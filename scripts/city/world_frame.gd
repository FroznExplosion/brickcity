class_name WorldFrame

## WHERE THE SCENE IS, in the frame of the body it stands on (Docs/Planets.md
## 9.6).
##
## A floating origin (STA's `solar_system.gd` rebases every 500 m) moves the
## scene's origin under the player, so a world-space position is only
## meaningful until the next rebase. What outlives a frame -- a save, a command
## on the wire -- is written in the BODY's frame instead: `to_body` on the way
## out, `from_body` on the way in.
##
## Today there is no floating origin and the body is the flat world, so
## `origin` is zero and both are the identity. A rebase is what will move it.

## The scene origin's position in the body's frame.
static var origin := Vector3.ZERO


static func to_body(p: Vector3) -> Vector3:
	return p + origin


static func from_body(p: Vector3) -> Vector3:
	return p - origin


static func xform_to_body(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis, t.origin + origin)


static func xform_from_body(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis, t.origin - origin)
