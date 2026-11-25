extends RefCounted
## -- --gate=wiring (Docs/MineWiring.md 10, stage 1): cable tiles, a lever
## and lamps in the real mine world, the player's way where it matters (the
## builder's aim, RMB and LMB; a real shot).
##
##   godot --path . scenes/terrain_test.tscn -- --gate=wiring
##
## What each check is for:
##   lay       RMB with cable tiles lays one on the top looked at; a lever and
##             a lamp the same; a run branches and climbs a placed block.
##   aim       looking at a cable, the builder's target is the cable, and LMB
##             takes it (not the ground under it); RMB lays it again.
##   power     the lever's RMB lights both lamps (one on the block's top, up
##             the climb); off, both dark.
##   shot      a real shot at a cable cuts it: the lamp past the cut goes
##             dark, the one on the other branch stays lit.
##   ground    the ground under a cable dug out: the cable breaks.
##   save      the world generated again (saved, loaded): the cables, the
##             lever's state and the lit lamp come back.
##   pictures  user://dev/wiring_on.png, wiring_cut.png.
## Preloaded by mine_world.gd (`--gate=wiring`).

var w: Node = null
var fails: Array[String] = []


func check(what: String, ok: bool) -> void:
	print("[wiring-gate] %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		fails.append(what)


func run(host: Node) -> void:
	w = host
	var wr: MineWiring = w.wiring
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	w._time = 0.5
	w.set_on_foot(false)
	await w._frames(30)
	w.builder.aim_trees = false

	# A flat patch by the spawn: 18 x 12 studs of stone, its top a course's
	# top, nothing over it.
	var eye: Vector3 = w._eye()
	var x0 := floori(eye.x / stud) + 6
	var z0 := floori(eye.z / stud) - 6
	var s0 := BrickTerrain.surface_plate(x0, z0)
	var top := floori(float(s0 + 1) / 3.0) * 3 - 1
	for res in [BrickTerrain.fill_box(Vector3i(x0 - 2, top + 1, z0 - 2), Vector3i(x0 + 17, top + 60, z0 + 11), 0, false),
			BrickTerrain.fill_box(Vector3i(x0 - 2, top - 6, z0 - 2), Vector3i(x0 + 17, top, z0 + 11), BrickTerrain.MAT_STONE, false)]:
		w.terrain_edited(res)
	await w._frames(20)
	wr.clear()
	var y := top + 1
	var z := z0 + 2

	# --- lay: the first cable, the lever and a lamp through the builder's RMB
	_hold(&"cable")
	w.builder.target = {"cell": Vector3i(x0, top, z), "normal": Vector3i.UP}
	check("RMB with cable tiles lays one on the top", w.builder.place_target() and wr.cables.has(Vector3i(x0, y, z)))
	for x in range(x0 + 1, x0 + 10):
		wr.place_cable(Vector3i(x, y, z))
	_hold(&"lever")
	var lever := Vector3i(x0 - 1, y, z)
	w.builder.target = {"cell": Vector3i(x0 - 1, top, z), "normal": Vector3i.UP}
	check("RMB with a lever puts one down", w.builder.place_target() and wr.devices.has(lever))
	_hold(&"lamp")
	var lamp := Vector3i(x0 + 10, y, z)
	w.builder.target = {"cell": Vector3i(x0 + 10, top, z), "normal": Vector3i.UP}
	check("RMB with a lamp puts one down", w.builder.place_target() and wr.devices.has(lamp))
	# A branch: from the run's start along +z to a second row, which climbs a
	# placed block (one brick) to a lamp on its top.
	var z2 := z + 4
	for k in range(1, 4):
		wr.place_cable(Vector3i(x0, y, z + k))
	for x in range(x0, x0 + 8):
		wr.place_cable(Vector3i(x, y, z2))
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 + 8, y, z2 - 1), Vector3i(x0 + 10, y + 2, z2 + 1), BrickTerrain.MAT_STONE, false))
	wr.place_cable(Vector3i(x0 + 8, y + 3, z2))
	var lamp2 := Vector3i(x0 + 9, y + 3, z2)
	wr.place_device(lamp2, &"lamp")
	await w._frames(10)
	check("one net: the run, the branch and the climb (%d nets, %d cables)" % [wr.nets.size(), wr.cables.size()],
			wr.nets.size() == 1 and wr.cables.size() == 22)

	# --- aim: looking down at a cable, LMB takes it and RMB lays it again
	var aim_cell := Vector3i(x0 + 4, y, z)
	var aim_at := wr.cable_box(aim_cell).get_center()
	var from := aim_at + Vector3(-0.4, 1.4, 0.0)
	var d := (aim_at - from).normalized()
	w._fly_to(from - Vector3(0, 1.6, 0), Vector3(d.x, 0, d.z))
	w.walker.pitch = asin(clampf(d.y, -1.0, 1.0))
	await w._frames(6)
	w.builder.update_target()
	check("looking at a cable, the target is the cable (%s)" % str(w.builder.target.get("cable", "none")),
			w.builder.target.get("cable", Vector3i(0, -9999, 0)) == aim_cell)
	_hold(&"stone")
	check("LMB takes the cable, not the ground", w.builder.break_target() and not wr.cables.has(aim_cell)
			and BrickTerrain.solid_at(aim_cell.x, top, aim_cell.z) != 0)
	_hold(&"cable")
	w.builder.update_target()
	check("RMB lays it again", w.builder.place_target() and wr.cables.has(aim_cell))
	await w._frames(6)

	# --- power
	check("lever off: both lamps dark", not wr.is_lit(lamp) and not wr.is_lit(lamp2))
	w.builder.target = {"device": lever, "position": wr.device_box(lever).get_center()}
	check("RMB on the lever turns it on", w.builder.place_target() and bool(wr.devices[lever].on))
	await w._frames(12)
	check("both lamps lit, the one up the climb too", wr.is_lit(lamp) and wr.is_lit(lamp2))
	await _picture(Vector3((x0 + 4) * stud, y * plate, (z + 2) * stud), Vector3(-3.4, 2.6, -2.6), "wiring_on.png")

	# --- shot: a real bullet at a cable of the first row, past the branch
	var cut := Vector3i(x0 + 6, y, z)
	var hit := Vector3((cut.x + 0.5) * stud, y * plate, (cut.z + 0.5) * stud)
	w._mine(w.to_global(hit), Vector3.DOWN, null)
	await w._frames(12)
	check("a shot cuts the cable", not wr.cables.has(cut))
	check("the lamp past the cut is dark, the other branch's lit", not wr.is_lit(lamp) and wr.is_lit(lamp2))
	await _picture(Vector3((x0 + 4) * stud, y * plate, (z + 2) * stud), Vector3(-3.4, 2.6, -2.6), "wiring_cut.png")

	# --- ground: dig out the brick under a cable
	var under := Vector3i(x0 + 2, y, z2)
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(under.x, top - 2, under.z), Vector3i(under.x, top, under.z), 0, false))
	await w._frames(6)
	check("the ground under a cable dug out: it breaks", not wr.cables.has(under))
	check("and the lamp up the climb, cut off from the lever, is dark", not wr.is_lit(lamp2))
	wr.place_cable(Vector3i(under.x, y, under.z + 1))   # not a path: the gap stays
	# Mend the branch round the hole (x0+1 .. x0+3 on z2+1) so lamp2 is lit for the save.
	for x in range(x0 + 1, x0 + 4):
		wr.place_cable(Vector3i(x, y, z2 + 1))
	await w._frames(6)
	check("mended round the hole: lit again", wr.is_lit(lamp2))

	# --- save: generated again
	var n_cables: int = wr.cables.size()
	var n_dev: int = wr.devices.size()
	w.generate(w.settings)
	await w._frames(30)
	check("after generating again: %d cables, %d devices" % [wr.cables.size(), wr.devices.size()],
			wr.cables.size() == n_cables and wr.devices.size() == n_dev)
	check("the lever still on, the lamp up the climb lit", wr.devices.has(lever) and bool(wr.devices[lever].on)
			and wr.is_lit(lamp2))

	print("[wiring-gate] %s" % ("WIRING-GATE PASS" if fails.is_empty() else "WIRING-GATE FAIL: " + "; ".join(fails)))
	w.get_tree().quit(0 if fails.is_empty() else 1)


func _picture(mid: Vector3, off: Vector3, file: String) -> void:
	var cam_at := mid + off
	var d := (mid - cam_at).normalized()
	w._fly_to(cam_at - Vector3(0, 1.6, 0), Vector3(d.x, 0, d.z))
	w.walker.pitch = asin(clampf(d.y, -1.0, 1.0))
	if w._hud_layer != null:
		w._hud_layer.visible = false
	await w._frames(40)
	await w._shot(UserPaths.DEV + file)
	if w._hud_layer != null:
		w._hud_layer.visible = true


func _hold(id: StringName) -> void:
	var inv: Inventory = w.builder.inv
	if not inv.select_item(id):
		inv.pick(id)
	check("%s in the hand" % id, inv.hand() != null and inv.hand().id == id)
