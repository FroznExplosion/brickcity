extends RefCounted

## World-gen presets for the mine world (Docs/MineWorld.md 6).
##
## A preset is a JSON file:
##
##     {"name": "Default", "seed": 1234,
##      "gen": {<BrickTerrain.get_gen_params keys, any subset>},
##      "trees": {"<biome name>": 0.0..1.0, ...},
##      "detail_tiles": 4, "far_tiles": 64, "cave_tiles": 4, "chamfer": true,
##      "bricks": {<the ground's brick fill, DEFAULT_BRICKS' keys, any subset>}}
##
## Shipped ones are content (`worldgen/` in every pack, ContentPacks); the
## player's own are saved under user://library/worldgen/ (UserPaths). A
## player preset of a shipped one's name is listed instead of it.
##
## Preloaded by path, not named: a new class_name is not in the class cache
## until the editor rescans.

const FOLDER := "worldgen"

## Trees per candidate spot (Trees.SPACING studs apart), by biome name.
const DEFAULT_TREES := {
	"Plains": 0.03, "Forest": 0.55, "Birch Forest": 0.5, "Dark Forest": 0.85,
	"Taiga": 0.5, "Snowy Plains": 0.02, "Snowy Taiga": 0.4, "Savanna": 0.06,
	"Jungle": 0.8, "Meadow": 0.02, "Windswept Hills": 0.08,
}
## The ground's brick fill (Docs/TerrainRegions.md 11; TerrainFit.configure):
## shares of each footprint by count (loose: within about 5 points), aimed
## higher in proportion on the 2- and 3-wide ones (`aim`); tall bricks (2 and
## 3 courses) as shares; the stagger (0 = always the best; more = weaker),
## the caves' (near cave air); the chance a brick crosses a tile edge; and
## bands by depth under the surface with their own shapes and tall shares.
## Sand, red sand and gravel are always 1x1, whatever this says.
const DEFAULT_BRICKS := {
	"shapes": {
		"2x4": 0.20, "2x2": 0.20, "1x3": 0.03, "1x4": 0.03, "1x5": 0.02, "1x6": 0.02,
		"2x3": 0.04, "2x5": 0.02, "2x6": 0.03, "3x3": 0.02, "3x4": 0.02, "3x5": 0.01, "3x6": 0.01,
		"1x2": 0.25, "1x1": 0.10,
	},
	"tall2": 0.07, "tall3": 0.03,
	"aim": 0.3,
	"stagger": 0.0, "cave_stagger": 0.35,
	"cross": 1.0,
	"mixed": true,
	"bands": [{
		"below_m": 12.0,
		"shapes": {
			"2x4": 0.22, "2x6": 0.10, "2x2": 0.15, "3x4": 0.06, "3x6": 0.05, "3x3": 0.04, "2x3": 0.05,
			"1x4": 0.04, "1x6": 0.03, "1x2": 0.18, "1x1": 0.08,
		},
		"tall2": 0.13, "tall3": 0.07,
	}],
}
## Which of Trees' four variants grow in a biome (none listed: any).
const BIOME_VARIANTS := {
	"Birch Forest": [2], "Dark Forest": [0, 1], "Taiga": [1], "Snowy Taiga": [1],
	"Savanna": [3], "Jungle": [0, 2, 3], "Windswept Hills": [1, 3],
}


static func user_dir() -> String:
	return UserPaths.library(FOLDER)


## Every preset: [{"name", "path", "builtin"}], shipped first, by name.
static func list() -> Array:
	var by_name := {}
	for path in ContentPacks.files(FOLDER):
		var d := read(path)
		var n := str(d.get("name", path.get_file().get_basename()))
		by_name[n] = {"name": n, "path": path, "builtin": true}
	var dir := DirAccess.open(user_dir())
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".json"):
				var path := user_dir() + f
				var d := read(path)
				var n := str(d.get("name", f.get_basename()))
				by_name[n] = {"name": n, "path": path, "builtin": false}
	var out := by_name.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.builtin != b.builtin:
			return a.builtin
		return str(a.name) < str(b.name))
	return out


static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v = JSON.parse_string(f.get_as_text())
	return v if v is Dictionary else {}


## A preset's full settings: the generator's defaults with the file on top,
## so a preset only has to say what it changes.
static func load_settings(path: String) -> Dictionary:
	return complete(read(path))


## Defaults filled in under whatever `d` says.
static func complete(d: Dictionary) -> Dictionary:
	BrickTerrain.reset_gen_params()
	var gen: Dictionary = BrickTerrain.get_gen_params()
	var over: Dictionary = d.get("gen", {})
	for k in over:
		if k == "biomes" or k == "ores" or k == "bands":
			continue
		gen[k] = over[k]
	if over.has("bands"):
		gen["bands"] = (over["bands"] as Array).duplicate(true)
	# Water (Docs/MineWater.md 9): on unless a preset turns it off; the wave
	# height is the mine world's, not the generator's.
	if not over.has("water"):
		gen["water"] = true
	if not over.has("wave_scale"):
		gen["wave_scale"] = 1.0
	# Lava pools in deep caves and springs out of cliffs (MineWater.md stage 8).
	if not over.has("lava_pools"):
		gen["lava_pools"] = true
	if not over.has("springs"):
		gen["springs"] = true
	if not over.has("lakes"):
		gen["lakes"] = true
	if not over.has("cave_pools"):
		gen["cave_pools"] = true
	# Biomes and ores by NAME, so a preset can name only the ones it changes
	# and a file outlives a reordering.
	for key in ["biomes", "ores"]:
		if not over.has(key):
			continue
		for row in over[key]:
			for have in gen[key]:
				if str(have.get("name", "")) == str(row.get("name", "")):
					for k in row:
						have[k] = row[k]
	var trees := DEFAULT_TREES.duplicate()
	var t: Dictionary = d.get("trees", {})
	for k in t:
		trees[k] = float(t[k])
	return {
		"name": str(d.get("name", "Custom")),
		"seed": int(d.get("seed", 20261116)),
		"gen": gen,
		"trees": trees,
		"detail_tiles": int(d.get("detail_tiles", 4)),
		"far_tiles": int(d.get("far_tiles", 64)),
		"cave_tiles": int(d.get("cave_tiles", d.get("detail_tiles", 4))),
		"chamfer": bool(d.get("chamfer", true)),
		"spawn": d.get("spawn", null),
		"bricks": complete_bricks(d.get("bricks", {})),
	}


## DEFAULT_BRICKS under whatever `b` says; `shapes` and `bands`, when given,
## replace the defaults' whole (a mix is one thing).
static func complete_bricks(b: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULT_BRICKS.duplicate(true)
	for k in b:
		out[k] = b[k].duplicate(true) if (b[k] is Dictionary or b[k] is Array) else b[k]
	return out


## Save the settings as the player's preset of their name. Returns the path.
static func save(settings: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(user_dir())
	var n := str(settings.get("name", "Custom")).strip_edges()
	if n == "":
		n = "Custom"
	var path := user_dir() + _file_name(n) + ".json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	var out := settings.duplicate(true)
	out["name"] = n
	f.store_string(JSON.stringify(out, "\t"))
	return path


static func remove(path: String) -> bool:
	if not path.begins_with(user_dir()):
		return false   # a shipped preset is not the player's to delete
	return DirAccess.remove_absolute(path) == OK


static func _file_name(n: String) -> String:
	var out := ""
	for ch in n.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out
