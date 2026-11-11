class_name ContentPacks
extends RefCounted

## Every content pack the game has, and where each kind of content is in them.
## Docs/Content.md.
##
## A PACK is one folder holding everything it adds, in the same sub-folders
## whoever made it:
##
##     <pack>/pack.json     what it is (id, name, version ...)
##     <pack>/builds/       buildings        <pack>/parts/     gun and mech parts
##     <pack>/rooms/        rooms            <pack>/bricks/    brick definitions
##     <pack>/items/        furniture, items <pack>/worlds/    terrain worlds
##     <pack>/guns/         guns             <pack>/data/      tables (tags, AI ...)
##     <pack>/mechs/        mechs            <pack>/audio/ textures/ planets/
##     <pack>/figures/      characters           characters/   (reserved)
##
## Three kinds, read in this order:
##
##     base   res://content/base/     the game itself
##     dlc    res://content/<id>/     ours, shipped beside the game (or as a .pck)
##     mod    user://mods/<id>/       anyone's, dropped in by the player
##
## and the player's own saved work (user://builds/ and the rest) after them all.
## Nothing is copied or registered anywhere else: a library asks here for its
## folders (`dirs("items")`) and reads every one, so what is in a pack shows up
## wherever the game's own does -- the workshop's Open list, the item catalogue,
## the part catalogue, the brick palette.
##
## Two ways content of the same name meets:
##     a FILE   the later pack's replaces the earlier (`resolve`), as a player's
##              build of a shipped one's name always has;
##     a TABLE  every pack's is read and merged by whoever owns it (`every`).
##
## This script names no other class of the game's, so anything may use it.

const BASE_ID := "base"
const SHIPPED_ROOT := "res://content/"
const MODS_ROOT := "user://mods/"
const MANIFEST := "pack.json"
## Which mods are off, beside them: [packs] disabled = ["id", ...].
const STATE_FILE := "packs.cfg"
## The pack format this game reads. A pack that asks for a newer one is left out.
const FORMAT := 1
## The sub-folders a pack may have. One not listed here is not an error (a
## later game may know it), only unread.
const FOLDERS := ["builds", "rooms", "items", "guns", "mechs", "figures", "parts",
		"bricks", "worlds", "planets", "characters", "audio", "textures", "data"]

## A probe's mods folder instead of the player's. Kept on Engine, not in a
## static: loading a scene reloads scripts and resets their statics (Godot 4.6).
const MODS_ROOT_META := "content_packs_mods_root"
## The archives already mounted this run (a mount cannot be undone or repeated).
const MOUNTED_META := "content_packs_mounted"

static var _packs: Array = []
static var _loaded := false
## Why a pack found on disk was left out: [{"id", "root", "why"}], for a mods screen.
static var _rejected: Array = []


static func mods_root() -> String:
	return str(Engine.get_meta(MODS_ROOT_META, MODS_ROOT))


## Read mods from `dir` instead ("" for the player's again), from now on.
static func use_mods_root(dir: String) -> void:
	if dir == "":
		Engine.remove_meta(MODS_ROOT_META)
	else:
		Engine.set_meta(MODS_ROOT_META, dir if dir.ends_with("/") else dir + "/")
	reload()


## Forget what was read: a pack added or switched a moment ago is seen.
static func reload() -> void:
	_loaded = false
	_packs.clear()
	_rejected.clear()


## Every pack in use, in the order they are read: [{"id", "name", "version",
## "kind" (base, dlc or mod), "root" (ends with /), "author", "description",
## "requires": [ids]}].
static func packs() -> Array:
	_ensure()
	return _packs


static func pack(id: String) -> Dictionary:
	for p: Dictionary in packs():
		if p.id == id:
			return p
	return {}


static func has_pack(id: String) -> bool:
	return not pack(id).is_empty()


## The packs found and not used, each with why.
static func rejected() -> Array:
	_ensure()
	return _rejected


## Where a pack keeps a kind of content, whether or not it has any:
## `dir_in("base", "builds")` is "res://content/base/builds/".
static func dir_in(id: String, folder: String) -> String:
	var p := pack(id)
	var root: String = p.root if not p.is_empty() else SHIPPED_ROOT + id + "/"
	return root + folder + "/"


## The folders of one kind that exist, in reading order: `dirs("items")`.
## `beyond_base` leaves the game's own out (for a list that names it itself).
static func dirs(folder: String, beyond_base := false) -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in packs():
		if beyond_base and p.id == BASE_ID:
			continue
		var d: String = p.root + folder + "/"
		if DirAccess.dir_exists_absolute(d):
			out.append(d)
	return out


## Every file of a kind with this ending, sub-folders too, in reading order and
## name order within a pack. A file a later pack also has is listed once, the
## later one's (compared by its path under the folder).
static func files(folder: String, ending := ".json") -> PackedStringArray:
	var by_rel := {}
	var order := []
	for d in dirs(folder):
		var found := PackedStringArray()
		_collect(d, ending, found)
		for path in found:
			var rel := path.substr(d.length())
			if not by_rel.has(rel):
				order.append(rel)
			by_rel[rel] = path
	var out := PackedStringArray()
	for rel: String in order:
		out.append(by_rel[rel])
	return out


## The copy of a file that counts: the last pack's that has it, or "" if none
## does. `rel` is its path inside a pack: "data/ai/roster.json".
static func resolve(rel: String) -> String:
	var all := every(rel)
	return all[all.size() - 1] if not all.is_empty() else ""


## Every pack's copy of a file, in reading order: for a table that is merged.
static func every(rel: String) -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in packs():
		if FileAccess.file_exists(p.root + rel):
			out.append(p.root + rel)
	return out


## The pack a path is in ("" for the player's own work or anything else).
static func pack_of(path: String) -> String:
	var best := ""
	var best_len := 0
	for p: Dictionary in packs():
		var root: String = p.root
		if path.begins_with(root) and root.length() > best_len:
			best = p.id
			best_len = root.length()
	return best


## Is this path ours (the game or a DLC), not a mod's and not the player's?
static func is_official(path: String) -> bool:
	var p := pack(pack_of(path))
	return not p.is_empty() and p.kind != "mod"


## Every mod found, on or off: [{"id", "name", "version", "enabled", "root"}].
static func mods() -> Array:
	_ensure()
	var off := _disabled()
	var out := []
	for id in _mod_folders():
		var m := _read_manifest(mods_root() + id + "/")
		out.append({"id": id, "name": str(m.get("name", id)), "version": str(m.get("version", "")),
				"enabled": not off.has(id), "root": mods_root() + id + "/"})
	return out


## Switch a mod on or off, from the next read. Kept beside the mods.
static func set_enabled(id: String, on: bool) -> void:
	var off := _disabled()
	if on:
		off.erase(id)
	elif not off.has(id):
		off.append(id)
	DirAccess.make_dir_recursive_absolute(mods_root())
	var cfg := ConfigFile.new()
	cfg.set_value("packs", "disabled", off)
	cfg.save(mods_root() + STATE_FILE)
	reload()


# -- reading ------------------------------------------------------------

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	# The game's own, then ours beside it: taken before any archive is mounted,
	# so a mod's archive cannot pass for one of them.
	var shipped := []
	if DirAccess.dir_exists_absolute(SHIPPED_ROOT + BASE_ID + "/"):
		shipped.append(BASE_ID)
	for id in _sorted_dirs(SHIPPED_ROOT):
		if id != BASE_ID and not _mounted().has(id):
			shipped.append(id)
	var found := []
	for id: String in shipped:
		found.append(_describe(id, SHIPPED_ROOT + id + "/", BASE_ID if id == BASE_ID else "dlc"))
	var off := _disabled()
	_mount_archives(off)
	for id: String in _mounted():
		if not shipped.has(id) and not off.has(id):
			found.append(_describe(id, SHIPPED_ROOT + id + "/", "mod"))
	for id: String in _mod_folders():
		if not off.has(id):
			found.append(_describe(id, mods_root() + id + "/", "mod"))
	# One id, one pack: the first read keeps it (ours before a mod's).
	var ids := {}
	var kept := []
	for p: Dictionary in found:
		var why := str(p.get("why", ""))
		if why == "" and ids.has(p.id):
			why = "another pack is already '%s'" % p.id
		if why != "":
			_reject(p, why)
			continue
		ids[p.id] = true
		kept.append(p)
	# A pack whose needs are not met is left out, and so is what needed it.
	var changed := true
	while changed:
		changed = false
		for p: Dictionary in kept.duplicate():
			for need in p.requires:
				if not ids.has(str(need)):
					_reject(p, "needs '%s', which is not here" % need)
					kept.erase(p)
					ids.erase(p.id)
					changed = true
					break
	_packs = kept


static func _describe(id: String, root: String, kind: String) -> Dictionary:
	var m := _read_manifest(root)
	var p := {"id": id, "root": root, "kind": kind, "name": str(m.get("name", id)),
			"version": str(m.get("version", "")), "author": str(m.get("author", "")),
			"description": str(m.get("description", "")), "requires": []}
	for need in (m.get("requires", []) as Array):
		p.requires.append(str(need))
	if not _valid_id(id):
		p["why"] = "its folder's name must be lower-case letters, digits and _"
	elif m.is_empty():
		p["why"] = "no readable %s" % MANIFEST
	elif str(m.get("id", "")) != id:
		p["why"] = "%s says id '%s', its folder says '%s'" % [MANIFEST, m.get("id", ""), id]
	elif int(m.get("format", 1)) > FORMAT:
		p["why"] = "made for a newer game (pack format %d)" % int(m.get("format", 1))
	return p


static func _reject(p: Dictionary, why: String) -> void:
	_rejected.append({"id": p.id, "root": p.root, "why": why})
	push_warning("ContentPacks: %s left out: %s" % [p.root, why])


static func _read_manifest(root: String) -> Dictionary:
	var path := root + MANIFEST
	if not FileAccess.file_exists(path):
		return {}
	var m = JSON.parse_string(FileAccess.get_file_as_string(path))
	return m if m is Dictionary else {}


static func _valid_id(id: String) -> bool:
	if id == "":
		return false
	for c in id:
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true


static func _disabled() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(mods_root() + STATE_FILE) != OK:
		return []
	return Array(cfg.get_value("packs", "disabled", []))


## The loose mods: every folder of the mods folder.
static func _mod_folders() -> Array:
	return _sorted_dirs(mods_root())


static func _mounted() -> Array:
	return Array(Engine.get_meta(MOUNTED_META, []))


## A mod as one file, user://mods/<id>.pck or .zip, holding content/<id>/...:
## mounted once a run, never over a file the game already has.
static func _mount_archives(off: Array) -> void:
	var root := mods_root()
	if not DirAccess.dir_exists_absolute(root):
		return
	var mounted := _mounted()
	var names := Array(DirAccess.get_files_at(root))
	names.sort()
	for f: String in names:
		var ext := f.get_extension().to_lower()
		if ext != "pck" and ext != "zip":
			continue
		var id := f.get_basename()
		if mounted.has(id) or off.has(id) or not _valid_id(id):
			continue
		if DirAccess.dir_exists_absolute(SHIPPED_ROOT + id + "/"):
			_rejected.append({"id": id, "root": root + f, "why": "the game already has a pack '%s'" % id})
			continue
		if not ProjectSettings.load_resource_pack(root + f, false):
			_rejected.append({"id": id, "root": root + f, "why": "could not be opened"})
			continue
		if not FileAccess.file_exists(SHIPPED_ROOT + id + "/" + MANIFEST):
			_rejected.append({"id": id, "root": root + f,
					"why": "holds no content/%s/%s" % [id, MANIFEST]})
			continue
		mounted.append(id)
	Engine.set_meta(MOUNTED_META, mounted)


static func _sorted_dirs(base: String) -> Array:
	if not DirAccess.dir_exists_absolute(base):
		return []
	var out := Array(DirAccess.get_directories_at(base))
	out.sort()
	return out


static func _collect(dir: String, ending: String, out: PackedStringArray) -> void:
	var names := Array(DirAccess.get_files_at(dir))
	names.sort()
	for f: String in names:
		if f.ends_with(ending):
			out.append(dir + f)
	for sub: String in _sorted_dirs(dir):
		_collect(dir + sub + "/", ending, out)
