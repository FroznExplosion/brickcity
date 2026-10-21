class_name BrickHeap
extends Node3D

## **Bricks that stay where they fall** (Docs/CollapseNext.md 0, item 17).
##
## A crumb -- a brick or a handful that came loose, the ring a blast throws,
## a piece of furniture broken -- fell, stopped on the floor under it and
## shrank away a second and a half after it came loose, so a hole had nothing
## lying under it. Now one that comes to rest is laid here instead: an
## instance in a MultiMesh that never moves again, lying flat on one of its
## faces where it stopped. Nothing is asked of it per tick; it is written once.
##
## Drawn only, like every crumb: nothing stands on it, hides behind it or picks
## it up, and it is this machine's own (it is in no command and no save).
##
## Kept by area and size: a square CELL metres across holds up to CELL_CAP of
## each brick size, the oldest overwritten first, and past `max_bricks` all
## told the heaps added to longest ago go first. A heap is drawn out to
## DRAW_RANGE and not past it.
##
## They pile up: a brick comes down on the bricks already lying under it on the
## same floor, not into them (base_for) -- a height per stud of the street,
## kept as each one is laid and taken.
##
## A brick lying on something that goes -- bricks a blast takes, a section
## breaking off, a piece of wreckage that moves -- is handed back to fall again
## (IslandManager._heap_support_gone); one a piece comes to rest on is gone
## (clear_in).

const CELL := 32.0
const CELL_CAP := 400
const DRAW_RANGE := 140.0
const DEFAULT_MAX := 3000
## How high a pile grows over the floor: three bricks or so. A brick that comes
## down on more than that is taken to have slid off it, to the floor -- a real
## heap spreads at its own slope rather than stacking up a wall.
const PILE_MAX := 1.3
const MAX_MAX := 8000
## The setting, "Bricks Left Lying (Developer)": 0 lays none, as before.
static var max_bricks := DEFAULT_MAX
## A pass that wants to know why a brick lies where it does (--lodbreak's "no
## brick lying in mid-air") sets this: each brick laid keeps what it came down
## on and when (`why`). Nothing pays for it otherwise.
static var track := false

## One brick size in one square: a ring of CELL_CAP slots.
class Heap:
	var key := Vector3i.ZERO
	var cell := Vector2i.ZERO
	var size := Vector3.ZERO
	var mmi: MultiMeshInstance3D
	var xf: Array[Transform3D] = []
	var colour := PackedColorArray()
	var ground := PackedFloat32Array()   ## the floor it came down on, under any pile
	var fixed := PackedByteArray()       ## lies on the ground itself: nothing under it goes
	var used := PackedByteArray()
	var why := PackedStringArray()     ## with `track`: what it came down on, and when
	var filled := 0     ## slots handed out, up to CELL_CAP
	var next := 0       ## once full, the oldest slot: the next to go
	var count := 0      ## bricks lying in it now
	var stamp := 0      ## when a brick was last laid in it (laid order)

var _heaps := {}        ## Vector3i(square x, square z, size id) -> Heap
var _size_ids := {}     ## brick size -> a number for the key
## Stud of the street -> [[top, ground], ...]: how high what lies there reaches,
## and on which floor it lies -- the latest TOPS_KEPT only. A pile's top is what
## came down last; every brick ever laid over a busy spot was a list walked on
## every lay and every removal, 72 us a brick in a barrage.
var _tops := {}
const TOPS_KEPT := 6
var _by_cell := {}      ## Vector2i -> Array of Heap
var _stamp := 0
var mesh_for := Callable()   ## size -> Mesh
var material: Material = null

var count := 0          ## bricks lying now
var laid := 0           ## laid, all told
var overwritten := 0    ## taken by a newer one in a full square
var trimmed := 0        ## taken for `max_bricks`
var handed_back := 0    ## falling again, what they lay on gone
var cleared := 0        ## under a piece that came to rest


static func enabled() -> bool:
	return max_bricks > 0


static func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.z / CELL))


func _heap_for(size: Vector3, cell: Vector2i) -> Heap:
	if not _size_ids.has(size):
		_size_ids[size] = _size_ids.size()
	var key := Vector3i(cell.x, cell.y, int(_size_ids[size]))
	if _heaps.has(key):
		return _heaps[key]
	var h := Heap.new()
	h.key = key
	h.cell = cell
	h.size = size
	h.xf.resize(CELL_CAP)
	h.colour.resize(CELL_CAP)
	h.ground.resize(CELL_CAP)
	h.fixed.resize(CELL_CAP)
	h.used.resize(CELL_CAP)
	if track:
		h.why.resize(CELL_CAP)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh_for.call(size) if mesh_for.is_valid() else BoxMesh.new()
	mm.instance_count = CELL_CAP
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.visibility_range_end = DRAW_RANGE
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(mmi)
	h.mmi = mmi
	_heaps[key] = h
	if not _by_cell.has(cell):
		_by_cell[cell] = []
	(_by_cell[cell] as Array).append(h)
	return h


## The studs of the street a brick of `size` turned by `b_basis` covers at `at`.
static func _footprint(size: Vector3, b_basis: Basis, at: Vector3) -> Array:
	var cs := BrickWorld.get_cell_size()
	var hx := 0.0
	var hz := 0.0
	for k in 3:
		hx += absf(b_basis[k].x) * size[k] * 0.5
		hz += absf(b_basis[k].z) * size[k] * 0.5
	var out := []
	for cx in range(floori((at.x - hx) / cs.x + 0.01), floori((at.x + hx) / cs.x - 0.01) + 1):
		for cz in range(floori((at.z - hz) / cs.z + 0.01), floori((at.z + hz) / cs.z - 0.01) + 1):
			out.append(Vector2i(cx, cz))
	return out


## Where a brick comes to rest over `at`, having come down on the floor at
## `ground`: on the highest brick lying under its middle on that floor, or on
## the floor. Its middle, not all of it: asked over the whole of a long brick,
## one clipping the end of another climbed onto it, and a heap at the foot of
## a wall grew into a stack up the wall (2026-10-15).
func base_for(_size: Vector3, _basis: Basis, at: Vector3, ground: float) -> float:
	var cs := BrickWorld.get_cell_size()
	var best := ground
	for e in _tops.get(Vector2i(floori(at.x / cs.x), floori(at.z / cs.z)), []):
		if absf(float(e[1]) - ground) < 0.1 and float(e[0]) > best:
			best = float(e[0])
	return best if best < ground + PILE_MAX else ground


func _top(h: Heap, slot: int, add: bool) -> void:
	var xf := h.xf[slot]
	var top := xf.origin.y + (absf(xf.basis.x.y) * h.size.x + absf(xf.basis.y.y) * h.size.y
			+ absf(xf.basis.z.y) * h.size.z) * 0.5
	# Under its middle half only: a brick coming down asks under its own middle
	# (base_for), and one landing on the very end of another slides off it.
	# Under all of it, this was 43 us of a 70 us lay in a barrage.
	for c in _footprint(h.size * 0.5, xf.basis, xf.origin):
		if add:
			if not _tops.has(c):
				_tops[c] = []
			var kept: Array = _tops[c]
			kept.append([top, h.ground[slot]])
			if kept.size() > TOPS_KEPT:
				kept.remove_at(0)
			continue
		var list: Array = _tops.get(c, [])
		for i in list.size():
			if is_equal_approx(float(list[i][0]), top) and is_equal_approx(float(list[i][1]), h.ground[slot]):
				list.remove_at(i)
				break
		if list.is_empty():
			_tops.erase(c)


## Lay one brick of `size` (its mesh's own box) at `at`, coloured `colour`,
## come down on the floor at `ground` (what base_for piled it on). `on_ground`:
## that floor is the ground itself (Layers.WORLD), which nothing takes away --
## take_in passes it by.
func lay(size: Vector3, at: Transform3D, colour: Color, ground := NAN,
		on_ground := false, why := "") -> void:
	if not enabled():
		return
	var h := _heap_for(size, _cell_of(at.origin))
	var slot: int
	if h.filled < CELL_CAP:
		slot = h.filled
		h.filled += 1
		h.mmi.multimesh.visible_instance_count = h.filled
	else:
		slot = h.next
		h.next = (h.next + 1) % CELL_CAP
		if h.used[slot]:
			_top(h, slot, false)
			h.count -= 1
			count -= 1
			overwritten += 1
	h.mmi.multimesh.set_instance_transform(slot, at)
	h.mmi.multimesh.set_instance_color(slot, colour)
	h.xf[slot] = at
	h.colour[slot] = colour
	h.ground[slot] = ground if not is_nan(ground) else at.origin.y
	h.fixed[slot] = 1 if on_ground else 0
	h.used[slot] = 1
	if not h.why.is_empty():
		h.why[slot] = "%s, tick %d" % [why, Engine.get_physics_frames()]
	_top(h, slot, true)
	h.count += 1
	count += 1
	laid += 1
	_stamp += 1
	h.stamp = _stamp
	_trim()


func _take(h: Heap, slot: int) -> void:
	_top(h, slot, false)
	h.used[slot] = 0
	h.mmi.multimesh.set_instance_transform(slot, Transform3D(Basis().scaled(Vector3.ZERO),
			h.xf[slot].origin))
	h.count -= 1
	count -= 1


## Past `max_bricks`: the heap laid in longest ago goes, the whole of it, until
## there is room -- the oldest wreckage is the first swept up.
func _trim() -> void:
	while count > max_bricks and not _heaps.is_empty():
		var oldest: Heap = null
		for k in _heaps:
			var h: Heap = _heaps[k]
			if oldest == null or h.stamp < oldest.stamp:
				oldest = h
		trimmed += oldest.count
		count -= oldest.count
		_drop(oldest)


func _drop(h: Heap) -> void:
	for slot in h.filled:
		if h.used[slot]:
			_top(h, slot, false)
	_heaps.erase(h.key)
	var list: Array = _by_cell.get(h.cell, [])
	list.erase(h)
	if list.is_empty():
		_by_cell.erase(h.cell)
	h.mmi.queue_free()


## Every heap a world box touches.
func _heaps_in(box: AABB) -> Array:
	var out := []
	var lo := _cell_of(box.position)
	var hi := _cell_of(box.end)
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			out.append_array(_by_cell.get(Vector2i(cx, cz), []))
	return out


## The bricks lying inside a world box, taken out: [size, transform, colour]
## each, for whoever is going to make them fall. Not those on the ground: what
## went was not under them. (Asked of every brick near anything that moved, the
## street's were handed back 9,114 times in one barrage, to land where they lay.)
func take_in(box: AABB) -> Array:
	var out := []
	if count == 0:
		return out
	for h in _heaps_in(box):
		if h.count == 0:
			continue
		for slot in h.filled:
			if h.used[slot] and not h.fixed[slot] and box.has_point(h.xf[slot].origin):
				out.append([h.size, h.xf[slot], h.colour[slot]])
				_take(h, slot)
	return out


## The bricks lying inside a box that is `local` in the space `xf` turns into
## the world -- a piece's own box, as it lies -- gone: it has come to rest on
## them. How many.
func clear_in(xf: Transform3D, local: AABB) -> int:
	if count == 0:
		return 0
	var world_box := xf * local
	var inv := xf.affine_inverse()
	var n := 0
	for h in _heaps_in(world_box):
		if h.count == 0:
			continue
		for slot in h.filled:
			if h.used[slot] and local.has_point(inv * h.xf[slot].origin):
				_take(h, slot)
				n += 1
	cleared += n
	return n


func census_line() -> String:
	return "bricks lying: %d now in %d heap(s), %d laid all told; %d overwritten in a full square, %d swept for the cap (%d), %d falling again, %d under a piece that came to rest" % [
			count, _heaps.size(), laid, overwritten, trimmed, max_bricks, handed_back, cleared]
