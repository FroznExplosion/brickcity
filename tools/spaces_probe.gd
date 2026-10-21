extends SceneTree
## Finding a room and its openings (StructureSpaces.find_space; Docs/Structures.md 3.2).
##
##     godot --headless --path . --script res://tools/spaces_probe.gd
##
## Two rooms side by side, built of 1x1 plates: floor, walls nine plates high,
## a ceiling. Between them a doorway; in the first, a window to the outside, a
## pane of glass and a niche that goes into a thick wall and not through it.
##
##   room       a click on the floor finds the room's footprint, floor and ceiling
##   openings   the doorway, the window and the glass, each its kind; not the niche
##   beside     the room next door finds the same doorway
##   outside    a click with no floor under it is no room
##   by hand    an opening's kind set by hand stays when the room is found again
##   generated  a generated building's rooms are all found from its bricks, each of
##              its own kind, with windows out and doorways between them
##   floors     floors found in the bricks (Structures.md 2.4): a generated tower's
##              are the ones its generator laid; a build's are its slabs and its
##              mezzanine, not its walls, a column or an interior plate; and the
##              registry gives a build those as its floor lines

var _w: BrickWorld
var _palette: Dictionary
var _chunk := -1
var _glass := -1
var _pass := 0
var _fail := 0


func _init() -> void:
	print("spaces probe: a room and its openings")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	for m in BrickWorld.get_material_count():
		if BrickWorld.is_material_translucent(m):
			_glass = m
			break
	_chunk = _w.create_chunk(Vector3i.ZERO, Vector3i(30, 30, 30))
	_build()
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _put(x: int, y: int, z: int, glass := false) -> void:
	var id := _w.place_block(_chunk, Vector3i(x, y, z), int(_palette.plate_1x1), 0)
	if glass and id >= 0:
		_w.set_block_material(_chunk, id, _glass)


func _clear(x: int, y: int, z: int) -> void:
	var id := _w.block_at(_chunk, Vector3i(x, y, z))
	if id >= 0:
		_w.remove_block(_chunk, id)


## Room A: inside x 2-11, z 2-9. Room B: inside x 13-20, z 2-9. Walls one
## stud thick (x 1, 12, 21; z 1) but two along z 10-11. Floor y 0, ceiling y 10,
## under and over the walls too; nothing outside them.
func _build() -> void:
	for x in range(1, 22):
		for z in range(1, 12):
			_put(x, 0, z)
			_put(x, 10, z)
			var wall := x == 1 or x == 12 or x == 21 or z == 1 or z >= 10
			if wall:
				for y in range(1, 10):
					_put(x, y, z)
	# The doorway, A to B: x 12, z 5-6, from the floor up six plates.
	for z in [5, 6]:
		for y in range(1, 7):
			_clear(12, y, z)
	# A window to the outside: z 1, x 5-6, plates 4-6.
	for x in [5, 6]:
		for y in range(4, 7):
			_clear(x, y, 1)
	# A pane of glass in the far wall: x 1, z 4-5, plates 3-6.
	for z in [4, 5]:
		for y in range(3, 7):
			_clear(1, y, z)
			_put(1, y, z, true)
	# A niche in the thick wall: z 10, x 8, plates 3-4; z 11 behind it stays.
	for y in [3, 4]:
		_clear(8, y, 10)


func _cell_kind(c: Vector3i) -> int:
	if not _w.is_solid(_chunk, c):
		return StructureSpaces.Cell.AIR
	var id := _w.block_at(_chunk, c)
	if BrickWorld.is_material_translucent(_w.get_block_material(_chunk, id)):
		return StructureSpaces.Cell.GLASS
	return StructureSpaces.Cell.SOLID


func _find(start: Vector3i) -> Dictionary:
	return StructureSpaces.find_space(start, _cell_kind, Vector3i.ZERO, Vector3i(30, 30, 30))


func _kinds(found: Dictionary) -> Dictionary:
	var out := {}
	for o in found.openings:
		out[o.kind] = int(out.get(o.kind, 0)) + 1
	return out


func _cells_of(found: Dictionary, kind: String) -> int:
	var n := 0
	for o in found.openings:
		if o.kind == kind:
			n += (o.cells as Array).size()
	return n


func _run() -> void:
	var t0 := Time.get_ticks_usec()
	var a := _find(Vector3i(6, 1, 5))
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_ok("a click on the floor finds the room: its footprint, floor and ceiling",
			a.ok and (a.columns as Array).size() == 80 and int(a.floor_y) == 0 and int(a.ceil_y) == 10,
			"%s, %d columns, floor %d, ceiling %d, %.1f ms" % [a.why if not a.ok else "found",
				(a.columns as Array).size(), a.floor_y, a.ceil_y, ms])
	var k := _kinds(a)
	_ok("its openings: the doorway, the window and the glass, each its kind -- and not the niche",
			(a.openings as Array).size() == 3 and k.get("doorway", 0) == 1 and k.get("window", 0) == 1
			and k.get("glass", 0) == 1,
			str(k))
	_ok("each opening is the cells it should be: doorway 12, window 6, glass 8",
			_cells_of(a, "doorway") == 12 and _cells_of(a, "window") == 6 and _cells_of(a, "glass") == 8,
			"doorway %d, window %d, glass %d" % [_cells_of(a, "doorway"), _cells_of(a, "window"),
				_cells_of(a, "glass")])
	var b := _find(Vector3i(16, 1, 5))
	var kb := _kinds(b)
	_ok("the room next door finds the same doorway, and only that",
			b.ok and (b.columns as Array).size() == 64 and (b.openings as Array).size() == 1
			and kb.get("doorway", 0) == 1 and _cells_of(b, "doorway") == 12,
			"%d columns, %s" % [(b.columns as Array).size(), str(kb)])
	var out := _find(Vector3i(26, 1, 26))
	_ok("a click with no floor under it is no room", not out.ok, out.why)
	# By hand: the window made an arch, and the room found again.
	var rec := StructureSpaces.empty()
	var made := StructureSpaces.record_space(0, "office", 0, Vector3i(6, 1, 5), a)
	rec.spaces.append(made[0])
	rec.openings.append_array(made[1])
	var wi := StructureSpaces.opening_at(rec, Vector3i(5, 5, 1))
	if wi >= 0:
		(rec.openings[wi] as Dictionary).kind = "arch"
		(rec.openings[wi] as Dictionary).set = true
	var again := StructureSpaces.record_space(0, "office", 0, Vector3i(6, 1, 5), _find(Vector3i(6, 1, 5)),
			rec.openings)
	var kept := false
	for o in again[1]:
		if o.kind == "arch" and bool(o.set):
			kept = true
	_ok("an opening's kind set by hand stays when the room is found again", wi >= 0 and kept,
			"window at %d" % wi)
	_ok("a cell of the room's air is in the space; one in its wall is not",
			StructureSpaces.space_at(rec, Vector3i(6, 4, 5)) == 0
			and StructureSpaces.space_at(rec, Vector3i(12, 8, 5)) == -1)
	_generated()
	_generated_with_stairs()
	_floors()


## A generated building, two storeys of 30 x 30 studs, as the city lays one.
func _generated() -> void:
	var fx := 30
	var fz := 30
	var courses := 12
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(_w, c, _palette, fx, fz, courses)
	var rooms := RoomManifest.rooms_for(fx, fz, courses, 7)
	var t0 := Time.get_ticks_usec()
	var rec := StructureSpaces.for_tower(_w, c, fx, fz, courses, 7)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var same_kind := true
	for s: Dictionary in rec.spaces:
		for r: Room in rooms:
			if r.id == int(s.id) and r.kind != String(s.kind):
				same_kind = false
	var k := {}
	for o in rec.openings:
		k[o.kind] = int(k.get(o.kind, 0)) + 1
	_ok("a generated building's rooms are all found from its bricks, each of its own kind",
			not rooms.is_empty() and (rec.spaces as Array).size() == rooms.size() and same_kind,
			"%d of %d rooms, %.1f ms" % [(rec.spaces as Array).size(), rooms.size(), ms])
	_ok("with windows out and doorways between them",
			int(k.get("window", 0)) > 0 and int(k.get("doorway", 0)) > 0, str(k))
	_frame()


## The frame, made by the generator (Docs/DestructionLod.md 4): every column it
## names is bricks, and every floor it names is bricks across its panels. Twelve
## storeys, so the lower ones carry COLUMN_STOREYS and stand their columns (a
## two-storey one has none: its room walls carry it).
func _frame() -> void:
	var fx := 30
	var fz := 30
	var courses := 12 * TowerRecipe.COURSES_PER_FLOOR
	var w := BrickWorld.new()
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, TowerRecipe.bake_palette(w), fx, fz, courses)
	var rec := StructureSpaces.empty()
	rec.merge(TowerRecipe.frame(fx, fz, courses, [], true, w, c), true)
	var holes := 0
	for col in rec.columns:
		for y in range(int(col[4]), int(col[4]) + int(col[5])):
			for x in range(int(col[0]), int(col[0]) + int(col[2])):
				for z in range(int(col[1]), int(col[1]) + int(col[3])):
					if not w.is_solid(c, Vector3i(x, y, z)):
						holes += 1
	var thin := 0
	for f in rec.floors:
		for p: Vector3i in TowerRecipe.plan(fx, fz).panels:
			@warning_ignore("integer_division")
			var mid := Vector2i(p.x + p.z / 2, p.y + p.z / 2)
			for y in range(int(f[0]), int(f[0]) + int(f[1])):
				if not w.is_solid(c, Vector3i(mid.x, y, mid.y)):
					thin += 1
	_ok("its frame: floors and columns as the generator laid them, every cell of them bricks",
			(rec.floors as Array).size() == TowerRecipe.layout(courses).filter(
				func(b: Dictionary) -> bool: return b.kind == "base" or b.kind == "slab").size()
			and (rec.columns as Array).size() > 0 and holes == 0 and thin == 0,
			"%d floor(s), %d column(s); %d column cell(s) not bricks, %d floor cell(s)" % [
				(rec.floors as Array).size(), (rec.columns as Array).size(), holes, thin])


## A generated building as the city lays it, its stairwell carved through every
## slab: the shaft is solid to the finder, so every room beside it is sealed --
## no side of it open where the slab has its hole (Docs/Structures.md 3.3).
func _generated_with_stairs() -> void:
	var fx := 40
	var fz := 40
	var courses := 18
	var stair := TowerRecipe.stair_rect(fx, fz)
	# A world of its own: the recipe lays its bricks from the origin.
	var w := BrickWorld.new()
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, TowerRecipe.bake_palette(w), fx, fz, courses, [stair])
	var open_rooms := func(rec: Dictionary) -> int:
		var leaky := {}
		for o in rec.openings:
			if String(o.kind) == "open":
				leaky[int(o.space)] = true
		return leaky.size()
	var before: Dictionary = StructureSpaces.for_tower(w, c, fx, fz, courses, 7, {}, Rect2i())
	var after: Dictionary = StructureSpaces.for_tower(w, c, fx, fz, courses, 7)
	var rooms := RoomManifest.rooms_for(fx, fz, courses, 7).size()
	print("  (the stairwell %s; with it read as holes: %d of %d rooms found, %d of them open)" % [
			str(stair), (before.spaces as Array).size(), RoomManifest.rooms_for(fx, fz, courses, 7).size(), open_rooms.call(before)])
	_ok("with its stairwell solid, every room of a building with stairs is sealed",
			stair.size != Vector2i.ZERO and int(open_rooms.call(after)) == 0
			and (after.spaces as Array).size() > 0,
			"%d of %d rooms found, %d open" % [(after.spaces as Array).size(), rooms,
			int(open_rooms.call(after))])


## Floors found in the bricks (StructureSpaces.find_floors; Docs/Structures.md
## 2.4).
func _floors() -> void:
	# A generated tower, its stairwell carved: what the finder makes of its
	# bricks against what the generator says it laid.
	var fx := 40
	var fz := 40
	var courses := 18
	var w := BrickWorld.new()
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, TowerRecipe.bake_palette(w), fx, fz, courses, [TowerRecipe.stair_rect(fx, fz)])
	var t0 := Time.get_ticks_usec()
	var found := StructureSpaces.find_floors(func(y: int) -> PackedByteArray:
			return w.get_column_mask(c, y, y + 1), w.get_chunk_dims(c))
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var laid: Array = TowerRecipe.frame(fx, fz, courses).floors
	_ok("a generated tower's floors, found in its bricks, are the ones its generator laid",
			str(found) == str(laid), "found %s, laid %s, %.1f ms" % [str(found), str(laid), ms])

	# A build, its corner at (5, 2, 5): a one-plate base 20 x 20, walls two studs
	# thick and nine plates high round it, a mezzanine 10 x 10 three plates over a
	# floor of interior plates, a 4 x 4 column, and a roof two plates thick.
	var r := BuildRecipe.new()
	var o := Vector3i(5, 2, 5)
	var slab := func(y: int) -> void:
		for q in [Vector2i(0, 0), Vector2i(10, 0), Vector2i(0, 10), Vector2i(10, 10)]:
			r.add("plate_10x10", o + Vector3i(q.x, y, q.y), 0)
	slab.call(0)
	for y in [1, 4, 7]:
		for x in 20:
			for z in 20:
				if x < 2 or z < 2 or x >= 18 or z >= 18:
					r.add("brick_1x1", o + Vector3i(x, y, z), 0)
	var rug := r.size()
	r.add("plate_10x10", o + Vector3i(2, 2, 2), 0)
	r.set_role(rug, BuildRecipe.Role.INTERIOR)
	r.add("plate_10x10", o + Vector3i(2, 5, 2), 0)
	for y in range(1, 10):
		r.add("plate_4x4", o + Vector3i(13, y, 13), 0)
	slab.call(10)
	slab.call(11)
	t0 = Time.get_ticks_usec()
	var floors := StructureSpaces.floors_of_build(r)
	ms = float(Time.get_ticks_usec() - t0) / 1000.0
	_ok("a build's floors: its base, its mezzanine and its roof, in its own grid -- not its walls, the column or the interior plates",
			str(floors) == str([[2, 1], [7, 1], [12, 2]]), "%s, %.1f ms" % [str(floors), ms])
	var reg := BuildingRegistry.new(BrickWorld.new(), {})
	var id := reg.register_build(r, Transform3D())
	_ok("and the registry gives the build those as its floor lines, in its chunk's grid",
			str(reg.floor_lines(id)) == str(PackedInt32Array([0, 5, 10])), str(reg.floor_lines(id)))
