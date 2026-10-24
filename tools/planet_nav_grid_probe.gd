extends SceneTree

## The planet nav region's ground grid (Docs/Planets.md 11.8, N1b): a region
## of 1024 x 1024 studs over the default planet, a pad at its centre.
##
##   --headless --path . --script res://tools/planet_nav_grid_probe.gd
##
## The grid is what AIWorld will read as the region's ground, so: is every
## sample on the planet's ground, does the bilinear read stay within a plate of
## the true ground between samples, is the floor under all of it, is a level
## pad level (save the sphere's own sag), is the region's tilt what 11.8 says,
## and does it build quickly enough to make off the fight's path?

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
	print("[nav-grid] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)
	return true


func _run() -> void:
	var data := PlanetData.new()
	var dir := Vector3(0.12, 1.0, -0.08).normalized()
	var pad := {"dir": dir, "height": 20.0, "flat": 60.0, "blend": 40.0}
	data.pads.append(pad)
	var r := PlanetNavRegion.make(data, dir)
	var plate := BrickWorld.get_plate_metres()
	print("[nav-grid] %d x %d samples, %.2f m apart, half width %.1f m; built in %.0f ms" % [
			r.size, r.size, r.step_m, r.half, r.build_ms])
	_check("builds off the fight's path (< 2 s)", r.build_ms < 2000.0, "%.0f ms" % r.build_ms)
	# Every sample on the ground: its point's altitude is the planet's height there.
	var worst_on := 0.0
	var low := INF
	for j in range(0, r.size, 7):
		for i in range(0, r.size, 7):
			var h: float = r.heights[j * r.size + i]
			low = minf(low, h)
			var p := r.frame * Vector3(-r.half + i * r.step_m, h, -r.half + j * r.step_m)
			worst_on = maxf(worst_on, absf(p.length() - data.radius - data.height(p.normalized())))
	for h in r.heights:
		low = minf(low, h)
	_check("every sample is on the ground (< 1 cm)", worst_on < 0.01, "%.4f m" % worst_on)
	_check("the floor is under all of it (heights >= %.1f m)" % PlanetNavRegion.FLOOR_MARGIN,
			low >= PlanetNavRegion.FLOOR_MARGIN - 0.001, "lowest %.3f m" % low)
	# Between samples, the bilinear read against the true ground.
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst_mid := 0.0
	for k in 400:
		var lx := rng.randf_range(-r.half, r.half)
		var lz := rng.randf_range(-r.half, r.half)
		worst_mid = maxf(worst_mid, absf(r.ground_at(lx, lz) - r._ground_y(lx, lz)))
	_check("between samples it is within a plate of the ground (< %.3f m)" % plate, worst_mid < plate,
			"worst %.3f m" % worst_mid)
	_check("outside the region the ground is a wall", r.ground_at(r.half + 1.0, 0.0) == INF
			and r.ground_at(0.0, -r.half - 1.0) == INF)
	# The pad: level ground, so in the frame only the sphere's sag, x^2 / 2R.
	var drop := (r.frame.origin.length() - data.radius)
	var worst_pad := 0.0
	for k in 200:
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(0.0, 55.0)
		var lx := cos(a) * d
		var lz := sin(a) * d
		var want := float(pad.height) - drop - (lx * lx + lz * lz) / (2.0 * (data.radius + float(pad.height)))
		worst_pad = maxf(worst_pad, absf(r.ground_at(lx, lz) - want))
	_check("a level pad reads level, but for the sphere's sag (< 2 cm)", worst_pad < 0.02, "%.4f m" % worst_pad)
	# The tilt at a corner: 11.8 says 1.45 deg at 10 km for 1024 studs.
	var corner := r.frame * Vector3(r.half, r.ground_at(r.half - 0.01, r.half - 0.01), r.half)
	var tilt := rad_to_deg(r.frame.basis.y.angle_to(corner.normalized()))
	print("[nav-grid] at a corner the true up is %.2f deg from the region's" % tilt)
	_check("its corners tilt as 11.8 says (1.3 .. 1.6 deg)", tilt > 1.3 and tilt < 1.6, "%.2f deg" % tilt)
	# The sea: at the centre, its surface is sea_level over the datum.
	var s := r.frame * Vector3(0.0, r.sea_y, 0.0)
	_check("the sea's level in the frame", absf(s.length() - data.radius - data.sea_level) < 0.001,
			"%.4f m" % (s.length() - data.radius - data.sea_level))
	# Its frame is the tangent frame Gravity uses there.
	var x := r.frame.basis.x
	var ref := Vector3.FORWARD if absf(dir.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	_check("its axes are Gravity.tangent_basis's", x.is_equal_approx(ref.cross(dir).normalized()))
