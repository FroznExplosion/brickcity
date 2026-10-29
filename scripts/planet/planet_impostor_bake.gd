class_name PlanetImpostorBake
extends RefCounted

## The planet's far look, baked from the same numbers as its ground (Docs/
## Planets.md 11.1; after STA's ImpostorBaker): an equirectangular heightmap
## of PlanetData.height (pads included) and a colour map by the ground shader's
## own rules (shaders/planet_ground.gdshader), with the sea where the ground is
## under it. So the planet from orbit is the planet on foot.

## Height stored as (h / amplitude) * 0.5 + 0.5, as STA's: the shader recovers
## (r * 2 - 1) * amplitude. In the same pass, the biome map the ground shader
## samples (PlanetBiomes, Planets.md 11.9): the impostor's colours are that
## map's, with the sea, beaches and snow put on as the ground shader puts them.
## How far the densest forest's canopy covers the ground's colour from orbit.
const FOREST_TINT := 0.6


## `textures` false: the images only, for a worker thread (Planets.md 11.12);
## `textured` makes the textures on the main thread after.
static func bake(data: PlanetData, width := 512, height_px := 256, textures := true) -> Dictionary:
	var amp := maxf(data.peak(), 1.0)
	var hm := Image.create(width, height_px, false, Image.FORMAT_RF)
	var cm := Image.create(width, height_px, false, Image.FORMAT_RGB8)
	var bm := Image.create(width, height_px, false, Image.FORMAT_RGBA8)
	var biomes := PlanetBiomes.of(data)
	var snow := Color(0.92, 0.93, 0.96)
	var sand := Color(0.76, 0.70, 0.52)
	var sea_shallow := Color(0.16, 0.42, 0.50)
	var sea_deep := Color(0.04, 0.16, 0.30)
	# From orbit a forest is its trees' canopy over the ground's colour: darker by
	# the biome's trees a hectare (PlanetTrees.TREES) -- the impostor's colours
	# only; the ground on foot has the trees themselves (11.10).
	var canopy := [Color(0.0, 0.0, 0.0), Color(0.07, 0.15, 0.09), Color(0.20, 0.24, 0.10),
			Color(0.11, 0.22, 0.09), Color(0.15, 0.25, 0.10), Color(0.0, 0.0, 0.0),
			Color(0.22, 0.24, 0.10), Color(0.09, 0.25, 0.08)]
	var t0 := Time.get_ticks_msec()
	for y in height_px:
		for x in width:
			var dir := PlanetBiomes.dir_of_pixel(x, y, width, height_px)
			var h := data.height(dir)
			hm.set_pixel(x, y, Color(clampf(h / amp, -1.0, 1.0) * 0.5 + 0.5, 0.0, 0.0))
			var pi := biomes.pixel_index(dir)
			var px: Color = pi[0]
			bm.set_pixel(x, y, px)
			var c := Color(px.r, px.g, px.b)
			var forest := float(PlanetTrees.TREES[int(pi[1])][0]) / PlanetTrees.D_MAX
			if forest > 0.0:
				c = c.lerp(canopy[int(pi[1])], FOREST_TINT * forest)
			var t := PlanetBiomes.temperature_at(lerpf(PlanetBiomes.T_RANGE.x, PlanetBiomes.T_RANGE.y, px.a), h)
			if not is_nan(data.sea_level) and h < data.sea_level:
				c = sea_shallow.lerp(sea_deep, clampf((data.sea_level - h) / 15.0, 0.0, 1.0))
			elif h < data.sea_level + 1.5:
				c = sand
			elif t < 0.0:
				c = c.lerp(snow, 0.85)
			# A town's pad from orbit: concrete grey.
			for pad in data.pads:
				if (dir * data.radius).distance_to((pad.dir as Vector3) * data.radius) < float(pad.flat):
					c = Color(0.55, 0.55, 0.57)
			cm.set_pixel(x, y, c)
	var b := {
		"height_image": hm,
		"biome_image": bm,
		"color_image": cm,
		"amplitude": amp,
		"ms": Time.get_ticks_msec() - t0,
	}
	return textured(b) if textures else b


## The bake's images made textures.
static func textured(b: Dictionary) -> Dictionary:
	b.heightmap = ImageTexture.create_from_image(b.height_image)
	b.color_map = ImageTexture.create_from_image(b.color_image)
	b.biome_map = ImageTexture.create_from_image(b.biome_image)
	return b
