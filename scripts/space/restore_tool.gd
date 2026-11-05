class_name RestoreTool
extends RefCounted
## The restore tool (Docs/Hulls.md 9, front end B -- Red Faction: Armageddon's
## Reconstructor): held on a ship's or station's hull, the bricks it has lost within
## RADIUS of where it points come back, the ones at the hole's edge first
## (SpaceStation.restorable), RATE a second. Each is a RESTORE command
## (SpaceStation.restore), so it records, saves and replays as a hit does.
##
## What a brick costs is a design value nobody has picked yet (Docs/Hulls.md 13);
## `cost` is how many it may still lay (-1: no limit), for when it is.

## How far it reaches, metres along the view.
const RANGE := 6.0
## How far round the aim point it gathers lost bricks, metres.
const RADIUS := 2.5
## Bricks a second.
const RATE := 8.0

var cost := -1
## While held: the ship or station it is working on, and bricks laid this hold.
var target: SpaceStation = null
var laid := 0
var _owed := 0.0


## One frame. `from` and `dir` are the view (world); `holding` is the button.
## `structures` are the ships and stations to look in. Returns the bricks laid.
func tick(dt: float, holding: bool, from: Vector3, dir: Vector3, structures: Array,
		space: PhysicsDirectSpaceState3D = null) -> int:
	if not holding:
		target = null
		laid = 0
		_owed = 0.0
		return 0
	var at := aim_point(from, dir, space)
	_owed = minf(_owed + RATE * dt, RATE)
	var n := int(_owed)
	if n <= 0:
		return 0
	for s in structures:
		var st := s as SpaceStation
		# Flown, it is worked on through its ghost (Docs/Hulls.md 7b).
		if st == null or not st.bricked or (st.riding and st.ghost == null):
			continue
		var ids := st.restorable(at, RADIUS)
		if ids.is_empty():
			continue
		if cost >= 0:
			n = mini(n, cost)
		if n <= 0:
			return 0
		var back := st.restore(ids.slice(0, n), at, RADIUS)
		_owed -= float(n)
		target = st
		laid += back.size()
		if cost >= 0:
			cost -= back.size()
		return back.size()
	_owed = 0.0
	target = null
	return 0


## Where it points: what the view ray meets within RANGE, or RANGE along it (a
## hole has nothing to meet -- the bricks it would hit are the lost ones).
static func aim_point(from: Vector3, dir: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	var to := from + dir.normalized() * RANGE
	if space != null:
		# Bricks only: never the pawn the view is in. Through a flown ship's ghost,
		# never its shell box (ShipRays).
		var q := PhysicsRayQueryParameters3D.create(from, to, Layers.STRUCTURE)
		var hit := ShipRays.cast(space, q)
		if not hit.is_empty():
			return hit.position
	return to
