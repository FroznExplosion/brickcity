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
##   gate tile      a solid brick (a collider) that turns passable while
##                  powered -- Terraria's actuator. Gate tiles touching (side
##                  by side, stacked) are one group and open together; one
##                  stands on ground or on/beside another (stage 3b, 16).
##   sequencer      faces a way: its back turning on runs a program of
##                  on/off steps out of its front (RMB picks the program) --
##                  Create's sequenced gearshift.
##   number display a 2-stud brick showing the level beside it, 0-15.
##   piston         faces a way or UP: power rising pushes the placed brick in
##                  front (and every placed brick clutched on its top, and
##                  any in its line) one stud, or one course up; falling
##                  retracts. A sticky piston pulls the brick back. Generated
##                  ground, a device or more than 12 bricks stall it (stage
##                  4, section 18).
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
## The sequencer's programs: ticks on, off, on, ... (RMB steps through them).
const PROGRAMS := [[5, 5, 5], [10], [2, 2, 2, 2, 2], [20, 10, 20], [3, 3, 3, 3, 3, 3, 3], [10, 30, 10]]
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
	# Stage 3b (section 16).
	&"gate_tile": {"kind": "gatetile", "plates": 3},
	&"sequencer": {"kind": "gate", "op": "sequence", "plates": 3, "facing": true, "colour": Color(0.85, 0.45, 0.2)},
	&"number_display": {"kind": "display", "plates": 3, "w": 2, "facing": true},
	# Stage 4 (section 18). up: may face UP too (FACE_UP).
	&"piston": {"kind": "piston", "plates": 3, "facing": true, "up": true},
	&"sticky_piston": {"kind": "piston", "plates": 3, "facing": true, "up": true, "sticky": true},
}
## The fifth facing: up (a piston laid looking steeply down).
const FACE_UP := 4
## Plates in a course (a brick's height): a placed brick is one course of
## plate cells.
const COURSE := 3
## The most bricks one push moves (Minecraft's 12).
const PISTON_LIMIT := 12
## Pushes started in one tick; the rest wait for the next.
const PUSHES_PER_TICK := 4
## A move's slide (s), and the longest wait for the tiles at each end.
const MOVE_TIME := 0.2
const MOVE_WAIT := 0.35
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
## The placed brick holding cell (x, course, z), Vector4i(rx, rz, sx, sz) or
## zeros; clearing and laying plate boxes; marking a placed brick. The real
## field's by default; a probe gives its own ground (pistons, section 18).
var rect_fn: Callable = func(x: int, course: int, z: int) -> Vector4i: return BrickTerrain.placed_rect(x, course, z)
var clear_fn: Callable = func(lo: Vector3i, hi: Vector3i) -> Dictionary: return BrickTerrain.fill_box(lo, hi, BrickTerrain.MAT_AIR, false)
var lay_fn: Callable = func(lo: Vector3i, hi: Vector3i, mat: int) -> Dictionary: return BrickTerrain.fill_box(lo, hi, mat, false)
var mark_fn: Callable = func(lo: Vector3i, hi: Vector3i, mat: int) -> int: return BrickTerrain.mark_placed(lo, hi, mat)
## Pistons' moves drawn sliding (a host in the tree); off: written at once.
var animate := true

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
## Pistons: moves under way (each {bricks, step, phase, ...}), pushes started
## this tick, moves done (probes), why the last push stalled.
var _moves: Array = []
var _pushes := 0
var moves_done := 0
var last_stall := ""

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
	if not _moves.is_empty():
		_step_moves(delta)
	_clock += delta
	if _clock < TICK:
		return
	_clock = fmod(_clock, TICK)
	tick()


## One tick: nets rebuilt where cables changed, string pairs found again,
## the logic run (when anything can change), drawn.
func tick() -> void:
	ticks += 1
	_pushes = 0
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
		if k == "piston" and bool(d.on) != (int(d.prev) > 0):
			return true    # a stalled push tries again each tick
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


static func can_face_up(item: StringName) -> bool:
	return DEVICES.has(item) and bool(DEVICES[item].get("up", false))


## The facing a device is laid with, from the camera's direction: away from
## the player, or UP for a piston when the camera looks steeply down.
static func facing_for(item: StringName, dir: Vector3) -> int:
	if can_face_up(item) and dir.normalized().y < -0.75:
		return FACE_UP
	return facing_of(dir)


static func facing_name(f: int) -> String:
	return "up" if f == FACE_UP else SIDE_NAMES[clampi(f, 0, 3)]


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
	if str(DEVICES.get(item, {}).get("kind", "")) == "gatetile":
		# Ground under it, or another gate tile under or beside it.
		if _solid(c + Vector3i.DOWN) or _is_gatetile(c + Vector3i.DOWN):
			return true
		for s in SIDES:
			if _is_gatetile(c + s):
				return true
		return false
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


## Is plate cell `c` part of a gate tile?
func _is_gatetile(c: Vector3i) -> bool:
	var b = _occupied.get(c, null)
	return b != null and devices.has(b) and str(DEVICES[devices[b].item].kind) == "gatetile"


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
	return not cables.has(c) and _device_at(c) == null and not _solid(c) and _solid(c + Vector3i.DOWN) \
			and not _in_head(c)


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
		if _solid(k) or cables.has(k) or _device_at(k) != null or _in_head(k):
			return false
	return true


func place_device(c: Vector3i, item: StringName, on := false, force := false, facing := 0, setting := -1) -> bool:
	if not is_device(item) or (not force and not can_place_device(c, item, facing)):
		return false
	var op := str(DEVICES[item].get("op", ""))
	var st := setting
	if st < 0:
		st = 2 if op == "delay" else (5 if op == "pulse" else 0)
	var f := clampi(facing, 0, FACE_UP if can_face_up(item) else 3)
	var node := _device_node(c, item, f)
	add_child(node)
	devices[c] = {"item": item, "on": on, "facing": f, "setting": st, "timer": 0,
			"out": 0, "lit": false, "prev": 0, "queue": [], "step": 0, "node": node}
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
		if str(def.kind) == "piston":
			if bool(d.on):
				return false   # extended: not turned
			# +x, +z, -x, -z, then up, then +x again.
			var f0 := int(d.facing)
			d.facing = FACE_UP if f0 == 3 else (0 if f0 == FACE_UP else right_of(f0))
			# Built again: facing up is a different shape.
			var old: Node = d.node
			d.node = _device_node(c, d.item, int(d.facing))
			add_child(d.node)
			if is_instance_valid(old):
				old.queue_free()
		else:
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
					"sequence":
						d.setting = (int(d.setting) + 1) % PROGRAMS.size()
						d.timer = 0
						d.step = 0
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
	# An out piston's head fills the stud in front.
	for c in devices:
		var d: Dictionary = devices[c]
		if bool(d.on) and str(DEVICES[d.item].kind) == "piston":
			for k in head_cells(c, int(d.facing), 1):
				if _cell_box(k).grow(-0.01).intersects(box):
					return true
	# A piston's move under way: its old place and its new one are kept.
	for m in _moves:
		var mb: AABB = m.box
		if mb.merge(AABB(mb.position + _metres(m.step), mb.size)).grow(-0.01).intersects(box):
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
	var riding := _riding() if not _moves.is_empty() else {}
	for c in cables.keys():
		if riding.has(c):
			continue
		if _inside(c, lo2, hi2) and (_solid(c) or not _solid(c + Vector3i.DOWN)):
			remove_cable(c)
			gone += 1
	for c in devices.keys():
		if not _inside(c, lo2, hi2) or riding.has(c):
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
	for m in _moves:
		if is_instance_valid(m.node):
			(m.node as Node).queue_free()
	_moves.clear()
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
	# 3a. Pistons: power rising pushes, falling retracts (a sticky one pulls
	# its brick back). A stalled push tries again next tick; past
	# PUSHES_PER_TICK the rest wait a tick. Gone through a copy of the keys:
	# a move's edit can break devices (`check`).
	for c in devices.keys():
		if not devices.has(c) or str(DEVICES[devices[c].item].kind) != "piston":
			continue
		var d: Dictionary = devices[c]
		var want := piston_power(c) > 0
		d.prev = 1 if want else 0
		if want == bool(d.on) or _pushes >= PUSHES_PER_TICK:
			continue
		if want:
			if not _piston_push(c):
				continue
		else:
			_piston_pull(c)
		if devices.has(c):
			d.on = want
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
	# 3c. Gate tiles open as groups (touching side by side or stacked): a
	# group is open while any of it is powered. Number displays show the
	# level beside them.
	var seen := {}
	for c in devices:
		var d: Dictionary = devices[c]
		var k := str(DEVICES[d.item].kind)
		if k == "display":
			var lvl := power_in(c)
			if lvl != int(d.out):
				d.out = lvl
				_show_device(c)
			continue
		if k != "gatetile" or seen.has(c):
			continue
		var group: Array[Vector3i] = [c]
		seen[c] = true
		var i := 0
		var open := false
		while i < group.size():
			var g: Vector3i = group[i]
			open = open or power_in(g) > 0
			for s in [SIDES[0], SIDES[1], SIDES[2], SIDES[3], Vector3i(0, 3, 0), Vector3i(0, -3, 0)]:
				var n: Vector3i = g + s
				if devices.has(n) and not seen.has(n) and str(DEVICES[devices[n].item].kind) == "gatetile":
					seen[n] = true
					group.append(n)
			i += 1
		for g in group:
			if bool(devices[g].on) != open:
				devices[g].on = open
				_show_device(g)
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
		"sequence":
			# Its back turning on starts the program (not while it runs).
			var prog: Array = PROGRAMS[clampi(int(d.setting), 0, PROGRAMS.size() - 1)]
			var now := int(b[0]) > 0
			if now and int(d.prev) == 0 and int(d.timer) == 0:
				d.step = 0
				d.timer = int(prog[0])
			d.prev = 1 if now else 0
			var out := 0
			if int(d.timer) > 0:
				out = LEVEL_MAX if int(d.step) % 2 == 0 else 0
				d.timer = int(d.timer) - 1
				if int(d.timer) == 0:
					d.step = int(d.step) + 1
					if int(d.step) < prog.size():
						d.timer = int(prog[d.step])
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
	return devices.has(c) and bool(devices[c].on) and str(DEVICES[devices[c].item].kind) in ["door", "trapdoor", "gatetile"]


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
# Pistons (Docs/MineWiring.md 6, 17, 18)
#
# The unit that moves is a PLACED brick (BrickTerrain.mark_placed): one course
# of plate cells over a rectangle of studs. The group is the brick the head
# meets, every placed brick clutched on a group brick's top studs (clutch is
# slime, 6.3), and -- pushing -- every placed brick in the way. Generated
# ground (bonded into the hillside), bedrock, a device or a cable in a cell
# the group moves into, a chest there, or more than PISTON_LIMIT bricks stall
# the push.
#
# A move: the group's cells cleared (no collapse survey yet), a stand-in of
# its bricks drawn sliding from the old place to the new once the tiles have
# rebuilt without them (a hop -- up a plate, across, down -- for a sideways
# push of bricks resting on studs), then the bricks laid and marked at the
# new place, the edit's box the old and new places together, and the
# stand-in hidden once the tiles have them. Without a host (a probe) the move
# is written at once.

## The move one push makes, in plate cells: a stud the way it faces, or a
## course up.
static func piston_step(f: int) -> Vector3i:
	return Vector3i(0, COURSE, 0) if f == FACE_UP else SIDES[clampi(f, 0, 3)]


## The plate cells a piston's head meets: the stud in front (`reach` 1), or
## the one past its extended head (2), its height; above it, facing up.
static func head_cells(c: Vector3i, f: int, reach: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var base := c + piston_step(f) * reach
	for p in COURSE:
		out.append(base + Vector3i(0, p, 0))
	return out


## The power reaching a piston: any side but its front (its head's side).
func piston_power(c: Vector3i) -> int:
	var f := int(devices[c].facing)
	var lvl := 0
	for s in SIDES:
		if f != FACE_UP and s == SIDES[f]:
			continue
		lvl = maxi(lvl, int(side_input(c, s)[0]))
	return lvl


func _metres(step: Vector3i) -> Vector3:
	return Vector3(step.x * _stud, step.y * _plate, step.z * _stud)


## The placed brick holding plate cell `k`: {key, rect, course, cols, mat},
## or {} (air, or generated ground). `cols`: the studs of its rectangle that
## are still its own.
func brick_at(k: Vector3i) -> Dictionary:
	var course := floori(float(k.y) / COURSE)
	var r: Vector4i = rect_fn.call(k.x, course, k.z)
	if r.z <= 0 or r.w <= 0:
		return {}
	var cols: Array[Vector2i] = []
	for bx in range(r.x, r.x + r.z):
		for bz in range(r.y, r.y + r.w):
			if (bx == k.x and bz == k.z) or rect_fn.call(bx, course, bz) == r:
				cols.append(Vector2i(bx, bz))
	return {"key": Vector3i(r.x, course, r.y), "rect": r, "course": course, "cols": cols,
			"mat": int(solid_fn.call(k.x, course * COURSE, k.z))}


static func brick_cells(b: Dictionary) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for col: Vector2i in b.cols:
		for p in COURSE:
			out.append(Vector3i(col.x, int(b.course) * COURSE + p, col.y))
	return out


## The plate boxes a brick is written as, moved by `off`: its whole
## rectangle, or stud by stud when part of it is no longer its own.
static func _boxes_of(b: Dictionary, off: Vector3i) -> Array:
	var r: Vector4i = b.rect
	var y0 := int(b.course) * COURSE
	if (b.cols as Array).size() == r.z * r.w:
		return [[Vector3i(r.x, y0, r.y) + off, Vector3i(r.x + r.z - 1, y0 + COURSE - 1, r.y + r.w - 1) + off]]
	var out: Array = []
	for col: Vector2i in b.cols:
		out.append([Vector3i(col.x, y0, col.y) + off, Vector3i(col.x, y0 + COURSE - 1, col.y) + off])
	return out


## Is plate cell `k` the old or new place of a move under way?
func _reserved(k: Vector3i) -> bool:
	for m in _moves:
		if (m.cells as Dictionary).has(k):
			return true
	return false


## A chest in `box` (metres, terrain frame)?
func _chest_in(box: AABB) -> bool:
	if host == null or not ("chests" in host) or host.chests == null:
		return false
	return host.chests.overlaps(box)


func _cell_box(k: Vector3i) -> AABB:
	return AABB(Vector3(k.x * _stud, k.y * _plate, k.z * _stud), Vector3(_stud, _plate, _stud))


## What a head meets: {"seeds": [bricks]} (none: air) or {"stall": why}.
func _head_meets(c: Vector3i, f: int, reach: int) -> Dictionary:
	var seeds: Array = []
	var keys := {}
	for k in head_cells(c, f, reach):
		if cables.has(k) or _device_at(k) != null:
			return {"stall": "a device in front"}
		if _reserved(k):
			return {"stall": "a move under way"}
		if _chest_in(_cell_box(k).grow(-0.01)):
			return {"stall": "a chest in front"}
		if not _solid(k):
			continue
		var b := brick_at(k)
		if b.is_empty():
			return {"stall": "ground in front"}
		if not keys.has(b.key):
			keys[b.key] = true
			seeds.append(b)
	return {"seeds": seeds}


## The group one move of `step` (plate cells) takes, from the bricks the head
## meets: {"bricks": [...]} or {"stall": why}. With `line` (a push), a placed
## brick in the way comes too; a pull takes only what is clutched on top.
func piston_group(seeds: Array, step: Vector3i, line: bool, pusher := Vector3i(WHOLE, WHOLE, WHOLE)) -> Dictionary:
	var group := {}
	var order: Array = []
	var queue: Array = seeds.duplicate()
	while not queue.is_empty():
		var b: Dictionary = queue.pop_back()
		if group.has(b.key):
			continue
		group[b.key] = true
		order.append(b)
		if order.size() > PISTON_LIMIT:
			return {"stall": "more than %d bricks" % PISTON_LIMIT}
		for col: Vector2i in b.cols:
			# Clutched on its top studs: comes along.
			var up := Vector3i(col.x, (int(b.course) + 1) * COURSE, col.y)
			if _solid(up):
				var nb := brick_at(up)
				if not nb.is_empty() and not group.has(nb.key):
					queue.append(nb)
			if not line:
				continue
			for p in COURSE:
				var d := Vector3i(col.x, int(b.course) * COURSE + p, col.y) + step
				if _solid(d):
					var nb2 := brick_at(d)
					if not nb2.is_empty() and not group.has(nb2.key):
						queue.append(nb2)
	var src := {}
	for b in order:
		for k in brick_cells(b):
			src[k] = true
	# Riders: wires and devices standing on a group brick's top come along
	# (a device by any of its bottom cells; the pushing piston never).
	var r_cables: Array[Vector3i] = []
	var r_devices: Array[Vector3i] = []
	var riding := {}
	for b in order:
		for col: Vector2i in b.cols:
			var t := Vector3i(col.x, (int(b.course) + 1) * COURSE, col.y)
			if src.has(t):
				continue
			if cables.has(t) and not riding.has(t):
				r_cables.append(t)
				riding[t] = true
			var dc = _occupied.get(t, null)
			if dc != null and dc != pusher and (dc as Vector3i).y == t.y and not r_devices.has(dc):
				r_devices.append(dc)
				for k in cells_of(dc, devices[dc].item, int(devices[dc].facing)):
					riding[k] = true
	for b in order:
		for k in brick_cells(b):
			var d: Vector3i = k + step
			if src.has(d) or riding.has(d):
				continue
			if _solid(d):
				return {"stall": "ground in the way at %s" % key_of(d)}
			if cables.has(d) or _device_at(d) != null or _in_head(d, pusher):
				return {"stall": "a device in the way at %s" % key_of(d)}
			if _reserved(d):
				return {"stall": "a move under way"}
		var dst := _bricks_box([b])
		if _chest_in(AABB(dst.position + _metres(step), dst.size).grow(-0.01)):
			return {"stall": "a chest in the way"}
	for k in riding:
		var d: Vector3i = k + step
		if src.has(d) or riding.has(d):
			continue
		if _solid(d):
			return {"stall": "ground in the way of what rides at %s" % key_of(d)}
		if cables.has(d) or _device_at(d) != null or _in_head(d, pusher):
			return {"stall": "a device in the way of what rides at %s" % key_of(d)}
		if _reserved(d):
			return {"stall": "a move under way"}
	return {"bricks": order, "cables": r_cables, "devices": r_devices}


## Does a loose group the collapse found rest on a piston -- on its body's
## top, or on its head's top while out? Then the collapse leaves it standing.
## `g`: the survey's bricks, 6 ints each (x, bottom plate, z, sx, sz, mat).
func holds(g: PackedInt32Array) -> bool:
	var tops := {}
	for c in devices:
		var d: Dictionary = devices[c]
		if str(DEVICES[d.item].kind) != "piston":
			continue
		tops[c + Vector3i(0, COURSE, 0)] = true
		if bool(d.on):
			var f := int(d.facing)
			tops[c + piston_step(f) + Vector3i(0, COURSE, 0)] = true
	if tops.is_empty():
		return false
	for i in range(0, g.size() - 5, 6):
		for dz in g[i + 4]:
			for dx in g[i + 3]:
				if tops.has(Vector3i(g[i] + dx, g[i + 1], g[i + 2] + dz)):
					return true
	return false


## Ask the host's collapse to look at a box (plate cells): what it holds up
## may have gone.
func _survey(lo: Vector3i, hi: Vector3i) -> void:
	if host != null and "collapse" in host and host.collapse != null:
		host.collapse.queue({"box_lo": lo, "box_hi": hi})


## The box (metres) round some bricks.
func _bricks_box(bricks: Array) -> AABB:
	var box := AABB()
	var first := true
	for b in bricks:
		for bx in _boxes_of(b, Vector3i.ZERO):
			var lo: Vector3i = bx[0]
			var hi: Vector3i = bx[1]
			var one := AABB(Vector3(lo.x * _stud, lo.y * _plate, lo.z * _stud),
					Vector3((hi.x - lo.x + 1) * _stud, (hi.y - lo.y + 1) * _plate, (hi.z - lo.z + 1) * _stud))
			box = one if first else box.merge(one)
			first = false
	return box


func _stalled(d: Dictionary, why: String) -> bool:
	d.stall = why
	last_stall = why
	return false


## Power rose: push what the head meets. False if it stalled (the head stays
## in, and it tries again next tick).
func _piston_push(c: Vector3i) -> bool:
	var d: Dictionary = devices[c]
	var f := int(d.facing)
	var meet := _head_meets(c, f, 1)
	if meet.has("stall"):
		return _stalled(d, meet.stall)
	var seeds: Array = meet.seeds
	if seeds.is_empty():
		d.stall = ""
		return true          # the head goes out into the air
	var g := piston_group(seeds, piston_step(f), true, c)
	if g.has("stall"):
		return _stalled(d, g.stall)
	_move(g, piston_step(f))
	d.stall = ""
	return true


## Power fell: the head comes in; a sticky one brings the brick at its face
## back with it (with what is clutched on it). What will not come stays --
## and what only the head held up is surveyed, so it falls.
func _piston_pull(c: Vector3i) -> void:
	var d: Dictionary = devices[c]
	var f0 := int(d.facing)
	var hc := head_cells(c, f0, 2 if f0 == FACE_UP else 1)
	_survey(hc[0] - Vector3i(1, 1, 1), hc[COURSE - 1] + Vector3i(1, COURSE + 1, 1))
	if not bool(DEVICES[d.item].get("sticky", false)):
		return
	var f := int(d.facing)
	var meet := _head_meets(c, f, 2)
	if meet.has("stall") or (meet.seeds as Array).is_empty():
		return
	var g := piston_group(meet.seeds, -piston_step(f), false, c)
	if g.has("stall"):
		last_stall = g.stall
		return
	_move(g, -piston_step(f))


func _move(g: Dictionary, step: Vector3i) -> void:
	var bricks: Array = g.bricks
	_pushes += 1
	var cells := {}
	var lo := Vector3i(WHOLE, WHOLE, WHOLE)
	var hi := -lo
	for b in bricks:
		for k in brick_cells(b):
			for q in [k, k + step]:
				cells[q] = true
				lo = Vector3i(mini(lo.x, q.x), mini(lo.y, q.y), mini(lo.z, q.z))
				hi = Vector3i(maxi(hi.x, q.x), maxi(hi.y, q.y), maxi(hi.z, q.z))
	var r_cables: Array = g.get("cables", [])
	var r_devices: Array = g.get("devices", [])
	var base := {}
	for c in r_cables:
		cells[c] = true
		cells[c + step] = true
	for dc in r_devices:
		for k in cells_of(dc, devices[dc].item, int(devices[dc].facing)):
			cells[k] = true
			cells[k + step] = true
		if is_instance_valid(devices[dc].node):
			base[dc] = (devices[dc].node as Node3D).position
	var m := {"bricks": bricks, "step": step, "cells": cells, "lo": lo, "hi": hi, "phase": 0, "t": 0.0,
			"wait": 0.0, "off": Vector3.ZERO, "box": _bricks_box(bricks), "node": null, "rect": Rect2i(),
			"cables": r_cables, "devices": r_devices, "base": base}
	if host == null or not animate or not is_inside_tree():
		_lift(bricks)
		_land(m)
		return
	m.hop = step.y == 0 and hops(bricks)
	m.node = _standin(bricks)
	add_child(m.node)
	var res := _lift(bricks)
	# The collapse judges it once, when it lands (the old place and the new).
	res["anchored"] = true
	m.rect = _tile_rect(res)
	_moves.append(m)
	_edited(res)


## Does any of the group rest on STUDS that stay (6.2)? Then a sideways move
## hops; on smooth tiles (road, farmland, glass: no studs) or hanging free it
## slides plainly.
func hops(bricks: Array) -> bool:
	var src := {}
	for b in bricks:
		for k in brick_cells(b):
			src[k] = true
	for b in bricks:
		for col: Vector2i in b.cols:
			var under := Vector3i(col.x, int(b.course) * COURSE - 1, col.y)
			if not src.has(under) and _solid(under) and studded(int(solid_fn.call(under.x, under.y, under.z))):
				return true
	return false


## Has terrain material `m` studs on its top (brick_terrain.h material_studded)?
static func studded(m: int) -> bool:
	return m != 0 and m != BrickTerrain.MAT_ROAD and m != BrickTerrain.MAT_FARMLAND \
			and m != BrickTerrain.MAT_WET_FARMLAND and m != MineBuildings.glass_material()


func _lift(bricks: Array) -> Dictionary:
	var out := {}
	for b in bricks:
		for bx in _boxes_of(b, Vector3i.ZERO):
			out = _merge(out, clear_fn.call(bx[0], bx[1]))
	return out


## The group laid at its new place and marked, one brick each again; the
## edit's box is the old and new places together.
func _land(m: Dictionary) -> void:
	var out := {}
	var step: Vector3i = m.step
	for b in m.bricks:
		for bx in _boxes_of(b, step):
			out = _merge(out, lay_fn.call(bx[0], bx[1], int(b.mat)))
	for b in m.bricks:
		var r: Vector4i = b.rect
		var lo := Vector3i(r.x, int(b.course) * COURSE, r.y) + step
		mark_fn.call(lo, lo + Vector3i(r.z - 1, COURSE - 1, r.w - 1), int(b.mat))
	out["box_lo"] = m.lo
	out["box_hi"] = m.hi
	_shift_riders(m)
	m.rect = _tile_rect(out)
	m.phase = 2
	m.wait = 0.0
	m.off = _metres(step)
	moves_done += 1
	_edited(out)


## What rode on the group goes to its new cells (before the landing's check,
## which then finds them held).
func _shift_riders(m: Dictionary) -> void:
	var step: Vector3i = m.step
	var moved_cables: Array = []
	for c in m.get("cables", []):
		if cables.has(c):
			cables.erase(c)
			_changed_cells.append(c)
			moved_cables.append(c)
	for c in moved_cables:
		cables[c + step] = true
		_changed_cells.append(c + step)
	var moved := {}
	for dc in m.get("devices", []):
		if not devices.has(dc):
			continue
		var d: Dictionary = devices[dc]
		for k in cells_of(dc, d.item, int(d.facing)):
			if _occupied.get(k, null) == dc:
				_occupied.erase(k)
		devices.erase(dc)
		moved[dc + step] = d
	for nc in moved:
		var d: Dictionary = moved[nc]
		devices[nc] = d
		for k in cells_of(nc, d.item, int(d.facing)):
			_occupied[k] = nc
		if is_instance_valid(d.node):
			var box := device_box(nc)
			(d.node as Node3D).position = Vector3(box.get_center().x, box.position.y, box.get_center().z)
	m.devices = []
	m.cables = []
	if not moved_cables.is_empty() or not moved.is_empty():
		_pairs_dirty = true
		_logic_dirty = true
		_draw_dirty = true
		_changed()


## Wires and devices riding a move under way: `check` leaves them be (their
## ground is cleared while they slide).
func _riding() -> Dictionary:
	var out := {}
	for m in _moves:
		if int(m.phase) >= 2:
			continue
		for c in m.get("cables", []):
			out[c] = true
		for dc in m.get("devices", []):
			out[dc] = true
	return out


## Is plate cell `k` the stud an out piston's head fills?
func _in_head(k: Vector3i, skip := Vector3i(WHOLE, WHOLE, WHOLE)) -> bool:
	for c in devices:
		if c == skip:
			continue
		var d: Dictionary = devices[c]
		if bool(d.on) and str(DEVICES[d.item].kind) == "piston" and head_cells(c, int(d.facing), 1).has(k):
			return true
	return false


static func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	if a.is_empty():
		return b.duplicate()
	if b.is_empty():
		return a
	var out := a.duplicate()
	var t := PackedInt32Array(a.get("tiles", PackedInt32Array()))
	t.append_array(PackedInt32Array(b.get("tiles", PackedInt32Array())))
	out["tiles"] = t
	out["changed"] = int(a.get("changed", 0)) + int(b.get("changed", 0))
	if a.has("box_lo") and b.has("box_lo"):
		var al: Vector3i = a.box_lo
		var ah: Vector3i = a.box_hi
		var bl: Vector3i = b.box_lo
		var bh: Vector3i = b.box_hi
		out["box_lo"] = Vector3i(mini(al.x, bl.x), mini(al.y, bl.y), mini(al.z, bl.z))
		out["box_hi"] = Vector3i(maxi(ah.x, bh.x), maxi(ah.y, bh.y), maxi(ah.z, bh.z))
	elif b.has("box_lo"):
		out["box_lo"] = b.box_lo
		out["box_hi"] = b.box_hi
	return out


## The ground changed: the host rebakes, surveys and checks (terrain_edited);
## a probe's wiring checks itself.
func _edited(res: Dictionary) -> void:
	if not res.has("tiles"):
		res["tiles"] = PackedInt32Array()
	if host != null and host.has_method("terrain_edited"):
		host.terrain_edited(res)
	elif res.has("box_lo"):
		check(res.box_lo, res.box_hi)


static func _tile_rect(res: Dictionary) -> Rect2i:
	var tiles: PackedInt32Array = res.get("tiles", PackedInt32Array())
	if tiles.is_empty():
		return Rect2i()
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for i in range(0, tiles.size(), 2):
		lo = Vector2i(mini(lo.x, tiles[i]), mini(lo.y, tiles[i + 1]))
		hi = Vector2i(maxi(hi.x, tiles[i]), maxi(hi.y, tiles[i + 1]))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


func _fresh(rect: Rect2i) -> bool:
	if not rect.has_area() or host == null or not host.has_method("tiles_fresh"):
		return true
	return host.tiles_fresh(rect)


## Moves under way, each frame: waiting for the tiles to let the old place
## go (0), sliding (1), waiting for the tiles to show the new place (2).
func _step_moves(delta: float) -> void:
	var i := 0
	while i < _moves.size():
		var m: Dictionary = _moves[i]
		m.wait = float(m.wait) + delta
		match int(m.phase):
			0:
				if _fresh(m.rect) or float(m.wait) > MOVE_WAIT:
					m.phase = 1
			1:
				m.t = minf(float(m.t) + delta, MOVE_TIME)
				var off := _path(m, float(m.t) / MOVE_TIME)
				_carry(m, m.off, off)
				m.off = off
				if is_instance_valid(m.node):
					(m.node as Node3D).position = off
				for dc in m.devices:
					if devices.has(dc) and is_instance_valid(devices[dc].node) and (m.base as Dictionary).has(dc):
						(devices[dc].node as Node3D).position = m.base[dc] + off
				if float(m.t) >= MOVE_TIME:
					_land(m)
			2:
				if _fresh(m.rect) or float(m.wait) > MOVE_WAIT:
					if is_instance_valid(m.node):
						(m.node as Node).queue_free()
					_moves.remove_at(i)
					continue
		i += 1


## Every move written now and its stand-in gone (a save, a probe).
func finish_moves() -> void:
	for m in _moves:
		if int(m.phase) < 2:
			_land(m)
		if is_instance_valid(m.node):
			(m.node as Node).queue_free()
	_moves.clear()


## Where the stand-in is at `u` (0..1) of the slide, metres: straight up or
## down, straight across hanging free, or the HOP across studs (6.2): up a
## plate, across, pressed down.
func _path(m: Dictionary, u: float) -> Vector3:
	var full := _metres(m.step)
	if full.y != 0.0 or not bool(m.get("hop", false)):
		return full * smoothstep(0.0, 1.0, u)
	var lift := _plate
	if u < 1.0 / 3.0:
		return Vector3(0, lift * smoothstep(0.0, 1.0, u * 3.0), 0)
	if u < 2.0 / 3.0:
		return full * smoothstep(0.0, 1.0, (u - 1.0 / 3.0) * 3.0) + Vector3(0, lift, 0)
	return full + Vector3(0, lift * (1.0 - smoothstep(0.0, 1.0, (u - 2.0 / 3.0) * 3.0)), 0)


static func _over(p: Vector3, box: AABB, grow: float) -> bool:
	return p.x >= box.position.x - grow and p.x <= box.end.x + grow \
			and p.z >= box.position.z - grow and p.z <= box.end.z + grow


## The player in the way of a moving group (the carried-by-contact rule kept
## simple, Hulls.md 7b.3): standing on it, carried along and kept on its top;
## beside it as it moves across, shoved; under a rising one, lifted onto it.
func _carry(m: Dictionary, was: Vector3, now: Vector3) -> void:
	if host == null or not host.has_method("shove_player_local"):
		return
	var feet: Vector3 = host.player_feet_local()
	if feet == Vector3.INF:
		return
	var box: AABB = m.box
	box.position += now
	var top := box.end.y
	var dv := now - was
	var step: Vector3i = m.step
	var by := Vector3.ZERO
	if _over(feet, box, 0.12) and feet.y >= top - 0.2 and feet.y <= top + 0.3:
		by = Vector3(dv.x, 0.0, dv.z)
		if feet.y < top:
			by.y = top - feet.y
	elif step.y == 0 and _over(feet, box, 0.3) and feet.y > box.position.y - 1.7 and feet.y < top - 0.2:
		by = Vector3(dv.x, 0.0, dv.z)
	elif step.y > 0 and _over(feet, box, 0.05) and feet.y >= box.position.y - 0.05 and feet.y < top:
		by.y = top - feet.y
	if by != Vector3.ZERO:
		host.shove_player_local(by)


## The stand-in of a moving group: its bricks as boxes with studs on their
## tops (one MultiMesh each), a kinematic body of the same boxes to stand on.
func _standin(bricks: Array) -> Node3D:
	var root := Node3D.new()
	root.name = "PistonMove"
	root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.5
	var body := AnimatableBody3D.new()
	body.name = "Body"
	body.sync_to_physics = false
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	root.add_child(body)
	var src := {}
	for b in bricks:
		for k in brick_cells(b):
			src[k] = true
	var boxes: Array = []
	var tops: Array = []
	var stud_h := _plate * 0.53
	for b in bricks:
		var col := BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(int(b.mat)))
		for bx in _boxes_of(b, Vector3i.ZERO):
			var lo: Vector3i = bx[0]
			var hi: Vector3i = bx[1]
			var size := Vector3((hi.x - lo.x + 1) * _stud, (hi.y - lo.y + 1) * _plate, (hi.z - lo.z + 1) * _stud)
			var mid := Vector3(lo.x * _stud, lo.y * _plate, lo.z * _stud) + size * 0.5
			boxes.append([Transform3D(Basis.from_scale(size - Vector3.ONE * 0.004), mid), col])
			var shape := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = size
			shape.shape = bs
			shape.position = mid
			body.add_child(shape)
		for c2: Vector2i in b.cols:
			var top_y := (int(b.course) + 1) * COURSE
			if not src.has(Vector3i(c2.x, top_y, c2.y)):
				tops.append([Transform3D(Basis(), Vector3((c2.x + 0.5) * _stud, top_y * _plate + stud_h * 0.5,
						(c2.y + 0.5) * _stud)), col])
	var cyl := CylinderMesh.new()
	cyl.top_radius = _stud * 0.3
	cyl.bottom_radius = _stud * 0.3
	cyl.height = stud_h
	cyl.radial_segments = 12
	for pair in [[_box_mesh(Vector3.ONE), boxes], [cyl, tops]]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = pair[0]
		var list: Array = pair[1]
		mm.instance_count = list.size()
		for k in list.size():
			mm.set_instance_transform(k, list[k][0])
			mm.set_instance_color(k, list[k][1])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = mat
		root.add_child(mi)
	return root


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
			parts.append("faces %s" % facing_name(f))
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
			"sequence":
				var prog: Array = PROGRAMS[clampi(int(d.setting), 0, PROGRAMS.size() - 1)]
				var steps: Array[String] = []
				for i in prog.size():
					steps.append("%d %s" % [int(prog[i]), "on" if i % 2 == 0 else "off"])
				parts.append("program: %s (RMB)" % ", ".join(steps))
		if str(def.kind) == "gatetile":
			parts.append("open" if bool(d.on) else "solid")
		if str(def.kind) == "display":
			parts.append("shows %d" % int(d.out))
		if str(def.kind) == "trip":
			parts.append("string to %s" % key_of(pairs[c]) if pairs.has(c) else "no string")
		if str(def.kind) == "lamp":
			parts.append("lit" if bool(d.lit) else "dark")
		if str(def.kind) in ["door", "trapdoor"]:
			parts.append("open" if bool(d.on) else "shut")
			parts.append("power %d" % power_in(c))
		if str(def.kind) == "observer":
			parts.append("watches %s" % key_of(_watched(c)[0]))
		if str(def.kind) == "piston":
			parts.append("extended" if bool(d.on) else "retracted")
			parts.append("power %d" % piston_power(c))
			if bool(def.get("sticky", false)):
				parts.append("sticky")
			if (int(d.prev) > 0) != bool(d.on) and str(d.get("stall", "")) != "":
				parts.append("stalled: %s" % d.stall)
		return " | ".join(parts)
	if target.has("cable") and net_of.has(target.cable):
		var id: int = net_of[target.cable]
		var n_dev := 0
		for c in devices:
			if device_nets(c).has(id):
				n_dev += 1
		return "Wire -- level %d | %d wires | %d devices on it" % [int(nets[id].level),
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
	# Cables never move: no physics interpolation (it warns when a MultiMesh
	# is changed outside the physics tick, as the wiring's tick does).
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
		"gatetile":
			# A brick with a stud, a collider; open, see-through and no collider.
			var body := StaticBody3D.new()
			body.name = "Body"
			body.collision_layer = Layers.WORLD
			body.collision_mask = 0
			var shape := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = box.size
			shape.shape = bs
			shape.position = Vector3(0, box.size.y * 0.5, 0)
			body.add_child(shape)
			root.add_child(body)
			var m := _mat(Color(0.22, 0.42, 0.48), 0.5)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var bm := _add_box(root, box.size * Vector3(0.98, 0.99, 0.98), Vector3(0, box.size.y * 0.495, 0), m)
			bm.name = "Brick"
			var cyl := CylinderMesh.new()
			cyl.top_radius = _stud * 0.3
			cyl.bottom_radius = _stud * 0.3
			cyl.height = _plate * 0.6
			var stud := MeshInstance3D.new()
			stud.name = "Stud"
			stud.mesh = cyl
			stud.material_override = m
			stud.position = Vector3(0, box.size.y + _plate * 0.3, 0)
			root.add_child(stud)
		"display":
			# A 2-stud brick, the level printed on its front.
			var turn := Node3D.new()
			turn.name = "Turn"
			turn.rotation.y = _yaw(facing)
			root.add_child(turn)
			_add_box(turn, Vector3(_stud * 0.96, _plate * 2.9, _stud * 1.96), Vector3(0, _plate * 1.45, 0),
					_mat(Color(0.12, 0.13, 0.15), 0.5))
			var lab := Label3D.new()
			lab.name = "Number"
			lab.text = "0"
			lab.pixel_size = 0.004
			lab.font_size = 64
			lab.outline_size = 0
			lab.modulate = Color(0.4, 1.0, 0.45)
			lab.position = Vector3(_stud * 0.49, _plate * 1.45, 0)
			lab.rotation.y = PI * 0.5
			turn.add_child(lab)
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
		"piston":
			# A grey body, a tan head plate (green on a sticky one) at the
			# front (+x before the turn; up, turned about z). The head slides
			# out a stud, or a course facing up, on a rod. A collider.
			var up_f := facing == FACE_UP
			var len_f := COURSE * _plate if up_f else _stud
			var h := _stud if up_f else COURSE * _plate
			root.set_meta("reach", len_f)
			var pbody := StaticBody3D.new()
			pbody.collision_layer = Layers.WORLD
			pbody.collision_mask = 0
			var pshape := CollisionShape3D.new()
			var pbs := BoxShape3D.new()
			pbs.size = box.size
			pshape.shape = pbs
			pshape.position = Vector3(0, box.size.y * 0.5, 0)
			pbody.add_child(pshape)
			root.add_child(pbody)
			var pturn := Node3D.new()
			pturn.name = "Turn"
			pturn.position = Vector3(0, box.size.y * 0.5, 0)
			if up_f:
				pturn.rotation.z = PI * 0.5
			else:
				pturn.rotation.y = _yaw(facing)
			root.add_child(pturn)
			_add_box(pturn, Vector3(len_f * 0.7, h * 0.96, _stud * 0.96), Vector3(-len_f * 0.15, 0, 0),
					_mat(Color(0.33, 0.34, 0.37), 0.6))
			var head := Node3D.new()
			head.name = "Head"
			pturn.add_child(head)
			var face := Color(0.36, 0.66, 0.3) if bool(def.get("sticky", false)) else Color(0.76, 0.62, 0.4)
			_add_box(head, Vector3(len_f * 0.26, h * 0.98, _stud * 0.98), Vector3(len_f * 0.36, 0, 0), _mat(face, 0.55))
			var rod := _add_box(head, Vector3(len_f, minf(h, _stud) * 0.22, _stud * 0.22), Vector3(-len_f * 0.24, 0, 0),
					_mat(Color(0.7, 0.7, 0.72), 0.3))
			rod.name = "Rod"
			rod.visible = false
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
		"gatetile":
			var body := node.get_node_or_null("Body") as StaticBody3D
			if body != null:
				body.collision_layer = 0 if bool(d.on) else Layers.WORLD
			var bm := node.get_node_or_null("Brick") as MeshInstance3D
			if bm != null:
				var m := bm.material_override as StandardMaterial3D
				m.albedo_color.a = 0.22 if bool(d.on) else 1.0
		"display":
			var lab := node.get_node_or_null("Turn/Number") as Label3D
			if lab != null:
				lab.text = str(int(d.out))
		"observer":
			var turn2 := node.get_node_or_null("Turn") as Node3D
			if turn2 != null:
				turn2.rotation.y = _yaw(int(d.facing))
				var g2 := turn2.get_node_or_null("Glow") as MeshInstance3D
				if g2 != null:
					(g2.material_override as StandardMaterial3D).emission_energy_multiplier = 3.0 if int(d.out) > 0 else 0.0
		"piston":
			var head := node.get_node_or_null("Turn/Head") as Node3D
			if head != null:
				var reach := float(node.get_meta("reach", _stud))
				var to := reach if bool(d.on) else 0.0
				var rod := head.get_node_or_null("Rod") as Node3D
				if rod != null:
					rod.visible = bool(d.on)
				if node.is_inside_tree() and not is_equal_approx(head.position.x, to):
					var tw := node.create_tween()
					tw.tween_property(head, "position:x", to, MOVE_TIME)
				else:
					head.position.x = to
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
	# A piston's move under way is written now: its bricks are in no cell
	# while they slide.
	finish_moves()
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
