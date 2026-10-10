extends SceneTree

## Probe for the tank (Docs/AIVehicles.md 2-4; AIRoster.md RO10).
##
##     godot --headless --path . --script tools/tank_probe.gd
##
## A. Its crew drive it: a driver and a gunner put in it, it goes where it is
##    sent along the walking map and stops there.
## B. Armour: a person's round scratches it, a rocket's hurts it (Tank.ARMOUR).
## C. Its gunner turns the turret on a player in sight and hits it with the
##    cannon and the machine gun; seeing it, it stops short (ENGAGE_RANGE).
## D. A player gone behind a wall is shot through it: the cannon opens bricks.
## E. Its squad screens it: with the casebook's screen_heavy, soldiers near
##    it read "Our heavy support is here" and go to its flank towards the
##    player; with heavy_leads, into its lee.
## F. It keeps its escort's pace: it waits when they fall behind.
## G. Wrecked, its crew climb out alive, hurt, and fight on; the wreck is no
##    longer a target.
## H. Seats: nobody gets into another side's crewed tank; an empty one is
##    anybody's, and changes side; without a driver it does not move, without
##    a gunner it does not shoot.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _stage := ""
var _t0 := 0.0
var _log := {}
var t: Tank
var br: TankBrain
var p: Pawn
var crew: Array[Soldier] = []
var squad: Squad


func _init() -> void:
	print("tank probe")
	a = Arena.new(self, 41)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _forget(x: Pawn) -> void:
	if x == null or not is_instance_valid(x):
		return
	a.s.pawns.erase(x)
	for team in [0, 1]:
		a.s.knowledge_of(team).contacts.erase(x.get_instance_id())
	x.body.process_mode = Node.PROCESS_MODE_DISABLED
	x.body.position += Vector3.DOWN * 500.0


## A tank of side `team` at `at`, crewed (driver and gunner, soldiers of its
## side) unless `empty`, with a brain.
func _tank(at: Vector3, yaw: float, team := 1, empty := false) -> Tank:
	var main := GunInstance.from_result(GunGenerator.generate(a.lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(a.lib, 6, WeaponClass.builtin(&"lmg"), 1))
	var tk := Tank.make(a.s, root, at, yaw, team, main, mg, a.structure_hit, a.s.rng)
	a.s.add_pawn(tk.make_target())
	br = TankBrain.attach(a.s, tk)
	crew.clear()
	if not empty:
		for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
			var so := a.soldier(at + Vector3(4.0, 0.0, 0.0), team, 50 + seat)
			tk.board(so.pawn, seat, true)
			crew.append(so)
	return tk


func _clear() -> void:
	if t != null and is_instance_valid(t):
		_forget(t.pawn)
		for s in t.crew:
			if t.crew[s] != null and is_instance_valid(t.crew[s]):
				(t.crew[s] as Pawn).body.queue_free()
		t.queue_free()
	t = null
	for so in crew:
		if is_instance_valid(so):
			_forget(so.pawn)
	crew.clear()
	_forget(p)
	p = null
	if squad != null:
		for so in squad.members:
			if is_instance_valid(so):
				_forget(so.pawn)
	squad = null


func _begin(stage: String) -> void:
	_stage = stage
	_t0 = a.s.now()
	_log.clear()
	match stage:
		"drive":
			t = _tank(Vector3(0.0, 0.0, 0.0), 0.0)
			# Sent 40 m off to the side: it has to turn first.
			br.send(Vector3(40.0, 0.0, -10.0))
			_log["pivoted"] = false
		"armour":
			var before := t.health.total_current()
			var rifle := DamagePacket.new(100.0, null, null)
			rifle.scale = &"person"
			DamageSystem.resolve(rifle, t)
			_log["rifle"] = before - t.health.total_current()
			var rocket := DamagePacket.new(100.0, null, null)
			rocket.scale = &"explosive"
			before = t.health.total_current()
			DamageSystem.resolve(rocket, t)
			_log["rocket"] = before - t.health.total_current()
			t.health.reset()
		"shoot":
			_clear()
			t = _tank(Vector3(0.0, 0.0, 100.0), 0.0)
			# In the open, 40 m ahead and to its right -- within both guns' reach
			# -- so the turret must turn.
			p = a.player(Vector3(20.0, 0.0, 65.0), 1e6, false, 0)
			br.send(p.feet())
			_log["hp0"] = p.health.total_current()
		"blind":
			_clear()
			t = _tank(Vector3(-100.0, 0.0, 0.0), 0.0)
			# A wall 20 m ahead, the player behind it, last seen there.
			a.bricks(Vector3i(int(-106.0 / Arena.STUD), 0, int(-21.0 / Arena.STUD)),
					Vector3i(int(12.0 / Arena.STUD), 3 * 7, 2))
			p = a.player(Vector3(-100.0, 0.0, -24.0), 1e6, false, 0)
			a.s.knowledge_of(1).heard(p, p.feet(), a.s.now())
			_log["breached0"] = a.breached_blocks
			_log["shells0"] = t.shells
		"screen":
			_clear()
			_screen_book("screen_heavy")
			t = _tank(Vector3(100.0, 0.0, 0.0), 0.0)
			p = a.player(Vector3(100.0, 0.0, -45.0), 1e6, false, 0)
			_squad(Vector3(100.0, 0.0, 9.0))
			_log["best"] = {}
		"lee":
			_clear()
			_screen_book("heavy_leads")
			t = _tank(Vector3(100.0, 0.0, 100.0), 0.0)
			p = a.player(Vector3(100.0, 0.0, 55.0), 1e6, false, 0)
			_squad(Vector3(108.0, 0.0, 100.0))
			_log["best"] = {}
		"pace":
			_clear()
			a.s.policy = CombatPolicy.from_args()
			t = _tank(Vector3(-100.0, 0.0, 100.0), 0.0)
			_squad(Vector3(-100.0, 0.0, 130.0))
			for so in squad.members:
				so.process_mode = Node.PROCESS_MODE_DISABLED
			br.escort = squad
			br.send(Vector3(-100.0, 0.0, 40.0))
			_log["waited"] = false
			_log["z0"] = t.feet().z
		"wreck":
			_clear()
			t = _tank(Vector3(-200.0, 0.0, -100.0), 0.0)
			_log["crew"] = t.crew_count()
			t.health.apply_impact(1e9, &"")
		"seats":
			_clear()
			t = _tank(Vector3(200.0, 0.0, 200.0), 0.0)
			var other := a.soldier(t.mount_point(), 0, 70)
			_log["other_in_crewed"] = t.board(other.pawn, Tank.Seat.DRIVER)
			_log["player_in_crewed"] = t.take_player(0)
			_forget(other.pawn)
			# Crew out: an empty tank, ours for the taking.
			var out := t.crew_get_out()
			for q in out:
				_forget(q)
			_log["empty"] = t.is_empty()
			_log["took"] = t.take_player(0)
			_log["side"] = t.team
			_log["target_side"] = t.pawn.team
			t.release_player()
			# A gunner only: it does not move; a driver only: it does not shoot.
			var g := a.soldier(t.mount_point(), 0, 71)
			_log["gunner_in"] = t.board(g.pawn, Tank.Seat.GUNNER)
			crew = [g]
			br.send(t.feet() + Vector3(0.0, 0.0, -30.0))
			p = a.player(t.feet() + Vector3(0.0, 0.0, -25.0), 1e6, false, 0)
			p.team = 1
			_log["z0"] = t.feet().z


## Every moment's weight on `move`: the policy is the book, told to.
func _screen_book(move: String) -> void:
	var sure := TacticsBook.load_book()
	for m in sure.moments:
		sure.moments[m].weights = {move: 100.0, "hold": 0.01}
	a.s.policy = BookCombatPolicy.new(sure)


func _squad(at: Vector3) -> void:
	var members: Array[Soldier] = []
	for i in 3:
		members.append(a.soldier(at + Vector3(2.0 * i - 2.0, 0.0, 0.0), 1, 60 + i))
	squad = Squad.make(a.s, root, members, 1)


func _check(dt: float) -> bool:
	match _stage:
		"drive":
			if br.state == "pivot":
				_log["pivoted"] = true
			var d := Vector2(t.feet().x - 40.0, t.feet().z + 10.0).length()
			if dt < 25.0 and not (br.state == "hold" and d < 4.0):
				return false
			_ok("a crewed tank drives where it is sent and stops there", br.state == "hold" and d < 4.0,
					"%.1f m from it after %.0f s, %s" % [d, dt, br.state])
			_ok("tracks: it turned on the spot into the first bend", bool(_log.pivoted))
		"armour":
			_ok("armour: a person's round scratches it, a rocket's hurts it",
					float(_log.rifle) < 5.0 and float(_log.rocket) >= 99.0,
					"100 of rifle -> %.1f, 100 of rocket -> %.1f" % [_log.rifle, _log.rocket])
		"shoot":
			var lost := float(_log.hp0) - p.health.total_current()
			if dt < 20.0 and not (t.shells >= 2 and t.coax.ammo < t.coax.mag_size()):
				return false
			var d := t.feet().distance_to(p.feet())
			_ok("its gunner turns on the player and hits it with the cannon and the machine gun",
					t.shells >= 2 and lost > 0.0 and t.coax.ammo < t.coax.mag_size(),
					"%d shell(s), the player lost %.0f, aim off %.1f deg" % [t.shells, lost, rad_to_deg(t.aim_error())])
			_ok("it stops short of the player: fire support, not a ram", d > TankBrain.HOLD_RANGE - 6.0 and br.state == "hold",
					"%.0f m off, %s" % [d, br.state])
		"blind":
			if dt < 15.0 and a.breached_blocks == int(_log.breached0):
				return false
			_ok("a player gone behind a wall is shot through it: the cannon opens the bricks",
					a.breached_blocks > int(_log.breached0) and br.blind_shots > 0,
					"%d shell(s), %d at a contact out of sight, %d brick(s) broken" % [t.shells - int(_log.shells0),
					br.blind_shots, a.breached_blocks - int(_log.breached0)])
		"screen", "lee":
			_track_screen()
			if dt < 14.0:
				return false
			var flank := _stage == "screen"
			var placed := 0
			for so in squad.members:
				var x: Dictionary = _log.best.get(so.get_instance_id(), {})
				if bool(x.get("ok", false)):
					placed += 1
			var said := squad.members.filter(func(so): return str(so.book.get("moment", "")) == "have_heavy").size()
			if flank:
				_ok("soldiers near our tank read \"Our heavy support is here\"", said > 0,
						"%d of %d" % [said, squad.members.size()])
				_ok("screen_heavy: they go to its flank, towards the player", placed >= 2,
						"%d of %d at a flank (%s)" % [placed, squad.members.size(), _screen_text()])
				var sides := {}
				for so in squad.members:
					sides[float((_log.best.get(so.get_instance_id(), {}) as Dictionary).get("side", 0.0))] = true
				_ok("and share it out: both flanks", sides.has(1.0) and sides.has(-1.0))
			else:
				_ok("heavy_leads: they go into its lee, away from the player", placed >= 2,
						"%d of %d in the lee (%s)" % [placed, squad.members.size(), _screen_text()])
		"pace":
			if br.state == "wait":
				_log["waited"] = true
			if dt < 6.0:
				return false
			var moved := absf(t.feet().z - float(_log.z0))
			_ok("it keeps its escort's pace: with the squad far behind it waits",
					bool(_log.waited) and moved < TankBrain.WAIT_FOR + 2.0, "moved %.1f m, %s" % [moved, br.state])
		"wreck":
			if dt < 0.5:
				return false
			var out := crew.filter(func(so): return a.s.pawns.has(so.pawn) and not so.pawn.health.is_dead() \
					and so.pawn.health.total_current() < 100.0 and so.pawn.body.visible)
			_ok("wrecked, its crew climb out alive and hurt, and are in the fight again",
					t.is_wrecked() and out.size() == int(_log.crew) and t.crew_count() == 0,
					"%d of %d out" % [out.size(), _log.crew])
			_ok("and the wreck is no target", not a.s.pawns.has(t.pawn))
		"seats":
			if dt < 6.0:
				return false
			_ok("nobody gets into another side's crewed tank",
					not bool(_log.other_in_crewed) and not bool(_log.player_in_crewed))
			_ok("an empty one is anybody's: the player takes it and it changes side",
					bool(_log.empty) and bool(_log.took) and int(_log.side) == 0 and int(_log.target_side) == 0)
			var moved := absf(t.feet().z - float(_log.z0))
			_ok("a gunner and no driver: it shoots and does not move",
					bool(_log.gunner_in) and moved < 0.5 and t.shells > 0,
					"moved %.1f m, %d shell(s)" % [moved, t.shells])
	return true


## How near each squad member has come to where it should be: beside the tank
## towards the player (screen), or behind it away from the player (lee).
func _track_screen() -> void:
	var at := t.feet()
	var u := Vector3(p.feet().x - at.x, 0.0, p.feet().z - at.z).normalized()
	for so in squad.members:
		var rel := so.pawn.feet() - at
		rel.y = 0.0
		var along := rel.dot(u)
		var signed := rel.dot(Vector3(-u.z, 0.0, u.x))
		var across := absf(signed)
		var ok := false
		if _stage == "screen":
			ok = across >= 2.5 and across <= 9.0 and along > -2.0 and rel.length() < 10.0
		else:
			ok = along < -3.0 and across < 4.0 and rel.length() < 10.0
		var key := so.get_instance_id()
		var was: Dictionary = _log.best.get(key, {})
		if ok or was.is_empty():
			_log.best[key] = {"ok": ok or bool(was.get("ok", false)), "state": so.state,
					"along": along, "across": across, "side": signf(signed)}


func _screen_text() -> String:
	var parts: Array[String] = []
	for so in squad.members:
		var x: Dictionary = _log.best.get(so.get_instance_id(), {})
		parts.append("%s %.0f/%.0f" % [x.get("state", "?"), x.get("along", 0.0), x.get("across", 0.0)])
	return ", ".join(parts)


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_begin("drive")
		return
	if _tick < 2:
		return
	a.tick()
	if not _check(a.s.now() - _t0):
		return
	var order := ["drive", "armour", "shoot", "blind", "screen", "lee", "pace", "wreck", "seats"]
	var i := order.find(_stage)
	if i + 1 < order.size():
		_begin(order[i + 1])
		return
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
