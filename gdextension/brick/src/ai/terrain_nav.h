#pragma once

// TerrainNav -- where a creature can walk in the mine world (Docs/MineCreatures.md 2).
//
// AINav reads AIWorld, which sees the terrain as a heightfield (all solid under
// the top, plates counted up from y = 0): every cave is a wall to it. The mine
// world is volumetric -- caves, overhangs, the player's builds inside the field,
// ground down to -126 m -- so this reads BrickTerrain's field itself, cell by
// cell, through terrain_column_solid.
//
// The grid is the terrain's: a COLUMN is one stud square, a plate is 0.14 m. A
// BODY is W x W studs and H plates (a zombie 2 x 12, a pig 2 x 6). A NODE is a
// body standing with its footprint's corner on column (x, z), on plate y: some
// column of the footprint solid at y, every column air from y + 1 to y + H. Only
// places a body fits are nodes, so a 1-stud gap or an 11-plate tunnel is simply
// not in a zombie's graph (the user's "only cells large enough").
//
// A move goes to one of eight neighbouring footprints and lands on the highest
// support there within `up` plates over and `drop` plates under, with air for
// the body all the way (no stepping up under a ceiling, no dropping through a
// floor). A diagonal needs both straight moves open: no cutting a corner
// through a crack.
//
// The field is read in SECTIONS of 16 x 16 columns x 32 plates, made the first
// time a search touches them and kept until an edit's box touches them
// (invalidate_box). Every query is safe from a worker: call them from
// WorkerThreadPool and poll (CLAUDE.md: never wait on a worker during play).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector4i.hpp>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

using namespace godot;

class TerrainNav : public RefCounted {
    GDCLASS(TerrainNav, RefCounted);

protected:
    static void _bind_methods();

public:
    static constexpr int SX = 16;
    static constexpr int SY = 32;
    /// Sections kept before the cache is dropped and made again (8 KB each).
    static constexpr int MAX_SECTIONS = 6000;
    /// A drop past this many plates costs HURT_COST more (Pawn.SAFE_FALL-ish).
    static constexpr int SAFE_DROP = 9;
    static constexpr float HURT_COST = 6.0f;

    struct Body {
        int w = 2;
        int h = 12;
        int up = 3;
        int drop = 19;
    };

    struct Section {
        uint8_t cells[SX * SX * SY];
    };

    /// A search's view of the sections: the last one it used is kept, so most
    /// reads are an array index.
    struct Reader {
        static constexpr int SLOTS = 32;
        TerrainNav *nav = nullptr;
        int64_t key = INT64_MIN;
        const Section *sec = nullptr;
        /// Sections this search has used, so a switch back is no lock.
        int64_t keys[SLOTS];
        std::shared_ptr<const Section> held[SLOTS];
        explicit Reader(TerrainNav *n) : nav(n) {
            for (int i = 0; i < SLOTS; ++i) {
                keys[i] = INT64_MIN;
            }
        }
        uint8_t solid(int x, int y, int z);
        /// Plates [y0, y0 + n) of column (x, z) into `out`: a copy per section.
        void column(int x, int z, int y0, int n, uint8_t *out);
        const Section *_at(int sx, int sy, int sz);
    };

    struct Field {
        Body body;
        int gx = 0, gz = 0;
        std::unordered_map<int64_t, float> cost;
    };

    // --- bound ----------------------------------------------------------

    /// A path for `body` (Vector4i: width studs, height plates, up plates,
    /// drop plates) from `from` to `to`, feet positions in the terrain frame,
    /// metres. {"path": PackedVector3Array of feet points, "reached": bool,
    /// "expanded": nodes}. Not reached: the path goes to the node nearest the
    /// goal it could get to (a zombie at the wall); empty if `from` is no node.
    Dictionary find_path(const Vector3 &from, const Vector3 &to, const Vector4i &body, int max_nodes);
    /// Cost to `goal` for every node within `radius` studs that can walk to it
    /// (a Dijkstra over the moves backwards). Returns the field's id.
    int build_field(const Vector3 &goal, int radius, const Vector4i &body, int max_nodes);
    /// The next feet point to walk to from `from` down the field, or
    /// Vector3(INF, INF, INF) when `from` is not in it. At the goal: `from`'s node.
    Vector3 field_next(int id, const Vector3 &from);
    /// Metres-ish of walking left from `from` (INF outside the field).
    float field_cost(int id, const Vector3 &from);
    int field_size(int id);
    void release_field(int id);
    /// No solid plate on the segment (sight, scent round a corner is not this).
    bool line_clear(const Vector3 &from, const Vector3 &to);
    /// The feet point of the nearest node to `at` for `body` within `radius`
    /// studs across and 12 plates up or down, or INF.
    Vector3 stand_near(const Vector3 &at, const Vector4i &body, int radius);
    /// Is there a node for `body` with its feet at `at` (snapped)?
    bool fits(const Vector3 &at, const Vector4i &body);
    /// Cells changed in [lo, hi] (stud, plate, stud; MineWorld.terrain_edited's
    /// box_lo / box_hi): the sections touching it (and one column round) go.
    void invalidate_box(const Vector3i &lo, const Vector3i &hi);
    /// Solid boxes that are not the terrain's -- tree trunks (TerrainTrees'
    /// physics boxes) -- as group `id`: [lo, hi] cell pairs (stud, plate, stud,
    /// inclusive), replacing what the group had. Stamped into sections as they
    /// are made; the sections either version touches are made again.
    void set_obstacles(int id, const PackedVector3Array &lo_hi);
    void remove_obstacles(int id);
    int obstacle_count();
    void clear();
    Dictionary get_stats();

    // --- inner ------------------------------------------------------------

    std::shared_ptr<const Section> _section(int sx, int sy, int sz);
    static Body _body(const Vector4i &v);
    static int64_t _key(int x, int y, int z);
    static void _unkey(int64_t k, int &x, int &y, int &z);
    /// Node of a feet point (footprint corner column, support plate), unchecked.
    static void _snap(const Vector3 &p, const Body &b, int &x, int &y, int &z);
    static Vector3 _feet(int x, int y, int z, const Body &b);
    bool _fit(Reader &r, int x, int y, int z, const Body &b);
    /// Find a node near the unchecked snap: y within [y - dn, y + up].
    bool _find_node(Reader &r, int &x, int &y, int &z, const Body &b, int dn, int upr);
    /// The plate a move from (x, y, z) to footprint (nx, nz) lands on, or INT32_MIN.
    int _land(Reader &r, int x, int y, int z, int nx, int nz, const Body &b);
    /// Move from (x, y, z) by (dx, dz): the landing plate or INT32_MIN.
    int _move(Reader &r, int x, int y, int z, int dx, int dz, const Body &b);
    static float _edge_cost(int dx, int dz, int y0, int y1);

    struct OBox {
        int x0, y0, z0, x1, y1, z1;
    };
    void _rebuild_obstacle_index();
    void _invalidate_boxes(const std::vector<OBox> &boxes);

private:
    std::mutex ob_lock;
    std::unordered_map<int, std::vector<OBox>> ob_groups;
    /// Section column (sx, 0, sz) -> the boxes over it.
    std::unordered_map<int64_t, std::vector<OBox>> ob_index;
    std::mutex sec_lock;
    std::unordered_map<int64_t, std::shared_ptr<const Section>> sections;
    std::mutex field_lock;
    std::unordered_map<int, std::shared_ptr<const Field>> fields;
    std::atomic<int> next_field{1};
    std::atomic<int64_t> sections_made{0};
};
