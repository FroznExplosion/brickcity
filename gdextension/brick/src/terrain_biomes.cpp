#include "terrain_biomes.h"

#include "brick_terrain.h"

#include <godot_cpp/variant/array.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>

using namespace godot;

namespace brick {

static std::atomic<int> g_mode{ 0 };
static GenParams g_params;
static bool g_params_ready = false;

int gen_mode() { return g_mode.load(std::memory_order_acquire); }
void set_gen_mode(int mode) { g_mode.store(mode, std::memory_order_release); }

static inline float clampf(float v, float lo, float hi) { return std::min(std::max(v, lo), hi); }
static inline float smooth01(float t) {
    t = clampf(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}
static inline float smoothstep(float a, float b, float v) {
    return smooth01((v - a) / std::max(b - a, 1e-5f));
}
static inline int fdiv(int a, int b) {
    const int q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}
static inline int fbrick(float metres) { return (int)std::floor(metres / BRICK_M); }

/// fBm over value noise sits well inside its nominal range (three octaves
/// rarely pass 0.5), so every macro noise is spread back out to about -1..1.
static inline float spread(float v) { return clampf(v * 1.9f, -1.0f, 1.0f); }

// --- defaults ----------------------------------------------------------------

static BiomeDef bdef(const char *name, int kind, float t, float h, float w, int top, int under,
        int ud, int under2, int u2d, int stone, float hill, int map) {
    BiomeDef b;
    b.name = name;
    b.kind = kind;
    b.temp = t;
    b.humid = h;
    b.weird = w;
    b.top = top;
    b.under = under;
    b.under_depth = ud;
    b.under2 = under2;
    b.under2_depth = u2d;
    b.stone = stone;
    b.hilliness = hill;
    b.map_colour = map;
    return b;
}

static OreDef odef(const char *name, int mat, float chance, float size, float lo, float hi) {
    OreDef o;
    o.name = name;
    o.material = mat;
    o.chance = chance;
    o.size = size;
    o.min_m = lo;
    o.max_m = hi;
    return o;
}

// The biome ids are these indices: the menu and the trees refer to them.
enum BiomeId {
    B_OCEAN = 0, B_BEACH, B_SHORE, B_RIVER, B_PLAINS, B_FOREST, B_BIRCH, B_DARK_FOREST,
    B_TAIGA, B_SNOWY_PLAINS, B_SNOWY_TAIGA, B_DESERT, B_SAVANNA, B_BADLANDS, B_JUNGLE,
    B_MEADOW, B_HILLS, B_STONY_PEAKS, B_SNOWY_PEAKS, B_SNOWY_BEACH, B_COUNT
};

void reset_gen_params() {
    GenParams p;
    // DEEP WORLDS (Docs/MineWorld.md 16): bedrock 300 bricks (126 m) under
    // the sea line, and everything that was laid out for a 48 m world
    // stretched to it (x 2.625 below the sea line): deepslate from a third
    // of the way down, each ore over the same share of the depth.
    p.bands.push_back(DeepBand{ -42.0f, MAT_DARK_STONE, true });
    p.ores = {
        odef("Coal", MAT_COAL, 0.50f, 1.8f, -52.0f, 70.0f),
        odef("Iron", MAT_IRON, 0.35f, 1.5f, -105.0f, 30.0f),
        odef("Copper", MAT_COPPER, 0.30f, 1.6f, -52.0f, 20.0f),
        odef("Gold", MAT_GOLD, 0.15f, 1.2f, -121.0f, -31.0f),
        odef("Redstone", MAT_REDSTONE, 0.20f, 1.4f, -126.0f, -63.0f),
        odef("Lapis", MAT_LAPIS, 0.12f, 1.2f, -118.0f, -21.0f),
        odef("Diamond", MAT_DIAMOND, 0.08f, 1.0f, -126.0f, -84.0f),
    };
    p.biomes.resize(B_COUNT);
    p.biomes[B_OCEAN] = bdef("Dry Ocean", BK_OCEAN, 0, 0, 0, MAT_SAND, MAT_SAND, 3, MAT_GRAVEL, 1, MAT_STONE, 0.25f, 47);
    p.biomes[B_BEACH] = bdef("Beach", BK_BEACH, 0, 0, 0, MAT_SAND, MAT_SAND, 3, MAT_SANDSTONE, 2, MAT_STONE, 0.0f, 29);
    p.biomes[B_SHORE] = bdef("Stony Shore", BK_SHORE, 0, 0, 0, MAT_STONE, MAT_STONE, 2, MAT_STONE, 0, MAT_STONE, 0.3f, 13);
    p.biomes[B_RIVER] = bdef("Dry River", BK_RIVER, 0, 0, 0, MAT_SAND, MAT_SAND, 2, MAT_GRAVEL, 1, MAT_STONE, 0.0f, 44);
    p.biomes[B_PLAINS] = bdef("Plains", BK_LAND, 0.10f, -0.10f, 0.0f, MAT_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.12f, 7);
    p.biomes[B_FOREST] = bdef("Forest", BK_LAND, 0.15f, 0.30f, 0.0f, MAT_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.55f, 41);
    p.biomes[B_BIRCH] = bdef("Birch Forest", BK_LAND, -0.05f, 0.10f, 0.0f, MAT_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.45f, 38);
    p.biomes[B_DARK_FOREST] = bdef("Dark Forest", BK_LAND, 0.30f, 0.65f, 0.0f, MAT_DARK_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.60f, 34);
    p.biomes[B_TAIGA] = bdef("Taiga", BK_LAND, -0.50f, 0.30f, 0.0f, MAT_COLD_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.70f, 39);
    p.biomes[B_SNOWY_PLAINS] = bdef("Snowy Plains", BK_LAND, -0.90f, -0.30f, 0.0f, MAT_SNOW, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.15f, 0);
    p.biomes[B_SNOWY_TAIGA] = bdef("Snowy Taiga", BK_LAND, -0.90f, 0.35f, 0.0f, MAT_SNOW, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.60f, 48);
    p.biomes[B_DESERT] = bdef("Desert", BK_LAND, 0.80f, -0.70f, 0.0f, MAT_SAND, MAT_SAND, 3, MAT_SANDSTONE, 4, MAT_STONE, 0.35f, 30);
    p.biomes[B_SAVANNA] = bdef("Savanna", BK_LAND, 0.55f, -0.35f, 0.0f, MAT_DRY_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.30f, 33);
    p.biomes[B_BADLANDS] = bdef("Badlands", BK_LAND, 0.85f, -0.45f, 0.8f, MAT_RED_SAND, MAT_RED_SAND, 1, MAT_TERRA_ORANGE, 0, MAT_TERRA_ORANGE, 1.10f, 60);
    p.biomes[B_JUNGLE] = bdef("Jungle", BK_LAND, 0.70f, 0.70f, 0.0f, MAT_LUSH_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.90f, 35);
    p.biomes[B_MEADOW] = bdef("Meadow", BK_LAND, -0.25f, -0.10f, -0.8f, MAT_LUSH_GRASS, MAT_DIRT, 3, MAT_DIRT, 0, MAT_STONE, 0.25f, 36);
    p.biomes[B_HILLS] = bdef("Windswept Hills", BK_HILLS, 0, 0, 0, MAT_GRASS, MAT_DIRT, 2, MAT_DIRT, 0, MAT_STONE, 1.00f, 63);
    p.biomes[B_STONY_PEAKS] = bdef("Stony Peaks", BK_PEAKS, 0, 0, 0, MAT_STONE, MAT_STONE, 2, MAT_STONE, 0, MAT_STONE, 1.00f, 2);
    p.biomes[B_SNOWY_PEAKS] = bdef("Snowy Peaks", BK_SNOWY_PEAKS, 0, 0, 0, MAT_SNOW, MAT_SNOW, 2, MAT_STONE, 0, MAT_STONE, 1.00f, 12);
    p.biomes[B_SNOWY_BEACH] = bdef("Snowy Beach", BK_SNOWY_BEACH, 0, 0, 0, MAT_SNOW, MAT_SAND, 3, MAT_SANDSTONE, 1, MAT_STONE, 0.0f, 32);
    g_params = p;
    g_params_ready = true;
}

GenParams &gen_params() {
    if (!g_params_ready) {
        reset_gen_params();
    }
    return g_params;
}

// --- Dictionary <-> params ----------------------------------------------------

#define GP_FLOAT(key, field) \
    if (d.has(key)) { p.field = (float)(double)d[key]; }
#define GP_INT(key, field) \
    if (d.has(key)) { p.field = (int)d[key]; }
#define GP_BOOL(key, field) \
    if (d.has(key)) { p.field = (bool)d[key]; }

static int clamp_mat(int m) { return std::min(std::max(m, 1), (int)MATERIAL_COUNT - 1); }

void gen_params_from_dict(const Dictionary &d) {
    apply_gen_dict(gen_params(), d);
}

void apply_gen_dict(GenParams &p, const Dictionary &d) {
    GP_FLOAT("height_scale", height_scale)
    GP_FLOAT("sea_m", sea_m)
    GP_FLOAT("continent_scale_m", continent_scale_m)
    GP_FLOAT("ocean_threshold", ocean_threshold)
    GP_FLOAT("ocean_depth_m", ocean_depth_m)
    GP_FLOAT("base_height_m", base_height_m)
    GP_FLOAT("cont_weight_m", cont_weight_m)
    GP_FLOAT("erosion_scale_m", erosion_scale_m)
    GP_FLOAT("hill_height_m", hill_height_m)
    GP_FLOAT("hill_scale_m", hill_scale_m)
    GP_FLOAT("peak_height_m", peak_height_m)
    GP_FLOAT("mountain_threshold", mountain_threshold)
    GP_FLOAT("mountain_gain", mountain_gain)
    GP_FLOAT("ridge_scale_m", ridge_scale_m)
    GP_FLOAT("valley_depth_m", valley_depth_m)
    GP_FLOAT("valley_width", valley_width)
    GP_FLOAT("valley_scale_m", valley_scale_m)
    GP_BOOL("far_lands", far_lands)
    GP_FLOAT("far_lands_intensity", far_lands_intensity)
    GP_FLOAT("cliff_amount", cliff_amount)
    GP_FLOAT("cliff_step_m", cliff_step_m)
    GP_FLOAT("overhang_amount", overhang_amount)
    GP_FLOAT("overhang_size_m", overhang_size_m)
    GP_FLOAT("beach_width_m", beach_width_m)
    GP_INT("basin_sand_depth", basin_sand_depth)
    GP_BOOL("water", water)
    GP_BOOL("lava_pools", lava_pools)
    GP_FLOAT("lava_m", lava_m)
    GP_BOOL("springs", springs)
    GP_FLOAT("spring_chance", spring_chance)
    GP_BOOL("caves", caves)
    GP_BOOL("deep_caves", deep_caves)
    GP_FLOAT("cave_intensity", cave_intensity)
    GP_FLOAT("cave_min_depth_m", cave_min_depth_m)
    GP_FLOAT("cave_max_depth_m", cave_max_depth_m)
    GP_BOOL("ravines", ravines)
    GP_FLOAT("ravine_width", ravine_width)
    GP_FLOAT("ravine_depth_m", ravine_depth_m)
    GP_FLOAT("biome_scale_m", biome_scale_m)
    GP_FLOAT("temp_offset", temp_offset)
    GP_FLOAT("humid_offset", humid_offset)
    GP_FLOAT("snow_line_m", snow_line_m)
    GP_FLOAT("bedrock_m", bedrock_m)
    GP_FLOAT("stone_patches", stone_patches)
    // Guard rails: a zero scale is a division by zero and a world of NaN.
    p.continent_scale_m = std::max(p.continent_scale_m, 50.0f);
    p.erosion_scale_m = std::max(p.erosion_scale_m, 30.0f);
    p.hill_scale_m = std::max(p.hill_scale_m, 10.0f);
    p.ridge_scale_m = std::max(p.ridge_scale_m, 20.0f);
    p.valley_scale_m = std::max(p.valley_scale_m, 50.0f);
    p.biome_scale_m = std::max(p.biome_scale_m, 50.0f);
    p.cliff_step_m = std::max(p.cliff_step_m, 1.0f);
    p.overhang_size_m = clampf(p.overhang_size_m, 0.0f, 30.0f);
    p.cave_max_depth_m = clampf(p.cave_max_depth_m, 0.0f, 60.0f);
    p.ravine_depth_m = clampf(p.ravine_depth_m, 0.0f, 60.0f);
    p.basin_sand_depth = std::max(p.basin_sand_depth, 1);

    if (d.has("bands")) {
        const Array a = d["bands"];
        p.bands.clear();
        for (int i = 0; i < a.size(); ++i) {
            const Dictionary b = a[i];
            DeepBand band;
            band.top_m = (float)(double)b.get("top_m", -16.0);
            band.material = clamp_mat((int)b.get("material", (int)MAT_DARK_STONE));
            band.enabled = (bool)b.get("enabled", true);
            p.bands.push_back(band);
        }
    }
    if (d.has("ores")) {
        const Array a = d["ores"];
        for (int i = 0; i < a.size() && i < (int)p.ores.size(); ++i) {
            const Dictionary o = a[i];
            OreDef &od = p.ores[(size_t)i];
            od.chance = clampf((float)(double)o.get("chance", od.chance), 0.0f, 1.0f);
            od.size = clampf((float)(double)o.get("size", od.size), 0.5f, 3.0f);
            od.min_m = (float)(double)o.get("min_m", od.min_m);
            od.max_m = (float)(double)o.get("max_m", od.max_m);
        }
    }
    if (d.has("biomes")) {
        const Array a = d["biomes"];
        for (int i = 0; i < a.size() && i < (int)p.biomes.size(); ++i) {
            const Dictionary o = a[i];
            BiomeDef &b = p.biomes[(size_t)i];
            b.enabled = (bool)o.get("enabled", b.enabled);
            b.temp = clampf((float)(double)o.get("temp", b.temp), -1.0f, 1.0f);
            b.humid = clampf((float)(double)o.get("humid", b.humid), -1.0f, 1.0f);
            b.weird = clampf((float)(double)o.get("weird", b.weird), -1.0f, 1.0f);
            b.top = clamp_mat((int)o.get("top", b.top));
            b.under = clamp_mat((int)o.get("under", b.under));
            b.under2 = clamp_mat((int)o.get("under2", b.under2));
            b.stone = clamp_mat((int)o.get("stone", b.stone));
            b.under_depth = std::max((int)o.get("under_depth", b.under_depth), 0);
            b.under2_depth = std::max((int)o.get("under2_depth", b.under2_depth), 0);
            b.hilliness = clampf((float)(double)o.get("hilliness", b.hilliness), 0.0f, 3.0f);
        }
    }
}

Dictionary gen_params_to_dict() {
    const GenParams &p = gen_params();
    Dictionary d;
    d["height_scale"] = p.height_scale;
    d["sea_m"] = p.sea_m;
    d["continent_scale_m"] = p.continent_scale_m;
    d["ocean_threshold"] = p.ocean_threshold;
    d["ocean_depth_m"] = p.ocean_depth_m;
    d["base_height_m"] = p.base_height_m;
    d["cont_weight_m"] = p.cont_weight_m;
    d["erosion_scale_m"] = p.erosion_scale_m;
    d["hill_height_m"] = p.hill_height_m;
    d["hill_scale_m"] = p.hill_scale_m;
    d["peak_height_m"] = p.peak_height_m;
    d["mountain_threshold"] = p.mountain_threshold;
    d["mountain_gain"] = p.mountain_gain;
    d["ridge_scale_m"] = p.ridge_scale_m;
    d["valley_depth_m"] = p.valley_depth_m;
    d["valley_width"] = p.valley_width;
    d["valley_scale_m"] = p.valley_scale_m;
    d["far_lands"] = p.far_lands;
    d["far_lands_intensity"] = p.far_lands_intensity;
    d["cliff_amount"] = p.cliff_amount;
    d["cliff_step_m"] = p.cliff_step_m;
    d["overhang_amount"] = p.overhang_amount;
    d["overhang_size_m"] = p.overhang_size_m;
    d["beach_width_m"] = p.beach_width_m;
    d["basin_sand_depth"] = p.basin_sand_depth;
    d["water"] = p.water;
    d["lava_pools"] = p.lava_pools;
    d["lava_m"] = p.lava_m;
    d["springs"] = p.springs;
    d["spring_chance"] = p.spring_chance;
    d["caves"] = p.caves;
    d["deep_caves"] = p.deep_caves;
    d["cave_intensity"] = p.cave_intensity;
    d["cave_min_depth_m"] = p.cave_min_depth_m;
    d["cave_max_depth_m"] = p.cave_max_depth_m;
    d["ravines"] = p.ravines;
    d["ravine_width"] = p.ravine_width;
    d["ravine_depth_m"] = p.ravine_depth_m;
    d["biome_scale_m"] = p.biome_scale_m;
    d["temp_offset"] = p.temp_offset;
    d["humid_offset"] = p.humid_offset;
    d["snow_line_m"] = p.snow_line_m;
    d["bedrock_m"] = p.bedrock_m;
    d["stone_patches"] = p.stone_patches;
    Array bands;
    for (const DeepBand &b : p.bands) {
        Dictionary e;
        e["top_m"] = b.top_m;
        e["material"] = b.material;
        e["enabled"] = b.enabled;
        bands.push_back(e);
    }
    d["bands"] = bands;
    Array ores;
    for (const OreDef &o : p.ores) {
        Dictionary e;
        e["name"] = String(o.name.c_str());
        e["material"] = o.material;
        e["chance"] = o.chance;
        e["size"] = o.size;
        e["min_m"] = o.min_m;
        e["max_m"] = o.max_m;
        ores.push_back(e);
    }
    d["ores"] = ores;
    Array biomes;
    for (const BiomeDef &b : p.biomes) {
        Dictionary e;
        e["name"] = String(b.name.c_str());
        e["kind"] = b.kind;
        e["enabled"] = b.enabled;
        e["temp"] = b.temp;
        e["humid"] = b.humid;
        e["weird"] = b.weird;
        e["top"] = b.top;
        e["under"] = b.under;
        e["under2"] = b.under2;
        e["stone"] = b.stone;
        e["under_depth"] = b.under_depth;
        e["under2_depth"] = b.under2_depth;
        e["hilliness"] = b.hilliness;
        e["map_colour"] = b.map_colour;
        biomes.push_back(e);
    }
    d["biomes"] = biomes;
    return d;
}

PackedStringArray biome_names() {
    PackedStringArray out;
    for (const BiomeDef &b : gen_params().biomes) {
        out.push_back(String(b.name.c_str()));
    }
    return out;
}

// --- the column -----------------------------------------------------------------

/// Nearest enabled LAND biome to a climate point; -1 if none is enabled.
static int climate_pick(const GenParams &p, float t, float h, float w) {
    int best = -1;
    float bd = 1e9f;
    for (size_t i = 0; i < p.biomes.size(); ++i) {
        const BiomeDef &b = p.biomes[i];
        if (b.kind != BK_LAND || !b.enabled) {
            continue;
        }
        const float dt = t - b.temp, dh = h - b.humid, dw = (w - b.weird) * 0.7f;
        const float dist = dt * dt + dh * dh + dw * dw;
        if (dist < bd) {
            bd = dist;
            best = (int)i;
        }
    }
    return best;
}

/// The land biomes' hilliness, weighted by closeness in climate space, so a
/// biome border changes the relief gradually instead of with a step.
static float climate_hilliness(const GenParams &p, float t, float h, float w) {
    float sum = 0.0f, wsum = 0.0f;
    for (const BiomeDef &b : p.biomes) {
        if (b.kind != BK_LAND || !b.enabled) {
            continue;
        }
        const float dt = t - b.temp, dh = h - b.humid, dw = (w - b.weird) * 0.7f;
        const float k = std::exp(-(dt * dt + dh * dh + dw * dw) * 14.0f);
        sum += b.hilliness * k;
        wsum += k;
    }
    return wsum > 1e-6f ? sum / wsum : 0.5f;
}

static bool usable(const GenParams &p, int id) {
    return id >= 0 && id < (int)p.biomes.size() && p.biomes[(size_t)id].enabled;
}

BColumn biome_column(const GenParams &p, uint32_t seed, int x, int z) {
    const float fx = (float)x * STUD_M;
    const float fz = (float)z * STUD_M;

    const float c = spread(fbm(fx / p.continent_scale_m, fz / p.continent_scale_m, seed + 101U, 5, 2.0f, 0.5f));
    const float e = spread(fbm(fx / p.erosion_scale_m, fz / p.erosion_scale_m, seed + 202U, 3, 2.0f, 0.5f));
    const float e01 = clampf(e * 0.5f + 0.5f, 0.0f, 1.0f);
    float ridge = 1.0f - std::fabs(spread(fbm(fx / p.ridge_scale_m, fz / p.ridge_scale_m, seed + 303U, 4, 2.0f, 0.5f)));
    ridge = ridge * ridge;
    const float hn = spread(fbm(fx / p.hill_scale_m, fz / p.hill_scale_m, seed + 404U, 4, 2.0f, 0.5f));

    const float temp = spread(fbm(fx / p.biome_scale_m, fz / p.biome_scale_m, seed + 505U, 3, 2.0f, 0.5f)) + p.temp_offset;
    const float humid = spread(fbm(fx / p.biome_scale_m, fz / p.biome_scale_m, seed + 606U, 3, 2.0f, 0.5f)) + p.humid_offset;
    const float weird = spread(fbm(fx / (p.biome_scale_m * 0.7f), fz / (p.biome_scale_m * 0.7f), seed + 707U, 2, 2.0f, 0.5f));

    // --- macro height, metres above the sea line
    float h = 0.0f;
    float mt = 0.0f;
    float river = 0.0f;
    const bool ocean = c < p.ocean_threshold;
    if (ocean) {
        const float t = smooth01((p.ocean_threshold - c) / 0.30f);
        h = -1.2f - p.ocean_depth_m * t + hn * 1.5f;
    } else {
        const float land = c - p.ocean_threshold;
        const float hill_mult = climate_hilliness(p, temp, humid, weird);
        h = 0.6f + p.base_height_m * smoothstep(0.0f, 0.12f, land) + p.cont_weight_m * land;
        h += hn * p.hill_height_m * hill_mult * (1.15f - e01) * smoothstep(0.0f, 0.10f, land);
        mt = clampf((c - p.mountain_threshold) * p.mountain_gain, 0.0f, 1.0f);
        mt = mt * mt * clampf(1.3f - e01 * 1.2f, 0.0f, 1.0f);
        h += ridge * p.peak_height_m * mt;
        // Dry rivers: valleys cut down to just under the sea line, in the
        // lowlands only, fading out as the ground climbs.
        if (p.valley_depth_m > 0.0f) {
            const float v = spread(fbm(fx / p.valley_scale_m, fz / p.valley_scale_m, seed + 808U, 3, 2.0f, 0.5f));
            float vv = clampf(1.0f - std::fabs(v) * p.valley_width, 0.0f, 1.0f);
            vv = vv * vv;
            const float k = vv * clampf(1.0f - (h - p.valley_depth_m) / (p.valley_depth_m * 2.0f), 0.0f, 1.0f);
            h = h + (-0.6f - h) * k;
            river = k;
        }
    }
    if (p.far_lands && p.far_lands_intensity > 0.0f) {
        const float r2 = 1.0f - std::fabs(spread(fbm(fx / 45.0f, fz / 45.0f, seed + 1212U, 3, 2.0f, 0.5f)));
        h += p.far_lands_intensity * 45.0f * r2 * r2 * r2;
    }
    h *= p.height_scale;

    // --- cliffs: terraces on raised ground where the mask says so
    const float cm_raw = clampf((spread(fbm(fx / 260.0f, fz / 260.0f, seed + 909U, 2, 2.0f, 0.5f))
            + (p.cliff_amount * 2.0f - 1.0f)) * 2.0f, 0.0f, 1.0f);
    const float raised = smoothstep(3.0f, 9.0f, h);
    const float cm = cm_raw * raised;
    if (cm > 0.0f && p.cliff_amount > 0.0f) {
        const float step = p.cliff_step_m;
        const float q = std::floor(h / step) * step;
        const float f = (h - q) / step;
        const float terraced = q + step * smoothstep(0.72f, 1.0f, f);
        h = h + (terraced - h) * cm;
    }

    BColumn col;
    col.sb = fbrick(p.sea_m + h);
    col.basin = h < -0.4f;

    // --- biome
    int id = -1;
    if (col.basin) {
        id = B_OCEAN;
    } else if (river > 0.55f) {
        id = B_RIVER;
    } else if (h < p.beach_width_m && c < p.ocean_threshold + 0.09f) {
        id = e01 < 0.28f ? B_SHORE : (temp < -0.5f ? B_SNOWY_BEACH : B_BEACH);
    } else if (mt > 0.45f && h > 32.0f * p.height_scale) {
        id = (temp < -0.25f || h > p.snow_line_m * p.height_scale) ? B_SNOWY_PEAKS : B_STONY_PEAKS;
    } else if (e01 < 0.25f && h > 14.0f * p.height_scale && hn > 0.15f) {
        id = B_HILLS;
    }
    if (!usable(p, id)) {
        id = climate_pick(p, temp, humid, weird);
    }
    if (id < 0) {
        id = B_PLAINS;
    }
    col.biome = id;
    const BiomeDef &b = p.biomes[(size_t)id];
    col.top = b.top;
    col.under = b.under;
    col.under_d = b.under_depth;
    col.under2 = b.under2;
    col.under2_d = b.under2_depth;
    col.stone = b.stone;
    if (id == B_OCEAN) {
        col.under_d = std::max(p.basin_sand_depth - 1, col.under_d);
    }
    col.snow = col.top == MAT_SNOW || (!col.basin && h > p.snow_line_m * p.height_scale);
    // Windswept hills and stony shores show rock through the grass in patches.
    if (id == B_HILLS || id == B_SHORE) {
        const float pn = value_noise(fx * 0.09f, fz * 0.09f, seed + 1313U);
        if (pn > 0.12f) {
            col.top = pn > 0.35f ? MAT_GRAVEL : MAT_STONE;
            col.under = MAT_STONE;
        }
    }
    if (id == B_TAIGA && value_noise(fx * 0.12f, fz * 0.12f, seed + 1414U) > 0.25f) {
        col.top = MAT_PODZOL;
    }

    // --- overhangs: cliffs and mountain flanks get a 3D band above the surface
    float oh = 0.0f;
    if (!col.basin && id != B_BEACH && id != B_RIVER && id != B_SNOWY_BEACH) {
        oh = std::max(cm, mt * 0.8f * raised);
    }
    col.amp = (int)std::lround(p.overhang_amount * oh * p.overhang_size_m / BRICK_M);
    col.bound_p = (col.sb + col.amp + 1) * PLATES_PER_CELL - 1;
    const float deepest = std::max(p.caves ? p.cave_max_depth_m : 0.0f, p.ravines ? p.ravine_depth_m : 0.0f);
    col.low_p = (col.sb - col.amp - fbrick(deepest) - 2) * PLATES_PER_CELL;
    return col;
}

int biome_bedrock_plate() {
    const GenParams &p = gen_params();
    return fbrick(p.sea_m + p.bedrock_m) * PLATES_PER_CELL;
}

int biome_top(const BColumn &c) {
    return c.snow ? (int)MAT_SNOW : c.top;
}

// --- the cell ---------------------------------------------------------------------

static bool cave_cell(const GenParams &p, uint32_t seed, int x, int yb, int z, float depth_m) {
    const float px = (float)x * STUD_M, py = (float)yb * BRICK_M, pz = (float)z * STUD_M;
    // Below cave_max_depth_m the same caves go on, at their deepest form,
    // down to three bricks over the bedrock (deep worlds, Docs/MineWorld.md
    // 16): one function of the cell, so a cave crossing from a surface
    // tile's mask into a deep section is the same cave.
    const bool deep_ok = p.deep_caves && yb > fbrick(p.sea_m + p.bedrock_m) + 3;
    if (p.caves && depth_m >= p.cave_min_depth_m && (depth_m <= p.cave_max_depth_m || deep_ok)) {
        const float deep = clampf(depth_m / std::max(p.cave_max_depth_m, 1.0f), 0.0f, 1.0f);
        const float w = (0.045f + 0.11f * p.cave_intensity) * (1.0f + 0.6f * deep);
        const float a = value_noise3(px * 0.10f, py * 0.14f, pz * 0.10f, seed + 5501U);
        if (std::fabs(a) < w) {
            const float bb = value_noise3(px * 0.10f + 31.7f, py * 0.14f + 11.3f, pz * 0.10f - 17.9f, seed + 9203U);
            if (std::fabs(bb) < w) {
                return true;   // spaghetti: two sheets crossing make a tunnel
            }
        }
        // Cheese: big chambers, deeper down only.
        if (deep > 0.45f) {
            const float ch = value_noise3(px * 0.045f, py * 0.08f, pz * 0.045f, seed + 777U);
            // Under the old deepest cave, chambers grow rarer over 10 m: at
            // full strength all the way down a quarter of the deep world was
            // air (mine_world_probe, 2026-11-18).
            const float under = clampf((depth_m - p.cave_max_depth_m) / 10.0f, 0.0f, 1.0f);
            if (ch > 0.50f - 0.22f * p.cave_intensity + 0.10f * under) {
                return true;
            }
        }
    }
    if (p.ravines && depth_m <= p.ravine_depth_m) {
        const float region = value_noise(px * 0.004f, pz * 0.004f, seed + 4321U);
        if (region > 0.22f) {
            const float line = spread(fbm(px / 120.0f, pz / 120.0f, seed + 4400U, 2, 2.0f, 0.5f));
            const float width = (0.010f + 0.030f * p.ravine_width)
                    * (1.0f - depth_m / std::max(p.ravine_depth_m, 1.0f)) * smoothstep(0.22f, 0.40f, region);
            if (std::fabs(line) < width) {
                return true;
            }
        }
    }
    return false;
}

static int ore_or(const GenParams &p, uint32_t seed, int x, int yb, int z, int base) {
    constexpr int G = 8;
    const int cx = fdiv(x, G), cy = fdiv(yb, G), cz = fdiv(z, G);
    const float rel_m = (float)yb * BRICK_M - p.sea_m;
    for (size_t i = 0; i < p.ores.size(); ++i) {
        const OreDef &o = p.ores[i];
        if (o.chance <= 0.0f || rel_m < o.min_m || rel_m > o.max_m) {
            continue;
        }
        const uint32_t h = hash3(cx * 7 + (int)i * 131, cy ^ (int)(seed & 0xffff), cz + (int)(seed >> 16));
        if ((float)(h & 0xffffU) * (1.0f / 65536.0f) >= o.chance) {
            continue;
        }
        const int ox = cx * G + 2 + (int)((h >> 16) & 3U);
        const int oy = cy * G + 2 + (int)((h >> 20) & 3U);
        const int oz = cz * G + 2 + (int)((h >> 24) & 3U);
        const float dx = (float)(x - ox), dy = (float)(yb - oy) * 1.2f, dz = (float)(z - oz);
        const float r = o.size * (0.75f + 0.5f * hashf(x, yb, z));
        if (dx * dx + dy * dy + dz * dz <= r * r) {
            return o.material;
        }
    }
    return base;
}

static int stone_at(const GenParams &p, const BColumn &c, uint32_t seed, int x, int yb, int z) {
    const float rel_m = (float)yb * BRICK_M - p.sea_m;
    int base = c.stone;
    // Deep bands: the lowest band whose top is above this brick wins. The
    // boundary is jittered a brick so it is not a ruled line.
    float best_top = 1e9f;
    const float jitter = (hashf(x, yb, z) - 0.5f) * BRICK_M * 2.0f;
    for (const DeepBand &band : p.bands) {
        if (band.enabled && rel_m + jitter < band.top_m && band.top_m < best_top) {
            best_top = band.top_m;
            base = band.material;
        }
    }
    if (base == MAT_TERRA_ORANGE) {
        // Badlands: horizontal stripes, by absolute height so they line up
        // across a whole mesa.
        static const int STRIPES[8] = { MAT_TERRA_ORANGE, MAT_TERRA_ORANGE, MAT_TERRA_CREAM,
                MAT_TERRA_ORANGE, MAT_TERRA_RED, MAT_CLAY, MAT_TERRA_ORANGE, MAT_TERRA_CREAM };
        const int s = (int)(hash3(fdiv(yb, 2), 0, (int)seed) & 7U);
        return STRIPES[s];
    }
    if (base != MAT_STONE && base != MAT_DARK_STONE) {
        return base;
    }
    const float px = (float)x * STUD_M, py = (float)yb * BRICK_M, pz = (float)z * STUD_M;
    if (p.stone_patches > 0.0f) {
        const float n = value_noise3(px * 0.07f, py * 0.09f, pz * 0.07f, seed + 6060U);
        const float t = 0.78f - 0.22f * p.stone_patches;
        if (n > t) {
            base = MAT_GRANITE;
        } else if (n < -t) {
            base = MAT_DIORITE;
        } else if (base == MAT_STONE
                && value_noise3(px * 0.11f, py * 0.13f, pz * 0.11f, seed + 6161U) > 0.70f - 0.15f * p.stone_patches) {
            base = MAT_GRAVEL;
        }
    }
    return ore_or(p, seed, x, yb, z, base);
}

int biome_cell(const GenParams &p, const BColumn &c, uint32_t seed, int x, int yb, int z) {
    if (yb > c.sb + c.amp) {
        return MAT_AIR;
    }
    const int bed = fbrick(p.sea_m + p.bedrock_m);
    if (yb <= bed) {
        return MAT_BEDROCK;
    }
    if (yb <= bed + 2 && hashf(x, yb, z) < (float)(bed + 3 - yb) / 3.0f) {
        return MAT_BEDROCK;
    }
    if (c.amp > 0 && yb >= c.sb - c.amp) {
        // The overhang band: density falls with height, 3D noise pushes it
        // about, so a cliff face leans out over itself and is undercut.
        const float fh = STUD_M / 6.0f, fv = BRICK_M / 4.0f;
        auto dens = [&](int y) {
            return (float)(c.sb - y) / (float)c.amp
                    + value_noise3((float)x * fh, (float)y * fv, (float)z * fh, seed + 1111U) * 1.6f;
        };
        if (dens(yb) <= 0.0f) {
            return MAT_AIR;
        }
        const bool exposed = yb + 1 > c.sb + c.amp || dens(yb + 1) <= 0.0f;
        if (exposed) {
            return biome_top(c);
        }
        return stone_at(p, c, seed, x, yb, z);
    }
    const int depth = c.sb - yb;
    // Sealed against the sea (MineWater.md 9): under the sea course, a column
    // that is sea floor or low shore keeps its caves and ravines shut, so no
    // cave air lies under or beside sea water (a "water wall" until woken).
    // A cliff higher than this over the sea can still open a cave to it.
    const bool sealed = p.water && yb <= fbrick(p.sea_m) + 1
            && c.sb <= fbrick(p.sea_m) + fbrick(p.cave_min_depth_m) + 3;
    if (depth > 0 && !sealed && cave_cell(p, seed, x, yb, z, (float)depth * BRICK_M)) {
        return MAT_AIR;
    }
    if (depth == 0) {
        return biome_top(c);
    }
    if (depth <= c.under_d) {
        return c.under;
    }
    if (depth <= c.under_d + c.under2_d) {
        return c.under2;
    }
    return stone_at(p, c, seed, x, yb, z);
}

// --- the map preview ----------------------------------------------------------------

PackedByteArray gen_preview(uint32_t seed, const Dictionary &params, int cx, int cz, int w, int h,
        int step, int mode) {
    PackedByteArray out;
    w = std::max(w, 1);
    h = std::max(h, 1);
    step = std::max(step, 1);
    out.resize((int64_t)w * h * 3);
    uint8_t *px = out.ptrw();
    GenParams p = gen_params();
    if (!params.is_empty()) {
        apply_gen_dict(p, params);
    }
    const int sea_b = fbrick(p.sea_m);
    std::vector<int> prev((size_t)w, 0);
    for (int j = 0; j < h; ++j) {
        int left = 0;
        for (int i = 0; i < w; ++i) {
            const int x = cx + (i - w / 2) * step;
            const int z = cz + (j - h / 2) * step;
            const BColumn c = biome_column(p, seed, x, z);
            const int top_b = c.sb;
            Color col;
            if (mode == 1) {
                col = filament_colour(p.biomes[(size_t)c.biome].map_colour);
            } else {
                col = filament_colour(material_filament(biome_top(c)));
            }
            // Hill shade from the neighbours already drawn (north-west light).
            float shade = 1.0f;
            if (i > 0 && j > 0) {
                const float slope = (float)((top_b - left) + (top_b - prev[(size_t)i]));
                shade = clampf(1.0f + slope * 0.06f * (4.0f / (float)step), 0.55f, 1.35f);
            }
            if (c.basin) {
                shade *= clampf(1.0f - (float)(sea_b - top_b) * 0.012f, 0.55f, 1.0f);
            }
            left = top_b;
            prev[(size_t)i] = top_b;
            const size_t k = ((size_t)j * w + i) * 3;
            px[k] = (uint8_t)clampf(col.r * shade * 255.0f, 0.0f, 255.0f);
            px[k + 1] = (uint8_t)clampf(col.g * shade * 255.0f, 0.0f, 255.0f);
            px[k + 2] = (uint8_t)clampf(col.b * shade * 255.0f, 0.0f, 255.0f);
        }
    }
    return out;
}

} // namespace brick
