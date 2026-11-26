class_name MineWiring
extends Node3D
## WIRING in the mine world (Docs/MineWiring.md 3.3, 4, 10, 13, 14): cable
## tiles, the nets they make, and the devices on them.
##
##   cable   a 1x1 smooth tile, one plate tall, laid on the ground's top (on
##           its studs, as a real tile sits), a cable along it. NOT a terrain
##           material: its own sparse layer (the water's pattern, MineWater.md
##           1), so a net lighting up never rebakes ground. No collider.
##   net     cables that touch: four sides, and up or down a step of up to a
##           brick (3 plates). A net's level is the highest of what drives it
##           (0-15); the whole net changes at once: no fading, no repeaters.
##   device  a node on the stud lattice, 1 stud across, standing on ground
##           (the chests' pattern). It reads or drives the nets of the cables
##           at its sides (a step up or down) and the devices beside it.
##           Devices never join nets.
##
## Devices (DEVICES):
##   lever          RMB turns it; on: 15 to every side.
##   button         RMB: 15 to every side for a second.
##   pressure tile  a plate (1 plate tall): 15 while someone stands on it.
##   trip hook      two facing each other in a line, up to 12 studs apart,
##                  nothing solid between, string between them: both give 15
##                  while someone crosses the string.
##   lamp           lit while anything beside it is above 0.
##   gates          FACE a way (placed facing away from the player; the
##                  wrench turns them): inputs at the back, left and right,
##                  output only at the front. AND (every side with something
##                  at it on), OR, XOR (an odd number on), NOT (the back off),
##                  latch (left sets, right resets), delay (the back, 1-10
##                  ticks later; RMB sets), pulse (the back turning on gives
##                  2/5/10/20 ticks of 15; RMB sets).
##   door           2 studs wide, 14 plates tall, a collider: opens (swings
##                  to its front) while powered from any side, RMB opens or
##                  shuts it by hand (stage 3, section 15).
##   trapdoor       2 x 2 studs, a plate thick, a collider, held by ground
##                  beside or under it: swings down open while powered (a
##                  floor that drops whoever stands on it); RMB too.
##   observer       a brick facing a way: when the ground, a cable or a device
##                  in the column in front of it changes, it gives 15 out of
##                  its BACK for 2 ticks.
##
## The TICK (10 Hz, with the water): sensors, then drivers' outputs, then net
## levels, then lamps, then every gate works out its next output from what it
## reads -- applied the next tick, so each gate takes one tick and a loop of
## gates is a clock, never an endless loop. Idle wiring does no work: it
## ticks only when something changed, or while sensors, gates or timers are
## there.
##
## The WRENCH (item kind "wrench") in the hand: every cable drawn through walls,
## a readout of what is looked at (the whole net's level, its cables and
## devices; a device's inputs and output), RMB turns a facing device, shift +
## RMB takes a device back. Create's goggles and wrench (Docs/MineWiring.md 12).
##
## Broken by LMB, a shot, a blast, or the ground going (`check`). Saved with
## the world's items (`to_save` / `restore`). A child of the mine world with
## no transform: positions are the terrain frame (plate cells).

const TICK := 0.1
const LEVEL_MAX := 15
## How far up or down a cable reaches its neighbour: a brick.
const STEP := 3
## check()'s default box: everything (far from int overflow when grown).
const WHOLE := 1 << 30
## The tallest device (plates): how far down a cell looks for one.
const DEVICE_PLATES := 14
## How long an observer's pulse is (ticks).
const OBSERVER_TICKS := 2
## How long a button stays on, and a sensor after the last touch (ticks).
const BUTTON_TICKS := 10
const SENSOR_HOLD := 5
const TRIP_REACH := 12
const PULSE_LENGTHS := [2, 5, 10, 20]
## What each device is. plates: its height; omni: drives every side; facing:
## has a front; reads: lit by its sides.
const DEVICES := {
	&"lever": {"kind": "switch", "plates": 3, "omni": true},
	&"button": {"kind": "button", "plates": 3, "omni": true},
	&"pressure_tile": {"kind": "pressure", "plates": 1, "omni": true},
	&"trip_hook": {"kind": "trip", "plates": 3, "omni": true, "facing": true},
	&"lamp": {"kind": "lamp", "plates": 3, "reads": true},
	&"and_gate": {"kind": "gate", "op": "and", "plates": 3, "facing": true, "colour": Color(0.23, 0.44, 0.82)},
	&"or_gate": {"kind": "gate", "op": "or", "plates": 3, "facing": true, "colour": Color(0.23, 0.69, 0.42)},
	&"xor_gate": {"kind": "gate", "op": "xor", "plates": 3, "facing": true, "colour": Color(0.61, 0.35, 0.82)},
	&"not_gate": {"kind": "gate", "op": "not", "plates": 3, "facing": true, "colour": Color(0.82, 0.29, 0.23)},
	&"latch": {"kind": "gate", "op": "latch", "plates": 3, "facing": true, "colour": Color(0.82, 0.64, 0.23)},
	&"delay": {"kind": "gate", "op": "delay", "plates": 3, "facing": true, "colour": Color(0.42, 0.45, 0.5)},
	&"pulse": {"kind": "gate", "op": "pulse", "plates": 3, "facing": true, "colour": Color(0.18, 0.72, 0.77)},
	# Stage 3 (section 15). w: studs to the right of the facing; d: studs to
	# the front. A device is a footprint of bottom cells, `plates` tall.
	&"door": {"kind": "door", "plates": 14, "w": 2, "facing": true},
	&"trapdoor": {"kind": "trapdoor", "plates": 1, "w": 2, "d": 2, "facing": true},
	&"observer": {"kind": "observer", "plates": 3, "facing": true},
}
const SIDES: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const SIDE_NAMES := ["+x", "-x", "+z", "-z"]

const COL_TILE := Color(0.24, 0.25, 0.27)
const COL_OFF := Color(0.42, 0.24, 0.13, 0.0)
const COL_ON := Color(1.0, 0.32, 0.12, 1.0)

var host: Node = null
var drops: DroppedItems = null
## Survival: what breaks drops (the host's `survival` wins when it has one).
var survival := false
## Is plate cell (x, y, z) solid ground? BrickTerrain's by default.
var solid_fn: Callable = func(x: int, y: int, z: int) -> int: return BrickTerrain.solid_at(x, y, z)
## The feet of whoever can press a tile or cross a string (terrain frame).
## The host's player by default; a probe gives its own.
var bodies_fn: Callable = func() -> Array: return _host_bodies()

## cell -> true: a cable tile there.
var cables := {}
## bottom cell -> {"item", "on", "facing", "setting", "timer", "out", "lit",
## "prev", "queue", "node"}
var devices := {}
## cable cell -> net id; net id -> {"cells": Array[Vector3i], "level": int}.
var net_of := {}
var nets := {}
var _next_net := 1
## trip hook -> its partner (both ways).
var pairs := {}
## plate cell -> the bottom cell of the device filling it.
var _occupied := {}

var _changed_cells: Array[Vector3i] = []
var _logic_dirty := false
var _draw_dirty := false
var _pairs_dirty := false
var _clock := 0.0
## Ticks run (probes), cells flooded by the last rebuild.
var ticks := 0
var last_flooded := 0

var _stud := 0.35
var _plate := 0.14
var _tiles_mi: MultiMeshInstance3D = null
var _cable_mi: MultiMeshInstance3D = null
var _string_mi: MultiMeshInstance3D = null
## The wrench's view: the cables again, through walls.
var _xray_tiles: MultiMeshInstance3D = null
var _xray_cable: MultiMeshInstance3D = null
var _readout: Label = null


func setup(p_host: Node, p_drops: DroppedItems) -> void:
	host = p_host
	drops = p_drops
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	if _tiles_mi == null:
		_make_draw()


func _ready() -> void:
	if _tiles_mi == null:
		_stud = BrickWorld.get_stud_metres()
		_plate = BrickWorld.get_plate_metres()
		_make_draw()


## The wrench's readout goes on this HUD layer.
func set_hud(layer: CanvasLayer) -> void:
	_readout = Label.new()
	_readout.name = "WiringReadout"
	_readout.add_theme_font_size_override("font_size", 15)
	_readout.add_theme_color_override("font_outline_color", Color.BLACK)
	_readout.add_theme_constant_override("outline_size", 4)
	_readout.anchor_left = 0.5
	_readout.anchor_right = 0.5
	_readout.anchor_top = 0.5
	_readout.anchor_bottom = 0.5
	_readout.offset_left = 24
	_readout.offset_top = 18
	_readout.visible = false
	layer.add_child(_readout)


func _process(delta: float) -> void:
	_clock += delta
	if _clock < TICK:
		return
	_clock = fmod(_clock, TICK)
	tick()


## One tick: nets rebuilt where cables changed, string pairs found again,
## the logic run (when anything can change), drawn.
func tick() -> void:
	ticks += 1
	if not _changed_cells.is_empty():
		_rebuild(_changed_cells)
		_changed_cells.clear()
		_logic_dirty = true
		_draw_dirty = true
	if _pairs_dirty:
		_pairs_dirty = false
		_find_pairs()
		_draw_dirty = true
		_logic_dirty = true
	if _logic_dirty or _live():
		_logic_dirty = false
		_evaluate()
	if _draw_dirty:
		_draw_dirty = false
		_redraw()


## Anything that changes by itself: a sensor, a timer, a gate.
func _live() -> bool:
	for c in devices:
		var d: Dictionary = devices[c]
		var k: String = DEVICES[d.item].kind
		if k == "pressure" or k == "gate" or int(d.timer) > 0 or (k != "switch" and int(d.out) > 0):
			return true
		if k == "trip" and pairs.has(c):
			return true
	return false


static func key_of(c: Vector3i) -> String:
	return "%d,%d,%d" % [c.x, c.y, c.z]


static func is_device(item: StringName) -> bool:
	return DEVICES.has(item)


static func plates_of(item: StringName) -> int:
	return int(DEVICES[item].get("plates", 3)) if DEVICES.has(item) else 3


static func has_facing(item: StringName) -> bool:
	return DEVICES.has(item) and bool(DEVICES[item].get("facing", false))


## The side to a facing's right, seen from above (y up).
static func right_of(f: int) -> int:
	var s := SIDES[f]
	return SIDES.find(Vector3i(-s.z, 0, s.x))


## The facing nearest a horizontal direction (a device faces away from the
## player placing it).
static func facing_of(dir: Vector3) -> int:
	if absf(dir.x) >= absf(dir.z):
		return 0 if dir.x >= 0.0 else 1
	return 2 if dir.z >= 0.0 else 3


func cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / _stud), floori(p.y / _plate), floori(p.z / _stud))


func cable_box(c: Vector3i) -> AABB:
	return AABB(Vector3(c.x * _stud, c.y * _plate, c.z * _stud), Vector3(_stud, _plate, _stud))


## The bottom cells a device stands on: its own cell, then `w` studs to the
## right of its facing and `d` to its front.
static func footprint(c: Vector3i, item: StringName, facing: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var def: Dictionary = DEVICES.get(item, {})
	var f := clampi(facing, 0, 3)
	var right := SIDES[right_of(f)]
	var front := SIDES[f]
	for i in int(def.get("w", 1)):
		for k in int(def.get("d", 1)):
			out.append(c + right * i + front * k)
	return out


## Every plate cell a device fills.
static func cells_of(c: Vector3i, item: StringName, facing: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for b in footprint(c, item, facing):
		for dy in plates_of(item):
			out.append(b + Vector3i(0, dy, 0))
	return out


func device_box(c: Vector3i, item: StringName = &"", facing := -1) -> AABB:
	var it := item
	var f := facing
	if devices.has(c):
		if it == &"":
			it = devices[c].item
		if f < 0:
			f = int(devices[c].facing)
	var box := AABB()
	var first := true
	for b in footprint(c, it, maxi(f, 0)):
		var one := AABB(Vector3(b.x * _stud, b.y * _plate, b.z * _stud), Vector3(_stud, plates_of(it) * _plate, _stud))
		box = one if first else box.merge(one)
		first = false
	return box


func _solid(c: Vector3i) -> bool:
	return int(solid_fn.call(c.x, c.y, c.z)) != 0


## The device whose box holds plate cell `c`, as its bottom cell, or null.
func _device_at(c: Vector3i):
	return _occupied.get(c, null)


## Is a device held where it stands? A trapdoor by ground under it or beside
## it at its plate; any other by ground under every cell of its footprint.
func _supported(c: Vector3i, item: StringName, facing: int) -> bool:
	var fp := footprint(c, item, facing)
	if str(DEVICES.get(item, {}).get("kind", "")) == "trapdoor":
		for b in fp:
			if _solid(b + Vector3i.DOWN):
				return true
			for s in SIDES:
				if not fp.has(b + s) and _solid(b + s):
					return true
		return false
	for b in fp:
		if not _solid(b + Vector3i.DOWN):
			return false
	return true


## The column an observer watches: the stud in front of it, its height.
func _watched(c: Vector3i) -> Array:
	var f := SIDES[int(devices[c].facing)]
	return [c + f, c + f + Vector3i(0, plates_of(devices[c].item) - 1, 0)]


## Something changed in the plate cells lo..hi: the observers watching any of
## them give their pulse.
func _poke(lo: Vector3i, hi: Vector3i) -> void:
	for c in devices:
		if str(DEVICES[devices[c].item].kind) != "observer":
			continue
		var w := _watched(c)
		var a: Vector3i = w[0]
		var b: Vector3i = w[1]
		if a.x >= lo.x and a.x <= hi.x and a.z >= lo.z and a.z <= hi.z and b.y >= lo.y and a.y <= hi.y:
			devices[c].timer = OBSERVER_TICKS
			_logic_dirty = true


func _host_bodies() -> Array:
	if host != null and host.has_method("player_feet_local"):
		var p: Vector3 = host.player_feet_local()
		if p != Vector3.INF:
			return [p]
	return []


# ---------------------------------------------------------------------------
# Placing and breaking

## Would a cable fit at `c`: air, ground under it, nothing there.
func can_place_cable(c: Vector3i) -> bool:
	return not cables.has(c) and _device_at(c) == null and not _solid(c) and _solid(c + Vector3i.DOWN)


func place_cable(c: Vector3i, force := false) -> bool:
	if not force and not can_place_cable(c):
		return false
	cables[c] = true
	_changed_cells.append(c)
	_pairs_dirty = true
	_poke(c, c)
	_changed()
	return true


func can_place_device(c: Vector3i, item: StringName = &"lamp", facing := 0) -> bool:
	if not _supported(c, item, facing):
		return false
	for k in cells_of(c, item, facing):
		if _solid(k) or cables.has(k) or _device_at(k) != null:
			return false
	return true


func place_device(c: Vector3i, item: StringName, on := false, force := false, facing := 0, setting := -1) -> bool:
	if not is_device(item) or (not force and not can_place_device(c, item, facing)):
		return false
	var op := str(DEVICES[item].get("op", ""))
	var st := setting
	if st < 0:
		st = 2 if op == "delay" else (5 if op == "pulse" else 0)
	var f := clampi(facing, 0, 3)
	var node := _device_node(c, item, f)
	add_child(node)
	devices[c] = {"item": item, "on": on, "facing": f, "setting": st, "timer": 0,
			"out": 0, "lit": false, "prev": 0, "queue": [], "node": node}
	for k in cells_of(c, item, f):
		_occupied[k] = c
	_show_device(c)
	_poke_cells(c)
	_logic_dirty = true
	_pairs_dirty = true
	_changed()
	return true


## RMB on a device. `how`: "use" (a lever turns, a button presses, a delay or
## pulse steps its setting) or "turn" (the wrench: a facing device turns a
## quarter to the right). True if it did something.
func use_device(c: Vector3i, how := "use") -> bool:
	if not devices.has(c):
		return false
	var d: Dictionary = devices[c]
	var def: Dictionary = DEVICES[d.item]
	if how == "turn":
		if not bool(def.get("facing", false)) or footprint(c, d.item, 0).size() > 1:
			return false   # a door or trapdoor is taken up and laid again
		d.facing = right_of(int(d.facing))
		_show_device(c)
		_pairs_dirty = true
	else:
		match str(def.kind):
			"switch":
				d.on = not bool(d.on)
			"button":
				d.timer = BUTTON_TICKS
			"door", "trapdoor":
				d.on = not bool(d.on)
			"gate":
				match str(def.get("op", "")):
					"delay":
						d.setting = int(d.setting) % 10 + 1
						d.queue = []
					"pulse":
						var i := PULSE_LENGTHS.find(int(d.setting))
						d.setting = PULSE_LENGTHS[(i + 1) % PULSE_LENGTHS.size()]
					_:
						return false
			_:
				return false
		_show_device(c)
	_logic_dirty = true
	_changed()
	return true


func remove_cable(c: Vector3i, drop := true) -> bool:
	if not cables.has(c):
		return false
	cables.erase(c)
	_changed_cells.append(c)
	_pairs_dirty = true
	_poke(c, c)
	if drop:
		_drop(&"cable", cable_box(c).get_center())
	_changed()
	return true


func remove_device(c: Vector3i, drop := true) -> bool:
	if not devices.has(c):
		return false
	var d: Dictionary = devices[c]
	var box := device_box(c)
	_poke_cells(c)
	for k in cells_of(c, d.item, int(d.facing)):
		_occupied.erase(k)
	devices.erase(c)
	if is_instance_valid(d.node):
		(d.node as Node).queue_free()
	if drop:
		_drop(d.item, box.get_center())
	_logic_dirty = true
	_pairs_dirty = true
	_changed()
	return true


## A device's cells changed (placed, taken): the observers watching them pulse.
func _poke_cells(c: Vector3i) -> void:
	var d: Dictionary = devices[c]
	var box_lo := c
	var box_hi := c
	for k in cells_of(c, d.item, int(d.facing)):
		box_lo = Vector3i(mini(box_lo.x, k.x), mini(box_lo.y, k.y), mini(box_lo.z, k.z))
		box_hi = Vector3i(maxi(box_hi.x, k.x), maxi(box_hi.y, k.y), maxi(box_hi.z, k.z))
	_poke(box_lo, box_hi)


func _drop(item: StringName, at: Vector3) -> void:
	var surv := survival
	if host != null and "survival" in host:
		surv = bool(host.survival)
	if not surv or drops == null:
		return
	drops.spawn(ItemStack.make(item, 1), at, Vector3(randf_range(-0.8, 0.8), 2.5, randf_range(-0.8, 0.8)))


## Does a device stand in `box` (terrain frame)? A block is not put there.
func overlaps(box: AABB) -> bool:
	for c in devices:
		if device_box(c).grow(-0.01).intersects(box):
			return true
	return false


## The nearest device along a ray (terrain frame) within `reach`:
## {cell, dist, point} or {}. A low device (a pressure tile) is aimed at as
## if a little taller, so it can be hit at all.
func ray_device(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
	var best := {}
	for c in devices:
		var box := device_box(c)
		if box.size.y < _plate * 2.0:
			box = box.grow(0.02)
		var hit = box.intersects_ray(from, dir)
		if hit == null:
			continue
		var d := from.distance_to(hit)
		if d <= reach and (best.is_empty() or d < best.dist):
			best = {"cell": c, "dist": d, "point": hit}
	return best


## A bullet reached `p` (terrain frame): a device or cable there breaks. A
## shot cuts a wire (Docs/MineWiring.md 3.1). True if something broke.
func shot(p: Vector3) -> bool:
	for c in devices:
		if device_box(c).grow(0.06).has_point(p):
			remove_device(c)
			return true
	# A cable has no collider: the bullet hits the ground under it, at the
	# cable's bottom face.
	for k in [cell_of(p), cell_of(p + Vector3(0, _plate * 0.4, 0))]:
		if cables.has(k) and cable_box(k).grow(0.04).has_point(p):
			remove_cable(k)
			return true
	return false


## A blast at `c` (terrain frame): everything within `radius` goes.
func blast(c: Vector3, radius: float) -> int:
	var n := 0
	for k in devices.keys():
		if device_box(k).get_center().distance_to(c) <= radius + 0.2:
			remove_device(k)
			n += 1
	var r2 := (radius + 0.2) * (radius + 0.2)
	for k in cables.keys():
		if cable_box(k).get_center().distance_squared_to(c) <= r2:
			remove_cable(k)
			n += 1
	return n


## The ground changed (inside `lo`..`hi`, plate cells, when given): a cable
## or device whose cell filled, or with nothing under it, breaks. A trip
## string whose line filled loses its pair (found again next tick).
func check(lo := Vector3i(-WHOLE, -WHOLE, -WHOLE), hi := Vector3i(WHOLE, WHOLE, WHOLE)) -> int:
	var lo2 := lo - Vector3i(1, DEVICE_PLATES + 1, 1)
	var hi2 := hi + Vector3i(1, 1, 1)
	var gone := 0
	for c in cables.keys():
		if _inside(c, lo2, hi2) and (_solid(c) or not _solid(c + Vector3i.DOWN)):
			remove_cable(c)
			gone += 1
	for c in devices.keys():
		if not _inside(c, lo2, hi2):
			continue
		var d: Dictionary = devices[c]
		var bad := not _supported(c, d.item, int(d.facing))
		for k in cells_of(c, d.item, int(d.facing)):
			bad = bad or _solid(k)
		if bad:
			remove_device(c)
			gone += 1
	_pairs_dirty = true
	# The ground changed in the box: observers watching it pulse (not for a
	# whole check, which is not a change).
	if lo.x != -WHOLE:
		_poke(lo, hi)
	return gone


static func _inside(c: Vector3i, lo: Vector3i, hi: Vector3i) -> bool:
	return c.x >= lo.x and c.y >= lo.y and c.z >= lo.z and c.x <= hi.x and c.y <= hi.y and c.z <= hi.z


func clear() -> void:
	for c in devices:
		if is_instance_valid(devices[c].node):
			(devices[c].node as Node).queue_free()
	devices.clear()
	_occupied.clear()
	cables.clear()
	net_of.clear()
	nets.clear()
	pairs.clear()
	_changed_cells.clear()
	_draw_dirty = true
	_logic_dirty = true


func _changed() -> void:
	if host != null and host.has_method("world_items_changed"):
		host.world_items_changed()


# ---------------------------------------------------------------------------
# Nets

## The cables `c` joins: four sides, up to a brick up or down.
func links(c: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for s in SIDES:
		for dy in range(-STEP, STEP + 1):
			var n := c + s + Vector3i(0, dy, 0)
			if cables.has(n):
				out.append(n)
	return out


## Only the nets the changed cells touched are flooded again.
func _rebuild(changed: Array[Vector3i]) -> void:
	var seeds := {}
	for c in changed:
		seeds[c] = true
		for n in links(c):
			seeds[n] = true
	var redo := {}
	for s in seeds:
		if net_of.has(s):
			var id: int = net_of[s]
			if nets.has(id):
				for c in nets[id].cells:
					redo[c] = true
				nets.erase(id)
		if cables.has(s):
			redo[s] = true
	for c in redo:
		net_of.erase(c)
	last_flooded = 0
	for c in redo:
		if not cables.has(c) or net_of.has(c):
			continue
		var id := _next_net
		_next_net += 1
		var cells: Array[Vector3i] = [c]
		net_of[c] = id
		var i := 0
		while i < cells.size():
			for n in links(cells[i]):
				if not net_of.has(n):
					net_of[n] = id
					cells.append(n)
			i += 1
		nets[id] = {"cells": cells, "level": 0}
		last_flooded += cells.size()


## The nets at one side of a device: cables there, a step up or down.
func side_nets(c: Vector3i, s: Vector3i) -> Array:
	var out := []
	for dy in range(-STEP, STEP + 1):
		var n := c + s + Vector3i(0, dy, 0)
		if net_of.has(n) and not out.has(net_of[n]):
			out.append(net_of[n])
	return out


## Every net at the sides of a device.
func device_nets(c: Vector3i) -> Array:
	var out := []
	for s in SIDES:
		for id in side_nets(c, s):
			if not out.has(id):
				out.append(id)
	return out


## The devices at one side of a device (their heights overlap).
func side_devices(c: Vector3i, s: Vector3i) -> Array:
	var out := []
	var h := plates_of(devices[c].item) if devices.has(c) else DEVICE_PLATES
	for dy in range(-(DEVICE_PLATES - 1), h):
		var n := c + s + Vector3i(0, dy, 0)
		if devices.has(n) and n.y + plates_of(devices[n].item) > c.y:
			out.append(n)
	return out


## What device `n` gives toward direction `dir` (from it): a facing device
## only out of its front, the rest every way. A trip hook drives every way.
func output_toward(n: Vector3i, dir: Vector3i) -> int:
	var d: Dictionary = devices[n]
	var def: Dictionary = DEVICES[d.item]
	if str(def.kind) == "gate":
		return int(d.out) if SIDES[int(d.facing)] == dir else 0
	if str(def.kind) == "observer":
		return int(d.out) if -SIDES[int(d.facing)] == dir else 0
	return int(d.out) if bool(def.get("omni", false)) else 0


## The level reaching device `c` at its side `s`, and whether anything is
## there at all (a cable or a device).
func side_input(c: Vector3i, s: Vector3i) -> Array:
	var lvl := 0
	var present := false
	for id in side_nets(c, s):
		present = true
		lvl = maxi(lvl, int(nets[id].level))
	for n in side_devices(c, s):
		present = true
		lvl = maxi(lvl, output_toward(n, -s))
	return [lvl, present]


## The sides a device drives: a gate its front, the omni ones all four.
func _drive_sides(c: Vector3i) -> Array[Vector3i]:
	var d: Dictionary = devices[c]
	if str(DEVICES[d.item].kind) == "gate":
		return [SIDES[int(d.facing)]]
	if str(DEVICES[d.item].kind) == "observer":
		return [-SIDES[int(d.facing)]]
	if bool(DEVICES[d.item].get("omni", false)):
		return SIDES
	return []


func _evaluate() -> void:
	# 1. Sensors and timers.
	var bodies: Array = bodies_fn.call() if bodies_fn.is_valid() else []
	for c in devices:
		var d: Dictionary = devices[c]
		match str(DEVICES[d.item].kind):
			"switch":
				d.out = LEVEL_MAX if bool(d.on) else 0
			"button":
				d.out = LEVEL_MAX if int(d.timer) > 0 else 0
				d.timer = maxi(int(d.timer) - 1, 0)
			"pressure":
				if _pressed(c, bodies):
					d.timer = SENSOR_HOLD
				d.out = LEVEL_MAX if int(d.timer) > 0 else 0
				d.timer = maxi(int(d.timer) - 1, 0)
			"trip":
				if pairs.has(c) and _crossed(c, pairs[c], bodies):
					d.timer = SENSOR_HOLD
				d.out = LEVEL_MAX if int(d.timer) > 0 else 0
				d.timer = maxi(int(d.timer) - 1, 0)
			"observer":
				d.out = LEVEL_MAX if int(d.timer) > 0 else 0
				d.timer = maxi(int(d.timer) - 1, 0)
	# A string crossed powers both its hooks.
	for c in pairs:
		if devices.has(c) and devices.has(pairs[c]):
			var o := maxi(int(devices[c].out), int(devices[pairs[c]].out))
			devices[c].out = o
	# 2. Net levels from every driver's output (gates' from the last tick).
	var old := {}
	for id in nets:
		old[id] = int(nets[id].level)
		nets[id].level = 0
	for c in devices:
		var out := int(devices[c].out)
		if out <= 0:
			continue
		for s in _drive_sides(c):
			for id in side_nets(c, s):
				nets[id].level = maxi(int(nets[id].level), out)
	for id in nets:
		if int(nets[id].level) != int(old.get(id, -1)):
			_draw_dirty = true
	# 3. Lamps.
	for c in devices:
		var d: Dictionary = devices[c]
		if not bool(DEVICES[d.item].get("reads", false)):
			continue
		var lvl := 0
		for s in SIDES:
			lvl = maxi(lvl, int(side_input(c, s)[0]))
		var lit := lvl > 0
		if lit != bool(d.lit):
			d.lit = lit
			_show_device(c)
	# 3b. Doors and trapdoors: power turning on opens them, turning off shuts
	# them; RMB in between opens or shuts by hand (Minecraft's iron door is
	# power only, its wooden one hand only: here both).
	for c in devices:
		var d: Dictionary = devices[c]
		var k := str(DEVICES[d.item].kind)
		if k != "door" and k != "trapdoor":
			continue
		var p := power_in(c) > 0
		if p != (int(d.prev) > 0):
			d.prev = 1 if p else 0
			if bool(d.on) != p:
				d.on = p
				_show_device(c)
	# 4. Gates: the next output from what they read now, applied together.
	var nexts := {}
	for c in devices:
		var d: Dictionary = devices[c]
		if str(DEVICES[d.item].kind) == "gate":
			nexts[c] = _gate_next(c, d)
	var changed := false
	for c in nexts:
		if int(nexts[c]) != int(devices[c].out):
			devices[c].out = nexts[c]
			_show_device(c)
			changed = true
	for c in devices:
		var k := str(DEVICES[devices[c].item].kind)
		if k == "button" or k == "pressure" or k == "trip" or k == "observer":
			_show_device(c)
	if changed:
		_logic_dirty = true


func _gate_next(c: Vector3i, d: Dictionary) -> int:
	var f := int(d.facing)
	var back := -SIDES[f]
	var right := SIDES[right_of(f)]
	var left := -right
	var b: Array = side_input(c, back)
	var l: Array = side_input(c, left)
	var r: Array = side_input(c, right)
	var on := []
	var present := 0
	for x in [b, l, r]:
		if bool(x[1]):
			present += 1
			on.append(int(x[0]) > 0)
	var n_on := on.count(true)
	match str(DEVICES[d.item].op):
		"and":
			return LEVEL_MAX if present > 0 and n_on == present else 0
		"or":
			return LEVEL_MAX if n_on > 0 else 0
		"xor":
			return LEVEL_MAX if n_on % 2 == 1 else 0
		"not":
			return 0 if int(b[0]) > 0 else LEVEL_MAX
		"latch":
			if int(r[0]) > 0:
				d.on = false
			elif int(l[0]) > 0:
				d.on = true
			return LEVEL_MAX if bool(d.on) else 0
		"delay":
			var q: Array = d.queue
			q.append(int(b[0]) > 0)
			var out := int(d.out)
			while q.size() > int(d.setting):
				out = LEVEL_MAX if bool(q.pop_front()) else 0
			return out
		"pulse":
			var now := int(b[0]) > 0
			if now and int(d.prev) == 0:
				d.timer = int(d.setting)
			d.prev = 1 if now else 0
			var out := LEVEL_MAX if int(d.timer) > 0 else 0
			d.timer = maxi(int(d.timer) - 1, 0)
			return out
	return 0


## The highest level reaching any side of a device's footprint (a door's
## two studs, a trapdoor's four).
func power_in(c: Vector3i) -> int:
	var d: Dictionary = devices[c]
	var fp := footprint(c, d.item, int(d.facing))
	var lvl := 0
	for b in fp:
		for s in SIDES:
			if not fp.has(b + s):
				lvl = maxi(lvl, int(side_input(b, s)[0]))
	return lvl


func is_open(c: Vector3i) -> bool:
	return devices.has(c) and bool(devices[c].on) and str(DEVICES[devices[c].item].kind) in ["door", "trapdoor"]


## Is someone standing on a pressure tile?
func _pressed(c: Vector3i, bodies: Array) -> bool:
	var box := device_box(c)
	var top := box.end.y
	for p in bodies:
		var q: Vector3 = p
		if q.x >= box.position.x - 0.1 and q.x <= box.end.x + 0.1 and q.z >= box.position.z - 0.1 \
				and q.z <= box.end.z + 0.1 and q.y >= top - 0.25 and q.y <= top + 0.5:
			return true
	return false


## The string between two hooks: its ends (terrain frame).
func string_ends(a: Vector3i, b: Vector3i) -> Array:
	var h := _plate * 2.2
	var pa := Vector3((a.x + 0.5) * _stud, a.y * _plate + h, (a.z + 0.5) * _stud)
	var pb := Vector3((b.x + 0.5) * _stud, b.y * _plate + h, (b.z + 0.5) * _stud)
	return [pa, pb]


## Does someone stand across the string (its line within 0.22 m of their
## middle, at a height their body covers)?
func _crossed(a: Vector3i, b: Vector3i, bodies: Array) -> bool:
	var e := string_ends(a, b)
	var pa: Vector3 = e[0]
	var pb: Vector3 = e[1]
	for p in bodies:
		var q: Vector3 = p
		if pa.y < q.y - 0.05 or pa.y > q.y + 1.8:
			continue
		var ab := Vector2(pb.x - pa.x, pb.z - pa.z)
		var aq := Vector2(q.x - pa.x, q.z - pa.z)
		var t := clampf(aq.dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		if (aq - ab * t).length() <= 0.22:
			return true
	return false


## Trip hooks pair: a hook facing a way, the first hook in front of it within
## TRIP_REACH studs, at its height, facing back at it, with nothing between
## (no ground at the string's plates, no cable, no device).
func _find_pairs() -> void:
	pairs.clear()
	for c in devices:
		if devices[c].item != &"trip_hook" or pairs.has(c):
			continue
		var f := int(devices[c].facing)
		var s := SIDES[f]
		for k in range(1, TRIP_REACH + 1):
			var n: Vector3i = c + s * k
			if devices.has(n):
				if devices[n].item == &"trip_hook" and SIDES[int(devices[n].facing)] == -s and not pairs.has(n):
					pairs[c] = n
					pairs[n] = c
				break
			if _solid(n + Vector3i(0, 2, 0)) or _solid(n + Vector3i(0, 1, 0)) or _device_at(n + Vector3i(0, 2, 0)) != null:
				break


## The level at a cable (0 if none), a lamp's state (probes, the readout).
func level_at(c: Vector3i) -> int:
	return int(nets[net_of[c]].level) if net_of.has(c) and nets.has(net_of[c]) else 0


func is_lit(c: Vector3i) -> bool:
	return devices.has(c) and bool(devices[c].lit)


func output_of(c: Vector3i) -> int:
	return int(devices[c].out) if devices.has(c) else 0


# ---------------------------------------------------------------------------
# The wrench

## What the wrench shows for a builder target (a cable or a device), or "".
func readout(target: Dictionary) -> String:
	if target.has("device") and devices.has(target.device):
		var c: Vector3i = target.device
		var d: Dictionary = devices[c]
		var nm := str(ItemCatalog.get_def(d.item).get("name", String(d.item)))
		var parts: Array[String] = ["%s -- output %d" % [nm, int(d.out)]]
		var def: Dictionary = DEVICES[d.item]
		if bool(def.get("facing", false)):
			var f := int(d.facing)
			parts.append("faces %s" % SIDE_NAMES[f])
			if str(def.kind) == "gate":
				var back := -SIDES[f]
				var right := SIDES[right_of(f)]
				parts.append("in: back %d, left %d, right %d" % [int(side_input(c, back)[0]),
						int(side_input(c, -right)[0]), int(side_input(c, right)[0])])
		match str(def.get("op", "")):
			"delay":
				parts.append("delay %d ticks (RMB)" % int(d.setting))
			"pulse":
				parts.append("pulse %d ticks (RMB)" % int(d.setting))
		if str(def.kind) == "trip":
			parts.append("string to %s" % key_of(pairs[c]) if pairs.has(c) else "no string")
		if str(def.kind) == "lamp":
			parts.append("lit" if bool(d.lit) else "dark")
		if str(def.kind) in ["door", "trapdoor"]:
			parts.append("open" if bool(d.on) else "shut")
			parts.append("power %d" % power_in(c))
		if str(def.kind) == "observer":
			parts.append("watches %s" % key_of(_watched(c)[0]))
		return " | ".join(parts)
	if target.has("cable") and net_of.has(target.cable):
		var id: int = net_of[target.cable]
		var n_dev := 0
		for c in devices:
			if device_nets(c).has(id):
				n_dev += 1
		return "Cable net -- level %d | %d cables | %d devices on it" % [int(nets[id].level),
				nets[id].cells.size(), n_dev]
	return ""


## The builder tells the wiring each frame whether the wrench is in the hand
## and what is looked at: the x-ray cables and the readout follow.
func show_wrench(on: bool, target: Dictionary) -> void:
	if _xray_tiles != null:
		_xray_tiles.visible = on
		_xray_cable.visible = on
	if _readout != null:
		var t := readout(target) if on else ""
		_readout.text = t
		_readout.visible = t != ""


# ---------------------------------------------------------------------------
# Drawing

const _SHADER := """
shader_type spatial;
varying vec4 tint;
void vertex() { tint = COLOR; }
void fragment() {
	ALBEDO = tint.rgb;
	ROUGHNESS = 0.45;
	EMISSION = tint.rgb * tint.a * 1.6;
}
"""

const _XRAY_SHADER := """
shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled, blend_mix;
varying vec4 tint;
void vertex() { tint = COLOR; }
void fragment() {
	ALBEDO = mix(tint.rgb, vec3(1.0, 0.45, 0.2), tint.a);
	ALPHA = 0.55;
}
"""


func _make_draw() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = _SHADER
	_tiles_mi = _multi("CableTiles", _box_mesh(Vector3(0.94, 0.86, 0.94)), mat)
	_cable_mi = _multi("Cables", _box_mesh(Vector3(1, 1, 1)), mat)
	_string_mi = _multi("TripStrings", _box_mesh(Vector3(1, 1, 1)), mat)
	var xmat := ShaderMaterial.new()
	xmat.shader = Shader.new()
	xmat.shader.code = _XRAY_SHADER
	_xray_tiles = _multi("XrayTiles", null, xmat, _tiles_mi.multimesh)
	_xray_cable = _multi("XrayCables", null, xmat, _cable_mi.multimesh)
	_xray_tiles.visible = false
	_xray_cable.visible = false


func _multi(n: String, mesh: Mesh, mat: Material, share: MultiMesh = null) -> MultiMeshInstance3D:
	var mm := share
	if mm == null:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.name = n
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


static func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## Every cable tile and its cable, and the trip strings, from the CPU's own
## records (no renderer read-back). Rebuilt whole when anything changed.
func _redraw() -> void:
	if _tiles_mi == null:
		return
	var tiles := _tiles_mi.multimesh
	var arms := _cable_mi.multimesh
	var tile_h := _plate * 0.86
	var cab_h := _plate * 0.22
	var cab_w := _stud * 0.26
	var parts: Array = []   # [Transform3D, Color]
	tiles.instance_count = cables.size()
	var i := 0
	for c in cables:
		var base := Vector3((c.x + 0.5) * _stud, c.y * _plate, (c.z + 0.5) * _stud)
		tiles.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(_stud, _plate, _stud)),
				base + Vector3(0, tile_h * 0.5, 0)))
		tiles.set_instance_color(i, COL_TILE)
		i += 1
		var col := COL_ON if level_at(c) > 0 else COL_OFF
		var top := base.y + tile_h + cab_h * 0.5
		parts.append([Transform3D(Basis.from_scale(Vector3(cab_w, cab_h, cab_w)), Vector3(base.x, top, base.z)), col])
		for s in SIDES:
			var linked := false
			for dy in range(-STEP, STEP + 1):
				if cables.has(c + s + Vector3i(0, dy, 0)):
					linked = true
			if not linked:
				continue
			var half := _stud * 0.5
			var len_x := half if s.x != 0 else cab_w
			var len_z := half if s.z != 0 else cab_w
			var mid := Vector3(base.x + s.x * half * 0.5, top, base.z + s.z * half * 0.5)
			parts.append([Transform3D(Basis.from_scale(Vector3(len_x, cab_h, len_z)), mid), col])
	arms.instance_count = parts.size()
	for k in parts.size():
		arms.set_instance_transform(k, parts[k][0])
		arms.set_instance_color(k, parts[k][1])
	# Strings: one per pair.
	var strings: Array = []
	for a in pairs:
		var b: Vector3i = pairs[a]
		if key_of(a) > key_of(b) or not devices.has(a):
			continue
		var e := string_ends(a, b)
		var pa: Vector3 = e[0]
		var pb: Vector3 = e[1]
		var slen := pa.distance_to(pb)
		var along := (pb - pa) / maxf(slen, 0.001)
		var sx := slen if absf(along.x) > 0.5 else 0.02
		var sz := slen if absf(along.z) > 0.5 else 0.02
		var on := int(devices[a].out) > 0
		strings.append([Transform3D(Basis.from_scale(Vector3(sx, 0.02, sz)), (pa + pb) * 0.5),
				Color(0.95, 0.25, 0.2, 0.6) if on else Color(0.85, 0.82, 0.75, 0.0)])
	var sm := _string_mi.multimesh
	sm.instance_count = strings.size()
	for k in strings.size():
		sm.set_instance_transform(k, strings[k][0])
		sm.set_instance_color(k, strings[k][1])


func _device_node(c: Vector3i, item: StringName, facing := 0) -> Node3D:
	var box := device_box(c, item, facing)
	var root := Node3D.new()
	root.name = "%s_%s" % [String(item).capitalize().replace(" ", ""), key_of(c).replace(",", "_").replace("-", "m")]
	root.position = Vector3(box.get_center().x, box.position.y, box.get_center().z)
	var stone := _mat(Color(0.5, 0.5, 0.52), 0.6)
	var def: Dictionary = DEVICES[item]
	match str(def.kind):
		"switch":
			_add_box(root, Vector3(_stud * 0.92, _plate, _stud * 0.92), Vector3(0, _plate * 0.5, 0), stone)
			var pivot := Node3D.new()
			pivot.name = "Arm"
			pivot.position = Vector3(0, _plate, 0)
			root.add_child(pivot)
			_add_box(pivot, Vector3(_stud * 0.16, _plate * 2.1, _stud * 0.16), Vector3(0, _plate * 1.05, 0),
					_mat(Color(0.45, 0.3, 0.16), 0.7))
			_add_box(pivot, Vector3(_stud * 0.3, _stud * 0.3, _stud * 0.3), Vector3(0, _plate * 2.1, 0),
					_mat(Color(0.75, 0.1, 0.08), 0.4))
		"button":
			_add_box(root, Vector3(_stud * 0.92, _plate * 1.4, _stud * 0.92), Vector3(0, _plate * 0.7, 0), stone)
			var btn := _add_box(root, Vector3(_stud * 0.5, _plate * 0.5, _stud * 0.5), Vector3(0, _plate * 1.65, 0),
					_mat(Color(0.8, 0.12, 0.1), 0.35))
			btn.name = "Push"
		"pressure":
			var plate := _add_box(root, Vector3(_stud * 0.9, _plate * 0.7, _stud * 0.9), Vector3(0, _plate * 0.35, 0),
					_mat(Color(0.62, 0.6, 0.55), 0.55))
			plate.name = "Plate"
		"trip":
			_add_box(root, Vector3(_stud * 0.5, _plate * 0.5, _stud * 0.5), Vector3(0, _plate * 0.25, 0), stone)
			_add_box(root, Vector3(_stud * 0.14, _plate * 2.4, _stud * 0.14), Vector3(0, _plate * 1.5, 0),
					_mat(Color(0.45, 0.3, 0.16), 0.7))
			_add_box(root, Vector3(_stud * 0.3, _stud * 0.1, _stud * 0.1), Vector3(_stud * 0.12, _plate * 2.2, 0),
					_mat(Color(0.7, 0.7, 0.72), 0.3))
		"lamp":
			var body := StaticBody3D.new()
			body.collision_layer = Layers.WORLD
			body.collision_mask = 0
			var shape := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = box.size
			shape.shape = bs
			shape.position = Vector3(0, box.size.y * 0.5, 0)
			body.add_child(shape)
			root.add_child(body)
			var glass := _mat(Color(0.95, 0.85, 0.55), 0.2)
			glass.emission_enabled = true
			glass.emission = Color(1.0, 0.8, 0.45)
			glass.emission_energy_multiplier = 0.0
			var mi := _add_box(root, box.size * Vector3(0.96, 0.98, 0.96), Vector3(0, box.size.y * 0.49, 0), glass)
			mi.name = "Glass"
			var stud := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = _stud * 0.3
			cyl.bottom_radius = _stud * 0.3
			cyl.height = _plate * 0.6
			stud.mesh = cyl
			stud.material_override = glass
			stud.position = Vector3(0, box.size.y + _plate * 0.3, 0)
			root.add_child(stud)
			var light := OmniLight3D.new()
			light.name = "Light"
			light.light_color = Color(1.0, 0.82, 0.55)
			light.omni_range = 4.5
			light.light_energy = 1.4
			light.shadow_enabled = false
			light.position = Vector3(0, box.size.y * 0.6, 0)
			light.visible = false
			root.add_child(light)
		"door", "trapdoor":
			# Built with +x the front and +z the right, turned to the facing.
			# The panel and its collider hang from a hinge: a door's at its
			# left edge (swings to the front), a trapdoor's at its back edge
			# (swings down).
			var turn := Node3D.new()
			turn.name = "Turn"
			turn.rotation.y = _yaw(facing)
			root.add_child(turn)
			var hinge := Node3D.new()
			hinge.name = "Hinge"
			turn.add_child(hinge)
			var size: Vector3
			var mid: Vector3
			if str(def.kind) == "door":
				hinge.position = Vector3(0, 0, -_stud)
				size = Vector3(_stud * 0.3, plates_of(item) * _plate, _stud * 2.0)
				mid = Vector3(0, size.y * 0.5, _stud)
			else:
				hinge.position = Vector3(-_stud, 0, 0)
				size = Vector3(_stud * 2.0, _plate, _stud * 2.0)
				mid = Vector3(_stud, _plate * 0.5, 0)
			var wood := _mat(Color(0.55, 0.37, 0.2), 0.7)
			_add_box(hinge, size * Vector3(1, 1, 0.98), mid, wood)
			if str(def.kind) == "door":
				# A window and a handle.
				_add_box(hinge, Vector3(size.x * 1.05, _plate * 3.0, _stud * 0.8), mid + Vector3(0, _plate * 3.0, 0),
						_mat(Color(0.75, 0.88, 0.95), 0.1))
				_add_box(hinge, Vector3(size.x * 1.6, _plate * 0.5, _stud * 0.12), mid + Vector3(0, -_plate * 0.5, _stud * 0.7),
						_mat(Color(0.8, 0.75, 0.4), 0.3))
			else:
				for z in [-0.5, 0.5]:
					_add_box(hinge, Vector3(_stud * 1.9, _plate * 1.08, _stud * 0.12), mid + Vector3(0, 0, z * _stud),
							_mat(Color(0.4, 0.27, 0.15), 0.7))
			var body := StaticBody3D.new()
			body.collision_layer = Layers.WORLD
			body.collision_mask = 0
			var shape := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = size
			shape.shape = bs
			shape.position = mid
			body.add_child(shape)
			hinge.add_child(body)
		"observer":
			var turn := Node3D.new()
			turn.name = "Turn"
			turn.rotation.y = _yaw(facing)
			root.add_child(turn)
			_add_box(turn, Vector3(_stud * 0.96, _plate * 2.9, _stud * 0.96), Vector3(0, _plate * 1.45, 0),
					_mat(Color(0.35, 0.36, 0.4), 0.6))
			# The face it watches with (front), a light at its back.
			_add_box(turn, Vector3(_stud * 0.06, _plate * 1.6, _stud * 0.7), Vector3(_stud * 0.49, _plate * 1.5, 0),
					_mat(Color(0.1, 0.1, 0.12), 0.4))
			for z in [-0.18, 0.18]:
				_add_box(turn, Vector3(_stud * 0.08, _plate * 0.4, _stud * 0.14), Vector3(_stud * 0.52, _plate * 1.8, z * _stud),
						_mat(Color(0.9, 0.9, 0.85), 0.3))
			var glow := _mat(Color(0.8, 0.15, 0.1), 0.3)
			glow.emission_enabled = true
			glow.emission = Color(1.0, 0.2, 0.1)
			glow.emission_energy_multiplier = 0.0
			var dot := _add_box(turn, Vector3(_stud * 0.06, _plate * 0.6, _stud * 0.3), Vector3(-_stud * 0.49, _plate * 1.5, 0), glow)
			dot.name = "Glow"
		"gate":
			# A slab, a coloured brick on it, an arrow at the front (+x before
			# the turn), a light on top that glows while the output is on.
			var col: Color = def.get("colour", Color.GRAY)
			var turn := Node3D.new()
			turn.name = "Turn"
			root.add_child(turn)
			_add_box(turn, Vector3(_stud * 0.96, _plate, _stud * 0.96), Vector3(0, _plate * 0.5, 0), stone)
			_add_box(turn, Vector3(_stud * 0.8, _plate * 1.6, _stud * 0.8), Vector3(0, _plate * 1.8, 0), _mat(col, 0.45))
			_add_box(turn, Vector3(_stud * 0.16, _plate * 0.9, _stud * 0.34), Vector3(_stud * 0.46, _plate * 1.6, 0),
					_mat(Color(0.95, 0.95, 0.9), 0.4))
			var glow := _mat(col.lightened(0.4), 0.3)
			glow.emission_enabled = true
			glow.emission = col.lightened(0.3)
			glow.emission_energy_multiplier = 0.0
			var lamp := _add_box(turn, Vector3(_stud * 0.3, _plate * 0.4, _stud * 0.3), Vector3(0, _plate * 2.8, 0), glow)
			lamp.name = "Glow"
	return root


func _add_box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh(size)
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


static func _mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


## Turning +x (the model's front) to a facing, about y.
static func _yaw(f: int) -> float:
	return [0.0, PI, -PI * 0.5, PI * 0.5][f]


## A device's look follows its state.
func _show_device(c: Vector3i) -> void:
	var d: Dictionary = devices[c]
	var node: Node3D = d.node
	if not is_instance_valid(node):
		return
	match str(DEVICES[d.item].kind):
		"switch":
			var arm := node.get_node_or_null("Arm") as Node3D
			if arm != null:
				arm.rotation = Vector3(deg_to_rad(40.0 if bool(d.on) else -40.0), 0, 0)
		"button":
			var push := node.get_node_or_null("Push") as Node3D
			if push != null:
				push.position.y = _plate * (1.5 if int(d.out) > 0 or int(d.timer) > 0 else 1.65)
		"pressure":
			var pl := node.get_node_or_null("Plate") as Node3D
			if pl != null:
				pl.scale.y = 0.6 if int(d.out) > 0 else 1.0
				pl.position.y = _plate * (0.21 if int(d.out) > 0 else 0.35)
		"trip":
			node.rotation.y = _yaw(int(d.facing))
		"lamp":
			var glass := node.get_node_or_null("Glass") as MeshInstance3D
			if glass != null:
				(glass.material_override as StandardMaterial3D).emission_energy_multiplier = 3.0 if bool(d.lit) else 0.0
			var light := node.get_node_or_null("Light") as OmniLight3D
			if light != null:
				light.visible = bool(d.lit)
		"door":
			var h := node.get_node_or_null("Turn/Hinge") as Node3D
			if h != null:
				h.rotation.y = PI * 0.5 if bool(d.on) else 0.0
		"trapdoor":
			var h2 := node.get_node_or_null("Turn/Hinge") as Node3D
			if h2 != null:
				h2.rotation.z = -PI * 0.5 if bool(d.on) else 0.0
		"observer":
			var turn2 := node.get_node_or_null("Turn") as Node3D
			if turn2 != null:
				turn2.rotation.y = _yaw(int(d.facing))
				var g2 := turn2.get_node_or_null("Glow") as MeshInstance3D
				if g2 != null:
					(g2.material_override as StandardMaterial3D).emission_energy_multiplier = 3.0 if int(d.out) > 0 else 0.0
		"gate":
			var turn := node.get_node_or_null("Turn") as Node3D
			if turn != null:
				turn.rotation.y = _yaw(int(d.facing))
				var g := turn.get_node_or_null("Glow") as MeshInstance3D
				if g != null:
					(g.material_override as StandardMaterial3D).emission_energy_multiplier = 3.0 if int(d.out) > 0 else 0.0


# ---------------------------------------------------------------------------
# Saving

## {"cables": [x, y, z, ...], "devices": {"x,y,z": {"item", "on", "facing",
## "setting"}}}: JSON.
func to_save() -> Dictionary:
	var flat: Array = []
	for c in cables:
		flat.append_array([c.x, c.y, c.z])
	var devs := {}
	for c in devices:
		var d: Dictionary = devices[c]
		devs[key_of(c)] = {"item": String(d.item), "on": bool(d.on), "facing": int(d.facing),
				"setting": int(d.setting)}
	return {"cables": flat, "devices": devs}


func restore(saved) -> void:
	clear()
	if not (saved is Dictionary):
		return
	var flat = saved.get("cables", [])
	if flat is Array:
		for i in range(0, flat.size() - 2, 3):
			place_cable(Vector3i(int(flat[i]), int(flat[i + 1]), int(flat[i + 2])), true)
	var devs = saved.get("devices", {})
	if devs is Dictionary:
		for k in devs:
			var p := str(k).split(",")
			var e = devs[k]
			if p.size() != 3 or not (e is Dictionary):
				continue
			place_device(Vector3i(int(p[0]), int(p[1]), int(p[2])), StringName(str(e.get("item", ""))),
					bool(e.get("on", false)), true, int(e.get("facing", 0)), int(e.get("setting", -1)))
	# Loading is not a change: no observer fires for it.
	for c in devices:
		if str(DEVICES[devices[c].item].kind) == "observer":
			devices[c].timer = 0
	tick()
