extends SceneTree
## Not headless. WHAT AN ALMOST EMPTY WINDOW HOLDS IN VIDEO TEXTURES, and what
## the PBR texture arrays add (Docs/TerrainRegions.md 2.1: the ~550 MB of
## video textures above ground that are neither the reflection atlas nor the
## materials). A report, no checks.
##
##     godot --path . --script res://tools/probes/vram_baseline_probe.gd

func _initialize() -> void:
	_run.call_deferred()


func _mb() -> float:
	return Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1e6


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await _frames(30)
	print("[vram] empty window: textures %.1f MB" % _mb())
	var cam := Camera3D.new()
	root.add_child(cam)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	root.add_child(sun)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.position = Vector3(0, 0, -3)
	root.add_child(box)
	await _frames(30)
	print("[vram] + a 3D view (camera, sky, shadowed sun, a box): textures %.1f MB" % _mb())
	var steps := [
		["directional shadow atlas -> 512", func(): RenderingServer.directional_shadow_atlas_set_size(512, false)],
		["positional shadow atlas %d -> 0" % root.positional_shadow_atlas_size, func(): root.positional_shadow_atlas_size = 0],
		["sun shadow off", func(): sun.shadow_enabled = false],
		["sky -> clear colour", func(): env.environment.background_mode = Environment.BG_CLEAR_COLOR],
		["window 3D off (camera gone)", func(): cam.queue_free()],
	]
	for st: Array in steps:
		var b := _mb()
		(st[1] as Callable).call()
		await _frames(20)
		print("[vram]   %-36s %+.1f MB -> %.1f" % [st[0], _mb() - b, _mb()])
	var held := []
	for f in DirAccess.get_files_at("res://textures/pbr"):
		if f.ends_with(".webp"):
			var before := _mb()
			var t: TextureLayered = load("res://textures/pbr/" + f)
			# Drawn once, so its upload is counted.
			var m := ShaderMaterial.new()
			var sh := Shader.new()
			sh.code = "shader_type spatial; uniform sampler2DArray t; void fragment() { ALBEDO = texture(t, vec3(UV, 0.0)).rgb; }"
			m.shader = sh
			m.set_shader_parameter("t", t)
			var mi := MeshInstance3D.new()
			mi.mesh = BoxMesh.new()
			mi.material_override = m
			mi.position = Vector3(1.5 * held.size() - 6.0, 0, -6)
			root.add_child(mi)
			held.append([t, mi])
			await _frames(5)
			print("[vram]   %-28s %dx%d x%d layers  %+.1f MB" % [f, t.get_width(), t.get_height(), t.get_layers(), _mb() - before])
	print("[vram] with every PBR array: textures %.1f MB" % _mb())
	await _frames(240)
	print("[vram] ...240 frames later: textures %.1f MB, video total %.1f MB, buffers %.1f MB" % [_mb(),
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1e6,
			Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1e6])
	quit()
