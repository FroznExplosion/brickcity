// AINav's hierarchy: HPA* over clusters of columns (Docs/AI.md 4.3.1).
//
// See ai_nav.h (set_hierarchy) for what it is. The pieces:
//
//   _border        the entrances on the border between two clusters: every
//                  crossing a body makes over it (one _step each way), grouped
//                  into runs at one height pair and cut every HIER_RUN columns,
//                  the middle of each run an entrance -- a node a side;
//   _side_edges    what it costs from one side to every other side of its
//                  cluster: a Dijkstra inside the cluster, kept until the
//                  cluster's revision changes;
//   _advance_hier  a request: the costs from its start to the sides of its
//                  cluster and from the sides of the goal's cluster to the goal,
//                  A* over the sides, then the brick-level path between the
//                  entrances it chose, one cluster at a time.
//
// Everything is lazy: a cluster no search has crossed costs nothing.

#include "ai_nav.h"

#include "../brick_grid.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <unordered_set>

using namespace godot;

namespace {

uint64_t hpa_usec() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
}

constexpr float STUD = brick::STUD_M;
constexpr float PLATE = brick::PLATE_M;
constexpr int DX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
constexpr int DZ[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
constexpr float NO_WAY = std::numeric_limits<float>::infinity();
constexpr int64_t START = -1;
constexpr int64_t GOAL = -2;
// Past this many sides the whole hierarchy is forgotten and found again:
// borders found afresh after every change leave the old ones behind.
constexpr size_t SIDES_CAP = 400000;

} // namespace

struct AINav::HpaState {
    int stage = 0;   // 0 ends, 1 the graph, 2 the bricks
    // Brick-level nodes its Dijkstras had looked at when it began: all of them
    // together are held to the request's budget, as a plain search is.
    uint64_t work0 = 0;
    std::vector<std::pair<int, float>> start_edges;
    std::unordered_map<int, float> to_goal;
    std::vector<Open> open;
    std::unordered_map<int64_t, float> g;
    std::unordered_map<int64_t, int64_t> parent;
    int expansions = 0;
    std::vector<Node> way;
    size_t seg = 0;
    std::unique_ptr<Search> sub;
    PackedVector3Array path;
    PackedVector3Array breaches;
};

void AINav::warm(const Vector3 &at, float radius_m) {
    warm_queue.clear();
    if (cluster <= 0) {
        return;
    }
    const float cm = cluster * STUD;
    const int ax = _cluster_of((int)std::floor(at.x / STUD));
    const int az = _cluster_of((int)std::floor(at.z / STUD));
    const int r = (int)std::ceil(radius_m / cm);
    std::vector<std::pair<int, std::pair<int, int>>> order;
    for (int dx = -r; dx <= r; ++dx) {
        for (int dz = -r; dz <= r; ++dz) {
            if (dx * dx + dz * dz <= r * r) {
                order.push_back({ dx * dx + dz * dz, { ax + dx, az + dz } });
            }
        }
    }
    // Farthest first in the vector: it is popped from the back.
    std::sort(order.begin(), order.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    for (const auto &o : order) {
        warm_queue.push_back(o.second);
    }
}

void AINav::_warm_step(uint64_t until_usec) {
    std::vector<int> ids;
    while (!warm_queue.empty() && hpa_usec() < until_usec) {
        const auto c = warm_queue.back();
        _cluster_sides(c.first, c.second, ids);
        bool done = true;
        for (int id : ids) {
            if (hpa_usec() >= until_usec) {
                done = false;
                break;
            }
            _side_edges(id);
        }
        if (done) {
            warm_queue.pop_back();
        }
    }
}

bool AINav::_hier_enclosed(const std::vector<int> &seeds, const std::vector<int> &other, int limit) {
    const std::unordered_set<int> target(other.begin(), other.end());
    std::unordered_set<int> seen;
    std::unordered_set<int64_t> clusters_done;
    std::vector<int> stack(seeds.begin(), seeds.end());
    std::vector<int> in_cluster;
    while (!stack.empty()) {
        const int s = stack.back();
        stack.pop_back();
        if (s < 0 || !sides[(size_t)s].alive || !seen.insert(s).second) {
            continue;
        }
        if (target.count(s)) {
            return false;
        }
        if ((int)seen.size() > limit) {
            return false;
        }
        const int cx = sides[(size_t)s].cx, cz = sides[(size_t)s].cz;
        _cluster_sides(cx, cz, in_cluster);
        if (clusters_done.insert(ckey(cx, cz)).second) {
            for (int o : in_cluster) {
                _side_edges(o);
            }
        }
        // Either way: over the border, and inside the cluster to or from it.
        const int partner = sides[(size_t)s].partner;
        if (partner >= 0 && (sides[(size_t)s].cross < NO_WAY || sides[(size_t)partner].cross < NO_WAY)) {
            stack.push_back(partner);
        }
        for (const auto &e : sides[(size_t)s].edges) {
            stack.push_back(e.first);
        }
        for (int o : in_cluster) {
            for (const auto &e : sides[(size_t)o].edges) {
                if (e.first == s) {
                    stack.push_back(o);
                    break;
                }
            }
        }
    }
    stat_hier_enclosed++;
    return true;
}

bool AINav::_hier_begin(Search &s) {
    Node a, b;
    if (!_snap_node(s.from, a) || !_snap_node(s.to, b)
            || (_cluster_of(a.x) == _cluster_of(b.x) && _cluster_of(a.z) == _cluster_of(b.z))) {
        return false;
    }
    s.hpa = std::make_shared<HpaState>();
    s.start = a;
    s.goal = b;
    s.started = true;
    s.revision = revision;
    s.lo_x = std::min(a.x, b.x) - cluster;
    s.hi_x = std::max(a.x, b.x) + cluster;
    s.lo_z = std::min(a.z, b.z) - cluster;
    s.hi_z = std::max(a.z, b.z) + cluster;
    return true;
}

void AINav::set_hierarchy(int cluster_columns) {
    cluster = std::max(0, cluster_columns);
    sides.clear();
    borders.clear();
    cluster_rev.clear();
}

uint32_t AINav::_crev(int cx, int cz) {
    auto it = cluster_rev.find(ckey(cx, cz));
    return it == cluster_rev.end() ? 1u : it->second;
}

const std::vector<int> &AINav::_border(int cx, int cz, int axis) {
    const int64_t bk = bkey(cx, cz, axis);
    auto it = borders.find(bk);
    if (it != borders.end()) {
        return it->second;
    }
    struct Crossing {
        int t = 0, ya = 0, yb = 0;
        float fwd = NO_WAY, back = NO_WAY;
        Node na, nb;
    };
    std::vector<Crossing> xs;
    const int C = cluster;
    const int fd = axis == 0 ? 0 : 2;   // +x or +z: A into B
    const int bd = axis == 0 ? 1 : 3;   // and back
    for (int i = 0; i < C; ++i) {
        int xa, za, xb, zb;
        if (axis == 0) {
            xa = (cx + 1) * C - 1;
            xb = xa + 1;
            za = zb = cz * C + i;
        } else {
            za = (cz + 1) * C - 1;
            zb = za + 1;
            xa = xb = cx * C + i;
        }
        // _column may drop the cache: copy the floors out first.
        const std::vector<Floor> fa = _column(xa, za).floors;
        for (const Floor &f : fa) {
            const int hn = _node_head(xa, za, f.y);
            // A breacher's body may be in the bricks already where it crosses.
            if (hn < 0 && !(breach_cost > 0.0f && _breach_fit(xa, za, f.y))) {
                continue;
            }
            const Node na{ xa, za, f.y };
            Node out;
            float c = 0.0f;
            if (!_step(na, hn, fd, out, c) || out.x != xb || out.z != zb) {
                continue;
            }
            Crossing x;
            x.t = i;
            x.ya = na.y;
            x.yb = out.y;
            x.fwd = c;
            x.na = na;
            x.nb = out;
            Node back;
            float c2 = 0.0f;
            if (_step(out, _node_head(out.x, out.z, out.y), bd, back, c2) && back.x == xa && back.z == za
                    && back.y == na.y) {
                x.back = c2;
            }
            xs.push_back(x);
        }
        // Ways from B down into A it cannot climb back: one way only.
        const std::vector<Floor> fb = _column(xb, zb).floors;
        for (const Floor &f : fb) {
            const int hb = _node_head(xb, zb, f.y);
            if (hb < 0 && !(breach_cost > 0.0f && _breach_fit(xb, zb, f.y))) {
                continue;
            }
            const Node nb{ xb, zb, f.y };
            Node out;
            float c = 0.0f;
            if (!_step(nb, hb, bd, out, c) || out.x != xa || out.z != za) {
                continue;
            }
            bool known = false;
            for (const Crossing &x : xs) {
                if (x.t == i && x.ya == out.y && x.yb == nb.y) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                Crossing x;
                x.t = i;
                x.ya = out.y;
                x.yb = nb.y;
                x.back = c;
                x.na = out;
                x.nb = nb;
                xs.push_back(x);
            }
        }
    }
    std::sort(xs.begin(), xs.end(), [](const Crossing &a, const Crossing &b) {
        if (a.ya != b.ya) {
            return a.ya < b.ya;
        }
        if (a.yb != b.yb) {
            return a.yb < b.yb;
        }
        const bool af = a.fwd < NO_WAY, bf = b.fwd < NO_WAY;
        if (af != bf) {
            return af;
        }
        const bool ab = a.back < NO_WAY, bb = b.back < NO_WAY;
        if (ab != bb) {
            return ab;
        }
        return a.t < b.t;
    });
    std::vector<int> ids;
    const int bcx = axis == 0 ? cx + 1 : cx;
    const int bcz = axis == 0 ? cz : cz + 1;
    size_t i = 0;
    while (i < xs.size()) {
        size_t j = i + 1;
        while (j < xs.size() && xs[j].ya == xs[i].ya && xs[j].yb == xs[i].yb
                && (xs[j].fwd < NO_WAY) == (xs[i].fwd < NO_WAY) && (xs[j].back < NO_WAY) == (xs[i].back < NO_WAY)
                && xs[j].t == xs[j - 1].t + 1) {
            j++;
        }
        // One entrance in the middle of a short run; two, a little in from
        // its ends, on a long one (a path along a wide street is not bent to
        // its middle).
        std::vector<size_t> picks;
        if ((int)(j - i) <= HIER_RUN) {
            picks.push_back((i + j - 1) / 2);
        } else {
            picks.push_back(i + 2);
            picks.push_back(j - 3);
        }
        for (size_t pk : picks) {
            const Crossing &m = xs[pk];
            const int a = (int)sides.size();
            Side sa;
            sa.node = m.na;
            sa.cx = cx;
            sa.cz = cz;
            sa.partner = a + 1;
            sa.cross = m.fwd;
            Side sb;
            sb.node = m.nb;
            sb.cx = bcx;
            sb.cz = bcz;
            sb.partner = a;
            sb.cross = m.back;
            sides.push_back(sa);
            sides.push_back(sb);
            ids.push_back(a);
            ids.push_back(a + 1);
        }
        i = j;
    }
    return borders.emplace(bk, std::move(ids)).first->second;
}

void AINav::_cluster_sides(int cx, int cz, std::vector<int> &out) {
    out.clear();
    const int keys[4][3] = { { cx, cz, 0 }, { cx, cz, 1 }, { cx - 1, cz, 0 }, { cx, cz - 1, 1 } };
    for (const auto &k : keys) {
        const std::vector<int> ids = _border(k[0], k[1], k[2]);
        for (int id : ids) {
            const Side &s = sides[(size_t)id];
            if (s.alive && s.cx == cx && s.cz == cz) {
                out.push_back(id);
            }
        }
    }
}

void AINav::_local_costs(const Node &from, int x0, int z0, int x1, int z1, int cap,
        std::unordered_map<int64_t, float> &g, const std::vector<int64_t> *targets) {
    // With targets: done once every one of them is settled.
    size_t left = targets != nullptr ? targets->size() : 0;
    auto cmp = [](const Open &a, const Open &b) { return a.f > b.f; };
    std::vector<Open> open;
    g.clear();
    const int64_t k0 = nkey(from.x, from.z, from.y);
    g[k0] = 0.0f;
    open.push_back(Open{ 0.0f, k0 });
    int n_done = 0;
    while (!open.empty() && n_done < cap) {
        std::pop_heap(open.begin(), open.end(), cmp);
        const Open cur = open.back();
        open.pop_back();
        const float gn = g[cur.key];
        if (cur.f > gn + 1e-3f) {
            continue;
        }
        n_done++;
        stat_hier_nodes++;
        if (targets != nullptr && std::find(targets->begin(), targets->end(), cur.key) != targets->end()) {
            if (--left == 0) {
                break;
            }
        }
        const Node n = unkey(cur.key);
        const int hn = _node_head(n.x, n.z, n.y);
        for (int d = 0; d < 8; ++d) {
            Node nb;
            float c = 0.0f;
            if (!_step(n, hn, d, nb, c)) {
                continue;
            }
            if (nb.x < x0 || nb.x > x1 || nb.z < z0 || nb.z > z1) {
                continue;
            }
            const int64_t nk = nkey(nb.x, nb.z, nb.y);
            const float ng = gn + c;
            auto it = g.find(nk);
            if (it != g.end() && it->second <= ng) {
                continue;
            }
            g[nk] = ng;
            open.push_back(Open{ ng, nk });
            std::push_heap(open.begin(), open.end(), cmp);
        }
    }
}

void AINav::_local_costs_to(const Node &to, int x0, int z0, int x1, int z1, int cap,
        std::unordered_map<int64_t, float> &g) {
    auto cmp = [](const Open &a, const Open &b) { return a.f > b.f; };
    std::vector<Open> open;
    g.clear();
    const int64_t k0 = nkey(to.x, to.z, to.y);
    g[k0] = 0.0f;
    open.push_back(Open{ 0.0f, k0 });
    int n_done = 0;
    while (!open.empty() && n_done < cap) {
        std::pop_heap(open.begin(), open.end(), cmp);
        const Open cur = open.back();
        open.pop_back();
        const float cn = g[cur.key];
        if (cur.f > cn + 1e-3f) {
            continue;
        }
        n_done++;
        stat_hier_nodes++;
        const Node n = unkey(cur.key);
        for (int d = 0; d < 8; ++d) {
            const int px = n.x - DX[d];
            const int pz = n.z - DZ[d];
            if (px < x0 || px > x1 || pz < z0 || pz > z1) {
                continue;
            }
            const std::vector<Floor> fl = _column(px, pz).floors;
            for (const Floor &f : fl) {
                if (f.y > n.y + max_drop || f.y < n.y - step_up) {
                    continue;
                }
                const int hm = _node_head(px, pz, f.y);
                if (hm < 0) {
                    continue;
                }
                Node out;
                float c = 0.0f;
                if (!_step(Node{ px, pz, f.y }, hm, d, out, c) || out.x != n.x || out.z != n.z || out.y != n.y) {
                    continue;
                }
                const int64_t mk = nkey(px, pz, f.y);
                const float nc = cn + c;
                auto it = g.find(mk);
                if (it != g.end() && it->second <= nc) {
                    continue;
                }
                g[mk] = nc;
                open.push_back(Open{ nc, mk });
                std::push_heap(open.begin(), open.end(), cmp);
            }
        }
    }
}

float AINav::_straight(const Node &a, const Node &b, int x0, int z0, int x1, int z1) {
    Node n = a;
    float cost = 0.0f;
    const int limit = 2 * (std::abs(a.x - b.x) + std::abs(a.z - b.z)) + 4;
    for (int i = 0; i < limit; ++i) {
        if (n.x == b.x && n.z == b.z) {
            return n.y == b.y ? cost : NO_WAY;
        }
        const int sx = (b.x > n.x) - (b.x < n.x);
        const int sz = (b.z > n.z) - (b.z < n.z);
        // The diagonal if both, else the axis; then each axis alone.
        int tries[3] = { -1, -1, -1 };
        int k = 0;
        for (int d = 0; d < 8; ++d) {
            if (DX[d] == sx && DZ[d] == sz) {
                tries[k++] = d;
            }
        }
        if (sx != 0 && sz != 0) {
            for (int d = 0; d < 4; ++d) {
                if ((DX[d] == sx && DZ[d] == 0) || (DX[d] == 0 && DZ[d] == sz)) {
                    tries[k++] = d;
                }
            }
        }
        const int hn = _node_head(n.x, n.z, n.y);
        bool moved = false;
        for (int t = 0; t < k && !moved; ++t) {
            Node nb;
            float c = 0.0f;
            if (_step(n, hn, tries[t], nb, c) && nb.x >= x0 && nb.x <= x1 && nb.z >= z0 && nb.z <= z1
                    && std::abs(nb.y - b.y) <= std::abs(n.y - b.y) + step_up) {
                n = nb;
                cost += c;
                moved = true;
            }
        }
        if (!moved) {
            return NO_WAY;
        }
    }
    return NO_WAY;
}

void AINav::_side_edges(int sid) {
    const int cx = sides[(size_t)sid].cx;
    const int cz = sides[(size_t)sid].cz;
    const uint32_t rev = _crev(cx, cz);
    if (sides[(size_t)sid].edges_rev == rev) {
        return;
    }
    std::vector<int> others;
    _cluster_sides(cx, cz, others);   // may grow `sides`
    const Node from = sides[(size_t)sid].node;
    const int C = cluster;
    const int x0 = cx * C, z0 = cz * C, x1 = x0 + C - 1, z1 = z0 + C - 1;
    // Straight walks first: across open ground they are the costs, and only
    // the sides they do not reach need the Dijkstra.
    std::vector<std::pair<int, float>> edges;
    std::vector<int64_t> targets;
    std::vector<int> rest;
    for (int o : others) {
        if (o == sid) {
            continue;
        }
        const Node n = sides[(size_t)o].node;
        const float c = _straight(from, n, x0, z0, x1, z1);
        if (c < NO_WAY) {
            edges.push_back({ o, c });
        } else {
            rest.push_back(o);
            targets.push_back(nkey(n.x, n.z, n.y));
        }
    }
    if (!rest.empty()) {
        std::unordered_map<int64_t, float> g;
        g.reserve((size_t)C * C * 2);
        _local_costs(from, x0, z0, x1, z1, C * C * 6, g, &targets);
        stat_hier_dijkstra++;
        for (int o : rest) {
            const Node &n = sides[(size_t)o].node;
            auto it = g.find(nkey(n.x, n.z, n.y));
            if (it != g.end()) {
                edges.push_back({ o, it->second });
            }
        }
    }
    Side &s = sides[(size_t)sid];
    s.edges = std::move(edges);
    s.edges_rev = rev;
}

void AINav::_hier_forget(int x0, int z0, int x1, int z1) {
    if (cluster <= 0 || borders.empty()) {
        return;
    }
    const int cx0 = _cluster_of(x0), cx1 = _cluster_of(x1);
    const int cz0 = _cluster_of(z0), cz1 = _cluster_of(z1);
    for (int cx = cx0; cx <= cx1; ++cx) {
        for (int cz = cz0; cz <= cz1; ++cz) {
            const int64_t keys[4] = { bkey(cx, cz, 0), bkey(cx, cz, 1), bkey(cx - 1, cz, 0), bkey(cx, cz - 1, 1) };
            for (int64_t k : keys) {
                auto it = borders.find(k);
                if (it == borders.end()) {
                    continue;
                }
                for (int id : it->second) {
                    sides[(size_t)id].alive = false;
                }
                borders.erase(it);
            }
            // Its sides' costs, and its neighbours' (their sides on the
            // borders just forgotten are gone).
            const int nb[5][2] = { { cx, cz }, { cx + 1, cz }, { cx - 1, cz }, { cx, cz + 1 }, { cx, cz - 1 } };
            for (const auto &c : nb) {
                cluster_rev[ckey(c[0], c[1])] = _crev(c[0], c[1]) + 1;
            }
        }
    }
}

bool AINav::_advance_hier(Search &s, uint64_t until_usec) {
    const uint64_t t0 = hpa_usec();
    HpaState &h = *s.hpa;
    const int C = cluster;
    auto finish_time = [&]() { stat_hier_usec += hpa_usec() - t0; };
    if (h.stage == 0) {
        if (sides.size() > SIDES_CAP) {
            set_hierarchy(cluster);
        }
        const int sx = _cluster_of(s.start.x), sz = _cluster_of(s.start.z);
        const int gx = _cluster_of(s.goal.x), gz = _cluster_of(s.goal.z);
        std::vector<int> ss;
        _cluster_sides(sx, sz, ss);
        std::unordered_map<int64_t, float> g;
        std::vector<int64_t> targets;
        for (int id : ss) {
            const Node &n = sides[(size_t)id].node;
            targets.push_back(nkey(n.x, n.z, n.y));
        }
        _local_costs(s.start, sx * C, sz * C, sx * C + C - 1, sz * C + C - 1, C * C * 6, g, &targets);
        for (int id : ss) {
            const Node &n = sides[(size_t)id].node;
            auto it = g.find(nkey(n.x, n.z, n.y));
            if (it != g.end()) {
                h.start_edges.push_back({ id, it->second });
            }
        }
        std::vector<int> gs;
        _cluster_sides(gx, gz, gs);
        _local_costs_to(s.goal, gx * C, gz * C, gx * C + C - 1, gz * C + C - 1, C * C * 6, g);
        for (int id : gs) {
            const Node &n = sides[(size_t)id].node;
            auto it = g.find(nkey(n.x, n.z, n.y));
            if (it != g.end()) {
                h.to_goal[id] = it->second;
            }
        }
        // No way at all, found out before the graph is searched: no side of
        // its cluster the start reaches, or none that reaches the goal; or the
        // goal's region (or the start's) closed, a small flood either way
        // finding nothing of the other's.
        std::vector<int> from_start, to_goal_ids;
        for (const auto &e : h.start_edges) {
            from_start.push_back(e.first);
        }
        for (const auto &kv : h.to_goal) {
            to_goal_ids.push_back(kv.first);
        }
        if (from_start.empty() || to_goal_ids.empty()
                || _hier_enclosed(to_goal_ids, from_start, ENCLOSED_LIMIT)
                || _hier_enclosed(from_start, to_goal_ids, ENCLOSED_LIMIT)) {
            s.status = FAILED;
            stat_failed++;
            finish_time();
            return true;
        }
        h.g[START] = 0.0f;
        h.open.push_back(Open{ 0.0f, START });
        h.work0 = stat_hier_nodes;
        h.stage = 1;
    }
    auto node_of = [&](int64_t k) -> Node {
        return k == START ? s.start : (k == GOAL ? s.goal : sides[(size_t)k].node);
    };
    auto heur = [&](int64_t k) {
        const Node n = node_of(k);
        const float dx = (float)std::abs(n.x - s.goal.x);
        const float dz = (float)std::abs(n.z - s.goal.z);
        return ((std::max(dx, dz) + 0.41421356f * std::min(dx, dz)) * STUD
                + std::max(0, s.goal.y - n.y) * PLATE) * 1.001f;
    };
    auto cmp = [](const Open &a, const Open &b) { return a.f > b.f; };
    if (h.stage == 1) {
        // Its own nodes are worth some forty of the plain search's: capped the
        // same, an unreachable goal costs both about the same.
        const int cap = std::max(1000, s.max_expansions / 40);
        auto relax = [&](int64_t from, int64_t to, float c) {
            if (to >= 0 && !sides[(size_t)to].alive) {
                return;
            }
            const float ng = h.g[from] + c;
            auto it = h.g.find(to);
            if (it != h.g.end() && it->second <= ng) {
                return;
            }
            h.g[to] = ng;
            h.parent[to] = from;
            h.open.push_back(Open{ ng + heur(to), to });
            std::push_heap(h.open.begin(), h.open.end(), cmp);
        };
        bool found = false;
        bool out_of_budget = false;
        while (!h.open.empty()) {
            if (hpa_usec() >= until_usec) {
                finish_time();
                return false;
            }
            std::pop_heap(h.open.begin(), h.open.end(), cmp);
            const Open cur = h.open.back();
            h.open.pop_back();
            if (cur.f > h.g[cur.key] + heur(cur.key) + 1e-3f) {
                continue;
            }
            if (cur.key == GOAL) {
                found = true;
                break;
            }
            if (++h.expansions > cap || stat_hier_nodes - h.work0 > (uint64_t)s.max_expansions) {
                out_of_budget = true;
                break;
            }
            if (cur.key == START) {
                for (const auto &e : h.start_edges) {
                    relax(START, e.first, e.second);
                }
                continue;
            }
            const int sid = (int)cur.key;
            const Side sd = sides[(size_t)sid];
            if (sd.cross < NO_WAY) {
                relax(cur.key, sd.partner, sd.cross);
            }
            _side_edges(sid);
            const std::vector<std::pair<int, float>> edges = sides[(size_t)sid].edges;
            for (const auto &e : edges) {
                relax(cur.key, e.first, e.second);
            }
            auto tg = h.to_goal.find(sid);
            if (tg != h.to_goal.end()) {
                relax(cur.key, GOAL, tg->second);
            }
        }
        if (!found && out_of_budget) {
            // Its budget gone on clusters nobody had crossed yet: the plain
            // search, with all of it, as before there was a hierarchy -- never
            // worse than that.
            s.hpa.reset();
            s.no_hier = true;
            s.started = false;
            finish_time();
            return false;
        }
        if (!found) {
            s.status = FAILED;
            stat_failed++;
            finish_time();
            return true;
        }
        std::vector<int64_t> keys;
        for (int64_t k = GOAL; k != START; k = h.parent[k]) {
            keys.push_back(k);
        }
        keys.push_back(START);
        std::reverse(keys.begin(), keys.end());
        for (int64_t k : keys) {
            h.way.push_back(node_of(k));
        }
        h.open.clear();
        h.g.clear();
        h.parent.clear();
        h.stage = 2;
    }
    // The bricks, a stretch at a time: across an entrance it is one step; inside
    // a cluster, the plain search between the two ends.
    while (h.seg + 1 < h.way.size()) {
        const Node a = h.way[h.seg];
        const Node b = h.way[h.seg + 1];
        if (std::max(std::abs(a.x - b.x), std::abs(a.z - b.z)) <= 1) {
            h.path.push_back(_node_point(b));
            if (breach_cost > 0.0f && _node_head(b.x, b.z, b.y) < 0 && _node_head(a.x, a.z, a.y) >= 0) {
                h.breaches.push_back(_node_point(b));
            }
            h.seg++;
            continue;
        }
        if (!h.sub) {
            h.sub = std::make_unique<Search>();
            h.sub->start = a;
            h.sub->goal = b;
            h.sub->presnapped = true;
            h.sub->max_expansions = C * C * 12;
        }
        if (!_advance(*h.sub, until_usec)) {
            finish_time();
            return false;
        }
        if (h.sub->status != DONE) {
            s.status = FAILED;
            stat_failed++;
            h.sub.reset();
            finish_time();
            return true;
        }
        const PackedVector3Array &p = h.sub->path;
        for (int i = 0; i < p.size(); ++i) {
            if (h.path.size() > 0 && i == 0 && h.path[h.path.size() - 1].is_equal_approx(p[0])) {
                continue;
            }
            h.path.push_back(p[i]);
        }
        h.breaches.append_array(h.sub->breaches);
        h.sub.reset();
        h.seg++;
    }
    if (h.path.size() == 0 || !h.path[0].is_equal_approx(_node_point(s.start))) {
        h.path.insert(0, _node_point(s.start));
    }
    s.path = h.path;
    s.breaches = h.breaches;
    s.status = DONE;
    stat_paths++;
    stat_hier_paths++;
    finish_time();
    return true;
}
