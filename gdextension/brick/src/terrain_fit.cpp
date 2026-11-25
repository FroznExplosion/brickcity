#include "terrain_fit.h"

#include "brick_terrain.h"
#include "terrain_bond.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <cmath>
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
    std::vector<uint8_t> mat, kind;
    int idx(int lx, int lz, int lc) const { return lx + AREA * (lz + AREA * lc); }
    bool in(int lx, int lz, int lc) const {
        return lx >= 0 && lz >= 0 && lc >= 0 && lx < AREA && lz < AREA && lc < nc;
    }
};

/// The area's cells, from the generator (no edits in a probe's world).
void sample_area(int tx0, int tz0, Area &a) {
    std::vector<std::unique_ptr<brick::TileSample>> s;
    int plo = 1 << 30, phi = -(1 << 30);
    for (int k = 0; k < AREA_TILES * AREA_TILES; ++k) {
        auto t = std::make_unique<brick::TileSample>();
        brick::packed_tile(tx0 + k % AREA_TILES, tz0 + k / AREA_TILES, *t);
        plo = std::min(plo, t->lo_owned());
        phi = std::max(phi, t->hi_owned());
        s.push_back(std::move(t));
    }
    a.ox = tx0 * TILE;
    a.oz = tz0 * TILE;
    a.c0 = fdiv(plo, 3);
    a.nc = fdiv(phi + 2, 3) - a.c0;
    const size_t n = (size_t)AREA * AREA * a.nc;
    a.mat.assign(n, 0);
    a.kind.assign(n, K_AIR);
    for (int k = 0; k < AREA_TILES * AREA_TILES; ++k) {
        const brick::TileSample &t = *s[(size_t)k];
        const int bx = (k % AREA_TILES) * TILE, bz = (k / AREA_TILES) * TILE;
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                for (int lc = 0; lc < a.nc; ++lc) {
                    const int p = (a.c0 + lc) * 3;
                    const int m0 = t.voxel(lx, p, lz), m1 = t.voxel(lx, p + 1, lz), m2 = t.voxel(lx, p + 2, lz);
                    const int i = a.idx(bx + lx, bz + lz, lc);
                    const int solid = (m0 != 0) + (m1 != 0) + (m2 != 0);
                    if (solid == 0) {
                        continue;
                    }
                    a.mat[(size_t)i] = (uint8_t)(m1 != 0 ? m1 : (m0 != 0 ? m0 : m2));
                    if (solid < 3) {
                        a.kind[(size_t)i] = K_PARTIAL;
                        continue;
                    }
                    const int g = std::min(brick::bond_group(m0), std::min(brick::bond_group(m1), brick::bond_group(m2)));
                    a.kind[(size_t)i] = g == brick::BOND_LOOSE ? K_LOOSE : (g == brick::BOND_MEDIUM ? K_MEDIUM : K_STRONG);
                }
            }
        }
    }
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
    int medium_max = 8;         ///< the biggest footprint (cells) in medium ground
    int offset = 7;             ///< odd courses' squares shifted by this
    bool merge = true;          ///< 1x1s merged into a 1-wide neighbour after a region
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
int g_off = 7;
int course_off(int c) { return (c & 1) ? g_off : 0; }

class Fitter {
public:
    Fitter(const Area &a, const FitParams &p, Fit &f) : a_(a), p_(p), f_(f) {}

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
                    const int rx0 = fdiv(a_.ox - SQ, SQ), rx1 = fdiv(a_.ox + AREA, SQ);
                    const int rz0 = fdiv(a_.oz - SQ, SQ), rz1 = fdiv(a_.oz + AREA, SQ);
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
    std::vector<int16_t> top_;        ///< a column's highest solid local course, -1 none
    std::vector<uint8_t> near_cave_;  ///< per cell: within cave_reach of cave air

    /// Columns' tops, and cave air (air under its column's top) grown by
    /// cave_reach: where the stagger is the caves' (weaker).
    void prepare() {
        top_.assign((size_t)AREA * AREA, -1);
        for (int lz = 0; lz < AREA; ++lz)
            for (int lx = 0; lx < AREA; ++lx)
                for (int lc = a_.nc - 1; lc >= 0; --lc)
                    if (a_.kind[(size_t)a_.idx(lx, lz, lc)] != K_AIR) { top_[(size_t)(lx + AREA * lz)] = (int16_t)lc; break; }
        near_cave_.assign(a_.kind.size(), 0);
        if (p_.cave_stagger < -1.5) return;
        const int R = p_.cave_reach;
        for (int lc = 0; lc < a_.nc; ++lc)
            for (int lz = 0; lz < AREA; ++lz)
                for (int lx = 0; lx < AREA; ++lx) {
                    if (a_.kind[(size_t)a_.idx(lx, lz, lc)] != K_AIR || lc >= top_[(size_t)(lx + AREA * lz)]) continue;
                    for (int dc = -R; dc <= R; ++dc)
                        for (int dz = -R; dz <= R; ++dz)
                            for (int dx = -R; dx <= R; ++dx)
                                if (a_.in(lx + dx, lz + dz, lc + dc)) near_cave_[(size_t)a_.idx(lx + dx, lz + dz, lc + dc)] = 1;
                }
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
                depth += (double)(top_[(size_t)(lx + AREA * lz)] - lc);
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
            for (int lz = 0; lz < AREA; ++lz) {
                for (int lx = 0; lx < AREA; ++lx) {
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
        auto edge = [&](int ax, int az, int bx, int bz) {
            const int i = at(ax, az, cb), j = at(bx, bz, cb);
            if (i < 0 || j < 0) return;
            const int A = f_.id[(size_t)i], B = f_.id[(size_t)j];
            if (A < 0 || B < 0) return;
            if (!known(A, L, reg) || !known(B, L, reg)) return;
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
        const int o = course_off(c);
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
            const int o = course_off(c);
            const int bx = rx * SQ + o, bz = rz * SQ + o;
            pick_band(c, bx, bz);
            if (p_.wide_first) wide_pass(c, k, rx, rz, L, reg, bx, bz);
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
                            for (int h = 1; h <= 3 - k; ++h) {
                                // fits() checks only the new course: a height left out ends the taller ones.
                                if (h > 1 && heights_[h - 1] <= 0.0) break;
                                if (!fits(x0, x1, z0, z1, c, h, rx, rz, kind, mat, reg)) break;
                                const double hw = std::max(0.02, heights_[h - 1] * (n_ + 1) - hcnt_[h - 1]);
                                const double w = qw * hw;
                                double frac = 0.0;
                                if (p_.stagger >= 0.0) {
                                    int units = 0;
                                    int sm = seams_along(x0, x1, z0, z1, c - 1, L, reg, units);
                                    sm += seams_along(x0, x1, z0, z1, c + h, L, reg, units);
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
    void wide_pass(int c, int k, int rx, int rz, int L, int64_t reg, int bx, int bz) {
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
        std::sort(order.begin(), order.end(), [&](int x, int y) {
            return brick::bond_hash(x, rx * 31 + rz, c ^ seed_) < brick::bond_hash(y, rx * 31 + rz, c ^ seed_);
        });
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
                    int units = 0;
                    const int sm = seams_along(x, x + sx - 1, z, z + sz - 1, c - 1, L, reg, units)
                            + seams_along(x, x + sx - 1, z, z + sz - 1, c + 1, L, reg, units);
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
    }

    bool fits(int x0, int x1, int z0, int z1, int c, int h, int rx, int rz, int kind, int mat, int64_t reg) const {
        const int cc = c + h - 1;
        if (!square_has(cc, rx, rz, x0, x1, z0, z1)) return false;
        if (fdiv(x0, TILE) != fdiv(x1, TILE) && !gate(fdiv(x1, TILE), 0, cc, reg)) return false;
        if (fdiv(z0, TILE) != fdiv(z1, TILE) && !gate(fdiv(z1, TILE), 1, cc, reg)) return false;
        if (h > 1 && fdiv(c, SECTION_COURSES) != fdiv(cc, SECTION_COURSES) && !gate(fdiv(cc, SECTION_COURSES), 2, 0, reg)) return false;
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
    s.tiles += AREA_TILES * AREA_TILES;
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
        if (lx < 0 || lx >= AREA || lc < 0 || lc >= a.nc) return -2;
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
    p.medium_max = (int)d.get("medium_max", 8);
    p.seed = (int)d.get("seed", 1);
    p.offset = (int)d.get("offset", 7);
    p.merge = (bool)d.get("merge", true);
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

} // namespace

namespace {
/// The world's fill (TerrainFit.configure), what the game's bricks will use.
/// Made on first use: a Godot Variant built when the library loads (before
/// Godot's interface is there) fails the DLL's initialisation.
struct World {
    FitParams params;
    Dictionary settings;
};
std::unique_ptr<World> g_world;
} // namespace

void TerrainFit::configure(const Dictionary &settings) {
    if (!g_world) g_world = std::make_unique<World>();
    g_world->settings = settings.duplicate(true);
    g_world->params = parse(settings);
}

Dictionary TerrainFit::get_configured() {
    return g_world ? g_world->settings.duplicate(true) : Dictionary();
}

Array TerrainFit::run(const Array &areas, const Array &variants) {
    std::vector<Area> as(areas.size());
    for (int i = 0; i < areas.size(); ++i) {
        const Vector2i t = areas[i];
        sample_area(t.x, t.y, as[(size_t)i]);
    }
    Array out;
    for (int v = 0; v < variants.size(); ++v) {
        const FitParams p = parse(variants[v]);
        g_off = p.offset;
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
                    for (int lz2 = 1; lz2 + 1 < AREA; ++lz2) {
                        for (int lx = 1; lx + 1 < AREA; ++lx) {
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
}
