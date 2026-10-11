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
##     and a slide;
##   * ARMS hold it (ViewArms): the right hand's C on the grip, the left's on the
##     handguard -- or under the right hand, on a pistol. The left comes off to
##     swing open at a sprint, to fetch a magazine on a reload (a pinch hand), and
##     to punch with a melee (a fist); with no gun both hands swing open;
##   * a GRENADE: the left hand goes down out of view, comes back with one, cocks
##     it back and throws -- the grenade leaves from the hand (start_throw);
##   * a GRAPPLE: the left hand is thrown out toward the hook and the line shoots
##     out of its C to it, and back in when it lets go;
##   * a SWAP lowers the gun out of view, changes it (and any hand) down there, and
##     raises the new one;
##   * MOMENTUM: the gun lags a change of speed, floats up in a fall, and a hard
##     landing slams it down, muzzle first, by how far the fall was.
##
## Cosmetic and local, apart from two things it sets on the gun: the cone's
## multiplier (aiming, moving, flying) and its bloom. Both only shape where the
## player's own rounds go, the way the mouse does; every roll is still the gun's.

## Field of view the way players think of it: HORIZONTAL degrees, turned into the
## camera's vertical FOV for the window's shape (Ceramic Edge's Hor+).
const HFOV := 90.0
## The Options menu's say (BrickcityMenuHost): field of view, sensitivity while
## aiming (1 = the zoom's own), how much the view shakes, and Reduce Motion --
## no gun bob or sway, no wall-run lean.
static var hfov := HFOV
static var ads_sensitivity := 0.75
static var shake_scale := 1.0
static var reduce_motion := false
## The Options default for ads_sensitivity: at it, aiming turns at the zoom's rate.
const ADS_SENSITIVITY_DEFAULT := 0.75
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
## Classes held in the right hand, the left cupped under it.
const ONE_HAND: Array[StringName] = [&"pistol", &"revolver"]
## Classes that look through a scope rather than over iron sights.
const SCOPED: Array[StringName] = [&"sniper"]
## How fast the view comes back down after a burst, once the trigger rests.
const KICK_RECOVER := 8.0
const KICK_RECOVER_AFTER := 0.1

## The gun's poses, camera-local, for the TOP of its BACK end (hold() puts the
## gun's model so that point is the rig's origin). At the hip: low and right. At
## the eye: centred, its top just under the line of sight. What a sprint and a
## reload do to it.
const HIP := Vector3(0.12, -0.06, -0.3)
const ADS := Vector3(0.0, -0.03, -0.2)
const SPRINT_POS := Vector3(-0.05, 0.03, -0.02)
const SPRINT_ROT := Vector3(-0.18, 0.5, 0.4)
const RELOAD_POS := Vector3(-0.07, 0.025, 0.03)
const RELOAD_ROT := Vector3(0.12, 0.35, 0.75)
const MANTLE_POS := Vector3(0.0, -0.05, 0.02)
## A melee is a gun bash: the gun turns on its side and drives forward and in.
const MELEE_POS := Vector3(-0.08, 0.02, -0.16)
const MELEE_ROT := Vector3(0.1, 0.35, -0.9)
const MANTLE_ROT := Vector3(-0.25, 0.1, 0.2)
## A swap: the gun drops out of the bottom of the view, muzzle down and rolled,
## and comes back up. Seconds down, and up.
const SWAP_POS := Vector3(0.05, -0.36, 0.1)
const SWAP_ROT := Vector3(-0.95, 0.3, 0.55)
const SWAP_DOWN := 0.18
const SWAP_UP := 0.3
## A grenade throw: how long, and when in it the grenade leaves the hand. The gun
## tips away to the right while the left hand is busy.
const THROW_TIME := 0.8
const THROW_RELEASE := 0.55
const THROW_POS := Vector3(0.04, -0.05, 0.03)
const THROW_ROT := Vector3(-0.15, -0.25, -0.3)
## The grapple's line: how long it takes to reach the hook, and to come back in.
const ROPE_OUT := 0.1
const ROPE_IN := 0.08

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
## The landing's pitch, muzzle down: heavier and slower than the drop.
const DIP_ROT_STIFF := 80.0
const DIP_ROT_DAMP := 9.0
## Momentum: the gun lags a change of speed (m/s^2 in, metres out) on a soft spring.
const MOM_GAIN := 0.0022
const MOM_STIFF := 60.0
const MOM_DAMP := 11.0
const MOM_MAX := 0.06
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
## The hands (and arms) on it.
var arms: ViewArms

var _ads := 0.0
var _sprint := 0.0
var _reload := 0.0
var _mantle := 0.0
var _melee := 0.0
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
var _dip_rot := 0.0
var _dip_rot_vel := 0.0
var _mom := Vector3.ZERO
var _mom_vel := Vector3.ZERO
var _prev_vel := Vector3.ZERO
var _accel := Vector3.ZERO
## A swap: how far down the gun is (0 up, 1 out of view), and whether it is going
## down. The gun going away stays in the hands until it is out of sight, then goes
## home (`put_away`); the new one, already the GunController's, waits hidden.
var _swap := 0.0
var _lowering := false
var _outgoing: GunInstance
var _outgoing_home: Node3D
## Swaps that reached the bottom (the --arms pass counts them).
var swaps_done := 0
## The left hand off the gun (0 on it, 1 free), and its stride.
var _left_free := 0.0
## A grenade throw under way, 0..1 (-1 none), what to call when the grenade
## leaves the hand, and the grenade shown in it.
var _throw := -1.0
var _throw_w := 0.0
var _throw_release := Callable()
var _grenade_in_hand: MeshInstance3D
## The grapple: the arm out (0..1), and the line out from the hand (0..1).
var _grapple := 0.0
var _rope := 0.0
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
	_hfov = hfov
	rig = Node3D.new()
	rig.name = "Viewmodel"
	camera.add_child(rig)
	arms = ViewArms.new()
	arms.setup(camera)
	_grenade_in_hand = MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.032
	ball.height = 0.064
	_grenade_in_hand.mesh = ball
	_grenade_in_hand.material_override = ViewArms._mat(Color(0.25, 0.32, 0.18))
	_grenade_in_hand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_grenade_in_hand.visible = false
	arms.held_point(ViewArms.LEFT).add_child(_grenade_in_hand)
	gun.fired.connect(_on_fired)
	pawn.landed.connect(_on_landed)
	pawn.meleed.connect(_on_meleed)
	if pawn.moves != null:
		pawn.moves.mantled.connect(_on_mantled)
	_prev_look = Vector2(camera.rotation.y, camera.rotation.x)
	if gun.gun != null:
		hold(gun.gun)
	# The first gun comes up from below.
	_swap = 1.0
	_prev_vel = pawn.body.velocity


## Hand the view back: the gun returns to the camera where it used to hang, and
## the camera loses every offset this put on it.
func teardown() -> void:
	if gun != null:
		if gun.fired.is_connected(_on_fired):
			gun.fired.disconnect(_on_fired)
		gun.spread_mult = 1.0
		gun.bloom_per_shot = 0.0
		gun.bloom = 0.0
		_finish_put_away()
		if gun.gun != null and gun.gun.get_parent() == rig:
			gun.gun.visible = true
			gun.gun.reparent(camera, false)
			gun.gun.transform = Transform3D(Basis.IDENTITY, Vector3(0.22, -0.2, -0.45))
	if pawn != null and is_instance_valid(pawn):
		if pawn.landed.is_connected(_on_landed):
			pawn.landed.disconnect(_on_landed)
		if pawn.meleed.is_connected(_on_meleed):
			pawn.meleed.disconnect(_on_meleed)
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
	if arms != null:
		arms.queue_free()
	arms = null


## Take this gun into the hands. It is measured and fitted (_fit) once it is in
## the tree, and waits out of sight while the gun before it goes down (a swap);
## it is shown at the bottom and comes up.
func hold(gi: GunInstance) -> void:
	if gi == null or rig == null:
		return
	if gi.get_parent() != rig:
		if gi.get_parent() != null:
			gi.reparent(rig, false)
		else:
			rig.add_child(gi)
	gi.transform = Transform3D.IDENTITY
	gi.visible = false
	_lowering = true
	_fitted = false
	gun.bloom_per_shot = float(_feel()[2])
	gun.bloom = 0.0


## A gun swapped out: it goes down with the hands and only then to `home` (the
## arsenal's holster). One not in sight -- the hidden gun of a swap still under
## way, or with the hands already down -- goes now.
func put_away(gi: GunInstance, home: Node3D) -> void:
	if gi == null:
		return
	if rig == null or gi.get_parent() != rig or not gi.visible or _swap >= 1.0:
		gi.reparent(home, false)
		return
	_finish_put_away()
	_outgoing = gi
	_outgoing_home = home
	_lowering = true


func _finish_put_away() -> void:
	if _outgoing != null and is_instance_valid(_outgoing) and _outgoing.get_parent() == rig \
			and _outgoing_home != null and is_instance_valid(_outgoing_home):
		_outgoing.reparent(_outgoing_home, false)
	_outgoing = null
	_outgoing_home = null


## The gun in the hands to look at: the one going down in a swap, else the
## GunController's (null while it waits hidden, or with none).
func _held() -> GunInstance:
	if _outgoing != null and is_instance_valid(_outgoing) and _outgoing.get_parent() == rig:
		return _outgoing
	var g := gun.gun if gun != null else null
	if g != null and is_instance_valid(g) and g.get_parent() == rig and g.visible:
		return g
	return null


## The landing's dip of the muzzle, radians (negative is down).
func landing_pitch() -> float:
	return _dip_rot


## Throw a grenade with the left hand: `release` is called with where it leaves
## the hand (world), THROW_RELEASE into the throw. False if a throw is under way.
func start_throw(release: Callable) -> bool:
	if _throw >= 0.0 or arms == null:
		return false
	_throw = 0.0
	_throw_release = release
	return true


func is_throwing() -> bool:
	return _throw >= 0.0


## The grapple's line, out from the hand: 0 in, 1 at the hook.
func rope_amount() -> float:
	return _rope


## Swapping: how far down, 0..1.
func swap_amount() -> float:
	return _swap


## Is the gun up? Not while it is still lowered from a sprint, or down while
## the hands climb or hold a lip, or on its way out or in.
func can_fire() -> bool:
	return _sprint < 0.35 and _mantle < 0.35 and _swap < 0.3 and _throw < 0.0 \
			and not pawn.is_meleeing()


## Hanging and facing the lip: both hands are on it. Look away from the wall and
## one comes off with the gun (Ceramic Edge's free hand) -- you can shoot from a
## hang, just not into the wall you hang on.
func _hands_on_lip() -> bool:
	var mv := pawn.moves
	if mv == null or not mv.is_hanging():
		return false
	var look := -camera.global_transform.basis.z
	var flat := Vector3(look.x, 0.0, look.z)
	return flat.length() < 0.1 or flat.normalized().dot(-mv.ledge_normal) > -0.2


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
	_mantle = move_toward(_mantle, 1.0 if mv != null and (mv.is_mantling() or _hands_on_lip())
			else 0.0, delta / 0.1)
	# Out fast, back slower: the blow lands in the first tenth of a second.
	var bashing := pawn.is_meleeing()
	_melee = move_toward(_melee, 1.0 if bashing else 0.0, delta / (0.07 if bashing else 0.2))
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
	var base := PlayerView.hfov
	var hfov := base + SPRINT_FOV * _sprint + (SLIDE_FOV if sliding else 0.0)
	hfov = lerpf(hfov, base * zoom, _smooth(_ads))
	_hfov = lerpf(_hfov, hfov, 1.0 - exp(-14.0 * delta))
	var vp := camera.get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(_hfov) * 0.5) / aspect))
	camera.look_scale = lerpf(1.0, zoom * ads_sensitivity / ADS_SENSITIVITY_DEFAULT, _ads)

	var lean := 0.0
	if wall_run:
		# Away from the wall: a wall on the right tips the head left.
		var right := camera.global_transform.basis.x
		lean = 0.0 if reduce_motion else -signf(pawn.moves.wall_normal.dot(right)) * WALL_LEAN
	elif sliding:
		lean = 0.0 if reduce_motion else 0.04
	_roll = lerpf(_roll, lean, 1.0 - exp(-8.0 * delta))
	camera.set_roll(_roll)

	_shake = maxf(_shake - SHAKE_DECAY * delta, 0.0)
	var amt := _shake * _shake * SHAKE_MAX * shake_scale
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
	_dip = clampf(_dip + _dip_vel * delta, -0.15, 0.12)
	_dip_rot_vel += (-DIP_ROT_STIFF * _dip_rot - DIP_ROT_DAMP * _dip_rot_vel) * delta
	_dip_rot = clampf(_dip_rot + _dip_rot_vel * delta, -0.7, 0.3)
	# Momentum: the change of the body's speed, in the view's frame, pushes the gun
	# the other way on a soft spring -- set off and it trails, stop and it runs on.
	# Not up and down: a fall and a landing have their own.
	var vel := pawn.body.velocity
	var acc := (vel - _prev_vel) / delta
	_prev_vel = vel
	acc.y = 0.0
	acc = camera.global_transform.basis.orthonormalized().inverse() * acc
	_accel = _accel.lerp(acc.limit_length(60.0), clampf(20.0 * delta, 0.0, 1.0))
	_mom_vel += (-MOM_STIFF * _mom - MOM_DAMP * _mom_vel - _accel * MOM_GAIN * MOM_STIFF) * delta
	_mom = (_mom + _mom_vel * delta).limit_length(MOM_MAX)
	_step_swap(delta)
	_step_throw(delta)

	if not _fitted and gun.gun != null and gun.gun.is_inside_tree():
		_fitted = true
		_fit(gun.gun)

	var hip := 1.0 - _smooth(_ads)
	var free := (1.0 - 0.85 * _ads) * (0.0 if reduce_motion else 1.0)
	# A long gun is held nearer, its back end by the cheek, so the arms reach its
	# handguard.
	var held := _held()
	var back := float(held.get_meta(&"view_back", 0.0)) if held != null else 0.0
	var pos := (HIP + Vector3(0.0, 0.0, back)).lerp(ADS, _smooth(_ads))
	var rot := Vector3.ZERO
	pos += SPRINT_POS * _smooth(_sprint)
	rot += SPRINT_ROT * _smooth(_sprint)
	pos += RELOAD_POS * _smooth(_reload)
	rot += RELOAD_ROT * _smooth(_reload)
	pos += MANTLE_POS * _mantle
	rot += MANTLE_ROT * _mantle
	pos += MELEE_POS * _smooth(_melee)
	rot += MELEE_ROT * _smooth(_melee)
	pos += SWAP_POS * _smooth(_swap)
	rot += SWAP_ROT * _smooth(_swap)
	_throw_w = move_toward(_throw_w, 1.0 if _throw >= 0.0 and _throw < 0.85 else 0.0, delta / 0.12)
	pos += THROW_POS * _smooth(_throw_w)
	rot += THROW_ROT * _smooth(_throw_w)

	if on_floor and not sliding and hv > 0.3:
		_bob += hv * BOB_PER_M * TAU * delta
	var bob_k := clampf(hv / Pawn.RUN_SPEED, 0.0, 1.0) * (1.0 if on_floor and not sliding else 0.0)
	bob_k *= lerpf(1.0, 1.6, _sprint) * free
	pos += Vector3(cos(_bob * 0.5) * BOB_X, -absf(sin(_bob * 0.5)) * BOB_Y * 2.0 + BOB_Y, 0.0) * bob_k
	# Each step rocks the gun: a roll with the stride, and a nod as the foot lands;
	# at a run the arms carry it, so it rocks more.
	rot += Vector3(-absf(sin(_bob * 0.5)) * 0.03, 0.0, sin(_bob * 0.5) * 0.045) \
			* bob_k * lerpf(0.5, 1.0, _sprint)
	pos += _mom * free

	var sway := Vector3(-_look_rate.x, _look_rate.y, 0.0) * SWAY_POS * free
	pos += sway.limit_length(SWAY_MAX)
	var tilt := Vector3(-_look_rate.y * SWAY_ROT, -_look_rate.x * SWAY_ROT,
			_look_rate.x * SWAY_ROLL) * free
	# Rising, the hands sink a little; falling, they float up, the muzzle with them,
	# the more the faster the fall -- the landing then slams it down (_on_landed).
	if not on_floor:
		var vy := pawn.body.velocity.y
		pos.y += clampf(-vy * 0.004, -0.04, 0.05) * free
		rot.x += clampf(-vy * 0.01, -0.05, 0.22) * free

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
	rot.x += _dip_rot
	# The lean pivots about a point ahead, so the muzzle holds the crosshair.
	var lean := Basis.from_euler(tilt)
	var arm := Vector3(0.0, 0.0, TILT_PIVOT)
	pos += lean * arm - arm
	var b := lean * Basis.from_euler(rot) * Basis.from_euler(_rc_rot)
	rig.transform = Transform3D(b, pos)
	# Through a scope there is no gun to see, nor hands.
	rig.visible = not is_scoped()
	_hands(delta, on_floor, hv)


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
	gi.set_meta(&"view_holds", _holds(gi, inv, box))
	gi.set_meta(&"view_back", clampf((float(VIEW_LENGTH.get(id, VIEW_LENGTH_DEFAULT)) - 0.3) * 0.45,
			0.0, 0.16))
	gi.scale = Vector3.ONE * s
	gi.position = -Vector3(box.get_center().x, box.end.y, box.end.z) * s


## Where the hands take this gun, in its own frame (unscaled): the grip, the
## handguard, the magazine. From its sockets where it has them (the parts are
## put together on them, GunAssembler), else from its box.
func _holds(gi: GunInstance, inv: Transform3D, box: AABB) -> Dictionary:
	var c := box.get_center()
	var grip := Vector3(c.x, box.position.y + box.size.y * 0.35, box.end.z - box.size.z * 0.25)
	var mag := Vector3(c.x, box.position.y + box.size.y * 0.3, c.z)
	var barrel := Vector3(c.x, c.y + box.size.y * 0.2, c.z)
	var muzzle := Vector3(c.x, barrel.y, box.position.z)
	var g := _socket(gi, "socket_grip")
	if g != null:
		grip = inv * g.global_position
	var m := _socket(gi, "socket_magazine")
	if m != null:
		mag = inv * m.global_position
	var b := _socket(gi, "socket_barrel")
	if b != null:
		barrel = inv * b.global_position
	var mp := gi.get_muzzle_point()
	if mp != null and mp != gi:
		muzzle = inv * mp.global_position
	# The handguard: under the barrel, ahead of the magazine.
	var fore := Vector3(c.x, barrel.y, lerpf(mag.z, muzzle.z, 0.4))
	var id: StringName = gi.weapon_class.id if gi.weapon_class != null else &""
	return {grip = grip, mag = mag, fore = fore, one_hand = id in ONE_HAND}


static func _socket(gi: GunInstance, prefix: String) -> Node3D:
	var found := gi.find_children(prefix + "*", "Node3D", true, false)
	return found[0] as Node3D if not found.is_empty() else null


static func _smooth(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


## The throw's clock: the grenade leaves the hand at THROW_RELEASE.
func _step_throw(delta: float) -> void:
	if _throw < 0.0:
		return
	var was := _throw
	_throw += delta / THROW_TIME
	if was < THROW_RELEASE and _throw >= THROW_RELEASE:
		_grenade_in_hand.visible = false
		if _throw_release.is_valid():
			_throw_release.call(_grenade_in_hand.global_position)
		_throw_release = Callable()
	if _throw >= 1.0:
		_throw = -1.0


## Down, and at the bottom the change: the old gun home, the new one shown. Then up.
func _step_swap(delta: float) -> void:
	if _lowering:
		_swap = move_toward(_swap, 1.0, delta / SWAP_DOWN)
		if _swap >= 1.0:
			_lowering = false
			swaps_done += 1
			_finish_put_away()
			if gun.gun != null and is_instance_valid(gun.gun) and gun.gun.get_parent() == rig:
				gun.gun.visible = true
	else:
		_swap = move_toward(_swap, 0.0, delta / SWAP_UP)


## Where each hand goes this frame, and which hand it is.
func _hands(delta: float, on_floor: bool, hv: float) -> void:
	if arms == null:
		return
	arms.visible = rig.visible
	var held := _held()
	var moving := clampf(hv / Pawn.RUN_SPEED, 0.0, 1.0) * (1.0 if on_floor else 0.3)
	var stride := _bob * 0.5
	var reloading := gun.is_reloading() and held != null and held == gun.gun
	if held == null or not held.has_meta(&"view_holds"):
		# Nothing in hand: both open, swinging with the stride.
		var bare := _swing(ViewArms.LEFT, stride, moving)
		var lp := _left_action(delta, bare, bare, ViewArms.Hand.OPEN)
		arms.set_hand(ViewArms.RIGHT, ViewArms.Hand.OPEN)
		arms.set_hand(ViewArms.LEFT, int(lp[1]))
		arms.swivel = [0.0, 0.0]
		arms.pose(_swing(ViewArms.RIGHT, stride, moving), lp[0], delta)
		_rope_to(delta)
		return

	var holds: Dictionary = held.get_meta(&"view_holds")
	var g := camera.global_transform.affine_inverse() * held.global_transform
	var gb := g.basis.orthonormalized()
	var gx := gb.x
	var gy := gb.y
	var gz := gb.z
	# The right hand: its C round the grip, a little down it, the fingers ahead.
	var grip_axis := (-gy + gz * 0.3).normalized()
	var right := Transform3D(ViewArms.hand_basis(grip_axis, -gz),
			g * (holds.grip as Vector3) + grip_axis * 0.02)
	# The left: round the handguard from under it -- or, on a pistol, under and
	# round the right hand.
	var on_gun: Transform3D
	if bool(holds.one_hand):
		on_gun = Transform3D(ViewArms.hand_basis(grip_axis, -gz + gx * 0.7),
				right.origin - gx * 0.04 - gy * 0.012 + gz * 0.01)
	else:
		on_gun = Transform3D(ViewArms.hand_basis(-gz, gy + gx * 0.4),
				g * (holds.fore as Vector3) - gy * 0.03)

	# Off the gun: at a run it swings open; on a lip it reaches; nothing else.
	var off := _sprint > 0.5 or _mantle > 0.5
	_left_free = move_toward(_left_free, 1.0 if off else 0.0, delta / 0.15)
	var free_pose := _swing(ViewArms.LEFT, stride, maxf(moving, 0.6))
	if _mantle > 0.0:
		free_pose = free_pose.interpolate_with(_reach(ViewArms.LEFT), _mantle)
	var left := on_gun.interpolate_with(free_pose, _smooth(_left_free))
	# Asked for at once: going, the hand is changed once it has left the view; coming
	# back, it is still out of it.
	var left_hand := ViewArms.Hand.OPEN if off else ViewArms.Hand.C

	if reloading:
		var path := _reload_left(gun.reload_progress(), on_gun, g, gx, gy, holds)
		left = path[0]
		left_hand = path[1]
	elif _melee > 0.0:
		# A bash: the left hand leaves the gun as a fist, driving with it.
		var fist := Transform3D(ViewArms.hand_basis(Vector3.UP, Vector3(0.1, 0.2, -1.0)),
				Vector3(-0.07, -0.14, -0.4))
		left = left.interpolate_with(fist, _smooth(_melee))
		if _melee > 0.3:
			left_hand = ViewArms.Hand.FIST
	var act := _left_action(delta, left, on_gun, left_hand)
	left = act[0]
	left_hand = act[1]
	arms.set_hand(ViewArms.RIGHT, ViewArms.Hand.C)
	arms.set_hand(ViewArms.LEFT, left_hand)
	# The elbows trail a turn, and wing out at a run.
	var trail := clampf(-_look_rate.x * 0.06, -0.3, 0.3)
	arms.swivel = [trail + 0.25 * _sprint, -trail + 0.15 * _sprint]
	arms.pose(right, left, delta)
	_rope_to(delta)


## What the left hand does over everything else: a grenade throw, else a grapple.
## `left` is the pose so far, `home` where it goes back to. [pose, hand].
func _left_action(delta: float, left: Transform3D, home: Transform3D, hand: int) -> Array:
	var mv := pawn.moves
	var hooked := mv != null and mv.is_grappling()
	_grapple = move_toward(_grapple, 1.0 if hooked else 0.0, delta / (0.08 if hooked else 0.2))
	if _grapple > 0.0 and mv != null:
		# Out toward the hook, the arm near straight, the line through the C.
		var hook := camera.global_transform.affine_inverse() * mv.hook
		var sh: Vector3 = ViewArms.SHOULDER[ViewArms.LEFT]
		var dir := (hook - sh).normalized()
		# Never back past the shoulder or out of the side of the view.
		dir.z = minf(dir.z, -0.55)
		dir.x = clampf(dir.x, -0.5, 0.35)
		dir = dir.normalized()
		var out := Transform3D(ViewArms.hand_basis(dir, Vector3(0.2, 1.0, 0.0)),
				sh + dir * 0.56 + Vector3(0.04, 0.04, 0.0))
		left = left.interpolate_with(out, _smooth(_grapple))
		hand = ViewArms.Hand.C
	if _throw >= 0.0:
		var p := _throw
		var down := Transform3D(ViewArms.hand_basis(Vector3.RIGHT, Vector3(0.2, 1.0, -0.3)),
				Vector3(-0.14, -0.52, -0.2))
		# Cocked back by the left of the view, then through past the crosshair and down.
		var cocked := Transform3D(ViewArms.hand_basis(Vector3.RIGHT, Vector3(0.1, 1.0, 0.4)),
				Vector3(-0.24, -0.06, -0.3))
		var let_go := Transform3D(ViewArms.hand_basis(Vector3.RIGHT, Vector3(0.0, 0.3, -1.0)),
				Vector3(-0.04, -0.02, -0.5))
		var follow := Transform3D(ViewArms.hand_basis(Vector3.RIGHT, Vector3(0.3, -0.4, -1.0)),
				Vector3(0.06, -0.46, -0.36))
		var keys := [[0.0, left], [0.18, down], [0.42, cocked], [THROW_RELEASE, let_go],
				[0.72, follow], [1.0, home]]
		for i in keys.size() - 1:
			var a: float = keys[i][0]
			var b: float = keys[i + 1][0]
			if p <= b:
				var k := clampf((p - a) / (b - a), 0.0, 1.0)
				# The throw itself is a snap, not an ease.
				k = k if a >= 0.42 and b <= THROW_RELEASE else _smooth(k)
				left = (keys[i][1] as Transform3D).interpolate_with(keys[i + 1][1], k)
				break
		# The grenade is picked up out of view, and let go of with an open hand.
		_grenade_in_hand.visible = p >= 0.18 and p < THROW_RELEASE
		hand = ViewArms.Hand.OPEN if p >= THROW_RELEASE and p < 0.8 else ViewArms.Hand.C
	return [left, hand]


## The grapple's line: out from the left hand's C to the hook, in when it lets go.
func _rope_to(delta: float) -> void:
	var mv := pawn.moves
	var hooked := mv != null and mv.is_grappling()
	_rope = move_toward(_rope, 1.0 if hooked else 0.0, delta / (ROPE_OUT if hooked else ROPE_IN))
	if _rope <= 0.0 or mv == null:
		arms.set_rope(Vector3.ZERO, Vector3.ZERO, false)
		return
	var from := arms.hole(ViewArms.LEFT)
	var hook := camera.global_transform.affine_inverse() * mv.hook
	arms.set_rope(from, from.lerp(hook, _rope), true)


## An open hand swinging with the stride, at the bottom of the view; `amount`
## is how hard (0 standing, 1 a run). The two hands swing opposite.
func _swing(side: int, stride: float, amount: float) -> Transform3D:
	var sx := 1.0 if side == ViewArms.RIGHT else -1.0
	var ph := sin(stride + (0.0 if side == ViewArms.RIGHT else PI))
	var at := Vector3(0.17 * sx, -0.36, -0.26)
	at += Vector3(0.0, maxf(ph, 0.0) * 0.08, -ph * 0.14) * amount
	var fingers := Vector3(-0.15 * sx, 0.35 + ph * 0.3 * amount, -1.0)
	return Transform3D(ViewArms.hand_basis(Vector3.UP, fingers), at)


## Reaching for a lip: an open hand out ahead and a little down.
func _reach(side: int) -> Transform3D:
	var sx := 1.0 if side == ViewArms.RIGHT else -1.0
	return Transform3D(ViewArms.hand_basis(Vector3(sx * 0.3, 0.0, 1.0), Vector3(0.0, 0.4, -1.0)),
			Vector3(0.16 * sx, -0.12, -0.42))


## The left hand through a reload, by its progress: down out of view (a pinch
## hand there), up to the magazine, down with the old one, up with the new, then
## down again (the C back) and onto the gun. [pose, hand].
func _reload_left(p: float, on_gun: Transform3D, g: Transform3D, gx: Vector3, gy: Vector3,
		holds: Dictionary) -> Array:
	var mag := Transform3D(ViewArms.hand_basis(gx, gy), g * (holds.mag as Vector3) - gy * 0.06)
	var down := Transform3D(ViewArms.hand_basis(Vector3.RIGHT, Vector3(0.2, 1.0, -0.3)),
			Vector3(-0.1, -0.52, -0.3))
	var keys := [[0.0, on_gun], [0.15, down], [0.32, mag], [0.44, mag], [0.56, down],
			[0.7, mag], [0.78, mag], [0.88, down], [1.0, on_gun]]
	var pose: Transform3D = on_gun
	for i in keys.size() - 1:
		var a: float = keys[i][0]
		var b: float = keys[i + 1][0]
		if p <= b:
			pose = (keys[i][1] as Transform3D).interpolate_with(keys[i + 1][1],
					_smooth(clampf((p - a) / (b - a), 0.0, 1.0)))
			break
	var hand := ViewArms.Hand.PINCH if p > 0.12 and p < 0.86 else ViewArms.Hand.C
	return [pose, hand]


func _on_fired(info: Dictionary) -> void:
	# What the round does to whoever it hit: a flinch, or up close a stumble
	# (HitReaction) -- and a stumble lands in the hands too.
	if gun.aim != null and HitReaction.hit(gun.gun, gun.aim.global_position, info) > 0.0:
		add_shake(0.06)
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
	_dip_vel -= clampf(drop * 0.35, 0.2, 1.8)
	# The muzzle dips with it: a step down nods it, a long fall slams it.
	_dip_rot_vel -= clampf(drop * 0.6, 0.15, 3.5)
	if drop > 2.0:
		add_shake(clampf(drop / 12.0, 0.1, 0.45))


## A blow that connected jolts the view; a whiff only swings.
func _on_meleed(info: Dictionary) -> void:
	if info.is_empty():
		return
	add_shake(0.18)
	_dip_vel += 0.25


func _on_mantled() -> void:
	_dip_vel -= 0.4
