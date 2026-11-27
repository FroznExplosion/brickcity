extends RefCounted
## -- --gate=mobs (Docs/MineCreatures.md 7): the creatures in the real mine
## world, on a walled stone arena laid by the spawn.
##
##   godot --path . scenes/terrain_test.tscn -- --gate=mobs
##
## What each check is for:
##   chase     a zombie 12 m off walks to the player on the shared flow field
##             and hits (a shove: the player cannot be hurt yet).
##   gap       a wall 2 bricks high across the arena with a 2-stud gap: the
##             zombie comes round through the gap.
##   shut out  the gap closed: it cannot get in, waits by the wall, no hits --
##             zombies cannot break bricks or climb 2 bricks.
##   step      the wall cut to 1 brick: it steps over and reaches the player.
##   trample   a zombie falling 4 bricks onto a carrot tramples it; a pig
##             falling 1 brick onto one does not, 3 bricks does (pig 2, zombie 3).
##   scent     a pig herd 11 m off, the player standing still: with the wind
##             blowing from the player to them notice fills faster than with
##             it blowing from them to the player.
##   flee      a shot (the gun's `fired`) sends the herd off together: the
##             herd's middle moves away and they stay bunched.
##   crops     a calm herd walks to open carrots and eats them back.
##   fences    a fence item placed through the builder lays a panel; a field
##             ringed by a 2-brick fence is not eaten and the pigs find no way
##             in; a zombie outside the ring never reaches the player inside.
##   pictures  user://dev/mobs_zombie.png, mobs_pigs.png, mobs_fence.png.
## Preloaded by mine_world.gd (`--gate=mobs`).

var w: Node = null
var m: MineMobs = null
var fails: Array[String] = []
var stud := 0.35
var plate := 0.14
var top := 0
var x0 := 0
var z0 := 0
const SIZE := 96


func check(what: String, ok: bool) -> void:
	print("[mobs-gate] %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		fails.append(what)


func run(host: Node) -> void:
	w = host
	m = w.mobs
	FarmPlant.trouble = false
	stud = BrickWorld.get_stud_metres()
	plate = BrickWorld.get_plate_metres()
	w._time = 0.5
	w.set_on_foot(false)
	await w._frames(30)
	w.builder.aim_trees = false
	_arena()
	await w._frames(40)
	await _zombie_checks()
	await _trample_checks()
	await _pig_checks()
	await _fence_checks()
	print("[mobs-gate] fields built %d, last %.1f ms; nav %s" % [m.fields_built, m.last_field_ms, m.nav.get_stats()])
	print("[mobs-gate] %s" % ("MOBS-GATE PASS" if fails.is_empty() else "MOBS-GATE FAIL: " + "; ".join(fails)))
	w.get_tree().quit(0 if fails.is_empty() else 1)


# ---------------------------------------------------------------------------
# The arena: SIZE x SIZE studs of stone, cleared over, walled round 3 bricks.

func _arena() -> void:
	var eye: Vector3 = w._eye()
	# On the 6-stud lattice, so fence rings and plots line up (see _ring).
	x0 = floori(eye.x / stud / 6.0) * 6 + 6
	z0 = floori(eye.z / stud / 6.0) * 6 - SIZE / 2
	var s0 := BrickTerrain.surface_plate(x0, z0)
	top = floori(float(s0 + 1) / 3.0) * 3 - 1
	# Cleared over in slabs (fill_box refuses a box of more than 200k cells).
	for zs in range(z0 - 1, z0 + SIZE + 1, 16):
		w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 - 1, top + 1, zs), Vector3i(x0 + SIZE, top + 45, mini(zs + 15, z0 + SIZE)), 0, false))
	# Its trees felled: a test of walls and gaps, not of trunks (those are
	# terrain_nav_probe's and MineMobs.trunk_boxes').
	var felled := 0
	var trees = w._trees
	for c in trees._cells.keys():
		for row in (trees._cells[c] as Array).duplicate():
			if int(row.x) >= x0 - 2 and int(row.x) <= x0 + SIZE + 2 and int(row.z) >= z0 - 2 and int(row.z) <= z0 + SIZE + 2:
				trees.fell(Vector2i(int(row.x), int(row.z)))
				felled += 1
	print("[mobs-gate] arena at column (%d, %d), ground plate %d, %d trees felled" % [x0, z0, top, felled])
	# Solid under it, deep: cleared hills over a cave would otherwise come down
	# (the ground's collapse) and take the floor with them.
	for zs in range(z0 - 1, z0 + SIZE + 1, 16):
		w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 - 1, top - 36, zs), Vector3i(x0 + SIZE, top - 7, mini(zs + 15, z0 + SIZE)), BrickTerrain.MAT_STONE, false))
	for res in [BrickTerrain.fill_box(Vector3i(x0 - 1, top - 6, z0 - 1), Vector3i(x0 + SIZE, top - 1, z0 + SIZE), BrickTerrain.MAT_DIRT, false),
			BrickTerrain.fill_box(Vector3i(x0 - 1, top, z0 - 1), Vector3i(x0 + SIZE, top, z0 + SIZE), BrickTerrain.MAT_GRASS, false),
			# The ring wall, 3 bricks: nothing walks out round the tests' walls.
			BrickTerrain.fill_box(Vector3i(x0 - 1, top + 1, z0 - 1), Vector3i(x0 + SIZE, top + 9, z0 - 1), BrickTerrain.MAT_STONE, false),
			BrickTerrain.fill_box(Vector3i(x0 - 1, top + 1, z0 + SIZE), Vector3i(x0 + SIZE, top + 9, z0 + SIZE), BrickTerrain.MAT_STONE, false),
			BrickTerrain.fill_box(Vector3i(x0 - 1, top + 1, z0 - 1), Vector3i(x0 - 1, top + 9, z0 + SIZE), BrickTerrain.MAT_STONE, false),
			BrickTerrain.fill_box(Vector3i(x0 + SIZE, top + 1, z0 - 1), Vector3i(x0 + SIZE, top + 9, z0 + SIZE), BrickTerrain.MAT_STONE, false)]:
		w.terrain_edited(res)


## Feet on the arena at column (x, z) from its corner (terrain frame).
func _at(x: float, z: float, up_plates := 0) -> Vector3:
	return Vector3((x0 + x) * stud, (top + 1 + up_plates) * plate, (z0 + z) * stud)


func _player_to(p: Vector3, look_at := Vector3.INF) -> void:
	w.set_on_foot(true, p)
	await w._frames(4)
	if look_at != Vector3.INF:
		FpsRig.face(w.cam, w.pawn, (look_at - p).normalized())


func _edit(lo: Vector3i, hi: Vector3i, mat: int) -> void:
	w.terrain_edited(BrickTerrain.fill_box(lo, hi, mat, false))


## Wait until `cond` is true or `secs` pass; true if it came true.
func _until(cond: Callable, secs: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		if cond.call():
			return true
		await w._frames(1)
	return cond.call()


func _kill_all() -> void:
	for x in m.mobs:
		if is_instance_valid(x) and not x.dead:
			x.pawn.health.apply_impact(9999.0, &"")
	await w._frames(30)
	m.mobs.clear()
	m.herds.clear()


## Where a zombie stands stuck: the nav's next step and the cells round it.
func _dump_stuck(z: MobZombie) -> void:
	var f := z.feet()
	var n: Vector3 = m.field_next(f)
	print("[mobs-gate]   stuck at %s (col %.1f, %.1f, plate %.1f), next %s" % [f, f.x / stud - x0, f.z / stud - z0, f.y / plate, n])
	var cx := floori(f.x / stud)
	var cz := floori(f.z / stud)
	var cy := floori(f.y / plate)
	for dz in range(-3, 4):
		var line := ""
		for dx in range(-3, 4):
			var h := 0
			for yy in range(cy, cy + 14):
				if BrickTerrain.solid_at(cx + dx, yy, cz + dz) != 0:
					h = yy - cy + 1
			line += "%3d" % h
		print("[mobs-gate]     z%+d %s" % [dz, line])
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.6
	q.shape = sh
	q.transform = Transform3D(Basis(), z.pawn.body.global_position)
	q.collision_mask = Layers.PAWN_MASK
	q.exclude = [z.pawn.body.get_rid()]
	for hit in z.pawn.body.get_world_3d().direct_space_state.intersect_shape(q, 8):
		var col = hit.get("collider")
		print("[mobs-gate]     touching %s (layer %s)" % [col, col.get("collision_layer") if col != null else hit.get("rid")])


func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ---------------------------------------------------------------------------

func _zombie_checks() -> void:
	var me := _at(80, 48)
	await _player_to(me, _at(20, 48))
	var z := m.spawn_zombie(m.nav.stand_near(_at(20, 48), MobZombie.BODY, 4))
	var used_field := [false]
	var close := await _until(func() -> bool:
			used_field[0] = used_field[0] or z.on_field
			return _flat_dist(z.feet(), m.player_feet()) < 1.6, 25.0)
	await _until(func() -> bool: return z.hits > 0, 4.0)
	check("chase: a zombie 21 m off reaches the player (%.1f m, on the field %s)" % [_flat_dist(z.feet(), m.player_feet()), used_field[0]],
			close and used_field[0])
	check("chase: it hits the player (%d hits)" % z.hits, z.hits > 0)
	await w._shot("user://dev/mobs_zombie.png")

	# A wall 2 bricks high across the arena at x = 48, with a 2-stud gap.
	_edit(Vector3i(x0 + 48, top + 1, z0), Vector3i(x0 + 48, top + 6, z0 + SIZE - 1), BrickTerrain.MAT_STONE)
	_edit(Vector3i(x0 + 48, top + 1, z0 + 60), Vector3i(x0 + 48, top + 6, z0 + 61), 0)
	z.pawn.place(m.to_world(m.nav.stand_near(_at(24, 24), MobZombie.BODY, 4)))
	await _player_to(_at(72, 24), _at(24, 24))
	var via_gap := [false]
	var dbg := [0]
	var got := await _until(func() -> bool:
			var f := z.feet()
			dbg[0] += 1
			if dbg[0] % 120 == 0:
				print("[mobs-gate]   zombie %s at col (%.1f, %.1f) on_field %s field %d cost %.1f path %d reached %s" % [z.state,
						f.x / stud - x0, f.z / stud - z0, z.on_field, m.field_id, m.field_cost(f), z._path.size(), z.path_reached])
			if absf(f.x / stud - (x0 + 48.5)) < 1.5:
				var cz := f.z / stud - z0
				via_gap[0] = via_gap[0] or (cz > 58.0 and cz < 64.0)
			return _flat_dist(f, m.player_feet()) < 1.6, 35.0)
	if not got:
		_dump_stuck(z)
	check("gap: round through the 2-stud gap in a 2-brick wall (reached %s, crossed at the gap %s)" % [got, via_gap[0]], got and via_gap[0])

	# Shut the gap: it cannot get in.
	_edit(Vector3i(x0 + 48, top + 1, z0 + 60), Vector3i(x0 + 48, top + 6, z0 + 61), BrickTerrain.MAT_STONE)
	z.pawn.place(m.to_world(m.nav.stand_near(_at(24, 24), MobZombie.BODY, 4)))
	await w._frames(10)
	var hits0 := z.hits
	await _until(func() -> bool: return false, 12.0)
	var zf := z.feet()
	check("shut out: never reaches the player behind a 2-brick wall (%.1f m off, %d hits)" % [_flat_dist(zf, m.player_feet()), z.hits - hits0],
			_flat_dist(zf, m.player_feet()) > 3.0 and z.hits == hits0)
	check("shut out: it waits by the wall (%.1f m from it)" % (absf(zf.x / stud - (x0 + 48)) * stud), absf(zf.x / stud - (x0 + 48)) * stud < 1.5)

	# Cut the wall to 1 brick: it steps over.
	_edit(Vector3i(x0 + 48, top + 4, z0), Vector3i(x0 + 48, top + 6, z0 + SIZE - 1), 0)
	var over := await _until(func() -> bool: return _flat_dist(z.feet(), m.player_feet()) < 1.6, 20.0)
	check("step: over a 1-brick wall to the player", over)
	_edit(Vector3i(x0 + 48, top + 1, z0), Vector3i(x0 + 48, top + 3, z0 + SIZE - 1), 0)
	await _kill_all()


## A carrot on a tilled plot at arena column (x, z) (even): its b.
func _carrot(x: int, z: int) -> Vector3i:
	var f: MineFarming = w.farming
	var cx := x0 + x
	var cz := z0 + z
	f.till({"cell": Vector3i(cx, top, cz), "normal": Vector3i.UP})
	var tilled := f.till({"cell": Vector3i(cx, top, cz), "normal": Vector3i.UP})
	var planted := f.plant({"cell": Vector3i(cx, top, cz), "normal": Vector3i.UP}, &"carrot")
	if not planted:
		print("[mobs-gate]   carrot at (%d, %d) tilled %s planted %s: %s" % [x, z, tilled, planted, f.log_lines.slice(-3)])
	return Vector3i(floori(cx / 2.0), top, floori(cz / 2.0))


func _trample_checks() -> void:
	var f: MineFarming = w.farming
	await _player_to(_at(88, 88))
	var bz := _carrot(20, 84)
	var bp1 := _carrot(30, 84)
	var bp3 := _carrot(40, 84)
	await w._frames(5)
	check("trample: three carrots planted", not f.store.get_plot(bz).is_empty() and not f.store.get_plot(bp1).is_empty()
			and not f.store.get_plot(bp3).is_empty() and f.store.get_plot(bz).crop != &"")
	var t0 := f.trampled
	var z := m.spawn_zombie(Vector3((bz.x * 2 + 1) * stud, (top + 1 + 12) * plate, (bz.z * 2 + 1) * stud))
	z.held = true      # no chasing off the plot before it lands
	await _until(func() -> bool: return z.pawn.is_on_floor(), 4.0)
	await w._frames(5)
	check("trample: a zombie falling 4 bricks onto a carrot tramples it (fell %.2f m)" % z.pawn.last_fall,
			f.trampled == t0 + 1 and f.store.get_plot(bz).is_empty())
	var h := m.spawn_herd(_at(2, 2), 2)
	var p1 = h.members[0]
	var p3 = h.members[1]
	h.blind = true
	p1.held = true
	p3.held = true
	p1.pawn.place(m.to_world(Vector3((bp1.x * 2 + 1) * stud, (top + 1 + 3) * plate, (bp1.z * 2 + 1) * stud)))
	p3.pawn.place(m.to_world(Vector3((bp3.x * 2 + 1) * stud, (top + 1 + 9) * plate, (bp3.z * 2 + 1) * stud)))
	await _until(func() -> bool: return p1.pawn.is_on_floor() and p3.pawn.is_on_floor(), 4.0)
	await w._frames(5)
	check("trample: a pig falling 1 brick does not (fell %.2f m)" % p1.pawn.last_fall, not f.store.get_plot(bp1).is_empty())
	check("trample: a pig falling 3 bricks does (fell %.2f m)" % p3.pawn.last_fall, f.store.get_plot(bp3).is_empty())
	# Clear what is left for the pigs' own checks.
	if not f.store.get_plot(bp1).is_empty():
		f.trample(f.store.get_plot(bp1))
	await _kill_all()


func _pig_checks() -> void:
	var me := _at(72, 48)
	var h := m.spawn_herd(_at(40, 48), 3)
	check("a herd of 3 pigs", h.alive().size() == 3)
	await _player_to(me, _at(40, 48))
	await w._frames(20)
	# Wind from the pigs to the player: the player is downwind, nothing to smell.
	m.set_wind((me - h.centre()).normalized())
	h.notice = 0.0
	h.alert = PigHerd.Alert.CALM
	await _until(func() -> bool: return false, 5.0)
	var down := h.notice
	m.set_wind((h.centre() - me).normalized())
	h.notice = 0.0
	h.alert = PigHerd.Alert.CALM
	await _until(func() -> bool: return false, 5.0)
	var up := h.notice
	check("scent: notice fills faster upwind of them (%.2f) than downwind (%.2f)" % [up, down], up > down + 0.1)
	check("standing still 11 m off, downwind, they stay calm or wary, not off (%.2f)" % down, down < PigHerd.FLEE_AT)
	await w._shot("user://dev/mobs_pigs.png")
	# A shot: the gun's `fired` (the hook MineMobs puts on it).
	for p in h.alive():
		p.pawn.place(m.to_world(m.nav.stand_near(h.slot(p.index, _at(40, 48)), MobPig.BODY, 4)))
	h.anchor = _at(40, 48)
	h.home = h.anchor
	await w._frames(20)
	var c0 := h.centre()
	h.notice = 0.0
	h.alert = PigHerd.Alert.CALM
	w.gun.fired.emit({})
	await w._frames(2)
	check("flee: a shot sends them off (%s)" % h.alert_name(), h.alert == PigHerd.Alert.FLEE)
	await _until(func() -> bool: return false, 7.0)
	var c1 := h.centre()
	var spread := 0.0
	for p in h.alive():
		spread = maxf(spread, _flat_dist(p.feet(), c1))
	check("flee: the herd moved off together (%.1f m away from the player, %.1f m further; spread %.1f m)"
			% [_flat_dist(c1, me), _flat_dist(c1, me) - _flat_dist(c0, me), spread],
			_flat_dist(c1, me) > _flat_dist(c0, me) + 4.0 and spread < 5.0)
	# Crops: calm and blind, three carrots 7 m off.
	h.blind = true
	h.notice = 0.0
	h.alert = PigHerd.Alert.CALM
	var f: MineFarming = w.farming
	var e0 := f.eaten
	var crops := [_carrot(50, 20), _carrot(52, 20), _carrot(54, 20)]
	var ate := await _until(func() -> bool: return f.eaten > e0, 40.0)
	check("crops: a calm herd walks to open carrots and eats (%d bites)" % (f.eaten - e0), ate)
	for b in crops:
		var plot := f.store.get_plot(b)
		if not plot.is_empty():
			f.trample(plot)
	_herd = h


var _herd: PigHerd = null


## A ring of fence panels round the stud box [ax, bx] x [az, bz] (multiples of 3).
func _ring(ax: int, az: int, bx: int, bz: int, plates: int) -> void:
	var mat := BrickTerrain.material_names().find("wood")
	for a in range(ax - 3, bx + 4, 3):
		for zz in [az, bz]:
			for r in MineFences.place(Vector3i(a, top + 1, zz), true, plates, mat):
				w.terrain_edited(r)
	for a in range(az - 3, bz + 4, 3):
		for xx in [ax, bx]:
			for r in MineFences.place(Vector3i(xx, top + 1, a), false, plates, mat):
				w.terrain_edited(r)


func _fence_checks() -> void:
	var f: MineFarming = w.farming
	# The builder's own way: a fence in the hand, RMB on the ground.
	var inv: Inventory = w.builder.inv
	inv.ensure_item(&"fence")
	if not inv.select_item(&"fence"):
		inv.pick(&"fence")
	await _player_to(_at(80, 76), _at(80, 60))
	var at := Vector3i(x0 + 80, top, z0 + 70)
	w.builder.target = {"cell": at, "normal": Vector3i.UP}
	var placed: bool = w.builder.place_target()
	var along_x := absf((w.cam as Node3D).global_transform.basis.x.x) >= absf((w.cam as Node3D).global_transform.basis.x.z)
	check("a fence item lays a panel through the builder (%s)" % placed, placed and MineFences.is_laid(at + Vector3i.UP, along_x, 6))
	# A field of 2 x 2 plots, ringed with a 2-brick fence.
	var ax := x0 + 12
	var az := z0 + 36
	_ring(ax, az, ax + 9, az + 9, 6)
	var field := []
	for i in 2:
		for k in 2:
			field.append(_carrot(15 + i * 2, 39 + k * 2))
	await w._frames(10)
	var h := _herd
	if h == null or h.alive().is_empty():
		h = m.spawn_herd(_at(44, 44), 3)
	h.blind = true
	h.alert = PigHerd.Alert.CALM
	for p in h.alive():
		p.pawn.place(m.to_world(m.nav.stand_near(_at(40, 44), MobPig.BODY, 6)))
	var e0 := f.eaten
	var logs0 := m.log_lines.size()
	await _until(func() -> bool: return false, 25.0)
	var no_way := false
	for i in range(logs0, m.log_lines.size()):
		no_way = no_way or m.log_lines[i].contains("no way")
	check("fences: a field ringed by a 2-brick fence is not eaten (%d bites)" % (f.eaten - e0), f.eaten == e0)
	check("fences: the pigs found no way in", no_way)
	await w._shot("user://dev/mobs_fence.png")
	# A zombie outside, the player inside the ring.
	await _kill_all()
	await _player_to(_at(17.0, 41.0))
	var z := m.spawn_zombie(m.nav.stand_near(_at(40, 40), MobZombie.BODY, 4))
	var inside := [false]
	await _until(func() -> bool:
			var zf := z.feet()
			var cx := zf.x / stud - x0
			var cz := zf.z / stud - z0
			inside[0] = inside[0] or (cx > 12.5 and cx < 21.5 and cz > 36.5 and cz < 45.5)
			return false, 15.0)
	check("fences: a zombie outside a 2-brick fence never gets in or hits the player inside (%.1f m, %d hits, got in %s)"
			% [_flat_dist(z.feet(), m.player_feet()), z.hits, inside[0]], z.hits == 0 and not inside[0])
	await _kill_all()
