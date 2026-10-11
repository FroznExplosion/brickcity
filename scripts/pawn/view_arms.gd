class_name ViewArms
extends Node3D
## The player's arms in first person: placeholders, brick-figure style. Two arms
## from the shoulders to stiff hands that never move a finger -- a hand is one of
## four rigid shapes, swapped whole:
##
##   C      the brick figure's C: a gun's grip or its handguard passes through it
##   PINCH  a small, tight C for small things -- a magazine
##   OPEN   a flat open hand, for moving with nothing in it
##   FIST   closed
##
## A new shape is asked for with `set_hand`; it is put on only when that hand is
## off the screen (the animations take a hand out of view to change it), or, if
## the hand never leaves the view, after SWAP_GRACE.
##
## The bones are Mixamo's names as Godot imports them (`mixamorig:RightArm`
## becomes `mixamorig_RightArm`: a bone name may not hold a colon), so a Mixamo
## rig and its animations can stand in for these later. Each frame `pose` is
## given where each hand should be -- the centre of the hole in its C, and how
## it is turned, in this node's space (the camera's) -- and a two-bone IK puts
## the arm on it: the shoulder is fixed, the elbow hinges and swings about the
## line from shoulder to wrist (`swivel`).
##
## Hand frame, every shape alike: origin at the wrist, +Y out of the wrist to the
## fingers, +X along the hole of the C (what is held passes through along X), the
## C's opening toward +Z.

enum Hand { C, PINCH, OPEN, FIST }
enum { RIGHT, LEFT }

const PREFIX := "mixamorig_"
const SIDE_NAMES := ["Right", "Left"]
## Arm segment lengths, metres. A little shorter than a person's: the view sees
## the forearms, and long arms push the elbows out of it.
const UPPER := 0.31
const FORE := 0.3
## Camera-local joints. The spine is behind and under the eye; the shoulders
## either side of it.
const SPINE := Vector3(0.0, -0.34, 0.2)
const SHOULDER := [Vector3(0.18, -0.22, 0.04), Vector3(-0.18, -0.22, 0.04)]
## How far a shoulder may come forward toward a hand out of reach, metres.
const SHOULDER_REACH := 0.14
## Where each elbow points, before swivel: down and out.
const POLE := [Vector3(0.85, -1.0, 0.2), Vector3(-0.85, -1.0, 0.2)]
## From the wrist to the centre of the C's hole, along +Y.
const HOLE_Y := 0.05
## How long a new hand waits for its hand to leave the view before it is put on anyway.
const SWAP_GRACE := 0.6

const SKIN := Color(0.98, 0.78, 0.12)
const SLEEVE := Color(0.2, 0.24, 0.3)
const CUFF := Color(0.13, 0.15, 0.19)

var skeleton: Skeleton3D
## Extra turn of each elbow about its shoulder-wrist line, radians; + swings it up.
var swivel := [0.0, 0.0]
var camera: Camera3D
## For the --arms pass: hand changes made with the hand still on the screen (its
## SWAP_GRACE ran out), and how far each wrist fell short of where it was asked
## to be last frame (out of reach), metres.
var swaps_in_view := 0
var reach_gap := [0.0, 0.0]

var _bone := {}
var _hands := [[], []]
var _shown := [Hand.C, Hand.C]
var _want := [Hand.C, Hand.C]
var _waited := [0.0, 0.0]
## Each hand's hole centre last frame, camera-local (what the off-screen test reads).
var _hole := [Vector3.ZERO, Vector3.ZERO]


static func bone_name(side: int, part: String) -> String:
	return PREFIX + SIDE_NAMES[side] + part


func setup(cam: Camera3D) -> void:
	camera = cam
	name = "Arms"
	cam.add_child(self)
	_build()


func _build() -> void:
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	var spine := _add_bone(PREFIX + "Spine2", -1, Transform3D(Basis.IDENTITY, SPINE))
	for side in 2:
		var sh: Vector3 = SHOULDER[side]
		var clav := _add_bone(bone_name(side, "Shoulder"), spine,
				Transform3D(_aim(sh - SPINE, Vector3.UP), Vector3(0.0, 0.08, 0.0)))
		# Rests: arm straight out ahead, as if reaching for the crosshair.
		var ahead := _aim(Vector3.FORWARD, Vector3.DOWN)
		var arm := _add_bone(bone_name(side, "Arm"), clav, _local(clav, Transform3D(ahead, sh)))
		var fore := _add_bone(bone_name(side, "ForeArm"), arm,
				Transform3D(Basis.IDENTITY, Vector3(0.0, UPPER, 0.0)))
		var hand := _add_bone(bone_name(side, "Hand"), fore,
				Transform3D(Basis.IDENTITY, Vector3(0.0, FORE, 0.0)))
		_dress(side, arm, fore, hand)
	skeleton.reset_bone_poses()


func _add_bone(n: String, parent: int, rest: Transform3D) -> int:
	var i := skeleton.add_bone(n)
	if parent >= 0:
		skeleton.set_bone_parent(i, parent)
	skeleton.set_bone_rest(i, rest)
	_bone[n] = i
	return i


## A rest given in skeleton space, as the bone's local rest.
func _local(parent: int, global: Transform3D) -> Transform3D:
	return _rest_global(parent).affine_inverse() * global


func _rest_global(i: int) -> Transform3D:
	var t := skeleton.get_bone_rest(i)
	var p := skeleton.get_bone_parent(i)
	while p >= 0:
		t = skeleton.get_bone_rest(p) * t
		p = skeleton.get_bone_parent(p)
	return t


# ------------------------------------------------------------------------ meshes

func _dress(side: int, arm: int, fore: int, hand: int) -> void:
	var sleeve := _mat(SLEEVE)
	var cuff := _mat(CUFF)
	var skin := _mat(SKIN)
	var up := _attach(arm)
	_mesh(up, _cylinder(0.033, 0.038, UPPER), sleeve, Vector3(0.0, UPPER * 0.5, 0.0))
	_mesh(up, _sphere(0.04), sleeve, Vector3.ZERO)
	var lo := _attach(fore)
	_mesh(lo, _cylinder(0.027, 0.032, FORE), sleeve, Vector3(0.0, FORE * 0.5, 0.0))
	# The elbow: a ball the forearm turns on.
	_mesh(lo, _sphere(0.035), cuff, Vector3.ZERO)
	_mesh(lo, _cylinder(0.031, 0.031, 0.03), cuff, Vector3(0.0, FORE - 0.015, 0.0))
	var h := _attach(hand)
	_mesh(h, _cylinder(0.018, 0.018, 0.03), skin, Vector3(0.0, 0.015, 0.0))
	var shapes: Array = []
	for kind in [Hand.C, Hand.PINCH, Hand.OPEN, Hand.FIST]:
		var holder := Node3D.new()
		holder.name = Hand.keys()[kind]
		h.add_child(holder)
		match kind:
			Hand.C:
				_mesh(holder, c_mesh(0.019, 0.034, 0.042, deg_to_rad(70.0)), skin, Vector3.ZERO)
			Hand.PINCH:
				_mesh(holder, c_mesh(0.009, 0.024, 0.034, deg_to_rad(110.0)), skin, Vector3.ZERO)
			Hand.OPEN:
				_mesh(holder, _box(Vector3(0.05, 0.085, 0.018)), skin, Vector3(0.0, 0.07, 0.0))
				# The thumb, off the side of the palm toward the body's middle.
				var tx := -0.03 if side == RIGHT else 0.03
				_mesh(holder, _box(Vector3(0.016, 0.04, 0.016)), skin, Vector3(tx, 0.05, 0.008))
			Hand.FIST:
				_mesh(holder, _box(Vector3(0.05, 0.05, 0.046)), skin, Vector3(0.0, 0.052, 0.0))
		holder.visible = kind == _shown[side]
		shapes.append(holder)
	_hands[side] = shapes


func _attach(bone: int) -> BoneAttachment3D:
	var a := BoneAttachment3D.new()
	a.name = skeleton.get_bone_name(bone).trim_prefix(PREFIX)
	skeleton.add_child(a)
	a.bone_name = skeleton.get_bone_name(bone)
	return a


func _mesh(parent: Node3D, m: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	# The view's own arms throw no shadow on the world.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.4
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _cylinder(top: float, bottom: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = 12
	c.rings = 1
	return c


static func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 12
	s.rings = 6
	return s


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## The brick figure's C: a ring of square section round the X axis, centred
## HOLE_Y up the hand, with `gap` radians cut out of it toward +Z.
static func c_mesh(r_in: float, r_out: float, width: float, gap: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 16
	var a0 := gap * 0.5
	var a1 := TAU - gap * 0.5
	var hw := width * 0.5
	var p := func(a: float, r: float, x: float) -> Vector3:
		return Vector3(x, HOLE_Y + r * sin(a), r * cos(a))
	for i in n:
		var ta := lerpf(a0, a1, float(i) / n)
		var tb := lerpf(a0, a1, float(i + 1) / n)
		var mid := (ta + tb) * 0.5
		var radial := Vector3(0.0, sin(mid), cos(mid))
		_quad(st, p.call(ta, r_out, -hw), p.call(tb, r_out, -hw), p.call(tb, r_out, hw),
				p.call(ta, r_out, hw), radial)
		_quad(st, p.call(ta, r_in, -hw), p.call(tb, r_in, -hw), p.call(tb, r_in, hw),
				p.call(ta, r_in, hw), -radial)
		for x in [-hw, hw]:
			_quad(st, p.call(ta, r_in, x), p.call(tb, r_in, x), p.call(tb, r_out, x),
					p.call(ta, r_out, x), Vector3(signf(x), 0.0, 0.0))
	for end in [[a0, -1.0], [a1, 1.0]]:
		var a: float = end[0]
		var t := Vector3(0.0, cos(a), -sin(a)) * float(end[1])
		_quad(st, p.call(a, r_in, -hw), p.call(a, r_out, -hw), p.call(a, r_out, hw),
				p.call(a, r_in, hw), t)
	return st.commit()


## One flat quad, its normal `out`, wound to face it.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		out: Vector3) -> void:
	if (b - a).cross(c - a).dot(out) > 0.0:
		var t := b
		b = d
		d = t
	st.set_normal(out)
	for v in [a, b, c, a, c, d]:
		st.add_vertex(v)


# ------------------------------------------------------------------------ hands

## Ask for this shape on this hand; it goes on when the hand is out of view.
func set_hand(side: int, kind: int) -> void:
	if _want[side] != kind:
		_want[side] = kind
		_waited[side] = 0.0


func shown_hand(side: int) -> int:
	return _shown[side]


func _swap_hands(delta: float) -> void:
	for side in 2:
		if _want[side] == _shown[side]:
			continue
		_waited[side] += delta
		var seen := _in_view(side)
		if _waited[side] < SWAP_GRACE and seen:
			continue
		if seen:
			swaps_in_view += 1
		_shown[side] = _want[side]
		var shapes: Array = _hands[side]
		for k in shapes.size():
			(shapes[k] as Node3D).visible = k == _shown[side]


## Is any of this hand on the screen? Its middle, and a hand's width round it.
func _in_view(side: int) -> bool:
	if camera == null:
		return false
	var xf := global_transform
	var c: Vector3 = _hole[side]
	for off in [Vector3.ZERO, Vector3(0.05, 0.0, 0.0), Vector3(-0.05, 0.0, 0.0),
			Vector3(0.0, 0.06, 0.0), Vector3(0.0, -0.06, 0.0)]:
		if camera.is_position_in_frustum(xf * (c + off)):
			return true
	return false


# ------------------------------------------------------------------------ pose

## Put the hands here: each the C's hole centre and its turn (see the header),
## camera-local. The arms follow by IK.
func pose(right: Transform3D, left: Transform3D, delta: float) -> void:
	if skeleton == null:
		return
	var targets := [right, left]
	for side in 2:
		var hole: Transform3D = targets[side]
		var b := hole.basis.orthonormalized()
		var wrist := hole.origin - b.y * HOLE_Y
		_hole[side] = hole.origin
		_arm(side, wrist, b)
	_swap_hands(delta)


func _arm(side: int, wrist: Vector3, hand_basis: Basis) -> void:
	var s: Vector3 = SHOULDER[side]
	var to := wrist - s
	var d := to.length()
	# Out of reach: the shoulder comes forward to it first, as a real one does.
	var over := d - (UPPER + FORE - 0.002)
	if over > 0.0:
		s += to / d * minf(over, SHOULDER_REACH)
		to = wrist - s
		d = to.length()
	var dir := to / maxf(d, 0.0001)
	# Out of reach: the arm goes straight, and the hand stays on what it holds.
	d = clampf(d, absf(UPPER - FORE) + 0.01, UPPER + FORE - 0.001)
	var pole: Vector3 = POLE[side]
	pole = pole.rotated(dir, float(swivel[side]) * (1.0 if side == RIGHT else -1.0))
	pole = (pole - dir * pole.dot(dir))
	if pole.length_squared() < 1e-6:
		pole = Vector3.DOWN - dir * dir.y
	pole = pole.normalized()
	# The elbow, by the law of cosines.
	var a := (UPPER * UPPER + d * d - FORE * FORE) / (2.0 * d)
	var h := sqrt(maxf(UPPER * UPPER - a * a, 0.0))
	var elbow := s + dir * a + pole * h
	var w := s + dir * d
	reach_gap[side] = w.distance_to(wrist)

	var arm_xf := Transform3D(_aim(elbow - s, pole), s)
	var fore_xf := Transform3D(_aim(w - elbow, pole), elbow)
	var hand_xf := Transform3D(hand_basis, w)
	var clav := int(_bone[bone_name(side, "Shoulder")])
	var arm := int(_bone[bone_name(side, "Arm")])
	var fore := int(_bone[bone_name(side, "ForeArm")])
	var hand := int(_bone[bone_name(side, "Hand")])
	var clav_xf := _rest_global(clav)
	_set_global(arm, clav_xf, arm_xf)
	_set_global(fore, arm_xf, fore_xf)
	_set_global(hand, fore_xf, hand_xf)


func _set_global(bone: int, parent_global: Transform3D, global: Transform3D) -> void:
	var local := parent_global.affine_inverse() * global
	skeleton.set_bone_pose_position(bone, local.origin)
	skeleton.set_bone_pose_rotation(bone, local.basis.orthonormalized().get_rotation_quaternion())


## A basis whose +Y runs along `along` and whose +Z leans toward `toward`.
static func _aim(along: Vector3, toward: Vector3) -> Basis:
	var y := along.normalized()
	var z := toward - y * toward.dot(y)
	if z.length_squared() < 1e-8:
		z = Vector3.BACK - y * y.z
		if z.length_squared() < 1e-8:
			z = Vector3.RIGHT
	z = z.normalized()
	var x := y.cross(z)
	return Basis(x, y, z)


## A hand basis from what passes through the hole (`hole_axis`, +X) and the way
## the fingers point out of the wrist (`fingers`, +Y, made square to it).
static func hand_basis(hole_axis: Vector3, fingers: Vector3) -> Basis:
	var x := hole_axis.normalized()
	var y := fingers - x * fingers.dot(x)
	if y.length_squared() < 1e-8:
		y = Vector3.UP - x * x.y
	y = y.normalized()
	return Basis(x, y, x.cross(y))
