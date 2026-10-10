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
##
## The gun's modifiers (GunModifiers, COMBAT_DESIGN 6) are numbers in its stats, read
## here as it fires: power shot and double fire count rounds; Shield Buster rides on
## the packet; Overkill Ricochet and the explosive attachment hit what is near, as
## `side_hit`s. And the first legendary red text: Boilerplate's wind-up, Sermon's
## round back on a kill.

## Per bullet: {"point", "normal", "collider", "structure": bool, "result"} -- or
## {} on a miss. "result" is the DamageSystem.DamageResult for a living target.
signal fired(info: Dictionary)
## A hit the round caused besides its own -- an explosive round's splash, an overkill
## ricochet. The same shape as `fired`'s info, with "side": &"explosive" or &"ricochet".
signal side_hit(info: Dictionary)
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
## The explosive attachment's burst (COMBAT_DESIGN 6.1): radius, and what is left of
## it at the edge.
const SPLASH_RADIUS := 3.0
const SPLASH_EDGE := 0.5
## How far an overkill ricochet looks for its next enemy.
const RICOCHET_RANGE := 12.0
## Boilerplate's wind-up (heat_ramp): fire rate climbs to this over that long held.
const HEAT_RAMP_MAX := 1.6
const HEAT_RAMP_SECONDS := 2.0

var gun: GunInstance
## What scale of weapon this is to a target that cares (DamagePacket.scale); &""
## lets the gun's class say (ordnance is explosive, the rest a person's). A mech's
## arm gun is &"mech", and its rounds are multiplied by `damage_mult` -- a stand-in
## until mech weapons are rolled as classes of their own.
var damage_scale: StringName = &""
var damage_mult := 1.0
var rng: RandomNumberGenerator
var range_m := 400.0
var collision_mask := Layers.GUN_MASK
## (point: Vector3, direction: Vector3, shot: Dictionary) -> void. `shot` is
## StructuralDamage.for_shot of the equipped gun.
var on_structure_hit := Callable()
## Bodies the ray ignores -- the shooter's own.
var exclude: Array[RID] = []
## The holder's team: a splash or a ricochet never lands on its own side (a body whose
## Pawn has this team). -1: no side, it lands on anyone.
var team := -1
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
## Rounds fired since the gun was drawn: power shot and double fire count them.
var _round := 0
## How long the trigger has been held, for the wind-up.
var _held := 0.0


func equip(g: GunInstance) -> void:
	gun = g
	ammo = mag_size()
	_cooldown = 0.0
	_reload_left = 0.0
	_round = 0
	_held = 0.0
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
	_held = _held + delta if _trigger else 0.0
	if _reload_left > 0.0:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_reload_left = 0.0
			ammo = mag_size()
			reloaded.emit()
		return
	_cooldown = maxf(_cooldown - delta, -delta)
	var interval := 1.0 / maxf(_stat(&"fire_rate", 1.0) * _wind_up(), 0.1)
	while _trigger and _cooldown <= 0.0:
		if ammo <= 0:
			reload()
			return
		ammo -= 1
		_cooldown += interval
		_round += 1
		_fire_one(GunModifiers.POWER_SHOT_MULT if is_power_round(_round) else 1.0)
		# Double fire: a free extra round, no ammo (COMBAT_DESIGN 6).
		if is_double_round(_round):
			_fire_one()
		bloom = minf(bloom + bloom_per_shot, BLOOM_MAX_DEG)


## Round `n` (1 = the first since the gun was drawn) is a power shot.
func is_power_round(n: int) -> bool:
	var every := roundi(_stat(&"power_shot_every", 0.0))
	return every > 0 and n % every == 0


## Round `n` fires a free extra round: every Nth, or -- the rarer roll -- by chance, from
## the owner's seeded stream so every peer agrees (COMBAT_DESIGN 6).
func is_double_round(n: int) -> bool:
	var every := roundi(_stat(&"double_fire_every", 0.0))
	if every > 0 and n % every == 0:
		return true
	var chance := _stat(&"double_fire_chance", 0.0)
	return chance > 0.0 and _roll().randf() < chance


## Boilerplate's red text: the fire rate winds up while the trigger is held.
func _wind_up() -> float:
	if gun == null or not gun.active_effects.has("heat_ramp"):
		return 1.0
	return lerpf(1.0, HEAT_RAMP_MAX, clampf(_held / HEAT_RAMP_SECONDS, 0.0, 1.0))


## One round. `mult` scales its damage (a power shot's 2x).
func _fire_one(mult := 1.0) -> void:
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
		info.result = _hit_living(target, point, hit.normal, mult)
	else:
		info.structure = true
		if on_structure_hit.is_valid():
			on_structure_hit.call(point + dir * INTO_SURFACE, dir, _shot)
	var splash := _stat(&"explosive", 0.0)
	if splash > 0.0:
		_explode(point + hit.normal * 0.05, target, _stat(&"damage", 1.0) * damage_mult * mult * splash)
	if gun.is_inside_tree():
		gun.play_shot_effects(point)
	fired.emit(info)


## The living thing the ray struck -- or null for structure. The collider itself
## or, a hurtbox under an entity, its parent: whichever holds a HealthPool as a
## direct child or is one. Never a recursive search up the tree: from a wall, that
## would walk to the scene root and find some enemy's HealthPool under it.
static func _living(collider: Object) -> Node:
	var n := collider as Node
	for _i in 2:
		if n == null:
			return null
		if n is HealthPool or n.get_node_or_null(^"HealthPool") is HealthPool:
			return n
		n = n.get_parent()
	return null


func _hit_living(target: Node, point: Vector3, normal: Vector3,
		mult := 1.0) -> DamageSystem.DamageResult:
	# A crit is a hit on a crit spot -- the head, a weak point -- never a dice roll.
	var crit := _crit_spot(target, point) != &""
	var p := DamagePacket.new(_stat(&"damage", 1.0) * damage_mult * mult, null, self)
	p.scale = damage_scale
	p.hit_position = point
	p.hit_normal = normal
	p.crit = crit
	p.crit_multiplier = _stat(&"crit_mult", 2.0)
	p.element_ratio = _stat(&"element_ratio", 0.0)
	p.element = Elements.get_def(gun.element_id)
	p.rng = rng
	p.shield_mult = 1.0 + _stat(&"shield_buster", 0.0)
	var r := DamageSystem.resolve(p, target)
	if r.killed:
		_on_kill(target, point, p.amount * (p.crit_multiplier if r.was_crit else 1.0) - r.dealt)
	return r


## A kill: Sermon's round back, and an overkill ricochet carrying the excess on.
func _on_kill(target: Node, point: Vector3, excess: float) -> void:
	if gun.active_effects.has("kill_refund"):
		ammo = mini(ammo + 1, mag_size())
	var carry := _stat(&"overkill_ricochet", 0.0)
	if carry <= 0.0 or excess <= 0.0:
		return
	var next := _nearest_near(point, RICOCHET_RANGE, target)
	if next == null:
		return
	_side(next, (next as Node3D).global_position, excess * carry, &"ricochet")


## The explosive attachment: everything near `at` takes up to `amount`, less toward the
## edge, none behind a wall -- never `struck` (the round already hit it) or the
## holder's own side. It wears bricks through StructuralDamage, not here.
func _explode(at: Vector3, struck: Node, amount: float) -> void:
	if gun.is_inside_tree():
		SplashFlash.spawn(gun.get_tree().current_scene, at, SPLASH_RADIUS)
	for n in _living_near(at, SPLASH_RADIUS):
		if n == struck:
			continue
		var pos := (n as Node3D).global_position
		var d := at.distance_to(pos)
		_side(n, pos, amount * lerpf(1.0, SPLASH_EDGE, clampf(d / SPLASH_RADIUS, 0.0, 1.0)),
				&"explosive")


## A hit besides the round's own, through the same pipeline: the gun's element, never
## a crit, Shield Buster still on.
func _side(target: Node, at: Vector3, amount: float, kind: StringName) -> void:
	var p := DamagePacket.new(amount, Elements.get_def(gun.element_id), self)
	p.scale = damage_scale
	p.hit_position = at
	p.element_ratio = _stat(&"element_ratio", 0.0)
	p.rng = rng
	p.shield_mult = 1.0 + _stat(&"shield_buster", 0.0)
	var r := DamageSystem.resolve(p, target)
	side_hit.emit({"point": at, "normal": Vector3.UP, "collider": target, "structure": false,
			"result": r, "side": kind})


## The living things within `radius` of `at` that a burst or a bounce may land on: in
## clear line from `at`, alive, not the holder's side.
func _living_near(at: Vector3, radius: float) -> Array[Node]:
	var out: Array[Node] = []
	if not is_inside_tree():
		return out
	var space := get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis.IDENTITY, at)
	q.collision_mask = Layers.PAWN
	q.exclude = exclude
	for hit in space.intersect_shape(q, 32):
		var n := _living(hit.collider)
		if n == null or out.has(n) or not (n is Node3D):
			continue
		var pool: HealthPool = n as HealthPool if n is HealthPool else n.get_node_or_null(^"HealthPool") as HealthPool
		if pool != null and pool.is_dead():
			continue
		if team >= 0 and _team_of(n) == team:
			continue
		var los := PhysicsRayQueryParameters3D.create(at, (n as Node3D).global_position,
				Layers.HITSCAN_MASK)
		if not space.intersect_ray(los).is_empty():
			continue
		out.append(n)
	return out


func _nearest_near(at: Vector3, radius: float, skip: Node) -> Node:
	var best: Node = null
	var best_d := INF
	for n in _living_near(at, radius):
		var d := at.distance_to((n as Node3D).global_position)
		if n != skip and d < best_d:
			best = n
			best_d = d
	return best


## The team of a living thing: its Pawn's, or -1 for one with none.
static func _team_of(n: Node) -> int:
	var pawn := n.get_node_or_null(^"Pawn") as Pawn
	return pawn.team if pawn != null else -1


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
