class_name TerrainWorld
extends RefCounted

## World-level decisions about a terrain: things a scene needs to agree on
## before anything is built. [Docs/Terrain.md](../Docs/Terrain.md) §19.10.
##
## The terrain itself is an authored size per world, so these are the numbers
## that come with a world rather than with the generator.


## Where the sea goes, chosen FROM THE TERRAIN.
##
## A fixed metre value is a guess about a generator, and it stopped being
## true the moment the relief went from 2.9 m of range to 48.7: sea level
## 2.8 m left the heightfield scene with no water in it at all, and the
## volumetric scene reported a seabed 15 m ABOVE the sea.
##
## The number that means something across any relief is "how much of the
## ground is under water", so that is what is asked for. Sampled on a coarse
## lattice over the play area — a few hundred field queries, once.
static func sea_level_for(half_tiles: int, drowned := 0.30) -> float:
	var brick := BrickTerrain.get_brick_metres()
	var half := half_tiles * BrickTerrain.get_tile_studs()
	var step: int = maxi(1, half / 12)
	var heights: Array[float] = []
	for gz in range(-half, half + 1, step):
		for gx in range(-half, half + 1, step):
			heights.append(float(BrickTerrain.height_at(gx, gz) + 1) * brick)
	if heights.is_empty():
		return 0.0
	heights.sort()
	var i: int = clampi(int(float(heights.size()) * drowned), 0, heights.size() - 1)
	# Half a brick above the chosen column, so that column is properly under
	# the surface rather than exactly at it.
	return heights[i] + brick * 0.5


## The authored sites for this world: where a building stands, how big its
## pad is, and how many storeys it gets.
##
## Hand-placed on purpose. The terrain is an authored size with authored
## buildings on it, so a site is a decision, not a noise function — and the
## pad it asks for goes into the FIELD, which is what makes the ground agree
## with the building instead of being flattened under it afterwards.
const SITES: Array[Dictionary] = [
	{"tile": Vector2i(0, 0), "radius": 14, "storeys": 6},
	{"tile": Vector2i(3, 1), "radius": 10, "storeys": 3},
	{"tile": Vector2i(-2, 3), "radius": 18, "storeys": 9},
	{"tile": Vector2i(2, -3), "radius": 12, "storeys": 4},
	{"tile": Vector2i(-4, -2), "radius": 16, "storeys": 7},
]


## The world's building sites. Loaded from the world file; the constant
## above is only what a brand new world starts with.
static var sites: Array[Dictionary] = []


## Cut the pads into the field. Before anything is built, because a pad is
## part of what the world IS.
static func stamp_sites() -> void:
	BrickTerrain.clear_pads()
	sites = SITES.duplicate(true)
	stamp_sites_only(sites)


## Cut pads for these sites and touch nothing else.
##
## `stamp_sites` clears the pad list, which is right at load and wrong in the
## editor: an author's hand-placed pads live in the same list, because the
## FIELD only has one kind of flat spot. The editor is what knows which pad
## came from a site.
static func stamp_sites_only(site_list: Array[Dictionary]) -> void:
	var tile := BrickTerrain.get_tile_studs()
	var plate := BrickWorld.get_plate_metres()
	for site in site_list:
		var c: Vector2i = site["tile"]
		var gx: int = c.x * tile + tile / 2
		var gz: int = c.y * tile + tile / 2
		# The pad sits at the natural height of its middle, rounded to a
		# course: a building stands ON the brick grid, not between two of it.
		var here := float(BrickTerrain.surface_plate(gx, gz) + 1) * plate
		var brick := BrickTerrain.get_brick_metres()
		var level := roundf(here / brick) * brick
		BrickTerrain.add_pad(gx, gz, site["radius"], site["radius"] / 2, level)


## Where a site's floor ended up, in metres. Read AFTER stamp_sites.
static func site_level(site: Dictionary) -> float:
	var tile := BrickTerrain.get_tile_studs()
	var plate := BrickWorld.get_plate_metres()
	var c: Vector2i = site["tile"]
	return float(BrickTerrain.surface_plate(c.x * tile + tile / 2,
			c.y * tile + tile / 2) + 1) * plate


# ---------------------------------------------------------------------------
# THE WORLD FILE
#
# A level's terrain is a seed plus the edits an author made to it. The seed is
# one integer and the edits are a short list, so a world is a small JSON file
# rather than a heightmap — and it stays diffable, mergeable and hand-editable,
# which a baked heightfield never is.
#
# Editing terrain is a LEVEL EDITING job. Nothing here is reachable from
# gameplay: the game loads a world and never writes one.

const WORLD_DIR := "res://worlds"


## `-- --world=<name>` picks which level to open, defaulting to `name`.
## One editor, any level: a world is a file, not a scene.
static func world_path(default_name := "heightfield") -> String:
	var chosen := default_name
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--world="):
			chosen = arg.split("=")[1]
	return "%s/%s.json" % [WORLD_DIR, chosen]


## Every world on disk, by name.
static func list_worlds() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(WORLD_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".json"):
			out.append(f.get_basename())
	out.sort()
	return out


## Everything that makes this world this world.
static func to_dict(seed_value: int, drowned: float) -> Dictionary:
	var pads: Array[Dictionary] = []
	for i in BrickTerrain.pad_count():
		pads.append(BrickTerrain.get_pad(i))
	var paints: Array[Dictionary] = []
	for i in BrickTerrain.paint_count():
		paints.append(BrickTerrain.get_paint(i))
	var site_list: Array[Dictionary] = []
	for site in sites:
		var c: Vector2i = site["tile"]
		site_list.append({
			"tile_x": c.x, "tile_z": c.y,
			"radius": int(site["radius"]), "storeys": int(site["storeys"]),
		})
	return {
		"version": 2,
		"seed": seed_value,
		"drowned": drowned,
		"pads": pads,
		"paints": paints,
		"sites": site_list,
	}


## Put the world back, pads and all. Returns the seed.
##
## Applies the pads BEFORE anything reads the field, because a pad is part of
## what the world is rather than something laid over it (§19.12).
static func from_dict(d: Dictionary) -> Dictionary:
	var seed_value := int(d.get("seed", 0))
	BrickTerrain.clear_pads()
	BrickTerrain.clear_paints()
	sites = []
	for p in d.get("pads", []):
		BrickTerrain.add_pad(int(p.get("x", 0)), int(p.get("z", 0)),
			int(p.get("radius", 8)), int(p.get("skirt", 4)),
			float(p.get("height", 0.0)))
	for p in d.get("paints", []):
		BrickTerrain.add_paint(int(p.get("x", 0)), int(p.get("z", 0)),
			int(p.get("radius", 8)), int(p.get("skirt", 4)),
			int(p.get("material", 1)))
	for site in d.get("sites", []):
		sites.append({
			"tile": Vector2i(int(site.get("tile_x", 0)), int(site.get("tile_z", 0))),
			"radius": int(site.get("radius", 10)),
			"storeys": int(site.get("storeys", 4)),
		})
	return {"seed": seed_value, "drowned": float(d.get("drowned", 0.30))}


static func save_world(path: String, seed_value: int, drowned: float) -> Error:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("terrain world: cannot write %s" % path)
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(seed_value, drowned), "\t"))
	f.close()
	return OK


## Returns {} when there is no world there, which is not an error: a level
## that has never been edited is a seed and nothing else.
static func load_world(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("terrain world: %s is not a world file" % path)
		return {}
	return from_dict(parsed)
