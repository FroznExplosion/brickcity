extends SceneTree

## Content packs: the game, a DLC and a mod are each one folder, and what is in
## a pack shows up where the game's own does. Docs/Content.md.
##
##     godot --headless --path . --script tools/content_packs_probe.gd
##
## What each group is for:
##   base      the game's own content is the pack "base", and the libraries
##             still find it there (it moved from the project's top folder).
##   mod       a mod dropped in the mods folder: its builds, items, bricks,
##             parts, worlds and tags are listed with the game's, each still a
##             file inside the mod's own folder.
##   bricks    a pack's brick definitions join the palette, bake, and never
##             replace or renumber a part the game has.
##   fences    a pack with a bad name, a wrong id, a missing need or switched
##             off is left out, and says why.
##   archive   a mod as one .zip is mounted and read the same way.
##
## It builds its mods in user://dev/_probe_mods/ and never reads the player's.

const ROOT := "user://dev/_probe_mods/"

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
	print("content packs probe")
	_wipe(ROOT)
	_check_base()
	_write_mods()
	ContentPacks.use_mods_root(ROOT)
	BrickPalette.reload_packs()
	AssetCatalog.reload()
	_check_mod()
	_check_bricks()
	_check_fences()
	_check_archive()
	ContentPacks.use_mods_root("")
	_wipe(ROOT)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check_base() -> void:
	print("\nbase")
	ContentPacks.use_mods_root(ROOT)   # empty: only what ships
	var ids := ContentPacks.packs().map(func(p: Dictionary) -> String: return p.id)
	_ok("the game is the first pack", not ids.is_empty() and ids[0] == "base", "%s" % [ids])
	_ok("its kind is base", ContentPacks.pack("base").get("kind", "") == "base")
	var lib := BuildRecipe.library("building")
	_ok("the shipped buildings are found in it", lib.has("res://content/base/builds/cottage.json"), "%s" % [lib])
	_ok("a shipped path names its pack", ContentPacks.pack_of("res://content/base/builds/cottage.json") == "base"
			and ContentPacks.is_official("res://content/base/builds/cottage.json"))
	_ok("the player's own work is in no pack", ContentPacks.pack_of("user://library/builds/mine.json") == "")
	_ok("the tags table is read", AssetTags.levels().size() >= 3, "%d levels" % AssetTags.levels().size())
	_ok("the worlds are listed", TerrainWorld.list_worlds().has("city"), "%s" % [TerrainWorld.list_worlds()])
	var cat := PartCatalog.load_all()
	_ok("the shipped parts are read", cat.filter({"family": ["gun"]}).size() >= 5,
			"%d gun parts" % cat.filter({"family": ["gun"]}).size())
	_ok("a file is resolved to the pack that has it",
			ContentPacks.resolve("data/ai/roster.json") == "res://content/base/data/ai/roster.json")


func _write_mods() -> void:
	# A whole mod: one folder, everything it adds inside.
	var m := ROOT + "probe_mod/"
	_json(m + "pack.json", {"format": 1, "id": "probe_mod", "name": "Probe Mod", "version": "1.2",
			"author": "Probe", "requires": ["base"]})
	var kiosk := FileAccess.get_file_as_string("res://content/base/builds/kiosk.json")
	_text(m + "builds/probe_hut.json", kiosk)
	_text(m + "items/probe_mug.json", kiosk)
	_text(m + "worlds/probe_moon.json", FileAccess.get_file_as_string("res://content/base/worlds/city.json"))
	_json(m + "data/asset_tags.json", {"levels": [
			{"id": "planet", "values": [{"id": "probe_moon", "label": "Probe Moon"}]},
			{"id": "era", "label": "Era", "multi": true, "any": "Any era",
					"values": [{"id": "old", "label": "Old"}]}]})
	_json(m + "bricks/girders.json", {
			"parts": {
				"girder_1x5": {"size": [1, 3, 5]},
				"tile_3x3": {"size": [3, 1, 3]},
				"slope_2x6": {"size": [2, 3, 6], "shape": {"kind": "slope", "axis": "x"}},
				"brick_2x4": {"size": [2, 3, 4]},          # the game's: must not be replaced
				"girder_5x1": {"size": [5, 3, 1]},         # W > L
				"wrong_2x2": {"size": [2, 3, 3]},          # name and size disagree
				"blob_2x2": {"size": [2, 3, 2], "shape": {"kind": "blob"}}},
			"categories": [["Girders", ["girder"]], ["Slopes", ["ramp"]]]})
	# A part: one of the game's, under an id and a maker of its own.
	var src := "res://content/base/parts/gun/starter_mech_lmg_barrel/"
	var part = JSON.parse_string(FileAccess.get_file_as_string(src + "part.json"))
	if part is Dictionary:
		part["id"] = "probe_mod_barrel"
		part["source"] = "official"   # a mod cannot make itself official
		part["creator"] = {"name": "Probe"}
		_json(m + "parts/gun/probe_mod_barrel/part.json", part)
	# The fences.
	_json(ROOT + "Bad Name/pack.json", {"id": "Bad Name"})
	_json(ROOT + "wrong_id/pack.json", {"id": "something_else"})
	_json(ROOT + "needs_more/pack.json", {"id": "needs_more", "requires": ["not_installed"]})
	_json(ROOT + "newer/pack.json", {"id": "newer", "format": 99})
	DirAccess.make_dir_recursive_absolute(ROOT + "no_manifest/")
	_json(ROOT + "switched_off/pack.json", {"id": "switched_off"})
	_text(ROOT + "switched_off/builds/off_hut.json", kiosk)
	# One file: content/<id>/... inside a zip.
	var zip := ZIPPacker.new()
	if zip.open(ROOT + "probe_zip.zip") == OK:
		zip.start_file("content/probe_zip/pack.json")
		zip.write_file(JSON.stringify({"format": 1, "id": "probe_zip", "name": "Probe Zip"}).to_utf8_buffer())
		zip.close_file()
		zip.start_file("content/probe_zip/builds/zip_hut.json")
		zip.write_file(kiosk.to_utf8_buffer())
		zip.close_file()
		zip.close()


func _check_mod() -> void:
	print("\nmod")
	var p := ContentPacks.pack("probe_mod")
	_ok("the mod is a pack", not p.is_empty() and p.kind == "mod" and p.name == "Probe Mod" and p.version == "1.2", "%s" % [p])
	var ids := ContentPacks.packs().map(func(q: Dictionary) -> String: return q.id)
	_ok("read after the game", ids.find("base") == 0 and ids.find("probe_mod") > 0, "%s" % [ids])
	var hut := ROOT + "probe_mod/builds/probe_hut.json"
	var lib := BuildRecipe.library("building")
	_ok("its building is in the building library, from its own folder", lib.has(hut), "%s" % [lib])
	_ok("the game's buildings come before it", lib.find("res://content/base/builds/cottage.json") < lib.find(hut))
	_ok("the player's folder is still where a build is saved", BuildRecipe.player_dir("building") == "user://library/builds/"
			and BuildRecipe.shipped_dir("building") == "res://content/base/builds/")
	var e := AssetCatalog.entry("probe_mug")
	_ok("its item is in the item catalogue", not e.is_empty() and e.path == ROOT + "probe_mod/items/probe_mug.json", "%s" % [e])
	_ok("the catalogue says which pack", e.get("pack", "") == "probe_mod")
	_ok("the path names its pack, and is not official", ContentPacks.pack_of(hut) == "probe_mod" and not ContentPacks.is_official(hut))
	_ok("its world is listed with the game's", TerrainWorld.list_worlds().has("probe_moon") and TerrainWorld.list_worlds().has("city"))
	AssetTags._levels.clear()
	var planet := AssetTags.level("planet")
	var planets := (planet.get("values", []) as Array).map(func(v: Dictionary) -> String: return v.id)
	_ok("its planet joins the planet tag, beside the game's", planets.has("probe_moon") and planets.has("earth"), "%s" % [planets])
	_ok("its new tag level is added", not AssetTags.level("era").is_empty())
	AssetTags._levels.clear()
	var cat := PartCatalog.load_all()
	var part := cat.filter({"family": ["gun"]}).filter(func(r: PartRecord) -> bool: return r.id == "probe_mod_barrel")
	_ok("its part is in the part catalogue", part.size() == 1)
	if part.size() == 1:
		_ok("a mod's part is custom whatever its file says", part[0].source == "custom", part[0].source)


func _check_bricks() -> void:
	print("\nbricks")
	var parts := BrickPalette.parts()
	_ok("the mod's bricks are parts", parts.has("girder_1x5") and parts.has("tile_3x3") and parts.has("slope_2x6"))
	_ok("a part says which pack it came in", BrickPalette.pack_of_part("girder_1x5") == "probe_mod"
			and BrickPalette.pack_of_part("brick_2x4") == "")
	_ok("the game's part is not replaced", BrickPalette.part_size("brick_2x4") == Vector3i(2, 3, 4)
			and BrickPalette.pack_of_part("brick_2x4") == "")
	_ok("bad entries are left out", not parts.has("girder_5x1") and not parts.has("wrong_2x2") and not parts.has("blob_2x2"))
	_ok("its category is browsed", BrickPalette.categories().has("Girders")
			and BrickPalette.parts_in("Girders") == ["girder_1x5"], "%s" % [BrickPalette.categories()])
	_ok("a part of a family the game has files with it", BrickPalette.category_of("tile_3x3") == "Tiles"
			and BrickPalette.category_of("slope_2x6") == "Slopes")
	_ok("its family decides its studs", not BrickPalette.has_studs("tile_3x3") and BrickPalette.has_studs("girder_1x5"))
	_ok("a shaped one has a front", BrickPalette.is_directional("slope_2x6") and BrickPalette.is_shaped("slope_2x6"))
	# Baking: with the mod and without, the game's own archetypes keep their ids.
	var with_mod := BrickPalette.bake(BrickWorld.new())
	_ok("they bake in every orientation", with_mod.get("girder_1x5_x", -1) >= 0 and with_mod.get("girder_1x5_z_i", -1) >= 0
			and with_mod.get("tile_3x3", -1) >= 0 and with_mod.get("slope_2x6_y3_i", -1) >= 0)
	_ok("an archetype's size follows its name", BrickPalette.size_of("girder_1x5_x") == Vector3i(5, 3, 1)
			and BrickPalette.part_of("girder_1x5_x_i") == "girder_1x5")
	ContentPacks.set_enabled("probe_mod", false)
	BrickPalette.reload_packs()
	var without := BrickPalette.bake(BrickWorld.new())
	var moved := 0
	for n: String in without:
		if with_mod.get(n, -1) != without[n]:
			moved += 1
	_ok("no archetype of the game's is renumbered by a mod", moved == 0 and not without.is_empty(), "%d moved" % moved)
	_ok("switched off, its bricks are gone", not BrickPalette.parts().has("girder_1x5"))
	ContentPacks.set_enabled("probe_mod", true)
	BrickPalette.reload_packs()
	_ok("switched on again, they are back", BrickPalette.parts().has("girder_1x5"))


func _check_fences() -> void:
	print("\nfences")
	ContentPacks.set_enabled("switched_off", false)
	var ids := ContentPacks.packs().map(func(p: Dictionary) -> String: return p.id)
	var why := {}
	for r: Dictionary in ContentPacks.rejected():
		why[r.id] = r.why
	_ok("a folder with a bad name is left out", not ids.has("Bad Name") and why.has("Bad Name"), "%s" % [why])
	_ok("an id that is not its folder's is left out", not ids.has("wrong_id") and why.has("wrong_id"))
	_ok("a pack missing what it needs is left out", not ids.has("needs_more") and why.has("needs_more"))
	_ok("a pack for a newer game is left out", not ids.has("newer") and why.has("newer"))
	_ok("a folder with no pack.json is left out", not ids.has("no_manifest") and why.has("no_manifest"))
	_ok("a mod switched off is not read", not ids.has("switched_off")
			and not BuildRecipe.library("building").has(ROOT + "switched_off/builds/off_hut.json"))
	var listed := ContentPacks.mods().filter(func(m: Dictionary) -> bool: return m.id == "switched_off")
	_ok("but is still listed, as off", listed.size() == 1 and not listed[0].enabled)
	_ok("no mod can call itself base", ContentPacks.pack("base").root == "res://content/base/")


func _check_archive() -> void:
	print("\narchive")
	var p := ContentPacks.pack("probe_zip")
	_ok("a zipped mod is a pack", not p.is_empty() and p.get("kind", "") == "mod", "%s  rejected %s" % [p, ContentPacks.rejected()])
	_ok("its building is in the library", BuildRecipe.library("building").has("res://content/probe_zip/builds/zip_hut.json"),
			"%s" % [BuildRecipe.library("building")])
	var r := BuildRecipe.load_from("res://content/probe_zip/builds/zip_hut.json")
	_ok("and loads", not r.is_empty())


# -- files ---------------------------------------------------------------

func _json(path: String, data: Variant) -> void:
	_text(path, JSON.stringify(data, "\t"))


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
	DirAccess.remove_absolute(dir)
