extends SceneTree

## Not headless (it takes pictures): the starter mech, made of the official parts, beside a
## wall with a second-storey window -- to see that its pilot looks straight into it, how tall it
## stands, and its walk (Docs/ModularParts.md, "Starter parts").
##
##     godot --path . --script res://tools/mech_look.gd
##
## Writes user://mech_look/*.png. Saves nothing.

const OUT := "user://mech_look/"
## The city's storeys (Docs/Parts/nano.md section 1): storey 1's walls start 2.8 m up; its
## window from 3.64 m to 4.90 m.
const STOREY := 2.8
const WINDOW_LO := 3.64
const WINDOW_HI := 4.90


func _init() -> void:
	_go.call_deferred()


func _shot(name: String) -> void:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(OUT + name + ".png")
	print("[mech look] wrote ", ProjectSettings.globalize_path(OUT + name + ".png"))


func _box(parent: Node3D, at: Vector3, size: Vector3, colour: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	if colour.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)


func _go() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var stage := Node3D.new()
	root.add_child(stage)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.78, 0.84, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.85)
	e.ambient_light_energy = 0.55
	env.environment = e
	stage.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.75, 0.8, 0)
	stage.add_child(sun)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(80, 1, 80)
	gs.shape = bs
	ground.add_child(gs)
	ground.position = Vector3(0, -0.5, 0)
	stage.add_child(ground)
	_box(stage, Vector3(0, -0.05, 0), Vector3(80, 0.1, 80), Color(0.55, 0.57, 0.55))
	# A wall in front of the mech (it faces -Z), 4 m off: storeys marked, the second storey's
	# window cut out (two pieces of wall either side, one above, one below).
	var wall := Node3D.new()
	wall.position = Vector3(0, 0, -4.0)
	stage.add_child(wall)
	var tan := Color(0.78, 0.7, 0.58)
	_box(wall, Vector3(0, WINDOW_LO * 0.5, 0), Vector3(8, WINDOW_LO, 0.3), tan)
	_box(wall, Vector3(0, (WINDOW_HI + 7.0) * 0.5, 0), Vector3(8, 7.0 - WINDOW_HI, 0.3), tan)
	_box(wall, Vector3(-2.75, (WINDOW_LO + WINDOW_HI) * 0.5, 0), Vector3(2.5, WINDOW_HI - WINDOW_LO, 0.3), tan)
	_box(wall, Vector3(2.75, (WINDOW_LO + WINDOW_HI) * 0.5, 0), Vector3(2.5, WINDOW_HI - WINDOW_LO, 0.3), tan)
	_box(wall, Vector3(0, STOREY, 0.2), Vector3(8, 0.08, 0.1), Color(0.3, 0.3, 0.3))   # storey line
	_box(wall, Vector3(0, STOREY * 2.0, 0.2), Vector3(8, 0.08, 0.1), Color(0.3, 0.3, 0.3))

	var m := Mech.spawn(stage, Vector3.ZERO, 0.0, 0)
	m.set_physics_process(false)
	m.motor.set_physics_process(false)
	m.body.set_physics_process(false)
	var cat := PartCatalog.new()
	cat.load_dir(PartCatalog.OFFICIAL_DIR, "official")
	var b := PartBuilder.generate("mech", null, 1, cat, {"class": "normal"})
	var ok := MechAssembler.dress(m, b, true)
	var gun := MechAssembler.arm_gun(m, MechAssembler.roll_gun(GunPlaceholderParts.build_library(), 1, cat))
	print("[mech look] its gun: %s" % (gun.gun_name if gun != null else "none"))
	m._aim_arm(0.016)   # the arm on its shoulder, along the aim, as a physics tick puts it
	print("[mech look] dressed: %s, parts %d, eye %.2f m, shoulder %s" % [ok, cat.size(), m.cockpit_y, m.shoulder])
	# The eye: a small red ball where the pilot looks from.
	_box(stage, Vector3(0, m.cockpit_y, -Mech.COCKPIT_FORWARD), Vector3(0.15, 0.15, 0.15), Color(1, 0.1, 0.1))
	var top := 0.0
	for mi in m.body.find_children("*", "MeshInstance3D", true, false):
		var g := (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
		top = maxf(top, g.end.y)
	print("[mech look] top of the mech %.2f m (two storeys: %.2f m)" % [top, STOREY * 2.0])

	var cam := Camera3D.new()
	cam.fov = 40.0
	stage.add_child(cam)
	cam.current = true
	cam.position = Vector3(11.0, 3.4, 2.0)   # from its right side, the wall in view
	cam.look_at(Vector3(0, 3.2, -1.5))
	await _shot("side_wall")
	cam.position = Vector3(6.5, 4.5, 7.5)
	cam.look_at(Vector3(0, 3.0, 0))
	await _shot("three_quarter")
	# From the pilot's seat: the chassis hidden as MechPilot hides it.
	m.canopy.visible = false
	cam.fov = 75.0
	cam.position = Vector3(0.0, m.cockpit_y, -Mech.COCKPIT_FORWARD)
	cam.look_at(Vector3(0, m.cockpit_y, -4.0))
	await _shot("pilot_view")
	m.canopy.visible = true
	cam.fov = 40.0
	# Walking: the stride's widest, then a knee folded.
	var walk := m.body.get_node_or_null(^"MotionWalk") as MechStride
	if walk != null:
		walk.set_physics_process(false)   # posed by hand here
		for i in 400:
			walk.step(0.01, 7.0)
			if absf(walk.swing) > walk.swing_max * (7.0 / walk.run) * 0.97:
				break
		cam.position = Vector3(-11.0, 3.0, 0.0)   # from its left: nothing in front of the legs
		cam.look_at(Vector3(0, 3.0, 0))
		await _shot("walk_reach")
		for i in 400:
			walk.step(0.01, 7.0)
			var k: Node3D = walk.knees[0] if not walk.knees.is_empty() else null
			if k != null and k.rotation.x < -0.6:
				break
		await _shot("walk_knee")
	quit(0)
