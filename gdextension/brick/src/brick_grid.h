#ifndef BRICK_GRID_H
#define BRICK_GRID_H

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>

using namespace godot;

namespace brick {

// ---------------------------------------------------------------------------
// The grid. Plan.md D5/D6.
//
// x and z are measured in STUDS, y is measured in PLATES. Every block is an
// integer footprint on this grid and nothing is ever allowed off it -- the
// integer adjacency test in BrickWorld is what the whole destruction stack
// rides on.
//
// Print scale is 8.0 mm stud pitch / 3.2 mm plate (spec section 3). In game we
// run at roughly 1:43.75, so one stud is 0.35 m and one plate is 0.14 m. A
// brick is three plates: 0.42 m.
// ---------------------------------------------------------------------------

constexpr float STUD_M = 0.35f;
constexpr float PLATE_M = 0.14f;
constexpr int PLATES_PER_BRICK = 3;

/// Fixed-point scale for structural load and joint capacity. Archetype masses
/// are small numbers with one decimal place, so 1024 units per mass leaves
/// three orders of magnitude of headroom below the point where a whole
/// building's load would trouble an int64.
constexpr int64_t MASS_FIXED = 1024;

inline int64_t to_mass_units(float mass) {
    return (int64_t)llround((double)mass * (double)MASS_FIXED);
}

inline Vector3 cell_size() {
    return Vector3(STUD_M, PLATE_M, STUD_M);
}

inline Vector3 grid_to_world(const Vector3i &cell) {
    return Vector3(cell.x * STUD_M, cell.y * PLATE_M, cell.z * STUD_M);
}

inline Vector3i world_to_grid(const Vector3 &pos) {
    return Vector3i(
        (int)std::floor(pos.x / STUD_M),
        (int)std::floor(pos.y / PLATE_M),
        (int)std::floor(pos.z / STUD_M));
}

// ---------------------------------------------------------------------------
// Filament palette. Spec section 2: flat filament colours, no textures, so
// colour is a vertex attribute and costs no texture memory. Index is stored
// per block as a byte.
// ---------------------------------------------------------------------------

enum Filament {
    FIL_WHITE = 0,
    FIL_BLACK,
    FIL_GREY,
    FIL_DARK_GREY,
    FIL_RED,
    FIL_ORANGE,
    FIL_YELLOW,
    FIL_GREEN,
    FIL_BLUE,
    FIL_LIGHT_BLUE,
    FIL_BROWN,
    FIL_TAN,
    FILAMENT_COUNT
};

// Defined after the palette below, which it reads.
inline Color filament_colour(int index);


// ---------------------------------------------------------------------------
// Materials. A block is a MATERIAL and a COLOUR, one byte each.
//
// What the colour byte means depends on the material:
//
//   * a FILAMENT material (PLA, ABS, TPU ...) takes any colour off the
//     filament palette below -- the same 64, whatever the plastic;
//   * a VARIANT material (wood, metal, stone ...) has its own short list:
//     oak, walnut, cherry; steel, brass, copper. The colour byte picks one.
//
// Everything that draws a block asks `block_rgba` for its colour. RGB is the
// resolved colour; ALPHA carries the material to the shader, encoded so that
// alpha 1.0 is material 0 (PLA) -- so every mesh built before materials, and
// the terrain, which never sets one, still means "plain PLA".
// ---------------------------------------------------------------------------

struct NamedColour {
    const char *name;
    float r, g, b;
};

// The filament palette. The first twelve are the Filament enum above and keep
// their indices: saved builds store these numbers.
inline const NamedColour FILAMENT_PALETTE[] = {
    {"white", 0.92f, 0.92f, 0.90f},
    {"black", 0.10f, 0.10f, 0.11f},
    {"grey", 0.55f, 0.56f, 0.58f},
    {"dark grey", 0.30f, 0.31f, 0.33f},
    {"red", 0.72f, 0.13f, 0.13f},
    {"orange", 0.87f, 0.42f, 0.09f},
    {"yellow", 0.93f, 0.75f, 0.10f},
    {"green", 0.20f, 0.55f, 0.24f},
    {"blue", 0.13f, 0.35f, 0.68f},
    {"light blue", 0.40f, 0.66f, 0.85f},
    {"brown", 0.40f, 0.26f, 0.17f},
    {"tan", 0.79f, 0.68f, 0.50f},
    // --- greys and neutrals
    {"off white", 0.96f, 0.94f, 0.86f},
    {"light grey", 0.74f, 0.75f, 0.77f},
    {"charcoal", 0.18f, 0.19f, 0.21f},
    {"warm grey", 0.55f, 0.51f, 0.47f},
    // --- reds and pinks
    {"dark red", 0.45f, 0.07f, 0.08f},
    {"bright red", 0.90f, 0.12f, 0.10f},
    {"coral", 0.95f, 0.45f, 0.38f},
    {"salmon", 0.96f, 0.63f, 0.55f},
    {"pink", 0.95f, 0.55f, 0.72f},
    {"hot pink", 0.93f, 0.20f, 0.55f},
    {"magenta", 0.78f, 0.12f, 0.55f},
    {"rose", 0.80f, 0.40f, 0.48f},
    // --- oranges and browns
    {"dark orange", 0.72f, 0.30f, 0.06f},
    {"peach", 0.98f, 0.72f, 0.52f},
    {"rust", 0.60f, 0.24f, 0.10f},
    {"chocolate", 0.30f, 0.18f, 0.11f},
    {"caramel", 0.70f, 0.45f, 0.22f},
    {"sand", 0.87f, 0.80f, 0.63f},
    // --- yellows
    {"lemon", 0.98f, 0.90f, 0.30f},
    {"gold yellow", 0.95f, 0.65f, 0.05f},
    {"cream", 0.98f, 0.93f, 0.72f},
    {"mustard", 0.78f, 0.62f, 0.12f},
    // --- greens
    {"dark green", 0.08f, 0.33f, 0.16f},
    {"bright green", 0.30f, 0.75f, 0.25f},
    {"lime", 0.65f, 0.85f, 0.20f},
    {"olive", 0.45f, 0.47f, 0.18f},
    {"mint", 0.62f, 0.90f, 0.72f},
    {"teal", 0.05f, 0.52f, 0.50f},
    {"sage", 0.60f, 0.68f, 0.55f},
    {"forest", 0.13f, 0.25f, 0.13f},
    // --- blues
    {"navy", 0.07f, 0.13f, 0.35f},
    {"royal blue", 0.15f, 0.25f, 0.80f},
    {"sky blue", 0.55f, 0.80f, 0.95f},
    {"azure", 0.10f, 0.55f, 0.90f},
    {"cyan", 0.10f, 0.78f, 0.85f},
    {"steel blue", 0.30f, 0.45f, 0.60f},
    {"ice", 0.80f, 0.92f, 0.97f},
    {"denim", 0.25f, 0.38f, 0.55f},
    // --- purples
    {"purple", 0.40f, 0.18f, 0.60f},
    {"violet", 0.55f, 0.35f, 0.85f},
    {"lavender", 0.75f, 0.68f, 0.92f},
    {"plum", 0.40f, 0.15f, 0.35f},
    {"indigo", 0.22f, 0.15f, 0.50f},
    {"lilac", 0.82f, 0.65f, 0.85f},
    // --- skin tones and earth
    {"skin light", 0.96f, 0.80f, 0.68f},
    {"skin medium", 0.82f, 0.60f, 0.45f},
    {"skin tan", 0.66f, 0.45f, 0.30f},
    {"skin dark", 0.40f, 0.26f, 0.18f},
    {"terracotta", 0.76f, 0.40f, 0.28f},
    {"clay", 0.68f, 0.52f, 0.40f},
    {"khaki", 0.70f, 0.66f, 0.46f},
    {"moss", 0.40f, 0.50f, 0.25f},
};
constexpr int FILAMENT_PALETTE_SIZE = (int)(sizeof(FILAMENT_PALETTE) / sizeof(FILAMENT_PALETTE[0]));

inline const NamedColour WOOD_VARIANTS[] = {
    {"oak", 0.72f, 0.54f, 0.33f},
    {"walnut", 0.36f, 0.24f, 0.16f},
    {"cherry", 0.62f, 0.33f, 0.21f},
    {"pine", 0.86f, 0.70f, 0.47f},
    {"birch", 0.90f, 0.81f, 0.64f},
    {"mahogany", 0.45f, 0.20f, 0.13f},
    {"maple", 0.88f, 0.74f, 0.54f},
    {"teak", 0.60f, 0.42f, 0.24f},
    {"ebony", 0.13f, 0.10f, 0.09f},
    {"ash", 0.80f, 0.72f, 0.58f},
    {"cedar", 0.70f, 0.42f, 0.28f},
    {"bamboo", 0.86f, 0.76f, 0.50f},
    {"weathered", 0.58f, 0.56f, 0.52f},
    {"driftwood", 0.72f, 0.68f, 0.60f},
};

inline const NamedColour METAL_VARIANTS[] = {
    {"steel", 0.62f, 0.63f, 0.65f},
    {"stainless", 0.76f, 0.77f, 0.78f},
    {"aluminium", 0.85f, 0.86f, 0.88f},
    {"chrome", 0.93f, 0.94f, 0.96f},
    {"iron", 0.36f, 0.35f, 0.34f},
    {"rusted iron", 0.48f, 0.26f, 0.14f},
    {"copper", 0.86f, 0.50f, 0.34f},
    {"brass", 0.88f, 0.73f, 0.38f},
    {"bronze", 0.72f, 0.50f, 0.26f},
    {"gold", 1.00f, 0.80f, 0.36f},
    {"silver", 0.92f, 0.92f, 0.93f},
    {"titanium", 0.55f, 0.56f, 0.60f},
    {"gunmetal", 0.25f, 0.27f, 0.30f},
    {"verdigris", 0.36f, 0.62f, 0.52f},
};

inline const NamedColour STONE_VARIANTS[] = {
    {"white marble", 0.92f, 0.91f, 0.88f},
    {"black marble", 0.12f, 0.12f, 0.13f},
    {"grey granite", 0.52f, 0.52f, 0.53f},
    {"pink granite", 0.72f, 0.55f, 0.52f},
    {"slate", 0.28f, 0.31f, 0.34f},
    {"sandstone", 0.82f, 0.68f, 0.48f},
    {"limestone", 0.84f, 0.81f, 0.72f},
    {"basalt", 0.20f, 0.20f, 0.21f},
    {"terracotta", 0.72f, 0.38f, 0.25f},
    {"concrete", 0.62f, 0.61f, 0.58f},
    {"green marble", 0.24f, 0.40f, 0.32f},
    {"travertine", 0.86f, 0.78f, 0.64f},
};

// How a material is SHADED is the shader's business (brick_materials
// .gdshaderinc); its index here is the contract between the two, so the order
// is append-only.
struct BrickMaterialDef {
    const char *name;
    const NamedColour *variants;   // nullptr: the filament palette
    int variant_count;
};

inline const BrickMaterialDef BRICK_MATERIALS[] = {
    {"PLA", nullptr, 0},
    {"PLA matte", nullptr, 0},
    {"PLA silk", nullptr, 0},
    {"ABS", nullptr, 0},
    {"PETG", nullptr, 0},
    {"TPU", nullptr, 0},
    {"Nylon", nullptr, 0},
    {"Glow PLA", nullptr, 0},
    {"Carbon PLA", nullptr, 0},
    {"Wood PLA", WOOD_VARIANTS, (int)(sizeof(WOOD_VARIANTS) / sizeof(WOOD_VARIANTS[0]))},
    {"Wood", WOOD_VARIANTS, (int)(sizeof(WOOD_VARIANTS) / sizeof(WOOD_VARIANTS[0]))},
    {"Metal", METAL_VARIANTS, (int)(sizeof(METAL_VARIANTS) / sizeof(METAL_VARIANTS[0]))},
    {"Stone", STONE_VARIANTS, (int)(sizeof(STONE_VARIANTS) / sizeof(STONE_VARIANTS[0]))},
};
constexpr int BRICK_MATERIAL_COUNT = (int)(sizeof(BRICK_MATERIALS) / sizeof(BRICK_MATERIALS[0]));

inline int brick_material_colour_count(int material) {
    if (material < 0 || material >= BRICK_MATERIAL_COUNT) {
        return 0;
    }
    const BrickMaterialDef &m = BRICK_MATERIALS[material];
    return m.variants != nullptr ? m.variant_count : FILAMENT_PALETTE_SIZE;
}

inline const NamedColour &brick_material_colour_entry(int material, int colour) {
    const int m = (material >= 0 && material < BRICK_MATERIAL_COUNT) ? material : 0;
    const BrickMaterialDef &def = BRICK_MATERIALS[m];
    if (def.variants != nullptr) {
        return def.variants[((colour % def.variant_count) + def.variant_count) % def.variant_count];
    }
    return FILAMENT_PALETTE[((colour % FILAMENT_PALETTE_SIZE) + FILAMENT_PALETTE_SIZE)
            % FILAMENT_PALETTE_SIZE];
}

inline Color filament_colour(int index) {
    if (index < 0 || index >= FILAMENT_PALETTE_SIZE) {
        return Color(1.0f, 0.0f, 1.0f); // missing-colour magenta
    }
    const NamedColour &e = FILAMENT_PALETTE[index];
    return Color(e.r, e.g, e.b);
}

/// The colour a block is drawn in: RGB resolved through its material, the
/// material itself in alpha (1.0 = material 0).
inline Color block_rgba(int material, int colour) {
    const NamedColour &e = brick_material_colour_entry(material, colour);
    const int m = (material >= 0 && material < BRICK_MATERIAL_COUNT) ? material : 0;
    return Color(e.r, e.g, e.b, 1.0f - (float)m / 255.0f);
}

} // namespace brick

#endif // BRICK_GRID_H
