extends SceneTree

## Furniture and items made in the asset workshop: their tags (planet, type,
## room), the filter, the Save As dialog, and the generator taking them.
## Docs/AssetWorkshop.md, "Furniture and items".
##
##     godot --headless --path . --script tools/asset_tags_probe.gd

var _pass := 0
var _fail := 0
var _ws
var _frames := 0
const DIR := "user://_probe_items/"


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 2:
		return
	_ws.set_process(false)
	_ws._hotbar.save_path = "user://_probe_asset_hotbar.json"
	_ws.toolbars_save = "user://_probe_asset_toolbars.json"
	print("asset tags probe")
	_levels()
	_filter()
	_old_files()
	_dialog()
	_save_and_generate()
	RoomTemplates.planet = "earth"
	RoomTemplates.reload()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## The levels are the data file's, in its order: planet first, then type, then room.
func _levels() -> void:
	print("[probe] levels")
	var ids := []
	for l: Dictionary in AssetTags.levels():
		ids.append(l.id)
	_ok("planet, type, room in that order", ids == ["planet", "type", "room"], str(ids))
	var planets := []
	for v: Dictionary in (AssetTags.level("planet").values as Array):
		planets.append(v.id)
	_ok("Earth is a planet, and planet can be left Common", planets.has("earth")
			and AssetTags.level("planet").any != "")
	_ok("type must be chosen, one of furniture or item", AssetTags.level("type").any == ""
			and not AssetTags.level("type").multi and AssetTags.level("type").values.size() == 2)
	var rooms := []
	for v: Dictionary in (AssetTags.level("room").values as Array):
		rooms.append(v.id)
	_ok("rooms are Room.KINDS but empty", rooms.size() == Room.KINDS.size() - 1
			and rooms.has("kitchen") and rooms.has("bedroom") and not rooms.has("empty"), str(rooms))


## Levels AND, values OR, an empty level on the asset passes when it has "any".
func _filter() -> void:
	print("[probe] filter")
	var chair := {"planet": [], "type": ["furniture"], "room": ["kitchen", "office"]}
	var cup := {"planet": ["earth"], "type": ["item"], "room": []}
	_ok("no filter passes all", AssetTags.matches(chair, {}) and AssetTags.matches(cup, {}))
	_ok("Earth passes a Common chair", AssetTags.matches(chair, {"planet": ["earth"]}))
	_ok("a planet not tagged fails", not AssetTags.matches(cup, {"planet": ["mars"]}))
	_ok("type picks one", AssetTags.matches(chair, {"type": ["furniture"]})
			and not AssetTags.matches(cup, {"type": ["furniture"]}))
	_ok("rooms OR: kitchen or bedroom", AssetTags.matches(chair, {"room": ["bedroom", "kitchen"]}))
	_ok("rooms: bedroom alone fails the chair", not AssetTags.matches(chair, {"room": ["bedroom"]}))
	_ok("any room passes every room", AssetTags.matches(cup, {"room": ["bathroom"]}))
	_ok("levels AND", not AssetTags.matches(chair, {"type": ["furniture"], "room": ["lab"]}))
	var c := AssetTags.clean({"planet": ["earth", "nowhere"], "type": ["item", "furniture"], "room": ["kitchen", "kitchen"]})
	_ok("clean: unknown values go, one type, no repeats",
			c.planet == ["earth"] and c.type == ["item"] and c.room == ["kitchen"], str(c))


## A file saved before tags: room_kind / room_kinds are its rooms, its bricks its type.
func _old_files() -> void:
	print("[probe] files saved before tags")
	var lamp := BuildRecipe.new()
	lamp.kind = "item"
	lamp.add("brick_1x1", Vector3i(0, 0, 0), 3, 0, BuildRecipe.Role.INTERIOR)
	lamp.meta = {"room_kinds": ["office", "lab"]}
	var t := AssetTags.tags_of(lamp)
	_ok("room_kinds read as rooms", t.room == ["office", "lab"], str(t))
	_ok("an Interior brick makes furniture", AssetTags.type_of(t) == "furniture")
	var cup := BuildRecipe.new()
	cup.kind = "item"
	cup.add("plate_1x1", Vector3i(0, 0, 0), 3, 0, BuildRecipe.Role.DETAIL)
	cup.meta = {"room_kind": "kitchen"}
	t = AssetTags.tags_of(cup)
	_ok("room_kind read as one room, all-Detail is an item", t.room == ["kitchen"]
			and AssetTags.type_of(t) == "item" and t.planet == [], str(t))


## The Save As dialog shows the tags for an item, and gives back what is ticked.
func _dialog() -> void:
	print("[probe] the Save As dialog")
	var m = _ws._menu
	_ws.set_asset_kind("item")
	_ok("Asset > furniture or item makes an item", _ws.recipe.kind == "item" and m._kind == "item")
	m.show_save_as("Stool", "", {"planet": ["earth"], "type": ["furniture"], "room": ["kitchen"]})
	_ok("an item's dialog has tags, not the room-kind list", m._save_tags_box.visible
			and not m._save_room_row.visible)
	var got: Dictionary = m._get_save_tags()
	_ok("ticks match what was given", got.planet == ["earth"] and got.type == ["furniture"]
			and got.room == ["kitchen"], str(got))
	var row: Dictionary = m._save_tags["room"]
	(row.values["bedroom"] as CheckBox).button_pressed = true
	_ok("a second room adds to the first", (m._get_save_tags().room as Array) == ["kitchen", "bedroom"],
			str(m._get_save_tags().room))
	(row.any as CheckBox).button_pressed = true
	_ok("Any room clears the rooms", (m._get_save_tags().room as Array).is_empty())
	var types: Dictionary = m._save_tags["type"]
	(types.values["item"] as CheckBox).button_pressed = true
	_ok("type is one choice: item replaces furniture", m._get_save_tags().type == ["item"],
			str(m._get_save_tags().type))
	m._save_dialog.hide()
	_ws.set_asset_kind("gun")
	m.show_save_as("Gun")
	_ok("a gun's dialog has no tags", not m._save_tags_box.visible)
	m._save_dialog.hide()


## Saved from the asset workshop as an item: the file has its tags and lands
## where the generator reads; the generator takes it for the rooms and planet
## tagged, an item as Detail and furniture as Interior.
func _save_and_generate() -> void:
	print("[probe] saved, and furnished from")
	_ws._new_build()
	_ws.set_asset_kind("item")
	_ws.recipe.add("brick_2x2", Vector3i(0, 0, 0), 5, 0, BuildRecipe.Role.STRUCTURE)
	_ws.recipe.add("plate_2x2", Vector3i(0, 3, 0), 5, 0, BuildRecipe.Role.DETAIL)
	_ws._builds_dir = DIR
	var path: String = _ws._save_as("Probe Stool", "",
			{"planet": [], "type": ["furniture"], "room": ["kitchen", "bedroom"]})
	_ws._builds_dir = BuildRecipe.player_dir()
	_ok("Save As writes it", path != "" and FileAccess.file_exists(path), path)
	_ok("an item's library is the generator's (user://items/)",
			BuildRecipe.player_dir("item") == "user://items/" and BuildRecipe.library_dirs("item").has("res://items/"))
	var back := BuildRecipe.load_from(path)
	_ok("the file keeps kind and tags, no room_kind", back.kind == "item"
			and back.meta.get("tags", {}).get("room", []) == ["kitchen", "bedroom"]
			and not back.meta.has("room_kind"), str(back.meta))

	RoomTemplates.reload()
	RoomTemplates.planet = "earth"
	var type := RoomTemplates.add_item("probe_stool", back)
	_ok("registered as furniture", type == "item:probe_stool")
	_ok("for its rooms only", RoomTemplates.items_for_kind("kitchen").has(type)
			and RoomTemplates.items_for_kind("bedroom").has(type)
			and not RoomTemplates.items_for_kind("office").has(type))
	var roles := []
	for p: Array in RoomTemplates.parts(type):
		roles.append(p[3])
	_ok("furniture: structure becomes Interior, Detail stays Detail",
			roles == [BuildRecipe.Role.INTERIOR, BuildRecipe.Role.DETAIL], str(roles))

	back.meta.tags.type = ["item"]
	RoomTemplates.reload()
	type = RoomTemplates.add_item("probe_cup", back)
	roles = []
	for p: Array in RoomTemplates.parts(type):
		roles.append(p[3])
	_ok("an item is Detail through and through", roles == [BuildRecipe.Role.DETAIL, BuildRecipe.Role.DETAIL],
			str(roles))

	back.meta.tags.planet = ["earth"]
	RoomTemplates.reload()
	RoomTemplates.planet = "mars"
	_ok("tagged Earth: not furnished on another planet", RoomTemplates.add_item("probe_cup", back) == "")
	RoomTemplates.planet = "earth"
	_ok("but on Earth", RoomTemplates.add_item("probe_cup", back) != "")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(DIR)
