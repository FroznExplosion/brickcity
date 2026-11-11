@tool
extends MeshInstance3D
## Builds a test brick (body + studs) that carries the per-brick data
## printed_plastic.gdshader reads:
##   CUSTOM0 = (centre xyz, mode)  mode 1 = box, 2 = stud
##   CUSTOM1 = box half extents, or (radius, half height, 0, 0) for studs
## Units: 1 = one stud pitch (8 mm). Remember to tick use_vertex_brick_data.

@export var studs_x := 4:
	set(v): studs_x = max(v, 1); _rebuild()
@export var studs_z := 2:
	set(v): studs_z = max(v, 1); _rebuild()
@export var body_height := 1.2:
	set(v): body_height = v; _rebuild()
@export var stud_radius := 0.3:
	set(v): stud_radius = v; _rebuild()
@export var stud_height := 0.2125:
	set(v): stud_height = v; _rebuild()
@export var stud_segments := 24:
	set(v): stud_segments = max(v, 6); _rebuild()

func _ready() -> void:
	_rebuild()

func _rebuild() -> void:
	if not is_inside_tree():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	st.set_custom_format(1, SurfaceTool.CUSTOM_RGBA_FLOAT)

	var half := Vector3(studs_x * 0.5, body_height * 0.5, studs_z * 0.5)
	var centre := Vector3(0.0, body_height * 0.5, 0.0)
	_add_box(st, centre, half)

	var sh := stud_height * 0.5
	for ix in studs_x:
		for iz in studs_z:
			var c := Vector3(ix - (studs_x - 1) * 0.5, body_height + sh, iz - (studs_z - 1) * 0.5)
			_add_stud(st, c, stud_radius, sh)

	mesh = st.commit()

func _set_data(st: SurfaceTool, centre: Vector3, mode: float, b: Vector4) -> void:
	st.set_custom(0, Color(centre.x, centre.y, centre.z, mode))
	st.set_custom(1, Color(b.x, b.y, b.z, b.w))

func _tri(st: SurfaceTool, n: Vector3, a: Vector3, b: Vector3, c: Vector3, centre: Vector3, mode: float, data: Vector4) -> void:
	# Godot treats clockwise triangles (seen from the front) as front-facing,
	# so emit in whichever order is clockwise relative to the normal.
	var order := [a, b, c] if (b - a).cross(c - a).dot(n) < 0.0 else [a, c, b]
	for v in order:
		st.set_normal(n)
		_set_data(st, centre, mode, data)
		st.add_vertex(v)

func _quad(st: SurfaceTool, n: Vector3, a: Vector3, b: Vector3, c: Vector3, d: Vector3, centre: Vector3, mode: float, data: Vector4) -> void:
	# a, b, c, d go around the quad in order (either direction)
	_tri(st, n, a, b, c, centre, mode, data)
	_tri(st, n, a, c, d, centre, mode, data)

func _add_box(st: SurfaceTool, c: Vector3, h: Vector3) -> void:
	var data := Vector4(h.x, h.y, h.z, 0.0)
	var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for i in 3:
		var u: Vector3 = axes[(i + 1) % 3] * h[(i + 1) % 3]
		var v: Vector3 = axes[(i + 2) % 3] * h[(i + 2) % 3]
		for sgn in [1.0, -1.0]:
			var n: Vector3 = axes[i] * sgn
			var fc: Vector3 = c + n * h[i]
			_quad(st, n, fc - u - v, fc + u - v, fc + u + v, fc - u + v, c, 1.0, data)

func _add_stud(st: SurfaceTool, c: Vector3, r: float, hh: float) -> void:
	var data := Vector4(r, hh, 0.0, 0.0)
	var top := c.y + hh
	var bottom := c.y - hh
	for i in stud_segments:
		var a0 := TAU * i / stud_segments
		var a1 := TAU * (i + 1) / stud_segments
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		var p0 := Vector3(c.x, 0.0, c.z) + d0 * r
		var p1 := Vector3(c.x, 0.0, c.z) + d1 * r
		var n := (d0 + d1).normalized()
		# side
		_quad(st, n,
			Vector3(p0.x, bottom, p0.z), Vector3(p1.x, bottom, p1.z),
			Vector3(p1.x, top, p1.z), Vector3(p0.x, top, p0.z), c, 2.0, data)
		# cap
		_tri(st, Vector3.UP, Vector3(c.x, top, c.z), Vector3(p1.x, top, p1.z), Vector3(p0.x, top, p0.z), c, 2.0, data)
