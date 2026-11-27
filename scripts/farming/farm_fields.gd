class_name FarmFields
extends RefCounted
## Fields (Docs/MineFarming.md 9, 23): plots that touch (8 ways, within a
## brick of each other's height). A field of one crop (MONO_PLOTS or more of
## it, MONO_SHARE of what is planted) is MONO: blight may come (FarmPlant).
##
## Stage 5 also flooded the ground from each field to tell whether animals
## could reach it, for farming's own random animal events. Since the mine
## world has real animals (Docs/MineCreatures.md: pigs, zombies, fences that
## stop them) those events are gone (the user, 2026-11-27): whether an animal
## gets in is the animal's walk, not a flood. So no flood, no worker job.
##
## Fields are worked out again when plots come or go (FarmStore.version), at
## most every AGAIN seconds.

const STEP := 3
const MONO_PLOTS := 24
const MONO_SHARE := 0.9
const AGAIN := 1.5

var dirty := true
## [{plots: Array[Vector3i], mono: StringName}]
var fields: Array = []
var _seen_version := -1
var _again := 0.0


## Called every frame. `apply(field)` is called for each field when the
## fields are worked out again (its plots' mono flag to set).
func step(delta: float, store: FarmStore, apply: Callable) -> void:
	if store.version != _seen_version:
		_seen_version = store.version
		dirty = true
	_again -= delta
	if not dirty or _again > 0.0:
		return
	dirty = false
	_again = AGAIN
	regroup(store)
	for f in fields:
		apply.call(f)


func busy() -> bool:
	return dirty


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
		fields.append({"plots": group, "mono": mono})
