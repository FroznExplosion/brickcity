class_name GunController
extends Node3D
## Fires a generated gun: the trigger, the rate, the magazine and the reload, and
## where each bullet goes. Owner-agnostic on purpose -- the player's hands, a mech's
## arm and an AI soldier all hold one of these (Docs/AI.md: friendly AI = enemy AI).
##
## What a bullet hits decides which rules judge it:
##   * something with a HealthPool -> DamageSystem, the elemental pipeline;
##   * anything else is structure -> `on_structure_hit`, which the scene routes to
##     the WorldAuthority as a CHIP or a BLAST (StructuralDamage says which). The
##     controller never touches the grid itself, so a client's gun asks and the
##     host's gun commits, with no difference here.
##
## Every roll -- spread -- comes from `rng`, which the owner sets from the host's
## combat state. Never the global RNG (Multiplayer.md, D9). A crit is not a roll: it is
## where the round landed (CritSpots, Docs/Weapons/COMBAT_DESIGN.md 4.3).

## Per bullet: {"point", "normal", "collider", "structure": bool, "result"} -- or
## {} on a miss. "result" is the DamageSystem.DamageResult for a living target.
signal fired(info: Dictionary)
signal reload_started(seconds: float)
signal reloaded

## Widest cone, in degrees, at accuracy 0. A 0.9-accuracy pistol spreads a tenth.
const MAX_SPREAD_DEG := 8.0
## How far into what it struck a structural hit is placed: inside the struck
## cell, never on the boundary between two.
const INTO_SURFACE := 0.02
## Bloom: how wide sustained fire may push the cone past the gun's own, and how
## fast it closes again once the trigger rests.
const BLOOM_MAX_DEG := 4.0
const BLOOM_RECOVER := 7.0

var gun: GunInstance
var rng: RandomNumberGenerator
var range_m := 400.0
var collision_mask := Layers.GUN_MASK
## (point: Vector3, direction: Vector3, shot: Dictionary) -> void. `shot` is
## StructuralDamage.for_shot of the equipped gun.
var on_structure_hit := Callable()
## Bodies the ray ignores -- the shooter's own.
var exclude: Array[RID] = []
## Where bullets come from and which way: the camera for a player, the arm for a mech.
var aim: Node3D
## The holder's say on the cone, multiplied in: narrower aimed down the sights,
## wider on the move or in the air (PlayerView sets it). 1 for a soldier.
var spread_mult := 1.0
## Degrees each round adds to the cone while firing (0: no bloom, a soldier's).
var bloom_per_shot := 0.0
var bloom := 0.0

var ammo := 0
var _cooldown := 0.0
var _reload_left := 0.0
var _reload_total := 1.0
var _trigger := false
var _shot := {}


func equip(g: GunInstance) -> void:
	gun = g
	ammo = mag_size()
	_cooldown = 0.0
	_reload_left = 0.0
	_shot = StructuralDamage.for_shot(g.weapon_class, g.active_effects) if g != null else {}


func mag_size() -> int:
	return maxi(1, int(_stat(&"mag_size", 1.0)))


func is_reloading() -> bool:
	return _reload_left > 0.0


func set_trigger(down: bool) -> void:
	_trigger = down


func reload() -> void:
	if gun == null or is_reloading() or ammo >= mag_size():
		return
	_reload_left = maxf(_stat(&"reload_time", 1.0), 0.05)
	_reload_total = _reload_left
	reload_started.emit(_reload_left)


## 0 as a reload starts, 1 as it ends; 1 when not reloading.
func reload_progress() -> float:
	return 1.0 - _reload_left / _reload_total if is_reloading() else 1.0


## The cone a round leaves in right now: its half-angle in degrees, from the gun's
## own accuracy, bloom, and the holder's multiplier.
func current_spread_deg() -> float:
	var acc := clampf(_stat(&"accuracy", 1.0), 0.0, 1.0)
	return (MAX_SPREAD_DEG * (1.0 - acc) + bloom) * spread_mult


func _physics_process(delta: float) -> void:
	step(delta)


## Advance the gun by `delta`. Fires as many rounds as the rate allows while the
## trigger is held -- more than one in a long frame, so a slow frame does not
## slow the gun.
func step(delta: float) -> void:
	if gun == null:
		return
	bloom = maxf(bloom - BLOOM_RECOVER * delta, 0.0)
	if _reload_left > 0.0:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_reload_left = 0.0
			ammo = mag_size()
			reloaded.emit()
		return
	_cooldown = maxf(_cooldown - delta, -delta)
	var interval := 1.0 / maxf(_stat(&"fire_rate", 1.0), 0.1)
	while _trigger and _cooldown <= 0.0:
		if ammo <= 0:
			reload()
			return
		ammo -= 1
		_cooldown += interval
		_fire_one()
		bloom = minf(bloom + bloom_per_shot, BLOOM_MAX_DEG)


func _fire_one() -> void:
	if aim == null or not aim.is_inside_tree():
		return
	var aim_basis := aim.global_transform.basis
	var dir := _spread(-aim_basis.z, aim_basis)
	var from := aim.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * range_m, collision_mask, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		fired.emit({})
		if gun.is_inside_tree():
			gun.play_shot_effects(from + dir * range_m)
		return
	var collider: Object = hit.collider
	var point: Vector3 = hit.position
	var info := {"point": point, "normal": hit.normal, "collider": collider,
			"structure": false, "result": null}
	var target := _living(collider)
	if target != null:
		info.result = _hit_living(target, point, hit.normal)
	else:
		info.structure = true
		if on_structure_hit.is_valid():
			on_structure_hit.call(point + dir * INTO_SURFACE, dir, _shot)
	if gun.is_inside_tree():
		gun.play_shot_effects(point)
	fired.emit(info)


## The living thing the ray struck -- or null for structure. The collider itself
## or, a hurtbox under an entity, its parent: whichever holds a HealthPool as a
## direct child or is one. Never a recursive search up the tree: from a wall, that
## would walk to the scene root and find some enemy's HealthPool under it.
func _living(collider: Object) -> Node:
	var n := collider as Node
	for _i in 2:
		if n == null:
			return null
		if n is HealthPool or n.get_node_or_null(^"HealthPool") is HealthPool:
			return n
		n = n.get_parent()
	return null


func _hit_living(target: Node, point: Vector3, normal: Vector3) -> DamageSystem.DamageResult:
	# A crit is a hit on a crit spot -- the head, a weak point -- never a dice roll.
	var crit := _crit_spot(target, point) != &""
	var p := DamagePacket.new(_stat(&"damage", 1.0), null, self)
	p.hit_position = point
	p.hit_normal = normal
	p.crit = crit
	p.crit_multiplier = _stat(&"crit_mult", 2.0)
	p.element_ratio = _stat(&"element_ratio", 0.0)
	p.rng = rng
	return DamageSystem.resolve(p, target)


## The crit spot `point` is in on `target` (its CritSpots), or &"" for none.
static func _crit_spot(target: Node, point: Vector3) -> StringName:
	var spots := target.get_node_or_null(^"CritSpots") as CritSpots
	return spots.spot_at(point) if spots != null else &""


func _spread(forward: Vector3, aim_basis: Basis) -> Vector3:
	var cone := deg_to_rad(current_spread_deg())
	if cone <= 0.0:
		return forward
	var r := _roll()
	# Uniform over the cone's disc, not its angle, so shots do not bunch in the middle.
	var radius := sqrt(r.randf()) * tan(cone)
	var theta := r.randf() * TAU
	return (forward + aim_basis.x * cos(theta) * radius + aim_basis.y * sin(theta) * radius).normalized()


func _roll() -> RandomNumberGenerator:
	return rng if rng != null else DamageSystem.rng


func _stat(key: StringName, fallback: float) -> float:
	if gun == null:
		return fallback
	return float(gun.stats.get(key, fallback))
