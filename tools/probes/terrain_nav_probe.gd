extends SceneTree

## TerrainNav, the mine world's creature nav (Docs/MineCreatures.md 2). Headless.
##
##     godot --headless --path . --script res://tools/probes/terrain_nav_probe.gd
##
## Each check builds its own test ground high in the sky (plate 3000, over any
## generated ground), so the answers are about the rules, not the seed:
##
##   * open floor: a path is found and reached.
##   * gaps: a 2-stud gap in a wall lets a zombie (2 studs) through, and the
##     path goes through the gap; a 1-stud gap does not, but lets a 1-stud
##     body (a rabbit-sized one) through -- "only cells a body fits in".
##   * walls: one brick (3 plates) is stepped over, two bricks (6) stop a
##     zombie -- the user's rule: zombies get over 1 brick, 2 stop them.
##   * headroom: an 11-plate opening is shut to a zombie (12 tall), a 12-plate
##     one open; a pig (6) goes through the 11.
##   * drops: down off a 2-brick ledge, but not back up it.
##   * edits: a wall opened by an edit is a way through after invalidate_box.
##   * the flow field: walking it from the start reaches the goal; outside a
##     sealed ring it has no answer.
##   * sight: line_clear is blocked by a wall and clear over it.
##   * fences (MineFences): a 2-brick fence stops a zombie and a pig, a body
##     that climbs 2 bricks gets over it, a 3-brick one stops that too.
##   * cost: a field of radius 96 studs on flat test ground and on the real
##     ground at the spawn, and a 30 m path there (printed; a budget check).

const F := 3000
const ZOMBIE := Vector4i(2, 12, 3, 19)
const PIG := Vector4i(2, 6, 3, 9)
const SMALL := Vector4i(1, 3, 3, 9)
const JUMPER := Vector4i(2, 11, 6, 19)

var failures := 0
var nav := TerrainNav.new()
var stud := 0.35
var plate := 0.14
var _area := 0


func _initialize() -> void:
	preload("res://scripts/terrain/worldgen_presets.gd").apply_fitted_flag()
	BrickTerrain.configure(424242)
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	stud = BrickWorld.get_stud_metres()
	plate = BrickWorld.get_plate_metres()
	_check_open()
	_check_gaps()
	_check_walls()
	_check_headroom()
	_check_drops()
	_check_edits()
	_check_field()
	_check_sight()
	_check_fences()
	_check_obstacles()
	_check_cost()
	print("[terrain-nav] %s (%d failed)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


func check(what: String, ok: bool) -> void:
	print("[terrain-nav] %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


## A fresh 60 x 60 stone floor at plate F, far from the others: its corner column.
func _floor() -> Vector2i:
	_area += 1
	var o := Vector2i(_area * 200, 5000)
	BrickTerrain.fill_box(Vector3i(o.x, F, o.y), Vector3i(o.x + 59, F, o.y + 59), BrickTerrain.MAT_STONE, false)
	return o


func _box(lo: Vector3i, hi: Vector3i, m := BrickTerrain.MAT_STONE) -> void:
	BrickTerrain.fill_box(lo, hi, m, false)
	nav.invalidate_box(lo, hi)


## Feet of a W-stud body whose footprint corner is column (x, z), on the floor.
func _at(x: int, z: int, w := 2, up := 0) -> Vector3:
	return Vector3((x + w * 0.5) * stud, (F + 1 + up) * plate, (z + w * 0.5) * stud)


func _path(from: Vector3, to: Vector3, body: Vector4i) -> Dictionary:
	return nav.find_path(from, to, body, 20000)


## A wall along z = z0 + zw across the whole floor, `h` plates high over it.
func _wall(o: Vector2i, zw: int, h: int) -> void:
	_box(Vector3i(o.x, F + 1, o.y + zw), Vector3i(o.x + 59, F + h, o.y + zw))


func _check_open() -> void:
	var o := _floor()
	var r := _path(_at(o.x + 5, o.y + 5), _at(o.x + 50, o.y + 5), ZOMBIE)
	check("open floor: reached in %d nodes (%d points)" % [r.expanded, r.path.size()], r.reached and r.path.size() >= 40)
	check("a point off the floor is no start", nav.find_path(_at(o.x + 5, o.y + 5, 2, 40), _at(o.x + 50, o.y + 5), ZOMBIE, 2000).path.is_empty())


func _check_gaps() -> void:
	var o := _floor()
	_wall(o, 30, 20)
	_box(Vector3i(o.x + 30, F + 1, o.y + 30), Vector3i(o.x + 31, F + 20, o.y + 30), 0)
	var r := _path(_at(o.x + 10, o.y + 20), _at(o.x + 10, o.y + 40), ZOMBIE)
	var through := false
	for p in r.path:
		var cx := floori(p.x / stud)
		var cz := floori(p.z / stud)
		if cz == o.y + 30 or cz == o.y + 31:
			through = through or (cx >= o.x + 30 and cx <= o.x + 32)
	check("a 2-stud gap lets a zombie through (reached %s, via the gap %s)" % [r.reached, through], r.reached and through)
	# Narrow it to one stud.
	_box(Vector3i(o.x + 31, F + 1, o.y + 30), Vector3i(o.x + 31, F + 20, o.y + 30))
	var r2 := _path(_at(o.x + 10, o.y + 20), _at(o.x + 10, o.y + 40), ZOMBIE)
	check("a 1-stud gap does not (reached %s, %d nodes)" % [r2.reached, r2.expanded], not r2.reached)
	var r3 := _path(_at(o.x + 10, o.y + 20, 1), _at(o.x + 10, o.y + 40, 1), SMALL)
	check("a 1-stud body gets through the 1-stud gap", r3.reached)
	var last: Vector3 = r2.path[r2.path.size() - 1] if not r2.path.is_empty() else Vector3.INF
	check("shut out, the path ends at the wall (%.1f m from it)" % absf(last.z - (o.y + 30) * stud),
			last != Vector3.INF and absf(last.z - (o.y + 30) * stud) < 1.2)


func _check_walls() -> void:
	var o := _floor()
	_wall(o, 30, 3)
	var r := _path(_at(o.x + 10, o.y + 20), _at(o.x + 10, o.y + 40), ZOMBIE)
	check("a wall 1 brick high is stepped over", r.reached)
	var o2 := _floor()
	_wall(o2, 30, 6)
	var r2 := _path(_at(o2.x + 10, o2.y + 20), _at(o2.x + 10, o2.y + 40), ZOMBIE)
	check("a wall 2 bricks high stops a zombie", not r2.reached)
	var r3 := _path(_at(o2.x + 10, o2.y + 20), _at(o2.x + 10, o2.y + 40), JUMPER)
	check("...and a body that climbs 2 bricks gets over it", r3.reached)


func _check_headroom() -> void:
	for h in [11, 12]:
		var o := _floor()
		_wall(o, 30, 30)
		# A 2-wide doorway h plates high, thick 1.
		_box(Vector3i(o.x + 30, F + 1, o.y + 30), Vector3i(o.x + 31, F + h, o.y + 30), 0)
		var r := _path(_at(o.x + 10, o.y + 20), _at(o.x + 10, o.y + 40), ZOMBIE)
		check("a doorway %d plates high: zombie %s" % [h, "through" if r.reached else "shut out"], r.reached == (h >= 12))
		if h == 11:
			var rp := _path(_at(o.x + 10, o.y + 20), _at(o.x + 10, o.y + 40), PIG)
			check("a pig goes through the 11-plate doorway", rp.reached)


func _check_drops() -> void:
	var o := _floor()
	# A ledge 2 bricks up over half the floor.
	_box(Vector3i(o.x, F + 1, o.y + 30), Vector3i(o.x + 59, F + 6, o.y + 59))
	var top := _at(o.x + 10, o.y + 45, 2, 6)
	var low := _at(o.x + 10, o.y + 15)
	check("down off a 2-brick ledge", _path(top, low, ZOMBIE).reached)
	check("not back up it", not _path(low, top, ZOMBIE).reached)


func _check_edits() -> void:
	var o := _floor()
	_wall(o, 30, 20)
	var a := _at(o.x + 10, o.y + 20)
	var b := _at(o.x + 10, o.y + 40)
	var before: bool = _path(a, b, ZOMBIE).reached
	BrickTerrain.fill_box(Vector3i(o.x + 20, F + 1, o.y + 30), Vector3i(o.x + 22, F + 20, o.y + 30), 0, false)
	var stale: bool = _path(a, b, ZOMBIE).reached
	nav.invalidate_box(Vector3i(o.x + 20, F + 1, o.y + 30), Vector3i(o.x + 22, F + 20, o.y + 30))
	var after: bool = _path(a, b, ZOMBIE).reached
	check("an edit opens a way once its box is invalidated (before %s, kept %s, after %s)" % [before, stale, after],
			not before and not stale and after)


func _check_field() -> void:
	var o := _floor()
	_wall(o, 30, 20)
	_box(Vector3i(o.x + 40, F + 1, o.y + 30), Vector3i(o.x + 41, F + 20, o.y + 30), 0)
	var goal := _at(o.x + 10, o.y + 45)
	var id := nav.build_field(goal, 60, ZOMBIE, 90000)
	check("a field is built (%d nodes)" % nav.field_size(id), id != 0 and nav.field_size(id) > 1000)
	var p := _at(o.x + 10, o.y + 10)
	var steps := 0
	while steps < 400:
		var n := nav.field_next(id, p)
		if n == Vector3.INF or n.distance_to(p) < 0.01:
			break
		p = n
		steps += 1
	check("walking the field reaches the goal (%d steps, %.2f m off)" % [steps, p.distance_to(goal)], p.distance_to(goal) < 0.8)
	check("its cost from the start is more than the straight line (round by the gap): %.1f m" % nav.field_cost(id, _at(o.x + 10, o.y + 10)),
			nav.field_cost(id, _at(o.x + 10, o.y + 10)) > 14.0)
	nav.release_field(id)
	# Sealed in: a ring of 2-brick wall round the goal.
	var o2 := _floor()
	_box(Vector3i(o2.x + 20, F + 1, o2.y + 20), Vector3i(o2.x + 40, F + 6, o2.y + 40))
	_box(Vector3i(o2.x + 21, F + 1, o2.y + 21), Vector3i(o2.x + 39, F + 6, o2.y + 39), 0)
	var id2 := nav.build_field(_at(o2.x + 30, o2.y + 30), 60, ZOMBIE, 90000)
	check("sealed in a 2-brick ring, the field has no answer outside it",
			nav.field_next(id2, _at(o2.x + 5, o2.y + 5)) == Vector3.INF and nav.field_next(id2, _at(o2.x + 25, o2.y + 25)) != Vector3.INF)
	nav.release_field(id2)


func _check_sight() -> void:
	var o := _floor()
	_wall(o, 30, 12)
	var a := _at(o.x + 10, o.y + 20) + Vector3(0, 1.0, 0)
	var b := _at(o.x + 10, o.y + 40) + Vector3(0, 1.0, 0)
	check("a wall blocks the line", not nav.line_clear(a, b))
	check("over its top the line is clear", nav.line_clear(a + Vector3(0, 1.2, 0), b + Vector3(0, 1.2, 0)))


func _fence_line(o: Vector2i, zf: int, plates: int) -> void:
	# Past both ends: the panels snap to the 3-stud lattice, not to the floor's corner.
	for a0 in range(-3, 63, 3):
		var at := Vector3i(o.x + a0, F + 1, o.y + zf)
		MineFences.place(at, true, plates, BrickTerrain.MAT_STONE)
	nav.invalidate_box(Vector3i(o.x - 3, F, o.y + zf), Vector3i(o.x + 63, F + plates, o.y + zf))


func _check_fences() -> void:
	var o := _floor()
	_fence_line(o, 30, 6)
	check("a fence panel is laid as posts and rails", MineFences.is_laid(Vector3i(o.x + 3, F + 1, o.y + 30), true, 6))
	# Rails at plates 2 and 5 up (F + 3, F + 6), air under each, between posts.
	var rail_x := floori(float(o.x + 3) / MineFences.SPAN) * MineFences.SPAN + 1
	check("a 2-brick fence has see-through gaps", BrickTerrain.solid_at(rail_x, F + 1, o.y + 30) == 0
			and BrickTerrain.solid_at(rail_x, F + 4, o.y + 30) == 0 and BrickTerrain.solid_at(rail_x, F + 3, o.y + 30) != 0
			and BrickTerrain.solid_at(rail_x, F + 6, o.y + 30) != 0)
	var a := _at(o.x + 10, o.y + 20)
	var b := _at(o.x + 10, o.y + 40)
	check("a 2-brick fence stops a zombie", not _path(a, b, ZOMBIE).reached)
	check("a 2-brick fence stops a pig", not _path(a, b, PIG).reached)
	check("a 2-brick fence stops a 1-stud body (no hole it fits)", not _path(_at(o.x + 10, o.y + 20, 1), _at(o.x + 10, o.y + 40, 1), SMALL).reached)
	check("a body that climbs 2 bricks gets over a 2-brick fence", _path(a, b, JUMPER).reached)
	var o2 := _floor()
	_fence_line(o2, 30, 9)
	check("a 3-brick fence stops that one too", not _path(_at(o2.x + 10, o2.y + 20), _at(o2.x + 10, o2.y + 40), JUMPER).reached)
	# Penned (free_reach, Docs/MineCreatures.md 11): a pig in a ring of
	# 2-brick fence cannot walk 24 studs out (32 in the game: this floor is 60 across); on the open floor it can.
	var o3 := _floor()
	for a0 in range(18, 42, 3):
		for zz in [o3.y + 18, o3.y + 39]:
			MineFences.place(Vector3i(o3.x + a0, F + 1, zz), true, 6, BrickTerrain.MAT_STONE)
		for xx in [o3.x + 18, o3.x + 39]:
			MineFences.place(Vector3i(xx, F + 1, o3.y + a0), false, 6, BrickTerrain.MAT_STONE)
	nav.invalidate_box(Vector3i(o3.x, F, o3.y), Vector3i(o3.x + 59, F + 10, o3.y + 59))
	check("penned: a pig in a 2-brick fence ring cannot walk out", not nav.free_reach(_at(o3.x + 28, o3.y + 28), PIG, 24, 9000))
	check("penned: a pig on the open floor can", nav.free_reach(_at(o3.x + 4, o3.y + 4), PIG, 24, 9000))
	check("penned: a deer (climbs 2 bricks) is not penned by it", nav.free_reach(_at(o3.x + 28, o3.y + 28), JUMPER, 24, 9000))


## Tree trunks are physics boxes, not terrain: set_obstacles stamps them in.
func _check_obstacles() -> void:
	var o := _floor()
	var a := _at(o.x + 10, o.y + 20)
	var b := _at(o.x + 10, o.y + 40)
	# A row of "trunks" across the floor, 2 x 2 studs, 1 stud apart: no gap a zombie fits.
	var boxes := PackedVector3Array()
	for x in range(o.x - 2, o.x + 62, 3):
		boxes.append(Vector3(x, F + 1, o.y + 30))
		boxes.append(Vector3(x + 1, F + 30, o.y + 31))
	var before: bool = _path(a, b, ZOMBIE).reached
	nav.set_obstacles(7, boxes)
	var blocked: bool = _path(a, b, ZOMBIE).reached
	var small: bool = _path(_at(o.x + 10, o.y + 20, 1), _at(o.x + 10, o.y + 40, 1), SMALL).reached
	nav.remove_obstacles(7)
	var after: bool = _path(a, b, ZOMBIE).reached
	check("obstacles: a row of trunks 1 stud apart shuts a zombie out (open %s, with trunks %s, removed %s)" % [before, blocked, after],
			before and not blocked and after)
	check("obstacles: a 1-stud body slips between the trunks", small)
	check("obstacles: none left", nav.obstacle_count() == 0)


func _check_cost() -> void:
	var o := _floor()
	var t0 := Time.get_ticks_usec()
	var id := nav.build_field(_at(o.x + 30, o.y + 30), 96, ZOMBIE, 90000)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("[terrain-nav] field on the test floor: %d nodes in %.1f ms" % [nav.field_size(id), ms])
	nav.release_field(id)
	# The real ground at the spawn: generated sections, the first time.
	var top := BrickTerrain.surface_plate(0, 0)
	var spawn := nav.stand_near(Vector3(0.0, (top + 1) * plate, 0.0), ZOMBIE, 12)
	check("a zombie fits somewhere at the spawn", spawn != Vector3.INF)
	if spawn == Vector3.INF:
		return
	var s0 := int(nav.get_stats().sections_made)
	t0 = Time.get_ticks_usec()
	var id2 := nav.build_field(spawn, 96, ZOMBIE, 90000)
	var ms2 := (Time.get_ticks_usec() - t0) / 1000.0
	var made := int(nav.get_stats().sections_made) - s0
	t0 = Time.get_ticks_usec()
	var id3 := nav.build_field(spawn, 96, ZOMBIE, 90000)
	var ms3 := (Time.get_ticks_usec() - t0) / 1000.0
	print("[terrain-nav] field at the spawn: %d nodes, %.1f ms with %d sections made, %.1f ms with them kept"
			% [nav.field_size(id2), ms2, made, ms3])
	check("a field at the spawn has room to walk (%d nodes)" % nav.field_size(id2), nav.field_size(id2) > 500)
	check("a kept-sections field is affordable on a worker (%.0f ms < 400)" % ms3, ms3 < 400.0)
	nav.release_field(id2)
	nav.release_field(id3)
	var far := nav.stand_near(spawn + Vector3(30.0, 0.0, 0.0), ZOMBIE, 16)
	if far != Vector3.INF:
		t0 = Time.get_ticks_usec()
		var r := nav.find_path(far, spawn, ZOMBIE, 6000)
		print("[terrain-nav] a 30 m path at the spawn: reached %s, %d nodes, %.1f ms" % [r.reached, r.expanded, (Time.get_ticks_usec() - t0) / 1000.0])
