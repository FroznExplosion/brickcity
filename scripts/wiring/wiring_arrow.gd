class_name WiringArrow
extends Node3D
## An ARROW in flight, shot by a wired shooter (Docs/MineWiring.md 19).
##
## It flies straight with gravity (SPEED, a little lift so it keeps its line
## over a corridor), a ray each physics step against what guns hit. A body with
## health takes DAMAGE through the damage system (DamageSystem.resolve, as a
## round does) and the arrow is gone; the ground or a wall stops it, and it
## lies there as an arrow to pick up again (DroppedItems). Arrows break no
## bricks. Gone after LIFE seconds in the air.

const SPEED := 30.0
## Upward share of the launch (about 2.3 degrees): flat for ~10 m.
const LIFT := 0.04
const LIFE := 4.0
## Melees (CombatScale) an arrow does at level 1: 21 at 60, two hit a zombie down.
const DAMAGE_MELEES := 0.35
const LENGTH := 0.42

var vel := Vector3.ZERO
var exclude: Array[RID] = []
var drops: DroppedItems = null
## The node whose local frame the drops live in (the mine world).
var frame: Node3D = null
var age := 0.0
## What it hit: "body", "ground" or "" (gates read it).
var struck := ""
var dealt := 0.0

static var shot_count := 0
static var hits_on_bodies := 0


## Shoots one from `from` along `dir` (global). The arrow is a child of `parent`.
static func shoot(parent: Node, from: Vector3, dir: Vector3, p_drops: DroppedItems, p_frame: Node3D,
		p_exclude: Array[RID] = []) -> WiringArrow:
	var a := WiringArrow.new()
	a.name = "Arrow"
	a.vel = (dir.normalized() + Vector3.UP * LIFT).normalized() * SPEED
	a.drops = p_drops
	a.frame = p_frame
	a.exclude = p_exclude
	var shaft := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(0.025, 0.025, LENGTH)
	shaft.mesh = b
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.55, 0.38, 0.2)
	shaft.material_override = wood
	a.add_child(shaft)
	var head := MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = Vector3(0.05, 0.05, 0.07)
	head.mesh = hb
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.7, 0.72, 0.75)
	steel.metallic = 0.8
	head.material_override = steel
	head.position = Vector3(0, 0, -LENGTH * 0.5)
	a.add_child(head)
	parent.add_child(a)
	a.global_position = from
	a._face()
	shot_count += 1
	return a


func _face() -> void:
	if vel.length_squared() > 0.0001:
		var up := Vector3.UP if absf(vel.normalized().y) < 0.99 else Vector3.RIGHT
		global_basis = Basis.looking_at(vel.normalized(), up)


func _physics_process(delta: float) -> void:
	age += delta
	if age > LIFE:
		queue_free()
		return
	vel += Gravity.down_at(global_position) * 9.8 * delta
	var from := global_position
	var to := from + vel * delta
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.GUN_MASK, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		global_position = to
		_face()
		return
	var target := GunController._living(hit.collider)
	if target != null:
		var p := DamagePacket.new(CombatScale.melee(1) * DAMAGE_MELEES, null, self)
		p.hit_position = hit.position
		p.hit_normal = hit.normal
		var r := DamageSystem.resolve(p, target)
		dealt = r.dealt if r != null else 0.0
		struck = "body"
		hits_on_bodies += 1
		queue_free()
		return
	# The ground or a wall: it lies there, an arrow to pick up.
	struck = "ground"
	if drops != null and frame != null:
		var at: Vector3 = frame.to_local(hit.position + (hit.normal as Vector3) * 0.05)
		drops.spawn(ItemStack.make(&"arrow", 1), at)
	queue_free()
