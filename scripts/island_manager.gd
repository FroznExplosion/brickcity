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
##   * a small piece stays while it can be seen, goes a second after it cannot,
##     and when it has to go in view it shrinks away rather than popping.
##
## "Small" -- DEBRIS -- is DEBRIS_MAX_BLOCKS bricks or fewer, however big, and
## above that it is size (Docs/AIPlan.md R2, AI.md A11, both as revised on
## 2026-09-25: a lone floor panel was a landmark until then, and a collapse made
## hundreds of them). A piece bigger than that and big enough to hide behind or
## stand on is a LANDMARK (is_landmark_size): it is never deleted, it collides
## with people, the AI takes cover behind it and every machine in a co-op game
## has the same one. Debris is presentation only -- no pawn collides with it
## (Layers.PAWN_MASK), each machine keeps or deletes its own by what ITS camera
## can see, and nothing but the eye ever depends on it.
##
## Landmarks are never touched by any of this. A section that stays intact is the
## thing the whole model exists to produce.

const MASS_SCALE := 10.0
const SETTLE_MIN_MS := 900
## A piece settles when it has stayed this slow for this long, whether or not
## Jolt has put it to sleep.
##
## Settling used to wait for sleep alone -- under 0.06 m/s for 0.3 s -- and in
## a big collapse almost nothing got there: pieces resting in a heap nudge each
## other forever, and once the solver runs out of contact slots it DROPS
## contacts, so they jitter as well. The --big census had ~390 pieces still
## moving five seconds in, carrying ~180,000 collision boxes, and settled is
## where a piece stops costing anything (frozen static, merged boxes).
##
## Nothing in free fall can pass this: falling pieces have 1.6x gravity, so
## half a metre a second is left behind in a thirtieth of a second. What stays
## this slow for this long is being held up by something.
const SETTLE_SPEED := 0.5       ## m/s
const SETTLE_SPIN := 0.5        ## rad/s
const SETTLE_SLOW_MS := 700
## Closer than this to the player, a piece gets longer to finish rocking or
## tipping over -- the settle is a freeze, and a freeze you are looking at from
## three metres should not come a beat early.
const SETTLE_NEAR := 20.0
const SETTLE_SLOW_NEAR_MS := 1500
## And whatever it is doing, a piece this old that is not actually falling --
## slower than this -- is frozen where it is. The backstop for something wedged
## and vibrating that never gets under SETTLE_SPEED at all.
const SETTLE_MAX_MS := 12000
const SETTLE_MAX_SPEED := 2.0
## Farther than FRACTURE_RANGE from every player, a piece settles on a shorter
## window: nobody is close enough to see it rock, and every tick it spends
## rocking is a body the solver steps. Physics LOD, in the same terms as the
## landing rule it sits beside.
const SETTLE_SLOW_FAR_MS := 350
## And it falls merged from this size, not MERGE_FALLING_BLOCKS: a far landing
## breaks nothing (FRACTURE_RANGE), so nothing needs its bricks one box each
## while it falls. A hit on it un-merges it first, as it does any merged piece.
const FAR_MERGE_BLOCKS := 8
## The hard cap on moving pieces (step 4 of the collapse plan). With this many
## already moving, a LANDMARK that comes loose farther than FRACTURE_RANGE from
## every player is cut out and dropped, on every machine: the host decides it
## and says so in the DETACH (DamageLog.FLAG_GONE), so nobody's world differs.
## Anything near a player still falls, however many are moving. Small pieces
## are each machine's own and already go where nobody sees them.
const MAX_MOVING := 48
## How many pieces may settle in one tick. A settle is a merged shape rebuild, a
## freeze and a recorded rest, and the rule above settles a heap all at once:
## measured, one tick spent 75 ms of its loop on it. The rest wait a tick --
## still slow, still where they were.
const SETTLES_PER_TICK := 12
## A settled piece is frozen: it is scenery until something wakes it, and it
## was only ever woken by damage near it. So a piece that settled resting on
## something -- a part of the building a mega collapse was still holding, a
## piece that later woke and slid off, one the debris cap deleted -- stayed where
## it was when that went, in mid-air, and what fell next landed on it and stuck,
## jittering and breaking more with every bounce.
##
## Now: where support goes away (support_gone), every settled piece resting on
## or wedged against that spot is woken, and settles again if it is still held.
## A piece that is woken or cut out ripples once it actually starts to move, so
## a stack wakes a layer at a time as each one falls, not all at once. A piece
## that comes to rest on, or lands on, a settled piece wakes that too: a
## floater falls under the load instead of holding it up.
##
## RIPPLE_MARGIN: how far past the box a resting piece may be and still count
## as touching it. RIPPLE_START_SPEED: how fast a woken piece has to be going to
## count as having moved off what it was holding.
const RIPPLE_MARGIN := 0.35
## And before a piece settles at all: is anything under it? A piece is cut out
## of a grid, so its faces lie exactly against the bricks it came away from, and
## friction on those can hold it where it was until it goes to sleep -- a piece
## that "broke off and stayed there" in the side of a building. Rays down from
## its underside (SUPPORT_REACH): nothing under it, and it is nudged down instead
## of frozen. SUPPORT_TRIES times at most -- a beam genuinely wedged across a gap
## is held, and settles on the next try.
const SUPPORT_REACH := 1.5
const SUPPORT_TRIES := 3
const SUPPORT_NUDGE := 1.5
## ...but SUPPORT_TRIES is only for a piece that is TOUCHING something. Past its
## tries a piece with nothing under it used to settle anyway -- right for a beam
## wedged across a gap, wrong for a piece held up by nothing at all. A tornado
## holds pieces slow in mid-air; they ran out of tries there, froze, and hung
## in the sky once it had gone. Now a piece that touches nothing -- no body
## within TOUCH_MARGIN of its box -- is never frozen, however many tries: it is
## nudged down again and again until it lands on something.
const TOUCH_MARGIN := 0.15
## And the WATCHDOG, for everything else that takes support away without a
## ripple: every tick AUDIT_PER_TICK settled pieces, round-robin, are asked the
## same two questions -- anything under it? anything touching it? -- and a
## piece that answers no to both is woken, and falls. Ten rays and a box query
## each; a city's worth of settled pieces is audited every few seconds.
const AUDIT_PER_TICK := 4
var unsupported_nudges := 0
const RIPPLE_START_SPEED := 0.6
const RIPPLES_PER_TICK := 16
var _ripples: Array[AABB] = []
var ripple_woken := 0
var touch_woken := 0
## Pieces at least this big fall with MERGED collision -- as few boxes as the
## shape allows -- rather than one box per brick. The --big census had ~23
## pieces of a thousand bricks and more carrying 80% of every collision box in
## the collapse, one per brick, all of them moving.
##
## It was tried once before and reverted: a merged piece had to be rebuilt one
## box per brick the moment it landed, so every landing paid for two shape
## builds. Nothing converts a falling piece back now. Landing, shearing, shedding
## and blasting work on the bricks' own joints, and the piece is rebuilt merged
## once at the end of the tick (_flush_reshapes) -- one build, not two, and far
## fewer boxes to build.
const MERGE_FALLING_BLOCKS := 200
## A landing further than this from every player does not break the piece that
## landed: it lands whole. What it landed ON still takes the hit, so a tower
## coming down on a building still wrecks the building.
##
## The pieces a landing breaks off are mostly landmarks -- big enough to stand
## on -- and landmarks are never deleted, because every machine has to have
## them. So the only way to have fewer of them far away is not to make them.
## The host decides, and what it decides is recorded, so every machine agrees.
const FRACTURE_RANGE := 60.0
const WAKE_RADIUS := 6.0

## Impact shear. A landing releases joints; it destroys nothing.
const IMPACT_MIN_SPEED := 4.0
const IMPACT_DELTA := 2.5
const IMPACT_RADIUS := 0.8
const IMPACT_RADIUS_MAX := 2.6
const MAX_IMPACTS := 4
## And only after falling -- over IMPACT_MIN_SPEED for this many ticks in a row
## since the last landing. A piece wedged on something and jittering swings its
## speed by metres a second from one tick to the next, and every swing counted
## as a landing: it broke itself up and sheared whatever it was stuck on --
## the building under it included -- MAX_IMPACTS times, where it had not
## fallen anywhere at all.
const IMPACT_FALL_TICKS := 3
var jolts_ignored := 0
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

## Debris budget -- by size. See the class notes.
## A piece at least this long is a landmark whatever else it is: a beam, a floor
## panel, a section of wall lying in the street.
const LANDMARK_SPAN := 2.0
## Or whose box is at least this big: a clump waist-high to a person, which is
## cover. A single 2x4 brick is 0.41; three stacked are 1.23.
const LANDMARK_VOLUME := 0.9
## Past this many blocks a group is a landmark without being measured: walking the
## blocks of a big group to prove it is big is the cost this exists to avoid.
const LANDMARK_COUNT := 48
## How close a piece that is nothing but furniture has to be to be allowed to
## fall rather than be deleted where it came loose. Arm's length and a bit: a
## chair tipping off a floor in front of you is worth a body; anywhere else it
## is a floating cube for a second and small debris after that.
const FURNITURE_FALL_RANGE := 6.0
## A small piece breaks off only this close to the player, and in view. Anywhere
## else it is deleted where it came loose. Per machine: small pieces are that
## machine's presentation, so its own camera decides.
const SMALL_KEEP_RANGE := 60.0
## A group of this many bricks or fewer is DEBRIS, however far it spans: a floor
## panel on its own is a sheet of plastic, not cover. Presentation only -- the
## RUBBLE layer, which no pawn collides with -- and each machine keeps or drops
## its own (AI.md A11, AIPlan R2, as revised 2026-09-25). Above it, size decides
## (is_landmark_size).
const DEBRIS_MAX_BLOCKS := 8
## Debris is never removed while this machine's camera can see it. It goes once
## it has been out of view this long -- counted in physics TICKS (_unseen_ticks),
## because a hitch longer than a second is not a second of nobody looking...
const DEBRIS_UNSEEN_MS := 1000
## ...and, seen or not, it shrinks away once it is this old, over DEBRIS_FADE_MS --
## never a pop. The debris cap shrinks what it takes that is in view, too.
const DEBRIS_SEEN_MAX_MS := 30000
const DEBRIS_FADE_MS := 600
## Every how many ticks each piece of debris is asked whether it can be seen.
const SEEN_EVERY := 4
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
##
## Out there it is drawn as the coarse stand-in (BrickWorld.build_chunk_coarse_mesh:
## its outer surface merged across bricks by colour, brick outlines from the
## seam shader, no bake). It used to be drawn as nothing -- settled wreckage
## past 145 m vanished, which anyone on a roof could watch happen. A piece that
## comes loose out there starts as the stand-in (spawn), so a collapse far off
## never bakes or uploads its full bricks at all: those uploads were a far
## collapse's worst frames (render buffers made on the main thread, 12 ms).
const ISLAND_MESH_RANGE := 120.0
const ISLAND_MESH_HYSTERESIS := 25.0
## Changing tier is cheap, but not free, so only a few change tier per tick.
const ISLAND_LOD_PER_TICK := 2
## A stand-in already drawn is built again at most this often. A piece falling
## far off sheds bricks every few ticks, and each was a stand-in built again --
## one piece ten times over in the big city's collapse. 145 m away nobody sees
## half a second of a few bricks too many.
const COARSE_REBUILD_TICKS := 15
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
## And few enough authored triangles (BrickWorld.get_chunk_authored_tris): a
## staircase piece is under 200 bricks and 90,000 vertices, and baking one here
## was a 9.5 ms spawn -- the worst of a big-city run.
const SYNC_MESH_MAX_TRIS := 2000
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
## A mesh with at least this many vertices is uploaded on a worker, not in the
## tick. The arrays come out of the bake in under a millisecond; handing them to
## the renderer is ~50 ns a vertex -- 5-35 ms for a piece of 3,000-8,400 bricks,
## or for a staircase of 150 (90,000 vertices of spiral step), and that was the
## worst tick of a collapse every time a big piece got its mesh. The worker
## packs the arrays, which is about two thirds of it; the renderer still creates
## the buffers on the main thread at the next call into it (measured: 3-4 ms for
## 62,000 vertices built here, 1-1.5 ms attached from a worker). High priority
## on the pool: a piece waiting for its mesh is invisible, a building band
## waiting for its new one is not (CityScene.BAND_THREAD_VERTS).
const THREAD_MESH_VERTS := 30000
## And how many vertices of those may be handed over in one tick. The worker
## packs a mesh's arrays, but the renderer makes its buffers on the main thread,
## at whatever next calls into it -- a node being made, a mesh being set -- about
## 25 ns a vertex (62,000 vertices, 1-1.5 ms). Unbudgeted, what the workers
## finished together was paid together, wherever that landed: a spawn's "node"
## step at 7-11 ms, band meshes at 4-7. What is over waits a tick with its arrays
## kept; the first of a tick always goes, since a mesh cannot be split.
const UPLOAD_VERTS_PER_TICK := 150000
## Meshes built on a worker are built compressed (16-bit positions and UVs,
## octahedral normals): the worker's half takes twice as long, and the main
## thread's -- the buffers the renderer makes -- about a third less (62,000
## vertices: 1.1 ms -> 0.7). Rendered side by side with the plain mesh, 0.14% of
## pixels differ, all of them brick edges moved by a pixel.
const UPLOAD_COMPRESS := Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
## A mesh job submitted and not yet started (start_mesh_jobs). BrickIsland's
## mesh_job is -1 for none, this for one waiting to start, a task id otherwise.
const JOB_NOT_STARTED := -2
## Set by a scene that ticks this manager and then does more: it starts the
## jobs itself, after all of it (see _submit_mesh_job).
var defer_job_start := false
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
var tiny_deleted := 0              ## small pieces deleted where they came loose, far away
var settled_by_rule := 0          ## settled for staying slow, not for sleeping
var far_landings := 0             ## landings too far from anyone to break the piece
var far_shears := 0               ## things landed on too far from anyone to shear
var merged_rebuilds := 0          ## falling pieces rebuilt merged after a change
var floating_refused := 0         ## settles refused: nothing under, nothing touching
var audit_woken := 0              ## settled pieces the watchdog found floating and woke
var _audit_at := 0
## Off only for probes that test another way of waking a floater.
var audit_enabled := true
var _touch_shape := BoxShape3D.new()
var _reshape_list: Array[BrickIsland] = []
var _sleep_jobs: Array = []       ## [island, record, edits when begun, for the cap]
var settled_by_age := 0           ## settled because SETTLE_MAX_MS ran out

## Called when an island lands hard: (island, world_point, severity). The scene
## uses it to damage whatever was underneath -- an island has no idea what it
## hit, and should not.
var on_impact: Callable = Callable()

## --- lifecycle -------------------------------------------------------------
## Docs/AIPlan.md P0 step 3. What the AI (and anything else that keeps its own
## picture of the wreckage) listens to, instead of walking `islands` every tick.
## A building's own structural changes are WorldAuthority.committed.

## A piece has come loose and has a body.
signal piece_spawned(isl: BrickIsland)
## It has stopped moving: frozen, merged, scenery that things land on.
signal piece_settled(isl: BrickIsland)
## It lost blocks, or had joints severed.
signal piece_changed(isl: BrickIsland)
## It is gone from the live set. `reason`: empty, swept, cap, slept.
signal piece_removed(isl: BrickIsland, reason: StringName)
## It was put away as a record: no body, no collision, still there.
signal piece_slept(piece_id: int, record: ChunkRecord)
## A record came back as a live piece.
signal piece_woken(isl: BrickIsland)

## --- authority -------------------------------------------------------------
## Docs/AIPlan.md P0 step 4, and R5: only the host turns physics into structure.

## Host: every structural operation performed on a piece, as a command, BEFORE
## the next one. Called with a DamageLog.Entry; returns the seq it was given
## (-1 if nothing recorded it). The scene routes it to WorldAuthority.
var on_command := Callable()
## Does this machine decide what breaks? False on a co-op client: its pieces
## never fracture, shear or solve of their own accord -- those arrive as the
## host's commands.
var decides := true
## Piece ids when nothing is recording: a tool or probe using this directly.
var _local_seq := 0

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
var _band_holes: Array = []  ## toppled pieces with bands still to build
var _mesh_jobs: Array = []   ## [island, task id, [mesh], arrays]
var _upload_waiting: Array = []  ## [island, arrays] over this tick's budget
var _upload_tick := -1
var _upload_used := 0
var uploads_waited := 0
var mesh_jobs_done := 0
var band_holes_filled := 0
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
## The classes are the size classes of the class notes: a landmark is LARGE,
## anything else SMALL (small pieces are swept up at rest, so the small cap rarely
## has anything left to do). Two caps, and the classes differ in what eviction
## MEANS:
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
##
## Small pieces go oldest-at-rest first. LARGE pieces go FARTHEST from anybody
## first, and never one within CAP_KEEP_RANGE of an interest point: a piece put to
## sleep has no collision, and somebody standing on it or behind it -- a player, or
## later an AI agent in cover (Docs/AI.md section 3.5) -- must not have it vanish
## under them.
const CAP_KEEP_RANGE := 8.0
var small_live_max := 220
var large_live_max := 60
var total_live_max := 240
var small_floor := 24
## How many pieces may be evicted in one tick. Deleting is cheap; sleeping
## captures a record, so it is budgeted like every other per-tick cost here.
const EVICTIONS_PER_TICK := 3
## A piece bigger than this is captured for sleep a slice at a time, and at most
## this many blocks of captures run in one tick. Capture was ~4 us a block from
## script -- the debris cap put a 14,000-brick wreck to sleep in one call, 57 ms
## of one tick, and a 2,000-brick piece slept in one go was still 8 ms. It is
## one call into the world now (BrickWorld.capture_blocks), 0.1-0.2 us a block.
const SLEEP_SYNC_BLOCKS := 6000
const CAPTURE_BLOCKS_PER_TICK := 12000
var cap_deleted := 0
var cap_slept := 0
var cap_worst_over := 0
## A piece the CAP put to sleep does not wake just for being in WAKE_RANGE. It
## did, and next to a big collapse -- where the cap is full and everything is
## inside 120 m -- the cap slept a piece, the stream woke it the next tick, and
## the cap slept it again: 1.25 ms a tick of dormancy across a whole big-city
## run, a 15 ms wake at the top of the worst tick, and wreckage blinking out and
## back in. So it wakes when the cap has room again (CAP_WAKE_SPARE under every
## limit, so the one it wakes does not tip it straight back over), or when it is
## clearly nearer than the farthest piece still awake (CAP_SWAP): that one is
## the cap's next choice, and the two trade places once rather than every tick.
const CAP_WAKE_SPARE := 8
const CAP_SWAP := 0.6
var _cap_room := true
## How far from anybody the farthest landmark the cap left awake is, at the
## last plan.
var _cap_far := INF
var cap_woken := 0
## The cap's plan (_plan_debris_cap) and when it was made.
const CAP_REPLAN_TICKS := 15
var _cap_plan: Array = []
var _cap_planned := -1000


class Dormant:
	var record: ChunkRecord
	var slept_ms := 0
	var piece_id := -1
	var owner := -1
	## Put to sleep by the debris cap, not by distance. See CAP_WAKE_SPARE.
	var by_cap := false
	## What it rested on went while it slept (IslandManager.support_gone).
	var unsure := false
	## What it left drawn where it lay: its coarse stand-in, a node with no
	## body (IslandManager._leave_stand_in). For a piece put back asleep from a
	## save, built a little after (build_due_stand_ins).
	var stand_in: MeshInstance3D = null


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
const WAKE_SCAN_PER_TICK := 32
var _wake_cursor := 0

var dormant: Array[Dormant] = []
var slept := 0
var woken := 0
## Set while restore_piece adopts a piece from a save. See adopt.
var _restoring := false
## Where the sleep scan got to. Walking every island every tick to ask how far
## away it is would be the same O(islands) mistake the settle loop already
## learned not to make.
var _sleep_cursor := 0

var _resolve_queue: Array[BrickIsland] = []  ## more to shed than one pass allowed
var _work_until := 0
## Where tick() actually spends its time, summed over the session.
var tick_prof := {"loop": 0.0, "resolve": 0.0, "fracture": 0.0, "mesh": 0.0, "mm": 0.0,
		"pieces": 0.0, "dormancy": 0.0, "cap": 0.0}
## What is in motion, tick by tick: pieces not yet settled, how many of them are
## landmarks, and how many bricks they carry. Summed for a mean and kept at the
## peak, for the report.
var census := {"ticks": 0, "moving": 0, "moving_peak": 0, "landmarks": 0,
		"landmarks_peak": 0, "blocks": 0, "blocks_peak": 0}
## Every group that came loose, by what became of it: [bodies, bricks] each.
## Debris gone because nobody could see it, and debris shrunk away in view.
var debris_unseen := 0
var debris_faded := 0
## The camera's frustum, refreshed every tick (_box_seen).
var _frustum: Array[Plane] = []
var spawn_census := {"landmark": [0, 0], "small": [0, 0], "deleted": [0, 0],
		"capped": [0, 0], "shed": [0, 0]}
## Pieces moving as of the last tick, plus bodies made since: what the cap reads.
var _moving_now := 0
## DETACHes recorded with FLAG_GONE, by the piece id they would have had.
var _gone_pieces := {}
var tick_worst := {}
## The worst single spawn: [ms, split, shapes, node, mesh, bricks].
var spawn_worst := [0.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0]
## The worst single landing or re-solve of a piece, by part, for the report.
var unit_worst := {}
var _unit := {}


func _upart(key: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	_unit[key] = float(_unit.get(key, 0.0)) + float(now - t0) / 1000.0
	return now


func _unit_done(kind: String, isl: BrickIsland, t0: int) -> void:
	var total := float(Time.get_ticks_usec() - t0) / 1000.0
	if total > float(unit_worst.get("total", 0.0)):
		unit_worst = _unit.duplicate()
		unit_worst["total"] = total
		unit_worst["kind"] = kind
		unit_worst["bricks"] = world.get_alive_block_count(isl.chunk) if isl.is_valid() else -1
		unit_worst["merged"] = isl.merged if isl.is_valid() else false
	_unit = {}
## The longest invisible stretch, by what the piece was waiting for each tick.
var blind_worst_stages := {}
## The worst single shape rebuild of a piece: [ms, bricks, boxes, building the
## shapes ms, putting the body back in the space ms].
var reshape_worst := [0.0, 0, 0, 0.0, 0.0]
## This tick's dormancy, split: waking pieces, and putting them to sleep. And
## the single worst of each over the session, with how many bricks it was.
var _dorm_wake_ms := 0.0
var _dorm_sleep_ms := 0.0
var wake_worst := [0.0, 0]
var sleep_worst := [0.0, 0]
var _work_done := 0
var _sync_meshes := 0
var dropped := 0     ## settled pieces put to the coarse stand-in for distance
var coarse_built := 0      ## coarse stand-ins built (build_chunk_coarse_mesh)
var coarse_worst_ms := 0.0 ## the slowest of them
var coarse_verts := 0      ## their vertices, all told
var stand_ins := 0         ## pieces put to sleep that left a stand-in drawn
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
var spawn_prof := {"split": 0.0, "shapes": 0.0, "mesh": 0.0, "node": 0.0, "total": 0.0,
		"deleted": 0.0}
var _multimesh := {}               ## box size -> MultiMeshInstance3D for single bricks
var _mm_members := {}              ## box size -> Array[BrickIsland]


func setup(brick_world: BrickWorld, material: ShaderMaterial, view: Camera3D) -> void:
	world = brick_world
	brick_material = material
	camera = view


## Where people are: every player in a co-op game, and later every AI agent that
## counts (Docs/AI.md section 3.5). Returns a PackedVector3Array. Dormancy and the
## debris cap ask this instead of the one camera -- a piece at the client player's
## feet must stay awake on the host, which is the machine whose physics everyone
## stands on. Unset, it is this machine's camera.
var interest := Callable()


func interest_points() -> PackedVector3Array:
	if interest.is_valid():
		return interest.call()
	if camera != null and is_instance_valid(camera):
		return PackedVector3Array([camera.global_position])
	return PackedVector3Array()


## How far a box is from the nearest interest point; INF when there are none.
func _distance_to_interest(box: AABB, points: PackedVector3Array) -> float:
	var best := INF
	for p in points:
		best = minf(best, _distance_to_box(box, p))
	return best


## Is a piece of this size a landmark -- something to hide behind or stand on --
## or presentation? See the class notes; the numbers are LANDMARK_SPAN and
## LANDMARK_VOLUME, and they are about people, not bricks.
static func is_landmark_size(size: Vector3) -> bool:
	return maxf(size.x, maxf(size.y, size.z)) >= LANDMARK_SPAN \
			or size.x * size.y * size.z >= LANDMARK_VOLUME


## Is this group, still in `source`, a landmark? Measured from the blocks' own
## boxes, which is cheap for the small groups where the answer is in doubt; a big
## group is a landmark without asking.
func group_is_landmark(source: int, block_ids: PackedInt32Array) -> bool:
	if block_ids.size() > LANDMARK_COUNT:
		return true
	if block_ids.size() <= DEBRIS_MAX_BLOCKS:
		return false
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	var any := false
	for id in block_ids:
		var ticks: Array = world.get_block_ticks(source, id)
		if ticks.is_empty():
			continue
		var a: Vector3i = ticks[0]
		var b: Vector3i = a + (ticks[1] as Vector3i)
		lo = Vector3i(mini(lo.x, a.x), mini(lo.y, a.y), mini(lo.z, a.z))
		hi = Vector3i(maxi(hi.x, b.x), maxi(hi.y, b.y), maxi(hi.z, b.z))
		any = true
	return any and is_landmark_size(Vector3(hi - lo) * tick_m)


# ---------------------------------------------------------------------------
# Recording -- every structural operation, as the command it is
# ---------------------------------------------------------------------------

## Record an operation that has just been applied. Returns the seq it was given,
## which is what a new piece's id is made from; with nothing recording, a
## negative local number, which can never collide with a host's seq.
func _record(e: DamageLog.Entry) -> int:
	e.tick = Engine.get_physics_frames()
	# A piece nothing recorded -- furniture that fell on its own (record_detach) --
	# holds no structure and exists in no replay, so what happens to it is not a
	# command either: sent, it would name a piece no machine can find. Found as
	# twelve orphan commands once the probe's tower carried real furniture.
	if e.is_piece() and e.target < 0:
		_local_seq += 1
		return -_local_seq
	if on_command.is_valid():
		var seq: Variant = on_command.call(e)
		if seq != null and int(seq) >= 0:
			return int(seq)
	_local_seq += 1
	return -_local_seq


## A command aimed at this piece, not yet filled in.
func _piece_entry(isl: BrickIsland, kind: DamageLog.Kind) -> DamageLog.Entry:
	var e := DamageLog.Entry.new()
	e.kind = kind
	e.target = isl.piece_id
	e.owner = isl.owner
	return e


func _touched(isl: BrickIsland) -> void:
	isl.changed = true
	isl.edits += 1
	piece_changed.emit(isl)


## A world point on this piece, in the grid space piece commands are written in.
func _to_grid(isl: BrickIsland, world_point: Vector3) -> Vector3:
	return DamageLog.grid_frame(world, isl.chunk) * isl.world_to_chunk(world_point)


## Record that `ids` are leaving `chunk` -- building `building`, or `source` if
## it is a piece -- and return the id the new piece will have. Called BEFORE the
## spawn that cuts them out, so the log holds the detach before anything that
## happens to the piece.
##
## Structural blocks only. Furniture is in the building's own chunk, which rooms
## a machine has open decides which furniture it has and what ids it got, and it
## weighs nothing in a solve -- so each machine carries its own along and the
## command names only what every machine agrees on. A group that is nothing but
## furniture changes no structure and is not recorded at all.
func record_detach(building: int, source: BrickIsland, chunk: int,
		ids: PackedInt32Array, flags := 0) -> int:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.DETACH
	e.flags = flags
	if source != null:
		e.target = source.piece_id
		e.owner = source.owner
		e.flags |= DamageLog.FLAG_FROM_PIECE
	else:
		e.target = building
		e.owner = building
	for id in ids:
		if world.is_block_decorative(chunk, id):
			continue
		if source == null:
			# A building's block ids are fixed by its recipe on every machine.
			e.blocks.append(id)
			continue
		# A PIECE's are not: going to sleep and waking up rebuilds it from a
		# ChunkRecord, which keeps only the living blocks and so renumbers them --
		# and each machine puts its own pieces to sleep. Its grid is what
		# survives (measured: identical local geometry, same bricks killed by the
		# same local hit), so a piece's blocks are named by a cell they fill.
		var cell := StructureReplayer.block_cell(world, chunk, id)
		if cell != StructureReplayer.NO_CELL:
			# Absolute: the cell in the building's grid, which every piece cut from
			# it keeps. See DamageLog on grid space.
			e.points.append(Vector3(world.get_chunk_origin(chunk) + cell))
	if e.blocks.is_empty() and e.points.is_empty():
		_local_seq += 1
		return DamageLog.piece_id(-_local_seq)
	var gone := _over_the_cap(chunk, ids)
	if gone:
		e.flags |= DamageLog.FLAG_GONE
	var pid := DamageLog.piece_id(_record(e))
	if gone:
		_gone_pieces[pid] = true
	return pid


## MAX_MOVING: is this group a landmark coming loose far from everybody while
## the scene is already full of moving pieces? The host's question only; its
## answer travels in the DETACH.
func _over_the_cap(chunk: int, ids: PackedInt32Array) -> bool:
	if not decides or _moving_now < MAX_MOVING:
		return false
	var points := interest_points()
	if points.is_empty():
		return false
	# Small pieces are each machine's own business (_delete_where_it_is).
	if not group_is_landmark(chunk, ids):
		return false
	return _nearest_interest(_sample_centre(chunk, ids), points) > FRACTURE_RANGE


## Is this point farther than FRACTURE_RANGE from every player? False when there
## is nobody to measure against -- a probe, a server with no players yet -- so
## everything counts as near, as it always did.
func far_from_everyone(at: Vector3) -> bool:
	var points := interest_points()
	return not points.is_empty() and _nearest_interest(at, points) > FRACTURE_RANGE


func _nearest_interest(at: Vector3, points: PackedVector3Array) -> float:
	var best := INF
	for p in points:
		best = minf(best, p.distance_to(at))
	return best


## Where a group is, from at most sixteen of its blocks. A big group asked
## block by block is thousands of calls for a position that has to be good to
## a few metres.
func _sample_centre(chunk: int, ids: PackedInt32Array) -> Vector3:
	if ids.size() <= 16:
		return _centre_of(chunk, ids)
	var some := PackedInt32Array()
	var step := float(ids.size()) / 16.0
	for k in 16:
		some.append(ids[int(k * step)])
	return _centre_of(chunk, some)


## Record that building `building` has come off its foundation whole, and
## return the id its root frame will have as a piece (frame i is id + i).
func record_topple(building: int) -> int:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.TOPPLE
	e.target = building
	e.owner = building
	return DamageLog.piece_id(_record(e))


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


## Can this machine's camera see any of this world box? Distance, then the box
## against each frustum plane: it is out of view only if some plane has all of it
## outside. No occlusion test -- a piece behind a wall counts as seen, which only
## ever keeps something a little longer, never removes one somebody is looking at.
## `planes` is the tick's cached frustum (_frustum) for the per-tick check; empty
## asks the camera now -- which a detach does, because the camera may have moved
## since the tick began.
func _box_seen(box: AABB, planes: Array[Plane] = []) -> bool:
	if camera == null or not is_instance_valid(camera):
		return true
	if _distance_to_box(box, camera.global_position) > VISIBLE_RANGE:
		return false
	if planes.is_empty():
		planes = camera.get_frustum()
	var lo := box.position
	var hi := box.end
	for plane in planes:
		# The corner deepest on the inside of this plane (Godot's frustum planes
		# face outward). If even that one is outside, all of the box is.
		var n := plane.normal
		var c := Vector3(lo.x if n.x > 0.0 else hi.x, lo.y if n.y > 0.0 else hi.y,
				lo.z if n.z > 0.0 else hi.z)
		if plane.is_point_over(c):
			return false
	return true


## A group's world box, from its blocks, while they are still in `chunk`.
func _group_box(chunk: int, block_ids: PackedInt32Array) -> AABB:
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for id in block_ids:
		var ticks: Array = world.get_block_ticks(chunk, id)
		if ticks.is_empty():
			continue
		var a := Vector3(ticks[0] as Vector3i) * tick_m
		var b := a + Vector3(ticks[1] as Vector3i) * tick_m
		lo = Vector3(minf(lo.x, a.x), minf(lo.y, a.y), minf(lo.z, a.z))
		hi = Vector3(maxf(hi.x, b.x), maxf(hi.y, b.y), maxf(hi.z, b.z))
	if lo.x == INF:
		return AABB()
	return world.get_chunk_transform(chunk) * AABB(lo, hi - lo)


## DEBRIS_UNSEEN_MS in physics ticks, at whatever rate the project runs them.
func _unseen_ticks() -> int:
	return maxi(int(DEBRIS_UNSEEN_MS * Engine.physics_ticks_per_second / 1000.0), 1)


## Start shrinking a piece of debris away (DEBRIS_FADE_MS). Idempotent.
func _start_fade(isl: BrickIsland, now: int) -> void:
	if isl.fade_since == 0:
		isl.fade_since = now
		debris_faded += 1


## One step of the shrink. True once it has gone all the way.
func _advance_fade(isl: BrickIsland, now: int) -> bool:
	var t := clampf(float(now - isl.fade_since) / float(DEBRIS_FADE_MS), 0.0, 1.0)
	isl.fade = 1.0 - t
	if isl.mesh != null:
		# About the centre of mass, which is the body's origin: the mesh node sits
		# at -local_com under it, so the offset shrinks with the scale.
		var s := maxf(isl.fade, 0.01)
		isl.mesh.transform = Transform3D(Basis().scaled(Vector3.ONE * s), -isl.local_com * s)
	return t >= 1.0


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
## `piece_id` comes from record_detach, which the caller runs first.
func spawn(source: int, block_ids: PackedInt32Array,
		inherit_linear := Vector3.ZERO, inherit_angular := Vector3.ZERO,
		piece_id := -1, owner_id := -1) -> BrickIsland:
	var _t0 := Time.get_ticks_usec()
	# The host said it goes (MAX_MOVING): cut out and let go, as every other
	# machine does with the same DETACH.
	if _gone_pieces.has(piece_id):
		_gone_pieces.erase(piece_id)
		var cut: Dictionary = world.split_island(source, block_ids)
		if not cut.is_empty():
			world.release_chunk(int(cut.chunk))
		spawn_census.capped[0] += 1
		spawn_census.capped[1] += block_ids.size()
		return null
	# Measured while the blocks are still in the source: the size decides both
	# whether it becomes a body at all and what kind of body it is.
	var landmark := group_is_landmark(source, block_ids)
	if _delete_where_it_is(source, block_ids, landmark):
		spawn_prof.deleted += float(Time.get_ticks_usec() - _t0) / 1000.0
		spawn_census.deleted[0] += 1
		spawn_census.deleted[1] += block_ids.size()
		return null
	var cls: Array = spawn_census.landmark if landmark else spawn_census.small
	cls[0] += 1
	cls[1] += block_ids.size()
	var split: Dictionary = world.split_island(source, block_ids)
	spawn_prof.split += float(Time.get_ticks_usec() - _t0) / 1000.0
	var _t := Time.get_ticks_usec()
	var _w := [0.0, float(_t - _t0) / 1000.0, 0.0, 0.0, 0.0, block_ids.size(), 0.0, 0.0, 0]
	if split.is_empty():
		return null

	var count := int(split.block_count)
	var island_chunk := int(split.chunk)

	var isl := BrickIsland.new()
	isl.chunk = island_chunk
	isl.piece_id = piece_id
	isl.owner = owner_id
	isl.local_com = split.local_com
	isl.landmark = landmark
	isl.disposable = not landmark
	isl.seen_tick = Engine.get_physics_frames()

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
	# Merged from birth when it is big: see MERGE_FALLING_BLOCKS, which also
	# says why this was once tried and reverted and what is different now.
	# Small pieces stay one box per brick -- they have few to begin with --
	# unless nobody is near enough for its landing to break it (FAR_MERGE_BLOCKS).
	var merge_now := count >= MERGE_FALLING_BLOCKS or (count >= FAR_MERGE_BLOCKS
			and not interest_points().is_empty()
			and _nearest_interest(split.com, interest_points()) > FRACTURE_RANGE)
	var built: Dictionary = world.add_chunk_shapes(
			isl.body.get_rid(), isl.chunk, isl.local_com, true, merge_now)
	isl.shape_map = built.map
	isl.shape_count = int(built.count)
	isl.merged = merge_now
	isl.fly_merged = merge_now
	spawn_prof.shapes += float(Time.get_ticks_usec() - _t) / 1000.0
	_w[2] = float(Time.get_ticks_usec() - _t) / 1000.0
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
		var _tf := Time.get_ticks_usec()
		FurnitureMesh.attach(world, isl.chunk, isl.mesh, _furniture)
		_w[6] = float(Time.get_ticks_usec() - _tf) / 1000.0

	var island_xform: Transform3D = world.get_chunk_transform(isl.chunk)
	var _ta := Time.get_ticks_usec()
	isl.body.transform = island_xform * Transform3D(Basis(), isl.local_com)

	add_child(isl.body)
	# A body that appears at a position has not MOVED there. Without this,
	# physics interpolation blends it in from wherever the previous frame
	# left off -- and for a mesh reparented into a brand-new body, from a
	# surface the renderer has not finished setting up.
	isl.body.reset_physics_interpolation()
	if isl.mesh != null:
		isl.mesh.reset_physics_interpolation()
	_w[7] = float(Time.get_ticks_usec() - _ta) / 1000.0
	_w[8] = isl.shape_count
	spawn_prof.node += float(Time.get_ticks_usec() - _t) / 1000.0
	_w[3] = float(Time.get_ticks_usec() - _t) / 1000.0
	_t = Time.get_ticks_usec()
	isl.body.set_meta("spawn_pos", isl.body.position)
	# Where it came from: once it starts to move, what rested on it there is
	# woken (support_gone). A chunk a mega collapse held and then let go is the
	# case this is for.
	isl.ripple_box = world_aabb(isl)
	isl.ripple_pending = true
	isl.body.linear_velocity = inherit_linear
	isl.body.angular_velocity = inherit_angular
	isl.born_ms = Time.get_ticks_msec()
	isl.prev_speed = inherit_linear.length()
	# Single bricks never reach rebuild_mesh, so the bound is set here too.
	isl.radius = _body_radius(isl)
	islands.append(isl)
	_moving_now += 1
	# No wake_near here. It is O(every island) and spawn is called once per
	# piece shed -- 4,400 times in a heavy collapse, which made it O(n^2).
	# _shed already wakes the region around the parent, which is the same
	# region every child of that parent occupies.
	if isl.mesh != null:
		# Far off: the coarse stand-in, which needs no bake (ISLAND_MESH_RANGE).
		isl.coarse = _starts_coarse(isl)
		if count <= SYNC_MESH_MAX_BLOCKS and _sync_meshes < SYNC_MESH_PER_TICK \
				and (isl.coarse or world.get_chunk_authored_tris(isl.chunk) <= SYNC_MESH_MAX_TRIS):
			# Small enough to bake here and now, so it is never invisible.
			_sync_meshes += 1
			rebuild_mesh(isl, true, true)
		else:
			# A big section goes to a worker; it is queued and appears a tick or
			# two later, which is far cheaper than baking it on this thread. A
			# stand-in is built when the queue reaches it, in its budget.
			if not isl.coarse:
				world.bake_chunk_async(isl.chunk)
			_mesh_queue.append(isl)
	spawn_prof.mesh += float(Time.get_ticks_usec() - _t) / 1000.0
	spawn_prof.total += float(Time.get_ticks_usec() - _t0) / 1000.0
	_w[4] = float(Time.get_ticks_usec() - _t) / 1000.0
	_w[0] = float(Time.get_ticks_usec() - _t0) / 1000.0
	if float(_w[0]) > float(spawn_worst[0]):
		spawn_worst = _w
	piece_spawned.emit(isl)
	return isl


## Should this piece never become a body at all? Decided BEFORE anything is
## built for it: no body, no shapes, no mesh.
##
## Three rules:
##   * **a landmark** is never deleted. It is structure somebody may hide behind
##     or stand on, and every machine has it (see the class notes).
##   * **a small piece** breaks off only within SMALL_KEEP_RANGE and in view. A
##     brick or two falling in the distance is a body the physics pays for and
##     nobody could see -- and a big collapse sheds hundreds of them.
##   * **nothing but furniture** breaks off only within FURNITURE_FALL_RANGE: a
##     chair whose floor went was a lone untextured cube in mid-air, then small
##     debris deleted anyway at the bottom of the fall.
## The camera is this machine's: small pieces are its own presentation.
func _delete_where_it_is(source: int, block_ids: PackedInt32Array, landmark: bool) -> bool:
	var n := block_ids.size()
	if n == 0:
		return false
	var furniture := true
	for id in block_ids:
		if not world.is_block_decorative(source, id):
			furniture = false
			break
	if landmark and not furniture:
		return false
	# Its BOX, not its centre: a floor panel whose middle is just off screen is
	# still mostly on it, and deleting that is a slab of floor vanishing in view.
	var box := _group_box(source, block_ids)
	var dist := INF
	if camera != null and is_instance_valid(camera):
		dist = _distance_to_box(box, camera.global_position)
	var gone := false
	if furniture:
		gone = dist > FURNITURE_FALL_RANGE and dist < INF
	var far := dist > SMALL_KEEP_RANGE and dist < INF
	if not furniture:
		gone = far or not _box_seen(box)
	if not gone:
		return false
	# Split out and freed, NOT killed in place. Killing is the obvious saving --
	# no chunk, no copy -- and it measured worse: a piece that loses blocks to
	# kills keeps them as dead blocks and never went to sleep. On the stress
	# pass that left 2,400-5,000 collision boxes still falling at the end and
	# physics at 13-15 ms a frame; split and freed, 0-900 and 9 ms.
	var cut: Dictionary = world.split_island(source, block_ids)
	if not cut.is_empty():
		world.release_chunk(int(cut.chunk))
	if furniture:
		furniture_deleted += n
	elif far:
		tiny_deleted += n
	else:
		discarded += n
	return true


## Where a group of blocks is in the world, from their boxes. Only ever asked of
## small groups, so the walk is a handful of blocks.
func _centre_of(chunk: int, block_ids: PackedInt32Array) -> Vector3:
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var sum := Vector3.ZERO
	var n := 0
	for id in block_ids:
		var ticks: Array = world.get_block_ticks(chunk, id)
		if ticks.is_empty():
			continue
		sum += (Vector3(ticks[0] as Vector3i) + Vector3(ticks[1] as Vector3i) * 0.5) * tick_m
		n += 1
	return world.get_chunk_transform(chunk) * (sum / maxf(n, 1))


## Swap a piece's collision between one box per brick and as few boxes as the
## shape allows.
##
## Merged is for pieces that have stopped moving: a settled island is inert
## scenery, and one box per brick across hundreds of them is what a collapse
## makes the physics solver pay for. The merged boxes ignore block identity, so
## nothing can be disabled on its own -- which is fine until the piece is hit,
## at which point this runs the other way first.
func _reshape(isl: BrickIsland, merged: bool, force := false) -> void:
	if not isl.is_valid() or (isl.merged == merged and not force):
		return
	var _t0 := Time.get_ticks_usec()
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
	var _t1 := Time.get_ticks_usec()
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, space)
	var _t2 := Time.get_ticks_usec()
	if float(_t2 - _t0) / 1000.0 > float(reshape_worst[0]):
		reshape_worst = [float(_t2 - _t0) / 1000.0, world.get_alive_block_count(isl.chunk),
				isl.shape_count, float(_t1 - _t0) / 1000.0, float(_t2 - _t1) / 1000.0]
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
##
## Unless it is FALLING merged: then it is rebuilt merged once, at the end of the
## tick, from whatever its blocks are by then -- one shape build instead of the
## per-block rebuild this used to force at every landing, which on a toppled
## building was the 285 ms tick.
func _ensure_per_block(isl: BrickIsland) -> void:
	if isl.merged and isl.fly_merged and not isl.settled:
		if not isl.reshape_due:
			isl.reshape_due = true
			_reshape_list.append(isl)
		return
	if isl.merged:
		_reshape(isl, false)


## Rebuild, merged, every falling piece whose blocks changed this tick.
func _flush_reshapes() -> void:
	for isl in _reshape_list:
		if not isl.is_valid() or not isl.reshape_due:
			continue
		isl.reshape_due = false
		if isl.settled:
			continue  # settling already rebuilt it
		_reshape(isl, true, true)
		merged_rebuilds += 1
	_reshape_list.clear()


## Is anybody close enough to a landing for it to break the piece that landed?
## With nobody to measure against -- a probe, a server with no players yet --
## everything matters, as it always did.
func _landing_matters(isl: BrickIsland) -> bool:
	var points := interest_points()
	if points.is_empty():
		return true
	return _distance_to_interest(world_aabb(isl), points) <= FRACTURE_RANGE


## What this piece collides with, given how big it is and what it is doing.
##
## Three states, and the distinction is what makes a collapse affordable:
##
##   * **rubble** -- a small piece, not a landmark. Lands on the ground, on buildings
##     and on settled wreckage; passes through anything still falling, and
##     through other rubble. A handful of loose bricks deflecting a falling
##     tower is neither believable nor cheap, and rubble-against-rubble is the
##     quadratic term in the pair count.
##   * **falling** -- a large section in motion. Everything except rubble.
##   * **settled** -- come to rest. Everything, rubble included, because now it
##     is scenery that things land on.
## Treat a piece as debris rather than as structure: rubble layers, and the
## debris rules -- kept while it can be seen, gone once it cannot.
##
## What a FIXTURE becomes the moment it comes loose. A staircase is not
## structure (Docs/BuildMode.md section 9.2), and once it is falling it should
## not cost what a falling section of building costs -- measured, that
## difference was 103 islands against 27 in the same collapse.
func make_debris(isl: BrickIsland) -> void:
	if isl == null or not isl.is_valid():
		return
	isl.disposable = true
	isl.landmark = false
	isl.seen_tick = Engine.get_physics_frames()
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
		carried_bytes: int, carried_width: int, carried_bands: Array = [],
		piece_id := -1, owner_id := -1, announce := true, is_landmark := true,
		carried_band_bytes: Array = []) -> BrickIsland:
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return null
	world.set_chunk_anchored(chunk, false)

	var isl := BrickIsland.new()
	isl.chunk = chunk
	isl.piece_id = piece_id
	isl.owner = owner_id
	isl.local_com = world.get_chunk_com(chunk)
	# A toppled building or a piece back from sleep: a landmark unless told
	# otherwise (only a loaded save's small pieces are).
	isl.landmark = is_landmark
	isl.disposable = not is_landmark
	# Counted as just seen: a piece back from a save or from sleep has not been
	# looked for yet, and seen_tick 0 would sweep it on the first tick.
	isl.seen_tick = Engine.get_physics_frames()

	isl.band_bytes = carried_band_bytes
	isl.body = RigidBody3D.new()
	isl.body.mass = maxf(world.get_chunk_mass(chunk) * MASS_SCALE, 0.5)
	isl.body.contact_monitor = true
	isl.body.max_contacts_reported = MAX_CONTACTS
	isl.body.gravity_scale = DEBRIS_GRAVITY
	_apply_layers(isl)

	# Shapes before the body joins a space, as always. Merged: a whole building
	# coming down is the biggest piece there is (MERGE_FALLING_BLOCKS).
	var merge_now := world.get_alive_block_count(chunk) >= MERGE_FALLING_BLOCKS
	var built: Dictionary = world.add_chunk_shapes(
			isl.body.get_rid(), chunk, isl.local_com, true, merge_now)
	isl.shape_map = built.map
	isl.shape_count = int(built.count)
	isl.merged = merge_now
	isl.fly_merged = merge_now

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
		# The bands too. They hang off the building's node, which goes as a
		# ghost just below and takes its children with it: a toppled building
		# drew nothing from two frames into its fall until something happened
		# to rebuild it. New instances of the same band meshes, as `fresh` is.
		isl.bands = _instance_bands(carried_bands, fresh)
		# A building that toppled halfway through rebuilding its bands comes down
		# with holes in it, and nothing rebuilt it until something changed it --
		# which a landing nobody is near never does (FRACTURE_RANGE). One piece
		# of 18,588 bricks was partly invisible for 422 ticks. The missing bands
		# are built one a tick (_fill_band_holes), slices of the bake it already
		# has; the bands it has draw, and take patches, meanwhile.
		if not isl.bands.is_empty() and not _draws_bands(isl):
			_band_holes.append(isl)
		if mesh_node.get_parent() != null:
			_ghosts.append([mesh_node, Engine.get_process_frames() + OVERLAP_FRAMES])
		else:
			mesh_node.queue_free()
	else:
		# Nothing carried: a piece back from sleep or from a save. It still needs
		# a node to be drawn into, or rebuild_mesh and the mesh queue have nowhere
		# to put what they build and the piece is solid but invisible. The same
		# node spawn makes.
		isl.mesh = MeshInstance3D.new()
		isl.mesh.material_override = brick_material
		isl.mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		isl.mesh.position = -isl.local_com
		isl.body.add_child(isl.mesh)
		FurnitureMesh.attach(world, chunk, isl.mesh, _furniture)

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
	# A building that toppled whole: once it moves, what had settled on it is
	# woken (support_gone).
	isl.ripple_box = world_aabb(isl)
	isl.ripple_pending = true
	islands.append(isl)
	# Not while a save is being put back: what lies next to this piece is
	# exactly as the save had it, asleep or not, and waking it is a difference.
	if not _restoring:
		wake_near(isl.body.global_position, WAKE_RADIUS)
	if announce:
		piece_spawned.emit(isl)
	return isl


## A piece's own instances of a building's band meshes, in the same slots. An
## instance of an ArrayMesh copies nothing. A slot the building never got to
## (it toppled halfway through rebuilding its bands) stays empty -- a hole
## _draws_bands knows about -- and a band built empty stays built and empty.
func _instance_bands(bands: Array, parent: MeshInstance3D) -> Array:
	var out: Array = []
	for node in bands:
		if not is_instance_valid(node):
			out.append(null)
			continue
		var src := node as MeshInstance3D
		var copy := MeshInstance3D.new()
		copy.mesh = src.mesh
		copy.material_override = src.material_override
		copy.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		copy.transform = src.transform
		parent.add_child(copy)
		out.append(copy)
	return out


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
	# No arrays at all: a chunk that baked to nothing -- nothing alive, or only
	# furniture, which is drawn apart from the faces. A piece of furniture put
	# to sleep and woken again built exactly that, and this read the vertex
	# array of nothing.
	if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
		return 4
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
	# Blocks ADDED to a piece -- a room's contents spilling into it. Not a
	# command: it is furniture, and each machine carries its own (record_detach).
	_touched(isl)
	if isl.fly_merged and not isl.settled:
		_reshape(isl, true, true)
	else:
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
	# Its mesh is being built on a worker. Whatever this call wanted is done
	# when that lands (_harvest_mesh_jobs), against the mesh it builds.
	if isl.mesh_job != -1 or isl.upload_waiting:
		isl.mesh_again = true
		isl.mesh_again_full = isl.mesh_again_full or force_full
		return
	# Band meshes carried down from a building that toppled whole: patched in
	# place, the band a blast landed in and no other. Dropping them for one mesh
	# here was a full build of the whole piece -- 10-22 ms for a toppled
	# section of 7,000-8,600 bricks -- inside the blast that hit it, once per
	# piece the blast reached. Held like any other update while a child it
	# shed is coming up (OVERLAP_FRAMES).
	if not isl.bands.is_empty() and not force_full and _any_band(isl):
		if isl.hold_until > Engine.get_process_frames():
			if not _held.has(isl):
				_held.append(isl)
			return
		if _patch_bands(isl):
			return
	# Something a patch cannot carry: drop the bands and build the one mesh an
	# island uses.
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
	# Far off: the stand-in, built again whatever changed. It is never patched
	# (its index buffer is not the bake's) and needs no bake. Built from the
	# mesh queue, in its budget, unless the caller is that queue or has to
	# have it now: a far piece being shot at would otherwise build it again
	# for every hit -- 1-3 ms each for a big one, where a patch was nothing.
	if isl.coarse:
		var fresh := isl.coarse_drawn \
				and Engine.get_physics_frames() - isl.coarse_tick < COARSE_REBUILD_TICKS
		if force_full and not fresh:
			_build_coarse(isl)
		elif not _mesh_queue.has(isl):
			_mesh_queue.append(isl)
		return
	if isl.array_mesh != null and isl.array_mesh.get_surface_count() > 0 and not force_full \
			and not isl.coarse_drawn:
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
	var ok := not arrays.is_empty() and mesh_arrays_ok(arrays, "island %d" % isl.chunk)
	if ok and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() >= THREAD_MESH_VERTS:
		# Big: uploaded on a worker, attached when it is done. The mesh it
		# replaces goes on drawing until then.
		if not _upload_ok((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()):
			isl.upload_waiting = true
			_upload_waiting.append([isl, arrays, false])
			uploads_waited += 1
			return
		_submit_mesh_job(isl, arrays)
		return
	var mesh := ArrayMesh.new()
	if ok:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_apply_mesh(isl, mesh, arrays)


## Far enough off to come up as the coarse stand-in (ISLAND_MESH_RANGE). A
## piece carrying a building's bands keeps them.
func _starts_coarse(isl: BrickIsland) -> bool:
	if camera == null or not isl.bands.is_empty() or not isl.body.is_inside_tree():
		return false
	return isl.body.global_position.distance_to(camera.global_position) > ISLAND_MESH_RANGE


## Build a far piece's coarse stand-in and hang it. From the grid, on this
## thread: there is no bake to wait for, and a stand-in is a few percent of
## the bricks' vertices. A big one is uploaded on a worker like any other mesh.
func _build_coarse(isl: BrickIsland) -> void:
	var arrays: Array = world.build_chunk_coarse_mesh(isl.chunk)
	isl.coarse_tick = Engine.get_physics_frames()
	coarse_built += 1
	coarse_worst_ms = maxf(coarse_worst_ms, world.get_last_coarse_ms())
	var ok := not arrays.is_empty() and mesh_arrays_ok(arrays, "island %d (coarse)" % isl.chunk)
	if ok:
		var verts := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		coarse_verts += verts
		if verts >= THREAD_MESH_VERTS:
			if not _upload_ok(verts):
				isl.upload_waiting = true
				_upload_waiting.append([isl, arrays, true])
				uploads_waited += 1
				return
			_submit_mesh_job(isl, arrays, true)
			return
	var mesh := ArrayMesh.new()
	if ok:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_apply_mesh(isl, mesh, arrays, true)


## Hang a finished mesh on a piece. `coarse`: it is the stand-in.
func _apply_mesh(isl: BrickIsland, mesh: ArrayMesh, arrays: Array, coarse := false) -> void:
	# Only a mesh that actually HAS a surface can be patched. A chunk with
	# nothing left alive produces no arrays, and patching surface 0 of an empty
	# ArrayMesh writes past the end of a buffer that is not there.
	isl.radius = _body_radius(isl)
	# The renderer may still be drawing the mesh this replaces.
	_retirer.retire(isl.mesh.mesh)
	isl.array_mesh = mesh if mesh != null and mesh.get_surface_count() > 0 else null
	isl.coarse_drawn = coarse
	# A stand-in has nothing to patch: 0 bytes is a patch that never fits.
	isl.index_bytes = index_patch_bytes(arrays) if isl.array_mesh != null and not coarse else 0
	isl.index_width = index_width(arrays)
	isl.mesh.mesh = mesh


## Room in this tick's upload budget for `verts` more (UPLOAD_VERTS_PER_TICK),
## taken if there is.
func _upload_ok(verts: int) -> bool:
	var now_tick := Engine.get_physics_frames()
	if now_tick != _upload_tick:
		_upload_tick = now_tick
		_upload_used = 0
	if _upload_used > 0 and _upload_used + verts > UPLOAD_VERTS_PER_TICK:
		return false
	_upload_used += verts
	return true


## Send what waited for the budget, oldest first, as far as this tick's goes.
func _drain_upload_waiting() -> void:
	while not _upload_waiting.is_empty():
		var entry: Array = _upload_waiting[0]
		var isl: BrickIsland = entry[0]
		if not isl.is_valid() or isl.mesh == null:
			_upload_waiting.pop_front()
			continue
		var arrays: Array = entry[1]
		if not _upload_ok((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()):
			return
		_upload_waiting.pop_front()
		isl.upload_waiting = false
		_submit_mesh_job(isl, arrays, bool(entry[2]))


## Upload `arrays` for `isl` on a worker (THREAD_MESH_VERTS). The arrays were
## built on this thread from the bake; the worker only turns them into a mesh.
##
## Not started here: at the end of the tick (start_mesh_jobs). A worker that
## finishes mid-tick has its buffers made by whatever next calls into the
## renderer in that same tick -- the loose bricks' MultiMesh at 24 ms, a
## 3-brick spawn's node at 7 -- where one started after the tick finishes
## during the frame, and is paid by the frame or by the flush at the top of
## the next tick.
func _submit_mesh_job(isl: BrickIsland, arrays: Array, coarse := false) -> void:
	var holder := [null]
	var work := func() -> void:
		var m := ArrayMesh.new()
		# Compressed (UPLOAD_COMPRESS), on the worker where it costs nothing
		# anyone waits for.
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				UPLOAD_COMPRESS)
		holder[0] = m
	isl.mesh_job = JOB_NOT_STARTED
	_mesh_jobs.append([isl, JOB_NOT_STARTED, holder, arrays, work, coarse])


## Start the mesh jobs submitted this tick. The tick's own last act, or the
## scene's (defer_job_start) when it has more to do after this manager's tick.
func start_mesh_jobs() -> void:
	for job in _mesh_jobs:
		if int(job[1]) != JOB_NOT_STARTED:
			continue
		var task := WorkerThreadPool.add_task(job[4] as Callable, true, "island mesh")
		job[1] = task
		var isl: BrickIsland = job[0]
		if isl.is_valid():
			isl.mesh_job = task


## Every mesh job finished before the manager goes: a worker still building a
## mesh while the renderer shuts down is a crash on quit.
func _exit_tree() -> void:
	for job in _mesh_jobs:
		if int(job[1]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(job[1]))
		(job[2] as Array)[0] = null
	_mesh_jobs.clear()
	_upload_waiting.clear()


## Attach the meshes the workers have finished, and do what was asked of those
## pieces while they were being built.
func _harvest_mesh_jobs() -> void:
	var k := 0
	while k < _mesh_jobs.size():
		var job: Array = _mesh_jobs[k]
		var task: int = job[1]
		if task < 0 or not WorkerThreadPool.is_task_completed(task):
			k += 1
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		_mesh_jobs.remove_at(k)
		var isl: BrickIsland = job[0]
		isl.mesh_job = -1
		if not isl.is_valid() or isl.mesh == null:
			continue
		_apply_mesh(isl, job[2][0], job[3], bool(job[5]))
		mesh_jobs_done += 1
		if isl.mesh_again:
			var full := isl.mesh_again_full
			isl.mesh_again = false
			isl.mesh_again_full = false
			rebuild_mesh(isl, full)


## Re-index a banded piece and upload only the bands whose bytes moved --
## CityScene._remesh's patch, for a building that has come down whole. A band
## not built yet is skipped: it is built later from the bake as it is by then
## (_fill_band_holes). False when it cannot: the bake is gone, the sections no
## longer match, a band was built empty, or a band's buffer is not the length it
## was built at. A band patched before the one that failed is harmless -- the
## full rebuild that follows replaces them all.
func _patch_bands(isl: BrickIsland) -> bool:
	if isl.band_bytes.size() != isl.bands.size() or not world.bake_ready(isl.chunk) \
			or world.get_chunk_sections(isl.chunk) != isl.bands.size():
		return false
	var moved: Array = world.update_index_regions(isl.chunk, isl.index_width)
	for entry in moved:
		var d: Dictionary = entry
		var si := int(d.section)
		if si < 0 or si >= isl.bands.size():
			return false
		if not is_instance_valid(isl.bands[si]):
			continue   # a hole: it will be built from the bake as it now is
		# A band that was empty cannot take a patch; the rebuild can.
		var band: ArrayMesh = (isl.bands[si] as MeshInstance3D).mesh as ArrayMesh
		if band == null or band.get_surface_count() == 0 \
				or int(d.offset) + int(d.changed_bytes) > int(isl.band_bytes[si]):
			return false
		RenderingServer.mesh_surface_update_index_region(band.get_rid(), 0,
				int(d.offset), d.data)
	return true


# ---------------------------------------------------------------------------
# Waking
# ---------------------------------------------------------------------------

## A frozen body never re-evaluates, so one that is shot -- or that has just lost
## the piece it was resting on -- hangs exactly where it stopped. That is where
## floating wreckage comes from.
func wake(isl: BrickIsland) -> void:
	if not isl.is_valid() or not isl.settled:
		return
	isl.ripple_box = world_aabb(isl)
	isl.ripple_pending = true
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


## Something that may have been holding pieces up is gone from this world box.
## The settled pieces resting on it or wedged against it are woken next tick
## (RIPPLES_PER_TICK boxes a tick). See RIPPLE_MARGIN.
func support_gone(box: AABB) -> void:
	if box.size == Vector3.ZERO:
		return
	_ripples.append(box)


func _drain_ripples() -> void:
	var n := 0
	while n < RIPPLES_PER_TICK and not _ripples.is_empty():
		_wake_resting_on(_ripples.pop_front())
		n += 1


## Wake the settled pieces that could have been resting on what was in `box`:
## touching it, and not wholly below it -- what is under a thing is holding it
## up, not held by it. Dormant records the same, marked to come back free to fall.
func _wake_resting_on(box: AABB) -> void:
	var grown := box.grow(RIPPLE_MARGIN)
	var centre := grown.get_center()
	var reach := grown.size.length() * 0.5
	for other in islands:
		if not other.is_valid() or not other.settled:
			continue
		if other.body.global_position.distance_to(centre) > other.radius + reach:
			continue
		var ob := world_aabb(other)
		if not ob.intersects(grown) or ob.position.y < box.position.y - RIPPLE_MARGIN:
			continue
		wake(other)
		ripple_woken += 1
	for d in dormant:
		var rb: AABB = d.record.box
		if rb.intersects(grown) and rb.position.y >= box.position.y - RIPPLE_MARGIN:
			d.unsure = true


## Is there anything under this piece -- ground, a building, another piece --
## within SUPPORT_REACH of its underside? Nine rays down from its world box's
## floor: the corners, the middle, and halfway between. Any hit is support; a
## piece leaning on its edge is found by the ray nearest that edge.
func _supported_below(isl: BrickIsland) -> bool:
	if not isl.is_valid() or not isl.body.is_inside_tree():
		return true
	var box := world_aabb(isl)
	if box.size == Vector3.ZERO:
		return true
	var space := isl.body.get_world_3d().direct_space_state
	var y := box.position.y + 0.1
	var skip: Array[RID] = [isl.body.get_rid()]
	for fx in [0.02, 0.5, 0.98]:
		for fz in [0.02, 0.5, 0.98]:
			var at := Vector3(box.position.x + box.size.x * fx, y,
					box.position.z + box.size.z * fz)
			var q := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * (SUPPORT_REACH + 0.1),
					isl.body.collision_mask, skip)
			if not space.intersect_ray(q).is_empty():
				return true
	return false


## Is any other body within TOUCH_MARGIN of this piece's world box? One box
## query. The box is axis-aligned round a piece that may be turned, so this
## errs towards "touching" -- which only ever lets a wedged piece settle, never
## freezes a floating one.
func _touching_anything(isl: BrickIsland) -> bool:
	if not isl.is_valid() or not isl.body.is_inside_tree():
		return true
	var box := world_aabb(isl)
	if box.size == Vector3.ZERO:
		return true
	box = box.grow(TOUCH_MARGIN)
	_touch_shape.size = box.size
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _touch_shape
	q.transform = Transform3D(Basis(), box.get_center())
	q.collision_mask = isl.body.collision_mask | Layers.WORLD | Layers.STRUCTURE
	q.exclude = [isl.body.get_rid()]
	return not isl.body.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## The watchdog (AUDIT_PER_TICK): a few settled pieces a tick, round-robin.
## Nothing under it and nothing touching it: it is not resting on anything, so
## it is woken -- and falls, and settles again wherever it lands.
func _audit_settled() -> void:
	var n := islands.size()
	if n == 0 or not audit_enabled:
		return
	var asked := 0
	var looked := 0
	while asked < AUDIT_PER_TICK and looked < n:
		_audit_at = (_audit_at + 1) % n
		looked += 1
		var isl := islands[_audit_at]
		if not isl.is_valid() or not isl.settled:
			continue
		asked += 1
		if not _supported_below(isl) and not _touching_anything(isl):
			wake(isl)
			audit_woken += 1


## Keep a piece from settling for `ms`: something outside physics -- wind -- is
## holding it up or pushing it, and slow in the wind is not at rest. Wakes it if
## it has settled already. See BrickIsland.hold_until_ms.
func hold_awake(isl: BrickIsland, ms: int) -> void:
	if not isl.is_valid():
		return
	isl.hold_until_ms = maxi(isl.hold_until_ms, Time.get_ticks_msec() + ms)
	if isl.settled:
		wake(isl)


## Freeze a piece where it is: what the tick does to one that has stayed slow
## long enough (SETTLE_SLOW_MS), and what a probe does to put one there.
func settle_now(isl: BrickIsland) -> void:
	if not isl.is_valid() or isl.settled:
		return
	isl.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	isl.body.freeze = true
	isl.settled = true
	isl.ripple_pending = false
	isl.settled_ms = Time.get_ticks_msec()
	isl.settled_blocks = world.get_alive_block_count(isl.chunk)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	_apply_layers(isl)
	# Inert now: give the solver as few boxes as the shape allows.
	_reshape(isl, true)
	settled += 1
	# Where a landmark came to rest is the one piece of physics every
	# machine has to agree on (DamageLog.Kind.PIECE_REST). Small pieces are
	# presentation and are not sent.
	if isl.landmark and isl.piece_id >= 0 and decides:
		var rest := _piece_entry(isl, DamageLog.Kind.PIECE_REST)
		rest.points = DamageLog.rest_points(isl.chunk_transform())
		_record(rest)
	piece_settled.emit(isl)


## Wake the settled pieces this one is touching that have nothing under them. A
## falling piece that lands on, or comes to rest on, a frozen floater: it falls
## under the load now instead of holding the load up in mid-air.
func _wake_touched(isl: BrickIsland) -> void:
	for c in _contact_points(isl):
		var rid: RID = (c as Dictionary).collider
		if not rid.is_valid():
			continue
		for other in islands:
			if other.settled and other.is_valid() and other.body.get_rid() == rid:
				# Only a floater: a piece in a pile that has something under it
				# is holding the new one up, and waking it was the whole pile
				# jostling at every landing -- a third more pieces moving.
				if not _supported_below(other):
					wake(other)
					touch_woken += 1
				break


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
	# Something landed on it: this machine's physics. The host's to decide.
	if not decides:
		return
	# Nobody near: it takes the landing without coming apart. FRACTURE_RANGE.
	if not _landing_matters(isl):
		far_shears += 1
		return
	wake(isl)
	wake_near(world_point, WAKE_RADIUS)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	_ensure_per_block(isl)
	var e := _piece_entry(isl, DamageLog.Kind.PIECE_SHEAR)
	e.point = _to_grid(isl, world_point)
	e.radius = radius
	e.limit = SHEAR_MAX_BLOCKS
	var loosened := DamageLog.apply_entry(world, isl.chunk, e)
	if loosened.is_empty():
		return
	_record(e)
	impact_blocks += loosened.size()
	_touched(isl)
	# Queued, not resolved here. Working out what the landing broke off means a
	# stress solve, a connectivity walk and cutting the pieces out, and on a
	# 2,000-brick tower that is hundreds of milliseconds in one indivisible
	# call -- which no per-tick clock can interrupt. The landing records the
	# damage; _drain_resolve_queue deals with the consequences on its own share.
	if not _resolve_queue.has(isl):
		_resolve_queue.append(isl)


## `chip` > 0 wears bricks by that much hp instead of destroying them
## (DamageLog.Kind.PIECE_CHIP, StructuralDamage).
func damage(isl: BrickIsland, world_point: Vector3, radius: float, chip := 0) -> void:
	if not isl.is_valid():
		return
	# The scene only calls this on the host -- a client's shot is a request --
	# but the rule belongs here as well as there.
	if not decides:
		return
	wake(isl)
	wake_near(world_point, WAKE_RADIUS)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	_ensure_per_block(isl)
	var e := _piece_entry(isl,
			DamageLog.Kind.PIECE_CHIP if chip > 0 else DamageLog.Kind.PIECE_BLAST)
	e.point = _to_grid(isl, world_point)
	e.radius = radius
	e.limit = chip
	var killed := DamageLog.apply_entry(world, isl.chunk, e)
	# A chip that killed nothing still took hp, and hp is state.
	if chip > 0:
		_record(e)
	if killed.is_empty():
		return
	if chip <= 0:
		_record(e)
	isl.disable_blocks(killed)
	_touched(isl)
	# Rubble is not re-solved. Cutting a disposable piece into smaller
	# disposable pieces costs a stress solve, a connectivity walk and a chunk
	# per group, to produce more of what is already being swept up in two and a
	# half seconds.
	if not isl.disposable:
		solve_island(isl)
	rebuild_mesh(isl)


## Damage every loose piece whose volume reaches the blast, not every piece
## whose origin happens to sit near it. Returns how many were hit.
func damage_near(point: Vector3, radius: float, chip := 0) -> int:
	var hit := 0
	# A bullet has no radius but still has to find the piece it struck.
	var reach := maxf(radius, 0.25) if chip > 0 else radius
	# What is asleep is still there to be hit.
	wake_dormant_near(point, reach)
	# Walk by index up to the count we started with: damaging a piece can
	# append new ones, and copying the list per call is itself O(islands).
	var n := islands.size()
	for i in n:
		var isl: BrickIsland = islands[i] if i < islands.size() else null
		if isl == null:
			continue
		if not isl.is_valid():
			continue
		if isl.body.global_position.distance_to(point) > isl.radius + reach:
			continue
		if world_aabb(isl).grow(reach).has_point(point):
			damage(isl, point, radius, chip)
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
	var _tu := Time.get_ticks_usec()
	_ensure_per_block(isl)
	_upart("shed: per block", _tu)
	var shed := 0
	var more := false
	for g in groups:
		if shed >= SHEDS_PER_PASS:
			more = true
			break
		var moved: PackedInt32Array = g
		if moved.is_empty():
			continue
		spawn_census.shed[0] += 1
		spawn_census.shed[1] += moved.size()
		var child := record_detach(isl.owner, isl, isl.chunk, moved)
		var _ts := Time.get_ticks_usec()
		if spawn(isl.chunk, moved, linear, angular, child, isl.owner) == null:
			# Deleted where it was, or dropped over the moving cap: gone, and
			# anything resting on it with it.
			support_gone(isl.chunk_transform() * world.get_blocks_box(isl.chunk, moved))
		_upart("shed: spawns", _ts)
		# Start a hold; never EXTEND one. A piece shedding on consecutive ticks
		# would otherwise push its own deadline forward every tick and never
		# rebuild at all, so its mesh would keep drawing bricks that had left
		# for as long as the cascade ran. Capped this way the mesh is stale for
		# OVERLAP_FRAMES at a time and no longer.
		if isl.hold_until <= Engine.get_process_frames():
			isl.hold_until = Engine.get_process_frames() + OVERLAP_FRAMES
		_touched(isl)
		# Whether or not spawn() kept the piece, those blocks are out of this
		# body. A discarded one is deleted, not left behind as ghost collision.
		isl.disable_blocks(moved, RID())
		shed += 1
	var _tb := Time.get_ticks_usec()
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, space)
	_upart("shed: body back", _tb)
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
	# Which way is down for a tumbled piece is this machine's physics. The host
	# decides, and a client gets the answer as a PIECE_SOLVE with the gravity in.
	if not decides:
		return
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	var down: Vector3 = isl.body.global_transform.basis.inverse() * Vector3.DOWN
	# Scaled to integers so the extension can see which component dominates.
	var e := _piece_entry(isl, DamageLog.Kind.PIECE_SOLVE)
	e.normal = Vector3(roundi(down.x * 100.0), roundi(down.y * 100.0), roundi(down.z * 100.0))
	var _tu := Time.get_ticks_usec()
	var res := DamageLog.apply_entry(world, isl.chunk, e)
	_tu = _upart("stress", _tu)
	# A solve that failed nothing changed nothing, so there is nothing to send.
	# What comes loose afterwards travels as DETACH, with its blocks named.
	if not res.is_empty() and res[0] > 0:
		_record(e)
	# Tension failure marks joints, it does not move bricks. What comes loose is
	# whatever can no longer trace a path to the ground.
	var groups := world.find_detached_groups(isl.chunk)
	_tu = _upart("groups", _tu)
	_shed(isl, groups)
	_tu = _upart("shed", _tu)
	split_if_broken(isl)
	_upart("split", _tu)


## A hard landing SHEARS the joints in the contact band. It destroys nothing --
## a brick that hits the ground comes loose, it does not cease to exist
## (Docs/BrickFailure.md).
## Landings already decided (Docs/AI.md 3.11, AIPlan R9): a floor a mech came
## down on falls with it, and the mech's fall rule -- not the plate landing first
## -- decides what the next floor does. Pieces landing within `radius` of `point`
## in the next `seconds` break nothing. [point, radius, until (physics tick)]
var _quiet: Array = []


func quiet_landings(point: Vector3, radius: float, seconds: float) -> void:
	_quiet.append([point, radius,
			Engine.get_physics_frames() + int(seconds * Engine.physics_ticks_per_second)])


func _is_quiet(isl: BrickIsland) -> bool:
	if _quiet.is_empty():
		return false
	var now := Engine.get_physics_frames()
	var c := world_aabb(isl).get_center()
	var keep: Array = []
	var quiet := false
	for q in _quiet:
		if int(q[2]) < now:
			continue
		keep.append(q)
		var p: Vector3 = q[0]
		if Vector2(c.x - p.x, c.z - p.z).length() <= float(q[1]):
			quiet = true
	_quiet = keep
	return quiet


func fracture_on_impact(isl: BrickIsland, severity: float) -> void:
	if _island_aabb(isl).size == Vector3.ZERO:
		return
	# A landing is this machine's physics. Only the host's landings break
	# anything; a client gets the breaks as PIECE_SHEAR and PIECE_SNAP.
	if not decides:
		return
	var radius := clampf(IMPACT_RADIUS * severity * 0.08, IMPACT_RADIUS, IMPACT_RADIUS_MAX)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())

	# Nobody near enough to see it break: it lands whole (FRACTURE_RANGE). What
	# it landed on still takes the hit, below.
	var near := _landing_matters(isl)
	# Where it actually touched. The solver already knows; asking it beats
	# guessing from a bounding box, which for a toppled building meant shearing
	# a band up the side rather than across the face that landed.
	var _tu := Time.get_ticks_usec()
	if near:
		_ensure_per_block(isl)
	_tu = _upart("land: per block", _tu)
	var contacts := _contact_points(isl)
	# What it landed on, if that is a settled piece, is woken: a floater falls
	# under the load instead of holding it up (see RIPPLE_MARGIN).
	_wake_touched(isl)
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
	# World to grid space, the space piece commands are written in.
	var inv := DamageLog.grid_frame(world, isl.chunk) * isl.chunk_transform().affine_inverse()
	for i in (mini(contacts.size(), SHEAR_CONTACTS_MAX) if near else 0):
		# peel: the struck region comes away as one clump rather than as a spray
		# of single bricks. See BrickWorld::separate_near.
		var e := _piece_entry(isl, DamageLog.Kind.PIECE_SHEAR)
		e.point = inv * ((contacts[i] as Dictionary).point as Vector3)
		e.radius = radius
		e.limit = SHEAR_MAX_BLOCKS
		e.flags = DamageLog.FLAG_PEEL
		var got := DamageLog.apply_entry(world, isl.chunk, e)
		if not got.is_empty():
			_record(e)
			loosened.append_array(got)
	_tu = _upart("land: shear", _tu)
	if near:
		loosened.append_array(_snap_across(isl, contacts, severity))
		_tu = _upart("land: snap", _tu)
	else:
		# Counted as a landing all the same, so a piece bouncing in the
		# distance is not queued again every bounce (MAX_IMPACTS).
		far_landings += 1
		isl.impacts += 1
	if loosened.is_empty() and near:
		return
	if loosened.is_empty():
		_hand_over(isl, contacts, severity)
		return

	isl.impacts += 1
	impacts += 1
	impact_blocks += loosened.size()
	_touched(isl)
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
	_tu = _upart("land: rest", _tu)
	_hand_over(isl, contacts, severity)
	_upart("land: what it hit", _tu)


## Give whatever a landing piece hit the other half of the collision.
func _hand_over(isl: BrickIsland, contacts: Array, severity: float) -> void:
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
	# In the piece's own space: what the command carries (DamageLog._apply_local).
	var points := PackedVector3Array()
	for c in contacts:
		if planes >= BREAK_PLANES_MAX:
			break
		var local_point: Vector3 = inv_xf * (c.point as Vector3)
		var at: float = local_point.dot(local_axis)
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
		points.push_back(DamageLog.grid_frame(world, isl.chunk) * local_point)
		used.append(at)
		planes += 1
	if planes > 0:
		# A SEAM first: sever one course of downward joints and leave both sides
		# solid, which is how a brick model comes apart. Tearing a band into
		# loose brick is the fallback, for a cut across an axis that has no
		# joints running along it -- see BrickWorld::sever_seams. Both live in
		# DamageLog._apply_local now, so a client snaps the same way.
		var e := _piece_entry(isl, DamageLog.Kind.PIECE_SNAP)
		e.points = points
		e.normal = local_axis
		e.radius = BREAK_THICKNESS
		torn = DamageLog.apply_entry(world, isl.chunk, e)
		if not torn.is_empty():
			_record(e)
		if e.flags & DamageLog.FLAG_BANDED:
			band_breaks += planes
		breaks += planes
	return torn


## How many pieces are invisible right now, and how big the biggest one is.
## Is this piece drawing nothing -- no surfaces and no bands? What
## _count_meshless counts, asked of one piece. A piece with no mesh node at all
## is drawn some other way (the shared single-brick MultiMesh) and is not blind.
func is_blind(isl: BrickIsland) -> bool:
	if not isl.is_valid() or isl.mesh == null:
		return false
	var m: Mesh = isl.mesh.mesh
	return (m == null or m.get_surface_count() == 0) and not _any_band(isl)


func _count_meshless() -> void:
	for isl in islands:
		if not isl.is_valid() or isl.mesh == null:
			continue
		# An ArrayMesh with no surfaces is NOT null and draws nothing; count both.
		# A toppled building draws through its bands and not its own mesh.
		var m: Mesh = isl.mesh.mesh
		if (m == null or m.get_surface_count() == 0) and not _any_band(isl):
			isl.blind_ticks += 1
			meshless_worst_blocks = maxi(meshless_worst_blocks,
					world.get_alive_block_count(isl.chunk))
			var stage := "orphan"
			if isl.upload_waiting:
				stage = "upload budget"
			elif isl.mesh_job != -1:
				stage = "upload"
			elif _mesh_queue.has(isl) and isl.coarse:
				stage = "stand-in queued"
			elif _mesh_queue.has(isl):
				stage = "queued" if world.bake_ready(isl.chunk) else \
						("baking" if world.bake_pending(isl.chunk) else "no bake")
			elif _band_holes.has(isl):
				stage = "band holes"
			isl.blind_stages[stage] = int(isl.blind_stages.get(stage, 0)) + 1
		elif isl.blind_ticks > 0:
			if isl.blind_ticks > blind_worst:
				blind_worst_stages = isl.blind_stages.duplicate()
				blind_worst_stages["bricks"] = world.get_alive_block_count(isl.chunk)
				blind_worst_stages["settled"] = isl.settled
				blind_worst_stages["landmark"] = isl.landmark
				blind_worst_stages["bands"] = isl.bands.size()
				blind_worst_stages["mesh"] = str(isl.mesh.mesh)
			isl.blind_stages = {}
			blind_worst = maxi(blind_worst, isl.blind_ticks)
			blind_total += isl.blind_ticks
			blind_count += 1
			isl.blind_ticks = 0


func _any_band(isl: BrickIsland) -> bool:
	for node in isl.bands:
		if is_instance_valid(node):
			return true
	return false


## Build the bands a toppled building never got to, one a tick, from the bake
## it already has: a slice of it each (build_chunk_mesh_section), where the one
## mesh of the whole piece was 17-23 ms in a single call -- paid inside whatever
## blast hit it first. A piece whose bake has gone, or that has become an
## ordinary one-mesh island meanwhile, is left to rebuild_mesh.
func _fill_band_holes() -> void:
	while not _band_holes.is_empty():
		var isl: BrickIsland = _band_holes[0]
		if not isl.is_valid() or isl.mesh == null or isl.bands.is_empty() \
				or not world.bake_ready(isl.chunk) \
				or world.get_chunk_sections(isl.chunk) != isl.bands.size():
			_band_holes.pop_front()
			continue
		var si := -1
		for k in isl.bands.size():
			if not is_instance_valid(isl.bands[k]):
				si = k
				break
		if si < 0:
			_band_holes.pop_front()
			continue
		var arrays: Array = world.build_chunk_mesh_section(isl.chunk, si)
		var mesh := ArrayMesh.new()
		if not arrays.is_empty() and mesh_arrays_ok(arrays, "island %d band %d" % [isl.chunk, si]):
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var live := mesh.get_surface_count() > 0
		var node := MeshInstance3D.new()
		node.material_override = brick_material
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		node.mesh = mesh if live else null
		# In the piece's own node's space, as its other bands are.
		isl.mesh.add_child(node)
		isl.bands[si] = node
		while isl.band_bytes.size() < isl.bands.size():
			isl.band_bytes.append(0)
		isl.band_bytes[si] = index_patch_bytes(arrays) if live else 0
		band_holes_filled += 1
		return   # one a tick


## Is this piece drawn whole by the bands it came down with? Every slot: one
## the building never built, or that has gone, is a hole in the piece. (A band
## built EMPTY is a node with no mesh, and is not a hole.)
func _draws_bands(isl: BrickIsland) -> bool:
	if isl.bands.is_empty():
		return false
	for node in isl.bands:
		if not is_instance_valid(node):
			return false
	return true


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
	if isl.mesh != null and isl.mesh.mesh != null:
		return isl.mesh.get_aabb()
	# No mesh to ask -- dropped for distance, or not built yet: its grid's box.
	# A zero box here was a piece nothing could find by volume, so a far piece
	# with its mesh dropped was never woken by the shot that took its floor.
	if isl.mesh != null and isl.chunk >= 0 and world.is_chunk_alive(isl.chunk):
		return AABB(Vector3.ZERO, Vector3(world.get_chunk_dims(isl.chunk))
				* BrickWorld.get_cell_size())
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



## How long a piece has to stay slow before it settles: longer where the
## player can see it happen from close by.
func _slow_window(isl: BrickIsland) -> int:
	if camera != null and is_instance_valid(camera) \
			and camera.global_position.distance_to(isl.body.global_position) < SETTLE_NEAR:
		return SETTLE_SLOW_NEAR_MS
	var points := interest_points()
	if not points.is_empty() \
			and _nearest_interest(isl.body.global_position, points) - isl.radius > FRACTURE_RANGE:
		return SETTLE_SLOW_FAR_MS
	return SETTLE_SLOW_MS


func tick() -> void:
	var _t_loop := Time.get_ticks_usec()
	if camera != null and is_instance_valid(camera):
		_frustum = camera.get_frustum()
	var look := Engine.get_physics_frames() % SEEN_EVERY == 0
	_work_until = Time.get_ticks_usec() + int(WORK_BUDGET_MS * 1000.0)
	_work_done = 0
	_sync_meshes = 0
	var now := Time.get_ticks_msec()
	var settles := 0
	var moving := 0
	var moving_landmarks := 0
	var moving_blocks := 0
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
				_retire(isl, i + 1, &"empty")
				continue

		# Debris is kept while it can be seen and goes once it cannot. It was
		# swept 0.3 s after it landed or at 2.5 s whatever the camera was doing,
		# which is a brick vanishing in front of the player -- the thing Just
		# Cause 3 was taken to task for. Now: never removed in view; gone after
		# DEBRIS_UNSEEN_MS out of it; and, when it must go in view (old, or the
		# cap), shrunk away over DEBRIS_FADE_MS rather than popped.
		if isl.disposable:
			if isl.fade_since > 0:
				if _advance_fade(isl, now):
					_retire(isl, i + 1, &"faded")
					continue
			else:
				if look and _box_seen(world_aabb(isl), _frustum):
					isl.seen_tick = Engine.get_physics_frames()
				if Engine.get_physics_frames() - isl.seen_tick > _unseen_ticks():
					debris_unseen += 1
					_retire(isl, i + 1, &"swept")
					continue
				if now - isl.born_ms > DEBRIS_SEEN_MAX_MS:
					_start_fade(isl, now)

		if isl.settled:
			continue
		moving += 1
		if isl.landmark:
			moving_landmarks += 1
		moving_blocks += isl.shape_count

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

		var fell := isl.fall_ticks
		isl.fall_ticks = isl.fall_ticks + 1 if speed > IMPACT_MIN_SPEED else 0
		# A landing only breaks anything where this machine decides (see decides).
		if decides and lost > IMPACT_DELTA and isl.prev_speed + lost > IMPACT_MIN_SPEED \
				and isl.impacts < MAX_IMPACTS and not isl.fracture_queued and not _is_quiet(isl):
			if fell < IMPACT_FALL_TICKS:
				jolts_ignored += 1
			else:
				peak_drop = maxf(peak_drop, lost)
				isl.fracture_queued = true
				isl.fall_ticks = 0
				_fracture_queue.append([isl, lost])
				continue

		if isl.ripple_pending and not isl.settled and speed > RIPPLE_START_SPEED:
			isl.ripple_pending = false
			support_gone(isl.ripple_box)

		# Held by something outside physics (hold_awake): not at rest, whatever
		# its speed says.
		if isl.hold_until_ms > 0 and now < isl.hold_until_ms:
			isl.slow_since = 0
			continue

		var rested := isl.body.sleeping
		var by_rule := false
		var by_age := false
		if not rested and now - isl.born_ms >= SETTLE_MIN_MS:
			if speed < SETTLE_SPEED and spin < SETTLE_SPIN:
				if isl.slow_since == 0:
					isl.slow_since = now
					# Coming to rest: on what? A frozen piece under it is woken,
					# and falls if nothing holds it (see RIPPLE_MARGIN).
					if not isl.disposable:
						_wake_touched(isl)
				elif now - isl.slow_since >= _slow_window(isl):
					rested = true
					by_rule = true
			else:
				isl.slow_since = 0
			if not rested and now - isl.born_ms >= SETTLE_MAX_MS \
					and speed < SETTLE_MAX_SPEED:
				rested = true
				by_age = true
		if now - isl.born_ms >= SETTLE_MIN_MS and rested and settles < SETTLES_PER_TICK \
				and not isl.disposable and not _supported_below(isl) \
				and (isl.unsupported_tries < SUPPORT_TRIES or not _touching_anything(isl)):
			# Nothing under it: held by friction against what it came away from.
			# A nudge down, and it is asked again when it is slow again. Past its
			# tries only if it touches something: a piece touching nothing is
			# never frozen (TOUCH_MARGIN).
			if isl.unsupported_tries >= SUPPORT_TRIES:
				floating_refused += 1
			isl.unsupported_tries += 1
			unsupported_nudges += 1
			isl.slow_since = 0
			isl.body.sleeping = false
			isl.body.linear_velocity += Vector3.DOWN * SUPPORT_NUDGE
			continue
		if now - isl.born_ms >= SETTLE_MIN_MS and rested and settles < SETTLES_PER_TICK:
			settles += 1
			if by_rule:
				settled_by_rule += 1
			elif by_age:
				settled_by_age += 1
			settle_now(isl)

	census.ticks += 1
	census.moving += moving
	census.landmarks += moving_landmarks
	census.blocks += moving_blocks
	census.moving_peak = maxi(census.moving_peak, moving)
	census.landmarks_peak = maxi(census.landmarks_peak, moving_landmarks)
	census.blocks_peak = maxi(census.blocks_peak, moving_blocks)
	_moving_now = moving
	_audit_settled()
	_drain_ripples()
	var _tp := Time.get_ticks_usec()
	_dorm_wake_ms = 0.0
	_dorm_sleep_ms = 0.0
	_stream_dormancy()
	var _td := Time.get_ticks_usec()
	# After dormancy, not before: what distance already put away does not
	# need the cap's attention.
	_enforce_debris_cap()
	_advance_sleep_jobs()
	if not _stand_ins_due.is_empty():
		build_due_stand_ins()
	var _tl := Time.get_ticks_usec()
	tick_prof.loop += float(_tl - _t_loop) / 1000.0
	tick_prof.pieces += float(_tp - _t_loop) / 1000.0
	tick_prof.dormancy += float(_td - _tp) / 1000.0
	tick_prof.cap += float(_tl - _td) / 1000.0
	_count_meshless()
	_retirer.drain()
	# Meshes first. A piece that has left its building but has no mesh yet is
	# a hole in the world, and the queues below can wait a tick -- they only
	# decide what breaks NEXT.
	_harvest_mesh_jobs()
	_drain_upload_waiting()
	_drain_mesh_queue()
	_fill_band_holes()
	_drain_resolve_queue()
	var _tr := Time.get_ticks_usec()
	tick_prof.resolve += float(_tr - _tl) / 1000.0
	_drain_fracture_queue()
	var _tfq := Time.get_ticks_usec()
	# After everything that can change a falling piece's blocks this tick, and
	# before the physics steps: one merged rebuild per piece that changed.
	_flush_reshapes()
	var _tf := Time.get_ticks_usec()
	tick_prof.fracture += float(_tf - _tr) / 1000.0
	_stream_island_meshes()
	var _tm := Time.get_ticks_usec()
	tick_prof.mesh += float(_tm - _tf) / 1000.0
	_update_multimeshes()
	if not defer_job_start:
		start_mesh_jobs()
	tick_prof.mm += float(Time.get_ticks_usec() - _tm) / 1000.0
	var _total := float(Time.get_ticks_usec() - _t_loop) / 1000.0
	if _total > float(tick_worst.get("total", 0.0)):
		tick_worst = {"total": _total,
				"loop": float(_tl - _t_loop) / 1000.0,
				"pieces": float(_tp - _t_loop) / 1000.0,
				"dormancy": float(_td - _tp) / 1000.0,
				"wake": _dorm_wake_ms,
				"sleep": _dorm_sleep_ms,
				"cap": float(_tl - _td) / 1000.0,
				"resolve": float(_tr - _tl) / 1000.0,
				"fracture": float(_tf - _tr) / 1000.0,
				"landings": float(_tfq - _tr) / 1000.0,
				"reshapes": float(_tf - _tfq) / 1000.0,
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
		var t0 := Time.get_ticks_usec()
		_unit = {}
		solve_island(isl)
		var t1 := Time.get_ticks_usec()
		rebuild_mesh(isl)
		_upart("mesh", t1)
		_unit_done("resolve", isl, t0)
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
		var t0 := Time.get_ticks_usec()
		_unit = {}
		fracture_on_impact(isl, float(entry[1]))
		_unit_done("landing", isl, t0)
		_work_done += 1


## The island LOD ladder: its bricks near, the coarse stand-in far
## (ISLAND_MESH_RANGE, ISLAND_MESH_HYSTERESIS between the two).
##
## Only a SETTLED piece is put to the stand-in here. Anything still moving is
## something the player is watching fall, and re-meshing it mid-flight would
## cost more than it saved (one that comes loose far off starts as the stand-in
## -- spawn). Anything, settled or not, gets its bricks back when somebody comes
## near; the stand-in draws until they are ready.
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
		if not isl.is_valid() or isl.mesh == null or not isl.bands.is_empty():
			continue
		var dist := isl.body.global_position.distance_to(here)
		if isl.coarse:
			if dist < ISLAND_MESH_RANGE:
				isl.coarse = false
				world.bake_chunk_async(isl.chunk)
				if not _mesh_queue.has(isl):
					_mesh_queue.append(isl)
				budget -= 1
		elif isl.settled and dist > ISLAND_MESH_RANGE + ISLAND_MESH_HYSTERESIS:
			isl.coarse = true
			world.drop_chunk_bake(isl.chunk)
			# Its bricks draw until the queue has built the stand-in -- they need
			# no bake to go on being drawn. Walked up to and away again before
			# its bricks came, it is drawing the stand-in already.
			if not isl.coarse_drawn and not _mesh_queue.has(isl):
				_mesh_queue.append(isl)
			dropped += 1
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
		# A stand-in waits on nothing: built now, in this budget -- unless the
		# one it has is fresh (COARSE_REBUILD_TICKS), when it waits its turn.
		if isl.coarse:
			if isl.coarse_drawn \
					and Engine.get_physics_frames() - isl.coarse_tick < COARSE_REBUILD_TICKS:
				i += 1
				continue
			_mesh_queue.remove_at(i)
			rebuild_mesh(isl, true)
			done += 1
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
	# Counting is cheap and done every tick, so the cap answers at once when it
	# is crossed; working out WHO goes is not, and is planned (_plan_debris_cap).
	var small_n := 0
	var large_n := 0
	for isl in islands:
		# Debris counts too, now that it lives as long as it is seen; what is
		# already shrinking away is on its way out.
		if not isl.is_valid() or not isl.settled or isl.capturing or isl.fade_since > 0:
			continue
		if isl.landmark:
			large_n += 1
		else:
			small_n += 1
	_cap_room = small_n <= small_live_max - CAP_WAKE_SPARE \
			and large_n <= large_live_max - CAP_WAKE_SPARE \
			and small_n + large_n <= total_live_max - CAP_WAKE_SPARE
	if small_n <= small_live_max and large_n <= large_live_max \
			and small_n + large_n <= total_live_max:
		_cap_plan.clear()
		return
	var now_tick := Engine.get_physics_frames()
	if _cap_plan.is_empty() or now_tick - _cap_planned >= CAP_REPLAN_TICKS:
		_cap_plan = _plan_debris_cap()
		_cap_planned = now_tick
	var done := 0
	while done < EVICTIONS_PER_TICK and not _cap_plan.is_empty():
		var entry: Array = _cap_plan.pop_front()
		var isl: BrickIsland = entry[0]
		if not isl.is_valid() or not isl.settled or isl.capturing:
			continue
		var at := islands.find(isl)
		if at < 0:
			continue
		if bool(entry[1]):
			if isl.disposable and Engine.get_physics_frames() - isl.seen_tick < _unseen_ticks():
				# In view: it goes, but it shrinks away rather than popping.
				_start_fade(isl, Time.get_ticks_msec())
			else:
				_retire(isl, at, &"cap")
			cap_deleted += 1
		else:
			match _sleep_or_begin(isl, at, true):
				SLEPT:
					cap_slept += 1
				NOTHING:
					# Nothing to photograph, so there is nothing to keep either.
					_retire(isl, at, &"cap")
					cap_deleted += 1
				# STARTED: counted when the capture finishes.
		done += 1


## Who the cap would put away, in order: [island, small] each. Worked out every
## CAP_REPLAN_TICKS rather than every tick -- sorting every settled landmark by
## its distance to everybody, every tick, for three evictions a tick, was most of
## what the cap cost: 2.4 ms a tick across a big collapse, with the scene over
## the cap for most of it. A plan a quarter of a second old is as good; anything
## in it that has woken or gone since is skipped.
func _plan_debris_cap() -> Array:
	var small: Array = []
	var large: Array = []
	for i in islands.size():
		var isl: BrickIsland = islands[i]
		if not isl.is_valid() or not isl.settled or isl.capturing or isl.fade_since > 0:
			continue
		if isl.landmark:
			large.append(isl)
		else:
			small.append(isl)
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
	var plan: Array = []
	# Oldest at rest first.
	if over_small > 0:
		# Out of view first, then oldest at rest.
		var tick_now := Engine.get_physics_frames()
		small.sort_custom(func(a: BrickIsland, c: BrickIsland) -> bool:
				var a_seen: bool = tick_now - a.seen_tick < _unseen_ticks()
				var c_seen: bool = tick_now - c.seen_tick < _unseen_ticks()
				if a_seen != c_seen:
					return not a_seen
				return a.settled_ms < c.settled_ms)
		for k in mini(over_small, small.size()):
			plan.append([small[k], true])
	if over_large > 0:
		# Farthest from anybody first, and nobody's cover or floor at all: a piece
		# asleep has no collision (see CAP_KEEP_RANGE).
		var points := interest_points()
		var away := {}
		var keep: Array = []
		for isl in large:
			var d := _distance_to_interest(world_aabb(isl), points)
			if d < CAP_KEEP_RANGE:
				continue
			away[isl] = d
			keep.append(isl)
		keep.sort_custom(func(a, c) -> bool: return float(away[a]) > float(away[c]))
		for k in mini(over_large, keep.size()):
			plan.append([keep[k], false])
		# What is still awake after this plan, the farthest of it.
		_cap_far = float(away[keep[over_large]]) if over_large < keep.size() else 0.0
	return plan


func _stream_dormancy() -> void:
	# Everybody, not one camera: see interest_points.
	var points := interest_points()
	if points.is_empty():
		return

	# Waking first, always. Something the player is walking towards matters
	# more than something they have walked away from.
	#
	# A slice of the list a tick, not all of it: every sleeping piece's distance
	# to everybody, every tick, was 1.7 ms a tick once a collapse had put a few
	# hundred to sleep. At WAKE_SCAN_PER_TICK the whole list is looked at every
	# few ticks, which is far faster than anyone walks into WAKE_RANGE.
	var woke := 0
	var _tw := Time.get_ticks_usec()
	for k in mini(dormant.size(), WAKE_SCAN_PER_TICK):
		if woke >= WAKES_PER_TICK:
			break
		if _wake_cursor >= dormant.size():
			_wake_cursor = 0
		var d: Dormant = dormant[_wake_cursor]
		var dist := _distance_to_interest(d.record.box, points)
		if dist > WAKE_RANGE or (d.by_cap and not _cap_room and dist >= _cap_far * CAP_SWAP):
			_wake_cursor += 1
			continue
		var _t1 := Time.get_ticks_usec()
		if _wake_record(d) != null:
			dormant.remove_at(_wake_cursor)   # the next one shifts into its place
			woke += 1
			if d.by_cap:
				cap_woken += 1
			var cost := float(Time.get_ticks_usec() - _t1) / 1000.0
			if cost > float(wake_worst[0]):
				wake_worst = [cost, d.record.block_count()]
		else:
			_wake_cursor += 1
	var _ts := Time.get_ticks_usec()
	_dorm_wake_ms = float(_ts - _tw) / 1000.0

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
		if not isl.is_valid() or not isl.settled or isl.disposable or isl.capturing:
			continue
		if now - isl.born_ms < SLEEP_AFTER_MS:
			continue
		var nearest := INF
		for p in points:
			nearest = minf(nearest, isl.body.global_position.distance_to(p))
		if nearest - isl.radius < SLEEP_RANGE:
			continue
		var _t1 := Time.get_ticks_usec()
		var blocks := world.get_block_count(isl.chunk)
		match _sleep_or_begin(isl, at, false):
			SLEPT:
				put_away += 1
				_sleep_cursor = at   # the list shifted under the cursor
				var cost := float(Time.get_ticks_usec() - _t1) / 1000.0
				if cost > float(sleep_worst[0]):
					sleep_worst = [cost, blocks]
			STARTED:
				put_away += 1
	_dorm_sleep_ms = float(Time.get_ticks_usec() - _ts) / 1000.0


## Photograph a piece and give everything else back.
func _sleep(isl: BrickIsland, index: int, by_cap := false) -> bool:
	return _commit_sleep(isl, index, ChunkRecord.capture(world, isl.chunk), by_cap)


enum { NOTHING, SLEPT, STARTED }


## Put a piece to sleep now if it is small, or start capturing it a slice a
## tick if it is not (CAPTURE_BLOCKS_PER_TICK). `for_cap` says who asked, for
## the counters when it finishes.
func _sleep_or_begin(isl: BrickIsland, index: int, for_cap: bool) -> int:
	if isl.capturing:
		return STARTED
	if world.get_block_count(isl.chunk) <= SLEEP_SYNC_BLOCKS:
		return SLEPT if _sleep(isl, index, for_cap) else NOTHING
	isl.capturing = true
	_sleep_jobs.append([isl, ChunkRecord.begin_capture(world, isl.chunk), isl.edits, for_cap])
	return STARTED


## Advance the captures in progress, CAPTURE_BLOCKS_PER_TICK blocks a tick. One
## that finishes puts its piece to sleep exactly as _sleep would have; one whose
## piece changed underneath it -- hit, landed on, woken -- is dropped, and the
## piece simply stays awake.
func _advance_sleep_jobs() -> void:
	var budget := CAPTURE_BLOCKS_PER_TICK
	while budget > 0 and not _sleep_jobs.is_empty():
		var job: Array = _sleep_jobs[0]
		var isl: BrickIsland = job[0]
		var record: ChunkRecord = job[1]
		if not isl.is_valid() or not isl.settled or isl.edits != int(job[2]):
			if isl.is_valid():
				isl.capturing = false
			_sleep_jobs.pop_front()
			continue
		var from := record.next
		var done := record.capture_some(world, isl.chunk, budget)
		budget -= record.next - from
		if not done:
			break
		_sleep_jobs.pop_front()
		record.finish_capture(world, isl.chunk)
		isl.capturing = false
		var at := islands.find(isl)
		if at < 0:
			continue
		if _commit_sleep(isl, at, record, bool(job[3])):
			if bool(job[3]):
				cap_slept += 1
		elif bool(job[3]):
			_retire(isl, at, &"cap")
			cap_deleted += 1


## The part of going to sleep after the photograph: keep the record, let the
## piece go.
func _commit_sleep(isl: BrickIsland, index: int, record: ChunkRecord, by_cap := false) -> bool:
	if record.block_count() == 0:
		return false
	var d := Dormant.new()
	d.record = record
	d.by_cap = by_cap
	d.slept_ms = Time.get_ticks_msec()
	d.piece_id = isl.piece_id
	d.owner = isl.owner
	d.stand_in = _leave_stand_in(isl)
	dormant.append(d)
	slept += 1
	piece_slept.emit(isl.piece_id, record)
	_retire(isl, index, &"slept")
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
	var isl := adopt(chunk, null, null, 0, 4, [], d.piece_id, d.owner, false)
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
	# What it rested on went while it slept (support_gone): it wakes free to
	# fall, and settles again if something still holds it.
	if d.unsure:
		wake(isl)
	# What it left drawn while it slept goes on being drawn, by the piece now,
	# until what it draws next is ready -- and far off, that IS what it draws
	# next: the same bricks make the same stand-in.
	var kept := _take_stand_in(d, isl)
	isl.coarse = _starts_coarse(isl)
	if isl.coarse:
		if not kept:
			_mesh_queue.append(isl)
	else:
		# Baked on a worker and drawn a tick or two later, however small: a
		# piece waking is one nobody was looking at, and bricks are a poor
		# measure of a bake -- a staircase piece of 146 is 90,000 vertices of
		# spiral step, and baking one here was a 15 ms wake.
		world.bake_chunk_async(chunk)
		_mesh_queue.append(isl)
	woken += 1
	isl.wakes += 1
	piece_woken.emit(isl)
	return isl


## Give a piece loaded from a save its body back. Docs/AIPlan.md P0 step 2.
##
## `chunk` holds the piece's bricks already -- the save's log was replayed into
## the world, which is what made them (StructureReplayer). What the log does not
## hold is physics: where the piece is and how it is moving. That comes from
## the save, and here it is put back.
func restore_piece(chunk: int, piece_id: int, owner_id: int, chunk_xform: Transform3D,
		linear: Vector3, angular: Vector3, at_rest: bool, is_disposable: bool) -> BrickIsland:
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return null
	world.set_chunk_transform(chunk, chunk_xform)
	_restoring = true
	var isl := adopt(chunk, null, null, 0, 4, [], piece_id, owner_id, true, not is_disposable)
	_restoring = false
	if isl == null:
		return null
	if at_rest:
		# The same state _wake_record builds: frozen, merged, not settling again.
		isl.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		isl.body.freeze = true
		isl.settled = true
		isl.settled_ms = Time.get_ticks_msec()
		isl.settled_blocks = world.get_alive_block_count(isl.chunk)
		settled += 1
		_apply_layers(isl)
		_reshape(isl, true)
	else:
		_apply_layers(isl)
		isl.body.linear_velocity = linear
		isl.body.angular_velocity = angular
		isl.prev_speed = linear.length()
	isl.coarse = _starts_coarse(isl)
	if isl.coarse or world.get_alive_block_count(chunk) <= SYNC_MESH_MAX_BLOCKS:
		rebuild_mesh(isl, true, true)
	else:
		world.bake_chunk_async(chunk)
		_mesh_queue.append(isl)
	return isl


## What a piece put to sleep leaves drawn where it lay (Dormant.stand_in): the
## mesh it is drawing, in a node of its own with no body. Sleeping used to take
## a piece out of the picture with its body, so a collapse's rubble went from
## the skyline as the player walked off (SLEEP_RANGE).
##
## The mesh it has, whichever it is: far off that is the coarse stand-in already
## (the ladder puts a settled piece to it at 145 m, sleep comes at 150), and
## nearer -- the debris cap puts pieces to sleep wherever they are -- it is its
## bricks, which is right that close. A stand-in built here was 8-38 ms a sleep
## when the cap took a few at once. Once asleep it is never patched: nothing
## changes it until the piece wakes and builds its own (_take_stand_in).
##
## Only a piece drawn by the bands of the building it toppled from has no one
## mesh to leave; its stand-in is built, from the chunk while it is still there.
## Those are whole buildings, and few. A single brick (the MultiMesh's) just goes.
func _leave_stand_in(isl: BrickIsland) -> MeshInstance3D:
	if isl.mesh == null or not isl.mesh.is_inside_tree():
		return null
	var mesh: ArrayMesh = isl.array_mesh
	if (mesh == null or mesh.get_surface_count() == 0) and _any_band(isl):
		var arrays: Array = world.build_chunk_coarse_mesh(isl.chunk)
		coarse_built += 1
		coarse_worst_ms = maxf(coarse_worst_ms, world.get_last_coarse_ms())
		if not arrays.is_empty() and mesh_arrays_ok(arrays, "stand-in %d" % isl.chunk):
			coarse_verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			mesh = ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = isl.mesh.material_override
	node.cast_shadow = isl.mesh.cast_shadow
	node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(node)
	node.global_transform = isl.mesh.global_transform
	stand_ins += 1
	return node


## Hand a waking piece the stand-in it left: its mesh on the piece's own node,
## the node itself gone. True if there was one to hand over. Marked coarse_drawn
## whatever it is -- coarse or the bricks it slept with -- because either way it
## is not the new chunk's bake, and must be built again, never patched.
func _take_stand_in(d: Dormant, isl: BrickIsland) -> bool:
	var node := d.stand_in
	d.stand_in = null
	if node == null or not is_instance_valid(node):
		return false
	var m := node.mesh as ArrayMesh
	node.queue_free()
	if m == null or m.get_surface_count() == 0 or isl.mesh == null:
		return false
	isl.mesh.mesh = m
	isl.array_mesh = m
	isl.coarse_drawn = true
	isl.index_bytes = 0
	return true


## Decisions queued here and not made yet: a landing waiting to break a piece, a
## piece waiting to be re-solved after something sheared it. The structure is
## exact without them -- they have not happened -- but a save that dropped them
## would load a piece that never finishes breaking. By piece id, for AreaSnapshot.
func pending_state() -> Dictionary:
	var resolve := PackedInt32Array()
	for isl in _resolve_queue:
		if isl.is_valid() and isl.piece_id >= 0:
			resolve.append(isl.piece_id)
	var fracture := []
	for entry in _fracture_queue:
		var isl: BrickIsland = entry[0]
		if isl.is_valid() and isl.piece_id >= 0:
			fracture.append([isl.piece_id, float(entry[1])])
	return {"resolve": resolve, "fracture": fracture}


## Queue again what pending_state saved, against the pieces a load brought back.
## Returns how many were queued.
func restore_pending(d: Dictionary) -> int:
	var by_id := {}
	for isl in islands:
		if isl.is_valid() and isl.piece_id >= 0:
			by_id[isl.piece_id] = isl
	var n := 0
	for id in d.get("resolve", PackedInt32Array()):
		var isl: BrickIsland = by_id.get(int(id))
		if isl != null and not _resolve_queue.has(isl):
			_resolve_queue.append(isl)
			n += 1
	for f in d.get("fracture", []):
		var isl: BrickIsland = by_id.get(int(f[0]))
		if isl != null and not isl.fracture_queued:
			isl.fracture_queued = true
			_fracture_queue.append([isl, float(f[1])])
			n += 1
	return n


## Put a piece loaded from a save straight back to sleep: it was a record when
## the save was taken, and it is a record now.
func restore_dormant(record: ChunkRecord, piece_id: int, owner_id: int) -> void:
	var d := Dormant.new()
	d.record = record
	d.slept_ms = Time.get_ticks_msec()
	d.piece_id = piece_id
	d.owner = owner_id
	dormant.append(d)
	_stand_ins_due.append(d)


## Pieces put back asleep from a save, whose stand-ins are still to be built.
var _stand_ins_due: Array = []


## Build the stand-ins of pieces put back asleep from a save, for `budget_ms`
## (one at least). A record is bricks and nothing draws it: a save's wreckage
## was invisible until somebody walked up to it. Each is made a chunk again
## (ChunkRecord.restore), its stand-in taken from that, and the chunk given
## back. Returns how many were built.
func build_due_stand_ins(budget_ms := 2.0) -> int:
	var until := Time.get_ticks_usec() + int(budget_ms * 1000.0)
	var n := 0
	while not _stand_ins_due.is_empty() and (n == 0 or Time.get_ticks_usec() < until):
		var d: Dormant = _stand_ins_due.pop_front()
		# Woken meanwhile, or a single brick (the MultiMesh's when awake).
		if d.stand_in != null or not dormant.has(d) or d.record.block_count() <= 1:
			continue
		var chunk := d.record.restore(world)
		if chunk < 0:
			continue
		var arrays: Array = world.build_chunk_coarse_mesh(chunk)
		world.release_chunk(chunk)
		coarse_built += 1
		coarse_worst_ms = maxf(coarse_worst_ms, world.get_last_coarse_ms())
		n += 1
		if arrays.is_empty() or not mesh_arrays_ok(arrays, "stand-in of piece %d" % d.piece_id):
			continue
		coarse_verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = brick_material
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(node)
		# Where its bricks lay: the chunk's own transform, as a piece's mesh has.
		node.transform = d.record.xform
		d.stand_in = node
		stand_ins += 1
	return n


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


func _retire(isl: BrickIsland, index: int, reason: StringName = &"swept") -> void:
	# Whatever was resting on it is resting on nothing now -- unless it is only
	# going to sleep: then what rests on it sleeps too, and both come back
	# where they were.
	if reason != &"slept" and isl.is_valid():
		support_gone(world_aabb(isl))
	piece_removed.emit(isl, reason)
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
			if isl.fade < 1.0:
				mm.set_instance_transform(i, isl.body.global_transform
						* Transform3D(Basis().scaled(Vector3.ONE * maxf(isl.fade, 0.01))))
			else:
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
		"settled_by_rule": settled_by_rule,
		"far_landings": far_landings,
		"far_shears": far_shears,
		"merged_rebuilds": merged_rebuilds,
		"settled_by_age": settled_by_age,
		"blocks": blocks,
		"disposable": loose,
		"discarded": discarded,
		"furniture_deleted": furniture_deleted,
		"tiny_deleted": tiny_deleted,
		"debris_unseen": debris_unseen,
		"debris_faded": debris_faded,
		"dropped": dropped,
		"coarse_built": coarse_built,
		"coarse_worst_ms": coarse_worst_ms,
		"coarse_verts": coarse_verts,
		"stand_ins": stand_ins,
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
