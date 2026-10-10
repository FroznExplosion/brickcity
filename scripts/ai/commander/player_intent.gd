class_name PlayerIntent
extends RefCounted
## What the players are up to, as the FRIENDLY commander reads it (Docs/AIRoster.md
## 8, R12, R13): the player gives friendlies no orders, so the commander infers
## them -- where the players are going, what they are shooting at, and what they
## have told their mechs to do -- and sends its squads to support that.
##
## The FOCUS is where the fight the players are making is: the enemy a player
## shot at in the last SHOT_MEMORY seconds; else a point a player's mech was told
## to attack; else where the players are heading (HEAD_AHEAD seconds on at their
## pace); else where they stand.
##
## A player's LANE is the line from its eye along its look, LANE_LENGTH out:
## where its rounds go. A friendly never stands in one (`in_lane`), so it is
## never in front of a player's gun; `support_point` puts a squad beside the
## players and the fight, on a side with no lane through it.

const SHOT_MEMORY := 8.0
const HEAD_AHEAD := 4.0
const LANE_LENGTH := 60.0
## A body this near a lane is in it.
const LANE_CLEAR := 3.5
## A squad supports from this far to the side of the line player -> focus, and
## this far ahead of the player along it.
const SIDE := 10.0
const AHEAD := 4.0
## Below this pace a player is standing, not going anywhere.
const MOVING := 1.0

var services: AIServices
## () -> Array[Pawn]: the players, on foot or as their mechs' pawns.
var players := Callable()
## () -> Array[MechBrain]: the players' own mechs, for their orders.
var mechs := Callable()

## Player instance id -> {pos, at, vel}: where it was at its last look.
var _track := {}
## The last thing a player shot at: {pos, at, pawn}.
var last_target := {}
var _watched := {}


func _init(s: AIServices) -> void:
	services = s


## Look at the players: their pace, and -- the first time -- their guns.
func observe() -> void:
	var now := services.now()
	for p in _players():
		var k := p.get_instance_id()
		var at := p.feet()
		var was: Dictionary = _track.get(k, {})
		var vel := Vector3.ZERO
		if not was.is_empty() and now > float(was.at):
			vel = (at - (was.pos as Vector3)) / (now - float(was.at))
			vel.y = 0.0
			vel = (was.vel as Vector3).lerp(vel, 0.5)
		_track[k] = {"pos": at, "at": now, "vel": vel}
		if p.gun != null and not _watched.has(p.gun.get_instance_id()):
			_watched[p.gun.get_instance_id()] = true
			p.gun.fired.connect(_on_player_fired.bind(p))


## A player's round: what it hit, if it was an enemy, is what it is shooting at.
func _on_player_fired(info: Dictionary, p: Pawn) -> void:
	if info.is_empty():
		return
	var who := _pawn_of(info.get("collider"))
	if who != null and who.team != p.team:
		last_target = {"pos": who.feet(), "at": services.now(), "pawn": who}
	elif not bool(info.get("structure", false)) or last_target.is_empty() \
			or services.now() - float(last_target.at) > SHOT_MEMORY:
		# Shooting at a wall, at nothing seen: where the rounds land.
		last_target = {"pos": info.get("point", p.feet()), "at": services.now(), "pawn": null}


static func _pawn_of(collider: Variant) -> Pawn:
	var n := collider as Node
	if n == null:
		return null
	var p := n.get_node_or_null(^"Pawn") as Pawn
	return p


func _players() -> Array[Pawn]:
	var out: Array[Pawn] = []
	if not players.is_valid():
		return out
	for p in players.call():
		if p != null and is_instance_valid(p) and (p.health == null or not p.health.is_dead()):
			out.append(p)
	return out


## Where the players' fight is (see the header), and why: [point, why]; INF with
## no players.
func focus() -> Array:
	var now := services.now()
	if not last_target.is_empty() and now - float(last_target.at) < SHOT_MEMORY:
		var t: Pawn = last_target.pawn
		if t != null and is_instance_valid(t) and t.health != null and not t.health.is_dead():
			return [t.feet(), "what they are shooting at"]
		return [last_target.pos, "where they are shooting"]
	if mechs.is_valid():
		for br in mechs.call():
			var b := br as MechBrain
			if b != null and is_instance_valid(b) and b.order == MechBrain.Order.ATTACK_AREA:
				return [b.order_point, "where they sent their mech"]
	var ps := _players()
	if ps.is_empty():
		return [Vector3.INF, "no players"]
	var lead := ps[0]
	var tr: Dictionary = _track.get(lead.get_instance_id(), {})
	var vel: Vector3 = tr.get("vel", Vector3.ZERO)
	if vel.length() > MOVING:
		return [lead.feet() + vel * HEAD_AHEAD, "where they are going"]
	return [lead.feet(), "where they are"]


## Is `at` in front of a player's gun: within LANE_CLEAR of a player's lane?
func in_lane(at: Vector3) -> bool:
	for p in _players():
		if p.eye == null:
			continue
		var from := p.eye.global_position
		var dir := -p.eye.global_basis.z
		var to := at + Vector3.UP * 1.2 - from
		var along := to.dot(dir)
		if along < 0.0 or along > LANE_LENGTH:
			continue
		if (to - dir * along).length() < LANE_CLEAR:
			return true
	return false


## The player nearest `at`, or null.
func nearest_player(at: Vector3) -> Pawn:
	var best: Pawn = null
	for q in _players():
		if best == null or q.feet().distance_to(at) < best.feet().distance_to(at):
			best = q
	return best


## Where squad number `slot` should be to support the players' fight at `f`: beside
## the line from the nearest player to it, SIDE out and AHEAD on, on the side the
## slot's parity names first -- then the other -- and never in a lane. INF if
## there is no player, or both sides are in front of a gun.
func support_point(f: Vector3, slot := 0) -> Vector3:
	var p := nearest_player(f)
	if p == null or f == Vector3.INF:
		return Vector3.INF
	var u := Vector3(f.x - p.feet().x, 0.0, f.z - p.feet().z)
	if u.length() < 1.0:
		u = -p.eye.global_basis.z if p.eye != null else Vector3.FORWARD
		u.y = 0.0
	u = u.normalized()
	var side := Vector3(-u.z, 0.0, u.x)
	var first := 1.0 if slot % 2 == 0 else -1.0
	for k in [first, -first]:
		for out in [SIDE, SIDE * 1.5, SIDE * 0.6]:
			var want: Vector3 = p.feet() + side * k * out + u * AHEAD
			var at := services.ai_nav.snap(want) if services.ai_nav != null else want
			if services.ai_nav != null and not services.ai_nav.can_stand(at):
				continue
			if not in_lane(at):
				return at
	return Vector3.INF


## Where squad number `slot` should go in at the fight from: the focus's own
## flank, on the support point's side -- across the players' lanes never.
func flank_of(f: Vector3, slot := 0) -> Vector3:
	var s := support_point(f, slot)
	if s == Vector3.INF:
		return Vector3.INF
	# Square to the line from the players to the focus, on the support point's
	# side: across the lane would be in front of their guns.
	var p := nearest_player(f)
	var u := Vector3(f.x - p.feet().x, 0.0, f.z - p.feet().z)
	if u.length() < 1.0:
		return s
	u = u.normalized()
	var side := Vector3(-u.z, 0.0, u.x)
	var k := signf((s - p.feet()).dot(side))
	var want := f + side * k * SIDE * 0.8
	var at := services.ai_nav.snap(want) if services.ai_nav != null else want
	return s if in_lane(at) else at
