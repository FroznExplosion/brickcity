extends SceneTree

## Wiring stage 1 (Docs/MineWiring.md 3.3, 4, 10): cable tiles, nets, lever,
## lamp -- the rules, on a ground of the probe's own (no terrain baked).
##
##     godot --headless --path . --script res://tools/probes/wiring_probe.gd
##
## What each group is for:
##   nets      touching cables are one net; a gap makes two; a run climbs or
##             drops a step of up to a brick and no more; a lamp between two
##             runs does not join them (devices never conduct).
##   power     a lever on drives its net to 15, the lamp at the far end lights
##             one tick later; off, it goes dark; a lever right beside a lamp
##             lights it with no cable; a cut run leaves the far lamp dark.
##   ground    a cable needs air and ground under it; filling its cell or
##             taking the ground away breaks it (check); a device the same.
##   hits      a shot at a cable's spot cuts it; a blast clears its radius.
##   rebuild   a cable laid floods only the nets it touched, not all of them.
##   save      to_save / restore give the same cables, devices, lever state
##             and lit lamps back.
##   items     the base pack has the cable, lever and lamp items.
## Stage 2 (Docs/MineWiring.md 14):
##   sensors   a button is on for a second; a pressure tile while someone
##             stands on it (and a moment after); a trip string pairs two
##             hooks facing each other, powers both while crossed, and does
##             not pair through ground or between hooks facing the same way.
##   gates     NOT, AND, OR, XOR, latch, delay (exact ticks), pulse (exact
##             length) on their back/left/right inputs; output only out of the
##             front; a NOT feeding its own back is a clock, not a hang; an OR
##             is a one-way joint.
##   wrench    the readout names the net's level and a gate's facing and
##             inputs; turning a gate moves its output.
## Stage 3 (Docs/MineWiring.md 15):
##   door      fills 2 studs x 14 plates (no cable in it), opens with power
##             from a side and shuts when it goes, RMB by hand, is not turned
##             by the wrench, breaks when the ground under it goes.
##   trapdoor  held by ground beside it over a pit (not in mid-air), opens
##             with power from a lever a step up.
##   observer  an edit or a cable in the stud it watches gives 15 out of its
##             back for exactly 2 ticks, nothing at its side, nothing for an
##             edit elsewhere; a load is not a change.
## Stage 3b (Docs/MineWiring.md 16):
##   gate tile a stack and a row of gate tiles is one group: a lever at one
##             opens all (passable), off shuts all; not in mid-air, but beside
##             another; one apart is its own group.
##   sequencer program [5, 5, 5]: 5 on, 5 off, 5 on, then off though its back
##             stays on; RMB picks the next program; it is saved.
##   display   shows the level beside it: 15 with the lever on, 0 off.

var _pass := 0
var _fail := 0
## The probe's ground: plate cells that are solid. Flat at plate -1 and under,
## a raised step (3 plates, a brick) for x 20..25, z 3..9.
var _extra := {}
var _holes := {}
## Who stands where (feet, terrain frame): the sensors' bodies.
var _bodies: Array = []


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _solid(x: int, y: int, z: int) -> int:
	var c := Vector3i(x, y, z)
	if _holes.has(c):
		return 0
	if _extra.has(c):
		return 1
	if y < 0:
		return 1
	if x >= 20 and x < 26 and z >= 3 and z < 10 and y < 3:
		return 1
	return 0


func _init() -> void:
	var w := MineWiring.new()
	w.solid_fn = _solid
	w.bodies_fn = func() -> Array: return _bodies
	root.add_child(w)
	_nets(w)
	_power(w)
	_ground(w)
	_hits(w)
	_rebuild(w)
	_sensors(w)
	_gates(w)
	_wrench(w)
	_stage3(w)
	_stage3b(w)
	_save(w)
	_save2(w)
	_items()
	w.queue_free()
	print("WIRING-PROBE %s (%d ok, %d fail)" % ["PASS" if _fail == 0 else "FAIL", _pass, _fail])
	quit(0 if _fail == 0 else 1)


func _line(w: MineWiring, x0: int, x1: int, y: int, z: int) -> void:
	for x in range(x0, x1 + 1):
		w.place_cable(Vector3i(x, y, z))


func _nets(w: MineWiring) -> void:
	print("nets")
	w.clear()
	_line(w, 0, 5, 0, 0)
	w.tick()
	_ok("six touching cables are one net", w.nets.size() == 1 and w.nets.values()[0].cells.size() == 6)
	_line(w, 0, 5, 0, 2)
	w.tick()
	_ok("a run two studs away is a net of its own", w.nets.size() == 2)
	w.remove_cable(Vector3i(3, 0, 0))
	w.tick()
	_ok("a cable taken out of a run makes two nets", w.nets.size() == 3)
	# Climbing: x = 19 on the flat (plate 0), x = 20 on the step (plate 3).
	w.clear()
	w.place_cable(Vector3i(18, 0, 5))
	w.place_cable(Vector3i(19, 0, 5))
	w.place_cable(Vector3i(20, 3, 5))
	w.tick()
	_ok("a run climbs a brick's step", w.nets.size() == 1)
	w.clear()
	for y in 4:
		_extra[Vector3i(11, y, 5)] = true
	w.place_cable(Vector3i(10, 0, 5))
	w.place_cable(Vector3i(11, 4, 5))
	w.tick()
	_ok("but not a step of more than a brick", w.cables.size() == 2 and w.nets.size() == 2)
	_extra.clear()
	w.clear()
	_line(w, 0, 2, 0, 0)
	w.place_device(Vector3i(3, 0, 0), &"lamp")
	_line(w, 4, 6, 0, 0)
	w.tick()
	_ok("a lamp between two runs keeps them two nets", w.nets.size() == 2)


func _power(w: MineWiring) -> void:
	print("power")
	w.clear()
	var lever := Vector3i(-1, 0, 0)
	var lamp := Vector3i(8, 0, 0)
	w.place_device(lever, &"lever")
	_line(w, 0, 7, 0, 0)
	w.place_device(lamp, &"lamp")
	w.tick()
	_ok("lever off: the lamp is dark", not w.is_lit(lamp) and w.level_at(Vector3i(4, 0, 0)) == 0)
	w.use_device(lever)
	w.tick()
	_ok("lever on: the net is 15 and the lamp lit one tick later", w.is_lit(lamp)
			and w.level_at(Vector3i(4, 0, 0)) == MineWiring.LEVEL_MAX)
	_ok("RMB on a lamp does nothing", not w.use_device(lamp))
	w.use_device(lever)
	w.tick()
	_ok("lever off again: dark", not w.is_lit(lamp))
	w.use_device(lever)
	w.remove_cable(Vector3i(5, 0, 0))
	w.tick()
	_ok("a cut run leaves the far lamp dark", not w.is_lit(lamp) and w.level_at(Vector3i(2, 0, 0)) == 15)
	w.clear()
	w.place_device(Vector3i(0, 0, 3), &"lever", true)
	w.place_device(Vector3i(1, 0, 3), &"lamp")
	w.tick()
	_ok("a lever right beside a lamp lights it, no cable", w.is_lit(Vector3i(1, 0, 3)))
	# The lamp lights on the step's top, the run climbing to it.
	w.clear()
	w.place_device(Vector3i(17, 0, 8), &"lever", true)
	_line(w, 18, 19, 0, 8)
	w.place_cable(Vector3i(20, 3, 8))
	w.place_device(Vector3i(21, 3, 8), &"lamp")
	w.tick()
	_ok("power climbs the step to a lamp up there", w.is_lit(Vector3i(21, 3, 8)))


func _ground(w: MineWiring) -> void:
	print("ground")
	w.clear()
	_ok("no cable in mid-air", not w.place_cable(Vector3i(0, 4, 0)))
	_ok("no cable inside the ground", not w.place_cable(Vector3i(0, -1, 0)))
	_ok("a cable on the ground", w.place_cable(Vector3i(0, 0, 0)))
	_ok("not two in one cell", not w.place_cable(Vector3i(0, 0, 0)))
	_ok("no device on a cable", not w.place_device(Vector3i(0, 0, 0), &"lamp"))
	_ok("a lamp on the ground", w.place_device(Vector3i(2, 0, 0), &"lamp"))
	_ok("no cable inside a lamp's height", not w.place_cable(Vector3i(2, 1, 0)))
	_extra[Vector3i(0, 0, 0)] = true
	var gone := w.check(Vector3i(0, 0, 0), Vector3i(0, 0, 0))
	_ok("ground put into a cable's cell breaks it", gone == 1 and not w.cables.has(Vector3i(0, 0, 0)))
	_extra.clear()
	_holes[Vector3i(2, -1, 0)] = true
	w.check(Vector3i(2, -1, 0), Vector3i(2, -1, 0))
	_ok("the ground under a lamp gone: the lamp breaks", not w.devices.has(Vector3i(2, 0, 0)))
	_holes.clear()
	w.place_cable(Vector3i(5, 0, 0))
	_holes[Vector3i(5, -1, 0)] = true
	w.check(Vector3i(40, -1, 40), Vector3i(41, -1, 41))
	_ok("a check of a box far away leaves it alone", w.cables.has(Vector3i(5, 0, 0)))
	w.check()
	_ok("a whole check finds it", not w.cables.has(Vector3i(5, 0, 0)))
	_holes.clear()


func _hits(w: MineWiring) -> void:
	print("hits")
	w.clear()
	_line(w, 0, 9, 0, 0)
	w.tick()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# The bullet hits the ground's top under the cable: y = 0.
	_ok("a shot at a cable's spot cuts it", w.shot(Vector3(4.5 * stud, 0.0, 0.5 * stud))
			and not w.cables.has(Vector3i(4, 0, 0)))
	_ok("a shot beside the run hits nothing", not w.shot(Vector3(4.5 * stud, 0.0, 3.5 * stud)))
	w.tick()
	_ok("the cut made two nets", w.nets.size() == 2)
	var n := w.blast(Vector3(8.5 * stud, plate, 0.5 * stud), stud * 1.2)
	_ok("a blast clears what is in its radius (%d)" % n, n >= 2 and not w.cables.has(Vector3i(8, 0, 0))
			and w.cables.has(Vector3i(0, 0, 0)))


func _rebuild(w: MineWiring) -> void:
	print("rebuild")
	w.clear()
	for z in 10:
		_line(w, 0, 17, 0, z * 2)
	w.tick()
	_ok("ten runs, ten nets", w.nets.size() == 10)
	_ok("one cable laid", w.place_cable(Vector3i(18, 0, 0)))
	w.tick()
	_ok("and it floods only its own net (%d cells, not 181)" % w.last_flooded, w.last_flooded == 19)


func _save(w: MineWiring) -> void:
	print("save")
	w.clear()
	w.place_device(Vector3i(-1, 0, 0), &"lever", true)
	_line(w, 0, 4, 0, 0)
	w.place_device(Vector3i(5, 0, 0), &"lamp")
	w.place_device(Vector3i(0, 0, 4), &"lever", false)
	w.tick()
	var saved: Variant = JSON.parse_string(JSON.stringify(w.to_save()))
	var w2 := MineWiring.new()
	w2.solid_fn = _solid
	root.add_child(w2)
	w2.restore(saved)
	_ok("restored: 5 cables, 3 devices", w2.cables.size() == 5 and w2.devices.size() == 3)
	_ok("restored: the lever on, the lamp lit", bool(w2.devices[Vector3i(-1, 0, 0)].on) and w2.is_lit(Vector3i(5, 0, 0)))
	_ok("restored: the other lever off", not bool(w2.devices[Vector3i(0, 0, 4)].on))
	w2.queue_free()


func _ticks(w: MineWiring, n: int) -> void:
	for i in n:
		w.tick()


func _sensors(w: MineWiring) -> void:
	print("sensors")
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	w.clear()
	w.place_device(Vector3i(0, 0, 30), &"button")
	w.place_device(Vector3i(1, 0, 30), &"lamp")
	w.tick()
	_ok("button: dark before", not w.is_lit(Vector3i(1, 0, 30)))
	w.use_device(Vector3i(0, 0, 30))
	w.tick()
	_ok("pressed: the lamp lit", w.is_lit(Vector3i(1, 0, 30)))
	var on := 1
	for i in 15:
		w.tick()
		if w.is_lit(Vector3i(1, 0, 30)):
			on += 1
	_ok("on for a second, then off (%d ticks)" % on, on == MineWiring.BUTTON_TICKS and not w.is_lit(Vector3i(1, 0, 30)))
	# Pressure tile.
	w.clear()
	_ok("a pressure tile on the ground", w.place_device(Vector3i(0, 0, 20), &"pressure_tile"))
	_ok("no cable on top of a pressure tile (a device is not ground)", not w.place_cable(Vector3i(0, 1, 20)))
	w.place_device(Vector3i(1, 0, 20), &"lamp")
	_bodies = [Vector3(0.5 * stud, plate, 20.5 * stud)]
	w.tick()
	_ok("someone on the tile: the lamp lit", w.is_lit(Vector3i(1, 0, 20)))
	_bodies = [Vector3(5.5 * stud, 0.0, 20.5 * stud)]
	w.tick()
	_ok("stepped off: still lit a moment", w.is_lit(Vector3i(1, 0, 20)))
	_ticks(w, MineWiring.SENSOR_HOLD + 1)
	_ok("then dark", not w.is_lit(Vector3i(1, 0, 20)))
	_bodies = [Vector3(0.5 * stud, plate + 1.5, 20.5 * stud)]
	_ticks(w, 2)
	_ok("someone flying over it does not press it", not w.is_lit(Vector3i(1, 0, 20)))
	_bodies = []
	# Trip string.
	w.clear()
	var a := Vector3i(0, 0, 10)
	var b := Vector3i(8, 0, 10)
	w.place_device(a, &"trip_hook", false, false, 0)
	w.place_device(b, &"trip_hook", false, false, 1)
	w.place_device(Vector3i(0, 0, 11), &"lamp")
	w.tick()
	_ok("two hooks facing each other 8 studs apart pair", w.pairs.get(a, Vector3i.ZERO) == b and w.pairs.get(b, Vector3i.ZERO) == a)
	_ok("nobody there: dark", not w.is_lit(Vector3i(0, 0, 11)))
	_bodies = [Vector3(4.5 * stud, 0.0, 10.5 * stud)]
	w.tick()
	_ok("someone across the string: both hooks on, the lamp lit", w.is_lit(Vector3i(0, 0, 11))
			and w.output_of(a) == 15 and w.output_of(b) == 15)
	_bodies = [Vector3(4.5 * stud, 0.0, 14.5 * stud)]
	_ticks(w, MineWiring.SENSOR_HOLD + 1)
	_ok("walked past: dark again", not w.is_lit(Vector3i(0, 0, 11)))
	_bodies = [Vector3(4.5 * stud, 3.0, 10.5 * stud)]
	_ticks(w, 2)
	_ok("someone far over the string does not trip it", not w.is_lit(Vector3i(0, 0, 11)))
	_bodies = []
	_extra[Vector3i(4, 1, 10)] = true
	w.check()
	w.tick()
	_ok("ground put across the line: no string", not w.pairs.has(a))
	_extra.clear()
	w.check()
	w.tick()
	_ok("taken away: the string again", w.pairs.has(a))
	w.use_device(b, "turn")
	w.tick()
	_ok("one hook turned away: no string", not w.pairs.has(a))
	w.clear()
	w.place_device(Vector3i(0, 0, 10), &"trip_hook", false, false, 0)
	w.place_device(Vector3i(13, 0, 10), &"trip_hook", false, false, 1)
	w.tick()
	_ok("13 studs apart: too far", w.pairs.is_empty())


## A gate at `g` facing +x, levers or lamps round it.
func _gates(w: MineWiring) -> void:
	print("gates")
	# NOT: lever -> cable -> NOT -> lamp; a lamp at the gate's left stays dark.
	w.clear()
	var lever := Vector3i(8, 0, 0)
	w.place_device(lever, &"lever")
	w.place_cable(Vector3i(9, 0, 0))
	var g := Vector3i(10, 0, 0)
	w.place_device(g, &"not_gate", false, false, 0)
	w.place_device(Vector3i(11, 0, 0), &"lamp")
	w.place_device(Vector3i(10, 0, -1), &"lamp")
	_ticks(w, 2)
	_ok("NOT: lever off, the lamp at its front lit", w.is_lit(Vector3i(11, 0, 0)))
	_ok("but not the lamp at its side (output only out of the front)", not w.is_lit(Vector3i(10, 0, -1)))
	w.use_device(lever)
	_ticks(w, 2)
	_ok("NOT: lever on, dark", not w.is_lit(Vector3i(11, 0, 0)))
	w.use_device(g, "turn")
	w.use_device(lever)
	_ticks(w, 3)
	_ok("turned to face +z: its output moved off the old lamp", not w.is_lit(Vector3i(11, 0, 0))
			and int(w.devices[g].facing) == 2)
	# Two-input gates: levers at the left (-z) and right (+z) of a gate facing +x.
	for t in [["and_gate", [false, true, false, false]], ["or_gate", [false, true, true, true]],
			["xor_gate", [false, false, true, true]]]:
		w.clear()
		var gg := Vector3i(20, 0, 0)
		var left := Vector3i(20, 0, -1)
		var right := Vector3i(20, 0, 1)
		w.place_device(gg, StringName(t[0]), false, false, 0)
		w.place_device(left, &"lever")
		w.place_device(right, &"lever")
		w.place_device(Vector3i(21, 0, 0), &"lamp")
		var want: Array = t[1]
		var got: Array = []
		# both on, both off, left only, right only
		for case in [[true, true], [false, false], [true, false], [false, true]]:
			w.devices[left].on = case[0]
			w.devices[right].on = case[1]
			_ticks(w, 3)
			got.append(w.is_lit(Vector3i(21, 0, 0)))
		# want is [off/off? ...] reorder to the cases' order
		var expect: Array = [want[1], want[0], want[2], want[3]]
		_ok("%s: both on %s, both off %s, left %s, right %s" % [t[0], got[0], got[1], got[2], got[3]], got == expect)
	# Latch: left sets, right resets, it remembers.
	w.clear()
	var lg := Vector3i(40, 0, 0)
	w.place_device(lg, &"latch", false, false, 0)
	w.place_device(Vector3i(40, 0, -1), &"button")
	w.place_device(Vector3i(40, 0, 1), &"button")
	w.place_device(Vector3i(41, 0, 0), &"lamp")
	_ticks(w, 2)
	_ok("latch: dark at first", not w.is_lit(Vector3i(41, 0, 0)))
	w.use_device(Vector3i(40, 0, -1))
	_ticks(w, 15)
	_ok("set by the left, remembered after the button is off", w.is_lit(Vector3i(41, 0, 0)))
	w.use_device(Vector3i(40, 0, 1))
	_ticks(w, 15)
	_ok("reset by the right", not w.is_lit(Vector3i(41, 0, 0)))
	# Delay of 3 ticks.
	w.clear()
	var dg := Vector3i(50, 0, 0)
	w.place_device(Vector3i(49, 0, 0), &"lever")
	w.place_device(dg, &"delay", false, false, 0, 3)
	_ticks(w, 2)
	w.use_device(Vector3i(49, 0, 0))
	var first := -1
	for i in 10:
		w.tick()
		if first < 0 and w.output_of(dg) > 0:
			first = i + 1
	_ok("delay 3: the output turns on in the 4th tick (3 + its own) -- %d" % first, first == 4)
	w.use_device(dg)
	_ok("RMB steps it: 4", int(w.devices[dg].setting) == 4)
	# Pulse of 5 ticks.
	w.clear()
	var pg := Vector3i(60, 0, 0)
	w.place_device(Vector3i(59, 0, 0), &"lever")
	w.place_device(pg, &"pulse", false, false, 0, 5)
	_ticks(w, 2)
	w.use_device(Vector3i(59, 0, 0))
	var n_on := 0
	for i in 20:
		w.tick()
		if w.output_of(pg) > 0:
			n_on += 1
	_ok("pulse 5: on for exactly 5 ticks though its back stays on (%d)" % n_on, n_on == 5)
	# A clock: a NOT whose front cable runs round to its back.
	w.clear()
	var cg := Vector3i(70, 0, 0)
	w.place_device(cg, &"not_gate", false, false, 0)
	for c in [Vector3i(71, 0, 0), Vector3i(71, 0, 2), Vector3i(71, 0, 1), Vector3i(70, 0, 2),
			Vector3i(69, 0, 2), Vector3i(69, 0, 1), Vector3i(69, 0, 0)]:
		w.place_cable(c)
	var flips := 0
	var last := w.output_of(cg)
	for i in 20:
		w.tick()
		if w.output_of(cg) != last:
			flips += 1
			last = w.output_of(cg)
	_ok("a NOT feeding its own back is a clock (%d flips in 20 ticks)" % flips, flips >= 8)
	# An OR is a one-way joint: a lever at its front does not reach its back.
	w.clear()
	w.place_device(Vector3i(80, 0, 0), &"or_gate", false, false, 0)
	w.place_device(Vector3i(81, 0, 0), &"lever", true)
	w.place_device(Vector3i(79, 0, 0), &"lamp")
	_ticks(w, 3)
	_ok("a lever at an OR's front does not light the lamp at its back", not w.is_lit(Vector3i(79, 0, 0)))


func _wrench(w: MineWiring) -> void:
	print("wrench")
	w.clear()
	w.place_device(Vector3i(-1, 0, 0), &"lever", true)
	_line(w, 0, 3, 0, 0)
	w.place_device(Vector3i(4, 0, 0), &"and_gate", false, false, 0)
	_ticks(w, 2)
	var t := w.readout({"cable": Vector3i(1, 0, 0)})
	_ok("cable readout: level, cables, devices (%s)" % t, t.contains("level 15") and t.contains("4 wires")
			and t.contains("2 devices"))
	var gt := w.readout({"device": Vector3i(4, 0, 0)})
	_ok("gate readout: facing and inputs (%s)" % gt, gt.contains("faces +x") and gt.contains("back 15"))
	_ok("nothing looked at: no readout", w.readout({}) == "")


func _stage3(w: MineWiring) -> void:
	print("doors and observers")
	w.clear()
	var door := Vector3i(0, 0, 50)
	_ok("a door on the ground", w.place_device(door, &"door", false, false, 0))
	_ok("it fills its second stud to its top", w._device_at(Vector3i(0, 13, 51)) == door
			and w._device_at(Vector3i(0, 14, 51)) == null)
	_ok("no cable inside it", not w.place_cable(Vector3i(0, 0, 51)))
	w.place_device(Vector3i(-1, 0, 50), &"lever")
	w.tick()
	_ok("shut while nothing powers it", not w.is_open(door))
	w.use_device(Vector3i(-1, 0, 50))
	w.tick()
	_ok("the lever on: open", w.is_open(door))
	w.use_device(Vector3i(-1, 0, 50))
	w.tick()
	_ok("the lever off: shut", not w.is_open(door))
	_ok("RMB opens it by hand", w.use_device(door) and w.is_open(door))
	w.tick()
	_ok("and it stays open with no power change", w.is_open(door))
	_ok("the wrench does not turn a door", not w.use_device(door, "turn"))
	_holes[Vector3i(0, -1, 51)] = true
	w.check(Vector3i(0, -1, 51), Vector3i(0, -1, 51))
	_ok("the ground under its second stud gone: it breaks", not w.devices.has(door)
			and w._device_at(Vector3i(0, 5, 50)) == null)
	_holes.clear()
	# Trapdoor over a pit 4 plates deep.
	w.clear()
	for x in [10, 11]:
		for z in [50, 51]:
			for y in range(-4, 0):
				_holes[Vector3i(x, y, z)] = true
	var trap := Vector3i(10, -1, 50)
	_ok("no trapdoor in mid-air", not w.place_device(Vector3i(30, 3, 50), &"trapdoor", false, false, 0))
	_ok("a trapdoor over the pit, held by the ground beside it", w.place_device(trap, &"trapdoor", false, false, 0))
	w.place_device(Vector3i(12, 0, 50), &"lever")
	w.tick()
	_ok("shut", not w.is_open(trap))
	w.use_device(Vector3i(12, 0, 50))
	w.tick()
	_ok("a lever a step up beside it: open", w.is_open(trap))
	_holes.clear()
	# Observer: watches (21, 0..2, 50), its back at 19.
	w.clear()
	var ob := Vector3i(20, 0, 50)
	w.place_device(ob, &"observer", false, false, 0)
	w.place_device(Vector3i(19, 0, 50), &"lamp")
	w.place_device(Vector3i(20, 0, 51), &"lamp")
	_ticks(w, 3)
	_ok("nothing changed: dark", not w.is_lit(Vector3i(19, 0, 50)))
	_extra[Vector3i(21, 0, 50)] = true
	w.check(Vector3i(21, 0, 50), Vector3i(21, 0, 50))
	var lit := 0
	var side := false
	for i in 6:
		w.tick()
		if w.is_lit(Vector3i(19, 0, 50)):
			lit += 1
		side = side or w.is_lit(Vector3i(20, 0, 51))
	_ok("ground put in the stud it watches: its back lit for exactly 2 ticks (%d)" % lit, lit == 2)
	_ok("nothing out of its side", not side)
	_extra.clear()
	w.check(Vector3i(21, 0, 50), Vector3i(21, 0, 50))
	_ticks(w, 4)
	w.check(Vector3i(25, 0, 50), Vector3i(25, 0, 50))
	w.tick()
	_ok("an edit elsewhere: nothing", not w.is_lit(Vector3i(19, 0, 50)))
	w.place_cable(Vector3i(21, 0, 50))
	w.tick()
	_ok("a cable laid in front of it: a pulse", w.is_lit(Vector3i(19, 0, 50)))
	_ticks(w, 4)
	var saved: Variant = JSON.parse_string(JSON.stringify(w.to_save()))
	var w2 := MineWiring.new()
	w2.solid_fn = _solid
	root.add_child(w2)
	w2.restore(saved)
	_ticks(w2, 2)
	_ok("loaded again: the observer faces +x and does not fire for the load", int(w2.devices[ob].facing) == 0
			and not w2.is_lit(Vector3i(19, 0, 50)))
	w2.queue_free()


func _stage3b(w: MineWiring) -> void:
	print("gate tiles, sequencer, number display")
	w.clear()
	var lever := Vector3i(-1, 0, 60)
	w.place_device(lever, &"lever")
	var tiles: Array[Vector3i] = [Vector3i(0, 0, 60), Vector3i(0, 3, 60), Vector3i(1, 0, 60), Vector3i(1, 3, 60), Vector3i(2, 3, 60)]
	var all_in := true
	for t in tiles:
		all_in = all_in and w.place_device(t, &"gate_tile")
	_ok("gate tiles: on ground, stacked, and one held only beside another", all_in)
	_ok("not in mid-air", not w.place_device(Vector3i(6, 4, 60), &"gate_tile"))
	w.place_device(Vector3i(4, 0, 60), &"gate_tile")
	w.tick()
	var shut := true
	for t in tiles:
		shut = shut and not w.is_open(t)
	_ok("unpowered: all solid", shut)
	w.use_device(lever)
	w.tick()
	var open := true
	for t in tiles:
		open = open and w.is_open(t)
	_ok("a lever at one: the whole group open", open)
	_ok("a tile one stud apart is its own group: still solid", not w.is_open(Vector3i(4, 0, 60)))
	w.use_device(lever)
	w.tick()
	_ok("the lever off: all solid again", not w.is_open(Vector3i(2, 3, 60)))
	# Sequencer [5, 5, 5].
	w.clear()
	var sq := Vector3i(10, 0, 60)
	w.place_device(Vector3i(9, 0, 60), &"lever")
	w.place_device(sq, &"sequencer", false, false, 0, 0)
	_ticks(w, 2)
	w.use_device(Vector3i(9, 0, 60))
	var pattern := ""
	for i in 20:
		w.tick()
		pattern += "1" if w.output_of(sq) > 0 else "0"
	_ok("program 5 on, 5 off, 5 on, then off with its back still on (%s)" % pattern,
			pattern == "11111000001111100000")
	w.use_device(sq)
	_ok("RMB picks the next program", int(w.devices[sq].setting) == 1)
	var saved: Variant = JSON.parse_string(JSON.stringify(w.to_save()))
	var w2 := MineWiring.new()
	w2.solid_fn = _solid
	root.add_child(w2)
	w2.restore(saved)
	_ok("its program comes back", int(w2.devices[sq].setting) == 1)
	w2.queue_free()
	# Number display.
	w.clear()
	var disp := Vector3i(20, 0, 60)
	w.place_device(Vector3i(19, 0, 60), &"lever")
	w.place_device(disp, &"number_display", false, false, 0)
	w.tick()
	_ok("display: 0 with the lever off", w.output_of(disp) == 0)
	w.use_device(Vector3i(19, 0, 60))
	w.tick()
	_ok("15 with it on", w.output_of(disp) == 15)
	var lab := (w.devices[disp].node as Node3D).get_node("Turn/Number") as Label3D
	_ok("printed on its front: \"%s\"" % lab.text, lab.text == "15")
	_ok("and it drives nothing (a lamp beside it stays dark)", w.place_device(Vector3i(20, 0, 62), &"lamp")
			and _tick_lit(w, Vector3i(20, 0, 62)) == false)


func _tick_lit(w: MineWiring, c: Vector3i) -> bool:
	w.tick()
	return w.is_lit(c)


func _save2(w: MineWiring) -> void:
	print("save (stage 2)")
	w.clear()
	w.place_device(Vector3i(0, 0, 0), &"delay", false, false, 2, 7)
	w.place_device(Vector3i(3, 0, 0), &"trip_hook", false, false, 3)
	var saved: Variant = JSON.parse_string(JSON.stringify(w.to_save()))
	var w2 := MineWiring.new()
	w2.solid_fn = _solid
	root.add_child(w2)
	w2.restore(saved)
	_ok("a delay's facing and ticks, a hook's facing come back", int(w2.devices[Vector3i(0, 0, 0)].facing) == 2
			and int(w2.devices[Vector3i(0, 0, 0)].setting) == 7 and int(w2.devices[Vector3i(3, 0, 0)].facing) == 3)
	w2.queue_free()


func _items() -> void:
	print("items")
	ItemCatalog.load_all(true)
	_ok("cable, lever, lamp are items", ItemCatalog.has(&"cable") and ItemCatalog.has(&"lever") and ItemCatalog.has(&"lamp"))
	var every := true
	for id in MineWiring.DEVICES:
		every = every and ItemCatalog.has(id) and ItemCatalog.kind(id) == "device"
	_ok("every device is an item of kind device, and the wrench", every and ItemCatalog.kind(&"wrench") == "wrench")
	_ok("in game it is called Wire, and the ore Wire ore (names decided 2026-11-26)", str(ItemCatalog.get_def(&"cable").name) == "Wire"
			and ItemCatalog.has(&"redstone_ore") and str(ItemCatalog.get_def(&"redstone_ore").name) == "Wire ore")
	_ok("their kinds: wire, device", ItemCatalog.kind(&"cable") == "wire" and ItemCatalog.kind(&"lever") == "device")
	for id in [&"cable", &"lever", &"lamp", &"button", &"pressure_tile", &"trip_hook", &"and_gate", &"wrench"]:
		var m := ItemIcons._model(ItemCatalog.get_def(id))
		_ok("%s has a model" % id, m != null and m.get_child(0).get_child_count() >= 2)
		m.free()
