class_name PodArmMotion
extends Node
## A pod's own arm (MotionSets "pod.arm.*", Docs/ModularParts.md sections 4 and 8): the pod
## swings about its foot on the chassis when it is used -- a strike winds back and hammers
## down and forward; a throw winds further back and flings. Then it settles to rest.

## Keyframes per style: [seconds, pitch radians]; forward-down is positive.
const STYLES := {
	"strike": [[0.0, 0.0], [0.18, -0.7], [0.32, 1.25], [0.7, 0.0]],
	"throw": [[0.0, 0.0], [0.3, -1.1], [0.45, 0.85], [0.9, 0.0]],
}

var set_id := ""
var style := "strike"
## What swings: the pod's joint on the chassis, or its stand-in.
var target: Node3D
var _t := -1.0
var _rest := 0.0


func play() -> void:
	if target == null:
		return
	if _t < 0.0:
		_rest = target.rotation.x
	_t = 0.0


func playing() -> bool:
	return _t >= 0.0


func length() -> float:
	var keys: Array = STYLES.get(style, STYLES.strike)
	return float(keys[-1][0])


func _physics_process(delta: float) -> void:
	if _t < 0.0 or target == null or not is_instance_valid(target):
		return
	_t += delta
	target.rotation.x = _rest + pitch_at(_t)
	if _t >= length():
		target.rotation.x = _rest
		_t = -1.0


## The swing at `t` seconds into the move.
func pitch_at(t: float) -> float:
	var keys: Array = STYLES.get(style, STYLES.strike)
	for i in range(1, keys.size()):
		if t <= float(keys[i][0]):
			var a: Array = keys[i - 1]
			var b: Array = keys[i]
			var f := (t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.0001)
			return lerpf(float(a[1]), float(b[1]), smoothstep(0.0, 1.0, f))
	return 0.0
