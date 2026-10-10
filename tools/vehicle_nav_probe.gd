extends SceneTree

## Probe for the vehicle map (VehicleNav; Docs/AIVehicles.md 3).
##
##     godot --headless --path . --script tools/vehicle_nav_probe.gd
##
## A. Width: a wall with a gap a body fits and a truck does not, and a gap a
##    truck fits and a tank does not. A person's path goes through the first,
##    a truck's through the second, a tank's round the end of the wall.
## B. Height: a passage under a roof a truck clears and a tank does not.
## C. Steps: a platform two plates up a truck drives onto; one a brick course
##    up only the tank climbs.
## D. A goal down an alley too narrow for a truck: the nearest place to it a
##    truck fits is outside the alley (beside its wall or at its mouth).
## E. Nothing baked: a wall with no gap is driven round; blown through, the
##    hole is a road at once.
## F. The vehicles drive it: a crewed tank sent across the first wall goes
##    round its end and gets there without sticking; a truck goes through the
##    wide gap and lets its cargo out on the far side.

const Arena := preload("res://tools/ai_arena.gd")
const STUD := 0.35
const PLATE := 0.14

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var truck_nav: AINav
var tank_nav: AINav
var t: Tank
var br: TankBrain
var truck: TransportTruck


func _init() -> void:
	print("vehicle nav probe")
	a = Arena.new(self, 43)
	_build()
	truck_nav = a.s.vehicle_nav(&"truck")
	tank_nav = a.s.vehicle_nav(&"tank")
	_static_checks()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A box of 1x1 plates from cell `lo`, `size` in studs, plates and studs.
func _plates(lo: Vector3i, size: Vector3i) -> void:
	var c := a.w.create_chunk(lo, size)
	for x in size.x:
		for y in size.y:
			for z in size.z:
				a.w.place_block(c, lo + Vector3i(x, y, z), a.palette["plate_1x1"], 4)
	a.w.set_chunk_anchored(c, true)
	var body := StaticBody3D.new()
	body.collision_layer = Layers.STRUCTURE
	a.w.add_chunk_shapes(body.get_rid(), c, Vector3.ZERO, false)
	body.transform = a.w.get_chunk_transform(c)
	a.root.add_child(body)
	a.s.ai_world.sync()


## A wall along X at cell row `z` from x0 to x1 (exclusive), `courses` high,
## leaving out the gaps [from, to).
func _wall(z: int, x0: int, x1: int, courses: int, gaps: Array) -> void:
	var x := x0
	for g in gaps + [[x1, x1]]:
		if g[0] > x:
			a.bricks(Vector3i(x, 0, z), Vector3i(g[0] - x, courses, 1))
		x = g[1]


func _build() -> void:
	# A: the wall with two gaps, z = 35 m: 7 studs (2.45 m) at x 0, 9 studs
	# (3.15 m) at x 30 (10.5 m).
	_wall(100, -60, 60, 5, [[0, 7], [30, 39]])
	# B: a wall at z = 105 m with a passage 12 studs wide at x 0 under a roof
	# 19 plates (2.66 m) up -- over a truck (2.4 m), under a tank's top (2.92 m).
	_wall(300, -60, 60, 7, [[0, 12]])
	a.bricks(Vector3i(0, 19, 296), Vector3i(12, 1, 9))
	# C: two platforms at z = 175..189 m: two plates high at x 60..100 cells, a
	# brick course high at x -100..-60.
	_plates(Vector3i(60, 0, 500), Vector3i(40, 2, 40))
	a.bricks(Vector3i(-100, 0, 500), Vector3i(40, 1, 40))
	# D: an alley 6 studs (2.1 m) wide between x cells 201..206, z 600..630.
	a.bricks(Vector3i(200, 0, 600), Vector3i(1, 5, 30))
	a.bricks(Vector3i(207, 0, 600), Vector3i(1, 5, 30))
	# E: a wall with no gap at z = 245 m.
	_wall(700, -60, 60, 4, [])


func _w(cx: float, cz: float, plates := 0) -> Vector3:
	return Vector3(cx * STUD, plates * PLATE, cz * STUD)


## Where `path` crosses the row z = `z` (metres): its X there, or NAN if it never does.
static func _cross_x(path: PackedVector3Array, z: float) -> float:
	for i in range(1, path.size()):
		var p0 := path[i - 1]
		var p1 := path[i]
		if (p0.z - z) * (p1.z - z) <= 0.0 and p0.z != p1.z:
			var k := (z - p0.z) / (p1.z - p0.z)
			return lerpf(p0.x, p1.x, k)
	return NAN


func _path(nav: AINav, from: Vector3, to: Vector3) -> PackedVector3Array:
	return nav.find_path(nav.snap(from), nav.snap(to), 60000)


func _static_checks() -> void:
	print("A. width")
	var from := _w(3, 80)
	var to := _w(3, 120)
	var wall_z := 100.5 * STUD
	var foot := _path(a.s.ai_nav, from, to)
	var tr := _path(truck_nav, from, to)
	var tk := _path(tank_nav, from, to)
	var fx := _cross_x(foot, wall_z)
	var rx := _cross_x(tr, wall_z)
	var kx := _cross_x(tk, wall_z)
	_ok("a person goes through the narrow gap (x 0..2.45 m)", fx >= 0.0 and fx <= 2.45, "crosses at x %.2f" % fx)
	_ok("a truck through the wide one (x 10.5..13.65 m)", rx >= 10.5 and rx <= 13.65,
			"crosses at x %.2f; span %d studs" % [rx, truck_nav.get_span()])
	_ok("a tank round the end of the wall (|x| > 21 m)", not tk.is_empty() and absf(kx) > 21.0,
			"crosses at x %.2f; span %d studs" % [kx, tank_nav.get_span()])

	print("B. height")
	from = _w(6, 285)
	to = _w(6, 315)
	wall_z = 300.5 * STUD
	rx = _cross_x(_path(truck_nav, from, to), wall_z)
	kx = _cross_x(_path(tank_nav, from, to), wall_z)
	_ok("a truck goes under the roof (x 0..4.2 m)", rx >= 0.0 and rx <= 4.2, "crosses at x %.2f" % rx)
	_ok("a tank, taller, goes round", absf(kx) > 21.0, "crosses at x %.2f" % kx)

	print("C. steps")
	var low_top := _w(80, 520, 2)
	var high_top := _w(-80, 520, 3)
	var ground := _w(80, 480)
	var ground2 := _w(-80, 480)
	_ok("a truck drives up two plates", not _path(truck_nav, ground, low_top).is_empty()
			and truck_nav.can_stand(truck_nav.snap(low_top)))
	var up := truck_nav.find_path(truck_nav.snap(ground2), Vector3(high_top.x, high_top.y, high_top.z), 20000)
	_ok("not up a brick course", up.is_empty() or up[up.size() - 1].y < 0.2,
			"ends at %v" % (up[up.size() - 1] if not up.is_empty() else Vector3.INF))
	up = tank_nav.find_path(tank_nav.snap(ground2), tank_nav.snap(high_top), 20000)
	_ok("a tank climbs it", not up.is_empty() and up[up.size() - 1].y > 0.3,
			"ends at %v" % (up[up.size() - 1] if not up.is_empty() else Vector3.INF))

	print("D. reach")
	var deep := _w(203.5, 618)
	var r := VehicleNav.reach_point(truck_nav, deep)
	var person := a.s.ai_nav.snap(deep)
	_ok("down an alley a body walks", a.s.ai_nav.can_stand(person) and person.distance_to(deep) < 1.0)
	var inside := r != Vector3.INF and r.x > 70.35 and r.x < 72.45 and r.z > 210.0 and r.z < 220.5
	_ok("a truck is brought to the nearest place it fits, out of the alley",
			r != Vector3.INF and truck_nav.can_stand(r) and not inside and r.distance_to(deep) < 16.0,
			"%v, %.1f m from the goal" % [r, r.distance_to(deep) if r != Vector3.INF else INF])

	print("E. a hole is a road")
	from = _w(0, 680)
	to = _w(0, 720)
	wall_z = 700.5 * STUD
	var before := _cross_x(_path(truck_nav, from, to), wall_z)
	a.breach(Vector3(0.0, 0.84, wall_z), 2.6)
	var after := _cross_x(_path(truck_nav, from, to), wall_z)
	_ok("a whole wall: round its end", absf(before) > 21.0, "crosses at x %.2f" % before)
	_ok("blown through: through the hole", absf(after) < 2.5, "crosses at x %.2f (%d bricks gone)" % [after, a.breached_blocks])


## A crewed tank of side 1 at `at`, with a brain.
func _tank(at: Vector3, yaw: float) -> Tank:
	var main := GunInstance.from_result(GunGenerator.generate(a.lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(a.lib, 6, WeaponClass.builtin(&"lmg"), 1))
	var tk := Tank.make(a.s, root, at, yaw, 1, main, mg, a.structure_hit, a.s.rng)
	a.s.add_pawn(tk.make_target())
	br = TankBrain.attach(a.s, tk)
	for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
		var so := a.soldier(at + Vector3(4.0, 0.0, 0.0), 1, 50 + seat)
		tk.board(so.pawn, seat, true)
	return tk


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"tank":
			print("F. the vehicles drive it")
			t = _tank(_w(3, 75), PI)
			br.send(_w(3, 125))
			_log["worst_backoffs"] = 0
		"truck":
			truck = TransportTruck.make(a.s, root, _w(3, 72), PI)
			truck.cargo = [&"rifleman", &"rifleman"] as Array[StringName]
			truck.send(_w(3, 171))


func _check(el: float) -> bool:
	match _stage:
		"tank":
			_log.worst_backoffs = maxi(int(_log.worst_backoffs), br._backoffs)
			var there := br.drive_to != Vector3.INF and Vector2(br.drive_to.x - t.feet().x,
					br.drive_to.z - t.feet().z).length() < 3.0
			if (there and br.state == "hold") or el > 45.0:
				_ok("a tank sent across the wall gets there on the vehicle map", there and br.road == "vehicle",
						"%.0f s, road %s, at %v, state %s" % [el, br.road, t.feet(), br.state])
				_ok("without sticking on the way", int(_log.worst_backoffs) == 0, "backed off %d times" % _log.worst_backoffs)
				return true
		"truck":
			if truck.state != "driving" or el > 40.0:
				_ok("a truck goes through the wide gap and lets them out past the wall",
						truck.state == "arrived" and truck.road == "vehicle" and truck.feet().z > 36.0
						and truck.stopped_because != "stuck",
						"%.0f s, %s (%s), road %s, at %v" % [el, truck.state, truck.stopped_because, truck.road, truck.feet()])
				return true
	return false


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("tank")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["tank", "truck"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
