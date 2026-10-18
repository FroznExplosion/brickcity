#include "form_mesher.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <cstdint>
#include <vector>

void FormMesher::_bind_methods() {
    ClassDB::bind_static_method("FormMesher", D_METHOD("surface", "field", "dims", "cell", "smooth"),
            &FormMesher::surface);
    ClassDB::bind_static_method("FormMesher", D_METHOD("erode", "field", "dims", "reach"), &FormMesher::erode);
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

Array FormMesher::surface(const PackedByteArray &field, const Vector3i &dims, const Vector3 &cell, int smooth) {
    Array out;
    const int64_t n = (int64_t)dims.x * dims.y * dims.z;
    if (dims.x <= 0 || dims.y <= 0 || dims.z <= 0 || field.size() < n) {
        return out;
    }
    const uint8_t *f = field.ptr();
    // A sample, outside the field empty.
    auto solid = [&](int x, int y, int z) -> bool {
        if (x < 0 || y < 0 || z < 0 || x >= dims.x || y >= dims.y || z >= dims.z) {
            return false;
        }
        return f[(int64_t)x + (int64_t)dims.x * ((int64_t)y + (int64_t)dims.y * z)] != 0;
    };

    // Cubes run from -1 to dims - 1 on each axis: cube c spans samples c and c + 1.
    const int cx = dims.x + 1;
    const int cy = dims.y + 1;
    const int cz = dims.z + 1;
    auto cube_index = [&](int x, int y, int z) -> int64_t {
        return (int64_t)(x + 1) + (int64_t)cx * ((int64_t)(y + 1) + (int64_t)cy * (z + 1));
    };
    std::vector<int32_t> vert_of((size_t)cx * cy * cz, -1);
    std::vector<Vector3> pos;      // in samples: sample (x, y, z) is at (x, y, z)
    std::vector<Vector3i> home;    // each vertex's cube
    std::vector<uint8_t> pinned;   // a cube with a pinned sample (2): not smoothed
    static const int CORNER[8][3] = {
        {0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0}, {0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1}};
    static const int EDGE[12][2] = {
        {0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}};
    for (int z = -1; z < dims.z; ++z) {
        for (int y = -1; y < dims.y; ++y) {
            for (int x = -1; x < dims.x; ++x) {
                bool s[8];
                int count = 0;
                bool pin = false;
                for (int k = 0; k < 8; ++k) {
                    const int sx = x + CORNER[k][0], sy = y + CORNER[k][1], sz = z + CORNER[k][2];
                    s[k] = solid(sx, sy, sz);
                    count += s[k] ? 1 : 0;
                    if (s[k] && f[(int64_t)sx + (int64_t)dims.x * ((int64_t)sy + (int64_t)dims.y * sz)] == 2) {
                        pin = true;
                    }
                }
                if (count == 0 || count == 8) {
                    continue;
                }
                Vector3 sum;
                int crossings = 0;
                for (const auto &e : EDGE) {
                    if (s[e[0]] == s[e[1]]) {
                        continue;
                    }
                    sum += Vector3((CORNER[e[0]][0] + CORNER[e[1]][0]) * 0.5f, (CORNER[e[0]][1] + CORNER[e[1]][1]) * 0.5f,
                            (CORNER[e[0]][2] + CORNER[e[1]][2]) * 0.5f);
                    ++crossings;
                }
                vert_of[(size_t)cube_index(x, y, z)] = (int32_t)pos.size();
                pos.push_back(Vector3((float)x, (float)y, (float)z) + sum / (float)crossings);
                home.push_back(Vector3i(x, y, z));
                pinned.push_back(pin ? 1 : 0);
            }
        }
    }
    if (pos.empty()) {
        return out;
    }

    // A quad across every crossing edge. The edge from sample p to p + axis is shared
    // by the four cubes p - (0|1) on the two other axes. Wound so its face looks out of
    // the solid, then split along its shorter diagonal.
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
        const int v = (axis + 2) % 3;
        int lo[3] = {0, 0, 0};
        int hi[3] = {dims.x, dims.y, dims.z};
        lo[axis] = -1;
        hi[axis] = (axis == 0 ? dims.x : axis == 1 ? dims.y : dims.z);
        for (int c2 = lo[2]; c2 < hi[2]; ++c2) {
            for (int c1 = lo[1]; c1 < hi[1]; ++c1) {
                for (int c0 = lo[0]; c0 < hi[0]; ++c0) {
                    int p[3] = {c0, c1, c2};
                    int q[3] = {c0, c1, c2};
                    q[axis] += 1;
                    const bool a = solid(p[0], p[1], p[2]);
                    const bool b = solid(q[0], q[1], q[2]);
                    if (a == b) {
                        continue;
                    }
                    int32_t quad[4];
                    bool ok = true;
                    // Round the edge: (u, v) offsets 0,0 -> 1,0 -> 1,1 -> 0,1 (minus one each).
                    static const int RING[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
                    for (int k = 0; k < 4; ++k) {
                        int c[3] = {p[0], p[1], p[2]};
                        c[u] -= 1 - RING[k][0];
                        c[v] -= 1 - RING[k][1];
                        const int32_t vi = vert_of[(size_t)cube_index(c[0], c[1], c[2])];
                        if (vi < 0) {
                            ok = false;
                            break;
                        }
                        quad[k] = vi;
                    }
                    if (!ok) {
                        continue;
                    }
                    // Solid at p, empty past it: the face looks along +axis. The ring
                    // u -> v is counter-clockwise seen from +axis; Godot's front faces
                    // are clockwise, so a face looking +axis takes the ring reversed.
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

    // Smoothed, each vertex kept in its cube.
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

    PackedVector3Array verts;
    verts.resize((int64_t)pos.size());
    for (size_t i = 0; i < pos.size(); ++i) {
        verts.set((int64_t)i, (pos[i] + Vector3(0.5f, 0.5f, 0.5f)) * cell);
    }
    // Smooth normals, area-weighted, out of the solid (the winding is clockwise from
    // outside, so a face's cross product points in).
    std::vector<Vector3> nrm(pos.size());
    for (size_t t = 0; t + 2 < tris.size(); t += 3) {
        const Vector3 a = verts[tris[t]], b = verts[tris[t + 1]], c = verts[tris[t + 2]];
        const Vector3 fn = -(b - a).cross(c - a);
        nrm[tris[t]] += fn;
        nrm[tris[t + 1]] += fn;
        nrm[tris[t + 2]] += fn;
    }
    PackedVector3Array normals;
    normals.resize((int64_t)pos.size());
    for (size_t i = 0; i < pos.size(); ++i) {
        normals.set((int64_t)i, nrm[i].length_squared() > 0.0f ? nrm[i].normalized() : Vector3(0, 1, 0));
    }
    PackedInt32Array index;
    index.resize((int64_t)tris.size());
    for (size_t i = 0; i < tris.size(); ++i) {
        index.set((int64_t)i, tris[i]);
    }
    out.resize(Mesh::ARRAY_MAX);
    out[Mesh::ARRAY_VERTEX] = verts;
    out[Mesh::ARRAY_NORMAL] = normals;
    out[Mesh::ARRAY_INDEX] = index;
    return out;
}
