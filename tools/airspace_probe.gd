extends SceneTree

## Probe for the airspace (Airspace; Docs/AI.md 5.2a): flyers and the ground
## sharing space.
##
##     godot --headless --path . --script tools/airspace_probe.gd
##
## A. Lanes: three flyers circling one target keep apart, at different heights.
## B. Over a tall body: a flyer low over a tank is pushed up off it.
## C. Pads: a flyer told to land claims a pad; a soldier standing on it clears
##    it; the flyer waits over it while anybody is on it, then comes down. A
##    second flyer cannot claim a pad over the first's.
## D. A truck driving through where a flyer is coming down holds short of the
##    pad, and drives on once the flyer has lifted off.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var flyers: Array[Flyer] = []
var p: Pawn


func _init() -> void:
	print("airspace probe")
	a = Arena.new(self, 71)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _flyer(at: Vector3, seed: int) -> Flyer:
	var f := Flyer.spawn(a.s, root, at, 1, a.rifle(seed))
	flyers.append(f)
	return f


func _clear() -> void:
	for f in flyers:
		if is_instance_valid(f):
			f.lift_off()
			f.body.queue_free()
	flyers.clear()


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"lanes":
			print("A. lanes")
			p = a.player(Vector3(0.0, 0.0, 0.0), 1e7, false, 0)
			for i in 3:
				_flyer(Vector3(30.0 + i * 0.5, 12.0, 0.2 * i), 10 + i)
			a.s.knowledge_of(1).saw(p, p.feet(), a.s.now())
			_log["closest"] = INF
		"tall":
			print("B. over a tall body")
			_clear()
			var main := GunInstance.from_result(GunGenerator.generate(a.lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
			var mg := GunInstance.from_result(GunGenerator.generate(a.lib, 6, WeaponClass.builtin(&"lmg"), 1))
			var t := Tank.make(a.s, root, Vector3(100.0, 0.0, 100.0), 0.0, 0, main, mg, a.structure_hit, a.s.rng)
			a.s.add_pawn(t.make_target())
			var f := _flyer(Vector3(100.0, 3.5, 100.0), 20)
			var push := a.s.air().separation(f, Vector3(100.0, 3.5, 100.0))
			_ok("a flyer low over a tank is pushed up off it", push.y > 0.5, "push %v" % push)
		"pad":
			print("C. pads")
			_clear()
			var so := a.soldier(Vector3(-100.0, 0.0, 50.0), 1, 30)
			# It stands its ground until the flyer is over the pad (as a soldier
			# busy fighting would): then it may move.
			so.process_mode = Node.PROCESS_MODE_DISABLED
			_log["so"] = so
			var f := _flyer(Vector3(-100.0, 15.0, 80.0), 31)
			_log["claimed"] = f.land(Vector3(-100.0, 0.0, 50.0))
			var g := _flyer(Vector3(-90.0, 15.0, 80.0), 32)
			_log["second"] = g.land(Vector3(-102.0, 0.0, 51.0))
			_log["waited"] = false
		"truck":
			print("D. a truck and a landing")
			_clear()
			var f := _flyer(Vector3(200.0, 20.0, -60.0), 40)
			f.land(Vector3(200.0, 0.0, -60.0))
			var tr := TransportTruck.make(a.s, root, Vector3(200.0, 0.0, 0.0), 0.0)
			tr.send(Vector3(200.0, 0.0, -150.0))
			_log["tr"] = tr
			_log["f"] = f


func _check(el: float) -> bool:
	match _stage:
		"lanes":
			# Its side keeps seeing the target, so they keep circling it.
			a.s.knowledge_of(1).saw(p, p.feet(), a.s.now())
			var ys := []
			for i in flyers.size():
				var fi := flyers[i]
				ys.append(fi.body.global_position.y)
				for j in range(i + 1, flyers.size()):
					var d := fi.body.global_position.distance_to(flyers[j].body.global_position)
					if el > 3.0:
						_log.closest = minf(float(_log.closest), d)
			if el < 12.0:
				return false
			ys.sort()
			_ok("three flyers circling one target never meet", float(_log.closest) > 2.5,
					"closest %.1f m after the first 3 s" % _log.closest)
			_ok("in different lanes", float(ys[2]) - float(ys[0]) > Airspace.LANE,
					"heights %.1f .. %.1f" % [ys[0], ys[2]])
			return true
		"tall":
			return true
		"pad":
			var f: Flyer = flyers[0]
			var so: Soldier = _log.so
			if f.state == "waiting for the pad" and not bool(_log.waited):
				_log.waited = true
				_log["waited_at"] = el
				so.process_mode = Node.PROCESS_MODE_INHERIT
			if not f.landed and el < 30.0:
				return false
			if bool(_log.waited) and f.landed:
				_log["down_after"] = el - float(_log.waited_at)
			var off := Vector2(so.pawn.feet().x + 100.0, so.pawn.feet().z - 50.0).length()
			_ok("a flyer told to land claims a pad; a second cannot claim one over it",
					bool(_log.claimed) and not bool(_log.second))
			_ok("the soldier on it clears it", off > Flyer.PAD_RADIUS, "%.1f m off its middle" % off)
			_ok("the flyer waits while anybody is on it, then comes down", bool(_log.waited) and f.landed,
					"%s, %.1f s after it began to wait" % [f.state, float(_log.get("down_after", -1.0))])
			return true
		"truck":
			var tr: TransportTruck = _log.tr
			var f: Flyer = _log.f
			if el < 9.0:
				return false
			if not _log.has("held_at"):
				_log["held_at"] = tr.feet()
				_log["held_why"] = tr.stopped_because
				var pad_d := Vector2(tr.feet().x - 200.0, tr.feet().z + 60.0).length()
				_ok("a truck driving through where a flyer comes down holds short of the pad",
						tr.state == "driving" and tr.stopped_because == "a landing ahead"
						and pad_d > Flyer.PAD_RADIUS + 2.0, "%.1f m from the pad, %s" % [pad_d, tr.stopped_because])
				f.lift_off()
				f.body.global_position.y += 20.0
				return false
			if el < 15.0:
				return false
			_ok("and drives on once it has lifted off", tr.feet().z < (_log.held_at as Vector3).z - 10.0,
					"%.0f m on" % ((_log.held_at as Vector3).z - tr.feet().z))
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("lanes")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["lanes", "tall", "pad", "truck"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
