#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

using namespace godot;

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
};
