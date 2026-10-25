extends SceneTree

## The planet's trees in the AI's world (Docs/Planets.md 11.10, step 4): each
## trunk a proxy box in the nav regions it stands in (PlanetNavNet.tree_source
## = PlanetTrees.trees_near), so the AI walks round it and hides behind it.
##
##   --headless --path . --script res://tools/planet_tree_ai_probe.gd
##
## In the densest forest found on the default planet: does every trunk in a
## region go into its world; does a path through the forest keep clear of every
## trunk (and would it not, without them); is a trunk cover; does a tree taken
## away (knocked down) leave the region's world and free its spot?

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
	print("[tree-ai] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)
	return true


## Least distance (across the ground) from `p` to any trunk's axis.
func _clear_of(p: Vector3, trunks: Array) -> float:
	var best := INF
	for t in trunks:
		var b: Basis = t.basis
		var d := p - (t.at as Vector3)
		d -= b.y * d.dot(b.y)
		best = minf(best, d.length())
	return best


func _run() -> void:
	var data := PlanetData.new()
	var trees := PlanetTrees.new()
	trees.setup(data)
	# The densest forest: sampled directions, the most trees within 40 m.
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var best := Vector3.UP
	var most := -1
	for k in 600:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var n := trees.trees_near(d, 40.0).size()
		if n > most:
			most = n
			best = d
	print("[tree-ai] densest of 600 spots: %d trees within 40 m" % most)
	_check("a forest on the planet (> 30 trees within 40 m)", most > 30, "%d" % most)
	var with := PlanetNavNet.make(data, best)
	with.tree_source = trees.trees_near
	var bare := PlanetNavNet.make(data, best)
	with.keep_around([data.surface_point(best)], 20.0, 99)
	bare.keep_around([data.surface_point(best)], 20.0, 99)
	var r: PlanetNavNet.Region = with.regions[Vector2i(0, 0)]
	var r0: PlanetNavNet.Region = bare.regions[Vector2i(0, 0)]
	var nr := r.nav_region
	var inv := nr.frame.affine_inverse()
	var inside: Array = []
	for t in trees.trees_near(best, nr.half * 1.42):
		var l := inv * (t.at as Vector3)
		if absf(l.x) <= nr.half and absf(l.z) <= nr.half:
			inside.append(t)
	print("[tree-ai] region (0, 0): %d trees in it, %d proxies in its world, %d without trees; made in %.1f ms (%.1f without)" % [
			inside.size(), r.world.get_proxy_count(), r0.world.get_proxy_count(), r.made_ms, r0.made_ms])
	_check("every trunk in the region is in its world", r.world.get_proxy_count() >= inside.size()
			and r0.world.get_proxy_count() == 0, "%d of %d" % [r.world.get_proxy_count(), inside.size()])
	# A path across the forest, with and without the trunks.
	var w := with.cell_m
	var from := data.surface_point(with._dir_of(Vector2(-0.4 * w, -0.05 * w)))
	var to := data.surface_point(with._dir_of(Vector2(0.4 * w, 0.1 * w)))
	var p1 := with.find_path(from, to, 200000)
	var p0 := bare.find_path(from, to, 200000)
	var clear1 := INF
	var clear0 := INF
	var through0 := 0
	for path_k in 2:
		var path: PackedVector3Array = p1 if path_k == 0 else p0
		for i in range(1, path.size()):
			for s in 4:
				var q := path[i - 1].lerp(path[i], s / 4.0)
				var c := _clear_of(q, inside)
				if path_k == 0:
					clear1 = minf(clear1, c)
				else:
					clear0 = minf(clear0, c)
					if c < 0.35:
						through0 += 1
	print("[tree-ai] across the forest: %d points, %.2f m from the nearest trunk; without trunks %d points, %.2f m (%d samples inside one)" % [
			p1.size(), clear1, p0.size(), clear0, through0])
	_check("a path through the forest", p1.size() > 2 and p1[p1.size() - 1].distance_to(to) < 1.5)
	_check("it keeps clear of every trunk (a body's half and the trunk's, >= 0.45 m)", clear1 >= 0.45,
			"%.2f m" % clear1)
	_check("without the trunks it would walk through some", through0 > 0, "%d samples" % through0)
	# A trunk is cover; taken away (knocked down), it is not, and its spot is free.
	var t0: Dictionary = inside[0]
	for t in inside:
		var lt := inv * (t.at as Vector3)
		if absf(lt.x) < nr.half - 6.0 and absf(lt.z) < nr.half - 6.0:
			t0 = t
			break
	var b: Basis = t0.basis
	var c0 := (t0.at as Vector3) + b.y * 1.0
	var a := c0 - b.x * 3.0
	var z := c0 + b.x * 3.0
	_check("a trunk is cover (bricks across it)", r.world.bricks_between(a, z) > 0 and r0.world.bricks_between(a, z) == 0,
			"%d bricks, %d without" % [r.world.bricks_between(a, z), r0.world.bricks_between(a, z)])
	var foot := (t0.at as Vector3) + b.y * 0.2
	var stood := r.nav.can_stand(foot)
	with.remove_tree(t0.key, t0.index)
	_check("knocked down, it is cover no more", r.world.bricks_between(a, z) == 0, "%d" % r.world.bricks_between(a, z))
	_check("and its spot is walkable again", not stood and r.nav.can_stand(r.nav.snap(foot))
			and r.nav.snap(foot).distance_to(foot) < 0.6, "stood %s, now %.2f m off" % [stood, r.nav.snap(foot).distance_to(foot)])
	trees.free()
