## freeze_visual.gd  (TWO-MESH LIMB VERSION)
## Handles the freeze look AND the frozen-death shatter for a low-poly enemy built
## as: a live single mesh for gameplay + a separate multi-mesh (per-limb) version
## that is hidden until freeze.
##
## FREEZE SEQUENCE:
##   1. Snapshot the live skeleton's current bone GLOBAL poses (the mid-action pose).
##   2. Hide the live mesh, show the multi-mesh, and bake the snapshot onto it so it
##      holds the exact pose it was in when frozen (then it stops animating = rigid).
##   3. For each limb MeshInstance3D, duplicate it, apply the icy transparent
##      material, grow the duplicate slightly, and parent the shell TO that limb so
##      the shell rides on top of it.
##
## SHATTER (frozen death):
##   For each limb, reparent (limb + its ice shell together) under a fresh
##   RigidBody3D at the limb's current GLOBAL transform, then apply outward impulse.
##   Limb and shell fall together as one frosted piece. (Per your spec choice.)
##
## Enemy is expected to expose (all optional, checked via has_method / @export paths):
##   - a Skeleton3D (live_skeleton_path)
##   - the live MeshInstance3D(s) root to hide (live_mesh_root_path)
##   - the multi-mesh limb root to show (multi_mesh_root_path); its MeshInstance3D
##     children are treated as the limbs.
class_name FreezeVisual
extends Node3D

@export var live_skeleton_path: NodePath
@export var live_mesh_root_path: NodePath
@export var multi_mesh_root_path: NodePath

## Icy transparent material applied to the duplicated shells.
@export var ice_material: Material

## Shell growth as a scale factor on each limb shell (1.06 = +6%).
@export var shell_grow: float = 1.06

## Outward impulse strength when limbs break apart on death.
@export var break_force: float = 4.0

## Upward pop added to the break impulse.
@export var break_upward_bias: float = 2.0

## Inherited enemy velocity factor (frozen mid-air death sprays with momentum).
@export var inherit_velocity_factor: float = 0.5

## Seconds before broken limb pieces despawn.
@export var piece_lifetime: float = 5.0

## Physics layers for the broken limb rigid bodies.
@export_flags_3d_physics var piece_collision_layer: int = 1
@export_flags_3d_physics var piece_collision_mask: int = 1

var _skeleton: Skeleton3D
var _live_root: Node3D
var _multi_root: Node3D
var _limbs: Array[MeshInstance3D] = []
var _shells: Array[MeshInstance3D] = []
var _active: bool = false
var _shattered: bool = false


func _resolve_nodes() -> void:
	_skeleton = get_node_or_null(live_skeleton_path) as Skeleton3D
	_live_root = get_node_or_null(live_mesh_root_path) as Node3D
	_multi_root = get_node_or_null(multi_mesh_root_path) as Node3D


## Begin the freeze. Snapshots pose, swaps meshes, builds ice shells.
func freeze() -> void:
	if _active:
		return
	_active = true
	_resolve_nodes()

	# 1. Show the multi-mesh, hide the live mesh.
	if _live_root != null:
		_live_root.visible = false
	if _multi_root == null:
		# No multi-mesh assigned; we can't do the limb freeze. Bail gracefully.
		_active = false
		if _live_root != null:
			_live_root.visible = true
		return
	_multi_root.visible = true

	# 2. Bake the live skeleton's current global pose onto the multi-mesh limbs.
	#    This is what "freeze in the current animation pose" means: we copy the
	#    pose at this instant, then never animate again (rigid).
	_collect_limbs()
	_bake_pose_onto_limbs()

	# 3. Build an ice shell on each limb.
	_build_shells()


func _collect_limbs() -> void:
	_limbs.clear()
	for child in _multi_root.get_children():
		if child is MeshInstance3D:
			_limbs.append(child)
		# Also catch limbs nested one level deep (common in exported rigs).
		for sub in child.get_children():
			if sub is MeshInstance3D:
				_limbs.append(sub)


## Copy current global bone transforms so the multi-mesh holds the live pose.
## If the multi-mesh shares the same skeleton/bone names, this aligns it exactly.
## NOTE: if your multi-mesh is rigged to its OWN skeleton, point the limb's
## transform-following at the matching bone here. Marked clearly for wiring.
func _bake_pose_onto_limbs() -> void:
	if _skeleton == null:
		return
	# Simplest robust path: place the whole multi-mesh root at the skeleton's
	# global transform so a shared-rig multi-mesh lines up. Per-limb bone matching
	# is only needed if the multi-mesh is NOT skinned to the same skeleton.
	_multi_root.global_transform = _skeleton.global_transform
	# ADAPTER (only if multi-mesh limbs are NOT auto-posed by a shared skeleton):
	# for limb in _limbs:
	#     var bone_idx := _skeleton.find_bone(limb.name)
	#     if bone_idx != -1:
	#         limb.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(bone_idx)


func _build_shells() -> void:
	_shells.clear()
	for limb in _limbs:
		if limb.mesh == null:
			continue
		var shell := MeshInstance3D.new()
		shell.mesh = limb.mesh  # shared ref; we only scale the instance, never edit the mesh
		if ice_material != null:
			shell.material_override = ice_material
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Parent to the limb so the shell rides on it; grow slightly so it encases.
		limb.add_child(shell)
		shell.transform = Transform3D.IDENTITY
		shell.scale = Vector3.ONE * shell_grow
		_shells.append(shell)


## Remove shells and restore the live mesh (thaw without dying).
func thaw() -> void:
	if not _active or _shattered:
		return
	_active = false
	for shell in _shells:
		if is_instance_valid(shell):
			shell.queue_free()
	_shells.clear()
	if _multi_root != null:
		_multi_root.visible = false
	if _live_root != null:
		_live_root.visible = true


## Frozen death: break each limb (with its ice shell) into a falling rigid body.
func shatter(enemy_velocity: Vector3 = Vector3.ZERO) -> void:
	if _shattered:
		return
	if not _active:
		# Died frozen but freeze() never ran (edge case) — nothing to break.
		return
	_shattered = true

	var center: Vector3 = global_position
	if _multi_root != null:
		center = _multi_root.global_position

	for limb in _limbs:
		if not is_instance_valid(limb):
			continue
		var limb_xform: Transform3D = limb.global_transform

		var body := RigidBody3D.new()
		body.collision_layer = piece_collision_layer
		body.collision_mask = piece_collision_mask

		# Reparent the limb (and its shell child) under the body, preserving world pose.
		var parent := limb.get_parent()
		if parent != null:
			parent.remove_child(limb)
		body.add_child(limb)

		# Give the body a collision shape from the limb's AABB (cheap approximation).
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var aabb: AABB = limb.get_aabb()
		box.size = aabb.size * limb.scale
		col.shape = box
		col.position = aabb.position + aabb.size * 0.5
		body.add_child(col)

		# Add to scene and restore the limb's exact world transform (NOT rest pose —
		# this is the fix for limbs teleporting to T-pose before flying off).
		add_child(body)
		body.global_transform = limb_xform
		limb.transform = Transform3D.IDENTITY  # limb now local to body

		# Impulse: outward from body center + upward pop + inherited momentum.
		var outward: Vector3 = body.global_position - center
		if outward.length() < 0.01:
			outward = Vector3(randf() - 0.5, 0.5, randf() - 0.5)
		var impulse: Vector3 = outward.normalized() * break_force
		impulse += Vector3.UP * break_upward_bias
		impulse += enemy_velocity * inherit_velocity_factor
		body.apply_central_impulse(impulse)
		body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))

		# Staggered despawn.
		var life: float = piece_lifetime + randf_range(-0.5, 0.5)
		var timer := get_tree().create_timer(life)
		timer.timeout.connect(func(): if is_instance_valid(body): body.queue_free())

	_limbs.clear()
	_shells.clear()


func is_frozen_visual_active() -> bool:
	return _active
