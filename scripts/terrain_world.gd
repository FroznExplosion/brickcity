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
	@warning_ignore("integer_division")
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


## THE sea level of the loaded world, in metres. -INF until a world is loaded
## or stamped.
##
## One number that every consumer reads — the water, the pads, navigation —
## so they cannot disagree about where the shore is (§21.6). It is a property
## of the WORLD: its seed and its drowned fraction, sampled over a fixed
## `SEA_TILES` around the origin on the field as generated, BEFORE any pad is
## cut. Sampled after, it would move every time an author moved a building,
## and a scene sampling a different area would put the sea somewhere else.
static var sea_level := -INF
## How much ground the drowned fraction is measured over, in tiles each way.
## What the heightfield scene has always used (max(NEAR_TILES, 8)).
const SEA_TILES := 8
## A site's pad never sits lower than this above the sea: a building stands
## on a quay, not in the water.
const FREEBOARD_BRICKS := 1


## Measure the sea for this world. On the RAW field: call with no pads in it.
static func settle_sea(drowned: float) -> float:
	sea_level = sea_level_for(SEA_TILES, drowned)
	BrickWave.set_sea_level(sea_level)
	return sea_level


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
static func stamp_sites(drowned := 0.30) -> void:
	BrickTerrain.clear_pads()
	BrickTerrain.clear_sculpt()
	settle_sea(drowned)
	sites = SITES.duplicate(true)
	stamp_sites_only(sites)


## Cut pads for these sites and touch nothing else.
##
## `stamp_sites` clears the pad list, which is right at load and wrong in the
## editor: an author's hand-placed pads live in the same list, because the
## FIELD only has one kind of flat spot. The editor is what knows which pad
## came from a site.
static func stamp_sites_only(site_list: Array[Dictionary]) -> void:
	var plate := BrickWorld.get_plate_metres()
	var brick := BrickTerrain.get_brick_metres()
	for site in site_list:
		var c := site_centre(site)
		# The pad sits at the natural height of its middle, rounded to a
		# course: a building stands ON the brick grid, not between two of it.
		var here := float(BrickTerrain.surface_plate(c.x, c.y) + 1) * plate
		var level := roundf(here / brick) * brick
		# Unless the author set the floor (the editor's - / =): then the
		# ground comes to the building, up or down.
		if site.has("level"):
			level = roundf(float(site["level"]) / brick) * brick
		# And never in the sea (§21.6): a site on low ground gets a quay.
		if sea_level > -INF:
			level = maxf(level, ceilf(sea_level / brick + FREEBOARD_BRICKS) * brick)
		# A RECTANGLE, the footprint plus the site's margin all round: the
		# ground is flattened where the building and its pavement are, not
		# over a square of hillside sized for its long side.
		var half := site_pad_half(site)
		BrickTerrain.add_pad(c.x, c.y, half.x, site_skirt(site), level, half.y)


## Where a site's floor ended up, in metres. Read AFTER stamp_sites.
static func site_level(site: Dictionary) -> float:
	var plate := BrickWorld.get_plate_metres()
	var c := site_centre(site)
	return float(BrickTerrain.surface_plate(c.x, c.y) + 1) * plate


## The column a site's middle stands on, in studs.
##
## A site placed in the editor is addressed by TILE and stands in the tile's
## middle. A site that came from somewhere with a finer lattice — the city's
## street grid — carries its own `centre`, because a tile is 32 studs and a
## street is nine.
static func site_centre(site: Dictionary) -> Vector2i:
	if site.has("centre"):
		return site["centre"]
	var tile := BrickTerrain.get_tile_studs()
	var c: Vector2i = site["tile"]
	@warning_ignore("integer_division")
	return Vector2i(c.x * tile + tile / 2, c.y * tile + tile / 2)


## A site's footprint in studs, X by Z.
##
## Its own when it has one (the city's shapes are not square), otherwise one
## that FILLS the pad, snapped to the city's panel grid:
## `TowerRecipe.conforming` is what the recipe tables assume, and a building
## off that grid has columns standing in the wrong places.
static func site_footprint(site: Dictionary) -> Vector2i:
	if site.has("footprint"):
		return site["footprint"]
	var want: int = int(site["radius"]) * 2
	var f: int = maxi(TowerRecipe.PANEL,
			int(float(want) / float(TowerRecipe.PANEL)) * TowerRecipe.PANEL)
	return Vector2i(f, f)


## A site's footprint MIN CORNER, in studs — where a recipe builds from.
static func site_corner(site: Dictionary) -> Vector2i:
	var f := site_footprint(site)
	@warning_ignore("integer_division")
	return site_centre(site) - Vector2i(f.x / 2, f.y / 2)


## A site's pad, as half-extents in studs: the footprint's half plus the
## margin its radius gives over the footprint's long side. A square site (an
## editor's) is `radius` each way, as it always was.
static func site_pad_half(site: Dictionary) -> Vector2i:
	var f := site_footprint(site)
	@warning_ignore("integer_division")
	var margin: int = maxi(int(site["radius"]) - maxi(f.x, f.y) / 2, 0)
	@warning_ignore("integer_division")
	return Vector2i(f.x / 2 + margin, f.y / 2 + margin)


static func site_skirt(site: Dictionary) -> int:
	@warning_ignore("integer_division")
	return int(site.get("skirt", int(site["radius"]) / 2))


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
		var row := {
			"tile_x": c.x, "tile_z": c.y,
			"radius": int(site["radius"]), "storeys": int(site["storeys"]),
		}
		# Only what a site says for itself: an editor site is a tile, a
		# radius and storeys, and its file entry stays that small.
		if site.has("centre"):
			row["x"] = site["centre"].x
			row["z"] = site["centre"].y
		if site.has("footprint"):
			row["footprint_x"] = site["footprint"].x
			row["footprint_z"] = site["footprint"].y
		if site.has("skirt"):
			row["skirt"] = int(site["skirt"])
		if site.has("program"):
			row["program"] = site["program"]
		if site.has("level"):
			row["level"] = float(site["level"])
		site_list.append(row)
	return {
		"version": 3,
		"seed": seed_value,
		"drowned": drowned,
		"pads": pads,
		"paints": paints,
		"sites": site_list,
		"sculpt": sculpt_to_list(),
	}


## The sculpted strokes (§20.6) and the surface paint (§20.7), a tile at a
## time: heights in metres as base64 float32, paint as base64 bytes
## (materials, then colours; 255 = not painted). Only what a tile carries.
static func sculpt_to_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in BrickTerrain.sculpt_tiles():
		var c: Vector2i = t
		var row := {"tx": c.x, "tz": c.y}
		var data: PackedFloat32Array = BrickTerrain.get_sculpt_tile(c.x, c.y)
		for v in data:
			if absf(v) > 1e-4:
				row["data"] = Marshalls.raw_to_base64(data.to_byte_array())
				break
		var paint: PackedByteArray = BrickTerrain.get_surface_paint_tile(c.x, c.y)
		for v in paint:
			if v != 255:
				row["paint"] = Marshalls.raw_to_base64(paint)
				break
		if row.size() > 2:
			out.append(row)
	return out


static func sculpt_from_list(list: Array) -> void:
	for t in list:
		var tx := int(t.get("tx", 0))
		var tz := int(t.get("tz", 0))
		if t.has("data"):
			BrickTerrain.set_sculpt_tile(tx, tz,
					Marshalls.base64_to_raw(String(t["data"])).to_float32_array())
		if t.has("paint"):
			BrickTerrain.set_surface_paint_tile(tx, tz,
					Marshalls.base64_to_raw(String(t["paint"])))


## Put the world back, pads and all. Returns the seed.
##
## Applies the pads BEFORE anything reads the field, because a pad is part of
## what the world is rather than something laid over it (§19.12).
static func from_dict(d: Dictionary) -> Dictionary:
	var seed_value := int(d.get("seed", 0))
	BrickTerrain.clear_pads()
	BrickTerrain.clear_paints()
	BrickTerrain.clear_sculpt()
	# The sea BEFORE the sculpt and the pads: it is measured on the field as
	# generated, so digging a lake does not move the ocean.
	settle_sea(float(d.get("drowned", 0.30)))
	sculpt_from_list(d.get("sculpt", []))
	sites = []
	for p in d.get("pads", []):
		BrickTerrain.add_pad(int(p.get("x", 0)), int(p.get("z", 0)),
			int(p.get("radius", 8)), int(p.get("skirt", 4)),
			float(p.get("height", 0.0)), int(p.get("radius_z", -1)))
	for p in d.get("paints", []):
		BrickTerrain.add_paint(int(p.get("x", 0)), int(p.get("z", 0)),
			int(p.get("radius", 8)), int(p.get("skirt", 4)),
			int(p.get("material", 1)))
	for site in d.get("sites", []):
		var row := {
			"tile": Vector2i(int(site.get("tile_x", 0)), int(site.get("tile_z", 0))),
			"radius": int(site.get("radius", 10)),
			"storeys": int(site.get("storeys", 4)),
		}
		if site.has("x"):
			row["centre"] = Vector2i(int(site["x"]), int(site["z"]))
		if site.has("footprint_x"):
			row["footprint"] = Vector2i(int(site["footprint_x"]), int(site["footprint_z"]))
		if site.has("skirt"):
			row["skirt"] = int(site["skirt"])
		if site.has("level"):
			row["level"] = float(site["level"])
		if site.has("program"):
			# JSON has no integers; a room count is one.
			var program := {}
			for k in site["program"]:
				program[k] = int(site["program"][k])
			row["program"] = program
		sites.append(row)
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
