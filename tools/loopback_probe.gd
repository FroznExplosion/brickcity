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
## What is deliberately not here yet: loose pieces. A landing fracture on an
## island is still decided by each machine's own physics (AIPlan R5, P0 step 4).

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
