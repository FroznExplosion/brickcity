# elemental_target.gd — add one to every enemy scene, name it "ElementalTarget".
#
# DROP-IN CONTRACT: this component is the ONLY per-enemy setup the elemental
# system needs. Assign the exports and every element just works — no custom
# effect authoring per enemy, because:
#   * the overlay shader uses world-space triplanar noise (no UV dependence),
#   * the popsicle shell is normal-inflation (works on any mesh shape),
#   * shatter position/size/shard-count all derive from the mesh AABB.
# Multi-part enemies (armor, weapon, head meshes) go in `extra_meshes` and get
# the same overlay treatment automatically.
#
# SHARED-MATERIAL RULE: never call material.set_shader_parameter() from here —
# that would change EVERY enemy. Always set_instance_shader_parameter().
class_name ElementalTarget
extends Node

signal died
## A frozen enemy hit the ground this hard. Not damage: whoever owns the enemy's
## HealthPool turns it into a DamagePacket, through DamageSystem, on the host.
signal frozen_landing(damage: float)

@export var body_mesh: MeshInstance3D          ## main character mesh
@export var extra_meshes: Array[MeshInstance3D] = []   ## armor/weapon/etc, optional
@export var skeleton_mesh: MeshInstance3D      ## inner skeleton, hidden by default (acid)
@export var animation_tree: AnimationTree      ## paused while frozen, optional
@export var chest_socket: Marker3D             ## fire/shock emitter anchor
@export var ground_socket: Marker3D            ## puddle anchor + floor reference (feet)

@export_group("Frozen Fall")
@export var frozen_fall_gravity := 22.0        ## ice blocks drop harder than ragdolls
@export var fall_impact_min_speed := 4.0       ## m/s of impact below this: free landing
@export var fall_damage_per_ms := 8.0          ## bonus damage per m/s over threshold

var is_dead := false
var is_frozen := false
var active_elements := 0                       ## bitmask of Element enum
var fx_handles: Dictionary = {}                ## element scripts stash pooled fx here

var _all_meshes: Array[MeshInstance3D] = []
var _overlay_on := false
var _saved_base_material: Material = null
var _frozen_airborne := false
var _frozen_vel := Vector3.ZERO

func _ready() -> void:
	set_physics_process(false)                 # only ticks while frozen
	if skeleton_mesh:
		skeleton_mesh.visible = false
	_all_meshes.append(body_mesh)
	_all_meshes.append_array(extra_meshes)
	for m in _all_meshes:
		m.set_instance_shader_parameter("coat_amount", 0.0)
		m.set_instance_shader_parameter("freeze_amount", 0.0)
		m.set_instance_shader_parameter("burn_amount", 0.0)
		m.set_instance_shader_parameter("pulse_speed", 0.0)

# --------------------------------------------------------------- overlay
## Enable the shared overlay on every visual part and configure one element.
func set_overlay(color: Color, coat: float, freeze: float, burn: float,
		pulse := 0.0) -> void:
	for m in _all_meshes:
		if not _overlay_on:
			m.material_overlay = ElementalManager.overlay_material
		m.set_instance_shader_parameter("element_color", color)
		m.set_instance_shader_parameter("coat_amount", coat)
		m.set_instance_shader_parameter("freeze_amount", freeze)
		m.set_instance_shader_parameter("burn_amount", burn)
		m.set_instance_shader_parameter("pulse_speed", pulse)
	_overlay_on = true

## Set one overlay uniform across all parts (element scripts use this).
func set_overlay_param(param: StringName, value: Variant) -> void:
	for m in _all_meshes:
		m.set_instance_shader_parameter(param, value)

## Fully remove the overlay pass — this is the perf win, not fading to 0.
func clear_overlay_if_unused() -> void:
	var overlay_users := (1 << ElementalManager.Element.ICE) \
		| (1 << ElementalManager.Element.FIRE) \
		| (1 << ElementalManager.Element.CORROSIVE) \
		| (1 << ElementalManager.Element.SLAG) \
		| (1 << ElementalManager.Element.RADIATION)
	if active_elements & overlay_users == 0 and _overlay_on:
		for m in _all_meshes:
			m.material_overlay = null
		_overlay_on = false

# --------------------------------------------------------------- acid swap
## Swap the BODY's base material to the shared dissolve shader. Extra meshes
## (armor etc.) keep their material — armor doesn't melt; hide it at full
## dissolve from AcidEffect if you want it to drop off.
func begin_dissolve() -> void:
	if _saved_base_material != null:
		return
	_saved_base_material = body_mesh.get_surface_override_material(0)
	if _saved_base_material == null:
		_saved_base_material = body_mesh.mesh.surface_get_material(0)
	body_mesh.set_surface_override_material(0, ElementalManager.dissolve_material)
	body_mesh.set_instance_shader_parameter("dissolve_amount", 0.0)
	if skeleton_mesh:
		skeleton_mesh.visible = true

func set_dissolve(amount: float) -> void:
	body_mesh.set_instance_shader_parameter("dissolve_amount", amount)

func end_dissolve() -> void:
	if _saved_base_material == null:
		return
	body_mesh.set_surface_override_material(0, _saved_base_material)
	_saved_base_material = null
	if skeleton_mesh and not is_dead:
		skeleton_mesh.visible = false

# --------------------------------------------------------------- freeze
func set_frozen(frozen: bool) -> void:
	is_frozen = frozen
	if animation_tree:
		animation_tree.active = not frozen
	var enemy := get_parent()
	if enemy.has_method("set_movement_enabled"):
		enemy.set_movement_enabled(not frozen)
	# Airborne popsicle: we take over gravity so a mid-air freeze drops them
	# like the ice block they now are. CharacterBody3D enemies only —
	# RigidBody enemies already fall on their own once their AI stops.
	if frozen and enemy is CharacterBody3D:
		_frozen_vel = enemy.velocity
		_frozen_vel.x *= 0.35                  # encasement kills most momentum
		_frozen_vel.z *= 0.35
		_frozen_airborne = not enemy.is_on_floor()
		set_physics_process(true)
	else:
		set_physics_process(false)

## Frozen-fall physics: dead-simple ballistic drop + landing impact damage.
func _physics_process(delta: float) -> void:
	var enemy := get_parent() as CharacterBody3D
	if enemy == null or not is_frozen or is_dead:
		set_physics_process(false)
		return
	_frozen_vel.y -= frozen_fall_gravity * delta
	var fall_speed := -_frozen_vel.y           # downward speed BEFORE the slide
	enemy.velocity = _frozen_vel
	enemy.move_and_slide()
	_frozen_vel = enemy.velocity
	if enemy.is_on_floor():
		if _frozen_airborne and fall_speed > fall_impact_min_speed:
			var dmg := (fall_speed - fall_impact_min_speed) * fall_damage_per_ms
			VfxPool.burst("shatter_puff", ground_socket.global_position)
			# Not dealt here: the owner routes it through DamageSystem, and if
			# it kills, calls on_killed() and the popsicle shatters.
			frozen_landing.emit(dmg)
		_frozen_airborne = false
	else:
		_frozen_airborne = true                # walked/knocked off a ledge

# --------------------------------------------------------------- death
## The enemy's HealthPool reached zero: play the death look. HealthPool is the
## only health there is -- BoomerBorder's copy of this kept its own, which nothing
## in the real damage pipeline touched.
func on_killed() -> void:
	if is_dead:
		return
	is_dead = true
	if is_frozen:
		# Popsicle shatter kill: hide all parts, burst shards, skip ragdoll.
		# Shard count auto-scales with enemy volume (rat -> badass).
		var aabb := body_mesh.get_aabb()
		var vol: float = aabb.size.x * aabb.size.y * aabb.size.z
		var count := clampi(24 + int(vol * 14.0), 24, 80)
		VfxPool.spawn_shatter(
			body_mesh.global_transform * aabb.get_center(),
			aabb.size, count, ground_socket.global_position.y)
		body_mesh.visible = false
		for m in extra_meshes:
			m.visible = false
		if skeleton_mesh:
			skeleton_mesh.visible = false
	died.emit()
