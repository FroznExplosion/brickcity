## body_separator.gd — stops a crowd of bodies standing inside each other.
##
## A HARD positional de-overlap, not a steering force, and that distinction is the whole
## module. Steering separation is a suggestion added to a velocity: it competes with whatever
## else is steering the body — seek, a lane's lookahead, a charge — and against a strong enough
## seek it simply loses, which is what a pile of props clipping through each other IS. SwarmCore
## hit exactly this and fixed it the same way (`_resolve_overlap`, ~800 deep-overlap pairs down
## to under 20 in three passes); this is that rule for the node side, where the bodies are tens
## rather than thousands and a plain O(n²) scan is cheaper than a spatial hash.
##
## Steering separation is still worth keeping ON TOP of this — it makes a queue spread out
## before it jams rather than after — so [LaneAgent.separation_strength] is not replaced by
## this, it is backed up by it.
##
## Generic on purpose: it knows about positions and radii, nothing else. Bodies come from a
## Callable and radii are duck-typed, so it separates possessed props, plain capsules, or
## whatever the next project puts in a room.
class_name BodySeparator
extends Node

## Passes per frame. Each pass halves the remaining overlap of every pair; three is where
## SwarmCore's measurements flattened out, and pairs are cheap here.
@export var passes: int = 3
## How much of each overlap to resolve per pass. Deliberately under 1.0: resolving every pair
## fully in one go overshoots when a body has several neighbours — each pair pushes it out of
## one overlap and into the next — and the crowd rings instead of settling.
@export_range(0.05, 1.0, 0.05) var relax: float = 0.55
## Cap on how far one body may be moved in a single pass. A deep overlap — two ghosts spawned
## on the same point, or one dropped onto another by the beam — would otherwise fire them apart
## like a physics glitch instead of easing them out.
@export var max_push: float = 0.35
## Extra breathing room added to every pair, so bodies settle just clear of each other rather
## than exactly touching.
@export var padding: float = 0.05

## `func() -> Array` of the movable bodies. Required.
var bodies: Callable
## `func() -> Array` of bodies that push but never move: barricades, towers, scenery. Optional.
var obstacles: Callable
## `func(body: Node3D) -> float` overriding the radius lookup. Optional — by default a body is
## asked for its own `body_radius()`, which is how a fridge and a can get different footprints
## without this module knowing what either of them is.
var radius_of: Callable

## Pairs pushed apart on the last resolve. Handy on a HUD when a crowd looks wrong.
var last_resolved: int = 0


func _process(_delta: float) -> void:
	resolve()


## One frame of separation. Public so a test can step it without frames, like everything else
## in this project that has a tick.
func resolve() -> int:
	last_resolved = 0
	if not bodies.is_valid():
		return 0
	var list: Array[Node3D] = []
	var radii: PackedFloat32Array = PackedFloat32Array()
	var pinned: Array[bool] = []
	for b in bodies.call():
		if b is Node3D and is_instance_valid(b):
			list.append(b)
			radii.push_back(_radius(b))
			pinned.append(_is_pinned(b))
	var fixed_from := list.size()
	if obstacles.is_valid():
		for o in obstacles.call():
			if o is Node3D and is_instance_valid(o):
				list.append(o)
				radii.push_back(_radius(o))
				pinned.append(true)
	if list.size() < 2:
		return 0

	for _p in passes:
		# j > i, so every pair is visited exactly once per pass. Visiting both orders would
		# apply each correction twice and double the effective relax.
		for i in list.size():
			for j in range(i + 1, list.size()):
				if i >= fixed_from and j >= fixed_from:
					continue         # two immovables cannot overlap each other's way out
				_resolve_pair(list[i], list[j], radii[i] + radii[j] + padding,
					pinned[i], pinned[j])
	return last_resolved


## Push one pair apart along the floor plane. Y is never touched: how high a ghost floats is
## its own animation's business, and lifting one over another would read as a ghost climbing
## furniture rather than standing beside it.
func _resolve_pair(a: Node3D, b: Node3D, want: float, a_pinned: bool, b_pinned: bool) -> void:
	if a_pinned and b_pinned:
		return
	var d := b.global_position - a.global_position
	d.y = 0.0
	var gap := d.length()
	if gap >= want:
		return
	var dir: Vector3
	if gap > 0.0001:
		dir = d / gap
	else:
		# Exactly co-located: there is no "apart" to compute, so pick a stable direction from
		# the pair's own identity. Rolling a random one every frame makes two stacked bodies
		# jitter in place forever instead of separating.
		var angle := float(a.get_instance_id() % 359) * 0.0175
		dir = Vector3(cos(angle), 0.0, sin(angle))
	var overlap: float = minf((want - gap) * relax, max_push)
	last_resolved += 1
	# When one side cannot move, the other takes the whole correction — otherwise a ghost
	# walking into a tower ends up half inside it, each frame pushing a wall that never moves.
	if a_pinned:
		b.global_position += dir * overlap
	elif b_pinned:
		a.global_position -= dir * overlap
	else:
		a.global_position -= dir * (overlap * 0.5)
		b.global_position += dir * (overlap * 0.5)


func _radius(b: Node3D) -> float:
	if radius_of.is_valid():
		return maxf(float(radius_of.call(b)), 0.05)
	if b.has_method("body_radius"):
		return maxf(float(b.body_radius()), 0.05)
	return 0.45


## A body something else is DRAGGING does not get shoved.
##
## The player's beam and the traps position a ghost every frame; a separation pass fighting that
## shows up as the haul stuttering whenever anything drifts near it, and the player reads it as
## the beam losing grip. The crowd moves around what is being hauled instead.
##
## `is_hauled`, not `is_held`: a ghost that is merely driving ITSELF (a melee ghost holding its
## own body so the lane agent stands down while it swings) is the crowd this exists to separate
## — pinning those would leave a mob attacking one barricade standing inside each other, which
## is the exact case that looked worst.
func _is_pinned(b: Node3D) -> bool:
	if b.has_method("is_hauled"):
		return bool(b.is_hauled())
	if b.has_method("is_held"):
		return bool(b.is_held())
	return false
