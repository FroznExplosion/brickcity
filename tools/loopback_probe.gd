extends SceneTree

## Co-op before there is a network. Docs/AIPlan.md P0.
##
## A host and a client, each with its own BrickWorld, joined by a fake wire that
## delays and reorders what it carries. Both sides act -- the host fires, the
## client fires, the host's physics shears -- and at the end the two worlds
## have to be the same world: the same bricks alive, the same joints severed, the
## same pieces. That is the claim every later phase of the AI work is checked
## against, twice: once as a host alone and once with a client beside it.
##
## Then the same with pieces, and real physics: a host city collapses -- a
## tower sheds, another topples, the pieces land and break -- and a client that
## never decides anything follows it through the wire. The client has to end with
## the same buildings, every piece brick for brick, and every piece that came to
## rest lying where the host's lies. That is the Docs/AIPlan.md P0 gate.

const STUD := 0.35
const PLATE := 0.14
const FOOT_X := 20
const FOOT_Z := 16
const COURSES := 20
## Building 1 sits this many studs along x from building 0.
const SPACING := 40

var failures := 0

## The fake wire. Messages wait here until _pump delivers them.
var _to_host: Array = []
var _to_client: Array = []
var _rng := RandomNumberGenerator.new()
var _tick := 0


func _init() -> void:
	_rng.seed = 7
	_check_roles()
	_check_agreement()
	_start_pieces()
	physics_frame.connect(_tick_pieces)


func _finish() -> void:
	print("")
	if failures == 0:
		print("[probe] PASS")
	else:
		print("[probe] FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)


func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  ok    %s%s" % [label, ("  " + detail) if detail else ""])
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  " + detail) if detail else ""])


## Two towers in a fresh world. `reverse` creates them in the opposite order, so
## the client's chunk ids differ from the host's -- commands must name buildings,
## never chunks, or this probe fails.
func _city(reverse: bool) -> Dictionary:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var chunks := {}
	var order := [1, 0] if reverse else [0, 1]
	for id in order:
		# TowerRecipe lays its bricks from grid cell zero, so each chunk is built
		# at the origin and then placed, which is what the city does too.
		var c := w.create_chunk(Vector3i.ZERO,
				TowerRecipe.chunk_dims(FOOT_X, FOOT_Z, COURSES))
		TowerRecipe.build(w, c, palette, FOOT_X, FOOT_Z, COURSES)
		w.set_chunk_transform(c, Transform3D(Basis.IDENTITY,
				Vector3(id * SPACING * STUD, 0.0, 0.0)))
		w.set_tension_per_stud(c, 9.3)
		chunks[id] = c
	return {"world": w, "chunks": chunks}


## Which building a bare point belongs to -- what the scene does with a blast
## that names no target.
func _building_at(point: Vector3) -> int:
	return 1 if point.x >= SPACING * STUD * 0.5 else 0


## A point on building `id`'s front wall at course `course`.
func _wall_point(id: int, course: int, along: float) -> Vector3:
	return Vector3(id * SPACING * STUD + along,
			course * TowerRecipe.PLATES_PER_COURSE * PLATE, 0.2)


# ---------------------------------------------------------------------------

func _check_roles() -> void:
	print("host and client roles")
	var host := WorldAuthority.new()
	var client := WorldAuthority.new()
	client.is_host = false
	var sent := []
	client.send_to_host = func(wire: Array) -> void: sent.append(wire)

	_ok("the host may apply its own request",
			host.request(DamageLog.Kind.BLAST, -1, Vector3.ONE, 1.0))
	_ok("a client may not apply its own request",
			not client.request(DamageLog.Kind.BLAST, -1, Vector3.ONE, 1.0))
	_ok("and the request went to the host instead", sent.size() == 1)
	_ok("only the host decides from physics", host.may_decide() and not client.may_decide())
	print("  (the next line is an expected error: a client trying to commit)")
	_ok("a client cannot commit",
			client.commit(0, DamageLog.Kind.BLAST, 0, Vector3.ONE, 1.0) == null)
	_ok("the log is on without being asked", host.commands.recording)


# ---------------------------------------------------------------------------

func _check_agreement() -> void:
	print("host and client end with the same world")
	var h := _city(false)
	var c := _city(true)
	var hw: BrickWorld = h.world
	var cw: BrickWorld = c.world
	var hc: Dictionary = h.chunks
	var cc: Dictionary = c.chunks
	print("  host chunks %s, client chunks %s" % [hc, cc])
	_ok("the client's chunk ids differ from the host's", hc[0] != cc[0])

	var host := WorldAuthority.new()
	var client := WorldAuthority.new()
	client.is_host = false

	# The wire, both ways, serialised the way a socket would carry it.
	client.send_to_host = func(wire: Array) -> void:
		_to_host.append(bytes_to_var(var_to_bytes(wire)))
	host.add_client(func(wire: Array) -> void:
		_to_client.append(bytes_to_var(var_to_bytes(wire))))

	# The host takes a client's shot exactly as it takes its own.
	host.handle_request = func(e: DamageLog.Entry) -> void:
		_host_act(host, hw, hc, e.kind, e.target, e.point, e.radius, e.normal, e.limit)

	# The client applies what the host committed, to its own chunk for that
	# building.
	var client_misses := [0]
	client.apply_entry = func(e: DamageLog.Entry) -> void:
		if not cc.has(e.target):
			client_misses[0] += 1
			return
		DamageLog.apply_entry(cw, int(cc[e.target]), e)

	var standing: int = hw.get_alive_block_count(int(hc[0]))
	_ok("both buildings stand before the fight",
			standing > 0 and hw.get_alive_block_count(int(hc[1])) == standing
			and cw.get_alive_block_count(int(cc[1])) == standing,
			"%d bricks each" % standing)
	var before := cw.get_chunk_content_hash(int(cc[0]))

	# A fight. Host shots, client shots, and shears from the host's physics,
	# interleaved, with the wire delivering late and out of order.
	for i in 12:
		var id := i % 2
		var p := _wall_point(id, 2 + i, 1.0 + (i % 5) * 0.8)
		if i % 3 == 1:
			# The client fires. Nothing may change on the client until the host
			# has decided.
			var asked := client.request(DamageLog.Kind.BLAST, -1, p, 1.3)
			if i == 1:
				_ok("a client's shot changes nothing before the host answers",
						not asked and cw.get_chunk_content_hash(int(cc[0])) == before)
		else:
			_host_act(host, hw, hc, DamageLog.Kind.BLAST, -1, p, 1.3)
		if i % 4 == 0 or i == 9:
			# A piece landed on the host. Only the host's physics counts.
			var shear_at := _wall_point(id, 3 + i, 3.0) + Vector3(0.0, 0.0, 2.2)
			if host.may_decide():
				_host_act(host, hw, hc, DamageLog.Kind.SHEAR, id, shear_at, 2.0,
						Vector3.ZERO, 14)
		if i % 5 == 4:
			_pump(host, client, true)

	# One cut across a whole storey, the way a SEVER lands.
	_host_act(host, hw, hc, DamageLog.Kind.SEVER, 0,
			Vector3(3.5, 9 * TowerRecipe.PLATES_PER_COURSE * PLATE, 2.8),
			0.42, Vector3.UP)
	_pump(host, client, true)
	_pump(host, client, false)

	_ok("every client request reached the host",
			host.requests_handled == client.requests_forwarded,
			"%d of %d" % [host.requests_handled, client.requests_forwarded])
	_ok("the client applied every committed command",
			client.entries_applied == host.commands.size() and client.held_count() == 0,
			"%d of %d, %d held" % [client.entries_applied, host.commands.size(),
			client.held_count()])
	_ok("out-of-order delivery was seen and put right", client.gaps_seen > 0,
			"%d gap(s)" % client.gaps_seen)
	_ok("every command found its building on the client", client_misses[0] == 0)
	_ok("the two logs are the same log",
			var_to_bytes(host.commands.to_data()) == var_to_bytes(client.commands.to_data()))

	# Both machines settle the structure the same way: the solve is integer.
	for id in [0, 1]:
		hw.solve_stress(int(hc[id]))
		cw.solve_stress(int(cc[id]))

	for id in [0, 1]:
		_compare(hw, int(hc[id]), cw, int(cc[id]), "building %d" % id)

	# And a player who joins now gets the same world from the log alone.
	var late := _city(false)
	var lw: BrickWorld = late.world
	var lc: Dictionary = late.chunks
	var joined := DamageLog.from_data(bytes_to_var(var_to_bytes(host.commands.to_data())))
	joined.replay(lw, func(target: int) -> int: return int(lc.get(target, -1)))
	for id in [0, 1]:
		lw.solve_stress(int(lc[id]))
	_ok("a late joiner replaying the log gets the host's world",
			lw.get_chunk_content_hash(int(lc[0])) == hw.get_chunk_content_hash(int(hc[0]))
			and lw.get_chunk_content_hash(int(lc[1])) == hw.get_chunk_content_hash(int(hc[1])))

	# The comparison has to be able to fail, or every ok above is decoration. A
	# client that applies its own shot instead of asking is exactly the bug the
	# authority exists to prevent; it must show.
	cw.apply_hit(int(cc[0]), _wall_point(0, 15, 2.0), 1.3)
	_ok("a client that applies its own shot is caught",
			cw.get_chunk_content_hash(int(cc[0])) != hw.get_chunk_content_hash(int(hc[0])))

	# The wiring holds lambdas that hold the authorities that hold them; cut the
	# loop so nothing outlives the probe.
	host.handle_request = Callable()
	client.send_to_host = Callable()
	client.apply_entry = Callable()
	host._clients.clear()


## The host applies a change to its own world and commits it -- the path both
## its own actors and a client's requests take.
func _host_act(host: WorldAuthority, hw: BrickWorld, hc: Dictionary,
		kind: DamageLog.Kind, target: int, point: Vector3, radius: float,
		normal := Vector3.ZERO, limit := 0) -> void:
	if not host.request(kind, target, point, radius, normal, limit):
		return
	var id := target if target >= 0 else _building_at(point)
	var e := DamageLog.Entry.new()
	e.kind = kind
	e.target = id
	e.point = point
	e.radius = radius
	e.normal = normal
	e.limit = limit
	var changed := DamageLog.apply_entry(hw, int(hc[id]), e)
	_tick += 1
	# The scene commits only what changed something; so does this.
	if not changed.is_empty():
		host.commit(_tick, kind, id, point, radius, normal, limit)


## Deliver what is on the wire. `shuffle` hands the client its entries in a
## random order, which is what an unreliable transport does and what the
## client's `seq` ordering exists to undo.
func _pump(host: WorldAuthority, client: WorldAuthority, shuffle: bool) -> void:
	# Requests first: the host decides, which may put more on the client's wire.
	while not _to_host.is_empty():
		var batch := _to_host.duplicate()
		_to_host.clear()
		for wire in batch:
			host.receive_request(wire)
	var out := _to_client.duplicate()
	_to_client.clear()
	if shuffle:
		for i in range(out.size() - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var t = out[i]
			out[i] = out[j]
			out[j] = t
	for wire in out:
		client.receive(wire)


## The things that must agree between machines: which bricks are alive, which
## joints are severed, and what pieces the structure falls into.
func _compare(a: BrickWorld, ca: int, b: BrickWorld, cb: int, label: String) -> void:
	_ok("%s: same bricks alive" % label,
			a.get_chunk_content_hash(ca) == b.get_chunk_content_hash(cb),
			"%d alive" % a.get_alive_block_count(ca))
	var n := a.get_block_count(ca)
	var broken_a := 0
	var differ := 0
	for i in n:
		var sa := a.is_support_broken(ca, i)
		if sa:
			broken_a += 1
		if sa != b.is_support_broken(cb, i):
			differ += 1
	# support_broken is what a stress failure marks. A peeled shear marks the
	# block's bottom_broken instead, which the extension does not expose -- but a
	# peel that went differently would split the structure differently, and the
	# pieces check below sees that.
	_ok("%s: same supports broken" % label, differ == 0,
			"%d broken, %d differ" % [broken_a, differ])
	var pa: Array = a.get_components(ca)
	var pb: Array = b.get_components(cb)
	var same := pa.size() == pb.size()
	if same:
		for k in pa.size():
			if PackedInt32Array(pa[k]) != PackedInt32Array(pb[k]):
				same = false
				break
	_ok("%s: same pieces" % label, same, "%d vs %d" % [pa.size(), pb.size()])

# ===========================================================================
# Pieces, with real physics
# ===========================================================================

const PIECE_COURSES := 14
const TENSION := 9.3
## Deliver the wire every this many physics frames, reordered: a transport
## that is late and out of order, all the way through a collapse.
const WIRE_EVERY := 4
const SETTLE_FRAMES := 450

var _p_host: Dictionary
var _p_client: Dictionary
var _p_host_auth: WorldAuthority
var _p_client_auth: WorldAuthority
var _p_rep: StructureReplayer
var _p_wire: Array = []
var _p_frame := 0
var _p_done := false


## Two towers in a world. Building ids are the same on every machine -- the city
## is generated the same everywhere -- but everse builds the bricks of the
## second one first, so the CHUNK ids differ, which is what a command must not
## depend on.
func _piece_city(reverse: bool) -> Dictionary:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var ids := []
	for i in 2:
		ids.append(reg.register(FOOT_X, FOOT_Z, PIECE_COURSES,
				Transform3D(Basis(), Vector3(i * 14.0, 0.0, 0.0))))
	if reverse:
		reg.materialise(ids[1])
		reg.materialise(ids[0])
	return {"world": w, "registry": reg, "ids": ids}


func _p_chunk(c: Dictionary, id: int) -> int:
	var reg: BuildingRegistry = c.registry
	var b := reg.get_building(id)
	if b == null or b.toppled:
		return -1
	var chunk := reg.materialise(id)
	(c.world as BrickWorld).set_tension_per_stud(chunk, TENSION)
	return chunk


func _start_pieces() -> void:
	print("pieces, with real physics, over the wire")
	_p_host = _piece_city(false)
	_p_client = _piece_city(true)

	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)

	_p_host_auth = WorldAuthority.new()
	var islands := IslandManager.new()
	root.add_child(islands)
	islands.setup(_p_host.world, null, null)
	islands.on_command = func(e: DamageLog.Entry) -> int:
		var done := _p_host_auth.commit_entry(e)
		return done.seq if done != null else -1
	_p_host["islands"] = islands

	# The client: it decides nothing, it has no bodies, it applies what arrives.
	_p_client_auth = WorldAuthority.new()
	_p_client_auth.is_host = false
	_p_rep = StructureReplayer.new(_p_client.world, func(id: int, frame: int) -> int:
		return _p_chunk(_p_client, id) if frame == 0 else -1)
	_p_rep.on_toppled = func(id: int) -> void: (_p_client.registry as BuildingRegistry).hand_over(id)
	_p_client_auth.apply_entry = func(e: DamageLog.Entry) -> void: _p_rep.apply(e)
	_p_host_auth.add_client(func(wire: Array) -> void:
		_p_wire.append(bytes_to_var(var_to_bytes(wire))))


## On the first physics frame, not in _init: the manager is only in the tree by
## then, and a piece placed before that has no global transform to be placed at.
func _p_fight() -> void:
	# Knock the base out of one tower so it sheds, and out from under most of the
	# other so it topples -- the host's own decisions, every one a command.
	var ids: Array = _p_host.ids
	for x in 5:
		_p_blast(ids[0], Vector3(0.6 + x * 1.4, 1.6, 0.2), 1.3)
		_p_blast(ids[0], Vector3(0.6 + x * 1.4, 1.6, FOOT_Z * STUD - 0.2), 1.3)
	for x in 5:
		for z in 6:
			for y in [0.4, 1.2]:
				_p_blast(ids[1], Vector3(14.0 + 0.4 + x * 1.0, y, 0.4 + z * 1.0), 1.0)
	for id in ids:
		_p_settle(id)


func _p_blast(id: int, point: Vector3, radius: float) -> void:
	var chunk := _p_chunk(_p_host, id)
	if chunk < 0:
		return
	if not (_p_host.world as BrickWorld).apply_hit(chunk, point, radius).is_empty():
		_p_host_auth.commit(Engine.get_physics_frames(), DamageLog.Kind.BLAST, id, point, radius)


## What the city does as host after damage: solve, topple or shed.
func _p_settle(id: int) -> void:
	var w: BrickWorld = _p_host.world
	var islands: IslandManager = _p_host.islands
	var chunk := _p_chunk(_p_host, id)
	if chunk < 0:
		return
	if int((w.solve_stress(chunk) as Dictionary).get("failures", 0)) > 0:
		_p_host_auth.commit(Engine.get_physics_frames(), DamageLog.Kind.SOLVE, id, Vector3.ZERO, 0.0)
	if not bool((w.check_stability(chunk) as Dictionary).get("stable", true)):
		var piece := islands.record_topple(id)
		(_p_host.registry as BuildingRegistry).hand_over(id)
		islands.adopt(chunk, null, null, 0, 4, [], piece, id)
		return
	for g in w.find_detached_groups(chunk):
		var piece := islands.record_detach(id, null, chunk, g)
		islands.spawn(chunk, g, Vector3.ZERO, Vector3.ZERO, piece, id)


func _p_deliver() -> void:
	var out := _p_wire.duplicate()
	_p_wire.clear()
	for i in range(out.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	for wire in out:
		_p_client_auth.receive(wire)


func _tick_pieces() -> void:
	if _p_done:
		return
	_p_frame += 1
	if _p_frame == 1:
		_p_fight()
	var islands: IslandManager = _p_host.islands
	islands.tick()
	if _p_frame % WIRE_EVERY == 0:
		_p_deliver()
	var moving := 0
	for isl in islands.islands:
		if isl.is_valid() and not isl.settled:
			moving += 1
	if (moving == 0 and _p_frame > 30) or _p_frame > SETTLE_FRAMES:
		_p_done = true
		_p_deliver()
		_p_compare()
		_p_client_auth.apply_entry = Callable()
		_p_host_auth._clients.clear()
		islands.on_command = Callable()
		_finish()


func _p_compare() -> void:
	var hw: BrickWorld = _p_host.world
	var cw: BrickWorld = _p_client.world
	var islands: IslandManager = _p_host.islands
	var kinds := {}
	for e in _p_host_auth.commands.entries:
		var k: String = DamageLog.Kind.keys()[e.kind]
		kinds[k] = int(kinds.get(k, 0)) + 1
	print("  %d frame(s), %d command(s): %s" % [_p_frame, _p_host_auth.commands.size(), kinds])
	_ok("the collapse detached, toppled and came to rest",
			kinds.has("DETACH") and kinds.has("TOPPLE") and kinds.has("PIECE_REST"), str(kinds))
	_ok("the client applied every command, in the host's order, through a reordering wire",
			_p_client_auth.entries_applied == _p_host_auth.commands.size()
			and _p_client_auth.held_count() == 0 and _p_client_auth.gaps_seen > 0,
			"%d of %d, %d gap(s)" % [_p_client_auth.entries_applied, _p_host_auth.commands.size(),
			_p_client_auth.gaps_seen])
	_ok("and found everything each one named", _p_rep.missed == 0, "%d missed" % _p_rep.missed)

	var same_b := 0
	var n_b := 0
	for id in _p_host.ids:
		var hb := (_p_host.registry as BuildingRegistry).get_building(id)
		var cb := (_p_client.registry as BuildingRegistry).get_building(id)
		if hb.toppled != cb.toppled:
			continue
		n_b += 1
		if hb.toppled or _structure(hw, hb.chunk) == _structure(cw, cb.chunk):
			same_b += 1
	_ok("the same buildings, standing or toppled", same_b == 2 and n_b == 2,
			"%d of 2" % same_b)

	var same := 0
	var n := 0
	var rest_ok := 0
	var rest_n := 0
	for isl in islands.islands:
		if not isl.is_valid() or isl.piece_id < 0:
			continue
		n += 1
		var rc := _p_rep.piece_chunk(isl.piece_id)
		if rc >= 0 and _structure(hw, isl.chunk) == _structure(cw, rc):
			same += 1
		if isl.settled and isl.landmark:
			rest_n += 1
			if rc >= 0 and cw.get_chunk_transform(rc).is_equal_approx(isl.chunk_transform()):
				rest_ok += 1
	_ok("every piece, brick for brick", n > 0 and same == n, "%d of %d" % [same, n])
	_ok("and every landmark at rest lies where the host's lies", rest_n > 0 and rest_ok == rest_n,
			"%d of %d" % [rest_ok, rest_n])


## Structural blocks by absolute cell and part name. See city_scene._structure_of.
func _structure(w: BrickWorld, chunk: int) -> PackedStringArray:
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
