class_name ModelMesh

## A model file read as one mesh in the model's own frame (Docs/AssetWorkshop.md, "SDF
## tools, round 4"): every mesh of the scene put where it is drawn, a skinned one posed by
## its skeleton. What the asset workshop draws, sizes and stamps into the field, so the
## three agree.
##
## A skinned mesh is drawn by its skeleton, not by its own node: a character's armature at
## 1/100 with bones a hundred times over, or turned to lie down, is drawn standing and
## real size. Reading the raw vertices with the node's transform put it in the field lying
## down and a hundredth the size (2026-10-19).


## The file (glTF, GLB or FBX) as one mesh, or null if it cannot be read.
static func read(path: String) -> ArrayMesh:
	var fbx := path.get_extension().to_lower() == "fbx"
	var doc: GLTFDocument = FBXDocument.new() if fbx else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if fbx else GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("model mesh: could not read %s" % path)
		return null
	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		return null
	var out := flatten(scene)
	scene.free()
	return out


## Every mesh under `root` as one mesh in root's frame: vertices and triangles only (it
## is drawn unshaded, and stamped). Null when there is none.
static func flatten(root: Node) -> ArrayMesh:
	var out := ArrayMesh.new()
	_add(root, root, out)
	return out if out.get_surface_count() > 0 else null


static func _add(n: Node, root: Node, out: ArrayMesh) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		var sk := mi.get_node_or_null(mi.skeleton) as Skeleton3D if mi.skin != null else null
		for si in mi.mesh.get_surface_count():
			if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arr := mi.mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if v.is_empty():
				continue
			if sk != null and arr[Mesh.ARRAY_BONES] != null and arr[Mesh.ARRAY_WEIGHTS] != null:
				v = _skinned(v, arr[Mesh.ARRAY_BONES], arr[Mesh.ARRAY_WEIGHTS], mi.skin, sk, _to(sk, root))
			else:
				var xf := _to(mi, root)
				for i in v.size():
					v[i] = xf * v[i]
			var s := []
			s.resize(Mesh.ARRAY_MAX)
			s[Mesh.ARRAY_VERTEX] = v
			if arr[Mesh.ARRAY_INDEX] != null and not (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
				s[Mesh.ARRAY_INDEX] = arr[Mesh.ARRAY_INDEX]
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s)
	for c in n.get_children():
		_add(c, root, out)


## A node's transform in root's frame, from the nodes' own transforms (the scene is not in
## the tree, so there is no global transform to ask).
static func _to(n: Node, root: Node) -> Transform3D:
	var xf := Transform3D()
	var q := n
	while q != null and q != root:
		if q is Node3D:
			xf = (q as Node3D).transform * xf
		q = q.get_parent()
	return xf


## Linear blend skinning in the skeleton's current pose, then into root's frame.
static func _skinned(v: PackedVector3Array, bones: PackedInt32Array, weights: PackedFloat32Array,
		skin: Skin, sk: Skeleton3D, to_root: Transform3D) -> PackedVector3Array:
	var mats: Array[Transform3D] = []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		mats.append(to_root * (sk.get_bone_global_pose(b) if b >= 0 else Transform3D()) * skin.get_bind_pose(i))
	var per := bones.size() / v.size()
	var out := PackedVector3Array()
	out.resize(v.size())
	for k in v.size():
		var p := Vector3.ZERO
		var wsum := 0.0
		for j in per:
			var w := weights[k * per + j]
			var bi := bones[k * per + j]
			if w > 0.0 and bi < mats.size():
				p += (mats[bi] * v[k]) * w
				wsum += w
		out[k] = p / wsum if wsum > 0.0 else to_root * v[k]
	return out
