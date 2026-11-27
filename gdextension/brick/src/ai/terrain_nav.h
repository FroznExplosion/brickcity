#pragma once

// TerrainNav -- where a creature can walk in the mine world (Docs/MineCreatures.md 2, 11).
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
// column of the footprint solid at y, nothing it cannot be in from y + 1 to
// y + H. Only places a body fits are nodes, so a 1-stud gap or an 11-plate
// tunnel is simply not in a zombie's graph (the user's "only cells large enough").
//
// A cell is AIR, SOLID, WATER or LAVA. A body stands only on solid; it is never
// in solid or lava; it wades in water (a cost) but never with its head under.
//
// A move goes to one of eight neighbouring footprints and lands on the highest
// support there within `up` plates over and `drop` plates under, with room for
// the body all the way (no stepping up under a ceiling, no dropping through a
// floor). A diagonal needs both straight moves open: no cutting a corner
// through a crack.
//
// The field is read in SECTIONS of 16 x 16 columns x 32 plates, made the first
// time a search touches them and kept until an edit's box touches them
// (invalidate_box). Water and lava are read with them and read again when the
// fluid has changed (set_fluid_version). Every query is safe from a worker: call
// them from WorkerThreadPool and poll (CLAUDE.md: never wait on a worker during play).

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
#include <unordered_set>
#include <vector>

using namespace godot;

class TerrainNav : public RefCounted {
    GDCLASS(TerrainNav, RefCounted);

protected:
    static void _bind_methods();

public:
    static constexpr int SX = 16;
    static constexpr int SY = 32;
    static constexpr int N = SX * SX * SY;
    /// Sections kept before the cache is dropped and made again (16 KB each).
    static constexpr int MAX_SECTIONS = 6000;
    /// A drop past this many plates costs HURT_COST more (Pawn.SAFE_FALL-ish).
    static constexpr int SAFE_DROP = 9;
    static constexpr float HURT_COST = 6.0f;
    /// Wading: a step with water round the feet costs this much more.
    static constexpr float WADE_COST = 2.0f;

    enum CellCode : uint8_t { AIR = 0, SOLID = 1, WATER = 2, LAVA = 3 };

    struct Body {
        int w = 2;
        int h = 12;
        int up = 3;
        int drop = 19;
    };

    struct Section {
        /// Terrain and obstacles, 0 / 1.
        uint8_t solid[N];
        /// solid plus the fluid: CellCode.
        uint8_t cells[N];
        int64_t fver = -1;
    };

    /// A search's view of the sections: the ones it used are kept, so most
    /// reads are an array index and a switch back is no lock.
    struct Reader {
        static constexpr int SLOTS = 32;
        TerrainNav *nav = nullptr;
        int64_t key = INT64_MIN;
        const Section *sec = nullptr;
        int64_t keys[SLOTS];
        std::shared_ptr<const Section> held[SLOTS];
        explicit Reader(TerrainNav *n) : nav(n) {
            for (int i = 0; i < SLOTS; ++i) {
                keys[i] = INT64_MIN;
            }
        }
        const Section *_at(int sx, int sy, int sz);
        uint8_t code(int x, int y, int z);
        bool solid(int x, int y, int z) { return code(x, y, z) == SOLID; }
        /// Codes of plates [y0, y0 + n) of column (x, z) into `out`.
        void column(int x, int z, int y0, int n, uint8_t *out);
    };

    struct Field {
        Body body;
        int gx = 0, gz = 0;
        std::unordered_map<int64_t, float> cost;
    };

    struct OBox {
        int x0, y0, z0, x1, y1, z1;
    };

    // --- bound ----------------------------------------------------------

    /// A path for `body` (Vector4i: width studs, height plates, up plates,
    /// drop plates) from `from` to `to`, feet positions in the terrain frame,
    /// metres. {"path": PackedVector3Array of feet points, "reached": bool,
    /// "expanded": nodes}. Not reached: the path goes to the node nearest the
    /// goal it could get to (a zombie at the wall); empty if `from` is no node.
    Dictionary find_path(const Vector3 &from, const Vector3 &to, const Vector4i &body, int max_nodes);
    /// Cost to `goal` for every node within `radius` studs that can walk to it
    /// (a Dijkstra over the moves backwards). Returns the field's id (0: none).
    int build_field(const Vector3 &goal, int radius, const Vector4i &body, int max_nodes);
    /// The next feet point to walk to from `from` down the field, or
    /// Vector3(INF, INF, INF) when `from` is not in it. At the goal: `from`'s node.
    Vector3 field_next(int id, const Vector3 &from);
    /// Metres of walking left from `from` (INF outside the field).
    float field_cost(int id, const Vector3 &from);
    int field_size(int id);
    void release_field(int id);
    /// Can `body` standing at `from` walk more than `reach` studs away (across)
    /// within `max_nodes` nodes? False: it is penned in -- a fence, a room, a
    /// pit (Docs/MineCreatures.md 11: what is saved).
    bool free_reach(const Vector3 &from, const Vector4i &body, int reach, int max_nodes);
    /// No solid plate on the segment (sight).
    bool line_clear(const Vector3 &from, const Vector3 &to);
    /// The feet point of the nearest node to `at` for `body` within `radius`
    /// studs across and 12 plates up or down, or INF.
    Vector3 stand_near(const Vector3 &at, const Vector4i &body, int radius);
    /// Is there a node for `body` with its feet at `at` (snapped)?
    bool fits(const Vector3 &at, const Vector4i &body);
    /// The cell code at a point (AIR, SOLID, WATER, LAVA): a probe's question.
    int code_at(const Vector3 &at);
    /// Cells changed in [lo, hi] (stud, plate, stud; MineWorld.terrain_edited's
    /// box_lo / box_hi): the sections touching it go.
    void invalidate_box(const Vector3i &lo, const Vector3i &hi);
    void clear();
    /// Read water and lava at all (off: every cell is ground or air -- a
    /// probe without a fluid world).
    void set_fluid(bool on);
    /// The fluid changed (BrickFluid.change_count): sections read their fluid
    /// again the next time they are used.
    void set_fluid_version(int64_t v);
    /// Read the fluid's change log (BrickFluid.set_change_log must be on):
    /// only the sections holding a changed cell read their fluid again. When
    /// the log does not reach back, every section does. Returns the cells.
    int update_fluid();
    /// Solid boxes that are not the terrain's -- tree trunks (TerrainTrees'
    /// physics boxes), shut doors -- as group `id`: [lo, hi] cell pairs (stud,
    /// plate, stud, inclusive), replacing what the group had.
    void set_obstacles(int id, const PackedVector3Array &lo_hi);
    void remove_obstacles(int id);
    int obstacle_count();
    Dictionary get_stats();

    // --- inner ------------------------------------------------------------

    std::shared_ptr<const Section> _section(int sx, int sy, int sz);
    static Body _body(const Vector4i &v);
    static int64_t _key(int x, int y, int z);
    static void _unkey(int64_t k, int &x, int &y, int &z);
    static void _snap(const Vector3 &p, const Body &b, int &x, int &y, int &z);
    static Vector3 _feet(int x, int y, int z, const Body &b);
    bool _fit(Reader &r, int x, int y, int z, const Body &b);
    bool _find_node(Reader &r, int &x, int &y, int &z, const Body &b, int dn, int upr);
    int _land(Reader &r, int x, int y, int z, int nx, int nz, const Body &b);
    int _move(Reader &r, int x, int y, int z, int dx, int dz, const Body &b);
    bool _wet_feet(Reader &r, int x, int y, int z, const Body &b);
    float _edge_cost(Reader &r, int x, int z, int dx, int dz, int y0, int y1, const Body &b);
    void _rebuild_obstacle_index();
    void _invalidate_boxes(const std::vector<OBox> &boxes);
    void _fill_fluid(Section &s, int sx, int sy, int sz);

private:
    std::mutex sec_lock;
    std::unordered_map<int64_t, std::shared_ptr<const Section>> sections;
    std::mutex field_lock;
    std::unordered_map<int, std::shared_ptr<const Field>> fields;
    std::atomic<int> next_field{ 1 };
    std::atomic<int64_t> sections_made{ 0 };
    std::atomic<int64_t> fluid_refreshes{ 0 };
    std::atomic<int64_t> fluid_ver{ 0 };
    std::atomic<bool> fluid_on{ false };
    /// Sections whose fluid changed since they read it.
    std::unordered_set<int64_t> fluid_dirty;
    int64_t fluid_seen = -1;
    std::mutex ob_lock;
    std::unordered_map<int, std::vector<OBox>> ob_groups;
    /// Section column (sx, 0, sz) -> the boxes over it.
    std::unordered_map<int64_t, std::vector<OBox>> ob_index;
};
