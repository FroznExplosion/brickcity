extends SceneTree
## Blocks placed into a chunk while its face bake runs on a worker. The worker
## walks the chunk's block list; place_block's push_back can move that list.
## place_block used to wait for the bake only AFTER growing it, and a
## decorative block (furniture: a close-up break of 20-30 rooms lands many)
## never waited at all -- the worker read freed memory and the game died
## (2026-10-24, bake_faces_into). Now every write joins the chunk's workers
## first (BrickWorld::join_chunk_readers). Without the fix this crashes, not
## fails; with it, every round's bake comes back.
##   --headless --path . --script res://tools/bake_race_probe.gd

const FX := 40
const FZ := 30
const COURSES := 34
const ROUNDS := 6

var _fails := 0


func _init() -> void:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(FX, FZ, COURSES, Transform3D())
	reg.storey_units = false  # the whole tower: a big bake, a long window
	var chunk := reg.materialise(id)
	var part := -1
	for k in palette:
		if str(k) == "plate_1x1" and int(palette[k]) >= 0:
			part = int(palette[k])
			break
	_ok("a 1x1 part to place", part >= 0)
	var origin := w.get_chunk_origin(chunk)
	var dims := w.get_chunk_dims(chunk)
	# Every free cell, in a scattered order, as somewhere furniture can go.
	var free: Array[Vector3i] = []
	for y in dims.y:
		for z in dims.z:
			for x in dims.x:
				free.append(origin + Vector3i(x, y, z))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in range(free.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := free[i]
		free[i] = free[j]
		free[j] = t
	var cursor := 0
	var placed_total := 0
	for r in ROUNDS:
		# Something structural goes, so the bake is stale and starts again.
		var n := w.get_block_count(chunk)
		for k in 3:
			w.remove_block(chunk, rng.randi_range(0, n - 1))
		w.bake_chunk_async(chunk)
		# Enough furniture to outgrow the block list's room at least once
		# while that bake is reading it.
		var want := n * 3 / 4 + 64
		var placed := 0
		while placed < want and cursor < free.size():
			if w.place_block(chunk, free[cursor], part, 0, true) >= 0:
				placed += 1
			cursor += 1
		placed_total += placed
		var t0 := Time.get_ticks_msec()
		while not w.bake_ready(chunk) and Time.get_ticks_msec() - t0 < 20000:
			OS.delay_msec(1)
		var ready := w.bake_ready(chunk)
		print("  round %d: %d blocks before, %d decorative placed, bake back: %s" % [
				r, n, placed, ready])
		if not ready:
			_fails += 1
	_ok("furniture placed during every bake", placed_total > 0)
	_ok("every bake came back", _fails == 0)
	print("[bake_race] %s" % ("ok" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


func _ok(what: String, cond: bool) -> void:
	print("  %s %s" % ["ok  " if cond else "FAIL", what])
	if not cond:
		_fails += 1
