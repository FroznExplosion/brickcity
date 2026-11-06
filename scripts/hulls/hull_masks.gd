class_name HullMasks
extends RefCounted
## The hulls' dry cells for the water shaders (Docs/Hulls.md 6): the sea is cut
## out of a floating hull cell by cell (shaders/hull_mask.gdshaderinc). Two slots,
## the two hulls nearest the eye that stand in water; a byte a cell -- 255 for a
## brick or dry inside air, 0 for flooded or outside -- as a 3D texture, with the
## world-to-cell transform and the grid's size as global shader parameters.
##
## The water side also asks `dry_at` (WaterSea / WaterSurface.submerged_at): a
## camera in a dry hold under the sea line is not under water.

## Hulls further than this from the eye are not cut (nothing to see of it).
const REACH := 400.0
## A mask is built again at most this often, seconds (flooding, hits).
const REBUILD := 0.25

static var _slots: Array = [null, null]
static var _tex := {}       ## hull -> ImageTexture3D
static var _built := {}     ## hull -> [ms built, water steps, bricks killed + restored]


## Fill the two slots from `hulls` (SpaceStations: ships, boats) for eye `eye`.
static func update(hulls: Array, eye: Vector3) -> void:
	var near: Array = []
	for h in hulls:
		if h == null or not is_instance_valid(h) or not h.bricked or h.chunk < 0 or h.air == null:
			continue
		if not h.water_depth.is_valid():
			continue
		var d: float = (h.global_position - eye).length()
		if d < REACH:
			near.append([d, h])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for k in 2:
		var h = near[k][1] if k < near.size() else null
		_slots[k] = h
		var suffix := "a" if k == 0 else "b"
		if h == null:
			RenderingServer.global_shader_parameter_set("hull_dims_" + suffix, Vector4.ZERO)
			continue
		RenderingServer.global_shader_parameter_set("hull_mask_" + suffix, _mask(h))
		RenderingServer.global_shader_parameter_set("hull_xf_" + suffix, Projection(world_to_cell(h)))
		var dims: Vector3i = h.air.dims
		RenderingServer.global_shader_parameter_set("hull_dims_" + suffix, Vector4(dims.x, dims.y, dims.z, 1.0))
	# Forget hulls gone.
	for h in _tex.keys():
		if not is_instance_valid(h) or not h.bricked:
			_tex.erase(h)
			_built.erase(h)


## World to its grid's cells (continuous: floor() is the cell).
static func world_to_cell(h) -> Transform3D:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var c2w: Transform3D = h.global_transform * h.frame * Transform3D(Basis.from_scale(Vector3(stud, plate, stud)), Vector3.ZERO)
	return c2w.affine_inverse()


## World point `p` is in a dry cell of a hull in a slot.
static func dry_at(p: Vector3) -> bool:
	for h in _slots:
		if h == null or not is_instance_valid(h):
			continue
		var c := world_to_cell(h) * p
		var dims: Vector3i = h.air.dims
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= dims.x or c.y >= dims.y or c.z >= dims.z:
			continue
		if _dry(h, h.air._idx(Vector3i(c.floor()))):
			return true
	return false


static func _dry(h, i: int) -> bool:
	var s: int = h.air.state[i]
	if s == HullAir.SOLID:
		return true
	if s != HullAir.INSIDE:
		return false
	return h.hull_water == null or h.hull_water.level(i) < 0.5


## Hull `h`'s mask, built again when its water or its bricks changed (at most
## every REBUILD seconds).
static func _mask(h) -> ImageTexture3D:
	var now := Time.get_ticks_msec()
	var sig := [h.hull_water.steps if h.hull_water != null and h.hull_water.changed else -1,
			int(h.bricks_killed) + int(h.bricks_restored)]
	var was: Array = _built.get(h, [])
	var tex: ImageTexture3D = _tex.get(h)
	if tex != null and not was.is_empty() and (now - int(was[0]) < REBUILD * 1000.0
			or (int(sig[0]) < 0 and int(was[2]) == int(sig[1]))):
		return tex
	var dims: Vector3i = h.air.dims
	var slices: Array[Image] = []
	for z in dims.z:
		var bytes := PackedByteArray()
		bytes.resize(dims.x * dims.y)
		for y in dims.y:
			for x in dims.x:
				if _dry(h, x + dims.x * (y + dims.y * z)):
					bytes[x + dims.x * y] = 255
		slices.append(Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_L8, bytes))
	if tex == null:
		tex = ImageTexture3D.new()
		tex.create(Image.FORMAT_L8, dims.x, dims.y, dims.z, false, slices)
		_tex[h] = tex
	else:
		tex.update(slices)
	_built[h] = [now, sig[0], sig[1]]
	return tex
