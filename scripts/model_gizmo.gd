class_name ModelGizmo
extends Node3D

## The gizmo on a placed model (Docs/AssetWorkshop.md, "SDF tools, round 4"): three arrows
## move it along x, y and z, three rings turn it about them, the cube in the middle resizes
## it evenly. Drawn over everything and kept the same size on screen. It only says what a
## drag means; the workshop moves the model.

const AXES: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const COLOURS: Array[Color] = [Color(0.95, 0.3, 0.3), Color(0.4, 0.9, 0.35), Color(0.35, 0.55, 1.0)]
const HOVER := Color(1.0, 0.9, 0.3)
## In gizmo units: an arrow's length, a ring's radius, half the cube, how near the mouse's
## ray must pass a handle.
const ARROW := 1.0
const RING := 0.72
const CUBE := 0.11
const PICK := 0.08
## The gizmo's size: this share of its distance from the camera (an orthographic view:
## of the view's height).
const SCREEN := 0.16

var hover := ""
var _mats := {}   # handle -> material
## The drag under way: which handle, where it started.
var _drag := ""
var _s0 := 0.0
var _v0 := Vector3.ZERO
var _m0 := Vector2.ZERO
var _c0 := Vector2.ZERO


func _init() -> void:
	for i in 3:
		var up := _y_to(AXES[i])
		var shaft := CylinderMesh.new()
		shaft.top_radius = 0.018
		shaft.bottom_radius = 0.018
		shaft.height = 0.7
		var tip := CylinderMesh.new()
		tip.top_radius = 0.0
		tip.bottom_radius = 0.06
		tip.height = 0.18
		_add("move%d" % i, [[shaft, Transform3D(up, up * Vector3(0, 0.5, 0))],
				[tip, Transform3D(up, up * Vector3(0, ARROW - 0.09, 0))]], COLOURS[i])
		var ring := TorusMesh.new()
		ring.inner_radius = RING - 0.015
		ring.outer_radius = RING + 0.015
		ring.rings = 48
		_add("turn%d" % i, [[ring, Transform3D(up, Vector3.ZERO)]], COLOURS[i])
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * CUBE * 2.0
	_add("size", [[cube, Transform3D()]], Color(0.95, 0.95, 0.95))


## A basis turning +Y onto `axis`.
static func _y_to(axis: Vector3) -> Basis:
	if axis == Vector3.RIGHT:
		return Basis(Vector3.BACK, -PI * 0.5)
	if axis == Vector3.BACK:
		return Basis(Vector3.RIGHT, PI * 0.5)
	return Basis()


func _add(id: String, parts: Array, col: Color) -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.render_priority = 10
	m.albedo_color = col
	_mats[id] = m
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p[0]
		mi.transform = p[1]
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


func _process(_dt: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or not visible:
		return
	var s := cam.size * SCREEN if cam.projection == Camera3D.PROJECTION_ORTHOGONAL \
			else cam.global_position.distance_to(global_position) * SCREEN
	scale = Vector3.ONE * maxf(s, 0.001)


## Light the handle the mouse is over.
func set_hover(id: String) -> void:
	if id == hover:
		return
	hover = id
	for k in _mats:
		(_mats[k] as StandardMaterial3D).albedo_color = HOVER if k == id else _colour(k)


static func _colour(id: String) -> Color:
	if id == "size":
		return Color(0.95, 0.95, 0.95)
	return COLOURS[int(id.right(1))]


## The handle a ray (global) passes nearest, "" for none: the cube first, then the nearest
## arrow or ring along the ray.
func pick(from: Vector3, dir: Vector3) -> String:
	var inv := global_transform.affine_inverse()
	var o := inv * from
	var d := (inv.basis * dir).normalized()
	if _hits_box(o, d, Vector3.ONE * CUBE * 1.4):
		return "size"
	var best := ""
	var best_t := INF
	for i in 3:
		var a := AXES[i]
		# An arrow: the ray passes near its shaft.
		var c := _closest(Vector3.ZERO, a, o, d)
		if c.x > 0.12 and c.x < ARROW and c.z < PICK * 1.5 and c.y < best_t:
			best = "move%d" % i
			best_t = c.y
		# A ring: where the ray meets its plane, near its circle.
		var dn := d.dot(a)
		if absf(dn) > 1e-4:
			var t := -o.dot(a) / dn
			if t > 0.0 and absf((o + d * t).length() - RING) < PICK and t < best_t:
				best = "turn%d" % i
				best_t = t
	return best


static func _hits_box(o: Vector3, d: Vector3, half: Vector3) -> bool:
	var t0 := -INF
	var t1 := INF
	for k in 3:
		if absf(d[k]) < 1e-8:
			if absf(o[k]) > half[k]:
				return false
			continue
		var a := (-half[k] - o[k]) / d[k]
		var b := (half[k] - o[k]) / d[k]
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	return t1 >= maxf(t0, 0.0)


## The line p + s a against the ray o + t d (a, d unit): (s, t, distance) at their
## nearest.
static func _closest(p: Vector3, a: Vector3, o: Vector3, d: Vector3) -> Vector3:
	var w := p - o
	var b := a.dot(d)
	var den := 1.0 - b * b
	if den < 1e-6:
		return Vector3(0.0, 0.0, INF)
	var s := (b * d.dot(w) - a.dot(w)) / den
	var t := (d.dot(w) - b * a.dot(w)) / den
	return Vector3(s, t, ((p + a * s) - (o + d * t)).length())


## Start dragging `id` from this ray and mouse position.
func begin(id: String, from: Vector3, dir: Vector3, mouse: Vector2, cam: Camera3D) -> void:
	_drag = id
	_m0 = mouse
	_c0 = cam.unproject_position(global_position)
	if id.begins_with("move"):
		_s0 = _closest(global_position, AXES[int(id.right(1))], from, dir.normalized()).x
	elif id.begins_with("turn"):
		_v0 = _on_ring_plane(AXES[int(id.right(1))], from, dir)


func dragging() -> String:
	return _drag


func end() -> void:
	_drag = ""


## What the drag has done since it began, in workshop space: {move: Vector3} along an
## axis, {turn: [axis, radians]} about one through the gizmo, or {size: factor} about it.
## The gizmo stays where it began until `begin` again (the workshop moves it).
func drag_delta(from: Vector3, dir: Vector3, mouse: Vector2) -> Dictionary:
	if _drag.begins_with("move"):
		var a := AXES[int(_drag.right(1))]
		var c := _closest(global_position, a, from, dir.normalized())
		return {"move": a * (c.x - _s0)}
	if _drag.begins_with("turn"):
		var a := AXES[int(_drag.right(1))]
		var v := _on_ring_plane(a, from, dir)
		if v == Vector3.ZERO or _v0 == Vector3.ZERO:
			return {"turn": [a, 0.0]}
		return {"turn": [a, atan2(a.dot(_v0.cross(v)), _v0.dot(v))]}
	if _drag == "size":
		var r0 := maxf((_m0 - _c0).length(), 8.0)
		return {"size": maxf((mouse - _c0).length(), 1.0) / r0}
	return {}


## Where a ray meets the plane through the gizmo across `a`, from the gizmo; ZERO if it
## runs along the plane.
func _on_ring_plane(a: Vector3, from: Vector3, dir: Vector3) -> Vector3:
	var h = Plane(a, global_position).intersects_ray(from, dir)
	if h == null:
		return Vector3.ZERO
	return (h as Vector3) - global_position
