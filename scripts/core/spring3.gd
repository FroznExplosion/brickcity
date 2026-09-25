## spring3.gd
## Vector3 form of [Spring]. Same maths, same parameters, one set of coefficients
## shared across all three axes — see spring.gd for the full parameter explanation
## and the reason a single spring implementation exists.
##
## This is the one most consumers want: camera position offset, weapon muzzle offset,
## hand/foot IK target smoothing, titan chassis sway. Rotation offsets use it too,
## as euler radians (small-angle, which every one of those cases is); a quaternion
## variant only becomes necessary if something needs to spring past 90 degrees.
##
## Kept as its own type rather than three [Spring]s so an impulse is one call and one
## allocation, and so the per-step coefficient work happens once instead of three times.
class_name Spring3
extends RefCounted

var value: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO

var _k1: float = 0.0
var _k2: float = 0.0
var _k3: float = 0.0
var _prev_target: Vector3 = Vector3.ZERO
var _has_prev: bool = false


func _init(frequency: float = 6.0, damping: float = 1.0, response: float = 0.0,
		initial: Vector3 = Vector3.ZERO) -> void:
	configure(frequency, damping, response)
	reset(initial)


## Retune without disturbing current value/velocity — safe from a live tuning slider.
func configure(frequency: float, damping: float, response: float) -> void:
	var f: float = maxf(frequency, 0.0001)
	var w: float = TAU * f
	_k1 = damping / (PI * f)
	_k2 = 1.0 / (w * w)
	_k3 = response * damping / w


func reset(initial: Vector3) -> void:
	value = initial
	velocity = Vector3.ZERO
	_prev_target = initial
	_has_prev = true


## Inject an instantaneous impulse — hit direction, recoil kick, parry deflection,
## landing thud. Direction and magnitude both matter; the spring resolves the rest.
func add_velocity(v: Vector3) -> void:
	velocity += v


## Advance one step toward `target`. Pass `target_velocity` when known (the estimate
## is a finite difference and is noisy at low frame rates; `response` amplifies it).
func update(delta: float, target: Vector3,
		target_velocity: Variant = null) -> Vector3:
	if delta <= 0.0:
		return value

	var xd: Vector3
	if target_velocity is Vector3:
		xd = target_velocity
	elif _has_prev:
		xd = (target - _prev_target) / delta
	else:
		xd = Vector3.ZERO
	_prev_target = target
	_has_prev = true

	# Stability clamp — bounded for any delta, so a hitch cannot fling the camera.
	var k2: float = maxf(_k2, 1.1 * (delta * delta * 0.25 + delta * _k1 * 0.5))

	value += delta * velocity
	velocity += delta * (target + _k3 * xd - value - _k1 * velocity) / k2
	return value


## Classic spring-damper constants (titan spec §7.1: x'' = -k*x - c*x').
static func from_kc(k: float, c: float, response: float = 0.0,
		initial: Vector3 = Vector3.ZERO) -> Spring3:
	var w: float = sqrt(maxf(k, 0.0001))
	return Spring3.new(w / TAU, c / (2.0 * w), response, initial)
