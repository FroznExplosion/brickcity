#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
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
    /// `blur`: the samples blurred that many times first ([1 2 1] along each axis), and the
    /// surface laid where the blurred density crosses one half, its crossings
    /// interpolated: a staircase of samples comes out as the slant it stood for.
    /// `target` (0: as many as it takes): decimated to about that many triangles,
    /// flat areas first (quadric edge collapse), closed and never folded, pinned
    /// vertices where they are.
    static Array surface(const PackedByteArray &field, const Vector3i &dims, const Vector3 &cell, int smooth,
            int blur = 0, int target = 0);

    /// The field shrunk: a sample stays solid only if every sample within `reach`
    /// of it (a box, `reach` samples each way along each axis) is solid -- outside
    /// the field counts as empty. What a shell's thickness leaves for its bricks.
    /// The surface of a solid given as distances: `distance` a float a sample, negative
    /// inside, in metres or any one unit; the surface goes exactly where it crosses zero
    /// (interpolated along each edge), so an outline drawn finer than the samples is
    /// followed, corners and all. `pins` (optional, a byte a sample): cubes not smoothed.
    /// `target`: decimated to about that many triangles, as `surface`.
    static Array surface_sdf(const PackedFloat32Array &distance, const PackedByteArray &pins, const Vector3i &dims,
            const Vector3 &cell, int smooth, int target);

    /// Signed distance to some outlines on a grid: sample (u, v) at `origin` + (u, v) + 0.5
    /// times `step`, distances measured with both scaled by `scale` (so plates and studs
    /// count alike); negative inside any outline (its winding not zero).
    static PackedFloat32Array polygon_distance(const Array &polygons, const Vector2 &origin, const Vector2 &step,
            const Vector2i &size, const Vector2 &scale);

    static PackedByteArray erode(const PackedByteArray &field, const Vector3i &dims, const Vector3i &reach);
};
