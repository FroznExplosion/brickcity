extends Node

## Stand-ins: a piece whose mesh is still being made is drawn as a box per brick
## (Docs/DestructionFirstPrinciples.md B10).
##
## A big piece's mesh is baked on a worker and comes up a tick or a few later;
## until it does the piece drew nothing (IslandManager.is_blind) -- up to four
## ticks for a 2,671-brick piece in barrage_probe, a pop in play. Now each block
## is a box of its size, in the piece's own brick material, coloured as its mesh
## will be (BrickWorld.get_standin_buffers: material and grain in the colour's
## alpha, as the mesher writes them), until the mesh is up.
##
## Why it is cheap: no bake and no per-brick script work -- C++ hands one ready
## MultiMesh buffer per brick size. A box is 12 triangles, so 2,671 bricks are
## 32,000 for a tick or two. No studs and no bevel: a piece is new and moving
## while it stands in, and the near tier draws a moving piece flat anyway
## (BrickNear.SETTLE_MS).
##
## Why it does not jump: the boxes are children of the piece's own mesh node, so
## they move with its interpolated transform, and they go the frame the mesh has
## something to draw.
##
## A part of the island manager (IslandManager.standins), reading it through
## `host`, as island_crumbs.gd does.

const Host := preload("res://scripts/island_manager.gd")

var host: Host
## Off: pieces are blind while their mesh is made, as before (for an A/B).
var enabled := true

var built := 0          ## stand-ins made (a piece's again when it lost bricks)
var frames_drawn := 0   ## frames a stand-in drew a piece that had nothing else
var build_ms := 0.0     ## making them, all told
var build_worst := 0.0  ## the slowest one
var bricks_worst := 0   ## the most bricks one stood in for

## BrickIsland -> [holder Node3D, live bricks when it was made]
var _by_isl := {}
## Box size -> ArrayMesh, shared.
static var _boxes := {}


func _init(h: Host) -> void:
	host = h
	name = "IslandStandins"


## Once a frame (IslandManager._process): the pieces waiting on a mesh, and the
## ones already stood in for.
func update() -> void:
	if not enabled:
		if not _by_isl.is_empty():
			for isl in _by_isl.keys():
				_drop(isl)
		return
	if host._mesh_queue.is_empty() and _by_isl.is_empty():
		return
	var seen := {}
	for isl in host._mesh_queue:
		seen[isl] = true
		_consider(isl)
	for isl in _by_isl.keys():
		if not seen.has(isl):
			_consider(isl)


func _consider(isl: BrickIsland) -> void:
	if not is_instance_valid(isl) or not isl.is_valid() or isl.mesh == null \
			or not is_instance_valid(isl.mesh):
		_drop(isl)
		return
	if not host.is_blind(isl):
		_drop(isl)
		return
	var alive := host.world.get_alive_block_count(isl.chunk)
	if alive == 0:
		_drop(isl)
		return
	var had: Array = _by_isl.get(isl, [])
	if had.is_empty() or int(had[1]) != alive or not is_instance_valid(had[0]):
		_drop(isl)
		_build(isl, alive)
	frames_drawn += 1


func _build(isl: BrickIsland, alive: int) -> void:
	if not host.world.has_method(&"get_standin_buffers"):
		return   # a library from before stand-ins: blind, as before
	var t0 := Time.get_ticks_usec()
	var buffers: Dictionary = host.world.call(&"get_standin_buffers", isl.chunk)
	var holder := Node3D.new()
	holder.name = "StandIn"
	for size in buffers:
		var buf: PackedFloat32Array = buffers[size]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _box(size)
		mm.instance_count = buf.size() / 16
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = isl.mesh.material_override
		holder.add_child(mmi)
	isl.mesh.add_child(holder)
	_by_isl[isl] = [holder, alive]
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	built += 1
	build_ms += ms
	build_worst = maxf(build_worst, ms)
	bricks_worst = maxi(bricks_worst, alive)


func _drop(isl) -> void:
	var had: Array = _by_isl.get(isl, [])
	if not had.is_empty() and is_instance_valid(had[0]):
		(had[0] as Node).queue_free()
	_by_isl.erase(isl)


func census_line() -> String:
	return "stand-ins: %d made (%.1f ms, worst %.2f, most %d bricks), drew %d frame(s) a piece had nothing else" % [
			built, build_ms, build_worst, bricks_worst, frames_drawn]


## A box of `size` metres, centred, as the brick mesher writes a face: UV the
## point's place in its face rectangle and UV2 that rectangle's size, both in
## metres (brick.gdshader draws its seams from them), white vertex colour for
## the instance colour to tint.
static func _box(size: Vector3) -> ArrayMesh:
	if _boxes.has(size):
		return _boxes[size]
	var h := size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var cols := PackedColorArray()
	# Each face: normal, the two in-plane axes (u, v), their lengths.
	var faces := [
		[Vector3.RIGHT, Vector3.BACK, Vector3.UP, size.z, size.y],
		[Vector3.LEFT, Vector3.FORWARD, Vector3.UP, size.z, size.y],
		[Vector3.UP, Vector3.RIGHT, Vector3.BACK, size.x, size.z],
		[Vector3.DOWN, Vector3.RIGHT, Vector3.FORWARD, size.x, size.z],
		[Vector3.BACK, Vector3.LEFT, Vector3.UP, size.x, size.y],
		[Vector3.FORWARD, Vector3.RIGHT, Vector3.UP, size.x, size.y],
	]
	for f in faces:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var lu: float = f[3]
		var lv: float = f[4]
		var centre := n * h
		var corners := [Vector2(0, 0), Vector2(lu, 0), Vector2(lu, lv), Vector2(0, lv)]
		var pts := []
		for c in corners:
			pts.append(centre + u * (c.x - lu * 0.5) + v * (c.y - lv * 0.5))
		# Two triangles, wound so the face points along n: clockwise seen from
		# outside (Godot's front face). Going 0-2-1 faces along u x v.
		var order := [0, 2, 1, 0, 3, 2] if u.cross(v).dot(n) > 0.0 else [0, 1, 2, 0, 2, 3]
		for k in order:
			verts.append(pts[k])
			norms.append(n)
			uvs.append(corners[k])
			uv2s.append(Vector2(lu, lv))
			cols.append(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_boxes[size] = mesh
	return mesh
