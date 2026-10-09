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
## A mech gun's rounds, against a person's (GunController.damage_mult): a
## stand-in until mech weapons are rolled as their own classes (AIRoster.md 4.6).
## At 8 a rifle-class round is one melee: it kills a light enemy in one.
const GUN_MULT := 8.0
## A mech's fist: how far between centres it reaches, how hard, how often.
const MELEE_REACH := 5.0
const MELEE_DAMAGE := 500.0
const MELEE_GAP := 1.2
## What it weighs on the bricks it stands on (WeightTracker).
const MASS := WeightTracker.MECH
## Getting in (Docs/AIRoster.md 4.4): a pilot stands this far out from the torso's
## centre on the hatch's side -- in front of a medium or heavy, behind a light --
## and gets in from within MOUNT_REACH of that spot.
const MOUNT_OUT := RADIUS + 1.3
const MOUNT_REACH := 1.6
## A Nuker's pilot is thrown clear of its blast (4.7): this much past its reach.
const EJECT_CLEAR := 6.0
## Danger zones for a lit fuse (AIWorld), so people get clear of a blast.
const DANGER_ID_BASE := 720000

signal mounted(p: Pawn)
signal dismounted(p: Pawn, thrown: bool)

var intents := TitanIntents.new()
var team := 0
var body: CharacterBody3D
var motor: TitanMotor
var health: HealthPool
## How it is killed: shield, armour, health, the doors, the pilot and the cell.
var layers: MechLayers
## Whoever is riding it (Rodeo, 4.5).
var rodeo: Rodeo
var gun: GunController
## What it is (Roster): its recipe, the casebook facts it brings, the name over it.
var type_id := ""
var type_facts: Array = []
## What everybody else sees and shoots at (make_target): a Pawn that does not
## walk -- the motor moves this body -- but has a chest, an eye, a side and this
## mech's health, so soldiers, flyers and other mechs sense and target a mech as
## they do a person, and the side's aggro keeps a row for it.
var pawn: Pawn
var name_tag: Label3D
## Who is in it: an AI pilot's pawn, put away while it is inside (stow). Null
## with nobody in it -- or with a pilot nobody put in (layers.piloted), the
## player's included: the city frees the player's pawn and makes a new one on
## the way out.
var pilot_pawn: Pawn
var _stowed_layers := Vector2i.ZERO
var _danger_id := -1
var melee_ready_at := 0.0
var melee_hits := 0
var _clock := 0.0
## Falling through floors (Docs/AI.md 3.11): the owner connects what it lands on
## and what breaking it means.
var fall: FallRule
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
static func spawn(parent: Node, at_feet: Vector3, yaw := 0.0, p_team := 0) -> Mech:
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
	m.layers = MechLayers.attach(m)
	m._wire_layers()
	m.rodeo = Rodeo.attach(m)
	m._build_greybox()
	parent.add_child(b)
	if b.is_inside_tree():
		b.global_position = at_feet + Vector3.UP * HEIGHT * 0.5
	else:
		b.position = at_feet + Vector3.UP * HEIGHT * 0.5
	b.reset_physics_interpolation()
	mo.reset(yaw)
	m.intents.clear(yaw)
	mo.set_intents(m.intents)
	var fr := FallRule.new()
	fr.name = "FallRule"
	fr.mech = m
	b.add_child(fr)
	m.fall = fr
	var g := GunController.new()
	g.name = "ArmGun"
	g.aim = m.muzzle
	g.exclude = [b.get_rid()] as Array[RID]
	g.damage_scale = &"mech"
	g.damage_mult = GUN_MULT
	b.add_child(g)
	m.gun = g
	return m


## The Pawn that stands for this mech to everyone who senses and shoots (above).
## Give it to AIServices.add_pawn.
func make_target() -> Pawn:
	if pawn != null and is_instance_valid(pawn):
		return pawn
	var e := Node3D.new()
	e.name = "Eye"
	e.position = Vector3.UP * (COCKPIT_Y - HEIGHT * 0.5)
	body.add_child(e)
	var p := Pawn.new()
	p.name = "Pawn"
	p.team = team
	p.health = health
	p.gun = gun
	p.eye = e
	# Never stepped: the titan's motor moves the body.
	p.process_mode = Node.PROCESS_MODE_DISABLED
	p.stand_height = HEIGHT
	p.set_meta(&"aggro_kind", "mech")
	p.set_meta(&"mech", true)
	body.add_child(p)
	pawn = p
	return p


## Make it the mech type `id` of `roster`: its class's shield, armour, health and
## doors, the side its hatch is on, the Nuker mod, and its name over it.
func set_type(id: String, roster: Roster) -> void:
	if roster == null or not roster.has(id):
		return
	var d := roster.derived(id)
	var spec: Dictionary = d.get("mech", {})
	if spec.is_empty():
		return
	type_id = id
	type_facts = roster.facts(id).duplicate()
	var keep := layers.services if layers != null else null
	if layers != null:
		health.damage_filter = Callable()
		health.layer_depleted.disconnect(layers._on_layer_depleted)
		health.died.disconnect(layers._on_died)
		layers.queue_free()
	var was_piloted := layers.piloted if layers != null else true
	var was_auto := layers.auto if layers != null else false
	layers = MechLayers.attach(self, spec)
	layers.services = keep
	layers.nuker = (roster.recipe(id).get("mods", []) as Array).has("nuker")
	layers.piloted = was_piloted
	layers.auto = was_auto
	layers.pilot = pilot_pawn
	_wire_layers()
	if name_tag == null or not is_instance_valid(name_tag):
		name_tag = TypeKit.make_tag(body, TypeKit.tag_text(d), team, HEIGHT * 0.5 + 0.7)
	else:
		name_tag.text = TypeKit.tag_text(d)


# --- getting in and out (Docs/AIRoster.md 4.4, 4.7; R14) ----------------------------

## Nobody in it, and nobody driving: a mech standing on the map for a pilot of
## its side to get into. Its brain sleeps until one does.
func park() -> void:
	if pilot_pawn != null:
		return
	layers.piloted = false
	layers.auto = false
	var br := brain()
	if br != null:
		br.enabled = false
		intents.clear(motor.torso_yaw)
		gun.set_trigger(false)


func brain() -> MechBrain:
	return body.get_node_or_null(^"MechBrain") as MechBrain


func is_empty() -> bool:
	return not layers.piloted and pilot_pawn == null


## Where a pilot stands to get in: on the hatch's side, clear of the hull --
## on the walking map when there is one.
func mount_point() -> Vector3:
	var z_sign := -1.0 if layers.hatch_side == "front" else 1.0
	var back := Basis(Vector3.UP, motor.torso_yaw).z
	var at := feet() + back * z_sign * MOUNT_OUT
	var s := layers.services
	if s != null and s.ai_nav != null:
		var snapped := s.ai_nav.snap(at)
		if Vector2(snapped.x - at.x, snapped.z - at.z).length() < 1.5:
			return snapped
	return at


## Can somebody stand at the mount point? Not with bricks in it, nor with no
## walking map near it (the mech backed against a wall, say).
func mount_spot_clear() -> bool:
	var s := layers.services
	if s == null or s.ai_world == null:
		return true
	var z_sign := -1.0 if layers.hatch_side == "front" else 1.0
	var back := Basis(Vector3.UP, motor.torso_yaw).z
	var at := feet() + back * z_sign * MOUNT_OUT
	if s.ai_world.solid_at(at + Vector3.UP * 0.9) or s.ai_world.solid_at(at + Vector3.UP * 1.5):
		return false
	if s.ai_nav != null:
		var snapped := s.ai_nav.snap(at)
		if Vector2(snapped.x - at.x, snapped.z - at.z).length() >= 1.5:
			return false
	return true


## Is `p` standing where it can get in?
func can_reach(p: Pawn) -> bool:
	var mp := mount_point()
	var f := p.feet()
	return Vector2(f.x - mp.x, f.z - mp.z).length() <= MOUNT_REACH and absf(f.y - mp.y) < 1.2


## `p` gets in, from the mount point (or from `anywhere`, for a pilot fielded in
## it). A pilot of another side sets off its self-destruct instead (R14) and
## stays out. An AI pilot wakes the mech's brain. True if it got in.
func mount(p: Pawn, anywhere := false) -> bool:
	if p == null or layers.dead or pilot_pawn != null or (p.health != null and p.health.is_dead()):
		return false
	if not anywhere and not can_reach(p):
		return false
	if not layers.try_enter(p.team):
		return false
	_stow(p)
	pilot_pawn = p
	layers.pilot = p
	layers.piloted = true
	layers.auto = false
	var br := brain()
	if br != null and p.body.get_node_or_null(^"Soldier") != null:
		br.enabled = true
	mounted.emit(p)
	return true


## A pilot nobody put in -- the player, whose pawn the city frees -- takes the
## controls: piloted, not auto.
func occupy() -> void:
	if layers.dead:
		return
	layers.piloted = true
	layers.auto = false


## The pilot gets out: on the ground at the mount point, or -- `thrown`, a
## Nuker's eject -- clear of its blast. The mech fights on in auto mode (4.2).
## Returns the pilot's pawn (null for a pilot nobody put in).
func dismount(thrown := false) -> Pawn:
	var p := pilot_pawn
	var was := layers.piloted
	pilot_pawn = null
	layers.pilot = null
	layers.piloted = false
	layers.auto = was and not layers.dead
	if p == null or not is_instance_valid(p):
		return null
	var at := mount_point()
	if thrown:
		var z_sign := -1.0 if layers.hatch_side == "front" else 1.0
		var out := Basis(Vector3.UP, motor.torso_yaw).z * z_sign
		at = feet() + out * (float(MechLayers.NUKE[1]) + EJECT_CLEAR)
		var s := layers.services
		if s != null and s.ai_nav != null:
			at = s.ai_nav.snap(at)
	_unstow(p, at)
	dismounted.emit(p, thrown)
	return p


## Put a pilot away inside: out of everybody's sight and aim (the services' pawns),
## not moving, not colliding, not drawn. Its hits come through the hatch
## (MechLayers.pilot).
func _stow(p: Pawn) -> void:
	var s := layers.services
	if s != null:
		s.pawns.erase(p)
		for team in [0, 1]:
			s.knowledge_of(team).contacts.erase(p.get_instance_id())
	_stowed_layers = Vector2i(p.body.collision_layer, p.body.collision_mask)
	p.body.collision_layer = 0
	p.body.collision_mask = 0
	p.body.visible = false
	p.intents.clear()
	p.place(feet() + Vector3.UP * (COCKPIT_Y - Pawn.BODY_HEIGHT * 0.5))
	p.body.process_mode = Node.PROCESS_MODE_DISABLED
	p.set_meta(&"in_mech", self)


func _unstow(p: Pawn, at: Vector3) -> void:
	p.body.process_mode = Node.PROCESS_MODE_INHERIT
	p.body.collision_layer = _stowed_layers.x
	p.body.collision_mask = _stowed_layers.y
	p.body.visible = true
	p.place(at)
	p.remove_meta(&"in_mech")
	var s := layers.services
	if s != null and not p.health.is_dead():
		s.add_pawn(p)


func _wire_layers() -> void:
	layers.fuse_lit.connect(_on_fuse_lit)
	layers.destroyed.connect(_on_destroyed)
	layers.pilot_killed.connect(func() -> void: pilot_pawn = null)


## A fuse lit: a danger zone the size of its blast, so people get clear of it.
func _on_fuse_lit(kind: String, _seconds: float) -> void:
	var s := layers.services
	if s == null or s.ai_world == null:
		return
	var reach := float((MechLayers.NUKE if kind == "nuke" else MechLayers.SELF_DESTRUCT)[1])
	_danger_id = DANGER_ID_BASE + int(get_instance_id() % 100000)
	s.ai_world.set_danger(_danger_id, AABB(feet() - Vector3(reach, 0.5, reach), Vector3(reach * 2.0, HEIGHT + 1.0, reach * 2.0)))


## Destroyed with its pilot inside: the pilot goes with it.
func _on_destroyed(_why: String) -> void:
	var s := layers.services
	if _danger_id >= 0 and s != null and s.ai_world != null:
		s.ai_world.remove_danger(_danger_id)
		_danger_id = -1
	if pilot_pawn != null and is_instance_valid(pilot_pawn) and pilot_pawn.health != null:
		pilot_pawn.health.apply_impact(1e9, &"")
	pilot_pawn = null


## Punch `target` if it is in reach and the last blow was long enough ago: through
## its shield, on the side of it this mech is at -- and a doomed mech is finished.
func melee(target: Mech) -> bool:
	if target == null or target.layers == null or target.layers.dead or _clock < melee_ready_at:
		return false
	var to := target.feet() - feet()
	if Vector2(to.x, to.z).length() > MELEE_REACH or absf(to.y) > HEIGHT * 0.5:
		return false
	melee_ready_at = _clock + MELEE_GAP
	melee_hits += 1
	# Where the fist lands: the near side of its torso, at the cockpit's height.
	var flat := Vector3(-to.x, 0.0, -to.z).normalized()
	var at := target.feet() + Vector3.UP * COCKPIT_Y + flat * RADIUS * 0.85
	target.layers.melee(MELEE_DAMAGE, target.layers.zone_at(at))
	return true


func feet() -> Vector3:
	return body.global_position - Vector3.UP * HEIGHT * 0.5


## The pilot's eye between physics ticks: the chassis is moved 30 times a second.
func cockpit_interpolated() -> Vector3:
	var o := body.get_global_transform_interpolated().origin
	var fwd := -Basis(Vector3.UP, motor.torso_yaw).z
	return o + Vector3.UP * (COCKPIT_Y - HEIGHT * 0.5) + fwd * COCKPIT_FORWARD


func _physics_process(delta: float) -> void:
	_clock += delta
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
