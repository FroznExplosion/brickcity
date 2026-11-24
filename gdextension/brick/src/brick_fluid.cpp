#include "brick_fluid.h"

#include "brick_terrain.h"
#include "terrain_biomes.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/time.hpp>
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

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <dbghelp.h>
#include <cstdio>
#pragma comment(lib, "dbghelp.lib")
#endif

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
constexpr int SEA_REACH = 2;       ///< studs water runs out over the open sea
constexpr int DROP_SEEK = 5;        ///< studs flowing water looks for a drop (4.1.5)
constexpr int MESH_PER_TICK = 24;
constexpr float TOP_SINK = 0.015f;  ///< tops a hair under the course: no z-fight with ground tops

enum { K_SOURCE = 0, K_FLOW = 1, K_FALL = 2, K_STILL = 3 };
enum { F_NONE = 0, F_WATER = 1, F_LAVA = 2 };

struct FluidDef {
    int reach;      ///< the last distance that still holds water
    int split;      ///< lava: distances up to this are 2 plates deep, past it 1
    bool renew;     ///< two sources make a third (4.1.7)
    bool dries;     ///< a lone unit of still fluid dries (4.2.3)
};
const FluidDef DEFS[3] = { { 0, 0, false, false }, { 5, 0, true, true }, { 6, 3, false, false } };

struct Cell {
    uint8_t solid = 0;   ///< bit per plate (0 bottom), from the terrain
    uint8_t st = 0;      ///< fluid (2 bits) | kind << 2 | ocean << 4
    uint8_t amt = 0;     ///< units of fluid (half plates), 0..CU
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
/// Fluid is counted in UNITS, half a plate (a half tile; the user,
/// 2026-11-23): six to a brick course. The terrain stays in plates.
constexpr int U = 2;                 ///< units a plate
constexpr int CU = 3 * U;            ///< units a course
constexpr float UNIT_M = PLATE_M / (float)U;
inline int floor_u(uint8_t m) { return floor_of(m) * U; }
inline bool c_wet(const Cell &c) { return c_fluid(c) != F_NONE && c.amt > 0; }
inline bool c_fed(const Cell &c) { return c_wet(c) && c_kind(c) != K_STILL; }
inline int c_cap(const Cell &c) { return CU - floor_u(c.solid); }
inline int c_dist(const Cell &c) { return c_kind(c) == K_FLOW ? (int)c.aux : 0; }
/// Running fluid's depth `d` studs from its source, in units. Water: half a
/// tile less a stud, 5 to 1 (a source is a brick, 6): it ends half a tile
/// deep 5 studs out (the user, 2026-11-23; was 2 plates to 7, 1 to 14).
/// Lava as before: 2 plates to 3 studs, 1 to 6.
inline int flow_level(int f, int d) {
    if (f == F_WATER) return std::max(1, CU - d);
    return d <= DEFS[f].split ? 2 * U : U;
}
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
    std::vector<int16_t> lake;      ///< per column: a lake's top course, or NO_SPRING
    /// per column, the section holding the sea's top course: its sea top is
    /// drawn by the fluid mesher (the real band), so the wave tiers leave it
    /// out (sea_mask). Empty until the mesher first sets one.
    std::vector<uint8_t> real;
    bool written = false;           ///< any cell ever written (the save skips the rest)
    std::vector<uint8_t> queued;    ///< per cell: in the next tick's list
    int wet = 0;                    ///< wet cells (for "anything to draw")
    /// Wet LAVA cells: the terrain's block light (lava_cells_in) reads only
    /// sections with some. The bakes read it under g_state while sample_into
    /// adds to it without: atomic.
    std::atomic<int> lava{ 0 };
    static int idx(int lx, int lb, int lz) { return lx + SX * (lz + SX * lb); }
};

std::unordered_map<int64_t, std::unique_ptr<Section>> g_sec;
std::unordered_map<int64_t, std::vector<int>> g_tile_secs;   ///< tile -> section courses
std::recursive_mutex g_state;
std::mutex g_cmd_mx;

/// What the main thread waits for g_state (the worker holds it while it
/// writes a tick's results): the worst wait since stats() last asked, and the
/// waits over a millisecond. CLAUDE.md: no waiting on a worker during play --
/// this says how much of it is left (stats: main_wait_ms, main_waits_1ms).
std::atomic<int64_t> g_main_wait_worst_us{ 0 };
std::atomic<int> g_main_waits_1ms{ 0 };
/// The worker's hold of g_state in a tick's apply step, ms.
double g_apply_ms = 0.0;

/// g_state for the main thread's questions (surface_at, flow_at ...), timed.
struct MainLock {
    std::unique_lock<std::recursive_mutex> lk;
    MainLock() : lk(g_state, std::defer_lock) {
        if (lk.try_lock()) return;
        const auto t0 = std::chrono::steady_clock::now();
        lk.lock();
        const int64_t us = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - t0).count();
        int64_t w = g_main_wait_worst_us.load(std::memory_order_relaxed);
        while (us > w && !g_main_wait_worst_us.compare_exchange_weak(w, us)) {}
        if (us >= 1000) g_main_waits_1ms.fetch_add(1, std::memory_order_relaxed);
    }
};

double g_sea_m = 0.0;
int g_sea_b = 0;          ///< the first course ABOVE the sea
bool g_sea_on = false;
bool g_sloped = false;   ///< flat plate steps (the user, 2026-11-21); true = MC slopes
double g_cx = 0.0, g_cz = 0.0, g_sim_r = 90.0;
double g_recheck_x = 1e30, g_recheck_z = 1e30;

// THE REAL SEA (MineWater.md 11.8, 11.9): sea water within REAL_BAND studs
// of ground at the sea's top course -- a shore, a pier, a hole dug, a brick
// set in the open sea -- is drawn by this mesher like any water, waving with
// the tiers' own waves (the same shader code, the same numbers), and the
// tiers leave those studs out (sea_mask). The open sea stays the tiers'.
// Sea columns are read in a square of tiles round the player, a few tiles a
// tick, nearest first; the band is drawn only there.
constexpr int REAL_T = 4;             ///< tiles each way from the square's middle
constexpr int REAL_PRIME_PER_TICK = 3;
constexpr int REAL_BAND = 6;          ///< studs of sea drawn real off ground
bool g_real_sea = false;
int g_real_x = INT_MIN, g_real_z = 0;     ///< the square's middle tile
std::vector<int64_t> g_real_todo;

inline bool in_square(int tx, int tz, int cx, int cz) {
    return cx != INT_MIN && std::abs(tx - cx) <= REAL_T && std::abs(tz - cz) <= REAL_T;
}
/// May the sea's top be drawn as real water in this tile (its band)?
inline bool real_tile(int tx, int tz) {
    return g_real_sea && g_sea_on && in_square(tx, tz, g_real_x, g_real_z);
}
uint32_t g_tick = 0;

std::vector<int64_t> g_due;            ///< water (and anything) next tick
std::vector<int64_t> g_due_lava;       ///< waits for a lava tick
std::multimap<uint32_t, int64_t> g_timers;
std::unordered_set<int64_t> g_frozen;
/// Timers that came due past the sim radius: fired when back in reach.
std::unordered_set<int64_t> g_frozen_timers;
std::unordered_set<int64_t> g_dirty_tiles;
/// BLOCK LIGHT (Docs/MineWorld.md 18): lava cells in all sections, and the
/// terrain tiles whose light lava appearing or going may have changed (tile
/// -> first, last course), drained by take(). Its own lock: sample_into marks
/// without g_state.
std::atomic<int64_t> g_lava_total{ 0 };
std::mutex g_lava_mx;
std::unordered_map<int64_t, std::pair<int, int>> g_lava_dirty;
/// How far a lava cell's light reaches, in cells: 15 levels, plus one for
/// the terrain's eight-cell blend round a vertex.
constexpr int LAVA_REACH = 16;

/// Lava appeared or went over courses b0..b1 of column (x, z): every terrain
/// tile its light reaches is to be lit again.
void lava_mark(int x, int b0, int b1, int z) {
    const int tx0 = fdiv(x - LAVA_REACH, SX), tx1 = fdiv(x + LAVA_REACH, SX);
    const int tz0 = fdiv(z - LAVA_REACH, SX), tz1 = fdiv(z + LAVA_REACH, SX);
    std::lock_guard<std::mutex> lk(g_lava_mx);
    for (int tz = tz0; tz <= tz1; ++tz) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            auto it = g_lava_dirty.find(tkey(tx, tz));
            if (it == g_lava_dirty.end()) {
                g_lava_dirty[tkey(tx, tz)] = { b0 - LAVA_REACH, b1 + LAVA_REACH };
            } else {
                it->second.first = std::min(it->second.first, b0 - LAVA_REACH);
                it->second.second = std::max(it->second.second, b1 + LAVA_REACH);
            }
        }
    }
}

inline bool c_lava(const Cell &c) { return c_wet(c) && c_fluid(c) == F_LAVA; }

std::unordered_set<int64_t> g_mesh_requests;
std::unordered_set<int64_t> g_far_requests;   ///< tiles wanting the coarse mesh
/// Pits filling from rivers (4.5, stage 8): falls that landed -> the tick
/// each is next looked at. Looked at every PIT_EVERY ticks while due, until
/// it stops being a fall. One found OPEN (its body spills somewhere) waits
/// PIT_OPEN_WAIT ticks before the next look: it used to stay due, so every
/// waterfall onto open ground was flood-filled (up to PIT_MAX cells) once a
/// second for good, wherever it was -- and only the first PIT_LOOKS in the
/// set's order were ever looked at, so past that many such falls a real pit
/// elsewhere never filled. Landings past the sim radius wait for the player.
std::unordered_map<int64_t, uint32_t> g_landings;
constexpr int PIT_EVERY = 10;
constexpr int PIT_LOOKS = 32;       ///< landings looked at a time
constexpr int PIT_MAX = 4096;       ///< cells a closed body may have
constexpr uint32_t PIT_OPEN_WAIT = 30;   ///< ticks before an open landing is looked at again

/// Multiplayer groundwork (MineWater.md 11.5): the cells whose drawn state
/// changed, with the write count at the time, kept while `g_log_on`. A peer
/// asks for what changed since the count it last had.
bool g_log_on = false;
std::vector<std::pair<int64_t, int64_t>> g_log;   ///< (write count, cell key)
int64_t g_log_floor = 0;            ///< asks from before this need everything
constexpr size_t LOG_MAX = 1 << 20;
/// A mirror (a client): commands and meshes, no rules of its own.
bool g_simulate = true;
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
    bool is_far = false;   ///< the coarse mesh (MineWater.md 8)
    double built_s = 0.0;  ///< its easing starts here (mesh_tile)
};
std::vector<MeshOut> g_out_meshes;
/// Blocks lava set alight (stage 9): per cell (x, plate, z) of a burnable
/// plate (wood, leaves) next to lava. The main thread burns them
/// (scripts/water/lava_fire.gd).
std::vector<int32_t> g_out_fire;

/// Burnable terrain plates in the six cells round a lava cell, alight.
void ignite_round(int x, int b, int z) {
    static const int NX[6] = { 1, -1, 0, 0, 0, 0 }, NB[6] = { 0, 0, 0, 0, 1, -1 }, NZ[6] = { 0, 0, 1, -1, 0, 0 };
    std::shared_lock<std::shared_mutex> rd(edit_lock());
    for (int i = 0; i < 6; ++i) {
        const int cx = x + NX[i], cb = b + NB[i], cz = z + NZ[i];
        for (int p = 0; p < 3; ++p) {
            const int m = edit_at(pack_cell(cx, cb * 3 + p, cz));
            if (m == MAT_WOOD || m == MAT_LEAVES) {
                g_out_fire.push_back(cx);
                g_out_fire.push_back(cb * 3 + p);
                g_out_fire.push_back(cz);
            }
        }
    }
}

/// Rock the fluids made, for the main thread to lay as terrain edits: per
/// cell (x, z, first plate, last plate, material) -- only the plates the lava
/// filled, so a tile of lava is a tile of rock.
std::vector<int32_t> g_out_terrain;

void out_rock(int x, int b, int z, const Cell &c, int mat) {
    const int lo = b * 3 + floor_of(c.solid);
    g_out_terrain.push_back(x);
    g_out_terrain.push_back(z);
    g_out_terrain.push_back(lo);
    g_out_terrain.push_back(lo + std::max(1, ((int)c.amt + U - 1) / U) - 1);
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
/// `gen_out`, when given, gets the masks as GENERATED (no edits): lava and
/// cave pools fill only air the world was generated with, not a hole dug.
void sample_column(int x, int z, int b0, int nb, uint8_t *out, int *gen_top, uint8_t *gen_out = nullptr) {
    // Shared with other readers, never with the main thread's edits (a race
    // on the map that crashed the water's thread).
    std::shared_lock<std::shared_mutex> rd(edit_lock());
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
            if (gen_out != nullptr) gen_out[i] = m;
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
        if (gen_out != nullptr) gen_out[i] = m;
    }
}

constexpr int NO_SPRING = -32000;
/// The water's own thread works cave pool regions out; the main thread only
/// reads what is already known (cave_pool_water's may_compute).
thread_local bool t_may_compute = false;
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

// --- lakes above the sea (stage 8): the generator's (terrain_biomes.cpp) ------

bool g_lakes = false;
bool g_pools = false;

/// The lake top over a column (its level course), or NO_SPRING.
int lake_course(int x, int z) {
    if (!g_lakes || !biomes_on()) return NO_SPRING;
    const int l = lake_level_at(gen_params(), (uint32_t)BrickTerrain::get_seed(), x, z);
    return l == INT_MIN ? NO_SPRING : l;
}

/// The fluid the world was generated with in a cell: the sea, lava pools
/// in caves deep down, springs out of cliff faces, lakes over the sea, cave
/// pools (MineWater.md 5, 9, 14.8).
inline void gen_fluid(Cell &cl, int x, int b, int z, int gen_top, int spring_b = NO_SPRING,
        int lake_b = NO_SPRING, bool gen_open = true) {
    cl.st = 0;
    cl.amt = 0;
    cl.aux = 0;
    const int cap = c_cap(cl);
    if (cap <= 0) return;
    if (g_sea_on && gen_top + 1 < g_sea_b && b > gen_top && b < g_sea_b) {
        cl.st = mk_st(F_WATER, K_SOURCE, true);
        cl.amt = (uint8_t)cap;
    } else if (b < g_lava_b && b < gen_top && gen_open) {
        // Air under the ground and under the lava line is a cave: lava.
        cl.st = mk_st(F_LAVA, K_SOURCE, false);
        cl.amt = (uint8_t)cap;
    } else if ((b == spring_b || b <= lake_b) && b > gen_top) {
        // A spring out of a cliff face, or a lake over its bed.
        cl.st = mk_st(F_WATER, K_SOURCE, false);
        cl.amt = (uint8_t)cap;
    } else if (g_pools && b < gen_top && gen_open
            && cave_pool_water(gen_params(), (uint32_t)BrickTerrain::get_seed(), x, b, z, t_may_compute) == 1) {
        // A cave pool: a closed pocket of cave air under its region's level.
        // STILL water, a real volume: broken into, it spills what it holds
        // and settles; it does not pour for ever.
        cl.st = mk_st(F_WATER, K_STILL, false);
        cl.amt = (uint8_t)cap;
    }
}

Cell gen_cell(int x, int b, int z) {
    Cell c;
    int gt = 0;
    uint8_t gm = 0;
    sample_column(x, z, b, 1, &c.solid, &gt, &gm);
    gen_fluid(c, x, b, z, gt, spring_course(x, z, gt), lake_course(x, z), gm != 7);
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
    ns->lake.assign(SCOL, NO_SPRING);
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
    uint8_t gmasks[SB];
    int gt = 0;
    const auto t0 = std::chrono::steady_clock::now();
    sample_column(x, z, s->sb * SB, SB, masks, &gt, gmasks);
    g_sample_ms += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    s->gtop[lx + SX * lz] = (int16_t)std::max(-32000, std::min(32000, gt));
    const int sp = spring_course(x, z, gt);
    s->spring[lx + SX * lz] = (int16_t)sp;
    const int lake = lake_course(x, z);
    s->lake[lx + SX * lz] = (int16_t)std::max(-32000, std::min(32000, lake));
    int lava = 0, lava_lo = INT_MAX, lava_hi = INT_MIN;
    for (int lb = 0; lb < SB; ++lb) {
        Cell &cl = s->c[Section::idx(lx, lb, lz)];
        cl.solid = masks[lb];
        gen_fluid(cl, x, s->sb * SB + lb, z, gt, sp, lake, gmasks[lb] != 7);
        if (c_wet(cl)) ++s->wet;
        if (c_lava(cl)) {
            ++lava;
            lava_lo = std::min(lava_lo, s->sb * SB + lb);
            lava_hi = std::max(lava_hi, s->sb * SB + lb);
        }
    }
    if (lava > 0) {
        s->lava.fetch_add(lava, std::memory_order_relaxed);
        g_lava_total.fetch_add(lava, std::memory_order_relaxed);
        lava_mark(x, lava_lo, lava_hi, z);
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
    const bool was_lava = c_lava(cl);
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
    const bool is_lava = c_lava(cl);
    if (is_lava != was_lava) {
        s->lava.fetch_add(is_lava ? 1 : -1, std::memory_order_relaxed);
        g_lava_total.fetch_add(is_lava ? 1 : -1, std::memory_order_relaxed);
        lava_mark(x, b, b, z);
    }
    s->written = true;
    if (!drawn_same) {
        mark_dirty(x, b, z);
        const int64_t w = g_writes.fetch_add(1, std::memory_order_relaxed) + 1;
        if (g_log_on) {
            if (g_log.size() >= LOG_MAX) {
                g_log.clear();
                g_log_floor = w;
            }
            g_log.push_back({ w, pack3(x, b, z) });
        }
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
    if (c_wet(d) && c_kind(d) != K_FALL && (floor_u(d.solid) + d.amt >= CU || c_kind(d) == K_SOURCE)) return true;
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
    if (cap <= 0) {
        if (c_wet(cur)) g_sets.push_back({ x, b, z, Cell{} });
        return;
    }
    // Lava meeting water, Minecraft's way, at once (not on lava's slow tick):
    // a lava SOURCE touched by water becomes obsidian, running lava stone.
    if (cf == F_LAVA && c_wet(cur)) {
        if (lt) ignite_round(x, b, z);

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
    if (cf == F_LAVA && !lt) {
        g_defer_lava.push_back(pack3(x, b, z));
        return;
    }
    // Still water lying on the open sea joins it (the sea is infinite: it
    // takes it in, a course at a time), instead of a sheet on top of it.
    if (g_sea_on && cf == F_WATER && c_wet(cur) && c_kind(cur) == K_STILL && b == g_sea_b
            && floor_of(cur.solid) == 0) {
        const Cell &dn = wcell(x, b - 1, z);
        if (c_wet(dn) && c_ocean(dn) && c_fluid(dn) == F_WATER) {
            g_sets.push_back({ x, b, z, Cell{ cur.solid, 0, 0, 0 } });
            return;
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
    const int my_floor = b * CU + floor_u(cur.solid);
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
        if (c_kind(n) == K_SOURCE && floor_u(n.solid) + n.amt >= CU) {
            ++sources[f];
            ocean_src = ocean_src || c_ocean(n);
        }
        if (f == F_LAVA && !lt) { deferred = true; continue; }
        if (c_kind(n) != K_SOURCE && !supported(nx, b, nz, n)) continue;
        // Running out over the open sea the sea takes it in: SEA_REACH studs,
        // not a stream's whole reach across the top of the ocean (the user,
        // 2026-11-23).
        if (g_sea_on && f == F_WATER && c_kind(n) == K_FLOW && c_dist(n) >= SEA_REACH && b == g_sea_b) {
            const Cell &nd = wcell(nx, b - 1, nz);
            if (c_wet(nd) && c_ocean(nd)) continue;
        }
        const int d = c_dist(n) + 1;
        const FluidDef &def = DEFS[f];
        if (d > def.reach || d > best_d) continue;
        if (c_kind(n) == K_FLOW || c_kind(n) == K_FALL) {
            // Toward the nearest drop: the way from n to here is i^1's reverse.
            const int back = (i == 0) ? 1 : (i == 1) ? 0 : (i == 2) ? 3 : 2;
            if (!(seek_dirs(nx, b, nz, n) & (1 << back))) continue;
        }
        const int lvl = flow_level(f, d);
        const int ntop = std::min(my_floor + lvl, b * CU + floor_u(n.solid) + n.amt);
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
    // Still water as deep as what would feed it, or deeper, stays still
    // (4.2.5 "whose top is lower"; stage 8): a river does not turn a pond
    // into a river, and a fall lands on a full pit as on ground, so the pit
    // can fill (pits_fill).
    if (best_fluid != 0 && best_kind != K_SOURCE && c_wet(cur) && c_kind(cur) == K_STILL
            && c_fluid(cur) == best_fluid && (int)cur.amt >= best_amt) {
        best_fluid = 0;
    }
    if (deferred && best_fluid == 0) {
        g_defer_lava.push_back(pack3(x, b, z));
    }
    if (best_fluid != 0 && best_kind == K_FALL) {
        // Where a fall meets ground or a full pit: a pit may be filling.
        const Cell &d = wcell(x, b - 1, z);
        if (floor_of(cur.solid) > 0 || (d.solid & 4)
                || (c_wet(d) && c_kind(d) == K_STILL && floor_u(d.solid) + d.amt >= CU)) {
            g_landings.emplace(pack3(x, b, z), g_tick);   // kept: an open one's wait stands
        }
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
            const int lvl = flow_level(cf, c_dist(cur));
            if ((int)cur.amt <= lvl) n.amt = 1;
        }
        g_sets.push_back({ x, b, z, n });
        return;
    }

    // --- still water: a volume in whole tiles (4.2)
    const int a = cur.amt;
    // Touching a SOURCE of its own fluid (the sea, a lake, a spring) it joins
    // it: a tile a tick drains into the infinite body (4.2.4).
    for (int i = 0; i < 4; ++i) {
        const Cell &n = wcell(x + DX[i], b, z + DZ[i]);
        if (c_wet(n) && c_fluid(n) == cf && c_kind(n) == K_SOURCE) {
            Cell k = cur;
            k.amt = (uint8_t)(a - 1);
            g_sets.push_back({ x, b, z, k });
            return;
        }
    }
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
    int s_top = b * CU + floor_u(cur.solid) + a;
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
            sn = b * CU + floor_u(n.solid) + n.amt;
        } else {
            sn = supported(nx, b, nz, n) ? b * CU + floor_u(n.solid) : b * CU - 1000;
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
            if (b * CU + floor_u(n.solid) + n.amt != s_top - 1 || c_edge(n) >= e_new) continue;
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
                // Any section already read keeps solid masks that must
                // follow the ground, wet or not: priming reads sections dry,
                // and a floor laid there later was air to the water.
                if (s != nullptr) return true;
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
    if (c.type == 11) {
        // The real sea on or off: every square forgotten, its tiles meshed again.
        const int rx = g_real_x, rz = g_real_z;
        g_real_sea = c.a.x != 0;
        g_real_x = INT_MIN;
        g_real_todo.clear();
        for (int dz = -REAL_T; dz <= REAL_T; ++dz) {
            for (int dx = -REAL_T; dx <= REAL_T; ++dx) {
                if (rx != INT_MIN) g_dirty_tiles.insert(tkey(rx + dx, rz + dz));
            }
        }
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
                if (g_lakes) {
                    const int lc = lake_course(x, z);
                    if (lc != NO_SPRING && c_wet(wcell(x, lc, z))) any = true;
                }
                if (g_pools && c.b.x <= c.b.y) {
                    const GenParams &gp = gen_params();
                    for (int ry = fdiv(c.b.x, AQ_Y); ry <= fdiv(c.b.y, AQ_Y); ++ry) {
                        const int lvl = cave_pool_level(gp, seed, x, ry * AQ_Y, z);
                        if (lvl == INT_MIN) continue;
                        // The pool's top course if this column holds any.
                        for (int yb = lvl; yb >= ry * AQ_Y; --yb) {
                            if (cave_pool_water(gp, seed, x, yb, z, true) == 1) {
                                if (c_wet(wcell(x, yb, z))) any = true;
                                break;
                            }
                        }
                    }
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
    if (c.type == 3 || c.type == 9) {
        Cell n = cur;
        n.st = c.st;
        n.amt = (uint8_t)std::min((int)c.amt, std::max(c_cap(cur), 0));
        n.aux = c.aux;
        write_cell(x, b, z, n);
        if (c.type == 3) wake_around(x, b, z);
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
        // Into another fluid's running (not source) cell: it takes its place,
        // as a bucket of water poured on running lava does in Minecraft.
        if (c_wet(cur) && c_fluid(cur) != f && c_kind(cur) == K_SOURCE) return;
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
    /// CUSTOM0 (RGBA float a vertex): x = how far below (+ above) its last
    /// mesh's place the vertex was, metres -- the shader eases from there to
    /// here over a tick, so water glides instead of jumping (no slide show).
    PackedFloat32Array cus;
    void quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d,
            const Vector3 &nrm, const Color &cc, float da = 0.0f, float db = 0.0f,
            float dc = 0.0f, float dd = 0.0f) {
        const int base = (int)v.size();
        v.push_back(a); v.push_back(b); v.push_back(c); v.push_back(d);
        for (int i = 0; i < 4; ++i) { n.push_back(nrm); col.push_back(cc); }
        for (float e : { da, db, dc, dd }) {
            cus.push_back(e); cus.push_back(0.0f); cus.push_back(0.0f); cus.push_back(0.0f);
        }
        idx.push_back(base); idx.push_back(base + 1); idx.push_back(base + 2);
        idx.push_back(base); idx.push_back(base + 2); idx.push_back(base + 3);
    }
    /// A real sea piece's face: CUSTOM0 y = 1 (sea); x, w the way from the
    /// vertex to its stud's middle in half studs (+-1) -- the shader rides
    /// the whole piece on the wave at that middle, as the tiers' pieces do.
    void sea_quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d,
            const Vector3 &nrm, const Color &cc, const Vector2 &mid) {
        const int base = (int)v.size();
        for (const Vector3 &p : { a, b, c, d }) {
            v.push_back(p);
            n.push_back(nrm);
            col.push_back(cc);
            cus.push_back(mid.x > p.x ? 1.0f : -1.0f);
            cus.push_back(1.0f);
            cus.push_back(0.0f);
            cus.push_back(mid.y > p.z ? 1.0f : -1.0f);
        }
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
        a[Mesh::ARRAY_CUSTOM0] = cus;
        a[Mesh::ARRAY_INDEX] = idx;
        return a;
    }
};

/// The top of a column's fluid at course b, in plates; full when there is
/// fluid in the course above.
inline int top_units(int x, int b, int z, const Cell &c) {
    const Cell &a = wcell(x, b + 1, z);
    if (c_wet(a) && c_fluid(a) == c_fluid(c)) return (b + 1) * CU;
    return b * CU + floor_u(c.solid) + c.amt;
}

/// A top corner: the mean of the tops round it that are open at this course.
/// A neighbour with more of its fluid over it (a pile still draining, a
/// fall's foot) is NOT counted: it used to snap the corner to a full brick,
/// so the thin water round a poured brick jumped up to a brick and back as
/// the pile went down (the user, 2026-11-20). The pile's own side covers the
/// step between them. A stacked cell itself is full at every corner.
float corner_h(int x, int b, int z, int cx, int cz, int fluid, int own) {
    if (!g_sloped) return (float)own;
    const int full = (b + 1) * CU;
    if (own >= full) {
        const Cell &a = wcell(x, b + 1, z);
        if (c_wet(a) && c_fluid(a) == fluid) return (float)full;
    }
    float sum = 0.0f;
    int n = 0;
    for (int dz = -1; dz <= 0; ++dz) {
        for (int dx = -1; dx <= 0; ++dx) {
            const int qx = cx + dx, qz = cz + dz;
            const Cell &q = (qx == x && qz == z) ? wcell(x, b, z) : wcell(qx, b, qz);
            if (!c_wet(q) || c_fluid(q) != fluid) continue;
            const Cell &qa = wcell(qx, b + 1, qz);
            if (c_wet(qa) && c_fluid(qa) == fluid && !(qx == x && qz == z)) continue;
            sum += (float)top_units(qx, b, qz, q);
            ++n;
        }
    }
    return n > 0 ? sum / (float)n : (float)own;
}

/// Each tile's top corners as last meshed, keyed by corner, course and
/// fluid: where it is (y, metres), how far it was eased from (off) and when
/// that mesh's easing started (t, the shader's clock: Time ticks, seconds).
/// The next mesh's vertices ease on from where the corner is DRAWN then, not
/// from where it was going: a tile meshed again mid-ease (water every tick)
/// snapped every rising cell to its full height -- the "jump" (the user,
/// 2026-11-23).
struct Ease { float y; float off; double t; };
std::unordered_map<int64_t, std::unordered_map<int64_t, Ease>> g_prev_tops;
/// How long a corner takes to reach a new height (water_fluid.gdshader
/// `ease_s`, set from ease_seconds()): about a tick of each fluid's, so a
/// running front creeps on instead of stepping (lava ticks every 5th).
constexpr float EASE_S[3] = { 0.1f, 0.2f, 0.5f };
inline double clock_s() { return (double)Time::get_singleton()->get_ticks_usec() / 1.0e6; }

/// The real band's tops of a tile. `top`: the studs whose water is open at
/// the sea's level (ocean or not); `ocean`: which of them are open sea. Each
/// stud's distance to ground (studs, Chebyshev, over the tile and a margin);
/// open sea is drawn within REAL_BAND of ground, other water at the sea's
/// level always. A quad a stud (shared corners: no cracks between them),
/// short sides on the band's outer edge where the tiers' pieces meet it.
/// Marks the drawn sea studs for the tiers' mask; true if any mark changed.
constexpr float SKIRT_M = 0.42f;   ///< a piece's sides, as deep as a brick
bool mesh_sea_tops(int tx, int tz, const bool *top, const bool *ocean, MeshBuf &m) {
    constexpr int M = REAL_BAND, W = SX + 2 * M, OUT_D = REAL_BAND + 1;
    uint8_t d[W * W];
    const int sb = g_sea_b - 1;
    for (int gz = 0; gz < W; ++gz) {
        for (int gx = 0; gx < W; ++gx) {
            const int lx = gx - M, lz = gz - M;
            bool wet;
            if (lx >= 0 && lz >= 0 && lx < SX && lz < SX) wet = top[lx + SX * lz];
            else {
                const int x = tx * SX + lx, z = tz * SX + lz;
                const Cell &c = wcell(x, sb, z);
                const Cell &a = wcell(x, sb + 1, z);
                wet = c_wet(c) && c_fluid(c) == F_WATER && c.amt >= c_cap(c) && c_cap(c) == CU
                        && !(c_wet(a) && c_fluid(a) == F_WATER);
            }
            d[gx + W * gz] = wet ? (uint8_t)OUT_D : 0;
        }
    }
    for (int gz = 0; gz < W; ++gz) {
        for (int gx = 0; gx < W; ++gx) {
            uint8_t &v = d[gx + W * gz];
            if (v == 0) continue;
            static const int OX[4] = { -1, 0, 1, -1 }, OZ[4] = { 0, -1, -1, -1 };
            for (int k = 0; k < 4; ++k) {
                const int nx = gx + OX[k], nz = gz + OZ[k];
                if (nx < 0 || nz < 0 || nx >= W) continue;
                v = (uint8_t)std::min<int>(v, d[nx + W * nz] + 1);
            }
        }
    }
    for (int gz = W - 1; gz >= 0; --gz) {
        for (int gx = W - 1; gx >= 0; --gx) {
            uint8_t &v = d[gx + W * gz];
            if (v == 0) continue;
            static const int OX[4] = { 1, 0, -1, 1 }, OZ[4] = { 0, 1, 1, 1 };
            for (int k = 0; k < 4; ++k) {
                const int nx = gx + OX[k], nz = gz + OZ[k];
                if (nx < 0 || nx >= W || nz >= W) continue;
                v = (uint8_t)std::min<int>(v, d[nx + W * nz] + 1);
            }
        }
    }
    auto dist = [&](int lx, int lz) -> int { return d[(lx + M) + W * (lz + M)]; };
    bool draw[SX * SX];
    for (int lz = 0; lz < SX; ++lz) {
        for (int lx = 0; lx < SX; ++lx) {
            const int i = lx + SX * lz;
            draw[i] = top[i] && (!ocean[i] || dist(lx, lz) <= REAL_BAND);
        }
    }
    // A piece a stud, as the tiers draw the sea: a flat top that rides the
    // wave at its middle (the shader), and four sides SKIRT_M deep -- the
    // risers between pieces at different heights.
    const float y = (float)(g_sea_b * 3) * PLATE_M - TOP_SINK;
    const Color cc(1.0f, 0.0f, 1.0f, 0.5f);   // b: sky level, open (sky_levels_into)
    const Vector3 dn(0.0f, SKIRT_M, 0.0f);
    for (int lz = 0; lz < SX; ++lz) {
        for (int lx = 0; lx < SX; ++lx) {
            if (!draw[lx + SX * lz]) continue;
            const float x0 = (float)(tx * SX + lx) * STUD_M, x1 = (float)(tx * SX + lx + 1) * STUD_M;
            const float z0 = (float)(tz * SX + lz) * STUD_M, z1 = (float)(tz * SX + lz + 1) * STUD_M;
            const Vector2 mid((x0 + x1) * 0.5f, (z0 + z1) * 0.5f);
            const Vector3 a(x0, y, z0), b(x0, y, z1), cq(x1, y, z1), d(x1, y, z0);
            m.sea_quad(a, b, cq, d, Vector3(0, 1, 0), cc, mid);
            m.sea_quad(d, cq, cq - dn, d - dn, Vector3(1, 0, 0), cc, mid);
            m.sea_quad(b, a, a - dn, b - dn, Vector3(-1, 0, 0), cc, mid);
            m.sea_quad(cq, b, b - dn, cq - dn, Vector3(0, 0, 1), cc, mid);
            m.sea_quad(a, d, d - dn, a - dn, Vector3(0, 0, -1), cc, mid);
        }
    }
    // The tiers' mask.
    bool changed = false;
    Section *ss = sec_find(tx, fdiv(sb, SB), tz);
    if (ss != nullptr) {
        if (ss->real.empty()) ss->real.assign(SX * SX, 0);
        for (int i = 0; i < SX * SX; ++i) {
            const uint8_t v = (draw[i] && ocean[i]) ? 1 : 0;
            if (ss->real[i] != v) { ss->real[i] = v; changed = true; }
        }
    }
    return changed;
}

/// A tile with no band now: its marks cleared. True if any were set.
bool clear_real_marks(int tx, int tz) {
    Section *ss = sec_find(tx, fdiv(g_sea_b - 1, SB), tz);
    if (ss == nullptr || ss->real.empty()) return false;
    bool any = false;
    for (uint8_t &v : ss->real) { if (v) { v = 0; any = true; } }
    return any;
}

double mesh_tile(int tx, int tz, Array &water, Array &lava) {
    MeshBuf buf[3];
    std::unordered_map<int64_t, Ease> &prev = g_prev_tops[tkey(tx, tz)];
    std::unordered_map<int64_t, Ease> now;
    const double t_now = clock_s();
    // Where a corner last meshed is drawn now (the shader's easing).
    auto shown = [&](const Ease &e, int f) -> float {
        const double k = std::min(1.0, std::max(0.0, (t_now - e.t) / (double)EASE_S[f]));
        return e.y + e.off * (float)(1.0 - k);
    };
    // Corner (ox, oz) (0 or 1) of cell (x, z)'s top, course b, fluid f, is at
    // y now; it was at prev (or, new, at `base`, so a new cell rises from its
    // floor). Keyed by the CELL's corner, not the shared grid corner: two
    // cells with flat tops at different levels share a grid corner, and a new
    // cell took its neighbour's last height there -- it flashed up to a brick
    // and dropped, its corners at different heights (the user, 2026-11-23).
    auto ckey = [](int x, int b, int z, int ox, int oz, int f) -> int64_t {
        return pack3(2 * x + ox, b * 4 + f, 2 * z + oz);
    };
    auto moved = [&](int x, int b, int z, int ox, int oz, int f, float y, float base) -> float {
        const int64_t k = ckey(x, b, z, ox, oz, f);
        auto it = prev.find(k);
        const float off = (it != prev.end() ? shown(it->second, f) : base) - y;
        now[k] = Ease{ y, off, t_now };
        return off;
    };
    // Where a neighbour's corner was last mesh (its side's foot follows it),
    // or `fallback` when it was not drawn in this tile.
    auto was = [&](int x, int b, int z, int ox, int oz, int f, float fallback) -> float {
        auto it = prev.find(ckey(x, b, z, ox, oz, f));
        return it != prev.end() ? shown(it->second, f) : fallback;
    };
    const bool real = real_tile(tx, tz);
    bool sea_top[SX * SX] = {};
    bool sea_ocean[SX * SX] = {};
    bool any_sea = false;
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
                struct Top { bool on; float h; Color c; int f; float mv; };
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
                        const int own = top_units(x, b, z, c);
                        const int bottom = b * CU + floor_u(c.solid);
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
                        const Color cc(std::min(1.0f, (float)depth / (float)(4 * CU)), kind, 1.0f, fz * 0.5f + 0.5f);   // b: sky level (sky_levels_into)
                        const float x0 = (float)x * STUD_M, x1 = (float)(x + 1) * STUD_M;
                        const float z0 = (float)z * STUD_M, z1 = (float)(z + 1) * STUD_M;
                        const float P = UNIT_M;
                        const Cell &above = wcell(x, b + 1, z);
                        const bool top_open = !(c_wet(above) && c_fluid(above) == f);
                        // Only an open top sinks under the course; a side under
                        // more water meets the course above (no seam in a fall).
                        const float sink = top_open ? TOP_SINK : 0.0f;
                        if (real && top_open && f == F_WATER && b == g_sea_b - 1 && own == g_sea_b * CU) {
                            // At the sea's level: the band's (waves with the sea).
                            sea_top[lx + SX * lz] = true;
                            sea_ocean[lx + SX * lz] = c_ocean(c);
                            any_sea = true;
                        } else if (top_open && !(c_ocean(c) && own == g_sea_b * CU)
                                && h00 == h10 && h10 == h11 && h11 == h01) {
                            // One easing for the whole top (a rect merges only
                            // tops moving alike); all four corners recorded.
                            const float y = h00 * P - TOP_SINK, yb0 = (float)bottom * P;
                            const float mv = moved(x, b, z, 0, 0, f, y, yb0);
                            moved(x, b, z, 1, 0, f, y, yb0);
                            moved(x, b, z, 0, 1, f, y, yb0);
                            moved(x, b, z, 1, 1, f, y, yb0);
                            flat[lx + SX * lz] = { true, h00, cc, f, mv };
                            any_flat = true;
                        } else if (top_open && !(c_ocean(c) && own == g_sea_b * CU)) {
                            const Vector3 a(x0, h00 * P - TOP_SINK, z0), bb(x1, h10 * P - TOP_SINK, z0);
                            const Vector3 cq(x1, h11 * P - TOP_SINK, z1), d(x0, h01 * P - TOP_SINK, z1);
                            Vector3 nrm = (d - a).cross(bb - a);
                            if (nrm.y < 0) nrm = -nrm;
                            nrm = nrm.normalized();
                            const float yb0 = (float)bottom * P;
                            m.quad(a, d, cq, bb, nrm, cc, moved(x, b, z, 0, 0, f, a.y, yb0), moved(x, b, z, 0, 1, f, d.y, yb0),
                                    moved(x, b, z, 1, 1, f, cq.y, yb0), moved(x, b, z, 1, 0, f, bb.y, yb0));
                        }
                        // Sides: down to whatever covers the neighbour.
                        const float ch[4][2] = { { h10, h11 }, { h00, h01 }, { h01, h11 }, { h00, h10 } };
                        for (int i = 0; i < 4; ++i) {
                            const int nx = x + DX[i], nz = z + DZ[i];
                            const Cell &n = wcell(nx, b, nz);
                            int cover;
                            if (c_cap(n) <= 0) continue;
                            const bool wet_n = c_wet(n) && c_fluid(n) == f
                                    && !(c_wet(wcell(nx, b + 1, nz)) && c_fluid(wcell(nx, b + 1, nz)) == f);
                            if (c_wet(n) && c_fluid(n) == f) cover = top_units(nx, b, nz, n);
                            else cover = b * CU + floor_u(n.solid);
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
                            const int o0x = (int)std::lround(p0.x / STUD_M) - x, o0z = (int)std::lround(p0.z / STUD_M) - z;
                            const int o1x = (int)std::lround(p1.x / STUD_M) - x, o1z = (int)std::lround(p1.z / STUD_M) - z;
                            // The foot on a neighbour's water top follows that
                            // top as it eases (no gap under a rising cell).
                            float f0 = 0.0f, f1 = 0.0f;
                            if (wet_n && cover >= bottom) {
                                const float nb0 = (float)(b * CU + floor_u(n.solid)) * P;
                                const float yn = (float)cover * P - TOP_SINK;
                                f0 = std::min(was(nx, b, nz, o0x - DX[i], o0z - DZ[i], f, nb0) - yn, 0.0f);
                                f1 = std::min(was(nx, b, nz, o1x - DX[i], o1z - DZ[i], f, nb0) - yn, 0.0f);
                            }
                            m.quad(Vector3(p0.x, y0, p0.z), Vector3(p1.x, y0, p1.z),
                                    Vector3(p1.x, yb, p1.z), Vector3(p0.x, ya, p0.z), nrm, cc,
                                    f0, f1, moved(x, b, z, o1x, o1z, f, yb, y0), moved(x, b, z, o0x, o0z, f, ya, y0));
                        }
                        // Bottom over open air (a fall seen from under it).
                        if (floor_of(c.solid) == 0) {
                            const Cell &d = wcell(x, b - 1, z);
                            if (!(c_wet(d) && c_fluid(d) == f) && !(d.solid & 4)) {
                                const float y = (float)(b * CU) * P;
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
                    return flat[i].on && !used[i] && flat[i].f == t.f && flat[i].h == t.h && flat[i].c == t.c
                            && flat[i].mv == t.mv;
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
                        const float y = t.h * UNIT_M - TOP_SINK;
                        buf[t.f].quad(Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0),
                                Vector3(0, 1, 0), t.c, t.mv, t.mv, t.mv, t.mv);
                    }
                }
            }
        }
    }
    if (any_sea) {
        if (mesh_sea_tops(tx, tz, sea_top, sea_ocean, buf[F_WATER])) g_out_mask = true;
    } else if (clear_real_marks(tx, tz)) {
        g_out_mask = true;
    }
    // Its sky light per vertex into COLOR.b (the mine world's water_fluid
    // reads it, Docs/MineWorld.md 19): a cave pool as dark as its cave.
    brick::sky_levels_into(buf[F_WATER].v, buf[F_WATER].n, buf[F_WATER].col);
    water = buf[F_WATER].arrays();
    lava = buf[F_LAVA].arrays();
    prev.swap(now);
    return t_now;
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
                                const int t = top_units(x, b, z, c);
                                if (c_ocean(c) && t == g_sea_b * CU) { found = true; break; }
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
                const float y = (float)top * UNIT_M - TOP_SINK;
                const Color cc(std::min(1.0f, (float)(depth + CU) / (float)(4 * CU)), 0.0f, 1.0f, 0.5f);   // b: sky level, open
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

/// Pits filling from rivers (4.5): the running water round a landed fall,
/// at its course, is a closed body when nothing in it can leave -- no drop
/// beside it, no dry floor lower than its top that it could spread onto, no
/// source or other fluid joined to it. Then the course becomes still water,
/// full, and the fall lands on that next: the pit rises a course at a time
/// until it reaches its rim, where the body is open and spills.
void check_pits() {
    if (g_landings.empty() || g_tick % PIT_EVERY != 0) return;
    std::vector<int64_t> done;
    // The due ones in reach, the longest waiting first.
    std::vector<std::pair<uint32_t, int64_t>> due;
    for (const auto &e : g_landings) {
        if (e.second > g_tick) continue;
        int x, b, z;
        unpack3(e.first, x, b, z);
        if (dist2_centre(x, z) > g_sim_r * g_sim_r) continue;
        due.push_back({ e.second, e.first });
    }
    if (due.size() > (size_t)PIT_LOOKS) {
        std::nth_element(due.begin(), due.begin() + PIT_LOOKS, due.end());
        due.resize(PIT_LOOKS);
    }
    for (const auto &d : due) {
        const int64_t k = d.second;
        int x, b, z;
        unpack3(k, x, b, z);
        const Cell &c = wcell(x, b, z);
        if (!c_wet(c) || c_kind(c) != K_FALL) { done.push_back(k); continue; }
        const int f = c_fluid(c);
        std::vector<int64_t> body{ k };
        std::unordered_set<int64_t> seen{ k };
        bool open = false;
        for (size_t h = 0; h < body.size() && !open; ++h) {
            if (body.size() > (size_t)PIT_MAX) { open = true; break; }
            int bx, bb, bz;
            unpack3(body[h], bx, bb, bz);
            const Cell &bc = wcell(bx, b, bz);
            const int top = b * CU + floor_u(bc.solid) + bc.amt;
            for (int i = 0; i < 4 && !open; ++i) {
                const int nx = bx + DX[i], nz = bz + DZ[i];
                const Cell &n = wcell(nx, b, nz);
                if (c_cap(n) <= 0) continue;
                if (c_wet(n)) {
                    if (c_fluid(n) != f || c_kind(n) == K_SOURCE) { open = true; break; }
                    if (c_kind(n) == K_STILL) continue;
                    const int64_t nk = pack3(nx, b, nz);
                    if (seen.insert(nk).second) body.push_back(nk);
                    continue;
                }
                // Dry floor is part of the basin (the stream may not cover
                // it: water reaches 5 studs); only a drop lets it out.
                if (!supported(nx, b, nz, n)) { open = true; break; }
                (void)top;
                const int64_t nk = pack3(nx, b, nz);
                if (seen.insert(nk).second) body.push_back(nk);
            }
        }
        if (open) {
            g_landings[k] = g_tick + PIT_OPEN_WAIT;
            continue;
        }
        for (int64_t bk : body) {
            int bx, bb, bz;
            unpack3(bk, bx, bb, bz);
            Cell n = wcell(bx, bb, bz);
            n.st = mk_st(f, K_STILL, false);
            n.amt = (uint8_t)std::max(0, c_cap(n));
            n.aux = E_NONE;
            g_sets.push_back({ bx, bb, bz, n });
        }
        done.push_back(k);
    }
    for (int64_t k : done) g_landings.erase(k);
}

/// SECTIONS FAR AWAY ARE LET GO. Every column the water ever sampled kept its
/// section for good -- the flow's look for a drop, priming, the sea's floor
/// -- so a long walk left thousands behind, and the save, the sea mask and
/// every lookup walked them. Only a section with nothing of its own goes:
/// never written, dry, nothing queued in it. All of that is the seed and the
/// terrain's edits again, sampled afresh if anything asks. Written or wet
/// sections stay (they ARE the water's state).
constexpr uint32_t EVICT_EVERY = 50;     ///< ticks (5 s)
constexpr double EVICT_PAST = 2.0;       ///< x the sim radius, plus a tile
int g_evicted = 0;

void evict_far() {
    if (g_tick % EVICT_EVERY != 0) return;
    const double tile_m = (double)SX * STUD_M;
    const double r = g_sim_r * EVICT_PAST + tile_m;
    std::vector<int64_t> gone;
    for (const auto &e : g_sec) {
        const Section *s = e.second.get();
        if (s->written || s->wet != 0) continue;
        const double cx = ((double)s->sx + 0.5) * tile_m - g_cx;
        const double cz = ((double)s->sz + 0.5) * tile_m - g_cz;
        if (cx * cx + cz * cz <= r * r) continue;
        bool queued = false;
        for (uint8_t q : s->queued) {
            if (q) { queued = true; break; }
        }
        if (!queued) gone.push_back(e.first);
    }
    if (gone.empty()) return;
    std::lock_guard<std::recursive_mutex> lk(g_state);
    for (int64_t k : gone) {
        auto it = g_sec.find(k);
        if (it == g_sec.end()) continue;
        const Section *s = it->second.get();
        auto ts = g_tile_secs.find(tkey(s->sx, s->sz));
        if (ts != g_tile_secs.end()) {
            auto &v = ts->second;
            v.erase(std::remove(v.begin(), v.end(), s->sb), v.end());
            if (v.empty()) g_tile_secs.erase(ts);
        }
        g_sec.erase(it);
        ++g_evicted;
    }
    // Every thread's section cache (sec_find) forgets what it held.
    g_sec_epoch.fetch_add(1);
}

/// Move the real sea square with the player; prime a few of its tiles' sea
/// columns a tick (the sea's top course read, so it has sections to mesh).
void real_sea_upkeep() {
    if (!g_real_sea || !g_sea_on) return;
    const double tm = (double)SX * STUD_M;
    const int ctx = (int)std::floor(g_cx / tm), ctz = (int)std::floor(g_cz / tm);
    if (g_real_x == INT_MIN || std::abs(ctx - g_real_x) >= 2 || std::abs(ctz - g_real_z) >= 2) {
        const int ox = g_real_x, oz = g_real_z;
        g_real_x = ctx;
        g_real_z = ctz;
        g_real_todo.clear();
        for (int dz = -REAL_T; dz <= REAL_T; ++dz) {
            for (int dx = -REAL_T; dx <= REAL_T; ++dx) {
                const int tx = ctx + dx, tz = ctz + dz;
                if (!in_square(tx, tz, ox, oz)) g_real_todo.push_back(tkey(tx, tz));
            }
        }
        // Nearest first.
        std::sort(g_real_todo.begin(), g_real_todo.end(), [&](int64_t a, int64_t b) {
            const int ax = tile_coord(a, false) - ctx, az = tile_coord(a, true) - ctz;
            const int bx = tile_coord(b, false) - ctx, bz = tile_coord(b, true) - ctz;
            return ax * ax + az * az > bx * bx + bz * bz;   // popped from the back
        });
        // The tiles it left go back to the tiers' sea.
        if (ox != INT_MIN) {
            for (int dz = -REAL_T; dz <= REAL_T; ++dz) {
                for (int dx = -REAL_T; dx <= REAL_T; ++dx) {
                    const int tx = ox + dx, tz = oz + dz;
                    if (!real_tile(tx, tz)) g_dirty_tiles.insert(tkey(tx, tz));
                }
            }
        }
    }
    for (int n = 0; n < REAL_PRIME_PER_TICK && !g_real_todo.empty(); ++n) {
        const int64_t k = g_real_todo.back();
        g_real_todo.pop_back();
        const int tx = tile_coord(k, false), tz = tile_coord(k, true);
        bool any = false;
        for (int lz = 0; lz < SX; ++lz) {
            for (int lx = 0; lx < SX; ++lx) {
                if (gen_sea_col(tx * SX + lx, tz * SX + lz)) any = true;
            }
        }
        if (any || g_tile_secs.count(k)) g_dirty_tiles.insert(k);
    }
}

void do_tick() {
    const auto t0 = std::chrono::steady_clock::now();
    t_may_compute = true;
    struct Off { ~Off() { t_may_compute = false; } } off;
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
        if (dx * dx + dz * dz > 64.0 && (!g_frozen.empty() || !g_frozen_timers.empty())) {
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
            back.clear();
            for (int64_t k : g_frozen_timers) {
                int x, b, z;
                unpack3(k, x, b, z);
                if (dist2_centre(x, z) <= g_sim_r * g_sim_r) back.push_back(k);
            }
            for (int64_t k : back) {
                g_frozen_timers.erase(k);
                g_timers.insert({ g_tick, k });   // due now: fires this tick
            }
        } else if (dx * dx + dz * dz > 64.0) {
            g_recheck_x = g_cx;
            g_recheck_z = g_cz;
        }
    }

    std::vector<int64_t> due;
    due.swap(g_due);
    if (!g_simulate) {
        // A mirror: what the authority sends is applied (apply_changes);
        // nothing here decides for itself.
        due.clear();
        g_due_lava.clear();
        g_timers.clear();
    }
    // Waiting lava comes up every tick, but only to meet water (eval checks
    // that first, then waits again till a lava tick to flow): a cell already
    // queued is not woken again, so a source waiting there met water late.
    if (!g_due_lava.empty()) {
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
        // Past the sim radius a timer waits (g_frozen_timers) and fires once
        // the player comes back. Timers used to fire anywhere (thin spills
        // drying, lava setting to stone) and their writes woke more cells
        // there. Not frozen as a cell: its armed flag (aux 0x80) stays set,
        // so a woken cell's eval would never arm it again.
        if (dist2_centre(x, z) > g_sim_r * g_sim_r) {
            g_frozen_timers.insert(k);
            continue;
        }
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

    if (g_simulate) check_pits();

    // Apply (MineWater.md 4.2: sets first, then the moves that still hold).
    std::unordered_set<int64_t> set_now;
    std::unordered_set<int64_t> by_op;
    const auto ta = std::chrono::steady_clock::now();
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
    g_apply_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - ta).count();
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

    real_sea_upkeep();

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
        mo.built_s = mesh_tile(tx, tz, mo.water, mo.lava);
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
        mo.is_far = true;
        mo.built_s = clock_s();
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
    evict_far();
    g_last_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

#ifdef _WIN32
/// The water's thread is not Godot's: a crash in it went out with no
/// backtrace at all. This prints where (with the .pdb of a pdb=yes build).
LONG fluid_crash_report(EXCEPTION_POINTERS *ep) {
    HANDLE proc = GetCurrentProcess();
    SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
    SymInitialize(proc, nullptr, TRUE);
    std::fprintf(stderr, "[BrickFluid] the water thread crashed: code 0x%08lx at %p\n",
            ep->ExceptionRecord->ExceptionCode, ep->ExceptionRecord->ExceptionAddress);
    void *frames[48];
    const USHORT n = CaptureStackBackTrace(0, 48, frames, nullptr);
    char buf[sizeof(SYMBOL_INFO) + 256];
    SYMBOL_INFO *sym = (SYMBOL_INFO *)buf;
    for (USHORT i = 0; i < n; ++i) {
        std::memset(buf, 0, sizeof(buf));
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen = 255;
        DWORD64 disp = 0;
        IMAGEHLP_LINE64 line;
        std::memset(&line, 0, sizeof(line));
        line.SizeOfStruct = sizeof(line);
        DWORD ldisp = 0;
        const DWORD64 a = (DWORD64)frames[i];
        const bool named = SymFromAddr(proc, a, &disp, sym);
        const bool lined = SymGetLineFromAddr64(proc, a, &ldisp, &line);
        std::fprintf(stderr, "[BrickFluid]   %2u %s %s:%lu\n", i, named ? sym->Name : "?",
                lined ? line.FileName : "?", lined ? line.LineNumber : 0ul);
    }
    std::fflush(stderr);
    return EXCEPTION_CONTINUE_SEARCH;
}

void tick_guarded() {
    __try {
        do_tick();
    } __except (fluid_crash_report(GetExceptionInformation())) {
    }
}
#else
void tick_guarded() { do_tick(); }
#endif

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
    g_frozen_timers.clear();
    g_dirty_tiles.clear();
    g_mesh_requests.clear();
    g_far_requests.clear();
    g_landings.clear();
    g_lava_total.store(0);
    {
        std::lock_guard<std::mutex> ll(g_lava_mx);
        g_lava_dirty.clear();
    }
    g_prev_tops.clear();
    g_log.clear();
    g_log_floor = g_writes.load();
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
        g_lakes = gen && gp.lakes;
        g_pools = gen && gp.cave_pools;
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
    c.amount = amount * U;   // tiles -> units
    push_cmd(c);
}

void BrickFluid::remove(Vector3i cell, int amount) {
    Cmd c;
    c.type = 2;
    c.a = cell;
    c.amount = amount < 0 ? amount : amount * U;   // tiles -> units
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
            tick_guarded();
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
            d["far"] = m.is_far;
            d["built_s"] = m.built_s;
            meshes.append(d);
        }
        for (int32_t v : g_out_terrain) terr.push_back(v);
        PackedInt32Array fire;
        for (int32_t v : g_out_fire) fire.push_back(v);
        out["fire"] = fire;
        mask = g_out_mask;
        g_out_meshes.clear();
        g_out_terrain.clear();
        g_out_fire.clear();
        g_out_mask = false;
        g_have_results = false;
        if (mask) ++g_mask_version;
    }
    out["meshes"] = meshes;
    out["terrain"] = terr;
    out["mask_changed"] = mask;
    PackedInt32Array lit;
    {
        std::lock_guard<std::mutex> ll(g_lava_mx);
        for (const auto &e : g_lava_dirty) {
            lit.push_back(tile_coord(e.first, false));
            lit.push_back(tile_coord(e.first, true));
            lit.push_back(e.second.first * 3);
            lit.push_back(e.second.second * 3 + 2);
        }
        g_lava_dirty.clear();
    }
    out["lava_light"] = lit;
    return out;
}

int64_t BrickFluid::lava_total() { return g_lava_total.load(std::memory_order_relaxed); }

int BrickFluid::lava_cells_in(Vector3i lo, Vector3i hi, std::vector<int32_t> &out) {
    if (g_lava_total.load(std::memory_order_relaxed) <= 0) return 0;
    const size_t n0 = out.size();
    const int sx0 = fdiv(lo.x, SX), sx1 = fdiv(hi.x, SX);
    const int sz0 = fdiv(lo.z, SX), sz1 = fdiv(hi.z, SX);
    const int sb0 = fdiv(lo.y, SB), sb1 = fdiv(hi.y, SB);
    std::lock_guard<std::recursive_mutex> lk(g_state);
    for (int sz = sz0; sz <= sz1; ++sz) {
        for (int sx = sx0; sx <= sx1; ++sx) {
            auto ts = g_tile_secs.find(tkey(sx, sz));
            if (ts == g_tile_secs.end()) continue;
            for (int sb : ts->second) {
                if (sb < sb0 || sb > sb1) continue;
                auto it = g_sec.find(pack3(sx, sb, sz));
                if (it == g_sec.end()) continue;
                const Section *s = it->second.get();
                if (s->lava.load(std::memory_order_relaxed) <= 0) continue;
                const int lx0 = std::max(0, lo.x - sx * SX), lx1 = std::min(SX - 1, hi.x - sx * SX);
                const int lz0 = std::max(0, lo.z - sz * SX), lz1 = std::min(SX - 1, hi.z - sz * SX);
                const int lb0 = std::max(0, lo.y - sb * SB), lb1 = std::min(SB - 1, hi.y - sb * SB);
                for (int lz = lz0; lz <= lz1; ++lz) {
                    for (int lx = lx0; lx <= lx1; ++lx) {
                        if (!s->ready[lx + SX * lz]) continue;
                        std::atomic_thread_fence(std::memory_order_acquire);
                        for (int lb = lb0; lb <= lb1; ++lb) {
                            if (c_lava(s->c[Section::idx(lx, lb, lz)])) {
                                out.push_back(sx * SX + lx);
                                out.push_back(sb * SB + lb);
                                out.push_back(sz * SX + lz);
                            }
                        }
                    }
                }
            }
        }
    }
    return (int)((out.size() - n0) / 3);
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
    d["built_s"] = mesh_tile(tx, tz, w, l);
    d["water"] = w;
    d["lava"] = l;
    return d;
}

PackedFloat32Array BrickFluid::ease_seconds() {
    PackedFloat32Array out;
    for (float v : EASE_S) out.push_back(v);
    return out;
}

void BrickFluid::prime_tile(int tx, int tz, int b_lo, int b_hi) {
    Cmd c;
    c.type = 7;
    c.a = Vector3i(tx, 0, tz);
    c.b = Vector3i(b_lo, b_hi, 0);
    push_cmd(c);
}

void BrickFluid::set_real_sea(bool on) {
    Cmd c;
    c.type = 11;
    c.a = Vector3i(on ? 1 : 0, 0, 0);
    push_cmd(c);
}

bool BrickFluid::ocean_at(Vector3 p) {
    if (!g_sea_on) return false;
    const Vector3i k = cell_of(p);
    MainLock lk;
    const Cell c = rcell(k.x, g_sea_b - 1, k.z);
    return c_wet(c) && c_ocean(c);
}

int BrickFluid::lake_top(int x, int z) {
    const int l = lake_course(x, z);
    return l == NO_SPRING ? INT_MIN : l;
}

void BrickFluid::set_change_log(bool on) {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    g_log_on = on;
    g_log.clear();
    g_log_floor = g_writes.load();
}

void BrickFluid::set_simulating(bool on) { g_simulate = on; }
bool BrickFluid::get_simulating() { return g_simulate; }

Dictionary BrickFluid::get_changes_since(int64_t since) {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    Dictionary out;
    const int64_t now = g_writes.load();
    out["version"] = now;
    // Older than the log reaches (or the log is off): a peer needs the whole
    // difference from the generated world, get_save's.
    out["full"] = !g_log_on || since < g_log_floor;
    std::vector<uint8_t> buf;
    auto put32 = [&](int32_t v) {
        for (int i = 0; i < 4; ++i) buf.push_back((uint8_t)((uint32_t)v >> (8 * i)));
    };
    if (g_log_on && since >= g_log_floor) {
        auto it = std::upper_bound(g_log.begin(), g_log.end(), std::make_pair(since, INT64_MAX));
        std::unordered_set<int64_t> sent;
        for (; it != g_log.end(); ++it) {
            if (!sent.insert(it->second).second) continue;
            int x, b, z;
            unpack3(it->second, x, b, z);
            const Cell c = rcell(x, b, z);
            put32(x);
            put32(b);
            put32(z);
            buf.push_back(c.st);
            buf.push_back(c.amt);
            buf.push_back(c.aux & 0x7F);
        }
    }
    PackedByteArray cells;
    cells.resize((int64_t)buf.size());
    std::copy(buf.begin(), buf.end(), cells.ptrw());
    out["cells"] = cells;
    return out;
}

int BrickFluid::apply_changes(const PackedByteArray &cells, bool wake) {
    int n = 0;
    const uint8_t *r = cells.ptr();
    auto get32 = [&](int64_t at) {
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= (uint32_t)r[at + i] << (8 * i);
        return (int32_t)v;
    };
    std::lock_guard<std::mutex> lk(g_cmd_mx);
    for (int64_t at = 0; at + 15 <= cells.size(); at += 15) {
        Cmd c;
        c.type = wake ? 3 : 9;
        c.a = Vector3i(get32(at), get32(at + 4), get32(at + 8));
        c.st = r[at + 12];
        c.amt = r[at + 13];
        c.aux = r[at + 14];
        g_cmds.push_back(c);
        ++n;
    }
    return n;
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
    MainLock lk;
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
    MainLock lk;
    const Cell c = rcell(cell.x, cell.y, cell.z);
    Dictionary d;
    d["fluid"] = c_wet(c) ? c_fluid(c) : 0;
    d["kind"] = c_kind(c);
    d["amount"] = ((int)c.amt + U - 1) / U;   // tiles (plates), a half rounded up
    d["units"] = (int)c.amt;                   // half tiles
    d["dist"] = c_dist(c);
    d["solid"] = (int)c.solid;
    d["ocean"] = c_ocean(c);
    d["capacity"] = c_cap(c) / U;
    return d;
}

int BrickFluid::fluid_at(Vector3 p) {
    const Vector3i k = cell_of(p);
    MainLock lk;
    const Cell c = rcell(k.x, k.y, k.z);
    if (!c_wet(c)) return 0;
    const double top = (double)(k.y * CU + floor_u(c.solid) + c.amt) * UNIT_M;
    const Cell a = rcell(k.x, k.y + 1, k.z);
    if (p.y < top || (c_wet(a) && c_fluid(a) == c_fluid(c))) return c_fluid(c);
    return 0;
}

double BrickFluid::surface_at(Vector3 p) {
    const Vector3i k = cell_of(p);
    MainLock lk;
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
    const double top = (double)(b * CU + floor_u(c.solid) + c.amt) * UNIT_M;
    if (b == k.y && p.y > top) return -INFINITY;
    return top;
}

Vector3 BrickFluid::flow_at(Vector3 p) {
    const Vector3i k = cell_of(p);
    MainLock lk;
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
    MainLock lk;
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
            out["amount"] = ((int)cl.amt + U - 1) / U;
            out["units"] = (int)cl.amt;
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
    MainLock lk;
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
                    bool calm = false, changed = false, hidden = false;
                    for (int b = cb - 1; b <= cb + 1; ++b) {
                        Section *s = sec_find(tx, fdiv(b, SB), tz);
                        if (s == nullptr || !s->ready[lx + SX * lz]) continue;
                        const Cell &c = s->c[Section::idx(lx, b - s->sb * SB, lz)];
                        if (c_wet(c) && !c_ocean(c)) calm = true;
                        if (b == cb && s->gtop[lx + SX * lz] + 1 < g_sea_b && !(c_wet(c) && c_ocean(c))) {
                            changed = true;
                        }
                        if (b == cb && !s->real.empty() && s->real[lx + SX * lz]) hidden = true;
                    }
                    const size_t k = (size_t)iz * size + ix;
                    if (changed || hidden) w[k * 2] = 255;
                    if (calm || changed) { dist[k] = 0.0f; any = true; }
                }
            }
        }
    }
    // The cells are read; the distance passes need no lock (the water's
    // worker waited for them too).
    lk.lk.unlock();
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
    d["lava_cells"] = g_lava_total.load();
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
    d["evicted"] = g_evicted;
    d["apply_ms"] = g_apply_ms;
    d["main_wait_ms"] = (double)g_main_wait_worst_us.exchange(0) / 1000.0;
    d["main_waits_1ms"] = g_main_waits_1ms.exchange(0);
    d["frozen_timers"] = (int)g_frozen_timers.size();
    d["tick"] = (int64_t)g_tick;
    return d;
}

Dictionary BrickFluid::memory_stats() {
    std::lock_guard<std::recursive_mutex> lk(g_state);
    int64_t bytes = 0;
    int64_t written = 0;
    int64_t wet = 0;
    for (const auto &e : g_sec) {
        const Section &s = *e.second;
        bytes += (int64_t)(sizeof(Section) + s.c.capacity() * sizeof(Cell) + s.ready.capacity()
                + s.gtop.capacity() * 2 + s.spring.capacity() * 2 + s.lake.capacity() * 2
                + s.real.capacity() + s.queued.capacity()) + 48;
        written += s.written ? 1 : 0;
        wet += s.wet > 0 ? 1 : 0;
    }
    Dictionary d;
    d["sections"] = (int64_t)g_sec.size();
    d["bytes"] = bytes;
    d["written"] = written;
    d["wet"] = wet;
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
// int32 x, course, z; uint8 st, amt, aux. Header "BCFL", format 2 (amt in
// units; format 1 counted plates and is read doubled).
/// The difference from gen_fluid, cell by cell (MineWater.md 11). Never waits
/// for a running tick: the worker writes cells only under g_state, which is
/// held here, and columns it is still sampling are not ready yet (skipped:
/// nothing there was changed). Sections with nothing wet and no generated
/// fluid are skipped whole.
PackedByteArray BrickFluid::get_save() {
    MainLock lk;
    std::vector<uint8_t> buf;
    const char *magic = "BCFL";
    buf.insert(buf.end(), magic, magic + 4);
    buf.push_back(2);
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
                    gen_fluid(g, s.sx * SX + lx, s.sb * SB + lb, s.sz * SX + lz, s.gtop[lx + SX * lz],
                            s.spring[lx + SX * lz], s.lake[lx + SX * lz]);
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
    if (r[0] != 'B' || r[1] != 'C' || r[2] != 'F' || r[3] != 'L' || (r[4] != 1 && r[4] != 2)) return 0;
    const int scale = r[4] == 1 ? U : 1;
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
        c.amt = (uint8_t)std::min(CU, r[at + 13] * scale);
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
    ClassDB::bind_static_method("BrickFluid", D_METHOD("ease_seconds"), &BrickFluid::ease_seconds);
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
    ClassDB::bind_static_method("BrickFluid", D_METHOD("prime_tile", "tx", "tz", "b_lo", "b_hi"), &BrickFluid::prime_tile,
            DEFVAL(1), DEFVAL(0));
    ClassDB::bind_static_method("BrickFluid", D_METHOD("lake_top", "x", "z"), &BrickFluid::lake_top);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("ocean_at", "point"), &BrickFluid::ocean_at);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_real_sea", "on"), &BrickFluid::set_real_sea);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_change_log", "on"), &BrickFluid::set_change_log);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_simulating", "on"), &BrickFluid::set_simulating);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_simulating"), &BrickFluid::get_simulating);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_changes_since", "version"), &BrickFluid::get_changes_since);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("apply_changes", "cells", "wake"), &BrickFluid::apply_changes,
            DEFVAL(false));
    ClassDB::bind_static_method("BrickFluid", D_METHOD("has_generated"), &BrickFluid::has_generated);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("sea_mask", "x0", "z0", "size"), &BrickFluid::sea_mask);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("changed_columns"), &BrickFluid::changed_columns);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("stats"), &BrickFluid::stats);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("memory_stats"), &BrickFluid::memory_stats);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("active_count"), &BrickFluid::active_count);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("section_count"), &BrickFluid::section_count);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("still_units", "fluid"), &BrickFluid::still_units);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("get_save"), &BrickFluid::get_save);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_save", "bytes"), &BrickFluid::set_save);
}
