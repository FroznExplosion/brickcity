#include "mesh_merge.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/vector3.hpp>

void MeshMerge::append(const Array &arrays, const Transform3D &xf, const Color &colour) {
    if (arrays.size() < Mesh::ARRAY_MAX) {
        return;
    }
    const PackedVector3Array v = arrays[Mesh::ARRAY_VERTEX];
    if (v.is_empty()) {
        return;
    }
    const Variant nv = arrays[Mesh::ARRAY_NORMAL];
    const Variant cv = arrays[Mesh::ARRAY_COLOR];
    const Variant uv = arrays[Mesh::ARRAY_TEX_UV];
    const Variant u2v = arrays[Mesh::ARRAY_TEX_UV2];
    const Variant iv = arrays[Mesh::ARRAY_INDEX];
    const PackedVector3Array n = nv.get_type() == Variant::PACKED_VECTOR3_ARRAY ? (PackedVector3Array)nv : PackedVector3Array();
    const PackedColorArray c = cv.get_type() == Variant::PACKED_COLOR_ARRAY ? (PackedColorArray)cv : PackedColorArray();
    const PackedVector2Array u = uv.get_type() == Variant::PACKED_VECTOR2_ARRAY ? (PackedVector2Array)uv : PackedVector2Array();
    const PackedVector2Array u2 = u2v.get_type() == Variant::PACKED_VECTOR2_ARRAY ? (PackedVector2Array)u2v : PackedVector2Array();
    const PackedInt32Array ix = iv.get_type() == Variant::PACKED_INT32_ARRAY ? (PackedInt32Array)iv : PackedInt32Array();

    const int64_t count = v.size();
    const int64_t base = verts.size();
    verts.resize(base + count);
    normals.resize(base + count);
    colours.resize(base + count);
    uvs.resize(base + count);
    uv2s.resize(base + count);
    Vector3 *pv = verts.ptrw() + base;
    Vector3 *pn = normals.ptrw() + base;
    Color *pc = colours.ptrw() + base;
    Vector2 *pu = uvs.ptrw() + base;
    Vector2 *pu2 = uv2s.ptrw() + base;
    const Vector3 *sv = v.ptr();
    const Basis &bs = xf.basis;
    for (int64_t i = 0; i < count; ++i) {
        pv[i] = xf.xform(sv[i]);
        pn[i] = i < n.size() ? bs.xform(n[i]).normalized() : Vector3(0, 1, 0);
        pc[i] = colour.r >= 0.0f ? colour : (i < c.size() ? c[i] : Color(1, 1, 1, 1));
        pu[i] = i < u.size() ? u[i] : Vector2();
        pu2[i] = i < u2.size() ? u2[i] : Vector2(0.7f, 0.42f);
    }
    if (ix.is_empty()) {
        const int64_t ib = indices.size();
        indices.resize(ib + count);
        int32_t *pi = indices.ptrw() + ib;
        for (int64_t i = 0; i < count; ++i) {
            pi[i] = (int32_t)(base + i);
        }
        return;
    }
    const int32_t *si = ix.ptr();
    const int64_t tris = ix.size() / 3;
    const int64_t ib = indices.size();
    indices.resize(ib + tris * 3);
    int32_t *pi = indices.ptrw() + ib;
    int64_t k = 0;
    for (int64_t t = 0; t < tris; ++t) {
        const int32_t a = si[t * 3], b = si[t * 3 + 1], d = si[t * 3 + 2];
        if (a == b || b == d || a == d) {
            continue;
        }
        pi[k++] = (int32_t)base + a;
        pi[k++] = (int32_t)base + b;
        pi[k++] = (int32_t)base + d;
    }
    indices.resize(ib + k);
}

void MeshMerge::add_surface(const Array &arrays, const Transform3D &xf, const Color &colour) {
    append(arrays, xf, colour);
}

void MeshMerge::add_instances(const Array &arrays, const Transform3D &xf, const PackedFloat32Array &buffer) {
    const float *b = buffer.ptr();
    const int64_t n = buffer.size() / 16;
    for (int64_t s = 0; s < n; ++s) {
        const float *o = b + s * 16;
        // Row-major 3x4: rows are (x.x, y.x, z.x, origin.x) ...
        const Basis basis(o[0], o[1], o[2], o[4], o[5], o[6], o[8], o[9], o[10]);
        const Transform3D sx(basis, Vector3(o[3], o[7], o[11]));
        append(arrays, xf * sx, Color(o[12], o[13], o[14], o[15]));
    }
}

Array MeshMerge::commit() const {
    Array out;
    if (verts.is_empty()) {
        return out;
    }
    out.resize(Mesh::ARRAY_MAX);
    out[Mesh::ARRAY_VERTEX] = verts;
    out[Mesh::ARRAY_NORMAL] = normals;
    out[Mesh::ARRAY_COLOR] = colours;
    out[Mesh::ARRAY_TEX_UV] = uvs;
    out[Mesh::ARRAY_TEX_UV2] = uv2s;
    out[Mesh::ARRAY_INDEX] = indices;
    return out;
}

void MeshMerge::_bind_methods() {
    ClassDB::bind_method(D_METHOD("add_surface", "arrays", "xf", "colour"), &MeshMerge::add_surface);
    ClassDB::bind_method(D_METHOD("add_instances", "arrays", "xf", "buffer"), &MeshMerge::add_instances);
    ClassDB::bind_method(D_METHOD("commit"), &MeshMerge::commit);
    ClassDB::bind_method(D_METHOD("vertex_count"), &MeshMerge::vertex_count);
}
