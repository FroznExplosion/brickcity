extends SceneTree

## Probe for a mech breaching its way (MechBrain path breaches; Docs/AI.md 3.6).
##
##     godot --headless --path . --script tools/mech_breach_probe.gd
##
## A wall 6.7 m high -- more than a mech climbs -- 120 m long, across the way.
## A. A mech sent to the far side: its path goes through the wall; it walks up
##    to it, punches a hole its size, walks through and gets there -- a short
##    walk, not round the end.
## B. One kept from breaching (can_breach off): its path goes round the
##    wall's end, and it never touches the wall.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var mech_nav: AINav
var br: MechBrain


func _init() -> void:
	print("mech breach probe")
	a = Arena.new(self, 81)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _gun(cls: StringName, seed: int) -> GunInstance:
	return GunInstance.from_result(GunGenerator.generate(a.lib, seed, WeaponClass.builtin(cls), 1))


func _mech(feet: Vector3, launcher: bool) -> MechBrain:
	var m := Mech.spawn(root, feet, PI, 0)
	var g := _gun(&"lmg", 5)
	g.visible = false
	m.arm.add_child(g)
	m.gun.equip(g)
	m.gun.rng = a.s.rng
	m.gun.on_structure_hit = a.structure_hit
	var b := MechBrain.attach(a.s, m, mech_nav, MechTree.companion(), 0)
	if launcher:
		b.arm_launcher(_gun(&"rocket_launcher", 9), a.s.rng, a.structure_hit)
	b.order = MechBrain.Order.ATTACK_AREA
	return b


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"breach":
			print("A. with a launcher")
			mech_nav = MechBrain.mech_nav(a.s.ai_world)
			# What changes where a figure walks changes where a mech walks (the
			# city's wiring).
			a.s.ai_nav.nav_changed.connect(mech_nav.invalidate_box)
			# The wall: z = 30 m, x -60..60 m, 16 courses (6.7 m), a stud thick.
			a.bricks(Vector3i(int(-60.0 / Arena.STUD), 0, int(30.0 / Arena.STUD)), Vector3i(int(120.0 / Arena.STUD), 16, 1))
			br = _mech(Vector3(0.0, 0.0, 10.0), true)
			br.order_point = Vector3(0.0, 0.0, 45.0)
			_log["from"] = br.mech.feet()
			_log["walked"] = 0.0
			_log["last"] = br.mech.feet()
			_log["blocks0"] = a.breached_blocks
		"round":
			print("B. kept from breaching")
			br.mech.body.queue_free()
			# A wall of its own, at z = 80 m: the first one has a hole in it now.
			a.bricks(Vector3i(int(-60.0 / Arena.STUD), 0, int(80.0 / Arena.STUD)), Vector3i(int(120.0 / Arena.STUD), 16, 1))
			mech_nav.clear_cache()
			br = _mech(Vector3(30.0, 0.0, 60.0), false)
			br.can_breach = false
			br.order_point = Vector3(30.0, 0.0, 95.0)
			_log["launched"] = 0


func _check(el: float) -> bool:
	match _stage:
		"breach":
			var f := br.mech.feet()
			_log.walked += Vector2(f.x - _log.last.x, f.z - _log.last.z).length()
			_log.last = f
			if f.z < 40.0 and el < 120.0:
				return false
			_ok("a mech sent through a wall gets there", f.z >= 40.0,
					"z %.1f after %.0f s, %s" % [f.z, el, br.state])
			_ok("it punched a hole its size on the way", br.breached >= 1 and br.mech.wall_punches > 0
					and a.breached_blocks > int(_log.blocks0), "%d hole(s), %d punches, %d rounds, %d bricks in %.0f s" % [
					br.breached, br.mech.wall_punches, br.launched, a.breached_blocks - int(_log.blocks0), el])
			_ok("through it -- a short walk, not round the wall's end", float(_log.walked) < 70.0,
					"walked %.0f m" % _log.walked)
			return true
		"round":
			if br._path.is_empty() and el < 30.0:
				return false
			var far := 0.0
			for p in br._path:
				far = maxf(far, absf(p.x))
			_ok("one kept from breaching goes round the wall's end, and never touches it",
					far > 58.0 and br.mech.wall_punches == 0 and br.breach_nav == null,
					"its path out to x %.0f, %d punches" % [far, br.mech.wall_punches])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("breach")
		return
	if _tick < 2:
		return
	a.tick()
	mech_nav.service(800)
	if not _check(a.s.now() - _t0):
		return
	var order := ["breach", "round"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
