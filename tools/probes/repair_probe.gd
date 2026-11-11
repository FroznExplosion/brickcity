extends SceneTree
## Repair (Docs/Hulls.md 9): the core (SpaceStation.restorable / restore, a RESTORE
## command, BrickWorld.revive_blocks) and the restore tool (RestoreTool), on a
## generated ship.
##
##     godot --headless --path . --script res://tools/probes/repair_probe.gd
##
##   shot      a blast through the hull (SpaceStation.damage, the hit path): bricks
##             lost, its room breached
##   rim       what is restorable starts at the hole's edge (beside a brick there)
##   tool      held on the hole for a second: about RATE bricks back, no more
##   riding    flying over a world, a restore is refused
##   exact     everything restored: nothing lost, every brick as built (part,
##             colour, full hp, the same id)
##   sealed    the breach sealed, the air filling again
##   replay    the same commands in the same order on a fresh ship give the same
##             bricks, alive and dead, brick for brick

var _pass := 0
var _fail := 0
var _st: SpaceStation
var _frames := 0
var _stage := 0
var _t := 0.0
var _room := -1
var _hole := Vector3.ZERO
var _built := {}   ## block -> [archetype, colour]
var _p_sealed := 0.0
var _shot_hp := PackedInt32Array()   ## every block's hp right after the shot


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _finish() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ship(sd: int) -> SpaceStation:
	var d := OrbitalData.new()
	d.kind = "ship"
	d.layout = "generated"
	d.orbital_name = "repair ship %d" % sd
	d.orbital_seed = sd
	var st := SpaceStation.new()
	root.add_child(st)
	st.setup(d)
	st.prepare()
	st.activate()
	return st


func _process(delta: float) -> bool:
	_frames += 1
	match _stage:
		0:
			print("repair probe")
			_st = _ship(1)
			_stage = 1
		1:
			if not _st.bricked:
				if _frames > 900:
					_ok("its bricks laid", false)
					_finish()
					return true
				return false
			for b in _st.bricks.get_block_count(_st.chunk):
				_built[b] = [_st.bricks.get_block_archetype(_st.chunk, b), _st.bricks.get_block_colour(_st.chunk, b)]
			_shoot()
			_stage = 2
		2:
			# A tick for the hit's solve, then the restore.
			_t += delta
			if _t < 0.2:
				return false
			_restore_checks()
			_t = 0.0
			_stage = 3
		3:
			_t += delta
			if _t < 0.5:
				return false
			var p := _st.air.pressure(_room)
			_ok("sealed: the breach closed, the air filling again", not _st.air.is_breached(_room)
					and _st.air.vent_rate(_room) == 0.0 and p > _p_sealed,
					"%.3f -> %.3f" % [_p_sealed, p])
			_replay_check()
			_finish()
			return true
	return false


## A blast through a hull brick beside a big room, through the hit path.
func _shoot() -> void:
	var air := _st.air
	var hb := -1
	for b in _st.bricks.get_block_count(_st.chunk):
		var ins := {}
		var out := false
		for i in air._block_cells(b):
			for j in air._neighbours(i):
				if air.state[j] == HullAir.INSIDE:
					ins[air._root(air.comp[j])] = true
				elif air.state[j] == HullAir.OUTSIDE:
					out = true
		if out and ins.size() == 1 and air._cells[air._root(ins.keys()[0])] > 1000:
			hb = b
			_room = ins.keys()[0]
			break
	if hb < 0:
		_ok("a hull brick to shoot", false)
		return
	var c := Vector3(air._cell(air._block_cells(hb)[0])) + Vector3(0.5, 0.5, 0.5)
	_hole = _st.global_transform * _st.frame * (c * BrickWorld.get_cell_size())
	_st.damage(_hole, {"blast": true, "radius": 1.2, "hp": 0})
	for b in _st.bricks.get_block_count(_st.chunk):
		_shot_hp.append(_st.bricks.get_block_hp(_st.chunk, b))
	var lost := _st.gone().size()
	_ok("shot: bricks lost, its room breached", lost > 0 and air.is_breached(_room),
			"%d brick(s) lost" % lost)


func _restore_checks() -> void:
	var air := _st.air
	var ids := _st.restorable(_hole, 50.0)
	var first := ids[0] if not ids.is_empty() else -1
	var rim := false
	if first >= 0:
		var own := {}
		for i in air._block_cells(first):
			own[i] = true
		for i in air._block_cells(first):
			for j in air._neighbours(i):
				rim = rim or (air.state[j] == HullAir.SOLID and not own.has(j))
	_ok("rim: what is restorable starts at the hole's edge", rim, "%d restorable" % ids.size())

	# Brick by brick (front end A): aimed at the hole, the ghost is one rim brick,
	# its box on its own cells; a tap lays it and nothing else.
	var tapper := RestoreTool.new()
	var up := Vector3.UP
	var eye := _hole - up * RestoreTool.RANGE
	var aimed := tapper.aim(eye, up, [_st])
	var gid: int = int(aimed.get("id", -1))
	var box_ok := false
	if gid >= 0:
		var c := Vector3i(_st.cell_at((aimed.xf as Transform3D).origin).floor())
		box_ok = _st.air._block_cells(gid).has(_st.air._idx(c)) and RestoreTool.rim_of(_st, gid)
	_ok("ghost: aimed at the hole, one rim brick shown on its own cells", gid >= 0 and box_ok,
			"brick %d" % gid)
	# The ghost is the brick itself: its shape as built, put where the brick goes
	# (its mesh's box holds the centre of the brick's cells).
	var shape := RestoreTool.shape_of(_st, gid) if gid >= 0 else []
	var fits := false
	if not shape.is_empty():
		var bb: AABB = RestoreTool.place_of(_st, gid) * (shape[0] as ArrayMesh).get_aabb()
		var mid: Vector3 = RestoreTool.box_of(_st, gid).origin
		fits = bb.grow(0.05).has_point(mid) and bb.size.length() > 0.1
	_ok("ghost: the brick's own shape (part, colour), where the brick goes", fits,
			"%s" % (str(_st.air._recipe.part_of(_st.air._block_recipe[gid])) if gid >= 0 else "none"))
	var gone_before := _st.gone().size()
	var r0 := _st.bricks_restored
	tapper.tick(0.1, true, eye, up, [_st])
	var during := _st.bricks_restored - r0
	var tapped := tapper.tick(0.1, false, eye, up, [_st])
	_ok("tap: one brick, the ghosted one, and only on release", during == 0 and tapped == 1
			and _st.bricks_restored - r0 == 1 and _st.gone().size() == gone_before - 1
			and not _st.gone().has(gid), "%d during, %d on release" % [during, tapped])
	tapper.cost = 0
	tapper.tick(0.1, true, eye, up, [_st])
	_ok("tap: nothing laid with nothing left to lay (cost 0)", tapper.tick(0.1, false, eye, up, [_st]) == 0)

	# The pouch: not while the tool works, not ashore, REFILL a second aboard once idle.
	var pouch := RestoreTool.new()
	pouch.cost = 10
	var ashore := 0
	for i in 30:
		ashore += pouch.refill(0.1, false)
	var busy := 0
	for i in 10:
		pouch.tick(0.1, true, eye, up, [])
		busy += pouch.refill(0.1, true)
	pouch.tick(0.1, false, eye, up, [])
	var idle := 0
	for i in int((RestoreTool.REFILL_AFTER + 1.0) / 0.1):
		idle += pouch.refill(0.1, true)
	for i in 400:
		pouch.refill(0.1, true)
	_ok("pouch: refills aboard once idle, REFILL a second, never past POUCH", ashore == 0 and busy == 0
			and idle >= int(RestoreTool.REFILL) - 1 and idle <= int(RestoreTool.REFILL) + 1
			and pouch.cost == RestoreTool.POUCH, "ashore %d, busy %d, idle %d, full %d" % [ashore, busy, idle, pouch.cost])

	# The snap is made, not loaded: a short sound with something in it.
	var snap := RepairFx.snap_sound(0)
	var peak := 0
	for i in range(0, snap.data.size(), 2):
		peak = maxi(peak, absi(snap.data.decode_s16(i)))
	_ok("snap: a made sound, short and audible", snap.data.size() > 1000 and snap.data.size() < 22050 * 2 * 0.2
			and peak > 8000, "%d bytes, peak %d" % [snap.data.size(), peak])

	# The tool, held on the hole for a second (no physics here: it points RANGE
	# along the view, at the hole).
	var tool := RestoreTool.new()
	var dir := Vector3.UP
	var from := _hole - dir * RestoreTool.RANGE
	var before := _st.bricks_restored
	for i in 10:
		tool.tick(0.1, true, from, dir, [_st])
	var by_tool := _st.bricks_restored - before
	_ok("tool: held a second, it streams after HOLD, about RATE bricks a second and no more",
			by_tool > 0 and by_tool <= int(RestoreTool.RATE) and tool.laid == by_tool,
			"%d laid" % by_tool)
	tool.tick(0.1, false, from, dir, [_st])

	# Flying over a world: refused.
	_st.riding = true
	var refused := _st.restore(_st.restorable(_hole, 50.0), _hole, 50.0).is_empty() \
			and _st.restorable(_hole, 50.0).is_empty()
	_st.riding = false
	_ok("riding: a restore is refused while it flies", refused)

	# The rest.
	var back := _st.restore(_st.restorable(_hole, 50.0), _hole, 50.0)
	var wrong := []
	for b in _built:
		var w := _st.bricks
		if w.get_block_hp(_st.chunk, b) != 255 or w.get_block_archetype(_st.chunk, b) != int(_built[b][0]) \
				or w.get_block_colour(_st.chunk, b) != int(_built[b][1]):
			wrong.append(b)
	_ok("exact: nothing lost, every brick as built", _st.gone().is_empty() and wrong.is_empty()
			and _st.bricks.get_alive_block_count(_st.chunk) == _built.size(),
			"%d more back, %d gone, %d not as built %s" % [back.size(), _st.gone().size(), wrong.size(),
			str(wrong.slice(0, 5))])
	_p_sealed = air.pressure(_room)


## The ship's commands on a fresh ship of the same seed, in order.
func _replay_check() -> void:
	var b := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(b)
	var ch := b.create_chunk(Vector3i.ZERO, _st.recipe.chunk_dims())
	_st.recipe.build(b, ch, pal)
	b.set_chunk_transform(ch, _st.bricks.get_chunk_transform(_st.chunk))
	var kinds := {}
	var n := b.get_block_count(ch)
	var diff_shot := -1
	for e in _st.damage_log.entries:
		if e.kind == DamageLog.Kind.RESTORE and diff_shot < 0:
			# Up to the first restore: the shot, brick for brick.
			diff_shot = 0
			for i in n:
				if b.get_block_hp(ch, i) != _shot_hp[i]:
					diff_shot += 1
		DamageLog.apply_entry(b, ch, e)
		kinds[e.kind] = true
	var diff := 0
	for i in n:
		if b.get_block_hp(ch, i) != _st.bricks.get_block_hp(_st.chunk, i) 				or (b.get_block_hp(ch, i) > 0) != (_st.bricks.get_block_hp(_st.chunk, i) > 0):
			diff += 1
	_ok("replay: the same commands on a fresh ship, the same bricks", diff == 0 and diff_shot == 0
			and n == _built.size() and kinds.has(DamageLog.Kind.RESTORE),
			"%d commands; %d bricks differ after the shot, %d at the end" % [_st.damage_log.size(),
			diff_shot, diff])
	b.release_chunk(ch)
