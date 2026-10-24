#pragma once

// AIWorld -- what the AI asks the city (Docs/AI.md section 3, AIPlan P2).
//
// Lives in the brick extension, not an extension of its own, because its inner
// loop walks chunk occupancy cell by cell: from another DLL every cell would be
// a Variant call (AIPlan R1). It READS BrickWorld's grids and never changes them.
//
// The world is not one grid. A standing building is a chunk on the grid, a piece
// that fell off it is a chunk at any rotation, and what is not bricks at all -- a
// pristine building's shell, a sleeping piece's record -- is registered here as
// a PROXY box. A query goes broad phase first (a 2D hash of world AABBs, walked
// along the segment), then narrow: into each candidate chunk's own frame, divided
// by the stud and plate pitch, and an integer DDA through THAT chunk's occupancy.
// A tilted slab is no harder than a wall.

#include "../brick_world.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

// The global namespace, as BrickWorld is (brick_world.h), so its `friend` finds us.
using namespace godot;

class AIWorld : public RefCounted {
    GDCLASS(AIWorld, RefCounted);

protected:
    static void _bind_methods();

public:
    /// Metres per broad-phase hash cell, in X and Z.
    static constexpr float HASH_CELL = 16.0f;

    void set_world(const Ref<BrickWorld> &world);
    Ref<BrickWorld> get_world() const { return world; }

    /// Rebuild the broad phase from every live chunk. Once a frame, or after
    /// anything moved: O(chunks), a transform and eight corners each.
    void sync();
    int get_indexed_chunks() const { return (int)chunk_entries.size(); }

    // --- the line between two points ------------------------------------

    /// Everything between `from` and `to`: {bricks, hp, solid_m, hit, point,
    /// chunk, proxy_bricks, smoke}. `bricks` counts distinct live structural
    /// blocks the segment passes through, across every chunk; furniture is not
    /// cover. `hit`/`point`/`chunk` are the FIRST brick along the way.
    Dictionary trace(const Vector3 &from, const Vector3 &to);
    /// Just the count, the cheap way.
    int bricks_between(const Vector3 &from, const Vector3 &to);
    /// No brick, no proxy and no smoke between them.
    bool line_clear(const Vector3 &from, const Vector3 &to);

    /// Cover as a number (Docs/AI.md 3.7): SECONDS the bricks between a threat
    /// at `from` and a target at `to` survive a gun that takes `hp_per_hit` a
    /// round (StructuralDamage) at `hits_per_second`. Each brick by its own hp
    /// and material, with BrickWorld.chip_hit's own wear rule, so the estimate
    /// is what the gun will actually do. Proxies count at full hp.
    float cover_seconds(const Vector3 &from, const Vector3 &to, int hp_per_hit,
            float hits_per_second);
    /// Many at once: one threat, many candidate positions -- a squad's cover
    /// search is one call.
    PackedFloat32Array cover_seconds_batch(const Vector3 &from, const PackedVector3Array &to,
            int hp_per_hit, float hits_per_second);

    // --- what is not bricks ------------------------------------------------

    /// A box that stands in for bricks nobody has built: a pristine building's
    /// wall slab, a sleeping piece. `bricks_per_metre` of travel through it.
    void set_proxy(int id, const Transform3D &xform, const Vector3 &size, float bricks_per_metre);
    /// A box that is COVER and nothing else: a vehicle (Docs/AIVehicles.md 4,
    /// moving cover). Lines through it count it as a proxy's bricks -- sight,
    /// fire, cover_seconds -- but it is not solid to navigation (it moves; the
    /// walking map would be read again every time it did), and a line that
    /// starts or ends inside it does not count it: that line is to the vehicle
    /// itself, or from a crewman in it. The same ids as set_proxy; remove_proxy
    /// removes it.
    void set_cover(int id, const Transform3D &xform, const Vector3 &size, float bricks_per_metre);
    void remove_proxy(int id);
    void clear_proxies();
    int get_proxy_count() const { return (int)proxies.size(); }

    /// Smoke, as a sphere (AI.md 10.4: smoke as spheres). Blocks sight, not bullets.
    void set_smoke(int id, const Vector3 &centre, float radius);
    void remove_smoke(int id);
    void clear_smoke();
    bool smoke_blocks(const Vector3 &from, const Vector3 &to) const;

    /// Danger: somewhere not to stand -- a falling piece's box, a building about
    /// to go. Boxes, world space.
    void set_danger(int id, const AABB &box);
    void remove_danger(int id);
    void clear_danger();
    bool in_danger(const Vector3 &point) const;
    /// How far `point` is from the nearest danger box's surface; 0 inside, INF
    /// with none.
    float danger_distance(const Vector3 &point) const;

    // --- points, for navigation ----------------------------------------------

    /// Is anything solid at this world point: a live brick of any chunk
    /// (furniture included -- bodies stand on it and walk round it), or inside
    /// a proxy.
    bool solid_at(const Vector3 &point);
    /// The live brick at this world point: (chunk, block), or (-1, -1). What a
    /// foot stands on, for weight (Docs/AI.md 3.10) and the fall rule (3.11).
    Vector2i block_at(const Vector3 &point);
    /// The highest top of anything that could be solid over this XZ, or -INF
    /// with nothing there. Navigation scans a column no higher than this.
    float top_at(float x, float z);
    /// A whole column at once: out[y] = 1 where plate y (0..out.size()-1) of the
    /// column through (x, z) is solid. One pass per chunk down its own Y axis --
    /// navigation reads columns two hundred plates tall, and asking solid_at for
    /// each plate was a hash lookup a plate.
    void column_solid(float x, float z, std::vector<char> &out);

    // --- the ground ---------------------------------------------------------
    //
    // Off, the ground is the plane y = 0 and nothing here knows about it: plate
    // 0 of a column is a floor because nothing is below it. On, the ground is
    // BrickTerrain's field (Docs/Terrain.md §21.5): every plate under its
    // surface is solid to every question above -- a column has its floor on the
    // hillside, a sight line over a crest is blocked by the crest, and a body
    // behind a hill is in cover the gun cannot wear away.

    void set_terrain_ground(bool on);
    bool get_terrain_ground() const { return terrain_ground; }
    /// The top of the ground over (x, z) in metres: 0 without terrain. Region
    /// values (set_frame): from GDScript, ground_under is the world's form.
    float ground_at(float x, float z);
    /// `point` moved along the region's up onto the ground under it -- what
    /// `p.y = ground_at(p.x, p.z)` was, in world values. Unframed it is exactly that.
    Vector3 ground_under(const Vector3 &point);
    /// The highest top over `point` (top_at) as a height along the region's
    /// up: a world point over `point` at that top, or INF with nothing there.
    Vector3 top_over(const Vector3 &point);
    /// Does the ground rise between two points? The terrain half of
    /// line_clear, for eyes that see bricks some other way (physics rays):
    /// the field is everywhere, its colliders only where the detail tier is.
    bool ground_blocks(const Vector3 &from, const Vector3 &to);

    // --- a moving origin ----------------------------------------------------

    /// The scene's origin moved by `offset` (a translation-only floating origin,
    /// Docs/Planets.md 10b): every proxy, cover box, smoke sphere and danger box
    /// moves with it. Chunks follow by themselves -- sync() reads them from
    /// BrickWorld. The terrain field stays where it is: the ground is asked at
    /// the stud column the offset puts it at, so X and Z must be whole studs. Y
    /// moves boxes only: columns count plates up from y = 0 (column_solid), so a
    /// vertical shift is a datum this flat AI does not have. Framed (a planet,
    /// set_frame), the frame's origin moves instead and nothing inside does.
    void shift_origin(const Vector3 &offset);
    /// Studs between the scene's columns and the field's (X, Z).
    Vector2i get_ground_shift() const { return Vector2i(ground_dx, ground_dz); }

    // --- a region frame (Docs/Planets.md 11.8, N1) ----------------------------
    //
    // On a planet the AI sees the world through a flat REGION: inside, every
    // query, column and cache is the region's flat world (+Y up, plates from
    // 0); the bound methods take and return WORLD values, converted at the
    // boundary by the `_b_` wrappers below. C++ callers (AINav) talk region
    // values to the unwrapped methods, so nothing is converted twice. With the
    // frame identity (the flat game) every wrapper calls straight through.

    /// Region -> world. Forgets the broad phase (sync() again) and the ground.
    void set_frame(const Transform3D &region_to_world);
    Transform3D get_frame() const { return frame; }
    bool is_framed() const { return framed; }
    Vector3 to_region(const Vector3 &p) const { return framed ? frame_inv.xform(p) : p; }
    Vector3 to_world(const Vector3 &p) const { return framed ? frame.xform(p) : p; }
    Vector3 dir_to_world(const Vector3 &d) const { return framed ? frame.basis.xform(d) : d; }
    AABB box_to_region(const AABB &b) const { return framed ? frame_inv.xform(b) : b; }

    /// The ground as a grid of heights in the region (N1b, PlanetNavRegion):
    /// `size` x `size` samples `step` metres apart from region (x, z) =
    /// `origin`, row by row along +X then +Z. With terrain ground on, a stud
    /// column's ground is the grid read bilinearly at its centre in place of
    /// BrickTerrain's field; outside the grid it is a wall no body climbs.
    /// An empty `heights` goes back to the field.
    void set_ground_grid(const Vector2 &origin, float step, int size, const PackedFloat32Array &heights);
    bool has_ground_grid() const { return grid_size > 0; }

    // --- measuring ----------------------------------------------------------

    Dictionary get_stats() const;
    void reset_stats();

private:
    // The bound forms of the queries above: world in, world out (set_frame).
    Dictionary _b_trace(const Vector3 &from, const Vector3 &to);
    int _b_bricks_between(const Vector3 &from, const Vector3 &to);
    bool _b_line_clear(const Vector3 &from, const Vector3 &to);
    float _b_cover_seconds(const Vector3 &from, const Vector3 &to, int hp_per_hit,
            float hits_per_second);
    PackedFloat32Array _b_cover_seconds_batch(const Vector3 &from, const PackedVector3Array &to,
            int hp_per_hit, float hits_per_second);
    void _b_set_proxy(int id, const Transform3D &xform, const Vector3 &size, float bricks_per_metre);
    void _b_set_cover(int id, const Transform3D &xform, const Vector3 &size, float bricks_per_metre);
    void _b_set_smoke(int id, const Vector3 &centre, float radius);
    bool _b_smoke_blocks(const Vector3 &from, const Vector3 &to) const;
    void _b_set_danger(int id, const AABB &box);
    bool _b_in_danger(const Vector3 &point) const;
    float _b_danger_distance(const Vector3 &point) const;
    bool _b_solid_at(const Vector3 &point);
    Vector2i _b_block_at(const Vector3 &point);
    bool _b_ground_blocks(const Vector3 &from, const Vector3 &to);

    bool framed = false;
    Transform3D frame;       // region -> world
    Transform3D frame_inv;   // world -> region

    // set_ground_grid.
    Vector2 grid_origin;
    float grid_step = 1.0f;
    int grid_size = 0;
    std::vector<float> grid_heights;
    int grid_wall = 0;   // the plate a column outside the grid is solid up to
    // Every stud column's ground plate over the grid, worked out once by
    // set_ground_grid: no cache to grow (and rehash) as the AI reads it.
    std::vector<int16_t> grid_plates;
    int grid_gx0 = 0, grid_gz0 = 0, grid_nx = 0, grid_nz = 0;
    int _grid_plate(int gx, int gz) const;
    /// Is region (x, z) off the grid? Its wall is for walking: a sight line
    /// past the region's edge is not blocked by it.
    bool _off_grid(float x, float z) const;

    struct ChunkEntry {
        int chunk = -1;
        AABB box;
        Transform3D inv;     // world -> chunk local
        Vector3i dims;
        uint32_t stamp = 0;  // last query that visited it
    };
    struct Proxy {
        int id = -1;
        Transform3D xform;
        Transform3D inv;
        Vector3 half;
        float bricks_per_metre = 0.0f;
        AABB box;
        bool cover = false;  // set_cover: lines only
    };
    struct Sphere {
        Vector3 centre;
        float radius = 0.0f;
    };

    struct Accum {
        int bricks = 0;
        int hits = 0;           // cover_seconds' sum of rounds
        int hp = 0;
        float solid_m = 0.0f;
        float first_t = 2.0f;   // along the segment, 0..1; > 1 = none
        int first_chunk = -1;
        float proxy_bricks = 0.0f;
    };

    Ref<BrickWorld> world;
    std::vector<ChunkEntry> chunk_entries;
    std::unordered_map<int64_t, std::vector<int>> hash;   // cell key -> entry indices
    std::unordered_map<int, Proxy> proxies;
    // The proxies again, as a list with a hash of their own, rebuilt on the first
    // query after any change: a city of pristine buildings is a thousand boxes.
    std::vector<Proxy> proxy_list;
    std::vector<uint32_t> proxy_stamp;
    std::unordered_map<int64_t, std::vector<int>> proxy_hash;
    bool proxies_dirty = true;
    void _rebuild_proxies();
    void _walk_proxy(Proxy &p, const Vector3 &from, const Vector3 &to, Accum &acc);
    std::unordered_map<int, Sphere> smoke;
    std::unordered_map<int, AABB> danger;
    uint32_t query_stamp = 0;
    std::vector<int32_t> seen;   // blocks already counted in this chunk walk

    // The ground, as the first free plate over each stud column. Cached: the
    // field is a noise function, a sight line asks it once a stud, and nothing
    // in play changes it (pads are cut before the city is built).
    bool terrain_ground = false;
    std::unordered_map<int64_t, int32_t> ground_cache;
    int ground_dx = 0;   // shift_origin: scene column - field column, studs
    int ground_dz = 0;
    int _ground_plate(int gx, int gz);
    /// Does the ground rise above the segment anywhere? `t` is where, 0..1.
    bool _terrain_hit(const Vector3 &from, const Vector3 &to, float &t);

    // stats
    uint64_t queries = 0;
    uint64_t query_usec = 0;
    uint64_t cells_walked = 0;
    uint64_t chunks_walked = 0;

    static int64_t key(int x, int z) { return ((int64_t)x << 32) ^ (int64_t)(uint32_t)z; }
    void _walk(const Vector3 &from, const Vector3 &to, int hp_per_hit, Accum &acc);
    void _walk_chunk(ChunkEntry &e, const Vector3 &from, const Vector3 &to, int hp_per_hit,
            Accum &acc);
    static bool _segment_box(const Vector3 &a, const Vector3 &b, const AABB &box, float &t0,
            float &t1);
};

