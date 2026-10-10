class_name VehicleNav
extends RefCounted
## The vehicle map (Docs/AIVehicles.md 3): where a vehicle can drive, read from
## the bricks as the walking map is.
##
## It IS the walking map's machinery -- an AINav, one column a stud square, a
## floor a plate a body stands on -- told a vehicle's numbers instead of a
## figure's (AINav.set_agent, as the mech map is): its footprint is its WIDTH
## and a hand's margin, square, so a path only goes where the whole of it fits
## between walls; the air it needs is its HEIGHT, so it never goes under what it
## would hit; its step is a plate or two, so a kerb is a way and a staircase is
## not; and it drops no more than a kerb's worth. A hole shot in a wall is a way
## the moment it is wide enough, as it is for a body -- nothing is baked.
##
## Not yet (AIVehicles.md 3): rubble dearer than road, and a tracked vehicle
## crushing low walls and rubble -- a tank goes round them like a truck.
##
## One map per KIND, kept by AIServices (vehicle_nav) and served in its tick.

const STUD := 0.35
const PLATE := 0.14
## A vehicle's margin, each side, over its width: a path along a wall leaves it
## this much air, and a corner cut by a turn is not one it scrapes.
const MARGIN := 0.15

## What each kind is, for its map: width and height in metres (its whole body,
## clearance included), plates it climbs (a kerb is two, a brick course three)
## and plates it drops off an edge.
const KINDS := {
	&"truck": {"width": 2.3, "height": 2.4, "step": 2, "drop": 4, "mobility": &"wheeled"},
	&"tank": {"width": 3.15, "height": 2.92, "step": 3, "drop": 5, "mobility": &"tracked"},
}


static func has_kind(kind: StringName) -> bool:
	return KINDS.has(kind)


## The map a vehicle of `kind` drives, over `ai_world`.
static func make(ai_world: AIWorld, kind: StringName) -> AINav:
	var k: Dictionary = KINDS[kind]
	var n := AINav.new()
	n.set_ai_world(ai_world)
	n.set_agent(span_of(kind), head_of(kind), head_of(kind), int(k.step), int(k.drop), int(k.drop))
	return n


## Studs square a vehicle of `kind` takes on its map.
static func span_of(kind: StringName) -> int:
	return int(ceil((float(KINDS[kind].width) + MARGIN * 2.0) / STUD))


static func head_of(kind: StringName) -> int:
	return int(ceil(float(KINDS[kind].height) / PLATE))


## The place nearest `goal` a vehicle can drive to on `nav`: `goal` itself when
## it fits there, else the nearest spot round it within `max_r` metres, at about
## its height -- a street beside a building, not the roof of it. INF for none.
static func reach_point(nav: AINav, goal: Vector3, max_r := 24.0) -> Vector3:
	if nav == null or goal == Vector3.INF:
		return Vector3.INF
	var at := nav.snap(goal)
	if nav.can_stand(at) and _flat(at - goal).length() < 2.0 and absf(at.y - goal.y) < 1.5:
		return at
	var r := 2.0
	while r <= max_r:
		var best := Vector3.INF
		var best_d := INF
		var n := maxi(8, int(TAU * r / 2.0))
		for i in n:
			var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / n)
			var q := nav.snap(goal + dir * r)
			if not nav.can_stand(q) or absf(q.y - goal.y) > 2.0:
				continue
			var d := q.distance_to(goal)
			if d < best_d:
				best_d = d
				best = q
		if best != Vector3.INF:
			return best
		r += 2.0
	return Vector3.INF


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
