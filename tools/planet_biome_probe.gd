extends SceneTree

## The planet's biomes (Docs/Planets.md 11.9): PlanetBiomes and the map baked
## with the impostor, on the default planet.
##
##   --headless --path . --script res://tools/planet_biome_probe.gd
##
## The map is what the ground shader colours by, the impostor what orbit sees,
## PlanetBiomes what trees will read: do they agree, is the climate what it
## says (colder poleward and uphill), does every biome turn up, does the
## shader's UV land on the pixel the bake wrote, and is the bake quick enough
## to do at load?

var ok := 0
var fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


var _done := false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("[biomes] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)
	return true


func _run() -> void:
	var data := PlanetData.new()
	var w := 512
	var hpx := 256
	var b := PlanetImpostorBake.bake(data, w, hpx)
	print("[biomes] impostor + biome map %d x %d baked in %d ms" % [w, hpx, b.ms])
	_check("bakes quickly enough to do at load (< 6 s)", int(b.ms) < 6000, "%d ms" % b.ms)
	var bio := PlanetBiomes.of(data)
	var img: Image = b.biome_image
	# The map's pixels are PlanetBiomes at their directions (RGBA8: within a step).
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var worst := 0.0
	for k in 300:
		var x := rng.randi_range(0, w - 1)
		var y := rng.randi_range(0, hpx - 1)
		var want := bio.pixel(PlanetBiomes.dir_of_pixel(x, y, w, hpx))
		var got := img.get_pixel(x, y)
		worst = maxf(worst, maxf(maxf(absf(want.r - got.r), absf(want.g - got.g)), maxf(absf(want.b - got.b), absf(want.a - got.a))))
	_check("the map is PlanetBiomes, pixel by pixel (within one 8-bit step)", worst <= 1.0 / 255.0 + 1e-4,
			"worst %.4f" % worst)
	# From orbit a forest is darker than its ground (its canopy, 11.10), a treeless
	# biome is its ground's colour: land pixels, off the sea, the beach and snow.
	var cimg: Image = b.color_image
	var darker := 0
	var forests := 0
	var bare_same := 0
	var bares := 0
	for k in 3000:
		var x := rng.randi_range(0, w - 1)
		var y := rng.randi_range(0, hpx - 1)
		var d := PlanetBiomes.dir_of_pixel(x, y, w, hpx)
		var h := data.height(d)
		var gp := img.get_pixel(x, y)
		if h < data.sea_level + 2.0 or PlanetBiomes.temperature_at(lerpf(PlanetBiomes.T_RANGE.x, PlanetBiomes.T_RANGE.y, gp.a), h) < 0.5:
			continue
		var on_pad := false
		for pad in data.pads:
			if (d * data.radius).distance_to((pad.dir as Vector3) * data.radius) < float(pad.flat) + 1.0:
				on_pad = true
		if on_pad:
			continue
		var i := bio.biome_index(d)
		var cp := cimg.get_pixel(x, y)
		var lum_g := gp.r * 0.3 + gp.g * 0.59 + gp.b * 0.11
		var lum_c := cp.r * 0.3 + cp.g * 0.59 + cp.b * 0.11
		if float(PlanetTrees.TREES[i][0]) >= 100.0:
			forests += 1
			if lum_c < lum_g - 0.02:
				darker += 1
		elif float(PlanetTrees.TREES[i][0]) == 0.0:
			bares += 1
			if absf(cp.r - gp.r) + absf(cp.g - gp.g) + absf(cp.b - gp.b) <= 3.0 / 255.0:
				bare_same += 1
	print("[biomes] from orbit: %d of %d forest pixels darker than their ground, %d of %d treeless ones its colour" % [
			darker, forests, bare_same, bares])
	_check("from orbit a forest is darker than its ground (its canopy)", forests > 20 and darker == forests,
			"%d of %d" % [darker, forests])
	_check("and a treeless biome is its ground's colour", bares > 20 and bare_same == bares, "%d of %d" % [bare_same, bares])
	# The shader's UV (PlanetBiomes.pixel_of_dir) lands on the pixel the bake wrote.
	var miss := 0
	for k in 300:
		var x := rng.randi_range(0, w - 1)
		var y := rng.randi_range(0, hpx - 1)
		if PlanetBiomes.pixel_of_dir(PlanetBiomes.dir_of_pixel(x, y, w, hpx), w, hpx) != Vector2i(x, y):
			miss += 1
	_check("the shader's lookup lands on the bake's pixel", miss == 0, "%d of 300 off" % miss)
	# Every biome present; tally over a sphere of directions.
	var count := {}
	var n := 20000
	for k in n:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var i := bio.biome_index(d)
		count[i] = int(count.get(i, 0)) + 1
	var line := []
	for i in PlanetBiomes.TABLE.size():
		line.append("%s %.1f%%" % [PlanetBiomes.TABLE[i].name, 100.0 * int(count.get(i, 0)) / n])
	print("[biomes] share of the ground: " + ", ".join(line))
	var absent := []
	for i in PlanetBiomes.TABLE.size():
		if int(count.get(i, 0)) < n * 0.005:
			absent.append(PlanetBiomes.TABLE[i].name)
	_check("every biome turns up (>= 0.5% of the planet)", absent.is_empty(), "rare: %s" % ", ".join(absent))
	# Colder poleward: the mean temperature in bands of latitude about the axis.
	var ax := data.climate_axis.normalized()
	var x0 := ax.cross(Vector3.FORWARD).normalized()
	var bands := []
	for deg in [0.0, 30.0, 60.0, 85.0]:
		var s := 0.0
		for k in 64:
			var lon := TAU * k / 64.0
			var eq := x0.rotated(ax, lon)
			s += bio.temperature_sea(eq.rotated(eq.cross(ax).normalized(), -deg_to_rad(deg)).normalized())
		bands.append(s / 64.0)
	print("[biomes] mean sea-level temperature at 0/30/60/85 deg: %.1f / %.1f / %.1f / %.1f C" % bands)
	_check("colder toward the poles", bands[0] > bands[1] and bands[1] > bands[2] and bands[2] > bands[3])
	_check("and from tropics to ice (equator > 20 C, poles < -5 C)", bands[0] > 20.0 and bands[3] < -5.0)
	_check("colder uphill (lapse %.2f C a metre)" % PlanetBiomes.LAPSE,
			PlanetBiomes.temperature_at(10.0, 40.0) == 10.0 - 40.0 * PlanetBiomes.LAPSE
			and PlanetBiomes.temperature_at(10.0, -5.0) == 10.0)
	# The proto's spawn (scenes/planet.tscn) is temperate.
	var spawn := Vector3(0.12, 1.0, -0.08).normalized()
	var at: String = PlanetBiomes.TABLE[bio.biome_index(spawn)].name
	print("[biomes] the spawn: %s, %.1f C at sea level" % [at, bio.temperature_sea(spawn)])
	_check("the spawn is temperate (0 .. 22 C)", bio.temperature_sea(spawn) > 0.0 and bio.temperature_sea(spawn) < 22.0)
