extends SceneTree

## What a small cut costs a standing building's grounding check, now and with a
## local search (Docs/DestructionFirstPrinciples.md A4.1, B3.2). A measurement,
## not a gate: it asserts only that the two answers agree.
##
##     godot --headless --path . --script tools/probes/ground_search_probe.gd
##
## Now: a hit marks the building dirty and its structure is solved whole --
## solve_grounded floods every live block from the foundation (solve_stress
## does that and more), on a worker when the city could start it a tick ahead
## and on the main thread when a hit made that answer stale (city_scene.gd
## _start_solves). So a single brick knocked out of a big tower walks the tower.
##
## The alternative (A4.1): from each block that touched the one that went, walk
## lowest first until the ground is reached (it stands) or there is nowhere left
## to go (it falls, and what was walked is the piece). A wall is found standing
## in about its height; a piece that falls is walked once, which spawning it
## needs anyway.
##
## For towers of rising size, a few dozen random single-brick kills each: the
## time of solve_grounded and solve_stress, and the blocks each way walks.
## Timing needs the editor closed (CLAUDE.md); the walk counts do not.

var _w: BrickWorld
var _palette: Dictionary
var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("what a small cut costs a standing building's grounding check")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	for spec in [[28, 16, 30], [28, 16, 120], [40, 40, 180], [40, 40, 360]]:
		_tower(spec[0], spec[1], spec[2])
	print("\nground_search_probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


static func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[s.size() / 2])


func _tower(fx: int, fz: int, courses: int) -> void:
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(_w, c, _palette, fx, fz, courses)
	# The structure as script data: each live structural block's bottom and
	# neighbours (what the local search would read from the joint cache).
	var ids := PackedInt32Array()
	for g in _w.get_components(c):
		ids.append_array(g)
	var bottom := {}
	var nbrs := {}
	var low := 1 << 30
	for id in ids:
		if _w.is_block_decorative(c, id):
			continue
		var y: int = StructureReplayer.block_cell(_w, c, id).y
		bottom[id] = y
		low = mini(low, y)
		nbrs[id] = _w.get_block_neighbours(c, id)
	var g0: PackedByteArray = _w.solve_grounded(c)
	var standing := 0
	for id in bottom:
		standing += g0[id]
	print("\ntower %d x %d, %d courses: %d structural bricks, %d standing at the start" % [fx, fz,
			courses, bottom.size(), standing])

	var rng := RandomNumberGenerator.new()
	rng.seed = 7 + courses
	var keys: Array = bottom.keys()
	var dead := {}
	var t_ground := []
	var t_stress := []
	var walked := []
	var flood_walked := []
	var falls := 0
	var agree := 0
	var kills := 0
	for k in 40:
		var victim: int = keys[rng.randi() % keys.size()]
		if dead.has(victim) or int(bottom[victim]) == low:
			continue
		var touching: PackedInt32Array = nbrs[victim]
		_w.kill_block(c, StructureReplayer.block_cell(_w, c, victim))
		dead[victim] = true
		kills += 1

		var t0 := Time.get_ticks_usec()
		var g: PackedByteArray = _w.solve_grounded(c)
		t_ground.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		flood_walked.append(int(_w.get_solve_stats(c).blocks_visited))
		t0 = Time.get_ticks_usec()
		_w.solve_stress(c)
		t_stress.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		var flood_falls := false
		for id in bottom:
			if not dead.has(id) and g[id] == 0:
				flood_falls = true
				break

		var r := _local(touching, bottom, nbrs, dead, low)
		walked.append(r[0])
		if r[1]:
			falls += 1
		if r[1] == flood_falls:
			agree += 1
		# What fell is gone for the next kill (as the game would spawn it).
		if flood_falls:
			for id in bottom:
				if not dead.has(id) and g[id] == 0:
					dead[id] = true

	print("    %d kills, %d cut something off" % [kills, falls])
	print("    solve_grounded: median %.2f ms, worst %.2f; walks %d blocks (median)" % [
			_median(t_ground), t_ground.max(), int(_median(flood_walked))])
	print("    solve_stress:   median %.2f ms, worst %.2f" % [_median(t_stress), t_stress.max()])
	print("    local search:   walks median %d blocks, worst %d -- %.1f%% of the flood (median)" % [
			int(_median(walked)), int(walked.max()),
			100.0 * _median(walked) / maxf(1.0, _median(flood_walked))])
	_ok("tower %d courses: the local search and the flood agree on what falls" % courses,
			agree == kills, "%d of %d" % [agree, kills])


## [blocks walked, whether anything fell]: from each block that touched the dead
## one, lowest first, until the ground (it stands) or nothing is left (it falls).
## Blocks found standing are remembered for the rest of this cut.
func _local(touching: PackedInt32Array, bottom: Dictionary, nbrs: Dictionary, dead: Dictionary,
		low: int) -> Array:
	var walked := 0
	var fell := false
	var standing := {}
	for start in touching:
		if dead.has(start) or not bottom.has(start) or standing.has(start):
			continue
		# Best first by height: a tiny binary heap of [y, id].
		var heap: Array = [[int(bottom[start]), start]]
		var seen := {start: true}
		var reached := false
		while not heap.is_empty():
			var top: Array = _pop(heap)
			var id: int = top[1]
			walked += 1
			if int(bottom[id]) == low or standing.has(id):
				reached = true
				break
			for nb in nbrs[id]:
				if seen.has(nb) or dead.has(nb) or not bottom.has(nb):
					continue
				seen[nb] = true
				_push(heap, [int(bottom[nb]), nb])
		if reached:
			for id in seen:
				standing[id] = true
		else:
			fell = true
	return [walked, fell]


static func _push(h: Array, item: Array) -> void:
	h.append(item)
	var i := h.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if h[p][0] <= h[i][0]:
			break
		var t = h[p]
		h[p] = h[i]
		h[i] = t
		i = p


static func _pop(h: Array) -> Array:
	var top: Array = h[0]
	var last: Array = h.pop_back()
	if h.is_empty():
		return top
	h[0] = last
	var i := 0
	while true:
		var l := 2 * i + 1
		var r := l + 1
		var m := i
		if l < h.size() and h[l][0] < h[m][0]:
			m = l
		if r < h.size() and h[r][0] < h[m][0]:
			m = r
		if m == i:
			break
		var t = h[m]
		h[m] = h[i]
		h[i] = t
		i = m
	return top
