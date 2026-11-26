class_name MineBuildingsFar
extends Node3D
## THE FAR VIEW OF STAMPED BUILDINGS (Docs/TerrainBuildings.md 7). Past the
## near tiles the ground is the coarse tier: a height per coarse cell, its
## walls the colour of its top -- a tower there was a plain block of its
## roof's colour, its windows and storeys gone. Here each stamped building
## (MineBuildings.registry) gets a FACADE MESH made from its own bricks in the
## field: each wall a grid of studs x courses, coloured by the outermost cell
## within FACE_DEPTH studs of the wall (glass blue, an opening dark), its roof
## the top cell of each column. Drawn a hair outside the building's box, so it
## covers the coarse block (which lies inside the footprint: the coarse cell
## takes the MIN of its corners). Shown only while the building's tile is not
## a near tile; made again when an edit reaches the building (after_edit's
## `far_dirty`), one building a tend, as it is wanted.
##
## Plain vertex-coloured quads, merged along each row where the colour
## agrees: a few hundred quads a tower.

## Studs into a wall a facade looks for its outer brick.
const FACE_DEPTH := 3
## Colour of an opening (nothing within FACE_DEPTH): the dark of a room.
const OPENING := Color(0.13, 0.13, 0.15)
## Metres outside the building's box the facade is drawn (over the coarse
## block's walls).
const OUTSET := 0.03
## Seconds between tends.
const TEND_EVERY := 0.25
## Metres past which no facade is drawn (the far tier's reach is the camera's).
const RANGE_M := 2000.0

var host: Node = null
var _mat: StandardMaterial3D = null
var _tend_in := 0.0
## Facades made (the gate's count).
var built := 0


func setup(p_host: Node) -> void:
	host = p_host
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.85
	_mat.cull_mode = BaseMaterial3D.CULL_BACK


func _process(delta: float) -> void:
	_tend_in -= delta
	if _tend_in > 0.0 or host == null:
		return
	_tend_in = TEND_EVERY
	tend()


## Each building's facade shown or hidden by its tile; one made or made again.
func tend() -> void:
	var made := false
	var tile_m := BrickTerrain.get_tile_studs()
	for b: Dictionary in MineBuildings.registry:
		var node: MeshInstance3D = b.get("far_node")
		if bool(b.fallen):
			if node != null:
				node.queue_free()
				b.erase("far_node")
			continue
		var lo: Vector3i = b.lo
		var hi: Vector3i = b.hi
		var t := Vector2i(floori(float(lo.x + hi.x) * 0.5 / tile_m), floori(float(lo.z + hi.z) * 0.5 / tile_m))
		var far: bool = not bool(host.call("near_tile", t))
		if far and (node == null or bool(b.get("far_dirty", false))) and not made:
			node = _make(b, node)
			made = true
		if node != null:
			node.visible = far
	return


## (Re)make building `b`'s facade mesh into `node` (made when null).
func _make(b: Dictionary, node: MeshInstance3D) -> MeshInstance3D:
	if node == null:
		node = MeshInstance3D.new()
		node.material_override = _mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.visibility_range_end = RANGE_M
		add_child(node)
		b["far_node"] = node
	node.mesh = facade_mesh(b)
	b["far_dirty"] = false
	built += 1
	return node


## The building's facade and roof as one ArrayMesh, in the terrain frame.
static func facade_mesh(b: Dictionary) -> ArrayMesh:
	var lo: Vector3i = b.lo
	var hi: Vector3i = b.hi
	var base := int(b.base)
	var s := BrickWorld.get_stud_metres()
	var p := BrickWorld.get_plate_metres()
	var courses := ceili(float(hi.y - base + 1) / 3.0)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var cols := PackedColorArray()
	# Four walls: (normal, along-axis, the wall's outer coordinate, inward step).
	var walls := [
		[Vector3(0, 0, -1), true, lo.z, 1], [Vector3(0, 0, 1), true, hi.z, -1],
		[Vector3(-1, 0, 0), false, lo.x, 1], [Vector3(1, 0, 0), false, hi.x, -1],
	]
	for w: Array in walls:
		var n: Vector3 = w[0]
		var along_x: bool = w[1]
		var outer := int(w[2])
		var inward := int(w[3])
		var u0 := lo.x if along_x else lo.z
		var u1 := hi.x if along_x else hi.z
		# The wall's top course per u: above it nothing is drawn.
		var grid := []
		for c in courses:
			var row := []
			var y := base + c * 3 + 1
			for u in range(u0, u1 + 1):
				row.append(_face_colour(u, y, outer, inward, along_x))
			grid.append(row)
		var top := []
		for i in u1 - u0 + 1:
			var t := -1
			for c in courses:
				if grid[c][i] != null and grid[c][i] != OPENING:
					t = c
			top.append(t)
		var plane := (float(outer) + (1.0 if inward < 0 else 0.0)) * s + (OUTSET * (-1.0 if inward > 0 else 1.0))
		for c in courses:
			var i := 0
			while i <= u1 - u0:
				if c > int(top[i]) or grid[c][i] == null:
					i += 1
					continue
				var col: Color = grid[c][i]
				var j := i + 1
				while j <= u1 - u0 and c <= int(top[j]) and grid[c][j] != null and grid[c][j] == col:
					j += 1
				var a := float(u0 + i) * s
				var e := float(u0 + j) * s
				var y0 := float(base + c * 3) * p
				var y1 := float(mini(base + c * 3 + 3, hi.y + 1)) * p
				var q := []
				if along_x:
					q = [Vector3(a, y0, plane), Vector3(e, y0, plane), Vector3(e, y1, plane), Vector3(a, y1, plane)]
				else:
					q = [Vector3(plane, y0, a), Vector3(plane, y0, e), Vector3(plane, y1, e), Vector3(plane, y1, a)]
				_quad(verts, normals, cols, q, n, col)
				i = j
	# The roof: each column's top building cell, merged along x.
	for z in range(lo.z, hi.z + 1):
		var x := lo.x
		while x <= hi.x:
			var t := _top_of(x, z, base, hi.y)
			if t[0] < 0:
				x += 1
				continue
			var e := x + 1
			while e <= hi.x:
				var t2 := _top_of(x + (e - x), z, base, hi.y)
				if t2[0] != t[0] or t2[1] != t[1]:
					break
				e += 1
			var y := float(int(t[0]) + 1) * p + OUTSET
			var col: Color = t[1]
			_quad(verts, normals, cols, [Vector3(float(x) * s, y, float(z) * s), Vector3(float(x) * s, y, float(z + 1) * s),
					Vector3(float(e) * s, y, float(z + 1) * s), Vector3(float(e) * s, y, float(z) * s)],
					Vector3.UP, col)
			x = e
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The colour a wall shows at (u, plate y): the first building or glass cell
## within FACE_DEPTH studs in from its outer face; OPENING when none (a
## window or doorway); null when nothing of the building is there at all
## (the whole depth empty and nothing behind it either: past its edge).
static func _face_colour(u: int, y: int, outer: int, inward: int, along_x: bool) -> Variant:
	for d in FACE_DEPTH:
		var w := outer + d * inward
		var m := BrickTerrain.solid_at(u, y, w) if along_x else BrickTerrain.solid_at(w, y, u)
		if MineBuildings.is_building(m):
			return _colour(m)
	return OPENING


## [top plate, colour] of a column's highest building cell, or [-1, null].
static func _top_of(x: int, z: int, y0: int, y1: int) -> Array:
	for y in range(y1, y0 - 1, -1):
		var m := BrickTerrain.solid_at(x, y, z)
		if MineBuildings.is_building(m):
			return [y, _colour(m)]
	return [-1, null]


static var _colours := {}


static func _colour(m: int) -> Color:
	if not _colours.has(m):
		_colours[m] = BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(m))
	return _colours[m]


## Two triangles, wound to face `n` (counter-clockwise seen from outside, as
## Godot's front faces are).
static func _quad(verts: PackedVector3Array, normals: PackedVector3Array, cols: PackedColorArray,
		q: Array, n: Vector3, col: Color) -> void:
	var a: Vector3 = q[0]
	var b: Vector3 = q[1]
	var c: Vector3 = q[2]
	var d: Vector3 = q[3]
	# Godot: clockwise is front. Flip to face n.
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b
		b = d
		d = t
	for v in [a, b, c, a, c, d]:
		verts.append(v)
		normals.append(n)
		cols.append(col)
