#include "strength_tree.h"

#include <algorithm>
#include <queue>
#include <utility>

using godot::Vector3;

namespace brick {

namespace {

struct Edge {
    int32_t nb;
    int64_t studs;
    Vector3 sum;
};

struct Pair {
    int64_t num;   ///< studs between
    int64_t den;   ///< size a x size b
    int32_t lo;
    int32_t hi;
};

// Lower priority first for std::priority_queue: `a` below `b` when b merges
// first. Higher studs per pair first; ties to the lower ids.
struct Below {
    bool operator()(const Pair &a, const Pair &b) const {
        const int64_t l = a.num * b.den;
        const int64_t r = b.num * a.den;
        if (l != r) {
            return l < r;
        }
        if (a.lo != b.lo) {
            return a.lo > b.lo;
        }
        return a.hi > b.hi;
    }
};

} // namespace

// Flat: a cluster's neighbours are a plain vector, not a hash map. A merge
// takes over the bigger list, finds the smaller's neighbours in it through a
// slot array stamped per merge, and each neighbour's own list has a and b
// replaced by c in place. About twice as fast as hash maps on a tower (2.6 ->
// 1.35 ms, 982 bricks, debug build;
// strength_tree_probe prints the bake).
void StrengthTree::bake(int32_t n, const std::vector<StrengthJoint> &joints) {
    left.assign((size_t)n, -1);
    right.assign((size_t)n, -1);
    size.assign((size_t)n, 1);
    studs.assign((size_t)n, 0);
    cut_sum.assign((size_t)n, Vector3());
    roots.clear();
    const size_t total = n > 0 ? (size_t)(2 * n - 1) : 0;
    left.reserve(total);
    right.reserve(total);
    size.reserve(total);
    studs.reserve(total);
    cut_sum.reserve(total);
    std::vector<int32_t> parent((size_t)n, -1);
    parent.reserve(total);
    std::vector<std::vector<Edge>> adj((size_t)n);
    adj.reserve(total);

    // One edge per pair: the joint runs sorted by pair and summed.
    std::vector<StrengthJoint> js;
    js.reserve(joints.size());
    for (const StrengthJoint &j : joints) {
        if (j.a == j.b || j.studs <= 0) {
            continue;
        }
        StrengthJoint k = j;
        if (k.a > k.b) {
            std::swap(k.a, k.b);
        }
        js.push_back(k);
    }
    std::sort(js.begin(), js.end(), [](const StrengthJoint &x, const StrengthJoint &y) {
        return x.a != y.a ? x.a < y.a : x.b < y.b;
    });
    std::priority_queue<Pair, std::vector<Pair>, Below> heap;
    for (size_t i = 0; i < js.size();) {
        const int32_t a = js[i].a;
        const int32_t b = js[i].b;
        int64_t st = 0;
        Vector3 sum;
        for (; i < js.size() && js[i].a == a && js[i].b == b; ++i) {
            st += js[i].studs;
            sum += js[i].at * (float)js[i].studs;
        }
        adj[(size_t)a].push_back(Edge{ b, st, sum });
        adj[(size_t)b].push_back(Edge{ a, st, sum });
        heap.push(Pair{ st, 1, a, b });
    }

    std::vector<int32_t> slot(total, -1);
    std::vector<int32_t> slot_stamp(total, -1);
    while (!heap.empty()) {
        const Pair p = heap.top();
        heap.pop();
        if (parent[(size_t)p.lo] >= 0 || parent[(size_t)p.hi] >= 0) {
            continue;   // one side has merged since: the pair is dead
        }
        const int32_t a = p.lo;
        const int32_t b = p.hi;
        const int32_t c = (int32_t)left.size();
        const bool a_big = adj[(size_t)a].size() >= adj[(size_t)b].size();
        std::vector<Edge> list = std::move(adj[(size_t)(a_big ? a : b)]);
        std::vector<Edge> small = std::move(adj[(size_t)(a_big ? b : a)]);
        adj[(size_t)a].clear();
        adj[(size_t)a].shrink_to_fit();
        adj[(size_t)b].clear();
        adj[(size_t)b].shrink_to_fit();

        // Take a and b out of the bigger list, keeping what lay between them.
        int64_t between = 0;
        Vector3 between_sum;
        size_t w = 0;
        for (size_t r = 0; r < list.size(); ++r) {
            if (list[r].nb == a || list[r].nb == b) {
                between = list[r].studs;
                between_sum = list[r].sum;
                continue;
            }
            list[w] = list[r];
            slot[(size_t)list[w].nb] = (int32_t)w;
            slot_stamp[(size_t)list[w].nb] = c;
            ++w;
        }
        list.resize(w);
        for (const Edge &e : small) {
            if (e.nb == a || e.nb == b) {
                continue;
            }
            if (slot_stamp[(size_t)e.nb] == c) {
                Edge &t = list[(size_t)slot[(size_t)e.nb]];
                t.studs += e.studs;
                t.sum += e.sum;
            } else {
                slot[(size_t)e.nb] = (int32_t)list.size();
                slot_stamp[(size_t)e.nb] = c;
                list.push_back(e);
            }
        }

        left.push_back(a);
        right.push_back(b);
        size.push_back(size[(size_t)a] + size[(size_t)b]);
        studs.push_back(between);
        cut_sum.push_back(between_sum);
        parent.push_back(-1);
        parent[(size_t)a] = c;
        parent[(size_t)b] = c;

        // Each neighbour: a and b become c, in place. Pairs not touching a or
        // b keep their sizes and so their scores; the ones that did are dead
        // (parent set) and come back as pairs with c.
        for (const Edge &e : list) {
            std::vector<Edge> &nx = adj[(size_t)e.nb];
            bool put = false;
            for (size_t r = 0; r < nx.size();) {
                if (nx[r].nb == a || nx[r].nb == b) {
                    if (!put) {
                        nx[r] = Edge{ c, e.studs, e.sum };
                        put = true;
                        ++r;
                    } else {
                        nx[r] = nx.back();
                        nx.pop_back();
                    }
                } else {
                    ++r;
                }
            }
            heap.push(Pair{ e.studs, (int64_t)size[(size_t)c] * (int64_t)size[(size_t)e.nb],
                    e.nb < c ? e.nb : c, e.nb < c ? c : e.nb });
        }
        adj.push_back(std::move(list));
    }

    for (int32_t i = 0; i < (int32_t)parent.size(); ++i) {
        if (parent[(size_t)i] < 0) {
            roots.push_back(i);
        }
    }
}

Vector3 StrengthTree::cut_centre(int32_t n) const {
    if (is_leaf(n) || studs[(size_t)n] <= 0) {
        return Vector3();
    }
    return cut_sum[(size_t)n] / (float)studs[(size_t)n];
}

void StrengthTree::split(int32_t node, double energy, const Vector3 &at, double falloff,
        std::vector<int32_t> &out) const {
    std::vector<std::pair<int32_t, double>> stack;
    stack.emplace_back(node, energy);
    const double fo = falloff > 1e-6 ? falloff : 1e-6;
    while (!stack.empty()) {
        const auto top = stack.back();
        stack.pop_back();
        const int32_t n = top.first;
        const double e = top.second;
        if (is_leaf(n)) {
            out.push_back(n);
            continue;
        }
        const double d = (double)cut_centre(n).distance_to(at) / fo;
        const double f = 1.0 / (1.0 + d * d);
        const double need = (double)studs[(size_t)n];
        if (e * f <= need) {
            out.push_back(n);
            continue;
        }
        const double rest = e - need / f;
        const double share = (double)size[(size_t)left[(size_t)n]] / (double)size[(size_t)n];
        stack.emplace_back(left[(size_t)n], rest * share);
        stack.emplace_back(right[(size_t)n], rest * (1.0 - share));
    }
}

void StrengthTree::leaves_of(int32_t node, std::vector<int32_t> &out) const {
    std::vector<int32_t> stack{ node };
    while (!stack.empty()) {
        const int32_t n = stack.back();
        stack.pop_back();
        if (left[(size_t)n] < 0) {
            out.push_back(n);
        } else {
            stack.push_back(left[(size_t)n]);
            stack.push_back(right[(size_t)n]);
        }
    }
}

} // namespace brick
