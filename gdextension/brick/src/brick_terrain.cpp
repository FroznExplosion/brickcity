#include "brick_terrain.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
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
}

/// Steepness at a column, in plates a stud: the larger of the two central
/// differences of the unquantised surface.
static float surface_slope(const Field &f, int x, int z) {
    const float dx = (f.raw_plate(x + 1, z) - f.raw_plate(x - 1, z)) * 0.5f;
    const float dz = (f.raw_plate(x, z + 1) - f.raw_plate(x, z - 1)) * 0.5f;
    return std::max(std::abs(dx), std::abs(dz));
}

/// Curve or bricks, for one column. `qstep` is the largest step to a
/// neighbour on the QUANTISED surface, in plates -- the caller has it to
/// hand, and recomputing it would be four more field evaluations a cell.
static bool smooth_column(const Field &f, int x, int z, int qstep) {
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
    SculptTile() {
        std::fill(std::begin(mat), std::end(mat), (uint8_t)0xFF);
        std::fill(std::begin(col), std::end(col), (uint8_t)0xFF);
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

static float sculpt_plates(int x, int z) {
    if (!g_sculpt_any.load(std::memory_order_acquire)) {
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
    const float bricks = landform * 90.0f + relief * 9.0f + detail * 1.5f + 14.0f;
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
    return apply_pads(base_plate(x, z), x, z, nullptr);
}

int Field::top_plate(int x, int z) const {
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

static std::unordered_map<int64_t, uint8_t> g_edits;

int64_t pack_cell(int x, int yp, int z) {
    // 21 bits each, signed, which is +-1 million studs and +-1 million
    // plates. The city is a thousand studs across.
    return ((int64_t)(x & 0x1FFFFF) << 42) | ((int64_t)(yp & 0x1FFFFF) << 21)
            | (int64_t)(z & 0x1FFFFF);
}

int edit_at(int64_t key) {
    auto it = g_edits.find(key);
    return it == g_edits.end() ? -1 : (int)it->second;
}

/// Deepest edited plate per tile column, so `sample_tile` knows how far down
/// it has to look. Without it the mask stopped SECTION_BELOW plates under the
/// surface, anything dug past that was edited in the field but still read as
/// solid rock to the mesher, and the floor of a deep pit was simply not
/// there.
static std::unordered_map<int64_t, int> g_tile_floor;

static inline int64_t tile_key(int tx, int tz) {
    return ((int64_t)(tx & 0xFFFFFFF) << 28) | (int64_t)(tz & 0xFFFFFFF);
}

void set_edit(int x, int yp, int z, int material) {
    g_edits[pack_cell(x, yp, z)] = (uint8_t)material;
    const int64_t tk = tile_key(floor_div(x, TILE), floor_div(z, TILE));
    auto it = g_tile_floor.find(tk);
    if (it == g_tile_floor.end() || yp < it->second) {
        g_tile_floor[tk] = yp;
    }
}

int deepest_edit_near(int tx, int tz) {
    int best = INT_MAX;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            auto it = g_tile_floor.find(tile_key(tx + dx, tz + dz));
            if (it != g_tile_floor.end()) {
                best = std::min(best, it->second);
            }
        }
    }
    return best;
}

void clear_edits() {
    g_edits.clear();
    g_tile_floor.clear();
}

size_t edit_count() {
    return g_edits.size();
}

bool edits_empty() {
    return g_edits.empty();
}

// --- sampling --------------------------------------------------------------

void sample_tile(const Field &f, int tx, int tz, TileSample &out) {
    out.tx = tx;
    out.tz = tz;

    const int gx0 = tx * TILE;
    const int gz0 = tz * TILE;

    // The mask spans from a little above the highest nominal surface down
    // SECTION_BELOW plates from the lowest. Everything above is air and
    // everything below is rock, and neither needs storing (section 17.4).
    int hi = -1000000, lo = 1000000;
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            const int t = f.top_plate(gx0 + lx, gz0 + lz);
            hi = std::max(hi, t);
            lo = std::min(lo, t);
        }
    }
    const int top_plate = hi + 1;
    out.y0 = lo + 1 - SECTION_BELOW;
    // Reach whatever has been dug, plus a little, or the bottom of a deep pit
    // falls outside the mask and is never meshed.
    const int dug = deepest_edit_near(tx, tz);
    if (dug != INT_MAX) {
        out.y0 = std::min(out.y0, dug - 6);
    }
    out.ysize = top_plate - out.y0 + 1;
    out.vox.assign((size_t)SPAN * out.ysize * SPAN, (uint8_t)MAT_AIR);

    // `nominal_height` is three octaves of fBm and `material_at` another
    // noise, and BOTH are functions of the column alone. Calling solid_at per
    // CELL recomputed them for all ~85 plates of every column: 9.4 ms a tile,
    // against 0.6 ms for the heightfield it replaced. Hoisted out, only the
    // cave test and the edit lookup remain per cell.
    const bool no_edits = edits_empty() || g_flat_mode;
    for (int lz = -MARGIN; lz < TILE + MARGIN; ++lz) {
        for (int lx = -MARGIN; lx < TILE + MARGIN; ++lx) {
            const int gx = gx0 + lx, gz = gz0 + lz;
            const int ctop_plate = f.top_plate(gx, gz);
            const int ch = floor_div(ctop_plate, PLATES_PER_CELL);
            const int ctop = ctop_plate + 1;
            const uint8_t cmat = (uint8_t)f.material_at(gx, gz, ch);
            for (int yp = out.y0; yp < out.y0 + out.ysize; ++yp) {
                uint8_t v;
                if (yp >= ctop) {
                    v = (uint8_t)MAT_AIR;
                } else if (!g_flat_mode && f.cave_at(gx, yp, gz, ctop)) {
                    v = (uint8_t)MAT_AIR;
                } else {
                    v = cmat;
                }
                if (!no_edits) {
                    const int e = edit_at(pack_cell(gx, yp, gz));
                    if (e >= 0) {
                        v = (uint8_t)e;
                    }
                }
                out.vox[out.vidx(lx, yp, lz)] = v;
            }
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

void pack_tile(const Field &f, const TileSample &s, std::vector<Piece> &out,
        std::vector<int32_t> &owner) {
    out.clear();
    owner.assign(TILE * TILE, -1);

    const uint32_t seed = f.seed;
    const int gx0 = s.tx * TILE;
    const int gz0 = s.tz * TILE;

    auto emit = [&](int ox, int oz, int sx, int sz, int kind, int ramp) {
        const int i = TileSample::idx(ox, oz);
        Piece pc;
        pc.ox = (int16_t)ox;
        pc.oz = (int16_t)oz;
        pc.sx = (int16_t)sx;
        pc.sz = (int16_t)sz;
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
        if (pc.studded && hashf(gx0 + ox, gz0 + oz, (int32_t)(seed ^ 0x7113U))
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

    place_pass(true, PIECE_BRICK);
    place_pass(false, PIECE_TILE);

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
        const int gx = gx0 + pc.ox;
        const int gz = gz0 + pc.oz;
        if (hashf(gx, gz, (int32_t)(seed ^ 0x0A11U)) >= g_overlay_chance) {
            continue;
        }
        const bool smooth = hashf(gx, gz, (int32_t)(seed ^ 0x71E5U)) < OVERLAY_TILE_SHARE;
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


/// Metres of real 45-degree chamfer cut off every face edge, or 0 for none.
///
/// KNOWN BROKEN, kept behind the `G` toggle as a comparison only. Chamfering
/// FACES of a surface opens a groove with no bottom: two coplanar pieces each
/// inset their top, and the V between them has no brick body under it because
/// the terrain mesh is a skin, not solids. Convex corners have the opposite
/// fault -- only one of the two faces owns the facet, so the other leaves a
/// notch.
///
/// The fix is not a better face chamfer. It is to draw NEAR bricks as closed
/// chamfered SOLIDS, which have a body and therefore a groove bottom, the way
/// `PieceMeshes.chamfered_box` already does for debris. See Terrain.md.
///
/// This is the built version of what `brick.gdshader` shades, and it is here
/// because the shaded bevel does not give a SILHOUETTE: a brick outlined in
/// light is still a box against the sky.
///
/// It is not free and the toggle is not decoration. Every quad becomes
/// fourteen triangles -- an inset face, four bevel strips and four corners --
/// so a terrain tile goes from ~3.6k triangles to ~25k and the 25-tile test
/// field from 70k to roughly 490k. That is affordable for terrain at this
/// size and is NOT affordable for the city's chunk mesh, where the same
/// multiplier puts a 150 m tower at 4.8M. Measure before turning it on
/// anywhere new.
static float g_face_bevel = 0.0f;

void BrickTerrain::configure(int64_t world_seed) {
    g_field.seed = (uint32_t)(world_seed & 0xffffffff);
}

int BrickTerrain::get_field_version() { return FIELD_VERSION; }
int64_t BrickTerrain::get_seed() { return (int64_t)g_field.seed; }
float BrickTerrain::get_brick_metres() { return BRICK_M; }
int BrickTerrain::get_tile_studs() { return TILE; }
int BrickTerrain::get_max_piece_length() { return MAX_LEN; }
int BrickTerrain::get_period() { return PERIOD; }

void BrickTerrain::set_face_bevel(double metres) {
    g_face_bevel = (float)std::max(0.0, metres);
}

double BrickTerrain::get_face_bevel() { return (double)g_face_bevel; }
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
}

void BrickTerrain::clear_pads() { g_pads.clear(); }
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
}

void BrickTerrain::remove_pad(int index) {
    if (index < 0 || index >= (int)g_pads.size()) {
        return;
    }
    g_pads.erase(g_pads.begin() + index);
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
    return out;
}

void BrickTerrain::set_sun_direction(Vector3 to_sun) { g_sun_dir = to_sun; }
Vector3 BrickTerrain::get_sun_direction() { return g_sun_dir; }
bool BrickTerrain::sunlit(int x, int z) { return sun_reaches(x, z); }

int BrickTerrain::surface_plate(int x, int z) {
    const int top = g_field.top_plate(x, z);
    if (g_flat_mode) {
        return top;   // nothing is ever carved out of it
    }
    int floor_p = top - SECTION_BELOW;
    const int dug = deepest_edit_near(floor_div(x, TILE), floor_div(z, TILE));
    if (dug != INT_MAX) {
        floor_p = std::min(floor_p, dug - 6);
    }
    for (int yp = top; yp > floor_p; --yp) {
        if (g_field.solid_at(x, yp, z) != MAT_AIR) {
            return yp;
        }
    }
    return floor_p;
}

int BrickTerrain::solid_at(int x, int yp, int z) { return g_field.solid_at(x, yp, z); }

int BrickTerrain::get_edit_count() { return (int)edit_count(); }

void BrickTerrain::clear_terrain_edits() { clear_edits(); }

void BrickTerrain::set_flat_mode(bool on) { g_flat_mode = on; }

void BrickTerrain::set_plate_steps(bool on) { g_plate_steps = on; }
bool BrickTerrain::get_plate_steps() { return g_plate_steps; }

void BrickTerrain::set_smooth_terrain(bool on) { g_smooth_terrain = on; }
bool BrickTerrain::get_smooth_terrain() { return g_smooth_terrain; }

double BrickTerrain::surface_raw(int x, int z) {
    // The half plate matches the mesher: the curve runs through the middle
    // of the staircase it replaces, not along its top.
    return ((double)g_field.raw_plate(x, z) + 0.5) * (double)PLATE_M;
}

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
                if (mat == MAT_AIR) {
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
    out["debris"] = debris;
    out["edits"] = (int)edit_count();
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
    sample_tile(g_field, tx, tz, s);
    std::vector<Piece> pieces;
    std::vector<int32_t> owner;
    brick::pack_tile(g_field, s, pieces, owner);

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

    void push_custom(int n) {
        for (int i = 0; i < n; ++i) {
            custom0.push_back(material);
            custom0.push_back(0);
            custom0.push_back(0);
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

    /// One face, chamfered in place.
    ///
    /// The face is inset by the bevel and a strip runs from the inset edge
    /// back out to the ORIGINAL rim. Two faces meeting at a 90-degree corner
    /// each contribute a strip whose normal is the bisector of the two face
    /// normals -- the same direction, in the same plane -- so the two halves
    /// form one 45-degree facet without either face knowing the other exists.
    /// That is what lets the packer's tops and the mask's sides bevel
    /// independently.
    /// `convex` is one bit an edge: set when a PERPENDICULAR face meets this
    /// one there, clear when the neighbour is coplanar (or there is none).
    ///
    /// The two cases need different geometry and there is no formula that
    /// serves both:
    ///
    ///   coplanar -- two tops side by side. Each emits HALF, down to the
    ///               shared rim one bevel back, and the two halves meet at
    ///               the bottom of the V. The groove has a floor.
    ///   convex   -- a top meeting a wall. The facet runs from OUR inset edge
    ///               to THEIRS, and exactly one of the two must draw all of
    ///               it, or you get a slot the length of the edge.
    ///
    /// Getting this wrong is not a notch at a corner. It is an open slot
    /// running the whole length of every terrace lip, which is what the olive
    /// lines were: daylight through the ground.
    /// An edge has THREE states, not two, and every round of chamfer bugs
    /// so far has been a missing third case:
    ///
    ///   CONVEX    the neighbour cell is air, so a perpendicular face meets
    ///             this one on an outside corner. One facet, one owner.
    ///   COPLANAR  the neighbour is solid and its own face in our direction
    ///             is exposed — another floor beside this floor. Each emits
    ///             HALF and they meet in the groove between them.
    ///   SQUARE    the neighbour is solid and covered: an INSIDE corner,
    ///             where a wall meets the floor it stands on. Chamfering
    ///             here cuts away material that is really there and opens a
    ///             slot with nothing behind it. A real brick has no bevel on
    ///             an inside corner either.
    ///
    /// A square edge is not inset at all, so the face reaches its full
    /// extent and butts against the geometry it meets.
    void quad(const Vector3 &n, const Color &c, const Vector2 &face,
            const Vector3 &a, const Vector3 &b, const Vector3 &d, const Vector3 &e,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &ud, const Vector2 &ue,
            uint8_t convex = 0, uint8_t square = 0) {
        const float bev = g_face_bevel;
        if (bev <= 0.0f) {
            raw_quad(n, c, face, a, b, d, e, ua, ub, ud, ue);
            return;
        }
        const Vector3 rim[4] = { a, b, d, e };
        const Vector2 ruv[4] = { ua, ub, ud, ue };

        // Never eat more than a third of the shorter side, or a 1x1 plate's
        // face collapses through itself.
        const float side_u = a.distance_to(b);
        const float side_v = b.distance_to(d);
        const float cut = std::min(bev, std::min(side_u, side_v) * 0.34f);
        if (cut <= 1e-5f) {
            raw_quad(n, c, face, a, b, d, e, ua, ub, ud, ue);
            return;
        }

        Vector3 in[4];
        Vector2 inuv[4];
        for (int i = 0; i < 4; ++i) {
            const Vector3 &p = rim[i];
            const Vector3 &nx = rim[(i + 1) % 4];
            const Vector3 &pv = rim[(i + 3) % 4];
            // Moving toward the NEXT corner insets away from the PREVIOUS
            // edge, and vice versa, so a square edge zeroes the displacement
            // that would have pulled the face off it.
            const float c1 = (square & (1u << ((i + 3) % 4))) ? 0.0f : cut;
            const float c2 = (square & (1u << i)) ? 0.0f : cut;
            const Vector3 e1 = (nx - p).normalized();
            const Vector3 e2 = (pv - p).normalized();
            in[i] = p + e1 * c1 + e2 * c2;
            const Vector2 &q = ruv[i];
            const Vector2 qn = ruv[(i + 1) % 4];
            const Vector2 qp = ruv[(i + 3) % 4];
            const Vector2 f1 = (qn - q).normalized();
            const Vector2 f2 = (qp - q).normalized();
            inuv[i] = q + f1 * c1 + f2 * c2;
        }

        raw_quad(n, c, face, in[0], in[1], in[2], in[3],
            inuv[0], inuv[1], inuv[2], inuv[3]);

        // Every edge gets its strip, running from the inset edge back to the
        // rim pushed one bevel BEHIND the face plane.
        //
        // The axis rule that used to live here -- "the face on the lower axis
        // owns the facet" -- was solving the wrong problem. It assumed the
        // other half of every edge belonged to a PERPENDICULAR face. Most
        // edges on this surface are shared with a COPLANAR neighbour instead,
        // where there is no second face at all, and skipping the strip left
        // the V-groove between two pieces open with nothing under it.
        //
        // With all four emitted, two coplanar neighbours' strips meet at the
        // shared rim line one bevel down: the groove has a bottom, which is
        // the whole thing the face version was missing. At a convex corner
        // the strip stops a bevel short of the perpendicular face and leaves
        // a 13 mm notch -- small enough to read as part of the bevel, and it
        // goes away when walls are packed into pieces (V2).
        //
        // 10 triangles a face, and only the near tier pays it.
        const Vector3 back = -n * cut;
        Vector3 edge_out[4];
        for (int i = 0; i < 4; ++i) {
            const int j = (i + 1) % 4;
            edge_out[i] = ((rim[i] + rim[j]) * 0.5f
                    - (in[i] + in[j]) * 0.5f).normalized();
        }
        for (int i = 0; i < 4; ++i) {
            const int j = (i + 1) % 4;
            const Vector3 out = edge_out[i];
            // The facet ALWAYS runs from our inset edge to the rim pushed
            // back along OUR normal. That point is the neighbouring face's
            // own inset edge, whether the neighbour is coplanar or
            // perpendicular, so the geometry is identical in both cases.
            //
            // Pushing it along `out` instead put the far edge exactly on top
            // of the near one -- a zero-area facet -- and every convex edge
            // simply vanished.
            //
            // The ONLY difference convexity makes is ownership: two coplanar
            // faces each draw their half and meet in the middle of the V,
            // while two perpendicular faces would both draw the WHOLE facet,
            // so one of them has to stand down.
            if ((square & (1u << i)) != 0) {
                continue;   // an inside corner takes no bevel
            }
            if ((convex & (1u << i)) != 0 && axis_of(n) > axis_of(out)) {
                continue;   // the perpendicular face owns this facet
            }
            const Vector3 off = back;
            const Vector3 sn = (n + out).normalized();
            // j FIRST. Wound the other way the strip's cross product comes
            // out along +sn instead of -sn, so every chamfer facet faced
            // inward: visible from behind the surface and invisible from in
            // front, which is what the capture showed.
            raw_quad(sn, c, face, in[j], in[i], rim[i] + off, rim[j] + off,
                inuv[j], inuv[i], ruv[i], ruv[j]);
        }

        // --- the corner, where three chamfers meet -----------------------
        //
        // Three faces share a convex corner and each one's strip stops a
        // bevel short of the other two, leaving a triangular hole. You see
        // the backs of the surrounding facets through it, which is the
        // pinwheel of light and dark triangles at every terrace corner.
        //
        // The hole is the triangle joining the three faces' pulled-back rim
        // points. All three faces can compute it -- the other two normals
        // are just this face's two edge outward directions -- so exactly one
        // must own it. The three normals lie on three DIFFERENT axes, so
        // "lowest axis index wins" picks one and only one.
        for (int i = 0; i < 4; ++i) {
            // Only where TWO convex edges meet is there a third face and so a
            // corner hole. A corner between coplanar edges is already closed
            // by the two half-facets.
            if (!(convex & (1u << ((i + 3) % 4))) || !(convex & (1u << i))) {
                continue;
            }
            const Vector3 o1 = edge_out[(i + 3) % 4];
            const Vector3 o2 = edge_out[i];
            const int an = axis_of(n);
            if (an > axis_of(o1) || an > axis_of(o2)) {
                continue;   // a neighbouring face owns this corner
            }
            // The three points where each PAIR of the corner's facets meet.
            // Using rim - n*cut and friends made a triangle twice the size
            // that did not line up with the facets bounding the hole.
            const Vector3 p0 = rim[i] - (o1 + o2) * cut;
            const Vector3 p1 = rim[i] - (n + o2) * cut;
            const Vector3 p2 = rim[i] - (n + o1) * cut;
            tri_facing((n + o1 + o2).normalized(), c, face, p0, p1, p2,
                ruv[i], ruv[i], ruv[i]);
        }
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
void mask_faces(MeshBuf &m, const TileSample &s, const std::vector<int32_t> &owner,
        const std::vector<Piece> &pieces, uint32_t seed) {
    static const int DIRS[6][3] = {
        { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 0, 0, 1 }
    };

    const int y0 = s.y0;
    const int y1 = s.y0 + s.ysize;
    std::vector<uint8_t> face_buf;

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
        return yp <= t && yp > t - PLATES_PER_CELL;
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

    for (int d = 0; d < 6; ++d) {
        const int dx = DIRS[d][0], dy = DIRS[d][1], dz = DIRS[d][2];

        // u and v are the two axes of the slice; w is the slice normal.
        // Sizes are in CELLS; the metre conversion happens at emit.
        const bool along_y = (dy != 0);
        const int u_count = along_y ? TILE : (dx != 0 ? TILE : TILE);
        (void)u_count;

        // Iterate slices along the normal axis.
        const int w_lo = (dx != 0) ? 0 : ((dy != 0) ? y0 : 0);
        const int w_hi = (dx != 0) ? TILE : ((dy != 0) ? y1 : TILE);

        for (int w = w_lo; w < w_hi; ++w) {
            // Mask of this slice: material where a face is exposed, 0 where not.
            const int su = TILE;
            const int sv = (dy != 0) ? TILE : (y1 - y0);
            // One buffer for every slice of every direction. Allocating per
            // slice was six directions times ~85 slices of churn a tile.
            face_buf.assign((size_t)su * sv, 0);
            std::vector<uint8_t> &face = face_buf;

            for (int v = 0; v < sv; ++v) {
                for (int u = 0; u < su; ++u) {
                    int lx, yp, lz;
                    if (dx != 0) {        // slice at x = w, u along z, v along y
                        lx = w; lz = u; yp = y0 + v;
                    } else if (dy != 0) { // slice at y = w, u along x, v along z
                        lx = u; lz = v; yp = w;
                    } else {              // slice at z = w, u along x, v along y
                        lx = u; lz = w; yp = y0 + v;
                    }
                    if (!s.solid(lx, yp, lz)) {
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
                    if (in_piece_solid(lx, yp, lz)) {
                        // A piece owns EVERY face of its own brick, not just
                        // the top — and this is true whether it is bevelled
                        // or not.
                        //
                        // The mask merges walls on its own lattice, which has
                        // nothing to do with where the packer put the piece
                        // boundaries above. So a 2x4 on top had its side
                        // divided somewhere else entirely, and the seams did
                        // not line up from the top to the side of the same
                        // brick. Letting the piece draw its own sides makes
                        // them the same brick by construction.
                        continue;
                    }
                    if (dy == 0 && ramp_covers(lx, yp, lz, dx, dz)) {
                        // The wedge replaces the flat wall on its low side --
                        // that rectangle standing exactly where the slope is
                        // was the square behind every angled piece.
                        continue;
                    }
                    face[(size_t)u + su * v] = (uint8_t)s.voxel(lx, yp, lz);
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
                    // wall. The result was a handful of enormous bricks.
                    //
                    // So a merged face is capped to something a real part
                    // could be, and a vertical face is additionally stopped
                    // at every brick course so a wall reads as courses rather
                    // than as a slab.
                    int max_h;
                    if (dy != 0) {
                        max_h = 2;                     // a 2xN plate, seen from above or below
                    } else {
                        const int yp_here = y0 + v;
                        const int into = ((yp_here % PLATES_PER_CELL) + PLATES_PER_CELL)
                                % PLATES_PER_CELL;
                        max_h = PLATES_PER_CELL - into;   // never cross a course line
                    }

                    // Joints stagger per course, off the same cut lattice the
                    // ground is packed with, so the courses of a cliff do not
                    // line up into vertical seams.
                    const int course = (dy != 0) ? v : floor_div(y0 + v, PLATES_PER_CELL);
                    const int row_key = course * 31 + w * 7 + d;
                    const int u_base = (dx != 0) ? (s.tz * TILE) : (s.tx * TILE);

                    int wdt = 1;
                    while (u + wdt < su && wdt < MAX_LEN
                            && face[(size_t)(u + wdt) + su * v] == mat
                            && !cut_before(seed, u_base + u + wdt, row_key, d & 1)) {
                        ++wdt;
                    }
                    int hgt = 1;
                    while (v + hgt < sv && hgt < max_h) {
                        bool ok = true;
                        for (int k = 0; k < wdt; ++k) {
                            if (face[(size_t)(u + k) + su * (v + hgt)] != mat) {
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
                        lx = w; lz = u; yp = y0 + v;
                    } else if (dy != 0) {
                        lx = u; lz = v; yp = w;
                    } else {
                        lx = u; lz = w; yp = y0 + v;
                    }
                    const Color col = cell_colour(lx, yp, lz);

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
                    {
                        // Unit steps along the slice's U and V axes.
                        const int ux = (dx != 0) ? 0 : 1;
                        const int uz = (dx != 0) ? 1 : 0;
                        const int vy = (dy != 0) ? 0 : 1;
                        const int vz = (dy != 0) ? 1 : 0;
                        const int probe[4][3] = {
                            { 0, -vy, -vz },
                            { ux * wdt, 0, uz * wdt },
                            { 0, vy * hgt, vz * hgt },
                            { -ux, 0, -uz },
                        };
                        // Two tests give all three states:
                        //   neighbour air                  -> convex
                        //   neighbour solid, ITS n-face air -> coplanar
                        //   neighbour solid and covered     -> square
                        for (int k = 0; k < 4; ++k) {
                            const int nx2 = lx + probe[k][0];
                            const int ny2 = yp + probe[k][1];
                            const int nz2 = lz + probe[k][2];
                            if (!s.solid(nx2, ny2, nz2)) {
                                convex |= (uint8_t)(1u << k);
                            } else if (s.solid(nx2 + dx, ny2 + dy, nz2 + dz)) {
                                square |= (uint8_t)(1u << k);
                            }
                            // A solid piece above butts square against this
                            // wall; its own bottom is square too, so neither
                            // side bevels the join.
                            if (g_face_bevel > 0.0f && in_piece_solid(nx2, ny2, nz2)) {
                                convex &= (uint8_t)~(1u << k);
                                square |= (uint8_t)(1u << k);
                            }
                        }
                    }
                    m.quad(Vector3((float)dx, (float)dy, (float)dz), col, fsz,
                        a0, b0, c0, d0,
                        Vector2(0, 0), Vector2(fsz.x, 0), fsz, Vector2(0, fsz.y),
                        convex, square);
                    u += wdt;
                }
            }
        }
    }
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

} // namespace

static int g_coarse_smooth_step = 8;

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

Dictionary BrickTerrain::build_tile(int tx, int tz) {
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();

    TileSample s;
    sample_tile(g_field, tx, tz, s);
    std::vector<Piece> pieces;
    std::vector<int32_t> owner;
    brick::pack_tile(g_field, s, pieces, owner);

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
        }
    }

    std::vector<uint8_t> done((size_t)TILE * TILE, 0);
    for (int lz = 0; lz < TILE; ++lz) {
        for (int lx = 0; lx < TILE; ++lx) {
            if (done[(size_t)lx + TILE * lz]) {
                continue;
            }
            const float t = ctop[(size_t)lx + TILE * lz];
            int w = 1;
            while (lx + w < TILE && !done[(size_t)(lx + w) + TILE * lz] &&
                    ctop[(size_t)(lx + w) + TILE * lz] == t) {
                ++w;
            }
            int d = 1;
            while (lz + d < TILE) {
                bool row_ok = true;
                for (int k = 0; k < w; ++k) {
                    if (done[(size_t)(lx + k) + TILE * (lz + d)] ||
                            ctop[(size_t)(lx + k) + TILE * (lz + d)] != t) {
                        row_ok = false;
                        break;
                    }
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

            // Down to the lowest neighbouring column, so a terrace face has
            // no gap under it. Clamped: a cliff does not need a box to the
            // seabed, only far enough that nothing walks through the face.
            int lowest_p = s.tp[TileSample::idx(lx, lz)];
            for (int dz = -1; dz <= d; ++dz) {
                for (int dx = -1; dx <= w; ++dx) {
                    if (dx >= 0 && dx < w && dz >= 0 && dz < d) {
                        continue;
                    }
                    lowest_p = std::min<int>(lowest_p, s.tp[TileSample::idx(lx + dx, lz + dz)]);
                }
            }
            const float floor_y = (float)(lowest_p + 1) * PLATE_M;
            const float depth = std::max(t - floor_y, BRICK_M);
            boxes.push_back(((float)lx + (float)w * 0.5f) * STUD_M);
            boxes.push_back(t - depth * 0.5f);
            boxes.push_back(((float)lz + (float)d * 0.5f) * STUD_M);
            boxes.push_back((float)w * STUD_M);
            boxes.push_back(depth);
            boxes.push_back((float)d * STUD_M);
        }
    }

    int curve_cells = 0;
    if (g_smooth_terrain) {
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                const int i = TileSample::idx(lx, lz);
                if (!s.smooth[i]) {
                    continue;
                }
                ++curve_cells;
                const float x0 = (float)lx * STUD_M, x1 = (float)(lx + 1) * STUD_M;
                const float z0 = (float)lz * STUD_M, z1 = (float)(lz + 1) * STUD_M;
                const float y00 = corner_y(lx, lz);
                const float y10 = corner_y(lx + 1, lz);
                const float y11 = corner_y(lx + 1, lz + 1);
                const float y01 = corner_y(lx, lz + 1);
                // UV2 ZERO says "no piece here" to the shader: no outline to
                // draw and no perimeter for the nozzle to walk, because a
                // curve is not a moulded part with edges.
                const Vector2 face(0.0f, 0.0f);
                m.material = (uint8_t)s.mat[i];
                const Color col = piece_colour(s, lx, lz, s.mat[i], true);
                const Vector3 v[4] = {
                    Vector3(x0, y00, z0), Vector3(x1, y10, z0),
                    Vector3(x1, y11, z1), Vector3(x0, y01, z1),
                };
                const Vector3 nrm[4] = {
                    corner_n(lx, lz), corner_n(lx + 1, lz),
                    corner_n(lx + 1, lz + 1), corner_n(lx, lz + 1),
                };
                const Vector2 uv[4] = {
                    Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1),
                };
                m.quad_soft(col, face, v, nrm, uv);

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
        // One march a piece, at its middle. A 2x4 is 1.4 m long and the sun
        // does not change over that, so per piece is the right granularity:
        // per column would be eight times the cost for an edge nobody can
        // see, and per tile would put a hard line down the middle of a hill.
        if (!sun_reaches(gx0 + p.ox + p.sx / 2, gz0 + p.oz + p.sz / 2)) {
            col = Color(col.r * SUN_SHADE, col.g * SUN_SHADE, col.b * SUN_SHADE, col.a);
        }
        const float top = (float)(p.top + 1) * PLATE_M;
        const float x0 = (float)p.ox * STUD_M, x1 = (float)(p.ox + p.sx) * STUD_M;
        const float z0 = (float)p.oz * STUD_M, z1 = (float)(p.oz + p.sz) * STUD_M;
        // UV2 is the PIECE's size, so the seam shader outlines a 2x4 as one
        // 2x4 -- not as a grid of eight 1x1s. That is the difference between
        // laid brick and a moulded baseplate, and the reason the mesher packs.
        const Vector2 face((float)p.sx * STUD_M, (float)p.sz * STUD_M);

        if (p.kind == PIECE_RAMP) {
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
            m.quad(n, col, face, a, b, c, d,
                Vector2(0, 0), Vector2(face.x, 0), face, Vector2(0, face.y));
        } else if (p.overlay != 0) {
            // The overlay's top, one plate up. The brick's own top is NOT
            // emitted: it is covered exactly, so it is culled.
            const float oy = top + OVERLAY_M;
            m.quad(Vector3(0, 1, 0), col, face,
                Vector3(x0, oy, z0), Vector3(x1, oy, z0),
                Vector3(x1, oy, z1), Vector3(x0, oy, z1),
                Vector2(0, 0), Vector2(face.x, 0), face, Vector2(0, face.y));
            // The lip: four one-plate walls round the overlay, always drawn,
            // because a neighbour at the same brick height still sits a plate
            // lower unless it carries an overlay too.
            const Vector2 lip(face.x, OVERLAY_M);
            const Vector2 lip_z(face.y, OVERLAY_M);
            m.quad(Vector3(0, 0, -1), col, lip,
                Vector3(x0, top, z0), Vector3(x1, top, z0),
                Vector3(x1, oy, z0), Vector3(x0, oy, z0),
                Vector2(0, lip.y), Vector2(lip.x, lip.y), Vector2(lip.x, 0), Vector2(0, 0));
            m.quad(Vector3(0, 0, 1), col, lip,
                Vector3(x1, top, z1), Vector3(x0, top, z1),
                Vector3(x0, oy, z1), Vector3(x1, oy, z1),
                Vector2(0, lip.y), Vector2(lip.x, lip.y), Vector2(lip.x, 0), Vector2(0, 0));
            m.quad(Vector3(-1, 0, 0), col, lip_z,
                Vector3(x0, top, z1), Vector3(x0, top, z0),
                Vector3(x0, oy, z0), Vector3(x0, oy, z1),
                Vector2(0, lip_z.y), Vector2(lip_z.x, lip_z.y), Vector2(lip_z.x, 0), Vector2(0, 0));
            m.quad(Vector3(1, 0, 0), col, lip_z,
                Vector3(x1, top, z0), Vector3(x1, top, z1),
                Vector3(x1, oy, z1), Vector3(x1, oy, z0),
                Vector2(0, lip_z.y), Vector2(lip_z.x, lip_z.y), Vector2(lip_z.x, 0), Vector2(0, 0));
        } else {
            // A side is convex where the ground DROPS AWAY, because that is
            // where a wall face exists for the chamfer to meet. Level with a
            // neighbour, or under one, it is coplanar or concave, and there
            // the two half-facets close the groove between them.
            uint8_t convex = 0;
            uint8_t square = 0;
            bool lo_zm = false, lo_zp = false, lo_xm = false, lo_xp = false;
            bool hi_zm = false, hi_zp = false, hi_xm = false, hi_xp = false;
            for (int dx2 = 0; dx2 < p.sx; ++dx2) {
                const int16_t a2 = s.tp[TileSample::idx(p.ox + dx2, p.oz - 1)];
                const int16_t b2 = s.tp[TileSample::idx(p.ox + dx2, p.oz + p.sz)];
                if (a2 < p.top) lo_zm = true;
                if (b2 < p.top) lo_zp = true;
                if (a2 > p.top) hi_zm = true;
                if (b2 > p.top) hi_zp = true;
            }
            for (int dz2 = 0; dz2 < p.sz; ++dz2) {
                const int16_t a2 = s.tp[TileSample::idx(p.ox - 1, p.oz + dz2)];
                const int16_t b2 = s.tp[TileSample::idx(p.ox + p.sx, p.oz + dz2)];
                if (a2 < p.top) lo_xm = true;
                if (b2 < p.top) lo_xp = true;
                if (a2 > p.top) hi_xm = true;
                if (b2 > p.top) hi_xp = true;
            }
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
                m.quad(Vector3(0, 1, 0), col, face,
                    Vector3(x0, top, z0), Vector3(x1, top, z0),
                    Vector3(x1, top, z1), Vector3(x0, top, z1),
                    Vector2(0, 0), Vector2(face.x, 0), face, Vector2(0, face.y),
                    0, square);
                // ...and its own sides, so a brick's side seam is the same
                // brick as its top. Only where the ground drops away; level
                // with a neighbour the face is interior. SQUARE: the top's
                // strip already runs down onto them.
                const uint8_t SQ = 0xF;
                const float yb = top - BRICK_M;
                const Vector2 fzy(z1 - z0, BRICK_M);
                const Vector2 fxy(x1 - x0, BRICK_M);
                if (lo_xm) {
                    m.quad(Vector3(-1, 0, 0), col, fzy,
                        Vector3(x0, yb, z1), Vector3(x0, yb, z0),
                        Vector3(x0, top, z0), Vector3(x0, top, z1),
                        Vector2(0, 0), Vector2(fzy.x, 0), fzy, Vector2(0, fzy.y), 0, SQ);
                }
                if (lo_xp) {
                    m.quad(Vector3(1, 0, 0), col, fzy,
                        Vector3(x1, yb, z0), Vector3(x1, yb, z1),
                        Vector3(x1, top, z1), Vector3(x1, top, z0),
                        Vector2(0, 0), Vector2(fzy.x, 0), fzy, Vector2(0, fzy.y), 0, SQ);
                }
                if (lo_zm) {
                    m.quad(Vector3(0, 0, -1), col, fxy,
                        Vector3(x0, yb, z0), Vector3(x1, yb, z0),
                        Vector3(x1, top, z0), Vector3(x0, top, z0),
                        Vector2(0, 0), Vector2(fxy.x, 0), fxy, Vector2(0, fxy.y), 0, SQ);
                }
                if (lo_zp) {
                    m.quad(Vector3(0, 0, 1), col, fxy,
                        Vector3(x1, yb, z1), Vector3(x0, yb, z1),
                        Vector3(x0, top, z1), Vector3(x1, top, z1),
                        Vector2(0, 0), Vector2(fxy.x, 0), fxy, Vector2(0, fxy.y), 0, SQ);
                }
            }
        }
    }

    // Every face the surface packer did not draw: terrace sides, cave roofs,
    // overhang undersides, crater walls. Section 17.2 -- this is the pass
    // that makes the world volumetric rather than a skin.
    mask_faces(m, s, owner, pieces, g_field.seed);

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
    int stud_count = 0;
    int scatter_count = 0;

    std::vector<uint8_t> blocked((size_t)TILE * TILE, 0);

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
            if (s.plate[i] == 0 || s.mat[i] == MAT_ROAD) {
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
                if (s.plate[i] && !tiled && material_studded(s.mat[i])) {
                    Color c = piece_colour(s, lx, lz, s.mat[i], true);
                    c.a = 1.0f;
                    // On the CURVE's own surface. The column top is up to
                    // half a plate away from it now that the curve follows
                    // the unquantised field, and a stud floating 7 cm over
                    // the ground is the first thing anyone would notice.
                    push_instance(studs, ((float)lx + 0.5f) * STUD_M,
                        cell_surface(lx, lz),
                        ((float)lz + 0.5f) * STUD_M, 0.0f, c);
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
            push_instance(studs, ((float)lx + 0.5f) * STUD_M, y,
                ((float)lz + 0.5f) * STUD_M, 0.0f, c);
            ++stud_count;
        }
    }

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

    Dictionary out;
    out["mesh"] = mesh;
    out["studs"] = studs;
    out["tufts"] = tufts;
    out["pebbles"] = pebbles;
    out["boxes"] = boxes;
    out["box_count"] = boxes.size() / 6;
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

void BrickTerrain::_bind_methods() {
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
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_face_bevel", "metres"),
        &BrickTerrain::set_face_bevel);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_face_bevel"),
        &BrickTerrain::get_face_bevel);
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
    ClassDB::bind_static_method("BrickTerrain",
        D_METHOD("build_coarse", "tx0", "tz0", "span", "step"),
        &BrickTerrain::build_coarse);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("set_coarse_smooth_step", "step"),
        &BrickTerrain::set_coarse_smooth_step);
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("get_coarse_smooth_step"),
        &BrickTerrain::get_coarse_smooth_step);

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
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_BRICK", PIECE_BRICK);
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_TILE", PIECE_TILE);
    ClassDB::bind_integer_constant("BrickTerrain", "PieceKind", "PIECE_RAMP", PIECE_RAMP);
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
    const double q = (x / (double)STUD_M + (double)g_shore_half) / (double)g_shore_step;
    const double r = (z / (double)STUD_M + (double)g_shore_half) / (double)g_shore_step;
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
    step = std::max(step, 1);
    const int n = std::max(2 * half_studs / step, 2);
    g_shore.assign((size_t)n * n * 2, 0.0f);
    std::vector<float> dist((size_t)n * n);
    const float INF = 1.0e9f;
    for (int iz = 0; iz < n; ++iz) {
        for (int ix = 0; ix < n; ++ix) {
            const int gx = ix * step - half_studs;
            const int gz = iz * step - half_studs;
            const float ground = (float)(BrickTerrain::surface_plate(gx, gz) + 1) * PLATE_M;
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
    g_shore_n = n;
    g_shore_half = half_studs;
    g_shore_step = step;
    PackedFloat32Array out;
    out.resize((int64_t)g_shore.size());
    std::copy(g_shore.begin(), g_shore.end(), out.ptrw());
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
    ClassDB::bind_static_method("BrickWave", D_METHOD("group_at", "x", "z", "t"),
        &BrickWave::group_at);
    ClassDB::bind_static_method("BrickWave", D_METHOD("band_at", "x", "z", "t"),
        &BrickWave::band_at);
    ClassDB::bind_static_method("BrickWave", D_METHOD("terrace_studs"), &BrickWave::terrace_studs);
}
