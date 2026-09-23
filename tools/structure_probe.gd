extends SceneTree

## Is a generated building one structure?
##
##     godot --headless --path . --script tools/structure_probe.gd
##
## Every shape the city builds, with the staircase the city gives it, asked the
## questions that decide whether it stands and how it comes apart:
##
##   * how many blocks it costs;
##   * does it hold itself up -- no stress failures, nothing detached;
##   * are its floors part of its walls -- how many floor panels share a stud
##     joint with an exterior wall;
##   * what is actually holding the floors -- take every column out and count
##     the panels that fall.
##
## Walls, floors and columns are all STRUCTURE: nothing in a bare building is
## decorative, and that is checked too.

const City := preload("res://scripts/city_scene.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("structure probe")
	var shapes: Array = City.SHAPES + City.BIG_SHAPES
	for s in shapes:
		_check_shape(int(s.x), int(s.z), int(s.courses))
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _check_shape(fx: int, fz: int, courses: int) -> void:
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, pal)
	var id := reg.register(fx, fz, courses, Transform3D())
	var sx := TowerRecipe.stair_line(fx)
	var sz := TowerRecipe.stair_line(fz)
	if sx >= 0 and sz >= 0:
		reg.add_fixture(id, "staircase", {"steps": StaircaseRecipe.steps_for_courses(courses),
				"colour": 11}, Vector3i(sx, TowerRecipe.SLAB_PLATES, sz))
	var chunk := reg.materialise(id)
	var n := w.get_block_count(chunk)
	print("\n%dx%d, %d courses: %d blocks" % [fx, fz, courses, n])

	_ok("has a stairwell in a cell clear of its walls", sx >= 0 and sz >= 0)

	var stress: Dictionary = w.solve_stress(chunk)
	var failures := int(stress.get("failures", 0))
	var detached := 0
	for g in w.find_detached_groups(chunk):
		detached += (g as PackedInt32Array).size()
	_ok("stands: no stress failures, nothing detached", failures == 0 and detached == 0,
			"%d failures, %d detached" % [failures, detached])
	_ok("nothing in the bare building is furniture", w.get_decorative_blocks(chunk).is_empty())

	# Which floor panels share a joint with an exterior wall brick.
	var panel_arch: int = pal.plate_10x10
	var t := TowerRecipe.WALL_THICK
	var tps := BrickWorld.ticks_per_stud()
	var panels := PackedInt32Array()
	var columns := PackedInt32Array()
	var joined := 0
	var edge := 0
	for b in n:
		var arch := w.get_block_archetype(chunk, b)
		if arch == pal.column_2x2 or arch == pal.column_1x1:
			columns.push_back(b)
		if arch != panel_arch:
			continue
		panels.push_back(b)
		var lo: Vector3i = w.get_block_ticks(chunk, b)[0]
		@warning_ignore("integer_division")
		var px: int = lo.x / tps
		@warning_ignore("integer_division")
		var pz: int = lo.z / tps
		# A panel on the edge of the floor: its outer side is at the wall.
		var on_edge := px <= t or pz <= t or px + TowerRecipe.PANEL >= fx - t \
				or pz + TowerRecipe.PANEL >= fz - t
		if not on_edge:
			continue
		edge += 1
		for nb in w.get_block_neighbours(chunk, b):
			var nlo: Vector3i = w.get_block_ticks(chunk, nb)[0]
			var nsz: Vector3i = w.get_block_ticks(chunk, nb)[1]
			@warning_ignore("integer_division")
			var nx0: int = nlo.x / tps
			@warning_ignore("integer_division")
			var nz0: int = nlo.z / tps
			@warning_ignore("integer_division")
			var nx1: int = (nlo.x + nsz.x) / tps
			@warning_ignore("integer_division")
			var nz1: int = (nlo.z + nsz.z) / tps
			if nx0 < t or nz0 < t or nx1 > fx - t or nz1 > fz - t:
				if w.get_block_archetype(chunk, nb) != panel_arch:
					joined += 1
					break
	print("  floor panels: %d, %d on the edge of a floor, %d of those joined to an exterior wall"
			% [panels.size(), edge, joined])
	_ok("every edge panel is joined to the wall it meets", joined == edge,
			"%d of %d" % [joined, edge])

	# Take the columns away. Whatever falls was hanging on them alone.
	w.kill_blocks(chunk, columns)
	var fell := 0
	var fell_panels := {}
	for g in w.find_detached_groups(chunk):
		for b in (g as PackedInt32Array):
			fell += 1
			if w.get_block_archetype(chunk, b) == panel_arch:
				fell_panels[b] = true
	print("  every column removed (%d): %d blocks fall, %d of %d panels"
			% [columns.size(), fell, fell_panels.size(), panels.size()])
