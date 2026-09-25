## spring.gd
## Second-order damped spring for ONE scalar.
##
## The single shared implementation of "smoothed value with weight, lag and overshoot"
## for the whole stack. Three specs each described their own spring independently —
## ProceduralCombat §2 (head-bone camera stabilisation), §3 (weapon weight, recoil,
## drag, hit-stop), and the titan spec §7.1 (piloted-camera impulse rig) — plus STA's
## `recoil_holder.gd`. Four implementations would mean four tuning vocabularies across
## three games. This is the one they all use.
##
## Parameterised by FEEL, not by k/c:
##   frequency (f, Hz) — speed of response. Higher = snappier. This is the frequency
##                       the system would ring at if undamped.
##   damping   (z)     — 0 = ring forever, <1 = overshoot then settle,
##                       1 = critical (fastest with no overshoot), >1 = sluggish.
##   response  (r)     — 0 = eases out of rest, 1 = reacts immediately to target
##                       velocity, >1 = overshoots the target, <0 = ANTICIPATES
##                       (winds up the wrong way first — good for wind-up on swings).
##
## The classic `x'' = -k*x - c*x'` form in the titan spec maps in via from_kc().
##
## Integration is semi-implicit with a stability clamp on k2, so it cannot explode at
## low frame rates or on a hitch. That matters: this runs the camera.
##
## Impulses (§3: "instantaneous physical impulses are injected into the spring system"
## on hit and parry) go through add_velocity() — they perturb velocity directly and let
## the spring resolve the recoil naturally, rather than animating a canned recoil.
##
## Time scale: pass an already-dilated delta (see EntityTime). This class is
## deliberately unaware of time scaling so a UI spring and an entity spring can share it.
class_name Spring
extends RefCounted

var value: float = 0.0
var velocity: float = 0.0

var _k1: float = 0.0
var _k2: float = 0.0
var _k3: float = 0.0
var _prev_target: float = 0.0
var _has_prev: bool = false


func _init(frequency: float = 6.0, damping: float = 1.0, response: float = 0.0,
		initial: float = 0.0) -> void:
	configure(frequency, damping, response)
	reset(initial)


## Retune without disturbing the current value/velocity — safe to call from a live
## tuning slider mid-motion.
func configure(frequency: float, damping: float, response: float) -> void:
	var f: float = maxf(frequency, 0.0001)
	var w: float = TAU * f
	_k1 = damping / (PI * f)
	_k2 = 1.0 / (w * w)
	_k3 = response * damping / w


## Teleport: value goes there, all motion is discarded.
func reset(initial: float) -> void:
	value = initial
	velocity = 0.0
	_prev_target = initial
	_has_prev = true


## Inject an instantaneous impulse (hit-stop kick, recoil, parry deflection).
func add_velocity(v: float) -> void:
	velocity += v


## Advance one step toward `target`.
## `target_velocity` is the target's own rate of change; leave it NAN to have it
## estimated by finite difference. Pass the real value when you have it (e.g. the
## player's angular velocity driving a camera spring) — the estimate is noisy at
## low frame rates and `response` amplifies that noise.
func update(delta: float, target: float, target_velocity: float = NAN) -> float:
	if delta <= 0.0:
		return value

	var xd: float = target_velocity
	if is_nan(xd):
		xd = (target - _prev_target) / delta if _has_prev else 0.0
	_prev_target = target
	_has_prev = true

	# Stability clamp. Guarantees the semi-implicit step stays bounded for ANY delta,
	# so a stall or a breakpoint cannot fling the camera.
	var k2: float = maxf(_k2, 1.1 * (delta * delta * 0.25 + delta * _k1 * 0.5))

	value += delta * velocity
	velocity += delta * (target + _k3 * xd - value - _k1 * velocity) / k2
	return value


## Build from the classic spring-damper constants (titan spec §7.1 form):
##   x'' = -k*x - c*x'   ->   f = sqrt(k)/2pi,  z = c / (2*sqrt(k))
static func from_kc(k: float, c: float, response: float = 0.0, initial: float = 0.0) -> Spring:
	var w: float = sqrt(maxf(k, 0.0001))
	return Spring.new(w / TAU, c / (2.0 * w), response, initial)
