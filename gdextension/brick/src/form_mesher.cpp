#include "form_mesher.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <queue>
#include <vector>

void FormMesher::_bind_methods() {
    ClassDB::bind_static_method("FormMesher", D_METHOD("surface", "field", "dims", "cell", "smooth", "blur", "target"),
            &FormMesher::surface, DEFVAL(0), DEFVAL(0));
    ClassDB::bind_static_method("FormMesher", D_METHOD("erode", "field", "dims", "reach"), &FormMesher::erode);
    ClassDB::bind_static_method("FormMesher",
            D_METHOD("surface_sdf", "distance", "pins", "dims", "cell", "smooth", "target"), &FormMesher::surface_sdf);
    ClassDB::bind_static_method("FormMesher", D_METHOD("polygon_distance", "polygons", "origin", "step", "size", "scale"),
            &FormMesher::polygon_distance);
}

PackedByteArray FormMesher::erode(const PackedByteArray &field, const Vector3i &dims, const Vector3i &reach) {
    const int64_t n = (int64_t)dims.x * dims.y * dims.z;
    PackedByteArray out;
    if (dims.x <= 0 || dims.y <= 0 || dims.z <= 0 || field.size() < n) {
        return out;
    }
    std::vector<uint8_t> a(field.ptr(), field.ptr() + n);
    std::vector<uint8_t> b((size_t)n);
    const int64_t stride[3] = {1, dims.x, (int64_t)dims.x * dims.y};
    const int len[3] = {dims.x, dims.y, dims.z};
    // A box erosion is three line erosions. Along a line: how far back the last empty
    // sample is and how far ahead the next, both counted in one pass each way.
    for (int axis = 0; axis < 3; ++axis) {
        const int r = reach[axis];
        if (r <= 0) {
            continue;
        }
        const int L = len[axis];
        const int64_t s = stride[axis];
        std::vector<int> run((size_t)L);
        for (int64_t base = 0; base < n; ++base) {
            // Each line once: from its first sample.
            if ((base / s) % L != 0) {
                continue;
            }
            int since = 0; // solid samples in a row up to here (the edge is empty)
            for (int i = 0; i < L; ++i) {
                since = a[(size_t)(base + i * s)] ? since + 1 : 0;
                run[(size_t)i] = since; // solid samples ending here, this one counted
            }
            int ahead = 0;
            for (int i = L - 1; i >= 0; --i) {
                ahead = a[(size_t)(base + i * s)] ? ahead + 1 : 0;
                // Solid r back and r ahead: the run through here reaches both.
                b[(size_t)(base + i * s)] = (run[(size_t)i] > r && ahead > r) ? 1 : 0;
            }
        }
        a.swap(b);
    }
    out.resize(n);
    std::copy(a.begin(), a.end(), out.ptrw());
    return out;
}

namespace {

// A plane's error quadric, the 4x4 symmetric matrix kept as its 10 numbers.
struct Quadric {
    double a[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

    void add_plane(const Vector3 &n, double d, double w) {
        const double x = n.x, y = n.y, z = n.z;
        a[0] += w * x * x; a[1] += w * x * y; a[2] += w * x * z; a[3] += w * x * d;
        a[4] += w * y * y; a[5] += w * y * z; a[6] += w * y * d;
        a[7] += w * z * z; a[8] += w * z * d;
        a[9] += w * d * d;
    }

    void add(const Quadric &o) {
        for (int i = 0; i < 10; ++i) {
            a[i] += o.a[i];
        }
    }

    double error(const Vector3 &p) const {
        const double x = p.x, y = p.y, z = p.z;
        return a[0] * x * x + 2 * a[1] * x * y + 2 * a[2] * x * z + 2 * a[3] * x
                + a[4] * y * y + 2 * a[5] * y * z + 2 * a[6] * y
                + a[7] * z * z + 2 * a[8] * z + a[9];
    }
};

struct Collapse {
    double cost;
    int32_t keep, gone;
    uint32_t stamp_keep, stamp_gone;
    Vector3 at;
    bool operator<(const Collapse &o) const { return cost > o.cost; } // a min-heap
};

// Fewer triangles, same shape: edges collapsed cheapest first by the quadric error
// metric (Garland-Heckbert), until `target` triangles are left. Each collapse keeps
// the surface closed and two-sided (an edge collapses only when its ends share exactly
// two neighbours) and never turns a face over. A pinned vertex never moves: an edge
// with one pinned end collapses onto it, one with two does not collapse. Flat areas
// cost nothing to collapse, so they go first; curves keep their triangles longest.
void decimate(std::vector<Vector3> &pos, std::vector<int32_t> &tris, const std::vector<uint8_t> &pinned,
        int target) {
    const int32_t nv = (int32_t)pos.size();
    const int32_t nf = (int32_t)(tris.size() / 3);
    if (target <= 0 || nf <= target) {
        return;
    }
    std::vector<Quadric> q((size_t)nv);
    std::vector<std::vector<int32_t>> faces_of((size_t)nv);
    std::vector<uint8_t> face_alive((size_t)nf, 1);
    std::vector<uint8_t> vert_alive((size_t)nv, 1);
    std::vector<uint32_t> stamp((size_t)nv, 0);
    auto face_normal = [&](int32_t f, Vector3 &n) -> double {
        const Vector3 &a = pos[tris[f * 3]], &b = pos[tris[f * 3 + 1]], &c = pos[tris[f * 3 + 2]];
        n = (b - a).cross(c - a);
        const double len = n.length();
        if (len > 1e-20) {
            n /= (float)len;
        }
        return len * 0.5;
    };
    for (int32_t f = 0; f < nf; ++f) {
        Vector3 n;
        const double area = face_normal(f, n);
        const double d = -n.dot(pos[tris[f * 3]]);
        for (int k = 0; k < 3; ++k) {
            q[tris[f * 3 + k]].add_plane(n, d, area);
            faces_of[tris[f * 3 + k]].push_back(f);
        }
    }
    auto neighbours = [&](int32_t v, std::vector<int32_t> &out) {
        out.clear();
        for (int32_t f : faces_of[v]) {
            if (!face_alive[f]) {
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                const int32_t w = tris[f * 3 + k];
                if (w != v && std::find(out.begin(), out.end(), w) == out.end()) {
                    out.push_back(w);
                }
            }
        }
    };
    std::priority_queue<Collapse> heap;
    auto offer = [&](int32_t u, int32_t v) {
        if (pinned[u] && pinned[v]) {
            return;
        }
        Quadric sum = q[u];
        sum.add(q[v]);
        Collapse c;
        if (pinned[v]) {
            std::swap(u, v);
        }
        c.keep = u;
        c.gone = v;
        if (pinned[u]) {
            c.at = pos[u];
            c.cost = sum.error(c.at);
        } else {
            const Vector3 cand[3] = {pos[u], pos[v], (pos[u] + pos[v]) * 0.5f};
            c.cost = 1e300;
            for (const Vector3 &p : cand) {
                const double e = sum.error(p);
                if (e < c.cost) {
                    c.cost = e;
                    c.at = p;
                }
            }
        }
        c.stamp_keep = stamp[u];
        c.stamp_gone = stamp[v];
        heap.push(c);
    };
    std::vector<int32_t> nb, nb2;
    for (int32_t v = 0; v < nv; ++v) {
        neighbours(v, nb);
        for (int32_t w : nb) {
            if (w > v) {
                offer(v, w);
            }
        }
    }
    int32_t alive = nf;
    while (alive > target && !heap.empty()) {
        const Collapse c = heap.top();
        heap.pop();
        const int32_t u = c.keep, v = c.gone;
        if (!vert_alive[u] || !vert_alive[v] || stamp[u] != c.stamp_keep || stamp[v] != c.stamp_gone) {
            continue;
        }
        // Still an edge, and its ends share exactly the two vertices across it.
        neighbours(u, nb);
        if (std::find(nb.begin(), nb.end(), v) == nb.end()) {
            continue;
        }
        neighbours(v, nb2);
        int shared = 0;
        for (int32_t w : nb) {
            if (std::find(nb2.begin(), nb2.end(), w) != nb2.end()) {
                ++shared;
            }
        }
        if (shared != 2) {
            continue;
        }
        // Not into a fan of more than MAX_VALENCE triangles: thin slivers render badly,
        // and checking a big fan on every later collapse is what made this slow.
        static constexpr int MAX_VALENCE = 14;
        if ((int)(nb.size() + nb2.size()) - 4 > MAX_VALENCE) {
            continue;
        }
        // No face turned over (or squashed flat) by the move.
        bool ok = true;
        for (int32_t end : {u, v}) {
            for (int32_t f : faces_of[end]) {
                if (!face_alive[f]) {
                    continue;
                }
                const int32_t *t = &tris[f * 3];
                if ((t[0] == u || t[1] == u || t[2] == u) && (t[0] == v || t[1] == v || t[2] == v)) {
                    continue; // goes with the edge
                }
                Vector3 before;
                face_normal(f, before);
                Vector3 p[3];
                for (int k = 0; k < 3; ++k) {
                    p[k] = (t[k] == u || t[k] == v) ? c.at : pos[t[k]];
                }
                Vector3 after = (p[1] - p[0]).cross(p[2] - p[0]);
                const float len = after.length();
                if (len < 1e-12f || before.dot(after / len) < 0.3f) {
                    ok = false;
                    break;
                }
            }
            if (!ok) {
                break;
            }
        }
        if (!ok) {
            continue;
        }
        for (int32_t f : faces_of[v]) {
            if (!face_alive[f]) {
                continue;
            }
            int32_t *t = &tris[f * 3];
            if (t[0] == u || t[1] == u || t[2] == u) {
                face_alive[f] = 0;
                --alive;
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                if (t[k] == v) {
                    t[k] = u;
                }
            }
            faces_of[u].push_back(f);
        }
        vert_alive[v] = 0;
        pos[u] = c.at;
        q[u].add(q[v]);
        ++stamp[u];
        ++stamp[v];
        // Only the edges at u changed (its place and its quadric); the rest keep their
        // costs, and whether a collapse is still allowed is asked when it comes up.
        std::vector<int32_t> &fu = faces_of[u];
        fu.erase(std::remove_if(fu.begin(), fu.end(), [&](int32_t f) { return !face_alive[f]; }), fu.end());
        faces_of[v].clear();
        neighbours(u, nb);
        for (int32_t w : nb) {
            offer(u, w);
        }
    }
    // Packed again: the vertices still used, renumbered.
    std::vector<int32_t> remap((size_t)nv, -1);
    std::vector<Vector3> out_pos;
    std::vector<int32_t> out_tris;
    for (int32_t f = 0; f < nf; ++f) {
        if (!face_alive[f]) {
            continue;
        }
        for (int k = 0; k < 3; ++k) {
            const int32_t w = tris[f * 3 + k];
            if (remap[w] < 0) {
                remap[w] = (int32_t)out_pos.size();
                out_pos.push_back(pos[w]);
            }
            out_tris.push_back(remap[w]);
        }
    }
    pos.swap(out_pos);
    tris.swap(out_tris);
}

} // namespace

// The surface where `d` crosses zero (positive inside), on a grid `P` padded by `pad`
// samples all round (outside the solid), in metres: sample (x, y, z) of the unpadded grid
// at ((x, y, z) + 0.5) * cell. `pin`: samples whose cubes are not smoothed.
static Array mesh_level(const std::vector<float> &d, const std::vector<uint8_t> &pin, const Vector3i &P, int pad,
        const Vector3 &cell, int smooth, int target) {
    Array out;
    auto pidx = [&](int x, int y, int z) -> int64_t {
        return (int64_t)x + (int64_t)P.x * ((int64_t)y + (int64_t)P.y * z);
    };
    auto dens = [&](int x, int y, int z) -> float { return d[(size_t)pidx(x, y, z)]; };

    // A vertex in every cube (of eight samples) the level passes through, at the middle
    // of where it crosses the cube's edges.
    const int64_t cubes = (int64_t)(P.x - 1) * (P.y - 1) * (P.z - 1);
    auto cidx = [&](int x, int y, int z) -> int64_t {
        return (int64_t)x + (int64_t)(P.x - 1) * ((int64_t)y + (int64_t)(P.y - 1) * z);
    };
    std::vector<int32_t> vert_of((size_t)cubes, -1);
    std::vector<Vector3> pos;      // in padded samples
    std::vector<Vector3i> home;
    std::vector<uint8_t> pinned;
    static const int CORNER[8][3] = {
        {0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0}, {0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1}};
    static const int EDGE[12][2] = {
        {0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}};
    for (int z = 0; z < P.z - 1; ++z) {
        for (int y = 0; y < P.y - 1; ++y) {
            for (int x = 0; x < P.x - 1; ++x) {
                float v[8];
                int count = 0;
                bool p = false;
                for (int k = 0; k < 8; ++k) {
                    v[k] = dens(x + CORNER[k][0], y + CORNER[k][1], z + CORNER[k][2]);
                    count += v[k] > 0.0f ? 1 : 0;
                    p = p || pin[(size_t)pidx(x + CORNER[k][0], y + CORNER[k][1], z + CORNER[k][2])];
                }
                if (count == 0 || count == 8) {
                    continue;
                }
                Vector3 sum;
                int crossings = 0;
                for (const auto &e : EDGE) {
                    const float a = v[e[0]], b = v[e[1]];
                    if ((a > 0.0f) == (b > 0.0f)) {
                        continue;
                    }
                    const float t = (0.0f - a) / (b - a);
                    sum += Vector3(CORNER[e[0]][0] + t * (CORNER[e[1]][0] - CORNER[e[0]][0]),
                            CORNER[e[0]][1] + t * (CORNER[e[1]][1] - CORNER[e[0]][1]),
                            CORNER[e[0]][2] + t * (CORNER[e[1]][2] - CORNER[e[0]][2]));
                    ++crossings;
                }
                vert_of[(size_t)cidx(x, y, z)] = (int32_t)pos.size();
                pos.push_back(Vector3((float)x, (float)y, (float)z) + sum / (float)crossings);
                home.push_back(Vector3i(x, y, z));
                pinned.push_back(p ? 1 : 0);
            }
        }
    }
    if (pos.empty()) {
        return out;
    }

    // A quad across every edge the level crosses, joining the four cubes round it; wound
    // so its face looks out of the solid, split along its shorter diagonal.
    std::vector<int32_t> tris;
    std::vector<std::vector<int32_t>> nbr(pos.size());
    auto link = [&](int32_t a, int32_t b) {
        if (std::find(nbr[a].begin(), nbr[a].end(), b) == nbr[a].end()) {
            nbr[a].push_back(b);
            nbr[b].push_back(a);
        }
    };
    for (int axis = 0; axis < 3; ++axis) {
        const int u = (axis + 1) % 3;
        const int w = (axis + 2) % 3;
        // The edge's own axis from the first sample; the other two from 1, since the
        // four cubes round it are one less than it on those.
        for (int z = axis == 2 ? 0 : 1; z < P.z - 1; ++z) {
            for (int y = axis == 1 ? 0 : 1; y < P.y - 1; ++y) {
                for (int x = axis == 0 ? 0 : 1; x < P.x - 1; ++x) {
                    int p[3] = {x, y, z};
                    int q[3] = {x, y, z};
                    q[axis] += 1;
                    if (q[axis] >= (axis == 0 ? P.x : axis == 1 ? P.y : P.z)) {
                        continue;
                    }
                    const bool a = dens(p[0], p[1], p[2]) > 0.0f;
                    const bool b = dens(q[0], q[1], q[2]) > 0.0f;
                    if (a == b) {
                        continue;
                    }
                    int32_t quad[4];
                    bool ok = true;
                    static const int RING[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
                    for (int k = 0; k < 4; ++k) {
                        int c[3] = {p[0], p[1], p[2]};
                        c[u] -= 1 - RING[k][0];
                        c[w] -= 1 - RING[k][1];
                        const int32_t vi = vert_of[(size_t)cidx(c[0], c[1], c[2])];
                        if (vi < 0) {
                            ok = false;
                            break;
                        }
                        quad[k] = vi;
                    }
                    if (!ok) {
                        continue;
                    }
                    // Counter-clockwise seen from +axis; Godot's front faces are clockwise,
                    // so a face looking +axis (solid at p) takes the ring reversed.
                    if (a) {
                        std::swap(quad[1], quad[3]);
                    }
                    for (int k = 0; k < 4; ++k) {
                        link(quad[k], quad[(k + 1) % 4]);
                    }
                    const float d02 = (pos[quad[0]] - pos[quad[2]]).length_squared();
                    const float d13 = (pos[quad[1]] - pos[quad[3]]).length_squared();
                    if (d02 <= d13) {
                        tris.insert(tris.end(), {quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]});
                    } else {
                        tris.insert(tris.end(), {quad[0], quad[1], quad[3], quad[1], quad[2], quad[3]});
                    }
                }
            }
        }
    }

    // Smoothed, each vertex kept in its cube; a pinned one stays where it is.
    std::vector<Vector3> next(pos.size());
    for (int it = 0; it < smooth; ++it) {
        for (size_t i = 0; i < pos.size(); ++i) {
            if (nbr[i].empty() || pinned[i]) {
                next[i] = pos[i];
                continue;
            }
            Vector3 m;
            for (int32_t j : nbr[i]) {
                m += pos[j];
            }
            m /= (float)nbr[i].size();
            const Vector3 c((float)home[i].x, (float)home[i].y, (float)home[i].z);
            next[i] = Vector3(std::clamp(m.x, c.x, c.x + 1.0f), std::clamp(m.y, c.y, c.y + 1.0f),
                    std::clamp(m.z, c.z, c.z + 1.0f));
        }
        pos.swap(next);
    }

    // Into metres (the decimation's error is then in metres too).
    for (Vector3 &p : pos) {
        p = (p - Vector3((float)pad, (float)pad, (float)pad) + Vector3(0.5f, 0.5f, 0.5f)) * cell;
    }
    decimate(pos, tris, pinned, target);

    // Normals: each corner of each triangle its own, the faces round its vertex averaged
    // (by area) only where they turn less than HARD_EDGE from this one -- so a curve
    // shades round and a sharp edge stays sharp, rather than one smudge across it.
    static constexpr float HARD_EDGE_COS = 0.766f; // 40 degrees
    const size_t nt = tris.size() / 3;
    std::vector<Vector3> fn(nt);
    std::vector<std::vector<int32_t>> around(pos.size());
    for (size_t t = 0; t < nt; ++t) {
        const Vector3 a = pos[tris[t * 3]], b = pos[tris[t * 3 + 1]], c = pos[tris[t * 3 + 2]];
        fn[t] = -(b - a).cross(c - a); // clockwise from outside: the cross product points in
        for (int k = 0; k < 3; ++k) {
            around[tris[t * 3 + k]].push_back((int32_t)t);
        }
    }
    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedInt32Array index;
    verts.resize((int64_t)tris.size());
    normals.resize((int64_t)tris.size());
    index.resize((int64_t)tris.size());
    for (size_t t = 0; t < nt; ++t) {
        const Vector3 own = fn[t].length_squared() > 0.0f ? fn[t].normalized() : Vector3(0, 1, 0);
        for (int k = 0; k < 3; ++k) {
            const int32_t v = tris[t * 3 + k];
            Vector3 sum;
            for (int32_t o : around[v]) {
                const float len = fn[o].length();
                if (len > 0.0f && own.dot(fn[o] / len) >= HARD_EDGE_COS) {
                    sum += fn[o];
                }
            }
            const int64_t i = (int64_t)(t * 3 + k);
            verts.set(i, pos[v]);
            normals.set(i, sum.length_squared() > 0.0f ? sum.normalized() : own);
            index.set(i, (int32_t)i);
        }
    }
    out.resize(Mesh::ARRAY_MAX);
    out[Mesh::ARRAY_VERTEX] = verts;
    out[Mesh::ARRAY_NORMAL] = normals;
    out[Mesh::ARRAY_INDEX] = index;
    return out;
}


Array FormMesher::surface(const PackedByteArray &field, const Vector3i &dims, const Vector3 &cell, int smooth,
        int blur, int target) {
    Array out;
    const int64_t n = (int64_t)dims.x * dims.y * dims.z;
    if (dims.x <= 0 || dims.y <= 0 || dims.z <= 0 || field.size() < n) {
        return out;
    }
    const uint8_t *f = field.ptr();
    // The samples as a density, 0 outside and 1 inside, on a grid padded far enough that
    // blurring never reaches its edge. Blurred `blur` times ([1 2 1] / 4 along each axis):
    // a staircase of samples becomes a ramp, and the surface goes where the density
    // crosses one half -- through the slanted line the stairs stood for.
    const int pad = std::max(1, blur + 1);
    const Vector3i P(dims.x + 2 * pad, dims.y + 2 * pad, dims.z + 2 * pad);
    const int64_t pn = (int64_t)P.x * P.y * P.z;
    auto pidx = [&](int x, int y, int z) -> int64_t {
        return (int64_t)x + (int64_t)P.x * ((int64_t)y + (int64_t)P.y * z);
    };
    std::vector<float> d((size_t)pn, 0.0f);
    std::vector<uint8_t> pin((size_t)pn, 0);
    for (int z = 0; z < dims.z; ++z) {
        for (int y = 0; y < dims.y; ++y) {
            for (int x = 0; x < dims.x; ++x) {
                const uint8_t v = f[(int64_t)x + (int64_t)dims.x * ((int64_t)y + (int64_t)dims.y * z)];
                const int64_t i = pidx(x + pad, y + pad, z + pad);
                d[(size_t)i] = v != 0 ? 1.0f : 0.0f;
                pin[(size_t)i] = v == 2 ? 1 : 0;
            }
        }
    }
    {
        std::vector<float> tmp((size_t)pn);
        const int64_t stride[3] = {1, P.x, (int64_t)P.x * P.y};
        const int len[3] = {P.x, P.y, P.z};
        for (int it = 0; it < blur; ++it) {
            for (int axis = 0; axis < 3; ++axis) {
                const int64_t s = stride[axis];
                for (int64_t i = 0; i < pn; ++i) {
                    const int at = (int)((i / s) % len[axis]);
                    const float l = at > 0 ? d[(size_t)(i - s)] : 0.0f;
                    const float r = at < len[axis] - 1 ? d[(size_t)(i + s)] : 0.0f;
                    tmp[(size_t)i] = (l + 2.0f * d[(size_t)i] + r) * 0.25f;
                }
                d.swap(tmp);
            }
        }
    }

    for (float &v : d) {
        v -= 0.5f; // inside where the density is over one half
    }
    return mesh_level(d, pin, P, pad, cell, smooth, target);
}

Array FormMesher::surface_sdf(const PackedFloat32Array &distance, const PackedByteArray &pins, const Vector3i &dims,
        const Vector3 &cell, int smooth, int target) {
    const int64_t n = (int64_t)dims.x * dims.y * dims.z;
    if (dims.x <= 0 || dims.y <= 0 || dims.z <= 0 || distance.size() < n) {
        return Array();
    }
    // Padded by one sample of plain outside, so the surface always closes.
    const int pad = 1;
    const Vector3i P(dims.x + 2, dims.y + 2, dims.z + 2);
    const int64_t pn = (int64_t)P.x * P.y * P.z;
    std::vector<float> d((size_t)pn, -1e6f);
    std::vector<uint8_t> pin((size_t)pn, 0);
    const float *src = distance.ptr();
    const bool has_pins = pins.size() >= n;
    for (int z = 0; z < dims.z; ++z) {
        for (int y = 0; y < dims.y; ++y) {
            for (int x = 0; x < dims.x; ++x) {
                const int64_t i = (int64_t)x + (int64_t)dims.x * ((int64_t)y + (int64_t)dims.y * z);
                const int64_t j = (int64_t)(x + 1) + (int64_t)P.x * ((int64_t)(y + 1) + (int64_t)P.y * (z + 1));
                d[(size_t)j] = -src[i]; // negative distance is inside: positive here
                pin[(size_t)j] = has_pins && pins[i] != 0 ? 1 : 0;
            }
        }
    }
    return mesh_level(d, pin, P, pad, cell, smooth, target);
}

PackedFloat32Array FormMesher::polygon_distance(const Array &polygons, const Vector2 &origin, const Vector2 &step,
        const Vector2i &size, const Vector2 &scale) {
    PackedFloat32Array out;
    if (size.x <= 0 || size.y <= 0) {
        return out;
    }
    out.resize((int64_t)size.x * size.y);
    float *w = out.ptrw();
    std::vector<std::vector<Vector2>> polys;
    for (int64_t i = 0; i < polygons.size(); ++i) {
        const PackedVector2Array src = polygons[i];
        std::vector<Vector2> pts;
        for (int64_t k = 0; k < src.size(); ++k) {
            pts.push_back(Vector2(src[k].x * scale.x, src[k].y * scale.y));
        }
        if (pts.size() >= 3) {
            polys.push_back(pts);
        }
    }
    for (int v = 0; v < size.y; ++v) {
        for (int u = 0; u < size.x; ++u) {
            const Vector2 q((origin.x + (u + 0.5f) * step.x) * scale.x, (origin.y + (v + 0.5f) * step.y) * scale.y);
            float best = 1e30f;
            bool inside = false;
            for (const std::vector<Vector2> &pts : polys) {
                int wind = 0;
                const size_t m = pts.size();
                for (size_t k = 0; k < m; ++k) {
                    const Vector2 &a = pts[k];
                    const Vector2 &b = pts[(k + 1) % m];
                    const Vector2 ab = b - a;
                    const float len2 = ab.length_squared();
                    const float t = len2 > 0.0f ? std::clamp((q - a).dot(ab) / len2, 0.0f, 1.0f) : 0.0f;
                    best = std::min(best, (a + ab * t - q).length_squared());
                    const float side = ab.x * (q.y - a.y) - (q.x - a.x) * ab.y;
                    if (a.y <= q.y) {
                        if (b.y > q.y && side > 0.0f) {
                            ++wind;
                        }
                    } else if (b.y <= q.y && side < 0.0f) {
                        --wind;
                    }
                }
                inside = inside || wind != 0;
            }
            const float dist = std::sqrt(best);
            w[(int64_t)u + (int64_t)size.x * v] = inside ? -dist : dist;
        }
    }
    return out;
}
