extends SceneTree

## Not headless. The thermal torch's flame (TorchFlame), burning at a target, saved to
## shots/torch_flame.png from beside and shots/torch_flame_fp.png from behind the gun.
##
##     godot --path . --script res://tools/torch_look.gd

var gun: GunController
var aim: Node3D


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.13, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0.0)
	root.add_child(sun)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	floor.mesh = pm
	root.add_child(floor)
	var target := Pawn.spawn(root, Vector3(0.0, 0.0, -4.0), 1, true, 1.0e6)
	Soldier._greybox(target, 1)
	aim = Node3D.new()
	root.add_child(aim)
	aim.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0, -1)), Vector3(0.0, 1.4, 0.0))
	gun = GunController.new()
	gun.aim = aim
	gun.rng = RandomNumberGenerator.new()
	root.add_child(gun)
	var lib := GunPlaceholderParts.build_library()
	var gi := GunInstance.from_result(GunGenerator.generate(lib, 3, WeaponClass.builtin(&"smg"), 1))
	gi.alt_fire = GunAltFire.TORCH
	aim.add_child(gi)
	gi.position = Vector3(0.2, -0.2, -0.4)
	gun.equip(gi)
	gun.toggle_alt()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(-5.0, -0.3, -1.8)), Vector3(4.0, 1.7, -0.5))
	gun.set_trigger(true)
	for i in 30:
		await physics_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	root.get_viewport().get_texture().get_image().save_png("res://shots/torch_flame.png")
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0.0, -0.15, -1.0)), Vector3(0.0, 1.6, 0.6))
	for i in 10:
		await physics_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("res://shots/torch_flame_fp.png")
	print("torch look: shots written")
	quit(0)
