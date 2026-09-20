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

inline Color filament_colour(int index) {
    switch (index) {
        case FIL_WHITE:      return Color(0.92f, 0.92f, 0.90f);
        case FIL_BLACK:      return Color(0.10f, 0.10f, 0.11f);
        case FIL_GREY:       return Color(0.55f, 0.56f, 0.58f);
        case FIL_DARK_GREY:  return Color(0.30f, 0.31f, 0.33f);
        case FIL_RED:        return Color(0.72f, 0.13f, 0.13f);
        case FIL_ORANGE:     return Color(0.87f, 0.42f, 0.09f);
        case FIL_YELLOW:     return Color(0.93f, 0.75f, 0.10f);
        case FIL_GREEN:      return Color(0.20f, 0.55f, 0.24f);
        case FIL_BLUE:       return Color(0.13f, 0.35f, 0.68f);
        case FIL_LIGHT_BLUE: return Color(0.40f, 0.66f, 0.85f);
        case FIL_BROWN:      return Color(0.40f, 0.26f, 0.17f);
        case FIL_TAN:        return Color(0.79f, 0.68f, 0.50f);
        default:             return Color(1.0f, 0.0f, 1.0f); // missing-colour magenta
    }
}

} // namespace brick

#endif // BRICK_GRID_H
