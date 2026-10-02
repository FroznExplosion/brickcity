extends SceneTree

## Probe for the soldier's grenade, melee and rush (Grenade, BTMelee, BTRush;
## the Tactics Casebook's moves, Docs/Tactics).
##
##     godot --headless --path . --script tools/ai_moves_probe.gd
##
## One small fight at a time, 120 m apart (the arena ground is 600 m across):
##   A. A grenade lobbed over a wall at a player behind it: it lands where thrown,
##      lies there as a danger zone, goes off, hurts the player and blows the
##      bricks next to it; and a throw that would land on a friend is refused.
##   B. Melee: the soldier runs at the player, hits it in reach, holds its fire.
##   C. Rush: straight in at a run from 25 m, firing on the way.
##   D. The book deciding, the player within reach: it chooses melee and hits.
##   E. The book deciding, three soldiers against a player behind a wall they
##      cannot see over, but hear firing every second: grenades go.

const Arena := preload("res://tools/ai_arena.gd")


class Always extends CombatPolicy:
	var tactic := 0

	func decide(_o: PackedFloat32Array, _rng: RandomNumberGenerator) -> int:
		return tactic

	func policy_name() -> String:
		return "always " + CombatPolicy.TACTIC_NAMES[tactic]


var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _so: Soldier
var _p: Pawn
var _g: Grenade
var _squad: Squad
var _log := {}
var _old: Array = []


func _init() -> void:
	print("ai moves probe")
	a = Arena.new(self, 21)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x / Arena.STUD), roundi(p.y / Arena.PLATE), roundi(p.z / Arena.STUD))


func _hp(p: Pawn) -> float:
	return p.health.total_current()


## Soldiers from finished stages stop: they are not in the next fight.
func _retire_all() -> void:
	for x in _old:
		if x is Soldier and is_instance_valid(x):
			(x as Soldier).process_mode = Node.PROCESS_MODE_DISABLED
			(x as Soldier).pawn.body.process_mode = Node.PROCESS_MODE_DISABLED
			a.s.pawns.erase((x as Soldier).pawn)
		elif x is Pawn and is_instance_valid(x):
			a.s.pawns.erase(x)
			# Forgotten by the soldiers' side, and out of its attention.
			var id := (x as Pawn).get_instance_id()
			a.s.knowledge_of(1).contacts.erase(id)
			a.s.aggro_of(1).entries.erase(id)
			(x as Pawn).body.process_mode = Node.PROCESS_MODE_DISABLED
	_old.clear()


func _pair(x: float, player_off: Vector3, player_hp: float) -> void:
	_so = a.soldier(Vector3(x, 0.0, 0.0), 1, 40 + int(x))
	_p = a.player(Vector3(x, 0.0, 0.0) + player_off, player_hp, true, int(x))
	Arena.look(_so.pawn, _p.eye.global_position)
	Arena.look(_p, _so.pawn.eye.global_position)
	_old.append(_so)
	_old.append(_p)


func _begin(stage: String) -> void:
	_retire_all()
	_stage = stage
	_t0 = a.s.now()
	match stage:
		"grenade":
			a.bricks(_cell(Vector3(-2.1, 0.0, -11.0)), Vector3i(12, 6, 1))
			_pair(0.0, Vector3(0.0, 0.0, -12.0), 400.0)
			_log["hp0"] = _hp(_p)
			_log["blocks0"] = a.breached_blocks
			# A friend standing where a second throw would land.
			var friend := a.soldier(Vector3(50.0, 0.0, -12.0), 1, 77)
			var thrower := a.soldier(Vector3(50.0, 0.0, 0.0), 1, 78)
			_old.append(friend)
			_old.append(thrower)
			_log["refused"] = not thrower.throw_grenade(friend.pawn.feet())
			_log["thrown"] = _so.throw_grenade(_p.feet())
			_g = _so.thrown[0] if not _so.thrown.is_empty() else null
		"melee":
			var pol := Always.new()
			pol.tactic = CombatPolicy.Tactic.MELEE
			a.s.policy = pol
			_pair(-120.0, Vector3(0.0, 0.0, -10.0), 400.0)
			_log["hp0"] = _hp(_p)
		"rush":
			var pol := Always.new()
			pol.tactic = CombatPolicy.Tactic.RUSH
			a.s.policy = pol
			_pair(120.0, Vector3(0.0, 0.0, -25.0), 1e7)
		"book_reach":
			a.s.policy = BookCombatPolicy.new()
			_pair(-240.0, Vector3(0.0, 0.0, -1.4), 400.0)
			_log["hp0"] = _hp(_p)
		"book_grenades":
			a.s.policy = BookCombatPolicy.new()
			a.bricks(_cell(Vector3(237.9, 0.0, -14.0)), Vector3i(12, 6, 1))
			_p = a.player(Vector3(240.0, 0.0, -15.0), 1e7, true, 8)
			_old.append(_p)
			var members: Array[Soldier] = []
			for i in 3:
				var so := a.soldier(Vector3(237.0 + i * 3.0, 0.0, 0.0), 1, 90 + i)
				Arena.look(so.pawn, _p.eye.global_position)
				members.append(so)
				_old.append(so)
			_log["members"] = members


func _check(t: float) -> bool:
	match _stage:
		"grenade":
			if _g != null and is_instance_valid(_g) and _g.landed and not _log.has("danger"):
				_log["danger"] = a.s.ai_world.danger_distance(_g.to) < 0.5
				_log["landed_off"] = _g.global_position.distance_to(_g.to)
			if t < 4.0:
				return false
			_ok("a grenade lobbed over a wall lands where it was thrown, a danger zone while it lies there",
					bool(_log.thrown) and bool(_log.get("danger", false)) and float(_log.get("landed_off", 9.0)) < 0.5,
					"thrown %s, danger %s" % [_log.thrown, _log.get("danger")])
			var lost := float(_log.hp0) - _hp(_p)
			_ok("it goes off: the player behind the wall is hurt, the bricks next to it blown",
					lost > 20.0 and a.breached_blocks > int(_log.blocks0) and a.s.ai_world.danger_distance(_p.feet()) > 3.0,
					"player lost %.0f hp, %d brick(s) blown, danger cleared" % [lost, a.breached_blocks - int(_log.blocks0)])
			_ok("a throw that would land on a friend is refused", bool(_log.refused))
			return true
		"melee":
			if t < 8.0 and _so.melee_hits < 2:
				return false
			var lost := float(_log.hp0) - _hp(_p)
			_ok("melee: it runs in and hits, holding its fire", _so.melee_hits >= 1 and lost >= Soldier.MELEE_DAMAGE * 0.9
					and _so.shots == 0, "%d blow(s), player lost %.0f hp, %d shot(s) in %.1f s" % [_so.melee_hits, lost, _so.shots, t])
			return true
		"rush":
			var d := _so.pawn.feet().distance_to(_p.feet())
			if t < 8.0 and d > 5.0:
				return false
			_ok("rush: straight in at a run from 25 m, firing on the way", d <= 5.5 and _so.shots > 0 and t < 8.0,
					"%.1f m away after %.1f s, %d shot(s)" % [d, t, _so.shots])
			return true
		"book_reach":
			if t < 4.0 and _so.melee_hits < 1:
				return false
			_ok("the book deciding, the player within reach: melee, and it hits",
					str(_so.book.get("move", "")) == "melee" and _so.melee_hits >= 1,
					"moment %s, move %s, %d blow(s)" % [_so.book.get("moment"), _so.book.get("move"), _so.melee_hits])
			return true
		"book_grenades":
			# The player fires from behind the wall: heard, not seen.
			if _tick % 60 == 0:
				a.s.noise(_p.feet(), 60.0, _p)
			if t < 25.0:
				return false
			var n := 0
			for m in _log.members:
				n += m.thrown.size()
			var pol := a.s.policy as BookCombatPolicy
			_ok("the book deciding, three soldiers against a player firing from behind a wall: grenades go", n >= 1,
					"%d grenade(s); done %s; still not built %s" % [n, pol.done, pol.wanted_text()])
			return true
	return true


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("grenade")
		return
	if _tick < 2:
		return
	a.tick()
	if _p != null and is_instance_valid(_p) and _stage != "grenade":
		var at: Vector3 = (_log.members[1] as Soldier).pawn.feet() if _stage == "book_grenades" else _so.pawn.feet()
		Arena.look(_p, at + Vector3.UP * 1.4)
	if not _check(a.s.now() - _t0):
		return
	var order := ["grenade", "melee", "rush", "book_reach", "book_grenades"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
