extends SceneTree

## The workshop's second pass: menus, a build inside a build, a generated
## building you drag bigger, and the detail layer. Docs/Workshop.md.
##
##     godot --headless --path . --script tools/workshop_probe.gd
##
## Drives the real workshop scene through the functions its menus call, with
## exact rays where a mouse would be.

var _pass := 0
var _fail := 0
const STUD := 0.35
const PLATE := 0.14


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _initialize() -> void:
	_recipe_checks()
	_turn_checks()
	_flatten_checks()
	_template_checks()
	await _workshop_checks()
	RoomTemplates.reload()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------

func _recipe_checks() -> void:
	print("[probe] the recipe: v6 kind, meta, groups, towers, detail")
	var r := BuildRecipe.new()
	r.kind = "room"
	r.meta = {"room_kind": "office", "size": [10, 6, 10]}
	var a := r.add("brick_2x4_z", Vector3i(0, 1, 0), 4)
	var b := r.add("plate_2x2", Vector3i(0, 4, 0), 5, 0, BuildRecipe.Role.DETAIL)
	var c := r.add("plate_2x2", Vector3i(4, 1, 0), 5, 0, true)
	r.groups.append({"source": "x", "name": "x", "first": 1, "count": 2, "turn": 1,
			"offset": [1, 2, 3]})
	r.add_tower(Vector3i(2, 1, 2), TowerBlockout.defaults())
	_ok("detail is a role of its own", r.role_of(b) == BuildRecipe.Role.DETAIL)
	_ok("and detail is interior", r.is_interior(b) and r.detail_count() == 1)
	_ok("a bool still means interior", r.role_of(c) == BuildRecipe.Role.INTERIOR)
	_ok("structure by default", r.role_of(a) == BuildRecipe.Role.STRUCTURE)
	var back := BuildRecipe.from_dict(JSON.parse_string(JSON.stringify(r.to_dict())))
	_ok("kind round-trips", back.kind == "room")
	_ok("meta round-trips as integers", back.meta.get("room_kind") == "office"
			and typeof(back.meta.size[0]) == TYPE_INT)
	_ok("groups round-trip", back.groups.size() == 1 and int(back.groups[0].first) == 1
			and typeof(back.groups[0].first) == TYPE_INT)
	_ok("towers round-trip", back.towers.size() == 1
			and BuildRecipe.cell_from(back.towers[0].cell) == Vector3i(2, 1, 2))
	_ok("roles round-trip", back.role_of(b) == BuildRecipe.Role.DETAIL
			and back.role_of(c) == BuildRecipe.Role.INTERIOR)
	var old := {"version": 5, "name": "old", "parts": ["plate_2x2"], "cells": [0, 1, 0],
			"part_index": [0], "colours": [4], "interior": [1]}
	var o := BuildRecipe.from_dict(old)
	_ok("a v5 file is a building with no groups", o.kind == "building"
			and o.groups.is_empty() and o.size() == 1 and o.role_of(0) == 1)
	r.remove_at(1)
	_ok("removing a grouped block shrinks its group", int(r.groups[0].count) == 1
			and int(r.groups[0].first) == 1)
	r.remove_at(0)
	_ok("removing one before it moves it down", int(r.groups[0].first) == 0)


## A turn is a turn of the SHAPE, not only of the cells: a slope has to face
## down its own slope afterwards. Built both ways and compared cell by cell.
func _turn_checks() -> void:
	print("[probe] turning a build a quarter at a time")
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var r := BuildRecipe.new()
	r.add("brick_2x4_z", Vector3i(0, 0, 0), 4)
	r.add("slope_2x4_y0", Vector3i(0, 3, 0), 5)
	r.add("slope_2x2_y1", Vector3i(2, 0, 3), 6)
	r.add("brick_1x2_x", Vector3i(3, 0, 0), 7, 0, true)
	r.add("curve_1x2_y3", Vector3i(5, 0, 0), 8)
	var d: Vector3i = r.bounds()[1]
	var four := r.turned(1).turned(1).turned(1).turned(1)
	var same := four.size() == r.size()
	for i in r.size():
		same = same and four.cell_of(i) == r.cell_of(i) and four.part_of(i) == r.part_of(i)
	_ok("four quarter turns are no turn", same)
	_ok("a turn keeps the roles", r.turned(1).role_of(3) == BuildRecipe.Role.INTERIOR)
	for k in [1, 2, 3]:
		var t := r.turned(k)
		var ca := w.create_chunk(Vector3i.ZERO, d + Vector3i.ONE * 2)
		var cb := w.create_chunk(Vector3i.ZERO, Vector3i(maxi(d.x, d.z), d.y, maxi(d.x, d.z)) + Vector3i.ONE * 2)
		var na := r.build(w, ca, pal, true)
		var nb := t.build(w, cb, pal, true)
		var match_all := na == r.size() and nb == t.size()
		var solid := 0
		var dd := d
		for x in d.x:
			for y in d.y:
				for z in d.z:
					var p := Vector3i(x, y, z)
					if not w.is_solid(ca, p):
						continue
					solid += 1
					var q := p
					dd = d
					for s in k:
						q = Vector3i(dd.z - 1 - q.z, q.y, q.x)
						dd = Vector3i(dd.z, dd.y, dd.x)
					if not w.is_solid(cb, q):
						match_all = false
		_ok("turned %d: every solid cell lands where the turn sends it (%d cells)" % [k, solid],
				match_all and solid > 0, "%d/%d placed" % [nb, t.size()])
		w.release_chunk(ca)
		w.release_chunk(cb)
	var multi := BuildRecipe.new()
	multi.add("brick_2x4_z", Vector3i.ZERO, 4)
	multi.add_frame(3, Vector3i(0, 0, 0))
	multi.add("brick_2x4_z", Vector3i.ZERO, 4, 1)
	_ok("a multi-frame build refuses a turn", multi.turned(1) == null)
	_ok("but not no turn", multi.turned(0) != null)


func _flatten_checks() -> void:
	print("[probe] a generated building, flattened for the city")
	var r := BuildRecipe.new()
	r.add_tower(Vector3i(0, 1, 0), TowerBlockout.defaults())
	r.add("brick_2x2", Vector3i(100, 1, 100), 4)
	var flat := TowerBlockout.flatten(r)
	_ok("flatten turns the record into bricks", flat.towers.is_empty() and flat.size() > 200,
			"%d bricks" % flat.size())
	_ok("the author's own brick comes last", flat.part_of(flat.size() - 1) == "brick_2x2"
			and flat.cell_of(flat.size() - 1) == Vector3i(100, 1, 100))
	_ok("a recipe with nothing generated is itself", TowerBlockout.flatten(flat) == flat)
	var p := TowerBlockout.normalised({"x": 27, "z": 4, "courses": 13})
	_ok("sizes snap to whole panels and storeys", p.x == 30 and p.z == 20 and p.courses == 12)
	var lim := TowerBlockout.normalised({"x": 90, "z": 90, "courses": 600}, Vector3i(48, 120, 48))
	_ok("and stay inside a limit", lim.x == 40 and lim.z == 40
			and TowerBlockout.dims(lim).y <= 120, "%s" % lim)
	var no_rooms := TowerBlockout.normalised({"rooms": false, "windows": false, "stairs": false})
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var full := TowerBlockout.bricks(w, pal, TowerBlockout.normalised({}))
	var bare := TowerBlockout.bricks(w, pal, no_rooms)
	_ok("switching rooms, windows and stairs off lays a different building",
			bare.size() != full.size(), "%d vs %d" % [bare.size(), full.size()])
	var steps := 0
	for b in full:
		if str(b[0]).begins_with("spiral"):
			steps += 1
	_ok("stairs on puts a flight in it", steps > 0, "%d spiral pieces" % steps)
	# And it goes into a city like any other build.
	var cw := BrickWorld.new()
	var reg := BuildingRegistry.new(cw, TowerRecipe.bake_palette(cw))
	var id := reg.register_build(r, Transform3D())
	reg.materialise(id)
	var alive := 0
	for c in reg.get_building(id).chunks():
		alive += cw.get_alive_block_count(c)
	_ok("the city builds it from the record", alive >= flat.size() - 5,
			"%d of %d" % [alive, flat.size()])


## Authored rooms and items as the generator reads them, the detail rule, and a
## building's room mix. Docs/Workshop.md stages D, E, F.
func _template_checks() -> void:
	print("[probe] room templates, items, detail and the room mix")
	RoomTemplates.reload()
	RoomTemplates._loaded = true   # this probe's templates only, not the player's
	var t := BuildRecipe.new()
	t.kind = "room"
	t.meta = {"room_kind": "office"}
	t.add("brick_2x4_z", Vector3i(0, 1, 0), 2)                    # a wall stub: structure
	t.add("brick_1x1", Vector3i(4, 1, 4), 11, 0, true)            # table leg
	t.add("brick_1x1", Vector3i(7, 1, 4), 11, 0, true)
	t.add("plate_4x4", Vector3i(4, 4, 4), 5, 0, true)             # table top
	t.add("plate_1x1", Vector3i(5, 5, 5), 1, 0, BuildRecipe.Role.DETAIL)   # a cup on it
	t.add("brick_1x1", Vector3i(12, 1, 4), 6, 0, true)            # a stool, apart
	_ok("a room template registers", RoomTemplates.add_room("probe_office", t))
	var tpl := RoomTemplates.room_for("office", Vector3i(30, 19, 30), 0)
	_ok("its furniture is two pieces: table-with-cup and stool",
			(tpl.get("types", []) as Array).size() == 2, "%s" % [tpl.get("types")])
	_ok("the wall stub is not furniture", tpl.size.x == 9 and tpl.size.z == 4,
			"size %v" % tpl.get("size"))
	_ok("a room too small for it gets none", RoomTemplates.room_for("office",
			Vector3i(3, 19, 3), 0).is_empty())
	var long := RoomTemplates.room_for("office", Vector3i(4, 19, 30), 0)
	_ok("a long thin room takes it turned", not long.is_empty() and long.size.x <= 4,
			"%s" % [long.get("size")])

	var room := Room.new()
	room.kind = "office"
	room.lo = Vector3i(10, 1, 10)
	room.size = Vector3i(30, 19, 30)
	room.room_seed = 77
	var items := RoomManifest.items_for(room)
	_ok("an office is furnished from the template", items.size() == 2
			and str(items[0].type).begins_with("room:probe_office"),
			"%s" % [items])
	_ok("and counted as such", RoomManifest.item_count_for(room) == 2)

	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(60, 30, 60))
	for x in range(0, 60, 4):
		for z in range(0, 60, 4):
			w.place_block(c, Vector3i(x, 0, z), pal["plate_4x4"], 2)
	var table_item: Dictionary = items[0]
	var roles := []
	var ids := RoomManifest.build_item(w, c, pal, table_item, 4, Vector3i.ZERO, roles)
	_ok("the real rung lays every part, detail included", ids.size() == 4, "%d" % ids.size())
	_ok("and says which one is detail", roles.count(BuildRecipe.Role.DETAIL) == 1
			and roles.count(BuildRecipe.Role.INTERIOR) == 3, "%s" % [roles])
	_ok("in the author's own colours", w.get_block_colour(c, ids[0]) == 11)
	for id in ids:
		w.remove_block(c, id)
	room.items = items
	var drawn := RoomManifest.draw_items(w, c, pal, room)
	_ok("the drawn rung leaves detail out", int(drawn.parts) == 4, "%d parts" % drawn.parts)

	var lamp := BuildRecipe.new()
	lamp.kind = "item"
	lamp.meta = {"room_kind": "storeroom"}
	lamp.add("brick_1x1", Vector3i(3, 1, 3), 6)
	lamp.add("tile_1x1", Vector3i(3, 4, 3), 1, 0, BuildRecipe.Role.DETAIL)
	var lt := RoomTemplates.add_item("probe_lamp", lamp)
	_ok("an item registers for its room kind",
			RoomTemplates.items_for_kind("storeroom").has(lt)
			and not RoomTemplates.items_for_kind("office").has(lt))
	_ok("its parts start at its own corner",
			(RoomTemplates.parts(lt)[0][1] as Vector3i) == Vector3i.ZERO)

	# The mix.
	var same := true
	for sd in 64:
		same = same and RoomManifest.kind_index(sd, {}) == sd % Room.KINDS.size()
	_ok("no program draws exactly what the city always drew", same)
	var kitchens := RoomManifest.rooms_for(40, 30, 18, 5, {"kitchen": 1})
	var all_k := not kitchens.is_empty()
	for r in kitchens:
		all_k = all_k and r.kind == "kitchen"
	_ok("a program of kitchens is all kitchens", all_k, "%d rooms" % kitchens.size())
	var mixed := RoomManifest.rooms_for(40, 30, 60, 9, {"office": 3, "storeroom": 1})
	var n_office := 0
	var others := 0
	for r in mixed:
		if r.kind == "office":
			n_office += 1
		elif r.kind != "storeroom":
			others += 1
	_ok("weights are weights", others == 0 and n_office > mixed.size() / 2,
			"%d offices of %d" % [n_office, mixed.size()])
	var agree := true
	var prog := {"office": 2, "kitchen": 1}
	var rs := RoomManifest.rooms_for(40, 30, 18, 3, prog)
	var lat := RoomManifest.lattice_for(40, 30, 18)
	var per: int = (lat.rects as Array).size()
	for r in rs:
		@warning_ignore("integer_division")
		var st: int = r.id / per
		var k := RoomManifest.kind_at(40, 30, 18, 3, st,
				Vector2(r.lo.x + r.size.x * 0.5, r.lo.z + r.size.z * 0.5), prog)
		agree = agree and Room.KINDS[k] == r.kind
	_ok("a far window shows the room the program put there", agree)

	# A furnished generated building.
	var gp := TowerBlockout.normalised({"program": {"office": 1}})
	var bw := BrickWorld.new()
	var bpal := TowerRecipe.bake_palette(bw)
	var furnished := TowerBlockout.bricks(bw, bpal, gp)
	var n_int := 0
	var n_det := 0
	for b in furnished:
		if int(b[3]) == BuildRecipe.Role.INTERIOR:
			n_int += 1
		elif int(b[3]) == BuildRecipe.Role.DETAIL:
			n_det += 1
	_ok("a furnished generated building has furniture in it", n_int > 0, "%d interior" % n_int)
	_ok("from the office template, cup and all", n_det > 0, "%d detail" % n_det)
	gp.furnish = false
	var bare := TowerBlockout.bricks(bw, bpal, gp)
	var any_int := false
	for b in bare:
		any_int = any_int or int(b[3]) != BuildRecipe.Role.STRUCTURE
	_ok("unfurnished has none", not any_int)
	var rr := BuildRecipe.new()
	rr.add_tower(Vector3i.ZERO, TowerBlockout.normalised({"program": {"office": 1}}))
	var flat := TowerBlockout.flatten(rr)
	_ok("the city gets the furniture with its roles", flat.interior_count() == n_int + n_det
			and flat.detail_count() == n_det, "%d / %d" % [flat.interior_count(), flat.detail_count()])


# ---------------------------------------------------------------------------

func _workshop_checks() -> void:
	print("[probe] the workshop scene")
	var ws = load("res://scenes/workshop.tscn").instantiate()
	root.add_child(ws)
	await process_frame
	await process_frame
	ws._builds_dir = "user://_probe_builds/"
	ws._save_path = "user://_probe_quick.json"
	var f0: int = ws.asm.frames[0]
	var base_blocks: int = ws.world.get_alive_block_count(f0)

	# --- the menu bar exists and its dialogs are shut
	_ok("a menu bar", ws._menu != null and ws._menu.bar_height() > 0.0)
	_ok("nothing modal to start with", not ws._menu.is_modal())

	# --- a generated building, dragged bigger
	ws._on_menu("tower", null)
	_ok("Insert > Generated building adds one", ws.recipe.towers.size() == 1)
	var laid: int = ws.world.get_alive_block_count(f0) - base_blocks
	_ok("and lays its preview into frame 0", laid > 200, "%d" % laid)
	_ok("without putting a brick in the recipe", ws.recipe.size() == 0)
	var t: Dictionary = ws.recipe.towers[0]
	var at := BuildRecipe.cell_from(t.cell)
	var o := BrickWorld.grid_to_world(at)
	ws.begin_drag("x")
	# A ray straight down at x = 40 studs past the building's corner, plus the gap.
	var want_x: float = o.x + 40 * STUD + ws.HANDLE_M
	ws.drag_ray(Vector3(want_x, 30.0, o.z + 1.0), Vector3(0, -1, 0))
	ws.end_drag()
	var p := TowerBlockout.normalised(ws.recipe.towers[0].params)
	_ok("dragging the +X handle widens it to whole panels", p.x == 40, "x=%d" % p.x)
	ws.begin_drag("y")
	# A ray along +X at the height of three storeys.
	var three: int = TowerBlockout.dims(TowerBlockout.normalised({"courses": 18})).y
	ws.drag_ray(Vector3(-5.0, o.y + three * PLATE + ws.HANDLE_M, o.z + 1.0), Vector3(1, 0, 0))
	ws.end_drag()
	p = TowerBlockout.normalised(ws.recipe.towers[0].params)
	_ok("dragging the top handle raises it a storey at a time", p.courses == 18,
			"courses=%d" % p.courses)
	var before_undo: int = ws.world.get_alive_block_count(f0)
	ws._undo()
	p = TowerBlockout.normalised(ws.recipe.towers[0].params)
	_ok("undo takes the drag back", p.courses == 12 and p.x == 40)
	_ok("and rebuilds the preview", ws.world.get_alive_block_count(f0) < before_undo)
	ws._set_tower_option("rooms", false)
	_ok("an option switches", not bool(ws.recipe.towers[0].params.rooms))
	ws._undo()
	_ok("and undoes", bool(ws.recipe.towers[0].params.rooms))

	# --- saved as a record, loaded back
	var path: String = ws._save_as("Probe House")
	_ok("Save As writes a named file", path != "" and FileAccess.file_exists(path), path)
	var saved := BuildRecipe.load_from(path)
	_ok("holding the generated building as ONE record", saved.towers.size() == 1
			and saved.size() == 0 and saved.name == "Probe House")
	ws._new_build()
	_ok("New clears the space", ws.recipe.towers.is_empty() and ws.recipe.size() == 0
			and ws.world.get_alive_block_count(ws.asm.frames[0]) == base_blocks)
	_ok("and forgets the file", ws._current_path == "")
	ws._open_path(path)
	_ok("Open brings it back, preview and all", ws.recipe.towers.size() == 1
			and ws.world.get_alive_block_count(ws.asm.frames[0]) > base_blocks + 200)
	_ok("and remembers the file for Save", ws._current_path == path and not ws._dirty)

	# --- bake it to bricks
	var baked: int = ws._bake_tower()
	_ok("Bake makes the preview the recipe's own bricks", baked > 200
			and ws.recipe.size() == baked and ws.recipe.towers.is_empty())
	_ok("recorded as a group", ws.recipe.groups.size() == 1
			and int(ws.recipe.groups[0].count) == baked)
	ws._undo()
	_ok("one undo puts the generated building back", ws.recipe.size() == 0
			and ws.recipe.towers.size() == 1 and ws.recipe.groups.is_empty())

	# --- a build inside a build
	ws._on_menu("remove_tower", null)
	_ok("Remove takes the generated building out", ws.recipe.towers.is_empty()
			and ws.world.get_alive_block_count(ws.asm.frames[0]) == base_blocks)
	ws._undo()
	_ok("and undo puts it back", ws.recipe.towers.size() == 1)
	ws._on_menu("remove_tower", null)
	var cottage := BuildRecipe.load_from("res://builds/cottage.json")
	ws.hold_stamp(cottage, "res://builds/cottage.json")
	var box: Array = ws.stamp_box(ws._stamp)
	var d: Vector3i = box[1]
	var target: Vector3i = ws.stamp_target(Vector3(24.5 * STUD, 30.0, 24.5 * STUD), Vector3(0, -1, 0))
	_ok("aimed at the middle of the baseplate, it sits on it",
			target.y == 1 and target.x == 24 - d.x / 2, "%v in a box of %v" % [target, d])
	ws._stamp_at = target
	ws._stamp_ok = ws._stamp_fits(target)
	_ok("and fits", ws._stamp_ok)
	ws._commit_stamp()
	_ok("stamping copies every brick", ws.recipe.size() == cottage.size(),
			"%d of %d" % [ws.recipe.size(), cottage.size()])
	var all_in := true
	for i in ws.recipe.size():
		all_in = all_in and int(ws._placed_at[i][1]) >= 0
	_ok("and every one is in the world", all_in)
	_ok("with a group naming where it came from", ws.recipe.groups.size() == 1
			and ws.recipe.groups[0].source == "res://builds/cottage.json")
	_ok("and the same place again does not fit", not ws._stamp_fits(target))
	ws._turn_stamp()
	_ok("R turns it", ws._stamp_turn == 1 and ws._stamp.size() == cottage.size())
	ws._cancel_stamp()
	ws._undo()
	_ok("one undo takes the whole stamp back", ws.recipe.size() == 0
			and ws.recipe.groups.is_empty()
			and ws.world.get_alive_block_count(ws.asm.frames[0]) == base_blocks)

	# --- the detail layer
	ws._set_role(BuildRecipe.Role.DETAIL)
	ws._part_index = BrickPalette.parts().find("plate_2x2")
	ws._yaw = 0
	ws._flip = false
	ws._cell = Vector3i(2, 1, 2)
	ws._valid = true
	ws._snapped = {}
	ws._place()
	_ok("a brick placed on the detail layer is detail",
			ws.recipe.size() == 1 and ws.recipe.role_of(0) == BuildRecipe.Role.DETAIL)
	ws._toggle_layer()
	_ok("I cycles back to structure after detail", ws._role == BuildRecipe.Role.STRUCTURE)

	# --- type
	ws._on_menu("kind", "room")
	var room_path: String = ws._save_as("Probe Office", "office")
	var room := BuildRecipe.load_from(room_path)
	_ok("a room template saves its kind and room kind", room.kind == "room"
			and room.meta.get("room_kind") == "office" and room.meta.has("size"))
	var listed := WorkshopMenu.library("building")
	_ok("the library lists shipped builds", listed.has("res://builds/cottage.json"))

	for f in DirAccess.get_files_at("user://_probe_builds/"):
		DirAccess.remove_absolute("user://_probe_builds/" + f)
	ws.queue_free()
	await process_frame
