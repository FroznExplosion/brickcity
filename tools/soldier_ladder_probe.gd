extends SceneTree

## Probe for soldiers on ladders (Docs/RoomModules.md 7.13): the nav has no way
## up a ladder, so a soldier whose goal is on another level, with no way there
## on foot, takes a ladder near -- walks to its foot, climbs it, goes over its
## top on to what it leads to, and walks on; and down it the other way.
##
##     godot --headless --path . --script res://tools/soldier_ladder_probe.gd
##
##   no way      a block taller than the nav steps or drops, no stair: no path
##               up it or down it on foot
##   up          a soldier sent on top of it climbs the ladder up its side and
##               gets there
##   down        sent back to the ground, it climbs down it, unhurt
##   none        the same with the ladder gone: it does not get up

const Arena := preload("res://tools/ai_arena.gd")
const STUD := 0.35
## The block: 16 x 16 studs, COURSES high (3.78 m: more than a storey's drop).
const SIDE := 16
const COURSES := 9

var _pass := 0
var _fail := 0
var a: Arena
var so: Soldier
var lad: Ladder
var _t := 0
var _stage := 0
var _seen_climb := false
var _hp0 := 0.0
var _top: Vector3
var _ground: Vector3


func _init() -> void:
	print("soldier ladder probe")
	a = Arena.new(self, 7)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _setup() -> void:
	a.bricks(Vector3i(0, 0, 0), Vector3i(SIDE, COURSES, SIDE))
	var h := COURSES * Arena.COURSE
	# A ladder up its +Z face, in the middle of it.
	lad = Ladder.new()
	lad.width = 2 * STUD
	lad.height = h
	root.add_child(lad)
	lad.global_transform = Transform3D(Basis(), Vector3(SIDE * 0.5 * STUD, 0.0, SIDE * STUD))
	_top = a.s.ai_nav.snap(Vector3(SIDE * 0.3 * STUD, h, SIDE * 0.3 * STUD))
	_ground = a.s.ai_nav.snap(Vector3(SIDE * 0.3 * STUD, 0.0, SIDE * STUD + 6.0))
	var up: PackedVector3Array = a.s.ai_nav.find_path(_ground, _top, 20000)
	var down: PackedVector3Array = a.s.ai_nav.find_path(_top, _ground, 20000)
	_ok("a block taller than the nav steps or drops, no stair: no way up or down on foot",
			_top.y > h - 0.2 and (up.is_empty() or up[up.size() - 1].distance_to(_top) > 1.0)
			and (down.is_empty() or down[down.size() - 1].distance_to(_ground) > 1.0),
			"top %s, up %d point(s), down %d" % [str(_top.snapped(Vector3.ONE * 0.01)), up.size(), down.size()])
	so = a.soldier(_ground, 1)
	so.brain.active = false
	so.fire_ok = false
	_hp0 = _hp()


func _hp() -> float:
	return so.pawn.health.total_current()


func _on_tick() -> void:
	_t += 1
	if _stage == 0 and _t == 3:
		_setup()
		_stage = 1
		_t = 0
		return
	if _stage == 0:
		return
	a.tick()
	match _stage:
		1:
			var r := so.move_to(_top)
			_seen_climb = _seen_climb or so.pawn.ladder != null
			if r == 1 or _t > 30 * 40:
				_ok("a soldier sent on top climbs the ladder up its side and gets there", r == 1 and _seen_climb
						and so.pawn.feet().distance_to(_top) < 1.0,
						"arrived %s, climbed %s, %.1f s, feet %s" % [r == 1, _seen_climb, _t / 30.0,
						str(so.pawn.feet().snapped(Vector3.ONE * 0.01))])
				_seen_climb = false
				_hp0 = _hp()
				_stage = 2
				_t = 0
		2:
			var r := so.move_to(_ground)
			_seen_climb = _seen_climb or so.pawn.ladder != null
			if r == 1 or _t > 30 * 40:
				_ok("sent back to the ground it climbs down it, unhurt", r == 1 and _seen_climb
						and so.pawn.feet().distance_to(_ground) < 1.0 and _hp() >= _hp0 and so.pawn.last_fall < 1.0,
						"arrived %s, climbed %s, %.1f s, last fall %.2f m, hp %.0f of %.0f" % [r == 1, _seen_climb,
						_t / 30.0, so.pawn.last_fall, _hp(), _hp0])
				lad.queue_free()
				so.stop()
				_stage = 3
				_t = 0
		3:
			var r := so.move_to(_top)
			if r == -1 or _t > 30 * 12:
				_ok("the same with the ladder gone: it does not get up", so.pawn.feet().y < 1.0,
						"result %d, feet %s" % [r, str(so.pawn.feet().snapped(Vector3.ONE * 0.01))])
				print("soldier ladder probe: %d ok, %d FAIL" % [_pass, _fail])
				quit(1 if _fail > 0 else 0)
