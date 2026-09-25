#include "swarm_core.h"

#include <godot_cpp/classes/capsule_mesh.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/sphere_mesh.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <queue>
#include <utility>

static const float INF_COST = std::numeric_limits<float>::infinity();

using namespace godot;

// Tier overlay colours (§12): Hero red, Near orange, Mid yellow, Far blue, Culled grey.
static const Color TIER_COLOR[5] = {
	Color(1.0f, 0.25f, 0.25f),
	Color(1.0f, 0.65f, 0.15f),
	Color(0.95f, 0.9f, 0.2f),
	Color(0.3f, 0.7f, 1.0f),
	Color(0.4f, 0.4f, 0.45f),
};

static const float TICK_DT = 1.0f / 30.0f; // fixed 30 Hz sim (§11)
static const int MM_STRIDE = 16;           // 12 transform floats + 4 colour floats

SwarmCore::SwarmCore() {}
SwarmCore::~SwarmCore() {
	if (_field_thread.joinable()) _field_thread.join();
}

void SwarmCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &SwarmCore::set_seed);
	ClassDB::bind_method(D_METHOD("configure", "target_population", "cell_size", "grid_dim"), &SwarmCore::configure);
	ClassDB::bind_method(D_METHOD("set_goal_position", "p"), &SwarmCore::set_goal_position);
	ClassDB::bind_method(D_METHOD("set_camera_position", "p"), &SwarmCore::set_camera_position);
	ClassDB::bind_method(D_METHOD("spawn_batch", "positions", "hp"), &SwarmCore::spawn_batch);
	// --- naked ghosts / outbreak waves (GDD2 §4) ---
	ClassDB::bind_method(D_METHOD("spawn_ghost_batch", "positions", "hp"), &SwarmCore::spawn_ghost_batch);
	ClassDB::bind_method(D_METHOD("apply_ecto_damage", "center", "radius", "dmg"), &SwarmCore::apply_ecto_damage);
	ClassDB::bind_method(D_METHOD("apply_ecto_beam", "from", "dir", "half_angle", "max_range", "dmg"),
			&SwarmCore::apply_ecto_beam);
	ClassDB::bind_method(D_METHOD("get_ghost_count"), &SwarmCore::get_ghost_count);
	ClassDB::bind_method(D_METHOD("set_ghost_params", "speed", "hover", "bob"), &SwarmCore::set_ghost_params);
	ClassDB::bind_method(D_METHOD("set_ghost_mesh", "mesh"), &SwarmCore::set_ghost_mesh);

	// ---- lanes (ST_LANE) ----
	ClassDB::bind_method(D_METHOD("set_lane_graph", "graph"), &SwarmCore::set_lane_graph);
	ClassDB::bind_method(D_METHOD("get_lane_graph"), &SwarmCore::get_lane_graph);
	ClassDB::bind_method(D_METHOD("set_lane_speed", "speed"), &SwarmCore::set_lane_speed);
	ClassDB::bind_method(D_METHOD("get_lane_speed"), &SwarmCore::get_lane_speed);
	ClassDB::bind_method(D_METHOD("spawn_lane_batch", "positions", "hp", "door_node"),
			&SwarmCore::spawn_lane_batch);
	ClassDB::bind_method(D_METHOD("get_lane_count"), &SwarmCore::get_lane_count);
	ClassDB::bind_method(D_METHOD("set_director_enabled", "on"),
			&SwarmCore::set_director_enabled);
	ClassDB::bind_method(D_METHOD("get_director_enabled"), &SwarmCore::get_director_enabled);
	ClassDB::bind_method(
			D_METHOD("lane_convert_in_box", "center", "half_extents", "door_node"),
			&SwarmCore::lane_convert_in_box, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("set_lane_blockers", "edges", "dists"),
			&SwarmCore::set_lane_blockers);
	ClassDB::bind_method(D_METHOD("set_lane_live", "per_edge"), &SwarmCore::set_lane_live);
	ClassDB::bind_method(D_METHOD("get_lane_blocker_attackers"),
			&SwarmCore::get_lane_blocker_attackers);
	ClassDB::bind_method(D_METHOD("get_lane_objective_attackers"),
			&SwarmCore::get_lane_objective_attackers);
	BIND_ENUM_CONSTANT(KIND_OBJECT);
	BIND_ENUM_CONSTANT(KIND_GHOST);
	ClassDB::bind_method(D_METHOD("apply_hitscan", "from", "dir", "dmg"), &SwarmCore::apply_hitscan);
	ClassDB::bind_method(D_METHOD("apply_radial_damage", "center", "radius", "dmg"), &SwarmCore::apply_radial_damage);
	ClassDB::bind_method(D_METHOD("poll_deaths"), &SwarmCore::poll_deaths);
	ClassDB::bind_method(D_METHOD("set_deaths_per_frame", "n"), &SwarmCore::set_deaths_per_frame);
	ClassDB::bind_method(D_METHOD("set_target_population", "n"), &SwarmCore::set_target_population);
	ClassDB::bind_method(D_METHOD("get_target_population"), &SwarmCore::get_target_population);
	ClassDB::bind_method(D_METHOD("query_cone", "from", "dir", "half_angle", "max_range"), &SwarmCore::query_cone);
	ClassDB::bind_method(D_METHOD("apply_point_damage", "center", "radius", "dmg", "pick_random"), &SwarmCore::apply_point_damage);
	ClassDB::bind_method(D_METHOD("set_overlay_tier", "on"), &SwarmCore::set_overlay_tier);
	ClassDB::bind_method(D_METHOD("get_overlay_tier"), &SwarmCore::get_overlay_tier);
	ClassDB::bind_method(D_METHOD("set_paused", "p"), &SwarmCore::set_paused);
	ClassDB::bind_method(D_METHOD("get_paused"), &SwarmCore::get_paused);
	ClassDB::bind_method(D_METHOD("set_time_scale", "s"), &SwarmCore::set_time_scale);
	ClassDB::bind_method(D_METHOD("get_time_scale"), &SwarmCore::get_time_scale);
	ClassDB::bind_method(D_METHOD("add_time_field", "center", "radius", "scale"), &SwarmCore::add_time_field);
	ClassDB::bind_method(D_METHOD("clear_time_fields"), &SwarmCore::clear_time_fields);
	ClassDB::bind_method(D_METHOD("get_time_field_count"), &SwarmCore::get_time_field_count);
	ClassDB::bind_method(D_METHOD("get_agent_time_scale", "i"), &SwarmCore::get_agent_time_scale);
	ClassDB::bind_method(D_METHOD("set_instance_meshes", "walk_poses", "run_poses", "corpse", "stand_y_off", "prone_y_off", "run_speed"), &SwarmCore::set_instance_meshes);
	ClassDB::bind_method(D_METHOD("set_node_pool", "max_tier", "budget"), &SwarmCore::set_node_pool);
	ClassDB::bind_method(D_METHOD("get_render_slice"), &SwarmCore::get_render_slice);
	ClassDB::bind_method(D_METHOD("get_node_used"), &SwarmCore::get_node_used);
	ClassDB::bind_method(D_METHOD("get_corpse_count"), &SwarmCore::get_corpse_count);
	ClassDB::bind_method(D_METHOD("get_corpse_visible"), &SwarmCore::get_corpse_visible);
	ClassDB::bind_method(D_METHOD("get_pile_shapes"), &SwarmCore::get_pile_shapes);
	ClassDB::bind_method(D_METHOD("get_pile_fields"), &SwarmCore::get_pile_fields);
	ClassDB::bind_method(D_METHOD("get_corpse_revision"), &SwarmCore::get_corpse_revision);
	ClassDB::bind_method(D_METHOD("set_pile_mesh_mode", "on"), &SwarmCore::set_pile_mesh_mode);
	ClassDB::bind_method(D_METHOD("set_field_params", "cell_size", "max_cost_radius", "regen_interval", "congestion_weight"), &SwarmCore::set_field_params);
	ClassDB::bind_method(D_METHOD("add_obstacle", "center", "size"), &SwarmCore::add_obstacle);
	ClassDB::bind_method(D_METHOD("add_platform", "center", "size"), &SwarmCore::add_platform);
	ClassDB::bind_method(D_METHOD("clear_obstacles"), &SwarmCore::clear_obstacles);
	ClassDB::bind_method(D_METHOD("get_last_field_ms"), &SwarmCore::get_last_field_ms);
	ClassDB::bind_method(D_METHOD("add_climb_point", "base", "top"), &SwarmCore::add_climb_point);
	ClassDB::bind_method(D_METHOD("clear_climb_points"), &SwarmCore::clear_climb_points);
	ClassDB::bind_method(D_METHOD("add_no_climb", "center", "size"), &SwarmCore::add_no_climb);
	ClassDB::bind_method(D_METHOD("clear_no_climb"), &SwarmCore::clear_no_climb);
	ClassDB::bind_method(D_METHOD("set_auto_climb", "on", "spacing", "min_height", "max_height"), &SwarmCore::set_auto_climb);
	ClassDB::bind_method(D_METHOD("set_player_elevated", "elevated", "player_pos"), &SwarmCore::set_player_elevated);
	ClassDB::bind_method(D_METHOD("set_climb_params", "density_threshold", "density_radius", "recruit_radius", "struct_min_sep"), &SwarmCore::set_climb_params);
	ClassDB::bind_method(D_METHOD("is_elevated_at", "p"), &SwarmCore::is_elevated_at);
	ClassDB::bind_method(D_METHOD("is_reachable_at", "p"), &SwarmCore::is_reachable_at);
	ClassDB::bind_method(D_METHOD("is_blocked_at", "p"), &SwarmCore::is_blocked_at);
	ClassDB::bind_method(D_METHOD("is_solid_at", "p"), &SwarmCore::is_solid_at);
	ClassDB::bind_method(D_METHOD("set_corpse_hp", "hp"), &SwarmCore::set_corpse_hp);
	ClassDB::bind_method(D_METHOD("get_climb_structs"), &SwarmCore::get_climb_structs);
	ClassDB::bind_method(D_METHOD("get_climb_debug"), &SwarmCore::get_climb_debug);
	ClassDB::bind_method(D_METHOD("get_climb_spots"), &SwarmCore::get_climb_spots);
	ClassDB::bind_method(D_METHOD("get_tier_counts"), &SwarmCore::get_tier_counts);
	ClassDB::bind_method(D_METHOD("get_alive_count"), &SwarmCore::get_alive_count);
	ClassDB::bind_method(D_METHOD("get_visible_count"), &SwarmCore::get_visible_count);
	ClassDB::bind_method(D_METHOD("get_last_tick_ms"), &SwarmCore::get_last_tick_ms);
	ClassDB::bind_method(D_METHOD("get_last_render_ms"), &SwarmCore::get_last_render_ms);
	ClassDB::bind_method(D_METHOD("make_handle", "i"), &SwarmCore::make_handle);
	ClassDB::bind_method(D_METHOD("is_handle_live", "handle"), &SwarmCore::is_handle_live);
	ClassDB::bind_method(D_METHOD("get_agent_state", "handle"), &SwarmCore::get_agent_state);
	ClassDB::bind_method(D_METHOD("release_agent", "handle"), &SwarmCore::release_agent);
	ClassDB::bind_method(D_METHOD("query_cone_handle", "from", "dir", "half_angle", "max_range"), &SwarmCore::query_cone_handle);
}

// -------------------------------------------------------------------- lifecycle
void SwarmCore::_ready() {
	// Pool: push every index onto the free stack (§2.2).
	_free_top = MAX_AGENTS;
	for (int i = 0; i < MAX_AGENTS; i++) {
		_free[i] = MAX_AGENTS - 1 - i; // pop() hands out low indices first
		_flags[i] = 0;
		_kind[i] = KIND_OBJECT;
		_generation[i] = 0;
		_lean[i] = 0.0f;
		_climb_slot[i] = -1;
		_climb_struct[i] = -1;
		_climb_prog[i] = 0.0f;
		_node_slot[i] = -1;
		_jam[i] = 0.0f;
		_cmd_speed[i] = 0.0f;
		_stuck_t[i] = 0.0f;
		_fall_v[i] = 0.0f;
		_tscale[i] = 1.0f;   // queried before the first tick otherwise
		_anim_phase[i] = (float)((i * 2654435761u) & 1023) / 1023.0f;
	}
	for (int s = 0; s < MAX_NODES; s++) _slot_agent[s] = -1;
	_alive_count = 0;

	// Hash grid sized around the origin.
	float half = _grid_dim * _cell_size * 0.5f;
	_grid_origin = Vector3(-half, 0.0f, -half);
	_cell_count = _grid_dim * _grid_dim;
	_cell_start.assign(_cell_count, 0);
	_cell_fill.assign(_cell_count, 0);
	_rank.reserve(MAX_AGENTS);

	// Flow-field grid: finer than the hash grid, same extent (§5.7).
	int sub = (int)(_cell_size / _fcs);
	if (sub < 1) sub = 1;
	_fdim = _grid_dim * sub;
	_forigin = _grid_origin;
	_fcell = _fdim * _fdim;
	_cost.assign(_fcell, INF_COST);
	_cost_b.assign(_fcell, INF_COST);
	_dirx.assign(_fcell, 0.0f);
	_dirx_b.assign(_fcell, 0.0f);
	_dirz.assign(_fcell, 0.0f);
	_dirz_b.assign(_fcell, 0.0f);
	_reach.assign(_fcell, 0);
	_reach_b.assign(_fcell, 0);
	_blocked.assign(_fcell, 0);
	_pile_h_field.assign(_fcell, 0.0f);
	_occ.assign(_fcell, 0);
	_snap_pos.assign(MAX_AGENTS, Vector3());

	_build_render();
	set_process(true);
}

uint32_t SwarmCore::_rand_u32() const {
	uint64_t z = (_rng_state += 0x9E3779B97F4A7C15ull);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	return (uint32_t)((z ^ (z >> 31)) >> 32);
}

float SwarmCore::_rand01() const {
	return (float)(_rand_u32() >> 8) * (1.0f / 16777216.0f);
}

void SwarmCore::set_seed(int64_t seed) {
	_rng_state = (uint64_t)seed ^ 0x9E3779B97F4A7C15ull;
}

void SwarmCore::configure(int target_population, float cell_size, int grid_dim) {
	_target_population = target_population;
	if (cell_size > 0.0f) _cell_size = cell_size;
	if (grid_dim > 0) _grid_dim = grid_dim;
}

// Build one MultiMesh layer. Called once for the placeholder capsule, and again for each
// baked pose when the level hands over real geometry.
void SwarmCore::_build_mesh_layer(const Ref<Mesh> &mesh, int count) {
	Ref<MultiMesh> mm;
	mm.instantiate();
	mm->set_transform_format(MultiMesh::TRANSFORM_3D);
	mm->set_use_colors(true);
	mm->set_use_custom_data(false);
	mm->set_mesh(mesh);
	mm->set_instance_count(count);
	mm->set_visible_instance_count(0);

	MultiMeshInstance3D *mmi = memnew(MultiMeshInstance3D);
	mmi->set_name(String("SwarmMultiMesh") + String::num_int64((int64_t)_mmis.size()));
	mmi->set_multimesh(mm);
	add_child(mmi);

	PackedFloat32Array buf;
	buf.resize(count * MM_STRIDE);

	_mms.push_back(mm);
	_mmis.push_back(mmi);
	_mm_buffers.push_back(buf);
}

void SwarmCore::_build_render() {
	Ref<CapsuleMesh> mesh;
	mesh.instantiate();
	mesh->set_radius(0.35f);
	mesh->set_height(1.7f);

	Ref<StandardMaterial3D> mat;
	mat.instantiate();
	mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true); // per-instance tier colour
	mat->set_roughness(0.85f);
	mesh->surface_set_material(0, mat);

	_build_mesh_layer(mesh, MAX_AGENTS);

	// Corpse layer: its own buffer, written only when a pile changes rather than every frame.
	// Nothing in the tick loop ever touches these.
	Ref<StandardMaterial3D> cmat;
	cmat.instantiate();
	cmat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
	cmat->set_roughness(0.95f);

	Ref<CapsuleMesh> cmesh;
	cmesh.instantiate();
	cmesh->set_radius(0.35f);
	cmesh->set_height(1.7f);
	cmesh->surface_set_material(0, cmat);

	_cmm.instantiate();
	_cmm->set_transform_format(MultiMesh::TRANSFORM_3D);
	_cmm->set_use_colors(true);
	_cmm->set_mesh(cmesh);
	_cmm->set_instance_count(MAX_CORPSES);
	_cmm->set_visible_instance_count(0);
	_cmm_buffer.resize(MAX_CORPSES * MM_STRIDE);

	_cmmi = memnew(MultiMeshInstance3D);
	_cmmi->set_name("CorpseMultiMesh");
	_cmmi->set_multimesh(_cmm);
	add_child(_cmmi);

	// Ghost layer (GDD2 §4). Placeholder is a translucent unshaded blob — the same read as
	// the node side's raw spirit, so a promoted ghost does not change appearance at the
	// handover. Alpha comes per-instance from the health fraction, so a draining wave
	// visibly thins out.
	Ref<StandardMaterial3D> gmat;
	gmat.instantiate();
	gmat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
	gmat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
	gmat->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);
	gmat->set_albedo(Color(0.55f, 0.9f, 1.0f, 0.55f));
	gmat->set_feature(BaseMaterial3D::FEATURE_EMISSION, true);
	gmat->set_emission(Color(0.4f, 0.85f, 1.0f));
	gmat->set_emission_energy_multiplier(1.6f);

	Ref<SphereMesh> gmesh;
	gmesh.instantiate();
	gmesh->set_radius(0.32f);
	gmesh->set_height(0.9f);
	gmesh->surface_set_material(0, gmat);
	_ghost_mesh = gmesh;

	_gmm.instantiate();
	_gmm->set_transform_format(MultiMesh::TRANSFORM_3D);
	_gmm->set_use_colors(true);
	_gmm->set_mesh(_ghost_mesh);
	_gmm->set_instance_count(MAX_AGENTS);
	_gmm->set_visible_instance_count(0);
	_gmm_buffer.resize(MAX_AGENTS * MM_STRIDE);

	_gmmi = memnew(MultiMeshInstance3D);
	_gmmi->set_name("GhostMultiMesh");
	_gmmi->set_multimesh(_gmm);
	add_child(_gmmi);
}

// Replace the placeholder capsule with geometry baked off the real rig (§4.2-lite). Two pose
// sets so the crowd's gait matches what the close-up actors are doing: agents under run_speed
// use the walk bake, the rest the run bake. Without that split a walking distant horde reads
// against sprinting near one, which is exactly the sort of seam a player notices.
void SwarmCore::set_instance_meshes(const Array &walk_poses, const Array &run_poses, const Ref<Mesh> &corpse,
		float stand_y_off, float prone_y_off, float run_speed) {
	_stand_y_off = stand_y_off;
	_prone_y_off = prone_y_off;
	if (run_speed > 0.0f) _run_speed = run_speed;

	int per = (int)walk_poses.size();
	if (per > 0) {
		for (size_t k = 0; k < _mmis.size(); k++) {
			remove_child(_mmis[k]);
			memdelete(_mmis[k]);
		}
		_mmis.clear();
		_mms.clear();
		_mm_buffers.clear();

		// Run set falls back to the walk set if the level only supplied one gait.
		bool has_run = run_poses.size() == walk_poses.size();
		for (int k = 0; k < per; k++) {
			Ref<Mesh> m = walk_poses[k];
			if (m.is_valid()) _build_mesh_layer(m, MAX_AGENTS);
		}
		for (int k = 0; k < per; k++) {
			Ref<Mesh> m = has_run ? Ref<Mesh>(run_poses[k]) : Ref<Mesh>(walk_poses[k]);
			if (m.is_valid()) _build_mesh_layer(m, MAX_AGENTS);
		}
		_poses_per_set = per;
		_mm_sets = 2;
		if ((int)_mmis.size() != per * 2) { // something was junk — start over with the capsule
			for (size_t k = 0; k < _mmis.size(); k++) { remove_child(_mmis[k]); memdelete(_mmis[k]); }
			_mmis.clear(); _mms.clear(); _mm_buffers.clear();
			_poses_per_set = 1;
			_mm_sets = 1;
			_stand_y_off = 0.9f;
			_prone_y_off = 0.35f;
			_build_render();
		}
	}
	if (corpse.is_valid() && _cmm.is_valid()) _cmm->set_mesh(corpse);
}

// --------------------------------------------------------------- corpse layer
void SwarmCore::_add_corpse(const Vector3 &p, float yaw, int group) {
	if ((int)_corpses.size() >= MAX_CORPSES) return;
	Corpse c;
	c.pos = p;
	c.yaw = yaw;
	c.group = group;
	c.hp = _corpse_hp;
	_corpses.push_back(c);
	_corpse_vis.push_back(1);
	_corpses_dirty = true;
	_corpse_rev++;
	_pile_mask_dirty = true;
}

// A corpse packed in on every side by other corpses cannot be seen from anywhere, so it is
// never written to the buffer. Runs per group when that group grows — an event, not per frame.
void SwarmCore::_revis_group(int group) {
	std::vector<int> idx;
	for (size_t i = 0; i < _corpses.size(); i++)
		if (_corpses[i].group == group) idx.push_back((int)i);
	// Mound-mesh mode: the pile IS the mound. No corpse is drawn as a body at all.
	//
	// Drawing the crest layer as real bodies meant a rendered corpse and a generated surface had
	// to agree on where the top of a heap was, through a blur, a sink and a prone draw offset —
	// they never quite did, and every disagreement showed up as a zombie hovering in the air.
	// A heap of dead is bulk with limbs sticking out of it, not a stack of intact posed bodies;
	// the level layer scatters those limbs onto the surface it just built, where they cannot
	// possibly float because it read the height off the same field.
	if (_pile_mesh_mode) {
		for (size_t a = 0; a < idx.size(); a++) _corpse_vis[idx[a]] = 0;
		_corpses_dirty = true;
		return;
	}
	float r2 = (_slot_pitch * 1.25f) * (_slot_pitch * 1.25f);
	for (size_t a = 0; a < idx.size(); a++) {
		int n = 0;
		bool above = false;
		const Vector3 &p = _corpses[idx[a]].pos;
		for (size_t b = 0; b < idx.size(); b++) {
			if (a == b) continue;
			const Vector3 &q = _corpses[idx[b]].pos;
			if (p.distance_squared_to(q) > r2) continue;
			n++;
			if (q.y > p.y + 0.3f) above = true;
		}
		// Buried needs both: hemmed in, and something actually lying on top of it.
		_corpse_vis[idx[a]] = (n >= 7 && above) ? 0 : 1;
	}
	_corpses_dirty = true;
}

void SwarmCore::_write_corpses() {
	float *buf = _cmm_buffer.ptrw();
	int w = 0;
	const Color col(0.30f, 0.26f, 0.24f);
	for (size_t i = 0; i < _corpses.size(); i++) {
		if (!_corpse_vis[i]) continue;
		Vector3 p = _corpses[i].pos + Vector3(0, _prone_y_off, 0); // lying down
		Basis b = Basis(Vector3(0, 1, 0), _corpses[i].yaw) * Basis(Vector3(1, 0, 0), 1.5708f);
		int o = w * MM_STRIDE;
		buf[o + 0] = b[0][0]; buf[o + 1] = b[0][1]; buf[o + 2] = b[0][2]; buf[o + 3] = p.x;
		buf[o + 4] = b[1][0]; buf[o + 5] = b[1][1]; buf[o + 6] = b[1][2]; buf[o + 7] = p.y;
		buf[o + 8] = b[2][0]; buf[o + 9] = b[2][1]; buf[o + 10] = b[2][2]; buf[o + 11] = p.z;
		buf[o + 12] = col.r; buf[o + 13] = col.g; buf[o + 14] = col.b; buf[o + 15] = 1.0f;
		w++;
	}
	_cmm->set_buffer(_cmm_buffer);
	_cmm->set_visible_instance_count(w);
	_corpse_visible = w;
	_corpses_dirty = false;
}

// Blow bodies out of a mound. Bullets can't do this — a hitscan resolves against the agent
// array and corpses have left it — but an explosion can, which puts the §6.5 counter-play back:
// grenade the foot of a pile and the cells it held go free, the crest recomputes lower on the
// next tick, and any climber that can no longer reach the lip slides back down.
// Corpses sit exactly on their lattice cell, so position alone matches the two up.
int SwarmCore::_blast_corpses(const Vector3 &c, float r, float dmg) {
	float r2 = r * r;
	int n = 0;
	std::vector<int> touched;
	for (int i = (int)_corpses.size() - 1; i >= 0; i--) {
		float d2 = _corpses[i].pos.distance_squared_to(c);
		if (d2 > r2) continue;
		// Falloff, so a blast scoops a crater out of the mound instead of levelling a sphere of
		// it. A pile's toughness is its body count, so its height IS its health: chew enough
		// bodies out of the bottom and the whole thing settles.
		float falloff = 1.0f - std::sqrt(d2) / (r > 0.001f ? r : 1.0f);
		_corpses[i].hp -= dmg * falloff;
		if (_corpses[i].hp > 0.0f) continue;
		_push_death(_corpses[i].pos + Vector3(0, 0.35f, 0)); // gib VFX through the usual queue
		int g = _corpses[i].group;
		bool seen = false;
		for (size_t t = 0; t < touched.size(); t++)
			if (touched[t] == g) { seen = true; break; }
		if (!seen) touched.push_back(g);
		_corpses.erase(_corpses.begin() + i);
		_corpse_vis.erase(_corpse_vis.begin() + i);
		n++;
	}
	if (n == 0) return 0;
	// Hand the cells back, so the horde can rebuild through the hole it just took.
	for (size_t k = 0; k < _structs.size(); k++) {
		ClimbStructure &S = _structs[k];
		for (size_t s = 0; s < S.slot_owner.size(); s++) {
			if (S.slot_owner[s] != CORPSE_SLOT) continue;
			if (S.slot_pos[s].distance_squared_to(c) > r2) continue;
			S.slot_owner[s] = -1;
			if (S.buried > 0) S.buried--;
		}
	}
	for (size_t t = 0; t < touched.size(); t++) _revis_group(touched[t]);
	_corpses_dirty = true;
	_corpse_rev++;
	_pile_mask_dirty = true;
	return n;
}

void SwarmCore::set_pile_mesh_mode(bool on) {
	_pile_mesh_mode = on;
	std::vector<int> seen;
	for (size_t i = 0; i < _corpses.size(); i++) {
		bool have = false;
		for (size_t g = 0; g < seen.size(); g++)
			if (seen[g] == _corpses[i].group) { have = true; break; }
		if (!have) seen.push_back(_corpses[i].group);
	}
	for (size_t g = 0; g < seen.size(); g++) _revis_group(seen[g]);
	_corpse_rev++;
}

// Every body position, grouped by pile. The level turns each group into a mound surface — the
// pile stops being a loose scatter of instances and becomes a thing with a top you can stand on.
Array SwarmCore::get_pile_fields() const {
	Array out;
	std::vector<int> groups;
	for (size_t i = 0; i < _corpses.size(); i++) {
		bool seen = false;
		for (size_t g = 0; g < groups.size(); g++)
			if (groups[g] == _corpses[i].group) { seen = true; break; }
		if (!seen) groups.push_back(_corpses[i].group);
	}
	// A pile's crest layer is still live agents, not corpses yet. They have to feed the mound as
	// well, or the surface stops one layer short of the top of the heap and whatever is standing
	// up there has nothing under it.
	for (size_t k = 0; k < _structs.size(); k++) {
		bool have = false;
		for (size_t g = 0; g < groups.size(); g++)
			if (groups[g] == _structs[k].group) { have = true; break; }
		if (!have && _structs[k].filled > 0) groups.push_back(_structs[k].group);
	}
	for (size_t g = 0; g < groups.size(); g++) {
		PackedVector3Array pts;
		for (size_t i = 0; i < _corpses.size(); i++)
			if (_corpses[i].group == groups[g]) pts.push_back(_corpses[i].pos);
		for (int i = 0; i < MAX_AGENTS; i++) {
			if ((_flags[i] & FLAG_ALIVE) == 0 || _state[i] != ST_FROZEN) continue;
			int ki = _climb_struct[i];
			if (ki < 0 || ki >= (int)_structs.size()) continue;
			if (_structs[ki].group == groups[g]) pts.push_back(_position[i]);
		}
		Dictionary d;
		d["group"] = groups[g];
		d["points"] = pts;
		out.push_back(d);
	}
	return out;
}

// One box per corpse group, so the level can drop a StaticBody3D there: the mound is real
// geometry the player can walk up, not just a picture of one.
Array SwarmCore::get_pile_shapes() const {
	Array out;
	std::vector<int> groups;
	for (size_t i = 0; i < _corpses.size(); i++) {
		bool seen = false;
		for (size_t g = 0; g < groups.size(); g++)
			if (groups[g] == _corpses[i].group) { seen = true; break; }
		if (!seen) groups.push_back(_corpses[i].group);
	}
	for (size_t g = 0; g < groups.size(); g++) {
		Vector3 lo(1e9f, 1e9f, 1e9f), hi(-1e9f, -1e9f, -1e9f);
		int n = 0;
		for (size_t i = 0; i < _corpses.size(); i++) {
			if (_corpses[i].group != groups[g]) continue;
			const Vector3 &p = _corpses[i].pos;
			lo.x = std::min(lo.x, p.x); lo.y = std::min(lo.y, p.y); lo.z = std::min(lo.z, p.z);
			hi.x = std::max(hi.x, p.x); hi.y = std::max(hi.y, p.y); hi.z = std::max(hi.z, p.z);
			n++;
		}
		if (n == 0) continue;
		Vector3 pad(_agent_radius, 0.0f, _agent_radius);
		lo -= pad;
		hi += pad + Vector3(0, _layer_h, 0);
		lo.y = 0.0f;
		Dictionary d;
		d["center"] = (lo + hi) * 0.5f;
		d["size"] = hi - lo;
		d["bodies"] = n;
		d["group"] = groups[g];
		out.push_back(d);
	}
	return out;
}

// ------------------------------------------------------------------- boundary
void SwarmCore::set_goal_position(const Vector3 &p) {
	_goal_pos = Vector3(p.x, 0.0f, p.z);
	_player_pos = p; // full 3D: the climb system decides for itself whether the player is out of reach
	_has_goal = true;
}

void SwarmCore::set_camera_position(const Vector3 &p) { _camera_pos = p; }

void SwarmCore::_spawn_one(int i, const Vector3 &pos, float hp, uint8_t kind) {
	Vector3 g = pos;
	// A body is modelled at its feet and belongs on the floor. A spirit floats, and it
	// arrived by phasing through a wall, so wherever the caller put it is where it is.
	g.y = (kind == KIND_GHOST) ? std::max(pos.y, _ghost_hover) : 0.0f;
	_position[i] = g;
	_prev_position[i] = g;
	_velocity[i] = Vector3();
	_yaw[i] = 0.0f;
	_lean[i] = 0.0f;
	_tier[i] = TIER_FAR;
	_state[i] = ST_GROUND;
	_kind[i] = kind;
	_climb_slot[i] = -1;
	_climb_prog[i] = 0.0f;
	_lane_edge[i] = -1;
	_lane_dist[i] = 0.0f;
	_lane_lat[i] = 0.0f;
	_flags[i] = FLAG_ALIVE;
	_health[i] = hp;
	_max_health[i] = hp;
	_alive_count++;
	if (kind == KIND_GHOST) _ghost_count++;
}

void SwarmCore::spawn_batch(const PackedVector3Array &positions, float hp) {
	int n = positions.size();
	for (int k = 0; k < n; k++) {
		if (_free_top <= 0) return; // pool exhausted
		_spawn_one(_free[--_free_top], positions[k], hp, KIND_OBJECT);
	}
}

// An outbreak wave (GDD2 §4). Sirens, then spirits come through the exterior walls from
// all 360 degrees — so the caller places them wherever it likes, including inside
// geometry, and they fly in from there.
void SwarmCore::spawn_ghost_batch(const PackedVector3Array &positions, float hp) {
	int n = positions.size();
	for (int k = 0; k < n; k++) {
		if (_free_top <= 0) return;
		_spawn_one(_free[--_free_top], positions[k], hp, KIND_GHOST);
	}
}

// ============================ ST_LANE: the defense case ============================
//
// See the block comment on the lane members in swarm_core.h for why this is a separate
// state rather than a tuning of the flow field, and for the two follow-rule fixes it
// carries over from scripts/td/lane_walker.gd. The two must not drift apart.

// Seconds of travel to aim ahead by. Too small and the walker saws across the centreline on
// curves; too large and it cuts the corners off the lane entirely.
static const float LANE_LOOKAHEAD_T = 0.55f;
static const float LANE_LOOKAHEAD_MIN = 1.2f;
static const float LANE_LOOKAHEAD_MAX = 4.0f;
// Base arrival ring. The walker's own |lateral| is ADDED to this — see _lane_move.
static const float LANE_ARRIVE_R = 1.1f;
// Dragged this far off its lane (beyond its own offset) and it re-queries the graph rather
// than steering at a target it has been pulled away from.
static const float LANE_REJOIN = 2.5f;
// Ease off over the last stride so a walker settles against a barricade instead of
// jittering back and forth across its stop line.
static const float LANE_EASE = 0.6f;

void SwarmCore::set_lane_graph(const Ref<LaneGraph> &g) {
	_lanes = g;
	int ec = g.is_valid() ? g->edge_count() : 0;
	int nc = g.is_valid() ? g->node_count() : 0;
	_lane_live.assign(ec, 1);
	_obj_hits.assign(nc, 0);
	// Editing a graph renumbers edges, so every walker's route is now a guess. -1 makes each
	// one rejoin from where it stands on its next tick, which is the same recovery the beam
	// already uses and is strictly better than routing confidently down a stale index.
	for (int i = 0; i < MAX_AGENTS; i++) {
		if (_state[i] == ST_LANE) _lane_edge[i] = -1;
	}
}

void SwarmCore::set_lane_speed(float s) { if (s > 0.0f) _lane_speed = s; }

void SwarmCore::set_lane_blockers(const PackedInt32Array &edges, const PackedFloat32Array &dists) {
	_blk_edge = edges;
	_blk_dist = dists;
	int n = std::min(_blk_edge.size(), _blk_dist.size());
	_blk_hits.assign(n, 0);
}

void SwarmCore::set_lane_live(const PackedByteArray &per_edge) {
	int n = per_edge.size();
	_lane_live.assign(n, 1);
	for (int e = 0; e < n; e++) _lane_live[e] = per_edge[e] ? 1 : 0;
}

PackedInt32Array SwarmCore::get_lane_blocker_attackers() const {
	PackedInt32Array out;
	out.resize((int)_blk_hits.size());
	for (int k = 0; k < (int)_blk_hits.size(); k++) out.set(k, _blk_hits[k]);
	return out;
}

PackedInt32Array SwarmCore::get_lane_objective_attackers() const {
	PackedInt32Array out;
	out.resize((int)_obj_hits.size());
	for (int k = 0; k < (int)_obj_hits.size(); k++) out.set(k, _obj_hits[k]);
	return out;
}

void SwarmCore::spawn_lane_batch(const PackedVector3Array &positions, float hp, int door_node) {
	if (_lanes.is_null()) return;
	int n = positions.size();
	for (int k = 0; k < n; k++) {
		if (_free_top <= 0) return; // pool exhausted
		int i = _free[--_free_top];
		_spawn_one(i, positions[k], hp, KIND_OBJECT);
		_state[i] = ST_LANE;
		_lane_count++;
		int e = door_node >= 0 ? _lane_pick_edge(door_node) : _lane_nearest_edge(_position[i]);
		// A doorway wired to nothing leaves the row on the lane state with no route; it
		// rejoins from where it stands on its next tick rather than being deleted, because a
		// body vanishing on spawn is far harder to diagnose than one standing in a doorway.
		if (e >= 0) _lane_enter(i, e, _lanes->edge_offset_of(e, _position[i]));
	}
}

int SwarmCore::lane_convert_in_box(const Vector3 &center, const Vector3 &half_extents,
		int door_node) {
	if (_lanes.is_null()) return 0;
	int converted = 0;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		// Only bodies that are simply walking. A climber halfway up a pile, a frozen body that
		// IS the pile, and a spirit that phases through walls are all mid-commitment to
		// something else — pulling any of them onto a lane would teleport a structure's brick
		// out of it.
		if (_state[i] != ST_GROUND) continue;
		if (_kind[i] != KIND_OBJECT) continue;
		const Vector3 &p = _position[i];
		if (Math::abs(p.x - center.x) > half_extents.x) continue;
		if (Math::abs(p.y - center.y) > half_extents.y) continue;
		if (Math::abs(p.z - center.z) > half_extents.z) continue;

		int e = door_node >= 0 ? _lane_pick_edge(door_node) : _lane_nearest_edge(p);
		if (e < 0) continue;   // no route here yet: leave it walking, try again next tick
		_state[i] = ST_LANE;
		_lane_count++;
		_lane_enter(i, e, _lanes->edge_offset_of(e, p));
		converted++;
	}
	return converted;
}

// Fixed for the whole edge, and re-rolled per edge because lanes differ in width. This is
// what stops a conga line: twelve walkers on one curve go abreast across the lane rather
// than nose to tail, and it is also why the arrival ring has to clear it.
void SwarmCore::_lane_enter(int i, int e, float at) {
	_lane_edge[i] = e;
	_lane_dist[i] = at;
	float w = _lanes->edge_width(e);
	_lane_lat[i] = (_rand01() * 2.0f - 1.0f) * w * 0.85f;
}

// Weighted branch pick, skipping branches that no longer lead to anything alive. Falls back
// to the unfiltered answer when the filter rejects everything, so a walker is never left
// with no lane at all.
int SwarmCore::_lane_pick_edge(int node) const {
	if (_lanes.is_null()) return -1;
	PackedInt32Array es = _lanes->outgoing(node);
	float total = 0.0f;
	int live = 0;
	for (int k = 0; k < es.size(); k++) {
		if (!_edge_is_live(es[k])) continue;
		live++;
		total += _lanes->edge_weight(es[k]);
	}
	if (live == 0) return _lanes->next_edge(node, _rand01());
	if (total <= 0.0f) {
		int want = (int)(_rand01() * live);
		for (int k = 0; k < es.size(); k++) {
			if (!_edge_is_live(es[k])) continue;
			if (want-- <= 0) return es[k];
		}
	}
	float pick = _rand01() * total;
	float acc = 0.0f;
	int last = -1;
	for (int k = 0; k < es.size(); k++) {
		if (!_edge_is_live(es[k])) continue;
		last = es[k];
		acc += _lanes->edge_weight(es[k]);
		if (pick <= acc) return es[k];
	}
	return last;
}

int SwarmCore::_lane_nearest_edge(const Vector3 &p) const {
	if (_lanes.is_null()) return -1;
	int best = -1;
	float best_d = 1e30f;
	for (int e = 0; e < _lanes->edge_count(); e++) {
		if (_lanes->edge_length(e) <= 0.0f || !_edge_is_live(e)) continue;
		float d = _lanes->edge_closest_point(e, p).distance_squared_to(p);
		if (d < best_d) { best_d = d; best = e; }
	}
	if (best >= 0) return best;
	Dictionary n = _lanes->nearest(p);
	return n.has("edge") ? (int)n["edge"] : -1;
}

int SwarmCore::_blocker_ahead(int e, float from_d, float *out_stop) const {
	int found = -1;
	float best = 1e30f;
	int n = std::min(_blk_edge.size(), _blk_dist.size());
	for (int k = 0; k < n; k++) {
		if (_blk_edge[k] != e) continue;
		float at = _blk_dist[k];
		// `- 0.05` so a walker already settled ON its stop line still sees the wall it is
		// hitting; without the slack it steps past by a hair and the queue walks through.
		if (at < from_d - 0.05f || at >= best) continue;
		best = at;
		found = k;
	}
	if (found >= 0 && out_stop) *out_stop = best;
	return found;
}

void SwarmCore::_lane_move(int i, float dt) {
	if (_lanes.is_null()) { _state[i] = ST_GROUND; if (_lane_count > 0) _lane_count--; return; }
	Vector3 p = _position[i];

	// No route (fresh from a doorway wired to nothing, or the graph was re-bound under it).
	if (_lane_edge[i] < 0) {
		int e0 = _lane_nearest_edge(p);
		if (e0 < 0) { _prev_position[i] = p; _velocity[i] = Vector3(); return; }
		_lane_enter(i, e0, _lanes->edge_offset_of(e0, p));
	}

	// Dragged clear of its lane — by the vacuum beam, by an explosion, by the crowd. Re-query
	// rather than steer at a target it is no longer anywhere near.
	{
		int e = _lane_edge[i];
		Vector3 on = _lanes->sample_dist(e, _lane_dist[i]);
		// FULL 3D. A bridge and the road under it are the same point in plan view, so a flat
		// test can never tell a walker on one from a walker on the other — and the body is
		// held at the lane's own height below, so the vertical term is meaningful rather than
		// a constant offset that would trip a rejoin every tick.
		float off = (float)p.distance_to(on);
		if (off > LANE_REJOIN + std::abs(_lane_lat[i])) {
			int e2 = _lane_nearest_edge(p);
			if (e2 >= 0) _lane_enter(i, e2, _lanes->edge_offset_of(e2, p));
		}
	}

	// PROGRESS IS WHERE THE BODY IS, NOT HOW FAR IT HAS WALKED, and it only ever climbs. A
	// lane that doubles back near itself can project a body onto a later part of the same
	// curve; taking the max reads that as a shortcut rather than as a walker teleporting
	// backwards, which is the version that actually looks broken on screen.
	int e = _lane_edge[i];
	float proj = _lanes->edge_offset_of(e, p);
	if (proj > _lane_dist[i]) _lane_dist[i] = proj;

	// Arrival, and the junction chain behind it. Bounded: zero-length or stacked edges could
	// otherwise chain forever inside one tick.
	bool holding = false;
	for (int guard = 0; guard < 8; guard++) {
		float len = _lanes->edge_length(e);
		int node = _lanes->edge_to(e);
		Vector3 end = _lanes->node_position(node);
		float to_end = (float)p.distance_to(end);
		// THE RING MUST CLEAR THE WALKER'S OWN OFFSET. Its last steering target sits
		// |lateral| metres beside the end node on purpose, so a fixed radius under the widest
		// offset leaves it orbiting the node forever.
		if (to_end > LANE_ARRIVE_R + std::abs(_lane_lat[i]) && _lane_dist[i] < len - 0.05f) break;

		if (_lanes->node_kind(node) == LaneGraph::NODE_OBJECTIVE) {
			if (node >= 0 && node < (int)_obj_hits.size()) _obj_hits[node]++;
			holding = true;
			break;
		}
		int nxt = _lane_pick_edge(node);
		if (nxt < 0) {
			// A dead end that is not an objective. Stand rather than teleport; validate() is
			// what should have caught this at author time.
			holding = true;
			break;
		}
		_lane_enter(i, nxt, _lanes->edge_offset_of(nxt, p));
		e = _lane_edge[i];
	}

	// A barricade caps how far along the lane the aim point may sit. Without the cap the
	// lookahead target sits BEYOND the wall, so a walker halted at it still leans through and
	// the barricade reads as porous.
	float cap = _lanes->edge_length(e);
	if (!holding) {
		float stop = 0.0f;
		int blk = _blocker_ahead(e, _lane_dist[i], &stop);
		if (blk >= 0) {
			cap = std::min(cap, stop);
			if (_lane_dist[i] >= stop - 0.15f) {
				if (blk < (int)_blk_hits.size()) _blk_hits[blk]++;
				holding = true;
			}
		}
	}

	Vector3 np = p;
	if (!holding) {
		float ahead = std::min(std::max(_lane_speed * LANE_LOOKAHEAD_T, LANE_LOOKAHEAD_MIN),
				LANE_LOOKAHEAD_MAX);
		float td = std::min(_lane_dist[i] + ahead, cap);
		Vector3 target = _lanes->sample_dist(e, td) + _lanes->right_dist(e, td) * _lane_lat[i];
		Vector3 to = target - p;
		to.y = 0.0f;
		float reach = to.length();
		if (reach > 1e-3f) {
			float sp = _lane_speed * std::min(reach / LANE_EASE, 1.0f);
			np = p + to / reach * std::min(sp * dt, reach);
		}
		_turn_toward(i, to);
	}

	// THE LANE IS THE WALKABLE SURFACE. Flattening to y=0 was the flat-level shortcut, and it
	// is what made two stacked routes indistinguishable — every walker on the bridge stood in
	// the road. Steering stays horizontal (above); height is something to be PLACED at, not
	// steered toward, or a walker bobs on every slope.
	//
	// Eased rather than snapped so a curve baked at 0.25 m does not read as a staircase.
	{
		const float want_y = _lanes->sample_dist(e, _lane_dist[i]).y;
		np.y = p.y + (want_y - p.y) * std::min(1.0f, 8.0f * dt);
	}
	_prev_position[i] = p;
	_position[i] = np;
	_velocity[i] = dt > 0.0f ? (np - p) / dt : Vector3();
	_cmd_speed[i] = holding ? 0.0f : _lane_speed;
	_anim_phase[i] += _phase_rate * (holding ? 0.0f : 1.0f) * dt;
	if (_anim_phase[i] >= 1.0f) _anim_phase[i] -= 1.0f;
}

void SwarmCore::set_ghost_params(float speed, float hover, float bob) {
	if (speed > 0.0f) _ghost_speed = speed;
	if (hover >= 0.0f) _ghost_hover = hover;
	if (bob >= 0.0f) _ghost_bob = bob;
}

int SwarmCore::make_handle(int i) const { return (i << 8) | int(_generation[i]); }

bool SwarmCore::is_handle_live(int handle) const {
	int i = handle >> 8;
	if (i < 0 || i >= MAX_AGENTS) return false;
	return (_flags[i] & FLAG_ALIVE) != 0 && int(_generation[i]) == (handle & 0xFF);
}

// --- Promotion: hand one agent over to the node world -----------------------------

Dictionary SwarmCore::get_agent_state(int handle) const {
	Dictionary d;
	if (!is_handle_live(handle)) return d;   // stale handle -> empty, never a half-state
	int i = handle >> 8;
	d["position"] = _position[i];
	d["velocity"] = _velocity[i];
	d["yaw"] = _yaw[i];
	d["lean"] = _lean[i];
	d["health"] = _health[i];
	d["max_health"] = _max_health[i];
	d["state"] = (int)_state[i];
	d["tier"] = (int)_tier[i];
	// Which SCENE to promote into. A spirit becomes a naked BaseGhost (no prop, one
	// ectoplasm layer); a body becomes the ordinary node enemy. Without this the promoter
	// would have to guess, and it would guess wrong exactly during an outbreak wave.
	d["kind"] = (int)_kind[i];
	// Carried so a promoted enemy resumes mid-stride instead of snapping to a bind pose
	// — the same continuity rule the tier 0-1 actor pool follows on slot handover.
	d["anim_phase"] = _anim_phase[i];
	d["time_scale"] = _tscale[i];
	// The row is modelled at the feet; node enemies usually want the body centre too.
	d["body_center"] = _position[i] + _body_center;
	return d;
}

bool SwarmCore::release_agent(int handle) {
	if (!is_handle_live(handle)) return false;
	// _kill() frees the pool slot, hands back any pile slot it held, and bumps the
	// generation so every other copy of this handle goes stale. It does NOT push a
	// death event — that is deliberate here: promotion is not a death, and firing the
	// gore path would spend the effect budget on an enemy that is still alive.
	_kill(handle >> 8);
	return true;
}

int SwarmCore::query_cone_handle(const Vector3 &from, const Vector3 &dir, float half_angle,
		float max_range) const {
	Vector3 d = dir.normalized();
	float cos_half = std::cos(half_angle);
	float best = max_range * max_range;
	int best_i = -1;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		// Frozen bodies are pile structure, not enemies. Promoting one would pull a
		// brick out of a ramp that other agents are standing on.
		if (_state[i] == ST_FROZEN) continue;
		Vector3 to = (_position[i] + _body_center) - from;
		float dist2 = to.length_squared();
		if (dist2 > best || dist2 < 0.0001f) continue;
		if (to.normalized().dot(d) < cos_half) continue;
		best = dist2;
		best_i = i;
	}
	return best_i < 0 ? -1 : make_handle(best_i);
}

void SwarmCore::_kill(int i) {
	if ((_flags[i] & FLAG_ALIVE) == 0) return;
	// Hand back the pile slot it held or had reserved. Shooting bodies out of a pile lowers its
	// crest on the next tick, and a climber that can no longer clear the lip slides back down —
	// the ramp visibly fails, which is the §6.5 counter-play.
	int k = _climb_struct[i];
	if (k >= 0 && k < (int)_structs.size()) {
		int s = _climb_slot[i];
		if (s >= 0 && s < (int)_structs[k].slot_owner.size() && _structs[k].slot_owner[s] == i)
			_structs[k].slot_owner[s] = -1;
	}
	_climb_struct[i] = -1;
	int ns = _node_slot[i];
	if (ns >= 0 && ns < MAX_NODES && _slot_agent[ns] == i) _slot_agent[ns] = -1;
	_node_slot[i] = -1;
	// Before the state is reset below, or the lane census can never see what this row was.
	if (_state[i] == ST_LANE && _lane_count > 0) _lane_count--;
	_flags[i] = 0;
	_state[i] = ST_GROUND;
	_climb_slot[i] = -1;
	_climb_prog[i] = 0.0f;
	_lean[i] = 0.0f;
	_generation[i] = (uint8_t)((_generation[i] + 1) & 0xFF); // invalidate in-flight handles
	if (_kind[i] == KIND_GHOST && _ghost_count > 0) _ghost_count--;
	_lane_edge[i] = -1;
	_kind[i] = KIND_OBJECT;
	_free[_free_top++] = i;
	_alive_count--;
}

void SwarmCore::set_overlay_tier(bool on) { _overlay_tier = on; }
void SwarmCore::set_paused(bool p) { _paused = p; }

void SwarmCore::set_time_scale(float s) { _time_scale = s > 0.0f ? s : 0.0f; }

void SwarmCore::add_time_field(const Vector3 &center, float radius, float scale) {
	if (radius <= 0.0f) return;
	if ((int)_time_fields.size() >= MAX_TIME_FIELDS) return; // bounded, like MAX_STRUCTURES
	TimeField f;
	f.center = center;
	f.radius = radius;
	f.scale = scale > 0.0f ? scale : 0.0f;
	_time_fields.push_back(f);
}

void SwarmCore::clear_time_fields() { _time_fields.clear(); }

float SwarmCore::get_agent_time_scale(int i) const {
	if (i < 0 || i >= MAX_AGENTS) return 1.0f;
	return _tscale[i];
}

// Per-agent spatial scale for this tick. Squared distance so a bubble costs no sqrt;
// with MAX_TIME_FIELDS at 8 this is 8 compares per agent and never shows on a profile.
void SwarmCore::_update_time_scales() {
	if (_time_fields.empty()) {
		for (int i = 0; i < MAX_AGENTS; i++) _tscale[i] = 1.0f;
		return;
	}
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) { _tscale[i] = 1.0f; continue; }
		float s = 1.0f;
		const Vector3 &p = _position[i];
		for (const TimeField &f : _time_fields) {
			if (p.distance_squared_to(f.center) <= f.radius * f.radius && f.scale < s) s = f.scale;
		}
		_tscale[i] = s;
	}
}

// ---------------------------------------------------------------- main loop
void SwarmCore::_process(double delta) {
	// Fixed-tick accumulator (§11); cap catch-up so a hitch never spirals.
	// Global dilation scales the ACCUMULATOR, never TICK_DT — the step stays a fixed
	// 30 Hz and the sim just takes fewer of them. Pause still discards banked time;
	// a 0.0 time_scale keeps it, so easing back out of stasis resumes mid-step.
	if (_paused) _accum = 0.0; else _accum += delta * _time_scale;
	int steps = 0;
	while (_accum >= TICK_DT && steps < 4) {
		uint64_t t0 = Time::get_singleton()->get_ticks_usec();
		_step_tick();
		_last_tick_ms = (Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
		_accum -= TICK_DT;
		steps++;
	}
	float alpha = (float)std::min(std::max(_accum / TICK_DT, 0.0), 1.0);

	uint64_t r0 = Time::get_singleton()->get_ticks_usec();
	_assign_tiers();
	_assign_nodes();
	_write_slice(alpha);
	_write_multimesh(alpha);
	if (_corpses_dirty) _write_corpses(); // only when a pile actually changed
	_last_render_ms = (Time::get_singleton()->get_ticks_usec() - r0) / 1000.0;
}

void SwarmCore::_step_tick() {
	_tick++;
	_update_time_scales();   // before anything reads _tscale[i]
	_director();
	_build_hash();
	// The field always aims at the player. When a wall makes that unreachable the wave simply
	// never gets out, agents jam against whatever face is between them and the player, and the
	// climb system grows a pile there — the horde "sees" the climb by failing to path (§6.2).
	_path_goal = _goal_pos;
	if (_pile_mask_dirty) _rebuild_pile_field();
	_maybe_regen_field();
	_update_climb(TICK_DT);
	// Censuses are per TICK, not cumulative: the host reads "how many are hitting this right
	// now" and multiplies by its own damage rate. Cleared here rather than after the read, so
	// a host that polls at a different cadence than the sim gets the latest tick's answer
	// instead of an ever-growing total.
	std::fill(_blk_hits.begin(), _blk_hits.end(), 0);
	std::fill(_obj_hits.begin(), _obj_hits.end(), 0);
	_movement();
	// Re-bucket before de-overlapping: movement has just moved everyone, so the hash built at
	// the top of the tick puts neighbours in the wrong cells and half the overlaps are missed.
	_build_hash();
	_resolve_overlap();

	// Walk-cycle phase per agent, used only to pick a pose bucket for the distant crowd.
	// Deliberately not synced to anything — a horde stepping in unison looks like a parade.
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		float sp = _velocity[i].length();
		_anim_phase[i] += TICK_DT * _tscale[i] * _phase_rate * (0.35f + sp / (_move_speed > 0.01f ? _move_speed : 1.0f));
		if (_anim_phase[i] >= 1.0f) _anim_phase[i] -= (float)(int)_anim_phase[i];
	}
}

// Keep the horde near target_population; ring-spawn around the goal (spawn-policy stub).
void SwarmCore::_director() {
	if (!_director_on) return;
	if (!_has_goal) return;
	// `target_population` is the HORDE's size. An outbreak wave is a scripted event on top
	// of it, so spirits are not counted here — otherwise spawning 200 ghosts would make the
	// director think it was 200 bodies over budget and immediately cull the wave.
	// Lane walkers are excluded for exactly the same reason spirits are: an authored wave is a
	// scripted event on top of the horde, not part of its budget. Counted, a 40-body round out
	// of a doorway reads as being 40 over target and the director culls the wave it was just
	// asked to send.
	int deficit = _target_population - (_alive_count - _ghost_count - _lane_count);
	if (deficit <= 0) {
		// Target was lowered: retire the farthest agents a few at a time, so dropping the
		// population never yanks bodies out of the player's view.
		int excess = -deficit;
		for (int k = 0; k < 8 && excess > 0; k++) {
			int far = -1;
			float fd = -1.0f;
			for (int i = 0; i < MAX_AGENTS; i++) {
				if ((_flags[i] & FLAG_ALIVE) == 0) continue;
				if (_kind[i] == KIND_GHOST) continue;         // not the director's to retire
				if (_state[i] == ST_LANE) continue;          // nor is an authored wave
				if (_state[i] == ST_FROZEN || _state[i] == ST_STUCK
						|| _state[i] == ST_CROUCH) continue; // pile bodies hold the ramp up
				float d = _position[i].distance_squared_to(_camera_pos);
				if (d > fd) { fd = d; far = i; }
			}
			if (far < 0) break;
			_kill(far);
			excess--;
		}
		return;
	}
	int n = std::min(deficit, 8);
	PackedVector3Array batch;
	for (int k = 0; k < n; k++) {
		float ang = _rand01() * (float)Math_TAU;
		float rad = _rand_range(30.0f, 55.0f);
		batch.push_back(_goal_pos + Vector3(std::cos(ang) * rad, 0.0f, std::sin(ang) * rad));
	}
	spawn_batch(batch, 100.0f);
}

// ------------------------------------------------------------------ hash (§7)
int SwarmCore::_cell_of(const Vector3 &p) const {
	int gx = (int)((p.x - _grid_origin.x) / _cell_size);
	int gz = (int)((p.z - _grid_origin.z) / _cell_size);
	if (gx < 0) gx = 0; else if (gx >= _grid_dim) gx = _grid_dim - 1;
	if (gz < 0) gz = 0; else if (gz >= _grid_dim) gz = _grid_dim - 1;
	return gx * _grid_dim + gz;
}

// O(n) counting sort into a flat bucket array — no allocation, no hash map (§7).
void SwarmCore::_build_hash() {
	// Frozen pile bodies are static geometry, not participants: they never move, never steer,
	// and must not push the agents climbing over them. Leaving them out of the hash makes them
	// free in separation as well as in movement (they stay shootable — hitscan is direct).
	std::fill(_cell_fill.begin(), _cell_fill.end(), 0);
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) && _state[i] != ST_FROZEN) {
			int c = _cell_of(_position[i]);
			_cell_index[i] = c;
			_cell_fill[c]++;
		}
	}
	int sum = 0;
	for (int c = 0; c < _cell_count; c++) {
		_cell_start[c] = sum;
		sum += _cell_fill[c];
	}
	_hashed_count = sum; // NOT _alive_count — frozen bodies are not in here
	for (int c = 0; c < _cell_count; c++) _cell_fill[c] = _cell_start[c]; // reuse as cursor
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) && _state[i] != ST_FROZEN) {
			int c = _cell_index[i];
			_order[_cell_fill[c]++] = i;
		}
	}
	// cell c now owns _order[_cell_start[c] .. _cell_fill[c])
}

// ------------------------------------------------------------ flow field (§5)
int SwarmCore::_fcell_of(const Vector3 &p) const {
	int gx = (int)((p.x - _forigin.x) / _fcs);
	int gz = (int)((p.z - _forigin.z) / _fcs);
	if (gx < 0) gx = 0; else if (gx >= _fdim) gx = _fdim - 1;
	if (gz < 0) gz = 0; else if (gz >= _fdim) gz = _fdim - 1;
	return gx * _fdim + gz;
}

void SwarmCore::set_field_params(float cell_size, float max_cost_radius, int regen_interval, float congestion_weight) {
	if (cell_size > 0.0f) _fcs = cell_size;
	if (max_cost_radius > 0.0f) _max_cost_radius = max_cost_radius;
	if (regen_interval > 0) _regen_interval = regen_interval;
	if (congestion_weight >= 0.0f) _congestion_weight = congestion_weight;
}

// A ledge the horde walks UNDER: no ground blocking, but climbable at its edges and
// walkable on top. Registering it is what lets climb spots be discovered instead of authored.
void SwarmCore::add_platform(const Vector3 &center, const Vector3 &size) {
	Volume v;
	v.center = center;
	v.size = size;
	v.flags = VOL_CLIMB | VOL_WALK;
	_volumes.push_back(v);
	_spots_dirty = true;
}

void SwarmCore::add_obstacle(const Vector3 &center, const Vector3 &size) {
	if (_field_running.load()) { if (_field_thread.joinable()) _field_thread.join(); _field_running = false; _field_done = false; }
	Volume vol;
	vol.center = center;
	vol.size = size;
	vol.flags = VOL_BLOCKS | VOL_CLIMB | VOL_WALK;
	_volumes.push_back(vol);
	_spots_dirty = true;
	// Inflate by ~agent radius so agent CENTRES stop before the wall and the 0.35 m capsule
	// bodies don't visibly clip into it.
	const float margin = 0.35f;
	float hx = size.x * 0.5f + margin, hz = size.z * 0.5f + margin;
	int x0 = (int)((center.x - hx - _forigin.x) / _fcs);
	int x1 = (int)((center.x + hx - _forigin.x) / _fcs);
	int z0 = (int)((center.z - hz - _forigin.z) / _fcs);
	int z1 = (int)((center.z + hz - _forigin.z) / _fcs);
	if (x0 < 0) x0 = 0; if (x1 >= _fdim) x1 = _fdim - 1;
	if (z0 < 0) z0 = 0; if (z1 >= _fdim) z1 = _fdim - 1;
	for (int gx = x0; gx <= x1; gx++)
		for (int gz = z0; gz <= z1; gz++)
			_blocked[gx * _fdim + gz] = 1;
	_field_ready = false; // force a rebuild
}

void SwarmCore::clear_obstacles() {
	if (_field_running.load()) { if (_field_thread.joinable()) _field_thread.join(); _field_running = false; _field_done = false; }
	std::fill(_blocked.begin(), _blocked.end(), 0);
	_volumes.clear();
	_spots_dirty = true;
	_field_ready = false;
}

// Main thread: swap in a finished field, then kick a new async regen if one is due (§10).
void SwarmCore::_maybe_regen_field() {
	if (!_has_goal) return;

	if (_field_done.load()) {
		if (_field_thread.joinable()) _field_thread.join();
		std::swap(_cost, _cost_b);
		std::swap(_dirx, _dirx_b);
		std::swap(_dirz, _dirz_b);
		std::swap(_reach, _reach_b);
		_field_ready = true;
		_last_field_goal = _snap_goal;
		_field_done = false;
		_field_running = false;
	}

	if (_field_running.load()) return;
	bool moved = _path_goal.distance_to(_last_field_goal) > _goal_move_thresh;
	if (_field_ready && !moved && (_tick % _regen_interval) != 0) return;

	// Snapshot positions + goal so the worker never races the live sim (§10).
	_snap_goal = _path_goal;
	_snap_count = 0;
	for (int i = 0; i < MAX_AGENTS; i++)
		if (_flags[i] & FLAG_ALIVE) _snap_pos[_snap_count++] = _position[i];

	_field_running = true;
	_field_done = false;
	_field_thread = std::thread(&SwarmCore::_field_worker, this);
}

// Worker thread: Dijkstra integration wave from the goal into the BACK buffers (§5.4/§5.7).
// Reads only the snapshot + the static _blocked mask; writes only _cost_b/_dirx_b/_dirz_b.
// Touches no engine API and no live sim state, so it's race-free against the tick.
void SwarmCore::_field_worker() {
	auto t0 = std::chrono::steady_clock::now();

	std::fill(_cost_b.begin(), _cost_b.end(), INF_COST);
	std::fill(_occ.begin(), _occ.end(), 0);
	for (int k = 0; k < _snap_count; k++) {
		uint16_t &o = _occ[_fcell_of(_snap_pos[k])];
		if (o < 65535) o++;
	}

	int gc = _fcell_of(_snap_goal);
	if (_blocked[gc]) { // goal inside an obstacle: snap to the nearest free cell
		int gx = gc / _fdim, gz = gc % _fdim, found = -1;
		for (int r = 1; r < 6 && found < 0; r++)
			for (int dx = -r; dx <= r && found < 0; dx++)
				for (int dz = -r; dz <= r && found < 0; dz++) {
					int nx = gx + dx, nz = gz + dz;
					if (nx >= 0 && nx < _fdim && nz >= 0 && nz < _fdim && !_blocked[nx * _fdim + nz])
						found = nx * _fdim + nz;
				}
		if (found >= 0) gc = found;
	}

	typedef std::pair<float, int> QN; // (cost, cell)
	std::priority_queue<QN, std::vector<QN>, std::greater<QN>> pq;
	_cost_b[gc] = 0.0f;
	pq.push(QN(0.0f, gc));

	static const int DX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
	static const int DZ[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
	while (!pq.empty()) {
		QN top = pq.top();
		pq.pop();
		float c = top.first;
		int idx = top.second;
		if (c > _cost_b[idx]) continue;
		if (c > _max_cost_radius) continue; // bound the wave (§5.7)
		int cx = idx / _fdim, cz = idx % _fdim;
		for (int d = 0; d < 8; d++) {
			int nx = cx + DX[d], nz = cz + DZ[d];
			if (nx < 0 || nx >= _fdim || nz < 0 || nz >= _fdim) continue;
			int nidx = nx * _fdim + nz;
			if (_blocked[nidx]) continue;
			float step = (d < 4 ? _fcs : _fcs * 1.41421356f) + _congestion_weight * (float)_occ[nidx];
			float nc = c + step;
			if (nc < _cost_b[nidx]) {
				_cost_b[nidx] = nc;
				pq.push(QN(nc, nidx));
			}
		}
	}

	// Reachability flood: same graph, no congestion and no cost bound, so it answers the purely
	// topological question the climb system asks — "is this cell walkable-connected to the
	// player at all?". A walled-off area is 1 inside and 0 outside; that difference across a
	// face is what makes the face worth piling against (§6.2).
	std::fill(_reach_b.begin(), _reach_b.end(), 0);
	{
		std::vector<int> stack;
		stack.reserve(1024);
		_reach_b[gc] = 1;
		stack.push_back(gc);
		while (!stack.empty()) {
			int idx = stack.back();
			stack.pop_back();
			int cx = idx / _fdim, cz = idx % _fdim;
			for (int d = 0; d < 4; d++) { // 4-connected: no squeezing through diagonal gaps
				int nx = cx + DX[d], nz = cz + DZ[d];
				if (nx < 0 || nx >= _fdim || nz < 0 || nz >= _fdim) continue;
				int nidx = nx * _fdim + nz;
				if (_blocked[nidx] || _reach_b[nidx]) continue;
				_reach_b[nidx] = 1;
				stack.push_back(nidx);
			}
		}
	}

	// Direction field: each reached cell points to its lowest-cost neighbour (§5.4).
	for (int idx = 0; idx < _fcell; idx++) {
		if (_cost_b[idx] == INF_COST) { _dirx_b[idx] = 0.0f; _dirz_b[idx] = 0.0f; continue; }
		int cx = idx / _fdim, cz = idx % _fdim;
		float best = _cost_b[idx];
		int bx = 0, bz = 0;
		for (int d = 0; d < 8; d++) {
			int nx = cx + DX[d], nz = cz + DZ[d];
			if (nx < 0 || nx >= _fdim || nz < 0 || nz >= _fdim) continue;
			float nc = _cost_b[nx * _fdim + nz];
			if (nc < best) { best = nc; bx = DX[d]; bz = DZ[d]; }
		}
		float len = std::sqrt((float)(bx * bx + bz * bz));
		if (len > 0.0f) { _dirx_b[idx] = bx / len; _dirz_b[idx] = bz / len; }
		else { _dirx_b[idx] = 0.0f; _dirz_b[idx] = 0.0f; }
	}

	auto t1 = std::chrono::steady_clock::now();
	_last_field_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
	_field_done = true; // published last; main thread swaps on seeing this
}

// ------------------------------------------------------------------ climb (§6)
// --- spot discovery: derive climbable ledges from the registered volumes ---
// Runs only when the volume list changes (an event, §6.6), never per tick. Each climbable
// box contributes candidate spots along its four vertical faces; a candidate survives only
// if the horde can stand at its foot and there is a walkable surface to land on.
bool SwarmCore::_on_surface(int v, const Vector3 &p) const {
	if (v < 0 || v >= (int)_volumes.size()) return false;
	const Volume &vol = _volumes[v];
	return std::fabs(p.x - vol.center.x) <= vol.size.x * 0.5f &&
			std::fabs(p.z - vol.center.z) <= vol.size.z * 0.5f;
}

int SwarmCore::_surface_under(const Vector3 &p, float y) const {
	int best = -1;
	float best_area = -1.0f;
	for (int v = 0; v < (int)_volumes.size(); v++) {
		const Volume &vol = _volumes[v];
		if ((vol.flags & VOL_WALK) == 0) continue;
		float top = vol.center.y + vol.size.y * 0.5f;
		if (std::fabs(top - y) > 0.75f) continue; // a different storey
		if (!_on_surface(v, p)) continue;
		float area = vol.size.x * vol.size.z;
		if (area > best_area) { best_area = area; best = v; } // the platform, not the parapet
	}
	return best;
}

// Which registered volume is the player standing on? -1 when they're on open ground.
int SwarmCore::_volume_under_player() const {
	for (int v = 0; v < (int)_volumes.size(); v++) {
		const Volume &vol = _volumes[v];
		if ((vol.flags & VOL_WALK) == 0) continue;
		float top = vol.center.y + vol.size.y * 0.5f;
		if (top < 0.75f) continue;
		if (_player_pos.y < top - 0.6f || _player_pos.y > top + 3.0f) continue;
		if (_on_surface(v, _player_pos)) return v;
	}
	return -1;
}

bool SwarmCore::_covered(const Vector3 &p) const {
	for (int v = 0; v < (int)_volumes.size(); v++) {
		const Volume &vol = _volumes[v];
		if ((vol.flags & VOL_WALK) == 0) continue;
		if (vol.center.y + vol.size.y * 0.5f < 0.75f) continue;
		if (_on_surface(v, p)) return true; // standing under an overhang — nothing to climb here
	}
	return false;
}

// Is the lip backed by something to climb, or is it hanging over open ground? Sampled at two
// heights just inside the face: a wall is solid at both, a slab or a balcony is solid at
// neither. This is the whole difference between "pile against the wall and scale it" and
// "pile on top of each other and go straight up".
bool SwarmCore::_solid_below(const Vector3 &face, const Vector3 &n, float lip) const {
	Vector3 probe = Vector3(face.x, 0.0f, face.z) - n * 0.25f;
	int hits = 0;
	for (int t = 0; t < 2; t++) {
		float y = lip * (t == 0 ? 0.3f : 0.7f);
		for (int vi = 0; vi < (int)_volumes.size(); vi++) {
			const Volume &vol = _volumes[vi];
			if ((vol.flags & VOL_BLOCKS) == 0) continue;
			if (std::fabs(probe.x - vol.center.x) > vol.size.x * 0.5f) continue;
			if (std::fabs(probe.z - vol.center.z) > vol.size.z * 0.5f) continue;
			if (y < vol.center.y - vol.size.y * 0.5f || y > vol.center.y + vol.size.y * 0.5f) continue;
			hits++;
			break;
		}
	}
	return hits == 2;
}

// A mound only stands up if it spreads: every layer of bodies is a little narrower than the one
// holding it. Ground radius follows from the height it has to reach.
float SwarmCore::_cone_radius_for(float lip) const {
	int layers = (int)std::ceil((lip - _grab_reach) / _layer_h) + 1;
	if (layers < 1) layers = 1;
	if (layers > _max_layers) layers = _max_layers;
	return _cone_base + (float)(layers - 1) * _cone_slope;
}

// Only things whose UNDERSIDE is above `above_y` count. Without that bound the lip's own slab
// is its own ceiling — the face point lies exactly on the volume's edge — and every ledge in the
// level rejects itself as unclimbable.
float SwarmCore::_ceiling_at(const Vector3 &p, float above_y) const {
	float best = 1e9f;
	for (size_t v = 0; v < _volumes.size(); v++) {
		const Volume &vol = _volumes[v];
		if ((vol.flags & (VOL_BLOCKS | VOL_WALK)) == 0) continue;
		if (std::fabs(p.x - vol.center.x) > vol.size.x * 0.5f) continue;
		if (std::fabs(p.z - vol.center.z) > vol.size.z * 0.5f) continue;
		float bottom = vol.center.y - vol.size.y * 0.5f;
		if (bottom > above_y + 0.05f && bottom < best) best = bottom;
	}
	return best;
}

void SwarmCore::_gen_spots_for(int v) {
	const Volume &vol = _volumes[v];
	if ((vol.flags & VOL_CLIMB) == 0) return;
	float top_y = vol.center.y + vol.size.y * 0.5f;
	if (top_y < _min_climb_h || top_y > _max_climb_h) return;

	static const Vector3 N[4] = { Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1) };
	for (int f = 0; f < 4; f++) {
		Vector3 n = N[f];
		Vector3 tangent(-n.z, 0.0f, n.x);
		float face_len = (f < 2) ? vol.size.z : vol.size.x; // width of this face
		float out = ((f < 2) ? vol.size.x : vol.size.z) * 0.5f;
		int samples = (int)std::floor(face_len / _spot_spacing);
		if (samples < 1) samples = 1;
		for (int k = 0; k < samples; k++) {
			if ((int)_spots.size() >= _max_spots) return;
			float u = ((float)k + 0.5f) / (float)samples;
			float off = (u - 0.5f) * std::max(0.0f, face_len - 0.8f); // keep off the corners
			Vector3 face = vol.center + n * out + tangent * off;
			face.y = top_y;

			ClimbSpot s;
			s.normal = n;
			s.face = face;
			s.height = top_y;
			s.authored = false;
			s.thickness = (f < 2) ? vol.size.x : vol.size.z; // depth of the box along -normal
			s.cone = !_solid_below(face, n, top_y);

			if (s.cone) {
				// Nothing to lean on: the mound stands on open ground just off the lip, and the
				// horde queues clear of its whole footprint.
				s.radius = _cone_radius_for(top_y);
				s.face = Vector3(face.x, 0.0f, face.z) + n * _cone_offset;
				s.face.y = top_y;
				s.base = Vector3(s.face.x, 0.0f, s.face.z) + n * (s.radius + 0.4f);
			} else {
				s.base = Vector3(face.x, 0.0f, face.z) + n * _approach;
			}
			if (_in_no_climb(s.base) || _in_no_climb(face)) continue; // the level said not here
			if (_blocked[_fcell_of(s.base)]) continue; // no room to pile at the foot
			if (_covered(s.base)) continue;            // the foot is under another ledge
			// Somewhere to put their heads. A pile needs clear air from the ground to above the
			// lip; roofed over, this face is not climbable however inviting it looks.
			if (_ceiling_at(s.base, top_y) < top_y + _headroom) continue;
			if (_ceiling_at(face, top_y) < top_y + _headroom) continue;

			// Two kinds of landing. A ledge deep enough to stand on behind the lip → the climber
			// mantles onto it and becomes an elevated hunter. A wall → there is nothing to stand
			// on, so the climber crests the lip and drops down the far side into the ground horde.
			// That second case is what lets the horde pour over a plain wall into a sealed area.
			Vector3 inset = Vector3(face.x, top_y, face.z) - n * _top_inset;
			int surf = _surface_under(inset, top_y);
			// The level named the approaches to this surface; do not invent more.
			bool owned = false;
			for (size_t q = 0; q < _authored_surfaces.size(); q++)
				if (_authored_surfaces[q] == surf) { owned = true; break; }
			if (owned) continue;
			if (surf >= 0) {
				s.top = inset;
				s.surface = surf;
				s.drop = false;
			} else {
				// A mound is built to get ONTO something. With nothing to land on there is
				// nothing to build it for — and no far side to fall down either.
				if (s.cone) continue;
				Vector3 far_side = Vector3(face.x, 0.0f, face.z) - n * (s.thickness + _approach);
				if (_blocked[_fcell_of(far_side)]) continue; // solid on the far side too
				s.top = far_side;
				s.surface = _surface_under(far_side, 0.0f); // -1 = plain ground, which is fine
				s.drop = true;
			}
			_spots.push_back(s);
		}
	}
}

void SwarmCore::_rebuild_spots() {
	if (_fcell == 0) return; // grids not allocated yet
	for (int k = (int)_structs.size() - 1; k >= 0; k--) _struct_release(k); // indices are about to change
	_spots.clear();
	_authored_surfaces.clear();
	for (size_t k = 0; k < _authored_spots.size(); k++) {
		ClimbSpot s = _authored_spots[k];
		s.surface = _surface_under(s.top, s.top.y); // -1 if the level didn't register the ledge
		if (s.surface >= 0) {
			bool have = false;
			for (size_t q = 0; q < _authored_surfaces.size(); q++)
				if (_authored_surfaces[q] == s.surface) { have = true; break; }
			if (!have) _authored_surfaces.push_back(s.surface);
		}
		// An authored spot gets the same shape test as a discovered one: point it at a wall and
		// the horde scales the wall; point it at a balcony and they mound up under it.
		s.cone = !_solid_below(s.face, s.normal, s.height);
		if (s.cone) {
			s.radius = _cone_radius_for(s.height);
			s.face = Vector3(s.face.x, 0.0f, s.face.z) + s.normal * _cone_offset;
			s.face.y = s.height;
			s.base = Vector3(s.face.x, 0.0f, s.face.z) + s.normal * (s.radius + 1.0f);
		}
		_spots.push_back(s);
	}
	if (_auto_spots)
		for (int v = 0; v < (int)_volumes.size(); v++) _gen_spots_for(v);
	_spot_mass.assign(_spots.size(), 0);
	_spot_score.assign(_spots.size(), -1e9f);
	_spot_sustain.assign(_spots.size(), 0.0f);
	_best_spot = -1;
	_spots_dirty = false;
}

// --- selection: which faces are worth piling against, for whom ---
// The §6.2 "reachable goal above" test, without the full portal graph. Two cases, one rule:
// climbing here has to put the agent somewhere the ground alone cannot take it.
//   - player up on a registered ledge  → the spot must land on THAT ledge
//   - player on the ground             → the landing must be ground-connected to the player
//                                        while the foot of the wall is not. A sealed courtyard,
//                                        a walled compound, a fence line: all the same test.
// Nothing here asks whether the player is "elevated" — the flow field's reachability mask
// answers it, so a plain wall between the horde and the player triggers a pile on its own.
bool SwarmCore::_spot_useful(const ClimbSpot &s) const {
	if (!_field_ready) return false;
	if (s.height - s.base.y < _min_climb_h) return false;
	if (_player_surface >= 0) return s.surface == _player_surface;
	if (!_reach[_fcell_of(s.top)]) return false;  // lands somewhere that still can't see the player
	if (_reach[_fcell_of(s.base)]) return false;  // the horde can already just walk there
	return true;
}

float SwarmCore::_score_of(const ClimbSpot &s, int mass) const {
	if (!_spot_useful(s)) return -1e9f;
	float dp = s.top.distance_to(_player_pos);
	if (dp > _sel_player_radius) return -1e9f; // this ledge doesn't lead anywhere near the player
	float sc = _w_player * (1.0f - dp / _sel_player_radius);
	sc += _w_mass * (float)mass / (float)(_density_threshold > 0 ? _density_threshold : 1);
	sc -= _w_height * s.height;
	if (s.authored) sc += _authored_bonus;
	return sc;
}

// One pass over agents for all spots — O(agents × spots) but only every _sel_interval ticks.
// Also ages the per-spot density timer, so several separately jammed groups can each ripen
// their own spot instead of the whole horde converging on one global best (§6.2).
void SwarmCore::_score_spots(float dt) {
	_player_surface = _volume_under_player();
	int n = (int)_spots.size();
	// Cheap eligibility first, so the O(agents × spots) mass count only runs for the handful of
	// faces that could actually serve — most of a level's spots are the wrong side of something.
	std::vector<uint8_t> ok(n, 0);
	for (int k = 0; k < n; k++) {
		_spot_mass[k] = 0;
		ok[k] = (_spot_useful(_spots[k]) && _spots[k].top.distance_to(_player_pos) <= _sel_player_radius) ? 1 : 0;
	}
	float r2 = _density_radius * _density_radius;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0 || _state[i] != ST_GROUND) continue;
		for (int k = 0; k < n; k++)
			if (ok[k] && _position[i].distance_squared_to(_spots[k].base) <= r2) _spot_mass[k]++;
	}
	_best_spot = -1;
	float best = -1e18f;
	for (int k = 0; k < n; k++) {
		_spot_score[k] = ok[k] ? _score_of(_spots[k], _spot_mass[k]) : -1e9f;
		bool hot = _spot_score[k] > -1e8f && _spot_mass[k] >= _density_threshold;
		_spot_sustain[k] = hot ? _spot_sustain[k] + dt : std::max(0.0f, _spot_sustain[k] - dt);
		if (_spot_score[k] > best) { best = _spot_score[k]; _best_spot = k; }
	}
}

// Spirits are excluded: a pile is a ramp built by things that cannot walk through the wall
// it is stacked against. A crowd of ghosts drifting past a ledge is not a jam and must not
// read as one, or an outbreak wave starts building ramps it has no use for.
int SwarmCore::_count_ground_near(const Vector3 &c, float r) const {
	float r2 = r * r;
	int n = 0;
	for (int i = 0; i < MAX_AGENTS; i++)
		if ((_flags[i] & FLAG_ALIVE) && _state[i] == ST_GROUND && _kind[i] != KIND_GHOST
				&& _position[i].distance_squared_to(c) <= r2) n++;
	return n;
}

// --------------------------------------------------------------- pile structures
int SwarmCore::_struct_at_spot(int spot_index) const {
	for (size_t k = 0; k < _structs.size(); k++)
		if (_structs[k].spot_index == spot_index) return (int)k;
	return -1;
}

int SwarmCore::_nearest_struct(const Vector3 &p) const {
	int best = -1;
	float bd = _recruit_radius * _recruit_radius;
	for (size_t k = 0; k < _structs.size(); k++) {
		float d = p.distance_squared_to(_structs[k].spot.base);
		if (d < bd) { bd = d; best = (int)k; }
	}
	return best;
}

// The pile's slots: a discrete lattice, one body per cell, cells wider than an agent is. Two
// bodies can never occupy the same space because there is nowhere for them to overlap — the
// old version scattered slots along a continuous curve and they interpenetrated (§6.1).
// The wedge tapers with height so it reads as a heap, not a tower.
void SwarmCore::_build_lattice(ClimbStructure &S) {
	S.slot_pos.clear();
	S.slot_layer.clear();
	S.slot_owner.clear();
	const ClimbSpot &sp = S.spot;
	float lip = sp.height - sp.base.y;
	Vector3 tangent(-sp.normal.z, 0.0f, sp.normal.x);
	Vector3 foot(sp.face.x, sp.base.y, sp.face.z);
	// Base grows with the height it has to support, and the taper is proportional — so a heap is
	// a pyramid whatever its size, instead of a fixed-width block that turns into a spike.
	float wide = std::min(_pile_width_max, _pile_width + lip * _pile_spread);
	float deep = std::min(_pile_depth_max, _pile_depth + lip * _pile_spread * 0.6f);
	int cols0 = std::max(1, (int)(wide / _slot_pitch));
	int rows0 = std::max(1, (int)(deep / _slot_pitch));
	// Enough layers that a climber standing on the crest can grab the lip, plus one for slack.
	int layers = (int)std::ceil((lip - _grab_reach) / _layer_h) + 1;
	if (layers < 1) layers = 1;
	if (layers > _max_layers) layers = _max_layers;
	// Never stack into a ceiling.
	float head = _ceiling_at(sp.base, sp.base.y + 0.5f) - sp.base.y - 0.7f;
	if (head < 1e8f) {
		int fit = (int)std::floor(head / _layer_h);
		if (fit < 1) fit = 1;
		if (layers > fit) layers = fit;
	}

	S.need = 0;

	// A free-standing mound: concentric rings per layer, each layer a ring narrower than the one
	// below it. Rings are laid outside-in so a layer visibly closes up before the next starts.
	if (sp.cone) {
		Vector3 axis(sp.face.x, sp.base.y, sp.face.z);
		float r0 = sp.radius > 0.0f ? sp.radius : _cone_radius_for(lip);
		for (int L = 0; L < layers; L++) {
			float r = r0 - (float)L * _cone_slope;
			// One ring of bodies per layer, plus a wider skirt at the ground to sit on. Packing
			// every layer solid is what a real heap would be and costs three times the zombies
			// for the same height — a mound this steep still reads as a mound.
			int rings = std::min((int)std::floor(r / _slot_pitch), L == 0 ? 2 : 1);
			for (int ring = rings; ring >= 1; ring--) {
				float rr = (float)ring * _slot_pitch;
				int cnt = std::max(1, (int)std::floor((float)Math_TAU * rr / _slot_pitch));
				for (int a = 0; a < cnt; a++) {
					float ang = ((float)a + 0.5f * (float)(L & 1)) / (float)cnt * (float)Math_TAU;
					Vector3 p = axis + Vector3(std::cos(ang) * rr, 0.0f, std::sin(ang) * rr);
					p.y = sp.base.y + (float)L * _layer_h;
					if (p.y + _headroom > _ceiling_at(p, 0.0f)) continue;
					S.slot_pos.push_back(p);
					S.slot_layer.push_back((uint8_t)L);
					S.slot_owner.push_back(-1);
				}
			}
			Vector3 c = axis; // the one in the middle, laid last
			c.y = sp.base.y + (float)L * _layer_h;
			if (c.y + _headroom > _ceiling_at(c, 0.0f)) continue;
			S.slot_pos.push_back(c);
			S.slot_layer.push_back((uint8_t)L);
			S.slot_owner.push_back(-1);
			if (S.need == 0 && (float)(L + 1) * _layer_h + _grab_reach >= lip)
				S.need = (int)S.slot_pos.size();
		}
		if (S.need == 0) S.need = (int)S.slot_pos.size();
		return;
	}

	for (int L = 0; L < layers; L++) {
		float shrink = 1.0f - (float)L / (float)layers;
		int cols = std::max(1, (int)std::round((float)cols0 * shrink));
		int rows = std::max(1, (int)std::round((float)rows0 * shrink));
		for (int r = 0; r < rows; r++) {
			for (int c = 0; c < cols; c++) {
				uint32_t h = (uint32_t)(L * 73856093) ^ (uint32_t)(r * 19349663) ^ (uint32_t)(c * 83492791);
				float jz = ((float)((h >> 8) & 255) / 255.0f - 0.5f) * 0.16f;
				float jx = ((float)((h >> 16) & 255) / 255.0f - 0.5f) * 0.16f;
				float depth = 0.35f + (float)r * _slot_pitch + jz;
				float across = ((float)c - (float)(cols - 1) * 0.5f) * _slot_pitch + jx;
				Vector3 p = foot + sp.normal * depth + tangent * across;
				p.y = sp.base.y + (float)L * _layer_h;
				// Per-cell headroom. Clamping the layer COUNT against the ceiling above the foot
				// is not enough once a heap is wide: its outer cells sit under slabs the foot
				// never sat beneath, and a body there pushes its head through one.
				if (p.y + _headroom > _ceiling_at(p, 0.0f)) continue;
				S.slot_pos.push_back(p);
				S.slot_layer.push_back((uint8_t)L);
				S.slot_owner.push_back(-1);
			}
		}
		if (S.need == 0 && (float)(L + 1) * _layer_h + _grab_reach >= lip)
			S.need = (int)S.slot_pos.size(); // this many bodies put the lip within reach
	}
	if (S.need == 0) S.need = (int)S.slot_pos.size();
}

// The pile is exactly as tall as the bodies in it. Recomputed every tick (a few dozen slots)
// so shooting bodies out of the heap lowers the crest immediately (§6.5).
void SwarmCore::_recalc_pile(ClimbStructure &S) {
	int tot[32] = { 0 };
	int got[32] = { 0 };
	int nlayers = S.slot_layer.empty() ? 0 : (int)S.slot_layer.back() + 1;
	if (nlayers > 32) nlayers = 32;
	S.filled = 0;
	for (size_t s = 0; s < S.slot_owner.size(); s++) {
		int L = S.slot_layer[s];
		if (L >= nlayers) continue;
		tot[L]++;
		int o = S.slot_owner[s];
		if (o == CORPSE_SLOT) { got[L]++; S.filled++; }
		else if (o >= 0 && (_flags[o] & FLAG_ALIVE) && _state[o] == ST_FROZEN) { got[L]++; S.filled++; }
	}
	// A layer only carries the next one once it is at least half laid: one body on top of a heap
	// is not a floor. Slots fill bottom-up, so this tracks the visible crest.
	int top = -1;
	for (int L = 0; L < nlayers; L++) {
		if (got[L] > 0 && got[L] * 2 >= tot[L]) top = L;
		else break;
	}
	S.pile_h = (float)(top + 1) * _layer_h;

	// Anything with a finished layer on top of it is buried: it dies, its pool slot goes back to
	// the horde, and it stays as a corpse holding the mound up. Only the crest layer stays live,
	// so releasing a pile still leaves bodies that can stand back up (§6.5). Once a corpse, the
	// slot is filled permanently — a mountain of dead zombies does not un-pile itself.
	if (top > 0) {
		bool buried_any = false;
		for (size_t s = 0; s < S.slot_owner.size(); s++) {
			if ((int)S.slot_layer[s] >= top) continue;
			int o = S.slot_owner[s];
			if (o < 0 || (_flags[o] & FLAG_ALIVE) == 0 || _state[o] != ST_FROZEN) continue;
			if ((int)_corpses.size() >= MAX_CORPSES) break;
			_add_corpse(_position[o], _yaw[o], S.group);
			_kill(o);                        // clears slot_owner back to -1 — reclaim it after
			S.slot_owner[s] = CORPSE_SLOT;
			S.buried++;
			buried_any = true;
		}
		if (buried_any) _revis_group(S.group);
	}

	// Crossing path, in metres: up the heap → up the bare face → over the lip → (a wall) down
	// the far side. Segment lengths are cached here, so the per-tick climber step is a lerp.
	const ClimbSpot &sp = S.spot;
	float lip = sp.height - sp.base.y;
	S.crossable = (S.pile_h + _grab_reach >= lip);

	// A mound has no face to scale: crest of the pile straight into the mantle. If the bodies
	// don't get there, nobody gets up — there is no wall segment to make up the difference.
	if (sp.cone) {
		Vector3 A(sp.face.x, sp.base.y + S.pile_h, sp.face.z);
		Vector3 P1 = A.lerp(sp.top, 0.5f);
		P1.y = std::max(A.y, sp.top.y) + _lip_rise;
		S.seg_pile = sp.base.distance_to(A);
		S.seg_wall = 0.0f;
		S.seg_mantle = (A.distance_to(P1) + P1.distance_to(sp.top)) * 0.85f;
		S.seg_drop = 0.0f;
		S.path_len = S.seg_pile + S.seg_mantle;
		return;
	}

	Vector3 hug = sp.normal * _wall_hug;
	Vector3 A(sp.face.x + hug.x, sp.base.y + S.pile_h, sp.face.z + hug.z);
	Vector3 B(A.x, sp.face.y - 0.15f, A.z);
	Vector3 P1(sp.face.x, sp.face.y + _lip_rise, sp.face.z);
	Vector3 M = sp.drop
			? Vector3(sp.face.x, sp.face.y + 0.15f, sp.face.z) - sp.normal * (sp.thickness * 0.5f)
			: sp.top;
	S.seg_pile = sp.base.distance_to(A);
	S.seg_wall = std::max(0.0f, B.y - A.y);
	S.seg_mantle = (B.distance_to(P1) + P1.distance_to(M)) * 0.85f; // chord of the arc
	S.seg_drop = sp.drop ? M.distance_to(sp.top) : 0.0f;
	S.path_len = S.seg_pile + S.seg_wall + S.seg_mantle + S.seg_drop;
}

int SwarmCore::_free_slot(const ClimbStructure &S, int min_layer) const {
	for (size_t s = 0; s < S.slot_owner.size(); s++)
		if (S.slot_owner[s] == -1 && (int)S.slot_layer[s] >= min_layer) return (int)s;
	return -1;
}

int SwarmCore::_free_slot_near(const ClimbStructure &S, const Vector3 &from) const {
	int layer = -1;
	for (size_t s = 0; s < S.slot_owner.size(); s++)
		if (S.slot_owner[s] == -1) { layer = (int)S.slot_layer[s]; break; }
	if (layer < 0) return -1;
	int best = -1;
	float bd = 1e18f;
	for (size_t s = 0; s < S.slot_owner.size(); s++) {
		if (S.slot_owner[s] != -1 || (int)S.slot_layer[s] != layer) continue;
		float d = S.slot_pos[s].distance_squared_to(from);
		if (d < bd) { bd = d; best = (int)s; }
	}
	return best;
}

void SwarmCore::_struct_begin(int spot_index) {
	if ((int)_structs.size() >= MAX_STRUCTURES) return;
	ClimbStructure S;
	S.spot = _spots[spot_index];
	S.spot_index = spot_index;
	S.phase = 1;
	S.group = _next_group++;
	S.wall_yaw = std::atan2(-S.spot.normal.x, -S.spot.normal.z);
	_build_lattice(S);
	// Rebuilding at a spot that already has a mound on it: any cell a corpse is lying in is
	// taken. Otherwise the new pile would lay bodies straight through the old one.
	float taken2 = (_slot_pitch * 0.5f) * (_slot_pitch * 0.5f);
	for (size_t s = 0; s < S.slot_pos.size(); s++)
		for (size_t c = 0; c < _corpses.size(); c++)
			if (S.slot_pos[s].distance_squared_to(_corpses[c].pos) < taken2) {
				S.slot_owner[s] = CORPSE_SLOT;
				S.group = _corpses[c].group; // inherit, so the mound stays one collider
				break;
			}
	_recalc_pile(S);
	_structs.push_back(S);
}

// Give the pile back to the horde. Frozen bodies stand up and rejoin; agents holding a later
// structure index are renumbered, since the vector closes up behind the erased entry.
void SwarmCore::_struct_release(int k) {
	if (k < 0 || k >= (int)_structs.size()) return;
	bool laid = false;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_climb_struct[i] == k) {
			if (_state[i] == ST_FROZEN) {
				// Nobody leaves the pile. A body that has lain down is part of the heap for good:
				// releasing the structure turns it into a corpse rather than standing it back up,
				// which also hands its pool slot back to the horde. Letting them rejoin made a
				// finished mound visibly shrink as its crest walked away.
				_add_corpse(_position[i], _yaw[i], _structs[k].group);
				_kill(i);
				laid = true;
				continue;
			}
			if (_state[i] == ST_BODY || _state[i] == ST_CLIMBER || _state[i] == ST_STUCK
					|| _state[i] == ST_CROUCH) {
				// Still in transit — they never joined the heap, so they go back to the horde.
				_state[i] = ST_GROUND;
				Vector3 pp = _position[i];
				pp.y = 0.0f;
				_position[i] = pp;
				_prev_position[i] = pp;
				_lean[i] = 0.0f;
			}
			_climb_struct[i] = -1;
			_climb_slot[i] = -1;
			_climb_prog[i] = 0.0f;
		} else if (_climb_struct[i] > k) {
			_climb_struct[i]--;
		}
	}
	if (laid) _revis_group(_structs[k].group);
	_structs.erase(_structs.begin() + k);
}

// An agent stops here: it becomes static pile geometry the rest of the horde climbs over.
// From this point it costs nothing — no steering, no path, no hash slot, no animation (§6.4).
void SwarmCore::_freeze(int i, ClimbStructure &S) {
	int slot = _climb_slot[i];
	if (slot < 0 || slot >= (int)S.slot_pos.size()) {
		_state[i] = ST_GROUND;
		_climb_struct[i] = -1;
		_climb_slot[i] = -1;
		return;
	}
	_state[i] = ST_FROZEN;
	S.slot_owner[slot] = i;
	_corpse_rev++; // the mound is built from frozen bodies too — it needs rebuilding
	_pile_mask_dirty = true;
	Vector3 sp = S.slot_pos[slot];
	_position[i] = sp;
	_prev_position[i] = sp;
	_velocity[i] = Vector3();
	_climb_prog[i] = 0.0f;
	// Prone, with a hashed yaw offset: the heap reads as bodies lying over each other rather
	// than a stack of standing zombies, and the lattice stops looking like a lattice. On a
	// mound they lie radially, heads to the middle, which is what a real heap of them looks like.
	uint32_t h = (uint32_t)(slot + 1) * 2654435761u;
	float base_yaw = S.wall_yaw;
	if (S.spot.cone) {
		Vector3 out = sp - Vector3(S.spot.face.x, sp.y, S.spot.face.z);
		if (out.length_squared() > 0.01f) base_yaw = std::atan2(out.x, out.z);
	}
	_yaw[i] = base_yaw + (((float)((h >> 9) & 255) / 255.0f) - 0.5f) * 1.6f;
	_lean[i] = 1.5708f;
}

// Pull the next body (or climber) out of the jam at the foot. Candidates come from the hash
// cells around the base — the old version swept all MAX_AGENTS once per empty slot per tick.
void SwarmCore::_recruit(ClimbStructure &S, int k) {
	const int per_pass = 2; // the pile grows a body at a time — that is the whole readable point
	for (int n = 0; n < per_pass; n++) {
		bool crosser = S.crossable;
		if (!crosser) {
			if (_free_slot(S, 0) < 0) { S.phase = 3; return; } // lattice full, still short of the lip
			if (S.fillers >= _max_fillers) return;  // let the ones already scrambling land first
		} else if (_crossers >= _max_climbers) {
			return;
		}
		int slot = -1;
		// A body walks to its cell under its own steam, from wherever it happens to be, so it can
		// be recruited from anywhere near the heap.
		//
		// A crosser is recruited at the CREST, not at the foot. Its ascent starts where it is
		// standing, and where it is standing when it runs out of pile is the top of the heap —
		// on a 9 m mound the ground stand-off point is buried under nine metres of bodies and
		// nobody could ever get within reach of it, so nobody ever crossed.
		Vector3 hug0 = S.spot.normal * _wall_hug;
		Vector3 crest = S.spot.cone
				? Vector3(S.spot.face.x, S.spot.base.y + S.pile_h, S.spot.face.z)
				: Vector3(S.spot.face.x + hug0.x, S.spot.base.y + S.pile_h, S.spot.face.z + hug0.z);
		Vector3 grab_c = crosser ? crest : S.spot.base;
		float grab = crosser ? 3.2f : _recruit_radius;

		int best = -1;
		float bd = grab * grab;
		// Only agents on the same side of the wall as the pile: the hash radius reaches through
		// a thin wall, and a body recruited from inside the compound would walk out through it.
		uint8_t side = _field_ready ? _reach[_fcell_of(S.spot.base)] : 0;
		int gx = (int)((grab_c.x - _grid_origin.x) / _cell_size);
		int gz = (int)((grab_c.z - _grid_origin.z) / _cell_size);
		int cr = (int)std::ceil(grab / _cell_size);
		for (int dx = -cr; dx <= cr; dx++) {
			int cx = gx + dx;
			if (cx < 0 || cx >= _grid_dim) continue;
			for (int dz = -cr; dz <= cr; dz++) {
				int cz = gz + dz;
				if (cz < 0 || cz >= _grid_dim) continue;
				int c = cx * _grid_dim + cz;
				for (int q = _cell_start[c]; q < _cell_fill[c]; q++) {
					int i = _order[q];
					if (_state[i] != ST_GROUND) continue;
					if (_field_ready && _reach[_fcell_of(_position[i])] != side) continue;
					// A crosser has to already be up on the heap, or it would start its ascent
					// from the floor and fly up the outside of the pile.
					if (crosser && _position[i].y < S.spot.base.y + S.pile_h - 1.6f) continue;
					// Prefer the ones already wedged: a zombie that has stopped making progress
					// against the wall is the one that would realistically start climbing.
					float dd = _position[i].distance_squared_to(grab_c) * (1.0f - 0.6f * _jam[i]);
					if (dd < bd) { bd = dd; best = i; }
				}
			}
		}
		if (best < 0) {
			// Nobody left to pile on. Once the ones already on their way have landed and there
			// is still no one to take the next slot, the pile holds at the height it reached —
			// the "not enough zombies, so the climb stops there" case, not a cleanup failure.
			if (S.claimed == 0) {
				S.stall_t += (float)_recruit_interval * TICK_DT;
				if (S.stall_t > _stall_timeout && !S.crossable) S.phase = 3;
			}
			return;
		}
		S.stall_t = 0.0f;
		if (S.phase == 3) S.phase = 1; // fresh bodies arrived — the pile can grow again

		_climb_struct[best] = (int8_t)k;
		_climb_prog[best] = 0.0f;
		_climb_start[best] = _position[best];
		// Now that we know WHO, give them the free cell on their own side of the heap.
		if (!crosser) {
			slot = _free_slot_near(S, _position[best]);
			if (slot < 0) { S.phase = 3; return; }
		}

		S.claimed++;
		if (crosser) {
			_state[best] = ST_CLIMBER;
			_climb_slot[best] = -1; // no slot reserved: this one is going over the top
			_climb_seg0[best] = std::max(0.2f, _position[best].distance_to(crest));
			_crossers++;
		} else {
			S.fillers++;
			S.slot_owner[slot] = best; // reserved on recruit, so two never target one cell
			_climb_slot[best] = slot;
			// Every filler walks, whatever layer its cell is on: across the ground, then up the
			// flank of the heap that is already there. Upper layers used to be put on a canned
			// arc from wherever the agent stood, which is the "dive into the pile" — there is no
			// such path any more.
			_state[best] = ST_BODY;
		}
	}
	S.phase = S.crossable ? 2 : 1;
}

// UNUSED since fillers walk to their cell under their own steam (see _recruit). Kept because the
// crossing path still needs the same Bezier shape and this is where it is worked out.
Vector3 SwarmCore::_filler_path_pos(const ClimbStructure &S, int slot, const Vector3 &start, float s, float *out_lean) const {
	Vector3 T = S.slot_pos[slot];
	// Rise at the outside of the heap, then settle in. On a mound "outside" is away from the
	// axis, so the climber goes up the flank it walked to rather than round to the lip side.
	Vector3 P1 = S.spot.cone
			? start.lerp(Vector3(S.spot.face.x, start.y, S.spot.face.z), 0.3f)
			: start - S.spot.normal * 0.3f;
	P1.y = T.y + 0.7f;
	float len = (start.distance_to(P1) + P1.distance_to(T)) * 0.9f;
	float t = len > 0.001f ? s / len : 1.0f;
	if (t > 1.0f) t = 1.0f;
	*out_lean = 0.3f + 1.27f * t; // hunched scramble, flattening into the prone freeze pose
	float mt = 1.0f - t;
	return start * (mt * mt) + P1 * (2.0f * mt * t) + T * (t * t);
}

float SwarmCore::_filler_path_len(const ClimbStructure &S, int slot, const Vector3 &start) const {
	Vector3 T = S.slot_pos[slot];
	Vector3 P1 = start - S.spot.normal * 0.3f;
	P1.y = T.y + 0.7f;
	return (start.distance_to(P1) + P1.distance_to(T)) * 0.9f;
}

// The crossing path, parametrised by metres travelled: up the pile → up the bare wall → mantle
// over the lip → (walls only) down the far side. Faked entirely — nothing here touches a
// physics body (§6.1/§6.6). Its first segment ends at pile_h, so a climber can only get as
// high as the bodies underneath actually reach.
Vector3 SwarmCore::_cross_path_pos(const ClimbStructure &S, float s, const Vector3 &start, float seg0, float *out_lean) const {
	const ClimbSpot &sp = S.spot;

	if (sp.cone) { // up the flank of the mound, then straight off the crest onto the ledge
		Vector3 A(sp.face.x, sp.base.y + S.pile_h, sp.face.z);
		if (s <= seg0) {
			float t = seg0 > 0.001f ? s / seg0 : 1.0f;
			*out_lean = 0.35f * t; // clambering over the ones underneath
			return start.lerp(A, t);
		}
		Vector3 P1 = A.lerp(sp.top, 0.5f);
		P1.y = std::max(A.y, sp.top.y) + _lip_rise;
		float t = S.seg_mantle > 0.001f ? (s - seg0) / S.seg_mantle : 1.0f;
		if (t > 1.0f) t = 1.0f;
		float mt = 1.0f - t;
		*out_lean = 0.35f + 0.6f * std::sin(t * (float)Math_PI) - 0.35f * t;
		return A * (mt * mt) + P1 * (2.0f * mt * t) + sp.top * (t * t);
	}

	Vector3 hug = sp.normal * _wall_hug;
	Vector3 A(sp.face.x + hug.x, sp.base.y + S.pile_h, sp.face.z + hug.z); // crest of the pile
	Vector3 B(A.x, sp.face.y - 0.15f, A.z);                                // hands on the lip
	Vector3 P1(sp.face.x, sp.face.y + _lip_rise, sp.face.z);
	Vector3 M = sp.drop
			? Vector3(sp.face.x, sp.face.y + 0.15f, sp.face.z) - sp.normal * (sp.thickness * 0.5f)
			: sp.top;

	// The first stretch runs from wherever this climber actually was, not from the structure's
	// queue point — starting every ascent at a shared spot metres out reads as the horde
	// backing up to take a run at the wall.
	if (s <= seg0) {
		float t = seg0 > 0.001f ? s / seg0 : 1.0f;
		*out_lean = 0.25f * t; // hunched forward scrambling up the bodies
		return start.lerp(A, t);
	}
	if (s <= seg0 + S.seg_wall) {
		float t = S.seg_wall > 0.001f ? (s - seg0) / S.seg_wall : 1.0f;
		*out_lean = 0.25f + 0.1f * t; // pressed flat against the face
		return A.lerp(B, t);
	}
	if (s <= seg0 + S.seg_wall + S.seg_mantle) {
		// Quadratic Bezier up over the lip and down onto the top — the clamber.
		float t = S.seg_mantle > 0.001f ? (s - seg0 - S.seg_wall) / S.seg_mantle : 1.0f;
		if (t > 1.0f) t = 1.0f;
		float mt = 1.0f - t;
		*out_lean = 0.35f + 0.8f * std::sin(t * (float)Math_PI) - 0.35f * t;
		return B * (mt * mt) + P1 * (2.0f * mt * t) + M * (t * t);
	}
	// Over a wall there is nothing to stand on: they tip over the top and fall down the inside.
	float t = S.seg_drop > 0.001f ? (s - seg0 - S.seg_wall - S.seg_mantle) / S.seg_drop : 1.0f;
	if (t > 1.0f) t = 1.0f;
	*out_lean = 0.6f * (1.0f - t);
	return M.lerp(sp.top, t);
}

// Drives every live pile: grow → crossable → stalled, plus proposing new ones where a separate
// group has jammed (§6.2-6.5). Nothing here is per-agent except the bounded recruit scan.
void SwarmCore::_update_climb(float dt) {
	if (_spots_dirty) _rebuild_spots();
	if (_spots.empty()) return;

	bool sel_tick = (_tick % (uint32_t)_sel_interval) == 0;
	if (sel_tick) _score_spots(dt * (float)_sel_interval);

	// One census pass for every structure, instead of each of them sweeping the agent array.
	// `claimed` is what stops a pile calling itself stalled while bodies are still walking to it.
	_crossers = 0;
	for (size_t k = 0; k < _structs.size(); k++) { _structs[k].claimed = 0; _structs[k].fillers = 0; }
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_state[i] != ST_BODY && _state[i] != ST_CLIMBER && _state[i] != ST_STUCK
				&& _state[i] != ST_CROUCH) continue;
		int ki = _climb_struct[i];
		if (ki < 0 || ki >= (int)_structs.size()) continue;
		_structs[ki].claimed++;
		if (_state[i] == ST_CLIMBER) {
			if (_climb_slot[i] >= 0) _structs[ki].fillers++;
			else _crossers++;
		} else {
			_structs[ki].fillers++; // a body walking to a layer-0 cell occupies a filler slot too
		}
	}

	for (int k = (int)_structs.size() - 1; k >= 0; k--) {
		ClimbStructure &S = _structs[k];
		S.age += dt;
		_recalc_pile(S);
		// A pile that reaches the lip is crossable whatever it was doing before — stalling is
		// only meaningful while it is still short.
		if (S.crossable) S.phase = 2;
		else if (S.phase != 3) S.phase = 1;
		// A pile is kept while it still leads to the player. Losing that (player walked away,
		// or a route opened up) releases it after the grace window — commitment, not thrash.
		if (_spot_useful(S.spot)) {
			S.lost_t = 0.0f;
		} else {
			S.lost_t += dt;
			if (S.lost_t > _goal_lost_grace) { _struct_release(k); continue; }
		}
	}

	if ((_tick % (uint32_t)_recruit_interval) == 0)
		for (int k = 0; k < (int)_structs.size(); k++) _recruit(_structs[k], k);

	// Propose a new pile: the best spot that has held its own jam for long enough and is far
	// enough from the piles that already exist. The separation is what gives a group stuck on
	// the far side of the compound its own ramp instead of a long walk to someone else's.
	if (sel_tick && (int)_structs.size() < MAX_STRUCTURES) {
		int pick = -1;
		float best = -1e18f;
		for (int s = 0; s < (int)_spots.size(); s++) {
			if (_spot_score[s] < -1e8f) continue;
			if (_spot_sustain[s] < _density_sustain) continue;
			if (_struct_at_spot(s) >= 0) continue;
			bool too_close = false;
			for (size_t k = 0; k < _structs.size(); k++)
				if (_structs[k].spot.base.distance_to(_spots[s].base) < _struct_min_sep) { too_close = true; break; }
			if (too_close) continue;
			if (_spot_score[s] > best) { best = _spot_score[s]; pick = s; }
		}
		if (pick >= 0) _struct_begin(pick);
	}
}

// --------------------------------------------------------------- movement
void SwarmCore::_movement() {
	if (!_has_goal) return;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		// Frozen bodies are static geometry. Skipped before anything else is even read: no
		// steering, no path evaluation, no animation state. They are the ramp now (§6.4).
		if (_state[i] == ST_FROZEN) continue;

		// `dt` below is this agent's slice of the tick, not the tick — shortened when
		// it is standing in a stasis field. Travel, fall, turn and the
		// stuck/scrabble timers all stretch together, so a slowed zombie is slow in
		// every way rather than moving slowly while its timers run at full speed.
		const float dt = TICK_DT * _tscale[i];

		Vector3 p = _position[i];

		// --- naked spirits: no field, no obstacles, no pile ---
		// A ghost phases through walls, so every one of those systems is about a problem it
		// does not have. It flies at the goal. This runs before the climb states on purpose:
		// a spirit is never recruited into a pile, because a pile is a ramp for things that
		// cannot walk through the wall it is stacked against.
		if (_kind[i] == KIND_GHOST) {
			Vector3 to = _path_goal - p;
			to.y = 0.0f;
			float d = to.length();
			Vector3 np = p;
			if (d > _stop_radius) {
				Vector3 step = to / d * std::min(d - _stop_radius, _ghost_speed * dt);
				np = p + step;
			}
			// Drift toward the hover height, with a slow per-agent bob so a wave reads as a
			// crowd of floating things rather than a flat sheet of them. `_anim_phase` is
			// already per-agent and already advanced below, so it doubles as the offset.
			float want_y = _ghost_hover + std::sin(_anim_phase[i] * (float)Math_TAU) * _ghost_bob;
			np.y = p.y + (want_y - p.y) * std::min(1.0f, 2.0f * dt);
			_prev_position[i] = p;
			_position[i] = np;
			_velocity[i] = dt > 0.0f ? (np - p) / dt : Vector3();
			_turn_toward(i, to);
			_anim_phase[i] += _phase_rate * 0.5f * dt;
			if (_anim_phase[i] >= 1.0f) _anim_phase[i] -= 1.0f;
			continue;
		}

		// --- lane walkers: an authored route, not the flow field ---
		// Beside the spirit branch and above the climb states for the same reason: the lane
		// was authored around the obstacles and there is no pile to recruit into. What it
		// still shares with the horde is the de-overlap pass, which runs after movement for
		// every state — a queue backed up at a barricade has to stop standing inside itself.
		if (_state[i] == ST_LANE) {
			_lane_move(i, dt);
			continue;
		}

		int k = _climb_struct[i];
		if ((_state[i] == ST_BODY || _state[i] == ST_CLIMBER) && (k < 0 || k >= (int)_structs.size())) {
			_state[i] = ST_GROUND; // its structure was released out from under it
			_climb_slot[i] = -1;
			_climb_struct[i] = -1;
			_lean[i] = 0.0f;
		}

		// --- climb states: driven by the pile, not the field ---
		if (_state[i] == ST_BODY) {
			// Walks to its cell — across the ground, then UP the pile that is already there,
			// rising as it closes rather than being placed on a canned arc. Reaching the cell
			// does not make it part of the heap; it stands there scrabbling until something
			// runs it over.
			ClimbStructure &S = _structs[k];
			Vector3 slot = S.slot_pos[_climb_slot[i]];
			Vector3 to = slot - p;
			to.y = 0.0f;
			float d = to.length();
			if (d < 0.25f) {
				_state[i] = ST_STUCK;
				_stuck_t[i] = 0.0f;
		_fall_v[i] = 0.0f;
				continue;
			}
			Vector3 np = p + to / d * std::min(d, _move_speed * dt);
			// Climb onto the heap over the last couple of metres, so they walk up its flank.
			float t = 1.0f - std::min(1.0f, d / 2.0f);
			np.y = p.y + (slot.y - p.y) * std::min(1.0f, t * 0.25f + 0.06f);
			_prev_position[i] = p;
			_position[i] = np;
			_velocity[i] = (np - p) / dt;
			Vector3 tp = _player_pos - np;
			_yaw[i] = std::atan2(tp.x, tp.z); // always facing what it wants, not what it is on
			_lean[i] = 0.25f;
			continue;
		}
		if (_state[i] == ST_FALLING) {
			// Ballistic, keeping whatever horizontal speed it left with, and it lands on the pile
			// surface if there is one under it — so a body dropping onto a heap hits the heap and
			// runs down it rather than passing through to the floor.
			_fall_v[i] -= _gravity * dt;
			Vector3 np = p + _velocity[i] * dt;
			np.y = p.y + _fall_v[i] * dt;
			float g = _pile_h_at(np);
			_prev_position[i] = p;
			if (np.y <= g) {
				np.y = g;
				_state[i] = ST_GROUND;
				_fall_v[i] = 0.0f;
				_velocity[i] = _velocity[i] * 0.35f; // stumble on landing
			}
			_position[i] = np;
			_lean[i] = 0.0f;
			continue;
		}
		if (_state[i] == ST_STUCK) {
			// At the top of what the pile can give it, clawing at the wall and going nowhere.
			// It joins the heap only when the one behind walks over it — that is the trample,
			// and it is an event, not an assignment. Nothing comes, it stands here.
			ClimbStructure &S = _structs[k];
			_stuck_t[i] += dt;
			_velocity[i] = Vector3();
			Vector3 tp = _player_pos - p;
			_yaw[i] = std::atan2(tp.x, tp.z);
			_lean[i] = 0.30f + 0.12f * std::sin(_stuck_t[i] * 7.0f); // scrabbling at the face
			_prev_position[i] = p;
			if (_trampled(i, p)) {
				_state[i] = ST_CROUCH;
				_stuck_t[i] = 0.0f;
			}
			continue;
		}
		if (_state[i] == ST_CROUCH) {
			// Being walked over. It ducks under the one climbing across it and settles onto its
			// cell, then it is heap. This is why the pile grows downward-ish instead of jacking
			// everything standing on it into the air.
			ClimbStructure &S = _structs[k];
			_stuck_t[i] += dt;
			float t = std::min(1.0f, _stuck_t[i] / _crouch_time);
			int slot = _climb_slot[i];
			Vector3 target = (slot >= 0 && slot < (int)S.slot_pos.size()) ? S.slot_pos[slot] : p;
			Vector3 np = p.lerp(target, std::min(1.0f, t * 0.35f));
			_prev_position[i] = p;
			_position[i] = np;
			_velocity[i] = Vector3();
			_lean[i] = 0.30f + (1.5708f - 0.30f) * t; // crouch, then flat
			if (t >= 1.0f) { _freeze(i, S); continue; }
			continue;
		}
		if (_state[i] == ST_CLIMBER) {
			ClimbStructure &S = _structs[k];
			int slot = _climb_slot[i];  // >= 0 → filling a cell, -1 → going over the top
			float s = _climb_prog[i];
			float lean = 0.0f;
			_prev_position[i] = p;
			if (slot >= 0) {
				float len = _filler_path_len(S, slot, _climb_start[i]);
				s += _pile_speed * dt;
				if (s >= len) { _freeze(i, S); continue; } // reached the top of the heap: stop here
				_climb_prog[i] = s;
				_position[i] = _filler_path_pos(S, slot, _climb_start[i], s, &lean);
			} else {
				// The heap can shrink under a crosser when its bodies are shot. If the lip is no
				// longer in reach, slide back down and queue again — the ramp visibly fails (§6.5).
				float seg0 = _climb_seg0[i];
				float path_len = S.path_len - S.seg_pile + seg0;
				if (!S.crossable && s < seg0 + S.seg_wall) {
					_state[i] = ST_GROUND;
					_climb_struct[i] = -1;
					_climb_prog[i] = 0.0f;
					_lean[i] = 0.0f;
					_position[i] = S.spot.base;
					continue;
				}
				float sp = (s < seg0) ? _pile_speed
						: (s < seg0 + S.seg_wall) ? _wall_speed
						: (s < seg0 + S.seg_wall + S.seg_mantle) ? _mantle_speed
						: _drop_speed;
				s += sp * dt;
				_climb_prog[i] = s;
				if (s >= path_len) { // over the top
					_crossings++;
					_position[i] = S.spot.top;
					_climb_struct[i] = -1;
					_lean[i] = 0.0f;
					_velocity[i] = Vector3();
					_yaw[i] = S.wall_yaw;
					if (S.spot.surface < 0) { // over the lip: fall the rest of the way in
						_state[i] = ST_FALLING;
						_fall_v[i] = 0.0f;
						_climb_slot[i] = -1;
						_climb_prog[i] = 0.0f;
					} else {
						_state[i] = ST_ELEVATED;
						_climb_slot[i] = S.spot.surface; // fields reused for elevated agents (header)
						_climb_prog[i] = S.spot.top.y;
					}
					continue;
				}
				_position[i] = _cross_path_pos(S, s, _climb_start[i], seg0, &lean);
			}
			_velocity[i] = Vector3();
			_yaw[i] = S.wall_yaw;
			_lean[i] = lean;
			continue;
		}
		if (_state[i] == ST_ELEVATED) {
			float surf_y = _climb_prog[i];
			int sv = _climb_slot[i];
			Vector3 to = _player_pos - p;
			to.y = 0.0f;
			float d = to.length();
			Vector3 desired = (d > 1.2f) ? to / d * _move_speed : Vector3();
			Vector3 v = _velocity[i].lerp(desired, 0.2f);
			v.y = 0.0f;
			Vector3 np = p + v * dt;
			np.y = surf_y;                          // stay on the platform surface
			// Chased the player off the edge — drop back into the ground horde rather than
			// walk on air. Cheap stand-in for a fall (no physics body involved).
			if (sv >= 0 && !_on_surface(sv, np)) {
				// Chased the player off the edge. It falls from here — it used to snap to the
				// floor, which read as a teleport.
				_state[i] = ST_FALLING;
				_climb_slot[i] = -1;
				_climb_prog[i] = 0.0f;
				_lean[i] = 0.0f;
				_fall_v[i] = 0.0f;
				np.y = p.y;
			}
			_prev_position[i] = _position[i];
			_position[i] = np;
			_velocity[i] = v;
			if (v.length_squared() > 0.0004f) _yaw[i] = std::atan2(v.x, v.z);
			continue;
		}

		// --- ground agents ---
		// They do not plan. A zombie wants the player and walks at the player; it does not
		// route to a climb marker and queue there. Everything about where a pile ends up is a
		// consequence of where the horde jams trying to reach them.
		// Obstruction, measured over last tick: how far it got versus how far it was TOLD to go.
		// Comparing against the commanded speed (not the raw desire) keeps this a negative
		// feedback loop — easing off lowers the bar too, so an eased agent stops looking blocked
		// and can recover. Comparing against the un-eased desire instead makes it run away and
		// freeze the entire horde solid, which is exactly what it did the first time.
		// `p` is post-overlap-resolution, so crowd shoving counts as obstruction as well.
		{
			float want = _cmd_speed[i] * dt;
			float got = p.distance_to(_prev_position[i]);
			float shortfall = (want > 0.01f) ? (1.0f - std::min(1.0f, got / want)) : 0.0f;
			_jam[i] += (shortfall - _jam[i]) * _jam_smooth;
			if (_jam[i] < 0.0f) _jam[i] = 0.0f;
			else if (_jam[i] > 1.0f) _jam[i] = 1.0f;
		}
		float ease = 1.0f - _jam[i] * _jam_max;

		Vector3 goal = _path_goal;
		Vector3 to_goal = goal - p;
		to_goal.y = 0.0f;
		float dist = to_goal.length();
		Vector3 desired;
		bool field_hit = false;
		if (_field_ready) {
			int fc = _fcell_of(p);
			if (_cost[fc] != INF_COST) {
				Vector3 fd(_dirx[fc], 0.0f, _dirz[fc]);
				if (fd.length_squared() > 0.01f) desired = fd * _move_speed;
				field_hit = true;
			}
		}
		float stop_r = _stop_radius;
		if (!field_hit && dist > stop_r) desired = to_goal / dist * _move_speed;
		if (dist <= stop_r) desired = Vector3(); // arrived

		// Wedged agents stop shoving. Both the push toward the goal and the shuffle away from
		// neighbours are eased off, so a packed crowd settles into a still mass rather than
		// buzzing in place; the positional pass still guarantees they do not interpenetrate.
		desired *= ease;
		Vector3 steer = desired + _separation(i, p) * _sep_strength * ease;
		Vector3 v = _velocity[i].lerp(steer, 0.2f);
		v *= (1.0f - _jam[i] * 0.5f);
		float sp = v.length();
		if (sp > _move_speed) v = v / sp * _move_speed;
		if (sp < 0.05f) v = Vector3(); // below a shuffle: park it, do not drift
		v.y = 0.0f;
		Vector3 np = p + v * dt;
		np.y = p.y;

		// Static obstacle collision (§7: physics colliders are world-geo only). The field
		// steers around walls, but crowd pressure can shove an agent into a blocked cell —
		// reject that and slide along the wall so the horde funnels instead of clipping.
		if (_blocked[_fcell_of(np)]) {
			Vector3 slide_x(np.x, p.y, p.z);
			Vector3 slide_z(p.x, p.y, np.z);
			if (!_blocked[_fcell_of(slide_x)]) np = slide_x;
			else if (!_blocked[_fcell_of(slide_z)]) np = slide_z;
			else np = p; // boxed in — hold position this tick
			v = (np - p) / dt; // kill the into-wall component so it can't build up
		}

		// Follow the pile surface. A heap is ground, so they walk up it, over it and down the
		// other side instead of stopping dead against it — but only where the rise is walkable.
		// Anything steeper is a face, and getting up a face is the climb system's job.
		float surf = _pile_h_at(np);
		float rise = surf - p.y;
		if (rise > _max_step) {
			Vector3 sx(np.x, p.y, p.z);
			Vector3 sz(p.x, p.y, np.z);
			if (_pile_h_at(sx) - p.y <= _max_step && !_blocked[_fcell_of(sx)]) np = sx;
			else if (_pile_h_at(sz) - p.y <= _max_step && !_blocked[_fcell_of(sz)]) np = sz;
			else np = p;
			v = (np - p) / dt;
			surf = _pile_h_at(np);
			rise = surf - p.y;
		}
		// The heap grows under whoever is standing on it. Rate-limit how fast that carries them
		// up, so they walk up onto the new height instead of levitating with the surface.
		if (rise > 0.0f) {
			float cap = _surf_rise * dt;
			if (rise > cap) { surf = p.y + cap; rise = cap; }
		}
		// Walking off the top of a heap is a fall, not a step down.
		if (rise < -0.45f) {
			_state[i] = ST_FALLING;
			_fall_v[i] = 0.0f;
			_velocity[i] = v;
			_prev_position[i] = p;
			_position[i] = Vector3(np.x, p.y, np.z);
			continue;
		}
		np.y = surf;

		_cmd_speed[i] = v.length();
		_velocity[i] = v;
		_prev_position[i] = _position[i];
		_position[i] = np;
		// Face where it is trying to get to, not where the crowd shoved it. Under pressure the
		// steering direction reverses from tick to tick; following that is what made them
		// twitch. Wedged agents hold the goal heading and turn at a bounded rate.
		Vector3 face_dir = (_jam[i] > 0.35f || v.length_squared() < 0.09f) ? to_goal : v;
		_turn_toward(i, face_dir);
	}
}

// Hard positional de-overlap (§7). The steering force in _movement is a *preference*; when 500
// agents all seek the same point the seek term simply outvotes it and they end up inside each
// other. This runs after integration and moves them apart on position, which cannot be
// outvoted. Pairs are visited once (j > i) and pushed half each, so the crowd stays symmetric.
void SwarmCore::_resolve_overlap() {
	const float dmin = 2.0f * _agent_radius;
	const float dmin2 = dmin * dmin;
	for (int pass = 0; pass < _overlap_passes; pass++) {
		bool last = (pass == _overlap_passes - 1);
		if (last) _overlap_pairs = 0;
		for (int a = 0; a < _hashed_count; a++) {
			int i = _order[a];
			uint8_t si = _state[i];
			if (si != ST_GROUND && si != ST_ELEVATED) continue;
			// Spirits do not collide — with the world or with each other. Two ghosts
			// occupying the same metre of air is fine; shoving them apart on position
			// would be the one physical thing about them.
			if (_kind[i] == KIND_GHOST) continue;
			Vector3 p = _position[i];
			int gx = (int)((p.x - _grid_origin.x) / _cell_size);
			int gz = (int)((p.z - _grid_origin.z) / _cell_size);
			for (int dx = -1; dx <= 1; dx++) {
				int cx = gx + dx;
				if (cx < 0 || cx >= _grid_dim) continue;
				for (int dz = -1; dz <= 1; dz++) {
					int cz = gz + dz;
					if (cz < 0 || cz >= _grid_dim) continue;
					int c = cx * _grid_dim + cz;
					for (int k = _cell_start[c]; k < _cell_fill[c]; k++) {
						int j = _order[k];
						if (j <= i) continue; // each pair once
						uint8_t sj = _state[j];
						if (sj != ST_GROUND && sj != ST_ELEVATED) continue;
						if (_kind[j] == KIND_GHOST) continue;   // nothing to push against
						Vector3 q = _position[j];
						if (std::fabs(q.y - p.y) > 0.9f) continue; // different storey
						Vector3 d = p - q;
						d.y = 0.0f;
						float dl2 = d.length_squared();
						if (dl2 >= dmin2) continue;
						// Only count real interpenetration: touching shoulders is a crowd,
						// a quarter of a body inside another one is the bug (§12).
						if (last && dl2 < dmin2 * 0.56f) _overlap_pairs++;
						float dl = std::sqrt(dl2);
						Vector3 dir;
						if (dl > 0.0001f) {
							dir = d / dl;
						} else { // exactly coincident — deterministic scatter, never random
							uint32_t h = (uint32_t)(i * 2654435761u) ^ (uint32_t)j;
							float ang = (float)(h & 1023) / 1023.0f * (float)Math_TAU;
							dir = Vector3(std::cos(ang), 0.0f, std::sin(ang));
							dl = 0.0f;
						}
						Vector3 push = dir * ((dmin - dl) * 0.5f * _overlap_relax);
						Vector3 np = p + push;
						Vector3 nq = q - push;
						// Never resolve an overlap by shoving someone inside a wall.
						if (!_blocked[_fcell_of(np)]) { p = np; _position[i] = np; }
						if (!_blocked[_fcell_of(nq)]) _position[j] = nq;
					}
				}
			}
		}
	}
}

// Has anything walked over this one? Any live agent still trying to get somewhere, close enough
// to be standing on it, counts. This is what turns a stuck zombie into pile: the horde behind
// does it, so a pile only grows while there is pressure behind it (§6.3).
bool SwarmCore::_trampled(int i, const Vector3 &p) const {
	float r2 = _trample_radius * _trample_radius;
	int gx = (int)((p.x - _grid_origin.x) / _cell_size);
	int gz = (int)((p.z - _grid_origin.z) / _cell_size);
	for (int dx = -1; dx <= 1; dx++) {
		int cx = gx + dx;
		if (cx < 0 || cx >= _grid_dim) continue;
		for (int dz = -1; dz <= 1; dz++) {
			int cz = gz + dz;
			if (cz < 0 || cz >= _grid_dim) continue;
			int cc = cx * _grid_dim + cz;
			for (int q = _cell_start[cc]; q < _cell_fill[cc]; q++) {
				int j = _order[q];
				if (j == i) continue;
				uint8_t sj = _state[j];
				if (sj != ST_GROUND && sj != ST_BODY && sj != ST_CLIMBER) continue;
				if (_state[i] == ST_CROUCH) continue; // already going down
				Vector3 d = _position[j] - p;
				d.y = 0.0f;
				if (d.length_squared() < r2) return true;
			}
		}
	}
	return false;
}

// Turn toward a heading at a bounded rate, taking the short way round.
void SwarmCore::_turn_toward(int i, const Vector3 &dir) {
	if (dir.length_squared() < 0.0001f) return;
	float want = std::atan2(dir.x, dir.z);
	float d = want - _yaw[i];
	while (d > (float)Math_PI) d -= (float)Math_TAU;
	while (d < -(float)Math_PI) d += (float)Math_TAU;
	float step = _yaw_rate * TICK_DT * _tscale[i];   // slowed agents turn slowly too
	if (d > step) d = step;
	else if (d < -step) d = -step;
	_yaw[i] += d;
}

// Stamp the pile's height into the terrain field. Rebuilt on the same event that rebuilds the
// mound mesh, from the same bodies, so the thing you walk on and the thing you see are the same
// thing. A falloff dome per body means the result is already smooth enough to walk up.
void SwarmCore::_rebuild_pile_field() {
	if (_pile_h_field.empty()) return;
	std::fill(_pile_h_field.begin(), _pile_h_field.end(), 0.0f);
	const float spread = 0.95f;
	const float top = 0.50f; // how far above its own cell a body raises the surface
	int r = (int)std::ceil(spread / _fcs);
	auto stamp = [&](const Vector3 &p) {
		int gx = (int)((p.x - _forigin.x) / _fcs);
		int gz = (int)((p.z - _forigin.z) / _fcs);
		for (int dx = -r; dx <= r; dx++) {
			int cx = gx + dx;
			if (cx < 0 || cx >= _fdim) continue;
			for (int dz = -r; dz <= r; dz++) {
				int cz = gz + dz;
				if (cz < 0 || cz >= _fdim) continue;
				float d = std::sqrt((float)(dx * dx + dz * dz)) * _fcs;
				if (d > spread) continue;
				float t = 1.0f - d / spread;
				float v = p.y + top * t * t * (3.0f - 2.0f * t);
				float &cell = _pile_h_field[cx * _fdim + cz];
				if (v > cell) cell = v;
			}
		}
	};
	for (size_t i = 0; i < _corpses.size(); i++) stamp(_corpses[i].pos);
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_state[i] == ST_FROZEN) stamp(_position[i]);
		// A body mid-crouch counts too, at a fraction of its height: the one climbing across it
		// rises as it sinks, which is what reads as being trampled rather than as the heap
		// silently gaining a layer under everybody.
		else if (_state[i] == ST_CROUCH) {
			Vector3 q = _position[i];
			q.y -= top * 0.45f;
			stamp(q);
		}
	}

	// Nothing may raise the walkable surface into a ceiling — a pile spreading under a slab was
	// pushing heads through it even where the spot itself had been rejected for headroom.
	for (int cx = 0; cx < _fdim; cx++) {
		for (int cz = 0; cz < _fdim; cz++) {
			int idx = cx * _fdim + cz;
			if (_pile_h_field[idx] <= 0.01f) continue;
			Vector3 wp(_forigin.x + ((float)cx + 0.5f) * _fcs, 0.0f, _forigin.z + ((float)cz + 0.5f) * _fcs);
			float ceil_y = _ceiling_at(wp, 0.0f);
			if (ceil_y > 1e8f) continue;
			float cap = ceil_y - _headroom;
			if (_pile_h_field[idx] > cap) _pile_h_field[idx] = std::max(0.0f, cap);
		}
	}
	_pile_mask_dirty = false;
}

float SwarmCore::_pile_h_at(const Vector3 &p) const {
	if (_pile_h_field.empty()) return 0.0f;
	return _pile_h_field[_fcell_of(p)];
}

// Inverse-distance push from neighbours in the 3x3 cell block (crude avoidance; ORCA = Phase 3).
Vector3 SwarmCore::_separation(int self_i, const Vector3 &p) const {
	Vector3 push;
	int gx = (int)((p.x - _grid_origin.x) / _cell_size);
	int gz = (int)((p.z - _grid_origin.z) / _cell_size);
	for (int dx = -1; dx <= 1; dx++) {
		int cx = gx + dx;
		if (cx < 0 || cx >= _grid_dim) continue;
		for (int dz = -1; dz <= 1; dz++) {
			int cz = gz + dz;
			if (cz < 0 || cz >= _grid_dim) continue;
			int c = cx * _grid_dim + cz;
			int s = _cell_start[c];
			int e = _cell_fill[c];
			for (int k = s; k < e; k++) {
				int j = _order[k];
				if (j == self_i) continue;
				Vector3 d = p - _position[j];
				d.y = 0.0f;
				float dl = d.length();
				if (dl > 0.0001f && dl < _sep_radius) push += d / dl * (1.0f - dl / _sep_radius);
			}
		}
	}
	return push;
}

// ------------------------------------------------------------------ tiering (§3)
// Budget-first, distance-ranked: sort alive by distance to camera, walk filling budgets.
void SwarmCore::_assign_tiers() {
	for (int t = 0; t < 5; t++) _tier_counts[t] = 0;

	std::vector<std::pair<float, int>> ranked;
	ranked.reserve(_alive_count);
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		float d = _position[i].distance_to(_camera_pos);
		if (d > _cull_dist) {
			_tier[i] = TIER_CULLED;
			_tier_counts[TIER_CULLED]++;
			continue;
		}
		ranked.push_back(std::make_pair(d, i));
	}
	std::sort(ranked.begin(), ranked.end(),
			[](const std::pair<float, int> &a, const std::pair<float, int> &b) { return a.first < b.first; });

	int budget[4] = { _tier_budget[0], _tier_budget[1], _tier_budget[2], _tier_budget[3] };
	for (size_t r = 0; r < ranked.size(); r++) {
		int idx = ranked[r].second;
		int placed = TIER_FAR;
		for (int t = 0; t < 4; t++) {
			if (budget[t] > 0) { budget[t]--; placed = t; break; }
		}
		_tier[idx] = (uint8_t)placed;
		_tier_counts[placed]++;
	}
}

// ------------------------------------------------------------------ node pool (§4.1)
void SwarmCore::set_node_pool(int max_tier, int budget) {
	_node_tier_max = max_tier;
	_node_budget = budget < 0 ? 0 : (budget > MAX_NODES ? MAX_NODES : budget);
	for (int i = 0; i < MAX_AGENTS; i++) _node_slot[i] = -1;
	for (int s = 0; s < MAX_NODES; s++) _slot_agent[s] = -1;
	_slice.resize(MAX_NODES * SLICE_STRIDE);
	for (int k = 0; k < MAX_NODES * SLICE_STRIDE; k++) _slice.set(k, 0.0f);
}

// Keep an actor on the same agent for as long as that agent still deserves one. Only slots
// whose agent died or dropped out of the node tiers are recycled, and they go to the closest
// unassigned candidate — so the pool churns a few slots a frame instead of reshuffling wholesale.
void SwarmCore::_assign_nodes() {
	if (_node_tier_max < 0 || _node_budget == 0) return;

	// Hold a slot until the agent is gone, not until it slips a tier. Tier assignment is a
	// budgeted sort with no hysteresis yet (§3.3), so agents at a boundary flip tier every
	// frame; releasing on that would pop actors in and out and reset their animation phase.
	for (int s = 0; s < _node_budget; s++) {
		int a = _slot_agent[s];
		if (a < 0) continue;
		bool keep = (_flags[a] & FLAG_ALIVE) && _state[a] != ST_FROZEN && _tier[a] != TIER_CULLED;
		if (!keep) {
			_node_slot[a] = -1;
			_slot_agent[s] = -1;
		}
	}
	// Candidates: in-tier agents without a slot, nearest to the camera first.
	std::vector<std::pair<float, int>> want;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_tier[i] > _node_tier_max || _state[i] == ST_FROZEN) continue;
		if (_node_slot[i] >= 0) continue;
		want.push_back(std::make_pair(_position[i].distance_squared_to(_camera_pos), i));
	}
	if (!want.empty())
		std::sort(want.begin(), want.end(),
				[](const std::pair<float, int> &a, const std::pair<float, int> &b) { return a.first < b.first; });

	size_t w = 0;
	for (int s = 0; s < _node_budget && w < want.size(); s++) {
		if (_slot_agent[s] >= 0) continue;
		int i = want[w++].second;
		_slot_agent[s] = i;
		_node_slot[i] = (int16_t)s;
	}
	// Pool full and better candidates waiting: hand a slot over only when the newcomer is
	// clearly closer than the sitting tenant, never on a tie. That margin is the hysteresis —
	// two agents at the same distance can't trade the slot back and forth every frame.
	if (w < want.size()) {
		const float margin = 3.0f; // metres closer before it is worth the swap
		for (int s = 0; s < _node_budget && w < want.size(); s++) {
			int a = _slot_agent[s];
			if (a < 0) continue;
			float held = _position[a].distance_to(_camera_pos);
			float cand = std::sqrt(want[w].first);
			if (cand + margin >= held) continue;
			_node_slot[a] = -1;
			int i = want[w++].second;
			_slot_agent[s] = i;
			_node_slot[i] = (int16_t)s;
		}
	}
	_node_used = 0;
	for (int s = 0; s < _node_budget; s++)
		if (_slot_agent[s] >= 0) _node_used++;
}

void SwarmCore::_write_slice(float alpha) {
	if (_node_tier_max < 0 || _node_budget == 0) return;
	float *w = _slice.ptrw();
	for (int s = 0; s < _node_budget; s++) {
		int o = s * SLICE_STRIDE;
		int i = _slot_agent[s];
		if (i < 0) {
			w[o] = 0.0f;
			continue;
		}
		// Same interpolation alpha the MultiMesh uses, so actors and instances never disagree
		// about where an agent is at the moment one is swapped for the other.
		Vector3 p = _prev_position[i].lerp(_position[i], alpha);
		w[o + 0] = 1.0f;
		w[o + 1] = p.x;
		w[o + 2] = p.y;
		w[o + 3] = p.z;
		w[o + 4] = _yaw[i];
		w[o + 5] = _lean[i];
		w[o + 6] = (float)_state[i];
		w[o + 7] = (float)_tier[i];
		w[o + 8] = _velocity[i].length();
		w[o + 9] = (float)i;             // which agent — GDScript spots a slot changing hands
		w[o + 10] = _anim_phase[i];      // ...and resumes its cycle instead of restarting
	}
}

// ------------------------------------------------------------------ render (§4)
// Write only visible, in-tier instances (MultiMesh does NOT cull per instance, §4.2) into
// one interleaved buffer, then push it in a single set_buffer call. Interpolate prev->cur.
void SwarmCore::_write_multimesh(float alpha) {
	int layers = (int)_mm_buffers.size();
	if (layers == 0) return;
	std::vector<float *> buf(layers);
	std::vector<int> w(layers, 0);
	for (int k = 0; k < layers; k++) buf[k] = _mm_buffers[k].ptrw();

	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_tier[i] == TIER_CULLED) continue;
		if (_node_slot[i] >= 0) continue; // a real character node is drawing this one (§4.1)
		if (_pile_mesh_mode && _state[i] == ST_FROZEN) continue; // the mound is drawing this one
		if (_kind[i] == KIND_GHOST) continue; // its own layer — shares no geometry with these

		// Standing agents are drawn from the body's centre; a frozen pile body is lying down,
		// so its slot position is the floor of its lattice layer and the body sits half a
		// body-width above it. Keeps the heap packed instead of hovering.
		float y_off = (_state[i] == ST_FROZEN) ? _prone_y_off : _stand_y_off;
		Vector3 p = _prev_position[i].lerp(_position[i], alpha) + Vector3(0, y_off, 0);
		Basis b(Vector3(0, 1, 0), _yaw[i]);
		// Climbers/bodies pitch forward — sells the wall scramble and the mantle without any
		// animation data. Ground agents keep lean at 0, so this branch is almost never taken.
		if (_lean[i] != 0.0f) b = b * Basis(Vector3(1, 0, 0), _lean[i]);

		// White by default so a real baked mesh shows its own albedo; the tier overlay tints it.
		Color col = _overlay_tier ? TIER_COLOR[_tier[i]] : Color(1.0f, 1.0f, 1.0f);
		float hp_frac = _health[i] / (_max_health[i] > 1.0f ? _max_health[i] : 1.0f);
		if (hp_frac < 0.25f) hp_frac = 0.25f; else if (hp_frac > 1.0f) hp_frac = 1.0f;
		col = col * hp_frac;

		// Which pose this agent is currently in. Frozen bodies hold pose 0 — they are not
		// walking anywhere.
		int layer = 0;
		if (_poses_per_set > 1 && _state[i] != ST_FROZEN) {
			layer = (int)(_anim_phase[i] * (float)_poses_per_set);
			if (layer < 0) layer = 0;
			else if (layer >= _poses_per_set) layer = _poses_per_set - 1;
		}
		// Gait set: match what a close-up actor would be playing at this speed.
		if (_mm_sets > 1 && _state[i] != ST_FROZEN && _velocity[i].length() > _run_speed)
			layer += _poses_per_set;
		if (layer >= layers) layer = layers - 1;

		int o = w[layer] * MM_STRIDE;
		float *bl = buf[layer];
		bl[o + 0] = b[0][0]; bl[o + 1] = b[0][1]; bl[o + 2] = b[0][2]; bl[o + 3] = p.x;
		bl[o + 4] = b[1][0]; bl[o + 5] = b[1][1]; bl[o + 6] = b[1][2]; bl[o + 7] = p.y;
		bl[o + 8] = b[2][0]; bl[o + 9] = b[2][1]; bl[o + 10] = b[2][2]; bl[o + 11] = p.z;
		bl[o + 12] = col.r; bl[o + 13] = col.g; bl[o + 14] = col.b; bl[o + 15] = col.a;
		w[layer]++;
	}

	_visible_count = 0;
	for (int k = 0; k < layers; k++) {
		_mms[k]->set_buffer(_mm_buffers[k]);
		_mms[k]->set_visible_instance_count(w[k]);
		_visible_count += w[k];
	}
	_write_ghosts(alpha);
	_visible_count += _ghost_visible;
}

// Spirits, in their own MultiMesh. Not a pose bucket in the body layers: they share none
// of that geometry and none of the locomotion phase that selects it, and mixing them in
// would mean every wave-spawned ghost had to be drawn as a walking corpse.
//
// No lean, no gait, no health tint — a ghost's health is not a shade of its albedo, it is
// how transparent it is, which is the alpha channel doing an honest job.
void SwarmCore::_write_ghosts(float alpha) {
	_ghost_visible = 0;
	if (_gmm.is_null()) return;
	float *b = _gmm_buffer.ptrw();
	int w = 0;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_kind[i] != KIND_GHOST) continue;
		if (_tier[i] == TIER_CULLED) continue;
		if (_node_slot[i] >= 0) continue;
		Vector3 p = _prev_position[i].lerp(_position[i], alpha);
		Basis ba(Vector3(0, 1, 0), _yaw[i]);
		float hp = _health[i] / (_max_health[i] > 1.0f ? _max_health[i] : 1.0f);
		if (hp < 0.2f) hp = 0.2f; else if (hp > 1.0f) hp = 1.0f;
		int o = w * MM_STRIDE;
		b[o + 0] = ba[0][0]; b[o + 1] = ba[0][1]; b[o + 2] = ba[0][2]; b[o + 3] = p.x;
		b[o + 4] = ba[1][0]; b[o + 5] = ba[1][1]; b[o + 6] = ba[1][2]; b[o + 7] = p.y;
		b[o + 8] = ba[2][0]; b[o + 9] = ba[2][1]; b[o + 10] = ba[2][2]; b[o + 11] = p.z;
		// A draining ghost fades out. Same readout the node-side beam gives you.
		b[o + 12] = 1.0f; b[o + 13] = 1.0f; b[o + 14] = 1.0f; b[o + 15] = hp;
		w++;
	}
	_gmm->set_buffer(_gmm_buffer);
	_gmm->set_visible_instance_count(w);
	_ghost_visible = w;
}

void SwarmCore::set_ghost_mesh(const Ref<Mesh> &mesh) {
	_ghost_mesh = mesh;
	if (_gmm.is_valid() && mesh.is_valid()) _gmm->set_mesh(mesh);
}

// ------------------------------------------------------------------ hitscan (§1.3)
Dictionary SwarmCore::apply_hitscan(const Vector3 &from, const Vector3 &dir_in, float dmg) {
	Vector3 dir = dir_in.normalized();
	float best_t = _hit_range;
	int best = -1;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		// A body lying in a pile is structure, not a target. Only explosives take a mound apart
		// (§6.5) — otherwise stray fire into a wall of bodies quietly collapses the ramp.
		if (_state[i] == ST_FROZEN) continue;
		// A bullet goes straight through a naked spirit. Not a miss and not a 0-damage hit:
		// the ray must not even be consumed by it, or a ghost drifting between the player
		// and a body would act as cover for the thing you were actually shooting at.
		if (_kind[i] == KIND_GHOST) continue;
		Vector3 rel = (_position[i] + _body_center) - from;
		float t = rel.dot(dir);
		if (t < 0.0f || t > best_t) continue;
		float perp = (rel - dir * t).length();
		if (perp < _hit_radius) { best_t = t; best = i; }
	}
	Dictionary out;
	if (best < 0) return out;
	float before = _health[best];
	_health[best] = before - dmg;
	bool killed = _health[best] <= 0.0f;
	out["handle"] = make_handle(best);
	out["point"] = from + dir * best_t;
	out["dealt"] = std::min(dmg, before);
	out["killed"] = killed;
	if (killed) _kill(best);
	return out;
}

// Radial damage against the hash (§1.3). Kills remove agents from the sim immediately, but
// their death EFFECTS go to the queue (§8.4) — the caller drains them a few per frame via
// poll_deaths(), so a 100-kill grenade never dumps 100 VFX spawns in one frame.
int SwarmCore::apply_radial_damage(const Vector3 &center, float radius, float dmg) {
	int kills = 0;
	float r2 = radius * radius;
	kills += _blast_corpses(center, radius, dmg); // a mound is only destructible by explosion
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_kind[i] == KIND_GHOST) continue;   // shrapnel does nothing to a spirit
		if (_position[i].distance_squared_to(center) <= r2) {
			_health[i] -= dmg;
			if (_health[i] <= 0.0f) {
				_push_death(_position[i] + _body_center);
				_kill(i);
				kills++;
			}
		}
	}
	return kills;
}

// --- the anti-ghost half of the arsenal -------------------------------------------
//
// Exact mirror of the kinetic calls above: those skip KIND_GHOST, these skip everything
// else. A Vacuum Beam Node or an Ecto-Sphere Mortar pouring fire into a crowd of bodies
// achieves precisely nothing, which is the same rule read from the other side and is what
// makes a hybrid wave (GDD2 §4: 70% objects, 30% naked) a real allocation problem.
int SwarmCore::apply_ecto_damage(const Vector3 &center, float radius, float dmg) {
	int kills = 0;
	float r2 = radius * radius;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_kind[i] != KIND_GHOST) continue;
		if (_position[i].distance_squared_to(center) > r2) continue;
		_health[i] -= dmg;
		if (_health[i] <= 0.0f) {
			_push_death(_position[i]);
			_kill(i);
			kills++;
		}
	}
	return kills;
}

// A held beam rather than a burst: nearest spirit in the cone takes `dmg` this call, and
// the caller passes damage-per-second × delta. Returns the same shape as apply_hitscan so
// a weapon can drive either without caring which it hit.
Dictionary SwarmCore::apply_ecto_beam(const Vector3 &from, const Vector3 &dir_in,
		float half_angle, float max_range, float dmg) {
	Dictionary out;
	Vector3 d = dir_in.normalized();
	float cos_half = std::cos(half_angle);
	float best = max_range * max_range;
	int best_i = -1;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_kind[i] != KIND_GHOST) continue;
		Vector3 rel = _position[i] - from;
		float d2 = rel.length_squared();
		if (d2 > best || d2 < 1e-4f) continue;
		if (rel.normalized().dot(d) < cos_half) continue;
		best = d2;
		best_i = i;
	}
	if (best_i < 0) return out;
	float before = _health[best_i];
	_health[best_i] = before - dmg;
	bool killed = _health[best_i] <= 0.0f;
	out["handle"] = make_handle(best_i);
	out["point"] = _position[best_i];
	out["dealt"] = std::min(dmg, before);
	out["killed"] = killed;
	if (killed) {
		_push_death(_position[best_i]);
		_kill(best_i);
	}
	return out;
}

void SwarmCore::_push_death(const Vector3 &p) {
	int tail = (_death_head + _death_count) % DEATH_CAP;
	if (_death_count < DEATH_CAP) {
		_death_pos[tail] = p;
		_death_count++;
	} else {
		// full: overwrite oldest, advance head (newest wins, §8.2)
		_death_pos[_death_head] = p;
		_death_head = (_death_head + 1) % DEATH_CAP;
	}
}

// Drain up to _deaths_per_frame queued death positions for the caller's VFX this frame.
PackedVector3Array SwarmCore::poll_deaths() {
	PackedVector3Array out;
	int n = _death_count < _deaths_per_frame ? _death_count : _deaths_per_frame;
	for (int k = 0; k < n; k++) {
		out.push_back(_death_pos[_death_head]);
		_death_head = (_death_head + 1) % DEATH_CAP;
		_death_count--;
	}
	return out;
}

void SwarmCore::set_deaths_per_frame(int n) { _deaths_per_frame = n > 1 ? n : 1; }

void SwarmCore::set_target_population(int n) {
	if (n < 0) n = 0;
	if (n > MAX_AGENTS) n = MAX_AGENTS;
	_target_population = n;
}

// Nearest agent inside an aim cone — what homing asks. Samples the body vertically so any
// part of a zombie inside the circle homes to the point closest to the centre, matching how
// the node-based version treats a capsule.
Dictionary SwarmCore::query_cone(const Vector3 &from, const Vector3 &dir_in, float half_angle, float max_range) const {
	Dictionary out;
	Vector3 dir = dir_in.normalized();
	float best_ang = half_angle;
	int best = -1;
	float r2 = max_range * max_range;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_state[i] == ST_FROZEN) continue; // a corpse in the pile is not a target
		// This is the KINETIC gun's homing query. Locking a spirit it cannot hurt would
		// pull the reticle off the body the player was actually aiming at.
		if (_kind[i] == KIND_GHOST) continue;
		if (_position[i].distance_squared_to(from) > r2) continue;
		for (int k = 0; k < 5; k++) {
			Vector3 pt = _position[i] + Vector3(0, 0.2f + 1.5f * (float)k / 4.0f, 0);
			Vector3 d = pt - from;
			float dl = d.length();
			if (dl < 0.1f) continue;
			float ang = std::acos(std::min(1.0f, std::max(-1.0f, dir.dot(d / dl))));
			if (ang < best_ang) {
				best_ang = ang;
				best = i;
			}
		}
	}
	if (best < 0) return out;
	// Candidacy comes from the silhouette — any part of the body inside the reticle counts —
	// but the point handed back is the body CENTRE. Returning the winning sample instead aims
	// homing shots at whatever scraped the cone edge, often the feet, and apply_hitscan then
	// misses by more than its hit radius: a homing gun that never hits anything.
	out["point"] = _position[best] + _body_center;
	out["angle"] = best_ang;
	return out;
}

// Damage ONE agent near a point — a ricochet bounce or a chain link. Random pick by default so
// bounces vary instead of always taking the nearest.
Dictionary SwarmCore::apply_point_damage(const Vector3 &center, float radius, float dmg, bool pick_random) {
	Dictionary out;
	float r2 = radius * radius;
	int pick = -1;
	if (pick_random) {
		int cand[64];
		int n = 0;
		for (int i = 0; i < MAX_AGENTS && n < 64; i++) {
			if ((_flags[i] & FLAG_ALIVE) == 0 || _state[i] == ST_FROZEN) continue;
			if (_kind[i] == KIND_GHOST) continue;   // a ricochet passes through a spirit
			if (_position[i].distance_squared_to(center) <= r2) cand[n++] = i;
		}
		if (n > 0) pick = cand[(int)(_rand_u32() % (uint32_t)n)];
	}
	if (pick < 0) { // nothing in range, or an explicit nearest request
		float bd = r2;
		for (int i = 0; i < MAX_AGENTS; i++) {
			if ((_flags[i] & FLAG_ALIVE) == 0 || _state[i] == ST_FROZEN) continue;
			if (_kind[i] == KIND_GHOST) continue;
			float d = _position[i].distance_squared_to(center);
			if (d < bd) { bd = d; pick = i; }
		}
	}
	if (pick < 0) return out;
	float before = _health[pick];
	_health[pick] = before - dmg;
	bool killed = _health[pick] <= 0.0f;
	out["point"] = _position[pick] + _body_center;
	out["dealt"] = std::min(dmg, before);
	out["killed"] = killed;
	if (killed) {
		_push_death(_position[pick] + _body_center);
		_kill(pick);
	}
	return out;
}

// ------------------------------------------------------------------ climb boundary (§6)
// An authored spot is just a generated one the designer placed by hand: it gets the same
// pile → wall → mantle motion, so authored and discovered spots look identical in play.
void SwarmCore::add_climb_point(const Vector3 &base, const Vector3 &top) {
	Vector3 n = Vector3(base.x - top.x, 0.0f, base.z - top.z);
	if (n.length_squared() < 0.0001f) n = Vector3(0, 0, 1);
	n = n.normalized();
	ClimbSpot s;
	s.normal = n;
	s.base = Vector3(base.x, 0.0f, base.z);
	s.face = Vector3(top.x, top.y, top.z) + n * _top_inset; // wall face in front of the landing
	s.top = top;
	s.height = top.y;
	s.surface = -1; // resolved on rebuild, once the volumes are known
	s.authored = true;
	_authored_spots.push_back(s);
	_spots_dirty = true;
}

bool SwarmCore::_in_no_climb(const Vector3 &p) const {
	for (size_t v = 0; v < _no_climb.size(); v++) {
		const Volume &b = _no_climb[v];
		if (std::fabs(p.x - b.center.x) > b.size.x * 0.5f) continue;
		if (std::fabs(p.z - b.center.z) > b.size.z * 0.5f) continue;
		if (p.y < b.center.y - b.size.y * 0.5f || p.y > b.center.y + b.size.y * 0.5f) continue;
		return true;
	}
	return false;
}

void SwarmCore::add_no_climb(const Vector3 &center, const Vector3 &size) {
	Volume b;
	b.center = center;
	b.size = size;
	b.flags = 0;
	_no_climb.push_back(b);
	_spots_dirty = true;
}

void SwarmCore::clear_no_climb() {
	_no_climb.clear();
	_spots_dirty = true;
}

void SwarmCore::clear_climb_points() {
	_authored_spots.clear();
	_spots_dirty = true;
}

void SwarmCore::set_auto_climb(bool on, float spacing, float min_height, float max_height) {
	_auto_spots = on;
	if (spacing > 0.0f) _spot_spacing = spacing;
	if (min_height > 0.0f) _min_climb_h = min_height;
	if (max_height > 0.0f) _max_climb_h = max_height;
	_spots_dirty = true;
}

// Deprecated. The core derives "the player is out of ground reach" itself — from the walkable
// volume under them and from the flow field's reachability mask — so the caller's bool is
// ignored. Only the full 3D position is taken, and set_goal_position already supplies it.
void SwarmCore::set_player_elevated(bool elevated, const Vector3 &player_pos) {
	(void)elevated;
	_player_pos = player_pos;
}

void SwarmCore::set_climb_params(int density_threshold, float density_radius, float recruit_radius, float struct_min_sep) {
	if (density_threshold > 0) _density_threshold = density_threshold;
	if (density_radius > 0.0f) _density_radius = density_radius;
	if (recruit_radius > 0.0f) _recruit_radius = recruit_radius;
	if (struct_min_sep > 0.0f) _struct_min_sep = struct_min_sep;
}

// Is this point walkable-connected to the player on the ground? False on the far side of a
// sealed wall — which is exactly where the horde has to climb (§6.2).
bool SwarmCore::is_reachable_at(const Vector3 &p) const {
	if (!_field_ready) return true;
	return _reach[_fcell_of(p)] != 0;
}

// Is this point inside a registered obstacle? The mound builder asks so a pile heaped against
// a wall stops at the face instead of growing through it and showing on the far side.
bool SwarmCore::is_blocked_at(const Vector3 &p) const {
	if (_blocked.empty()) return false;
	return _blocked[_fcell_of(p)] != 0;
}

// The real footprint, with no agent-radius inflation. The mound builder needs this rather than
// is_blocked_at: the pathing mask is grown by 0.35 m so agent CENTRES stop clear of a wall, and
// that is exactly where the front row of a pile lies — clipping against it carved the heap out
// from under its own crest bodies and left them hanging in the air.
bool SwarmCore::is_solid_at(const Vector3 &p) const {
	for (size_t v = 0; v < _volumes.size(); v++) {
		const Volume &vol = _volumes[v];
		if ((vol.flags & VOL_BLOCKS) == 0) continue;
		if (vol.center.y - vol.size.y * 0.5f > 1.0f) continue; // an overhead ledge, not a wall
		if (std::fabs(p.x - vol.center.x) > vol.size.x * 0.5f) continue;
		if (std::fabs(p.z - vol.center.z) > vol.size.z * 0.5f) continue;
		return true;
	}
	return false;
}

void SwarmCore::set_corpse_hp(float hp) { if (hp > 0.0f) _corpse_hp = hp; }

// Lets callers skip hand-written platform checks: is this position standing on a registered
// walkable volume?
bool SwarmCore::is_elevated_at(const Vector3 &p) const {
	for (int v = 0; v < (int)_volumes.size(); v++) {
		const Volume &vol = _volumes[v];
		if ((vol.flags & VOL_WALK) == 0) continue;
		float top = vol.center.y + vol.size.y * 0.5f;
		if (top < 0.75f) continue;
		if (p.y < top - 0.6f || p.y > top + 3.0f) continue;
		if (_on_surface(v, p)) return true;
	}
	return false;
}

Array SwarmCore::get_climb_spots() const {
	Array out;
	for (size_t k = 0; k < _spots.size(); k++) {
		Dictionary d;
		d["base"] = _spots[k].base;
		d["face"] = _spots[k].face;
		d["top"] = _spots[k].top;
		d["normal"] = _spots[k].normal;
		d["height"] = _spots[k].height;
		d["authored"] = _spots[k].authored;
		d["drop"] = _spots[k].drop;
		d["cone"] = _spots[k].cone;
		d["mass"] = k < _spot_mass.size() ? _spot_mass[k] : 0;
		d["score"] = k < _spot_score.size() ? _spot_score[k] : -1e9f;
		d["active"] = (_struct_at_spot((int)k) >= 0);
		out.push_back(d);
	}
	return out;
}

Array SwarmCore::get_climb_structs() const {
	Array out;
	for (size_t k = 0; k < _structs.size(); k++) {
		const ClimbStructure &S = _structs[k];
		Dictionary d;
		d["phase"] = S.phase; // 1 growing, 2 crossable, 3 stalled
		d["base"] = S.spot.base;
		d["top"] = S.spot.top;
		d["drop"] = S.spot.drop;
		d["cone"] = S.spot.cone;
		d["height"] = S.spot.height;
		d["pile_height"] = S.pile_h;
		d["filled"] = S.filled;
		d["buried"] = S.buried;
		d["slots"] = (int)S.slot_pos.size();
		d["needed"] = S.need;
		d["crossable"] = S.crossable;
		d["age"] = S.age;
		out.push_back(d);
	}
	return out;
}

Dictionary SwarmCore::get_climb_debug() const {
	Dictionary d;
	d["structures"] = (int)_structs.size();
	d["corpses"] = (int)_corpses.size();
	d["overlaps"] = _overlap_pairs;
	// Jitter probe (§12): of the agents the crowd has wedged solid, how fast are they still
	// twitching? Settled means this trends to zero — a packed mass, not a vibrating one.
	{
		int wedged = 0;
		float speed_sum = 0.0f;
		for (int i = 0; i < MAX_AGENTS; i++) {
			if ((_flags[i] & FLAG_ALIVE) == 0 || _state[i] != ST_GROUND) continue;
			if (_jam[i] < 0.6f) continue;
			wedged++;
			speed_sum += _velocity[i].length();
		}
		d["wedged"] = wedged;
		d["wedged_speed"] = wedged > 0 ? (speed_sum / (float)wedged) : 0.0f;
	}
	d["corpses_drawn"] = _corpse_visible;
	d["crossings"] = _crossings;
	d["spots"] = (int)_spots.size();
	// Headline figures come from the tallest live pile, so a one-line HUD still says something
	// useful when several are running (get_climb_structs() has them all).
	int lead = -1;
	for (size_t k = 0; k < _structs.size(); k++)
		if (lead < 0 || _structs[k].pile_h > _structs[lead].pile_h) lead = (int)k;
	d["phase"] = lead >= 0 ? _structs[lead].phase : 0; // 0 none, 1 growing, 2 crossable, 3 stalled
	d["point"] = lead >= 0 ? _structs[lead].spot_index : -1;
	d["base"] = lead >= 0 ? _structs[lead].spot.base : Vector3(0, -50, 0);
	d["top"] = lead >= 0 ? _structs[lead].spot.top : Vector3(0, -50, 0);
	d["pile_height"] = lead >= 0 ? _structs[lead].pile_h : 0.0f;
	d["path_len"] = lead >= 0 ? _structs[lead].path_len : 0.0f;
	d["bodies_needed"] = lead >= 0 ? _structs[lead].need : 0;
	d["body_arrived"] = lead >= 0 ? _structs[lead].filled : 0;
	int bodies = 0, frozen = 0, climbers = 0, elevated = 0, stuck = 0;
	for (int i = 0; i < MAX_AGENTS; i++) {
		if ((_flags[i] & FLAG_ALIVE) == 0) continue;
		if (_state[i] == ST_BODY) bodies++;
		else if (_state[i] == ST_FROZEN) frozen++;
		else if (_state[i] == ST_STUCK) stuck++;
		else if (_state[i] == ST_CLIMBER) climbers++;
		else if (_state[i] == ST_ELEVATED) elevated++;
	}
	d["bodies"] = bodies;
	d["frozen"] = frozen;
	d["stuck"] = stuck;
	d["climbers"] = climbers;
	d["elevated"] = elevated;
	return d;
}

// ------------------------------------------------------------------ debug (§12)
PackedInt32Array SwarmCore::get_tier_counts() const {
	PackedInt32Array a;
	a.resize(5);
	for (int t = 0; t < 5; t++) a.set(t, _tier_counts[t]);
	return a;
}
