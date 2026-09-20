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
##   §4.2 items ride the island the floor they stand on rides
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
	_check_the_diff()
	_check_compromised()
	_check_the_analytic_resolve()
	_check_the_spill()
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


## The first room with something in it -- some are generated empty on purpose.
func _furnished_room(reg: BuildingRegistry, id: int) -> int:
	for r in reg.rooms_of(id):
		if not RoomManifest.items_for(r).is_empty():
			return r.id
	return -1
