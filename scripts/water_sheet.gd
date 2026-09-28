class_name WaterSheet
extends MeshInstance3D

## The smooth sea: everything past the studded tier, out to the world's edge.
## [Docs/Water.md](../Docs/Water.md) §3.2, §8.
##
## Tier 0 is real 1x1 bricks to 20 m round the camera. This is the rest --
## there is no tier of coarse bricks between them any more (§8): it was a
## ring of 1.4 m blocks that read as a blocky donut, and it cost more than
## the sheet that replaced it.
##
## This is NOT bricks. At 80 m a 0.35 m piece is under a pixel, and a tier
## made of them would cost 64k instances to say "blue". It is a static mesh
## whose cells double in size with distance — the same cascade the terrain's
## coarse tier uses, and for the same reason — displaced in the vertex shader
## by the one wave function. No steps, no studs, no print: at this range the
## surface is a colour with a slope.
##
## It FOLLOWS the camera, snapped to its finest cell, and is filled right to
## the middle; a hole in the shader (`hole_centre`, `hole_radius`) is where
## the studded tier draws instead. Built once round the world's origin, the
## fine rings and the hole stayed THERE: anywhere else the sheet and the
## bricks drew the same water and flickered through each other.
##
## Each vertex carries its ring's spacing in UV2.x, so the shader drops the
## waves too short for it -- under ~4 samples a wavelength a crest lands
## between vertices and the surface boils.

## Where the finest ring ends. It starts at the middle, but the studded tier
## covers the first 40 m, so this ring is only SEEN from 40 to 80.
@export var inner_radius := 80.0
## How far the sheet reaches, in metres.
@export var outer_radius := 600.0
## The finest cell: eight studs. Still over four samples a crest for the
## shore band (15 m) and the swell.
@export var base_cell := 2.8
## How many doublings past the first ring.
@export var levels := 6

var _mat: ShaderMaterial = null
var _tris := 0


func build(seabed: Texture2D, origin: Vector2, extent: Vector2) -> void:
	mesh = _ring_mesh()
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/water.gdshader")
	_mat.set_shader_parameter("waves", BrickWave.uniform_array())
	_mat.set_shader_parameter("wave_count", BrickWave.component_count())
	_mat.set_shader_parameter("groups", BrickWave.group_uniform_array())
	_mat.set_shader_parameter("group_count", BrickWave.group_uniform_array().size() >> 1)
	_mat.set_shader_parameter("shore_band", BrickWave.shore_band_uniform())
	_mat.set_shader_parameter("swell_blend", BrickWave.swell_blend_uniform())
	_mat.set_shader_parameter("lod_base_cell", base_cell)
	_mat.set_shader_parameter("lod_inner_radius", inner_radius)
	_mat.set_shader_parameter("sea_level", BrickWave.get_sea_level())
	_mat.set_shader_parameter("step_m", BrickWave.get_step_metres())
	_mat.set_shader_parameter("shore_taper_depth", BrickWave.get_shore_taper_depth())
	# The sheet is already in world space, so the instancing path is off.
	_mat.set_shader_parameter("sheet_mode", true)
	# Past the edge of the seabed map is OPEN SEA, not dry land: it was dry,
	# so from the world's edge looking out the water sank out of sight.
	_mat.set_shader_parameter("water_outside_field", true)
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


func set_lod_debug(on: bool) -> void:
	if _mat != null:
		_mat.set_shader_parameter("lod_debug", on)


## Every frame: the clock, where the camera is, and the hole the studded tier
## fills (radius 0 when it is not drawing).
func follow(time: float, camera_xz := Vector2.ZERO, hole_centre := Vector2.ZERO,
		hole_radius := 0.0) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("wave_time", time)
	_mat.set_shader_parameter("hole_centre", hole_centre)
	_mat.set_shader_parameter("hole_radius", hole_radius)
	# Snapped to the finest cell, so the rings that can show a wave never
	# slide over it; the coarse rings shift by a fraction of their own cell,
	# and only carry waves long enough not to notice.
	position = Vector3(roundf(camera_xz.x / base_cell) * base_cell, 0.0,
			roundf(camera_xz.y / base_cell) * base_cell)


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
	# The first ring is FILLED, from the middle to `inner_radius`.
	var inner := 0.0
	var cell := base_cell
	for level in levels + 1:
		if inner >= outer_radius:
			break
		var outer: float = inner_radius if level == 0 else minf(outer_radius, inner * 2.0)
		if level == levels:
			outer = outer_radius
		# Snap both edges to this ring's cell size.
		var lo := floorf(inner / cell) * cell
		# The outer edge on the NEXT ring's lattice, so that ring starts
		# exactly here. On this ring's own lattice the two overlapped by up
		# to a cell and drew the same water twice.
		var hi := ceilf(outer / (cell * 2.0)) * cell * 2.0
		if level == levels:
			hi = ceilf(outer / cell) * cell
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
				# With a tolerance: -358.4 + 16 * 11.2 lands a hair INSIDE 179.2
				# in floating point, and without it the whole first row of
				# every ring was dropped -- a band of nothing one coarse cell
				# wide at each ring border (Water.md 9.9).
				if maxf(near_x, near_z) < lo - cell * 0.01:
					continue
				# The outer edge, where the next ring (twice the cell) meets
				# this one: its vertices off the next ring's lattice are
				# stitched to it in the shader.
				_quad(st, x0, z0, x1, z1, cell, hi if level < levels else -1.0)
		inner = hi
		cell *= 2.0
	# Normals are set per vertex (straight up); the shader lights the wave.
	var m := st.commit()
	_tris = 0
	if m.get_surface_count() > 0:
		@warning_ignore("integer_division")
		_tris = m.surface_get_array_len(0) / 3
	return m


func _quad(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float,
		cell: float, edge := -1.0) -> void:
	var a := Vector3(x0, 0.0, z0)
	var b := Vector3(x1, 0.0, z0)
	var c := Vector3(x1, 0.0, z1)
	var d := Vector3(x0, 0.0, z1)
	for v in [a, b, c, a, c, d]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x, v.z))
		# This ring's vertex spacing, and whether the vertex is on the ring's
		# outer edge between two of the next ring's vertices: 2 along X, 3
		# along Z.
		var flag := 0.0
		if edge > 0.0:
			var on_x := absf(absf(v.z) - edge) < 1e-3
			var on_z := absf(absf(v.x) - edge) < 1e-3
			var odd_x := absf(fposmod(v.x, cell * 2.0) - cell) < 1e-3
			var odd_z := absf(fposmod(v.z, cell * 2.0) - cell) < 1e-3
			if on_x and odd_x:
				flag = 2.0
			elif on_z and odd_z:
				flag = 3.0
		st.set_uv2(Vector2(cell, flag))
		st.add_vertex(v)
