#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

using namespace godot;

/// A recipe building's shell, the arrays of it (scripts/city/building_shell.gd).
///
/// BuildingShell.build_arrays walked every band of a tower in GDScript and
/// pushed each quad's four corners into five arrays: 2.7-5.7 ms for a 4,000-
/// 9,000-vertex shell, on the main thread whenever a damaged building left
/// for range or a storey was laid (Docs/HandoffPerf.md 6.5). This is the same
/// walk, the same quads in the same order.
class ShellMesher : public RefCounted {
    GDCLASS(ShellMesher, RefCounted)

protected:
    static void _bind_methods();

public:
    /// `bands`: four ints a band of TowerRecipe.layout -- kind (0 base,
    /// 1 course, 2 slab, 3 cornice), y and plates (in plates), and its
    /// filament. `masks`: five ints a band -- 1 if it has a damage mask, then
    /// the four segment masks in BuildingShell's SIDE_* order. `wall_thick`
    /// in studs. Mesh.ARRAY_MAX arrays, as BuildingShell.build_arrays.
    /// Touches nothing shared: safe on a worker.
    static Array build_arrays(int footprint_x, int footprint_z, int wall_thick,
            const PackedInt32Array &bands, const PackedInt32Array &masks);
};
