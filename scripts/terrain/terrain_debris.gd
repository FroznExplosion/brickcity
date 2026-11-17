extends Node3D

## Bricks thrown off the ground by a hit: the terrain bench's blast and the
## mine world's shots (Docs/MineWorld.md 10). One node owns them, capped and
## swept, because a blast that removes two thousand plates must not become two
## thousand bodies -- the same debris budget M4 settled on for buildings.
##
## Preloaded by path, not named (see terrain_scene.gd).

const CAP := 160
const LIFE := 7.0

var bodies: Array[RigidBody3D] = []

static var _mats := {}


## Nine floats a brick: position, size, colour (BrickTerrain.carve's and
## break_brick's "debris"). Thrown outward from `origin`.
func spawn(buf: PackedFloat32Array, origin: Vector3) -> void:
	@warning_ignore("integer_division")
	var n := buf.size() / 9
	for i in n:
		if bodies.size() >= CAP:
			break
		var o := i * 9
		var pos := Vector3(buf[o], buf[o + 1], buf[o + 2])
		var size := Vector3(buf[o + 3], buf[o + 4], buf[o + 5])
		var col := Color(buf[o + 6], buf[o + 7], buf[o + 8])

		var body := RigidBody3D.new()
		body.collision_layer = Layers.RUBBLE
		body.collision_mask = Layers.RUBBLE_MASK
		body.position = pos
		var shape := BoxShape3D.new()
		shape.size = size
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = PieceMeshes.chamfered_box(size)
		# The same printed plastic the ground is, layer lines and all -- in
		# OBJECT space, so the lines tumble with it.
		mi.material_override = material(col)
		body.add_child(mi)
		add_child(body)
		var away := (pos - origin).normalized() + Vector3.UP * 0.5
		body.linear_velocity = away * randf_range(3.0, 7.0)
		body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
		bodies.append(body)
		var timer := get_tree().create_timer(LIFE)
		timer.timeout.connect(func() -> void:
			bodies.erase(body)
			if is_instance_valid(body):
				body.queue_free())


func clear() -> void:
	for body in bodies:
		if is_instance_valid(body):
			body.queue_free()
	bodies.clear()


## One printed-plastic material per colour. The mesh carries no vertex
## colours, so the shader's `tint` supplies it.
static func material(col: Color) -> ShaderMaterial:
	# Rounded: every brick's tint is a little different, and one material a
	# colour grew without end.
	col = Color(snappedf(col.r, 1.0 / 32.0), snappedf(col.g, 1.0 / 32.0), snappedf(col.b, 1.0 / 32.0))
	if _mats.has(col):
		return _mats[col]
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/printed.gdshader")
	mat.set_shader_parameter("tint", col)
	_mats[col] = mat
	return mat
