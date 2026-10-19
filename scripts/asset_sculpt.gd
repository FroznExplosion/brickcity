class_name AssetSculpt
extends Node3D

## The asset workshop's SDF block-out in the scene (Docs/AssetWorkshop.md, "The SDF
## block-out"): the field (`SdfForm`, gdextension/brick/src/sdf_form.cpp), its surface
## a mesh a block, and the brush under the cursor. Its own transform maps samples (ticks)
## to the workshop: the upright grid's transform, scaled a tick.

var form := SdfForm.new()
## A colour a part label (0: none).
var palette := PackedColorArray([Color(0.8, 0.8, 0.8)])
var _meshes := {}   # Vector3i block -> MeshInstance3D
var _mat := StandardMaterial3D.new()
var _cursor := MeshInstance3D.new()
var _cursor_mat := StandardMaterial3D.new()
## The plane a stroke will stay on, as a disc round the brush.
var _disc := MeshInstance3D.new()
## A stamp being dragged out.
var _ghost := MeshInstance3D.new()
var _ghost_mat := StandardMaterial3D.new()


func _init() -> void:
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.55
	_cursor.mesh = SphereMesh.new()
	(_cursor.mesh as SphereMesh).radius = 1.0
	(_cursor.mesh as SphereMesh).height = 2.0
	_cursor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cursor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cursor_mat.no_depth_test = true
	_cursor.material_override = _cursor_mat
	_cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cursor.visible = false
	add_child(_cursor)
	var dm := CylinderMesh.new()
	dm.top_radius = 1.0
	dm.bottom_radius = 1.0
	dm.height = 0.02
	dm.radial_segments = 48
	dm.rings = 1
	_disc.mesh = dm
	var disc_mat := StandardMaterial3D.new()
	disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	disc_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.12)
	_disc.material_override = disc_mat
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_disc.visible = false
	add_child(_disc)
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost.material_override = _ghost_mat
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.visible = false
	add_child(_ghost)


## Samples on the grid `grid` (the upright chunk's transform), `tick` metres a sample.
func place(grid: Transform3D, tick: float) -> void:
	transform = grid * Transform3D(Basis.from_scale(Vector3.ONE * tick), Vector3.ZERO)


## A colour for each part (labels are part index + 1).
func set_parts(count: int) -> void:
	palette = PackedColorArray([Color(0.8, 0.8, 0.8)])
	for i in count:
		palette.append(Color.from_hsv(fmod(0.08 + i * 0.618034, 1.0), 0.45, 0.92))
	remesh_all()


func to_sample(p: Vector3) -> Vector3:
	return global_transform.affine_inverse() * p


func to_world(s: Vector3) -> Vector3:
	return global_transform * s


## A ray of the workshop as a ray of samples: [from, dir], dir unit.
func ray_to_samples(from: Vector3, dir: Vector3) -> Array:
	var inv := global_transform.affine_inverse()
	var a := inv * from
	var b := inv * (from + dir)
	return [a, (b - a).normalized()]


## The surface where a workshop ray first meets it, in samples, or null.
func hit(from: Vector3, dir: Vector3) -> Variant:
	var r := ray_to_samples(from, dir)
	return form.raycast(r[0], r[1], 20000.0)


## Re-mesh the blocks that changed.
func remesh() -> void:
	for b in form.take_dirty():
		_mesh(b)


func remesh_all() -> void:
	for b in _meshes:
		(_meshes[b] as Node).queue_free()
	_meshes.clear()
	form.take_dirty()
	for b in form.block_keys():
		_mesh(b)


func _mesh(b: Vector3i) -> void:
	var arrays: Array = form.mesh_block(b, palette)
	var mi: MeshInstance3D = _meshes.get(b)
	if arrays.is_empty():
		if mi != null:
			mi.queue_free()
			_meshes.erase(b)
		return
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _mat
		add_child(mi)
		_meshes[b] = mi
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = m


## The brush: a ball `radius` samples round `at`, coloured by what it does; with a
## `normal`, a disc of the plane its stroke stays on.
func show_cursor(at: Variant, radius: float, col: Color, normal: Vector3 = Vector3.ZERO) -> void:
	_cursor.visible = at != null
	_disc.visible = at != null and normal != Vector3.ZERO
	if at == null:
		return
	_cursor.position = at
	_cursor.scale = Vector3.ONE * maxf(radius, 0.3)
	col.a = 0.25
	_cursor_mat.albedo_color = col
	if _disc.visible:
		var up := normal.normalized()
		var side := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
		var r := maxf(radius, 0.3) * 4.0
		_disc.transform = Transform3D(Basis(side * r, up, side.cross(up) * r), at)


## A stamp's ghost (`AssetWorkshop._stamp_desc`, samples); empty hides it.
func show_ghost(d: Dictionary, col: Color = Color.WHITE) -> void:
	_ghost.visible = not d.is_empty()
	if d.is_empty():
		return
	col.a = 0.35
	_ghost_mat.albedo_color = col
	match String(d.kind):
		"box":
			var m := BoxMesh.new()
			m.size = d.half * 2.0
			_ghost.mesh = m
			_ghost.transform = Transform3D(Basis(), d.center)
		"cone":
			var m := CylinderMesh.new()
			m.bottom_radius = d.size.x
			m.top_radius = d.size.z
			m.height = d.size.y * 2.0
			_ghost.mesh = m
			_ghost.transform = d.xform
		_:
			var a: Vector3 = d.a
			var b: Vector3 = d.b
			var r: float = d.r
			var m := CapsuleMesh.new()
			m.radius = r
			m.height = a.distance_to(b) + 2.0 * r
			_ghost.mesh = m
			var y := (b - a).normalized() if a.distance_to(b) > 0.01 else Vector3.UP
			var x := y.cross(Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).normalized()
			_ghost.transform = Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5)


func triangles() -> int:
	var n := 0
	for b in _meshes:
		var m: ArrayMesh = (_meshes[b] as MeshInstance3D).mesh
		n += m.surface_get_array_index_len(0) / 3
	return n


## Saved with the asset: the field, compressed, as text.
func save_meta() -> Dictionary:
	var raw := form.to_bytes()
	return {"size": raw.size(), "data": Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_ZSTD))}


func load_meta(m: Variant) -> void:
	form.clear()
	if m is Dictionary and m.has("data"):
		var raw := Marshalls.base64_to_raw(String(m.data)).decompress(int(m.size), FileAccess.COMPRESSION_ZSTD)
		if not form.from_bytes(raw):
			push_warning("asset workshop: the saved block-out could not be read")
	remesh_all()
