#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector2i.hpp>

using namespace godot;

namespace brick {
/// A fitted brick: its min corner (studs), bottom course, size in studs and
/// courses, the material of most of its cells; loose = sand/gravel 1x1.
struct FitBrick {
    int x = 0, z = 0, c = 0, sx = 1, sz = 1, h = 1, mat = 0;
    bool loose = false;
};
/// THE LOOKUP (Docs/TerrainRegions.md 12): the fitted brick a generated cell
/// is in. Any thread; a tile's first ask fits it (ms), later ones are a
/// lookup. False where nothing is fitted (air, the deep tier, not yet
/// configured). Generated cells only: edits are the caller's.
bool fitted_brick(int x, int course, int z, FitBrick &out);
/// Drops every kept tile (new settings, a new world).
void fitted_clear();
} // namespace brick

/// THE REGION FIT (Docs/TerrainRegions.md 3, 11): bricks of random sizes,
/// fitted per region from the GENERATED cells, staggered by a score.
/// Stage B1: only the probe's side (region_fit_probe) -- nothing in the game
/// reads it yet.
///
/// A cell is one stud by one course (3 plates). Courses come in LAYERS of
/// three; a tall brick stays inside its layer. Each course is cut into
/// 16 x 16 squares, shifted 8 studs on odd courses, so a cut never stands
/// over a cut; a brick stays inside its square in every course it spans.
/// Even layers are fitted first, each on its own (a pure function of the
/// generated cells); odd layers are then scored against the even layers
/// under and over them, so the stagger never needs more than one layer
/// round it.
class TerrainFit : public RefCounted {
    GDCLASS(TerrainFit, RefCounted);

protected:
    static void _bind_methods();

public:
    /// Runs the fits a probe asks for over sampled areas of the current
    /// world. `areas`: Vector2i tile origins of 5 x 5 tile areas (metrics on
    /// the middle 3 x 3). `variants`: Dictionaries (see terrain_fit.cpp
    /// FitParams). Returns one Dictionary a variant: metrics summed over the
    /// areas, plus pictures of the first area.
    static Array run(const Array &areas, const Array &variants);
    /// The world's fill settings (the worldgen preset's "bricks",
    /// WorldgenPresets.DEFAULT_BRICKS' keys). Held for the game's bricks.
    static void configure(const Dictionary &settings);
    static Dictionary get_configured();
    /// fitted_brick for scripts: {x, z, c, sx, sz, h, mat, loose}, or empty.
    static Dictionary brick_at(int x, int course, int z);
    static Dictionary lookup_stats();
    /// The lookup against the batch fit (region_fit_probe): counts of cells
    /// checked, wrong and missing, from `threads` threads.
    static Dictionary check_lookup(Vector2i tile, int threads = 4);
};
