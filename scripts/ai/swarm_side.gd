class_name SwarmSide
extends Node
## The swarm (Docs/AI.md 5.2, 10.2; AIPlan P8): hundreds of agents as ROWS of
## SwarmCore -- a C++ state machine on its own flow field, drawn as a MultiMesh --
## and the seam between them and the node agents.
##
##   GOAL        the nearest player on the other side, once a tick
##   OBSTACLES   the chunks' boxes, from AIWorld's bricks: the field goes round
##               buildings, and again whenever the bricks change (refresh())
##   ROUNDS      a player-side round that passes through the swarm hits the first
##               row on its line -- no further than what the bullet physically
##               struck, so a wall still stops it (AIServices.round_listeners)
##   PROMOTION   a row that gets within PROMOTE_RANGE of a player becomes a node
##               agent -- `spawn_promoted(position, health)`, born DIRECTED -- and
##               leaves the swarm without a death: no corpse, no effects. At most
##               PROMOTE_PER_TICK a tick, and never past `node_cap`.
##   DEMOTION    the ImportanceBudget hands a swarm-born agent back (demote()) when
##               it has fallen out of the budget far from every player: it is a row
##               again, with the health it had.
##
## Rows do not bite: by the time one is close enough to, it has been promoted.

const PROMOTE_RANGE := 16.0
const PROMOTE_EVERY := 0.25
const PROMOTE_PER_TICK := 2
## The first row on a round's line within this of it is the one it hits.
const ROUND_CONE := 0.035

var core: SwarmCore
var services: AIServices
var team := 1
## (position: Vector3, health: float) -> Object: the node agent a row becomes.
var spawn_promoted := Callable()
## () -> Array: the chunks whose boxes the field goes round.
var chunks := Callable()
## () -> Array[AABB]: or the boxes themselves (a city's buildings, bricks or
## shell alike). Used when set.
var boxes := Callable()
## () -> int: how many more node agents the budget will take now.
var node_room := Callable()
## For gates.
var promoted := 0
var demoted := 0
var rows_hit := 0
var _next_promote := -INF


func setup(s: AIServices, parent: Node, p_team: int, positions: PackedVector3Array, hp: float,
		seed := 1) -> void:
	services = s
	team = p_team
	name = "Swarm"
	core = SwarmCore.new()
	core.name = "SwarmCore"
	core.set_seed(seed)
	core.configure(maxi(positions.size() + 64, 128), 2.0, 120)
	# Its numbers are ours: it spawns what we tell it, when we tell it.
	core.set_director_enabled(false)
	add_child(core)
	parent.add_child(self)
	core.spawn_batch(positions, hp)
	s.round_listeners.append(_on_round)


## The obstacles again, from the bricks: every chunk's box. Cheap to call after
## a collapse or a load; the field is rebuilt by the core on its own schedule.
func refresh() -> void:
	core.clear_obstacles()
	if boxes.is_valid():
		for box in boxes.call():
			if (box as AABB).size.y >= 0.6:
				core.add_obstacle((box as AABB).get_center(), (box as AABB).size)
		return
	if not chunks.is_valid():
		return
	var w := services.ai_world.get_world()
	var cs := BrickWorld.get_cell_size()
	for c in chunks.call():
		if not w.is_chunk_alive(int(c)):
			continue
		var dims := Vector3(w.get_chunk_dims(int(c))) * cs
		var xf := w.get_chunk_transform(int(c))
		var box := xf * AABB(Vector3.ZERO, dims)
		if box.size.y < 0.6:
			continue   # a slab or a kerb: walked over
		core.add_obstacle(box.get_center(), box.size)


func alive() -> int:
	return core.get_alive_count()


func tick_ms() -> float:
	return core.get_last_tick_ms()


func _physics_process(_delta: float) -> void:
	var goal := _nearest_player()
	if goal != null:
		core.set_goal_position(goal.feet())
	var now := services.now()
	if now >= _next_promote:
		_next_promote = now + PROMOTE_EVERY
		_promote()


func _nearest_player() -> Pawn:
	var best: Pawn = null
	var best_d := INF
	var c := core.global_position
	for p in services.hostiles_of(team):
		var d := p.feet().distance_squared_to(c)
		if best == null or d < best_d:
			best = p
			best_d = d
	return best


func _promote() -> void:
	if not spawn_promoted.is_valid():
		return
	var n := 0
	for p in services.hostiles_of(team):
		while n < PROMOTE_PER_TICK:
			if node_room.is_valid() and int(node_room.call()) <= 0:
				return
			var h := core.query_cone_handle(p.feet() + Vector3.UP * 0.8, Vector3.FORWARD, PI,
					PROMOTE_RANGE)
			if h < 0 or not core.is_handle_live(h):
				break
			var st: Dictionary = core.get_agent_state(h)
			if st.is_empty() or not core.release_agent(h):
				break
			spawn_promoted.call(st.position as Vector3, float(st.health))
			promoted += 1
			n += 1


## Back to a row: `agent` (swarm-born, out of the budget) is freed and its place
## taken by a row with its health. True if it went.
func demote(agent: Object) -> bool:
	if not is_instance_valid(agent):
		return false
	var pos: Vector3 = agent.budget_pos()
	var hp := 0.0
	if agent.get("pawn") != null and agent.pawn.health != null:
		hp = agent.pawn.health.total_current()
	if hp <= 0.0:
		return false
	core.spawn_batch(PackedVector3Array([pos]), hp)
	agent.call(&"retire")
	demoted += 1
	return true


## A round from the other side: the first row on its line, no further than what
## it struck.
func _on_round(shooter: Pawn, from: Vector3, to: Vector3, _info: Dictionary) -> void:
	if shooter == null or shooter.team == team or shooter.gun == null:
		return
	var dir := (to - from)
	var reach := dir.length()
	if reach < 0.1:
		return
	dir /= reach
	var q: Dictionary = core.query_cone(from, dir, ROUND_CONE, reach)
	if q.is_empty():
		return
	var dmg := float(shooter.gun._stat(&"damage", 10.0))
	var r: Dictionary = core.apply_hitscan(from, dir, dmg)
	if not r.is_empty():
		rows_hit += 1
