#include <array>
#include <map>
#include "brick_terrain.h"
#include "brick_fluid.h"
#include "terrain_biomes.h"
#include "terrain_bond.h"
#include "terrain_fit.h"

#include <shared_mutex>
#include <mutex>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <cstring>
#include <atomic>
#include <cmath>
#include <functional>
#include <memory>
#include <unordered_map>
#include <set>
#include <climits>

using namespace godot;

namespace brick {

// --- noise -----------------------------------------------------------------

static inline float fade(float t) {
    // Quintic. A cubic fade leaves second-derivative discontinuities at the
    // lattice, which show up as faint grid lines once the height is quantised
    // to terraces -- the quantisation amplifies exactly the artefact a cubic
    // has.
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

static inline float grad01(int ix, int iy, uint32_t seed) {
    return hashf(ix, iy, (int32_t)seed) * 2.0f - 1.0f;
}

float value_noise(float x, float y, uint32_t seed) {
    const float fx = std::floor(x);
    const float fy = std::floor(y);
    const int ix = (int)fx;
    const int iy = (int)fy;
    const float tx = fade(x - fx);
    const float ty = fade(y - fy);

    const float v00 = grad01(ix, iy, seed);
    const float v10 = grad01(ix + 1, iy, seed);
    const float v01 = grad01(ix, iy + 1, seed);
    const float v11 = grad01(ix + 1, iy + 1, seed);

    const float a = v00 + (v10 - v00) * tx;
    const float b = v01 + (v11 - v01) * tx;
    return a + (b - a) * ty;
}

float fbm(float x, float y, uint32_t seed, int octaves, float lacunarity, float gain) {
    float sum = 0.0f;
    float amp = 1.0f;
    float norm = 0.0f;
    float fx = x;
    float fy = y;
    for (int i = 0; i < octaves; ++i) {
        sum += value_noise(fx, fy, seed + (uint32_t)i * 7919U) * amp;
        norm += amp;
        amp *= gain;
        fx *= lacunarity;
        fy *= lacunarity;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

static inline int floor_div(int a, int b) {
    const int q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

float value_noise3(float x, float y, float z, uint32_t seed) {
    const float fx = std::floor(x), fy = std::floor(y), fz = std::floor(z);
    const int ix = (int)fx, iy = (int)fy, iz = (int)fz;
    const float tx = fade(x - fx), ty = fade(y - fy), tz = fade(z - fz);
    float c[8];
    for (int k = 0; k < 8; ++k) {
        c[k] = hashf(ix + (k & 1), iy + ((k >> 1) & 1),
                (int32_t)(seed ^ (uint32_t)(iz + ((k >> 2) & 1)) * 2654435761U)) * 2.0f - 1.0f;
    }
    const float x00 = c[0] + (c[1] - c[0]) * tx;
    const float x10 = c[2] + (c[3] - c[2]) * tx;
    const float x01 = c[4] + (c[5] - c[4]) * tx;
    const float x11 = c[6] + (c[7] - c[6]) * tx;
    const float y0v = x00 + (x10 - x00) * ty;
    const float y1v = x01 + (x11 - x01) * ty;
    return y0v + (y1v - y0v) * tz;
}

// --- the field -------------------------------------------------------------

/// An authored flat spot. See BrickTerrain::add_pad.
struct Pad {
    int x = 0, z = 0;
    int radius = 0;     ///< studs of dead flat, in X
    int radius_z = 0;   ///< and in Z: a pad is a rectangle
    int skirt = 0;      ///< studs of blend back to the natural ground
    float plates = 0.0f;
};
static std::vector<Pad> g_pads;

/// An authored patch of material. See BrickTerrain::add_paint.
struct Paint {
    int x = 0, z = 0, radius = 0, skirt = 0;
    uint8_t mat = 0;
};
static std::vector<Paint> g_paints;

/// Direction TO the sun. Zero means "bake no shadow".
static Vector3 g_sun_dir(0.0f, 0.0f, 0.0f);
/// How far a shadow may reach, in studs, and the step along the ray.
///
/// 64 studs is 22 m: a 12 m hill at a 30-degree sun casts about that far.
/// Two studs a step is half a brick of horizontal resolution, which is finer
/// than the ground it is marching over.
constexpr int SUN_REACH = 64;
constexpr int SUN_STEP = 2;
/// What a shadowed piece is multiplied by. Not black: the sky still lights
/// it, and the ambient term in the shader is doing that job for everything
/// else.
constexpr float SUN_SHADE = 0.62f;

/// Collision heights under a curve are rounded to this, so the greedy merge
/// still has equal values to join. See build_tile.
constexpr float COLLIDE_QUANTUM = PLATE_M * 0.25f;

/// Curved ground. See BrickTerrain::set_smooth_terrain.
static bool g_smooth_terrain = false;
/// Which ground curves. See BrickTerrain::set_smooth_slopes.
static bool g_smooth_slopes = false;
/// Studs a side of one LOW-POLY curve quad. See BrickTerrain::set_curve_step.
static int g_curve_step = 4;
/// Share of curve cells a brick patch starts on. See set_curve_bricks. Off:
/// bricks standing proud of a slope were not what was wanted (18.8) -- the
/// bricks belong flush, in the flat places.
static float g_curve_bricks = 0.0f;
/// On "slopes" ground, the share of level curve cells that take a stud.
constexpr float CURVE_STUD_CHANCE = 0.125f;
/// Plates a stud: broad steepness above which ground curves (18.8).
static float g_curve_slope = 0.15f;
/// SHELVES on slopes ground (Terrain.md 18.8): bricks a level, and the share
/// of each level's rise that is flat shelf. 0 bricks for none.
static float g_shelf_bricks = 4.0f;
static float g_shelf_share = 0.3f;
/// Bumped by every pad edit, so a cache of the field can tell it moved.
static std::atomic<uint32_t> g_pad_gen{ 1 };

namespace smoothcfg {
/// ~67 studs (23 m) a biome patch.
///
/// This was 0.0035 -- a 285-stud patch -- and the whole 160-stud test field
/// then sat INSIDE ONE NOISE CELL, so the "regional" mask was a single
/// constant and 100% of the map came out curved. A mask whose wavelength
/// exceeds the world cannot be a mask. The plate-step mask had exactly the
/// same bug and the same fix; both are measured now rather than asserted.
constexpr float FREQ = 0.015f;
/// Above this the biome asks for curves. value_noise is [-1, 1], so zero is
/// about half the map before steepness gets a say -- and half the map was
/// far too much: curved ground has no PIECES in it, so wherever it went the
/// 2x4s and the smooth tiles went with it, and the ground stopped reading as
/// laid brick. Curves are meant to be the odd hillside, not the default
/// surface. 0.35 puts them on about a quarter of it.
constexpr float BIAS = 0.35f;
/// ...but only where it is not steep. A cliff of stacked courses looks
/// BUILT, and a smooth 45-degree slope is where a heightfield looks most
/// like a heightfield -- so steepness overrules the biome, never the other
/// way round.
///
/// In plates a stud, on the UNQUANTISED surface, and sampled ONCE PER
/// REGION rather than per column.
///
/// Per column it was salt and pepper. Measured on this field the slope is
/// median 0.17 and p90 0.50, so a 0.30 threshold rejected about a third of
/// the columns INSIDE a curved patch -- and each one came back as a single
/// brick standing in the middle of smooth ground. The terrain has to be one
/// thing or the other over an area you can walk across: a smooth hillside,
/// or laid brick.
///
/// 0.45 with a regional sample leaves the gate for ground that is genuinely
/// steep across a whole region, which is where stacked courses look built.
constexpr float MAX_SLOPE = 0.45f;
/// Studs. The block the steepness question is asked about — 2.8 m, a few
/// paces, so a region is never smaller than something you can stand on.
constexpr int REGION = 8;
/// ...and the same test on the QUANTISED surface, in plates, because the
/// continuous one does not know about the plate-step mask: a curve can be
/// gentle and still straddle the boundary where quantisation changes from
/// plates to bricks, and the drawn step there is a whole brick. The probe
/// found a 3-plate cliff under a curve on the first run.
constexpr int MAX_QSTEP = 2;
/// Slopes mode's cliff, in plates a stud, regional: steeper than this is
/// stacked courses. 3.0 is ~50 degrees. It was 1.5, steeper than anything
/// the noise made -- until shelves (18.8) gathered each level's rise into
/// ramps up to twice as steep, and every steep stretch of hillside came out
/// as stacked brick: rows of ledges across the slopes, the "smooth tiles
/// everywhere" the curves were meant to replace. A cliff is for sculpted and
/// dug ground.
constexpr float CLIFF_SLOPE = 3.0f;
}

/// Steepness at a column, in plates a stud: the larger of the two central
/// differences of the unquantised surface.
static float surface_slope(const Field &f, int x, int z) {
    const float dx = (f.raw_plate(x + 1, z) - f.raw_plate(x - 1, z)) * 0.5f;
    const float dz = (f.raw_plate(x, z + 1) - f.raw_plate(x, z - 1)) * 0.5f;
    return std::max(std::abs(dx), std::abs(dz));
}

static int layer_form(int x, int z);
static bool on_pad_flat(int x, int z);
static uint64_t sculpt_gen_now();

/// Steepness of the 8-stud block whose middle is (bx, bz), remembered: the
/// slope rule asks four blocks a column and a tile asks the same few dozen
/// over and over. Direct-mapped, per thread, keyed by the block and by
/// everything that moves the field (seed, sculpt, pads).
static float block_slope(const Field &f, int bx, int bz) {
    struct Slot { int x, z; uint32_t seed, pads; uint64_t sculpt; float v; bool ok; };
    thread_local Slot slots[256] = {};
    const uint32_t pads = g_pad_gen.load(std::memory_order_acquire);
    const uint64_t sculpt = sculpt_gen_now();
    Slot &s = slots[((uint32_t)bx * 73856093u ^ (uint32_t)bz * 19349663u) & 255u];
    if (!s.ok || s.x != bx || s.z != bz || s.seed != f.seed || s.pads != pads
            || s.sculpt != sculpt) {
        s = { bx, bz, f.seed, pads, sculpt, surface_slope(f, bx, bz), true };
    }
    return s.v;
}

/// Steepness for the slope rule: the block slopes, blended bilinearly
/// between block middles. A threshold on that is a smooth CONTOUR -- an
/// organic edge between laid brick and curved ground, not 8-stud squares --
/// and still cannot speckle, because the blend never flips between
/// neighbours the way a per-column slope does (§18.5).
static float regional_slope(const Field &f, int x, int z) {
    const int r = smoothcfg::REGION;
    const int h = r / 2;
    const int x0 = floor_div(x - h, r) * r + h;
    const int z0 = floor_div(z - h, r) * r + h;
    const float tx = (float)(x - x0) / (float)r;
    const float tz = (float)(z - z0) / (float)r;
    const float a = block_slope(f, x0, z0);
    const float b = block_slope(f, x0 + r, z0);
    const float c = block_slope(f, x0, z0 + r);
    const float d = block_slope(f, x0 + r, z0 + r);
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz;
}

/// How flat the ground is ROUND a block: the steepest of the 3 x 3 blocks
/// centred on it. Laid brick on slopes ground is for ground that is flat
/// across a place -- a hill top, a valley floor, a plain (Terrain.md 18.8) --
/// not every few studs that happen to level off on the way down a hill; a
/// block counts as flat only if its neighbours are too, so a flat patch is
/// never smaller than ~24 studs across.
static float broad_block_slope(const Field &f, int bx, int bz) {
    const int r = smoothcfg::REGION;
    float worst = 0.0f;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            worst = std::max(worst, block_slope(f, bx + dx * r, bz + dz * r));
        }
    }
    return worst;
}

/// broad_block_slope blended between block middles, as regional_slope: a
/// threshold on it is a smooth contour, never squares and never speckle.
static float broad_slope(const Field &f, int x, int z) {
    const int r = smoothcfg::REGION;
    const int h = r / 2;
    const int x0 = floor_div(x - h, r) * r + h;
    const int z0 = floor_div(z - h, r) * r + h;
    const float tx = (float)(x - x0) / (float)r;
    const float tz = (float)(z - z0) / (float)r;
    const float a = broad_block_slope(f, x0, z0);
    const float b = broad_block_slope(f, x0 + r, z0);
    const float c = broad_block_slope(f, x0, z0 + r);
    const float d = broad_block_slope(f, x0 + r, z0 + r);
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz;
}

/// Curve or bricks, for one column. `qstep` is the largest step to a
/// neighbour on the QUANTISED surface, in plates -- the caller has it to
/// hand, and recomputing it would be four more field evaluations a cell.
static bool smooth_column(const Field &f, int x, int z, int qstep) {
    // SLOPES mode (Terrain.md 18.6): the ground is curved where it slopes
    // and laid brick where it is flat -- the other way round from the biome
    // rule below. What the author painted wins; a pad is somewhere a thing
    // stands, so it is brick; a cliff stays stacked courses.
    //
    // A cliff here is REGIONAL steepness, not the drawn step: where the
    // plate-step mask quantises to whole bricks every terrace edge is a
    // 3-plate step, and the per-column test below bricked all of them --
    // the slope could never curve, and its flat tops came out as lone
    // curved cells. The curve is drawn from the unquantised surface, so a
    // brick step under it is not a wall.
    if (g_smooth_slopes) {
        const int painted = layer_form(x, z);
        if (painted != 0xFF) {
            return painted == 1;
        }
        if (on_pad_flat(x, z)) {
            return false;
        }
        // Broad slope, not regional: brick only where the ground is flat
        // across a place (18.8). The cliff test stays on the block's own
        // slope -- a cliff is a cliff however flat the land above it is.
        const float s = broad_slope(f, x, z);
        return s > g_curve_slope && regional_slope(f, x, z) < smoothcfg::CLIFF_SLOPE;
    }
    // A real cliff stays brick wherever it is. This is per COLUMN because a
    // step of more than two plates is a wall, and a wall is a wall whatever
    // the ground around it is doing.
    if (qstep > smoothcfg::MAX_QSTEP) {
        return false;
    }
    // Steepness, asked once for the whole region: the same answer for every
    // column in an 8-stud block, so it cannot speckle.
    const int bx = floor_div(x, smoothcfg::REGION) * smoothcfg::REGION
            + smoothcfg::REGION / 2;
    const int bz = floor_div(z, smoothcfg::REGION) * smoothcfg::REGION
            + smoothcfg::REGION / 2;
    if (surface_slope(f, bx, bz) > smoothcfg::MAX_SLOPE) {
        return false;
    }
    // The biome boundary stays PER COLUMN, because it is a smooth field and
    // its contour is the organic edge between the two kinds of ground. Only
    // the tests that can flip between neighbours had to become regional.
    return value_noise((float)x * smoothcfg::FREQ, (float)z * smoothcfg::FREQ,
            f.seed + 6197U) > smoothcfg::BIAS;
}

/// Quantise the surface to plates rather than bricks. See set_plate_steps.
static bool g_plate_steps = false;

/// The surface, in PLATES, before quantisation. THE one height function.
///
/// Three scales, because one is a plain and two is a lumpy plain:
///
///   LANDFORM  ~400 studs (140 m), 34 bricks. The hills you walk between.
///   RELIEF    ~100 studs (35 m), 9 bricks. What a hillside is made of.
///   DETAIL    ~29 studs (10 m), 1.5 bricks. Enough to break a terrace edge.
///
/// This was one octave at 7 bricks, which is 2.9 m of total relief — the
/// whole world inside a two-storey building, and it read as flat ground with
/// texture on it. The landform octave is what makes a view distance worth
/// having: at 560 m you can now see something that is not at your eye level.
/// A pad's influence at a column: 1 inside the flat, 0 outside the skirt.
///
/// Chebyshev distance, not Euclidean: a building is a rectangle on a square
/// lattice, and a round pad under a square building leaves corners hanging.
static float pad_weight(const Pad &p, int x, int z) {
    // How far outside the flat RECTANGLE, Chebyshev: 0 inside it.
    const int d = std::max(std::abs(x - p.x) - p.radius, std::abs(z - p.z) - p.radius_z);
    if (d <= 0) {
        return 1.0f;
    }
    if (d >= p.skirt || p.skirt <= 0) {
        return 0.0f;
    }
    const float t = (float)d / (float)p.skirt;
    // Smoothstep, so the skirt meets the natural ground without a crease.
    return 1.0f - (t * t * (3.0f - 2.0f * t));
}

static bool on_pad_flat(int x, int z) {
    for (const Pad &p : g_pads) {
        if (pad_weight(p, x, z) >= 1.0f) {
            return true;
        }
    }
    return false;
}

// --- sculpt ------------------------------------------------------------------
//
// A height offset per stud column, in plates, stored per tile. Tiles bake on
// worker threads while the editor paints, so the map is COPY-ON-WRITE: a
// writer builds a new map (tile pointers copied, touched tiles cloned) and
// publishes it; a reader holds whichever map it loaded for as long as it
// likes. Readers keep a thread-local pointer and reload only when the
// generation moves, so a bake does not touch the shared pointer per column.

struct SculptTile {
    float v[TILE * TILE] = {};
    /// Surface paint (§20.7): material and colour per column, 255 = none.
    uint8_t mat[TILE * TILE];
    uint8_t col[TILE * TILE];
    /// Brick or curve, painted (§18.6): 0 brick, 1 curve, 255 = the rule's.
    uint8_t form[TILE * TILE];
    SculptTile() {
        std::fill(std::begin(mat), std::end(mat), (uint8_t)0xFF);
        std::fill(std::begin(col), std::end(col), (uint8_t)0xFF);
        std::fill(std::begin(form), std::end(form), (uint8_t)0xFF);
    }
};
using SculptMap = std::unordered_map<int64_t, std::shared_ptr<const SculptTile>>;
static std::shared_ptr<const SculptMap> g_sculpt = std::make_shared<SculptMap>();
static std::atomic<uint64_t> g_sculpt_gen{ 1 };
static std::atomic<bool> g_sculpt_any{ false };

static inline int64_t sculpt_key(int tx, int tz) {
    return ((int64_t)tx << 32) ^ (int64_t)(uint32_t)tz;
}

static const SculptMap &sculpt_map() {
    thread_local uint64_t gen = 0;
    thread_local std::shared_ptr<const SculptMap> held;
    const uint64_t now = g_sculpt_gen.load(std::memory_order_acquire);
    if (gen != now) {
        held = std::atomic_load(&g_sculpt);
        gen = now;
    }
    return *held;
}

static const SculptTile *layer_tile(int x, int z, int &i) {
    if (!g_sculpt_any.load(std::memory_order_acquire)) {
        return nullptr;
    }
    const SculptMap &m = sculpt_map();
    const int tx = floor_div(x, TILE);
    const int tz = floor_div(z, TILE);
    auto it = m.find(sculpt_key(tx, tz));
    if (it == m.end()) {
        return nullptr;
    }
    i = (z - tz * TILE) * TILE + (x - tx * TILE);
    return it->second.get();
}

static int layer_material(int x, int z) {
    int i = 0;
    const SculptTile *t = layer_tile(x, z, i);
    return t == nullptr ? 0xFF : t->mat[i];
}

static int layer_colour(int x, int z) {
    int i = 0;
    const SculptTile *t = layer_tile(x, z, i);
    return t == nullptr ? 0xFF : t->col[i];
}

static int layer_form(int x, int z) {
    int i = 0;
    const SculptTile *t = layer_tile(x, z, i);
    return t == nullptr ? 0xFF : t->form[i];
}

static uint64_t sculpt_gen_now() {
    return g_sculpt_gen.load(std::memory_order_acquire);
}

/// Set while reading the field as generated (BrickTerrain::generated_plate).
/// Per thread, so a worker building a tile is not affected.
static thread_local bool t_bare_field = false;

static float sculpt_plates(int x, int z) {
    if (t_bare_field || !g_sculpt_any.load(std::memory_order_acquire)) {
        return 0.0f;
    }
    const SculptMap &m = sculpt_map();
    const int tx = floor_div(x, TILE);
    const int tz = floor_div(z, TILE);
    auto it = m.find(sculpt_key(tx, tz));
    if (it == m.end()) {
        return 0.0f;
    }
    return it->second->v[(z - tz * TILE) * TILE + (x - tx * TILE)];
}

float Field::base_plate(int x, int z) const {
    const float landform = fbm((float)x * 0.0025f, (float)z * 0.0025f, seed + 5501U,
            3, 2.0f, 0.5f);
    const float relief = fbm((float)x * 0.010f, (float)z * 0.010f, seed, 3, 2.0f, 0.5f);
    const float detail = value_noise((float)x * 0.035f, (float)z * 0.035f, seed + 977U);
    // fBm over value noise rarely reaches its extremes, so the multipliers
    // are bigger than the nominal range suggests.
    // 90 bricks is 38 m of landform amplitude and gives ~25 m of real
    // relief, because three octaves of fBm over value noise sit well inside
    // their nominal range: 34 measured only 9.8 m across 140 m of ground.
    float bricks = landform * 90.0f + relief * 9.0f + detail * 1.5f + 14.0f;
    // SHELVES (Terrain.md 18.8), on slopes ground only. Laid brick there is
    // for places that are flat ON PURPOSE -- hill tops, valley floors -- and
    // noise has almost none: 2% of the test field is flat across 24 studs.
    // So every `g_shelf_bricks` of height, the first `g_shelf_share` of the
    // rise is held flat and the rest climbs to the next shelf on a
    // smoothstep, flat-in and flat-out so a shelf meets its slope without a
    // crease. Where the land is gentle -- tops and bottoms -- a shelf is wide
    // and the broad-flat rule lays it in brick; on a hillside it is a ledge
    // a few studs wide, too narrow for brick, and the hill stays a curve.
    if (g_smooth_slopes && g_smooth_terrain && g_shelf_bricks > 0.0f) {
        const float k = bricks / g_shelf_bricks;
        const float level = std::floor(k);
        const float t = k - level;
        float u = t <= g_shelf_share ? 0.0f
                : (t - g_shelf_share) / std::max(1.0f - g_shelf_share, 1e-3f);
        u = u * u * (3.0f - 2.0f * u);
        bricks = (level + u) * g_shelf_bricks;
    }
    // Sculpted strokes on the noise, under the pads (§20.6).
    return bricks * (float)PLATES_PER_CELL + sculpt_plates(x, z);
}

// Authored pads last: they are a statement about the world that the noise
// does not get to overrule. `flat` says whether the column ends up on some
// pad's dead-flat part (no later pad's skirt over it).
//
// A pad's FLAT part beats every other pad's skirt: a building stands on its
// pad, and a neighbour's skirt reaching under it tilted 718 of the default
// city's 23,100 footprint columns (§21.8). Two neighbours at different heights
// now meet at the edge of the higher one's flat -- a terrace step, which is
// what a row of buildings on a hillside has.
static float apply_pads(float plates, int x, int z, bool *flat) {
    const Pad *on = nullptr;
    for (const Pad &p : g_pads) {
        const float w = pad_weight(p, x, z);
        if (w >= 1.0f) {
            on = &p;   // the last pad flat here is the one standing here
        } else if (w > 0.0f) {
            plates = plates + (p.plates - plates) * w;
        }
    }
    if (flat != nullptr) {
        *flat = on != nullptr;
    }
    return on != nullptr ? on->plates : plates;
}

float Field::raw_plate(int x, int z) const {
    if (biomes_on()) {
        return (float)((biome_column(seed, x, z).sb + 1) * PLATES_PER_CELL);
    }
    return apply_pads(base_plate(x, z), x, z, nullptr);
}

int Field::top_plate(int x, int z) const {
    // The biome generator (terrain_biomes.h): the top plate anything in the
    // column can be solid at -- its overhang band included -- so every scan
    // down from here still finds the real surface.
    if (biomes_on()) {
        return biome_column(seed, x, z).bound_p;
    }
    // ONE height function, quantised two ways. This used to be a second copy
    // of the expression in `raw_plate` and the two drifted apart the moment
    // the relief changed.
    bool flat = false;
    const float plates = apply_pads(base_plate(x, z), x, z, &flat);
    // ON A PAD the ground's top IS the pad's height, whatever the region
    // would quantise it to: a building's floor is read off the field, and a
    // footprint straddling a plate-step patch and a brick-step one stood a
    // plate on one side and three on the other (§21.8).
    if (flat) {
        return (int)std::lround(plates) - 1;
    }
    // Plate steps are REGIONAL, not global. Everywhere at once cost 60% more
    // triangles and a third of the studs (section 17.23) for a smoothness
    // that only some ground wants; a low-frequency mask puts it on about
    // half the map, in patches big enough to read as terrain rather than as
    // noise.
    // 0.012 is a ~83-stud patch. It was 0.004, a 250-stud one, which is
    // wider than the test field -- so "about half the map" was in fact all
    // of it, every time. Measured now.
    if (g_plate_steps
            && value_noise((float)x * 0.012f, (float)z * 0.012f, seed + 3301U) > 0.0f) {
        return (int)std::floor(plates);
    }
    // Quantised to a whole BRICK: the top plate of the course it lands in.
    const int brick = (int)std::floor(plates / (float)PLATES_PER_CELL);
    return (brick + 1) * PLATES_PER_CELL - 1;
}

int Field::nominal_height(int x, int z) const {
    return floor_div(top_plate(x, z), PLATES_PER_CELL);
}

/// Which painted patch owns a column, or -1.
///
/// The skirt is DITHERED: inside it, a hash of the column decides, with the
/// odds falling off with distance. A blended material would have to be half
/// of two things, and there is no such material; a hard edge would draw a
/// visible circle on the ground. Breaking the boundary up is what a hand
/// would do with a brush.
static int painted_at(int x, int z, uint32_t seed) {
    for (size_t i = 0; i < g_paints.size(); ++i) {
        const Paint &p = g_paints[i];
        const int d = std::max(std::abs(x - p.x), std::abs(z - p.z));
        if (d <= p.radius) {
            return (int)i;
        }
        if (p.skirt <= 0 || d >= p.radius + p.skirt) {
            continue;
        }
        const float t = (float)(d - p.radius) / (float)p.skirt;
        if (hashf(x, z, (int32_t)(seed ^ 0x9A17U)) > t) {
            return (int)i;
        }
    }
    return -1;
}

int Field::material_at(int x, int z, int h) const {
    if (biomes_on()) {
        return biome_top(biome_column(seed, x, z));
    }
    // A brush-painted column first: the most specific thing an author said.
    const int brushed = layer_material(x, z);
    if (brushed != 0xFF) {
        return brushed;
    }
    // Authored paint wins over anything the noise has to say.
    const int painted = painted_at(x, z, seed);
    if (painted >= 0) {
        return g_paints[(size_t)painted].mat;
    }
    const float d = value_noise((float)x * 0.021f, (float)z * 0.021f, seed + 4241U);
    if (h <= 1) {
        return MAT_SAND;
    }
    // The bands moved with the relief. At 7 bricks they were tuned for a
    // world 8 bricks tall; with a landform octave that put stone on almost
    // everything, because almost everything is now above seven courses.
    if (h >= 26) {
        return d < 0.2f ? MAT_STONE : MAT_DARK_STONE;
    }
    if (d > 0.45f) {
        return MAT_DIRT;
    }
    return MAT_GRASS;
}

/// Caves, as two crossing sheets of ridged noise.
///
/// A single threshold on 3D noise gives blobs; the ABSOLUTE value of two
/// independent fields, both near zero at once, gives tubes -- which is what a
/// cave is. It is the cheapest generator that produces something you can walk
/// along rather than stand in.
///
/// Caves are held below the surface by a depth ramp, so the ground is not
/// shredded everywhere; where one does reach up, it opens a mouth, and that
/// is the interesting case rather than a bug.
bool Field::cave_at(int x, int yp, int z) const {
    return cave_at(x, yp, z, (nominal_height(x, z) + 1) * PLATES_PER_CELL);
}

bool Field::cave_at(int x, int yp, int z, int top) const {
    const int depth = top - yp;
    // A band, not a half-space. Below it the rock is solid, which is what
    // keeps the conservative reachability fill affordable: there are no deep
    // sealed chambers left to mesh, so nothing has to be culled by guessing.
    if (depth < 4 || depth > 34) {
        return false;   // never break the top plate from below
    }
    const float fx = (float)x * 0.028f;
    const float fy = (float)yp * 0.020f;
    const float fz = (float)z * 0.028f;
    const float a = value_noise3(fx, fy, fz, seed + 5501U);
    const float b = value_noise3(fx + 31.7f, fy + 11.3f, fz - 17.9f, seed + 9203U);
    // Widen with depth, so a cave is a thread near the surface and a chamber
    // lower down rather than a uniform lattice of holes.
    //
    // Two independent |noise| < w tests multiply, and trilinear value noise
    // is peaked around zero, so the joint probability falls off far faster
    // than w suggests: 0.055 measured 0.35% subsurface air, which is no caves
    // at all. These numbers are tuned against the probe's measurement, not
    // derived.
    const float w = 0.15f + 0.16f * std::min((float)depth / 40.0f, 1.0f);
    return std::fabs(a) < w && std::fabs(b) < w;
}

/// Heightfield mode. See BrickTerrain::set_flat_mode.
static bool g_flat_mode = false;

int Field::solid_at(int x, int yp, int z) const {
    if (biomes_on()) {
        if (!edits_empty()) {
            const int e = edit_at(pack_cell(x, yp, z));
            if (e >= 0) {
                return e;
            }
        }
        return biome_cell(biome_column(seed, x, z), seed, x, floor_div(yp, PLATES_PER_CELL), z);
    }
    if (g_flat_mode) {
        const int t = top_plate(x, z);
        return yp > t ? MAT_AIR : material_at(x, z, floor_div(t, PLATES_PER_CELL));
    }
    if (!edits_empty()) {
        const int e = edit_at(pack_cell(x, yp, z));
        if (e >= 0) {
            return e;   // an edit is the truth, air included
        }
    }
    const int t = top_plate(x, z);
    if (yp > t) {
        return MAT_AIR;
    }
    const int h = floor_div(t, PLATES_PER_CELL);
    if (cave_at(x, yp, z)) {
        return MAT_AIR;
    }
    return material_at(x, z, h);
}

// --- edits -----------------------------------------------------------------

namespace {

/// A hash table with ONE writer (the main thread: shots, blocks, sand, lava
/// rock, a save loading) and any number of readers on other threads that
/// take no lock: the tile bakes, find_brick, the collapse survey, the deep
/// tier, the water, the shore field. It replaced three std::unordered_maps
/// that the bakes read with no lock while the main thread inserted -- a race
/// the old comment owned up to, and past the 65 536 reserved entries a rehash
/// under a reader (a crash, or a tile baked from garbage).
///
/// Open addressing, linear probing, nothing is ever deleted (an edit back to
/// air is an edit). An insert writes the value, then publishes the key with
/// release; a reader loads the key with acquire, so a key it sees has its
/// value. Growing builds a bigger table and publishes it; the old ones are
/// kept (a reader may still be probing one) until clear(), which frees all
/// but the last. A reader that misses an edit made while it ran is the same
/// as one that started a moment earlier: the streamer bakes a tile again when
/// an edit lands during its bake.
class EditTable {
public:
    static constexpr uint64_t EMPTY = ~(uint64_t)0;

    EditTable() { cur_.store(make(1024), std::memory_order_release); }

    /// Any thread. False when the key has no entry.
    bool find(uint64_t key, int32_t &out) const {
        const Table *t = cur_.load(std::memory_order_acquire);
        size_t i = slot(key, t->mask);
        for (;;) {
            const uint64_t k = t->keys[i].load(std::memory_order_acquire);
            if (k == key) {
                out = t->vals[i].load(std::memory_order_relaxed);
                return true;
            }
            if (k == EMPTY) {
                return false;
            }
            i = (i + 1) & t->mask;
        }
    }

    /// The writer only. True when the key was new.
    bool put(uint64_t key, int32_t val) {
        Table *t = cur_.load(std::memory_order_relaxed);
        if ((count_.load(std::memory_order_relaxed) + 1) * 2 > t->mask + 1) {
            t = grow(t);
        }
        if (insert(t, key, val)) {
            count_.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
        return false;
    }

    size_t size() const { return count_.load(std::memory_order_relaxed); }

    /// Bytes held: every table not yet freed (the old ones stay, for readers).
    size_t bytes() const {
        size_t b = 0;
        for (const auto &t : owned_) {
            b += (t->mask + 1) * (sizeof(uint64_t) + sizeof(int32_t));
        }
        return b;
    }

    /// The writer only: every entry.
    template <typename F> void each(F f) const {
        const Table *t = cur_.load(std::memory_order_relaxed);
        for (size_t i = 0; i <= t->mask; ++i) {
            const uint64_t k = t->keys[i].load(std::memory_order_relaxed);
            if (k != EMPTY) {
                f(k, t->vals[i].load(std::memory_order_relaxed));
            }
        }
    }

    /// The writer only, with no bake running (a new world: the streamer and
    /// the deep tier wait for theirs as they leave the tree). Readers that
    /// hold edit_lock() shared are kept out by the caller's exclusive lock.
    void clear() {
        Table *old = cur_.load(std::memory_order_relaxed);
        Table *fresh = make(1024);
        cur_.store(fresh, std::memory_order_release);
        count_.store(0, std::memory_order_relaxed);
        // Keep the table just replaced one more round; free the rest.
        std::vector<std::unique_ptr<Table>> keep;
        for (auto &p : owned_) {
            if (p.get() == old || p.get() == fresh) {
                keep.push_back(std::move(p));
            }
        }
        owned_.swap(keep);
    }

private:
    struct Table {
        size_t mask = 0;
        std::unique_ptr<std::atomic<uint64_t>[]> keys;
        std::unique_ptr<std::atomic<int32_t>[]> vals;
    };

    static size_t slot(uint64_t k, size_t mask) {
        k ^= k >> 30;
        k *= 0xbf58476d1ce4e5b9ULL;
        k ^= k >> 27;
        k *= 0x94d049bb133111ebULL;
        k ^= k >> 31;
        return (size_t)k & mask;
    }

    Table *make(size_t cap) {
        auto t = std::make_unique<Table>();
        t->mask = cap - 1;
        t->keys.reset(new std::atomic<uint64_t>[cap]);
        t->vals.reset(new std::atomic<int32_t>[cap]);
        for (size_t i = 0; i < cap; ++i) {
            t->keys[i].store(EMPTY, std::memory_order_relaxed);
            t->vals[i].store(0, std::memory_order_relaxed);
        }
        Table *raw = t.get();
        owned_.push_back(std::move(t));
        return raw;
    }

    /// True when the key was new.
    static bool insert(Table *t, uint64_t key, int32_t val) {
        size_t i = slot(key, t->mask);
        for (;;) {
            const uint64_t k = t->keys[i].load(std::memory_order_relaxed);
            if (k == key) {
                t->vals[i].store(val, std::memory_order_relaxed);
                return false;
            }
            if (k == EMPTY) {
                t->vals[i].store(val, std::memory_order_relaxed);
                t->keys[i].store(key, std::memory_order_release);
                return true;
            }
            i = (i + 1) & t->mask;
        }
    }

    Table *grow(Table *t) {
        Table *n = make((t->mask + 1) * 2);
        for (size_t i = 0; i <= t->mask; ++i) {
            const uint64_t k = t->keys[i].load(std::memory_order_relaxed);
            if (k != EMPTY) {
                insert(n, k, t->vals[i].load(std::memory_order_relaxed));
            }
        }
        cur_.store(n, std::memory_order_release);
        return n;
    }

    std::atomic<Table *> cur_{ nullptr };
    std::atomic<size_t> count_{ 0 };
    std::vector<std::unique_ptr<Table>> owned_;   ///< every table not yet freed
};

/// Plate cell -> material.
EditTable g_edits;

/// EDITS BY REGION (Docs/MineWorld.md 9): each REGION_STUDS square keeps the
/// cells edited in it and whether any changed since the last save asked, so
/// a save writes the regions that changed and nothing else. It used to pack
/// every edit of the world on the main thread each autosave (get_edits: 1.6 ms
/// at 100k edits, 16.6 ms at 1M) and rewrite the whole file. The main thread's
/// alone: written by set_edit, read by take_dirty_regions / get_region_edits.
/// The edit table above is still what every reader looks cells up in.
constexpr int REGION_STUDS = 256;
struct EditRegion {
    std::vector<uint64_t> keys;   ///< cells edited here, each once
    bool dirty = false;
};
std::unordered_map<int64_t, EditRegion> g_regions;

inline int64_t region_key(int rx, int rz) {
    return ((int64_t)(rx & 0xFFFFFFF) << 28) | (int64_t)(rz & 0xFFFFFFF);
}
/// Deepest edited plate per tile column, so `sample_tile` knows how far down
/// it has to look. Without it the mask stopped SECTION_BELOW plates under the
/// surface, anything dug past that was edited in the field but still read as
/// solid rock to the mesher, and the floor of a deep pit was simply not
/// there.
EditTable g_tile_floor;
/// Highest edited SOLID plate per tile column.
EditTable g_tile_ceiling;
/// Placed bricks: (x, course, z) packed like a plate cell -> the brick's
/// rectangle as an offset and size (placed_code). 0: none (an entry is never
/// removed, only zeroed).
EditTable g_placed;

inline int32_t placed_code(int dx, int dz, int sx, int sz) {
    return (1 << 20) | (dx & 15) | ((dz & 15) << 4) | ((sx & 15) << 8) | ((sz & 15) << 12);
}

} // namespace

/// Held alone by clear_edits, shared by the water's thread (BrickFluid) and
/// the shore field while they read. Nothing else needs it any more: the
/// tables above are safe to read while the main thread writes. set_edit no
/// longer takes it per cell, so an edit never waits for the water to finish
/// sampling a column.
static std::shared_mutex g_edit_rw;

std::shared_mutex &edit_lock() { return g_edit_rw; }

int64_t pack_cell(int x, int yp, int z) {
    // 21 bits each, signed, which is +-1 million studs and +-1 million
    // plates. The city is a thousand studs across.
    return ((int64_t)(x & 0x1FFFFF) << 42) | ((int64_t)(yp & 0x1FFFFF) << 21)
            | (int64_t)(z & 0x1FFFFF);
}

int edit_at(int64_t key) {
    int32_t v;
    return g_edits.find((uint64_t)key, v) ? (int)v : -1;
}

static inline int64_t tile_key(int tx, int tz) {
    return ((int64_t)(tx & 0xFFFFFFF) << 28) | (int64_t)(tz & 0xFFFFFFF);
}

bool placed_at(int x, int course, int z, int &rx, int &rz, int &rsx, int &rsz) {
    if (g_placed.size() == 0) {
        return false;
    }
    int32_t v;
    if (!g_placed.find((uint64_t)pack_cell(x, course, z), v) || v == 0) {
        return false;
    }
    rx = x - (v & 15);
    rz = z - ((v >> 4) & 15);
    rsx = (v >> 8) & 15;
    rsz = (v >> 12) & 15;
    return true;
}

static std::atomic<uint32_t> g_field_serial{ 1 };
static constexpr int TILE_SERIAL_SLOTS = 4096;
static std::atomic<uint32_t> g_tile_serial[TILE_SERIAL_SLOTS];

static inline size_t tile_serial_slot(int tx, int tz) {
    uint32_t h = (uint32_t)tx * 0x8DA6B343U ^ (uint32_t)tz * 0xD8163841U;
    h ^= h >> 15;
    return (size_t)(h & (TILE_SERIAL_SLOTS - 1));
}

/// A cell at (x, z) changed: its tile and the ones round it (a tile is
/// sampled with a margin) are not what they were.
static inline void bump_tiles_near(int x, int z) {
    const int tx = floor_div(x, TILE), tz = floor_div(z, TILE);
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            g_tile_serial[tile_serial_slot(tx + dx, tz + dz)].fetch_add(1, std::memory_order_relaxed);
        }
    }
}

uint64_t tile_version(int tx, int tz) {
    return ((uint64_t)g_field_serial.load(std::memory_order_acquire) << 32)
            | g_tile_serial[tile_serial_slot(tx, tz)].load(std::memory_order_acquire);
}

void bump_field_version() {
    g_field_serial.fetch_add(1, std::memory_order_acq_rel);
}

uint32_t field_serial() {
    return g_field_serial.load(std::memory_order_acquire);
}

void set_edit(int x, int yp, int z, int material) {
    bump_tiles_near(x, z);
    // Any other edit to a placed brick's cell makes it ground again (a
    // placement marks it after its fill_box: BrickTerrain::mark_placed).
    if (g_placed.size() > 0) {
        const uint64_t pk = (uint64_t)pack_cell(x, floor_div(yp, PLATES_PER_CELL), z);
        int32_t pv;
        if (g_placed.find(pk, pv) && pv != 0) {
            g_placed.put(pk, 0);
        }
    }
    const uint64_t tk = (uint64_t)tile_key(floor_div(x, TILE), floor_div(z, TILE));
    // The column bounds first: a bake that sees the new cell must also reach
    // down (or up) to it.
    int32_t was;
    if (!g_tile_floor.find(tk, was) || yp < was) {
        g_tile_floor.put(tk, yp);
    }
    if (material != MAT_AIR && (!g_tile_ceiling.find(tk, was) || yp > was)) {
        g_tile_ceiling.put(tk, yp);
    }
    const uint64_t key = (uint64_t)pack_cell(x, yp, z);
    const bool fresh = g_edits.put(key, (int32_t)(uint8_t)material);
    EditRegion &r = g_regions[region_key(floor_div(x, REGION_STUDS), floor_div(z, REGION_STUDS))];
    if (fresh) {
        r.keys.push_back(key);
    }
    r.dirty = true;
    // Again after the write: a reader that read the version before the bump
    // above but sampled before the write must not keep what it packed under
    // the new version (packed_tile, the collapse's top course).
    bump_tiles_near(x, z);
}

int highest_edit_near(int tx, int tz) {
    if (g_tile_ceiling.size() == 0) {
        return INT_MIN;
    }
    int best = INT_MIN;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            int32_t v;
            if (g_tile_ceiling.find((uint64_t)tile_key(tx + dx, tz + dz), v)) {
                best = std::max(best, (int)v);
            }
        }
    }
    return best;
}

int deepest_edit_near(int tx, int tz) {
    if (g_tile_floor.size() == 0) {
        return INT_MAX;
    }
    int best = INT_MAX;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            int32_t v;
            if (g_tile_floor.find((uint64_t)tile_key(tx + dx, tz + dz), v)) {
                best = std::min(best, (int)v);
            }
        }
    }
    return best;
}

void clear_edits() {
    bump_field_version();
    std::unique_lock<std::shared_mutex> lk(g_edit_rw);
    g_edits.clear();
    g_tile_floor.clear();
    g_tile_ceiling.clear();
    g_placed.clear();
    g_regions.clear();
}

size_t edit_count() {
    return g_edits.size();
}

bool edits_empty() {
    return g_edits.size() == 0;
}

// --- sampling --------------------------------------------------------------

// Off by default (2026-10-16): the user prefers terrace edges as plain
// bricks. The pieces still work; F10's dev menu turns them back on.
bool g_slope_pieces = false;

// The top course on the bond, not the packer's ladder (Docs/TerrainBond.md).
bool g_bond_top = false;

/// Sky light in the cells (Docs/MineWorld.md 18); set_sky_light.
static std::atomic<bool> g_sky_light{ false };
/// Bake behind faces (BrickTerrain.set_behind_faces; the mine world).
static std::atomic<bool> g_behind_faces{ false };
/// ...only round the eye (set_behind_centre): they are drawn only within the
/// overlay's 12 m, and every tile and section carrying them was ~200 MB more
/// (the machine paged: --gate=deep's worst frame 82 -> 1538 ms). Tiles within
/// BEHIND_RING of the eye's tile; sections also within BEHIND_PLATES of its
/// plate.
static std::atomic<int> g_behind_cx{ 0 }, g_behind_cz{ 0 }, g_behind_cy{ 0 };
constexpr int BEHIND_RING = 2;
constexpr int BEHIND_PLATES = 128;
static bool behind_tile(int tx, int tz) {
    return g_behind_faces.load(std::memory_order_relaxed)
            && std::abs(tx - g_behind_cx.load(std::memory_order_relaxed)) <= BEHIND_RING
            && std::abs(tz - g_behind_cz.load(std::memory_order_relaxed)) <= BEHIND_RING;
}

bool g_deep_tier = false;

/// A surface tile's mask floor from the generator alone (never from edits):
/// what the deep tier partitions on. The same rule sample_tile has always
/// used for its mask's bottom.
static int tile_floor_of(const std::vector<BColumn> &bcols) {
    int lo = 1000000, deep = 1000000;
    for (const BColumn &c : bcols) {
        lo = std::min(lo, (c.sb - c.amp + 1) * PLATES_PER_CELL - 1);
        deep = std::min(deep, c.low_p);
    }
    return std::min(lo + 1 - SECTION_BELOW, deep);
}

// --- generated tiles -------------------------------------------------------
//
// A tile's GENERATED cells, kept (Docs/MineWorld.md 21, item 1). The noise is
// nearly all of a sample (~5 ms of 5.1), and no edit changes it: a shot
// re-sampled the whole tile from noise for find_brick and again for the
// rebuild. Kept, a re-sample is a copy plus the edits.
namespace {
struct GenTile {
    int lo = 0, hi = 0, deep = 0;   ///< sample_tile's bounds from the columns
    int gy0 = 0, gys = 0;           ///< the plates `vox` holds
    std::vector<uint8_t> vox;       ///< SPAN * gys * SPAN, TileSample's layout
    std::vector<int16_t> top;       ///< generated top plate a column, gy0 - 1: none
};
struct GenStore {
    std::mutex lock;
    struct Entry {
        uint32_t field = 0;
        uint64_t used = 0;
        std::shared_ptr<const GenTile> gen;
    };
    std::unordered_map<uint64_t, Entry> tiles;
    uint64_t clock = 0;
    int64_t hits = 0, made = 0;
};
/// Surface tiles: ~180 KB each (36 x 36 columns, ~140 plates). The tiles
/// sampled again are the ones being dug, near the eye; streaming passes
/// through. Deep sections (Docs/MineWorld.md 16): one store of their own, so
/// a cave's sections and the ground over it do not push each other out.
GenStore g_gen, g_gen_sec;
constexpr size_t GEN_MAX = 64;

std::shared_ptr<const GenTile> gen_find(GenStore &st, uint64_t k, uint32_t field) {
    std::lock_guard<std::mutex> lk(st.lock);
    auto it = st.tiles.find(k);
    if (it == st.tiles.end() || it->second.field != field) {
        return nullptr;
    }
    it->second.used = ++st.clock;
    ++st.hits;
    return it->second.gen;
}

void gen_keep(GenStore &st, uint64_t k, uint32_t field, std::shared_ptr<const GenTile> gen) {
    std::lock_guard<std::mutex> lk(st.lock);
    ++st.made;
    if (st.tiles.size() >= GEN_MAX && st.tiles.find(k) == st.tiles.end()) {
        std::vector<uint64_t> used;
        used.reserve(st.tiles.size());
        for (const auto &e : st.tiles) {
            used.push_back(e.second.used);
        }
        const size_t q = used.size() / 4;
        std::nth_element(used.begin(), used.begin() + q, used.end());
        const uint64_t cut = used[q];
        for (auto it = st.tiles.begin(); it != st.tiles.end();) {
            it = it->second.used <= cut ? st.tiles.erase(it) : std::next(it);
        }
    }
    st.tiles[k] = GenStore::Entry{ field, ++st.clock, std::move(gen) };
}
} // namespace

/// The edits over a sample's generated cells, from the deepest edit of its
/// tile and the neighbours (the margin reaches into them) up: under it
/// nothing was edited, and most of a sample's plates are under it.
static void apply_edits(TileSample &out) {
    const int dug_to = deepest_edit_near(out.tx, out.tz);
    if (dug_to == INT_MAX) {
        return;
    }
    const int gx0 = out.tx * TILE, gz0 = out.tz * TILE;
    const int ylo = std::max(out.y0, dug_to);
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            const int gx = gx0 + lx, gz = gz0 + lz;
            for (int yp = ylo; yp < out.y0 + out.ysize; ++yp) {
                const int e = edit_at(pack_cell(gx, yp, gz));
                if (e >= 0) {
                    out.vox[out.vidx(lx, yp, lz)] = (uint8_t)e;
                }
            }
        }
    }
}

void sample_tile(const Field &f, int tx, int tz, TileSample &out) {
    out.tx = tx;
    out.tz = tz;

    const int gx0 = tx * TILE;
    const int gz0 = tz * TILE;

    // The mask spans from a little above the highest nominal surface down
    // SECTION_BELOW plates from the lowest. Everything above is air and
    // everything below is rock, and neither needs storing (section 17.4).
    int hi = -1000000, lo = 1000000;
    // The biome generator decides each column once (2D noise, biome, band)
    // and every plate of it reads that: per cell would be ~25 octaves of
    // noise a plate.
    const bool biomes = biomes_on();
    std::vector<BColumn> bcols;
    int deep = 1000000;
    // The field's serial: configure, the generator and its params bump it.
    const uint32_t field = (uint32_t)(tile_version(tx, tz) >> 32);
    const uint64_t gkey = (uint64_t)tile_key(tx, tz);
    std::shared_ptr<const GenTile> gen = biomes ? gen_find(g_gen, gkey, field) : nullptr;
    if (gen) {
        hi = gen->hi;
        lo = gen->lo;
        deep = gen->deep;
    } else if (biomes) {
        bcols.resize((size_t)SPAN * SPAN);
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                const BColumn c = biome_column(f.seed, gx0 + lx, gz0 + lz);
                bcols[TileSample::idx(lx, lz)] = c;
                hi = std::max(hi, c.bound_p);
                lo = std::min(lo, (c.sb - c.amp + 1) * PLATES_PER_CELL - 1);
                deep = std::min(deep, c.low_p);
            }
        }
    } else {
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                const int t = f.top_plate(gx0 + lx, gz0 + lz);
                hi = std::max(hi, t);
                lo = std::min(lo, t);
            }
        }
    }
    // Placed blocks can stand above every column's generated top.
    const int placed = highest_edit_near(tx, tz);
    if (placed != INT_MIN) {
        hi = std::max(hi, placed + 1);
    }
    const int top_plate = hi + 1;
    out.y0 = lo + 1 - SECTION_BELOW;
    if (biomes) {
        out.y0 = std::min(out.y0, deep);
    }
    // The deep tier owns everything under the generated floor: the mask
    // stops there (plus one guard plate, sampled, not drawn), and what is dug
    // below it is the sections' (Docs/MineWorld.md 16).
    const bool deep_tier = biomes && g_deep_tier;
    // Reach whatever has been dug, plus a little, or the bottom of a deep pit
    // falls outside the mask and is never meshed.
    const int dug = deep_tier ? INT_MAX : deepest_edit_near(tx, tz);
    if (dug != INT_MAX) {
        out.y0 = std::min(out.y0, dug - 6);
    }
    if (deep_tier) {
        out.own_lo = out.y0;
        out.y0 -= 1;
    }
    out.ysize = top_plate - out.y0 + 1;
    if (deep_tier) {
        out.own_hi = out.y0 + out.ysize;
    }
    out.vox.assign((size_t)SPAN * out.ysize * SPAN, (uint8_t)MAT_AIR);

    // `nominal_height` is three octaves of fBm and `material_at` another
    // noise, and BOTH are functions of the column alone. Calling solid_at per
    // CELL recomputed them for all ~85 plates of every column: 9.4 ms a tile,
    // against 0.6 ms for the heightfield it replaced. Hoisted out, only the
    // cave test and the edit lookup remain per cell.
    const bool no_edits = edits_empty() || g_flat_mode;
    out.gtp.assign(SPAN * SPAN, (int16_t)(out.y0 - 1));
    // The kept cells reach as deep as this sample's, or they are made again
    // (a pit dug past them, the deep tier off).
    if (gen && out.y0 < gen->gy0) {
        gen = nullptr;
        bcols.resize((size_t)SPAN * SPAN);
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                bcols[TileSample::idx(lx, lz)] = biome_column(f.seed, gx0 + lx, gz0 + lz);
            }
        }
    }
    if (gen) {
        // Row by row (a row is SPAN columns of one plate): what the kept
        // tile has; above it, air (it reaches past every column's bound).
        const int ylast = std::min(out.y0 + out.ysize, gen->gy0 + gen->gys);
        for (int lz = 0; lz < SPAN; ++lz) {
            for (int yp = out.y0; yp < ylast; ++yp) {
                std::memcpy(&out.vox[(size_t)SPAN * ((yp - out.y0) + (size_t)out.ysize * lz)],
                        &gen->vox[(size_t)SPAN * ((yp - gen->gy0) + (size_t)gen->gys * lz)], SPAN);
            }
        }
        for (int i = 0; i < SPAN * SPAN; ++i) {
            out.gtp[i] = gen->top[i] >= out.y0 ? gen->top[i] : (int16_t)(out.y0 - 1);
        }
    }
    if (biomes && !gen) {
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                const int gx = gx0 + lx, gz = gz0 + lz;
                const BColumn &c = bcols[TileSample::idx(lx, lz)];
                int last_b = INT_MIN;
                uint8_t last_v = (uint8_t)MAT_AIR;
                int16_t gen_top = (int16_t)(out.y0 - 1);
                for (int yp = out.y0; yp < out.y0 + out.ysize; ++yp) {
                    uint8_t v = (uint8_t)MAT_AIR;
                    if (yp <= c.bound_p) {
                        const int yb = floor_div(yp, PLATES_PER_CELL);
                        if (yb != last_b) {
                            last_b = yb;
                            last_v = (uint8_t)biome_cell(c, f.seed, gx, yb, gz);
                        }
                        v = last_v;
                    }
                    if (v != MAT_AIR) {
                        gen_top = (int16_t)yp;
                    }
                    out.vox[out.vidx(lx, yp, lz)] = v;
                }
                out.gtp[TileSample::idx(lx, lz)] = gen_top;
            }
        }
        auto made = std::make_shared<GenTile>();
        made->lo = lo;
        made->hi = hi;
        made->deep = deep;
        made->gy0 = out.y0;
        made->gys = out.ysize;
        made->vox = out.vox;
        made->top = out.gtp;
        gen_keep(g_gen, gkey, field, std::move(made));
    }
    if (biomes && !no_edits) {
        apply_edits(out);
    }
    for (int lz = -MARGIN; lz < TILE + MARGIN && !biomes; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            const int gx = gx0 + lx, gz = gz0 + lz;
            const int ctop_plate = f.top_plate(gx, gz);
            const int ch = floor_div(ctop_plate, PLATES_PER_CELL);
            const int ctop = ctop_plate + 1;
            const uint8_t cmat = (uint8_t)f.material_at(gx, gz, ch);
            int16_t gen_top = (int16_t)(out.y0 - 1);
            for (int yp = out.y0; yp < out.y0 + out.ysize; ++yp) {
                uint8_t v;
                if (yp >= ctop) {
                    v = (uint8_t)MAT_AIR;
                } else if (!g_flat_mode && f.cave_at(gx, yp, gz, ctop)) {
                    v = (uint8_t)MAT_AIR;
                } else {
                    v = cmat;
                }
                if (v != MAT_AIR) {
                    gen_top = (int16_t)yp;
                }
                if (!no_edits) {
                    const int e = edit_at(pack_cell(gx, yp, gz));
                    if (e >= 0) {
                        v = (uint8_t)e;
                    }
                }
                out.vox[out.vidx(lx, yp, lz)] = v;
            }
            out.gtp[TileSample::idx(lx, lz)] = gen_top;
        }
    }

    // --- which air can actually be reached ---------------------------------
    //
    // Caves tripled the triangle count the moment they existed, and almost
    // all of it was chambers sealed inside the rock: real air, real faces,
    // and no way for anyone to ever be in the room. A flood fill from the sky
    // and from the section's open sides says which air is connected to the
    // outside, and only faces touching THAT are drawn.
    //
    // It is not a heuristic. Blast into a sealed chamber and the fill reruns
    // on the rebuild, the chamber becomes reachable, and its walls appear.
    out.open.assign((size_t)SPAN * out.ysize * SPAN, 0);
    {
        std::vector<int> stack;
        stack.reserve(4096);
        auto push = [&](int lx, int yp, int lz) {
            if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN
                    || lz >= TILE + MARGIN || yp < out.y0 || yp >= out.y0 + out.ysize) {
                return;
            }
            const int i = out.vidx(lx, yp, lz);
            if (out.vox[i] != MAT_AIR || out.open[i]) {
                return;
            }
            out.open[i] = 1;
            stack.push_back(i);
        };
        // Seed: the top layer is sky, and the four sides of the sampled span
        // are open to whatever the neighbouring tile holds.
        const int ytop = out.y0 + out.ysize - 1;
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                push(lx, ytop, lz);
            }
        }
        // Seed the SIDES of the span as well as the sky, and this is not an
        // optimisation choice -- it is the only version that is correct.
        //
        // The fill can only see one tile's span. Sky-only culled far more,
        // but it culled air that reaches the sky by a path LEAVING the span,
        // and that air is genuinely open: standing in a dug-out cavern you
        // could see straight through the ground where its faces had been
        // thrown away. Seeding the boundary makes the test conservative --
        // it now only culls a pocket that is entirely inside the span and
        // reaches no sky, which really is sealed, globally and not just
        // locally.
        //
        // It culls much less. The triangles that buys back are paid for by
        // bounding cave DEPTH in `cave_at` instead, which is a generation
        // decision rather than a rendering lie.
        for (int yp = out.y0; yp < out.y0 + out.ysize; ++yp) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                push(lx, yp, -MARGIN);
                push(lx, yp, TILE + MARGIN - 1);
            }
            for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
                push(-MARGIN, yp, lz);
                push(TILE + MARGIN - 1, yp, lz);
            }
        }
        // With a deep tier under it the floor is open too: air there may be
        // a cave going on down into a section.
        if (deep_tier) {
            for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
                for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                    push(lx, out.y0, lz);
                }
            }
        }
        while (!stack.empty()) {
            const int i = stack.back();
            stack.pop_back();
            // Unpack vidx: i = (lx+M) + SPAN * ((yp-y0) + ysize * (lz+M))
            const int a = i % SPAN;
            const int rest = i / SPAN;
            const int b = rest % out.ysize;
            const int c = rest / out.ysize;
            const int lx = a - MARGIN, yp = b + out.y0, lz = c - MARGIN;
            push(lx - 1, yp, lz);
            push(lx + 1, yp, lz);
            push(lx, yp - 1, lz);
            push(lx, yp + 1, lz);
            push(lx, yp, lz - 1);
            push(lx, yp, lz + 1);
        }
    }

    // --- derive the surface -------------------------------------------------
    out.h.assign(SPAN * SPAN, 0);
    out.tp.assign(SPAN * SPAN, 0);
    out.mat.assign(SPAN * SPAN, 0);
    out.col.assign(SPAN * SPAN, 0xFF);
    out.plate.assign(SPAN * SPAN, 0);
    out.ramp.assign(SPAN * SPAN, 255);
    out.smooth.assign(SPAN * SPAN, 0);

    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            const int i = TileSample::idx(lx, lz);
            int yp = out.y0 + out.ysize - 1;
            while (yp >= out.y0 && out.vox[out.vidx(lx, yp, lz)] == MAT_AIR) {
                --yp;
            }
            // A column carved through entirely reads as the mask floor; the
            // surface tier draws nothing there and the face mesher draws the
            // hole. floor_div, because a broken brick leaves a partial one.
            const int h = floor_div(yp, PLATES_PER_CELL);
            out.h[i] = (int16_t)h;
            out.tp[i] = (int16_t)yp;
            out.mat[i] = (uint8_t)(yp >= out.y0
                    ? out.vox[out.vidx(lx, yp, lz)]
                    : (uint8_t)MAT_STONE);
            out.col[i] = (uint8_t)layer_colour(tx * TILE + lx, tz * TILE + lz);
        }
    }

    for (int lz = -MARGIN + 1; lz < TILE + MARGIN - 1; ++lz) {
        for (int lx = -MARGIN + 1; lx < TILE + MARGIN - 1; ++lx) {
            const int i = TileSample::idx(lx, lz);
            const int h = out.h[i];
            const int n[4] = {
                out.h[TileSample::idx(lx - 1, lz)],
                out.h[TileSample::idx(lx + 1, lz)],
                out.h[TileSample::idx(lx, lz - 1)],
                out.h[TileSample::idx(lx, lz + 1)],
            };
            // With an integer height this is an EQUALITY test, not a normal
            // threshold. No tuning constant, and a slope gets NO studs rather
            // than some -- spec section 4's "no half-studs melting into hills".
            // Flat means the same exact PLATE. Comparing bricks called a
            // one-plate step flat, which with plate quantisation is most of
            // the terrain.
            const int t = out.tp[i];
            const int nt[4] = {
                out.tp[TileSample::idx(lx - 1, lz)],
                out.tp[TileSample::idx(lx + 1, lz)],
                out.tp[TileSample::idx(lx, lz - 1)],
                out.tp[TileSample::idx(lx, lz + 1)],
            };
            out.plate[i] = (nt[0] == t && nt[1] == t && nt[2] == t && nt[3] == t) ? 1 : 0;
            // EDITS DO NOT RE-LAY THE BRICKS ROUND THEM (Docs/MineWorld.md
            // 10). Judged against the edited tops, a hole took the studs off
            // every brick at its rim, the packer cut them differently, and a
            // shot looked like the ground being rebuilt round it. So:
            //   * an untouched column judges a neighbour an edit moved by
            //     that neighbour's GENERATED top -- it is laid as it was;
            //   * a column an edit moved is a brick top where nothing beside
            //     it stands higher: a placed block has studs, and so does the
            //     floor a shot opened, as the bricks under it would.
            if (!no_edits) {
                const int nidx[4] = {
                    TileSample::idx(lx - 1, lz), TileSample::idx(lx + 1, lz),
                    TileSample::idx(lx, lz - 1), TileSample::idx(lx, lz + 1),
                };
                if (out.tp[i] != out.gtp[i]) {
                    out.plate[i] = (nt[0] <= t && nt[1] <= t && nt[2] <= t && nt[3] <= t) ? 1 : 0;
                } else {
                    bool flat = true;
                    for (int k = 0; k < 4; ++k) {
                        const int j = nidx[k];
                        const int ref = out.tp[j] != out.gtp[j] ? out.gtp[j] : out.tp[j];
                        flat = flat && ref == t;
                    }
                    out.plate[i] = flat ? 1 : 0;
                }
            }

            // CURVED or BRICKED, from the biome and the steepness together.
            //
            // Steepness is free: the four neighbours are already in hand,
            // and it is the half that carries the idea -- steep ground goes
            // bricked because a stack of courses is what a cliff should look
            // like. The biome decides what happens on the flat.
            if (g_smooth_terrain) {
                int qstep = 0;
                for (int k = 0; k < 4; ++k) {
                    qstep = std::max(qstep, std::abs(nt[k] - t));
                }
                out.smooth[i] = smooth_column(f, out.tx * TILE + lx,
                        out.tz * TILE + lz, qstep) ? 1 : 0;
            }

            int lower = -1, count = 0;
            for (int k = 0; k < 4; ++k) {
                if (n[k] < h) { ++count; lower = k; }
            }
            out.ramp[i] = (RAMPS_ENABLED && count == 1 && n[lower] == h - 1)
                    ? (uint8_t)lower : (uint8_t)255;
        }
    }

    // SLOPE COLUMNS (Terrain.md 19.24). Decided per column from the FIELD, not
    // by the packer's first-come order, so the tile next door reaches the same
    // answer about a shared edge -- a slope drawn against a neighbour whose
    // pieces it could not see was the fins and slivers at tile borders.
    //
    // A column is part of a slope toward side r when walking toward r over
    // level ground of the same material and colour reaches, within 4 studs, a
    // FRONT whose next cell is lower; the run back from that front (2-4 studs,
    // 1-2 for a steep 2-3 brick fall) must reach this column. Of the sides
    // that qualify, the longest run wins.
    out.sl_r.assign(SPAN * SPAN, 255);
    out.sl_len.assign(SPAN * SPAN, 0);
    out.sl_d.assign(SPAN * SPAN, 0);
    out.sl_fall.assign(SPAN * SPAN, 0);
    if (g_slope_pieces && g_flat_mode && !g_smooth_terrain) {
        constexpr int GM = 8;
        constexpr int GN = TILE + 2 * GM;
        std::vector<int16_t> gt((size_t)GN * GN);
        std::vector<uint8_t> gm((size_t)GN * GN), gc((size_t)GN * GN);
        for (int z = 0; z < GN; ++z) {
            for (int x = 0; x < GN; ++x) {
                const int wx = tx * TILE + x - GM, wz = tz * TILE + z - GM;
                const int t = f.top_plate(wx, wz);
                const size_t k = (size_t)x + (size_t)GN * z;
                gt[k] = (int16_t)t;
                gm[k] = (uint8_t)f.material_at(wx, wz, floor_div(t, PLATES_PER_CELL));
                gc[k] = (uint8_t)layer_colour(wx, wz);
            }
        }
        auto G = [&](int lx, int lz) { return (size_t)(lx + GM) + (size_t)GN * (lz + GM); };
        auto same = [&](size_t a, size_t b) {
            return gt[a] == gt[b] && gm[a] == gm[b] && gc[a] == gc[b];
        };
        const int DX[4] = { -1, 1, 0, 0 };
        const int DZ[4] = { 0, 0, -1, 1 };
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                int best_r = -1, best_len = 0, best_d = 0, best_fall = 0;
                for (int r = 0; r < 4; ++r) {
                    int fx = lx, fz = lz, d = 0, fall = 0;
                    while (d <= 3) {
                        const size_t a = G(fx, fz), b = G(fx + DX[r], fz + DZ[r]);
                        if (gt[b] < gt[a]) {
                            fall = gt[a] - gt[b];
                            break;
                        }
                        if (d == 3 || !same(a, b)) {
                            break;
                        }
                        fx += DX[r];
                        fz += DZ[r];
                        ++d;
                    }
                    if (fall < 1) {
                        continue;
                    }
                    const bool steep = fall > PLATES_PER_CELL;
                    if (steep && fall < 2 * PLATES_PER_CELL) {
                        continue;   // 4-5 plates: neither a slope nor a steep one
                    }
                    const size_t front = G(fx, fz);
                    int n = 0;
                    while (n < 4 && same(G(fx - DX[r] * n, fz - DZ[r] * n), front)) {
                        ++n;
                    }
                    n = std::min(n, steep ? 2 : 4);
                    if ((!steep && n < 2) || d >= n) {
                        continue;
                    }
                    if (n > best_len) {
                        best_len = n;
                        best_r = r;
                        best_d = d;
                        best_fall = std::min(fall, 3 * PLATES_PER_CELL);
                    }
                }
                if (best_r >= 0) {
                    const int i = TileSample::idx(lx, lz);
                    out.sl_r[i] = (uint8_t)best_r;
                    out.sl_len[i] = (uint8_t)best_len;
                    out.sl_d[i] = (uint8_t)best_d;
                    out.sl_fall[i] = (uint8_t)best_fall;
                }
            }
        }
    }
}

// --- the packer ------------------------------------------------------------

/// Partitions of PERIOD. First entry is the segment count; repeats of a whole
/// row are weights, so [4,4,4] appearing six times is what makes three 2x4s in
/// a row the commonest outcome.
///
/// On FLAT ground this table puts 112 of 144 cells (78%) in a 4-long segment.
/// On real relief it does much less, and that gap is the interesting number:
/// every terrace edge and every material boundary is a forced cut, so measured
/// over a field with ten brick terraces of relief the mean piece is about half
/// what a flat tile would give. Terrain chops bricks; the table only decides
/// what it chops them from. The probe prints the measured mix.
static const int8_t PARTITIONS[][5] = {
    {3, 4, 4, 4, 0},
    {3, 4, 4, 4, 0},
    {3, 4, 4, 4, 0},
    {3, 4, 4, 4, 0},
    {3, 4, 4, 4, 0},
    {3, 4, 4, 4, 0},
    {4, 4, 4, 2, 2},
    {4, 2, 4, 4, 2},
    {4, 4, 2, 4, 2},
    {3, 6, 4, 2, 0},
    {3, 4, 6, 2, 0},
    {4, 4, 4, 3, 1},
    {2, 6, 6, 0, 0},
};
static const int PARTITION_COUNT = (int)(sizeof(PARTITIONS) / sizeof(PARTITIONS[0]));

int row_offset(uint32_t seed, int row_key, int axis) {
    return (int)(hash3(row_key, axis, (int32_t)(seed ^ 0x51EDU)) % (uint32_t)PERIOD);
}

bool pair_bonds(uint32_t seed, int pair_key, int axis) {
    return hashf(pair_key, axis + 7, (int32_t)(seed ^ 0x2B0DU)) < BOND_CHANCE;
}

bool cut_before(uint32_t seed, int u, int row_key, int axis) {
    const int t = u - row_offset(seed, row_key, axis);
    const int period_index = floor_div(t, PERIOD);
    const int local = t - period_index * PERIOD;
    const uint32_t pick = hash3(period_index, row_key * 31 + axis,
                                (int32_t)(seed ^ 0xB105U)) % (uint32_t)PARTITION_COUNT;
    const int8_t *part = PARTITIONS[pick];
    const int n = part[0];
    int acc = 0;
    for (int i = 1; i <= n; ++i) {
        if (local == acc) {
            return true;
        }
        acc += part[i];
    }
    return false;
}

/// Index into the sample by (run coordinate, row), whichever axis the course
/// runs along. Keeping the packer axis-agnostic is what lets a tile lay its
/// bricks the other way with no second code path.
static inline int at(int u, int row, int axis) {
    return axis == 0 ? TileSample::idx(u, row) : TileSample::idx(row, u);
}

/// The size ladder. `chance` is a hashed skip, so the largest sizes do not
/// carpet the ground in a regular grid -- a 2x6 that is skipped leaves room
/// for the 2x4 and 2x3 passes to make something less repetitive.
///
/// 2x4 and 2x2 are never skipped. 2x4 because it is the brief; 2x2 because it
/// is the piece that keeps the 1x1 count down.
struct SizeStep {
    int8_t a, b;
    float chance;
};

// A per-CELL chance on a big piece buys far more AREA than it looks: 2x6 at
// 0.22 measured 43% of the ground and pushed 2x4 down to 25%. The acceptance
// rate has to be divided by the piece's area to read as a share.
static const SizeStep LADDER[] = {
    { 2, 6, 0.05f },
    { 2, 4, 1.00f },
    { 2, 3, 0.80f },
    { 1, 4, 0.50f },
    { 2, 2, 1.00f },
    { 1, 3, 0.65f },
    { 1, 2, 1.00f },
    { 1, 1, 1.00f },
};
static const int LADDER_COUNT = (int)(sizeof(LADDER) / sizeof(LADDER[0]));

/// How many brick pieces carry a second course — a tile or a plate laid on
/// their studs. Runtime so a scene can turn it off and compare.
static float g_overlay_chance = OVERLAY_CHANCE;


/// A slope piece's top height at `s` studs from its back edge, in metres.
/// `top` is the terrace, `yf` where the face meets the front lip.
static float slope_profile(float s, int len, float top, float yf, bool straight = false) {
    if (straight) {
        // A cheese slope: one straight face from the back to the front.
        return top + (yf - top) * (s / (float)len);
    }
    if (len <= 1) {
        // A steep 1x1 face: straight from the top to the lip.
        return top + (yf - top) * s;
    }
    if (len <= 2) {
        // 1x2 slope: flat over the back stud, a straight face over the front.
        return s <= 1.0f ? top : top + (yf - top) * (s - 1.0f);
    }
    // Curved slope: flat at the back, falling ever steeper to the front.
    const float u = s / (float)len;
    return top - (top - yf) * u * u;
}


void pack_tile(const Field &f, const TileSample &s, std::vector<Piece> &out,
        std::vector<int32_t> &owner) {
    out.clear();
    owner.assign(TILE * TILE, -1);

    const uint32_t seed = f.seed;
    const int gx0 = s.tx * TILE;
    const int gz0 = s.tz * TILE;

    auto emit = [&](int ox, int oz, int sx, int sz, int kind, int ramp,
            int brx = 0, int brz = 0, int brsx = 0, int brsz = 0, bool held = false) {
        const int i = TileSample::idx(ox, oz);
        Piece pc;
        pc.ox = (int16_t)ox;
        pc.oz = (int16_t)oz;
        pc.sx = (int16_t)sx;
        pc.sz = (int16_t)sz;
        if (brsx > 0 && (brx != ox || brz != oz || brsx != sx || brsz != sz)) {
            pc.bx = (int16_t)brx;
            pc.bz = (int16_t)brz;
            pc.bsx = (int16_t)brsx;
            pc.bsz = (int16_t)brsz;
        }
        pc.h = s.h[i];
        pc.top = s.tp[i];
        pc.mat = s.mat[i];
        pc.kind = (uint8_t)kind;
        pc.ramp = (uint8_t)ramp;
        // Only a flat plate of a material that takes them carries studs. A
        // tile is smooth by definition and a ramp is not flat, so neither
        // does -- which is also why neither can be built on (section 7.6).
        pc.studded = (kind == PIECE_BRICK && material_studded(pc.mat)) ? 1 : 0;
        // Some flat pieces are laid smooth. A tile takes no studs and nothing
        // clips to it, so this is also a BUILD rule, not only a look: you
        // cannot build on a tiled patch (section 7.6).
        // By the BRICK's corner: both tiles' parts of a brick agree. Never a
        // brick something stands on (`held`): it holds that by its studs.
        pc.held = held ? 1 : 0;
        if (pc.studded && !held
                && hashf(gx0 + pc.brick_x(), gz0 + pc.brick_z(), (int32_t)(seed ^ 0x7113U))
                < TILE_CHANCE) {
            pc.kind = (uint8_t)PIECE_TILE;
            pc.studded = 0;
        }
        pc.overlay = 0;
        const int index = (int)out.size();
        out.push_back(pc);
        for (int dz = 0; dz < sz; ++dz) {
            for (int dx = 0; dx < sx; ++dx) {
                owner[(ox + dx) + TILE * (oz + dz)] = index;
            }
        }
    };

    // SLOPES FIRST (19.22, 19.24): pieces from the slope columns sample_tile
    // decided. A piece runs along the fall from the back-most column of its
    // run in this tile to the front-most, and up to 4 wide along the contour
    // where the columns beside it are the same run.
    if (!s.sl_r.empty()) {
        const int DXS[4] = { -1, 1, 0, 0 };
        const int DZS[4] = { 0, 0, -1, 1 };
        auto in_tile = [](int x, int z) { return x >= 0 && z >= 0 && x < TILE && z < TILE; };
        auto group = [&](int x, int z, int r, int len, int fall, int top) {
            const int i = TileSample::idx(x, z);
            return s.sl_r[i] == r && s.sl_len[i] == len && s.sl_fall[i] == fall && s.tp[i] == top;
        };
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                if (owner[lx + TILE * lz] >= 0) {
                    continue;
                }
                const int i0 = TileSample::idx(lx, lz);
                if (s.sl_r[i0] == 255) {
                    continue;
                }
                const int r = s.sl_r[i0], len = s.sl_len[i0], fall = s.sl_fall[i0], top = s.tp[i0];
                // Back to the back-most column of this run in the tile.
                int bx = lx, bz = lz, bd = s.sl_d[i0];
                while (in_tile(bx - DXS[r], bz - DZS[r]) && owner[(bx - DXS[r]) + TILE * (bz - DZS[r])] < 0
                        && group(bx - DXS[r], bz - DZS[r], r, len, fall, top)
                        && s.sl_d[TileSample::idx(bx - DXS[r], bz - DZS[r])] == bd + 1) {
                    bx -= DXS[r];
                    bz -= DZS[r];
                    ++bd;
                }
                // Forward to the front-most.
                int cnt = 1;
                while (cnt <= bd && in_tile(bx + DXS[r] * cnt, bz + DZS[r] * cnt)
                        && owner[(bx + DXS[r] * cnt) + TILE * (bz + DZS[r] * cnt)] < 0
                        && group(bx + DXS[r] * cnt, bz + DZS[r] * cnt, r, len, fall, top)
                        && s.sl_d[TileSample::idx(bx + DXS[r] * cnt, bz + DZS[r] * cnt)] == bd - cnt) {
                    ++cnt;
                }
                // Across the contour: the same strip beside it.
                const int ax = r < 2 ? 0 : 1, az = r < 2 ? 1 : 0;
                int w = 1;
                while (w < 4) {
                    bool ok = true;
                    for (int k = 0; k < cnt && ok; ++k) {
                        const int x = bx + DXS[r] * k + ax * w, z = bz + DZS[r] * k + az * w;
                        ok = in_tile(x, z) && owner[x + TILE * z] < 0 && group(x, z, r, len, fall, top)
                                && s.sl_d[TileSample::idx(x, z)] == bd - k;
                    }
                    if (!ok) {
                        break;
                    }
                    ++w;
                }
                // The rectangle: from the back cell, cnt along the fall, w across.
                const int ex = bx + DXS[r] * (cnt - 1), ez = bz + DZS[r] * (cnt - 1);
                int ox = std::min(bx, ex), oz = std::min(bz, ez);
                int sx = std::abs(ex - bx) + 1, sz = std::abs(ez - bz) + 1;
                if (r < 2) {
                    sz = w;
                } else {
                    sx = w;
                }
                emit(ox, oz, sx, sz, PIECE_SLOPE, r);
                out.back().slope_len = (uint8_t)len;
                out.back().fall = (uint8_t)fall;
                out.back().slope_s0 = (uint8_t)(len - 1 - bd);
                out.back().top = (int16_t)top;
                out.back().h = s.h[i0];
            }
        }
    }

    // Ramps first. They are 1x1 by nature -- a tilted top cannot be shared by
    // a longer piece -- and placing them before anything else stops a tile run
    // from swallowing one and drawing it flat.
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            const int i = TileSample::idx(lx, lz);
            if (s.smooth[i]) {
                continue;   // curved ground is not made of pieces
            }
            if (s.ramp[i] != 255) {
                emit(lx, lz, 1, 1, PIECE_RAMP, s.ramp[i]);
            }
        }
    }

    // A candidate fits if every cell it covers is free, of the right kind,
    // and agrees about height and material. A piece is one moulded part, so
    // it is flat and of one colour by construction.
    auto fits = [&](int ox, int oz, int sx, int sz, bool want_plate) {
        if (ox < 0 || oz < 0 || ox + sx > TILE || oz + sz > TILE) {
            return false;
        }
        const int i0 = TileSample::idx(ox, oz);
        const int16_t h0 = s.h[i0];
        const int16_t tp0 = s.tp[i0];
        const uint8_t m0 = s.mat[i0];
        const uint8_t c0 = s.col[i0];
        for (int dz = 0; dz < sz; ++dz) {
            for (int dx = 0; dx < sx; ++dx) {
                const int cx = ox + dx;
                const int cz = oz + dz;
                if (owner[cx + TILE * cz] >= 0) {
                    return false;
                }
                const int i = TileSample::idx(cx, cz);
                // A curve has no pieces in it, so no piece may reach into
                // one. This is the whole of the packer's involvement.
                if (s.smooth[i]) {
                    return false;
                }
                if ((s.plate[i] == 1) != want_plate) {
                    return false;
                }
                // Same exact top PLATE, not merely the same brick: two
                // columns whose bricks match but whose crater-cut tops differ
                // are not one flat piece.
                if (s.tp[i] != tp0 || s.h[i] != h0 || s.mat[i] != m0 || s.col[i] != c0) {
                    return false;
                }
            }
        }
        return true;
    };

    // One walk down the ladder, for one kind of cell.
    auto place_pass = [&](bool want_plate, int kind) {
        for (int step = 0; step < LADDER_COUNT; ++step) {
            const SizeStep &sz_step = LADDER[step];
            for (int lz = 0; lz < TILE; ++lz) {
                for (int lx = 0; lx < TILE; ++lx) {
                    if (owner[lx + TILE * lz] >= 0) {
                        continue;
                    }
                    const int gx = gx0 + lx;
                    const int gz = gz0 + lz;
                    if (sz_step.chance < 1.0f &&
                            hashf(gx, gz, (int32_t)(seed ^ 0xC0DEU) + step) >= sz_step.chance) {
                        continue;
                    }
                    // Which way round to try first. This is the whole of
                    // "courses run both ways": a 4x2 and a 2x4 are the same
                    // brick, and the hash decides which one this cell reaches
                    // for.
                    const bool flip = (hash3(gx, gz, (int32_t)(seed ^ 0x5A1DU) + step) & 1U) != 0;
                    const int8_t first_x = flip ? sz_step.b : sz_step.a;
                    const int8_t first_z = flip ? sz_step.a : sz_step.b;
                    if (fits(lx, lz, first_x, first_z, want_plate)) {
                        emit(lx, lz, first_x, first_z, kind, 255);
                    } else if (sz_step.a != sz_step.b &&
                            fits(lx, lz, first_z, first_x, want_plate)) {
                        emit(lx, lz, first_z, first_x, kind, 255);
                    }
                }
            }
        }
    };

    if (g_bond_top) {
        // THE BOND'S TOP COURSE (Docs/TerrainBond.md): the surface laid on
        // the same 4 x 4 blocks and parity rule as the ground under it, so
        // its seams never stand over the course below's. The ladder above
        // put pieces wherever a cell was free, and a seam over a seam split
        // a two-course arm (the collapse falls by these bricks).
        //
        // A brick here is the run of top cells of one exact top plate,
        // material and colour inside a bond footprint. It may cross the
        // tile's edge: each tile emits its part, knowing the whole (the
        // outline, the tint, breaking and the collapse go by the brick).
        // Past the sample the field answers, so both tiles agree.
        constexpr int PAD = 4;
        constexpr int SIDE = TILE + 2 * PAD;
        struct TopCell {
            int tp = 0, mat = 0, col = 0;
            bool free = true, known = false;
        };
        std::vector<TopCell> cells((size_t)SIDE * SIDE);
        // Ramps and slopes are placed already; nothing else is yet.
        const std::vector<int32_t> pre_owned = owner;
        auto top_at = [&](int lx, int lz) -> const TopCell & {
            TopCell &t = cells[(size_t)(lx + PAD) + SIDE * (size_t)(lz + PAD)];
            if (t.known) {
                return t;
            }
            t.known = true;
            if (lx >= -MARGIN && lz >= -MARGIN && lx < TILE + MARGIN && lz < TILE + MARGIN) {
                const int i = TileSample::idx(lx, lz);
                t.tp = s.tp[i];
                t.mat = s.mat[i];
                t.col = s.col[i];
                t.free = !s.smooth[i];
                if (lx >= 0 && lz >= 0 && lx < TILE && lz < TILE && pre_owned[lx + TILE * lz] >= 0) {
                    t.free = false;
                }
            } else {
                const int x = gx0 + lx, z = gz0 + lz;
                t.tp = BrickTerrain::surface_plate(x, z);
                t.mat = f.solid_at(x, t.tp, z);
                t.col = layer_colour(x, z);
            }
            return t;
        };
        // Solid at plate yp of column (x, z), absolute studs: the sample where
        // it has the cell, the field past it.
        auto solid_g = [&](int x, int yp, int z) -> bool {
            const int lx = x - gx0, lz = z - gz0;
            if (lx >= -MARGIN && lz >= -MARGIN && lx < TILE + MARGIN && lz < TILE + MARGIN
                    && s.in_y(yp)) {
                return s.solid(lx, yp, lz);
            }
            return f.solid_at(x, yp, z) != MAT_AIR;
        };
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                if (owner[lx + TILE * lz] >= 0) {
                    continue;
                }
                const TopCell &q = top_at(lx, lz);
                if (!q.free) {
                    continue;
                }
                const int qtp = q.tp, qmat = q.mat, qcol = q.col;
                const int qc = floor_div(qtp, PLATES_PER_CELL);
                int px, pz, psx, psz;
                const bool q_placed = placed_at(gx0 + lx, qc, gz0 + lz, px, pz, psx, psz);
                auto group = [&](int x, int z) {
                    const TopCell &t = top_at(x - gx0, z - gz0);
                    int a, b2, c2, d2;
                    return (t.free && t.tp == qtp && t.mat == qmat && t.col == qcol
                            && !placed_at(x, qc, z, a, b2, c2, d2))
                            ? BOND_STRONG : BOND_NONE;
                };
                // A placed block is the brick the player laid, whatever the
                // bond would have cut it into.
                const BondRect r = q_placed ? BondRect{ px, pz, psx, psz }
                        : bond_rect(gx0 + lx, qc, gz0 + lz, group);
                int cx0 = std::max(r.x - gx0, 0), cz0 = std::max(r.z - gz0, 0);
                int cx1 = std::min(r.x - gx0 + r.sx, TILE);
                int cz1 = std::min(r.z - gz0 + r.sz, TILE);
                if (q_placed) {
                    // Part of a placed brick may be built over or gone: then
                    // this cell alone (still outlined as the whole brick).
                    bool whole = true;
                    for (int z = cz0; z < cz1 && whole; ++z) {
                        for (int x = cx0; x < cx1 && whole; ++x) {
                            const TopCell &t = top_at(x, z);
                            int a, b2, c2, d2;
                            whole = owner[x + TILE * z] < 0 && t.free && t.tp == qtp
                                    && placed_at(gx0 + x, qc, gz0 + z, a, b2, c2, d2)
                                    && a == r.x && b2 == r.z;
                        }
                    }
                    if (!whole) {
                        cx0 = lx;
                        cz0 = lz;
                        cx1 = lx + 1;
                        cz1 = lz + 1;
                    }
                }
                bool plate = true;
                for (int z = cz0; z < cz1; ++z) {
                    for (int x = cx0; x < cx1; ++x) {
                        plate = plate && s.plate[TileSample::idx(x, z)] == 1;
                    }
                }
                // HELD (Docs/MineWorld.md 20): the user's rule, "any brick with
                // a brick on top of it must always have studs". The bond cuts
                // a top brick out of its course's 4 x 2 footprint; where that
                // footprint reaches under a higher column -- the foot of every
                // step, a wall standing on the course -- the brick is what the
                // course above stands on, so it is a studded brick, never a
                // smooth tile (a tile only had to be one because its column
                // was not level with all four neighbours).
                bool held = false;
                if (!q_placed) {
                    const BondRect fp = bond_rect(gx0 + lx, qc, gz0 + lz,
                            [](int, int) { return BOND_STRONG; });
                    const int above = (qc + 1) * PLATES_PER_CELL;
                    for (int z = fp.z; z < fp.z + fp.sz && !held; ++z) {
                        for (int x = fp.x; x < fp.x + fp.sx && !held; ++x) {
                            const TopCell &t = top_at(x - gx0, z - gz0);
                            held = t.tp >= above && solid_g(x, above, z)
                                    && solid_g(x, above - 1, z);
                        }
                    }
                }
                emit(cx0, cz0, cx1 - cx0, cz1 - cz0, (plate || held) ? PIECE_BRICK : PIECE_TILE, 255,
                        r.x - gx0, r.z - gz0, r.sx, r.sz, held);
            }
        }
    } else {
        place_pass(true, PIECE_BRICK);
        place_pass(false, PIECE_TILE);
    }

    // A second course, laid on some of the bricks.
    //
    // A real build is not one layer deep. Putting a tile or a plate on a
    // brick gives the ground a 0.14 m lip, breaks the flatness, and mixes
    // smooth faces in among the studded ones -- and because the overlay
    // covers its brick EXACTLY, the brick's top face is culled rather than
    // drawn and hidden. Whole-piece coverage is what buys that: a partly
    // covered piece would have to keep its top and pay for both.
    for (Piece &pc : out) {
        if (pc.kind != PIECE_BRICK) {
            continue;
        }
        const int gx = gx0 + pc.brick_x();   // the brick's corner: both tiles agree
        const int gz = gz0 + pc.brick_z();
        if (hashf(gx, gz, (int32_t)(seed ^ 0x0A11U)) >= g_overlay_chance) {
            continue;
        }
        // A held brick may take a studded plate, never a smooth tile.
        const bool smooth = pc.held == 0
                && hashf(gx, gz, (int32_t)(seed ^ 0x71E5U)) < OVERLAY_TILE_SHARE;
        pc.overlay = smooth ? 1 : 2;
        // A smooth tile has nothing to clip to, so it takes no studs and
        // cannot be built on -- the same rule PIECE_TILE follows, and the
        // same one `mates()` enforces for free (section 7.6).
        if (smooth) {
            pc.studded = 0;
        }
    }
}

} // namespace brick

// ---------------------------------------------------------------------------
// BrickTerrain
// ---------------------------------------------------------------------------

using namespace brick;

static Field g_field;

// --- the bond's view of a tile (Docs/TerrainBond.md) -------------------------

namespace {

/// What the bond (terrain_bond.h) needs to know of one course cell -- its
/// group, or none -- read from a tile's sample where it reaches and from the
/// field past it, so two tiles agree on a brick across their shared edge.
///
/// `tops`: the sample is a surface tile, whose top courses are the packer's
/// pieces (a cell at or above its column's top course is not the bond's).
/// A deep-tier section has no top courses.
struct BondView {
    const TileSample &s;
    bool tops;
    int c_lo = 0, c_n = 0;            ///< courses the memo spans
    static constexpr int PAD = 4;     ///< studs past the tile the memo spans
    static constexpr int SIDE = TILE + 2 * PAD;
    std::vector<uint8_t> memo;        ///< group + 1, 0 unknown
    std::vector<int32_t> top_memo;    ///< top plate past the sample, INT_MIN unknown
    /// The region fit's bricks (Docs/TerrainRegions.md 12), when the game
    /// uses them (TerrainFit.set_enabled); else the old pattern.
    bool fit_on = false;
    brick::FitView fit;
    std::unordered_map<int64_t, bool> whole_memo;

    BondView(const TileSample &p_s, bool p_tops) : s(p_s), tops(p_tops) {
        fit_on = brick::fit_enabled();
        c_lo = floor_div(s.y0, PLATES_PER_CELL) - 1;
        c_n = floor_div(s.y0 + s.ysize - 1, PLATES_PER_CELL) - c_lo + 2;
        memo.assign((size_t)SIDE * SIDE * c_n, 0);
        top_memo.assign((size_t)SIDE * SIDE, INT_MIN);
    }

    bool in_sample(int lx, int lz) const {
        return lx >= -MARGIN && lz >= -MARGIN && lx < TILE + MARGIN && lz < TILE + MARGIN;
    }

    /// The column's topmost solid plate (absolute studs).
    int top_plate(int x, int z) {
        const int lx = x - s.tx * TILE, lz = z - s.tz * TILE;
        if (in_sample(lx, lz)) {
            return s.tp[TileSample::idx(lx, lz)];
        }
        const bool memoed = lx >= -PAD && lz >= -PAD && lx < TILE + PAD && lz < TILE + PAD;
        const size_t i = memoed ? (size_t)(lx + PAD) + SIDE * (size_t)(lz + PAD) : 0;
        if (memoed && top_memo[i] != INT_MIN) {
            return top_memo[i];
        }
        const int t = BrickTerrain::surface_plate(x, z);
        if (memoed) {
            top_memo[i] = t;
        }
        return t;
    }

    /// The material of the cell's lowest solid plate, or air.
    int material(int x, int c, int z) const {
        const int lx = x - s.tx * TILE, lz = z - s.tz * TILE;
        const bool in = in_sample(lx, lz);
        for (int p = 0; p < PLATES_PER_CELL; ++p) {
            const int yp = c * PLATES_PER_CELL + p;
            const int m = (in && s.in_y(yp)) ? s.voxel(lx, yp, lz) : g_field.solid_at(x, yp, z);
            if (m != MAT_AIR) {
                return m;
            }
        }
        return MAT_AIR;
    }

    int group(int x, int c, int z) {
        const int lx = x - s.tx * TILE, lz = z - s.tz * TILE;
        const bool memoed = lx >= -PAD && lz >= -PAD && lx < TILE + PAD && lz < TILE + PAD
                && c >= c_lo && c < c_lo + c_n;
        size_t i = 0;
        if (memoed) {
            i = (size_t)(lx + PAD) + SIDE * ((size_t)(lz + PAD) + SIDE * (size_t)(c - c_lo));
            if (memo[i] != 0) {
                return memo[i] - 1;
            }
        }
        int g = bond_group(material(x, c, z));
        if (g != BOND_NONE && tops && c >= floor_div(top_plate(x, z), PLATES_PER_CELL)) {
            g = BOND_NONE;   // the top course: the packer's piece
        }
        int px, pz, psx, psz;
        if (g != BOND_NONE && placed_at(x, c, z, px, pz, psx, psz)) {
            g = BOND_NONE;   // a placed brick: its own shape
        }
        if (memoed) {
            memo[i] = (uint8_t)(g + 1);
        }
        return g;
    }

    /// Every cell of fitted brick `b` still a bond cell (not dug, built
    /// over, made the top course by a hole or placed): the fit is of the
    /// generated cells, and a brick an edit cut is its cells one by one.
    bool whole(const brick::FitBrick &b) {
        const int64_t k = bond_key(b.x, b.c, b.z);
        auto it = whole_memo.find(k);
        if (it != whole_memo.end()) {
            return it->second;
        }
        bool ok = true;
        for (int cc = b.c; cc < b.c + b.h && ok; ++cc) {
            for (int zz = b.z; zz < b.z + b.sz && ok; ++zz) {
                for (int xx = b.x; xx < b.x + b.sx && ok; ++xx) {
                    const int g = group(xx, cc, zz);
                    ok = g == BOND_MEDIUM || g == BOND_STRONG;
                }
            }
        }
        whole_memo[k] = ok;
        return ok;
    }

    /// The fitted regions this sample's open faces are in, fitted in one go
    /// before a mesh asks for them cell by cell (Docs/TerrainRegions.md 12):
    /// a region is fitted only where some cell of it is drawn.
    void prefetch_open() {
        if (!fit_on) {
            return;
        }
        std::vector<std::array<int, 3>> cells;
        const int ylo = s.y0, yhi = s.y0 + s.ysize;
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                int last_c = INT_MIN;
                for (int yp = ylo; yp < yhi; ++yp) {
                    const size_t i = (size_t)s.vidx(lx, yp, lz);
                    if (s.vox[i] == MAT_AIR) {
                        continue;
                    }
                    const int c = floor_div(yp, PLATES_PER_CELL);
                    if (c == last_c) {
                        continue;
                    }
                    if (!(s.open_air(lx - 1, yp, lz) || s.open_air(lx + 1, yp, lz)
                                || s.open_air(lx, yp - 1, lz) || s.open_air(lx, yp + 1, lz)
                                || s.open_air(lx, yp, lz - 1) || s.open_air(lx, yp, lz + 1))) {
                        continue;
                    }
                    last_c = c;
                    cells.push_back({ s.tx * TILE + lx, c, s.tz * TILE + lz });
                }
            }
        }
        fit.prefetch(cells);
    }

    /// A bond cell in a fitted brick still whole (`b` that brick).
    bool in_fitted(int x, int c, int z, brick::FitBrick &b) {
        const int g = group(x, c, z);
        return (g == BOND_MEDIUM || g == BOND_STRONG) && fit.at(x, c, z, b) && whole(b);
    }

    /// The brick of a bond cell (group MEDIUM or STRONG; anything else is
    /// its own 1x1). Its `c` and `h` always set: the fitted brick's bottom
    /// course and height, else `c` and 1.
    BondRect rect(int x, int c, int z) {
        int px, pz, psx, psz;
        if (placed_at(x, c, z, px, pz, psx, psz)) {
            return BondRect{ px, pz, psx, psz, c, 1 };
        }
        if (fit_on) {
            brick::FitBrick b;
            if (in_fitted(x, c, z, b)) {
                return BondRect{ b.x, b.z, b.sx, b.sz, b.c, b.h };
            }
            // Ground the fit does not hold whole (built up by edits, the rest
            // of a brick a hole cut): the old pattern among those cells only,
            // so it never overlaps a fitted brick.
            BondRect r = bond_rect(x, c, z, [&](int cx, int cz) {
                brick::FitBrick q;
                return in_fitted(cx, c, cz, q) ? (int)BOND_NONE : group(cx, c, cz);
            });
            r.c = c;
            r.h = 1;
            return r;
        }
        BondRect r = bond_rect(x, c, z, [&](int cx, int cz) { return group(cx, c, cz); });
        r.c = c;
        r.h = 1;
        return r;
    }
};

/// clear_runs' runs for a top-course piece's whole brick (tile `s`'s piece;
/// its brick may reach into the next tile, whose tops the view reads).
void piece_runs(const TileSample &s, const Piece &p, BondView &view, PackedInt32Array &runs) {
    for (int dz = 0; dz < p.brick_sz(); ++dz) {
        for (int dx = 0; dx < p.brick_sx(); ++dx) {
            const int x = s.tx * TILE + p.brick_x() + dx;
            const int z = s.tz * TILE + p.brick_z() + dz;
            const int t = view.top_plate(x, z);
            runs.push_back(x);
            runs.push_back(z);
            runs.push_back(floor_div(t, PLATES_PER_CELL) * PLATES_PER_CELL);
            runs.push_back(t);
        }
    }
}

/// clear_runs' runs for one bond brick (BondView::rect's): every column of
/// it, all its courses.
void bond_runs(const BondRect &r, PackedInt32Array &runs) {
    for (int dz = 0; dz < r.sz; ++dz) {
        for (int dx = 0; dx < r.sx; ++dx) {
            runs.push_back(r.x + dx);
            runs.push_back(r.z + dz);
            runs.push_back(r.c * PLATES_PER_CELL);
            runs.push_back((r.c + r.h) * PLATES_PER_CELL - 1);
        }
    }
}

} // namespace


/// The old geometry chamfer (a chamfered copy of each near tile) was deleted
/// on 2026-11-24: real bevels are the brick overlay's instanced bricks
/// (TerrainBricks, Docs/BrickOverlay.md). The mesher draws flat faces only.

void BrickTerrain::configure(int64_t world_seed) {
    g_field.seed = (uint32_t)(world_seed & 0xffffffff);
    brick::bump_field_version();
}

int BrickTerrain::get_field_version() { return FIELD_VERSION; }
int64_t BrickTerrain::get_seed() { return (int64_t)g_field.seed; }
float BrickTerrain::get_brick_metres() { return BRICK_M; }
int BrickTerrain::get_tile_studs() { return TILE; }
int BrickTerrain::get_max_piece_length() { return MAX_LEN; }
int BrickTerrain::get_period() { return PERIOD; }

int BrickTerrain::get_piece_stride() { return PIECE_STRIDE; }

/// The real surface, in bricks: scan down from the nominal top until
/// something solid. A cave mouth or a crater lowers it; nothing raises it.
int BrickTerrain::height_at(int x, int z) {
    return floor_div(surface_plate(x, z), PLATES_PER_CELL);
}

/// Does the sun reach this column's top?
///
/// A ray march over the heightfield, which is the whole of it: step along the
/// sun's horizontal direction, raise the ray by the sun's slope, and if the
/// ground is ever above the ray the column is in shadow.
///
/// Cheap enough to do per PIECE at build time (24 field samples) and far too
/// expensive to do per frame, which is the trade the whole idea rests on.
static bool sun_reaches(int x, int z) {
    if (g_sun_dir.length_squared() < 1e-6f) {
        return true;
    }
    const Vector3 d = g_sun_dir.normalized();
    const float horiz = std::sqrt(d.x * d.x + d.z * d.z);
    if (d.y <= 0.02f) {
        return true;    // the sun is on the horizon; nothing is lit by it
    }
    if (horiz < 1e-4f) {
        return true;    // straight overhead
    }
    const float start = (float)(BrickTerrain::surface_plate(x, z) + 1) * PLATE_M;
    // Rise per stud travelled along the ground.
    const float rise = (d.y / horiz) * STUD_M;
    const float sx = d.x / horiz;
    const float sz = d.z / horiz;
    for (int t = SUN_STEP; t <= SUN_REACH; t += SUN_STEP) {
        const int px = x + (int)std::lround(sx * (float)t);
        const int pz = z + (int)std::lround(sz * (float)t);
        const float ray = start + rise * (float)t;
        const float ground = (float)(BrickTerrain::surface_plate(px, pz) + 1) * PLATE_M;
        if (ground > ray) {
            return false;
        }
        // Once the ray is above anything the field can reach, stop.
        if (ray - ground > 40.0f) {
            break;
        }
    }
    return true;
}

void BrickTerrain::add_pad(int x, int z, int radius, int skirt, double height_m,
        int radius_z) {
    Pad p;
    p.x = x;
    p.z = z;
    p.radius = std::max(radius, 0);
    p.radius_z = radius_z < 0 ? p.radius : radius_z;
    p.skirt = std::max(skirt, 0);
    // Snapped to 1/64 plate: a height that came back through a float as
    // 128.99999 plates floored to the plate below the building's floor.
    p.plates = (float)(std::round(height_m / (double)PLATE_M * 64.0) / 64.0);
    g_pads.push_back(p);
    g_pad_gen.fetch_add(1, std::memory_order_acq_rel);
}

void BrickTerrain::clear_pads() {
    g_pads.clear();
    g_pad_gen.fetch_add(1, std::memory_order_acq_rel);
}
int BrickTerrain::pad_count() { return (int)g_pads.size(); }

int BrickTerrain::pad_at(int x, int z) {
    for (size_t i = 0; i < g_pads.size(); ++i) {
        if (pad_weight(g_pads[i], x, z) >= 1.0f) {
            return (int)i;
        }
    }
    return -1;
}

Dictionary BrickTerrain::get_pad(int index) {
    Dictionary d;
    if (index < 0 || index >= (int)g_pads.size()) {
        return d;
    }
    const Pad &p = g_pads[(size_t)index];
    d["x"] = p.x;
    d["z"] = p.z;
    d["radius"] = p.radius;
    d["radius_z"] = p.radius_z;
    d["skirt"] = p.skirt;
    d["height"] = (double)p.plates * (double)PLATE_M;
    return d;
}

void BrickTerrain::set_pad(int index, int x, int z, int radius, int skirt,
        double height_m, int radius_z) {
    if (index < 0 || index >= (int)g_pads.size()) {
        return;
    }
    Pad &p = g_pads[(size_t)index];
    p.x = x;
    p.z = z;
    p.radius = std::max(radius, 0);
    p.radius_z = radius_z < 0 ? p.radius : radius_z;
    p.skirt = std::max(skirt, 0);
    // Snapped to 1/64 plate: a height that came back through a float as
    // 128.99999 plates floored to the plate below the building's floor.
    p.plates = (float)(std::round(height_m / (double)PLATE_M * 64.0) / 64.0);
    g_pad_gen.fetch_add(1, std::memory_order_acq_rel);
}

void BrickTerrain::remove_pad(int index) {
    if (index < 0 || index >= (int)g_pads.size()) {
        return;
    }
    g_pads.erase(g_pads.begin() + index);
    g_pad_gen.fetch_add(1, std::memory_order_acq_rel);
}

Rect2i BrickTerrain::pad_bounds(int index) {
    if (index < 0 || index >= (int)g_pads.size()) {
        return Rect2i();
    }
    const Pad &p = g_pads[(size_t)index];
    const int rx = p.radius + p.skirt;
    const int rz = p.radius_z + p.skirt;
    return Rect2i(p.x - rx, p.z - rz, rx * 2 + 1, rz * 2 + 1);
}

// --- sculpt, the writing half --------------------------------------------------

namespace {
struct Stroke {
    // The tiles as they were before the stroke first touched them; null for a
    // tile that did not exist.
    std::unordered_map<int64_t, std::shared_ptr<const SculptTile>> before;
    Rect2i bounds;
};
std::vector<Stroke> g_strokes;
constexpr size_t MAX_STROKES = 64;

void publish(std::shared_ptr<const SculptMap> m) {
    const bool any = !m->empty();
    std::atomic_store(&g_sculpt, std::move(m));
    g_sculpt_any.store(any, std::memory_order_release);
    g_sculpt_gen.fetch_add(1, std::memory_order_acq_rel);
}

Rect2i merge_rect(const Rect2i &a, const Rect2i &b) {
    if (a.size.x <= 0) {
        return b;
    }
    return a.merge(b);
}
} // namespace

Rect2i BrickTerrain::sculpt(int x, int z, double radius, int mode, double amount, double target_m) {
    const float r = (float)std::max(radius, 0.5);
    const int ri = (int)std::ceil(r);
    const Rect2i box(x - ri, z - ri, ri * 2 + 1, ri * 2 + 1);
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));

    // The surface BEFORE this dab: noise plus sculpt, no pads. Read once for
    // the box (and a margin, for smoothing) so every column of the dab sees
    // the same ground.
    const int m = 1;
    const int w = box.size.x + 2 * m;
    std::vector<float> before((size_t)w * (size_t)(box.size.y + 2 * m));
    // Without the pads: the offset is measured against the ground the stroke
    // paints, not against a building's flat spot over it. `base_plate` reads
    // the PUBLISHED sculpt, which is what `next` was copied from.
    for (int dz = 0; dz < box.size.y + 2 * m; ++dz) {
        for (int dx = 0; dx < w; ++dx) {
            const int cx = box.position.x - m + dx;
            const int cz = box.position.y - m + dz;
            before[(size_t)dz * w + dx] = g_field.base_plate(cx, cz);
        }
    }
    auto h_at = [&](int cx, int cz) {
        return before[(size_t)(cz - box.position.y + m) * w + (cx - box.position.x + m)];
    };

    Stroke *stroke = g_strokes.empty() ? nullptr : &g_strokes.back();
    const float target = (float)(target_m / (double)PLATE_M);
    const float raise = (float)(amount / (double)PLATE_M);
    const float k = (float)std::clamp(amount, 0.0, 1.0);
    std::unordered_map<int64_t, std::shared_ptr<SculptTile>> writable;
    for (int cz = box.position.y; cz < box.position.y + box.size.y; ++cz) {
        for (int cx = box.position.x; cx < box.position.x + box.size.x; ++cx) {
            const float d = std::sqrt((float)((cx - x) * (cx - x) + (cz - z) * (cz - z)));
            if (d > r) {
                continue;
            }
            const float t = d / r;
            const float fall = 1.0f - t * t * (3.0f - 2.0f * t);
            float delta = 0.0f;
            if (mode == 0) {
                delta = raise * fall;
            } else if (mode == 1) {
                delta = (target - h_at(cx, cz)) * k * fall;
            } else {
                float sum = 0.0f;
                for (int oz = -1; oz <= 1; ++oz) {
                    for (int ox = -1; ox <= 1; ++ox) {
                        sum += h_at(cx + ox, cz + oz);
                    }
                }
                delta = (sum / 9.0f - h_at(cx, cz)) * k * fall;
            }
            if (delta == 0.0f) {
                continue;
            }
            const int tx = floor_div(cx, TILE);
            const int tz = floor_div(cz, TILE);
            const int64_t key = sculpt_key(tx, tz);
            auto wit = writable.find(key);
            if (wit == writable.end()) {
                auto old = next->find(key);
                std::shared_ptr<const SculptTile> was = old == next->end() ? nullptr : old->second;
                if (stroke != nullptr && stroke->before.find(key) == stroke->before.end()) {
                    stroke->before.emplace(key, was);
                }
                auto fresh = was ? std::make_shared<SculptTile>(*was) : std::make_shared<SculptTile>();
                wit = writable.emplace(key, fresh).first;
                (*next)[key] = fresh;
            }
            wit->second->v[(cz - tz * TILE) * TILE + (cx - tx * TILE)] += delta;
        }
    }
    publish(std::move(next));
    if (stroke != nullptr) {
        stroke->bounds = merge_rect(stroke->bounds, box);
    }
    return box;
}

void BrickTerrain::sculpt_begin_stroke() {
    if (!g_strokes.empty() && g_strokes.back().before.empty()) {
        return;   // the last one never touched anything: reuse it
    }
    g_strokes.emplace_back();
    if (g_strokes.size() > MAX_STROKES) {
        g_strokes.erase(g_strokes.begin());
    }
}

Rect2i BrickTerrain::sculpt_undo() {
    while (!g_strokes.empty() && g_strokes.back().before.empty()) {
        g_strokes.pop_back();
    }
    if (g_strokes.empty()) {
        return Rect2i();
    }
    Stroke s = std::move(g_strokes.back());
    g_strokes.pop_back();
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));
    for (auto &kv : s.before) {
        if (kv.second) {
            (*next)[kv.first] = kv.second;
        } else {
            next->erase(kv.first);
        }
    }
    publish(std::move(next));
    return s.bounds;
}

int BrickTerrain::sculpt_undo_depth() {
    int n = 0;
    for (const Stroke &s : g_strokes) {
        n += s.before.empty() ? 0 : 1;
    }
    return n;
}

void BrickTerrain::clear_sculpt() {
    g_strokes.clear();
    publish(std::make_shared<SculptMap>());
}

double BrickTerrain::sculpt_at(int x, int z) {
    return (double)sculpt_plates(x, z) * (double)PLATE_M;
}

Array BrickTerrain::sculpt_tiles() {
    Array out;
    for (const auto &kv : *std::atomic_load(&g_sculpt)) {
        const int tx = (int)(kv.first >> 32);
        const int tz = (int)(int32_t)(uint32_t)(kv.first & 0xFFFFFFFF);
        out.append(Vector2i(tx, tz));
    }
    return out;
}

PackedFloat32Array BrickTerrain::get_sculpt_tile(int tx, int tz) {
    PackedFloat32Array out;
    auto m = std::atomic_load(&g_sculpt);
    auto it = m->find(sculpt_key(tx, tz));
    if (it == m->end()) {
        return out;
    }
    out.resize(TILE * TILE);
    for (int i = 0; i < TILE * TILE; ++i) {
        out.set(i, it->second->v[i] * PLATE_M);
    }
    return out;
}

Rect2i BrickTerrain::paint_surface(int x, int z, double radius, int material, int colour) {
    const float r = (float)std::max(radius, 0.5);
    const int ri = (int)std::ceil(r);
    const Rect2i box(x - ri, z - ri, ri * 2 + 1, ri * 2 + 1);
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));
    Stroke *stroke = g_strokes.empty() ? nullptr : &g_strokes.back();
    std::unordered_map<int64_t, std::shared_ptr<SculptTile>> writable;
    auto code = [](int v, int was) {
        return v == -1 ? was : (v == -2 ? 0xFF : std::clamp(v, 0, 254));
    };
    for (int cz = box.position.y; cz < box.position.y + box.size.y; ++cz) {
        for (int cx = box.position.x; cx < box.position.x + box.size.x; ++cx) {
            const float d2 = (float)((cx - x) * (cx - x) + (cz - z) * (cz - z));
            if (d2 > r * r) {
                continue;
            }
            const int tx = floor_div(cx, TILE);
            const int tz = floor_div(cz, TILE);
            const int64_t key = sculpt_key(tx, tz);
            const int i = (cz - tz * TILE) * TILE + (cx - tx * TILE);
            auto wit = writable.find(key);
            if (wit == writable.end()) {
                auto old = next->find(key);
                std::shared_ptr<const SculptTile> was = old == next->end() ? nullptr : old->second;
                const int m_was = was ? was->mat[i] : 0xFF;
                const int c_was = was ? was->col[i] : 0xFF;
                if (code(material, m_was) == m_was && code(colour, c_was) == c_was) {
                    continue;   // nothing to change, and no tile worth cloning
                }
                if (stroke != nullptr && stroke->before.find(key) == stroke->before.end()) {
                    stroke->before.emplace(key, was);
                }
                auto fresh = was ? std::make_shared<SculptTile>(*was) : std::make_shared<SculptTile>();
                wit = writable.emplace(key, fresh).first;
                (*next)[key] = fresh;
            }
            SculptTile &t = *wit->second;
            t.mat[i] = (uint8_t)code(material, t.mat[i]);
            t.col[i] = (uint8_t)code(colour, t.col[i]);
        }
    }
    publish(std::move(next));
    if (stroke != nullptr) {
        stroke->bounds = merge_rect(stroke->bounds, box);
    }
    return box;
}

Rect2i BrickTerrain::paint_form(int x, int z, double radius, int form) {
    const float r = (float)std::max(radius, 0.5);
    const int ri = (int)std::ceil(r);
    const Rect2i box(x - ri, z - ri, ri * 2 + 1, ri * 2 + 1);
    const int code = form < 0 ? 0xFF : std::clamp(form, 0, 1);
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));
    Stroke *stroke = g_strokes.empty() ? nullptr : &g_strokes.back();
    std::unordered_map<int64_t, std::shared_ptr<SculptTile>> writable;
    for (int cz = box.position.y; cz < box.position.y + box.size.y; ++cz) {
        for (int cx = box.position.x; cx < box.position.x + box.size.x; ++cx) {
            const float d2 = (float)((cx - x) * (cx - x) + (cz - z) * (cz - z));
            if (d2 > r * r) {
                continue;
            }
            const int tx = floor_div(cx, TILE);
            const int tz = floor_div(cz, TILE);
            const int64_t key = sculpt_key(tx, tz);
            const int i = (cz - tz * TILE) * TILE + (cx - tx * TILE);
            auto wit = writable.find(key);
            if (wit == writable.end()) {
                auto old = next->find(key);
                std::shared_ptr<const SculptTile> was = old == next->end() ? nullptr : old->second;
                if ((was ? was->form[i] : 0xFF) == code) {
                    continue;   // nothing to change, and no tile worth cloning
                }
                if (stroke != nullptr && stroke->before.find(key) == stroke->before.end()) {
                    stroke->before.emplace(key, was);
                }
                auto fresh = was ? std::make_shared<SculptTile>(*was) : std::make_shared<SculptTile>();
                wit = writable.emplace(key, fresh).first;
                (*next)[key] = fresh;
            }
            wit->second->form[i] = (uint8_t)code;
        }
    }
    publish(std::move(next));
    if (stroke != nullptr) {
        stroke->bounds = merge_rect(stroke->bounds, box);
    }
    return box;
}

int BrickTerrain::form_at(int x, int z) { return layer_form(x, z); }

PackedByteArray BrickTerrain::get_form_tile(int tx, int tz) {
    PackedByteArray out;
    auto m = std::atomic_load(&g_sculpt);
    auto it = m->find(sculpt_key(tx, tz));
    if (it == m->end()) {
        return out;
    }
    out.resize(TILE * TILE);
    for (int i = 0; i < TILE * TILE; ++i) {
        out.set(i, it->second->form[i]);
    }
    return out;
}

void BrickTerrain::set_form_tile(int tx, int tz, const PackedByteArray &bytes) {
    if (bytes.size() != TILE * TILE) {
        return;
    }
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));
    auto old = next->find(sculpt_key(tx, tz));
    auto t = old == next->end() ? std::make_shared<SculptTile>()
                                : std::make_shared<SculptTile>(*old->second);
    for (int i = 0; i < TILE * TILE; ++i) {
        t->form[i] = bytes[i];
    }
    (*next)[sculpt_key(tx, tz)] = t;
    publish(std::move(next));
}

Vector2i BrickTerrain::surface_paint_at(int x, int z) {
    return Vector2i(layer_material(x, z), layer_colour(x, z));
}

int BrickTerrain::colour_at(int x, int z) {
    const int painted = layer_colour(x, z);
    return painted != 0xFF ? painted : brick::material_filament(material_at(x, z));
}

PackedByteArray BrickTerrain::get_surface_paint_tile(int tx, int tz) {
    PackedByteArray out;
    auto m = std::atomic_load(&g_sculpt);
    auto it = m->find(sculpt_key(tx, tz));
    if (it == m->end()) {
        return out;
    }
    out.resize(TILE * TILE * 2);
    for (int i = 0; i < TILE * TILE; ++i) {
        out.set(i, it->second->mat[i]);
        out.set(TILE * TILE + i, it->second->col[i]);
    }
    return out;
}

void BrickTerrain::set_surface_paint_tile(int tx, int tz, const PackedByteArray &bytes) {
    if (bytes.size() != TILE * TILE * 2) {
        return;
    }
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));
    auto old = next->find(sculpt_key(tx, tz));
    auto t = old == next->end() ? std::make_shared<SculptTile>()
                                : std::make_shared<SculptTile>(*old->second);
    for (int i = 0; i < TILE * TILE; ++i) {
        t->mat[i] = bytes[i];
        t->col[i] = bytes[TILE * TILE + i];
    }
    (*next)[sculpt_key(tx, tz)] = t;
    publish(std::move(next));
}

void BrickTerrain::set_sculpt_tile(int tx, int tz, const PackedFloat32Array &metres) {
    auto next = std::make_shared<SculptMap>(*std::atomic_load(&g_sculpt));
    auto old = next->find(sculpt_key(tx, tz));
    auto t = old == next->end() ? std::make_shared<SculptTile>()
                                : std::make_shared<SculptTile>(*old->second);
    for (int i = 0; i < TILE * TILE; ++i) {
        t->v[i] = metres.size() == TILE * TILE ? metres[i] / PLATE_M : 0.0f;
    }
    (*next)[sculpt_key(tx, tz)] = t;
    publish(std::move(next));
}

void BrickTerrain::add_paint(int x, int z, int radius, int skirt, int material) {
    Paint p;
    p.x = x;
    p.z = z;
    p.radius = std::max(radius, 0);
    p.skirt = std::max(skirt, 0);
    p.mat = (uint8_t)std::min(std::max(material, 1), (int)MAT_ROAD);
    g_paints.push_back(p);
}

void BrickTerrain::clear_paints() { g_paints.clear(); }
int BrickTerrain::paint_count() { return (int)g_paints.size(); }

Dictionary BrickTerrain::get_paint(int index) {
    Dictionary d;
    if (index < 0 || index >= (int)g_paints.size()) {
        return d;
    }
    const Paint &p = g_paints[(size_t)index];
    d["x"] = p.x;
    d["z"] = p.z;
    d["radius"] = p.radius;
    d["skirt"] = p.skirt;
    d["material"] = (int)p.mat;
    return d;
}

void BrickTerrain::set_paint(int index, int x, int z, int radius, int skirt,
        int material) {
    if (index < 0 || index >= (int)g_paints.size()) {
        return;
    }
    Paint &p = g_paints[(size_t)index];
    p.x = x;
    p.z = z;
    p.radius = std::max(radius, 0);
    p.skirt = std::max(skirt, 0);
    p.mat = (uint8_t)std::min(std::max(material, 1), (int)MAT_ROAD);
}

void BrickTerrain::remove_paint(int index) {
    if (index < 0 || index >= (int)g_paints.size()) {
        return;
    }
    g_paints.erase(g_paints.begin() + index);
}

Rect2i BrickTerrain::paint_bounds(int index) {
    if (index < 0 || index >= (int)g_paints.size()) {
        return Rect2i();
    }
    const Paint &p = g_paints[(size_t)index];
    const int r = p.radius + p.skirt;
    return Rect2i(p.x - r, p.z - r, r * 2 + 1, r * 2 + 1);
}

int BrickTerrain::paint_at(int x, int z) { return painted_at(x, z, g_field.seed); }

PackedStringArray BrickTerrain::material_names() {
    PackedStringArray out;
    out.push_back("air");
    out.push_back("grass");
    out.push_back("dirt");
    out.push_back("sand");
    out.push_back("stone");
    out.push_back("dark stone");
    out.push_back("road");
    for (const char *n : { "snow", "gravel", "sandstone", "red sand", "terracotta",
            "cream terracotta", "red terracotta", "clay", "bedrock", "coal ore", "iron ore",
            "copper ore", "gold ore", "redstone ore", "lapis ore", "diamond ore", "podzol",
            "dry grass", "lush grass", "cold grass", "dark grass", "granite", "diorite", "ice", "obsidian",
            "wood", "leaves", "pale wood", "birch wood", "light leaves",
            "autumn leaves", "red leaves", "farmland", "wet farmland", "glass" }) {
        out.push_back(n);
    }
    return out;
}

void BrickTerrain::set_sun_direction(Vector3 to_sun) { g_sun_dir = to_sun; }
Vector3 BrickTerrain::get_sun_direction() { return g_sun_dir; }
bool BrickTerrain::sunlit(int x, int z) { return sun_reaches(x, z); }

int BrickTerrain::surface_plate(int x, int z) {
    if (biomes_on()) {
        // One column decision, then a scan down it: solid_at per plate would
        // decide the column again for every plate of air above the ground.
        const BColumn c = biome_column(g_field.seed, x, z);
        int floor_p = c.low_p - SECTION_BELOW;
        const int dug = deepest_edit_near(floor_div(x, TILE), floor_div(z, TILE));
        if (dug != INT_MAX) {
            floor_p = std::min(floor_p, dug - 6);
        }
        const bool any_edits = !edits_empty();
        int last_b = INT_MIN;
        int last_v = MAT_AIR;
        const int placed = highest_edit_near(floor_div(x, TILE), floor_div(z, TILE));
        const int from = std::max(c.bound_p, placed);
        for (int yp = from; yp > floor_p; --yp) {
            int v;
            const int e = any_edits ? edit_at(pack_cell(x, yp, z)) : -1;
            if (e >= 0) {
                v = e;
            } else {
                const int yb = floor_div(yp, PLATES_PER_CELL);
                if (yb != last_b) {
                    last_b = yb;
                    last_v = biome_cell(c, g_field.seed, x, yb, z);
                }
                v = last_v;
            }
            if (v != MAT_AIR) {
                return yp;
            }
        }
        return floor_p;
    }
    const int top = g_field.top_plate(x, z);
    if (g_flat_mode) {
        return top;   // nothing is ever carved out of it
    }
    int floor_p = top - SECTION_BELOW;
    const int dug = deepest_edit_near(floor_div(x, TILE), floor_div(z, TILE));
    if (dug != INT_MAX) {
        floor_p = std::min(floor_p, dug - 6);
    }
    const int placed = highest_edit_near(floor_div(x, TILE), floor_div(z, TILE));
    for (int yp = std::max(top, placed); yp > floor_p; --yp) {
        if (g_field.solid_at(x, yp, z) != MAT_AIR) {
            return yp;
        }
    }
    return floor_p;
}

int BrickTerrain::generated_plate(int x, int z) {
    if (biomes_on()) {
        // The biome world's own surface, not the classic field's: the shore
        // field asked this whether dug ground was sea, and with the classic
        // answer a pit dug below the sea line inland drew the sea in it.
        return biome_column(g_field.seed, x, z).sb * PLATES_PER_CELL + PLATES_PER_CELL - 1;
    }
    t_bare_field = true;
    const int top = g_field.top_plate(x, z);
    t_bare_field = false;
    return top;
}

int BrickTerrain::solid_at(int x, int yp, int z) { return g_field.solid_at(x, yp, z); }

int BrickTerrain::get_edit_count() { return (int)edit_count(); }

void BrickTerrain::clear_terrain_edits() { clear_edits(); }

void BrickTerrain::set_flat_mode(bool on) { g_flat_mode = on; }

void BrickTerrain::set_behind_faces(bool on) {
    g_behind_faces.store(on, std::memory_order_relaxed);
    brick::bump_field_version();
}

bool BrickTerrain::get_behind_faces() { return g_behind_faces.load(std::memory_order_relaxed); }

void BrickTerrain::set_behind_centre(Vector3i tile_plate) {
    g_behind_cx.store(tile_plate.x, std::memory_order_relaxed);
    g_behind_cy.store(tile_plate.y, std::memory_order_relaxed);
    g_behind_cz.store(tile_plate.z, std::memory_order_relaxed);
}

bool BrickTerrain::behind_wanted(int tx, int sy, int tz) {
    if (!behind_tile(tx, tz)) {
        return false;
    }
    if (sy == INT_MIN) {
        return true;
    }
    const int lo = sy * DEEP_SECTION_PLATES, hi = lo + DEEP_SECTION_PLATES;
    const int cy = g_behind_cy.load(std::memory_order_relaxed);
    return hi > cy - BEHIND_PLATES && lo < cy + BEHIND_PLATES;
}

void BrickTerrain::set_plate_steps(bool on) { g_plate_steps = on; }
bool BrickTerrain::get_plate_steps() { return g_plate_steps; }

void BrickTerrain::set_smooth_terrain(bool on) { g_smooth_terrain = on; }
bool BrickTerrain::get_smooth_terrain() { return g_smooth_terrain; }
void BrickTerrain::set_shelves(double bricks, double share) {
    g_shelf_bricks = (float)std::max(0.0, bricks);
    g_shelf_share = (float)std::clamp(share, 0.0, 0.9);
}
Vector2 BrickTerrain::get_shelves() { return Vector2(g_shelf_bricks, g_shelf_share); }
void BrickTerrain::set_curve_step(int studs) { g_curve_step = std::max(1, studs); }
int BrickTerrain::get_curve_step() { return g_curve_step; }
void BrickTerrain::set_smooth_slopes(bool on) { g_smooth_slopes = on; }
bool BrickTerrain::get_smooth_slopes() { return g_smooth_slopes; }
void BrickTerrain::set_curve_slope(double plates_per_stud) {
    g_curve_slope = (float)std::max(0.0, plates_per_stud);
}
double BrickTerrain::get_curve_slope() { return (double)g_curve_slope; }

double BrickTerrain::surface_raw(int x, int z) {
    // The half plate matches the mesher: the curve runs through the middle
    // of the staircase it replaces, not along its top.
    return ((double)g_field.raw_plate(x, z) + 0.5) * (double)PLATE_M;
}

void BrickTerrain::set_curve_bricks(double share) {
    g_curve_bricks = (float)std::max(0.0, std::min(1.0, share));
}
double BrickTerrain::get_curve_bricks() { return (double)g_curve_bricks; }

bool BrickTerrain::smooth_at(int x, int z) {
    if (!g_smooth_terrain) {
        return false;
    }
    const int t = g_field.top_plate(x, z);
    int qstep = 0;
    qstep = std::max(qstep, std::abs(g_field.top_plate(x - 1, z) - t));
    qstep = std::max(qstep, std::abs(g_field.top_plate(x + 1, z) - t));
    qstep = std::max(qstep, std::abs(g_field.top_plate(x, z - 1) - t));
    qstep = std::max(qstep, std::abs(g_field.top_plate(x, z + 1) - t));
    return smooth_column(g_field, x, z, qstep);
}

void BrickTerrain::set_overlay_chance(double c) {
    g_overlay_chance = (float)std::max(0.0, std::min(1.0, c));
}

double BrickTerrain::get_overlay_chance() { return (double)g_overlay_chance; }
bool BrickTerrain::get_flat_mode() { return g_flat_mode; }

Dictionary BrickTerrain::carve(Vector3 world_point, double radius_m) {
    Dictionary out;
    const double r = std::max(radius_m, (double)STUD_M * 0.5);
    const int cx = (int)std::floor(world_point.x / STUD_M);
    const int cy = (int)std::floor(world_point.y / PLATE_M);
    const int cz = (int)std::floor(world_point.z / STUD_M);
    const int rx = (int)std::ceil(r / STUD_M) + 1;
    const int ry = (int)std::ceil(r / PLATE_M) + 1;

    std::set<std::pair<int, int>> touched;
    PackedFloat32Array debris;
    int removed = 0;

    // A sphere in METRES, not in cells -- the grid is anisotropic (0.35 by
    // 0.14) and testing in cells would carve a lens.
    for (int z = cz - rx; z <= cz + rx; ++z) {
        for (int x = cx - rx; x <= cx + rx; ++x) {
            for (int y = cy - ry; y <= cy + ry; ++y) {
                const double wx = ((double)x + 0.5) * STUD_M - world_point.x;
                const double wy = ((double)y + 0.5) * PLATE_M - world_point.y;
                const double wz = ((double)z + 0.5) * STUD_M - world_point.z;
                if (wx * wx + wy * wy + wz * wz > r * r) {
                    continue;
                }
                const int mat = g_field.solid_at(x, y, z);
                // Bedrock is the floor of the world and does not break.
                if (mat == MAT_AIR || mat == MAT_BEDROCK) {
                    continue;
                }
                set_edit(x, y, z, MAT_AIR);
                ++removed;

                // Every cell within one stud of the tile edge dirties the
                // neighbour too: its mask reads across the boundary, so its
                // faces change even though none of its own cells did.
                for (int ddz = -1; ddz <= 1; ++ddz) {
                    for (int ddx = -1; ddx <= 1; ++ddx) {
                        touched.insert({ floor_div(x + ddx * MARGIN, TILE),
                                         floor_div(z + ddz * MARGIN, TILE) });
                    }
                }

                // Throw a piece for a thin shell of what was destroyed. The
                // whole volume would be thousands of bodies; the rim is what
                // anyone actually sees leave.
                const double d2 = wx * wx + wy * wy + wz * wz;
                if (d2 > (r * 0.62) * (r * 0.62) && hashf(x, y, z) < 0.10f) {
                    Color c = filament_colour(material_filament(mat));
                    const float t = piece_tint(g_field.seed, x, z);
                    debris.push_back(((float)x + 0.5f) * STUD_M);
                    debris.push_back(((float)y + 0.5f) * PLATE_M);
                    debris.push_back(((float)z + 0.5f) * STUD_M);
                    debris.push_back(STUD_M);
                    debris.push_back(PLATE_M * (float)PLATES_PER_CELL);
                    debris.push_back(STUD_M);
                    debris.push_back(c.r * t);
                    debris.push_back(c.g * t);
                    debris.push_back(c.b * t);
                }
            }
        }
    }

    PackedInt32Array tiles;
    for (const auto &t : touched) {
        tiles.push_back(t.first);
        tiles.push_back(t.second);
    }
    out["tiles"] = tiles;
    out["removed"] = removed;
    // The plate cells the sphere could have touched: the water reads its
    // ground again there (Docs/MineWater.md 4.3).
    out["box_lo"] = Vector3i(cx - rx, cy - ry, cz - rx);
    out["box_hi"] = Vector3i(cx + rx, cy + ry, cz + rx);
    out["debris"] = debris;
    out["edits"] = (int)edit_count();
    return out;
}

static inline int unpack21(int64_t v) {
    const int x = (int)(v & 0x1FFFFF);
    return (x & 0x100000) ? x - 0x200000 : x;
}

PackedByteArray BrickTerrain::get_edits() {
    PackedByteArray out;
    out.resize((int64_t)g_edits.size() * 13);
    uint8_t *w = out.ptrw();
    size_t i = 0;
    g_edits.each([&](uint64_t key, int32_t mat) {
        const int64_t k = (int64_t)key;
        const int32_t v[3] = { unpack21(k >> 42), unpack21(k >> 21), unpack21(k) };
        for (int a = 0; a < 3; ++a) {
            const uint32_t u = (uint32_t)v[a];
            w[i++] = (uint8_t)(u & 0xFF);
            w[i++] = (uint8_t)((u >> 8) & 0xFF);
            w[i++] = (uint8_t)((u >> 16) & 0xFF);
            w[i++] = (uint8_t)((u >> 24) & 0xFF);
        }
        w[i++] = (uint8_t)mat;
    });
    return out;
}

int BrickTerrain::set_edits(const PackedByteArray &bytes) {
    const int64_t n = bytes.size() / 13;
    const uint8_t *r = bytes.ptr();
    for (int64_t k = 0; k < n; ++k) {
        int32_t v[3];
        for (int a = 0; a < 3; ++a) {
            const uint8_t *p = r + k * 13 + a * 4;
            v[a] = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16)
                    | ((uint32_t)p[3] << 24));
        }
        const int m = clamp_material((int)r[k * 13 + 12]);
        set_edit(v[0], v[1], v[2], m);
    }
    return (int)n;
}

int BrickTerrain::mark_placed(Vector3i lo, Vector3i hi, int material) {
    const int x0 = std::min(lo.x, hi.x), x1 = std::max(lo.x, hi.x);
    const int z0 = std::min(lo.z, hi.z), z1 = std::max(lo.z, hi.z);
    const int c0 = floor_div(std::min(lo.y, hi.y), PLATES_PER_CELL);
    const int c1 = floor_div(std::max(lo.y, hi.y), PLATES_PER_CELL);
    const int sx = x1 - x0 + 1, sz = z1 - z0 + 1;
    // A block is a brick: a few studs, a course or so. Nothing bigger.
    if (sx > 15 || sz > 15 || c1 - c0 > 8) {
        return 0;
    }
    int n = 0;
    for (int cc = c0; cc <= c1; ++cc) {
        for (int z = z0; z <= z1; ++z) {
            for (int x = x0; x <= x1; ++x) {
                bool all = true;
                for (int p = 0; p < PLATES_PER_CELL && all; ++p) {
                    all = g_field.solid_at(x, cc * PLATES_PER_CELL + p, z) == material;
                }
                if (!all) {
                    continue;
                }
                g_placed.put((uint64_t)pack_cell(x, cc, z), placed_code(x - x0, z - z0, sx, sz));
                bump_tiles_near(x, z);
                ++n;
            }
        }
    }
    return n;
}

int BrickTerrain::get_region_studs() { return REGION_STUDS; }

PackedInt32Array BrickTerrain::take_dirty_regions() {
    PackedInt32Array out;
    for (auto &e : g_regions) {
        if (!e.second.dirty) {
            continue;
        }
        e.second.dirty = false;
        const int64_t k = e.first;
        const int rx = (int)((k >> 28) & 0xFFFFFFF), rz = (int)(k & 0xFFFFFFF);
        // 28-bit signed back to int.
        out.push_back((rx & 0x8000000) ? rx - 0x10000000 : rx);
        out.push_back((rz & 0x8000000) ? rz - 0x10000000 : rz);
    }
    return out;
}

PackedByteArray BrickTerrain::get_region_edits(int rx, int rz) {
    PackedByteArray out;
    auto it = g_regions.find(region_key(rx, rz));
    if (it == g_regions.end()) {
        return out;
    }
    const std::vector<uint64_t> &keys = it->second.keys;
    out.resize((int64_t)keys.size() * 13);
    uint8_t *w = out.ptrw();
    size_t i = 0;
    for (uint64_t key : keys) {
        int32_t mat = 0;
        g_edits.find(key, mat);
        const int64_t k = (int64_t)key;
        const int32_t v[3] = { unpack21(k >> 42), unpack21(k >> 21), unpack21(k) };
        for (int a = 0; a < 3; ++a) {
            const uint32_t u = (uint32_t)v[a];
            w[i++] = (uint8_t)(u & 0xFF);
            w[i++] = (uint8_t)((u >> 8) & 0xFF);
            w[i++] = (uint8_t)((u >> 16) & 0xFF);
            w[i++] = (uint8_t)((u >> 24) & 0xFF);
        }
        w[i++] = (uint8_t)mat;
    }
    return out;
}

PackedInt32Array BrickTerrain::get_placed() {
    PackedInt32Array out;
    g_placed.each([&](uint64_t key, int32_t v) {
        if (v == 0) {
            return;
        }
        const int64_t k = (int64_t)key;
        out.push_back(unpack21(k >> 42));
        out.push_back(unpack21(k >> 21));
        out.push_back(unpack21(k));
        out.push_back(v);
    });
    return out;
}

int BrickTerrain::set_placed(const PackedInt32Array &cells) {
    int n = 0;
    for (int64_t i = 0; i + 3 < cells.size(); i += 4) {
        g_placed.put((uint64_t)pack_cell(cells[i], cells[i + 1], cells[i + 2]), cells[i + 3]);
        ++n;
    }
    return n;
}

Dictionary BrickTerrain::fill_box(Vector3i lo, Vector3i hi, int material, bool only_air) {
    Dictionary out;
    const int mat = clamp_material(material);
    std::set<std::pair<int, int>> touched;
    int changed = 0;
    // A placed block is at most a few studs across; refuse anything huge.
    if ((int64_t)(hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1) > 200000) {
        out["tiles"] = PackedInt32Array();
        out["changed"] = 0;
        return out;
    }
    for (int z = lo.z; z <= hi.z; ++z) {
        for (int x = lo.x; x <= hi.x; ++x) {
            for (int y = lo.y; y <= hi.y; ++y) {
                const int was = g_field.solid_at(x, y, z);
                if (was == mat || was == MAT_BEDROCK) {
                    continue;
                }
                if (only_air && was != MAT_AIR) {
                    continue;
                }
                set_edit(x, y, z, mat);
                ++changed;
                for (int ddz = -1; ddz <= 1; ++ddz) {
                    for (int ddx = -1; ddx <= 1; ++ddx) {
                        touched.insert({ floor_div(x + ddx * MARGIN, TILE),
                                         floor_div(z + ddz * MARGIN, TILE) });
                    }
                }
            }
        }
    }
    PackedInt32Array tiles;
    for (const auto &t : touched) {
        tiles.push_back(t.first);
        tiles.push_back(t.second);
    }
    out["tiles"] = tiles;
    out["changed"] = changed;
    out["box_lo"] = lo;
    out["box_hi"] = hi;
    return out;
}

namespace {
Color piece_colour(const TileSample &s, int ox, int oz, int mat, bool studded);
}

Dictionary BrickTerrain::find_brick(Vector3 point, Vector3 normal) {
    Dictionary out;
    PackedInt32Array runs;
    PackedFloat32Array debris;
    out["runs"] = runs;
    out["debris"] = debris;
    const Vector3 n = normal.length_squared() > 1e-6 ? normal.normalized() : Vector3(0, 1, 0);
    // The cell just inside the face that was hit; a glancing hit lands on the
    // face itself, so step in a little further until it is solid.
    int x = 0, yp = 0, z = 0;
    bool found = false;
    for (int k = 1; k <= 6 && !found; ++k) {
        const Vector3 in = point - n * (real_t)(0.03 * k);
        x = (int)std::floor(in.x / STUD_M);
        yp = (int)std::floor(in.y / PLATE_M);
        z = (int)std::floor(in.z / STUD_M);
        const int m = g_field.solid_at(x, yp, z);
        found = m != MAT_AIR && m != MAT_BEDROCK;
    }
    if (!found) {
        return out;
    }
    const int tx = floor_div(x, TILE), tz = floor_div(z, TILE);
    const int lx = x - tx * TILE, lz = z - tz * TILE;
    TileSample s;
    const std::shared_ptr<const brick::TilePack> packed = brick::packed_tile(tx, tz, s);
    const std::vector<Piece> &pieces = packed->pieces;
    const std::vector<int32_t> &owner = packed->owner;

    const int col_top = s.tp[TileSample::idx(lx, lz)];
    const int course = floor_div(col_top, PLATES_PER_CELL) * PLATES_PER_CELL;
    const int32_t o = owner[(size_t)lx + TILE * lz];
    Color col = filament_colour(material_filament(g_field.solid_at(x, yp, z)));
    Vector3 lo_m, hi_m;
    if (o >= 0 && yp >= course) {
        // The top course: the whole piece -- the whole BRICK, where the
        // bond's top course laid one across a tile edge.
        const Piece &p = pieces[(size_t)o];
        col = piece_colour(s, p.ox, p.oz, p.mat, false);
        BondView view(s, true);
        piece_runs(s, p, view, runs);
        lo_m = Vector3((float)(tx * TILE + p.brick_x()) * STUD_M, (float)course * PLATE_M,
                (float)(tz * TILE + p.brick_z()) * STUD_M);
        hi_m = lo_m + Vector3((float)p.brick_sx() * STUD_M, (float)(col_top - course + 1) * PLATE_M,
                (float)p.brick_sz() * STUD_M);
    } else {
        // A wall, a cave face, the face of a pit: the whole brick of the
        // ground's bond (Docs/TerrainBond.md), the one the wall draws.
        const int c = floor_div(yp, PLATES_PER_CELL);
        BondView view(s, true);
        const BondRect r = view.rect(x, c, z);
        bond_runs(r, runs);
        const int b = r.c * PLATES_PER_CELL;
        lo_m = Vector3((float)r.x * STUD_M, (float)b * PLATE_M, (float)r.z * STUD_M);
        hi_m = lo_m + Vector3((float)r.sx * STUD_M, BRICK_M * (float)r.h, (float)r.sz * STUD_M);
    }
    const Vector3 c = (lo_m + hi_m) * 0.5f;
    const Vector3 size = hi_m - lo_m;
    const float d[9] = { c.x, c.y, c.z, size.x, size.y, size.z, col.r, col.g, col.b };
    for (float v : d) {
        debris.push_back(v);
    }
    out["runs"] = runs;
    out["debris"] = debris;
    return out;
}

namespace {
/// brick::packed_tile's tiles. Most recently used kept; past PACKS_MAX the
/// least used quarter goes. ~10-30 KB a tile.
struct PackStore {
    std::mutex lock;
    struct Entry {
        uint64_t version = 0;
        uint64_t used = 0;
        std::shared_ptr<const brick::TilePack> pack;
    };
    std::unordered_map<uint64_t, Entry> tiles;
    uint64_t clock = 0;
    int64_t hits = 0;
    int64_t packs = 0;
};
PackStore g_packs;
/// The mine world keeps ~240 tiles drawn; the rest is the survey's ring and
/// the far edits round them.
constexpr size_t PACKS_MAX = 768;
} // namespace

std::shared_ptr<const brick::TilePack> brick::packed_tile(int tx, int tz, TileSample &s) {
    // The version BEFORE sampling: an edit landing after it changes it, and
    // the pack is then not kept.
    const uint64_t ver = tile_version(tx, tz);
    sample_tile(g_field, tx, tz, s);
    const uint64_t k = (uint64_t)tile_key(tx, tz);
    {
        std::lock_guard<std::mutex> lk(g_packs.lock);
        auto it = g_packs.tiles.find(k);
        if (it != g_packs.tiles.end() && it->second.version == ver) {
            it->second.used = ++g_packs.clock;
            ++g_packs.hits;
            return it->second.pack;
        }
    }
    auto fresh = std::make_shared<TilePack>();
    pack_tile(g_field, s, fresh->pieces, fresh->owner);
    fresh->top.resize((size_t)TILE * TILE);
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            fresh->top[(size_t)lx + TILE * lz] = s.tp[TileSample::idx(lx, lz)];
        }
    }
    std::lock_guard<std::mutex> lk(g_packs.lock);
    ++g_packs.packs;
    if (tile_version(tx, tz) == ver) {
        if (g_packs.tiles.size() >= PACKS_MAX && g_packs.tiles.find(k) == g_packs.tiles.end()) {
            std::vector<uint64_t> used;
            used.reserve(g_packs.tiles.size());
            for (const auto &e : g_packs.tiles) {
                used.push_back(e.second.used);
            }
            const size_t q = used.size() / 4;
            std::nth_element(used.begin(), used.begin() + q, used.end());
            const uint64_t cut = used[q];
            for (auto it = g_packs.tiles.begin(); it != g_packs.tiles.end();) {
                it = it->second.used <= cut ? g_packs.tiles.erase(it) : std::next(it);
            }
        }
        g_packs.tiles[k] = PackStore::Entry{ ver, ++g_packs.clock, fresh };
    }
    return fresh;
}

std::shared_ptr<const brick::TilePack> brick::packed_tops(int tx, int tz, bool *packed) {
    if (packed) {
        *packed = false;
    }
    {
        const uint64_t ver = tile_version(tx, tz);
        const uint64_t k = (uint64_t)tile_key(tx, tz);
        std::lock_guard<std::mutex> lk(g_packs.lock);
        auto it = g_packs.tiles.find(k);
        if (it != g_packs.tiles.end() && it->second.version == ver) {
            it->second.used = ++g_packs.clock;
            ++g_packs.hits;
            return it->second.pack;
        }
    }
    if (packed) {
        *packed = true;
    }
    TileSample s;
    return packed_tile(tx, tz, s);
}

Dictionary BrickTerrain::get_tile_pack_stats(bool reset) {
    std::lock_guard<std::mutex> lk(g_packs.lock);
    Dictionary d;
    d["hits"] = g_packs.hits;
    d["packs"] = g_packs.packs;
    d["kept"] = (int64_t)g_packs.tiles.size();
    {
        std::lock_guard<std::mutex> glk(g_gen.lock);
        d["gen_hits"] = g_gen.hits;
        d["gen_made"] = g_gen.made;
        d["gen_kept"] = (int64_t)g_gen.tiles.size();
        if (reset) {
            g_gen.hits = 0;
            g_gen.made = 0;
        }
    }
    {
        std::lock_guard<std::mutex> glk(g_gen_sec.lock);
        d["gen_sec_hits"] = g_gen_sec.hits;
        d["gen_sec_made"] = g_gen_sec.made;
        if (reset) {
            g_gen_sec.hits = 0;
            g_gen_sec.made = 0;
        }
    }
    if (reset) {
        g_packs.hits = 0;
        g_packs.packs = 0;
    }
    return d;
}

void brick::top_columns(int tx, int tz, std::vector<TopColumn> &out, bool *was_packed) {
    const std::shared_ptr<const brick::TilePack> packed = brick::packed_tops(tx, tz, was_packed);
    const std::vector<Piece> &pieces = packed->pieces;
    const std::vector<int32_t> &owner = packed->owner;
    out.assign((size_t)TILE * TILE, TopColumn());
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            TopColumn &c = out[(size_t)lx + TILE * lz];
            c.top = packed->top[(size_t)lx + TILE * lz];
            const int32_t o = owner[(size_t)lx + TILE * lz];
            if (o >= 0) {
                const Piece &p = pieces[(size_t)o];
                c.piece = true;
                c.px = tx * TILE + p.brick_x();   // the whole brick: it may cross the tile edge
                c.pz = tz * TILE + p.brick_z();
                c.psx = p.brick_sx();
                c.psz = p.brick_sz();
            }
        }
    }
}

Dictionary BrickTerrain::find_bricks(Vector3i lo, Vector3i hi) {
    Dictionary out;
    PackedInt32Array runs;
    const int x0 = std::min(lo.x, hi.x), x1 = std::max(lo.x, hi.x);
    const int z0 = std::min(lo.z, hi.z), z1 = std::max(lo.z, hi.z);
    const int y0 = std::min(lo.y, hi.y), y1 = std::max(lo.y, hi.y);
    // A pickaxe's reach, not a crater: refuse anything huge.
    if ((int64_t)(x1 - x0 + 1) * (z1 - z0 + 1) > 4096 || y1 - y0 > 300) {
        out["runs"] = runs;
        return out;
    }
    // Bond bricks reach past the box and across tiles: each is taken once.
    std::set<int64_t> bond_taken;
    for (int tz = floor_div(z0, TILE); tz <= floor_div(z1, TILE); ++tz) {
        for (int tx = floor_div(x0, TILE); tx <= floor_div(x1, TILE); ++tx) {
            TileSample s;
            const std::shared_ptr<const brick::TilePack> packed = brick::packed_tile(tx, tz, s);
            const std::vector<Piece> &pieces = packed->pieces;
            const std::vector<int32_t> &owner = packed->owner;
            std::vector<uint8_t> taken(pieces.size(), 0);
            BondView view(s, true);
            const int ax0 = std::max(x0, tx * TILE), ax1 = std::min(x1, tx * TILE + TILE - 1);
            const int az0 = std::max(z0, tz * TILE), az1 = std::min(z1, tz * TILE + TILE - 1);
            for (int z = az0; z <= az1; ++z) {
                for (int x = ax0; x <= ax1; ++x) {
                    const int lx = x - tx * TILE, lz = z - tz * TILE;
                    const int col_top = s.tp[TileSample::idx(lx, lz)];
                    const int course = floor_div(col_top, PLATES_PER_CELL) * PLATES_PER_CELL;
                    const int32_t o = owner[(size_t)lx + TILE * lz];
                    int below_hi = y1;
                    if (o >= 0) {
                        below_hi = std::min(y1, course - 1);
                        // The top course in the box: its whole brick, once
                        // (a brick across a tile edge is two tiles' pieces).
                        if (y1 >= course && y0 <= col_top && !taken[(size_t)o]) {
                            taken[(size_t)o] = 1;
                            const Piece &p = pieces[(size_t)o];
                            const int64_t k = bond_key(tx * TILE + p.brick_x(),
                                    floor_div(col_top, PLATES_PER_CELL) + (1 << 20), tz * TILE + p.brick_z());
                            if (bond_taken.insert(k).second) {
                                piece_runs(s, p, view, runs);
                            }
                        }
                    }
                    // Under it (a wall, a cave face, the face of a pit): the
                    // bond's bricks (Docs/TerrainBond.md), each whole.
                    if (below_hi < y0) {
                        continue;
                    }
                    for (int b = floor_div(y0, PLATES_PER_CELL); b <= floor_div(below_hi, PLATES_PER_CELL); ++b) {
                        const BondRect r = view.rect(x, b, z);
                        if (bond_taken.insert(bond_key(r.x, r.c, r.z)).second) {
                            bond_runs(r, runs);
                        }
                    }
                }
            }
        }
    }
    out["runs"] = runs;
    return out;
}

Dictionary BrickTerrain::clear_runs(const PackedInt32Array &runs) {
    Dictionary out;
    std::set<std::pair<int, int>> touched;
    int removed = 0;
    Vector3i box_lo(INT_MAX, INT_MAX, INT_MAX), box_hi(INT_MIN, INT_MIN, INT_MIN);
    for (int64_t i = 0; i + 3 < runs.size(); i += 4) {
        const int x = runs[i], z = runs[i + 1], lo = runs[i + 2], hi = runs[i + 3];
        box_lo = Vector3i(std::min(box_lo.x, x), std::min(box_lo.y, lo), std::min(box_lo.z, z));
        box_hi = Vector3i(std::max(box_hi.x, x), std::max(box_hi.y, hi), std::max(box_hi.z, z));
        for (int y = lo; y <= hi; ++y) {
            const int m = g_field.solid_at(x, y, z);
            if (m == MAT_AIR || m == MAT_BEDROCK) {
                continue;
            }
            set_edit(x, y, z, MAT_AIR);
            ++removed;
        }
        for (int ddz = -1; ddz <= 1; ++ddz) {
            for (int ddx = -1; ddx <= 1; ++ddx) {
                touched.insert({ floor_div(x + ddx * MARGIN, TILE), floor_div(z + ddz * MARGIN, TILE) });
            }
        }
    }
    PackedInt32Array tiles;
    if (removed > 0) {
        for (const auto &t : touched) {
            tiles.push_back(t.first);
            tiles.push_back(t.second);
        }
    }
    out["tiles"] = tiles;
    out["removed"] = removed;
    if (removed > 0) {
        // The plate cells cleared: the water reads its ground again there
        // (Docs/MineWater.md 4.3).
        out["box_lo"] = box_lo;
        out["box_hi"] = box_hi;
    }
    return out;
}

Dictionary BrickTerrain::break_brick(Vector3 point, Vector3 normal) {
    Dictionary found = find_brick(point, normal);
    Dictionary out = clear_runs(found["runs"]);
    out["debris"] = (int)out["removed"] > 0 ? found["debris"] : Variant(PackedFloat32Array());
    return out;
}

Dictionary BrickTerrain::ray_cell(Vector3 from, Vector3 dir, double max_metres) {
    // Amanatides-Woo over the anisotropic grid: each axis has its own cell
    // size, so the step and the crossing distances are per axis.
    Dictionary out;
    if (dir.length_squared() < 1e-12) {
        return out;
    }
    const Vector3 d = dir.normalized();
    const double size[3] = { STUD_M, PLATE_M, STUD_M };
    const double o[3] = { from.x, from.y, from.z };
    const double v[3] = { d.x, d.y, d.z };
    int cell[3], step[3];
    double t_max[3], t_delta[3];
    for (int a = 0; a < 3; ++a) {
        cell[a] = (int)std::floor(o[a] / size[a]);
        if (v[a] > 0.0) {
            step[a] = 1;
            t_max[a] = (((double)cell[a] + 1.0) * size[a] - o[a]) / v[a];
            t_delta[a] = size[a] / v[a];
        } else if (v[a] < 0.0) {
            step[a] = -1;
            t_max[a] = ((double)cell[a] * size[a] - o[a]) / v[a];
            t_delta[a] = -size[a] / v[a];
        } else {
            step[a] = 0;
            t_max[a] = 1e30;
            t_delta[a] = 1e30;
        }
    }
    int entered = -1;
    double t = 0.0;
    for (int i = 0; i < 4000 && t <= max_metres; ++i) {
        const int m = g_field.solid_at(cell[0], cell[1], cell[2]);
        if (m != MAT_AIR && i > 0) {
            Vector3i n(0, 0, 0);
            if (entered == 0) n.x = -step[0];
            if (entered == 1) n.y = -step[1];
            if (entered == 2) n.z = -step[2];
            out["cell"] = Vector3i(cell[0], cell[1], cell[2]);
            out["normal"] = n;
            out["material"] = m;
            out["position"] = from + d * (real_t)t;
            return out;
        }
        int a = 0;
        if (t_max[1] < t_max[a]) a = 1;
        if (t_max[2] < t_max[a]) a = 2;
        t = t_max[a];
        t_max[a] += t_delta[a];
        cell[a] += step[a];
        entered = a;
    }
    return out;
}

int BrickTerrain::material_at(int x, int z) {
    const int yp = surface_plate(x, z);
    const int m = g_field.solid_at(x, yp, z);
    return m == MAT_AIR ? MAT_STONE : m;
}

bool BrickTerrain::is_plate(int x, int z) {
    const int h = height_at(x, z);
    return height_at(x - 1, z) == h && height_at(x + 1, z) == h &&
           height_at(x, z - 1) == h && height_at(x, z + 1) == h;
}

bool BrickTerrain::stud_at(int x, int z) {
    return is_plate(x, z) && material_studded(material_at(x, z));
}

int BrickTerrain::ramp_dir(int x, int z) {
    // Must agree with `sample_tile`, or the query says a cell ramps while the
    // mesher lays a tile there.
    if (!RAMPS_ENABLED) {
        return -1;
    }
    const int h = height_at(x, z);
    const int n[4] = {
        height_at(x - 1, z), height_at(x + 1, z),
        height_at(x, z - 1), height_at(x, z + 1)
    };
    int lower = -1;
    int count = 0;
    for (int k = 0; k < 4; ++k) {
        if (n[k] < h) { ++count; lower = k; }
    }
    return (count == 1 && n[lower] == h - 1) ? lower : -1;
}

int BrickTerrain::material_filament_index(int m) { return brick::material_filament(m); }
bool BrickTerrain::material_takes_studs(int m) { return brick::material_studded(m); }

int64_t BrickTerrain::hash3(int a, int b, int c) { return (int64_t)brick::hash3(a, b, c); }
double BrickTerrain::hashf(int a, int b, int c) { return (double)brick::hashf(a, b, c); }

bool BrickTerrain::cut_before(int u, int row_key, int axis) {
    return brick::cut_before(g_field.seed, u, row_key, axis);
}

PackedInt32Array BrickTerrain::pack_tile(int tx, int tz) {
    TileSample s;
    const std::shared_ptr<const brick::TilePack> packed = brick::packed_tile(tx, tz, s);
    const std::vector<Piece> &pieces = packed->pieces;
    const std::vector<int32_t> &owner = packed->owner;

    PackedInt32Array out;
    out.resize((int)pieces.size() * PIECE_STRIDE);
    int32_t *w = out.ptrw();
    for (size_t i = 0; i < pieces.size(); ++i) {
        const Piece &p = pieces[i];
        const size_t o = i * PIECE_STRIDE;
        w[o + 0] = p.ox;
        w[o + 1] = p.oz;
        w[o + 2] = p.sx;
        w[o + 3] = p.sz;
        w[o + 4] = p.h;
        w[o + 5] = p.mat;
        w[o + 6] = p.kind;
        w[o + 7] = p.ramp;
    }
    return out;
}

// --- tile build ------------------------------------------------------------

namespace {



/// Which axis a unit axis-aligned direction lies on. Used to decide, without
/// either face knowing about the other, which of two faces sharing an edge
/// draws the chamfer facet between them.
static inline int axis_of(const Vector3 &v) {
    const float ax = std::fabs(v.x), ay = std::fabs(v.y), az = std::fabs(v.z);
    if (ax >= ay && ax >= az) {
        return 0;
    }
    return (ay >= az) ? 1 : 2;
}

struct MeshBuf {
    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedColorArray colours;
    PackedVector2Array uvs;
    PackedVector2Array uv2s;
    PackedInt32Array indices;
    /// ARRAY_CUSTOM0, RGBA8: which terrain MATERIAL this surface is.
    ///
    /// Spec section 2 wants wood-fill, metal-fill, TPU and the rest to look
    /// different, and "different" is a surface response — roughness,
    /// specular, rim — not a colour. The colour is already in COLOR.rgb and
    /// carries no such information: two filaments can be the same grey and
    /// behave nothing alike.
    ///
    /// One byte a vertex, in the red channel, indexing a surface table in
    /// the shader (§18.3). The other three channels are spare — the print
    /// material proper (PLA, wood-fill, TPU) goes in one of them when the
    /// generator has an opinion about it.
    PackedByteArray custom0;
    /// What `quad`/`tri` stamp into custom0 for the vertices they emit.
    uint8_t material = 0;
    /// custom0.b: BOXED_FACE on a flat face with a brick of the overlay over
    /// it (Docs/BrickOverlay.md: the shader sinks it under the brick's box
    /// near the eye); 255 was the deleted geometry chamfer's facet
    /// (the top's print paths stop at the edge instead of running down it).
    uint8_t facet = 0;

    void push_custom(int n) {
        for (int i = 0; i < n; ++i) {
            custom0.push_back(material);
            custom0.push_back(0);
            custom0.push_back(facet);
            custom0.push_back(255);
        }
    }

    void raw_quad(const Vector3 &n, const Color &c, const Vector2 &face,
            const Vector3 &a, const Vector3 &b, const Vector3 &d, const Vector3 &e,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &ud, const Vector2 &ue) {
        const int base = verts.size();
        verts.push_back(a); verts.push_back(b); verts.push_back(d); verts.push_back(e);
        push_custom(4);
        for (int i = 0; i < 4; ++i) {
            normals.push_back(n);
            colours.push_back(c);
            uv2s.push_back(face);
        }
        uvs.push_back(ua); uvs.push_back(ub); uvs.push_back(ud); uvs.push_back(ue);
        indices.push_back(base); indices.push_back(base + 1); indices.push_back(base + 2);
        indices.push_back(base); indices.push_back(base + 2); indices.push_back(base + 3);
    }

    /// A quad with a normal PER VERTEX, so the GPU interpolates across it.
    /// Everything else in this buffer is a flat face of a brick and wants
    /// one normal for four corners; curved ground is the one thing that
    /// does not, and it is the only reason this exists.
    void quad_soft(const Color &c, const Vector2 &face,
            const Vector3 v[4], const Vector3 nrm[4], const Vector2 uv[4]) {
        const int base = verts.size();
        push_custom(4);
        for (int i = 0; i < 4; ++i) {
            verts.push_back(v[i]);
            normals.push_back(nrm[i]);
            colours.push_back(c);
            uv2s.push_back(face);
            uvs.push_back(uv[i]);
        }
        indices.push_back(base); indices.push_back(base + 1); indices.push_back(base + 2);
        indices.push_back(base); indices.push_back(base + 2); indices.push_back(base + 3);
    }

    /// A triangle whose winding is CORRECTED to face `n`, rather than
    /// trusted. Four hand-derived winding errors in this system is enough:
    /// the corner fans below have eight sign cases and deriving them by hand
    /// is how the last three happened.
    void tri_facing(const Vector3 &n, const Color &c, const Vector2 &face,
            const Vector3 &a, const Vector3 &b, const Vector3 &d,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &ud) {
        if ((b - a).cross(d - a).dot(n) > 0.0f) {
            tri(n, c, face, a, d, b, ua, ud, ub);
        } else {
            tri(n, c, face, a, b, d, ua, ub, ud);
        }
    }

    void tri(const Vector3 &n, const Color &c, const Vector2 &face,
            const Vector3 &a, const Vector3 &b, const Vector3 &d,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &ud) {
        const int base = verts.size();
        verts.push_back(a); verts.push_back(b); verts.push_back(d);
        push_custom(3);
        for (int i = 0; i < 3; ++i) {
            normals.push_back(n);
            colours.push_back(c);
            uv2s.push_back(face);
        }
        uvs.push_back(ua); uvs.push_back(ub); uvs.push_back(ud);
        indices.push_back(base); indices.push_back(base + 1); indices.push_back(base + 2);
    }

    /// A face quad. `convex`, `square` and `cut_corner` were the old
    /// geometry chamfer's (deleted 2026-11-24); kept in the signature so the
    /// callers' edge flags still compile, ignored.
    void quad(const Vector3 &n, const Color &c, const Vector2 &face,
            const Vector3 &a, const Vector3 &b, const Vector3 &d, const Vector3 &e,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &ud, const Vector2 &ue,
            uint8_t convex = 0, uint8_t square = 0, uint8_t cut_corner = 0) {
        (void)convex;
        (void)square;
        (void)cut_corner;
        raw_quad(n, c, face, a, b, d, e, ua, ub, ud, ue);
    }
};

/// How far a brick is pulled back from its neighbour, per side. Two of these
/// meet as a 16 mm groove, which is the visible join between bricks.
constexpr float BRICK_GAP = 0.008f;

/// How far the backing sits below the surface. The groove between two bricks
/// shows this, so it is the groove's depth.
constexpr float BACKING_DROP = 0.030f;

/// A piece, as a brick standing on a backing.
///
/// This replaces six rounds of chamfered-FACE geometry, and the reason is
/// structural rather than a preference. A face chamfer needs every facet to
/// agree with the facet on the other side of the edge -- and the other side
/// might belong to the packer, to the greedy mask, or to nothing at all,
/// because the volume behind the surface is not meshed. Three systems, no
/// shared knowledge, and an agreement required at every edge. Each round
/// found a real bug in one of those contracts and the next round found the
/// next one.
///
/// Here NOTHING agrees with anything:
///
///   * the brick is a CLOSED box with every edge convex against air. It is
///     `PieceMeshes.chamfered_box` in C++, the one piece of chamfer geometry
///     that has never produced an artefact -- it is what the debris uses.
///   * it is pulled back by BRICK_GAP on any side with a neighbour, so the
///     join between two bricks is a real physical gap, not a negotiated V.
///   * behind it sits a BACKING quad. Every gap, and every mistake in the
///     gap, shows backing rather than daylight.
///
/// The property that matters: a wrong inset is now a cosmetic gap width. It
/// can no longer be a hole.
///
/// A side where the ground DROPS AWAY is not pulled back -- there is no
/// neighbouring brick to leave a gap against, and the brick's own face is
/// the cliff.
void piece_brick(MeshBuf &m, const Color &col, float x0, float y0, float z0,
        float x1, float y1, float z1) {
    const Vector2 fxz(x1 - x0, z1 - z0);
    const Vector2 fxy(x1 - x0, y1 - y0);
    const Vector2 fzy(z1 - z0, y1 - y0);
    const uint8_t ALL = 0xF;

    m.quad(Vector3(0, 1, 0), col, fxz,
        Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1),
        Vector2(0, 0), Vector2(fxz.x, 0), fxz, Vector2(0, fxz.y), ALL);
    m.quad(Vector3(0, -1, 0), col, fxz,
        Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0),
        Vector2(0, 0), Vector2(fxz.x, 0), fxz, Vector2(0, fxz.y), ALL);
    m.quad(Vector3(-1, 0, 0), col, fzy,
        Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1),
        Vector2(0, 0), Vector2(fzy.x, 0), fzy, Vector2(0, fzy.y), ALL);
    m.quad(Vector3(1, 0, 0), col, fzy,
        Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0),
        Vector2(0, 0), Vector2(fzy.x, 0), fzy, Vector2(0, fzy.y), ALL);
    m.quad(Vector3(0, 0, -1), col, fxy,
        Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0),
        Vector2(0, 0), Vector2(fxy.x, 0), fxy, Vector2(0, fxy.y), ALL);
    m.quad(Vector3(0, 0, 1), col, fxy,
        Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x1, y1, z1),
        Vector2(0, 0), Vector2(fxy.x, 0), fxy, Vector2(0, fxy.y), ALL);
}

/// COLOR.a carries "this piece takes studs" to the shader, which is what lets
/// the painted stud tier know where to draw with no second texture. A piece
/// never spans the plate/non-plate boundary -- the packer forces a cut there --
/// so one flag a piece is exact rather than an approximation.
Color piece_colour(const TileSample &s, int ox, int oz, int mat, bool studded) {
    const int painted = s.col[TileSample::idx(ox, oz)];
    Color c = filament_colour(painted != 0xFF ? painted : material_filament(mat));
    const float t = piece_tint(g_field.seed, s.tx * TILE + ox, s.tz * TILE + oz);
    return Color(c.r * t, c.g * t, c.b * t, studded ? 1.0f : 0.0f);
}

/// THE BRICK OVERLAY (Docs/BrickOverlay.md): every brick a bake draws a face
/// of, for real bevelled instances laid over the flat ground near the camera.
/// Keyed by the brick's corner and course; its plates the union of what the
/// faces found solid. Set by build_tile / build_section for their own call
/// (thread-local: bakes run on workers side by side).
/// CUSTOM0.b of a flat face an overlay brick covers (MeshBuf::facet).
constexpr uint8_t BOXED_FACE = 64;
/// How far such a face sinks near the eye (terrain.gdshader OVERLAY_RECESS).
constexpr float OVERLAY_RECESS_M = 0.013f;
/// CUSTOM0.b of a BEHIND face (Docs/BrickOverlay.md 6b): a face of the solid
/// behind the overlay's bricks -- the brick under a top brick, a wall's next
/// course in -- drawn now, inside the ground, so a shot brick's hole shows
/// real bricks the frame it is hit. The shader keeps it only within the
/// overlay's reach (and sunk like a boxed face); past it, it is collapsed.
constexpr uint8_t BEHIND_FACE = 96;
/// Set by build_tile / build_section for their behind pass: the cells of
/// every exposed brick (the sample's vox layout, 1 = part of a brick open
/// air touches). mask_faces then draws only faces of other solid cells
/// that touch one; sky_light_pass reads a behind vertex's light from the
/// far side of the brick in front of it.
static thread_local const std::vector<uint8_t> *t_behind = nullptr;
/// The bond view mask_faces takes for the behind pass (the main pass's).
static thread_local bool t_behind_tops = false;
/// The plates the behind pass looks at: the exposed bricks' and one past.
static thread_local int t_behind_lo = 0, t_behind_hi = 0;

struct OutBrick {
    int x0, z0, x1, z1;   ///< studs, absolute, [x0, x1)
    int p0, p1;           ///< plates, [p0, p1)
    uint8_t mat;
    Color col;
    bool studded;         ///< its top drew studs (any face noting it so)
    /// What of each face the bake drew (face f: +x -x +y -y +z -z): one
    /// bit a cell, in the face's own axes -- x faces (u z studs, v y
    /// plates), y faces (u x, v z studs), z faces (u x studs, v y plates) --
    /// bit (u - u base) + 8 (v - v base), u from the brick's corner, v from
    /// its z corner (y faces) or OutBrick::v_base (plates). Cells past 8 are
    /// not kept. 0: none drawn (a surface piece's side the packer draws),
    /// the face is taken whole.
    uint64_t drawn[6];
    /// The plate the plate faces' v counts from: two under the key's course.
    int v_base;
    /// Sky light (levels 0..15) at each face's 4 corners (corner c: bit 0
    /// the face's u max, bit 1 its v max), read as the flat mesh reads a
    /// vertex's -- half a cell out along the face's normal -- at the corners
    /// of what of the face is drawn: a brick through a wall has a face in
    /// the room and one outside, and corners of the whole brick lit the
    /// room's face with the outside's light. Block light (lava) a face.
    /// sky_light_pass fills them; with no sky light, the open air's 15.
    uint8_t sky[6][4];
    uint8_t blk[6];
};
static thread_local std::map<std::array<int, 3>, OutBrick> *t_bricks = nullptr;

static void note_brick(int x0, int z0, int sx, int sz, int p0, int p1, int mat, const Color &col,
        bool studded) {
    if (t_bricks == nullptr || sx <= 0 || sz <= 0 || p1 <= p0 || material_is_glass(mat)) {
        return;
    }
    const std::array<int, 3> k{ x0, z0, floor_div(p0, PLATES_PER_CELL) };
    auto it = t_bricks->find(k);
    if (it == t_bricks->end()) {
        OutBrick b{ x0, z0, x0 + sx, z0 + sz, p0, p1, (uint8_t)mat, col, studded, {}, 0, {}, {} };
        b.v_base = floor_div(p0, PLATES_PER_CELL) * PLATES_PER_CELL - 2;
        for (int f = 0; f < 6; ++f) {
            b.drawn[f] = 0;
            b.blk[f] = 0;
            for (int c = 0; c < 4; ++c) {
                b.sky[f][c] = 15;
            }
        }
        (*t_bricks)[k] = b;
    } else {
        it->second.p0 = std::min(it->second.p0, p0);
        it->second.p1 = std::max(it->second.p1, p1);
        it->second.studded = it->second.studded || studded;
    }
}

/// The face `f` of the brick at corner x0 z0, course of plate p0 (as
/// note_brick keyed it) drew [u0, u1) x [v0, v1) in that face's axes.
static void note_face(int x0, int z0, int p0, int f, int u0, int v0, int u1, int v1) {
    if (t_bricks == nullptr) {
        return;
    }
    auto it = t_bricks->find(std::array<int, 3>{ x0, z0, floor_div(p0, PLATES_PER_CELL) });
    if (it == t_bricks->end()) {
        return;
    }
    OutBrick &b = it->second;
    const int ax = f / 2;
    const int ub = ax == 0 ? b.z0 : b.x0;
    const int vb = ax == 1 ? b.z0 : b.v_base;
    for (int v = std::max(v0, vb); v < std::min(v1, vb + 8); ++v) {
        for (int u = std::max(u0, ub); u < std::min(u1, ub + 8); ++u) {
            b.drawn[f] |= 1ULL << ((u - ub) + 8 * (v - vb));
        }
    }
}

/// A face's index: +x 0, -x 1, +y 2, -y 3, +z 4, -z 5.
static inline int face_index(int dx, int dy, int dz) {
    return dx > 0 ? 0 : dx < 0 ? 1 : dy > 0 ? 2 : dy < 0 ? 3 : dz > 0 ? 4 : 5;
}

/// The noted bricks as floats, 17 a brick: min corner, max corner (metres,
/// absolute), material, colour r g b, 1 if its top drew studs (else 0), then
/// its light as whole numbers of 24 bits, 4 bits a level: sky words 0-3
/// (face f's corner c is level 4 f + c, six to a word, the first at bit 0),
/// the block word (face f at bit 4 f), and the drawn word: how much of face
/// f this bake drew (cells, at most 15; 0 none) -- a brick
/// across a tile edge is in two tiles' lists, each lit from what that tile
/// drew of it, and overlay_pick takes each face from the one that drew more.
/// OutBrick::sky for the order.
static PackedFloat32Array bricks_floats(const std::map<std::array<int, 3>, OutBrick> &m) {
    PackedFloat32Array out;
    out.resize((int64_t)m.size() * 17);
    float *w = out.ptrw();
    for (const auto &kv : m) {
        const OutBrick &b = kv.second;
        *w++ = (float)b.x0 * STUD_M;
        *w++ = (float)b.p0 * PLATE_M;
        *w++ = (float)b.z0 * STUD_M;
        *w++ = (float)b.x1 * STUD_M;
        *w++ = (float)b.p1 * PLATE_M;
        *w++ = (float)b.z1 * STUD_M;
        *w++ = (float)b.mat;
        *w++ = b.col.r;
        *w++ = b.col.g;
        *w++ = b.col.b;
        *w++ = b.studded ? 1.0f : 0.0f;
        int words[4] = { 0, 0, 0, 0 };
        int blk = 0;
        for (int f = 0; f < 6; ++f) {
            for (int c = 0; c < 4; ++c) {
                const int n = f * 4 + c;
                words[n / 6] |= (int)std::min<uint8_t>(b.sky[f][c], 15) << (4 * (n % 6));
            }
            blk |= (int)std::min<uint8_t>(b.blk[f], 15) << (4 * f);
        }
        for (int q = 0; q < 4; ++q) {
            *w++ = (float)words[q];
        }
        *w++ = (float)blk;
        int drawn = 0;
        for (int f = 0; f < 6; ++f) {
            int cells = 0;
            for (uint64_t m = b.drawn[f]; m != 0; m &= m - 1) {
                ++cells;
            }
            drawn |= std::min(cells, 15) << (4 * f);
        }
        *w++ = (float)drawn;
    }
    return out;
}

/// Every exposed face of the volumetric mask, greedy-merged, EXCEPT the top
/// faces the surface packer has already drawn.
///
/// This replaces the old height-comparison skirts, and it had to: a
/// heightfield could draw a terrace face by comparing two numbers, but a cave
/// roof, an overhang underside and the wall of a fresh crater are not
/// expressible that way at all. Walking the mask is the only thing that sees
/// them.
///
/// Greedy per direction, the standard voxel pass: sweep each slice, grow a
/// rectangle right while the face is exposed and the material matches, then
/// grow it down while the whole row matches. A flat terrace face comes out as
/// one quad, which is what the hand-written merge used to do and now happens
/// for all six directions instead of four.
/// WINDING, once, because getting it wrong is silent.
///
/// A face whose outward normal is N must be wound so that
/// (b - a) x (c - a) points along -N. That is not a convention anyone can
/// derive from first principles -- it is read off the one face that was
/// already known to render, the packer's top quad -- and every quad emitted
/// anywhere in this file has to obey it. `_check_winding` in the probe now
/// asserts it for every triangle of a tile.
void push_stud(PackedFloat32Array &buf, float px, float py, float pz, const Color &c, int mat = MAT_AIR);

void mask_faces(MeshBuf &m, const TileSample &s, const std::vector<int32_t> &owner,
        const std::vector<Piece> &pieces, uint32_t seed, PackedFloat32Array &studs, int &stud_count);

/// The plates of a sample where solid can meet open air: one under its
/// lowest open cell (the sky over it counts) to its highest solid one + 1.
/// Most of a sample is rock under that or air over it.
static void face_band(const TileSample &s, int &lo, int &hi) {
    int lo_open = INT_MAX, hi_solid = INT_MIN;
    const int ytop = s.y0 + s.ysize;
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            for (int yp = s.y0; yp < ytop && yp < lo_open; ++yp) {
                if (s.open[(size_t)s.vidx(lx, yp, lz)] != 0) {
                    lo_open = yp;
                    break;
                }
            }
            for (int yp = ytop - 1; yp >= s.y0 && yp > hi_solid; --yp) {
                if (s.vox[(size_t)s.vidx(lx, yp, lz)] != MAT_AIR) {
                    hi_solid = yp;
                    break;
                }
            }
        }
    }
    lo_open = std::min(lo_open, ytop);
    lo = lo_open - 1;
    hi = hi_solid + 1;
}

/// Every cell of every brick open air touches (a face of it drawn: the
/// overlay's bricks), in the sample's vox layout. A brick is its bond
/// rectangle (the `tops` view, as the main pass draws it) and the solid
/// plates of its course.
static void exposed_brick_cells(const TileSample &s, bool tops, std::vector<uint8_t> &out,
        int &ylo_out, int &yhi_out) {
    out.assign(s.vox.size(), 0);
    ylo_out = INT_MAX;
    yhi_out = INT_MIN;
    BondView view(s, tops);
    view.prefetch_open();
    const int gx0 = s.tx * TILE, gz0 = s.tz * TILE;
    const int ylo = s.y0, yhi = s.y0 + s.ysize;
    int band_lo = 0, band_hi = 0;
    face_band(s, band_lo, band_hi);
    const int scan_lo = std::max(ylo, band_lo), scan_hi = std::min(yhi, band_hi);
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            for (int yp = scan_lo; yp < scan_hi; ++yp) {
                const size_t i = (size_t)s.vidx(lx, yp, lz);
                if (out[i] != 0 || s.vox[i] == MAT_AIR) {
                    continue;
                }
                // Deep in the rock (all six neighbours solid, read straight
                // from vox) most cells are: no open air beside them.
                if (lx > -MARGIN && lz > -MARGIN && lx < TILE + MARGIN - 1 && lz < TILE + MARGIN - 1
                        && yp > ylo && yp < yhi - 1) {
                    const size_t sy = (size_t)SPAN, sz = (size_t)SPAN * (size_t)s.ysize;
                    if (s.vox[i - 1] != MAT_AIR && s.vox[i + 1] != MAT_AIR && s.vox[i - sy] != MAT_AIR
                            && s.vox[i + sy] != MAT_AIR && s.vox[i - sz] != MAT_AIR && s.vox[i + sz] != MAT_AIR) {
                        continue;
                    }
                }
                if (!(s.open_air(lx - 1, yp, lz) || s.open_air(lx + 1, yp, lz)
                            || s.open_air(lx, yp - 1, lz) || s.open_air(lx, yp + 1, lz)
                            || s.open_air(lx, yp, lz - 1) || s.open_air(lx, yp, lz + 1))) {
                    continue;
                }
                const int c = floor_div(yp, PLATES_PER_CELL);
                const BondRect r = view.rect(gx0 + lx, c, gz0 + lz);
                for (int z = r.z; z < r.z + r.sz; ++z) {
                    for (int x = r.x; x < r.x + r.sx; ++x) {
                        const int bx = x - gx0, bz = z - gz0;
                        if (bx < -MARGIN || bz < -MARGIN || bx >= TILE + MARGIN || bz >= TILE + MARGIN) {
                            continue;
                        }
                        for (int q = r.c * PLATES_PER_CELL; q < (r.c + r.h) * PLATES_PER_CELL; ++q) {
                            if (s.in_y(q) && s.solid(bx, q, bz)) {
                                out[(size_t)s.vidx(bx, q, bz)] = 1;
                                ylo_out = std::min(ylo_out, q);
                                yhi_out = std::max(yhi_out, q);
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Every BEHIND_FACE triangle moved out of `m` into mesh arrays of its own
/// (build_tile's "behind_mesh"): drawn by a node of its own with a short
/// visibility range, so a far tile's are not processed at all. Empty: none.
static Array split_behind(MeshBuf &m) {
    const int nv = m.verts.size();
    const uint8_t *cu = m.custom0.ptr();
    std::vector<uint8_t> which((size_t)nv, 0);
    bool any = false;
    for (int i = 0; i < nv; ++i) {
        which[(size_t)i] = cu[(size_t)i * 4 + 2] == BEHIND_FACE ? 1 : 0;
        any = any || which[(size_t)i] != 0;
    }
    if (!any) {
        return Array();
    }
    MeshBuf part[2];
    std::vector<int32_t> map((size_t)nv, -1);
    const Vector3 *v = m.verts.ptr();
    const Vector3 *nr = m.normals.ptr();
    const Color *co = m.colours.ptr();
    const Vector2 *uv = m.uvs.ptr();
    const Vector2 *uv2 = m.uv2s.ptr();
    for (int i = 0; i < nv; ++i) {
        MeshBuf &d = part[which[(size_t)i]];
        map[(size_t)i] = d.verts.size();
        d.verts.push_back(v[i]);
        d.normals.push_back(nr[i]);
        d.colours.push_back(co[i]);
        d.uvs.push_back(uv[i]);
        d.uv2s.push_back(uv2[i]);
        for (int k = 0; k < 4; ++k) {
            d.custom0.push_back(cu[(size_t)i * 4 + k]);
        }
    }
    const int ni = m.indices.size();
    const int32_t *ix = m.indices.ptr();
    for (int t = 0; t < ni; ++t) {
        part[which[(size_t)ix[t]]].indices.push_back(map[(size_t)ix[t]]);
    }
    m.verts = part[0].verts;
    m.normals = part[0].normals;
    m.colours = part[0].colours;
    m.uvs = part[0].uvs;
    m.uv2s = part[0].uv2s;
    m.indices = part[0].indices;
    m.custom0 = part[0].custom0;
    const MeshBuf &b = part[1];
    Array mesh;
    mesh.resize(Mesh::ARRAY_MAX);
    mesh[Mesh::ARRAY_VERTEX] = b.verts;
    mesh[Mesh::ARRAY_NORMAL] = b.normals;
    mesh[Mesh::ARRAY_COLOR] = b.colours;
    mesh[Mesh::ARRAY_TEX_UV] = b.uvs;
    mesh[Mesh::ARRAY_TEX_UV2] = b.uv2s;
    mesh[Mesh::ARRAY_INDEX] = b.indices;
    mesh[Mesh::ARRAY_CUSTOM0] = b.custom0;
    return mesh;
}

/// The behind pass (BEHIND_FACE): into `m`, after the main pass; `cells`
/// stays set (t_behind) for sky_light_pass, which the caller clears.
static thread_local double t_behind_cells_ms = 0.0, t_behind_mask_ms = 0.0;
static void behind_faces(MeshBuf &m, const TileSample &s, bool tops, std::vector<uint8_t> &cells) {
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
    int ylo = 0, yhi = 0;
    exposed_brick_cells(s, tops, cells, ylo, yhi);
    const uint64_t t1 = Time::get_singleton()->get_ticks_usec();
    t_behind_cells_ms = (double)(t1 - t0) / 1000.0;
    const std::vector<int32_t> owner((size_t)TILE * TILE, -1);
    const std::vector<Piece> pieces;
    PackedFloat32Array no_studs;
    int no_count = 0;
    auto *bricks = t_bricks;
    t_bricks = nullptr;   // nothing here is an overlay brick's face
    if (ylo > yhi) {
        t_behind_mask_ms = 0.0;
        return;
    }
    t_behind = &cells;
    t_behind_tops = tops;
    t_behind_lo = ylo - 1;
    t_behind_hi = yhi + 2;
    mask_faces(m, s, owner, pieces, g_field.seed, no_studs, no_count);
    t_bricks = bricks;
    t_behind_mask_ms = (double)(Time::get_singleton()->get_ticks_usec() - t1) / 1000.0;
}

void mask_faces(MeshBuf &m, const TileSample &s, const std::vector<int32_t> &owner,
        const std::vector<Piece> &pieces, uint32_t seed, PackedFloat32Array &studs, int &stud_count) {
    static const int DIRS[6][3] = {
        { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 }
    };

    // The plates this sample draws (a guard plate past a deep-tier boundary
    // is sampled for its faces but drawn by its owner).
    const int y0 = s.lo_owned();
    const int y1 = s.hi_owned();
    // THE PLATES WORTH SCANNING (Docs/MineWorld.md 21, item 4). A face is
    // where solid meets open air, and most of a sample is rock under every
    // open cell or sky over every solid one: scanning all of it in six
    // directions was 3.7 ms of a 7 ms bake. From one under the lowest open
    // cell to the highest solid one; the behind pass, where its exposed
    // bricks are. y0/y1 stay the sample's own plates (the edge tests below).
    int sy0 = y0, sy1 = y1;
    if (t_behind != nullptr) {
        sy0 = std::max(y0, t_behind_lo);
        sy1 = std::min(y1, t_behind_hi);
    } else {
        int lo = 0, hi = 0;
        face_band(s, lo, hi);
        sy0 = std::max(y0, lo);
        sy1 = std::min(y1, hi);
    }
    if (sy1 < sy0) {
        sy1 = sy0;
    }
    std::vector<uint8_t> face_buf;
    std::vector<int64_t> key_buf;

    // THE BOND (Docs/TerrainBond.md): a face is merged only within one
    // brick, so the seams drawn on a wall, a cave roof or a cave floor are
    // the edges of the bricks a shot or a pickaxe takes and the collapse
    // holds. They used to come from a random cut lattice that nothing else
    // knew about. Memoised per cell and course (a cell's three plates and up
    // to six faces ask the same).
    BondView view(s, t_behind != nullptr ? t_behind_tops : !pieces.empty());
    view.prefetch_open();
    std::vector<BondRect> rect_memo((size_t)TILE * TILE * view.c_n, BondRect{ 0, 0, 0, 0 });
    auto brick_rect = [&](int lx, int yp, int lz) -> BondRect {
        const int c = floor_div(yp, PLATES_PER_CELL);
        const int x = s.tx * TILE + lx, z = s.tz * TILE + lz;
        const bool memoed = lx >= 0 && lz >= 0 && lx < TILE && lz < TILE
                && c >= view.c_lo && c < view.c_lo + view.c_n;
        const size_t i = memoed
                ? (size_t)lx + TILE * ((size_t)lz + TILE * (size_t)(c - view.c_lo)) : 0;
        if (memoed && rect_memo[i].sx != 0) {
            return rect_memo[i];
        }
        const BondRect r = view.rect(x, c, z);
        if (memoed) {
            rect_memo[i] = r;
        }
        return r;
    };
    auto brick_key = [&](int lx, int yp, int lz) -> int64_t {
        // The brick's BOTTOM course: a tall brick's faces are one brick's,
        // no seam drawn between its courses.
        const BondRect r = brick_rect(lx, yp, lz);
        return bond_key(r.x, r.c, r.z);
    };

    // A cell's colour comes from its own material, jittered by the piece that
    // owns its column where there is one, so a crater wall and the ground
    // above it read as the same rock rather than as two materials.
    auto cell_colour = [&](int lx, int yp, int lz) {
        const int mat = s.voxel(lx, yp, lz);
        const bool inside = lx >= -MARGIN && lz >= -MARGIN && lx < TILE + MARGIN && lz < TILE + MARGIN;
        const int painted = inside ? s.col[TileSample::idx(lx, lz)] : 0xFF;
        Color c = filament_colour(painted != 0xFF ? painted : material_filament(mat));
        const float t = piece_tint(seed, s.tx * TILE + lx, s.tz * TILE + lz);
        return Color(c.r * t, c.g * t, c.b * t, 0.0f);
    };

    // Is this face the one the ramp's tilted quad already covers?
    //
    // ONLY the low side. The first version skipped every lateral face of the
    // wedge's brick, on the reasoning that a ramp has exactly one lower
    // neighbour so its other three sides face solid rock. That is true of the
    // GENERATED surface, where every column's top is brick-aligned -- and
    // false the moment anything is carved, because `ramp_dir` compares brick
    // heights (`h`) while the real surface is a plate (`tp`). Two columns can
    // share a brick and not share a top, and then the perpendicular face IS
    // exposed and skipping it punches the hole that showed up beside every
    // ramp.
    auto ramp_covers = [&](int lx, int yp, int lz, int dx, int dz) {
        if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN || lz >= TILE + MARGIN) {
            return false;
        }
        const int i = TileSample::idx(lx, lz);
        const uint8_t r = s.ramp[i];
        if (r == 255) {
            return false;
        }
        const int t = s.tp[i];
        if (yp > t || yp <= t - PLATES_PER_CELL) {
            return false;
        }
        // 0 = -X, 1 = +X, 2 = -Z, 3 = +Z
        const int rdx = (r == 0) ? -1 : ((r == 1) ? 1 : 0);
        const int rdz = (r == 2) ? -1 : ((r == 3) ? 1 : 0);
        return dx == rdx && dz == rdz;
    };

    // Is this cell inside the brick a solid piece occupies?
    auto in_piece_solid = [&](int lx, int yp, int lz) {
        if (lx < 0 || lz < 0 || lx >= TILE || lz >= TILE) {
            return false;
        }
        const int32_t o = owner[(size_t)lx + TILE * lz];
        if (o < 0 || pieces[o].kind == PIECE_RAMP) {
            return false;
        }
        const int t = pieces[o].top;
        // A steep slope reaches below its own brick, to the ground in front
        // of it, and draws every face of that column itself.
        const int depth = pieces[o].kind == PIECE_SLOPE
                ? std::max<int>(pieces[o].fall, PLATES_PER_CELL) : PLATES_PER_CELL;
        return yp <= t && yp > t - depth;
    };

    // Is this +Y face already drawn by a packed surface piece?
    auto top_is_packed = [&](int lx, int yp, int lz) {
        if (lx < 0 || lz < 0 || lx >= TILE || lz >= TILE) {
            return false;
        }
        const int32_t o = owner[(size_t)lx + TILE * lz];
        if (o < 0) {
            return false;
        }
        // The packer draws the top of the column's topmost solid PLATE.
        // Comparing against the brick top instead left the real top face
        // undrawn AND a packed quad floating above it.
        return yp == pieces[o].top;
    };

    // WHICH SIDES A PIECE DRAWS ITSELF (build_tile): a plain brick or tile only
    // where the ground beside it DROPS (its lo_* edges), an overlay's brick
    // none, a slope every face of its column. Everything else of a piece's
    // brick that air can see -- a side against a cave or an overhang under a
    // higher column, an overlay brick's sides, its underside -- is drawn here,
    // keyed by the piece. Skipping every face inside a piece left those
    // see-through (terrain_audit_probe, Docs/MineWorld.md 20).
    std::vector<uint8_t> sides_drawn(pieces.size(), 0);
    for (size_t i = 0; i < pieces.size(); ++i) {
        const Piece &p = pieces[i];
        if (p.kind == PIECE_SLOPE) {
            sides_drawn[i] = 0xF;
            continue;
        }
        if (p.kind == PIECE_RAMP || p.overlay != 0) {
            continue;
        }
        uint8_t f = 0;
        for (int k = 0; k < p.sx; ++k) {
            if (s.tp[TileSample::idx(p.ox + k, p.oz - 1)] < p.top) f |= 4u;
            if (s.tp[TileSample::idx(p.ox + k, p.oz + p.sz)] < p.top) f |= 8u;
        }
        for (int k = 0; k < p.sz; ++k) {
            if (s.tp[TileSample::idx(p.ox - 1, p.oz + k)] < p.top) f |= 1u;
            if (s.tp[TileSample::idx(p.ox + p.sx, p.oz + k)] < p.top) f |= 2u;
        }
        sides_drawn[i] = f;
    }
    auto side_bit = [](int dx, int dz) -> uint8_t {
        return dx < 0 ? 1u : (dx > 0 ? 2u : (dz < 0 ? 4u : 8u));
    };
    // A face keyed by a piece (bit 63) is part of that piece's brick: its
    // rectangle, absolute studs.
    auto piece_rect = [&](int64_t key) -> BondRect {
        const Piece &p = pieces[(size_t)(key & 0x7FFFFFFF)];
        return BondRect{ s.tx * TILE + p.brick_x(), s.tz * TILE + p.brick_z(),
            p.brick_sx(), p.brick_sz() };
    };

    for (int d = 0; d < 6; ++d) {
        const int dx = DIRS[d][0], dy = DIRS[d][1], dz = DIRS[d][2];

        // u and v are the two axes of the slice; w is the slice normal.
        // Sizes are in CELLS; the metre conversion happens at emit.
        const bool along_y = (dy != 0);
        const int u_count = along_y ? TILE : (dx != 0 ? TILE : TILE);
        (void)u_count;

        // Iterate slices along the normal axis.
        const int w_lo = (dx != 0) ? 0 : ((dy != 0) ? sy0 : 0);
        const int w_hi = (dx != 0) ? TILE : ((dy != 0) ? sy1 : TILE);

        for (int w = w_lo; w < w_hi; ++w) {
            // Mask of this slice: material where a face is exposed, 0 where not.
            const int su = TILE;
            const int sv = (dy != 0) ? TILE : (sy1 - sy0);
            // One buffer for every slice of every direction. Allocating per
            // slice was six directions times ~85 slices of churn a tile.
            face_buf.assign((size_t)su * sv, 0);
            key_buf.resize((size_t)su * sv);
            std::vector<uint8_t> &face = face_buf;
            std::vector<int64_t> &fkey = key_buf;

            for (int v = 0; v < sv; ++v) {
                for (int u = 0; u < su; ++u) {
                    int lx, yp, lz;
                    if (dx != 0) {        // slice at x = w, u along z, v along y
                        lx = w; lz = u; yp = sy0 + v;
                    } else if (dy != 0) { // slice at y = w, u along x, v along z
                        lx = u; lz = v; yp = w;
                    } else {              // slice at z = w, u along x, v along y
                        lx = u; lz = w; yp = sy0 + v;
                    }
                    if (!s.solid(lx, yp, lz)) {
                        continue;
                    }
                    if (t_behind != nullptr) {
                        // BEHIND: a face of a cell that is not an exposed
                        // brick's, toward one that is. Keyed by both bricks,
                        // so a quad faces one brick in front (its light).
                        const int nx = lx + dx, ny = yp + dy, nz = lz + dz;
                        if (!s.in_y(ny) || (*t_behind)[(size_t)s.vidx(lx, yp, lz)] != 0
                                || (*t_behind)[(size_t)s.vidx(nx, ny, nz)] == 0) {
                            continue;
                        }
                        face[(size_t)u + su * v] = (uint8_t)s.voxel(lx, yp, lz);
                        fkey[(size_t)u + su * v] = (brick_key(lx, yp, lz)
                                ^ (brick_key(nx, ny, nz) * (int64_t)0x9E3779B97F4A7C1LL)) & INT64_MAX;
                        continue;
                    }
                    if (s.solid(lx + dx, yp + dy, lz + dz)) {
                        continue;   // interior face, never drawn
                    }
                    if (!s.open_air(lx + dx, yp + dy, lz + dz)) {
                        continue;   // faces a sealed pocket; nobody can be there
                    }
                    if (dy > 0 && top_is_packed(lx, yp, lz)) {
                        continue;   // the surface packer owns this one
                    }
                    // A CURVED column's top and sides are the curve's
                    // (Terrain.md 18.8). Its exposed faces only ever face
                    // lower ground, and between two curves the shared
                    // corners already close it, while against lower brick
                    // the curve draws its own skirt. Drawn here as well,
                    // the voxel staircase under every curve stood through
                    // it -- the curve runs through the middle of each step,
                    // so the top half of every step's wall and its top
                    // showed: the ledges and "smooth tiles everywhere" on
                    // curved hills, since 18.5.
                    if (dy >= 0 && g_smooth_terrain && lx >= 0 && lz >= 0
                            && lx < TILE && lz < TILE
                            && s.smooth[TileSample::idx(lx, lz)]) {
                        continue;
                    }
                    if (in_piece_solid(lx, yp, lz)) {
                        // A piece draws its own top and, where the ground
                        // beside it drops, its own sides, so the seams on them
                        // are the same brick as its top (sides_drawn above).
                        // Every OTHER face of its brick is drawn here, keyed by
                        // the piece (bit 63, which no bond_key sets) so it
                        // outlines that brick too: its UNDERSIDE over open air
                        // -- a built roof or a carved slab one course thick was
                        // see-through from below (MineWorld.md 18) -- and a side
                        // the piece does not draw.
                        const int32_t o = owner[(size_t)lx + TILE * lz];
                        if (dy == 0 && (sides_drawn[(size_t)o] & side_bit(dx, dz)) != 0) {
                            continue;
                        }
                        if (dy >= 0 && pieces[(size_t)o].kind == PIECE_SLOPE) {
                            continue;
                        }
                        face[(size_t)u + su * v] = (uint8_t)s.voxel(lx, yp, lz);
                        fkey[(size_t)u + su * v] = INT64_MIN | (int64_t)o;
                        continue;
                    }
                    if (dy == 0 && ramp_covers(lx, yp, lz, dx, dz)) {
                        // The wedge replaces the flat wall on its low side --
                        // that rectangle standing exactly where the slope is
                        // was the square behind every angled piece.
                        continue;
                    }
                    face[(size_t)u + su * v] = (uint8_t)s.voxel(lx, yp, lz);
                    fkey[(size_t)u + su * v] = brick_key(lx, yp, lz);
                }
            }

            // Greedy rectangles over the slice.
            for (int v = 0; v < sv; ++v) {
                for (int u = 0; u < su;) {
                    const uint8_t mat = face[(size_t)u + su * v];
                    if (mat == 0) {
                        ++u;
                        continue;
                    }
                    // --- keep the merge brick-sized ------------------
                    //
                    // An unbounded greedy merge turned a three-metre cliff
                    // into ONE quad, and since UV2 carries the quad's size
                    // the seam shader drew one brick outline around the whole
                    // wall. So a merged face is one brick's: the same bond
                    // key all along it (a key is a brick of one course, so a
                    // wall reads as courses, and its joints are staggered by
                    // the bond itself, Docs/TerrainBond.md).
                    const int64_t key = fkey[(size_t)u + su * v];

                    int wdt = 1;
                    while (u + wdt < su && wdt < MAX_LEN
                            && face[(size_t)(u + wdt) + su * v] == mat
                            && fkey[(size_t)(u + wdt) + su * v] == key) {
                        ++wdt;
                    }
                    int hgt = 1;
                    while (v + hgt < sv) {
                        bool ok = true;
                        for (int k = 0; k < wdt; ++k) {
                            if (face[(size_t)(u + k) + su * (v + hgt)] != mat
                                    || fkey[(size_t)(u + k) + su * (v + hgt)] != key) {
                                ok = false;
                                break;
                            }
                        }
                        if (!ok) {
                            break;
                        }
                        ++hgt;
                    }
                    for (int b = 0; b < hgt; ++b) {
                        for (int a = 0; a < wdt; ++a) {
                            face[(size_t)(u + a) + su * (v + b)] = 0;
                        }
                    }

                    // Back to world space.
                    int lx, yp, lz;
                    if (dx != 0) {
                        lx = w; lz = u; yp = sy0 + v;
                    } else if (dy != 0) {
                        lx = u; lz = v; yp = w;
                    } else {
                        lx = u; lz = w; yp = sy0 + v;
                    }
                    Color col = cell_colour(lx, yp, lz);
                    // The brick this face is part of: a piece's (bit 63), or
                    // the bond's.
                    const bool of_piece = key < 0;
                    const BondRect br = of_piece ? piece_rect(key) : brick_rect(lx, yp, lz);
                    // STUDS ON THE TOPMOST BRICKS OF A CAVE (Docs/MineWorld.md
                    // 19), in the mine world's look (the bond's top course):
                    // a cave floor or ledge is a brick's top as much as the
                    // surface is, and drew none at all. More often studded
                    // than the surface, smooth otherwise, by the brick's corner
                    // and course, so every face of one brick agrees.
                    bool studded = false;
                    if (dy > 0 && g_bond_top && material_studded(mat) && t_behind == nullptr) {
                        const int c = floor_div(yp, PLATES_PER_CELL);
                        studded = hashf(br.x, br.z, (int32_t)(seed ^ 0xCA5EU) + c) < CAVE_STUD_CHANCE;
                    }
                    if (t_bricks != nullptr) {
                        // The brick's plates: a piece's course under its top,
                        // or the solid plates of this cell's course.
                        int bp0 = 0, bp1 = 0;
                        if (of_piece) {
                            const Piece &pp = pieces[(size_t)(key & 0x7FFFFFFF)];
                            bp0 = pp.top - (PLATES_PER_CELL - 1);
                            bp1 = pp.top + 1;
                        } else {
                            const int cb = br.c * PLATES_PER_CELL;
                            bp0 = INT_MAX;
                            bp1 = INT_MIN;
                            for (int q = cb; q < cb + br.h * PLATES_PER_CELL; ++q) {
                                if (s.solid(lx, q, lz)) {
                                    bp0 = std::min(bp0, q);
                                    bp1 = std::max(bp1, q + 1);
                                }
                            }
                        }
                        note_brick(br.x, br.z, br.sx, br.sz, bp0, bp1, mat, col, studded);
                        // What of the face this quad draws, in its axes.
                        const int ax = s.tx * TILE + lx, az = s.tz * TILE + lz;
                        if (dx != 0) {
                            note_face(br.x, br.z, bp0, face_index(dx, dy, dz), az, yp, az + wdt, yp + hgt);
                        } else if (dy != 0) {
                            note_face(br.x, br.z, bp0, face_index(dx, dy, dz), ax, az, ax + wdt, az + hgt);
                        } else {
                            note_face(br.x, br.z, bp0, face_index(dx, dy, dz), ax, yp, ax + wdt, yp + hgt);
                        }
                    }
                    if (studded) {
                        col.a = 1.0f;
                        for (int b = 0; b < hgt; ++b) {
                            for (int a = 0; a < wdt; ++a) {
                                push_stud(studs, ((float)(lx + a) + 0.5f) * STUD_M,
                                        (float)(yp + 1) * PLATE_M, ((float)(lz + b) + 0.5f) * STUD_M, col,
                                        s.voxel(lx + a, yp, lz + b));
                                ++stud_count;
                            }
                        }
                    }

                    const float X = (float)lx * STUD_M;
                    const float Z = (float)lz * STUD_M;
                    const float Y = (float)yp * PLATE_M;
                    const float WU = (dy != 0) ? (float)wdt * STUD_M
                            : ((dx != 0) ? (float)wdt * STUD_M : (float)wdt * STUD_M);
                    const float HV = (dy != 0) ? (float)hgt * STUD_M : (float)hgt * PLATE_M;

                    Vector3 a0, b0, c0, d0;
                    Vector2 fsz;
                    if (dx < 0) {
                        a0 = Vector3(X, Y, Z + WU); b0 = Vector3(X, Y, Z);
                        c0 = Vector3(X, Y + HV, Z); d0 = Vector3(X, Y + HV, Z + WU);
                        fsz = Vector2(WU, HV);
                    } else if (dx > 0) {
                        a0 = Vector3(X + STUD_M, Y, Z); b0 = Vector3(X + STUD_M, Y, Z + WU);
                        c0 = Vector3(X + STUD_M, Y + HV, Z + WU);
                        d0 = Vector3(X + STUD_M, Y + HV, Z);
                        fsz = Vector2(WU, HV);
                    } else if (dy < 0) {
                        // Wound the OTHER way round from the +Y face below.
                        // Both of these were back to front, so every cave
                        // roof and every overhang underside was backface
                        // culled and you saw sky through the ground.
                        a0 = Vector3(X, Y, Z); b0 = Vector3(X, Y, Z + HV);
                        c0 = Vector3(X + WU, Y, Z + HV); d0 = Vector3(X + WU, Y, Z);
                        fsz = Vector2(WU, HV);
                    } else if (dy > 0) {
                        const float YT = Y + PLATE_M;
                        a0 = Vector3(X, YT, Z); b0 = Vector3(X + WU, YT, Z);
                        c0 = Vector3(X + WU, YT, Z + HV); d0 = Vector3(X, YT, Z + HV);
                        fsz = Vector2(WU, HV);
                    } else if (dz < 0) {
                        a0 = Vector3(X, Y, Z); b0 = Vector3(X + WU, Y, Z);
                        c0 = Vector3(X + WU, Y + HV, Z); d0 = Vector3(X, Y + HV, Z);
                        fsz = Vector2(WU, HV);
                    } else {
                        a0 = Vector3(X + WU, Y, Z + STUD_M); b0 = Vector3(X, Y, Z + STUD_M);
                        c0 = Vector3(X, Y + HV, Z + STUD_M);
                        d0 = Vector3(X + WU, Y + HV, Z + STUD_M);
                        fsz = Vector2(WU, HV);
                    }
                    // Which of this quad's edges has a perpendicular face
                    // on it. The in-plane neighbour being AIR is exactly the
                    // condition for this cell to have an exposed lateral
                    // face there -- the face the chamfer has to meet.
                    //
                    // Corners were wound a0 -> b0 -> c0 -> d0, so edge 0 runs
                    // along U, 1 along V, 2 back along U, 3 back along V.
                    uint8_t convex = 0;
                    uint8_t square = 0;
                    // Square because the neighbour is solid and covered (not
                    // only because a piece is beside it): where a face
                    // reaches past its edge (the skirts below).
                    uint8_t covered = 0;
                    // Square only because this sample stops there (another
                    // tile or tier draws on, flat): the backing reaches past.
                    // Edges whose neighbour is past this sample's plates (a
                    // tile's floor, a section's top or bottom): the flat
                    // face must not reach past them (see `reach` below).
                    uint8_t past_y = 0;
                    {
                        // Unit steps along the slice's U and V axes.
                        const int ux = (dx != 0) ? 0 : 1;
                        const int uz = (dx != 0) ? 1 : 0;
                        const int vy = (dy != 0) ? 0 : 1;
                        const int vz = (dy != 0) ? 1 : 0;
                        // Two tests give all three states:
                        //   neighbour air                  -> convex
                        //   neighbour solid, ITS n-face air -> coplanar
                        //   neighbour solid and covered     -> square
                        // A solid piece beside butts square against this face;
                        // its own bottom is square too, so neither bevels the
                        // join.
                        //
                        // Along the WHOLE edge, every cell of it: one probe at
                        // its first cell gave a merged face one state where
                        // the cells along it differed, and a convex edge whose
                        // far half was really coplanar left a slit there. An
                        // edge whose cells disagree is SQUARE: the face then
                        // reaches its full extent and whatever meets it can
                        // only overlap it, never open a gap.
                        const int probe[4][3] = {
                            { 0, -vy, -vz },
                            { ux * wdt, 0, uz * wdt },
                            { 0, vy * hgt, vz * hgt },
                            { -ux, 0, -uz },
                        };
                        for (int k = 0; k < 4; ++k) {
                            const int nx2 = lx + probe[k][0];
                            const int ny2 = yp + probe[k][1];
                            const int nz2 = lz + probe[k][2];
                            if (ny2 < y0 || ny2 >= y1) {
                                past_y |= (uint8_t)(1u << k);
                            }
                            if (!s.solid(nx2, ny2, nz2)) {
                                convex |= (uint8_t)(1u << k);
                            } else if (s.solid(nx2 + dx, ny2 + dy, nz2 + dz)) {
                                square |= (uint8_t)(1u << k);
                                covered |= (uint8_t)(1u << k);
                            }
                        }
                        // The probes above are in slice order (0 V-, 1 U+,
                        // 2 V+, 3 U-); `quad` reads bit i as the edge from
                        // corner i to i+1, and not every face is wound
                        // a0 -> b0 along +U. The -X and +Z walls run a0 -> b0
                        // along -U, so their two upright edges swap; the -Y
                        // face runs a0 -> b0 along +V, so edge i is probe
                        // 3 - i. Read unswapped, a brick at a room's inside
                        // corner bevelled its corner edge (nothing meets it
                        // there) and squared its seam edge (half the groove
                        // gone): two slits to daylight up every inside
                        // corner, the bright dotted lines in a dark room
                        // (MineWorld.md 19, --gate=seams).
                        auto remap = [&](uint8_t m) -> uint8_t {
                            if (dy < 0) {
                                return (uint8_t)(((m >> 3) & 1u) | (((m >> 2) & 1u) << 1)
                                        | (((m >> 1) & 1u) << 2) | ((m & 1u) << 3));
                            }
                            if (dx < 0 || dz > 0) {
                                return (uint8_t)((m & 0x5u) | ((m & 0x2u) << 2) | ((m & 0x8u) >> 2));
                            }
                            return m;
                        };
                        convex = remap(convex);
                        square = remap(square);
                        covered = remap(covered);
                        past_y = remap(past_y);
                    }
                    // Each face overlaps its neighbours by FLAT_OVERLAP past every
                    // edge that is not an outside corner. Where one face's
                    // edge meets two faces' edges part way along (a 1x1
                    // brick beside a 1x2, a wall's corner against a roof's
                    // edge) the T-junction cracked to single pixels of
                    // whatever is behind: the white dots in a dark cave
                    // (MineWorld.md 19, --gate=seams' flat tier). Overlapped,
                    // there is no line left between them. No triangles added.
                    {
                        constexpr float FLAT_OVERLAP = 0.001f;
                        const Vector3 n((float)dx, (float)dy, (float)dz);
                        Vector3 *rim[4] = { &a0, &b0, &c0, &d0 };
                        const Vector3 centre = (a0 + b0 + c0 + d0) * 0.25f;
                        Vector3 grow[4];
                        for (int i = 0; i < 4; ++i) {
                            const Vector3 p = *rim[i];
                            const Vector3 q = *rim[(i + 1) % 4];
                            Vector3 o = n.cross(q - p).normalized();
                            if (o.dot((p + q) * 0.5f - centre) < 0.0f) {
                                o = -o;
                            }
                            // An INSIDE corner (the neighbour solid and covered:
                            // a floor's edge at a wall's foot) reaches the
                            // brick overlay's recess further, into the solid
                            // behind the face it meets, where nothing sees it:
                            // near the eye both faces sink 13 mm under their
                            // bricks (terrain.gdshader overlay_reach), and a
                            // floor ending at the wall's old plane stopped
                            // 13 mm short of the sunken wall -- a slit along
                            // every wall's foot (--gate=seams --deep --at-top),
                            // where the brick under the wall, buried, has no
                            // box to hide it.
                            // Not past the sample's own plates: the tier
                            // beyond draws that side (mine_world_probe: a
                            // tile draws nothing under its floor).
                            const float reach = FLAT_OVERLAP
                                    + ((covered & ~past_y & (1u << i)) ? OVERLAY_RECESS_M : 0.0f);
                            grow[i] = (convex & (1u << i)) ? Vector3() : o * reach;
                        }
                        for (int i = 0; i < 4; ++i) {
                            *rim[i] += grow[i] + grow[(i + 3) % 4];
                        }
                    }
                    // UV is this quad's place in its BRICK and UV2 the
                    // brick's face (Docs/TerrainBond.md): a brick across a
                    // tile edge is drawn by two tiles and still outlined
                    // once. `ua` is the brick-side coordinate of corner a0
                    // along the quad's U (a0 -> b0).
                    {
                        const int ax = s.tx * TILE + lx, az = s.tz * TILE + lz;
                        const int c = floor_div(yp, PLATES_PER_CELL);
                        // Up the brick's side from its foot: a piece's brick
                        // stands on the plate under its top course.
                        const int foot = of_piece
                                ? pieces[(size_t)(key & 0x7FFFFFFF)].top - (PLATES_PER_CELL - 1)
                                : c * PLATES_PER_CELL;
                        const float va_y = (float)(yp - foot) * PLATE_M;
                        float ua = 0.0f, va = 0.0f;
                        Vector2 bf;
                        if (dx != 0) {
                            ua = (float)(dx < 0 ? (br.z + br.sz) - (az + wdt) : az - br.z) * STUD_M;
                            va = va_y;
                            bf = Vector2((float)br.sz * STUD_M, BRICK_M);
                        } else if (dz != 0) {
                            ua = (float)(dz > 0 ? (br.x + br.sx) - (ax + wdt) : ax - br.x) * STUD_M;
                            va = va_y;
                            bf = Vector2((float)br.sx * STUD_M, BRICK_M);
                        } else {
                            ua = (float)(ax - br.x) * STUD_M;   // along X
                            va = (float)(az - br.z) * STUD_M;   // along Z
                            bf = Vector2((float)br.sx * STUD_M, (float)br.sz * STUD_M);
                        }
                        // Every face here is a listed brick's (note_brick).
                        m.facet = t_behind != nullptr ? BEHIND_FACE : BOXED_FACE;
                        // GLASS says so in its material byte (terrain.gdshader
                        // TERRAIN_GLASS draws it see-through). Only glass: the
                        // rest of these faces keep the byte as it was.
                        const uint8_t mat_was = m.material;
                        if (material_is_glass(mat)) {
                            m.material = (uint8_t)MAT_GLASS;
                        }
                        if (dy < 0) {
                            // Wound a0 -> b0 along Z here: UV.x stays along X.
                            m.quad(Vector3((float)dx, (float)dy, (float)dz), col, bf,
                                a0, b0, c0, d0,
                                Vector2(ua, va), Vector2(ua, va + HV), Vector2(ua + WU, va + HV),
                                Vector2(ua + WU, va), convex, square);
                        } else {
                            m.quad(Vector3((float)dx, (float)dy, (float)dz), col, bf,
                                a0, b0, c0, d0,
                                Vector2(ua, va), Vector2(ua + fsz.x, va), Vector2(ua + fsz.x, va + fsz.y),
                                Vector2(ua, va + fsz.y), convex, square);
                        }
                        m.facet = 0;
                        m.material = mat_was;
                    }
                    u += wdt;
                }
            }
        }
    }
}

/// A box instance (a brick poking out of curved ground, §18.7): axis-aligned
/// on the stud grid, `sx` x `sy` x `sz` times the unit mesh.
void push_box_instance(PackedFloat32Array &buf, float px, float py, float pz,
        const Color &c, float sx, float sy, float sz) {
    buf.push_back(sx);   buf.push_back(0.0f); buf.push_back(0.0f); buf.push_back(px);
    buf.push_back(0.0f); buf.push_back(sy);   buf.push_back(0.0f); buf.push_back(py);
    buf.push_back(0.0f); buf.push_back(0.0f); buf.push_back(sz);   buf.push_back(pz);
    buf.push_back(c.r);  buf.push_back(c.g);  buf.push_back(c.b); buf.push_back(c.a);
}

void push_instance(PackedFloat32Array &buf, float px, float py, float pz,
        float yaw, const Color &c, float scale = 1.0f, float scale_y = -1.0f) {
    // XZ and Y scale separately. A single uniform scale made a 3-stud boulder
    // three times TALLER as well as wider -- 1.26 m of rock on ground whose
    // whole relief is 4 m. A wide rock is a wide rock, not a monolith.
    if (scale_y < 0.0f) {
        scale_y = scale;
    }
    const float cs = std::cos(yaw) * scale;
    const float sn = std::sin(yaw) * scale;
    // MultiMesh.set_buffer, TRANSFORM_3D with use_colors: three rows of four,
    // then rgba. Emitting it here means GDScript uploads a tile's studs with
    // one call and no per-instance loop.
    buf.push_back(cs);   buf.push_back(0.0f); buf.push_back(sn);  buf.push_back(px);
    buf.push_back(0.0f); buf.push_back(scale_y); buf.push_back(0.0f); buf.push_back(py);
    buf.push_back(-sn);  buf.push_back(0.0f); buf.push_back(cs);  buf.push_back(pz);
    buf.push_back(c.r);  buf.push_back(c.g);  buf.push_back(c.b); buf.push_back(c.a);
}

/// Floats a stud takes in the "studs" buffer: 16 (transform, colour), or 20
/// with the sky light on -- then four of custom data after the colour, the
/// cell's sky and block light (sky_light_pass fills them; full sky until it
/// does), so a stud in a cave is as dark as the floor it stands on
/// (TerrainTile's sky studs, printed_core INSTANCE_SKY; Docs/MineWorld.md 20).
int stud_stride() {
    return g_sky_light.load(std::memory_order_relaxed) ? 20 : 16;
}

/// A stud's alpha: the brick material printed.gdshader draws it as
/// (brick_grid.h BRICK_MATERIALS: 10 Wood, 13 Leaf; the low five bits of
/// 1 - alpha, grain along X). The ground's wood and leaves are drawn from
/// the PBR sets, their studs with them (Docs/PbrWood.md 8); the rest PLA.
static float stud_alpha(int mat) {
    const int bm = material_is_wood(mat) ? 10 : (material_is_leaves(mat) ? 13 : 0);
    return 1.0f - (float)bm / 255.0f;
}

void push_stud(PackedFloat32Array &buf, float px, float py, float pz, const Color &c, int mat) {
    Color k = c;
    k.a = stud_alpha(mat);
    push_instance(buf, px, py, pz, 0.0f, k);
    if (stud_stride() == 20) {
        buf.push_back(1.0f); buf.push_back(0.0f); buf.push_back(0.0f); buf.push_back(0.0f);
    }
}

} // namespace

static int g_coarse_smooth_step = 8;
void BrickTerrain::set_slope_pieces(bool on) { brick::g_slope_pieces = on; }
bool BrickTerrain::get_slope_pieces() { return brick::g_slope_pieces; }
void BrickTerrain::set_bond_top(bool on) {
    brick::g_bond_top = on;
    brick::bump_field_version();
}
bool BrickTerrain::get_bond_top() { return brick::g_bond_top; }

/// How far every edge of a terrain LOD piece hangs down: the detail tiles'
/// outer skirt, a coarse block's edge walls and a smooth block's skirt. Deep
/// enough to cover the step between two levels on the steepest ground the
/// field makes over one coarse cell (Terrain.md 19.15).
constexpr float EDGE_SKIRT_M = 4.0f * BRICK_M;

/// A coarse block's edge skirt, scaled to its sample spacing (19.17): the
/// next ring out samples twice as far apart, and on a 45-degree hill two
/// samples that far apart differ by that much in height. 1.68 m fixed left
/// gaps at every blocky-to-smooth and smooth-to-smooth border on steep ground.
static inline float coarse_skirt_m(int step) {
    return std::max(EDGE_SKIRT_M, 2.0f * (float)step * STUD_M);
}
void BrickTerrain::set_coarse_smooth_step(int step) { g_coarse_smooth_step = std::max(step, 0); }
int BrickTerrain::get_coarse_smooth_step() { return g_coarse_smooth_step; }

void BrickTerrain::set_generator(int mode) {
    brick::gen_params();   // built here, on the main thread, not first by a worker
    brick::set_gen_mode(mode);
    brick::bump_field_version();
}
int BrickTerrain::get_generator() { return brick::gen_mode(); }
void BrickTerrain::set_gen_params(Dictionary params) {
    brick::gen_params_from_dict(params);
    brick::bump_field_version();
}
Dictionary BrickTerrain::get_gen_params() { return brick::gen_params_to_dict(); }
void BrickTerrain::reset_gen_params() {
    brick::reset_gen_params();
    brick::bump_field_version();
}
int BrickTerrain::biome_at(int x, int z) {
    return brick::biome_column(g_field.seed, x, z).biome;
}
PackedStringArray BrickTerrain::biome_names() { return brick::biome_names(); }
PackedByteArray BrickTerrain::gen_preview(int64_t seed, Dictionary params, int cx, int cz, int w,
        int h, int step, int mode) {
    return brick::gen_preview((uint32_t)(seed & 0xffffffff), params, cx, cz, w, h, step, mode);
}

/// A coarse block as a SMOOTH grid: one vertex a sample, heights at the
/// sample, a colour and a material a vertex. Neighbouring blocks sample the
/// same corners on their shared edge, so they meet exactly; a skirt round the
/// edge hides the join against a blocky neighbour, whose tops sit at the MAX
/// of a cell and so can stand above this edge.
static Dictionary build_coarse_smooth(int tx0, int tz0, int span, int step, uint64_t t0) {
    // SMOOTH FAR GROUND THAT READS AS BRICK (Terrain.md 19.20):
    //   * corner heights snapped to a brick COURSE, so gentle ground is flat
    //     shelves joined by short ramps -- terraces, not a rubber sheet;
    //   * each cell its OWN four vertices, so its colour and material are one
    //     flat patch with a hard edge, like a blocky cell, not blended blobs
    //     (same triangles; four vertices a cell instead of one). Neighbours
    //     read the same corner heights, so the surface has no cracks;
    //   * the shader lights each triangle flat, so a shelf is a brick top and a
    //     ramp is a step face.
    const int W = span * TILE;
    const int N = std::max(W / step, 1);
    const int gx0 = tx0 * TILE;
    const int gz0 = tz0 * TILE;
    const int V = N + 1;
    std::vector<float> hq((size_t)V * V);
    for (int cz = 0; cz <= N; ++cz) {
        for (int cx = 0; cx <= N; ++cx) {
            const float h = (float)(BrickTerrain::surface_plate(gx0 + cx * step, gz0 + cz * step) + 1) * PLATE_M;
            hq[(size_t)cx + (size_t)V * cz] = std::round(h / BRICK_M) * BRICK_M;
        }
    }
    auto H = [&](int cx, int cz) { return hq[(size_t)cx + (size_t)V * cz]; };
    const float cs = (float)step * STUD_M;
    MeshBuf m;
    const Vector2 no_seam(0.0f, 0.0f);
    std::vector<Color> ccol((size_t)N * N);
    std::vector<uint8_t> cmat((size_t)N * N);
    for (int cz = 0; cz < N; ++cz) {
        for (int cx = 0; cx < N; ++cx) {
            // The cell's own colour and material, from its middle.
            const int px = gx0 + cx * step + step / 2;
            const int pz = gz0 + cz * step + step / 2;
            const int mat = g_field.material_at(px, pz,
                    floor_div(BrickTerrain::surface_plate(px, pz), PLATES_PER_CELL));
            const int painted = layer_colour(px, pz);
            Color col = filament_colour(painted != 0xFF ? painted : material_filament(mat));
            if (!sun_reaches(px, pz)) {
                col = Color(col.r * SUN_SHADE, col.g * SUN_SHADE, col.b * SUN_SHADE, col.a);
            }
            col.a = 0.0f;   // takes no studs
            ccol[(size_t)cx + (size_t)N * cz] = col;
            cmat[(size_t)cx + (size_t)N * cz] = (uint8_t)mat;
            const float x0 = (float)cx * cs, x1 = x0 + cs;
            const float z0 = (float)cz * cs, z1 = z0 + cs;
            const Vector3 v[4] = {
                Vector3(x0, H(cx, cz), z0), Vector3(x1, H(cx + 1, cz), z0),
                Vector3(x1, H(cx + 1, cz + 1), z1), Vector3(x0, H(cx, cz + 1), z1),
            };
            // The cell's REAL slope as its vertex normal. The shader lights it
            // flat anyway, but shadow bias reads the vertex normal: "up" on a
            // steep ramp was shadow acne, a speckle along every seam (19.21).
            Vector3 cn = (v[2] - v[0]).cross(v[1] - v[3]);
            cn = cn.y < 0.0f ? -cn : cn;
            cn = cn.length_squared() > 1e-8f ? cn.normalized() : Vector3(0, 1, 0);
            const int base = m.verts.size();
            for (int k = 0; k < 4; ++k) {
                m.verts.push_back(v[k]);
                m.normals.push_back(cn);
                m.colours.push_back(col);
                m.uvs.push_back(Vector2(v[k].x, v[k].z));
                m.uv2s.push_back(no_seam);
                m.custom0.push_back((uint8_t)mat);
                m.custom0.push_back(255);   // G: smooth far ground
                m.custom0.push_back(0);
                m.custom0.push_back(255);
            }
            m.indices.push_back(base); m.indices.push_back(base + 1); m.indices.push_back(base + 2);
            m.indices.push_back(base); m.indices.push_back(base + 2); m.indices.push_back(base + 3);
        }
    }
    // The skirt round the block's edge, facing out of it (19.17/19.18).
    const float drop = coarse_skirt_m(step);
    auto skirt = [&](int ax, int az, int bx, int bz, int ccx, int ccz, const Vector3 &out) {
        const Vector3 pa((float)ax * cs, H(ax, az), (float)az * cs);
        const Vector3 pb((float)bx * cs, H(bx, bz), (float)bz * cs);
        const size_t c = (size_t)ccx + (size_t)N * ccz;
        m.material = cmat[c];
        m.raw_quad(out, ccol[c], no_seam,
            Vector3(pb.x, pb.y - drop, pb.z), Vector3(pa.x, pa.y - drop, pa.z), pa, pb,
            Vector2(0, drop), Vector2(cs, drop), Vector2(cs, 0), Vector2(0, 0));
        // raw_quad wrote CUSTOM0.g = 0: flag these as smooth far ground too.
        const int n = m.custom0.size();
        for (int k = 0; k < 4; ++k) {
            m.custom0.set(n - 16 + k * 4 + 1, 255);
        }
    };
    for (int k = 0; k < N; ++k) {
        skirt(k + 1, 0, k, 0, k, 0, Vector3(0, 0, -1));
        skirt(k, N, k + 1, N, k, N - 1, Vector3(0, 0, 1));
        skirt(0, k, 0, k + 1, 0, k, Vector3(-1, 0, 0));
        skirt(N, k + 1, N, k, N - 1, k, Vector3(1, 0, 0));
    }
    Array mesh;
    mesh.resize(Mesh::ARRAY_MAX);
    mesh[Mesh::ARRAY_VERTEX] = m.verts;
    mesh[Mesh::ARRAY_NORMAL] = m.normals;
    mesh[Mesh::ARRAY_COLOR] = m.colours;
    mesh[Mesh::ARRAY_TEX_UV] = m.uvs;
    mesh[Mesh::ARRAY_TEX_UV2] = m.uv2s;
    mesh[Mesh::ARRAY_INDEX] = m.indices;
    mesh[Mesh::ARRAY_CUSTOM0] = m.custom0;
    Dictionary out;
    out["mesh"] = mesh;
    out["triangle_count"] = m.indices.size() / 3;
    out["smooth"] = true;
    out["build_ms"] = (double)(Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    return out;
}

Dictionary BrickTerrain::build_coarse(int tx0, int tz0, int span, int step) {
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
    span = std::max(span, 1);
    step = std::max(step, 1);
    if (g_coarse_smooth_step > 0 && step >= g_coarse_smooth_step) {
        return build_coarse_smooth(tx0, tz0, span, step, t0);
    }

    const int W = span * TILE;          // studs across the block
    const int N = std::max(W / step, 1); // coarse cells across the block
    const int gx0 = tx0 * TILE;
    const int gz0 = tz0 * TILE;

    // Corner heights, one sample every `step` studs. Sampling the CORNERS
    // rather than the middle means two neighbouring blocks read the same
    // number on their shared edge and cannot disagree about where the
    // ground is.
    std::vector<float> corner((size_t)(N + 1) * (N + 1));
    for (int cz = 0; cz <= N; ++cz) {
        for (int cx = 0; cx <= N; ++cx) {
            const int gx = gx0 + cx * step;
            const int gz = gz0 + cz * step;
            corner[(size_t)cx + (size_t)(N + 1) * cz] =
                    (float)(surface_plate(gx, gz) + 1) * PLATE_M;
        }
    }

    // The MAX of a cell's four corners, not the mean. A coarse cell stands
    // in for up to step^2 columns and the tallest of them is what the
    // silhouette should follow; averaging sinks the mesh into the hills and
    // the near tier pokes through the join.
    std::vector<float> cell((size_t)N * N);
    for (int cz = 0; cz < N; ++cz) {
        for (int cx = 0; cx < N; ++cx) {
            const float a = corner[(size_t)cx + (size_t)(N + 1) * cz];
            const float b = corner[(size_t)(cx + 1) + (size_t)(N + 1) * cz];
            const float c = corner[(size_t)(cx + 1) + (size_t)(N + 1) * (cz + 1)];
            const float d = corner[(size_t)cx + (size_t)(N + 1) * (cz + 1)];
            // The MIN of the four corners, not the max (Terrain.md 19.15). A
            // coarse cell stands in for up to step^2 columns, and the max
            // put it ABOVE the detailed ground at every border -- a step up
            // into the far tier, with a slit of water or sky under it. At or
            // below, the nearer level's skirt covers the join from above.
            cell[(size_t)cx + (size_t)N * cz] = std::min(std::min(a, b), std::min(c, d));
        }
    }

    MeshBuf m;
    const float cs = (float)step * STUD_M;
    const Vector2 face(0.0f, 0.0f);   // no piece, so no seam and no perimeter

    // Each cell's colour and material first, so neighbours can be compared:
    // runs of cells that agree are drawn as ONE quad (Terrain.md 19.18).
    std::vector<Color> ccol((size_t)N * N);
    std::vector<uint8_t> cmat((size_t)N * N);
    for (int cz = 0; cz < N; ++cz) {
        for (int cx = 0; cx < N; ++cx) {
            const int px = gx0 + cx * step + step / 2;
            const int pz = gz0 + cz * step + step / 2;
            const int mat = g_field.material_at(px, pz,
                    floor_div(surface_plate(px, pz), PLATES_PER_CELL));
            const int painted_c = layer_colour(px, pz);
            Color col = filament_colour(painted_c != 0xFF ? painted_c : material_filament(mat));
            if (!sun_reaches(px, pz)) {
                col = Color(col.r * SUN_SHADE, col.g * SUN_SHADE, col.b * SUN_SHADE, col.a);
            }
            ccol[(size_t)cx + (size_t)N * cz] = col;
            cmat[(size_t)cx + (size_t)N * cz] = (uint8_t)mat;
        }
    }
    auto Y = [&](int cx, int cz) { return cell[(size_t)cx + (size_t)N * cz]; };
    auto same = [&](int a, int b) {
        return cell[a] == cell[b] && cmat[a] == cmat[b] && ccol[a] == ccol[b];
    };
    // The height a cell's side drops to: the neighbour, or at the block's
    // edge a skirt deep enough to meet the next level.
    auto drop_to = [&](int cx, int cz, int dx, int dz) {
        const int nx = cx + dx, nz = cz + dz;
        if (nx < 0 || nz < 0 || nx >= N || nz >= N) {
            return Y(cx, cz) - coarse_skirt_m(step);
        }
        return Y(nx, nz);
    };
    auto is_edge = [&](int cx, int cz, int dx, int dz) {
        const int nx = cx + dx, nz = cz + dz;
        return nx < 0 || nz < 0 || nx >= N || nz >= N;
    };

    // TOPS: runs along X.
    for (int cz = 0; cz < N; ++cz) {
        int cx = 0;
        while (cx < N) {
            const int a = cx + N * cz;
            int e = cx + 1;
            while (e < N && same(a, e + N * cz)) {
                ++e;
            }
            const float y = cell[a];
            const float x0 = (float)cx * cs, x1 = (float)e * cs;
            const float z0 = (float)cz * cs, z1 = z0 + cs;
            m.material = cmat[a];
            m.raw_quad(Vector3(0, 1, 0), ccol[a], face,
                Vector3(x0, y, z0), Vector3(x1, y, z0),
                Vector3(x1, y, z1), Vector3(x0, y, z1),
                Vector2(0, 0), Vector2(x1 - x0, 0), Vector2(x1 - x0, cs), Vector2(0, cs));
            cx = e;
        }
    }

    // WALLS, one direction at a time, merged along the wall's own length
    // while the cells agree and drop to the same height. A block-EDGE wall is
    // a skirt over the next level and lit like ground (19.16); it faces out
    // of the block, which is the only side it can be seen from (19.18).
    struct Dir { int dx, dz; Vector3 n; };
    const Dir dirs[4] = {
        { 0, -1, Vector3(0, 0, -1) }, { 0, 1, Vector3(0, 0, 1) },
        { -1, 0, Vector3(-1, 0, 0) }, { 1, 0, Vector3(1, 0, 0) },
    };
    for (const Dir &d : dirs) {
        const bool along_x = d.dz != 0;   // a Z-facing wall runs along X
        for (int row = 0; row < N; ++row) {
            int k = 0;
            while (k < N) {
                const int cx = along_x ? k : row;
                const int cz = along_x ? row : k;
                const int a = cx + N * cz;
                const float y = cell[a];
                const float ny = drop_to(cx, cz, d.dx, d.dz);
                if (ny >= y - 1e-4f) {
                    ++k;
                    continue;
                }
                const bool edge = is_edge(cx, cz, d.dx, d.dz);
                int e = k + 1;
                while (e < N) {
                    const int ex = along_x ? e : row;
                    const int ez = along_x ? row : e;
                    const int b = ex + N * ez;
                    if (!same(a, b) || drop_to(ex, ez, d.dx, d.dz) != ny
                            || is_edge(ex, ez, d.dx, d.dz) != edge) {
                        break;
                    }
                    ++e;
                }
                // The wall's two ends, wound to face along d.n.
                const float lo = (float)k * cs, hi = (float)e * cs;
                Vector3 pa, pb;
                if (d.dz == -1) {
                    const float z = (float)cz * cs;
                    pa = Vector3(lo, 0, z); pb = Vector3(hi, 0, z);
                } else if (d.dz == 1) {
                    const float z = (float)(cz + 1) * cs;
                    pa = Vector3(hi, 0, z); pb = Vector3(lo, 0, z);
                } else if (d.dx == -1) {
                    const float x = (float)cx * cs;
                    pa = Vector3(x, 0, hi); pb = Vector3(x, 0, lo);
                } else {
                    const float x = (float)(cx + 1) * cs;
                    pa = Vector3(x, 0, lo); pb = Vector3(x, 0, hi);
                }
                const float len = hi - lo;
                m.material = cmat[a];
                (void)edge;
                m.raw_quad(d.n, ccol[a], face,
                    Vector3(pa.x, ny, pa.z), Vector3(pb.x, ny, pb.z),
                    Vector3(pb.x, y, pb.z), Vector3(pa.x, y, pa.z),
                    Vector2(0, y - ny), Vector2(len, y - ny),
                    Vector2(len, 0), Vector2(0, 0));
                k = e;
            }
        }
    }
    // CUSTOM0.g = 128: blocky FAR ground. The shader lights it by the same
    // rules as smooth far ground (tops full, steps darkened alike), so at the
    // LOD 1 / LOD 2 border only the shape changes, not the shading (19.21).
    for (int k = 1; k < m.custom0.size(); k += 4) {
        m.custom0.set(k, 128);
    }

    Array mesh;
    if (!m.verts.is_empty()) {
        mesh.resize(Mesh::ARRAY_MAX);
        mesh[Mesh::ARRAY_VERTEX] = m.verts;
        mesh[Mesh::ARRAY_NORMAL] = m.normals;
        mesh[Mesh::ARRAY_COLOR] = m.colours;
        mesh[Mesh::ARRAY_TEX_UV] = m.uvs;
        mesh[Mesh::ARRAY_TEX_UV2] = m.uv2s;
        mesh[Mesh::ARRAY_INDEX] = m.indices;
        mesh[Mesh::ARRAY_CUSTOM0] = m.custom0;
    }
    Dictionary out;
    out["mesh"] = mesh;
    out["triangle_count"] = m.indices.size() / 3;
    out["build_ms"] = (double)(Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    return out;
}

/// A slope's front: one plate above the lower ground (the LEGO lip), or ON it
/// for a one-plate fall (a cheese slope).
static float slope_front_at(float top, int fall) {
    const float lower = top - (float)fall * PLATE_M;
    return fall >= 2 ? lower + PLATE_M : lower;
}

/// The surface of a column at a point inside it, (fx, fz) its fraction across
/// the stud: the slope profile where it is a slope column, else its top. Pure
/// in the field (19.24), so a tile can ask it of its neighbour's columns.
static float column_surface(const TileSample &s, int lx, int lz, float fx, float fz) {
    const int i = TileSample::idx(lx, lz);
    const float top = (float)(s.tp[i] + 1) * PLATE_M;
    if (s.sl_r.empty() || s.sl_r[i] == 255) {
        return top;
    }
    const int r = s.sl_r[i];
    const float u = r == 1 ? fx : (r == 0 ? 1.0f - fx : (r == 3 ? fz : 1.0f - fz));
    const int len = s.sl_len[i];
    const float sv = (float)(len - 1 - s.sl_d[i]) + std::clamp(u, 0.0f, 1.0f);
    return slope_profile(sv, len, top, slope_front_at(top, s.sl_fall[i]), s.sl_fall[i] < 2);
}

Dictionary BrickTerrain::ray_ground(const Vector3 &from, const Vector3 &dir, double max_metres) {
    Dictionary out;
    const Vector3 d = dir.normalized();
    auto ground = [](const Vector3 &p) {
        return (double)(surface_plate((int)std::floor(p.x / STUD_M), (int)std::floor(p.z / STUD_M)) + 1)
                * (double)PLATE_M;
    };
    const double step = 0.5;
    for (double t = 0.0; t < max_metres; t += step) {
        const Vector3 p = from + d * (real_t)(t + step);
        if ((double)p.y > ground(p)) {
            continue;
        }
        double lo = t, hi = t + step;
        for (int i = 0; i < 5; ++i) {
            const double mid = (lo + hi) * 0.5;
            if ((double)(from + d * (real_t)mid).y <= ground(from + d * (real_t)mid)) {
                hi = mid;
            } else {
                lo = mid;
            }
        }
        const Vector3 at = from + d * (real_t)hi;
        out["position"] = Vector3(at.x, (real_t)ground(at), at.z);
        return out;
    }
    return out;
}

PackedFloat32Array BrickTerrain::water_floor_tile(int tx, int tz) {
    TileSample s;
    sample_tile(g_field, tx, tz, s);
    PackedFloat32Array out;
    out.resize(TILE * TILE);
    float *w = out.ptrw();
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            w[lx + TILE * lz] = column_surface(s, lx, lz, 0.5f, 0.5f);
        }
    }
    return out;
}

/// The surface at a tile-local point in metres.
static float surface_point(const TileSample &s, float x, float z) {
    const float gx = x / STUD_M, gz = z / STUD_M;
    const int lx = (int)std::floor(gx), lz = (int)std::floor(gz);
    return column_surface(s, std::clamp(lx, -MARGIN, TILE + MARGIN - 1),
            std::clamp(lz, -MARGIN, TILE + MARGIN - 1), gx - (float)lx, gz - (float)lz);
}

/// A quad facing `want`, whatever order its corners came in.
static void quad_facing(MeshBuf &m, const Vector3 &want, const Color &col, const Vector2 &face,
        const Vector3 &a, const Vector3 &b, const Vector3 &d, const Vector3 &e,
        const Vector2 &ua, const Vector2 &ub, const Vector2 &ud, const Vector2 &ue) {
    // raw_quad's front face has its winding normal pointing AWAY from `n`.
    // Read from the DIAGONALS: a side wall that tapers to nothing at one end
    // has a degenerate first triangle, and reading that one flipped 312
    // triangles the wrong way (the probe's winding check).
    const Vector3 wn = (d - a).cross(e - b);
    if (wn.length_squared() < 1e-12f) {
        return;   // no area: nothing to draw
    }
    if (wn.dot(want) > 0.0f) {
        m.raw_quad(want, col, face, a, e, d, b, ua, ue, ud, ub);
    } else {
        m.raw_quad(want, col, face, a, b, d, e, ua, ub, ud, ue);
    }
}

/// One slope piece (19.22-19.24): its profiled top, its front lip where it
/// reaches the front, a back wall where the ground behind is lower, and each
/// side a wall down to lower ground or a CHEEK up to higher -- the filler that
/// plugs the gap between an angled top and its neighbour. Neighbours are read
/// from the pure column surface, so both sides of any edge agree. Every face
/// of a piece carries the piece's own UV frame, so its outline is drawn round
/// the whole piece, not round every segment.
static void emit_slope(MeshBuf &m, const TileSample &s, const Piece &p, const Color &col) {
    const int r = p.ramp;
    const int len = p.slope_len;
    const bool along_x = r < 2;
    const int width = along_x ? p.sz : p.sx;
    const int cnt = along_x ? p.sx : p.sz;
    const float s0 = (float)p.slope_s0, s1 = s0 + (float)cnt;
    const float top = (float)(p.top + 1) * PLATE_M;
    const float yf = slope_front_at(top, p.fall);
    const float yb = top - (float)std::max<int>(p.fall, PLATES_PER_CELL) * PLATE_M;
    const bool cheese = p.fall < 2;
    const float W = (float)width;
    // Profile station sv (0 = back of the whole slope) at local q across -> tile metres.
    auto P = [&](float sv, float q, float y) {
        const float k = sv - s0;   // cells from this piece's back edge
        float x, z;
        if (along_x) {
            x = r == 1 ? ((float)p.ox + k) * STUD_M : ((float)(p.ox + p.sx) - k) * STUD_M;
            z = ((float)p.oz + q) * STUD_M;
        } else {
            z = r == 3 ? ((float)p.oz + k) * STUD_M : ((float)(p.oz + p.sz) - k) * STUD_M;
            x = ((float)p.ox + q) * STUD_M;
        }
        return Vector3(x, y, z);
    };
    const Vector3 fall_n = along_x ? Vector3(r == 1 ? 1.0f : -1.0f, 0, 0)
                                   : Vector3(0, 0, r == 3 ? 1.0f : -1.0f);
    const Vector3 across_n = along_x ? Vector3(0, 0, 1) : Vector3(1, 0, 0);
    auto Y = [&](float sv) { return slope_profile(sv, len, top, yf, cheese); };
    // Stations: a curve bends, two a stud; a 1x2 breaks at one stud; a
    // straight face needs only its ends.
    std::vector<float> st;
    if (cheese || len <= 1) {
        st = { s0, s1 };
    } else if (len == 2) {
        st.push_back(s0);
        if (s0 < 1.0f && s1 > 1.0f) {
            st.push_back(1.0f);
        }
        st.push_back(s1);
    } else {
        for (float v = s0; v < s1 - 1e-4f; v += 0.5f) {
            st.push_back(v);
        }
        st.push_back(s1);
    }
    const float L = (float)cnt * STUD_M;
    const float H = top - yb;

    // TOP, in one UV frame: the seam outline goes round the piece.
    const Vector2 top_face(W * STUD_M, L);
    for (size_t k = 0; k + 1 < st.size(); ++k) {
        const float a0 = st[k], a1 = st[k + 1];
        const Vector3 a = P(a0, 0, Y(a0)), b = P(a0, W, Y(a0));
        const Vector3 d = P(a1, W, Y(a1)), e = P(a1, 0, Y(a1));
        Vector3 n = (d - a).cross(e - b);
        n = n.y < 0.0f ? -n : n;
        const float v0 = (a0 - s0) * STUD_M, v1 = (a1 - s0) * STUD_M;
        quad_facing(m, n.normalized(), col, top_face, a, b, d, e,
            Vector2(0, v0), Vector2(W * STUD_M, v0), Vector2(W * STUD_M, v1), Vector2(0, v1));
    }
    // FRONT lip, where the piece reaches the slope's front.
    if (p.slope_s0 + cnt == len) {
        const Vector2 f(W * STUD_M, yf - yb);
        quad_facing(m, fall_n, col, f,
            P(s1, 0, yb), P(s1, W, yb), P(s1, W, yf), P(s1, 0, yf),
            Vector2(0, f.y), Vector2(f.x, f.y), Vector2(f.x, 0), Vector2(0, 0));
    }
    // The ground just outside the piece at station sv, across q.
    auto outside = [&](float sv, float q) {
        const Vector3 w = P(sv, q, 0.0f);
        return surface_point(s, w.x, w.z);
    };
    // BACK wall, where the ground behind is lower.
    {
        const Vector2 f(W * STUD_M, H);
        for (int q = 0; q < width; ++q) {
            const float ny = outside(s0 - 0.02f, (float)q + 0.5f);
            const float yt = Y(s0);
            if (ny < yt - 1e-4f) {
                const float lo = std::max(ny, yb);
                quad_facing(m, -fall_n, col, f,
                    P(s0, (float)q, lo), P(s0, (float)q + 1, lo), P(s0, (float)q + 1, yt), P(s0, (float)q, yt),
                    Vector2((float)q * STUD_M, top - lo), Vector2((float)(q + 1) * STUD_M, top - lo),
                    Vector2((float)(q + 1) * STUD_M, top - yt), Vector2((float)q * STUD_M, top - yt));
            }
        }
    }
    // SIDES: wall or cheek against the neighbour's real surface, split where
    // the two cross, sampled at the same stations as the top.
    // Whole studs on a straight face, half studs on a curve: a neighbour is
    // straight between stud lines unless it is a curve too.
    const float side_step = (!cheese && len >= 3) ? 0.5f : 1.0f;
    std::vector<float> ss;
    for (float v = s0; v < s1 - 1e-4f; v += side_step) {
        ss.push_back(v);
    }
    ss.push_back(s1);
    const Vector2 side_face(L, H);
    for (int side = 0; side < 2; ++side) {
        const float q = side == 0 ? 0.0f : W;
        const float qo = side == 0 ? -0.02f : W + 0.02f;
        const Vector3 out_n = side == 0 ? -across_n : across_n;
        auto uv = [&](float sv, float y) { return Vector2((sv - s0) * STUD_M, top - y); };
        auto piece = [&](float a0, float a1, float y0, float y1, float n0, float n1) {
            if (n0 <= y0 + 1e-5f && n1 <= y1 + 1e-5f) {
                const float b0 = std::max(n0, yb), b1 = std::max(n1, yb);
                const float t0 = std::max(y0, b0), t1 = std::max(y1, b1);
                quad_facing(m, out_n, col, side_face,
                    P(a0, q, b0), P(a1, q, b1), P(a1, q, t1), P(a0, q, t0),
                    uv(a0, b0), uv(a1, b1), uv(a1, t1), uv(a0, t0));
            } else if (n0 >= y0 - 1e-5f && n1 >= y1 - 1e-5f) {
                const float h0 = std::min(n0, top), h1 = std::min(n1, top);
                const float l0 = std::min(y0, h0), l1 = std::min(y1, h1);
                quad_facing(m, -out_n, col, side_face,
                    P(a0, q, l0), P(a1, q, l1), P(a1, q, h1), P(a0, q, h0),
                    uv(a0, l0), uv(a1, l1), uv(a1, h1), uv(a0, h0));
            }
        };
        for (size_t k = 0; k + 1 < ss.size(); ++k) {
            const float a0 = ss[k], a1 = ss[k + 1];
            const float y0 = Y(a0), y1 = Y(a1);
            const float n0 = outside(a0 + 1e-3f, qo), n1 = outside(a1 - 1e-3f, qo);
            const float d0 = n0 - y0, d1 = n1 - y1;
            if ((d0 > 1e-5f && d1 < -1e-5f) || (d0 < -1e-5f && d1 > 1e-5f)) {
                const float t = d0 / (d0 - d1);
                const float am = a0 + (a1 - a0) * t;
                const float ym = y0 + (y1 - y0) * t;
                piece(a0, am, y0, ym, n0, ym);
                piece(am, a1, ym, y1, ym, n1);
            } else {
                piece(a0, a1, y0, y1, n0, n1);
            }
        }
    }
}

// --- cave colliders -------------------------------------------------------------
//
// (Docs/MineWorld.md 13.) Every solid plate cell this sample owns that touches
// OPEN air, or lies within a brick under a floor of it, merged greedily into
// boxes that may grow through any cell that is not open air. A surface tile
// leaves out what its column-top boxes cover; a deep `section` collides all it
// owns. Returns how many boxes it added.
static int add_cave_boxes(const TileSample &s, PackedFloat32Array &boxes, bool section,
        const std::vector<int16_t> *cov) {
    int cave_boxes = 0;
    const int lo = s.lo_owned();
    const int hi = s.hi_owned();
    const int ny = s.ysize;
    const int CS = TILE + 2;   // columns -1 .. TILE
    std::vector<uint8_t> col_open((size_t)CS * CS, 0);
    bool any = false;
    for (int lz = -1; lz <= TILE; ++lz) {
        for (int lx = -1; lx <= TILE; ++lx) {
            // From the guard plate under the owned ones to the one over them
            // (a deep-tier sample): a cave wholly in the next sample still has
            // its ceiling or floor here, and it went uncollided
            // (terrain_audit_probe).
            const int top = section ? std::min(hi, s.y0 + s.ysize - 1)
                    : std::min<int>(s.tp[TileSample::idx(lx, lz)], hi - 1);
            for (int yp = std::max(lo - 1, s.y0); yp <= top; ++yp) {
                if (s.open[s.vidx(lx, yp, lz)]) {
                    col_open[(size_t)(lx + 1) + CS * (lz + 1)] = 1;
                    any = true;
                    break;
                }
            }
        }
    }
    if (any) {
        // 0 = not wanted, 1 = wanted, 2 = in a box already.
        std::vector<uint8_t> want((size_t)TILE * ny * TILE, 0);
        auto widx = [&](int lx, int yp, int lz) -> size_t {
            return (size_t)lx + TILE * ((size_t)(yp - s.y0) + (size_t)ny * lz);
        };
        int ylo = INT_MAX, yhi = INT_MIN;
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                bool near_open = false;
                for (int dz = -1; dz <= 1 && !near_open; ++dz) {
                    for (int dx = -1; dx <= 1; ++dx) {
                        if (col_open[(size_t)(lx + dx + 1) + CS * (lz + dz + 1)]) {
                            near_open = true;
                            break;
                        }
                    }
                }
                if (!near_open) {
                    continue;
                }
                // The plates the column's top box covers, from its top down
                // (a section has none): build_tile says how many (`cov`).
                const int covered = cov != nullptr ? (*cov)[(size_t)lx + TILE * lz] : PLATES_PER_CELL;
                const int top = section ? hi - 1
                        : std::min<int>(s.tp[TileSample::idx(lx, lz)] - covered, hi - 1);
                for (int yp = lo; yp <= top; ++yp) {
                    if (s.vox[s.vidx(lx, yp, lz)] == MAT_AIR) {
                        continue;
                    }
                    bool w = s.open_air(lx + 1, yp, lz) || s.open_air(lx - 1, yp, lz)
                            || s.open_air(lx, yp, lz + 1) || s.open_air(lx, yp, lz - 1)
                            || s.open_air(lx, yp - 1, lz);
                    for (int k = 1; k <= PLATES_PER_CELL && !w; ++k) {
                        w = s.open_air(lx, yp + k, lz);
                    }
                    if (w) {
                        want[widx(lx, yp, lz)] = 1;
                        ylo = std::min(ylo, yp);
                        yhi = std::max(yhi, yp);
                    }
                }
            }
        }
        auto seed_cell = [&](int lx, int yp, int lz) -> bool {
            return want[widx(lx, yp, lz)] == 1;
        };
        auto free_cell = [&](int lx, int yp, int lz) -> bool {
            return !s.open[s.vidx(lx, yp, lz)];
        };
        for (int yp = ylo; yp <= yhi; ++yp) {
            for (int lz = 0; lz < TILE; ++lz) {
                for (int lx = 0; lx < TILE; ++lx) {
                    if (!seed_cell(lx, yp, lz)) {
                        continue;
                    }
                    int w = 1;
                    while (lx + w < TILE && free_cell(lx + w, yp, lz)) {
                        ++w;
                    }
                    int d = 1;
                    for (; lz + d < TILE; ++d) {
                        bool ok = true;
                        for (int k = 0; k < w && ok; ++k) {
                            ok = free_cell(lx + k, yp, lz + d);
                        }
                        if (!ok) {
                            break;
                        }
                    }
                    int h = 1;
                    for (; yp + h <= yhi; ++h) {
                        bool ok = true;
                        for (int kz = 0; kz < d && ok; ++kz) {
                            for (int kx = 0; kx < w && ok; ++kx) {
                                ok = free_cell(lx + kx, yp + h, lz + kz);
                            }
                        }
                        if (!ok) {
                            break;
                        }
                    }
                    for (int ky = 0; ky < h; ++ky) {
                        for (int kz = 0; kz < d; ++kz) {
                            for (int kx = 0; kx < w; ++kx) {
                                uint8_t &c = want[widx(lx + kx, yp + ky, lz + kz)];
                                if (c == 1) {
                                    c = 2;
                                }
                            }
                        }
                    }
                    boxes.push_back(((float)lx + (float)w * 0.5f) * STUD_M);
                    boxes.push_back(((float)yp + (float)h * 0.5f) * PLATE_M);
                    boxes.push_back(((float)lz + (float)d * 0.5f) * STUD_M);
                    boxes.push_back((float)w * STUD_M);
                    boxes.push_back((float)h * PLATE_M);
                    boxes.push_back((float)d * STUD_M);
                    ++cave_boxes;
                }
            }
        }
    }
    return cave_boxes;
}

// --- the deep tier (Docs/MineWorld.md 16) ------------------------------------------

void BrickTerrain::set_deep_tier(bool on) { g_deep_tier = on; }
bool BrickTerrain::get_deep_tier() { return g_deep_tier; }
int BrickTerrain::get_deep_section_plates() { return DEEP_SECTION_PLATES; }
int BrickTerrain::get_bedrock_plate() { return biome_bedrock_plate(); }

static void span_columns(int tx, int tz, std::vector<BColumn> &bcols) {
    bcols.resize((size_t)SPAN * SPAN);
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            bcols[TileSample::idx(lx, lz)] = biome_column(g_field.seed, tx * TILE + lx, tz * TILE + lz);
        }
    }
}

int BrickTerrain::deep_top(int tx, int tz) {
    if (!biomes_on()) {
        return INT_MIN;
    }
    std::vector<BColumn> bcols;
    span_columns(tx, tz, bcols);
    return tile_floor_of(bcols);
}

/// Section (tx, sy, tz): the plates [sy, sy + 1) * DEEP_SECTION_PLATES of the
/// tile column, clipped to above the bedrock floor and below the surface
/// mask's floor; one guard plate sampled each side. False when it owns none.
static bool sample_section(int tx, int sy, int tz, TileSample &out) {
    out.tx = tx;
    out.tz = tz;
    if (!biomes_on()) {
        return false;
    }
    // The kept cells (see GenTile): the section's plates are the
    // generator's alone, so a kept one is always the whole of it.
    const uint32_t field = (uint32_t)(tile_version(tx, tz) >> 32);
    const uint64_t gkey = (uint64_t)tile_key(tx, tz) * 0x9E3779B97F4A7C15ULL ^ (uint64_t)(uint32_t)sy;
    std::shared_ptr<const GenTile> gen = gen_find(g_gen_sec, gkey, field);
    std::vector<BColumn> bcols;
    int top;
    if (gen) {
        top = gen->hi;
    } else {
        span_columns(tx, tz, bcols);
        top = tile_floor_of(bcols);
    }
    const int lo = std::max(sy * DEEP_SECTION_PLATES, biome_bedrock_plate());
    const int hi = std::min((sy + 1) * DEEP_SECTION_PLATES, top);
    if (lo >= hi) {
        return false;
    }
    out.own_lo = lo;
    out.own_hi = hi;
    out.y0 = lo - 1;
    out.ysize = hi - lo + 2;
    const bool no_edits = edits_empty();
    const int gx0 = tx * TILE, gz0 = tz * TILE;
    if (gen) {
        out.vox = gen->vox;
    } else {
        out.vox.assign((size_t)SPAN * out.ysize * SPAN, (uint8_t)MAT_AIR);
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                const int gx = gx0 + lx, gz = gz0 + lz;
                const BColumn &c = bcols[TileSample::idx(lx, lz)];
                int last_b = INT_MIN;
                uint8_t last_v = (uint8_t)MAT_AIR;
                for (int yp = out.y0; yp < out.y0 + out.ysize; ++yp) {
                    uint8_t v = (uint8_t)MAT_AIR;
                    if (yp <= c.bound_p) {
                        const int yb = floor_div(yp, PLATES_PER_CELL);
                        if (yb != last_b) {
                            last_b = yb;
                            last_v = (uint8_t)biome_cell(c, g_field.seed, gx, yb, gz);
                        }
                        v = last_v;
                    }
                    out.vox[out.vidx(lx, yp, lz)] = v;
                }
            }
        }
        auto made = std::make_shared<GenTile>();
        made->hi = top;
        made->gy0 = out.y0;
        made->gys = out.ysize;
        made->vox = out.vox;
        gen_keep(g_gen_sec, gkey, field, std::move(made));
    }
    if (!no_edits) {
        apply_edits(out);
    }
    // Open air: every side of a section is open to its neighbours,
    // conservatively (only a pocket entirely inside it is sealed).
    out.open.assign(out.vox.size(), 0);
    std::vector<int> stack;
    auto push = [&](int lx, int yp, int lz) {
        if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN || lz >= TILE + MARGIN
                || yp < out.y0 || yp >= out.y0 + out.ysize) {
            return;
        }
        const int i = out.vidx(lx, yp, lz);
        if (out.vox[i] != MAT_AIR || out.open[i]) {
            return;
        }
        out.open[i] = 1;
        stack.push_back(i);
    };
    for (int yp = out.y0; yp < out.y0 + out.ysize; ++yp) {
        const bool cap = yp == out.y0 || yp == out.y0 + out.ysize - 1;
        for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
            for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
                if (cap || lx == -MARGIN || lz == -MARGIN || lx == TILE + MARGIN - 1
                        || lz == TILE + MARGIN - 1) {
                    push(lx, yp, lz);
                }
            }
        }
    }
    while (!stack.empty()) {
        const int i = stack.back();
        stack.pop_back();
        const int a = i % SPAN;
        const int rest = i / SPAN;
        const int b = rest % out.ysize;
        const int cc = rest / out.ysize;
        const int lx = a - MARGIN, yp = b + out.y0, lz = cc - MARGIN;
        push(lx - 1, yp, lz);
        push(lx + 1, yp, lz);
        push(lx, yp - 1, lz);
        push(lx, yp + 1, lz);
        push(lx, yp, lz - 1);
        push(lx, yp, lz + 1);
    }
    // No surface: the column fields the face mesher reads say so.
    const size_t cols = (size_t)SPAN * SPAN;
    out.h.assign(cols, (int16_t)floor_div(out.y0 - 1, PLATES_PER_CELL));
    out.tp.assign(cols, (int16_t)(out.y0 - 1));
    out.gtp.assign(cols, (int16_t)(out.y0 - 1));
    out.mat.assign(cols, (uint8_t)MAT_STONE);
    out.col.assign(cols, 0xFF);
    out.plate.assign(cols, 0);
    out.ramp.assign(cols, 255);
    out.smooth.assign(cols, 0);
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            out.col[TileSample::idx(lx, lz)] = (uint8_t)layer_colour(gx0 + lx, gz0 + lz);
        }
    }
    return true;
}

// The region fit's cells (terrain_fit.cpp): the generator's, from the kept
// tiles and sections, never the edits.
bool brick::generated_cells(int tx, int tz, int y_lo, int y_hi, std::vector<uint8_t> &vox,
        std::vector<int16_t> &gtop, uint32_t *field_out, int lx0, int lx1, int lz0, int lz1) {
    lx0 = std::max(lx0, 0);
    lz0 = std::max(lz0, 0);
    lx1 = std::min(lx1, TILE);
    lz1 = std::min(lz1, TILE);
    if (!biomes_on() || y_hi <= y_lo) {
        return false;
    }
    const uint32_t field = (uint32_t)(tile_version(tx, tz) >> 32);
    if (field_out) {
        *field_out = field;
    }
    const uint64_t gkey = (uint64_t)tile_key(tx, tz);
    std::shared_ptr<const GenTile> gen = gen_find(g_gen, gkey, field);
    if (!gen) {
        TileSample tmp;
        sample_tile(g_field, tx, tz, tmp);
        gen = gen_find(g_gen, gkey, field);
        if (!gen) {
            return false;
        }
    }
    const int ny = y_hi - y_lo;
    // Only the columns asked for are written; the rest of `vox` is stale.
    vox.resize((size_t)TILE * TILE * ny);
    for (int yp = 0; yp < ny; ++yp) {
        for (int lz = lz0; lz < lz1; ++lz) {
            std::memset(&vox[(size_t)lx0 + TILE * ((size_t)lz + TILE * (size_t)yp)], MAT_AIR, (size_t)(lx1 - lx0));
        }
    }
    gtop.resize((size_t)TILE * TILE);
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            gtop[(size_t)lx + TILE * lz] = gen->top[TileSample::idx(lx, lz)];
        }
    }
    auto copy = [&](const GenTile &g, int lo, int hi) {
        lo = std::max(lo, y_lo);
        hi = std::min(hi, y_hi);
        for (int yp = lo; yp < hi; ++yp) {
            for (int lz = lz0; lz < lz1; ++lz) {
                const uint8_t *src = &g.vox[(size_t)(MARGIN + lx0) + SPAN * ((size_t)(yp - g.gy0) + (size_t)g.gys * (lz + MARGIN))];
                std::memcpy(&vox[(size_t)lx0 + TILE * ((size_t)lz + TILE * (size_t)(yp - y_lo))], src, (size_t)(lx1 - lx0));
            }
        }
    };
    copy(*gen, gen->gy0, gen->gy0 + gen->gys);
    if (y_lo < gen->gy0) {
        const int under_hi = std::min(y_hi, gen->gy0);
        // The deep sections' cells, deep tier or not: the fit is of what
        // the generator makes, whatever has been sampled or dug so far.
        {
            for (int yp = 0; yp < under_hi - y_lo; ++yp) {
                for (int lz = lz0; lz < lz1; ++lz) {
                    std::memset(&vox[(size_t)lx0 + TILE * ((size_t)lz + TILE * (size_t)yp)], 255, (size_t)(lx1 - lx0));
                }
            }
            for (int sy = floor_div(y_lo, DEEP_SECTION_PLATES); sy <= floor_div(under_hi - 1, DEEP_SECTION_PLATES); ++sy) {
                const uint64_t skey = (uint64_t)tile_key(tx, tz) * 0x9E3779B97F4A7C15ULL ^ (uint64_t)(uint32_t)sy;
                std::shared_ptr<const GenTile> sec = gen_find(g_gen_sec, skey, field);
                if (!sec) {
                    TileSample tmp;
                    if (!sample_section(tx, sy, tz, tmp)) {
                        continue;   // under the bedrock: no cells
                    }
                    sec = gen_find(g_gen_sec, skey, field);
                    if (!sec) {
                        continue;
                    }
                }
                // Its own plates (one guard plate sampled each side); the
                // surface tile's are the surface's.
                copy(*sec, sec->gy0 + 1, std::min(sec->gy0 + sec->gys - 1, gen->gy0));
            }
        }
    }
    return true;
}

// --- sky light in the cells (Docs/MineWorld.md 18) ----------------------------------

namespace {

/// Levels 15 (open sky) to 0: a step to a neighbour cell costs one.
constexpr int SKY_MAX = 15;
/// Cells past what a pass reads that its fill covers: light at a cell depends
/// only on cells within SKY_MAX steps, plus one for the eight-cell blend.
constexpr int SKY_PAD = SKY_MAX + 2;
/// Block light's full level in CUSTOM0.g: under 64 (0.25), where the shader
/// starts reading G as the far meshes' smooth-ground flag.
constexpr int BLOCK_BYTE = 60;

/// What a sky-light fill reads -- is a cell opaque, where does a column's sky
/// stop -- worked out on demand and kept, over a box of columns and courses.
/// A cell is one stud by one course (PLATES_PER_CELL plates); OPAQUE when all
/// its plates are solid.
struct SkyGrid {
    const TileSample *s = nullptr;
    /// `s` is a surface tile: its `tp` is each column's real top. A deep
    /// section's (or none) is not.
    bool surface = false;
    int x0 = 0, z0 = 0, c0 = 0;   ///< absolute cell of index 0
    int nx = 0, nz = 0, nc = 0;
    std::vector<uint8_t> state;   ///< 0 unknown, 1 open, 2 opaque
    std::vector<uint8_t> level;   ///< below the sky floor; the fill's result
    std::vector<uint8_t> block;   ///< block light (lava), once fill_block ran
    std::vector<int32_t> floors;  ///< per column: sky floor course, INT_MIN unknown
    std::vector<BColumn> cols;
    std::vector<uint8_t> col_done;
    bool biomes = false;
    bool any_edits = false;
    int64_t cells_filled = 0;
    int64_t block_filled = 0;

    void init(int p_x0, int p_z0, int p_c0, int p_nx, int p_nz, int p_nc) {
        x0 = p_x0; z0 = p_z0; c0 = p_c0;
        nx = p_nx; nz = p_nz; nc = p_nc;
        state.assign((size_t)nx * nz * nc, 0);
        level.assign((size_t)nx * nz * nc, 0);
        floors.assign((size_t)nx * nz, INT_MIN);
        biomes = biomes_on();
        if (biomes) {
            cols.resize((size_t)nx * nz);
            col_done.assign((size_t)nx * nz, 0);
        }
        any_edits = !edits_empty();
    }

    int c1() const { return c0 + nc - 1; }
    bool in_cols(int x, int z) const { return x >= x0 && z >= z0 && x < x0 + nx && z < z0 + nz; }
    bool in(int x, int c, int z) const { return in_cols(x, z) && c >= c0 && c < c0 + nc; }
    size_t ki(int x, int z) const { return (size_t)(x - x0) + (size_t)nx * (size_t)(z - z0); }
    size_t ci(int x, int c, int z) const { return ki(x, z) + (size_t)nx * nz * (size_t)(c - c0); }

    /// The biome generator's column, kept (in the box) or made.
    BColumn column(int x, int z) {
        if (!in_cols(x, z)) {
            return biome_column(g_field.seed, x, z);
        }
        const size_t k = ki(x, z);
        if (!col_done[k]) {
            cols[k] = biome_column(g_field.seed, x, z);
            col_done[k] = 1;
        }
        return cols[k];
    }

    bool sample_has(int x, int z, int &lx, int &lz) const {
        if (s == nullptr) {
            return false;
        }
        lx = x - s->tx * TILE;
        lz = z - s->tz * TILE;
        return lx >= -MARGIN && lz >= -MARGIN && lx < TILE + MARGIN && lz < TILE + MARGIN;
    }

    bool opaque_raw(int x, int c, int z) {
        const int yp0 = c * PLATES_PER_CELL;
        int lx, lz;
        // The tile's own sample where it reaches: the same field, already read.
        if (sample_has(x, z, lx, lz) && s->in_y(yp0) && s->in_y(yp0 + PLATES_PER_CELL - 1)) {
            for (int p = 0; p < PLATES_PER_CELL; ++p) {
                const uint8_t v = s->vox[s->vidx(lx, yp0 + p, lz)];
                if (v == MAT_AIR || material_is_glass(v)) {
                    return false;
                }
            }
            return true;
        }
        if (biomes) {
            // One generator cell a course (biome_cell is per brick); edits per plate.
            int base = -1;
            for (int p = 0; p < PLATES_PER_CELL; ++p) {
                if (any_edits) {
                    const int e = edit_at(pack_cell(x, yp0 + p, z));
                    if (e >= 0) {
                        if (e == MAT_AIR || material_is_glass(e)) {
                            return false;
                        }
                        continue;
                    }
                }
                if (base < 0) {
                    base = biome_cell(column(x, z), g_field.seed, x, c, z) != MAT_AIR ? 1 : 0;
                }
                if (base == 0) {
                    return false;
                }
            }
            return true;
        }
        for (int p = 0; p < PLATES_PER_CELL; ++p) {
            const int v = g_field.solid_at(x, yp0 + p, z);
            if (v == MAT_AIR || material_is_glass(v)) {
                return false;
            }
        }
        return true;
    }

    bool opaque(int x, int c, int z) {
        if (!in(x, c, z)) {
            return opaque_raw(x, c, z);
        }
        const size_t i = ci(x, c, z);
        if (state[i] == 0) {
            state[i] = opaque_raw(x, c, z) ? 2 : 1;
        }
        return state[i] == 2;
    }

    /// The column's sky floor: cells at and above it see the sky (level 15),
    /// down to the first opaque cell from the top. Any value past the box's
    /// top means "no sky in the box"; any at or below its bottom, "all sky".
    int floor_raw(int x, int z) {
        int top_c;
        int lx, lz;
        if (surface && sample_has(x, z, lx, lz)) {
            top_c = floor_div(s->tp[TileSample::idx(lx, lz)], PLATES_PER_CELL);
        } else if (!surface && biomes) {
            // Deep in the ground, the box's top is far under the surface: the
            // first opaque cell above the box settles it, and is nearly
            // always the one just above. Only a column open all the way up
            // needs the scan down from the box's top.
            const BColumn col = column(x, z);
            const int placed = highest_edit_near(floor_div(x, TILE), floor_div(z, TILE));
            const int lim = floor_div(std::max(col.bound_p, placed), PLATES_PER_CELL) + 1;
            for (int c = c1() + 1; c <= lim; ++c) {
                if (opaque_raw(x, c, z)) {
                    return c + 1;
                }
            }
            top_c = std::min(c1(), lim);
        } else {
            top_c = floor_div(BrickTerrain::surface_plate(x, z), PLATES_PER_CELL);
        }
        int c = top_c;
        while (c >= c0 && !opaque(x, c, z)) {
            --c;
        }
        return c + 1;
    }

    int sky_floor(int x, int z) {
        if (!in_cols(x, z)) {
            return floor_raw(x, z);
        }
        const size_t k = ki(x, z);
        if (floors[k] == INT_MIN) {
            floors[k] = floor_raw(x, z);
        }
        return floors[k];
    }

    bool sky(int x, int c, int z) { return c >= sky_floor(x, z); }

    /// A cell's level once filled: 15 at and above the sky floor, 0 opaque.
    int light(int x, int c, int z) {
        if (sky(x, c, z)) {
            return SKY_MAX;
        }
        if (!in(x, c, z)) {
            return 0;
        }
        return level[ci(x, c, z)];
    }

    /// The breadth-first fill, exact inside `lo..hi` (absolute cells,
    /// inclusive): seeds are the sky cells within SKY_MAX of the box that
    /// touch a cell below its column's sky floor, and no step is taken where
    /// the light left could not reach the box.
    void fill(const Vector3i &lo, const Vector3i &hi) {
        auto dist = [&](int x, int c, int z) {
            return std::max(0, lo.x - x) + std::max(0, x - hi.x) + std::max(0, lo.y - c)
                    + std::max(0, c - hi.y) + std::max(0, lo.z - z) + std::max(0, z - hi.z);
        };
        std::vector<uint32_t> bucket[SKY_MAX + 1];
        const int sx0 = std::max(x0, lo.x - SKY_MAX), sx1 = std::min(x0 + nx - 1, hi.x + SKY_MAX);
        const int sz0 = std::max(z0, lo.z - SKY_MAX), sz1 = std::min(z0 + nz - 1, hi.z + SKY_MAX);
        const int sc0 = std::max(c0, lo.y - SKY_MAX), sc1 = std::min(c1(), hi.y + SKY_MAX);
        static const int DX[4] = { -1, 1, 0, 0 }, DZ[4] = { 0, 0, -1, 1 };
        for (int z = sz0; z <= sz1; ++z) {
            for (int x = sx0; x <= sx1; ++x) {
                if (dist(x, std::clamp(lo.y, sc0, sc1), z) >= SKY_MAX) {
                    continue;   // too far sideways for any of it to arrive
                }
                const int f = sky_floor(x, z);
                // Its sky cells beside a neighbour's cells under that one's
                // floor; the bottom one also faces down onto opaque, nothing.
                int top = f;
                for (int k = 0; k < 4; ++k) {
                    top = std::max(top, sky_floor(x + DX[k], z + DZ[k]) - 1);
                }
                for (int c = std::max(f, sc0); c <= std::min(top, sc1); ++c) {
                    if (dist(x, c, z) < SKY_MAX) {
                        bucket[SKY_MAX].push_back((uint32_t)ci(x, c, z));
                    }
                }
            }
        }
        const size_t plane = (size_t)nx * nz;
        for (int L = SKY_MAX; L >= 2; --L) {
            const int nl = L - 1;
            for (size_t b = 0; b < bucket[L].size(); ++b) {
                const uint32_t i = bucket[L][b];
                const int c = c0 + (int)(i / plane);
                const size_t r = i % plane;
                const int z = z0 + (int)(r / (size_t)nx);
                const int x = x0 + (int)(r % (size_t)nx);
                if (L < SKY_MAX && level[i] != L) {
                    continue;   // raised since it was queued
                }
                static const int NX[6] = { -1, 1, 0, 0, 0, 0 };
                static const int NY[6] = { 0, 0, -1, 1, 0, 0 };
                static const int NZ[6] = { 0, 0, 0, 0, -1, 1 };
                for (int k = 0; k < 6; ++k) {
                    const int ax = x + NX[k], ac = c + NY[k], az = z + NZ[k];
                    if (!in(ax, ac, az) || dist(ax, ac, az) >= nl) {
                        continue;
                    }
                    const size_t j = ci(ax, ac, az);
                    if (level[j] >= nl || sky(ax, ac, az) || opaque(ax, ac, az)) {
                        continue;
                    }
                    level[j] = (uint8_t)nl;
                    bucket[nl].push_back((uint32_t)j);
                    ++cells_filled;
                }
            }
        }
    }

    /// BLOCK LIGHT from lava, exact inside `lo..hi` like fill(): every lava
    /// cell (x, course, z triples) within SKY_MAX of the box is a seed at 15,
    /// and light steps to the six neighbours one level less through cells
    /// that are not opaque -- sky cells included, which block light ignores.
    /// Returns the seeds used.
    int fill_block(const Vector3i &lo, const Vector3i &hi, const std::vector<int32_t> &lava) {
        auto dist = [&](int x, int c, int z) {
            return std::max(0, lo.x - x) + std::max(0, x - hi.x) + std::max(0, lo.y - c)
                    + std::max(0, c - hi.y) + std::max(0, lo.z - z) + std::max(0, z - hi.z);
        };
        block.assign(state.size(), 0);
        std::vector<uint32_t> bucket[SKY_MAX + 1];
        int seeds = 0;
        for (size_t k = 0; k + 2 < lava.size(); k += 3) {
            const int x = lava[k], c = lava[k + 1], z = lava[k + 2];
            if (!in(x, c, z) || dist(x, c, z) >= SKY_MAX || opaque(x, c, z)) {
                continue;
            }
            const size_t i = ci(x, c, z);
            if (block[i] == SKY_MAX) {
                continue;
            }
            block[i] = SKY_MAX;
            bucket[SKY_MAX].push_back((uint32_t)i);
            ++seeds;
        }
        const size_t plane = (size_t)nx * nz;
        static const int NX[6] = { -1, 1, 0, 0, 0, 0 };
        static const int NY[6] = { 0, 0, -1, 1, 0, 0 };
        static const int NZ[6] = { 0, 0, 0, 0, -1, 1 };
        for (int L = SKY_MAX; L >= 2; --L) {
            const int nl = L - 1;
            for (size_t b = 0; b < bucket[L].size(); ++b) {
                const uint32_t i = bucket[L][b];
                if (block[i] != L) {
                    continue;   // raised since it was queued
                }
                const int c = c0 + (int)(i / plane);
                const size_t r = i % plane;
                const int z = z0 + (int)(r / (size_t)nx);
                const int x = x0 + (int)(r % (size_t)nx);
                for (int k = 0; k < 6; ++k) {
                    const int ax = x + NX[k], ac = c + NY[k], az = z + NZ[k];
                    if (!in(ax, ac, az) || dist(ax, ac, az) >= nl) {
                        continue;
                    }
                    const size_t j = ci(ax, ac, az);
                    if (block[j] >= nl || opaque(ax, ac, az)) {
                        continue;
                    }
                    block[j] = (uint8_t)nl;
                    bucket[nl].push_back((uint32_t)j);
                    ++block_filled;
                }
            }
        }
        return seeds;
    }

    int block_light(int x, int c, int z) const {
        if (block.empty() || !in(x, c, z)) {
            return 0;
        }
        return block[ci(x, c, z)];
    }
};

} // namespace

/// Each vertex's sky light into CUSTOM0.a (Docs/MineWorld.md 18): the light
/// half a cell out along its normal, blended over the eight cell centres round
/// that point, opaque cells left out. Vertex positions are tile-local in X and
/// Z (the tile's origin is stud gx0, gz0), absolute in Y.
/// `studs` (stud_stride 20): each stud's custom data gets the light of the
/// cell it stands in, as a vertex facing up there would (Docs/MineWorld.md 20).
static void sky_light_pass(MeshBuf &m, const TileSample &s, bool surface, Dictionary &out,
        PackedFloat32Array *studs = nullptr) {
    if (!g_sky_light.load(std::memory_order_relaxed) || m.verts.is_empty()) {
        return;
    }
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
    const int n = m.verts.size();
    const Vector3 *v = m.verts.ptr();
    const Vector3 *nr = m.normals.ptr();
    const int gx0 = s.tx * TILE, gz0 = s.tz * TILE;
    float ymin = 1e30f, ymax = -1e30f;
    for (int i = 0; i < n; ++i) {
        ymin = std::min(ymin, v[i].y);
        ymax = std::max(ymax, v[i].y);
    }
    SkyGrid g;
    g.s = &s;
    g.surface = surface;
    const int cl = (int)std::floor(ymin / BRICK_M) - 1, ch = (int)std::floor(ymax / BRICK_M) + 1;
    g.init(gx0 - 1 - SKY_PAD, gz0 - 1 - SKY_PAD, cl - SKY_PAD, TILE + 2 + 2 * SKY_PAD,
            TILE + 2 + 2 * SKY_PAD, ch - cl + 1 + 2 * SKY_PAD);

    // A stud is a point facing up at its foot (12 floats of transform, its
    // origin at 3, 7, 11).
    const int SS = 20;
    const int ns = (studs != nullptr && stud_stride() == SS) ? studs->size() / SS : 0;
    auto stud_at = [&](int k) -> Vector3 {
        const float *b = studs->ptr() + (size_t)k * SS;
        return Vector3(b[3], b[7], b[11]);
    };
    const Vector3 UP(0.0f, 1.0f, 0.0f);
    // The overlay's bricks (Docs/BrickOverlay.md): each face's 4 corners --
    // of what of the face was drawn (the whole face if none was noted) --
    // read as a vertex there with the face's normal.
    std::vector<OutBrick *> obs;
    std::vector<Vector3> bpts;
    std::vector<Vector3> bnrm;
    // Each sample's brick (index into obs), face and corner.
    std::vector<std::array<int, 3>> bref;
    if (t_bricks != nullptr) {
        obs.reserve(t_bricks->size());
        bpts.reserve(t_bricks->size() * 24);
        bnrm.reserve(t_bricks->size() * 24);
        static const Vector3 NRM[6] = { Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
            Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1) };
        for (auto &kv : *t_bricks) {
            OutBrick &b = kv.second;
            obs.push_back(&b);
            for (int f = 0; f < 6; ++f) {
                // Only what the bake drew is ever seen: a face drawn by none
                // takes the brick's brightest drawn face's light (below).
                if (b.drawn[f] == 0) {
                    continue;
                }
                const int ax = f / 2;   // 0 x, 1 y, 2 z
                // The face's whole rect in its axes.
                int u0, v0, u1, v1;
                if (ax == 0) {
                    u0 = b.z0; u1 = b.z1; v0 = b.p0; v1 = b.p1;
                } else if (ax == 1) {
                    u0 = b.x0; u1 = b.x1; v0 = b.z0; v1 = b.z1;
                } else {
                    u0 = b.x0; u1 = b.x1; v0 = b.p0; v1 = b.p1;
                }
                const int ub = ax == 0 ? b.z0 : b.x0;
                const int vb = ax == 1 ? b.z0 : b.v_base;
                const bool hi = (f & 1) == 0;
                for (int c = 0; c < 4; ++c) {
                    // The corner of the drawn cell nearest this corner of the
                    // face (a face drawn in an L has a corner nowhere drawn,
                    // maybe in the open air past a wall).
                    const int tu = (c & 1) ? u1 : u0, tv = (c & 2) ? v1 : v0;
                    float u = (float)tu, v = (float)tv;
                    if (b.drawn[f] != 0) {
                        int best = INT_MAX;
                        for (uint64_t m = b.drawn[f]; m != 0; m &= m - 1) {
                            int bit = 0;
                            while (((m >> bit) & 1ULL) == 0) {
                                ++bit;
                            }
                            const int cu = ub + (bit & 7) + ((c & 1) ? 1 : 0);
                            const int cv = vb + (bit >> 3) + ((c & 2) ? 1 : 0);
                            const int d = std::abs(cu - tu) + std::abs(cv - tv);
                            if (d < best) {
                                best = d;
                                u = (float)cu;
                                v = (float)cv;
                            }
                        }
                    }
                    Vector3 q;
                    if (ax == 0) {
                        q = Vector3((float)((hi ? b.x1 : b.x0) - gx0) * STUD_M, v * PLATE_M,
                                (u - (float)gz0) * STUD_M);
                    } else if (ax == 1) {
                        q = Vector3((u - (float)gx0) * STUD_M, (float)(hi ? b.p1 : b.p0) * PLATE_M,
                                (v - (float)gz0) * STUD_M);
                    } else {
                        q = Vector3((u - (float)gx0) * STUD_M, v * PLATE_M,
                                (float)((hi ? b.z1 : b.z0) - gz0) * STUD_M);
                    }
                    bpts.push_back(q);
                    bnrm.push_back(NRM[f]);
                    bref.push_back({ (int)obs.size() - 1, f, c });
                }
            }
        }
    }
    const int nb = (int)bpts.size();
    // The eight cells round a point's sample point, and their weights.
    auto corners_at = [&](const Vector3 &pos, const Vector3 &nrm, int &ix, int &iy, int &iz,
            float &fx, float &fy, float &fz) {
        const Vector3 q = pos + Vector3(nrm.x * STUD_M, nrm.y * BRICK_M, nrm.z * STUD_M) * 0.5f;
        const float cx = q.x / STUD_M + (float)gx0 - 0.5f;
        const float cy = q.y / BRICK_M - 0.5f;
        const float cz = q.z / STUD_M + (float)gz0 - 0.5f;
        ix = (int)std::floor(cx);
        iy = (int)std::floor(cy);
        iz = (int)std::floor(cz);
        fx = cx - (float)ix;
        fy = cy - (float)iy;
        fz = cz - (float)iz;
    };
    // A BEHIND vertex (BEHIND_FACE) faces the brick in front of it, solid
    // now: its light is what the hole will have, read from the far side of
    // that brick (stepping along the normal while the cell is that brick's).
    const uint8_t *c0 = m.custom0.ptr();
    auto behind_at = [&](int i) -> Vector3 {
        const Vector3 nrm = nr[i];
        const Vector3 step(nrm.x * STUD_M, nrm.y * PLATE_M, nrm.z * STUD_M);
        Vector3 q = v[i];
        for (int k = 0; k < 64; ++k) {
            const Vector3 mid = q + step * 0.5f;
            const int lx = (int)std::floor(mid.x / STUD_M), yp = (int)std::floor(mid.y / PLATE_M);
            const int lz = (int)std::floor(mid.z / STUD_M);
            if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN || lz >= TILE + MARGIN
                    || !s.in_y(yp) || (*t_behind)[(size_t)s.vidx(lx, yp, lz)] == 0) {
                break;
            }
            q += step;
        }
        return q;
    };
    auto corners = [&](int i, int &ix, int &iy, int &iz, float &fx, float &fy, float &fz) {
        if (t_behind != nullptr && c0[(size_t)i * 4 + 2] == BEHIND_FACE) {
            corners_at(behind_at(i), nr[i], ix, iy, iz, fx, fy, fz);
            return;
        }
        corners_at(v[i], nr[i], ix, iy, iz, fx, fy, fz);
    };
    // Which of those cells are under their column's sky floor and open: the
    // ones the fill must answer for.
    Vector3i lo(INT_MAX, INT_MAX, INT_MAX), hi(INT_MIN, INT_MIN, INT_MIN);
    // Block light answers for every open cell a vertex reads, sky or not.
    Vector3i blo(INT_MAX, INT_MAX, INT_MAX), bhi(INT_MIN, INT_MIN, INT_MIN);
    bool dark = false;
    for (int i = 0; i < n + ns + nb; ++i) {
        int ix, iy, iz;
        float fx, fy, fz;
        if (i < n) {
            corners(i, ix, iy, iz, fx, fy, fz);
        } else if (i < n + ns) {
            corners_at(stud_at(i - n), UP, ix, iy, iz, fx, fy, fz);
        } else {
            corners_at(bpts[(size_t)(i - n - ns)], bnrm[(size_t)(i - n - ns)], ix, iy, iz, fx, fy, fz);
        }
        for (int k = 0; k < 8; ++k) {
            const int x = ix + (k & 1), c = iy + ((k >> 1) & 1), z = iz + ((k >> 2) & 1);
            if (g.opaque(x, c, z) && !g.sky(x, c, z)) {
                continue;
            }
            blo = Vector3i(std::min(blo.x, x), std::min(blo.y, c), std::min(blo.z, z));
            bhi = Vector3i(std::max(bhi.x, x), std::max(bhi.y, c), std::max(bhi.z, z));
            if (g.sky(x, c, z)) {
                continue;
            }
            dark = true;
            lo = Vector3i(std::min(lo.x, x), std::min(lo.y, c), std::min(lo.z, z));
            hi = Vector3i(std::max(hi.x, x), std::max(hi.y, c), std::max(hi.z, z));
        }
    }
    if (dark) {
        g.fill(lo, hi);
    }
    // BLOCK LIGHT: the water's lava cells that could reach the box (any
    // thread: BrickFluid takes its lock a moment, nothing when no lava).
    const uint64_t tb = Time::get_singleton()->get_ticks_usec();
    int seeds = 0;
    if (blo.x <= bhi.x && BrickFluid::lava_total() > 0) {
        std::vector<int32_t> lava;
        const Vector3i qlo(std::max(g.x0, blo.x - SKY_MAX), std::max(g.c0, blo.y - SKY_MAX), std::max(g.z0, blo.z - SKY_MAX));
        const Vector3i qhi(std::min(g.x0 + g.nx - 1, bhi.x + SKY_MAX), std::min(g.c1(), bhi.y + SKY_MAX),
                std::min(g.z0 + g.nz - 1, bhi.z + SKY_MAX));
        BrickFluid::lava_cells_in(qlo, qhi, lava);
        if (!lava.empty()) {
            seeds = g.fill_block(blo, bhi, lava);
        }
    }
    const double block_ms = (double)(Time::get_singleton()->get_ticks_usec() - tb) / 1000.0;
    const bool lit = seeds > 0;
    uint8_t *cu = m.custom0.ptrw();
    for (int i = 0; i < n; ++i) {
        int ix, iy, iz;
        float fx, fy, fz;
        corners(i, ix, iy, iz, fx, fy, fz);
        float sum = 0.0f, wsum = 0.0f;
        for (int k = 0; k < 8; ++k) {
            const int x = ix + (k & 1), c = iy + ((k >> 1) & 1), z = iz + ((k >> 2) & 1);
            if (g.opaque(x, c, z) && !g.sky(x, c, z)) {
                continue;
            }
            const float w = ((k & 1) ? fx : 1.0f - fx) * (((k >> 1) & 1) ? fy : 1.0f - fy)
                    * (((k >> 2) & 1) ? fz : 1.0f - fz);
            sum += w * (float)g.light(x, c, z);
            wsum += w;
        }
        float lv = 0.0f;
        if (wsum > 1e-5f) {
            lv = sum / wsum;
        } else {
            // All eight opaque (a face inside a part-filled course): the
            // nearest cell's own answer.
            const int x = ix + (fx > 0.5f), c = iy + (fy > 0.5f), z = iz + (fz > 0.5f);
            lv = g.sky(x, c, z) ? (float)SKY_MAX : 0.0f;
        }
        cu[(size_t)i * 4 + 3] = (uint8_t)std::lround(std::clamp(lv / (float)SKY_MAX, 0.0f, 1.0f) * 255.0f);
        if (!lit) {
            continue;
        }
        // Block light the same way, into CUSTOM0.g as 0..BLOCK_BYTE: under
        // the far meshes' 64 (their G is 128 or 255, smooth far ground), so
        // the shader tells them apart and every other scene ignores it.
        float bs = 0.0f, bw = 0.0f;
        for (int k = 0; k < 8; ++k) {
            const int x = ix + (k & 1), c = iy + ((k >> 1) & 1), z = iz + ((k >> 2) & 1);
            if (g.opaque(x, c, z) && !g.sky(x, c, z)) {
                continue;
            }
            const float w = ((k & 1) ? fx : 1.0f - fx) * (((k >> 1) & 1) ? fy : 1.0f - fy)
                    * (((k >> 2) & 1) ? fz : 1.0f - fz);
            bs += w * (float)g.block_light(x, c, z);
            bw += w;
        }
        const float bl = bw > 1e-5f ? bs / bw : 0.0f;
        cu[(size_t)i * 4 + 1] = (uint8_t)std::lround(std::clamp(bl / (float)SKY_MAX, 0.0f, 1.0f) * (float)BLOCK_BYTE);
    }
    // The studs: the same blend, into their custom data (sky, block; 0..1).
    for (int k = 0; k < ns; ++k) {
        int ix, iy, iz;
        float fx, fy, fz;
        corners_at(stud_at(k), UP, ix, iy, iz, fx, fy, fz);
        float sum = 0.0f, wsum = 0.0f, bs = 0.0f;
        for (int c8 = 0; c8 < 8; ++c8) {
            const int x = ix + (c8 & 1), c = iy + ((c8 >> 1) & 1), z = iz + ((c8 >> 2) & 1);
            if (g.opaque(x, c, z) && !g.sky(x, c, z)) {
                continue;
            }
            const float w = ((c8 & 1) ? fx : 1.0f - fx) * (((c8 >> 1) & 1) ? fy : 1.0f - fy)
                    * (((c8 >> 2) & 1) ? fz : 1.0f - fz);
            sum += w * (float)g.light(x, c, z);
            if (lit) {
                bs += w * (float)g.block_light(x, c, z);
            }
            wsum += w;
        }
        float *b = studs->ptrw() + (size_t)k * SS;
        b[16] = wsum > 1e-5f ? std::clamp(sum / wsum / (float)SKY_MAX, 0.0f, 1.0f) : 1.0f;
        b[17] = wsum > 1e-5f ? std::clamp(bs / wsum / (float)SKY_MAX, 0.0f, 1.0f) : 0.0f;
    }
    // The overlay bricks' faces: the open cells' blend, as a vertex's.
    for (int k = 0; k < nb; ++k) {
        int ix, iy, iz;
        float fx, fy, fz;
        corners_at(bpts[(size_t)k], bnrm[(size_t)k], ix, iy, iz, fx, fy, fz);
        float sum = 0.0f, wsum = 0.0f, bs = 0.0f;
        for (int c8 = 0; c8 < 8; ++c8) {
            const int x = ix + (c8 & 1), c = iy + ((c8 >> 1) & 1), z = iz + ((c8 >> 2) & 1);
            if (g.opaque(x, c, z) && !g.sky(x, c, z)) {
                continue;
            }
            const float w = ((c8 & 1) ? fx : 1.0f - fx) * (((c8 >> 1) & 1) ? fy : 1.0f - fy)
                    * (((c8 >> 2) & 1) ? fz : 1.0f - fz);
            sum += w * (float)g.light(x, c, z);
            if (lit) {
                bs += w * (float)g.block_light(x, c, z);
            }
            wsum += w;
        }
        OutBrick &ob = *obs[(size_t)bref[(size_t)k][0]];
        const int f = bref[(size_t)k][1], cc = bref[(size_t)k][2];
        const float lv = wsum > 1e-5f ? sum / wsum : 0.0f;
        ob.sky[f][cc] = (uint8_t)std::clamp((int)std::lround(lv), 0, SKY_MAX);
        const int bl = (int)std::lround(wsum > 1e-5f ? bs / wsum : 0.0f);
        ob.blk[f] = (uint8_t)std::clamp(std::max((int)ob.blk[f] * (cc > 0 ? 1 : 0), bl), 0, SKY_MAX);
    }
    // Faces drawn by none: the brightest drawn face's light, all over.
    for (OutBrick *ob : obs) {
        int sky = -1, blk = 0;
        for (int f = 0; f < 6; ++f) {
            if (ob->drawn[f] == 0) {
                continue;
            }
            for (int c = 0; c < 4; ++c) {
                sky = std::max(sky, (int)ob->sky[f][c]);
            }
            blk = std::max(blk, (int)ob->blk[f]);
        }
        if (sky < 0) {
            continue;
        }
        for (int f = 0; f < 6; ++f) {
            if (ob->drawn[f] != 0) {
                continue;
            }
            for (int c = 0; c < 4; ++c) {
                ob->sky[f][c] = (uint8_t)sky;
            }
            ob->blk[f] = (uint8_t)blk;
        }
    }
    out["sky_ms"] = (double)(Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    out["sky_filled"] = g.cells_filled;
    out["sky_dark"] = dark;
    out["block_ms"] = block_ms;
    out["block_seeds"] = seeds;
    out["block_filled"] = g.block_filled;
    // The plates the light grid covers: lava outside them cannot change
    // this mesh's light (mine_world.gd skips relighting the tile then).
    out["light_lo"] = g.c0 * PLATES_PER_CELL;
    out["light_hi"] = (g.c1() + 1) * PLATES_PER_CELL - 1;
}

void brick::sky_levels_into(const PackedVector3Array &verts, const PackedVector3Array &norms,
        PackedColorArray &col) {
    const int n = verts.size();
    if (!g_sky_light.load(std::memory_order_relaxed) || n == 0 || col.size() != n || norms.size() != n) {
        return;
    }
    const Vector3 *v = verts.ptr();
    const Vector3 *nr = norms.ptr();
    Vector3 lo = v[0], hi = v[0];
    for (int i = 1; i < n; ++i) {
        lo = Vector3(std::min(lo.x, v[i].x), std::min(lo.y, v[i].y), std::min(lo.z, v[i].z));
        hi = Vector3(std::max(hi.x, v[i].x), std::max(hi.y, v[i].y), std::max(hi.z, v[i].z));
    }
    const int x0 = (int)std::floor(lo.x / STUD_M) - 1, x1 = (int)std::floor(hi.x / STUD_M) + 1;
    const int z0 = (int)std::floor(lo.z / STUD_M) - 1, z1 = (int)std::floor(hi.z / STUD_M) + 1;
    const int c0 = (int)std::floor(lo.y / BRICK_M) - 1, c1 = (int)std::floor(hi.y / BRICK_M) + 1;
    SkyGrid g;
    g.init(x0 - SKY_PAD, z0 - SKY_PAD, c0 - SKY_PAD, x1 - x0 + 1 + 2 * SKY_PAD,
            z1 - z0 + 1 + 2 * SKY_PAD, c1 - c0 + 1 + 2 * SKY_PAD);
    auto corners = [&](int i, int &ix, int &iy, int &iz, float &fx, float &fy, float &fz) {
        const Vector3 q = v[i] + Vector3(nr[i].x * STUD_M, nr[i].y * BRICK_M, nr[i].z * STUD_M) * 0.5f;
        const float cx = q.x / STUD_M - 0.5f;
        const float cy = q.y / BRICK_M - 0.5f;
        const float cz = q.z / STUD_M - 0.5f;
        ix = (int)std::floor(cx);
        iy = (int)std::floor(cy);
        iz = (int)std::floor(cz);
        fx = cx - (float)ix;
        fy = cy - (float)iy;
        fz = cz - (float)iz;
    };
    Vector3i dlo(INT_MAX, INT_MAX, INT_MAX), dhi(INT_MIN, INT_MIN, INT_MIN);
    bool dark = false;
    for (int i = 0; i < n; ++i) {
        int ix, iy, iz;
        float fx, fy, fz;
        corners(i, ix, iy, iz, fx, fy, fz);
        for (int k = 0; k < 8; ++k) {
            const int x = ix + (k & 1), c = iy + ((k >> 1) & 1), z = iz + ((k >> 2) & 1);
            if (g.sky(x, c, z) || g.opaque(x, c, z)) {
                continue;
            }
            dark = true;
            dlo = Vector3i(std::min(dlo.x, x), std::min(dlo.y, c), std::min(dlo.z, z));
            dhi = Vector3i(std::max(dhi.x, x), std::max(dhi.y, c), std::max(dhi.z, z));
        }
    }
    if (dark) {
        g.fill(dlo, dhi);
    }
    Color *cw = col.ptrw();
    for (int i = 0; i < n; ++i) {
        int ix, iy, iz;
        float fx, fy, fz;
        corners(i, ix, iy, iz, fx, fy, fz);
        float sum = 0.0f, wsum = 0.0f;
        for (int k = 0; k < 8; ++k) {
            const int x = ix + (k & 1), c = iy + ((k >> 1) & 1), z = iz + ((k >> 2) & 1);
            if (g.opaque(x, c, z) && !g.sky(x, c, z)) {
                continue;
            }
            const float w = ((k & 1) ? fx : 1.0f - fx) * (((k >> 1) & 1) ? fy : 1.0f - fy)
                    * (((k >> 2) & 1) ? fz : 1.0f - fz);
            sum += w * (float)g.light(x, c, z);
            wsum += w;
        }
        const float lv = wsum > 1e-5f ? sum / wsum : (float)SKY_MAX;
        cw[i].b = std::clamp(lv / (float)SKY_MAX, 0.0f, 1.0f);
    }
}

void BrickTerrain::set_sky_light(bool on) { g_sky_light.store(on); }
bool BrickTerrain::get_sky_light() { return g_sky_light.load(); }

/// The eye's level: a fill backwards from its cell through open cells, the
/// first sky cell met at d steps giving 15 - d -- the same answer the bake's
/// fill gives that cell, for the cells near the eye only.
double BrickTerrain::sky_light_at(Vector3 point) {
    const int x = (int)std::floor(point.x / STUD_M);
    const int c = (int)std::floor(point.y / BRICK_M);
    const int z = (int)std::floor(point.z / STUD_M);
    SkyGrid g;
    g.init(x - SKY_MAX, z - SKY_MAX, c - SKY_MAX, 2 * SKY_MAX + 1, 2 * SKY_MAX + 1, 2 * SKY_MAX + 1);
    if (g.sky(x, c, z)) {
        return SKY_MAX;
    }
    // `level` doubles as the visited mark: steps + 1.
    std::vector<uint32_t> cur, next;
    cur.push_back((uint32_t)g.ci(x, c, z));
    g.level[g.ci(x, c, z)] = 1;
    const size_t plane = (size_t)g.nx * g.nz;
    static const int NX[6] = { -1, 1, 0, 0, 0, 0 };
    static const int NY[6] = { 0, 0, -1, 1, 0, 0 };
    static const int NZ[6] = { 0, 0, 0, 0, -1, 1 };
    for (int d = 1; d <= SKY_MAX && !cur.empty(); ++d) {
        next.clear();
        for (uint32_t i : cur) {
            const int cc = g.c0 + (int)(i / plane);
            const size_t r = i % plane;
            const int zz = g.z0 + (int)(r / (size_t)g.nx);
            const int xx = g.x0 + (int)(r % (size_t)g.nx);
            for (int k = 0; k < 6; ++k) {
                const int ax = xx + NX[k], ac = cc + NY[k], az = zz + NZ[k];
                if (!g.in(ax, ac, az)) {
                    continue;
                }
                const size_t j = g.ci(ax, ac, az);
                if (g.level[j] != 0) {
                    continue;
                }
                g.level[j] = 1;
                if (g.opaque(ax, ac, az)) {
                    continue;
                }
                if (g.sky(ax, ac, az)) {
                    return SKY_MAX - d;
                }
                next.push_back((uint32_t)j);
            }
        }
        cur.swap(next);
    }
    return 0.0;
}

/// The block light of the cell holding `point`: the bake's fill_block over a
/// box light's reach round it, seeded by the lava in that box. Nothing to do,
/// and no grid made, when there is no lava near.
double BrickTerrain::block_light_at(Vector3 point) {
    if (BrickFluid::lava_total() <= 0) {
        return 0.0;
    }
    const int x = (int)std::floor(point.x / STUD_M);
    const int c = (int)std::floor(point.y / BRICK_M);
    const int z = (int)std::floor(point.z / STUD_M);
    std::vector<int32_t> lava;
    BrickFluid::lava_cells_in(Vector3i(x - SKY_MAX, c - SKY_MAX, z - SKY_MAX),
            Vector3i(x + SKY_MAX, c + SKY_MAX, z + SKY_MAX), lava);
    if (lava.empty()) {
        return 0.0;
    }
    SkyGrid g;
    g.init(x - SKY_MAX, z - SKY_MAX, c - SKY_MAX, 2 * SKY_MAX + 1, 2 * SKY_MAX + 1, 2 * SKY_MAX + 1);
    const Vector3i at(x, c, z);
    if (g.fill_block(at, at, lava) == 0) {
        return 0.0;
    }
    return (double)g.block_light(x, c, z);
}

/// A colour as one whole number of 24 bits (8 a channel, r at bit 0): exact
/// in a float, which the overlay's instance colour is.
static inline float pack_rgb(float r, float g, float b) {
    auto q = [](float v) { return (int)std::lround(std::clamp(v, 0.0f, 1.0f) * 255.0f); };
    return (float)(q(r) | (q(g) << 8) | (q(b) << 16));
}

Dictionary BrickTerrain::overlay_pick(const Array &lists, Vector3 eye, Vector3 forward, double range_m,
        double cos_half, int max_bricks, const PackedVector3Array &hidden) {
    constexpr int IN = 17, OUT = 20;
    struct Cand {
        float d2;
        const float *b;
        int sky[4];   ///< the faces' sky words, merged
        int blk;
        int drawn;
    };
    std::vector<Cand> cands;
    std::unordered_map<uint64_t, size_t> keys;
    const float r = (float)range_m, r2 = r * r;
    const float ch = (float)cos_half;
    const Vector3 f = forward.length_squared() > 1e-12f ? forward.normalized() : Vector3(0, 0, -1);
    int64_t seen = 0;
    // The arrays stay referenced by `lists` for the call: pointers into them hold.
    for (int64_t li = 0; li < lists.size(); ++li) {
        const Variant &v = lists[li];
        if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
            continue;
        }
        const PackedFloat32Array a = v;   // shares the list's buffer (copy on write)
        const int64_t n = a.size() / IN;
        const float *p = a.ptr();
        seen += n;
        for (int64_t i = 0; i < n; ++i) {
            const float *b = p + i * IN;
            const Vector3 lo(b[0], b[1], b[2]), hi(b[3], b[4], b[5]);
            // Distance to the box.
            const Vector3 q(std::clamp(eye.x, lo.x, hi.x), std::clamp(eye.y, lo.y, hi.y),
                    std::clamp(eye.z, lo.z, hi.z));
            const float d2 = (q - eye).length_squared();
            if (d2 > r2) {
                continue;
            }
            // In the cone: its bounding sphere.
            const Vector3 mid = (lo + hi) * 0.5f;
            const Vector3 to = mid - eye;
            const float rad = (hi - lo).length() * 0.5f;
            const float tl = to.length();
            if (tl > rad && to.dot(f) < tl * ch - rad) {
                continue;
            }
            // Inside a hidden box (a millimetre's give): left out.
            bool gone = false;
            for (int64_t q = 0; q + 1 < hidden.size(); q += 2) {
                const Vector3 &a = hidden[q], &e = hidden[q + 1];
                if (lo.x >= a.x - 1e-3f && lo.y >= a.y - 1e-3f && lo.z >= a.z - 1e-3f
                        && hi.x <= e.x + 1e-3f && hi.y <= e.y + 1e-3f && hi.z <= e.z + 1e-3f) {
                    gone = true;
                    break;
                }
            }
            if (gone) {
                continue;
            }
            const uint64_t k = ((uint64_t)(uint32_t)(int32_t)std::lround(lo.x / STUD_M) & 0x1FFFFFULL)
                    | (((uint64_t)(uint32_t)(int32_t)std::lround(lo.z / STUD_M) & 0x1FFFFFULL) << 21)
                    | (((uint64_t)(uint32_t)floor_div((int)std::lround(lo.y / PLATE_M), PLATES_PER_CELL)
                            & 0x3FFFFFULL) << 42);
            auto found = keys.find(k);
            if (found != keys.end()) {
                // The same brick from another tile: each face from the list
                // that drew more of it.
                Cand &c = cands[found->second];
                const int dr = (int)b[16];
                for (int f = 0; f < 6; ++f) {
                    const int mine = (c.drawn >> (4 * f)) & 15, theirs = (dr >> (4 * f)) & 15;
                    if (theirs <= mine) {
                        continue;
                    }
                    for (int cc = 0; cc < 4; ++cc) {
                        const int n = f * 4 + cc, wq = n / 6, sh = 4 * (n % 6);
                        c.sky[wq] = (c.sky[wq] & ~(15 << sh)) | (((int)b[11 + wq] >> sh & 15) << sh);
                    }
                    c.blk = (c.blk & ~(15 << (4 * f))) | (((int)b[15] >> (4 * f) & 15) << (4 * f));
                    c.drawn = (c.drawn & ~(15 << (4 * f))) | (theirs << (4 * f));
                }
                continue;
            }
            keys.emplace(k, cands.size());
            cands.push_back(Cand{ d2, b, { (int)b[11], (int)b[12], (int)b[13], (int)b[14] }, (int)b[15],
                    (int)b[16] });
        }
    }
    const int64_t total = (int64_t)cands.size();
    const int64_t take = std::min<int64_t>(total, std::max(0, max_bricks));
    float far_m = r;
    if (take < total) {
        std::nth_element(cands.begin(), cands.begin() + take, cands.end(),
                [](const Cand &x, const Cand &y) { return x.d2 < y.d2; });
        far_m = std::sqrt(cands[(size_t)take].d2);
    }
    PackedFloat32Array buf;
    buf.resize(take * OUT);
    float *w = buf.ptrw();
    for (int64_t i = 0; i < take; ++i) {
        const Cand &cd = cands[(size_t)i];
        const float *b = cd.b;
        const float sx = b[3] - b[0], sy = b[4] - b[1], sz = b[5] - b[2];
        const float o[OUT] = {
            sx, 0.0f, 0.0f, (b[0] + b[3]) * 0.5f,
            0.0f, sy, 0.0f, (b[1] + b[4]) * 0.5f,
            0.0f, 0.0f, sz, (b[2] + b[5]) * 0.5f,
            pack_rgb(b[7], b[8], b[9]), (float)cd.blk, 0.0f, b[6] * 2.0f + (b[10] > 0.5f ? 1.0f : 0.0f),
            (float)cd.sky[0], (float)cd.sky[1], (float)cd.sky[2], (float)cd.sky[3],
        };
        std::memcpy(w + i * OUT, o, sizeof(o));
    }
    Dictionary out;
    out["buffer"] = buf;
    out["count"] = take;
    out["far_m"] = far_m;
    out["seen"] = seen;
    out["inside"] = total;
    return out;
}

Dictionary BrickTerrain::overlay_find(const Array &lists, Vector3 point) {
    constexpr int IN = 17;
    constexpr float E = 1e-3f;
    Dictionary out;
    const float *hit = nullptr;
    PackedFloat32Array best;   // a copy of the brick's floats, merged
    std::vector<PackedFloat32Array> held;
    held.reserve((size_t)lists.size());
    for (int64_t li = 0; li < lists.size(); ++li) {
        const Variant &v = lists[li];
        if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
            continue;
        }
        held.push_back(v);
    }
    // The brick: the first box holding the point; then the same brick in the
    // other lists, each face from the one that drew more of it.
    for (const PackedFloat32Array &a : held) {
        const float *p = a.ptr();
        const int64_t n = a.size() / IN;
        for (int64_t i = 0; i < n; ++i) {
            const float *b = p + i * IN;
            if (point.x < b[0] || point.y < b[1] || point.z < b[2] || point.x > b[3] || point.y > b[4]
                    || point.z > b[5]) {
                continue;
            }
            if (hit == nullptr) {
                hit = b;
                best.resize(IN);
                std::memcpy(best.ptrw(), b, sizeof(float) * IN);
                continue;
            }
            if (std::fabs(b[0] - hit[0]) > E || std::fabs(b[2] - hit[2]) > E || std::fabs(b[1] - hit[1]) > 0.13f) {
                continue;
            }
            float *w = best.ptrw();
            int sky[4] = { (int)w[11], (int)w[12], (int)w[13], (int)w[14] };
            int blk = (int)w[15], drawn = (int)w[16];
            for (int f = 0; f < 6; ++f) {
                const int mine = (drawn >> (4 * f)) & 15, theirs = ((int)b[16] >> (4 * f)) & 15;
                if (theirs <= mine) {
                    continue;
                }
                for (int cc = 0; cc < 4; ++cc) {
                    const int k = f * 4 + cc, wq = k / 6, sh = 4 * (k % 6);
                    sky[wq] = (sky[wq] & ~(15 << sh)) | ((((int)b[11 + wq]) >> sh & 15) << sh);
                }
                blk = (blk & ~(15 << (4 * f))) | ((((int)b[15]) >> (4 * f) & 15) << (4 * f));
                drawn = (drawn & ~(15 << (4 * f))) | (theirs << (4 * f));
            }
            for (int q = 0; q < 4; ++q) {
                w[11 + q] = (float)sky[q];
            }
            w[15] = (float)blk;
            w[16] = (float)drawn;
        }
    }
    if (hit == nullptr) {
        return out;
    }
    const float *w = best.ptr();
    Vector3 lo(w[0], w[1], w[2]), hi(w[3], w[4], w[5]);
    // Stacked on or under it, the same footprint: one piece.
    for (bool grew = true; grew;) {
        grew = false;
        for (const PackedFloat32Array &a : held) {
            const float *p = a.ptr();
            const int64_t n = a.size() / IN;
            for (int64_t i = 0; i < n; ++i) {
                const float *b = p + i * IN;
                if (std::fabs(b[0] - lo.x) > E || std::fabs(b[3] - hi.x) > E || std::fabs(b[2] - lo.z) > E
                        || std::fabs(b[5] - hi.z) > E) {
                    continue;
                }
                if (std::fabs(b[1] - hi.y) < E && b[4] > hi.y + E) {
                    hi.y = b[4];
                    grew = true;
                } else if (std::fabs(b[4] - lo.y) < E && b[1] < lo.y - E) {
                    lo.y = b[1];
                    grew = true;
                }
            }
        }
    }
    out["brick"] = best;
    out["lo"] = lo;
    out["hi"] = hi;
    return out;
}

Dictionary BrickTerrain::build_section(int tx, int sy, int tz) {
    std::map<std::array<int, 3>, OutBrick> overlay;
    t_bricks = &overlay;
    struct OverlayReset { ~OverlayReset() { t_bricks = nullptr; } } overlay_reset;
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
    Dictionary out;
    TileSample s;
    MeshBuf m;
    PackedFloat32Array boxes;
    int cave_boxes = 0;
    PackedFloat32Array studs;
    int stud_count = 0;
    if (sample_section(tx, sy, tz, s)) {
        const std::vector<int32_t> owner((size_t)TILE * TILE, -1);
        const std::vector<Piece> pieces;
        mask_faces(m, s, owner, pieces, g_field.seed, studs, stud_count);
        std::vector<uint8_t> behind;
        if (behind_wanted(tx, sy, tz)) {
            behind_faces(m, s, false, behind);
            out["behind_baked"] = true;
        }
        cave_boxes = add_cave_boxes(s, boxes, true, nullptr);
        sky_light_pass(m, s, false, out, &studs);
        t_behind = nullptr;
        out["behind_mesh"] = split_behind(m);
        out["own_lo"] = s.own_lo;
        out["own_hi"] = s.own_hi;
    }
    Array mesh;
    if (!m.verts.is_empty()) {
        mesh.resize(Mesh::ARRAY_MAX);
        mesh[Mesh::ARRAY_VERTEX] = m.verts;
        mesh[Mesh::ARRAY_NORMAL] = m.normals;
        mesh[Mesh::ARRAY_COLOR] = m.colours;
        mesh[Mesh::ARRAY_TEX_UV] = m.uvs;
        mesh[Mesh::ARRAY_TEX_UV2] = m.uv2s;
        mesh[Mesh::ARRAY_INDEX] = m.indices;
        mesh[Mesh::ARRAY_CUSTOM0] = m.custom0;
    }
    // The keys TerrainTile reads, so a section is drawn by the same node.
    out["mesh"] = mesh;
    // The bricks it drew a face of (Docs/BrickOverlay.md).
    out["overlay_bricks"] = bricks_floats(overlay);
    t_bricks = nullptr;
    // Studs on the cave floors (Docs/MineWorld.md 20), drawn by the section's
    // TerrainTile like a surface tile's.
    out["studs"] = studs;
    out["stud_stride"] = stud_stride();
    out["tufts"] = PackedFloat32Array();
    out["pebbles"] = PackedFloat32Array();
    out["bricks"] = PackedFloat32Array();
    out["brick_count"] = 0;
    out["boxes"] = boxes;
    out["box_count"] = boxes.size() / 6;
    out["cave_box_count"] = cave_boxes;
    out["piece_count"] = 0;
    out["triangle_count"] = m.indices.size() / 3;
    out["stud_count"] = stud_count;
    out["scatter_count"] = 0;
    out["build_ms"] = (double)(Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    return out;
}

Dictionary BrickTerrain::build_tile(int tx, int tz) {
    std::map<std::array<int, 3>, OutBrick> overlay;
    t_bricks = &overlay;
    struct OverlayReset { ~OverlayReset() { t_bricks = nullptr; } } overlay_reset;
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();

    TileSample s;
    const std::shared_ptr<const brick::TilePack> packed = brick::packed_tile(tx, tz, s);
    const std::vector<Piece> &pieces = packed->pieces;
    const std::vector<int32_t> &owner = packed->owner;

    MeshBuf m;
    PackedFloat32Array boxes;
    const int gx0 = tx * TILE;
    const int gz0 = tz * TILE;

    // --- curved ground ---------------------------------------------------
    //
    // The same field and the same `tp`, with a different top face: one
    // vertex a column, interpolated. See Terrain.md 18.5.
    //
    // A corner's height is the mean of the four columns that meet there --
    // EXCEPT where one of them is bricked, and then it takes that brick's
    // exact top. The curve has to land on the brick's top edge rather than
    // near it, or the boundary is a row of pinholes.
    const int CLO = -1, CHI = TILE + 1;
    const int CSPAN = CHI - CLO + 1;
    std::vector<float> cy;
    if (g_smooth_terrain) {
        cy.assign((size_t)CSPAN * CSPAN, 0.0f);
        for (int cz = CLO; cz <= CHI; ++cz) {
            for (int cx = CLO; cx <= CHI; ++cx) {
                // THE CONTINUOUS FIELD, not the mean of the quantised tops.
                //
                // Averaging `tp` was the first version and it is barely a
                // curve at all: `tp` IS the staircase, and the mean of four
                // steps is another step with a bevel on it. On gentle
                // plate-quantised ground the four columns round a corner
                // usually agree, so the average equalled the column and the
                // "curve" was the same flat quad the bricks would have
                // drawn -- except without the packing, so the ground lost
                // its 2x4s and gained nothing. That is exactly what it
                // looked like.
                //
                // `raw_plate` is the surface BEFORE the floor, so a corner
                // is smooth by construction and the cells either side of it
                // interpolate a real slope. The half plate puts the curve
                // through the middle of the staircase it replaces rather
                // than along its top.
                float sum = 0.0f;
                int n = 0;
                int hard = -100000;
                for (int dz = -1; dz <= 0; ++dz) {
                    for (int dx = -1; dx <= 0; ++dx) {
                        const int i = TileSample::idx(cx + dx, cz + dz);
                        sum += (g_field.raw_plate(gx0 + cx + dx, gz0 + cz + dz) + 0.5f)
                                * PLATE_M;
                        ++n;
                        if (!s.smooth[i]) {
                            hard = std::max<int>(hard, s.tp[i]);
                        }
                    }
                }
                // Against brick, the curve lands on the brick's top edge
                // exactly -- that has not changed and is what keeps the
                // seam shut.
                cy[(size_t)(cx - CLO) + CSPAN * (cz - CLO)] =
                        hard > -100000 ? (float)(hard + 1) * PLATE_M : sum / (float)n;
            }
        }
    }
    // LOW-POLY CURVES (Terrain.md 18.7). A curve drawn one quad a stud costs
    // about twice the triangles of packed brick (§18.5). On a grid of K-stud
    // blocks:
    //
    //  1. EDGES. Every K-long edge of the grid with curve on BOTH sides of it
    //     along its whole length has the corners along it moved onto the
    //     straight line between its two ends. Both tiles that share a tile
    //     edge see the cells either side of it (the sample carries a cell of
    //     border), so they move the same corners the same way, and a 1x1
    //     curve cell next to a merged block reads the block's edge exactly --
    //     no gap. An edge next to brick is never moved: its corners take the
    //     brick's exact top (above), which is what keeps that seam shut.
    //  2. BLOCKS. A block whose K x K cells are all curve and whose four edges
    //     were all moved is drawn as ONE quad, and the corners inside it are
    //     moved onto that quad so collision and studs agree with the drawing.
    const int K = (g_smooth_terrain && g_curve_step > 1 && TILE % g_curve_step == 0)
            ? g_curve_step : 1;
    const int KB = TILE / K;
    std::vector<uint8_t> coarse;
    if (K > 1) {
        auto at = [&](int cx, int cz) -> float & {
            return cy[(size_t)(cx - CLO) + CSPAN * (cz - CLO)];
        };
        auto sm = [&](int lx, int lz) -> bool { return s.smooth[TileSample::idx(lx, lz)] != 0; };
        // Edges along X at z = j*K (cells z-1 and z either side), and along Z.
        std::vector<uint8_t> ex((size_t)KB * (KB + 1), 0), ez((size_t)(KB + 1) * KB, 0);
        for (int j = 0; j <= KB; ++j) {
            for (int i = 0; i < KB; ++i) {
                const int x0 = i * K, z = j * K;
                bool all = true;
                for (int k = 0; k < K && all; ++k) {
                    all = sm(x0 + k, z - 1) && sm(x0 + k, z);
                }
                if (all) {
                    ex[(size_t)i + KB * j] = 1;
                    const float a = at(x0, z), b = at(x0 + K, z);
                    for (int k = 1; k < K; ++k) {
                        at(x0 + k, z) = a + (b - a) * ((float)k / (float)K);
                    }
                }
                const int x = j * K, z0 = i * K;
                all = true;
                for (int k = 0; k < K && all; ++k) {
                    all = sm(x - 1, z0 + k) && sm(x, z0 + k);
                }
                if (all) {
                    ez[(size_t)j + (KB + 1) * i] = 1;
                    const float a = at(x, z0), b = at(x, z0 + K);
                    for (int k = 1; k < K; ++k) {
                        at(x, z0 + k) = a + (b - a) * ((float)k / (float)K);
                    }
                }
            }
        }
        coarse.assign((size_t)KB * KB, 0);
        for (int bz = 0; bz < KB; ++bz) {
            for (int bx = 0; bx < KB; ++bx) {
                if (!ex[(size_t)bx + KB * bz] || !ex[(size_t)bx + KB * (bz + 1)]
                        || !ez[(size_t)bx + (KB + 1) * bz] || !ez[(size_t)(bx + 1) + (KB + 1) * bz]) {
                    continue;
                }
                const int x0 = bx * K, z0 = bz * K;
                bool all = true;
                for (int lz = z0; lz < z0 + K && all; ++lz) {
                    for (int lx = x0; lx < x0 + K; ++lx) {
                        if (!sm(lx, lz)) {
                            all = false;
                            break;
                        }
                    }
                }
                if (!all) {
                    continue;
                }
                coarse[(size_t)bx + KB * bz] = 1;
                const float a = at(x0, z0), b = at(x0 + K, z0);
                const float c = at(x0 + K, z0 + K), d = at(x0, z0 + K);
                for (int cz = z0 + 1; cz < z0 + K; ++cz) {
                    for (int cx = x0 + 1; cx < x0 + K; ++cx) {
                        const float u = (float)(cx - x0) / (float)K;
                        const float v = (float)(cz - z0) / (float)K;
                        at(cx, cz) = (a + (b - a) * u) * (1.0f - v) + (d + (c - d) * u) * v;
                    }
                }
            }
        }
    }
    auto corner_y = [&](int cx, int cz) -> float {
        return cy[(size_t)(cx - CLO) + CSPAN * (cz - CLO)];
    };
    // Central differences over the corner grid. A vertex normal, which is
    // the whole point: a flat quad per cell would be a staircase with the
    // steps painted out.
    // The drawn height at the middle of a cell: what stands on it has to
    // agree with what it looks like.
    auto cell_surface = [&](int lx, int lz) -> float {
        return 0.25f * (corner_y(lx, lz) + corner_y(lx + 1, lz)
                + corner_y(lx + 1, lz + 1) + corner_y(lx, lz + 1));
    };
    auto corner_n = [&](int cx, int cz) -> Vector3 {
        const float dx = corner_y(cx - 1, cz) - corner_y(cx + 1, cz);
        const float dz = corner_y(cx, cz - 1) - corner_y(cx, cz + 1);
        return Vector3(dx, 2.0f * STUD_M, dz).normalized();
    };

    // Collision is merged across the whole tile, NOT emitted per piece.
    //
    // A piece is a rendering decision; the collider only has to match the
    // SURFACE. One box a piece meant 338 CollisionShape3D nodes a tile and
    // 8,450 across the test field -- which was the entire 813 ms scene build
    // against 0.5 ms of C++. Greedy rectangles over equal collision height
    // bring a flat tile back to a handful.
    //
    // A RAMP collides at half a brick rather than at its full step, so the
    // 0.42 m rise a ramp exists to soften is actually soft to walk up and not
    // only to look at. A proper wedge shape is the real answer and is what
    // `bake_shaped_archetype` is for; this is the cheap version.
    std::vector<float> ctop((size_t)TILE * TILE, 0.0f);
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            const int i = TileSample::idx(lx, lz);
            float full = (float)(s.tp[i] + 1) * PLATE_M;
            if (g_smooth_terrain && s.smooth[i]) {
                // The middle of the drawn cell, not the column it was cut
                // from: a curve's surface sits up to half a plate away from
                // its own `tp`, and walking a curve while standing on the
                // staircase under it is exactly the mismatch curves were
                // supposed to remove.
                //
                // QUANTISED to a quarter plate, and that is the whole trick
                // that keeps this affordable: the merge below joins cells of
                // EQUAL height, continuous heights are never equal, and an
                // unquantised curve would hand back one box a cell -- 1,024
                // a tile, which is the 813 ms scene build this merge exists
                // to prevent. A quarter plate is 3.5 cm of worst-case error
                // against 7 cm before.
                full = std::round(cell_surface(lx, lz) / COLLIDE_QUANTUM)
                        * COLLIDE_QUANTUM;
            }
            const int32_t o = owner[(size_t)lx + TILE * lz];
            if (o >= 0 && pieces[o].overlay != 0) {
                full += OVERLAY_M;   // you stand on the tile, not on the brick
            }
            ctop[(size_t)lx + TILE * lz] = (s.ramp[i] != 255) ? full - BRICK_M * 0.5f : full;
            if (o >= 0 && pieces[o].kind == PIECE_SLOPE) {
                // On a slope, the box at the slope's height over this cell,
                // quantised so a row of cells still merges.
                ctop[(size_t)lx + TILE * lz] = std::round(column_surface(s, lx, lz, 0.5f, 0.5f)
                        / COLLIDE_QUANTUM) * COLLIDE_QUANTUM;
            }
        }
    }

    // WHERE EACH COLUMN'S TOP STOPS BEING SOLID (Docs/MineWorld.md 20): the
    // lowest plate of the solid run down from its top, or INT16_MIN past
    // RUN_CAP plates. A top box reached down to the lowest neighbouring column
    // whatever was under the top, so over a cave under a roof -- a course or
    // two thick, beside lower ground -- it filled the cave with a wall you
    // walked into and could not break, drawn open (terrain_audit_probe: 7,158
    // open-air cells inside top boxes over 30 tiles). A merged box that would
    // reach into air under one of its columns is merged again inside itself,
    // over columns that stop alike, and each part stops at its first air; a
    // part over solid ground still reaches its lowest neighbour, so a terrace
    // face keeps its box.
    constexpr int RUN_CAP = 96;
    std::vector<int16_t> sbot((size_t)TILE * TILE, INT16_MIN);
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            int yp = s.tp[TileSample::idx(lx, lz)];
            int n = 0;
            while (n < RUN_CAP && s.solid(lx, yp, lz)) {
                --yp;
                ++n;
            }
            if (n < RUN_CAP) {
                sbot[(size_t)lx + TILE * lz] = (int16_t)(yp + 1);
            }
        }
    }
    // Plates of each column its top box covers, from the top down: the cave
    // colliders take the rest (add_cave_boxes).
    std::vector<int16_t> cov((size_t)TILE * TILE, (int16_t)PLATES_PER_CELL);
    // Down to the lowest neighbouring column, so a terrace face has no gap
    // under it. Clamped: a cliff does not need a box to the seabed, only far
    // enough that nothing walks through the face.
    auto box_depth = [&](int x0, int z0, int w, int d, float t) -> float {
        int lowest_p = s.tp[TileSample::idx(x0, z0)];
        for (int dz = -1; dz <= d; ++dz) {
            for (int dx = -1; dx <= w; ++dx) {
                if (dx >= 0 && dx < w && dz >= 0 && dz < d) {
                    continue;
                }
                lowest_p = std::min<int>(lowest_p, s.tp[TileSample::idx(x0 + dx, z0 + dz)]);
            }
        }
        const float floor_y = (float)(lowest_p + 1) * PLATE_M;
        return std::max(t - floor_y, BRICK_M);
    };
    auto emit_box = [&](int x0, int z0, int w, int d, float t, int cap) {
        float depth = box_depth(x0, z0, w, d, t);
        if (cap != INT16_MIN) {
            depth = std::max(std::min(depth, t - (float)cap * PLATE_M), 0.02f);
        }
        const int bottom = (int)std::ceil((t - depth) / PLATE_M - 1e-3f);
        for (int dz = 0; dz < d; ++dz) {
            for (int dx = 0; dx < w; ++dx) {
                const int tp = s.tp[TileSample::idx(x0 + dx, z0 + dz)];
                cov[(size_t)(x0 + dx) + TILE * (z0 + dz)] = (int16_t)std::max(tp - bottom + 1, 0);
            }
        }
        boxes.push_back(((float)x0 + (float)w * 0.5f) * STUD_M);
        boxes.push_back(t - depth * 0.5f);
        boxes.push_back(((float)z0 + (float)d * 0.5f) * STUD_M);
        boxes.push_back((float)w * STUD_M);
        boxes.push_back(depth);
        boxes.push_back((float)d * STUD_M);
    };
    // Greedy rectangles of equal collision height (and equal `key`) over a
    // region of the tile, handed to `on_rect(x0, z0, w, d)`.
    std::vector<uint8_t> done((size_t)TILE * TILE, 0);
    std::vector<int16_t> key((size_t)TILE * TILE, INT16_MIN);
    auto greedy = [&](int rx, int rz, int rw, int rd,
            const std::function<void(int, int, int, int)> &on_rect) {
        for (int lz = rz; lz < rz + rd; ++lz) {
            for (int lx = rx; lx < rx + rw; ++lx) {
                if (done[(size_t)lx + TILE * lz]) {
                    continue;
                }
                const float t = ctop[(size_t)lx + TILE * lz];
                const int16_t kk = key[(size_t)lx + TILE * lz];
                auto same = [&](int x, int z) {
                    const size_t i = (size_t)x + TILE * z;
                    return !done[i] && ctop[i] == t && key[i] == kk;
                };
                int w = 1;
                while (lx + w < rx + rw && same(lx + w, lz)) {
                    ++w;
                }
                int d = 1;
                while (lz + d < rz + rd) {
                    bool row_ok = true;
                    for (int k = 0; k < w && row_ok; ++k) {
                        row_ok = same(lx + k, lz + d);
                    }
                    if (!row_ok) {
                        break;
                    }
                    ++d;
                }
                for (int dz = 0; dz < d; ++dz) {
                    for (int dx = 0; dx < w; ++dx) {
                        done[(size_t)(lx + dx) + TILE * (lz + dz)] = 1;
                    }
                }
                on_rect(lx, lz, w, d);
            }
        }
    };
    greedy(0, 0, TILE, TILE, [&](int x0, int z0, int w, int d) {
        const float t = ctop[(size_t)x0 + TILE * z0];
        const float bottom = t - box_depth(x0, z0, w, d, t);
        bool through_air = false;
        for (int dz = 0; dz < d; ++dz) {
            for (int dx = 0; dx < w; ++dx) {
                const size_t i = (size_t)(x0 + dx) + TILE * (z0 + dz);
                if (sbot[i] != INT16_MIN && (float)sbot[i] * PLATE_M > bottom + 1e-4f) {
                    through_air = true;
                    key[i] = sbot[i];
                }
            }
        }
        if (!through_air) {
            emit_box(x0, z0, w, d, t, INT16_MIN);
            return;
        }
        for (int dz = 0; dz < d; ++dz) {
            for (int dx = 0; dx < w; ++dx) {
                done[(size_t)(x0 + dx) + TILE * (z0 + dz)] = 0;
            }
        }
        greedy(x0, z0, w, d, [&](int ax, int az, int aw, int ad) {
            emit_box(ax, az, aw, ad, t, key[(size_t)ax + TILE * az]);
        });
    });

    // --- cave colliders -----------------------------------------------------
    //
    // The boxes above follow each column's TOP and reach a brick (or the
    // lowest neighbour) down. Under that -- a cave floor, the ground under an
    // overhang, a tunnel's walls -- there was no collider at all: land in a
    // cave and the pawn fell through bricks it could see (Docs/MineWorld.md
    // 13). So every solid plate cell under its column's top box that touches
    // OPEN air (the air the mesher draws faces against), or lies within a
    // brick under a floor of it, is collided, greedily merged: along x, then
    // z, then up. Floors come out a brick thick, so nothing falls through a
    // plate-thin box. A box may grow through any cell that is not open air
    // -- rock, or a sealed chamber nobody can reach -- so the rock round a
    // cave is a few large boxes rather than a shell of thin ones (the shell
    // alone was ~400 boxes a cave tile).
    //
    // Cheap where there are no caves: a column only looks at its cells when
    // it, or a neighbour, has open air under its top.
    int cave_boxes = add_cave_boxes(s, boxes, false, &cov);

    int curve_cells = 0;
    if (g_smooth_terrain) {
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                const int i = TileSample::idx(lx, lz);
                if (!s.smooth[i]) {
                    continue;
                }
                ++curve_cells;
                // A cell of a merged block: its block's first cell draws the
                // whole block, and no skirt is ever needed (its ring is all
                // curve). The rest draw nothing.
                int span = 1;
                if (K > 1 && coarse[(size_t)(lx / K) + KB * (lz / K)]) {
                    if (lx % K != 0 || lz % K != 0) {
                        continue;
                    }
                    span = K;
                }
                const float x0 = (float)lx * STUD_M, x1 = (float)(lx + span) * STUD_M;
                const float z0 = (float)lz * STUD_M, z1 = (float)(lz + span) * STUD_M;
                const float y00 = corner_y(lx, lz);
                const float y10 = corner_y(lx + span, lz);
                const float y11 = corner_y(lx + span, lz + span);
                const float y01 = corner_y(lx, lz + span);
                // UV2 ZERO says "no piece here" to the shader: no outline to
                // draw and no perimeter for the nozzle to walk, because a
                // curve is not a moulded part with edges.
                const Vector2 face(0.0f, 0.0f);
                m.material = (uint8_t)s.mat[i];
                // On "slopes" ground a curve is NOT studded: the shader paints
                // a stud on every studded cell past the geometry studs' range,
                // and across a curved hillside that drew the brick grid back
                // over it from a distance (18.7). Its few real studs are
                // instances.
                Color col = piece_colour(s, lx, lz, s.mat[i], !g_smooth_slopes);
                if (g_smooth_slopes) {
                    // ...and not tinted cell by cell. A brick gets its own
                    // shade of the filament so neighbouring pieces read as
                    // pieces; on a curve that shade per stud cell drew a
                    // mosaic of 1x1 squares over the hill. A slow drift of
                    // a few percent instead, so a slope is not one flat
                    // colour either.
                    const int painted = s.col[i];
                    const Color base = filament_colour(painted != 0xFF ? painted
                            : material_filament(s.mat[i]));
                    const float t = 1.0f + 0.05f * value_noise((float)(gx0 + lx) * 0.03f,
                            (float)(gz0 + lz) * 0.03f, g_field.seed + 911U);
                    col = Color(base.r * t, base.g * t, base.b * t, 0.0f);
                }
                const Vector3 v[4] = {
                    Vector3(x0, y00, z0), Vector3(x1, y10, z0),
                    Vector3(x1, y11, z1), Vector3(x0, y01, z1),
                };
                const Vector3 nrm[4] = {
                    corner_n(lx, lz), corner_n(lx + span, lz),
                    corner_n(lx + span, lz + span), corner_n(lx, lz + span),
                };
                const Vector2 uv[4] = {
                    Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1),
                };
                m.quad_soft(col, face, v, nrm, uv);
                if (span > 1) {
                    continue;
                }

                // The skirt. Wherever the neighbouring column's surface is
                // BELOW this cell's edge, a wall closes the difference --
                // the same rule the brick mesher follows, and the reason a
                // curve can sit next to a terrace without a hole between
                // them. Against a bricked neighbour the brick draws its own
                // face at the same plane facing the other way, which costs
                // one quad and never z-fights.
                struct Edge {
                    int dx, dz;
                    Vector3 n;
                    float ax, az, bx, bz;
                    float ya, yb;
                };
                const Edge edges[4] = {
                    { 0, -1, Vector3(0, 0, -1), x0, z0, x1, z0, y00, y10 },
                    { 0,  1, Vector3(0, 0,  1), x1, z1, x0, z1, y11, y01 },
                    { -1, 0, Vector3(-1, 0, 0), x0, z1, x0, z0, y01, y00 },
                    {  1, 0, Vector3(1, 0,  0), x1, z0, x1, z1, y10, y11 },
                };
                for (const Edge &e : edges) {
                    const int ni = TileSample::idx(lx + e.dx, lz + e.dz);
                    // NEVER against another curve. Two neighbouring curve
                    // cells SHARE their corner vertices, so their surfaces
                    // already meet exactly and there is nothing to close --
                    // and the skirt was being sized from the neighbour's
                    // COLUMN, `(tp + 1) * plate`, which is not where a curve
                    // is drawn at all. Where that came out above the
                    // neighbour's real surface the skirt stood up THROUGH
                    // it: two surfaces in the same place, which is the
                    // z-fighting along the curved ground.
                    //
                    // A curve only ever needs a wall against BRICK.
                    if (s.smooth[ni]) {
                        continue;
                    }
                    const float ny = (float)(s.tp[ni] + 1) * PLATE_M;
                    const float lo = std::min(e.ya, e.yb);
                    if (ny >= lo - 1e-5f) {
                        continue;   // nothing showing
                    }
                    const Vector2 wall(STUD_M, lo - ny);
                    m.raw_quad(e.n, col, wall,
                        Vector3(e.ax, ny, e.az), Vector3(e.bx, ny, e.bz),
                        Vector3(e.bx, e.yb, e.bz), Vector3(e.ax, e.ya, e.az),
                        Vector2(0, wall.y), Vector2(wall.x, wall.y),
                        Vector2(wall.x, 0), Vector2(0, 0));
                }
            }
        }
    }

    for (const Piece &p : pieces) {
        m.material = (uint8_t)p.mat;
        Color col = piece_colour(s, p.ox, p.oz, p.mat, p.studded != 0);
        if (p.bsx > 0) {
            // A brick across a tile edge (the bond's top course): ONE moulded
            // colour, tinted by the brick's corner, not each part's.
            const float k = piece_tint(g_field.seed, gx0 + p.brick_x(), gz0 + p.brick_z())
                    / piece_tint(g_field.seed, gx0 + p.ox, gz0 + p.oz);
            col = Color(col.r * k, col.g * k, col.b * k, col.a);
        }
        // One march a piece, at its middle. A 2x4 is 1.4 m long and the sun
        // does not change over that, so per piece is the right granularity:
        // per column would be eight times the cost for an edge nobody can
        // see, and per tile would put a hard line down the middle of a hill.
        if (!sun_reaches(gx0 + p.brick_x() + p.brick_sx() / 2, gz0 + p.brick_z() + p.brick_sz() / 2)) {
            col = Color(col.r * SUN_SHADE, col.g * SUN_SHADE, col.b * SUN_SHADE, col.a);
        }
        if (p.kind == PIECE_BRICK || p.kind == PIECE_TILE) {
            note_brick(gx0 + p.brick_x(), gz0 + p.brick_z(), p.brick_sx(), p.brick_sz(),
                    p.top - (PLATES_PER_CELL - 1), p.top + 1, p.mat, col,
                    p.overlay == 0 && p.studded != 0);
            // Its top as this tile draws it (the piece's part of the brick).
            note_face(gx0 + p.brick_x(), gz0 + p.brick_z(),
                    p.overlay != 0 ? p.top + 1 : p.top - (PLATES_PER_CELL - 1), 2,
                    gx0 + p.ox, gz0 + p.oz, gx0 + p.ox + p.sx, gz0 + p.oz + p.sz);
            if (p.overlay != 0) {
                // The tile or plate laid on it: its own one-plate brick.
                note_brick(gx0 + p.brick_x(), gz0 + p.brick_z(), p.brick_sx(), p.brick_sz(),
                        p.top + 1, p.top + 2, p.mat, col, p.studded != 0);
            }
        }
        const float top = (float)(p.top + 1) * PLATE_M;
        const float x0 = (float)p.ox * STUD_M, x1 = (float)(p.ox + p.sx) * STUD_M;
        const float z0 = (float)p.oz * STUD_M, z1 = (float)(p.oz + p.sz) * STUD_M;
        // UV2 is the PIECE's size, so the seam shader outlines a 2x4 as one
        // 2x4 -- not as a grid of eight 1x1s. That is the difference between
        // laid brick and a moulded baseplate, and the reason the mesher packs.
        const Vector2 face((float)p.sx * STUD_M, (float)p.sz * STUD_M);
        // ...and of a brick across a tile edge, the WHOLE brick's size, with
        // UV this part's place in it: each tile draws its part and the seam
        // shader still outlines one brick, with no line at the tile edge.
        const float bx0 = (float)p.brick_x() * STUD_M, bz0 = (float)p.brick_z() * STUD_M;
        const float bx1 = bx0 + (float)p.brick_sx() * STUD_M, bz1 = bz0 + (float)p.brick_sz() * STUD_M;
        const Vector2 bface(bx1 - bx0, bz1 - bz0);
        const Vector2 uv0(x0 - bx0, z0 - bz0);

        if (p.kind == PIECE_SLOPE) {
            emit_slope(m, s, p, col);
        } else if (p.kind == PIECE_RAMP) {
            const float lo = top - BRICK_M;
            float y00 = top, y10 = top, y11 = top, y01 = top;
            switch (p.ramp) {
                case 0: y00 = lo; y01 = lo; break;
                case 1: y10 = lo; y11 = lo; break;
                case 2: y00 = lo; y10 = lo; break;
                default: y01 = lo; y11 = lo; break;
            }
            const Vector3 a(x0, y00, z0), b(x1, y10, z0);
            const Vector3 c(x1, y11, z1), d(x0, y01, z1);
            Vector3 n = (c - a).cross(d - b).normalized();
            if (n.y < 0.0f) {
                n = -n;
            }
            // SQUARE all round: no neighbour bevels back against a tilted
            // top, so a chamfer here was a slit with nothing behind it.
            m.quad(n, col, face, a, b, c, d,
                Vector2(0, 0), Vector2(face.x, 0), face, Vector2(0, face.y), 0, 0xF);
        } else if (p.overlay != 0) {
            // The overlay's top, one plate up. The brick's own top is NOT
            // emitted: it is covered exactly, so it is culled.
            const float oy = top + OVERLAY_M;
            // The overlay's top and lips: its one-plate brick's box.
            const bool boxed = p.kind == PIECE_BRICK || p.kind == PIECE_TILE;
            if (boxed) {
                m.facet = BOXED_FACE;
                // Its top and four lips, as the faces this tile draws of it.
                const int bx = gx0 + p.brick_x(), bz = gz0 + p.brick_z();
                const int ax0 = gx0 + p.ox, ax1 = gx0 + p.ox + p.sx;
                const int az0 = gz0 + p.oz, az1 = gz0 + p.oz + p.sz;
                const int lp = p.top + 1;
                note_face(bx, bz, lp, 2, ax0, az0, ax1, az1);
                note_face(bx, bz, lp, 1, az0, lp, az1, lp + 1);
                note_face(bx, bz, lp, 0, az0, lp, az1, lp + 1);
                note_face(bx, bz, lp, 5, ax0, lp, ax1, lp + 1);
                note_face(bx, bz, lp, 4, ax0, lp, ax1, lp + 1);
            }
            // The top's bevel runs down onto the overlay's OWN lip walls
            // (always drawn), so it needs nobody else; the lips are square.
            m.quad(Vector3(0, 1, 0), col, bface,
                Vector3(x0, oy, z0), Vector3(x1, oy, z0),
                Vector3(x1, oy, z1), Vector3(x0, oy, z1),
                uv0, uv0 + Vector2(face.x, 0), uv0 + face, uv0 + Vector2(0, face.y));
            const uint8_t LIP_SQ = 0xF;
            // V runs UP the lip, as up every other side: the shader finds a
            // face's brick from UV (terrain.gdshader overlay_holes).
            // The lip: four one-plate walls round the overlay, always drawn,
            // because a neighbour at the same brick height still sits a plate
            // lower unless it carries an overlay too.
            const float lb = top;
            const Vector2 lip(face.x, OVERLAY_M);
            const Vector2 lip_z(face.y, OVERLAY_M);
            m.quad(Vector3(0, 0, -1), col, lip,
                Vector3(x0, lb, z0), Vector3(x1, lb, z0),
                Vector3(x1, oy, z0), Vector3(x0, oy, z0),
                Vector2(0, 0), Vector2(lip.x, 0), Vector2(lip.x, lip.y), Vector2(0, lip.y), 0, LIP_SQ);
            m.quad(Vector3(0, 0, 1), col, lip,
                Vector3(x1, lb, z1), Vector3(x0, lb, z1),
                Vector3(x0, oy, z1), Vector3(x1, oy, z1),
                Vector2(0, 0), Vector2(lip.x, 0), Vector2(lip.x, lip.y), Vector2(0, lip.y), 0, LIP_SQ);
            m.quad(Vector3(-1, 0, 0), col, lip_z,
                Vector3(x0, lb, z1), Vector3(x0, lb, z0),
                Vector3(x0, oy, z0), Vector3(x0, oy, z1),
                Vector2(0, 0), Vector2(lip_z.x, 0), Vector2(lip_z.x, lip_z.y), Vector2(0, lip_z.y), 0, LIP_SQ);
            m.quad(Vector3(1, 0, 0), col, lip_z,
                Vector3(x1, lb, z0), Vector3(x1, lb, z1),
                Vector3(x1, oy, z1), Vector3(x1, oy, z0),
                Vector2(0, 0), Vector2(lip_z.x, 0), Vector2(lip_z.x, lip_z.y), Vector2(0, lip_z.y), 0, LIP_SQ);
            if (boxed) {
                m.facet = 0;
            }
        } else {
            // A side is convex where the ground DROPS AWAY, because that is
            // where a wall face exists for the chamfer to meet. Level with a
            // neighbour, or under one, it is coplanar or concave, and there
            // the two half-facets close the groove between them.
            uint8_t convex = 0;
            uint8_t square = 0;
            bool lo_zm = false, lo_zp = false, lo_xm = false, lo_xp = false;
            bool hi_zm = false, hi_zp = false, hi_xm = false, hi_xp = false;
            // A LEVEL neighbour closes the groove only if it bevels back: a
            // plain brick or tile in this tile with no overlay. Anything else
            // -- an overlay's lip, a slope, a ramp, curved ground, a column
            // in the next tile whose pieces this tile cannot see -- leaves our
            // half-groove a slit down to nothing, which is the see-through-
            // the-world gap. Such an edge is SQUARE: the user's rule, "only
            // chamfer where the brick beside it chamfers too".
            auto partner = [&](int nlx, int nlz) -> bool {
                if (nlx < 0 || nlz < 0 || nlx >= TILE || nlz >= TILE) {
                    return false;
                }
                const int i = TileSample::idx(nlx, nlz);
                if (s.smooth[i] || s.ramp[i] != 255 || (!s.sl_r.empty() && s.sl_r[i] != 255)) {
                    return false;
                }
                const int32_t o = owner[(size_t)nlx + TILE * nlz];
                if (o < 0) {
                    return false;
                }
                const Piece &q = pieces[(size_t)o];
                return q.kind != PIECE_SLOPE && q.kind != PIECE_RAMP && q.overlay == 0;
            };
            bool lv_zm = false, lv_zp = false, lv_xm = false, lv_xp = false;
            // Any column along the edge level with this one (partner or not).
            bool eq_zm = false, eq_zp = false, eq_xm = false, eq_xp = false;
            for (int dx2 = 0; dx2 < p.sx; ++dx2) {
                const int16_t a2 = s.tp[TileSample::idx(p.ox + dx2, p.oz - 1)];
                const int16_t b2 = s.tp[TileSample::idx(p.ox + dx2, p.oz + p.sz)];
                if (a2 < p.top) lo_zm = true;
                if (b2 < p.top) lo_zp = true;
                if (a2 > p.top) hi_zm = true;
                if (b2 > p.top) hi_zp = true;
                if (a2 == p.top && !partner(p.ox + dx2, p.oz - 1)) lv_zm = true;
                if (b2 == p.top && !partner(p.ox + dx2, p.oz + p.sz)) lv_zp = true;
                if (a2 == p.top) eq_zm = true;
                if (b2 == p.top) eq_zp = true;
            }
            for (int dz2 = 0; dz2 < p.sz; ++dz2) {
                const int16_t a2 = s.tp[TileSample::idx(p.ox - 1, p.oz + dz2)];
                const int16_t b2 = s.tp[TileSample::idx(p.ox + p.sx, p.oz + dz2)];
                if (a2 < p.top) lo_xm = true;
                if (b2 < p.top) lo_xp = true;
                if (a2 > p.top) hi_xm = true;
                if (b2 > p.top) hi_xp = true;
                if (a2 == p.top && !partner(p.ox - 1, p.oz + dz2)) lv_xm = true;
                if (b2 == p.top && !partner(p.ox + p.sx, p.oz + dz2)) lv_xp = true;
                if (a2 == p.top) eq_xm = true;
                if (b2 == p.top) eq_xp = true;
            }
            if (lv_zm) square |= 1u;
            if (lv_xp) square |= 2u;
            if (lv_zp) square |= 4u;
            if (lv_xm) square |= 8u;
            // A HIGHER neighbour is an inside corner: a wall standing on this
            // floor. Bevelling there cut a slot along the foot of every wall.
            if (hi_zm) square |= 1u;
            if (hi_xp) square |= 2u;
            if (hi_zp) square |= 4u;
            if (hi_xm) square |= 8u;
            // Corners are (x0,z0) (x1,z0) (x1,z1) (x0,z1), so edge 0 faces
            // -Z, edge 1 faces +X, edge 2 faces +Z, edge 3 faces -X.
            if (lo_zm) convex |= 1u;
            if (lo_xp) convex |= 2u;
            if (lo_zp) convex |= 4u;
            if (lo_xm) convex |= 8u;
            {
                // TOP EDGES ONLY.
                //
                // Every artefact in six rounds came from a facet having to
                // agree with one drawn by somebody else -- the greedy mask,
                // a neighbouring piece, or unmeshed space. The four top edges
                // of a piece meet the piece's OWN side faces, which it now
                // draws itself (section 17.23), so there is no second party.
                //
                // The top is emitted coplanar on all four edges, which is the
                // half-facet case: level neighbours meet in the groove
                // between them, and at a drop the strip runs down onto this
                // piece's own side face. The sides themselves are SQUARE --
                // no bevel, nothing to negotiate.
                //
                // On a floor seen at a grazing angle the top edge is the only
                // one that reads, which is where this started.
                //
                // Its top and sides (below): its brick's box.
                const bool boxed = p.kind == PIECE_BRICK || p.kind == PIECE_TILE;
                if (boxed) {
                    m.facet = BOXED_FACE;
                }
                m.quad(Vector3(0, 1, 0), col, bface,
                    Vector3(x0, top, z0), Vector3(x1, top, z0),
                    Vector3(x1, top, z1), Vector3(x0, top, z1),
                    uv0, uv0 + Vector2(face.x, 0), uv0 + face, uv0 + Vector2(0, face.y));
                if (boxed) {
                    m.facet = 0;
                }
                // ...and its own sides, so a brick's side seam is the same
                // brick as its top. Only where the ground drops away; level
                // with a neighbour the face is interior. SQUARE: the top's
                // strip already runs down onto them.
                const float yb = top - BRICK_M;
                // One side, from corner ka to corner kb (wound as before).
                // `u0`: where along the BRICK's side this side starts, and
                // `blen` that side's length (a part of a brick across a tile
                // edge outlines as the whole brick).
                const auto side = [&](const Vector3 &n, int ka, int kb, float xa, float za,
                        float xb, float zb, float yt, float u0, float blen) {
                    const Vector3 dir = Vector3(xb - xa, 0.0f, zb - za).normalized();
                    const float len = std::fabs(xb - xa) + std::fabs(zb - za);
                    (void)ka;
                    (void)kb;
                    const float sa = 0.0f, sb = 0.0f;
                    const Vector3 pa = Vector3(xa, 0.0f, za) + dir * sa;
                    const Vector3 pb = Vector3(xb, 0.0f, zb) - dir * sb;
                    const Vector2 f(blen, BRICK_M);
                    const auto at = [](const Vector3 &q, float y) { return Vector3(q.x, y, q.z); };
                    // One brick tall, on the piece's brick: its box covers it.
                    if (boxed) {
                        m.facet = BOXED_FACE;
                        // What of the brick's side this draws (note_face's axes).
                        const int sxa = gx0 + (int)std::lround(xa / STUD_M), sxb = gx0 + (int)std::lround(xb / STUD_M);
                        const int sza = gz0 + (int)std::lround(za / STUD_M), szb = gz0 + (int)std::lround(zb / STUD_M);
                        const int f = face_index((int)n.x, 0, (int)n.z);
                        const int pb0 = p.top - (PLATES_PER_CELL - 1);
                        if (n.x != 0.0f) {
                            note_face(gx0 + p.brick_x(), gz0 + p.brick_z(), pb0, f, std::min(sza, szb),
                                    pb0, std::max(sza, szb), p.top + 1);
                        } else {
                            note_face(gx0 + p.brick_x(), gz0 + p.brick_z(), pb0, f, std::min(sxa, sxb),
                                    pb0, std::max(sxa, sxb), p.top + 1);
                        }
                    }
                    m.quad(n, col, f, at(pa, yb), at(pb, yb), at(pb, yt), at(pa, yt),
                        Vector2(u0 + sa, 0), Vector2(u0 + len - sb, 0), Vector2(u0 + len - sb, f.y),
                        Vector2(u0 + sa, f.y), 0, 0xF);
                    if (boxed) {
                        m.facet = 0;
                    }
                };
                if (lo_xm) {
                    side(Vector3(-1, 0, 0), 3, 0, x0, z1, x0, z0, top,
                            bz1 - z1, bface.y);
                }
                if (lo_xp) {
                    side(Vector3(1, 0, 0), 1, 2, x1, z0, x1, z1, top,
                            z0 - bz0, bface.y);
                }
                if (lo_zm) {
                    side(Vector3(0, 0, -1), 0, 1, x0, z0, x1, z0, top,
                            x0 - bx0, bface.x);
                }
                if (lo_zp) {
                    side(Vector3(0, 0, 1), 2, 3, x1, z1, x0, z1, top,
                            bx1 - x1, bface.x);
                }
            }
        }
    }

    // Every face the surface packer did not draw: terrace sides, cave roofs,
    // overhang undersides, crater walls. Section 17.2 -- this is the pass
    // that makes the world volumetric rather than a skin.
    PackedFloat32Array cave_studs;
    int cave_stud_count = 0;
    mask_faces(m, s, owner, pieces, g_field.seed, cave_studs, cave_stud_count);
    std::vector<uint8_t> behind;
    const bool behind_baked = behind_tile(tx, tz) && t_bricks != nullptr;
    if (behind_baked) {
        behind_faces(m, s, !pieces.empty(), behind);
    }
    struct BehindReset { ~BehindReset() { t_behind = nullptr; } } behind_reset;

    // --- scatter (section 8), then studs (section 7.2 tier 0) -------------
    //
    // Scatter goes FIRST, because a rock sitting on the ground hides the
    // studs under it. Emitting studs first and scatter second drew studs
    // poking through boulders.
    //
    // A scatter piece is sized in STUDS and may span several of them, so it
    // crosses brick outlines the way a real thing dropped on a floor does --
    // it has no idea which brick it landed on and should not look like it
    // does.
    PackedFloat32Array studs;
    PackedFloat32Array tufts;
    PackedFloat32Array pebbles;
    PackedFloat32Array bricks;
    int stud_count = 0;
    int scatter_count = 0;
    int brick_count = 0;

    std::vector<uint8_t> blocked((size_t)TILE * TILE, 0);

    // BRICKS POKING OUT OF CURVED GROUND (Terrain.md 18.7). Curved ground has
    // no pieces, so a hillside of it is plastic with no bricks in it at all;
    // a few laid bricks half in the slope say what the world is made of, the
    // way LEGO games dress smooth ground. Each is its OWN instance on the
    // stud grid -- not cells of the ground -- which is also what a patch on a
    // planet has to be (Planets.md 9.4).
    //
    // Level, its top a plate over the highest ground under it, and as deep
    // as it must be to reach the lowest: buried uphill, standing proud
    // downhill, never floating. Studs on top, from the stud buffer; one in
    // four gets a 2x2 stacked on it. No collision, like scatter.
    if (g_smooth_terrain && g_curve_bricks > 0.0f) {
        auto all_curve = [&](int lx, int lz, int w, int d) {
            if (lx + w > TILE || lz + d > TILE) {
                return false;
            }
            for (int dz = 0; dz < d; ++dz) {
                for (int dx = 0; dx < w; ++dx) {
                    if (blocked[(size_t)(lx + dx) + TILE * (lz + dz)]
                            || !s.smooth[TileSample::idx(lx + dx, lz + dz)]) {
                        return false;
                    }
                }
            }
            return true;
        };
        auto lay = [&](int lx, int lz, int w, int d, float top, float bottom, const Color &c) {
            push_box_instance(bricks, ((float)lx + (float)w * 0.5f) * STUD_M,
                    (top + bottom) * 0.5f, ((float)lz + (float)d * 0.5f) * STUD_M, c,
                    (float)w, (top - bottom) / BRICK_M, (float)d);
            for (int dz = 0; dz < d; ++dz) {
                for (int dx = 0; dx < w; ++dx) {
                    push_stud(studs, ((float)(lx + dx) + 0.5f) * STUD_M, top,
                            ((float)(lz + dz) + 0.5f) * STUD_M, c);
                    ++stud_count;
                }
            }
            ++brick_count;
        };
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                const int i = TileSample::idx(lx, lz);
                if (!s.smooth[i] || s.mat[i] == MAT_ROAD || material_is_farmland(s.mat[i])) {
                    continue;
                }
                const int gx = gx0 + lx;
                const int gz = gz0 + lz;
                if (hashf(gx, gz, 0xB51C) >= g_curve_bricks) {
                    continue;
                }
                const float r = hashf(gx, gz, 0xB52D);
                int w = 2, d = r < 0.4f ? 2 : 4;
                if (hashf(gx, gz, 0xB53E) < 0.5f) {
                    std::swap(w, d);
                }
                if (!all_curve(lx, lz, w, d)) {
                    if (!all_curve(lx, lz, 2, 2)) {
                        continue;
                    }
                    w = d = 2;
                }
                // The drawn ground at the brick's corners and middle.
                float hi = -1e9f, lo = 1e9f;
                for (int cz = lz; cz <= lz + d; ++cz) {
                    for (int cx = lx; cx <= lx + w; ++cx) {
                        const float y = corner_y(cx, cz);
                        hi = std::max(hi, y);
                        lo = std::min(lo, y);
                    }
                }
                const float top = hi + PLATE_M;
                const float bottom = std::min(top - BRICK_M, lo - PLATE_M);
                Color c = piece_colour(s, lx, lz, s.mat[i], true);
                c.a = 1.0f;
                lay(lx, lz, w, d, top, bottom, c);
                if (hashf(gx, gz, 0xB54F) < 0.25f) {
                    lay(lx + (w - 2) / 2, lz + (d - 2) / 2, 2, 2, top + BRICK_M, top, c);
                }
                for (int dz = 0; dz < d; ++dz) {
                    for (int dx = 0; dx < w; ++dx) {
                        blocked[(size_t)(lx + dx) + TILE * (lz + dz)] = 1;
                    }
                }
            }
        }
    }

    // Does an n x n footprint at (lx, lz) sit on one flat, plate, unoccupied
    // patch? A boulder half on a terrace edge would float.
    auto footprint_ok = [&](int lx, int lz, int n) {
        if (lx + n > TILE || lz + n > TILE) {
            return false;
        }
        const int h0 = s.h[TileSample::idx(lx, lz)];
        for (int dz = 0; dz < n; ++dz) {
            for (int dx = 0; dx < n; ++dx) {
                if (blocked[(size_t)(lx + dx) + TILE * (lz + dz)]) {
                    return false;
                }
                const int i = TileSample::idx(lx + dx, lz + dz);
                if (s.plate[i] == 0 || s.h[i] != h0) {
                    return false;
                }
                const int32_t o = owner[(size_t)(lx + dx) + TILE * (lz + dz)];
                // A studded brick, or curved ground -- which has no piece at
                // all and was therefore refusing every boulder and every
                // tuft on it. Scatter went from 492 to 146 the moment curves
                // were switched on, and nothing said so; it is the kind of
                // loss that hides as "the terrain changed".
                //
                // Tiles and ramps still refuse: a smooth tile has nothing to
                // clip to, and a ramp is not flat.
                const bool ok = o >= 0 ? pieces[o].kind == PIECE_BRICK
                                       : s.smooth[i] != 0;
                if (!ok) {
                    return false;
                }
            }
        }
        return true;
    };

    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            if (blocked[(size_t)lx + TILE * lz]) {
                continue;
            }
            const int i = TileSample::idx(lx, lz);
            if (s.plate[i] == 0 || s.mat[i] == MAT_ROAD || material_is_farmland(s.mat[i])) {
                continue;
            }
            const int gx = gx0 + lx;
            const int gz = gz0 + lz;
            // One in 22 eligible cells. Lower than the old one in 16 because
            // the pieces are bigger now and cover more ground each.
            if (hashf(gx, gz, 0x5CA7) >= 1.0f / 22.0f) {
                continue;
            }
            const float sr = hashf(gx, gz, 0x512E);
            int n = sr < 0.52f ? 1 : (sr < 0.84f ? 2 : 3);
            while (n > 1 && !footprint_ok(lx, lz, n)) {
                --n;
            }
            if (!footprint_ok(lx, lz, n)) {
                continue;
            }

            const int32_t o = owner[(size_t)lx + TILE * lz];
            const float base = (o < 0 && g_smooth_terrain && s.smooth[i])
                    ? cell_surface(lx, lz)
                    : (float)(s.tp[i] + 1) * PLATE_M
                      + (o >= 0 && pieces[o].overlay != 0 ? OVERLAY_M : 0.0f);
            for (int dz = 0; dz < n; ++dz) {
                for (int dx = 0; dx < n; ++dx) {
                    blocked[(size_t)(lx + dx) + TILE * (lz + dz)] = 1;
                }
            }

            // Centred on the whole footprint, not on the first cell, so a
            // 2x2 boulder straddles the four studs it covers.
            const float px = ((float)lx + (float)n * 0.5f) * STUD_M;
            const float pz = ((float)lz + (float)n * 0.5f) * STUD_M;
            // One of the eight grid-legal yaws, same as a placed part gets.
            const float yaw = (float)(Math_TAU *
                (double)(hash3(gx, gz, 0x1AE) % 8U) / 8.0);
            const float g = piece_tint(g_field.seed, gx, gz);
            if (s.mat[i] == MAT_GRASS && n == 1) {
                push_instance(tufts, px, base, pz, yaw,
                    Color(0.24f * g, 0.52f * g, 0.22f * g, 1.0f), 1.0f, 1.0f);
            } else {
                // Rocks come out of the filament palette like everything
                // else, so a boulder and a brick printed in the same colour
                // ARE the same colour. A hand-mixed grey read as chalk-white
                // next to ground that was using the palette properly.
                const float pick = hashf(gx, gz, 0x80C5);
                const int fil = pick < 0.45f ? FIL_DARK_GREY
                        : (pick < 0.80f ? FIL_GREY : FIL_BROWN);
                Color rc = filament_colour(fil);
                // Height grows far more slowly than width.
                const float sy = 0.75f + 0.15f * (float)n;
                push_instance(pebbles, px, base, pz, yaw,
                    Color(rc.r * g, rc.g * g, rc.b * g, 1.0f), (float)n, sy);
            }
            ++scatter_count;
        }
    }

    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            if (blocked[(size_t)lx + TILE * lz]) {
                continue;   // something is standing here
            }
            const int32_t o = owner[(size_t)lx + TILE * lz];
            const int i = TileSample::idx(lx, lz);
            if (o < 0 && s.smooth[i]) {
                // Curved ground takes studs on its FLAT spots and nowhere
                // else -- which is what `plate` already means, and is the
                // original idea from section 4: curves, with studs standing
                // out of them where the ground levels off. A flat cell's
                // four corners are all at its own height, so the stud sits
                // exactly on the surface and not near it.
                // Some flat patches of a curve are laid SMOOTH, the same
                // one-in-five the packer tiles a brick floor with and off
                // the same hash, so a curve gets the same mix of studded
                // and smooth ground that laid brick does. A curve has no
                // pieces to be a tile, so a tile here is simply a cell that
                // takes no stud.
                const bool tiled = hashf(gx0 + lx, gz0 + lz,
                        (int32_t)(g_field.seed ^ 0x7113U)) < TILE_CHANCE;
                // On "slopes" ground (18.7) studs are SCATTERED: one flat cell
                // in eight, and flat means the drawn curve is level there --
                // `plate` only says the four columns are on one plate, which
                // on gentle curved ground is most of it, and a stud on every
                // such cell drew terraces of studs across the hills.
                bool scattered = true;
                if (g_smooth_slopes) {
                    const float c0 = corner_y(lx, lz), c1 = corner_y(lx + 1, lz);
                    const float c2 = corner_y(lx + 1, lz + 1), c3 = corner_y(lx, lz + 1);
                    const float spread = std::max(std::max(c0, c1), std::max(c2, c3))
                            - std::min(std::min(c0, c1), std::min(c2, c3));
                    scattered = spread < PLATE_M * 0.25f
                            && hashf(gx0 + lx, gz0 + lz, 0x57D5) < CURVE_STUD_CHANCE;
                }
                if (s.plate[i] && !tiled && scattered && material_studded(s.mat[i])) {
                    Color c = piece_colour(s, lx, lz, s.mat[i], true);
                    c.a = 1.0f;
                    // On the CURVE's own surface. The column top is up to
                    // half a plate away from it now that the curve follows
                    // the unquantised field, and a stud floating 7 cm over
                    // the ground is the first thing anyone would notice.
                    push_stud(studs, ((float)lx + 0.5f) * STUD_M,
                        cell_surface(lx, lz),
                        ((float)lz + 0.5f) * STUD_M, c);
                    ++stud_count;
                }
                continue;
            }
            // A stud belongs to a PIECE, not to a cell: a tile, a ramp and a
            // smooth overlay are studless however flat the cell under them
            // is, and asking the piece is the only way to know which this is.
            if (o < 0 || pieces[o].studded == 0) {
                continue;
            }
            const float y = (float)(s.tp[i] + 1) * PLATE_M
                    + (pieces[o].overlay != 0 ? OVERLAY_M : 0.0f);
            // The colour of the piece it stands on, so a stud can never
            // disagree with its brick (section 7.3).
            Color c = piece_colour(s, pieces[o].ox, pieces[o].oz, pieces[o].mat, true);
            c.a = 1.0f;
            push_stud(studs, ((float)lx + 0.5f) * STUD_M, y,
                ((float)lz + 0.5f) * STUD_M, c, pieces[o].mat);
            ++stud_count;
        }
    }

    studs.append_array(cave_studs);
    stud_count += cave_stud_count;
    Dictionary sky;
    sky_light_pass(m, s, true, sky, &studs);
    t_behind = nullptr;
    const Array behind_mesh = split_behind(m);

    // No edge skirt on the detail tiles (19.18): the detail square always
    // surrounds the camera, so a skirt facing out of it is never seen, and
    // the coarse tier's own skirts face back in to cover every border.

    Array mesh;
    if (!m.verts.is_empty()) {
        mesh.resize(Mesh::ARRAY_MAX);
        mesh[Mesh::ARRAY_VERTEX] = m.verts;
        mesh[Mesh::ARRAY_NORMAL] = m.normals;
        mesh[Mesh::ARRAY_COLOR] = m.colours;
        mesh[Mesh::ARRAY_TEX_UV] = m.uvs;
        mesh[Mesh::ARRAY_TEX_UV2] = m.uv2s;
        mesh[Mesh::ARRAY_INDEX] = m.indices;
        mesh[Mesh::ARRAY_CUSTOM0] = m.custom0;
    }

    Dictionary out = sky;
    out["mesh"] = mesh;
    out["behind_mesh"] = behind_mesh;
    out["behind_baked"] = behind_baked;
    out["behind_cells_ms"] = t_behind_cells_ms;
    out["behind_mask_ms"] = t_behind_mask_ms;
    // The bricks it drew a face of (Docs/BrickOverlay.md).
    out["overlay_bricks"] = bricks_floats(overlay);
    t_bricks = nullptr;
    out["studs"] = studs;
    out["stud_stride"] = stud_stride();
    out["tufts"] = tufts;
    out["pebbles"] = pebbles;
    out["bricks"] = bricks;
    out["brick_count"] = brick_count;
    out["boxes"] = boxes;
    out["box_count"] = boxes.size() / 6;
    out["cave_box_count"] = cave_boxes;
    out["piece_count"] = (int)pieces.size();
    out["triangle_count"] = m.indices.size() / 3;
    // Cells drawn as a curve, and cells owned by a piece. They must add up
    // to the tile EXACTLY: one top surface a cell, no cell drawn twice (two
    // surfaces in the same place is z-fighting) and none left undrawn (a
    // hole). The invariant is cheap and it is the one a mixed surface can
    // break silently.
    int owned_cells = 0;
    for (int i = 0; i < TILE * TILE; ++i) {
        if (owner[(size_t)i] >= 0) {
            ++owned_cells;
        }
    }
    out["curve_cells"] = curve_cells;
    out["owned_cells"] = owned_cells;
    out["stud_count"] = stud_count;
    out["scatter_count"] = scatter_count;
    out["build_ms"] = (double)(Time::get_singleton()->get_ticks_usec() - t0) / 1000.0;
    return out;
}

// --- the audit (probes; Docs/MineWorld.md 20) ----------------------------------------
//
// Is every face of an owned solid cell that open air can see covered by a
// triangle of the FLAT mesh (the far one; the chamfered one is
// bevel_gap_probe's), and does no collider box hold open air? Both are the
// field against what build_tile hands out, so a mesher or collider shortcut
// that leaves a face out ("see-through") or collides where nothing is drawn
// ("an invisible wall") shows as a count.
Dictionary BrickTerrain::audit_tile(int tx, int tz, int sy) {
    TileSample s;
    Dictionary d;
    const bool section = sy != INT32_MIN;
    if (section) {
        if (!sample_section(tx, sy, tz, s)) {
            return Dictionary();
        }
        d = build_section(tx, sy, tz);
    } else {
        sample_tile(g_field, tx, tz, s);
        d = build_tile(tx, tz);
    }

    // Unit faces the mesh covers: (axis, sign, plane, u, v) in cells.
    auto fkey = [](int axis, int sgn, int plane, int u, int v) -> int64_t {
        return ((int64_t)(axis * 2 + (sgn > 0 ? 1 : 0)) << 56)
                | ((int64_t)(plane + 4096) << 40) | ((int64_t)(u + 4096) << 24)
                | (int64_t)(v + (1 << 23));
    };
    std::set<int64_t> covered;
    const Array mesh = d.get("mesh", Array());
    if (mesh.size() > Mesh::ARRAY_INDEX) {
        const PackedVector3Array verts = mesh[Mesh::ARRAY_VERTEX];
        const PackedVector3Array norms = mesh[Mesh::ARRAY_NORMAL];
        const PackedInt32Array idx = mesh[Mesh::ARRAY_INDEX];
        for (int t = 0; t + 2 < idx.size(); t += 3) {
            const Vector3 a = verts[idx[t]], b = verts[idx[t + 1]], c = verts[idx[t + 2]];
            const Vector3 n = norms[idx[t]];
            int axis = 0;
            float big = std::fabs(n.x);
            if (std::fabs(n.y) > big) { axis = 1; big = std::fabs(n.y); }
            if (std::fabs(n.z) > big) { axis = 2; big = std::fabs(n.z); }
            if (big < 0.99f) {
                continue;
            }
            const int sgn = n[axis] > 0.0f ? 1 : -1;
            const int ua = axis == 0 ? 2 : 0;
            const int va = axis == 1 ? 2 : 1;
            const float ps = axis == 1 ? PLATE_M : STUD_M;
            const float us = STUD_M;
            const float vs = axis == 1 ? STUD_M : PLATE_M;
            const float pf = a[axis] / ps;
            const int plane = (int)std::lround(pf);
            if (std::fabs(pf - (float)plane) > 1e-3f) {
                continue;   // off the grid (a skirt, a lip's foot)
            }
            const float au = a[ua] / us, av = a[va] / vs;
            const float bu = b[ua] / us, bv = b[va] / vs;
            const float cu = c[ua] / us, cv = c[va] / vs;
            const int u0 = (int)std::floor(std::min({ au, bu, cu }));
            const int u1 = (int)std::ceil(std::max({ au, bu, cu }));
            const int v0 = (int)std::floor(std::min({ av, bv, cv }));
            const int v1 = (int)std::ceil(std::max({ av, bv, cv }));
            const float area = (bu - au) * (cv - av) - (cu - au) * (bv - av);
            if (std::fabs(area) < 1e-6f) {
                continue;
            }
            for (int v = v0; v < v1; ++v) {
                for (int u = u0; u < u1; ++u) {
                    const float pu = (float)u + 0.5f, pv = (float)v + 0.5f;
                    const float w0 = ((bu - pu) * (cv - pv) - (cu - pu) * (bv - pv)) / area;
                    const float w1 = ((cu - pu) * (av - pv) - (au - pu) * (cv - pv)) / area;
                    const float w2 = 1.0f - w0 - w1;
                    if (w0 >= -1e-4f && w1 >= -1e-4f && w2 >= -1e-4f) {
                        covered.insert(fkey(axis, sgn, plane, u, v));
                    }
                }
            }
        }
    }

    static const int DIRS[6][3] = {
        { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 }
    };
    int exposed = 0, undrawn = 0;
    PackedInt32Array undrawn_dir;
    undrawn_dir.resize(6);
    for (int k = 0; k < 6; ++k) {
        undrawn_dir[k] = 0;
    }
    Array examples;
    const int lo = s.lo_owned(), hi = s.hi_owned();
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            for (int yp = lo; yp < hi; ++yp) {
                if (!s.solid(lx, yp, lz)) {
                    continue;
                }
                for (int k = 0; k < 6; ++k) {
                    const int dx = DIRS[k][0], dy = DIRS[k][1], dz = DIRS[k][2];
                    if (s.solid(lx + dx, yp + dy, lz + dz) || !s.open_air(lx + dx, yp + dy, lz + dz)) {
                        continue;
                    }
                    ++exposed;
                    bool ok;
                    if (dx != 0) {
                        ok = covered.count(fkey(0, dx, lx + (dx > 0 ? 1 : 0), lz, yp)) > 0;
                    } else if (dz != 0) {
                        ok = covered.count(fkey(2, dz, lz + (dz > 0 ? 1 : 0), lx, yp)) > 0;
                    } else if (dy < 0) {
                        ok = covered.count(fkey(1, -1, yp, lx, lz)) > 0;
                    } else {
                        // An overlay is drawn a plate up, over its brick.
                        ok = covered.count(fkey(1, 1, yp + 1, lx, lz)) > 0
                                || covered.count(fkey(1, 1, yp + 2, lx, lz)) > 0;
                    }
                    if (!ok) {
                        ++undrawn;
                        undrawn_dir[k] = undrawn_dir[k] + 1;
                        if (examples.size() < 12) {
                            examples.push_back(Vector4i(tx * TILE + lx, yp, tz * TILE + lz, k));
                        }
                    }
                }
            }
        }
    }

    const PackedFloat32Array boxes = d.get("boxes", PackedFloat32Array());
    const int nbox = boxes.size() / 6;
    const int ncave = (int)d.get("cave_box_count", 0);
    const int ntop = nbox - ncave;
    int air_top = 0, air_cave = 0;
    Array air_examples;
    for (int b = 0; b < nbox; ++b) {
        const int o = b * 6;
        const float cx = boxes[o], cyy = boxes[o + 1], cz = boxes[o + 2];
        const float hx = boxes[o + 3] * 0.5f, hy = boxes[o + 4] * 0.5f, hz = boxes[o + 5] * 0.5f;
        const int x0 = (int)std::ceil((cx - hx) / STUD_M - 0.5f + 1e-3f);
        const int x1 = (int)std::floor((cx + hx) / STUD_M - 0.5f - 1e-3f);
        const int z0 = (int)std::ceil((cz - hz) / STUD_M - 0.5f + 1e-3f);
        const int z1 = (int)std::floor((cz + hz) / STUD_M - 0.5f - 1e-3f);
        const int y0p = (int)std::ceil((cyy - hy) / PLATE_M - 0.5f + 1e-3f);
        const int y1p = (int)std::floor((cyy + hy) / PLATE_M - 0.5f - 1e-3f);
        for (int lz = z0; lz <= z1; ++lz) {
            for (int lx = x0; lx <= x1; ++lx) {
                if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN || lz >= TILE + MARGIN) {
                    continue;
                }
                // Over the column's top is the sky (a lip or an overlay's
                // box reaching a plate up); under it is what a cave is.
                const int top = s.tp[TileSample::idx(lx, lz)];
                for (int yp = y0p; yp <= y1p && yp < top; ++yp) {
                    if (!s.in_y(yp) || s.solid(lx, yp, lz) || !s.open_air(lx, yp, lz)) {
                        continue;
                    }
                    if (b < ntop) {
                        ++air_top;
                    } else {
                        ++air_cave;
                    }
                    if (air_examples.size() < 12) {
                        air_examples.push_back(Vector4i(tx * TILE + lx, yp, tz * TILE + lz,
                                b < ntop ? 0 : 1));
                    }
                }
            }
        }
    }
    // ...and the other way round: every owned solid cell open air touches is
    // inside some box, or a walker falls through what is drawn.
    const int ny = std::max(hi - lo, 1);
    std::vector<uint8_t> inbox((size_t)TILE * ny * TILE, 0);
    for (int b = 0; b < nbox; ++b) {
        const int o = b * 6;
        const float cx = boxes[o], cyy = boxes[o + 1], cz = boxes[o + 2];
        const float hx = boxes[o + 3] * 0.5f, hy = boxes[o + 4] * 0.5f, hz = boxes[o + 5] * 0.5f;
        const int x0 = std::max((int)std::ceil((cx - hx) / STUD_M - 0.5f - 1e-3f), 0);
        const int x1 = std::min((int)std::floor((cx + hx) / STUD_M - 0.5f + 1e-3f), TILE - 1);
        const int z0 = std::max((int)std::ceil((cz - hz) / STUD_M - 0.5f - 1e-3f), 0);
        const int z1 = std::min((int)std::floor((cz + hz) / STUD_M - 0.5f + 1e-3f), TILE - 1);
        const int y0p = std::max((int)std::ceil((cyy - hy) / PLATE_M - 0.5f - 1e-3f), lo);
        const int y1p = std::min((int)std::floor((cyy + hy) / PLATE_M - 0.5f + 1e-3f), hi - 1);
        for (int lz = z0; lz <= z1; ++lz) {
            for (int yp = y0p; yp <= y1p; ++yp) {
                for (int lx = x0; lx <= x1; ++lx) {
                    inbox[(size_t)lx + TILE * ((size_t)(yp - lo) + (size_t)ny * lz)] = 1;
                }
            }
        }
    }
    int uncollided = 0;
    Array bare_examples;
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            for (int yp = lo; yp < hi; ++yp) {
                if (!s.solid(lx, yp, lz) || inbox[(size_t)lx + TILE * ((size_t)(yp - lo) + (size_t)ny * lz)]) {
                    continue;
                }
                bool open = false;
                for (int k = 0; k < 6 && !open; ++k) {
                    const int dx = DIRS[k][0], dy = DIRS[k][1], dz = DIRS[k][2];
                    open = !s.solid(lx + dx, yp + dy, lz + dz) && s.open_air(lx + dx, yp + dy, lz + dz);
                }
                if (open) {
                    ++uncollided;
                    if (bare_examples.size() < 12) {
                        bare_examples.push_back(Vector3i(tx * TILE + lx, yp, tz * TILE + lz));
                    }
                }
            }
        }
    }
    // STUDS (Docs/MineWorld.md 20). The top course: how many of its cells
    // show studs (a studded brick, or a studded plate laid on one), and the
    // held bricks -- something stands on their footprint -- that show none.
    // The caves: their topmost bricks' cells (a +Y face the packer did not
    // draw) and how many have a stud instance on them.
    int top_cells = 0, top_studded = 0, held = 0, held_bare = 0;
    std::set<int64_t> cave_cells;
    {
        std::vector<Piece> pieces;
        std::vector<int32_t> owner((size_t)TILE * TILE, -1);
        if (!section) {
            brick::pack_tile(g_field, s, pieces, owner);
        }
        for (const Piece &p : pieces) {
            if (p.kind == PIECE_RAMP || p.kind == PIECE_SLOPE) {
                continue;
            }
            const int n = p.sx * p.sz;
            const bool shows = p.studded != 0 && p.overlay != 1;
            top_cells += n;
            top_studded += shows ? n : 0;
            if (p.held && material_studded(p.mat)) {
                ++held;
                held_bare += shows ? 0 : 1;
            }
        }
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                const int32_t o = owner[(size_t)lx + TILE * lz];
                for (int yp = lo; yp < hi; ++yp) {
                    if (!s.solid(lx, yp, lz) || s.solid(lx, yp + 1, lz) || !s.open_air(lx, yp + 1, lz)) {
                        continue;
                    }
                    if (o >= 0 && pieces[(size_t)o].top == yp) {
                        continue;   // the top course's
                    }
                    if (!material_studded(s.voxel(lx, yp, lz))) {
                        continue;
                    }
                    cave_cells.insert(((int64_t)lx << 40) | ((int64_t)lz << 24) | (int64_t)(yp + (1 << 23)));
                }
            }
        }
    }
    int cave_studded = 0;
    {
        const PackedFloat32Array st = d.get("studs", PackedFloat32Array());
        const int stride = (int)d.get("stud_stride", 16);
        for (int i = 0; i + stride <= st.size(); i += stride) {
            const int lx = (int)std::floor(st[i + 3] / STUD_M);
            const int lz = (int)std::floor(st[i + 11] / STUD_M);
            const int yp = (int)std::lround(st[i + 7] / PLATE_M) - 1;
            if (lx < 0 || lz < 0) {
                continue;
            }
            if (cave_cells.count(((int64_t)lx << 40) | ((int64_t)lz << 24) | (int64_t)(yp + (1 << 23)))) {
                ++cave_studded;
            }
        }
    }
    Dictionary out;
    out["top_cells"] = top_cells;
    out["top_studded"] = top_studded;
    out["held"] = held;
    out["held_bare"] = held_bare;
    out["cave_cells"] = (int)cave_cells.size();
    out["cave_studded"] = cave_studded;
    out["uncollided"] = uncollided;
    out["bare_examples"] = bare_examples;
    out["exposed"] = exposed;
    out["undrawn"] = undrawn;
    out["undrawn_dir"] = undrawn_dir;
    out["examples"] = examples;
    out["box_air_top"] = air_top;
    out["box_air_cave"] = air_cave;
    out["air_examples"] = air_examples;
    out["boxes"] = nbox;
    out["cave_boxes"] = ncave;
    return out;
}

// --- Memory (Docs/TerrainRegions.md 2, A0: terrain_mem_probe) --------------

namespace {
template <typename T> size_t vec_bytes(const std::vector<T> &v) { return v.capacity() * sizeof(T); }

size_t sample_bytes(const brick::TileSample &s) {
    return vec_bytes(s.vox) + vec_bytes(s.open) + vec_bytes(s.h) + vec_bytes(s.tp) + vec_bytes(s.gtp)
            + vec_bytes(s.mat) + vec_bytes(s.col) + vec_bytes(s.sl_r) + vec_bytes(s.sl_len)
            + vec_bytes(s.sl_d) + vec_bytes(s.sl_fall) + vec_bytes(s.plate) + vec_bytes(s.ramp)
            + vec_bytes(s.smooth);
}

/// Runs of one material up each owned column of the tile (margin left out):
/// what a run-length store of the cells would keep (stage A's estimate).
void count_runs(const brick::TileSample &s, int64_t &runs, int64_t &columns, int64_t &solid) {
    const int lo = s.lo_owned();
    const int hi = s.hi_owned();
    for (int lz = 0; lz < brick::TILE; ++lz) {
        for (int lx = 0; lx < brick::TILE; ++lx) {
            int last = -1;
            for (int yp = lo; yp < hi; ++yp) {
                const int m = s.vox[s.vidx(lx, yp, lz)];
                if (m != last) {
                    ++runs;
                    last = m;
                }
                if (m != 0) {
                    ++solid;
                }
            }
            ++columns;
        }
    }
}

Dictionary sample_report(const brick::TileSample &s, uint64_t us) {
    Dictionary d;
    int64_t runs = 0, columns = 0, solid = 0;
    count_runs(s, runs, columns, solid);
    d["ms"] = (double)us / 1000.0;
    d["bytes"] = (int64_t)sample_bytes(s);
    d["vox_bytes"] = (int64_t)(vec_bytes(s.vox) + vec_bytes(s.open));
    d["plates"] = s.hi_owned() - s.lo_owned();
    d["runs"] = runs;
    d["columns"] = columns;
    d["solid_cells"] = solid;
    return d;
}
} // namespace

Dictionary BrickTerrain::memory_stats() {
    Dictionary d;
    {
        std::lock_guard<std::mutex> lk(g_packs.lock);
        int64_t bytes = 0;
        int64_t pieces = 0;
        for (const auto &e : g_packs.tiles) {
            const brick::TilePack &p = *e.second.pack;
            bytes += (int64_t)(sizeof(brick::TilePack) + vec_bytes(p.pieces) + vec_bytes(p.owner) + vec_bytes(p.top));
            bytes += 64;   // the map node, the shared_ptr's control block
            pieces += (int64_t)p.pieces.size();
        }
        d["packs_kept"] = (int64_t)g_packs.tiles.size();
        d["packs_bytes"] = bytes;
        d["packs_pieces"] = pieces;
        d["piece_bytes"] = (int64_t)sizeof(brick::Piece);
    }
    d["edits"] = (int64_t)g_edits.size();
    d["edits_bytes"] = (int64_t)g_edits.bytes();
    return d;
}

Dictionary BrickTerrain::sample_stats(int tx, int tz) {
    brick::TileSample s;
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
    brick::sample_tile(g_field, tx, tz, s);
    return sample_report(s, Time::get_singleton()->get_ticks_usec() - t0);
}

Dictionary BrickTerrain::section_sample_stats(int tx, int sy, int tz) {
    brick::TileSample s;
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();
    if (!sample_section(tx, sy, tz, s)) {
        return Dictionary();
    }
    return sample_report(s, Time::get_singleton()->get_ticks_usec() - t0);
}

void BrickTerrain::_bind_methods() {
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("memory_stats"), &BrickTerrain::memory_stats);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sample_stats", "tx", "tz"), &BrickTerrain::sample_stats);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("section_sample_stats", "tx", "sy", "tz"),
        &BrickTerrain::section_sample_stats);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("audit_tile", "tx", "tz", "sy"),
        &BrickTerrain::audit_tile);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("configure", "world_seed"),
        &BrickTerrain::configure);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_field_version"),
        &BrickTerrain::get_field_version);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_seed"), &BrickTerrain::get_seed);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_brick_metres"),
        &BrickTerrain::get_brick_metres);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_tile_studs"),
        &BrickTerrain::get_tile_studs);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_max_piece_length"),
        &BrickTerrain::get_max_piece_length);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_period"), &BrickTerrain::get_period);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("height_at", "x", "z"),
        &BrickTerrain::height_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("solid_at", "x", "yp", "z"),
        &BrickTerrain::solid_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("surface_plate", "x", "z"),
        &BrickTerrain::surface_plate);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("carve", "world_point", "radius_m"),
        &BrickTerrain::carve);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("clear_terrain_edits"),
        &BrickTerrain::clear_terrain_edits);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_flat_mode", "on"),
        &BrickTerrain::set_flat_mode);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_plate_steps", "on"),
        &BrickTerrain::set_plate_steps);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_plate_steps"),
        &BrickTerrain::get_plate_steps);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_smooth_terrain", "on"),
        &BrickTerrain::set_smooth_terrain);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_smooth_terrain"),
        &BrickTerrain::get_smooth_terrain);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_shelves", "bricks", "share"),
        &BrickTerrain::set_shelves);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_shelves"),
        &BrickTerrain::get_shelves);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_curve_bricks", "share"),
        &BrickTerrain::set_curve_bricks);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_curve_bricks"),
        &BrickTerrain::get_curve_bricks);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_curve_step", "studs"),
        &BrickTerrain::set_curve_step);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_curve_step"),
        &BrickTerrain::get_curve_step);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_smooth_slopes", "on"),
        &BrickTerrain::set_smooth_slopes);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_smooth_slopes"),
        &BrickTerrain::get_smooth_slopes);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_curve_slope", "plates_per_stud"),
        &BrickTerrain::set_curve_slope);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_curve_slope"),
        &BrickTerrain::get_curve_slope);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("paint_form", "x", "z", "radius", "form"),
        &BrickTerrain::paint_form);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("form_at", "x", "z"),
        &BrickTerrain::form_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_form_tile", "tx", "tz"),
        &BrickTerrain::get_form_tile);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_form_tile", "tx", "tz", "bytes"),
        &BrickTerrain::set_form_tile);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("add_pad", "x", "z", "radius", "skirt", "height_m", "radius_z"),
        &BrickTerrain::add_pad, DEFVAL(-1));
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("sculpt", "x", "z", "radius", "mode", "amount", "target_m"),
        &BrickTerrain::sculpt);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sculpt_begin_stroke"),
        &BrickTerrain::sculpt_begin_stroke);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sculpt_undo"),
        &BrickTerrain::sculpt_undo);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sculpt_undo_depth"),
        &BrickTerrain::sculpt_undo_depth);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("clear_sculpt"),
        &BrickTerrain::clear_sculpt);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sculpt_at", "x", "z"),
        &BrickTerrain::sculpt_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("generated_plate", "x", "z"),
        &BrickTerrain::generated_plate);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("water_floor_tile", "tx", "tz"),
        &BrickTerrain::water_floor_tile);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("ray_ground", "from", "dir", "max_metres"),
        &BrickTerrain::ray_ground);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sculpt_tiles"),
        &BrickTerrain::sculpt_tiles);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_sculpt_tile", "tx", "tz"),
        &BrickTerrain::get_sculpt_tile);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("set_sculpt_tile", "tx", "tz", "metres"),
        &BrickTerrain::set_sculpt_tile);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("paint_surface", "x", "z", "radius", "material", "colour"),
        &BrickTerrain::paint_surface);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("surface_paint_at", "x", "z"),
        &BrickTerrain::surface_paint_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("colour_at", "x", "z"),
        &BrickTerrain::colour_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_surface_paint_tile", "tx", "tz"),
        &BrickTerrain::get_surface_paint_tile);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("set_surface_paint_tile", "tx", "tz", "bytes"),
        &BrickTerrain::set_surface_paint_tile);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("clear_pads"),
        &BrickTerrain::clear_pads);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("pad_count"),
        &BrickTerrain::pad_count);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("pad_at", "x", "z"),
        &BrickTerrain::pad_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_pad", "index"),
        &BrickTerrain::get_pad);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("set_pad", "index", "x", "z", "radius", "skirt", "height_m", "radius_z"),
        &BrickTerrain::set_pad, DEFVAL(-1));
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("remove_pad", "index"),
        &BrickTerrain::remove_pad);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("pad_bounds", "index"),
        &BrickTerrain::pad_bounds);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("add_paint", "x", "z", "radius", "skirt", "material"),
        &BrickTerrain::add_paint);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("clear_paints"),
        &BrickTerrain::clear_paints);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("paint_count"),
        &BrickTerrain::paint_count);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_paint", "index"),
        &BrickTerrain::get_paint);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("set_paint", "index", "x", "z", "radius", "skirt", "material"),
        &BrickTerrain::set_paint);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("remove_paint", "index"),
        &BrickTerrain::remove_paint);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("paint_bounds", "index"),
        &BrickTerrain::paint_bounds);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("paint_at", "x", "z"),
        &BrickTerrain::paint_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("material_names"),
        &BrickTerrain::material_names);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_sun_direction", "to_sun"),
        &BrickTerrain::set_sun_direction);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_sun_direction"),
        &BrickTerrain::get_sun_direction);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sunlit", "x", "z"),
        &BrickTerrain::sunlit);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("smooth_at", "x", "z"),
        &BrickTerrain::smooth_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("surface_raw", "x", "z"),
        &BrickTerrain::surface_raw);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_overlay_chance", "chance"),
        &BrickTerrain::set_overlay_chance);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_overlay_chance"),
        &BrickTerrain::get_overlay_chance);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_flat_mode"),
        &BrickTerrain::get_flat_mode);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_edit_count"),
        &BrickTerrain::get_edit_count);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("material_at", "x", "z"),
        &BrickTerrain::material_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("is_plate", "x", "z"),
        &BrickTerrain::is_plate);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("stud_at", "x", "z"),
        &BrickTerrain::stud_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("ramp_dir", "x", "z"),
        &BrickTerrain::ramp_dir);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("material_filament_index", "material"),
        &BrickTerrain::material_filament_index);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("material_takes_studs", "material"),
        &BrickTerrain::material_takes_studs);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("hash3", "a", "b", "c"),
        &BrickTerrain::hash3);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("hashf", "a", "b", "c"),
        &BrickTerrain::hashf);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("cut_before", "u", "row_key", "axis"),
        &BrickTerrain::cut_before);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("pack_tile", "tx", "tz"),
        &BrickTerrain::pack_tile);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_piece_stride"),
        &BrickTerrain::get_piece_stride);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("build_tile", "tx", "tz"),
        &BrickTerrain::build_tile);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_deep_tier", "on"),
        &BrickTerrain::set_deep_tier);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_deep_tier"),
        &BrickTerrain::get_deep_tier);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_sky_light", "on"), &BrickTerrain::set_sky_light);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_sky_light"), &BrickTerrain::get_sky_light);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("sky_light_at", "point"), &BrickTerrain::sky_light_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("block_light_at", "point"), &BrickTerrain::block_light_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("deep_top", "tx", "tz"),
        &BrickTerrain::deep_top);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_deep_section_plates"),
        &BrickTerrain::get_deep_section_plates);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_bedrock_plate"),
        &BrickTerrain::get_bedrock_plate);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("build_section", "tx", "sy", "tz"),
        &BrickTerrain::build_section);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("overlay_pick", "lists", "eye", "forward", "range_m", "cos_half", "max_bricks", "hidden"),
        &BrickTerrain::overlay_pick, DEFVAL(PackedVector3Array()));
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("overlay_find", "lists", "point"),
        &BrickTerrain::overlay_find);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("build_coarse", "tx0", "tz0", "span", "step"),
        &BrickTerrain::build_coarse);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_slope_pieces", "on"),
        &BrickTerrain::set_slope_pieces);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_slope_pieces"),
        &BrickTerrain::get_slope_pieces);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_region_studs"), &BrickTerrain::get_region_studs);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_tile_pack_stats", "reset"), &BrickTerrain::get_tile_pack_stats, DEFVAL(false));
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("take_dirty_regions"), &BrickTerrain::take_dirty_regions);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_region_edits", "rx", "rz"),
        &BrickTerrain::get_region_edits);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("mark_placed", "lo", "hi", "material"),
        &BrickTerrain::mark_placed);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_placed"), &BrickTerrain::get_placed);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_placed", "cells"),
        &BrickTerrain::set_placed);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_bond_top", "on"),
        &BrickTerrain::set_bond_top);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_bond_top"),
        &BrickTerrain::get_bond_top);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_coarse_smooth_step", "step"),
        &BrickTerrain::set_coarse_smooth_step);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_coarse_smooth_step"),
        &BrickTerrain::get_coarse_smooth_step);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("break_brick", "point", "normal"),
        &BrickTerrain::break_brick);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("find_brick", "point", "normal"),
        &BrickTerrain::find_brick);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("find_bricks", "lo", "hi"),
        &BrickTerrain::find_bricks);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("clear_runs", "runs"),
        &BrickTerrain::clear_runs);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_edits"), &BrickTerrain::get_edits);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_edits", "bytes"), &BrickTerrain::set_edits);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_behind_faces", "on"), &BrickTerrain::set_behind_faces);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_behind_faces"), &BrickTerrain::get_behind_faces);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_behind_centre", "tile_plate"), &BrickTerrain::set_behind_centre);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("behind_wanted", "tx", "sy", "tz"), &BrickTerrain::behind_wanted);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("fill_box", "lo", "hi", "material", "only_air"),
        &BrickTerrain::fill_box);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("ray_cell", "from", "dir", "max_metres"),
        &BrickTerrain::ray_cell);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_generator", "mode"),
        &BrickTerrain::set_generator);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_generator"),
        &BrickTerrain::get_generator);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_gen_params", "params"),
        &BrickTerrain::set_gen_params);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_gen_params"),
        &BrickTerrain::get_gen_params);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("reset_gen_params"),
        &BrickTerrain::reset_gen_params);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("biome_at", "x", "z"),
        &BrickTerrain::biome_at);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("biome_names"),
        &BrickTerrain::biome_names);
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("gen_preview", "seed", "params", "cx", "cz", "w", "h", "step", "mode"),
        &BrickTerrain::gen_preview);

    // Plain integer constants rather than BIND_ENUM_CONSTANT: the enum lives
    // in namespace brick, outside the class, and binding it as a real enum
    // would mean VARIANT_ENUM_CAST on a type the destruction core also uses.
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_AIR", MAT_AIR);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_GRASS", MAT_GRASS);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_DIRT", MAT_DIRT);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_SAND", MAT_SAND);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_STONE", MAT_STONE);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_DARK_STONE", MAT_DARK_STONE);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_ROAD", MAT_ROAD);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_FARMLAND", MAT_FARMLAND);
    ClassDB::bind_integer_constant("BrickTerrain", "Material", "MAT_WET_FARMLAND", MAT_WET_FARMLAND);
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_BRICK", PIECE_BRICK);
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_TILE", PIECE_TILE);
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_RAMP", PIECE_RAMP);
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_SLOPE", PIECE_SLOPE);
}

// ---------------------------------------------------------------------------
// BrickWave
// ---------------------------------------------------------------------------

namespace {

struct WaveComponent {
    double amplitude;
    double wavelength;
    double angle;
    double phase;
};

/// TWO crossing swells, and that is deliberate.
///
/// Water.md section 2 derived the terrace width from a SINGLE component
/// (A=1 m, L=12 m, slope 0.52, terrace 2.3 studs). Slopes ADD, so a
/// four-component sea summed to slope 1.67 and a 0.72-stud terrace -- under
/// one stud, which is exactly the "reads as noise, not terraces" failure that
/// section warned about for plate quantisation. The probe caught it.
///
/// The general rule the arithmetic gives: on a brick-stepped surface a
/// component whose amplitude is below the 0.42 m step cannot move the surface
/// at all, so it spends slope budget and buys no visible detail. A stepped sea
/// carries two or three big components, not an ocean spectrum. Small-scale
/// texture belongs in the normal and in the cosmetic ripples of section 1.2.
///
/// These two sum to slope 0.57 and a 2.1-stud terrace.
const WaveComponent WAVES[] = {
    { 0.90, 13.0, 0.00, 0.0 },
    { 0.45, 21.0, 0.95, 1.7 },
};
const int WAVE_COUNT = (int)(sizeof(WAVES) / sizeof(WAVES[0]));

double g_sea_level = 1.1;
double g_wave_gain = 1.0;

/// Wave GROUPS: long envelopes over the swell, travelling with it at group
/// speed (half the phase speed, deep water). Two, at 170 m and 240 m as MvsC
/// found worked, each +/-15%, so together +/-30%: a heaped stretch, then a
/// calm one, rather than the same sea everywhere.
struct GroupEnvelope {
    double fraction;
    double length;
    int follows;      ///< which swell component it rides with
    double phase;
};
const GroupEnvelope GROUPS[] = {
    { 0.15, 170.0, 0, 0.3 },
    { 0.15, 240.0, 1, 2.2 },
};
const int GROUP_COUNT = (int)(sizeof(GROUPS) / sizeof(GROUPS[0]));

/// THE SHORE BAND. Phased on DISTANCE to the nearest dry ground --
/// A(s) sin(k s + w t + drift) -- so a crest is a line parallel to the coast,
/// and since the phase is constant where k s + w t is, it moves to smaller
/// s as t grows: every crest rolls in toward its own shore.
///
/// It was phased on DEPTH first (MvsC's choice), and on this terrain that was
/// invisible: the ground drops steeply, so every line of equal depth was
/// crammed into a strip a few metres wide at the waterline and the open sea
/// moving one way was all anyone saw. Distance spaces the crests evenly
/// however steep the seabed is.
/// Off (Water.md 9.9): a second wave laid over the swell near the shore read
/// as the sea being clamped at the beach. The swell itself now carries the
/// shore, dying down with distance. Kept at 0 so the uniform layout holds.
constexpr double BAND_AMP = 0.0;
constexpr double BAND_WAVELENGTH = 15.0;  ///< metres between crests
constexpr double BAND_PERIOD = 6.0;       ///< seconds between crests
constexpr double BAND_REACH = 70.0;       ///< metres out from the shore
constexpr int BAND_LATTICE = 8;           ///< studs between seabed samples

/// THE SWELL IS STEERED TO THE SHORE. Within SWELL_NEAR metres of land each
/// swell component is phased on distance to the nearest shore -- crests
/// parallel to the coast, moving in -- so on a lake or a bay the sea rolls
/// out from the middle toward every shore rather than all one way. Past
/// SWELL_FAR, in open ocean, it is the directional swell again, which is
/// what an ocean with no coast in reach looks like.
double SWELL_NEAR = 250.0;
double SWELL_FAR = 400.0;
constexpr double SWELL_DRIFT = 1.0;

/// The field the band reads: (ground, distance) per lattice corner.
std::vector<float> g_shore;
int g_shore_n = 0;
int g_shore_half = 0;
int g_shore_step = BAND_LATTICE;
/// The field's centre, studs: an endless world builds it round the player
/// (Docs/MineWater.md 7.2). 0, 0 for a world built round its origin.
int g_shore_cx = 0;
int g_shore_cz = 0;

/// Depth over which the swell is throttled to nothing. 2.5 m is a little
/// under two full-gain wave heights, so the surf is already half its size a
/// couple of metres out and flat by the waterline.
constexpr double SHORE_TAPER_DEPTH = 2.5;

/// How far the swell is allowed to run, as a fraction of its full height,
/// where the ground is unknown (outside the sampled field).
constexpr double OPEN_SEA_TAPER = 1.0;

/// Deep-water dispersion: a wave of length L travels at sqrt(gL/2pi), so the
/// long swell and the ripples cannot share a speed without the sea looking
/// like a scrolling texture. g at 1:1 -- the world is scaled, the physics of a
/// water surface is not, and scaled gravity made the swell crawl.
constexpr double G = 9.81;

inline double omega(double wavelength) {
    return std::sqrt(G * (Math_TAU / wavelength));
}

} // namespace

int BrickWave::component_count() { return WAVE_COUNT; }

void BrickWave::set_sea_level(double m) { g_sea_level = m; }
double BrickWave::get_sea_level() { return g_sea_level; }

/// A TALLER SWELL IS ALSO A LONGER ONE.
///
/// The gain scales wavelength as well as amplitude, so wave steepness -- and
/// with it the terrace width, which is section 2's whole argument -- does not
/// move. Scaling amplitude alone at gain 2.2 tripled the surface slope and
/// cut the terraces to 1.0 stud: every cell on a different step, which reads
/// as chaos rather than as a swell, and is exactly the failure section 2
/// warned about for plate quantisation. Measured, in the water captures.
///
/// It is also the physical answer. Real swell holds H/L roughly constant; a
/// 4 m wave 13 m long is not a swell, it is a wall. Speed follows for free,
/// because omega comes from the wavelength.
void BrickWave::set_wave_gain(double g) { g_wave_gain = std::max(g, 0.0); }
double BrickWave::get_wave_gain() { return g_wave_gain; }

double BrickWave::get_shore_taper_depth() { return SHORE_TAPER_DEPTH; }

namespace {

/// The shore ramp, from the SAME ground the seabed texture is built from --
/// (height + 1) * brick -- so the CPU surface and the drawn one agree to
/// within the texture's own quantisation rather than by construction.
double shore_taper(double x, double z) {
    // No depth RAMP (9.9): the strength comes from the distance to the shore,
    // in swell_near_shore. Dry land is still 0 -- nothing to wave there.
    const int gx = (int)std::floor(x / (double)STUD_M);
    const int gz = (int)std::floor(z / (double)STUD_M);
    const double ground = (double)(BrickTerrain::height_at(gx, gz) + 1) * (double)BRICK_M;
    return g_sea_level - ground > 0.0 ? 1.0 : 0.0;
}

} // namespace

/// Water quantises to one BRICK, not one plate. At A=1 m, L=12 m the mean
/// surface slope is 0.52, so a plate step gives a 0.76-stud terrace -- every
/// cell on a different step, which reads as noise. A brick step gives 2.3
/// studs, which reads as a terrace (Water section 2).
double BrickWave::get_step_metres() { return (double)BRICK_M; }

double BrickWave::shore_gain(double x, double z) { return shore_taper(x, z); }

namespace {

inline double smoothstep_d(double a, double b, double x) {
    const double t = std::clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// The ground under a point, bilinear over the seabed lattice -- the same
/// corners the seabed texture holds, so CPU and shader read one surface.
double lattice_ground(double x, double z) {
    const double xs = x / (double)STUD_M / (double)BAND_LATTICE;
    const double zs = z / (double)STUD_M / (double)BAND_LATTICE;
    const int i0 = (int)std::floor(xs);
    const int j0 = (int)std::floor(zs);
    const double fx = xs - (double)i0;
    const double fz = zs - (double)j0;
    auto g = [](int i, int j) {
        return (double)(BrickTerrain::surface_plate(i * BAND_LATTICE, j * BAND_LATTICE) + 1)
                * (double)PLATE_M;
    };
    const double a = g(i0, j0), b = g(i0 + 1, j0), cc = g(i0, j0 + 1), d = g(i0 + 1, j0 + 1);
    return (a + (b - a) * fx) * (1.0 - fz) + (cc + (d - cc) * fx) * fz;
}

double group_factor(double x, double z, double t) {
    double f = 1.0;
    for (int j = 0; j < GROUP_COUNT; ++j) {
        const GroupEnvelope &g = GROUPS[j];
        const WaveComponent &w = WAVES[g.follows];
        const double swell_len = w.wavelength * g_wave_gain;
        const double group_speed = 0.5 * std::sqrt(G * swell_len / Math_TAU);
        const double len = g.length * g_wave_gain;
        const double k = Math_TAU / len;
        f += g.fraction * std::sin((std::cos(w.angle) * x + std::sin(w.angle) * z) * k
                - k * group_speed * t + g.phase);
    }
    return f;
}

double band_drift(double x, double z) {
    return 1.2 * std::sin(0.013 * x + 0.7) + 1.2 * std::sin(0.011 * z + 2.1);
}

/// Bilinear over the shore field's distance channel; 1e9 outside it.
double field_distance(double x, double z) {
    if (g_shore_n <= 1) {
        return 1.0e9;
    }
    const double q = (x / (double)STUD_M + (double)(g_shore_half - g_shore_cx)) / (double)g_shore_step;
    const double r = (z / (double)STUD_M + (double)(g_shore_half - g_shore_cz)) / (double)g_shore_step;
    const int i0 = (int)std::floor(q);
    const int j0 = (int)std::floor(r);
    if (i0 < 0 || j0 < 0 || i0 + 1 >= g_shore_n || j0 + 1 >= g_shore_n) {
        return 1.0e9;
    }
    const double fx = q - (double)i0;
    const double fz = r - (double)j0;
    auto d = [](int i, int j) { return (double)g_shore[((size_t)j * g_shore_n + i) * 2 + 1]; };
    return (d(i0, j0) + (d(i0 + 1, j0) - d(i0, j0)) * fx) * (1.0 - fz)
            + (d(i0, j0 + 1) + (d(i0 + 1, j0 + 1) - d(i0, j0 + 1)) * fx) * fz;
}

/// THE WAVE STRENGTH, by distance to the shore and nothing else: full in the
/// middle of the water, dying down as it travels in, a quarter of it where it
/// meets the beach (9.9). There is no depth clamp any more -- that is what
/// read as the sea being cut off at the shore.
double SHORE_FADE = 150.0;
double SHORE_STRENGTH = 0.25;
double swell_near_shore(double dist) {
    return SHORE_STRENGTH + (1.0 - SHORE_STRENGTH) * smoothstep_d(0.0, SHORE_FADE, dist);
}

/// A slow wobble per swell component, so shore-steered crests are not
/// perfect contour lines of the distance field.
double swell_drift(int i, double x, double z) {
    return SWELL_DRIFT * (std::sin(0.017 * x + 1.3 * (double)i) + std::sin(0.014 * z + 0.7 * (double)i));
}

double band_value(double x, double z, double t) {
    const double depth = g_sea_level - lattice_ground(x, z);
    if (depth <= 0.0) {
        return 0.0;
    }
    const double dist = field_distance(x, z);
    // A third at the waterline and growing out to sea -- a beach gets small
    // rollers, the approach bigger ones -- then gone past the reach.
    const double wgt = (0.35 + 0.65 * smoothstep_d(0.0, 20.0, dist))
            * (1.0 - smoothstep_d(0.6 * BAND_REACH, BAND_REACH, dist))
            * smoothstep_d(0.2, 1.0, depth);
    if (wgt <= 0.0) {
        return 0.0;
    }
    return BAND_AMP * g_wave_gain * wgt
            * std::sin((Math_TAU / BAND_WAVELENGTH) * dist + (Math_TAU / BAND_PERIOD) * t
            + band_drift(x, z));
}

} // namespace

double BrickWave::band_depth(double x, double z) { return g_sea_level - lattice_ground(x, z); }
double BrickWave::shore_distance(double x, double z) { return field_distance(x, z); }

PackedFloat32Array BrickWave::build_shore_field(int half_studs, int step) {
    PackedFloat32Array out = compute_shore_field(0, 0, half_studs, step);
    install_shore_field(0, 0, half_studs, step, out);
    return out;
}

void BrickWave::install_shore_field(int cx, int cz, int half_studs, int step,
        const PackedFloat32Array &field) {
    step = std::max(step, 1);
    const int n = std::max(2 * half_studs / step, 2);
    if (field.size() != (int64_t)n * n * 2) {
        return;
    }
    g_shore.assign(field.ptr(), field.ptr() + field.size());
    g_shore_n = n;
    g_shore_half = half_studs;
    g_shore_step = step;
    g_shore_cx = cx;
    g_shore_cz = cz;
}

PackedFloat32Array BrickWave::compute_shore_field(int cx, int cz, int half_studs, int step) {
    step = std::max(step, 1);
    const int n = std::max(2 * half_studs / step, 2);
    std::vector<float> g_shore((size_t)n * n * 2, 0.0f);
    std::vector<float> dist((size_t)n * n);
    const float INF = 1.0e9f;
    for (int iz = 0; iz < n; ++iz) {
        std::shared_lock<std::shared_mutex> rd(g_edit_rw);
        for (int ix = 0; ix < n; ++ix) {
            const int gx = ix * step - half_studs + cx;
            const int gz = iz * step - half_studs + cz;
            float ground = (float)(BrickTerrain::surface_plate(gx, gz) + 1) * PLATE_M;
            // Ground dug below the sea where the world as generated was dry
            // is not sea: the sea tiers must not draw in it. Its water is a
            // pool, which fills by flowing (BrickPools, Water.md 12).
            if (ground < (float)g_sea_level
                    && (float)(BrickTerrain::generated_plate(gx, gz) + 1) * PLATE_M
                            >= (float)g_sea_level) {
                // Well over any crest: one plate up, the waves rose over it
                // and the tiers drew sea down a pit dug inland.
                ground = (float)g_sea_level + 100.0f;
            }
            const size_t k = (size_t)iz * n + ix;
            g_shore[k * 2] = ground;
            dist[k] = ground < (float)g_sea_level ? INF : 0.0f;
        }
    }
    // Two-pass chamfer distance, in cells: a close enough Euclidean for
    // spacing wave crests, and 160k cells in a couple of milliseconds.
    const float D1 = 1.0f, D2 = 1.41421356f;
    for (int iz = 0; iz < n; ++iz) {
        for (int ix = 0; ix < n; ++ix) {
            float &v = dist[(size_t)iz * n + ix];
            if (ix > 0) v = std::min(v, dist[(size_t)iz * n + ix - 1] + D1);
            if (iz > 0) {
                v = std::min(v, dist[(size_t)(iz - 1) * n + ix] + D1);
                if (ix > 0) v = std::min(v, dist[(size_t)(iz - 1) * n + ix - 1] + D2);
                if (ix + 1 < n) v = std::min(v, dist[(size_t)(iz - 1) * n + ix + 1] + D2);
            }
        }
    }
    for (int iz = n - 1; iz >= 0; --iz) {
        for (int ix = n - 1; ix >= 0; --ix) {
            float &v = dist[(size_t)iz * n + ix];
            if (ix + 1 < n) v = std::min(v, dist[(size_t)iz * n + ix + 1] + D1);
            if (iz + 1 < n) {
                v = std::min(v, dist[(size_t)(iz + 1) * n + ix] + D1);
                if (ix + 1 < n) v = std::min(v, dist[(size_t)(iz + 1) * n + ix + 1] + D2);
                if (ix > 0) v = std::min(v, dist[(size_t)(iz + 1) * n + ix - 1] + D2);
            }
        }
    }
    const float cell_m = (float)step * STUD_M;
    for (size_t k = 0; k < dist.size(); ++k) {
        // Open sea with no shore in the field reads as far out.
        g_shore[k * 2 + 1] = dist[k] >= INF * 0.5f ? 10000.0f : dist[k] * cell_m;
    }
    PackedFloat32Array out;
    out.resize((int64_t)g_shore.size());
    std::copy(g_shore.begin(), g_shore.end(), out.ptrw());
    return out;
}
Array BrickWave::wet_cells(int cell_studs) {
    Array out;
    cell_studs = std::max(cell_studs, 1);
    std::set<std::pair<int, int>> seen;
    for (int iz = 0; iz < g_shore_n; ++iz) {
        for (int ix = 0; ix < g_shore_n; ++ix) {
            if (g_shore[((size_t)iz * g_shore_n + ix) * 2] >= (float)g_sea_level) {
                continue;
            }
            const int cx = (int)std::floor((double)(ix * g_shore_step - g_shore_half + g_shore_cx) / cell_studs);
            const int cz = (int)std::floor((double)(iz * g_shore_step - g_shore_half + g_shore_cz) / cell_studs);
            if (seen.insert({ cx, cz }).second) {
                out.append(Vector2i(cx, cz));
            }
        }
    }
    return out;
}

double BrickWave::group_at(double x, double z, double t) { return group_factor(x, z, t); }
double BrickWave::band_at(double x, double z, double t) { return band_value(x, z, t); }

PackedVector4Array BrickWave::group_uniform_array() {
    PackedVector4Array out;
    for (int j = 0; j < GROUP_COUNT; ++j) {
        const GroupEnvelope &g = GROUPS[j];
        const WaveComponent &w = WAVES[g.follows];
        const double swell_len = w.wavelength * g_wave_gain;
        const double group_speed = 0.5 * std::sqrt(G * swell_len / Math_TAU);
        const double k = Math_TAU / (g.length * g_wave_gain);
        out.push_back(Vector4((float)g.fraction, (float)k,
            (float)std::cos(w.angle), (float)std::sin(w.angle)));
        out.push_back(Vector4((float)(k * group_speed), (float)g.phase, 0.0f, 0.0f));
    }
    return out;
}

void BrickWave::set_swell_steer(double near_m, double far_m) {
    SWELL_NEAR = std::max(near_m, 0.0);
    SWELL_FAR = std::max(far_m, SWELL_NEAR + 1.0);
}

void BrickWave::set_shore_calm(double strength, double fade_m) {
    SHORE_STRENGTH = std::clamp(strength, 0.0, 1.0);
    SHORE_FADE = std::max(fade_m, 1.0);
}

Vector2 BrickWave::shore_calm_uniform() {
    return Vector2((float)SHORE_STRENGTH, (float)SHORE_FADE);
}

Vector4 BrickWave::swell_blend_uniform() {
    return Vector4((float)SWELL_NEAR, (float)SWELL_FAR, (float)SWELL_DRIFT, 0.0f);
}

Vector4 BrickWave::shore_band_uniform() {
    return Vector4((float)(BAND_AMP * g_wave_gain), (float)(Math_TAU / BAND_WAVELENGTH),
        (float)(Math_TAU / BAND_PERIOD), (float)BAND_REACH);
}

double BrickWave::height_at(double x, double z, double t) {
    // One field query a sample, for the shore ramp. That is an fBm evaluation
    // where there used to be none, so this is a per-BODY call and not a
    // per-vertex one -- which is what `sample_heights` is for.
    const double taper = shore_taper(x, z);
    const double dist = field_distance(x, z);
    // 0 near land (steered to the shore), 1 in open ocean (directional).
    const double open = smoothstep_d(SWELL_NEAR, SWELL_FAR, dist);
    double swell = 0.0;
    for (int i = 0; i < WAVE_COUNT; ++i) {
        const WaveComponent &w = WAVES[i];
        const double len = w.wavelength * g_wave_gain;
        const double k = Math_TAU / len;
        const double directional = std::sin((std::cos(w.angle) * x + std::sin(w.angle) * z) * k
                - omega(len) * t + w.phase);
        // + omega t: the phase is constant where k dist + w t is, so the
        // crest moves to smaller distance -- toward the shore.
        const double steered = std::sin(k * std::min(dist, SWELL_FAR) + omega(len) * t + w.phase
                + swell_drift(i, x, z));
        swell += w.amplitude * g_wave_gain * (steered * (1.0 - open) + directional * open);
    }
    // The swell, shaped by the groups and dying in the shallows, and the
    // shore band on top of it: the same expression the shader draws.
    return g_sea_level + taper * group_factor(x, z, t) * swell_near_shore(dist) * swell
            + band_value(x, z, t);
}

/// The surface as the pieces actually sit. Gameplay uses the CONTINUOUS height
/// -- a swimmer should not teleport 0.42 m -- and presentation uses this one.
/// Both come from the same expression, which is the property that matters.
double BrickWave::stepped_at(double x, double z, double t) {
    const double step = get_step_metres();
    return std::floor(height_at(x, z, t) / step) * step;
}

PackedFloat32Array BrickWave::sample_heights(const PackedVector2Array &points, double t) {
    PackedFloat32Array out;
    out.resize(points.size());
    float *w = out.ptrw();
    for (int i = 0; i < points.size(); ++i) {
        const Vector2 p = points[i];
        w[i] = (float)height_at(p.x, p.y, t);
    }
    return out;
}

PackedVector4Array BrickWave::uniform_array() {
    PackedVector4Array out;
    for (int i = 0; i < WAVE_COUNT; ++i) {
        const WaveComponent &w = WAVES[i];
        // Gained here -- amplitude AND wavelength -- so the shader has no
        // knob of its own to disagree with.
        const double len = w.wavelength * g_wave_gain;
        const double k = Math_TAU / len;
        out.push_back(Vector4((float)(w.amplitude * g_wave_gain), (float)k,
            (float)std::cos(w.angle), (float)std::sin(w.angle)));
        out.push_back(Vector4((float)omega(len), (float)w.phase, 0.0f, 0.0f));
    }
    return out;
}

double BrickWave::terrace_studs() {
    double slope = 0.0;
    for (int i = 0; i < WAVE_COUNT; ++i) {
        // Gain cancels: it scales both. That is the point of it.
        slope += Math_TAU * (WAVES[i].amplitude * g_wave_gain)
                / (WAVES[i].wavelength * g_wave_gain);
    }
    return (get_step_metres() / std::max(slope, 1e-4)) / (double)STUD_M;
}

void BrickWave::_bind_methods() {
    ClassDB::bind_static_method("BrickWave", D_METHOD("component_count"),
        &BrickWave::component_count);
    ClassDB::bind_static_method("BrickWave", D_METHOD("set_sea_level", "m"),
        &BrickWave::set_sea_level);
    ClassDB::bind_static_method("BrickWave", D_METHOD("get_sea_level"), &BrickWave::get_sea_level);
    ClassDB::bind_static_method("BrickWave", D_METHOD("set_wave_gain", "g"),
        &BrickWave::set_wave_gain);
    ClassDB::bind_static_method("BrickWave", D_METHOD("get_wave_gain"),
        &BrickWave::get_wave_gain);
    ClassDB::bind_static_method("BrickWave", D_METHOD("get_shore_taper_depth"),
        &BrickWave::get_shore_taper_depth);
    ClassDB::bind_static_method("BrickWave", D_METHOD("shore_gain", "x", "z"),
        &BrickWave::shore_gain);
    ClassDB::bind_static_method("BrickWave", D_METHOD("get_step_metres"),
        &BrickWave::get_step_metres);
    ClassDB::bind_static_method("BrickWave", D_METHOD("height_at", "x", "z", "t"),
        &BrickWave::height_at);
    ClassDB::bind_static_method("BrickWave", D_METHOD("stepped_at", "x", "z", "t"),
        &BrickWave::stepped_at);
    ClassDB::bind_static_method("BrickWave", D_METHOD("sample_heights", "points", "t"),
        &BrickWave::sample_heights);
    ClassDB::bind_static_method("BrickWave", D_METHOD("uniform_array"), &BrickWave::uniform_array);
    ClassDB::bind_static_method("BrickWave", D_METHOD("group_uniform_array"),
        &BrickWave::group_uniform_array);
    ClassDB::bind_static_method("BrickWave", D_METHOD("shore_band_uniform"),
        &BrickWave::shore_band_uniform);
    ClassDB::bind_static_method("BrickWave", D_METHOD("swell_blend_uniform"),
        &BrickWave::swell_blend_uniform);
    ClassDB::bind_static_method("BrickWave", D_METHOD("set_swell_steer", "near_m", "far_m"),
        &BrickWave::set_swell_steer);
    ClassDB::bind_static_method("BrickWave", D_METHOD("set_shore_calm", "strength", "fade_m"),
        &BrickWave::set_shore_calm);
    ClassDB::bind_static_method("BrickWave", D_METHOD("shore_calm_uniform"),
        &BrickWave::shore_calm_uniform);
    ClassDB::bind_static_method("BrickWave", D_METHOD("band_depth", "x", "z"),
        &BrickWave::band_depth);
    ClassDB::bind_static_method("BrickWave", D_METHOD("shore_distance", "x", "z"),
        &BrickWave::shore_distance);
    ClassDB::bind_static_method("BrickWave", D_METHOD("build_shore_field", "half_studs", "step"),
        &BrickWave::build_shore_field);
    ClassDB::bind_static_method("BrickWave", D_METHOD("compute_shore_field", "cx", "cz", "half_studs", "step"), &BrickWave::compute_shore_field);
    ClassDB::bind_static_method("BrickWave", D_METHOD("install_shore_field", "cx", "cz", "half_studs", "step", "field"), &BrickWave::install_shore_field);
    ClassDB::bind_static_method("BrickWave", D_METHOD("wet_cells", "cell_studs"),
        &BrickWave::wet_cells);
    ClassDB::bind_static_method("BrickWave", D_METHOD("group_at", "x", "z", "t"),
        &BrickWave::group_at);
    ClassDB::bind_static_method("BrickWave", D_METHOD("band_at", "x", "z", "t"),
        &BrickWave::band_at);
    ClassDB::bind_static_method("BrickWave", D_METHOD("terrace_studs"), &BrickWave::terrace_studs);
}
