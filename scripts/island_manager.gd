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
## A piece in a heap is not slow, it is jittering: pushed about by the pieces
## round it, between half a metre a second and a metre, and every time it went
## over SETTLE_SPEED its clock started again. --jam found pieces doing that for
## the whole ten seconds it watched, 4-8 a collapse. So a piece with something
## under it (BrickIsland.landed) has a second clock, at twice the speed, over
## the same window. Free fall is still left behind at once -- a metre a second
## takes 1.6x gravity a sixteenth of a second.
const SETTLE_JITTER_SPEED := 1.0  ## m/s
const SETTLE_JITTER_SPIN := 1.0   ## rad/s
## A landed piece falling faster than IMPACT_MIN_SPEED with nothing touching it
## for this many ticks has gone over an edge: it is in the air again.
const AIRBORNE_AGAIN_TICKS := 6
## A contact whose normal is this near vertical is something under the piece
## (or on it), not a wall it is sliding down.
const LANDED_NORMAL_Y := 0.7
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
## And PERCHED: a big piece whose contacts under it are a point next to its own
## size, or do not have its centre of mass over them, is tipped, not frozen.
## Far from everybody a piece is frozen after SETTLE_SLOW_FAR_MS slow, and a
## landing there breaks nothing (FRACTURE_RANGE), so the top half of a tower
## shot from 160 m dropped a metre onto a strand of single bricks it hung over
## the stump, was frozen there before it had begun to tip, and stood 65 m tall
## on that strand for good -- "never falls, just floats" (user, 2026-10-17;
## big_city --lodbreak --at=160). The same SUPPORT_TRIES as a piece with
## nothing under it; past them it settles where it is. Only on the far window:
## closer in a piece has SETTLE_SLOW_MS to be slow before it is frozen, time
## enough to begin tipping by itself. Nor on a piece lying on other pieces:
## tipped in a heap, one levered its neighbours out (--jam --big, two runs of
## three threw one, where without the rule none did in three).
##
## PERCH_FOOT: a piece narrower than this on plan is never perched -- rubble
## lying on a corner is what rubble does. PERCH_SHARE: contacts spread over
## less than this share of its narrower side are a point. PERCH_EDGE_SPEED:
## how fast its farthest brick is set moving, m/s -- a spin, about the line it
## tips over, of this over its radius, so a 65 m piece is not flung.
const PERCH_FOOT := 3.0
const PERCH_SHARE := 0.2
const PERCH_EDGE_SPEED := 1.5
var perched_tipped := 0
## A pass that asks why a piece was frozen where it was (--lodbreak's piece
## lines) sets this: each piece's last perch answer and how it was frozen, by
## piece id. Nothing pays for it otherwise.
var perch_say := false
var perch_said := {}
const RIPPLE_START_SPEED := 0.6
## How far a piece that others were frozen on may move before they are woken
## (_note_holders). A heap's jitter is centimetres; a piece that falls away
## is gone past this in a tick or two.
const HOLDER_SLIP := 0.3
## frozen body's instance id -> [[piece frozen on it, where it was], ...]
var _holders := {}
var holder_woken := 0      ## pieces woken because what they were frozen on moved or went
var settle_waits := 0      ## settles put off because what was under was still moving
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
const FRACTURE_RANGE := CollapseTier.HOT_RANGE
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
const SMALL_KEEP_RANGE := CollapseTier.HOT_RANGE
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
## ...and longer for one that costs more to build: COARSE_TICKS_PER_MS ticks of
## wait for each millisecond its last build took. A 5,000-brick chunk of a
## collapse, falling far off while the queued shots of a --big --shot kept
## landing on it, was 17-22 ms a build -- the worst tick of the pass, every
## fifteen ticks. At four ticks a millisecond that one waits a second.
const COARSE_TICKS_PER_MS := 4.0


## How long this piece's stand-in waits before it is built again.
static func coarse_wait(isl: BrickIsland) -> int:
	return maxi(COARSE_REBUILD_TICKS, int(isl.coarse_ms * COARSE_TICKS_PER_MS))
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
##
## One of EACH queue. It was one for the tick, the re-solves were served
## first, and in a collapse the tick's own loop has spent the budget before
## either queue is reached -- so while a re-solve was waiting, no landing was
## dealt with. Once a hit's solve was queued as well (Docs/CollapseNext.md 1.4)
## one nearly always was: in a `--big --shot` up to 25 landings stood waiting,
## each a section lying whole and still moving where its landing should have
## broken it along its storeys, and the physics solver paid for every box of
## every one. Six alternated pairs of that pass (2026-10-08, quiet machine):
## frames 33.9 -> 28.8 ms mean, 308 -> 190 of 906 over 33.3 ms; the worst
## script tick and the count of ticks over 25 ms the same.
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
## ... and after it, in the same pass, groups of up to this many bricks:
## crumbs, off a piece (_crumbles_off_a_piece), with no body to make --
## SHED_CRUMBS_ANYWAY of them whatever the clock says, and more while the
## tick's work clock lasts (_has_work_time). One a pass was a landing's sheared
## band -- a few hundred single bricks, each joined to nothing -- coming off one
## brick a tick for four seconds and more, every pass finding all the piece's
## groups again to cut the next one: 900 passes of a `--big --shot` over a
## millisecond, 1.4 s of finding groups and 0.8 s of cutting them
## (2026-10-15). A crumb is ~17 us to cut once its pass has found it -- 32 are
## half a millisecond -- and finding them again 1.5-2.7 ms on a 22,000-brick
## piece. A brick that has come loose falls now.
const SHED_MORE_MAX_BLOCKS := LANDMARK_COUNT
const SHED_CRUMBS_ANYWAY := 32
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
## Nothing in this game throws a piece UP but a blast (push_near), a little, and
## a landing does not bounce. What else does is the solver pushing apart two pieces that
## overlap -- two that passed through each other in the air (Layers.
## AIRBORNE_MASK), and then one landed -- and uncapped that threw a 22-brick
## piece off a 72-brick one at 11 m/s (--jam --big). A piece rises no faster
## than this, so two that overlap come apart over a few ticks instead of
## flying. Not one the wind holds (hold_awake): a tornado lifts on purpose.
const MAX_RISE_SPEED := 4.0
var rises_capped := 0

## **A blast pushes what it reaches** (Docs/CollapseNext.md 1.10 (4)). It used to
## take bricks and push nothing: a piece beside it woke and stayed where it was.
## Now every loose piece within PUSH_REACH of its radius is given a shove away
## from it, and a little up -- light plastic is thrown, a section of a tower
## barely moves. How much: PUSH_SPEED for a piece of PUSH_REF_BLOCKS bricks at
## the blast's middle, falling to nothing at the edge of its reach. A smaller
## piece goes faster by the cube root of how much smaller (what a blast meets is
## a face, what it has to move is a volume); a bigger one slower by the whole of
## how much bigger, because a blast only meets as much face as is within its
## reach -- past that size the shove is the same and the mass is not. Given at
## the side nearest the blast, so a blast at one end of a beam turns it.
##
## Wreckage that is down stays where it is unless the shove is at least
## PUSH_WAKE_SPEED (1.10 (2)): a heap of a few hundred bricks shrugs off a rocket
## beside it, a handful of them is knocked over. Not only one at rest: a piece
## sliding to a stop given a shove its friction takes back in a moment only
## takes that much longer to stop -- under a barrage, pushing every piece that
## was down left almost nothing at rest (27 hits on wreckage at rest became 1,
## barrage_probe). A piece in the air takes every shove.
##
## Feel numbers: Options > Gameplay, "Blast Push (Developer)" (push_times).
const PUSH_SPEED := 4.0
const PUSH_REF_BLOCKS := 20.0
const PUSH_REACH := 2.5
const PUSH_LIFT := 0.35
const PUSH_WAKE_SPEED := 1.0
const PUSH_MAX_SPEED := 8.0
const PUSH_DEFAULT_TIMES := 1.0
const PUSH_MAX_TIMES := 3.0
static var push_times := PUSH_DEFAULT_TIMES
## Pieces pushed; of those, woken from rest; pieces down that a blast reached
## and that shrugged it off.
var push_census := [0, 0, 0]

var world: BrickWorld
var brick_material: ShaderMaterial
var camera: Camera3D
## The near tier (chamfered meshes, studs) for the pieces' meshes, if the scene
## has one: told of every mesh a piece is given and every patch of one.
var near_tier: BrickNear

var islands: Array[BrickIsland] = []
var settled := 0
var impacts := 0
var impact_blocks := 0
var splits := 0
var discarded := 0                 ## small pieces never spawned, because unseen
var furniture_deleted := 0         ## furniture-only pieces deleted where they came loose
var tiny_deleted := 0              ## small pieces deleted where they came loose, far away
var settled_by_rule := 0          ## settled for staying slow, not for sleeping
var settled_jittering := 0        ## of those, slow only by SETTLE_JITTER_SPEED
var landings_noted := 0           ## pieces that came down on something (landed)
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
## A hold lasts while a child it is for is still undrawn -- a big one is baked
## and meshed on a worker, and in a busy tick that is many frames -- up to this
## many. It was OVERLAP_FRAMES whatever: a toppled tower's top landed, broke in
## two, the parent stopped drawing the half that left, and that 2,145-brick half
## was drawn by nothing until its mesh came; only its window glass was left in
## the air (user, 2026-10-26: "the entire building glassed and disappears for a
## second"; big_city --landing). The child is drawn where the parent was for
## those frames, which on the ground is where it is.
const HOLD_MAX_FRAMES := 90
var holds_extended := 0
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
	## The rubble field's tile its stand-in is drawn in (_field_add), if any.
	var field_key := Vector2i.ZERO
	var in_field := false
	## The arrays its stand-in was made from (BrickIsland.coarse_arrays), or none:
	## a stand-in of its bricks, which draws itself, unmerged.
	var stand_in_arrays: Array = []


## Far enough that a piece is not part of the scene any more, and close enough
## that walking back brings it out again. The gap is hysteresis: a piece on the
## line must not sleep and wake every tick.
const SLEEP_RANGE := CollapseTier.FAR_RANGE
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
		"capped": [0, 0], "shed": [0, 0], "crumbled": [0, 0]}
## Bodies made, by what they came off -- a building, a piece (its landing or a
## hit on it), or a building toppled whole -- and by size: 1-8, 9-48, 49-499,
## 500+ bricks. Each [bodies, ms making them, ticks moving, boxes x ticks
## moving]: what each kind costs, which is what decides what to cut.
var body_census := {}
var _shedding := false
var _shed_cause := ""
## (building id) -> the plate heights of its floors in its own grid, bottom up
## (BuildingRegistry.floor_lines; Docs/DestructionLod.md 4): the lines a
## landing prefers to break a piece of it along (_snap_across). Set by the
## scene; unset or empty, pieces break where they are weakest.
var floor_lines := Callable()


func _lines_of(isl: BrickIsland) -> PackedInt32Array:
	return floor_lines.call(isl.owner) if floor_lines.is_valid() else PackedInt32Array()


## Plates from the floor at or under `plate` to the one over it: the storey
## there -- under the lowest floor or over the top one, the storey nearest. 0
## with fewer than two floors.
static func _storey_at(lines: PackedInt32Array, plate: int) -> int:
	if lines.size() < 2:
		return 0
	var i := clampi(lines.bsearch(plate, false), 1, lines.size() - 1)   # floors at or under it
	return lines[i] - lines[i - 1]


static func _on_line(lines: PackedInt32Array, plate: int) -> bool:
	var i := lines.bsearch(plate)
	return i < lines.size() and lines[i] == plate
const CENSUS_FROM := ["building", "piece: landing", "piece: landing: band", "piece: landing: crack",
		"piece: struck",
		"piece: hit", "piece: other", "adopted (toppled whole, or woken)"]


static func census_class(bricks: int) -> int:
	if bricks <= DEBRIS_MAX_BLOCKS:
		return 0
	if bricks <= LANDMARK_COUNT:
		return 1
	if bricks < 500:
		return 2
	return 3


func _census_body(isl: BrickIsland, from: String, bricks: int, ms: float) -> void:
	if body_census.is_empty():
		for f in CENSUS_FROM:
			body_census[f] = [[0, 0.0, 0, 0], [0, 0.0, 0, 0], [0, 0.0, 0, 0], [0, 0.0, 0, 0]]
	isl.census_cls = census_class(bricks)
	isl.census_from = from
	var row: Array = body_census[from][isl.census_cls]
	row[0] += 1
	row[1] += ms


## Hits on pieces, by where the piece was when it was hit -- in the air, down
## but still moving, at rest -- as [hits, bodies they made]. What a shot at
## wreckage costs depends on which (Docs/CollapseNext.md 1.4).
var hit_census := [[0, 0], [0, 0], [0, 0]]
## Hits that took bricks from a piece at rest: left at rest; woken because they
## cut it in two (or took all of it); and woken with nothing cut -- which rule 2
## says never happens (damage). What it stood on going is a wake a tick later
## (support_gone), counted as kept here.
var rest_hits_kept := 0
var rest_hits_cut := 0
var rest_hits_woke := 0


func hit_census_line() -> String:
	return "hits on pieces -- in the air: %d made %d bodies; down and moving: %d made %d; at rest: %d made %d" % [
			hit_census[0][0], hit_census[0][1], hit_census[1][0], hit_census[1][1],
			hit_census[2][0], hit_census[2][1]] + "; of the ones at rest %d left it at rest, %d cut it in two, %d woke it with nothing cut; %d merged rebuild(s), %d tick(s) one was put off" % [
			rest_hits_kept, rest_hits_cut, rest_hits_woke, merged_rebuilds, reshapes_put_off]


## The census as lines, for a pass to print.
func body_census_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var names := ["1-8", "9-48", "49-499", "500+"]
	var total_box := 0
	for f in body_census:
		for row in body_census[f]:
			total_box += int(row[3])
	for f in body_census:
		var parts := PackedStringArray()
		for c in 4:
			var row: Array = body_census[f][c]
			if int(row[0]) == 0:
				continue
			parts.append("%s: %d bodies, %.0f ms to make, %d moving ticks, %.0f%% of moving boxes" % [
					names[c], int(row[0]), float(row[1]), int(row[2]),
					100.0 * float(row[3]) / maxf(total_box, 1)])
		if not parts.is_empty():
			out.append("from a %s -- %s" % [f, "; ".join(parts)])
	return out
## Pieces moving as of the last tick, plus bodies made since: what the cap reads.
var _moving_now := 0
## Building id -> its pieces (not rubble) still moving, as of the last tick.
var _moving_of := {}


## How many pieces of this building are still moving: it is coming apart, or
## its wreckage has not come to rest (CityScene._mid_collapse).
func moving_of(owner_id: int) -> int:
	return int(_moving_of.get(owner_id, 0))
## DETACHes recorded with FLAG_GONE, by the piece id they would have had.
var _gone_pieces := {}
var tick_worst := {}
## The last tick, split as tick_worst: [total, loop, resolve parts (harvest,
## upload, mesh queue, band holes, resolve queue), landings, reshapes, mesh] --
## for CityScene's spikes, which keep every slow tick, not the worst alone.
var last_tick: Array = []
## The worst single spawn: [ms, split, shapes, node, mesh, bricks].
var spawn_worst := [0.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0]
var spawn_last := []   ## the last spawn, the same way
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
var _resolve_parts: Array = []
var _sync_meshes := 0
var dropped := 0     ## settled pieces put to the coarse stand-in for distance
var coarse_built := 0      ## coarse stand-ins built (build_chunk_coarse_mesh)
var coarse_worst_ms := 0.0 ## the slowest of them
var coarse_verts := 0      ## their vertices, all told
var stand_ins := 0         ## pieces put to sleep that left a stand-in drawn
var breaks := 0      ## times a landing snapped a piece across its width
var floor_breaks := 0  ## of those, on a storey line (_is_floor_line)
var seam_breaks := 0   ## of those, at the weakest seam in reach (_weak_seam)
var crack_breaks := 0  ## of those, cracks across X or Z (_weak_crack)
## Studs the weakest seams in reach of landings held with, and the storey
## lines beside them -- where there was one of each to count.
var seam_studs_chosen := 0
var seam_studs_floor := 0
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
	# Every search from what changed checked against a whole walk
	# (split_if_broken; the count is in shed_census_line). For test passes.
	if OS.has_environment("BC_COMPONENTS_CHECK"):
		world.set_components_check(true)
	if heap == null:
		heap = BrickHeap.new()
		heap.name = "BrickHeap"
		heap.mesh_for = func(size: Vector3) -> Mesh: return PieceMeshes.chamfered_box(size)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.85
		heap.material = mat
		add_child(heap)


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
	var far_small := not gone and _far_and_small(chunk, ids)
	var crumbs := not gone and not far_small and source != null \
			and _crumbles_off_a_piece(chunk, ids)
	if gone or crumbs or far_small:
		e.flags |= DamageLog.FLAG_GONE
	var pid := DamageLog.piece_id(_record(e))
	if gone:
		_gone_pieces[pid] = true
	if far_small:
		_gone_pieces[pid] = &"far"
	if crumbs:
		_crumbled_pieces[pid] = true
	return pid


## What comes off a PIECE -- shot apart, struck, broken by its own landing -- and
## is LANDMARK_COUNT bricks or fewer is crumbs, not a body, landmark-sized or
## not: wreckage coming apart into bricks. They were the most of what a
## collapse made: 9-48 bricks, 141 bodies in a --big --shot, 91 of them from
## shots at pieces (body_census, 2026-10-02). The host's decision, and it
## travels in the DETACH as FLAG_GONE, so nobody keeps a body of it -- a
## landmark is something every machine has or none does.
func _crumbles_off_a_piece(chunk: int, ids: PackedInt32Array) -> bool:
	if not decides or ids.size() > LANDMARK_COUNT or ids.size() <= DEBRIS_MAX_BLOCKS:
		return false
	var furniture := true
	for id in ids:
		if not world.is_block_decorative(chunk, id):
			furniture = false
			break
	return not furniture and not _in_wind(_group_box(chunk, ids))


## Far from every player, a piece of fewer than FAR_DELETE_BLOCKS bricks is
## not made: cut out and gone, on every machine (user, 2026-10-06 -- a far
## collapse is still physics, and is made cheap by rule). Eight and under went
## already where a machine's own camera was far (SMALL_KEEP_RANGE); this is the
## host's word, so a piece of nine that is landmark-sized goes for everybody
## too. FRACTURE_RANGE is "far", as it is for a landing.
const FAR_DELETE_BLOCKS := 10
var far_small_deleted := [0, 0]   ## pieces, bricks


func _far_and_small(chunk: int, ids: PackedInt32Array) -> bool:
	if not decides or ids.size() >= FAR_DELETE_BLOCKS:
		return false
	var points := interest_points()
	if points.is_empty():
		return false
	return _nearest_interest(_sample_centre(chunk, ids), points) > FRACTURE_RANGE


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
	# What lay on these bricks lies on nothing once they leave.
	if heap != null and heap.count > 0:
		_heap_support_gone(_group_box(source, block_ids))
	# The host said it goes (MAX_MOVING): cut out and let go, as every other
	# machine does with the same DETACH.
	if _gone_pieces.has(piece_id):
		var why = _gone_pieces[piece_id]
		_gone_pieces.erase(piece_id)
		var cut: Dictionary = world.split_island(source, block_ids)
		if not cut.is_empty():
			world.release_chunk(int(cut.chunk))
		if why is StringName and why == &"far":
			far_small_deleted[0] += 1
			far_small_deleted[1] += block_ids.size()
		else:
			spawn_census.capped[0] += 1
			spawn_census.capped[1] += block_ids.size()
		return null
	# Measured while the blocks are still in the source: the size decides both
	# whether it becomes a body at all and what kind of body it is.
	var landmark := group_is_landmark(source, block_ids)
	var crumbled_as: int = CRUMB_NOT
	if _crumbled_pieces.has(piece_id):
		_crumbled_pieces.erase(piece_id)
		crumbled_as = _crumble(source, block_ids, inherit_linear, LANDMARK_COUNT)
		if crumbled_as == CRUMB_NOT:
			# Its DETACH said gone: out it goes, drawn or not.
			var cut: Dictionary = world.split_island(source, block_ids)
			if not cut.is_empty():
				world.release_chunk(int(cut.chunk))
			crumbled_as = CRUMB_GONE
	elif not landmark:
		crumbled_as = _crumble(source, block_ids, inherit_linear)
	if crumbled_as == CRUMB_DRAWN:
		spawn_census.crumbled[0] += 1
		spawn_census.crumbled[1] += block_ids.size()
		return null
	if crumbled_as == CRUMB_GONE:
		spawn_census.deleted[0] += 1
		spawn_census.deleted[1] += block_ids.size()
		return null
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
	spawn_last = _w
	if float(_w[0]) > float(spawn_worst[0]):
		spawn_worst = _w
	_census_body(isl, ("piece: " + (_shed_cause if _shed_cause != "" else "other"))
			if _shedding else "building", count, float(_w[0]))
	piece_spawned.emit(isl)
	return isl


# ---------------------------------------------------------------------------
# Crumbs: a small piece is not a body
# ---------------------------------------------------------------------------

## A piece of DEBRIS_MAX_BLOCKS or fewer -- a brick, a handful, a floor panel on
## its own -- is not made a piece at all. Each brick is drawn from the shared
## brick MultiMesh of its size (as a lone brick piece always was), given the
## piece's velocity, a little away from the building it came off, and gravity;
## it stops on the floor one ray found under it when it broke, and shrinks away
## over CRUMB_LIFE_MS. No grid, no body, no shapes, no contacts: it was all of
## those, for something that was swept up a second after it landed (DEBRIS_
## UNSEEN_MS), that people walk through (Layers.PAWN_MASK) and that is each
## machine's own anyway (the class notes). And outside SMALL_KEEP_RANGE or out
## of view it was deleted where it came loose, the 569 of a big collapse that
## just vanished (--diag census, 2026-09-30): in view now, every one falls.
##
## Not a piece of nothing but furniture (_delete_where_it_is has a rule for
## that), and not inside a tornado's reach (windy): the wind lifts small pieces
## and throws them, and a crumb only falls.
const CRUMB_LIFE_MS := 1400
## Full size this long, then shrinking to nothing at CRUMB_LIFE_MS.
const CRUMB_FULL_MS := 350
## m/s: away from its building, at most -- off the face it came from.
const CRUMB_KICK := 1.2
## m/s: each brick's own on top of that, so a handful comes apart as it falls.
const CRUMB_SCATTER := 0.6
## rad/s at most.
const CRUMB_SPIN := 5.0
## Bricks drawn as crumbs at once. Past it a piece just goes, as one out of
## view does: the update is about a microsecond a brick, on the main thread.
## 600 was for pieces of eight; what comes off a piece crumbles up to
## LANDMARK_COUNT (_crumbles_off_a_piece).
const CRUMBS_MAX := 1500
const CRUMB_FLOOR_MASK := Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS
## A crumb's floor asked again on landing (_crumb_floor_gone), from this far
## over where it was; lower by more than the slack, it had gone.
const CRUMB_FLOOR_RECHECK := 0.3
const CRUMB_FLOOR_SLACK := 0.05
## **Plastic clatters** (Docs/CollapseNext.md 1.10 (4)). A crumb that comes down
## faster than CRUMB_REST_SPEED bounces: up at `crumb_bounce` of the speed it came
## down at, along at CRUMB_SLIDE of what it had, turning still; slower, it stops
## where it is. A crumb is a brick or a handful -- light, hard, and what a blast
## throws -- so it is the one thing that bounces. A section coming down is not:
## its landing is spent breaking it (fracture_on_impact), and one that sprang back
## up would land, and break, again.
## Feel numbers: Options > Gameplay, "Brick Bounce (Developer)" (crumb_bounce).
const CRUMB_BOUNCE := 0.25
const CRUMB_BOUNCE_MAX := 0.8
const CRUMB_REST_SPEED := 1.5
const CRUMB_SLIDE := 0.5
static var crumb_bounce := CRUMB_BOUNCE
var crumb_bounces := 0   ## times a crumb bounced

## **A blast destroys the middle of what it reaches and throws the rest out**
## (Docs/CollapseNext.md 1.10 (3); BrickFailure.md 5 -- bricks separate, they do
## not vanish). Every brick a blast killed was there in one frame and not in the
## next. Now only those whose middle is within this much of its radius are --
## that is the round going through -- and the ring round them leaves as crumbs,
## thrown from the hole (throw_killed).
##
## The STRUCTURE is what it was to the brick: they are dead in the grid the
## moment the blast lands, so the damage log, a replay, a save and a client's
## world are unchanged. Knocked loose instead, each would be a group of one for
## the next solve to find, a command to record and a grid to cut out and free,
## thirty times a blast, to end as the same crumb (DEBRIS_MAX_BLOCKS).
const BLAST_CORE := 0.5
## m/s off the face at most (CRUMB_KICK is a brick that only let go), and up to
## three fifths of it again away from the middle of the blast.
const BLAST_THROW := 3.0
## m/s for the brick a gun's last round knocks off: enough to be out of the wall
## before it has sunk into the course under it.
const CHIP_THROW := 1.8
## Crumbs one blast throws at most: past it, every so-manyth brick of the ring.
const BLAST_CRUMBS_MAX := 48
## A thrown brick that is out past the face of the hole before it has dropped
## this far below what is under the hole comes down outside (_add_crumbs): a
## course, so the bottom row of a ring leaves over the sill it stood on.
const CRUMB_SILL := 0.45
## Structural bricks blasts and guns have killed: all of them; those in a core;
## those thrown as crumbs; and those not drawn -- too far, out of view, in a
## wind, no room (CRUMBS_MAX, BLAST_CRUMBS_MAX).
var blast_census := [0, 0, 0, 0, 0, 0, 0]
## What throwing them cost: ms all told, and the worst blast.
var blast_throw_ms := [0.0, 0.0]

class Crumbs:
	var mmi: MultiMeshInstance3D
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var base: Array[Basis] = []
	var axis := PackedVector3Array()
	var rate := PackedFloat32Array()
	## Physics ticks, not milliseconds: it moves a tick at a time, and a hitch
	## must not shrink it away before it has fallen.
	var born := PackedInt64Array()
	var landed := PackedInt64Array()      ## the tick it stopped on its floor, 0 while falling
	var floor_y := PackedFloat32Array()
	var half_h := PackedFloat32Array()
	var colour := PackedColorArray()
	## Its floor is the ground itself (Layers.WORLD), which nothing takes away:
	## what the ray that found the floor hit (_crumb_floor), kept for the heap.
	var on_ground := PackedByteArray()

	func remove(i: int) -> void:
		var last := pos.size() - 1
		if i != last:
			pos[i] = pos[last]
			vel[i] = vel[last]
			base[i] = base[last]
			axis[i] = axis[last]
			rate[i] = rate[last]
			born[i] = born[last]
			landed[i] = landed[last]
			floor_y[i] = floor_y[last]
			half_h[i] = half_h[last]
			colour[i] = colour[last]
			on_ground[i] = on_ground[last]
		pos.resize(last)
		vel.resize(last)
		base.resize(last)
		axis.resize(last)
		rate.resize(last)
		born.resize(last)
		landed.resize(last)
		floor_y.resize(last)
		half_h.resize(last)
		colour.resize(last)
		on_ground.resize(last)

var _crumbs := {}            ## brick size, snapped -> Crumbs
## Where a crumb goes when it comes to rest, while BrickHeap.max_bricks is not 0:
## the bricks a collapse leaves lying (BrickHeap).
var heap: BrickHeap
## While bricks are kept, a crumb is not shrunk away a second and a half after
## it came loose: it falls until it lands, for this long at most, and fades in
## the last CRUMB_FADE_MS of that (one that found no floor).
const CRUMB_FALL_MAX_MS := 6000
const CRUMB_FADE_MS := 600
## What lay on top of something that goes is within this far above it.
const HEAP_LIFT := 0.8
## Bricks one event hands back to fall again; past it the rest are just gone.
const HEAP_FALL_MAX := 64
var _crumbled_pieces := {}   ## piece id -> true: its DETACH said gone, and it crumbles
var crumb_count := 0         ## bricks drawn as crumbs now
var crumbled := 0            ## pieces that went as crumbs
var crumb_bricks := 0        ## bricks that were drawn as crumbs
var crumbs_over := 0         ## bricks not drawn for CRUMBS_MAX
var crumb_worst_ms := 0.0    ## the slowest tick of _update_crumbs
var crumb_update_ms := 0.0   ## _update_crumbs, all told
var lay_us := 0              ## of that, laying crumbs that stopped in the heap (BrickHeap)
var crumb_peak := 0          ## the most drawn at once
var crumble_worst_ms := 0.0  ## the slowest single _crumble
var crumble_parts := [0.0, 0.0, 0.0]  ## ms, all told: drawing, cutting out, deciding
var _wind := {}              ## who -> [centre, radius, until msec]: windy()


## Somewhere the wind is lifting small pieces (a tornado, Disasters): for `ms`,
## a small piece that comes loose within `radius` of `centre` stays a body, so
## the wind has something to lift. `who` is the caller's, so one wind is one
## entry however often it says so.
func windy(who: int, centre: Vector3, radius: float, ms: int) -> void:
	_wind[who] = [centre, radius, Time.get_ticks_msec() + ms]


func _in_wind(box: AABB) -> bool:
	if _wind.is_empty():
		return false
	var now := Time.get_ticks_msec()
	var c := box.get_center()
	for who in _wind.keys():
		var w: Array = _wind[who]
		if int(w[2]) < now:
			_wind.erase(who)
			continue
		var d := Vector2(c.x - (w[0] as Vector3).x, c.z - (w[0] as Vector3).z).length()
		if d < float(w[1]) + box.size.length() * 0.5:
			return true
	return false


## What _crumble did: nothing (not a small piece), drew it as crumbs, or took
## it out with nothing drawn (far, or out of view, or CRUMBS_MAX).
enum { CRUMB_NOT, CRUMB_DRAWN, CRUMB_GONE }


## Crumble a small piece if it is one: out of its source, and drawn as crumbs if
## it can be seen. CRUMB_NOT, and nothing done, for anything else.
func _crumble(source: int, block_ids: PackedInt32Array, linear: Vector3,
		limit := DEBRIS_MAX_BLOCKS) -> int:
	var n := block_ids.size()
	if n == 0 or n > limit:
		return CRUMB_NOT
	var furniture := true
	for id in block_ids:
		if not world.is_block_decorative(source, id):
			furniture = false
			break
	if furniture:
		return CRUMB_NOT
	var box := _group_box(source, block_ids)
	# Decided already when the DETACH said so (_crumbles_off_a_piece): the wind
	# was asked then, and the blocks have to go now either way.
	if limit == DEBRIS_MAX_BLOCKS and _in_wind(box):
		return CRUMB_NOT
	var t0 := Time.get_ticks_usec()
	var dist := INF
	if camera != null and is_instance_valid(camera):
		dist = _distance_to_box(box, camera.global_position)
	var far := dist > SMALL_KEEP_RANGE and dist < INF
	var shown := not far and _box_seen(box)
	if shown and crumb_count + n > CRUMBS_MAX:
		crumbs_over += n
		shown = false
	var t_add := Time.get_ticks_usec()
	if shown:
		_add_crumbs(source, block_ids, box, linear)
		crumbled += 1
	elif far:
		tiny_deleted += n
	else:
		discarded += n
	crumble_parts[0] += float(Time.get_ticks_usec() - t_add) / 1000.0
	# Out of the source the way every piece goes, and the grid it was given
	# freed at once (_delete_where_it_is says why not killed in place).
	var t_cut := Time.get_ticks_usec()
	var cut: Dictionary = world.split_island(source, block_ids)
	if not cut.is_empty():
		world.release_chunk(int(cut.chunk))
	crumble_parts[1] += float(Time.get_ticks_usec() - t_cut) / 1000.0
	crumble_parts[2] += float(t_add - t0) / 1000.0
	crumble_worst_ms = maxf(crumble_worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)
	return CRUMB_DRAWN if shown else CRUMB_GONE


## What a blast or a gun has just killed in `source`, thrown out of it
## (BLAST_CORE). `killed` is still in the grid -- dead, not yet cut out -- which
## is where each brick's place, size and colour are read from. `at` and `radius`
## are the blast's, in the world; `chip` is a gun's wear, which destroys nothing
## and knocks every brick it finishes off whole. `linear` is what the source was
## doing, for a piece on the move. Draws; changes nothing in the world.
func throw_killed(source: int, killed: PackedInt32Array, at: Vector3, radius: float,
		chip := false, linear := Vector3.ZERO) -> void:
	if killed.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	_throw_killed(source, killed, at, radius, chip, linear)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	blast_throw_ms[0] += ms
	blast_throw_ms[1] = maxf(blast_throw_ms[1], ms)


func _throw_killed(source: int, killed: PackedInt32Array, at: Vector3, radius: float,
		chip: bool, linear: Vector3) -> void:
	var xf: Transform3D = world.get_chunk_transform(source)
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var core := 0.0 if chip else radius * BLAST_CORE
	var ring := PackedInt32Array()
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var bricks := 0
	for id in killed:
		# Furniture is not thrown: a lone block of it is a blank cube (_crumble).
		if world.is_block_decorative(source, id):
			continue
		var t: Array = world.get_block_ticks(source, id)
		if t.is_empty():
			continue
		bricks += 1
		var p: Vector3 = xf * ((Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m)
		if p.distance_to(at) < core:
			continue
		ring.append(id)
		lo = lo.min(p)
		hi = hi.max(p)
	blast_census[0] += bricks
	blast_census[1] += bricks - ring.size()
	if ring.is_empty():
		return
	# This machine's own, as every crumb is: near enough, in view, out of the
	# wind (a tornado's chips are the tornado's to draw), and room for them.
	var box := AABB(lo, hi - lo).grow(0.25)
	var dist := INF
	if camera != null and is_instance_valid(camera):
		dist = _distance_to_box(box, camera.global_position)
	if dist > SMALL_KEEP_RANGE and dist < INF:
		blast_census[3] += ring.size()
		return
	if not _box_seen(box):
		blast_census[4] += ring.size()
		return
	if _in_wind(box):
		blast_census[5] += ring.size()
		return
	if ring.size() > BLAST_CRUMBS_MAX:
		# A big charge: every so-manyth brick, all the way round.
		var step := ceili(float(ring.size()) / float(BLAST_CRUMBS_MAX))
		var some := PackedInt32Array()
		for i in range(0, ring.size(), step):
			some.append(ring[i])
		blast_census[6] += ring.size() - some.size()
		ring = some
	if crumb_count + ring.size() > CRUMBS_MAX:
		crumbs_over += ring.size()
		blast_census[6] += ring.size()
		return
	_add_crumbs(source, ring, box, linear, at, CHIP_THROW if chip else BLAST_THROW)
	blast_census[2] += ring.size()


## Drawn furniture that broke (CityScene._break_items): items, and the parts of
## them thrown as crumbs.
var furniture_broken := [0, 0]


## A piece of drawn furniture breaks: each row of its drawing -- FurnitureMesh's
## layout, a part of it in `xf`'s space -- is thrown as a crumb of that part's
## size and colour from where it stood, away from `at` at up to `speed` m/s,
## and comes down on the floor under it. Drawn only, and this machine's own,
## like every crumb (none far, unseen, in a wind, or past CRUMBS_MAX).
## Returns how many were thrown.
func throw_rows(rows: PackedFloat32Array, xf: Transform3D, at: Vector3, speed: float) -> int:
	@warning_ignore("integer_division")
	var n := rows.size() / 16
	if n == 0:
		return 0
	furniture_broken[0] += 1
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for r in n:
		var p: Vector3 = xf * Vector3(rows[r * 16 + 3], rows[r * 16 + 7], rows[r * 16 + 11])
		lo = lo.min(p)
		hi = hi.max(p)
	var box := AABB(lo, hi - lo).grow(0.25)
	var dist := INF
	if camera != null and is_instance_valid(camera):
		dist = _distance_to_box(box, camera.global_position)
	if (dist > SMALL_KEEP_RANGE and dist < INF) or not _box_seen(box) or _in_wind(box) \
			or crumb_count + n > CRUMBS_MAX:
		return 0
	# It stood on a floor: one ray from under its middle finds it.
	var floor_y := _crumb_floor(Vector3(box.get_center().x, box.position.y, box.get_center().z))
	var fixed := 1 if _floor_on_ground else 0
	var frame_basis := xf.basis.orthonormalized()
	var now := Engine.get_physics_frames()
	for r in n:
		var k := r * 16
		var size := Vector3(absf(rows[k]), absf(rows[k + 5]), absf(rows[k + 10]))
		var p: Vector3 = xf * Vector3(rows[k + 3], rows[k + 7], rows[k + 11])
		var cr := _crumb_set(size.snapped(Vector3.ONE * 0.001))
		var away := p - at
		away = away.normalized() if away.length() > 0.01 else Vector3.UP
		var axis := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		cr.pos.append(p)
		cr.vel.append(away * speed * randf_range(0.3, 1.0) + Vector3(randf_range(-1.0, 1.0),
				randf_range(0.0, 1.0), randf_range(-1.0, 1.0)) * CRUMB_SCATTER)
		cr.base.append(frame_basis)
		cr.axis.append(axis.normalized() if axis.length() > 0.01 else Vector3.UP)
		cr.rate.append(randf_range(-CRUMB_SPIN, CRUMB_SPIN))
		cr.born.append(now)
		cr.landed.append(0)
		cr.floor_y.append(floor_y)
		cr.half_h.append(size.y * 0.5)
		cr.colour.append(Color(rows[k + 12], rows[k + 13], rows[k + 14], rows[k + 15]))
		cr.on_ground.append(fixed)
		crumb_count += 1
		crumb_bricks += 1
	furniture_broken[1] += n
	return n


func blast_census_line() -> String:
	return "bricks blasts and guns killed: %d -- %d in a core and gone, %d thrown out as crumbs; not drawn: %d too far, %d out of view, %d in a wind, %d for want of room; throwing them %.1f ms all told, %.2f the worst blast" % [
			blast_census[0], blast_census[1], blast_census[2], blast_census[3], blast_census[4],
			blast_census[5], blast_census[6], blast_throw_ms[0], blast_throw_ms[1]]


func crumb_cost_line() -> String:
	return "crumbs of every kind: %d at once at the most, moving them %.1f ms all told (laying the ones that stopped %.1f), %.2f the worst tick" % [
			crumb_peak, crumb_update_ms, float(lay_us) / 1000.0, crumb_worst_ms]


## `burst` and `throw`: thrown from a blast at `burst` (throw_killed) -- `throw`
## m/s off the face at most instead of CRUMB_KICK, and each brick its own way
## from the middle of the blast as well.
func _add_crumbs(source: int, block_ids: PackedInt32Array, box: AABB, linear: Vector3,
		burst := Vector3.ZERO, throw := 0.0) -> void:
	var xf: Transform3D = world.get_chunk_transform(source)
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var centre := box.get_center()
	# Off the face it came from: away from the middle of its source's grid.
	var mid: Vector3 = xf * (Vector3(world.get_chunk_dims(source)) * BrickWorld.get_cell_size() * 0.5)
	var out := Vector3(centre.x - mid.x, 0.0, centre.z - mid.z)
	var out_dir := out.normalized() if out.length() > 0.01 else Vector3.ZERO
	# A blast's are out of the wall before they have dropped a brick's height:
	# slower, they sank through the wall under the hole on the way.
	var kick := out_dir * (randf_range(0.6, 1.0) * throw if throw > 0.0
			else randf_range(0.3, 1.0) * CRUMB_KICK)
	# Where it comes down: one ray, from where the kick takes it, down onto the
	# ground, a building or settled wreckage -- not onto anything still falling.
	var floor_y := -INF
	# A blast's ring reaches metres into a building, and is thrown harder: one
	# floor for all of it had the bricks that cleared the wall lying in the air
	# beside the hole, at the height of the storey's floor. So two rays: what
	# is under the hole, and what is under the air a metre past its face. A
	# brick that is out past the face before it has dropped CRUMB_SILL below
	# the first comes down on the second.
	var floor_past := -INF
	var fixed_y := 0
	var fixed_past := 0
	var face := INF
	var g := 0.0
	if throw > 0.0:
		floor_y = _crumb_floor(Vector3(centre.x, box.position.y, centre.z))
		fixed_y = 1 if _floor_on_ground else 0
		if out_dir != Vector3.ZERO:
			var reach := (absf(out_dir.x) * box.size.x + absf(out_dir.z) * box.size.z) * 0.5
			face = centre.dot(out_dir) + reach
			floor_past = _crumb_floor(Vector3(centre.x, box.end.y, centre.z) + out_dir * (reach + 1.0))
			fixed_past = 1 if _floor_on_ground else 0
		g = Gravity.strength() * DEBRIS_GRAVITY
	else:
		floor_y = _crumb_floor(centre + kick * 0.4)
		fixed_y = 1 if _floor_on_ground else 0
	var frame_basis := xf.basis.orthonormalized()
	var now := Engine.get_physics_frames()
	for id in block_ids:
		if world.is_block_decorative(source, id):
			continue
		var t: Array = world.get_block_ticks(source, id)
		if t.is_empty():
			continue
		var size := Vector3(t[1] as Vector3i) * tick_m
		var local := (Vector3(t[0] as Vector3i) + Vector3(t[1] as Vector3i) * 0.5) * tick_m
		var cr := _crumb_set(size.snapped(Vector3.ONE * 0.001))
		var axis := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		var from_blast := Vector3.ZERO
		if throw > 0.0:
			var away: Vector3 = xf * local - burst
			if away.length() > 0.01:
				from_blast = away.normalized() * throw * randf_range(0.2, 0.6)
		var at: Vector3 = xf * local
		var vel := linear + kick + from_blast + Vector3(randf_range(-1.0, 1.0),
				randf_range(0.0, 1.0), randf_range(-1.0, 1.0)) * CRUMB_SCATTER
		var lands_on := floor_y
		var lands_fixed := fixed_y
		if face < INF:
			var speed_out := vel.dot(out_dir)
			var to_face := face - at.dot(out_dir)
			if floor_y == -INF or to_face <= 0.0:
				lands_on = floor_past
				lands_fixed = fixed_past
			elif speed_out > 0.05:
				# How far it has dropped by the time it is out past the face.
				var clear := to_face / speed_out
				var foot := at.y - size.y * 0.5 + vel.y * clear - 0.5 * g * clear * clear
				if foot > floor_y - CRUMB_SILL:
					lands_on = floor_past
					lands_fixed = fixed_past
		cr.pos.append(at)
		cr.vel.append(vel)
		cr.base.append(frame_basis)
		cr.axis.append(axis.normalized() if axis.length() > 0.01 else Vector3.UP)
		cr.rate.append(randf_range(-CRUMB_SPIN, CRUMB_SPIN))
		cr.born.append(now)
		cr.landed.append(0)
		cr.floor_y.append(lands_on)
		cr.half_h.append(size.y * 0.5)
		cr.colour.append(BrickWorld.get_filament_colour(world.get_block_colour(source, id)))
		cr.on_ground.append(lands_fixed)
		crumb_count += 1
		crumb_bricks += 1


## The first thing under `from` a crumb stops on, or -INF. Whether that was
## the ground itself (Layers.WORLD) is left in _floor_on_ground.
func _crumb_floor(from: Vector3) -> float:
	_floor_on_ground = false
	if not is_inside_tree():
		return -INF
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 300.0,
			CRUMB_FLOOR_MASK)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return -INF
	_floor_on_ground = hit.collider is CollisionObject3D 			and ((hit.collider as CollisionObject3D).collision_layer & Layers.WORLD) != 0
	return (hit.position as Vector3).y


var _floor_on_ground := false
var crumb_floors_gone := 0   ## crumbs whose floor had gone when they reached it


## A crumb's floor is asked once, when it comes loose, and a fall takes a
## second or more: what it was going to land on may have gone meanwhile -- the
## storey a blast's ring came down on breaking off and falling as a section,
## a settled piece woken. It was laid where that floor had been, in mid-air,
## and lay there for good (user, 2026-10-17: "single bricks ... settle on a
## falling part of a building then stay there floating"). So on reaching it the
## floor is asked again, from a little above: gone or lower, the crumb falls on
## to the new one. True when it does.
func _crumb_floor_gone(cr: Crumbs, i: int, p: Vector3) -> bool:
	var was := cr.floor_y[i]
	if not is_finite(was):
		return false
	var now_y := _crumb_floor(Vector3(p.x, was + CRUMB_FLOOR_RECHECK, p.z))
	if now_y >= was - CRUMB_FLOOR_SLACK:
		return false
	cr.floor_y[i] = now_y
	cr.on_ground[i] = 1 if _floor_on_ground else 0
	crumb_floors_gone += 1
	return true


func _crumb_set(key: Vector3) -> Crumbs:
	if _crumbs.has(key):
		return _crumbs[key]
	var cr := Crumbs.new()
	var mmi := MultiMeshInstance3D.new()
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.chamfered_box(key)
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mmi.material_override = mat
	add_child(mmi)
	cr.mmi = mmi
	_crumbs[key] = cr
	return cr


## Fall, stop on the floor, shrink, go. Once a tick, after the pieces.
func _update_crumbs() -> void:
	if _crumbs.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var now := Engine.get_physics_frames()
	var tps := float(Engine.physics_ticks_per_second)
	var dt := 1.0 / tps
	var life := int(CRUMB_LIFE_MS * tps / 1000.0)
	var full := int(CRUMB_FULL_MS * tps / 1000.0)
	var g := Gravity.strength() * DEBRIS_GRAVITY
	var keep := heap != null and BrickHeap.enabled()
	var fall_max := int(CRUMB_FALL_MAX_MS * tps / 1000.0)
	var fade := maxi(int(CRUMB_FADE_MS * tps / 1000.0), 1)
	for key in _crumbs:
		var cr: Crumbs = _crumbs[key]
		var i := 0
		while i < cr.pos.size():
			var age := now - cr.born[i]
			# Come to rest: it lies where it stopped, for good (BrickHeap).
			if keep and cr.landed[i] > 0:
				var t_lay := Time.get_ticks_usec()
				_lay_crumb(cr, i, key, dt)
				lay_us += Time.get_ticks_usec() - t_lay
				cr.remove(i)
				crumb_count -= 1
				continue
			if age >= (fall_max if keep else life):
				cr.remove(i)
				crumb_count -= 1
				continue
			# Handed back by the heap: its floor is asked once what took the old
			# one has had its tick to go (_heap_support_gone).
			if is_nan(cr.floor_y[i]) and age >= 2:
				cr.floor_y[i] = _crumb_floor(cr.pos[i])
				cr.on_ground[i] = 1 if _floor_on_ground else 0
			if cr.landed[i] == 0:
				var v := cr.vel[i]
				v.y -= g * dt
				var p := cr.pos[i] + v * dt
				if p.y - cr.half_h[i] <= cr.floor_y[i] and not _crumb_floor_gone(cr, i, p):
					p.y = cr.floor_y[i] + cr.half_h[i]
					if -v.y * crumb_bounce > CRUMB_REST_SPEED:
						v = Vector3(v.x * CRUMB_SLIDE, -v.y * crumb_bounce, v.z * CRUMB_SLIDE)
						crumb_bounces += 1
					else:
						cr.landed[i] = now
				cr.pos[i] = p
				cr.vel[i] = v
			i += 1
		var mm := cr.mmi.multimesh
		var count := cr.pos.size()
		if mm.instance_count != count:
			mm.instance_count = count
		for j in count:
			var age := now - cr.born[j]
			var s := 1.0
			if keep:
				if age > fall_max - fade:
					s = maxf(float(fall_max - age) / float(fade), 0.01)
			elif age > full:
				s = maxf(1.0 - float(age - full) / float(life - full), 0.01)
			# It stops turning when it stops falling.
			var turned := (cr.landed[j] if cr.landed[j] > 0 else now) - cr.born[j]
			var b := Basis(cr.axis[j], cr.rate[j] * float(turned) * dt) * cr.base[j]
			mm.set_instance_transform(j, Transform3D(b.scaled(Vector3(s, s, s)), cr.pos[j]))
			mm.set_instance_color(j, cr.colour[j])
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	crumb_worst_ms = maxf(crumb_worst_ms, ms)
	crumb_update_ms += ms
	crumb_peak = maxi(crumb_peak, crumb_count)


## A crumb that has come to rest, laid in the heap: flat on whichever of its
## faces was most nearly down (_lie_flat), on the floor it stopped on.
func _lay_crumb(cr: Crumbs, i: int, size: Vector3, dt: float) -> void:
	if not is_finite(cr.floor_y[i]):
		return
	var turned := cr.landed[i] - cr.born[i]
	var b := Basis(cr.axis[i], cr.rate[i] * float(turned) * dt) * cr.base[i]
	var flat := _lie_flat(b, size)
	var p := cr.pos[i]
	# On the floor it came down on, or on what already lies there (a pile).
	p.y = heap.base_for(size, flat[0] as Basis, p, cr.floor_y[i]) + size[int(flat[1])] * 0.5
	heap.lay(size, Transform3D(flat[0] as Basis, p), cr.colour[i], cr.floor_y[i],
			cr.on_ground[i] != 0, _laid_on(p, cr.floor_y[i], size[int(flat[1])] * 0.5) if BrickHeap.track else "")


## What a brick laid at `p` came down on, said for BrickHeap.track: the body
## under it -- a piece, the ground, a body with no node (a building's bricks or
## its shell) -- and the floor it was laid for.
func _laid_on(p: Vector3, floor_y: float, half: float) -> String:
	var q := PhysicsRayQueryParameters3D.create(p, p + Vector3.DOWN * 300.0, CRUMB_FLOOR_MASK)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var under := "nothing"
	if not hit.is_empty():
		var isl := find_by_body(hit.collider) if hit.collider is Node else null
		if isl != null:
			under = "piece of chunk %d (%s)" % [isl.chunk, "settled" if isl.settled else "moving"]
		elif hit.collider is CollisionObject3D:
			under = "%s, layer %d" % [(hit.collider as Node).name, (hit.collider as CollisionObject3D).collision_layer]
		else:
			under = "a body with no node"
		under += " %.2f m under its foot" % (p.y - half - (hit.position as Vector3).y)
	return "on %s; its floor %.2f m under it" % [under, p.y - half - floor_y]


## `b` turned to lie on a face: the axis it comes down on made vertical, the
## next one levelled, which way it pointed kept. [basis, that axis]. Which face:
## the most nearly down, weighed by how thin the brick is that way -- a brick
## comes to rest on a broad face, and stands on its end only when it came down
## very nearly upright (one in five of a heap stood on end, weighed by the
## angle alone).
static func _lie_flat(b: Basis, size := Vector3.ONE) -> Array:
	var cols: Array[Vector3] = [b.x.normalized(), b.y.normalized(), b.z.normalized()]
	var up := 0
	var best := -1.0
	for k in 3:
		var score := absf(cols[k].y) / maxf(size[k], 0.001)
		if score > best:
			best = score
			up = k
	var a := (up + 1) % 3
	var m := (up + 2) % 3
	cols[up] = Vector3.UP if cols[up].y >= 0.0 else Vector3.DOWN
	var h := Vector3(cols[a].x, 0.0, cols[a].z)
	cols[a] = h.normalized() if h.length() > 0.001 else Vector3.RIGHT
	# Right-handed: the axis after next is this one across the next.
	cols[m] = cols[up].cross(cols[a])
	return [Basis(cols[0], cols[1], cols[2]), up]


## What lay on something that has gone falls again: the heap's bricks inside
## `box` and up to HEAP_LIFT over it are handed back as crumbs, their floor
## asked again a couple of ticks on (by when what went has gone from the
## physics too). The first HEAP_FALL_MAX fall; the rest are just gone.
func _heap_support_gone(box: AABB) -> void:
	if heap == null or heap.count == 0 or box.size == Vector3.ZERO:
		return
	var reach := box.grow(RIPPLE_MARGIN)
	reach.size.y += HEAP_LIFT
	var lying := heap.take_in(reach)
	if lying.is_empty():
		return
	heap.handed_back += lying.size()
	var now := Engine.get_physics_frames()
	for k in mini(lying.size(), HEAP_FALL_MAX):
		if crumb_count >= CRUMBS_MAX:
			break
		var size: Vector3 = lying[k][0]
		var xf: Transform3D = lying[k][1]
		var b := xf.basis
		var cr := _crumb_set(size)
		var axis := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
		cr.pos.append(xf.origin)
		cr.vel.append(Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)))
		cr.base.append(b)
		cr.axis.append(axis.normalized() if axis.length() > 0.01 else Vector3.UP)
		cr.rate.append(randf_range(-1.5, 1.5))
		cr.born.append(now)
		cr.landed.append(0)
		cr.floor_y.append(NAN)
		cr.on_ground.append(0)
		cr.half_h.append(0.5 * (absf(b.x.y) * size.x + absf(b.y.y) * size.y + absf(b.z.y) * size.z))
		cr.colour.append(lying[k][2])
		crumb_count += 1


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
## building was the 285 ms tick. Or AT REST: a piece that is hit where it lies
## stays where it lies (damage), frozen, and frozen it is merged.
func _ensure_per_block(isl: BrickIsland) -> void:
	if isl.merged and (isl.fly_merged or isl.settled):
		if not isl.reshape_due:
			isl.reshape_due = true
			_reshape_list.append(isl)
		return
	if isl.merged:
		_reshape(isl, false)


## A piece in the air has its collision rebuilt after a change at most this
## often. It collides with nothing while it falls but what it lands on
## (Layers.AIRBORNE_MASK), and the rebuild is the whole piece's boxes -- 7 ms
## for 15,000 bricks -- so a section shot at on its way down was rebuilt every
## tick it was hit: 20 ms of the worst `islands.tick` once sections stopped
## shattering in the air (solve_island) and stayed big. Until the rebuild its
## boxes are a fifth of a second behind its bricks: a bullet can stop on a
## brick a blast just took. The tick it lands it is rebuilt at once.
const AIR_RESHAPE_TICKS := 12
## And one that is down but still moving, this often: what rests on it is
## resting on its boxes, so less slack than a piece in the air gets -- a tenth
## of a second. 900-1,300 rebuilds a `--big --shot`, nearly all of them of
## pieces on the ground being hit tick after tick.
const MOVING_RESHAPE_TICKS := 6
var reshapes_put_off := 0


## Rebuild, merged, every merged piece whose blocks changed -- falling, or hit
## where it lay at rest (settle_now clears what settling has already rebuilt).
## A merged rebuild that has waited this long past its turn is made whatever
## else the tick has done (_flush_reshapes): half a second of a piece colliding
## with bricks it has lost, at the most.
const RESHAPE_OVERDUE_TICKS := 15


## The merged rebuilds that are due, oldest first, while the tick's work budget
## lasts (WORK_BUDGET_MS) -- and one that is overdue whatever. They were all
## made in the tick they fell due: a big wreck's is 9.5 ms on its own (20,608
## bricks, 2,626 boxes), and two or three in the tick a collapse was spawning
## and being shot made the worst ticks of --big --shot (2026-10-15).
func _flush_reshapes() -> void:
	var later: Array[BrickIsland] = []
	var now := Engine.get_physics_frames()
	var due: Array[BrickIsland] = []
	for isl in _reshape_list:
		if not isl.is_valid() or not isl.reshape_due:
			continue
		if now - isl.reshaped_tick < (MOVING_RESHAPE_TICKS if isl.landed else AIR_RESHAPE_TICKS):
			later.append(isl)   # still due
			reshapes_put_off += 1
			continue
		due.append(isl)
	due.sort_custom(func(a: BrickIsland, b: BrickIsland) -> bool:
		return a.reshaped_tick < b.reshaped_tick)
	var overdue_done := false
	for isl in due:
		var waited := now - isl.reshaped_tick \
				- (MOVING_RESHAPE_TICKS if isl.landed else AIR_RESHAPE_TICKS)
		var overdue := waited >= RESHAPE_OVERDUE_TICKS and not overdue_done
		if not _has_work_time() and not overdue:
			later.append(isl)
			reshapes_spread += 1
			continue
		overdue_done = overdue_done or overdue
		isl.reshape_due = false
		isl.reshaped_tick = now
		_reshape(isl, true, true)
		merged_rebuilds += 1
	_reshape_list = later


var reshapes_spread := 0   ## rebuilds left for a later tick: this one had spent its budget
var harvests_spread := 0   ## finished meshes left for a later tick, the same


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
		isl.body.collision_mask = Layers.FALLING_MASK if isl.landed else Layers.AIRBORNE_MASK


## In the air, or come down on something? A piece in the air passes through
## other pieces in the air (Layers.AIRBORNE_MASK); the tick it has something
## under it -- a contact whose normal is near vertical, not a wall it is
## scraping down -- it lands, and what falls after it lands on it. Over an edge
## and falling with nothing touching it, it is in the air again.
func _note_landing(isl: BrickIsland) -> void:
	if not isl.landed:
		if isl.body.get_contact_count() == 0:
			return
		var st := PhysicsServer3D.body_get_direct_state(isl.body.get_rid())
		if st == null:
			return
		for i in st.get_contact_count():
			if absf(st.get_contact_local_normal(i).y) >= LANDED_NORMAL_Y:
				isl.landed = true
				isl.air_ticks = 0
				landings_noted += 1
				_apply_layers(isl)
				return
		return
	if isl.body.get_contact_count() == 0 and isl.body.linear_velocity.y < -IMPACT_MIN_SPEED:
		isl.air_ticks += 1
		if isl.air_ticks >= AIRBORNE_AGAIN_TICKS:
			isl.landed = false
			isl.jitter_since = 0
			_apply_layers(isl)
	else:
		isl.air_ticks = 0


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
		if near_tier != null:
			for si in isl.bands.size():
				if isl.bands[si] != null:
					near_tier.track(isl.bands[si], isl.chunk, si)
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
	_census_body(isl, "adopted (toppled whole, or woken)", world.get_alive_block_count(isl.chunk), 0.0)
	# What had settled on it wakes when it moves (ripple_pending, above) and
	# what it lands on when it touches (_wake_touched). Not everything within
	# six metres of it for being near: wreckage at rest stays at rest until
	# something is taken from under it (Docs/CollapseNext.md 1.10).
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
	# Something a patch cannot carry: build the one mesh an island uses. The
	# bands go on drawing until it is up (_apply_mesh): freed here, a toppled
	# tower that landed and broke was drawn by nothing while its new mesh was
	# baked and uploaded on a worker -- only its window glass was left (user,
	# 2026-10-26: "the entire building glassed and disappears for a second";
	# big_city --landing). Stale for those ticks, never empty.
	if not isl.bands.is_empty():
		isl.retiring_bands.append_array(isl.bands)
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
				and Engine.get_physics_frames() - isl.coarse_tick < coarse_wait(isl)
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
				if near_tier != null:
					near_tier.damaged(isl.chunk)
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
## A piece of this many bricks has its stand-in built on a worker
## (BrickWorld.coarse_chunk_async): a 5,000-7,000-brick chunk of a far collapse
## was 17-22 ms in one call from the mesh queue, the worst tick of most
## --big --shot runs. A smaller one is a millisecond or two and is built where
## it is asked for, as it was. The piece goes on drawing what it had until the
## worker is done (nothing, for a first stand-in: a tick or two, far off).
const COARSE_ASYNC_BLOCKS := 1500
var _coarse_jobs: Array[BrickIsland] = []
var coarse_async := 0            ## stand-ins built on a worker
var coarse_main_worst_ms := 0.0  ## the slowest stand-in built on the main thread


func _build_coarse(isl: BrickIsland) -> void:
	isl.coarse_tick = Engine.get_physics_frames()
	if world.get_alive_block_count(isl.chunk) >= COARSE_ASYNC_BLOCKS:
		if not world.coarse_pending(isl.chunk):
			world.coarse_chunk_async(isl.chunk)
			coarse_async += 1
		if not _coarse_jobs.has(isl):
			_coarse_jobs.append(isl)
		return
	var _t0 := Time.get_ticks_usec()
	var arrays: Array = world.build_chunk_coarse_mesh(isl.chunk)
	var _t1 := Time.get_ticks_usec()
	coarse_main_worst_ms = maxf(coarse_main_worst_ms, world.get_last_coarse_ms())
	_finish_coarse(isl, arrays)
	coarse_split = "built %.1f ms (%.1f of it the build's own) + %s" % [
			float(_t1 - _t0) / 1000.0, world.get_last_coarse_ms(), _finish_split]


## Where the time of the last stand-in built on the main thread went, for the
## mesh queue's slowest (_note_mesh_drain): one of 76 bricks took 216.6 ms in a
## --big --shot (2026-10-23), its build 1.1 ms at most.
var coarse_split := ""
var _finish_split := ""


## Attach the stand-ins the workers have finished.
func _harvest_coarse_jobs() -> void:
	var k := 0
	while k < _coarse_jobs.size():
		var isl: BrickIsland = _coarse_jobs[k]
		if not isl.is_valid():
			# Gone; releasing its chunk waited for the worker and dropped the job.
			_coarse_jobs.remove_at(k)
			continue
		if not world.coarse_ready(isl.chunk):
			# No job at all: a block placed or removed in it settled it
			# (BrickWorld.settle_coarse_job). Asked for again.
			if not world.coarse_pending(isl.chunk):
				_coarse_jobs.remove_at(k)
				if isl.coarse and not _mesh_queue.has(isl):
					isl.coarse_tick = -1000000
					_mesh_queue.append(isl)
				continue
			k += 1
			continue
		_coarse_jobs.remove_at(k)
		var arrays: Array = world.take_coarse_mesh(isl.chunk)
		if not isl.coarse:
			continue  # come near meanwhile: it draws its bricks now
		_finish_coarse(isl, arrays)
		# Its cost was a worker's, not this thread's: it waits only the plain
		# COARSE_REBUILD_TICKS before it may be built again (coarse_wait).
		isl.coarse_ms = 0.0


func _finish_coarse(isl: BrickIsland, arrays: Array) -> void:
	isl.coarse_ms = world.get_last_coarse_ms()
	coarse_built += 1
	coarse_worst_ms = maxf(coarse_worst_ms, isl.coarse_ms)
	var ok := not arrays.is_empty() and mesh_arrays_ok(arrays, "island %d (coarse)" % isl.chunk)
	# Every stand-in is uploaded on a worker, however small (THREAD_MESH_VERTS
	# is for the bricks). One handed to the renderer here waited for the other
	# workers' uploads: a 76-brick one 216.6 ms in a --big --shot, its build
	# 1.1 (2026-10-23) -- as the bands did (CityScene.BAND_THREAD_VERTS). It is
	# far off: a tick or two of the old mesh, or of none, is not seen.
	if ok:
		var verts := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		coarse_verts += verts
		if not _upload_ok(verts):
			isl.upload_waiting = true
			_upload_waiting.append([isl, arrays, true])
			uploads_waited += 1
			return
		_submit_mesh_job(isl, arrays, true)
		_finish_split = "to a worker"
		return
	var _t0 := Time.get_ticks_usec()
	var mesh := ArrayMesh.new()
	if ok:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var _t1 := Time.get_ticks_usec()
	_apply_mesh(isl, mesh, arrays, true)
	_finish_split = "surface %.1f + hung %.1f ms" % [float(_t1 - _t0) / 1000.0,
			float(Time.get_ticks_usec() - _t1) / 1000.0]


## Hang a finished mesh on a piece. `coarse`: it is the stand-in.
func _apply_mesh(isl: BrickIsland, mesh: ArrayMesh, arrays: Array, coarse := false) -> void:
	# Only a mesh that actually HAS a surface can be patched. A chunk with
	# nothing left alive produces no arrays, and patching surface 0 of an empty
	# ArrayMesh writes past the end of a buffer that is not there.
	isl.radius = _body_radius(isl)
	# The renderer may still be drawing the mesh this replaces.
	_retirer.retire(isl.mesh.mesh)
	_drop_retiring_bands(isl)
	isl.array_mesh = mesh if mesh != null and mesh.get_surface_count() > 0 else null
	isl.coarse_drawn = coarse
	isl.coarse_arrays = arrays if coarse and isl.array_mesh != null else []
	# A stand-in has nothing to patch: 0 bytes is a patch that never fits.
	isl.index_bytes = index_patch_bytes(arrays) if isl.array_mesh != null and not coarse else 0
	isl.index_width = index_width(arrays)
	isl.mesh.mesh = mesh
	if near_tier != null:
		# The bricks themselves, whole: not a stand-in, and not while the
		# piece is drawn by a building's bands (they are tracked one by one).
		if isl.array_mesh != null and not coarse and isl.bands.is_empty():
			near_tier.track(isl.mesh, isl.chunk)
		else:
			near_tier.untrack(isl.mesh)


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
## Mesh jobs submitted and not yet attached: uploads that may be running on a
## worker now (BrickNear.uploads).
func mesh_jobs() -> int:
	return _mesh_jobs.size()


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
	# And the rubble field's merges, the same way (it crashed on quit without).
	for key in _field:
		var tile: FieldTile = _field[key]
		if tile.job >= 0:
			WorkerThreadPool.wait_for_task_completion(tile.job)
			tile.job = -1
		tile.holder = []
	_field.clear()
	_field_jobs = 0
	for c in _coarsening:
		world.release_chunk(int(c[1]))
	_coarsening.clear()


## Attach the meshes the workers have finished, and do what was asked of those
## pieces while they were being built.
## A finished mesh is handed to the renderer here, and that is ~50 ns a vertex
## on the main thread -- every one that was ready went in the same tick, 5 ms
## of the worst tick of --big --shot (2026-10-15). Up to HARVEST_BUDGET_MS a
## tick now, one at least; the rest the next tick.
const HARVEST_BUDGET_MS := 3.0


func _harvest_mesh_jobs() -> void:
	var k := 0
	var t0 := Time.get_ticks_usec()
	var applied := 0
	while k < _mesh_jobs.size():
		var job: Array = _mesh_jobs[k]
		var task: int = job[1]
		if task < 0 or not WorkerThreadPool.is_task_completed(task):
			k += 1
			continue
		if applied > 0 and Time.get_ticks_usec() - t0 > int(HARVEST_BUDGET_MS * 1000.0):
			harvests_spread += 1
			k += 1
			continue
		applied += 1
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
	if near_tier != null and not moved.is_empty():
		var touched := PackedInt32Array()
		for entry in moved:
			touched.append(int((entry as Dictionary).section))
		near_tier.damaged(isl.chunk, touched)
	return true


# ---------------------------------------------------------------------------
# Waking
# ---------------------------------------------------------------------------

## A frozen body never re-evaluates, so one that has just lost the piece it was
## resting on -- or been cut in two -- hangs exactly where it stopped. That is
## where floating wreckage comes from. Being shot is not a reason by itself
## (damage): what is taken from a piece at rest is gone, and the rest stays.
func wake(isl: BrickIsland) -> void:
	if not isl.is_valid() or not isl.settled:
		return
	isl.ripple_box = world_aabb(isl)
	isl.ripple_pending = true
	isl.body.freeze = false
	isl.settled = false
	# It was resting on something; if that has gone, it is in the air again
	# within AIRBORNE_AGAIN_TICKS.
	isl.landed = true
	isl.air_ticks = 0
	isl.jitter_since = 0
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
	_heap_support_gone(AABB(origin - Vector3.ONE * radius, Vector3.ONE * radius * 2.0))
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
	_heap_support_gone(box)
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
	return not _under(isl, false).is_empty()


## What the rays of _supported_below hit under a piece: every collider, or
## (`all` false) the first one. A piece with no box answers [null] -- held, as
## _supported_below has always taken it.
func _under(isl: BrickIsland, all: bool) -> Array:
	var out := []
	var box := world_aabb(isl)
	if box.size == Vector3.ZERO:
		return [null]
	var space := isl.body.get_world_3d().direct_space_state
	var y := box.position.y + 0.1
	var skip: Array[RID] = [isl.body.get_rid()]
	for fx in [0.02, 0.5, 0.98]:
		for fz in [0.02, 0.5, 0.98]:
			var at := Vector3(box.position.x + box.size.x * fx, y,
					box.position.z + box.size.z * fz)
			var q := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * (SUPPORT_REACH + 0.1),
					isl.body.collision_mask, skip)
			# A piece that has sunk a little into what it landed on starts the
			# ray INSIDE it, and a ray reports nothing from inside a shape: "no
			# support" for a piece pressed into a slab. It was nudged for that,
			# and woken by every piece that came to rest on it (--jam: the last
			# two stuck pieces of a collapse).
			q.hit_from_inside = true
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			if not all:
				return [hit.collider]
			if not out.has(hit.collider):
				out.append(hit.collider)
	return out


## Is what this piece would be frozen on still moving? A piece under it that is
## not frozen and faster than SETTLE_SPEED: wait for it (Docs/DestructionLod.md
## 3.1). Frozen there, it stayed when that one fell away -- "hanging up on
## something that's actively falling, then it goes to sleep as the other thing
## falls away" (user, 2026-10-19).
func _resting_on_moving(isl: BrickIsland) -> bool:
	for c in _under(isl, true):
		var rb := c as RigidBody3D
		if rb != null and not rb.freeze and rb.linear_velocity.length() > SETTLE_SPEED:
			return true
	return false


## Remember the pieces a piece was frozen on, and where they were: one that
## later moves HOLDER_SLIP from there, or goes, wakes it (_check_holders).
## Ripples (support_gone) only came from a piece that had been frozen and was
## woken; a piece that never froze moved out from under others without a word.
func _note_holders(isl: BrickIsland) -> void:
	for c in _under(isl, true):
		var rb := c as RigidBody3D
		if rb == null:
			continue   # the ground or a building: their bricks going has its own doors
		var key := rb.get_instance_id()
		if not _holders.has(key):
			_holders[key] = []
		(_holders[key] as Array).append([isl, rb.global_position])


## A piece that holds others up is moving (the tick, for every piece not
## frozen) or gone (_retire): wake the ones it has moved out from under.
func _check_holders(body: Node3D, gone: bool) -> void:
	var key := body.get_instance_id()
	var held: Array = _holders.get(key, [])
	if held.is_empty():
		return
	var keep := []
	for h in held:
		var dep: BrickIsland = h[0]
		if not dep.is_valid() or not dep.settled:
			continue   # woken already: nothing to keep
		if gone or body.global_position.distance_to(h[1]) > HOLDER_SLIP:
			wake(dep)
			holder_woken += 1
		else:
			keep.append(h)
	if keep.is_empty():
		_holders.erase(key)
	else:
		_holders[key] = keep


## A big piece standing on a point (PERCH_FOOT, PERCH_SHARE), or with its
## centre of mass past what is under it, is set tipping over the edge it would
## fall from, and true; otherwise false and nothing is done. Read from the
## solver's contacts: with none -- a body asleep -- it is not asked.
func _tip_if_perched(isl: BrickIsland) -> bool:
	var box := world_aabb(isl)
	var foot := minf(box.size.x, box.size.z)
	if foot < PERCH_FOOT:
		_perch_note(isl, "narrow (%.1f m)" % foot)
		return false
	var st := PhysicsServer3D.body_get_direct_state(isl.body.get_rid())
	if st == null:
		_perch_note(isl, "no body state")
		return false
	var com := isl.body.global_position
	var under := Rect2()
	var any := false
	var aside := 0
	for i in st.get_contact_count():
		var n := st.get_contact_local_normal(i)
		var at := st.get_contact_local_position(i)
		if absf(n.y) < LANDED_NORMAL_Y or at.y > com.y:
			aside += 1
			continue   # a wall it leans on, or something on top of it
		# Lying in a heap, on other pieces: theirs to settle together. Tipped
		# there, one levered its neighbours out of the heap (--jam --big).
		if st.get_contact_collider_object(i) is RigidBody3D:
			_perch_note(isl, "on another piece")
			return false
		var p := Vector2(at.x, at.z)
		if not any:
			under = Rect2(p, Vector2.ZERO)
			any = true
		else:
			under = under.expand(p)
	if not any:
		_perch_note(isl, "%d contact(s), none under it (%d beside or over it)" % [
				st.get_contact_count(), aside])
		return false
	var c := Vector2(com.x, com.z)
	var over := under.grow(0.05).has_point(c)
	if over and minf(under.size.x, under.size.y) >= foot * PERCH_SHARE:
		_perch_note(isl, "held: weight %s over %s" % [str(c.snapped(Vector2.ONE * 0.1)), str(under)])
		return false
	_perch_note(isl, "tipped: weight %s, under it %s" % [str(c.snapped(Vector2.ONE * 0.1)), str(under)])
	# Tip it over the side its weight is towards; straight over a point, the
	# way its id says, so every run of a replay tips it the same way.
	var off := c - under.get_center()
	if off.length() < 0.01:
		var a := float(isl.piece_id % 8) * TAU / 8.0
		off = Vector2(cos(a), sin(a))
	var axis := Vector3.UP.cross(Vector3(off.x, 0.0, off.y)).normalized()
	isl.body.sleeping = false
	isl.body.angular_velocity += axis * PERCH_EDGE_SPEED / maxf(isl.radius, 1.0)
	perched_tipped += 1
	return true


func _perch_note(isl: BrickIsland, why: String) -> void:
	if perch_say:
		perch_said[isl.piece_id] = why


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
	if isl.body.is_inside_tree():
		_note_holders(isl)
	# Come to rest on bricks lying there: they are under it, and go.
	if heap != null and heap.count > 0:
		heap.clear_in(isl.chunk_transform(), _island_aabb(isl))
	# Inert now: give the solver as few boxes as the shape allows.
	_reshape(isl, true)
	# And those are its boxes as its bricks are now: nothing is still owed.
	isl.reshape_due = false
	isl.reshaped_tick = Engine.get_physics_frames()
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
	# peel: what it was struck on comes away as a clump, cut along its
	# underside, as from a building (CityScene._shear_building) and a landing.
	# Without it every brick in the ball was joined to nothing and the piece
	# sprayed single bricks -- 234 of them in a barrage, against 20 groups of
	# two to eight (Docs/CollapseNext.md 1.3).
	e.flags = DamageLog.FLAG_PEEL
	var loosened := DamageLog.apply_entry(world, isl.chunk, e)
	if loosened.is_empty():
		return
	_record(e)
	impact_blocks += loosened.size()
	isl.shed_cause = "struck"
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
## Where a hit on a piece spends its time, ms all told: [the hit (apply_entry),
## throwing what it killed, cutting their shapes out, the solve, the mesh].
var damage_ms := [0.0, 0.0, 0.0, 0.0, 0.0]
func damage(isl: BrickIsland, world_point: Vector3, radius: float, chip := 0) -> void:
	if not isl.is_valid():
		return
	var tq := Time.get_ticks_usec()
	# The scene only calls this on the host -- a client's shot is a request --
	# but the rule belongs here as well as there.
	if not decides:
		return
	# **A piece at rest that is hit stays at rest** (Docs/CollapseNext.md 1.10;
	# the user, 2026-10-13: real LEGO). A heap of bricks that loses a brick does
	# not start to move. It was woken first, whole, whether or not the blast
	# took anything from it, and so was every piece within six metres -- under
	# fire the wreckage never slept, and every box of a piece that is awake is
	# the physics solver's to pay for. Now the bricks go, the piece stays
	# frozen where it lies, and it wakes for one of two reasons only: the hit
	# cut it in two (_shed), or took the bricks it stood on (support_gone,
	# below -- and the watchdog, for what that misses).
	var at_rest := isl.settled
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	var e := _piece_entry(isl,
			DamageLog.Kind.PIECE_CHIP if chip > 0 else DamageLog.Kind.PIECE_BLAST)
	e.point = _to_grid(isl, world_point)
	e.radius = radius
	e.limit = chip
	var killed := DamageLog.apply_entry(world, isl.chunk, e)
	tq = _dms(0, tq)
	# A chip that killed nothing still took hp, and hp is state.
	if chip > 0:
		_record(e)
	if killed.is_empty():
		return
	if chip <= 0:
		_record(e)
	isl.shed_cause = "hit"
	# Thrown out of it, all but the middle (BLAST_CORE) -- and, like the box
	# below, while their ids still mean these bricks.
	throw_killed(isl.chunk, killed, world_point, radius, chip > 0,
			Vector3.ZERO if isl.settled else isl.body.linear_velocity)
	tq = _dms(1, tq)
	# Where those bricks were, before the piece is cut and their ids mean
	# another chunk's bricks.
	var gone_box: AABB = isl.chunk_transform() * world.get_blocks_box(isl.chunk, killed)
	_ensure_per_block(isl)
	isl.disable_blocks(killed)
	_touched(isl)
	tq = _dms(2, tq)
	# Rubble is not re-solved. Cutting a disposable piece into smaller
	# disposable pieces costs a connectivity walk and a chunk per group, to
	# produce more of what is already being swept up in two and a half seconds.
	# At rest first: a piece cut off one that lay still can come to rest with
	# no landing of its own, and was counted in the air -- and in the rest
	# counts below, which ask only whether it was at rest.
	hit_census[2 if at_rest else (1 if isl.landed else 0)][0] += 1
	# Whatever rested on those bricks has lost them: every settled piece
	# touching where they were and not wholly below it is woken next tick,
	# and that is this piece too when they were the ones it stood on.
	support_gone(gone_box)
	# Solved here, in the call, once a blast -- NOT queued for the pieces' share
	# of the tick. Queued (once a piece a tick however many blasts reached it;
	# 2026-10-07 to 10-08) looked like less work and was more: a piece under
	# fire shed less a tick, lay whole and moving for longer, and was there to
	# be hit again -- twice the hits on pieces that were down (759-919 a
	# `--big --shot` against 339-403), and every box of a moving piece is the
	# physics solver's to pay for. Three alternated pairs, quiet machine:
	# queued 31.1 ms a frame, 269 of 906 over 33.3 ms, 69 ticks over 25 ms;
	# here 25.0, 132 and 44, the worst tick the same. Docs/CollapseNext.md 3.
	var cut0 := int(spawn_census.shed[0])
	tq = _dms(2, tq)
	if not isl.disposable:
		solve_island(isl)
	tq = _dms(3, tq)
	_mesh_later(isl)
	tq = _dms(4, tq)
	if at_rest:
		if isl.is_valid() and isl.settled:
			rest_hits_kept += 1
		elif not isl.is_valid() or int(spawn_census.shed[0]) > cut0:
			rest_hits_cut += 1
		else:
			rest_hits_woke += 1


## A hit's mesh update, once a piece a tick however many hits it took
## (flush_meshes). Done in the hit, it was 1.65 s of a `--big --shot`'s 1.95 s of
## hits on pieces (2026-10-20): a piece under automatic fire patched -- a walk
## of its every face -- or rebuilt once a bullet. Its bricks and collision
## change in the hit; only the drawing waits, to the end of the damage pass.
var _mesh_due: Array[BrickIsland] = []
func _mesh_later(isl: BrickIsland) -> void:
	if not _mesh_due.has(isl):
		_mesh_due.append(isl)


## The meshes hits have owed since the last call. CityScene calls it after the
## tick's hits; the pieces' tick calls it too, for hits from anywhere else.
func flush_meshes() -> void:
	if _mesh_due.is_empty():
		return
	var due := _mesh_due
	_mesh_due = []
	var t0 := Time.get_ticks_usec()
	for isl in due:
		if isl.is_valid():
			rebuild_mesh(isl)
	damage_ms[4] += float(Time.get_ticks_usec() - t0) / 1000.0


func _dms(k: int, t0: int) -> int:
	var now := Time.get_ticks_usec()
	damage_ms[k] += float(now - t0) / 1000.0
	return now


## Shove every loose piece within PUSH_REACH of a blast at `point` (see
## PUSH_SPEED). The host's: a piece's motion is this machine's physics, and
## only the host's shots reach pieces. Returns how many moved.
func push_near(point: Vector3, radius: float) -> int:
	if not decides or push_times <= 0.0 or radius <= 0.0:
		return 0
	var reach := radius * PUSH_REACH
	var moved := 0
	for i in islands.size():
		var isl: BrickIsland = islands[i]
		if not isl.is_valid() or isl.fade_since > 0:
			continue
		var com := isl.body.global_position
		if com.distance_to(point) > isl.radius + reach:
			continue
		var box := world_aabb(isl)
		var near := Vector3(clampf(point.x, box.position.x, box.end.x),
				clampf(point.y, box.position.y, box.end.y), clampf(point.z, box.position.z, box.end.z))
		var d := near.distance_to(point)
		if d >= reach:
			continue
		var size := PUSH_REF_BLOCKS / float(maxi(world.get_alive_block_count(isl.chunk), 1))
		var dv := minf(PUSH_SPEED * push_times * (1.0 - d / reach)
				* (pow(size, 1.0 / 3.0) if size > 1.0 else size), PUSH_MAX_SPEED)
		if isl.settled or isl.landed:
			if dv < PUSH_WAKE_SPEED:
				push_census[2] += 1
				continue
			if isl.settled:
				wake(isl)
				push_census[1] += 1
		var away := com - point
		away = away.normalized() if away.length() > 0.01 else Vector3.UP
		var dir := (away + Vector3.UP * PUSH_LIFT).normalized()
		isl.body.apply_impulse(dir * dv * isl.body.mass, near - com)
		push_census[0] += 1
		moved += 1
	return moved


func push_census_line() -> String:
	return "blasts pushed %d piece(s), %d of them woken from rest; %d that were down shrugged one off" % [
			push_census[0], push_census[1], push_census[2]]


## Damage every loose piece whose volume reaches the blast, not every piece
## whose origin happens to sit near it, and push what it reaches (push_near).
## Returns how many were hit.
## Where damage_near's time goes, ms all told: [waking sleepers, finding the
## pieces, damaging them, pushing them, calls].
var damage_near_ms := [0.0, 0.0, 0.0, 0.0, 0]
func damage_near(point: Vector3, radius: float, chip := 0) -> int:
	var hit := 0
	var t0 := Time.get_ticks_usec()
	damage_near_ms[4] += 1
	# A bullet has no radius but still has to find the piece it struck.
	var reach := maxf(radius, 0.25) if chip > 0 else radius
	# What is asleep is still there to be hit.
	wake_dormant_near(point, reach)
	var t1 := Time.get_ticks_usec()
	damage_near_ms[0] += float(t1 - t0) / 1000.0
	var in_damage := 0
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
			var td := Time.get_ticks_usec()
			damage(isl, point, radius, chip)
			in_damage += Time.get_ticks_usec() - td
			hit += 1
	var t2 := Time.get_ticks_usec()
	damage_near_ms[1] += float(t2 - t1 - in_damage) / 1000.0
	damage_near_ms[2] += float(in_damage) / 1000.0
	# After the damage, so what a hit cut off is pushed as well. A gun's wear
	# pushes nothing.
	if chip <= 0:
		push_near(point, radius)
	damage_near_ms[3] += float(Time.get_ticks_usec() - t2) / 1000.0
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
## What comes off pieces, by why (shed_cause: a hit, a landing, something
## landing on it) and by size -- one brick, 2-8, 9-48, more: whether single
## bricks still spray off pieces (Docs/CollapseNext.md 1.3) is the first column.
var shed_census := {}


func shed_census_line() -> String:
	var parts := PackedStringArray()
	for cause in shed_census:
		var row: Array = shed_census[cause]
		parts.append("%s %d / %d / %d / %d" % [cause, row[0], row[1], row[2], row[3]])
	var st: PackedInt64Array = world.get_components_near_stats()
	return "off pieces, groups of 1 / 2-8 / 9-48 / more: " + ("; ".join(parts) if not parts.is_empty() else "none") \
			+ " -- found by %d search(es), %.1f ms all told, %.2f the worst: %d whole with nothing changed, %d from what changed (%d bricks walked), %d walked whole, %d not as said; %d differing from a whole walk" % [
			int(find_ms[2]), find_ms[0], find_ms[1], st[1], st[2], st[3], st[4], st[6], st[5]]


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
	var bodies := 0
	var more := false
	_shed_left = false
	for g in groups:
		var moved: PackedInt32Array = g
		if moved.is_empty():
			continue
		if shed >= SHEDS_PER_PASS:
			# Biggest first: one that is too big waits for the next pass, and
			# the crumbs after it go now.
			if moved.size() > SHED_MORE_MAX_BLOCKS:
				more = true
				continue
			if shed > SHED_CRUMBS_ANYWAY and not _has_work_time():
				more = true
				break
		spawn_census.shed[0] += 1
		spawn_census.shed[1] += moved.size()
		var cause := isl.shed_cause if isl.shed_cause != "" else "other"
		if not shed_census.has(cause):
			shed_census[cause] = [0, 0, 0, 0]
		var n := moved.size()
		(shed_census[cause] as Array)[0 if n == 1 else (1 if n <= DEBRIS_MAX_BLOCKS
				else (2 if n <= LANDMARK_COUNT else 3))] += 1
		var child := record_detach(isl.owner, isl, isl.chunk, moved)
		var _ts := Time.get_ticks_usec()
		_shedding = true
		_shed_cause = isl.shed_cause
		var came := spawn(isl.chunk, moved, linear, angular, child, isl.owner)
		_shedding = false
		if came != null and is_blind(came):
			isl.waiting_children.append(came)
		if came != null:
			bodies += 1
		if came == null:
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
			isl.hold_started = Engine.get_process_frames()
		_touched(isl)
		# Whether or not spawn() kept the piece, those blocks are out of this
		# body. A discarded one is deleted, not left behind as ghost collision.
		isl.disable_blocks(moved, RID())
		shed += 1
	# A merged piece has no one block's box to switch off (disable_blocks), so
	# what left it is still in its boxes until they are rebuilt -- and a piece
	# on the ground collides with what it has just shed, lying exactly inside
	# those boxes. Rebuilt here, while the body is out of its space, not at the
	# rate a hit's rebuild is put off to (_flush_reshapes). A piece in the air
	# passes through what leaves it (Layers.AIRBORNE_MASK), and waits; so does
	# one that only shed crumbs or what was deleted, which have no body to be
	# pushed out of it.
	_shed_left = more
	if bodies > 0 and isl.merged and isl.landed:
		_reshape(isl, true, true)
		isl.reshape_due = false
		isl.reshaped_tick = Engine.get_physics_frames()
		merged_rebuilds += 1
	var _tb := Time.get_ticks_usec()
	if space.is_valid():
		PhysicsServer3D.body_set_space(rid, space)
	_upart("shed: body back", _tb)
	if more and not _resolve_queue.has(isl):
		_resolve_queue.append(isl)
	if isl.shed_cause == "hit":
		hit_census[2 if isl.settled else (1 if isl.landed else 0)][1] += bodies
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
	# Cut in two: what is left may have been standing on what left. It wakes,
	# and settles again if it is still held. What rested on it wakes when it
	# moves (wake sets its ripple), and what rested on a group that was deleted
	# was woken above (support_gone) -- not everything within six metres.
	wake(isl)
	return shed


## Whether the last _shed left groups for another pass.
var _shed_left := false
## What split_if_broken's searches took: [ms all told, the worst, how many].
var find_ms := [0.0, 0.0, 0]


## Anything no longer joined to the rest becomes its own piece.
##
## Searched from what has changed (BrickWorld.get_components_near): a piece
## known to be in one piece is walked out from the bricks a hit, a landing or a
## cut changed since, not end to end. Walked whole, a hit that cut nothing off
## the 22,000-brick tower was 1.5-3.5 ms, and a --big --shot had 146-187 of
## them (2026-10-16, CollapseNext item 23).
func split_if_broken(isl: BrickIsland) -> void:
	# A crack a landing put in (_snap_across) is no joint flag: it is asked
	# here, every pass until the piece has come apart along it, and forgotten
	# then.
	var cracked := not isl.cracks_x.is_empty() or not isl.cracks_z.is_empty()
	var t0 := Time.get_ticks_usec()
	var comps: Array = world.crack_components(isl.chunk, isl.cracks_x, isl.cracks_z) \
			if cracked else world.get_components_near(isl.chunk)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	find_ms[0] += ms
	find_ms[1] = maxf(find_ms[1], ms)
	find_ms[2] += 1
	if comps.size() <= 1:
		isl.cracks_x = PackedInt32Array()
		isl.cracks_z = PackedInt32Array()
		return
	_shed(isl, comps.slice(1))
	# Every group it found is cut away: what is left is one piece, and the next
	# search starts from what changes it.
	if not _shed_left:
		world.mark_chunk_whole(isl.chunk)


## What a hit or a landing has cut off a loose piece comes away from it. That
## is all there is to solve: **a loose piece is a rigid chunk** (Docs/
## CollapseNext.md 1.10; the user, 2026-10-13: real LEGO breaking apart).
##
## It was stress-solved: stood on its lowest bricks along whichever grid axis
## was nearest to down, and asked what their joints could hold -- the tension
## solve a standing building has, on a thing that is not standing on anything.
## For a section in the air that hung a tower's weight on a row of studs that
## held up nothing, and one shot failed it storey after storey (taken out
## 2026-10-07, CollapseNext 1.4). For wreckage on the ground it was the same
## mistake more quietly: a hit on a piece that was down made a new body a
## third of the time, against a twelfth for one in the air -- wreckage coming
## apart under its own weight after being shot, which a brick model lying on a
## table does not do. Its studs hold it together; it parts where a hit
## DISCONNECTS it and where a landing snaps it (fracture_on_impact: a clump
## peeled at the contact, one seam severed), and nowhere else.
##
## DamageLog.Kind.PIECE_SOLVE is not written any more. It is still read, for a
## log that was written when it was.
func solve_island(isl: BrickIsland) -> void:
	if not isl.is_valid() or world.get_alive_block_count(isl.chunk) == 0:
		return
	# The host cuts; a client gets each piece that leaves as a DETACH.
	if not decides:
		return
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	var _ta := Time.get_ticks_usec()
	split_if_broken(isl)
	_upart("split", _ta)


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
	var banded := false
	var cracked := false
	if near:
		var bands0 := band_breaks
		var cracks0 := crack_breaks
		loosened.append_array(_snap_across(isl, contacts, severity))
		banded = band_breaks > bands0
		cracked = crack_breaks > cracks0
		_tu = _upart("land: snap", _tu)
	else:
		# Counted as a landing all the same, so a piece bouncing in the
		# distance is not queued again every bounce (MAX_IMPACTS).
		far_landings += 1
		isl.impacts += 1
	# A crack loosens nothing: the split cuts along it (split_if_broken).
	if loosened.is_empty() and near and not cracked:
		return
	if loosened.is_empty() and not cracked:
		_hand_over(isl, contacts, severity)
		return

	isl.impacts += 1
	impacts += 1
	impact_blocks += loosened.size()
	# A band torn across a piece is said apart from the rest of a landing (the
	# clump peeled where it touched, a seam): it is where single bricks come from
	# (shed_census).
	isl.shed_cause = "landing: band" if banded else ("landing: crack" if cracked else "landing")
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
	var counted := {}   ## the piece's seams, counted once a landing (_weak_seam)
	var cracking := false
	var cracks := PackedInt32Array()
	for c in contacts:
		if planes >= BREAK_PLANES_MAX:
			break
		var local_point: Vector3 = inv_xf * (c.point as Vector3)
		var at: float = local_point.dot(local_axis)
		# **At the weakest seam near where it was struck** (_weak_seam;
		# Docs/CollapseNext.md 1.10 (5)): a brick model goes where the fewest
		# studs hold it -- through a row of windows before a solid course. It
		# went at the storey line nearest the contact whatever was there, and
		# still does where no course boundary in reach is a clean seam.
		var seam_at := INF
		var weak := false
		if local_axis.y > 0.5:
			seam_at = _weak_seam(isl, at, lo, hi, counted)
			weak = seam_at != INF
			if not weak:
				seam_at = _floor_line(isl, at, lo, hi)
		else:
			# Across X or Z, where no seam runs: **a crack along the bond**
			# (_weak_crack; Docs/CollapseNext.md 0, item 18). It tore a band
			# into loose bricks here -- the most single bricks a landing made.
			seam_at = _weak_crack(isl, 0 if local_axis.x > 0.5 else 2, at, lo, hi, counted)
			if seam_at == INF:
				continue   # nothing joined across there: nothing to snap
			cracking = true
		if seam_at != INF:
			if cracking:
				at = seam_at
			else:
				local_point.y = seam_at
				at = seam_at
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
		used.append(at)
		planes += 1
		if cracking:
			cracks.append(roundi(at / _axis_cell(local_axis)))
			continue
		points.push_back(DamageLog.grid_frame(world, isl.chunk) * local_point)
		if seam_at != INF and _is_floor_line(isl, seam_at):
			floor_breaks += 1
		if weak:
			seam_breaks += 1
	if cracking and not cracks.is_empty():
		# Not a command of its own: the split cuts the piece along them, and
		# what leaves goes as a DETACH like anything a piece sheds, which a
		# client and a replay take as it is.
		if local_axis.x > 0.5:
			isl.cracks_x.append_array(cracks)
		else:
			isl.cracks_z.append_array(cracks)
		crack_breaks += cracks.size()
		breaks += cracks.size()
		return torn
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
		# A block that runs through the seam pulls off at its foot (a column, in
		# a wall snapped along its windows): without that the two sides stay
		# joined by it and nothing parts.
		e.flags = DamageLog.FLAG_STEP
		torn = DamageLog.apply_entry(world, isl.chunk, e)
		if not torn.is_empty():
			_record(e)
		if e.flags & DamageLog.FLAG_BANDED:
			band_breaks += planes
		breaks += planes
	return torn


## How far either side of where a piece was struck its weakest seam is looked
## for, in metres, when it has no storeys to say (a player's build): three
## courses. A recipe tower's piece is searched half a storey either way.
const SEAM_REACH := 1.3
## A storey line is where it snaps unless some other seam in reach lets go of
## fewer than this much of its studs: the slab goes with the walls it is the
## floor of (the interiors ride on that), and two seams within a quarter of
## each other are as weak as each other. A recipe tower's row of windows holds
## with about three fifths of what its storey line does, columns and all.
const SEAM_PREFERS_FLOOR := 0.75


## Where a piece struck at `at` (metres up its own Y) snaps: the course
## boundary in reach that lets go of the fewest studs (BrickWorld.seam_studs)
## -- those meeting there, and those at the feet of the blocks that run
## through it, which a stepped seam pulls off (DamageLog.FLAG_STEP). The
## nearer of two as weak as each other; a storey line before anything not
## clearly weaker (SEAM_PREFERS_FLOOR); BREAK_MIN_PIECE left either side. INF
## when nothing in reach is a seam -- no two blocks meet at any boundary there.
##
## `counted` is the landing's own: the piece's boundaries are counted once, on
## the first contact that asks -- seam_studs walks every block of the piece,
## and a landing has up to nine contacts.
func _weak_seam(isl: BrickIsland, at: float, lo: float, hi: float,
		counted := {}) -> float:
	var cy: float = BrickWorld.get_cell_size().y
	var reach := SEAM_REACH
	var lines := _lines_of(isl)
	var per := _storey_at(lines, roundi(at / cy) + world.get_chunk_origin(isl.chunk).y)
	if per > 0:
		reach = float(per) * cy * 0.5
	var first := ceili((lo + BREAK_MIN_PIECE) / cy)
	var last := floori((hi - BREAK_MIN_PIECE) / cy)
	var k_at := roundi(at / cy)
	var k0 := maxi(k_at - ceili(reach / cy), first)
	var k1 := mini(k_at + ceili(reach / cy), last)
	if k1 < k0:
		return INF
	if counted.is_empty():
		counted["from"] = first
		counted["studs"] = world.seam_studs(isl.chunk, first, last)
	var studs: PackedInt32Array = counted["studs"]
	var skip: int = k0 - int(counted["from"])
	var origin_y: int = world.get_chunk_origin(isl.chunk).y
	var best := -1
	var best_cost := 0
	var line := -1       ## the storey line in reach, nearest
	var line_cost := 0
	for i in k1 - k0 + 1:
		var j := (skip + i) * 3
		# Where no two blocks meet there is no seam to open, whatever runs through.
		if studs[j] <= 0:
			continue
		var cost := studs[j] + studs[j + 2]
		var nearer := best < 0 or absi(k0 + i - k_at) < absi(k0 + best - k_at)
		if best < 0 or cost < best_cost or (cost == best_cost and nearer):
			best = i
			best_cost = cost
		if _on_line(lines, k0 + i + origin_y) \
				and (line < 0 or absi(k0 + i - k_at) < absi(k0 + line - k_at)):
			line = i
			line_cost = cost
	if best < 0:
		return INF
	if line >= 0:
		seam_studs_chosen += best_cost
		seam_studs_floor += line_cost
		if float(best_cost) >= float(line_cost) * SEAM_PREFERS_FLOOR:
			best = line
	return float(k0 + best) * cy


func snap_census_line() -> String:
	return "landings snapped %d time(s): %d at the weakest seam in reach, %d of all of them on a storey line, %d cracked across, %d torn as a band; the weakest seams held with %d stud(s) all told, the storey lines beside them with %d" % [
			breaks, seam_breaks, floor_breaks, crack_breaks, band_breaks, seam_studs_chosen, seam_studs_floor]


## A cell's size along a piece's own X, Y or Z.
static func _axis_cell(local_axis: Vector3) -> float:
	var cs := BrickWorld.get_cell_size()
	return cs.x if local_axis.x > 0.5 else (cs.y if local_axis.y > 0.5 else cs.z)


## How far either side of where a piece was struck its weakest crack is looked
## for, across X or Z, in metres: four studs.
const CRACK_REACH := 1.4


## Where a piece struck at `at` (metres along its own X, `axis` 0, or Z, 2)
## cracks: the plane in reach that lets go of the fewest studs, the bricks
## going each with the side its middle is on (BrickWorld.crack_studs) -- the
## crack steps round them, along the bond, as a snapped slab of bricks does.
## The nearer of two as weak as each other; BREAK_MIN_PIECE left either side.
## INF when nothing is joined across any plane in reach. `counted`, as for
## _weak_seam: the piece's planes counted once a landing.
func _weak_crack(isl: BrickIsland, axis: int, at: float, lo: float, hi: float,
		counted := {}) -> float:
	var cell := _axis_cell(Vector3.RIGHT if axis == 0 else Vector3.BACK)
	var first := ceili((lo + BREAK_MIN_PIECE) / cell)
	var last := floori((hi - BREAK_MIN_PIECE) / cell)
	var k_at := roundi(at / cell)
	var k0 := maxi(k_at - ceili(CRACK_REACH / cell), first)
	var k1 := mini(k_at + ceili(CRACK_REACH / cell), last)
	if k1 < k0:
		return INF
	var key := "crack%d" % axis
	if not counted.has(key):
		counted[key] = [first, world.crack_studs(isl.chunk, axis, first, last)]
	var from: int = counted[key][0]
	var studs: PackedInt32Array = counted[key][1]
	var best := -1
	for k in range(k0, k1 + 1):
		var s := studs[k - from]
		if s <= 0:
			continue
		if best < 0 or s < studs[best - from] or (s == studs[best - from]
				and absi(k - k_at) < absi(best - k_at)):
			best = k
	return float(best) * cell if best >= 0 else INF


## Is `y` (metres up the piece's own Y) one of its building's storey lines?
func _is_floor_line(isl: BrickIsland, y: float) -> bool:
	return _on_line(_lines_of(isl), roundi(y / BrickWorld.get_cell_size().y)
			+ world.get_chunk_origin(isl.chunk).y)


## The storey line nearest `at` (along the piece's own Y, in its local metres)
## that leaves BREAK_MIN_PIECE either side, or INF: a piece of a building with
## no storeys, or none in reach.
func _floor_line(isl: BrickIsland, at: float, lo: float, hi: float) -> float:
	var lines := _lines_of(isl)
	if lines.is_empty():
		return INF
	var cy: float = BrickWorld.get_cell_size().y
	var origin_y: int = world.get_chunk_origin(isl.chunk).y
	# In plates of the building's grid, which the piece kept.
	var plates := at / cy + float(origin_y)
	# The floor nearest, then the ones either side of it.
	var i := lines.bsearch(roundi(plates))
	var near := i
	if i >= lines.size() or (i > 0 and absf(plates - lines[i - 1]) < absf(lines[i] - plates)):
		near = i - 1
	for k in [near, near - 1, near + 1]:
		if k < 0 or k >= lines.size():
			continue
		var y := float(lines[k] - origin_y) * cy
		if y - lo >= BREAK_MIN_PIECE and hi - y >= BREAK_MIN_PIECE:
			return y
	return INF


## How many pieces are invisible right now, and how big the biggest one is.
## Is this piece drawing nothing -- no surfaces and no bands? What
## _count_meshless counts, asked of one piece. A piece with no mesh node at all
## is drawn some other way (the shared single-brick MultiMesh) and is not blind.
func is_blind(isl: BrickIsland) -> bool:
	if not isl.is_valid() or isl.mesh == null:
		return false
	var m: Mesh = isl.mesh.mesh
	return (m == null or m.get_surface_count() == 0) and not _any_band(isl) \
			and not _retiring_band(isl)


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


## Bands still drawing for a piece whose one mesh is not up yet (rebuild_mesh)?
func _retiring_band(isl: BrickIsland) -> bool:
	for node in isl.retiring_bands:
		if is_instance_valid(node):
			return true
	return false


## The new mesh is up: the bands it replaces go.
func _drop_retiring_bands(isl: BrickIsland) -> void:
	for node in isl.retiring_bands:
		if is_instance_valid(node):
			_retirer.retire((node as MeshInstance3D).mesh)
			(node as MeshInstance3D).queue_free()
	isl.retiring_bands.clear()


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
		if near_tier != null and live:
			near_tier.track(node, isl.chunk, si)
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
			if _still_waiting(h) and now - h.hold_started < HOLD_MAX_FRAMES:
				h.hold_until = now + 1
				holds_extended += 1
			else:
				h.waiting_children.clear()
				_held.remove_at(hi)
				rebuild_mesh(h)
		hi -= 1



## Is a child this piece shed still drawn by nothing? Those that are drawn, or
## gone, are dropped from the list.
func _still_waiting(isl: BrickIsland) -> bool:
	for i in range(isl.waiting_children.size() - 1, -1, -1):
		var c: BrickIsland = isl.waiting_children[i]
		if not c.is_valid() or not is_blind(c):
			isl.waiting_children.remove_at(i)
	return not isl.waiting_children.is_empty()


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
	flush_meshes()
	var _t_loop := Time.get_ticks_usec()
	if camera != null and is_instance_valid(camera):
		_frustum = camera.get_frustum()
	var look := Engine.get_physics_frames() % SEEN_EVERY == 0
	_work_until = Time.get_ticks_usec() + int(WORK_BUDGET_MS * 1000.0)
	_sync_meshes = 0
	var now := Time.get_ticks_msec()
	var settles := 0
	var moving := 0
	var moving_of_now := {}
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
		if not isl.disposable:
			moving_of_now[isl.owner] = int(moving_of_now.get(isl.owner, 0)) + 1
		if isl.landmark:
			moving_landmarks += 1
		moving_blocks += isl.shape_count
		if isl.census_cls >= 0:
			var crow: Array = body_census[isl.census_from][isl.census_cls]
			crow[2] += 1
			crow[3] += isl.shape_count

		var speed := isl.body.linear_velocity.length()
		if speed > MAX_DEBRIS_SPEED:
			isl.body.linear_velocity = isl.body.linear_velocity.normalized() * MAX_DEBRIS_SPEED
			speed = MAX_DEBRIS_SPEED
		if isl.body.linear_velocity.y > MAX_RISE_SPEED \
				and not (isl.hold_until_ms > 0 and now < isl.hold_until_ms):
			var risen := isl.body.linear_velocity
			risen.y = MAX_RISE_SPEED
			isl.body.linear_velocity = risen
			speed = risen.length()
			rises_capped += 1
		if not _holders.is_empty():
			_check_holders(isl.body, false)
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

		if not isl.disposable:
			_note_landing(isl)

		# Held by something outside physics (hold_awake): not at rest, whatever
		# its speed says.
		if isl.hold_until_ms > 0 and now < isl.hold_until_ms:
			isl.slow_since = 0
			isl.jitter_since = 0
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
			# Jittering in a heap: see SETTLE_JITTER_SPEED.
			if isl.landed and speed < SETTLE_JITTER_SPEED and spin < SETTLE_JITTER_SPIN:
				if isl.jitter_since == 0:
					isl.jitter_since = now
				elif not rested and now - isl.jitter_since >= _slow_window(isl):
					rested = true
					by_rule = true
					settled_jittering += 1
			else:
				isl.jitter_since = 0
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
			isl.jitter_since = 0
			isl.body.sleeping = false
			isl.body.linear_velocity += Vector3.DOWN * SUPPORT_NUDGE
			continue
		if now - isl.born_ms >= SETTLE_MIN_MS and rested and settles < SETTLES_PER_TICK 				and not isl.disposable and isl.unsupported_tries < SUPPORT_TRIES 				and _slow_window(isl) == SETTLE_SLOW_FAR_MS and _tip_if_perched(isl):
			isl.unsupported_tries += 1
			isl.slow_since = 0
			isl.jitter_since = 0
			continue
		if now - isl.born_ms >= SETTLE_MIN_MS and rested and settles < SETTLES_PER_TICK \
				and _resting_on_moving(isl):
			settle_waits += 1
			continue
		if now - isl.born_ms >= SETTLE_MIN_MS and rested and settles < SETTLES_PER_TICK:
			settles += 1
			if by_rule:
				settled_by_rule += 1
			elif by_age:
				settled_by_age += 1
			if perch_say:
				perch_said[isl.piece_id] = "%s; frozen %s, window %d ms, tries %d" % [
						perch_said.get(isl.piece_id, "never asked"),
						"by rule" if by_rule else "by age" if by_age else "at rest",
						_slow_window(isl), isl.unsupported_tries]
			settle_now(isl)

	_moving_of = moving_of_now
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
	_tend_field()
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
	var _r0 := Time.get_ticks_usec()
	_harvest_coarse_jobs()
	_harvest_mesh_jobs()
	var _r1 := Time.get_ticks_usec()
	_drain_upload_waiting()
	var _r2 := Time.get_ticks_usec()
	_drain_mesh_queue()
	var _r3 := Time.get_ticks_usec()
	_fill_band_holes()
	var _r4 := Time.get_ticks_usec()
	_drain_resolve_queue()
	var _tr := Time.get_ticks_usec()
	_resolve_parts = [float(_r1 - _r0) / 1000.0, float(_r2 - _r1) / 1000.0,
			float(_r3 - _r2) / 1000.0, float(_r4 - _r3) / 1000.0, float(_tr - _r4) / 1000.0]
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
	_update_crumbs()
	if not defer_job_start:
		start_mesh_jobs()
	tick_prof.mm += float(Time.get_ticks_usec() - _tm) / 1000.0
	var _total := float(Time.get_ticks_usec() - _t_loop) / 1000.0
	last_tick = [_total, float(_tl - _t_loop) / 1000.0, _resolve_parts.duplicate(),
			float(_tfq - _tr) / 1000.0, float(_tf - _tfq) / 1000.0, float(_tm - _tf) / 1000.0]
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
				"islands": islands.size(),
				"resolve parts: harvest, upload, mesh queue, band holes, resolve queue": _resolve_parts}


## Is there time left in this tick's share? Each queue does its first unit
## whatever this says (WORK_MIN).
func _has_work_time() -> bool:
	return Time.get_ticks_usec() < _work_until


## Islands that had more to shed than one pass allowed. Re-solving finishes
## the job, a couple of pieces at a time.
func _drain_resolve_queue() -> void:
	var done := 0
	while (done < WORK_MIN or _has_work_time()) and not _resolve_queue.is_empty():
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
		done += 1


## Work through landings a couple at a time. Each one shears the contact band
## and re-solves the piece, which is far too much to do for every island that
## touched down in the same tick.
func _drain_fracture_queue() -> void:
	# Its own first unit, whatever the re-solves before it took (WORK_MIN).
	var done := 0
	while (done < WORK_MIN or _has_work_time()) and not _fracture_queue.is_empty():
		var entry: Array = _fracture_queue.pop_front()
		var isl: BrickIsland = entry[0]
		if not isl.is_valid():
			continue
		isl.fracture_queued = false
		var t0 := Time.get_ticks_usec()
		_unit = {}
		fracture_on_impact(isl, float(entry[1]))
		_unit_done("landing", isl, t0)
		done += 1


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
					and Engine.get_physics_frames() - isl.coarse_tick < coarse_wait(isl):
				i += 1
				continue
			_mesh_queue.remove_at(i)
			var _tc := Time.get_ticks_usec()
			var _was := "rebuilt" if isl.coarse_drawn else "first"
			coarse_split = "on a worker"
			rebuild_mesh(isl, true)
			_note_mesh_drain(isl, _tc, "stand-in, %s, from %s (%s), %d ms old, settled %s, edits %d: %s" % [
					_was, isl.census_from, isl.shed_cause, Time.get_ticks_msec() - isl.born_ms,
					isl.settled, isl.edits, coarse_split])
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
		var _tb := Time.get_ticks_usec()
		rebuild_mesh(isl, true)
		_note_mesh_drain(isl, _tb, "baked")
		done += 1


## The slowest single mesh the queue made, for the profile: [ms, bricks, kind].
var mesh_drain_worst: Array = [0.0, 0, ""]


func _note_mesh_drain(isl: BrickIsland, t0: int, kind: String) -> void:
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if ms > float(mesh_drain_worst[0]):
		mesh_drain_worst = [ms, world.get_alive_block_count(isl.chunk) if isl.is_valid() else -1, kind]


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
		# The least seen first (apparent_size: a tall wreck far off outranks a low
		# heap nearer), and nobody's cover or floor at all: a piece asleep has no
		# collision (see CAP_KEEP_RANGE). It was farthest first.
		var points := interest_points()
		var away := {}
		var seen := {}
		var keep: Array = []
		for isl in large:
			var box := world_aabb(isl)
			var d := _distance_to_interest(box, points)
			if d < CAP_KEEP_RANGE:
				continue
			away[isl] = d
			seen[isl] = apparent_size(box, d)
			keep.append(isl)
		keep.sort_custom(func(a, c) -> bool: return float(seen[a]) < float(seen[c]))
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
	_decide_owed(isl)
	return _commit_sleep(isl, index, ChunkRecord.capture(world, isl.chunk), by_cap)


## A piece with a decision still queued -- hit, struck or landed, and not yet
## re-solved -- has it made now, before it is put to sleep. Asleep it is a
## record and a stand-in, and the queue's entry for it is an island that no
## longer exists: what the hit broke off would never come off.
func _decide_owed(isl: BrickIsland) -> void:
	var at := _resolve_queue.find(isl)
	if at < 0:
		return
	_resolve_queue.remove_at(at)
	solve_island(isl)
	rebuild_mesh(isl)


enum { NOTHING, SLEPT, STARTED }


## Put a piece to sleep now if it is small, or start capturing it a slice a
## tick if it is not (CAPTURE_BLOCKS_PER_TICK). `for_cap` says who asked, for
## the counters when it finishes.
func _sleep_or_begin(isl: BrickIsland, index: int, for_cap: bool) -> int:
	if isl.capturing:
		return STARTED
	_decide_owed(isl)
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
	d.stand_in_arrays = _stand_in_arrays
	dormant.append(d)
	_field_add(d)
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
		linear: Vector3, angular: Vector3, at_rest: bool, is_disposable: bool,
		was_landed: bool = true) -> BrickIsland:
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
		isl.landed = was_landed
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
	_stand_in_arrays = []
	if isl.mesh == null or not isl.mesh.is_inside_tree():
		return null
	var mesh: ArrayMesh = isl.array_mesh
	if isl.coarse_drawn:
		_stand_in_arrays = isl.coarse_arrays
	if (mesh == null or mesh.get_surface_count() == 0) and _any_band(isl):
		var arrays: Array = world.build_chunk_coarse_mesh(isl.chunk)
		coarse_built += 1
		coarse_worst_ms = maxf(coarse_worst_ms, world.get_last_coarse_ms())
		if not arrays.is_empty() and mesh_arrays_ok(arrays, "stand-in %d" % isl.chunk):
			coarse_verts += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			mesh = ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			_stand_in_arrays = arrays
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
	_field_remove(d)
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
	isl.coarse_arrays = d.stand_in_arrays
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
		d.stand_in_arrays = arrays
		stand_ins += 1
		_field_add(d)
	return n


# ---------------------------------------------------------------------------
# THE RUBBLE FIELD (Docs/DestructionLod.md 3.5)
# ---------------------------------------------------------------------------

## What sleeping wreckage leaves drawn -- its stand-ins (_leave_stand_in) -- is
## drawn a TILE at a time: every stand-in in one FIELD_TILE_M square merged into
## one mesh, a surface per material, the stand-ins' own nodes kept (hidden) for
## the piece to take back when it wakes. And only so many tiles are drawn: the
## FIELD_MAX_DRAWN that look biggest from where everybody is (apparent_size), so
## a tall wreck far off -- one seen from round the planet -- is drawn before a
## low heap nearer (user, 2026-10-25). Ranked every FIELD_RANK_TICKS; merged on
## workers (FIELD_JOBS at a time) once a tile has been quiet FIELD_QUIET_TICKS.
##
## Measured before (--rubble --big): 165 pieces asleep after a big collapse,
## each its own node and draw call; settled pieces cost the physics step
## nothing, and drawing them was 62 of 970 draw calls.
const FIELD_TILE_M := 32.0 * BrickPalette.STUD_M
const FIELD_MAX_DRAWN := 48
const FIELD_RANK_TICKS := 30

class FieldTile:
	var members: Array = []   ## Dormant
	var node: MeshInstance3D = null
	var box := AABB()
	var dirty := true
	var shown := true
	var changed_tick := 0
	var job := -1               ## the worker merging it, or -1
	var holder: Array = []      ## what the worker made: [ArrayMesh, AABB]
	var restart := false        ## changed while the worker ran

## A tile is merged once it has been left alone this long: a collapse puts its
## pieces to sleep one a tick, and merging on every one was 378 merges for 77
## tiles. Until then, and while its worker runs, its stand-ins draw themselves.
const FIELD_QUIET_TICKS := 30
## Off (--no-field), every stand-in draws itself and none is culled: the A/B.
var field_enabled := true
const FIELD_JOBS := 2
## A stand-in left as its BRICKS -- the cap puts pieces to sleep near as well as
## far, and 95 of 132 after a big collapse were -- has no arrays to merge from.
## Past the coarse ladder's range (ISLAND_MESH_RANGE + ISLAND_MESH_HYSTERESIS,
## where an awake piece would be coarse too) it is made coarse: its record made a
## chunk again, the coarse mesh built on a worker, the chunk given back, as
## build_due_stand_ins does for a save's. FIELD_COARSEN_JOBS at a time. Nearer,
## it keeps its bricks and draws itself.
const FIELD_COARSEN_JOBS := 2
var _coarsening: Array = []    ## [Dormant, chunk]
var field_coarsened := 0

var _field := {}               ## Vector2i -> FieldTile
var _stand_in_arrays: Array = []   ## what _leave_stand_in drew from, if arrays
var _field_root: Node3D = null
var _field_ranked := -1000
var _field_jobs := 0
var field_merges := 0          ## tiles merged, all told
var field_worst_ms := 0.0      ## the slowest worker merge
var field_main_worst_ms := 0.0 ## the slowest a merge cost the main thread
var field_drawn := 0           ## tiles drawn at the last ranking
var field_culled := 0          ## tiles the cap left undrawn at the last ranking


## How big something looks from `distance` metres: its height, and a quarter of
## its width, over the distance. Height first: a tall wreck stands on the
## skyline, a wide low one does not.
static func apparent_size(box: AABB, distance: float) -> float:
	return (box.size.y + 0.25 * maxf(box.size.x, box.size.z)) / maxf(distance, 1.0)


func _field_key_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / FIELD_TILE_M), floori(p.z / FIELD_TILE_M))


func _field_add(d: Dormant) -> void:
	if not field_enabled or d.in_field or d.stand_in == null or not is_instance_valid(d.stand_in):
		return
	if _field_root == null:
		_field_root = Node3D.new()
		_field_root.name = "RubbleField"
		add_child(_field_root)
	var key := _field_key_of(d.stand_in.global_position)
	var tile: FieldTile = _field.get(key)
	if tile == null:
		tile = FieldTile.new()
		_field[key] = tile
	tile.members.append(d)
	d.field_key = key
	d.in_field = true
	_field_touch(tile)


## A piece waking takes its stand-in back, out of its tile: the tile draws its
## stand-ins one by one until it is merged again, so nothing is drawn twice.
func _field_remove(d: Dormant) -> void:
	if not d.in_field:
		return
	d.in_field = false
	if d.stand_in != null and is_instance_valid(d.stand_in):
		d.stand_in.visible = true
	var tile: FieldTile = _field.get(d.field_key)
	if tile == null:
		return
	tile.members.erase(d)
	_field_touch(tile)


## Changed: drawn piece by piece from now until merged again.
func _field_touch(tile: FieldTile) -> void:
	tile.dirty = true
	tile.changed_tick = Engine.get_physics_frames()
	if tile.job >= 0:
		tile.restart = true
	_field_show(tile)


## What draws a tile: its merged mesh when that is up to date, else each of
## its stand-ins -- and neither when the cap has culled it.
func _field_show(tile: FieldTile) -> void:
	var merged := not tile.dirty and tile.node != null and is_instance_valid(tile.node)
	if tile.node != null and is_instance_valid(tile.node):
		tile.node.visible = tile.shown and merged
	for d in tile.members:
		var dd: Dormant = d
		if dd.stand_in != null and is_instance_valid(dd.stand_in):
			dd.stand_in.visible = tile.shown and (not merged or dd.stand_in_arrays.is_empty())


func _tend_field() -> void:
	if _field.is_empty():
		return
	var now := Engine.get_physics_frames()
	for key in _field.keys():
		var tile: FieldTile = _field[key]
		if tile.job >= 0:
			if WorkerThreadPool.is_task_completed(tile.job):
				_field_finish(tile)
			continue
		if tile.dirty and _field_jobs < FIELD_JOBS and now - tile.changed_tick >= FIELD_QUIET_TICKS:
			_field_start(key, tile)
	if not _coarsening.is_empty():
		_field_coarsen_finish()
	if now - _field_ranked >= FIELD_RANK_TICKS:
		_field_ranked = now
		_field_rank()
		_field_coarsen_start()


## Hand a tile's stand-ins to a worker to merge. Members whose piece has woken
## or gone are dropped here; an empty tile is freed.
func _field_start(key: Vector2i, tile: FieldTile) -> void:
	var t0 := Time.get_ticks_usec()
	var into := _field_root.global_transform.affine_inverse()
	var items: Array = []
	for i in range(tile.members.size() - 1, -1, -1):
		var d: Dormant = tile.members[i]
		if not dormant.has(d) or d.stand_in == null or not is_instance_valid(d.stand_in) \
				or d.stand_in.mesh == null:
			d.in_field = false
			tile.members.remove_at(i)
			continue
		if d.stand_in_arrays.is_empty():
			continue   # drawn by itself (_field_show)
		var node := d.stand_in
		items.append([d.stand_in_arrays, into * node.global_transform,
				node.material_override if node.material_override != null else brick_material])
	if tile.members.is_empty():
		if tile.node != null and is_instance_valid(tile.node):
			tile.node.queue_free()
		_field.erase(key)
		return
	tile.dirty = false
	if items.is_empty():
		_field_show(tile)   # every one of them draws itself
		return
	tile.restart = false
	var holder := [null, AABB()]
	tile.holder = holder
	tile.job = WorkerThreadPool.add_task(func() -> void:
		var t := Time.get_ticks_usec()
		var built := IslandManager._field_build(items)
		holder[0] = built[0]
		holder[1] = built[1]
		holder.append(float(Time.get_ticks_usec() - t) / 1000.0), true, "rubble field")
	_field_jobs += 1
	field_main_worst_ms = maxf(field_main_worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


func _field_finish(tile: FieldTile) -> void:
	var t0 := Time.get_ticks_usec()
	WorkerThreadPool.wait_for_task_completion(tile.job)
	tile.job = -1
	_field_jobs -= 1
	var mesh: ArrayMesh = tile.holder[0]
	if tile.holder.size() > 2:
		field_worst_ms = maxf(field_worst_ms, float(tile.holder[2]))
	if tile.restart or mesh == null:
		# Changed while it was merged: what it made is already out of date.
		tile.dirty = true
		_field_show(tile)
		return
	if tile.node == null or not is_instance_valid(tile.node):
		tile.node = MeshInstance3D.new()
		tile.node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_field_root.add_child(tile.node)
	tile.node.mesh = mesh
	tile.box = _field_root.global_transform * (tile.holder[1] as AABB)
	field_merges += 1
	_field_show(tile)
	field_main_worst_ms = maxf(field_main_worst_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


## On a worker: [mesh, its box] of `items` ([arrays, transform, material]
## each), a surface per material and set of arrays. Joined, not fed through a
## SurfaceTool (append_from walks every vertex in turn): positions and normals
## are moved in one call each, only the indices offset one by one. From the
## arrays a stand-in was made from, never read back from its mesh -- that was
## the GPU's copy.
static func _field_build(items: Array) -> Array:
	var groups := {}    # [material, slots present] -> [arrays, vertex count]
	var mats := {}
	for it in items:
		var src: Array = it[0]
		var xf: Transform3D = it[1]
		var mat: Material = it[2]
		var turn := Transform3D(xf.basis.orthonormalized(), Vector3.ZERO)
		var present := 0
		for slot in Mesh.ARRAY_MAX:
			if slot < src.size() and src[slot] != null:
				present |= 1 << slot
		var k := [mat, present]
		mats[k] = mat
		var g: Array = groups.get(k, [])
		if g.is_empty():
			var fresh := []
			fresh.resize(Mesh.ARRAY_MAX)
			g = [fresh, 0]
			groups[k] = g
		var dst: Array = g[0]
		var base: int = g[1]
		for slot in Mesh.ARRAY_MAX:
			if not (present & (1 << slot)):
				continue
			var v = src[slot]
			if slot == Mesh.ARRAY_VERTEX:
				v = xf * (v as PackedVector3Array)
			elif slot == Mesh.ARRAY_NORMAL:
				v = turn * (v as PackedVector3Array)
			elif slot == Mesh.ARRAY_TANGENT:
				var tangents := (v as PackedFloat32Array).duplicate()
				for i in range(0, tangents.size(), 4):
					var t3 := turn.basis * Vector3(tangents[i], tangents[i + 1], tangents[i + 2])
					tangents[i] = t3.x
					tangents[i + 1] = t3.y
					tangents[i + 2] = t3.z
				v = tangents
			elif slot == Mesh.ARRAY_INDEX and base > 0:
				var idx := (v as PackedInt32Array).duplicate()
				for i in idx.size():
					idx[i] += base
				v = idx
			if dst[slot] == null:
				dst[slot] = v
			else:
				dst[slot].append_array(v)
		g[1] = base + (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var out := ArrayMesh.new()
	for k in groups:
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, (groups[k] as Array)[0])
		out.surface_set_material(out.get_surface_count() - 1, mats[k])
	return [out, out.get_aabb()]


## Start making far stand-ins of bricks coarse (FIELD_COARSEN_JOBS).
func _field_coarsen_start() -> void:
	if _coarsening.size() >= FIELD_COARSEN_JOBS:
		return
	var points := interest_points()
	if points.is_empty():
		return
	var busy := {}
	for c in _coarsening:
		busy[c[0]] = true
	for d in dormant:
		if _coarsening.size() >= FIELD_COARSEN_JOBS:
			return
		if busy.has(d) or not d.stand_in_arrays.is_empty() or d.stand_in == null \
				or not is_instance_valid(d.stand_in) or d.record.block_count() <= 1:
			continue
		if _distance_to_interest(d.record.box, points) < ISLAND_MESH_RANGE + ISLAND_MESH_HYSTERESIS:
			continue
		var chunk := d.record.restore(world)
		if chunk < 0:
			continue
		world.coarse_chunk_async(chunk)
		_coarsening.append([d, chunk])


func _field_coarsen_finish() -> void:
	for i in range(_coarsening.size() - 1, -1, -1):
		var d: Dormant = _coarsening[i][0]
		var chunk: int = _coarsening[i][1]
		if not world.coarse_ready(chunk):
			if not world.coarse_pending(chunk):
				world.coarse_chunk_async(chunk)
			continue
		_coarsening.remove_at(i)
		var arrays: Array = world.take_coarse_mesh(chunk)
		world.release_chunk(chunk)
		# Woken meanwhile: it has its own mesh now.
		if not dormant.has(d) or d.stand_in == null or not is_instance_valid(d.stand_in):
			continue
		if arrays.is_empty() or not mesh_arrays_ok(arrays, "coarse stand-in of piece %d" % d.piece_id):
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		d.stand_in.mesh = mesh
		d.stand_in.material_override = brick_material
		d.stand_in.transform = d.record.xform
		d.stand_in_arrays = arrays
		field_coarsened += 1
		var tile: FieldTile = _field.get(d.field_key)
		if d.in_field and tile != null:
			_field_touch(tile)


## The cap: the FIELD_MAX_DRAWN tiles that look biggest are drawn, the rest
## are not (still asleep, still there, only unseen). Every tile within the
## coarse ladder's range is drawn whatever the count -- the cap is for FAR
## wreckage -- and fills the cap first. A tile not merged yet is ranked by its
## stand-ins' own boxes.
func _field_rank() -> void:
	var points := interest_points()
	if points.is_empty():
		return
	var tiles: Array = []
	var seen := {}
	for key in _field:
		var tile: FieldTile = _field[key]
		var box := tile.box
		if box.size == Vector3.ZERO:
			for d in tile.members:
				var dd: Dormant = d
				box = dd.record.box if box.size == Vector3.ZERO else box.merge(dd.record.box)
		var dist := _distance_to_interest(box, points)
		# Near wreckage is never culled: it would blink out at somebody's feet.
		# It is drawn, and counts against the cap.
		seen[tile] = INF if dist < ISLAND_MESH_RANGE + ISLAND_MESH_HYSTERESIS 				else apparent_size(box, dist)
		tiles.append(tile)
	tiles.sort_custom(func(a, c) -> bool: return float(seen[a]) > float(seen[c]))
	field_drawn = 0
	field_culled = 0
	for i in tiles.size():
		var tile: FieldTile = tiles[i]
		tile.shown = i < FIELD_MAX_DRAWN or is_inf(float(seen[tile]))
		_field_show(tile)
		if tile.shown:
			field_drawn += 1
		else:
			field_culled += 1


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
		_check_holders(isl.body, true)
	if isl.is_valid():
		_holders.erase(isl.body.get_instance_id())
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
		"settled_jittering": settled_jittering,
		"crumbled": crumbled,
		"floor_breaks": floor_breaks,
		"seam_breaks": seam_breaks,
		"rises_capped": rises_capped,
		"crumb_bricks": crumb_bricks,
		"crumbs": crumb_count,
		"crumbs_over": crumbs_over,
		"crumb_worst_ms": crumb_worst_ms,
		"crumble_worst_ms": crumble_worst_ms,
		"landings_noted": landings_noted,
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
		"coarse_async": coarse_async,
		"coarse_main_worst_ms": coarse_main_worst_ms,
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
