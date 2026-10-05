#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3i.hpp>

using namespace godot;

/// The sampling half of ShapedParts (scripts/shaped_parts.gd): a shaped
/// part's cell, stud and socket masks from its convex prisms.
///
/// Each cell is SAMPLES^3 point-in-prism tests; in GDScript that was ~43 ms a
/// part and ~0.7 s for the palette's 17 shaped parts, every time a palette
/// was baked. The arithmetic is the script's, step for step and in the same
/// precision (points rounded to float as a Vector3 is, crosses in float), so
/// the masks -- which the connectivity graph and the masses are built on --
/// come out identical.
class ShapedSampler : public RefCounted {
    GDCLASS(ShapedSampler, RefCounted)

protected:
    static void _bind_methods();

public:
    /// `pieces`: [{poly: PackedVector2Array, plane: "zy"|"xy"|"xz", lo, hi}].
    /// Returns {cells, studs, sockets, solid} as ShapedParts._mask did.
    static Dictionary mask(const Array &pieces, const Vector3i &size, double stud_m, double plate_m,
            int samples);
};
