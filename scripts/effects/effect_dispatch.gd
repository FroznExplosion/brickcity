class_name EffectDispatch
extends RefCounted
## Runs on-hit effect behaviors for a shot (MANUFACTURER_SPEC §2/§6). Given the gun's
## active effect ids + active merges + a hit context, it spawns the secondary damage
## (splash, ricochet) through the SAME DamageSystem, so every effect respects layers,
## the matrix, bypass, and vital-death. Handlers keyed by effect id; adding one is a
## new branch, never a change to the caller.
##
## Shot-phase effects (power_shot, extra_round, burst) are applied at fire time by the
## weapon, not here.

const EXPLOSIVE_RADIUS := 4.0
const EXPLOSIVE_FRAC := 0.5           ## splash damage as a fraction of the hit's base
const RICOCHET_FRAC := 0.6            ## ricochet damage as a fraction of base
const RICOCHET_DOT_CHANCE_MULT := 1.5 ## merge boosts DoT chance on the ricochet round
const RICOCHET_RANGE := 18.0         ## bounce picks a RANDOM enemy within this range


static func on_hit(ctx: EffectContext, effects: PackedStringArray, merges: Array) -> void:
	var has: Dictionary = {}
	for e in effects:
		has[StringName(e)] = true
	var merged: Dictionary = {}
	for m: MergeRule in merges:
		merged[m.id] = true

	# Explosive splash. Boomer mod supercharge = bigger radius + damage. A Boomer mod's
	# universal splash also splashes on EVERY hit even without the explosive effect.
	if has.has(&"explosive") or ctx.universal_splash > 0.0:
		var sc_ex := ctx.supercharges.has(&"explosive")
		var radius := EXPLOSIVE_RADIUS * (1.5 if sc_ex else 1.0)
		var frac := EXPLOSIVE_FRAC if has.has(&"explosive") else ctx.universal_splash
		if sc_ex:
			frac *= 1.5
		frac *= float(ctx.effect_mults.get(&"explosive", 1.0))   # brand-match magnitude
		_explode_frac(ctx, ctx.hit_point, [ctx.target_root], radius, frac)

	# Ricochet: on a crit, OR always if a Cowboy mod supercharges it (boosted then).
	# The bounce is KINETIC unless the ricochet + element merge is active.
	if has.has(&"ricochet") and (ctx.crit or ctx.supercharges.has(&"ricochet")):
		var t := _random_enemy_near(ctx, ctx.hit_point, [ctx.target_root], RICOCHET_RANGE)
		if t != null:
			var carry := merged.has(&"ricochet_dot_up")
			var elem: Element = ctx.element if carry else null
			var ratio: float = ctx.element_ratio if carry else 0.0
			var chance_mult := RICOCHET_DOT_CHANCE_MULT if carry else 1.0
			var amount := ctx.base_damage * RICOCHET_FRAC
			if ctx.supercharges.has(&"ricochet"):
				amount *= 1.6
			amount *= float(ctx.effect_mults.get(&"ricochet", 1.0))   # brand-match magnitude
			var tp := _pos(t) + Vector3(0, 0.9, 0)
			if ctx.vfx.is_valid():
				var rc: Color = elem.color if elem != null else Color(1.0, 0.9, 0.5)
				ctx.vfx.call(ctx.hit_point, tp, rc)   # ricochet trail
			_hit(ctx, t, amount, elem, ratio, chance_mult)
			# Merge (ricochet + explosive): the ricochet target ALSO explodes.
			if merged.has(&"ricochet_double_blast"):
				_explode(ctx, tp, [t])

	# Overkill + ricochet: the killing bullet bounces onto a random enemy carrying the
	# leftover (overkill) damage.
	if ctx.overkill_ricochet > 0.0:
		var ot := _random_enemy_near(ctx, ctx.hit_point, [ctx.target_root], RICOCHET_RANGE)
		if ot != null:
			var otp := _pos(ot) + Vector3(0, 0.9, 0)
			if ctx.vfx.is_valid():
				ctx.vfx.call(ctx.hit_point, otp, Color(1.0, 0.45, 0.1))
			_hit(ctx, ot, ctx.overkill_ricochet, ctx.element, ctx.element_ratio, 1.0)

	# Cluster: a KILLING blow detonates a small on-kill blast (carries the element,
	# so cluster + element = elemental bomblets). Splashes the dying target's neighbours.
	if has.has(&"cluster") and _is_dead(ctx.target_root):
		_explode(ctx, ctx.hit_point, [])


# ------------------------------------------------------------------- handlers

static func _explode(ctx: EffectContext, center: Vector3, exclude: Array) -> void:
	_explode_frac(ctx, center, exclude, EXPLOSIVE_RADIUS, EXPLOSIVE_FRAC)


static func _explode_frac(ctx: EffectContext, center: Vector3, exclude: Array,
		radius: float, frac: float) -> void:
	for e in _enemies(ctx):
		if e in exclude:
			continue
		if _pos(e).distance_to(center) <= radius:
			_hit(ctx, e, ctx.base_damage * frac, ctx.element, ctx.element_ratio, 1.0)


## Random enemy within `radius` of `from` (so ricochets vary instead of always the
## nearest). Falls back to the nearest if none are in range.
static func _random_enemy_near(ctx: EffectContext, from: Vector3, exclude: Array, radius: float) -> Node:
	var pool: Array = []
	for e in _enemies(ctx):
		if e in exclude:
			continue
		if _pos(e).distance_to(from) <= radius:
			pool.append(e)
	if pool.is_empty():
		return _nearest_enemy(ctx, from, exclude)
	var roll: RandomNumberGenerator = ctx.rng if ctx.rng != null else DamageSystem.rng
	return pool[roll.randi() % pool.size()]


static func _nearest_enemy(ctx: EffectContext, from: Vector3, exclude: Array) -> Node:
	var best: Node = null
	var best_d := INF
	for e in _enemies(ctx):
		if e in exclude:
			continue
		var d := _pos(e).distance_to(from)
		if d < best_d:
			best_d = d
			best = e
	return best


## Deal secondary damage through the real DamageSystem + flash the target. `element`
## null = kinetic-only bounce/splash; `chance_mult` scales the status proc chance.
static func _hit(ctx: EffectContext, target: Node, amount: float,
		element: Element, ratio: float, chance_mult: float) -> void:
	var p := DamagePacket.new(amount, element, ctx.shooter)
	p.element_ratio = ratio
	p.element_chance = ctx.element_chance * chance_mult
	p.crit = false
	p.crit_multiplier = ctx.crit_mult
	p.rng = ctx.rng
	DamageSystem.resolve(p, target)
	if target.has_method(&"pulse"):
		var col: Color = element.color if element != null else Color(1, 1, 1)
		target.call(&"pulse", col, 0.9)


static func _is_dead(target: Node) -> bool:
	if target == null:
		return false
	var hp := target.find_child("HealthPool", true, false) as HealthPool
	return hp != null and hp.is_dead()


static func _enemies(ctx: EffectContext) -> Array:
	if ctx.shooter == null or not ctx.shooter.is_inside_tree():
		return []
	return ctx.shooter.get_tree().get_nodes_in_group(&"enemy")


static func _pos(n: Node) -> Vector3:
	return (n as Node3D).global_position if n is Node3D else Vector3.ZERO
