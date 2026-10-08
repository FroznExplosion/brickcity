extends SceneTree

## Probe for how a mech is killed (MechLayers; Docs/AIRoster.md 4.2, 4.6, 4.7, RO6).
##
##     godot --headless --path . --script tools/mech_layers_probe.gd
##
## Each check builds its own mech(s) and hits them by the rules:
##   classes     light has the most shield and its hatch at the back; heavy the
##               most armour and its hatch in front (the roster's numbers)
##   scales      a person's gun does nothing; plasma on the shield and corrosive
##               on bare armour a tenth; an explosive half; a mech's gun in full
##   order       the shield is first; the armour next; then the health
##   doors       a hit on the hatch wears it, and it can come off before the
##               armour is gone; armour gone, a door still on is left very low
##   pilot       hatch off, a person's gun reaches the pilot; killed, the mech
##               lives on, on auto
##   cell        cell door off, the cell is shot for three times; gone, the mech
##               blows up -- and a Nuker's does not nuke
##   doomed      health drained: the shield dies and stays dead, the hit that
##               doomed it does not skip the state, a few more finish it
##   melee       through the shield; a doomed mech is finished, and a Nuker
##               finished does not nuke
##   nuke        a Nuker doomed throws its pilot clear and goes off 4 s later,
##               hurting the mech beside it
##   wrong pilot a pilot of another side sets it off; its own side's gets in
##   the shield  comes back after its pause
##   the pipe    a gun's hit through DamageSystem obeys all of it

var _pass := 0
var _fail := 0
var r: Roster
var _tick := 0
var _nuker: Mech
var _near: Mech
var _thief: Mech
var _regen: Mech
var _log := {}
var _x := 0.0


func _init() -> void:
	print("mech layers probe")
	r = Roster.shared()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A mech of the roster's `type` (or the medium default), well away from the others.
func _mech(type := "", team := 1) -> Mech:
	_x += 80.0
	var m := Mech.spawn(root, Vector3(_x, 0.0, 0.0), 0.0, team)
	if type != "":
		m.set_type(type, r)
	return m


## Take a layer off with a mech's gun, exactly: a hit that breaks the shield only
## carries half of what is left over into the armour (shield gating), so layers
## are stripped one at a time.
func _strip(l: MechLayers, type: StringName) -> void:
	for i in 8:
		if l.value(type) <= 0.0:
			return
		l.take(l.value(type), &"mech")


func _vals(m: Mech) -> String:
	var l := m.layers
	return "shield %.0f armour %.0f health %.0f hatch %.0f cell door %.0f" % [l.value(MechLayers.SHIELD),
			l.value(MechLayers.ARMOR), l.value(MechLayers.HEALTH), l.hatch, l.cell_door]


func _static_checks() -> void:
	var light := _mech("light_melee_nuker")
	var heavy := _mech("heavy_gunner_nuker")
	_ok("classes: light most shield, hatch at the back; heavy most armour, hatch in front; names over them",
			light.layers.value(MechLayers.SHIELD) > heavy.layers.value(MechLayers.SHIELD)
			and heavy.layers.value(MechLayers.ARMOR) > light.layers.value(MechLayers.ARMOR)
			and light.layers.hatch_side == "back" and heavy.layers.hatch_side == "front"
			and light.layers.nuker and heavy.name_tag.text == "Heavy Gunner Nuker",
			"light: %s | heavy: %s" % [_vals(light), _vals(heavy)])

	# --- scales
	var m := _mech()
	var l := m.layers
	var rifle := l.take(100.0, &"person")
	var plasma := l.take(100.0, &"person", &"", Elements.PLASMA)
	var corro_shielded := l.take(100.0, &"person", &"", Elements.CORROSIVE)
	var boom := l.take(100.0, &"explosive")
	var cannon := l.take(100.0, &"mech")
	var anti := l.take(100.0, &"anti_mech")
	_ok("scales: a person's gun nothing; plasma on the shield a tenth; an explosive half; a mech's and an anti-mech gun in full",
			rifle == 0.0 and is_equal_approx(plasma, 10.0) and corro_shielded == 0.0 and is_equal_approx(boom, 50.0)
			and is_equal_approx(cannon, 100.0) and is_equal_approx(anti, 100.0),
			"rifle %.0f, plasma %.0f, corrosive %.0f, explosive %.0f, mech %.0f, anti-mech %.0f" % [rifle, plasma, corro_shielded, boom, cannon, anti])
	# --- order
	var armour0 := l.value(MechLayers.ARMOR)
	l.take(l.value(MechLayers.SHIELD) - 1.0, &"mech")
	var armour_shielded := l.value(MechLayers.ARMOR)
	l.take(101.0, &"mech")
	_ok("order: nothing reaches the armour while the shield is up; what breaks the shield goes on into it",
			is_equal_approx(armour_shielded, armour0) and not l.shield_up() and l.value(MechLayers.ARMOR) < armour0
			and is_equal_approx(l.value(MechLayers.HEALTH), 1250.0), _vals(m))
	var plasma_bare := l.take(100.0, &"person", &"", Elements.PLASMA)
	var corro_bare := l.take(100.0, &"person", &"", Elements.CORROSIVE)
	_ok("and with the shield down: plasma nothing, corrosive on bare armour a tenth",
			plasma_bare == 0.0 and is_equal_approx(corro_bare, 10.0), "plasma %.0f, corrosive %.0f" % [plasma_bare, corro_bare])

	# --- doors and the pilot
	m = _mech()
	l = m.layers
	l.take(l.value(MechLayers.SHIELD), &"mech")
	var hatch0 := l.hatch
	l.take(200.0, &"mech", &"hatch")
	var worn := hatch0 - l.hatch
	l.take(200.0, &"mech", &"hatch")
	_ok("doors: a hit on the hatch wears it too, and it comes off before the armour is gone",
			is_equal_approx(worn, 200.0) and l.hatch_off and not l.armour_gone(), _vals(m))
	var hull_before := m.health.total_current()
	l.take(60.0, &"person", &"hatch")
	var alive_pilot := l.piloted
	l.take(60.0, &"person", &"hatch")
	_ok("pilot: hatch off, a person's gun reaches the pilot; killed, the mech lives on, on auto",
			alive_pilot and not l.piloted and l.auto and not l.dead and is_equal_approx(m.health.total_current(), hull_before),
			"piloted %s, auto %s, hull untouched" % [l.piloted, l.auto])

	# --- armour gone, the cell
	m = _mech("heavy_gunner_nuker")
	l = m.layers
	_strip(l, MechLayers.SHIELD)
	_strip(l, MechLayers.ARMOR)
	_ok("armour gone with the doors still on: each is left very low",
			l.armour_gone() and not l.hatch_off and not l.cell_door_off and is_equal_approx(l.hatch, MechLayers.DOOR_LOW)
			and is_equal_approx(l.cell_door, MechLayers.DOOR_LOW), _vals(m))
	var blasts := []
	l.exploded.connect(func(kind: String, _at: Vector3) -> void: blasts.append(kind))
	l.take(50.0, &"mech", &"cell")
	var door_off := l.cell_door_off
	var cell0 := l.power_cell
	l.take(50.0, &"person", &"cell")
	var crit := cell0 - l.power_cell
	l.take(50.0, &"person", &"cell")
	_ok("cell: the door off, anybody's gun hits the power cell for three times; gone, the mech blows up -- a Nuker's too, and no nuke",
			door_off and is_equal_approx(crit, 150.0) and l.dead and l.cause == "cell" and blasts == ["self_destruct"] and l.nuker,
			"cell took %.0f from a 50 hit; cause %s; blast %s" % [crit, l.cause, blasts])

	# --- doomed
	m = _mech()
	l = m.layers
	_strip(l, MechLayers.SHIELD)
	_strip(l, MechLayers.ARMOR)
	l.take(l.value(MechLayers.HEALTH) + 5000.0, &"mech")
	var doomed_pool := l.value(MechLayers.DOOMED)
	_ok("doomed: health drained; the hit that did it does not skip the state",
			l.doomed and not l.dead and is_equal_approx(doomed_pool, 250.0) and not l.shield_up(), "doomed pool %.0f" % doomed_pool)
	_log["doomed_mech"] = m
	var hits := 0
	while not l.dead and hits < 10:
		l._doom_block = false
		l.take(100.0, &"mech")
		hits += 1
	_ok("and a few more hits finish it", l.dead and l.cause == "doomed" and hits <= 3, "%d hit(s) of 100" % hits)

	# --- melee
	m = _mech()
	l = m.layers
	var shield0 := l.value(MechLayers.SHIELD)
	l.melee(500.0)
	_ok("melee: through the shield, into the armour", is_equal_approx(l.value(MechLayers.SHIELD), shield0)
			and is_equal_approx(l.value(MechLayers.ARMOR), 1000.0), _vals(m))
	var puncher := Mech.spawn(root, m.feet() + Vector3(4.0, 0.0, 0.0), 0.0, 0)
	var far := Mech.spawn(root, m.feet() + Vector3(40.0, 0.0, 0.0), 0.0, 0)
	var landed := puncher.melee(m)
	var again := puncher.melee(m)
	var out_of_reach := far.melee(m)
	_ok("a mech's fist: in reach it lands, not twice at once, and not from across the street",
			landed and not again and not out_of_reach and is_equal_approx(l.value(MechLayers.ARMOR), 500.0), _vals(m))
	var nk := _mech("heavy_gunner_nuker")
	_strip(nk.layers, MechLayers.SHIELD)
	_strip(nk.layers, MechLayers.ARMOR)
	_strip(nk.layers, MechLayers.HEALTH)
	var lit := nk.layers.fuse_kind
	var nk_blasts := []
	nk.layers.exploded.connect(func(kind: String, _at: Vector3) -> void: nk_blasts.append(kind))
	var finished := nk.layers.melee(500.0)
	_ok("a doomed mech is finished by a melee, and a Nuker finished does not nuke",
			lit == "nuke" and finished and nk.layers.dead and nk.layers.cause == "finisher" and nk_blasts.is_empty(),
			"fuse was %s; cause %s; blasts %s" % [lit, nk.layers.cause, nk_blasts])

	# --- the pipe
	m = _mech()
	l = m.layers
	var p := DamagePacket.new(100.0)
	p.scale = &"person"
	p.hit_position = m.feet() + Vector3.UP * 3.0
	var none := DamageSystem.resolve(p, m.body).dealt
	p.scale = &"mech"
	var full := DamageSystem.resolve(p, m.body).dealt
	l.take(l.value(MechLayers.SHIELD), &"mech")
	p.hit_position = l.hatch_point()
	var hatch1 := l.hatch
	DamageSystem.resolve(p, m.body)
	_ok("the pipe: a gun's hit through DamageSystem obeys it -- nothing from a person, all from a mech, and on the hatch it wears the hatch",
			none == 0.0 and is_equal_approx(full, 100.0) and is_equal_approx(hatch1 - l.hatch, 100.0)
			and l.zone_at(l.hatch_point()) == &"hatch" and l.zone_at(l.cell_point()) == &"cell"
			and l.zone_at(m.feet() + Vector3.UP * 0.5) == &"", "person %.0f, mech %.0f, hatch wore %.0f" % [none, full, hatch1 - l.hatch])

	# --- for the timed checks
	_nuker = _mech("heavy_gunner_nuker")
	_near = Mech.spawn(root, _nuker.feet() + Vector3(15.0, 0.0, 0.0), 0.0, 0)
	_log["near0"] = _near.health.total_current()
	_nuker.layers.exploded.connect(func(kind: String, _at: Vector3) -> void: _log["nuke_kind"] = kind)
	_strip(_nuker.layers, MechLayers.SHIELD)
	_strip(_nuker.layers, MechLayers.ARMOR)
	_strip(_nuker.layers, MechLayers.HEALTH)
	_log["nuke_lit"] = _nuker.layers.fuse_kind
	_log["thrown_clear"] = not _nuker.layers.piloted
	_thief = _mech("", 1)
	_log["own_side"] = _thief.layers.try_enter(1) and _thief.layers.fuse_kind == ""
	_log["other_side"] = not _thief.layers.try_enter(0) and _thief.layers.fuse_kind == "self_destruct"
	_regen = _mech()
	_regen.layers.take(_regen.layers.value(MechLayers.SHIELD) + 100.0, &"mech")
	_log["doomed_shield"] = (_log.doomed_mech as Mech).layers.value(MechLayers.SHIELD)


func _timed_checks() -> void:
	_ok("nuke: a Nuker doomed throws its pilot clear, counts four seconds, and goes off -- the mech 15 m away is hurt",
			str(_log.nuke_lit) == "nuke" and bool(_log.thrown_clear) and str(_log.get("nuke_kind", "")) == "nuke"
			and _nuker.layers.dead and _nuker.layers.cause == "nuke" and float(_log.get("near_lost", 0.0)) > 800.0,
			"went off after %.1f s; the mech beside it lost %.0f" % [float(_log.get("nuke_at", -1.0)), float(_log.get("near_lost", 0.0))])
	_ok("wrong pilot: its own side's gets in; another side's sets it off, two seconds later",
			bool(_log.own_side) and bool(_log.other_side) and _thief.layers.dead and _thief.layers.cause == "self_destruct"
			and float(_log.get("thief_at", 99.0)) < 2.5, "blew up after %.1f s" % float(_log.get("thief_at", -1.0)))
	_ok("the shield comes back after its pause -- and a doomed mech's never does",
			float(_log.get("regen_early", 1.0)) == 0.0 and _regen.layers.value(MechLayers.SHIELD) > 500.0
			and (_log.doomed_mech as Mech).layers.value(MechLayers.SHIELD) == 0.0,
			"0 at 3 s, %.0f at 12 s" % _regen.layers.value(MechLayers.SHIELD))


func _on_tick() -> void:
	_tick += 1
	if _tick == 2:
		_ok("the roster loads", r != null)
		_static_checks()
		return
	if _tick < 2:
		return
	var t := float(_tick - 2) / float(Engine.physics_ticks_per_second)
	if _nuker.layers.dead and not _log.has("nuke_at"):
		_log["nuke_at"] = t
		_log["near_lost"] = float(_log.near0) - _near.health.total_current()
	if _thief.layers.dead and not _log.has("thief_at"):
		_log["thief_at"] = t
	if t >= 3.0 and not _log.has("regen_early"):
		_log["regen_early"] = _regen.layers.value(MechLayers.SHIELD)
	if t >= 12.0:
		_timed_checks()
		print("\n%d passed, %d failed" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
