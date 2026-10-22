extends SceneTree

## Test 8 of the sphere-planet feasibility tests (Docs/Planets.md 10b): two
## flat nav regions in frames `deg` apart, joined at a border, and a path
## across them.
##
##   --headless --path . --script res://tools/planet_nav_probe.gd [-- --deg=1.5]
##
## Each region is an AIWorld + AINav of its own, exactly as the city has one,
## seeing ITS region in its own flat frame: the plane y = 0 for ground, walls
## as proxies. Region B is region A's neighbour turned `deg` about their
## shared border -- as two tangent frames of a sphere are. A path from A to B
## is stitched at a portal on the border: the best of portals every 2 m, by A's
## length to it plus B's from it. Then: is the world path continuous where it
## crosses, how sharp is its kink, does each half stay in its own region, and
## how far are the flat regions from the sphere they stand for?

const HALF := 44.8     # a region is 8 x 8 tiles, 256 studs: its border on a stud line
var deg := 1.5
var ok := 0
var fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--deg="):
			deg = float(a.trim_prefix("--deg="))


var _done := false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	quit(1 if fail > 0 else 0)
	return true


## A region: its nav, and its frame (region-local -> world).
func _region(walls: Array) -> Dictionary:
	var bw := BrickWorld.new()
	var aw := AIWorld.new()
	aw.set_world(bw)
	for k in walls.size():
		var w: Array = walls[k]   # [centre, size]
		aw.set_proxy(k, Transform3D(Basis(), w[0]), w[1], 1.0 / BrickWorld.get_stud_metres())
	aw.sync()
	var nav := AINav.new()
	nav.set_ai_world(aw)
	return {"world": bw, "ai": aw, "nav": nav}


func _run() -> void:
	var th := deg_to_rad(deg)
	# A: walls in its own frame. A long wall at x = 20 from z = -45 to 20: the
	# way round it is to the north. B: one at x' = -20 from z' = -20 to 45: the
	# way round is to the south. So the best crossing is somewhere between.
	var a := _region([[Vector3(20.0, 1.5, -12.5), Vector3(1.0, 3.0, 65.0)]])
	var b := _region([[Vector3(-20.0, 1.5, 12.5), Vector3(1.0, 3.0, 65.0)]])
	var fa := Transform3D.IDENTITY
	# B's local origin is HALF past the border, the border its x' = -HALF; it
	# is turned -th about the border line (x = HALF, along Z): downhill, as
	# the next frame round a sphere is.
	var fb := Transform3D(Basis(), Vector3(HALF, 0.0, 0.0)) \
			* Transform3D(Basis(Vector3(0, 0, 1), -th), Vector3.ZERO) \
			* Transform3D(Basis(), Vector3(HALF, 0.0, 0.0))
	var start := Vector3(-30.0, 0.5, 0.0)      # in A
	var goal := Vector3(30.0, 0.5, 0.0)        # in B
	var best := []
	var t0 := Time.get_ticks_usec()
	var tried := 0
	var z := -HALF + 1.0
	while z <= HALF - 1.0:
		var pa: PackedVector3Array = a.nav.find_path(start, Vector3(HALF, 0.5, z), 200000)
		var pb: PackedVector3Array = b.nav.find_path(Vector3(-HALF, 0.5, z), goal, 200000)
		tried += 1
		if pa.size() > 1 and pb.size() > 1:
			var cost := _len(pa) + _len(pb)
			if best.is_empty() or cost < best[0]:
				best = [cost, z, pa, pb]
		z += 2.0
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if best.is_empty():
		_check("a path across the border exists", false)
		return
	var pa: PackedVector3Array = best[2]
	var pb: PackedVector3Array = best[3]
	# Into the world, each half through its own frame.
	var wa := PackedVector3Array()
	for p in pa:
		wa.append(fa * p)
	var wb := PackedVector3Array()
	for p in pb:
		wb.append(fb * p)
	var gap := wa[wa.size() - 1].distance_to(wb[0])
	var din := (wa[wa.size() - 1] - wa[wa.size() - 2]).normalized()
	var dout := (wb[1] - wb[0]).normalized()
	var kink := rad_to_deg(din.angle_to(dout))
	var a_out := 0.0
	for p in pa:
		a_out = maxf(a_out, p.x - HALF)
	var b_out := 0.0
	for p in pb:
		b_out = maxf(b_out, -HALF - p.x)
	print("[nav] regions %.1f deg apart: %d portals tried in %.0f ms; best crosses at z %.0f, %.1f m (%d + %d points)" % [
			deg, tried, ms, best[1], best[0], pa.size(), pb.size()])
	print("[nav] the world path: %.3f m between the halves at the border , the route turning %.2f deg there; A's half %.2f m past the border at most, B's %.2f m" % [
			gap, kink, a_out, b_out])
	_check("the halves meet at the border: one stud column apart, as any two path points (<= 0.36 m)", gap <= 0.36, "%.3f m" % gap)
	_check("each half stays in its own region (< 1 m over)", a_out < 1.0 and b_out < 1.0,
			"%.2f / %.2f m" % [a_out, b_out])
	_check("it goes round both walls", best[0] > 64.0, "%.1f m" % best[0])
	# The regions stand for a sphere of radius HALF*2 / th, tangent to each at
	# its centre; how far is each plane from it at the region's corners?
	var r := (2.0 * HALF) / th
	var corner := sqrt(2.0) * HALF
	var sag := r - sqrt(r * r - corner * corner)
	var tilt_edge := rad_to_deg(asin(corner / r))
	print("[nav] the sphere they stand for: R %.0f m; a region's plane is %.2f m off it at its corners, and its ground tilts %.2f deg there" % [
			r, sag, tilt_edge])
	print("[nav] %d ok, %d FAIL" % [ok, fail])


func _len(p: PackedVector3Array) -> float:
	var s := 0.0
	for i in range(1, p.size()):
		s += p[i].distance_to(p[i - 1])
	return s
