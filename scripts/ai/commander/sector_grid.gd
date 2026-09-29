class_name SectorGrid
extends RefCounted
## The commander's map (Docs/AI.md 9): the ground cut into SECTOR-metre squares,
## each holding what the side knows of it -- how strong it is there, where the
## enemy has been seen, where its own have died. Coarse on purpose: the commander
## never pathfinds and never aims, it weighs places.
##
## Everything but its own strength decays (HALF_LIFE): a sector where three men
## fell a minute ago is still a bad idea; one where they fell ten minutes ago is
## just a place.
##
## What it answers: danger(point) -- how bad a place is to send or spawn men,
## from threat seen and losses taken there and next door -- and safest(points),
## the pick of a host's candidate spawn spots.

const SECTOR := 32.0
const HALF_LIFE := 60.0
## How much a loss weighs against a sighting.
const LOSS_WEIGHT := 2.0
## A neighbour's share of a sector's danger.
const SPILL := 0.35

var _threat := {}   # Vector2i -> weight
var _loss := {}     # Vector2i -> weight
var _ours := {}     # Vector2i -> points up there now (recounted by the commander)


static func key(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / SECTOR), floori(p.z / SECTOR))


func decay(dt: float) -> void:
	var k := pow(0.5, dt / HALF_LIFE)
	for d in [_threat, _loss]:
		for c in d.keys():
			d[c] = float(d[c]) * k
			if float(d[c]) < 0.01:
				d.erase(c)


func note_threat(p: Vector3, weight := 1.0) -> void:
	var c := key(p)
	_threat[c] = float(_threat.get(c, 0.0)) + weight


func note_loss(p: Vector3, points := 1.0) -> void:
	var c := key(p)
	_loss[c] = float(_loss.get(c, 0.0)) + points


## The side's own strength, recounted from scratch: {point: points}.
func set_ours(where: Array) -> void:
	_ours.clear()
	for e in where:
		var c := key(e[0])
		_ours[c] = float(_ours.get(c, 0.0)) + float(e[1])


func ours(p: Vector3) -> float:
	return float(_ours.get(key(p), 0.0))


func threat(p: Vector3) -> float:
	return float(_threat.get(key(p), 0.0))


func losses(p: Vector3) -> float:
	return float(_loss.get(key(p), 0.0))


## How bad a place `p` is: threat and losses there, and a share of next door's.
func danger(p: Vector3) -> float:
	var c := key(p)
	var d := _cell(c)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if dx != 0 or dz != 0:
				d += SPILL * _cell(c + Vector2i(dx, dz))
	return d


func _cell(c: Vector2i) -> float:
	return float(_threat.get(c, 0.0)) + LOSS_WEIGHT * float(_loss.get(c, 0.0))


## The least dangerous of `points`, or INF with none.
func safest(points: Array) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for p in points:
		var d := danger(p)
		if d < best_d:
			best_d = d
			best = p
	return best


func to_dict() -> Dictionary:
	var t := {}
	for c in _threat:
		t["%d,%d" % [c.x, c.y]] = _threat[c]
	var l := {}
	for c in _loss:
		l["%d,%d" % [c.x, c.y]] = _loss[c]
	return {"threat": t, "loss": l}
