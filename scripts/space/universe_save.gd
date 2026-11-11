class_name UniverseSave
extends RefCounted

## A universe on disk (Docs/Planets.md, "saving"; after zylanntest's Universe and
## its Docs/save_format_and_data_longevity.md): a stable id, a folder of its own,
## a file for the universe and one for each world in it. What the seed makes is
## not saved, only what happened to it, with the world it happened on.
##
## Written whole to a .tmp and renamed over the old file, so a machine that goes
## off leaves the last good one. Every file carries its version: one from a newer
## game than this is refused, not half read. Add fields with a default; never
## rename one or change what it means without a migration and a new VERSION.

const VERSION := 1
const ROOT := UserPaths.SAVES
## The gates': the player's own saves are never touched by one.
const TEST_ROOT := UserPaths.DEV + "saves_test/"
const LAST := "last.cfg"

## The universe asked for this run (a reloaded scene's), over the last one played.
static var active_id := ""

var root := ROOT
## Stable: set once, so a renamed universe keeps its worlds.
var universe_id := ""
var display_name := "Universe"
var seed_value := 1
var created_at := 0


## Every universe under `root`, newest played first: [{id, name, seed, played}].
static func list(p_root := ROOT) -> Array:
	var out := []
	var d := DirAccess.open(p_root)
	if d == null:
		return out
	for id in d.get_directories():
		var u := _read("%s%s/universe.dat" % [p_root, id])
		if not u.is_empty():
			out.append({"id": id, "name": u.get("name", id), "seed": u.get("seed", 1), "played": u.get("played", 0)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.played) > int(b.played))
	return out


## A new universe.
static func make(p_name: String, p_seed: int, p_root := ROOT) -> UniverseSave:
	var s := UniverseSave.new()
	s.root = p_root
	s.display_name = p_name
	s.seed_value = p_seed
	s.created_at = int(Time.get_unix_time_from_system())
	s.universe_id = "%s_%d" % [p_name.to_lower().replace(" ", "_").validate_filename(), s.created_at]
	DirAccess.make_dir_recursive_absolute(s.dir())
	s.write_state({})
	return s


static func open(id: String, p_root := ROOT) -> UniverseSave:
	var u := _read("%s%s/universe.dat" % [p_root, id])
	if u.is_empty():
		return null
	var s := UniverseSave.new()
	s.root = p_root
	s.universe_id = id
	s.display_name = u.get("name", id)
	s.seed_value = u.get("seed", 1)
	s.created_at = u.get("created", 0)
	return s


## The universe to play: the one asked for, or the last one played, or a first.
static func current(p_root := ROOT) -> UniverseSave:
	var id := active_id
	if id == "":
		var c := ConfigFile.new()
		if c.load(p_root + LAST) == OK:
			id = c.get_value("universe", "id", "")
	var s := open(id, p_root) if id != "" else null
	if s == null:
		s = make("Universe 1", 1, p_root)
	s._remember()
	return s


func _remember() -> void:
	var c := ConfigFile.new()
	c.set_value("universe", "id", universe_id)
	c.save(root + LAST)


func dir() -> String:
	return "%s%s/" % [root, universe_id]


## What was last written of the universe: the clock, the player, the ship.
func state() -> Dictionary:
	return _read(dir() + "universe.dat")


func write_state(d: Dictionary) -> void:
	var out := d.duplicate()
	out["name"] = display_name
	out["seed"] = seed_value
	out["created"] = created_at
	out["played"] = int(Time.get_unix_time_from_system())
	_write(dir() + "universe.dat", out)


func world(system: int, body: int) -> Dictionary:
	return _read("%ss%d_b%d.dat" % [dir(), system, body])


func write_world(system: int, body: int, d: Dictionary) -> void:
	_write("%ss%d_b%d.dat" % [dir(), system, body], d)


static func _write(path: String, d: Dictionary) -> void:
	var out := d.duplicate()
	out["format_version"] = VERSION
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("UniverseSave: cannot write %s" % tmp)
		return
	f.store_var(out)
	f.close()
	if DirAccess.rename_absolute(tmp, path) != OK:
		push_warning("UniverseSave: cannot put %s in place" % path)


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = f.get_var()
	if not v is Dictionary:
		return {}
	if int((v as Dictionary).get("format_version", 0)) > VERSION:
		push_warning("UniverseSave: %s is from a newer game -- not read" % path)
		return {}
	return v


## Everything under `p_root` (the gates' only).
static func wipe(p_root: String) -> void:
	var d := DirAccess.open(p_root)
	if d == null:
		return
	for sub in d.get_directories():
		var s := DirAccess.open(p_root + sub)
		for f in s.get_files():
			s.remove(f)
		d.remove(sub)
	for f in d.get_files():
		d.remove(f)
