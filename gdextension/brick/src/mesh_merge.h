#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

using namespace godot;

/// Many surfaces into one mesh, transformed (scripts/recipe_mesh.gd).
///
/// A build recipe -- a tree, an item -- is meshed as its frames' chunk
/// meshes plus one stud mesh a stud, merged into a single ArrayMesh for
/// instancing and for its impostor bake. That merge was a GDScript loop a
/// VERTEX: 900 ms for the city's four tree kinds at startup.
class MeshMerge : public RefCounted {
    GDCLASS(MeshMerge, RefCounted)

protected:
    static void _bind_methods();

public:
    /// One surface's arrays, transformed by `xf`. `colour` replaces the
    /// vertex colours unless its red is negative. Missing UVs get zero, a
    /// missing UV2 a whole brick face (0.7, 0.42), a missing normal UP.
    /// Degenerate triangles (a brick mesh's zero-area hidden-face slots) are
    /// dropped.
    void add_surface(const Array &arrays, const Transform3D &xf, const Color &colour);
    /// The same surface once an instance: `buffer` holds 16 floats each, a
    /// row-major 3x4 transform then a colour (BrickWorld's stud layout), and
    /// each copy is placed at xf * its transform, in its colour.
    void add_instances(const Array &arrays, const Transform3D &xf, const PackedFloat32Array &buffer);
    /// The merged mesh arrays (Mesh.ARRAY_MAX long), or an empty Array.
    Array commit() const;
    int vertex_count() const { return (int)verts.size(); }

private:
    void append(const Array &arrays, const Transform3D &xf, const Color &colour);
    PackedVector3Array verts, normals;
    PackedColorArray colours;
    PackedVector2Array uvs, uv2s;
    PackedInt32Array indices;
};
