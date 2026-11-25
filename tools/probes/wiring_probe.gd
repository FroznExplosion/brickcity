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

var _pass := 0
var _fail := 0
## The probe's ground: plate cells that are solid. Flat at plate -1 and under,
## a raised step (3 plates, a brick) for x >= 20.
var _extra := {}
var _holes := {}


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
	if x >= 20 and y < 3:
		return 1
	return 0


func _init() -> void:
	var w := MineWiring.new()
	w.solid_fn = _solid
	root.add_child(w)
	_nets(w)
	_power(w)
	_ground(w)
	_hits(w)
	_rebuild(w)
	_save(w)
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


func _items() -> void:
	print("items")
	ItemCatalog.load_all(true)
	_ok("cable, lever, lamp are items", ItemCatalog.has(&"cable") and ItemCatalog.has(&"lever") and ItemCatalog.has(&"lamp"))
	_ok("their kinds: wire, device", ItemCatalog.kind(&"cable") == "wire" and ItemCatalog.kind(&"lever") == "device")
	for id in [&"cable", &"lever", &"lamp"]:
		var m := ItemIcons._model(ItemCatalog.get_def(id))
		_ok("%s has a model" % id, m != null and m.get_child(0).get_child_count() >= 2)
		m.free()
