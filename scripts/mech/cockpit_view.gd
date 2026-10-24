class_name CockpitView
extends Node3D
## The pilot's seat as the pilot sees it: their arms down at their sides, a hand on
## each of two sticks that drive the mech. The left stick leans with WASD, the right
## with the look (it is what turns the torso) and lights its button while the arm
## fires. The sticks stand in the seat, which turns with the look's yaw but not its
## pitch -- look down and they are there; look ahead and the fists are at the
## bottom corners of the view.
##
## A child of the camera, as the on-foot ViewArms are (it makes its own).

## Where each stick's grip is, from the eye, in the seat's frame (x right, y up,
## -z ahead): low, and out to the sides.
const GRIP := [Vector3(0.34, -0.44, -0.46), Vector3(-0.34, -0.44, -0.46)]
## From the grip down to the stick's pivot.
const SHAFT := 0.2
## How far a stick leans at full push, radians.
const LEAN := 0.32
## The look's turn rate that leans the right stick all the way, radians a second.
const FULL_TURN := 3.0
## How quickly a stick follows the hand, per second.
const FOLLOW := 12.0

var mech: Mech
var camera: Camera3D
var arms: ViewArms
## Each stick: a pivot node; its lean now (x: ahead/back, z: side to side).
var sticks: Array[Node3D] = [null, null]
var lean := [Vector2.ZERO, Vector2.ZERO]
var _button: StandardMaterial3D
var _last_look := Vector2.INF


func setup(cam: Camera3D, m: Mech) -> void:
	camera = cam
	mech = m
	name = "Cockpit"
	cam.add_child(self)
	arms = ViewArms.new()
	arms.setup(cam)
	arms.set_hand(ViewArms.RIGHT, ViewArms.Hand.C)
	arms.set_hand(ViewArms.LEFT, ViewArms.Hand.C)
	var dark := ViewArms._mat(Color(0.16, 0.17, 0.19))
	var metal := ViewArms._mat(Color(0.42, 0.44, 0.47))
	var rubber := ViewArms._mat(Color(0.08, 0.08, 0.09))
	_button = ViewArms._mat(Color(0.5, 0.08, 0.06))
	for side in 2:
		var pivot := Node3D.new()
		pivot.name = "StickR" if side == ViewArms.RIGHT else "StickL"
		add_child(pivot)
		sticks[side] = pivot
		_part(pivot, _cyl(0.07, 0.09, 0.05), dark, Vector3(0.0, -0.02, 0.0))
		_part(pivot, _cyl(0.012, 0.014, SHAFT), metal, Vector3(0.0, SHAFT * 0.5, 0.0))
		_part(pivot, _cyl(0.024, 0.022, 0.13), rubber, Vector3(0.0, SHAFT, 0.0))
		if side == ViewArms.RIGHT:
			_part(pivot, _cyl(0.012, 0.012, 0.012), _button, Vector3(0.0, SHAFT + 0.07, 0.0))
		# The console the stick stands in, beside the seat.
		var console := _part(self, _box(Vector3(0.22, 0.5, 0.36)), dark, Vector3.ZERO)
		console.name = "Console" + ("R" if side == ViewArms.RIGHT else "L")
		console.set_meta(&"side", side)
	_place(0.0)


func _process(delta: float) -> void:
	if mech == null or not is_instance_valid(mech) or camera == null:
		return
	# The right stick turns the torso: it leans with how fast the look turns.
	var gr := camera.global_rotation
	if camera is DebugCamera and (camera as DebugCamera).frame != Basis.IDENTITY:
		gr = (camera as DebugCamera).look_angles()
	var look := Vector2(gr.y, gr.x)
	var turn := Vector2.ZERO
	if _last_look != Vector2.INF and delta > 0.0:
		turn = Vector2(wrapf(look.x - _last_look.x, -PI, PI), look.y - _last_look.y) / delta
	_last_look = look
	var want_r := Vector2(clampf(-turn.y / FULL_TURN, -1.0, 1.0), clampf(-turn.x / FULL_TURN, -1.0, 1.0))
	var md: Vector2 = mech.intents.move_dir
	var want_l := Vector2(md.y, md.x)
	var k := 1.0 - exp(-FOLLOW * delta)
	lean[ViewArms.RIGHT] = (lean[ViewArms.RIGHT] as Vector2).lerp(want_r, k)
	lean[ViewArms.LEFT] = (lean[ViewArms.LEFT] as Vector2).lerp(want_l, k)
	var firing := mech.gun != null and mech.gun.trigger_held()
	_button.albedo_color = Color(1.0, 0.2, 0.12) if firing else Color(0.5, 0.08, 0.06)
	_button.emission_enabled = firing
	_button.emission = Color(1.0, 0.2, 0.1)
	_place(delta)


## Put the sticks and consoles in the seat, and the hands on the grips.
func _place(delta: float) -> void:
	# The seat: at the eye, turned with the look's yaw only. In camera space.
	var gr := camera.global_rotation
	if camera is DebugCamera and (camera as DebugCamera).frame != Basis.IDENTITY:
		gr = (camera as DebugCamera).look_angles()
	var seat_basis := Basis(Vector3.UP, gr.y)
	if camera is DebugCamera and (camera as DebugCamera).frame != Basis.IDENTITY:
		seat_basis = (camera as DebugCamera).frame * seat_basis
	var seat_world := Transform3D(seat_basis, camera.global_position)
	var to_cam := camera.global_transform.affine_inverse() * seat_world
	var hands: Array[Transform3D] = [Transform3D(), Transform3D()]
	for side in 2:
		var grip: Vector3 = GRIP[side]
		var l: Vector2 = lean[side]
		# Pushed ahead, the top goes ahead (-z): a turn about +x by -lean.
		var tilt := Basis(Vector3.RIGHT, -l.x * LEAN) * Basis(Vector3.BACK, -l.y * LEAN)
		var base := grip - Vector3.UP * SHAFT
		var pivot_seat := Transform3D(tilt, base)
		sticks[side].transform = to_cam * pivot_seat
		var top := pivot_seat * (Vector3.UP * (SHAFT + 0.01))
		var up := tilt * Vector3.UP
		# The C round the grip: its hole along the stick, the fingers reaching
		# ahead and in, the wrist behind and outside.
		var inward := Vector3(-1.0 if side == ViewArms.RIGHT else 1.0, 0.0, 0.0)
		var fingers := (Vector3.FORWARD + inward * 0.6)
		fingers = (fingers - up * fingers.dot(up)).normalized()
		var hb := Basis(up, fingers, up.cross(fingers))
		hands[side] = to_cam * Transform3D(hb, top)
	for c in get_children():
		if c.has_meta(&"side"):
			var s: int = c.get_meta(&"side")
			var g: Vector3 = GRIP[s]
			c.transform = to_cam * Transform3D(Basis.IDENTITY,
					Vector3(g.x, g.y - SHAFT - 0.27, g.z + 0.04))
	arms.pose(hands[ViewArms.RIGHT], hands[ViewArms.LEFT], delta)


func _exit_tree() -> void:
	if arms != null and is_instance_valid(arms):
		arms.queue_free()
	arms = null


static func _part(parent: Node3D, m: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _cyl(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = 12
	return c


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b
