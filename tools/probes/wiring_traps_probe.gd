extends SceneTree

## Wiring stages 5-6, the traps kit (Docs/MineWiring.md 19): dispenser,
## dropper, release brick, alarm -- the rules, on a ground of the probe's own
## (flat, solid under plate 0; no terrain baked, no weapon system, no
## creatures: what those do is --gate=wiring's, in the real world).
##
##     godot --headless --path . --script res://tools/probes/wiring_traps_probe.gd
##
## What each group is for:
##   dispenser  power turning on at its back fires ONE item, the first slot's;
##              held on, nothing more; from its front, nothing; a grenade is
##              thrown 17 studs out onto the ground, or short of a wall; a
##              bucket pours a brick in front (3 tiles out of 9); a gun stays
##              in its slot; an arrow is shot, one a turn-on; an empty one
##              fires nothing; other things are launched (items still).
##   dropper    drops even a grenade or an arrow (never shoots); RMB opens its slots.
##   release    sits on the brick courses (snap); laid into the ground (its
##              cells solid, one edit); powered it lets go (cells air) and
##              stays let go RELEASE_HOLD ticks after the power goes, then
##              grips again -- not while someone stands in it; shot out while
##              holding, it is gone; taken, its cells go too; not in mid-air.
##   alarm      powered it sounds and calls once, again every ALARM_AGAIN
##              ticks while on, quiet when the power goes.
##   save       a dispenser's slots and a let-go release brick come back.
##   items      the four are device items with models; the wiring guide lists
##              every device and every part in it is an item.
## Sensors and the counter (Docs/MineWiring.md 28):
##   motion     a body in front within its reach: 15 (and lights a lamp beside
##              it); behind it, beside the box, past its reach or past a wall:
##              nothing; RMB's longer reach sees farther; it holds 5 ticks.
##   light      sky x daylight (15 open at noon, 0 at night, 8 half-roofed);
##              RMB makes it a night sensor (15 minus).
##   fluid      water 2 tiles in front: 10; watching lava only: 0; lava 3: 15.
##   counter    N = 3 by default: the third turn-on at its back pulses 15 out
##              of its front for 5 ticks; its right side resets the count;
##              RMB steps N; count and N saved.

var _pass := 0
var _fail := 0
var _extra := {}
var _holes := {}
var _bodies: Array = []
var _edits: Array = []
var _w: MineWiring = null
var _sky := 15
var _day := 1.0
var _fluid := {}


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
	return 1 if y < 0 else 0


## The ground edit a release brick makes, then the check terrain_edited runs.
func _edit(lo: Vector3i, hi: Vector3i, mat: int) -> void:
	_edits.append([lo, hi, mat])
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				var c := Vector3i(x, y, z)
				if mat == 0:
					_extra.erase(c)
					if y < 0:
						_holes[c] = true
				else:
					_holes.erase(c)
					_extra[c] = true
	_w.check(lo, hi)


func _init() -> void:
	ItemCatalog.load_all(true)
	_w = MineWiring.new()
	_w.solid_fn = _solid
	_w.bodies_fn = func() -> Array: return _bodies
	WiringTraps.edit_fn = _edit
	root.add_child(_w)
	_dispenser(_w)
	_dropper(_w)
	_release(_w)
	_alarm(_w)
	_sensors(_w)
	_save(_w)
	_items()
	WiringTraps.edit_fn = Callable()
	WiringTraps.light_fn = Callable()
	WiringTraps.day_fn = Callable()
	WiringTraps.fluid_fn = Callable()
	_w.queue_free()
	print("WIRING-TRAPS-PROBE %s (%d ok, %d fail)" % ["PASS" if _fail == 0 else "FAIL", _pass, _fail])
	quit(0 if _fail == 0 else 1)


func _ticks(w: MineWiring, n: int) -> void:
	for i in n:
		w.tick()


func _lever(w: MineWiring, c: Vector3i, on: bool) -> void:
	if bool(w.devices[c].on) != on:
		w.use_device(c)


func _dispenser(w: MineWiring) -> void:
	print("dispenser")
	w.clear()
	var c := Vector3i(0, 0, 0)
	_ok("a dispenser is placed facing +x", w.place_device(c, &"dispenser", false, false, 0))
	var d: Dictionary = w.devices[c]
	_ok("it has 9 empty slots", d.slots.size() == 9 and d.slots.count(null) == 9)
	d.slots[0] = ItemStack.make(&"grenade", 2)
	d.slots[2] = ItemStack.make(&"cable", 3)
	var lv := Vector3i(-1, 0, 0)
	w.place_device(lv, &"lever")
	_ticks(w, 2)
	_ok("nothing fired before the power", int(d.get("fired", 0)) == 0)
	_lever(w, lv, true)
	_ticks(w, 1)
	_ok("the lever at its back turning on fires once, a grenade (%s)" % d.get("last", ""),
			int(d.get("fired", 0)) == 1 and str(d.get("last", "")) == "grenade grenade" and d.slots[0].count == 1)
	_ok("thrown 17 studs out onto the ground (%s)" % d.get("grenade_to"), d.get("grenade_to") == Vector3i(17, 0, 0))
	_ticks(w, 6)
	_ok("held on, nothing more", int(d.fired) == 1)
	_lever(w, lv, false)
	_ticks(w, 2)
	_extra[Vector3i(5, 1, 0)] = true
	_lever(w, lv, true)
	_ticks(w, 2)
	_ok("on again: the second grenade, short of the wall at 5 (%s)" % d.get("grenade_to"),
			int(d.fired) == 2 and d.slots[0] == null and d.get("grenade_to") == Vector3i(4, 0, 0))
	_extra.erase(Vector3i(5, 1, 0))
	_lever(w, lv, false)
	_ticks(w, 2)
	_lever(w, lv, true)
	_ticks(w, 2)
	_ok("then the next slot's: a wire is LAUNCHED, an item still (%s)" % d.last, str(d.last) == "launch cable" and d.slots[2].count == 2)
	_lever(w, lv, false)
	_ticks(w, 2)
	# From the front: nothing.
	w.remove_device(lv, false)
	var front := Vector3i(1, 0, 0)
	w.place_device(front, &"lever")
	_lever(w, front, true)
	_ticks(w, 3)
	_ok("a lever at its FRONT fires nothing", int(d.fired) == 3)
	w.remove_device(front, false)
	w.place_device(lv, &"lever")
	# Arrows: shot, one used a turn-on.
	d.slots[2] = null
	d.slots[1] = ItemStack.make(&"arrow", 3)
	_lever(w, lv, true)
	_ticks(w, 2)
	_ok("arrows: one shot (%s), 2 left" % d.last, str(d.last) == "arrow arrow" and d.slots[1].count == 2)
	_lever(w, lv, false)
	_ticks(w, 2)
	d.slots[1] = null
	# A bucket: a brick of water in front.
	d.slots[1] = ItemStack.make(&"bucket", 1, {"tiles": 9})
	_lever(w, lv, true)
	_ticks(w, 2)
	_ok("a bucket pours 3 of its 9 tiles into the stud in front (%s)" % d.get("poured"),
			str(d.last) == "bucket bucket" and int(d.slots[1].data.tiles) == 6 and d.get("poured") == Vector3i(1, 0, 0))
	_lever(w, lv, false)
	_ticks(w, 2)
	# A gun stays in its slot.
	var gun_id := StringName()
	for id in ItemCatalog.ids():
		if ItemCatalog.kind(id) == "gun":
			gun_id = id
			break
	d.slots[1] = null
	if gun_id != &"":
		d.slots[0] = ItemStack.make(gun_id, 1, {"class": "pistol"})
		_lever(w, lv, true)
		_ticks(w, 2)
		_ok("a gun fires (%s) and stays in its slot" % d.last, str(d.last).begins_with("gun ") and d.slots[0] != null)
		_lever(w, lv, false)
		_ticks(w, 2)
		d.slots[0] = null
	else:
		_ok("a gun item exists to test with", false)
	_lever(w, lv, true)
	_ticks(w, 2)
	_ok("empty, it fires nothing", str(d.last) == "empty")
	_ok("the wrench readout counts its items and its last shot", w.readout({"device": c}).contains("0 items")
			and w.readout({"device": c}).contains("last: empty"))
	_ok("the wrench turns it", w.use_device(c, "turn") and int(d.facing) == WiringTraps.SIDES.find(Vector3i(0, 0, 1)))


func _dropper(w: MineWiring) -> void:
	print("dropper")
	w.clear()
	var c := Vector3i(0, 0, 0)
	w.place_device(c, &"dropper", false, false, 2)
	var d: Dictionary = w.devices[c]
	d.slots[4] = ItemStack.make(&"grenade", 1)
	w.place_device(Vector3i(1, 0, 0), &"lever")
	_lever(w, Vector3i(1, 0, 0), true)
	_ticks(w, 2)
	_ok("a dropper drops even a grenade (%s)" % d.get("last", ""), str(d.get("last", "")) == "drop grenade" and d.slots[4] == null)
	d.slots[5] = ItemStack.make(&"arrow", 1)
	_lever(w, Vector3i(1, 0, 0), false)
	_ticks(w, 2)
	_lever(w, Vector3i(1, 0, 0), true)
	_ticks(w, 2)
	_ok("and an arrow as a pickup, not shot (%s)" % d.get("last", ""), str(d.get("last", "")) == "drop arrow")
	_ok("RMB opens its slots", w.use_device(c) and int(d.get("opened", 0)) == 1)


func _release(w: MineWiring) -> void:
	print("release brick")
	w.clear()
	_extra.clear()
	_holes.clear()
	_edits.clear()
	var c := Vector3i(10, 0, 0)
	_ok("not in mid-air", not w.can_place_device(Vector3i(30, 7, 0), &"release_brick"))
	_extra[Vector3i(31, 7, 0)] = true
	_ok("beside a solid stud, yes", w.can_place_device(Vector3i(30, 7, 0), &"release_brick"))
	_extra.erase(Vector3i(31, 7, 0))
	_ok("placed on the ground", w.place_device(Vector3i(10, 1, 0), &"release_brick"))
	_ok("on the brick courses: plate 1 snaps to 0", w.devices.has(c) and not w.devices.has(Vector3i(10, 1, 0)))
	var d: Dictionary = w.devices[c]
	_ok("laid at the end of the tick, not at once", not _w._solid(c) and bool(d.get("pending", false)))
	_ticks(w, 1)
	_ok("its 3 cells are ground now, one edit, a building colour (%s)" % [_edits],
			_solid(10, 0, 0) == 1 and _solid(10, 2, 0) == 1 and _edits.size() == 1
			and int(_edits[0][2]) >= ItemCatalog.BUILDING_MATERIAL_BASE and not d.has("pending"))
	_ok("the ground's check leaves it (its cells are solid on purpose)", w.devices.has(c))
	var lv := Vector3i(9, 0, 0)
	w.place_device(lv, &"lever")
	_lever(w, lv, true)
	_ticks(w, 1)
	_ok("powered, it lets go: its cells are air", bool(d.on) and _solid(10, 0, 0) == 0 and _solid(10, 2, 0) == 0)
	_ok("and it is still there (let go is not broken)", w.devices.has(c))
	_ok("the readout says so", w.readout({"device": c}).contains("let go"))
	_lever(w, lv, false)
	_ticks(w, WiringTraps.RELEASE_HOLD - 1)
	_ok("power off: still let go %d ticks later" % (WiringTraps.RELEASE_HOLD - 1), bool(d.on) and _solid(10, 0, 0) == 0)
	_ticks(w, 2)
	_ok("then it grips again (cells solid)", not bool(d.on) and _solid(10, 1, 0) == 1)
	# Someone standing in it: it waits.
	_lever(w, lv, true)
	_ticks(w, 1)
	_lever(w, lv, false)
	_bodies = [Vector3(10.5 * 0.35, 0.0, 0.5 * 0.35)]
	_ticks(w, WiringTraps.RELEASE_HOLD + 5)
	_ok("not while someone stands in it", bool(d.on) and _solid(10, 0, 0) == 0)
	_bodies = []
	_ticks(w, 12)
	_ok("they step out: it grips", not bool(d.on) and _solid(10, 0, 0) == 1)
	# Shot out while holding.
	_holes[Vector3i(10, 1, 0)] = true
	w.check(Vector3i(10, 1, 0), Vector3i(10, 1, 0))
	_ok("a cell shot out while it holds: it is gone", not w.devices.has(c))
	_holes.clear()
	# Taken: its cells go with it.
	w.place_device(c, &"release_brick")
	_ticks(w, 1)
	w.remove_device(c, false)
	_ticks(w, 1)
	_ok("taken: its cells go too", _solid(10, 0, 0) == 0 and _solid(10, 2, 0) == 0)
	# A stack: one on another is held.
	w.place_device(c, &"release_brick")
	_ticks(w, 1)
	_ok("one on top of another is held", w.place_device(c + Vector3i(0, 3, 0), &"release_brick"))


func _alarm(w: MineWiring) -> void:
	print("alarm")
	w.clear()
	var c := Vector3i(20, 0, 0)
	w.place_device(c, &"alarm")
	var d: Dictionary = w.devices[c]
	var lv := Vector3i(19, 0, 0)
	w.place_device(lv, &"lever")
	_ticks(w, 2)
	_ok("quiet unpowered", not bool(d.on) and int(d.get("calls", 0)) == 0)
	_lever(w, lv, true)
	_ticks(w, 1)
	_ok("powered: it sounds and calls once", bool(d.on) and int(d.get("calls", 0)) == 1)
	_ticks(w, WiringTraps.ALARM_AGAIN + 1)
	_ok("and again %d ticks later while on (%d calls)" % [WiringTraps.ALARM_AGAIN, int(d.calls)], int(d.calls) == 2)
	_lever(w, lv, false)
	_ticks(w, 1)
	_ok("quiet when the power goes", not bool(d.on) and int(d.out) == 0)
	_ticks(w, WiringTraps.ALARM_AGAIN + 2)
	_ok("and calls no more", int(d.calls) == 2)


func _feet(x: float, z: float) -> Vector3:
	return Vector3((x + 0.5) * 0.35, 0.0, (z + 0.5) * 0.35)


func _sensors(w: MineWiring) -> void:
	print("sensors")
	w.clear()
	_extra.clear()
	_holes.clear()
	_bodies = []
	# Motion sensor at the origin facing +x, a lamp beside it.
	var m := Vector3i(0, 0, 0)
	_ok("a motion sensor is placed facing +x", w.place_device(m, &"motion_sensor", false, false, 0))
	var lamp := Vector3i(0, 0, 1)
	w.place_device(lamp, &"lamp")
	_ticks(w, 3)
	_ok("nobody there: 0", w.output_of(m) == 0)
	_bodies = [_feet(3, 0)]
	_ticks(w, 2)
	_ok("someone 3 studs in front: 15", w.output_of(m) == 15)
	_ticks(w, 1)
	_ok("and the lamp beside it lights", w.is_lit(lamp))
	_bodies = [_feet(-3, 0)]
	_ticks(w, 4)
	_ok("still on for its hold after they leave", w.output_of(m) == 15)
	_ticks(w, 4)
	_ok("someone BEHIND it: nothing (after the hold)", w.output_of(m) == 0)
	_bodies = [_feet(3, 3)]
	_ticks(w, 3)
	_ok("someone 3 studs to the side of the box: nothing", w.output_of(m) == 0)
	_bodies = [_feet(8, 0)]
	_ticks(w, 3)
	_ok("someone 8 studs out, past its reach of 6: nothing", w.output_of(m) == 0)
	w.use_device(m)
	_ticks(w, 2)
	_ok("RMB: reach 10 -- now it sees them", w.output_of(m) == 15 and w.readout({"device": m}).contains("reach 10"))
	_extra[Vector3i(4, 1, 0)] = true
	_extra[Vector3i(4, 2, 0)] = true
	_ticks(w, 8)
	_ok("a wall at 4 studs: they are hidden", w.output_of(m) == 0)
	_bodies = [_feet(2, 0)]
	_ticks(w, 2)
	_ok("this side of the wall: seen", w.output_of(m) == 15)
	_extra.clear()
	_bodies = []
	# Light sensor.
	WiringTraps.light_fn = func(_p: Vector3) -> int: return _sky
	WiringTraps.day_fn = func() -> float: return _day
	var l := Vector3i(6, 0, 0)
	_ok("a light sensor is placed (a plate)", w.place_device(l, &"light_sensor"))
	_ticks(w, 2)
	_ok("open sky at noon: 15", w.output_of(l) == 15)
	_day = 0.0
	_ticks(w, 11)
	_ok("night: 0", w.output_of(l) == 0)
	_day = 1.0
	_sky = 8
	_ticks(w, 11)
	_ok("half roofed by day: 8", w.output_of(l) == 8)
	w.use_device(l)
	_ticks(w, 2)
	_ok("RMB: a night sensor -- 7", w.output_of(l) == 7 and w.readout({"device": l}).contains("night"))
	# Fluid sensor.
	WiringTraps.fluid_fn = func(cell: Vector3i) -> Dictionary: return _fluid.get(cell, {})
	var fs := Vector3i(10, 0, 0)
	_ok("a fluid sensor is placed facing +x", w.place_device(fs, &"fluid_sensor", false, false, 0))
	_ticks(w, 2)
	_ok("dry: 0", w.output_of(fs) == 0)
	_fluid[Vector3i(11, 0, 0)] = {"fluid": 1, "amount": 2}
	_ticks(w, 6)
	_ok("water 2 tiles deep in front: 10", w.output_of(fs) == 10)
	w.use_device(fs)
	_ticks(w, 2)
	_ok("RMB: water only -- still 10", w.output_of(fs) == 10)
	w.use_device(fs)
	_ticks(w, 2)
	_ok("RMB: lava only -- 0", w.output_of(fs) == 0)
	_fluid[Vector3i(11, 0, 0)] = {"fluid": 2, "amount": 3}
	_ticks(w, 6)
	_ok("lava 3 tiles: 15", w.output_of(fs) == 15)
	# Counter: a lever at its back, a reset lever at its right (+z for +x).
	var ct := Vector3i(20, 0, 0)
	_ok("a counter is placed facing +x, N = 3", w.place_device(ct, &"counter", false, false, 0)
			and int(w.devices[ct].setting) == 3)
	var back := Vector3i(19, 0, 0)
	var rst := Vector3i(20, 0, 1)
	w.place_device(back, &"lever")
	w.place_device(rst, &"lever")
	_ticks(w, 2)
	var outs := ""
	for k in 3:
		_lever(w, back, true)
		_ticks(w, 2)
		outs += str(w.output_of(ct) / 15)
		_lever(w, back, false)
		_ticks(w, 2)
	_ok("turn-ons 1, 2 nothing; the third pulses 15 (%s)" % outs, outs == "001")
	var held := 0
	for k in 8:
		if w.output_of(ct) == 15:
			held += 1
		_ticks(w, 1)
	_ok("the pulse is short (%d ticks seen after) and over" % held, held <= WiringTraps.COUNTER_PULSE and w.output_of(ct) == 0)
	_lever(w, back, true)
	_ticks(w, 2)
	_lever(w, back, false)
	_ticks(w, 2)
	_ok("one more: count 1", int(w.devices[ct].count) == 1)
	_lever(w, rst, true)
	_ticks(w, 2)
	_lever(w, rst, false)
	_ticks(w, 2)
	_ok("its right side sets it back to 0", int(w.devices[ct].count) == 0)
	w.use_device(ct)
	_ok("RMB: N = 4, the readout says so", int(w.devices[ct].setting) == 4
			and w.readout({"device": ct}).contains("count 0 of 4"))
	_lever(w, back, true)
	_ticks(w, 2)
	_lever(w, back, false)
	_ticks(w, 2)
	var saved: Variant = JSON.parse_string(JSON.stringify(w.to_save()))
	var w2 := MineWiring.new()
	w2.solid_fn = _solid
	root.add_child(w2)
	w2.restore(saved)
	var d2: Dictionary = w2.devices.get(ct, {})
	_ok("the counter's count (1) and N (4) come back; the sensors' settings too", not d2.is_empty()
			and int(d2.get("count", -1)) == 1 and int(d2.setting) == 4
			and int(w2.devices[m].setting) == 1 and int(w2.devices[l].setting) == 1 and int(w2.devices[fs].setting) == 2)
	w2.queue_free()


func _save(w: MineWiring) -> void:
	print("save")
	w.clear()
	_extra.clear()
	_holes.clear()
	w.place_device(Vector3i(0, 0, 0), &"dispenser", false, false, 3)
	w.devices[Vector3i(0, 0, 0)].slots[3] = ItemStack.make(&"grenade", 5)
	w.place_device(Vector3i(5, 0, 0), &"release_brick")
	_ticks(w, 1)
	w.place_device(Vector3i(4, 0, 0), &"lever")
	_lever(w, Vector3i(4, 0, 0), true)
	_ticks(w, 1)
	var saved: Variant = JSON.parse_string(JSON.stringify(w.to_save()))
	var edits0 := _edits.size()
	var w2 := MineWiring.new()
	w2.solid_fn = _solid
	root.add_child(w2)
	w2.restore(saved)
	var d: Dictionary = w2.devices.get(Vector3i(0, 0, 0), {})
	_ok("a dispenser's slots come back", not d.is_empty() and d.slots[3] != null and d.slots[3].id == &"grenade"
			and d.slots[3].count == 5 and int(d.facing) == 3)
	var r: Dictionary = w2.devices.get(Vector3i(5, 0, 0), {})
	_ok("a let-go release brick comes back let go, and loading edits no ground", not r.is_empty() and bool(r.on)
			and _edits.size() == edits0 and w2.trap_edits.is_empty())
	w2.queue_free()


func _items() -> void:
	print("items")
	_ok("the dispenser is called Shooter in game", str(ItemCatalog.get_def(&"dispenser").name) == "Shooter")
	var am := ItemIcons._model(ItemCatalog.get_def(&"arrow"))
	_ok("arrows are items of kind arrow, with a model", ItemCatalog.kind(&"arrow") == "arrow"
			and am != null and am.get_child(0).get_child_count() >= 3)
	am.free()
	for id in [&"dispenser", &"dropper", &"release_brick", &"alarm", &"motion_sensor", &"light_sensor", &"fluid_sensor", &"counter"]:
		_ok("%s is a device item" % id, ItemCatalog.has(id) and ItemCatalog.kind(id) == "device")
		var m := ItemIcons._model(ItemCatalog.get_def(id))
		_ok("%s has a model of its own" % id, m != null and m.get_child(0).get_child_count() >= 2)
		m.free()
	_ok("named Release brick in game", str(ItemCatalog.get_def(&"release_brick").name) == "Release brick")
	# The wiring guide (Docs/MineWiring.md 29): every device in it, every part an item.
	var listed := WiringGuide.part_ids()
	var missing: Array = []
	for id in MineWiring.DEVICES:
		if not listed.has(id):
			missing.append(id)
	_ok("the wiring guide lists every wiring device (missing: %s)" % [missing], missing.is_empty())
	var not_items: Array = []
	for id in listed:
		if not ItemCatalog.has(id):
			not_items.append(id)
	_ok("every part the guide lists is an item (%s)" % [not_items], not_items.is_empty())
	var page := WiringGuide.build(func(id: StringName, _n: int) -> Control:
		var c := Control.new()
		c.set_meta(&"item", id)
		return c)
	_ok("the guide page builds: a row per part (%d rows)" % page.get_child_count(), page.get_child_count() > listed.size())
	page.free()
