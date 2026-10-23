class_name PlanetImpostorBake
extends RefCounted

## The planet's far look, baked from the same numbers as its ground (Docs/
## Planets.md 11.1; after STA's ImpostorBaker): an equirectangular heightmap
## of PlanetData.height (pads included) and a colour map by the ground shader's
## own rules (shaders/planet_ground.gdshader), with the sea where the ground is
## under it. So the planet from orbit is the planet on foot.

## Height stored as (h / amplitude) * 0.5 + 0.5, as STA's: the shader recovers
## (r * 2 - 1) * amplitude.
static func bake(data: PlanetData, width := 512, height_px := 256) -> Dictionary:
	var amp := maxf(data.peak(), 1.0)
	var hm := Image.create(width, height_px, false, Image.FORMAT_RF)
	var cm := Image.create(width, height_px, false, Image.FORMAT_RGB8)
	var grass := Color(0.36, 0.47, 0.27)
	var rock := Color(0.46, 0.43, 0.40)
	var snow := Color(0.92, 0.93, 0.96)
	var sand := Color(0.76, 0.70, 0.52)
	var sea_shallow := Color(0.16, 0.42, 0.50)
	var sea_deep := Color(0.04, 0.16, 0.30)
	var t0 := Time.get_ticks_msec()
	for y in height_px:
		var v := (float(y) + 0.5) / float(height_px)
		var lat := (0.5 - v) * PI
		for x in width:
			var u := (float(x) + 0.5) / float(width)
			var lon := (u - 0.5) * TAU
			var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
			var h := data.height(dir)
			hm.set_pixel(x, y, Color(clampf(h / amp, -1.0, 1.0) * 0.5 + 0.5, 0.0, 0.0))
			var c := grass
			if not is_nan(data.sea_level) and h < data.sea_level:
				c = sea_shallow.lerp(sea_deep, clampf((data.sea_level - h) / 15.0, 0.0, 1.0))
			elif h < data.sea_level + 1.5:
				c = sand
			elif h > 34.0:
				c = snow
			elif h > 26.0:
				c = rock
			cm.set_pixel(x, y, c)
	return {
		"heightmap": ImageTexture.create_from_image(hm),
		"color_map": ImageTexture.create_from_image(cm),
		"amplitude": amp,
		"ms": Time.get_ticks_msec() - t0,
	}
