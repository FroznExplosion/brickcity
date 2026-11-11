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


## The model files read: glTF / GLB and FBX through Godot's importers, OBJ and STL here.
const EXTENSIONS := ["glb", "gltf", "fbx", "obj", "stl"]


## The file as one mesh, or null if it cannot be read.
static func read(path: String) -> ArrayMesh:
	match path.get_extension().to_lower():
		"obj":
			return _soup_mesh(_read_obj(path))
		"stl":
			return _soup_mesh(_read_stl(path))
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


## The file as its pieces, each [name, mesh] in the model's frame (Docs/AssetWorkshop.md,
## "Models as objects"): a glTF / FBX's mesh nodes, an OBJ's objects and groups, an STL
## whole. Empty if it cannot be read.
static func read_pieces(path: String) -> Array:
	match path.get_extension().to_lower():
		"obj":
			var out := []
			for p in _read_obj_pieces(path):
				var m := _soup_mesh([p[1], p[2]])
				if m != null:
					out.append([p[0], m])
			return out
		"stl":
			var m := _soup_mesh(_read_stl(path))
			return [] if m == null else [[path.get_file().get_basename(), m]]
	var fbx := path.get_extension().to_lower() == "fbx"
	var doc: GLTFDocument = FBXDocument.new() if fbx else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if fbx else GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("model mesh: could not read %s" % path)
		return []
	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		return []
	var out := []
	for n in scene.find_children("*", "MeshInstance3D", true, false):
		var one := ArrayMesh.new()
		_add_one(n as MeshInstance3D, scene, one)
		if one.get_surface_count() > 0:
			out.append([String(n.name), one])
	scene.free()
	return out


## Every mesh under `root` as one mesh in root's frame: vertices and triangles only (it
## is drawn unshaded, and stamped). Null when there is none.
static func flatten(root: Node) -> ArrayMesh:
	var out := ArrayMesh.new()
	_add(root, root, out)
	return out if out.get_surface_count() > 0 else null


static func _add(n: Node, root: Node, out: ArrayMesh) -> void:
	if n is MeshInstance3D:
		_add_one(n as MeshInstance3D, root, out)
	for c in n.get_children():
		_add(c, root, out)


## One mesh node's surfaces into `out`, in root's frame.
static func _add_one(mi: MeshInstance3D, root: Node, out: ArrayMesh) -> void:
	if mi.mesh != null:
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
			_add_colours(s, arr, mi.get_active_material(si))
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s)


## The surface's colours as vertex colours (Docs/AssetWorkshop.md, "Colour from model to
## bricks"), into `s` (the surface being built from `arr`): the material's albedo times
## its texture at each corner's UV times the vertex colour where the material uses it.
## With a texture each triangle gets corners of its own (the index dropped), each read a
## little in toward the triangle's middle: a low-poly model's palette texture gives every
## face one swatch, and a corner shared with the next face would blend the two.
static func _add_colours(s: Array, arr: Array, mat: Material) -> void:
	var albedo := Color.WHITE
	var tex: Texture2D = null
	var use_vc := true
	if mat is BaseMaterial3D:
		var bm := mat as BaseMaterial3D
		albedo = bm.albedo_color
		tex = bm.albedo_texture
		use_vc = bm.vertex_color_use_as_albedo
	elif mat is ShaderMaterial:
		for n in ["albedo", "albedo_color", "base_color", "color"]:
			var p = (mat as ShaderMaterial).get_shader_parameter(n)
			if p is Color:
				albedo = p
				break
		for n in ["albedo_texture", "texture_albedo", "base_texture", "main_texture"]:
			var t = (mat as ShaderMaterial).get_shader_parameter(n)
			if t is Texture2D:
				tex = t
				break
	var vc = arr[Mesh.ARRAY_COLOR] if use_vc else null
	var uv = arr[Mesh.ARRAY_TEX_UV]
	var img := _image_of(tex)
	var v: PackedVector3Array = s[Mesh.ARRAY_VERTEX]
	if img == null or uv == null or (uv as PackedVector2Array).size() != v.size():
		if mat == null and (vc == null or (vc as PackedColorArray).size() != v.size()):
			return   # nothing to say: the model has no colour of its own
		var cols := PackedColorArray()
		cols.resize(v.size())
		for i in v.size():
			var c := albedo
			if vc != null and i < (vc as PackedColorArray).size():
				c *= (vc as PackedColorArray)[i]
			c.a = 1.0
			cols[i] = c
		s[Mesh.ARRAY_COLOR] = cols
		return
	var idx: PackedInt32Array = s[Mesh.ARRAY_INDEX] if s[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		for i in v.size() - v.size() % 3:
			idx.append(i)
	var nv := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs: PackedVector2Array = uv
	var size := Vector2(img.get_width(), img.get_height())
	for t in range(0, idx.size() - idx.size() % 3, 3):
		var mid := (uvs[idx[t]] + uvs[idx[t + 1]] + uvs[idx[t + 2]]) / 3.0
		for k in 3:
			var i := idx[t + k]
			var at := uvs[i].lerp(mid, 0.3)
			var px := Vector2i(int(fposmod(at.x, 1.0) * size.x), int(fposmod(at.y, 1.0) * size.y))
			var c := img.get_pixelv(px.clamp(Vector2i.ZERO, Vector2i(size) - Vector2i.ONE)) * albedo
			if vc != null and i < (vc as PackedColorArray).size():
				c *= (vc as PackedColorArray)[i]
			c.a = 1.0
			nv.append(v[i])
			cols.append(c)
	s[Mesh.ARRAY_VERTEX] = nv
	s[Mesh.ARRAY_INDEX] = null
	s[Mesh.ARRAY_COLOR] = cols


## A texture's pixels on the CPU, decompressed; null when it has none to give.
static func _image_of(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img = img.duplicate() as Image
		if img.decompress() != OK:
			return null
	return img


## [vertices, index] as a mesh; null when empty.
static func _soup_mesh(soup: Array) -> ArrayMesh:
	if soup.is_empty() or (soup[1] as PackedInt32Array).is_empty():
		return null
	var s := []
	s.resize(Mesh.ARRAY_MAX)
	s[Mesh.ARRAY_VERTEX] = soup[0]
	s[Mesh.ARRAY_INDEX] = soup[1]
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s)
	return out


## Wavefront OBJ: its `v` and `f` lines (a face of more than three corners a fan; v/vt/vn
## and negative indices as the format has them). Every object and group in one.
static func _read_obj(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("v "):
			var p := line.substr(2).split(" ", false)
			if p.size() >= 3:
				v.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		elif line.begins_with("f "):
			var corners := PackedInt32Array()
			for c in line.substr(2).split(" ", false):
				var i := int(c.get_slice("/", 0))
				corners.append(i - 1 if i > 0 else v.size() + i)
			for k in range(1, corners.size() - 1):
				idx.append_array([corners[0], corners[k], corners[k + 1]])
	return [v, idx]


## An OBJ's pieces: [name, vertices, index] for each `o` or `g` that has faces (indices
## are the file's, shared by all, so every piece keeps every vertex).
static func _read_obj_pieces(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var v := PackedVector3Array()
	var pieces := []
	var name := path.get_file().get_basename()
	var idx := PackedInt32Array()
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("v "):
			var p := line.substr(2).split(" ", false)
			if p.size() >= 3:
				v.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		elif line.begins_with("o ") or line.begins_with("g "):
			if not idx.is_empty():
				pieces.append([name, idx])
			idx = PackedInt32Array()
			name = line.substr(2).strip_edges()
		elif line.begins_with("f "):
			var corners := PackedInt32Array()
			for c in line.substr(2).split(" ", false):
				var i := int(c.get_slice("/", 0))
				corners.append(i - 1 if i > 0 else v.size() + i)
			for k in range(1, corners.size() - 1):
				idx.append_array([corners[0], corners[k], corners[k + 1]])
	if not idx.is_empty():
		pieces.append([name, idx])
	return pieces.map(func(p: Array) -> Array: return [p[0], v, p[1]])


## STL, binary or text: every facet's three corners.
static func _read_stl(path: String) -> Array:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 84:
		return []
	var v := PackedVector3Array()
	var n := bytes.decode_u32(80)
	if 84 + n * 50 == bytes.size():
		for t in n:
			var at := 84 + t * 50 + 12
			for k in 3:
				var o := at + k * 12
				v.append(Vector3(bytes.decode_float(o), bytes.decode_float(o + 4), bytes.decode_float(o + 8)))
	else:
		for line in bytes.get_string_from_ascii().split("\n"):
			var s := line.strip_edges()
			if s.begins_with("vertex"):
				var p := s.split(" ", false)
				if p.size() >= 4:
					v.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
	var idx := PackedInt32Array()
	for i in v.size() - v.size() % 3:
		idx.append(i)
	return [v, idx]


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
