extends SceneTree

## Acceptance probe for interiors, first pass: rooms and their contents.
##
##     godot --headless --path . --script tools/interior_probe.gd
##
## The claims, from [Docs/Interiors.md](../Docs/Interiors.md):
##
##   §1  a room nobody has looked into has no objects at all -- it has a seed
##   §2  rooms come from the recipe; contents come from (building seed, room id)
##       and are reproducible without being stored
##   §8.2 a room is DRAWN from its manifest with no brick laid, and only what
##       has a floor under it is drawn
##   §8.4 a piece that is hit becomes bricks, that piece alone; what is left
##       of it when the bricks go back is the diff, and all that is kept
##   §4.2 a piece that is bricks rides the island its floor rides -- and,
##       since the block role, weighs nothing in the solve while doing it
##   §3  the holes in a room's walls are its openings: the windows the recipe
##       cut, and whatever has been blown through since
##   §5.4 an uncompromised room nobody has approached costs nothing
##
## What stood here before 2026-10-08 measured the "rungs" this replaced -- a
## room opened whole by walking up to it, drawn or faked a room at a time,
## spilled into a wreck or written off with it, resolved against whichever
## face was the floor -- and went with them (Interiors §8.12).
##
## No rendering and no physics.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("interior probe")
	_check_rooms_come_from_the_recipe()
	_check_a_manifest_is_a_function_of_its_seed()
	_check_nothing_until_asked()
	_check_a_piece_becomes_bricks()
	_check_the_drawing()
	_check_nothing_stands_on_air()
	_check_the_diff()
	_check_compromised()
	_check_openings()
	_check_the_wreck()
	_check_furniture_is_not_structure()
	_check_grounding_is_one_way()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _world() -> Array:
	var w := BrickWorld.new()
	return [w, TowerRecipe.bake_palette(w)]


func _tower(reg: BuildingRegistry, courses: int = 18) -> int:
	return reg.register(20, 20, courses, Transform3D(Basis(), Vector3(8.0, 0.0, -3.0)))


# ---------------------------------------------------------------------------

func _check_rooms_come_from_the_recipe() -> void:
	print("\nrooms are generated, not authored")
	var res := _world()
	var reg := BuildingRegistry.new(res[0], res[1])
	var id := _tower(reg)
	var rooms := reg.rooms_of(id)
	_ok("a building has rooms", rooms.size() > 0, "%d" % rooms.size())
	_ok("with a kind each", rooms[0].kind in Room.KINDS, rooms[0].kind)

	# Inside the walls, above the slab, and stacked up the building.
	var inside := true
	var lowest := 1 << 30
	var highest := -(1 << 30)
	for r in rooms:
		inside = inside and r.lo.x > 0 and r.lo.z > 0 \
				and r.lo.x + r.size.x <= 20 and r.lo.z + r.size.z <= 20
		lowest = mini(lowest, r.lo.y)
		highest = maxi(highest, r.lo.y)
	_ok("all of them inside the footprint", inside)
	_ok("and on more than one storey", highest > lowest,
			"%d to %d plates" % [lowest, highest])

	# The same building always has the same rooms; a different one does not.
	var again := BuildingRegistry.new(res[0], res[1])
	var same_id := _tower(again)
	var same := again.rooms_of(same_id)
	var equal := same.size() == rooms.size()
	for i in mini(same.size(), rooms.size()):
		equal = equal and same[i].lo == rooms[i].lo and same[i].kind == rooms[i].kind
	_ok("generated the same way twice", equal)

	var other := again.register(20, 20, 18, Transform3D())
	var other_rooms := again.rooms_of(other)
	var differs := false
	for i in mini(other_rooms.size(), rooms.size()):
		differs = differs or other_rooms[i].kind != rooms[i].kind
	_ok("and differently for a different building", differs)


func _check_a_manifest_is_a_function_of_its_seed() -> void:
	print("\nand so are their contents")
	var res := _world()
	var reg := BuildingRegistry.new(res[0], res[1])
	var id := _tower(reg)
	var room := reg.get_room(id, 0)
	var first := RoomManifest.items_for(room)
	var second := RoomManifest.items_for(room)
	_ok("a manifest is the same every time it is run", first.size() == second.size(),
			"%d vs %d" % [first.size(), second.size()])
	var same := true
	for i in first.size():
		same = same and first[i].type == second[i].type and first[i].cell == second[i].cell
	_ok("item for item", same)
	_ok("and it holds something", first.size() > 0 or room.kind == "empty",
			"%s room, %d items" % [room.kind, first.size()])

	# What is in a room suits what the room is.
	var wrong := 0
	for r in reg.rooms_of(id):
		var allowed: Array = RoomManifest.BY_KIND.get(r.kind, [])
		for item in RoomManifest.items_for(r):
			if not allowed.has(str(item.type)):
				wrong += 1
	_ok("every item belongs to its room's kind", wrong == 0, "%d out of place" % wrong)


func _check_nothing_until_asked() -> void:
	print("\na room nobody has looked into costs nothing")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var before: Dictionary = w.get_memory_report()
	var id := _tower(reg)
	var rooms := reg.rooms_of(id)
	var after: Dictionary = w.get_memory_report()
	_ok("generating them creates no chunk", int(after.chunks) == int(before.chunks))
	_ok("and no bricks", int(after.total_bytes) == int(before.total_bytes))
	var laid := 0
	for r in rooms:
		laid += r.item_count()
	_ok("no contents have been run", laid == 0)
	_ok("and nothing has to be written down", not rooms[0].is_changed())


## Lay every piece of a room as bricks, one at a time, as blasts reaching each
## of them would (BuildingRegistry.lay_item). Returns the blocks that laid.
func _lay_room(reg: BuildingRegistry, id: int, index: int) -> int:
	var room := reg.get_room(id, index)
	if room.items.is_empty():
		room.items = RoomManifest.items_for(room)
	var n := 0
	for i in room.items.size():
		n += reg.lay_item(id, index, i)
	return n


## Interiors §8.4: what is hit becomes bricks -- that piece, in the building's
## own chunk -- and nothing about it is kept once the bricks go back unharmed.
func _check_a_piece_becomes_bricks() -> void:
	print("\na piece that is hit becomes bricks in the building")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	_ok("there is a furnished room", index >= 0)
	var room := reg.get_room(id, index)
	var b := reg.get_building(id)

	_ok("a building that is not bricks has nowhere to lay one",
			reg.lay_item(id, index, 0) == 0 and room.laid.is_empty())
	var chunk := reg.materialise(id)
	var before := w.get_alive_block_count(chunk)
	var first := reg.lay_item(id, index, 0)
	_ok("a piece laid is bricks in the building's own chunk", first > 0, "%d blocks" % first)
	_ok("the chunk grew by exactly that", w.get_alive_block_count(chunk) == before + first)
	_ok("that piece is marked laid, and no other",
			room.laid.size() == 1 and room.laid.has(0)
			and b.laid_rooms.size() == 1 and b.laid_rooms.has(index))
	_ok("and the manifest has been run", room.item_count() > 0)
	_ok("laying it twice does nothing", reg.lay_item(id, index, 0) == 0)
	var placed := first + _lay_room(reg, id, index)
	_ok("the registry counts what is bricks",
			int(reg.room_report().laid) == room.laid.size() and reg.items_laid == room.laid.size(),
			"%d laid, report %d, counter %d" % [room.laid.size(), int(reg.room_report().laid),
			reg.items_laid])
	_ok("every piece of the room laid is the room's blocks, no more",
			w.get_alive_block_count(chunk) == before + placed and _laid(room) == placed,
			"%d blocks" % placed)

	# Inside the room, which is the only test of "where" that matters.
	var box := room.local_box().grow(0.5)
	var outside := 0
	var cell := BrickWorld.get_cell_size()
	for item in room.items:
		for block in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
			var ticks: Array = w.get_block_ticks(chunk, block)
			if ticks.is_empty():
				continue
			var at: Vector3 = Vector3(ticks[0] as Vector3i) * (cell.x / float(BrickWorld.ticks_per_stud()))
			if not box.has_point(at):
				outside += 1
	_ok("and all of it inside the room", outside == 0, "%d blocks outside" % outside)

	reg.dematerialise(id)
	_ok("the bricks given back, nothing is laid and nothing is written off",
			room.laid.is_empty() and b.laid_rooms.is_empty() and _laid(room) == 0
			and not room.is_changed())
	_ok("without the building counting it as damage", not b.is_damaged())


## Interiors §8.2: a room is drawn from its manifest -- on screen, one box a
## piece -- with nothing laid, and a piece becoming bricks changes nothing
## anybody can see.
func _check_the_drawing() -> void:
	print("\na room can be drawn without a single brick")
	var res := _world()
	var w: BrickWorld = res[0]
	var pal: Dictionary = res[1]
	var reg := BuildingRegistry.new(w, pal)
	var id := _tower(reg, 48)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	var chunk := reg.materialise(id)
	var offset: Vector3i = reg._rebase_of(reg.get_building(id))
	var before := w.get_alive_block_count(chunk)
	room.items = RoomManifest.items_for(room)
	var d := RoomManifest.draw_items(w, chunk, pal, room, offset)
	var boxes: Array = (d.boxes as Array).duplicate()
	_ok("a drawn room draws its pieces", boxes.size() > 0, "%d pieces" % boxes.size())
	_ok("one box a piece", boxes.size() == room.items.size(),
			"%d boxes, %d pieces" % [boxes.size(), room.items.size()])
	_ok("and lays nothing", w.get_alive_block_count(chunk) == before and room.laid.is_empty())
	_ok("nor writes anything down", not room.is_changed())

	# Every part as a box, in the chunk's own metres -- which is exactly what
	# the blocks will say about themselves once they are laid.
	var drawn_parts := {}
	for buf in [d.buffer as PackedFloat32Array, d.details as PackedFloat32Array]:
		@warning_ignore("integer_division")
		var parts: int = buf.size() / FurnitureMesh.STRIDE
		for k in parts:
			var o := k * FurnitureMesh.STRIDE
			var size := Vector3(buf[o], buf[o + 5], buf[o + 10])
			var mid := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
			drawn_parts[_box_key(mid - size * 0.5, size)] = true

	var placed := _lay_room(reg, id, index)
	_ok("every piece of it laid is bricks", placed > 0 and room.laid.size() == room.items.size(),
			"%d blocks, %d of %d piece(s)" % [placed, room.laid.size(), room.items.size()])
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var laid_parts := {}
	for item in room.items:
		for block in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
			var ticks: Array = w.get_block_ticks(chunk, block)
			laid_parts[_box_key(Vector3(ticks[0] as Vector3i) * tick_m,
					Vector3(ticks[1] as Vector3i) * tick_m)] = true
	var missing := 0
	for key in laid_parts:
		if not drawn_parts.has(key):
			missing += 1
	_ok("the drawing was every brick it became, where it became it",
			missing == 0 and laid_parts.size() == drawn_parts.size(),
			"%d laid, %d drawn, %d laid but not drawn" % [laid_parts.size(),
			drawn_parts.size(), missing])
	# And every piece's box covers what that piece laid.
	var covered := true
	var bi := 0
	for i in room.items.size():
		var blocks: PackedInt32Array = room.items[i].get("blocks", PackedInt32Array())
		if blocks.is_empty():
			continue
		var box: AABB = boxes[bi]
		bi += 1
		for block in blocks:
			var ticks: Array = w.get_block_ticks(chunk, block)
			var lo := Vector3(ticks[0] as Vector3i) * tick_m
			covered = covered and box.grow(0.001).encloses(
					AABB(lo, Vector3(ticks[1] as Vector3i) * tick_m))
	_ok("and each piece's box covers its bricks", covered)

	# Bricks now, and drawn from them: no drawing of the room shows them again.
	var again := RoomManifest.draw_items(w, chunk, pal, room, offset)
	_ok("a piece that is bricks is not drawn as well",
			(again.buffer as PackedFloat32Array).is_empty() and (again.boxes as Array).is_empty(),
			"%d box(es) drawn over bricks" % (again.boxes as Array).size())


## What floated, and what stops it now.
func _check_nothing_stands_on_air() -> void:
	print("\nno furniture stands on nothing")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	# A building with a stairwell, placed as the city places one: a shaft ten
	# studs across with no floor in it on any storey.
	var sx := TowerRecipe.stair_line(40)
	var sz := TowerRecipe.stair_line(30)
	var id := reg.register(40, 30, 78, Transform3D())
	reg.add_fixture(id, "staircase", {"steps": StaircaseRecipe.steps_for_courses(78),
			"colour": 11}, Vector3i(sx, TowerRecipe.SLAB_PLATES, sz))
	var chunk := reg.materialise(id)
	var offset: Vector3i = reg._rebase_of(reg.get_building(id))
	var shaft := Rect2i(sx, sz, StaircaseRecipe.DIAMETER, StaircaseRecipe.DIAMETER)
	var in_shaft := 0
	var on_air := 0
	var items := 0
	for room in reg.rooms_of(id):
		for item in RoomManifest.items_for(room):
			items += 1
			var span := RoomManifest._item_span(str(item.type))
			var cell: Vector3i = item.cell
			if Rect2i(cell.x, cell.z, span.x, span.z).intersects(shaft):
				in_shaft += 1
			# The drawing's own rule: most of its floor is live brick here.
			if RoomManifest.item_floor_share(w, chunk, str(item.type), cell - offset) <= 0.5:
				on_air += 1
	_ok("nothing is generated in the stairwell", in_shaft == 0,
			"%d of %d items" % [in_shaft, items])
	# No two things in one room share floor: a crate placed over a table laid
	# only its lid, and the lid hung in the air over the tabletop.
	var overlaps := 0
	for room in reg.rooms_of(id):
		var boxes: Array[Rect2i] = []
		for item in RoomManifest.items_for(room):
			var sp := RoomManifest._item_span(str(item.type))
			var r := Rect2i((item.cell as Vector3i).x, (item.cell as Vector3i).z, sp.x, sp.z)
			for q in boxes:
				if q.intersects(r):
					overlaps += 1
			boxes.append(r)
	_ok("and no two items in a room share floor", overlaps == 0, "%d overlaps" % overlaps)
	# And an item is laid whole or not at all: block one part of a crate and
	# the rest of it is taken back out.
	var probe_cell := Vector3i(sx + 3, 60, sz + 3)
	var pal: Dictionary = res[1]
	w.place_block(chunk, probe_cell + Vector3i(0, 3, 0), pal.brick_2x2, 1)
	var before := w.get_alive_block_count(chunk)
	var got := RoomManifest.build_item(w, chunk, pal, {"type": "crate", "cell": probe_cell}, 4)
	_ok("an item that cannot be laid whole is not laid at all",
			got.is_empty() and w.get_alive_block_count(chunk) == before,
			"%d laid, %d alive against %d" % [got.size(), w.get_alive_block_count(chunk), before])
	_ok("and everything generated has a floor under it", on_air == 0,
			"%d of %d items" % [on_air, items])

	# Take the floor away from under a piece. It is not drawn there and cannot
	# be laid there -- and it is NOT written off: its floor may be lying in the
	# street with the piece on it (Interiors §8.3), so its not being here says
	# nothing about its being gone.
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	room.items = RoomManifest.items_for(room)
	var victim: Dictionary = room.items[0]
	var span0 := RoomManifest._item_span(str(victim.type))
	var cell0: Vector3i = (victim.cell as Vector3i) - offset
	var under := PackedInt32Array()
	for x in span0.x:
		for z in span0.z:
			var bid := w.block_at(chunk, Vector3i(cell0.x + x, cell0.y - 1, cell0.z + z))
			if bid >= 0 and not under.has(bid):
				under.push_back(bid)
	w.kill_blocks(chunk, under)
	var d := RoomManifest.draw_items(w, chunk, pal, room, offset)
	var drawn := {}
	for j in range(0, (d.pieces as PackedInt32Array).size(), 6):
		drawn[int(d.pieces[j])] = true
	_ok("a drawing leaves out a piece whose floor is gone",
			not drawn.has(0) and (d.boxes as Array).size() == drawn.size()
			and drawn.size() < room.items.size(),
			"%d of %d piece(s) drawn" % [drawn.size(), room.items.size()])
	_ok("and writes nothing off", not room.is_changed(), "%d gone" % room.gone.size())
	_ok("nor is it laid as bricks where it no longer stands",
			reg.lay_item(id, index, 0) == 0 and not room.laid.has(0) and not room.is_changed())


## Interiors §3: a room's openings are the holes in its walls -- its windows,
## and what has been blown through them. What the squad reads for a way in and
## a line of sight (scripts/ai/squad/city_rooms.gd). Was the `-- --rooms`
## gate's; here since that gate went with the drawing it measured.
func _check_openings() -> void:
	print("\na room's walls have windows, and a hole blown in one is an opening too")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := reg.register(40, 30, 48, Transform3D(Basis(), Vector3(8.0, 0.0, -3.0)))
	var b := reg.get_building(id)
	_ok("a building that is not bricks reports none", reg.openings_of(id, 0).is_empty())
	reg.materialise(id)
	var with := 0
	var widest := 0.0
	var target := -1
	for room in reg.rooms_of(id):
		var open := reg.openings_of(id, room.id)
		if open.is_empty():
			continue
		with += 1
		if target < 0:
			target = room.id
		for box in open:
			widest = maxf(widest, maxf(box.size.x, box.size.z))
	_ok("an undamaged building has windows: its rooms report openings", with > 0,
			"%d of %d room(s)" % [with, reg.rooms_of(id).size()])
	# A window is 4 studs (1.4 m). Much wider means the scan merged two of
	# them across the pier between.
	_ok("each of them one window, not a box drawn round two", widest < 2.0,
			"widest %.2f m" % widest)
	if target < 0:
		return
	var before := reg.openings_of(id, target)
	var size0 := 0.0
	for box in before:
		size0 += box.get_volume()
	_ok("asked again with nothing changed, the answer is the one kept",
			reg.openings_of(id, target) == before)
	# Through the wall at one of its windows.
	var killed := reg.damage(id, b.xform * before[0].get_center(), 1.6)
	# The dead are counted once a physics frame, and a probe has no frames.
	b.dead_frame = -1
	var after := reg.openings_of(id, target)
	var size1 := 0.0
	for box in after:
		size1 += box.get_volume()
	_ok("a hole blown through the wall is more opening than the window was",
			killed.size() > 0 and size1 > size0,
			"%d brick(s) gone; %d opening(s) of %.2f m3, then %d of %.2f" % [killed.size(),
			before.size(), size0, after.size(), size1])


static func _box_key(lo: Vector3, size: Vector3) -> String:
	return "%.3f,%.3f,%.3f/%.3f,%.3f,%.3f" % [lo.x, lo.y, lo.z, size.x, size.y, size.z]


func _check_the_diff() -> void:
	print("\nand what happened to it is all that is kept")
	var res := _world()
	var w: BrickWorld = res[0]
	var pal: Dictionary = res[1]
	var reg := BuildingRegistry.new(w, pal)
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	var chunk := reg.materialise(id)
	_lay_room(reg, id, index)

	# Shoot one of the things in it.
	var victim: PackedInt32Array = PackedInt32Array()
	var which := -1
	for i in room.items.size():
		var blocks: PackedInt32Array = room.items[i].get("blocks", PackedInt32Array())
		if not blocks.is_empty():
			victim = blocks
			which = i
			break
	_ok("there is something to destroy", which >= 0)
	w.kill_blocks(chunk, victim)
	reg.dematerialise(id)
	_ok("the diff remembers it is gone", room.gone.has(which))
	_ok("and remembers nothing else", room.gone.size() == 1 and room.laid.is_empty(),
			"%d gone, %d laid" % [room.gone.size(), room.laid.size()])

	# Bricks again: the room is a drawing of what is left.
	chunk = reg.materialise(id)
	var d := RoomManifest.draw_items(w, chunk, pal, room, reg._rebase_of(reg.get_building(id)))
	var drawn := {}
	for j in range(0, (d.pieces as PackedInt32Array).size(), 6):
		drawn[int(d.pieces[j])] = true
	_ok("the building bricks again, the room is drawn with what is left",
			drawn.size() == room.items.size() - 1,
			"%d of %d piece(s)" % [drawn.size(), room.items.size()])
	_ok("but not what was destroyed",
			not drawn.has(which) and reg.lay_item(id, index, which) == 0)


func _check_compromised() -> void:
	print("\na blast lays the pieces it reaches, whether or not anyone walked in")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var b := reg.get_building(id)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	reg.materialise(id)

	var mid: Vector3 = b.xform * (room.local_box().position + room.local_box().size * 0.5)
	var far: Vector3 = b.xform * Vector3(0.0, 100.0, 0.0)
	var miss: Dictionary = reg.compromise_items(id, far, 2.0)
	_ok("a blast nowhere near it lays nothing",
			(miss.laid as Array).is_empty() and int(miss.gone) == 0 and room.laid.is_empty())
	var hit: Dictionary = reg.compromise_items(id, mid, 2.0)
	_ok("a blast inside it lays what it reaches",
			(hit.laid as Array).size() > 0 and room.laid.size() == (hit.laid as Array).size(),
			"%d piece(s) laid of %d" % [(hit.laid as Array).size(), room.item_count()])

	# And then the hit lands on contents that are actually there.
	var chunk := b.chunk
	var before := w.get_alive_block_count(chunk)
	reg.damage(id, mid, 2.0)
	_ok("so the damage reaches them", w.get_alive_block_count(chunk) < before)


## Interiors §4.2 and §8.3: the building comes down. A piece that was bricks is
## bricks in the wreck; nothing else is built, spilled or written off -- what
## stood on a floor is drawn on whichever piece holds that floor, when somebody
## is near it (tools/interior_group_probe.gd has that half, on a real split).
func _check_the_wreck() -> void:
	print("\nand a building that comes down takes its rooms with it, as they are")
	var res := _world()
	var w: BrickWorld = res[0]
	var pal: Dictionary = res[1]
	var reg := BuildingRegistry.new(w, pal)
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	var chunk := reg.materialise(id)
	var b := reg.get_building(id)
	var offset: Vector3i = reg._rebase_of(b)
	var laid := reg.lay_item(id, index, 0)
	_ok("one piece of a room is bricks when the building falls", laid > 0, "%d blocks" % laid)
	var before := w.get_alive_block_count(chunk)

	# The bricks are an island now.
	reg.hand_over(id)
	_ok("the building is gone, the chunk is not",
			not b.is_materialised() and w.is_chunk_alive(chunk))
	_ok("nothing was built or taken out to do it", w.get_alive_block_count(chunk) == before)
	var changed := 0
	for r in reg.rooms_of(id):
		if r.is_changed():
			changed += 1
	_ok("and no room was written off", changed == 0, "%d room(s) with a diff" % changed)
	_ok("the piece that was bricks still is, in the wreck",
			room.laid.has(0) and _laid(room) == laid)
	# Drawn against the wreck's own chunk, by the rule a standing building's
	# rooms are: everything with its floor there, and the laid piece not twice.
	var d := RoomManifest.draw_items(w, chunk, pal, room, offset)
	var drawn := {}
	for j in range(0, (d.pieces as PackedInt32Array).size(), 6):
		drawn[int(d.pieces[j])] = true
	_ok("the rest of the room is drawn on the wreck, and that piece is not drawn twice",
			not drawn.has(0) and drawn.size() == room.items.size() - 1,
			"%d of %d piece(s) drawn" % [drawn.size(), room.items.size()])
	_ok("and nothing more can be laid in a building that is not there",
			reg.lay_item(id, index, 1) == 0 and room.laid.size() == 1)


## How many blocks a room currently has laid.
func _laid(room: Room) -> int:
	var n := 0
	for item in room.items:
		n += (item.get("blocks", PackedInt32Array()) as PackedInt32Array).size()
	return n


## A room full of furniture must not bring a building closer to falling down.
##
## The role is per BLOCK and it lives in the host's own chunk (BuildMode §9.2's
## third answer). So the test is the one that matters: solve the same building
## empty and furnished and demand the structural answer be identical, while the
## furniture is still there to ride the island.
func _check_furniture_is_not_structure() -> void:
	print("\nwhat is in a room weighs nothing in the building's own solve")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var chunk := reg.materialise(id)

	var empty_stress: Dictionary = w.solve_stress(chunk)
	var empty_balance: Dictionary = w.check_stability(chunk)
	var empty_blocks := w.get_alive_block_count(chunk)
	_ok("an unfurnished building holds together", int(empty_stress.failures) == 0)
	_ok("and nothing in it is decorative yet",
			w.get_decorative_blocks(chunk).is_empty())

	var placed := _lay_room(reg, id, index)
	_ok("furnishing it laid bricks", placed > 0, "%d" % placed)
	_ok("and the count was knowable without making the list",
			RoomManifest.item_count_for(reg.get_room(id, index))
			== RoomManifest.items_for(reg.get_room(id, index)).size())
	var decor := w.get_decorative_blocks(chunk)
	_ok("and every one of them is marked decorative", decor.size() == placed,
			"%d of %d" % [decor.size(), placed])
	_ok("which is more blocks in the chunk than there were",
			w.get_alive_block_count(chunk) > empty_blocks)

	var full_stress: Dictionary = w.solve_stress(chunk)
	_ok("the structure still holds", int(full_stress.failures) == 0)
	_ok("carrying exactly the weight it carried empty",
			is_equal_approx(float(full_stress.peak_load), float(empty_stress.peak_load)),
			"%.4f against %.4f" % [float(full_stress.peak_load), float(empty_stress.peak_load)])

	var full_balance: Dictionary = w.check_stability(chunk)
	_ok("and balanced where it was balanced empty",
			(full_balance.com as Vector3).distance_to(empty_balance.com as Vector3) < 0.0001,
			"%v against %v" % [full_balance.com, empty_balance.com])
	_ok("on the same footprint",
			full_balance.support_min == empty_balance.support_min
			and full_balance.support_max == empty_balance.support_max)

	# Weightless is not absent. §4.2: the furniture is in the chunk, so it is in
	# the piece that chunk becomes.
	var standing: PackedInt32Array = full_balance.blocks
	var riding := 0
	for bid in decor:
		if standing.has(bid):
			riding += 1
	_ok("but every piece of it is still standing in the building",
			riding == decor.size(), "%d of %d" % [riding, decor.size()])
	_ok("and still something the blast record knows about",
			w.get_block_ticks(chunk, decor[0]).size() > 0)

	# And it can be taken back off, which is what the workshop will need.
	_ok("the role can be cleared", w.set_blocks_decorative(chunk, decor, false) == decor.size())
	_ok("and setting it again on what already has it changes nothing",
			w.set_blocks_decorative(chunk, decor, true) == decor.size()
			and w.set_blocks_decorative(chunk, decor, true) == 0)


## Grounding goes INTO a room's contents and never back out of them.
##
## Two reported bugs, one rule. Furniture held whole buildings up -- a section
## that should have come down hung off the table standing in it -- because
## grounding is reachability and a chair was a perfectly good step on the path.
## And furniture floated, because a chair still touching a wall was still
## reachable after the floor under it had gone.
##
## So the edge is directed. Grounding never leaves a decorative block for a
## structural one, and a decorative block is only ever reached from BELOW.
## Structure keeps the old rule and needs it: undercut a wall and its weight
## travels sideways to the corners that still stand, which is why the support
## pass is a BFS rather than a downward walk. Furniture has no such story.
func _check_grounding_is_one_way() -> void:
	print("\ngrounding flows into a room's contents, never out of them")
	var res := _world()
	var w: BrickWorld = res[0]
	var pal: Dictionary = res[1]
	var reg := BuildingRegistry.new(w, pal)
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var chunk := reg.materialise(id)
	var room := reg.get_room(id, index)
	_lay_room(reg, id, index)
	var decor: PackedInt32Array = w.get_decorative_blocks(chunk)
	_ok("the room has contents", decor.size() > 0, "%d block(s)" % decor.size())

	var grounded := w.solve_grounded(chunk)
	var floating := 0
	for b in decor:
		if grounded[b] == 0:
			floating += 1
	_ok("all of it is held up while its floor is there", floating == 0,
			"%d floating" % floating)

	# A purpose-built stack, because a generated room cannot be relied on to
	# offer a perch: the top of a crate is a TILE, and a tile has no studs, so
	# nothing clutches to it -- which is correct and not what is being tested.
	# Floor, a decorative brick standing on it, a structural brick on that.
	var w2 := BrickWorld.new()
	var pal2 := TowerRecipe.bake_palette(w2)
	var c2 := w2.create_chunk(Vector3i.ZERO, Vector3i(8, 24, 8))
	var slab := w2.place_block(c2, Vector3i(0, 0, 0), pal2.plate_2x2, 2)
	var chair := w2.place_block(c2, Vector3i(0, 1, 0), pal2.brick_2x2, 4, true)
	var perched := w2.place_block(c2, Vector3i(0, 4, 0), pal2.brick_2x2, 5)
	_ok("a stack of floor, furniture and brick builds",
			slab >= 0 and chair >= 0 and perched >= 0,
			"%d %d %d" % [slab, chair, perched])
	_ok("the middle one is the furniture",
			w2.is_block_decorative(c2, chair) and not w2.is_block_decorative(c2, perched))
	_ok("and they are all clutched together",
			w2.get_block_neighbours(c2, perched).has(chair)
			and w2.get_block_neighbours(c2, chair).has(slab),
			"%s / %s" % [w2.get_block_neighbours(c2, perched),
					w2.get_block_neighbours(c2, chair)])

	var g2 := w2.solve_grounded(c2)
	_ok("the floor is held up by the ground", g2[slab] == 1)
	_ok("the furniture is held up by the floor", g2[chair] == 1)
	_ok("but the brick standing on the furniture is NOT held up by it",
			g2[perched] == 0)
	var loose2: Array = w2.find_detached_groups(c2)
	var carried := 0
	for g in loose2:
		if (g as PackedInt32Array).has(perched):
			carried += 1
	_ok("so it comes away as a piece", carried == 1,
			"%d group(s) hold it" % carried)

	# And the same block, once the floor under it is gone.
	w2.kill_blocks(c2, PackedInt32Array([slab]))
	g2 = w2.solve_grounded(c2)
	_ok("with the floor gone the furniture is falling too", g2[chair] == 0)

	# Through the CHUNK's transform: apply_hit takes a world point, and this
	# tower is registered at an offset. Aimed in local metres it lands in
	# open air next to the building and kills nothing, which is what it did.
	var cell := BrickWorld.get_cell_size()
	var under: Vector3 = w.get_chunk_transform(chunk) * Vector3(
			(room.lo.x + room.size.x * 0.5) * cell.x,
			(room.lo.y - 1) * cell.y,
			(room.lo.z + room.size.z * 0.5) * cell.z)
	var killed: PackedInt32Array = w.apply_hit(chunk, under, 2.2)
	_ok("a blast under the room takes its floor out", killed.size() > 0,
			"%d block(s)" % killed.size())
	grounded = w.solve_grounded(chunk)
	var dead := {}
	for d in w.get_dead_blocks(chunk):
		dead[d] = true
	var still_alive := 0
	var held := 0
	for b in decor:
		if not dead.has(b):
			still_alive += 1
			if grounded[b] == 1:
				held += 1
	_ok("what is left of the furniture is falling, not floating", held == 0,
			"%d of %d still held" % [held, still_alive])


## The first room with something in it -- some are generated empty on purpose.
func _furnished_room(reg: BuildingRegistry, id: int) -> int:
	for r in reg.rooms_of(id):
		if not RoomManifest.items_for(r).is_empty():
			return r.id
	return -1
