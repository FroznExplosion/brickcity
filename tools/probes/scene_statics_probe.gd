extends SceneTree

## Static state that outlives a scene is put back when its owner's scene goes.
##
##     godot --headless --path . --script res://tools/probes/scene_statics_probe.gd
##
## Gravity: the real planet scene (with its star system) is loaded and then left
## for an empty scene, as quitting to the menu does. Left set, the next scene was
## pulled toward a freed planet, and a station's 0 m/s^2 outside pull left the
## flat city with no gravity at all (Gravity.reset).
##
## WeatherFx: a storm and a wildfire map set on a registered material, then the
## DisasterDirector (their only writer) leaves the tree. Left set, the next scene's
## shared brick materials came in wet, swaying and charred (WeatherFx.clear).

var _ok := 0
var _fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		_ok += 1
		print("  ok   ", what)
	else:
		_fail += 1
		print("  FAIL ", what, (" -- " + detail) if detail != "" else "")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("[statics] gravity: planet scene, then away")
	var flat_pull := Gravity.pull_at(Vector3(0.0, 5.0, 0.0))
	change_scene_to_file("res://scenes/planet.tscn")
	for i in 240:
		await process_frame
		if Gravity.planet != null and is_instance_valid(Gravity.planet) and i > 30:
			break
	_check("the planet scene sets the planet", Gravity.planet != null and is_instance_valid(Gravity.planet))
	# What a station would leave: a pull of nothing outside its fields.
	Gravity.outside_pull = 0.0
	var empty := PackedScene.new()
	var root := Node3D.new()
	empty.pack(root)
	root.free()
	change_scene_to_packed(empty)
	for i in 10:
		await process_frame
	_check("leaving it clears the planet", Gravity.planet == null)
	_check("and the fields", Gravity.fields.is_empty())
	_check("and the outside pull", Gravity.outside_pull < 0.0, "%.2f" % Gravity.outside_pull)
	var pull := Gravity.pull_at(Vector3(0.0, 5.0, 0.0))
	_check("the flat game's pull is back (%.2f m/s^2)" % pull, is_equal_approx(pull, flat_pull),
			"was %.2f before the planet" % flat_pull)
	_check("down is -Y again", Gravity.down_at(Vector3(30.0, 5.0, -12.0)).is_equal_approx(Vector3.DOWN))

	print("[statics] weather: a storm and a wildfire, then the director leaves")
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/brick.gdshader")
	WeatherFx.register(mat)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	WeatherFx.set_weather(0.9, Vector3(3.0, 0.0, 1.0), 0.8, 0.5)
	WeatherFx.set_burn(ImageTexture.create_from_image(img), Vector4(-100.0, -100.0, 200.0, 200.0))
	_check("the storm is on the material", float(mat.get_shader_parameter("weather_wet")) > 0.5)
	var director := DisasterDirector.new()
	root = current_scene
	root.add_child(director)
	root.remove_child(director)
	director.free()
	_check("leaving clears the wet", WeatherFx.wet == 0.0 and float(mat.get_shader_parameter("weather_wet")) == 0.0)
	_check("the rain and snow", WeatherFx.rain == 0.0 and WeatherFx.snow == 0.0
			and float(mat.get_shader_parameter("weather_snow")) == 0.0)
	_check("the wind", WeatherFx.wind == Vector3.ZERO
			and (mat.get_shader_parameter("weather_wind") as Vector3) == Vector3.ZERO)
	_check("the burnt ground", WeatherFx.burn_tex == null
			and (mat.get_shader_parameter("weather_burn_rect") as Vector4).z <= 0.0)
	_check("and the material is still registered for the next scene", WeatherFx.is_registered(mat))

	print("[statics] %d ok, %d FAIL" % [_ok, _fail])
	quit(1 if _fail > 0 else 0)
