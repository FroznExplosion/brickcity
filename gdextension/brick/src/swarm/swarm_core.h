// SwarmCore — C++ GDExtension core for the Swarm Master Plan (§1.1).
//
// Everything that runs per-agent per-tick lives here. GDScript only orchestrates
// (spawn policy, HUD, config, gun wiring) and crosses this boundary through a handful
// of batched methods (§1.3) — never per-agent in a loop.
//
// Phase 1 scope (Build Order §14):
//   §2  SoA buffers, free-list pooling, generation handles
//   §7  uniform spatial hash, O(n) counting-sort rebuild each tick
//   §11 fixed 30 Hz tick, decoupled from render, visual interpolation
//   §3  budget-first / distance-ranked tiering (hysteresis = Phase 3)
//   §4  MultiMesh instance-buffer writes with visible_instance_count
//   §1  apply_hitscan / apply_radial_damage resolved against the swarm
//
// Movement is seek + separation (a Phase-2 flow-field stand-in). Layers, portals, climb,
// VAT, and networking (§5–§9) are later phases; the SoA layout leaves room for them.
#ifndef SWARM_CORE_H
#define SWARM_CORE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>

#include "lane_graph.h"

#include <atomic>
#include <thread>
#include <vector>

namespace godot {

class SwarmCore : public Node3D {
	GDCLASS(SwarmCore, Node3D)

public:
	static const int MAX_AGENTS = 2048; // hard ceiling; the live target is set at runtime (§2.2)

	enum Tier { TIER_HERO = 0, TIER_NEAR, TIER_MID, TIER_FAR, TIER_CULLED };
	// Per-agent movement state (§7). Ground agents path the field; the rest are driven by
	// the climb system (§6): bodies walk to a slot at the wall foot, freeze there as static
	// pile geometry, climbers scramble over the frozen ones, elevated chase up top.
	// ST_STUCK: reached the top of what the pile can give it and is scrabbling at the face.
	// Still a live agent, still drawn, still in the way — it becomes part of the heap only when
	// the zombie behind it walks over it.
	// ST_CROUCH: being walked over. It ducks as the one behind climbs across it, and only then
	// becomes part of the heap — the pile grows by a body going DOWN, not by everything on top
	// of it being jacked up.
	// ST_LANE: walking an authored LaneGraph route to an objective, the defense case. Appended
	// rather than slotted in, because the numbers are already in saved data and in GDScript.
	enum State { ST_GROUND = 0, ST_BODY, ST_FROZEN, ST_CLIMBER, ST_ELEVATED, ST_STUCK, ST_FALLING, ST_CROUCH, ST_LANE };
	// What KIND of thing this row is. The horde is physical bodies; an outbreak wave
	// (GDD2 §4) is naked spirits, and the whole tactical point of one is that the physical
	// half of the arsenal does not work on it:
	//   KIND_OBJECT — a body. Kinetic hits it, it walks the flow field, it climbs.
	//   KIND_GHOST  — a naked spirit. Kinetic passes straight through; only the ecto calls
	//                 touch it. It phases through walls, so it ignores the field entirely
	//                 and flies at the goal, and it floats instead of walking.
	// This mirrors the node side exactly, where the same rule is a 0x row in the
	// effectiveness matrix against the ectoplasm layer (BaseGhost). Two representations of
	// one enemy, one rule.
	enum Kind { KIND_OBJECT = 0, KIND_GHOST };
	static const uint16_t FLAG_ALIVE = 1u;

private:
	// brickcity: the horde's own generator, never the global one (Docs/Multiplayer.md, D9).
	// splitmix64 -- tiny, and the same sequence on every machine from the same seed.
	// Mutable: a lane pick inside a const query draws from it too.
	mutable uint64_t _rng_state = 0x9E3779B97F4A7C15ull;
	uint32_t _rand_u32() const;
	float _rand01() const;
	float _rand_range(float lo, float hi) const { return lo + (hi - lo) * _rand01(); }

	// ---- SoA buffers (§2.1). Fixed capacity, allocated once, never resized in play. ----
	// Hot — every tick
	Vector3 _position[MAX_AGENTS];
	Vector3 _prev_position[MAX_AGENTS]; // render interpolation (§11)
	Vector3 _velocity[MAX_AGENTS];
	float _yaw[MAX_AGENTS];
	float _lean[MAX_AGENTS]; // forward pitch, radians — climbers lean into the wall / over the lip
	uint8_t _tier[MAX_AGENTS];
	uint8_t _state[MAX_AGENTS];
	uint8_t _kind[MAX_AGENTS];
	uint16_t _flags[MAX_AGENTS];
	// Warm
	float _health[MAX_AGENTS];
	float _max_health[MAX_AGENTS];
	uint32_t _cell_index[MAX_AGENTS];
	// Cold
	uint8_t _generation[MAX_AGENTS]; // stale-handle guard (§2.2)

	// --- Time scale ---------------------------------------------------------------
	// The node side dilates time per entity (EntityTime) because Engine.time_scale is
	// global and every game here is 4-player co-op. The horde needs the same thing, or
	// "stasis" is a lie on every swarm enemy in two of the three games.
	//
	// GLOBAL scale multiplies the ACCUMULATOR, not TICK_DT: the sim keeps its fixed
	// 30 Hz step (§11) and simply takes fewer steps per second. Determinism, the
	// networking plan (§9) and render interpolation all survive unchanged. Scaling
	// TICK_DT itself would make every tick a different length and break all three.
	//
	// LOCAL fields are spatial (a stasis bubble thrown into a crowd). They cannot use
	// the accumulator — only some agents are inside — so they scale per-agent motion
	// within a tick: travel, turn rate, fall, timers, animation phase.
	struct TimeField {
		Vector3 center;
		float radius = 0.0f;
		float scale = 1.0f;
	};
	static const int MAX_TIME_FIELDS = 8;

	float _time_scale = 1.0f;          // global, applied to the accumulator
	std::vector<TimeField> _time_fields;
	float _tscale[MAX_AGENTS];         // per-agent field scale, recomputed each tick
	void _update_time_scales();

	// Free-list pool
	int _free[MAX_AGENTS];
	int _free_top = 0; // number of free entries currently on the stack
	int _alive_count = 0;

	// ---- death-event queue (§8.4) ----
	// Mass kills remove agents from the sim immediately (cheap) but their death EFFECTS
	// (impacts/blood/corpses on the GDScript side) are expensive node spawns. Queue the
	// death positions and drain a bounded number per frame so a 100-kill grenade spreads
	// its VFX over ~frames instead of spiking one. Ring buffer: newest wins (§8.2).
	static const int DEATH_CAP = 512;
	Vector3 _death_pos[DEATH_CAP];
	int _death_head = 0;  // oldest
	int _death_count = 0;
	int _deaths_per_frame = 6;
	void _push_death(const Vector3 &p);

	// ---- spatial hash (§7) ----
	float _cell_size = 2.0f;
	int _grid_dim = 70;
	Vector3 _grid_origin;
	int _cell_count = 0;
	std::vector<int> _cell_start; // first slot in _order per cell
	std::vector<int> _cell_fill;  // running count / cursor
	int _order[MAX_AGENTS];       // agent indices bucketed by cell
	int _hashed_count = 0;        // entries actually in _order (frozen bodies are left out)

	// ---- flow field (§5, single layer / flat) ----
	// A 2D Dijkstra integration wave from the goal outward on a fine grid. Agents sample the
	// gradient of their cell and walk it — this routes them around obstacles and, via the
	// congestion layer (§5.7), around their own jams (the liquid-horde look). Regenerated
	// only when the goal moves or every N ticks. Replaces the Phase-1 straight-line seek.
	float _fcs = 0.5f;               // field cell size (§5.7)
	int _fdim = 0;
	int _fcell = 0;
	Vector3 _forigin;
	// Double-buffered (§10): movement reads the front buffers; a worker thread fills the
	// back buffers, then the main thread swaps them in. Keeps the ~ms regen off the tick.
	std::vector<float> _cost, _cost_b;
	std::vector<float> _dirx, _dirx_b;
	std::vector<float> _dirz, _dirz_b;
	// Reachability mask: a plain uncongested, unbounded flood from the goal cell. _cost says
	// "how expensive is the walk right now" (congestion + a cost cap make it lie about distant
	// cells); _reach says "is this cell in the player's connected ground region at all". The
	// climb system needs the second question — a wall the horde cannot walk around is exactly
	// a spot where reach is 0 on one side and 1 on the other (§6.2).
	std::vector<uint8_t> _reach, _reach_b;
	std::vector<uint8_t> _blocked;   // static obstacle mask (read-only on the worker)
	std::vector<uint16_t> _occ;      // per-cell occupancy scratch (worker-owned)
	float _max_cost_radius = 80.0f;  // bound the wave past this cost (§5.7)
	int _regen_interval = 12;        // ticks between forced regenerations
	float _goal_move_thresh = 2.0f;  // regen when the goal moves this far
	float _congestion_weight = 4.0f; // occupancy penalty added to cell cost (§13)
	Vector3 _last_field_goal;
	bool _field_ready = false;
	double _last_field_ms = 0.0;

	// worker-thread regen state
	std::thread _field_thread;
	std::atomic<bool> _field_running{ false };
	std::atomic<bool> _field_done{ false };
	std::vector<Vector3> _snap_pos;  // position snapshot the worker integrates against
	int _snap_count = 0;
	Vector3 _snap_goal;

	int _fcell_of(const Vector3 &p) const;
	void _field_worker();            // runs on _field_thread; fills the back buffers
	void _maybe_regen_field();       // main thread: consume finished field, kick a new one

	// ---- corpse layer (§8.3) ----
	// A body buried in a pile is never getting up again, so it stops being an agent: it dies,
	// hands its pool slot back to the horde, and what is left is a static instance in a second
	// MultiMesh that is only rewritten when a pile changes. That is the whole point — a
	// forty-body mound costs forty *corpses* and about seven live agents, not forty agents.
	// Corpses are the ramp, and they are scenery: get_pile_shapes() hands their bounds to the
	// level so it can put a collider there for the player to climb.
	struct Corpse {
		Vector3 pos;
		float yaw;
		int group;      // which pile laid it; survives that pile being released
		float hp;       // explosions chew through a mound rather than deleting it wholesale
	};
	float _corpse_hp = 140.0f;
	static const int MAX_CORPSES = 2048;
	static const int CORPSE_SLOT = -2; // slot_owner sentinel: filled, permanently
	std::vector<Corpse> _corpses;
	std::vector<uint8_t> _corpse_vis; // 0 = walled in by other corpses, never drawn
	bool _corpses_dirty = false;
	int _corpse_rev = 0;        // bumped on any corpse change, so the mesh layer knows to rebuild
	// With a mound mesh standing in for the mass of the pile, only the bodies lying on its crest
	// are drawn individually. A cone's upper layers are single rings of bodies — a hollow shell
	// that from the side reads as corpses floating in an arc. The mesh fills that in; the ring
	// underneath it should not be drawn at all.
	bool _pile_mesh_mode = false;
	int _next_group = 0;
	int _corpse_visible = 0;
	MultiMeshInstance3D *_cmmi = nullptr;
	Ref<MultiMesh> _cmm;
	PackedFloat32Array _cmm_buffer;
	void _add_corpse(const Vector3 &p, float yaw, int group);
	int _blast_corpses(const Vector3 &c, float r, float dmg); // explosions, and only explosions, break a mound
	void _revis_group(int group); // recompute which of a group's corpses anyone can actually see
	void _write_corpses();

	// ---- world volumes (§5/§6) ----
	// Every box the level registers. Blockers rasterise into the flow field; climbable ones
	// generate climb spots along their faces; walkable ones carry elevated agents on top.
	// Keeping the boxes (not just the rasterised mask) is what lets the climb system find
	// its own ledges instead of relying on authored markers.
	enum VolumeFlag { VOL_BLOCKS = 1u, VOL_CLIMB = 2u, VOL_WALK = 4u };
	struct Volume { Vector3 center; Vector3 size; uint8_t flags; };
	std::vector<Volume> _volumes;

	// ---- climb / pile-up (§6) ----
	// A ClimbStructure is a dynamically created ramp between the ground and whatever is on the
	// far side of a wall. The pile is authored geometry (§6.1) — a discrete lattice of body
	// slots — but its HEIGHT is emergent: it is exactly as tall as the bodies that actually
	// arrived. A zombie that reaches the crest and still can't clear the lip freezes into the
	// next free slot and becomes static geometry the next one climbs over. Run out of bodies
	// and the pile just stops at that height. Spots are discovered from the registered volumes,
	// so a level gets climbing for free; several structures run at once, one per jammed group.
	// Two pile shapes, picked per spot by whether there is anything to lean against (§6.3):
	//   WEDGE — the lip is backed by solid geometry all the way down. Bodies heap against the
	//           foot of the wall and climbers finish the last stretch on the face itself.
	//   CONE  — nothing under the lip: an overhanging slab, a balcony, open ground. The pile has
	//           to hold itself up, so it is a self-supporting mound of concentric rings whose
	//           radius shrinks with height. No wall segment — the horde goes straight up on
	//           its own bodies, and a tall one costs a great many of them.
	struct ClimbSpot {
		Vector3 base;    // ground stand-off OUTSIDE the pile footprint — where the horde queues
		Vector3 face;    // wedge: the point on the wall face. cone: the pile axis, at lip height
		Vector3 top;     // where a climber ends up: the upper surface, or the far-side ground
		Vector3 normal;  // outward horizontal direction (points at the horde)
		float height = 0.0f;    // lip height above the ground
		float thickness = 0.0f; // wall depth along -normal; the drop segment crosses it
		float radius = 0.0f;    // cone: ground-layer radius of the mound
		int surface = -1;       // volume index the climber lands on (-1 = plain ground)
		bool drop = false;      // true = crest the lip and fall down the far side (a wall)
		bool cone = false;      // true = free-standing mound, nothing to climb against
		bool authored = false;  // came from add_climb_point()
	};
	std::vector<ClimbSpot> _authored_spots;
	// Walkable volumes that an authored spot already lands on. Naming even one approach to a
	// surface is taken as "I am specifying the approaches to this thing" — discovery then stops
	// contributing its own for that surface, so a designer can pin the routes onto a hero
	// structure without having to hand-annotate the rest of the level.
	std::vector<int> _authored_surfaces;
	// Regions the level has vetoed. Discovery generates nothing whose foot or face lands inside
	// one; authored points are explicit intent and are NOT vetoed, so the pattern is "box out
	// the area, then place the approaches you actually want".
	std::vector<Volume> _no_climb;
	bool _in_no_climb(const Vector3 &p) const;
	std::vector<ClimbSpot> _spots;
	std::vector<int> _spot_mass;      // ground agents near each base, refreshed on the sel tick
	std::vector<float> _spot_score;   // last score per spot (debug + hysteresis)
	std::vector<float> _spot_sustain; // seconds this spot has been over the density threshold
	bool _spots_dirty = true;
	int _best_spot = -1;
	int _player_surface = -1;      // volume the player stands on, -1 = plain ground

	// A live pile. Slots fill bottom-up; `filled`/`pile_h` are the emergent height (§6.3).
	static const int MAX_STRUCTURES = 4;
	struct ClimbStructure {
		ClimbSpot spot;
		int spot_index = -1;
		int phase = 1;             // 1 growing, 2 crossable, 3 stalled (out of bodies)
		float age = 0.0f;
		float lost_t = 0.0f;       // seconds the spot has been useless (player left / rerouted)
		float stall_t = 0.0f;      // seconds without a body to recruit
		float pile_h = 0.0f;       // crest of the pile above base.y — count-derived, not authored
		int filled = 0;            // occupied slots
		int need = 0;              // slots required before a climber can clear the lip
		int claimed = 0;           // agents on their way here but not yet frozen (recount/tick)
		int fillers = 0;           // of those, ones scrambling up to a slot
		int group = -1;            // corpse group id — outlives the structure
		int buried = 0;            // slots that have become corpses
		float wall_yaw = 0.0f;
		std::vector<Vector3> slot_pos;   // lattice: one non-overlapping cell per body
		std::vector<uint8_t> slot_layer;
		std::vector<int> slot_owner;     // agent index, or -1 (reserved on recruit, not arrival)
		// crossing path, recomputed whenever pile_h changes (an event, not per tick)
		float seg_pile = 0.0f, seg_wall = 0.0f, seg_mantle = 0.0f, seg_drop = 0.0f, path_len = 0.0f;
		bool crossable = false;
	};
	std::vector<ClimbStructure> _structs;
	int _crossers = 0;             // agents currently going over the top, across all structures
	int _crossings = 0;            // total agents that have made it over, since startup (§12)
	int _max_fillers = 7;          // concurrent scramblers per pile. A 237-body mound at three at
	                               // a time takes minutes; the trample still gates each one.

	Vector3 _player_pos;
	Vector3 _path_goal;            // flow-field goal — always the player now (§6.2 rework)
	int32_t _climb_slot[MAX_AGENTS];
	int8_t _climb_struct[MAX_AGENTS]; // index into _structs, -1 = not in a pile
	Vector3 _climb_start[MAX_AGENTS]; // where a climber began — nobody is teleported on recruit
	float _climb_seg0[MAX_AGENTS];    // its own first-segment length, from there to the crest
	float _climb_prog[MAX_AGENTS]; // climbers: metres travelled along the climb path.
	                               // ST_ELEVATED reuses the pair: _climb_slot = the volume the
	                               // agent is standing on, _climb_prog = that surface height.
	// config (§13 SwarmClimbConfig)
	int _density_threshold = 16;   // agents jammed at the base before a pile forms (§6.2)
	float _density_radius = 8.0f;  // the jam spreads over metres — detect over that area
	float _density_sustain = 1.0f;
	float _goal_lost_grace = 4.0f; // keep the ramp this long after it stops being useful (§6.5)
	float _stall_timeout = 6.0f;   // no body to recruit for this long → the pile stops growing
	int _max_climbers = 24;        // concurrent climbers across all structures
	float _struct_min_sep = 12.0f; // new piles must start this far from an existing one
	float _recruit_radius = 14.0f; // ground agents inside this join THAT pile, not the far one
	float _queue_width = 5.0f;     // how far along the face the queue for a pile spreads
	int _recruit_interval = 4;     // ticks between recruit passes
	// spot generation
	bool _auto_spots = true;
	float _spot_spacing = 3.0f;    // one candidate per this many metres of face
	float _min_climb_h = 1.2f;     // below this the horde just walks up
	float _max_climb_h = 12.0f;    // above this a pile can't plausibly reach
	float _approach = 1.1f;        // queue stand-off from the face — right up against the wall
	float _top_inset = 1.1f;       // landing point inset behind the lip
	int _max_spots = 256;
	// pile lattice — discrete cells, so bodies can never occupy the same space
	float _layer_h = 0.6f;         // one prone body tall
	float _slot_pitch = 0.85f;     // horizontal cell; > 2x the 0.35 m agent radius
	float _grab_reach = 1.3f;           // how far above the crest a climber can grab
	// Wedge footprint at the ground layer. These are the MINIMUM: a heap has an angle of repose,
	// so a tall wall needs a broad base. Held fixed, a 9 m pile came out a one-body-wide spike.
	float _pile_depth = 1.8f;
	float _pile_width = 3.4f;
	float _pile_spread = 0.5f;     // extra base size per metre of lip
	float _pile_depth_max = 6.0f;
	float _pile_width_max = 9.0f;
	float _cone_base = 0.6f;       // cone radius at the crest
	float _cone_slope = 0.55f;     // radius gained per layer down — the angle of repose
	float _cone_offset = 0.7f;     // how far the mound's axis stands off the lip it serves
	int _max_layers = 18;
	// climb path shape / speeds
	float _wall_hug = 0.45f;       // climber distance from the face while ascending
	float _lip_rise = 0.55f;       // mantle arc height above the lip
	float _pile_speed = 2.2f;      // m/s scrambling up the bodies
	float _wall_speed = 1.6f;      // m/s up the wall face
	float _mantle_speed = 1.1f;    // m/s over the lip
	float _drop_speed = 5.0f;      // m/s down the far side of a wall
	// selection scoring
	float _sel_player_radius = 60.0f;
	float _w_player = 3.0f;
	float _w_mass = 2.0f;
	float _w_height = 0.25f;
	float _authored_bonus = 0.75f; // designer-placed spots win ties
	int _sel_interval = 15;        // ticks between spot re-scores
	void _update_climb(float dt);
	void _rebuild_spots();
	void _gen_spots_for(int v);
	void _score_spots(float dt);
	float _score_of(const ClimbSpot &s, int mass) const;
	bool _spot_useful(const ClimbSpot &s) const;         // does climbing here reach the player?
	int _surface_under(const Vector3 &p, float y) const; // walkable volume with top ≈ y under p
	int _volume_under_player() const;
	bool _on_surface(int v, const Vector3 &p) const;
	bool _covered(const Vector3 &p) const;               // something walkable overhead
	// Height of the lowest thing overhead, or a big number for open sky. _covered() only answers
	// yes/no, which cannot tell a spot with a metre of clearance from one with none — and a pile
	// built under a slab pushes heads through it.
	float _ceiling_at(const Vector3 &p, float above_y) const;
	float _headroom = 1.15f;   // clearance a climber needs above the lip it is going over
	bool _solid_below(const Vector3 &face, const Vector3 &n, float lip) const; // wall, or overhang?
	float _cone_radius_for(float lip) const;             // ground radius a self-supporting mound needs
	int _count_ground_near(const Vector3 &c, float r) const;
	// structures
	int _struct_at_spot(int spot_index) const;
	void _struct_begin(int spot_index);
	void _struct_release(int k);
	void _build_lattice(ClimbStructure &S);
	void _recalc_pile(ClimbStructure &S);
	void _recruit(ClimbStructure &S, int k);
	int _free_slot(const ClimbStructure &S, int min_layer) const;
	// Nearest free cell in the LOWEST layer that still has one. Bottom-up filling is what makes
	// the crest track the bodies, but which cell within that layer is free choice — so a zombie
	// arriving from any side climbs up that side instead of walking round to a fixed spot.
	int _free_slot_near(const ClimbStructure &S, const Vector3 &from) const;
	void _freeze(int i, ClimbStructure &S);
	int _nearest_struct(const Vector3 &p) const;
	Vector3 _filler_path_pos(const ClimbStructure &S, int slot, const Vector3 &start, float s, float *out_lean) const;
	Vector3 _cross_path_pos(const ClimbStructure &S, float s, const Vector3 &start, float seg0, float *out_lean) const;
	float _filler_path_len(const ClimbStructure &S, int slot, const Vector3 &start) const;

	// ---- tiering (§3) ----
	int _tier_budget[4] = { 12, 60, 200, 100000 };
	float _cull_dist = 120.0f;
	int _tier_counts[5] = { 0, 0, 0, 0, 0 };
	std::vector<int> _rank; // scratch for the distance sort

	// ---- sim wiring ----
	int _target_population = 500;
	bool _director_on = true;
	Vector3 _goal_pos;
	Vector3 _camera_pos;
	bool _has_goal = false;
	double _accum = 0.0;
	uint32_t _tick = 0;
	bool _overlay_tier = true;
	bool _paused = false;
	int _visible_count = 0;

	// ---- movement tuning (Phase 1 stand-in) ----
	float _move_speed = 2.6f;
	float _stop_radius = 1.4f;
	// Deliberately tight. A horde waiting to climb should look like it is shoving to get to the
	// front, not queueing politely — the hard de-overlap pass is what stops them interpenetrating,
	// so the steering only needs a nudge.
	float _sep_radius = 0.85f;
	float _sep_strength = 1.5f;
	// Steering alone cannot stop 500 agents all seeking one point from interpenetrating — the
	// seek force simply outvotes it. After integration, push overlapping pairs apart on
	// position (§7). Cheap, hash-bounded, and the only thing that actually holds a crowd apart.
	float _agent_radius = 0.30f;
	int _overlap_passes = 3;
	// Gauss-Seidel relaxation. Resolving each overlapping pair fully, every pass, overshoots
	// when an agent has many neighbours: it gets shoved past them, gets shoved back next tick,
	// and the crowd buzzes. Correcting a fraction per pass converges instead of ringing.
	float _overlap_relax = 0.55f;
	// How wedged each agent is: the shortfall between the distance it MEANT to travel last
	// tick and the distance it actually did, smoothed. A packed crowd is a physical fact — the
	// agents in the middle cannot go anywhere, and the seek force insisting otherwise is what
	// makes them vibrate. High jam damps the seek, the separation steer, and the velocity, so
	// they cram in and settle instead.
	float _jam[MAX_AGENTS];
	float _cmd_speed[MAX_AGENTS]; // speed it was actually told to travel at last tick
	float _stuck_t[MAX_AGENTS];   // seconds spent stuck at the crest, drives the scrabble
	float _trample_radius = 0.85f;
	bool _trampled(int i, const Vector3 &p) const;
	// Zombies do not pivot on the spot. Facing is rate-limited, and while an agent is wedged it
	// faces where it WANTS to go rather than where the shoving happens to be pushing it —
	// steering direction under a crowd swings every tick, and following it is the jitter.
	float _yaw_rate = 5.0f; // radians per second
	void _turn_toward(int i, const Vector3 &dir);

	// ---- pile as geometry ----
	// A finished pile is a solid object in the world. Without this the horde walks straight
	// through the heap it just built. Rasterised from the same bodies that feed the mound, and
	// consulted by ground movement only — the flow field still points through it, which is what
	// presses agents into it and gets them climbing instead of politely detouring.
	// Not a wall — a surface. Storing the pile's HEIGHT per cell instead of a blocking flag is
	// what lets the horde walk onto it, over it and down the far side, which is both what they
	// should do instead of stopping dead at it and what a body falling onto a heap has to land
	// on. Getting over the *lip* of a wall is still the climb system's job.
	std::vector<float> _pile_h_field;
	bool _pile_mask_dirty = true;
	float _max_step = 0.12f;   // height an agent can gain in one tick; steeper reads as a face
	float _surf_rise = 0.9f;   // m/s an agent is carried up by a heap growing under it — they
	                           // step up onto it rather than being levitated
	float _crouch_time = 0.45f;
	float _gravity = 18.0f;
	float _fall_v[MAX_AGENTS]; // vertical speed while falling
	void _rebuild_pile_field();
	float _pile_h_at(const Vector3 &p) const;
	float _jam_smooth = 0.12f;
	float _jam_max = 0.85f;       // never ease all the way to zero, or a jam can't unwind
	int _overlap_pairs = 0; // pairs still interpenetrating after the last pass (§12)
	void _resolve_overlap();

	// ---- hitscan tuning ----
	float _hit_radius = 0.55f;
	float _hit_range = 500.0f;
	Vector3 _body_center = Vector3(0, 0.9f, 0);

	// ---- naked ghosts (GDD2 §4 Outbreak Waves) ----
	// Spirits do not path. They phase through exterior walls to get in, so nothing about
	// the flow field, the obstacle mask or the pile applies to them: they fly at the goal
	// in a straight line at a fixed height. That is deliberately much simpler than the
	// horde's movement, and it is also the reason a wave of them cannot be walled out —
	// barricades are for objects.
	int _ghost_count = 0;
	float _ghost_speed = 3.0f;
	float _ghost_hover = 1.0f;   // metres off the floor the spirit floats at
	float _ghost_bob = 0.25f;    // vertical drift amplitude, so a crowd is not a flat plane
	// Ghosts get their own MultiMesh layer rather than a pose bucket: they share no
	// geometry with the body meshes and none of the locomotion phase that buckets them.
	MultiMeshInstance3D *_gmmi = nullptr;
	Ref<MultiMesh> _gmm;
	PackedFloat32Array _gmm_buffer;
	Ref<Mesh> _ghost_mesh;
	int _ghost_visible = 0;
	void _write_ghosts(float alpha);
	// Shared spawn path so an object and a spirit can never drift out of sync on which
	// fields a fresh row has to have.
	void _spawn_one(int i, const Vector3 &pos, float hp, uint8_t kind);

	// ---- ST_LANE: the defense case (Docs/Ghosts/DEFENSE_LANES_SPEC.md) --------------
	//
	// The horde's own movement rests on "zombies do not plan": the flow field points at the
	// goal, agents press into whatever is between them and it, and piles form where they jam.
	// That is the right model for a siege and the wrong one for a tower defense, where the
	// entire proposition is that the player can SEE where the wave will walk and buy a turret
	// covering it. A route that might not be used is worthless for that.
	//
	// So a lane walker is a different state, not a different tuning. It ignores the field, the
	// obstacle mask and the pile — the lane was authored around all three — and runs the exact
	// follow rule scripts/td/lane_walker.gd runs, including both of its non-obvious fixes:
	//
	//   PROGRESS IS PROJECTED, NEVER INTEGRATED. Soft steering cuts every corner, so distance
	//   travelled is always shorter than the curve. Integrating it leaves the lookahead target
	//   behind the walker and it oscillates in place; ~11% never arrived. Asking where the body
	//   IS (edge_offset_of), clamped monotone, is what makes a body pinned against a barricade
	//   or dragged backwards make no progress with no special case at all.
	//
	//   THE ARRIVAL RING MUST CLEAR THE WALKER'S OWN LATERAL OFFSET. The last steering target
	//   sits |lateral| metres BESIDE the end node, deliberately, so a crowd fans out around the
	//   rig instead of stacking on one point. A fixed radius under the widest offset leaves a
	//   walker orbiting forever; ~20% were lost that way.
	//
	// Any change here has to be mirrored in lane_walker.gd and vice versa.
	Ref<LaneGraph> _lanes;
	int32_t _lane_edge[MAX_AGENTS];  // -1 = not routed yet
	float _lane_dist[MAX_AGENTS];    // monotone progress along that edge
	float _lane_lat[MAX_AGENTS];     // fixed at entry: what stops a conga line
	int _lane_count = 0;
	float _lane_speed = 2.6f;

	// Barricades, as parallel arrays indexed by the order GDScript handed them over. That
	// index IS the blocker's identity in both directions — the core reports attackers by it,
	// and the host maps it back to whatever object it owns. Lane-relative rather than a
	// physics query, exactly as TDBlocker is, because a wall's job is to be predictable on a
	// known route.
	PackedInt32Array _blk_edge;
	PackedFloat32Array _blk_dist;
	std::vector<int> _blk_hits;
	// Per edge: does walking it still lead to something alive? The host's job to fill (the
	// defense layer floods backward from live objectives). Empty = no filtering.
	std::vector<uint8_t> _lane_live;
	// Per graph NODE: how many walkers are standing on it hitting it this tick.
	std::vector<int> _obj_hits;

	void _lane_move(int i, float dt);
	void _lane_enter(int i, int e, float at);
	int _lane_pick_edge(int node) const;
	int _lane_nearest_edge(const Vector3 &p) const;
	// Nearest live barricade on `e` at or beyond `from_d`. Returns its id, -1 for none, and
	// writes where to stop short of it.
	int _blocker_ahead(int e, float from_d, float *out_stop) const;
	bool _edge_is_live(int e) const {
		return _lane_live.empty() || (e >= 0 && e < (int)_lane_live.size() && _lane_live[e]);
	}

	// ---- rendering (§4) ----
	// One MultiMesh per baked pose. A MultiMesh has a single mesh for every instance, so a
	// crowd built from one of them is a clone army frozen in one stance. Handing the core a
	// few poses baked off the real rig and bucketing agents between them by animation phase
	// gets a moving crowd out of static instances — a poor man's VAT (§4.2) with no shader
	// work. With no meshes supplied it falls back to a single capsule.
	std::vector<MultiMeshInstance3D *> _mmis;
	std::vector<Ref<MultiMesh>> _mms;
	std::vector<PackedFloat32Array> _mm_buffers;
	int _poses_per_set = 1;        // layers are laid out [set0 poses..][set1 poses..]
	int _mm_sets = 1;              // 1 = capsule placeholder, 2 = walk + run
	float _run_speed = 1.8f;       // above this an agent uses the run pose set
	// Where the instance origin sits relative to the mesh. The capsule is modelled around its
	// centre; a baked character has its feet on the origin, so the offset has to change with it
	// or the whole distant crowd hovers a body-height off the ground.
	float _stand_y_off = 0.9f;
	float _prone_y_off = 0.35f;
	float _anim_phase[MAX_AGENTS]; // 0..1 around the locomotion cycle, drives the pose bucket
	float _phase_rate = 1.1f;      // cycles per second at full speed
	void _build_mesh_layer(const Ref<Mesh> &mesh, int count);

	// ---- node pool (§4.1) ----
	// Tier 0-1 agents are drawn as real skinned character nodes with skeletons and animation,
	// not MultiMesh instances. The core does not own those nodes — it owns the *assignment*:
	// which agent is in which pool slot, held stable across frames so an actor keeps its
	// animation phase instead of popping every time the sort order shifts. GDScript reads one
	// packed array per frame (§1.3) and moves its pool to match. Agents holding a slot are
	// skipped by the MultiMesh write, so nothing is ever drawn twice.
	static const int MAX_NODES = 96;
	static const int SLICE_STRIDE = 11; // used, x, y, z, yaw, lean, state, tier, speed, agent, phase
	int _node_tier_max = -1;           // -1 = feature off, everything goes to the MultiMesh
	int _node_budget = 0;
	int16_t _node_slot[MAX_AGENTS];    // agent -> pool slot, -1 = MultiMesh
	int _slot_agent[MAX_NODES];        // pool slot -> agent, -1 = free
	PackedFloat32Array _slice;
	int _node_used = 0;
	void _assign_nodes();
	void _write_slice(float alpha);

	// ---- perf counters (§12) ----
	double _last_tick_ms = 0.0;
	double _last_render_ms = 0.0;

	// internals
	void _build_render();
	void _step_tick();
	void _director();
	void _build_hash();
	void _movement();
	Vector3 _separation(int self_i, const Vector3 &p) const;
	void _assign_tiers();
	void _write_multimesh(float alpha);
	int _cell_of(const Vector3 &p) const;
	void _kill(int i);

protected:
	static void _bind_methods();

public:
	SwarmCore();
	~SwarmCore();

	void _ready() override;
	void _process(double delta) override;

	// ---- GDScript boundary (§1.3): batched, never per-agent in a loop ----
	void configure(int target_population, float cell_size, int grid_dim);
	/// brickcity: seed the horde's generator. Whoever owns combat seeds it (D9).
	void set_seed(int64_t seed);
	void set_goal_position(const Vector3 &p); // once/frame
	void set_camera_position(const Vector3 &p);
	void spawn_batch(const PackedVector3Array &positions, float hp);
	Dictionary apply_hitscan(const Vector3 &from, const Vector3 &dir, float dmg);
	int apply_radial_damage(const Vector3 &center, float radius, float dmg); // returns kill count

	// ---- naked ghosts (GDD2 §4) ----
	// An outbreak wave phases in through the walls: spawn them anywhere, they fly straight
	// at the goal. Population is tracked separately from the horde's, so a scripted wave is
	// not immediately culled by the director trying to hold `target_population`.
	void spawn_ghost_batch(const PackedVector3Array &positions, float hp);
	// The anti-ghost half of the arsenal. Kinetic (hitscan / radial / point) cannot touch a
	// spirit at all; these two are the only calls that can, and they in turn cannot touch a
	// body. That symmetry is the whole "Kinetic Breakers vs Energy Trappers" split, and it
	// is what makes an outbreak wave a genuine loadout check rather than a reskin.
	int apply_ecto_damage(const Vector3 &center, float radius, float dmg);   // vacuum node / mortar
	Dictionary apply_ecto_beam(const Vector3 &from, const Vector3 &dir, float half_angle,
			float max_range, float dmg);                                     // a held beam
	int get_ghost_count() const { return _ghost_count; }
	void set_ghost_params(float speed, float hover, float bob);
	void set_ghost_mesh(const Ref<Mesh> &mesh);

	// ---- lanes (ST_LANE) ----
	// The SAME LaneGraph resource the node side reads. It is a Resource and not part of this
	// class precisely so both can hold it: two SwarmCore instances in one tree segfault, so
	// lane data could never have lived inside the core.
	void set_lane_graph(const Ref<LaneGraph> &g);
	Ref<LaneGraph> get_lane_graph() const { return _lanes; }
	void set_lane_speed(float s);
	float get_lane_speed() const { return _lane_speed; }
	// Release bodies onto a route. `door_node` < 0 makes each one join the nearest lane from
	// where it landed, which is how anything that appears off-route gets going.
	void spawn_lane_batch(const PackedVector3Array &positions, float hp, int door_node);
	int get_lane_count() const { return _lane_count; }
	// Put every ground agent standing inside an axis-aligned box onto the lanes. Returns how
	// many changed over.
	//
	// This is the handover between the two halves of an open-approach defense: out in the
	// field the horde walks the flow field, spreading out and going round things; at the mouth
	// of the build zone it has to become a lane walker, or the barricades the player just
	// snapped together are scenery it wanders past.
	//
	// It lives in C++ because the alternative is asking GDScript where every row is, every
	// frame — `get_agent_state` per agent over a horde is exactly the per-body scripting the
	// whole core exists to avoid, and it hands over late, which shows up as a wave clipping
	// the corner of the first wall. Here it is one pass over the pool inside the tick.
	//
	// `door_node` < 0 joins each body to the nearest lane from where it stands, which is
	// almost always what a handover wants: the body has walked its own way to the mouth and
	// the route it should pick up is the one it is next to.
	int lane_convert_in_box(const Vector3 &center, const Vector3 &half_extents, int door_node);
	// Parallel arrays; the index into them is the blocker's id in every direction.
	void set_lane_blockers(const PackedInt32Array &edges, const PackedFloat32Array &dists);
	// One byte per edge: 1 = still leads to a live objective. Without it a wave routes to a
	// wrecked Sub-Anchor, finds nothing, rejoins the nearest lane — the one it just walked —
	// and ping-pongs on that dead end forever.
	void set_lane_live(const PackedByteArray &per_edge);
	// Censuses, not damage: the core moves bodies and counts what is hitting what, and the
	// host applies damage by its own rules. Elements, layered pools and refunds are game
	// ideas and the horde must not learn any of them.
	PackedInt32Array get_lane_blocker_attackers() const;
	PackedInt32Array get_lane_objective_attackers() const;
	PackedVector3Array poll_deaths(); // drain up to deaths_per_frame death-effect positions
	void set_target_population(int n);
	int get_target_population() const { return _target_population; }
	// Turn the population director off entirely.
	//
	// The director keeps a free-roaming horde topped up around the goal, which is right for a
	// survival level and wrong for a defense: there the wave is AUTHORED, and a round that
	// releases forty bodies must release forty. Left on, converting bodies to lane walkers
	// lowers the count it measures and it ring-spawns replacements behind the player, so the
	// level quietly refills itself with zombies nobody asked for.
	//
	// A target of zero does not do this job — that reads as being over budget and culls every
	// body the wave just spawned, one of the older traps in this file.
	void set_director_enabled(bool on) { _director_on = on; }
	bool get_director_enabled() const { return _director_on; }

	// ---- effect queries (§1.3) ----
	// Gun effects are written against scene nodes in a group; swarm agents are rows of floats,
	// so they need the same questions answered here. Both are one call per shot — an event,
	// never a per-agent loop from GDScript.
	Dictionary query_cone(const Vector3 &from, const Vector3 &dir, float half_angle, float max_range) const;
	Dictionary apply_point_damage(const Vector3 &center, float radius, float dmg, bool pick_random);
	void set_deaths_per_frame(int n);

	void set_overlay_tier(bool on);
	bool get_overlay_tier() const { return _overlay_tier; }
	void set_paused(bool p);          // freeze the sim; rendering keeps running
	bool get_paused() const { return _paused; }

	// --- Time scale (mirror of the node side's EntityTime) ---
	// Global: 1.0 = real time, 0.0 = frozen. Differs from set_paused(true) in that the
	// accumulator is NOT discarded, so partial scales keep sub-tick time banked.
	void set_time_scale(float s);
	float get_time_scale() const { return _time_scale; }

	// Spatial dilation — a stasis bubble dropped into a crowd. Overlapping fields take
	// the STRONGEST slow (min), not the product: two 0.5 bubbles are still 0.5, because
	// they are places, not stacking effects. (EntityTime's named sources multiply
	// instead — those are channels on one entity, which is a different question.)
	void add_time_field(const Vector3 &center, float radius, float scale);
	void clear_time_fields();
	int get_time_field_count() const { return (int)_time_fields.size(); }
	float get_agent_time_scale(int i) const;
	// Hand tiers 0..max_tier to a GDScript node pool (§4.1). budget caps how many actors it
	// will ever be asked for. max_tier < 0 turns it off again.
	// Swap the placeholder capsule for real geometry. `poses` is a set of meshes baked off the
	// rig in agent space; agents are spread across them by animation phase so the distant crowd
	// moves. `corpse` is the mesh laid on its side for the pile bodies (§8.3).
	void set_instance_meshes(const Array &walk_poses, const Array &run_poses, const Ref<Mesh> &corpse,
			float stand_y_off, float prone_y_off, float run_speed);
	void set_node_pool(int max_tier, int budget);
	PackedFloat32Array get_render_slice() const { return _slice; }
	int get_node_used() const { return _node_used; }
	int get_corpse_count() const { return (int)_corpses.size(); }
	int get_corpse_visible() const { return _corpse_visible; }
	Array get_pile_shapes() const;    // per corpse group: {center, size} for a level collider
	// Per corpse group: every body position, for the level to build a mound surface over.
	Array get_pile_fields() const;
	int get_corpse_revision() const { return _corpse_rev; }
	void set_pile_mesh_mode(bool on);

	// flow field config / obstacles (§5)
	void set_field_params(float cell_size, float max_cost_radius, int regen_interval, float congestion_weight);
	void add_obstacle(const Vector3 &center, const Vector3 &size); // blocks the ground field, climbable, walkable on top
	void add_platform(const Vector3 &center, const Vector3 &size); // ledge the horde walks under; climbable, walkable on top
	void clear_obstacles();
	double get_last_field_ms() const { return _last_field_ms; }

	// climb (§6)
	void add_climb_point(const Vector3 &base, const Vector3 &top); // authored spot, same motion as a generated one
	void clear_climb_points();
	void add_no_climb(const Vector3 &center, const Vector3 &size); // veto discovery in a region
	void clear_no_climb();
	void set_auto_climb(bool on, float spacing, float min_height, float max_height);
	// Deprecated: the core works out for itself whether the player is out of ground reach
	// (elevated, or walled in). Kept so callers can keep feeding the player's full 3D position;
	// the bool is ignored.
	void set_player_elevated(bool elevated, const Vector3 &player_pos);
	void set_climb_params(int density_threshold, float density_radius, float recruit_radius, float struct_min_sep);
	bool is_elevated_at(const Vector3 &p) const;  // stood on a registered walkable volume?
	bool is_reachable_at(const Vector3 &p) const; // ground-connected to the player? (§6.2)
	bool is_blocked_at(const Vector3 &p) const;   // inside the INFLATED obstacle mask (pathing)
	bool is_solid_at(const Vector3 &p) const;     // inside the actual obstacle box (mound clipping)
	void set_corpse_hp(float hp);
	Dictionary get_climb_debug() const; // aggregate counters + the first structure, for HUDs
	Array get_climb_structs() const;    // per-structure dicts (§12)
	Array get_climb_spots() const;      // per-spot dicts for debug drawing (§12)

	PackedInt32Array get_tier_counts() const;
	int get_alive_count() const { return _alive_count; }
	int get_visible_count() const { return _visible_count; }
	double get_last_tick_ms() const { return _last_tick_ms; }
	double get_last_render_ms() const { return _last_render_ms; }

	// handles (§2.2)
	int make_handle(int i) const;
	bool is_handle_live(int handle) const;

	// --- Promotion (swarm row -> real node entity) ---------------------------------
	// A swarm agent is an SoA row drawn by MultiMesh: no mesh, no skeleton, no
	// HealthPool. Executions, Doomed State and stasis stored-damage all need per-entity
	// node state, so the horde has to be able to hand one agent over to the node world
	// and forget it. These three calls are that handover; the policy (which scene, when)
	// lives in GDScript (§1.2).
	//
	// Handles, not indices: a raw index is reused by the pool the moment the agent dies,
	// so anything holding one across a frame is pointing at a stranger.

	// Everything the node side needs to continue this agent: position, velocity, yaw,
	// health, max_health, state, tier, anim_phase, body_center. Empty if the handle is
	// stale. Side-effect free — call it before deciding whether to promote.
	Dictionary get_agent_state(int handle) const;

	// Remove the agent WITHOUT a death event. Promotion is not death: no corpse, no
	// gore budget, no VFX. Returns false if the handle was already stale.
	bool release_agent(int handle);

	// Nearest agent in a cone, as a HANDLE — the targeting call for "look at a doomed
	// enemy and press melee". query_cone() answers a different question (where to aim)
	// and hands back a position, which cannot be promoted.
	int query_cone_handle(const Vector3 &from, const Vector3 &dir, float half_angle,
			float max_range) const;
};

} // namespace godot

// Kind has to cross into GDScript: the promoter branches on it to decide whether a row
// becomes a naked BaseGhost or a shootable body, and that decision must not be spelled as
// a bare 0/1 on the script side.
VARIANT_ENUM_CAST(godot::SwarmCore::Kind);

#endif // SWARM_CORE_H
