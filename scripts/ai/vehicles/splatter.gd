class_name Splatter
extends RefCounted
## A vehicle running a body down (Halo's splatter; Docs/AIVehicles.md 4.1).
##
## Each tick a driven vehicle moving faster than MIN_SPEED looks along its nose
## for bodies of another side in the box it is about to sweep -- its width, from
## its middle to REACH past its front, a body's height -- and hits each one for
## DAMAGE_PER_MS a metre a second over MIN_SPEED, once a HIT_EVERY seconds per
## body. Its own side, anybody riding on or boarding a vehicle, and anybody
## inside one are spared.

const MIN_SPEED := 4.0
const DAMAGE_PER_MS := 30.0
const REACH := 0.8
const HIT_EVERY := 1.0


## `v` (a Tank or TransportTruck) of `half` its width and length, moving at
## `speed` along `fwd`, its feet at `feet`. `last` remembers who was hit when
## (instance id -> time). Returns how many it hit.
static func run_down(s: AIServices, v: Node3D, team: int, feet: Vector3, fwd: Vector3, half: Vector2,
		speed: float, last: Dictionary) -> int:
	if s == null or absf(speed) < MIN_SPEED:
		return 0
	var nose := fwd * signf(speed)
	var side := Vector3(-nose.z, 0.0, nose.x)
	var now := s.now()
	var hits := 0
	for p in s.pawns:
		if not is_instance_valid(p) or p.team == team or p.health == null or p.health.is_dead():
			continue
		if p.has_meta(&"in_vehicle") or p.has_meta(&"in_mech") or p.has_meta(&"vehicle") \
				or p.has_meta(&"aboard") or p.has_meta(&"riding"):
			continue
		var d := p.feet() - feet
		if d.y < -0.5 or d.y > 1.5:
			continue
		var along := d.dot(nose)
		if along < 0.0 or along > half.y + REACH or absf(d.dot(side)) > half.x + 0.3:
			continue
		var id := p.get_instance_id()
		if now - float(last.get(id, -INF)) < HIT_EVERY:
			continue
		last[id] = now
		p.health.apply_impact((absf(speed) - MIN_SPEED) * DAMAGE_PER_MS + DAMAGE_PER_MS, &"")
		hits += 1
	return hits
