#include "brick_fluid.h"

#include "brick_terrain.h"
#include "terrain_biomes.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cstdint>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace brick;

// Docs/MineWater.md. Everything below the class boundary is one worker's
// state: the tick thread is its only writer; the main thread reads it under
// g_state (held by the worker only while it writes cells or adds sections).

namespace {

constexpr int SX = TILE;            ///< studs a side: one terrain tile
constexpr int SB = 16;              ///< brick courses a section
constexpr int SCOL = SX * SX;
constexpr int SCELLS = SCOL * SB;
constexpr double TICK_S = 0.1;      ///< 10 Hz (MineWater.md 4)
constexpr int LAVA_EVERY = 5;       ///< lava: every 5th tick
constexpr int MAX_EVALS = 65536;    ///< a tick's budget (6)
constexpr int DROP_SEEK = 5;        ///< studs flowing water looks for a drop (4.1.5)
constexpr int MESH_PER_TICK = 24;
constexpr float TOP_SINK = 0.015f;  ///< tops a hair under the course: no z-fight with ground tops

enum { K_SOURCE = 0, K_FLOW = 1, K_FALL = 2, K_STILL = 3 };
enum { F_NONE = 0, F_WATER = 1, F_LAVA = 2 };

struct FluidDef {
    int reach;      ///< the last distance that still holds water
    int split;      ///< distances up to this are 2 plates deep, past it 1
    bool renew;     ///< two sources make a third (4.1.7)
    bool dries;     ///< a lone tile of still fluid dries (4.2.3)
};
const FluidDef DEFS[3] = { { 0, 0, false, false }, { 14, 7, true, true }, { 6, 3, false, false } };

struct Cell {
    uint8_t solid = 0;   ///< bit per plate (0 bottom), from the terrain
    uint8_t st = 0;      ///< fluid (2 bits) | kind << 2 | ocean << 4
    uint8_t amt = 0;     ///< plates of fluid, 0..3
    uint8_t aux = 0;     ///< FLOW: distance. STILL: low 6 bits the edge distance
                         ///< (E_NONE: none known), 0x80 = drying timer set
};

inline int c_fluid(const Cell &c) { return c.st & 3; }
inline int c_kind(const Cell &c) { return (c.st >> 2) & 3; }
inline bool c_ocean(const Cell &c) { return ((c.st >> 4) & 1) != 0; }
inline uint8_t mk_st(int fluid, int kind, bool ocean) {
    return (uint8_t)(fluid | (kind << 2) | (ocean ? 16 : 0));
}
inline int floor_of(uint8_t m) { return (m & 4) ? 3 : (m & 2) ? 2 : (m & 1) ? 1 : 0; }
inline bool c_wet(const Cell &c) { return c_fluid(c) != F_NONE && c.amt > 0; }
inline bool c_fed(const Cell &c) { return c_wet(c) && c_kind(c) != K_STILL; }
inline int c_cap(const Cell &c) { return 3 - floor_of(c.solid); }
inline int c_dist(const Cell &c) { return c_kind(c) == K_FLOW ? (int)c.aux : 0; }
/// Still water's distance, in cells, to the dry floor its sheet can spread
/// onto (4.2.6): 0 beside it, E_NONE when none is known (enclosed, or new).
constexpr uint8_t E_NONE = 63;
inline int c_edge(const Cell &c) { return c.aux & 0x3F; }

inline int fdiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }
inline int64_t pack3(int x, int y, int z) {
    return ((int64_t)(x & 0x1FFFFF) << 42) | ((int64_t)(y & 0x1FFFFF) << 21) | (int64_t)(z & 0x1FFFFF);
}
inline int sx21(int64_t v) { return (int)((v & 0x100000) ? (v | ~(int64_t)0x1FFFFF) : v); }
inline void unpack3(int64_t k, int &x, int &y, int &z) {
    x = sx21((k >> 42) & 0x1FFFFF);
    y = sx21((k >> 21) & 0x1FFFFF);
    z = sx21(k & 0x1FFFFF);
}
inline int64_t tkey(int tx, int tz) { return ((int64_t)(tx & 0xFFFFFFF) << 28) | (int64_t)(tz & 0xFFFFFFF); }
inline uint32_t hmix(uint32_t h) {
    h ^= h >> 16; h *= 0x7feb352dU; h ^= h >> 15; h *= 0x846ca68bU; h ^= h >> 16;
    return h;
}

struct Section {
    int sx = 0, sb = 0, sz = 0;
    std::vector<Cell> c;
    std::vector<uint8_t> ready;     ///< per column: sampled from the field
    std::vector<int16_t> gtop;      ///< per column: generated top brick (the sea's floor)
    std::vector<int16_t> spring;    ///< per column: a spring's course, or NO_SPRING
    bool written = false;           ///< any cell ever written (the save skips the rest)
    std::vector<uint8_t> queued;    ///< per cell: in the next tick's list
    int wet = 0;                    ///< wet cells (for "anything to draw")
    static int idx(int lx, int lb, int lz) { return lx + SX * (lz + SX * lb); }
};

std::unordered_map<int64_t, std::unique_ptr<Section>> g_sec;
std::unordered_map<int64_t, std::vector<int>> g_tile_secs;   ///< tile -> section courses
std::recursive_mutex g_state;
std::mutex g_cmd_mx;

double g_sea_m = 0.0;
int g_sea_b = 0;          ///< the first course ABOVE the sea
bool g_sea_on = false;
bool g_sloped = true;
double g_cx = 0.0, g_cz = 0.0, g_sim_r = 90.0;
double g_recheck_x = 1e30, g_recheck_z = 1e30;
uint32_t g_tick = 0;

std::vector<int64_t> g_due;            ///< water (and anything) next tick
std::vector<int64_t> g_due_lava;       ///< waits for a lava tick
std::multimap<uint32_t, int64_t> g_timers;
std::unordered_set<int64_t> g_frozen;
std::unordered_set<int64_t> g_dirty_tiles;
std::unordered_set<int64_t> g_mesh_requests;
std::unordered_set<int64_t> g_far_requests;   ///< tiles wanting the coarse mesh
int g_mask_version = 0;

struct Cmd {
    int type = 0;     // 0 terrain, 1 place, 2 remove, 3 raw, 4 mesh request, 5 reset frozen
    Vector3i a, b;
    int fluid = 0, kind = 0, amount = 0;
    uint8_t st = 0, amt = 0, aux = 0;
};
std::vector<Cmd> g_cmds;

struct MeshOut {
    int tx, tz;
    Array water, lava;
    bool far = false;   ///< the coarse mesh (MineWater.md 8)
};
std::vector<MeshOut> g_out_meshes;
/// Rock the fluids made, for the main thread to lay as terrain edits: per
/// cell (x, z, first plate, last plate, material) -- only the plates the lava
/// filled, so a tile of lava is a tile of rock.
std::vector<int32_t> g_out_terrain;

void out_rock(int x, int b, int z, const Cell &c, int mat) {
    const int lo = b * 3 + floor_of(c.solid);
    g_out_terrain.push_back(x);
    g_out_terrain.push_back(z);
    g_out_terrain.push_back(lo);
    g_out_terrain.push_back(lo + std::max(1, (int)c.amt) - 1);
    g_out_terrain.push_back(mat);
}
bool g_out_mask = false;

std::thread g_thread;
std::atomic<bool> g_running{ false };
std::atomic<bool> g_done{ false };
bool g_have_results = false;
double g_acc = 0.0;

// stats
double g_last_ms = 0.0;
double g_last_mesh_ms = 0.0;    ///< of g_last_ms: building tile meshes
double g_sample_ms = 0.0;       ///< of g_last_ms: reading new columns from the field
std::vector<int64_t> g_last_changed;   ///< probes: a few cells the last tick wrote
int g_last_evals = 0;
int g_last_changes = 0;
int g_last_columns = 0;
int g_last_meshes = 0;
int g_active = 0;

// --- the field ---------------------------------------------------------------

/// Solid masks of `nb` courses from `b0` of one column, and the column's
/// generated top brick. Reads the terrain's edits like a tile bake does.
void sample_column(int x, int z, int b0, int nb, uint8_t *out, int *gen_top) {
    const bool ed = !edits_empty();
    if (biomes_on()) {
        const uint32_t seed = (uint32_t)BrickTerrain::get_seed();
        const BColumn c = biome_column(seed, x, z);
        *gen_top = c.sb;
        for (int i = 0; i < nb; ++i) {
            const int b = b0 + i;
            uint8_t m = 0;
            if (b * 3 <= c.bound_p && biome_cell(c, seed, x, b, z) != MAT_AIR) {
                m = 7;
            }
            if (ed) {
                for (int p = 0; p < 3; ++p) {
                    const int e = edit_at(pack_cell(x, b * 3 + p, z));
                    if (e >= 0) {
                        if (e != MAT_AIR) m |= (uint8_t)(1 << p);
                        else m &= (uint8_t)~(1 << p);
                    }
                }
            }
            out[i] = m;
        }
        return;
    }
    *gen_top = fdiv(BrickTerrain::generated_plate(x, z), 3);
    for (int i = 0; i < nb; ++i) {
        uint8_t m = 0;
        for (int p = 0; p < 3; ++p) {
            if (BrickTerrain::solid_at(x, (b0 + i) * 3 + p, z) != MAT_AIR) m |= (uint8_t)(1 << p);
        }
        out[i] = m;
    }
}

constexpr int NO_SPRING = -32000;
int g_lava_b = INT_MIN;      ///< lava pools: cave air under this course (stage 8)
bool g_springs = false;
uint32_t g_spring_cut = 0;   ///< a column's hash under this: a spring candidate

/// Where a spring runs out of a cliff face into this column (stage 8): a
/// neighbour column chosen by hash whose surface is three bricks or more over
/// this one's; the source is the course just under its top, in this column's
/// air. NO_SPRING when none. Only the hashed few cost a column of their own.
int spring_course(int x, int z, int gen_top) {
    if (!g_springs || !biomes_on()) return NO_SPRING;
    const uint32_t seed = (uint32_t)BrickTerrain::get_seed();
    static const int NX[4] = { 1, -1, 0, 0 }, NZ[4] = { 0, 0, 1, -1 };
    for (int i = 0; i < 4; ++i) {
        const int nx = x + NX[i], nz = z + NZ[i];
        if (hmix((uint32_t)nx * 0x9E3779B1U ^ (uint32_t)nz * 0x85EBCA77U ^ seed) >= g_spring_cut) continue;
        const BColumn c = biome_column(seed, nx, nz);
        // Its real top: cliffs are mostly the overhang band over the base
        // surface, so scan down from the band's top to the first solid.
        int top = c.sb;
        for (int yb = c.bound_p / 3; yb > c.sb; --yb) {
            if (biome_cell(c, seed, nx, yb, nz) != MAT_AIR) { top = yb; break; }
        }
        if (top - 3 >= gen_top) return top - 1;
    }
    return NO_SPRING;
}

/// The fluid the world was generated with in a cell: the sea, lava pools
/// in caves deep down, springs out of cliff faces (MineWater.md 5, 9).
inline void gen_fluid(Cell &cl, int b, int gen_top, int spring_b = NO_SPRING) {
    cl.st = 0;
    cl.amt = 0;
    cl.aux = 0;
    const int cap = c_cap(cl);
    if (cap <= 0) return;
    if (g_sea_on && gen_top + 1 < g_sea_b && b > gen_top && b < g_sea_b) {
        cl.st = mk_st(F_WATER, K_SOURCE, true);
        cl.amt = (uint8_t)cap;
    } else if (b < g_lava_b && b < gen_top) {
        // Air under the ground and under the lava line is a cave: lava.
        cl.st = mk_st(F_LAVA, K_SOURCE, false);
        cl.amt = (uint8_t)cap;
    } else if (b == spring_b && b > gen_top) {
        cl.st = mk_st(F_WATER, K_SOURCE, false);
        cl.amt = (uint8_t)cap;
    }
}

Cell gen_cell(int x, int b, int z) {
    Cell c;
    int gt = 0;
    sample_column(x, z, b, 1, &c.solid, &gt);
    gen_fluid(c, b, gt, spring_course(x, z, gt));
    return c;
}

// --- sections ----------------------------------------------------------------

/// Sections are only ever freed by reset, which bumps this: a cached pointer
/// from before it is never used.
std::atomic<uint32_t> g_sec_epoch{ 1 };

/// The hash map behind every cell read was most of a cell's cost (measured,
/// MineWater.md 12): a small direct-mapped cache per thread in front of it.
/// A miss on a section that does not exist is not cached (it may be made).
struct SecCache {
    int64_t key[64];
    Section *ptr[64];
    uint32_t epoch = 0;
};

inline Section *sec_find(int sx, int sb, int sz) {
    thread_local SecCache cache;
    const uint32_t ep = g_sec_epoch.load(std::memory_order_relaxed);
    if (cache.epoch != ep) {
        for (int i = 0; i < 64; ++i) { cache.key[i] = -1; cache.ptr[i] = nullptr; }
        cache.epoch = ep;
    }
    const int64_t k = pack3(sx, sb, sz);
    const uint32_t slot = hmix((uint32_t)k ^ (uint32_t)(k >> 32)) & 63;
    if (cache.key[slot] == k) return cache.ptr[slot];
    auto it = g_sec.find(k);
    if (it == g_sec.end()) return nullptr;
    cache.key[slot] = k;
    cache.ptr[slot] = it->second.get();
    return cache.ptr[slot];
}

Section *sec_make(int sx, int sb, int sz) {
    Section *s = sec_find(sx, sb, sz);
    if (s != nullptr) {
        return s;
    }
    auto ns = std::make_unique<Section>();
    ns->sx = sx;
    ns->sb = sb;
    ns->sz = sz;
    ns->c.resize(SCELLS);
    ns->ready.assign(SCOL, 0);
    ns->gtop.assign(SCOL, 0);
    ns->spring.assign(SCOL, NO_SPRING);
    ns->queued.assign(SCELLS, 0);
    s = ns.get();
    std::lock_guard<std::recursive_mutex> lk(g_state);
    g_sec[pack3(sx, sb, sz)] = std::move(ns);
    g_tile_secs[tkey(sx, sz)].push_back(sb);
    return s;
}

void sample_into(Section *s, int lx, int lz) {
    const int x = s->sx * SX + lx, z = s->sz * SX + lz;
    uint8_t masks[SB];
    int gt = 0;
    const auto t0 = std::chrono::steady_clock::now();
    sample_column(x, z, s->sb * SB, SB, masks, &gt);
    g_sample_ms += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    s->gtop[lx + SX * lz] = (int16_t)std::max(-32000, std::min(32000, gt));
    const int sp = spring_course(x, z, gt);
    s->spring[lx + SX * lz] = (int16_t)sp;
    for (int lb = 0; lb < SB; ++lb) {
        Cell &cl = s->c[Section::idx(lx, lb, lz)];
        cl.solid = masks[lb];
        gen_fluid(cl, s->sb * SB + lb, gt, sp);
        if (c_wet(cl)) ++s->wet;
    }
    std::atomic_thread_fence(std::memory_order_release);
    s->ready[lx + SX * lz] = 1;
    ++g_last_columns;
}

/// Worker: the cell, made and sampled if it has to be.
Cell &wcell(int x, int b, int z) {
    const int sx = fdiv(x, SX), sb = fdiv(b, SB), sz = fdiv(z, SX);
    Section *s = sec_make(sx, sb, sz);
    const int lx = x - sx * SX, lb = b - sb * SB, lz = z - sz * SX;
    if (!s->ready[lx + SX * lz]) {
        sample_into(s, lx, lz);
    }
    return s->c[Section::idx(lx, lb, lz)];
}

/// Main thread, under g_state: read only, never makes anything.
Cell rcell(int x, int b, int z) {
    const int sx = fdiv(x, SX), sb = fdiv(b, SB), sz = fdiv(z, SX);
    Section *s = sec_find(sx, sb, sz);
    if (s != nullptr) {
        const int lx = x - sx * SX, lb = b - sb * SB, lz = z - sz * SX;
        if (s->ready[lx + SX * lz]) {
            std::atomic_thread_fence(std::memory_order_acquire);
            return s->c[Section::idx(lx, lb, lz)];
        }
    }
    return gen_cell(x, b, z);
}

inline double dist2_centre(int x, int z) {
    const double dx = ((double)x + 0.5) * STUD_M - g_cx;
    const double dz = ((double)z + 0.5) * STUD_M - g_cz;
    return dx * dx + dz * dz;
}

void wake(int x, int b, int z) {
    const int64_t k = pack3(x, b, z);
    if (dist2_centre(x, z) > g_sim_r * g_sim_r) {
        g_frozen.insert(k);
        return;
    }
    const int sx = fdiv(x, SX), sb = fdiv(b, SB), sz = fdiv(z, SX);
    Section *s = sec_make(sx, sb, sz);
    const int lx = x - sx * SX, lb = b - sb * SB, lz = z - sz * SX;
    if (!s->ready[lx + SX * lz]) {
        sample_into(s, lx, lz);
    }
    uint8_t &q = s->queued[Section::idx(lx, lb, lz)];
    if (!q) {
        q = 1;
        g_due.push_back(k);
    }
}

void wake_around(int x, int b, int z) {
    wake(x, b, z);
    wake(x + 1, b, z);
    wake(x - 1, b, z);
    wake(x, b + 1, z);
    wake(x, b - 1, z);
    wake(x, b, z + 1);
    wake(x, b, z - 1);
}

void mark_dirty(int x, int b, int z) {
    const int tx = fdiv(x, SX), tz = fdiv(z, SX);
    g_dirty_tiles.insert(tkey(tx, tz));
    const int lx = x - tx * SX, lz = z - tz * SX;
    if (lx == 0) g_dirty_tiles.insert(tkey(tx - 1, tz));
    if (lx == SX - 1) g_dirty_tiles.insert(tkey(tx + 1, tz));
    if (lz == 0) g_dirty_tiles.insert(tkey(tx, tz - 1));
    if (lz == SX - 1) g_dirty_tiles.insert(tkey(tx, tz + 1));
    if (b >= g_sea_b - 2 && b <= g_sea_b + 1) {
        g_out_mask = true;
    }
}

/// Cells written since the world began: the save asks whether anything
/// changed since it last wrote (MineWater.md 11).
std::atomic<int64_t> g_writes{ 0 };

/// Write a cell (worker, under g_state) and keep the wet count.
void write_cell(int x, int b, int z, const Cell &nc) {
    const int sx = fdiv(x, SX), sb = fdiv(b, SB), sz = fdiv(z, SX);
    Section *s = sec_find(sx, sb, sz);
    if (s == nullptr) return;
    Cell &cl = s->c[Section::idx(x - sx * SX, b - sb * SB, z - sz * SX)];
    const bool was = c_wet(cl);
    const bool drawn_same = cl.st == nc.st && cl.amt == nc.amt;
    cl.st = nc.st;
    cl.amt = nc.amt;
    cl.aux = nc.aux;
    if (cl.amt == 0) {
        cl.st = 0;
        cl.aux = 0;
    }
    const bool is = c_wet(cl);
    s->wet += (is ? 1 : 0) - (was ? 1 : 0);
    s->written = true;
    if (!drawn_same) {
        mark_dirty(x, b, z);
        g_writes.fetch_add(1, std::memory_order_relaxed);
    }
}

/// Was this column generated as sea? (its generated top under the sea course)
bool gen_sea_col(int x, int z) {
    if (!g_sea_on) return false;
    const int sx = fdiv(x, SX), sz = fdiv(z, SX);
    wcell(x, g_sea_b - 1, z);   // makes and samples the column
    Section *s = sec_find(sx, fdiv(g_sea_b - 1, SB), sz);
    return s != nullptr && s->gtop[(x - sx * SX) + SX * (z - sz * SX)] + 1 < g_sea_b;
}

// --- the rules (MineWater.md 4) -----------------------------------------------

const int DX[4] = { 1, -1, 0, 0 };
const int DZ[4] = { 0, 0, 1, -1 };

/// Fluid resting here cannot go down: ground in the cell or under it, or a
/// full cell of fluid under it.
bool supported(int x, int b, int z, const Cell &c) {
    if (floor_of(c.solid) > 0) return true;
    const Cell &d = wcell(x, b - 1, z);
    if (d.solid & 4) return true;
    // Falling water is not a floor: water over a waterfall only falls (else it
    // spreads across the top of every course of the fall, its reach anew).
    if (c_wet(d) && c_kind(d) != K_FALL && (floor_of(d.solid) + d.amt >= 3 || c_kind(d) == K_SOURCE)) return true;
    if (c_wet(d) && c_wet(c) && c_fluid(d) != c_fluid(c)) return true;
    return false;
}

std::unordered_map<int64_t, uint8_t> g_seek;   ///< per tick: directions a spreader takes

/// Minecraft's spread toward the nearest drop within DROP_SEEK studs: the
/// directions (bit per DX/DZ index) on a shortest path to one, or all four.
uint8_t seek_dirs(int x, int b, int z, const Cell &n) {
    const int64_t k = pack3(x, b, z);
    auto it = g_seek.find(k);
    if (it != g_seek.end()) return it->second;
    const int nf = floor_of(n.solid);
    int best = 1 << 30;
    uint8_t mask = 0;
    // Breadth first over the (2*DROP_SEEK+1)^2 studs round it, on the stack:
    // the set and the vector this had were most of a flowing cell's cost.
    constexpr int R = DROP_SEEK, SIDE = 2 * R + 1;
    struct Node { int8_t x, z, d, first; };
    Node q[SIDE * SIDE * 4 + 8];
    int qn = 0;
    uint8_t seen[SIDE * SIDE] = {};
    seen[R + SIDE * R] = 1;
    for (int i = 0; i < 4; ++i) {
        q[qn++] = { (int8_t)DX[i], (int8_t)DZ[i], 1, (int8_t)i };
    }
    for (int h = 0; h < qn; ++h) {
        const Node nd = q[h];
        if (nd.d > best || nd.d > DROP_SEEK) break;
        uint8_t &sn = seen[(nd.x + R) + SIDE * (nd.z + R)];
        if (sn && nd.d > 1) continue;
        sn = 1;
        const Cell &c = wcell(x + nd.x, b, z + nd.z);
        const int f = floor_of(c.solid);
        if (f >= 3 || f > nf) continue;
        if (c_wet(c) && c_kind(c) != K_FLOW) continue;
        if (!supported(x + nd.x, b, z + nd.z, c)) {
            if (nd.d < best) { best = nd.d; mask = 0; }
            mask |= (uint8_t)(1 << nd.first);
            continue;
        }
        if (nd.d >= DROP_SEEK) continue;
        for (int i = 0; i < 4; ++i) {
            const int nx = nd.x + DX[i], nz = nd.z + DZ[i];
            if (seen[(nx + R) + SIDE * (nz + R)]) continue;
            q[qn++] = { (int8_t)nx, (int8_t)nz, (int8_t)(nd.d + 1), nd.first };
        }
    }
    if (mask == 0) mask = 0xF;
    g_seek[k] = mask;
    return mask;
}

struct SetOp { int x, b, z; Cell c; };
struct MoveOp { int x, b, z, tx, tb, tz, n, fluid; };
std::vector<SetOp> g_sets;
std::vector<MoveOp> g_moves;
std::vector<int64_t> g_defer_lava;

inline bool lava_tick() { return g_tick % LAVA_EVERY == 0; }

void eval(int x, int b, int z) {
    const Cell cur = wcell(x, b, z);
    const int cap = c_cap(cur);
    const int cf = c_fluid(cur);
    const bool lt = lava_tick();
    if (cf == F_LAVA && !lt) {
        g_defer_lava.push_back(pack3(x, b, z));
        return;
    }
    if (cap <= 0) {
        if (c_wet(cur)) g_sets.push_back({ x, b, z, Cell{} });
        return;
    }
    // Lava meeting water: obsidian from a source, stone from the rest.
    if (cf == F_LAVA && c_wet(cur)) {
        const int nx[6] = { x + 1, x - 1, x, x, x, x };
        const int nb[6] = { b, b, b, b, b + 1, b - 1 };
        const int nz[6] = { z, z, z + 1, z - 1, z, z };
        for (int i = 0; i < 6; ++i) {
            const Cell &o = wcell(nx[i], nb[i], nz[i]);
            if (c_wet(o) && c_fluid(o) == F_WATER) {
                out_rock(x, b, z, cur, c_kind(cur) == K_SOURCE ? MAT_OBSIDIAN : MAT_STONE);
                g_sets.push_back({ x, b, z, Cell{} });
                return;
            }
        }
    }
    if (c_wet(cur) && c_kind(cur) == K_SOURCE) {
        if (cur.amt != cap) {
            Cell n = cur;
            n.amt = (uint8_t)cap;
            g_sets.push_back({ x, b, z, n });
        }
        return;
    }

    // --- fed water: what should this cell be? (4.1)
    const int my_floor = b * 3 + floor_of(cur.solid);
    int best_fluid = 0, best_kind = 0, best_d = 1 << 20, best_amt = 0;
    bool best_ocean = false;
    bool deferred = false;
    {
        const Cell &a = wcell(x, b + 1, z);
        if (c_fed(a) && floor_of(a.solid) == 0 && (cf == F_NONE || c_fluid(a) == cf)) {
            if (c_fluid(a) == F_LAVA && !lt) {
                deferred = true;
            } else {
                best_fluid = c_fluid(a);
                best_kind = K_FALL;
                best_d = 0;
                best_amt = cap;
            }
        }
    }
    int sources[3] = { 0, 0, 0 };
    bool ocean_src = false;
    for (int i = 0; i < 4; ++i) {
        const int nx = x + DX[i], nz = z + DZ[i];
        const Cell &n = wcell(nx, b, nz);
        if (!c_fed(n)) continue;
        const int f = c_fluid(n);
        if (cf != F_NONE && f != cf) continue;
        if (c_kind(n) == K_SOURCE && floor_of(n.solid) + n.amt >= 3) {
            ++sources[f];
            ocean_src = ocean_src || c_ocean(n);
        }
        if (f == F_LAVA && !lt) { deferred = true; continue; }
        if (c_kind(n) != K_SOURCE && !supported(nx, b, nz, n)) continue;
        const int d = c_dist(n) + 1;
        const FluidDef &def = DEFS[f];
        if (d > def.reach || d > best_d) continue;
        if (c_kind(n) == K_FLOW || c_kind(n) == K_FALL) {
            // Toward the nearest drop: the way from n to here is i^1's reverse.
            const int back = (i == 0) ? 1 : (i == 1) ? 0 : (i == 2) ? 3 : 2;
            if (!(seek_dirs(nx, b, nz, n) & (1 << back))) continue;
        }
        const int lvl = d <= def.split ? 2 : 1;
        const int ntop = std::min(my_floor + lvl, b * 3 + floor_of(n.solid) + n.amt);
        if (ntop <= my_floor) continue;
        const int amt = std::min(ntop - my_floor, cap);
        if (d < best_d || (d == best_d && amt > best_amt)) {
            best_fluid = f;
            best_kind = K_FLOW;
            best_d = d;
            best_amt = amt;
        }
    }
    // Two sources beside it and ground or a source under it: a source.
    for (int f = 1; f <= 2; ++f) {
        if (!DEFS[f].renew || sources[f] < 2) continue;
        if (cf != F_NONE && cf != f) continue;
        const Cell &d = wcell(x, b - 1, z);
        const bool held = floor_of(cur.solid) > 0 || (d.solid & 4)
                || (c_wet(d) && c_kind(d) == K_SOURCE && c_fluid(d) == f);
        if (held) {
            best_fluid = f;
            best_kind = K_SOURCE;
            best_d = 0;
            best_amt = cap;
            // Ocean (drawn by the wave tiers) only where the world was
            // generated as sea: a source re-made in a dug channel is calm
            // water the tiers do not draw, so the mesher must.
            best_ocean = ocean_src && b == g_sea_b - 1 && gen_sea_col(x, z);
        }
    }
    if (deferred && best_fluid == 0) {
        g_defer_lava.push_back(pack3(x, b, z));
    }
    if (best_fluid != 0) {
        Cell n = cur;
        int amt = best_amt;
        if (c_wet(cur) && c_kind(cur) == K_STILL) amt = std::max(amt, (int)cur.amt);
        n.st = mk_st(best_fluid, best_kind, best_ocean);
        n.amt = (uint8_t)std::min(amt, cap);
        n.aux = (uint8_t)(best_kind == K_FLOW ? best_d : 0);
        if (n.st != cur.st || n.amt != cur.amt || n.aux != cur.aux) {
            g_sets.push_back({ x, b, z, n });
        }
        return;
    }
    if (!c_wet(cur)) return;
    if (c_kind(cur) == K_FLOW || c_kind(cur) == K_FALL) {
        // Its feed is gone: what is left is a water brick's water (4.1.6).
        Cell n = cur;
        n.st = mk_st(cf, K_STILL, false);
        n.aux = E_NONE;
        // A stream keeps only a tile, so it dries (13.3); a two-plate stream
        // cell kept whole was a 2-deep core its tile-deep edges never dried
        // round. Water deeper than the stream's own level was a pond the
        // river ran over: it stays (4.2.5). A fall keeps all, to drain.
        if (c_kind(cur) == K_FLOW) {
            const int lvl = c_dist(cur) <= DEFS[cf].split ? 2 : 1;
            if ((int)cur.amt <= lvl) n.amt = 1;
        }
        g_sets.push_back({ x, b, z, n });
        return;
    }

    // --- still water: a volume in whole tiles (4.2)
    const int a = cur.amt;
    if (floor_of(cur.solid) == 0) {
        const Cell &d = wcell(x, b - 1, z);
        if (!(d.solid & 4)) {
            int n = 0;
            if (!c_wet(d)) {
                n = std::min(a, c_cap(d));
            } else if (c_fluid(d) == cf) {
                n = c_fed(d) ? a : std::min(a, c_cap(d) - (int)d.amt);
            }
            if (n > 0) {
                g_moves.push_back({ x, b, z, x, b - 1, z, n, cf });
                return;
            }
        }
    }
    int s_top = b * 3 + floor_of(cur.solid) + a;
    int left = a;
    const int rot = (int)(hmix((uint32_t)(x * 73856093) ^ (uint32_t)(z * 19349663) ^ g_tick) & 3);
    bool moved = false;
    bool deep_near = false;
    for (int j = 0; j < 4 && left > 0; ++j) {
        const int i = (j + rot) & 3;
        const int nx = x + DX[i], nz = z + DZ[i];
        const Cell &n = wcell(nx, b, nz);
        const int nc = c_cap(n);
        if (nc <= 0) continue;
        int sn;
        if (c_wet(n)) {
            if (c_fluid(n) != cf) continue;
            if (c_fed(n) || n.amt >= 2) deep_near = true;
            const Cell &na = wcell(nx, b + 1, nz);
            if (c_wet(na)) continue;
            sn = b * 3 + floor_of(n.solid) + n.amt;
        } else {
            sn = supported(nx, b, nz, n) ? b * 3 + floor_of(n.solid) : b * 3 - 1000;
        }
        if (s_top - sn >= 2) {
            g_moves.push_back({ x, b, z, nx, b, nz, 1, cf });
            --s_top;
            --left;
            moved = true;
        }
    }
    if (moved) return;
    // The edge distance (4.2.6): 0 beside dry floor at this cell's own level
    // that the sheet could spread onto, else one more than the nearest still
    // neighbour's. A cell two or more deep gives a tile to a neighbour one
    // plate lower that is NEARER the edge: so a spill on open ground thins
    // out to a tile and dries (a difference of one plate alone never moves,
    // and left a pool three deep with a staircase round it), while water only
    // ever moves outward and cannot ping-pong. A pond with walls, not dry
    // floor, round it has no edge (E_NONE) and stays.
    const int my_fl = floor_of(cur.solid);
    int e_new = E_NONE;
    for (int i = 0; i < 4; ++i) {
        const int nx = x + DX[i], nz = z + DZ[i];
        const Cell &q = wcell(nx, b, nz);
        if (!c_wet(q)) {
            if (c_cap(q) > 0 && floor_of(q.solid) == my_fl && supported(nx, b, nz, q)) { e_new = 0; break; }
            continue;
        }
        if (c_fluid(q) == cf && c_kind(q) == K_STILL) e_new = std::min(e_new, c_edge(q) + 1);
    }
    if (e_new > E_NONE) e_new = E_NONE;
    if (a >= 2 && e_new > 0 && e_new < E_NONE && supported(x, b, z, cur)) {
        for (int j = 0; j < 4; ++j) {
            const int i = (j + rot) & 3;
            const int nx = x + DX[i], nz = z + DZ[i];
            const Cell &n = wcell(nx, b, nz);
            if (!c_wet(n) || c_fluid(n) != cf || c_kind(n) != K_STILL) continue;
            if (b * 3 + floor_of(n.solid) + n.amt != s_top - 1 || c_edge(n) >= e_new) continue;
            if (c_wet(wcell(nx, b + 1, nz))) continue;
            g_moves.push_back({ x, b, z, nx, b, nz, 1, cf });
            return;
        }
    }
    uint8_t want = (uint8_t)((cur.aux & 0x80) | e_new);
    // Lava cut off and come to rest cools into stone (4.6), 30-60 s later.
    if (cf == F_LAVA && !(cur.aux & 0x80) && supported(x, b, z, cur)) {
        want |= 0x80;
        const uint32_t wait = 300 + (hmix((uint32_t)x * 2246822519U ^ (uint32_t)z ^ (uint32_t)b * 131U) % 300);
        g_timers.insert({ g_tick + wait, pack3(x, b, z) });
    }
    // A lone tile, on the ground, with nothing deeper beside it, dries.
    if (DEFS[cf].dries && a == 1 && !(cur.aux & 0x80) && !deep_near && supported(x, b, z, cur)
            && !c_wet(wcell(x, b + 1, z))) {
        want |= 0x80;
        const uint32_t wait = 150 + (hmix((uint32_t)x * 2654435761U ^ (uint32_t)z ^ (uint32_t)b * 97U) % 300);
        g_timers.insert({ g_tick + wait, pack3(x, b, z) });
    }
    if (want != cur.aux) {
        Cell n = cur;
        n.aux = want;
        g_sets.push_back({ x, b, z, n });
    }
}

/// A drying timer came due: dry if it is still a lone tile.
void eval_timer(int x, int b, int z) {
    const Cell cur = wcell(x, b, z);
    if (!c_wet(cur) || c_kind(cur) != K_STILL || !(cur.aux & 0x80)) return;
    if (c_fluid(cur) == F_LAVA) {
        // Still lava at rest: stone, plate for plate.
        out_rock(x, b, z, cur, MAT_STONE);
        g_sets.push_back({ x, b, z, Cell{} });
        return;
    }
    if (cur.amt != 1) return;
    for (int i = 0; i < 4; ++i) {
        const Cell &n = wcell(x + DX[i], b, z + DZ[i]);
        if (c_wet(n) && c_fluid(n) == c_fluid(cur) && (c_fed(n) || n.amt >= 2)) {
            Cell k = cur;
            k.aux = (uint8_t)c_edge(cur);
            g_sets.push_back({ x, b, z, k });
            return;
        }
    }
    g_sets.push_back({ x, b, z, Cell{} });
}

// --- commands ------------------------------------------------------------------

bool box_near_water(int x0, int x1, int b0, int b1, int z0, int z1) {
    for (int sx = fdiv(x0, SX); sx <= fdiv(x1, SX); ++sx) {
        for (int sz = fdiv(z0, SX); sz <= fdiv(z1, SX); ++sz) {
            for (int sb = fdiv(b0, SB); sb <= fdiv(b1, SB); ++sb) {
                Section *s = sec_find(sx, sb, sz);
                if (s != nullptr && s->wet > 0) return true;
            }
        }
    }
    // Generated lava lies in caves under its line, not stored until sampled.
    if (b0 < g_lava_b) return true;
    if (!g_sea_on || b0 >= g_sea_b) return false;
    for (int x = x0; x <= x1; ++x) {
        for (int z = z0; z <= z1; ++z) {
            uint8_t m;
            int gt = 0;
            sample_column(x, z, b0, 1, &m, &gt);
            if (gt + 1 < g_sea_b) return true;
        }
    }
    return false;
}

void apply_cmd(const Cmd &c) {
    if (c.type == 0) {
        const int b0 = fdiv(c.a.y, 3), b1 = fdiv(c.b.y, 3);
        if (!box_near_water(c.a.x - 1, c.b.x + 1, b0 - 1, b1 + 1, c.a.z - 1, c.b.z + 1)) return;
        for (int x = c.a.x; x <= c.b.x; ++x) {
            for (int z = c.a.z; z <= c.b.z; ++z) {
                const int sx = fdiv(x, SX), sz = fdiv(z, SX);
                for (int b = b0; b <= b1; ++b) {
                    const int sb = fdiv(b, SB);
                    Section *s = sec_make(sx, sb, sz);
                    const int lx = x - sx * SX, lz = z - sz * SX;
                    if (!s->ready[lx + SX * lz]) {
                        sample_into(s, lx, lz);
                        continue;
                    }
                    uint8_t m;
                    int gt;
                    sample_column(x, z, b, 1, &m, &gt);
                    Cell &cl = s->c[Section::idx(lx, b - sb * SB, lz)];
                    if (cl.solid == m) continue;
                    std::lock_guard<std::recursive_mutex> lk(g_state);
                    const bool grew = floor_of(m) > floor_of(cl.solid) || ((m & ~cl.solid) & 7) != 0;
                    cl.solid = m;
                    Cell n = cl;
                    const int cap = c_cap(n);
                    // Ground placed into water deletes it (13.4); a source
                    // only shrinks. Fed water finds its level again next tick.
                    if (cap <= 0 || (grew && c_wet(n) && c_kind(n) != K_SOURCE)) n = Cell{ m, 0, 0, 0 };
                    else if (n.amt > cap) n.amt = (uint8_t)cap;
                    write_cell(x, b, z, n);
                }
            }
        }
        for (int x = c.a.x - 1; x <= c.b.x + 1; ++x) {
            for (int z = c.a.z - 1; z <= c.b.z + 1; ++z) {
                for (int b = b0 - 1; b <= b1 + 1; ++b) {
                    wake(x, b, z);
                }
            }
        }
        return;
    }
    if (c.type == 4) {
        g_mesh_requests.insert(tkey(c.a.x, c.a.z));
        return;
    }
    if (c.type == 6) {
        g_far_requests.insert(tkey(c.a.x, c.a.z));
        return;
    }
    if (c.type == 7) {
        // A tile came near (stage 8): its generated lava pools read from the
        // field so they are drawn, its springs read and woken so they run.
        const int tx = c.a.x, tz = c.a.z;
        const uint32_t seed = (uint32_t)BrickTerrain::get_seed();
        bool any = false;
        for (int lz = 0; lz < SX; ++lz) {
            for (int lx = 0; lx < SX; ++lx) {
                const int x = tx * SX + lx, z = tz * SX + lz;
                if (g_lava_b != INT_MIN) {
                    if (c_wet(wcell(x, g_lava_b - 1, z))) any = true;
                }
                if (g_springs) {
                    const int sp = spring_course(x, z, biome_column(seed, x, z).sb);
                    if (sp != NO_SPRING) {
                        wcell(x, sp, z);
                        wake_around(x, sp, z);
                        any = true;
                    }
                }
            }
        }
        if (any) g_dirty_tiles.insert(tkey(tx, tz));
        return;
    }
    if (c.type == 5) {
        g_recheck_x = 1e30;
        return;
    }
    const int x = c.a.x, b = c.a.y, z = c.a.z;
    Cell cur = wcell(x, b, z);
    std::lock_guard<std::recursive_mutex> lk(g_state);
    if (c.type == 3) {
        Cell n = cur;
        n.st = c.st;
        n.amt = (uint8_t)std::min((int)c.amt, std::max(c_cap(cur), 0));
        n.aux = c.aux;
        write_cell(x, b, z, n);
        wake_around(x, b, z);
        return;
    }
    if (c.type == 2) {
        if (!c_wet(cur)) return;
        Cell n = cur;
        if (c.amount < 0 || c_kind(cur) != K_STILL) n = Cell{ cur.solid, 0, 0, 0 };
        else n.amt = (uint8_t)std::max(0, (int)cur.amt - c.amount);
        n.aux = c_kind(n) == K_STILL ? (uint8_t)c_edge(cur) : 0;
        write_cell(x, b, z, n);
        wake_around(x, b, z);
        return;
    }
    // place
    const int f = std::max(1, std::min(2, c.fluid));
    if (c.kind == K_SOURCE) {
        if (c_cap(cur) <= 0) return;
        if (c_wet(cur) && c_fluid(cur) != f) return;
        Cell n = cur;
        n.st = mk_st(f, K_SOURCE, false);
        n.amt = (uint8_t)c_cap(cur);
        n.aux = 0;
        write_cell(x, b, z, n);
        wake_around(x, b, z);
        return;
    }
    int left = std::max(0, c.amount);
    for (int up = 0; up < 4 && left > 0; ++up) {
        Cell q = (up == 0) ? cur : wcell(x, b + up, z);
        const int cap = c_cap(q);
        if (cap <= 0) break;
        if (c_wet(q) && c_fluid(q) != f) break;
        if (c_fed(q)) break;   // poured into running water: it joins it
        const int room = cap - (c_wet(q) ? q.amt : 0);
        const int n = std::min(room, left);
        if (n > 0) {
            Cell nq = q;
            nq.st = mk_st(f, K_STILL, false);
            nq.amt = (uint8_t)((c_wet(q) ? q.amt : 0) + n);
            nq.aux = c_wet(q) ? (uint8_t)c_edge(q) : E_NONE;
            write_cell(x, b + up, z, nq);
            wake_around(x, b + up, z);
            left -= n;
        }
    }
}

// --- the mesher (MineWater.md 7.1) ------------------------------------------------

struct MeshBuf {
    PackedVector3Array v, n;
    PackedColorArray col;
    PackedInt32Array idx;
    void quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d,
            const Vector3 &nrm, const Color &cc) {
        const int base = (int)v.size();
        v.push_back(a); v.push_back(b); v.push_back(c); v.push_back(d);
        for (int i = 0; i < 4; ++i) { n.push_back(nrm); col.push_back(cc); }
        idx.push_back(base); idx.push_back(base + 1); idx.push_back(base + 2);
        idx.push_back(base); idx.push_back(base + 2); idx.push_back(base + 3);
    }
    Array arrays() const {
        Array a;
        if (v.is_empty()) return a;
        a.resize(Mesh::ARRAY_MAX);
        a[Mesh::ARRAY_VERTEX] = v;
        a[Mesh::ARRAY_NORMAL] = n;
        a[Mesh::ARRAY_COLOR] = col;
        a[Mesh::ARRAY_INDEX] = idx;
        return a;
    }
};

/// The top of a column's fluid at course b, in plates; full when there is
/// fluid in the course above.
inline int top_plates(int x, int b, int z, const Cell &c) {
    const Cell &a = wcell(x, b + 1, z);
    if (c_wet(a) && c_fluid(a) == c_fluid(c)) return (b + 1) * 3;
    return b * 3 + floor_of(c.solid) + c.amt;
}

float corner_h(int x, int b, int z, int cx, int cz, int fluid, int own) {
    if (!g_sloped) return (float)own;
    float sum = 0.0f;
    int n = 0;
    for (int dz = -1; dz <= 0; ++dz) {
        for (int dx = -1; dx <= 0; ++dx) {
            const int qx = cx + dx, qz = cz + dz;
            const Cell &q = (qx == x && qz == z) ? wcell(x, b, z) : wcell(qx, b, qz);
            if (!c_wet(q) || c_fluid(q) != fluid) continue;
            const int t = top_plates(qx, b, qz, q);
            if (t >= (b + 1) * 3) return (float)((b + 1) * 3);
            sum += (float)t;
            ++n;
        }
    }
    return n > 0 ? sum / (float)n : (float)own;
}

void mesh_tile(int tx, int tz, Array &water, Array &lava) {
    MeshBuf buf[3];
    auto it = g_tile_secs.find(tkey(tx, tz));
    if (it != g_tile_secs.end()) {
        std::vector<int> sbs = it->second;
        for (int sb : sbs) {
            Section *s = sec_find(tx, sb, tz);
            if (s == nullptr || s->wet <= 0) continue;
            for (int lb = 0; lb < SB; ++lb) {
                // Flat tops of a course, merged into rectangles afterwards
                // (stage 8, "mixed water pieces"): a calm pond was a quad a
                // stud; meshing was two thirds of a spreading spill's time.
                struct Top { bool on; float h; Color c; int f; };
                Top flat[SX * SX];
                for (int i = 0; i < SX * SX; ++i) flat[i].on = false;
                bool any_flat = false;
                for (int lz = 0; lz < SX; ++lz) {
                    for (int lx = 0; lx < SX; ++lx) {
                        if (!s->ready[lx + SX * lz]) continue;
                        const Cell c = s->c[Section::idx(lx, lb, lz)];
                        if (!c_wet(c)) continue;
                        const int x = tx * SX + lx, z = tz * SX + lz, b = sb * SB + lb;
                        const int f = c_fluid(c);
                        MeshBuf &m = buf[f];
                        const int own = top_plates(x, b, z, c);
                        const int bottom = b * 3 + floor_of(c.solid);
                        // Corner heights, plates: (x,z) (x+1,z) (x+1,z+1) (x,z+1).
                        const float h00 = corner_h(x, b, z, x, z, f, own);
                        const float h10 = corner_h(x, b, z, x + 1, z, f, own);
                        const float h11 = corner_h(x, b, z, x + 1, z + 1, f, own);
                        const float h01 = corner_h(x, b, z, x, z + 1, f, own);
                        // Colour: depth, kind, flow direction.
                        int depth = c.amt;
                        for (int k = 1; k <= 3; ++k) {
                            const Cell &d = wcell(x, b - k, z);
                            if (!c_wet(d) || c_fluid(d) != f) break;
                            depth += d.amt;
                        }
                        float fx = 0.0f, fz = 0.0f;
                        if (c_kind(c) == K_FLOW) {
                            for (int i = 0; i < 4; ++i) {
                                const Cell &n = wcell(x + DX[i], b, z + DZ[i]);
                                int nd;
                                if (c_wet(n) && c_fluid(n) == f) nd = c_fed(n) ? c_dist(n) : c_dist(c) + 1;
                                else if (c_cap(n) > 0) nd = c_dist(c) + 2;
                                else continue;
                                fx += (float)DX[i] * (float)(nd - c_dist(c));
                                fz += (float)DZ[i] * (float)(nd - c_dist(c));
                            }
                            const float l = std::sqrt(fx * fx + fz * fz);
                            if (l > 0.001f) { fx /= l; fz /= l; }
                        }
                        const float kind = c_kind(c) == K_FLOW ? 0.5f : c_kind(c) == K_FALL ? 1.0f : 0.0f;
                        const Color cc(std::min(1.0f, (float)depth / 12.0f), kind, fx * 0.5f + 0.5f, fz * 0.5f + 0.5f);
                        const float x0 = (float)x * STUD_M, x1 = (float)(x + 1) * STUD_M;
                        const float z0 = (float)z * STUD_M, z1 = (float)(z + 1) * STUD_M;
                        const float P = PLATE_M;
                        const Cell &above = wcell(x, b + 1, z);
                        const bool top_open = !(c_wet(above) && c_fluid(above) == f);
                        // Only an open top sinks under the course; a side under
                        // more water meets the course above (no seam in a fall).
                        const float sink = top_open ? TOP_SINK : 0.0f;
                        if (top_open && !(c_ocean(c) && own == g_sea_b * 3)
                                && h00 == h10 && h10 == h11 && h11 == h01) {
                            flat[lx + SX * lz] = { true, h00, cc, f };
                            any_flat = true;
                        } else if (top_open && !(c_ocean(c) && own == g_sea_b * 3)) {
                            const Vector3 a(x0, h00 * P - TOP_SINK, z0), bb(x1, h10 * P - TOP_SINK, z0);
                            const Vector3 cq(x1, h11 * P - TOP_SINK, z1), d(x0, h01 * P - TOP_SINK, z1);
                            Vector3 nrm = (d - a).cross(bb - a);
                            if (nrm.y < 0) nrm = -nrm;
                            nrm = nrm.normalized();
                            m.quad(a, d, cq, bb, nrm, cc);
                        }
                        // Sides: down to whatever covers the neighbour.
                        const float ch[4][2] = { { h10, h11 }, { h00, h01 }, { h01, h11 }, { h00, h10 } };
                        for (int i = 0; i < 4; ++i) {
                            const int nx = x + DX[i], nz = z + DZ[i];
                            const Cell &n = wcell(nx, b, nz);
                            int cover;
                            if (c_cap(n) <= 0) continue;
                            if (c_wet(n) && c_fluid(n) == f) cover = top_plates(nx, b, nz, n);
                            else cover = b * 3 + floor_of(n.solid);
                            const float lo = (float)std::max(cover, bottom);
                            const float t0 = ch[i][0], t1 = ch[i][1];
                            if (std::max(t0, t1) <= lo + 0.01f) continue;
                            const float y0 = lo * P;
                            const float ya = std::max(t0, lo) * P - sink, yb = std::max(t1, lo) * P - sink;
                            Vector3 p0, p1;
                            if (i == 0) { p0 = Vector3(x1, 0, z0); p1 = Vector3(x1, 0, z1); }
                            else if (i == 1) { p0 = Vector3(x0, 0, z0); p1 = Vector3(x0, 0, z1); }
                            else if (i == 2) { p0 = Vector3(x0, 0, z1); p1 = Vector3(x1, 0, z1); }
                            else { p0 = Vector3(x0, 0, z0); p1 = Vector3(x1, 0, z0); }
                            const Vector3 nrm((float)DX[i], 0.0f, (float)DZ[i]);
                            m.quad(Vector3(p0.x, y0, p0.z), Vector3(p1.x, y0, p1.z),
                                    Vector3(p1.x, yb, p1.z), Vector3(p0.x, ya, p0.z), nrm, cc);
                        }
                        // Bottom over open air (a fall seen from under it).
                        if (floor_of(c.solid) == 0) {
                            const Cell &d = wcell(x, b - 1, z);
                            if (!(c_wet(d) && c_fluid(d) == f) && !(d.solid & 4)) {
                                const float y = (float)(b * 3) * P;
                                m.quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1),
                                        Vector3(x0, y, z1), Vector3(0, -1, 0), cc);
                            }
                        }
                    }
                }
                if (!any_flat) continue;
                // Greedy: along x as far as the same top goes, then down z as
                // far as whole rows of it go.
                bool used[SX * SX] = {};
                auto same = [&](int i, const Top &t) {
                    return flat[i].on && !used[i] && flat[i].f == t.f && flat[i].h == t.h && flat[i].c == t.c;
                };
                for (int lz = 0; lz < SX; ++lz) {
                    for (int lx = 0; lx < SX; ++lx) {
                        const int i0 = lx + SX * lz;
                        if (!flat[i0].on || used[i0]) continue;
                        const Top t = flat[i0];
                        int w = 1;
                        while (lx + w < SX && same(lx + w + SX * lz, t)) ++w;
                        int h = 1;
                        while (lz + h < SX) {
                            bool row = true;
                            for (int k = 0; k < w && row; ++k) row = same(lx + k + SX * (lz + h), t);
                            if (!row) break;
                            ++h;
                        }
                        for (int dz = 0; dz < h; ++dz) {
                            for (int dx = 0; dx < w; ++dx) used[lx + dx + SX * (lz + dz)] = true;
                        }
                        const float x0 = (float)(tx * SX + lx) * STUD_M, x1 = (float)(tx * SX + lx + w) * STUD_M;
                        const float z0 = (float)(tz * SX + lz) * STUD_M, z1 = (float)(tz * SX + lz + h) * STUD_M;
                        const float y = t.h * PLATE_M - TOP_SINK;
                        buf[t.f].quad(Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
                                Vector3(0, 1, 0), t.c);
                    }
                }
            }
        }
    }
    water = buf[F_WATER].arrays();
    lava = buf[F_LAVA].arrays();
}

/// The far mesh of a tile (MineWater.md 8): one flat quad per 4 x 4 studs at
/// the highest water top in them, no sides. Past the sim ring water is frozen,
/// so this is built once when a tile leaves it. Open sea is the wave tiers'.
constexpr int FAR_B = 4;
void mesh_tile_far(int tx, int tz, Array &water, Array &lava) {
    MeshBuf buf[3];
    auto it = g_tile_secs.find(tkey(tx, tz));
    if (it != g_tile_secs.end()) {
        std::vector<int> sbs = it->second;
        std::sort(sbs.begin(), sbs.end());
        for (int bz = 0; bz < SX; bz += FAR_B) {
            for (int bx = 0; bx < SX; bx += FAR_B) {
                int top = INT32_MIN, fl = 0, depth = 0;
                for (int lz = bz; lz < bz + FAR_B; ++lz) {
                    for (int lx = bx; lx < bx + FAR_B; ++lx) {
                        const int x = tx * SX + lx, z = tz * SX + lz;
                        for (int si = (int)sbs.size() - 1; si >= 0; --si) {
                            Section *s = sec_find(tx, sbs[si], tz);
                            if (s == nullptr || s->wet <= 0 || !s->ready[lx + SX * lz]) continue;
                            bool found = false;
                            for (int lb = SB - 1; lb >= 0; --lb) {
                                const Cell &c = s->c[Section::idx(lx, lb, lz)];
                                if (!c_wet(c)) continue;
                                const int b = sbs[si] * SB + lb;
                                const int t = top_plates(x, b, z, c);
                                if (c_ocean(c) && t == g_sea_b * 3) { found = true; break; }
                                if (t > top) { top = t; fl = c_fluid(c); depth = c.amt; }
                                found = true;
                                break;
                            }
                            if (found) break;
                        }
                    }
                }
                if (top == INT32_MIN) continue;
                const float x0 = (float)(tx * SX + bx) * STUD_M, x1 = (float)(tx * SX + bx + FAR_B) * STUD_M;
                const float z0 = (float)(tz * SX + bz) * STUD_M, z1 = (float)(tz * SX + bz + FAR_B) * STUD_M;
                const float y = (float)top * PLATE_M - TOP_SINK;
                const Color cc(std::min(1.0f, (float)(depth + 3) / 12.0f), 0.0f, 0.5f, 0.5f);
                buf[fl].quad(Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
                        Vector3(0, 1, 0), cc);
            }
        }
    }
    water = buf[F_WATER].arrays();
    lava = buf[F_LAVA].arrays();
}

int tile_coord(int64_t k, bool z) {
    const int64_t v = z ? (k & 0xFFFFFFF) : ((k >> 28) & 0xFFFFFFF);
    return (int)((v & 0x8000000) ? (v | ~(int64_t)0xFFFFFFF) : v);
}

// --- the tick ------------------------------------------------------------------------

void do_tick() {
    const auto t0 = std::chrono::steady_clock::now();
    g_last_columns = 0;
    g_sample_ms = 0.0;
    ++g_tick;
    g_seek.clear();
    std::vector<Cmd> cmds;
    {
        std::lock_guard<std::mutex> lk(g_cmd_mx);
        cmds.swap(g_cmds);
    }
    for (const Cmd &c : cmds) apply_cmd(c);

    // The player moved: frozen wakes in reach again.
    {
        const double dx = g_cx - g_recheck_x, dz = g_cz - g_recheck_z;
        if (dx * dx + dz * dz > 64.0 && !g_frozen.empty()) {
            g_recheck_x = g_cx;
            g_recheck_z = g_cz;
            std::vector<int64_t> back;
            for (int64_t k : g_frozen) {
                int x, b, z;
                unpack3(k, x, b, z);
                if (dist2_centre(x, z) <= g_sim_r * g_sim_r) back.push_back(k);
            }
            for (int64_t k : back) {
                g_frozen.erase(k);
                int x, b, z;
                unpack3(k, x, b, z);
                wake(x, b, z);
            }
        } else if (dx * dx + dz * dz > 64.0) {
            g_recheck_x = g_cx;
            g_recheck_z = g_cz;
        }
    }

    std::vector<int64_t> due;
    due.swap(g_due);
    if (lava_tick() && !g_due_lava.empty()) {
        due.insert(due.end(), g_due_lava.begin(), g_due_lava.end());
        g_due_lava.clear();
    }
    std::vector<int64_t> timers;
    while (!g_timers.empty() && g_timers.begin()->first <= g_tick) {
        timers.push_back(g_timers.begin()->second);
        g_timers.erase(g_timers.begin());
    }
    g_sets.clear();
    g_moves.clear();
    g_defer_lava.clear();
    // Timers first: of two writes to one cell in a tick the first is kept, and
    // a cell's own edge-distance update must not swallow its drying.
    for (int64_t k : timers) {
        int x, b, z;
        unpack3(k, x, b, z);
        eval_timer(x, b, z);
    }
    std::vector<int64_t> over;
    int evals = 0;
    // Over the budget: the nearest the player first, the far ones wait (6).
    if (due.size() > (size_t)MAX_EVALS) {
        auto d2 = [](int64_t k) { int x, b, z; unpack3(k, x, b, z); return dist2_centre(x, z); };
        std::nth_element(due.begin(), due.begin() + MAX_EVALS, due.end(),
                [&](int64_t a, int64_t c) { return d2(a) < d2(c); });
    }
    for (int64_t k : due) {
        int x, b, z;
        unpack3(k, x, b, z);
        const int sx = fdiv(x, SX), sb = fdiv(b, SB), sz = fdiv(z, SX);
        Section *s = sec_find(sx, sb, sz);
        if (s != nullptr) {
            uint8_t &q = s->queued[Section::idx(x - sx * SX, b - sb * SB, z - sz * SX)];
            if (evals >= MAX_EVALS) { over.push_back(k); continue; }
            q = 0;
        }
        ++evals;
        eval(x, b, z);
    }

    // Apply (MineWater.md 4.2: sets first, then the moves that still hold).
    std::unordered_set<int64_t> set_now;
    std::unordered_set<int64_t> by_op;
    {
        std::lock_guard<std::recursive_mutex> lk(g_state);
        for (const SetOp &o : g_sets) {
            const int64_t k = pack3(o.x, o.b, o.z);
            if (!by_op.insert(k).second) continue;
            set_now.insert(k);
            Cell n = o.c;
            write_cell(o.x, o.b, o.z, n);
        }
        for (const MoveOp &mv : g_moves) {
            if (by_op.count(pack3(mv.x, mv.b, mv.z))) continue;
            Cell src = wcell(mv.x, mv.b, mv.z);
            if (!c_wet(src) || c_kind(src) != K_STILL || c_fluid(src) != mv.fluid) continue;
            int n = std::min(mv.n, (int)src.amt);
            if (n <= 0) continue;
            Cell dst = wcell(mv.tx, mv.tb, mv.tz);
            if (c_wet(dst) && c_fluid(dst) != mv.fluid) continue;
            if (c_fed(dst)) {
                // Into running water or the sea: it joins the infinite body.
            } else {
                const int room = c_cap(dst) - (c_wet(dst) ? dst.amt : 0);
                n = std::min(n, room);
                if (n <= 0) continue;
                Cell nd = dst;
                nd.st = mk_st(mv.fluid, K_STILL, false);
                nd.amt = (uint8_t)((c_wet(dst) ? dst.amt : 0) + n);
                // A wet cell keeps its edge distance; a new one has none yet.
                nd.aux = c_wet(dst) && c_kind(dst) == K_STILL ? (uint8_t)c_edge(dst) : E_NONE;
                write_cell(mv.tx, mv.tb, mv.tz, nd);
                set_now.insert(pack3(mv.tx, mv.tb, mv.tz));
            }
            Cell ns = src;
            ns.amt = (uint8_t)(src.amt - n);
            ns.aux = (uint8_t)c_edge(src);
            write_cell(mv.x, mv.b, mv.z, ns);
            set_now.insert(pack3(mv.x, mv.b, mv.z));
        }
    }
    for (int64_t k : set_now) {
        int x, b, z;
        unpack3(k, x, b, z);
        wake_around(x, b, z);
    }
    for (int64_t k : over) g_due.push_back(k);
    for (int64_t k : g_defer_lava) {
        int x, b, z;
        unpack3(k, x, b, z);
        const int sx = fdiv(x, SX), sb = fdiv(b, SB), sz = fdiv(z, SX);
        Section *s = sec_find(sx, sb, sz);
        if (s == nullptr) continue;
        uint8_t &q = s->queued[Section::idx(x - sx * SX, b - sb * SB, z - sz * SX)];
        if (!q) { q = 1; g_due_lava.push_back(k); }
    }

    // Meshes for what changed, and what was asked for.
    const auto tm = std::chrono::steady_clock::now();
    for (int64_t k : g_mesh_requests) g_dirty_tiles.insert(k);
    g_mesh_requests.clear();
    int meshed = 0;
    std::vector<int64_t> left;
    for (int64_t k : g_dirty_tiles) {
        if (meshed >= MESH_PER_TICK) { left.push_back(k); continue; }
        const int tx = tile_coord(k, false);
        const int tz = tile_coord(k, true);
        MeshOut mo;
        mo.tx = tx;
        mo.tz = tz;
        mesh_tile(tx, tz, mo.water, mo.lava);
        g_out_meshes.push_back(mo);
        ++meshed;
    }
    g_dirty_tiles.clear();
    for (int64_t k : left) g_dirty_tiles.insert(k);
    std::vector<int64_t> far_left;
    for (int64_t k : g_far_requests) {
        if (meshed >= MESH_PER_TICK) { far_left.push_back(k); continue; }
        MeshOut mo;
        mo.tx = tile_coord(k, false);
        mo.tz = tile_coord(k, true);
        mo.far = true;
        mesh_tile_far(mo.tx, mo.tz, mo.water, mo.lava);
        g_out_meshes.push_back(mo);
        ++meshed;
    }
    g_far_requests.clear();
    for (int64_t k : far_left) g_far_requests.insert(k);

    g_last_mesh_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tm).count();
    g_last_evals = evals;
    g_last_changes = (int)set_now.size();
    g_last_changed.clear();
    for (int64_t k : set_now) {
        if (g_last_changed.size() >= 8) break;
        g_last_changed.push_back(k);
    }
    g_last_meshes = meshed;
    g_active = (int)(g_due.size() + g_due_lava.size());
    g_last_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

void join_if_done() {
    if (g_running.load() && g_done.load()) {
        if (g_thread.joinable()) g_thread.join();
        g_running = false;
        g_have_results = true;
    }
}

void join_wait() {
    if (g_running.load()) {
        if (g_thread.joinable()) g_thread.join();
        g_running = false;
        g_have_results = true;
    }
}

void push_cmd(const Cmd &c) {
    std::lock_guard<std::mutex> lk(g_cmd_mx);
    g_cmds.push_back(c);
}

} // namespace

// --- the class boundary ----------------------------------------------------------------

double BrickFluid::reset(double sea_m, bool sea_on) {
    join_wait();
    std::lock_guard<std::recursive_mutex> lk(g_state);
    g_sec.clear();
    g_sec_epoch.fetch_add(1);
    g_tile_secs.clear();
    g_due.clear();
    g_due_lava.clear();
    g_timers.clear();
    g_frozen.clear();
    g_dirty_tiles.clear();
    g_mesh_requests.clear();
    g_far_requests.clear();
    {
        std::lock_guard<std::mutex> lc(g_cmd_mx);
        g_cmds.clear();
    }
    g_out_meshes.clear();
    g_out_terrain.clear();
    g_have_results = false;
    g_acc = 0.0;
    g_tick = 0;
    g_sea_on = sea_on;
    g_sea_b = (int)std::llround(sea_m / (double)(PLATE_M * 3.0f));
    {
        const GenParams &gp = gen_params();
        const bool gen = biomes_on();
        g_lava_b = gen && gp.lava_pools ? (int)std::floor((gp.sea_m + gp.lava_m) / (PLATE_M * 3.0f)) : INT_MIN;
        g_springs = gen && gp.springs;
        g_spring_cut = (uint32_t)std::min(4294967295.0, std::max(0.0, (double)gp.spring_chance * 4294967296.0));
    }
    g_sea_m = (double)g_sea_b * (double)(PLATE_M * 3.0f);
    ++g_mask_version;
    return g_sea_m;
}

double BrickFluid::get_sea_level() { return g_sea_m; }
int BrickFluid::get_sea_course() { return g_sea_b; }
bool BrickFluid::get_sea_on() { return g_sea_on; }

void BrickFluid::set_centre(Vector3 at, double sim_radius_m) {
    g_cx = at.x;
    g_cz = at.z;
    g_sim_r = std::max(8.0, sim_radius_m);
}

void BrickFluid::set_sloped(bool on) {
    g_sloped = on;
}
bool BrickFluid::get_sloped() { return g_sloped; }

void BrickFluid::terrain_changed(Vector3i lo, Vector3i hi) {
    Cmd c;
    c.type = 0;
    c.a = Vector3i(std::min(lo.x, hi.x), std::min(lo.y, hi.y), std::min(lo.z, hi.z));
    c.b = Vector3i(std::max(lo.x, hi.x), std::max(lo.y, hi.y), std::max(lo.z, hi.z));
    if ((int64_t)(c.b.x - c.a.x + 1) * (c.b.z - c.a.z + 1) * (c.b.y - c.a.y + 1) > 400000) return;
    push_cmd(c);
}

void BrickFluid::place(Vector3i cell, int fluid, int kind, int amount) {
    Cmd c;
    c.type = 1;
    c.a = cell;
    c.fluid = fluid;
    c.kind = kind == SOURCE ? K_SOURCE : K_STILL;
    c.amount = amount;
    push_cmd(c);
}

void BrickFluid::remove(Vector3i cell, int amount) {
    Cmd c;
    c.type = 2;
    c.a = cell;
    c.amount = amount;
    push_cmd(c);
}

bool BrickFluid::update(double delta) {
    join_if_done();
    if (g_have_results) return true;
    g_acc = std::min(g_acc + delta, 0.3);
    if (!g_running.load() && g_acc >= TICK_S) {
        g_acc -= TICK_S;
        g_done = false;
        g_running = true;
        g_thread = std::thread([]() {
            do_tick();
            g_done = true;
        });
    }
    return false;
}

Dictionary BrickFluid::take() {
    join_if_done();
    Dictionary out;
    Array meshes;
    PackedInt32Array terr;
    bool mask = false;
    if (g_have_results && !g_running.load()) {
        for (const MeshOut &m : g_out_meshes) {
            Dictionary d;
            d["tile"] = Vector2i(m.tx, m.tz);
            d["water"] = m.water;
            d["lava"] = m.lava;
            d["far"] = m.far;
            meshes.append(d);
        }
        for (int32_t v : g_out_terrain) terr.push_back(v);
        mask = g_out_mask;
        g_out_meshes.clear();
        g_out_terrain.clear();
        g_out_mask = false;
        g_have_results = false;
        if (mask) ++g_mask_version;
    }
    out["meshes"] = meshes;
    out["terrain"] = terr;
    out["mask_changed"] = mask;
    return out;
}

void BrickFluid::tick_now(int ticks) {
    join_wait();
    for (int i = 0; i < ticks; ++i) do_tick();
    g_have_results = true;
}

bool BrickFluid::busy() { return g_running.load(); }

Dictionary BrickFluid::build_tile_mesh(int tx, int tz) {
    join_wait();
    Dictionary d;
    Array w, l;
    mesh_tile(tx, tz, w, l);
    d["water"] = w;
    d["lava"] = l;
    return d;
}

void BrickFluid::prime_tile(int tx, int tz) {
    Cmd c;
    c.type = 7;
    c.a = Vector3i(tx, 0, tz);
    push_cmd(c);
}

bool BrickFluid::has_generated() { return g_lava_b != INT_MIN || g_springs; }

void BrickFluid::request_far_mesh(int tx, int tz) {
    Cmd c;
    c.type = 6;
    c.a = Vector3i(tx, 0, tz);
    push_cmd(c);
}

void BrickFluid::request_mesh(int tx, int tz) {
    Cmd c;
    c.type = 4;
    c.a = Vector3i(tx, 0, tz);
    push_cmd(c);
}

Array BrickFluid::drawn_tiles() {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    Array out;
    for (const auto &e : g_tile_secs) {
        bool any = false;
        for (int sb : e.second) {
            Section *s = sec_find(tile_coord(e.first, false), sb, tile_coord(e.first, true));
            if (s != nullptr && s->wet > 0) { any = true; break; }
        }
        if (any) out.append(Vector2i(tile_coord(e.first, false), tile_coord(e.first, true)));
    }
    return out;
}

Vector3i BrickFluid::cell_of(Vector3 p) {
    return Vector3i((int)std::floor(p.x / STUD_M), (int)std::floor(p.y / (PLATE_M * 3.0f)),
            (int)std::floor(p.z / STUD_M));
}

Dictionary BrickFluid::cell_info(Vector3i cell) {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    const Cell c = rcell(cell.x, cell.y, cell.z);
    Dictionary d;
    d["fluid"] = c_wet(c) ? c_fluid(c) : 0;
    d["kind"] = c_kind(c);
    d["amount"] = (int)c.amt;
    d["dist"] = c_dist(c);
    d["solid"] = (int)c.solid;
    d["ocean"] = c_ocean(c);
    d["capacity"] = c_cap(c);
    return d;
}

int BrickFluid::fluid_at(Vector3 p) {
    const Vector3i k = cell_of(p);
    std::lock_guard<std::recursive_mutex> lk(g_state);
    const Cell c = rcell(k.x, k.y, k.z);
    if (!c_wet(c)) return 0;
    const double top = (double)(k.y * 3 + floor_of(c.solid) + c.amt) * PLATE_M;
    const Cell a = rcell(k.x, k.y + 1, k.z);
    if (p.y < top || (c_wet(a) && c_fluid(a) == c_fluid(c))) return c_fluid(c);
    return 0;
}

double BrickFluid::surface_at(Vector3 p) {
    const Vector3i k = cell_of(p);
    std::lock_guard<std::recursive_mutex> lk(g_state);
    Cell c = rcell(k.x, k.y, k.z);
    if (!c_wet(c)) {
        // Just above a shallow cell: its top is still the surface here.
        return -INFINITY;
    }
    const int f = c_fluid(c);
    int b = k.y;
    for (int i = 0; i < 64; ++i) {
        const Cell a = rcell(k.x, b + 1, k.z);
        if (!(c_wet(a) && c_fluid(a) == f)) break;
        c = a;
        ++b;
    }
    const double top = (double)(b * 3 + floor_of(c.solid) + c.amt) * PLATE_M;
    if (b == k.y && p.y > top) return -INFINITY;
    return top;
}

Vector3 BrickFluid::flow_at(Vector3 p) {
    const Vector3i k = cell_of(p);
    std::lock_guard<std::recursive_mutex> lk(g_state);
    const Cell c = rcell(k.x, k.y, k.z);
    if (!c_wet(c)) return Vector3();
    if (c_kind(c) == K_FALL) return Vector3(0, -2.0f, 0);
    if (c_kind(c) != K_FLOW) return Vector3();
    float fx = 0, fz = 0;
    for (int i = 0; i < 4; ++i) {
        const Cell n = rcell(k.x + DX[i], k.y, k.z + DZ[i]);
        int nd;
        if (c_wet(n) && c_fluid(n) == c_fluid(c)) nd = c_fed(n) ? c_dist(n) : c_dist(c) + 1;
        else if (c_cap(n) > 0) nd = c_dist(c) + 2;
        else continue;
        fx += (float)DX[i] * (float)(nd - c_dist(c));
        fz += (float)DZ[i] * (float)(nd - c_dist(c));
    }
    const float l = std::sqrt(fx * fx + fz * fz);
    if (l < 0.001f) return Vector3();
    const float speed = c_fluid(c) == F_LAVA ? 0.3f : 1.2f;
    return Vector3(fx / l * speed, 0, fz / l * speed);
}

Dictionary BrickFluid::ray_cell(Vector3 from, Vector3 dir, double max_metres) {
    Dictionary out;
    const Vector3 d = dir.normalized();
    if (d.length_squared() < 0.5f) return out;
    const double cs[3] = { STUD_M, PLATE_M * 3.0, STUD_M };
    const double o[3] = { from.x, from.y, from.z };
    const double v[3] = { d.x, d.y, d.z };
    int c[3], step[3];
    double tmax[3], tdel[3];
    for (int i = 0; i < 3; ++i) {
        c[i] = (int)std::floor(o[i] / cs[i]);
        step[i] = v[i] > 0 ? 1 : -1;
        if (std::abs(v[i]) < 1e-9) { tmax[i] = 1e30; tdel[i] = 1e30; continue; }
        const double next = (double)(c[i] + (v[i] > 0 ? 1 : 0)) * cs[i];
        tmax[i] = (next - o[i]) / v[i];
        tdel[i] = cs[i] / std::abs(v[i]);
    }
    std::lock_guard<std::recursive_mutex> lk(g_state);
    double t = 0.0;
    Vector3i nrm;
    for (int it = 0; it < 400 && t <= max_metres; ++it) {
        const Cell cl = rcell(c[0], c[1], c[2]);
        const bool hit_fluid = c_wet(cl);
        const bool hit_ground = cl.solid != 0 && !hit_fluid;
        if (hit_fluid || hit_ground) {
            out["cell"] = Vector3i(c[0], c[1], c[2]);
            out["normal"] = nrm;
            out["fluid"] = hit_fluid ? c_fluid(cl) : 0;
            out["kind"] = c_kind(cl);
            out["amount"] = (int)cl.amt;
            out["ocean"] = c_ocean(cl);
            out["position"] = from + d * (float)t;
            return out;
        }
        int a = 0;
        if (tmax[1] < tmax[a]) a = 1;
        if (tmax[2] < tmax[a]) a = 2;
        t = tmax[a];
        tmax[a] += tdel[a];
        c[a] += step[a];
        nrm = Vector3i(0, 0, 0);
        if (a == 0) nrm.x = -step[0];
        else if (a == 1) nrm.y = -step[1];
        else nrm.z = -step[2];
    }
    return out;
}

PackedByteArray BrickFluid::sea_mask(int x0, int z0, int size) {
    PackedByteArray out;
    size = std::max(1, std::min(size, 2048));
    out.resize((int64_t)size * size * 2);
    uint8_t *w = out.ptrw();
    std::vector<float> dist((size_t)size * size, 1.0e9f);
    for (int i = 0; i < size * size; ++i) { w[i * 2] = 0; w[i * 2 + 1] = 255; }
    const int cb = g_sea_b - 1;
    std::lock_guard<std::recursive_mutex> lk(g_state);
    bool any = false;
    for (int tz = fdiv(z0, SX); tz <= fdiv(z0 + size - 1, SX); ++tz) {
        for (int tx = fdiv(x0, SX); tx <= fdiv(x0 + size - 1, SX); ++tx) {
            auto it = g_tile_secs.find(tkey(tx, tz));
            if (it == g_tile_secs.end()) continue;
            for (int lz = 0; lz < SX; ++lz) {
                for (int lx = 0; lx < SX; ++lx) {
                    const int x = tx * SX + lx, z = tz * SX + lz;
                    const int ix = x - x0, iz = z - z0;
                    if (ix < 0 || iz < 0 || ix >= size || iz >= size) continue;
                    // The courses round the sea's top: calm water there, or a
                    // sea column that is no longer open sea.
                    bool calm = false, changed = false;
                    for (int b = cb - 1; b <= cb + 1; ++b) {
                        Section *s = sec_find(tx, fdiv(b, SB), tz);
                        if (s == nullptr || !s->ready[lx + SX * lz]) continue;
                        const Cell &c = s->c[Section::idx(lx, b - s->sb * SB, lz)];
                        if (c_wet(c) && !c_ocean(c)) calm = true;
                        if (b == cb && s->gtop[lx + SX * lz] + 1 < g_sea_b && !(c_wet(c) && c_ocean(c))) {
                            changed = true;
                        }
                    }
                    const size_t k = (size_t)iz * size + ix;
                    if (changed) w[k * 2] = 255;
                    if (calm || changed) { dist[k] = 0.0f; any = true; }
                }
            }
        }
    }
    if (!any) return out;
    const float D2 = 1.41421356f;
    for (int iz = 0; iz < size; ++iz) {
        for (int ix = 0; ix < size; ++ix) {
            float &v = dist[(size_t)iz * size + ix];
            if (ix > 0) v = std::min(v, dist[(size_t)iz * size + ix - 1] + 1.0f);
            if (iz > 0) {
                v = std::min(v, dist[(size_t)(iz - 1) * size + ix] + 1.0f);
                if (ix > 0) v = std::min(v, dist[(size_t)(iz - 1) * size + ix - 1] + D2);
                if (ix + 1 < size) v = std::min(v, dist[(size_t)(iz - 1) * size + ix + 1] + D2);
            }
        }
    }
    for (int iz = size - 1; iz >= 0; --iz) {
        for (int ix = size - 1; ix >= 0; --ix) {
            float &v = dist[(size_t)iz * size + ix];
            if (ix + 1 < size) v = std::min(v, dist[(size_t)iz * size + ix + 1] + 1.0f);
            if (iz + 1 < size) {
                v = std::min(v, dist[(size_t)(iz + 1) * size + ix] + 1.0f);
                if (ix + 1 < size) v = std::min(v, dist[(size_t)(iz + 1) * size + ix + 1] + D2);
                if (ix > 0) v = std::min(v, dist[(size_t)(iz + 1) * size + ix - 1] + D2);
            }
        }
    }
    for (size_t k = 0; k < dist.size(); ++k) {
        const float t = std::max(0.0f, std::min(1.0f, (dist[k] - 1.0f) / 13.0f));
        const float s = t * t * (3.0f - 2.0f * t);
        w[k * 2 + 1] = (uint8_t)std::lround(s * 255.0f);
    }
    return out;
}

int BrickFluid::changed_columns() { return g_mask_version; }

Dictionary BrickFluid::stats() {
    Dictionary d;
    d["tick_ms"] = g_last_ms;
    d["mesh_ms"] = g_last_mesh_ms;
    d["sample_ms"] = g_sample_ms;
    Array ch;
    for (int64_t k : g_last_changed) {
        int x, b, z;
        unpack3(k, x, b, z);
        ch.append(Vector3i(x, b, z));
    }
    d["changed"] = ch;
    d["evals"] = g_last_evals;
    d["changes"] = g_last_changes;
    d["columns"] = g_last_columns;
    d["meshes"] = g_last_meshes;
    d["active"] = g_active;
    d["frozen"] = (int)g_frozen.size();
    d["timers"] = (int)g_timers.size();
    d["sections"] = section_count();
    d["tick"] = (int64_t)g_tick;
    return d;
}

int BrickFluid::active_count() { return g_active; }

int BrickFluid::section_count() {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    return (int)g_sec.size();
}

int64_t BrickFluid::still_units(int fluid) {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    int64_t n = 0;
    for (const auto &e : g_sec) {
        const Section &s = *e.second;
        if (s.wet <= 0) continue;
        for (const Cell &c : s.c) {
            if (c_wet(c) && c_kind(c) == K_STILL && c_fluid(c) == fluid) n += c.amt;
        }
    }
    return n;
}

// Save: every cell that differs from the generated world, 15 bytes each:
// int32 x, course, z; uint8 st, amt, aux. Header "BCFL", format 1.
/// The difference from gen_fluid, cell by cell (MineWater.md 11). Never waits
/// for a running tick: the worker writes cells only under g_state, which is
/// held here, and columns it is still sampling are not ready yet (skipped:
/// nothing there was changed). Sections with nothing wet and no generated
/// fluid are skipped whole.
PackedByteArray BrickFluid::get_save() {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    std::vector<uint8_t> buf;
    const char *magic = "BCFL";
    buf.insert(buf.end(), magic, magic + 4);
    buf.push_back(1);
    auto put32 = [&](int32_t v) {
        for (int i = 0; i < 4; ++i) buf.push_back((uint8_t)((uint32_t)v >> (8 * i)));
    };
    for (const auto &e : g_sec) {
        const Section &s = *e.second;
        if (!s.written) continue;
        for (int lb = 0; lb < SB; ++lb) {
            for (int lz = 0; lz < SX; ++lz) {
                for (int lx = 0; lx < SX; ++lx) {
                    if (!s.ready[lx + SX * lz]) continue;
                    const Cell &c = s.c[Section::idx(lx, lb, lz)];
                    Cell g = c;
                    gen_fluid(g, s.sb * SB + lb, s.gtop[lx + SX * lz], s.spring[lx + SX * lz]);
                    const uint8_t aux = c.aux & 0x7F;
                    if (c.st == g.st && c.amt == g.amt) continue;
                    put32(s.sx * SX + lx);
                    put32(s.sb * SB + lb);
                    put32(s.sz * SX + lz);
                    buf.push_back(c.st);
                    buf.push_back(c.amt);
                    buf.push_back(aux);
                }
            }
        }
    }
    PackedByteArray out;
    out.resize((int64_t)buf.size());
    std::copy(buf.begin(), buf.end(), out.ptrw());
    return out;
}

int64_t BrickFluid::change_count() { return g_writes.load(); }

int BrickFluid::set_save(const PackedByteArray &bytes) {
    if (bytes.size() < 5) return 0;
    const uint8_t *r = bytes.ptr();
    if (r[0] != 'B' || r[1] != 'C' || r[2] != 'F' || r[3] != 'L' || r[4] != 1) return 0;
    auto get32 = [&](int64_t at) {
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= (uint32_t)r[at + i] << (8 * i);
        return (int32_t)v;
    };
    int n = 0;
    std::lock_guard<std::mutex> lk(g_cmd_mx);
    for (int64_t at = 5; at + 15 <= bytes.size(); at += 15) {
        Cmd c;
        c.type = 3;
        c.a = Vector3i(get32(at), get32(at + 4), get32(at + 8));
        c.st = r[at + 12];
        c.amt = r[at + 13];
        c.aux = r[at + 14];
        g_cmds.push_back(c);
        ++n;
    }
    return n;
}

void BrickFluid::_bind_methods() {
    BIND_CONSTANT(NONE);
    BIND_CONSTANT(WATER);
    BIND_CONSTANT(LAVA);
    BIND_CONSTANT(SOURCE);
    BIND_CONSTANT(FLOW);
    BIND_CONSTANT(FALL);
    BIND_CONSTANT(STILL);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("reset", "sea_m", "sea_on"), &BrickFluid::reset);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_sea_level"), &BrickFluid::get_sea_level);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_sea_course"), &BrickFluid::get_sea_course);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_sea_on"), &BrickFluid::get_sea_on);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_centre", "at", "sim_radius_m"), &BrickFluid::set_centre);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_sloped", "on"), &BrickFluid::set_sloped);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_sloped"), &BrickFluid::get_sloped);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("terrain_changed", "lo", "hi"), &BrickFluid::terrain_changed);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("place", "cell", "fluid", "kind", "amount"), &BrickFluid::place);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("remove", "cell", "amount"), &BrickFluid::remove);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("update", "delta"), &BrickFluid::update);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("take"), &BrickFluid::take);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("tick_now", "ticks"), &BrickFluid::tick_now);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("busy"), &BrickFluid::busy);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("build_tile_mesh", "tx", "tz"), &BrickFluid::build_tile_mesh);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("request_mesh", "tx", "tz"), &BrickFluid::request_mesh);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("drawn_tiles"), &BrickFluid::drawn_tiles);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("cell_info", "cell"), &BrickFluid::cell_info);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("cell_of", "p"), &BrickFluid::cell_of);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("fluid_at", "p"), &BrickFluid::fluid_at);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("surface_at", "p"), &BrickFluid::surface_at);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("flow_at", "p"), &BrickFluid::flow_at);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("ray_cell", "from", "dir", "max_metres"), &BrickFluid::ray_cell);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("request_far_mesh", "tx", "tz"), &BrickFluid::request_far_mesh);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("change_count"), &BrickFluid::change_count);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("prime_tile", "tx", "tz"), &BrickFluid::prime_tile);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("has_generated"), &BrickFluid::has_generated);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("sea_mask", "x0", "z0", "size"), &BrickFluid::sea_mask);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("changed_columns"), &BrickFluid::changed_columns);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("stats"), &BrickFluid::stats);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("active_count"), &BrickFluid::active_count);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("section_count"), &BrickFluid::section_count);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("still_units", "fluid"), &BrickFluid::still_units);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_save"), &BrickFluid::get_save);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_save", "bytes"), &BrickFluid::set_save);
}
