class_name MobZombie
extends Mob
## The zombie (Docs/MineCreatures.md 3): 2 studs across, 4 bricks tall. Active
## all the time (no day rule yet). It walks to the player on MineMobs' shared
## flow field -- one Dijkstra out from the player for every zombie -- and, where
## the field does not reach it (too far, or no way in), on a path of its own
## that ends as near as it can get: shut out by a wall, it waits at the wall.
##
## It cannot break bricks, steps up one brick and no more (a wall two bricks
## high stops it), and fits nowhere narrower than 2 studs or lower than 12
## plates. It hits the player at arm's length: a shove, and in survival
## DAMAGE of health (MineMobs.hurt_player). A fall of 3 bricks onto a crop
## tramples it. Saved with the world when near the player (section 11).

const BODY := Vector4i(2, 12, 3, 19)
const HIT_RANGE := 1.3
const HIT_EVERY := 1.0
## Walking speed x this while it chases (Pawn.WALK_SPEED 2.8 m/s -> 3.5).
const CHASE_MULT := 1.25
const HP := 40.0
const DAMAGE := 5.0

## A wired alarm's call (Docs/MineWiring.md 19): where it walks, and until
## when. It goes back to the player when it gets there, sees the player within
## CALL_SEES m, or the call runs out.
const CALL_SECONDS := 30.0
const CALL_SEES := 8.0
const CALL_THERE := 2.0
var called_to := Vector3.INF
var called_until := 0.0
var calls := 0

var hits := 0
var on_field := false
var _next_hit := 0.0
var _player := Vector3.INF


func _init() -> void:
	kind = &"zombie"
	body = BODY
	trample_bricks = 3.0


func think(now: float) -> void:
	_player = mobs.player_feet()
	if _player == Vector3.INF:
		state = "idle"
		stop()
		return
	var f := last_feet
	pawn.move_mult = CHASE_MULT
	if called_to != Vector3.INF:
		if now > called_until or f.distance_to(called_to) < CALL_THERE or f.distance_to(_player) < CALL_SEES:
			called_to = Vector3.INF
		else:
			state = "called"
			on_field = false
			face_point = Vector3.INF
			walk_to(called_to, now)
			return
	face_point = _player if f.distance_to(_player) < 6.0 else Vector3.INF
	on_field = mobs.field_next(f) != Vector3.INF
	if on_field:
		state = "chase"
		stop()
	else:
		state = "chase (own path)" if path_reached or path_answers == 0 else "at the nearest point"
		walk_to(_player, now)
	var d := Vector3(_player.x - f.x, 0.0, _player.z - f.z)
	# Only what it can walk to: never through a fence or a wall it stands at.
	var can_reach: bool = (mobs.field_cost(f) < 2.5) if on_field else (path_reached and answered)
	if can_reach and d.length() <= HIT_RANGE and absf(_player.y - f.y) < 1.0 and now >= _next_hit:
		_next_hit = now + HIT_EVERY
		hits += 1
		mobs.hurt_player(self, DAMAGE, d.normalized() if d.length() > 0.01 else Vector3.FORWARD)


## An alarm calls it to `at` (terrain frame) for CALL_SECONDS.
func call_to(at: Vector3, now: float) -> void:
	called_to = at
	called_until = now + CALL_SECONDS
	calls += 1
	asleep = false


func steer_point() -> Vector3:
	if not on_field or _player == Vector3.INF:
		return Vector3.INF
	var f := last_feet
	if Vector2(_player.x - f.x, _player.z - f.z).length() < 1.0:
		return Vector3.INF    # close enough: it stands and hits
	var p1: Vector3 = mobs.field_next(f)
	if p1 == Vector3.INF:
		return Vector3.INF
	if p1.distance_to(f) < 0.05:
		return _player        # on the goal's node: straight at the player
	# One node further on where it is level: a smoother line than node to node.
	var p2: Vector3 = mobs.field_next(p1)
	if p2 != Vector3.INF and absf(p2.y - f.y) < 0.3 and absf(p1.y - f.y) < 0.3:
		return p2
	return p1
