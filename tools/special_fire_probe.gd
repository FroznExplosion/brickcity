extends SceneTree

## The rest of the alt-fires, the shock special weapon, the shatter and the soldiers'
## alt-fire (Docs/Weapons/COMBAT_DESIGN.md 5, 7.2, 7.3).
##
##     godot --headless --path . --script res://tools/special_fire_probe.gd
##
##   roll       the grenade tube only on rifles and LMGs, the torch only on SMGs and
##              shotguns
##   tube       a press lobs a grenade that bursts where it lands: the struck enemy takes
##              the whole burst, a near one less, a far one none; then a cooldown
##   torch      its cone burns what is in front, not what is beside; corrosive, so armor
##              takes twice what flesh does; it runs out of fuel and cools down
##   arc caster the ordnance's charge arcs through six enemies, each less, each slowed
##   shatter    frozen takes 1.5x; frozen and bare, a melee or a hit that leaves the flesh
##              low shatters it; a shield up, a high flesh, or no ice, and it does not
##   soldiers   with ai_alt the trigger fires the alt-fire too, at most once a gap; the
##              plasma charge only at a shield; without ai_alt, never

const RANGE := 5.0

var _pass := 0
var _fail := 0
var gun: GunController
var aim: Node3D
var _side: Array = []
var _lib: GunPartLibrary
var _pawns: Array = []


func _init() -> void:
	print("special fire probe")
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


func _run() -> void:
	_lib = GunPlaceholderParts.build_library()
	aim = Node3D.new()
	root.add_child(aim)
	gun = GunController.new()
	gun.aim = aim
	gun.rng = RandomNumberGenerator.new()
	gun.team = 0
	root.add_child(gun)
	gun.side_hit.connect(func(i: Dictionary) -> void: _side.append(i))
	_roll()
	await _tube()
	await _torch()
	await _caster()
	await _shatter()
	await _soldiers()
	print("special fire probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)


## A plain gun of `cls`, 10 a round, dead accurate, with this alt-fire.
func _arm(alt: StringName, cls := &"rifle") -> GunInstance:
	var gi := GunInstance.from_result(GunGenerator.generate(_lib, 11, WeaponClass.builtin(cls), 1, 1))
	for k: StringName in [&"power_shot_every", &"double_fire_every", &"double_fire_chance",
			&"shield_buster", &"overkill_ricochet", &"explosive"]:
		gi.stats.erase(k)
	gi.stats[&"damage"] = 10.0
	gi.stats[&"accuracy"] = 1.0
	gi.stats[&"element_ratio"] = 0.0
	gi.stats[&"mag_size"] = 20.0
	gi.stats[&"fire_rate"] = 10.0
	gi.element_id = &""
	gi.active_effects = PackedStringArray()
	gi.alt_fire = alt
	gi.alt_mode = false
	root.add_child(gi)
	gun.equip(gi)
	gun._alt_cool = 0.0
	return gi


func _target(at: Vector3, hp: float, layer := &"", layer_hp := 0.0) -> Pawn:
	var p := Pawn.spawn(root, at, 1, true, hp)
	if layer != &"":
		var d := DefenseLayer.new()
		d.layer_type = layer
		d.max_value = layer_hp
		var h := DefenseLayer.new()
		h.max_value = hp
		p.health.layer_configs = [d, h]
		p.health.impact_carries_over = false
		p.health._rebuild_state()
	_pawns.append(p)
	return p


func _clear() -> void:
	for p in _pawns:
		if is_instance_valid(p):
			p.body.queue_free()
	_pawns.clear()
	_side.clear()


## Stand RANGE back from `to` along +Z and look at it.
func _look(to: Vector3) -> void:
	var from := to + Vector3(0.0, 0.0, RANGE)
	aim.global_transform = Transform3D(Basis.looking_at(to - from, Vector3.UP), from)


func _press() -> void:
	gun._cooldown = 0.0
	gun.set_trigger(true)
	gun.step(0.001)
	gun.set_trigger(false)
	gun.step(0.001)


func _lost(p: Pawn) -> float:
	var t := 0.0
	for i in p.health.layer_count():
		t += p.health.layer_configs[i].max_value - p.health.get_layer_value(i)
	return t


# --- the roll -----------------------------------------------------------------------------

func _roll() -> void:
	var seen := {}
	for cls: StringName in [&"pistol", &"smg", &"rifle", &"lmg", &"shotgun", &"revolver"]:
		for s in 300:
			var a := GunAltFire.roll(s, 6, WeaponClass.builtin(cls))
			if a != &"":
				seen["%s/%s" % [cls, a]] = true
	_ok("the grenade tube on rifles and LMGs only", seen.has("rifle/tube") and seen.has("lmg/tube")
			and not seen.has("pistol/tube") and not seen.has("smg/tube") and not seen.has("shotgun/tube"))
	_ok("the torch on SMGs and shotguns only", seen.has("smg/torch") and seen.has("shotgun/torch")
			and not seen.has("rifle/torch") and not seen.has("pistol/torch"))


# --- the grenade tube ---------------------------------------------------------------------

func _tube() -> void:
	var at := Vector3(0.0, 0.0, -20.0)
	var hit := _target(at, 1000.0)
	var near := _target(at + Vector3(2.0, 0.0, 0.0), 1000.0)
	var far := _target(at + Vector3(7.0, 0.0, 0.0), 1000.0)
	await _ticks(2)
	_arm(GunAltFire.TUBE)
	_look(at + Vector3(0.0, 0.9, 0.0))
	gun.toggle_alt()
	_press()
	_ok("a press lobs a grenade, and the gun is back on its primary",
			not gun.gun.alt_mode and gun.alt_cooldown_left() > 0.0)
	await _ticks(20)
	var whole := 10.0 * GunController.TUBE_MULT
	_ok("it bursts on the struck enemy: the whole burst", is_equal_approx(_lost(hit), whole),
			"%.0f" % _lost(hit))
	_ok("a near one less, a far one none", _lost(near) > 0.0 and _lost(near) < whole
			and _lost(far) == 0.0, "near %.0f, far %.0f" % [_lost(near), _lost(far)])
	gun.toggle_alt()
	_press()
	await _ticks(20)
	_ok("and not again until it cools", is_equal_approx(_lost(hit), whole))
	_clear()
	await _ticks(2)


# --- the thermal torch --------------------------------------------------------------------

func _torch() -> void:
	var at := Vector3(0.0, 0.0, -40.0)
	var armored := _target(at, 1000.0, &"armor", 1000.0)
	var flesh := _target(at + Vector3(0.6, 0.0, 0.0), 1000.0)
	var beside := _target(at + Vector3(4.5, 0.0, 2.5), 1000.0)
	await _ticks(2)
	_arm(GunAltFire.TORCH, &"smg")
	var from := at + Vector3(0.0, 0.9, 3.0)
	aim.global_transform = Transform3D(Basis.looking_at(Vector3(0.0, 0.0, -1.0), Vector3.UP), from)
	var n := gun._burn_cone(0.5)
	_ok("the cone burns what is in front, not what is beside", n == 2 and _lost(beside) == 0.0,
			"%d burned" % n)
	_ok("corrosive: armor takes twice what flesh does",
			is_equal_approx(_lost(armored), 2.0 * _lost(flesh)) and _lost(flesh) > 0.0,
			"%.1f vs %.1f" % [_lost(armored), _lost(flesh)])
	gun.toggle_alt()
	gun.set_trigger(true)
	gun.step(0.001)
	var burned := 0.0
	gun.step(0.1)
	_ok("burning, the flame is lit at the muzzle, down the aim", gun._flame != null and gun._flame.emitting
			and gun._flame.global_transform.basis.z.dot(aim.global_transform.basis.z) > 0.99)
	for i in 40:
		gun.step(0.1)
	_ok("and out when the fuel is", not gun._flame.emitting)
	burned = _lost(flesh)
	_ok("held, it runs out of fuel: back on the primary, cooling",
			not gun.gun.alt_mode and gun.alt_cooldown_left() > 0.0)
	gun.set_trigger(false)
	gun.step(0.001)
	_ok("and it burned only its fuel's worth", burned < _lost(flesh) + 0.01
			and burned <= 10.0 * GunController.TORCH_ROUNDS * (GunController.TORCH_FUEL + 0.5) + 30.0,
			"%.0f" % burned)
	_clear()
	await _ticks(2)


# --- the arc caster -----------------------------------------------------------------------

func _caster() -> void:
	var at := Vector3(0.0, 0.0, -60.0)
	var line: Array[Pawn] = []
	for i in 7:
		line.append(_target(at + Vector3(4.0 * i, 0.0, 0.0), 5000.0))
	await _ticks(2)
	var gi := GunInstance.from_result(GunGenerator.generate(_lib, 5, WeaponClass.builtin(&"arc_caster"), 1))
	root.add_child(gi)
	gun.equip(gi)
	_ok("the arc caster is ordnance", gi.weapon_class.is_ordnance and gi.alt_fire == &"")
	_look(at + Vector3(0.0, 0.9, 0.0))
	_side.clear()
	_press()
	var hurt := []
	for p in line:
		hurt.append(_lost(p))
	_ok("one charge arcs through six enemies, each less",
			hurt[0] > hurt[1] and hurt[1] > hurt[5] and hurt[5] > 0.0 and hurt[6] == 0.0,
			str(hurt.map(func(x): return roundi(x))))
	var es := ElementStatus.of(line[3].body)
	_ok("and slows them", es != null and line[3].speed_mult < 1.0)
	_clear()
	await _ticks(2)


# --- the shatter --------------------------------------------------------------------------

func _freeze(p: Pawn) -> void:
	var s := ElementStatus.of(p.body, true)
	s.frozen_left = 2.0


func _hit(p: Pawn, amount: float, melee := false) -> DamageSystem.DamageResult:
	var pk := DamagePacket.new(amount, null, gun)
	pk.melee = melee
	return DamageSystem.resolve(pk, p.body)


func _shatter() -> void:
	var a := _target(Vector3(10.0, 0.0, -80.0), 100.0)
	var b := _target(Vector3(14.0, 0.0, -80.0), 100.0, &"shield", 50.0)
	var c := _target(Vector3(18.0, 0.0, -80.0), 100.0)
	var d := _target(Vector3(22.0, 0.0, -80.0), 100.0)
	await _ticks(2)
	_freeze(a)
	_ok("frozen takes 1.5x", is_equal_approx(_hit(a, 10.0).dealt, 15.0))
	var r := _hit(a, 10.0, true)
	_ok("frozen and bare, a melee shatters it", r.killed and r.shattered and a.health.is_dead())
	_freeze(b)
	r = _hit(b, 10.0, true)
	_ok("a shield up: the melee takes the shield, no shatter", not r.killed and not b.health.is_dead())
	_freeze(c)
	r = _hit(c, 40.0)
	_ok("a hit that leaves the flesh high does not shatter", not r.killed and not r.shattered,
			"%.0f left" % c.health.get_layer_value(0))
	r = _hit(c, 10.0)
	_ok("one that leaves it low does", r.killed and r.shattered)
	r = _hit(d, 10.0, true)
	_ok("no ice, no shatter", not r.killed)
	_clear()
	await _ticks(2)


# --- the soldiers -------------------------------------------------------------------------

func _soldiers() -> void:
	var at := Vector3(0.0, 0.0, -100.0)
	var t := _target(at, 5000.0)
	var t2 := _target(at + Vector3(3.0, 0.0, 0.0), 5000.0)
	await _ticks(2)
	_arm(GunAltFire.ARC, &"pistol")
	_look(at + Vector3(0.0, 0.9, 0.0))
	gun.ai_alt = false
	_side.clear()
	gun.set_trigger(true)
	gun.step(0.001)
	gun.set_trigger(false)
	gun.step(0.001)
	_ok("without ai_alt the trigger is only the primary", _side.filter(func(i): return i.side == &"shock").is_empty())
	gun.ai_alt = true
	_side.clear()
	gun.set_trigger(true)
	gun.step(0.001)
	gun.step(0.1)
	gun.step(0.1)
	var shocks := _side.filter(func(i): return i.side == &"shock").size()
	gun.set_trigger(false)
	gun.step(0.001)
	_ok("with it, the arc goes once, then waits its gap", shocks == 2
			and gun.alt_cooldown_left() >= GunController.AI_ALT_GAP - 0.5, "%d shocks" % shocks)
	_clear()
	await _ticks(2)

	var bare := _target(at, 500.0)
	await _ticks(2)
	_arm(GunAltFire.CHARGE, &"pistol")
	_look(at + Vector3(0.0, 0.9, 0.0))
	_side.clear()
	gun.set_trigger(true)
	gun.step(0.001)
	gun.set_trigger(false)
	gun.step(0.001)
	_ok("the plasma charge not at bare flesh", _side.filter(func(i): return i.side == &"charge").is_empty())
	_clear()
	await _ticks(2)
	var shielded := _target(at, 500.0, &"shield", 200.0)
	await _ticks(2)
	gun._alt_cool = 0.0
	_side.clear()
	gun.set_trigger(true)
	gun.step(0.001)
	gun.set_trigger(false)
	gun.step(0.001)
	_ok("at a shield, it takes it", not _side.filter(func(i): return i.side == &"charge").is_empty()
			and shielded.health.get_layer_value(0) <= 0.0)
	gun.ai_alt = false
	_clear()
	await _ticks(2)
