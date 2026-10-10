class_name ElementStatus
extends Node3D
## The elements' statuses (Docs/Weapons/COMBAT_DESIGN.md 5), on one thing that was hit.
## Not dice: the element part of every round builds its status, in proportion to what
## it dealt, so co-op peers agree and the player can count on it.
##
##   burn     fire's part that lands on flesh (or vegetation) burns on: BURN_SHARE more
##            of it over BURN_SECONDS, while the flesh is bare. A shield or armor coming
##            up puts it out.
##   corrode  corrosive's part that lands on armor keeps eating it: CORRODE_SHARE more of
##            it over CORRODE_SECONDS, on the armor only.
##   chill    ice's part, on any layer, chills: a slow of up to SLOW_MAX; ice damage worth
##            CHILL_SHARE of the thing's whole health freezes it (no moving, no firing)
##            for FREEZE_SECONDS. A player is slowed, never frozen.
##   shock    a shock arc's slow (GunController's alt-fire): not an element, a slow.
##
## The extra damage the statuses do is plain (the element's multiplier was already in
## the part that built it). A mech takes its hits by its own rules and has none of this.
##
## A child of the thing hit, named ElementStatus, made on its first status and gone
## when the last ends. It ticks itself; nothing in it is random.

const NODE_NAME := &"ElementStatus"
const TICK := 0.5
const BURN_SHARE := 0.6
const BURN_SECONDS := 3.0
const CORRODE_SHARE := 0.5
const CORRODE_SECONDS := 3.0
const CHILL_SHARE := 0.25
## Seconds after the last ice hit before the chill starts to thaw, and how fast it does.
const CHILL_HOLD := 1.0
const CHILL_DECAY := 0.3
const SLOW_MAX := 0.5
const FREEZE_SECONDS := 2.0
## After a thaw, this long before ice can chill it again: no frozen lock.
const THAW_GRACE := 1.5
const SHOCK_SLOW := 0.4
const FLESH: Array[StringName] = [&"health", &"flesh", &"vegetation"]

var pool: HealthPool
var pawn: Pawn
## Damage still to burn or corrode, and over how long.
var burn_left := 0.0
var burn_time := 0.0
var corrode_left := 0.0
var corrode_time := 0.0
## 0..1: 1 is frozen.
var chill := 0.0
var frozen_left := 0.0
var shock_left := 0.0
var _chill_hold := 0.0
var _grace := 0.0
var _tick := 0.0
var _aura: MeshInstance3D
var _aura_mat: StandardMaterial3D


## The statuses on `root`; with `make`, made if it has none.
static func of(root: Node, make := false) -> ElementStatus:
	if root == null:
		return null
	var s := root.get_node_or_null(NodePath(NODE_NAME)) as ElementStatus
	if s != null or not make or not (root is Node3D) or not root.is_inside_tree():
		return s
	s = ElementStatus.new()
	s.name = NODE_NAME
	s.pool = DamageSystem._find_health_pool(root)
	s.pawn = root.get_node_or_null(^"Pawn") as Pawn
	root.add_child(s)
	return s


## A round's element part dealt `dealt` on a layer of type `layer` (DamageSystem): build
## that element's status.
static func build(root: Node, element_id: StringName, layer: StringName, dealt: float) -> void:
	if dealt <= 0.0 or root == null:
		return
	var builds := (element_id == Elements.FIRE and layer in FLESH) \
			or (element_id == Elements.CORROSIVE and layer == &"armor") or element_id == Elements.ICE
	if not builds:
		return
	var s := of(root, true)
	if s == null or s.pool == null:
		return
	match element_id:
		Elements.FIRE:
			s.add_burn(dealt * BURN_SHARE)
		Elements.CORROSIVE:
			s.add_corrode(dealt * CORRODE_SHARE)
		Elements.ICE:
			s.add_chill(dealt / maxf(_max_total(s.pool), 1.0))


## A shock arc's slow on `root`, for `seconds`.
static func shock(root: Node, seconds: float) -> void:
	var s := of(root, true)
	if s != null:
		s.shock_left = maxf(s.shock_left, seconds)
		s._apply()


static func _max_total(p: HealthPool) -> float:
	var t := 0.0
	for c in p.layer_configs:
		t += c.max_value
	return t


func add_burn(amount: float) -> void:
	burn_left += amount
	burn_time = BURN_SECONDS


func add_corrode(amount: float) -> void:
	corrode_left += amount
	corrode_time = CORRODE_SECONDS


## `share`: the ice damage as a share of the thing's whole health.
func add_chill(share: float) -> void:
	if frozen_left > 0.0 or _grace > 0.0:
		return
	chill += share / CHILL_SHARE
	_chill_hold = CHILL_HOLD
	if chill >= 1.0:
		chill = 1.0
		if pawn == null or not pawn.is_player:
			frozen_left = FREEZE_SECONDS
	_apply()


func is_frozen() -> bool:
	return frozen_left > 0.0


func is_burning() -> bool:
	return burn_left > 0.0


func is_corroding() -> bool:
	return corrode_left > 0.0


## What it slows the pawn to: 1 is full speed.
func speed_mult() -> float:
	if frozen_left > 0.0:
		return 0.0
	var slow := SLOW_MAX * clampf(chill, 0.0, 1.0)
	if shock_left > 0.0:
		slow = maxf(slow, SHOCK_SLOW)
	return 1.0 - slow


func _ready() -> void:
	if pool != null and not pool.died.is_connected(_on_died):
		pool.died.connect(_on_died)
	_make_aura()


func _physics_process(delta: float) -> void:
	step(delta)


## Advance every status by `delta`.
func step(delta: float) -> void:
	if pool == null or pool.is_dead():
		_end()
		return
	_tick += delta
	while _tick >= TICK:
		_tick -= TICK
		_tick_dots()
	if frozen_left > 0.0:
		frozen_left -= delta
		if frozen_left <= 0.0:
			frozen_left = 0.0
			chill = 0.0
			_grace = THAW_GRACE
	else:
		_grace = maxf(_grace - delta, 0.0)
		_chill_hold -= delta
		if _chill_hold <= 0.0:
			chill = maxf(chill - CHILL_DECAY * delta, 0.0)
	shock_left = maxf(shock_left - delta, 0.0)
	_apply()
	if burn_left <= 0.0 and corrode_left <= 0.0 and chill <= 0.0 and frozen_left <= 0.0 \
			and shock_left <= 0.0 and _grace <= 0.0:
		_end()


func _tick_dots() -> void:
	if burn_left > 0.0:
		var top := pool.top_layer_type()
		if top in FLESH:
			var d := burn_left * minf(1.0, TICK / maxf(burn_time, TICK))
			pool.apply_to_layer_type(d, top, &"")
			burn_left -= d
		else:
			burn_left = 0.0   # a shield or armor came up: it goes out
		burn_time -= TICK
		if burn_time <= 0.0:
			burn_left = 0.0
	if corrode_left > 0.0 and not pool.is_dead():
		if pool.top_layer_type() == &"armor":
			var d := corrode_left * minf(1.0, TICK / maxf(corrode_time, TICK))
			pool.apply_to_layer_type(d, &"armor", &"")
			corrode_left -= d
		else:
			corrode_left = 0.0   # the armor is gone (or a shield is over it)
		corrode_time -= TICK
		if corrode_time <= 0.0:
			corrode_left = 0.0


## Put the slow and the freeze on the pawn, and the look on the aura.
func _apply() -> void:
	if pawn != null and is_instance_valid(pawn):
		pawn.speed_mult = speed_mult()
		pawn.frozen = frozen_left > 0.0
	_show()


func _on_died() -> void:
	_end()


## All over: the pawn back to itself, and this gone.
func _end() -> void:
	if pawn != null and is_instance_valid(pawn):
		pawn.speed_mult = 1.0
		pawn.frozen = false
	burn_left = 0.0
	corrode_left = 0.0
	chill = 0.0
	frozen_left = 0.0
	shock_left = 0.0
	if not is_queued_for_deletion():
		queue_free()


# --- the look ---------------------------------------------------------------------

func _make_aura() -> void:
	_aura = MeshInstance3D.new()
	var h := pawn.stand_height if pawn != null else 1.6
	var cap := CapsuleMesh.new()
	cap.radius = Pawn.BODY_RADIUS + 0.06 if pawn != null else 0.5
	cap.height = h + 0.08
	cap.radial_segments = 12
	cap.rings = 4
	_aura.mesh = cap
	_aura_mat = StandardMaterial3D.new()
	_aura_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_aura_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_aura_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_aura.material_override = _aura_mat
	_aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_aura)
	_show()


func _show() -> void:
	if _aura_mat == null:
		return
	var c := Color(0, 0, 0, 0)
	var pulse := 0.75 + 0.25 * sin(float(Time.get_ticks_msec()) * 0.012)
	if frozen_left > 0.0:
		c = Elements.INFO[Elements.ICE][1]
		c.a = 0.6
	elif burn_left > 0.0:
		c = Elements.INFO[Elements.FIRE][1]
		c.a = 0.35 * pulse
	elif corrode_left > 0.0:
		c = Elements.INFO[Elements.CORROSIVE][1]
		c.a = 0.3 * pulse
	elif shock_left > 0.0:
		c = Color(0.65, 0.8, 1.0, 0.35 * pulse)
	elif chill > 0.0:
		c = Elements.INFO[Elements.ICE][1]
		c.a = 0.1 + 0.3 * chill
	_aura_mat.albedo_color = c
	_aura.visible = c.a > 0.01
