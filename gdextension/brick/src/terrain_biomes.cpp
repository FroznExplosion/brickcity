#include <climits>
#include <queue>
#include <mutex>
#include <unordered_map>
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
/// Bumped when the live params change: cached lakes are worked out again.
static int g_params_gen = 0;

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
    ++g_params_gen;
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
    ++g_params_gen;     // lakes are worked out again
}

void apply_gen_dict(GenParams &p, const Dictionary &d) {
    GP_FLOAT("height_scale", height_scale)
    GP_FLOAT("sea_m", sea_m)
    GP_FLOAT("continent_scale_m", continent_scale_m)
    GP_FLOAT("ocean_threshold", ocean_threshold)
    GP_FLOAT("ocean_depth_m", ocean_depth_m)
    GP_FLOAT("deep_ocean_from", deep_ocean_from)
    GP_FLOAT("deep_ocean_m", deep_ocean_m)
    GP_FLOAT("trench_m", trench_m)
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
    GP_BOOL("lakes", lakes)
    GP_FLOAT("lake_chance", lake_chance)
    GP_BOOL("cave_pools", cave_pools)
    GP_FLOAT("cave_pool_chance", cave_pool_chance)
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
    d["deep_ocean_from"] = p.deep_ocean_from;
    d["deep_ocean_m"] = p.deep_ocean_m;
    d["trench_m"] = p.trench_m;
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
    d["lakes"] = p.lakes;
    d["lake_chance"] = p.lake_chance;
    d["cave_pools"] = p.cave_pools;
    d["cave_pool_chance"] = p.cave_pool_chance;
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

static BColumn column_base(const GenParams &p, uint32_t seed, int x, int z) {
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
        const float out = p.ocean_threshold - c;
        const float t = smooth01(out / 0.30f);
        h = -1.2f - p.ocean_depth_m * t + hn * 1.5f;
        // The deep ocean (Docs/MineOcean.md 2.1): past the shelf a drop-off
        // to the deep plains, which roll more, and trenches along the ridges.
        if (p.deep_ocean_m > p.ocean_depth_m) {
            const float dd = smoothstep(p.deep_ocean_from, p.deep_ocean_from + 0.10f, out);
            if (dd > 0.0f) {
                const float tr = clampf((ridge - 0.78f) / 0.22f, 0.0f, 1.0f);
                h -= dd * ((p.deep_ocean_m - p.ocean_depth_m) + p.trench_m * tr * tr + hn * 4.0f);
                h = std::max(h, p.bedrock_m + 24.0f);
            }
        }
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

// --- lakes above the sea (Docs/MineWater.md 14.8) -----------------------------
//
// One region in LAKE_REGION studs may hold a lake: at the lowest of nine
// hashed points in it, an ellipse 18-47 studs a radius. Its level is a brick
// under the lowest column of its rim (the inside columns touching the
// outside), worked out from the columns as generated WITHOUT lakes; inside
// the rim the ground is cut to a sand bowl 1-4 bricks under the level, so
// every lake has water, and the rim, untouched, holds it in.

namespace {
struct LakeR {
    bool on = false;
    int cx = 0, cz = 0, rx = 1, rz = 1, level = 0;
};
std::mutex g_lake_mx;
std::unordered_map<int64_t, LakeR> g_lakes;
uint32_t g_lake_seed = 0;
int g_lake_gen = -1;

inline bool in_ell(int dx, int dz, int rx, int rz) {
    return (int64_t)dx * dx * rz * rz + (int64_t)dz * dz * rx * rx <= (int64_t)rx * rx * rz * rz;
}
inline bool lake_inner(int dx, int dz, int rx, int rz) {
    return in_ell(dx, dz, rx, rz) && in_ell(dx + 1, dz, rx, rz) && in_ell(dx - 1, dz, rx, rz)
            && in_ell(dx, dz + 1, rx, rz) && in_ell(dx, dz - 1, rx, rz);
}
inline uint32_t lmix(uint32_t h) {
    h ^= h >> 16; h *= 0x7feb352dU; h ^= h >> 15; h *= 0x846ca68bU; h ^= h >> 16;
    return h;
}

LakeR lake_region(const GenParams &p, uint32_t seed, int rx, int rz) {
    const int64_t key = ((int64_t)(rx & 0xFFFFFFF) << 28) | (int64_t)(rz & 0xFFFFFFF);
    {
        std::lock_guard<std::mutex> lk(g_lake_mx);
        if (g_lake_seed != seed || g_lake_gen != g_params_gen) {
            g_lakes.clear();
            g_lake_seed = seed;
            g_lake_gen = g_params_gen;
        }
        auto it = g_lakes.find(key);
        if (it != g_lakes.end()) return it->second;
    }
    LakeR L;
    const uint32_t h = lmix((uint32_t)rx * 0x27D4EB2FU ^ (uint32_t)rz * 0x165667B1U ^ seed ^ 0x1A4Eu);
    if (p.lakes && (double)h < (double)p.lake_chance * 4294967296.0) {
        int best = INT_MAX;
        for (int i = 0; i < 9; ++i) {
            const uint32_t hi = lmix(h + (uint32_t)i * 0x9E3779B9U);
            const int px = rx * LAKE_REGION + 64 + (int)(hi % (uint32_t)(LAKE_REGION - 128));
            const int pz = rz * LAKE_REGION + 64 + (int)((hi >> 11) % (uint32_t)(LAKE_REGION - 128));
            const int sb = column_base(p, seed, px, pz).sb;
            if (sb < best) { best = sb; L.cx = px; L.cz = pz; }
        }
        L.rx = 18 + (int)(h % 30u);
        L.rz = 18 + (int)((h >> 7) % 30u);
        int rim = INT_MAX;
        for (int dz = -L.rz; dz <= L.rz; ++dz) {
            for (int dx = -L.rx; dx <= L.rx; ++dx) {
                if (!in_ell(dx, dz, L.rx, L.rz) || lake_inner(dx, dz, L.rx, L.rz)) continue;
                rim = std::min(rim, column_base(p, seed, L.cx + dx, L.cz + dz).sb);
            }
        }
        L.level = rim - 1;
        L.on = rim != INT_MAX && L.level > fbrick(p.sea_m) + 1;
    }
    std::lock_guard<std::mutex> lk(g_lake_mx);
    g_lakes[key] = L;
    return L;
}
} // namespace

int lake_level_at(const GenParams &p, uint32_t seed, int x, int z, int *bed) {
    if (!p.lakes) return INT_MIN;
    const LakeR L = lake_region(p, seed, fdiv(x, LAKE_REGION), fdiv(z, LAKE_REGION));
    const int dx = x - L.cx, dz = z - L.cz;
    if (!L.on || !lake_inner(dx, dz, L.rx, L.rz)) return INT_MIN;
    if (bed != nullptr) {
        const double r2 = (double)dx * dx / ((double)L.rx * L.rx) + (double)dz * dz / ((double)L.rz * L.rz);
        *bed = L.level - (1 + (int)std::lround(3.0 * (1.0 - std::min(1.0, r2))));
    }
    return L.level;
}

BColumn biome_column(const GenParams &p, uint32_t seed, int x, int z) {
    BColumn col = column_base(p, seed, x, z);
    if (p.lakes) {
        int bed = 0;
        if (lake_level_at(p, seed, x, z, &bed) != INT_MIN && bed < col.sb) {
            // The lake's bowl: sand, no overhang over the water.
            col.sb = bed;
            col.top = MAT_SAND;
            col.under = MAT_SAND;
            col.amp = 0;
            col.snow = false;
            col.bound_p = (col.sb + 1) * PLATES_PER_CELL - 1;
            const float deepest = std::max(p.caves ? p.cave_max_depth_m : 0.0f, p.ravines ? p.ravine_depth_m : 0.0f);
            col.low_p = (col.sb - fbrick(deepest) - 2) * PLATES_PER_CELL;
        }
    }
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

static int pool_level_r(const GenParams &p, uint32_t seed, int rx, int ry, int rz) {
    if (!p.cave_pools) return INT_MIN;
    uint32_t h = (uint32_t)rx * 0x8DA6B343U ^ (uint32_t)ry * 0xD8163841U ^ (uint32_t)rz * 0xCB1AB31FU ^ seed ^ 0xA0F1u;
    h ^= h >> 15; h *= 0x2C1B3C6DU; h ^= h >> 12; h *= 0x297A2D39U; h ^= h >> 15;
    if ((float)(h & 0xFFFF) >= p.cave_pool_chance * 65536.0f) return INT_MIN;
    const int base = ry * AQ_Y;
    // Over the lava line (lava pools stay lava) by a band.
    if (base <= fbrick(p.sea_m + p.lava_m) + AQ_Y) return INT_MIN;
    return base + 2 + (int)((h >> 16) % 7u);
}

int cave_pool_level(const GenParams &p, uint32_t seed, int x, int yb, int z) {
    return pool_level_r(p, seed, fdiv(x, AQ_XZ), fdiv(yb, AQ_Y), fdiv(z, AQ_XZ));
}

// --- cave pools as closed basins (Docs/MineWater.md 14.8, 2026-11-20) -------
//
// The first pools filled a whole grid region of cave under a level and left
// thin stone walls and floors round it: rectangles of water floating in the
// caves, and when a brick of a floor went, the whole floor fell and all the
// water moved at once. Now a region's water is only its CLOSED pockets: the
// cave air under its level that is joined to nothing outside the region, to
// no air under it, and to no open air -- a dip in a cave floor, filled to its
// rim. Nothing is added to the ground. Worked out once a region (on the
// water's thread), cached.

namespace {
struct PoolBits {
    std::vector<uint8_t> w;     ///< a bit a cell, AQ_XZ x AQ_Y x AQ_XZ
    bool any = false;
};
std::mutex g_pool_mx;
std::unordered_map<int64_t, PoolBits> g_pools;
uint32_t g_pool_seed = 0;
int g_pool_gen = -1;

inline int64_t pool_key(int rx, int ry, int rz) {
    return ((int64_t)(rx & 0x1FFFFF) << 42) | ((int64_t)(ry & 0x1FFFFF) << 21) | (int64_t)(rz & 0x1FFFFF);
}

/// Each cave cell's SPILL height: the lowest course water standing there
/// would have to reach to get out -- over the region's sides, down under
/// it, or into open air -- found as the least "highest point on the way" over
/// every way out (a priority flood). A cave cell under its spill height is
/// pool water: the dips of cave floors, each filled to its own lip, never
/// beside air at the same height.
PoolBits pool_compute(const GenParams &p, uint32_t seed, int rx, int ry, int rz) {
    PoolBits out;
    if (pool_level_r(p, seed, rx, ry, rz) == INT_MIN) return out;   // this region has none
    const int x0 = rx * AQ_XZ, z0 = rz * AQ_XZ, y0 = ry * AQ_Y;
    const int NX = AQ_XZ, NZ = AQ_XZ, NY = AQ_Y + 1;      // a course under the band too
    // 0 rock, 1 cave air, 2 open air (over the ground).
    std::vector<uint8_t> g((size_t)NX * NY * NZ, 0);
    auto idx = [&](int x, int y, int z) { return ((size_t)y * NZ + z) * NX + x; };
    for (int z = 0; z < NZ; ++z) {
        for (int x = 0; x < NX; ++x) {
            const BColumn c = biome_column(p, seed, x0 + x, z0 + z);
            for (int y = 0; y < NY; ++y) {
                const int yb = y0 - 1 + y;
                if (yb > c.sb) { g[idx(x, y, z)] = 2; continue; }
                g[idx(x, y, z)] = biome_cell(c, seed, x0 + x, yb, z0 + z) == MAT_AIR ? 1 : 0;
            }
        }
    }
    const int INF = 1 << 30;
    std::vector<int> spill(g.size(), INF);
    // Ways out: a cell on the region's sides, the course under the band, the
    // band's top course, open air -- water there leaves at its own height.
    using QE = std::pair<int, int>;   // (spill, cell)
    std::priority_queue<QE, std::vector<QE>, std::greater<QE>> q;
    for (int y = 0; y < NY; ++y) {
        for (int z = 0; z < NZ; ++z) {
            for (int x = 0; x < NX; ++x) {
                const size_t i = idx(x, y, z);
                if (g[i] == 0) continue;
                const bool out_way = x == 0 || z == 0 || x == NX - 1 || z == NZ - 1 || y == 0
                        || y == NY - 1 || g[i] == 2;
                if (out_way) {
                    spill[i] = y;
                    q.push({ y, (int)i });
                }
            }
        }
    }
    static const int D[6][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
    while (!q.empty()) {
        const QE e = q.top();
        q.pop();
        if (e.first != spill[(size_t)e.second]) continue;
        const int i = e.second;
        const int cx = i % NX, cz = (i / NX) % NZ, cy = i / (NX * NZ);
        for (const auto &d : D) {
            const int nx = cx + d[0], ny2 = cy + d[1], nz = cz + d[2];
            if (nx < 0 || nz < 0 || ny2 < 0 || nx >= NX || nz >= NZ || ny2 >= NY) continue;
            const size_t j = idx(nx, ny2, nz);
            if (g[j] == 0) continue;
            const int cand = std::max(e.first, ny2);
            if (cand < spill[j]) {
                spill[j] = cand;
                q.push({ cand, (int)j });
            }
        }
    }
    out.w.assign((size_t)AQ_XZ * AQ_Y * AQ_XZ, 0);
    for (int y = 1; y < NY; ++y) {
        for (int z = 0; z < NZ; ++z) {
            for (int x = 0; x < NX; ++x) {
                const size_t i = idx(x, y, z);
                if (g[i] == 1 && y < spill[i] && spill[i] < INF) {
                    out.w[((size_t)(y - 1) * AQ_XZ + z) * AQ_XZ + x] = 1;
                    out.any = true;
                }
            }
        }
    }
    return out;
}
} // namespace

int cave_pool_water(const GenParams &p, uint32_t seed, int x, int yb, int z, bool may_compute) {
    if (!p.cave_pools) return 0;
    const int rx = fdiv(x, AQ_XZ), ry = fdiv(yb, AQ_Y), rz = fdiv(z, AQ_XZ);
    const int64_t key = pool_key(rx, ry, rz);
    {
        std::lock_guard<std::mutex> lk(g_pool_mx);
        if (g_pool_seed != seed || g_pool_gen != g_params_gen) {
            g_pools.clear();
            g_pool_seed = seed;
            g_pool_gen = g_params_gen;
        }
        auto it = g_pools.find(key);
        if (it != g_pools.end()) {
            if (!it->second.any) return 0;
            const int lx = x - rx * AQ_XZ, ly = yb - ry * AQ_Y, lz = z - rz * AQ_XZ;
            return it->second.w[((size_t)ly * AQ_XZ + lz) * AQ_XZ + lx];
        }
    }
    if (!may_compute) return -1;
    PoolBits b = pool_compute(p, seed, rx, ry, rz);
    const int lx = x - rx * AQ_XZ, ly = yb - ry * AQ_Y, lz = z - rz * AQ_XZ;
    const int r = b.any ? b.w[((size_t)ly * AQ_XZ + lz) * AQ_XZ + lx] : 0;
    std::lock_guard<std::mutex> lk(g_pool_mx);
    g_pools[key] = std::move(b);
    return r;
}

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
