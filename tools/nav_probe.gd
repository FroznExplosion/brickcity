extends SceneTree

## Acceptance probe for AINav, grid-native navigation (Docs/AIPlan.md P3).
##
##     godot --headless --path . --script tools/nav_probe.gd
##
## A figure walks where the bricks let it: through a door it fits (two studs is
## the body; one is not), under a ceiling it can stand or crouch under, up a
## brick course and not two, off a ledge of three courses and not four. A wall
## shot through is a way through the moment the columns are re-read. A proxy --
## a pristine building's shell -- is a wall. The queue serves fifty requesters
## inside its budget, the important first. The city gate (-- --nav) does the
## same against real towers, stairs and all.

const STUD := 0.35
const PLATE := 0.14

var _pass := 0
var _fail := 0
var w: BrickWorld
var palette: Dictionary
var ai: AIWorld
var nav: AINav
var _changed := []


func _init() -> void:
	print("nav probe")
	w = BrickWorld.new()
	palette = TowerRecipe.bake_palette(w)
	ai = AIWorld.new()
	ai.set_world(w)
	nav = AINav.new()
	nav.set_ai_world(ai)
	nav.nav_changed.connect(func(box: AABB) -> void: _changed.append(box))
	_check_open_ground()
	_check_doors()
	_check_headroom()
	_check_steps_and_drops()
	_check_hole()
	_check_proxy()
	_check_queue()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A chunk from `lo` (absolute cells) of `dims`, empty.
func _chunk(lo: Vector3i, dims: Vector3i) -> int:
	return w.create_chunk(lo, dims)


## Fill a box of cells (absolute) with one-plate tiles.
func _fill(chunk: int, at: Vector3i, size: Vector3i) -> void:
	for x in size.x:
		for y in size.y:
			for z in size.z:
				w.place_block(chunk, at + Vector3i(x, y, z), palette["tile_1x1"], 2)


func _m(cell: Vector3i) -> Vector3:
	return Vector3(cell.x * STUD, cell.y * PLATE, cell.z * STUD)


func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


func _sync() -> void:
	ai.sync()
	nav.clear_cache()


# ---------------------------------------------------------------------------

func _check_open_ground() -> void:
	print("\nopen ground")
	_sync()
	var a := Vector3(1, 0, 1)
	var b := Vector3(16, 0, 9)
	var p := nav.find_path(a, b)
	_ok("a path across open ground", p.size() >= 2, "%d corners" % p.size())
	_ok("that goes more or less straight", _length(p) < a.distance_to(b) * 1.1,
			"%.1f m for %.1f" % [_length(p), a.distance_to(b)])
	_ok("from where it was asked to where it was asked",
			p.size() > 0 and p[0].distance_to(a) < 0.6 and p[-1].distance_to(b) < 0.6)


## A room 12 studs square inside, walls one stud thick and six courses tall,
## with a doorway `door` studs wide in its -Z wall.
func _room(corner: Vector3i, door: int) -> int:
	var c := _chunk(corner, Vector3i(14, 20, 14))
	for i in 14:
		for side in [0, 13]:
			_fill(c, corner + Vector3i(i, 0, side), Vector3i(1, 18, 1))
			if i > 0 and i < 13:
				_fill(c, corner + Vector3i(side, 0, i), Vector3i(1, 18, 1))
	# The doorway: take the -Z wall's middle out.
	var mid := 7 - door / 2
	for i in door:
		for y in 18:
			var id := w.block_at(c, corner + Vector3i(mid + i, y, 0))
			if id >= 0:
				w.kill_blocks(c, PackedInt32Array([id]))
	return c


func _check_doors() -> void:
	print("\ndoors: the body is two studs wide")
	var narrow := _room(Vector3i(100, 0, 0), 1)
	var wide := _room(Vector3i(140, 0, 0), 3)
	_sync()
	var outside := _m(Vector3i(107, 0, -8))
	var in_narrow := _m(Vector3i(107, 0, 7))
	var p1 := nav.find_path(outside, in_narrow, 20000)
	_ok("a one-stud door lets nobody in", p1.is_empty())
	var p2 := nav.find_path(_m(Vector3i(147, 0, -8)), _m(Vector3i(147, 0, 7)), 20000)
	_ok("a three-stud door does", p2.size() >= 2, "%.1f m" % _length(p2))


func _check_headroom() -> void:
	print("\nheadroom: stand at 12 plates, crouch at 9")
	var c := _chunk(Vector3i(200, 0, 0), Vector3i(30, 20, 6))
	# Three slabs over open ground, at 8, 10 and 13 plates.
	_fill(c, Vector3i(200, 8, 0), Vector3i(6, 1, 6))
	_fill(c, Vector3i(210, 10, 0), Vector3i(6, 1, 6))
	_fill(c, Vector3i(220, 13, 0), Vector3i(6, 1, 6))
	_sync()
	_ok("under eight plates, nobody", not nav.can_stand(_m(Vector3i(202, 0, 2))))
	_ok("under ten, crouching", nav.can_stand(_m(Vector3i(212, 0, 2))))
	_ok("under thirteen, standing", nav.can_stand(_m(Vector3i(222, 0, 2))))
	_ok("and on top of each slab, under the sky", nav.can_stand(_m(Vector3i(202, 9, 2)))
			and nav.can_stand(_m(Vector3i(222, 14, 2))))


func _check_steps_and_drops() -> void:
	print("\nsteps and drops")
	var c := _chunk(Vector3i(300, 0, 0), Vector3i(60, 20, 8))
	# A platform one course high, one two courses high, and one two courses high
	# with a one-course step in front of it.
	_fill(c, Vector3i(300, 0, 0), Vector3i(6, 3, 6))
	_fill(c, Vector3i(310, 0, 0), Vector3i(6, 6, 6))
	_fill(c, Vector3i(320, 0, 0), Vector3i(6, 6, 6))
	_fill(c, Vector3i(318, 0, 0), Vector3i(2, 3, 6))
	# Ledges three and four courses high, to jump off.
	_fill(c, Vector3i(330, 0, 0), Vector3i(6, 9, 6))
	_fill(c, Vector3i(340, 0, 0), Vector3i(6, 12, 6))
	_sync()
	var ground := _m(Vector3i(303, 0, 7))
	_ok("up one course: walked", not nav.find_path(ground, _m(Vector3i(303, 3, 3)), 20000).is_empty())
	_ok("up two courses: not without a step",
			nav.find_path(_m(Vector3i(313, 0, 7)), _m(Vector3i(313, 6, 3)), 20000).is_empty())
	_ok("up two courses with a step: walked",
			not nav.find_path(_m(Vector3i(316, 0, 3)), _m(Vector3i(323, 6, 3)), 20000).is_empty())
	_ok("off three courses: dropped",
			not nav.find_path(_m(Vector3i(333, 9, 3)), _m(Vector3i(333, 0, 7)), 20000).is_empty())
	_ok("off four: not", nav.find_path(_m(Vector3i(343, 12, 3)), _m(Vector3i(343, 0, 7)), 20000).is_empty())


func _check_hole() -> void:
	print("\na wall shot through is a way through")
	var room := _room(Vector3i(400, 0, 0), 3)
	_sync()
	# From behind the room, to its middle: round to the door on the far side.
	var behind := _m(Vector3i(407, 0, 18))
	var inside := _m(Vector3i(407, 0, 7))
	var before := nav.find_path(behind, inside, 40000)
	_ok("from behind, the way in is round to the door", before.size() >= 2,
			"%.1f m" % _length(before))
	# Blow the +Z wall open, the way a gun would, and say so.
	var hole := _m(Vector3i(407, 0, 13)) + Vector3(0.0, 1.0, 0.175)
	w.apply_hit(room, hole, 1.0)
	_changed.clear()
	nav.invalidate_box(AABB(hole - Vector3(1.2, 1.2, 1.2), Vector3(2.4, 2.4, 2.4)))
	var t0 := Time.get_ticks_usec()
	var after := nav.find_path(behind, inside, 40000)
	var us := Time.get_ticks_usec() - t0
	_ok("the change was announced (nav_changed)", _changed.size() == 1)
	_ok("and the new way is through the hole", after.size() >= 2
			and _length(after) < _length(before) - 4.0,
			"%.1f m, was %.1f; re-read and re-pathed in %d us" % [_length(after), _length(before), us])


func _check_proxy() -> void:
	print("\na proxy is a wall")
	_sync()
	var a := Vector3(-40, 0, 0)
	var b := Vector3(-40, 0, 10)
	var straight := _length(nav.find_path(a, b))
	ai.set_proxy(9, Transform3D(Basis(), Vector3(-40, 2, 5)), Vector3(8, 4, 0.7), 1.0 / STUD)
	nav.invalidate_box(AABB(Vector3(-45, 0, 4), Vector3(10, 5, 2)))
	var round := _length(nav.find_path(a, b))
	_ok("a shell's box is walked round, not through", round > straight + 2.0,
			"%.1f m, straight %.1f" % [round, straight])
	ai.remove_proxy(9)
	nav.invalidate_box(AABB(Vector3(-45, 0, 4), Vector3(10, 5, 2)))


func _check_queue() -> void:
	print("\nfifty requesters")
	_sync()
	nav.reset_stats()
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	var ids := []
	var pri := {}
	for i in 50:
		var a := Vector3(rng.randf_range(-60, 60), 0, rng.randf_range(-60, -20))
		var b := Vector3(rng.randf_range(-60, 60), 0, rng.randf_range(-60, -20))
		var p := rng.randf() * 10.0
		var id := nav.request_path(a, b, p)
		ids.append(id)
		pri[id] = p
	var done_at := {}
	var worst := 0
	var frames := 0
	while nav.pending() > 0 and frames < 400:
		var t0 := Time.get_ticks_usec()
		nav.service(500)
		worst = maxi(worst, Time.get_ticks_usec() - t0)
		frames += 1
		for id in ids:
			if not done_at.has(id) and nav.get_status(id) != AINav.PENDING:
				done_at[id] = frames
	var ok_paths := 0
	for id in ids:
		if nav.get_status(id) == AINav.DONE:
			ok_paths += 1
	_ok("every one answered", done_at.size() == 50 and ok_paths == 50,
			"%d paths over %d frames" % [ok_paths, frames])
	# Half a millisecond a frame (AI.md 10.1), checked every 32 nodes.
	_ok("inside half a millisecond a frame", worst < 800, "worst %d us" % worst)
	ids.sort_custom(func(x, y): return pri[x] > pri[y])
	var top := 0.0
	var bottom := 0.0
	for k in 10:
		top += done_at.get(ids[k], frames)
		bottom += done_at.get(ids[49 - k], frames)
	_ok("the important first", top < bottom, "top ten by frame %.1f, bottom ten %.1f" % [
			top / 10.0, bottom / 10.0])
	var st := nav.get_stats()
	print("  %d expansions, %d columns read, %.1f ms searching" % [
			int(st.expansions), int(st.columns_read), float(st.search_ms)])
