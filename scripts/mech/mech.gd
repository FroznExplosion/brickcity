class_name Mech
extends Node
## A mech: BoomerBorder's TitanMotor under a body sized in bricks, with an arm that
## carries a gun. A component under its CharacterBody3D, like Pawn (D7).
##
## Like the titan it came from it has ONE interface for whoever drives it: fill
## `intents` (TitanIntents) -- the pilot (MechPilot) or, later, the AI brain that
## lets the player's mech fight on its own. The motor moves the chassis: legs lag
## the torso, the torso chases the aim, sprint and dash chain. This node adds what
## the titan's 3,400-line scene script did that brickcity needs now: a body, a
## greybox to see it by, and the arm.
##
## **The arm aims like the player** (Docs/AI.md A15): full pitch, up at a sniper
## on a roof or down into a street, where BoomerBorder held it to -45..40. Its yaw
## stays a shoulder, +-55 degrees of the torso, so how fast the torso turns still
## matters. The arm converges on `aim_point` when the brain gives one (where the
## pilot's crosshair lands), so a gun mounted beside the cockpit hits what the
## pilot is looking at, not a parallel line a metre and a half to the right.
##
## Greybox for now: the "brick-built mech" of the porting checklist is a chunk of
## bricks with its own weight (Docs/AIPlan.md P7). Until then, boxes the colour of
## bricks, sized in them.

const COURSE := 0.42
const STUD := 0.35
## 16 courses tall (6.72 m), 5 studs of radius (1.75 m): BoomerBorder's titan,
## 6.9 m by 1.7 m, restated on the grid. Four figures tall.
const HEIGHT := COURSE * 16.0
const RADIUS := STUD * 5.0
## The cockpit, 10 courses up (4.2 m -- the titan's own TORSO_Y, which lands on a
## course exactly).
const COCKPIT_Y := COURSE * 10.0
## The eye sits this far ahead of the torso's centre, behind the canopy.
const COCKPIT_FORWARD := 0.9
## The arm's shoulder, relative to the torso: right, and just under the cockpit.
const SHOULDER := Vector3(2.0, COURSE * 9.0, -0.4)
const ARM_YAW_LIMIT := deg_to_rad(55.0)
const ARM_YAW_SPEED := deg_to_rad(420.0)
## Straight up and straight down, short of the pole (A15).
const ARM_PITCH_LIMIT := deg_to_rad(89.0)
const MAX_HEALTH := 2500.0

var intents := TitanIntents.new()
var team := 0
var body: CharacterBody3D
var motor: TitanMotor
var health: HealthPool
var gun: GunController
## Where the arm should put its rounds, in world space; INF for "along the aim".
var aim_point := Vector3.INF

var legs: Node3D
var torso: Node3D
var arm: Node3D
## Where rounds leave the arm. GunController's aim.
var muzzle: Node3D
## Arm yaw relative to the torso, radians.
var arm_yaw := 0.0
var arm_pitch := 0.0


## A standing mech with its feet at `feet`, facing `yaw`.
static func spawn(parent: Node, feet: Vector3, yaw := 0.0, p_team := 0) -> Mech:
	var b := CharacterBody3D.new()
	b.name = "MechBody"
	b.collision_layer = Layers.PAWN
	b.collision_mask = Layers.PAWN_MASK
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = RADIUS
	capsule.height = HEIGHT
	shape.shape = capsule
	b.add_child(shape)

	var m := Mech.new()
	m.name = "Mech"
	m.team = p_team
	m.body = b
	b.add_child(m)
	var mo := TitanMotor.new()
	mo.name = "TitanMotor"
	mo.body = b
	m.motor = mo
	b.add_child(mo)
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = MAX_HEALTH
	pool.layer_configs = [layer]
	b.add_child(pool)
	m.health = pool
	m._build_greybox()
	parent.add_child(b)
	if b.is_inside_tree():
		b.global_position = feet + Vector3.UP * HEIGHT * 0.5
	else:
		b.position = feet + Vector3.UP * HEIGHT * 0.5
	b.reset_physics_interpolation()
	mo.reset(yaw)
	m.intents.clear(yaw)
	mo.set_intents(m.intents)
	var g := GunController.new()
	g.name = "ArmGun"
	g.aim = m.muzzle
	g.exclude = [b.get_rid()] as Array[RID]
	b.add_child(g)
	m.gun = g
	return m


func feet() -> Vector3:
	return body.global_position - Vector3.UP * HEIGHT * 0.5


## The pilot's eye between physics ticks: the chassis is moved 30 times a second.
func cockpit_interpolated() -> Vector3:
	var o := body.get_global_transform_interpolated().origin
	var fwd := -Basis(Vector3.UP, motor.torso_yaw).z
	return o + Vector3.UP * (COCKPIT_Y - HEIGHT * 0.5) + fwd * COCKPIT_FORWARD


func _physics_process(delta: float) -> void:
	if body == null or motor == null:
		return
	_aim_arm(delta)
	legs.rotation.y = motor.legs_yaw
	torso.rotation.y = motor.torso_yaw


## The arm chases the aim: yaw within its shoulder's reach of the torso, pitch
## free (A15). With an aim point it converges on it; without, it takes the
## intents' aim angles.
func _aim_arm(delta: float) -> void:
	var want_yaw := intents.aim_yaw
	var want_pitch := intents.aim_pitch
	var shoulder := body.global_position + Vector3.UP * (SHOULDER.y - HEIGHT * 0.5) \
			+ Basis(Vector3.UP, motor.torso_yaw) * Vector3(SHOULDER.x, 0.0, SHOULDER.z)
	if aim_point != Vector3.INF:
		var to := aim_point - shoulder
		if to.length() > 2.0:
			want_yaw = atan2(-to.x, -to.z)
			want_pitch = atan2(to.y, Vector2(to.x, to.z).length())
	var rel := clampf(wrapf(want_yaw - motor.torso_yaw, -PI, PI), -ARM_YAW_LIMIT, ARM_YAW_LIMIT)
	arm_yaw = move_toward(arm_yaw, rel, ARM_YAW_SPEED * delta)
	arm_pitch = clampf(want_pitch, -ARM_PITCH_LIMIT, ARM_PITCH_LIMIT)
	# The arm is a child of the body, which never rotates; put it in world yaw.
	arm.position = shoulder - body.global_position
	arm.rotation = Vector3(arm_pitch, motor.torso_yaw + arm_yaw, 0.0)


func _build_greybox() -> void:
	var brick := StandardMaterial3D.new()
	brick.albedo_color = Color(0.55, 0.57, 0.6)
	brick.roughness = 0.8
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.3, 0.32, 0.35)
	var feet_y := -HEIGHT * 0.5
	legs = Node3D.new()
	legs.name = "Legs"
	body.add_child(legs)
	for side in [-1.0, 1.0]:
		_box(legs, Vector3(side * STUD * 2.0, feet_y + COURSE * 4.0, 0.0),
				Vector3(STUD * 3.0, COURSE * 8.0, STUD * 3.0), brick)
		_box(legs, Vector3(side * STUD * 2.0, feet_y + COURSE * 0.5, -STUD * 0.5),
				Vector3(STUD * 3.5, COURSE, STUD * 5.0), dark)
	_box(legs, Vector3(0.0, feet_y + COURSE * 8.5, 0.0), Vector3(STUD * 7.0, COURSE * 1.5, STUD * 4.0), dark)
	torso = Node3D.new()
	torso.name = "Torso"
	body.add_child(torso)
	_box(torso, Vector3(0.0, feet_y + COURSE * 11.5, 0.0),
			Vector3(STUD * 9.0, COURSE * 5.0, STUD * 7.0), brick)
	# The canopy: a darker slab across the front at the eye.
	_box(torso, Vector3(0.0, feet_y + COCKPIT_Y + COURSE * 0.3, -STUD * 3.5),
			Vector3(STUD * 5.0, COURSE * 1.5, STUD * 0.6), dark)
	_box(torso, Vector3(-STUD * 5.0, feet_y + COURSE * 12.5, 0.0),
			Vector3(STUD * 2.0, COURSE * 3.0, STUD * 3.0), brick)
	arm = Node3D.new()
	arm.name = "Arm"
	body.add_child(arm)
	_box(arm, Vector3(0.0, 0.0, -1.0), Vector3(STUD * 2.0, COURSE * 2.0, 2.4), brick)
	_box(arm, Vector3(0.0, 0.0, -2.6), Vector3(STUD * 1.2, COURSE * 1.2, 1.2), dark)
	muzzle = Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 0.0, -3.3)
	arm.add_child(muzzle)


static func _box(parent: Node3D, at: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
