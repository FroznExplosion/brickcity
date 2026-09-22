extends SceneTree

## Acceptance probe for placement in the workshop.
##
##     godot --headless --path . --script tools/place_probe.gd
##
## Looking at a stud puts the part ON that stud, and at the underside of one
## puts it UNDER; holding E locks the plane and the ghost follows the cursor
## across it; RMB deletes what the cursor is on.
## Everything here was first checked by driving the scene by hand, and one of
## those hand checks was wrong in a way that looked like a pass -- a ghost that
## "slid through a wall" had in fact moved on top of it, which is correct. So
## every case is driven with exact rays through `_aim_ray`, and each asserts the
## one property it exists for.
##
## The workshop's own `_process` is switched off, so the real mouse cannot move
## the ghost between checks.

var _pass := 0
var _fail := 0
var _ws
var _frames := 0

const STUD := 0.35
const PLATE := 0.14


func _init() -> void:
	_ws = load("res://scenes/workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 2:
		return
	_ws.set_process(false)
	print("place probe (stud aim, E lock, RMB delete)")
	_check_top_stud()
	_check_aim_follows_the_cursor()
	_check_drag_along_the_locked_plane()
	_check_fits_beside_an_obstruction()
	_check_side_stud_snap()
	_check_sliding_off_a_side_stud_drops_the_weld()
	_check_looking_down_at_a_bracket_builds_on_top()
	_check_under()
	_check_rotate_last_and_undo()
	_check_delete()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# --- helpers ---------------------------------------------------------------

func _reset() -> void:
	while _ws._undo():
		pass
	_ws._hold_lock(false)
	_ws._frame = 0
	_ws._axis_z = false
	_ws._flip = false


func _hold(part: String, axis_z := false) -> void:
	_ws._part_index = BrickPalette.parts().find(part)
	_ws._axis_z = axis_z


## Place directly, bypassing the aim. For building the scenery a case needs.
func _put(part: String, cell: Vector3i, axis_z := false) -> int:
	_hold(part, axis_z)
	_ws._snapped = {}
	_ws._cell = cell
	_ws._update_ghost()
	var n: int = _ws.recipe.size()
	_ws._place()
	return _ws.recipe.size() - n


## A ray straight down onto the centre of a column of cells.
func _down(x: float, z: float) -> void:
	_ws._aim_ray(Vector3((x + 0.5) * STUD, 20.0, (z + 0.5) * STUD), Vector3(0, -1, 0))
	_ws._update_ghost()


func _delete_down(x: float, z: float) -> bool:
	return _ws._delete_ray(Vector3((x + 0.5) * STUD, 20.0, (z + 0.5) * STUD), Vector3(0, -1, 0))


func _arch() -> int:
	return _ws.palette[_ws._archetype_name()]


# ---------------------------------------------------------------------------

func _check_top_stud() -> void:
	print("\nlooking at a brick puts the part on the stud under the cursor")
	_reset()
	_ok("a 1x6 placed", _put("brick_1x6", Vector3i(20, 1, 20)) == 1)
	_hold("brick_1x4")
	_down(22, 20)
	_ok("the cursor is on a stud", _ws._stud != _ws.NO_STUD)
	_ok("that stud: column 22, on the brick's top (1 + 3 plates)",
			_ws._stud == Vector3i(22, 4, 20), "%v" % _ws._stud)
	_ok("the part covers it, centred: x 21..24", _ws._cell == Vector3i(21, 4, 20),
			"%v" % _ws._cell)
	_ok("in the upright grid", _ws._frame == 0)
	_ok("and it would connect", _ws._valid and _ws._joints > 0,
			"valid=%s joints=%d" % [_ws._valid, _ws._joints])


func _check_aim_follows_the_cursor() -> void:
	print("\nwithout E the height is whatever the cursor is on -- nothing is sticky")
	_reset()
	_hold("brick_2x2")
	_down(8, 8)
	_ok("on the baseplate top", _ws._cell.y == 1, "y = %d" % _ws._cell.y)
	_put("brick_2x2", Vector3i(12, 1, 8))
	_hold("brick_2x2")
	_down(12, 8)
	_ok("over a brick: on its top", _ws._cell.y == 4, "y = %d" % _ws._cell.y)
	_down(8, 8)
	_ok("back over bare floor: back on the floor (the old sticky plane stayed at 4)",
			_ws._cell.y == 1, "y = %d" % _ws._cell.y)


func _check_drag_along_the_locked_plane() -> void:
	print("\nholding E, the part walks across the locked plane one stud at a time")
	_reset()
	_put("brick_1x6", Vector3i(20, 1, 20))     # x 20..25
	_hold("brick_1x4")                           # 4 long, centred with half = 1
	_down(24, 20)
	_ws._hold_lock(true)
	_ok("E locks a plane", not _ws._lock.is_empty() and _ws._lock.y == 4)
	var xs := []
	var ys := {}
	var joints := []
	var valid := []
	for cx in range(24, 33):
		_down(cx, 20)
		xs.append(_ws._cell.x)
		ys[_ws._cell.y] = true
		joints.append(_ws._joints)
		valid.append(_ws._valid)

	var steps_ok := true
	for i in range(1, xs.size()):
		if xs[i] - xs[i - 1] != 1:
			steps_ok = false
	_ok("every step moves exactly one stud", steps_ok, "%s" % [xs])
	_ok("and the plane never changes, off the end of the brick too", ys.size() == 1 and ys.has(4),
			"%s" % [ys.keys()])

	# The case the lock exists for: the 1x4 overlapping the 1x6 by ONE stud.
	var one := xs.find(25)
	_ok("there is a position overlapping by exactly one stud (x = 25)", one >= 0)
	if one >= 0:
		_ok("and it connects by one column", joints[one] == 1, "joints = %d" % joints[one])

	# Past the end it is mid-air on the plane -- allowed, and it places.
	_ok("fully off the end it floats: no joints", joints[joints.size() - 1] == 0)
	_ok("but it is still a legal placement", valid[valid.size() - 1])
	var n: int = _ws.recipe.size()
	_ws._place()
	_ok("and it places in mid-air", _ws.recipe.size() == n + 1)

	_ws._hold_lock(false)
	_down(40, 40)
	_ok("letting go of E lets go of the plane", _ws._lock.is_empty() and _ws._cell.y == 1,
			"y = %d" % _ws._cell.y)


func _check_fits_beside_an_obstruction() -> void:
	print("\naiming next to a wall shifts the part to fit, instead of into the wall")
	_reset()
	# A two-course wall, x 30..33 at z = 30..31.
	_put("brick_2x4", Vector3i(30, 1, 30))
	_put("brick_2x4", Vector3i(30, 4, 30))
	_hold("brick_1x6")                           # 6 long, half = 2
	_down(29, 30)                                # the floor stud against the wall
	_ok("on the floor", _ws._cell.y == 1)
	_ok("covering the stud aimed at", _ws._cell.x <= 29 and _ws._cell.x + 6 > 29)
	_ok("pushed back flush: x = 24 (24..29, wall at 30)", _ws._cell.x == 24,
			"x = %d" % _ws._cell.x)
	_ok("and legal", _ws._valid)

	# With the plane locked the player is placing by hand: no shifting, and a
	# part that does not fit says so.
	_ws._hold_lock(true)
	_down(29, 30)
	_ok("E held: centred on the cursor (x = 27) and red", _ws._cell.x == 27 and not _ws._valid,
			"x = %d valid = %s" % [_ws._cell.x, _ws._valid])
	_ws._hold_lock(false)


## A bracket's i-th side stud, as the workshop sees it.
func _bracket_stud(cell: Vector3i, i := 0) -> Dictionary:
	var f0: int = _ws.asm.frames[0]
	var studs: Array = _ws._real_side_studs(f0, _ws.world.block_at(f0, cell))
	return studs[i] if i < studs.size() else {}


## A ray straight at a side stud, from in front of it, optionally offset.
func _at_stud(st: Dictionary, offset := Vector3.ZERO) -> void:
	var n := Vector3(st.dir as Vector3i)
	_ws._aim_ray(st.centre + n * 3.0 + offset, -n)
	_ws._update_ghost()


func _check_side_stud_snap() -> void:
	print("\nlooking at a bracket's side stud builds sideways off it, lined up with it")
	_reset()
	# A 1x4 bracket running along Z: its four side studs face +X.
	_ok("a 1x4 bracket placed", _put("bracket_1x4", Vector3i(14, 1, 10), true) == 1)
	var f0: int = _ws.asm.frames[0]
	var bid: int = _ws.world.block_at(f0, Vector3i(14, 1, 10))
	var studs: Array = _ws._real_side_studs(f0, bid)
	_ok("four side studs, one per stud of its length", studs.size() == 4, "%d" % studs.size())
	if studs.size() < 4:
		return
	var dirs_ok := true
	for st in studs:
		if st.dir != Vector3i(1, 0, 0):
			dirs_ok = false
	_ok("all down its long side (+X)", dirs_ok)
	@warning_ignore("integer_division")
	var drawn: int = _ws._side_stud_instances(f0).size() / 16
	_ok("and they are drawn", drawn == 4, "%d" % drawn)

	_hold("plate_2x2")
	var welds: int = _ws.asm.live_weld_count()
	_at_stud(studs[1])
	_ok("it snapped to the stud", not _ws._snapped.is_empty())
	_ok("in a grid that is not the upright one", _ws._frame != 0)
	var up: Vector3 = _ws.world.get_chunk_transform(_ws.chunk).basis.y
	_ok("turned to match: its up is the stud's direction (+X)",
			up.is_equal_approx(Vector3(1, 0, 0)), "%v" % up)
	_ok("legal, and shown as attached (not amber)", _ws._valid
			and _ws._ghost_material.albedo_color.b > 0.5)

	var n: int = _ws.recipe.size()
	_ws._place()
	_ok("it places", _ws.recipe.size() == n + 1)
	_ok("welded to the bracket", _ws.asm.live_weld_count() == welds + 1,
			"%d -> %d" % [welds, _ws.asm.live_weld_count()])

	var at: Array = _ws._placed_at[_ws._placed_at.size() - 1]
	var box: Array = _ws.world.get_block_ticks(_ws.asm.frames[at[0]], at[1])
	var blo: Vector3i = box[0]
	var bhi: Vector3i = blo + (box[1] as Vector3i)
	var brk: Array = _ws.world.get_block_ticks(f0, bid)
	var klo: Vector3i = brk[0]
	_ok("flush on the stud face, in exact ticks", blo.x == (studs[1].hi as Vector3i).x,
			"plate x %d vs face %d" % [blo.x, (studs[1].hi as Vector3i).x])
	_ok("standing flush with the bracket's base, not a tick off", blo.y == klo.y,
			"plate y %d vs bracket y %d" % [blo.y, klo.y])
	var c: Vector3 = studs[1].centre / (BrickPalette.STUD_M / BrickWorld.ticks_per_stud())
	_ok("and over the stud it was aimed at", c.z > blo.z and c.z < bhi.z and c.y > blo.y and c.y < bhi.y,
			"stud %v, plate %v..%v" % [c, blo, bhi])


func _check_sliding_off_a_side_stud_drops_the_weld() -> void:
	print("\nE on a side stud: slide along its plane, and the weld only while still on it")
	_reset()
	_put("bracket_1x2", Vector3i(14, 1, 10), true)
	var st := _bracket_stud(Vector3i(14, 1, 10), 0)
	if st.is_empty():
		_ok("the bracket has side studs", false)
		return
	_hold("plate_1x1")
	_at_stud(st)
	_ok("on the stud", not _ws._snapped.is_empty())
	var frame: int = _ws._frame
	_ws._hold_lock(true)
	_at_stud(st, Vector3(0, 0, -2.0))
	_ok("slid off sideways, same sideways grid", _ws._frame == frame)
	_ok("no longer held by the stud", _ws._snapped.is_empty())
	_at_stud(st)
	_ok("slid back on: held again", not _ws._snapped.is_empty())
	_ws._hold_lock(false)


func _check_looking_down_at_a_bracket_builds_on_top() -> void:
	print("\nlooking at a bracket's top, even from its stud side, builds on top")
	_reset()
	_put("bracket_1x2", Vector3i(20, 1, 20), true)
	_hold("brick_1x2", true)
	_down(20, 20)
	_ok("no side-stud snap from above", _ws._snapped.is_empty())
	_ok("upright grid", _ws._frame == 0)
	_ok("on top of it", _ws._cell.y == 4, "y = %d" % _ws._cell.y)
	# Steeply down from the stud side: the ray goes in through the top.
	var top := Vector3(20.5 * STUD, 4 * PLATE, 20.5 * STUD)
	var dir := Vector3(-0.3, -1.0, 0.0).normalized()
	_ws._aim_ray(top - dir * 3.0, dir)
	_ok("from the stud side at a steep angle, still on top", _ws._snapped.is_empty()
			and _ws._cell.y == 4, "y = %d" % _ws._cell.y)


func _check_under() -> void:
	print("\nlooking at the underside of a brick places the part under it")
	_reset()
	_put("brick_1x4", Vector3i(20, 4, 20))       # y 4..6, x 20..23, in mid-air
	_hold("brick_1x2")                           # 2 long, half = 0
	var up := Vector3(0, 1, 0)
	_ws._aim_ray(Vector3(21.5 * STUD, 0.3, 20.5 * STUD), up)
	_ws._update_ghost()
	_ok("under it: its top against the brick's underside (y = 4 - 3)",
			_ws._cell == Vector3i(21, 1, 20), "%v" % _ws._cell)
	_ok("and it clips on", _ws._valid and _ws._joints > 0,
			"valid=%s joints=%d" % [_ws._valid, _ws._joints])
	var n: int = _ws.recipe.size()
	_ws._place()
	_ok("it places", _ws.recipe.size() == n + 1)
	_hold("plate_1x1")
	_ws._aim_ray(Vector3(23.5 * STUD, 0.3, 20.5 * STUD), up)
	_ws._update_ghost()
	_ok("a plate under goes one plate down (y = 3)", _ws._cell == Vector3i(23, 3, 20),
			"%v" % _ws._cell)
	_ok("and clips too", _ws._valid and _ws._joints > 0)
	# Side-on to a plain brick is not under: it builds on top, as before.
	_ws._aim_ray(Vector3(21.5 * STUD, 5 * PLATE, 17.0 * STUD), Vector3(0, 0, 1))
	_ok("the plain side of a brick builds on its top", _ws._cell.y == 7, "y = %d" % _ws._cell.y)


func _check_rotate_last_and_undo() -> void:
	print("\nT turns the last brick, repeatedly; undo repeats")
	_reset()
	_put("brick_1x4", Vector3i(20, 1, 20))
	var seen := [_ws.recipe.part_of(0)]
	for i in 3:
		_ws._rotate_last()
		seen.append(_ws.recipe.part_of(_ws.recipe.size() - 1))
	_ok("x -> z -> x -> z", seen == ["brick_1x4_x", "brick_1x4_z", "brick_1x4_x", "brick_1x4_z"],
			"%s" % [seen])
	_ok("still one brick", _ws.recipe.size() == 1)
	_put("brick_2x2", Vector3i(30, 1, 30))
	_put("brick_2x2", Vector3i(34, 1, 30))
	var undone := 0
	while _ws._undo():
		undone += 1
	_ok("undo takes all three back", undone == 3 and _ws.recipe.is_empty(), "%d" % undone)


func _check_delete() -> void:
	print("\nRMB deletes what the cursor is on, from anywhere in the build")
	_reset()
	_put("brick_2x2", Vector3i(4, 1, 4))         # recipe 0
	_put("bracket_1x2", Vector3i(14, 1, 10), true)  # recipe 1
	var f0: int = _ws.asm.frames[0]
	_hold("plate_2x2")
	_at_stud(_bracket_stud(Vector3i(14, 1, 10), 1))
	_ws._place()                                 # recipe 2, welded 1 -> 2
	_ok("three bricks and a weld", _ws.recipe.size() == 3 and _ws.recipe.weld_count() == 1)

	_ok("the baseplate does not delete", not _delete_down(40, 40) and _ws.recipe.size() == 3)
	_ok("RMB on the first brick deletes it", _delete_down(4, 4))
	_ok("gone from the world", _ws.world.block_at(f0, Vector3i(4, 1, 4)) < 0)
	_ok("and from the recipe, the rest renumbered", _ws.recipe.size() == 2
			and _ws.recipe.part_of(0).begins_with("bracket_1x2"), "%d" % _ws.recipe.size())
	_ok("the weld follows its blocks down: 1->2 is now 0->1",
			_ws.recipe.weld_count() == 1 and _ws.recipe.weld_blocks(0) == Vector2i(0, 1))

	_ok("RMB on the bracket deletes it", _delete_down(14, 10))
	_ok("and a weld with a missing end is dropped", _ws.recipe.weld_count() == 0)
	_ok("undo still takes back what is left", _ws._undo() and _ws.recipe.is_empty())
	_ok("with nothing more to undo", not _ws._undo())

	_ws._frame = 0
	_ws._cell = Vector3i(12, 1, 12)
	_ws._place_staircase()
	@warning_ignore("integer_division")
	var mid := 12 + StaircaseRecipe.DIAMETER / 2
	_ok("RMB on a staircase deletes the whole fixture", _delete_down(mid, mid)
			and _ws.recipe.fixture_count() == 0 and _ws._fixture_blocks.is_empty())
	_ok("and its bricks", _ws.world.block_at(f0, Vector3i(mid, 1, mid)) < 0)
