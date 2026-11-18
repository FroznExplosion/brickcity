#pragma once

// THE BIOME GENERATOR: a flat, Minecraft-like world for the terrain test.
// Docs/MineWorld.md. Off unless a scene asks for it (`BrickTerrain.set_generator
// (1)`), so every other scene keeps the classic field in Field::base_plate.
//
// What it adds to the classic field, in the order a column is decided:
//
//   1. MACRO HEIGHT from continentalness, erosion and ridge noise -- dry ocean
//      basins, coasts, plains, hills, mountains -- plus dry river valleys.
//   2. CLIMATE (temperature, humidity, weirdness) picks the nearest enabled
//      land biome; terrain rules pick beaches, stony shores, basins, rivers,
//      windswept hills and the two kinds of peak.
//   3. LOCAL DETAIL: each biome's hilliness, blended over nearby climate so a
//      border is not a cliff; cliff terraces; an OVERHANG band of 3D noise
//      above the surface where the cliff mask says so.
//   4. LAYERS: top block, two under layers, stone (or banded terracotta),
//      deepslate, a bedrock floor; caves, ravines, ores and stone patches.
//
// Every number is in GenParams, set from GDScript as one Dictionary
// (BrickTerrain.set_gen_params) -- the world-gen menu's whole interface.
// Params are read by worker threads while tiles bake, so they are only
// changed while nothing is baking (the scene tears its tiers down first).

#include <cstdint>
#include <string>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace brick {

enum BiomeKind {
    BK_LAND = 0,     ///< chosen by climate
    BK_OCEAN,        ///< below the sea line: a dry, sand-floored basin
    BK_BEACH,
    BK_SHORE,        ///< stony coast where the land is rough
    BK_RIVER,        ///< a dry valley floor
    BK_HILLS,        ///< windswept: high, rough, not a mountain
    BK_PEAKS,        ///< mountain tops (snowy when cold, stony when not)
    BK_SNOWY_PEAKS,
    BK_SNOWY_BEACH,
};

struct BiomeDef {
    std::string name;
    int kind = BK_LAND;
    bool enabled = true;
    float temp = 0.0f, humid = 0.0f, weird = 0.0f;   ///< climate point, -1..1
    int top = 1, under = 2, under2 = 2, stone = 4;   ///< materials
    int under_depth = 3, under2_depth = 0;           ///< bricks
    float hilliness = 0.5f;                          ///< local relief multiplier
    int map_colour = 0;                              ///< filament index, the map's biome view
};

struct OreDef {
    std::string name;
    int material = 0;
    float chance = 0.0f;     ///< veins per 8x8x8 cell, 0..1
    float size = 1.5f;       ///< vein radius, studs
    float min_m = -100.0f;   ///< metres relative to the sea line
    float max_m = 100.0f;
};

struct DeepBand {
    float top_m = -20.0f;    ///< relative to the sea line; this band below it
    int material = 5;
    bool enabled = true;
};

struct GenParams {
    // --- world
    float height_scale = 1.0f;
    float sea_m = 20.0f;              ///< absolute Y of the (dry) sea line
    // --- shape
    float continent_scale_m = 1400.0f;
    float ocean_threshold = -0.18f;   ///< continentalness below this is basin
    float ocean_depth_m = 14.0f;
    float base_height_m = 2.5f;
    float cont_weight_m = 22.0f;
    float erosion_scale_m = 700.0f;
    float hill_height_m = 9.0f;
    float hill_scale_m = 160.0f;
    float peak_height_m = 70.0f;
    float mountain_threshold = 0.18f;
    float mountain_gain = 2.2f;
    float ridge_scale_m = 420.0f;
    float valley_depth_m = 7.0f;
    float valley_width = 14.0f;
    float valley_scale_m = 900.0f;
    bool far_lands = false;
    float far_lands_intensity = 0.0f;
    // --- cliffs and overhangs
    float cliff_amount = 0.45f;       ///< share of hill/mountain ground that terraces
    float cliff_step_m = 5.0f;
    float overhang_amount = 0.6f;
    float overhang_size_m = 5.0f;
    // --- sea and beach (dry)
    float beach_width_m = 1.4f;
    int basin_sand_depth = 4;         ///< bricks of sand on a basin floor
    // --- caves
    /// The sea is water (Docs/MineWater.md 9): caves and ravines are sealed
    /// against it, so no water stands beside cave air before anything wakes it.
    bool water = false;
    /// Lava pools (Docs/MineWater.md 9, stage 8): all cave air under
    /// sea_m + lava_m is lava, as Minecraft's caves are at the bottom. Caves
    /// reach the bedrock (deep_caves), so the line sits a few bricks over it:
    /// lava lakes in the deepest caves, not a molten underground.
    bool lava_pools = false;
    float lava_m = -112.0f;
    /// Springs: a column beside a cliff of three bricks or more has this
    /// chance of water running out of the face (a source in the air there).
    bool springs = false;
    float spring_chance = 0.02f;
    bool caves = true;
    /// Caves below cave_max_depth_m too, down to just over the bedrock: the
    /// deep tier draws them (Docs/MineWorld.md 16).
    bool deep_caves = true;
    float cave_intensity = 0.5f;
    float cave_min_depth_m = 1.8f;
    float cave_max_depth_m = 18.0f;
    bool ravines = true;
    float ravine_width = 0.5f;
    float ravine_depth_m = 16.0f;
    // --- climate
    float biome_scale_m = 800.0f;
    float temp_offset = 0.0f;
    float humid_offset = 0.0f;
    float snow_line_m = 50.0f;        ///< above the sea line, every top is snow
    // --- underground
    float bedrock_m = -126.0f;        ///< relative to the sea line: 300 bricks (Docs/MineWorld.md 16)
    float stone_patches = 0.5f;
    std::vector<DeepBand> bands;
    std::vector<OreDef> ores;
    std::vector<BiomeDef> biomes;
};

/// Everything about one column that does not depend on Y.
struct BColumn {
    int sb = 0;          ///< the 2D surface's top BRICK
    int amp = 0;         ///< overhang band half height, bricks (0 = none)
    int biome = 0;
    int top = 1, under = 2, under2 = 2, stone = 4;
    int under_d = 3, under2_d = 0;
    bool basin = false;
    bool snow = false;   ///< above the snow line or a snowy biome's top
    int bound_p = 0;     ///< topmost plate anything can be solid at
    int low_p = 0;       ///< the deepest plate caves or ravines can reach
};

/// 0 classic (Field), 1 biomes.
int gen_mode();
void set_gen_mode(int mode);
inline bool biomes_on() { return gen_mode() == 1; }

GenParams &gen_params();
void reset_gen_params();
void gen_params_from_dict(const godot::Dictionary &d);
/// Apply a Dictionary to any params block (the live one, or a copy the map
/// preview draws from while the live world keeps baking).
void apply_gen_dict(GenParams &p, const godot::Dictionary &d);
godot::Dictionary gen_params_to_dict();

BColumn biome_column(const GenParams &p, uint32_t seed, int x, int z);
inline BColumn biome_column(uint32_t seed, int x, int z) { return biome_column(gen_params(), seed, x, z); }
/// The material of brick `yb` (absolute brick index) of the column, 0 air.
int biome_cell(const GenParams &p, const BColumn &c, uint32_t seed, int x, int yb, int z);
inline int biome_cell(const BColumn &c, uint32_t seed, int x, int yb, int z) {
    return biome_cell(gen_params(), c, seed, x, yb, z);
}
/// The top block the column shows from above (the coarse tier's colour).
int biome_top(const BColumn &c);
/// The plate of the bedrock floor's top brick (all bedrock at and below it).
int biome_bedrock_plate();

godot::PackedStringArray biome_names();
/// RGB8, w*h pixels, centred on (cx, cz) studs, `step` studs a pixel.
/// mode 0: what the ground looks like from above, hill-shaded; 1: biomes.
/// `params`: overrides on a copy of the live params (empty: the live ones).
godot::PackedByteArray gen_preview(uint32_t seed, const godot::Dictionary &params, int cx, int cz,
        int w, int h, int step, int mode);

} // namespace brick
