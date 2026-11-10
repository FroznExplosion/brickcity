extends SceneTree

## A recipe building's shell arrays from C++ (ShellMesher, through
## BuildingShell.build_arrays) against the GDScript walk they replaced
## (BuildingShell.build_arrays_script). Docs/HandoffPerf.md 6.5.
##
##     godot --headless --path . --script res://tools/shell_mesher_probe.gd
##
## Checked: for every size and damage below, every array is the same, value
## for value (vertices, normals, colours, both UVs, indices) -- the shell the
## game draws is the one it drew. Printed: what each takes.

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## Where the two differ first, or "" when they do not.
func _diff(a: Array, b: Array) -> String:
	for k in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV,
			Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
		var x = a[k]
		var y = b[k]
		if x.size() != y.size():
			return "array %d: %d against %d entries" % [k, x.size(), y.size()]
		for i in x.size():
			if x[i] != y[i]:
				return "array %d entry %d: %s against %s" % [k, i, str(x[i]), str(y[i])]
	return ""


func _init() -> void:
	print("shell arrays, C++ against GDScript")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var sizes := [[80, 60, 204], [60, 40, 162], [50, 50, 102], [30, 30, 246], [8, 6, 3], [12, 12, 1]]
	for dims in sizes:
		var fx: int = dims[0]
		var fz: int = dims[1]
		var courses: int = dims[2]
		var bands := TowerRecipe.layout(courses).size()
		var cases := {}
		cases["intact"] = {}
		# A hit at the foot: holes in a dozen bands, one band gone whole.
		var foot := {}
		for band in mini(12, bands):
			foot[band] = PackedInt32Array([0x0000FFFF, 0xFFFF0000, 0x00FF00FF, -1])
		foot[mini(5, bands - 1)] = PackedInt32Array([0, 0, 0, 0])
		cases["hit at the foot"] = foot
		# Random masks on every band, the cornice and the top course among them,
		# and some bands every bit standing (-1), some gone.
		var shot := {}
		for band in bands:
			var r := rng.randi_range(0, 5)
			if r == 0:
				continue
			elif r == 1:
				shot[band] = PackedInt32Array([0, 0, 0, 0])
			elif r == 2:
				shot[band] = PackedInt32Array([-1, -1, -1, -1])
			else:
				shot[band] = PackedInt32Array([rng.randi() - 2147483648, rng.randi() - 2147483648,
						rng.randi() - 2147483648, rng.randi() - 2147483648])
		cases["shot all over"] = shot
		# The top gone: the wall-top cap then lands on what is left.
		var topless := {}
		for band in range(bands / 2, bands):
			topless[band] = PackedInt32Array([0, 0, 0, 0])
		cases["top half gone"] = topless
		for name in cases:
			var damage: Dictionary = cases[name]
			BuildingShell.build_arrays(fx, fz, courses, damage)   # its layout flattened once
			var t0 := Time.get_ticks_usec()
			var cpp := BuildingShell.build_arrays(fx, fz, courses, damage)
			var t1 := Time.get_ticks_usec()
			var gd := BuildingShell.build_arrays_script(fx, fz, courses, damage)
			var t2 := Time.get_ticks_usec()
			var diff := _diff(cpp, gd)
			_ok("%dx%d, %d courses, %s: the same arrays" % [fx, fz, courses, name], diff == "",
					diff if diff else "%d verts; C++ %.2f ms, GDScript %.2f ms" % [
					(cpp[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
					(t1 - t0) / 1000.0, (t2 - t1) / 1000.0])
	# A worker passes the layout in (CityDrawing's shadow proxies).
	var layout := TowerRecipe.layout(40)
	var diff := _diff(BuildingShell.build_arrays(20, 16, 40, {}, layout),
			BuildingShell.build_arrays_script(20, 16, 40, {}, layout))
	_ok("a layout handed in: the same arrays", diff == "", diff)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
