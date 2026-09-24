extends SceneTree

## Placing a finished build in the city: the workshop's rules, one level up.
##
##     godot --headless --path . --script tools/city_place_probe.gd
##
## Driven with exact rays through CityPlacer.aim_ray, as place_probe drives the
## workshop, against a registry with one tower in it and no city scene.

var _pass := 0
var _fail := 0
const STUD := 0.35
const PLATE := 0.14


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A ray straight down onto the centre of a world stud column.
func _down(p: CityPlacer, x: int, z: int) -> void:
	p.aim_ray(Vector3((x + 0.5) * STUD, 60.0, (z + 0.5) * STUD), Vector3(0, -1, 0))


## A 2 x 4 studs, 2 bricks tall slab of a build: easy to reason about.
func _block_build() -> BuildRecipe:
	var r := BuildRecipe.new()
	for y in 2:
		r.add("brick_2x4_z", Vector3i(0, 1 + y * 3, 0), 4)
	return r


func _on_grid(x: Transform3D) -> bool:
	var o := x.origin
	var ok := true
	for v in [o.x / STUD, o.y / PLATE, o.z / STUD]:
		ok = ok and absf(v - round(v)) < 1e-3
	for axis in [x.basis.x, x.basis.z]:
		ok = ok and (absf(absf(axis.x) - 1.0) < 1e-4 or absf(absf(axis.z) - 1.0) < 1e-4)
	return ok


func _init() -> void:
	print("city place probe")
	var w := BrickWorld.new()
	var reg := BuildingRegistry.new(w, TowerRecipe.bake_palette(w))
	# A 24 x 24 tower, 18 courses, standing on studs 0..23.
	reg.register(24, 24, 18, Transform3D())
	var top := TowerRecipe.total_plates(18)
	var p := CityPlacer.new()
	root.add_child(p)
	p.setup(reg, null)
	var placed := []
	p.on_placed = func(id: int) -> void: placed.append(id)
	p.hold(_block_build(), "block")

	print("\non the ground: centred on the stud aimed at")
	_down(p, 40, 40)
	_ok("the target is the ground stud", p._target == Vector3i(40, 0, 40), "%v" % p._target)
	# 2 x 4 footprint, half = (0, 1): centred cell is (40, 0, 39).
	_ok("the build covers it, centred", p._cell == Vector3i(40, 0, 39), "%v" % p._cell)
	_ok("and it fits", p._valid)
	_ok("its placement is on the grid", _on_grid(p.placement()), "%s" % p.placement())

	print("\non a tower: its roof")
	_down(p, 10, 10)
	_ok("the target is on the roof", p._target == Vector3i(10, top, 10), "%v" % p._target)
	_ok("and the build sits on it", p._cell.y == top and p._valid)

	print("\nnext to the tower: shifted to fit, still over the stud")
	_down(p, 24, 10)   # the ground stud just east of the tower's wall
	_ok("on the ground", p._cell.y == 0)
	_ok("flush against the wall, not in it", p._cell.x == 24 and p._valid, "%v" % p._cell)

	print("\nR turns it a quarter, still on the grid")
	p.turn()
	_down(p, 40, 40)
	var x := p.placement()
	_ok("turned a quarter", absf(absf(x.basis.x.z) - 1.0) < 1e-4, "%v" % x.basis.x)
	_ok("its box is now 4 x 2", p._turned_dims() == Vector3i(4, 6, 2), "%v" % p._turned_dims())
	_ok("and on the grid", _on_grid(x))
	var box := AABB(BrickWorld.grid_to_world(p._cell), Vector3(4 * STUD, 6 * PLATE, 2 * STUD))
	var ghost := x * AABB(Vector3.ZERO, Vector3(2 * STUD, 6 * PLATE, 4 * STUD))
	_ok("the turned build covers exactly the cells it was fitted to",
			ghost.position.is_equal_approx(box.position) and ghost.size.is_equal_approx(box.size),
			"%s vs %s" % [ghost, box])

	print("\nhold E: the height stays, and a blocked spot is red rather than moved")
	_down(p, 40, 40)
	p._hold_lock(true)
	_down(p, 10, 10)   # over the tower now, but locked at the ground
	_ok("still at ground height", p._cell.y == 0)
	_ok("inside the tower is red", not p._valid)
	p._hold_lock(false)

	print("\nLMB places it, where the ghost is")
	_down(p, 40, 40)
	var want := p.placement()
	var id := p.place()
	_ok("it registers", id >= 0 and placed == [id], "%d %s" % [id, placed])
	_ok("exactly where the ghost was", reg.get_building(id).xform.is_equal_approx(want))
	_down(p, 40, 40)
	_ok("aimed at again, the next one goes on TOP of it, as a brick would",
			p._cell.y == 6 and p._valid, "%v" % p._cell)
	p._lock = {"y": 0}
	_down(p, 40, 40)
	_ok("locked at the ground, the same spot is blocked now", not p._valid)
	_ok("so a click there places nothing", p.place() < 0)
	p._lock = {}

	print("\nthe wheel steps through the library")
	var lib := CityPlacer.library()
	_ok("the shipped prebuilts are in it", lib.has("res://builds/cottage.json")
			and lib.has("res://builds/watchtower.json"), "%s" % [lib])
	p.stop()
	p.toggle(lib[0])
	var first := p._name
	p.turn()
	p.cycle(1)
	_ok("the wheel picks the next build", p._name != first and p._index == 1,
			"%s -> %s" % [first, p._name])
	_ok("keeping the turn", p._turn == 1)
	for i in lib.size():
		p.cycle(1)
	_ok("and comes back round", p._index == 1, "%d" % p._index)
	p.stop()

	print("\nthe shell a build draws before it is damaged faces OUT")
	_check_shell_winding(w)

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Every triangle of a build's shell has to be wound the way the brick mesher
## winds its own, or back-face culling hides the outside and draws the inside
## -- which is what a placed build looked like until it was damaged.
func _check_shell_winding(w: BrickWorld) -> void:
	var sign_of := func(arrays: Array) -> Vector2i:
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var out := Vector2i.ZERO
		for t in range(0, idx.size(), 3):
			var a := v[idx[t]]
			var face := (v[idx[t + 1]] - a).cross(v[idx[t + 2]] - a)
			if face.dot(n[idx[t]]) > 0.0:
				out.x += 1
			else:
				out.y += 1
		return out
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(4, 3, 4))
	w.place_block(c, Vector3i.ZERO, TowerRecipe.bake_palette(w)["brick_2x4_z"], 4)
	var bricks: Vector2i = sign_of.call(w.build_chunk_mesh(c))
	var r := BuildRecipe.load_from("res://builds/cottage.json")
	var shell: Vector2i = sign_of.call(BuildShell.build_arrays(w, r))
	var brick_sign := 1 if bricks.x > 0 else -1
	var shell_sign := 1 if shell.x > 0 else -1
	_ok("the brick mesher winds every triangle one way", bricks.x == 0 or bricks.y == 0,
			"%v" % bricks)
	_ok("and the shell winds every triangle the same way", (shell.x == 0 or shell.y == 0)
			and shell_sign == brick_sign, "bricks %v, shell %v" % [bricks, shell])
