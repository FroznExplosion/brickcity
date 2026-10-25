extends SceneTree
## The rubble field (IslandManager, DestructionLod 3.5): sleeping wreckage's
## stand-ins merged a tile at a time, the biggest-looking drawn.
##   * a tall wreck far off looks bigger than a short heap nearer (the user's
##     rule: what is seen from round the planet is drawn first);
##   * a tile's merge is its stand-ins' arrays joined: every vertex moved by its
##     own transform, every index offset to its own vertices.
##   --headless --path . --script res://tools/rubble_field_probe.gd

var _fails := 0


func _init() -> void:
	# A 60 m spire 600 m off against a 3 m heap 200 m off.
	var tall := IslandManager.apparent_size(AABB(Vector3.ZERO, Vector3(8, 60, 8)), 600.0)
	var short := IslandManager.apparent_size(AABB(Vector3.ZERO, Vector3(10, 3, 10)), 200.0)
	_ok("a tall wreck far off looks bigger than a short heap nearer", tall > short,
			"%.3f against %.3f" % [tall, short])
	# A wide low slab as far as the spire: height counts more than width.
	var wide := IslandManager.apparent_size(AABB(Vector3.ZERO, Vector3(60, 8, 60)), 600.0)
	_ok("and a tower outranks a slab as wide as it is tall", tall > wide,
			"%.3f against %.3f" % [tall, wide])

	# Two one-triangle stand-ins, the second moved 10 m up x.
	var a := _tri()
	var b := _tri()
	var mat := StandardMaterial3D.new()
	var built := IslandManager._field_build([
			[a, Transform3D.IDENTITY, mat],
			[b, Transform3D(Basis(), Vector3(10, 0, 0)), mat]])
	var mesh: ArrayMesh = built[0]
	_ok("one surface for one material", mesh.get_surface_count() == 1,
			"%d surface(s)" % mesh.get_surface_count())
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	_ok("every vertex of both", v.size() == 6, "%d" % v.size())
	_ok("the second moved by its own transform", v[3].is_equal_approx(Vector3(10, 0, 0))
			and v[0].is_equal_approx(Vector3.ZERO), "%s, %s" % [v[0], v[3]])
	_ok("its indices offset to its own vertices", idx == PackedInt32Array([0, 1, 2, 3, 4, 5]),
			str(idx))
	_ok("the box covers both", (built[1] as AABB).end.x >= 11.0 - 0.001, str(built[1]))
	print("[rubble_field] %s" % ("ok" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


func _tri() -> Array:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)])
	arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	return arr


func _ok(what: String, cond: bool, note := "") -> void:
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + note) if note != "" else ""])
	if not cond:
		_fails += 1
