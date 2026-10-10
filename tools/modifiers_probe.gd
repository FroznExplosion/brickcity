extends SceneTree

## A gun's modifiers in the hand (Docs/Weapons/COMBAT_DESIGN.md 6, 6.1): what each one
## does when GunController fires, and the first legendary red text.
##
##     godot --headless --path . --script res://tools/modifiers_probe.gd
##
##   power shot    every Nth round does 2x, the rest 1x
##   double fire   every Nth round fires a free extra round (no ammo); the rarer roll
##                 by chance, the same for the same seed
##   shield buster more damage on a shield, none extra on flesh
##   ricochet      a kill's excess jumps to the nearest enemy, times the roll; never
##                 to the shooter's own side
##   explosive     a round bursts: an enemy beside the one struck takes splash, one
##                 behind a wall does not, the shooter's side does not; a round into a
##                 wall bursts too; and the gun wears bricks harder (StructuralDamage)
##   red text      Sermon's kill puts the round back; Boilerplate winds up its fire
##                 rate while the trigger is held
##   the roll      the modifier stats reach the gun the generator builds

const RANGE := 5.0

var _pass := 0
var _fail := 0
var gun: GunController
var aim: Node3D
var _fired: Array = []
var _side: Array = []
var _lib: GunPartLibrary


func _init() -> void:
	print("modifiers probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


## A plain pistol: 10 a round, dead accurate, no modifiers but `extra`.
func _arm(extra: Dictionary = {}, effects := PackedStringArray()) -> void:
	var res := GunGenerator.generate(_lib, 11, WeaponClass.builtin(&"pistol"), 1, 1)
	var gi := GunInstance.from_result(res)
	for k: StringName in [&"power_shot_every", &"double_fire_every", &"double_fire_chance",
			&"shield_buster", &"overkill_ricochet", &"explosive"]:
		gi.stats.erase(k)
	gi.stats[&"damage"] = 10.0
	gi.stats[&"accuracy"] = 1.0
	gi.stats[&"crit_mult"] = 1.0
	gi.stats[&"element_ratio"] = 0.0
	gi.stats[&"mag_size"] = 30.0
	# A hair over 10 a second: each 0.1 s step fires exactly one round (for up to 20).
	gi.stats[&"fire_rate"] = 10.5
	gi.element_id = &""
	for k: StringName in extra:
		gi.stats[k] = float(extra[k])
	gi.active_effects = effects
	if gi.get_parent() == null:
		root.add_child(gi)
	gun.equip(gi)


func _target(at: Vector3, hp: float, team := 1, shield := 0.0) -> Pawn:
	var p := Pawn.spawn(root, at, team, true, hp)
	if shield > 0.0:
		var s := DefenseLayer.new()
		s.layer_type = &"shield"
		s.max_value = shield
		var h := DefenseLayer.new()
		h.max_value = hp
		p.health.layer_configs = [s, h]
		p.health._rebuild_state()
	return p


func _aim_at(p: Pawn) -> void:
	var to := p.chest()
	var from := to + Vector3(0.0, 0.0, RANGE)
	aim.global_transform = Transform3D(Basis.looking_at(to - from, Vector3.UP), from)


## Hold the trigger for `rounds` steps of 0.1 s: one round each.
func _burst(rounds: int) -> void:
	_fired.clear()
	_side.clear()
	gun._cooldown = 0.0   # rested: the last burst's round is long gone
	gun.set_trigger(true)
	# The first step tiny: from rest the gun may catch up a whole step's worth of
	# rounds at once, and a 0.1 s step is six frames.
	gun.step(0.001)
	for i in rounds - 1:
		gun.step(0.1)
	gun.set_trigger(false)


func _dealt(info: Dictionary) -> float:
	var r: DamageSystem.DamageResult = info.get("result")
	return r.dealt if r != null else 0.0


func _gone(p: Pawn) -> void:
	p.body.queue_free()


func _run() -> void:
	_lib = GunPlaceholderParts.build_library()
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)

	aim = Node3D.new()
	root.add_child(aim)
	gun = GunController.new()
	gun.rng = RandomNumberGenerator.new()
	gun.rng.seed = 7
	gun.aim = aim
	gun.team = 0
	root.add_child(gun)
	gun.fired.connect(func(info: Dictionary) -> void: _fired.append(info))
	gun.side_hit.connect(func(info: Dictionary) -> void: _side.append(info))

	# --- power shot ---------------------------------------------------------------
	var big := _target(Vector3.ZERO, 100000.0)
	await _ticks(4)
	_arm({&"power_shot_every": 3.0})
	_aim_at(big)
	_burst(6)
	var d: Array = _fired.map(func(i: Dictionary) -> float: return snappedf(_dealt(i), 0.01))
	_ok("power shot: every 3rd round 2x, the rest 1x", d == [10.0, 10.0, 20.0, 10.0, 10.0, 20.0],
			str(d))

	# --- double fire --------------------------------------------------------------
	_arm({&"double_fire_every": 2.0})
	_burst(4)
	_ok("double fire: every 2nd round fires twice", _fired.size() == 6, "%d rounds" % _fired.size())
	_ok("and the extra rounds cost no ammo", gun.ammo == 26, "%d left" % gun.ammo)
	_arm({&"double_fire_chance": 0.5})
	gun.rng.seed = 99
	_burst(20)
	var first := _fired.size()
	_arm({&"double_fire_chance": 0.5})
	gun.rng.seed = 99
	_burst(20)
	_ok("double fire by chance: some rounds twice, the same for the same seed",
			first > 20 and first < 40 and _fired.size() == first, "%d / %d" % [first, _fired.size()])

	# --- shield buster -------------------------------------------------------------
	_gone(big)
	var shielded := _target(Vector3.ZERO, 1000.0, 1, 1000.0)
	await _ticks(2)
	_arm({&"shield_buster": 0.3})
	_aim_at(shielded)
	_burst(1)
	_ok("Shield Buster: +30% on a shield", is_equal_approx(_dealt(_fired[0]), 13.0),
			"%.2f" % _dealt(_fired[0]))
	_gone(shielded)
	var flesh := _target(Vector3.ZERO, 1000.0)
	await _ticks(2)
	_aim_at(flesh)
	_burst(1)
	_ok("and nothing extra on flesh", is_equal_approx(_dealt(_fired[0]), 10.0),
			"%.2f" % _dealt(_fired[0]))
	_gone(flesh)

	# --- overkill ricochet -----------------------------------------------------------
	var weak := _target(Vector3.ZERO, 4.0)
	var friend := _target(Vector3(1.5, 0.0, 0.0), 1000.0, 0)
	var next := _target(Vector3(4.0, 0.0, 0.0), 1000.0)
	await _ticks(2)
	_arm({&"overkill_ricochet": 1.5})
	_aim_at(weak)
	_burst(1)
	var to_next := 1000.0 - next.health.total_current()
	_ok("ricochet: the kill's excess x1.5 jumps to the next enemy", is_equal_approx(to_next, 9.0)
			and _side.size() == 1 and _side[0].side == &"ricochet", "%.2f" % to_next)
	_ok("and never to the shooter's own side, even nearer",
			is_equal_approx(friend.health.total_current(), 1000.0))
	_gone(weak)
	_gone(friend)
	_gone(next)

	# --- explosive ------------------------------------------------------------------
	var struck := _target(Vector3.ZERO, 1000.0)
	var beside := _target(Vector3(1.5, 0.0, 0.0), 1000.0)
	var mate := _target(Vector3(-1.5, 0.0, 0.0), 1000.0, 0)
	var hidden := _target(Vector3(0.0, 0.0, -2.5), 1000.0)
	var wall := StaticBody3D.new()
	wall.collision_layer = Layers.WORLD
	var ws := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(4.0, 3.0, 0.3)
	ws.shape = wb
	wall.add_child(ws)
	root.add_child(wall)
	wall.global_position = Vector3(0.0, 1.5, -1.2)
	await _ticks(2)
	_arm({&"explosive": 0.5}, PackedStringArray(["explosive"]))
	_aim_at(struck)
	_burst(1)
	var splash := 1000.0 - beside.health.total_current()
	_ok("explosive: the enemy beside takes splash", splash > 2.5 and splash <= 5.0,
			"%.2f of 5" % splash)
	_ok("the one struck takes only its round", is_equal_approx(1000.0 - struck.health.total_current(), 10.0))
	_ok("not one behind a wall", is_equal_approx(hidden.health.total_current(), 1000.0))
	_ok("not the shooter's side", is_equal_approx(mate.health.total_current(), 1000.0))
	_gone(struck)
	await _ticks(2)
	# A round into the wall, beside an enemy, bursts too.
	var before := beside.health.total_current()
	var wall_pt := Vector3(1.0, 1.0, -1.05)
	var from := wall_pt + Vector3(0.0, 0.0, RANGE)
	aim.global_transform = Transform3D(Basis.looking_at(wall_pt - from, Vector3.UP), from)
	_burst(1)
	_ok("a round into a wall bursts beside an enemy", beside.health.total_current() < before
			and _fired[0].structure, "%.2f" % (before - beside.health.total_current()))
	var shot := StructuralDamage.for_shot(WeaponClass.builtin(&"pistol"), gun.gun.active_effects)
	_ok("and wears bricks harder", float(shot.radius) > 0.0)
	_gone(beside)
	_gone(mate)
	_gone(hidden)
	wall.queue_free()

	# --- red text -------------------------------------------------------------------
	var victim := _target(Vector3.ZERO, 5.0)
	await _ticks(2)
	_arm({}, PackedStringArray(["kill_refund"]))
	_aim_at(victim)
	_burst(1)
	_ok("Sermon: a kill puts the round back", gun.ammo == 30, "%d" % gun.ammo)
	_gone(victim)
	_arm({}, PackedStringArray(["heat_ramp"]))
	gun.set_trigger(true)
	for i in 25:
		gun.step(0.1)
	var wound := gun._wind_up()
	gun.set_trigger(false)
	gun.step(0.1)
	_ok("Boilerplate: held, the fire rate winds up to 1.6x", is_equal_approx(wound, 1.6),
			"x%.2f" % wound)
	_ok("and lets go when the trigger does", is_equal_approx(gun._wind_up(), 1.0))

	# --- the roll reaches the gun ---------------------------------------------------
	var found := {}
	for i in 400:
		var res := GunGenerator.generate(_lib, 5000 + i, WeaponClass.builtin(&"rifle"), 1, 4)
		for m in res.modifiers:
			found[m.id] = true
			if m.id == &"explosive" and not res.active_effects.has("explosive"):
				found[&"broken"] = true
			if m.id == &"power_shot" and res.stats.get(&"power_shot_every", 0.0) != m.value:
				found[&"broken"] = true
	_ok("every modifier rolls somewhere on purples", found.size() >= GunModifiers.DEFS.size()
			and not found.has(&"broken"), str(found.keys()))
	var ord := false
	for i in 200:
		var res := GunGenerator.generate(_lib, 9000 + i, WeaponClass.builtin(&"rocket_launcher"), 1, 4)
		for m in res.modifiers:
			if GunModifiers.DEFS[m.id].get("guns_only", false):
				ord = true
	_ok("ordnance never rolls a round-counting modifier", not ord)

	print("modifiers probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)
