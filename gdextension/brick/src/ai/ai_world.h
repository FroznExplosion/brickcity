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

    // --- measuring ----------------------------------------------------------

    Dictionary get_stats() const;
    void reset_stats();

private:
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

