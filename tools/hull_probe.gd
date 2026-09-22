extends SceneTree

## Acceptance probe for gap 8, part two: parts that COLLIDE as their shape.
##
##     godot --headless --path . --script tools/hull_probe.gd
##
## An archetype may carry convex hulls, and both collision paths -- one body
## shape per block, and a standing building's merged boxes -- use one shared
## convex shape per hull for it instead of boxes. The claim worth testing is
## the physical one, so this puts real bodies in a real space and fires rays:
## a point inside a tread's CELL but outside its CURVE is solid to the old
## boxes and empty to the hulls.

var _pass := 0
var _fail := 0
var _frames := 0

var _w: BrickWorld
var _space: RID
var _hulled_body: RID
var _boxed_body: RID
var _probe_point := Vector3.ZERO
var _tread_point := Vector3.ZERO

## The boxed copy sits this far along X so the two never touch.
const APART := 10.0


func _init() -> void:
	print("hull probe (gap 8: collision)")
	_check_shapes()
	_setup_space()
	physics_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 3:
		return
	_check_rays()
	PhysicsServer3D.free_rid(_hulled_body)
	PhysicsServer3D.free_rid(_boxed_body)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## The same step as the staircase's sector 0, but with no hulls: what every
## masked part collided as before.
func _boxed_step(w: BrickWorld) -> int:
	var D := StaircaseRecipe.DIAMETER
	var H := StaircaseRecipe.STEP_PLATES
	var solid: PackedByteArray = StaircaseRecipe._mask(0)
	var cells := PackedByteArray()
	cells.resize(D * H * D)
	for z in D:
		for x in D:
			for y in H:
				cells[x + D * (y + H * z)] = solid[x + D * z]
	return w.bake_shaped_archetype("boxed_step", Vector3i(D, H, D), 1.0, cells, solid, solid)


# ---------------------------------------------------------------------------

func _check_shapes() -> void:
	print("\nwhich shapes a part gets")
	var w := BrickWorld.new()
	var parts: PackedInt32Array = StaircaseRecipe.bake_parts(w)
	var all_two := true
	for id in parts:
		all_two = all_two and w.get_archetype_hull_count(id) == 2
	_ok("every stair step carries two hulls: the newel and the tread", all_two)

	var boxed := _boxed_step(w)
	var ps := PhysicsServer3D
	var c := w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(1))
	w.place_block(c, Vector3i.ZERO, parts[0], 4)
	var body := ps.body_create()
	var r: Dictionary = w.add_chunk_shapes(body, c, Vector3.ZERO, false, false)
	_ok("per block: a hulled step is two shapes", r.count == 2, "%d" % r.count)
	var convex := true
	for i in ps.body_get_shape_count(body):
		convex = convex and ps.shape_get_type(ps.body_get_shape(body, i)) \
				== PhysicsServer3D.SHAPE_CONVEX_POLYGON
	_ok("both convex polygons", convex)
	var map: Dictionary = r.map
	_ok("and the damage map gives the block both, so killing it disables both",
			map.has(0) and (map[0] as PackedInt32Array).size() == 2)
	ps.free_rid(body)

	var c2 := w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(1))
	w.place_block(c2, Vector3i.ZERO, boxed, 4)
	var body2 := ps.body_create()
	var r2: Dictionary = w.add_chunk_shapes(body2, c2, Vector3.ZERO, false, false)
	_ok("the same cells with no hulls are a box per solid cell -- the old rule",
			r2.count == w.get_archetype_solid_cells(boxed), "%d" % r2.count)
	ps.free_rid(body2)

	# A standing building's merged boxes: the step stays out of the merge and
	# brings its own two, while an ordinary brick still merges.
	var p := BrickPalette.bake(w)
	var c3 := w.create_chunk(Vector3i.ZERO, Vector3i(16, 8, 8))
	w.place_block(c3, Vector3i.ZERO, parts[0], 4)
	w.place_block(c3, Vector3i(10, 0, 0), p["brick_2x4_x"], 4)
	var body3 := ps.body_create()
	var r3: Dictionary = w.add_chunk_shapes(body3, c3, Vector3.ZERO, false, true)
	_ok("merged: one box for the brick plus the step's two hulls", r3.count == 3,
			"%d" % r3.count)
	ps.free_rid(body3)

	# Turned variants carry their hulls round with them.
	var base := w.bake_archetype("hullbase", Vector3i(1, 3, 4), 1.2)
	var S := BrickPalette.STUD_M
	var hy := 3 * BrickPalette.PLATE_M
	var box := PackedVector3Array([Vector3(0, 0, 0), Vector3(S, 0, 0), Vector3(0, hy, 0),
			Vector3(0, 0, 4 * S), Vector3(S, hy, 4 * S)])
	w.set_archetype_hulls(base, [box])
	var turned := w.bake_variant(base, "hullbase_x", 1, false)
	_ok("a turned variant has its hull", w.get_archetype_hull_count(turned) == 1)
	_ok("a hull of fewer than four points is refused",
			(func() -> bool:
				w.set_archetype_hulls(base, [PackedVector3Array([Vector3.ZERO])])
				return w.get_archetype_hull_count(base) == 1).call())


func _setup_space() -> void:
	_w = BrickWorld.new()
	var parts: PackedInt32Array = StaircaseRecipe.bake_parts(_w)
	var boxed := _boxed_step(_w)
	_space = root.get_world_3d().space
	var ps := PhysicsServer3D

	var ch := _w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(1))
	_w.place_block(ch, Vector3i.ZERO, parts[0], 4)
	_hulled_body = ps.body_create()
	ps.body_set_mode(_hulled_body, PhysicsServer3D.BODY_MODE_STATIC)
	_w.add_chunk_shapes(_hulled_body, ch, Vector3.ZERO, false, false)
	ps.body_set_state(_hulled_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D())
	ps.body_set_space(_hulled_body, _space)

	var cb := _w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(1))
	_w.place_block(cb, Vector3i.ZERO, boxed, 4)
	_boxed_body = ps.body_create()
	ps.body_set_mode(_boxed_body, PhysicsServer3D.BODY_MODE_STATIC)
	_w.add_chunk_shapes(_boxed_body, cb, Vector3.ZERO, false, false)
	ps.body_set_state(_boxed_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			Transform3D(Basis(), Vector3(APART, 0, 0)))
	ps.body_set_space(_boxed_body, _space)

	# A point inside a solid CELL of the sector-0 mask but outside the tread's
	# CURVE: the corner of a cell that pokes past the outer radius.
	var S := BrickPalette.STUD_M
	var D := StaircaseRecipe.DIAMETER
	var centre := Vector2(D * 0.5 * S, D * 0.5 * S)
	var ro := D * 0.5 * S
	var mask: PackedByteArray = StaircaseRecipe._mask(0)
	for z in D:
		for x in D:
			if mask[x + D * z] == 0:
				continue
			for corner in [Vector2(x + 1, z + 1), Vector2(x, z + 1), Vector2(x + 1, z)]:
				var q: Vector2 = corner * S
				var toward := (Vector2((x + 0.5) * S, (z + 0.5) * S) - q).normalized()
				q += toward * 0.02
				if (q - centre).length() > ro + 0.02 and _probe_point == Vector3.ZERO:
					_probe_point = Vector3(q.x, 1.0, q.y)
	# And a point squarely on the tread: halfway out, mid-sector.
	var a := TAU / 16.0
	var rm := (ro + S) * 0.5
	_tread_point = Vector3(centre.x + rm * cos(a), 1.0, centre.y + rm * sin(a))


func _cast(p: Vector3) -> Dictionary:
	var dss := PhysicsServer3D.space_get_direct_state(_space)
	var q := PhysicsRayQueryParameters3D.create(p, p - Vector3(0, 2.0, 0))
	return dss.intersect_ray(q)


func _check_rays() -> void:
	print("\nrays: what is solid where")
	_ok("found a point in a tread cell but outside its curve", _probe_point != Vector3.ZERO)

	var top := StaircaseRecipe.STEP_PLATES * BrickPalette.PLATE_M
	var on: Dictionary = _cast(_tread_point)
	_ok("the tread is solid where it is drawn", not on.is_empty())
	if not on.is_empty():
		_ok("and its top is at the tread's height", absf((on.position as Vector3).y - top) < 0.01,
				"y %.3f" % (on.position as Vector3).y)

	var boxed: Dictionary = _cast(_probe_point + Vector3(APART, 0, 0))
	_ok("the OLD rule: that corner is solid, because its cell is", not boxed.is_empty())
	var hulled: Dictionary = _cast(_probe_point)
	_ok("with hulls it is empty -- the part collides as its curve, not its cells",
			hulled.is_empty(), "hit at %v" % [hulled.get("position", Vector3.ZERO)])
