class_name ImpostorLod
extends Node3D

## Many copies of one small thing -- a tree, an item, a gun on the ground --
## drawn in two draw calls however many there are (Docs/Impostors.md 3.3, 8).
##
##   near  the real mesh, instanced (one MultiMesh);
##   far   an octahedral impostor card (ImpostorBaker), instanced;
##   past `cull_range`, nothing.
##
## Each instance has a transform and a "wanted" flag its owner sets -- a tree
## that has been shot is drawn by its own bricks, not by this. `update` sorts
## the wanted ones into near and far by distance and repacks both MultiMeshes
## ONLY when something moved between them; a hidden instance is not in either
## buffer, so it costs nothing on the GPU.
##
## The bake is asynchronous and needs a renderer. Until it lands (or with no
## renderer at all) the far tier draws the real mesh, so nothing is missing.

var near_range := 40.0
var cull_range := 3000.0
var hysteresis := 5.0

var mesh: Mesh
var material: Material
var bake := {}

var _near: MultiMeshInstance3D
var _far: MultiMeshInstance3D
var _xf: Array[Transform3D] = []
var _want := PackedByteArray()
var _tier := PackedByteArray()     ## 0 hidden, 1 near, 2 far
var _dirty := true
var _free: Array[int] = []
var _tile := 128
var near_count := 0
var far_count := 0


## `far_shadows` off for small things: a card a few pixels across throws a
## shadow nobody can see, and the cascades draw it again for each (7.2).
func setup(p_mesh: Mesh, p_material: Material, p_near_range: float = 40.0,
		p_cull_range: float = 3000.0, far_shadows: bool = true, tile: int = 128) -> void:
	mesh = p_mesh
	material = p_material
	near_range = p_near_range
	cull_range = p_cull_range
	_tile = tile
	_near = _make_mmi(mesh, material)
	_far = _make_mmi(mesh, material)
	if not far_shadows:
		_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_near)
	add_child(_far)
	_bake_later()


func _bake_later() -> void:
	# A frame first, so the host is in the tree.
	await get_tree().process_frame
	var got: Dictionary = await ImpostorBaker.bake(self, mesh, ImpostorBaker.GRID, _tile)
	if got.is_empty() or not is_instance_valid(self):
		return
	bake = got
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/impostor.gdshader")
	mat.set_shader_parameter("albedo_atlas", got.albedo)
	mat.set_shader_parameter("normal_atlas", got.normal)
	mat.set_shader_parameter("grid", float(got.grid))
	mat.set_shader_parameter("radius", float(got.radius))
	mat.set_shader_parameter("centre", got.centre)
	_far.multimesh.mesh = quad
	_far.material_override = mat
	# A card is built in the shader, round each object's centre, so the
	# quad's own bounds say nothing about where it draws. Two triangles a
	# card: never culling them costs less than working out where they are.
	_far.custom_aabb = AABB(Vector3(-50000, -5000, -50000), Vector3(100000, 10000, 100000))
	_dirty = true


static func _make_mmi(m: Mesh, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = m
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	return mmi


## A new copy. Returns its handle, which stays its own until `remove`.
func add(xf: Transform3D, wanted: bool = true) -> int:
	_dirty = true
	if not _free.is_empty():
		var h: int = _free.pop_back()
		_xf[h] = xf
		_want[h] = 1 if wanted else 0
		_tier[h] = 0
		return h
	_xf.append(xf)
	_want.append(1 if wanted else 0)
	_tier.append(0)
	return _xf.size() - 1


## Moved (an item kicked across the floor). Repacks only if it is drawn.
func move(handle: int, xf: Transform3D) -> void:
	if handle < 0 or handle >= _xf.size():
		return
	_xf[handle] = xf
	if _tier[handle] != 0:
		_dirty = true


## Gone for good (picked up, destroyed). Its handle is reused.
func remove(handle: int) -> void:
	if handle < 0 or handle >= _xf.size() or _free.has(handle):
		return
	_want[handle] = 0
	_free.append(handle)
	_dirty = true


func count() -> int:
	return _xf.size() - _free.size()


func set_wanted(handle: int, on: bool) -> void:
	if handle < 0 or handle >= _want.size():
		return
	var v := 1 if on else 0
	if _want[handle] != v:
		_want[handle] = v
		_dirty = true


func is_drawn(handle: int) -> bool:
	return handle >= 0 and handle < _tier.size() and _tier[handle] != 0


func tier_of(handle: int) -> int:
	return _tier[handle] if handle >= 0 and handle < _tier.size() else 0


## Sort into tiers from `here`, and repack if anything changed tier.
func update(here: Vector3) -> void:
	var changed := _dirty
	_dirty = false
	for i in _xf.size():
		var t := 0
		if _want[i] != 0:
			var d := _xf[i].origin.distance_to(here)
			if d > cull_range:
				t = 0
			elif _tier[i] == 1:
				t = 1 if d < near_range + hysteresis else 2
			else:
				t = 1 if d < near_range - hysteresis else 2
		if t != _tier[i]:
			_tier[i] = t
			changed = true
	if changed:
		_repack()


func _repack() -> void:
	var near := PackedFloat32Array()
	var far := PackedFloat32Array()
	for i in _xf.size():
		if _tier[i] == 0:
			continue
		var x := _xf[i]
		var row := PackedFloat32Array([x.basis.x.x, x.basis.y.x, x.basis.z.x, x.origin.x,
				x.basis.x.y, x.basis.y.y, x.basis.z.y, x.origin.y,
				x.basis.x.z, x.basis.y.z, x.basis.z.z, x.origin.z])
		if _tier[i] == 1:
			near.append_array(row)
		else:
			far.append_array(row)
	near_count = near.size() / 12
	far_count = far.size() / 12
	_fill(_near.multimesh, near, near_count)
	_fill(_far.multimesh, far, far_count)


static func _fill(mm: MultiMesh, buf: PackedFloat32Array, n: int) -> void:
	if mm.instance_count < n or mm.instance_count > n * 4 + 64:
		mm.instance_count = maxi(n * 2, 16)
	var full := buf
	full.resize(mm.instance_count * 12)
	mm.buffer = full
	mm.visible_instance_count = n
