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
#include <cstring>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
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
/// A tile whose water changes every tick is meshed every MESH_GAP ticks, not
/// every tick (meshing was two thirds of a busy tick, W2 2026-11-24): its
/// corners ease over EASE_S (0.2 s, two ticks), so the motion stays
/// continuous. The tile round the player, and a mesh asked for, at once.
constexpr uint32_t MESH_GAP = 2;
std::unordered_map<int64_t, uint32_t> g_tile_meshed_at;
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
    uint8_t st = 0;      ///< fluid (2 bits) | kind << 2 | ocean << 4 | held << 5
    uint8_t amt = 0;     ///< units of fluid (half plates), 0..CU
    uint8_t aux = 0;     ///< FLOW: distance. STILL: low 6 bits the edge distance
                         ///< (E_NONE: none known), 0x80 = drying timer set
};

inline int c_fluid(const Cell &c) { return c.st & 3; }
inline int c_kind(const Cell &c) { return (c.st >> 2) & 3; }
inline bool c_ocean(const Cell &c) { return ((c.st >> 4) & 1) != 0; }
/// FED water over a pond: the pond's own still units under it (0-6), given
/// back when the feed goes. Infinite water adds water nowhere (the user's
/// R6, Docs/MineWaterNext.md): a river over a pond leaves its volume as it
/// was -- it took the cell's water and gave back as much as the river held.
inline int c_held(const Cell &c) { return (c.st >> 5) & 7; }
inline uint8_t with_held(uint8_t st, int held) { return (uint8_t)((st & 31) | (held << 5)); }
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

/// One cell of a parked section that differs from the generated world (the
/// save's record): its index in the section and its fluid.
struct Diff {
    uint16_t i;
    uint8_t st, amt, aux;
};

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
    /// Back from parking (W3): its changed cells, by column, put back over
    /// the generated ones as each column is sampled.
    std::vector<Diff> pending;
    int wet = 0;                    ///< wet cells (for "anything to draw")
    /// Wet LAVA cells: the terrain's block light (lava_cells_in) reads only
    /// sections with some. The bakes read it under g_state while sample_into
    /// adds to it without: atomic.
    std::atomic<int> lava{ 0 };
    static int idx(int lx, int lb, int lz) { return lx + SX * (lz + SX * lb); }
};
inline int diff_col(const Diff &d) { return d.i % SCOL; }

std::unordered_map<int64_t, std::unique_ptr<Section>> g_sec;
/// WATER FAR AWAY IS PARKED (W3, Docs/MineWaterNext.md 6; the terrain chat
/// measured 122 MB after a 480 m flight over sea, 2026-11-24): a written
/// section far from the player keeps only the cells that differ from the
/// generated world, sorted by column -- about 5 bytes a changed cell, not
/// ~90 KB a section. Asked for again, it is made afresh and they are put
/// back (sample_into). A section of only generated water is not kept at all.
std::unordered_map<int64_t, std::vector<Diff>> g_parked;
int64_t g_parked_bytes = 0;
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
/// How far inland water (lakes, rivers, the player's -- not the open sea,
/// which the tiers draw) keeps its sections, metres: water is drawn out to
/// the terrain LOD the player chose (MineWater.drop_lod). 0: no further than
/// the rest (EVICT_PAST).
double g_keep_inland_m = 0.0;
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

/// LEVELLING (stage P, Docs/MineWaterNext.md 4): still water has no
/// pressure -- poured down one arm of a U-bend it stood there; a sealed room
/// filled unevenly. A still cell resting on full still water (a head on it)
/// marks its body due; once calm a moment it is levelled as one body: its
/// units laid again from the lowest floor up through every opening, a unit
/// layer at a time. Seed cell -> the tick it is due.
std::unordered_map<int64_t, uint32_t> g_level_due;
constexpr int LEVEL_EVERY = 10;          ///< ticks between looks
constexpr int LEVEL_LOOKS = 8;           ///< bodies a look
constexpr int LEVEL_MAX = 4096;          ///< cells a body may have
constexpr uint32_t LEVEL_WAIT = 20;      ///< ticks calm before levelling

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
    int type = 0;     // 0 terrain, 1 place, 2 remove, 3 raw, 4 mesh request, 5 reset frozen, 12 rain
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
            if (material_burns(m)) {
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
    auto pk = g_parked.find(pack3(sx, sb, sz));
    if (pk != g_parked.end()) {
        ns->pending = std::move(pk->second);
        ns->written = true;
        g_parked_bytes -= (int64_t)ns->pending.size() * (int64_t)sizeof(Diff);
        g_parked.erase(pk);
    }
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
    }
    if (!s->pending.empty()) {
        // Back from parking: this column's changed cells over the generated.
        const int col = lx + SX * lz;
        auto at = std::lower_bound(s->pending.begin(), s->pending.end(), col,
                [](const Diff &d, int c) { return diff_col(d) < c; });
        for (; at != s->pending.end() && diff_col(*at) == col; ++at) {
            Cell &cl = s->c[at->i];
            cl.st = at->st;
            cl.amt = at->amt;
            cl.aux = at->aux;
        }
    }
    for (int lb = 0; lb < SB; ++lb) {
        const Cell &cl = s->c[Section::idx(lx, lb, lz)];
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
    // Not sampled: the generated cell, or a parked (or pending) change.
    Cell g = gen_cell(x, b, z);
    const std::vector<Diff> *diffs = nullptr;
    if (s != nullptr) {
        diffs = &s->pending;
    } else if (!g_parked.empty()) {
        auto pk = g_parked.find(pack3(sx, sb, sz));
        if (pk != g_parked.end()) diffs = &pk->second;
    }
    if (diffs != nullptr) {
        const int i = Section::idx(x - sx * SX, b - sb * SB, z - sz * SX);
        for (const Diff &d : *diffs) {
            if (d.i == i) { g.st = d.st; g.amt = d.amt; g.aux = d.aux; break; }
        }
    }
    return g;
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
    // (4.2.5 "whose top is lower"): a river does not turn a pond into a river.
    if (best_fluid != 0 && best_kind != K_SOURCE && c_wet(cur) && c_kind(cur) == K_STILL
            && c_fluid(cur) == best_fluid && (int)cur.amt >= best_amt) {
        best_fluid = 0;
    }
    if (deferred && best_fluid == 0) {
        g_defer_lava.push_back(pack3(x, b, z));
    }
    if (best_fluid != 0) {
        Cell n = cur;
        int amt = best_amt;
        // The pond under it: a still cell taken over keeps its units as
        // `held`, a fed one keeps what it held (a source holds nothing: it
        // is infinite).
        int held = 0;
        if (best_kind != K_SOURCE && c_wet(cur) && c_fluid(cur) == best_fluid) {
            held = c_kind(cur) == K_STILL ? (int)cur.amt : c_held(cur);
        }
        amt = std::max(amt, held);
        n.st = with_held(mk_st(best_fluid, best_kind, best_ocean), held);
        n.amt = (uint8_t)std::min(amt, cap);
        n.aux = (uint8_t)(best_kind == K_FLOW ? best_d : 0);
        if (n.st != cur.st || n.amt != cur.amt || n.aux != cur.aux) {
            g_sets.push_back({ x, b, z, n });
        }
        return;
    }
    if (!c_wet(cur)) return;
    if (c_kind(cur) == K_FLOW || c_kind(cur) == K_FALL) {
        // Its feed is gone: running water goes, cell by cell from where it
        // was cut, as Minecraft's does -- infinite water never leaves water
        // behind (R6; it used to become still water, 4.1.6). A pond it ran
        // over is given back as it was.
        const int held = c_held(cur);
        Cell n = cur;
        if (cf == F_LAVA) {
            // Lava is not R6's: cut off, it comes to rest a unit deep where
            // it ran (deeper where it stood), and cools into stone (4.6).
            n.st = mk_st(cf, K_STILL, false);
            n.aux = E_NONE;
            if (c_kind(cur) == K_FLOW && (int)cur.amt <= flow_level(cf, c_dist(cur))) n.amt = 1;
        } else if (held > 0) {
            n.st = mk_st(cf, K_STILL, false);
            n.amt = (uint8_t)held;
            n.aux = E_NONE;
        } else {
            n = Cell{ cur.solid, 0, 0, 0 };
        }
        g_sets.push_back({ x, b, z, n });
        return;
    }

    // --- still water: a volume in whole tiles (4.2)
    const int a = cur.amt;
    // Touching a SOURCE of its own fluid (the sea, a lake, a spring) it joins
    // it: a FULL cell becomes source itself (R9, the user 2026-11-24: a
    // source in a brim-full pond makes it a lake -- the next full cells turn
    // the tick after, through the whole full body); a part-full one drains
    // into the infinite body a unit a tick (4.2.4). Water only: still lava
    // beside its source drains in as before.
    for (int i = 0; i < 4; ++i) {
        const Cell &n = wcell(x + DX[i], b, z + DZ[i]);
        if (c_wet(n) && c_fluid(n) == cf && c_kind(n) == K_SOURCE) {
            if (DEFS[cf].renew && floor_u(cur.solid) + a >= CU) {
                Cell k = cur;
                k.st = mk_st(cf, K_SOURCE, false);
                k.aux = 0;
                g_sets.push_back({ x, b, z, k });
                return;
            }
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
    // Resting on full still water: there is a head here -- the body may not
    // be level (a U-bend's arm). Looked at once it has been calm (stage P).
    if (floor_of(cur.solid) == 0) {
        const Cell &dl = wcell(x, b - 1, z);
        if (c_wet(dl) && c_fluid(dl) == cf && c_kind(dl) == K_STILL && floor_u(dl.solid) + dl.amt >= CU) {
            g_level_due.emplace(pack3(x, b, z), g_tick + LEVEL_WAIT);
        }
    }
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

/// RAIN (R10, Docs/MineWaterNext.md 8): a drop is a tile of still water on
/// a column's top solid plate -- the ground, a roof, whatever is open to the
/// sky (brick::packed_tops, the tiles the player sees: edits and buildings
/// in). On still water it adds to it; on the sea, a lake, a river or lava it
/// is nothing (infinite or burning). It pools as poured water does: runs off
/// a rim into the hollow, and a lone tile on flat ground dries (4.2.3).
///
/// SOAKING IN: a drop on dry ground with nothing higher beside it -- the
/// open flat, a hilltop -- soaks in (the ground is drawn wet, WeatherFx);
/// only water that would run somewhere lands: at the foot of anything
/// higher (a step, a wall, a hollow's side), where it runs down to the
/// hollows, or on water already there. Every drop landed meshes its tile
/// again: a storm landing everywhere kept ~50 tiles meshing every tick
/// (23 ms a tick, 16 ms a frame drawing them, the water gate 2026-11-25),
/// and those lone tiles only dried again.
int64_t g_rain_landed = 0;
int64_t g_rain_soaked = 0;
uint32_t g_rain_seq = 0;

/// A column's top solid plate (packed_tops), or INT_MIN.
int rain_top(int x, int z) {
    const int tx = fdiv(x, SX), tz = fdiv(z, SX);
    const std::shared_ptr<const TileTops> pk = packed_tops(tx, tz);
    if (!pk || pk->top.size() < (size_t)(SX * SX)) return INT_MIN;
    return pk->top[(size_t)(x - tx * SX) + (size_t)SX * (size_t)(z - tz * SX)];
}

/// SNOW AND ICE (Docs/MineWaterNext.md 10): a column is cold where the
/// generator lays snow on it (a snowy biome's top, or over the snow line).
/// Rain there falls as snow and leaves no water; calm water there freezes.
bool g_cold_test = false;   ///< every column cold (probes)
std::unordered_map<int64_t, bool> g_cold_tiles;   ///< tile -> cold (its middle column)
bool cold_column(int x, int z) {
    if (g_cold_test) return true;
    if (!biomes_on()) return false;
    return biome_column((uint32_t)BrickTerrain::get_seed(), x, z).snow;
}

void rain_drop(int x, int z) {
    if (cold_column(x, z)) { ++g_rain_soaked; return; }
    const int tp = rain_top(x, z);
    if (tp == INT_MIN) return;
    int b = fdiv(tp + 1, 3);
    {
        const Cell q = wcell(x, b, z);
        if (!c_wet(q)) {
            static const int DX[4] = { 1, -1, 0, 0 }, DZ[4] = { 0, 0, 1, -1 };
            bool foot = false;
            for (int i = 0; i < 4 && !foot; ++i) foot = rain_top(x + DX[i], z + DZ[i]) > tp;
            if (!foot) { ++g_rain_soaked; return; }
        }
    }
    for (int up = 0; up < 24; ++up, ++b) {
        const Cell q = wcell(x, b, z);
        const int cap = c_cap(q);
        if (cap <= 0) return;
        if (c_wet(q)) {
            if (c_fluid(q) != F_WATER || c_kind(q) != K_STILL) return;
            if ((int)q.amt >= cap) continue;          // a full cell: on top of it
        }
        std::lock_guard<std::recursive_mutex> lk(g_state);
        const int have = c_wet(q) ? (int)q.amt : 0;
        Cell n = q;
        n.st = mk_st(F_WATER, K_STILL, false);
        n.amt = (uint8_t)std::min(cap, have + U);
        n.aux = c_wet(q) ? (uint8_t)c_edge(q) : E_NONE;
        write_cell(x, b, z, n);
        wake_around(x, b, z);
        ++g_rain_landed;
        return;
    }
}

/// A shower over the disc (a.x, a.z) studs, b.x studs across (radius), of
/// `amount` drops: only the part inside the sim radius is rained on, so a
/// storm far wider than it samples the sim disc at its own density.
void rain_cmd(const Cmd &c) {
    const double r_st = std::max(1, c.b.x);
    const double sim_st = g_sim_r / STUD_M;
    const double cx_st = g_cx / STUD_M - 0.5, cz_st = g_cz / STUD_M - 0.5;
    double ox = c.a.x, oz = c.a.z, rr = r_st, n = (double)c.amount;
    const double gap = std::hypot(ox - cx_st, oz - cz_st);
    if (gap > r_st + sim_st) return;
    if (sim_st < r_st) {
        // Sample the sim disc, at the storm's density.
        n *= (sim_st * sim_st) / (r_st * r_st);
        ox = cx_st;
        oz = cz_st;
        rr = sim_st;
    }
    int drops = (int)n;
    if ((double)(hmix(++g_rain_seq * 0x9E3779B1U) % 1000) < (n - drops) * 1000.0) ++drops;
    drops = std::min(drops, 4000);
    for (int i = 0; i < drops; ++i) {
        const uint32_t h1 = hmix(++g_rain_seq * 0x85EBCA77U ^ g_tick);
        const uint32_t h2 = hmix(h1 ^ 0xC2B2AE3DU);
        const double a = (double)(h1 & 0xFFFF) / 65536.0 * Math_TAU;
        const double d = std::sqrt((double)(h2 & 0xFFFF) / 65536.0) * rr;
        const int x = (int)std::floor(ox + std::cos(a) * d + 0.5);
        const int z = (int)std::floor(oz + std::sin(a) * d + 0.5);
        if (std::hypot(x - (double)c.a.x, z - (double)c.a.z) > r_st) continue;   // outside the storm
        if (dist2_centre(x, z) > g_sim_r * g_sim_r) continue;
        rain_drop(x, z);
    }
}

void apply_cmd(const Cmd &c) {
    if (c.type == 12) {
        rain_cmd(c);
        return;
    }
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
    // Plain vectors while building, copied into Godot's packed arrays once
    // (arrays()): a packed array's push_back a value was a large part of a
    // mesh's time (W2, 2026-11-25).
    std::vector<Vector3> v, n;
    std::vector<Color> col;
    std::vector<int32_t> idx;
    /// CUSTOM0 (RGBA float a vertex): x = how far below (+ above) its last
    /// mesh's place the vertex was, metres -- the shader eases from there to
    /// here over a tick, so water glides instead of jumping (no slide show).
    std::vector<float> cus;
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
    /// `drop`: c and d are a side's foot, this far under the top -- CUSTOM0.z
    /// (the shader cuts it to the neighbour the side faces, as the tiers do).
    void sea_quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d,
            const Vector3 &nrm, const Color &cc, const Vector2 &mid, float drop = 0.0f) {
        const int base = (int)v.size();
        int k = 0;
        for (const Vector3 &p : { a, b, c, d }) {
            v.push_back(p);
            n.push_back(nrm);
            col.push_back(cc);
            cus.push_back(mid.x > p.x ? 1.0f : -1.0f);
            cus.push_back(1.0f);
            cus.push_back(k >= 2 ? drop : 0.0f);
            cus.push_back(mid.y > p.z ? 1.0f : -1.0f);
            ++k;
        }
        idx.push_back(base); idx.push_back(base + 1); idx.push_back(base + 2);
        idx.push_back(base); idx.push_back(base + 2); idx.push_back(base + 3);
    }
    /// A brick piece's face (W4): CUSTOM0 x, w the way from the vertex to
    /// the piece's middle, studs (the shader finds its joints and, on a lake,
    /// the wave there); y 2 a lake piece (z its wave amplitude) or 3 a still
    /// one (z how far it moved, the easing as CUSTOM0.x elsewhere).
    void piece_quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d,
            const Vector3 &nrm, const Color *cs, const Vector2 &mid, float kind, float z) {
        const int base = (int)v.size();
        const Vector3 ps[4] = { a, b, c, d };
        for (int k = 0; k < 4; ++k) {
            const Vector3 &p = ps[k];
            v.push_back(p);
            n.push_back(nrm);
            col.push_back(cs[k]);
            cus.push_back((mid.x - p.x) / STUD_M);
            cus.push_back(kind);
            cus.push_back(z);
            cus.push_back((mid.y - p.z) / STUD_M);
        }
        idx.push_back(base); idx.push_back(base + 1); idx.push_back(base + 2);
        idx.push_back(base); idx.push_back(base + 2); idx.push_back(base + 3);
    }
    /// A lake piece's face (S3, W4): one colour, riding the wave at `mid`.
    void lake_quad(const Vector3 &a, const Vector3 &b, const Vector3 &c, const Vector3 &d,
            const Vector3 &nrm, const Color &cc, const Vector2 &mid, float amp) {
        const Color cs[4] = { cc, cc, cc, cc };
        piece_quad(a, b, c, d, nrm, cs, mid, 2.0f, amp);
    }
    /// The mesh arrays; `sky`: each vertex's sky light into COLOR.b first
    /// (brick::sky_levels_into, the mine world's water_fluid reads it).
    Array arrays(bool sky = false) const {
        Array a;
        if (v.empty()) return a;
        PackedVector3Array pv, pn;
        PackedColorArray pc;
        PackedInt32Array pi;
        PackedFloat32Array pf;
        pv.resize((int64_t)v.size());
        std::memcpy(pv.ptrw(), v.data(), v.size() * sizeof(Vector3));
        pn.resize((int64_t)n.size());
        std::memcpy(pn.ptrw(), n.data(), n.size() * sizeof(Vector3));
        pc.resize((int64_t)col.size());
        std::memcpy(pc.ptrw(), col.data(), col.size() * sizeof(Color));
        pi.resize((int64_t)idx.size());
        std::memcpy(pi.ptrw(), idx.data(), idx.size() * sizeof(int32_t));
        pf.resize((int64_t)cus.size());
        std::memcpy(pf.ptrw(), cus.data(), cus.size() * sizeof(float));
        if (sky) brick::sky_levels_into(pv, pn, pc);
        a.resize(Mesh::ARRAY_MAX);
        a[Mesh::ARRAY_VERTEX] = pv;
        a[Mesh::ARRAY_NORMAL] = pn;
        a[Mesh::ARRAY_COLOR] = pc;
        a[Mesh::ARRAY_CUSTOM0] = pf;
        a[Mesh::ARRAY_INDEX] = pi;
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

/// WAVES ON LAKES AND RIVERS (S3, the user's R1, Docs/MineWaterNext.md): an
/// infinite body's open top -- a source not of the open sea, open to the sky,
/// a full course -- rides a small wave, piece by piece as the sea's do. Its
/// height at a stud's middle, metres: LAKE_AMP times how open the stud is
/// (its distance to the body's edge, ramped over LAKE_RAMP studs: a lone
/// source, a channel or a pond's rim stays flat) times two crossing sines.
/// water_fluid.gdshader `lake_wave` is the same expression on `now_s`, the
/// clock MineWater hands both (set_wave_clock).
constexpr float LAKE_AMP = 0.09f;
constexpr int LAKE_R = 6;            ///< studs looked out to for the edge
constexpr float LAKE_RAMP = 5.0f;
double g_wave_t = 0.0;
inline double lake_wave(double x, double z, double t) {
    const double a = (0.8 * x + 0.6 * z) * (Math_TAU / 5.0) - t * 1.6;
    const double b = (-0.5 * x + 0.866 * z) * (Math_TAU / 3.2) - t * 2.1 + 1.7;
    return 0.55 * std::sin(a) + 0.45 * std::sin(b);
}
/// Is (x, b, z) an infinite body's open top (a lake or river piece)?
template <class Get>
inline bool lake_top(Get get, int x, int b, int z) {
    const Cell c = get(x, b, z);
    if (!(c_wet(c) && c_fluid(c) == F_WATER && c_kind(c) == K_SOURCE && !c_ocean(c))) return false;
    if (floor_u(c.solid) + c.amt < CU) return false;
    const Cell a = get(x, b + 1, z);
    return !(c_wet(a) && c_fluid(a) == F_WATER);
}
/// A lake top's wave amplitude, metres (0: flat, or not a lake top).
template <class Get>
inline float lake_amp(Get get, int x, int b, int z) {
    if (!lake_top(get, x, b, z)) return 0.0f;
    int d = LAKE_R + 1;
    for (int r = 1; r <= LAKE_R && d > LAKE_R; ++r) {
        for (int i = -r; i <= r && d > LAKE_R; ++i) {
            if (!lake_top(get, x + i, b, z - r) || !lake_top(get, x + i, b, z + r)
                    || !lake_top(get, x - r, b, z + i) || !lake_top(get, x + r, b, z + i)) {
                d = r;
            }
        }
    }
    return LAKE_AMP * std::min(1.0f, (float)(d - 1) / LAKE_RAMP);
}

/// PACKED BRICK TOPS (W4, Docs/MineWaterNext.md 9): a calm water top -- a
/// pond, a puddle, a source, a lake -- is drawn as flat brick tiles, the
/// biggest that fit, with joints between them; running water stays smooth.
/// The layout is fixed by world position, so a piece changes only when its
/// own cells do: a 4 x 4 block of studs is one tile when its whole top is
/// alike, else it splits in two (4 x 2 or 2 x 4, by the block's parity), each
/// half into 2 x 2, each of those in two (2 x 1 or 1 x 2), then 1 x 1. A
/// cell's piece is the first rect of its chain that is alike (piece_rect):
/// the chain is nested, so every cell of a piece finds the same piece. The
/// mesher and the lake queries (surface_at, ray_cell: a lake piece rides the
/// wave at ITS middle) ask the same rule.
/// The biggest piece, studs a side. 1 (the user, 2026-11-25): every water
/// top a 1 x 1 tile -- the 4 x 4 tiles read as a floor laid over the water,
/// not water. The rule stays (piece_rect), so bigger pieces are one number.
constexpr int PIECE = 1;
struct PRect { int x0, z0, w, h; };
inline PRect piece_child(const PRect &r, int x, int z) {
    bool by_x;
    if (r.w == r.h) by_x = ((fdiv(r.x0, r.w) + fdiv(r.z0, r.h)) & 1) != 0;
    else by_x = r.w > r.h;
    if (by_x) {
        const int hw = r.w / 2;
        return x < r.x0 + hw ? PRect{ r.x0, r.z0, hw, r.h } : PRect{ r.x0 + hw, r.z0, hw, r.h };
    }
    const int hh = r.h / 2;
    return z < r.z0 + hh ? PRect{ r.x0, r.z0, r.w, hh } : PRect{ r.x0, r.z0 + hh, r.w, hh };
}
template <class Alike>
inline PRect piece_rect(int x, int z, Alike alike) {
    PRect r{ fdiv(x, PIECE) * PIECE, fdiv(z, PIECE) * PIECE, PIECE, PIECE };
    while (r.w * r.h > 1 && !alike(r)) r = piece_child(r, x, z);
    return r;
}
/// The lake piece over (x, b, z): its wave amplitude (at its middle cell)
/// and its middle, metres. False when (x, b, z) is no lake top.
template <class Get>
inline bool lake_piece(Get get, int x, int b, int z, float &amp, Vector2 &mid) {
    if (!lake_top(get, x, b, z)) return false;
    const PRect r = piece_rect(x, z, [&](const PRect &q) {
        for (int cz = q.z0; cz < q.z0 + q.h; ++cz) {
            for (int cx = q.x0; cx < q.x0 + q.w; ++cx) {
                if (!lake_top(get, cx, b, cz)) return false;
            }
        }
        return true;
    });
    amp = lake_amp(get, r.x0 + r.w / 2, b, r.z0 + r.h / 2);
    mid = Vector2(((float)r.x0 + 0.5f * (float)r.w) * STUD_M, ((float)r.z0 + 0.5f * (float)r.h) * STUD_M);
    return true;
}

/// Each tile's top corners as last meshed, keyed by corner, course and
/// fluid: where it is (y, metres), how far it was eased from (off) and when
/// that mesh's easing started (t, the shader's clock: Time ticks, seconds).
/// The next mesh's vertices ease on from where the corner is DRAWN then, not
/// from where it was going: a tile meshed again mid-ease (water every tick)
/// snapped every rising cell to its full height -- the "jump" (the user,
/// 2026-11-23).
struct Ease { float y; float off; double t; };
/// A tile's corners: a flat open-addressing table (linear probing, a power of
/// two, at most half full). The easing's lookups and writes were half a
/// mesh's time as a node-based map, then as a sorted list (2026-11-25).
struct EaseMap {
    static constexpr int64_t EMPTY = INT64_MIN;
    std::vector<int64_t> keys;
    std::vector<Ease> vals;
    size_t count = 0;
    static size_t slot(int64_t k, size_t mask) {
        uint64_t h = (uint64_t)k * 0x9E3779B97F4A7C15ULL;
        return (size_t)(h ^ (h >> 29)) & mask;
    }
    void reserve(size_t n) {
        size_t cap = 64;
        while (cap < n * 2) cap <<= 1;
        if (cap <= keys.size()) return;
        std::vector<int64_t> ok = std::move(keys);
        std::vector<Ease> ov = std::move(vals);
        keys.assign(cap, EMPTY);
        vals.assign(cap, Ease{});
        count = 0;
        for (size_t i = 0; i < ok.size(); ++i) {
            if (ok[i] != EMPTY) put(ok[i], ov[i]);
        }
    }
    const Ease *find(int64_t k) const {
        if (keys.empty()) return nullptr;
        const size_t mask = keys.size() - 1;
        for (size_t i = slot(k, mask);; i = (i + 1) & mask) {
            if (keys[i] == k) return &vals[i];
            if (keys[i] == EMPTY) return nullptr;
        }
    }
    void put(int64_t k, const Ease &e) {
        if ((count + 1) * 2 > keys.size()) reserve(count + 1);
        const size_t mask = keys.size() - 1;
        for (size_t i = slot(k, mask);; i = (i + 1) & mask) {
            if (keys[i] == k) { vals[i] = e; return; }
            if (keys[i] == EMPTY) { keys[i] = k; vals[i] = e; ++count; return; }
        }
    }
};
std::unordered_map<int64_t, EaseMap> g_prev_tops;
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
    // wave at its middle (the shader), and four sides cut to the neighbour
    // each faces (the shader, from SKIRT_M) -- the risers between pieces.
    // AT the sea level, as the tiers' tops: 1.5 cm under it (TOP_SINK) their
    // sides showed along the seam as a bright line (the user, 2026-11-25).
    const float y = (float)(g_sea_b * 3) * PLATE_M;
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
            m.sea_quad(d, cq, cq - dn, d - dn, Vector3(1, 0, 0), cc, mid, SKIRT_M);
            m.sea_quad(b, a, a - dn, b - dn, Vector3(-1, 0, 0), cc, mid, SKIRT_M);
            m.sea_quad(cq, b, b - dn, cq - dn, Vector3(0, 0, 1), cc, mid, SKIRT_M);
            m.sea_quad(a, d, d - dn, a - dn, Vector3(0, 0, -1), cc, mid, SKIRT_M);
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
    EaseMap &prev = g_prev_tops[tkey(tx, tz)];
    EaseMap now;
    now.reserve(prev.count + 64);
    auto find_prev = [&](int64_t k) -> const Ease * { return prev.find(k); };
    const double t_now = clock_s();
    // Where a corner last meshed is drawn now (the shader's easing).
    auto shown = [&](const Ease &e, int f) -> float {
        const double k = std::min(1.0, std::max(0.0, (t_now - e.t) / (double)EASE_S[f]));
        return e.y + e.off * (float)(1.0 - k);
    };
    // Corner (ox, oz) (0 or 1) of cell (x, z)'s top, course b, fluid f, is at
    // y now; it was drawn at prev's eased height. A NEW top pops in at its
    // height and holds it, easing only when its level changes: rising from
    // its floor, a cell that took water rose and at once fell again as it
    // passed water on -- the choppy flow (the user, 2026-11-24). Keyed by the CELL's corner, not the shared grid corner: two
    // cells with flat tops at different levels share a grid corner, and a new
    // cell took its neighbour's last height there -- it flashed up to a brick
    // and dropped, its corners at different heights (the user, 2026-11-23).
    auto ckey = [](int x, int b, int z, int ox, int oz, int f) -> int64_t {
        return pack3(2 * x + ox, b * 4 + f, 2 * z + oz);
    };
    auto moved = [&](int x, int b, int z, int ox, int oz, int f, float y) -> float {
        const int64_t k = ckey(x, b, z, ox, oz, f);
        const Ease *e = find_prev(k);
        const float off = e != nullptr ? shown(*e, f) - y : 0.0f;
        now.put(k, Ease{ y, off, t_now });
        return off;
    };
    // Where a neighbour's corner was last mesh (its side's foot follows it),
    // or `fallback` when it was not drawn in this tile.
    auto was = [&](int x, int b, int z, int ox, int oz, int f, float fallback) -> float {
        const Ease *e = find_prev(ckey(x, b, z, ox, oz, f));
        return e != nullptr ? shown(*e, f) : fallback;
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
                // Brick pieces (W4): 1 a still or source top, 2 a lake's.
                struct PTop { uint8_t cls; float h; Color c; float mv; };
                PTop pt[SX * SX];
                for (int i = 0; i < SX * SX; ++i) pt[i].cls = 0;
                bool any_piece = false;
                // Neighbours read from this section directly where they are in
                // it (a wcell a read was most of a mesh, 2026-11-25).
                auto cell = [&](int cx, int cb, int cz) -> const Cell & {
                    const int qx = cx - tx * SX, qz = cz - tz * SX, qb = cb - sb * SB;
                    if ((unsigned)qx < (unsigned)SX && (unsigned)qz < (unsigned)SX && (unsigned)qb < (unsigned)SB
                            && s->ready[qx + SX * qz]) {
                        return s->c[Section::idx(qx, qb, qz)];
                    }
                    return wcell(cx, cb, cz);
                };
                auto top_of = [&](int cx, int cb, int cz, const Cell &cc0) -> int {
                    const Cell &a = cell(cx, cb + 1, cz);
                    if (c_wet(a) && c_fluid(a) == c_fluid(cc0)) return (cb + 1) * CU;
                    return cb * CU + floor_u(cc0.solid) + cc0.amt;
                };
                for (int lz = 0; lz < SX; ++lz) {
                    for (int lx = 0; lx < SX; ++lx) {
                        if (!s->ready[lx + SX * lz]) continue;
                        const Cell c = s->c[Section::idx(lx, lb, lz)];
                        if (!c_wet(c)) continue;
                        const int x = tx * SX + lx, z = tz * SX + lz, b = sb * SB + lb;
                        const int f = c_fluid(c);
                        MeshBuf &m = buf[f];
                        const int own = top_of(x, b, z, c);
                        const int bottom = b * CU + floor_u(c.solid);
                        // Corner heights, plates: (x,z) (x+1,z) (x+1,z+1) (x,z+1).
                        const float h00 = corner_h(x, b, z, x, z, f, own);
                        const float h10 = corner_h(x, b, z, x + 1, z, f, own);
                        const float h11 = corner_h(x, b, z, x + 1, z + 1, f, own);
                        const float h01 = corner_h(x, b, z, x, z + 1, f, own);
                        // Colour: depth, kind, flow direction.
                        int depth = c.amt;
                        for (int k = 1; k <= 3; ++k) {
                            const Cell &d = cell(x, b - k, z);
                            if (!c_wet(d) || c_fluid(d) != f) break;
                            depth += d.amt;
                        }
                        float fx = 0.0f, fz = 0.0f;
                        if (c_kind(c) == K_FLOW) {
                            for (int i = 0; i < 4; ++i) {
                                const Cell &n = cell(x + DX[i], b, z + DZ[i]);
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
                        const Cell &above = cell(x, b + 1, z);
                        const bool top_open = !(c_wet(above) && c_fluid(above) == f);
                        // Only an open top sinks under the course; a side under
                        // more water meets the course above (no seam in a fall).
                        const float sink = top_open ? TOP_SINK : 0.0f;
                        if (real && top_open && f == F_WATER && b == g_sea_b - 1 && own == g_sea_b * CU) {
                            // At the sea's level: the band's (waves with the sea).
                            sea_top[lx + SX * lz] = true;
                            sea_ocean[lx + SX * lz] = c_ocean(c);
                            any_sea = true;
                        } else if (top_open && f == F_WATER && c_kind(c) == K_SOURCE && !c_ocean(c)
                                && lake_top(cell, x, b, z)) {
                            // A lake, river or source top (S3, W4): a brick
                            // piece riding the wave at the piece's middle.
                            pt[lx + SX * lz] = { 2, (float)own, cc, 0.0f };
                            any_piece = true;
                        } else if (top_open && !(c_ocean(c) && own == g_sea_b * CU)
                                && h00 == h10 && h10 == h11 && h11 == h01) {
                            // One easing for the whole top (a rect merges only
                            // tops moving alike); all four corners recorded.
                            const float y = h00 * P - TOP_SINK;
                            const float mv = moved(x, b, z, 0, 0, f, y);
                            moved(x, b, z, 1, 0, f, y);
                            moved(x, b, z, 0, 1, f, y);
                            moved(x, b, z, 1, 1, f, y);
                            if (f == F_WATER && (c_kind(c) == K_STILL || c_kind(c) == K_SOURCE)) {
                                // Calm water: a brick piece (W4).
                                pt[lx + SX * lz] = { 1, h00, cc, mv };
                                any_piece = true;
                            } else {
                                flat[lx + SX * lz] = { true, h00, cc, f, mv };
                                any_flat = true;
                            }
                        } else if (top_open && !(c_ocean(c) && own == g_sea_b * CU)) {
                            const Vector3 a(x0, h00 * P - TOP_SINK, z0), bb(x1, h10 * P - TOP_SINK, z0);
                            const Vector3 cq(x1, h11 * P - TOP_SINK, z1), d(x0, h01 * P - TOP_SINK, z1);
                            Vector3 nrm = (d - a).cross(bb - a);
                            if (nrm.y < 0) nrm = -nrm;
                            nrm = nrm.normalized();
                            m.quad(a, d, cq, bb, nrm, cc, moved(x, b, z, 0, 0, f, a.y), moved(x, b, z, 0, 1, f, d.y),
                                    moved(x, b, z, 1, 1, f, cq.y), moved(x, b, z, 1, 0, f, bb.y));
                        }
                        // Sides: down to whatever covers the neighbour.
                        const float ch[4][2] = { { h10, h11 }, { h00, h01 }, { h01, h11 }, { h00, h10 } };
                        for (int i = 0; i < 4; ++i) {
                            const int nx = x + DX[i], nz = z + DZ[i];
                            const Cell &n = cell(nx, b, nz);
                            int cover;
                            if (c_cap(n) <= 0) continue;
                            const bool wet_n = c_wet(n) && c_fluid(n) == f
                                    && !(c_wet(cell(nx, b + 1, nz)) && c_fluid(cell(nx, b + 1, nz)) == f);
                            if (c_wet(n) && c_fluid(n) == f) cover = top_of(nx, b, nz, n);
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
                            // top as it eases (no gap under a rising one).
                            float f0 = 0.0f, f1 = 0.0f;
                            if (wet_n && cover >= bottom) {
                                const float yn = (float)cover * P - TOP_SINK;
                                f0 = std::min(was(nx, b, nz, o0x - DX[i], o0z - DZ[i], f, yn) - yn, 0.0f);
                                f1 = std::min(was(nx, b, nz, o1x - DX[i], o1z - DZ[i], f, yn) - yn, 0.0f);
                            }
                            m.quad(Vector3(p0.x, y0, p0.z), Vector3(p1.x, y0, p1.z),
                                    Vector3(p1.x, yb, p1.z), Vector3(p0.x, ya, p0.z), nrm, cc,
                                    f0, f1, moved(x, b, z, o1x, o1z, f, yb), moved(x, b, z, o0x, o0z, f, ya));
                        }
                        // Bottom over open air (a fall seen from under it).
                        if (floor_of(c.solid) == 0) {
                            const Cell &d = cell(x, b - 1, z);
                            if (!(c_wet(d) && c_fluid(d) == f) && !(d.solid & 4)) {
                                const float y = (float)(b * CU) * P;
                                m.quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1),
                                        Vector3(x0, y, z1), Vector3(0, -1, 0), cc);
                            }
                        }
                    }
                }
                if (any_piece) {
                    const int b = sb * SB + lb;
                    bool done[SX * SX] = {};
                    for (int lz = 0; lz < SX; ++lz) {
                        for (int lx = 0; lx < SX; ++lx) {
                            const int i0 = lx + SX * lz;
                            if (pt[i0].cls == 0 || done[i0]) continue;
                            const PTop t = pt[i0];
                            // Alike: every cell a piece of its kind, its height,
                            // moving alike (a still one's easing).
                            const PRect r = piece_rect(lx, lz, [&](const PRect &q) {
                                for (int cz = q.z0; cz < q.z0 + q.h; ++cz) {
                                    for (int cx = q.x0; cx < q.x0 + q.w; ++cx) {
                                        const PTop &o = pt[cx + SX * cz];
                                        if (o.cls != t.cls || o.h != t.h || (t.cls == 1 && o.mv != t.mv)) return false;
                                    }
                                }
                                return true;
                            });
                            for (int cz = r.z0; cz < r.z0 + r.h; ++cz) {
                                for (int cx = r.x0; cx < r.x0 + r.w; ++cx) done[cx + SX * cz] = true;
                            }
                            const int wx0 = tx * SX + r.x0, wz0 = tz * SX + r.z0;
                            const float x0 = (float)wx0 * STUD_M, x1 = (float)(wx0 + r.w) * STUD_M;
                            const float z0 = (float)wz0 * STUD_M, z1 = (float)(wz0 + r.h) * STUD_M;
                            const float y = t.h * UNIT_M - TOP_SINK;
                            const Vector2 mid((x0 + x1) * 0.5f, (z0 + z1) * 0.5f);
                            const Vector3 a(x0, y, z0), bq(x0, y, z1), cq(x1, y, z1), dq(x1, y, z0);
                            if (t.cls == 1) {
                                const Color cs[4] = { pt[r.x0 + SX * r.z0].c, pt[r.x0 + SX * (r.z0 + r.h - 1)].c,
                                    pt[r.x0 + r.w - 1 + SX * (r.z0 + r.h - 1)].c, pt[r.x0 + r.w - 1 + SX * r.z0].c };
                                buf[F_WATER].piece_quad(a, bq, cq, dq, Vector3(0, 1, 0), cs, mid, 3.0f, t.mv);
                            } else {
                                // Sides deep enough for the piece beside it at
                                // the other end of its wave.
                                const float amp = lake_amp(cell, wx0 + r.w / 2, b, wz0 + r.h / 2);
                                const Color cc = pt[r.x0 + r.w / 2 + SX * (r.z0 + r.h / 2)].c;
                                const Vector3 dn(0.0f, 2.5f * LAKE_AMP, 0.0f);
                                MeshBuf &m = buf[F_WATER];
                                m.lake_quad(a, bq, cq, dq, Vector3(0, 1, 0), cc, mid, amp);
                                m.lake_quad(dq, cq, cq - dn, dq - dn, Vector3(1, 0, 0), cc, mid, amp);
                                m.lake_quad(bq, a, a - dn, bq - dn, Vector3(-1, 0, 0), cc, mid, amp);
                                m.lake_quad(cq, bq, bq - dn, cq - dn, Vector3(0, 0, 1), cc, mid, amp);
                                m.lake_quad(a, dq, dq - dn, a - dn, Vector3(0, 0, -1), cc, mid, amp);
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
    water = buf[F_WATER].arrays(true);
    lava = buf[F_LAVA].arrays();
    std::swap(prev, now);
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


/// Level the still body holding (x, b, z) (stage P). False when it was left
/// alone: open (a way out lower than its level), joined to running or
/// infinite water, too big, or already level. `done`: cells of bodies seen.
bool level_body(int x0, int b0, int z0, std::unordered_set<int64_t> &done, std::unordered_set<int64_t> &wrote) {
    const Cell &s0 = wcell(x0, b0, z0);
    if (!c_wet(s0) || c_kind(s0) != K_STILL) return false;
    const int f = c_fluid(s0);
    // The body: connected still cells of its fluid.
    std::vector<int64_t> body{ pack3(x0, b0, z0) };
    std::unordered_set<int64_t> in_body{ body[0] };
    int64_t units = 0;
    static const int NX[6] = { 1, -1, 0, 0, 0, 0 }, NB[6] = { 0, 0, 0, 0, 1, -1 }, NZ[6] = { 0, 0, 1, -1, 0, 0 };
    for (size_t h = 0; h < body.size(); ++h) {
        if (body.size() > (size_t)LEVEL_MAX) return false;
        int x, b, z;
        unpack3(body[h], x, b, z);
        units += wcell(x, b, z).amt;
        for (int i = 0; i < 6; ++i) {
            const Cell &n = wcell(x + NX[i], b + NB[i], z + NZ[i]);
            if (!c_wet(n) || c_fluid(n) != f) continue;
            if (c_kind(n) != K_STILL) return false;      // running or infinite water joined
            const int64_t nk = pack3(x + NX[i], b + NB[i], z + NZ[i]);
            if (in_body.insert(nk).second) body.push_back(nk);
        }
    }
    for (int64_t k : body) done.insert(k);
    // Fill again from the lowest floor up: cells join as the level reaches
    // their floor (a priority flood); each unit layer gives a unit to every
    // cell the level is inside. A cell found lower than the level is a way
    // out: the rules run it, not this.
    struct Q { int key; int64_t k; bool operator>(const Q &o) const { return key > o.key; } };
    std::priority_queue<Q, std::vector<Q>, std::greater<Q>> pq;
    std::unordered_set<int64_t> seen;
    auto floor_key = [](int b, const Cell &c) { return b * CU + floor_u(c.solid); };
    {
        int best = INT_MAX;
        int64_t bk = body[0];
        for (int64_t k : body) {
            int x, b, z;
            unpack3(k, x, b, z);
            const int fk = floor_key(b, wcell(x, b, z));
            if (fk < best) { best = fk; bk = k; }
        }
        pq.push({ best, bk });
        seen.insert(bk);
    }
    struct In { int64_t k; int lo, hi; int fill; };
    std::vector<In> reach;
    int level = pq.top().key;
    int64_t left = units;
    while (left > 0) {
        while (!pq.empty() && pq.top().key <= level) {
            const Q q = pq.top();
            pq.pop();
            if (q.key < level) return false;              // a way out below the level
            int x, b, z;
            unpack3(q.k, x, b, z);
            const Cell &c = wcell(x, b, z);
            reach.push_back({ q.k, q.key, (b + 1) * CU, 0 });
            for (int i = 0; i < 6; ++i) {
                const int nx = x + NX[i], nb = b + NB[i], nz = z + NZ[i];
                const Cell &n = wcell(nx, nb, nz);
                if (c_cap(n) <= 0) continue;
                if (c_wet(n) && c_fluid(n) != f) continue;   // another fluid: a wall
                if (NB[i] > 0 && (n.solid & 1)) continue;   // a plate over this cell
                if (NB[i] < 0 && floor_of(c.solid) > 0) continue;
                const int64_t nk = pack3(nx, nb, nz);
                if (!seen.insert(nk).second) continue;
                if (seen.size() > (size_t)LEVEL_MAX * 4) return false;
                pq.push({ floor_key(nb, n), nk });
            }
        }
        int active = 0;
        for (const In &r : reach) {
            if (r.lo <= level && level < r.hi) ++active;
        }
        if (active == 0) return false;
        if (left >= active) {
            for (In &r : reach) {
                if (r.lo <= level && level < r.hi) ++r.fill;
            }
            left -= active;
            ++level;
        } else {
            for (In &r : reach) {
                if (left == 0) break;
                if (r.lo <= level && level < r.hi) { ++r.fill; --left; }
            }
        }
    }
    // Write what changed: the reached cells' new water, and nothing left in
    // body cells above the level.
    std::unordered_map<int64_t, int> fill;
    for (const In &r : reach) fill[r.k] = r.fill;
    for (int64_t k : body) fill.emplace(k, 0);
    bool any = false;
    for (const auto &e : fill) {
        int x, b, z;
        unpack3(e.first, x, b, z);
        const Cell &c = wcell(x, b, z);
        const int have = (c_wet(c) && c_fluid(c) == f) ? (int)c.amt : 0;
        if (have == e.second) continue;
        Cell n = c;
        if (e.second > 0) {
            n.st = mk_st(f, K_STILL, false);
            n.amt = (uint8_t)e.second;
            n.aux = E_NONE;
        } else {
            n = Cell{ c.solid, 0, 0, 0 };
        }
        g_sets.push_back({ x, b, z, n });
        wrote.insert(e.first);
        any = true;
    }
    return any;
}

int g_levelled = 0;

/// The bodies due a levelling, a few a look, in the sim radius.
void level_due() {
    if (g_level_due.empty() || g_tick % LEVEL_EVERY != 0) return;
    std::vector<int64_t> now;
    for (const auto &e : g_level_due) {
        if (e.second > g_tick) continue;
        int x, b, z;
        unpack3(e.first, x, b, z);
        if (dist2_centre(x, z) > g_sim_r * g_sim_r) continue;
        now.push_back(e.first);
        if ((int)now.size() >= LEVEL_LOOKS) break;
    }
    std::unordered_set<int64_t> done, wrote;
    const size_t sets_before = g_sets.size();
    for (int64_t k : now) {
        g_level_due.erase(k);
        if (done.count(k)) continue;
        int x, b, z;
        unpack3(k, x, b, z);
        if (level_body(x, b, z, done, wrote)) ++g_levelled;
    }
    // This tick's moves were worked out from the water before the levelling:
    // one into or out of a levelled cell would take or add units twice.
    if (!wrote.empty()) {
        // The apply keeps a cell's first set: the rules' own sets to a
        // levelled cell this tick (its edge distance, say) would win.
        std::vector<SetOp> keep;
        keep.reserve(g_sets.size());
        for (size_t i = 0; i < g_sets.size(); ++i) {
            const SetOp &o = g_sets[i];
            if (i < sets_before && wrote.count(pack3(o.x, o.b, o.z))) continue;
            keep.push_back(o);
        }
        g_sets.swap(keep);
        g_moves.erase(std::remove_if(g_moves.begin(), g_moves.end(), [&](const MoveOp &m) {
            return wrote.count(pack3(m.x, m.b, m.z)) || wrote.count(pack3(m.tx, m.tb, m.tz));
        }), g_moves.end());
    }
}

/// SECTIONS FAR AWAY ARE LET GO. Every column the water ever sampled kept its
/// section for good -- the flow's look for a drop, priming, the sea's floor
/// -- so a long walk left thousands behind, and the save, the sea mask and
/// every lookup walked them. A section with nothing queued goes: one never
/// written (dry, or only the generated sea, lakes, pools -- the seed and the
/// terrain's edits again, sampled afresh if anything asks); a written one is
/// parked, its changed cells kept (g_parked, W3). Wet sections used to stay
/// for good: 1,030 of them after a flight over the sea.
constexpr uint32_t EVICT_EVERY = 50;     ///< ticks (5 s)
constexpr double EVICT_PAST = 1.5;       ///< x the sim radius, plus a tile (2.0 kept ~775 sections, 69 MB, round the player: W3)
int g_evicted = 0;

void evict_far() {
    if (g_tick % EVICT_EVERY != 0) return;
    const double tile_m = (double)SX * STUD_M;
    const double r = g_sim_r * EVICT_PAST + tile_m;
    std::vector<int64_t> gone;
    for (const auto &e : g_sec) {
        const Section *s = e.second.get();
        const double cx = ((double)s->sx + 0.5) * tile_m - g_cx;
        const double cz = ((double)s->sz + 0.5) * tile_m - g_cz;
        const double d2 = cx * cx + cz * cz;
        if (d2 <= r * r) continue;
        if (g_keep_inland_m > r && d2 <= g_keep_inland_m * g_keep_inland_m && s->wet > 0) {
            // Inland water out to the chosen LOD stays, to be drawn (its
            // far mesh reads sections); a section of only open sea goes.
            bool inland = false;
            for (const Cell &c : s->c) {
                if (c_wet(c) && !c_ocean(c)) { inland = true; break; }
            }
            if (inland) continue;
        }
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
        if (s->written) {
            // Its changed cells: the ready columns' against the generated
            // world, and an unsampled column's still-pending ones.
            std::vector<Diff> keep;
            for (int col = 0; col < SCOL; ++col) {
                const int lx = col % SX, lz = col / SX;
                if (!s->ready[col]) continue;
                for (int lb = 0; lb < SB; ++lb) {
                    const int i = Section::idx(lx, lb, lz);
                    const Cell &c = s->c[i];
                    Cell g = c;
                    gen_fluid(g, s->sx * SX + lx, s->sb * SB + lb, s->sz * SX + lz, s->gtop[col],
                            s->spring[col], s->lake[col]);
                    if (c.st == g.st && c.amt == g.amt && c.aux == g.aux) continue;
                    keep.push_back({ (uint16_t)i, c.st, c.amt, c.aux });
                }
            }
            for (const Diff &d : s->pending) {
                if (!s->ready[diff_col(d)]) keep.push_back(d);
            }
            std::sort(keep.begin(), keep.end(), [](const Diff &a, const Diff &b) {
                return diff_col(a) != diff_col(b) ? diff_col(a) < diff_col(b) : a.i < b.i;
            });
            if (!keep.empty()) {
                g_parked_bytes += (int64_t)keep.size() * (int64_t)sizeof(Diff);
                g_parked[k] = std::move(keep);
            }
        }
        const int lv = s->lava.load(std::memory_order_relaxed);
        if (lv != 0) g_lava_total.fetch_add(-lv, std::memory_order_relaxed);
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
    if (g_simulate) level_due();

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
    const std::unordered_set<int64_t> asked(g_mesh_requests.begin(), g_mesh_requests.end());
    for (int64_t k : g_mesh_requests) g_dirty_tiles.insert(k);
    g_mesh_requests.clear();
    int meshed = 0;
    std::vector<int64_t> left;
    const double tile_len = (double)SX * STUD_M;
    const int ctx = (int)std::floor(g_cx / tile_len), ctz = (int)std::floor(g_cz / tile_len);
    for (int64_t k : g_dirty_tiles) {
        if (meshed >= MESH_PER_TICK) { left.push_back(k); continue; }
        const int tx = tile_coord(k, false);
        const int tz = tile_coord(k, true);
        auto at = g_tile_meshed_at.find(k);
        const bool by_player = std::abs(tx - ctx) <= 1 && std::abs(tz - ctz) <= 1;
        if (at != g_tile_meshed_at.end() && g_tick - at->second < MESH_GAP && !by_player && !asked.count(k)) {
            left.push_back(k);
            continue;
        }
        g_tile_meshed_at[k] = g_tick;
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
    g_parked.clear();
    g_parked_bytes = 0;
    g_level_due.clear();
    g_cold_tiles.clear();
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
    g_lava_total.store(0);
    {
        std::lock_guard<std::mutex> ll(g_lava_mx);
        g_lava_dirty.clear();
    }
    g_prev_tops.clear();
    g_tile_meshed_at.clear();
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

void BrickFluid::set_wave_clock(double t) { g_wave_t = t; }

void BrickFluid::rain(Vector3 centre, double radius_m, double drops) {
    if (drops <= 0.0 || radius_m <= 0.0) return;
    Cmd c;
    c.type = 12;
    c.a = Vector3i((int)std::floor(centre.x / STUD_M), 0, (int)std::floor(centre.z / STUD_M));
    c.b = Vector3i((int)std::ceil(radius_m / STUD_M), 0, 0);
    c.amount = (int)std::min(drops, 1.0e9);
    push_cmd(c);
}

int64_t BrickFluid::rain_landed() { return g_rain_landed; }

int64_t BrickFluid::rain_soaked() { return g_rain_soaked; }

bool BrickFluid::cold_at(int x, int z) { return cold_column(x, z); }

void BrickFluid::set_cold_test(bool on) {
    g_cold_test = on;
    g_cold_tiles.clear();
}

PackedInt32Array BrickFluid::freeze_scan(int tiles, int max_out) {
    // Water that freezes: the open top cell of calm water (still or a
    // source, not the sea's) under the sky, in a cold tile (its middle
    // column's), of a few random tiles of the sim ring with water in them.
    PackedInt32Array out;
    if (max_out <= 0 || tiles <= 0) return out;
    MainLock lk;
    std::unordered_map<int64_t, bool> &cold_tiles = g_cold_tiles;
    if (cold_tiles.size() > 4096) cold_tiles.clear();
    std::vector<int64_t> wet;
    for (const auto &e : g_tile_secs) {
        const int tx = (int)((int32_t)((uint32_t)(e.first >> 28) << 4) >> 4);
        const int tz = (int)((int32_t)((uint32_t)(e.first & 0xFFFFFFF) << 4) >> 4);
        if (dist2_centre(tx * SX + SX / 2, tz * SX + SX / 2) > g_sim_r * g_sim_r) continue;
        bool any = false;
        for (int sb : e.second) {
            const Section *sc = sec_find(tx, sb, tz);
            if (sc != nullptr && sc->wet > 0) { any = true; break; }
        }
        if (!any) continue;
        auto ct = cold_tiles.find(e.first);
        if (ct == cold_tiles.end()) ct = cold_tiles.emplace(e.first, cold_column(tx * SX + SX / 2, tz * SX + SX / 2)).first;
        if (ct->second) wet.push_back(e.first);
    }
    if (wet.empty()) return out;
    struct Cand { int x, lo, hi, z; };
    std::vector<Cand> cand;
    // Distinct tiles, at random.
    for (size_t i = wet.size(); i > 1; --i) std::swap(wet[i - 1], wet[hmix(++g_rain_seq * 0x27D4EB2FU) % i]);
    for (int t = 0; t < tiles && t < (int)wet.size(); ++t) {
        const int64_t key = wet[t];
        const int tx = (int)((int32_t)((uint32_t)(key >> 28) << 4) >> 4);
        const int tz = (int)((int32_t)((uint32_t)(key & 0xFFFFFFF) << 4) >> 4);
        auto ts = g_tile_secs.find(key);
        if (ts == g_tile_secs.end()) continue;
        for (int sb : ts->second) {
            const Section *sc = sec_find(tx, sb, tz);
            if (sc == nullptr || sc->wet <= 0) continue;
            for (int lz = 0; lz < SX; ++lz) {
                for (int lx = 0; lx < SX; ++lx) {
                    if (!sc->ready[lx + SX * lz]) continue;
                    for (int lb = SB - 1; lb >= 0; --lb) {
                        const Cell &c = sc->c[Section::idx(lx, lb, lz)];
                        if (!c_wet(c)) continue;
                        if (c_fluid(c) != F_WATER || c_ocean(c)) break;
                        if (c_kind(c) != K_STILL && c_kind(c) != K_SOURCE) break;
                        const int x = tx * SX + lx, z = tz * SX + lz, b = sb * SB + lb;
                        const Cell a = rcell(x, b + 1, z);
                        if (c_wet(a)) break;
                        // Under the sky: nothing solid over it.
                        if (rain_top(x, z) >= (b + 1) * 3) break;
                        const int f_pl = floor_u(c.solid) / U;
                        const int top_pl = (floor_u(c.solid) + c.amt) / U;
                        if (top_pl > f_pl) cand.push_back({ x, b * 3 + f_pl, b * 3 + top_pl - 1, z });
                        break;
                    }
                }
            }
        }
    }
    for (int i = 0; i < max_out && !cand.empty(); ++i) {
        const size_t j = hmix(++g_rain_seq * 0x165667B1U) % cand.size();
        out.push_back(cand[j].x);
        out.push_back(cand[j].lo);
        out.push_back(cand[j].hi);
        out.push_back(cand[j].z);
        cand[j] = cand.back();
        cand.pop_back();
    }
    return out;
}

void BrickFluid::set_keep_inland(double metres) {
    g_keep_inland_m = std::max(0.0, metres);
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

bool BrickFluid::any_fluid(Vector3i lo, Vector3i hi, int fluid) {
    const int x0 = std::min(lo.x, hi.x), x1 = std::max(lo.x, hi.x);
    const int b0 = std::min(lo.y, hi.y), b1 = std::max(lo.y, hi.y);
    const int z0 = std::min(lo.z, hi.z), z1 = std::max(lo.z, hi.z);
    // A box is a plot's reach, not a region: refuse anything huge.
    if ((int64_t)(x1 - x0 + 1) * (b1 - b0 + 1) * (z1 - z0 + 1) > 65536) {
        return false;
    }
    MainLock lk;
    for (int b = b0; b <= b1; ++b) {
        for (int z = z0; z <= z1; ++z) {
            for (int x = x0; x <= x1; ++x) {
                const Cell c = rcell(x, b, z);
                if (c_wet(c) && c_fluid(c) == fluid) {
                    return true;
                }
            }
        }
    }
    return false;
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
    // A lake's wave (S3): its top plus the wave at the stud's middle, from
    // the top's own cell or the air over it (a crest).
    for (int bb = k.y; bb >= k.y - 1; --bb) {
        float amp = 0.0f;
        Vector2 mid;
        if (!lake_piece(rcell, k.x, bb, k.z, amp, mid) || amp <= 0.0f) continue;
        const Cell t = rcell(k.x, bb, k.z);
        const double top = (double)(bb * CU + floor_u(t.solid) + t.amt) * UNIT_M;
        return top + amp * lake_wave(mid.x, mid.y, g_wave_t);
    }
    if (!c_wet(c)) {
        // Just above a shallow cell: its top is still the surface here.
        return -INFINITY;
    }
    const int f = c_fluid(c);
    int b = k.y;
    // Up to the top of the body, however deep (the deep ocean is 70-90 m,
    // Docs/MineOcean.md 2.1; 64 bricks stopped 27 m down, and a swimmer
    // deeper floated to that as its surface). The bedrock is 300 bricks down.
    for (int i = 0; i < 400; ++i) {
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
        Cell cl = rcell(c[0], c[1], c[2]);
        bool hit_fluid = c_wet(cl);
        // A lake's crest drawn up into this air cell (S3, R2): the source
        // under it is what the bucket takes.
        if (!hit_fluid && cl.solid == 0) {
            float amp = 0.0f;
            Vector2 mid;
            if (lake_piece(rcell, c[0], c[1] - 1, c[2], amp, mid) && amp > 0.0f) {
                const Cell lc = rcell(c[0], c[1] - 1, c[2]);
                const double crest = (double)((c[1] - 1) * CU + floor_u(lc.solid) + lc.amt) * UNIT_M
                        + amp * lake_wave(mid.x, mid.y, g_wave_t);
                const double y_in = from.y + d.y * t;
                const double y_out = from.y + d.y * std::min(std::min(tmax[0], tmax[1]), tmax[2]);
                if (std::min(y_in, y_out) <= crest) {
                    c[1] -= 1;
                    cl = lc;
                    hit_fluid = true;
                    nrm = Vector3i(0, 1, 0);
                }
            }
        }
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
    d["parked"] = (int64_t)g_parked.size();
    d["parked_bytes"] = g_parked_bytes + (int64_t)g_parked.size() * 64;
    bytes += g_parked_bytes + (int64_t)g_parked.size() * 64;
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
    // A section back from parking: the changed cells of columns not yet
    // sampled are still in `pending`.
    for (const auto &e : g_sec) {
        const Section &s = *e.second;
        for (const Diff &d : s.pending) {
            if (s.ready[diff_col(d)]) continue;
            const int lx = d.i % SX, lz = (d.i / SX) % SX, lb = d.i / SCOL;
            put32(s.sx * SX + lx);
            put32(s.sb * SB + lb);
            put32(s.sz * SX + lz);
            buf.push_back(d.st);
            buf.push_back(d.amt);
            buf.push_back((uint8_t)(d.aux & 0x7F));
        }
    }
    // Parked sections: their changed cells are the save's records already.
    for (const auto &e : g_parked) {
        int sx, sb, sz;
        unpack3(e.first, sx, sb, sz);
        for (const Diff &d : e.second) {
            const int lx = d.i % SX, lz = (d.i / SX) % SX, lb = d.i / SCOL;
            put32(sx * SX + lx);
            put32(sb * SB + lb);
            put32(sz * SX + lz);
            buf.push_back(d.st);
            buf.push_back(d.amt);
            buf.push_back((uint8_t)(d.aux & 0x7F));
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
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_keep_inland", "metres"), &BrickFluid::set_keep_inland);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_wave_clock", "t"), &BrickFluid::set_wave_clock);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("rain", "centre", "radius_m", "drops"), &BrickFluid::rain);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("rain_landed"), &BrickFluid::rain_landed);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("rain_soaked"), &BrickFluid::rain_soaked);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("cold_at", "x", "z"), &BrickFluid::cold_at);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("set_cold_test", "on"), &BrickFluid::set_cold_test);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("freeze_scan", "tiles", "max_out"), &BrickFluid::freeze_scan);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("request_mesh", "tx", "tz"), &BrickFluid::request_mesh);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("drawn_tiles"), &BrickFluid::drawn_tiles);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("cell_info", "cell"), &BrickFluid::cell_info);
    ClassDB::bind_static_method("BrickFluid", D_METHOD("any_fluid", "lo", "hi", "fluid"), &BrickFluid::any_fluid);
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
