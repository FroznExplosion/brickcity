extends SceneTree

## The catalogue and placing furniture and items in the workshop: the filter
## panel, placements (asset + cell + turn, never bricks) aimed, stacked,
## turned, taken away, undone, saved, and laid as bricks for the city.
## Docs/AssetWorkshop.md, "Furniture and items".
##
##     godot --headless --path . --script tools/furnish_probe.gd

var _pass := 0
var _fail := 0
const DIR := "user://_probe_furnish_items/"


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _initialize() -> void:
	_make_assets()
	await _catalogue()
	await _workshop()
	_cleanup()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## A 2x4 Earth table for kitchens and offices (furniture: a plate on a brick),
## a 1x1 cup for any room on every planet (item), a 2x2 bed for bedrooms.
func _make_assets() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var table := BuildRecipe.new()
	table.kind = "item"
	table.name = "Probe Table"
	table.add("brick_2x4_x", Vector3i(5, 1, 5), 2, 0, BuildRecipe.Role.STRUCTURE)
	table.add("plate_2x4_x", Vector3i(5, 4, 5), 3, 0, BuildRecipe.Role.STRUCTURE)
	table.meta = {"tags": {"planet": ["earth"], "type": ["furniture"], "room": ["kitchen", "office"]}}
	table.save_to(DIR + "probe_table.json")
	var cup := BuildRecipe.new()
	cup.kind = "item"
	cup.name = "Probe Cup"
	cup.add("brick_1x1", Vector3i(0, 0, 0), 6, 0, BuildRecipe.Role.DETAIL)
	cup.meta = {"tags": {"planet": [], "type": ["item"], "room": []}}
	cup.save_to(DIR + "probe_cup.json")
	var bed := BuildRecipe.new()
	bed.kind = "item"
	bed.name = "Probe Bed"
	bed.add("brick_2x2", Vector3i(0, 0, 0), 1, 0, BuildRecipe.Role.INTERIOR)
	bed.meta = {"tags": {"planet": ["earth"], "type": ["furniture"], "room": ["bedroom"]}}
	bed.save_to(DIR + "probe_bed.json")
	AssetCatalog.use_dir(DIR)
	RoomTemplates.reload()
	AssetPlacements.forget_meshes()


func _catalogue() -> void:
	print("[probe] the catalogue")
	_ok("three assets read", AssetCatalog.entries().size() == 3, str(AssetCatalog.entries().size()))
	_ok("search by name", AssetCatalog.find({}, "cup").size() == 1)
	_ok("Earth: all three (the cup is Common)", AssetCatalog.find({"planet": ["earth"]}).size() == 3)
	_ok("furniture for a kitchen: the table",
			AssetCatalog.find({"type": ["furniture"], "room": ["kitchen"]}).map(func(e): return e.id) == ["probe_table"])
	_ok("kitchen OR bedroom: bed, cup (any room), table",
			AssetCatalog.find({"room": ["kitchen", "bedroom"]}).size() == 3)
	_ok("chip count: item alone leaves 1", AssetCatalog.count_with({}, "type", "item") == 1)

	var p := AssetCatalogPanel.new()
	p.save_path = "user://_probe_catalog.json"
	DirAccess.remove_absolute(p.save_path)
	root.add_child(p)
	await process_frame
	_ok("panel lists all with no filter", p.shown_ids().size() == 3, str(p.shown_ids()))
	var row: Dictionary = p._chips["type"]
	_ok("chips carry counts", (row.values["furniture"] as Button).text.ends_with("2")
			and (row.values["item"] as Button).text.ends_with("1"), (row.values["furniture"] as Button).text)
	(row.values["furniture"] as Button).emit_signal("pressed")
	_ok("Furniture chip narrows the list", p.shown_ids() == ["probe_bed", "probe_table"], str(p.shown_ids()))
	(row.values["item"] as Button).emit_signal("pressed")
	_ok("type is one choice: Item replaces Furniture", p.shown_ids() == ["probe_cup"], str(p.shown_ids()))
	(row.all as Button).emit_signal("pressed")
	var rooms: Dictionary = p._chips["room"]
	(rooms.values["bedroom"] as Button).emit_signal("pressed")
	_ok("Bedroom: the bed and the any-room cup", p.shown_ids() == ["probe_bed", "probe_cup"], str(p.shown_ids()))
	(rooms.values["lab"] as Button).emit_signal("pressed")
	_ok("rooms add: Bedroom or Lab", p.filter.room == ["bedroom", "lab"])
	p.set_level("type", ["furniture"])
	_ok("a chip that would leave none is greyed", (rooms.values["shop"] as Button).disabled
			and not (p._chips["planet"].values["earth"] as Button).disabled)
	var picked := []
	p.picked.connect(func(id: String) -> void: picked.append(id))
	p._list.select(0)
	p._list.item_selected.emit(0)
	_ok("picking from the list says which", picked == ["probe_bed"], str(picked))
	p.queue_free()
	var q := AssetCatalogPanel.new()
	q.save_path = "user://_probe_catalog.json"
	root.add_child(q)
	await process_frame
	_ok("the filter is remembered", q.filter.type == ["furniture"] and q.filter.room == ["bedroom", "lab"],
			str(q.filter))
	q.queue_free()
	DirAccess.remove_absolute("user://_probe_catalog.json")


func _workshop() -> void:
	print("[probe] furnishing in the workshop")
	var ws = load("res://scenes/workshop.tscn").instantiate()
	root.add_child(ws)
	await process_frame
	await process_frame
	ws._builds_dir = "user://_probe_builds/"
	ws._save_path = "user://_probe_quick.json"
	ws._hotbar.save_path = "user://_probe_hotbar.json"
	# Loading the scene reloads scripts, which resets their statics: point the
	# catalogue at the probe's folder again.
	AssetCatalog.use_dir(DIR)
	RoomTemplates.reload()
	var f: FurnishTool = ws._furnish
	f.panel.save_path = "user://_probe_catalog.json"
	var xf: Transform3D = ws.world.get_chunk_transform(ws.chunk)
	@warning_ignore("integer_division")
	var mid: int = ws.plate_studs / 2
	var above := func(x: int, z: int) -> Vector3:
		return xf * Vector3((x + 0.5) * BrickPalette.STUD_M, 40.0, (z + 0.5) * BrickPalette.STUD_M)

	f.open(true)
	_ok("F6 opens the catalogue", f.is_open())
	f.hold("probe_table")
	f.aim_ray(above.call(mid, mid), Vector3.DOWN)
	_ok("aimed at the baseplate: a target that fits", f.has_target and f.ok, "at %s, held '%s'" % [f.at, f.held])
	var floor_y: int = f.at.y
	var sz := AssetPlacements.size_of("probe_table", 0)
	@warning_ignore("integer_division")
	_ok("centred on the stud aimed at", f.at.x == mid - (sz.x - 1) / 2 and f.at.z == mid - (sz.z - 1) / 2,
			str(f.at))
	var bricks: int = ws.recipe.size()
	_ok("placed", f.place())
	_ok("a placement, not bricks", ws.recipe.placements.size() == 1 and ws.recipe.size() == bricks)
	_ok("drawn", f._drawn.get_child_count() == 1)
	f.aim_ray(above.call(mid, mid), Vector3.DOWN)
	_ok("the same spot again: on top of the table", f.at.y == floor_y + 4, "%d vs %d" % [f.at.y, floor_y])
	f.hold("probe_cup")
	f.aim_ray(above.call(mid, mid), Vector3.DOWN)
	_ok("a cup on the table", f.ok and f.at.y == floor_y + 4 and f.place(), str(f.at))
	f.hold("probe_table")
	_ok("into the table's cells does not fit",
			not f.fits("probe_table", 0, AssetPlacements.cell_of(ws.recipe.placements[0])))
	f.turn_held()
	var s0 := AssetPlacements.size_of("probe_table", 0)
	_ok("R turns: across and along swap", AssetPlacements.size_of("probe_table", 1) == Vector3i(s0.z, s0.y, s0.x)
			and s0.y == 4 and s0.x != s0.z, str(s0))
	f.aim_ray(above.call(mid + 8, mid), Vector3.DOWN)
	_ok("turned, placed elsewhere", f.place() and int(ws.recipe.placements[2].turn) == 1)

	_ok("RMB takes the cup away (it is on top)", f.remove_ray(above.call(mid, mid), Vector3.DOWN)
			and ws.recipe.placements.size() == 2 and ws.recipe.placements[0].asset == "probe_table"
			and ws.recipe.placements[1].asset == "probe_table")
	ws._undo()
	_ok("undo puts it back where it was", ws.recipe.placements.size() == 3
			and ws.recipe.placements[1].asset == "probe_cup")
	ws._undo()
	_ok("undo again takes the last placed", ws.recipe.placements.size() == 2)

	ws.recipe.add("brick_2x2", Vector3i(mid + 20, floor_y, mid), 0)
	var path: String = ws._save_as("Probe Furnished")
	var back := BuildRecipe.load_from(path)
	_ok("saved with its placements", back.placements.size() == 2
			and back.placements[0].asset == "probe_table" and back.placements[1].asset == "probe_cup")
	_ok("as asset, cell and turn only", back.placements[0].keys().size() == 3
			and back.placements[0].has("cell") and back.placements[0].has("turn"))
	var full := AssetPlacements.expand(back)
	_ok("laid for the city: table 2 bricks and cup 1 after the build's own",
			full.size() == back.size() + 3 and full.placements.is_empty(), "%d" % full.size())
	_ok("the build's own bricks keep their ids", full.part_of(0) == back.part_of(0)
			and full.cell_of(0) == back.cell_of(0))
	var n := back.size()
	_ok("table is Interior, cup is Detail", full.role_of(n) == BuildRecipe.Role.INTERIOR
			and full.role_of(n + 2) == BuildRecipe.Role.DETAIL)
	_ok("in the author's colours", full.colour_of(n) == 2 and full.colour_of(n + 1) == 3)
	var bare := BuildRecipe.new()
	_ok("a build with no placements is handed back as it is", AssetPlacements.expand(bare) == bare)
	var t := back.turned(1)
	_ok("turning the build turns its placements", t != null and t.placements.size() == 2
			and int(t.placements[0].turn) == 1)
	var empty := BuildRecipe.new()
	empty.placements.append(AssetPlacements.make("gone_asset", Vector3i.ZERO, 0))
	_ok("a placement whose asset is gone is left out", AssetPlacements.expand(empty).size() == 0)
	var rw := BrickWorld.new()
	var reg := BuildingRegistry.new(rw, TowerRecipe.bake_palette(rw))
	var bid := reg.register_build(back, Transform3D())
	_ok("the city registers it with the furniture as bricks", bid >= 0
			and reg.get_building(bid).build.size() == back.size() + 3)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute("user://_probe_builds/")
	ws._new_build()
	_ok("a new build has no placements, none drawn", ws.recipe.placements.is_empty()
			and f._drawn.get_children().all(func(c): return c.is_queued_for_deletion()))
	ws.queue_free()


func _cleanup() -> void:
	for fn in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR + fn)
	DirAccess.remove_absolute(DIR)
	DirAccess.remove_absolute("user://_probe_catalog.json")
	AssetCatalog.use_dir("")
	RoomTemplates.reload()
