#ifndef MESH_FORGE_H
#define MESH_FORGE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <vector>

namespace godot {

// Native port of PartMeshLib's geometry batch. Same emission order, same
// index patterns, so vertex counts and AABBs match the GDScript path exactly.
// Organic vs robotic stays a *skin-weight policy*: callers pass blended or
// hard weights per ring station; the forge just emits fast.
class MeshForge : public RefCounted {
	GDCLASS(MeshForge, RefCounted)

	struct Vtx {
		Vector3 pos;
		Vector2 uv;
		int32_t bones[4];
		float weights[4];
		uint32_t smooth_group;
	};

	std::vector<Vtx> verts;
	std::vector<int32_t> indices;
	bool smooth = true;
	uint32_t vcount = 0;

	int32_t emit(const Vector3 &pos, const Vector2 &uv,
			const PackedInt32Array &bones, const PackedFloat32Array &weights);
	int32_t ring(const Vector3 &pos, const Basis &basis, float radius, float rx,
			float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, int n);
	void cap(int32_t ring_base, int ring_n, const Vector3 &tip, const Vector3 &axis_y,
			float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, bool flip);

protected:
	static void _bind_methods();

public:
	void begin(bool p_smooth);

	// stations: Array of Dictionaries {pos, basis, radius, rx, v, bones, weights}
	void add_tube(const Array &stations, int ring_n, bool cap_start, bool cap_end);
	void add_rigid_segment(const Vector3 &p0, const Vector3 &p1, float r0, float r1,
			int bone, int ring_n, float inset);
	void add_sphere(const Vector3 &center, float r, const PackedInt32Array &bones,
			const PackedFloat32Array &weights, int lat, int lon, const Vector3 &squash);

	int get_vertex_count() const { return (int)vcount; }
	void commit(const Ref<ArrayMesh> &mesh, const Ref<Material> &material);

	static Basis basis_y_to(const Vector3 &dir);
};

} // namespace godot

#endif
