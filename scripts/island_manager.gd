class_name IslandManager
extends Node3D

## Owns every detached piece in the world: spawning, settling, waking, impact
## shear, and the debris budget.
##
## Split out of the sandbox so the city scene and the single-tower scene share
## one implementation rather than two that drift.
##
## The debris budget is the part that matters at city scale. A ring cut on one
## test tower produced 36 single-brick islands, each of them a chunk, a body and
## a mesh. Twenty buildings collapsing would produce thousands, so:
##
##   * a small piece nobody can see is never spawned at all -- its bricks are
##     simply gone, because no one is there to notice the difference;
##   * a single brick that IS visible becomes a real body but is drawn from a
##     shared MultiMesh, one draw call per brick size rather than per brick;
##   * anything under DEBRIS_MIN_BLOCKS is cleaned up after a few seconds.
##
## Big pieces are never touched by any of this. A section that stays intact is
## the thing the whole model exists to produce.

const MASS_SCALE := 10.0
const SETTLE_MIN_MS := 900
const WAKE_RADIUS := 6.0

## Impact shear. A landing releases joints; it destroys nothing.
const IMPACT_MIN_SPEED := 4.0
const IMPACT_DELTA := 2.5
const IMPACT_RADIUS := 0.8
const IMPACT_RADIUS_MAX := 2.6
const MAX_IMPACTS := 4
## How many contact points the solver is asked to keep per island. Four is
## enough to tell a corner strike from a flat landing and cheap enough to leave
## on permanently.
const MAX_CONTACTS := 6

## A long piece that lands hard does not shed a handful of bricks -- it SNAPS.
##
## A beam struck across its middle is in bending, and the tension runs across
## the whole cross-section at the point of impact, so it comes apart in two long
## pieces. A tower falling flat on the ground touches down along its length and
## breaks into a few. Docs/BrickFailure.md: stiff sections, breaking at the
## point of contact, is what a real brick tower does.
const BREAK_MIN_DROP := 5.0        ## m/s lost in one tick before a piece snaps
const BREAK_MIN_LENGTH := 5.0      ## metres; shorter pieces just shed bricks
const BREAK_MIN_PIECE := 1.2       ## never sever this close to either end
const BREAK_SPACING := 2.0         ## metres between two breaks in one landing
const BREAK_PLANES_MAX := 6
## Contacts that get a shear sweep. The rest may still become break planes.
## Blocks one shear sweep may loosen. A sphere measured in metres
## over-selects flat thin geometry -- measured, one 2.6 m sweep on a
## 24-course tower loosened 86 blocks and 74% of them were floor plates,
## because a plate is a third of a brick's height and spans the whole
## footprint. An impact carries finite energy; it does not shear an
## unbounded area, and the flooring coming away in sheets was this.
const SHEAR_MAX_BLOCKS := 14
const SHEAR_CONTACTS_MAX := 3
## Contacts handed to whatever was landed on. Landing is one event.
const IMPACT_HANDOVERS_MAX := 2
const BREAK_THICKNESS := 0.42      ## one brick course

## Debris budget.
const DEBRIS_MIN_BLOCKS := 10      ## under this, a piece is disposable
## How close a piece that is nothing but furniture has to be to be allowed to
## fall rather than be deleted where it came loose. Arm's length and a bit: a
## chair tipping off a floor in front of you is worth a body; anywhere else it
## is a floating cube for a second and small debris after that.
const FURNITURE_FALL_RANGE := 6.0
const DEBRIS_LIFETIME_MS := 2500   ## how long disposable debris lingers
## A piece has to be at least this big to shear anything it lands on. Two bricks
## of ABS weigh a few grams; at brick scale nothing that small arrives with
## enough energy to break a joint, and letting it try produced damage that
## looked arbitrary.
const MIN_IMPACT_BLOCKS := 3
## How many island meshes may be BUILT per tick. The first build of an island's
## mesh bakes its faces, which is the single most expensive thing a collapse
## does; every later one is an index patch and is free. Presentation can lag a
## few frames, so it does.
## Wreckage that has come to rest and is further away than this gives its baked
## faces back. A building has a ladder of cheaper representations to fall back
## on; an island had none, and kept full brick geometry forever however far away
## it was. The bake is 98% of what a chunk costs, so this is the whole saving.
const ISLAND_MESH_RANGE := 120.0
const ISLAND_MESH_HYSTERESIS := 25.0
## Dropping and rebuilding are both cheap, but not free, so only a few change
## tier per tick.
const ISLAND_LOD_PER_TICK := 2
## Landings processed per tick. A landing shears joints and re-solves the
## piece, and when a whole city comes down at once hundreds arrive together
## -- 98 ms of a 108 ms tick. The rest wait their turn; the queue keeps the
## severity, so nothing is lost, only delayed.
## One shared budget across every expensive thing this manager does in a tick:
## landings, re-solves and first mesh builds.
##
## It is a budget in MILLISECONDS, not in operations, and that distinction is
## the whole point. Counting operations bounds the number of things done and
## not the time they take -- and these operations are not interchangeable. A
## re-solve that sheds three 2,000-brick halves off a toppled tower costs fifty
## times what a re-solve on a chair leg does, so "two per tick" was 298 ms on
## one tick and 0.3 ms on the next. A clock does not care which kind it got.
## Pieces this small get their mesh built on the spot instead of queued.
##
## A piece that has left its building but has no mesh yet is invisible, and the
## bricks are already gone from the parent -- so there is a hole in the world
## for however long the queue takes. Baking a handful of bricks is microseconds;
## it is only a whole toppled building that has to go to a worker.
## 24, not 96. The point is to stop a piece popping in a frame late, and the
## pieces that read as popping are the small ones -- a chunk of wall large enough
## to notice is also large enough that a frame's delay is invisible against its
## own motion. Baking 96 blocks on the main thread, many times in one tick,
## measured 268 ms of spawn time against 155 for the queued path.
## Bake a new piece on this thread rather than queueing it, up to this size.
##
## Raised from 24 after measuring the gap it leaves: a piece above the threshold
## is created with an empty MeshInstance3D and draws NOTHING until its bake comes
## back, while the parent has already stopped drawing those bricks. Counted over
## a 200-building collapse that was 1,304 ticks with at least one invisible
## piece, 30 at once at worst.
##
## 24 only ever covered gravel. The pieces that actually show the gap are the
## small-to-middling ones a wall sheds -- exactly the range between 24 and here.
const SYNC_MESH_MAX_BLOCKS := 200
## However cheap one bake is, not an unbounded number of them per tick.
const SYNC_MESH_PER_TICK := 6

const WORK_BUDGET_MS := 4.0
## The mesh queue gets its OWN budget rather than sharing the one above.
##
## Sharing it meant a tick spent on resolving and fracturing left nothing for
## meshing, so a piece waiting to become visible queued behind work that only
## matters once it IS visible. Drawing a piece that already exists is the more
## urgent job of the two.
const MESH_BUDGET_MS := 3.0
## Always do at least one, however long it takes: a budget that can starve
## forever is a deadlock, and a single unit is bounded by the piece's size.
const WORK_MIN := 1
## Pieces cut off one island in a single pass. A collapse produced 4139
## splits, and cutting them all the moment the solver noticed them was the
## last unbudgeted path in the tick. What is left over is re-solved next
## tick, so the piece still comes apart -- just not all at once.
## One piece cut off per pass. Three was chosen when a shed was cheap; a
## transverse break makes components by the dozen, and cutting three 2,000-brick
## halves out inside one indivisible work unit is 300 ms that no clock can
## interrupt. The rest are re-queued and come away over the next few ticks.
const SHEDS_PER_PASS := 1
const VISIBLE_RANGE := 140.0       ## beyond this, nobody is watching closely
## A thin, wide piece -- a floor slab especially -- can spawn overlapping what
## it just left and get a huge separation impulse out of the solver, which
## launches it into the sky. Nothing in a collapse legitimately moves this fast,
## so it is clamped rather than explained.
## Debris falls harder than the world does.
##
## Brick models are light and stiff, and at 1g a toppling tower drifts down
## looking like it is underwater. This is a feel number, not a physics one: it
## buys the weight the shapes cannot, and the harder landing is what breaks the
## piece up when it arrives.
const DEBRIS_GRAVITY := 1.6
const MAX_DEBRIS_SPEED := 30.0
const MAX_DEBRIS_SPIN := 14.0

var world: BrickWorld
var brick_material: ShaderMaterial
var camera: Camera3D

var islands: Array[BrickIsland] = []
var settled := 0
var impacts := 0
var impact_blocks := 0
var splits := 0
var discarded := 0                 ## small pieces never spawned, because unseen
var furniture_deleted := 0         ## furniture-only pieces deleted where they came loose

## Called when an island lands hard: (island, world_point, severity). The scene
## uses it to damage whatever was underneath -- an island has no idea what it
## hit, and should not.
var on_impact: Callable = Callable()

var _mesh_queue: Array[BrickIsland] = []
## Meshes the renderer may still be holding. See MeshRetirer.
var _retirer := MeshRetirer.new()
var _lod_cursor := 0
var _fracture_queue: Array = []   ## [island, severity] awaiting their turn
## Breaks that could not find a seam and had to tear a band into loose brick.
## Should stay near zero; a rising count means pieces are being cut across an
## axis their joints do not run along.
var band_breaks := 0
## Overlap instead of hand-off.
##
## Every newborn piece takes bricks something else was drawing a moment ago,
## and every hand-off here used to happen in ONE frame: the source stopped
## drawing them and the newborn started. The newborn is a render instance
## entering the scenario that very frame, and that is what every flashing case
## had in common -- a split child, a building's first piece, a toppling building
## re-parented into a new body -- while every case that never flashed lacked it:
## a building promoted to bricks (its instance existed frames before its mesh)
## and a single brick in the shared MultiMesh (never an instance of its own).
##
## No instrument ever saw the missed frame -- the interpolated transform of
## every newborn matched its body, and a framebuffer test forces the GPU sync
## that hides it -- so this does not depend on knowing why. It keeps the old
## drawing up for OVERLAP_FRAMES, so no frame exists in which nothing draws those
## bricks. The same bricks are drawn twice in almost the same place meanwhile,
## which cannot be seen. Confirmed by eye, in slow motion, as the fix.
##
## TWO frames, and a `static var` rather than a `const` so that `J` in the city
## can turn it off in a running scene. That is not a debug nicety: this is a fix
## no instrument can see, so the only evidence it works is the flash coming back
## when it is switched off, and that has to stay available.
## chunk id -> the MultiMeshInstance3D drawing that chunk's interiors.
##
## Interiors are not in the face bake (FurnitureMesh), so a piece that breaks
## off a furnished building draws its own furniture from here.
var _furniture := {}
static var OVERLAP_FRAMES := 2
var _ghosts: Array = []   ## [node, free on this process frame]
var _held: Array = []     ## islands whose mesh update waits for a child to come up
## Most overlaps alive at once -- the cost of the fix, measured rather than
## assumed. Each one is a piece's geometry drawn twice for two frames.
var overlap_peak := 0
## Pieces that exist, own a MeshInstance3D, and have nothing in it.
##
## This is the disappearing piece, counted rather than looked for: `spawn`
## creates the node before the bake exists, so between the split and the bake
## landing the piece draws NOTHING while the parent has already stopped drawing
## those bricks. A large toppling section never shows it because `adopt` carries
## its mesh across instead of re-baking.
var meshless_worst_blocks := 0
## How LONG an individual piece stays invisible, which is what is actually seen.
## "Some piece is invisible this tick" is true almost continuously during a
## collapse and says nothing. This is what found the cancelled-bake bug.
var blind_worst := 0
var blind_total := 0
var blind_count := 0
## --- the dormant tier -------------------------------------------------------
##
## Wreckage that has come to rest, far from anybody, given back: the chunk, the
## occupancy grid, the bake, the mesh and the body all go, and what is left is a
## `ChunkRecord` of about nine bytes a block. Plan.md §4.2's ladder, for the one
## layer that never had it -- a building is a recipe until it is hit, a creation
## is a recipe and a shell, and a lump of rubble was rubble forever.
##
## It is not deletion. The record round-trips: the same blocks in the same
## order, so a piece a player walks back to is the piece they left, and it can
## still be shot, broken and moved. What it costs is a rebuild when they do.
## THE DEBRIS CAP. Docs/Scale.md section 4.8.
##
## A collapse makes two kinds of thing and they are worth different amounts. A
## LARGE piece is a landmark: it changes how the place is navigated and it is
## what the player remembers doing. A SMALL piece is texture: hundreds of them
## are what fill the solver and nobody misses one.
##
## So two caps with one eviction order -- oldest at rest first, within a class
## -- and the classes differ in what eviction MEANS:
##
##     small, over its cap  ->  DELETED
##     large, over its cap  ->  SLEPT, into the dormant record that already
##                              exists, at 17 bytes a block, able to come back
##
## That second row is why the cap is not a new mechanism. Dormancy already
## reduces a large piece to a record; until now it only ever fired on DISTANCE,
## so a hundred large pieces at the player's feet stayed live however long they
## sat there. The cap is what drives it on a schedule as well.
##
## `total` sits over both: when it is exceeded the small class is spent first,
## down to `small_floor`, and only then does the large class begin to sleep.
static var SMALL_BLOCKS := 24
var small_live_max := 220
var large_live_max := 60
var total_live_max := 240
var small_floor := 24
## How many pieces may be evicted in one tick. Deleting is cheap; sleeping
## captures a record, so it is budgeted like every other per-tick cost here.
const EVICTIONS_PER_TICK := 3
var cap_deleted := 0
var cap_slept := 0
var cap_worst_over := 0


class Dormant:
	var record: ChunkRecord
	var slept_ms := 0


## Far enough that a piece is not part of the scene any more, and close enough
## that walking back brings it out again. The gap is hysteresis: a piece on the
## line must not sleep and wake every tick.
const SLEEP_RANGE := 150.0
const WAKE_RANGE := 120.0
## How long a piece has to have been settled first. Long enough that a collapse
## finishes before anything in it is put away.
const SLEEP_AFTER_MS := 6000
## One each per pass, like every other streaming decision in this project: a
## sleep is a capture and a release, a wake is a chunk, a bake and a mesh.
const SLEEPS_PER_TICK := 1
const WAKES_PER_TICK := 1

var dormant: Array[Dormant] = []
var slept := 0
var woken := 0
## Where the sleep scan got to. Walking every island every tick to ask how far
## away it is would be the same O(islands) mistake the settle loop already
## learned not to make.
var _sleep_cursor := 0

var _resolve_queue: Array[BrickIsland] = []  ## more to shed than one pass allowed
var _work_until := 0
## Where tick() actually spends its time, summed over the session.
var tick_prof := {"loop": 0.0, "resolve": 0.0, "fracture": 0.0, "mesh": 0.0, "mm": 0.0}
var tick_worst := {}
var _work_done := 0
var _sync_meshes := 0
var dropped := 0     ## islands that have given their mesh back
var breaks := 0      ## times a landing snapped a piece across its width
var merged_shapes := 0  ## pieces whose collision has been merged down
var merged_boxes := 0   ## boxes those pieces ended up with
var unmerged_boxes := 0 ## boxes they had to go back to when hit
var peak_drop := 0.0 ## biggest single-tick speed loss seen, m/s
var long_landings := 0  ## landings on a piece long enough to snap
var soft_landings := 0  ## landings too gentle to snap anything
var short_landings := 0 ## landings on a piece too short to snap
var longest_landed := 0.0  ## longest piece that has landed, metres
## Microseconds spent in each part of spawn(), summed over the session.
var spawn_prof := {"split": 0.0, "shapes": 0.0, "mesh": 0.0, "node": 0.0, "total": 0.0}
var _multimesh := {}               ## box size -> MultiMeshInstance3D for single bricks
var _mm_members := {}              ## box size -> Array[BrickIsland]


func setup(brick_world: BrickWorld, material: ShaderMaterial, view: Camera3D) -> void:
	world = brick_world
	brick_material = material
	camera = view


# ---------------------------------------------------------------------------
# Visibility — the whole debris budget hangs off this one question
# ---------------------------------------------------------------------------

## Cheap and deliberately generous: in front of the camera and close enough to
## make out. Getting this wrong in the permissive direction costs a few bodies;
## getting it wrong the other way deletes something a player was looking at.
## Which island a physics body belongs to. A shot at settled wreckage has to
## find it by what the ray actually hit -- measuring distance from the body's
## ORIGIN misses a toppled building entirely, because its origin is its centre
## of mass and the ray hit one end of it.
func find_by_body(body: Node) -> BrickIsland:
	for isl in islands:
		if isl.is_valid() and isl.body == body:
			return isl
	return null


func can_be_seen(point: Vector3) -> bool:
	if camera == null or not is_instance_valid(camera):
		return true
	if camera.global_position.distance_to(point) > VISIBLE_RANGE:
		return false
	return camera.is_position_in_frustum(point)


# ---------------------------------------------------------------------------
# Spawning
# ---------------------------------------------------------------------------

## Lift a group out of `source` and give it a chunk, a body and a way to be
## drawn. Returns null when the piece was small, unseen and therefore discarded.
func spawn(source: int, block_ids: PackedInt32Array,
		inherit_linear := Vector3.ZERO, inherit_angular := Vector3.ZERO) -> BrickIsland:
	var _t0 := Time.get_ticks_usec()
	var split: Dictionary = world.split_island(source, block_ids)
	spawn_prof.split += float(Time.get_ticks_usec() - _t0) / 1000.0
	var _t := Time.get_ticks_usec()
	if split.is_empty():
		return null

	var count := int(split.block_count)
	var island_chunk := int(split.chunk)
	var at: Vector3 = split.com

	# A small piece nobody can see never becomes anything. The bricks are
	# already out of the source chunk, so this is a deletion, not a leak.
	if count < DEBRIS_MIN_BLOCKS and not can_be_seen(at):
		world.release_chunk(island_chunk)
		discarded += count
		return null
	# Nor does a piece that is ONLY furniture, unless it is at arm's length.
	# A chair whose floor went is not a chair the collapse needs: as a body it
	# was a lone untextured cube in mid-air, or a brick that fell a beat after
	# everything around it, and at the far end of a fall it was deleted as
	# small debris anyway. Deleting it here, where it leaves, is the same
	# outcome without the part everybody could see.
	if world.get_decorative_blocks(island_chunk).size() == count \
			and (camera == null or camera.global_position.distance_to(at) > FURNITURE_FALL_RANGE):
		world.release_chunk(island_chunk)
		furniture_deleted += count
		return null

	var isl := BrickIsland.new()
	isl.chunk = island_chunk
	isl.local_com = split.local_com
	isl.disposable = count < DEBRIS_MIN_BLOCKS

	isl.body = RigidBody3D.new()
	isl.body.mass = maxf(float(split.mass) * MASS_SCALE, 0.5)
	_apply_layers(isl)
	# Real contact points, so a landing knows WHERE it hit and WHAT it hit
	# rather than inferring both from a bounding box.
	isl.body.contact_monitor = true
	isl.body.max_contacts_reported = MAX_CONTACTS
	isl.body.gravity_scale = DEBRIS_GRAVITY

	# Shapes are built inside the extension: one call instead of one per block
	# across the script/engine boundary, which was a third of what cutting an
	# island out of a building cost.
	# Per block, NOT merged. Merging a piece at birth was tried and reverted:
	# a falling piece is hit almost at once (its own landing), `_ensure_per_block`
	# has to rebuild the shapes there and then, and the scene ends up paying for
	# two shape builds instead of one -- 35,000 boxes rebuilt against 839 saved.
	# It also wrecked the settled phase, 16.7 ms to 69.5. Merging is worth it
	# once a piece has stopped, and only then.
	var built: Dictionary = world.add_chunk_shapes(
			isl.body.get_rid(), isl.chunk, isl.local_com, true)
	isl.shape_map = built.map
	isl.shape_count = int(built.count)
	spawn_prof.shapes += float(Time.get_ticks_usec() - _t) / 1000.0
	_t = Time.get_ticks_usec()

	# One brick is drawn from a shared MultiMesh; anything bigger gets its own
	# mesh, because its shape is its own.
	if count == 1 and isl.shape_count == 1:
		# One block, so this array has one entry and costs nothing.
		var one: Array = world.get_block_boxes(isl.chunk)
		isl.mm_key = (one[0] as Dictionary).size
		_join_multimesh(isl, block_ids)
	else:
		isl.mesh = MeshInstance3D.new()
		isl.mesh.material_override = brick_material
		# Interpolation is for things that MOVE. This instance sits at a fixed
		# offset under its body -- the body is what gets interpolated -- and its
		# geometry is rewritten in place by index patches, which is exactly what
		# interpolation's double buffering cannot survive.
		isl.mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		isl.mesh.position = -isl.local_com
		isl.body.add_child(isl.mesh)
		# What was standing in the rooms this piece took with it. Under the
		# MESH, which is the node holding the chunk's own space -- so the
		# furniture rides the collapse without anything here tracking it, which
		# is Interiors section 4.2 and the reason interiors are blocks in the
		# host's grid in the first place.
		FurnitureMesh.attach(world, isl.chunk, isl.mesh, _furniture)

	var island_xform: Transform3D = world.get_chunk_transform(isl.chunk)
	isl.body.transform = island_xform * Transform3D(Basis(), isl.local_com)

	add_child(isl.body)
	# A body that appears at a position has not MOVED there. Without this,
	# physics interpolation blends it in from wherever the previous frame
	# left off -- and for a mesh reparented into a brand-new body, from a
	# surface the renderer has not finished setting up.
	isl.body.reset_physics_interpolation()
	if isl.mesh != null:
		isl.mesh.reset_physics_interpolation()
	spawn_prof.node += float(Time.get_ticks_usec() - _t) / 1000.0
	_t = Time.get_ticks_usec()
	isl.body.set_meta("spawn_pos", isl.body.position)
	isl.body.linear_velocity = inherit_linear
	isl.body.angular_velocity = inherit_angular
	isl.born_ms = Time.get_ticks_msec()
	isl.prev_speed = inherit_linear.length()
	# Single bricks never reach rebuild_mesh, so the bound is set here too.
	isl.radius = _body_radius(isl)
	islands.append(isl)
	# No wake_near here. It is O(every island) and spawn is called once per
	# piece shed -- 4,400 times in a heavy collapse, which made it O(n^2).
	# _shed already wakes the region around the parent, which is the same
	# region every child of that parent occupies.
	if isl.mesh != null:
		if count <= SYNC_MESH_MAX_BLOCKS and _sync_meshes < SYNC_MESH_PER_TICK:
			# Small enough to bake here and now, so it is never invisible.
			_sync_meshes += 1
			rebuild_mesh(isl, true, true)
		else:
			# A big section goes to a worker; it is queued and appears a tick or
			# two later, which is far cheaper than baking it on this thread.
			world.bake_chunk_async(isl.chunk)
			_mesh_queue.append(isl)
	spawn_prof.mesh += float(Time.get_ticks_usec() - _t) / 1000.0
	spawn_prof.total += float(Time.get_ticks_usec() - _t0) / 1000.0
	return isl


## Swap a piece's collision between one box per brick and as few boxes as the
## shape allows.
##
## Merged is for pieces that have stopped moving: a settled island is inert
## scenery, and one box per brick across hundreds of them is what a collapse
## makes the physics solver pay for. The merged boxes ignore block identity, so
## nothing can be disabled on its own -- which is fine until the piece is hit,
## at which point this runs the other way first.
func _reshape(isl: BrickIsland, merged: bool) -> void:
	if not isl.is_valid() or isl.merged == merged:
		return
	var rid := isl.body.get_rid()
	# Out of the space first: shape calls on a body IN a space cost time
	# proportional to its shape count.
	var space := PhysicsServer3D.body_get_space(rid)
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, RID())
	PhysicsServer3D.body_clear_shapes(rid)
	var built: Dictionary = world.add_chunk_shapes(
			rid, isl.chunk, isl.local_com, true, merged)
	isl.shape_map = built.map
	isl.shape_count = int(built.count)
	isl.merged = merged
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, space)
		# See BrickIsland.disable_blocks: rejoining a space resets the body's
		# interpolation history, and swapping shapes is the other half of the
		# damage path that does it.
		isl.body.reset_physics_interpolation()
		if isl.mesh != null:
			isl.mesh.reset_physics_interpolation()
	if merged:
		merged_shapes += 1
		merged_boxes += isl.shape_count
	else:
		unmerged_boxes += isl.shape_count


## About to damage this piece, so it needs shapes it can disable one at a time.
func _ensure_per_block(isl: BrickIsland) -> void:
	if isl.merged:
		_reshape(isl, false)


## What this piece collides with, given how big it is and what it is doing.
##
## Three states, and the distinction is what makes a collapse affordable:
##
##   * **rubble** -- under DEBRIS_MIN_BLOCKS. Lands on the ground, on buildings
##     and on settled wreckage; passes through anything still falling, and
##     through other rubble. A handful of loose bricks deflecting a falling
##     tower is neither believable nor cheap, and rubble-against-rubble is the
##     quadratic term in the pair count.
##   * **falling** -- a large section in motion. Everything except rubble.
##   * **settled** -- come to rest. Everything, rubble included, because now it
##     is scenery that things land on.
## Treat a piece as debris rather than as structure: rubble layers, and swept up
## on the debris timer like anything else too small to matter.
##
## What a FIXTURE becomes the moment it comes loose. A staircase is not
## structure (Docs/BuildMode.md section 9.2), and once it is falling it should
## not cost what a falling section of building costs -- measured, that
## difference was 103 islands against 27 in the same collapse.
func make_debris(isl: BrickIsland) -> void:
	if isl == null or not isl.is_valid():
		return
	isl.disposable = true
	_apply_layers(isl)


func _apply_layers(isl: BrickIsland) -> void:
	if not isl.is_valid():
		return
	if isl.disposable:
		isl.body.collision_layer = Layers.RUBBLE
		isl.body.collision_mask = Layers.RUBBLE_MASK
	elif isl.settled:
		isl.body.collision_layer = Layers.DEBRIS
		isl.body.collision_mask = Layers.SETTLED_MASK
	else:
		isl.body.collision_layer = Layers.FALLING
		isl.body.collision_mask = Layers.FALLING_MASK


## Take a chunk over whole, without copying a block of it.
##
## The general path (`spawn`) cuts a group out of a source chunk into a new one.
## When a building topples the group is the ENTIRE building, so that copy builds
## a duplicate of something about to be thrown away -- a second occupancy grid,
## 2,800 `place_block` calls and a second face bake. Here the chunk, its bake and
## its mesh node move across as they are, and the only new thing is the body.
func adopt(chunk: int, mesh_node: MeshInstance3D, carried_mesh: ArrayMesh,
		carried_bytes: int, carried_width: int, carried_bands: Array = []) -> BrickIsland:
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return null
	world.set_chunk_anchored(chunk, false)

	var isl := BrickIsland.new()
	isl.chunk = chunk
	isl.local_com = world.get_chunk_com(chunk)
	isl.disposable = false

	isl.bands = carried_bands
	isl.body = RigidBody3D.new()
	isl.body.mass = maxf(world.get_chunk_mass(chunk) * MASS_SCALE, 0.5)
	isl.body.contact_monitor = true
	isl.body.max_contacts_reported = MAX_CONTACTS
	isl.body.gravity_scale = DEBRIS_GRAVITY
	_apply_layers(isl)

	# Shapes before the body joins a space, as always.
	var built: Dictionary = world.add_chunk_shapes(
			isl.body.get_rid(), chunk, isl.local_com, true)
	isl.shape_map = built.map
	isl.shape_count = int(built.count)

	# The building's mesh becomes the island's mesh. It already holds the right
	# geometry, so there is nothing to bake and nothing to upload.
	isl.mesh = mesh_node
	isl.array_mesh = carried_mesh
	isl.index_bytes = carried_bytes
	isl.index_width = carried_width
	if mesh_node != null:
		# Leave the building's node exactly where it is, still drawing, and give
		# the island a NEW instance of the SAME mesh -- nothing is copied; an
		# ArrayMesh can back any number of instances. Moving the node took it out
		# of the scenario and put it back in one frame. See OVERLAP_FRAMES.
		var fresh := MeshInstance3D.new()
		fresh.mesh = mesh_node.mesh
		fresh.material_override = mesh_node.material_override
		isl.mesh = fresh
		isl.body.add_child(fresh)
		fresh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		fresh.transform = Transform3D(Basis(), -isl.local_com)
		if mesh_node.get_parent() != null:
			_ghosts.append([mesh_node, Engine.get_process_frames() + OVERLAP_FRAMES])
		else:
			mesh_node.queue_free()

	isl.body.transform = world.get_chunk_transform(chunk) \
			* Transform3D(Basis(), isl.local_com)
	add_child(isl.body)
	# A body that appears at a position has not MOVED there. Without this,
	# physics interpolation blends it in from wherever the previous frame
	# left off -- and for a mesh reparented into a brand-new body, from a
	# surface the renderer has not finished setting up.
	isl.body.reset_physics_interpolation()
	if isl.mesh != null:
		isl.mesh.reset_physics_interpolation()
	isl.body.set_meta("spawn_pos", isl.body.position)
	isl.born_ms = Time.get_ticks_msec()
	isl.radius = _body_radius(isl)
	islands.append(isl)
	wake_near(isl.body.global_position, WAKE_RADIUS)
	return isl


func _join_multimesh(isl: BrickIsland, block_ids: PackedInt32Array) -> void:
	var key: Vector3 = isl.mm_key
	if not _multimesh.has(key):
		var mmi := MultiMeshInstance3D.new()
		# Rewritten every frame from scratch; interpolating it is both pointless
		# and a source of buffer errors.
		mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		# A chamfered brick, not a cube. This mesh is shared by every single
		# brick of this size in the debris field, so the bevel costs 44
		# triangles once -- and a loose brick tumbling past the camera is the
		# one case where the shaded bevel in brick.gdshader cannot help,
		# because it is all silhouette.
		mm.mesh = PieceMeshes.chamfered_box(key)
		mmi.multimesh = mm
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.85
		mmi.material_override = mat
		add_child(mmi)
		_multimesh[key] = mmi
		_mm_members[key] = []
	isl.mm_colour = BrickWorld.get_filament_colour(
			world.get_block_colour(isl.chunk, block_ids[0] if not block_ids.is_empty() else 0))
	(_mm_members[key] as Array).append(isl)


## Godot draws a surface non-indexed when its index array is empty, and then
## complains that the vertex count is not a multiple of three -- which is the
## exact shape of the renderer errors this scene was producing. Anything that
## would build such a surface is reported here instead of being uploaded.
##
## Every test is O(1) on purpose: this runs on every remesh, and a remesh can
## carry half a million indices.
static func mesh_arrays_ok(arrays: Array, who: String) -> bool:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.is_empty():
		return false
	if idx.is_empty() or idx.size() % 3 != 0:
		push_error("[brick] %s: %d verts but %d indices -- surface skipped" % [
				who, verts.size(), idx.size()])
		return false
	var n := verts.size()
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	if normals.size() != n or colours.size() != n or uvs.size() != n or uv2s.size() != n:
		push_error("[brick] %s: %d verts, %d normals, %d colours, %d uv, %d uv2" % [
				who, n, normals.size(), colours.size(), uvs.size(), uv2s.size()])
		return false
	return true


## Godot stores indices as **uint16 whenever a surface has 65536 vertices or
## fewer** and uint32 above that. A patch written at the wrong width lands as
## garbage, or past the end of the buffer:
##
##     ERROR: Attempted to write buffer (1440 bytes) past the end.
##
## This used to be handled by refusing to patch small surfaces at all. That was
## fine while only tiny debris was small -- and then greedy face merging cut
## vertex counts by five times, put most BUILDINGS under the threshold, and
## turned every hit into a full mesh rebuild. So the width is passed through to
## the extension instead.
const INDEX16_MAX_VERTS := 65536

static func index_width(arrays: Array) -> int:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return 2 if verts.size() <= INDEX16_MAX_VERTS else 4


## Size of the surface's index buffer in bytes: what a patch has to fit inside.
static func index_patch_bytes(arrays: Array) -> int:
	return (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() * index_width(arrays)


## A patch is only meaningful while the index buffer is the length the surface
## was built at. If the chunk re-bakes -- which grows or shrinks the face count
## -- the region describes a buffer that no longer exists, and uploading it
## writes past the end of the one that does. Rebuild instead.
static func _patch_fits(region: Dictionary, buffer_bytes: int) -> bool:
	if buffer_bytes <= 0:
		return false
	var data: PackedByteArray = region.get("data", PackedByteArray())
	return int(region.get("offset", 0)) + data.size() <= buffer_bytes


## Same index-region patch the buildings use: the vertex buffer never changes
## under damage, so re-uploading it is both slow and, at this scale, a way to
## run the GPU out of memory.
## The island holding this chunk, or null. Used by anything that changes a
## piece's blocks from outside -- spilling a room's contents into wreckage, for
## one (Docs/Interiors.md section 4.1).
func find_by_chunk(chunk: int) -> BrickIsland:
	for isl in islands:
		if isl.is_valid() and isl.chunk == chunk:
			return isl
	return null


## Redraw the piece holding this chunk, after somebody else has added blocks to
## it. A collision rebuild comes with it: what was put in has to be solid.
func rebuild_chunk(chunk: int) -> bool:
	var isl := find_by_chunk(chunk)
	if isl == null:
		return false
	isl.changed = true
	_reshape(isl, isl.settled)
	rebuild_mesh(isl, true, true)
	refresh_furniture(isl)
	return true


## Redraw a piece's interiors. Cheap enough to call on any change: it walks the
## decorative blocks of one chunk, which is a room or two, not a building.
func refresh_furniture(isl: BrickIsland) -> void:
	if isl == null or isl.mesh == null:
		return
	FurnitureMesh.attach(world, isl.chunk, isl.mesh, _furniture)


func rebuild_mesh(isl: BrickIsland, force_full: bool = false, allow_sync: bool = false) -> void:
	if isl.mesh == null:
		return
	# Band meshes carried down from a building that toppled whole. They were
	# right until something changed, and something has: drop them and build the
	# one mesh an island uses.
	if not isl.bands.is_empty():
		for node in isl.bands:
			if is_instance_valid(node):
				_retirer.retire((node as MeshInstance3D).mesh)
				(node as MeshInstance3D).queue_free()
		isl.bands.clear()
		isl.array_mesh = null
		force_full = true
	# A child it just shed is still coming up; keep drawing those bricks until
	# it has. See OVERLAP_FRAMES. force_full comes from the mesh queue, for a
	# piece that is waiting on its own bake, and is never held.
	if not force_full and isl.hold_until > Engine.get_process_frames():
		if not _held.has(isl):
			_held.append(isl)
		return
	if isl.array_mesh != null and isl.array_mesh.get_surface_count() > 0 and not force_full:
		var region: Dictionary = world.update_index_region(isl.chunk, isl.index_width)
		if not region.is_empty() and _patch_fits(region, isl.index_bytes):
			if int(region.get("changed_bytes", 0)) > 0:
				RenderingServer.mesh_surface_update_index_region(
						isl.array_mesh.get_rid(), 0, int(region.offset), region.data)
			return

	# Never bake on the main thread. build_chunk_mesh() will do it silently if
	# the chunk has no valid bake, and for a freshly split 2,000-brick half
	# that is most of a second -- which no per-tick budget can bound, because
	# it is one indivisible call. Ask the worker and come back later.
	if not allow_sync and not world.bake_ready(isl.chunk):
		world.bake_chunk_async(isl.chunk)
		if not _mesh_queue.has(isl):
			_mesh_queue.append(isl)
		return

	var arrays: Array = world.build_chunk_mesh(isl.chunk)
	var mesh := ArrayMesh.new()
	if not arrays.is_empty() and mesh_arrays_ok(arrays, "island %d" % isl.chunk):
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Only a mesh that actually HAS a surface can be patched. A chunk with
	# nothing left alive produces no arrays, and patching surface 0 of an empty
	# ArrayMesh writes past the end of a buffer that is not there.
	isl.radius = _body_radius(isl)
	# The renderer may still be drawing the mesh this replaces.
	_retirer.retire(isl.mesh.mesh)
	isl.array_mesh = mesh if mesh.get_surface_count() > 0 else null
	isl.index_bytes = index_patch_bytes(arrays) if isl.array_mesh != null else 0
	isl.index_width = index_width(arrays)
	isl.mesh.mesh = mesh


# ---------------------------------------------------------------------------
# Waking
# ---------------------------------------------------------------------------

## A frozen body never re-evaluates, so one that is shot -- or that has just lost
## the piece it was resting on -- hangs exactly where it stopped. That is where
## floating wreckage comes from.
func wake(isl: BrickIsland) -> void:
	if not isl.is_valid() or not isl.settled:
		return
	isl.body.freeze = false
	isl.settled = false
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	_apply_layers(isl)
	isl.body.sleeping = false
	# Un-freezing changes the body's MODE in the physics server, and that resets
	# its interpolation history exactly the way rejoining a space does -- the
	# piece is drawn from wherever the interpolator last had it for one frame.
	#
	# This is the third door into the same bug (see BrickIsland.disable_blocks
	# and _reshape), and it is the one that shows on BIG pieces: only a large
	# island survives long enough to settle and freeze, so only a large island
	# is ever un-frozen by being shot. Small ones are swept up first.
	isl.body.reset_physics_interpolation()
	if isl.mesh != null:
		isl.mesh.reset_physics_interpolation()
	isl.born_ms = Time.get_ticks_msec()
	isl.prev_speed = 0.0
	settled = maxi(settled - 1, 0)


## Everything whose VOLUME comes within `radius` wakes, not everything whose
## ORIGIN does. A toppled building is forty metres long and its origin is its
## centre of mass, so an origin test leaves the far end of it hanging in the
## air after the wall under that end is shot away.
func wake_near(origin: Vector3, radius: float) -> void:
	for other in islands:
		if not other.is_valid() or not other.settled:
			continue
		# Cheap sphere reject before anything builds an AABB.
		if other.body.global_position.distance_to(origin) > other.radius + radius:
			continue
		if world_aabb(other).grow(radius).has_point(origin):
			wake(other)


## The island's AABB in world space. Rotating an AABB gives the box around the
## rotated box, which is what we want: it only ever errs towards including.
func world_aabb(isl: BrickIsland) -> AABB:
	return isl.chunk_transform() * _island_aabb(isl)


# ---------------------------------------------------------------------------
# Damage and splitting
# ---------------------------------------------------------------------------

## Shear an island's joints without destroying bricks -- the same thing an
## impact does, for when something lands ON it.
func shear(isl: BrickIsland, world_point: Vector3, radius: float) -> void:
	if not isl.is_valid():
		return
	# Rubble does not come apart on landing: it is already rubble, and it is
	# swept up in two and a half seconds either way. Splitting it buys a stress
	# solve, a connectivity walk and a cut-out per landing to produce smaller
	# pieces of the same thing -- measured, a collapse full of falling
	# staircases spent 9.7 ms a tick in exactly this.
	if isl.disposable:
		return
	wake(isl)
	wake_near(world_point, WAKE_RADIUS)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	_ensure_per_block(isl)
	var loosened: PackedInt32Array = world.separate_near(isl.chunk, world_point, radius,
			SHEAR_MAX_BLOCKS)
	if loosened.is_empty():
		return
	impact_blocks += loosened.size()
	isl.changed = true
	# Queued, not resolved here. Working out what the landing broke off means a
	# stress solve, a connectivity walk and cutting the pieces out, and on a
	# 2,000-brick tower that is hundreds of milliseconds in one indivisible
	# call -- which no per-tick clock can interrupt. The landing records the
	# damage; _drain_resolve_queue deals with the consequences on its own share.
	if not _resolve_queue.has(isl):
		_resolve_queue.append(isl)


func damage(isl: BrickIsland, world_point: Vector3, radius: float) -> void:
	if not isl.is_valid():
		return
	wake(isl)
	wake_near(world_point, WAKE_RADIUS)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	_ensure_per_block(isl)
	var killed: PackedInt32Array = world.apply_hit(isl.chunk, world_point, radius)
	if killed.is_empty():
		return
	isl.disable_blocks(killed)
	isl.changed = true
	# Rubble is not re-solved. Cutting a disposable piece into smaller
	# disposable pieces costs a stress solve, a connectivity walk and a chunk
	# per group, to produce more of what is already being swept up in two and a
	# half seconds.
	if not isl.disposable:
		solve_island(isl)
	rebuild_mesh(isl)


## Damage every loose piece whose volume reaches the blast, not every piece
## whose origin happens to sit near it. Returns how many were hit.
func damage_near(point: Vector3, radius: float) -> int:
	var hit := 0
	# What is asleep is still there to be hit.
	wake_dormant_near(point, radius)
	# Walk by index up to the count we started with: damaging a piece can
	# append new ones, and copying the list per call is itself O(islands).
	var n := islands.size()
	for i in n:
		var isl: BrickIsland = islands[i] if i < islands.size() else null
		if isl == null:
			continue
		if not isl.is_valid():
			continue
		if isl.body.global_position.distance_to(point) > isl.radius + radius:
			continue
		if world_aabb(isl).grow(radius).has_point(point):
			damage(isl, point, radius)
			hit += 1
	return hit


## Shear every loose piece the impact reaches, except the piece that caused it.
## Volume test, same reason as damage_near.
func shear_near(point: Vector3, radius: float, except: BrickIsland = null) -> int:
	var hit := 0
	# Walk by index up to the count we started with: damaging a piece can
	# append new ones, and copying the list per call is itself O(islands).
	var n := islands.size()
	for i in n:
		var isl: BrickIsland = islands[i] if i < islands.size() else null
		if isl == null:
			continue
		if isl == except or not isl.is_valid():
			continue
		if isl.body.global_position.distance_to(point) > isl.radius + radius:
			continue
		if world_aabb(isl).grow(radius).has_point(point):
			shear(isl, point, radius)
			hit += 1
	return hit


## Cut a set of block groups out of an island, each into an island of its own.
##
## **The parent's collision for those blocks has to go with them.** Leaving it
## behind is what made a broken fallen building refuse to come apart: the bricks
## left the parent in the world and in the mesh, but the parent's body still had
## solid, invisible shapes exactly where the new piece now sat. The two bodies
## overlapped, the solver pushed at them forever, and the result was halves that
## stayed joined, pieces floating on nothing, and a section that jittered and
## slid across the ground.
func _shed(isl: BrickIsland, groups: Array) -> int:
	if groups.is_empty():
		return 0
	var linear := isl.body.linear_velocity
	var angular := isl.body.angular_velocity

	# One space lift for the whole split, not one per group: disabling a shape
	# on a body that is IN a space costs time proportional to its shape count,
	# so a loop over a thousand of them is quadratic.
	var rid := isl.body.get_rid()
	var space := PhysicsServer3D.body_get_space(rid)
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, RID())
	_ensure_per_block(isl)
	var shed := 0
	var more := false
	for g in groups:
		if shed >= SHEDS_PER_PASS:
			more = true
			break
		var moved: PackedInt32Array = g
		if moved.is_empty():
			continue
		spawn(isl.chunk, moved, linear, angular)
		# Start a hold; never EXTEND one. A piece shedding on consecutive ticks
		# would otherwise push its own deadline forward every tick and never
		# rebuild at all, so its mesh would keep drawing bricks that had left
		# for as long as the cascade ran. Capped this way the mesh is stale for
		# OVERLAP_FRAMES at a time and no longer.
		if isl.hold_until <= Engine.get_process_frames():
			isl.hold_until = Engine.get_process_frames() + OVERLAP_FRAMES
		isl.changed = true
		# Whether or not spawn() kept the piece, those blocks are out of this
		# body. A discarded one is deleted, not left behind as ghost collision.
		isl.disable_blocks(moved, RID())
		shed += 1
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, space)
	if more and not _resolve_queue.has(isl):
		_resolve_queue.append(isl)
	if shed == 0:
		return 0
	# And redraw what is standing in it. Furniture is not in the face bake, so
	# rebuilding the mesh leaves the furniture drawing alone -- and without
	# this it went on drawing every piece that had just left, riding along in
	# mid-air with the piece it used to belong to.
	if _furniture.has(isl.chunk):
		refresh_furniture(isl)

	# The parent is lighter now. Without this it keeps the inertia of a building
	# while carrying half of one, and behaves like it is full of lead.
	isl.body.mass = maxf(world.get_chunk_mass(isl.chunk) * MASS_SCALE, 0.5)
	isl.fractures += 1
	splits += 1
	wake(isl)
	wake_near(isl.body.global_position, WAKE_RADIUS)
	return shed


## Anything no longer joined to the rest becomes its own piece.
func split_if_broken(isl: BrickIsland) -> void:
	var comps: Array = world.get_components(isl.chunk)
	if comps.size() <= 1:
		return
	_shed(isl, comps.slice(1))


## Run the tension solve on a piece that has already fallen.
##
## Standing buildings have had this since M2; islands never did, so a fallen
## section was structurally frozen -- you could disconnect bits off it, but
## undercutting it did nothing, because nothing re-asked whether what was left
## could still hold itself up.
##
## The catch is that **a chunk's grid does not rotate when the piece topples**.
## Weight flows along world down, which for a building lying on its side is some
## other grid axis entirely. So the world's down vector is rotated into chunk
## space and snapped to the nearest grid axis, and the solver anchors to
## whatever is lowest along it. A piece resting on a face -- which is where a
## toppled building ends up -- gets an exact answer; one balanced at an angle
## gets the nearest of six, which is still far better than pretending it is
## upright.
func solve_island(isl: BrickIsland) -> void:
	if not isl.is_valid() or world.get_alive_block_count(isl.chunk) == 0:
		return
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	var down: Vector3 = isl.body.global_transform.basis.inverse() * Vector3.DOWN
	# Scaled to integers so the extension can see which component dominates.
	world.set_chunk_gravity(isl.chunk, Vector3i(
			roundi(down.x * 100.0), roundi(down.y * 100.0), roundi(down.z * 100.0)))
	world.solve_stress(isl.chunk)
	# Tension failure marks joints, it does not move bricks. What comes loose is
	# whatever can no longer trace a path to the ground.
	_shed(isl, world.find_detached_groups(isl.chunk))
	split_if_broken(isl)


## A hard landing SHEARS the joints in the contact band. It destroys nothing --
## a brick that hits the ground comes loose, it does not cease to exist
## (Docs/BrickFailure.md).
func fracture_on_impact(isl: BrickIsland, severity: float) -> void:
	if _island_aabb(isl).size == Vector3.ZERO:
		return
	var radius := clampf(IMPACT_RADIUS * severity * 0.08, IMPACT_RADIUS, IMPACT_RADIUS_MAX)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())

	# Where it actually touched. The solver already knows; asking it beats
	# guessing from a bounding box, which for a toppled building meant shearing
	# a band up the side rather than across the face that landed.
	_ensure_per_block(isl)
	var contacts := _contact_points(isl)
	var box := world_aabb(isl)
	if contacts.is_empty():
		# No manifold -- the body has already come to rest, or the landing was
		# resolved between frames. Fall back to the bottom plane of the island
		# as it lies, in WORLD space.
		# Two steps, so nine points at most. Five gave thirty-six, and every one
		# of them is a full separate_near sweep over its own cell box -- 262 ms
		# in one indivisible call on a large settled piece, which is what made
		# landings the worst thing in the tick.
		var steps := clampi(int(maxf(box.size.x, box.size.z) / maxf(radius, 0.1)), 1, 2)
		for ix in steps + 1:
			for iz in steps + 1:
				contacts.append({"point": box.position + Vector3(
						box.size.x * float(ix) / float(steps), 0.0,
						box.size.z * float(iz) / float(steps)),
						"collider": RID()})

	# However the contacts were arrived at, only so many are worth shearing: a
	# landing is one event, not one per sample point.
	# Shearing a ball of joints at each contact is cosmetic -- a few bricks
	# coming loose where it touched down. Snapping the piece across is the thing
	# you actually see. So the sweeps are capped tightly and the planes are not:
	# each sweep walks its own cell box, and a dozen of them was 60 ms.
	var loosened := PackedInt32Array()
	for i in mini(contacts.size(), SHEAR_CONTACTS_MAX):
		# peel: the struck region comes away as one clump rather than as a spray
		# of single bricks. See BrickWorld::separate_near.
		loosened.append_array(world.separate_near(isl.chunk,
				(contacts[i] as Dictionary).point, radius, SHEAR_MAX_BLOCKS, true))
	loosened.append_array(_snap_across(isl, contacts, severity))
	if loosened.is_empty():
		return

	isl.impacts += 1
	impacts += 1
	impact_blocks += loosened.size()
	isl.changed = true
	# Queued, not resolved here -- the same rule shear() follows. Cutting the
	# pieces out means a connectivity walk and a spawn each, and doing it inline
	# put a landing at 63 ms in one indivisible call.
	if not _resolve_queue.has(isl):
		_resolve_queue.append(isl)

	# Whatever it landed on takes the other half of the collision. A falling
	# building that leaves its target untouched is the one thing nobody believes.
	#
	# Only the first couple of contacts are handed over. Landing on something is
	# ONE event, and each hand-over shears every loose piece within reach -- so
	# six contacts a few centimetres apart meant doing that six times over.
	# Two bricks bounce: see MIN_IMPACT_BLOCKS.
	if on_impact.is_valid() and world.get_alive_block_count(isl.chunk) >= MIN_IMPACT_BLOCKS:
		for i in mini(contacts.size(), IMPACT_HANDOVERS_MAX):
			var c: Dictionary = contacts[i]
			on_impact.call(isl, c.point, severity, c.collider)


## Tear a long piece across its width where it was struck.
##
## Returns the blocks along the break. The band becomes loose brick and the two
## sides become separate components, because connectivity already treats a
## sheared block as joined to nothing -- so a band torn across a tower leaves
## the two halves and a spray of bricks at the break, which is what a snapped
## brick model looks like.
func _snap_across(isl: BrickIsland, contacts: Array, severity: float) -> PackedInt32Array:
	var torn := PackedInt32Array()
	# Which axis does this piece bend about? Asked in the piece's OWN space, not
	# the world's.
	#
	# Joints run along the chunk's local Y and nowhere else, so that is the only
	# direction a clean seam can cross. Choosing the axis from the world box --
	# what this did first -- meant a tumbling piece was usually broken across
	# some diagonal of its local X or Z, where there is no seam to find, and
	# fourteen of twenty-four breaks fell back to tearing a band into gravel.
	#
	# Prefer local Y whenever the piece is long enough along it to be worth
	# snapping. A piece that is genuinely long the other way -- a floor slab --
	# still breaks, but it can only tear a band, and `band_breaks` counts that.
	var xf := isl.chunk_transform()
	var ls := _island_aabb(isl).size
	var local_axis := Vector3(0, 1, 0)
	var length: float = ls.y
	if length < BREAK_MIN_LENGTH and (ls.x > length or ls.z > length):
		if ls.x >= ls.z:
			local_axis = Vector3(1, 0, 0)
			length = ls.x
		else:
			local_axis = Vector3(0, 0, 1)
			length = ls.z
	var axis: Vector3 = (xf.basis * local_axis).normalized()
	longest_landed = maxf(longest_landed, length)
	if length < BREAK_MIN_LENGTH:
		short_landings += 1
		return torn

	# How hard is hard enough depends on how long the piece is, and measuring
	# that at the CENTRE OF MASS is why the first version almost never fired.
	# A toppling tower rotates: its far end arrives at twenty metres a second
	# while its centre barely slows, so the body's own speed drop understates
	# the impact by the ratio of the piece's length to its width. A thirty-metre
	# section touching down at one metre a second is a colossal impact; a
	# one-metre brick at the same speed is nothing.
	var need: float = BREAK_MIN_DROP * clampf(BREAK_MIN_LENGTH / length, 0.2, 1.0)
	if severity < need:
		soft_landings += 1
		return torn
	long_landings += 1

	# Offsets are measured in the piece's own space too: a world AABB's corner
	# is not a point on a rotated axis, so projecting it gave a span that had
	# nothing to do with the piece.
	var local_box := _island_aabb(isl)
	var lo: float = local_box.position.dot(local_axis)
	var hi: float = lo + length
	var inv_xf := xf.affine_inverse()
	var planes := 0
	var used: Array[float] = []
	var points := PackedVector3Array()
	for c in contacts:
		if planes >= BREAK_PLANES_MAX:
			break
		var at: float = (inv_xf * (c.point as Vector3)).dot(local_axis)
		# Severing right at an end shaves a cap off rather than breaking the
		# piece, and severing twice in one place is one break.
		if at - lo < BREAK_MIN_PIECE or hi - at < BREAK_MIN_PIECE:
			continue
		var crowded := false
		for u in used:
			if absf(u - at) < BREAK_SPACING:
				crowded = true
				break
		if crowded:
			continue
		points.push_back(c.point)
		used.append(at)
		planes += 1
	if planes > 0:
		# A SEAM first: sever one course of downward joints and leave both sides
		# solid, which is how a brick model comes apart. Tearing a band into
		# loose brick is the fallback, for a cut across an axis that has no
		# joints running along it -- see BrickWorld::sever_seams.
		torn = world.sever_seams(isl.chunk, points, axis)
		if torn.is_empty():
			torn = world.separate_planes(isl.chunk, points, axis, BREAK_THICKNESS)
			band_breaks += planes
		breaks += planes
	return torn


## How many pieces are invisible right now, and how big the biggest one is.
func _count_meshless() -> void:
	for isl in islands:
		if not isl.is_valid() or isl.mesh == null:
			continue
		# An ArrayMesh with no surfaces is NOT null and draws nothing; count both.
		var m: Mesh = isl.mesh.mesh
		if m == null or m.get_surface_count() == 0:
			isl.blind_ticks += 1
			meshless_worst_blocks = maxi(meshless_worst_blocks,
					world.get_alive_block_count(isl.chunk))
		elif isl.blind_ticks > 0:
			blind_worst = maxi(blind_worst, isl.blind_ticks)
			blind_total += isl.blind_ticks
			blind_count += 1
			isl.blind_ticks = 0


## The island's live contact manifold: world-space points, and the RID of what
## each one is touching.
func _contact_points(isl: BrickIsland) -> Array:
	var out := []
	var st := PhysicsServer3D.body_get_direct_state(isl.body.get_rid())
	if st == null:
		return out
	for i in st.get_contact_count():
		out.append({
			"point": st.get_contact_local_position(i),
			"collider": st.get_contact_collider(i),
		})
	return out


## Distance from the body's ORIGIN to the farthest corner of the piece.
##
## Not half the diagonal of its bounding box: the body is positioned at the
## centre of mass, and for a long piece that is nowhere near the centre of the
## box. Getting that wrong makes the cheap sphere reject throw away hits on the
## far end of a toppled building -- which is the exact case it exists to serve.
func _body_radius(isl: BrickIsland) -> float:
	var box := _island_aabb(isl)
	var lo := box.position - isl.local_com
	var hi := lo + box.size
	return Vector3(maxf(absf(lo.x), absf(hi.x)), maxf(absf(lo.y), absf(hi.y)),
			maxf(absf(lo.z), absf(hi.z))).length()


func _island_aabb(isl: BrickIsland) -> AABB:
	if isl.mesh != null:
		return isl.mesh.get_aabb()
	# A single brick drawn from a MultiMesh has no MeshInstance3D of its own.
	# local_com is its centre in chunk space, so the box starts half a brick
	# before that.
	var size := isl.mm_key if isl.mm_key != Vector3.ZERO else Vector3(0.35, 0.42, 0.35)
	return AABB(isl.local_com - size * 0.5, size)


# ---------------------------------------------------------------------------
# Per-tick
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var now := Engine.get_process_frames()
	overlap_peak = maxi(overlap_peak, _ghosts.size() + _held.size())
	var gi := _ghosts.size() - 1
	while gi >= 0:
		var g: Array = _ghosts[gi]
		if now >= int(g[1]):
			var node: Node = g[0]
			if is_instance_valid(node):
				node.queue_free()
			_ghosts.remove_at(gi)
		gi -= 1
	var hi := _held.size() - 1
	while hi >= 0:
		var h: BrickIsland = _held[hi]
		if not h.is_valid() or h.mesh == null:
			_held.remove_at(hi)
		elif now >= h.hold_until:
			_held.remove_at(hi)
			rebuild_mesh(h)
		hi -= 1



func tick() -> void:
	var _t_loop := Time.get_ticks_usec()
	_work_until = Time.get_ticks_usec() + int(WORK_BUDGET_MS * 1000.0)
	_work_done = 0
	_sync_meshes = 0
	var now := Time.get_ticks_msec()
	var i := islands.size() - 1
	while i >= 0:
		var isl := islands[i]
		i -= 1
		if not isl.is_valid():
			islands.remove_at(i + 1)
			continue

		# Only pieces that are actually moving need their grid transform written
		# back. A settled one had it written when it settled and cannot have
		# moved since; doing it for all of them made this loop O(every island)
		# every tick, which at 367 islands is most of a frame.
		if not isl.settled:
			world.set_chunk_transform(isl.chunk, isl.chunk_transform())

		# An island that has shed every block it had is an empty grid and a body
		# with nothing in it. The grid overlay is what made these obvious: a
		# scatter of chunk boxes with nothing drawn inside them. Only islands
		# that have actually lost blocks are asked; see BrickIsland.changed.
		if isl.changed:
			isl.changed = false
			if world.get_alive_block_count(isl.chunk) == 0:
				_retire(isl, i + 1)
				continue

		# Disposable debris is swept up after a few seconds, settled or not.
		if isl.disposable and now - isl.born_ms > DEBRIS_LIFETIME_MS:
			_retire(isl, i + 1)
			continue

		if isl.settled:
			continue

		var speed := isl.body.linear_velocity.length()
		if speed > MAX_DEBRIS_SPEED:
			isl.body.linear_velocity = isl.body.linear_velocity.normalized() * MAX_DEBRIS_SPEED
			speed = MAX_DEBRIS_SPEED
		var spin := isl.body.angular_velocity.length()
		if spin > MAX_DEBRIS_SPIN:
			isl.body.angular_velocity = isl.body.angular_velocity.normalized() * MAX_DEBRIS_SPIN
		var lost := isl.prev_speed - speed
		isl.peak_speed = maxf(isl.peak_speed, isl.prev_speed)
		isl.max_speed_lost = maxf(isl.max_speed_lost, lost)
		isl.prev_speed = speed

		if lost > IMPACT_DELTA and isl.prev_speed + lost > IMPACT_MIN_SPEED \
				and isl.impacts < MAX_IMPACTS and not isl.fracture_queued:
			peak_drop = maxf(peak_drop, lost)
			isl.fracture_queued = true
			_fracture_queue.append([isl, lost])
			continue

		if now - isl.born_ms >= SETTLE_MIN_MS and isl.body.sleeping:
			isl.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			isl.body.freeze = true
			isl.settled = true
			isl.settled_ms = Time.get_ticks_msec()
			isl.settled_blocks = world.get_alive_block_count(isl.chunk)
			world.set_chunk_transform(isl.chunk, isl.chunk_transform())
			_apply_layers(isl)
			# Inert now: give the solver as few boxes as the shape allows.
			_reshape(isl, true)
			settled += 1

	_stream_dormancy()
	# After dormancy, not before: what distance already put away does not
	# need the cap's attention.
	_enforce_debris_cap()
	var _tl := Time.get_ticks_usec()
	tick_prof.loop += float(_tl - _t_loop) / 1000.0
	_count_meshless()
	_retirer.drain()
	# Meshes first. A piece that has left its building but has no mesh yet is
	# a hole in the world, and the queues below can wait a tick -- they only
	# decide what breaks NEXT.
	_drain_mesh_queue()
	_drain_resolve_queue()
	var _tr := Time.get_ticks_usec()
	tick_prof.resolve += float(_tr - _tl) / 1000.0
	_drain_fracture_queue()
	var _tf := Time.get_ticks_usec()
	tick_prof.fracture += float(_tf - _tr) / 1000.0
	_stream_island_meshes()
	var _tm := Time.get_ticks_usec()
	tick_prof.mesh += float(_tm - _tf) / 1000.0
	_update_multimeshes()
	tick_prof.mm += float(Time.get_ticks_usec() - _tm) / 1000.0
	var _total := float(Time.get_ticks_usec() - _t_loop) / 1000.0
	if _total > float(tick_worst.get("total", 0.0)):
		tick_worst = {"total": _total,
				"loop": float(_tl - _t_loop) / 1000.0,
				"resolve": float(_tr - _tl) / 1000.0,
				"fracture": float(_tf - _tr) / 1000.0,
				"mesh": float(_tm - _tf) / 1000.0,
				"islands": islands.size()}


## Is there time left in this tick's share? Always yes for the first unit.
func _has_work_time() -> bool:
	return _work_done < WORK_MIN or Time.get_ticks_usec() < _work_until


## Islands that had more to shed than one pass allowed. Re-solving finishes
## the job, a couple of pieces at a time.
func _drain_resolve_queue() -> void:
	while _has_work_time() and not _resolve_queue.is_empty():
		var isl: BrickIsland = _resolve_queue.pop_front()
		if not isl.is_valid():
			continue
		solve_island(isl)
		rebuild_mesh(isl)
		_work_done += 1


## Work through landings a couple at a time. Each one shears the contact band
## and re-solves the piece, which is far too much to do for every island that
## touched down in the same tick.
func _drain_fracture_queue() -> void:
	while _has_work_time() and not _fracture_queue.is_empty():
		var entry: Array = _fracture_queue.pop_front()
		var isl: BrickIsland = entry[0]
		if not isl.is_valid():
			continue
		isl.fracture_queued = false
		fracture_on_impact(isl, float(entry[1]))
		_work_done += 1


## The island LOD ladder, such as it is: drawn, or not drawn and not baked.
##
## Only SETTLED islands are considered. Anything still moving is by definition
## something the player is watching fall, and re-baking it mid-flight would cost
## more than it saved.
func _stream_island_meshes() -> void:
	if camera == null or islands.is_empty():
		return
	var here := camera.global_position
	var budget := ISLAND_LOD_PER_TICK
	var looked := 0
	var slice := mini(islands.size(), ISLAND_LOD_PER_TICK * 16)
	while looked < slice and budget > 0:
		var isl: BrickIsland = islands[_lod_cursor % islands.size()]
		_lod_cursor += 1
		looked += 1
		if not isl.is_valid() or isl.mesh == null or not isl.settled:
			continue
		var dist := isl.body.global_position.distance_to(here)
		var has_mesh: bool = isl.array_mesh != null
		if has_mesh and dist > ISLAND_MESH_RANGE + ISLAND_MESH_HYSTERESIS:
			_retirer.retire(isl.mesh.mesh)
			isl.mesh.mesh = null
			isl.array_mesh = null
			isl.index_bytes = 0
			world.drop_chunk_bake(isl.chunk)
			dropped += 1
			budget -= 1
		elif not has_mesh and dist < ISLAND_MESH_RANGE:
			world.bake_chunk_async(isl.chunk)
			if not _mesh_queue.has(isl):
				_mesh_queue.append(isl)
			budget -= 1


## Turn finished bakes into meshes. The expensive part -- baking the faces --
## happened on a worker; what is left is assembling the arrays and handing them
## to the renderer, which still costs enough to be worth a budget.
func _drain_mesh_queue() -> void:
	var i := 0
	var until := Time.get_ticks_usec() + int(MESH_BUDGET_MS * 1000.0)
	var done := 0
	while i < _mesh_queue.size() and (done == 0 or Time.get_ticks_usec() < until):
		var isl: BrickIsland = _mesh_queue[i]
		if not isl.is_valid() or isl.mesh == null:
			_mesh_queue.remove_at(i)
			continue
		# Still on the worker? Leave it and look at the next one -- a big bake
		# must not hold up a small one behind it.
		if not world.bake_ready(isl.chunk):
			# ...unless there is no worker. Damaging a chunk CANCELS a bake in
			# flight (place_block and remove_block both call settle_bake_job,
			# because a bake running against the old geometry is worthless and is
			# reading the arrays they just rewrote). Nothing re-issued it, so a
			# piece that was hit again while its mesh was baking waited on a
			# `bake_ready` that could never come -- and stayed invisible until
			# something unrelated happened to ask for a bake.
			#
			# Measured before this: pieces blind for a mean of 17.8 physics ticks
			# and a worst of 102, which is over three seconds.
			if not world.bake_pending(isl.chunk):
				world.bake_chunk_async(isl.chunk)
			i += 1
			continue
		_mesh_queue.remove_at(i)
		rebuild_mesh(isl, true)
		done += 1


## Put distant, settled wreckage away, and bring back what somebody has walked
## up to. One of each a tick.
## Bring the live debris back under the caps.
##
## Only SETTLED pieces are ever evicted -- something still falling is something
## the player is watching, and the cap is about what is lying around afterwards.
func _enforce_debris_cap() -> void:
	var small: Array = []
	var large: Array = []
	for i in islands.size():
		var isl: BrickIsland = islands[i]
		if not isl.is_valid() or not isl.settled or isl.disposable:
			continue
		if isl.settled_blocks <= SMALL_BLOCKS:
			small.append(i)
		else:
			large.append(i)
	var live := small.size() + large.size()
	cap_worst_over = maxi(cap_worst_over, live - total_live_max)
	var over_small := maxi(small.size() - small_live_max, 0)
	var over_large := maxi(large.size() - large_live_max, 0)
	# The total, spent on the small class first and only then on the large one.
	var over_total := maxi(live - total_live_max, 0)
	if over_total > 0:
		var spare_small := maxi(small.size() - small_floor, 0)
		var from_small := mini(over_total, spare_small)
		over_small = maxi(over_small, from_small)
		over_large = maxi(over_large, over_total - from_small)
	if over_small <= 0 and over_large <= 0:
		return

	# Oldest at rest first, and evicted by index descending so that removing one
	# cannot move another out from under the loop.
	var doomed: Array = []
	if over_small > 0:
		small.sort_custom(func(a, c) -> bool:
				return islands[a].settled_ms < islands[c].settled_ms)
		for k in mini(over_small, small.size()):
			doomed.append([small[k], true])
	if over_large > 0:
		large.sort_custom(func(a, c) -> bool:
				return islands[a].settled_ms < islands[c].settled_ms)
		for k in mini(over_large, large.size()):
			doomed.append([large[k], false])
	doomed.sort_custom(func(a, c) -> bool: return int(a[0]) > int(c[0]))
	var done := 0
	for entry in doomed:
		if done >= EVICTIONS_PER_TICK:
			break
		var at: int = int(entry[0])
		if at >= islands.size():
			continue
		var isl: BrickIsland = islands[at]
		if not isl.is_valid() or not isl.settled:
			continue
		if bool(entry[1]):
			_retire(isl, at)
			cap_deleted += 1
		elif _sleep(isl, at):
			cap_slept += 1
		else:
			# Nothing to photograph, so there is nothing to keep either.
			_retire(isl, at)
			cap_deleted += 1
		done += 1


func _stream_dormancy() -> void:
	if camera == null:
		return
	var here := camera.global_position

	# Waking first, always. Something the player is walking towards matters
	# more than something they have walked away from.
	var woke := 0
	for i in range(dormant.size() - 1, -1, -1):
		if woke >= WAKES_PER_TICK:
			break
		var d: Dormant = dormant[i]
		if _distance_to_box(d.record.box, here) > WAKE_RANGE:
			continue
		if _wake_record(d) != null:
			dormant.remove_at(i)
			woke += 1

	var now := Time.get_ticks_msec()
	var put_away := 0
	var scanned := 0
	while scanned < islands.size() and put_away < SLEEPS_PER_TICK:
		scanned += 1
		if _sleep_cursor >= islands.size():
			_sleep_cursor = 0
		var at := _sleep_cursor
		_sleep_cursor += 1
		var isl: BrickIsland = islands[at]
		if not isl.is_valid() or not isl.settled or isl.disposable:
			continue
		if now - isl.born_ms < SLEEP_AFTER_MS:
			continue
		if isl.body.global_position.distance_to(here) - isl.radius < SLEEP_RANGE:
			continue
		if _sleep(isl, at):
			put_away += 1
			_sleep_cursor = at   # the list shifted under the cursor


## Photograph a piece and give everything else back.
func _sleep(isl: BrickIsland, index: int) -> bool:
	var record := ChunkRecord.capture(world, isl.chunk)
	if record.block_count() == 0:
		return false
	var d := Dormant.new()
	d.record = record
	d.slept_ms = Time.get_ticks_msec()
	dormant.append(d)
	slept += 1
	_retire(isl, index)
	return true


## Build a dormant piece back into the world, already at rest.
##
## It was settled when it was put away and nothing has happened to it since, so
## it comes back frozen, with merged collision, and does not go through the
## settle loop again.
func _wake_record(d: Dormant) -> BrickIsland:
	var chunk := d.record.restore(world)
	if chunk < 0:
		return null
	var isl := adopt(chunk, null, null, 0, 4)
	if isl == null:
		world.release_chunk(chunk)
		return null
	isl.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	isl.body.freeze = true
	isl.settled = true
	isl.settled_ms = Time.get_ticks_msec()
	isl.settled_blocks = world.get_alive_block_count(isl.chunk)
	settled += 1
	_apply_layers(isl)
	_reshape(isl, true)
	# Small enough to bake here, or queued like any other big piece.
	if d.record.block_count() <= SYNC_MESH_MAX_BLOCKS:
		rebuild_mesh(isl, true, true)
	else:
		world.bake_chunk_async(chunk)
		_mesh_queue.append(isl)
	woken += 1
	return isl


## Wake anything dormant that this volume reaches, so that a blast lands on
## wreckage whether or not it happened to be resident.
##
## Plan §4.4: applying damage does not require a player to be nearby, only
## SHOWING it does. A piece that is asleep because nobody is near it still has
## to take the hit.
func wake_dormant_near(point: Vector3, radius: float) -> int:
	var n := 0
	for i in range(dormant.size() - 1, -1, -1):
		var d: Dormant = dormant[i]
		if not d.record.box.grow(radius).has_point(point):
			continue
		if _wake_record(d) != null:
			dormant.remove_at(i)
			n += 1
	return n


static func _distance_to_box(box: AABB, point: Vector3) -> float:
	return maxf(box.get_center().distance_to(point) - box.size.length() * 0.5, 0.0)


## Bytes the dormant tier is holding, and what it is standing in for.
func dormant_report() -> Dictionary:
	var bytes := 0
	var blocks := 0
	for d in dormant:
		bytes += d.record.bytes()
		blocks += d.record.block_count()
	return {"pieces": dormant.size(), "blocks": blocks, "bytes": bytes,
			"slept": slept, "woken": woken}


func _retire(isl: BrickIsland, index: int) -> void:
	FurnitureMesh.drop(isl.chunk, _furniture)
	_mesh_queue.erase(isl)
	if isl.settled:
		settled = maxi(settled - 1, 0)
	if isl.mm_key != Vector3.ZERO and _mm_members.has(isl.mm_key):
		(_mm_members[isl.mm_key] as Array).erase(isl)
	world.release_chunk(isl.chunk)
	isl.chunk = -1
	isl.body.queue_free()
	islands.remove_at(index)


## One draw call per brick size, however many loose bricks there are.
func _update_multimeshes() -> void:
	for key in _multimesh:
		var members: Array = _mm_members[key]
		var mmi: MultiMeshInstance3D = _multimesh[key]
		var mm: MultiMesh = mmi.multimesh
		if mm.instance_count != members.size():
			mm.instance_count = members.size()
		for i in members.size():
			var isl: BrickIsland = members[i]
			if not isl.is_valid():
				continue
			mm.set_instance_transform(i, isl.body.global_transform)
			mm.set_instance_color(i, isl.mm_colour)


func report() -> Dictionary:
	var blocks := 0
	var loose := 0
	for isl in islands:
		if isl.is_valid():
			blocks += world.get_alive_block_count(isl.chunk)
			if isl.disposable:
				loose += 1
	var d := dormant_report()
	return {
		"islands": islands.size(),
		"dormant": int(d.pieces),
		"dormant_blocks": int(d.blocks),
		"dormant_bytes": int(d.bytes),
		"slept": slept,
		"woken": woken,
		"settled": settled,
		"blocks": blocks,
		"disposable": loose,
		"discarded": discarded,
		"furniture_deleted": furniture_deleted,
		"dropped": dropped,
		"breaks": breaks,
		"band_breaks": band_breaks,
		"overlap_peak": overlap_peak,
		"blind_worst": blind_worst,
		"blind_mean": float(blind_total) / maxf(blind_count, 1),
		"blind_count": blind_count,
		"meshless_worst_blocks": meshless_worst_blocks,
		"merged_shapes": merged_shapes,
		"merged_boxes": merged_boxes,
		"unmerged_boxes": unmerged_boxes,
		"peak_drop": peak_drop,
		"long_landings": long_landings,
		"soft_landings": soft_landings,
		"short_landings": short_landings,
		"longest_landed": longest_landed,
		"impacts": impacts,
		"impact_blocks": impact_blocks,
		"splits": splits,
	}
