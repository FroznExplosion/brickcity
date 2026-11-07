#include "strength_tree.h"

#include <queue>
#include <unordered_map>
#include <utility>

using godot::Vector3;

namespace brick {

namespace {

struct Acc {
    int64_t studs = 0;
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

void StrengthTree::bake(int32_t n, const std::vector<StrengthJoint> &joints) {
    left.assign((size_t)n, -1);
    right.assign((size_t)n, -1);
    size.assign((size_t)n, 1);
    studs.assign((size_t)n, 0);
    cut_sum.assign((size_t)n, Vector3());
    roots.clear();
    std::vector<int32_t> parent((size_t)n, -1);
    std::vector<std::unordered_map<int32_t, Acc>> adj((size_t)n);

    for (const StrengthJoint &j : joints) {
        if (j.a == j.b || j.studs <= 0) {
            continue;
        }
        const Vector3 w = j.at * (float)j.studs;
        Acc &x = adj[(size_t)j.a][j.b];
        x.studs += j.studs;
        x.sum += w;
        Acc &y = adj[(size_t)j.b][j.a];
        y.studs += j.studs;
        y.sum += w;
    }

    std::priority_queue<Pair, std::vector<Pair>, Below> heap;
    for (int32_t a = 0; a < n; ++a) {
        for (const auto &kv : adj[(size_t)a]) {
            if (a < kv.first) {
                heap.push(Pair{ kv.second.studs, 1, a, kv.first });
            }
        }
    }

    while (!heap.empty()) {
        const Pair p = heap.top();
        heap.pop();
        if (parent[(size_t)p.lo] >= 0 || parent[(size_t)p.hi] >= 0) {
            continue;   // one side has merged since: the pair is dead
        }
        const int32_t a = p.lo;
        const int32_t b = p.hi;
        const Acc between = adj[(size_t)a][b];
        const int32_t c = (int32_t)left.size();
        left.push_back(a);
        right.push_back(b);
        size.push_back(size[(size_t)a] + size[(size_t)b]);
        studs.push_back(between.studs);
        cut_sum.push_back(between.sum);
        parent.push_back(-1);
        parent[(size_t)a] = c;
        parent[(size_t)b] = c;

        // The bigger map is taken over, the smaller added into it.
        const bool a_big = adj[(size_t)a].size() >= adj[(size_t)b].size();
        std::unordered_map<int32_t, Acc> big = std::move(adj[(size_t)(a_big ? a : b)]);
        std::unordered_map<int32_t, Acc> small = std::move(adj[(size_t)(a_big ? b : a)]);
        adj[(size_t)a].clear();
        adj[(size_t)b].clear();
        big.erase(a);
        big.erase(b);
        for (const auto &kv : small) {
            if (kv.first == a || kv.first == b) {
                continue;
            }
            Acc &t = big[kv.first];
            t.studs += kv.second.studs;
            t.sum += kv.second.sum;
        }
        // Pairs not touching a or b keep their sizes and so their scores; the
        // ones that did are dead (parent set) and come back as pairs with c.
        for (const auto &kv : big) {
            std::unordered_map<int32_t, Acc> &nx = adj[(size_t)kv.first];
            nx.erase(a);
            nx.erase(b);
            nx[c] = kv.second;
            heap.push(Pair{ kv.second.studs,
                    (int64_t)size[(size_t)c] * (int64_t)size[(size_t)kv.first],
                    kv.first < c ? kv.first : c, kv.first < c ? c : kv.first });
        }
        adj.push_back(std::move(big));
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
