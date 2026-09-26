#include "ai_nav.h"

#include "../brick_grid.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>

using namespace godot;

namespace {

uint64_t now_usec() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
}

constexpr float STUD = brick::STUD_M;
constexpr float PLATE = brick::PLATE_M;
// Open sky: more air than anything could need.
constexpr int16_t SKY = 4096;
constexpr int DX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
constexpr int DZ[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };

} // namespace

void AINav::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_ai_world", "ai"), &AINav::set_ai_world);
    ClassDB::bind_method(D_METHOD("find_path", "from", "to", "max_expansions"), &AINav::find_path,
            DEFVAL(60000));
    ClassDB::bind_method(D_METHOD("request_path", "from", "to", "priority", "max_expansions"),
            &AINav::request_path, DEFVAL(60000));
    ClassDB::bind_method(D_METHOD("service", "budget_usec"), &AINav::service);
    ClassDB::bind_method(D_METHOD("get_status", "id"), &AINav::get_status);
    ClassDB::bind_method(D_METHOD("get_path", "id"), &AINav::get_path);
    ClassDB::bind_method(D_METHOD("release", "id"), &AINav::release);
    ClassDB::bind_method(D_METHOD("pending"), &AINav::pending);
    ClassDB::bind_method(D_METHOD("invalidate_box", "box"), &AINav::invalidate_box);
    ClassDB::bind_method(D_METHOD("clear_cache"), &AINav::clear_cache);
    ClassDB::bind_method(D_METHOD("snap", "point"), &AINav::snap);
    ClassDB::bind_method(D_METHOD("can_stand", "point"), &AINav::can_stand);
    ClassDB::bind_method(D_METHOD("get_stats"), &AINav::get_stats);
    ClassDB::bind_method(D_METHOD("reset_stats"), &AINav::reset_stats);

    ADD_SIGNAL(MethodInfo("nav_changed", PropertyInfo(Variant::AABB, "box")));

    BIND_ENUM_CONSTANT(PENDING);
    BIND_ENUM_CONSTANT(DONE);
    BIND_ENUM_CONSTANT(FAILED);
    BIND_ENUM_CONSTANT(UNKNOWN);
    BIND_CONSTANT(HEAD_STAND);
    BIND_CONSTANT(HEAD_CROUCH);
    BIND_CONSTANT(STEP_UP);
    BIND_CONSTANT(MAX_DROP);
}

// The caches are hash maps that grow to tens of thousands of entries, and a
// map that doubles rehashes everything at once -- measured as a 6.6 ms search
// step in a city whose columns cost 49 us at worst. So they are sized up front
// and, past a cap, simply dropped and read again.
static constexpr size_t CACHE_RESERVE = 1u << 18;
static constexpr size_t CACHE_CAP = 1u << 20;

void AINav::set_ai_world(const Ref<AIWorld> &p_ai) {
    ai = p_ai;
    columns.clear();
    node_memo.clear();
    columns.reserve(CACHE_RESERVE);
    node_memo.reserve(CACHE_RESERVE);
}

AINav::Node AINav::unkey(int64_t k) {
    Node n;
    int x = (int)((k >> 37) & 0x1FFFFF);
    int z = (int)((k >> 16) & 0x1FFFFF);
    // Sign-extend the 21-bit fields.
    if (x & 0x100000) {
        x -= 0x200000;
    }
    if (z & 0x100000) {
        z -= 0x200000;
    }
    n.x = x;
    n.z = z;
    n.y = (int)(k & 0xFFFF);
    return n;
}

// Read a column once and keep it until something invalidates it. The ground is
// the plane y = 0 (terrain, when the city has it, is a height here instead).
const AINav::Column &AINav::_column(int x, int z) {
    const int64_t k = ckey(x, z);
    auto it = columns.find(k);
    if (it != columns.end()) {
        return it->second;
    }
    if (columns.size() >= CACHE_CAP || node_memo.size() >= CACHE_CAP) {
        columns.clear();
        node_memo.clear();
    }
    Column col;
    stat_columns_read++;
    const uint64_t t_col = now_usec();
    if (ai.is_valid()) {
        const float cx = (x + 0.5f) * STUD;
        const float cz = (z + 0.5f) * STUD;
        const float top = ai->top_at(cx, cz);
        const int ymax = std::isfinite(top) ? std::max(0, (int)std::ceil(top / PLATE)) : 0;
        std::vector<char> solid(ymax + 1, 0);
        ai->column_solid(cx, cz, solid);
        for (int y = 0; y <= ymax; ++y) {
            const bool below = y == 0 || solid[y - 1];
            if (!below || solid[y]) {
                continue;
            }
            int r = 0;
            while (y + r <= ymax && !solid[y + r]) {
                r++;
            }
            const int16_t head = (y + r > ymax) ? SKY : (int16_t)r;
            if (head >= HEAD_CROUCH) {
                col.floors.push_back(Floor{ (int16_t)y, head });
            }
        }
    }
    stat_worst_column_usec = std::max(stat_worst_column_usec, now_usec() - t_col);
    return columns.emplace(k, std::move(col)).first->second;
}

// A node is the 2x2 of columns from (x, z): it stands on column (x, z)'s floor at
// `y`. Each of the other three needs air where the body is -- from its own ground,
// which may be LOWER (the body overhangs an edge: how a drop begins) or up to a
// step HIGHER (the body is at the foot of a step it is about to climb), up to the
// head. Memoised: the search asks about the same node from every neighbour.
int AINav::_node_head(int x, int z, int y) {
    std::vector<std::pair<int16_t, int16_t>> &memo = node_memo[ckey(x, z)];
    for (const auto &m : memo) {
        if (m.first == y) {
            return m.second;
        }
    }
    int head = std::numeric_limits<int>::max();
    for (int i = 0; i < 4 && head >= 0; ++i) {
        const int cx = x + (i & 1);
        const int cz = z + (i >> 1);
        const Column &col = _column(cx, cz);
        int best = -1;
        for (const Floor &f : col.floors) {
            if (i == 0 ? f.y != y : f.y > y + STEP_UP) {
                continue;
            }
            // Its air runs from its ground up; the body needs it from its own
            // feet (or that ground, if higher) to a crouch above them.
            const int air = (int)f.y + (int)f.head - y;
            if (air >= HEAD_CROUCH && (i == 0 || f.y + f.head >= std::max((int)f.y, y) + HEAD_CROUCH)) {
                best = std::max(best, air);
            }
        }
        head = best < 0 ? -1 : std::min(head, best);
    }
    node_memo[ckey(x, z)].push_back({ (int16_t)y, (int16_t)std::min(head, 32000) });
    return head;
}

Vector3 AINav::_node_point(const Node &n) const {
    return Vector3((n.x + 1) * STUD, n.y * PLATE, (n.z + 1) * STUD);
}

bool AINav::_snap_node(const Vector3 &p, Node &out) {
    const int ax = (int)std::lround(p.x / STUD) - 1;
    const int az = (int)std::lround(p.z / STUD) - 1;
    const int py = (int)std::floor(p.y / PLATE + 0.5f);
    float best_d = std::numeric_limits<float>::infinity();
    bool found = false;
    for (int r = 0; r <= 4 && !found; ++r) {
        for (int dx = -r; dx <= r; ++dx) {
            for (int dz = -r; dz <= r; ++dz) {
                if (std::max(std::abs(dx), std::abs(dz)) != r) {
                    continue;
                }
                const int x = ax + dx;
                const int z = az + dz;
                const Column &col = _column(x, z);
                // The floor under the point: the highest no more than a step
                // above it.
                int pick = -1;
                for (const Floor &f : col.floors) {
                    if (f.y <= py + STEP_UP && f.y > pick) {
                        pick = f.y;
                    }
                }
                if (pick < 0 || _node_head(x, z, pick) < 0) {
                    continue;
                }
                const Vector3 q = _node_point(Node{ x, z, pick });
                const float d = q.distance_squared_to(p);
                if (d < best_d) {
                    best_d = d;
                    out = Node{ x, z, pick };
                    found = true;
                }
            }
        }
    }
    return found;
}

Vector3 AINav::snap(const Vector3 &point) {
    Node n;
    return _snap_node(point, n) ? _node_point(n) : point;
}

bool AINav::can_stand(const Vector3 &point) {
    const int ax = (int)std::lround(point.x / STUD) - 1;
    const int az = (int)std::lround(point.z / STUD) - 1;
    const int py = (int)std::floor(point.y / PLATE + 0.5f);
    return _node_head(ax, az, py) >= 0;
}

bool AINav::_advance(Search &s, uint64_t until_usec) {
    const uint64_t t_start = now_usec();
    auto cmp = [](const Open &a, const Open &b) { return a.f > b.f; };
    // Octile distance: exact on an eight-way grid with nothing in the way, so
    // open ground is walked straight rather than flooded. A hair over 1 breaks
    // ties toward the goal.
    auto h = [&s](const Node &n) {
        const float dx = (float)std::abs(n.x - s.goal.x);
        const float dz = (float)std::abs(n.z - s.goal.z);
        const float oct = std::max(dx, dz) + 0.41421356f * std::min(dx, dz);
        return (oct * STUD + std::abs(n.y - s.goal.y) * PLATE) * 1.001f;
    };
    if (!s.started) {
        s.started = true;
        s.revision = revision;
        s.open.clear();
        s.g.clear();
        s.parent.clear();
        s.g.reserve(8192);
        s.parent.reserve(8192);
        s.open.reserve(4096);
        s.expansions = 0;
        const uint64_t t_snap = now_usec();
        const bool snapped = _snap_node(s.from, s.start) && _snap_node(s.to, s.goal);
        stat_worst_snap_usec = std::max(stat_worst_snap_usec, now_usec() - t_snap);
        if (!snapped) {
            s.status = FAILED;
            stat_failed++;
            return true;
        }
        const int64_t k0 = nkey(s.start.x, s.start.z, s.start.y);
        s.g[k0] = 0.0f;
        s.open.push_back(Open{ h(s.start), k0 });
    }
    const int64_t goal_key = nkey(s.goal.x, s.goal.z, s.goal.y);
    int since_check = 0;
    while (!s.open.empty()) {
        if (++since_check >= 1) {
            since_check = 0;
            if (now_usec() >= until_usec) {
                stat_search_usec += now_usec() - t_start;
                return false;
            }
        }
        std::pop_heap(s.open.begin(), s.open.end(), cmp);
        const Open cur = s.open.back();
        s.open.pop_back();
        const Node n = unkey(cur.key);
        const float gn = s.g[cur.key];
        // A stale entry: this node was reached more cheaply since it was pushed.
        if (cur.f > gn + h(n) + 1e-3f) {
            continue;
        }
        if (cur.key == goal_key) {
            _finish(s, goal_key);
            stat_search_usec += now_usec() - t_start;
            return true;
        }
        if (++s.expansions > s.max_expansions) {
            break;
        }
        stat_expansions++;
        const uint64_t t_exp = now_usec();
        const int hn = _node_head(n.x, n.z, n.y);
        for (int d = 0; d < 8; ++d) {
            const int nx = n.x + DX[d];
            const int nz = n.z + DZ[d];
            // The floor next door nearest this one, within a step up or a drop.
            const Column &col = _column(nx, nz);
            int best_y = -1;
            int best_head = -1;
            int best_dy = std::numeric_limits<int>::max();
            for (const Floor &f : col.floors) {
                const int dy = f.y - n.y;
                if (dy > STEP_UP || -dy > MAX_DROP) {
                    continue;
                }
                if (std::abs(dy) >= best_dy) {
                    continue;
                }
                // Stepping up needs the air to rise into.
                if (dy > 0 && hn < dy + HEAD_CROUCH) {
                    continue;
                }
                const int hh = _node_head(nx, nz, f.y);
                if (hh < 0) {
                    continue;
                }
                best_y = f.y;
                best_head = hh;
                best_dy = std::abs(dy);
            }
            if (best_y < 0) {
                continue;
            }
            // No cutting a corner the body would not fit round.
            if (d >= 4) {
                if (_node_head(n.x + DX[d], n.z, n.y) < 0 && _node_head(n.x, n.z + DZ[d], n.y) < 0) {
                    continue;
                }
            }
            float step = (d >= 4 ? 1.41421356f : 1.0f) * STUD + std::abs(best_y - n.y) * PLATE;
            if (best_head < HEAD_STAND) {
                step *= 2.0f;   // crouching is slow
            }
            if (best_y < n.y - STEP_UP) {
                step += 0.5f;   // a drop is a commitment
            }
            const int64_t nk = nkey(nx, nz, best_y);
            const float ng = gn + step;
            auto git = s.g.find(nk);
            if (git != s.g.end() && git->second <= ng) {
                continue;
            }
            s.g[nk] = ng;
            s.parent[nk] = cur.key;
            s.open.push_back(Open{ ng + h(Node{ nx, nz, best_y }), nk });
            std::push_heap(s.open.begin(), s.open.end(), cmp);
        }
        stat_worst_expand_usec = std::max(stat_worst_expand_usec, now_usec() - t_exp);
    }
    s.status = FAILED;
    stat_failed++;
    stat_search_usec += now_usec() - t_start;
    return true;
}

void AINav::_finish(Search &s, int64_t goal_key) {
    std::vector<Node> nodes;
    int64_t k = goal_key;
    const int64_t start_key = nkey(s.start.x, s.start.z, s.start.y);
    nodes.push_back(unkey(k));
    while (k != start_key) {
        auto it = s.parent.find(k);
        if (it == s.parent.end()) {
            break;
        }
        k = it->second;
        nodes.push_back(unkey(k));
    }
    std::reverse(nodes.begin(), nodes.end());
    // Only the corners: drop a point that carries on in the same direction at
    // the same height as the one before.
    s.path.clear();
    for (size_t i = 0; i < nodes.size(); ++i) {
        if (i > 0 && i + 1 < nodes.size()) {
            const Node &a = nodes[i - 1];
            const Node &b = nodes[i];
            const Node &c = nodes[i + 1];
            if (b.x - a.x == c.x - b.x && b.z - a.z == c.z - b.z && a.y == b.y && b.y == c.y) {
                continue;
            }
        }
        s.path.push_back(_node_point(nodes[i]));
    }
    s.status = DONE;
    stat_paths++;
    s.open.clear();
    s.open.shrink_to_fit();
    s.g.clear();
    s.parent.clear();
}

PackedVector3Array AINav::find_path(const Vector3 &from, const Vector3 &to, int max_expansions) {
    Search s;
    s.from = from;
    s.to = to;
    s.max_expansions = max_expansions;
    _advance(s, std::numeric_limits<uint64_t>::max());
    return s.status == DONE ? s.path : PackedVector3Array();
}

int AINav::request_path(const Vector3 &from, const Vector3 &to, float priority,
        int max_expansions) {
    Search s;
    s.id = next_id++;
    s.from = from;
    s.to = to;
    s.priority = priority;
    s.max_expansions = max_expansions;
    searches.emplace(s.id, std::move(s));
    return next_id - 1;
}

int AINav::service(int budget_usec) {
    const uint64_t until = now_usec() + (uint64_t)std::max(budget_usec, 0);
    int finished = 0;
    while (now_usec() < until) {
        // Best first: the most important pending request, oldest on a tie.
        Search *best = nullptr;
        for (auto &kv : searches) {
            Search &s = kv.second;
            if (s.status != PENDING) {
                continue;
            }
            if (best == nullptr || s.priority > best->priority
                    || (s.priority == best->priority && s.id < best->id)) {
                best = &s;
            }
        }
        if (best == nullptr) {
            break;
        }
        if (_advance(*best, until)) {
            finished++;
        }
    }
    return finished;
}

int AINav::get_status(int id) const {
    auto it = searches.find(id);
    return it == searches.end() ? UNKNOWN : (int)it->second.status;
}

PackedVector3Array AINav::get_path(int id) const {
    auto it = searches.find(id);
    return it == searches.end() ? PackedVector3Array() : it->second.path;
}

void AINav::release(int id) {
    searches.erase(id);
}

int AINav::pending() const {
    int n = 0;
    for (const auto &kv : searches) {
        if (kv.second.status == PENDING) {
            n++;
        }
    }
    return n;
}

void AINav::invalidate_box(const AABB &box) {
    stat_invalidations++;
    const int x0 = (int)std::floor(box.position.x / STUD) - 2;
    const int x1 = (int)std::floor((box.position.x + box.size.x) / STUD) + 1;
    const int z0 = (int)std::floor(box.position.z / STUD) - 2;
    const int z1 = (int)std::floor((box.position.z + box.size.z) / STUD) + 1;
    if ((int64_t)(x1 - x0 + 1) * (int64_t)(z1 - z0 + 1) > (int64_t)columns.size()) {
        // A big box: cheaper to walk the cache than the box.
        for (auto it = columns.begin(); it != columns.end();) {
            const int x = (int)(it->first >> 32);
            const int z = (int)(int32_t)(uint32_t)(it->first & 0xFFFFFFFF);
            if (x >= x0 && x <= x1 && z >= z0 && z <= z1) {
                it = columns.erase(it);
            } else {
                ++it;
            }
        }
        for (auto it = node_memo.begin(); it != node_memo.end();) {
            const int x = (int)(it->first >> 32);
            const int z = (int)(int32_t)(uint32_t)(it->first & 0xFFFFFFFF);
            if (x >= x0 && x <= x1 && z >= z0 && z <= z1) {
                it = node_memo.erase(it);
            } else {
                ++it;
            }
        }
    } else {
        for (int x = x0; x <= x1; ++x) {
            for (int z = z0; z <= z1; ++z) {
                columns.erase(ckey(x, z));
                node_memo.erase(ckey(x, z));
            }
        }
    }
    revision++;
    // A search that may have read those columns starts again.
    for (auto &kv : searches) {
        if (kv.second.status == PENDING && kv.second.started) {
            kv.second.started = false;
        }
    }
    emit_signal("nav_changed", box);
}

void AINav::clear_cache() {
    columns.clear();
    node_memo.clear();
    revision++;
}

Dictionary AINav::get_stats() const {
    Dictionary d;
    d["columns_cached"] = (int)columns.size();
    d["nodes_cached"] = (int)node_memo.size();
    d["columns_read"] = (int64_t)stat_columns_read;
    d["expansions"] = (int64_t)stat_expansions;
    d["paths"] = (int64_t)stat_paths;
    d["failed"] = (int64_t)stat_failed;
    d["search_ms"] = (double)stat_search_usec / 1000.0;
    d["invalidations"] = (int64_t)stat_invalidations;
    d["pending"] = pending();
    d["worst_expand_us"] = (int64_t)stat_worst_expand_usec;
    d["worst_snap_us"] = (int64_t)stat_worst_snap_usec;
    d["worst_column_us"] = (int64_t)stat_worst_column_usec;
    return d;
}

void AINav::reset_stats() {
    stat_columns_read = 0;
    stat_expansions = 0;
    stat_paths = 0;
    stat_failed = 0;
    stat_search_usec = 0;
    stat_invalidations = 0;
    stat_worst_expand_usec = 0;
    stat_worst_snap_usec = 0;
    stat_worst_column_usec = 0;
}
