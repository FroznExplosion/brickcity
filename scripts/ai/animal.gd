class_name Animal
extends Node
## An animal (Docs/AI.md 5.2; AIPlan P8): a procedural creature (ProcCreature, its
## gait animated from how it moves) on a Pawn's body, in an AnimalPack. The pack
## decides; the animal goes to its place in it -- on an AINav path, or, closing
## on prey, on the side's shared flow field -- and bites what it hunts.
##
## A row of the swarm promoted near a player becomes one of these, hunting, in a
## pack of its own (SwarmSide.spawn_promoted): the swarm's bodies up close.
##
## Tiered like a soldier (AgentTier): SMART thinks at THINK_HZ, DIRECTED at a
## third of it; a swarm-born one can go back to a row (retire()).

const THINK_HZ := 6.0
const DIRECTED_THINK_HZ := 2.0
const BITE_RANGE := 1.4
const BITE_DAMAGE := 8.0
const BITE_EVERY := 0.8
const ARRIVED := 1.2

var services: AIServices
var pawn: Pawn
var pack: AnimalPack
var team := 2
var tier: int = AgentTier.SMART
var tier_hsm: AgentTier
var swarm_born := false
var visual: ProcCreature
var index := 0
var state := "graze"
## For gates.
var bites := 0

var _next_think := -INF
var _queued := false
var _goal := Vector3.INF
var _path_id := -1
var _path := PackedVector3Array()
var _wp := 0
var _field_goal := Vector3.INF
var _next_bite := 0.0


## An animal at `feet` in `pack`. `creature_seed` < 0: no creature mesh (a
## greybox capsule), for the many a probe runs headless.
static func spawn(s: AIServices, parent: Node, feet: Vector3, p_pack: AnimalPack, hp := 60.0,
		creature_seed := -1, start_tier := AgentTier.SMART) -> Animal:
	var p := Pawn.spawn(parent, feet, p_pack.team, true, hp)
	p.no_crouch = true
	var a := Animal.new()
	a.name = "Animal"
	a.services = s
	a.pawn = p
	a.pack = p_pack
	a.team = p_pack.team
	a.index = p_pack.members.size()
	a.process_physics_priority = -5
	p.body.add_child(a)
	p_pack.members.append(a)
	if creature_seed >= 0:
		var dna := CreatureDNA.random(creature_seed)
		a.visual = ProcCreature.spawn(dna)
		p.body.add_child(a.visual)
		a.visual.position = Vector3.DOWN * Pawn.BODY_HEIGHT * 0.5
	else:
		Soldier._greybox(p, p_pack.team)
	s.pawns.append(p)
	a.tier_hsm = AgentTier.attach(a, start_tier)
	return a


func set_tier(t: int) -> void:
	tier = t


func is_dead() -> bool:
	return pawn == null or not is_instance_valid(pawn) or pawn.health.is_dead()


func budget_pos() -> Vector3:
	return pawn.feet()


func budget_bonus(_now: float) -> float:
	if pack.mode == AnimalPack.Mode.HUNT and pack.prey != null and is_instance_valid(pack.prey) \
			and pack.prey.feet().distance_to(pawn.feet()) < 30.0:
		return 20.0
	return 0.0


## Leave the world without dying: back to a swarm row (SwarmSide.demote).
func retire() -> void:
	pack.members.erase(self)
	services.pawns.erase(pawn)
	pawn.body.queue_free()


func _physics_process(_delta: float) -> void:
	if is_dead():
		return
	var now := services.now()
	if now >= _next_think and not _queued:
		_queued = true
		services.sched.submit(AIScheduler.TREES, 4.0, _think)
	if _field_goal != Vector3.INF:
		var d := services.field_dir(_field_goal, pawn.feet())
		d.y = 0.0
		pawn.intents.move = d.normalized() if d.length() > 0.01 else Vector3.ZERO
	elif _goal != Vector3.INF:
		_follow()
	# The bite: a hunter next to its prey.
	if pack.mode == AnimalPack.Mode.HUNT and pack.prey != null and is_instance_valid(pack.prey) \
			and now >= _next_bite and pawn.feet().distance_to(pack.prey.feet()) <= BITE_RANGE:
		_next_bite = now + BITE_EVERY
		pack.prey.health.apply_impact(BITE_DAMAGE, &"")
		bites += 1
	if visual != null:
		var v := pawn.body.velocity
		if Vector2(v.x, v.z).length() > 0.2:
			visual.rotation.y = atan2(-v.x, -v.z)


func _think() -> void:
	_queued = false
	var now := services.now()
	var hz := THINK_HZ if tier == AgentTier.SMART else DIRECTED_THINK_HZ
	_next_think = now + 1.0 / (hz * services.sched.rate_scale(AIScheduler.TREES))
	if pack.members.front() == self or not is_instance_valid(pack.members.front()) \
			or (pack.members.front() as Animal).is_dead():
		pack.think()
	var a := pack.alive()
	var i := maxi(a.find(self), 0)
	match pack.mode:
		AnimalPack.Mode.GRAZE:
			state = "graze"
			_field_goal = Vector3.INF
			pawn.intents.run = false
			_walk_to(pack.slot(i, a.size()))
		AnimalPack.Mode.FLEE:
			state = "flee"
			_field_goal = Vector3.INF
			var away := pawn.feet() - pack.threat
			away.y = 0.0
			away = away.normalized() if away.length() > 0.1 else Vector3.BACK
			pawn.intents.run = true
			_walk_to(pawn.feet() + away * 12.0)
		AnimalPack.Mode.HUNT:
			pawn.intents.run = true
			if pack.closing:
				state = "close in"
				_goal = Vector3.INF
				_field_goal = pack.prey.feet()
			else:
				state = "encircle"
				_field_goal = Vector3.INF
				_walk_to(pack.slot(i, a.size()))


func _walk_to(goal: Vector3) -> void:
	if _goal != Vector3.INF and goal.distance_to(_goal) < 1.5:
		return
	_goal = goal
	if _path_id >= 0:
		services.ai_nav.release(_path_id)
	_path_id = services.ai_nav.request_path(pawn.feet(), goal, 3.0, 4000)
	_path = PackedVector3Array()
	_wp = 0


func _follow() -> void:
	if _path.is_empty():
		var st := services.ai_nav.get_status(_path_id)
		if st == AINav.PENDING:
			pawn.intents.move = Vector3.ZERO
			return
		if st != AINav.DONE:
			# No way there: straight at it, and let the body find out.
			var d := _goal - pawn.feet()
			d.y = 0.0
			pawn.intents.move = d.normalized() if d.length() > ARRIVED else Vector3.ZERO
			return
		_path = services.ai_nav.get_path(_path_id)
		_wp = 1 if _path.size() > 1 else 0
	var feet := pawn.feet()
	while _wp < _path.size() and Vector2(_path[_wp].x - feet.x, _path[_wp].z - feet.z).length() < 0.4:
		_wp += 1
	if _wp >= _path.size():
		pawn.intents.move = Vector3.ZERO
		return
	var dir := _path[_wp] - feet
	dir.y = 0.0
	pawn.intents.move = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO
