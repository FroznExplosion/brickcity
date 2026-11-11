class_name UserPaths
extends RefCounted

## Where everything the game writes for a player lives, and the one-time move
## from the old flat layout. Docs/Content.md, "The player's folder".
##
##     user://
##       settings.cfg     options (MenuSettings)
##       saves/           universes (UniverseSave)
##       mods/            content packs dropped in (ContentPacks)
##       library/         what the player has MADE, shaped like a pack:
##                        builds/ rooms/ items/ guns/ mechs/ figures/ parts/
##       profile/         who the player is: character, checkpoint, dressing, tally
##       workshop/        how the workshops were left: hotbars, toolbars,
##                        quick saves, autosave, catalogue filters
##       exports/         files written to take elsewhere: assets/ parts/
##       dev/             nothing a player needs: probe files, shots, test
##                        saves, look tuning. Safe to delete whole.
##
## `library/` has a pack's folders (ContentPacks.FOLDERS) on purpose: add a
## pack.json to a copy of it and it is a mod.
##
## A script names its path with these, so loading that script loads this one,
## and loading this one moves an old layout over (`_static_init`) before
## anything is read.
##
## This script names no other class of the game's, so anything may use it.

const ROOT := "user://"
const SETTINGS := "user://settings.cfg"
const SAVES := "user://saves/"
const MODS := "user://mods/"
const LIBRARY := "user://library/"
const PROFILE := "user://profile/"
const WORKSHOP := "user://workshop/"
const EXPORTS := "user://exports/"
const DEV := "user://dev/"

## The folders made at start, so a writer never meets a missing one.
const MADE := ["library/", "profile/", "workshop/", "exports/", "dev/"]

## Old place -> new place, both under user://. A name ending in / is a folder,
## moved file by file. Never reorder into a chain (a new place that is another
## row's old place): each row is moved once, top to bottom.
const MOVES := [
	# the player's library
	["builds/", "library/builds/"],
	["rooms/", "library/rooms/"],
	["items/", "library/items/"],
	["guns/", "library/guns/"],
	["mechs/", "library/mechs/"],
	["figures/", "library/figures/"],
	["parts/custom/", "library/parts/"],
	["parts/designs/", "library/parts/designs/"],
	# the player
	["character.json", "profile/character.json"],
	["checkpoint.area", "profile/checkpoint.area"],
	["parts/dressing.json", "profile/dressing.json"],
	["tactics_tally.json", "profile/tactics_tally.json"],
	# the workshops
	["workshop_hotbar.json", "workshop/hotbar.json"],
	["workshop_build.json", "workshop/quick_build.json"],
	["asset_workshop.cfg", "workshop/asset.cfg"],
	["asset_workshop_autosave.json", "workshop/asset_autosave.json"],
	["asset_workshop_hotbar.json", "workshop/asset_hotbar.json"],
	["asset_workshop_quick.json", "workshop/asset_quick.json"],
	["asset_workshop_toolbars.json", "workshop/asset_toolbars.json"],
	["asset_catalog.json", "workshop/asset_catalog.json"],
	["swarm_authoring.json", "workshop/swarm_authoring.json"],
	# files to take elsewhere
	["asset_exports/", "exports/assets/"],
	["parts/export/", "exports/parts/"],
	# nothing a player needs
	["parts/placeholder/", "dev/parts_placeholder/"],
	["asset_shots/", "dev/asset_shots/"],
	["saves_test/", "dev/saves_test/"],
	["print_look.cfg", "dev/print_look.cfg"],
	["editor_shot_world.json", "dev/editor_shot_world.json"],
]

const _DONE_META := "user_paths_moved"


static func _static_init() -> void:
	# Once a run: a reloaded scene loads scripts again (Godot 4.6).
	if Engine.has_meta(_DONE_META):
		return
	Engine.set_meta(_DONE_META, true)
	migrate()


## Move an old layout under `root` to the new one, and make the folders.
## Returns what moved: ["old -> new", ...].
##
## Safe to run every start and safe beside an older build of the game that
## still writes the old places: a file is moved only where the new place has
## none of its name, so nothing is ever written over, and what an older build
## writes later is moved the next time.
static func migrate(root := ROOT) -> PackedStringArray:
	var moved := PackedStringArray()
	for d: String in MADE:
		DirAccess.make_dir_recursive_absolute(root + d)
	for row: Array in MOVES:
		var from: String = root + row[0]
		var to: String = root + row[1]
		if from.ends_with("/"):
			if DirAccess.dir_exists_absolute(from):
				_move_dir(from, to, moved)
		elif FileAccess.file_exists(from) and not FileAccess.file_exists(to):
			DirAccess.make_dir_recursive_absolute(to.get_base_dir())
			if DirAccess.rename_absolute(from, to) == OK:
				moved.append("%s -> %s" % [row[0], row[1]])
	# The old parts/ held four of the rows above; gone once they are.
	_remove_if_empty(root + "parts/")
	if not moved.is_empty():
		print("[user] moved %d file(s) to the new folders (Docs/Content.md)" % moved.size())
	return moved


## Where a library folder is: `library("builds")` is "user://library/builds/".
static func library(folder: String) -> String:
	return LIBRARY + folder + "/"


static func _move_dir(from: String, to: String, moved: PackedStringArray) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for f in DirAccess.get_files_at(from):
		if not FileAccess.file_exists(to + f) and DirAccess.rename_absolute(from + f, to + f) == OK:
			moved.append("%s -> %s" % [from + f, to + f])
	for sub in DirAccess.get_directories_at(from):
		_move_dir(from + sub + "/", to + sub + "/", moved)
	_remove_if_empty(from)


static func _remove_if_empty(dir: String) -> void:
	if DirAccess.dir_exists_absolute(dir) and DirAccess.get_files_at(dir).is_empty() \
			and DirAccess.get_directories_at(dir).is_empty():
		DirAccess.remove_absolute(dir.trim_suffix("/"))
