class_name WaterSheet
extends MeshInstance3D

## Water tier 2: one sheet from the brick tiers out to the world's edge.
## [Docs/Water.md](../Docs/Water.md) §3.2.
##
## Tier 0 is real 1x1 bricks to 20 m and tier 1 is coarse bricks to 80 m.
## Past that the sea simply stopped, which was invisible while the terrain
## stopped at 56 m and glaring the moment it reached 560: from any hilltop
## the ocean ended in mid-air.
##
## This is NOT bricks. At 80 m a 0.35 m piece is under a pixel, and a tier
## made of them would cost 64k instances to say "blue". It is a static mesh
## whose cells double in size with distance — the same cascade the terrain's
## coarse tier uses, and for the same reason — displaced in the vertex shader
## by the one wave function. No steps, no studs, no print: at this range the
## surface is a colour with a slope.
##
## It is built once. The world has edges, so the sheet has edges, and neither
## has to follow the camera.

## Where tier 1 stops and this begins.
@export var inner_radius := 76.0
## The world's half-extent, in metres.
@export var outer_radius := 600.0
## The finest cell, at the inner edge. Doubles every ring.
@export var base_cell := 8.0
## How many doublings. Six takes an 8 m cell to 256 m.
@export var levels := 6

var _mat: ShaderMaterial = null
var _tris := 0


func build(seabed: Texture2D, origin: Vector2, extent: Vector2) -> void:
	mesh = _ring_mesh()
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/water.gdshader")
	_mat.set_shader_parameter("waves", BrickWave.uniform_array())
	_mat.set_shader_parameter("wave_count", BrickWave.component_count())
	_mat.set_shader_parameter("sea_level", BrickWave.get_sea_level())
	_mat.set_shader_parameter("step_m", BrickWave.get_step_metres())
	_mat.set_shader_parameter("shore_taper_depth", BrickWave.get_shore_taper_depth())
	# The sheet is already in world space, so the instancing path is off.
	_mat.set_shader_parameter("sheet_mode", true)
	_mat.set_shader_parameter("studs_enabled", false)
	_mat.set_shader_parameter("print_lines_enabled", false)
	_mat.set_shader_parameter("seabed_tex", seabed)
	_mat.set_shader_parameter("seabed_origin", origin)
	_mat.set_shader_parameter("seabed_extent", extent)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Displaced in the vertex shader, so Godot's own bounds are wrong.
	custom_aabb = AABB(Vector3(-outer_radius, -60.0, -outer_radius),
		Vector3(outer_radius * 2.0, 200.0, outer_radius * 2.0))


func follow(time: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("wave_time", time)


func triangle_count() -> int:
	return _tris


## Concentric square rings of quads, each ring twice the cell size of the
## one inside it. Cells are laid on their own lattice so a ring's inner edge
## lands on the coarser ring's grid — the same alignment argument the
## terrain's cascade makes, and the same reason: off-lattice rings leave
## cracks, and a crack in water is a hole through to the sky.
func _ring_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inner := inner_radius
	var cell := base_cell
	for level in levels:
		if inner >= outer_radius:
			break
		var outer: float = minf(outer_radius, inner * 2.0)
		if level == levels - 1:
			outer = outer_radius
		# Snap both edges to this ring's cell size.
		var lo := floorf(inner / cell) * cell
		var hi := ceilf(outer / cell) * cell
		var n := int((hi + hi) / cell)
		for iz in n:
			for ix in n:
				var x0 := -hi + float(ix) * cell
				var z0 := -hi + float(iz) * cell
				var x1 := x0 + cell
				var z1 := z0 + cell
				# Keep the cell only if it is in THIS ring's annulus: its
				# nearest corner outside the inner square, so the ring
				# inside it owns everything closer.
				var near_x: float = 0.0 if x0 <= 0.0 and x1 >= 0.0 else minf(absf(x0), absf(x1))
				var near_z: float = 0.0 if z0 <= 0.0 and z1 >= 0.0 else minf(absf(z0), absf(z1))
				if maxf(near_x, near_z) < lo:
					continue
				_quad(st, x0, z0, x1, z1)
		inner = hi
		cell *= 2.0
	st.generate_normals()
	var m := st.commit()
	_tris = 0
	if m.get_surface_count() > 0:
		_tris = m.surface_get_array_len(0) / 3
	return m


func _quad(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float) -> void:
	var a := Vector3(x0, 0.0, z0)
	var b := Vector3(x1, 0.0, z0)
	var c := Vector3(x1, 0.0, z1)
	var d := Vector3(x0, 0.0, z1)
	for v in [a, b, c, a, c, d]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x, v.z))
		st.add_vertex(v)
