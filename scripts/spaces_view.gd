class_name SpacesView
extends Node3D

## The rooms of a generated building, drawn over it (Docs/Structures.md 3.3):
## what StructureSpaces.for_tower finds in its bricks, the way the workshop's
## spaces tool draws a build's. In the city, Shift+O.
##
##   * each room outlined at its floor and its ceiling -- cyan when it is
##     sealed (walls all round, every gap in them a doorway, door, window or
##     glass), RED when a side of it is open: the finder walked out of it
##     through a floor or ceiling that is not there;
##   * its kind written over it, and "OPEN" when it is not sealed;
##   * every opening boxed in its kind's colour (WorkshopSpaces.COLOURS):
##     doorway green, window blue, glass pale blue, door dark green, open red;
##   * the stairwell boxed orange, storey by storey: solid to the finder, so a
##     room beside it is sealed by it.
##
## A room the finder could not find from its middle at all is not drawn; the
## line under it in report() counts them.

const SEALED := Color(0.35, 0.9, 1.0)
const LEAKS := Color(1.0, 0.25, 0.25)
const STAIR := Color(1.0, 0.6, 0.15)

var _mesh := MeshInstance3D.new()
var _labels: Array[Label3D] = []
## What the last show() found: rooms in the manifest, found, sealed, and the
## openings by kind.
var rooms := 0
var found := 0
var sealed := 0
var openings := {}
var ms := 0.0


func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 10
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)


func clear() -> void:
	for l in _labels:
		l.queue_free()
	_labels.clear()
	_mesh.mesh = null
	rooms = 0
	found = 0
	sealed = 0
	openings = {}


## Find and draw the rooms of building `b`, whose bricks are in `world`.
func show_building(world: BrickWorld, b: BuildingRegistry.Building, room_seed: int) -> void:
	clear()
	if b == null or not b.is_materialised() or b.is_build():
		return
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var program: Dictionary = b.recipe.get("program", {})
	var t0 := Time.get_ticks_usec()
	var rec := StructureSpaces.for_tower(world, b.chunk, fx, fz, courses, room_seed, program)
	ms = float(Time.get_ticks_usec() - t0) / 1000.0
	rooms = RoomManifest.rooms_for(fx, fz, courses, room_seed, program).size()
	found = (rec.spaces as Array).size()
	var origin := world.get_chunk_origin(b.chunk)
	var open_of := {}   # space id -> open sides
	for o: Dictionary in rec.openings:
		openings[o.kind] = int(openings.get(o.kind, 0)) + 1
		if String(o.kind) == "open":
			open_of[int(o.space)] = int(open_of.get(int(o.space), 0)) + 1

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for s: Dictionary in rec.spaces:
		var leaks := open_of.has(int(s.id))
		if not leaks:
			sealed += 1
		var col := LEAKS if leaks else SEALED
		var cols := {}
		for c in s.columns:
			cols[Vector2i(int(c[0]), int(c[1]))] = true
		var y0 := int(s.floor_y) + 1
		var y1 := int(s.ceil_y)
		var sum := Vector2.ZERO
		for c: Vector2i in cols:
			sum += Vector2(c)
			for side in [[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1)],
					[Vector2i(1, 0), Vector2i(1, 0), Vector2i(1, 1)],
					[Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, 0)],
					[Vector2i(0, 1), Vector2i(0, 1), Vector2i(1, 1)]]:
				if cols.has(c + (side[0] as Vector2i)):
					continue
				var a: Vector2i = c + (side[1] as Vector2i)
				var e: Vector2i = c + (side[2] as Vector2i)
				for y in [y0, y1]:
					_line(im, Vector3i(a.x, y, a.y) - origin, Vector3i(e.x, y, e.y) - origin, col)
		if cols.is_empty():
			continue
		var mid := sum / float(cols.size())
		var l := Label3D.new()
		l.text = String(s.kind) + ("  OPEN x%d" % int(open_of[int(s.id)]) if leaks else "")
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.pixel_size = 0.006
		l.modulate = col
		l.position = BrickWorld.grid_to_world(Vector3i(int(mid.x), int((y0 + y1) * 0.5), int(mid.y))
				- origin) + Vector3(BrickPalette.STUD_M, 0.0, BrickPalette.STUD_M) * 0.5
		_mesh.add_child(l)
		_labels.append(l)
	for o: Dictionary in rec.openings:
		var lo := Vector3i(1000000000, 1000000000, 1000000000)
		var hi := -lo
		for c in o.cells:
			var v := Vector3i(int(c[0]), int(c[1]), int(c[2])) - origin
			lo = Vector3i(mini(lo.x, v.x), mini(lo.y, v.y), mini(lo.z, v.z))
			hi = Vector3i(maxi(hi.x, v.x), maxi(hi.y, v.y), maxi(hi.z, v.z))
		_box(im, BrickWorld.grid_to_world(lo), BrickWorld.grid_to_world(hi + Vector3i.ONE),
				WorkshopSpaces.COLOURS.get(String(o.kind), Color.WHITE))
	# The stairwell, a box a storey.
	var stair := TowerRecipe.stair_rect(fx, fz)
	if stair.size != Vector2i.ZERO:
		for st: Dictionary in RoomManifest.storeys_of(courses):
			var a := Vector3i(stair.position.x, int(st.floor_y), stair.position.y)
			var e := Vector3i(stair.end.x, int(st.floor_y) + int(st.height), stair.end.y)
			_box(im, BrickWorld.grid_to_world(a), BrickWorld.grid_to_world(e), STAIR)
	im.surface_end()
	_mesh.mesh = im
	_mesh.global_transform = world.get_chunk_transform(b.chunk)


func report() -> String:
	return "%d room(s): %d found, %d sealed, %d open; openings %s; %.0f ms" % [
			rooms, found, sealed, found - sealed, str(openings), ms]


func _line(im: ImmediateMesh, a: Vector3i, b: Vector3i, col: Color) -> void:
	im.surface_set_color(col)
	im.surface_add_vertex(BrickWorld.grid_to_world(a))
	im.surface_set_color(col)
	im.surface_add_vertex(BrickWorld.grid_to_world(b))


func _box(im: ImmediateMesh, a: Vector3, b: Vector3, col: Color) -> void:
	var c := [Vector3(a.x, a.y, a.z), Vector3(b.x, a.y, a.z), Vector3(b.x, a.y, b.z),
			Vector3(a.x, a.y, b.z), Vector3(a.x, b.y, a.z), Vector3(b.x, b.y, a.z),
			Vector3(b.x, b.y, b.z), Vector3(a.x, b.y, b.z)]
	for pair in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]]:
		im.surface_set_color(col)
		im.surface_add_vertex(c[pair[0]])
		im.surface_set_color(col)
		im.surface_add_vertex(c[pair[1]])
