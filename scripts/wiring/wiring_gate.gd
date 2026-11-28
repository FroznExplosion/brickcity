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
## Stage 3b (Docs/MineWiring.md 16):
##   gate tile a wall of gate tiles 2 high: a lever opens the whole wall (its
##             colliders off), off makes it solid again.
##   display   a number display laid with the builder reads 15 beside a lever.
##   sequencer a sequencer's program runs out of its front in the real tick:
##             its lamp is lit, then dark, then lit.
## Stage 4 (Docs/MineWiring.md 18), with real placed bricks:
##   piston    laid with the builder looking straight down: faces up; a
##             2x2 placed brick on it stands (the collapse leaves what rests
##             on a piston); a lever pushes it a course up, still one placed
##             brick, still standing on the head; off, the head comes in and
##             the brick falls; a stack of 3 rides up with the player on top
##             (lifted a course); 13 bricks stall; ground of the world in
##             front stalls a sideways one; sideways the brick in its line is
##             pushed too; a sticky one pulls its brick (and the one on it)
##             back; pushed bricks are where they were pushed after a reload.
##   pictures  user://dev/wiring_pistons.png.
## Stage 7 (Docs/MineWiring.md 20):
##   wire brick laid with the builder, the wiring knows it; a wall of wire
##             bricks (one up a course) carries a lever's power to a lamp;
##             a real shot breaking one cuts it.
##   links     a receiver 14 studs off gives its transmitter's level; RMB
##             steps its channel (dark), the transmitter stepped too (lit); a
##             shot breaking the transmitter darkens it; channels and wire
##             bricks back after a reload. Picture
##             user://dev/wiring_wire_bricks.png.
## Stages 5-6 (Docs/MineWiring.md 19): the traps kit, its own file
## (wiring_traps_gate.gd), at the end; `-- --gate=wiring --traps` runs it alone.
## The gaps after stage 4 (Docs/MineWiring.md 21-27): wiring_gaps_gate.gd,
## before the kit; `--gaps` runs it alone.
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
	if "--traps" in OS.get_cmdline_user_args():
		await _traps()   # the traps kit alone (Docs/MineWiring.md 19)
		_finish()
		return
	if "--gaps" in OS.get_cmdline_user_args():
		await _gaps()   # the gaps fixed after stage 4 alone (Docs/MineWiring.md 21-27)
		_finish()
		return

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

	# --- stage 3b: gate tiles, number display, sequencer (Docs/MineWiring.md 16)
	var zg := z0 + 11
	var glever := Vector3i(x0, y, zg)
	wr.place_device(glever, &"lever")
	var wall: Array[Vector3i] = []
	for x in range(x0 + 1, x0 + 4):
		for k in 2:
			var t := Vector3i(x, y + k * 3, zg)
			wr.place_device(t, &"gate_tile")
			wall.append(t)
	await w._frames(14)
	var body := (wr.devices[wall[0]].node as Node3D).get_node("Body") as StaticBody3D
	check("a wall of 6 gate tiles, solid (collider on)", wr.devices.size() > 0 and wall.all(func(t): return wr.devices.has(t))
			and not wr.is_open(wall[5]) and body.collision_layer != 0)
	wr.use_device(glever)
	await w._frames(14)
	check("the lever on: the whole wall open, colliders off", wall.all(func(t): return wr.is_open(t)) and body.collision_layer == 0)
	wr.use_device(glever)
	await w._frames(14)
	check("off: solid again", not wr.is_open(wall[3]) and body.collision_layer != 0)
	# Number display laid with the builder, beside a lever that is on.
	var dlev := Vector3i(x0 + 6, y, zg)
	wr.place_device(dlev, &"lever", true)
	w._fly_to(Vector3((x0 + 4) * stud, y * plate, (zg + 0.5) * stud), Vector3(1, 0, 0))
	w.walker.pitch = -0.3
	await w._frames(4)
	_hold(&"number_display")
	var disp := Vector3i(x0 + 7, y, zg - 1)
	w.builder.target = {"cell": Vector3i(disp.x, top, disp.z), "normal": Vector3i.UP}
	check("RMB with a number display lays one", w.builder.place_target() and wr.devices.has(disp))
	await w._frames(14)
	var lab := (wr.devices[disp].node as Node3D).get_node("Turn/Number") as Label3D
	check("it reads the lever beside it: \"%s\"" % lab.text, lab.text == "15")
	# Sequencer [5, 5, 5] from a button, a lamp at its front.
	var sq := Vector3i(x0 + 11, y, zg)
	var sbtn := Vector3i(x0 + 10, y, zg)
	var slamp := Vector3i(x0 + 12, y, zg)
	wr.place_device(sbtn, &"button")
	wr.place_device(sq, &"sequencer", false, false, 0, 0)
	wr.place_device(slamp, &"lamp")
	await w._frames(14)
	wr.use_device(sbtn)
	var seq := ""
	for i in 40:
		await w._frames(3)
		var ch := "1" if wr.is_lit(slamp) else "0"
		if seq.is_empty() or seq[seq.length() - 1] != ch:
			seq += ch
	check("the sequencer's lamp: lit, dark, lit, dark (%s)" % seq, seq.begins_with("01010") or seq.begins_with("1010"))

	# --- stage 4: pistons (Docs/MineWiring.md 18), on a second flat patch
	var zp := z0 + 16
	for res in [BrickTerrain.fill_box(Vector3i(x0 - 2, top + 1, zp - 2), Vector3i(x0 + 17, top + 60, zp + 12), 0, false),
			BrickTerrain.fill_box(Vector3i(x0 - 2, top - 6, zp - 2), Vector3i(x0 + 17, top, zp + 12), BrickTerrain.MAT_STONE, false)]:
		w.terrain_edited(res)
	await w._frames(20)
	var up := MineWiring.FACE_UP
	var dark := BrickTerrain.MAT_DARK_STONE
	# Laid with the builder looking straight down: it faces up.
	var pu := Vector3i(x0 + 2, y, zp)
	w._fly_to(Vector3((pu.x + 0.5) * stud - 0.9, y * plate + 1.2, (pu.z + 0.5) * stud), Vector3(1, 0, 0))
	w.walker.pitch = -1.45
	await w._frames(4)
	_hold(&"piston")
	w.builder.target = {"cell": Vector3i(pu.x, top, pu.z), "normal": Vector3i.UP}
	check("RMB with a piston, looking straight down, lays one facing up", w.builder.place_target()
			and wr.devices.has(pu) and int(wr.devices[pu].facing) == up)
	_lay_brick(pu + Vector3i(0, 3, 0), 2, 2, dark)
	await w._frames(30)
	check("a placed 2x2 brick on its top stands (the piston holds it up)", _is_brick(pu + Vector3i(0, 3, 0), 2, 2))
	var plev := Vector3i(pu.x - 1, y, pu.z)
	wr.place_device(plev, &"lever")
	await _settle()
	wr.use_device(plev)
	await _settle()
	check("the lever on: out, the brick a course up, still one 2x2 placed brick", bool(wr.devices[pu].on)
			and _is_brick(pu + Vector3i(0, 6, 0), 2, 2) and BrickTerrain.solid_at(pu.x, y + 3, pu.z) == 0)
	await w._frames(40)
	check("and the collapse leaves it standing on the head", _is_brick(pu + Vector3i(0, 6, 0), 2, 2))
	await _picture(Vector3((pu.x + 1) * stud, y * plate, (pu.z + 1) * stud), Vector3(-2.2, 1.8, -2.4), "wiring_pistons.png")
	wr.use_device(plev)
	await _settle()
	await w._frames(60)
	check("off: the head comes in and the brick it held falls (%s)" % str(BrickTerrain.placed_rect(pu.x, floori((y + 6) / 3.0), pu.z)),
			not bool(wr.devices[pu].on) and BrickTerrain.solid_at(pu.x, y + 6, pu.z) == 0)
	# A stack of 3 clutched on each other rides up, with the player on top.
	var p2 := Vector3i(x0 + 6, y, zp)
	wr.place_device(p2, &"piston", false, false, up)
	_lay_brick(p2 + Vector3i(0, 3, 0), 2, 2, dark)
	_lay_brick(p2 + Vector3i(1, 6, 0), 1, 2, dark)
	_lay_brick(p2 + Vector3i(1, 9, 1), 1, 1, dark)
	var lev2 := Vector3i(p2.x - 1, y, p2.z)
	wr.place_device(lev2, &"lever")
	await _settle()
	var stand := Vector3((p2.x + 1.5) * stud, (y + 12) * plate, (p2.z + 1.5) * stud)
	w._fly_to(stand, Vector3(1, 0, 0))
	await w._frames(10)
	var feet0: Vector3 = w.player_feet_local()
	wr.use_device(lev2)
	await _settle()
	var feet1: Vector3 = w.player_feet_local()
	check("a stack of 3 clutched bricks rides up together (stall '%s')" % wr.last_stall, _is_brick(p2 + Vector3i(0, 6, 0), 2, 2)
			and _is_brick(p2 + Vector3i(1, 9, 0), 1, 2) and _is_brick(p2 + Vector3i(1, 12, 1), 1, 1))
	check("the player on top is lifted (%.2f m)" % (feet1.y - feet0.y), feet1.y - feet0.y > 3 * plate - 0.08)
	w._fly_to(Vector3((x0 + 4) * stud, y * plate + 3.0, (zp - 3) * stud), Vector3(0, 0, 1))
	# 13 bricks stall.
	var p3 := Vector3i(x0 + 10, y, zp)
	wr.place_device(p3, &"piston", false, false, up)
	for k in 13:
		_lay_brick(p3 + Vector3i(0, 3 + 3 * k, 0), 1, 1, dark)
	wr.place_device(Vector3i(p3.x - 1, y, p3.z), &"lever", true)
	await _settle()
	check("13 bricks on it: stalled (%s)" % wr.last_stall, not bool(wr.devices[p3].on)
			and _is_brick(p3 + Vector3i(0, 3, 0), 1, 1) and wr.last_stall.contains("more than"))
	# Ground (not placed) in front stalls a sideways one.
	var p4 := Vector3i(x0 + 2, y, zp + 4)
	wr.place_device(p4, &"piston", false, false, 0)
	w.terrain_edited(BrickTerrain.fill_box(p4 + Vector3i(1, 0, 0), p4 + Vector3i(1, 2, 0), BrickTerrain.MAT_STONE, false))
	wr.place_device(p4 + Vector3i(-1, 0, 0), &"lever", true)
	await _settle()
	check("ground of the world in front stalls it (%s)" % wr.last_stall, not bool(wr.devices[p4].on)
			and wr.last_stall.contains("ground"))
	# Sideways: the brick hops a stud over, the one in its line is pushed too.
	var p5 := Vector3i(x0 + 2, y, zp + 7)
	wr.place_device(p5, &"piston", false, false, 0)
	_lay_brick(p5 + Vector3i(1, 0, 0), 2, 1, dark)
	_lay_brick(p5 + Vector3i(3, 0, 0), 1, 1, dark)
	var lev5 := p5 + Vector3i(-1, 0, 0)
	wr.place_device(lev5, &"lever")
	await _settle()
	wr.use_device(lev5)
	await _settle()
	check("sideways: the 2x1 a stud over, the brick in its line pushed too", bool(wr.devices[p5].on)
			and _is_brick(p5 + Vector3i(2, 0, 0), 2, 1) and _is_brick(p5 + Vector3i(4, 0, 0), 1, 1)
			and BrickTerrain.solid_at(p5.x + 1, y, p5.z) == 0)
	# Sticky: out and back, with the brick clutched on it.
	var p6 := Vector3i(x0 + 10, y, zp + 7)
	wr.place_device(p6, &"sticky_piston", false, false, 0)
	_lay_brick(p6 + Vector3i(1, 0, 0), 1, 1, dark)
	_lay_brick(p6 + Vector3i(1, 3, 0), 1, 1, dark)
	var lev6 := p6 + Vector3i(-1, 0, 0)
	wr.place_device(lev6, &"lever")
	await _settle()
	wr.use_device(lev6)
	await _settle()
	check("sticky: pushed out", _is_brick(p6 + Vector3i(2, 0, 0), 1, 1) and _is_brick(p6 + Vector3i(2, 3, 0), 1, 1))
	wr.use_device(lev6)
	await _settle()
	check("off: pulled back, the brick on it too", not bool(wr.devices[p6].on)
			and _is_brick(p6 + Vector3i(1, 0, 0), 1, 1) and _is_brick(p6 + Vector3i(1, 3, 0), 1, 1)
			and BrickTerrain.solid_at(p6.x + 2, y, p6.z) == 0)

	# A chest on a lifted brick rides up; on one pushed sideways it stalls
	# the push (chests keep to their 2-stud grid).
	var ch: MineChests = w.chests
	var bx := floori((x0 + 14) / 2.0)
	var bz := floori(zp / 2.0)
	var p7 := Vector3i(bx * 2, y, bz * 2)
	wr.place_device(p7, &"piston", false, false, up)
	_lay_brick(p7 + Vector3i(0, 3, 0), 2, 2, dark)
	var cblock := Vector3i(bx, y + 6, bz)
	check("a chest on the brick over a piston", ch.place(cblock, [], true))
	var lev7 := Vector3i(p7.x - 1, y, p7.z)
	wr.place_device(lev7, &"lever")
	await _settle()
	wr.use_device(lev7)
	await _settle()
	check("the lever on: the chest rode up a course with the brick (stall '%s')" % wr.last_stall,
			ch.chests.has(MineChests.key_of(cblock + Vector3i(0, 3, 0))) and _is_brick(p7 + Vector3i(0, 6, 0), 2, 2))
	var bx2 := floori((x0 + 4) / 2.0)
	var bz2 := floori((zp + 10) / 2.0)
	var blo := Vector3i(bx2 * 2, y, bz2 * 2)
	var p8 := blo + Vector3i(-1, 0, 0)
	wr.place_device(p8, &"piston", false, false, 0)
	_lay_brick(blo, 2, 2, dark)
	ch.place(Vector3i(bx2, y + 3, bz2), [], true)
	wr.place_device(p8 + Vector3i(-1, 0, 0), &"lever", true)
	await _settle()
	check("a chest on a brick pushed sideways stalls it (%s)" % wr.last_stall, not bool(wr.devices[p8].on)
			and _is_brick(blo, 2, 2) and ch.chests.has(MineChests.key_of(Vector3i(bx2, y + 3, bz2))))

	# --- stage 7: wire bricks and wireless links (Docs/MineWiring.md 20)
	var zw := z0 + 30
	for res in [BrickTerrain.fill_box(Vector3i(x0 - 2, top + 1, zw - 2), Vector3i(x0 + 17, top + 60, zw + 10), 0, false),
			BrickTerrain.fill_box(Vector3i(x0 - 2, top - 6, zw - 2), Vector3i(x0 + 17, top, zw + 10), BrickTerrain.MAT_STONE, false)]:
		w.terrain_edited(res)
	await w._frames(20)
	var wire := BrickTerrain.MAT_WIRE_BRICK
	# Laid with the builder, as a block: the edit's check finds it.
	w._fly_to(Vector3((x0 + 8) * stud, y * plate + 1.0, (zw - 3) * stud), Vector3(0, 0, 1))
	w.walker.pitch = -0.6
	await w._frames(4)
	_hold(&"wire_brick")
	w.builder.target = {"cell": Vector3i(x0 + 8, top, zw), "normal": Vector3i.UP}
	check("RMB with wire bricks lays one: the wiring knows it", w.builder.place_target()
			and BrickTerrain.solid_at(x0 + 8, y, zw) == wire and wr.wires.has(Vector3i(x0 + 8, y, zw)))
	# A wall: a 3-long wire brick on the ground, a 1x1 on its far end, a
	# lever at its near end, a lamp beside the top one.
	_lay_brick(Vector3i(x0 + 3, y, zw), 3, 1, wire)
	_lay_brick(Vector3i(x0 + 5, y + 3, zw), 1, 1, wire)
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 + 6, y, zw), Vector3i(x0 + 6, y + 2, zw), BrickTerrain.MAT_STONE, false))
	var wlev := Vector3i(x0 + 2, y, zw)
	var wlamp := Vector3i(x0 + 6, y + 3, zw)
	wr.place_device(wlev, &"lever")
	wr.place_device(wlamp, &"lamp")
	await w._frames(16)
	check("a wall of wire bricks is one net (%d wire nodes)" % wr.wires.size(), wr.wires.has(Vector3i(x0 + 3, y, zw))
			and wr.wires.has(Vector3i(x0 + 5, y + 3, zw)) and wr.net_of.has(Vector3i(x0 + 3, y, zw))
			and wr.net_of[Vector3i(x0 + 3, y, zw)] == wr.net_of.get(Vector3i(x0 + 5, y + 3, zw), -1))
	check("lever off: the lamp dark", not wr.is_lit(wlamp))
	wr.use_device(wlev)
	await w._frames(16)
	check("lever on: through the wall and up it, the lamp lit", wr.is_lit(wlamp))
	await _picture(Vector3((x0 + 4) * stud, y * plate, zw * stud), Vector3(-1.2, 1.6, -2.6), "wiring_wire_bricks.png")
	# A real shot at the wall's lower brick cuts the circuit.
	var hitp := Vector3((x0 + 4.5) * stud, (y + 1.5) * plate, zw * stud + 0.01)
	w._mine(w.to_global(hitp), Vector3(0, 0, 1), null)
	await w._frames(30)
	check("a shot breaks the lower wire brick: out of the net, the lamp dark (solid %d)" % BrickTerrain.solid_at(x0 + 4, y, zw),
			not wr.wires.has(Vector3i(x0 + 4, y, zw)) and not wr.is_lit(wlamp))
	# A lever standing on a wire brick drives it: a lamp beside the brick.
	_lay_brick(Vector3i(x0 + 3, y, zw + 4), 2, 1, wire)
	var onlev := Vector3i(x0 + 3, y + 3, zw + 4)
	var onlamp := Vector3i(x0 + 5, y, zw + 4)
	check("a lever on a wire brick, a lamp beside the brick", wr.place_device(onlev, &"lever")
			and wr.place_device(onlamp, &"lamp"))
	await w._frames(16)
	wr.use_device(onlev)
	await w._frames(16)
	check("the lever on: it drives the brick it stands on, the lamp lit", wr.is_lit(onlamp))
	# Wireless: a transmitter beside a lever, a receiver 14 studs off with a lamp.
	# Clear of the builder's wire brick (a 2x2 block at x0+8..9).
	var tx := Vector3i(x0 + 12, y, zw)
	var rx := Vector3i(x0 + 16, y, zw + 8)
	var rlamp := Vector3i(x0 + 16, y, zw + 7)
	check("a lever beside the transmitter", wr.place_device(Vector3i(x0 + 11, y, zw), &"lever", true))
	wr.place_device(tx, &"wire_transmitter")
	wr.place_device(rx, &"wire_receiver")
	wr.place_device(rlamp, &"lamp")
	await w._frames(20)
	check("the receiver gives its transmitter's level: its lamp lit", wr.output_of(rx) == 15 and wr.is_lit(rlamp))
	w.builder.target = {"device": rx, "position": wr.device_box(rx).get_center()}
	_hold(&"stone")
	check("RMB on the receiver steps its channel", w.builder.place_target() and int(wr.devices[rx].setting) == 8)
	await w._frames(20)
	check("on another channel: dark", not wr.is_lit(rlamp))
	wr.use_device(tx)
	await w._frames(20)
	check("the transmitter stepped to the same channel: lit again", wr.is_lit(rlamp))
	var txb: AABB = wr.device_box(tx)
	w._mine(w.to_global(txb.get_center() - Vector3(0, 0, txb.size.z * 0.5 - 0.01)), Vector3(0, 0, 1), null)
	await w._frames(20)
	check("a shot breaks the transmitter: the far lamp dark", not wr.devices.has(tx) and not wr.is_lit(rlamp))

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
	check("the gate tile wall is back, solid; the display reads 15", wall.all(func(t): return wr.devices.has(t) and not wr.is_open(t))
			and wr.output_of(disp) == 15)
	check("the wire bricks and the receiver (its channel) are back", wr.wires.has(Vector3i(x0 + 8, y, zw))
			and wr.wires.has(Vector3i(x0 + 3, y, zw)) == false and wr.devices.has(rx) and int(wr.devices[rx].setting) == 8)
	check("the pistons are back (one facing up); the pushed bricks where they were pushed",
			wr.devices.has(pu) and int(wr.devices[pu].facing) == up and wr.devices.has(p6)
			and _is_brick(p5 + Vector3i(2, 0, 0), 2, 1) and _is_brick(p6 + Vector3i(1, 0, 0), 1, 1))

	await _gaps()
	await _traps()
	_finish()


## The gaps fixed after stage 4 (Docs/MineWiring.md 21-27):
## scripts/wiring/wiring_gaps_gate.gd.
func _gaps() -> void:
	await preload("res://scripts/wiring/wiring_gaps_gate.gd").new().run(self)


## Stages 5-6, the traps kit: scripts/wiring/wiring_traps_gate.gd.
func _traps() -> void:
	await preload("res://scripts/wiring/wiring_traps_gate.gd").new().run(self)


func _finish() -> void:
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


## A placed brick (one, as the builder lays a block): sx x sz studs, a course.
func _lay_brick(lo: Vector3i, sx: int, sz: int, mat: int) -> void:
	var hi := lo + Vector3i(sx - 1, 2, sz - 1)
	var res: Dictionary = BrickTerrain.fill_box(lo, hi, mat, false)
	BrickTerrain.mark_placed(lo, hi, mat)
	w.terrain_edited(res)


## One whole placed brick sx x sz with its low corner at `lo`?
func _is_brick(lo: Vector3i, sx: int, sz: int) -> bool:
	for x in range(lo.x, lo.x + sx):
		for z in range(lo.z, lo.z + sz):
			if BrickTerrain.placed_rect(x, floori(lo.y / 3.0), z) != Vector4i(lo.x, lo.z, sx, sz):
				return false
			for p in 3:
				if BrickTerrain.solid_at(x, lo.y + p, z) == 0:
					return false
	return true


## A wiring change and the moves it starts all done: more than two ticks,
## then every piston move landed and its tiles in.
func _settle() -> void:
	await w._frames(16)
	var n := 0
	while not w.wiring._moves.is_empty() and n < 240:
		await w._frames(1)
		n += 1
	await w._frames(4)


func _hold(id: StringName) -> void:
	var inv: Inventory = w.builder.inv
	if not inv.select_item(id):
		inv.pick(id)
	check("%s in the hand" % id, inv.hand() != null and inv.hand().id == id)
