extends SceneTree

## The elements' statuses (Docs/Weapons/COMBAT_DESIGN.md 5, ElementStatus): what each
## element's part of a round leaves behind, through the one damage pipeline.
##
##     godot --headless --path . --script res://tools/status_probe.gd
##
##   burn      fire on flesh burns on for BURN_SHARE of what it dealt, over its time, then
##             stops; fire on a shield builds none; a shield coming back puts it out
##   corrode   corrosive on armor keeps eating the armor, and only the armor; on flesh
##             it builds none
##   chill     ice slows, more with more ice; enough ice freezes: the pawn stands still and
##             does not fire; it thaws after its time, and cannot be frozen again at once;
##             the chill thaws on its own when the ice stops
##   player    a player's pawn is slowed, never frozen
##   kinetic   a round with no element leaves nothing
##   death     a status ends with what it was on: nothing is left over

var _pass := 0
var _fail := 0


func _init() -> void:
	print("status probe")
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


func _seconds(s: float) -> void:
	await _ticks(int(ceil(s * Engine.physics_ticks_per_second)))


## A pawn with these layers, top first: [[type, value], ...].
func _target(at: Vector3, layers: Array, team := 1) -> Pawn:
	var p := Pawn.spawn(root, at, team, true, 100.0)
	var cfgs: Array[DefenseLayer] = []
	for l in layers:
		var d := DefenseLayer.new()
		d.layer_type = l[0]
		d.max_value = l[1]
		cfgs.append(d)
	p.health.layer_configs = cfgs
	p.health.impact_carries_over = false
	p.health._rebuild_state()
	return p


## A round of `amount`, all of it `element` (ratio 1), into `p`.
func _hit(p: Pawn, amount: float, element: StringName) -> DamageSystem.DamageResult:
	var pk := DamagePacket.new(amount, Elements.get_def(element), null)
	pk.element_ratio = 1.0 if element != &"" else 0.0
	return DamageSystem.resolve(pk, p.body)


func _layer(p: Pawn, i: int) -> float:
	return p.health.get_layer_value(i)


func _run() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80.0, 1.0, 80.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)

	# --- burn -------------------------------------------------------------------------
	var a := _target(Vector3.ZERO, [[&"health", 1000.0]])
	await _ticks(3)
	_hit(a, 10.0, Elements.FIRE)
	var st := ElementStatus.of(a.body)
	_ok("burn: fire on flesh sets it burning", st != null and st.is_burning())
	await _seconds(1.0)
	var mid := 990.0 - _layer(a, 0)
	_ok("it burns on over time, not at once", mid > 0.5 and mid < 5.0, "%.2f after 1 s" % mid)
	await _seconds(ElementStatus.BURN_SECONDS + 0.5)
	var burnt := 990.0 - _layer(a, 0)
	_ok("all told BURN_SHARE of what the fire dealt, then it stops",
			is_equal_approx(burnt, 10.0 * ElementStatus.BURN_SHARE), "%.2f" % burnt)
	_ok("and the status is gone", ElementStatus.of(a.body) == null)
	a.body.queue_free()

	var sh := _target(Vector3(4.0, 0.0, 0.0), [[&"shield", 1000.0], [&"health", 1000.0]])
	await _ticks(3)
	_hit(sh, 10.0, Elements.FIRE)
	_ok("fire on a shield builds no burn", ElementStatus.of(sh.body) == null
			or not ElementStatus.of(sh.body).is_burning())
	sh.body.queue_free()

	# A shield coming back puts it out: burn on bare flesh, then a shield over it.
	var re := _target(Vector3(8.0, 0.0, 0.0), [[&"shield", 10.0], [&"health", 1000.0]])
	await _ticks(3)
	_hit(re, 10.0, &"")
	_hit(re, 20.0, Elements.FIRE)
	re.health._current[0] = 10.0   # the shield regenerates
	await _seconds(1.0)
	_ok("a shield coming back puts it out", ElementStatus.of(re.body) == null
			and is_equal_approx(_layer(re, 1), 980.0), "%.2f" % _layer(re, 1))
	re.body.queue_free()

	# --- corrode ----------------------------------------------------------------------
	var arm := _target(Vector3(12.0, 0.0, 0.0), [[&"armor", 1000.0], [&"health", 100.0]])
	await _ticks(3)
	_hit(arm, 10.0, Elements.CORROSIVE)   # 2x on armor: 20
	var hit_armor := 1000.0 - _layer(arm, 0)
	await _seconds(ElementStatus.CORRODE_SECONDS + 0.5)
	var eaten := 1000.0 - _layer(arm, 0) - hit_armor
	_ok("corrode: corrosive on armor keeps eating it, CORRODE_SHARE of what it dealt",
			is_equal_approx(hit_armor, 20.0) and is_equal_approx(eaten, 20.0 * ElementStatus.CORRODE_SHARE),
			"%.2f then %.2f" % [hit_armor, eaten])
	_ok("and only the armor", is_equal_approx(_layer(arm, 1), 100.0))
	arm.body.queue_free()
	var bare := _target(Vector3(16.0, 0.0, 0.0), [[&"health", 1000.0]])
	await _ticks(3)
	_hit(bare, 10.0, Elements.CORROSIVE)
	_ok("corrosive on flesh builds none", ElementStatus.of(bare.body) == null)

	# --- kinetic ----------------------------------------------------------------------
	_hit(bare, 10.0, &"")
	_ok("a round with no element leaves nothing", ElementStatus.of(bare.body) == null)
	bare.body.queue_free()

	# --- chill ------------------------------------------------------------------------
	var ice := _target(Vector3(20.0, 0.0, 0.0), [[&"health", 1000.0]])
	await _ticks(3)
	# 1000 health: 250 of ice freezes it. 50 is a fifth of the way.
	_hit(ice, 50.0, Elements.ICE)
	var s1 := ice.speed_mult
	_hit(ice, 50.0, Elements.ICE)
	var s2 := ice.speed_mult
	_ok("chill: ice slows, more with more ice", s1 < 1.0 and s2 < s1 and not ice.frozen,
			"%.2f then %.2f" % [s1, s2])
	_hit(ice, 160.0, Elements.ICE)
	_ok("enough ice freezes it", ice.frozen and is_equal_approx(ice.speed_mult, 0.0))
	var at := ice.feet()
	ice.intents.move = Vector3(1.0, 0.0, 0.0)
	ice.intents.fire = true
	await _seconds(0.5)
	_ok("frozen, it stands still and does not fire", ice.feet().distance_to(at) < 0.01
			and not ice.intents.fire, "moved %.3f" % ice.feet().distance_to(at))
	await _seconds(ElementStatus.FREEZE_SECONDS)
	_ok("it thaws after its time, and is at full speed", not ice.frozen
			and is_equal_approx(ice.speed_mult, 1.0))
	_hit(ice, 300.0, Elements.ICE)
	_ok("and cannot be frozen again at once", not ice.frozen)
	await _seconds(ElementStatus.THAW_GRACE + 0.1)
	_hit(ice, 100.0, Elements.ICE)
	var c0 := ice.speed_mult
	await _seconds(ElementStatus.CHILL_HOLD + 1.0)
	_ok("when the ice stops, the chill thaws on its own", ice.speed_mult > c0,
			"%.2f to %.2f" % [c0, ice.speed_mult])

	# The slow is real: a slowed pawn walks less far.
	ice.intents.move = Vector3.ZERO
	await _seconds(3.0)
	var free_walk := await _walk(ice, 30)
	_hit(ice, 150.0, Elements.ICE)
	var slow_walk := await _walk(ice, 30)
	_ok("a chilled pawn walks less far", slow_walk < free_walk * 0.85,
			"%.2f m against %.2f m" % [slow_walk, free_walk])
	ice.body.queue_free()

	# --- player -----------------------------------------------------------------------
	var me := _target(Vector3(28.0, 0.0, 0.0), [[&"health", 1000.0]], 0)
	me.is_player = true
	await _ticks(3)
	_hit(me, 600.0, Elements.ICE)
	_ok("a player's pawn is slowed, never frozen", not me.frozen
			and is_equal_approx(me.speed_mult, 1.0 - ElementStatus.SLOW_MAX))
	me.body.queue_free()

	# --- death ------------------------------------------------------------------------
	var d := _target(Vector3(32.0, 0.0, 0.0), [[&"health", 30.0]])
	await _ticks(3)
	_hit(d, 20.0, Elements.FIRE)
	_hit(d, 20.0, &"")
	await _ticks(3)
	_ok("a status ends with what it was on", d.health.is_dead() and ElementStatus.of(d.body) == null)

	print("status probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)


## How far `p` walks in `n` ticks asked to go +X.
func _walk(p: Pawn, n: int) -> float:
	var from := p.feet()
	for i in n:
		p.intents.move = Vector3(1.0, 0.0, 0.0)
		await physics_frame
	p.intents.move = Vector3.ZERO
	var to := p.feet()
	return Vector2(to.x - from.x, to.z - from.z).length()
