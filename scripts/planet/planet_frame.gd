class_name PlanetFrame
extends RefCounted

## The floating origin of a planet scene (Docs/Planets.md 10b, 11): translation
## only, so nothing turns, and nothing on the planet streams again -- it is all
## a child of the planet's node, which moves with everything else. Shift when
## the player is SHIFT_AT from the origin (test 1: nothing a player can see
## before ~8 km; 4 km halves the shifts of the 2 km first planned).
##
## Moves every Node3D with no Node3D above it under `root`, resets each one's
## physics interpolation (a shift is a teleport, not motion), and moves
## WorldFrame.origin the other way so a saved position keeps its meaning.
## Anything holding a WORLD position in a variable must be told: `shifted`.

const SHIFT_AT := 4000.0

static var shifts := 0
static var last_us := 0


## Move the scene so `point` lands at the origin. Returns the offset applied.
static func recentre(root: Node, point: Vector3) -> Vector3:
	var offset := -point
	var t0 := Time.get_ticks_usec()
	var moved: Array[Node3D] = []
	_collect(root, moved, false)
	for n in moved:
		n.global_position += offset
	for n in moved:
		n.reset_physics_interpolation()
	WorldFrame.origin -= offset
	shifts += 1
	last_us = Time.get_ticks_usec() - t0
	return offset


static func _collect(n: Node, out: Array[Node3D], under3d: bool) -> void:
	for c in n.get_children():
		var is3d := c is Node3D
		if is3d and (not under3d or (c as Node3D).top_level):
			out.append(c)
		_collect(c, out, under3d or is3d)
