#include "brick_terrain.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cmath>
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
/// Above this the biome asks for curves -- value_noise is [-1, 1], so zero
/// is about half the map before steepness gets a say.
constexpr float BIAS = 0.0f;
/// ...but only where it is not steep. A cliff of stacked courses looks
/// BUILT, and a smooth 45-degree slope is where a heightfield looks most
/// like a heightfield -- so steepness overrules the biome, never the other
/// way round.
///
/// In plates a stud, on the UNQUANTISED surface. Measured on this field:
/// median 0.17, p90 0.50, max 0.67, so 0.30 keeps the flats and hands the
/// valley sides back to the bricks.
constexpr float MAX_SLOPE = 0.30f;
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
    return qstep <= smoothcfg::MAX_QSTEP
            && surface_slope(f, x, z) <= smoothcfg::MAX_SLOPE
            && value_noise((float)x * smoothcfg::FREQ, (float)z * smoothcfg::FREQ,
                    f.seed + 6197U) > smoothcfg::BIAS;
}

/// Quantise the surface to plates rather than bricks. See set_plate_steps.
static bool g_plate_steps = false;

float Field::raw_plate(int x, int z) const {
    const float base = fbm((float)x * 0.010f, (float)z * 0.010f, seed, 3, 2.0f, 0.5f);
    const float detail = value_noise((float)x * 0.035f, (float)z * 0.035f, seed + 977U) * 0.25f;
    return (base + detail) * 7.0f * (float)PLATES_PER_CELL
            + 5.0f * (float)PLATES_PER_CELL;
}

int Field::top_plate(int x, int z) const {
    // 0.010 per stud is a ~100-stud (35 m) feature size for the base shape.
    const float base = fbm((float)x * 0.010f, (float)z * 0.010f, seed, 3, 2.0f, 0.5f);
    const float detail = value_noise((float)x * 0.035f, (float)z * 0.035f, seed + 977U) * 0.25f;
    // fBm over value noise rarely reaches its extremes, so the multiplier is
    // bigger than the nominal range suggests: x4 measured only five terraces
    // across the whole test field.
    const float v = base + detail;
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
        // The same relief, cut into plates instead of bricks: three times the
        // steps, each a third the height.
        return (int)std::floor(v * 7.0f * (float)PLATES_PER_CELL
                + 5.0f * (float)PLATES_PER_CELL);
    }
    return ((int)std::floor(v * 7.0f + 5.0f) + 1) * PLATES_PER_CELL - 1;
}

int Field::nominal_height(int x, int z) const {
    return floor_div(top_plate(x, z), PLATES_PER_CELL);
}

int Field::material_at(int x, int z, int h) const {
    const float d = value_noise((float)x * 0.021f, (float)z * 0.021f, seed + 4241U);
    if (h <= 1) {
        return MAT_SAND;
    }
    if (h >= 7) {
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
                if (s.tp[i] != tp0 || s.h[i] != h0 || s.mat[i] != m0) {
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

    void raw_quad(const Vector3 &n, const Color &c, const Vector2 &face,
            const Vector3 &a, const Vector3 &b, const Vector3 &d, const Vector3 &e,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &ud, const Vector2 &ue) {
        const int base = verts.size();
        verts.push_back(a); verts.push_back(b); verts.push_back(d); verts.push_back(e);
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
    Color c = filament_colour(material_filament(mat));
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
        Color c = filament_colour(material_filament(mat));
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

Dictionary BrickTerrain::build_tile(int tx, int tz) {
    const uint64_t t0 = Time::get_singleton()->get_ticks_usec();

    TileSample s;
    sample_tile(g_field, tx, tz, s);
    std::vector<Piece> pieces;
    std::vector<int32_t> owner;
    brick::pack_tile(g_field, s, pieces, owner);

    MeshBuf m;
    PackedFloat32Array boxes;

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
                float sum = 0.0f;
                int n = 0;
                int hard = -100000;
                for (int dz = -1; dz <= 0; ++dz) {
                    for (int dx = -1; dx <= 0; ++dx) {
                        const int i = TileSample::idx(cx + dx, cz + dz);
                        sum += (float)(s.tp[i] + 1) * PLATE_M;
                        ++n;
                        if (!s.smooth[i]) {
                            hard = std::max<int>(hard, s.tp[i]);
                        }
                    }
                }
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
    auto corner_n = [&](int cx, int cz) -> Vector3 {
        const float dx = corner_y(cx - 1, cz) - corner_y(cx + 1, cz);
        const float dz = corner_y(cx, cz - 1) - corner_y(cx, cz + 1);
        return Vector3(dx, 2.0f * STUD_M, dz).normalized();
    };

    if (g_smooth_terrain) {
        for (int lz = 0; lz < TILE; ++lz) {
            for (int lx = 0; lx < TILE; ++lx) {
                const int i = TileSample::idx(lx, lz);
                if (!s.smooth[i]) {
                    continue;
                }
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
        const Color col = piece_colour(s, p.ox, p.oz, p.mat, p.studded != 0);
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
    const int gx0 = tx * TILE;
    const int gz0 = tz * TILE;

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
                if (o < 0 || pieces[o].kind != PIECE_BRICK) {
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
            const float base = (float)(s.tp[i] + 1) * PLATE_M
                    + (pieces[o].overlay != 0 ? OVERLAY_M : 0.0f);
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
                if (s.plate[i] && material_studded(s.mat[i])) {
                    Color c = piece_colour(s, lx, lz, s.mat[i], true);
                    c.a = 1.0f;
                    push_instance(studs, ((float)lx + 0.5f) * STUD_M,
                        (float)(s.tp[i] + 1) * PLATE_M,
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

    Array mesh;
    if (!m.verts.is_empty()) {
        mesh.resize(Mesh::ARRAY_MAX);
        mesh[Mesh::ARRAY_VERTEX] = m.verts;
        mesh[Mesh::ARRAY_NORMAL] = m.normals;
        mesh[Mesh::ARRAY_COLOR] = m.colours;
        mesh[Mesh::ARRAY_TEX_UV] = m.uvs;
        mesh[Mesh::ARRAY_TEX_UV2] = m.uv2s;
        mesh[Mesh::ARRAY_INDEX] = m.indices;
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
    ClassDB::bind_static_method("BrickTerrain", D_METHOD("smooth_at", "x", "z"),
        &BrickTerrain::smooth_at);
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
    const int gx = (int)std::floor(x / (double)STUD_M);
    const int gz = (int)std::floor(z / (double)STUD_M);
    const double ground = (double)(BrickTerrain::height_at(gx, gz) + 1) * (double)BRICK_M;
    const double depth = g_sea_level - ground;
    if (depth <= 0.0) {
        return 0.0;
    }
    return std::min(depth / SHORE_TAPER_DEPTH, OPEN_SEA_TAPER);
}

} // namespace

/// Water quantises to one BRICK, not one plate. At A=1 m, L=12 m the mean
/// surface slope is 0.52, so a plate step gives a 0.76-stud terrace -- every
/// cell on a different step, which reads as noise. A brick step gives 2.3
/// studs, which reads as a terrace (Water section 2).
double BrickWave::get_step_metres() { return (double)BRICK_M; }

double BrickWave::shore_gain(double x, double z) { return shore_taper(x, z); }

double BrickWave::height_at(double x, double z, double t) {
    // One field query a sample, for the shore ramp. That is an fBm evaluation
    // where there used to be none, so this is a per-BODY call and not a
    // per-vertex one -- which is what `sample_heights` is for.
    const double taper = shore_taper(x, z);
    double h = g_sea_level;
    for (int i = 0; i < WAVE_COUNT; ++i) {
        const WaveComponent &w = WAVES[i];
        const double len = w.wavelength * g_wave_gain;
        const double k = Math_TAU / len;
        h += w.amplitude * g_wave_gain * taper
                * std::sin((std::cos(w.angle) * x + std::sin(w.angle) * z) * k
                - omega(len) * t + w.phase);
    }
    return h;
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
    ClassDB::bind_static_method("BrickWave", D_METHOD("terrace_studs"), &BrickWave::terrace_studs);
}
