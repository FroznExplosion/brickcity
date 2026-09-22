extends SceneTree

## Acceptance probe for anchored placement in the workshop.
##
##     godot --headless --path . --script tools/place_probe.gd
##
## Looking at a stud picks a PLANE; the ghost then slides on it following the
## cursor. Everything here was first checked by driving the scene by hand, and
## one of those hand checks was wrong in a way that looked like a pass -- a
## ghost that "slid through a wall" had in fact re-anchored on top of it, which
## is correct. So every case is driven with exact rays through `_aim_ray`, and
## each asserts the one property it exists for.
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
	print("place probe (anchored placement)")
	_check_top_anchor()
	_check_drag_along_the_plane()
	_check_nearer_thing_re_anchors()
	_check_ghost_stops_at_obstruction()
	_check_side_stud_snap()
	_check_looking_down_at_a_bracket_builds_on_top()
	_check_rotate_last_and_undo()
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
	_ws._anchor = {}
	_ws._has_good = false
	_ws._frame = 0
	_ws._axis_z = false
	_ws._flip = false


func _hold(part: String, axis_z := false) -> void:
	_ws._part_index = BrickPalette.parts().find(part)
	_ws._axis_z = axis_z
	_ws._has_good = false


## Place directly, bypassing the aim. For building the scenery a case needs.
func _put(part: String, cell: Vector3i, axis_z := false) -> int:
	_hold(part, axis_z)
	_ws._cell = cell
	_ws._update_ghost()
	var n: int = _ws.recipe.size()
	_ws._place()
	return _ws.recipe.size() - n


## A ray straight down onto the centre of a column of cells.
func _down(x: float, z: float) -> void:
	_ws._aim_ray(Vector3((x + 0.5) * STUD, 20.0, (z + 0.5) * STUD), Vector3(0, -1, 0))
	_ws._update_ghost()


func _arch() -> int:
	return _ws.palette[_ws._archetype_name()]


# ---------------------------------------------------------------------------

func _check_top_anchor() -> void:
	print("\nlooking at a brick anchors to its top")
	_reset()
	_ok("a 1x6 placed", _put("brick_1x6", Vector3i(20, 1, 20)) == 1)
	_hold("brick_1x4")
	_down(22, 20)
	_ok("the ghost anchored", not _ws._anchor.is_empty())
	_ok("on the brick's top: 1 + 3 plates", _ws._cell.y == 4, "y = %d" % _ws._cell.y)
	_ok("in the upright grid", _ws._frame == 0)
	_ok("and it would connect", _ws._valid and _ws._joints > 0,
			"valid=%s joints=%d" % [_ws._valid, _ws._joints])


func _check_drag_along_the_plane() -> void:
	print("\ndragging walks the part along the plane, one stud at a time")
	_reset()
	_put("brick_1x6", Vector3i(20, 1, 20))     # x 20..25
	_hold("brick_1x4")                           # 4 long, centred with half = 1
	_down(24, 20)
	var xs := []
	var ys := {}
	var joints := []
	for cx in range(24, 33):
		_down(cx, 20)
		xs.append(_ws._cell.x)
		ys[_ws._cell.y] = true
		joints.append(_ws._joints)

	var steps_ok := true
	for i in range(1, xs.size()):
		if xs[i] - xs[i - 1] != 1:
			steps_ok = false
	_ok("every step moves exactly one stud", steps_ok, "%s" % [xs])
	_ok("and the plane never changes", ys.size() == 1 and ys.has(4), "%s" % [ys.keys()])
	_ok("the anchor survives dragging off the end (the floor is further away)",
			not _ws._anchor.is_empty() and _ws._cell.y == 4)

	# The case the drag exists for: the 1x4 overlapping the 1x6 by ONE stud.
	var one := xs.find(25)
	_ok("there is a position overlapping by exactly one stud (x = 25)", one >= 0)
	if one >= 0:
		_ok("and it connects by one column", joints[one] == 1, "joints = %d" % joints[one])

	# Past the end it is mid-air on the plane -- allowed, and it places.
	_ok("fully off the end it floats: no joints", joints[joints.size() - 1] == 0)
	_ok("but it is still a legal placement", _ws._valid)
	var n: int = _ws.recipe.size()
	_ws._place()
	_ok("and it places in mid-air", _ws.recipe.size() == n + 1)


func _check_nearer_thing_re_anchors() -> void:
	print("\nsomething nearer than the plane takes the anchor")
	_reset()
	_hold("brick_2x2")
	_down(8, 8)                                  # the baseplate
	_ok("anchored on the baseplate top", _ws._cell.y == 1, "y = %d" % _ws._cell.y)
	_put("brick_2x2", Vector3i(12, 1, 8))
	_hold("brick_2x2")
	_ws._anchor = {}
	_down(8, 8)
	_down(12, 8)                                 # now over the brick
	_ok("aiming at a brick on the floor re-anchors to its top",
			_ws._cell.y == 4, "y = %d" % _ws._cell.y)
	_down(8, 8)
	_ok("and back over bare floor, the floor is FURTHER than the brick's plane, so it stays",
			_ws._cell.y == 4, "y = %d" % _ws._cell.y)


func _check_ghost_stops_at_obstruction() -> void:
	print("\nthe ghost stops against an obstruction instead of passing into it")
	_reset()
	# A two-course wall, x 30..33 at z = 30.
	_put("brick_2x4", Vector3i(30, 1, 30))
	_put("brick_2x4", Vector3i(30, 4, 30))
	_hold("brick_1x6")                           # 6 long, half = 2
	_down(20, 30)                                # anchor on the floor beside it
	_ok("anchored on the floor", _ws._cell.y == 1)

	# Walk the cursor toward the wall. The cursor itself never goes over the wall
	# -- that would re-anchor on its top, which is correct and not what this
	# checks -- but the far end of the 1x6 does reach into it.
	var inside := 0
	var max_x := -1
	for cx in range(20, 30):
		_down(cx, 30)
		if not _ws.asm.can_place(_ws.chunk, _ws._cell, _arch()):
			inside += 1
		max_x = maxi(max_x, _ws._cell.x)
	_ok("at no step is the ghost inside the wall", inside == 0, "%d steps inside" % inside)
	_ok("it stops flush: the last good cell is x = 24 (24..29, wall at 30)",
			max_x == 24, "max x = %d" % max_x)
	_ok("and still on the floor plane", _ws._cell.y == 1)


func _check_side_stud_snap() -> void:
	print("\nlooking at a bracket's side stud builds sideways off it")
	_reset()
	_put("brick_2x4", Vector3i(10, 1, 10))       # z 10..11
	_ok("a bracket placed, studs facing +Z", _put("bracket_1x2", Vector3i(14, 1, 10), true) == 1)
	var f0: int = _ws.asm.frames[0]
	var bid: int = _ws.world.block_at(f0, Vector3i(14, 1, 11))
	var studs: Array = _ws.world.get_side_studs(f0, bid)
	_ok("it exposes side studs", studs.size() > 0, "%d" % studs.size())
	if studs.is_empty():
		return

	_hold("plate_2x2")
	var target: Vector3 = _ws._stud_world_centre(studs[1])
	var welds: int = _ws.asm.live_weld_count()
	# Horizontally at the face, from in front of it.
	_ws._aim_ray(target + Vector3(0, 0, 3.0), Vector3(0, 0, -1))
	_ws._update_ghost()
	_ok("it snapped to the stud", not _ws._snapped.is_empty())
	_ok("in a grid that is not the upright one", _ws._frame != 0)
	var up: Vector3 = _ws.world.get_chunk_transform(_ws.chunk).basis.y
	_ok("whose up is the stud's direction (+Z)", up.is_equal_approx(Vector3(0, 0, 1)),
			"%v" % up)
	_ok("and the placement is legal", _ws._valid)

	var n: int = _ws.recipe.size()
	_ws._place()
	_ok("it places", _ws.recipe.size() == n + 1)
	_ok("welded to the bracket", _ws.asm.live_weld_count() == welds + 1,
			"%d -> %d" % [welds, _ws.asm.live_weld_count()])

	# Flush, not floating: the plate's face sits exactly on the stud's face plane.
	var at: Array = _ws._placed_at[_ws._placed_at.size() - 1]
	var box: Array = _ws.world.get_block_ticks(_ws.asm.frames[at[0]], at[1])
	var face: int = (studs[1].hi as Vector3i).z
	_ok("the plate sits flush on the stud face, in exact ticks",
			(box[0] as Vector3i).z == face, "plate z %d vs face %d" % [(box[0] as Vector3i).z, face])


func _check_looking_down_at_a_bracket_builds_on_top() -> void:
	print("\nlooking straight down at a bracket builds on its top, not its side")
	_reset()
	_put("bracket_1x2", Vector3i(20, 1, 20), true)
	_hold("brick_1x2", true)
	_down(20, 20)
	_ok("no side-stud snap from above", _ws._snapped.is_empty())
	_ok("upright grid", _ws._frame == 0)
	_ok("on top of it", _ws._cell.y == 4, "y = %d" % _ws._cell.y)


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
