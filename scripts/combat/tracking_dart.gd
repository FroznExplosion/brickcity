class_name TrackingDart
extends Node3D
## The tracking dart (Docs/Weapons/COMBAT_DESIGN.md 7.2): a slow, heavy projectile the
## player leads onto a moving target. It flies, sticks where it strikes, and tells the
## GunController that fired it (`dart_struck`), which does the damage and holds the mark.
## Stuck in a living thing it rides along with it; in a wall it stays a moment and goes.

const SPEED := 40.0
## A little drop, so a long dart is lobbed: still mostly a straight line.
const GRAVITY := 3.0
## Flight time before it is given up as a miss.
const FLIGHT := 3.0
## How long a dart stuck in a wall (or one whose mark has ended) stays to be seen.
const LINGER := 1.0

var gun: GunController
var velocity := Vector3.ZERO
var mask := Layers.GUN_MASK
var exclude: Array[RID] = []
var stuck := false
var _left := FLIGHT


static func launch(p_gun: GunController, parent: Node, from: Vector3, dir: Vector3) -> TrackingDart:
	var d := TrackingDart.new()
	d.name = "TrackingDart"
	d.gun = p_gun
	d.mask = p_gun.collision_mask
	d.exclude = p_gun.exclude
	d.velocity = dir.normalized() * SPEED
	var m := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.0
	cyl.bottom_radius = 0.03
	cyl.height = 0.28
	cyl.radial_segments = 6
	cyl.rings = 1
	m.mesh = cyl
	# The cylinder stands on Y; the dart flies down its -Z.
	m.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 1.0, 0.85)
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	d.add_child(m)
	parent.add_child(d)
	d.global_position = from
	d._face()
	return d


func _physics_process(delta: float) -> void:
	step(delta)


## Fly `delta` seconds: a ray from here to where it will be, so a fast frame does not
## step it through a thin target.
func step(delta: float) -> void:
	_left -= delta
	if stuck:
		if _left <= 0.0 and not _is_mark():
			queue_free()
		return
	if _left <= 0.0:
		if gun != null and is_instance_valid(gun):
			gun.dart_missed(self)
		queue_free()
		return
	velocity += Vector3.DOWN * GRAVITY * delta
	var from := global_position
	var to := from + velocity * delta
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		global_position = to
		_face()
		return
	stuck = true
	_left = LINGER
	global_position = hit.position
	var host := hit.collider as Node
	if host != null and GunController._living(host) != null:
		# Ride along with what it struck.
		reparent(GunController._living(host), true)
	if gun != null and is_instance_valid(gun):
		gun.dart_struck(self, hit)


func _is_mark() -> bool:
	return gun != null and is_instance_valid(gun) and gun.mark_dart() == self


func _face() -> void:
	if velocity.length_squared() > 0.0001:
		look_at(global_position + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.99 else Vector3.RIGHT)
