#include "mesh_forge.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

void MeshForge::_bind_methods() {
	ClassDB::bind_method(D_METHOD("begin", "smooth"), &MeshForge::begin);
	ClassDB::bind_method(D_METHOD("add_tube", "stations", "ring_n", "cap_start", "cap_end"),
			&MeshForge::add_tube, DEFVAL(8), DEFVAL(true), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_rigid_segment", "p0", "p1", "r0", "r1", "bone", "ring_n", "inset"),
			&MeshForge::add_rigid_segment, DEFVAL(6), DEFVAL(0.03));
	ClassDB::bind_method(D_METHOD("add_sphere", "center", "r", "bones", "weights", "lat", "lon", "squash"),
			&MeshForge::add_sphere, DEFVAL(6), DEFVAL(8), DEFVAL(Vector3(1, 1, 1)));
	ClassDB::bind_method(D_METHOD("get_vertex_count"), &MeshForge::get_vertex_count);
	ClassDB::bind_method(D_METHOD("commit", "mesh", "material"), &MeshForge::commit);
}

void MeshForge::begin(bool p_smooth) {
	smooth = p_smooth;
	verts.clear();
	indices.clear();
	vcount = 0;
	verts.reserve(1024);
	indices.reserve(4096);
}

Basis MeshForge::basis_y_to(const Vector3 &dir) {
	Vector3 y = dir.normalized();
	if (y.length_squared() < 0.0001f) {
		y = Vector3(0, 1, 0);
	}
	Vector3 hint = Math::abs(y.dot(Vector3(1, 0, 0))) < 0.98f ? Vector3(1, 0, 0) : Vector3(0, 0, -1);
	Vector3 z = hint.cross(y).normalized();
	Vector3 x = y.cross(z).normalized();
	return Basis(x, y, z);
}

int32_t MeshForge::emit(const Vector3 &pos, const Vector2 &uv,
		const PackedInt32Array &bones, const PackedFloat32Array &weights) {
	Vtx v;
	v.pos = pos;
	v.uv = uv;
	for (int i = 0; i < 4; i++) {
		v.bones[i] = i < bones.size() ? bones[i] : 0;
		v.weights[i] = i < weights.size() ? weights[i] : 0.0f;
	}
	v.smooth_group = smooth ? 0u : vcount; // unique group per vertex = flat
	verts.push_back(v);
	return (int32_t)vcount++;
}

int32_t MeshForge::ring(const Vector3 &pos, const Basis &basis, float radius, float rx,
		float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, int n) {
	int32_t base = (int32_t)vcount;
	const Vector3 bx = basis.get_column(0);
	const Vector3 bz = basis.get_column(2);
	for (int k = 0; k <= n; k++) { // +1 duplicated seam vertex, identical position
		float a = (float)Math_TAU * (float)(k % n) / (float)n;
		Vector3 off = bx * (Math::cos(a) * radius * rx) + bz * (Math::sin(a) * radius);
		emit(pos + off, Vector2((float)k / (float)n, v), bones, weights);
	}
	return base;
}

void MeshForge::cap(int32_t ring_base, int ring_n, const Vector3 &tip, const Vector3 &axis_y,
		float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, bool flip) {
	int32_t tip_i = emit(tip, Vector2(0.5f, v), bones, weights);
	for (int k = 0; k < ring_n; k++) {
		if (flip) {
			indices.push_back(ring_base + k + 1);
			indices.push_back(tip_i);
			indices.push_back(ring_base + k);
		} else {
			indices.push_back(ring_base + k);
			indices.push_back(tip_i);
			indices.push_back(ring_base + k + 1);
		}
	}
	(void)axis_y;
}

void MeshForge::add_tube(const Array &stations, int ring_n, bool cap_start, bool cap_end) {
	const int ns = stations.size();
	if (ns < 2) {
		return;
	}
	std::vector<int32_t> bases;
	bases.reserve(ns);
	// cache first/last station data for caps
	Vector3 s0_pos, se_pos, s0_y, se_y;
	float s0_r = 0, se_r = 0, s0_v = 0, se_v = 0;
	PackedInt32Array s0_b, se_b;
	PackedFloat32Array s0_w, se_w;
	for (int i = 0; i < ns; i++) {
		Dictionary s = stations[i];
		Vector3 pos = s["pos"];
		Basis basis = s["basis"];
		float radius = s["radius"];
		float rx = s.has("rx") ? (float)s["rx"] : 1.0f;
		float v = s["v"];
		PackedInt32Array b = s["bones"];
		PackedFloat32Array w = s["weights"];
		bases.push_back(ring(pos, basis, radius, rx, v, b, w, ring_n));
		if (i == 0) { s0_pos = pos; s0_y = basis.get_column(1); s0_r = radius; s0_v = v; s0_b = b; s0_w = w; }
		if (i == ns - 1) { se_pos = pos; se_y = basis.get_column(1); se_r = radius; se_v = v; se_b = b; se_w = w; }
	}
	for (int i = 0; i < ns - 1; i++) {
		int32_t b0 = bases[i];
		int32_t b1 = bases[i + 1];
		for (int k = 0; k < ring_n; k++) {
			indices.push_back(b0 + k); indices.push_back(b1 + k); indices.push_back(b0 + k + 1);
			indices.push_back(b0 + k + 1); indices.push_back(b1 + k); indices.push_back(b1 + k + 1);
		}
	}
	if (cap_start) {
		cap(bases[0], ring_n, s0_pos - s0_y * s0_r * 0.6f, s0_y, s0_v, s0_b, s0_w, true);
	}
	if (cap_end) {
		cap(bases[ns - 1], ring_n, se_pos + se_y * se_r * 0.6f, se_y, se_v, se_b, se_w, false);
	}
}

void MeshForge::add_rigid_segment(const Vector3 &p0, const Vector3 &p1, float r0, float r1,
		int bone, int ring_n, float inset) {
	Vector3 dir = (p1 - p0).normalized();
	Basis b = basis_y_to(dir);
	Vector3 q0 = p0 + dir * inset;
	Vector3 q1 = p1 - dir * inset;
	PackedInt32Array bn;
	bn.push_back(bone); bn.push_back(0); bn.push_back(0); bn.push_back(0);
	PackedFloat32Array w;
	w.push_back(1.0f); w.push_back(0.0f); w.push_back(0.0f); w.push_back(0.0f);

	Array sts;
	Dictionary s0, s1;
	s0["pos"] = q0; s0["basis"] = b; s0["radius"] = r0; s0["rx"] = 1.0f; s0["v"] = 0.0f;
	s0["bones"] = bn; s0["weights"] = w;
	s1["pos"] = q1; s1["basis"] = b; s1["radius"] = r1; s1["rx"] = 1.0f; s1["v"] = 1.0f;
	s1["bones"] = bn; s1["weights"] = w;
	sts.push_back(s0);
	sts.push_back(s1);
	add_tube(sts, ring_n, true, true);
}

void MeshForge::add_sphere(const Vector3 &center, float r, const PackedInt32Array &bones,
		const PackedFloat32Array &weights, int lat, int lon, const Vector3 &squash) {
	std::vector<int32_t> rows;
	rows.reserve(lat + 1);
	for (int i = 0; i <= lat; i++) {
		float phi = (float)Math_PI * (float)i / (float)lat;
		float y = Math::cos(phi) * r * (float)squash.y;
		float rr = Math::sin(phi) * r;
		int32_t base = (int32_t)vcount;
		for (int k = 0; k <= lon; k++) {
			float a = (float)Math_TAU * (float)(k % lon) / (float)lon;
			Vector3 off(Math::cos(a) * rr * (float)squash.x, y, Math::sin(a) * rr * (float)squash.z);
			emit(center + off, Vector2((float)k / (float)lon, (float)i / (float)lat), bones, weights);
		}
		rows.push_back(base);
	}
	for (int i = 0; i < lat; i++) {
		int32_t b0 = rows[i];
		int32_t b1 = rows[i + 1];
		for (int k = 0; k < lon; k++) {
			indices.push_back(b0 + k); indices.push_back(b0 + k + 1); indices.push_back(b1 + k);
			indices.push_back(b0 + k + 1); indices.push_back(b1 + k + 1); indices.push_back(b1 + k);
		}
	}
}

void MeshForge::commit(const Ref<ArrayMesh> &mesh, const Ref<Material> &material) {
	ERR_FAIL_COND(mesh.is_null());
	if (vcount == 0) {
		return;
	}
	const size_t nv = verts.size();

	// ---- normal generation, SurfaceTool-compatible ------------------------
	// smooth: vertices sharing (bitwise) position accumulate together, so the
	// duplicated UV-seam vertex gets the same normal as ring vertex 0.
	// flat (unique smooth groups): accumulate per emitted vertex only.
	std::vector<Vector3> nrm(nv, Vector3());
	HashMap<Vector3, Vector3> pos_accum;
	const size_t ntri = indices.size() / 3;
	for (size_t t = 0; t < ntri; t++) {
		int32_t i0 = indices[t * 3 + 0];
		int32_t i1 = indices[t * 3 + 1];
		int32_t i2 = indices[t * 3 + 2];
		const Vector3 &p0 = verts[i0].pos;
		const Vector3 &p1 = verts[i1].pos;
		const Vector3 &p2 = verts[i2].pos;
		// winding matches SurfaceTool's convention (clockwise front faces)
		Vector3 fn = (p0 - p1).cross(p0 - p2); // area-weighted
		if (smooth) {
			pos_accum[p0] += fn;
			pos_accum[p1] += fn;
			pos_accum[p2] += fn;
		} else {
			nrm[i0] += fn;
			nrm[i1] += fn;
			nrm[i2] += fn;
		}
	}
	for (size_t i = 0; i < nv; i++) {
		Vector3 n = smooth ? (pos_accum.has(verts[i].pos) ? pos_accum[verts[i].pos] : Vector3(0, 1, 0)) : nrm[i];
		float l = n.length();
		nrm[i] = l > 0.00001f ? n / l : Vector3(0, 1, 0);
	}

	// ---- pack arrays -------------------------------------------------------
	PackedVector3Array pv, pn;
	PackedVector2Array puv;
	PackedInt32Array pb, pidx;
	PackedFloat32Array pw;
	pv.resize(nv); pn.resize(nv); puv.resize(nv);
	pb.resize(nv * 4); pw.resize(nv * 4);
	pidx.resize(indices.size());
	Vector3 *pvw = pv.ptrw();
	Vector3 *pnw = pn.ptrw();
	Vector2 *puvw = puv.ptrw();
	int32_t *pbw = pb.ptrw();
	float *pww = pw.ptrw();
	int32_t *pidxw = pidx.ptrw();
	for (size_t i = 0; i < nv; i++) {
		pvw[i] = verts[i].pos;
		pnw[i] = nrm[i];
		puvw[i] = verts[i].uv;
		for (int j = 0; j < 4; j++) {
			pbw[i * 4 + j] = verts[i].bones[j];
			pww[i * 4 + j] = verts[i].weights[j];
		}
	}
	for (size_t i = 0; i < indices.size(); i++) {
		pidxw[i] = indices[i];
	}

	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = pv;
	arrays[Mesh::ARRAY_NORMAL] = pn;
	arrays[Mesh::ARRAY_TEX_UV] = puv;
	arrays[Mesh::ARRAY_BONES] = pb;
	arrays[Mesh::ARRAY_WEIGHTS] = pw;
	arrays[Mesh::ARRAY_INDEX] = pidx;

	Ref<ArrayMesh> m = mesh;
	int surf = m->get_surface_count();
	m->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	if (material.is_valid()) {
		m->surface_set_material(surf, material);
	}
}
