#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3i.hpp>

using namespace godot;

/// What an edit to the ground lets go (Docs/TerrainCollapse.md).
///
/// The ground is plate cells, not bricks, so a survey packs the cells round an
/// edit into VIRTUAL bricks -- a fixed bond worked out from absolute
/// coordinates, stronger for rock than for dirt, single studs for sand -- lays
/// them into a private BrickWorld made for the survey, and asks it the
/// buildings' own question (solve_structure: the tension cascade, then what
/// still reaches the ground). Sand and gravel never hang: a loose cell with air
/// under it falls, with every loose cell stacked on it.
///
/// Pure reads of the terrain and a world of its own: a worker's job.
class TerrainCollapse : public RefCounted {
    GDCLASS(TerrainCollapse, RefCounted);

protected:
    static void _bind_methods();

public:
    /// Studs round the edit box the region reaches (then one more: the ring).
    static constexpr int REACH = 10;
    /// Bricks under / over the edit box the region reaches.
    static constexpr int BELOW = 4;
    static constexpr int ABOVE = 20;
    /// Studs round the edit box a cell with air under it makes a solve due.
    static constexpr int NEAR = 5;

    /// The survey of plate box [lo, hi] (inclusive), just edited.
    /// `tension`: what a stud holds (BrickStrength.tension()); `mass_per_cell`:
    /// BrickPalette.MASS_PER_CELL.
    /// Returns {
    ///   sand:      PackedInt32Array, 4 a falling column: x, z, bottom plate,
    ///              cells (each a brick tall, bottom up)
    ///   sand_mats: PackedByteArray, the columns' cells' materials, in order
    ///   groups:    Array of PackedInt32Array, 6 a brick: x, plate y, z (min
    ///              corner, absolute), size x, size z, material -- each a
    ///              loose group to fall as one piece
    ///   solved:    whether the structure was solved (anything hung near)
    ///   bricks, sample_ms, solve_ms
    /// }
    /// `building_times`: a building material's brick (MAT_FIL_BASE..) weighs
    /// this many times its cells: the survey runs at the ground's tension (x4
    /// the buildings'), so at x4 mass a building's bricks hold as the city's do.
    static Dictionary survey(Vector3i lo, Vector3i hi, double tension, double mass_per_cell,
            double building_times = 1.0);

    /// The class of a terrain material: 0 air, 1 loose (sand, gravel), 2
    /// medium (dirt, grass), 3 strong (rock).
    static int material_class(int material);
};
