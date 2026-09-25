## titan_motor.gd
## Copied from BoomerBorder (scripts/titan/) for brickcity's mechs, 2026-09-25: the
## motor unchanged apart from its step height, restated in brick courses. The Titan
## node, cockpit and exits it mentions stayed behind -- they are built around
## third-party meshes; brickcity's Mech (scripts/mech/mech.gd) drives this instead.
## The whole of spec §6: how a titan moves. Titanfall handling with mass.
##
## ─── THE ONE RULE ─────────────────────────────────────────────────────────────────────
##
## This node NEVER touches input, the player, or a camera. It consumes one [TitanIntents]
## per physics tick from whoever is driving, and that is the entire interface. Spec §1
## locks it: one motor, pluggable brain, so piloted feel and AI feel can never diverge.
## The moment this file reads a key or a camera basis, an AI titan starts moving like a
## different machine and nobody notices until the AI ships.
##
## ─── AIM IS INSTANT, THE CHASSIS IS HEAVY ─────────────────────────────────────────────
##
## The pilot's look is 1:1 and lives entirely in [PlayerRig] (whose rule 1 is that aim is
## never sprung). What lags is the MACHINE: [member torso_yaw] chases `intents.aim_yaw` at
## [member torso_turn_speed] with [member torso_turn_accel] smoothing, and the legs chase
## the torso with further lag, only re-aligning once they are past
## [member leg_follow_threshold]. Movement is then relative to the TORSO, not to the aim —
## get that backwards and strafing feels like an FPS instead of like driving a chassis.
##
## The torso chase uses a stop-on-target rate profile (`sqrt(2*a*err)`) rather than a
## proportional one. A proportional chase clamped to a max rate arrives at full speed and
## overshoots by the whole spin-down distance, and a mech that wobbles past its target
## reads as broken rather than heavy.
##
## ─── SPEED CHAINING ───────────────────────────────────────────────────────────────────
##
## Dashing out of a sprint keeps sprint momentum — spec §6.1 calls it the core move, so it
## is a rule and not a side effect: the dash caps you at [member dash_speed] PLUS whatever
## speed the chassis was already carrying above its walking cap. From a standstill that is
## exactly `dash_speed`; out of a full sprint it is `dash_speed + (13.5 - 9.0)`. Charges
## regenerate on independent timers (TF2-style), not on one shared cooldown.
##
## Those two numbers are the ONLY legal outcomes, and `_try_dash` now enforces that twice
## over, because the carry rule read naively is a speed exploit: mid-dash `body.velocity`
## IS the forced dash speed, so a second dash would carry 26 − 9 and land at 43 m/s —
## making dash → dash strictly better than sprint → dash and deleting the very move §6.1
## calls the core one. So: a dash may not be cancelled into another dash, and the carry is
## additionally capped at what a sprinting chassis could legitimately be holding. See
## [method _try_dash].
##
## ─── STEPS ────────────────────────────────────────────────────────────────────────────
##
## Godot's [CharacterBody3D] has no step-up, and a 1.2 m riser is a wall to it. See
## `_step_assist` — the short version is that it only fires against surfaces too steep to
## walk, and it proves a surface is a STEP and not a RAMP by requiring the way to be clear
## for [constant STEP_PROBE_REACH] metres at the lifted height. A ramp keeps rising; a step
## does not. Without that test the titan ratchets straight up a 50° slope.
##
## Time scale: [EntityTime], never `Engine.time_scale` — project rule.
class_name TitanMotor
extends Node

# ------------------------------------------------------------------------------ signals
# Spec §6.3 verbatim. The motor is the single source of "physical truth" events that both
# audio and camera feel subscribe to; nothing downstream reaches into internals.

## From an AnimationTree method track once one exists; distance cadence until then.
signal footstep(foot: StringName, strength: float)
signal dash_started(dir: Vector3)
signal dash_ended
signal sprint_started
signal sprint_ended
## Drives the 2-pip dash HUD (spec §6.3).
signal dash_charges_changed(current: int, max: int)
signal landed(fall_distance: float)
signal started_moving
signal stopped_moving

# ------------------------------------------------------------------------------ tuning
# Spec §6.2 — names, groups and initial values are a tuning contract. Do not rename or
# re-value them here; a feel pass changes them in the inspector.

@export_group("Ground Movement")
@export var max_speed := 9.0            # m/s (~pilot sprint; titans keep pace, they don't outrun)
@export var accel := 12.0               # m/s² — noticeably softer than the pilot's
@export var decel := 16.0
@export var turn_in_place_speed := 140.0 # deg/s when no move input

@export_group("Sprint")
@export var sprint_speed_mult := 1.5     # → ~13.5 m/s
@export var sprint_spool_time := 0.4     # accel ramp into sprint
@export var sprint_turn_mult := 0.6      # torso turn rate while sprinting
@export var sprint_strafe_mult := 0.5    # lateral input damping
@export var sprint_min_speed := 3.0      # must be moving to engage

@export_group("Torso / Aim Chase")
@export var torso_turn_speed := 240.0   # deg/s max chase rate
@export var torso_turn_accel := 720.0   # deg/s² smoothing
@export var leg_follow_threshold := 35.0 # deg before legs re-align

@export_group("Dash")
@export var dash_speed := 26.0
@export var dash_duration := 0.28
@export var dash_charges := 2
@export var dash_regen_time := 5.0
@export var dash_control := 0.15        # steering authority mid-dash (low = committed)

@export_group("Vertical / Terrain")
@export var gravity_scale := 1.6
## Three brick courses (1.26 m): a mech walks over a figure's cover and a
## rubble heap, and not over a storey (brickcity, D6: lengths in bricks).
@export var step_height := 0.42 * 3.0   # use safe-margin + snap; titans walk over pilot-scale cover
@export var max_slope_deg := 42.0
@export var landing_min_fall := 3.0     # m of fall before a landing impact event fires

## NOT in §6.2. There is no AnimationTree in M1, so footsteps use the fallback the spec
## documents in §10.4: distance-based cadence. One stride per emitted step, feet alternating.
@export_group("Footsteps")
@export var stride_length := 3.4

# ------------------------------------------------------------------------------ constants

## How far the ground is pressed into while walking, so floor snapping stays engaged.
## Negative Y only — there is no jump in this game and nothing here may ever produce lift.
const GROUND_PRESS := 2.0

## A step must leave the way clear for this far at the lifted height. This is the entire
## step-vs-ramp discriminator: 1.2 m of lift buys 1.5 m of level travel on a stair top and
## about 1.0 m on a 50° slope, so the slope fails and the stair passes.
const STEP_PROBE_REACH := 1.5
## Slack on the lift search, so a riser of exactly `step_height` is not refused for grazing
## its own top face at the collision margin.
const STEP_GRAZE := 0.06
## Floor on the "am I blocked" probe distance.
##
## ⚠ Without this the step assist never fires against the one case it exists for. Walk into
## a riser, `move_and_slide` cancels the horizontal velocity into the wall, and the NEXT
## tick's motion is `accel * dt` ≈ 3 mm — a probe that short reports no collision against a
## surface the chassis is already touching, so the titan stands there re-accelerating into a
## step it will never test for. Probing a fixed short distance ahead costs nothing when the
## way is clear (`test_move` returns false and we return) and is the difference between a
## stair being climbable and being a wall.
const STEP_MIN_MOTION := 0.12
## Bisection steps for the lift search. 6 gives ~2 cm resolution over a 1.2 m range.
const STEP_SEARCH_ITERATIONS := 6

## Sprint DROPS at this fraction of [member sprint_min_speed] but still ENGAGES at the full
## value. See [method _update_sprint] — a single threshold chatters against a wall.
const SPRINT_DROP_FRACTION := 0.7

# ------------------------------------------------------------------------------ state

## The body this drives. Resolved from the parent in [method _ready]; settable before that
## for a motor that is not a direct child.
var body: CharacterBody3D

## World yaw of the chassis torso, radians. Chases `intents.aim_yaw`. THIS is the frame
## movement is expressed in.
var torso_yaw: float = 0.0
## World yaw of the legs, radians. Chases the torso with further lag. Cosmetic in M1 (it
## drives the leg mesh); locomotion never reads it.
var legs_yaw: float = 0.0

var _intents: TitanIntents
var _own_intents := TitanIntents.new()   # used when nobody has handed us one yet

var _torso_rate: float = 0.0             # rad/s, signed
var _legs_chasing: bool = false

var _sprinting: bool = false
var _sprint_spool: float = 0.0           # 0..1

var _dash_time: float = 0.0
var _dash_dir: Vector3 = Vector3.ZERO
var _dash_target_speed: float = 0.0
var _dash_edge: bool = false             # previous tick's raw dash bit
var _charges: int = 0
var _regen: Array[float] = []            # one independent timer per spent charge

var _wish: Vector3 = Vector3.ZERO        # world, horizontal, magnitude 0..1 (the throttle)
var _wish_dir: Vector3 = Vector3.ZERO    # world, horizontal, unit or zero
var _moving: bool = false
var _stride: float = 0.0
var _next_foot: StringName = &"left"
var _last_pos: Vector3 = Vector3.ZERO

var _was_on_floor: bool = true
var _air_peak_y: float = 0.0
var _gravity: float = 15.68

## Reused so a blocked frame does not allocate. `_step_assist` runs shape casts, not
## allocations.
var _probe := KinematicCollision3D.new()


func _ready() -> void:
	# BEFORE anything that reads our output (HUD, camera rig, future weapon aim) and AFTER
	# the brain that fills our intents — same reasoning as RiderBody's priority comment:
	# reading a value before its producer has run costs you exactly one frame of lag, every
	# frame, and it never looks like an ordering bug.
	process_physics_priority = -10
	if body == null:
		body = get_parent() as CharacterBody3D
	if body == null:
		push_error("TitanMotor: no CharacterBody3D parent — the motor will do nothing.")
		return
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * gravity_scale
	# The motor owns terrain handling, so it owns the body's terrain settings.
	body.floor_max_angle = deg_to_rad(max_slope_deg)
	body.floor_snap_length = 0.5
	body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	_charges = dash_charges
	_last_pos = body.global_position
	_air_peak_y = body.global_position.y
	torso_yaw = body.rotation.y
	legs_yaw = torso_yaw
	_own_intents.aim_yaw = torso_yaw


# ------------------------------------------------------------------------------ interface

## Hand the motor this tick's intents. Called by [Titan] from whichever brain is active.
## The reference is kept, not copied — brains reuse one struct, and the motor consumes it
## inside the same physics tick.
##
## ⚠ Pass `null` to UNPLUG, and [Titan] must do exactly that on every non-PILOTED branch.
## Keeping the reference used to be unconditional, which leaked a dead brain's last frame
## forever: clearing a brain's INPUT zeroes its private fields, but only its `think()`
## writes the struct, and a titan with no brain never runs `think()` again. A pilot who
## left while holding W left the motor pointing at a struct that still said "forward,
## sprinting" — the titan walked off on its own and the `_own_intents` fallback below was
## unreachable. Unplugging re-seeds the fallback's aim to the CURRENT torso angle so a
## parked chassis holds where it is looking rather than snapping back to its spawn facing.
func set_intents(i: TitanIntents) -> void:
	if i == null:
		_intents = null
		_own_intents.clear(torso_yaw)
		return
	_intents = i


## Place the chassis at rest facing `yaw`: spawn, teleport, and every probe phase.
func reset(yaw: float) -> void:
	torso_yaw = wrapf(yaw, -PI, PI)
	legs_yaw = torso_yaw
	_torso_rate = 0.0
	_legs_chasing = false
	# Every state that has a matching "ended" signal must EMIT it here, not just clear the
	# flag. A teleport out of a sprint used to drop `_sprinting` silently, so the next
	# sprint emitted a second `sprint_started` against one `sprint_ended` and anything
	# counting the pair (the HUD today, M6's turbine loop next) was left running a sprint
	# that had stopped existing.
	if _sprinting:
		_sprinting = false
		sprint_ended.emit()
	_sprint_spool = 0.0
	if _dash_time > 0.0:
		_dash_time = 0.0
		dash_ended.emit()
	_dash_dir = Vector3.ZERO
	# NOT cleared: `_dash_edge` is the previous tick's raw BUTTON state, not motor state,
	# and the button does not un-press because the chassis teleported. Zeroing it handed a
	# pilot who was holding Space through the teleport a free rising edge on the next tick
	# and burned a charge. Seed it from what is actually being asked for right now.
	_dash_edge = _active().dash
	_regen.clear()
	_charges = dash_charges
	_stride = 0.0
	if _moving:
		_moving = false
		stopped_moving.emit()
	_wish = Vector3.ZERO
	_wish_dir = Vector3.ZERO
	_own_intents.clear(torso_yaw)
	if body != null:
		body.velocity = Vector3.ZERO
		_last_pos = body.global_position
		_air_peak_y = body.global_position.y
		_was_on_floor = true
	dash_charges_changed.emit(_charges, dash_charges)


func planar_speed() -> float:
	return Vector2(body.velocity.x, body.velocity.z).length() if body != null else 0.0


func is_sprinting() -> bool:
	return _sprinting


func is_dashing() -> bool:
	return _dash_time > 0.0


func charges() -> int:
	return _charges


## Signed torso-behind-aim error in radians. The HUD reads this; so does anything that
## wants to know whether the chassis has caught up.
func aim_divergence() -> float:
	return wrapf(target_yaw() - torso_yaw, -PI, PI)


func target_yaw() -> float:
	return _active().aim_yaw


func sprint_spool() -> float:
	return _sprint_spool


# ------------------------------------------------------------------------------ the tick

func _physics_process(delta: float) -> void:
	if body == null:
		return
	# `body`, not `self`. [EntityTime.of] resolves through [ComponentCache.find], which
	# searches the given node's DESCENDANTS — and this motor has none, so passing `self`
	# could never find the `EntityTime` child that EntityTime's own docs tell you to hang
	# off the entity ROOT. Per-titan dilation was a guaranteed silent no-op. Same call
	# shape as `base_ghost.gd` and `player_rig_test.gd`: pass the node that OWNS the child.
	var dt: float = EntityTime.delta_for(body, delta)
	if dt <= 0.0:
		# Frozen entity. Nothing moves — not even gravity, or a stasis field quietly
		# becomes a trapdoor.
		return

	var on_floor := body.is_on_floor()
	var it := _active()

	_update_charges(dt)
	_update_sprint(dt, on_floor)
	_update_torso(dt, it)
	# ⚠ BEFORE the dash, not inside `_apply_horizontal` after it. The dash direction is
	# `_wish_dir`, so computing the wish afterwards makes every dash use LAST tick's stick —
	# tap dash on the same frame you push a direction and the titan dashes torso-forward
	# instead. One frame, invisible in a log, and exactly the frame a player dashes on.
	_update_wish(it)
	_update_dash(dt)
	_try_dash(it)
	_apply_horizontal(dt, on_floor)
	_apply_vertical(dt, on_floor)
	_update_legs(dt)
	_step_assist(dt)
	body.move_and_slide()
	_post_move(dt)


func _active() -> TitanIntents:
	return _intents if _intents != null else _own_intents


# ------------------------------------------------------------------------------ torso/legs

func _update_torso(dt: float, it: TitanIntents) -> void:
	var target := it.aim_yaw
	var err := wrapf(target - torso_yaw, -PI, PI)
	# Committed while sprinting: turn rate drops, and it drops WITH the spool so the
	# handling change arrives at the same moment the speed does.
	#
	# ⚠ The spool ALONE, not gated on `_sprinting`. Gating it made the comment above true
	# only on the way in: on release the flag clears in one tick, so the turn rate snapped
	# back to full instantly while `top` speed kept decaying smoothly with the spool.
	var rate_mult: float = lerpf(1.0, sprint_turn_mult, _sprint_spool)
	var max_rate := deg_to_rad(torso_turn_speed) * rate_mult
	var acc := deg_to_rad(torso_turn_accel)

	# The fastest rate from which `acc` can still stop exactly on target. Capping a
	# proportional chase instead would arrive at full speed and overshoot by the whole
	# spin-down arc, which reads as a wobble rather than as weight.
	var stop_rate: float = sqrt(2.0 * acc * absf(err))
	var desired: float = signf(err) * minf(max_rate, stop_rate)
	_torso_rate = move_toward(_torso_rate, desired, acc * dt)
	torso_yaw = wrapf(torso_yaw + _torso_rate * dt, -PI, PI)

	var after := wrapf(target - torso_yaw, -PI, PI)
	if err != 0.0 and signf(after) != signf(err):
		# Stepped past the target inside one tick. Land on it rather than ringing.
		torso_yaw = wrapf(target, -PI, PI)
		_torso_rate = 0.0


## Legs chase the torso, and only start chasing once the divergence is worth an animation
## (spec §6.1's skate fix) or once the titan is actually walking — you cannot keep walking
## with your legs crossed sideways, however long the torso holds its angle.
func _update_legs(dt: float) -> void:
	var diff := wrapf(torso_yaw - legs_yaw, -PI, PI)
	if not _legs_chasing:
		if absf(diff) > deg_to_rad(leg_follow_threshold) or _wish_dir.length_squared() > 1e-6:
			_legs_chasing = true
	if not _legs_chasing:
		return
	var step := deg_to_rad(turn_in_place_speed) * dt
	legs_yaw = wrapf(legs_yaw + clampf(diff, -step, step), -PI, PI)
	if absf(diff) <= deg_to_rad(2.0) and _wish_dir.length_squared() <= 1e-6:
		_legs_chasing = false


# ------------------------------------------------------------------------------ sprint

func _update_sprint(dt: float, on_floor: bool) -> void:
	var it := _active()
	# "Must be moving to engage" (§6.2 sprint_min_speed) plus forward intent: a titan that
	# spools its turbines while strafing sideways is a titan whose sprint means nothing.
	#
	# TWO thresholds, the way §8.2's `follow_near` / `follow_far` does it. One bare
	# `>= sprint_min_speed` oscillates: hold Shift+W into a wall or up the 50° ramp and the
	# speed hunts around 3.0 m/s, emitting sprint_started/sprint_ended every few ticks —
	# HUD flicker now, a stuttering turbine loop in M6.
	var floor_speed: float = sprint_min_speed * (SPRINT_DROP_FRACTION if _sprinting else 1.0)
	var want: bool = it.sprint and on_floor and it.move_dir.y > 0.1 \
		and planar_speed() >= floor_speed
	if want != _sprinting:
		_sprinting = want
		if want:
			sprint_started.emit()
		else:
			sprint_ended.emit()
	var rate := dt / maxf(sprint_spool_time, 0.0001)
	_sprint_spool = clampf(_sprint_spool + (rate if _sprinting else -rate), 0.0, 1.0)


# ------------------------------------------------------------------------------ dash

func _try_dash(it: TitanIntents) -> void:
	# NO DASH-CANCEL. A dash may not be interrupted by another dash, and this guard is the
	# 🔴 fix, not a nicety: mid-dash `body.velocity` IS the forced dash speed, so the carry
	# rule below would read 26 m/s as "momentum", hand the second dash 26 − 9 = 17 m/s of
	# carry and produce 43 m/s (47.5 out of a sprint) from two taps 0.1 s apart. That is
	# 1.6× spec, and worse, it inverts §6.1's economy — dash → dash would beat sprint →
	# dash and quietly delete the chaining move the whole section is built around.
	#
	# ⚠ REVERSIBLE FEEL DECISION, not a technical limit. "No dash-cancel" is the M1 answer
	# and belongs to the same family as spec §14 Q5; if a playtest wants cancels back, the
	# way to do it is to let the dash be re-entered while making the carry read the
	# chassis' PRE-dash speed, never `body.velocity`.
	#
	# `_dash_edge` is deliberately left frozen for the duration — the button state the
	# motor last acted on is still the one it last acted on. Holding Space through a dash
	# therefore cannot auto-fire the next one; the pilot has to release and press again.
	if _dash_time > 0.0:
		return

	var raw := it.dash
	var rising := raw and not _dash_edge
	_dash_edge = raw
	if not rising:
		return
	if _charges <= 0:
		return       # refused; the HUD already shows why

	var dir := _wish_dir
	if dir.length_squared() < 1e-6:
		dir = -Basis(Vector3.UP, torso_yaw).z    # torso-forward when there is no input
	dir = dir.normalized()

	# THE CHAINING RULE (§6.1). Whatever the chassis was carrying ABOVE its walking cap
	# rides into the dash, so sprint → dash is strictly faster than dash from rest. Setting
	# the speed to `dash_speed` flat would make the two identical and quietly delete the
	# best move in the kit.
	#
	# Belt and braces on top of the no-dash-cancel guard: the carry can never exceed what a
	# fully spooled sprint could legitimately be holding above the walking cap. The guard
	# above closes the one hole we know about; this cap means any FUTURE way of arriving
	# here with impossible speed in `body.velocity` (a launcher, a conveyor, a physics
	# shove) degrades to the sprint→dash number instead of scaling without limit. The two
	# legal outcomes stay `dash_speed` from rest and `dash_speed + 4.5` out of a sprint.
	var planar := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var carry_cap: float = maxf(max_speed * sprint_speed_mult - max_speed, 0.0)
	var carry: float = clampf(planar.dot(dir) - max_speed, 0.0, carry_cap)
	_dash_target_speed = dash_speed + carry
	_dash_dir = dir
	_dash_time = dash_duration
	_charges -= 1
	_regen.append(dash_regen_time)
	dash_charges_changed.emit(_charges, dash_charges)
	dash_started.emit(dir)


func _update_dash(dt: float) -> void:
	if _dash_time <= 0.0:
		return
	if _wish_dir.length_squared() > 1e-6 and dash_control > 0.0:
		# `dash_control` is the FRACTION of the way to the new heading the pilot may steer
		# across the whole dash, so the export reads as "steering authority" the way §6.2
		# describes it and does not silently depend on the tick rate.
		var t: float = clampf(dash_control * (dt / maxf(dash_duration, 0.0001)), 0.0, 1.0)
		var blended := _dash_dir.lerp(_wish_dir, t)
		if blended.length_squared() > 1e-6:
			_dash_dir = blended.normalized()
	_dash_time -= dt
	if _dash_time <= 0.0:
		_dash_time = 0.0
		dash_ended.emit()


## Charges come back on their OWN timers, TF2-style (§6.1). A shared cooldown would make
## spending both charges cost the same as spending one, which is the whole reason the
## 2-pip HUD exists.
func _update_charges(dt: float) -> void:
	if _regen.is_empty():
		return
	var gained := false
	var i := _regen.size() - 1
	while i >= 0:
		_regen[i] -= dt
		if _regen[i] <= 0.0:
			_regen.remove_at(i)
			_charges = mini(_charges + 1, dash_charges)
			gained = true
		i -= 1
	if gained:
		# The invariant is `_charges + _regen.size() == dash_charges`, and it only holds
		# for a CONSTANT export. Live inspector tuning is the documented workflow for this
		# file, and lowering `dash_charges` while timers are pending made `mini` above
		# silently eat the granted charge while its timer stayed in the queue — the titan
		# then sat below full forever. Trim the queue to what is still owed.
		var owed: int = maxi(dash_charges - _charges, 0)
		while _regen.size() > owed:
			_regen.remove_at(_regen.size() - 1)
		dash_charges_changed.emit(_charges, dash_charges)


# ------------------------------------------------------------------------------ movement

## Turn this tick's intent into a world-space throttle vector. Split out of
## [method _apply_horizontal] so the dash can read it — see the call site.
func _update_wish(it: TitanIntents) -> void:
	var md := it.move_dir
	if _sprinting:
		md.x *= lerpf(1.0, sprint_strafe_mult, _sprint_spool)
	# TORSO frame, not aim frame (§6.1). This single line is the Titanfall feel.
	var b := Basis(Vector3.UP, torso_yaw)
	var wish := b.x * md.x - b.z * md.y
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	_wish = wish
	_wish_dir = wish.normalized() if wish.length_squared() > 1e-6 else Vector3.ZERO


func _apply_horizontal(dt: float, on_floor: bool) -> void:
	var wish := _wish
	var planar := Vector3(body.velocity.x, 0.0, body.velocity.z)
	if _dash_time > 0.0:
		planar = _dash_dir * _dash_target_speed
	else:
		var top := max_speed * lerpf(1.0, sprint_speed_mult, _sprint_spool)
		var rate: float
		if wish.length_squared() > 1e-6:
			rate = accel
		elif on_floor:
			rate = decel
		else:
			rate = 0.0    # no jump means barely any air time; air friction would be invented physics
		planar = planar.move_toward(wish * top, rate * dt)
	body.velocity.x = planar.x
	body.velocity.z = planar.z


func _apply_vertical(dt: float, on_floor: bool) -> void:
	if on_floor:
		# Never positive. No jump — vertical is gravity only (§6.1) — and this is the line
		# that has to stay honest for that claim to survive a refactor.
		body.velocity.y = -GROUND_PRESS
		_air_peak_y = body.global_position.y
	else:
		body.velocity.y -= _gravity * dt
		_air_peak_y = maxf(_air_peak_y, body.global_position.y)


# ------------------------------------------------------------------------------ steps

## Lift the body over a riser up to [member step_height] before `move_and_slide` runs.
##
## Gates, and every one of them is load-bearing:
##  0. The titan must be ON THE FLOOR. Titans have no jump, so the only reason to be
##     airborne is falling, and nothing should climb while falling — without this the
##     assist fires mid-air, teleports up to `step_height` and zeroes `velocity.y`, so a
##     titan dropping off the 30° ramp that brushes a 1.2 m cover box gets a free
##     ledge-snag and hops up it.
##  0b. The capsule must be able to REACH the lifted height. The lift is an UNSWEPT
##     teleport and the probes below only look sideways FROM the raised transform, so
##     under an overhang lower than `step_height` — a doorway lintel over a threshold, a
##     bridge deck with a kerb — the chassis would be teleported into the ceiling and Jolt
##     would eject it. The M1 greybox happens to have no such geometry; a real level will.
##  1. The blocking surface must be too steep to walk. A walkable slope is already handled
##     by `move_and_slide`; assisting it as well launches the titan up every ramp it meets.
##  2. There must be a lift under `step_height` at which the way is clear.
##  3. That lift must clear the way for [constant STEP_PROBE_REACH] metres, not for one
##     frame of motion. This is what tells a stair from a slope: a slope keeps rising, so
##     one tick of clearance is always available and the titan ratchets up a cliff.
##
## The lift teleports. With a rounded capsule bottom, one lift is enough: the chassis
## coasts forward, meets the riser's top edge at a shallow (walkable) contact angle, and
## `move_and_slide` finishes the climb. A smoothed lift is a M6 polish item.
func _step_assist(dt: float) -> void:
	if step_height <= 0.0:
		return
	if not body.is_on_floor():
		return                                              # gate 0: never climb mid-fall
	var motion := Vector3(body.velocity.x, 0.0, body.velocity.z) * dt
	if motion.length_squared() < 1e-8:
		return
	if motion.length() < STEP_MIN_MOTION:
		motion = motion.normalized() * STEP_MIN_MOTION   # see STEP_MIN_MOTION
	var t := body.global_transform
	if not body.test_move(t, motion, _probe):
		return                                              # not blocked; nothing to do
	if _probe.get_normal().angle_to(Vector3.UP) <= deg_to_rad(max_slope_deg):
		return                                              # gate 1: a walkable slope

	var reach := motion.normalized() * maxf(motion.length(), STEP_PROBE_REACH)
	var ceiling := step_height + STEP_GRAZE
	# Gate 0b, and it goes BEFORE the horizontal probes because those all start from a
	# transform we have not yet shown the capsule can legally occupy. Conservative on
	# purpose: it refuses a legal 0.4 m step under a 0.5 m overhang. Refusing to climb is a
	# titan that walks into a wall; not refusing is a titan Jolt spits out of a ceiling.
	if body.test_move(t, Vector3.UP * ceiling):
		return
	if body.test_move(_raised(t, ceiling), reach):
		return                                              # gates 2+3: too tall, or a slope

	var lo := 0.0
	var hi := ceiling
	for _i in STEP_SEARCH_ITERATIONS:
		var mid := (lo + hi) * 0.5
		if body.test_move(_raised(t, mid), reach):
			lo = mid
		else:
			hi = mid
	var lift := hi
	if lift - STEP_GRAZE > step_height or lift <= 0.02:
		return
	# Re-test the ACTUAL lift before committing. Gate 0b already cleared the full ceiling
	# and a swept rise that reaches the ceiling reaches everything below it, so this is
	# belt and braces — but the committing line is an unswept teleport, and the last thing
	# before an unswept teleport should be a swept test of exactly the distance it moves.
	if body.test_move(t, Vector3.UP * lift):
		return

	body.global_position.y += lift
	# Pure horizontal for this tick, so the descent does not immediately re-clip the riser
	# we just cleared. Gravity resumes next tick.
	body.velocity.y = 0.0


func _raised(t: Transform3D, by: float) -> Transform3D:
	return Transform3D(t.basis, t.origin + Vector3.UP * by)


# ------------------------------------------------------------------------------ post-move

func _post_move(_dt: float) -> void:
	var pos := body.global_position
	var on_floor := body.is_on_floor()

	if on_floor and not _was_on_floor:
		var fall: float = maxf(_air_peak_y - pos.y, 0.0)
		if fall >= landing_min_fall:
			landed.emit(fall)
	_was_on_floor = on_floor

	var moved := Vector3(pos.x - _last_pos.x, 0.0, pos.z - _last_pos.z).length()
	_last_pos = pos

	# Distance cadence, spec §10.4's documented fallback for "no method tracks yet". Phase
	# advances with DISTANCE so the stride stays locked through acceleration instead of
	# scurrying when the titan speeds up.
	if on_floor:
		# ⚠ GUARDED DIVISOR, and it is the one that matters most in this file. `stride_length`
		# is an unguarded `@export` on a node whose whole tuning header invites live inspector
		# edits — and `while 0.0 >= 0.0` is an infinite loop that hangs the EDITOR, with the
		# titan standing perfectly still. Every other divisor here is `maxf`-guarded; this
		# one was not.
		var stride: float = maxf(stride_length, 0.05)
		_stride += moved
		while _stride >= stride:
			_stride -= stride
			_next_foot = &"right" if _next_foot == &"left" else &"left"
			var strength: float = clampf(planar_speed() / maxf(max_speed, 0.001), 0.25, 1.0)
			footstep.emit(_next_foot, strength * (1.0 + 0.4 * _sprint_spool))
	else:
		_stride = 0.0

	var speed := planar_speed()
	if _moving and speed < 0.3:
		_moving = false
		stopped_moving.emit()
	elif not _moving and speed > 0.6:
		_moving = true
		started_moving.emit()
