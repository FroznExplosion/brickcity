extends SceneTree

## How a gun fires (GunFireMode, Docs/Weapons/COMBAT_DESIGN.md 7.9).
##
##     godot --headless --path . --script res://tools/fire_mode_probe.gd
##
##   the roll       off the seed, the same every time; nothing for a gun no one gave a
##                  kind (an enemy's fires as it always has); the magnum is semi; every
##                  shotgun of a kind fires pellets; only semi and burst guns charge,
##                  commons too
##   semi           light: held, it keeps firing, slower than it can be tapped; heavy: one
##                  round a pull however long it is held; a press a little early is kept
##   auto           rounds at the fire rate while held
##   burst          a press is its count of rounds, fast; held, a light gun's bursts run at
##                  the fire rate, a heavy's stop at one
##   pellets        one report a blast for each thing it hit, its damage summed; up close
##                  most pellets strike, and far off the falloff takes most of the damage
##   charge         nothing on the press; a tap fires one round on its release; held full
##                  and let go, the charged shot alone: an overcharge that takes a shield
##                  whole for three shots, a hyper burst that knocks back, an armor break;
##                  let go early, nothing

const RANGE := 5.0

var _pass := 0
var _fail := 0
var gun: GunController
var aim: Node3D
var _fired: Array = []
var _lib: GunPartLibrary


func _init() -> void:
	print("fire mode probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A plain gun, 10 a round, 10 a second, dead accurate, firing as `fm` says.
func _arm(fm: Dictionary, cls := &"rifle", kind := &"light") -> GunInstance:
	var res := GunGenerator.generate(_lib, 11, WeaponClass.builtin(cls).with_kind(kind), 1, 1)
	var gi := GunInstance.from_result(res)
	for k: StringName in [&"power_shot_every", &"double_fire_every", &"double_fire_chance",
			&"shield_buster", &"overkill_ricochet", &"explosive"]:
		gi.stats.erase(k)
	gi.stats[&"damage"] = 10.0
	gi.stats[&"accuracy"] = 1.0
	gi.stats[&"element_ratio"] = 0.0
	gi.stats[&"mag_size"] = 200.0
	gi.stats[&"fire_rate"] = 10.0
	gi.element_id = &""
	gi.active_effects = PackedStringArray()
	gi.alt_fire = &""
	gi.fire = fm
	if gi.get_parent() == null:
		root.add_child(gi)
	gun.equip(gi)
	return gi


func _target(at: Vector3, hp: float, top := &"", top_hp := 0.0) -> Pawn:
	var p := Pawn.spawn(root, at, 1, true, hp)
	if top != &"":
		var s := DefenseLayer.new()
		s.layer_type = top
		s.max_value = top_hp
		var h := DefenseLayer.new()
		h.max_value = hp
		p.health.layer_configs = [s, h]
		p.health.impact_carries_over = false
		p.health._rebuild_state()
	return p


func _look(to: Vector3, dist := RANGE) -> void:
	var from := to + Vector3(0.0, 0.0, dist)
	aim.global_transform = Transform3D(Basis.looking_at(to - from, Vector3.UP), from)


## Hold the trigger `held` seconds in 10 ms steps, then let go; rounds fired.
func _hold(held: float) -> int:
	var before := gun.ammo
	gun.set_trigger(true)
	var t := 0.0
	while t < held:
		gun.step(0.01)
		t += 0.01
	gun.set_trigger(false)
	gun.step(0.01)
	return before - gun.ammo


## Hold `held`, then rest `after`: every round the press made, the ones that come after
## the trigger is up (the rest of a burst, a kept press) included.
func _shots(held: float, after: float) -> int:
	var before := gun.ammo
	_hold(held)
	_rest(after)
	return before - gun.ammo


## Let the gun sit `secs` with the trigger up.
func _rest(secs: float) -> void:
	var t := 0.0
	while t < secs:
		gun.step(0.01)
		t += 0.01


func _run() -> void:
	_lib = GunPlaceholderParts.build_library()
	aim = Node3D.new()
	root.add_child(aim)
	gun = GunController.new()
	gun.rng = RandomNumberGenerator.new()
	gun.rng.seed = 7
	gun.aim = aim
	gun.team = 0
	root.add_child(gun)
	gun.fired.connect(func(info: Dictionary) -> void: _fired.append(info))
	# Physics owns the stepping only through step() here: keep _physics_process out.
	gun.set_physics_process(false)

	_roll()
	_semi()
	_auto_burst()
	await _pellets()
	await _charge()
	print("fire mode probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _roll() -> void:
	var same := true
	var plain_none := true
	var shotgun_pellets := true
	var charge_ok := true
	var white_charge := false
	var bursts_ok := true
	var any_charge := 0
	for i in 600:
		var s := 7000 + i
		var rar := 1 + i % 6
		var cls: StringName = [&"pistol", &"rifle", &"shotgun", &"smg", &"dmr"][i % 5]
		var wc := WeaponClass.rolled(cls, s, rar)
		var a := GunFireMode.roll(s, rar, wc)
		if a != GunFireMode.roll(s, rar, wc):
			same = false
		if not GunFireMode.roll(s, rar, WeaponClass.builtin(cls)).is_empty():
			plain_none = false
		if cls == &"shotgun" and not a.has("pellets"):
			shotgun_pellets = false
		if a.has("charge"):
			any_charge += 1
			if a.mode == GunFireMode.AUTO:
				charge_ok = false
			if rar == 1:
				white_charge = true
		if a.mode == GunFireMode.BURST and (int(a.burst) < 2 or int(a.burst) > 5):
			bursts_ok = false
	_ok("the fire mode is off the seed, the same every time", same)
	_ok("a gun no one gave a kind has none (it fires as it always has)", plain_none)
	_ok("every shotgun of a kind fires pellets", shotgun_pellets)
	_ok("only semi and burst guns charge, commons too, and some do", charge_ok
			and white_charge and any_charge > 30, "%d charge" % any_charge)
	_ok("bursts are 2 to 5", bursts_ok)
	var mag := WeaponClass.builtin(&"pistol").with_kind(&"heavy")
	_ok("the magnum is semi-auto", GunFireMode.roll(5, 1, mag).mode == GunFireMode.SEMI)


func _semi() -> void:
	_arm({"mode": GunFireMode.SEMI})
	var held := _hold(1.0)
	_ok("semi, light: held a second, it keeps firing, slower than tapping", held >= 5 and held <= 8,
			"%d in 1 s at 10/s" % held)
	_rest(0.3)
	_arm({"mode": GunFireMode.SEMI}, &"rifle", &"heavy")
	held = _hold(1.0)
	_ok("semi, heavy: one round a pull, held a whole second", held == 1, "%d" % held)
	_rest(0.3)
	var three := 0
	for i in 3:
		three += _hold(0.02)
		_rest(0.2)
	_ok("three presses, three rounds", three == 3, "%d" % three)
	_rest(0.3)
	# A second press 40 ms after the first, under the 100 ms between rounds: kept.
	var before := gun.ammo
	_hold(0.02)
	_rest(0.02)
	_hold(0.02)
	_rest(0.2)
	var two := before - gun.ammo
	_ok("a press a little early is kept, not lost", two == 2, "%d" % two)


func _auto_burst() -> void:
	var gi := _arm({"mode": GunFireMode.AUTO})
	var n := _hold(1.0)
	_ok("auto: rounds at the fire rate while held", n >= 9 and n <= 11, "%d in 1 s at 10/s" % n)
	gi = _arm({"mode": GunFireMode.BURST, "burst": 3, "burst_speed": 3.0})
	var one := _shots(0.02, 0.2)
	_ok("burst: a press is three rounds", one == 3, "%d" % one)
	_rest(0.5)
	var held := _hold(3.0)
	_ok("held, a light gun's bursts run at the fire rate", held >= 27 and held <= 33,
			"%d in 3 s at 10/s" % held)
	_arm({"mode": GunFireMode.BURST, "burst": 3, "burst_speed": 3.0}, &"rifle", &"heavy")
	_rest(0.5)
	held = _shots(3.0, 0.5)
	_ok("held, a heavy gun's burst is one", held == 3, "%d" % held)


func _pellets() -> void:
	var near_t := _target(Vector3(0.0, 0.0, 0.0), 100000.0)
	var far_t := _target(Vector3(6.0, 0.0, 0.0), 100000.0)
	await physics_frame
	await physics_frame
	_arm({"mode": GunFireMode.SEMI, "pellets": 8, "pellet_spread": 4.0, "near": 4.0, "far": 12.0,
			"falloff": 0.2}, &"shotgun")
	_look(near_t.chest(), 3.0)
	_fired.clear()
	_hold(0.02)
	_rest(0.3)
	var reports := _fired.filter(func(f: Dictionary) -> bool: return not f.is_empty() and f.result != null)
	var close := 0.0
	var hit_n := 0
	if reports.size() == 1:
		close = (reports[0].result as DamageSystem.DamageResult).dealt
		hit_n = int(reports[0].pellets_hit)
	_ok("a blast is one report for the man it hit, damage summed", reports.size() == 1
			and hit_n >= 6, "%d report(s), %d / 8 pellets" % [reports.size(), hit_n])
	_look(far_t.chest(), 16.0)
	_fired.clear()
	_hold(0.02)
	_rest(0.3)
	var far := 0.0
	for f in _fired:
		if not f.is_empty() and f.result != null:
			far += (f.result as DamageSystem.DamageResult).dealt
	_ok("far off, the falloff takes most of it", close > 0.0 and far < close * 0.45,
			"%.1f at 3 m, %.1f at 16 m" % [close, far])
	near_t.body.queue_free()
	far_t.body.queue_free()
	await physics_frame


func _charge() -> void:
	var t := _target(Vector3(20.0, 0.0, 0.0), 1000.0, &"shield", 50.0)
	await physics_frame
	await physics_frame
	_look(t.chest())
	_arm({"mode": GunFireMode.SEMI, "charge": GunFireMode.OVERCHARGE,
			"effect": GunFireMode.SHIELD_BREAK, "charge_time": 0.8})
	var before := gun.ammo
	gun.set_trigger(true)
	for i in 5:
		gun.step(0.01)
	var on_press := before - gun.ammo
	gun.set_trigger(false)
	_rest(0.3)
	var tap := before - gun.ammo
	_ok("a charging gun fires nothing on the press", on_press == 0, "%d" % on_press)
	_ok("a tap fires one round on its release", tap == 1 and t.health.total_current() < 1050.0
			and t.health.top_layer_type() == &"shield", "%d" % tap)
	var early := _hold(0.6)
	_rest(0.3)
	_ok("let go before the charge is full, nothing", early == 0, "%d" % early)
	_fired.clear()
	var full := _hold(1.3)
	_rest(0.3)
	_ok("held full: the overcharge alone takes the shield whole, for three shots",
			full == 3 and t.health.top_layer_type() != &"shield",
			"%d shots, top layer %s" % [full, t.health.top_layer_type()])
	t.body.queue_free()

	var armored := _target(Vector3(30.0, 0.0, 0.0), 1000.0, &"armor", 300.0)
	await physics_frame
	await physics_frame
	_look(armored.chest())
	_arm({"mode": GunFireMode.SEMI, "charge": GunFireMode.OVERCHARGE,
			"effect": GunFireMode.ARMOR_BREAK, "charge_time": 0.8})
	_hold(1.3)
	_rest(0.3)
	_ok("an armor break takes the armor whole", armored.health.top_layer_type() != &"armor")
	armored.body.queue_free()

	var man := _target(Vector3(40.0, 0.0, 0.0), 100000.0)
	await physics_frame
	await physics_frame
	_look(man.chest())
	_arm({"mode": GunFireMode.BURST, "burst": 3, "burst_speed": 3.0,
			"charge": GunFireMode.HYPER, "effect": GunFireMode.KNOCKBACK, "charge_time": 0.8})
	_fired.clear()
	var n := _shots(1.4, 1.0)
	var knocked := _fired.filter(func(f: Dictionary) -> bool: return f.get("impact_mult", 1.0) > 1.0)
	_ok("held full on a burst gun: a hyper burst of twice its count, alone, that knocks back",
			n == 6 and knocked.size() == 6, "%d rounds, %d knocking" % [n, knocked.size()])
	man.body.queue_free()
