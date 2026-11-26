class_name WorldView
extends RefCounted

## HOW THE MINE WORLD IS DRAWN, not what it is (Docs/MineWorld.md 22): how
## far the detail, caves and far rings reach, the real brick edges, the far
## ground's detail, how dark caves get and whether they fade to black at the
## view's end. Changed in the World view menu (world_view_menu.gd) and put
## in with its Apply, in play -- never part of a world's generator settings
## (those only take effect on Generate, and key its saved changes).
##
## Kept for the player in user://profile/world_view.cfg, across worlds. A
## scripted pass (a gate) uses the defaults and never writes the file, as
## the Options menu's settings (CLAUDE.md, test windows).

const PATH := UserPaths.PROFILE + "world_view.cfg"

const DEFAULTS := {
	"detail_tiles": 4,      ## tiles round the eye drawn in full detail
	"cave_tiles": 4,        ## how far caves (the deep tier) are drawn
	"far_tiles": 64,        ## how far the far rings reach (tiles)
	"chamfer": true,        ## real bevelled bricks near the eye (the overlay)
	"far_detail": 0,        ## Distant Ground Detail: 0 High, 1 Medium, 2 Low
	"cave_light": 0.015,    ## the least light a closed cave gets (0 = black)
	"cave_fade": true,      ## caves fade to black where their drawing ends
}

## The limits the menu and the world both clamp to.
const RANGES := {
	"detail_tiles": [2, 8],
	"cave_tiles": [2, 8],
	"far_tiles": [16, 192],
	"far_detail": [0, 2],
	"cave_light": [0.0, 0.15],
}

static var values := DEFAULTS.duplicate()
static var _loaded := false


## The player's values (once), or the defaults for a scripted pass. Values a
## world's generator settings still carry from before this menu existed are
## taken in the first time (`legacy`).
static func load_for(scripted: bool, legacy: Dictionary = {}) -> void:
	values = DEFAULTS.duplicate()
	if scripted:
		_loaded = true
		return
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		for k in DEFAULTS:
			values[k] = cf.get_value("view", k, DEFAULTS[k])
	else:
		for k in ["detail_tiles", "cave_tiles", "far_tiles", "chamfer"]:
			if legacy.has(k):
				values[k] = legacy[k]
	_clamp()
	_loaded = true


static func save() -> void:
	DirAccess.make_dir_recursive_absolute(UserPaths.PROFILE)
	var cf := ConfigFile.new()
	for k in values:
		cf.set_value("view", k, values[k])
	cf.save(PATH)


static func get_value(key: String) -> Variant:
	return values.get(key, DEFAULTS.get(key))


static func _clamp() -> void:
	for k in RANGES:
		var r: Array = RANGES[k]
		if DEFAULTS[k] is int:
			values[k] = clampi(int(values[k]), int(r[0]), int(r[1]))
		else:
			values[k] = clampf(float(values[k]), float(r[0]), float(r[1]))
	values["chamfer"] = bool(values["chamfer"])
	values["cave_fade"] = bool(values["cave_fade"])
