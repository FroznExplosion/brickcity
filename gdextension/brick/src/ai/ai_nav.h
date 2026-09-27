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
    static constexpr int MAX_DROP = 9;

    void set_ai_world(const Ref<AIWorld> &ai);

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
    void clear_cache();

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

    Dictionary get_stats() const;
    void reset_stats();

private:
    struct Floor {
        int16_t y = 0;       // plate the feet are on
        int16_t head = 0;    // plates of air above
    };
    struct Column {
        std::vector<Floor> floors;
    };
    struct Node {
        int x = 0, z = 0, y = 0;
    };
    struct Open {
        float f = 0.0f;
        int64_t key = 0;
    };
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
        uint32_t revision = 0;
    };

    Ref<AIWorld> ai;
    std::unordered_map<int64_t, Column> columns;
    std::vector<char> column_scratch;
    // Node fit, memoised per ANCHOR column: (floor y, head) pairs. Keyed by
    // column so an invalidation forgets only the region it touched.
    std::unordered_map<int64_t, std::vector<std::pair<int16_t, int16_t>>> node_memo;
    std::unordered_map<int, Search> searches;
    int next_id = 1;
    uint32_t revision = 1;

    uint64_t stat_columns_read = 0;
    uint64_t stat_expansions = 0;
    uint64_t stat_paths = 0;
    uint64_t stat_failed = 0;
    uint64_t stat_search_usec = 0;
    uint64_t stat_invalidations = 0;
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
    void _finish(Search &s, int64_t goal_key);
};

VARIANT_ENUM_CAST(AINav::Status);
