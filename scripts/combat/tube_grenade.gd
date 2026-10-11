class_name TubeGrenade
extends Node3D
## The underbarrel grenade (Docs/Weapons/COMBAT_DESIGN.md 7.2, GunAltFire.TUBE): lobbed
## down the aim, it bursts on whatever it strikes -- or where its flight runs out -- and
## tells the GunController that fired it (`tube_burst`), which does the damage.

const SPEED := 32.0
const GRAVITY := 9.8
const FLIGHT := 3.0

var gun: GunController
var velocity := Vector3.ZERO
var mask := Layers.GUN_MASK
var exclude: Array[RID] = []
var _left := FLIGHT


static func launch(p_gun: GunController, parent: Node, from: Vector3, dir: Vector3) -> TubeGrenade:
	var g := TubeGrenade.new()
	g.name = "TubeGrenade"
	g.gun = p_gun
	g.mask = p_gun.collision_mask
	g.exclude = p_gun.exclude
	g.velocity = dir.normalized() * SPEED
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.06
	s.height = 0.12
	s.radial_segments = 8
	s.rings = 4
	m.mesh = s
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.35, 0.25)
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.add_child(m)
	parent.add_child(g)
	g.global_position = from
	return g


func _physics_process(delta: float) -> void:
	step(delta)


## Fly `delta` seconds, a ray from here to where it will be.
func step(delta: float) -> void:
	_left -= delta
	velocity += Vector3.DOWN * GRAVITY * delta
	var from := global_position
	var to := from + velocity * delta
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() and _left > 0.0:
		global_position = to
		return
	var at: Vector3 = to if hit.is_empty() else hit.position
	var normal: Vector3 = Vector3.UP if hit.is_empty() else hit.normal
	if gun != null and is_instance_valid(gun):
		gun.tube_burst(at, normal, null if hit.is_empty() else hit.collider)
	queue_free()
