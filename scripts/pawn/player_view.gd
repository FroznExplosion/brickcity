class_name PlayerView
extends Node
## What the player's eye and hands do while on foot: the gun held in view, and
## the camera that looks down it.
##
## The gun used to be glued to the camera at one offset -- it did not move when
## you walked, turned, fired, reloaded or aimed, and the view never kicked. This
## is the procedural view model from Ceramic Edge (ViewmodelSway, and the recoil
## in PlayerMovement; Docs/Reference/ceramicedge.md section 3) cut down to one
## gun in one hand:
##
##   * the gun LEANS in the wake of a turn -- tilted about a point ahead of it, so
##     the muzzle stays near the crosshair while the body of the gun swings;
##   * it BOBS with the stride, dips on landing, lowers to run, drops to reload;
##   * each round kicks the gun on a spring and the VIEW up by the class's kick,
##     and the view settles most of the way back once the trigger rests;
##   * the right mouse button brings the sights to the eye: a narrower FOV, a
##     slower mouse, a tighter cone -- a scope on a sniper;
##   * the camera leans off a wall it is running, and widens a little at a sprint
##     and a slide.
##
## Cosmetic and local, apart from two things it sets on the gun: the cone's
## multiplier (aiming, moving, flying) and its bloom. Both only shape where the
## player's own rounds go, the way the mouse does; every roll is still the gun's.

## Field of view the way players think of it: HORIZONTAL degrees, turned into the
## camera's vertical FOV for the window's shape (Ceramic Edge's Hor+).
const HFOV := 90.0
const SPRINT_FOV := 6.0
const SLIDE_FOV := 10.0
const ADS_TIME := 0.16
const SPRINT_TIME := 0.18
const RELOAD_TIME := 0.2

## Per gun class: [view kick in degrees per round, ADS zoom as a fraction of the
## FOV, bloom in degrees per round]. Heavy single shots kick hard and bloom not at
## all; automatics kick little and bloom as they are held.
const FEEL := {
	&"pistol": [1.3, 0.8, 0.45],
	&"revolver": [2.6, 0.78, 0.0],
	&"smg": [0.45, 0.82, 0.22],
	&"rifle": [0.6, 0.72, 0.28],
	&"lmg": [0.5, 0.75, 0.2],
	&"dmr": [1.6, 0.5, 0.3],
	&"sniper": [3.6, 0.28, 0.0],
	&"shotgun": [3.0, 0.85, 0.0],
	&"rocket_launcher": [3.0, 0.8, 0.0],
	&"grenade_launcher": [2.4, 0.8, 0.0],
}
const FEEL_DEFAULT := [1.0, 0.75, 0.3]
## How long each class reads in the hands, metres. The generated models are
## whatever size their parts make them, so the view scales each to this: a
## pistol is a hand's length, a sniper nearly an arm's.
const VIEW_LENGTH := {
	&"pistol": 0.26, &"revolver": 0.3, &"smg": 0.4, &"rifle": 0.55, &"lmg": 0.6,
	&"dmr": 0.6, &"sniper": 0.68, &"shotgun": 0.55, &"rocket_launcher": 0.7,
	&"grenade_launcher": 0.5,
}
const VIEW_LENGTH_DEFAULT := 0.5
## Classes that look through a scope rather than over iron sights.
const SCOPED: Array[StringName] = [&"sniper"]
## How fast the view comes back down after a burst, once the trigger rests.
const KICK_RECOVER := 8.0
const KICK_RECOVER_AFTER := 0.1

## The gun's poses, camera-local, for the TOP of its BACK end (hold() puts the
## gun's model so that point is the rig's origin). At the hip: low and right. At
## the eye: centred, its top just under the line of sight. What a sprint and a
## reload do to it.
const HIP := Vector3(0.14, -0.13, -0.24)
const ADS := Vector3(0.0, -0.03, -0.2)
const SPRINT_POS := Vector3(-0.05, 0.03, -0.02)
const SPRINT_ROT := Vector3(-0.18, 0.5, 0.4)
const RELOAD_POS := Vector3(-0.04, -0.02, -0.02)
const RELOAD_ROT := Vector3(-0.22, 0.3, 0.65)
const MANTLE_POS := Vector3(0.0, -0.05, 0.02)
const MANTLE_ROT := Vector3(-0.25, 0.1, 0.2)

## Look sway: the gun lags and leans in the wake of the turn rate (rad/s).
const SWAY_POS := 0.004
const SWAY_ROT := 0.02
const SWAY_ROLL := 0.03
const SWAY_MAX := 0.025
const LOOK_RATE_SMOOTH := 9.0
const LOOK_RATE_MAX := 8.0
## About a point this far ahead, so the muzzle stays on the crosshair.
const TILT_PIVOT := 0.6
## Bob: cycles per metre of stride, and how far at a run.
const BOB_PER_M := 0.9
const BOB_X := 0.012
const BOB_Y := 0.009
## Springs: gun recoil, and the landing dip (both underdamped, one small bounce).
const RC_STIFF := 210.0
const RC_DAMP := 17.0
const RC_BACK := 0.05
const RC_UP := 0.012
const RC_PITCH := 0.07
const DIP_STIFF := 120.0
const DIP_DAMP := 14.0
## The gun pulled back off a wall close in front, instead of poking into it.
const RETRACT_REACH := 0.9
## Wall-run lean, radians.
const WALL_LEAN := 0.2
## Screen shake: trauma lost per second, and the biggest shove at full trauma.
const SHAKE_DECAY := 1.8
const SHAKE_MAX := 0.05

var camera: DebugCamera
var pawn: Pawn
var gun: GunController
## Hangs off the camera; the gun hangs off it.
var rig: Node3D

var _ads := 0.0
var _sprint := 0.0
var _reload := 0.0
var _mantle := 0.0
var _hfov := HFOV
var _roll := 0.0
var _bob := 0.0
var _look_rate := Vector2.ZERO
var _prev_look := Vector2.ZERO
var _rc_pos := Vector3.ZERO
var _rc_pvel := Vector3.ZERO
var _rc_rot := Vector3.ZERO
var _rc_rvel := Vector3.ZERO
var _dip := 0.0
var _dip_vel := 0.0
var _retract := 0.0
var _kick_left := 0.0
var _since_shot := 1.0
var _shake := 0.0
var _fitted := false
var _fov_was := 75.0
## Cosmetic rolls -- which way a round kicks sideways, the shake. Seeded; never
## the global RNG, and never the gun's (Multiplayer.md D9 is about the gun's).
var _rng := RandomNumberGenerator.new()


func setup(cam: DebugCamera, p: Pawn, g: GunController) -> void:
	camera = cam
	pawn = p
	gun = g
	_rng.seed = 0x5EE
	_fov_was = camera.fov
	rig = Node3D.new()
	rig.name = "Viewmodel"
	camera.add_child(rig)
	gun.fired.connect(_on_fired)
	pawn.landed.connect(_on_landed)
	if pawn.moves != null:
		pawn.moves.mantled.connect(_on_mantled)
	_prev_look = Vector2(camera.rotation.y, camera.rotation.x)
	if gun.gun != null:
		hold(gun.gun)


## Hand the view back: the gun returns to the camera where it used to hang, and
## the camera loses every offset this put on it.
func teardown() -> void:
	if gun != null:
		if gun.fired.is_connected(_on_fired):
			gun.fired.disconnect(_on_fired)
		gun.spread_mult = 1.0
		gun.bloom_per_shot = 0.0
		gun.bloom = 0.0
		if gun.gun != null and gun.gun.get_parent() == rig:
			gun.gun.reparent(camera, false)
			gun.gun.transform = Transform3D(Basis.IDENTITY, Vector3(0.22, -0.2, -0.45))
	if pawn != null and is_instance_valid(pawn):
		if pawn.landed.is_connected(_on_landed):
			pawn.landed.disconnect(_on_landed)
		if pawn.moves != null and pawn.moves.mantled.is_connected(_on_mantled):
			pawn.moves.mantled.disconnect(_on_mantled)
	if camera != null:
		camera.fov = _fov_was
		camera.look_scale = 1.0
		camera.set_roll(0.0)
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	if rig != null:
		rig.queue_free()
	rig = null


## Take this gun into the hands. It is measured and fitted (_fit) once it is in
## the tree.
func hold(gi: GunInstance) -> void:
	if gi == null or rig == null:
		return
	if gi.get_parent() != rig:
		if gi.get_parent() != null:
			gi.reparent(rig, false)
		else:
			rig.add_child(gi)
	gi.transform = Transform3D.IDENTITY
	gi.visible = true
	_fitted = false
	gun.bloom_per_shot = float(_feel()[2])
	gun.bloom = 0.0


## Is the gun up? Not while it is still lowered from a sprint.
func can_fire() -> bool:
	return _sprint < 0.35


func ads_amount() -> float:
	return _ads


func is_scoped() -> bool:
	return gun != null and gun.gun != null and gun.gun.weapon_class != null \
			and gun.gun.weapon_class.id in SCOPED and _ads > 0.85


## Lowered for a run, 0..1.
func sprint_amount() -> float:
	return _sprint


## Shake the view: ~0.1 a shot, ~0.6 a close blast.
func add_shake(amount: float) -> void:
	_shake = minf(_shake + amount, 1.0)


func _feel() -> Array:
	if gun == null or gun.gun == null or gun.gun.weapon_class == null:
		return FEEL_DEFAULT
	return FEEL.get(gun.gun.weapon_class.id, FEEL_DEFAULT)


func _process(delta: float) -> void:
	if rig == null or pawn == null or not is_instance_valid(pawn) or delta <= 0.0:
		return
	var it := pawn.intents
	var body := pawn.body
	var mv := pawn.moves
	var on_floor := pawn.is_on_floor()
	var hv := Vector2(body.velocity.x, body.velocity.z).length()
	var sliding := mv != null and mv.is_sliding()
	var wall_run := mv != null and mv.is_wall_running()
	var reloading := gun.is_reloading()

	var sprinting := it.run and on_floor and not sliding and hv > Pawn.WALK_SPEED * 1.1
	_ads = move_toward(_ads, 1.0 if it.aim and not reloading else 0.0, delta / ADS_TIME)
	_sprint = move_toward(_sprint, 1.0 if sprinting and not it.fire and not it.aim else 0.0,
			delta / SPRINT_TIME)
	_reload = move_toward(_reload, 1.0 if reloading else 0.0, delta / RELOAD_TIME)
	_mantle = move_toward(_mantle, 1.0 if mv != null and mv.is_mantling() else 0.0, delta / 0.1)
	_since_shot += delta

	# Where rounds go: tight at the eye, loose on the run and looser in the air.
	var move_k := clampf(hv / Pawn.RUN_SPEED, 0.0, 1.0)
	var spread := lerpf(1.0, 0.35, _ads) * (1.0 + 0.6 * move_k * (1.0 - 0.7 * _ads))
	if not on_floor and not wall_run:
		spread *= 1.8
	gun.spread_mult = spread

	_camera(delta, wall_run, sliding)
	_recover_kick(delta)
	_model(delta, on_floor, hv, sliding)


func _camera(delta: float, wall_run: bool, sliding: bool) -> void:
	var zoom := float(_feel()[1])
	var hfov := HFOV + SPRINT_FOV * _sprint + (SLIDE_FOV if sliding else 0.0)
	hfov = lerpf(hfov, HFOV * zoom, _smooth(_ads))
	_hfov = lerpf(_hfov, hfov, 1.0 - exp(-14.0 * delta))
	var vp := camera.get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(_hfov) * 0.5) / aspect))
	camera.look_scale = lerpf(1.0, zoom, _ads)

	var lean := 0.0
	if wall_run:
		# Away from the wall: a wall on the right tips the head left.
		var right := camera.global_transform.basis.x
		lean = -signf(pawn.moves.wall_normal.dot(right)) * WALL_LEAN
	elif sliding:
		lean = 0.04
	_roll = lerpf(_roll, lean, 1.0 - exp(-8.0 * delta))
	camera.set_roll(_roll)

	_shake = maxf(_shake - SHAKE_DECAY * delta, 0.0)
	var amt := _shake * _shake * SHAKE_MAX
	camera.h_offset = _rng.randf_range(-1.0, 1.0) * amt
	camera.v_offset = _rng.randf_range(-1.0, 1.0) * amt


## The view comes back down by what the rounds put on it -- not while the
## trigger is held (pulling down against the climb is the player's job), and
## never further than it went up, so a player who already pulled down keeps it.
func _recover_kick(delta: float) -> void:
	if _kick_left <= 0.0 or _since_shot < KICK_RECOVER_AFTER:
		return
	var back := minf(_kick_left, _kick_left * KICK_RECOVER * delta + 0.0005)
	_kick_left -= back
	camera.add_look(0.0, -back)


func _model(delta: float, on_floor: bool, hv: float, sliding: bool) -> void:
	# Turn rate, low-passed: mouse deltas arrive in spikes, and a gun chasing the
	# raw rate jitters.
	var look := Vector2(camera.rotation.y, camera.rotation.x)
	var raw := Vector2(wrapf(look.x - _prev_look.x, -PI, PI), look.y - _prev_look.y) / delta
	_prev_look = look
	raw = raw.clamp(Vector2(-LOOK_RATE_MAX, -LOOK_RATE_MAX), Vector2(LOOK_RATE_MAX, LOOK_RATE_MAX))
	_look_rate = _look_rate.lerp(raw, clampf(LOOK_RATE_SMOOTH * delta, 0.0, 1.0))

	# Springs.
	_rc_pvel += (-RC_STIFF * _rc_pos - RC_DAMP * _rc_pvel) * delta
	_rc_pos = (_rc_pos + _rc_pvel * delta).limit_length(RC_BACK * 2.5)
	_rc_rvel += (-RC_STIFF * _rc_rot - RC_DAMP * _rc_rvel) * delta
	_rc_rot = (_rc_rot + _rc_rvel * delta).limit_length(RC_PITCH * 2.5)
	_dip_vel += (-DIP_STIFF * _dip - DIP_DAMP * _dip_vel) * delta
	_dip = clampf(_dip + _dip_vel * delta, -0.12, 0.12)

	if not _fitted and gun.gun != null and gun.gun.is_inside_tree():
		_fitted = true
		_fit(gun.gun)

	var hip := 1.0 - _smooth(_ads)
	var free := 1.0 - 0.85 * _ads
	var pos := HIP.lerp(ADS, _smooth(_ads))
	var rot := Vector3.ZERO
	pos += SPRINT_POS * _smooth(_sprint)
	rot += SPRINT_ROT * _smooth(_sprint)
	pos += RELOAD_POS * _smooth(_reload)
	rot += RELOAD_ROT * _smooth(_reload)
	pos += MANTLE_POS * _mantle
	rot += MANTLE_ROT * _mantle

	if on_floor and not sliding and hv > 0.3:
		_bob += hv * BOB_PER_M * TAU * delta
	var bob_k := clampf(hv / Pawn.RUN_SPEED, 0.0, 1.0) * (1.0 if on_floor and not sliding else 0.0)
	bob_k *= lerpf(1.0, 1.6, _sprint) * free
	pos += Vector3(cos(_bob * 0.5) * BOB_X, -absf(sin(_bob * 0.5)) * BOB_Y * 2.0 + BOB_Y, 0.0) * bob_k

	var sway := Vector3(-_look_rate.x, _look_rate.y, 0.0) * SWAY_POS * free
	pos += sway.limit_length(SWAY_MAX)
	var tilt := Vector3(-_look_rate.y * SWAY_ROT, -_look_rate.x * SWAY_ROT,
			_look_rate.x * SWAY_ROLL) * free
	# Rising, the hands sink a little; falling, they float up.
	if not on_floor:
		pos.y += clampf(-pawn.body.velocity.y * 0.004, -0.04, 0.04) * free

	# Pulled back off a wall close in front, and down with it.
	var want := 0.0
	var from := camera.global_position
	var q := PhysicsRayQueryParameters3D.create(from,
			from - camera.global_transform.basis.z * RETRACT_REACH, Layers.PAWN_MASK,
			[pawn.body.get_rid()])
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		want = RETRACT_REACH - from.distance_to(hit.position)
	_retract = lerpf(_retract, want * hip, 1.0 - exp(-16.0 * delta))
	pos += Vector3(0.0, -_retract * 0.35, _retract * 0.8)
	rot.x -= _retract * 0.6

	pos += _rc_pos + Vector3(0.0, _dip, 0.0)
	# The lean pivots about a point ahead, so the muzzle holds the crosshair.
	var lean := Basis.from_euler(tilt)
	var arm := Vector3(0.0, 0.0, TILT_PIVOT)
	pos += lean * arm - arm
	var b := lean * Basis.from_euler(rot) * Basis.from_euler(_rc_rot)
	rig.transform = Transform3D(b, pos)
	# Through a scope there is no gun to see.
	rig.visible = not is_scoped()


## Scale the model to its class's length and move it so the top of its back end
## sits on the rig's origin: the poses then place any gun the same way, whatever
## its parts made it.
func _fit(gi: GunInstance) -> void:
	gi.transform = Transform3D.IDENTITY
	var inv := gi.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for n in gi.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var bb: AABB = (inv * vi.global_transform) * vi.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	if first or box.size.z < 0.01:
		return
	var id: StringName = gi.weapon_class.id if gi.weapon_class != null else &""
	var s := float(VIEW_LENGTH.get(id, VIEW_LENGTH_DEFAULT)) / box.size.z
	gi.scale = Vector3.ONE * s
	gi.position = -Vector3(box.get_center().x, box.end.y, box.end.z) * s


static func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


func _on_fired(_info: Dictionary) -> void:
	var f := _feel()
	var kick := deg_to_rad(float(f[0])) * lerpf(1.0, 0.7, _ads)
	var side := kick * 0.3 * _rng.randf_range(-1.0, 1.0)
	camera.add_look(side, kick)
	_kick_left += kick
	_since_shot = 0.0
	# The gun: back, up, muzzle up -- scaled to the kick, the pistol's the unit.
	var s := clampf(float(f[0]) / 1.3, 0.3, 2.5) * lerpf(1.0, 0.5, _ads)
	var imp := sqrt(RC_STIFF) * s
	_rc_pvel += Vector3(0.0, RC_UP, RC_BACK) * imp
	_rc_rvel += Vector3(RC_PITCH, side * 2.0, _rng.randf_range(-0.03, 0.03)) * imp
	add_shake(clampf(float(f[0]) * 0.03, 0.02, 0.14))


func _on_landed() -> void:
	var drop := pawn.last_fall
	if drop < 0.2:
		return
	_dip_vel -= clampf(drop * 0.35, 0.2, 1.4)
	if drop > 2.0:
		add_shake(clampf(drop / 12.0, 0.1, 0.45))


func _on_mantled() -> void:
	_dip_vel -= 0.4
