extends SceneTree

## The player's folder: the layout (UserPaths) and the move from the old flat
## one. Docs/Content.md, "The player's folder".
##
##     godot --headless --path . --script tools/user_paths_probe.gd
##
## What each group is for:
##   layout   the libraries and saves name the new folders, and those exist.
##   move     an old layout is carried over whole, file by file.
##   safe     a move never writes over a file, can be run again, and picks up
##            what an older build of the game writes to the old places later.
##
## It moves a made-up layout in user://dev/_probe_userpaths/, never the player's.

const ROOT := "user://dev/_probe_userpaths/"

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	print("user paths probe")
	_wipe(ROOT)
	_check_layout()
	_check_move()
	_check_safe()
	_wipe(ROOT)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check_layout() -> void:
	print("\nlayout")
	for d: String in UserPaths.MADE:
		_ok("user://%s exists" % d, DirAccess.dir_exists_absolute("user://" + d))
	_ok("a build is saved in the library", BuildRecipe.player_dir("building") == "user://library/builds/"
			and BuildRecipe.player_dir("gun") == "user://library/guns/", BuildRecipe.player_dir("building"))
	_ok("the library's folders are a pack's", ContentPacks.FOLDERS.has("builds")
			and UserPaths.library("items") == "user://library/items/")
	_ok("custom parts are the library's parts", PartCatalog.CUSTOM_DIR == "user://library/parts/")
	_ok("the character is in the profile", CharacterSave.PATH == "user://profile/character.json")
	_ok("universes stay in saves, the gates' in dev", UniverseSave.ROOT == "user://saves/"
			and UniverseSave.TEST_ROOT == "user://dev/saves_test/")
	_ok("mods stay in mods", ContentPacks.MODS_ROOT == "user://mods/")
	_ok("the quick save is the workshop's", BuildRecipe.QUICK_SAVE == "user://workshop/quick_build.json")
	# No row's new place is another row's old place, and none is moved twice.
	var olds := {}
	var chained := []
	for row: Array in UserPaths.MOVES:
		olds[row[0]] = true
	for row: Array in UserPaths.MOVES:
		for old: String in olds:
			if str(row[1]).begins_with(old) and old.ends_with("/"):
				chained.append("%s into %s" % [row[1], old])
	_ok("no move lands in a folder that is itself moved", chained.is_empty(), "%s" % [chained])


func _check_move() -> void:
	print("\nmove")
	var old := {
		"builds/hut.json": "hut", "builds/town/hall.json": "hall",
		"guns/thompson.json": "gun", "guns/thompson/gun.json": "folder gun",
		"items/mug.json": "mug", "rooms/kitchen/a.json": "room",
		"parts/custom/gun/my_barrel/part.json": "part", "parts/designs/scout.json": "design",
		"parts/dressing.json": "dressing", "parts/export/a.bcpart": "export",
		"character.json": "me", "checkpoint.area": "cp",
		"workshop_hotbar.json": "hotbar", "workshop_build.json": "quick",
		"asset_workshop_toolbars.json": "toolbars", "asset_exports/a.json": "asset",
		"saves_test/last.cfg": "test save", "asset_shots/front.png": "shot",
		# not the move's business
		"settings.cfg": "settings", "saves/universe_1/universe.dat": "universe", "mods/m/pack.json": "mod",
	}
	for rel: String in old:
		_text(ROOT + rel, old[rel])
	var moved := UserPaths.migrate(ROOT)
	var want := {
		"library/builds/hut.json": "hut", "library/builds/town/hall.json": "hall",
		"library/guns/thompson.json": "gun", "library/guns/thompson/gun.json": "folder gun",
		"library/items/mug.json": "mug", "library/rooms/kitchen/a.json": "room",
		"library/parts/gun/my_barrel/part.json": "part", "library/parts/designs/scout.json": "design",
		"profile/dressing.json": "dressing", "exports/parts/a.bcpart": "export",
		"profile/character.json": "me", "profile/checkpoint.area": "cp",
		"workshop/hotbar.json": "hotbar", "workshop/quick_build.json": "quick",
		"workshop/asset_toolbars.json": "toolbars", "exports/assets/a.json": "asset",
		"dev/saves_test/last.cfg": "test save", "dev/asset_shots/front.png": "shot",
		"settings.cfg": "settings", "saves/universe_1/universe.dat": "universe", "mods/m/pack.json": "mod",
	}
	var wrong := []
	for rel: String in want:
		if FileAccess.get_file_as_string(ROOT + rel) != want[rel]:
			wrong.append(rel)
	_ok("every file is in its new place, unchanged", wrong.is_empty(), "%s" % [wrong])
	_ok("it says what moved", moved.size() == 18, "%d" % moved.size())
	var left := []
	for d in ["builds/", "guns/", "items/", "rooms/", "parts/", "asset_exports/", "saves_test/", "asset_shots/"]:
		if DirAccess.dir_exists_absolute(ROOT + d):
			left.append(d)
	_ok("the old folders are gone", left.is_empty(), "%s" % [left])
	_ok("settings, saves and mods did not move", FileAccess.file_exists(ROOT + "settings.cfg")
			and DirAccess.dir_exists_absolute(ROOT + "saves/universe_1/") and DirAccess.dir_exists_absolute(ROOT + "mods/m/"))


func _check_safe() -> void:
	print("\nsafe")
	_ok("a second run moves nothing", UserPaths.migrate(ROOT).is_empty())
	# An older build of the game writes the old places again.
	_text(ROOT + "builds/hut.json", "OLD hut")        # a name the library has
	_text(ROOT + "builds/shed.json", "shed")          # a new one
	_text(ROOT + "character.json", "OLD me")
	var moved := UserPaths.migrate(ROOT)
	_ok("a new file from an older build is picked up", FileAccess.get_file_as_string(ROOT + "library/builds/shed.json") == "shed"
			and moved.size() == 1, "%s" % [moved])
	_ok("nothing is written over", FileAccess.get_file_as_string(ROOT + "library/builds/hut.json") == "hut"
			and FileAccess.get_file_as_string(ROOT + "profile/character.json") == "me")
	_ok("and the file that lost is left where it was", FileAccess.get_file_as_string(ROOT + "builds/hut.json") == "OLD hut"
			and FileAccess.get_file_as_string(ROOT + "character.json") == "OLD me")


func _text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + f)
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir + d + "/")
	DirAccess.remove_absolute(dir.trim_suffix("/"))
