class_name CollapseDirector
extends RefCounted

## How a building comes apart, decided per solve -- the collapse plan's steps 2
## and 3 (Docs/Status.md, "Collapse plan").
##
## A building's solve hands back the groups that no longer reach the ground, and
## every one of them used to become a body of its own: a bullet knocking three
## bricks out and a 22,000-brick tower giving way went through the same door.
## Two things are told apart here.
##
## * BREAKAGE -- a group next to where something just hit this building, and not
##   big. Local, close up, watched: it comes loose exactly as it did.
## * COLLAPSE -- everything else: the structure giving way. On an ordinary
##   building that is still one body per group. On a MEGA building (MEGA_BLOCKS)
##   the groups of one solve are clustered, bottom to top, into a few big chunks
##   -- small groups ride inside them rather than becoming debris of their own --
##   and their furniture is taken out to be written off (it goes through the
##   furniture rule on its own: IslandManager.FURNITURE_FALL_RANGE). How big a
##   chunk is depends on how far the nearest player is: a collapse across the
##   city comes down in a handful of pieces, one next to you in more.
##
## The host's decision, like every structural one: each chunk is one DETACH, so
## a client cuts exactly the same pieces (StructureReplayer). Presentation (the
## dust, which pieces a machine keeps of its own debris) is each machine's.

## A building with at least this many bricks collapses through the director.
const MEGA_BLOCKS := 8000
## A group this close to a hit on its building, this recently, is breakage...
const BREAKAGE_RANGE := 4.0
const BREAKAGE_MS := 2000
## ...if it is no bigger than this. A floor coming away next to the shot that
## undercut it is the building giving way, not a chip.
const BREAKAGE_MAX_BLOCKS := 200
## Bricks a chunk aims for, by the nearest player's distance to the building.
const NEAR_RANGE := 60.0
const FAR_RANGE := 150.0
const CHUNK_NEAR := 1500
const CHUNK_MID := 4000
## Beyond FAR_RANGE a round's groups become at most this many chunks.
const CHUNKS_FAR := 3
## A mega building's collapse is HELD -- what has given way stays where it is,
## part of the building -- while the cascade is still growing, and let go once it
## has stopped growing for STALL_ROUNDS solves, or after HOLD_MS whatever it is
## doing. A cascade fails a few joints a tick, and releasing each tick's worth
## made one small chunk a tick for as long as it ran: 331 of them in one pass.
## Held, it comes down in a few big ones, and the moment before it does is the
## groan Red Faction put there on purpose.
##
## Where somebody is close enough to be watching (NEAR_RANGE), though, only
## while there is less than a chunk's worth (_chunk_target) -- a chunk is what
## holding is waiting for, and one that is there already goes at once -- and
## for HOLD_NEAR_MS at most: held a second and a half, a break next to the
## player read as the game hanging, the bricks shot out and nothing falling.
## Far off nobody sees the wait, and letting part of a growing cascade go early
## only makes more pieces of it (collapse_probe's far check: 9 against 4).
const HOLD_MS := 1500
const HOLD_NEAR_MS := 500
const STALL_ROUNDS := 2

var world: BrickWorld
## building id -> [[world point, ms], ...], the recent hits.
var _hits := {}
## What the director did, for the report.
var rounds := 0
var groups_in := 0
var chunks_out := 0
var far_collapses := 0            ## rounds a far building came down coarse
var breakage_out := 0
var furniture_out := 0
## building id -> true, for the buildings a mega collapse has begun in (dust).
var collapsing := {}
## building id -> when its current hold began, how many bricks it held last
## round, and for how many rounds that has not grown.
var _held_since := {}
var _held_bricks := {}
var _stalled := {}
var held_rounds := 0


func _init(p_world: BrickWorld) -> void:
	world = p_world


## Something hit building `id` at `point`.
func note_hit(id: int, point: Vector3) -> void:
	var now := Time.get_ticks_msec()
	var list: Array = _hits.get(id, [])
	var kept: Array = []
	for h in list:
		if now - int(h[1]) < BREAKAGE_MS:
			kept.append(h)
	kept.append([point, now])
	_hits[id] = kept


## Is every player further than FAR_RANGE from this building? Then it comes
## down coarse, whatever its size (plan).
static func is_far(box: AABB, points: PackedVector3Array) -> bool:
	if points.is_empty():
		return false
	for p in points:
		if _distance_to_box(box, p) < FAR_RANGE:
			return false
	return true


static func is_mega(blocks: int) -> bool:
	return blocks >= MEGA_BLOCKS


## The groups of one solve, as the pieces they should leave as. `blocks` is the
## building's size, `box` its world box, `points` where the players are.
## Returns [ids, kind] pairs, kind one of &"breakage", &"group", &"chunk",
## &"furniture" -- in a fixed order, since the host records each as it spawns.
func plan(id: int, chunk: int, blocks: int, box: AABB, groups: Array,
		points: PackedVector3Array) -> Array:
	var out: Array = []
	var collapse: Array = []
	for g in groups:
		var ids: PackedInt32Array = g
		if ids.size() <= BREAKAGE_MAX_BLOCKS and _near_recent_hit(id, chunk, ids):
			out.append([ids, &"breakage"])
			breakage_out += 1
		else:
			collapse.append(ids)
	if collapse.is_empty():
		return out
	# Mega buildings, and ANY building collapsing where nobody is near
	# (FAR_RANGE): a few big chunks, furniture written off, no debris of its
	# own (Docs/Collapse.md 3). Nobody watches a collapse across the city
	# closely enough to miss the small pieces, and every one of them was a
	# body stepped, meshed and slept.
	if not is_mega(blocks) and not is_far(box, points):
		# The biggest first: what has given way is let go a few groups a tick
		# (CityScene.SPAWN_BUDGET_MS), and the one that has to go at once is the
		# building's body -- left for last, it hung in the air while the
		# small stuff went (--breaklag). Ties by first block, so the order is
		# the same on every run: the host records each one as it goes.
		collapse.sort_custom(func(a: PackedInt32Array, c: PackedInt32Array) -> bool:
				if a.size() != c.size():
					return a.size() > c.size()
				return a[0] < c[0])
		var groups_first: Array = []
		for ids in collapse:
			groups_first.append([ids, &"group"])
		groups_first.append_array(out)
		return groups_first
	if not is_mega(blocks):
		far_collapses += 1

	# Held until there is a chunk's worth, or until it has hung long enough.
	var bricks := 0
	for ids in collapse:
		bricks += ids.size()
	var now := Time.get_ticks_msec()
	if not _held_since.has(id):
		_held_since[id] = now
		_held_bricks[id] = 0
		_stalled[id] = 0
	if bricks > int(_held_bricks[id]):
		_stalled[id] = 0
	else:
		_stalled[id] = int(_stalled[id]) + 1
	_held_bricks[id] = bricks
	var watched := _nearest(box, points) < NEAR_RANGE
	var ready := watched and bricks >= _chunk_target(box, points, bricks)
	var hold_ms := HOLD_NEAR_MS if watched else HOLD_MS
	if not ready and int(_stalled[id]) < STALL_ROUNDS and now - int(_held_since[id]) < hold_ms:
		held_rounds += 1
		return out
	_held_since.erase(id)
	_held_bricks.erase(id)
	_stalled.erase(id)

	rounds += 1
	groups_in += collapse.size()
	collapsing[id] = true
	# The furniture in them is written off: out of the chunks, into a group of
	# its own that the furniture rule deletes unless somebody is right there.
	var decorative := {}
	for d in world.get_decorative_blocks(chunk):
		decorative[d] = true
	var total := 0
	var ordered: Array = []
	var furniture := PackedInt32Array()
	for ids in collapse:
		var structure := PackedInt32Array()
		for b in ids:
			if decorative.has(b):
				furniture.append(b)
			else:
				structure.append(b)
		if structure.is_empty():
			continue
		total += structure.size()
		ordered.append([_height_of(chunk, structure), structure[0], structure])
	# Bottom to top, and the first block id to break ties: the same order every
	# time, because the host records the chunks in it.
	ordered.sort_custom(func(a: Array, c: Array) -> bool:
			if int(a[0]) != int(c[0]):
				return int(a[0]) < int(c[0])
			return int(a[1]) < int(c[1]))
	var target := _chunk_target(box, points, total)
	var current := PackedInt32Array()
	for entry in ordered:
		var structure: PackedInt32Array = entry[2]
		current.append_array(structure)
		if current.size() >= target:
			out.append([current, &"chunk"])
			chunks_out += 1
			current = PackedInt32Array()
	if not current.is_empty():
		# The last, short chunk joins the one below it rather than being a
		# small piece on its own -- unless it is the only one.
		var last := -1
		for k in range(out.size() - 1, -1, -1):
			if out[k][1] == &"chunk":
				last = k
				break
		if last >= 0 and current.size() < (target >> 1):
			var joined: PackedInt32Array = out[last][0]
			joined.append_array(current)
			out[last][0] = joined
		else:
			out.append([current, &"chunk"])
			chunks_out += 1
	# split_island and the DETACH both want the ids in order. (A packed array in
	# an Array is a copy when read out: sort it and put it back.)
	for entry in out:
		var sorted_ids: PackedInt32Array = entry[0]
		sorted_ids.sort()
		entry[0] = sorted_ids
	# The furniture first: it is deleted where it is unless somebody is right
	# next to it, which costs next to nothing, and left for a later tick it would
	# hang in the air where its floor was.
	if not furniture.is_empty():
		furniture.sort()
		out.push_front([furniture, &"furniture"])
		furniture_out += furniture.size()
	return out


## How far the nearest player is from this box. INF with nobody.
func _nearest(box: AABB, points: PackedVector3Array) -> float:
	var d := INF
	for p in points:
		d = minf(d, _distance_to_box(box, p))
	return d


## Bricks per chunk for a building this far from everybody.
func _chunk_target(box: AABB, points: PackedVector3Array, total: int) -> int:
	var d := _nearest(box, points)
	if points.is_empty() or d < NEAR_RANGE:
		return CHUNK_NEAR
	if d < FAR_RANGE:
		return CHUNK_MID
	@warning_ignore("integer_division")
	return maxi(total / CHUNKS_FAR + 1, CHUNK_MID)


## Roughly how high a group sits: the lowest of a few of its blocks, in ticks.
func _height_of(chunk: int, ids: PackedInt32Array) -> int:
	var lo := 1 << 30
	var step := maxi(ids.size() >> 3, 1)
	for k in range(0, ids.size(), step):
		var ticks: Array = world.get_block_ticks(chunk, ids[k])
		if not ticks.is_empty():
			lo = mini(lo, (ticks[0] as Vector3i).y)
	return lo


## Is any of a few of this group's blocks within BREAKAGE_RANGE of a recent hit?
func _near_recent_hit(id: int, chunk: int, ids: PackedInt32Array) -> bool:
	var list: Array = _hits.get(id, [])
	if list.is_empty():
		return false
	var now := Time.get_ticks_msec()
	var xf := world.get_chunk_transform(chunk)
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var step := maxi(int(ids.size() / 6.0), 1)
	for k in range(0, ids.size(), step):
		var ticks: Array = world.get_block_ticks(chunk, ids[k])
		if ticks.is_empty():
			continue
		var at: Vector3 = xf * ((Vector3(ticks[0] as Vector3i)
				+ Vector3(ticks[1] as Vector3i) * 0.5) * tick_m)
		for h in list:
			if now - int(h[1]) < BREAKAGE_MS and (h[0] as Vector3).distance_to(at) < BREAKAGE_RANGE:
				return true
	return false


static func _distance_to_box(box: AABB, p: Vector3) -> float:
	var q := Vector3(clampf(p.x, box.position.x, box.end.x),
			clampf(p.y, box.position.y, box.end.y),
			clampf(p.z, box.position.z, box.end.z))
	return q.distance_to(p)
