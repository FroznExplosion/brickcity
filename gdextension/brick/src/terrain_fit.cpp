#include "terrain_fit.h"

#include "brick_terrain.h"
#include "terrain_bond.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <climits>
#include <cmath>
#include <mutex>
#include <thread>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

// The region fit's probe side (Docs/TerrainRegions.md 3 and 11). See the
// header. Everything here is in absolute studs and courses unless named
// local (l...).

namespace {

using brick::TILE;

constexpr int AREA_TILES = 5;              ///< an area is 5 x 5 tiles
constexpr int AREA = AREA_TILES * 32;      ///< studs a side
constexpr int MID_LO = 32, MID_HI = 128;   ///< the metrics' middle 3 x 3 tiles
constexpr int SQ = 16;                     ///< a region's square, studs
constexpr int SECTION_COURSES = 32;        ///< deep sections are 96 plates

enum Kind : uint8_t { K_AIR = 0, K_PARTIAL = 1, K_LOOSE = 2, K_MEDIUM = 3, K_STRONG = 4 };

int fdiv(int a, int b) { return brick::bond_fdiv(a, b); }
int fmod_pos(int a, int b) { return a - fdiv(a, b) * b; }

double hash01(int a, int b, int c, int d) {
    return (double)(brick::bond_hash(a, b, c ^ (d * 0x2545F491)) & 0xFFFFFF) / (double)0x1000000;
}

struct Area {
    int ox = 0, oz = 0;   ///< absolute stud of local (0, 0)
    int c0 = 0, nc = 0;   ///< first course, courses
    int tiles = AREA_TILES;            ///< tiles a side (the probe's areas)
    int w = AREA, d = AREA;            ///< studs along x, along z
    std::vector<uint8_t> mat, kind;
    /// Each column's top course (its generated top plate's), absolute: the
    /// top course is the surface's pieces, never fitted; depth and cave air
    /// are measured from it.
    std::vector<int32_t> top;
    uint32_t field = 0;                ///< the field's serial when sampled
    int idx(int lx, int lz, int lc) const { return lx + w * (lz + d * lc); }
    bool in(int lx, int lz, int lc) const {
        return lx >= 0 && lz >= 0 && lc >= 0 && lx < w && lz < d && lc < nc;
    }
};

// --- the fit's cells, kept -------------------------------------------------
//
// A region's fit reads the generated cells ~1.5 tiles round it (an odd
// region's even neighbours), so neighbouring tiles' jobs read the same cells
// again and again: kept here a byte a cell, in blocks of a tile by
// CELL_BLOCK courses, least recently used out. 0 air, 1 partly solid / the
// top course's / under the bedrock (never fitted), else 2 + kind * 64 +
// material (kind 0 loose, 1 medium, 2 strong; generated materials are < 64).

constexpr int CELL_BLOCK = 12;
constexpr size_t CELL_BLOCKS_MAX = 1536;   // 12 KB each: ~18 MB at most

struct CellBlock {
    std::vector<uint8_t> cells;   ///< TILE x TILE x CELL_BLOCK, x fastest
    std::vector<int32_t> top;     ///< the columns' top courses, TILE x TILE
};

struct CellCache {
    std::mutex lock;
    struct Entry { uint64_t used; uint32_t field; std::shared_ptr<const CellBlock> b; };
    std::unordered_map<int64_t, Entry> blocks;
    uint64_t clock = 0;
    int64_t made = 0, hits = 0;
};
CellCache *g_cells = nullptr;

CellCache &cell_cache() {
    static std::once_flag once;
    std::call_once(once, [] { g_cells = new CellCache(); });
    return *g_cells;
}

int64_t cell_key(int tx, int tz, int cb) {
    return ((int64_t)(tx & 0x1FFFFF) << 42) | ((int64_t)(tz & 0x1FFFFF) << 21) | (int64_t)(cb & 0x1FFFFF);
}

/// Blocks [cb0, cb1] of tile (tx, tz), the missing ones made in one call
/// (a column's biome is worked out once for all of them). Empty: no
/// generator.
std::vector<std::shared_ptr<const CellBlock>> cell_blocks(int tx, int tz, int cb0, int cb1, uint32_t &field) {
    CellCache &cc = cell_cache();
    const uint32_t f = brick::field_serial();
    field = f;
    std::vector<std::shared_ptr<const CellBlock>> out((size_t)(cb1 - cb0 + 1));
    int miss_lo = INT_MAX, miss_hi = INT_MIN;
    {
        std::lock_guard<std::mutex> lk(cc.lock);
        for (int cb = cb0; cb <= cb1; ++cb) {
            auto it = cc.blocks.find(cell_key(tx, tz, cb));
            if (it != cc.blocks.end() && it->second.field == f) {
                it->second.used = ++cc.clock;
                ++cc.hits;
                out[(size_t)(cb - cb0)] = it->second.b;
            } else {
                miss_lo = std::min(miss_lo, cb);
                miss_hi = std::max(miss_hi, cb);
            }
        }
    }
    if (miss_lo > miss_hi) return out;
    std::vector<uint8_t> vox;
    std::vector<int16_t> gtop;
    uint32_t gf = 0;
    if (!brick::generated_cells(tx, tz, miss_lo * CELL_BLOCK * 3, (miss_hi + 1) * CELL_BLOCK * 3, vox, gtop, &gf)) {
        return {};
    }
    const size_t layer = (size_t)TILE * TILE;
    std::vector<int32_t> top(layer);
    for (size_t i = 0; i < layer; ++i) top[i] = fdiv(gtop[i], 3);
    std::vector<std::pair<int64_t, std::shared_ptr<CellBlock>>> made;
    for (int cb = miss_lo; cb <= miss_hi; ++cb) {
        if (out[(size_t)(cb - cb0)]) continue;
        auto b = std::make_shared<CellBlock>();
        b->cells.assign(layer * CELL_BLOCK, 0);
        b->top = top;
        const int c0 = cb * CELL_BLOCK;
        for (int lc = 0; lc < CELL_BLOCK; ++lc) {
            const size_t base = layer * (size_t)((c0 + lc - miss_lo * CELL_BLOCK) * 3);
            for (size_t i = 0; i < layer; ++i) {
                const uint8_t *v = &vox[base + i];
                const int m0 = v[0], m1 = v[layer], m2 = v[2 * layer];
                uint8_t o = 0;
                if (m0 == 255 || m1 == 255 || m2 == 255) {
                    o = 1;
                } else {
                    const int solid = (m0 != 0) + (m1 != 0) + (m2 != 0);
                    if (solid > 0) {
                        if (solid < 3 || c0 + lc >= top[i]) {
                            o = 1;
                        } else {
                            const int g = std::min(brick::bond_group(m0), std::min(brick::bond_group(m1), brick::bond_group(m2)));
                            const int kind = g == brick::BOND_LOOSE ? 0 : (g == brick::BOND_MEDIUM ? 1 : 2);
                            o = (uint8_t)(2 + kind * 64 + std::min(m1, 63));
                        }
                    }
                }
                b->cells[i + layer * (size_t)lc] = o;
            }
        }
        out[(size_t)(cb - cb0)] = b;
        made.push_back({ cell_key(tx, tz, cb), b });
    }
    std::lock_guard<std::mutex> lk(cc.lock);
    cc.made += (int64_t)made.size();
    if (gf != brick::field_serial()) return out;   // the world changed meanwhile: not kept
    if (cc.blocks.size() + made.size() > CELL_BLOCKS_MAX) {
        std::vector<uint64_t> used;
        used.reserve(cc.blocks.size());
        for (const auto &e : cc.blocks) used.push_back(e.second.used);
        const size_t q = used.size() / 4;
        std::nth_element(used.begin(), used.begin() + q, used.end());
        const uint64_t cut = used[q];
        for (auto it = cc.blocks.begin(); it != cc.blocks.end();) {
            it = (it->second.used <= cut || it->second.field != gf) ? cc.blocks.erase(it) : std::next(it);
        }
    }
    for (auto &e : made) cc.blocks[e.first] = CellCache::Entry{ ++cc.clock, gf, e.second };
    return out;
}

/// The box [x0, x0 + w) x [z0, z0 + d), courses [c0, c0 + nc): the
/// GENERATED cells (edits are the game's to apply), from the kept blocks.
/// False without the biome generator.
bool sample_box(int x0, int z0, int w, int d, int c0, int nc, Area &a) {
    a.ox = x0;
    a.oz = z0;
    a.w = w;
    a.d = d;
    a.c0 = c0;
    a.nc = nc;
    const size_t n = (size_t)w * d * nc;
    a.mat.assign(n, 0);
    a.kind.assign(n, K_AIR);
    a.top.assign((size_t)w * d, INT32_MIN / 2);
    struct Lut {
        uint8_t kind[256], mat[256];
        Lut() {
            static const uint8_t KIND_OF[3] = { K_LOOSE, K_MEDIUM, K_STRONG };
            for (int v = 0; v < 256; ++v) {
                kind[v] = v == 0 ? K_AIR : (v == 1 ? K_PARTIAL : (v - 2 < 192 ? KIND_OF[(v - 2) / 64] : K_PARTIAL));
                mat[v] = v < 2 ? 0 : (uint8_t)((v - 2) % 64);
            }
        }
    };
    static const Lut LUT;
    for (int tz = fdiv(z0, TILE); tz <= fdiv(z0 + d - 1, TILE); ++tz) {
        for (int tx = fdiv(x0, TILE); tx <= fdiv(x0 + w - 1, TILE); ++tx) {
            const int lx0 = std::max(0, tx * TILE - x0), lx1 = std::min(w, tx * TILE + TILE - x0);
            const int lz0 = std::max(0, tz * TILE - z0), lz1 = std::min(d, tz * TILE + TILE - z0);
            bool tops = false;
            const int cb0 = fdiv(c0, CELL_BLOCK), cb1 = fdiv(c0 + nc - 1, CELL_BLOCK);
            uint32_t field = 0;
            const std::vector<std::shared_ptr<const CellBlock>> bs = cell_blocks(tx, tz, cb0, cb1, field);
            if (bs.empty()) return false;
            a.field = field;
            for (int cb = cb0; cb <= cb1; ++cb) {
                const std::shared_ptr<const CellBlock> &b = bs[(size_t)(cb - cb0)];
                if (!tops) {
                    tops = true;
                    for (int lz = lz0; lz < lz1; ++lz)
                        for (int lx = lx0; lx < lx1; ++lx)
                            a.top[(size_t)lx + (size_t)w * lz] = b->top[(size_t)(lx + x0 - tx * TILE) + TILE * (size_t)(lz + z0 - tz * TILE)];
                }
                const int k0 = std::max(c0, cb * CELL_BLOCK), k1 = std::min(c0 + nc, cb * CELL_BLOCK + CELL_BLOCK);
                for (int c = k0; c < k1; ++c) {
                    const uint8_t *src = &b->cells[(size_t)TILE * TILE * (size_t)(c - cb * CELL_BLOCK)];
                    for (int lz = lz0; lz < lz1; ++lz) {
                        const uint8_t *row = src + (size_t)(lx0 + x0 - tx * TILE) + TILE * (size_t)(lz + z0 - tz * TILE);
                        const size_t i0 = (size_t)a.idx(lx0, lz, c - c0);
                        uint8_t *kd = a.kind.data() + i0;
                        uint8_t *mt = a.mat.data() + i0;
                        for (int q = 0; q < lx1 - lx0; ++q) {
                            const uint8_t v = row[q];
                            kd[q] = LUT.kind[v];
                            mt[q] = LUT.mat[v];
                        }
                    }
                }
            }
        }
    }
    return true;
}

/// A probe's area: ntiles x ntiles tiles from (tx0, tz0), the surface band
/// (from `below` courses under the lowest column top to over the highest),
/// or with `depth` > 0 a band that many courses under the lowest top.
bool sample_area(int tx0, int tz0, Area &a, int ntiles = AREA_TILES, int depth = 0, int band = 36) {
    a.tiles = ntiles;
    std::vector<uint8_t> vox;
    std::vector<int16_t> gtop;
    int lo = 1 << 30, hi = -(1 << 30);
    for (int k = 0; k < ntiles * ntiles; ++k) {
        if (!brick::generated_cells(tx0 + k % ntiles, tz0 + k / ntiles, 0, 1, vox, gtop)) {
            return false;
        }
        for (int16_t t : gtop) {
            lo = std::min(lo, fdiv(t, 3));
            hi = std::max(hi, fdiv(t, 3));
        }
    }
    const int c0 = depth > 0 ? lo - depth - band : lo - 18;
    const int c1 = depth > 0 ? lo - depth : hi + 1;
    return sample_box(tx0 * TILE, tz0 * TILE, ntiles * TILE, ntiles * TILE, c0, c1 - c0, a);
}

struct Shape {
    int a = 1, b = 1;       ///< footprint, a <= b
    double share = 0.0;
};

/// The mix at one depth: shares a shape (by FitParams::shapes' index) and
/// heights. Band 0 is the surface's; a band applies from `below_m` metres
/// under the column's surface down (Docs/TerrainRegions.md 11: caves use
/// other bricks the deeper they are).
struct Band {
    double below_m = 0.0;
    std::vector<double> share;
    double heights[3] = { 1.0, 0.0, 0.0 };
};

struct FitParams {
    std::string name;
    std::vector<Band> bands;    ///< by depth; [0] the surface's
    /// Bricks may span materials (stone with coal in it); a brick takes the
    /// material of most of its cells, each cell keeps its own for drawing.
    bool mixed = true;
    double cave_stagger = -2.0; ///< the stagger near cave air (-2: as `stagger`)
    int cave_reach = 2;         ///< cells from cave air that count as near it
    bool bond = false;          ///< the old pattern (brick::bond_rect), the reference
    std::vector<Shape> shapes;  ///< 1x1 always among them
    /// The stagger as a filter: among the shapes that fit at a cell, only
    /// those whose outline lies on seams of the course below / above no more
    /// than the best one's share + this are drawn from (0: always the best
    /// stagger; 1: no stagger). Below 0: off.
    double stagger = -1.0;
    double cross = 1.0;         ///< chance a tile edge / section boundary may be crossed
    int float_cells = 500;      ///< a group let go this big floats (0: never)
    bool fit_top = false;       ///< the top course from the fit too (deferred: 12.3)
    int medium_max = 8;         ///< the biggest footprint (cells) in medium ground
    int offset = 7;             ///< odd courses' squares shifted by this
    bool merge = true;          ///< 1x1s merged into a 1-wide neighbour after a region
    bool pair_merge = true;     ///< like bricks side by side joined where their pair shape is short
    bool wide_first = true;     ///< the wide bricks placed to their share before the fill
    double wide_seams = 0.25;   ///< most of a wide brick's outline on seams it may have (+ stagger)
    int tries = 1;              ///< seeds tried a region, the best kept
    double try_seams = 1.0;     ///< a try's score: share error + this x its seams-over-seams share
    int seed = 1;
};

struct Brick {
    int x, z, c, sx, sz, h, mat;
    int layer;
    int64_t region;
    bool loose;
    bool dead = false;   ///< merged into a neighbour
};

struct Fit {
    std::vector<int32_t> id;
    std::vector<Brick> bricks;
    int regions = 0;
    double ms = 0.0;
};

int64_t region_key(int rx, int rz, int layer) {
    return ((int64_t)(rx & 0xFFFFF) << 40) | ((int64_t)(rz & 0xFFFFF) << 20) | (int64_t)(layer & 0xFFFFF);
}

/// Odd courses' squares are shifted this many studs (the probe sets it). An
/// ODD shift also moves the rows of 2-deep bricks, so their long sides are
/// not over the course below's.
int course_off(int c, int off) { return (c & 1) ? off : 0; }

class Fitter {
public:
    Fitter(const Area &a, const FitParams &p, Fit &f) : a_(a), p_(p), f_(f) {}

    /// A region already fitted (the lookup's cache), its bricks laid in so
    /// the regions fitted next read them as the batch fit would.
    void lay(int64_t reg, int layer, int x, int z, int c, int sx, int sz, int h, int mat) {
        if (f_.id.empty()) {
            f_.id.assign(a_.kind.size(), -1);
        }
        const int id = (int)f_.bricks.size();
        f_.bricks.push_back(Brick{ x, z, c, sx, sz, h, mat, layer, reg, false });
        for (int cc = c; cc < c + h; ++cc)
            for (int zz = z; zz < z + sz; ++zz)
                for (int xx = x; xx < x + sx; ++xx) {
                    const int i = at(xx, zz, cc);
                    if (i >= 0) f_.id[(size_t)i] = id;
                }
    }

    /// A laid region's sand and gravel: its own 1x1s in the batch fit (and
    /// seams there), not kept in the cache.
    void lay_loose(int64_t reg, int rx, int rz, int L) {
        if (f_.id.empty()) {
            f_.id.assign(a_.kind.size(), -1);
        }
        for (int k = 0; k < 3; ++k) {
            const int c = L * 3 + k;
            const int o = course_off(c, p_.offset);
            for (int v = 0; v < SQ; ++v)
                for (int u = 0; u < SQ; ++u) {
                    const int x = rx * SQ + o + u, z = rz * SQ + o + v;
                    const int i = at(x, z, c);
                    if (i < 0 || f_.id[(size_t)i] >= 0 || a_.kind[(size_t)i] != K_LOOSE) continue;
                    f_.id[(size_t)i] = (int)f_.bricks.size();
                    f_.bricks.push_back(Brick{ x, z, c, 1, 1, 1, a_.mat[(size_t)i], L, reg, true });
                }
        }
    }

    /// The lookup's job: these regions only, even layers' before odd ones'
    /// (each region's whole reach must be inside the area; `lay` first).
    void fit_regions(const std::vector<std::array<int, 3>> &regs) {
        if (f_.id.empty()) {
            f_.id.assign(a_.kind.size(), -1);
        }
        prepare();
        share_ = p_.bands[0].share.data();
        heights_ = p_.bands[0].heights;
        const uint64_t t0 = godot::Time::get_singleton()->get_ticks_usec();
        for (int parity = 0; parity < 2; ++parity) {
            for (const auto &r : regs) {
                if ((r[2] & 1) != parity) continue;
                region(r[0], r[1], r[2]);
                ++f_.regions;
            }
        }
        f_.ms = (double)(godot::Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    }

    void run() {
        f_.id.assign(a_.kind.size(), -1);
        prepare();
        share_ = p_.bands[0].share.data();
        heights_ = p_.bands[0].heights;
        const uint64_t t0 = godot::Time::get_singleton()->get_ticks_usec();
        if (p_.bond) {
            bond_all();
        } else {
            const int l0 = fdiv(a_.c0, 3), l1 = fdiv(a_.c0 + a_.nc - 1, 3);
            for (int parity = 0; parity < 2; ++parity) {
                for (int L = l0; L <= l1; ++L) {
                    if ((L & 1) != parity) {
                        continue;
                    }
                    const int rx0 = fdiv(a_.ox - SQ, SQ), rx1 = fdiv(a_.ox + a_.w, SQ);
                    const int rz0 = fdiv(a_.oz - SQ, SQ), rz1 = fdiv(a_.oz + a_.d, SQ);
                    for (int rz = rz0; rz <= rz1; ++rz) {
                        for (int rx = rx0; rx <= rx1; ++rx) {
                            region(rx, rz, L);
                            ++f_.regions;
                        }
                    }
                }
            }
        }
        f_.ms = (double)(godot::Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    }

private:
    const Area &a_;
    const FitParams &p_;
    Fit &f_;
    // per region
    std::vector<int> cnt_;
    int hcnt_[3] = { 0, 0, 0 };
    int n_ = 0;
    int seed_ = 1;
    int64_t st_seams_ = 0, st_units_ = 0;
    const double *share_ = nullptr;   ///< the current band's shares
    const double *heights_ = nullptr;
    std::vector<uint8_t> near_cave_;  ///< per cell: within cave_reach of cave air

    /// Cave air (air under its column's top) grown by cave_reach in a box:
    /// where the stagger is the caves' (weaker). Separable: x, then z, then
    /// courses.
    void prepare() {
        const int W = a_.w, D = a_.d, N = a_.nc;
        near_cave_.assign(a_.kind.size(), 0);
        if (p_.cave_stagger < -1.5) return;
        const int R = p_.cave_reach;
        std::vector<uint8_t> &m = near_cave_;
        for (int lc = 0; lc < N; ++lc)
            for (int lz = 0; lz < D; ++lz)
                for (int lx = 0; lx < W; ++lx) {
                    const size_t i = (size_t)a_.idx(lx, lz, lc);
                    m[i] = a_.kind[i] == K_AIR && a_.c0 + lc < a_.top[(size_t)lx + (size_t)W * lz];
                }
        std::vector<uint8_t> t(m.size(), 0);
        auto grow = [&](int stride, int len, int count_outer, auto index_of) {
            (void)stride;
            for (int o = 0; o < count_outer; ++o) {
                int last = -(1 << 20);
                // forward: distance since the last marked; then backward
                for (int k = 0; k < len; ++k) {
                    const size_t i = index_of(o, k);
                    if (m[i]) last = k;
                    t[i] = k - last <= R;
                }
                last = 1 << 20;
                for (int k = len - 1; k >= 0; --k) {
                    const size_t i = index_of(o, k);
                    if (m[i]) last = k;
                    if (last - k <= R) t[i] = 1;
                }
            }
            m.swap(t);
        };
        grow(1, W, D * N, [&](int o, int k) { return (size_t)a_.idx(k, o % D, o / D); });
        grow(W, D, W * N, [&](int o, int k) { return (size_t)a_.idx(o % W, k, o / W); });
        grow(W * D, N, W * D, [&](int o, int k) { return (size_t)a_.idx(o % W, o / W, k); });
    }

    /// The band of a square's course: its bond cells' mean depth under
    /// their columns' tops.
    void pick_band(int c, int bx, int bz) {
        double depth = 0.0;
        int n = 0;
        const int lc = c - a_.c0;
        for (int dz = 0; dz < SQ; ++dz)
            for (int dx = 0; dx < SQ; ++dx) {
                const int lx = bx + dx - a_.ox, lz = bz + dz - a_.oz;
                if (!a_.in(lx, lz, lc) || a_.kind[(size_t)a_.idx(lx, lz, lc)] < K_MEDIUM) continue;
                depth += (double)(a_.top[(size_t)lx + (size_t)a_.w * lz] - c);
                ++n;
            }
        const double m = n > 0 ? depth / n * (double)BrickTerrain::get_brick_metres() : 0.0;
        size_t b = 0;
        for (size_t k = 0; k < p_.bands.size(); ++k)
            if (p_.bands[k].below_m <= m) b = k;
        share_ = p_.bands[b].share.data();
        heights_ = p_.bands[b].heights;
    }

    int at(int x, int z, int c) const {
        const int lx = x - a_.ox, lz = z - a_.oz, lc = c - a_.c0;
        return a_.in(lx, lz, lc) ? a_.idx(lx, lz, lc) : -1;
    }

    /// The region being fitted's free cells, a 16-bit row a square row a
    /// course (bit u: square cell u of that row is in the area, not taken,
    /// medium or strong): fits() reads a row, not each cell. Mixed fills
    /// only (one material a brick checks materials too).
    uint16_t free_[3][SQ];
    int fr_rx_ = 0, fr_rz_ = 0, fr_L_ = INT_MIN;
    bool fr_on_ = false;

    void build_free(int rx, int rz, int L) {
        fr_rx_ = rx; fr_rz_ = rz; fr_L_ = L;
        fr_on_ = p_.mixed;
        if (!fr_on_) return;
        for (int k = 0; k < 3; ++k) {
            const int c = L * 3 + k, o = course_off(c, p_.offset);
            for (int v = 0; v < SQ; ++v) {
                uint16_t row = 0;
                for (int u = 0; u < SQ; ++u) {
                    const int i = at(rx * SQ + o + u, rz * SQ + o + v, c);
                    if (i >= 0 && f_.id[(size_t)i] < 0 && a_.kind[(size_t)i] >= K_MEDIUM) row |= (uint16_t)(1u << u);
                }
                free_[k][v] = row;
            }
        }
    }

    /// A cell taken: its bit off, if it is in the region's squares.
    void take_free(int x, int z, int c) {
        if (!fr_on_ || fdiv(c, 3) != fr_L_) return;
        const int k = c - fr_L_ * 3, o = course_off(c, p_.offset);
        const int u = x - fr_rx_ * SQ - o, v = z - fr_rz_ * SQ - o;
        if (u < 0 || v < 0 || u >= SQ || v >= SQ) return;
        free_[k][v] = (uint16_t)(free_[k][v] & ~(1u << u));
    }

    int place(int x, int z, int c, int sx, int sz, int h, int mat, int layer, int64_t reg, bool loose) {
        if (!loose && (sx * sz * h) > 1) {
            // The material of most of its cells (its strength, its item).
            int count[64] = { 0 };
            for (int cc = c; cc < c + h; ++cc)
                for (int zz = z; zz < z + sz; ++zz)
                    for (int xx = x; xx < x + sx; ++xx) ++count[a_.mat[(size_t)at(xx, zz, cc)] & 63];
            int best = mat & 63;
            for (int m = 0; m < 64; ++m)
                if (count[m] > count[best]) best = m;
            mat = best;
        }
        const int id = (int)f_.bricks.size();
        f_.bricks.push_back(Brick{ x, z, c, sx, sz, h, mat, layer, reg, loose });
        for (int cc = c; cc < c + h; ++cc) {
            for (int zz = z; zz < z + sz; ++zz) {
                for (int xx = x; xx < x + sx; ++xx) {
                    f_.id[(size_t)at(xx, zz, cc)] = id;
                    take_free(xx, zz, cc);
                }
            }
        }
        return id;
    }

    void bond_all() {
        std::unordered_map<int64_t, int> keyed;
        for (int lc = 0; lc < a_.nc; ++lc) {
            const int c = a_.c0 + lc;
            auto group = [&](int x, int z) -> int {
                const int i = at(x, z, c);
                if (i < 0) return brick::BOND_NONE;
                switch (a_.kind[(size_t)i]) {
                    case K_LOOSE: return brick::BOND_LOOSE;
                    case K_MEDIUM: return brick::BOND_MEDIUM;
                    case K_STRONG: return brick::BOND_STRONG;
                    default: return brick::BOND_NONE;
                }
            };
            for (int lz = 0; lz < a_.w; ++lz) {
                for (int lx = 0; lx < a_.w; ++lx) {
                    const int i = a_.idx(lx, lz, lc);
                    const int k = a_.kind[(size_t)i];
                    if (k < K_LOOSE || f_.id[(size_t)i] >= 0) continue;
                    const int x = a_.ox + lx, z = a_.oz + lz;
                    if (k == K_LOOSE) {
                        place(x, z, c, 1, 1, 1, a_.mat[(size_t)i], fdiv(c, 3), 0, true);
                        continue;
                    }
                    const brick::BondRect r = brick::bond_rect(x, c, z, group);
                    const int64_t key = brick::bond_key(r.x, c, r.z);
                    auto it = keyed.find(key);
                    if (it != keyed.end()) {
                        f_.id[(size_t)i] = it->second;
                        continue;
                    }
                    // Only the cells of the rectangle inside the area are laid.
                    const int id = (int)f_.bricks.size();
                    f_.bricks.push_back(Brick{ r.x, r.z, c, r.sx, r.sz, 1, a_.mat[(size_t)i], fdiv(c, 3), 0, false });
                    keyed[key] = id;
                    f_.id[(size_t)i] = id;
                }
            }
        }
    }

    /// True when brick `id`'s cells may be read by a region of layer L
    /// (the game sees only these): its own region, or for an odd layer the
    /// even layers round it.
    bool known(int id, int L, int64_t reg) const {
        const Brick &b = f_.bricks[(size_t)id];
        if (b.layer == L) return b.region == reg;
        return (L & 1) == 1;
    }

    /// Seams of course `cb` along the outline of footprint (x0..x1, z0..z1):
    /// unit edges where the two cells either side are different known
    /// bricks. `units` counts the edges it could see.
    int seams_along(int x0, int x1, int z0, int z1, int cb, int L, int64_t reg, int &units) const {
        int n = 0;
        const int lc = cb - a_.c0;
        if (lc < 0 || lc >= a_.nc) return 0;
        const int32_t *ids = f_.id.data() + (size_t)a_.w * a_.d * lc;
        const int W = a_.w, D = a_.d, ox = a_.ox, oz = a_.oz;
        const bool odd = (L & 1) != 0;
        auto kn = [&](int id) {
            const Brick &b = f_.bricks[(size_t)id];
            return b.layer == L ? b.region == reg : odd;
        };
        auto edge = [&](int ax, int az, int bx, int bz) {
            ax -= ox; bx -= ox; az -= oz; bz -= oz;
            if (ax < 0 || az < 0 || bx < 0 || bz < 0 || ax >= W || bx >= W || az >= D || bz >= D) return;
            const int A = ids[ax + W * az], B = ids[bx + W * bz];
            if (A < 0 || B < 0) return;
            if (!kn(A) || !kn(B)) return;
            ++units;
            if (A != B) ++n;
        };
        for (int x = x0; x <= x1; ++x) {
            edge(x, z0 - 1, x, z0);
            edge(x, z1, x, z1 + 1);
        }
        for (int z = z0; z <= z1; ++z) {
            edge(x0 - 1, z, x0, z);
            edge(x1, z, x1 + 1, z);
        }
        return n;
    }

    bool square_has(int c, int rx, int rz, int x0, int x1, int z0, int z1) const {
        const int o = course_off(c, p_.offset);
        const int sx0 = rx * SQ + o, sz0 = rz * SQ + o;
        return x0 >= sx0 && x1 < sx0 + SQ && z0 >= sz0 && z1 < sz0 + SQ;
    }

    bool gate(int line, int axis, int c, int64_t reg) const {
        if (p_.cross >= 1.0) return true;
        if (p_.cross <= 0.0) return false;
        return hash01(line, axis, (int)(reg & 0x7FFFFFFF), c ^ p_.seed) < p_.cross;
    }

    /// A region tried `tries` times (seeds from the region's coordinates, so
    /// still a pure function), the try closest to the shares with the fewest
    /// seams over seams kept: one greedy pass is either short of the big
    /// shares or stacks seams; picking among a few is cheap (us a region).
    void region(int rx, int rz, int L) {
        const size_t first = f_.bricks.size();
        int best_t = 0;
        double best = 1e18;
        const int tries = std::max(1, p_.tries);
        if (tries > 1) {
            for (int t = 0; t < tries; ++t) {
                seed_ = p_.seed + t * 7919;
                st_seams_ = 0; st_units_ = 0;
                region_once(rx, rz, L);
                double dev = 0.0;
                for (size_t si = 0; si < p_.shapes.size(); ++si) {
                    dev += std::fabs((n_ > 0 ? (double)cnt_[si] / n_ : 0.0) - p_.bands[0].share[si]);
                }
                const double sc = dev + p_.try_seams * (st_units_ > 0 ? (double)st_seams_ / st_units_ : 0.0);
                if (sc < best) { best = sc; best_t = t; }
                undo(first);
            }
        }
        seed_ = p_.seed + best_t * 7919;
        region_once(rx, rz, L);
    }

    void undo(size_t first) {
        for (size_t bi = first; bi < f_.bricks.size(); ++bi) {
            const Brick &b = f_.bricks[bi];
            if (b.dead) continue;
            for (int cc = b.c; cc < b.c + b.h; ++cc)
                for (int zz = b.z; zz < b.z + b.sz; ++zz)
                    for (int xx = b.x; xx < b.x + b.sx; ++xx) f_.id[(size_t)at(xx, zz, cc)] = -1;
        }
        f_.bricks.resize(first);
    }

    void region_once(int rx, int rz, int L) {
        const int64_t reg = region_key(rx, rz, L);
        const size_t first = f_.bricks.size();
        build_free(rx, rz, L);
        cnt_.assign(p_.shapes.size(), 0);
        hcnt_[0] = hcnt_[1] = hcnt_[2] = 0;
        n_ = 0;
        const uint32_t hr = brick::bond_hash(rx, rz, L * 7 + seed_);
        const bool flip_x = (hr & 1U) != 0, flip_z = (hr & 2U) != 0, z_major = (hr & 4U) != 0;
        struct Cand { int x, z, sx, sz, h, shape; double w, frac; };
        std::vector<Cand> cand;
        for (int k = 0; k < 3; ++k) {
            const int c = L * 3 + k;
            if (c < a_.c0 || c >= a_.c0 + a_.nc) continue;
            const int o = course_off(c, p_.offset);
            const int bx = rx * SQ + o, bz = rz * SQ + o;
            pick_band(c, bx, bz);
            if (p_.wide_first) wide_pass(c, k, rx, rz, L, reg, bx, bz);
            // The course under does not change while this course fills.
            SeamMap below_map;
            bool below_made = false;
            for (int u = 0; u < SQ; ++u) {
                for (int v = 0; v < SQ; ++v) {
                    int dx = z_major ? v : u, dz = z_major ? u : v;
                    const int x = bx + (flip_x ? SQ - 1 - dx : dx);
                    const int z = bz + (flip_z ? SQ - 1 - dz : dz);
                    const int i = at(x, z, c);
                    if (i < 0 || f_.id[(size_t)i] >= 0) continue;
                    const int kind = a_.kind[(size_t)i];
                    if (kind < K_LOOSE) continue;
                    const int mat = a_.mat[(size_t)i];
                    if (kind == K_LOOSE) {
                        place(x, z, c, 1, 1, 1, mat, L, reg, true);
                        continue;
                    }
                    cand.clear();
                    double total = 0.0;
                    for (size_t si = 0; si < p_.shapes.size(); ++si) {
                        const Shape &sh = p_.shapes[si];
                        if (kind == K_MEDIUM && sh.a * sh.b > p_.medium_max) continue;
                        const double qw = std::max(0.02, share_[si] * (n_ + 1) - cnt_[si]);
                        for (int orient = 0; orient < (sh.a == sh.b ? 1 : 2); ++orient) {
                            const int sx = orient ? sh.b : sh.a, sz = orient ? sh.a : sh.b;
                            const int x0 = flip_x ? x - sx + 1 : x, z0 = flip_z ? z - sz + 1 : z;
                            const int x1 = x0 + sx - 1, z1 = z0 + sz - 1;
                            // The course under is the same for every height: counted once.
                            int below_sm = -1, below_units = 0;
                            for (int h = 1; h <= 3 - k; ++h) {
                                // fits() checks only the new course: a height left out ends the taller ones.
                                if (h > 1 && heights_[h - 1] <= 0.0) break;
                                if (!fits(x0, x1, z0, z1, c, h, rx, rz, kind, mat, reg)) break;
                                const double hw = std::max(0.02, heights_[h - 1] * (n_ + 1) - hcnt_[h - 1]);
                                const double w = qw * hw;
                                double frac = 0.0;
                                if (p_.stagger >= 0.0) {
                                    if (below_sm < 0) {
                                        if (!below_made) {
                                            seam_map(below_map, bx, bz, c - 1, L, reg);
                                            below_made = true;
                                        }
                                        below_sm = seams_from(below_map, x0, x1, z0, z1, below_units);
                                    }
                                    int units = below_units;
                                    const int sm = below_sm + seams_along(x0, x1, z0, z1, c + h, L, reg, units);
                                    if (units > 0) frac = (double)sm / (double)units;
                                }
                                cand.push_back(Cand{ x0, z0, sx, sz, h, (int)si, w, frac });
                            }
                        }
                    }
                    if (cand.empty()) {
                        // A 1x1 always fits; reached only if the shapes have none.
                        place(x, z, c, 1, 1, 1, mat, L, reg, false);
                        ++n_;
                        ++hcnt_[0];
                        continue;
                    }
                    if (p_.stagger >= 0.0) {
                        double best = 1e9;
                        for (const Cand &cd : cand) best = std::min(best, cd.frac);
                        const double tol = (near_cave_[(size_t)i] && p_.cave_stagger > -1.5) ? p_.cave_stagger : p_.stagger;
                        for (Cand &cd : cand) {
                            if (tol >= 0.0 && cd.frac > best + tol + 1e-9) cd.w = 0.0;
                        }
                    }
                    for (const Cand &cd : cand) total += cd.w;
                    double r = hash01(x, z, c, seed_) * total;
                    size_t pick = 0;
                    for (size_t q = 0; q < cand.size(); ++q) {
                        if (cand[q].w > 0.0) pick = q;   // the last drawable, if rounding runs past
                    }
                    for (size_t q = 0; q < cand.size(); ++q) {
                        r -= cand[q].w;
                        if (cand[q].w > 0.0 && r <= 0.0) { pick = q; break; }
                    }
                    const Cand &cd = cand[pick];
                    {
                        int units = 0;
                        st_seams_ += seams_along(cd.x, cd.x + cd.sx - 1, cd.z, cd.z + cd.sz - 1, c - 1, L, reg, units);
                        st_seams_ += seams_along(cd.x, cd.x + cd.sx - 1, cd.z, cd.z + cd.sz - 1, c + cd.h, L, reg, units);
                        st_units_ += units;
                    }
                    place(cd.x, cd.z, c, cd.sx, cd.sz, cd.h, mat, L, reg, false);
                    ++cnt_[(size_t)cd.shape];
                    ++hcnt_[cd.h - 1];
                    ++n_;
                }
            }
        }
        if (p_.merge) merge_ones(first, reg);
    }

    /// The wide bricks (2 and 3 wide) first, up to their share of what the
    /// square's course will hold, at hashed spots: a raster fill alone
    /// fragments the course and leaves them short of their share.
    /// Seam codes along a course's unit edges round a square (one cell out):
    /// 0 not seen, 1 seen, 2 a seam (seams_along's edge, kept). The courses
    /// under and over a course do not change while its wide pass runs, and
    /// it asked seams_along the same edges for every spot it tried.
    struct SeamMap {
        static constexpr int N = SQ + 2;
        int x0 = 0, z0 = 0;
        uint8_t ex[N * N], ez[N * N];   ///< edge (x,z)-(x+1,z), (x,z)-(x,z+1)
    };

    void seam_map(SeamMap &m, int bx, int bz, int cb, int L, int64_t reg) const {
        m.x0 = bx - 1;
        m.z0 = bz - 1;
        for (int j = 0; j < SeamMap::N; ++j) {
            for (int i = 0; i < SeamMap::N; ++i) {
                const int x = m.x0 + i, z = m.z0 + j;
                int u = 0;
                const int sx = seams_along_edge(x, z, x + 1, z, cb, L, reg, u);
                m.ex[i + SeamMap::N * j] = (uint8_t)(u ? 1 + sx : 0);
                u = 0;
                const int sz = seams_along_edge(x, z, x, z + 1, cb, L, reg, u);
                m.ez[i + SeamMap::N * j] = (uint8_t)(u ? 1 + sz : 0);
            }
        }
    }

    /// seams_along's one edge.
    int seams_along_edge(int ax, int az, int bx, int bz, int cb, int L, int64_t reg, int &units) const {
        const int i = at(ax, az, cb), j = at(bx, bz, cb);
        if (i < 0 || j < 0) return 0;
        const int A = f_.id[(size_t)i], B = f_.id[(size_t)j];
        if (A < 0 || B < 0) return 0;
        if (!known(A, L, reg) || !known(B, L, reg)) return 0;
        ++units;
        return A != B ? 1 : 0;
    }

    /// seams_along from a map: the same edges, the same counts.
    static int seams_from(const SeamMap &m, int x0, int x1, int z0, int z1, int &units) {
        int n = 0;
        auto add = [&](uint8_t v) { if (v) { ++units; n += v - 1; } };
        const int N = SeamMap::N;
        for (int x = x0; x <= x1; ++x) {
            add(m.ez[(x - m.x0) + N * (z0 - 1 - m.z0)]);
            add(m.ez[(x - m.x0) + N * (z1 - m.z0)]);
        }
        for (int z = z0; z <= z1; ++z) {
            add(m.ex[(x0 - 1 - m.x0) + N * (z - m.z0)]);
            add(m.ex[(x1 - m.x0) + N * (z - m.z0)]);
        }
        return n;
    }

    void wide_pass(int c, int k, int rx, int rz, int L, int64_t reg, int bx, int bz) {
        SeamMap below, above;
        bool maps = false;
        int cells = 0;
        for (int dz = 0; dz < SQ; ++dz) {
            for (int dx = 0; dx < SQ; ++dx) {
                const int i = at(bx + dx, bz + dz, c);
                if (i >= 0 && f_.id[(size_t)i] < 0 && a_.kind[(size_t)i] >= K_MEDIUM) ++cells;
            }
        }
        if (cells == 0) return;
        double mean = 0.0, tot = 0.0;
        for (size_t si = 0; si < p_.shapes.size(); ++si) {
            mean += share_[si] * p_.shapes[si].a * p_.shapes[si].b;
            tot += share_[si];
        }
        if (tot <= 0.0) return;
        const double n_est = (double)cells / (mean / tot);
        std::vector<int> want(p_.shapes.size(), 0);
        for (size_t si = 0; si < p_.shapes.size(); ++si) {
            if (p_.shapes[si].a >= 2) want[si] = (int)std::lround(share_[si] / tot * n_est);
        }
        std::vector<int> order(SQ * SQ);
        for (int q = 0; q < SQ * SQ; ++q) order[(size_t)q] = q;
        // Keys once (the comparator hashed both sides on every compare):
        // the same comparisons, the same order.
        uint32_t okey[SQ * SQ];
        for (int q = 0; q < SQ * SQ; ++q) okey[q] = brick::bond_hash(q, rx * 31 + rz, c ^ seed_);
        std::sort(order.begin(), order.end(), [&](int x, int y) { return okey[x] < okey[y]; });
        // The most wanted wide shape first (a rare big one placed first took
        // the common ones' room), each to its share.
        std::vector<size_t> by_share;
        for (size_t si = 0; si < p_.shapes.size(); ++si) by_share.push_back(si);
        // Shapes of 8 cells and more first, biggest first (each only to its
        // own small share), then the rest by share.
        std::stable_sort(by_share.begin(), by_share.end(), [&](size_t x, size_t y) {
            const int ax = p_.shapes[x].a * p_.shapes[x].b, ay = p_.shapes[y].a * p_.shapes[y].b;
            const bool bx = ax >= 8, byy = ay >= 8;
            if (bx != byy) return bx;
            if (bx) return ax > ay;
            return share_[x] > share_[y];
        });
        for (size_t si : by_share) {
          for (int q : order) {
            if (want[si] <= 0) break;
            const int x = bx + q % SQ, z = bz + q / SQ;
            const int i = at(x, z, c);
            if (i < 0 || f_.id[(size_t)i] >= 0 || a_.kind[(size_t)i] < K_MEDIUM) continue;
            const int kind = a_.kind[(size_t)i], mat = a_.mat[(size_t)i];
            const uint32_t hq = brick::bond_hash(x, z, c + 977);
            {
                const Shape &sh = p_.shapes[si];
                if (kind == K_MEDIUM && sh.a * sh.b > p_.medium_max) continue;
                bool placed = false;
                for (int t = 0; t < 2 && !placed; ++t) {
                    const int orient = ((hq >> 8) + t) & 1;
                    const int sx = orient ? sh.b : sh.a, sz = orient ? sh.a : sh.b;
                    if (!fits(x, x + sx - 1, z, z + sz - 1, c, 1, rx, rz, kind, mat, reg)) continue;
                    if (!maps) {
                        seam_map(below, bx, bz, c - 1, L, reg);
                        seam_map(above, bx, bz, c + 1, L, reg);
                        maps = true;
                    }
                    int units = 0;
                    const int sm = seams_from(below, x, x + sx - 1, z, z + sz - 1, units)
                            + seams_from(above, x, x + sx - 1, z, z + sz - 1, units);
                    if (p_.stagger >= 0.0 && units > 0 && (double)sm / (double)units > p_.wide_seams + p_.stagger) continue;
                    st_seams_ += sm;
                    st_units_ += units;
                    place(x, z, c, sx, sz, 1, mat, L, reg, false);
                    --want[si];
                    ++cnt_[si];
                    ++hcnt_[0];
                    ++n_;
                    placed = true;
                }
            }
          }
        }
        (void)k;
    }

    bool has_shape(int a, int b) const {
        const int lo = std::min(a, b), hi = std::max(a, b);
        for (const Shape &sh : p_.shapes) {
            if (sh.a == lo && sh.b == hi) return true;
        }
        return false;
    }

    /// Each 1x1 the fit had to leave (a gap no bigger shape fitted) joins a
    /// 1-wide, one-course neighbour of the same material in the same region
    /// in line with it, when the result is a listed shape.
    int shape_index(int a, int b) const {
        const int lo = std::min(a, b), hi = std::max(a, b);
        for (size_t si = 0; si < p_.shapes.size(); ++si) {
            if (p_.shapes[si].a == lo && p_.shapes[si].b == hi) return (int)si;
        }
        return -1;
    }

    void merge_ones(size_t first, int64_t reg) {
        for (int round = 0; round < 2; ++round)
        for (size_t bi = first; bi < f_.bricks.size(); ++bi) {
            Brick &b = f_.bricks[bi];
            if (b.dead || b.loose || b.sx != 1 || b.sz != 1 || b.h != 1) continue;
            static const int D[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
            const int start = (int)(brick::bond_hash(b.x, b.z, b.c) & 3U);
            for (int t = 0; t < 4; ++t) {
                const int dx = D[(start + t) & 3][0], dz = D[(start + t) & 3][1];
                const int i = at(b.x + dx, b.z + dz, b.c);
                if (i < 0) continue;
                const int nid = f_.id[(size_t)i];
                if (nid < 0 || nid == (int)bi) continue;
                Brick &n = f_.bricks[(size_t)nid];
                if (n.dead || n.loose || n.h != 1 || n.c != b.c || (!p_.mixed && n.mat != b.mat) || n.region != reg) continue;
                // Round 0 pairs 1x1s; round 1 grows longer bricks, but only a shape under its share.
                if (round == 0 && (n.sx != 1 || n.sz != 1)) continue;
                int nx = n.x, nz = n.z, nsx = n.sx, nsz = n.sz;
                if (dx != 0 && n.sz == 1 && n.z == b.z) {
                    nx = std::min(n.x, b.x);
                    nsx = n.sx + 1;
                } else if (dz != 0 && n.sx == 1 && n.x == b.x) {
                    nz = std::min(n.z, b.z);
                    nsz = n.sz + 1;
                } else {
                    continue;
                }
                const int to = shape_index(nsx, nsz);
                if (to < 0) continue;
                if (round == 1 && cnt_[(size_t)to] + 1 > share_[(size_t)to] * (n_ + 1) + 1) continue;
                const int from = shape_index(n.sx, n.sz);
                if (from >= 0) --cnt_[(size_t)from];
                ++cnt_[(size_t)to];
                n.x = nx; n.z = nz; n.sx = nsx; n.sz = nsz;
                f_.id[(size_t)at(b.x, b.z, b.c)] = nid;
                b.dead = true;
                break;
            }
        }
        if (p_.pair_merge) merge_pairs(first, reg);
    }

    /// Two like bricks side by side (same size, lined up, one course, same
    /// region) joined into the listed shape they make -- 1x2 + 1x2 a 2x2,
    /// 2x2 + 2x2 a 2x4, 1x3 + 1x3 a 2x3 -- where that shape is further under
    /// its share than the pair's is: the fill leaves the narrow shapes over
    /// their share and the square ones under (rough ground has room for a 1x2
    /// where a 2x2 does not fit), and this moves the count back.
    void merge_pairs(size_t first, int64_t reg) {
        auto deficit = [&](int s) { return share_[(size_t)s] * (double)n_ - (double)cnt_[(size_t)s]; };
        for (size_t bi = first; bi < f_.bricks.size(); ++bi) {
            Brick &b = f_.bricks[bi];
            if (b.dead || b.loose || b.h != 1 || b.region != reg) continue;
            const int from = shape_index(b.sx, b.sz);
            if (from < 0) continue;
            static const int D[4][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } };
            const int start = (int)(brick::bond_hash(b.x, b.z, b.c + 31) & 3U);
            for (int t = 0; t < 4; ++t) {
                const int dx = D[(start + t) & 3][0], dz = D[(start + t) & 3][1];
                // The neighbour's corner, if it is a like brick lined up with b.
                const int qx = dx > 0 ? b.x + b.sx : (dx < 0 ? b.x - 1 : b.x);
                const int qz = dz > 0 ? b.z + b.sz : (dz < 0 ? b.z - 1 : b.z);
                const int i = at(qx, qz, b.c);
                if (i < 0) continue;
                const int nid = f_.id[(size_t)i];
                if (nid < 0 || nid == (int)bi) continue;
                Brick &n = f_.bricks[(size_t)nid];
                if (n.dead || n.loose || n.h != 1 || n.c != b.c || n.region != reg || n.sx != b.sx || n.sz != b.sz
                        || (!p_.mixed && n.mat != b.mat)) continue;
                if (dx != 0 && n.z != b.z) continue;
                if (dz != 0 && n.x != b.x) continue;
                const int nsx = dx != 0 ? b.sx * 2 : b.sx, nsz = dz != 0 ? b.sz * 2 : b.sz;
                const int to = shape_index(nsx, nsz);
                if (to < 0) continue;
                if (deficit(to) <= 0.0 || deficit(to) <= deficit(from)) continue;
                cnt_[(size_t)from] -= 2;
                ++cnt_[(size_t)to];
                const int mx = std::min(b.x, n.x), mz = std::min(b.z, n.z);
                b.x = mx; b.z = mz; b.sx = nsx; b.sz = nsz;
                for (int zz = n.z; zz < n.z + n.sz; ++zz)
                    for (int xx = n.x; xx < n.x + n.sx; ++xx) f_.id[(size_t)at(xx, zz, n.c)] = (int)bi;
                n.dead = true;
                break;
            }
        }
    }

    bool fits(int x0, int x1, int z0, int z1, int c, int h, int rx, int rz, int kind, int mat, int64_t reg) const {
        const int cc = c + h - 1;
        if (!square_has(cc, rx, rz, x0, x1, z0, z1)) return false;
        if (fdiv(x0, TILE) != fdiv(x1, TILE) && !gate(fdiv(x1, TILE), 0, cc, reg)) return false;
        if (fdiv(z0, TILE) != fdiv(z1, TILE) && !gate(fdiv(z1, TILE), 1, cc, reg)) return false;
        if (h > 1 && fdiv(c, SECTION_COURSES) != fdiv(cc, SECTION_COURSES) && !gate(fdiv(cc, SECTION_COURSES), 2, 0, reg)) return false;
        if (fr_on_ && rx == fr_rx_ && rz == fr_rz_ && fdiv(cc, 3) == fr_L_) {
            // Inside the square (checked above): a row's bits.
            const int o = course_off(cc, p_.offset);
            const int u0 = x0 - rx * SQ - o, v0 = z0 - rz * SQ - o;
            const uint16_t want = (uint16_t)(((1u << (x1 - x0 + 1)) - 1u) << u0);
            const uint16_t *rows = free_[cc - fr_L_ * 3];
            for (int v = v0; v <= v0 + (z1 - z0); ++v) {
                if ((rows[v] & want) != want) return false;
            }
            return true;
        }
        for (int zz = z0; zz <= z1; ++zz) {
            for (int xx = x0; xx <= x1; ++xx) {
                const int i = at(xx, zz, cc);
                if (i < 0 || f_.id[(size_t)i] >= 0) return false;
                if (p_.mixed ? a_.kind[(size_t)i] < K_MEDIUM : (a_.kind[(size_t)i] != kind || a_.mat[(size_t)i] != mat)) return false;
            }
        }
        return true;
    }
};

// --- metrics ----------------------------------------------------------------

std::string fkey(int a, int b) { return std::to_string(std::min(a, b)) + "x" + std::to_string(std::max(a, b)); }

struct Sums {
    std::unordered_map<std::string, int64_t> share, share_vis;
    int64_t bricks = 0, cells = 0, vis = 0, loose = 0, ones = 0, ore_ones = 0, seams = 0;
    int64_t heights[3] = { 0, 0, 0 };
    int64_t oriented = 0, along_x = 0;
    int64_t joints = 0, stacked = 0, long_stacked = 0;
    int64_t cross_tile = 0, in4 = 0, cross_sec = 0, chunks = 0;
    double ms = 0.0;
    int64_t regions = 0, tiles = 0;
};

void measure(const Area &a, const Fit &f, Sums &s) {
    auto id_at = [&](int lx, int lz, int lc) -> int {
        if (!a.in(lx, lz, lc)) return -1;
        const int i = f.id[(size_t)a.idx(lx, lz, lc)];
        return (i >= 0 && !f.bricks[(size_t)i].loose) ? i : -1;
    };
    for (size_t bi = 0; bi < f.bricks.size(); ++bi) {
        const Brick &b = f.bricks[bi];
        const int lx = b.x - a.ox, lz = b.z - a.oz;
        if (lx < MID_LO || lx >= MID_HI || lz < MID_LO || lz >= MID_HI) continue;
        if (b.dead) continue;
        if (b.loose) { ++s.loose; continue; }
        ++s.bricks;
        const int cells = b.sx * b.sz * b.h;
        s.cells += cells;
        if (b.sx == 1 && b.sz == 1 && b.h == 1) {
            ++s.ones;
            if (b.mat >= brick::MAT_COAL && b.mat <= brick::MAT_DIAMOND) ++s.ore_ones;
        }
        ++s.heights[b.h - 1];
        if (b.sx != b.sz) { ++s.oriented; if (b.sx > b.sz) ++s.along_x; }
        const std::string k = fkey(b.sx, b.sz);
        ++s.share[k];
        bool vis = false;
        for (int c = b.c; c < b.c + b.h && !vis; ++c) {
            for (int z = b.z - 1; z <= b.z + b.sz && !vis; ++z) {
                for (int x = b.x - 1; x <= b.x + b.sx && !vis; ++x) {
                    for (int dc = -1; dc <= 1 && !vis; ++dc) {
                        const int qx = x - a.ox, qz = z - a.oz, qc = c + dc - a.c0;
                        if (a.in(qx, qz, qc) && a.kind[(size_t)a.idx(qx, qz, qc)] == K_AIR) vis = true;
                    }
                }
            }
        }
        if (vis) { ++s.vis; ++s.share_vis[k]; }
        const int tx = fdiv(b.x + b.sx - 1, TILE) - fdiv(b.x, TILE) + 1;
        const int tz = fdiv(b.z + b.sz - 1, TILE) - fdiv(b.z, TILE) + 1;
        const int sc = fdiv(b.c + b.h - 1, SECTION_COURSES) - fdiv(b.c, SECTION_COURSES) + 1;
        if (tx * tz > 1) ++s.cross_tile;
        if (tx * tz >= 4) ++s.in4;
        if (sc > 1) ++s.cross_sec;
        s.chunks += tx * tz * sc;
    }
    for (int lc = 0; lc < a.nc; ++lc) {
        for (int lz = MID_LO; lz < MID_HI; ++lz) {
            for (int lx = MID_LO; lx < MID_HI; ++lx) {
                const int A = id_at(lx, lz, lc);
                if (A < 0) continue;
                const int U = id_at(lx, lz, lc + 1);
                if (U >= 0 && U != A) ++s.joints;
                for (int axis = 0; axis < 2; ++axis) {
                    const int nx = lx + (axis == 0), nz = lz + (axis == 1);
                    auto seam = [&](int c) {
                        const int p = id_at(lx, lz, c), q = id_at(nx, nz, c);
                        return p >= 0 && q >= 0 && p != q;
                    };
                    if (seam(lc) && id_at(lx, lz, lc + 1) >= 0 && id_at(nx, nz, lc + 1) >= 0) ++s.seams;
                    if (!seam(lc) || !seam(lc + 1)) continue;
                    ++s.stacked;
                    if (seam(lc + 2)) ++s.long_stacked;
                }
            }
        }
    }
    s.ms += f.ms;
    s.regions += f.regions;
    s.tiles += a.tiles * a.tiles;
}

// --- pictures -----------------------------------------------------------------

void mat_rgb(int m, int &r, int &g, int &b) {
    static const int T[][3] = {
        { 0, 0, 0 }, { 80, 150, 60 }, { 125, 88, 58 }, { 220, 200, 140 }, { 135, 135, 140 }, { 82, 82, 92 },
        { 60, 60, 60 }, { 238, 240, 245 }, { 150, 142, 136 }, { 212, 190, 130 }, { 200, 112, 62 },
        { 205, 120, 60 }, { 220, 200, 170 }, { 170, 70, 50 }, { 160, 160, 175 }, { 40, 40, 40 },
        { 55, 55, 58 }, { 190, 160, 140 }, { 200, 120, 80 }, { 232, 200, 64 }, { 180, 40, 40 },
        { 40, 70, 170 }, { 90, 210, 210 }, { 100, 70, 40 }, { 150, 150, 70 }, { 60, 170, 60 },
        { 90, 140, 110 }, { 50, 110, 50 }, { 160, 112, 96 }, { 205, 205, 205 }, { 170, 210, 240 },
        { 30, 20, 40 }, { 150, 100, 60 }, { 60, 130, 50 },
    };
    const int n = (int)(sizeof(T) / sizeof(T[0]));
    const int k = (m >= 0 && m < n) ? m : 4;
    r = T[k][0]; g = T[k][1]; b = T[k][2];
}

/// A face-on view of a wall: the vertical slice at local z, x across the
/// middle tiles, courses up. 8 x 10 px a cell (a brick is 9.6 mm tall to an
/// 8 mm stud). Air black, surface pieces grey; each brick its material
/// shaded by a hash, outlined where the next cell is another brick.
PackedByteArray slice_picture(const Area &a, const Fit &f, int lz, int &w, int &h) {
    const int CW = 8, CH = 10;
    const int nx = MID_HI - MID_LO;
    w = nx * CW;
    h = a.nc * CH;
    PackedByteArray px;
    px.resize((int64_t)w * h * 3);
    uint8_t *d = px.ptrw();
    auto cell_id = [&](int lx, int lc) -> int {
        if (lx < 0 || lx >= a.w || lc < 0 || lc >= a.nc) return -2;
        return f.id[(size_t)a.idx(lx, lz, lc)];
    };
    for (int lc = 0; lc < a.nc; ++lc) {
        for (int i = 0; i < nx; ++i) {
            const int lx = MID_LO + i;
            const int idx = a.idx(lx, lz, lc);
            const int k = a.kind[(size_t)idx];
            const int id = f.id[(size_t)idx];
            int r = 14, g = 14, b = 20;
            if (k == K_PARTIAL) { r = g = b = 95; }
            if (id >= 0) {
                mat_rgb(a.mat[(size_t)idx], r, g, b);
                const double t = 0.82 + 0.3 * hash01(id, 7, 11, 3);
                r = std::min(255, (int)(r * t)); g = std::min(255, (int)(g * t)); b = std::min(255, (int)(b * t));
            }
            const bool left = id >= 0 && cell_id(lx - 1, lc) != id;
            const bool right = id >= 0 && cell_id(lx + 1, lc) != id;
            const bool below = id >= 0 && cell_id(lx, lc - 1) != id;
            const bool above = id >= 0 && cell_id(lx, lc + 1) != id;
            for (int py = 0; py < CH; ++py) {
                for (int pxx = 0; pxx < CW; ++pxx) {
                    const bool edge = (left && pxx == 0) || (right && pxx == CW - 1) || (above && py == 0)
                            || (below && py == CH - 1);
                    const int X = i * CW + pxx, Y = (a.nc - 1 - lc) * CH + py;
                    uint8_t *o = d + ((size_t)Y * w + X) * 3;
                    o[0] = (uint8_t)(edge ? r / 4 : r);
                    o[1] = (uint8_t)(edge ? g / 4 : g);
                    o[2] = (uint8_t)(edge ? b / 4 : b);
                }
            }
        }
    }
    return px;
}

/// The local z (in the middle tiles) whose slice shows the most wall: bond
/// cells next to air.
int best_slice(const Area &a) {
    int best = (MID_LO + MID_HI) / 2, most = -1;
    for (int lz = MID_LO; lz < MID_HI; ++lz) {
        int n = 0;
        for (int lc = 1; lc + 1 < a.nc; ++lc) {
            for (int lx = MID_LO; lx < MID_HI; ++lx) {
                if (a.kind[(size_t)a.idx(lx, lz, lc)] < K_MEDIUM) continue;
                if (a.kind[(size_t)a.idx(lx, lz + 1, lc)] == K_AIR || a.kind[(size_t)a.idx(lx, lz - 1, lc)] == K_AIR) ++n;
            }
        }
        if (n > most) { most = n; best = lz; }
    }
    return best;
}

void parse_mix(const Dictionary &shapes, std::vector<std::pair<std::pair<int, int>, double>> &out) {
    const Array keys = shapes.keys();
    for (int i = 0; i < keys.size(); ++i) {
        const String k = keys[i];
        const PackedStringArray ab = k.split("x");
        if (ab.size() != 2) continue;
        const int a = std::min(ab[0].to_int(), ab[1].to_int()), b = std::max(ab[0].to_int(), ab[1].to_int());
        out.push_back({ { a, b }, (double)shapes[k] });
    }
}

FitParams parse(const Dictionary &d) {
    FitParams p;
    p.name = String(d.get("name", "")).utf8().get_data();
    p.bond = String(d.get("mode", "quota")) == "bond";
    p.stagger = (double)d.get("stagger", -1.0);
    p.cave_stagger = (double)d.get("cave_stagger", -2.0);
    p.cave_reach = (int)d.get("cave_reach", 2);
    p.mixed = (bool)d.get("mixed", true);
    p.cross = (double)d.get("cross", 1.0);
    p.float_cells = (int)d.get("float_cells", 500);
    p.fit_top = (bool)d.get("fit_top", false);
    p.medium_max = (int)d.get("medium_max", 8);
    p.seed = (int)d.get("seed", 1);
    p.offset = (int)d.get("offset", 7);
    p.merge = (bool)d.get("merge", true);
    p.pair_merge = (bool)d.get("pair_merge", true);
    p.wide_first = (bool)d.get("wide_first", true);
    p.tries = (int)d.get("tries", 1);
    p.try_seams = (double)d.get("try_seams", 1.0);
    const double aim = (double)d.get("aim", 0.0);
    // Every band's mix; the shapes are the union, 1x1 always among them.
    struct Raw {
        double below;
        std::vector<std::pair<std::pair<int, int>, double>> mix;
        double h[3];
    };
    std::vector<Raw> raw;
    // "heights": [one, two, three courses], or the settings' "tall2"/"tall3".
    auto read_heights = [](const Dictionary &dd, double *h) {
        const Array hs = dd.get("heights", Array());
        if (!hs.is_empty()) {
            for (int i = 0; i < 3; ++i) h[i] = i < hs.size() ? (double)hs[i] : 0.0;
            return;
        }
        if (dd.has("tall2") || dd.has("tall3")) {
            h[1] = (double)dd.get("tall2", 0.0);
            h[2] = (double)dd.get("tall3", 0.0);
            h[0] = std::max(0.0, 1.0 - h[1] - h[2]);
        }
    };
    Raw top{ 0.0, {}, { 1.0, 0.0, 0.0 } };
    parse_mix(d.get("shapes", Dictionary()), top.mix);
    read_heights(d, top.h);
    raw.push_back(top);
    const Array bands = d.get("bands", Array());
    for (int i = 0; i < bands.size(); ++i) {
        const Dictionary bd = bands[i];
        Raw r{ (double)bd.get("below_m", 0.0), {}, { top.h[0], top.h[1], top.h[2] } };
        parse_mix(bd.get("shapes", Dictionary()), r.mix);
        if (r.mix.empty()) r.mix = top.mix;
        read_heights(bd, r.h);
        raw.push_back(r);
    }
    std::sort(raw.begin() + 1, raw.end(), [](const Raw &x, const Raw &y) { return x.below < y.below; });
    for (const Raw &r : raw)
        for (const auto &e : r.mix) {
            bool have = false;
            for (const Shape &sh : p.shapes) have = have || (sh.a == e.first.first && sh.b == e.first.second);
            if (!have) p.shapes.push_back(Shape{ e.first.first, e.first.second, 0.0 });
        }
    bool one = false;
    for (const Shape &sh : p.shapes) one = one || (sh.a == 1 && sh.b == 1);
    if (!one) p.shapes.push_back(Shape{ 1, 1, 0.0 });
    // Biggest first: the wide pass goes in this order, ties to the earlier.
    std::sort(p.shapes.begin(), p.shapes.end(), [](const Shape &x, const Shape &y) { return x.a * x.b > y.a * y.b; });
    for (const Raw &r : raw) {
        Band b;
        b.below_m = r.below;
        for (int i = 0; i < 3; ++i) b.heights[i] = r.h[i];
        b.share.assign(p.shapes.size(), 0.0);
        for (const auto &e : r.mix)
            for (size_t si = 0; si < p.shapes.size(); ++si)
                if (p.shapes[si].a == e.first.first && p.shapes[si].b == e.first.second)
                    // Aim high on the wide shapes, in proportion: the
                    // ground's gaps leave them short of what is asked.
                    b.share[si] = e.second * (p.shapes[si].a >= 2 ? 1.0 + aim : 1.0);
        p.bands.push_back(b);
    }
    for (size_t si = 0; si < p.shapes.size(); ++si) p.shapes[si].share = p.bands[0].share[si];
    return p;
}

/// SHARES CALIBRATED (the user, 2026-11-26: closer to what is set; "if that
/// is too expensive during generation, pivot"). By count, rough ground has
/// room for a 1x2 where a 2x2 does not fit, so the fill lands narrow shapes
/// over their share and square ones under whatever the fill does locally.
/// So the shares are scaled once, when a world is set up: a fixed sample of
/// its ground (5 x 5 tiles near the origin, the first with enough bricks)
/// fitted, each shape's share times (target / got)^0.8, three times. A pure
/// function of the world and the settings: the same bricks every session.
/// Returns the ms it took (0: not asked, or no generator).
double calibrate(FitParams &p, const Dictionary &d, Dictionary *report = nullptr) {
    if (!(bool)d.get("calibrate", false)) return 0.0;
    const uint64_t t0 = godot::Time::get_singleton()->get_ticks_usec();
    std::vector<std::pair<std::pair<int, int>, double>> mix;
    parse_mix(d.get("shapes", Dictionary()), mix);
    std::vector<double> target(p.shapes.size(), 0.0);
    double total = 0.0;
    for (const auto &e : mix) total += e.second;
    for (const auto &e : mix)
        for (size_t si = 0; si < p.shapes.size(); ++si)
            if (p.shapes[si].a == e.first.first && p.shapes[si].b == e.first.second)
                target[si] = total > 0.0 ? e.second / total : 0.0;
    Area a;
    bool found = false;
    for (int k = 0; k < 6 && !found; ++k) {
        if (!sample_area(-2 + 8 * k, -2, a)) return 0.0;
        int64_t full = 0;
        for (int lc = 0; lc < a.nc; ++lc)
            for (int lz = MID_LO; lz < MID_HI; ++lz)
                for (int lx = MID_LO; lx < MID_HI; ++lx)
                    full += a.kind[(size_t)a.idx(lx, lz, lc)] >= K_MEDIUM;
        found = full > 20000;
    }
    if (!found) return 0.0;
    Array steps;
    for (int it = 0; it < 3; ++it) {
        Fit f;
        Fitter(a, p, f).run();
        Sums sm;
        measure(a, f, sm);
        if (sm.bricks <= 0) break;
        double err = 0.0;
        for (size_t si = 0; si < p.shapes.size(); ++si) {
            if (target[si] <= 0.0) continue;
            auto g = sm.share.find(fkey(p.shapes[si].a, p.shapes[si].b));
            const double got = g == sm.share.end() ? 0.0 : (double)g->second / (double)sm.bricks;
            err += std::fabs(got - target[si]);
            const double step = std::min(2.0, std::max(0.5, std::pow(target[si] / std::max(got, 0.005), 0.8)));
            for (Band &b : p.bands) b.share[si] *= step;
            p.shapes[si].share *= step;
        }
        steps.append(err);
    }
    const double ms = (double)(godot::Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    if (report) {
        (*report)["calibration_ms"] = ms;
        (*report)["calibration_error"] = steps;   // sum of |got - target| before each step
    }
    return ms;
}

} // namespace

namespace {
/// The world's fill (TerrainFit.configure), what the game's bricks will use.
/// Made on first use: a Godot Variant built when the library loads (before
/// Godot's interface is there) fails the DLL's initialisation.
struct World {
    /// Swapped whole by configure (atomic_load / atomic_store): a worker
    /// fitting keeps the one it started with.
    std::shared_ptr<const FitParams> params;
    Dictionary settings;
    Dictionary calibration;
    /// The game's bricks from the fit (TerrainFit.set_enabled); off, the
    /// old pattern (terrain_bond.h). The lookup answers either way.
    std::atomic<bool> enabled{ false };
};
std::unique_ptr<World> g_world;

std::shared_ptr<const FitParams> world_params() {
    return g_world ? std::atomic_load(&g_world->params) : nullptr;
}
} // namespace

void TerrainFit::configure(const Dictionary &settings) {
    if (!g_world) g_world = std::make_unique<World>();
    g_world->settings = settings.duplicate(true);
    auto p = std::make_shared<FitParams>(parse(settings));
    Dictionary rep;
    calibrate(*p, settings, &rep);
    g_world->calibration = rep;
    std::atomic_store(&g_world->params, std::shared_ptr<const FitParams>(p));
    brick::fitted_clear();
}

void TerrainFit::set_enabled(bool on) {
    if (!g_world) g_world = std::make_unique<World>();
    if (g_world->enabled.exchange(on) != on) {
        brick::bump_field_version();   // every tile drawn again, with the other bricks
    }
}

bool TerrainFit::get_enabled() { return brick::fit_enabled(); }

Dictionary TerrainFit::get_calibration() {
    return g_world ? g_world->calibration.duplicate(true) : Dictionary();
}

Dictionary TerrainFit::get_configured() {
    return g_world ? g_world->settings.duplicate(true) : Dictionary();
}

// --- the lookup (Docs/TerrainRegions.md 12) -----------------------------------
//
// A cell's brick is in exactly one region: the square of its course holding
// it, in its layer. Regions are fitted on a miss and kept (least recently
// used out): an even layer's region from its own cells, an odd layer's with
// the even regions round it (fitted too, or laid in from the cache). Each
// region's whole reach is in the area it is fitted in, so a region is the
// same whoever asks first: the batch fit's, in any order, from any thread.
// Any depth: the cells come from the generator (surface tiles and the deep
// tier's sections alike).

namespace {
constexpr size_t REGIONS_MAX = 32768;   ///< ~12 MB at ~380 B a region
constexpr int LAYER_BLOCK = 8;          ///< a miss fits this many layers of the tile

/// A region's bricks, 4 bytes each, from the region's corner (rx * SQ,
/// rz * SQ, L * 3): dx 5 bits, dz 5, dc 2, sx-1 3, sz-1 3, h-1 2, material 8.
struct RegionBricks {
    std::vector<uint32_t> bricks;
};

uint32_t pack_brick(const Brick &b, int rx, int rz, int L) {
    return (uint32_t)(b.x - rx * SQ) | ((uint32_t)(b.z - rz * SQ) << 5) | ((uint32_t)(b.c - L * 3) << 10)
            | ((uint32_t)(b.sx - 1) << 12) | ((uint32_t)(b.sz - 1) << 15) | ((uint32_t)(b.h - 1) << 18)
            | ((uint32_t)(b.mat & 0xFF) << 20);
}

brick::FitBrick unpack_brick(uint32_t v, int rx, int rz, int L) {
    brick::FitBrick b;
    b.x = rx * SQ + (int)(v & 31U);
    b.z = rz * SQ + (int)((v >> 5) & 31U);
    b.c = L * 3 + (int)((v >> 10) & 3U);
    b.sx = 1 + (int)((v >> 12) & 7U);
    b.sz = 1 + (int)((v >> 15) & 7U);
    b.h = 1 + (int)((v >> 18) & 3U);
    b.mat = (int)((v >> 20) & 0xFFU);
    return b;
}

struct RegionCache {
    std::mutex lock;
    struct Entry { uint64_t used; std::shared_ptr<const RegionBricks> r; };
    std::unordered_map<int64_t, Entry> regions;
    uint64_t clock = 0;
    uint64_t gen = 1;        ///< bumped by configure / a new field: views drop what they hold
    uint32_t field = 0;
    int64_t fitted = 0, jobs = 0, sampled_cells = 0;
    double fit_ms = 0.0, sample_ms = 0.0;
};
RegionCache *g_regions = nullptr;

RegionCache &regions() {
    static std::once_flag once;
    std::call_once(once, [] { g_regions = new RegionCache(); });
    return *g_regions;
}

/// The cache, emptied if the world changed under it. Lock held.
void check_field(RegionCache &rc) {
    const uint32_t f = brick::field_serial();
    if (rc.field != f) {
        rc.regions.clear();
        rc.field = f;
        ++rc.gen;
    }
}

void keep(RegionCache &rc, int64_t k, std::shared_ptr<const RegionBricks> r) {
    if (rc.regions.size() >= REGIONS_MAX && rc.regions.find(k) == rc.regions.end()) {
        std::vector<uint64_t> used;
        used.reserve(rc.regions.size());
        for (const auto &e : rc.regions) used.push_back(e.second.used);
        const size_t q = used.size() / 4;
        std::nth_element(used.begin(), used.begin() + q, used.end());
        const uint64_t cut = used[q];
        for (auto it = rc.regions.begin(); it != rc.regions.end();) {
            it = it->second.used <= cut ? rc.regions.erase(it) : std::next(it);
        }
    }
    rc.regions[k] = RegionCache::Entry{ ++rc.clock, std::move(r) };
}

/// The x (or z) range of a region's cells over its layer's three courses.
inline int span_lo(int r) { return r * SQ; }
inline int span_hi(int r, int off) { return r * SQ + SQ + off; }   // exclusive

using RKey = std::array<int, 3>;

/// The regions `asked` fitted and kept, with the even regions an odd one
/// reads. Fits outside the lock; two threads on the same miss both fit and
/// agree, the second's copy dropped.
void ensure_group(const std::vector<RKey> &asked, const FitParams &p);

/// Split by layer: each band of GROUP_LAYERS layers is a job of its own, its
/// box only as tall as its band (a tile asks for its surface and its caves
/// far under it, and one box over both sampled all the rock between). A
/// band's even regions are kept before the next band lays them in.
constexpr int GROUP_LAYERS = 4;
void ensure_regions(const std::vector<RKey> &asked_in, const FitParams &p) {
    std::vector<RKey> asked = asked_in;
    std::sort(asked.begin(), asked.end(), [](const RKey &a, const RKey &b) { return a[2] < b[2]; });
    size_t i = 0;
    while (i < asked.size()) {
        const int band = fdiv(asked[i][2], GROUP_LAYERS);
        size_t j = i;
        std::vector<RKey> g;
        while (j < asked.size() && fdiv(asked[j][2], GROUP_LAYERS) == band) g.push_back(asked[j++]);
        ensure_group(g, p);
        i = j;
    }
}

void ensure_group(const std::vector<RKey> &asked, const FitParams &p) {
    RegionCache &rc = regions();
    const int off = p.offset;
    std::vector<RKey> fit;
    std::vector<std::pair<RKey, std::shared_ptr<const RegionBricks>>> lay;
    std::unordered_map<int64_t, char> seen;
    {
        std::lock_guard<std::mutex> lk(rc.lock);
        check_field(rc);
        auto want = [&](int rx, int rz, int L) {
            const int64_t k = region_key(rx, rz, L);
            if (seen.count(k)) return;
            seen[k] = 1;
            auto it = rc.regions.find(k);
            if (it != rc.regions.end()) {
                // Kept: an even one is laid in (an odd region may read it);
                // seen once, whichever list met it first.
                if ((L & 1) == 0) lay.push_back({ RKey{ rx, rz, L }, it->second.r });
                return;
            }
            fit.push_back(RKey{ rx, rz, L });
        };
        for (const RKey &r : asked) want(r[0], r[1], r[2]);
        if (fit.empty()) return;
        // An odd region reads the even layers' bricks along its outline,
        // one cell out: those regions fitted with it, or laid in.
        const std::vector<RKey> first = fit;
        for (const RKey &r : first) {
            if ((r[2] & 1) == 0) continue;
            const int ax0 = span_lo(r[0]) - 1, ax1 = span_hi(r[0], off) + 1;
            const int az0 = span_lo(r[1]) - 1, az1 = span_hi(r[1], off) + 1;
            for (int Le = r[2] - 1; Le <= r[2] + 1; Le += 2) {
                for (int rz = fdiv(az0 - SQ - off, SQ); rz <= fdiv(az1 - 1, SQ); ++rz) {
                    for (int rx = fdiv(ax0 - SQ - off, SQ); rx <= fdiv(ax1 - 1, SQ); ++rx) {
                        if (span_hi(rx, off) <= ax0 || span_lo(rx) >= ax1 || span_hi(rz, off) <= az0 || span_lo(rz) >= az1) continue;
                        want(rx, rz, Le);
                    }
                }
            }
        }
    }
    // The area: each fitted region's cells, 3 round (cave reach 2, the
    // outline's cell), courses 3 under to 3 over its layer.
    int bx0 = INT_MAX, bx1 = INT_MIN, bz0 = INT_MAX, bz1 = INT_MIN, bc0 = INT_MAX, bc1 = INT_MIN;
    for (const RKey &r : fit) {
        bx0 = std::min(bx0, span_lo(r[0]) - 3);
        bx1 = std::max(bx1, span_hi(r[0], off) + 3);
        bz0 = std::min(bz0, span_lo(r[1]) - 3);
        bz1 = std::max(bz1, span_hi(r[1], off) + 3);
        bc0 = std::min(bc0, r[2] * 3 - 3);
        bc1 = std::max(bc1, r[2] * 3 + 6);
    }
    const uint64_t t0 = godot::Time::get_singleton()->get_ticks_usec();
    Area a;
    if (!sample_box(bx0, bz0, bx1 - bx0, bz1 - bz0, bc0, bc1 - bc0, a)) return;
    const uint64_t t1 = godot::Time::get_singleton()->get_ticks_usec();
    Fit f;
    Fitter ft(a, p, f);
    for (const auto &e : lay) {
        const int64_t k = region_key(e.first[0], e.first[1], e.first[2]);
        for (uint32_t v : e.second->bricks) {
            const brick::FitBrick b = unpack_brick(v, e.first[0], e.first[1], e.first[2]);
            ft.lay(k, e.first[2], b.x, b.z, b.c, b.sx, b.sz, b.h, b.mat);
        }
        ft.lay_loose(k, e.first[0], e.first[1], e.first[2]);
    }
    ft.fit_regions(fit);
    std::unordered_map<int64_t, std::shared_ptr<RegionBricks>> out;
    for (const RKey &r : fit) out[region_key(r[0], r[1], r[2])] = std::make_shared<RegionBricks>();
    for (const Brick &b : f.bricks) {
        if (b.dead || b.loose) continue;
        auto it = out.find(b.region);
        if (it == out.end() || b.layer != fdiv(b.c, 3)) continue;
        const int rx = (int)(((b.region >> 40) & 0xFFFFF) << 12) >> 12;
        const int rz = (int)(((b.region >> 20) & 0xFFFFF) << 12) >> 12;
        it->second->bricks.push_back(pack_brick(b, rx, rz, b.layer));
    }
    const uint64_t t2 = godot::Time::get_singleton()->get_ticks_usec();
    std::lock_guard<std::mutex> lk(rc.lock);
    ++rc.jobs;
    rc.fitted += (int64_t)fit.size();
    rc.sampled_cells += (int64_t)a.kind.size();
    rc.sample_ms += (double)(t1 - t0) / 1000.0;
    rc.fit_ms += (double)(t2 - t1) / 1000.0;
    if (rc.field != a.field) return;   // the world changed while fitting
    for (auto &e : out) {
        e.second->bricks.shrink_to_fit();
        if (rc.regions.find(e.first) == rc.regions.end()) keep(rc, e.first, e.second);
    }
}

/// Every region of layers [L0, L1] with a cell in tile (tx, tz).
void ensure(int tx, int tz, int L0, int L1, const FitParams &p) {
    const int off = p.offset;
    const int x0 = tx * TILE, x1 = x0 + TILE, z0 = tz * TILE, z1 = z0 + TILE;
    std::vector<RKey> asked;
    for (int L = L0; L <= L1; ++L) {
        for (int rz = fdiv(z0 - SQ - off, SQ); rz <= fdiv(z1 - 1, SQ); ++rz) {
            for (int rx = fdiv(x0 - SQ - off, SQ); rx <= fdiv(x1 - 1, SQ); ++rx) {
                if (span_hi(rx, off) <= x0 || span_lo(rx) >= x1 || span_hi(rz, off) <= z0 || span_lo(rz) >= z1) continue;
                asked.push_back(RKey{ rx, rz, L });
            }
        }
    }
    ensure_regions(asked, p);
}

std::shared_ptr<const RegionBricks> region_of(int rx, int rz, int L, uint64_t &gen) {
    RegionCache &rc = regions();
    std::lock_guard<std::mutex> lk(rc.lock);
    check_field(rc);
    gen = rc.gen;
    auto it = rc.regions.find(region_key(rx, rz, L));
    if (it == rc.regions.end()) return nullptr;
    it->second.used = ++rc.clock;
    return it->second.r;
}
} // namespace

namespace brick {
struct FitView::Open {
    int64_t key = 0;
    int rx = 0, rz = 0, L = 0;
    std::shared_ptr<const RegionBricks> r;
    uint16_t ids[3 * SQ * SQ];
};
} // namespace brick

brick::FitView::FitView() = default;
brick::FitView::~FitView() = default;

void brick::FitView::clear() {
    open_.clear();
    last_ = nullptr;
}

void brick::FitView::prefetch(const std::vector<std::array<int, 3>> &cells) {
    const std::shared_ptr<const FitParams> P = world_params();
    if (!P || cells.empty()) return;
    std::vector<RKey> asked;
    std::unordered_map<int64_t, char> seen;
    {
        RegionCache &rc = regions();
        std::lock_guard<std::mutex> lk(rc.lock);
        check_field(rc);
        for (const auto &c : cells) {
            const int L = fdiv(c[1], 3);
            const int o = course_off(c[1], P->offset);
            const int rx = fdiv(c[0] - o, SQ), rz = fdiv(c[2] - o, SQ);
            const int64_t k = region_key(rx, rz, L);
            if (seen.count(k) || rc.regions.count(k)) continue;
            seen[k] = 1;
            asked.push_back(RKey{ rx, rz, L });
        }
    }
    if (!asked.empty()) ensure_regions(asked, *P);
}

bool brick::FitView::at(int x, int course, int z, FitBrick &out) {
    const std::shared_ptr<const FitParams> P = world_params();
    if (!P) return false;
    const int L = fdiv(course, 3), k = course - L * 3;
    const int o = course_off(course, P->offset);
    const int rx = fdiv(x - o, SQ), rz = fdiv(z - o, SQ);
    const int64_t key = region_key(rx, rz, L);
    Open *op = (last_ && last_->key == key) ? last_ : nullptr;
    if (!op) {
        auto it = open_.find(key);
        if (it != open_.end()) op = it->second.get();
    }
    if (!op) {
        uint64_t gen = 0;
        std::shared_ptr<const RegionBricks> r = region_of(rx, rz, L, gen);
        if (gen != gen_) {
            clear();
            gen_ = gen;
        }
        if (!r) {
            const int L0 = fdiv(L, LAYER_BLOCK) * LAYER_BLOCK;
            ensure(fdiv(x, TILE), fdiv(z, TILE), L0, L0 + LAYER_BLOCK - 1, *P);
            r = region_of(rx, rz, L, gen);
            if (!r) return false;   // no generator, or the world changed
        }
        if (open_.size() >= 512) clear();
        auto made = std::make_unique<Open>();
        made->key = key;
        made->rx = rx;
        made->rz = rz;
        made->L = L;
        made->r = r;
        std::fill(std::begin(made->ids), std::end(made->ids), (uint16_t)0xFFFF);
        for (size_t i = 0; i < r->bricks.size(); ++i) {
            const FitBrick b = unpack_brick(r->bricks[i], rx, rz, L);
            for (int cc = b.c; cc < b.c + b.h; ++cc) {
                const int oc = course_off(cc, P->offset);
                for (int zz = b.z; zz < b.z + b.sz; ++zz) {
                    for (int xx = b.x; xx < b.x + b.sx; ++xx) {
                        const int u = xx - rx * SQ - oc, v = zz - rz * SQ - oc;
                        made->ids[(cc - L * 3) * SQ * SQ + v * SQ + u] = (uint16_t)i;
                    }
                }
            }
        }
        op = made.get();
        open_[key] = std::move(made);
    }
    last_ = op;
    const int u = x - rx * SQ - o, v = z - rz * SQ - o;
    const uint16_t i = op->ids[k * SQ * SQ + v * SQ + u];
    if (i == 0xFFFF) return false;
    out = unpack_brick(op->r->bricks[i], rx, rz, L);
    return true;
}

bool brick::fitted_brick(int x, int course, int z, FitBrick &out) {
    thread_local FitView view;
    return view.at(x, course, z, out);
}

// --- the top course (Docs/TerrainRegions.md 12.3) ----------------------------

struct brick::TopFitMemo::Square {
    uint16_t ids[SQ * SQ];
    std::vector<brick::FitBrick> bricks;
};
brick::TopFitMemo::TopFitMemo() = default;
brick::TopFitMemo::~TopFitMemo() = default;

bool brick::fit_top(TopFitMemo &memo, int x, int course, int z, uint64_t cls,
        const std::function<int(int, int)> &group, FitBrick &out) {
    const std::shared_ptr<const FitParams> P = world_params();
    if (!P) return false;
    const int o = course_off(course, P->offset);
    const int rx = fdiv(x - o, SQ), rz = fdiv(z - o, SQ), L = fdiv(course, 3);
    uint64_t key = cls * 0x9E3779B97F4A7C15ULL;
    key ^= (uint64_t)brick::bond_hash(rx, rz, course) + 0x7F4A7C15ULL + (key << 6) + (key >> 2);
    auto it = memo.squares.find(key);
    if (it == memo.squares.end()) {
        Area a;
        a.ox = rx * SQ + o;
        a.oz = rz * SQ + o;
        a.w = a.d = SQ;
        a.c0 = course;
        a.nc = 1;
        a.kind.assign(SQ * SQ, K_PARTIAL);
        a.mat.assign(SQ * SQ, 1);
        a.top.assign(SQ * SQ, course + 1);
        for (int v = 0; v < SQ; ++v)
            for (int u = 0; u < SQ; ++u) {
                const int g = group(a.ox + u, a.oz + v);
                a.kind[(size_t)(u + SQ * v)] = g == brick::BOND_STRONG ? K_STRONG
                        : (g == brick::BOND_MEDIUM ? K_MEDIUM : (g == brick::BOND_LOOSE ? K_LOOSE : K_PARTIAL));
            }
        Fit f;
        Fitter ft(a, *P, f);
        ft.fit_regions({ RKey{ rx, rz, L } });
        auto sq = std::make_unique<TopFitMemo::Square>();
        std::fill(std::begin(sq->ids), std::end(sq->ids), (uint16_t)0xFFFF);
        std::unordered_map<int, uint16_t> remap;
        for (int i = 0; i < SQ * SQ; ++i) {
            const int fid = f.id[(size_t)i];
            if (fid < 0) continue;
            auto r = remap.find(fid);
            if (r == remap.end()) {
                const Brick &b = f.bricks[(size_t)fid];
                r = remap.emplace(fid, (uint16_t)sq->bricks.size()).first;
                sq->bricks.push_back(FitBrick{ b.x, b.z, b.c, b.sx, b.sz, b.h, b.mat });
            }
            sq->ids[i] = r->second;
        }
        it = memo.squares.emplace(key, std::move(sq)).first;
    }
    const int u = x - (rx * SQ + o), v = z - (rz * SQ + o);
    const uint16_t i = it->second->ids[u + SQ * v];
    if (i == 0xFFFF) return false;
    out = it->second->bricks[i];
    return true;
}

// Each column's generated top plate and material, a tile at a time, kept
// (the top course is fitted from what was generated: an edit cuts the bricks
// it touches, it does not re-lay its neighbours).
namespace {
struct TopTile {
    int16_t plate[TILE * TILE];
    uint8_t mat[TILE * TILE];
};
struct TopCache {
    std::mutex lock;
    struct Entry { uint64_t used; uint32_t field; std::shared_ptr<const TopTile> t; };
    std::unordered_map<int64_t, Entry> tiles;
    uint64_t clock = 0;
};
TopCache &top_cache() {
    static TopCache *c = new TopCache();
    return *c;
}
} // namespace

bool brick::generated_top(int x, int z, int &plate, int &mat) {
    const int tx = fdiv(x, TILE), tz = fdiv(z, TILE);
    const int64_t k = ((int64_t)tx << 32) ^ (int64_t)(uint32_t)tz;
    const uint32_t f = brick::field_serial();
    TopCache &tc = top_cache();
    std::shared_ptr<const TopTile> t;
    {
        std::lock_guard<std::mutex> lk(tc.lock);
        auto it = tc.tiles.find(k);
        if (it != tc.tiles.end() && it->second.field == f) {
            it->second.used = ++tc.clock;
            t = it->second.t;
        }
    }
    if (!t) {
        std::vector<uint8_t> vox;
        std::vector<int16_t> gtop;
        if (!brick::generated_cells(tx, tz, 0, 1, vox, gtop)) return false;
        int lo = INT_MAX, hi = INT_MIN;
        for (int16_t g : gtop) { lo = std::min(lo, (int)g); hi = std::max(hi, (int)g); }
        if (!brick::generated_cells(tx, tz, lo, hi + 1, vox, gtop)) return false;
        auto made = std::make_shared<TopTile>();
        for (int i = 0; i < TILE * TILE; ++i) {
            made->plate[i] = gtop[(size_t)i];
            const uint8_t m = vox[(size_t)i + (size_t)TILE * TILE * (size_t)(gtop[(size_t)i] - lo)];
            made->mat[i] = m == 255 ? 0 : m;
        }
        t = made;
        std::lock_guard<std::mutex> lk(tc.lock);
        if (tc.tiles.size() >= 512) {
            std::vector<uint64_t> used;
            for (const auto &e : tc.tiles) used.push_back(e.second.used);
            const size_t q = used.size() / 4;
            std::nth_element(used.begin(), used.begin() + q, used.end());
            const uint64_t cut = used[q];
            for (auto it = tc.tiles.begin(); it != tc.tiles.end();)
                it = (it->second.used <= cut || it->second.field != f) ? tc.tiles.erase(it) : std::next(it);
        }
        tc.tiles[k] = TopCache::Entry{ ++tc.clock, f, made };
    }
    const int i = (x - tx * TILE) + TILE * (z - tz * TILE);
    plate = t->plate[i];
    mat = t->mat[i];
    return true;
}

bool brick::fit_top_enabled() {
    const std::shared_ptr<const FitParams> P = world_params();
    return brick::fit_enabled() && P && P->fit_top;
}

int brick::fit_float_cells() {
    const std::shared_ptr<const FitParams> P = world_params();
    return P ? P->float_cells : 500;
}

bool brick::fit_enabled() {
    return g_world != nullptr && g_world->enabled && world_params() != nullptr;
}

void brick::fitted_clear() {
    RegionCache &rc = regions();
    std::lock_guard<std::mutex> lk(rc.lock);
    rc.regions.clear();
    ++rc.gen;
    // lookup_stats counts from here
    rc.fitted = rc.jobs = rc.sampled_cells = 0;
    rc.fit_ms = rc.sample_ms = 0.0;
}

Dictionary TerrainFit::brick_at(int x, int course, int z) {
    brick::FitBrick b;
    Dictionary d;
    if (!brick::fitted_brick(x, course, z, b)) return d;
    d["x"] = b.x; d["z"] = b.z; d["c"] = b.c;
    d["sx"] = b.sx; d["sz"] = b.sz; d["h"] = b.h;
    d["mat"] = b.mat;
    return d;
}

Dictionary TerrainFit::lookup_stats() {
    RegionCache &rc = regions();
    std::lock_guard<std::mutex> lk(rc.lock);
    Dictionary d;
    int64_t bricks = 0, bytes = 0;
    for (const auto &e : rc.regions) {
        bricks += (int64_t)e.second.r->bricks.size();
        // the brick words, the vector and control block, the map's node
        bytes += (int64_t)(e.second.r->bricks.capacity() * 4) + 24 + 32 + 48;
    }
    d["kept"] = (int64_t)rc.regions.size();
    d["fitted"] = rc.fitted;
    d["jobs"] = rc.jobs;
    d["bricks"] = bricks;
    d["bytes"] = bytes;
    d["sample_ms"] = rc.sample_ms;
    d["fit_ms"] = rc.fit_ms;
    d["us_region"] = rc.fitted > 0 ? 1000.0 * (rc.sample_ms + rc.fit_ms) / (double)rc.fitted : 0.0;
    d["sampled_per_region"] = rc.fitted > 0 ? (double)rc.sampled_cells / (double)rc.fitted : 0.0;
    return d;
}

/// The lookup against the batch fit: the 5 x 5 tile area at `tile` fitted
/// whole with the world's settings (the surface band, or with `depth` a band
/// that many courses under its lowest top), then every cell the batch has
/// whole -- 48 studs from its sides (an odd region's even neighbours reach
/// that far), 12 courses from its bottom and top -- asked of fitted_brick,
/// tiles in a shuffled order, from `threads` threads at once, cache cleared
/// first. Sand and gravel are not listed (their own 1x1s).
Dictionary TerrainFit::check_lookup(Vector2i tile, int threads, int depth) {
    Dictionary d;
    const std::shared_ptr<const FitParams> P = world_params();
    if (!P) { d["error"] = "not configured"; return d; }
    Area a;
    if (!sample_area(tile.x, tile.y, a, AREA_TILES, depth)) { d["error"] = "no generator"; return d; }
    Fit f;
    Fitter(a, *P, f).run();
    brick::fitted_clear();
    {
        RegionCache &rc = regions();
        std::lock_guard<std::mutex> lk(rc.lock);
        rc.fitted = rc.jobs = rc.sampled_cells = 0;
        rc.fit_ms = rc.sample_ms = 0.0;
    }
    constexpr int LO = 48, HI = AREA - 48;
    const int c_lo = 12, c_hi = depth > 0 ? a.nc - 12 : a.nc;
    std::vector<int> order;
    for (int k = 0; k < 9; ++k) order.push_back(k);
    std::sort(order.begin(), order.end(), [](int x, int y) { return brick::bond_hash(x, 5, 9) < brick::bond_hash(y, 5, 9); });
    std::atomic<int64_t> checked{ 0 }, wrong{ 0 }, missing{ 0 }, wrong_even{ 0 };
    std::atomic<int> next{ 0 };
    std::mutex ex_lock;
    Array ex;
    const uint64_t t0 = godot::Time::get_singleton()->get_ticks_usec();
    auto work = [&]() {
        brick::FitView view;
        for (;;) {
            const int q = next.fetch_add(1);
            if (q >= 9) return;
            const int k = order[(size_t)q];
            const int bx = TILE + (k % 3) * TILE, bz = TILE + (k / 3) * TILE;
            for (int lc = c_lo; lc < c_hi; ++lc) {
                for (int lz = std::max(bz, LO); lz < std::min(bz + TILE, HI); ++lz) {
                    for (int lx = std::max(bx, LO); lx < std::min(bx + TILE, HI); ++lx) {
                        const int fid = f.id[(size_t)a.idx(lx, lz, lc)];
                        if (fid < 0) continue;
                        const Brick &br = f.bricks[(size_t)fid];
                        if (br.loose) continue;
                        brick::FitBrick got;
                        ++checked;
                        if (!view.at(a.ox + lx, a.c0 + lc, a.oz + lz, got)) { ++missing; continue; }
                        if (got.x != br.x || got.z != br.z || got.c != br.c || got.sx != br.sx || got.sz != br.sz || got.h != br.h) {
                            if ((fdiv(a.c0 + lc, 3) & 1) == 0) ++wrong_even;
                            if (wrong.fetch_add(1) < 6) {
                                std::lock_guard<std::mutex> lk(ex_lock);
                                const int L = fdiv(a.c0 + lc, 3);
                                ex.append(vformat("cell (%d,%d,%d) L%d: batch %d,%d,%d %dx%dx%d layer %d; lookup %d,%d,%d %dx%dx%d",
                                        a.ox + lx, a.c0 + lc, a.oz + lz, L, br.x, br.c, br.z, br.sx, br.sz, br.h, br.layer,
                                        got.x, got.c, got.z, got.sx, got.sz, got.h));
                            }
                        }
                    }
                }
            }
        }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < std::max(1, threads); ++t) pool.emplace_back(work);
    work();
    for (auto &t : pool) t.join();
    d["checked"] = checked.load();
    d["wrong"] = wrong.load();
    d["missing"] = missing.load();
    d["examples"] = ex;
    d["wrong_even"] = wrong_even.load();
    d["c0"] = a.c0;
    d["nc"] = a.nc;
    d["ms"] = (double)(godot::Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    d["stats"] = lookup_stats();
    return d;
}

/// generated_cells made fresh against the kept tile and sections (sampled
/// first through build_section / sample_tile by the caller): cells and tops
/// that differ, plates [y_lo, y_hi) of tile `tile`.
Dictionary TerrainFit::check_generated(Vector2i tile, int y_lo, int y_hi) {
    Dictionary d;
    std::vector<uint8_t> kept, made;
    std::vector<int16_t> kt, mt;
    if (!brick::generated_cells(tile.x, tile.y, y_lo, y_hi, kept, kt)) { d["error"] = "no generator"; return d; }
    brick::set_generated_made_only(true);
    brick::generated_cells(tile.x, tile.y, y_lo, y_hi, made, mt);
    brick::set_generated_made_only(false);
    int64_t cells = 0, tops = 0;
    for (size_t i = 0; i < kept.size(); ++i) cells += kept[i] != made[i];
    for (size_t i = 0; i < kt.size(); ++i) tops += kt[i] != mt[i];
    d["cells"] = (int64_t)kept.size();
    d["cells_differ"] = cells;
    d["tops_differ"] = tops;
    return d;
}

Array TerrainFit::run(const Array &areas, const Array &variants) {
    std::vector<Area> as(areas.size());
    for (int i = 0; i < areas.size(); ++i) {
        const Vector2i t = areas[i];
        sample_area(t.x, t.y, as[(size_t)i]);
    }
    Array out;
    for (int v = 0; v < variants.size(); ++v) {
        FitParams p = parse(variants[v]);
        Dictionary cal;
        calibrate(p, variants[v], &cal);
        Sums s;
        Dictionary r;
        for (size_t i = 0; i < as.size(); ++i) {
            Fit f;
            Fitter(as[i], p, f).run();
            measure(as[i], f, s);
            if (i == 0) {
                int w = 0, h = 0;
                const int lz = best_slice(as[i]);
                r["slice"] = slice_picture(as[i], f, lz, w, h);
                r["slice_w"] = w;
                r["slice_h"] = h;
                r["slice_z"] = as[i].oz + lz;
                // What the area is made of: cells by kind, and full cells next to air.
                Array kinds;
                int64_t kc[5] = { 0, 0, 0, 0, 0 };
                int64_t open = 0;
                const Area &A = as[i];
                for (int lc = 1; lc + 1 < A.nc; ++lc) {
                    for (int lz2 = 1; lz2 + 1 < A.d; ++lz2) {
                        for (int lx = 1; lx + 1 < A.w; ++lx) {
                            const int k = A.kind[(size_t)A.idx(lx, lz2, lc)];
                            ++kc[k];
                            if (k >= K_MEDIUM && (A.kind[(size_t)A.idx(lx + 1, lz2, lc)] == K_AIR
                                    || A.kind[(size_t)A.idx(lx, lz2, lc + 1)] == K_AIR)) ++open;
                        }
                    }
                }
                for (int k = 0; k < 5; ++k) kinds.append(kc[k]);
                kinds.append(open);
                kinds.append(A.c0);
                kinds.append(A.nc);
                r["kinds"] = kinds;
            }
        }
        r["name"] = String(p.name.c_str());
        r["calibration"] = cal;
        r["bricks"] = s.bricks;
        r["visible"] = s.vis;
        r["loose"] = s.loose;
        r["per_tile"] = (double)(s.bricks + s.loose) / (9.0 * (double)as.size());
        r["mean_cells"] = s.bricks > 0 ? (double)s.cells / (double)s.bricks : 0.0;
        r["ones"] = s.bricks > 0 ? (double)s.ones / (double)s.bricks : 0.0;
        r["ore_ones"] = s.bricks > 0 ? (double)s.ore_ones / (double)s.bricks : 0.0;
        r["stacked_share"] = s.seams > 0 ? (double)s.stacked / (double)s.seams : 0.0;
        Dictionary share, share_vis;
        for (const auto &e : s.share) share[String(e.first.c_str())] = (double)e.second / (double)std::max<int64_t>(1, s.bricks);
        for (const auto &e : s.share_vis) share_vis[String(e.first.c_str())] = (double)e.second / (double)std::max<int64_t>(1, s.vis);
        r["share"] = share;
        r["share_vis"] = share_vis;
        Array hs;
        for (int k = 0; k < 3; ++k) hs.append((double)s.heights[k] / (double)std::max<int64_t>(1, s.bricks));
        r["heights"] = hs;
        r["along_x"] = s.oriented > 0 ? (double)s.along_x / (double)s.oriented : 0.5;
        r["joints"] = s.joints;
        r["stacked_k"] = s.joints > 0 ? 1000.0 * (double)s.stacked / (double)s.joints : 0.0;
        r["long_k"] = s.joints > 0 ? 1000.0 * (double)s.long_stacked / (double)s.joints : 0.0;
        r["joints_per_brick"] = s.bricks > 0 ? 2.0 * (double)s.joints / (double)s.bricks : 0.0;
        r["cross_tile"] = s.bricks > 0 ? (double)s.cross_tile / (double)s.bricks : 0.0;
        r["in4"] = s.bricks > 0 ? (double)s.in4 / (double)s.bricks : 0.0;
        r["cross_sec"] = s.bricks > 0 ? (double)s.cross_sec / (double)s.bricks : 0.0;
        r["chunks_per_brick"] = s.bricks > 0 ? (double)s.chunks / (double)s.bricks : 0.0;
        r["ms_tile"] = s.ms / (double)std::max<int64_t>(1, s.tiles);
        r["us_region"] = s.regions > 0 ? 1000.0 * s.ms / (double)s.regions : 0.0;
        out.append(r);
    }
    return out;
}

void TerrainFit::_bind_methods() {
    ClassDB::bind_static_method("TerrainFit", D_METHOD("run", "areas", "variants"), &TerrainFit::run);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("configure", "settings"), &TerrainFit::configure);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("get_configured"), &TerrainFit::get_configured);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("get_calibration"), &TerrainFit::get_calibration);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("brick_at", "x", "course", "z"), &TerrainFit::brick_at);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("lookup_stats"), &TerrainFit::lookup_stats);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("check_lookup", "tile", "threads", "depth"), &TerrainFit::check_lookup, DEFVAL(4), DEFVAL(0));
    ClassDB::bind_static_method("TerrainFit", D_METHOD("set_enabled", "on"), &TerrainFit::set_enabled);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("check_generated", "tile", "y_lo", "y_hi"), &TerrainFit::check_generated);
    ClassDB::bind_static_method("TerrainFit", D_METHOD("get_enabled"), &TerrainFit::get_enabled);
}
