extends RefCounted

## Test 9 of the sphere-planet feasibility tests (Docs/Planets.md 10b): what
## a MOVING sun costs the ground. Run by tools/planet_passes.gd on the terrain
## city, windowed, with the editor closed (a timing run):
##   res://scenes/city.tscn -- --terrain --planet=sun
##
## Today the ground bakes its sun shadow into the tiles at build time
## (Terrain.md 19.9: 3.3 ms a frame against 4.9 casting) and never enters the
## shadow map. A day cycle either
##   (B) puts the terrain back in the shadow map (`shadow_radius` 3, as 19.9
##       measured), the sun turning every frame, or
##   (C) keeps baking, and re-bakes the detail tiles every STEP_DEG of sun --
##       a tile is 2.9 ms on a worker, but it is assembled and uploaded on
##       the main thread.
## Against (A), the sun baked and still. Draw cost is the renderer's own clock
## (viewport_get_measured_render_time_*: a test window's frames are pinned at
## 16.6 ms), plus the script's process time.

const FRAMES := 300
const STEP_DEG := 2.0
const TURN_DEG := 0.05   # a frame: 2 degrees every 40 frames, a fast day

var p
var city: Node3D


func _init(pass_node) -> void:
	p = pass_node
	city = pass_node.city


func run() -> void:
	var c = city
	if not c._terrain_mode:
		print("[planet] sun: FAIL needs --terrain")
		return
	await p._frames(60)
	var vp := c.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	# A street-level view over the city and the hills.
	var cam: Camera3D = c.camera
	cam.global_position = Vector3(-60.0, p._ground_y(Vector3(-60.0, 0.0, -60.0)) + 8.0, -60.0)
	cam.look_at(Vector3(30.0, p._ground_y(Vector3(30.0, 0.0, 30.0)) + 4.0, 30.0), Vector3.UP)
	cam.reset_physics_interpolation()
	await p._frames(120)
	var st: TerrainStreamer = c._terrain_streamer
	print("[planet] sun: %d detail tiles; sun pitch %.0f deg" % [st.tile_count(), c._sun.rotation_degrees.x])

	var a := await _measure("A baked, the sun still", 0.0, false)
	st.shadow_radius = 3
	st._shadow_centre = Vector2i(1 << 30, 0)
	await p._frames(30)
	var b := await _measure("B terrain in the shadow map (radius 3), the sun turning", TURN_DEG, false)
	st.shadow_radius = 0
	st._shadow_centre = Vector2i(1 << 30, 0)
	await p._frames(30)
	var cc := await _measure("C baked, re-baked every %.0f deg of sun" % STEP_DEG, TURN_DEG, true)
	print("[planet] sun summary (ms a frame: render CPU, render GPU, script process; mean / 95th / worst)")
	for r in [a, b, cc]:
		print("  %-58s cpu %.2f / %.2f / %.2f   gpu %.2f / %.2f / %.2f   process %.2f / %.2f / %.2f" % r)


## FRAMES frames: the renderer's CPU and GPU time and the process time, each
## as [mean, 95th, worst]. `turn` degrees of sun a frame; `rebake` re-bakes
## the detail tiles every STEP_DEG.
func _measure(what: String, turn: float, rebake: bool) -> Array:
	var c = city
	var st: TerrainStreamer = c._terrain_streamer
	var vp := c.get_viewport().get_viewport_rid()
	var cpu: Array[float] = []
	var gpu: Array[float] = []
	var proc: Array[float] = []
	var turned := 0.0
	var rebakes := 0
	var rebake_frames: Array[int] = []
	var pending_since := -1
	for f in FRAMES:
		if turn != 0.0:
			c._sun.rotation_degrees.y += turn
			turned += turn
			if rebake and turned >= STEP_DEG:
				turned = 0.0
				# The baked shadow is cast from the light: tell the mesher and
				# the material, then rebuild the detail tiles behind the ones
				# on screen (TerrainStreamer.refresh), as a sculpt stroke does.
				BrickTerrain.set_sun_direction(c._sun.global_transform.basis.z)
				c._terrain_mat.set_shader_parameter("sun_dir", -c._sun.global_transform.basis.z)
				c.rebuild_detail()
				rebakes += 1
				pending_since = f
		await RenderingServer.frame_post_draw
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		if pending_since >= 0 and st._dirty.is_empty() and st._tasks.is_empty():
			rebake_frames.append(f - pending_since)
			pending_since = -1
	if rebake:
		print("[planet] sun: %d re-bakes; each took %s frames to land every tile" % [rebakes, rebake_frames])
	return [what] + _stats(cpu) + _stats(gpu) + _stats(proc)


func _stats(a: Array[float]) -> Array:
	var s := a.duplicate()
	s.sort()
	var mean := 0.0
	for v in s:
		mean += v
	mean /= maxf(s.size(), 1)
	return [mean, s[int(s.size() * 0.95)], s[-1]]
