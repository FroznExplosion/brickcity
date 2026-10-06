extends SceneTree

## Interiors drawn a group of storeys at a time (InteriorGroups;
## Docs/Interiors.md section 8.2). The parts that need no city round them:
##
##   * how a building is cut into groups -- every storey in exactly one, none
##     bigger than asked, no stub of a group left over;
##   * a group's drawing is every interior piece of every room in it, the same
##     rows the drawn rung works out room by room, and nothing twice;
##   * it is worked out a few rooms at a time under a clock;
##   * a change in one group's storeys works that group out again and leaves
##     the others exactly as they were (the reason for groups at all: a tower
##     is not redrawn for one shot);
##   * a piece whose floor has gone, and a room laid as bricks, leave it;
##   * the small things (BuildRecipe.Role.DETAIL) are a drawing of their own.
##
## What needs the city -- ranges, fades, the collapse rules, collision -- is the
## scene's gate: `scenes/big_city.tscn -- --groups`.

var passed := 0
var failed := 0


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  ok   %s%s" % [what, (" -- " + detail) if detail else ""])
	else:
		failed += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	print("interiors by storey group")
	_check_cut()
	_check_building()
	_check_details()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _check_cut() -> void:
	print("\nhow a building is cut")
	var bad := ""
	for storeys in range(1, 61):
		for span in range(1, 7):
			var pairs: Array = InteriorGroups.cut(storeys, span)
			var at := 0
			var smallest := 1 << 30
			var biggest := 0
			for p in pairs:
				if int(p[0]) != at or int(p[1]) <= int(p[0]):
					bad = "%d storeys by %d: %s" % [storeys, span, pairs]
				at = int(p[1])
				smallest = mini(smallest, int(p[1]) - int(p[0]))
				biggest = maxi(biggest, int(p[1]) - int(p[0]))
			if at != storeys or biggest > span or biggest - smallest > 1:
				bad = "%d storeys by %d: %s" % [storeys, span, pairs]
	_ok("every storey in one group, none over the span, none a stub", bad == "", bad)
	_ok("a building shorter than a group is one group",
			InteriorGroups.cut(3, InteriorGroups.GROUP_STOREYS).size() == 1)
	var five: Array = InteriorGroups.cut(5, 4)
	_ok("five storeys in fours is two and three, not four and one",
			five.size() == 2 and absi((int(five[0][1]) - int(five[0][0])) - (int(five[1][1]) - int(five[1][0]))) == 1,
			str(five))
	_ok("today's floors (4 and 6 rooms) take the most storeys a group may have",
			InteriorGroups.storeys_per_group(4) == InteriorGroups.GROUP_STOREYS
			and InteriorGroups.storeys_per_group(6) == InteriorGroups.GROUP_STOREYS)
	_ok("a floor of a hundred rooms is a group to itself, and never none",
			InteriorGroups.storeys_per_group(100) == 1 and InteriorGroups.storeys_per_group(100000) == 1,
			"%d storeys for 30 rooms a floor" % InteriorGroups.storeys_per_group(30))


## A tower of ten storeys, bricks, with its groups and a second copy of its
## rooms to work the answer out from independently.
func _check_building() -> void:
	print("\na tower's groups")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(40, 30, 60, Transform3D.IDENTITY)
	var b := reg.get_building(id)
	reg.materialise(id)
	var groups := InteriorGroups.new()
	groups.world = w
	groups.registry = reg
	var layout: Array = groups.layout(b)
	var rooms := reg.rooms_of(id)
	var owner := {}
	var twice := 0
	var outside := 0
	for g in layout:
		for index in range(g.first_room, g.last_room):
			if owner.has(index):
				twice += 1
			owner[index] = g.index
			var rb: AABB = rooms[index].local_box()
			if rb.position.y < g.box.position.y - 0.01 or rb.end.y > g.box.end.y + 0.01:
				outside += 1
	_ok("every room is in one group, inside its storeys",
			owner.size() == rooms.size() and twice == 0 and outside == 0,
			"%d groups for %d rooms on %d storeys; %d twice, %d outside" % [
				layout.size(), rooms.size(), layout[layout.size() - 1].last_storey, twice, outside])

	# The same rooms again, worked out the way the drawn rung does: one at a time.
	var reg2 := BuildingRegistry.new(w, palette)
	var id2 := reg2.register(40, 30, 60, Transform3D.IDENTITY)
	var want_rows := {}   # group -> floats
	var want_pieces := 0
	for room in reg2.rooms_of(id2):
		room.items = RoomManifest.items_for(room)
		var d := RoomManifest.draw_items(w, b.chunk, palette, room, Vector3i.ZERO)
		var gi: int = owner[room.id]
		want_rows[gi] = int(want_rows.get(gi, 0)) + (d.buffer as PackedFloat32Array).size()
		want_pieces += (d.boxes as Array).size()

	# Under a clock that has already run out: one room a call, and it gets there.
	var g0: InteriorGroups.Group = layout[0]
	var calls := 0
	while not groups.work(b, g0, 0) and calls < 1000:
		calls += 1
	_ok("with no time left a call still works one room out, and no more",
			calls + 1 == g0.last_room - g0.first_room,
			"%d calls for %d rooms" % [calls + 1, g0.last_room - g0.first_room])
	var far := Time.get_ticks_usec() + 60000000
	var parent := Node3D.new()
	root.add_child(parent)
	var rows_ok := true
	var pieces := 0
	var total := 0
	for g in layout:
		groups.work(b, g, far)
		groups.attach(b, g, parent)
		var got := 0
		for buf in g.pieces:
			got += (buf as PackedFloat32Array).size()
		for boxes in g.boxes:
			pieces += (boxes as Array).size()
		total += got
		var node := groups.piece_node(id, g.index)
		var on_screen: int = node.multimesh.instance_count * FurnitureMesh.STRIDE if node != null else 0
		if got != int(want_rows.get(g.index, 0)) or on_screen != got:
			rows_ok = false
	_ok("a group draws every interior piece of its rooms, once",
			rows_ok and total > 0 and pieces == want_pieces,
			"%d box(es) for %d piece(s) in %d group(s)" % [
				total / FurnitureMesh.STRIDE, pieces, layout.size()])
	var clean := true
	for g in layout:
		if g.dirty or g.changed or not g.shown:
			clean = false
	_ok("and is then up to date: nothing to work out, nothing to redraw", clean)
	var before_worked := groups.rooms_worked
	for g in layout:
		groups.work(b, g, far)
	_ok("asked again with nothing changed, no room is worked out",
			groups.rooms_worked == before_worked)

	# One piece's floor goes, in the top group. Only that group is worked out
	# again; every other group's rows are the same floats they were.
	var top: InteriorGroups.Group = layout[layout.size() - 1]
	var victim := AABB()
	var victim_room := -1
	for k in top.boxes.size():
		if not (top.boxes[k] as Array).is_empty():
			victim = top.boxes[k][0]
			victim_room = top.first_room + k
			break
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = w.get_chunk_origin(b.chunk)
	var foot := Vector3i(roundi(victim.position.x / cs.x), roundi(victim.position.y / cs.y),
			roundi(victim.position.z / cs.z)) + origin
	var under := PackedInt32Array()
	for x in maxi(roundi(victim.size.x / cs.x), 1):
		for z in maxi(roundi(victim.size.z / cs.z), 1):
			var blk: int = w.block_at(b.chunk, Vector3i(foot.x + x, foot.y - 1, foot.z + z))
			if blk >= 0 and not under.has(blk):
				under.push_back(blk)
	w.kill_blocks(b.chunk, under)
	var stamps := []
	var copies := []
	for g in layout:
		stamps.append(g.struct_stamp)
		copies.append(g.pieces.duplicate(true))
	var y := victim.position.y
	groups.touch(id, y - 0.3, y + 0.3)
	var touched := 0
	for g in layout:
		if g.struct_stamp != stamps[g.index]:
			touched += 1
	_ok("a change at one height reaches the group there, not the building",
			top.dirty and touched >= 1 and touched <= 2 and touched < layout.size(),
			"%d of %d group(s) asked again" % [touched, layout.size()])
	var worked0 := groups.rooms_worked
	for g in layout:
		if g.dirty:
			groups.work(b, g, far)
			if g.changed:
				groups.attach(b, g, parent)
	var others_same := true
	for g in layout:
		if g == top:
			continue
		if g.pieces != copies[g.index]:
			others_same = false
	var top_rows := 0
	for buf in top.pieces:
		top_rows += (buf as PackedFloat32Array).size()
	var room: Room = rooms[victim_room]
	_ok("the piece whose floor went is gone from its group and from its room's record",
			not room.gone.is_empty() and top_rows < int(want_rows.get(top.index, 0))
			and groups.piece_node(id, top.index).multimesh.instance_count * FurnitureMesh.STRIDE == top_rows,
			"%d floor brick(s) killed; %d of %d box(es) left; %d room(s) worked out again" % [
				under.size(), top_rows / FurnitureMesh.STRIDE,
				int(want_rows.get(top.index, 0)) / FurnitureMesh.STRIDE, groups.rooms_worked - worked0])
	_ok("and every other group's drawing is what it was", others_same)

	# A room laid as bricks (a blast reached it) is drawn from its bricks, not
	# by its group; taken back out, it is the group's again.
	var laid_room := -1
	for index in range(g0.first_room, g0.last_room):
		if not (g0.pieces[index - g0.first_room] as PackedFloat32Array).is_empty():
			laid_room = index
			break
	var rows_before := (g0.pieces[laid_room - g0.first_room] as PackedFloat32Array).size()
	var placed := reg.activate_room(id, laid_room)
	groups.room_changed(id, laid_room)
	groups.work(b, g0, far)
	var rows_laid := (g0.pieces[laid_room - g0.first_room] as PackedFloat32Array).size()
	reg.deactivate_room(id, laid_room)
	groups.room_changed(id, laid_room)
	groups.work(b, g0, far)
	var rows_back := (g0.pieces[laid_room - g0.first_room] as PackedFloat32Array).size()
	_ok("a room laid as bricks leaves its group's drawing, and comes back when it is taken out",
			placed > 0 and rows_before > 0 and rows_laid == 0 and rows_back == rows_before,
			"%d brick(s) laid; %d, %d, %d floats" % [placed, rows_before, rows_laid, rows_back])

	# A section leaving: what stood in its box stops being drawn at once.
	var mid: InteriorGroups.Group = layout[layout.size() / 2]
	var shown_before := _shown(groups.piece_node(id, mid.index))
	var hid := groups.hide_inside(id, [mid.box.grow(0.05)] as Array[AABB])
	_ok("everything standing in a box that leaves is hidden at once, and that group asked again",
			shown_before > 0 and hid == shown_before and _shown(groups.piece_node(id, mid.index)) == 0
			and mid.dirty,
			"%d of %d hidden" % [hid, shown_before])

	groups.release(id, top)
	_ok("a group let go draws nothing and keeps nothing",
			not top.shown and groups.piece_node(id, top.index) == null and top.pieces.is_empty())
	groups.drop(id)
	_ok("and a building let go has no groups", groups.known(id).is_empty())
	parent.queue_free()


## The small things: an authored item with a DETAIL part on it. The part is a
## row of the group's ITEM drawing and no part of its interior drawing or its
## collision box.
func _check_details() -> void:
	print("\nitems")
	RoomTemplates.items_for_kind("office")   # read what is on disk first
	var cup := BuildRecipe.new()
	cup.meta["room_kind"] = "office"
	cup.add("brick_2x2", Vector3i(0, 0, 0), 3, 0, BuildRecipe.Role.INTERIOR)
	cup.add("brick_1x1", Vector3i(0, 3, 0), 5, 0, BuildRecipe.Role.DETAIL)
	var type := RoomTemplates.add_item("probe_stand", cup)
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(40, 30, 60, Transform3D.IDENTITY, {"office": 1})
	var b := reg.get_building(id)
	reg.materialise(id)
	var groups := InteriorGroups.new()
	groups.world = w
	groups.registry = reg
	var parent := Node3D.new()
	root.add_child(parent)
	var stands := 0
	var item_rows := 0
	var piece_rows := 0
	var boxes := 0
	var want_piece_parts := 0
	for g in groups.layout(b):
		groups.work(b, g, Time.get_ticks_usec() + 60000000)
		groups.attach(b, g, parent)
		for buf in g.items:
			item_rows += (buf as PackedFloat32Array).size() / FurnitureMesh.STRIDE
		for buf in g.pieces:
			piece_rows += (buf as PackedFloat32Array).size() / FurnitureMesh.STRIDE
		for bx in g.boxes:
			boxes += (bx as Array).size()
		var node := groups.item_node(id, g.index)
		if node != null and node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			stands = -1000000
	for room in reg.rooms_of(id):
		for i in room.items.size():
			if room.gone.has(i):
				continue
			var it: Dictionary = room.items[i]
			if str(it.type) == type:
				stands += 1
			for part in RoomManifest.parts_of(str(it.type)):
				if not RoomManifest.is_detail(part):
					want_piece_parts += 1
	_ok("each DETAIL part is one row of the item drawing, which casts no shadow",
			stands > 0 and item_rows == stands,
			"%d stand(s) in the tower, %d item row(s)" % [stands, item_rows])
	_ok("and no part of the interior drawing", piece_rows == want_piece_parts,
			"%d interior box(es) for %d interior part(s)" % [piece_rows, want_piece_parts])
	_ok("the two drawings fade at their own ranges",
			float(InteriorGroups.piece_material().get_shader_parameter("fade_range")) == InteriorGroups.INTERIOR_RANGE
			and float(InteriorGroups.item_material().get_shader_parameter("fade_range")) == InteriorGroups.ITEM_RANGE
			and InteriorGroups.ITEM_RANGE < InteriorGroups.INTERIOR_RANGE)
	parent.queue_free()
	RoomTemplates.reload()


## Boxes of a furniture MultiMesh that are still shown (not scaled to nothing).
func _shown(node: MultiMeshInstance3D) -> int:
	if node == null or node.multimesh == null:
		return 0
	var buffer: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array())
	var n := 0
	for i in buffer.size() / FurnitureMesh.STRIDE:
		var at := i * FurnitureMesh.STRIDE
		if absf(buffer[at]) + absf(buffer[at + 5]) + absf(buffer[at + 10]) > 0.0001:
			n += 1
	return n
