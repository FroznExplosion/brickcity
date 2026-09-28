class_name Crush
extends RefCounted

## Falling masonry hurts, and nobody is left inside it (Docs/Collapse.md 4.4).
##
## Falling pieces do not collide with pawns -- FALLING_MASK leaves PAWN out, on
## purpose: a rigid piece meeting an immovable character body stops dead on
## it -- so until now a building came down THROUGH a soldier, harmlessly, and
## left it standing inside the rubble. This is the missing half:
##
##   * CRUSH: a piece moving faster than MIN_SPEED whose solid is where a pawn
##     is -- its feet, chest or head -- hurts it by speed times the square root
##     of its bricks; a piece of KILL_BRICKS or more, moving, kills. Once per
##     pawn and piece every COOLDOWN_MS, so a slab resting on somebody is one
##     hit, not sixty a second.
##   * PUSH OUT: a pawn whose body is inside a piece's solid, moving or not, is
##     shoved out of it, away from the piece's middle (Pawn.shove), until it is
##     clear. Nobody ends a collapse embedded in a wall.
##
## Cheap: a box test per piece and pawn, and point queries only for the few
## pawns inside a piece's box.

const MIN_SPEED := 2.5            ## m/s
const MIN_BRICKS := 6
const DAMAGE := 1.1               ## hp per (m/s x sqrt(bricks))
const KILL_BRICKS := 100
const KILL_SPEED := 4.0
const COOLDOWN_MS := 400
const PUSH := 4.0                 ## m/s out of the piece
const PUSH_UP := 1.5

const RIDE_SPEED := 0.8           ## m/s: slower than this a piece carries nobody
const RIDE_SPIN := 0.3            ## rad/s
const THROW_DELTA := 2.0          ## m/s lost in a tick: the piece hit something

## For the probe and the HUD.
var rides := 0
var throws := 0
var _riding := {}                 ## "pawn:chunk" -> the velocity it was carried at
var hits := 0
var kills := 0
var pushes := 0

var _last := {}                   ## "pawn instance id:chunk" -> msec of the last hit


func tick(islands: IslandManager, pawns: Array[Pawn]) -> void:
	if pawns.is_empty():
		return
	var now := Time.get_ticks_msec()
	for isl in islands.islands:
		if not isl.is_valid() or not is_instance_valid(isl.body) or not isl.body.is_inside_tree():
			continue
		var box := islands.world_aabb(isl).grow(0.4)
		for p in pawns:
			if p.health == null or p.health.is_dead():
				continue
			var feet := p.feet()
			# In its box, or standing on top of it.
			if not box.has_point(feet + Vector3.UP * 0.9) and not box.has_point(feet + Vector3.UP * 0.05):
				continue
			if not _inside(isl, [feet + Vector3.UP * 0.3, p.chest(), feet + Vector3.UP * 1.55]):
				# Not in its solid, but on it or against it while it moves: carried.
				_ride(isl, p)
				continue
			var speed := isl.body.linear_velocity.length()
			if speed >= MIN_SPEED:
				_crush(isl, p, speed, now, islands)
			# Out of it, whichever way is away from its middle.
			var away := feet - box.get_center()
			away.y = 0.0
			if away.length() < 0.01:
				away = Vector3.FORWARD
			p.shove = away.normalized() * PUSH + Vector3.UP * PUSH_UP
			pushes += 1


## A pawn touching a moving piece goes with it, and is thrown when it stops.
##
## Standing on its FLOOR, the character body already goes with it (Godot
## carries a body on a moving floor); against its wall, or in a room tipping
## over with no floor under its feet, nothing does, so the pawn takes the
## piece's velocity where it stands as a shove (Pawn.shove). Either way, when
## the piece's velocity there drops by THROW_DELTA in a tick -- it has hit
## something -- the pawn keeps what it had: thrown, and the fall does the rest
## (Pawn.SAFE_FALL). Rigid bodies do not push character bodies; this does.
func _ride(isl: BrickIsland, p: Pawn) -> void:
	var body := isl.body
	var key := "%d:%d" % [p.get_instance_id(), isl.chunk]
	var at := p.chest() - body.global_position
	var v := body.linear_velocity + body.angular_velocity.cross(at)
	var touching := false
	var on_floor := false
	for i in p.body.get_slide_collision_count():
		var c := p.body.get_slide_collision(i)
		if c.get_collider() == body:
			touching = true
			if c.get_normal().y > 0.7:
				on_floor = true
	var was: Vector3 = _riding.get(key, Vector3.ZERO)
	# Thrown: it was riding, and the piece stopped under it.
	if was.length() - v.length() > THROW_DELTA:
		p.shove = was
		throws += 1
		_riding.erase(key)
		return
	if not touching or (v.length() < RIDE_SPEED and body.angular_velocity.length() < RIDE_SPIN):
		_riding.erase(key)
		return
	_riding[key] = v
	rides += 1
	if not on_floor and v.length() > p.shove.length():
		p.shove = v


## Is any of `points` in this piece's solid?
func _inside(isl: BrickIsland, points: Array) -> bool:
	var space := isl.body.get_world_3d().direct_space_state
	var q := PhysicsPointQueryParameters3D.new()
	q.collision_mask = isl.body.collision_layer
	for pt in points:
		q.position = pt
		for hit in space.intersect_point(q, 8):
			if hit.collider == isl.body:
				return true
	return false


func _crush(isl: BrickIsland, p: Pawn, speed: float, now: int, islands: IslandManager) -> void:
	var key := "%d:%d" % [p.get_instance_id(), isl.chunk]
	if now - int(_last.get(key, -COOLDOWN_MS)) < COOLDOWN_MS:
		return
	_last[key] = now
	var bricks := islands.world.get_alive_block_count(isl.chunk)
	if bricks < MIN_BRICKS:
		return
	var amount := speed * sqrt(float(bricks)) * DAMAGE
	if bricks >= KILL_BRICKS and speed >= KILL_SPEED:
		amount = 1e9
	var packet := DamagePacket.new(amount, null, null)
	packet.hit_position = p.chest()
	var res := DamageSystem.resolve(packet, p.health)
	if res.dealt > 0.0:
		hits += 1
	if res.killed:
		kills += 1
