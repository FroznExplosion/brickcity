class_name PlanetGraph
extends RefCounted

## The planet's ground as a compiled VoxelGeneratorGraph (Docs/Planets.md 11.1).
## After STA's `PlanetGraphBuilder` (its noise-layer path), without caves or
## islands: generation runs in Zylann's native graph runtime, no GDScript per
## voxel.
##
## SDF convention: negative is solid.
##   h     = amplitude * ridged(noise(p))        the relief, PlanetData.relief
##   h     = lerp(h, pad.height, w(pad)) ...     each pad levels the ground
##   sdf   = |p| - radius - h
##   sdf   = min(sdf, |p| - core_radius)         solid core
## w(pad) = clamp((flat + blend - |p - pad.dir * radius|) / blend, 0, 1): level
## inside `flat`, blended into the natural ground over `blend`. Must stay in
## step with PlanetData.height, which the CPU side asks.

static func build(data: PlanetData) -> VoxelGeneratorGraph:
	var g := VoxelGeneratorGraph.new()
	var f := g.get_main_function()
	f.clear()
	var x := f.create_node(VoxelGraphFunction.NODE_INPUT_X, Vector2(-900, 0))
	var y := f.create_node(VoxelGraphFunction.NODE_INPUT_Y, Vector2(-900, 80))
	var z := f.create_node(VoxelGraphFunction.NODE_INPUT_Z, Vector2(-900, 160))

	# The relief, sampled on the datum sphere under the voxel (its direction
	# times the radius), as PlanetData.relief does: the ground is then a true
	# height over each direction, and the CPU's answer is the voxels'. The noise
	# is 3D, so on a sphere it has no seams.
	var nm := f.create_node(VoxelGraphFunction.NODE_NORMALIZE_3D, Vector2(-820, 200))
	_wire3(f, x, y, z, nm)
	var n := f.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D, Vector2(-700, 200))
	f.set_node_param_by_name(n, "noise", data.height_noise())
	var on_datum: Array[int] = []   # the voxel's direction times the radius
	for k in 3:
		var s := f.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(-760, 200 + k * 40))
		f.add_connection(nm, k, s, 0)
		f.set_node_default_input(s, 1, data.radius)
		f.add_connection(s, 0, n, k)
		on_datum.append(s)
	var h := n
	if data.ridged:
		var a := f.create_node(VoxelGraphFunction.NODE_ABS, Vector2(-560, 260))
		f.add_connection(n, 0, a, 0)
		var a2 := _mul(f, a, 2.0, Vector2(-440, 260))
		var rg := f.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(-320, 260))
		f.set_node_default_input(rg, 0, 1.0)
		f.add_connection(a2, 0, rg, 1)
		h = rg
	h = _mul(f, h, data.amplitude, Vector2(-200, 200))

	# Pads: h += w * (pad.height - h).
	var row := 0
	for pad in data.pads:
		var c: Vector3 = (pad.dir as Vector3).normalized() * data.radius
		var d := f.create_node(VoxelGraphFunction.NODE_DISTANCE_3D, Vector2(-700, 400 + row * 120))
		# From the point on the datum under the voxel, as PlanetData.height.
		for k in 3:
			f.add_connection(on_datum[k], 0, d, k)
		# The centre through Constant nodes: an unwired x1/y1/z1 is
		# auto-connected to the voxel's own position, a distance of nothing.
		for k in 3:
			var cn := f.create_node(VoxelGraphFunction.NODE_CONSTANT, Vector2(-900, 400 + row * 120 + k * 30))
			f.set_node_param(cn, 0, c[k])
			f.add_connection(cn, 0, d, 3 + k)
		var blend := maxf(float(pad.blend), 0.001)
		# w = clamp((flat + blend - d) / blend, 0, 1) = clamp(d * -1/blend + (flat+blend)/blend)
		var lin := _mad(f, d, -1.0 / blend, (float(pad.flat) + blend) / blend, Vector2(-560, 400 + row * 120))
		var w := _clamp01(f, lin, Vector2(-420, 400 + row * 120))
		var diff := f.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(-280, 400 + row * 120))
		f.set_node_default_input(diff, 0, float(pad.height))
		f.add_connection(h, 0, diff, 1)
		var step := f.create_node(VoxelGraphFunction.NODE_MULTIPLY, Vector2(-160, 400 + row * 120))
		f.add_connection(w, 0, step, 0)
		f.add_connection(diff, 0, step, 1)
		var nh := f.create_node(VoxelGraphFunction.NODE_ADD, Vector2(-40, 400 + row * 120))
		f.add_connection(h, 0, nh, 0)
		f.add_connection(step, 0, nh, 1)
		h = nh
		row += 1

	# sdf = sphere(radius) - h, then the core held solid.
	var sphere := f.create_node(VoxelGraphFunction.NODE_SDF_SPHERE, Vector2(0, 0))
	f.set_node_default_input_by_name(sphere, "radius", data.radius)
	var sdf := f.create_node(VoxelGraphFunction.NODE_SUBTRACT, Vector2(200, 0))
	f.add_connection(sphere, 0, sdf, 0)
	f.add_connection(h, 0, sdf, 1)
	var core := f.create_node(VoxelGraphFunction.NODE_SDF_SPHERE, Vector2(200, 120))
	f.set_node_default_input_by_name(core, "radius", data.core_radius)
	var solid := f.create_node(VoxelGraphFunction.NODE_MIN, Vector2(380, 0))
	f.add_connection(sdf, 0, solid, 0)
	f.add_connection(core, 0, solid, 1)
	var out := f.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(560, 0))
	f.add_connection(solid, 0, out, 0)
	var res: Dictionary = g.compile()
	if not res.get("success", false):
		push_error("PlanetGraph: compile failed: %s (node %s)" % [res.get("message", "?"), res.get("node_id", -1)])
	return g


static func _wire3(f: VoxelGraphFunction, x: int, y: int, z: int, node: int) -> void:
	f.add_connection(x, 0, node, 0)
	f.add_connection(y, 0, node, 1)
	f.add_connection(z, 0, node, 2)


static func _mul(f: VoxelGraphFunction, src: int, k: float, pos: Vector2) -> int:
	var m := f.create_node(VoxelGraphFunction.NODE_MULTIPLY, pos)
	f.add_connection(src, 0, m, 0)
	f.set_node_default_input(m, 1, k)
	return m


## src * a + b.
static func _mad(f: VoxelGraphFunction, src: int, a: float, b: float, pos: Vector2) -> int:
	var m := _mul(f, src, a, pos)
	var ad := f.create_node(VoxelGraphFunction.NODE_ADD, pos + Vector2(60, 0))
	f.add_connection(m, 0, ad, 0)
	f.set_node_default_input(ad, 1, b)
	return ad


static func _clamp01(f: VoxelGraphFunction, src: int, pos: Vector2) -> int:
	var mx := f.create_node(VoxelGraphFunction.NODE_MAX, pos)
	f.add_connection(src, 0, mx, 0)
	f.set_node_default_input(mx, 1, 0.0)
	var mn := f.create_node(VoxelGraphFunction.NODE_MIN, pos + Vector2(70, 0))
	f.add_connection(mx, 0, mn, 0)
	f.set_node_default_input(mn, 1, 1.0)
	return mn
