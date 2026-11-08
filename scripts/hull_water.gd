class_name HullWater
extends RefCounted
## Water inside a hull, cell by cell (Docs/Hulls.md 5): STA's automaton (Water.md
## 12.1) on the hull's air grid (HullAir) -- a fill per cell, flowing down the
## ship's own down first, then aside (more to the downhill side), then up where a
## cell is over full (the pressure that lifts water up a stairwell or to the outside
## level). The flow is C++ (HullFlow): only cells whose water moved, and what they
## touch, are looked at, so a pool at rest costs nothing.
##
## Where it comes in: each breach cell (HullAir's: an outside cell beside inside
## air) under the outside water. It fills the inside cells beside it, faster the
## deeper the hole, to a fill of 1 plus its head (`depth` in cells): that head is
## what the up-rule spends, so a compartment fills to the outside level and no
## higher. Where it goes out: a breach cell over the outside water lets the
## compartment's water out from its top (it stands level) down to the hole -- a
## hull lifted or rolled out of the water empties.
##
## Trapped air (Docs/Hulls.md 5.2): a room whose every hole is under the water
## cannot let its air out, so the water coming in squeezes it -- Boyle: the pocket
## shrinks to 1 / (1 + depth / 10.3 m) of the room, the deepest hole's depth -- and
## stops there, the pocket held at the top. Air leaks out of a held pocket at
## `air_leak` cells a second (a brick hull's seams; 0 for an airtight one, INF for
## none held at all), so the water creeps on up as it goes.
##
## Water stands only in inside cells and open doors' cells (a shut door holds, a
## bulkhead holds); never in a brick, never out but through a hole. Every fill
## that comes in, goes out or dries off as a film is counted (`came_in`,
## `went_out`, `dried`), so the mass in the grid is checkable.

## Inflow at a hole, cells of water a second per hole cell, at a metre's head
## (it goes as the square root of the depth): sqrt(2g) m/s through a hole cell's
## face (a stud by a plate), in cells of water.
const INFLOW := 11.0
## Out through a hole over the water, cells a second for each inside cell beside it.
const OUTFLOW := 24.0
## How much of the difference flows to a neighbour aside in one pass.
const SIDE := 0.4
## Of a cell's excess over full, the share pushed up a pass.
const UP := 0.5
## Flow passes a step: water levels out across a room in a fraction of a second.
const PASSES := 4
## Metres of water that press as hard as the air: one atmosphere.
const ATM_M := 10.3
## Under this a cell is dry; under STILL a transfer is no move.
const DRY := 0.002
const STILL := 0.0005

var air: HullAir
var flow := HullFlow.new()
var came_in := 0.0
var went_out := 0.0
## Water moved this step (the drawing is built again only then).
var changed := false
## Steps taken: a reader's cache of what the water weighs is good until it moves.
var steps := 0
## Height of a cell, metres (a plate): how a depth becomes a head in cells.
var cell_h := 0.12
var _down := Vector3.DOWN
var _last_lat: Array = []
var _doors_sig := ""
## Set by whoever changes the air's grid (a hit, a repair): what the water may
## stand in is worked out again at the next step.
var grid_changed := false
## Air out of a held pocket through the hull's seams, cells a second (the class notes).
var air_leak := 0.0
## Air leaked out of each room's pocket so far, cells (by its root).
var _leaked := {}
## Rooms holding a pocket at the last step (roots): their air has nowhere to go.
var trapped: Dictionary = {}
## What came in at each hole cell at the last step, cells of water (HullSpray).
var inflow: Dictionary = {}


static func on(hull_air: HullAir) -> HullWater:
	var w := HullWater.new()
	w.air = hull_air
	w.flow.setup(hull_air.dims)
	w.cell_h = BrickWorld.get_plate_metres()
	w._passable_again()
	return w


## Cells water may stand in, from the air's states and the doors open now.
func _passable_again() -> void:
	var open := PackedInt32Array()
	for d: Dictionary in air.doors:
		if bool(d.open) and not bool(d.outside):
			open.append_array(d.cells)
	flow.set_passable(air.state, HullAir.INSIDE, open)


func passable(i: int) -> bool:
	return flow.is_passable(i)


## Every cell with water in it.
var wet: PackedInt32Array:
	get:
		return flow.wet()


## The dried film (see the class notes).
var dried: float:
	get:
		return flow.get_dried()


func total() -> float:
	return flow.total()


## Water in a compartment (its root's cells), cells' worth.
func in_compartment(ci: int) -> float:
	var r := air._root(ci)
	var t := 0.0
	for i in flow.wet():
		if air.state[i] == HullAir.INSIDE and air._root(air.comp[i]) == r:
			t += flow.get(i)
	return t


func any() -> bool:
	return flow.wet_count() > 0


func fill_at(i: int) -> float:
	return flow.get(i)


## A cell's water, capped at full: what is drawn and what weighs.
func level(i: int) -> float:
	return flow.level(i)


## `dt` seconds of water. `down` is the ship's down in the grid's axes (a unit
## vector); `depth_at` gives a hole cell's depth under the outside water, metres
## (below 0: over it; NAN: no water there -- space, dry land).
func step(dt: float, down: Vector3, depth_at: Callable) -> void:
	_down = down
	changed = false
	steps += 1
	# What it may stand in: the air's grid changes with every hit and repair, the
	# doors as they open and shut.
	var sig := ""
	for d: Dictionary in air.doors:
		sig += "1" if bool(d.open) else "0"
	if sig != _doors_sig or grid_changed:
		_doors_sig = sig
		grid_changed = false
		_passable_again()
		flow.wake_all()
	var axis := _axis(down)
	if _tipped(axis[1]):
		flow.wake_all()
	_holes(dt, depth_at)
	var lat := PackedInt32Array()
	var wts := PackedFloat32Array()
	for e: Array in axis[1]:
		lat.append(int(e[0]))
		wts.append(float(e[1]))
	if flow.flow(int(axis[0]), lat, wts, PASSES, SIDE, UP, DRY, STILL):
		changed = true


## The lateral weights moved enough since the last step that a still pool would
## run (the ship rolled or pitched).
func _tipped(lat: Array) -> bool:
	var tip := false
	if _last_lat.size() == lat.size():
		for k in lat.size():
			if int(lat[k][0]) != int(_last_lat[k][0]) or absf(float(lat[k][1]) - float(_last_lat[k][1])) > 0.15:
				tip = true
				break
	if tip or _last_lat.is_empty():
		_last_lat = lat.duplicate(true)
	return tip


## In and out through every breach cell.
func _holes(dt: float, depth_at: Callable) -> void:
	trapped.clear()
	inflow.clear()
	for ci in air._parent.size():
		if air._parent[ci] != ci:
			continue
		var room := pocket_room(ci, depth_at)
		if room >= 0.0:
			var have := in_compartment(ci)
			if have >= room - 0.5:
				# Held: only what leaks out lets more in.
				trapped[ci] = true
				_leaked[ci] = float(_leaked.get(ci, 0.0)) + air_leak * dt
				continue
		var budget := INF if room < 0.0 else room - in_compartment(ci)
		for b: int in air._breach[ci]:
			var d: float = depth_at.call(b)
			if is_nan(d):
				continue
			var nb := PackedInt32Array()
			for j in air._neighbours(b):
				if flow.is_passable(j):
					nb.append(j)
			if nb.is_empty():
				continue
			if d > 0.0:
				# The head: how far over full the water may stand here.
				var cap := 1.0 + d / cell_h
				var q := INFLOW * sqrt(d) * dt / nb.size()
				for j in nb:
					var add := minf(clampf(cap - flow.get(j), 0.0, q), budget)
					if add > 0.0:
						var got := flow.add(j, add)
						came_in += got
						budget -= got
						inflow[b] = float(inflow.get(b, 0.0)) + got
						changed = true
			else:
				# Out: the room's water stands level (it would, long before a cell a
				# tick could carry it to the hole), so what goes is its top -- the
				# highest wet cells of the compartment that stand over the hole.
				_drain_top(ci, _height(b), OUTFLOW * dt * nb.size())


## How much water room `ci` can take before its air is squeezed to the water's
## pressure: -1 if its air can get out (a hole over the water, or no water at one,
## or `air_leak` INF), else its cells times 1 - 1 / (1 + deepest hole / ATM_M),
## plus what has leaked out of it.
func pocket_room(ci: int, depth_at: Callable) -> float:
	if is_inf(air_leak) or air._breach[ci].is_empty():
		return -1.0
	var deepest := 0.0
	for b: int in air._breach[ci]:
		var d: float = depth_at.call(b)
		if is_nan(d) or d <= 0.0:
			return -1.0
		deepest = maxf(deepest, d)
	var cells := float(air._cells[ci])
	return minf(cells, cells * (1.0 - 1.0 / (1.0 + deepest / ATM_M)) + float(_leaked.get(ci, 0.0)))


## How high cell `i` stands along the ship's up, in cells.
func _height(i: int) -> float:
	return -Vector3(air._cell(i)).dot(_down)


## Up to `amount` of compartment `ci`'s water taken from its top, never from
## under `floor_h` (water under a hole stays).
func _drain_top(ci: int, floor_h: float, amount: float) -> void:
	var r := air._root(ci)
	var top: Array = []
	for i in flow.wet():
		if air.state[i] == HullAir.INSIDE and air._root(air.comp[i]) == r:
			var hh := _height(i)
			if hh >= floor_h - 0.5:
				top.append([hh, i])
	top.sort_custom(func(a, b): return a[0] > b[0])
	var left := amount
	for e in top:
		if left <= 0.0:
			break
		var i: int = e[1]
		var t := minf(flow.get(i), left)
		if t <= 0.0:
			continue
		went_out -= flow.add(i, -t)
		left -= t
		changed = true


## Pumped out (a pump, a bucket chain): `cells` of water a second taken from the
## wet cells of compartment `ci`, any if -1. Returns what it took.
func pump(dt: float, cells: float, ci := -1) -> float:
	var want := cells * dt
	var took := 0.0
	var r := air._root(ci) if ci >= 0 else -1
	for i in flow.wet():
		if took >= want:
			break
		if r >= 0 and (air.state[i] != HullAir.INSIDE or air._root(air.comp[i]) != r):
			continue
		took -= flow.add(i, -minf(flow.get(i), want - took))
	went_out += took
	if took > 0.0:
		changed = true
	return took


## The grid step nearest `down`, and the four aside, each with a weight: 1 on
## level ground, more toward the downhill side (kept at most 1).
func _axis(down: Vector3) -> Array:
	var a := absf(down.x)
	var b := absf(down.y)
	var c := absf(down.z)
	var sx := 1
	var sy := air.dims.x
	var sz := air.dims.x * air.dims.y
	var dstep := 0
	var lat: Array = []
	if b >= a and b >= c:
		dstep = -sy if down.y < 0.0 else sy
		lat = [[sx, 1.0 + maxf(down.x, 0.0) * 4.0], [-sx, 1.0 + maxf(-down.x, 0.0) * 4.0],
				[sz, 1.0 + maxf(down.z, 0.0) * 4.0], [-sz, 1.0 + maxf(-down.z, 0.0) * 4.0]]
	elif a >= c:
		dstep = -sx if down.x < 0.0 else sx
		lat = [[sy, 1.0 + maxf(down.y, 0.0) * 4.0], [-sy, 1.0 + maxf(-down.y, 0.0) * 4.0],
				[sz, 1.0 + maxf(down.z, 0.0) * 4.0], [-sz, 1.0 + maxf(-down.z, 0.0) * 4.0]]
	else:
		dstep = -sz if down.z < 0.0 else sz
		lat = [[sx, 1.0 + maxf(down.x, 0.0) * 4.0], [-sx, 1.0 + maxf(-down.x, 0.0) * 4.0],
				[sy, 1.0 + maxf(down.y, 0.0) * 4.0], [-sy, 1.0 + maxf(-down.y, 0.0) * 4.0]]
	var top := 0.0
	for e: Array in lat:
		top = maxf(top, float(e[1]))
	for e: Array in lat:
		e[1] = float(e[1]) / top
	return [dstep, lat]
