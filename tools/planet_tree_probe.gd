extends SceneTree

## The planet's trees (Docs/Planets.md 11.10): PlanetTrees' cells and scatter
## on the default planet, a pad at the spawn.
##
##   --headless --path . --script res://tools/planet_tree_probe.gd
##
## Trees come from the cell, never from storage, so: is a cell the same trees
## every time, does a direction's cell hold it (across a cube corner too), is
## the density the biome table's, are none on a pad, in the sea or on a cliff,
## does every trunk stand on the ground, does the camera's plan reach every cell
## within KEEP, and is a cell quick enough to build a few a frame?

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
		return false   # _go quits when it is through
	_done = true
	_go()
	return false


func _go() -> void:
	await _run()
	print("[trees] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)


func _run() -> void:
	var data := PlanetData.new()
	var spawn := Vector3(0.12, 1.0, -0.08).normalized()
	data.pads.append({"dir": spawn, "height": 4.0, "flat": 95.0, "blend": 70.0})
	var tr := PlanetTrees.new()
	tr.setup(data)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	# A cell is the same trees every time.
	# (A cell with trees in it: the first of a run of random ones.)
	var key := tr.cell_of(Vector3(0.5, 0.7, 0.2).normalized())
	while tr.trees_of(key).size() < 10:
		key = tr.cell_of(Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized())
	var a := tr.trees_of(key)
	var b := tr.trees_of(key)
	var same := a.size() == b.size()
	for i in mini(a.size(), b.size()):
		same = same and (a[i].at as Vector3).is_equal_approx(b[i].at) and a[i].variant == b[i].variant
	_check("a cell is the same trees every time", same, "%d trees" % a.size())
	# A direction's cell holds it, at random and at a cube corner.
	var bad := 0
	for k in 400:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		if k < 40:
			d = (Vector3(1, 1, 1) + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.002).normalized()
		var c := tr.cell_of(d)
		if tr.cell_of(tr.cell_centre(c)) != c:
			bad += 1
	_check("a cell's centre is in that cell (corners too)", bad == 0, "%d of 400 not" % bad)
	# Density by biome: cells whose centre is a forest's or a desert's.
	var tally := {}   # biome -> [trees, hectares, cells]
	var worst_foot := 0.0
	var on_pad := 0
	var in_sea := 0
	var steep := 0
	var worst_us := 0
	var cells := 0
	while cells < 260:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var ck := tr.cell_of(d)
		var bi := tr.biomes.biome_index(tr.cell_centre(ck))
		var t0 := Time.get_ticks_usec()
		var trees := tr.trees_of(ck)
		worst_us = maxi(worst_us, Time.get_ticks_usec() - t0)
		cells += 1
		var row: Array = tally.get(bi, [0, 0.0, 0])
		row[0] += trees.size()
		row[1] += tr.cell_area(ck) / 10000.0
		row[2] += 1
		tally[bi] = row
		for t in trees:
			var at: Vector3 = t.at
			var dd := at.normalized()
			var h := data.height(dd)
			worst_foot = maxf(worst_foot, absf(at.length() - data.radius - h + 0.05))
			if h < data.sea_level + 1.0:
				in_sea += 1
			if tr._slope(dd, h) > PlanetTrees.MAX_SLOPE:
				steep += 1
	# And the spawn's pad: its cells hold nothing.
	var sk := tr.cell_of(spawn)
	var pad_cells := 0
	for di in range(-3, 4):
		for dj in range(-3, 4):
			var ck := Vector3i(sk.x, sk.y + di, sk.z + dj)
			pad_cells += 1
			on_pad += tr.trees_of(ck).filter(func(t) -> bool:
				return ((t.at as Vector3).normalized() * data.radius).distance_to(spawn * data.radius) < 165.0).size()
	var line := []
	var dense_ok := true
	for bi in tally:
		var row: Array = tally[bi]
		var want := float(PlanetTrees.TREES[bi][0])
		var got: float = row[0] / maxf(row[1], 0.001)
		line.append("%s %.0f/ha (table %.0f, %d cells)" % [PlanetBiomes.TABLE[bi].name, got, want, row[2]])
		# Biomes mix inside a cell and cliffs and the sea take trees: within a
		# wide band, judged only on biomes with enough cells to mean anything.
		if row[2] >= 12 and (got < want * 0.4 or got > want * 1.6 + 3.0):
			dense_ok = false
	print("[trees] density: " + "; ".join(line))
	_check("each biome's density near its table's (0.4 .. 1.6 x, a few a hectare from a neighbour at its borders)", dense_ok)
	_check("every trunk's foot on the ground, 5 cm sunk (< 1 cm off)", worst_foot < 0.01, "%.4f m" % worst_foot)
	_check("none at the sea or its beach", in_sea == 0, "%d" % in_sea)
	_check("none on ground steeper than %.0f deg" % PlanetTrees.MAX_SLOPE, steep == 0, "%d" % steep)
	_check("none on a town's pad (its 7 x 7 cells)", on_pad == 0, "%d in %d cells" % [on_pad, pad_cells])
	_check("a cell builds quickly (< 25 ms)", worst_us < 25000, "worst %.1f ms" % (worst_us / 1000.0))
	# The camera's plan reaches every cell within KEEP, at a cube corner too.
	for where in [Vector3(0.3, 0.9, 0.2), Vector3(1, 1, 1)]:
		var cam: Vector3 = (where as Vector3).normalized() * (data.radius + 30.0)
		tr._cells.clear()
		tr._plan(cam)
		var planned := {}
		for k2 in tr._queue:
			planned[k2] = true
		var missed := 0
		for k in 500:
			var off := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
			off -= cam.normalized() * off.dot(cam.normalized())
			var p: Vector3 = (cam.normalized() * data.radius + off.normalized() * rng.randf_range(0.0, PlanetTrees.KEEP - 80.0))
			var c := tr.cell_of(p.normalized())
			if (tr.cell_centre(c) * data.radius).distance_to(cam) <= PlanetTrees.KEEP and not planned.has(c):
				missed += 1
		_check("the camera's plan reaches every cell within KEEP (%s)" % ("a cube corner" if where == Vector3(1, 1, 1) else "mid-face"),
				missed == 0, "%d cells planned, %d missed" % [tr._queue.size(), missed])
	# Snow on the crowns by the ground's own rule (snow under freezing at the
	# height): every tree's bucket is the rule's, and the planet has all three.
	var buckets := [0, 0, 0]
	var wrong := 0
	for k in 400:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		for t in tr.trees_of(tr.cell_of(d)):
			var td: Vector3 = (t.at as Vector3).normalized()
			var hh := data.height(td)
			var cap := smoothstep(1.5, -1.5, PlanetBiomes.temperature_at(tr.biomes.temperature_sea(td), hh))
			var want := 0 if cap < 0.25 else (1 if cap < 0.75 else 2)
			buckets[int(t.snow)] += 1
			if int(t.snow) != want:
				wrong += 1
	print("[trees] snow on the crowns, 400 cells: none %d, a little %d, a full cap %d" % buckets)
	_check("each tree's snow is the ground's rule at its foot", wrong == 0, "%d wrong" % wrong)
	_check("the planet has snowy trees and bare ones", buckets[0] > 0 and buckets[2] > 0, str(buckets))
	tr.free()
	await _stream_cost(data, spawn)


## The streaming's own cost a frame: a camera standing at the spawn while its
## cells fill, then flying low at 500 m/s (Shift) for 3 s.
func _stream_cost(data: PlanetData, spawn: Vector3) -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var tr := PlanetTrees.new()
	root.add_child(tr)
	tr.setup(data)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	var side := spawn.cross(Vector3.FORWARD).normalized()
	cam.global_position = spawn * (data.radius + data.height(spawn) + 2.0)
	var worst_fill := 0
	var frames := 0
	while frames < 600 and (frames < 5 or not tr._queue.is_empty()):
		var t0 := Time.get_ticks_usec()
		tr._process(0.016)
		worst_fill = maxi(worst_fill, Time.get_ticks_usec() - t0)
		frames += 1
		await process_frame
	print("[trees] filled %d cells (%d trees) in %d frames; worst frame %.1f ms" % [
			tr._cells.size(), tr.tree_count, frames, worst_fill / 1000.0])
	# Timings: reported, not judged -- they mean something only on a quiet machine
	# (no editor, no other runs; CLAUDE.md). Aim: under 8 ms filling, 12 ms flying.
	var worst_fly := 0
	var d := spawn
	for k in 180:
		d = d.rotated(side, 500.0 / 60.0 / data.radius)
		cam.global_position = d * (data.radius + data.height(d) + 40.0)
		var t0 := Time.get_ticks_usec()
		tr._process(0.016)
		worst_fly = maxi(worst_fly, Time.get_ticks_usec() - t0)
		await process_frame
	print("[trees] 3 s at 500 m/s, 40 m up: worst frame %.1f ms, %d cells held" % [worst_fly / 1000.0, tr._cells.size()])
	root.free()
