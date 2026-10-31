class_name Drift
extends RefCounted

## A piece adrift (Docs/Planets.md 11.12 step 6; Space.md §4): no body, no
## physics. Where it is and how it is turned come from its age alone, in the
## frame it left: `p0 + v t`, `q0` spun by `rate` about `axis`.

## A station it goes on orbiting with; null: `base`, the star's frame where it left.
var frame: Node3D
var base := Transform3D()
var p0 := Vector3.ZERO
var q0 := Basis()
var v := Vector3.ZERO
var axis := Vector3.UP
var rate := 0.0
var born := 0.0
var bricks := 0
var node: Node3D
## Its mesh while a worker makes it, drawn so its centre of mass is at `node`.
var task := -1
var holder: Array = []
var material: Material
var draw_at := Vector3.ZERO


## Its place in its frame at clock `now`.
func at(now: float) -> Transform3D:
	var age := now - born
	return Transform3D(Basis(axis, rate * age) * q0, p0 + v * age)
