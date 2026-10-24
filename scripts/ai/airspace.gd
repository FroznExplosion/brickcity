class_name Airspace
extends RefCounted
## Where flyers and the ground share space (Docs/AI.md 5.2a): one per side's
## services, the ledger everybody asks before they move into the other's way.
##
##   LANES        flyers fly at heights a lane apart (lane_of), so two circling
##                one target are not at one height.
##   SEPARATION   a flyer is pushed off any other flyer nearer than SEPARATION,
##                and up off the top of a tall body (a mech, a tank) it is over.
##   PADS         a flyer that comes down claims a pad first (claim_pad): a
##                circle on the ground with a DANGER box over it in AIWorld, so
##                soldiers clear it as they clear a falling piece's shadow
##                (BTEvade), ground vehicles hold short of it (blocks), and
##                another flyer cannot claim one over it. It comes down only
##                while the pad is clear (pad_clear); somebody on it, it waits
##                over it. Lifted off, it gives the pad up (release_pad).
##
## Nothing here moves anybody: it answers, and the movers do what it says.

## Flyers keep this far apart; a flyer over a tall body keeps this far over it.
const SEPARATION := 6.0
const OVER_TALL := 2.5
## Height between lanes, and how many.
const LANE := 3.0
const LANES := 3
## A pad's danger box: this high over the ground (the flyer's way down).
const PAD_HEIGHT := 12.0
## Danger ids for pads, clear of the pieces' (chunk ids).
const PAD_ID_BASE := 1 << 27

var services: AIServices
## Every flyer in the air, any side: Flyer nodes.
var flyers: Array = []
## id -> {"owner": Object, "at": Vector3, "radius": float}
var pads := {}
var _next_pad := 0
## Flyer -> its lane, given in turn as they come.
var _lanes := {}
var _next_lane := 0


func _init(s: AIServices) -> void:
	services = s


func register(f: Object) -> void:
	if not flyers.has(f):
		flyers.append(f)
		_lanes[f] = _next_lane % LANES
		_next_lane += 1


func unregister(f: Object) -> void:
	flyers.erase(f)
	_lanes.erase(f)
	for id in pads.keys():
		if pads[id].owner == f:
			release_pad(id)


## The height over its usual one `f` flies at: its lane.
func lane_of(f: Object) -> float:
	return float(_lanes.get(f, 0)) * LANE


## Which way to push `f`, at `p`, off the others: away from every flyer within
## SEPARATION (harder the nearer), and up off a tall body it is close over.
func separation(f: Object, p: Vector3) -> Vector3:
	var push := Vector3.ZERO
	for o in flyers:
		if o == f or not is_instance_valid(o) or o.is_dead():
			continue
		var q: Vector3 = o.body.global_position
		var d := p.distance_to(q)
		if d < SEPARATION and d > 0.01:
			push += (p - q) / d * (SEPARATION - d)
	for b in services.pawns:
		if not is_instance_valid(b) or b.stand_height < 2.5 or b.health == null or b.health.is_dead():
			continue
		var up := Gravity.up_at(b.feet())
		var top := Gravity.height_of(b.feet()) + b.stand_height
		var flat := Gravity.flat(p - b.feet(), up).length()
		var h := Gravity.height_of(p)
		if flat < 4.0 and h < top + OVER_TALL:
			push += up * ((top + OVER_TALL - h) * 2.0)
	return push


## Claim a pad at `at` (its ground), `radius` round, for `owner` to come down
## on. -1 if another pad is there already.
func claim_pad(owner: Object, at: Vector3, radius: float) -> int:
	for id in pads:
		var o: Dictionary = pads[id]
		if Gravity.flat(at - (o.at as Vector3), Gravity.up_at(at)).length() < radius + float(o.radius):
			return -1
	var id := PAD_ID_BASE + _next_pad
	_next_pad += 1
	pads[id] = {"owner": owner, "at": at, "radius": radius}
	if services.ai_world != null:
		services.set_danger(id, _box(at, radius))
	return id


func release_pad(id: int) -> void:
	if pads.erase(id) and services.ai_world != null:
		services.remove_danger(id)


## Is the pad free of everybody but its owner -- bodies, vehicles, other flyers
## under its owner?
func pad_clear(id: int) -> bool:
	if not pads.has(id):
		return false
	var pad: Dictionary = pads[id]
	var at: Vector3 = pad.at
	var r := float(pad.radius)
	for b in services.pawns:
		if not is_instance_valid(b) or b.health == null or b.health.is_dead() or b.has_meta(&"in_vehicle"):
			continue
		var f := b.feet()
		var up := Gravity.up_at(at)
		if Gravity.flat(f - at, up).length() < r + 0.5 and absf(Gravity.vert(f - at, up)) < 3.0:
			return false
	for o in flyers:
		if o == pad.owner or not is_instance_valid(o) or o.is_dead():
			continue
		var q: Vector3 = o.body.global_position
		if Gravity.flat(q - at, Gravity.up_at(at)).length() < r \
				and Gravity.height_of(q) < Gravity.height_of(at) + PAD_HEIGHT:
			return false
	return true


## Does a pad cover `p` (with `margin`)? Ground vehicles hold short of one.
func blocks(p: Vector3, margin := 0.0) -> bool:
	for id in pads:
		var o: Dictionary = pads[id]
		if Vector2(p.x - o.at.x, p.z - o.at.z).length() < float(o.radius) + margin:
			return true
	return false


## Put the pads' danger back: after the pieces' boxes were cleared (Danger).
func refresh() -> void:
	if services.ai_world == null:
		return
	for id in pads:
		services.set_danger(id, _box(pads[id].at, float(pads[id].radius)))


static func _box(at: Vector3, radius: float) -> AABB:
	return AABB(at - Vector3(radius, 0.2, radius), Vector3(radius * 2.0, PAD_HEIGHT, radius * 2.0))
