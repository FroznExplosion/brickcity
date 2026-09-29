class_name WeightTracker
extends RefCounted
## Weight for everything that stands on bricks (Docs/AI.md 3.10, A16; AIPlan P7):
## players, soldiers and mechs, on the host.
##
## The solver already carries every brick's own weight, and since P5 the wreckage
## resting on a building. What stands on it is the rest -- and almost always it
## does not matter: a floor on its columns is in compression, and compression
## never fails (D11). So weight costs ONE LOOKUP. Every solve leaves each block's
## HEADROOM (BrickWorld.get_headroom): how much more could rest on it before a
## tension joint on its way down lets go. A bearer's foot block is looked up when
## it changes, and:
##
##   headroom INF (a way down that is all compression)  nothing: no command, no solve
##   finite, the bearer lighter                         a LOAD is logged -- it takes
##                                                      part in every later solve, so
##                                                      a client must have it (R5) --
##                                                      and nothing is solved
##   finite, the bearer heavier                         the LOAD, and a solve: the
##                                                      section that was hanging by a
##                                                      thread drops
##   unknown (never solved)                             a solve, then the lookup again
##
## Stepping off is an UNLOAD, if there was a LOAD. The commands are the owner's to
## commit (the city's authority, a probe's log); this decides which, and when.

## Masses, in the palette's units (print-scale grams; a 2x4 brick is 2.4). A
## person is well under a brick's weight: it matters only to a section already
## hanging by a thread. A mech is many.
const PERSON := 1.0
const MECH := 45.0
## Looked up this often per bearer. A body crosses a stud in ~0.1 s at a run.
const HZ := 15.0

class Bearer:
	var body: Node3D
	## () -> Vector3: where its feet are.
	var feet: Callable
	var mass := 0.0
	## Its owner id in LOAD / UNLOAD commands: negative, never a piece's id.
	var owner := -1
	var chunk := -1
	var block := -1
	## A LOAD for it is on `chunk` now.
	var logged := false


var ai_world: AIWorld
var world: BrickWorld
## (chunk: int, owner: int, cell: Vector3i, mass: float) -> void. Commit a LOAD.
var on_load := Callable()
## (chunk: int, owner: int) -> void. Commit an UNLOAD.
var on_unload := Callable()
## (chunk: int) -> void. Solve that chunk (queued, inside the destruction budget).
var on_solve := Callable()
var bearers := {}   # owner -> Bearer
## For gates and the overlay.
var loads := 0
var unloads := 0
var solves := 0
var lookups := 0
var _next_owner := -1
var _next_tick := -INF
var _asked := {}    # chunk -> true: a solve asked for because its headroom was unknown


func _init(p_ai_world: AIWorld, p_world: BrickWorld) -> void:
	ai_world = p_ai_world
	world = p_world


## Something that weighs `mass` and stands where `feet` says. Returns its owner id.
func add(body: Node3D, feet: Callable, mass: float) -> int:
	var b := Bearer.new()
	b.body = body
	b.feet = feet
	b.mass = mass
	b.owner = _next_owner
	_next_owner -= 1
	bearers[b.owner] = b
	return b.owner


func remove(owner: int) -> void:
	var b: Bearer = bearers.get(owner)
	if b == null:
		return
	_step_off(b)
	bearers.erase(owner)


func bearer(owner: int) -> Bearer:
	return bearers.get(owner)


## The block under a point just below `feet`, or (-1, -1).
func block_under(feet: Vector3) -> Vector2i:
	for dy in [0.05, 0.2]:
		var v := ai_world.block_at(feet - Vector3.UP * dy)
		if v.x >= 0:
			return v
	return Vector2i(-1, -1)


func tick(now: float) -> void:
	if now < _next_tick:
		return
	_next_tick = now + 1.0 / HZ
	for owner in bearers.keys():
		var b: Bearer = bearers[owner]
		if not is_instance_valid(b.body) or not b.body.is_inside_tree():
			remove(owner)
			continue
		var feet: Vector3 = b.feet.call()
		var v := block_under(feet)
		lookups += 1
		if v.x == b.chunk and v.y == b.block:
			continue
		_step_off(b)
		b.chunk = v.x
		b.block = v.y
		if v.x >= 0:
			_step_on(b, feet)


func _step_on(b: Bearer, feet: Vector3) -> void:
	var h := world.get_headroom(b.chunk, b.block)
	if h >= 0.0:
		_asked.erase(b.chunk)
	if h < 0.0:
		# Never solved since this block existed: find out, then look again.
		if not _asked.has(b.chunk):
			_asked[b.chunk] = true
			solves += 1
			on_solve.call(b.chunk)
		b.chunk = -1
		b.block = -1
		return
	if is_inf(h):
		return
	loads += 1
	b.logged = true
	on_load.call(b.chunk, b.owner, _cell(b.chunk, feet), b.mass)
	if b.mass > h:
		solves += 1
		on_solve.call(b.chunk)


func _step_off(b: Bearer) -> void:
	if b.logged and b.chunk >= 0 and world.is_chunk_alive(b.chunk):
		unloads += 1
		on_unload.call(b.chunk, b.owner)
	b.logged = false


## The absolute cell of `chunk` under `feet`: what a LOAD names.
func _cell(chunk: int, feet: Vector3) -> Vector3i:
	var cs := BrickWorld.get_cell_size()
	for dy in [0.05, 0.2]:
		var local: Vector3 = world.get_chunk_transform(chunk).affine_inverse() * (feet - Vector3.UP * dy)
		var at := world.get_chunk_origin(chunk) + Vector3i(floori(local.x / cs.x),
				floori(local.y / cs.y), floori(local.z / cs.z))
		if world.block_at(chunk, at) >= 0:
			return at
	return world.get_chunk_origin(chunk)
