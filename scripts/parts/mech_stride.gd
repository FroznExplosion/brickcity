class_name MechStride
extends Node
## A mech's walk (MotionSets "mech.walk.*"): the legs swing at the hips, left against right,
## the stride worked out from the legs' length so the feet keep pace with the ground -- one
## walk for every leg length, a boss's too (Docs/ModularParts.md section 8).
##
## A leg `hip_height` long swung `a` either side of straight down covers 2 h sin(a) a step.
## The swing grows with speed up to `swing_max` at RUN; the cadence is whatever makes a
## step's length times steps a second the speed. Longer legs, the same speed: slower steps.

## The speed the swing is at its widest, m/s.
const RUN := 9.0

var set_id := ""
var mech: Mech
var hips: Array[Node3D] = []
## The knees, one a hip (null where a leg has none): the leg folds as it swings forward.
var knees: Array = []
## Arms that swing against the legs as it walks (a figure's; a mech's gun arm aims), and
## their elbows.
var arms: Array[Node3D] = []
var elbows: Array = []
const KNEE_FOLD := 1.1
const ELBOW_BEND := 0.35
var hip_height := 3.36
var swing_max := 0.45
var phase := 0.0
## The swing now, radians either side, and the last step's length and rate: for gates.
var swing := 0.0
var stride := 0.0
var cadence := 0.0


func _physics_process(delta: float) -> void:
	if mech == null or mech.body == null:
		return
	step(delta, Gravity.flat(mech.body.velocity, mech.motor.up).length())


## Move the legs on by `dt` at ground speed `speed`.
func step(dt: float, speed: float) -> void:
	var a := swing_max * clampf(speed / RUN, 0.0, 1.0)
	stride = 2.0 * hip_height * sin(a)
	# Half a cycle (pi of phase) is one step: steps a second = speed / stride.
	cadence = speed / stride if stride > 0.001 else 0.0
	phase = fmod(phase + PI * cadence * dt, TAU)
	swing = a * sin(phase)
	var amount := clampf(speed / RUN, 0.0, 1.0)
	for i in hips.size():
		if is_instance_valid(hips[i]):
			hips[i].rotation.x = swing if i % 2 == 0 else -swing
		# The knee folds while its leg swings through, the foot clearing the ground: the
		# half of the cycle the leg is moving forward.
		var k: Node3D = knees[i] if i < knees.size() else null
		if k != null and is_instance_valid(k):
			var through := cos(phase) if i % 2 == 0 else -cos(phase)
			k.rotation.x = -KNEE_FOLD * amount * maxf(through, 0.0)
	for i in arms.size():
		if is_instance_valid(arms[i]):
			arms[i].rotation.x = (-swing if i % 2 == 0 else swing) * 0.6
		var e: Node3D = elbows[i] if i < elbows.size() else null
		if e != null and is_instance_valid(e):
			e.rotation.x = ELBOW_BEND * (0.4 + amount)


## How fast the feet go past the body at the speed it is walking: the speed, if nothing skids.
func foot_speed() -> float:
	return stride * cadence
