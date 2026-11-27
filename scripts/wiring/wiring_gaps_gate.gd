extends RefCounted
## -- --gate=wiring, the gaps section (Docs/MineWiring.md 20-26): the fixes
## to what stages 1-4 left, in the real mine world. Run by wiring_gate.gd
## before the traps kit; `-- --gate=wiring --gaps` runs it alone.
##
## What each check is for:
##   creatures  a zombie standing on a pressure tile lights its lamp: enemies
##              spring traps, not only the player (20).
##   cave light a wire and a lamp in a closed room (stone walls, a placed
##              brick for its roof) take its dark (sky
##              level 2 or less), a wire outside it the open sky's 15 (21).
##   lamps      12 lamps lit by one lever: only the cap's worth (Options >
##              Video > Lamp Lights x 2; 8 at the test window's defaults)
##              hang a real light, on the ones nearest the camera (22).
##   gate tiles a bridge of gate tiles off one standing at a trench's edge:
##              digging out that one's ground drops the whole bridge (23).
##   sequencer  the builder's RMB on a sequencer (a wire in the hand) opens
##              its program editor, the builder idle meanwhile; a program typed
##              in runs out of its front in the real tick; a real Escape closes
##              the panel and not into the pause menu; the program is kept
##              after the world is generated again (24).
##   trapdoor   on foot, standing on a trapdoor over a pit: the lever opens
##              it and the player falls into the pit (25).
##   pistons    a real push's stand-in draws the bevelled box with the mine
##              world's (sky-lit) brick material; a collapse piece fallen in
##              front of a piston is shoved by its head going out: woken and
##              moved (26).

var g = null   # wiring_gate.gd: check(), w (the mine world)
var w: Node = null
var wr: MineWiring = null
var stud := 0.35
var plate := 0.14
var x0 := 0
var z0 := 0
var top := 0
var y := 0


func run(gate) -> void:
	g = gate
	w = gate.w
	wr = w.wiring
	stud = BrickWorld.get_stud_metres()
	plate = BrickWorld.get_plate_metres()
	# Flying (the main gate's save section ends on foot; its eye would stay
	# where the pawn is while the walker is moved).
	w.set_on_foot(false)
	await w._frames(10)
	_patch()
	await w._frames(20)
	await _creatures()
	await _cave_light()
	await _lamps()
	await _gatetiles()
	await _sequencer()
	await _trapdoor()
	await _pistons()


## A flat patch of stone of its own, 24 x 16 studs, a course's top: well
## away from the main gate's patches (east of where the eye began; the eye
## has moved by the time this runs) and their lamps.
func _patch() -> void:
	var eye: Vector3 = w._eye()
	x0 = floori(eye.x / stud) - 60
	z0 = floori(eye.z / stud) - 30
	var s0 := BrickTerrain.surface_plate(x0, z0)
	top = floori(float(s0 + 1) / 3.0) * 3 - 1
	for res in [BrickTerrain.fill_box(Vector3i(x0 - 2, top + 1, z0 - 2), Vector3i(x0 + 25, top + 60, z0 + 17), 0, false),
			BrickTerrain.fill_box(Vector3i(x0 - 2, top - 9, z0 - 2), Vector3i(x0 + 25, top, z0 + 17), BrickTerrain.MAT_STONE, false)]:
		w.terrain_edited(res)
	y = top + 1


# --- 1. creatures press tiles (Docs/MineWiring.md 20)
func _creatures() -> void:
	var tile := Vector3i(x0 + 4, y, z0 + 2)
	var lamp := Vector3i(x0 + 5, y, z0 + 2)
	wr.place_device(tile, &"pressure_tile")
	wr.place_device(lamp, &"lamp")
	# The player well away (a zombie walks to the player: it must stand on
	# the tile for a moment first).
	w._fly_to(Vector3((x0 + 4) * stud, y * plate + 6.0, (z0 + 14) * stud), Vector3(0, 0, -1))
	await w._frames(20)
	g.check("gaps: the tile is dark with nobody on it", not wr.is_lit(lamp))
	var tb := wr.device_box(tile)
	var zombie = w.mobs.spawn_zombie(Vector3(tb.get_center().x, tb.end.y + 0.05, tb.get_center().z)) if w.mobs != null else null
	var lit := false
	for i in 40:
		await w._frames(1)
		lit = lit or wr.is_lit(lamp)
	g.check("gaps: a zombie on the pressure tile lights its lamp (feet %s)" %
			(str(zombie.last_feet) if zombie != null else "no zombie"), zombie != null and lit)
	if zombie != null and is_instance_valid(zombie) and zombie.pawn != null:
		zombie.pawn.health.apply_impact(1000.0, &"")
	await w._frames(40)
	g.check("gaps: the zombie dead, the tile lets go", not wr.is_lit(lamp))
	wr.remove_device(tile, false)
	wr.remove_device(lamp, false)


# --- 2. cave light (Docs/MineWiring.md 21)
func _cave_light() -> void:
	if w.sky_lit == null:
		g.check("gaps: sky light is on in the gate world", false)
		return
	# A closed room on the patch: walls of stone a stud thick and 2 courses
	# tall round 4 x 4 studs, and for a roof ONE 6 x 6 placed brick resting on
	# them (a roof course of loose stone over the room fell to the collapse --
	# a course is held through studs, not by its sides -- and a pocket dug in
	# the ground filled with the gravel over it).
	var rx := x0 + 10
	var rz := z0 + 2
	var fy := y   # the room's floor cells
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(rx - 1, fy, rz - 1), Vector3i(rx + 4, fy + 5, rz + 4), BrickTerrain.MAT_STONE, false))
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(rx, fy, rz), Vector3i(rx + 3, fy + 5, rz + 3), 0, false))
	g._lay_brick(Vector3i(rx - 1, fy + 6, rz - 1), 6, 6, BrickTerrain.MAT_STONE)
	# The sky level reads the tiles' baked tops: the tile rebuilt first (and
	# the collapse has looked at the new roof).
	await w._frames(90)
	var sealed := true
	for k in [Vector3i(rx - 1, fy + 2, rz + 1), Vector3i(rx + 4, fy + 2, rz + 1), Vector3i(rx + 1, fy + 2, rz - 1),
			Vector3i(rx + 1, fy + 2, rz + 4), Vector3i(rx + 1, fy + 6, rz + 1), Vector3i(rx + 2, fy + 8, rz + 2),
			Vector3i(rx + 1, fy - 1, rz + 1)]:
		sealed = sealed and BrickTerrain.solid_at(k.x, k.y, k.z) != 0
	var open_in := BrickTerrain.solid_at(rx + 1, fy, rz + 1) == 0 and BrickTerrain.solid_at(rx + 2, fy + 4, rz + 2) == 0
	g.check("gaps: the room is closed (walls, floor and roof solid, air inside)", sealed and open_in)
	var inside := Vector3i(rx + 1, fy, rz + 1)
	var outside := Vector3i(rx - 3, y, rz + 2)
	var lamp := Vector3i(rx + 2, fy, rz + 2)
	var placed := [wr.place_cable(inside), wr.place_cable(outside), wr.place_device(lamp, &"lamp")]
	g.check("gaps: a wire and a lamp laid in the room, a wire outside (%s; under the lamp %d, in it %d)" % [str(placed),
			BrickTerrain.solid_at(lamp.x, lamp.y - 1, lamp.z), BrickTerrain.solid_at(lamp.x, lamp.y, lamp.z)],
			placed.all(func(v): return v))
	if not placed.all(func(v): return v):
		return
	await w._frames(30)
	var lin: Vector2 = wr.cell_light.get(inside, Vector2(-1, -1))
	var lout: Vector2 = wr.cell_light.get(outside, Vector2(-1, -1))
	var node: Node3D = wr.devices[lamp].node
	var ldev: float = w.sky_lit.level_of(node)
	g.check("gaps: a wire in a closed room is dark (sky %.0f), one outside open (sky %.0f)" % [lin.x, lout.x],
			lin.x >= 0.0 and lin.x <= 2.0 and lout.x >= 14.0)
	g.check("gaps: a lamp in the room is tracked and dark (sky %.1f)" % ldev, ldev >= 0.0 and ldev <= 2.0)
	g.check("gaps: the wires draw with the sky-lit shader", (wr._tiles_mi.material_override as ShaderMaterial).shader
			== MineWiring.wire_shader(true))
	wr.remove_cable(inside, false)
	wr.remove_cable(outside, false)
	wr.remove_device(lamp, false)
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(rx - 1, fy, rz - 1), Vector3i(rx + 4, fy + 8, rz + 4), 0, false))
	await w._frames(4)


# --- 3. lamp lights (Docs/MineWiring.md 22)
func _lamps() -> void:
	var lz := z0 + 10
	var lamps: Array[Vector3i] = []
	for x in range(x0, x0 + 12):
		wr.place_cable(Vector3i(x, y, lz))
		var l := Vector3i(x, y, lz + 1)
		wr.place_device(l, &"lamp")
		lamps.append(l)
	var lev := Vector3i(x0 - 1, y, lz)
	wr.place_device(lev, &"lever", true)
	# The camera by the row's +x end, looking along it.
	w._fly_to(Vector3((x0 + 14) * stud, y * plate + 1.0, (lz + 3) * stud), Vector3(-1, 0, 0))
	await w._frames(30)
	var cap := wr.lamp_light_cap()
	var shown := 0
	for c in wr.get_children():
		if c is OmniLight3D and (c as OmniLight3D).visible and str(c.name).begins_with("LampLight"):
			shown += 1
	var lit := lamps.filter(func(c): return wr.is_lit(c)).size()
	# Other sections' lamps may be lit too (far off): the lights must be on
	# the cap's worth of this row nearest the camera, and no more lights out
	# than the cap.
	var near_ok := true
	for k in mini(cap, 12):
		near_ok = near_ok and wr.lamp_light_of.has(lamps[11 - k])
	var mine := lamps.filter(func(c): return wr.lamp_light_of.has(c)).size()
	g.check("gaps: 12 lamps lit, %d real lights in all (cap %d), %d on this row's nearest" % [shown, cap, mine],
			lit == 12 and shown == cap and near_ok and mine == mini(cap, 12))
	for l in lamps:
		wr.remove_device(l, false)
	for x in range(x0, x0 + 12):
		wr.remove_cable(Vector3i(x, y, lz), false)
	wr.remove_device(lev, false)
	await w._frames(4)
	g.check("gaps: the lamps gone, none of them has a light; lights out %d (cap %d)" % [wr.lamp_light_of.size(), cap],
			lamps.all(func(c): return not wr.lamp_light_of.has(c)) and wr.lamp_light_of.size() <= cap)


# --- 4. gate tiles fall (Docs/MineWiring.md 23)
func _gatetiles() -> void:
	var tz := z0 + 6
	var tx := x0 + 2
	# A trench 4 studs long at z = tz, 2 courses deep, past x = tx.
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(tx + 1, top - 5, tz), Vector3i(tx + 4, top, tz), 0, false))
	await w._frames(10)
	var row: Array[Vector3i] = []
	var ok := true
	for k in 5:
		var c := Vector3i(tx + k, y, tz)
		ok = ok and wr.place_device(c, &"gate_tile")
		row.append(c)
	await w._frames(16)
	g.check("gaps: a bridge of 5 gate tiles hangs off the one at the trench's edge", ok
			and row.all(func(c): return wr.devices.has(c)))
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(tx, top - 5, tz), Vector3i(tx, top, tz), 0, false))
	await w._frames(16)
	g.check("gaps: its ground dug out: the whole bridge falls", row.all(func(c): return not wr.devices.has(c)))


# --- 6. trapdoor drops a player on foot (Docs/MineWiring.md 25)
func _trapdoor() -> void:
	var px := x0 + 16
	var pz := z0 + 4
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(px, top - 8, pz), Vector3i(px + 1, top, pz + 1), 0, false))
	await w._frames(10)
	var trap := Vector3i(px, top, pz)
	g.check("gaps: a trapdoor over a pit", wr.place_device(trap, &"trapdoor", false, false, 0))
	var lev := Vector3i(px + 2, y, pz)
	wr.place_device(lev, &"lever")
	var stand := Vector3((px + 1) * stud, (top + 1) * plate + 0.05, (pz + 1) * stud)
	w.set_on_foot(true, stand)
	await w._frames(30)
	var feet0: Vector3 = w.player_feet_local()
	g.check("gaps: on foot, standing on the shut trapdoor (feet %.2f, its top %.2f)" % [feet0.y, (top + 1) * plate],
			absf(feet0.y - (top + 1) * plate) < 0.12)
	wr.use_device(lev)
	await w._frames(60)
	var feet1: Vector3 = w.player_feet_local()
	g.check("gaps: the lever opens it and the player falls into the pit (feet %.2f, the pit's floor %.2f)" %
			[feet1.y, (top - 8) * plate], wr.is_open(trap) and feet1.y < top * plate - 0.4)
	w.set_on_foot(false)
	await w._frames(4)
	w._fly_to(Vector3(px * stud, y * plate + 3.0, (pz - 4) * stud), Vector3(0, 0, 1))
	wr.remove_device(trap, false)
	wr.remove_device(lev, false)


# --- 5. the sequencer's program editor (Docs/MineWiring.md 24)
func _sequencer() -> void:
	var sz := z0 + 13
	var lev := Vector3i(x0 + 1, y, sz)
	var sq := Vector3i(x0 + 2, y, sz)
	var lamp := Vector3i(x0 + 3, y, sz)
	wr.place_device(lev, &"lever")
	wr.place_device(sq, &"sequencer", false, false, 0, 0)
	wr.place_device(lamp, &"lamp")
	g._hold(&"cable")
	w.builder.set_active(true)
	w.builder.target = {"device": sq}
	w.builder.place_target()
	await w._frames(3)
	var p: SequencerPanel = w.seq_panel
	g.check("gaps: RMB on a sequencer opens its program editor; the builder waits (inventory_open)",
			p != null and p.is_open() and w.inventory_open() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	if p == null:
		return
	p.type_steps([3, 4, 3])
	await w._frames(2)
	await w._key(KEY_ESCAPE)
	await w._frames(2)
	g.check("gaps: a real Escape closes the panel, not into the pause menu", (not is_instance_valid(p) or not p.is_open())
			and w.seq_panel == null and not w.inventory_open() and not w.get_tree().paused)
	w.builder.set_active(false)
	wr.use_device(lev)
	var pattern := ""
	var t0: int = wr.ticks
	while wr.ticks < t0 + 14:
		await w._frames(1)
		if wr.ticks > t0 + int(pattern.length()):
			pattern += "1" if wr.is_lit(lamp) else "0"
	g.check("gaps: the typed program 3 on, 4 off, 3 on lights its lamp so (%s)" % pattern,
			pattern.count("1") >= 5 and pattern.count("1") <= 7 and pattern.contains("0000"))
	var n_dev: int = wr.devices.size()
	w.generate(w.settings)
	await w._frames(30)
	g.check("gaps: after generating again its program is kept (%s)" % str(wr.program_of(sq)),
			wr.devices.size() == n_dev and wr.program_of(sq) == [3, 4, 3])
	wr.remove_device(lev, false)
	wr.remove_device(sq, false)
	wr.remove_device(lamp, false)


# --- 7. the piston's stand-in look, and fallen pieces shoved (Docs/MineWiring.md 26)
func _pistons() -> void:
	var px := x0 + 6
	var pz := z0 + 14
	w._fly_to(Vector3((px - 4) * stud, y * plate + 2.5, (pz - 5) * stud), Vector3(1, 0, 1).normalized())
	# A plain piston facing up under a 2x2 placed brick: catch the stand-in.
	var pu := Vector3i(px, y, pz)
	wr.place_device(pu, &"piston", false, false, MineWiring.FACE_UP)
	g._lay_brick(pu + Vector3i(0, 3, 0), 2, 2, BrickTerrain.MAT_STONE)
	await w._frames(16)
	var lev := Vector3i(px - 1, y, pz)
	wr.place_device(lev, &"lever", true)
	var look := ""
	for i in 60:
		await w._frames(1)
		for m in wr._moves:
			var bm := (m.node as Node).get_node_or_null("Bricks") as MultiMeshInstance3D if is_instance_valid(m.node) else null
			if bm != null and look == "":
				look = "bevel %s, brick material %s, %d bricks" % [bm.multimesh.mesh == BrickNear.bevel_box_mesh(),
						bm.material_override == wr.standin_brick_material(), bm.multimesh.instance_count]
		if look != "":
			break
	g.check("gaps: a push's stand-in draws bevelled bricks in the brick material (%s)" % look,
			look.begins_with("bevel true, brick material true") and wr.standin_brick_material() != null)
	await g._settle()
	wr.use_device(lev)
	await g._settle()
	# A piston facing +x; a 2x2 brick dropped from 5 courses up lands in front.
	var ps := Vector3i(px + 6, y, pz)
	wr.place_device(ps, &"piston", false, false, 0)
	var lev2 := Vector3i(px + 5, y, pz)
	wr.place_device(lev2, &"lever")
	await w._frames(16)
	g._lay_brick(Vector3i(ps.x + 1, y + 15, pz), 2, 2, BrickTerrain.MAT_STONE)
	var pp = w.collapse.pieces if w.collapse != null else null
	var piece = null
	var at: Vector3 = w.to_global(Vector3((ps.x + 2) * stud, (y + 1) * plate, (pz + 1) * stud))
	for i in 360:
		await w._frames(1)
		if pp != null:
			var near: Array = pp.pieces_near(at, 0.4)
			if not near.is_empty() and near[0].settled:
				piece = near[0]
				break
	g.check("gaps: a dropped brick fell as a piece and settled in front of the piston", piece != null)
	if piece == null:
		return
	var p0: Vector3 = piece.body.global_position
	var n0: int = wr.pieces_shoved
	wr.use_device(lev2)
	await w._frames(60)
	var moved: float = (piece.body.global_position - p0).length() if is_instance_valid(piece.body) else -1.0
	g.check("gaps: the piston's head shoved the piece (%d shoved, moved %.2f m)" % [wr.pieces_shoved - n0, moved],
			wr.pieces_shoved > n0 and moved > 0.1)
	wr.use_device(lev2)
	await g._settle()
