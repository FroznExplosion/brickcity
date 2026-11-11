extends SceneTree

## Not headless. The effects that are particles (Docs/GpuOffload.md 2.2): a death
## burst (CombatFeedback), what flies off hits on stone, metal and wood
## (MaterialFx), and a collapse's dust (CollapseDust), caught early and late.
## Saved to <out>/fx_early.png and <out>/fx_late.png (default res://shots/gpu_fx).
## The torch has its own (torch_look.gd).
##
##     godot --path . --script res://tools/shots/gpu_fx_look.gd -- [--out=<dir>]

func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := "res://shots/gpu_fx"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.45, 0.55, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.55, 0.6)
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0.0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	ground.mesh = pm
	root.add_child(ground)
	var wall := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(6.0, 3.0, 0.4)
	wall.mesh = bm
	wall.position = Vector3(2.0, 1.5, -3.2)
	root.add_child(wall)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0.0, -0.25, -1.0)), Vector3(0.5, 2.0, 5.0))
	var city := Node3D.new()
	root.add_child(city)
	var fb := CombatFeedback.new()
	root.add_child(fb)
	fb.setup(city)
	var fx := MaterialFx.new()
	root.add_child(fx)
	fx.setup(null, null)
	for i in 3:
		await process_frame
	fb.burst(Vector3(-2.5, 0.0, 0.0), Color(0.85, 0.15, 0.1))
	var hits := [["stone", Vector3(0.5, 1.2, -3.0)], ["metal", Vector3(2.0, 1.6, -3.0)],
			["wood", Vector3(3.5, 1.2, -3.0)]]
	for h in hits:
		fx._debris(h[1], Vector3.BACK, h[0], Color(0.6, 0.6, 0.6))
	CollapseDust.puff(city, Vector3(-6.0, 1.0, -10.0), 6.0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for shot in [["fx_early", 6], ["fx_late", 24]]:
		for i in int(shot[1]):
			await physics_frame
		await RenderingServer.frame_post_draw
		root.get_viewport().get_texture().get_image().save_png(out.path_join(shot[0] + ".png"))
	print("gpu fx look: shots written to %s" % out)
	quit(0)
