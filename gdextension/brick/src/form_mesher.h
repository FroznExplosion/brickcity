#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

using namespace godot;

/// A smooth, closed surface round a solid given as samples: the asset workshop's
/// shells (Docs/AssetWorkshop.md, "Shells"). A part's form is sampled finer than
/// the brick grid -- each sample solid or not -- and this makes the outside of it.
///
/// Surface nets: one vertex in every cube of eight samples that has both solid and
/// empty corners, at the middle of its crossing edges; a quad across every edge
/// that crosses, joining the four cubes round it. Closed by construction (the grid
/// is treated as empty outside `dims`). Then smoothed: each vertex moved toward the
/// middle of its neighbours, `smooth` times, but never out of its own cube -- so a
/// stair of samples becomes a slope and a ring becomes round, and nothing moves
/// more than a sample from where the samples put it.
class FormMesher : public RefCounted {
    GDCLASS(FormMesher, RefCounted)

protected:
    static void _bind_methods();

public:
    /// `field`: dims.x * dims.y * dims.z bytes, x fastest, then y, then z; non-zero
    /// is solid; 2 is solid and PINNED -- a cube touching one is not smoothed, so a face
    /// where the solid meets something else stays flat, exactly where the samples end.
    /// Sample (x, y, z) is at ((x, y, z) + 0.5) * `cell` from the origin.
    /// Returns ArrayMesh surface arrays (vertex, normal, index), wound as the
    /// project's brick meshes are, or an empty Array for an empty field.
    static Array surface(const PackedByteArray &field, const Vector3i &dims, const Vector3 &cell, int smooth);

    /// The field shrunk: a sample stays solid only if every sample within `reach`
    /// of it (a box, `reach` samples each way along each axis) is solid -- outside
    /// the field counts as empty. What a shell's thickness leaves for its bricks.
    static PackedByteArray erode(const PackedByteArray &field, const Vector3i &dims, const Vector3i &reach);
};
