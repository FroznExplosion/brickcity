extends SceneTree

## Not headless (it takes pictures): a blocky action figure built in the asset workshop's figure
## mode, and the same figure in the game -- standing, mid-stride and with an elbow bent -- to
## look at its knees, ankles and elbows (Docs/ModularParts.md, joints inside a part).
##
##     godot --path . --script res://tools/figure_look.gd
##
## Writes user://figure_look/*.png. Saves nothing of the player's: its build and parts go in
## its own folder, the workshop's autosave is off.

const DIR := "user://_figure_look/"
const OUT := "user://figure_look/"

var _ws
var _frames := 0
var _arch := ""


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	_ws.auto_start_brick = false
	root.add_child(_ws)
	_ws._no_autosave = true
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 3:
		return
	_ws._no_autosave = true
	_ws._hotbar.save_path = "user://_figure_look_hotbar.json"
	_ws.toolbars_save = "user://_figure_look_toolbars.json"
	_go()


func _shot(name: String) -> void:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(OUT + name + ".png")
	print("[figure look] wrote ", ProjectSettings.globalize_path(OUT + name + ".png"))


func _put(part: String, x: int, y: int, z: int, colour: int) -> void:
	_ws.select_part(_ws.part_names.find(part))
	if not _ws.place_named(_arch, Vector3i(x, y, z), colour):
		print("[figure look] no room for %s at %d,%d,%d" % [part, x, y, z])


func _go() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for yaw in 2:   # limbs a stud wide (across, Z) and two deep (X)
		var n := BrickPalette.variant_name("brick_1x2", yaw, false)
		if BrickPalette.size_of(n).z == 1:
			_arch = n
	_ws._new_build()
	_ws.set_asset_kind("figure")
	var x := int(_ws.mech_origin().x) - 1
	var zl := int(floor(_ws.mirror_z)) + 1   # its left, +Z
	var zr := int(floor(_ws.mirror_z)) - 1
	var zm := int(floor(_ws.mirror_z))
	var g := int(_ws.mech_origin().y)
	# Legs: four bricks each, ground to hips (the lowest is the foot, below the ankle).
	for y in [0, 3, 6, 9]:
		_put("leg_L", x, g + y, zl, 3)
		_put("leg_R", x, g + y, zr, 3)
	# Torso: three wide, hips to shoulders.
	for y in [12, 15, 18]:
		for z in [zr, zm, zl]:
			_put("torso", x, g + y, z, 1)
	# Arms: three bricks from the shoulder down, a hand under each.
	for y in [12, 15, 18]:
		_put("arm_L", x, g + y, zl + 1, 6)
		_put("arm_R", x, g + y, zr - 1, 6)
	_put("hand_L", x, g + 9, zl + 1, 9)
	_put("hand_R", x, g + 9, zr - 1, 9)
	# Head and hat.
	_put("head", x, g + 21, zm, 9)
	_put("head", x, g + 24, zm, 9)
	_put("hat", x, g + 27, zm, 0)
	_ws._builds_dir = DIR
	_ws._save_as("Look Figure")
	_ws.show_help(false)
	_ws._look_at_build()
	_ws.set_view(1)
	await _shot("workshop_side")
	_ws.set_view(3)
	await _shot("workshop_front")
	_ws.set_view(0)
	_ws._look_at_build()
	await _shot("workshop_3d")

	# In the game: its own little world, seen from the side.
	var cat := PartCatalog.new()
	cat.load_dir(_ws.parts_dir(), "custom")
	var d: PartDesign = Figure.designs(cat).get("look_figure")
	var f := Figure.make(PartBuilder.generate("figure", d, 1, cat)) if d != null else null
	if f == null:
		print("[figure look] the figure did not go together")
		quit(1)
		return
	_ws.visible = false
	for c in _ws.find_children("*", "CanvasLayer", true, false):
		(c as CanvasLayer).visible = false
	var stage := Node3D.new()
	root.add_child(stage)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.82, 0.86, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.8, 0.8, 0.85)
	e.ambient_light_energy = 0.5
	env.environment = e
	stage.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.7, 0.9, 0)
	stage.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(6, 6)
	floor_mi.mesh = pm
	stage.add_child(floor_mi)
	stage.add_child(f)
	f.set_physics_process(false)   # posed by hand here
	var cam := Camera3D.new()
	cam.fov = 30.0
	stage.add_child(cam)
	cam.position = Vector3(3.6, 1.6, 2.7)   # three quarters, from its right front: it faces -Z
	cam.look_at(Vector3(0, 1.0, 0))
	cam.current = true
	f.walk.step(0.02, 0.0)
	await _shot("game_standing")
	# Mid-stride: walk until the left knee is folded furthest.
	var knee := f.joint("leg_L").find_child("Bend_knee", true, false) as Node3D
	var best := 0.0
	var best_phase := 0.0
	for i in 200:
		f.walk.step(0.02, 3.0)
		if knee != null and knee.rotation.x < best:
			best = knee.rotation.x
			best_phase = f.walk.phase
	while knee != null and absf(f.walk.phase - best_phase) > 0.05:
		f.walk.step(0.005, 3.0)
	print("[figure look] mid-stride: hip %.2f, knee %.2f, ankle %.2f" % [f.joint("leg_L").rotation.x,
			knee.rotation.x if knee else 0.0,
			(knee.get_node(^"Bend_ankle") as Node3D).rotation.x if knee and knee.has_node(^"Bend_ankle") else 0.0])
	await _shot("game_stride_3q")
	cam.position = Vector3(4.8, 1.0, 0.0)   # from its right side
	cam.look_at(Vector3(0, 1.0, 0))
	await _shot("game_stride_side")
	# A quarter cycle on: one leg forward, the other back.
	for i in 40:
		f.walk.step(0.005, 3.0)
		if absf(f.walk.swing) >= f.walk.swing_max * (3.0 / Figure.RUN) * 0.98:
			break
	await _shot("game_stride_reach")
	var elbow := f.joint("arm_R").find_child("Bend_elbow", true, false) as Node3D
	f.walk.step(0.02, 0.0)
	if elbow != null:
		elbow.rotation.x = 1.3
	cam.position = Vector3(4.8, 1.0, 0.0)
	cam.look_at(Vector3(0, 1.0, 0))
	await _shot("game_elbow")
	_wipe(DIR)
	quit(0)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
