extends SceneTree

## Aim assist (AimAssist, Docs/Weapons/AIM_ASSIST.md): it helps without dragging.
##
##     godot --headless --path . --script res://tools/aim_assist_probe.gd
##
##   pick        an enemy just off the crosshair is the target; one far off is not
##   no drift    a still enemy, no input: the view does not move
##   friction    the look slows over a target, not away from one
##   tracking    an enemy strafing across the view is followed, part way
##   head        centering helps sideways only: aimed at the head, the pitch is kept
##   never fight turning away from a target, the assist adds nothing
##   range       a shotgun has no target past its reach; it does inside it
##   weak points a weak point round the back is not aimed for; from behind it is
##   bullets     a near miss is bent onto the line at the crosshair's height; a wide miss is not
##   snap        raising the sights near a target closes part of the gap, once
##   engaged     firing on a target builds the engagement
##   off         the level at Off: nothing

var cam: DebugCamera
var aa: AimAssist
var gun: GunController
var pc: PlayerController
var me: Pawn
var foe: Pawn
var s: AIServices
var lib: GunPartLibrary
var _pass := 0
var _fail := 0


func _init() -> void:
	print("aim assist probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _wait(t: float) -> void:
	await create_timer(t).timeout


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Point the camera at `p`, turned `yaw_off` degrees (+ left) and `pitch_off` up.
func _look(p: Vector3, yaw_off := 0.0, pitch_off := 0.0) -> void:
	var d := (p - cam.global_position).normalized()
	cam.rotation = Vector3(asin(d.y) + deg_to_rad(pitch_off), atan2(-d.x, -d.z) + deg_to_rad(yaw_off), 0.0)


func _yaw() -> float:
	return cam.rotation.y


func _equip(cls: StringName) -> void:
	var gi := GunInstance.from_result(GunGenerator.generate(lib, 7, WeaponClass.builtin(cls), 1))
	cam.add_child(gi)
	if gun.gun != null:
		gun.gun.queue_free()
	gun.equip(gi)


func _chest() -> Vector3:
	return foe.feet() + Vector3.UP * 1.0


func _head() -> Vector3:
	return foe.feet() + Vector3.UP * (foe.eye_height() + 0.05)


func _run() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)
	s = AIServices.new()
	s.world3d = root.get_world_3d()
	cam = DebugCamera.new()
	cam.capture_mouse = false
	root.add_child(cam)
	me = Pawn.spawn(root, Vector3.ZERO, 0, true, 1.0e6)
	s.pawns.append(me)
	foe = Pawn.spawn(root, Vector3(0.0, 0.0, -20.0), 1, true, 1.0e6)
	s.pawns.append(foe)
	pc = PlayerController.new()
	root.add_child(pc)
	pc.possess(me, cam)
	pc.drive_uncaptured = true
	gun = GunController.new()
	gun.aim = cam
	gun.rng = RandomNumberGenerator.new()
	root.add_child(gun)
	lib = GunPlaceholderParts.build_library()
	_equip(&"rifle")
	aa = AimAssist.new()
	aa.setup(cam, gun, pc, s)
	root.add_child(aa)
	aa.ads_override = 0.0
	cam.assist = aa
	gun.assist = aa
	AimAssist.device = AimAssist.Device.MOUSE
	AimAssist.mouse_level = 2
	await _frames(3)

	# --- pick
	_look(_chest(), 1.0)
	await _frames(2)
	_ok("an enemy 1 deg off the crosshair is the target", not aa.target.is_empty() and aa.target.owner == foe)
	_look(_chest(), 25.0)
	await _frames(2)
	_ok("one 25 deg off is not", aa.target.is_empty())

	# --- no drift
	_look(_chest(), 1.2)
	await _frames(2)
	var y0 := _yaw()
	var p0 := cam.rotation.x
	await _wait(1.0)
	_ok("a still enemy and no input: the view does not move",
			absf(_yaw() - y0) < 1e-5 and absf(cam.rotation.x - p0) < 1e-5,
			"%.5f deg" % rad_to_deg(absf(_yaw() - y0)))

	# --- friction
	_look(_chest(), 0.0)
	await _frames(2)
	var on := aa.filter_look(Vector2(0.01, 0.0)).x
	_look(_chest(), 25.0)
	await _frames(2)
	var off := aa.filter_look(Vector2(0.01, 0.0)).x
	_ok("the look slows over a target, not away from one", on < 0.0099 and absf(off - 0.01) < 1e-7,
			"over %.4f, away %.4f of 0.01" % [on, off])

	# --- tracking: strafe the enemy 1 m to its side over a second.
	_look(_chest(), 0.0)
	await _frames(2)
	var start := foe.feet()
	var yaw_a := _yaw()
	var t := 0.0
	while t < 1.0:
		await process_frame
		t += 1.0 / 60.0
		foe.place(start + Vector3.RIGHT * 1.0 * minf(t, 1.0))
		await _wait(1.0 / 60.0)
	var target_turn := atan2(1.0, 20.0)
	var turned := absf(wrapf(_yaw() - yaw_a, -PI, PI))
	_ok("an enemy strafing is followed, part way", turned > target_turn * 0.15 and turned < target_turn * 0.9,
			"%.2f of its %.2f deg" % [rad_to_deg(turned), rad_to_deg(target_turn)])
	foe.place(start)
	await _frames(3)

	# --- head: aim at the head, 1.5 deg to its side, firing: the pitch stays.
	_look(_head(), 1.5)
	await _frames(2)
	var pitch_h := cam.rotation.x
	var err0 := absf((aa.target.err as Vector2).x) if not aa.target.is_empty() else 0.0
	gun.set_trigger(true)
	await _wait(0.5)
	gun.set_trigger(false)
	var err1 := absf(aa.error_to(foe.feet() + Vector3.UP * 1.0).x)
	_ok("firing at the head: centering helps sideways", err1 < err0 * 0.8,
			"%.2f -> %.2f deg" % [rad_to_deg(err0), rad_to_deg(err1)])
	_ok("and keeps the head's pitch", absf(cam.rotation.x - pitch_h) < deg_to_rad(0.05),
			"%.3f deg" % rad_to_deg(cam.rotation.x - pitch_h))
	await _wait(0.5)

	# --- never fight: the target is right of the crosshair; turn left (yaw +).
	_look(_chest(), 1.0)
	await _frames(2)
	var yb := _yaw()
	var asked := 0.0
	for i in 20:
		var d := aa.filter_look(Vector2(0.0005, 0.0))
		cam.add_look(d.x, d.y)
		asked += d.x
		await process_frame
	_ok("turning away from a target, the assist adds nothing against it",
			wrapf(_yaw() - yb, -PI, PI) >= asked - 1e-5,
			"asked %.3f, turned %.3f deg" % [rad_to_deg(asked), rad_to_deg(wrapf(_yaw() - yb, -PI, PI))])

	# --- range
	_equip(&"shotgun")
	_look(_chest(), 0.5)
	await _frames(2)
	_ok("a shotgun has no target at 20 m", aa.target.is_empty())
	foe.place(Vector3(0.0, 0.0, -8.0))
	await _frames(2)
	_look(_chest(), 0.5)
	await _frames(2)
	_ok("and has one at 8 m", not aa.target.is_empty())
	_equip(&"rifle")
	foe.place(Vector3(0.0, 0.0, -20.0))
	await _frames(2)

	# --- weak points: a spot 0.3 m behind the body (its -z side faces us).
	var spots := CritSpots.new()
	spots.name = "CritSpots"
	foe.body.add_child(spots)
	spots.add(&"pack", foe.body, 0.2, Vector3(0.0, 0.6, -0.3))
	_look(_chest(), 0.5)
	await _frames(2)
	var col := aa.target.point as Vector3 if not aa.target.is_empty() else Vector3.INF
	_ok("a weak point round the back is not aimed for", col != Vector3.INF and absf(col.z - foe.feet().z) < 0.05,
			"line at z %.2f, body %.2f" % [col.z, foe.feet().z])
	me.place(Vector3(0.0, 0.0, -40.0))
	await _frames(3)
	_look(_chest(), 0.5)
	await _frames(2)
	col = aa.target.point as Vector3 if not aa.target.is_empty() else Vector3.INF
	_ok("from behind, it is", col != Vector3.INF and absf(col.z - (foe.feet().z - 0.3)) < 0.05,
			"line at z %.2f" % col.z)
	spots.queue_free()
	me.place(Vector3.ZERO)
	await _frames(3)

	# --- bullets
	_look(_head(), 1.3)
	await _frames(2)
	var from := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var bent := aa.bend(from, fwd)
	var lands := from + bent * from.distance_to(_head())
	_ok("a near miss at head height is bent onto the line", bent != fwd and Vector2(lands.x - foe.feet().x,
			lands.z - foe.feet().z).length() < 0.3 and absf(lands.y - _head().y) < 0.15,
			"lands %.2f m off the line, %.2f m from the head's height" % [Vector2(lands.x - foe.feet().x,
			lands.z - foe.feet().z).length(), absf(lands.y - _head().y)])
	_look(_head(), 3.5)
	await _frames(2)
	_ok("a wide miss is not", aa.bend(cam.global_position, -cam.global_transform.basis.z)
			== -cam.global_transform.basis.z)

	# --- snap
	_look(_chest(), 1.5)
	await _frames(2)
	var e0 := absf((aa.target.err as Vector2).x)
	Input.action_press(&"aim")
	aa.ads_override = 0.5
	await _wait(0.4)
	var e1 := absf(aa.error_to(_chest()).x)
	_ok("raising the sights near a target closes part of the gap", e1 < e0 * 0.6 and e1 > e0 * 0.05,
			"%.2f -> %.2f deg" % [rad_to_deg(e0), rad_to_deg(e1)])
	var y_after := _yaw()
	await _wait(0.4)
	_ok("once", absf(_yaw() - y_after) < 1e-5)
	Input.action_release(&"aim")
	aa.ads_override = 0.0
	await _frames(3)

	# --- engaged
	_look(_chest(), 0.3)
	gun.set_trigger(true)
	await _wait(0.7)
	_ok("firing on a target builds the engagement", aa.engagement > 0.9, "%.2f" % aa.engagement)
	gun.set_trigger(false)
	await _wait(0.5)
	_ok("and it is lost when the firing stops", aa.engagement < 0.05, "%.2f" % aa.engagement)

	# --- off
	AimAssist.mouse_level = 0
	_look(_chest(), 0.0)
	await _frames(2)
	_ok("at Off: no target, no slowdown, no bend", aa.target.is_empty()
			and is_equal_approx(aa.filter_look(Vector2(0.01, 0.0)).x, 0.01)
			and aa.bend(cam.global_position, Vector3.FORWARD) == Vector3.FORWARD)
	AimAssist.mouse_level = 2

	print("aim assist probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _frames(2)
	quit(1 if _fail > 0 else 0)
