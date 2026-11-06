extends SceneTree
## The player's flashlight (Docs/Lighting.md 6.4): mounted once per camera, off
## at the start, the `flashlight` action (L) turns it on and off again.

var _pass := 0
var _fail := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL ", what)


func _initialize() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	var f := Flashlight.mount(cam)
	await process_frame
	_check(Flashlight.mount(cam) == f, "a second mount gives the same light")
	_check(not f.visible and not Flashlight.on, "it starts off")
	_check(f.shadow_enabled and f.spot_range > 10.0, "it throws shadows a good way")
	_check(f.position.x > 0.0 and f.position.y < 0.0, "it sits right of and below the eye")
	_check(InputMap.has_action(&"flashlight"), "the flashlight action exists")
	var keys := InputMap.action_get_events(&"flashlight")
	_check(keys.size() == 1 and keys[0] is InputEventKey
			and (keys[0] as InputEventKey).physical_keycode == KEY_L, "it is on L")
	for a in InputMap.get_actions():
		if a == &"flashlight":
			continue
		for e in InputMap.action_get_events(a):
			if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_L:
				_check(false, "L is also %s" % a)
	var press := InputEventAction.new()
	press.action = &"flashlight"
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	_check(f.visible and Flashlight.on, "L turns it on")
	Input.parse_input_event(press)
	await process_frame
	await process_frame
	_check(not f.visible and not Flashlight.on, "L again turns it off")
	cam.queue_free()
	await process_frame
	_check(not Flashlight.on, "gone with its camera, off")
	print("[flashlight] %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
