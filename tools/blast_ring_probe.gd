extends SceneTree

## A blast destroys the middle of what it reaches and throws the rest out
## (Docs/CollapseNext.md 1.10 (3); BrickFailure.md 5: bricks separate, they do
## not vanish).
##
##     godot --headless --path . --script tools/blast_ring_probe.gd
##
## IslandManager.throw_killed: of the bricks a blast has killed, those whose
## middle is within BLAST_CORE of its radius are gone, and the ring round them
## leaves as crumbs -- drawn, thrown off the face and away from the middle of
## the blast, falling, gone a second and a half on. A gun's wear destroys
## nothing: the brick it finishes is knocked off whole.
##
## What this does NOT change is the structure, and that is the first thing
## checked: the bricks are dead in the grid the moment the blast lands, exactly
## the ones that were before, so the log, a replay and a save are unchanged.
## The crumbs are each machine's own drawing, like every crumb: none far away,
## none out of view, none in a tornado's wind, and no more than there is room for.

const RADIUS := 1.4

var _pass := 0
var _fail := 0
var _started := false
var _w: BrickWorld
var _palette: Dictionary
var _m: IslandManager
var _camera: Camera3D
var _tower := -1


func _init() -> void:
	print("a blast throws out the ring round its middle")
	# How hard each crumb is thrown is drawn at random; the same draws every run.
	seed(20261013)
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	_tower = _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(16, 16, 20))
	TowerRecipe.build(_w, _tower, _palette, 16, 16, 20)
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	_camera = Camera3D.new()
	root.add_child(_camera)
	_m = IslandManager.new()
	root.add_child(_m)
	_m.setup(_w, null, _camera)
	_m.interest = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0, 1, 0)])
	physics_frame.connect(_run)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for k in n:
		await physics_frame
		_m.tick()


func _look(from: Vector3, at: Vector3) -> void:
	_camera.global_position = from
	_camera.look_at(at, Vector3.UP)


## A block's middle, in the world.
func _middle(chunk: int, id: int) -> Vector3:
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var t: Array = _w.get_block_ticks(chunk, id)
	return _w.get_chunk_transform(chunk) \
			* ((Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m)


## Of `killed`, how many are in the core of a blast at `at` and how many round it.
func _split(chunk: int, killed: PackedInt32Array, at: Vector3, radius: float) -> Array:
	var core := 0
	var ring := 0
	for id in killed:
		if _w.is_block_decorative(chunk, id):
			continue
		if _middle(chunk, id).distance_to(at) < radius * IslandManager.BLAST_CORE:
			core += 1
		else:
			ring += 1
	return [core, ring]


## Every crumb there is: [where, how fast].
func _crumbs() -> Array:
	var out := []
	for key in _m._crumbs:
		var cr = _m._crumbs[key]
		for i in cr.pos.size():
			out.append([cr.pos[i], cr.vel[i]])
	return out


## The front face of the tower (z = 0), `along` of the way across and `up` metres.
func _face(along: float, up: float) -> Vector3:
	var size: Vector3 = Vector3(_w.get_chunk_dims(_tower)) * BrickWorld.get_cell_size()
	return Vector3(size.x * along, up, 0.2)


func _run() -> void:
	if _started:
		return
	_started = true
	var size: Vector3 = Vector3(_w.get_chunk_dims(_tower)) * BrickWorld.get_cell_size()
	var mid := size * 0.5

	# --- the middle goes, the ring is thrown ------------------------------------
	print("\na blast on a wall, looked at from the street")
	var at := _face(0.5, 3.0)
	_look(Vector3(mid.x, 3.0, -14.0), at)
	var killed: PackedInt32Array = _w.apply_hit(_tower, at, RADIUS)
	var parts := _split(_tower, killed, at, RADIUS)
	var alive0 := _w.get_alive_block_count(_tower)
	_m.throw_killed(_tower, killed, at, RADIUS)
	_ok("the blast killed bricks in its middle and bricks round it",
			int(parts[0]) > 0 and int(parts[1]) > 0, "%d in the core, %d in the ring" % parts)
	_ok("throwing them changes nothing in the grid: dead is dead, as it was",
			_w.get_alive_block_count(_tower) == alive0)
	_ok("every brick of the ring is a crumb, and none of the core",
			_m.crumb_count == int(parts[1]), "%d crumb(s)" % _m.crumb_count)
	var crumbs := _crumbs()
	var nearest := INF
	var farthest := 0.0
	var mean := Vector3.ZERO
	for c in crumbs:
		var d: float = (c[0] as Vector3).distance_to(at)
		nearest = minf(nearest, d)
		farthest = maxf(farthest, d)
		mean += c[1] as Vector3
	mean /= maxf(crumbs.size(), 1.0)
	_ok("each starts where its brick was: none inside the core, none far outside the blast",
			nearest >= RADIUS * IslandManager.BLAST_CORE - 0.001 and farthest < RADIUS + 1.0,
			"%.2f to %.2f m from the middle" % [nearest, farthest])
	# The face is z = 0 and the building's middle is behind it: off the face is -z.
	_ok("they are thrown off the face, away from the building",
			mean.z < -0.3 and mean.z > -IslandManager.BLAST_THROW - 1.0, "%.2f m/s" % -mean.z)
	var outward := 0.0
	for c in crumbs:
		outward += ((c[1] as Vector3) - mean).dot(((c[0] as Vector3) - at).normalized())
	outward /= maxf(crumbs.size(), 1.0)
	_ok("and each its own way from the middle of the blast", outward > 0.3, "%.2f m/s" % outward)
	_ok("counted: killed, in the core, thrown, and none not drawn",
			_m.blast_census == [int(parts[0]) + int(parts[1]), int(parts[0]), int(parts[1]), 0, 0, 0, 0],
			str(_m.blast_census))
	await _ticks(20)
	var fell := 0.0
	var lowest := INF
	for c in _crumbs():
		fell += (c[1] as Vector3).y
		lowest = minf(lowest, (c[0] as Vector3).y)
	_ok("a third of a second on they are falling", fell < 0.0 and lowest < at.y,
			"lowest at %.2f m" % lowest)
	await _ticks(int(IslandManager.CRUMB_LIFE_MS * Engine.physics_ticks_per_second / 1000.0))
	_ok("and a second and a half on they are gone", _m.crumb_count == 0,
			"%d left" % _m.crumb_count)

	# --- a blast that kills nothing ---------------------------------------------
	print("\na blast in the air")
	var census0: Array = _m.blast_census.duplicate()
	var none: PackedInt32Array = _w.apply_hit(_tower, Vector3(mid.x, 3.0, -8.0), RADIUS)
	_m.throw_killed(_tower, none, Vector3(mid.x, 3.0, -8.0), RADIUS)
	_ok("kills nothing and throws nothing", none.is_empty() and _m.crumb_count == 0
			and _m.blast_census == census0)

	# --- this machine's own: far, unseen, wind, room ----------------------------
	print("\nwho gets to see them")
	at = _face(0.25, 6.0)
	_look(Vector3(mid.x, 3.0, -(IslandManager.SMALL_KEEP_RANGE + 40.0)), at)
	killed = _w.apply_hit(_tower, at, RADIUS)
	parts = _split(_tower, killed, at, RADIUS)
	_m.throw_killed(_tower, killed, at, RADIUS)
	_ok("from too far to make out a brick, none is drawn", int(parts[1]) > 0
			and _m.crumb_count == 0 and _m.blast_census[3] == int(parts[1]),
			"%d in the ring" % int(parts[1]))

	at = _face(0.75, 6.0)
	_look(Vector3(mid.x, 3.0, -14.0), Vector3(mid.x, 3.0, -60.0))
	killed = _w.apply_hit(_tower, at, RADIUS)
	parts = _split(_tower, killed, at, RADIUS)
	_m.throw_killed(_tower, killed, at, RADIUS)
	_ok("with the camera's back to it, none is drawn", int(parts[1]) > 0
			and _m.crumb_count == 0 and _m.blast_census[4] == int(parts[1]))

	at = _face(0.25, 9.0)
	_look(Vector3(mid.x, 3.0, -14.0), at)
	_m.windy(7, Vector3(mid.x, 0.0, mid.z), 40.0, 600000)
	killed = _w.apply_hit(_tower, at, RADIUS)
	parts = _split(_tower, killed, at, RADIUS)
	_m.throw_killed(_tower, killed, at, RADIUS)
	_ok("in a tornado's wind, none is drawn: what it tears off is its own to show",
			int(parts[1]) > 0 and _m.crumb_count == 0 and _m.blast_census[5] == int(parts[1]))
	_m._wind.clear()

	# A charge big enough to take a storey out, on a tower of its own: every
	# so-manyth brick of the ring.
	var big := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(28, 16, 30))
	TowerRecipe.build(_w, big, _palette, 28, 16, 30)
	_w.set_chunk_transform(big, Transform3D(Basis(), Vector3(60.0, 0.0, 0.0)))
	var big_size: Vector3 = Vector3(_w.get_chunk_dims(big)) * BrickWorld.get_cell_size()
	at = Vector3(60.0 + big_size.x * 0.5, big_size.y * 0.5, 0.2)
	_look(at + Vector3(0.0, 0.0, -22.0), at)
	killed = _w.apply_hit(big, at, 4.0)
	parts = _split(big, killed, at, 4.0)
	_m.throw_killed(big, killed, at, 4.0)
	_ok("a big charge throws no more than BLAST_CRUMBS_MAX",
			int(parts[1]) > IslandManager.BLAST_CRUMBS_MAX and _m.crumb_count > 0
			and _m.crumb_count <= IslandManager.BLAST_CRUMBS_MAX
			and _m.blast_census[6] == int(parts[1]) - _m.crumb_count,
			"%d of %d in the ring" % [_m.crumb_count, int(parts[1])])
	crumbs = _crumbs()
	var left := 0
	var right := 0
	var above := 0
	var below := 0
	for c in crumbs:
		var p: Vector3 = c[0]
		left += 1 if p.x < at.x else 0
		right += 1 if p.x >= at.x else 0
		above += 1 if p.y >= at.y else 0
		below += 1 if p.y < at.y else 0
	_ok("and they come from all the way round it, not one side",
			mini(mini(left, right), mini(above, below)) >= crumbs.size() / 5,
			"%d left, %d right, %d above, %d below" % [left, right, above, below])
	await _ticks(int(IslandManager.CRUMB_LIFE_MS * Engine.physics_ticks_per_second / 1000.0) + 10)

	# --- a gun --------------------------------------------------------------------
	print("\na gun's wear")
	# A brick of the front wall, low down, and a round into the middle of it.
	var target := -1
	for id in _w.get_block_count(_tower):
		if not _w.get_archetype_name(_w.get_block_archetype(_tower, id)).begins_with("brick_"):
			continue
		if not _w.is_solid(_tower, _w.get_chunk_origin(_tower)
				+ StructureReplayer.block_cell(_w, _tower, id)):
			continue
		var m := _middle(_tower, id)
		if m.z < 0.4 and m.y > 0.4 and m.y < 1.6:
			target = id
			break
	at = _middle(_tower, target) if target >= 0 else _face(0.4, 1.0)
	_look(Vector3(mid.x, 3.0, -14.0), at)
	var hp0: int = _w.get_block_hp(_tower, target) if target >= 0 else 0
	var worn: PackedInt32Array = _w.chip_hit(_tower, at, 0.0, 100)
	_m.throw_killed(_tower, worn, at, 0.0, true)
	_ok("a round that only wears a brick knocks nothing off", target >= 0 and worn.is_empty()
			and _w.get_block_hp(_tower, target) < hp0 and _m.crumb_count == 0,
			"hp %d -> %d" % [hp0, _w.get_block_hp(_tower, target) if target >= 0 else 0])
	var shots := 1
	while worn.is_empty() and shots < 8:
		worn = _w.chip_hit(_tower, at, 0.0, 100)
		shots += 1
	_m.throw_killed(_tower, worn, at, 0.0, true)
	_ok("the round that finishes it knocks it off whole: one brick, one crumb",
			worn.size() == 1 and _m.crumb_count == 1, "after %d round(s)" % shots)
	await _ticks(int(IslandManager.CRUMB_LIFE_MS * Engine.physics_ticks_per_second / 1000.0) + 10)

	# --- wreckage -----------------------------------------------------------------
	print("\na blast on a piece lying in the street")
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(10, 10, 3))
	TowerRecipe.build(_w, c, _palette, 10, 10, 3)
	_w.set_chunk_transform(c, Transform3D(Basis(), Vector3(-30.0, 0.05, 0.0)))
	var ids := PackedInt32Array()
	for id in _w.get_block_count(c):
		ids.append(id)
	var piece := _m.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	await _ticks(60)
	_m.settle_now(piece)
	var box := _m.world_aabb(piece)
	at = Vector3(box.get_center().x, box.end.y, box.position.z + 0.2)
	_look(at + Vector3(0.0, 3.0, -12.0), at)
	var bricks0 := _w.get_alive_block_count(piece.chunk)
	var thrown0: int = _m.blast_census[2]
	var core0: int = _m.blast_census[1]
	_m.damage(piece, at, RADIUS)
	var took := bricks0 - (_w.get_alive_block_count(piece.chunk) if piece.is_valid() else 0)
	_ok("it loses bricks, and the ones round the middle are thrown",
			took > 0 and _m.blast_census[2] > thrown0 and _m.crumb_count == _m.blast_census[2] - thrown0,
			"%d gone from it, %d of them thrown, %d in the core" % [
				took, _m.blast_census[2] - thrown0, _m.blast_census[1] - core0])
	_ok("and it stays where it lies, as wreckage at rest does", piece.is_valid() and piece.settled)

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
