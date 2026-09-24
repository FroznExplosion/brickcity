extends SceneTree

## Acceptance probe for Docs/AIPlan.md P0 step 5: debris by SIZE, with real
## bodies falling in a real space.
##
##     godot --headless --path . --script tools/debris_probe.gd
##
## The review's R2: "small" used to be a block count, and a floor panel is ONE
## block 3.5 m across -- so a floor that broke away was deleted as debris, and
## under A11 would have been something people walk through. Now:
##
##   * a LANDMARK (big enough to hide behind or stand on) is never deleted, is
##     solid to people, and is kept by every machine;
##   * a small piece is presentation: deleted where it came loose when unseen or
##     far, swept up moments after it lands, and walked through;
##   * the cap puts landmarks to sleep farthest from anybody first -- interest
##     points, not one camera -- and never one somebody is standing next to.

const TENSION := 9.3
## Frames a visible small piece is given to fall, land and be swept up.
const SWEEP_FRAMES := 150

var _pass := 0
var _fail := 0
var _frames := 0
var _phase := 0
var _phase_frame := 0

var _w: BrickWorld
var _palette: Dictionary
var _islands: IslandManager
var _camera: Camera3D
var _tower := -1
## A second tower, far enough off that pieces from the two land well apart --
## the cap test needs one landmark near somebody and one nowhere near.
var _tower2 := -1
const APART := 30.0
var _rubble: BrickIsland
var _rubble_gone_frame := -1
var _removed := {}
var _slabs: Array = []


func _init() -> void:
	print("debris probe (AIPlan P0 step 5)")
	_check_classifier()
	_w = BrickWorld.new()
	_w.set_seed(4)
	_palette = TowerRecipe.bake_palette(_w)
	_tower = _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 16, 10))
	TowerRecipe.build(_w, _tower, _palette, 20, 16, 10)
	_w.set_tension_per_stud(_tower, TENSION)
	_tower2 = _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 16, 10))
	TowerRecipe.build(_w, _tower2, _palette, 20, 16, 10)
	_w.set_tension_per_stud(_tower2, TENSION)
	_w.set_chunk_transform(_tower2, Transform3D(Basis(), Vector3(APART, 0.0, 0.0)))

	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)

	_camera = Camera3D.new()
	root.add_child(_camera)
	_islands = IslandManager.new()
	root.add_child(_islands)
	_islands.setup(_w, null, _camera)
	_islands.piece_removed.connect(func(isl: BrickIsland, why: StringName):
		_removed[why] = int(_removed.get(why, 0)) + 1
		if isl == _rubble:
			_rubble_gone_frame = _frames)
	physics_frame.connect(_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# ---------------------------------------------------------------------------

func _check_classifier() -> void:
	print("\nwhat counts as a landmark is size, not blocks")
	_ok("a floor panel, one block 3.5 m across, is a landmark",
			IslandManager.is_landmark_size(Vector3(3.5, 0.14, 3.5)))
	_ok("a beam 2.1 m long is a landmark",
			IslandManager.is_landmark_size(Vector3(2.1, 0.42, 0.35)))
	_ok("three 2x4 bricks stacked, waist high, is a landmark",
			IslandManager.is_landmark_size(Vector3(1.4, 1.26, 0.7)))
	_ok("a single 2x4 brick is not",
			not IslandManager.is_landmark_size(Vector3(1.4, 0.42, 0.7)))
	_ok("nor is a 2x4 plate", not IslandManager.is_landmark_size(Vector3(1.4, 0.14, 0.7)))


## The first alive block in the tower whose part name starts with `prefix`.
func _find(prefix: String, skip := {}, chunk := -1) -> int:
	if chunk < 0:
		chunk = _tower
	for id in _w.get_block_count(chunk):
		if skip.has(id) or not _w.is_solid(chunk, _cell(id, chunk)):
			continue
		if _w.get_archetype_name(_w.get_block_archetype(chunk, id)).begins_with(prefix):
			return id
	return -1


func _cell(id: int, chunk: int) -> Vector3i:
	var c := StructureReplayer.block_cell(_w, chunk, id)
	return _w.get_chunk_origin(chunk) + c


func _look(from: Vector3, at: Vector3) -> void:
	_camera.global_position = from
	_camera.look_at(at, Vector3.UP)


# ---------------------------------------------------------------------------

func _tick() -> void:
	_frames += 1
	_phase_frame += 1
	_islands.tick()
	match _phase:
		0:
			_check_births()
			_next()
		1:
			# The visible brick falls, lands, and is swept up.
			if _rubble_gone_frame >= 0 or _phase_frame > SWEEP_FRAMES:
				_check_sweep()
				_next()
		2:
			# The two floor panels settle.
			var still := 0
			for isl in _slabs:
				if isl.is_valid() and isl.settled:
					still += 1
			if still == _slabs.size() or _phase_frame > 400:
				_check_cap()
				_finish()


func _next() -> void:
	_phase += 1
	_phase_frame = 0


func _check_births() -> void:
	print("\nwhat is kept and what is deleted where it came loose")
	var plate := _find("plate_10x10")
	var brick := _find("brick_2x4")
	_ok("the tower has a floor panel and a brick to cut", plate >= 0 and brick >= 0)
	_ok("a floor panel measured in the tower is a landmark",
			_islands.group_is_landmark(_tower, PackedInt32Array([plate])))
	_ok("a single brick is not", not _islands.group_is_landmark(_tower, PackedInt32Array([brick])))

	# Nobody can see the tower: the camera is close by but facing away.
	_look(Vector3(3.5, 3.0, 20.0), Vector3(3.5, 3.0, 60.0))
	var kept := _islands.spawn(_tower, PackedInt32Array([plate]))
	_ok("an unseen floor panel still comes loose as a body", kept != null)
	if kept != null:
		_ok("as structure, not rubble", kept.landmark and not kept.disposable
				and kept.body.collision_layer == Layers.FALLING)
		_slabs.append(kept)
	var before := _islands.discarded + _islands.tiny_deleted
	var gone := _islands.spawn(_tower, PackedInt32Array([brick]))
	_ok("an unseen brick is deleted where it came loose", gone == null
			and _islands.discarded + _islands.tiny_deleted > before)

	# Now looking straight at it: a small piece nearby and in view is a body --
	# rubble, which people walk through.
	_look(Vector3(3.5, 3.0, 14.0), Vector3(3.5, 2.0, 2.8))
	var seen := _find("brick_2x4", {brick: true})
	_rubble = _islands.spawn(_tower, PackedInt32Array([seen]))
	_ok("a brick in view comes loose as a body", _rubble != null)
	if _rubble != null:
		_ok("as rubble", _rubble.disposable and not _rubble.landmark
				and _rubble.body.collision_layer == Layers.RUBBLE)
	_ok("and people walk through rubble", Layers.PAWN_MASK & Layers.RUBBLE == 0
			and Layers.PAWN_MASK & Layers.DEBRIS != 0)

	# A second floor panel for the cap, from the far tower. Nobody is looking: it
	# is a landmark, and landmarks are kept whoever can see them.
	var plate2 := _find("plate_10x10", {}, _tower2)
	var second := _islands.spawn(_tower2, PackedInt32Array([plate2]))
	if second != null:
		_slabs.append(second)


func _check_sweep() -> void:
	print("\nrubble is swept up moments after it lands")
	var ms := int(float(_rubble_gone_frame) / float(Engine.physics_ticks_per_second) * 1000.0)
	_ok("the brick is gone", _rubble_gone_frame >= 0)
	_ok("swept at rest, not on the old timer", _islands.swept_at_rest > 0,
			"%d swept at rest, %d ms after it came loose" % [_islands.swept_at_rest, ms])


func _check_cap() -> void:
	print("\nthe cap puts to sleep farthest from anybody, never under anybody")
	_ok("both floor panels came to rest", _slabs.size() == 2
			and _slabs[0].settled and _slabs[1].settled)
	if _slabs.size() < 2:
		return
	var a: BrickIsland = _slabs[0]
	var b: BrickIsland = _slabs[1]
	# Somebody stands on A. B is the one that may go.
	var on_a := _islands.world_aabb(a).get_center()
	_islands.interest = func() -> PackedVector3Array: return PackedVector3Array([on_a])
	_islands.large_live_max = 1
	_islands.total_live_max = 1000
	_islands.tick()
	_ok("the one somebody is standing on stays", a.is_valid())
	_ok("the other is put to sleep", not b.is_valid() and _islands.dormant.size() == 1,
			"%d asleep" % _islands.dormant.size())

	# And with somebody next to every one, nothing goes -- however far over.
	var c := _islands.spawn(_tower, PackedInt32Array([_find("plate_10x10")]))
	if c == null:
		_ok("a third panel to try it with", false)
		return
	var on_c := _islands.world_aabb(c).get_center()
	_islands.interest = func() -> PackedVector3Array: return PackedVector3Array([on_a, on_c])
	c.settled = true
	c.settled_ms = Time.get_ticks_msec()
	_islands.large_live_max = 0
	_islands.tick()
	_ok("nobody's floor is put away, even over the cap", a.is_valid() and c.is_valid())


func _finish() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
