extends SceneTree

## Acceptance probe for mechs that fight on their own (Docs/AIPlan.md P7; AI.md
## 2.1, 6.4), in an arena. Two fights side by side, 200 m apart:
##
##   A. THE ENEMY'S MECH against infantry it knows are inside a roofed brick
##      building. It cannot follow them in, so it takes the wall away: launcher
##      rounds into the first brick on its line to them, until it sees them, and
##      then its gun. Every blast is a command; a client applying the log has the
##      same bricks.
##   B. THE PLAYER'S MECH on the one button (A4): a tap and it FOLLOWS the pilot's
##      walk in a 5-8 m band; a tap and it HOLDS while the pilot walks off; held
##      while aiming, it goes to the aimed point -- round a wall six metres high --
##      and drops the enemy it finds there.
##
##     godot --headless --path . --script tools/mech_ai_probe.gd

const Arena := preload("res://tools/ai_arena.gd")
const LIMIT := 30 * 75
const B_ORIGIN := Vector3(200.0, 0.0, 0.0)
const AREA := Vector3(230.0, 0.0, 30.0)

var _pass := 0
var _fail := 0
var a: Arena
var mech_nav: AINav
var _tick := 0
var _t0 := -1.0
var _log := {}

var enemy: MechBrain
var infantry: Array[Pawn] = []
var ally: MechBrain
var cmd: MechCommand
var pilot: Pawn
var dummy: Pawn
var _follow_worst := 0.0


func _init() -> void:
	print("mech ai probe")
	a = Arena.new(self, 31)
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


func _mech(feet: Vector3, yaw: float, team: int, tree: BehaviorTree) -> MechBrain:
	var m := Mech.spawn(root, feet, yaw, team)
	var g := _gun(&"lmg", 5 + team)
	g.visible = false
	m.arm.add_child(g)
	m.gun.equip(g)
	m.gun.rng = a.s.rng
	m.gun.on_structure_hit = a.structure_hit
	return MechBrain.attach(a.s, m, mech_nav, tree, team)


func _build() -> void:
	mech_nav = MechBrain.mech_nav(a.s.ai_world)
	# A: a building 14 x 14 studs, twelve courses of wall and a roof.
	a.bricks(Vector3i(0, 0, 40), Vector3i(14, 12, 1))
	a.bricks(Vector3i(0, 0, 53), Vector3i(14, 12, 1))
	a.bricks(Vector3i(0, 0, 41), Vector3i(1, 12, 12))
	a.bricks(Vector3i(13, 0, 41), Vector3i(1, 12, 12))
	a.bricks(Vector3i(0, 36, 40), Vector3i(14, 1, 14))
	for at in [Vector3(1.8, 0.0, 16.3), Vector3(3.1, 0.0, 17.2)]:
		infantry.append(a.player(at, 100.0, false))
	enemy = _mech(Vector3(2.4, 0.0, -24.0), PI, 1, MechTree.enemy())
	enemy.arm_launcher(_gun(&"rocket_launcher", 9), a.s.rng, a.structure_hit)
	# B: the pilot, its mech behind it, and a wall six metres high between the
	# walk and the enemy waiting in the area.
	var sx := int(round(225.0 / Arena.STUD))
	a.bricks(Vector3i(sx, 0, int(20.0 / Arena.STUD)), Vector3i(1, 16, int(20.0 / Arena.STUD)))
	pilot = a.player(B_ORIGIN, 1e7, false)
	ally = _mech(B_ORIGIN + Vector3(0.0, 0.0, -10.0), PI, 0, MechTree.companion())
	cmd = MechCommand.new(ally, pilot)
	dummy = Pawn.spawn(root, AREA + Vector3(1.5, 0.0, 1.5), 1, true, 100.0)
	Soldier._greybox(dummy, 1)
	a.s.add_pawn(dummy)


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
		return
	a.tick()
	mech_nav.service(800)
	var now := a.s.now()
	if _t0 < 0.0:
		_t0 = now
	var t := now - _t0
	_fight_a(t)
	_fight_b(t)
	if _tick >= LIMIT or (_log.has("a_done") and _log.has("b_done")):
		_finish()


## A: intel on the infantry every few seconds, until the mech sees for itself.
func _fight_a(t: float) -> void:
	if _log.has("a_done"):
		return
	if fmod(t, 5.0) < 0.04:
		for p in infantry:
			if not p.health.is_dead():
				a.s.knowledge_of(1).heard(p, p.feet(), a.s.now())
	if enemy.state == "breach" and not _log.has("a_breach_at"):
		_log["a_breach_at"] = t
	var dead := 0
	for p in infantry:
		if p.health.is_dead():
			dead += 1
	if dead == infantry.size():
		_log["a_done"] = t


## B: the pilot's script and the button.
func _fight_b(t: float) -> void:
	if _log.has("b_done"):
		return
	var it := pilot.intents
	it.move = Vector3.ZERO
	if t >= 0.5 and not _log.has("tap1"):
		cmd.press(a.s.now() - 0.1)
		_log["tap1"] = cmd.release(a.s.now(), Vector3.INF)
	if t >= 1.0 and t < 9.0:
		it.move = Vector3.BACK   # +Z: 22 m at a walk
	if t >= 4.0 and t < 12.0:
		_follow_worst = maxf(_follow_worst, _flat(ally.mech.feet(), pilot.feet()))
	if t >= 12.0 and not _log.has("tap2"):
		_log["follow_end"] = _flat(ally.mech.feet(), pilot.feet())
		cmd.press(a.s.now() - 0.1)
		_log["tap2"] = cmd.release(a.s.now(), Vector3.INF)
		_log["hold_at"] = ally.order_point
	if t >= 12.5 and t < 20.0:
		it.move = Vector3.LEFT   # -X, away from it
	if t >= 20.0 and not _log.has("held"):
		_log["held"] = _flat(ally.mech.feet(), _log.hold_at)
		_log["held_gap"] = _flat(ally.mech.feet(), pilot.feet())
		cmd.press(a.s.now())
	if t >= 20.6 and not _log.has("attack"):
		_log["attack"] = cmd.release(a.s.now(), AREA)
		_log["attack_t"] = t
	if _log.has("attack"):
		if not _log.has("arrived") and _flat(ally.mech.feet(), AREA) < 4.0:
			_log["arrived"] = t - float(_log.attack_t)
		if dummy.health.is_dead() and not _log.has("b_down"):
			_log["b_down"] = t - float(_log.attack_t)
		# Down on the way is fine; it still goes where it was sent.
		if _log.has("b_down") and _log.has("arrived"):
			_log["b_done"] = true


static func _flat(p: Vector3, q: Vector3) -> float:
	return Vector2(p.x - q.x, p.z - q.z).length()


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var dead := 0
	for p in infantry:
		if p.health.is_dead():
			dead += 1
	_ok("A: the enemy's mech breaches the building and drops the infantry inside",
			dead == infantry.size() and enemy.launched >= 1 and a.breached_blocks > 0,
			"%d of %d down at %.1f s; breaching from %.1f s; %d launcher round(s), %d brick(s) blown; state %s" % [
			dead, infantry.size(), float(_log.get("a_done", -1.0)), float(_log.get("a_breach_at", -1.0)),
			enemy.launched, a.breached_blocks, enemy.state])
	_ok("A: its gun never fired through a wall", enemy.blocked_shots == 0 and enemy.shots > 0,
			"%d of %d" % [enemy.blocked_shots, enemy.shots])
	var agree := a.twin_agrees()
	_ok("A: a client applying the log has the same bricks", agree.x == agree.y and a.log.entries.size() > 0,
			"%d of %d blocks agree, %d command(s)" % [agree.x, agree.y, a.log.entries.size()])
	_ok("B: a tap and it follows the pilot's walk in its band",
			int(_log.get("tap1", -1)) == MechBrain.Order.FOLLOW and float(_log.get("follow_end", -1.0)) >= 4.0
			and float(_log.get("follow_end", 99.0)) <= 9.5 and _follow_worst < 14.0,
			"%.1f m at the end, at most %.1f m while walking" % [float(_log.get("follow_end", -1.0)), _follow_worst])
	_ok("B: a tap and it holds while the pilot walks off",
			int(_log.get("tap2", -1)) == MechBrain.Order.HOLD and float(_log.get("held", 99.0)) < 2.5
			and float(_log.get("held_gap", 0.0)) > 15.0,
			"%.1f m from its spot, the pilot %.1f m off" % [float(_log.get("held", -1.0)),
			float(_log.get("held_gap", -1.0))])
	_ok("B: held while aiming, it goes to the aimed area round the wall and drops the enemy there",
			int(_log.get("attack", -1)) == MechBrain.Order.ATTACK_AREA and _log.has("arrived")
			and dummy.health.is_dead(),
			"there in %.1f s, enemy down %.1f s after the order; state %s" % [float(_log.get("arrived", -1.0)),
			float(_log.get("b_down", -1.0)), ally.state])
	print("  AI mean %.3f ms a tick, worst %.2f ms" % [a.mean_ai_ms(), a.worst_ai_us / 1000.0])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
