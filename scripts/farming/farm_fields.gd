class_name FarmFields
extends RefCounted
## Fields and whether animals can reach them (Docs/MineFarming.md 9, stage 5).
##
## A FIELD is plots that touch (8 ways, within a brick of each other's height).
## It is ENCLOSED when a walk over the ground from its plots cannot get more
## than REACH studs past them: a flood over stud columns, a step allowed
## where the next column's top is within one brick (STEP plates) up or down
## and there is room over it. A wall two bricks high, a drop of two bricks, a
## fence -- anything an animal cannot step over -- stops it. Not enclosed:
## the field is OPEN, and its plots get the animals' visits (FarmPlant).
##
## A field of one crop (MONO_PLOTS or more of it, MONO_SHARE of what is
## planted) is MONO: blight may come (FarmPlant).
##
## The flood reads the terrain (BrickTerrain.solid_at, safe to read from a
## worker) on a WorkerThreadPool job, one field at a time; the main thread
## starts it and takes the answer when `is_task_completed` says so -- never a
## wait (CLAUDE.md). Fields are worked out again when plots come or go, or
## the ground near them changes (`dirty`), at most every AGAIN seconds.

const STEP := 3
const REACH := 24
const MAX_CELLS := 30000
const MONO_PLOTS := 24
const MONO_SHARE := 0.9
const AGAIN := 1.5
## Only fields within this of the eye are looked at.
const NEAR_M := 96.0

var dirty := true
## [{plots: Array[Vector3i], mono: StringName, open: bool, done: bool}]
var fields: Array = []
var floods := 0
var _seen_version := -1
var _again := 0.0
var _todo: Array = []          ## field indices waiting for a flood
var _job := -1
var _job_field := -1
var _job_out := [false]


## Called every frame. `apply(field)` is called for each field whose answer
## is in (its plots' open/mono flags to set).
func step(delta: float, store: FarmStore, eye: Vector3, stud: float, apply: Callable) -> void:
	if store.version != _seen_version:
		_seen_version = store.version
		dirty = true
	_again -= delta
	if _job >= 0:
		if not WorkerThreadPool.is_task_completed(_job):
			return
		WorkerThreadPool.wait_for_task_completion(_job)   # done: returns at once
		_job = -1
		if _job_field >= 0 and _job_field < fields.size():
			var f: Dictionary = fields[_job_field]
			f.open = bool(_job_out[0])
			f.done = true
			apply.call(f)
		_job_field = -1
	if dirty and _again <= 0.0:
		dirty = false
		_again = AGAIN
		regroup(store)
		_todo.clear()
		for i in fields.size():
			var b: Vector3i = fields[i].plots[0]
			var at := Vector2((b.x * 2 + 1) * stud, (b.z * 2 + 1) * stud)
			if at.distance_to(Vector2(eye.x, eye.z)) <= NEAR_M:
				_todo.append(i)
	if _job < 0 and not _todo.is_empty():
		_job_field = _todo.pop_front()
		var f: Dictionary = fields[_job_field]
		var starts: Array = []
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := Vector2i(-(1 << 30), -(1 << 30))
		for b in f.plots:
			for dx in 2:
				for dz in 2:
					var c := Vector2i(b.x * 2 + dx, b.z * 2 + dz)
					starts.append([c.x, c.y, int(b.y)])
					lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
					hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
		var box := Rect2i(lo, hi - lo + Vector2i.ONE)
		var out := _job_out
		floods += 1
		_job = WorkerThreadPool.add_task(func() -> void:
				out[0] = flood_open(starts, box, REACH), true, "farm field flood")


func busy() -> bool:
	return _job >= 0 or not _todo.is_empty() or dirty


## Plots that touch, grouped; each field's one crop if it has one.
func regroup(store: FarmStore) -> void:
	fields.clear()
	var by_col := {}
	for b in store.plots:
		var k := Vector2i(b.x, b.z)
		if not by_col.has(k):
			by_col[k] = []
		by_col[k].append(b)
	var seen := {}
	for b0 in store.plots:
		if seen.has(b0):
			continue
		var group: Array[Vector3i] = []
		var q: Array = [b0]
		seen[b0] = true
		while not q.is_empty():
			var b: Vector3i = q.pop_back()
			group.append(b)
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for n in by_col.get(Vector2i(b.x + dx, b.z + dz), []):
						if not seen.has(n) and absi(int(n.y) - b.y) <= STEP:
							seen[n] = true
							q.append(n)
		var counts := {}
		var planted := 0
		for b in group:
			var c: StringName = store.plots[b].crop
			if c != &"":
				planted += 1
				counts[c] = int(counts.get(c, 0)) + 1
		var mono := &""
		for c in counts:
			if int(counts[c]) >= MONO_PLOTS and float(counts[c]) >= MONO_SHARE * planted:
				mono = c
		fields.append({"plots": group, "mono": mono, "open": false, "done": false})


## The top of column (x, z) an animal standing at plate `h` can step to: the
## highest solid plate within STEP of h with room over it (two plates), or -1.
static func top_from(x: int, z: int, h: int) -> int:
	for yy in range(h + STEP, h - STEP - 1, -1):
		if BrickTerrain.solid_at(x, yy, z) != 0 and BrickTerrain.solid_at(x, yy + 1, z) == 0 \
				and BrickTerrain.solid_at(x, yy + 2, z) == 0:
			return yy
	return -1


## Can a walk from `starts` ([x, z, h] columns) get more than `reach` studs
## past `box`? A worker runs this (no nodes, terrain reads only).
static func flood_open(starts: Array, box: Rect2i, reach: int) -> bool:
	var outer := box.grow(reach)
	var seen := {}
	var q: Array[Vector2i] = []
	for s in starts:
		var k := Vector2i(int(s[0]), int(s[1]))
		seen[k] = int(s[2])
		q.append(k)
	var head := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		if not outer.has_point(c) or seen.size() > MAX_CELLS:
			return true
		var h: int = seen[c]
		for d in dirs:
			var n: Vector2i = c + d
			if seen.has(n):
				continue
			var hn := top_from(n.x, n.y, h)
			if hn < 0:
				continue
			seen[n] = hn
			q.append(n)
	return false
