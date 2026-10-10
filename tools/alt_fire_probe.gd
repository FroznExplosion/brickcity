extends SceneTree

## The alt-fire (Docs/Weapons/COMBAT_DESIGN.md 7.2) in the hand: the roll, the mode, and
## what each alt-fire does when GunController fires it.
##
##     godot --headless --path . --script res://tools/alt_fire_probe.gd
##
##   the roll       from the seed, the same every time; never on ordnance; only on the
##                  classes it belongs to; commoner up the colours; it reaches the gun
##   the mode       a gun with none ignores the switch; a trigger held through the switch
##                  fires nothing; after an alt-fire the gun is back on its primary, and
##                  the primary waits for the trigger to come up
##   dart           a short charge fires nothing; a full one sends a slow dart that does a
##                  heavy shot's damage and marks what it struck; rounds fired near the
##                  mark bend onto it, rounds fired well off do not; a dart in the head
##                  makes them crits, but a shield over the head still takes them plain;
##                  the mark ends after its time, and a new dart ends the old one
##   charge         takes a whole shield and nothing under it, for a bite of the magazine;
##                  refused without the ammo; on bare flesh it is one plain round
##   arc            the struck enemy and the next three near it, each less, each slowed;
##                  never the shooter's side; nothing past its jumps; a cooldown

const RANGE := 5.0

var _pass := 0
var _fail := 0
var gun: GunController
var aim: Node3D
var _fired: Array = []
var _side: Array = []
var _refused: Array = []
var _lib: GunPartLibrary


func _init() -> void:
	print("alt-fire probe")
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


## A plain pistol, 10 a round, dead accurate, with this alt-fire.
func _arm(alt: StringName) -> GunInstance:
	var res := GunGenerator.generate(_lib, 11, WeaponClass.builtin(&"pistol"), 1, 1)
	var gi := GunInstance.from_result(res)
	for k: StringName in [&"power_shot_every", &"double_fire_every", &"double_fire_chance",
			&"shield_buster", &"overkill_ricochet", &"explosive"]:
		gi.stats.erase(k)
	gi.stats[&"damage"] = 10.0
	gi.stats[&"accuracy"] = 1.0
	gi.stats[&"crit_mult"] = 2.0
	gi.stats[&"element_ratio"] = 0.0
	gi.stats[&"mag_size"] = 20.0
	gi.stats[&"fire_rate"] = 10.5
	gi.element_id = &""
	gi.active_effects = PackedStringArray()
	gi.alt_fire = alt
	gi.alt_mode = false
	if gi.get_parent() == null:
		root.add_child(gi)
	gun.equip(gi)
	gun._alt_cool = 0.0
	return gi


func _target(at: Vector3, hp: float, team := 1, shield := 0.0, crits := false) -> Pawn:
	Pawn.head_crits = crits
	var p := Pawn.spawn(root, at, team, true, hp)
	Pawn.head_crits = false
	if shield > 0.0:
		var s := DefenseLayer.new()
		s.layer_type = &"shield"
		s.max_value = shield
		var h := DefenseLayer.new()
		h.max_value = hp
		p.health.layer_configs = [s, h]
		p.health.impact_carries_over = false
		p.health._rebuild_state()
	return p


## Stand RANGE back from `to` along +Z and look at it, turned `off_deg` to the side.
func _look(to: Vector3, off_deg := 0.0) -> void:
	var from := to + Vector3(0.0, 0.0, RANGE)
	var b := Basis.looking_at(to - from, Vector3.UP)
	b = Basis(Vector3.UP, deg_to_rad(off_deg)) * b
	aim.global_transform = Transform3D(b, from)


## One round, the trigger then let go.
func _shoot() -> void:
	_fired.clear()
	gun._cooldown = 0.0
	gun.set_trigger(true)
	gun.step(0.001)
	gun.set_trigger(false)
	gun.step(0.001)


## Hold the trigger `held` seconds in alt-fire mode, then let go.
func _charge_release(held: float) -> void:
	gun.set_trigger(true)
	gun.step(0.001)
	gun.step(held)
	gun.set_trigger(false)
	gun.step(0.001)


func _hp(p: Pawn) -> float:
	return p.health.total_current()


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
	box.size = Vector3(80.0, 1.0, 80.0)
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
	gun.alt_refused.connect(func(why: String) -> void: _refused.append(why))

	# --- the roll ---------------------------------------------------------------------
	var same := true
	var on_ord := false
	var wrong_class := false
	var counts := [0, 0, 0, 0, 0, 0]
	for i in 600:
		var s := 40000 + i
		var rar := 1 + i % 6
		var wc := WeaponClass.builtin([&"pistol", &"rifle", &"shotgun", &"sniper", &"smg"][i % 5])
		var a := GunAltFire.roll(s, rar, wc)
		if a != GunAltFire.roll(s, rar, wc):
			same = false
		if a != &"":
			counts[rar - 1] += 1
			if not (GunAltFire.DEFS[a].classes as Array).has(wc.id):
				wrong_class = true
		if GunAltFire.roll(s, rar, WeaponClass.builtin(&"rocket_launcher")) != &"":
			on_ord = true
	_ok("the roll: the same seed rolls the same alt-fire", same)
	_ok("never on ordnance", not on_ord)
	_ok("only on the classes it belongs to (no sniper)", not wrong_class)
	_ok("commoner up the colours: few whites, every mythic that can", counts[0] < counts[3]
			and counts[3] < counts[5], str(counts))
	var reached := true
	var seen := 0
	for i in 200:
		var res := GunGenerator.generate(_lib, 70000 + i, WeaponClass.builtin(&"pistol"), 1, 5)
		var gi := GunInstance.from_result(res)
		var back := GunGenerator.deserialize(_lib, res.serialize())
		if res.alt_fire != GunAltFire.roll(res.seed, 5, res.weapon_class) or gi.alt_fire != res.alt_fire \
				or back.alt_fire != res.alt_fire:
			reached = false
		if res.alt_fire != &"":
			seen += 1
		gi.free()
	_ok("it reaches the gun, and a saved gun rebuilds it", reached and seen > 50, "%d of 200" % seen)

	# --- the mode ----------------------------------------------------------------------
	var big := _target(Vector3.ZERO, 100000.0)
	await _ticks(4)
	_arm(&"")
	_ok("a gun with no alt-fire ignores the switch", not gun.toggle_alt() and not gun.alt_on())
	_arm(GunAltFire.DART)
	_look(big.chest())
	gun.set_trigger(true)
	gun.toggle_alt()
	gun.step(0.001)
	gun.step(1.0)
	gun.set_trigger(false)
	gun.step(0.001)
	_ok("a trigger held through the switch fires nothing", gun.mark_dart() == null
			and gun.ammo == 20 and gun.alt_on())

	# --- the dart ---------------------------------------------------------------------
	_charge_release(0.2)
	_ok("dart: a short charge fires nothing", gun.mark_dart() == null and gun.ammo == 20)
	_side.clear()
	_charge_release(0.6)
	_ok("a full charge fires a dart, for one round, and the gun is back on its primary",
			gun.mark_dart() != null and gun.ammo == 19 and not gun.alt_on())
	var dart := gun.mark_dart()
	await _ticks(2)
	_ok("the dart is slow: a moment after, it is still on its way",
			dart != null and not dart.stuck and _side.is_empty())
	await _ticks(20)
	var dart_hit: float = _dealt(_side[0]) if _side.size() == 1 else -1.0
	_ok("it strikes for a heavy shot (2x)", is_equal_approx(dart_hit, 20.0)
			and _side[0].side == &"dart", "%.2f" % dart_hit)
	_ok("and marks what it struck", gun.has_mark() and gun.mark_target() == big.body)

	_gone(big)
	var crit := _target(Vector3.ZERO, 100000.0, 1, 0.0, true)
	var other := _target(Vector3(3.0, 0.0, -4.0), 100000.0)
	await _ticks(3)
	_arm(GunAltFire.DART)
	gun.toggle_alt()
	# The dart into the head.
	_look(crit.eye.global_position)
	_charge_release(0.6)
	await _ticks(20)
	_ok("a dart in the head marks a crit spot", gun.has_mark() and gun._mark.spot == &"head",
			str(gun._mark.get("spot", "?")))
	_look(crit.chest(), 8.0)
	_shoot()
	var bent: float = _dealt(_fired[0]) if _fired.size() == 1 else -1.0
	_ok("a round fired 8 degrees off bends onto the mark, and crits", is_equal_approx(bent, 20.0),
			"%.2f" % bent)
	_look(crit.chest(), 30.0)
	var before := _hp(crit)
	_shoot()
	_ok("a round fired 30 degrees off flies straight past", is_equal_approx(_hp(crit), before))
	var ob := _hp(other)
	_look(other.chest())
	_shoot()
	_ok("a round at another enemy, far off the mark, hits that enemy", _hp(other) < ob)
	await _ticks(int((GunController.MARK_SECONDS + 0.2) * Engine.physics_ticks_per_second))
	_ok("the mark ends after its time", not gun.has_mark())
	_gone(other)

	# A new dart ends the old mark at once, hit or miss.
	_arm(GunAltFire.DART)
	gun.toggle_alt()
	_look(crit.eye.global_position)
	_charge_release(0.6)
	await _ticks(20)
	var held := gun.has_mark()
	gun._alt_cool = 0.0
	gun.toggle_alt()
	_look(crit.chest() + Vector3(0.0, 30.0, 0.0))
	_charge_release(0.6)
	_ok("a new dart ends the old mark at once", held and not gun.has_mark())
	await _ticks(10)
	_gone(crit)

	# A shield over the head still takes the round as a plain one.
	var helm := _target(Vector3.ZERO, 1000.0, 1, 1000.0, true)
	await _ticks(3)
	_arm(GunAltFire.DART)
	gun.toggle_alt()
	_look(helm.eye.global_position)
	_charge_release(0.6)
	await _ticks(20)
	_look(helm.chest(), 5.0)
	_shoot()
	var plain: float = _dealt(_fired[0]) if _fired.size() == 1 else -1.0
	_ok("a shield over the marked head takes the bent round plain", gun.has_mark()
			and is_equal_approx(plain, 10.0), "%.2f" % plain)
	_gone(helm)

	# --- the charge -------------------------------------------------------------------
	var shielded := _target(Vector3.ZERO, 100.0, 1, 300.0)
	await _ticks(3)
	_arm(GunAltFire.CHARGE)
	gun.toggle_alt()
	_look(shielded.chest())
	var cost := gun.charge_cost()
	_charge_release(0.3)
	_ok("charge: a short charge fires nothing", is_equal_approx(_hp(shielded), 400.0))
	_charge_release(1.0)
	_ok("a full charge takes the whole shield, and nothing under it",
			is_equal_approx(shielded.health.get_layer_value(0), 0.0)
			and is_equal_approx(shielded.health.get_layer_value(1), 100.0),
			"%.1f / %.1f" % [shielded.health.get_layer_value(0), shielded.health.get_layer_value(1)])
	_ok("for a bite of the magazine", gun.ammo == 20 - cost and cost == 5, "cost %d" % cost)
	gun.toggle_alt()
	_charge_release(1.0)
	_ok("on bare flesh it is one plain round", is_equal_approx(shielded.health.get_layer_value(1), 90.0),
			"%.1f" % shielded.health.get_layer_value(1))
	gun.ammo = 2
	gun.toggle_alt()
	_refused.clear()
	_charge_release(1.0)
	_ok("refused without the ammo, and still in its alt mode", _refused.size() == 1
			and gun.ammo == 2 and gun.alt_on(), str(_refused))
	_gone(shielded)

	# --- the arc ----------------------------------------------------------------------
	var chain: Array[Pawn] = []
	for i in 5:
		chain.append(_target(Vector3(3.0 * i, 0.0, 0.0), 1000.0))
	var far := _target(Vector3(30.0, 0.0, 0.0), 1000.0)
	var friend := _target(Vector3(0.0, 0.0, -2.0), 1000.0, 0)
	await _ticks(3)
	_arm(GunAltFire.ARC)
	gun.toggle_alt()
	_look(chain[0].chest())
	gun.set_trigger(true)
	gun.step(0.001)
	var took: Array = chain.map(func(p: Pawn) -> float: return snappedf(1000.0 - _hp(p), 0.01))
	_ok("arc: the struck enemy and the next three, each less", took == [15.0, 12.0, 9.6, 7.68, 0.0],
			str(took))
	_ok("never the shooter's side, nothing far off", is_equal_approx(_hp(friend), 1000.0)
			and is_equal_approx(_hp(far), 1000.0))
	var slowed := true
	for i in 4:
		var st := ElementStatus.of(chain[i].body)
		if st == null or not is_equal_approx(chain[i].speed_mult, 1.0 - ElementStatus.SHOCK_SLOW):
			slowed = false
	_ok("each one it touched is slowed", slowed)
	gun.step(0.1)
	_ok("the trigger still down: the primary waits for it to come up", gun.ammo == 20
			and not gun.alt_on())
	gun.set_trigger(false)
	gun.step(0.001)
	gun.toggle_alt()
	var h0 := _hp(chain[0])
	gun.set_trigger(true)
	gun.step(0.001)
	gun.set_trigger(false)
	_ok("and it waits for its cooldown", is_equal_approx(_hp(chain[0]), h0) and gun.alt_on(),
			"%.1fs left" % gun.alt_cooldown_left())
	await _ticks(int((ElementStatus.TICK + GunController.ARC_SLOW_SECONDS + 0.2) * Engine.physics_ticks_per_second))
	_ok("the slow wears off", is_equal_approx(chain[1].speed_mult, 1.0)
			and ElementStatus.of(chain[1].body) == null)

	print("alt-fire probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)
