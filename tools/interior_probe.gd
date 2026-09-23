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
##   §3  activating materialises the manifest, deactivating frees the objects
##       and keeps the diff
##   §4.2 items ride the island the floor they stand on rides -- and, since the
##       block role, weigh nothing in the solve while doing it
##   §5.2 a room that fell while nobody was looking RESOLVES, it does not
##       simulate: contents end up against whatever face is now the floor
##   §5.4 an uncompromised room nobody has approached costs nothing
##
## No rendering and no physics.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("interior probe")
	_check_rooms_come_from_the_recipe()
	_check_a_manifest_is_a_function_of_its_seed()
	_check_nothing_until_asked()
	_check_activation()
	_check_the_drawn_rung()
	_check_nothing_stands_on_air()
	_check_the_diff()
	_check_compromised()
	_check_the_analytic_resolve()
	_check_the_spill()
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


func _check_activation() -> void:
	print("\nactivating a room puts its contents in the building")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	_ok("there is a furnished room to open", index >= 0)
	var room := reg.get_room(id, index)

	var chunk := reg.materialise(id)
	var before := w.get_alive_block_count(chunk)
	var placed := reg.activate_room(id, index)
	_ok("its contents are bricks in the building's own chunk", placed > 0,
			"%d blocks" % placed)
	_ok("the chunk grew by exactly that", w.get_alive_block_count(chunk) == before + placed)
	_ok("the room says it is open", room.active)
	_ok("and the manifest has been run", room.item_count() > 0)
	_ok("activating it twice does nothing", reg.activate_room(id, index) == 0)

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

	reg.deactivate_room(id, index)
	_ok("closing it takes the contents back out",
			w.get_alive_block_count(chunk) == before,
			"%d against %d" % [w.get_alive_block_count(chunk), before])
	_ok("without the building counting it as damage",
			w.get_dead_blocks(chunk).is_empty() and not reg.get_building(id).is_damaged())


## Scale §4.1 rung 2: a room can be drawn -- on screen, one box an item -- with
## nothing laid, and promoting it to bricks changes nothing anybody can see.
func _check_the_drawn_rung() -> void:
	print("\na room can be drawn without a single brick")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	# Tall enough for two furnished rooms: the last checks need a second.
	var id := _tower(reg, 48)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	_ok("a shell has nothing to draw into", reg.draw_room(id, index) == 0 and not room.drawn)

	var chunk := reg.materialise(id)
	var before := w.get_alive_block_count(chunk)
	var drawn := reg.draw_room(id, index)
	_ok("a drawn room draws its items", drawn > 0 and room.drawn, "%d items" % drawn)
	_ok("one box an item", room.drawn_boxes.size() == room.items.size(),
			"%d boxes, %d items" % [room.drawn_boxes.size(), room.items.size()])
	_ok("and lays nothing", w.get_alive_block_count(chunk) == before)
	_ok("nor opens anything", not room.active and reg.room_report().active == 0)
	_ok("drawing it twice does nothing", reg.draw_room(id, index) == 0)
	_ok("the registry knows it is drawn", reg.room_report().drawn == 1
			and reg.drawn_rooms_of(id).size() == 1)

	# Every part as a box, in the chunk's own metres -- which is exactly what
	# the blocks will say about themselves once they are laid.
	var drawn_parts := {}
	var buf := room.drawn_buffer
	@warning_ignore("integer_division")
	var parts: int = buf.size() / FurnitureMesh.STRIDE
	for k in parts:
		var o := k * FurnitureMesh.STRIDE
		var size := Vector3(buf[o], buf[o + 5], buf[o + 10])
		var mid := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
		drawn_parts[_box_key(mid - size * 0.5, size)] = true
	var boxes := room.drawn_boxes.duplicate()

	var placed := reg.activate_room(id, index)
	_ok("promoting it lays the bricks", placed > 0 and room.active, "%d blocks" % placed)
	_ok("and stops drawing it", not room.drawn and room.drawn_buffer.is_empty()
			and reg.drawn_rooms_of(id).is_empty() and reg.room_report().drawn == 0)
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
	# And every item's box covers what that item laid.
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
	_ok("and each item's box covers its bricks", covered)

	# Back down the ladder, keeping the diff.
	var victim := -1
	for i in room.items.size():
		if not (room.items[i].get("blocks", PackedInt32Array()) as PackedInt32Array).is_empty():
			victim = i
			break
	w.kill_blocks(chunk, room.items[victim].blocks)
	reg.deactivate_room(id, index)
	var redrawn := reg.draw_room(id, index)
	_ok("drawn again after closing, without what was destroyed",
			room.gone.has(victim) and redrawn == room.items.size() - room.gone.size(),
			"%d drawn, %d gone of %d" % [redrawn, room.gone.size(), room.items.size()])

	# A blast nobody is watching writes a drawn room off rather than laying it.
	var b := reg.get_building(id)
	var mid: Vector3 = b.xform * (room.local_box().position + room.local_box().size * 0.5)
	reg.compromise_rooms(id, mid, 1.0, false)
	_ok("an unwatched blast undraws it and writes it all off",
			not room.drawn and not room.active and room.gone.size() == room.items.size())

	# And a watched one promotes it, and says so.
	var other := -1
	for r in reg.rooms_of(id):
		if r.id != index and not RoomManifest.items_for(r).is_empty():
			other = r.id
			break
	_ok("there is a second furnished room", other >= 0)
	if other < 0:
		return
	var room2 := reg.get_room(id, other)
	reg.draw_room(id, other)
	var mid2: Vector3 = b.xform * (room2.local_box().position + room2.local_box().size * 0.5)
	reg.compromise_rooms(id, mid2, 1.0, true)
	_ok("a watched blast promotes a drawn room, and marks it hit",
			room2.active and not room2.drawn and room2.hit)
	reg.deactivate_room(id, other)
	_ok("which closing clears", not room2.hit)

	# A topple: a drawn room has no bricks to ride the fall, so it spills.
	reg.draw_room(id, other)
	reg.mark_rooms_spilled(id)
	_ok("a building coming down spills its drawn rooms",
			room2.spilled and not room2.drawn and reg.room_report().drawn == 0)
	_ok("and a spilled room will not draw", reg.draw_room(id, other) == 0)


## What floated, found by --interior-audit, and what stops it now.
func _check_nothing_stands_on_air() -> void:
	print("\nno furniture stands on nothing")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	# A building with a stairwell, placed as the city places one: a shaft ten
	# studs across with no floor in it on any storey.
	var id := reg.register(44, 34, 78, Transform3D())
	reg.add_fixture(id, "staircase", {"steps": StaircaseRecipe.steps_for_courses(78),
			"colour": 11}, Vector3i(12, TowerRecipe.SLAB_PLATES, 12))
	var chunk := reg.materialise(id)
	var shaft := Rect2i(12, 12, StaircaseRecipe.DIAMETER, StaircaseRecipe.DIAMETER)
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
			if not RoomManifest.item_supported(w, chunk, str(item.type), cell):
				on_air += 1
	_ok("nothing is generated in the stairwell", in_shaft == 0,
			"%d of %d items" % [in_shaft, items])
	_ok("and everything generated has a floor under it", on_air == 0,
			"%d of %d items" % [on_air, items])

	# Take a floor away from under a room nobody has opened: drawing it and
	# opening it both leave what stood there out, and write it off.
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	room.items = RoomManifest.items_for(room)
	var victim: Dictionary = room.items[0]
	var span0 := RoomManifest._item_span(str(victim.type))
	var cell0: Vector3i = victim.cell
	var under := PackedInt32Array()
	for x in span0.x:
		for z in span0.z:
			var bid := w.block_at(chunk, Vector3i(cell0.x + x, cell0.y - 1, cell0.z + z))
			if bid >= 0 and not under.has(bid):
				under.push_back(bid)
	w.kill_blocks(chunk, under)
	reg.draw_room(id, index)
	_ok("a drawn room leaves out an item whose floor is gone",
			room.gone.has(0) and room.drawn_boxes.size() == room.items.size() - room.gone.size(),
			"%d boxes, %d gone" % [room.drawn_boxes.size(), room.gone.size()])
	room.gone.clear()
	reg.activate_room(id, index)
	var laid_victim: PackedInt32Array = room.items[0].get("blocks", PackedInt32Array())
	_ok("and an opened one does not lay it", room.gone.has(0) and laid_victim.is_empty())

	# The building comes down with nobody inside: its untouched rooms are
	# written off rather than spilled into the wreck.
	var other := reg.register(44, 34, 78, Transform3D(Basis(), Vector3(40, 0, 0)))
	reg.materialise(other)
	reg.draw_room(other, _furnished_room(reg, other))
	var written := reg.write_off_rooms(other)
	var all_gone := true
	for r in reg.rooms_of(other):
		all_gone = all_gone and (RoomManifest.item_count_for(r) == 0 or r.is_changed())
	_ok("a building coming down writes its untouched rooms off",
			written > 0 and all_gone and reg.spilled_rooms(other).is_empty()
			and reg.get_building(other).drawn_rooms.is_empty())


static func _box_key(lo: Vector3, size: Vector3) -> String:
	return "%.3f,%.3f,%.3f/%.3f,%.3f,%.3f" % [lo.x, lo.y, lo.z, size.x, size.y, size.z]


func _check_the_diff() -> void:
	print("\nand what happened to it is all that is kept")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	var chunk := reg.materialise(id)
	reg.activate_room(id, index)

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
	reg.deactivate_room(id, index)
	_ok("the diff remembers it is gone", room.gone.has(which))
	_ok("and remembers nothing else", room.gone.size() == 1, "%d entries" % room.gone.size())

	var again := reg.activate_room(id, index)
	_ok("opening it again brings back what is left", again > 0)
	_ok("but not what was destroyed",
			(room.items[which].get("blocks", PackedInt32Array()) as PackedInt32Array).is_empty())


func _check_compromised() -> void:
	print("\na room in a damage volume resolves whether or not anyone is there")
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
	_ok("a blast nowhere near it leaves it shut",
			reg.compromise_rooms(id, far, 2.0) == 0 and not room.active)
	_ok("a blast inside it opens it", reg.compromise_rooms(id, mid, 2.0) > 0 and room.active)

	# And then the hit lands on contents that are actually there.
	var chunk := b.chunk
	var before := w.get_alive_block_count(chunk)
	reg.damage(id, mid, 2.0)
	_ok("so the damage reaches them", w.get_alive_block_count(chunk) < before)


func _check_the_analytic_resolve() -> void:
	print("\nand a room that fell over resolves rather than simulating")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	var chunk := reg.materialise(id)

	_ok("upright, down is down",
			RoomManifest.down_axis(Transform3D()) == Vector3i(0, -1, 0))
	var on_its_side := Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO)
	_ok("on its side, down is one of the other five",
			RoomManifest.down_axis(on_its_side) != Vector3i(0, -1, 0),
			"%v" % RoomManifest.down_axis(on_its_side))
	_ok("upside down, down is up",
			RoomManifest.down_axis(Transform3D(Basis(Vector3.FORWARD, PI), Vector3.ZERO))
			== Vector3i(0, 1, 0))

	# An item in an upright room stays where it was authored; the same item in a
	# room lying on its side is against the new floor instead.
	var items := RoomManifest.items_for(room)
	var upright := RoomManifest.resolved_cell(room, items[0], Vector3i(0, -1, 0), 0)
	var toppled := RoomManifest.resolved_cell(room, items[0],
			RoomManifest.down_axis(on_its_side), 0)
	_ok("upright, it is where it was put", upright == (items[0].cell as Vector3i))
	_ok("fallen, it has moved to the new floor", toppled != upright,
			"%v vs %v" % [toppled, upright])
	_ok("and it is still inside the room",
			toppled.x >= room.lo.x and toppled.x <= room.lo.x + room.size.x
			and toppled.y >= room.lo.y and toppled.y <= room.lo.y + room.size.y
			and toppled.z >= room.lo.z and toppled.z <= room.lo.z + room.size.z,
			"%v in %v + %v" % [toppled, room.lo, room.size])

	# Deterministic: the same room resolves the same way every time, which is
	# what makes the second visit identical to the first.
	var twice := RoomManifest.resolved_cell(room, items[0],
			RoomManifest.down_axis(on_its_side), 0)
	_ok("and it resolves the same way every time", twice == toppled)

	# Through the registry, into a chunk that has been turned over.
	w.set_chunk_transform(chunk, on_its_side)
	var placed := reg.activate_room(id, index, chunk)
	_ok("a fallen room still produces its contents", placed > 0, "%d blocks" % placed)


func _check_the_spill() -> void:
	print("\nand a room that came down spills what was in it")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var id := _tower(reg)
	var index := _furnished_room(reg, id)
	var room := reg.get_room(id, index)
	var chunk := reg.materialise(id)

	# It came down without anybody opening it.
	_ok("nothing is open when the building falls", not room.active)
	var marked := reg.mark_rooms_spilled(id)
	_ok("every shut room is marked spilled", marked == reg.rooms_of(id).size(),
			"%d of %d" % [marked, reg.rooms_of(id).size()])
	_ok("including this one", room.spilled)
	_ok("and nothing was built to do it",
			room.items.is_empty() or _laid(room) == 0)

	# The bricks are an island now. Somebody walks up to the pile.
	reg.hand_over(id)
	_ok("the building is gone, the chunk is not",
			not reg.get_building(id).is_materialised() and w.is_chunk_alive(chunk))
	var before := w.get_alive_block_count(chunk)
	var placed := reg.spill_room(id, index, chunk, 4)
	_ok("its contents are in the wreck", placed > 0, "%d blocks" % placed)
	_ok("which is where the wreck is", w.get_alive_block_count(chunk) > before)
	_ok("and the room is no longer waiting to spill", not room.spilled)

	# Damaged, not intact: that is the difference between spilling a room and
	# furnishing one.
	var dead := {}
	for gone_id in w.get_dead_blocks(chunk):
		dead[gone_id] = true
	var broken := 0
	var whole := 0
	for item in room.items:
		for block in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
			if dead.has(block):
				broken += 1
			else:
				whole += 1
	_ok("some of it is broken", broken > 0, "%d broken, %d whole" % [broken, whole])
	_ok("and some of it is not", whole > 0, "%d whole" % whole)

	# Capped: four items in full, the rest written off as rubble.
	var laid_items := 0
	for item in room.items:
		if not (item.get("blocks", PackedInt32Array()) as PackedInt32Array).is_empty():
			laid_items += 1
	_ok("at most the budget was laid in full", laid_items <= 4, "%d items" % laid_items)

	# Deterministic: the same wreck twice.
	var again := _world()
	var reg2 := BuildingRegistry.new(again[0], again[1])
	var id2 := _tower(reg2)
	var chunk2 := reg2.materialise(id2)
	reg2.mark_rooms_spilled(id2)
	reg2.hand_over(id2)
	var placed2 := reg2.spill_room(id2, index, chunk2, 4)
	_ok("spilling the same room twice gives the same wreck", placed2 == placed,
			"%d against %d blocks" % [placed2, placed])
	var dead2: int = (again[0] as BrickWorld).get_dead_blocks(chunk2).size()
	_ok("broken in the same places", dead2 == w.get_dead_blocks(chunk).size(),
			"%d against %d" % [dead2, w.get_dead_blocks(chunk).size()])

	# A kitchen spills kitchen things (section 4.1): what came out is what the
	# manifest said would be in there, not generic debris.
	var allowed: Array = RoomManifest.BY_KIND.get(room.kind, [])
	var foreign := 0
	for item in room.items:
		if not allowed.has(str(item.type)):
			foreign += 1
	_ok("and it spilled its own things, not somebody's", foreign == 0,
			"%s room, %d foreign" % [room.kind, foreign])


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

	var placed := reg.activate_room(id, index)
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
	reg.activate_room(id, index)
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
