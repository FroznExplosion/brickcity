extends SceneTree

## Furniture and items placed in a game world (F6, WorldFurnisher): into a
## generated building's room as one of its items, into a player build as its
## bricks, outdoors as a prop (OutdoorProps) drawn by distance and bricks once
## a blast reaches it. Docs/AssetWorkshop.md, "Furniture and items".
##
##     godot --headless --path . --script tools/world_furnish_probe.gd

var _pass := 0
var _fail := 0
const DIR := "user://_probe_world_items/"


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _initialize() -> void:
	_make_assets()
	var w := BrickWorld.new()
	var reg := BuildingRegistry.new(w, TowerRecipe.bake_palette(w))
	var props := OutdoorProps.new()
	root.add_child(props)
	props.setup(StandardMaterial3D.new(), StandardMaterial3D.new())
	var f := WorldFurnisher.new()
	root.add_child(f)
	f.setup(reg, null, props)
	await process_frame
	AssetCatalog.use_dir(DIR)
	RoomTemplates.reload()
	_catalogue(f)
	_rooms(f, reg)
	_build(f, reg, w)
	_outdoor(f, reg, props)
	for fn in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR + fn)
	DirAccess.remove_absolute(DIR)
	DirAccess.remove_absolute("user://_probe_world_catalog.json")
	AssetCatalog.use_dir("")
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## A 2x4 table, 4 plates high (furniture), and a 1x1 cup (item), both Earth.
func _make_assets() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var table := BuildRecipe.new()
	table.kind = "item"
	table.name = "Probe Table"
	table.add("brick_2x4_x", Vector3i(0, 0, 0), 2, 0, BuildRecipe.Role.STRUCTURE)
	table.add("plate_2x4_x", Vector3i(0, 3, 0), 3, 0, BuildRecipe.Role.STRUCTURE)
	table.meta = {"tags": {"planet": ["earth"], "type": ["furniture"], "room": []}}
	table.save_to(DIR + "probe_table.json")
	var cup := BuildRecipe.new()
	cup.kind = "item"
	cup.name = "Probe Cup"
	cup.add("brick_1x1", Vector3i(0, 0, 0), 6, 0, BuildRecipe.Role.DETAIL)
	cup.meta = {"tags": {"planet": [], "type": ["item"], "room": []}}
	cup.save_to(DIR + "probe_cup.json")


func _catalogue(f: WorldFurnisher) -> void:
	print("[probe] the catalogue in a world")
	f.panel.save_path = "user://_probe_world_catalog.json"
	f.open(true)
	_ok("F6 opens it filtered to the planet underfoot", f.is_open() and f.panel.filter.planet == ["earth"])


## A 20x20 tower: a room on its second storey, aimed at from inside, straight down.
func _rooms(f: WorldFurnisher, reg: BuildingRegistry) -> void:
	print("[probe] in a room of a generated building")
	var id := reg.register(20, 20, 18, Transform3D(Basis(), Vector3(8.0, 0.0, -3.0)))
	var b := reg.get_building(id)
	var rooms := reg.rooms_of(id)
	# A room upstairs with a clear patch of floor: no generated piece or
	# column in a 4x4 of it.
	var ri := -1
	var spot := Vector2i(-1, -1)
	for i in rooms.size():
		if rooms[i].lo.y <= 0:
			continue
		if rooms[i].items.is_empty():
			rooms[i].items = RoomManifest.items_for(rooms[i])
		spot = _free_spot(rooms[i], Vector2i(4, 4))
		if spot != Vector2i(-1, -1):
			ri = i
			break
	_ok("a room upstairs with clear floor to furnish", ri >= 0, "%d rooms" % rooms.size())
	if ri < 0:
		return
	var room: Room = rooms[ri]
	var before := room.items.size()
	var stamp := room.diff_stamp()
	var cs := BrickWorld.get_cell_size()
	var over := Vector3((spot.x + 1.5) * cs.x, (room.lo.y + 10) * cs.y, (spot.y + 1.5) * cs.z)
	f.hold("probe_table")
	f.aim_ray(b.xform * over, Vector3.DOWN)
	_ok("aimed at its floor: the room, on its floor, fits", f.target.get("kind") == "room"
			and f.target.room == room and (f.target.at as Vector3i).y == room.lo.y and f.target.ok,
			str(f.target.get("at")) + " " + str(f.target.get("ok")))
	_ok("placed", f.place())
	_ok("as one more of the room's own items", room.items.size() == before + 1
			and str(room.items[before].type) == "item:probe_table@0"
			and room.items[before].cell == f.target.at)
	_ok("its drawing is told (the room's stamp moved)", room.diff_stamp() != stamp)
	_ok("its parts are the table's", RoomManifest.parts_of(str(room.items[before].type)).size() == 2)
	f.hold("probe_cup")
	f.aim_ray(b.xform * over, Vector3.DOWN)
	_ok("aimed there again: on the table's top", f.target.get("kind") == "room"
			and (f.target.at as Vector3i).y == room.lo.y + 4 and f.target.ok, str(f.target.get("at")))
	_ok("the cup placed on it", f.place() and room.items.size() == before + 2)
	f.hold("probe_table")
	f.target = {"kind": "room", "b": b, "room": room}
	_ok("into the table's cells does not fit", not f._fits(room.items[before].cell, Vector3i(2, 4, 4)))
	_ok("nor through the room's wall", not f._fits(room.lo + Vector3i(room.size.x - 1, 0, 0), Vector3i(2, 4, 4)))
	_ok("Backspace takes the cup back", f.take_back() and room.items.size() == before + 1)

	# Laid when hit: the placed table becomes bricks in the building's chunk,
	# exactly as a generated piece does.
	var chunk := reg.materialise(id)
	var laid := reg.lay_item(id, ri, before)
	_ok("laid as bricks when hit, like the generator's own", chunk >= 0 and laid == 2, "%d" % laid)
	_ok("and it is not taken back once it is the world's", not f.take_back()
			and room.items.size() == before + 1)


func _free_spot(room: Room, span: Vector2i) -> Vector2i:
	var cs := BrickWorld.get_cell_size()
	for x in range(room.lo.x, room.lo.x + room.size.x - span.x):
		for z in range(room.lo.z, room.lo.z + room.size.z - span.y):
			var plan := Rect2i(x, z, span.x, span.y)
			var clear := true
			for post in room.posts:
				clear = clear and not (post as Rect2i).intersects(plan)
			var mine := AABB(Vector3(x, room.lo.y, z) * cs, Vector3(span.x, 20, span.y) * cs)
			for item in room.items:
				clear = clear and not mine.intersects(RoomManifest.item_box(item))
			if clear:
				return Vector2i(x, z)
	return Vector2i(-1, -1)


## A player build: a 6x6 slab of plates. The ground ray stands for the physics
## hit on its top.
func _build(f: WorldFurnisher, reg: BuildingRegistry, w: BrickWorld) -> void:
	print("[probe] in a player build")
	var r := BuildRecipe.new()
	for x in range(0, 6, 2):
		for z in range(0, 6, 2):
			r.add("plate_2x2", Vector3i(x, 0, z), 1)
	# A post in a corner, so the build's box has room over the slab.
	for y in range(1, 13, 3):
		r.add("brick_1x1", Vector3i(5, y, 5), 1)
	var at := Vector3(30.0, 0.0, 30.0)
	var id := reg.register_build(r, Transform3D(Basis(), at))
	var chunk := reg.materialise(id)
	var b := reg.get_building(id)
	var cs := BrickWorld.get_cell_size()
	var top := b.xform * Vector3(1.0 * cs.x + 0.1, 1.0 * cs.y, 1.0 * cs.z + 0.1)
	f.ground_ray = func(_from: Vector3, _dir: Vector3) -> Vector3: return top
	var alive := w.get_alive_block_count(chunk)
	f.hold("probe_table")
	f.aim_ray(top + Vector3.UP * 3.0, Vector3.DOWN)
	_ok("aimed at its floor: the build, on the plate", f.target.get("kind") == "build"
			and (f.target.at as Vector3i).y == 1 and f.target.ok, str(f.target))
	var laid := []
	f.build_furnished = func(_id: int, blocks: PackedInt32Array) -> void: laid.append(blocks.size())
	_ok("placed as bricks in its chunk", f.place() and w.get_alive_block_count(chunk) == alive + 2
			and laid == [2])
	_ok("decorative (furniture weighs nothing)", w.get_decorative_blocks(chunk).size() == 2)
	_ok("Backspace takes them out", f.take_back() and w.get_alive_block_count(chunk) == alive)
	f.ground_ray = Callable()


## Outdoors: on the ground (the plane y = 0 here), clear of buildings.
func _outdoor(f: WorldFurnisher, reg: BuildingRegistry, props: OutdoorProps) -> void:
	print("[probe] outdoors")
	var cs := BrickWorld.get_cell_size()
	f.hold("probe_table")
	var spot := Vector3(-40.3, 5.0, 60.2)
	f.aim_ray(spot, Vector3.DOWN)
	_ok("aimed at open ground: outdoors, on it, fits", f.target.get("kind") == "outdoor"
			and (f.target.at as Vector3i).y == 0 and f.target.ok, str(f.target))
	_ok("placed as a prop", f.place() and props.props.size() == 1)
	var t := OutdoorProps.tile_of(props.props[0].cell)
	var st := props.tile_stats(t)
	_ok("drawn in its tile (bricks and studs) with one box", st.drawings == 2 and st.shapes == 1, str(st))
	var drawn: MultiMeshInstance3D = props._tiles[t].node.get_child(0)
	_ok("drawn only to the furniture range, fading", is_equal_approx(drawn.visibility_range_end,
			OutdoorProps.FURNITURE_RANGE) and drawn.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF)
	f.aim_ray(spot, Vector3.DOWN)
	_ok("the same spot again does not fit", not f.target.ok)
	f.hold("probe_cup")
	f.aim_ray(spot + Vector3(3.0, 0.0, 0.0), Vector3.DOWN)
	_ok("a cup beside it", f.target.ok and f.place() and props.props.size() == 2)
	var cup_tile := OutdoorProps.tile_of(props.props[1].cell)
	var cup_draw: MultiMeshInstance3D = null
	for c in props._tiles[cup_tile].node.get_children():
		if is_equal_approx((c as MultiMeshInstance3D).visibility_range_end, OutdoorProps.ITEM_RANGE):
			cup_draw = c
	_ok("an item is drawn to the item range only", cup_draw != null)
	f.hold("probe_table")
	f.aim_ray(Vector3(8.0 + 3.0, 5.0, -3.0 + 3.0), Vector3.DOWN)
	_ok("not into a building's box", f.target.get("kind") != "outdoor" or not f.target.ok)

	var made := []
	props.make_build = func(r: BuildRecipe, xf: Transform3D) -> int:
		var id := reg.register_build(r, xf)
		made.append(id)
		return id
	_ok("a blast away from them promotes nothing", props.promote_near(Vector3(200, 0, 200), 1.0).is_empty())
	var hit_at := props.box_of(0).get_center()
	var ids := props.promote_near(hit_at, 0.5)
	_ok("a blast at the table makes it a build of its own", ids.size() == 1 and made == ids
			and not props.props[0].alive and props.props[1].alive)
	var nb := reg.get_building(ids[0])
	_ok("of its bricks, as structure, where it stood", nb.build.size() == 2
			and nb.build.role_of(0) == BuildRecipe.Role.STRUCTURE
			and nb.xform.origin.is_equal_approx(BrickWorld.grid_to_world(props.props[0].cell)))
	_ok("and out of its tile's drawing and body", props.tile_stats(t).shapes == (1 if cup_tile == t else 0))
	_ok("Backspace takes the cup back", f.take_back() and not props.props[1].alive)
