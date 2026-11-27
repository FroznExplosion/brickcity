class_name FarmAuto
extends RefCounted
## The auto farmers' areas (HandoffFarming.md 7.3, Docs/MineFarming.md 24).
##
## An auto farmer tends the plots in ITS FENCED AREA: a flood over walkable
## stud columns from its block -- a step allowed where the next column's top
## is within one brick (STEP plates) up or down with a brick of room over it
## (HEAD plates: a fence's rails, 2 plates apart, do not let it through) --
## stopped by fences, walls and drops, and capped at PLOTS plots each way.
## No fence: every plot it can walk to within the cap.
##
## The flood reads the terrain (BrickTerrain.solid_at, safe from a worker) on
## a WorkerThreadPool job, one farmer at a time; the main thread starts it
## and takes the answer when `is_task_completed` says so -- never a wait on a
## job that may not be done (CLAUDE.md). An area is worked out again when its
## farmer is new, or plots came or went (FarmStore.version), or the ground
## changed (MineFarming._terrain_ver), at most every AGAIN seconds.

const STEP := 3
const HEAD := 4
## The cap: plots (2 studs) each way from the farmer.
const PLOTS := 12
const AGAIN := 1.5

## farmer key -> {cols: {Vector2i plot column: plot top plate}, block, sig}
var areas := {}
var floods := 0
var _job := -1
var _job_key := ""
var _job_sig := ""
var _job_block := Vector3i.ZERO
var _job_out := [{}]
var _again := 0.0


## Called every frame with the farmers to keep areas for ([[block, key], ...],
## the near ones) and the signature of what an area depends on. True when an
## area came in (the caller applies the flags).
func step(delta: float, farmers: Array, sig: String) -> bool:
	_again -= delta
	var got := false
	if _job >= 0:
		if not WorkerThreadPool.is_task_completed(_job):
			return false
		WorkerThreadPool.wait_for_task_completion(_job)   # done: returns at once
		_job = -1
		areas[_job_key] = {"cols": _job_out[0], "block": _job_block, "sig": _job_sig}
		got = true
	# Areas of farmers gone (or out of reach) are forgotten.
	var keys := {}
	for f in farmers:
		keys[str(f[1])] = true
	for k in areas.keys():
		if not keys.has(k):
			areas.erase(k)
	if _again > 0.0:
		return got
	for f in farmers:
		var key := str(f[1])
		var block: Vector3i = f[0]
		var s := "%s|%s" % [sig, block]
		var a: Dictionary = areas.get(key, {})
		if not a.is_empty() and str(a.sig) == s:
			continue
		_again = AGAIN
		_job_key = key
		_job_sig = s
		_job_block = block
		var out := _job_out
		out[0] = {}
		floods += 1
		_job = WorkerThreadPool.add_task(func() -> void:
				out[0] = plot_cols(flood(block)), true, "auto farmer flood")
		break
	return got


func busy() -> bool:
	return _job >= 0


## Every area ready for the farmers given? (Gates wait on it.)
func ready_for(farmers: Array, sig: String) -> bool:
	if _job >= 0:
		return false
	for f in farmers:
		var a: Dictionary = areas.get(str(f[1]), {})
		if a.is_empty() or str(a.sig) != "%s|%s" % [sig, f[0]]:
			return false
	return true


## The top of column (x, z) a walker at plate `h` can step to: the highest
## solid plate within STEP of h with HEAD plates of room over it, or -1.
static func top_from(x: int, z: int, h: int) -> int:
	for yy in range(h + STEP, h - STEP - 1, -1):
		if BrickTerrain.solid_at(x, yy, z) == 0:
			continue
		var room := true
		for k in range(1, HEAD + 1):
			if BrickTerrain.solid_at(x, yy + k, z) != 0:
				room = false
				break
		if room:
			return yy
	return -1


## The stud columns a walk from the farmer at `block` (its 2-stud lattice
## block, bottom plate) reaches within the cap: {Vector2i stud column: top}.
## A worker runs this (no nodes, terrain reads only).
static func flood(block: Vector3i) -> Dictionary:
	var seen := {}
	var q: Array[Vector2i] = []
	for dx in 2:
		for dz in 2:
			var c := Vector2i(block.x * 2 + dx, block.z * 2 + dz)
			var h := top_from(c.x, c.y, block.y - 1)
			if h >= 0:
				seen[c] = h
				q.append(c)
	var box := Rect2i(Vector2i(block.x * 2, block.z * 2) - Vector2i(PLOTS * 2, PLOTS * 2),
			Vector2i(PLOTS * 4 + 2, PLOTS * 4 + 2))
	var head := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		var h: int = seen[c]
		for d in dirs:
			var n: Vector2i = c + d
			if seen.has(n) or not box.has_point(n):
				continue
			var hn := top_from(n.x, n.y, h)
			if hn < 0:
				continue
			seen[n] = hn
			q.append(n)
	return seen


## The flood's stud columns as plot columns (2 x 2 studs): a plot column is
## in when any of its studs is, at that stud's top.
static func plot_cols(studs: Dictionary) -> Dictionary:
	var out := {}
	for c in studs:
		var k := Vector2i(floori(c.x / 2.0), floori(c.y / 2.0))
		if not out.has(k):
			out[k] = []
		(out[k] as Array).append(int(studs[c]))
	return out


## Is plot `b` (its top plate b.y) in this area?
static func has_plot(area: Dictionary, b: Vector3i) -> bool:
	var tops = (area.get("cols", {}) as Dictionary).get(Vector2i(b.x, b.z))
	return tops is Array and (tops as Array).has(b.y)
