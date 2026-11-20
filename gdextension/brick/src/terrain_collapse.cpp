#include "terrain_collapse.h"

#include "brick_terrain.h"
#include "brick_world.h"
#include "terrain_biomes.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <chrono>
#include <vector>

using namespace brick;

namespace {

inline int fdiv(int a, int b) {
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

constexpr int PPB = 3;              ///< plates a brick
/// Not a material: the air under a ring column's top, filled so the region's
/// edge stands on the ground past it (Docs/TerrainCollapse.md 3).
constexpr uint8_t MAT_PILLAR = 255;
/// Grow the region this many bricks up when a loose group reaches its top,
/// at most GROW_TIMES times; past that a group reaching the top is held.
constexpr int GROW_UP = 24;
constexpr int GROW_TIMES = 2;
/// Grow it this many studs round when ground with no way down inside the
/// region reaches its side (a big island, a long ledge), at most
/// GROW_SIDE_TIMES times; past that what reaches the side is held there.
constexpr int GROW_SIDE = 16;
constexpr int GROW_SIDE_TIMES = 3;
/// Cells a region may hold at most (memory, and the worker's time).
constexpr int64_t MAX_CELLS = 1200000;
/// Virtual bricks a solve may hold at most; a region with more is not solved
/// (what it would have let go is held). The private world's solve is cheap
/// per brick, but a worker's time and memory are not endless.
constexpr size_t MAX_SOLVE_BRICKS = 120000;
/// Loose cells over the region a falling sand column may take at most.
constexpr int MAX_SAND_RUN = 256;

/// One column's cells, a brick tall each: the generator's column worked out
/// once, an edit (per plate) wins over it -- BrickTerrain's solid_at, without
/// three octaves of noise a cell.
struct Sampler {
    bool biomes = false;
    bool edits = false;
    uint32_t seed = 0;
    int x = 0, z = 0;
    BColumn col;

    void column(int cx, int cz) {
        x = cx;
        z = cz;
        if (biomes) {
            col = biome_column(seed, cx, cz);
        }
    }

    /// The cell's material: that of its lowest solid plate, or air.
    int cell(int yb) const {
        if (!biomes) {
            for (int p = 0; p < PPB; ++p) {
                const int m = BrickTerrain::solid_at(x, yb * PPB + p, z);
                if (m != MAT_AIR) {
                    return m;
                }
            }
            return MAT_AIR;
        }
        int g = -1;
        for (int p = 0; p < PPB; ++p) {
            int m = edits ? edit_at(pack_cell(x, yb * PPB + p, z)) : -1;
            if (m < 0) {
                if (g < 0) {
                    g = biome_cell(col, seed, x, yb, z);
                }
                m = g;
            }
            if (m != MAT_AIR) {
                return m;
            }
        }
        return MAT_AIR;
    }
};

struct VBrick {
    int x, y, z;     ///< region-local cell, y in bricks
    int sx, sz;
    uint8_t m;
    bool held;       ///< touches the ring (or is a pillar): the edge holds it
    bool top;        ///< in the region's top course
};

struct Attempt {
    PackedInt32Array sand;
    PackedByteArray sand_mats;
    Array groups;
    bool solved = false;
    bool top_touch = false;
    bool side_touch = false;
    bool too_big = false;   ///< the region (or its bricks) past the limits
    int bricks = 0;
    double sample_ms = 0.0;
    double solve_ms = 0.0;
};

double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

Attempt run(Vector3i lo, Vector3i hi, int above, int reach, bool last_up, bool last_side,
        double tension, double mass_per_cell) {
    Attempt a;
    const auto t0 = std::chrono::steady_clock::now();
    const int lob = fdiv(lo.y, PPB), hib = fdiv(hi.y, PPB);
    const int R = reach;
    const int x0 = lo.x - R - 1, x1 = hi.x + R + 1;
    const int z0 = lo.z - R - 1, z1 = hi.z + R + 1;
    const int y0 = lob - TerrainCollapse::BELOW, y1 = hib + above;
    const int W = x1 - x0 + 1, D = z1 - z0 + 1, H = y1 - y0 + 1;
    if ((int64_t)W * H * D > MAX_CELLS || W < 3 || D < 3 || H < 2) {
        a.too_big = true;
        return a;
    }
    std::vector<uint8_t> g((size_t)W * H * D, (uint8_t)MAT_AIR);
    auto idx = [&](int x, int y, int z) -> size_t {
        return (size_t)x + (size_t)W * ((size_t)y + (size_t)H * (size_t)z);
    };
    Sampler s;
    s.biomes = biomes_on();
    s.edits = !edits_empty();
    s.seed = (uint32_t)BrickTerrain::get_seed();
    for (int z = 0; z < D; ++z) {
        for (int x = 0; x < W; ++x) {
            s.column(x0 + x, z0 + z);
            for (int y = 0; y < H; ++y) {
                g[idx(x, y, z)] = (uint8_t)s.cell(y0 + y);
            }
        }
    }
    a.sample_ms = ms_since(t0);

    // --- sand and gravel: stand only on what is under them ---------------
    const int sx0 = std::max(1, lo.x - 1 - x0), sx1 = std::min(W - 2, hi.x + 1 - x0);
    const int sz0 = std::max(1, lo.z - 1 - z0), sz1 = std::min(D - 2, hi.z + 1 - z0);
    for (int z = sz0; z <= sz1; ++z) {
        for (int x = sx0; x <= sx1; ++x) {
            for (int y = 1; y < H; ++y) {
                if (TerrainCollapse::material_class(g[idx(x, y, z)]) != 1
                        || g[idx(x, y - 1, z)] != MAT_AIR) {
                    continue;
                }
                const int start = y;
                const int64_t first = a.sand_mats.size();
                while (y < H && TerrainCollapse::material_class(g[idx(x, y, z)]) == 1) {
                    a.sand_mats.push_back(g[idx(x, y, z)]);
                    g[idx(x, y, z)] = MAT_AIR;
                    ++y;
                }
                if (y == H) {
                    // The stack goes on over the region: all of it falls.
                    s.column(x0 + x, z0 + z);
                    for (int yy = y0 + H; a.sand_mats.size() - first < MAX_SAND_RUN; ++yy) {
                        const int m = s.cell(yy);
                        if (TerrainCollapse::material_class(m) != 1) {
                            break;
                        }
                        a.sand_mats.push_back((uint8_t)m);
                    }
                }
                a.sand.push_back(x0 + x);
                a.sand.push_back(z0 + z);
                a.sand.push_back((y0 + start) * PPB);
                a.sand.push_back((int)(a.sand_mats.size() - first));
            }
        }
    }

    // --- anything hanging near the edit? ---------------------------------
    bool due = false;
    {
        const int N = TerrainCollapse::NEAR;
        const int cx0 = std::max(1, lo.x - N - x0), cx1 = std::min(W - 2, hi.x + N - x0);
        const int cz0 = std::max(1, lo.z - N - z0), cz1 = std::min(D - 2, hi.z + N - z0);
        const int cy0 = std::max(1, lob - 1 - y0);
        for (int z = cz0; z <= cz1 && !due; ++z) {
            for (int x = cx0; x <= cx1 && !due; ++x) {
                for (int y = cy0; y < H; ++y) {
                    if (g[idx(x, y, z)] != MAT_AIR && g[idx(x, y - 1, z)] == MAT_AIR) {
                        due = true;
                        break;
                    }
                }
            }
        }
    }
    if (!due) {
        return a;
    }
    a.solved = true;
    const auto t1 = std::chrono::steady_clock::now();

    // --- the ring stands on the ground past it ---------------------------
    auto ring = [&](int x, int z) { return x == 0 || z == 0 || x == W - 1 || z == D - 1; };
    for (int z = 0; z < D; ++z) {
        for (int x = 0; x < W; ++x) {
            if (!ring(x, z)) {
                continue;
            }
            int top = -1;
            for (int y = H - 1; y >= 0; --y) {
                if (g[idx(x, y, z)] != MAT_AIR) {
                    top = y;
                    break;
                }
            }
            for (int y = 0; y < top; ++y) {
                if (g[idx(x, y, z)] == MAT_AIR) {
                    g[idx(x, y, z)] = MAT_PILLAR;
                }
            }
        }
    }

    // --- virtual bricks (Docs/TerrainCollapse.md 2) ----------------------
    std::vector<int32_t> owner(g.size(), -1);
    std::vector<VBrick> vb;
    vb.reserve(g.size() / 4);
    auto fits = [&](int ox, int oz, int y, int sx, int sz, uint8_t m) -> bool {
        if (ox < 0 || oz < 0 || ox + sx > W || oz + sz > D) {
            return false;
        }
        for (int dz = 0; dz < sz; ++dz) {
            for (int dx = 0; dx < sx; ++dx) {
                const size_t i = idx(ox + dx, y, oz + dz);
                if (owner[i] >= 0 || g[i] == MAT_AIR) {
                    return false;
                }
                if (g[i] == m) {
                    continue;
                }
                // Another material: bricks bond across a border (a dirt
                // ledge on rock is joined to it), never with sand or a
                // pillar, and a long brick only through rock.
                const int c = g[i] == MAT_PILLAR ? 1 : TerrainCollapse::material_class(g[i]);
                const int cm = m == MAT_PILLAR ? 1 : TerrainCollapse::material_class(m);
                if (c < 2 || cm < 2 || (sx * sz > 4 && c < 3)) {
                    return false;
                }
            }
        }
        return true;
    };
    // Course by course from the bottom, each cell's brick the largest that
    // fits, placed where it laps the most bricks under it: a seam over a
    // seam joins nothing, so the bond comes from the laps, whatever the
    // ground's shape (Docs/TerrainCollapse.md 2).
    static const int STRONG[6][2] = { { 4, 2 }, { 2, 4 }, { 2, 2 }, { 2, 1 }, { 1, 2 }, { 1, 1 } };
    static const int MEDIUM[4][2] = { { 2, 2 }, { 2, 1 }, { 1, 2 }, { 1, 1 } };
    static const int LOOSE[1][2] = { { 1, 1 } };
    auto below = [&](int ox, int oz, int y, int sx, int sz) -> int {
        if (y == 0) {
            return 0;
        }
        int32_t seen[8];
        int n = 0;
        for (int dz = 0; dz < sz; ++dz) {
            for (int dx = 0; dx < sx; ++dx) {
                const int32_t o = owner[idx(ox + dx, y - 1, oz + dz)];
                if (o < 0) {
                    continue;
                }
                bool dup = false;
                for (int k = 0; k < n; ++k) {
                    dup = dup || seen[k] == o;
                }
                if (!dup && n < 8) {
                    seen[n++] = o;
                }
            }
        }
        return n;
    };
    // Edges of a footprint that stand right over a seam of the course under
    // it (two different bricks either side, below): each one a seam over a
    // seam.
    auto seams = [&](int ox, int oz, int y, int sx, int sz) -> int {
        if (y == 0) {
            return 0;
        }
        auto own = [&](int x, int z) -> int32_t {
            if (x < 0 || z < 0 || x >= W || z >= D) {
                return -1;
            }
            return owner[idx(x, y - 1, z)];
        };
        int n = 0;
        auto edge = [&](int ix, int iz, int ox2, int oz2, int len, int stepx, int stepz) {
            int hit = 0;
            for (int k = 0; k < len; ++k) {
                const int32_t a1 = own(ix + k * stepx, iz + k * stepz);
                const int32_t a2 = own(ox2 + k * stepx, oz2 + k * stepz);
                if (a1 >= 0 && a2 >= 0 && a1 != a2) {
                    ++hit;
                }
            }
            if (hit * 2 >= len && hit > 0) {
                ++n;
            }
        };
        edge(ox, oz, ox - 1, oz, sz, 0, 1);                       // -x
        edge(ox + sx - 1, oz, ox + sx, oz, sz, 0, 1);             // +x
        edge(ox, oz, ox, oz - 1, sx, 1, 0);                       // -z
        edge(ox, oz + sz - 1, ox, oz + sz, sx, 1, 0);             // +z
        return n;
    };
    for (int y = 0; y < H; ++y) {
        for (int z = 0; z < D; ++z) {
            for (int x = 0; x < W; ++x) {
                const uint8_t m = g[idx(x, y, z)];
                if (m == MAT_AIR || owner[idx(x, y, z)] >= 0) {
                    continue;
                }
                const int cls = m == MAT_PILLAR ? 1 : TerrainCollapse::material_class(m);
                const int(*sizes)[2] = cls == 3 ? STRONG : (cls == 2 ? MEDIUM : LOOSE);
                const int ns = cls == 3 ? 6 : (cls == 2 ? 4 : 1);
                int best = -1, bx = x, bz = z, bsx = 1, bsz = 1;
                for (int k = 0; k < ns; ++k) {
                    const int sx = sizes[k][0], sz = sizes[k][1];
                    for (int oz = z - sz + 1; oz <= z; ++oz) {
                        for (int ox = x - sx + 1; ox <= x; ++ox) {
                            if (!fits(ox, oz, y, sx, sz, m)) {
                                continue;
                            }
                            const int score = sx * sz * 4 + 6 * std::min(below(ox, oz, y, sx, sz), 3)
                                    - 20 * seams(ox, oz, y, sx, sz);
                            if (score > best) {
                                best = score;
                                bx = ox;
                                bz = oz;
                                bsx = sx;
                                bsz = sz;
                            }
                        }
                    }
                }
                VBrick b{ bx, y, bz, bsx, bsz, m, m == MAT_PILLAR, y == H - 1 };
                const int32_t id = (int32_t)vb.size();
                for (int dz = 0; dz < bsz; ++dz) {
                    for (int dx = 0; dx < bsx; ++dx) {
                        owner[idx(bx + dx, y, bz + dz)] = id;
                        if (ring(bx + dx, bz + dz)) {
                            b.held = true;
                        }
                    }
                }
                vb.push_back(b);
            }
        }
    }
    a.bricks = (int)vb.size();
    if (vb.size() > MAX_SOLVE_BRICKS) {
        a.too_big = true;
        a.solve_ms = ms_since(t1);
        return a;
    }

    // --- does loose-looking ground reach the region's side? ---------------
    // Grounded by its own courses alone (the bottom course; never the ring's
    // pillars): ground that is not, yet touches the ring, is held only by
    // the edge -- it may be a big island that is loose past it. Then the
    // region is grown and asked again, before the solve is paid for.
    if (!last_side) {
        std::vector<uint8_t> grounded(vb.size(), 0);
        std::vector<int32_t> queue;
        queue.reserve(vb.size());
        for (size_t i = 0; i < vb.size(); ++i) {
            if (vb[i].y == 0 && vb[i].m != MAT_PILLAR) {
                grounded[i] = 1;
                queue.push_back((int32_t)i);
            }
        }
        for (size_t qi = 0; qi < queue.size(); ++qi) {
            const VBrick &b = vb[(size_t)queue[qi]];
            for (int dy = -1; dy <= 1; dy += 2) {
                const int yy = b.y + dy;
                if (yy < 0 || yy >= H) {
                    continue;
                }
                for (int dz = 0; dz < b.sz; ++dz) {
                    for (int dx = 0; dx < b.sx; ++dx) {
                        const int32_t o = owner[idx(b.x + dx, yy, b.z + dz)];
                        if (o < 0 || grounded[(size_t)o] || vb[(size_t)o].m == MAT_PILLAR) {
                            continue;
                        }
                        grounded[(size_t)o] = 1;
                        queue.push_back(o);
                    }
                }
            }
        }
        for (size_t i = 0; i < vb.size(); ++i) {
            if (!grounded[i] && vb[i].held && vb[i].m != MAT_PILLAR) {
                a.side_touch = true;
                a.solve_ms = ms_since(t1);
                return a;
            }
        }
    }

    // --- the buildings' solve, on a world of the survey's own ------------
    Ref<BrickWorld> w;
    w.instantiate();
    const int sizes[6][2] = { { 4, 2 }, { 2, 4 }, { 2, 2 }, { 2, 1 }, { 1, 2 }, { 1, 1 } };
    int arch[6];
    for (int k = 0; k < 6; ++k) {
        const Vector3i sz(sizes[k][0], PPB, sizes[k][1]);
        arch[k] = w->bake_archetype(String("terrain_v") + String::num_int64(k), sz,
                (float)(sz.x * sz.y * sz.z * mass_per_cell));
    }
    const int ch = w->create_chunk(Vector3i(0, 0, 0), Vector3i(W, H * PPB, D));
    PackedInt32Array cells, archs;
    PackedByteArray cols;
    cells.resize((int64_t)vb.size() * 3);
    archs.resize((int64_t)vb.size());
    cols.resize((int64_t)vb.size());
    for (size_t i = 0; i < vb.size(); ++i) {
        const VBrick &b = vb[i];
        cells.set((int64_t)i * 3, b.x);
        cells.set((int64_t)i * 3 + 1, b.y * PPB);
        cells.set((int64_t)i * 3 + 2, b.z);
        int k = 5;
        for (int q = 0; q < 6; ++q) {
            if (sizes[q][0] == b.sx && sizes[q][1] == b.sz) {
                k = q;
                break;
            }
        }
        archs.set((int64_t)i, arch[k]);
        cols.set((int64_t)i, 0);
    }
    const PackedInt32Array ids = w->place_blocks(ch, Vector3i(0, 0, 0), cells, archs, cols);
    int max_id = -1;
    for (int64_t i = 0; i < ids.size(); ++i) {
        max_id = std::max(max_id, (int)ids[i]);
    }
    std::vector<int32_t> of_id((size_t)std::max(max_id + 1, 0), -1);
    for (int64_t i = 0; i < ids.size(); ++i) {
        if (ids[i] >= 0) {
            of_id[(size_t)ids[i]] = (int32_t)i;
        }
    }
    w->set_tension_per_stud(ch, (float)tension);
    const Dictionary solve = w->solve_structure(ch, 48, 0.0);
    const Array gs = solve.get("groups", Array());
    for (int64_t k = 0; k < gs.size(); ++k) {
        const PackedInt32Array grp = gs[k];
        bool held = false, top = false;
        for (int64_t j = 0; j < grp.size() && !held; ++j) {
            const int id = grp[j];
            if (id < 0 || id >= (int)of_id.size() || of_id[(size_t)id] < 0) {
                continue;
            }
            const VBrick &b = vb[(size_t)of_id[(size_t)id]];
            held = b.held;
            top = top || b.top;
        }
        if (held) {
            continue;
        }
        if (top && !last_up) {
            a.top_touch = true;
            continue;
        }
        if (top) {
            continue;   // reaches past the tallest region: held up there
        }
        PackedInt32Array out;
        out.resize(grp.size() * 6);
        int64_t n = 0;
        for (int64_t j = 0; j < grp.size(); ++j) {
            const int id = grp[j];
            if (id < 0 || id >= (int)of_id.size() || of_id[(size_t)id] < 0) {
                continue;
            }
            const VBrick &b = vb[(size_t)of_id[(size_t)id]];
            out.set(n++, x0 + b.x);
            out.set(n++, (y0 + b.y) * PPB);
            out.set(n++, z0 + b.z);
            out.set(n++, b.sx);
            out.set(n++, b.sz);
            out.set(n++, b.m);
        }
        out.resize(n);
        if (n > 0) {
            a.groups.push_back(out);
        }
    }
    a.solve_ms = ms_since(t1);
    return a;
}

} // namespace

int TerrainCollapse::material_class(int m) {
    switch (m) {
        case MAT_AIR:
            return 0;
        case MAT_SAND:
        case MAT_RED_SAND:
        case MAT_GRAVEL:
            return 1;
        case MAT_GRASS:
        case MAT_DIRT:
        case MAT_SNOW:
        case MAT_CLAY:
        case MAT_PODZOL:
        case MAT_DRY_GRASS:
        case MAT_LUSH_GRASS:
        case MAT_COLD_GRASS:
        case MAT_DARK_GRASS:
            return 2;
        default:
            return 3;
    }
}

Dictionary TerrainCollapse::survey(Vector3i lo, Vector3i hi, double tension, double mass_per_cell) {
    const Vector3i l(std::min(lo.x, hi.x), std::min(lo.y, hi.y), std::min(lo.z, hi.z));
    const Vector3i h(std::max(lo.x, hi.x), std::max(lo.y, hi.y), std::max(lo.z, hi.z));
    Attempt a;
    double sample_ms = 0.0, solve_ms = 0.0;
    int up = 0, side = 0;
    int up_max = GROW_TIMES, side_max = GROW_SIDE_TIMES;
    for (int k = 0; k <= 2 * (GROW_TIMES + GROW_SIDE_TIMES) + 2; ++k) {
        a = run(l, h, ABOVE + GROW_UP * up, REACH + GROW_SIDE * side, up >= up_max,
                side >= side_max, tension, mass_per_cell);
        sample_ms += a.sample_ms;
        solve_ms += a.solve_ms;
        if (a.too_big) {
            // Grown past the limits: back to the last size, and that is the
            // last word (what reaches past it is held).
            if (side > 0) {
                --side;
                side_max = side;
                continue;
            }
            if (up > 0) {
                --up;
                up_max = up;
                continue;
            }
            break;
        }
        if (a.side_touch && side < side_max) {
            ++side;
            continue;
        }
        if (a.top_touch && up < up_max) {
            ++up;
            continue;
        }
        break;
    }
    const int grown = up + side;
    Dictionary out;
    out["sand"] = a.sand;
    out["sand_mats"] = a.sand_mats;
    out["groups"] = a.groups;
    out["solved"] = a.solved;
    out["bricks"] = a.bricks;
    out["grown"] = grown;
    out["sample_ms"] = sample_ms;
    out["solve_ms"] = solve_ms;
    return out;
}

void TerrainCollapse::_bind_methods() {
    ClassDB::bind_static_method("TerrainCollapse",
            D_METHOD("survey", "lo", "hi", "tension", "mass_per_cell"), &TerrainCollapse::survey);
    ClassDB::bind_static_method("TerrainCollapse", D_METHOD("material_class", "material"),
            &TerrainCollapse::material_class);
    BIND_CONSTANT(REACH);
    BIND_CONSTANT(BELOW);
    BIND_CONSTANT(ABOVE);
    BIND_CONSTANT(NEAR);
}
