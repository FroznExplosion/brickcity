extends SceneTree

## Acceptance probe for Docs/AIPlan.md P0 steps 2, 3 and 4, with real bodies
## falling in a real space:
##
##     godot --headless --path . --script tools/snapshot_probe.gd
##
##   step 4  every structural operation is a command. A host city collapses; its
##           log, replayed into a fresh world, is the same structure, and a
##           manager that does not decide breaks nothing on its own.
##   step 3  the lifecycle is announced: spawned, settled, changed, slept,
##           woken, removed, handed over.
##   step 2  a checkpoint. Taken twice -- mid-fall, and after everything settled,
##           a piece was shot (which wakes what is near it) and one was put to sleep --
##           and each loaded into a fresh world: the same buildings,
##           the same pieces where they were, moving as they were.
##
## The city's --shot pass checks step 4 again with the scene's own budgets and
## landings; this is the headless half, and the only place save/load is tested.

const STUD := 0.35
const FOOT_X := 20
const FOOT_Z := 16
const COURSES := 14
const TENSION := 9.3
## Frames after the collapse before the mid-fall checkpoint.
const FALL_FRAMES := 6
## Frames to wait for everything to settle.
const SETTLE_FRAMES := 400
## Ticks the host and a loaded copy each get to work through what was queued.
const PENDING_TICKS := 12

var _pass := 0
var _fail := 0
var _frames := 0
var _phase := 0
var _phase_frame := 0

var _host: Dictionary
var _events := {"spawned": 0, "settled": 0, "changed": 0, "slept": 0, "woken": 0,
		"handed_over": 0}
var _removed := {}
var _woken_ids: Array = []
var _slept_id := -1
var _snap_fall: PackedByteArray
var _snap_rest: PackedByteArray
var _expect_fall: Dictionary
var _expect_rest: Dictionary
var _snap_pending: PackedByteArray
var _expect_pending: Dictionary
## How many furniture blocks the toppling tower carries down.
var _furnished := 0


func _init() -> void:
	print("snapshot probe (AIPlan P0 steps 2-4)")
	_host = _make_city(true)
	var islands: IslandManager = _host.islands
	islands.piece_spawned.connect(func(_i): _events.spawned += 1)
	islands.piece_settled.connect(func(_i): _events.settled += 1)
	islands.piece_changed.connect(func(_i): _events.changed += 1)
	islands.piece_slept.connect(func(id, _r):
		_events.slept += 1
		_slept_id = id)
	islands.piece_woken.connect(func(isl):
		_events.woken += 1
		_woken_ids.append(isl.piece_id))
	islands.piece_removed.connect(func(_i, why): _removed[why] = int(_removed.get(why, 0)) + 1)
	(_host.registry as BuildingRegistry).handed_over.connect(func(_id): _events.handed_over += 1)
	physics_frame.connect(_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# ---------------------------------------------------------------------------
# A small city: a world, two towers, the ground, pieces, and an authority.
# ---------------------------------------------------------------------------

func _make_city(host: bool) -> Dictionary:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var ids := []
	for i in 2:
		ids.append(reg.register(FOOT_X, FOOT_Z, COURSES,
				Transform3D(Basis(), Vector3(i * 14.0, 0.0, 0.0))))

	# The ground, on the same layer the city's is.
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)

	var islands := IslandManager.new()
	root.add_child(islands)
	islands.setup(w, null, null)
	var authority := WorldAuthority.new()
	islands.decides = host
	islands.on_command = func(e: DamageLog.Entry) -> int:
		var done := authority.commit_entry(e)
		return done.seq if done != null else -1
	return {"world": w, "registry": reg, "islands": islands, "authority": authority,
			"ids": ids, "ground": ground}


func _chunk_of(c: Dictionary, id: int) -> int:
	var reg: BuildingRegistry = c.registry
	var b := reg.get_building(id)
	if b == null or b.toppled:
		return -1
	var chunk := reg.materialise(id)
	(c.world as BrickWorld).set_tension_per_stud(chunk, TENSION)
	return chunk


## What the city does after damage, as a host: solve, topple what is
## unbalanced, and cut out what hangs from nothing -- every step a command.
func _settle_building(c: Dictionary, id: int) -> void:
	var w: BrickWorld = c.world
	var islands: IslandManager = c.islands
	var authority: WorldAuthority = c.authority
	var chunk := _chunk_of(c, id)
	if chunk < 0:
		return
	var res: Dictionary = w.solve_stress(chunk)
	if int(res.get("failures", 0)) > 0:
		authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SOLVE, id, Vector3.ZERO, 0.0)
	var stability: Dictionary = w.check_stability(chunk)
	if not bool(stability.get("stable", true)):
		var piece := islands.record_topple(id)
		(c.registry as BuildingRegistry).hand_over(id)
		islands.adopt(chunk, null, null, 0, 4, [], piece, id)
		return
	for g in w.find_detached_groups(chunk):
		var piece := islands.record_detach(id, null, chunk, g)
		islands.spawn(chunk, g, Vector3.ZERO, Vector3.ZERO, piece, id)


func _blast(c: Dictionary, id: int, point: Vector3, radius: float) -> void:
	var chunk := _chunk_of(c, id)
	if chunk < 0:
		return
	var killed: PackedInt32Array = (c.world as BrickWorld).apply_hit(chunk, point, radius)
	if not killed.is_empty():
		(c.authority as WorldAuthority).commit(Engine.get_physics_frames(),
				DamageLog.Kind.BLAST, id, point, radius)


# ---------------------------------------------------------------------------

func _tick() -> void:
	_frames += 1
	_phase_frame += 1
	var islands: IslandManager = _host.islands
	islands.tick()
	match _phase:
		0:
			_collapse()
			_next()
		1:
			if _phase_frame == FALL_FRAMES:
				_expect_fall = _expectations(_host)
				_snap_fall = AreaSnapshot.capture(_host.authority.commands, islands).to_bytes()
				print("  (mid-fall checkpoint: %d moving, %d at rest, %d bytes)" % [
					_expect_fall.moving, _expect_fall.at_rest, _snap_fall.size()])
				_next()
		2:
			var moving := 0
			for isl in islands.islands:
				if isl.is_valid() and not isl.settled:
					moving += 1
			if moving == 0 or _phase_frame > SETTLE_FRAMES:
				_after_rest()
				_next()
		3:
			_check_load("mid-fall", _snap_fall, _expect_fall)
			_check_load("settled, shot, one asleep", _snap_rest, _expect_rest)
			_check_pending_load()
			_finish()


func _next() -> void:
	_phase += 1
	_phase_frame = 0


## Knock the base out of one tower so it sheds, and one side out of the other so
## it topples.
func _collapse() -> void:
	print("\na host city comes down")
	var ids: Array = _host.ids
	for x in 5:
		_blast(_host, ids[0], Vector3(0.6 + x * 1.4, 1.6, 0.2), 1.3)
		_blast(_host, ids[0], Vector3(0.6 + x * 1.4, 1.6, FOOT_Z * STUD - 0.2), 1.3)
	# The base out from under 70% of the second tower's footprint: its centre of
	# mass is then over nothing, and it has to go over rather than shed.
	for x in 5:
		for z in 6:
			for y in [0.4, 1.2]:
				_blast(_host, ids[1], Vector3(14.0 + 0.4 + x * 1.0, y, 0.4 + z * 1.0), 1.0)
	# Furniture in the toppling tower's rooms: laid as decorative blocks in empty
	# cells, which is what a room's contents are (RoomManifest.build_item). It
	# rides the piece down, is in no command, and a save still has to bring it
	# back. ADDED, never converted: flagging the tower's own bricks as furniture
	# would make the host's structure differ from every replay's, which is a
	# different -- and false -- claim.
	var w: BrickWorld = _host.world
	var c1 := _chunk_of(_host, ids[1])
	var one: int = (_host.registry as BuildingRegistry).palette["brick_1x1"]
	var dims := w.get_chunk_dims(c1)
	for y in range(dims.y - 12, 3, -9):
		for z in range(3, dims.z - 3, 3):
			for x in range(3, dims.x - 3, 4):
				if _furnished < 12 and w.can_place(c1, Vector3i(x, y, z), one):
					if w.place_block(c1, Vector3i(x, y, z), one, 5, true) >= 0:
						_furnished += 1
	_ok("the toppling tower has furniture in it", _furnished > 0, "%d block(s)" % _furnished)
	for id in ids:
		_settle_building(_host, id)
	var islands: IslandManager = _host.islands
	_ok("pieces came loose", islands.islands.size() > 0, "%d piece(s)" % islands.islands.size())


## Everything has stopped: prove the lifecycle, then put one piece to sleep and
## take the second checkpoint.
func _after_rest() -> void:
	var islands: IslandManager = _host.islands
	var authority: WorldAuthority = _host.authority
	var w: BrickWorld = _host.world

	# --- step 4: the log is the structure -------------------------------------
	print("\nstep 4: every structural operation is a command")
	var h := authority.commands
	var kinds := {}
	for e in h.entries:
		kinds[DamageLog.Kind.keys()[e.kind]] = int(kinds.get(DamageLog.Kind.keys()[e.kind], 0)) + 1
	print("  %d command(s): %s" % [h.size(), kinds])
	var born := {}
	var orphan := 0
	for e in h.entries:
		if e.kind == DamageLog.Kind.DETACH:
			born[DamageLog.piece_id(e.seq)] = true
		elif e.kind == DamageLog.Kind.TOPPLE:
			born[DamageLog.piece_id(e.seq)] = true
		if e.is_piece() and not born.has(e.target):
			orphan += 1
	_ok("every piece command names a piece an earlier command created", orphan == 0,
			"%d orphan(s)" % orphan)
	_ok("pieces were detached and toppled, and broke on landing",
			kinds.has("DETACH") and kinds.has("TOPPLE"), str(kinds))

	var fresh := _make_city(false)
	var rep := StructureReplayer.new(fresh.world, func(id: int, frame: int) -> int:
		return _chunk_of(fresh, id) if frame == 0 else -1)
	rep.on_toppled = func(id: int) -> void: (fresh.registry as BuildingRegistry).hand_over(id)
	rep.apply_all(h.entries)
	var same_b := _buildings_match(_host, fresh)
	var same_p := 0
	var n_p := 0
	for isl in islands.islands:
		if not isl.is_valid() or isl.piece_id < 0:
			continue
		n_p += 1
		if _structure_of(w, isl.chunk) == _structure_of(fresh.world, rep.piece_chunk(isl.piece_id)):
			same_p += 1
	_ok("the host's log replays into the host's buildings", same_b)
	_ok("and into every piece", n_p > 0 and same_p == n_p, "%d of %d, %d missed" % [
			same_p, n_p, rep.missed])

	# A manager that does not decide breaks nothing on its own.
	var follower: IslandManager = fresh.islands
	var first: BrickIsland = null
	for isl in islands.islands:
		if isl.is_valid() and isl.piece_id >= 0 and rep.piece_chunk(isl.piece_id) >= 0:
			first = isl
			break
	var some := rep.piece_chunk(first.piece_id)
	var shadow := follower.adopt(some, null, null, 0, 4, [], first.piece_id, 0)
	var before: int = (fresh.authority as WorldAuthority).commands.size()
	var alive := (fresh.world as BrickWorld).get_alive_block_count(some)
	follower.damage(shadow, _aim(fresh.world, shadow), 2.0)
	follower.shear(shadow, _aim(fresh.world, shadow), 2.0)
	follower.solve_island(shadow)
	follower.fracture_on_impact(shadow, 50.0)
	_ok("a manager that does not decide breaks nothing and records nothing",
			(fresh.world as BrickWorld).get_alive_block_count(some) == alive
			and fresh.authority.commands.size() == before)
	_free_city(fresh)

	# --- step 3: the lifecycle -------------------------------------------------
	print("\nstep 3: the lifecycle is announced")
	_ok("spawned", _events.spawned > 0, "%d" % _events.spawned)
	_ok("settled", _events.settled > 0, "%d" % _events.settled)
	_ok("changed", _events.changed > 0, "%d" % _events.changed)
	_ok("a toppled building is handed over", _events.handed_over == 1,
			"%d" % _events.handed_over)

	# Shoot the biggest piece: changed, and the command is its id.
	var big: BrickIsland = null
	for isl in islands.islands:
		if isl.is_valid() and isl.piece_id >= 0 and (big == null
				or w.get_alive_block_count(isl.chunk) > w.get_alive_block_count(big.chunk)):
			big = isl
	var changed_before: int = _events.changed
	var n_before := authority.commands.size()
	islands.damage(big, _aim(w, big), 1.5)
	var hit_logged := false
	for i in range(n_before, authority.commands.size()):
		var e: DamageLog.Entry = authority.commands.entries[i]
		if e.kind == DamageLog.Kind.PIECE_BLAST and e.target == big.piece_id:
			hit_logged = true
	_ok("a shot piece is changed, and the command names it", _events.changed > changed_before
			and hit_logged)

	# Sleep it: slept + removed(slept), and a record left behind.
	var index := islands.islands.find(big)
	var id := big.piece_id
	islands._sleep(big, index)
	_ok("put to sleep: slept, and removed as slept", _slept_id == id
			and int(_removed.get(&"slept", 0)) == 1)
	_expect_rest = _expectations(_host)
	_snap_rest = AreaSnapshot.capture(authority.commands, islands).to_bytes()
	print("  (at-rest checkpoint: %d piece(s), %d asleep, %d bytes)" % [
		_expect_rest.pieces.size(), _expect_rest.dormant, _snap_rest.size()])

	# Wake it again: woken, with the id it went to sleep with.
	var d: IslandManager.Dormant = islands.dormant[islands.dormant.size() - 1]
	islands.wake_dormant_near(d.record.box.get_center(), 1.0)
	_ok("woken, still the same piece", _woken_ids.has(id), "id %d, woken %s" % [id, _woken_ids])

	# --- a decision waiting at the moment of the save --------------------------
	# Shear a big piece: it is queued to be re-solved, and has not been. Save
	# right then, and let the host finish; a load has to finish the same way.
	var q: BrickIsland = null
	for isl in islands.islands:
		if isl.is_valid() and isl.piece_id >= 0 and isl.landmark \
				and w.get_alive_block_count(isl.chunk) > 30:
			q = isl
			break
	var loosened_before := islands.impact_blocks
	if q != null:
		islands.shear(q, _aim(w, q), 2.2)
	print("  (shear: piece %s, %d block(s), loosened %d)" % [
		q.piece_id if q != null else -1, w.get_alive_block_count(q.chunk) if q != null else 0,
		islands.impact_blocks - loosened_before])
	var waiting := islands.pending_state()
	_ok("a piece is waiting to be re-solved when the save is taken",
			(waiting.resolve as PackedInt32Array).size() > 0, str(waiting))
	_snap_pending = AreaSnapshot.capture(authority.commands, islands,
			{"dirty": [_host.ids[0]]}).to_bytes()
	for i in PENDING_TICKS:
		islands.tick()
	_expect_pending = _expectations(_host)


## What a checkpoint has to bring back: every building's structure, and every
## recorded piece's structure, transform, speed and rest.
func _expectations(c: Dictionary) -> Dictionary:
	var w: BrickWorld = c.world
	var out := {"buildings": {}, "pieces": {}, "moving": 0, "at_rest": 0, "dormant": 0}
	for id in c.ids:
		var b := (c.registry as BuildingRegistry).get_building(id)
		if b != null and not b.toppled and b.is_materialised():
			out.buildings[id] = _structure_of(w, b.chunk)
	for isl in (c.islands as IslandManager).islands:
		if not isl.is_valid() or isl.piece_id < 0:
			continue
		out.pieces[isl.piece_id] = {"structure": _structure_of(w, isl.chunk),
				"xform": isl.chunk_transform(), "linear": isl.body.linear_velocity,
				"at_rest": isl.settled, "furniture": _furniture_of(w, isl.chunk)}
		if isl.settled:
			out.at_rest += 1
		else:
			out.moving += 1
	for d in (c.islands as IslandManager).dormant:
		if d.piece_id >= 0:
			out.dormant += 1
	return out


func _check_load(label: String, bytes: PackedByteArray, want: Dictionary) -> void:
	print("\nstep 2: load the %s checkpoint into a fresh world" % label)
	var snap := AreaSnapshot.from_bytes(bytes)
	_ok("it reads back", snap != null)
	if snap == null:
		return
	var c := _make_city(true)
	var report := snap.restore(c.world, func(id: int, frame: int) -> int:
		return _chunk_of(c, id) if frame == 0 else -1,
		c.islands, func(id: int) -> void: (c.registry as BuildingRegistry).hand_over(id))
	# The game carries on from the loaded log: new commands follow it.
	(c.authority as WorldAuthority).commands = DamageLog.from_data(snap.commands)
	print("  %s" % report)
	_ok("every command applied", int(report.missed) == 0)
	var w: BrickWorld = c.world
	var same_b := true
	for id in want.buildings:
		var b := (c.registry as BuildingRegistry).get_building(id)
		if b == null or b.toppled or _structure_of(w, b.chunk) != want.buildings[id]:
			same_b = false
	_ok("the same buildings", same_b and want.buildings.size() > 0,
			"%d standing" % want.buildings.size())
	var got := {}
	for isl in (c.islands as IslandManager).islands:
		got[isl.piece_id] = isl
	var same := 0
	var placed := 0
	var moving := 0
	for id in want.pieces:
		var p: Dictionary = want.pieces[id]
		var isl: BrickIsland = got.get(id)
		if isl == null:
			continue
		if _structure_of(w, isl.chunk) == p.structure:
			same += 1
		if isl.chunk_transform().is_equal_approx(p.xform) and isl.settled == bool(p.at_rest):
			placed += 1
		if not isl.settled and isl.body.linear_velocity.is_equal_approx(p.linear):
			moving += 1
	_ok("every piece is back, brick for brick", same == want.pieces.size(),
			"%d of %d" % [same, want.pieces.size()])
	_ok("where it was, at rest or not as it was", placed == want.pieces.size(),
			"%d of %d" % [placed, want.pieces.size()])
	_ok("and a moving piece moving as it was", moving == int(want.moving),
			"%d of %d" % [moving, int(want.moving)])
	var furn_same := 0
	var furn_n := 0
	for id in want.pieces:
		var p: Dictionary = want.pieces[id]
		var isl: BrickIsland = got.get(id)
		furn_n += (p.furniture as PackedStringArray).size()
		if isl != null and _furniture_of(w, isl.chunk) == p.furniture:
			furn_same += 1
	_ok("and every piece carries the furniture it carried",
			furn_same == want.pieces.size() and furn_n == int(report.furniture),
			"%d of %d pieces, %d furniture block(s)" % [furn_same, want.pieces.size(), furn_n])
	_ok("the pieces that were asleep are asleep",
			(c.islands as IslandManager).dormant.size() == int(want.dormant),
			"%d of %d" % [(c.islands as IslandManager).dormant.size(), int(want.dormant)])
	# And it is a world the game can carry on in: a new command follows the log.
	var next_seq: int = (c.authority as WorldAuthority).commands.size()
	var any: BrickIsland = null
	for isl in (c.islands as IslandManager).islands:
		if isl.is_valid() and isl.piece_id >= 0:
			any = isl
			break
	if any != null:
		(c.islands as IslandManager).damage(any, _aim(c.world, any), 2.0)
		var last: DamageLog.Entry = (c.authority as WorldAuthority).commands.entries.back()
		_ok("a shot after loading is the next command in the log",
				last.seq >= next_seq and last.target == any.piece_id, "seq %d" % last.seq)
	_free_city(c)


## A point on a brick of this piece that is actually there, in world space.
func _aim(w: BrickWorld, isl: BrickIsland) -> Vector3:
	for bx in w.get_block_boxes(isl.chunk):
		if bool((bx as Dictionary).get("alive", true)):
			return isl.chunk_to_world((bx.pos as Vector3) + (bx.size as Vector3) * 0.5)
	return isl.body.global_position


## A checkpoint taken while a piece was waiting to be re-solved. Loaded, and
## given the same ticks the host had, it has to break the same way: the same
## pieces, with the same ids -- which is the log continuing exactly where the
## save stopped it.
func _check_pending_load() -> void:
	print("\nstep 2: load a checkpoint taken with a decision still queued")
	var snap := AreaSnapshot.from_bytes(_snap_pending)
	_ok("it reads back", snap != null)
	if snap == null:
		return
	var c := _make_city(true)
	var report := snap.restore(c.world, func(id: int, frame: int) -> int:
		return _chunk_of(c, id) if frame == 0 else -1,
		c.islands, func(id: int) -> void: (c.registry as BuildingRegistry).hand_over(id))
	(c.authority as WorldAuthority).commands = DamageLog.from_data(snap.commands)
	print("  %s" % report)
	_ok("the queued decision is queued again", int(report.pending) > 0, "%d" % int(report.pending))
	_ok("and the scene's own queue is handed back",
			(report.scene as Dictionary).get("dirty", []) == [_host.ids[0]], str(report.scene))
	for i in PENDING_TICKS:
		(c.islands as IslandManager).tick()
	var w: BrickWorld = c.world
	var got := {}
	for isl in (c.islands as IslandManager).islands:
		if isl.is_valid() and isl.piece_id >= 0:
			got[isl.piece_id] = isl
	var same := 0
	for id in _expect_pending.pieces:
		var isl: BrickIsland = got.get(id)
		if isl != null and _structure_of(w, isl.chunk) == _expect_pending.pieces[id].structure:
			same += 1
	_ok("it finishes breaking the way the host did, piece for piece",
			same == _expect_pending.pieces.size() and got.size() == _expect_pending.pieces.size(),
			"%d of %d host pieces matched, %d loaded" % [same, _expect_pending.pieces.size(), got.size()])
	_free_city(c)


## Furniture in a chunk, comparable: absolute cell and part name, sorted.
func _furniture_of(w: BrickWorld, chunk: int) -> PackedStringArray:
	var out := PackedStringArray()
	for f in AreaSnapshot.furniture_of(w, chunk):
		out.append("%s:%s" % [f[0], f[1]])
	out.sort()
	return out

func _buildings_match(a: Dictionary, b: Dictionary) -> bool:
	for id in a.ids:
		var ba := (a.registry as BuildingRegistry).get_building(id)
		var bb := (b.registry as BuildingRegistry).get_building(id)
		if ba.toppled != bb.toppled:
			return false
		if not ba.toppled and _structure_of(a.world, ba.chunk) != _structure_of(b.world, bb.chunk):
			return false
	return true


## Structural blocks, by the cell they fill and the part they are. See
## city_scene._structure_of for why cells and names rather than ids.
func _structure_of(w: BrickWorld, chunk: int) -> PackedStringArray:
	var out := PackedStringArray()
	if chunk < 0 or not w.is_chunk_alive(chunk):
		return out
	var origin := w.get_chunk_origin(chunk)
	for id in w.get_block_count(chunk):
		if w.is_block_decorative(chunk, id):
			continue
		var cell := StructureReplayer.block_cell(w, chunk, id)
		if cell == StructureReplayer.NO_CELL or not w.is_solid(chunk, origin + cell):
			continue
		out.append("%s:%s" % [origin + cell, w.get_archetype_name(w.get_block_archetype(chunk, id))])
	out.sort()
	return out


func _free_city(c: Dictionary) -> void:
	(c.islands as Node).queue_free()
	(c.ground as Node).queue_free()


func _finish() -> void:
	(_host.islands as IslandManager).on_command = Callable()
	_free_city(_host)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
