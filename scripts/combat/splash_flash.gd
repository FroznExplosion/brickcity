class_name SplashFlash
extends MeshInstance3D
## The flash of an explosive round's burst (COMBAT_DESIGN 6.1): a glowing ball that
## swells to the burst's radius and fades, so the player sees what the splash reached.

const SECONDS := 0.25

var _t := 0.0
var _radius := 1.0
var _mat: StandardMaterial3D


static func spawn(parent: Node, at: Vector3, radius: float,
		colour := Color(1.0, 0.6, 0.2)) -> void:
	if parent == null:
		return
	var f := SplashFlash.new()
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	f.mesh = mesh
	f._mat = StandardMaterial3D.new()
	f._mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	f._mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	f._mat.albedo_color = colour
	f.material_override = f._mat
	f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	f._radius = radius
	f.scale = Vector3.ONE * 0.1
	parent.add_child(f)
	f.global_position = at


func _process(delta: float) -> void:
	_t += delta
	var k := clampf(_t / SECONDS, 0.0, 1.0)
	scale = Vector3.ONE * maxf(_radius * (0.3 + 0.7 * k), 0.01)
	_mat.albedo_color.a = 0.55 * (1.0 - k)
	if k >= 1.0:
		queue_free()
