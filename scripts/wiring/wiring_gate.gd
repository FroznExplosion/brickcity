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
##   pictures  user://dev/wiring_on.png, wiring_cut.png, wiring_gates.png.
## Stage 2 (Docs/MineWiring.md 14):
##   gate      a NOT gate laid with the builder faces away from the camera;
##             with its back off it lights the lamp at its front.
##   button    the builder's RMB on a button: the NOT's lamp dark, back in
##             a second and a half.
##   wrench    in the hand (build mode on): the cables through walls, the
##             readout of the cable looked at; RMB turns the gate.
##   held RMB  a repeat of a held RMB does not turn a lever again.
##   pressure  the player standing on a pressure tile lights its lamp; off it,
##             dark again.
##   trip      the player crossing a trip string lights its lamp.
## Stage 3 (Docs/MineWiring.md 15):
##   door      laid with the builder across the camera's view; a lever beside
##             it swings it open (its collider turns with it), off shuts it.
##   observer  a real ground edit in the stud it watches flashes the lamp at
##             its back.
##   trapdoor  over a dug pit, held by the ground beside it; a lever opens it.
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
	await w._frames(14)
	check("one net: the run, the branch and the climb (%d nets, %d cables)" % [wr.nets.size(), wr.cables.size()],
			wr.nets.size() == 1 and wr.cables.size() == 22)

	# --- aim: looking down at a cable, LMB takes it and RMB lays it again
	var aim_cell := Vector3i(x0 + 4, y, z)
	var aim_at := wr.cable_box(aim_cell).get_center()
	var from := aim_at + Vector3(-0.4, 1.4, 0.0)
	var d := (aim_at - from).normalized()
	w._fly_to(from - Vector3(0, 1.6, 0), Vector3(d.x, 0, d.z))
	w.walker.pitch = asin(clampf(d.y, -1.0, 1.0))
	await w._frames(14)
	w.builder.update_target()
	check("looking at a cable, the target is the cable (%s)" % str(w.builder.target.get("cable", "none")),
			w.builder.target.get("cable", Vector3i(0, -9999, 0)) == aim_cell)
	_hold(&"stone")
	check("LMB takes the cable, not the ground", w.builder.break_target() and not wr.cables.has(aim_cell)
			and BrickTerrain.solid_at(aim_cell.x, top, aim_cell.z) != 0)
	_hold(&"cable")
	w.builder.update_target()
	check("RMB lays it again", w.builder.place_target() and wr.cables.has(aim_cell))
	await w._frames(14)

	# --- power
	check("lever off: both lamps dark", not wr.is_lit(lamp) and not wr.is_lit(lamp2))
	w.builder.target = {"device": lever, "position": wr.device_box(lever).get_center()}
	check("RMB on the lever turns it on", w.builder.place_target() and bool(wr.devices[lever].on))
	await w._frames(14)
	check("both lamps lit, the one up the climb too", wr.is_lit(lamp) and wr.is_lit(lamp2))
	await _picture(Vector3((x0 + 4) * stud, y * plate, (z + 2) * stud), Vector3(-3.4, 2.6, -2.6), "wiring_on.png")

	# --- shot: a real bullet at a cable of the first row, past the branch
	var cut := Vector3i(x0 + 6, y, z)
	var hit := Vector3((cut.x + 0.5) * stud, y * plate, (cut.z + 0.5) * stud)
	w._mine(w.to_global(hit), Vector3.DOWN, null)
	await w._frames(14)
	check("a shot cuts the cable", not wr.cables.has(cut))
	check("the lamp past the cut is dark, the other branch's lit", not wr.is_lit(lamp) and wr.is_lit(lamp2))
	await _picture(Vector3((x0 + 4) * stud, y * plate, (z + 2) * stud), Vector3(-3.4, 2.6, -2.6), "wiring_cut.png")

	# --- ground: dig out the brick under a cable
	var under := Vector3i(x0 + 2, y, z2)
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(under.x, top - 2, under.z), Vector3i(under.x, top, under.z), 0, false))
	await w._frames(14)
	check("the ground under a cable dug out: it breaks", not wr.cables.has(under))
	check("and the lamp up the climb, cut off from the lever, is dark", not wr.is_lit(lamp2))
	wr.place_cable(Vector3i(under.x, y, under.z + 1))   # not a path: the gap stays
	# Mend the branch round the hole (x0+1 .. x0+3 on z2+1) so lamp2 is lit for the save.
	for x in range(x0 + 1, x0 + 4):
		wr.place_cable(Vector3i(x, y, z2 + 1))
	await w._frames(14)
	check("mended round the hole: lit again", wr.is_lit(lamp2))

	# --- stage 2: gates, sensors, the wrench (Docs/MineWiring.md 14)
	var z3 := z0 + 9
	var button := Vector3i(x0, y, z3)
	wr.place_device(button, &"button")
	for x in range(x0 + 1, x0 + 4):
		wr.place_cable(Vector3i(x, y, z3))
	var gate := Vector3i(x0 + 4, y, z3)
	var lamp3 := Vector3i(x0 + 5, y, z3)
	# The camera looks along +x: a gate laid now faces +x.
	var look_from := Vector3((x0 + 1) * stud, y * plate + 1.6, (z3 + 0.5) * stud)
	w._fly_to(look_from - Vector3(0, 1.6, 0), Vector3(1, 0, 0))
	w.walker.pitch = -0.6
	await w._frames(4)
	_hold(&"not_gate")
	w.builder.target = {"cell": Vector3i(gate.x, top, gate.z), "normal": Vector3i.UP}
	check("RMB with a NOT gate lays one, facing away from the camera (+x)", w.builder.place_target()
			and wr.devices.has(gate) and int(wr.devices[gate].facing) == 0)
	wr.place_device(lamp3, &"lamp")
	await w._frames(14)
	check("NOT with its back off: the lamp at its front lit", wr.is_lit(lamp3))
	w.builder.target = {"device": button, "position": wr.device_box(button).get_center()}
	check("RMB on the button presses it", w.builder.place_target())
	# Two ticks (0.2 s) from the button to the lamp: wait for it, well inside
	# the button's second.
	var waited := 0
	while wr.is_lit(lamp3) and waited < 40:
		await w._frames(1)
		waited += 1
	check("button pressed: the NOT's lamp dark (%d frames)" % waited, not wr.is_lit(lamp3))
	await w._frames(100)
	check("a second and a half later: lit again", wr.is_lit(lamp3))
	# A held RMB's repeat does not turn the lever.
	var was: bool = wr.devices[lever].on
	w.builder.rmb_repeat = true
	w.builder.target = {"device": lever, "position": wr.device_box(lever).get_center()}
	check("a held RMB's repeat does not turn the lever again", not w.builder.place_target()
			and bool(wr.devices[lever].on) == was)
	w.builder.rmb_repeat = false
	# The wrench, build mode on: aim at a cable of this row.
	_hold(&"wrench")
	w.builder.set_active(true)
	var aim3 := wr.cable_box(Vector3i(x0 + 2, y, z3)).get_center()
	var from3 := aim3 + Vector3(-0.4, 1.4, 0.0)
	var d3 := (aim3 - from3).normalized()
	w._fly_to(from3 - Vector3(0, 1.6, 0), Vector3(d3.x, 0, d3.z))
	w.walker.pitch = asin(clampf(d3.y, -1.0, 1.0))
	await w._frames(14)
	var ro: Label = wr._readout
	check("wrench: the readout of the cable looked at (%s)" % (ro.text if ro != null else "none"),
			ro != null and ro.visible and ro.text.contains("level"))
	check("wrench: the cables drawn through walls", wr._xray_cable.visible)
	w.builder.target = {"device": gate, "position": wr.device_box(gate).get_center()}
	check("wrench RMB turns the gate a quarter (+x to +z)", w.builder.place_target() and int(wr.devices[gate].facing) == 2)
	for i in 3:
		wr.use_device(gate, "turn")
	check("and round to +x again", int(wr.devices[gate].facing) == 0)
	_hold(&"cable")
	await w._frames(4)
	check("the wrench put away: no x-ray, no readout", not wr._xray_cable.visible and not ro.visible)
	w.builder.set_active(false)
	# Pressure tile: the player stands on it.
	var tile := Vector3i(x0 + 8, y, z3)
	var lamp4 := Vector3i(x0 + 9, y, z3)
	wr.place_device(tile, &"pressure_tile")
	wr.place_device(lamp4, &"lamp")
	await w._frames(14)
	check("pressure tile: dark with nobody on it", not wr.is_lit(lamp4))
	var tb := wr.device_box(tile)
	w._fly_to(Vector3(tb.get_center().x, tb.end.y, tb.get_center().z), Vector3(1, 0, 0))
	await w._frames(14)
	check("the player on the tile: lit (feet %s)" % str(w.player_feet_local()), wr.is_lit(lamp4))
	w._fly_to(Vector3(tb.get_center().x, tb.end.y + 3.0, tb.get_center().z - 2.0), Vector3(1, 0, 0))
	await w._frames(30)
	check("off it: dark", not wr.is_lit(lamp4))
	# Trip string across the row's end.
	var ha := Vector3i(x0 + 11, y, z3)
	var hb := Vector3i(x0 + 16, y, z3)
	wr.place_device(ha, &"trip_hook", false, false, 0)
	wr.place_device(hb, &"trip_hook", false, false, 1)
	var lamp5 := Vector3i(x0 + 11, y, z3 - 1)
	wr.place_device(lamp5, &"lamp")
	await w._frames(14)
	check("two hooks pair: a string", wr.pairs.get(ha, Vector3i.ZERO) == hb)
	w._fly_to(Vector3((x0 + 13.5) * stud, y * plate, (z3 + 0.5) * stud), Vector3(0, 0, 1))
	await w._frames(14)
	check("the player across the string: lit", wr.is_lit(lamp5))
	w._fly_to(Vector3((x0 + 13.5) * stud, y * plate + 3.0, (z3 - 4.5) * stud), Vector3(0, 0, 1))
	await w._frames(30)
	check("walked on: dark", not wr.is_lit(lamp5))
	await _picture(Vector3((x0 + 8) * stud, y * plate, z3 * stud), Vector3(-2.0, 2.4, -3.4), "wiring_gates.png")

	# --- stage 3: door, observer, trapdoor (Docs/MineWiring.md 15)
	var zd := z0 - 1
	var door := Vector3i(x0 + 2, y, zd)
	w._fly_to(Vector3((x0 - 1) * stud, y * plate, zd * stud), Vector3(1, 0, 0))
	w.walker.pitch = -0.3
	await w._frames(4)
	_hold(&"door")
	w.builder.target = {"cell": Vector3i(door.x, top, door.z), "normal": Vector3i.UP}
	check("RMB with a door lays one across the view (facing +x)", w.builder.place_target() and wr.devices.has(door)
			and int(wr.devices[door].facing) == 0)
	var dlever := Vector3i(x0 + 1, y, zd)
	wr.place_device(dlever, &"lever")
	await w._frames(14)
	var hinge := (wr.devices[door].node as Node3D).get_node("Turn/Hinge") as Node3D
	check("shut: its panel square", not wr.is_open(door) and is_zero_approx(hinge.rotation.y))
	wr.use_device(dlever)
	await w._frames(14)
	check("the lever on: open, the panel (and its collider) swung", wr.is_open(door) and absf(hinge.rotation.y - PI * 0.5) < 0.01)
	wr.use_device(dlever)
	await w._frames(14)
	check("the lever off: shut", not wr.is_open(door))
	# Observer watching a stud of the patch; a lamp at its back.
	var ob := Vector3i(x0 + 6, y, zd)
	wr.place_device(ob, &"observer", false, false, 0)
	var oblamp := Vector3i(x0 + 5, y, zd)
	wr.place_device(oblamp, &"lamp")
	await w._frames(14)
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 + 7, y, zd), Vector3i(x0 + 7, y + 2, zd), BrickTerrain.MAT_STONE, false))
	var seen := false
	for i in 20:
		await w._frames(1)
		seen = seen or wr.is_lit(oblamp)
	check("a real ground edit in front of the observer flashed the lamp at its back", seen)
	await w._frames(14)
	check("and the flash is over", not wr.is_lit(oblamp))
	# Trapdoor over a pit dug in the patch.
	var px := x0 + 10
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(px, top - 5, zd), Vector3i(px + 1, top, zd + 1), 0, false))
	await w._frames(14)
	var trap := Vector3i(px, top, zd)
	check("a trapdoor over the pit, held by the ground beside it", wr.place_device(trap, &"trapdoor", false, false, 0))
	var tlever := Vector3i(px + 2, y, zd)
	wr.place_device(tlever, &"lever")
	await w._frames(14)
	check("shut", not wr.is_open(trap))
	wr.use_device(tlever)
	await w._frames(14)
	check("the lever on: the trapdoor swung down open", wr.is_open(trap))

	# --- save: generated again
	var n_cables: int = wr.cables.size()
	var n_dev: int = wr.devices.size()
	w.generate(w.settings)
	await w._frames(30)
	check("after generating again: %d cables, %d devices" % [wr.cables.size(), wr.devices.size()],
			wr.cables.size() == n_cables and wr.devices.size() == n_dev)
	check("the lever still on, the lamp up the climb lit", wr.devices.has(lever) and bool(wr.devices[lever].on)
			and wr.is_lit(lamp2))
	check("the NOT gate still faces +x and lights its lamp; the string is back", wr.devices.has(gate)
			and int(wr.devices[gate].facing) == 0 and wr.is_lit(lamp3) and wr.pairs.get(ha, Vector3i.ZERO) == hb)
	check("the door is back, shut; the trapdoor back, open", wr.devices.has(door) and not wr.is_open(door)
			and wr.devices.has(trap) and wr.is_open(trap))

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
