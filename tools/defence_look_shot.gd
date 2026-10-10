extends SceneTree

## Not headless. A picture of DefenceLook (Docs/Weapons/COMBAT_DESIGN.md 4.1): can a
## player tell, at a glance, what each enemy wears?
##
##     godot --path . --script res://tools/defence_look_shot.gd
##
## Four greybox soldiers in a row, left to right: bare (light), shielded
## (light_shielded), armored (medium), and medium armor two melees in. Writes
## shots/defence_look.png (the folder must exist) and quits.

const PROFILES: Array[StringName] = [&"light", &"light_shielded", &"medium", &"medium"]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	root.add_child(sun)

	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 1.0, 30.0)
	fs.shape = box
	floor.add_child(fs)
	var fm := MeshInstance3D.new()
	var fmesh := BoxMesh.new()
	fmesh.size = box.size
	fm.mesh = fmesh
	floor.add_child(fm)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)

	var pawns: Array[Pawn] = []
	for i in PROFILES.size():
		var p := Pawn.spawn(root, Vector3((i - 1.5) * 1.6, 0.0, 0.0), 1)
		Soldier._greybox(p, 1)
		EnemyProfiles.apply(p.health, PROFILES[i], 1)
		DefenceLook.dress(p.health)
		pawns.append(p)
	# The last one, two melees into its three of armor.
	for i in 2:
		var pk := DamagePacket.new(CombatScale.melee(1), null, null)
		pk.melee = true
		DamageSystem.resolve(pk, pawns[3].body)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(0.0, 1.5, 5.5)
	cam.look_at(Vector3(0.0, 0.9, 0.0), Vector3.UP)
	cam.current = true

	for i in 20:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("res://shots/defence_look.png")
	print("defence look: shots/defence_look.png")
	for c in root.get_children():
		c.queue_free()
	await process_frame
	quit()
