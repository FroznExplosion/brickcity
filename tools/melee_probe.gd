extends SceneTree

## Melee (Docs/Weapons/COMBAT_DESIGN.md 4.1): a player who looks at an enemy knows how
## many melees it takes, and that is what it takes.
##
##     godot --headless --path . --script res://tools/melee_probe.gd
##
##   counts       every enemy profile dies in exactly its card's count (each layer's
##                melees rounded up), at tier 1 and tier 6 alike
##   one step     a blow that breaks a defence stops there: the flesh under it is whole
##   shields      a blow does 1.5x to a shield, so one melee breaks one shield-melee
##   no crit      a blow flagged as a crit lands the same as one that is not
##   then head    melee the shield off, and the next headshot crits
##   tier         a blow is a melee of its own tier: a tier-1 blow takes two to fell a
##                tier-2 light enemy's one melee of flesh
##   reach        a pawn's blow fells a light enemy in front of it, whiffs at one out of
##                reach, and never lands through a wall

var _pass := 0
var _fail := 0


func _init() -> void:
	print("melee probe")
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


func _pool(profile: StringName, level := 1) -> HealthPool:
	var holder := Node.new()
	root.add_child(holder)
	var p := HealthPool.new()
	p.name = "HealthPool"
	holder.add_child(p)
	EnemyProfiles.apply(p, profile, level)
	return p


func _melee(pool: HealthPool, tier: int, crit := false) -> DamageSystem.DamageResult:
	var pk := DamagePacket.new(CombatScale.melee(tier), null, null)
	pk.melee = true
	pk.crit = crit
	pk.crit_multiplier = 2.0
	return DamageSystem.resolve(pk, pool.get_parent())


func _count(profile: StringName, tier: int) -> int:
	var pool := _pool(profile, tier)
	var n := 0
	while not pool.is_dead() and n < 50:
		_melee(pool, tier)
		n += 1
	return n


func _run() -> void:
	# --- counts ---------------------------------------------------------------------
	for id in EnemyProfiles.PROFILES:
		var want := 0
		for m in EnemyProfiles.melee_counts(id):
			want += ceili(m)
		for tier in [1, 6]:
			var got := _count(id, tier)
			_ok("%s at tier %d dies in %d melees" % [id, tier, want], got == want, "took %d" % got)

	# --- one step -------------------------------------------------------------------
	var ls := _pool(&"light_shielded")
	var flesh_full := ls.get_layer_value(1)
	_melee(ls, 1)
	_ok("a blow that breaks a shield stops there", ls.get_layer_value(0) <= 0.0
			and is_equal_approx(ls.get_layer_value(1), flesh_full),
			"shield %.1f, flesh %.1f of %.1f" % [ls.get_layer_value(0), ls.get_layer_value(1), flesh_full])
	var la := _pool(&"light_armored")
	var la_flesh := la.get_layer_value(1)
	_melee(la, 1)
	_ok("and so does one that breaks armor", la.get_layer_value(0) <= 0.0
			and is_equal_approx(la.get_layer_value(1), la_flesh))

	# --- shields --------------------------------------------------------------------
	var ms := _pool(&"medium_shielded")
	var r := _melee(ms, 1)
	_ok("a blow does 1.5x to a shield", is_equal_approx(r.dealt, CombatScale.melee(1) * 1.5),
			"%.2f vs %.2f" % [r.dealt, CombatScale.melee(1) * 1.5])

	# --- no crit --------------------------------------------------------------------
	var a := _pool(&"medium")
	var b := _pool(&"medium")
	var plain := _melee(a, 1)
	var flagged := _melee(b, 1, true)
	_ok("a blow is never a crit", not flagged.was_crit and is_equal_approx(plain.dealt, flagged.dealt))

	# --- then head ------------------------------------------------------------------
	var mh := _pool(&"light_shielded")
	_melee(mh, 1)
	var shot := DamagePacket.new(10.0, null, null)
	shot.crit = true
	shot.crit_multiplier = 2.0
	var hs := DamageSystem.resolve(shot, mh.get_parent())
	_ok("melee the shield off, and the next headshot crits", hs.was_crit
			and is_equal_approx(hs.dealt, 20.0), "dealt %.1f" % hs.dealt)

	# --- tier -----------------------------------------------------------------------
	var up := _pool(&"light", 2)
	var n := 0
	while not up.is_dead() and n < 10:
		_melee(up, 1)
		n += 1
	_ok("a tier-1 blow takes 2 on a tier-2 light enemy", n == 2, "took %d" % n)

	# --- reach ----------------------------------------------------------------------
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)

	var me := Pawn.spawn(root, Vector3.ZERO, 0)
	var near := Pawn.spawn(root, Vector3(0.0, 0.0, -1.2), 1)
	EnemyProfiles.apply(near.health, &"light", 1)
	var far := Pawn.spawn(root, Vector3(8.0, 0.0, -3.5), 1)
	EnemyProfiles.apply(far.health, &"light", 1)
	var walled := Pawn.spawn(root, Vector3(-8.0, 0.0, -1.4), 1)
	EnemyProfiles.apply(walled.health, &"light", 1)
	var wall := StaticBody3D.new()
	wall.collision_layer = Layers.WORLD
	var ws := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(2.0, 3.0, 0.2)
	ws.shape = wb
	wall.add_child(ws)
	root.add_child(wall)
	wall.global_position = Vector3(-8.0, 1.5, -0.6)
	await _ticks(6)

	# Facing -z, level.
	me.intents.look_yaw = 0.0
	me.intents.look_pitch = 0.0
	await _ticks(2)
	var info := me.melee()
	var hit: DamageSystem.DamageResult = info.get("result")
	_ok("a blow fells a light enemy in front", hit != null and hit.killed and near.health.is_dead())
	_ok("and the gun is down for the start of it", me.is_meleeing())

	me.place(Vector3(8.0, 0.0, 0.0))
	await _ticks(2)
	var whiff := me.melee()
	_ok("a light enemy 3.5 m off is out of reach", whiff.is_empty() and not far.health.is_dead())

	me.place(Vector3(-8.0, 0.0, 0.0))
	await _ticks(2)
	var blocked := me.melee()
	_ok("and a blow never lands through a wall", blocked.is_empty() and not walled.health.is_dead())

	# The motor's cooldown: an intent mid-recovery is dropped.
	me.place(Vector3(0.0, 0.0, 3.0))
	await _ticks(int(ceil(MeleeStrike.RECOVERY * 30.0)) + 1)
	var count := [0]
	me.meleed.connect(func(_i: Dictionary) -> void: count[0] += 1)
	me.intents.melee = true
	await _ticks(1)
	me.intents.melee = true
	await _ticks(1)
	_ok("a second press mid-blow is not a second blow", count[0] == 1, "%d blows" % count[0])
	await _ticks(int(ceil(MeleeStrike.RECOVERY * 30.0)) + 1)
	me.intents.melee = true
	await _ticks(1)
	_ok("once recovered, the next press is", count[0] == 2, "%d blows" % count[0])

	# --- seen ----------------------------------------------------------------------
	var shielded := Pawn.spawn(root, Vector3(20.0, 0.0, 0.0), 1)
	UnitCatalog.apply_health(shielded.health, &"officer", 1)   # medium_shielded
	var armored := Pawn.spawn(root, Vector3(24.0, 0.0, 0.0), 1)
	EnemyProfiles.apply(armored.health, &"medium", 1)
	var alook := DefenceLook.dress(armored.health)
	var slook := shielded.body.get_node_or_null(^"DefenceLook") as DefenceLook
	await process_frame
	await process_frame
	_ok("an arena unit with a shield wears its look", slook != null and slook._shield != null
			and slook._shield.visible)
	var bare := Pawn.spawn(root, Vector3(28.0, 0.0, 0.0), 1)
	EnemyProfiles.apply(bare.health, &"light", 1)
	_ok("a bare enemy gets none", DefenceLook.dress(bare.health) != null
			and DefenceLook.dress(bare.health)._shield == null
			and DefenceLook.dress(bare.health)._armor == null)
	var plate_full := (alook._armor.mesh as CylinderMesh).height
	_melee(armored.health, 1)
	await process_frame
	var plate_worn := (alook._armor.mesh as CylinderMesh).height
	_ok("armor plates shrink as the armor wears", alook._armor.visible
			and plate_worn < plate_full * 0.75, "%.2f -> %.2f" % [plate_full, plate_worn])
	_melee(armored.health, 1)
	_melee(armored.health, 1)
	await process_frame
	_ok("and are gone when it breaks", not alook._armor.visible)
	for i in 3:
		_melee(shielded.health, 1)
	await process_frame
	_ok("a broken shield bursts", slook._shield.visible and slook._burst > 0.0)
	# Real time: headless frames are far shorter than a display's.
	await create_timer(DefenceLook.BURST + 0.15).timeout
	await process_frame
	_ok("and is then gone", not slook._shield.visible)

	print("melee probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)
