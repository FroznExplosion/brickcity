#pragma once

// AINav -- where a figure can walk, read straight from the bricks (AIPlan P3).
//
// Not a navmesh. The city is a grid of studs and plates, so navigation is one
// too: a COLUMN is one stud square, and a FLOOR in it is a plate a body can
// stand on -- solid below, enough air above. The answers come from AIWorld's
// point queries, which see every chunk at any rotation and every proxy box, so:
//
//   * a hole a body fits through is a way through the moment it is shot, with no
//     rebake -- only the columns it touched are forgotten and re-read;
//   * stairs, doors and rooms are whatever the bricks say they are;
//   * a pristine building is its shell's proxy boxes -- a wall with no door --
//     and asking a path of it never materialises it (Docs/AI.md 3.2).
//
// A body is two studs square (the figure is 0.525 m across, a stud 0.35): a
// node is the 2x2 of columns at (x, z)..(x+1, z+1), standing on column (x, z)'s
// floor. It walks to any of eight neighbours, up a brick course, down a few,
// crouching where it must. A* in C++, served from a queue inside a budget.

#include "ai_world.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

using namespace godot;

class AINav : public RefCounted {
    GDCLASS(AINav, RefCounted);

protected:
    static void _bind_methods();

public:
    enum Status {
        PENDING = 0,
        DONE,
        FAILED,
        UNKNOWN,
    };

    /// Plates of air a figure stands in (Pawn.BODY_HEIGHT, 1.68 m), and crouches in.
    static constexpr int HEAD_STAND = 12;
    static constexpr int HEAD_CROUCH = 9;
    /// Plates it steps up without a jump: one brick course (Pawn.STEP_HEIGHT).
    static constexpr int STEP_UP = 3;
    /// Plates it steps down off an edge rather than going round.
    ///
    /// It was 9 (1.26 m), and a storey is 19: a soldier whose staircase was shot
    /// out had no way off its floor and stood there for the rest of the fight
    /// (Docs/Collapse.md 4.3). One storey and a little is allowed now, and a
    /// drop past SAFE_DROP -- which hurts (Pawn.SAFE_FALL) -- costs HURT_DROP_COST
    /// metres of walking, so it is taken when there is no other way down.
    static constexpr int MAX_DROP = 21;
    /// One search's turn in service() before the queue is looked at again.
    static constexpr uint64_t SLICE_USEC = 150;
    static constexpr int SAFE_DROP = 9;
    static constexpr float HURT_DROP_COST = 12.0f;

    void set_ai_world(const Ref<AIWorld> &ai);

    /// Who walks this map (the constants above are the figure's, the default).
    /// A mech map (Docs/AI.md 3.6, AIPlan R8) is another AINav with a mech's
    /// numbers: `span` columns square (its footprint in studs), plates of air it
    /// stands in and squeezes through, plates it steps up, drops off an edge,
    /// and drops without harm. Forgets every column.
    void set_agent(int span, int head_stand, int head_crouch, int step_up, int max_drop,
            int safe_drop);
    int get_span() const { return span; }

    /// A tracked vehicle CRUSHES what is low enough (Docs/AIVehicles.md 3): a
    /// run of bricks standing on the ground -- a garden wall, a barricade, a
    /// heap of rubble -- more than a step high and no more than `plates`, is a
    /// way THROUGH at its foot, for `cost_m` metres of driving more than the
    /// road beside it. 0 (the default) crushes nothing. Forgets every column.
    void set_crush(int plates, float cost_m);
    int get_crush() const { return crush; }

    /// An agent that BREACHES (Docs/AI.md 3.6, breach links): a column of
    /// bricks in its way at the height it walks is a way through, for `cost_m`
    /// metres of walking a column -- the time it takes it to open one, as
    /// distance. A wall two studs thick is two columns. Bricks only: never the
    /// terrain under the ground, never down through a floor. 0 (the default)
    /// breaches nothing. Forgets every column. Where a path goes through bricks
    /// is get_breaches / get_last_breaches.
    void set_breach(float cost_m);
    float get_breach() const { return breach_cost; }
    /// The points where a finished path enters bricks it has to open, in order
    /// (the first column of each run): for a request, and for the last find_path.
    PackedVector3Array get_breaches(int id) const;
    PackedVector3Array get_last_breaches() const { return last_breaches; }

    // --- the hierarchy (HPA*, Docs/AI.md 4.3.1) -------------------------------
    //
    // A path between far points is found on a small graph first: the map cut
    // into square CLUSTERS of `cluster` columns (sized to the agent: a tank's
    // cluster is bigger than a soldier's), their ENTRANCES -- each run of the
    // border between two clusters a body crosses, at each height, one node a
    // side, sampled every RUN columns -- and what it costs to walk from one
    // entrance of a cluster to another inside it (a Dijkstra in the cluster,
    // worked out the first time a search needs it, kept until something there
    // changes). A* on that graph is a few hundred nodes for a walk across the
    // city; the brick-level path is then found a cluster at a time between the
    // entrances it chose. What the agent can do -- climb, drop, crush, breach --
    // is the same `_step` both levels walk, so every map (each size, each
    // vehicle) gets its own hierarchy for free. An invalidation forgets the
    // borders and costs of the clusters it touches.
    //
    // Used for a request whose ends are in different clusters, once the plain
    // search has failed to find it in a few times the straight distance in
    // nodes (PLAIN_FIRST): across open ground the plain search is the cheaper,
    // round walls and through buildings the hierarchy. 0 turns it off.
    void set_hierarchy(int cluster_columns);
    int get_hierarchy() const { return cluster; }
    /// A border run this long or shorter is one entrance; longer, two, a little
    /// in from its ends.
    static constexpr int HIER_RUN = 10;
    static constexpr int PLAIN_FIRST = 48;
    /// Work out the hierarchy round `at` -- every cluster within `radius_m` --
    /// in service()'s spare time, before anybody asks: where the fight is, the
    /// first searches find it ready. Nearest first; asked again, it starts over
    /// from the new point.
    void warm(const Vector3 &at, float radius_m);
    int warm_pending() const { return (int)warm_queue.size(); }

    /// A path now, whatever it costs, up to `max_expansions` nodes. Empty if none.
    PackedVector3Array find_path(const Vector3 &from, const Vector3 &to, int max_expansions);

    /// Queue a path. Served best-first by `priority` inside service().
    /// A search that has not found the goal after `max_expansions` nodes gives up:
    /// a way into a sealed building does not exist, and looking for it costs.
    int request_path(const Vector3 &from, const Vector3 &to, float priority,
            int max_expansions = 60000);
    /// Work the queue for up to `budget_usec`. Returns requests finished.
    int service(int budget_usec);
    int get_status(int id) const;
    PackedVector3Array get_path(int id) const;
    void release(int id);
    int pending() const;

    /// Something changed here: forget the columns under this box and restart
    /// any search that may have read them. Emits `nav_changed(box)` so path
    /// followers whose corridor crosses it re-path (the NavChange event, R17).
    void invalidate_box(const AABB &box);

    // --- flow fields (Docs/AI.md 4.3) -----------------------------------------
    //
    // When many go to one place -- directed agents closing on a player -- one
    // field serves them all: the cost from every node within `radius_m` of the
    // goal TO it, worked out once (Dijkstra over the same steps a path takes,
    // reversed, so a drop is one-way), served inside service() after the paths,
    // and read by any number of agents with field_dir. Worked out again when an
    // invalidation reaches it; the owner asks for a new one when its goal moves.

    int request_field(const Vector3 &goal, float radius_m, float priority);
    int get_field_status(int id) const;
    /// Which way to walk from `point` toward the goal: a unit vector, or zero
    /// (at the goal, outside the field, or not worked out yet).
    Vector3 field_dir(int id, const Vector3 &point);
    /// Metres of walking from `point` to the goal, INF outside the field.
    float field_cost(int id, const Vector3 &point);
    int get_field_size(int id) const;
    void release_field(int id);
    void clear_cache();

    /// The sea, in metres: a floor deeper under it than WADE is not a floor.
    /// -INF (the default) is no sea. Forgets every column, so set it once.
    void set_water_level(float metres);
    float get_water_level() const { return water_level; }
    /// How deep a figure wades before the water is somewhere it cannot go.
    static constexpr float WADE = 0.5f;
    float get_wade() const { return WADE; }

    /// Where a body would stand nearest `point`, or `point` itself with none.
    Vector3 snap(const Vector3 &point);
    bool can_stand(const Vector3 &point);

    // --- cover (Docs/AI.md 3.7, 6.1) -------------------------------------------
    //
    // Found on demand against the actual threat rather than baked: AIWorld says
    // whether the bricks between the threat's eye and a spot hide a body there,
    // and for how long. LOW cover hides a crouched body (peek by standing); HIGH
    // hides a standing one (peek by stepping to its side). C++ because it loops:
    // a ring search is a hundred-odd candidates (AI.md 10.3 rule 8).

    /// The best cover near `from` against a threat whose eye is at `threat_eye`,
    /// carrying `hp_per_hit` at `hits_per_second`: {cover, kind, peek, life, hug}
    /// or {}.
    Dictionary find_cover(const Vector3 &from, const Vector3 &threat_eye, int hp_per_hit,
            float hits_per_second, float ideal_range);
    /// Is `p` cover against that threat, and how good: as find_cover, or {}.
    Dictionary rate_cover(const Vector3 &p, const Vector3 &threat_eye, int hp_per_hit,
            float hits_per_second);

    /// Nobody crouches (Docs/AI.md A21): cover has to hide a STANDING body, and
    /// every spot is "high" -- peeked by stepping to its side. On by default;
    /// off brings back low cover that hides a crouched body.
    void set_stand_only(bool on) { stand_only = on; }
    bool get_stand_only() const { return stand_only; }

    Dictionary get_stats() const;
    void reset_stats();

private:
    struct Floor {
        int16_t y = 0;       // plate the feet are on
        int16_t head = 0;    // plates of air above
        int16_t crush = 0;   // plates of bricks the agent crushes to stand here
    };
    struct Column {
        std::vector<Floor> floors;
        // A breaching agent's: plates up from the column's ground (terrain), and
        // which plates over it are bricks, packed a bit a plate.
        int16_t ground = 0;
        std::vector<uint8_t> brick;
    };
    struct Node {
        int x = 0, z = 0, y = 0;
    };
    struct Open {
        float f = 0.0f;
        int64_t key = 0;
    };
    struct Field {
        int id = 0;
        float priority = 0.0f;
        Vector3 goal;
        float radius = 40.0f;
        Status status = PENDING;
        bool started = false;
        Node goal_node;
        std::vector<Open> open;
        std::unordered_map<int64_t, float> cost;
    };
    struct HpaState;
    struct Search {
        int id = 0;
        float priority = 0.0f;
        Vector3 from, to;
        Status status = PENDING;
        bool started = false;
        Node start, goal;
        std::vector<Open> open;
        std::unordered_map<int64_t, float> g;
        std::unordered_map<int64_t, int64_t> parent;
        int expansions = 0;
        int max_expansions = 60000;
        PackedVector3Array path;
        PackedVector3Array breaches;
        uint32_t revision = 0;
        // A hierarchical search's own state (null for a plain one).
        std::shared_ptr<HpaState> hpa;
        // start and goal are nodes already (a stretch of a hierarchical path).
        bool presnapped = false;
        // Far ends: the plain search had its few nodes first (PLAIN_FIRST).
        bool tried_plain = false;
        bool plain_first = false;
        bool capped = false;
        int full_cap = 0;
        // The hierarchy ran out of budget: the plain search, all of it.
        bool no_hier = false;
        // The columns it has read so far, as a box: an invalidation outside it
        // cannot have changed anything this search knows.
        int lo_x = 0, hi_x = -1, lo_z = 0, hi_z = -1;
    };

    Ref<AIWorld> ai;
    // The agent (set_agent). Defaults: the figure.
    int span = 2;
    int head_stand = HEAD_STAND;
    int head_crouch = HEAD_CROUCH;
    int step_up = STEP_UP;
    int max_drop = MAX_DROP;
    int safe_drop = SAFE_DROP;
    int crush = 0;
    float crush_cost = 0.0f;
    float breach_cost = 0.0f;
    PackedVector3Array last_breaches;

    // The hierarchy.
    int cluster = 0;
    struct Side {
        Node node;
        int cx = 0, cz = 0;      // its cluster
        int partner = -1;        // the other side of its entrance
        float cross = 0.0f;      // stepping over to the partner, INF if it cannot
        bool alive = true;
        uint32_t edges_rev = 0;  // its cluster's revision when edges were found
        std::vector<std::pair<int, float>> edges;   // to other sides of its cluster
    };
    std::vector<Side> sides;
    // Border (between cluster (cx, cz) and its +x or +z neighbour) -> its sides.
    std::unordered_map<int64_t, std::vector<int>> borders;
    std::unordered_map<int64_t, uint32_t> cluster_rev;
    // Clusters to work out in spare time (warm), nearest first; and the time a
    // cluster gets per turn.
    std::vector<std::pair<int, int>> warm_queue;
    void _warm_step(uint64_t until_usec);
    uint64_t stat_hier_paths = 0;
    uint64_t stat_hier_nodes = 0;
    uint64_t stat_hier_dijkstra = 0;
    uint64_t stat_hier_usec = 0;
    static int64_t bkey(int cx, int cz, int axis) {
        return ((int64_t)(cx & 0xFFFFF) << 22) | ((int64_t)(cz & 0xFFFFF) << 2) | (int64_t)axis;
    }
    int _cluster_of(int v) const { return v >= 0 ? v / cluster : -((-v - 1) / cluster) - 1; }
    uint32_t _crev(int cx, int cz);
    const std::vector<int> &_border(int cx, int cz, int axis);
    void _cluster_sides(int cx, int cz, std::vector<int> &out);
    void _side_edges(int sid);
    /// Dijkstra from `from` over anchors inside the box, up to `cap` nodes.
    void _local_costs(const Node &from, int x0, int z0, int x1, int z1, int cap,
            std::unordered_map<int64_t, float> &g, const std::vector<int64_t> *targets = nullptr);
    /// Cost from every node of the box TO `to` (reversed steps, as a field's).
    void _local_costs_to(const Node &to, int x0, int z0, int x1, int z1, int cap,
            std::unordered_map<int64_t, float> &g);
    /// Run the hierarchical search `s` until done or `until_usec`. True when done.
    bool _advance_hier(Search &s, uint64_t until_usec);
    void _hier_forget(int x0, int z0, int x1, int z1);
    /// Make `s` hierarchical if its ends are far apart; true if it did.
    bool _hier_begin(Search &s);
    /// Walk straight from `a` towards `b`, a _step at a time, inside the box:
    /// its cost if it gets there, INF if it does not. Cheaper than a Dijkstra
    /// across open ground; an upper bound, never a way that is not there.
    float _straight(const Node &a, const Node &b, int x0, int z0, int x1, int z1);
    /// Bricks in column (x, z) anywhere from plate y up through a crouch's air:
    /// a breaching agent may go into it there.
    bool _breachable(int x, int z, int y);
    /// A node at (x, z, y) a breacher can take: bricks under its footprint
    /// there, and every other column of it a floor at y or bricks too.
    bool _breach_fit(int x, int z, int y);
    int terrain_plate(float x, float z);
    float water_level = -1e30f;
    bool stand_only = true;
    std::unordered_map<int64_t, Column> columns;
    std::vector<char> column_scratch;
    // Node fit, memoised per ANCHOR column: (floor y, head) pairs. Keyed by
    // column so an invalidation forgets only the region it touched.
    std::unordered_map<int64_t, std::vector<std::pair<int16_t, int16_t>>> node_memo;
    std::unordered_map<int, Search> searches;
    std::unordered_map<int, Field> fields;
    int next_id = 1;
    uint32_t revision = 1;

    uint64_t stat_columns_read = 0;
    uint64_t stat_expansions = 0;
    uint64_t stat_paths = 0;
    uint64_t stat_failed = 0;
    uint64_t stat_search_usec = 0;
    uint64_t stat_invalidations = 0;
    uint64_t stat_field_nodes = 0;
    uint64_t stat_worst_expand_usec = 0;
    uint64_t stat_worst_snap_usec = 0;
    uint64_t stat_worst_column_usec = 0;

    static int64_t ckey(int x, int z) { return ((int64_t)x << 32) ^ (int64_t)(uint32_t)z; }
    static int64_t nkey(int x, int z, int y) {
        return ((int64_t)(x & 0x1FFFFF) << 37) | ((int64_t)(z & 0x1FFFFF) << 16) | (int64_t)(y & 0xFFFF);
    }
    static Node unkey(int64_t k);

    const Column &_column(int x, int z);
    /// The head room of a node standing on floor `y` of column (x, z): the least
    /// over its 2x2, or -1 when it does not fit there at all.
    int _node_head(int x, int z, int y);
    bool _snap_node(const Vector3 &p, Node &out, int max_r = 4);
    Vector3 _node_point(const Node &n) const;
    /// Run a search until done or `until_usec` passes. Returns true when done.
    bool _advance(Search &s, uint64_t until_usec);
    bool _advance_field(Field &f, uint64_t until_usec);
    bool _step(const Node &n, int hn, int d, Node &out, float &cost);
    void _finish(Search &s, int64_t goal_key);
};

VARIANT_ENUM_CAST(AINav::Status);
