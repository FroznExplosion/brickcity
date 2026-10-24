class_name PartPackage
extends RefCounted
## A part as one file to share (Docs/ModularParts.md section 7, stage 9): `<id>.bcpart`, a zip
## of data only -- never a scene, never a script. A scene file can carry a script, and a part
## from another player must never run code here, so the game builds the part's nodes itself
## from the arrays in the package.
##
##   part.json        the record, creator and bricks included (PartRecord)
##   mesh.json        the part's nodes: Node3D, MeshInstance3D, MultiMeshInstance3D, their
##                    places, and their meshes as arrays (base64 of packed arrays); materials
##                    by role (brick, stud) or as plain colours
##   interfaces.json  the interfaces it uses, as standards.json has them
##   thumb.png        the catalogue card's picture, when one was made
##   manifest.json    the format, the id and rev, each file's sha256, and the content hash:
##                    the part's identity across machines
##
## Import refuses a package that is too big, has a file it should not, fails a hash, or whose
## record or nodes break the schema. What passes lands in user://parts/custom/<id>/ with
## everything it came with -- its part.scn built here, from the arrays.

const FORMAT := 1
const EXT := "bcpart"
const FILES := ["part.json", "mesh.json", "interfaces.json", "thumb.png", "manifest.json"]
const REQUIRED := ["part.json", "mesh.json", "interfaces.json", "manifest.json"]
## Limits: the package on disk, any one file in it, nodes, vertices.
const MAX_PACKAGE := 8 * 1024 * 1024
const MAX_FILE := 16 * 1024 * 1024
const MAX_NODES := 512
const MAX_VERTICES := 2_000_000
const NODE_TYPES := ["Node3D", "MeshInstance3D", "MultiMeshInstance3D"]
const EXPORT_DIR := "user://parts/export/"
const BRICK_SHADER := "res://shaders/brick.gdshader"
const STUD_SHADERS := ["res://shaders/printed.gdshader"]
## Packed array kinds as written: name -> how to read it back.
const KINDS := ["v3", "v2", "c", "f32", "i32", "u8"]
## The mesh arrays a package may have.
const ALLOWED_ARRAYS := [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR,
		Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2,
		Mesh.ARRAY_CUSTOM3, Mesh.ARRAY_INDEX]


# --- export -----------------------------------------------------------------------

## Write the part in folder `dir` (part.json, part.scn) as a package at `out` (default
## EXPORT_DIR/<id>.bcpart). {ok, path, hash} or {ok: false, why}.
static func export_part(dir: String, out: String = "") -> Dictionary:
	var made := pack(dir)
	if not made.ok:
		return made
	if out == "":
		DirAccess.make_dir_recursive_absolute(EXPORT_DIR)
		out = EXPORT_DIR + "%s.%s" % [made.id, EXT]
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "why": "cannot write %s: %s" % [out, error_string(FileAccess.get_open_error())]}
	f.store_buffer(made.bytes)
	f.close()
	return {"ok": true, "path": out, "hash": made.hash}


## The part in folder `dir` as a package, in memory: {ok, id, rev, hash, bytes} -- what is
## written to a file, sent to a joining player in chunks, or hashed for the lobby.
static func pack(dir: String) -> Dictionary:
	var r := PartRecord.load_file(dir + PartCatalog.FILE)
	if r == null:
		return {"ok": false, "why": "no part in %s" % dir}
	var ps := ResourceLoader.load(dir + "part.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var node := ps.instantiate() as Node3D if ps != null else null
	if node == null:
		return {"ok": false, "why": "%s has no scene" % r.id}
	var mesh := describe(node)
	node.free()
	var files := {
		"part.json": _canon(r.to_dict()),
		"mesh.json": _canon(mesh),
		"interfaces.json": _canon(_interfaces_of(r)),
	}
	if FileAccess.file_exists(dir + "thumb.png"):
		files["thumb.png"] = FileAccess.get_file_as_bytes(dir + "thumb.png")
	var manifest := {"format": FORMAT, "id": r.id, "rev": r.rev, "files": {}}
	for f: String in files:
		manifest.files[f] = _sha(files[f])
	manifest["hash"] = content_hash(manifest.files)
	files["manifest.json"] = _canon(manifest)
	var tmp := "user://.bcpart_%d.tmp" % Time.get_ticks_usec()
	var zip := ZIPPacker.new()
	var err := zip.open(tmp)
	if err != OK:
		return {"ok": false, "why": "cannot pack: %s" % error_string(err)}
	for f: String in files:
		zip.start_file(f)
		zip.write_file(files[f])
		zip.close_file()
	zip.close()
	var bytes := FileAccess.get_file_as_bytes(tmp)
	DirAccess.remove_absolute(tmp)
	return {"ok": true, "id": r.id, "rev": r.rev, "hash": manifest.hash, "bytes": bytes}


## The content hash of the part in `dir`: the imported package's, else worked out (a part
## made here). "" if it is not a part.
static func hash_for(dir: String) -> String:
	var h := hash_of(dir)
	if h != "":
		return h
	var made := pack(dir)
	return String(made.hash) if made.ok else ""


## The identity of a part's content: the sha256 of its files' hashes, in name order. The
## manifest and the thumbnail are not content.
static func content_hash(file_hashes: Dictionary) -> String:
	var names := file_hashes.keys().filter(func(n: String) -> bool:
		return n != "manifest.json" and n != "thumb.png")
	names.sort()
	var joined := ""
	for n in names:
		joined += "%s:%s\n" % [n, file_hashes[n]]
	return _sha(joined.to_utf8_buffer())


## A node tree as data: what mesh.json holds.
static func describe(root: Node3D) -> Dictionary:
	var nodes := []
	var meshes := []
	var mesh_ids := {}
	_describe(root, -1, nodes, meshes, mesh_ids)
	return {"format": FORMAT, "nodes": nodes, "meshes": meshes}


static func _describe(n: Node, parent: int, nodes: Array, meshes: Array, mesh_ids: Dictionary) -> void:
	var type := n.get_class()
	if not type in NODE_TYPES:
		return   # nothing else is a part's to show
	var d := {"name": String(n.name), "parent": parent, "type": type,
			"xf": _xf_list((n as Node3D).transform)}
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			d["mesh"] = _mesh_id(mi.mesh, meshes, mesh_ids)
		d["material"] = _material_of(mi.material_override)
		var bevel: Variant = mi.get_instance_shader_parameter("geo_bevel")
		if bevel != null:
			d["geo_bevel"] = float(bevel)
	elif n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm != null:
			# The buffer kept on the node first: the renderer's copy is empty headless.
			var buf: PackedFloat32Array = mmi.get_meta(&"buffer", PackedFloat32Array())
			if buf.is_empty():
				buf = mm.buffer
			d["multimesh"] = {"count": mm.instance_count, "colors": mm.use_colors,
					"custom": mm.use_custom_data, "buffer": _enc(buf),
					"mesh": _mesh_id(mm.mesh, meshes, mesh_ids) if mm.mesh != null else -1}
		d["material"] = _material_of(mmi.material_override)
	var me := nodes.size()
	nodes.append(d)
	for c in n.get_children():
		_describe(c, me, nodes, meshes, mesh_ids)


static func _mesh_id(m: Mesh, meshes: Array, mesh_ids: Dictionary) -> int:
	if mesh_ids.has(m):
		return mesh_ids[m]
	var surfaces := []
	for s in m.get_surface_count():
		var arrays := m.surface_get_arrays(s)
		var enc := {}
		for k in arrays.size():
			if arrays[k] != null:
				enc[str(k)] = _enc(arrays[k])
		surfaces.append({"primitive": int((m as ArrayMesh).surface_get_primitive_type(s)) if m is ArrayMesh
				else Mesh.PRIMITIVE_TRIANGLES, "format": int(m.surface_get_format(s)) if m is ArrayMesh else 0,
				"arrays": enc, "material": _material_of(m.surface_get_material(s))})
	mesh_ids[m] = meshes.size()
	meshes.append({"surfaces": surfaces})
	return meshes.size() - 1


## A material by role: the brick shader, the stud shader, or a plain colour.
static func _material_of(m: Material) -> Dictionary:
	if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
		var path := (m as ShaderMaterial).shader.resource_path
		if path == BRICK_SHADER:
			return {"role": "brick"}
		if path in STUD_SHADERS or path.contains("stud") or path.contains("printed"):
			return {"role": "stud"}
		return {"role": "brick"}
	if m is StandardMaterial3D:
		var s := m as StandardMaterial3D
		var c := s.albedo_color
		return {"role": "plain", "albedo": [c.r, c.g, c.b, c.a], "roughness": s.roughness,
				"metallic": s.metallic, "vertex_color": s.vertex_color_use_as_albedo}
	return {"role": "none"} if m == null else {"role": "plain", "albedo": [0.6, 0.6, 0.6, 1.0]}


static func _interfaces_of(r: PartRecord) -> Dictionary:
	var used := {}
	if r.interface() != "":
		used[r.interface()] = PartStandards.interface(r.interface())
	for s: Dictionary in r.sockets:
		for a in s.get("accepts", []):
			used[String(a)] = PartStandards.interface(String(a))
	return {"standards": PartStandards.version(), "interfaces": used}


# --- import -----------------------------------------------------------------------

## Read and check the package at `path`; on success, its part goes in `into` (default the
## custom folder): part.json, part.scn built from its arrays, package.json (the manifest),
## thumb.png. {ok, id, rev, hash, dir} or {ok: false, why}. `official`: ids taken by a
## shipped part, which a package may not use.
static func import_file(path: String, into: String = PartCatalog.CUSTOM_DIR, official: PartCatalog = null) -> Dictionary:
	var got := read(path)
	if not got.ok:
		return got
	var r: PartRecord = got.record
	if official == null:
		official = PartCatalog.new()
		official.load_dir(PartCatalog.OFFICIAL_DIR, "official")
	if official.get_part(r.id) != null:
		return {"ok": false, "why": "'%s' is a shipped part's id" % r.id}
	var dir := into + r.id + "/"
	var have := PartRecord.load_file(dir + PartCatalog.FILE)
	if have != null:
		var have_hash := hash_of(dir)
		if have_hash == got.hash:
			return {"ok": true, "id": r.id, "rev": r.rev, "hash": got.hash, "dir": dir, "same": true}
		if have.rev >= r.rev:
			return {"ok": false, "why": "%s rev %d is here already; this is rev %d" % [r.id, have.rev, r.rev]}
	var node := build(got.mesh)
	if node == null:
		return {"ok": false, "why": "its nodes could not be built"}
	DirAccess.make_dir_recursive_absolute(dir)
	_own(node, node)
	var ps := PackedScene.new()
	var err := ps.pack(node)
	node.free()
	if err == OK:
		err = ResourceSaver.save(ps, dir + "part.scn")
	if err == OK:
		r.source = "custom"
		err = r.save_file(dir + PartCatalog.FILE)
	if err != OK:
		return {"ok": false, "why": error_string(err)}
	var f := FileAccess.open(dir + "package.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(got.manifest, "\t"))
		f.close()
	if got.thumb != null:
		var t := FileAccess.open(dir + "thumb.png", FileAccess.WRITE)
		if t != null:
			t.store_buffer(got.thumb)
			t.close()
	return {"ok": true, "id": r.id, "rev": r.rev, "hash": got.hash, "dir": dir}


## The package's content hash as kept beside an imported part ("" for a part made here).
static func hash_of(dir: String) -> String:
	var t := FileAccess.get_file_as_string(dir + "package.json")
	var d = JSON.parse_string(t) if t != "" else null
	return String(d.get("hash", "")) if d is Dictionary else ""


## Open and check a package without writing anything: {ok, record, mesh, manifest, hash,
## thumb} or {ok: false, why}.
static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "why": "no file %s" % path}
	var size := FileAccess.get_file_as_bytes(path).size()
	if size > MAX_PACKAGE:
		return {"ok": false, "why": "too big: %d bytes, %d at most" % [size, MAX_PACKAGE]}
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"ok": false, "why": "not a package (not a zip)"}
	var bytes := {}
	for f in zip.get_files():
		if not f in FILES:
			zip.close()
			return {"ok": false, "why": "it holds '%s', which a package may not" % f}
		var b := zip.read_file(f)
		if b.size() > MAX_FILE:
			zip.close()
			return {"ok": false, "why": "%s too big" % f}
		bytes[f] = b
	zip.close()
	for f in REQUIRED:
		if not bytes.has(f):
			return {"ok": false, "why": "no %s" % f}
	var manifest = JSON.parse_string((bytes["manifest.json"] as PackedByteArray).get_string_from_utf8())
	if not manifest is Dictionary or int(manifest.get("format", 0)) != FORMAT:
		return {"ok": false, "why": "not a package this game reads (format)"}
	var hashes: Dictionary = manifest.get("files", {})
	for f: String in bytes:
		if f == "manifest.json":
			continue
		if String(hashes.get(f, "")) != _sha(bytes[f]):
			return {"ok": false, "why": "%s does not match its hash" % f}
	var h := content_hash(hashes)
	if h != String(manifest.get("hash", "")):
		return {"ok": false, "why": "the content hash does not match"}
	var d = JSON.parse_string((bytes["part.json"] as PackedByteArray).get_string_from_utf8())
	if not d is Dictionary:
		return {"ok": false, "why": "part.json is not a record"}
	var r := PartRecord.from_dict(d)
	r.source = "custom"   # a package never makes itself official
	var bad := r.problems()
	if not bad.is_empty():
		return {"ok": false, "why": "its record: " + "; ".join(bad)}
	if r.id != String(manifest.get("id", "")) or not r.id.validate_filename() == r.id:
		return {"ok": false, "why": "its id '%s' is not one a folder can have" % r.id}
	var mesh = JSON.parse_string((bytes["mesh.json"] as PackedByteArray).get_string_from_utf8())
	var why := check_mesh(mesh)
	if why != "":
		return {"ok": false, "why": "its nodes: " + why}
	var thumb: Variant = null
	if bytes.has("thumb.png"):
		var img := Image.new()
		if img.load_png_from_buffer(bytes["thumb.png"]) != OK:
			return {"ok": false, "why": "thumb.png is not a picture"}
		thumb = bytes["thumb.png"]
	return {"ok": true, "record": r, "mesh": mesh, "manifest": manifest, "hash": h, "thumb": thumb}


## What is wrong with a mesh.json ("" for nothing): node types, parents, places, every
## array of the kind and length it must be, every index in range, multimesh buffers whole.
static func check_mesh(mesh: Variant) -> String:
	if not mesh is Dictionary:
		return "not a record"
	var nodes = mesh.get("nodes")
	var meshes = mesh.get("meshes", [])
	if not nodes is Array or not meshes is Array or (nodes as Array).is_empty():
		return "no nodes"
	if (nodes as Array).size() > MAX_NODES:
		return "more than %d nodes" % MAX_NODES
	var verts := 0
	for mi in (meshes as Array).size():
		var m = meshes[mi]
		if not m is Dictionary or not m.get("surfaces") is Array:
			return "mesh %d is not one" % mi
		for s in m.surfaces:
			if not s is Dictionary or not s.get("arrays") is Dictionary:
				return "mesh %d: a surface that is not one" % mi
			var arrs: Dictionary = s.arrays
			for k in arrs:
				# No bones or weights: a part is rigid, and nothing here skins it.
				if not str(k).is_valid_int() or not int(k) in ALLOWED_ARRAYS or not _valid_enc(arrs[k]):
					return "mesh %d: array %s" % [mi, k]
			var v = _dec(arrs.get(str(Mesh.ARRAY_VERTEX)))
			if not v is PackedVector3Array:
				return "mesh %d: no vertices" % mi
			var n := (v as PackedVector3Array).size()
			verts += n
			for k in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
				var a = _dec(arrs.get(str(k)))
				if a != null and a.size() != n:
					return "mesh %d: array %d is %d long, the vertices %d" % [mi, k, a.size(), n]
			var tan = _dec(arrs.get(str(Mesh.ARRAY_TANGENT)))
			if tan != null and tan.size() != n * 4:
				return "mesh %d: tangents" % mi
			for k in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
				var c = _dec(arrs.get(str(k)))
				if c != null and (n == 0 or c.size() % n != 0 or c.size() / n > 4 * 4):
					return "mesh %d: custom array %d" % [mi, k]
			var idx = _dec(arrs.get(str(Mesh.ARRAY_INDEX)))
			if idx != null:
				if not idx is PackedInt32Array:
					return "mesh %d: indices not whole numbers" % mi
				for i in idx:
					if i < 0 or i >= n:
						return "mesh %d: an index out of range" % mi
			if int(s.get("primitive", 3)) < 0 or int(s.get("primitive", 3)) > Mesh.PRIMITIVE_TRIANGLE_STRIP:
				return "mesh %d: primitive" % mi
	if verts > MAX_VERTICES:
		return "%d vertices, %d at most" % [verts, MAX_VERTICES]
	for i in (nodes as Array).size():
		var d = nodes[i]
		if not d is Dictionary:
			return "node %d is not one" % i
		if not String(d.get("type", "")) in NODE_TYPES:
			return "node %d is a %s" % [i, d.get("type", "?")]
		var p := int(d.get("parent", -2))
		if (i == 0 and p != -1) or (i > 0 and (p < 0 or p >= i)):
			return "node %d: its parent" % i
		var xf = d.get("xf")
		if not xf is Array or (xf as Array).size() != 12 or not (xf as Array).all(func(x) -> bool:
				return (x is float or x is int) and is_finite(float(x))):
			return "node %d: its place" % i
		if String(d.get("name", "")).validate_node_name() != String(d.get("name", "")) or String(d.get("name", "")) == "":
			return "node %d: its name" % i
		if d.has("mesh") and (int(d.mesh) < 0 or int(d.mesh) >= (meshes as Array).size()):
			return "node %d: its mesh" % i
		if d.has("multimesh"):
			var mm = d.multimesh
			if not mm is Dictionary:
				return "node %d: its multimesh" % i
			var buf = _dec(mm.get("buffer"))
			var stride := 12 + (4 if mm.get("colors", false) else 0) + (4 if mm.get("custom", false) else 0)
			var count := int(mm.get("count", 0))
			if not buf is PackedFloat32Array or count < 0 or count > MAX_VERTICES \
					or (buf as PackedFloat32Array).size() != count * stride:
				return "node %d: its multimesh buffer" % i
			if int(mm.get("mesh", -1)) >= (meshes as Array).size():
				return "node %d: its multimesh's mesh" % i
	return ""


## The nodes of a checked mesh.json, built here: the only way a package's part is ever shown.
static func build(mesh: Dictionary) -> Node3D:
	if check_mesh(mesh) != "":
		return null
	var built_meshes := []
	for m in mesh.get("meshes", []):
		var am := ArrayMesh.new()
		for s in m.surfaces:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			for k in s.arrays:
				arrays[int(k)] = _dec(s.arrays[k])
			am.add_surface_from_arrays(int(s.get("primitive", Mesh.PRIMITIVE_TRIANGLES)), arrays, [], {},
					int(s.get("format", 0)) & _custom_format_mask())
			var mat := _material(s.get("material", {}))
			if mat != null:
				am.surface_set_material(am.get_surface_count() - 1, mat)
		built_meshes.append(am)
	var out: Array[Node3D] = []
	for d in mesh.nodes:
		var n: Node3D
		match String(d.type):
			"MeshInstance3D":
				var mi := MeshInstance3D.new()
				if d.has("mesh"):
					mi.mesh = built_meshes[int(d.mesh)]
				mi.material_override = _material(d.get("material", {}))
				if d.has("geo_bevel"):
					mi.set_instance_shader_parameter("geo_bevel", float(d.geo_bevel))
				n = mi
			"MultiMeshInstance3D":
				var mmi := MultiMeshInstance3D.new()
				if d.has("multimesh"):
					var mm := MultiMesh.new()
					mm.transform_format = MultiMesh.TRANSFORM_3D
					mm.use_colors = bool(d.multimesh.get("colors", false))
					mm.use_custom_data = bool(d.multimesh.get("custom", false))
					if int(d.multimesh.get("mesh", -1)) >= 0:
						mm.mesh = built_meshes[int(d.multimesh.mesh)]
					mm.instance_count = int(d.multimesh.count)
					if mm.instance_count > 0:
						mm.buffer = _dec(d.multimesh.buffer)
						mmi.set_meta(&"buffer", _dec(d.multimesh.buffer))
					mmi.multimesh = mm
				mmi.material_override = _material(d.get("material", {}))
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				n = mmi
			_:
				n = Node3D.new()
		n.name = String(d.name)
		n.transform = _list_xf(d.xf)
		if int(d.parent) >= 0:
			out[int(d.parent)].add_child(n)
		out.append(n)
	return out[0]


static func _material(d: Dictionary) -> Material:
	match String(d.get("role", "none")):
		"brick":
			var sm := ShaderMaterial.new()
			sm.shader = load(BRICK_SHADER)
			return BrickMaterials.add_glass(sm)
		"stud":
			return load("res://scripts/workshop.gd")._stud_material()
		"plain":
			var s := StandardMaterial3D.new()
			var a: Array = d.get("albedo", [0.6, 0.6, 0.6, 1.0])
			if a.size() == 4:
				s.albedo_color = Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
			s.roughness = clampf(float(d.get("roughness", 0.8)), 0.0, 1.0)
			s.metallic = clampf(float(d.get("metallic", 0.0)), 0.0, 1.0)
			s.vertex_color_use_as_albedo = bool(d.get("vertex_color", false))
			return s
	return null


static func _custom_format_mask() -> int:
	var mask := 0
	for k in 4:
		mask |= Mesh.ARRAY_FORMAT_CUSTOM_MASK << (Mesh.ARRAY_FORMAT_CUSTOM_BASE + k * Mesh.ARRAY_FORMAT_CUSTOM_BITS)
	return mask


# --- small things -------------------------------------------------------------------

static func _enc(a: Variant) -> Dictionary:
	if a is PackedVector3Array:
		return {"k": "v3", "b": Marshalls.raw_to_base64((a as PackedVector3Array).to_byte_array())}
	if a is PackedVector2Array:
		return {"k": "v2", "b": Marshalls.raw_to_base64((a as PackedVector2Array).to_byte_array())}
	if a is PackedColorArray:
		return {"k": "c", "b": Marshalls.raw_to_base64((a as PackedColorArray).to_byte_array())}
	if a is PackedFloat32Array:
		return {"k": "f32", "b": Marshalls.raw_to_base64((a as PackedFloat32Array).to_byte_array())}
	if a is PackedInt32Array:
		return {"k": "i32", "b": Marshalls.raw_to_base64((a as PackedInt32Array).to_byte_array())}
	if a is PackedByteArray:
		return {"k": "u8", "b": Marshalls.raw_to_base64(a)}
	if a is PackedFloat64Array:
		return {"k": "f32", "b": Marshalls.raw_to_base64(PackedFloat32Array(a).to_byte_array())}
	return {"k": "u8", "b": ""}


static func _valid_enc(e: Variant) -> bool:
	return e is Dictionary and String(e.get("k", "")) in KINDS and e.get("b") is String


static func _dec(e: Variant) -> Variant:
	if not _valid_enc(e):
		return null
	var raw := Marshalls.base64_to_raw(String(e.b))
	match String(e.k):
		"v3":
			return _to_v3(raw.to_float32_array())
		"v2":
			return _to_v2(raw.to_float32_array())
		"c":
			return _to_c(raw.to_float32_array())
		"f32":
			return raw.to_float32_array()
		"i32":
			return raw.to_int32_array()
	return raw


static func _to_v3(f: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(f.size() / 3)
	for i in out.size():
		out[i] = Vector3(f[i * 3], f[i * 3 + 1], f[i * 3 + 2])
	return out


static func _to_v2(f: PackedFloat32Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(f.size() / 2)
	for i in out.size():
		out[i] = Vector2(f[i * 2], f[i * 2 + 1])
	return out


static func _to_c(f: PackedFloat32Array) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(f.size() / 4)
	for i in out.size():
		out[i] = Color(f[i * 4], f[i * 4 + 1], f[i * 4 + 2], f[i * 4 + 3])
	return out


static func _xf_list(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z]


static func _list_xf(a: Array) -> Transform3D:
	var f := a.map(func(x) -> float: return float(x))
	return Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]), Vector3(f[6], f[7], f[8])),
			Vector3(f[9], f[10], f[11]))


static func _canon(d: Dictionary) -> PackedByteArray:
	return JSON.stringify(d, "", true).to_utf8_buffer()


static func _sha(b: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(b)
	return h.finish().hex_encode()


static func _own(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_own(c, root)
