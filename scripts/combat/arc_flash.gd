class_name ArcFlash
extends MeshInstance3D
## The flash of a shock arc (COMBAT_DESIGN 7.2): a jagged bright line through every point
## it jumped to, gone in a moment.

const SECONDS := 0.3
const JAG := 0.18

var _t := 0.0
var _mat: StandardMaterial3D


static func spawn(parent: Node, points: PackedVector3Array,
		colour := Color(0.65, 0.8, 1.0)) -> void:
	if parent == null or not (parent is Node3D) or points.size() < 2:
		return
	# Cosmetic only: its own stream, so the jag never moves a combat roll.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(points)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var prev := a
		var steps := maxi(2, int(a.distance_to(b) / 0.6))
		for k in range(1, steps + 1):
			var p := a.lerp(b, float(k) / float(steps))
			if k < steps:
				p += Vector3(rng.randf_range(-JAG, JAG), rng.randf_range(-JAG, JAG),
						rng.randf_range(-JAG, JAG))
			im.surface_add_vertex(prev)
			im.surface_add_vertex(p)
			prev = p
	im.surface_end()
	var f := ArcFlash.new()
	f.mesh = im
	f._mat = StandardMaterial3D.new()
	f._mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	f._mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	f._mat.albedo_color = colour
	f.material_override = f._mat
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(f)
	f.global_transform = Transform3D.IDENTITY


func _process(delta: float) -> void:
	_t += delta
	var k := clampf(_t / SECONDS, 0.0, 1.0)
	_mat.albedo_color.a = 1.0 - k
	if k >= 1.0:
		queue_free()
