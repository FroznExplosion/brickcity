#include "terrain_collapse.h"

#include "brick_terrain.h"
#include "brick_world.h"
#include "terrain_biomes.h"
#include "terrain_bond.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <algorithm>
#include <memory>
#include <mutex>
#include <chrono>
#include <unordered_map>
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

/// The top course's columns (brick::top_columns), a tile at a time, held for
/// every attempt of one survey. They come from the packed-tile store
/// (brick::packed_tops, Docs/TerrainCollapse.md 8.4): the drawing packed the
/// tiles round the player already, so a survey samples and packs only ground
/// nothing has drawn since its last edit. (It had its own cache by tile
/// version, SharedTops; the store replaces it.)
struct TopCache {
    std::unordered_map<int64_t, std::vector<TopColumn>> tiles;
    int packed = 0;
    const TopColumn &at(int x, int z) {
        const int tx = fdiv(x, TILE), tz = fdiv(z, TILE);
        const int64_t k = ((int64_t)(tx & 0xFFFFFFF) << 28) | (int64_t)(tz & 0xFFFFFFF);
        auto it = tiles.find(k);
        if (it == tiles.end()) {
            it = tiles.emplace(k, std::vector<TopColumn>()).first;
            bool p = false;
            top_columns(tx, tz, it->second, &p);
            if (p) {
                ++packed;
            }
        }
        return it->second[(size_t)(x - tx * TILE) + TILE * (size_t)(z - tz * TILE)];
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
    int packed = 0;          ///< tiles packed for their top course (cache misses)
    double sample_ms = 0.0;
    double solve_ms = 0.0;
    double tops_ms = 0.0;    ///< the top course's tiles read, or sampled and packed (brick::top_columns)
    double bond_ms = 0.0;    ///< the bricks laid
    double world_ms = 0.0;   ///< the private world built and solved
};

double ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

Attempt run(Vector3i lo, Vector3i hi, int above, int reach, bool last_up, bool last_side,
        double tension, double mass_per_cell, TopCache &tops) {
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

    // --- does loose-looking ground reach the region's side? ---------------
    // Solid cells joined face to face, walked from the region's bottom course
    // (never the ring): ground that is not reached, yet touches the ring, is
    // held only by the edge -- it may be a big island that is loose past it.
    // Then the region is grown and asked again. Asked of CELLS, before any
    // brick is laid: laying the bricks (the top course packs every tile the
    // region covers) and solving them is the expensive part, and a grown
    // region used to pay it at every size it passed through -- seconds under
    // a wide cave roof.
    if (!last_side) {
        std::vector<uint8_t> reached(g.size(), 0);
        std::vector<int32_t> queue;
        queue.reserve(g.size() / 4);
        for (int z = 0; z < D; ++z) {
            for (int x = 0; x < W; ++x) {
                const size_t i = idx(x, 0, z);
                if (g[i] != MAT_AIR) {
                    reached[i] = 1;
                    queue.push_back((int32_t)i);
                }
            }
        }
        const int64_t sy = W, sz = (int64_t)W * H;
        for (size_t qi = 0; qi < queue.size(); ++qi) {
            const int64_t i = queue[qi];
            const int x = (int)(i % W), y = (int)((i / sy) % H), z = (int)(i / sz);
            const int64_t nb[6] = { x > 0 ? i - 1 : -1, x < W - 1 ? i + 1 : -1,
                    y > 0 ? i - sy : -1, y < H - 1 ? i + sy : -1,
                    z > 0 ? i - sz : -1, z < D - 1 ? i + sz : -1 };
            for (int64_t n : nb) {
                if (n < 0 || reached[(size_t)n] || g[(size_t)n] == MAT_AIR) {
                    continue;
                }
                reached[(size_t)n] = 1;
                queue.push_back((int32_t)n);
            }
        }
        for (int z = 0; z < D && !a.side_touch; ++z) {
            for (int x = 0; x < W && !a.side_touch; ++x) {
                if (!(x == 0 || z == 0 || x == W - 1 || z == D - 1)) {
                    continue;
                }
                for (int y = 1; y < H; ++y) {
                    const size_t i = idx(x, y, z);
                    if (g[i] != MAT_AIR && !reached[i]) {
                        a.side_touch = true;
                        break;
                    }
                }
            }
        }
        if (a.side_touch) {
            a.solve_ms = ms_since(t1);
            return a;
        }
    }

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

    // --- the bricks: the ground's bond (Docs/TerrainBond.md) --------------
    //
    // The same bricks the tiles draw and a shot or a pickaxe breaks: the top
    // course is the packer's pieces (brick::top_columns), everything under it
    // the bond's rectangles (brick::bond_rect). They used to be a bond found
    // afresh by each survey, packed up from its region's bottom: the same
    // cell was in another brick next time, and in none anyone could see.
    std::vector<int32_t> owner(g.size(), -1);
    std::vector<VBrick> vb;
    vb.reserve(g.size() / 4);
    // Each column's top course (absolute), INT_MAX where nothing is known.
    const auto tt0 = std::chrono::steady_clock::now();
    std::vector<int> topc((size_t)W * D, INT_MAX);
    for (int z = 0; z < D; ++z) {
        for (int x = 0; x < W; ++x) {
            const TopColumn &t = tops.at(x0 + x, z0 + z);
            if (t.top > -1000000000) {
                topc[(size_t)x + W * z] = fdiv(t.top, PPB);
            }
        }
    }
    a.tops_ms = ms_since(tt0);
    a.packed = tops.packed;
    const auto tb0 = std::chrono::steady_clock::now();
    auto add = [&](int bx, int y, int bz, int bsx, int bsz, uint8_t m) {
        VBrick vbk{ bx, y, bz, bsx, bsz, m, m == MAT_PILLAR, y == H - 1 };
        const int32_t id = (int32_t)vb.size();
        for (int dz = 0; dz < bsz; ++dz) {
            for (int dx = 0; dx < bsx; ++dx) {
                owner[idx(bx + dx, y, bz + dz)] = id;
                if (ring(bx + dx, bz + dz)) {
                    vbk.held = true;
                }
            }
        }
        vb.push_back(vbk);
    };
    // A cell's bond group in course y (region-local x, z; absolute in the
    // lambda below): none outside the region, at or over its column's top
    // course, or already a top piece's.
    auto group_local = [&](int x, int y, int z) -> int {
        if (x < 0 || z < 0 || x >= W || z >= D) {
            return BOND_NONE;
        }
        const uint8_t m = g[idx(x, y, z)];
        if (m == MAT_AIR) {
            return BOND_NONE;
        }
        if (m == MAT_PILLAR) {
            return BOND_PILLAR;
        }
        if (y0 + y >= topc[(size_t)x + W * z]) {
            return BOND_NONE;
        }
        int px, pz, psx, psz;
        if (placed_at(x0 + x, y0 + y, z0 + z, px, pz, psx, psz)) {
            return BOND_NONE;   // a placed brick: its own shape
        }
        return bond_group(m);
    };

    // The top course: each piece whole where all of it (in the region) is
    // there and bonds; else its cells one by one. Loose tops stay single
    // studs (sand falls as columns).
    {
        std::unordered_map<int64_t, std::vector<int32_t>> by_piece;
        for (int z = 0; z < D; ++z) {
            for (int x = 0; x < W; ++x) {
                const TopColumn &t = tops.at(x0 + x, z0 + z);
                const int tc = topc[(size_t)x + W * z];
                if (!t.piece || tc == INT_MAX) {
                    continue;
                }
                const int y = tc - y0;
                if (y < 0 || y >= H) {
                    continue;
                }
                const uint8_t m = g[idx(x, y, z)];
                if (m == MAT_AIR || m == MAT_PILLAR || bond_group(m) == BOND_LOOSE) {
                    continue;
                }
                by_piece[bond_key(t.px, tc, t.pz)].push_back((int32_t)(x + W * z));
            }
        }
        for (const auto &e : by_piece) {
            const int c0 = e.second[0];
            const TopColumn &t = tops.at(x0 + c0 % W, z0 + c0 / W);
            const int y = topc[(size_t)c0] - y0;
            const int rx0 = std::max(t.px - x0, 0), rz0 = std::max(t.pz - z0, 0);
            const int rx1 = std::min(t.px + t.psx - x0, W), rz1 = std::min(t.pz + t.psz - z0, D);
            const uint8_t m = g[idx(c0 % W, y, c0 / W)];
            if ((int)e.second.size() == (rx1 - rx0) * (rz1 - rz0)) {
                add(rx0, y, rz0, rx1 - rx0, rz1 - rz0, m);
            } else {
                for (int32_t c : e.second) {
                    add(c % W, y, c / W, 1, 1, g[idx(c % W, y, c / W)]);
                }
            }
        }
    }

    // Placed blocks under the top course: each the brick the player laid,
    // whole where all of it is here (BrickTerrain.mark_placed).
    {
        std::unordered_map<int64_t, std::vector<int32_t>> by_brick;
        std::unordered_map<int64_t, BondRect> rect_of;
        for (int y = 0; y < H; ++y) {
            for (int z = 0; z < D; ++z) {
                for (int x = 0; x < W; ++x) {
                    const uint8_t m = g[idx(x, y, z)];
                    if (m == MAT_AIR || m == MAT_PILLAR || owner[idx(x, y, z)] >= 0) {
                        continue;
                    }
                    int px, pz, psx, psz;
                    if (!placed_at(x0 + x, y0 + y, z0 + z, px, pz, psx, psz)) {
                        continue;
                    }
                    const int64_t k = bond_key(px, y0 + y, pz);
                    by_brick[k].push_back((int32_t)(x + W * (z + D * y)));
                    rect_of[k] = BondRect{ px, pz, psx, psz };
                }
            }
        }
        for (const auto &e : by_brick) {
            const BondRect &r = rect_of[e.first];
            const int c0 = e.second[0];
            const int y = c0 / (W * D);
            const int rx0 = r.x - x0, rz0 = r.z - z0;
            const bool inside = rx0 >= 0 && rz0 >= 0 && rx0 + r.sx <= W && rz0 + r.sz <= D;
            if (inside && (int)e.second.size() == r.sx * r.sz) {
                add(rx0, y, rz0, r.sx, r.sz, g[idx(c0 % W, y, (c0 / W) % D)]);
            } else {
                for (int32_t c : e.second) {
                    const int cx = c % W, cz = (c / W) % D;
                    add(cx, y, cz, 1, 1, g[idx(cx, y, cz)]);
                }
            }
        }
    }

    // Under it, the bond: every other solid cell's brick, laid once.
    for (int y = 0; y < H; ++y) {
        const int course = y0 + y;
        auto group_abs = [&](int ax, int az) { return group_local(ax - x0, y, az - z0); };
        for (int z = 0; z < D; ++z) {
            for (int x = 0; x < W; ++x) {
                const uint8_t m = g[idx(x, y, z)];
                if (m == MAT_AIR || owner[idx(x, y, z)] >= 0) {
                    continue;
                }
                const BondRect r = bond_rect(x0 + x, course, z0 + z, group_abs);
                int bx = r.x - x0, bz = r.z - z0, bsx = r.sx, bsz = r.sz;
                // Every cell of the rectangle names it, so none is taken yet;
                // if one were, the cell goes alone rather than overlap.
                bool free = bx >= 0 && bz >= 0 && bx + bsx <= W && bz + bsz <= D;
                for (int dz = 0; dz < bsz && free; ++dz) {
                    for (int dx = 0; dx < bsx && free; ++dx) {
                        free = owner[idx(bx + dx, y, bz + dz)] < 0
                                && g[idx(bx + dx, y, bz + dz)] != MAT_AIR;
                    }
                }
                if (!free) {
                    bx = x;
                    bz = z;
                    bsx = 1;
                    bsz = 1;
                }
                add(bx, y, bz, bsx, bsz, m);
            }
        }
    }
    a.bricks = (int)vb.size();
    if (vb.size() > MAX_SOLVE_BRICKS) {
        a.too_big = true;
        a.solve_ms = ms_since(t1);
        return a;
    }

    // --- the buildings' solve, on a world of the survey's own ------------
    a.bond_ms = ms_since(tb0);
    const auto tw0 = std::chrono::steady_clock::now();
    Ref<BrickWorld> w;
    w.instantiate();
    // One archetype a size, baked as met: the top pieces come in the
    // packer's sizes (2x6, 2x3, 1x4 ...), the bond's in 2x4 and its parts.
    std::unordered_map<int, int> arch_of;
    auto arch_for = [&](int sx, int sz) -> int {
        const int k = sx * 64 + sz;
        auto it = arch_of.find(k);
        if (it != arch_of.end()) {
            return it->second;
        }
        const Vector3i size(sx, PPB, sz);
        const int a2 = w->bake_archetype(String("terrain_v") + String::num_int64(k), size,
                (float)(size.x * size.y * size.z * mass_per_cell));
        arch_of[k] = a2;
        return a2;
    };
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
        archs.set((int64_t)i, arch_for(b.sx, b.sz));
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
    // What this edit let go touches it: a group with no brick next to the
    // edit box was loose before it (the generator leaves bits of cave and
    // overhang floating) -- generated ground is left alone until an edit
    // reaches it. Region-local, a stud round and a course over and under.
    const int ex0 = lo.x - 2 - x0, ex1 = hi.x + 2 - x0;
    const int ez0 = lo.z - 2 - z0, ez1 = hi.z + 2 - z0;
    const int ey0 = lob - 1 - y0, ey1 = hib + 1 - y0;
    for (int64_t k = 0; k < gs.size(); ++k) {
        const PackedInt32Array grp = gs[k];
        bool held = false, top = false, near = false;
        for (int64_t j = 0; j < grp.size() && !held; ++j) {
            const int id = grp[j];
            if (id < 0 || id >= (int)of_id.size() || of_id[(size_t)id] < 0) {
                continue;
            }
            const VBrick &b = vb[(size_t)of_id[(size_t)id]];
            held = b.held;
            top = top || b.top;
            near = near || (b.x <= ex1 && b.x + b.sx - 1 >= ex0 && b.z <= ez1 && b.z + b.sz - 1 >= ez0
                    && b.y >= ey0 && b.y <= ey1);
        }
        if (held || !near) {
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
    a.world_ms = ms_since(tw0);
    a.solve_ms = ms_since(t1);
    return a;
}

} // namespace

int TerrainCollapse::material_class(int m) {
    // The ground's bond groups (terrain_bond.h): one list, not two.
    return bond_group(m);
}

Dictionary TerrainCollapse::survey(Vector3i lo, Vector3i hi, double tension, double mass_per_cell) {
    const Vector3i l(std::min(lo.x, hi.x), std::min(lo.y, hi.y), std::min(lo.z, hi.z));
    const Vector3i h(std::max(lo.x, hi.x), std::max(lo.y, hi.y), std::max(lo.z, hi.z));
    Attempt a;
    double sample_ms = 0.0, solve_ms = 0.0, tops_ms = 0.0, bond_ms = 0.0, world_ms = 0.0;
    int up = 0, side = 0;
    int up_max = GROW_TIMES, side_max = GROW_SIDE_TIMES;
    TopCache tops;
    for (int k = 0; k <= 2 * (GROW_TIMES + GROW_SIDE_TIMES) + 2; ++k) {
        a = run(l, h, ABOVE + GROW_UP * up, REACH + GROW_SIDE * side, up >= up_max,
                side >= side_max, tension, mass_per_cell, tops);
        sample_ms += a.sample_ms;
        solve_ms += a.solve_ms;
        tops_ms += a.tops_ms;
        bond_ms += a.bond_ms;
        world_ms += a.world_ms;
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
    out["tops_ms"] = tops_ms;
    out["tiles_packed"] = tops.packed;
    out["bond_ms"] = bond_ms;
    out["world_ms"] = world_ms;
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
