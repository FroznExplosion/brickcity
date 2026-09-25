extends Node3D

## A block of city. Twenty-odd buildings of mixed height, close enough to fall
## on each other.
##
## This is where the LOD claim gets tested: an undamaged building holds **no
## bricks at all**. It is a recipe, a cheap shell mesh and five collision boxes.
## Shoot one and it materialises — bricks, per-block collision, real mesh — and
## from that moment it behaves exactly like the single-tower sandbox.
##
## Keys: WASD fly · SPACE/Q up, down · shift fast · SPACE SPACE walk/fly
##       LMB fire · WHEEL blast size · X wider blast
##       1 gun · 2 debug blast · T next gun · R reload · L seams · F1 stats
##       F5 save · F9 load · ESC mouse
## Flags: `-- --shot` scripted capture; `-- --gun` and `-- --checkpoint` gates

const BLAST_RADIUS := 1.4
const BIG_BLAST := 3.2
## What the wheel may wind the blast down to and up to, and by how much per
## notch. Multiplicative, so a notch is the same proportion of the radius at
## either end -- at a fixed step the small end is unusable and the big end
## takes forever.
const BLAST_MIN := 0.5
const BLAST_MAX := 12.0
const BLAST_STEP := 1.2

## The grid, from the palette rather than typed in again. The city used to
## write 0.35 and 0.14 inline some twenty times; right every time, and one
## grid change from being wrong in twenty places. tools/scale_probe.gd.
const STUD := BrickPalette.STUD_M
const PLATE := BrickPalette.PLATE_M

## Building shapes, chosen to give a skyline rather than a grid of clones.
##
## Footprints are LATTICE-CONFORMING: `k * PANEL`, so 20, 30, 40 and so on.
## Every one divides into whole floor panels from face to face -- the ones round
## the edge running under the walls, which is what makes each floor part of its
## walls -- with nothing left over.
##
## That is the constraint five attempts at the floor rewrite failed on: a
## footprint that does not divide leaves a strip of small plates reaching
## neither a column nor a wall. Choosing footprints that fit the lattice makes
## the whole class of failure go away. Docs/Scale.md.
##
## They were `2 * WALL_THICK + k * PANEL` (24, 34, 44...) while the floor
## stopped at the inside face of the wall. Now it runs to the outer face, each
## shape is four studs smaller outside and has the same number of panels.
##
## It is a constraint in STUDS, so a printed brick still lines up: the lattice
## is a multiple of the stud pitch, not a departure from it.
##
## The smallest here is 30, because a stairwell is a whole panel across and has
## to be a cell CLEAR of the walls: a 20-stud building is two cells, both under
## a wall on their outer sides, and a staircase in either cut through the wall
## to fit (TowerRecipe.stair_line).
##
## Courses are whole storeys of TowerRecipe.COURSES_PER_FLOOR. When a storey went
## from four courses to six, every shape kept its height (or lost up to a storey
## of it) and gave up floors instead: 46 courses was 11 floors and is 7 now.
const SHAPES := [
	{"x": 30, "z": 30, "courses": 18},
	{"x": 40, "z": 30, "courses": 30},
	{"x": 30, "z": 30, "courses": 42},
	{"x": 30, "z": 40, "courses": 60},
	{"x": 40, "z": 30, "courses": 24},
	{"x": 30, "z": 30, "courses": 78},
]

## `--big`: the same city with buildings the size the game eventually wants.
##
## The largest here is 28 x 22 m on plan and 84 m tall, which is a mid-rise
## office block rather than a test tower -- and 4,000 rooms. Everything about
## interiors that is a judgement call at 20x20x18 is a measurement at this
## size, which is what the mode exists for.
const BIG_SHAPES := [
	{"x": 40, "z": 30, "courses": 60},
	{"x": 40, "z": 40, "courses": 120},
	{"x": 60, "z": 40, "courses": 162},
	{"x": 50, "z": 50, "courses": 102},
	{"x": 80, "z": 60, "courses": 204},
	{"x": 30, "z": 30, "courses": 246},
]
## Set in the SCENE as well as on the command line, so that
## `scenes/big_city.tscn` is something you open and press play on rather than a
## flag you have to remember. `--big` still works and still wins: a scripted
## pass names what it wants and must not be overruled by whichever scene file
## happened to launch it.
@export var big_shapes := false
## How many buildings the city has. The command line's `--buildings=` wins over
## this for the same reason.
@export_range(1, 400) var building_count := 22
## Whether a building may give its bricks back and get them again.
##
## Two things happen when it can. `_trim_quiet` hands the bricks of a quiet,
## distant building back and puts a SHELL in their place; walking up to it
## (`PROMOTE_RANGE`) turns it back into bricks. Both are right for an
## undisturbed building and wrong once something has fallen where it stands:
## the shell is a coarse box over the whole footprint, so rubble lying inside
## that footprint ends up inside the shell's collision, and every brick of it
## is a contact. Jolt's manifold cache is 20,480 contacts and says so.
##
## Off, a building is promoted once and stays promoted. Nothing is handed back
## and nothing reappears. It costs memory -- that is what the trim was for --
## and it is the switch to reach for when something is fighting the physics.
@export var respawn_buildings := true
## The debris cap (Docs/Scale.md section 4.8, IslandManager). Exported because
## it is a player setting in the end -- Teardown ships exactly this pair, and
## the honest thing is to admit the cap exists rather than hide it.
##
## `--debris-small=`, `--debris-large=` and `--debris-total=` override them, so
## a pass can sweep values without editing a scene.
## Measured on --stress --big --buildings=4, which is the case that hurts:
##
##     uncapped        38.0 ms mean, 24.5% of frames over, 510 islands
##     220 / 60 / 240  45.6 ms mean, 37.0% over, 300 islands
##     80 / 24 / 96    33.8 ms mean, 16.5% over, 210 islands
##
## The middle row is the one worth keeping: a cap loose enough to fire
## occasionally pays for the capture a sleep costs without removing enough
## bodies to earn it back. Tight is better than loose, and loose is worse
## than none.
@export_range(0, 2000) var debris_small_max := 80
@export_range(0, 2000) var debris_large_max := 24
@export_range(0, 4000) var debris_total_max := 96
## What happens to the rooms nobody had touched when their building comes
## down. Off: they are written off, every item gone (BuildingRegistry.
## write_off_rooms). On: Interiors §4.1's spill -- the manifest laid into the
## wreck when somebody walks up to it. Off by default, and measured: the spill
## landed in wrecks that were still falling, every piece it laid was joined to
## nothing, and all of it was deleted as small debris by the time the wreck
## came to rest. See --interior-audit.
@export var spill_interiors := false
var _big := false
## Metres between buildings. Big ones need more, or they start inside each
## other -- the shapes above are up to 28 m across against a 13 m pitch.
const BIG_SPACING := 46.0
## The narrowest street between two buildings' footprints, in studs: what the
## small city had at 13 m before its footprints grew (3.2 m).
const STREET_STUDS := 9

var world: BrickWorld
var registry: BuildingRegistry
var islands: IslandManager
var palette := {}

var brick_material: ShaderMaterial

## Shader toggles, held HERE rather than read back from the material.
##
## `get_shader_parameter` returns the value that was ASSIGNED to the material,
## not the default the shader declares -- so a uniform nobody has written
## reads as null, and `var on: bool = <null>` is the crash `B` produced.
## `seams_enabled` only escaped it because `_build_scenery` happens to set it.
##
## Keeping the state on this side means the default is stated once, the
## material is only ever written to, and adding a uniform cannot introduce
## the same bug again.
var _shader_toggles := {
	"seams_enabled": true,
	"chamfer_enabled": true,
}
var stats_label: Label
var camera: DebugCamera
var _placer: CityPlacer

## Per building: the shell it shows while undamaged, and the bricks once it is not.
var _shells := {}          ## building id -> MeshInstance3D
var _shell_bodies := {}    ## building id -> RID
var _brick_nodes := {}     ## building id -> MeshInstance3D
## chunk id -> the MultiMeshInstance3D drawing that chunk's interiors, parented
## to the building's own mesh so it inherits the chunk's transform.
var _furniture := {}
## building id -> the static body its open rooms' furniture collides on, and
## that body's block -> shape indices. See _room_body.
var _room_bodies := {}
var _room_shapes := {}
## Buildings that have had a room laid in them. See _refresh_furniture.
var _furnished := {}
## The DRAWN rung (Scale §4.1 rung 2): building id -> the MultiMeshInstance3D
## drawing its drawn rooms from their manifests, and building id -> {room index
## -> the shape indices its item boxes hold on the building's furniture body}.
## See _sync_drawn.
var _drawn_furniture := {}
var _drawn_shapes := {}
## Building id -> shape indices on its furniture body that are switched off and
## free to be handed out again. A room is drawn and undrawn every time the
## player walks past it, and a body that only ever grows is one whose swap in
## and out of the space gets dearer every time.
var _spare_shapes := {}
## How a building's drawing is cut up. See BrickWorld::set_chunk_section_plates.
##
## Rebuilding a building's mesh is linear in the whole building however few
## bricks changed: ~104 ms for one of the big shapes, and a promotion forces
## one. Bands make a rebuild proportional to the band.
##
## The two numbers pull against each other. Taller bands mean fewer draw calls
## and a bigger rebuild; shorter bands mean the opposite. A cap on the COUNT is
## what keeps a 700-plate tower from becoming thirty draw calls, and a floor on
## the HEIGHT keeps an ordinary building as one or two.
const SECTION_PLATES := 24
const SECTION_MAX := 16
## building id -> its band nodes, its band meshes, and the index bytes each
## band's surface holds. Parallel arrays, one entry per band.
## building id -> the next band to build, for a rebuild in progress.
var _band_cursor := {}
## Buildings that were damaged while their bands were being rebuilt, and so
## need one more pass when this one finishes.
var _band_redo := {}
var _band_cpp_ms := 0.0
var _band_upload_ms := 0.0
var _band_builds := 0
var _band_worst := 0.0
## How much band building a tick may do. A band of one of the big shapes is a
## few milliseconds; the point is that a building's worth of them is not one
## frame's problem.
const BANDS_PER_TICK := 2
const BAND_BUDGET_MS := 6.0
var _brick_bands := {}
var _brick_band_meshes := {}
var _brick_band_bytes := {}
var _brick_meshes := {}    ## building id -> the ArrayMesh whose indices we patch
## Meshes the renderer may still be holding. See MeshRetirer.
var _retirer := MeshRetirer.new()
var _brick_index_bytes := {}  ## building id -> that surface's index buffer length
var _brick_index_width := {} ## building id -> 2 or 4, that surface's index width
var _brick_bodies := {}    ## building id -> RID
## Buildings whose collision has been merged down, and when each was last hit.
##
## A standing building carries ONE BOX PER BRICK, and measured on the
## 200-building stress pass that is 112,321 boxes across 37 buildings against
## 1,827 in all the settled wreckage put together -- the wreckage already merges
## and the buildings did not. So they merge too, on the same rule that works
## for a settled piece: **once it has stopped**.
##
## Not at promotion, and not while it is being shot. Merging a piece at birth
## was tried on the islands and reverted (see IslandManager.spawn) because the
## first hit has to undo it, and the scene pays for two shape builds instead of
## one. A building is materialised BECAUSE something hit it, so merging it then
## would walk into exactly that. It merges when the shooting has moved on.
var _brick_merged := {}
var _last_hit := {}
## How long a building has to have been quiet, and how many may be merged in
## one tick. A merge is one `add_chunk_shapes` over the whole chunk, which is
## the same call promotion makes, so it is budgeted like promotion.
const MERGE_AFTER_MS := 10000
const MERGES_PER_TICK := 1
## The experiment's other arm: rebuild the body exactly as a merge does, but
## per block. If the cost is the same either way, it is the REBUILD and not the
## merged geometry.
const MERGE_SHAPES := true
var _brick_shapes := {}    ## building id -> { block id -> PackedInt32Array }
var _shape_cache := {}
var _materialised: Array[int] = []
var _toppling := {}   ## building id -> already handed to physics
## M4: promotion is ~42 ms, so several landing in one frame is a visible hitch.
## The queue spreads them; a blast's own target is still promoted immediately.
const PROMOTIONS_PER_FRAME := 1
## How close somebody has to be for a building to become bricks on its own.
##
## Promotion used to be damage's job alone, and the comment above ROOM_RANGE
## used to explain why: materialising a tower because somebody walked past it
## looked like the opposite of the point. It is not, because a room can only
## stream for a building that is already bricks -- so an intact building had no
## interior at all, and the FIRST shot into one both materialised it and
## compromised its rooms in the same frame. The furniture arrived in the act of
## being destroyed.
##
## So residency is a distance as well as a hit. The band is chosen by the two
## things on either side of it: far enough outside ROOM_RANGE (26 m) that a
## building is bricks well before its rooms want to open, and far enough inside
## TRIM_RADIUS (90 m) that the trim can never take back what this just gave.
## Six metres ahead of ROOM_RANGE, and that gap is the whole requirement: a
## building has to BE bricks before its rooms are asked for. At walking pace
## six metres is over a second, which is many times what a promotion needs.
## Raising it further was tried and reverted -- it promotes buildings nobody
## is near, and it is rooms that pop in, not buildings.
const PROMOTE_RANGE := 46.0
## Nearest first, two a pass, fifteen passes a second. Promotion is already
## rate-limited downstream -- the queue drains at PROMOTIONS_PER_FRAME and the
## face bake finishes one building a tick -- so this only decides how fast the
## queue fills, and the cap stops a spawn or a teleport queueing a whole
## district at once.
const PROMOTE_PER_PASS := 2
const PROMOTE_QUEUE_MAX := 24
## How many islands may be cut out of standing structure per tick. Splitting a
## 2800-brick section out of its building costs ~6 ms in the extension alone --
## a new chunk, its occupancy grid, and every block copied across -- so eleven
## buildings toppling in the same tick is a third of a second of stall. They
## topple over the next few ticks instead, which nobody can see.
## Cutting islands out of standing structure, budgeted in MILLISECONDS.
##
## It was a count of two, and a count bounds how many things happen rather than
## how long they take -- which is fine while every spawn costs the same and
## wrong as soon as they do not. At 878 islands two spawns measured 43 ms of a
## 91 ms tick. The island manager has used a clock for this reason since the
## collapse work; the building side had not caught up.
const SPAWN_BUDGET_MS := 3.0
## Same shape as DAMAGE_PER_TICK: the count is the cap, the clock is an
## early-out.
const SPAWNS_PER_TICK := 2
## Re-indexing a building's mesh walks every baked face in its chunk, so it is
## linear in the whole building however few bricks left it. Eleven of those in
## one tick was 32 ms; they queue instead. The bricks are already gone from the
## world -- only the picture lags.
const REMESHES_PER_TICK := 2
## And the real budget. See the loop in _physics_process: the count bounds
## how many SMALL patches run, this bounds how much a big rebuild may cost
## the frame it lands in.
const REMESH_BUDGET_MS := 8.0
## Handing a finished bake to the renderer still costs a full mesh build and
## upload -- ~16 ms for a tall building. The shell is still drawn until it
## happens, so there is no reason to do more than one per tick.
const PROMOTE_FINISHES_PER_TICK := 1
## Hits applied per tick. Everything else the tick does is budgeted; incoming
## damage was not, so a burst -- automatic fire, a cluster warhead, or the
## scripted cut that opens every tall building at once -- cost whatever it cost.
## Generous enough that ordinary play never queues.
## Hits applied per tick, and the budget that can cut that short.
##
## The count is the CAP and the clock is an EARLY-OUT -- not the other way
## round. Written the other way (do N, then keep going while under budget) the
## loop does far more than N whenever hits are cheap, which raises per-tick cost
## instead of bounding it: the 22-building collapse measured 16.7 ms mean with a
## plain count of 8 and 75.3 ms with "8, then as many more as fit". A budget
## exists to stop a tick running away, never to increase throughput.
##
## The other half of the same lesson: a MINIMUM of one, with the clock as the
## only other limit, throttled the game to one hit per tick and produced frame
## times that looked superb because the damage was not being applied -- 66 of
## 200 buildings hit instead of all of them.
const DAMAGE_PER_TICK := 8
const DAMAGE_BUDGET_MS := 6.0
## There is deliberately NO upper bound. Capping the loop at 16 was tried on the
## grounds that a budget should bound a tick in both directions, and it made the
## 22-building scene four times worse -- 16.5 ms mean to 75.4. Capping does not
## remove the work, it spreads it over more ticks, so the scene spends far longer
## in the expensive phase instead of a short while. Draining fast is cheaper than
## draining smoothly.
## Side of the lookup grid that answers "which buildings are near this point".
## A blast used to test every registered building; at 5000 that is 5000 AABB
## tests per shot.
const BUILDING_CELL := 32.0
## Buildings re-solved per tick. The solve is the one thing that used to run on
## EVERY materialised building EVERY tick, whether or not anything had happened
## to it -- 270 ms a tick across 45 buildings in the 200-building stress run,
## against 1 ms across 22. Structure only changes when something hits it, so the
## solve is driven by that instead, and budgeted like everything else.
const SOLVES_PER_TICK := 4
const TRIM_AFTER_MS := 12000
const TRIM_RADIUS := 90.0
## How often the trim runs, and how much it may do when it does.
##
## This used to be two buildings every 120 physics frames -- one every two
## seconds. Reclaiming the 163 buildings a player can put out of range in a
## single firefight would have taken five and a half minutes, so a damaged city
## grew without bound and the memory report looked like a leak. It was a budget
## set an order of magnitude below the rate damage arrives at.
##
## Same shape as every other budget here: the count is the cap, the clock is an
## early-out.
const TRIM_EVERY := 30
const TRIM_PER_RUN := 8
const TRIM_BUDGET_MS := 6.0
## M4 streaming, far tier. Beyond SHELL_RANGE a registered building has no node,
## no mesh and no collider -- it is a recipe and a damage record, and costs what
## those cost. The hysteresis band stops a building on the line from building
## and freeing its shell every frame as the camera drifts.
const SHELL_RANGE := 260.0
## How far a shot carries. Buildings past SHELL_RANGE have no collision, so
## anything beyond that band is resolved against recipes -- see _ray_recipes.
const FIRE_RANGE := 2000.0

## Middle tier: resident bricks, no mesh.
##
## A materialised building is skipped by _stream_shells, so it draws full brick
## geometry however far away it is. Measured at the peak of a 200-building
## stress run: 114 of 185 resident buildings were past SHELL_DETAIL_RANGE and
## held 62% of the blocks. Nobody resolves a stud at 150 m.
##
## So past this range a building drops its bake and its brick mesh and draws a
## coarse shell -- but KEEPS its chunk and its collision. The damage record
## stays live, a shot still lands on real bricks, and the whole thing is
## reversible in a tick.
##
## _trim_quiet eventually de-materialises these anyway (TRIM_RADIUS is 90 m,
## inside this), and when it does it reclaims more. The point of this tier is
## speed: the trim will not touch a building until it has been quiet for
## TRIM_AFTER_MS, and the peak is made of buildings that have not been quiet
## yet. This gives the bake back within a tick of the building going out of
## range.
const DEMESH_RANGE := 110.0
const DEMESH_HYSTERESIS := 20.0
## Do not strip a building that is still being shot at; materialised_at is
## refreshed by every _promote, so it reads as "last touched".
const DEMESH_AFTER_MS := 2000
const DEMESH_PER_TICK := 4
const DEMESH_BUDGET_MS := 2.0
const SHELL_HYSTERESIS := 30.0
## Inside this, a shell gets its course banding. Outside it, a course is thinner
## than a pixel and the coarse tier is indistinguishable for ~1.2% of the
## triangles.
const SHELL_DETAIL_RANGE := 110.0
## Making a shell is ~0.4 ms and freeing one is less, so a handful per tick is
## invisible and still keeps up with anything short of teleporting.
const SHELLS_PER_TICK := 4
var _promote_queue: Array[int] = []
var _remesh_queue: Array[int] = []
## Materialised, collidable, still drawn by its shell: waiting on a worker to
## finish baking its faces.
var _pending_bricks: Array[int] = []
## building id -> process frame before which its remesh must wait.
var _remesh_hold := {}
var _demesh_ms := 0.0
var _demeshed := 0
var _remeshed_back := 0
var _trim_split := {"demat": 0.0, "free": 0.0, "shell": 0.0}
var _trim_ms := 0.0
var _trims := 0
var _damage_queue: Array = []
var _pending_disable := {}
## Lookup grid cell -> building ids whose footprint touches it.
var _building_grid := {}
## building id -> its box in the world. See _world_box.
var _world_boxes := {}
var _near_promotions := 0
## The one door every structural change goes through, and the log of every
## command that went through it -- for replay, saving and the wire. This scene
## is always the host today; see WorldAuthority for what a client does instead.
var authority := WorldAuthority.new()
## Buildings whose structure has changed and not yet been re-solved to rest.
var _dirty: Array[int] = []
var _impact_damage := 0
var _full_rebuilds := 0
var _merges := 0
var _unmerges := 0
var _merged_boxes := 0
var _merge_ms := 0.0
var _merge_worst := 0.0
var _unmerge_ms := 0.0
var _show_grids := false
var _grid_count := 0
var _grid_view: MeshInstance3D
## How wide the next shot hits, in metres. The wheel sets it; the reticle draws
## it at the range it is actually pointing at, because a radius in metres means
## nothing to the eye until it is a circle over the wall it is about to remove.
## How close the player has to be for a room to hold its contents, and how far
## before it lets go of them. Interiors section 3's hysteresis, so standing in a
## doorway does not thrash.
##
## Rooms are only streamed for buildings that are ALREADY bricks -- which is
## why buildings become bricks for being NEAR and not only for being shot; see
## PROMOTE_RANGE.
## Raised from 26. A room that opens at 26 m opens where the player can watch
## it happen, which is what "the interiors pop in" is. At 40 it is furnished
## before there is anything to notice, and a room costs 0.9 ms.
const ROOM_RANGE := 40.0
const ROOM_SLEEP_RANGE := 58.0
## Everything inside ROOM_RANGE is DRAWN -- the manifest on screen, a box per
## item, no blocks (Scale §4.1 rung 2). A room becomes REAL bricks only when it
## is touched: a blast reaching it (compromise_rooms), or the player standing
## within ROOM_REACH of it on its own storey. Scale §4.3: distance decides
## drawn, interaction decides real -- promoting on distance is what made
## interiors cost what exists rather than what is used.
##
## 1.5 m is inside the room, in its doorway, or hugging the wall it shares with
## the next one. Only the player's own storey is asked: the room overhead is
## 1.2 m from the eye, through a slab nobody can reach through.
const ROOM_REACH := 1.5
## And it goes back to drawn past this. The gap is the hysteresis that keeps a
## player pacing a doorway from laying and lifting the same room every pass.
const ROOM_REACH_RELEASE := 4.0
## How many rooms a pass may DRAW. A drawn room is a manifest and a buffer --
## tens of microseconds -- so this is a guard on a teleport, not a budget.
const ROOM_DRAWS_PER_PASS := 96
## How many rooms a streaming pass may open, and how many milliseconds it may
## spend doing it.
##
## One a pass was right when a room cost 225 ms and wrong the moment it cost
## 0.9: at one every fourth physics tick that is seven rooms a second, and a
## storey of the big shapes is eighty of them. Walking into a building meant
## watching it furnish for ten seconds.
##
## The budget is the real limit and the count is the guard on it. Rooms are not
## all the same size -- an empty one costs nothing, a shelf costs four bricks
## and a table five -- so a pass stops on whichever it reaches first.
const ROOMS_PER_PASS := 16
const ROOM_BUDGET_MS := 3.0
## How many storeys either side of the player's own a room may be and still be
## walked into: one flight up or down.
const ROOM_STOREY_SPAN := 1
## How far a room can be seen into, and so how far its building's rooms are
## FAKED: drawn unlit from the manifest with no collision at all (Scale §4.1).
## Interiors section 7 question 2 asks exactly this -- a sniper looking through
## a window 300 m away technically sees a room -- and a distance cap is the
## answer it expects.
##
## It used to be a portal test: a distance, a view cone and a ray through each
## opening, twenty-four rooms and sixteen rays a pass, and a room seen into was
## DRAWN, collision and all. Faking every outer room in range is cheaper than
## asking which ones are being looked at, and it has no answer to get wrong.
const ROOM_VIEW_RANGE := 70.0
## And the range a building's fake is dropped at. The gap keeps a building on
## the boundary from building and dropping it every pass.
const ROOM_VIEW_RELEASE := 85.0
## How many buildings a pass may (re)build the fake of. A fresh one runs the
## manifest of every outer room in the building -- a few milliseconds for the
## big shapes -- and walking into a district would otherwise pay for all of it
## in one tick.
const FAKE_BUILDS_PER_PASS := 1
## And how many rooms' drawings it may work out doing so. A cold building of the
## big shapes is 150 manifests and 15 ms; at this many a pass it fills in over
## three or four passes instead, the rooms nearest the ground first -- a
## quarter of a second at the edge of view, which is where it happens.
const FAKE_ROOMS_PER_PASS := 48
## How many rooms a pass may ACTIVATE while trying to place ROOMS_PER_PASS of
## them. A room generated with nothing in it lays no bricks and costs no
## collision, so it should not spend the pass -- but it still must not be able
## to spend the whole district either.
const ROOM_TRIES_PER_PASS := 6
## Building id -> the chunk its bricks became when it came down. A room that
## was never opened is spilled into THAT, not into a building that no longer
## exists (Interiors section 4.1).
var _wrecks := {}
var _spilled_rooms := 0
var _audit_spilled_moving := 0
var _room_draws := 0
var _room_draw_ms := 0.0
var _room_opens := 0
var _room_lay_ms := 0.0
var _room_shape_ms := 0.0
var _room_open_worst := 0.0
var _room_compromises := 0
var _room_built := 0
var _room_compromise_ms := 0.0
## How close somebody has to be for a spilled room to be laid into the wreck.
## Further than the walking range, because arriving at a collapsed building and
## finding the kitchen in it is the point.
const SPILL_RANGE := 34.0
## Items laid in full per spilled room. Section 4.1's degradation ladder: the
## rest of the manifest is written off rather than built.
const SPILL_ITEMS := 4

var _blast_radius := BLAST_RADIUS
var _reticle: Reticle
## A multi-frame player build draws and collides one node per FRAME.
##
## The root frame goes through the same path a generated building does -- the
## dictionaries above, index patching and all. The frames beyond it get their
## own, deliberately simpler, path: a player build is small, so a full mesh
## rebuild costs less than the bookkeeping that avoids one
## (Docs/BuildMode.md section 10.1 -- under 65,536 vertices nothing can be
## index-patched anyway).
var _frame_nodes := {}    ## building id -> Array[MeshInstance3D], frame 1 first
var _frame_bodies := {}   ## building id -> Array[RID]
var _frame_shapes := {}   ## building id -> Array[Dictionary] block id -> shapes
var _shell_coarse := {}    ## building id -> drawn with the far-far tier
var _stream_cursor := 0
var _shells_made := 0
var _shells_freed := 0
var _shells_swapped := 0

var _shot_mode := false
var _stress_mode := false
var _reach_mode := false
var _lod_mode := false
var _walk_mode := false
var _no_fixtures := false
var _build_mode := false
var _fixture_mode := false
var _dormant_mode := false
var _rooms_mode := false
var _audit_mode := false
var _windows_mode := false
var _interiors_mode := false
## Set by the interiors pass. The streamers and the collision merge run on a
## timer and would rebuild the body underneath a measurement -- which they did,
## 30 merges and 28 un-merges deep into the first run of it.
var _measuring := false
var _chamfer_mode := false
var _checkpoint_mode := false
var _gun_mode := false
## The player's gun (Docs/AIPlan.md P1): a generated BoomerBorder gun held by a
## GunController. LMB fires it once 1 is pressed; 2 goes back to the debug blast.
var _gun: GunController
var _gun_armed := false
var _gun_library: GunPartLibrary
var _gun_class := 0
## Combat's own seeded RNG -- spread, crits, procs. The host owns it (D9).
var _combat_rng := RandomNumberGenerator.new()
const GUN_CLASSES: Array[StringName] = [&"pistol", &"smg", &"rifle", &"shotgun", &"sniper",
		&"rocket_launcher"]
## `--build[=res://or/user://path.json]`: drop a saved workshop build into the
## city. Empty means nothing was asked for.
var _build_path := ""
const DEFAULT_BUILD_PATH := "user://workshop_build.json"
## How many buildings the stress pass destabilises. Every building is damaged
## either way; this is how many are hit hard enough to come down. -1 means all
## of them, which is the old behaviour -- see `_run_stress_pass`.
var _stress_collapse := 8
var _city_size := 22
var _promotions := 0
var _promote_ms := 0.0
var _frame_worst := 0.0
var _frame_sum := 0.0
var _frame_samples := 0
var _frames_over_30 := 0
var _sampling := false
## The live profiler. F2.
##
## Everything a scripted pass measures is already collected every tick; it was
## only ever PRINTED at the end of a pass, which is no use for the case that
## actually matters -- walking round the city and feeling it stutter. This puts
## the same numbers on screen over a rolling window, so the thing being
## complained about is the thing being measured.
##
## A window rather than a total: what a session did on average ten minutes ago
## says nothing about the hitch that just happened.
var _live_prof := false
const LIVE_WINDOW := 60
var _live_ring: Array = []
var _live_frame_ms: Array = []
var _live_worst := {}
var _live_worst_ms := 0.0
var _live_label: Label
## Frame times bucketed by what the city was doing at the time, because a single
## mean over a whole run cannot answer "does it come back afterwards".
var _phase := ""
var _phys_sum := 0.0
var _proc_sum := 0.0
var _phases := {}
## Per-phase microseconds for the current physics tick, and the breakdown of
## the single worst frame seen. Guessing which phase owns a spike has been wrong
## every time so far, so it is measured.
var _prof := {}
var _prof_worst := {}
var _prof_worst_ms := 0.0
var _prof_sum := {}


func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	_shot_mode = "--shot" in args
	_stress_mode = "--stress" in args
	_reach_mode = "--reach" in args
	_lod_mode = "--lod" in args
	_walk_mode = "--walk" in args
	# For measurement: the same city with nothing fixed to its buildings, so a
	# pass can be compared against one with staircases in it.
	_no_fixtures = "--no-fixtures" in args
	# The gate for a placed creation. It places one whether or not --build was
	# also given, because a pass with nothing to look at proves nothing.
	_build_mode = "--buildshot" in args
	_fixture_mode = "--fixture" in args
	_dormant_mode = "--dormant" in args
	_rooms_mode = "--rooms" in args
	_audit_mode = "--interior-audit" in args
	_windows_mode = "--windows" in args
	# The scene's settings first, the command line over the top of them.
	_big = big_shapes or "--big" in args
	_city_size = maxi(building_count, 1)
	_interiors_mode = "--interiors" in args
	_chamfer_mode = "--chamfer" in args
	_checkpoint_mode = "--checkpoint" in args
	_gun_mode = "--gun" in args
	if _build_mode:
		_build_path = DEFAULT_BUILD_PATH
	for a in args:
		if a == "--build":
			_build_path = DEFAULT_BUILD_PATH
		elif a.begins_with("--build="):
			_build_path = a.split("=", true, 1)[1]
	# Not only in the stress pass. Walking round a city is the reason to want a
	# different number of buildings in it -- and with --big, six shapes is six
	# towers and twenty-two is a district.
	for a in args:
		if a.begins_with("--buildings="):
			_city_size = maxi(1, int(a.split("=")[1]))
		elif a.begins_with("--debris-small="):
			debris_small_max = maxi(0, int(a.split("=")[1]))
		elif a.begins_with("--debris-large="):
			debris_large_max = maxi(0, int(a.split("=")[1]))
		elif a.begins_with("--debris-total="):
			debris_total_max = maxi(0, int(a.split("=")[1]))
	if _stress_mode:
		for a in args:
			if a.begins_with("--collapse="):
				var v: String = a.split("=")[1]
				_stress_collapse = -1 if v == "all" else maxi(0, int(v))

	world = BrickWorld.new()
	world.set_seed(4)
	_build_scenery()
	palette = TowerRecipe.bake_palette(world)
	registry = BuildingRegistry.new(world, palette)

	islands = IslandManager.new()
	islands.small_live_max = debris_small_max
	islands.large_live_max = debris_large_max
	islands.total_live_max = debris_total_max
	islands.name = "Islands"
	add_child(islands)
	islands.setup(world, brick_material, camera)
	islands.on_impact = _on_island_impact
	# A client's shot arrives as a request; the host takes it exactly as it takes
	# its own. Shears are never requested -- they come from the host's physics.
	authority.handle_request = func(e: DamageLog.Entry) -> void:
		if e.kind == DamageLog.Kind.BLAST:
			_damage_queue.append([e.point, e.radius])
		elif e.kind == DamageLog.Kind.CHIP:
			_damage_queue.append([e.point, e.radius, e.limit])
	# Everything the pieces do to themselves is a command too, and only the host
	# lets them do it.
	islands.decides = authority.may_decide()
	islands.on_command = func(e: DamageLog.Entry) -> int:
		var done := authority.commit_entry(e)
		return done.seq if done != null else -1

	_setup_gun()
	_build_city()
	# Loaded now rather than by the first building to come into view of a
	# window: the first fake paid for the shader on top of its own rooms.
	FurnitureMesh.fake_material()
	# F9 reloaded the scene to get here: the city is recipes again, and the
	# checkpoint goes on top of them.
	var root := get_tree().root
	if root.has_meta(CHECKPOINT_META):
		var path: String = root.get_meta(CHECKPOINT_META)
		root.remove_meta(CHECKPOINT_META)
		_restore_checkpoint(path)
	if _build_path != "":
		_place_build(_build_path)
	# P picks up a saved workshop build and places it like a brick
	# (scripts/city_placer.gd); what it places goes through the same
	# index-and-shell path as `_place_build`.
	_placer = CityPlacer.new()
	_placer.name = "Placer"
	add_child(_placer)
	_placer.setup(registry, camera)
	_placer.on_placed = func(id: int) -> void:
		_index_building(id)
		_make_shell(id)
	if _lod_mode:
		_run_lod_pass()
	elif _reach_mode:
		_run_reach_pass()
	elif _walk_mode:
		_run_walk_pass()
	elif _build_mode:
		_run_build_pass()
	elif _fixture_mode:
		_run_fixture_pass()
	elif _dormant_mode:
		_run_dormant_pass()
	elif _interiors_mode:
		_run_interiors_pass()
	elif _audit_mode:
		_run_interior_audit_pass()
	elif _windows_mode:
		_run_windows_pass()
	elif _rooms_mode:
		_run_rooms_pass()
	elif _chamfer_mode:
		_run_chamfer_pass()
	elif _checkpoint_mode:
		_run_checkpoint_pass()
	elif _gun_mode:
		_run_gun_pass()
	elif _stress_mode:
		_run_stress_pass()
	elif _shot_mode:
		_run_shot_pass()


func _exit_tree() -> void:
	for bodies in _frame_bodies.values():
		for rid in (bodies as Array):
			PhysicsServer3D.free_rid(rid)
	for rid in _shell_bodies.values():
		PhysicsServer3D.free_rid(rid)
	for rid in _brick_bodies.values():
		PhysicsServer3D.free_rid(rid)
	for rid in _shape_cache.values():
		PhysicsServer3D.free_rid(rid)


# ---------------------------------------------------------------------------
# The city
# ---------------------------------------------------------------------------

func _build_city() -> void:
	var t0 := Time.get_ticks_usec()
	var shapes: Array = BIG_SHAPES if _big else SHAPES
	# In STUDS, so every building's corner is on the grid by construction
	# rather than by BuildingRegistry.on_grid rounding it there: 13 m was
	# 37.14 studs, and the rounding nudged each tower a different way.
	#
	# And never closer than the widest footprint plus a street. The lattice
	# footprints (up to 44 studs, 15.4 m) outgrew the old 13 m pitch, and two
	# pairs of towers stood 2.45 m inside each other.
	var spacing := roundi((BIG_SPACING if _big else 13.0) / STUD)
	var widest := 0
	for s in shapes:
		widest = maxi(widest, maxi(int(s.x), int(s.z)))
	spacing = maxi(spacing, widest + STREET_STUDS)
	var index := 0
	var side := int(ceil(sqrt(float(_city_size))))
	for row in side:
		for col in side:
			if index >= _city_size:
				break
			var shape: Dictionary = shapes[(row * side + col) % shapes.size()]
			# Close together on purpose: these have to be able to fall on each
			# other, which is the whole point of the scene.
			@warning_ignore("integer_division")
			var half := (side - 1) * spacing / 2
			var pos := BrickWorld.grid_to_world(
					Vector3i(col * spacing - half, 0, row * spacing - half))
			var id := registry.register(shape.x, shape.z, shape.courses,
					Transform3D(Basis(), pos))
			_add_staircase(id, shape.x, shape.z, shape.courses)
			_index_building(id)
			_make_shell(id)
			index += 1
	var ms := (Time.get_ticks_usec() - t0) / 1000.0

	var mem: Dictionary = world.get_memory_report()
	print("[city] %d buildings in %.0f ms — BrickWorld holds %.2f MB across %d chunks" % [
		registry.buildings.size(), ms, float(mem.total_bytes) / 1048576.0, mem.chunks])
	var tris := 0
	for mi in _shells.values():
		@warning_ignore("integer_division")
		var t := (mi as MeshInstance3D).mesh.get_faces().size() / 3
		tris += t
	print("[city] shells: %d triangles total, %.0f per building" % [
		tris, float(tris) / maxf(registry.buildings.size(), 1)])
	_update_hud()


## A spiral staircase up the middle, dormant.
##
## Docs/BuildMode.md section 9: a fixture is a sub-assembly with its own
## materialisation state, and this one costs nothing until somebody walks up to
## it or blows a hole in the wall beside it. Every building in the city gets
## one, which is the point -- if a dormant fixture were not free, twenty-two of
## them would say so immediately and five thousand would be unarguable.
func _add_staircase(id: int, footprint_x: int, footprint_z: int, courses: int) -> void:
	if _no_fixtures:
		return
	# ON a lattice point, so the shaft is exactly one floor cell -- and a cell
	# clear of the exterior walls, which run over the edge cells. Anywhere else
	# it straddles two cells, or cuts through the wall.
	var sx := TowerRecipe.stair_line(footprint_x)
	var sz := TowerRecipe.stair_line(footprint_z)
	if sx < 0 or sz < 0:
		return  # no cell inside the walls for a flight
	var at := Vector3i(sx, TowerRecipe.SLAB_PLATES, sz)
	registry.add_fixture(id, "staircase", {
		"steps": StaircaseRecipe.steps_for_courses(courses),
		"colour": 11,
	}, at)


# ---------------------------------------------------------------------------
# Rooms (Docs/Interiors.md)
# ---------------------------------------------------------------------------

## Open a room: its contents go into the building's own chunk, so they need
## collision on the building's own body and a mesh rebuild to be seen.
## `batch` means the caller has already lifted this building's furniture body
## out of the physics space and will put it back, and will redraw the furniture
## itself once the pass is done. See _stream_rooms.
func _open_room(id: int, index: int, batch: bool = false) -> int:
	var t0 := Time.get_ticks_usec()
	var placed := registry.activate_room(id, index)
	_room_lay_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	if placed <= 0:
		return 0
	var t1 := Time.get_ticks_usec()
	_add_room_shapes(id, index, batch)
	_room_shape_ms += float(Time.get_ticks_usec() - t1) / 1000.0
	# NOT _queue_remesh. A room's contents are not in the building's face bake,
	# so the building's mesh has not changed and re-uploading it would be the
	# whole 225 ms this design exists to remove. What changed is the furniture,
	# and that is its own MultiMesh over its own blocks.
	_furnished[id] = true
	_fake_dirty[id] = true
	if not batch:
		_refresh_furniture(id)
	_room_opens += 1
	_room_open_worst = maxf(_room_open_worst, float(Time.get_ticks_usec() - t0) / 1000.0)
	return placed


## Shut one. The shapes cannot be taken off a body -- `PhysicsServer3D` has no
## remove-shape that keeps the others' indices -- so they are disabled, which is
## what `_disable` already does for a brick that dies.
func _close_room(id: int, index: int) -> void:
	var room := registry.get_room(id, index)
	if room == null or not room.active:
		return
	var leaving := PackedInt32Array()
	for item in room.items:
		leaving.append_array(item.get("blocks", PackedInt32Array()) as PackedInt32Array)
	_disable(id, leaving)
	# Their shapes are free now, and so are the block ids: a chunk can hand a
	# removed block's id out again, and a stale entry here would switch off
	# whatever the next room laid under it.
	var map: Dictionary = _room_shapes.get(id, {})
	var spare: PackedInt32Array = _spare_shapes.get(id, PackedInt32Array())
	for block in leaving:
		if map.has(block):
			spare.append_array(map[block] as PackedInt32Array)
			map.erase(block)
	_spare_shapes[id] = spare
	registry.deactivate_room(id, index)
	_refresh_furniture(id)
	_fake_dirty[id] = true


## Real -> drawn: the bricks come out and the drawing goes back in, keeping
## whatever the room lost while it was real. Scale §4.4, the ladder backwards.
## The caller syncs the drawing (_sync_drawn), once for the pass.
func _demote_room(id: int, index: int) -> void:
	_close_room(id, index)
	registry.draw_room(id, index)


## Put a box on a building's furniture body, in a slot a closed room left if
## there is one. The body must already be out of the space.
func _take_shape(id: int, body: RID, size: Vector3, xform: Transform3D) -> int:
	var spare: PackedInt32Array = _spare_shapes.get(id, PackedInt32Array())
	if spare.is_empty():
		var added := PhysicsServer3D.body_get_shape_count(body)
		PhysicsServer3D.body_add_shape(body, _shape_rid(size), xform)
		return added
	var reused: int = spare[spare.size() - 1]
	spare.remove_at(spare.size() - 1)
	_spare_shapes[id] = spare
	PhysicsServer3D.body_set_shape(body, reused, _shape_rid(size))
	PhysicsServer3D.body_set_shape_transform(body, reused, xform)
	PhysicsServer3D.body_set_shape_disabled(body, reused, false)
	return reused


## Make a building's drawn furniture match what the registry says is drawn.
##
## The registry owns the state -- `Room.drawn` -- and everything that changes
## it (drawing, promotion by a blast, a topple) leaves this to catch up. It is
## a diff of room indices, so a pass that changed nothing costs a dictionary
## walk and no physics at all.
func _sync_drawn(id: int) -> void:
	var b := registry.get_building(id)
	if b == null:
		return
	var held: Dictionary = _drawn_shapes.get(id, {})
	var want := {}
	for index in b.drawn_rooms:
		want[index] = true
	var going := []
	for index in held:
		if not want.has(index):
			going.append(index)
	var coming := []
	for index in want:
		if not held.has(index):
			coming.append(index)
	if going.is_empty() and coming.is_empty():
		return
	var ft := Time.get_ticks_usec()
	var body := _room_body(id) if b.is_materialised() else RID()
	if body.is_valid():
		PhysicsServer3D.body_set_space(body, RID())
		var spare: PackedInt32Array = _spare_shapes.get(id, PackedInt32Array())
		for index in going:
			for shape in (held[index] as PackedInt32Array):
				PhysicsServer3D.body_set_shape_disabled(body, shape, true)
				spare.push_back(shape)
		_spare_shapes[id] = spare
		for index in coming:
			var room := registry.get_room(id, index)
			var mine := PackedInt32Array()
			for box in room.drawn_boxes:
				mine.push_back(_take_shape(id, body, box.size,
						Transform3D(Basis(), box.position + box.size * 0.5)))
			held[index] = mine
		PhysicsServer3D.body_set_space(body, get_world_3d().space)
	for index in going:
		held.erase(index)
	_drawn_shapes[id] = held
	if _brick_nodes.has(id):
		FurnitureMesh.attach_drawn(registry.drawn_rooms_of(id), _brick_nodes[id],
				_drawn_furniture, id)
	_drawn_ms += float(Time.get_ticks_usec() - ft) / 1000.0
	_drawn_syncs += 1
	# A room that went to drawn leaves the fake; one that came back joins it.
	_fake_dirty[id] = true


## A piece of this building just came away. Any drawn room with an item that
## was standing on it is undrawn; the next streaming pass draws it again, and
## drawing asks whether each item still has a floor (RoomManifest.draw_items).
## Without this, a drawn room's furniture hung where its floor had been --
## drawn from a manifest that had no way to know.
func _recheck_drawn(id: int) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or b.drawn_rooms.is_empty():
		return
	var origin: Vector3i = world.get_chunk_origin(b.chunk)
	var cs := BrickWorld.get_cell_size()
	var changed := false
	for index in b.drawn_rooms.duplicate():
		var room := registry.get_room(id, index)
		for item_box in room.drawn_boxes:
			var cell := Vector3i(roundi(item_box.position.x / cs.x),
					roundi(item_box.position.y / cs.y),
					roundi(item_box.position.z / cs.z)) + origin
			var sx := maxi(roundi(item_box.size.x / cs.x), 1)
			var sz := maxi(roundi(item_box.size.z / cs.z), 1)
			var held := false
			for x in sx:
				for z in sz:
					if world.is_solid(b.chunk, Vector3i(cell.x + x, cell.y - 1, cell.z + z)):
						held = true
						break
				if held:
					break
			if not held:
				registry.undraw_room(id, index)
				changed = true
				break
	if changed:
		_sync_drawn(id)
	# And the fake: every outer room's floor has to be asked again, so every
	# cached drawing of this building is stale.
	for room in registry.rooms_of(id):
		room.fake_gone = -1
	_fake_dirty[id] = true


## Everything drawn for a building goes, with the bricks it was drawn in.
func _drop_drawn(id: int) -> void:
	FurnitureMesh.drop(id, _drawn_furniture)
	_drawn_shapes.erase(id)
	_drop_fake(id)


# ---------------------------------------------------------------------------
# The fake rung (Docs/Scale.md section 4.1)
# ---------------------------------------------------------------------------

## Building id -> the MultiMeshInstance3D drawing its FAKED rooms, and building
## id -> which room indices that drawing holds. See _sync_fake.
var _fake_furniture := {}
var _fake_rooms := {}
## Buildings whose room sets have changed since their fake was built.
var _fake_dirty := {}
var _fake_ms := 0.0
var _fake_builds := 0


## Fake, or stop faking, the buildings around the player.
##
## Every outer room of a standing building that is bricks and within
## ROOM_VIEW_RANGE, and that is not drawn or real already, is drawn from its
## manifest with no collision and no lighting. Only buildings whose rooms have
## changed are rebuilt, a building's at a time.
func _stream_fake(here: Vector3) -> void:
	var built := 0
	var near := {}
	for id in _near_buildings(here, ROOM_VIEW_RELEASE):
		var b := registry.get_building(id)
		if b == null or not b.is_materialised() or b.is_build() or b.toppled:
			continue
		if not _brick_nodes.has(id):
			continue  # demeshed: nothing to hang it from until it is redrawn
		var d := _box_distance(registry.local_box(id), b.xform.affine_inverse() * here)
		if d > ROOM_VIEW_RELEASE:
			continue
		near[id] = true
		var have := _fake_rooms.has(id)
		if have and not _fake_dirty.has(id):
			continue
		if not have and d > ROOM_VIEW_RANGE:
			continue
		if built >= FAKE_BUILDS_PER_PASS:
			continue
		_sync_fake(id)
		built += 1
	for id in _fake_rooms.keys():
		if not near.has(id):
			_drop_fake(id)


## Rebuild one building's fake from the rooms that want it.
func _sync_fake(id: int) -> void:
	var t0 := Time.get_ticks_usec()
	_fake_dirty.erase(id)
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not _brick_nodes.has(id):
		_drop_fake(id)
		return
	var want: Array[Room] = []
	var indices := PackedInt32Array()
	var offset := Vector3i.ZERO
	var worked := 0
	var more := false
	for room in registry.rooms_of(id):
		if not room.outer or room.drawn or room.active or room.spilled:
			continue
		if room.fake_gone != room.gone.size() or room.fake_gone < 0:
			if worked >= FAKE_ROOMS_PER_PASS:
				more = true
				continue
			worked += 1
			if room.items.is_empty():
				room.items = RoomManifest.items_for(room)
			room.fake_buffer = RoomManifest.draw_items(world, b.chunk, registry.palette,
					room, offset).buffer
			room.fake_gone = room.gone.size()
		if room.fake_buffer.is_empty():
			continue
		want.append(room)
		indices.push_back(room.id)
	_fake_rooms[id] = indices
	FurnitureMesh.attach_fake(want, _brick_nodes[id], _fake_furniture, id)
	if more:
		_fake_dirty[id] = true  # the rest next pass
	_fake_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	_fake_builds += 1


func _drop_fake(id: int) -> void:
	FurnitureMesh.drop(id, _fake_furniture)
	_fake_rooms.erase(id)
	_fake_dirty.erase(id)


## Collision for what a room just laid, appended to the building's body.
##
## One box per block and no merging: a chair is five blocks, and a room of them
## is a few dozen shapes against a tower's thousands. Every item part is a box,
## so `get_block_ticks` describes it exactly.
## Redraw a building's interiors.
##
## A walk over the decorative blocks of one chunk -- hundreds, against the tens
## of thousands a face bake walks -- and the building's own mesh is not touched
## at all. See FurnitureMesh.
var _phase_gather := 0.0
var _phase_open := 0.0
var _phase_portal := 0.0
var _phase_close := 0.0
var _phase_spill := 0.0
var _furniture_ms := 0.0
var _furniture_calls := 0
var _drawn_ms := 0.0
var _drawn_syncs := 0


func _refresh_furniture(id: int) -> void:
	var _ft := Time.get_ticks_usec()
	# Nothing has ever been laid in this building, so there is nothing to
	# redraw -- and this is the guard that makes the call safe to put on the
	# damage path. get_decorative_blocks walks every block in the chunk, so
	# without it a burst of fire at an unfurnished tower paid for a scan of
	# the whole tower per hit. That cost the stress pass a millisecond of
	# mean frame and nine of its damage phase.
	if not _furnished.has(id):
		return
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not _brick_nodes.has(id):
		return
	FurnitureMesh.attach(world, b.chunk, _brick_nodes[id], _furniture)
	_furniture_ms += float(Time.get_ticks_usec() - _ft) / 1000.0
	_furniture_calls += 1


## `batch` leaves the body out of the physics space for the caller to put back,
## so that opening several rooms at once pays for one swap rather than one each.
## Opening every room of a 4,000-room building a swap at a time is quadratic and
## measured 11.6 s; batched it is a tenth of a second.
func _add_room_shapes(id: int, index: int, batch: bool = false) -> void:
	var b := registry.get_building(id)
	var room := registry.get_room(id, index)
	if b == null or room == null or not _brick_bodies.has(id):
		return
	var body := _room_body(id)
	if not body.is_valid():
		return
	var map: Dictionary = _room_shapes.get(id, {})
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	if not batch:
		PhysicsServer3D.body_set_space(body, RID())
	for item in room.items:
		for block in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
			var ticks: Array = world.get_block_ticks(b.chunk, block)
			if ticks.is_empty():
				continue
			var lo: Vector3 = Vector3(ticks[0] as Vector3i) * tick_m
			var size: Vector3 = Vector3(ticks[1] as Vector3i) * tick_m
			var at := _take_shape(id, body, size, Transform3D(Basis(), lo + size * 0.5))
			var shapes: PackedInt32Array = map.get(block, PackedInt32Array())
			shapes.push_back(at)
			map[block] = shapes
	_room_shapes[id] = map
	if not batch:
		PhysicsServer3D.body_set_space(body, get_world_3d().space)


## The static body a building's OPEN ROOMS put their collision on.
##
## Not the building's own body, and the reason is the same one that took
## interiors out of the face bake. Adding a room's shapes means lifting the
## body out of the physics space and putting it back, and that call is priced
## by the body's shape count -- on a 50,000-brick tower that is 56,000 shapes,
## and it measured **22 ms for one room**. A separate body carries hundreds.
##
## One per building rather than one per room, because the swap is what costs,
## not the shapes: a building with twenty rooms open is one body of a few
## thousand boxes, and opening the twenty-first pays for those rather than for
## the tower.
##
## It never has to ride anything. A building that comes apart hands its blocks
## to an island, and an island builds its collision from the CHUNK -- decorative
## blocks included -- so the furniture is covered there by a body that already
## exists. This one exists only while the building is standing.
func _room_body(id: int) -> RID:
	if _room_bodies.has(id):
		return _room_bodies[id]
	var b := registry.get_building(id)
	if b == null or not b.is_materialised():
		return RID()
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
	PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			world.get_chunk_transform(b.chunk))
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	_room_bodies[id] = body
	return body


## Take a building's room collision away entirely. Called when the bricks go.
func _free_room_body(id: int) -> void:
	if _room_bodies.has(id):
		PhysicsServer3D.free_rid(_room_bodies[id])
		_room_bodies.erase(id)
	_room_shapes.erase(id)
	_drawn_shapes.erase(id)
	_spare_shapes.erase(id)


## How far a point is from a box. AABB has `has_point` and nothing between, and
## a room is a volume rather than a position -- standing in the doorway of a big
## room is not twenty metres from it because its centre is.
static func _box_distance(box: AABB, point: Vector3) -> float:
	var lo: Vector3 = box.position
	var hi: Vector3 = box.position + box.size
	var out := Vector3(
			maxf(maxf(lo.x - point.x, point.x - hi.x), 0.0),
			maxf(maxf(lo.y - point.y, point.y - hi.y), 0.0),
			maxf(maxf(lo.z - point.z, point.z - hi.z), 0.0))
	return out.length()


## Which rooms are holding their contents, by how close the player is.
##
## Interiors section 3: test ROOMS, not items. They are few and they are
## volumes, so this is a handful of box tests for the buildings that are bricks
## at all.
func _stream_rooms() -> void:
	var here := camera.global_position
	var opened := 0
	# The VIEW range, not the walking range: a hole in a wall is a way to see
	# into a room from further than anybody could walk to it, and scoping this
	# loop to ROOM_RANGE meant the portal test below was never asked.
	# NEAREST FIRST, and that is not a nicety. One room a pass is a queue, and
	# this queue used to be served in grid-cell order: with the whole district
	# around the player resident (PROMOTE_RANGE), the buildings at one corner of
	# the search took every pass and the building the player was standing in was
	# never reached at all. Distance is the only order that means anything here.
	# ASKED, not scanned. Rooms sit on a regular lattice, so which ones are
	# within reach of a point is arithmetic -- and the difference is the
	# whole cost of this pass. Walking every room of every building in view
	# is tens of thousands of box tests fifteen times a second once buildings
	# have four thousand rooms each, whether or not a single one opens.
	# Two lists out of one walk. Everything in range that is not drawn yet is
	# drawn -- a manifest and a buffer, so all of it, nearest first. What the
	# player is close enough to TOUCH is promoted to bricks, and only that
	# (Scale §4.3). The walk used to promote everything it found, which is
	# what made a building with its rooms open +25,537 collision boxes.
	var undrawn: Array = []
	var reach: Array = []
	var here_buildings: Array = []
	var cs := BrickWorld.get_cell_size()
	for id in _near_buildings(here, ROOM_VIEW_RANGE):
		var b := registry.get_building(id)
		if b == null or not b.is_materialised() or b.is_build() or b.toppled:
			continue
		here_buildings.append(b)
		# Measured in the BUILDING's space, with the camera brought into it
		# once. A world AABB per candidate is eight matrix multiplies and an
		# allocation, and a pass standing inside one of the big shapes has a
		# thousand candidates.
		var local: Vector3 = b.xform.affine_inverse() * here
		for index in registry.rooms_in_range(id, here, ROOM_RANGE, ROOM_STOREY_SPAN):
			var room := registry.get_room(id, index)
			if room == null or room.active:
				continue
			var d := room.local_distance(local)
			if d > ROOM_RANGE:
				continue
			if not room.drawn and not room.spilled:
				undrawn.append([d, id, room.id])
			# Its own storey only: between its floor and its ceiling.
			if d <= ROOM_REACH and local.y >= room.lo.y * cs.y \
					and local.y <= (room.lo.y + room.size.y) * cs.y:
				reach.append([d, id, room.id])
	var by_distance := func(a, c) -> bool: return float(a[0]) < float(c[0])
	var redraw := {}
	var t_draw := Time.get_ticks_usec()
	if undrawn.size() > ROOM_DRAWS_PER_PASS:
		undrawn.sort_custom(by_distance)
		undrawn.resize(ROOM_DRAWS_PER_PASS)
	for cand in undrawn:
		registry.draw_room(int(cand[1]), int(cand[2]))
		redraw[int(cand[1])] = true
	_room_draws += undrawn.size()
	_room_draw_ms += float(Time.get_ticks_usec() - t_draw) / 1000.0

	reach.sort_custom(by_distance)
	# A room whose whole manifest is empty activates without laying anything, so
	# it costs nothing and does not count against the pass -- but a handful of
	# them in a row must not turn one pass into a walk over the district.
	var tries := 0
	var until := Time.get_ticks_usec() + int(ROOM_BUDGET_MS * 1000.0)
	# One swap of each building's furniture body in and out of the physics
	# space for the whole pass, and one redraw of its furniture at the end of
	# it. Both are per BUILDING costs -- the swap is priced by the body's
	# shape count and the redraw walks every decorative block in the chunk --
	# so paying them per room made opening a storey quadratic in the storey.
	var touched := {}
	for cand in reach:
		if opened >= ROOMS_PER_PASS or tries >= ROOM_TRIES_PER_PASS:
			break
		if opened > 0 and Time.get_ticks_usec() >= until:
			break
		tries += 1
		var bid: int = int(cand[1])
		if not touched.has(bid):
			var body := _room_body(bid)
			if body.is_valid():
				PhysicsServer3D.body_set_space(body, RID())
			touched[bid] = true
		# Promotion takes the drawing away (activate_room), so this building's
		# drawn furniture has to catch up as well.
		redraw[bid] = true
		if _open_room(bid, int(cand[2]), true) > 0:
			opened += 1
	for bid in touched:
		if _room_bodies.has(bid):
			PhysicsServer3D.body_set_space(_room_bodies[bid], get_world_3d().space)
		_refresh_furniture(bid)

	# And the wreckage: a building that came down still has rooms, and what was
	# in them is owed to whoever walks up to the pile.
	for id in _wrecks.keys():
		var wreck: int = _wrecks[id]
		if not world.is_chunk_alive(wreck):
			_wrecks.erase(id)
			continue
		if opened >= ROOMS_PER_PASS:
			break
		var fell := registry.get_building(id)
		if fell == null:
			continue
		for room in registry.spilled_rooms(id):
			# The room's box travels with the wreck: the chunk's transform is
			# where those bricks ended up.
			var was: Transform3D = world.get_chunk_transform(wreck)
			if _box_distance(room.world_box(was), here) > SPILL_RANGE:
				continue
			var wreck_isl := islands.find_by_chunk(wreck)
			if wreck_isl != null and not wreck_isl.settled:
				_audit_spilled_moving += 1
			if registry.spill_room(id, room.id, wreck, SPILL_ITEMS) > 0:
				_spilled_rooms += 1
				islands.rebuild_chunk(wreck)
				opened += 1
				break

	# The ladder backwards (Scale §4.4). Only what is bricks: `_materialised` is
	# the city's own list, so this is never O(the city) however many buildings
	# there are -- and within one, the registry's lists of what is open and
	# what is drawn, which are a handful and a few hundred against thousands.
	for id in _materialised:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		if b.open_rooms.is_empty() and b.drawn_rooms.is_empty():
			continue
		var local: Vector3 = b.xform.affine_inverse() * here
		# Real -> drawn once out of reach. A room a blast promoted stays real
		# until the old sleep range, because what the blast did to it is
		# half-broken furniture, and the drawing can only show an item whole
		# or not at all.
		for index in b.open_rooms.duplicate():
			var room := registry.get_room(id, index)
			if room == null or not room.active:
				continue
			var d := room.local_distance(local)
			if room.hit:
				if d <= ROOM_SLEEP_RANGE:
					continue
				_close_room(id, index)
				continue
			if d <= ROOM_REACH_RELEASE:
				continue
			_demote_room(id, index)
			redraw[id] = true
		# Drawn -> shut past the sleep range. Its outer rooms go on being seen
		# through the windows -- as the fake, below.
		for index in b.drawn_rooms.duplicate():
			var room := registry.get_room(id, index)
			if room == null or not room.drawn:
				continue
			if room.local_distance(local) <= ROOM_SLEEP_RANGE:
				continue
			registry.undraw_room(id, index)
			redraw[id] = true
	for id in redraw:
		_sync_drawn(id)
	_stream_fake(here)


## The far tier: a shell mesh and five boxes. No bricks anywhere.
## `coarse` picks the far-far tier: a box and a cap instead of a course-banded
## hollow shell. Same collision either way, because a building you can see is a
## building you can shoot, however few triangles it is drawn with.
func _make_shell(id: int, coarse: bool = false) -> void:
	var b := registry.get_building(id)
	var mi := MeshInstance3D.new()
	# G1b: a damaged building that has given its bricks back must still LOOK
	# damaged. A tower takes that as a per-band segment mask, because its shell
	# is generated from parameters and cannot ask "is block N dead"; a BUILD's
	# shell is generated from its recipe and asks exactly that, so its damage is
	# exact rather than approximate (Docs/BuildMode.md section 12, question 3).
	if b.is_build():
		mi.mesh = BuildShell.build_mesh(world, b.build, _dead_by_frame(b), coarse)
	else:
		mi.mesh = (BuildingShell.build_coarse_mesh(b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses)
				if coarse else
				BuildingShell.build_mesh(b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses,
						b.damage_profile))
	mi.material_override = brick_material
	mi.transform = b.xform
	add_child(mi)
	_shells[id] = mi
	_shell_coarse[id] = coarse
	# Its windows, with a room painted behind each: a shell has no openings, so
	# the fake rung cannot show through it. Not on the coarse tier -- past a
	# hundred metres a window is a pixel -- and not on a player build, which
	# has no recipe windows. A child of the shell, so it goes when the shell
	# does, and with its own material so the brick material is untouched.
	if not coarse and not b.is_build():
		var panes := BuildingShell.build_window_mesh(b.recipe.footprint_x,
				b.recipe.footprint_z, b.recipe.courses, registry.room_seed_of(id),
				b.damage_profile)
		if panes != null:
			var glass := MeshInstance3D.new()
			glass.mesh = panes
			glass.material_override = BuildingShell.window_material()
			glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.add_child(glass)

	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
	PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
	var boxes: Array = (BuildShell.collision_boxes(world, b.build, _dead_by_frame(b))
			if b.is_build() else
			BuildingShell.collision_boxes(b.recipe.footprint_x, b.recipe.footprint_z,
					b.recipe.courses))
	for box in boxes:
		PhysicsServer3D.body_add_shape(body, _shape_rid(box.size), Transform3D(Basis(), box.pos))
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, b.xform)
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	if PhysicsServer3D.body_get_shape_count(body) > 0:
		PhysicsServer3D.body_set_shape_disabled(body, 0, false)
	_shell_bodies[id] = body
	# Remember which building a shape belongs to, so a ray hit can name it.
	PhysicsServer3D.body_set_max_contacts_reported(body, 0)


## What is missing from each frame of a build, as one dictionary per frame.
##
## The shell walks block ids, so it wants the record in the form the record is
## already in -- and `dead` is only refreshed when the bricks are handed back,
## which is exactly when a shell is built.
func _dead_by_frame(b: BuildingRegistry.Building) -> Array:
	var out := []
	if not b.is_build():
		return out
	var frames: int = b.build.frame_count()
	for f in frames:
		var gone := {}
		for id in b.dead_in(f):
			gone[id] = true
		out.append(gone)
	return out


func _shape_rid(size: Vector3) -> RID:
	if not _shape_cache.has(size):
		var rid := PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(rid, size * 0.5)
		_shape_cache[size] = rid
	return _shape_cache[size]


# ---------------------------------------------------------------------------
# Promotion — shell to bricks, on damage
# ---------------------------------------------------------------------------

## Applying damage does not require a player to be nearby; only SHOWING debris
## does (Plan §4.4). So this materialises whenever the building is hit, wherever
## the hit came from -- and, since PROMOTE_RANGE, whenever somebody walks up to
## one as well.
##
## `solve` is what tells those two apart. A hit changes the structure and the
## structure has to be re-answered; walking up to an INTACT building changes
## nothing, and a stress pass, a stability check and a detached-group walk over
## every brick in it would all return "nothing happened". The proximity path
## passes `b.is_damaged()`, so a building that was hit, trimmed and has now been
## walked back up to still gets its solve.
func _promote(id: int, solve: bool = true) -> int:
	var b := registry.get_building(id)
	if b == null:
		return -1
	if b.is_materialised():
		return b.chunk

	var t0 := Time.get_ticks_usec()
	var chunk := registry.materialise(id)
	if chunk < 0:
		return -1  # already toppled: its bricks are an island, not a building
	world.set_tension_per_stud(chunk, 9.3)
	_dress(id, chunk, solve)
	_promote_ms += (Time.get_ticks_usec() - t0) / 1000.0
	return chunk


## Everything a materialised building needs to be seen and stood on: its bands,
## its bake, its static body and its mesh node. Split from _promote so a loaded
## checkpoint can replay the damage into the bricks FIRST and dress the building
## after -- the bake and the shapes then start from the damaged building.
func _dress(id: int, chunk: int, solve: bool) -> void:
	# BEFORE the bake is started. Changing the band height invalidates the
	# bake and cancels one in flight, so doing it afterwards cancels the very
	# bake this promotion is waiting on -- the shell never comes down and the
	# building never finishes promoting.
	world.set_chunk_section_plates(chunk, _section_plates(chunk))

	# The shell STAYS UP. Bricks and collision exist from this instant, but the
	# mesh that draws them is baked on a worker and arrives a tick or two later
	# -- and a building that drops its shell before it has a mesh is a building
	# that vanishes for a frame. See _finish_promotions.
	world.bake_chunk_async(chunk)

	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
	PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
	# See IslandManager.spawn: the shapes are built inside the extension, dead
	# blocks disabled as they go.
	var built: Dictionary = world.add_chunk_shapes(body, chunk, Vector3.ZERO, false)
	var map: Dictionary = built.map
	# The CHUNK's transform, not the building's. They are the same thing for a
	# generated tower, and they are not for a build: a multi-frame placement
	# rebases the whole assembly in its transform so the author's lowest brick
	# lands on the ground (BuildingRegistry.materialise).
	var root_x: Transform3D = world.get_chunk_transform(chunk)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, root_x)
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	_brick_bodies[id] = body
	_brick_shapes[id] = map

	var mi := MeshInstance3D.new()
	mi.material_override = brick_material
	mi.transform = root_x
	# A standing building never moves; its mesh is rewritten in place instead.
	# See IslandManager.spawn for why that and interpolation do not mix.
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(mi)
	_brick_nodes[id] = mi
	_pending_bricks.append(id)

	_materialised.append(id)
	_promote_frames(id)
	if solve:
		_mark_dirty(id)
	_promotions += 1


## Bodies and meshes for the frames beyond the root of a multi-frame build.
##
## Each frame is a chunk with its own transform, so each one is its own static
## body and its own mesh -- which is exactly what a frame IS
## (Docs/BuildMode.md section 1). No shell tier and no streaming: a player build
## has no cheap representation yet (section 12, question 3), so it is resident
## from the moment it is placed.
func _promote_frames(id: int) -> void:
	var b := registry.get_building(id)
	if b == null or b.frames.size() < 2 or _frame_bodies.has(id):
		return
	var nodes := []
	var bodies := []
	var shapes := []
	for i in range(1, b.frames.size()):
		var c: int = b.frames[i]
		var xf: Transform3D = world.get_chunk_transform(c)
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
		PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
		world.set_tension_per_stud(c, 9.3)
		var built: Dictionary = world.add_chunk_shapes(body, c, Vector3.ZERO, false)
		PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		PhysicsServer3D.body_set_space(body, get_world_3d().space)
		var mi := MeshInstance3D.new()
		mi.material_override = brick_material
		mi.transform = xf
		mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(mi)
		nodes.append(mi)
		bodies.append(body)
		shapes.append(built.map)
	_frame_nodes[id] = nodes
	_frame_bodies[id] = bodies
	_frame_shapes[id] = shapes
	_remesh_frames(id)


## Rebuild every non-root frame's mesh from scratch.
func _remesh_frames(id: int) -> void:
	var b := registry.get_building(id)
	if b == null or not _frame_nodes.has(id) or b.frames.size() < 2:
		return
	var nodes: Array = _frame_nodes[id]
	for i in range(1, b.frames.size()):
		if i - 1 >= nodes.size():
			break
		var mi: MeshInstance3D = nodes[i - 1]
		var c: int = b.frames[i]
		if world.get_alive_block_count(c) == 0:
			_retirer.retire(mi.mesh)
			mi.mesh = null
			continue
		var arrays: Array = world.build_chunk_mesh(c)
		var mesh := ArrayMesh.new()
		if not arrays.is_empty() and IslandManager.mesh_arrays_ok(arrays, "frame %d" % c):
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_retirer.retire(mi.mesh)
		mi.mesh = mesh


## Disable the collision shapes of blocks a hit removed, in one frame's body.
##
## The root frame's version of this is deferred and batched (see _disable): a
## burst of fire on a tower pays for lifting the body out of the space once per
## hit otherwise. A player build's sideways frames hold a few dozen bricks, so
## they are done as they happen.
func _disable_frame(id: int, frame: int, ids: PackedInt32Array) -> void:
	if ids.is_empty() or not _frame_bodies.has(id) or frame < 1:
		return
	var bodies: Array = _frame_bodies[id]
	var shapes: Array = _frame_shapes[id]
	if frame - 1 >= bodies.size():
		return
	var body: RID = bodies[frame - 1]
	var map: Dictionary = shapes[frame - 1]
	PhysicsServer3D.body_set_space(body, RID())
	for block in ids:
		for shape in (map.get(block, PackedInt32Array()) as PackedInt32Array):
			PhysicsServer3D.body_set_shape_disabled(body, shape, true)
	PhysicsServer3D.body_set_space(body, get_world_3d().space)


## Give the nodes and bodies of the non-root frames back. `keep_meshes` is for
## toppling, where the meshes go to the islands rather than to the renderer's
## retirement queue.
func _free_frames(id: int, keep_meshes: bool = false) -> void:
	for body in (_frame_bodies.get(id, []) as Array):
		PhysicsServer3D.free_rid(body)
	if not keep_meshes:
		for mi in (_frame_nodes.get(id, []) as Array):
			(mi as MeshInstance3D).queue_free()
	_frame_bodies.erase(id)
	_frame_nodes.erase(id)
	_frame_shapes.erase(id)


## Hand over from shell to bricks, once the worker has the faces ready.
##
## This is the second half of promotion. Doing it here rather than inside
## _promote buys two things: the face bake -- the most expensive single step in
## materialising a building -- runs off the main thread, and the shell is still
## drawn for the frame or two in between, so the building never blinks out.
func _finish_promotions() -> void:
	var done := 0
	var i := 0
	while i < _pending_bricks.size() and done < PROMOTE_FINISHES_PER_TICK:
		var id: int = _pending_bricks[i]
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			_pending_bricks.remove_at(i)
			continue
		# A big bake must not hold up a small one queued behind it.
		if not world.bake_ready(b.chunk):
			i += 1
			continue
		_pending_bricks.remove_at(i)
		_remesh(id, true)
		_remesh_frames(id)
		_refresh_furniture(id)
		# And what was drawn while it had no mesh node to hang from -- a
		# building demeshed at range keeps its drawn rooms and their boxes.
		if b.drawn_rooms.size() > 0 and _brick_nodes.has(id):
			FurnitureMesh.attach_drawn(registry.drawn_rooms_of(id), _brick_nodes[id],
					_drawn_furniture, id)
		# And the fake, which went with the mesh node; the next pass rebuilds it.
		_fake_dirty[id] = true
		# The shell stays up until every band is built -- see _advance_bands.
		# Dropping it here would leave a half-drawn building standing in the
		# open for the few ticks the rest of the bands take.
		if not _band_cursor.has(id):
			_free_shell(id)
		done += 1


## Hand a whole building over to the physics, without copying any of it.
##
## A toppling building becomes an island containing *every* block it has. The
## general path cuts that island out with `split_island`, which builds a second
## chunk, allocates a second occupancy grid, copies all 2,800 blocks across one
## at a time and then bakes the result -- to duplicate something that already
## exists and is about to be thrown away. That was 57% of what spawning cost.
##
## So nothing is copied. The chunk, its bake, and the mesh node all move to the
## island as they are; the chunk stops being anchored, and the only new thing is
## a rigid body to carry it. The building's own static body is freed, and the
## registry keeps the recipe and the damage record but lets go of the chunk.
func _topple(id: int) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised():
		return
	# Recorded first: whatever happens to these bricks next happens to a piece,
	# and the piece's id is this command's (DamageLog.piece_id).
	var piece := islands.record_topple(id)
	var chunk := b.chunk
	var mi: MeshInstance3D = _brick_nodes.get(id)
	# Captured before hand_over, which drops the building's claim on them.
	var extra_frames := b.frames.duplicate()
	var extra_nodes: Array = (_frame_nodes.get(id, []) as Array).duplicate()

	# The shell may still be up. Promotion leaves it drawn until the worker has
	# baked the bricks (see _finish_promotions), and a building can become
	# unstable in the tick or two before that happens -- so a toppling building
	# would leave its shell standing, with full collision, and the section
	# falling out of it would lodge inside the shell and get pushed upwards.
	_free_shell(id)

	if _brick_bodies.has(id):
		PhysicsServer3D.free_rid(_brick_bodies[id])
	var carried_mesh: ArrayMesh = _brick_meshes.get(id)
	var carried_bytes: int = int(_brick_index_bytes.get(id, 0))
	var carried_width: int = int(_brick_index_width.get(id, 4))
	# The furniture node goes with the mesh node to the island, and the island
	# then makes its OWN from its own chunk -- so the first one hangs there
	# drawing furniture that has already been redrawn, forever. It is the
	# floating brick over a building that has come down.
	FurnitureMesh.drop(chunk, _furniture)
	_drop_drawn(id)
	# A banded building has no single mesh to hand over -- it has its bands,
	# and they already hold the right geometry. The island draws them until
	# the first thing that changes it, and becomes an ordinary one-mesh
	# island then. See BrickIsland.bands.
	var carried_bands: Array = _take_bands(id)
	_brick_bodies.erase(id)
	# The furniture body belongs to a STANDING building. What is falling
	# carries its own -- an island builds collision from the chunk, and a
	# decorative block is in the chunk like any other.
	_free_room_body(id)
	_furnished.erase(id)
	_brick_nodes.erase(id)
	_brick_meshes.erase(id)
	_brick_index_bytes.erase(id)
	_brick_index_width.erase(id)
	_brick_shapes.erase(id)
	_brick_merged.erase(id)
	_last_hit.erase(id)
	_materialised.erase(id)
	_dirty.erase(id)
	_remesh_queue.erase(id)
	_pending_bricks.erase(id)

	# What was in the rooms. An OPEN room's contents are bricks in this chunk
	# already, so they ride it down (Interiors section 4.2). A shut or drawn
	# one is written off -- or, with spill_interiors, marked spilled to resolve
	# into the wreck when somebody arrives. Either way nothing is built in the
	# middle of a collapse for rooms nobody may ever look at (section 5.1).
	if not b.is_build():
		if spill_interiors:
			registry.mark_rooms_spilled(id)
			_wrecks[id] = chunk
		else:
			registry.write_off_rooms(id)

	# The sideways frames go with it, each as its own piece. A welded assembly
	# coming down in one piece would need the solver to carry the welds, which
	# it does not: a weld is authoring-time structure (Docs/BuildMode.md
	# section 6.3 defers real joints), so what falls is the frames.
	_free_frames(id, true)
	registry.hand_over(id)
	islands.adopt(chunk, mi, carried_mesh, carried_bytes, carried_width, carried_bands,
			piece, id)
	for i in range(1, extra_frames.size()):
		if i - 1 >= extra_nodes.size():
			break
		var node: MeshInstance3D = extra_nodes[i - 1]
		islands.adopt(extra_frames[i], node, null, 0, 4, [], piece + i, id)


## Swap a building's collision between one box per brick and as few boxes as
## the shape allows.
##
## The merged form cannot disable a single block -- a box spans several -- so
## anything about to damage this building calls `_ensure_building_per_block`
## first, exactly as the islands do.
func _reshape_building(id: int, merged: bool) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not _brick_bodies.has(id):
		return
	if bool(_brick_merged.get(id, false)) == merged:
		return
	var _t_reshape := Time.get_ticks_usec()
	var body: RID = _brick_bodies[id]
	var space := PhysicsServer3D.body_get_space(body)
	# Out of the space first: a shape call on a body IN a space costs time
	# proportional to its shape count, and this body has thousands.
	if space.is_valid():
		PhysicsServer3D.body_set_space(body, RID())
	PhysicsServer3D.body_clear_shapes(body)
	# skip_dead now, where promotion cannot: by this point the holes are known,
	# so a dead brick costs no box at all rather than a disabled one.
	var built: Dictionary = world.add_chunk_shapes(body, b.chunk, Vector3.ZERO, true,
			merged and MERGE_SHAPES)
	_brick_shapes[id] = built.map
	_brick_merged[id] = merged
	if space.is_valid():
		PhysicsServer3D.body_set_space(body, space)
	var cost := float(Time.get_ticks_usec() - _t_reshape) / 1000.0
	if merged:
		_merges += 1
		_merged_boxes += int(built.count)
		_merge_ms += cost
		_merge_worst = maxf(_merge_worst, cost)
	else:
		_unmerges += 1
		_unmerge_ms += cost


## About to damage this building, so it needs shapes it can disable one at a
## time.
func _ensure_building_per_block(id: int) -> void:
	if bool(_brick_merged.get(id, false)):
		_reshape_building(id, false)


## Merge the collision of buildings the fighting has moved on from.
##
## One a tick, and only for a building that is not queued for anything: a
## merge undone by the next hit is two shape builds for nothing, which is the
## mistake the island spawn path already records.
func _merge_quiet_buildings() -> void:
	# Not while the scene is busy. A merge is a whole-chunk shape rebuild, and
	# measured on the stress pass it is 5-15 ms of one -- doing that while the
	# damage queue is draining took the phase from 17 ms a frame to 94. This is
	# idle work: it waits for the fighting to stop, which is also when its
	# result is worth having.
	if not _damage_queue.is_empty() or not _dirty.is_empty() 			or not _remesh_queue.is_empty() or not _promote_queue.is_empty() 			or not _pending_bricks.is_empty():
		return
	# And not while anything is still moving. Swapping the shapes of a static
	# body wakes whatever is resting on it, so a rebuild during a settling
	# scene re-activates the whole pile -- which is what the measurement below
	# actually found, and it costs far more than the boxes it saves.
	var isl: Dictionary = islands.report()
	if int(isl.islands) != int(isl.settled):
		return
	var merged := 0
	var now := Time.get_ticks_msec()
	for id in _materialised:
		if merged >= MERGES_PER_TICK:
			break
		if bool(_brick_merged.get(id, false)) or _toppling.has(id):
			continue
		if _dirty.has(id) or _remesh_queue.has(id) or _pending_disable.has(id):
			continue
		if now - int(_last_hit.get(id, 0)) < MERGE_AFTER_MS:
			continue
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		_reshape_building(id, true)
		merged += 1


## Something changed this building's structure, so it needs re-solving.
func _mark_dirty(id: int) -> void:
	if not _dirty.has(id):
		_dirty.append(id)


func _queue_remesh(id: int) -> void:
	if not _remesh_queue.has(id):
		_remesh_queue.append(id)


## Build the surface once, then patch only the index bytes that changed.
##
## Handing Godot a fresh ArrayMesh re-uploads the ENTIRE vertex buffer. For the
## tall buildings here that is ~6.8 MB a time, several times a frame during a
## collapse, and it does not merely cost time -- it exhausted VRAM outright:
##
##     ERROR: Can't create buffer of size: 6772480, error -2.
##
## after which the surface draws with a null vertex array and the renderer
## complains that the vertex count is not a multiple of three. Damage never
## changes a vertex; it changes which baked faces are indexed. Only `place_block`
## invalidates the bake, and nothing calls that after materialisation, so the
## fast path is always available once the surface exists.
func _remesh(id: int, force_full: bool = false) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not _brick_nodes.has(id):
		return
	# A build's other frames are rebuilt whole, every time. They are small, and
	# a surface under 65,536 vertices cannot be index-patched anyway.
	if b.frames.size() > 1:
		_remesh_frames(id)
	# A building that has lost every brick -- which is what toppling does -- has
	# no mesh to patch and no arrays to build. Rebuilding one at that moment
	# means assembling and uploading a third of a million vertices to draw
	# nothing at all, and it was the single most expensive thing left in the
	# tick.
	if world.get_alive_block_count(b.chunk) == 0:
		_retirer.retire((_brick_nodes[id] as MeshInstance3D).mesh)
		for node in _take_bands(id):
			if is_instance_valid(node):
				_retirer.retire((node as MeshInstance3D).mesh)
				(node as MeshInstance3D).queue_free()
		_brick_meshes[id] = null
		_brick_index_bytes[id] = 0
		_brick_index_width[id] = 4
		(_brick_nodes[id] as MeshInstance3D).mesh = null
		return

	# PATCH. One re-index of the chunk, and only the bands whose index bytes
	# actually moved cross to the renderer -- which for a blast is the band it
	# landed in, not the building it landed on.
	# A rebuild already running covers whatever just happened, and restarting
	# it is how a building under sustained fire never finishes one: every hit
	# fails the patch, because the bands it has not reached yet hold no mesh
	# to patch, and the cursor goes back to zero. One more pass is queued
	# instead, and it runs when this one is done.
	if _band_cursor.has(id):
		_band_redo[id] = true
		return
	var bands: Array = _brick_bands.get(id, [])
	if not bands.is_empty() and not force_full:
		var moved: Array = world.update_index_regions(b.chunk,
				int(_brick_index_width.get(id, 4)))
		var held: Array = _brick_band_meshes.get(id, [])
		var byte_counts: Array = _brick_band_bytes.get(id, [])
		var ok: bool = world.get_chunk_sections(b.chunk) == bands.size()
		for entry in moved:
			if not ok:
				break
			var d: Dictionary = entry
			var si: int = int(d.section)
			if si < 0 or si >= held.size() or held[si] == null:
				ok = false
				break
			# The band's buffer is not the length it was, so it cannot be patched
			# in place -- the same rule the whole-mesh path used.
			if int(d.offset) + int(d.changed_bytes) > int(byte_counts[si]):
				ok = false
				break
			RenderingServer.mesh_surface_update_index_region(
					(held[si] as ArrayMesh).get_rid(), 0, int(d.offset), d.data)
		if ok:
			return

	_rebuild_bands(id, b.chunk)


## How tall a band should be for a chunk this tall. See SECTION_PLATES.
func _section_plates(chunk: int) -> int:
	var plates: int = world.get_chunk_dims(chunk).y
	@warning_ignore("integer_division")
	var wanted: int = maxi(SECTION_PLATES, (plates + SECTION_MAX - 1) / SECTION_MAX)
	return wanted


## Build every band of a building's mesh from scratch.
##
## The expensive path, and the one bands exist to make cheaper: it is O(the
## building) and a promotion runs it. What bands change is that the NEXT one --
## a blast, a piece coming off -- is O(the band).
func _rebuild_bands(id: int, chunk: int) -> void:
	_full_rebuilds += 1
	var parent: MeshInstance3D = _brick_nodes[id]
	var n := world.get_chunk_sections(chunk)
	# Slots first, bands afterwards, a few a tick. Building all of them here is
	# what the whole-mesh path did and it is the ~104 ms this exists to remove:
	# the total is the same, what changes is that it no longer lands in one
	# frame. The OLD band stays drawn in its slot until its replacement is
	# ready, so nothing flickers on the way through.
	var old: Array = _brick_bands.get(id, [])
	var nodes: Array = []
	var meshes: Array = []
	var bytes: Array = []
	for si in n:
		nodes.append(old[si] if si < old.size() else null)
		meshes.append(null)
		bytes.append(0)
	for si in range(n, old.size()):
		if is_instance_valid(old[si]):
			_retirer.retire((old[si] as MeshInstance3D).mesh)
			(old[si] as MeshInstance3D).queue_free()
	_brick_bands[id] = nodes
	_brick_band_meshes[id] = meshes
	_brick_band_bytes[id] = bytes
	_band_cursor[id] = 0
	# The parent draws nothing itself; it is the transform the bands hang off
	# and the node the furniture is parented to.
	_retirer.retire(parent.mesh)
	parent.mesh = null
	_brick_meshes[id] = null
	_brick_index_bytes[id] = 0


## Build one band of a building's mesh. Returns false when there are none left.
func _build_one_band(id: int) -> bool:
	var at: int = int(_band_cursor.get(id, -1))
	if at < 0:
		return false
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not _brick_nodes.has(id):
		_band_cursor.erase(id)
		return false
	var nodes: Array = _brick_bands.get(id, [])
	if at >= nodes.size():
		_band_cursor.erase(id)
		return false
	# A band built against a stale bake re-bakes the WHOLE chunk on this
	# thread -- measured at 55 ms against 2.6 for an ordinary band, and it
	# lands in one frame. Wait for the worker instead.
	if not world.has_bake(b.chunk):
		if not world.bake_pending(b.chunk):
			world.bake_chunk_async(b.chunk)
		return true
	var parent: MeshInstance3D = _brick_nodes[id]
	var _t0 := Time.get_ticks_usec()
	var arrays: Array = world.build_chunk_mesh_section(b.chunk, at)
	var _t1 := Time.get_ticks_usec()
	var mesh := ArrayMesh.new()
	if not arrays.is_empty() and IslandManager.mesh_arrays_ok(arrays, "building %d band %d" % [id, at]):
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_brick_index_width[id] = IslandManager.index_width(arrays)
	var _t2 := Time.get_ticks_usec()
	_band_cpp_ms += float(_t1 - _t0) / 1000.0
	_band_upload_ms += float(_t2 - _t1) / 1000.0
	_band_builds += 1
	_band_worst = maxf(_band_worst, float(_t2 - _t0) / 1000.0)
	var node: MeshInstance3D = nodes[at]
	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.material_override = brick_material
		# In the parent's space, which already carries the chunk transform.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		parent.add_child(node)
		nodes[at] = node
	else:
		_retirer.retire(node.mesh)
	var live := mesh.get_surface_count() > 0
	node.mesh = mesh if live else null
	(_brick_band_meshes[id] as Array)[at] = mesh if live else null
	(_brick_band_bytes[id] as Array)[at] = (IslandManager.index_patch_bytes(arrays) if live else 0)
	_band_cursor[id] = at + 1
	if at + 1 >= nodes.size():
		_band_cursor.erase(id)
		return false
	return true


## Drain the band work, a budget at a time.
func _advance_bands() -> void:
	if _band_cursor.is_empty():
		return
	var until := Time.get_ticks_usec() + int(BAND_BUDGET_MS * 1000.0)
	var built := 0
	while built < BANDS_PER_TICK and not _band_cursor.is_empty():
		var id: int = _band_cursor.keys()[0]
		_build_one_band(id)
		built += 1
		if not _band_cursor.has(id):
			if _band_redo.has(id):
				# Something hit it on the way through. Go round once more.
				_band_redo.erase(id)
				var rb := registry.get_building(id)
				if rb != null and rb.is_materialised():
					_rebuild_bands(id, rb.chunk)
			else:
				# Finished: the shell it was hiding behind can go.
				_free_shell(id)
		if Time.get_ticks_usec() >= until:
			break


## Drop a building's band nodes, returning them so a caller can hand them on.
func _take_bands(id: int) -> Array:
	var nodes: Array = _brick_bands.get(id, [])
	_band_cursor.erase(id)
	_band_redo.erase(id)
	_brick_bands.erase(id)
	_brick_band_meshes.erase(id)
	_brick_band_bytes.erase(id)
	return nodes


func _disable(id: int, ids: PackedInt32Array) -> void:
	if ids.is_empty() or not _brick_bodies.has(id):
		return
	# Merged boxes span blocks, so there is nothing to disable one at a time
	# until the shapes are per block again.
	_ensure_building_per_block(id)
	# Interiors are drawn from their own blocks rather than from the face
	# bake, so a blast that takes a chair out has to be told to redraw one.
	_refresh_furniture(id)
	_disable_on(_brick_bodies[id], _brick_shapes.get(id, {}), ids)
	# And the furniture body, if this building has one. A blast does not
	# know which of the two a block it killed was on, so both are asked.
	if _room_bodies.has(id):
		_disable_on(_room_bodies[id], _room_shapes.get(id, {}), ids)


## Switch off the shapes these blocks own on one body.
##
## Lifting the body out of the space first: each shape call costs time
## proportional to the body's shape count, so in a loop it is quadratic.
func _disable_on(body: RID, map: Dictionary, ids: PackedInt32Array) -> void:
	if map.is_empty():
		return
	var any := false
	for bid in ids:
		if map.has(bid):
			any = true
			break
	if not any:
		return
	PhysicsServer3D.body_set_space(body, RID())
	for bid in ids:
		if map.has(bid):
			for shape_index in map[bid]:
				PhysicsServer3D.body_set_shape_disabled(body, shape_index, true)
	PhysicsServer3D.body_set_space(body, get_world_3d().space)


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

## A falling island landed. Hand the other half of the collision to whatever it
## hit -- buildings and other islands alike. Without this a tower can come down
## across its neighbour and leave it untouched, which nobody believes.
func _on_island_impact(source: BrickIsland, point: Vector3, severity: float,
		collider: RID = RID()) -> void:
	# A landing is this machine's physics, and two machines never land a piece in
	# quite the same place. Only the host turns one into structure (AIPlan R5).
	if not authority.may_decide():
		return
	var radius := clampf(severity * 0.12, 0.9, 3.0)

	# The collider the solver named is the answer when there is one. Falling
	# back to "which building's bounding box contains this point" was what made
	# impact damage intermittent: a contact sits ON the surface, so whether it
	# counts as inside depends on which side of the skin the solver put it.
	var named := _building_for_body(collider)
	if named >= 0:
		_shear_building(named, point, radius)
	else:
		for b in registry.buildings:
			var local := b.xform.affine_inverse() * point
			var size := Vector3(b.recipe.footprint_x * STUD,
					TowerRecipe.total_plates(b.recipe.courses) * PLATE,
					b.recipe.footprint_z * STUD)
			if AABB(Vector3.ZERO, size).grow(radius).has_point(local):
				_shear_building(b.id, point, radius)

	islands.shear_near(point, radius, source)


## Shear, not destroy: a brick struck by falling masonry comes loose.
func _shear_building(id: int, point: Vector3, radius: float) -> void:
	var chunk := _promote(id)
	if chunk < 0:
		return
	# peel: masonry landing on a wall knocks a clump of it loose, not a cloud of
	# individual bricks. See BrickWorld::separate_near.
	var loosened: PackedInt32Array = world.separate_near(chunk, point, radius,
			IslandManager.SHEAR_MAX_BLOCKS, true)
	if loosened.is_empty():
		return
	authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SHEAR,
			id, point, radius, Vector3.ZERO, IslandManager.SHEAR_MAX_BLOCKS)
	_impact_damage += loosened.size()
	_mark_dirty(id)
	# Queued, as a blast's is: a landing is inside the islands' own tick, and a
	# rebuild there is paid in the worst tick of a collapse.
	_queue_remesh(id)


## Which building owns a physics body -- shell tier or brick tier, either counts.
func _building_for_body(body: RID) -> int:
	if not body.is_valid():
		return -1
	for id in _brick_bodies:
		if _brick_bodies[id] == body:
			return id
	for id in _shell_bodies:
		if _shell_bodies[id] == body:
			return id
	return -1


## Queue a hit. Applying it is the next tick's problem; see DAMAGE_BUDGET_MS.
## On a client the hit is only asked for: the host applies it and it comes back
## as a committed command.
func _blast(point: Vector3, radius: float) -> void:
	if not authority.request(DamageLog.Kind.BLAST, -1, point, radius):
		return
	_damage_queue.append([point, radius])


## A gun's hit on structure: wear, not destruction. `chip` hp off every brick in
## `radius` and always the one `point` is in (StructuralDamage says how much). Goes
## the same way as a blast -- a client asks, the host queues and commits.
func chip(point: Vector3, radius: float, hp: int) -> void:
	if hp <= 0:
		return
	if not authority.request(DamageLog.Kind.CHIP, -1, point, radius, Vector3.ZERO, hp):
		return
	_damage_queue.append([point, radius, hp])


func _setup_gun() -> void:
	_combat_rng.seed = 0xC0FFEE
	DamageSystem.rng.seed = 0xC0FFEE + 1
	_gun = GunController.new()
	_gun.name = "Gun"
	_gun.rng = _combat_rng
	_gun.aim = camera
	# What a bullet does to bricks is StructuralDamage's to say, and it goes
	# through the same door as every other change to the world.
	_gun.on_structure_hit = func(point: Vector3, _dir: Vector3, shot: Dictionary) -> void:
		if bool(shot.blast):
			_blast(point, float(shot.radius))
		else:
			chip(point, float(shot.radius), int(shot.hp))
	add_child(_gun)
	# The walker's own body is not something to shoot.
	camera.mode_changed.connect(func(walking: bool) -> void:
		var body := camera.body()
		_gun.exclude = [body.get_rid()] if walking and body != null else [] as Array[RID])


## Roll a gun of this class and put it in the player's hands.
func _equip_gun(class_id: StringName, gen_seed: int) -> GunInstance:
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var res := GunGenerator.generate(_gun_library, gen_seed, WeaponClass.builtin(class_id), 1)
	var gi := GunInstance.from_result(res)
	if _gun.gun != null:
		_gun.gun.queue_free()
	camera.add_child(gi)
	gi.position = Vector3(0.22, -0.2, -0.45)
	_gun.equip(gi)
	var shot := StructuralDamage.for_shot(gi.weapon_class, gi.active_effects)
	print("[city] gun: %s -- %s, %s" % [gi.gun_name, class_id,
			("blast %.2f m" % float(shot.radius)) if bool(shot.blast)
			else ("%d hits a brick" % StructuralDamage.hits_per_brick(gi.weapon_class))])
	return gi


## The gate for the player's gun (Docs/AIPlan.md P1): a generated gun, fired at a
## wall, wears bricks through the WorldAuthority and breaks one on the hit
## StructuralDamage says; a living target takes the damage instead of the wall;
## ordnance blasts; and the log -- CHIPs and all -- replays into the same city.
func _run_gun_pass() -> void:
	var b := registry.get_building(0)
	_promote(0)
	await _frames(20)
	var chunk := b.chunk
	# A structural brick in the outer wall at chest height -- not a window, which
	# a round would go straight through into the room behind.
	var xf := world.get_chunk_transform(chunk)
	var face := Vector3.ZERO
	var best := INF
	var mid: float = b.recipe.footprint_x * 0.5 * STUD
	for bx in world.get_block_boxes(chunk):
		var d: Dictionary = bx
		var pos: Vector3 = d.pos
		if not bool(d.alive) or world.is_block_decorative(chunk, int(d.block)) 				or pos.y < 1.2 or pos.y > 2.2:
			continue
		var score := pos.z * 10.0 + absf(pos.x - mid)
		if score < best:
			best = score
			face = xf * pos
	var out := xf.basis * Vector3(0.0, 0.0, -1.0)
	camera.look_at_from_position(face + out * 6.0, face)
	await _frames(2)
	# Dead, not alive: a shot near a window opens the room behind it, and the
	# furniture that puts in the chunk counts as alive.
	var dead0 := world.get_dead_blocks(chunk).size()
	var n0 := authority.commands.size()

	_equip_gun(&"pistol", 7)
	# Dead straight, so every round lands in the same brick.
	_gun.gun.stats[&"accuracy"] = 1.0
	var shots := [0]
	var structural := [0]
	var log_hits: Array = []
	_gun.fired.connect(func(info: Dictionary) -> void:
		shots[0] += 1
		log_hits.append(info)
		if bool(info.get("structure", false)):
			structural[0] += 1)
	await _shoot(1)
	var chips := 0
	for i in range(n0, authority.commands.size()):
		if authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	print("[city] gun gate")
	_gate_ok("one round is one CHIP, on the building it hit",
			chips == 1 and authority.commands.entries[-1].target == 0,
			"%d command(s)" % (authority.commands.size() - n0))
	_gate_ok("and it breaks nothing", world.get_dead_blocks(chunk).size() == dead0)
	await _shoot(StructuralDamage.hits_per_brick(WeaponClass.builtin(&"pistol")) - 1)
	_gate_ok("the round StructuralDamage names breaks the brick",
			world.get_dead_blocks(chunk).size() == dead0 + 1,
			"%d dead -> %d" % [dead0, world.get_dead_blocks(chunk).size()])

	# Something alive in the line of fire takes the bullet instead.
	var target := StaticBody3D.new()
	target.collision_layer = Layers.PAWN
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	col.shape = capsule
	target.add_child(col)
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = 1000.0
	pool.layer_configs = [layer]
	target.add_child(pool)
	add_child(target)
	target.global_position = face + out * 3.0 - Vector3(0.0, 0.2, 0.0)
	await _frames(2)
	var n1 := authority.commands.size()
	var before := pool.total_current()
	await _shoot(2)
	_gate_ok("a living target takes the damage, and the wall none",
			pool.total_current() < before and authority.commands.size() == n1,
			"%.0f -> %.0f hp, %d command(s)" % [before, pool.total_current(),
			authority.commands.size() - n1])
	target.queue_free()
	await _frames(2)

	# An SMG held down: every round a command, none of them a whole brick.
	_equip_gun(&"smg", 11)
	var n2 := authority.commands.size()
	var s0: int = shots[0]
	log_hits.clear()
	_gun.set_trigger(true)
	await _frames(60)
	_gun.set_trigger(false)
	await _shoot(0)
	var fired: int = shots[0] - s0
	for info in log_hits:
		if info.is_empty() or not bool(info.structure):
			print("[city]   round: %s" % ("missed" if info.is_empty() else "hit %s at %v" % [info.collider, info.point]))
	_gate_ok("a held trigger fires at the gun's rate, one command a round",
			fired >= 5 and authority.commands.size() - n2 == fired,
			"%d rounds, %d command(s), %.1f/s rated" % [fired, authority.commands.size() - n2,
			_gun.gun.stats.get(&"fire_rate", 0.0)])

	_equip_gun(&"rocket_launcher", 3)
	_gun.gun.stats[&"accuracy"] = 1.0
	var n3 := authority.commands.size()
	log_hits.clear()
	await _shoot(1)
	var blasts := 0
	for i in range(n3, authority.commands.size()):
		if authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	_gate_ok("ordnance blasts", blasts >= 1, "%d BLAST(s); rounds %s" % [blasts, log_hits])
	await _frames(30)
	await _save("city_gun")
	_check_log_replays()
	print("[city] gun gate: %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Fire `n` single rounds, waiting out the gun's rate between them and the
## damage queue after.
func _shoot(n: int) -> void:
	for i in n:
		while _gun._cooldown > 0.0 or _gun.is_reloading():
			await _frames(1)
		# Held across two ticks: physics_frame is emitted BEFORE the nodes'
		# _physics_process, so a trigger held for one resumption never fires.
		_gun.set_trigger(true)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_gun.set_trigger(false)
	var guard := 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(2)


## Which buildings could a point at `radius` possibly touch. A grid lookup, so
## the answer does not get more expensive as the city grows.
func _near_buildings(point: Vector3, radius: float) -> Array:
	var out := []
	var lo := Vector3(point.x - radius, 0.0, point.z - radius)
	var hi := Vector3(point.x + radius, 0.0, point.z + radius)
	var x0 := int(floor(lo.x / BUILDING_CELL))
	var x1 := int(floor(hi.x / BUILDING_CELL))
	var z0 := int(floor(lo.z / BUILDING_CELL))
	var z1 := int(floor(hi.z / BUILDING_CELL))
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var key := Vector2i(cx, cz)
			if not _building_grid.has(key):
				continue
			for id in _building_grid[key]:
				if not out.has(id):
					out.append(id)
	return out


func _index_building(id: int) -> void:
	var b := registry.get_building(id)
	if b == null:
		return
	# The building's own box, turned into the world. A tower's is its footprint;
	# a multi-frame build's reaches wherever its sideways frames reach, and a
	# placement can be rotated, so the eight corners are what has to be covered.
	# Indexing only the root's footprint meant a shot at a panel hanging off the
	# side found no building at all and did nothing.
	var box := registry.local_box(id)
	var lo := Vector3(INF, 0.0, INF)
	var hi := Vector3(-INF, 0.0, -INF)
	for i in 8:
		var corner: Vector3 = b.xform * (box.position + Vector3(
				box.size.x if (i & 1) else 0.0,
				box.size.y if (i & 2) else 0.0,
				box.size.z if (i & 4) else 0.0))
		lo.x = minf(lo.x, corner.x)
		lo.z = minf(lo.z, corner.z)
		hi.x = maxf(hi.x, corner.x)
		hi.z = maxf(hi.z, corner.z)
	var x0 := int(floor(lo.x / BUILDING_CELL))
	var x1 := int(floor(hi.x / BUILDING_CELL))
	var z0 := int(floor(lo.z / BUILDING_CELL))
	var z1 := int(floor(hi.z / BUILDING_CELL))
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var key := Vector2i(cx, cz)
			if not _building_grid.has(key):
				_building_grid[key] = []
			(_building_grid[key] as Array).append(id)


## `chip` > 0: a gun's wear instead of a blast (DamageLog.Kind.CHIP).
func _apply_blast(point: Vector3, radius: float, chip_hp := 0) -> void:
	# A bullet has no radius, but it still has to find the building it struck.
	var reach := maxf(radius, 0.25)
	# Everything within the blast, not only what the ray touched — a rocket does
	# not care which building it hit first.
	for id in _near_buildings(point, reach):
		var b := registry.get_building(id)
		if b == null:
			continue
		var local := b.xform.affine_inverse() * point
		# A player build has no footprint and no courses; its box comes from the
		# frames it is actually made of.
		var box := registry.local_box(b.id).grow(reach)
		if not box.has_point(local):
			continue
		var t_part := Time.get_ticks_usec()
		var chunk := _promote(b.id)
		t_part = _part("dmg_promote", t_part)
		if chunk < 0:
			continue
		# A COMPROMISED room resolves before the hit lands, whether or not
		# anybody can see it: its contents are part of what the damage does
		# (Interiors section 5). The blast then destroys them like anything
		# else in its way.
		# Only a room somebody could actually see is built. The rest are
		# resolved in the record, which is Interiors section 5.1's own rule and
		# the difference between 20 ms a frame and 108 in a firefight.
		var watched_room: bool = camera != null 				and camera.global_position.distance_to(point) < ROOM_RANGE * 1.5
		var t_room := Time.get_ticks_usec()
		var woke: int = registry.compromise_rooms(b.id, point, radius, watched_room)
		# A drawn room the blast reached was promoted -- or, unwatched, written
		# off -- and either way it is not drawn any more. A faked one likewise:
		# what the blast did to it is in its diff now.
		_sync_drawn(b.id)
		if woke > 0:
			_fake_dirty[b.id] = true
		if woke > 0 and watched_room:
			var fb := _room_body(b.id)
			if fb.is_valid():
				PhysicsServer3D.body_set_space(fb, RID())
				for room in registry.rooms_of(b.id):
					if room.active:
						_add_room_shapes(b.id, room.id, true)
				PhysicsServer3D.body_set_space(fb, get_world_3d().space)
			# A blast furnishes rooms without _open_room ever running, so the
			# building has to be told it holds furniture now or the redraw
			# guard will skip it forever.
			_furnished[b.id] = true
			_refresh_furniture(b.id)
		if woke > 0:
			_room_compromises += woke
			if watched_room:
				_room_built += woke
			var dt := float(Time.get_ticks_usec() - t_room) / 1000.0
			_room_compromise_ms += dt
			_room_open_worst = maxf(_room_open_worst, dt)
		t_part = _part("dmg_rooms", t_part)
		var killed: PackedInt32Array = world.chip_hit(chunk, point, radius, chip_hp) 				if chip_hp > 0 else world.apply_hit(chunk, point, radius)
		t_part = _part("dmg_hit", t_part)
		# Committed as soon as it is applied, so the log's order is the order
		# the world changed in. A chip always: the hp it took is state even
		# when no brick died.
		if chip_hp > 0:
			authority.commit(Engine.get_physics_frames(), DamageLog.Kind.CHIP,
					b.id, point, radius, Vector3.ZERO, chip_hp)
		elif not killed.is_empty():
			authority.commit(Engine.get_physics_frames(), DamageLog.Kind.BLAST,
					b.id, point, radius)
		# Every other frame of a multi-frame build takes the same hit: a blast
		# does not care which grid the brick it removed was authored in.
		if b.frames.size() > 1:
			for fi in range(1, b.frames.size()):
				var hit_frame: PackedInt32Array = 						world.chip_hit(b.frames[fi], point, radius, chip_hp) if chip_hp > 0 						else world.apply_hit(b.frames[fi], point, radius)
				if hit_frame.is_empty() and chip_hp <= 0:
					continue
				# Each frame is its own grid, so each hit is its own command.
				var fe := DamageLog.Entry.new()
				fe.tick = Engine.get_physics_frames()
				fe.kind = DamageLog.Kind.CHIP if chip_hp > 0 else DamageLog.Kind.BLAST
				fe.target = b.id
				fe.frame = fi
				fe.point = point
				fe.radius = radius
				fe.limit = chip_hp
				authority.commit_entry(fe)
				if hit_frame.is_empty():
					continue
				b.hit = true
				_disable_frame(b.id, fi, hit_frame)
				_mark_dirty(b.id)
				_queue_remesh(b.id)
		if killed.is_empty():
			continue
		b.hit = true
		_mark_dirty(b.id)
		# Both the collision update and the remesh are deferred to the end of
		# the tick. _disable lifts the body out of its space and back, and
		# _remesh walks every baked face; doing either once per HIT meant a
		# burst of fire paid for them over and over on the same building.
		_last_hit[b.id] = Time.get_ticks_msec()
		if not _pending_disable.has(b.id):
			_pending_disable[b.id] = PackedInt32Array()
		_pending_disable[b.id].append_array(killed)
		# The damage record is NOT refreshed here. get_dead_blocks walks every
		# block in the building, and a burst of fire would do that once per hit;
		# dematerialise() is the only place the record has to be current, and it
		# captures it there.
		_queue_remesh(b.id)

	# Loose pieces in range are damaged, and everything nearby is woken -- a
	# settled section resting on a wall that has just gone must fall, not hang.
	var t_pieces := Time.get_ticks_usec()
	islands.damage_near(point, radius, chip_hp)
	islands.wake_near(point, reach * 4.0)
	_part("dmg_pieces", t_pieces)


func _fire(radius: float) -> void:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * FIRE_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Layers.HITSCAN_MASK
	var hit := space.intersect_ray(q)

	# A building past SHELL_RANGE has no node at all, so there is nothing for
	# the ray to hit and a shot at a tower on the horizon did nothing. Reach is
	# not something a player should have to know about: line one up, fire, get a
	# hole. So when physics finds nothing nearer, the ray is intersected against
	# the RECIPES -- which cost nothing to keep and exist for every building in
	# the city. The hit then goes through _apply_blast like any other and
	# materialises what it landed on.
	var far_hit := _ray_recipes(from, to)
	if not far_hit.is_empty():
		if hit.is_empty() or from.distance_to(far_hit.position) < from.distance_to(hit.position):
			_blast(far_hit.position, radius)
			return
	if hit.is_empty():
		return
	# If the ray landed on wreckage, damage THAT piece directly. Settled debris
	# is a frozen body whose origin is its centre of mass, so a proximity test
	# from the origin misses a toppled building you are standing next to.
	var struck := islands.find_by_body(hit.collider)
	if struck != null:
		# A client asks; the host's blast finds the same piece by its volume.
		if not authority.request(DamageLog.Kind.BLAST, -1, hit.position, radius):
			return
		islands.damage(struck, hit.position, radius)
		islands.wake_near(hit.position, radius * 4.0)
		return
	_blast(hit.position, radius)


# ---------------------------------------------------------------------------
# Per-tick: collapse whatever is materialised
# ---------------------------------------------------------------------------

## Time a PART of a phase, into the same per-tick record, so the worst tick can
## say what inside `damage` it was: see _report_profile.
func _part(key: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	_prof[key] = float(_prof.get(key, 0.0)) + float(now - t0) / 1000.0
	return now


func _mark(phase: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	_prof[phase] = float(_prof.get(phase, 0.0)) + float(now - t0) / 1000.0
	return now


func _physics_process(_delta: float) -> void:
	_prof = {}
	var t_tick := Time.get_ticks_usec()
	var t := t_tick
	var spawn_until := Time.get_ticks_usec() + int(SPAWN_BUDGET_MS * 1000.0)
	var spawned := 0
	var solved := 0
	# Solving, toppling and detaching decide what a building does next, and on
	# budgets whose timing differs machine to machine. The host decides; a client
	# gets the SOLVE / TOPPLE / DETACH commands instead (AIPlan P0 step 4).
	var decide_limit := SOLVES_PER_TICK if authority.may_decide() else 0
	while solved < decide_limit and not _dirty.is_empty():
		var id: int = _dirty.pop_front()
		solved += 1
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var quiet := true
		var res: Dictionary = world.solve_stress(b.chunk)
		if int(res.get("failures", 0)) > 0:
			quiet = false
			# A solve that failed something changed the structure, and when it
			# ran relative to the hits around it decides what it failed.
			authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SOLVE,
					b.id, Vector3.ZERO, 0.0)
		t = _mark("stress", t)

		# Is what is left actually balanced on what holds it up? Stress cannot
		# answer that -- toppling is a rigid-body question. Without this a tower
		# with half its base gone stands forever, because standing structure is
		# a static body and only a DETACHED piece is ever dynamic.
		var stability: Dictionary = world.check_stability(b.chunk)
		t = _mark("stability", t)
		if not bool(stability.get("stable", true)):
			quiet = false
		if not bool(stability.get("stable", true)) and not _toppling.has(b.id) \
				and spawned < SPAWNS_PER_TICK \
				and (spawned == 0 or Time.get_ticks_usec() < spawn_until):
			_toppling[b.id] = true
			var whole: PackedInt32Array = stability.blocks
			if whole.size() > 0:
				spawned += 1
				print("[city] building %d is toppling: centre of mass %.1f m outside its support, %d bricks" % [
					b.id, float(stability.overhang), whole.size()])
				# Vacate the parent's collision BEFORE the island body joins the
				# space. The other order leaves the two overlapping for one
				# step, and the solver answers an overlap by throwing the
				# lighter body -- which is where floor slabs launched from.
				_topple(b.id)
				t = _mark("spawn", t)
				continue

		var groups: Array = world.find_detached_groups(b.chunk)
		t = _mark("detach", t)
		if groups.is_empty():
			# Nothing failed, nothing is falling, nothing is unbalanced: this
			# building is at rest and does not need looking at again until
			# something hits it.
			if quiet:
				continue
			_mark_dirty(b.id)
			continue
		_mark_dirty(b.id)
		for g in groups:
			if spawned >= SPAWNS_PER_TICK \
					or (spawned > 0 and Time.get_ticks_usec() >= spawn_until):
				break
			spawned += 1
			var before: PackedInt32Array = g
			# Parent first, island second -- see the note above the toppling
			# spawn. spawn() returns null for debris discarded unseen; either
			# way the blocks have left this building.
			_disable(b.id, before)
			t = _mark("disable", t)
			# The detach is a command: WHEN a group leaves is a budget, and timing
			# changes what the next hit does (DamageLog, "Every operation").
			var piece := islands.record_detach(b.id, null, b.chunk, before)
			islands.spawn(b.chunk, before, Vector3.ZERO, Vector3.ZERO, piece, b.id)
			t = _mark("spawn", t)
		# NOW the furniture is redrawn, from what is left. _disable redrew it
		# too, but before the spawn took the blocks out of this chunk -- so the
		# building went on drawing every piece that had just left it, a flat
		# untextured ghost where the floor used to be, until the next hit on
		# this building happened to redraw it again.
		_refresh_furniture(b.id)
		_recheck_drawn(b.id)
		# Keep drawing those bricks until the piece that took them has come up.
		# See IslandManager.OVERLAP_FRAMES.
		# Start a hold, never extend one -- see the same guard in _shed.
		if int(_remesh_hold.get(b.id, -1)) <= Engine.get_process_frames():
			_remesh_hold[b.id] = Engine.get_process_frames() + IslandManager.OVERLAP_FRAMES
		_queue_remesh(b.id)
	# M4: spread promotions rather than letting several land in one frame.
	var hits := 0
	var damage_until := Time.get_ticks_usec() + int(DAMAGE_BUDGET_MS * 1000.0)
	while not _damage_queue.is_empty() \
			and hits < DAMAGE_PER_TICK \
			and (hits == 0 or Time.get_ticks_usec() < damage_until):
		var h: Array = _damage_queue.pop_front()
		_apply_blast(h[0], h[1], int(h[2]) if h.size() > 2 else 0)
		hits += 1
	# One space lift per building per tick, however many hits landed on it.
	var t_dis := Time.get_ticks_usec()
	for id in _pending_disable:
		_disable(id, _pending_disable[id])
	_pending_disable.clear()
	_part("dmg_disable", t_dis)
	t = _mark("damage", t)

	_retirer.drain()
	t = _mark("retire", t)
	_advance_bands()
	t = _mark("bands", t)
	_finish_promotions()
	t = _mark("promote_finish", t)

	var remeshed := 0
	var now_frame := Engine.get_process_frames()
	var remesh_until := Time.get_ticks_usec() + int(REMESH_BUDGET_MS * 1000.0)
	var ri := 0
	while remeshed < REMESHES_PER_TICK and ri < _remesh_queue.size():
		# A count is the wrong budget when the items differ by two orders of
		# magnitude. Patching a small surface is microseconds; rebuilding a
		# 50,000-brick tower is ~53 ms, and two of those landing together was
		# 106 ms of a 162 ms worst tick on --stress --big. One is allowed to
		# overrun -- something has to go first -- and the next waits a tick.
		if remeshed > 0 and Time.get_ticks_usec() >= remesh_until:
			break
		var rid_b: int = _remesh_queue[ri]
		# Held: a piece this building just shed has not come up yet.
		if int(_remesh_hold.get(rid_b, -1)) > now_frame:
			ri += 1
			continue
		_remesh_queue.remove_at(ri)
		_remesh_hold.erase(rid_b)
		_remesh(rid_b)
		remeshed += 1
	t = _mark("remesh", t)

	var promoted := 0
	while promoted < PROMOTIONS_PER_FRAME and not _promote_queue.is_empty():
		var pid: int = _promote_queue.pop_front()
		var pb := registry.get_building(pid)
		_promote(pid, pb == null or pb.is_damaged())
		promoted += 1
	t = _mark("promote", t)

	# M4: buildings that have been quiet and are far away give their bricks
	# back. The damage record stays, so the holes are still there next time.
	if not _measuring:
		if camera != null and Engine.get_physics_frames() % TRIM_EVERY == 0:
			_trim_quiet()
		if Engine.get_physics_frames() % 8 == 5:
			_merge_quiet_buildings()
		# Still every fourth tick. A pass now opens up to ROOMS_PER_PASS rooms
		# rather than one, which is where the speed comes from; running the
		# pass twice as often as well cost the stress pass 2 ms of mean frame
		# for nothing, because the SCAN is the per-pass cost and it is over
		# every room of every building in view.
		if camera != null and Engine.get_physics_frames() % 4 == 3:
			_stream_rooms()
		if camera != null and Engine.get_physics_frames() % 4 == 2:
			_stream_detail()
		if camera != null and Engine.get_physics_frames() % 4 == 1:
			_stream_residency()
	# Every fourth tick is fifteen times a second: far faster than anyone can
	# cross an LOD band, and a quarter of the cost.
	if camera != null and Engine.get_physics_frames() % 4 == 0:
		_stream_shells()
	if _show_grids:
		_draw_grids()
	t = _mark("stream", t)

	islands.tick()
	t = _mark("islands", t)
	# Nobody can read it at 60 Hz, and at 400 islands it was costing more than
	# the stress solve.
	if Engine.get_physics_frames() % 10 == 0:
		_update_hud()
	_mark("hud", t)

	var tick_total := float(Time.get_ticks_usec() - t_tick) / 1000.0
	_prof["script_total"] = tick_total
	if _sampling:
		for k in _prof:
			_prof_sum[k] = float(_prof_sum.get(k, 0.0)) + float(_prof[k])
		if tick_total > _prof_worst_ms:
			_prof_worst_ms = tick_total
			_prof_worst = _prof.duplicate()
			_prof_worst["island_count"] = islands.islands.size()
	if _live_prof:
		_live_ring.append(_prof.duplicate())
		if _live_ring.size() > LIVE_WINDOW:
			_live_ring.remove_at(0)
		if tick_total > _live_worst_ms:
			_live_worst_ms = tick_total
			_live_worst = _prof.duplicate()


func _free_shell(id: int) -> void:
	_shell_coarse.erase(id)
	if _shells.has(id):
		(_shells[id] as MeshInstance3D).queue_free()
		_shells.erase(id)
	if _shell_bodies.has(id):
		PhysicsServer3D.free_rid(_shell_bodies[id])
		_shell_bodies.erase(id)


## A building's box in the world.
##
## `local_box` is in the building's own frame and a placement can be rotated, so
## the eight corners are what has to be covered -- the same reasoning as
## `_index_building`, which needs only the XZ of it. Buildings do not move, so
## the answer is kept.
func _world_box(b: BuildingRegistry.Building) -> AABB:
	if _world_boxes.has(b.id):
		return _world_boxes[b.id]
	var box := registry.local_box(b.id)
	var out := AABB(b.xform * box.position, Vector3.ZERO)
	for i in range(1, 8):
		out = out.expand(b.xform * (box.position + Vector3(
				box.size.x if (i & 1) else 0.0,
				box.size.y if (i & 2) else 0.0,
				box.size.z if (i & 4) else 0.0)))
	_world_boxes[b.id] = out
	return out


## Make buildings near the player bricks, before anything shoots them.
##
## The middle of the LOD ladder was reachable from one direction only: damage
## pushed a building up it and the trim pulled it back down. This is the other
## direction -- walking towards one. See PROMOTE_RANGE.
##
## Measured against the BOX, not the origin: standing with your face against the
## wall of a forty-metre tower is not forty metres from the building, and the
## rooms inside that wall are about to be asked for.
func _stream_residency() -> void:
	# NOT gated on respawn_buildings. Turning that off means a building never
	# gives its bricks BACK -- it was never meant to stop one getting them in
	# the first place, and with it off nothing is ever de-materialised, so
	# there is nothing here that could be a respawn. Gating this as well is
	# what made interiors wait for a building to be shot before they appeared.
	if _promote_queue.size() >= PROMOTE_QUEUE_MAX:
		return
	var here := camera.global_position
	var found: Array = []
	for id in _near_buildings(here, PROMOTE_RANGE):
		var b := registry.get_building(id)
		if b == null or b.is_materialised() or b.toppled or b.is_build():
			continue
		if _promote_queue.has(id):
			continue
		var dist := _box_distance(_world_box(b), here)
		if dist > PROMOTE_RANGE:
			continue
		found.append([dist, id])
	if found.is_empty():
		return
	# Nearest first: the one whose rooms are about to be asked for is the one
	# worth a promotion this pass.
	found.sort_custom(func(a, c) -> bool: return float(a[0]) < float(c[0]))
	for i in mini(PROMOTE_PER_PASS, found.size()):
		_promote_queue.append(int(found[i][1]))
		_near_promotions += 1


## M4, far tier: give distant buildings their shells, take them back when they
## leave. Only a slice of the register is examined per tick -- with 5000
## buildings, walking all of them every frame would cost more than the shells.
##
## A materialised building is never streamed: it holds real bricks and real
## damage, and `_trim_quiet` is what decides when those go.
func _stream_shells() -> void:
	var here := camera.global_position
	var count := registry.buildings.size()
	if count == 0:
		return
	var budget := SHELLS_PER_TICK
	var looked := 0
	var slice := mini(count, SHELLS_PER_TICK * 16)
	while looked < slice and budget > 0:
		var b = registry.buildings[_stream_cursor % count]
		_stream_cursor += 1
		looked += 1
		if b.is_materialised() or b.toppled:
			continue
		var dist: float = b.xform.origin.distance_to(here)
		var has_shell: bool = _shells.has(b.id)
		if not has_shell:
			if dist < SHELL_RANGE:
				_make_shell(b.id, dist > SHELL_DETAIL_RANGE)
				_shells_made += 1
				budget -= 1
			continue
		if dist > SHELL_RANGE + SHELL_HYSTERESIS:
			_free_shell(b.id)
			_shells_freed += 1
			budget -= 1
			continue
		# Tier swap, with the same hysteresis band so a building on the line
		# does not rebuild its mesh every tick.
		var coarse: bool = _shell_coarse.get(b.id, false)
		if coarse and dist < SHELL_DETAIL_RANGE - SHELL_HYSTERESIS:
			_free_shell(b.id)
			_make_shell(b.id, false)
			_shells_swapped += 1
			budget -= 1
		elif not coarse and dist > SHELL_DETAIL_RANGE + SHELL_HYSTERESIS:
			_free_shell(b.id)
			_make_shell(b.id, true)
			_shells_swapped += 1
			budget -= 1


## Drop the mesh of resident buildings nobody can see the bricks of, and put it
## back for ones that have come close again. See DEMESH_RANGE.
func _stream_detail() -> void:
	var here := camera.global_position
	var t0 := Time.get_ticks_usec()
	var until := t0 + int(DEMESH_BUDGET_MS * 1000.0)
	var done := 0
	var now := Time.get_ticks_msec()
	for id in _materialised:
		if done >= DEMESH_PER_TICK:
			break
		if done > 0 and Time.get_ticks_usec() >= until:
			break
		var b := registry.get_building(id)
		if b == null or not b.is_materialised() or _toppling.has(id):
			continue
		var dist: float = b.xform.origin.distance_to(here)
		var meshed: bool = _brick_nodes.has(id)
		if meshed:
			# Hysteresis, so a building on the boundary does not strip and
			# rebuild itself every few ticks.
			if dist <= DEMESH_RANGE + DEMESH_HYSTERESIS:
				continue
			if now - b.materialised_at < DEMESH_AFTER_MS:
				continue
			_demesh(id)
			done += 1
		elif dist < DEMESH_RANGE:
			_remesh_bricks(id)
			done += 1
	_demesh_ms += float(Time.get_ticks_usec() - t0) / 1000.0


## Give back the bake and the mesh; keep the chunk and the collision.
func _demesh(id: int) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised():
		return
	if _brick_nodes.has(id):
		var mi: MeshInstance3D = _brick_nodes[id]
		_retirer.retire(mi.mesh)
		# The band nodes are its children and go with it; their meshes are
		# retired first so the renderer is not still reading them.
		for node in _take_bands(id):
			if is_instance_valid(node):
				_retirer.retire((node as MeshInstance3D).mesh)
		# And the furniture, which is ALSO a child of this node. Freeing the
		# parent takes the node with it but leaves the map pointing at a freed
		# object, and the next attach reads that as "already have one".
		FurnitureMesh.drop(b.chunk, _furniture)
		# The drawing only: the collision stays, as the building's does.
		FurnitureMesh.drop(id, _drawn_furniture)
		_drop_fake(id)
		mi.queue_free()
		_brick_nodes.erase(id)
	_brick_meshes.erase(id)
	_brick_index_bytes.erase(id)
	_brick_index_width.erase(id)
	_pending_bricks.erase(id)
	# The bake is the expensive part -- 3.4 MB a building against a few hundred
	# kilobytes for its occupancy and blocks.
	world.drop_chunk_bake(b.chunk)
	if not _shells.has(id):
		_make_shell(id, true)
	_demeshed += 1


## The camera came back. Rebuild the brick mesh the way a promotion does, so the
## shell stays up until the bake lands -- see _finish_promotions.
func _remesh_bricks(id: int) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or _brick_nodes.has(id):
		return
	world.bake_chunk_async(b.chunk)
	var mi := MeshInstance3D.new()
	mi.material_override = brick_material
	mi.transform = b.xform
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(mi)
	_brick_nodes[id] = mi
	if not _pending_bricks.has(id):
		_pending_bricks.append(id)
	_remeshed_back += 1


## Hand the bricks back for buildings nobody is near. Damage is kept.
func _trim_quiet() -> void:
	if not respawn_buildings:
		return  # nothing is handed back, so nothing has to come back
	var here := camera.global_position
	var freed := 0
	var t0 := Time.get_ticks_usec()
	var trim_until := t0 + int(TRIM_BUDGET_MS * 1000.0)
	for i in range(_materialised.size() - 1, -1, -1):
		var id: int = _materialised[i]
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			_materialised.remove_at(i)
			continue
		if _toppling.has(id):
			continue  # still coming apart
		var dist: float = b.xform.origin.distance_to(here)
		if dist < TRIM_RADIUS:
			continue
		if Time.get_ticks_msec() - b.materialised_at < TRIM_AFTER_MS:
			continue
		_demote(id, dist)
		_materialised.remove_at(i)
		freed += 1
		if freed >= TRIM_PER_RUN:
			break
		if Time.get_ticks_usec() >= trim_until:
			break
	_trim_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	_trims += freed


## Give a building's bricks back and put a shell in their place.
##
## The trim path's body, lifted out so that something other than the trim can
## ask for it -- the gates do, because waiting TRIM_AFTER_MS for a scripted pass
## to prove a building came back as a shell is twelve seconds of nothing.
##
## The caller owns `_materialised`: the trim walks it backwards and removes by
## index, which is not this function's business.
func _demote(id: int, dist: float) -> void:
	var _ta := Time.get_ticks_usec()
	# Before dematerialising, which is what takes the chunk id away: the
	# furniture node is keyed on the chunk, not on the building.
	var gone := registry.get_building(id)
	FurnitureMesh.drop(gone.chunk if gone != null else -1, _furniture)
	_drop_drawn(id)
	_free_room_body(id)
	_furnished.erase(id)
	registry.dematerialise(id)
	_trim_split.demat += float(Time.get_ticks_usec() - _ta) / 1000.0
	_ta = Time.get_ticks_usec()
	if _brick_bodies.has(id):
		PhysicsServer3D.free_rid(_brick_bodies[id])
		_brick_bodies.erase(id)
	if _brick_nodes.has(id):
		(_brick_nodes[id] as MeshInstance3D).queue_free()
		_brick_nodes.erase(id)
	_free_frames(id)
	_take_bands(id)
	_band_cursor.erase(id)
	_brick_meshes.erase(id)
	_brick_index_bytes.erase(id)
	_brick_index_width.erase(id)
	_brick_shapes.erase(id)
	_brick_merged.erase(id)
	_last_hit.erase(id)
	_dirty.erase(id)
	_remesh_queue.erase(id)
	_pending_bricks.erase(id)
	_trim_split.free += float(Time.get_ticks_usec() - _ta) / 1000.0
	_ta = Time.get_ticks_usec()
	# At the detail the distance calls for. This built a FULL shell for every
	# building it trimmed, and everything it trims is by definition past
	# TRIM_RADIUS (90 m) -- so it was paying for near detail on buildings that
	# _stream_shells would have given a coarse one anyway. That was most of the
	# 5.4 ms a trim cost, and the reason the budget only ever allowed one of
	# them per run.
	_make_shell(id, dist > SHELL_DETAIL_RANGE)
	_trim_split.shell += float(Time.get_ticks_usec() - _ta) / 1000.0


func _process(delta: float) -> void:
	_update_reticle()
	_update_live_prof(delta)
	if not _sampling:
		return
	var ms := delta * 1000.0
	# Jolt does not populate the PHYSICS_3D_* counters -- they are Godot Physics
	# bookkeeping and read zero whoever asks, which is why every profile so far
	# has claimed nought active bodies during a collapse. The TIME_ monitors are
	# real, and they are what actually splits a frame up: TIME_PHYSICS_PROCESS
	# includes this script's own tick, so subtracting it leaves the solver.
	var phys_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var proc_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	_phys_sum += phys_ms
	_proc_sum += proc_ms
	if _phase != "":
		var pp: Dictionary = _phases.get(_phase, {})
		if not pp.is_empty():
			pp["phys"] = float(pp.get("phys", 0.0)) + phys_ms
			pp["proc"] = float(pp.get("proc", 0.0)) + proc_ms

	_frame_worst = maxf(_frame_worst, ms)
	_frame_sum += ms
	_frame_samples += 1
	if _phase != "":
		if not _phases.has(_phase):
			_phases[_phase] = {"sum": 0.0, "n": 0, "worst": 0.0, "over": 0}
		var ph: Dictionary = _phases[_phase]
		ph.sum += ms
		ph.n += 1
		ph.worst = maxf(ph.worst, ms)
		if ms > 33.3:
			ph.over += 1
	if ms > 33.3:
		_frames_over_30 += 1


# ---------------------------------------------------------------------------

func _update_hud() -> void:
	if stats_label == null:
		return
	var mem: Dictionary = world.get_memory_report()
	var rep: Dictionary = registry.report()
	var isl: Dictionary = islands.report()
	var rooms: Dictionary = registry.room_report()
	stats_label.text = "\n".join([
		"buildings     %d  (%d materialised, %d damaged)" % [
			rep.buildings, rep.materialised, rep.damaged],
		"bricks        %d live · BrickWorld %.1f MB · %d chunks" % [
			rep.live_blocks, float(mem.total_bytes) / 1048576.0, mem.chunks],
		"islands       %d  (%d settled, %d loose, %d blocks)" % [
			isl.islands, isl.settled, isl.disposable, isl.blocks],
		"asleep        %d piece(s), %d blocks, %.1f KB  (%d slept, %d woken)" % [
			isl.dormant, isl.dormant_blocks, float(isl.dormant_bytes) / 1024.0,
			isl.slept, isl.woken],
		"debris        %d bricks discarded unseen · %d impact(s) sheared %d joint(s)" % [
			isl.discarded, isl.impacts, isl.impact_blocks],
		"promotions    %d in %.0f ms (%.1f ms each), %d queued" % [
			_promotions, _promote_ms, _promote_ms / maxf(_promotions, 1), _promote_queue.size()],
		"impact damage %d brick(s) sheared by falling debris" % _impact_damage,
		"fixtures      %d, built with the buildings that hold them" % rep.fixtures,
		"rooms         %d  (%d open, %d with a diff, %d spilled into wreckage)" % [
			rooms.rooms, rooms.active, rooms.changed, _spilled_rooms],
		"",
		("%s  %d/%d%s   %s (SPACE SPACE)" % [_gun.gun.gun_name, _gun.ammo, _gun.mag_size(),
				"  reloading" if _gun.is_reloading() else "",
				"WALKING" if camera.is_walking() else "FLYING"]) if _gun_armed and _gun.gun != null
			else "blast %.1f m (wheel)   %s (SPACE SPACE)" % [
				_blast_radius, "WALKING" if camera.is_walking() else "FLYING"],
		"1 gun · 2 blast · T next gun · R reload",
		"LMB fire · X big blast · P place a saved build · WASD move · shift fast · G grids · B bevel · J overlap"
			+ "
F1 stats · F2 profiler · F3 reset worst · F5 save · F9 load · N respawn"
			+ ("" if respawn_buildings else "\nRESPAWN OFF (N) — buildings keep their bricks once promoted"),
	])


## What the last second of ticks cost, by phase, worst first.
##
## Drawn from the same `_prof` the scripted passes read, so a number seen here
## and a number in a pass summary mean the same thing.
func _update_live_prof(delta: float) -> void:
	if _live_label == null:
		return
	_live_frame_ms.append(delta * 1000.0)
	if _live_frame_ms.size() > LIVE_WINDOW:
		_live_frame_ms.remove_at(0)
	if not _live_prof or _live_ring.is_empty():
		return
	var mean := {}
	for entry in _live_ring:
		for k in (entry as Dictionary):
			mean[k] = float(mean.get(k, 0.0)) + float(entry[k])
	var n := float(_live_ring.size())
	var phases: Array = []
	for k in mean:
		if k == "script_total":
			continue
		phases.append([float(mean[k]) / n, str(k)])
	phases.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))

	var frame_mean := 0.0
	var frame_worst := 0.0
	for ms in _live_frame_ms:
		frame_mean += float(ms)
		frame_worst = maxf(frame_worst, float(ms))
	frame_mean /= maxf(float(_live_frame_ms.size()), 1.0)

	var lines: Array = []
	lines.append("frame     %6.2f ms mean   %6.2f worst   (%.0f fps)" % [
			frame_mean, frame_worst, 1000.0 / maxf(frame_mean, 0.01)])
	# TIME_PHYSICS_PROCESS includes this script's own tick, so subtracting it
	# leaves the solver. The PHYSICS_3D_* counters are NOT used anywhere here:
	# Jolt does not populate them and they read zero whoever asks.
	var phys := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var script_ms := float(mean.get("script_total", 0.0)) / n
	lines.append("physics   %6.2f ms   script %6.2f   solver ~%6.2f" % [
			phys, script_ms, maxf(phys - script_ms, 0.0)])
	lines.append("")
	lines.append("per tick, mean of the last %d:" % _live_ring.size())
	for i in mini(phases.size(), 8):
		var row: Array = phases[i]
		lines.append("  %-16s %6.2f ms" % [row[1], row[0]])
	if _live_worst_ms > 0.0:
		lines.append("")
		lines.append("worst tick %.2f ms (F3 resets):" % _live_worst_ms)
		var worst: Array = []
		for k in _live_worst:
			if k != "script_total":
				worst.append([float(_live_worst[k]), str(k)])
		worst.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))
		for i in mini(worst.size(), 4):
			var row: Array = worst[i]
			if float(row[0]) < 0.01:
				break
			lines.append("  %-16s %6.2f ms" % [row[1], row[0]])
	var isl: Dictionary = islands.report()
	lines.append("")
	lines.append("islands %d (%d settled, %d loose) · dormant %d" % [
			isl.islands, isl.settled, isl.islands - int(isl.settled), isl.dormant])
	lines.append("resident buildings %d · open rooms %d" % [
			_materialised.size(), int(registry.room_report().active)])
	# The census in one line rather than the full sentence _collision_report
	# writes: this label is 430 pixels wide.
	var boxes := 0
	for bid in _brick_bodies:
		boxes += PhysicsServer3D.body_get_shape_count(_brick_bodies[bid])
	lines.append("collision boxes %d standing · %d falling · %d settled" % [
			boxes, int(isl.get("loose_boxes", 0)), int(isl.get("settled_boxes", 0))])
	_live_label.text = "\n".join(lines)


## Wind the blast up or down a notch.
func _set_blast_radius(r: float) -> void:
	_blast_radius = clampf(r, BLAST_MIN, BLAST_MAX)
	if _reticle != null:
		_reticle.queue_redraw()


## The crosshair, and the only honest way to show a blast radius before it goes
## off: a circle of the size the shot will actually be, at the range the ray
## actually reaches. A fixed-size reticle would say the same thing about a wall
## two metres away and a tower four hundred metres off, and they are not the
## same shot.
class Reticle extends Control:
	var radius_px := 8.0
	var colour := Color(1.0, 1.0, 1.0, 0.85)

	func _draw() -> void:
		var c := size * 0.5
		draw_arc(c, maxf(radius_px, 2.0), 0.0, TAU, 64, colour, 1.5, true)
		draw_line(c - Vector2(6.0, 0.0), c + Vector2(6.0, 0.0), colour, 1.0)
		draw_line(c - Vector2(0.0, 6.0), c + Vector2(0.0, 6.0), colour, 1.0)


## Project the blast sphere onto the screen at whatever the camera is pointing
## at. One ray a frame, which is what a shot costs anyway.
func _update_reticle() -> void:
	if _reticle == null or not _reticle.visible:
		return
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * FIRE_RANGE)
	q.collision_mask = Layers.HITSCAN_MASK
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	# Nothing in front of the camera: draw it at a middle distance rather than
	# collapsing the circle to a dot, which would read as "no blast". The
	# recipes are deliberately NOT rayed here the way _fire does it -- that walk
	# is over every registered building, and a shot pays it once while a reticle
	# would pay it every frame.
	var dist := 60.0
	if not hit.is_empty():
		dist = maxf(from.distance_to(hit.position), 1.0)
	# Vertical FOV, so the half-height of the view at `dist` is what scales it.
	var half_h := tan(deg_to_rad(camera.fov) * 0.5) * dist
	var px := _blast_radius / half_h * (float(get_viewport().get_visible_rect().size.y) * 0.5)
	if absf(px - _reticle.radius_px) > 0.5:
		_reticle.radius_px = px
		_reticle.queue_redraw()


## Flip a shader bool and return its new value. Never reads the material.
func _toggle_shader(param: String) -> bool:
	var on: bool = not bool(_shader_toggles.get(param, true))
	_shader_toggles[param] = on
	brick_material.set_shader_parameter(param, on)
	return on


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed 			and event.button_index == MOUSE_BUTTON_LEFT:
		_gun.set_trigger(false)
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if _gun_armed:
					_gun.set_trigger(true)
				else:
					_fire(_blast_radius)
				return
			MOUSE_BUTTON_WHEEL_UP:
				_set_blast_radius(_blast_radius * BLAST_STEP)
				return
			MOUSE_BUTTON_WHEEL_DOWN:
				_set_blast_radius(_blast_radius / BLAST_STEP)
				return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_X:
			_fire(BIG_BLAST)
		KEY_F1:
			stats_label.visible = not stats_label.visible
		KEY_1:
			_gun_armed = true
			if _gun.gun == null:
				_equip_gun(GUN_CLASSES[_gun_class], _combat_rng.randi())
			_gun.gun.visible = true
		KEY_2:
			_gun_armed = false
			_gun.set_trigger(false)
			if _gun.gun != null:
				_gun.gun.visible = false
		KEY_T:
			_gun_class = (_gun_class + 1) % GUN_CLASSES.size()
			_equip_gun(GUN_CLASSES[_gun_class], _combat_rng.randi())
			_gun_armed = true
		KEY_R:
			if _gun_armed:
				_gun.reload()
		KEY_F5:
			save_checkpoint()
		KEY_F9:
			load_checkpoint()
		KEY_L:
			print("[city] seams: %s" % ("ON" if _toggle_shader("seams_enabled") else "OFF"))
		KEY_B:
			print("[city] chamfered edges: %s"
					% ("ON" if _toggle_shader("chamfer_enabled") else "OFF"))
		KEY_J:
			# The overlap. A piece that has just come off a building is drawn by
			# BOTH for two frames, because on the frame it is born there is
			# otherwise an instant where neither draws those bricks and the
			# building flashes. No readback can see it -- the sync hides it --
			# so the evidence is this toggle: turn it off and the flash returns.
			IslandManager.OVERLAP_FRAMES = 0 if IslandManager.OVERLAP_FRAMES > 0 else 2
			print("[city] overlap frames: %d %s" % [
					IslandManager.OVERLAP_FRAMES,
					"(a new piece and its parent both draw, briefly)"
					if IslandManager.OVERLAP_FRAMES > 0
					else "OFF -- watch for the one-frame flash"])
		KEY_O:
			# Slow motion, so a one-tick artefact lasts long enough to attribute
			# to something. Cycles rather than toggles: 0.05 makes a single
			# physics tick last two thirds of a second.
			var steps := [1.0, 0.25, 0.05]
			var at := steps.find(snappedf(Engine.time_scale, 0.01))
			Engine.time_scale = steps[(at + 1) % steps.size()] if at >= 0 else 1.0
			print("[city] time scale: %.2f" % Engine.time_scale)
		KEY_F2:
			_live_prof = not _live_prof
			_live_ring.clear()
			_live_frame_ms.clear()
			_live_worst = {}
			_live_worst_ms = 0.0
			if _live_label != null:
				_live_label.visible = _live_prof
			print("[city] live profiler: %s" % ("ON" if _live_prof else "OFF"))
		KEY_F3:
			_live_worst = {}
			_live_worst_ms = 0.0
			print("[city] worst frame reset")
		KEY_N:
			respawn_buildings = not respawn_buildings
			print("[city] buildings give their bricks back and take them again: %s"
					% ("ON" if respawn_buildings else "OFF -- promoted once, resident for good"))
			_update_hud()
		KEY_P:
			_placer.toggle(_build_path if _build_path != "" else DEFAULT_BUILD_PATH)
		KEY_G:
			_show_grids = not _show_grids
			if _grid_view != null:
				_grid_view.visible = _show_grids
			if _show_grids:
				_draw_grids()


## Every live chunk as a wireframe box: where its grid is, how big it is, and
## which way it is pointing.
##
## A chunk's grid does NOT rotate when the piece it holds does -- only its
## transform. So a toppled building draws a box lying on its side, and that box
## is still the tall narrow grid it had standing. Seeing that is the whole point
## of the toggle.
##
##   green   standing structure (anchored)
##   orange  a section still falling
##   blue    wreckage that has settled
##   grey    a chunk with nothing alive left in it
func _draw_grids() -> void:
	if _grid_view == null:
		_grid_view = MeshInstance3D.new()
		_grid_view.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = true
		_grid_view.material_override = mat
		_grid_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_grid_view)

	# Which chunks belong to islands, and what those islands are doing.
	var island_state := {}
	for isl in islands.islands:
		if isl.is_valid():
			island_state[isl.chunk] = isl.settled

	var live: Array[int] = []
	for id in world.get_chunk_count():
		if world.is_chunk_alive(id):
			live.append(id)

	# An undamaged city holds no chunks at all. ImmediateMesh has no way to
	# abandon a surface once begun and errors on an empty one, so the surface is
	# only opened when there is something to put in it.
	var im: ImmediateMesh = _grid_view.mesh
	im.clear_surfaces()
	_grid_count = live.size()
	if live.is_empty():
		return

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var stud := BrickWorld.get_cell_size()
	for id in live:
		var dims: Vector3i = world.get_chunk_dims(id)
		var size := Vector3(dims.x * stud.x, dims.y * stud.y, dims.z * stud.z)
		var col := Color(0.35, 0.9, 0.4)          # standing
		if world.get_alive_block_count(id) == 0:
			col = Color(0.5, 0.5, 0.5)            # emptied
		elif island_state.has(id):
			col = Color(0.35, 0.6, 1.0) if bool(island_state[id]) else Color(1.0, 0.6, 0.15)
		_wire_box(im, world.get_chunk_transform(id), size, col)
	im.surface_end()


func _wire_box(im: ImmediateMesh, xform: Transform3D, size: Vector3, col: Color) -> void:
	var c := [
		Vector3(0, 0, 0), Vector3(size.x, 0, 0), Vector3(size.x, 0, size.z), Vector3(0, 0, size.z),
		Vector3(0, size.y, 0), Vector3(size.x, size.y, 0),
		Vector3(size.x, size.y, size.z), Vector3(0, size.y, size.z),
	]
	const EDGES := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	for i in EDGES:
		im.surface_set_color(col)
		im.surface_add_vertex(xform * (c[i] as Vector3))


# ---------------------------------------------------------------------------
# Automated capture
# ---------------------------------------------------------------------------

func _run_shot_pass() -> void:
	camera.position = Vector3(-52.0, 34.0, -52.0)
	camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(4)
	await _save("city_intact")

	# Inside an undamaged building: floors have to be visible from above AND
	# below, and the walls have to read as brick before anything materialises.
	# From a corner room at eye height, looking across the storey: the middle of
	# the building is the stairwell, and a camera there saw only the flight.
	var inside = registry.buildings[0]
	# Mid-panel: columns stand on the lattice lines either side of it.
	var corner := (float(TowerRecipe.WALL_THICK) + TowerRecipe.PANEL * 0.5) * STUD
	camera.position = inside.xform.origin + Vector3(corner,
			PLATE * TowerRecipe.SLAB_PLATES + DebugCamera.EYE_HEIGHT, corner)
	camera.rotation = Vector3(0.15, -2.356, 0.0)
	await _frames(2)
	await _save("city_interior")
	# And looking down at the floor you are standing on, which is the half that
	# was missing.
	camera.position.y = 2.4
	camera.rotation = Vector3(-0.6, 0.6, 0.0)
	await _frames(2)
	await _save("city_interior_down")
	camera.position = Vector3(-52.0, 34.0, -52.0)
	camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(2)

	# --- measurement 1: does one hit take the floors out? --------------------
	# The bug was that any damage at all detached every slab in the building,
	# because a slab was a single layer of plates and our connectivity is
	# vertical only, so no plate in it touched any other.
	var probe = registry.buildings[0]
	_blast(probe.xform.origin + Vector3(probe.recipe.footprint_x * 0.5 * STUD, 0.8, 0.3), 1.4)
	await _frames(2)
	var standing := world.get_block_count(probe.chunk)
	var loose := 0
	for isl in islands.islands:
		if isl.is_valid():
			loose += world.get_block_count(isl.chunk)
	var built := standing + loose
	print("[city] one hit on building %d: %d bricks, %d came loose (%.1f%%)" % [
		probe.id, built, loose, float(loose) / maxf(built, 1) * 100.0])

	# Take out ONE SIDE of the tall ones, all the way up several courses.
	#
	# A horizontal ring does not topple anything -- it just lowers the building
	# onto whatever is left, which is exactly right and looks like nothing. A
	# brick tower falls the way the research says it does: when its centre of
	# mass leaves what is still holding it up. So the cut has to be asymmetric.
	_sampling = true
	for b in registry.buildings:
		if b.recipe.courses < 44:
			continue
		var w: float = b.recipe.footprint_x * STUD
		var d: float = b.recipe.footprint_z * STUD
		# Eat the -X half of the footprint over the bottom eight courses.
		for course in range(0, 8):
			var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * PLATE
			var px := 0.3
			while px < w * 0.55:
				var pz := 0.3
				while pz < d:
					_blast(b.xform.origin + Vector3(px, y, pz), 1.5)
					pz += 2.0
				px += 2.0
	# Damage is budgeted now, so a thousand queued blasts take a few dozen ticks
	# to land. Wait for them rather than photographing a half-cut city.
	var guard := 0
	while not _damage_queue.is_empty() and guard < 600:
		await _frames(1)
		guard += 1
	await _frames(3)
	await _save("city_cut")
	_physics_census("cut")

	await _frames(60)
	await _save("city_falling")
	_physics_census("1 s")

	for k in 4:
		await _frames(60)
		_physics_census("%d s" % (k + 2))
	await _save("city_fallen")

	# The grid overlay, so it is covered by the same pass that covers everything
	# else. Green standing, orange falling, blue settled, grey emptied.
	_show_grids = true
	_draw_grids()
	await _frames(2)
	await _save("city_grids")
	print("[city] grid overlay: %d live chunk(s) drawn" % _grid_count)
	_show_grids = false
	if _grid_view != null:
		_grid_view.visible = false
	await _frames(1)

	var mem: Dictionary = world.get_memory_report()
	var rep: Dictionary = registry.report()
	var isl: Dictionary = islands.report()
	print("[city] final: %d buildings, %d materialised, %d damaged, %.1f MB" % [
		rep.buildings, rep.materialised, rep.damaged, float(mem.total_bytes) / 1048576.0])
	# What a grid actually costs, which is the question "how many grids is too
	# many" really asks. Occupancy is 4 bytes per cell of the chunk's bounding
	# box whether or not a brick is in it.
	print("[city] %d chunks: occupancy %.1f MB, blocks %.1f MB, bake %.1f MB" % [
		mem.chunks, float(mem.occupancy_bytes) / 1048576.0,
		float(mem.block_bytes) / 1048576.0,
		float(int(mem.total_bytes) - int(mem.occupancy_bytes) - int(mem.block_bytes)) / 1048576.0])
	print("[city] islands: %d live (%d settled, %d loose), %d bricks discarded unseen" % [
		isl.islands, isl.settled, isl.disposable, isl.discarded])
	print("[city]   small pieces: %d brick(s) deleted where they came loose beyond %.0f m, %d swept up at rest; %d of furniture; %.0f ms deciding"
			% [isl.tiny_deleted, IslandManager.SMALL_KEEP_RANGE, int(isl.get("swept_at_rest", 0)),
			isl.furniture_deleted, float(islands.spawn_prof.deleted)])
	print("[city]   %d merge(s) down to %d box(es); %d box(es) rebuilt per block when hit" % [
		isl.merged_shapes, isl.merged_boxes, isl.unmerged_boxes])
	print("[city] impacts: %d landing(s) sheared %d joint(s), %d split(s), %d snapped across" % [
		isl.impacts, isl.impact_blocks, isl.splits, isl.breaks])
	print("[city]   biggest single-tick speed loss %.1f m/s, %d landing(s) on a piece long enough to snap" % [
		isl.peak_drop, isl.long_landings])
	print("[city]   landings rejected: %d too gentle, %d too short; longest piece landed %.1f m" % [
		isl.soft_landings, isl.short_landings, isl.longest_landed])
	print("[city] promotions: %d in %.0f ms (%.1f ms each), %d of them for somebody walking up" % [
		_promotions, _promote_ms, _promote_ms / maxf(_promotions, 1), _near_promotions])
	print("[city] falling debris sheared %d brick(s) off what it landed on" % _impact_damage)
	var kinds := {}
	for e in authority.commands.entries:
		var k: String = DamageLog.Kind.keys()[e.kind]
		kinds[k] = int(kinds.get(k, 0)) + 1
	print("[city] authority: %d command(s) committed -- %s" % [
		authority.commands.size(), kinds])
	_check_log_replays()

	# --- measurement 2: is settled wreckage still breakable? -----------------
	# A collapsed section is a frozen body whose origin is its centre of mass,
	# so anything that located it by origin distance missed it entirely.
	# get_block_count includes blocks that are already dead -- a hit marks them,
	# it does not remove them from the chunk -- so the only count that answers
	# "did the blast do anything" is the alive one.
	var biggest: BrickIsland = null
	var biggest_n := 0
	for piece in islands.islands:
		if piece.is_valid() and world.get_alive_block_count(piece.chunk) > biggest_n:
			biggest_n = world.get_alive_block_count(piece.chunk)
			biggest = piece
	if biggest != null:
		# Aim at an actual brick. A toppled building is hollow, so the centre
		# of its bounding box is thin air and a blast there removes nothing --
		# which is a bad measurement, not a bug.
		var boxes: Array = world.get_block_boxes(biggest.chunk)
		var aim := islands.world_aabb(biggest).get_center()
		if not boxes.is_empty():
			@warning_ignore("integer_division")
			var mid := boxes.size() / 2
			var pick: Dictionary = boxes[mid]
			aim = biggest.chunk_transform() * (pick.pos as Vector3)
		var hits := islands.damage_near(aim, 1.4)
		var after := world.get_alive_block_count(biggest.chunk)
		print("[city] settled wreckage: biggest piece %d bricks, blast hit %d piece(s), %d bricks left" % [
			biggest_n, hits, after])
		print("[city] %s" % ("ok    settled wreckage is still breakable" if after < biggest_n
				else "FAIL  settled wreckage shrugged the blast off"))
	if _frame_samples > 0:
		print("[city] frame time: mean %.1f ms, worst %.1f ms, %d of %d over 33.3 ms" % [
			_frame_sum / _frame_samples, _frame_worst, _frames_over_30, _frame_samples])
	_report_profile()
	get_tree().quit()


## The host's own log, replayed into a fresh twin of every building it touched,
## has to give the same structure -- the buildings AND the pieces that came off
## them. AIPlan P0 step 4's gate, run where the commands are really made: by a
## collapse with real physics, budgets and landings, not by a probe's script.
##
## Compared on STRUCTURAL blocks at their local cells. Furniture is each machine's
## own (IslandManager.record_detach), and a piece that has slept has had its
## block ids renumbered, so neither ids nor content hashes are the thing to
## compare.
## Where F5 writes the checkpoint and F9 reads it. Docs/AIPlan.md P0 step 5.
const CHECKPOINT_PATH := "user://checkpoint.area"
## Set on the tree's root, which outlives reload_current_scene: the path the
## scene about to load has to restore.
const CHECKPOINT_META := &"city_checkpoint"
## The --checkpoint gate's expectations, carried across the reload the same way.
const CHECKPOINT_GATE_META := &"city_checkpoint_gate"


## Save the area exactly as it is -- the log, every piece where it is and how it
## is moving, what is asleep, what is queued -- to CHECKPOINT_PATH.
func save_checkpoint() -> bool:
	var scene := {"damage": _damage_queue.duplicate(true), "dirty": Array(_dirty),
			"camera": camera.global_transform}
	var bytes := AreaSnapshot.capture(authority.commands, islands, scene).to_bytes()
	var f := FileAccess.open(CHECKPOINT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[city] checkpoint: cannot write %s" % CHECKPOINT_PATH)
		return false
	f.store_buffer(bytes)
	f.close()
	print("[city] checkpoint saved: %d command(s), %d piece(s), %d asleep, %d KB" % [
		authority.commands.size(), islands.islands.size(), islands.dormant.size(),
		bytes.size() / 1024])
	return true


## Throw the area away and build it again from CHECKPOINT_PATH. The scene is
## reloaded rather than unpicked: every building back to its recipe, every body
## and node gone, and _ready restores the checkpoint on top.
func load_checkpoint() -> void:
	if not FileAccess.file_exists(CHECKPOINT_PATH):
		print("[city] no checkpoint to load (F5 saves one)")
		return
	get_tree().root.set_meta(CHECKPOINT_META, CHECKPOINT_PATH)
	get_tree().reload_current_scene()


func _restore_checkpoint(path: String) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var snap := AreaSnapshot.from_bytes(FileAccess.get_file_as_bytes(path))
	if snap == null:
		push_error("[city] checkpoint: %s does not read back" % path)
		return {}
	# A building that comes down whole in the log is its bricks and nothing else:
	# no body, no mesh, no bake -- the piece it becomes is given those.
	var toppling := {}
	for e in DamageLog.from_data(snap.commands).entries:
		if e.kind == DamageLog.Kind.TOPPLE:
			toppling[e.target] = true
	var shown: Array[int] = []
	var resolve := func(id: int, frame: int) -> int:
		var b := registry.get_building(id)
		if b == null or b.toppled:
			return -1
		if not b.is_materialised():
			var chunk := registry.materialise(id)
			if chunk < 0:
				return -1
			world.set_tension_per_stud(chunk, 9.3)
			if not toppling.has(id):
				shown.append(id)
		var cs := b.chunks()
		return cs[frame] if frame < cs.size() else -1
	var on_toppled := func(id: int) -> void:
		var b := registry.get_building(id)
		_free_shell(id)
		_drop_drawn(id)
		if b != null and not b.is_build():
			if spill_interiors:
				registry.mark_rooms_spilled(id)
				_wrecks[id] = b.chunk
			else:
				registry.write_off_rooms(id)
		registry.hand_over(id)
	var report := snap.restore(world, resolve, islands, on_toppled)
	# New commands follow the loaded ones.
	authority.commands = DamageLog.from_data(snap.commands)
	# Dressed AFTER the replay, so the bake and the collision start from the
	# damaged building rather than being patched from an intact one.
	for id in shown:
		var b := registry.get_building(id)
		if b == null or b.toppled or not b.is_materialised():
			continue
		b.hit = true
		_dress(id, b.chunk, true)
	var scene: Dictionary = report.get("scene", {})
	for h in scene.get("damage", []):
		_damage_queue.append(h)
	for id in scene.get("dirty", []):
		_mark_dirty(int(id))
	if scene.has("camera"):
		camera.global_transform = scene.camera
	print("[city] checkpoint loaded in %d ms: %s" % [Time.get_ticks_msec() - t0, report])
	return report


## The gate for F5/F9. Knock the city about, save partway through the collapse
## -- pieces still falling, some at rest -- reload the scene from the save, and
## check it is the same area: every damaged building brick for brick, every
## piece brick for brick, where it was, moving or not as it was. Then let the
## loaded city carry on and check the log still replays into it.
func _run_checkpoint_pass() -> void:
	var root := get_tree().root
	if root.has_meta(CHECKPOINT_GATE_META):
		var want: Dictionary = root.get_meta(CHECKPOINT_GATE_META)
		root.remove_meta(CHECKPOINT_GATE_META)
		await _check_checkpoint(want)
		return
	camera.position = Vector3(-52.0, 34.0, -52.0)
	camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(4)
	var probe = registry.buildings[0]
	_blast(probe.xform.origin + Vector3(probe.recipe.footprint_x * 0.5 * STUD, 0.8, 0.3), 1.4)
	for b in registry.buildings:
		if b.recipe.courses < 44:
			continue
		var w: float = b.recipe.footprint_x * STUD
		var d: float = b.recipe.footprint_z * STUD
		for course in range(0, 8):
			var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * PLATE
			var px := 0.3
			while px < w * 0.55:
				var pz := 0.3
				while pz < d:
					_blast(b.xform.origin + Vector3(px, y, pz), 1.5)
					pz += 2.0
				px += 2.0
	var guard := 0
	while not _damage_queue.is_empty() and guard < 600:
		await _frames(1)
		guard += 1
	await _frames(45)

	var want := {"buildings": {}, "pieces": {}, "dormant": 0, "moving": 0, "settled": 0}
	var touched := {}
	for e in authority.commands.entries:
		if not e.is_piece():
			touched[e.target] = true
	for id in touched:
		var b := registry.get_building(int(id))
		if b != null and not b.toppled and b.is_materialised():
			want.buildings[int(id)] = _structure_of(b.chunk)
	for isl in islands.islands:
		if not isl.is_valid() or isl.piece_id < 0:
			continue
		want.pieces[isl.piece_id] = {"structure": _structure_of(isl.chunk),
				"xform": isl.chunk_transform(), "at_rest": isl.settled,
				"linear": isl.body.linear_velocity}
		if isl.settled:
			want.settled += 1
		else:
			want.moving += 1
	for dm in islands.dormant:
		if dm.piece_id >= 0:
			want.dormant += 1
	want["commands"] = authority.commands.size()
	print("[city] checkpoint: saving %d command(s), %d damaged building(s), %d piece(s) (%d moving, %d at rest), %d asleep" % [
		want.commands, want.buildings.size(), want.pieces.size(), want.moving, want.settled, want.dormant])
	if not save_checkpoint():
		get_tree().quit(1)
		return
	root.set_meta(CHECKPOINT_GATE_META, want)
	load_checkpoint()


func _check_checkpoint(want: Dictionary) -> void:
	print("[city] checkpoint gate: the loaded area against the saved one")
	_gate_ok("every command came back", authority.commands.size() == int(want.commands),
			"%d of %d" % [authority.commands.size(), int(want.commands)])
	var same_b := 0
	for id in want.buildings:
		var b := registry.get_building(int(id))
		if b != null and not b.toppled and b.is_materialised() \
				and _structure_of(b.chunk) == want.buildings[id]:
			same_b += 1
	_gate_ok("every damaged building, brick for brick",
			same_b == want.buildings.size() and same_b > 0,
			"%d of %d" % [same_b, want.buildings.size()])
	var got := {}
	for isl in islands.islands:
		if isl.is_valid() and isl.piece_id >= 0:
			got[isl.piece_id] = isl
	var same := 0
	var placed := 0
	var moving := 0
	var drawn := 0
	for id in want.pieces:
		var p: Dictionary = want.pieces[id]
		var isl: BrickIsland = got.get(id)
		if isl == null:
			continue
		if _structure_of(isl.chunk) == p.structure:
			same += 1
		if isl.chunk_transform().is_equal_approx(p.xform) and isl.settled == bool(p.at_rest):
			placed += 1
		else:
			print("  piece %d: at rest %s -> %s, %.3f m out" % [int(id), p.at_rest,
					isl.settled, isl.chunk_transform().origin.distance_to(p.xform.origin)])
		if not isl.settled and not bool(p.at_rest) \
				and isl.body.linear_velocity.is_equal_approx(p.linear):
			moving += 1
		# Something to draw into, or an array of bricks nobody can see.
		if isl.mesh != null or isl.mm_key != Vector3.ZERO:
			drawn += 1
	var n: int = want.pieces.size()
	_gate_ok("every piece, brick for brick", same == n and n > 0, "%d of %d" % [same, n])
	_gate_ok("where it was, at rest or not as it was", placed == n, "%d of %d" % [placed, n])
	_gate_ok("a moving piece still moving", moving == int(want.moving) and moving > 0,
			"%d of %d" % [moving, int(want.moving)])
	_gate_ok("every piece has a node to draw into", drawn == n, "%d of %d" % [drawn, n])
	_gate_ok("everything asleep is still asleep",
			islands.dormant.size() == int(want.dormant),
			"%d of %d" % [islands.dormant.size(), int(want.dormant)])
	await _frames(20)
	await _save("city_checkpoint_loaded")
	# And it carries on: the collapse finishes, and the log -- the loaded part
	# and what was added after -- still replays into what is standing.
	await _frames(240)
	_gate_ok("the loaded city carries on", authority.commands.size() >= int(want.commands),
			"%d command(s) now" % authority.commands.size())
	_check_log_replays()
	print("[city] checkpoint gate: %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


func _check_log_replays() -> void:
	var t0 := Time.get_ticks_msec()
	var entries := authority.commands.entries
	var touched := {}
	for e in entries:
		if not e.is_piece():
			touched[e.target] = true

	# The twins: same recipes, same places, same staircases, fresh bricks.
	var twin := BuildingRegistry.new(world, palette)
	var twin_of := {}
	var skipped := 0
	for id in touched:
		var b := registry.get_building(int(id))
		if b == null or b.is_build():
			skipped += 1
			continue
		var tid := twin.register(b.recipe.footprint_x, b.recipe.footprint_z,
				b.recipe.courses, b.xform)
		for f in b.fixtures:
			twin.add_fixture(tid, f.kind, f.params, f.cell, f.role)
		twin_of[int(id)] = tid
	var toppled := {}
	var rep := StructureReplayer.new(world, func(id: int, frame: int) -> int:
		if frame != 0 or not twin_of.has(id) or toppled.has(id):
			return -1
		return twin.materialise(int(twin_of[id])))
	rep.on_toppled = func(id: int) -> void:
		toppled[id] = true
		twin.hand_over(int(twin_of[id]))
	rep.apply_all(entries)

	var b_ok := 0
	var b_n := 0
	for id in twin_of:
		var b := registry.get_building(int(id))
		if b.toppled or not b.is_materialised():
			continue
		b_n += 1
		var tb := twin.get_building(int(twin_of[id]))
		var hs := _structure_of(b.chunk)
		var ts := _structure_of(tb.chunk)
		if hs == ts:
			b_ok += 1
		elif b_n - b_ok == 1:
			_explain_difference("building %d" % int(id), hs, ts)
	var p_ok := 0
	var p_n := 0
	var p_missing := 0
	var rest_ok := 0
	var rest_n := 0
	for isl in islands.islands:
		if not isl.is_valid() or isl.piece_id < 0 or not twin_of.has(isl.owner):
			continue
		p_n += 1
		var rc := rep.piece_chunk(isl.piece_id)
		if rc < 0:
			p_missing += 1
			continue
		# A landmark at rest has to lie where the host's lies (PIECE_REST).
		if isl.settled and isl.landmark:
			rest_n += 1
			if world.get_chunk_transform(rc).is_equal_approx(isl.chunk_transform()):
				rest_ok += 1
		var hp := _structure_of(isl.chunk)
		var rp := _structure_of(rc)
		if hp == rp:
			p_ok += 1
		elif p_n - p_ok - p_missing <= 2:
			_explain_difference("piece %d (owner %d, woke %d time(s))" % [isl.piece_id, isl.owner, isl.wakes], hp, rp)
			_trace_piece(rep, entries, isl, hp, rp)

	print("[city] log replay: %d command(s) into %d twin building(s) (%d skipped), %d missed, %.0f ms" % [
		entries.size(), twin_of.size(), skipped, rep.missed, Time.get_ticks_msec() - t0])
	print("[city]   buildings: %d of %d identical; pieces: %d of %d identical, %d missing; %d of %d at rest where the host's are" % [
		b_ok, b_n, p_ok, p_n, p_missing, rest_ok, rest_n])
	for m in rep.miss_log:
		print("[city]   missed: %s target %d seq %d -- %s" % m)
	print("[city] %s" % ("ok    the log replays into the same structure"
			if b_ok == b_n and p_ok == p_n and rep.missed == 0 and rest_ok == rest_n
			else "FAIL  the log does not replay into the same structure"))

	# Give the twins' bricks back: nothing after this should find them.
	for id in rep.pieces:
		var c := rep.piece_chunk(int(id))
		if c >= 0:
			world.release_chunk(c)
	for id in twin_of:
		twin.dematerialise(int(twin_of[id]))


## Where did a piece's missing bricks go in the replay, and what does the log say
## about the piece? Only run when a piece disagrees.
func _trace_piece(rep: StructureReplayer, entries: Array, isl: BrickIsland,
		host: PackedStringArray, replay: PackedStringArray) -> void:
	var in_replay := {}
	for s in replay:
		in_replay[s] = true
	var lost := {}
	for s in host:
		if not in_replay.has(s):
			lost[s] = true
	# Which replay piece holds them now? Cells are absolute -- the building's grid,
	# which every piece cut from it keeps -- so this is where they went.
	var holders := {}
	for id in rep.pieces:
		var c := rep.piece_chunk(int(id))
		if c < 0 or int(id) == isl.piece_id:
			continue
		for s in _structure_of(c):
			if lost.has(s):
				holders[int(id)] = int(holders.get(int(id), 0)) + 1
	print("[city]     lost bricks are now in replay piece(s) %s" % holders)
	# The piece's own history in the log, and its parent's.
	var parent := -1
	var mine: Array = []
	for e in entries:
		var ee: DamageLog.Entry = e
		if DamageLog.piece_id(ee.seq) == isl.piece_id and ee.kind == DamageLog.Kind.DETACH:
			parent = ee.target if ee.flags & DamageLog.FLAG_FROM_PIECE else -1
			mine.append("born seq %d from %s %d, %d cells %d ids" % [ee.seq,
					"piece" if parent >= 0 else "building", ee.target, ee.points.size(), ee.blocks.size()])
		elif ee.target == isl.piece_id and ee.is_piece():
			mine.append("%s seq %d" % [DamageLog.Kind.keys()[ee.kind], ee.seq])
	print("[city]     its log: %s" % [mine.slice(0, 12)])
	if parent >= 0:
		var hist: Array = []
		for e in entries:
			var ee: DamageLog.Entry = e
			if ee.is_piece() and ee.target == parent:
				hist.append("%s seq %d%s" % [DamageLog.Kind.keys()[ee.kind], ee.seq,
						" -> piece %d" % DamageLog.piece_id(ee.seq) if ee.kind == DamageLog.Kind.DETACH else ""])
		print("[city]     parent %d's log: %s" % [parent, hist.slice(0, 20)])


func _explain_difference(what: String, host: PackedStringArray, replay: PackedStringArray) -> void:
	var in_replay := {}
	for s in replay:
		in_replay[s] = true
	var in_host := {}
	for s in host:
		in_host[s] = true
	var only_host := PackedStringArray()
	var only_replay := PackedStringArray()
	for s in host:
		if not in_replay.has(s):
			only_host.append(s)
	for s in replay:
		if not in_host.has(s):
			only_replay.append(s)
	print("[city]   %s differs: host %d, replay %d; %d only on the host %s, %d only in the replay %s" % [
		what, host.size(), replay.size(), only_host.size(), only_host.slice(0, 3),
		only_replay.size(), only_replay.slice(0, 3)])


## A chunk's structure as something comparable: every living, structural block
## as its ABSOLUTE cell (the building's grid, kept by every piece cut from it and
## now through sleep) and its archetype by name, sorted.
func _structure_of(chunk: int) -> PackedStringArray:
	var out := PackedStringArray()
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return out
	var origin := world.get_chunk_origin(chunk)
	for id in world.get_block_count(chunk):
		if world.is_block_decorative(chunk, id):
			continue
		var cell := StructureReplayer.block_cell(world, chunk, id)
		# Dead and detached blocks are not solid: they were destroyed, or they left
		# with a piece. Only what is standing here counts.
		if cell == StructureReplayer.NO_CELL or not world.is_solid(chunk, origin + cell):
			continue
		# By NAME: fixture parts are baked on first demand, so the same stair step
		# can hold a different archetype number in another registry -- or on
		# another machine -- and still be the same brick.
		out.append("%s:%s" % [origin + cell, world.get_archetype_name(world.get_block_archetype(chunk, id))])
	out.sort()
	return out


## Where the time actually went. `script_total` is everything this script did in
## a physics tick; whatever the frame cost beyond that is the engine -- physics
## solve, rendering, and the buffer uploads the script asked for.
func _report_profile() -> void:
	if _prof_worst.is_empty():
		return
	var keys := ["stress", "stability", "detach", "disable", "spawn", "remesh",
			"bands", "retire", "damage", "promote", "promote_finish", "stream",
			"islands", "hud"]
	if _frame_samples > 0:
		print("[prof] mean frame: %.1f ms physics (solver + this script), %.1f ms idle process" % [
				_phys_sum / _frame_samples, _proc_sum / _frame_samples])
	print("[prof] worst script tick %.1f ms  (%d islands)" % [
			_prof_worst_ms, int(_prof_worst.get("island_count", 0))])
	var line := ""
	for k in keys:
		line += "%s %.1f  " % [k, float(_prof_worst.get(k, 0.0))]
	print("[prof]   " + line)
	print("[prof]   of which damage: promote %.1f  rooms %.1f  hit %.1f  loose pieces %.1f  collision update %.1f"
			% [float(_prof_worst.get("dmg_promote", 0.0)), float(_prof_worst.get("dmg_rooms", 0.0)),
			float(_prof_worst.get("dmg_hit", 0.0)), float(_prof_worst.get("dmg_pieces", 0.0)),
			float(_prof_worst.get("dmg_disable", 0.0))])
	print("[prof] %d building meshes rebuilt from scratch (the rest were index patches)"
			% _full_rebuilds)
	var tw: Dictionary = islands.tick_worst
	if not tw.is_empty():
		print("[prof] worst islands.tick %.1f ms = loop %.1f + resolve %.1f + fracture %.1f + mesh %.1f  (%d islands)" % [
				float(tw.total), float(tw.loop), float(tw.resolve), float(tw.fracture),
				float(tw.mesh), int(tw.islands)])
	var sp: Dictionary = islands.spawn_prof
	var _bi: Dictionary = islands.report()
	print("[prof] overlaps alive at once, worst: %d" % _bi.overlap_peak)
	print("[prof] invisible pieces: %d went blind, worst %d tick(s), mean %.2f, biggest %d bricks" % [
			_bi.blind_count, _bi.blind_worst, _bi.blind_mean, _bi.meshless_worst_blocks])
	print("[prof] spawn total %.0f ms = split %.0f (C++ chunk+blocks) + shapes %.0f + node %.0f + mesh %.0f" % [
			sp.total, sp.split, sp.shapes, sp.node, sp.mesh])
	if _frame_samples > 0:
		line = ""
		for k in keys:
			line += "%s %.2f  " % [k, float(_prof_sum.get(k, 0.0)) / _frame_samples]
		print("[prof] mean per tick: " + line)


## Sustained destruction across a whole city, with rendering on.
##
## The shot pass cuts twelve buildings open in one burst and then watches them
## fall; this keeps firing for the whole run, so promotion, island spawning,
## island LOD and the damage queue are all under load at the same time rather
## than one after another. Run it with:
##
##     godot --path . -- --stress --buildings=200
func _run_stress_pass() -> void:
	print("[stress] %d buildings, %.1f m spacing" % [_city_size, 13.0])
	camera.position = Vector3(0.0, 46.0, 96.0)
	camera.rotation = Vector3(-0.42, 0.0, 0.0)
	await _frames(10)

	var mem: Dictionary = world.get_memory_report()
	print("[stress] standing: %.1f MB, %d chunks, %d islands" % [
			float(mem.total_bytes) / 1048576.0, int(mem.chunks), islands.islands.size()])

	_sampling = true
	_phase = "under fire"
	var target := 0
	var shots := 0
	var toppled_on_purpose := 0
	# One building per frame, working along the city. Unlike the old version
	# this fires a SMALL pattern, because the damage queue drains at
	# DAMAGE_PER_TICK (8) a tick: a pattern that queues more than eight hits per
	# frame builds a backlog that never clears, and the pass then measures a
	# permanent queue rather than a city. See "What the stress pass could not
	# say" in Docs/Status.md.
	while target < registry.buildings.size():
		var b = registry.buildings[target]
		var collapse: bool = _stress_collapse < 0 or target < _stress_collapse
		if collapse:
			shots += _stress_topple(b)
			toppled_on_purpose += 1
		else:
			shots += _stress_wound(b)
		target += 1
		await _frames(1)

	# Let the queue actually empty. If it does not, the run is not measuring
	# what it says it is, and the report below says so rather than quietly
	# reporting a number taken under a backlog.
	_phase = "damage queue draining"
	var wait := 0
	while not _damage_queue.is_empty() and wait < 1800:
		await _frames(1)
		wait += 1
	var queue_left := _damage_queue.size()

	# Everything is falling, nothing new is arriving.
	_phase = "collapsing"
	await _frames(180)

	# And then: does it come back?
	_phase = "settled"
	await _frames(240)
	var peak_mb := float(world.get_memory_report().total_bytes) / 1048576.0
	var peak_res: int = registry.report().materialised
	# How much of the peak belongs to buildings nobody can see the bricks of?
	# A materialised building is skipped by _stream_shells, so it is drawn as
	# full brick geometry however far away it is -- and the bake is most of what
	# a resident building costs.
	var near_res := 0
	var far_res := 0
	var far_blocks := 0
	var near_blocks := 0
	for b in registry.buildings:
		if not b.is_materialised():
			continue
		if b.xform.origin.distance_to(camera.global_position) > SHELL_DETAIL_RANGE:
			far_res += 1
			far_blocks += world.get_block_count(b.chunk)
		else:
			near_res += 1
			near_blocks += world.get_block_count(b.chunk)
	print("[stress] at peak: %d resident within %.0f m (%d blocks), %d beyond it (%d blocks, %.0f%%)" % [
			near_res, SHELL_DETAIL_RANGE, near_blocks, far_res, far_blocks,
			float(far_blocks) / maxf(near_blocks + far_blocks, 1) * 100.0])

	# Well past TRIM_AFTER_MS (12 s) AND past several runs of _trim_quiet, which
	# only fires every 120 physics frames. A tail shorter than both answers
	# "does a damaged city hand its bricks back?" with the trim barely started.
	_phase = "trimmed"
	await _frames(1800)
	_sampling = false
	_phase = ""

	mem = world.get_memory_report()
	var rep: Dictionary = registry.report()
	var isl: Dictionary = islands.report()
	var toppled := 0
	for b in registry.buildings:
		if b.toppled:
			toppled += 1
	print("[stress] %d shot(s) at %d building(s); %d meant to come down" % [
			shots, target, toppled_on_purpose])
	print("[stress] %d of %d buildings took a hit, %d actually toppled" % [
			rep.damaged, registry.buildings.size(), toppled])
	if queue_left > 0:
		print("[stress] WARNING: %d hit(s) never left the queue -- the numbers below were taken"
				% queue_left)
		print("[stress]          under a permanent backlog and understate how many buildings")
		print("[stress]          were involved. Fire a smaller pattern or raise DAMAGE_PER_TICK.")
	elif rep.damaged < registry.buildings.size():
		print("[stress] note: %d building(s) took no damage -- the queue drained, so the hits"
				% (registry.buildings.size() - rep.damaged))
		print("[stress]       missed rather than being dropped.")
	print("[stress] %d materialised, %.1f MB across %d chunks" % [
			rep.materialised, float(mem.total_bytes) / 1048576.0, int(mem.chunks)])
	print("[stress]   occupancy %.1f MB, blocks %.1f MB, bake %.1f MB" % [
			float(mem.occupancy_bytes) / 1048576.0, float(mem.block_bytes) / 1048576.0,
			float(int(mem.total_bytes) - int(mem.occupancy_bytes) - int(mem.block_bytes)) / 1048576.0])
	print("[stress] collision: %s" % _collision_report())
	print("[stress] islands %d (%d settled, %d small), %d mesh(es) given back, %d split(s)" % [
			isl.islands, isl.settled, isl.disposable, isl.dropped, isl.splits])
	print("[stress] small pieces deleted where they came loose: %d brick(s) beyond %.0f m, %d unseen, %d of furniture"
			% [int(islands.report().tiny_deleted), IslandManager.SMALL_KEEP_RANGE,
			int(islands.report().discarded), int(islands.report().furniture_deleted)])
	print("[stress] bands built %d: C++ %.0f ms, upload %.0f ms, worst one %.1f ms" % [
			_band_builds, _band_cpp_ms, _band_upload_ms, _band_worst])
	print("[stress] debris cap: small <=%d, large <=%d, total <=%d -- deleted %d, slept %d, peak %d over" % [
			islands.small_live_max, islands.large_live_max, islands.total_live_max,
			islands.cap_deleted, islands.cap_slept, maxi(islands.cap_worst_over, 0)])
	print("[stress] asleep %d piece(s) holding %d block(s) in %.1f KB (%d slept, %d woken)" % [
			isl.dormant, isl.dormant_blocks, float(isl.dormant_bytes) / 1024.0,
			isl.slept, isl.woken])
	print("[stress] invisible pieces: %d went blind, worst %d tick(s), mean %.1f, biggest %d bricks" % [
			isl.blind_count, isl.blind_worst, isl.blind_mean, isl.meshless_worst_blocks])
	print("[stress] breaks %d (%d had to tear a band), %d impact(s) loosening %d block(s)" % [
			isl.breaks, isl.band_breaks, isl.impacts, isl.impact_blocks])
	print("[stress] de-meshed %d, re-meshed %d, in %.0f ms" % [
			_demeshed, _remeshed_back, _demesh_ms])
	print("[stress] trimmed %d building(s) in %.0f ms (%.1f ms each) = demat %.0f + free %.0f + shell %.0f" % [
			_trims, _trim_ms, _trim_ms / maxf(_trims, 1),
			_trim_split.demat, _trim_split.free, _trim_split.shell])
	print("[stress] peak %.1f MB with %d resident; after trimming %.1f MB with %d" % [
			peak_mb, peak_res, float(mem.total_bytes) / 1048576.0, rep.materialised])
	print("[stress] rooms opened %d in %.0f ms (lay %.0f + collision %.0f); compromised %d (%d built) in %.0f ms; worst %.1f ms" % [
			_room_opens, _room_lay_ms + _room_shape_ms, _room_lay_ms, _room_shape_ms,
			_room_compromises, _room_built, _room_compromise_ms, _room_open_worst])
	print("[stress] promotions: %d in %.0f ms (%.1f ms each), %d of them for somebody walking up" % [
			_promotions, _promote_ms, _promote_ms / maxf(_promotions, 1), _near_promotions])
	if _frame_samples > 0:
		print("[stress] whole run: mean %.1f ms, worst %.1f ms, %d of %d over 33.3 ms (%.1f%%)" % [
			_frame_sum / _frame_samples, _frame_worst, _frames_over_30, _frame_samples,
			float(_frames_over_30) / _frame_samples * 100.0])
	_report_phases()
	_report_profile()
	get_tree().quit()


## A bite out of the bottom of one side. The centre of mass leaves its support
## and the building comes down. A symmetric ring just lowers it onto what is
## left and nothing falls.
func _stress_topple(b) -> int:
	var w: float = b.recipe.footprint_x * STUD
	var d: float = b.recipe.footprint_z * STUD
	var fired := 0
	for course in range(0, 8):
		var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * PLATE
		var px := 0.3
		while px < w * 0.55:
			var pz := 0.3
			while pz < d:
				_blast(b.xform.origin + Vector3(px, y, pz), 1.5)
				fired += 1
				pz += 2.0
			px += 2.0
	return fired


## Damage without demolition: a shallow bite out of one wall, high enough up
## that removing the mass makes the building MORE stable rather than less.
##
## Eight hits, because the damage queue drains eight a tick and this pass fires
## at one building a frame -- so the queue stays level instead of growing. That
## is the whole difference between measuring a city and measuring a backlog.
func _stress_wound(b) -> int:
	var w: float = b.recipe.footprint_x * STUD
	var d: float = b.recipe.footprint_z * STUD
	var courses: int = b.recipe.courses
	var fired := 0
	# Two courses, two thirds of the way up.
	for i in 2:
		var course: int = maxi(1, int(courses * 0.66) + i)
		var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * PLATE
		# Four points across one face, and only a quarter of the way in, so the
		# opposite wall and the core are untouched.
		for j in 4:
			var pz: float = d * (0.15 + 0.7 * float(j) / 3.0)
			_blast(b.xform.origin + Vector3(w * 0.12, y, pz), 1.3)
			fired += 1
	return fired


## The de-mesh tier, there and back.
##
## Dropping a building's mesh is only half a feature. The half that breaks
## silently is the return: walk away, walk back, and the building has to be
## bricks again -- with its damage still in them. A building stuck as a shell
## forever looks exactly like a building that was never damaged.
func _run_lod_pass() -> void:
	print("[lod] de-mesh and back")
	var target := registry.get_building(0)
	var aim: Vector3 = target.xform.origin + Vector3(
			target.recipe.footprint_x * STUD * 0.5,
			target.recipe.courses * TowerRecipe.PLATES_PER_COURSE * PLATE * 0.5,
			target.recipe.footprint_z * STUD * 0.5)

	# An Array, not an int: a GDScript lambda captures locals BY VALUE, so
	# `failures += 1` inside one updates a copy and the probe reports PASS over
	# its own FAIL lines. The array is captured by reference.
	var failures := [0]
	var check := func(label: String, cond: bool, detail: String) -> void:
		if cond:
			print("  ok    %s  %s" % [label, detail])
		else:
			failures[0] += 1
			print("  FAIL  %s  %s" % [label, detail])

	# Stand close and shoot it.
	camera.global_position = aim + Vector3(0.0, 0.0, -40.0)
	camera.look_at(aim, Vector3.UP)
	await _frames(20)
	_fire(1.6)
	var guard := 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)

	var b := registry.get_building(0)
	check.call("it took damage", b.is_damaged(), "")
	check.call("and is drawn as bricks", _brick_nodes.has(0), "")
	var dead_near: int = world.get_dead_blocks(b.chunk).size()
	check.call("bricks are missing", dead_near > 0, "%d dead" % dead_near)

	# Walk away, past DEMESH_RANGE + hysteresis, and POLL for the de-mesh rather
	# than sleeping a fixed time. _trim_quiet is a deeper tier on the same
	# buildings -- TRIM_RADIUS (90 m) is inside DEMESH_RANGE (110 m) -- so a
	# fixed wait long enough to be safe is also long enough for the trim to fire
	# and take the chunk away, which reads as the de-mesh tier failing when it
	# is the trim working.
	camera.global_position = aim + Vector3(0.0, 0.0, -200.0)
	camera.look_at(aim, Vector3.UP)
	var waited := 0
	while _brick_nodes.has(0) and waited < 600:
		await _frames(1)
		waited += 1

	b = registry.get_building(0)
	check.call("mesh dropped", not _brick_nodes.has(0), "after %d frame(s)" % waited)
	check.call("still resident", b.is_materialised(), "")
	check.call("drawn as a shell instead", _shells.has(0), "")
	check.call("damage still recorded", _dead_count(0) == dead_near,
			"%d dead" % _dead_count(0))

	# A shot from out here still has to land, on real bricks. Aimed WELL AWAY
	# from the first hole: firing at the same point again destroys nothing
	# because everything in range of it is already destroyed, which is the game
	# being right and the test being wrong.
	#
	# And aimed at a FLOOR SLAB rather than at a fraction of the height. The
	# walls have windows in them now, and a ray through a window is a ray out
	# of the far side of the building: the shot landed on nothing and the check
	# read it as damage not carrying to 200 m. A slab spans the whole footprint
	# and is the one band of a tower that is solid all the way across.
	var aim_high: Vector3 = _intact_aim(0)
	var before: int = _dead_count(0)
	camera.look_at(aim_high, Vector3.UP)
	# From whichever bearing has a clear line. The first shot knocked a piece
	# off the near wall, and a piece knocked off a building 200 m away is a
	# rigid body standing between the camera and the target: the shot lands on
	# the DEBRIS and the building takes nothing, which is the game being right
	# and the test aiming badly. Walk round until the ray reaches the building
	# itself.
	var bearings := [Vector3(0.0, 0.0, -1.0), Vector3(-1.0, 0.0, 0.0),
			Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0)]
	var clear_line := false
	for bearing in bearings:
		camera.global_position = aim_high + (bearing as Vector3) * 200.0
		camera.look_at(aim_high, Vector3.UP)
		await _frames(10)
		var look := PhysicsRayQueryParameters3D.create(camera.global_position,
				camera.global_position - camera.global_transform.basis.z * FIRE_RANGE)
		look.collision_mask = Layers.HITSCAN_MASK
		var seen := get_world_3d().direct_space_state.intersect_ray(look)
		# BUILDING 0, not merely something solid. "Not an island" was too weak:
		# another building's shell in front of this one is not an island
		# either, and the shot landed on that and destroyed nothing here.
		# Either of building 0's own bodies counts -- de-meshed, it is drawn
		# by a shell and collided by its bricks, and both are in the space.
		var struck_rid: RID = seen.get("rid", RID())
		if not seen.is_empty() and (struck_rid == _brick_bodies.get(0, RID())
				or struck_rid == _shell_bodies.get(0, RID())):
			clear_line = true
			break
	check.call("there is a clear line to it from 200 m", clear_line, "")
	_fire(1.6)
	guard = 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)
	var after: int = _dead_count(0)
	check.call("a shot from 200 m still destroys brick", after > before,
			"%d -> %d dead" % [before, after])

	# Walk back, and poll for the bricks to return.
	camera.global_position = aim + Vector3(0.0, 0.0, -40.0)
	camera.look_at(aim, Vector3.UP)
	waited = 0
	while not _brick_nodes.has(0) and waited < 600:
		await _frames(1)
		waited += 1
	await _frames(20)

	b = registry.get_building(0)
	check.call("bricks came back", _brick_nodes.has(0), "after %d frame(s)" % waited)
	check.call("and the shell went away", not _shells.has(0), "")
	# The node itself holds no mesh: a building draws through its BANDS, and
	# the node is the transform they hang off. See _rebuild_bands.
	check.call("with geometry in it", _drawn_surfaces(0) > 0,
			"%d band(s) with a surface" % _drawn_surfaces(0))
	check.call("damage survived the round trip", _dead_count(0) >= after,
			"%d dead" % _dead_count(0))

	print("")
	print("[probe] PASS" if failures[0] == 0 else "[probe] FAIL — %d check(s)" % failures[0])
	get_tree().quit()


## How many bricks this building has lost, whether or not it is materialised.
## The registry record survives de-materialisation; the chunk does not.
func _dead_count(id: int) -> int:
	var b := registry.get_building(id)
	if b == null:
		return -1
	if b.is_materialised() and world.is_chunk_alive(b.chunk):
		return world.get_dead_blocks(b.chunk).size()
	return b.dead.size()


## Nearest building the ray passes through, by recipe rather than by geometry.
##
## Only buildings with no node are considered: anything nearer has a shell or
## real bricks, and the physics ray is both cheaper and more accurate for those.
## The test is the building's box, not its silhouette -- at the range this
## exists to cover, the difference is well under a pixel.
func _ray_recipes(from: Vector3, to: Vector3) -> Dictionary:
	var dir := (to - from)
	var span := dir.length()
	if span <= 0.0:
		return {}
	dir /= span

	var best := {}
	var best_d := span
	for b in registry.buildings:
		if b.toppled or b.is_materialised() or _shells.has(b.id):
			continue
		var size := Vector3(b.recipe.footprint_x * STUD,
				TowerRecipe.total_plates(b.recipe.courses) * PLATE,
				b.recipe.footprint_z * STUD)
		var inv := b.xform.affine_inverse()
		var local_from: Vector3 = inv * from
		var local_dir: Vector3 = inv.basis * dir
		var at = AABB(Vector3.ZERO, size).intersects_ray(local_from, local_dir)
		if at == null:
			continue
		var world_at: Vector3 = b.xform * (at as Vector3)
		var d := from.distance_to(world_at)
		if d < best_d:
			best_d = d
			best = {"position": world_at, "building": b.id}
	return best


## How far away can a building be shot?
##
## The answer has to be "as far as you can see it", because a player who lines
## up a distant tower and fires expects a hole. The chain is: the ray needs
## something to hit, so the building needs a shell body; the hit point then goes
## through _apply_blast, which materialises whatever it lands on regardless of
## distance. So the reach is exactly the shell tier's reach, and this measures
## it rather than assuming it.
func _run_reach_pass() -> void:
	print("[reach] how far can a building be shot?")
	var target := registry.get_building(0)
	var aim: Vector3 = target.xform.origin + Vector3(
			target.recipe.footprint_x * STUD * 0.5,
			target.recipe.courses * TowerRecipe.PLATES_PER_COURSE * PLATE * 0.5,
			target.recipe.footprint_z * STUD * 0.5)

	var furthest := 0.0
	var first_miss := 0.0
	var d := 40.0
	while d <= 480.0:
		# Rebuild the target so each distance is asked the same question.
		# Order matters: dematerialise() refreshes `dead` FROM the chunk, so
		# clearing the record first and de-materialising second puts the damage
		# straight back and every distance reports a hit.
		var b := registry.get_building(0)
		if b.is_materialised():
			registry.dematerialise(0)
			if _brick_bodies.has(0):
				PhysicsServer3D.free_rid(_brick_bodies[0])
				_brick_bodies.erase(0)
			if _brick_nodes.has(0):
				(_brick_nodes[0] as MeshInstance3D).queue_free()
				_brick_nodes.erase(0)
			_brick_meshes.erase(0)
			_brick_index_bytes.erase(0)
			_brick_index_width.erase(0)
			_brick_shapes.erase(0)
			_materialised.erase(0)
			_dirty.erase(0)
		b.hit = false
		b.dead = PackedInt32Array()
		b.damage_profile = {}
		_free_shell(0)

		# Stand off along -Z and look at it. The shell streamer needs a few
		# ticks to notice where the camera is before the ray has anything to
		# hit, which is itself part of the answer.
		camera.global_position = aim + Vector3(0.0, 0.0, -d)
		camera.look_at(aim, Vector3.UP)
		# _stream_shells runs every fourth tick at SHELLS_PER_TICK, so a camera
		# that has just jumped 40 m needs time for the shell tier to catch up.
		# Thirty frames was sometimes enough and sometimes not, which made this
		# probe report misses that were the test's fault rather than the game's.
		await _frames(120)

		var _sp := get_world_3d().direct_space_state
		var _f := camera.global_position
		var _t2 := _f - camera.global_transform.basis.z * FIRE_RANGE
		var _q := PhysicsRayQueryParameters3D.create(_f, _t2)
		_q.collision_mask = Layers.HITSCAN_MASK
		var _ph := _sp.intersect_ray(_q)
		var _rr := _ray_recipes(_f, _t2)
		print("[reach]        physics %s, recipe %s" % [
				("%.0f m" % _f.distance_to(_ph.position)) if not _ph.is_empty() else "none",
				("b%d @ %.0f m" % [int(_rr.building), _f.distance_to(_rr.position)]) if not _rr.is_empty() else "none"])
		_fire(1.6)
		var guard := 0
		while not _damage_queue.is_empty() and guard < 120:
			await _frames(1)
			guard += 1
		await _frames(2)

		var landed: bool = registry.get_building(0).is_damaged()
		var shelled: bool = _shells.has(0)
		print("[reach] %4.0f m: shell %s, damage %s" % [
				d, "yes" if shelled else "NO ", "LANDED" if landed else "missed"])
		if landed:
			furthest = d
		elif first_miss == 0.0:
			first_miss = d
		d += 40.0

	print("[reach] damage lands out to %.0f m; first miss at %.0f m (SHELL_RANGE is %.0f)" % [
			furthest, first_miss, SHELL_RANGE])
	get_tree().quit()


## Drop a saved workshop build into the city, frames and all.
##
## Docs/BuildMode.md section 8.1: the city PLACES finished recipes, it does not
## author them. A build comes in materialised and stays that way -- there is no
## shell for an arbitrary creation yet (section 12, question 3), so it is not
## streamed, not trimmed, and not given a cheap tier. Everything after that is
## the ordinary path: it takes hits, sheds islands and topples like any other
## building, because it IS one.
func _place_build(path: String) -> void:
	if not FileAccess.file_exists(path):
		push_warning("[city] no build at %s -- save one from the workshop with F5" % path)
		return
	var recipe := BuildRecipe.load_from(path)
	if recipe.is_empty():
		push_warning("[city] %s holds no bricks" % path)
		return
	# Clear of the block of towers, between them and where the camera starts.
	# On the grid, square to it: -120 x -97 studs, no turn.
	var at := Transform3D(Basis(), BrickWorld.grid_to_world(Vector3i(-120, 0, -97)))
	var id := registry.register_build(recipe, at)
	if id < 0:
		return
	# Registered and SHELLED, not materialised: a build is a recipe like any
	# other building now that there is something cheap to draw it with, so it
	# streams and trims on the same rules (Docs/BuildMode.md section 12,
	# question 3).
	_index_building(id)
	_make_shell(id)
	var b := registry.get_building(id)
	var tris := 0
	var mesh: Mesh = (_shells[id] as MeshInstance3D).mesh
	if mesh != null and mesh.get_surface_count() > 0:
		@warning_ignore("integer_division")
		tris = mesh.get_faces().size() / 3
	print("[city] placed '%s': %d bricks in the recipe, %d frame(s), %d fixture(s); shell %d triangles at %v" % [
			recipe.name, recipe.size(), recipe.frame_count(), b.fixtures.size(),
			tris, at.origin])


# ---------------------------------------------------------------------------
# The chamfer gate
# ---------------------------------------------------------------------------

## Does the shaded chamfer do anything, and does it stop doing it at range?
##
## A bevel on every edge of every block would be four quads a face -- five times
## the triangles for something 13 mm wide. It is shaded instead, so the only
## test that means anything is the rendered picture: one frame with it and one
## without, differenced. The second half matters as much as the first: a
## sub-pixel highlight that does not fade out shimmers, which is the same reason
## the seam fades (spec section 2, layer lines).
func _run_chamfer_pass() -> void:
	print("[chamfer] a bevel nobody paid a triangle for")
	var b := registry.get_building(0)
	var chunk := _promote(0)
	await _frames(40)
	_gate_ok("there are real bricks to look at", chunk >= 0
			and world.get_alive_block_count(chunk) > 0)

	# Close enough to read a single brick: about a metre and a half off a wall,
	# square on.
	var wall: Vector3 = b.xform * Vector3(b.recipe.footprint_x * STUD * 0.5, 2.2, 0.0)
	camera.global_position = wall - Vector3(0.0, 0.0, 1.6)
	camera.look_at(wall, Vector3.UP)
	await _frames(10)

	var near_off := await _capture_chamfer(false, "chamfer_off")
	var near_on := await _capture_chamfer(true, "chamfer_on")
	var near_diff := _image_difference(near_off, near_on)
	_gate_ok("up close, the bevel changes the picture", near_diff > 0.04,
			"%.1f%% of sampled pixels" % (near_diff * 100.0))
	_gate_ok("but does not repaint the whole wall -- it is edges, not a tint",
			near_diff < 0.75, "%.1f%%" % (near_diff * 100.0))

	# And from across the street it is gone, because at that size it is noise.
	camera.global_position = wall - Vector3(0.0, -6.0, 110.0)
	camera.look_at(wall, Vector3.UP)
	await _frames(10)
	var far_off := await _capture_chamfer(false, "")
	var far_on := await _capture_chamfer(true, "")
	var far_diff := _image_difference(far_off, far_on)
	_gate_ok("at a hundred metres it has faded out", far_diff < 0.01,
			"%.2f%% of sampled pixels" % (far_diff * 100.0))
	_gate_ok("which is far less than it changes up close", far_diff * 4.0 < near_diff,
			"%.2f%% against %.1f%%" % [far_diff * 100.0, near_diff * 100.0])

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Render one frame with the chamfer on or off and hand back the image. A name
## also writes it to shots/, for the eye to judge what a number cannot.
func _capture_chamfer(on: bool, shot_name: String) -> Image:
	_shader_toggles["chamfer_enabled"] = on
	brick_material.set_shader_parameter("chamfer_enabled", on)
	await _frames(3)
	var img := get_viewport().get_texture().get_image()
	if shot_name != "":
		img.save_png("res://shots/%s.png" % shot_name)
		print("[chamfer] shot written: %s.png" % shot_name)
	await RenderingServer.frame_post_draw
	return img


## What fraction of sampled pixels changed. Every fourth pixel each way, which
## is 57,600 samples out of 921,600 -- enough to measure an effect that is drawn
## along every brick edge in the frame.
func _image_difference(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 0.0
	var changed := 0
	var total := 0
	var w := a.get_width()
	var h := a.get_height()
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			total += 1
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			if absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b) > 0.02:
				changed += 1
	return float(changed) / float(maxi(total, 1))


# ---------------------------------------------------------------------------
# What interiors cost, per room against per building
# ---------------------------------------------------------------------------

## Re-bake a chunk's faces and wait for the worker, returning wall milliseconds.
##
## Wall time, and it is the honest number for this question: a room that opens
## invalidates its building's whole face bake, and the building cannot be drawn
## again until that bake lands. The streamer hides the latency behind a tick; it
## does not remove the work.
func _bake_and_wait(chunk: int) -> float:
	var t := Time.get_ticks_usec()
	world.bake_chunk_async(chunk)
	var spin := 0
	while not world.bake_ready(chunk) and spin < 400000:
		OS.delay_usec(50)
		spin += 1
	return float(Time.get_ticks_usec() - t) / 1000.0


## Is it worth streaming interiors a ROOM at a time, or should a building simply
## furnish itself all at once?
##
## The question only has an answer at scale, so this runs on `--big`: buildings
## up to 28 x 22 m on plan and 84 m tall, which is where a floor is a dozen
## rooms rather than four.
##
##     godot --path . --resolution 1280x720 -- --interiors --big
##
## Both arms run on the SAME building, back to back, with the streamers and the
## collision merge held off -- the first version of this measured one arm on a
## 4,000-room tower and the other on a 180-room one, and let `_merge_quiet_
## buildings` rebuild the body underneath both of them.
func _run_interiors_pass() -> void:
	_measuring = true
	print("[interiors] what a room costs, and what a building's worth of them costs")
	print("[interiors] %d building(s), %s shapes" % [
			registry.buildings.size(), "BIG" if _big else "default"])

	# What the recipes alone say. No bricks anywhere: this is the shape of the
	# problem before any of it is paid for.
	var t_rooms := Time.get_ticks_usec()
	var total_rooms := 0
	var biggest := -1
	var biggest_rooms := 0
	for b in registry.buildings:
		var n: int = registry.rooms_of(b.id).size()
		total_rooms += n
		if n > biggest_rooms:
			biggest_rooms = n
			biggest = b.id
	var rooms_ms := float(Time.get_ticks_usec() - t_rooms) / 1000.0
	print("[interiors] %d room(s) across the city, %d in the biggest building, generated in %.0f ms"
			% [total_rooms, biggest_rooms, rooms_ms])
	for b in registry.buildings:
		if b.id > 5:
			break
		var st: int = RoomManifest.storeys_of(b.recipe.courses).size()
		var n: int = registry.rooms_of(b.id).size()
		@warning_ignore("integer_division")
		print("[interiors]   building %d: %d x %d studs, %d courses -> %d storeys, %d rooms (%d a storey)"
				% [b.id, b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses,
				st, n, n / maxi(st, 1)])

	var host := registry.get_building(biggest)
	var box := registry.local_box(biggest)
	var mid: Vector3 = host.xform * (box.position + box.size * 0.5)
	camera.global_position = mid + Vector3(0.0, 0.0, -box.size.z - 40.0)
	camera.look_at(mid, Vector3.UP)
	await _frames(10)
	var chunk := await _fresh_bricks(biggest)
	var bare_blocks := world.get_alive_block_count(chunk)
	var bare_mb := _world_mb()
	var bare_shapes := PhysicsServer3D.body_get_shape_count(_brick_bodies[biggest])
	var bare_bake := _bake_and_wait(chunk)
	print("[interiors] the building: %d brick(s), %d collision box(es), %.1f MB, one face bake %.0f ms"
			% [bare_blocks, bare_shapes, bare_mb, bare_bake])

	# --- A: a room at a time, which is what _stream_rooms does ---------------
	var rooms := registry.rooms_of(biggest)
	var sample: int = mini(rooms.size(), 40)
	var lay := 0.0
	var shapes_ms := 0.0
	var mesh_ms := 0.0
	var worst := 0.0
	var opened := 0
	var laid := 0
	for room in rooms:
		if opened >= sample:
			break
		if room.active:
			continue
		var a := Time.get_ticks_usec()
		var placed: int = registry.activate_room(biggest, room.id)
		var b_ := Time.get_ticks_usec()
		if placed <= 0:
			continue
		_add_room_shapes(biggest, room.id)
		var c := Time.get_ticks_usec()
		# Everything else _open_room does. The face bake is NOT in this list
		# any more and that is the whole point: a decorative block is not in
		# the bake, so opening a room cannot invalidate it. What is left is
		# redrawing the furniture, over the furniture's own blocks.
		_refresh_furniture(biggest)
		var d := Time.get_ticks_usec()
		lay += float(b_ - a) / 1000.0
		shapes_ms += float(c - b_) / 1000.0
		mesh_ms += float(d - c) / 1000.0
		worst = maxf(worst, float(d - a) / 1000.0)
		laid += placed
		opened += 1
		await _frames(1)
	var a_total := lay + shapes_ms + mesh_ms
	var per_room := a_total / maxf(opened, 1)
	print("\n[interiors] A: one room at a time (what the streamer does)")
	print("[interiors]   %d room(s), %d brick(s), %.0f ms total, %.1f ms a room, worst %.1f ms"
			% [opened, laid, a_total, per_room, worst])
	print("[interiors]   lay %.0f + collision %.0f (%.0f%%) + furniture redraw %.0f ms; face bake untouched"
			% [lay, shapes_ms, 100.0 * shapes_ms / maxf(a_total, 0.001), mesh_ms])
	print("[interiors]   every room in this building this way: %d x %.1f ms = %.0f s of work"
			% [rooms.size(), per_room, rooms.size() * per_room / 1000.0])
	print("[interiors]   %.1f MB (+%.1f), %d collision box(es) (+%d)"
			% [_world_mb(), _world_mb() - bare_mb,
			PhysicsServer3D.body_get_shape_count(_brick_bodies[biggest]),
			PhysicsServer3D.body_get_shape_count(_brick_bodies[biggest]) - bare_shapes])
	await _save("interiors_room")

	# --- B: the same building, all of it at once ------------------------------
	# The alternative: no per-room streaming. Every room is furnished the moment
	# anybody is near the building, which is ONE collision build, ONE face bake
	# and ONE mesh upload rather than one of each per room.
	chunk = await _fresh_bricks(biggest)
	var b_bare_mb := _world_mb()
	var b_bare_shapes := PhysicsServer3D.body_get_shape_count(_brick_bodies[biggest])
	var t_all := Time.get_ticks_usec()
	var all_laid := 0
	for room in registry.rooms_of(biggest):
		all_laid += registry.activate_room(biggest, room.id)
	var t_laid := Time.get_ticks_usec()
	# Batched: one swap of the furniture body in and out of the physics
	# space for the lot. A swap a room is quadratic and measured 11.6 s.
	var fb := _room_body(biggest)
	PhysicsServer3D.body_set_space(fb, RID())
	for room in registry.rooms_of(biggest):
		_add_room_shapes(biggest, room.id, true)
	PhysicsServer3D.body_set_space(fb, get_world_3d().space)
	var t_shapes := Time.get_ticks_usec()
	_refresh_furniture(biggest)
	var t_mesh := Time.get_ticks_usec()
	var bl := float(t_laid - t_all) / 1000.0
	var bs := float(t_shapes - t_laid) / 1000.0
	var bm := float(t_mesh - t_shapes) / 1000.0
	var b_total := float(t_mesh - t_all) / 1000.0
	print("\n[interiors] B: the same building, every room at once")
	print("[interiors]   %d room(s), %d brick(s), %.0f ms total"
			% [registry.rooms_of(biggest).size(), all_laid, b_total])
	print("[interiors]   lay %.0f ms + collision %.0f ms + furniture redraw %.0f ms"
			% [bl, bs, bm])
	print("[interiors]   %.1f MB (+%.1f), %d collision box(es) (+%d)"
			% [_world_mb(), _world_mb() - b_bare_mb,
			PhysicsServer3D.body_get_shape_count(_brick_bodies[biggest]),
			PhysicsServer3D.body_get_shape_count(_brick_bodies[biggest]) - b_bare_shapes])
	print("[interiors]   %.0f ms once, against %.0f s of work spread a room at a time"
			% [b_total, rooms.size() * per_room / 1000.0])
	await _frames(10)
	await _save("interiors_building")

	# --- C: a storey at a time, the obvious middle ---------------------------
	# Rooms are cut out of storeys, and a storey is what a player walks onto.
	# It is the same trade one notch along: fewer bakes than a room at a time,
	# less resident furniture than a building at a time.
	chunk = await _fresh_bricks(biggest)
	var storeys: int = maxi(RoomManifest.storeys_of(host.recipe.courses).size(), 1)
	@warning_ignore("integer_division")
	var per_storey: int = maxi(registry.rooms_of(biggest).size() / storeys, 1)
	var c_total := 0.0
	var c_rooms := 0
	var c_floors: int = mini(storeys, 4)
	for f in c_floors:
		var t_f := Time.get_ticks_usec()
		for k in per_storey:
			var idx: int = f * per_storey + k
			if idx >= registry.rooms_of(biggest).size():
				break
			if registry.activate_room(biggest, idx) > 0:
				_add_room_shapes(biggest, idx)
				c_rooms += 1
		_refresh_furniture(biggest)
		c_total += float(Time.get_ticks_usec() - t_f) / 1000.0
		await _frames(1)
	print("\n[interiors] C: a storey at a time")
	print("[interiors]   %d storey(s), %d room(s), %.0f ms total, %.0f ms a storey"
			% [c_floors, c_rooms, c_total, c_total / maxf(c_floors, 1)])
	print("[interiors]   every storey of this building: %d x %.0f ms = %.1f s of work"
			% [storeys, c_total / maxf(c_floors, 1),
			storeys * (c_total / maxf(c_floors, 1)) / 1000.0])
	await _frames(5)

	# --- E: the same building with every room DRAWN ---------------------------
	# Scale §4.1 rung 2: the manifest on screen and one box an item, no blocks.
	# The thing to beat is arm B -- every room real -- and what it is meant to
	# cost is a few hundred boxes and no bricks at all.
	chunk = await _fresh_bricks(biggest)
	var e_blocks := world.get_alive_block_count(chunk)
	var e_bare_mb := _world_mb()
	var e_room_shapes := 0
	var t_e := Time.get_ticks_usec()
	var e_items := 0
	for room in registry.rooms_of(biggest):
		e_items += registry.draw_room(biggest, room.id)
	var t_e_drawn := Time.get_ticks_usec()
	_sync_drawn(biggest)
	var t_e_synced := Time.get_ticks_usec()
	if _room_bodies.has(biggest):
		e_room_shapes = PhysicsServer3D.body_get_shape_count(_room_bodies[biggest])
	var e_instances := 0
	if _drawn_furniture.has(biggest):
		e_instances = (_drawn_furniture[biggest] as MultiMeshInstance3D).multimesh.instance_count
	var e_total := float(t_e_synced - t_e) / 1000.0
	print("\n[interiors] E: the same building, every room DRAWN (rung 2)")
	print("[interiors]   %d room(s), %d item(s), %.0f ms total, %.3f ms a room"
			% [registry.rooms_of(biggest).size(), e_items, e_total,
			e_total / maxf(registry.rooms_of(biggest).size(), 1)])
	print("[interiors]   manifest + buffer %.0f ms + collision and drawing %.0f ms"
			% [float(t_e_drawn - t_e) / 1000.0, float(t_e_synced - t_e_drawn) / 1000.0])
	print("[interiors]   %d brick(s) laid, %d collision box(es), %d instance(s) drawn, %.1f MB (+%.1f)"
			% [world.get_alive_block_count(chunk) - e_blocks, e_room_shapes, e_instances,
			_world_mb(), _world_mb() - e_bare_mb])
	await _frames(5)
	await _save("interiors_drawn")
	# And a blast still destroys what it reaches: the room it lands in is
	# promoted to bricks first, then hit.
	var target: Room = null
	for index in host.drawn_rooms:
		var r: Room = registry.get_room(biggest, index)
		if not r.drawn_boxes.is_empty():
			target = r
			break
	if target != null:
		# The drawing is in the chunk's own space, as the furniture body is.
		var aim: Vector3 = world.get_chunk_transform(chunk) * target.drawn_boxes[0].get_center()
		# Near enough that somebody is watching: an unwatched blast writes a
		# room off rather than laying it, which is the other half of the rule.
		camera.global_position = aim + Vector3(0.0, 0.5, 3.0)
		_blast(aim, 0.6)
		var guard := 0
		while not _damage_queue.is_empty() and guard < 120:
			await _frames(1)
			guard += 1
		var dead := {}
		for id in world.get_dead_blocks(chunk):
			dead[id] = true
		var lost := 0
		for item in target.items:
			for block in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
				if dead.has(block):
					lost += 1
		print("[interiors]   a blast into a drawn room: %s, %d of its bricks destroyed, %d room(s) still drawn"
				% ["promoted" if target.active else "NOT PROMOTED", lost, host.drawn_rooms.size()])
		print("[interiors]   %s" % ("ok    a blast still destroys what it reaches"
				if target.active and lost > 0 else "FAIL  the blast went through drawn furniture"))
	for room in registry.rooms_of(biggest):
		registry.undraw_room(biggest, room.id)
	_sync_drawn(biggest)
	await _frames(5)

	# --- F: the same building FAKED ------------------------------------------
	# Every room against an outside wall drawn unlit from its manifest, with no
	# collision and nothing laid: what a window shows from further than anybody
	# can reach. Cold first -- every manifest and buffer worked out -- then warm,
	# which is what a rebuild after a room changes costs.
	chunk = await _fresh_bricks(biggest)
	var f_blocks := world.get_alive_block_count(chunk)
	var f_cold := 0.0
	var f_worst := 0.0
	var f_calls := 0
	_fake_dirty[biggest] = true
	while _fake_dirty.has(biggest) and f_calls < 50:
		var t_c := Time.get_ticks_usec()
		_sync_fake(biggest)
		var dt_c := float(Time.get_ticks_usec() - t_c) / 1000.0
		f_cold += dt_c
		f_worst = maxf(f_worst, dt_c)
		f_calls += 1
	print("[interiors]   cold, %d pass(es) of up to %d rooms: worst pass %.1f ms"
			% [f_calls, FAKE_ROOMS_PER_PASS, f_worst])
	var t_f := Time.get_ticks_usec()
	_sync_fake(biggest)
	var f_warm := float(Time.get_ticks_usec() - t_f) / 1000.0
	var faked: PackedInt32Array = _fake_rooms.get(biggest, PackedInt32Array())
	var f_instances := 0
	if _fake_furniture.has(biggest):
		f_instances = (_fake_furniture[biggest] as MultiMeshInstance3D).multimesh.instance_count
	var f_shapes: int = (_drawn_shapes.get(biggest, {}) as Dictionary).size() \
			+ (_room_shapes.get(biggest, {}) as Dictionary).size()
	print("\n[interiors] F: the same building, every outer room FAKED (no collision, unlit)")
	print("[interiors]   %d of %d room(s) faked, %d instance(s), %.1f ms cold, %.2f ms warm"
			% [faked.size(), registry.rooms_of(biggest).size(), f_instances, f_cold, f_warm])
	print("[interiors]   %d brick(s) laid, %d room(s) holding collision"
			% [world.get_alive_block_count(chunk) - f_blocks, f_shapes])
	# Look at it: a few storeys up, from the street, twenty-five metres out.
	var face: Vector3 = host.xform * (box.position + Vector3(box.size.x * 0.5, 12.0, 0.0))
	camera.global_position = face + Vector3(0.0, -8.0, -25.0)
	camera.look_at(face, Vector3.UP)
	await _frames(10)
	await _save("interiors_fake")
	_drop_fake(biggest)
	await _frames(5)

	# --- D: what a streaming pass costs, which is what the player feels ----
	# Arms A to C measure what OPENING a room costs. This measures what the
	# pass costs when it is deciding -- the part that runs every tick whether
	# or not anything opens, and the part that was most of the bill.
	chunk = await _fresh_bricks(biggest)
	var inside: Vector3 = host.xform * (box.position + box.size * 0.5)
	camera.global_position = inside
	await _frames(2)
	var pass_total := 0.0
	var pass_worst := 0.0
	var passes := 40
	for i in passes:
		var t := Time.get_ticks_usec()
		_stream_rooms()
		var dt := float(Time.get_ticks_usec() - t) / 1000.0
		pass_total += dt
		pass_worst = maxf(pass_worst, dt)
		await _frames(1)
	print("\n[interiors] D: a streaming pass, standing inside the building")
	print("[interiors]   %d pass(es), %.2f ms each, worst %.2f ms, %d room(s) open after"
			% [passes, pass_total / float(passes), pass_worst,
			_open_rooms_of(biggest)])
	# What the same decision costs the way it used to be made: measure every
	# room of every building in view rather than asking which are in range.
	var t_scan := Time.get_ticks_usec()
	var seen := 0
	for id in _near_buildings(camera.global_position, ROOM_VIEW_RANGE):
		var sb := registry.get_building(id)
		if sb == null or not sb.is_materialised():
			continue
		for room in registry.rooms_of(id):
			seen += 1
			_box_distance(room.world_box(sb.xform), camera.global_position)
	print("[interiors]   the same decision by walking every room: %d room(s), %.2f ms"
			% [seen, float(Time.get_ticks_usec() - t_scan) / 1000.0])
	print("[interiors]   of the passes: gather %.0f, open %.0f, portal %.0f, spill %.0f, close %.0f ms"
			% [_phase_gather, _phase_open, _phase_portal, _phase_spill, _phase_close])
	print("[interiors]   furniture redraw %.0f ms over %d call(s); lay %.0f, collision %.0f"
			% [_furniture_ms, _furniture_calls, _room_lay_ms, _room_shape_ms])

	print("\n[interiors] and what the city is carrying")
	var rep: Dictionary = registry.room_report()
	print("[interiors]   %d room(s), %d open, %d with a diff" % [
			int(rep.rooms), int(rep.active), int(rep.changed)])
	print("[interiors]   %s" % _collision_report())
	print("[interiors]   BrickWorld %.1f MB" % _world_mb())
	get_tree().quit(0)


## Where the physics is going, by piece size: how many pieces are moving and
## how many have settled, and how many collision boxes each class is carrying.
## The solver's cost is bodies, boxes and the contacts between them, so this is
## what says whether a collapse is expensive because of a few enormous pieces
## or a great many small ones -- which are different fixes.
func _physics_census(label: String) -> void:
	var edges := [1, 10, 100, 1000, 1 << 30]
	var names := ["1-9", "10-99", "100-999", "1000+"]
	var rows := []
	for i in names.size():
		rows.append({"moving": 0, "settled": 0, "mbox": 0, "sbox": 0, "bricks": 0})
	for isl in islands.islands:
		if not isl.is_valid():
			continue
		var n := world.get_alive_block_count(isl.chunk)
		var i := 0
		while i < names.size() - 1 and n >= int(edges[i + 1]):
			i += 1
		var r: Dictionary = rows[i]
		if isl.settled:
			r.settled += 1
			r.sbox += isl.shape_count
		else:
			r.moving += 1
			r.mbox += isl.shape_count
		r.bricks += n
	# Jolt answers the server's active-object and pair counts with zero, so the
	# census counts for itself; the physics time is the engine's own monitor.
	var rep: Dictionary = islands.report()
	print("[census] %s: physics %.1f ms this frame; settled so far %d (%d by staying slow, %d by age)"
			% [label, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			int(rep.settled), int(rep.settled_by_rule), int(rep.settled_by_age)])
	for i in names.size():
		var r: Dictionary = rows[i]
		if int(r.moving) + int(r.settled) == 0:
			continue
		print("[census]   %-8s bricks: %4d moving (%6d boxes), %4d settled (%6d boxes), %6d bricks"
				% [names[i], r.moving, r.mbox, r.settled, r.sbox, r.bricks])


## What a far building's windows look like: a shell, close up.
##
##     godot --path . --resolution 1280x720 res://scenes/city.tscn -- --windows
##
## Promotion is held off (`_measuring`), so the camera can walk right up to a
## building that is still a shell -- which in play it never does, because a
## building becomes bricks at PROMOTE_RANGE. That is the point of looking: the
## panes have to hold up at the closest a player ever sees them, and further.
func _run_windows_pass() -> void:
	_measuring = true
	print("[windows] a shell's windows, close up")
	var panes := 0
	var tris := 0
	for id in _shells:
		var shell: MeshInstance3D = _shells[id]
		for child in shell.get_children():
			if child is MeshInstance3D:
				@warning_ignore("integer_division")
				var n: int = (child as MeshInstance3D).mesh.get_faces().size() / 6
				panes += n
				tris += n * 2
	print("[windows] %d pane(s) across %d shell(s), %d triangle(s)" % [panes, _shells.size(), tris])
	var tallest := 0
	var target := -1
	for b in registry.buildings:
		if b.recipe != null and not b.is_build() and b.recipe.courses > tallest:
			tallest = b.recipe.courses
			target = b.id
	var b := registry.get_building(target)
	var box := registry.local_box(target)
	var face: Vector3 = b.xform * (box.position + Vector3(box.size.x * 0.5, 7.5, 0.0))
	# In the street: the city's buildings are only a street apart, so anything
	# much further out than this is inside the one across the road.
	for view in [["windows_near", Vector3(0.0, 0.0, -5.0)],
			["windows_angle", Vector3(-4.0, -1.5, -4.0)],
			["windows_far", Vector3(0.0, 25.0, -40.0)]]:
		camera.global_position = face + (view[1] as Vector3)
		camera.look_at(face, Vector3.UP)
		await _frames(8)
		await _save(str(view[0]))
	get_tree().quit(0)


## What an interior piece IS at every stage of a collapse, counted.
##
##     godot --path . --resolution 1280x720 res://scenes/city.tscn -- --interior-audit
##
## Floating furniture was reported by eye: untextured, hanging where a floor
## used to be, and falling the moment something near it broke. This walks the
## tallest building through what a player does to it -- walks up, touches a
## couple of storeys, blows a floor out, cuts it down, walks to the wreck --
## and after each step counts every way a piece can be in the wrong place.
## See _audit_interiors for what each number means.
func _run_interior_audit_pass() -> void:
	print("[audit] what interior pieces do while a building comes down")
	var target := -1
	var tallest := 0
	for b in registry.buildings:
		if b.recipe != null and not b.is_build() and b.recipe.courses > tallest:
			tallest = b.recipe.courses
			target = b.id
	var b := registry.get_building(target)
	var box := registry.local_box(target)
	var mid: Vector3 = b.xform * (box.position + box.size * 0.5)
	var outside: Vector3 = b.xform * (box.position
			+ Vector3(box.size.x * 0.5, DebugCamera.EYE_HEIGHT, -2.0))
	print("[audit] building %d, %d courses, %d rooms" % [target, tallest,
			registry.rooms_of(target).size()])

	# 1. Walk up to it: bricks, and its near rooms drawn.
	camera.global_position = outside
	camera.look_at(mid, Vector3.UP)
	var guard := 0
	while guard < 900 and (not b.is_materialised() or b.drawn_rooms.is_empty()):
		await _frames(1)
		guard += 1
	await _frames(30)
	# And through its bottom two storeys, as a player walking the floors would:
	# every room there touched, so real.
	var storeys: int = RoomManifest.storeys_of(b.recipe.courses).size()
	@warning_ignore("integer_division")
	var per_storey: int = maxi(registry.rooms_of(target).size() / maxi(storeys, 1), 1)
	var fb := _room_body(target)
	PhysicsServer3D.body_set_space(fb, RID())
	for index in mini(per_storey * 2, registry.rooms_of(target).size()):
		_open_room(target, index, true)
	PhysicsServer3D.body_set_space(fb, get_world_3d().space)
	_refresh_furniture(target)
	_sync_drawn(target)
	# Keep them real for the rest of the pass: this is what a player who has
	# been in there, or a blast that reached them, leaves behind.
	for index in b.open_rooms:
		registry.get_room(target, index).hit = true
	await _frames(10)
	_audit_interiors("walked up and through two storeys", target)

	# 2. Blow the floor out from under a furnished real room on the upper of
	# those storeys, leaving its walls standing.
	var victim: Room = null
	for index in b.open_rooms:
		var r := registry.get_room(target, index)
		if r.lo.y > 4 and r.items.size() > 0:
			victim = r
			break
	if victim != null:
		var cs := BrickWorld.get_cell_size()
		var y := (victim.lo.y - 1) * cs.y
		var x := victim.lo.x * cs.x + 0.5
		while x < (victim.lo.x + victim.size.x) * cs.x:
			var z := victim.lo.z * cs.z + 0.5
			while z < (victim.lo.z + victim.size.z) * cs.z:
				_blast(b.xform * Vector3(x, y, z), 0.9)
				z += 1.0
			x += 1.0
		guard = 0
		while not _damage_queue.is_empty() and guard < 300:
			await _frames(1)
			guard += 1
		await _frames(40)
		_audit_interiors("floor blown out under room %d" % victim.id, target)
	else:
		print("[audit] no furnished real room above the ground storey to undercut")

	# 3. Cut it down: the -X half of its bottom courses, as --shot does.
	var w: float = b.recipe.footprint_x * STUD
	var d: float = b.recipe.footprint_z * STUD
	for course in range(0, 8):
		var cy := (1 + course * TowerRecipe.PLATES_PER_COURSE) * PLATE
		var px := 0.3
		while px < w * 0.55:
			var pz := 0.3
			while pz < d:
				_blast(b.xform * Vector3(px, cy, pz), 1.5)
				pz += 2.0
			px += 2.0
	guard = 0
	while not _damage_queue.is_empty() and guard < 900:
		await _frames(1)
		guard += 1
	await _frames(10)
	_audit_interiors("cut: just after", target)
	await _frames(60)
	_audit_interiors("cut: a second later", target)
	guard = 0
	while guard < 900:
		var isl: Dictionary = islands.report()
		if int(isl.islands) == int(isl.settled):
			break
		await _frames(10)
		guard += 10
	_audit_interiors("settled", target)

	# 4. Walk to what is left of it.
	camera.global_position = outside + Vector3(0.0, 0.0, -6.0)
	camera.look_at(mid, Vector3.UP)
	await _frames(120)
	_audit_interiors("walked to the wreck", target)
	await _save("interior_audit")
	get_tree().quit(0)


## One line of numbers about every interior piece in the city, and one about
## the building being watched.
##
##   ghost      furniture DRAWN for a chunk that no longer holds those blocks:
##              instances on a furniture MultiMesh beyond the chunk's live
##              decorative blocks, or a MultiMesh for a chunk nothing owns
##   loose      a real piece in a STANDING building that grounding does not
##              reach -- it should already have been cut out and dropped
##   hanging    a real piece that grounding reaches, with nothing solid under
##              it: held up sideways, by a wall or a column or a neighbour
##   drawn-air  a drawn item with nothing solid under its box
##   islands    pieces riding islands; furniture-only islands; lone bricks
func _audit_interiors(stage: String, focus: int) -> void:
	var n := {"real": 0, "ghost": 0, "loose": 0, "hanging": 0, "drawn": 0,
			"drawn_air": 0, "isl_pieces": 0, "isl_furniture_only": 0,
			"isl_lone": 0, "isl_ghost": 0, "isl_hanging": 0, "isl_adrift": 0, "orphan": 0,
			"fake": 0, "fake_stale": 0}
	var owned := {}
	for id in _materialised:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var chunk := b.chunk
		owned[chunk] = true
		var decor: PackedInt32Array = world.get_decorative_blocks(chunk)
		n.real += decor.size()
		var node: MultiMeshInstance3D = _furniture.get(chunk)
		if node != null and is_instance_valid(node) and node.visible:
			n.ghost += maxi(node.multimesh.visible_instance_count - decor.size(), 0)
		if not decor.is_empty():
			var grounded: PackedByteArray = world.solve_grounded(chunk)
			for block in decor:
				if block >= grounded.size() or grounded[block] == 0:
					n.loose += 1
					if n.loose <= 3:
						_audit_describe(chunk, block, "loose")
				elif not _audit_supported(chunk, block):
					n.hanging += 1
		for room in registry.drawn_rooms_of(id):
			for item_box in room.drawn_boxes:
				n.drawn += 1
				if not _audit_box_supported(chunk, item_box):
					n.drawn_air += 1
		# Faked rooms drawn from a cache that is out of date: what a collapse
		# took may still be in the picture until the next rebuild.
		if _fake_furniture.has(id):
			n.fake += (_fake_furniture[id] as MultiMeshInstance3D).multimesh.instance_count
		for index in (_fake_rooms.get(id, PackedInt32Array()) as PackedInt32Array):
			var fr := registry.get_room(id, index)
			if fr.fake_gone != fr.gone.size():
				n.fake_stale += 1
	for chunk in _furniture:
		var node: MultiMeshInstance3D = _furniture[chunk]
		if not owned.has(chunk) and node != null and is_instance_valid(node):
			n.orphan += node.multimesh.visible_instance_count
	for id in _fake_furniture:
		var bf := registry.get_building(id)
		var fnode: MultiMeshInstance3D = _fake_furniture[id]
		if (bf == null or not bf.is_materialised() or bf.toppled) and is_instance_valid(fnode):
			n.orphan += fnode.multimesh.instance_count
	for id in _drawn_furniture:
		var bd := registry.get_building(id)
		var node: MultiMeshInstance3D = _drawn_furniture[id]
		if (bd == null or not bd.is_materialised() or bd.toppled) and is_instance_valid(node):
			n.orphan += node.multimesh.instance_count
	for isl in islands.islands:
		if not isl.is_valid():
			continue
		var decor: PackedInt32Array = world.get_decorative_blocks(isl.chunk)
		if decor.is_empty():
			continue
		n.isl_pieces += decor.size()
		var alive := world.get_alive_block_count(isl.chunk)
		if alive == decor.size():
			n.isl_furniture_only += 1
		if alive == 1:
			n.isl_lone += 1
		var node: MultiMeshInstance3D = islands._furniture.get(isl.chunk)
		if node != null and is_instance_valid(node):
			n.isl_ghost += maxi(node.multimesh.visible_instance_count - decor.size(), 0)
		# Hanging inside the piece: nothing under it along whatever is down
		# for this piece now. It cannot fall -- it is welded into a rigid
		# body -- so it floats for as long as the piece exists.
		var down := RoomManifest.down_axis(isl.chunk_transform())
		for block in decor:
			if not _audit_supported(isl.chunk, block, down):
				n.isl_hanging += 1
		# Adrift: joined to no structure at all, only to other furniture or to
		# nothing. That is not a chair clicked to a floor that is now a wall;
		# it is a chair in mid-air that happens to share a rigid body.
		for group in world.get_components(isl.chunk):
			var structural := false
			for block in (group as PackedInt32Array):
				if not world.is_block_decorative(isl.chunk, block):
					structural = true
					break
			if not structural:
				n.isl_adrift += (group as PackedInt32Array).size()
	var fb := registry.get_building(focus)
	var st := {"shut": 0, "drawn": 0, "real": 0, "spilled": 0, "written_off": 0}
	for room in registry.rooms_of(focus):
		if room.active:
			st.real += 1
		elif room.drawn:
			st.drawn += 1
		elif room.spilled:
			st.spilled += 1
		else:
			st.shut += 1
		if room.items.size() > 0 and room.gone.size() >= room.items.size():
			st.written_off += 1
	print("\n[audit] %s" % stage)
	print("[audit]   standing: %d real piece(s), %d ghost, %d loose, %d hanging; %d drawn item(s), %d over air; %d faked part(s), %d stale faked room(s)"
			% [n.real, n.ghost, n.loose, n.hanging, n.drawn, n.drawn_air, n.fake, n.fake_stale])
	print("[audit]   islands: %d piece(s) riding, %d with nothing under them, %d ADRIFT (joined to no structure), %d furniture-only island(s), %d lone brick(s), %d ghost; %d orphaned instance(s)"
			% [n.isl_pieces, n.isl_hanging, n.isl_adrift, n.isl_furniture_only, n.isl_lone, n.isl_ghost, n.orphan])
	print("[audit]   spilled so far: %d room(s), of which into a piece still moving: %d; furniture-only pieces deleted where they came loose: %d block(s)"
			% [_spilled_rooms, _audit_spilled_moving, int(islands.report().furniture_deleted)])
	var dormant: Dictionary = islands.dormant_report()
	print("[audit]   dormant: %s" % str(dormant))
	if _wrecks.has(focus):
		var wk: int = _wrecks[focus]
		var alive_wk := world.is_chunk_alive(wk)
		print("[audit]   wreck chunk %d: alive %s, an island %s, %d furniture block(s) in it"
				% [wk, alive_wk, islands.find_by_chunk(wk) != null,
				world.get_decorative_blocks(wk).size() if alive_wk else 0])
	else:
		print("[audit]   no wreck recorded for building %d" % focus)
	print("[audit]   building %d: %s, toppled %s -- rooms %d shut, %d drawn, %d real, %d spilled, %d written off"
			% [focus, "bricks" if fb.is_materialised() else "not bricks", fb.toppled,
			st.shut, st.drawn, st.real, st.spilled, st.written_off])


## One line about a misplaced piece: what it is, where, and what it touches.
func _audit_describe(chunk: int, block: int, what: String) -> void:
	var ticks: Array = world.get_block_ticks(chunk, block)
	var parts := []
	for nb in world.get_block_neighbours(chunk, block):
		parts.append("%s%s" % [world.get_archetype_name(world.get_block_archetype(chunk, nb)),
				" (furniture)" if world.is_block_decorative(chunk, nb) else ""])
	print("[audit]     %s: %s at ticks %s size %s, touching %s" % [what,
			world.get_archetype_name(world.get_block_archetype(chunk, block)),
			str(ticks[0]) if not ticks.is_empty() else "?",
			str(ticks[1]) if not ticks.is_empty() else "?", str(parts)])


## Is anything solid directly under this block, in its own chunk? "Under" is
## `down` in the chunk's own grid, which for a standing building is -Y.
func _audit_supported(chunk: int, block: int, down: Vector3i = Vector3i(0, -1, 0)) -> bool:
	var ticks: Array = world.get_block_ticks(chunk, block)
	if ticks.is_empty():
		return true
	var tpc := Vector3i(BrickWorld.ticks_per_stud(), BrickWorld.ticks_per_plate(),
			BrickWorld.ticks_per_stud())
	var lo: Vector3i = ticks[0]
	var size: Vector3i = ticks[1]
	var origin: Vector3i = world.get_chunk_origin(chunk)
	@warning_ignore("integer_division")
	var cell := Vector3i(lo.x / tpc.x, lo.y / tpc.y, lo.z / tpc.z) + origin
	@warning_ignore("integer_division")
	var span := Vector3i(maxi(size.x / tpc.x, 1), maxi(size.y / tpc.y, 1), maxi(size.z / tpc.z, 1))
	# The block's cells on its down face, and the cell one step past each.
	for x in span.x:
		for y in span.y:
			for z in span.z:
				var on_face := (down.x < 0 and x == 0) or (down.x > 0 and x == span.x - 1) 						or (down.y < 0 and y == 0) or (down.y > 0 and y == span.y - 1) 						or (down.z < 0 and z == 0) or (down.z > 0 and z == span.z - 1)
				if on_face and world.is_solid(chunk, cell + Vector3i(x, y, z) + down):
					return true
	return false


## The same question for a drawn item's box, in the chunk's own metres.
func _audit_box_supported(chunk: int, item_box: AABB) -> bool:
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = world.get_chunk_origin(chunk)
	var lo := Vector3i(roundi(item_box.position.x / cs.x), roundi(item_box.position.y / cs.y),
			roundi(item_box.position.z / cs.z)) + origin
	var sx := maxi(roundi(item_box.size.x / cs.x), 1)
	var sz := maxi(roundi(item_box.size.z / cs.z), 1)
	for x in sx:
		for z in sz:
			if world.is_solid(chunk, Vector3i(lo.x + x, lo.y - 1, lo.z + z)):
				return true
	return false


func _world_mb() -> float:
	return float(world.get_memory_report().total_bytes as int) / 1048576.0


## Give a building brand-new bricks: no rooms open, no merged collision, one
## bake done. Both arms start here so neither inherits the other's state.
func _fresh_bricks(id: int) -> int:
	var b := registry.get_building(id)
	if b.is_materialised():
		for room in registry.rooms_of(id):
			if room.active:
				registry.deactivate_room(id, room.id)
		_demote(id, 0.0)
		_materialised.erase(id)
		await _frames(2)
	_free_shell(id)
	var chunk := _promote(id)
	var guard := 0
	while _pending_bricks.has(id) and guard < 1200:
		await _frames(1)
		guard += 1
	_brick_merged[id] = false
	return chunk


# ---------------------------------------------------------------------------
# The interiors gate
# ---------------------------------------------------------------------------

## Do rooms hold things, and only when something is asking?
##
## Docs/Interiors.md. The truth layer's half is `tools/interior_probe.gd`; this
## is the half with distances, collision and a mesh in it.
func _run_rooms_pass() -> void:
	print("[rooms] what is inside a building, and what it costs")
	var b := registry.get_building(0)
	var rep: Dictionary = registry.room_report()
	_gate_ok("a city nobody has reached holds no rooms at all", int(rep.rooms) == 0,
			"%d" % int(rep.rooms))

	# Walking up to one is enough. Nothing shoots this building and nothing
	# needs to: what it shows is what PROMOTE_RANGE gives it, and before that
	# range existed an intact building had no interior at all -- the first shot
	# into one both materialised it and compromised its rooms in the same frame,
	# so the furniture arrived in the act of being destroyed.
	var near_id: int = mini(12, registry.buildings.size() - 1)
	var nb := registry.get_building(near_id)
	var nbox := registry.local_box(near_id)
	var nmid: Vector3 = nb.xform * (nbox.position + nbox.size * 0.5)
	camera.global_position = nmid + Vector3(0.0, 6.0, -150.0)
	camera.look_at(nmid, Vector3.UP)
	await _frames(20)
	_gate_ok("from a hundred and fifty metres it is a shell, not bricks",
			not nb.is_materialised())
	_gate_ok("and it is holding nothing", _open_rooms_of(near_id) == 0)

	# Against its wall, OUTSIDE: two metres off the face at eye height. Its
	# middle is inside a room, and standing in a room is touching it.
	camera.global_position = nb.xform * (nbox.position
			+ Vector3(nbox.size.x * 0.5, DebugCamera.EYE_HEIGHT, -2.0))
	camera.look_at(nmid, Vector3.UP)
	var walk_guard := 0
	var near_laid := 0
	while walk_guard < 900 and (not nb.is_materialised() or _drawn_rooms_of(near_id) == 0):
		await _frames(1)
		walk_guard += 1
		near_laid = 0
		for room in registry.rooms_of(near_id):
			if not room.active:
				continue
			for item in room.items:
				near_laid += (item.get("blocks", PackedInt32Array()) as PackedInt32Array).size()
	_gate_ok("standing against it makes it bricks, unshot", nb.is_materialised())
	_gate_ok("and furnishes it without anybody firing a thing",
			_drawn_rooms_of(near_id) > 0, "%d drawn" % _drawn_rooms_of(near_id))
	_gate_ok("with the building still undamaged", not nb.is_damaged())
	# Drawn, not built (Scale §4.1 rung 2): furniture nobody has touched is on
	# screen and solid, and is not a single brick.
	_gate_ok("and not a brick of it laid for being near", near_laid == 0,
			"%d blocks" % near_laid)

	# Shoot it: a building becomes bricks, and its rooms become askable.
	var box := registry.local_box(0)
	var mid: Vector3 = b.xform * (box.position + box.size * 0.5)
	camera.global_position = mid + Vector3(0.0, 2.0, -80.0)
	camera.look_at(mid, Vector3.UP)
	await _frames(10)
	var chunk := _promote(0)
	await _frames(20)
	var rooms := registry.rooms_of(0)
	_gate_ok("a building that is bricks has rooms", rooms.size() > 0, "%d" % rooms.size())
	_gate_ok("and none of them is holding anything from eighty metres away",
			int(registry.room_report().active) == 0 and _drawn_rooms_of(0) == 0,
			"%d open, %d drawn" % [int(registry.room_report().active), _drawn_rooms_of(0)])
	var bare := world.get_alive_block_count(chunk)

	# Walk up to it. Near is DRAWN: the rooms around the player are on screen
	# from their manifests, and nothing is laid.
	camera.global_position = b.xform * (box.position
			+ Vector3(box.size.x * 0.5, DebugCamera.EYE_HEIGHT, -2.0))
	camera.look_at(mid, Vector3.UP)
	# A furnished one: some rooms are generated empty on purpose, and an empty
	# room drawing is an empty room drawing.
	var guard := 0
	var drawn_one: Room = null
	while guard < 600 and drawn_one == null:
		await _frames(1)
		guard += 1
		for room in rooms:
			if room.drawn and not room.drawn_boxes.is_empty():
				drawn_one = room
				break
	_gate_ok("standing next to it draws a room with something in it", drawn_one != null,
			"%d drawn" % _drawn_rooms_of(0))
	_gate_ok("without laying a brick", world.get_alive_block_count(chunk) == bare,
			"%d against %d" % [world.get_alive_block_count(chunk), bare])
	# Step into it: close enough to touch is what makes it bricks (Scale §4.3).
	var rb := drawn_one.world_box(b.xform)
	camera.global_position = rb.position + Vector3(0.4, rb.size.y * 0.55, 0.4)
	camera.look_at(rb.get_center() - Vector3(0.0, rb.size.y * 0.3, 0.0), Vector3.UP)
	guard = 0
	while guard < 300 and not drawn_one.active:
		await _frames(1)
		guard += 1
	var opened: Room = drawn_one if drawn_one.active else null
	_gate_ok("standing in it makes it bricks", opened != null,
			"%d open" % int(registry.room_report().active))
	_gate_ok("and stops drawing it", not drawn_one.drawn)
	_gate_ok("and its contents are bricks in the building",
			world.get_alive_block_count(chunk) > bare,
			"%d against %d" % [world.get_alive_block_count(chunk), bare])
	var laid := 0
	for item in opened.items:
		laid += (item.get("blocks", PackedInt32Array()) as PackedInt32Array).size()
	_gate_ok("which laid real bricks", laid > 0, "%d blocks" % laid)
	# Standing in the room and looking across it already, which is the only
	# place the contents can be seen from -- they are inside a building.
	await _frames(40)
	await _save("rooms_open")

	# Solid: the furniture is on the building's own body, so it is something to
	# stand on and something to shoot.
	var first_item: Dictionary = opened.items[0]
	var block: int = (first_item.get("blocks", PackedInt32Array()) as PackedInt32Array)[0]
	var ticks: Array = world.get_block_ticks(chunk, block)
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var at: Vector3 = b.xform * (Vector3(ticks[0] as Vector3i) * tick_m)
	var from: Vector3 = at + Vector3(0.0, 6.0, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, at - Vector3(0.0, 0.5, 0.0))
	q.collision_mask = Layers.HITSCAN_MASK
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	_gate_ok("what is in the room is solid", not hit.is_empty())

	# And destructible, as the building's own bricks.
	var before := world.get_alive_block_count(chunk)
	_blast(at + Vector3(0.0, 0.2, 0.0), 1.2)
	guard = 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(20)
	_gate_ok("and destructible", world.get_alive_block_count(chunk) < before,
			"%d -> %d" % [before, world.get_alive_block_count(chunk)])

	# Walk away: the contents go, the diff stays.
	camera.global_position = mid + Vector3(0.0, 20.0, -120.0)
	camera.look_at(mid, Vector3.UP)
	guard = 0
	while guard < 300 and (int(registry.room_report().active) > 0 or _drawn_rooms_of(0) > 0):
		await _frames(1)
		guard += 1
	rep = registry.room_report()
	_gate_ok("walking away shuts the rooms", int(rep.active) == 0, "%d open" % int(rep.active))
	_gate_ok("and stops drawing them", _drawn_rooms_of(0) == 0, "%d drawn" % _drawn_rooms_of(0))
	_gate_ok("and what was destroyed is remembered", int(rep.changed) > 0,
			"%d rooms with a diff" % int(rep.changed))
	_gate_ok("the building is back to what it was, plus its damage",
			world.get_alive_block_count(chunk) <= bare,
			"%d against %d" % [world.get_alive_block_count(chunk), bare])

	# Seeing in: an opening in a wall is a way to see a room from further than
	# anybody could walk. What is seen is the FAKE -- the manifest drawn unlit,
	# with no collision and nothing laid -- for every room against an outside
	# wall, whether or not anybody is looking at its window.
	print("\n[rooms] an opening in the wall is a way in")
	var host := registry.get_building(1)
	_promote(1)
	await _frames(20)
	var target: Room = null
	for room in registry.rooms_of(1):
		if room.outer and RoomManifest.items_for(room).size() > 0:
			target = room
			break
	_gate_ok("there is a room against an outside wall to look into", target != null)
	var rbox := target.world_box(host.xform)
	var wall: Vector3 = Vector3(rbox.get_center().x, rbox.get_center().y,
			host.xform.origin.z)
	# Beyond reach of anything but seeing: sixty metres, inside the seventy a
	# room can be seen into.
	var stand := wall - Vector3(0.0, 0.0, 60.0)
	camera.global_position = stand
	camera.look_at(wall, Vector3.UP)
	await _frames(20)
	# Its walls have windows: every storey with a slab over it is cut through
	# under its lintel course. Before them a room could be walked into but
	# never seen into.
	var windows: int = registry.openings_of(1, target.id).size()
	_gate_ok("an undamaged wall has windows in it", windows > 0, "%d" % windows)
	_gate_ok("each of them one window, not a box drawn round two",
			_widest_opening(1, target.id) < 2.0,
			"widest %.2f m" % _widest_opening(1, target.id))
	guard = 0
	while guard < 300 and not (_fake_rooms.get(1, PackedInt32Array()) as PackedInt32Array).has(target.id):
		await _frames(1)
		guard += 1
	var faked: PackedInt32Array = _fake_rooms.get(1, PackedInt32Array())
	_gate_ok("from sixty metres the rooms behind its windows are faked",
			faked.has(target.id), "%d faked" % faked.size())
	_gate_ok("with nothing drawn, laid or opened for it",
			_drawn_rooms_of(1) == 0 and _open_rooms_of(1) == 0,
			"%d drawn, %d open" % [_drawn_rooms_of(1), _open_rooms_of(1)])
	# Held shapes, not the body's count: a body keeps its switched-off slots.
	var room_shapes: int = (_drawn_shapes.get(1, {}) as Dictionary).size() 			+ (_room_shapes.get(1, {}) as Dictionary).size()
	_gate_ok("and with no collision at all", room_shapes == 0,
			"%d room(s) holding shapes" % room_shapes)
	var inner_faked := 0
	for index in faked:
		if not registry.get_room(1, index).outer:
			inner_faked += 1
	_gate_ok("and only the rooms against an outside wall", inner_faked == 0 and faked.size() > 0,
			"%d inner rooms faked" % inner_faked)
	await _save("rooms_fake")

	# Blow a hole in it. The blast compromises the rooms it reaches, which is a
	# different trigger -- so they are shut again by hand, and the fake comes
	# back without what the blast took.
	_blast(wall, 2.6)
	guard = 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(20)
	_shut_all_rooms(1)
	_gate_ok("there is a hole in the wall now",
			not registry.openings_of(1, target.id).is_empty(),
			"%d opening(s)" % registry.openings_of(1, target.id).size())
	_gate_ok("and every room in it is shut again",
			_open_rooms_of(1) == 0 and _drawn_rooms_of(1) == 0,
			"%d open, %d drawn" % [_open_rooms_of(1), _drawn_rooms_of(1)])
	guard = 0
	while guard < 200 and _fake_dirty.has(1):
		await _frames(1)
		guard += 1
	_gate_ok("and the fake is rebuilt from what is left",
			not _fake_dirty.has(1) and _fake_rooms.has(1),
			"%d faked" % (_fake_rooms.get(1, PackedInt32Array()) as PackedInt32Array).size())
	await _save("rooms_portal")

	# Walk away: past the release range the fake goes.
	camera.global_position = wall - Vector3(0.0, 0.0, 120.0)
	guard = 0
	while guard < 300 and _fake_rooms.has(1):
		await _frames(1)
		guard += 1
	_gate_ok("walking away drops the fake", not _fake_rooms.has(1)
			and not _fake_furniture.has(1))

	# And the wreckage. A building comes down while nobody is inside it; what
	# was in its rooms is owed to whoever walks up to the pile afterwards.
	print("\n[rooms] what was in a building that fell down")
	var fell := registry.get_building(2)
	camera.global_position = fell.xform.origin + Vector3(0.0, 40.0, -220.0)
	camera.look_at(fell.xform.origin, Vector3.UP)
	await _frames(20)
	_promote(2)
	await _frames(20)
	_gate_ok("nobody opened anything in it", _open_rooms_of(2) == 0)
	var fell_chunk := fell.chunk
	_topple(2)
	var settle := 0
	while settle < 240 and islands.find_by_chunk(fell_chunk) == null:
		await _frames(1)
		settle += 1
	await _frames(20)
	# Nobody had touched a room in it, so there is nothing to carry down and
	# nothing owed to the pile: the rooms are written off where they stood.
	# (spill_interiors turns Interiors 4.1's spill back on; --interior-audit
	# is why it is off -- every piece it laid floated through the fall.)
	var written := 0
	for room in registry.rooms_of(2):
		if room.is_changed():
			written += 1
	_gate_ok("its untouched rooms are written off, not spilled",
			registry.spilled_rooms(2).size() == 0 and written > 0,
			"%d spilled, %d written off" % [registry.spilled_rooms(2).size(), written])
	_gate_ok("and nothing was built to do it", _open_rooms_of(2) == 0)

	# Walk up to the pile: nothing is laid into it.
	_gate_ok("the wreck is a piece the city can still find",
			islands.find_by_chunk(fell_chunk) != null)
	var pile: Vector3 = world.get_chunk_transform(fell_chunk).origin
	camera.global_position = pile + Vector3(0.0, 6.0, -12.0)
	camera.look_at(pile, Vector3.UP)
	await _frames(120)
	var in_pile: int = world.get_decorative_blocks(fell_chunk).size() 			if world.is_chunk_alive(fell_chunk) else 0
	_gate_ok("and arriving at it lays no furniture into it", in_pile == 0,
			"%d furniture block(s)" % in_pile)
	await _save("rooms_wreck")

	# A room nowhere near anybody, in the path of a blast, resolves anyway.
	var far := registry.get_building(registry.buildings.size() - 1)
	var far_box := registry.local_box(far.id)
	var far_mid: Vector3 = far.xform * (far_box.position + far_box.size * 0.5)
	_gate_ok("the far building has no rooms open", _open_rooms_of(far.id) == 0,
			"%d open" % _open_rooms_of(far.id))
	_blast(far_mid, 3.0)
	guard = 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)
	var compromised := 0
	for room in registry.rooms_of(far.id):
		if room.active or room.is_changed():
			compromised += 1
	_gate_ok("a blast opens the rooms it reaches, with nobody there", compromised > 0,
			"%d" % compromised)
	await _save("rooms_compromised")

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


# ---------------------------------------------------------------------------
# The dormant gate
# ---------------------------------------------------------------------------

## Does wreckage stop costing anything once nobody is near it?
##
## Docs/Status.md, "give islands back to the world". A settled island used to
## keep a chunk, an occupancy grid, a bake, a mesh and a body for the rest of
## the scene, and the 1.2 GB worst case is mostly that. The truth layer's half
## of this gate is `tools/dormant_probe.gd`; here are the distances, the
## budgets and the memory.
func _run_dormant_pass() -> void:
	print("[dormant] wreckage, given back")

	# Make some. Three buildings promoted and toppled is a field of settled
	# pieces within a few seconds.
	var mid := Vector3.ZERO
	for id in [0, 1, 2]:
		var b := registry.get_building(id)
		mid += b.xform.origin / 3.0
		_promote(id)
	await _frames(20)
	for id in [0, 1, 2]:
		_topple(id)
	camera.global_position = mid + Vector3(0.0, 30.0, -60.0)
	camera.look_at(mid, Vector3.UP)

	# Let them fall and settle. SETTLE_MIN_MS is 900 and a body has to be
	# asleep, so this is seconds of scene time however it is written.
	var guard := 0
	while guard < 600 and int(islands.report().settled) < 1:
		await _frames(1)
		guard += 1
	var rep: Dictionary = islands.report()
	_gate_ok("there is wreckage", int(rep.islands) > 0, "%d islands" % int(rep.islands))
	_gate_ok("and it has settled", int(rep.settled) > 0, "%d settled" % int(rep.settled))
	_gate_ok("none of it is asleep yet", int(rep.dormant) == 0)
	var resident: Dictionary = world.get_memory_report()
	var blocks_before := int(rep.blocks)

	# Walk away. SLEEP_AFTER_MS is six seconds, and the streamer puts one piece
	# away per tick, so this is deliberately not instant.
	camera.global_position = mid + Vector3(0.0, 40.0, -320.0)
	camera.look_at(mid, Vector3.UP)
	guard = 0
	while guard < 1200 and int(islands.report().islands) > 0:
		await _frames(1)
		guard += 1
	rep = islands.report()
	var asleep: Dictionary = world.get_memory_report()
	_gate_ok("walking away puts the wreckage to sleep", int(rep.dormant) > 0,
			"%d asleep, %d still resident" % [int(rep.dormant), int(rep.islands)])
	_gate_ok("the chunks went with it", int(asleep.chunks) < int(resident.chunks),
			"%d chunks, was %d" % [int(asleep.chunks), int(resident.chunks)])
	_gate_ok("and so did the memory",
			int(asleep.total_bytes) < int(resident.total_bytes),
			"%.1f MB, was %.1f MB" % [float(asleep.total_bytes) / 1048576.0,
					float(resident.total_bytes) / 1048576.0])
	var freed := int(resident.total_bytes) - int(asleep.total_bytes)
	_gate_ok("what it kept is a fraction of what it gave back",
			int(rep.dormant_bytes) * 8 < freed,
			"%.1f KB kept against %.1f MB freed" % [
				float(int(rep.dormant_bytes)) / 1024.0, float(freed) / 1048576.0])
	_gate_ok("and every brick is still accounted for",
			int(rep.dormant_blocks) + int(rep.blocks) == blocks_before,
			"%d asleep + %d awake against %d" % [
				int(rep.dormant_blocks), int(rep.blocks), blocks_before])
	print("[dormant] %d piece(s), %d block(s): %.1f MB resident -> %.1f MB + %.1f KB of record" % [
			int(rep.dormant), int(rep.dormant_blocks),
			float(resident.total_bytes) / 1048576.0,
			float(asleep.total_bytes) / 1048576.0,
			float(int(rep.dormant_bytes)) / 1024.0])
	await _save("dormant_asleep")

	# Walk back. It has to be the same wreckage, not a fresh pile.
	var was_dormant := int(rep.dormant)
	var was_blocks := int(rep.dormant_blocks)
	camera.global_position = mid + Vector3(0.0, 30.0, -60.0)
	camera.look_at(mid, Vector3.UP)
	guard = 0
	while guard < 1200 and int(islands.report().dormant) > 0:
		await _frames(1)
		guard += 1
	rep = islands.report()
	_gate_ok("walking back wakes it", int(rep.dormant) == 0,
			"%d still asleep" % int(rep.dormant))
	_gate_ok("as the same pieces", int(rep.islands) >= was_dormant,
			"%d islands for %d that slept" % [int(rep.islands), was_dormant])
	_gate_ok("with the same bricks", int(rep.blocks) == blocks_before,
			"%d against %d" % [int(rep.blocks), blocks_before])
	_gate_ok("settled, not falling over again", int(rep.settled) >= was_dormant,
			"%d settled" % int(rep.settled))
	_gate_ok("and it was woken rather than rebuilt from nothing",
			int(rep.woken) >= was_dormant and was_blocks > 0)
	await _save("dormant_awake")

	# And a piece that is asleep is still there to be shot. Plan section 4.4:
	# damage does not wait for somebody to be near.
	camera.global_position = mid + Vector3(0.0, 40.0, -320.0)
	camera.look_at(mid, Vector3.UP)
	guard = 0
	while guard < 1200 and int(islands.report().dormant) == 0:
		await _frames(1)
		guard += 1
	_gate_ok("something is asleep again", int(islands.report().dormant) > 0)
	var target: IslandManager.Dormant = islands.dormant[0]
	var at: Vector3 = target.record.box.get_center()
	var held := target.record.block_count()
	_blast(at, 3.0)
	guard = 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)
	var woke := false
	var left := 0
	for isl in islands.islands:
		if isl.is_valid() and isl.body.global_position.distance_to(at) < 20.0:
			woke = true
			left += world.get_alive_block_count(isl.chunk)
	_gate_ok("a blast wakes what it reaches", woke)
	_gate_ok("and takes bricks out of it", left > 0 and left < held,
			"%d of %d left" % [left, held])

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


# ---------------------------------------------------------------------------
# The fixture gate
# ---------------------------------------------------------------------------

## Is a staircase part of the building it is in?
##
## Docs/BuildMode.md section 11, Stage 5. The truth layer's half is
## `tools/fixture_probe.gd`; this is the half that needs a scene -- bricks in
## the building's own body, a figure standing on a tread, and what happens to
## the flight when the building comes down.
##
## The first version of this gate asked the opposite questions: whether the
## staircase had a body of its own, whether it woke up when you walked near it,
## whether a falling section passed through it. It did all of those and the
## result was a staircase left standing in the rubble of the building it was
## fixed to. A staircase is bricks in the same grid as the building. These are
## the questions that follow from that.
func _run_fixture_pass() -> void:
	print("[fixture] a staircase made of the building it is in")
	var b := registry.get_building(0)
	var rep: Dictionary = registry.report()

	_gate_ok("every building registered a staircase",
			int(rep.fixtures) == registry.buildings.size(),
			"%d for %d buildings" % [int(rep.fixtures), registry.buildings.size()])
	_gate_ok("and the city is still recipes and shells, staircases included",
			int(world.get_memory_report().chunks) == 0)
	_gate_ok("no fixture holds a chunk of its own", b.fixtures[0].blocks.is_empty())

	# Materialise it the way a shot does.
	var chunk := _promote(0)
	await _frames(20)
	var f := b.fixtures[0]
	var steps: int = int(f.params.get("steps", 0))
	_gate_ok("the building builds its staircase with itself", not f.blocks.is_empty(),
			"%d blocks" % f.blocks.size())
	_gate_ok("every step is there", f.blocks.size() == steps,
			"%d of %d" % [f.blocks.size(), steps])
	_gate_ok("in the SAME chunk as the building", chunk == b.chunk)
	_gate_ok("so the city holds one chunk for the building, not two",
			int(world.get_memory_report().chunks) == 1,
			"%d" % int(world.get_memory_report().chunks))

	# Clipped to the building, which is what makes it come apart with it.
	var joined := 0
	for id in f.blocks:
		for n in world.get_block_neighbours(chunk, id):
			if not f.blocks.has(n):
				joined += 1
	_gate_ok("and it is clipped to the building's own bricks", joined > 0,
			"%d joints out of the flight" % joined)

	# Solid, and solid as part of the BUILDING's body rather than a body of its
	# own -- the ray has to come back with the building's brick body.
	var vol := f.volume()
	var mid: Vector3 = b.xform * (vol.position + vol.size * 0.5)
	var eye := mid + Vector3(9.0, 1.0, 9.0)
	camera.global_position = eye
	camera.look_at(mid, Vector3.UP)
	await _frames(6)
	var shell: MeshInstance3D = _shells.get(0)
	if shell != null:
		shell.visible = false
	await _save("fixture_awake")

	# Stand on it. The treads are three studs wide and the figure is a little
	# under three bricks tall, so this is also the check that those agree.
	# Onto a tread, found rather than computed: only an eighth of the ring is
	# solid at any one height, so a point picked off the volume alone is as
	# likely to be the gap the next step leaves.
	var over: Vector3 = b.xform * (vol.position + Vector3(
			vol.size.x * 0.75, vol.size.y * 0.6, vol.size.z * 0.5))
	var down := PhysicsRayQueryParameters3D.create(over, over - Vector3(0.0, 6.0, 0.0))
	down.collision_mask = Layers.HITSCAN_MASK
	var found := get_world_3d().direct_space_state.intersect_ray(down)
	_gate_ok("a ray down the stairwell lands on a tread", not found.is_empty(),
			"from %v" % over)
	var tread: Vector3 = (found.position as Vector3) if not found.is_empty() else over
	camera.allow_walk = true
	camera.drive_uncaptured = true
	camera.global_position = tread + Vector3(0.0, 1.0, 0.0)
	camera.set_walking(true)
	var body := camera.body()
	var landed := 0
	while landed < 150 and (body == null or (not body.is_on_floor()
			and absf(body.velocity.y) > 0.15)):
		await _frames(1)
		landed += 1
		body = camera.body()
	await _frames(10)
	_gate_ok("a figure dropped onto the flight comes to rest on it",
			body != null and (body.is_on_floor() or absf(body.velocity.y) < 0.15),
			"on floor %s, vy %.2f" % [body.is_on_floor() if body != null else false,
					body.velocity.y if body != null else 0.0])
	_gate_ok("well above the building's floor, which means it landed on a TREAD",
			camera.global_position.y > b.xform.origin.y + 1.0,
			"%.2f m" % camera.global_position.y)
	camera.look_at(Vector3(mid.x, camera.global_position.y - 1.2, mid.z), Vector3.UP)
	await _frames(4)
	await _save("fixture_standing")
	camera.set_walking(false)
	if shell != null:
		shell.visible = true

	# Shoot it. Its bricks are the building's bricks, so they go into the
	# building's own damage record and nowhere else.
	camera.global_position = mid + Vector3(0.0, 1.0, -9.0)
	camera.look_at(mid, Vector3.UP)
	await _frames(6)
	var before := world.get_alive_block_count(chunk)
	var stairs_before := _alive_of(chunk, f.blocks)
	_blast(mid, 2.0)
	var guard := 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(20)
	_gate_ok("shooting the flight takes steps out of it",
			_alive_of(chunk, f.blocks) < stairs_before,
			"%d of %d left" % [_alive_of(chunk, f.blocks), stairs_before])
	_gate_ok("and the building is the thing that is damaged",
			registry.get_building(0).is_damaged() and world.get_alive_block_count(chunk) < before)

	# The whole point: when the building comes down, the staircase goes with it.
	var stairs_standing := _alive_of(chunk, f.blocks)
	var before_islands: int = int(islands.report().islands)
	_topple(0)
	await _frames(30)
	_gate_ok("toppling the building makes one piece of wreckage",
			int(islands.report().islands) > before_islands)
	_gate_ok("the staircase went with it -- same chunk, now an island",
			world.is_chunk_alive(chunk) and _alive_of(chunk, f.blocks) == stairs_standing,
			"%d of %d steps" % [_alive_of(chunk, f.blocks), stairs_standing])
	_gate_ok("nothing was left standing where the building was",
			not registry.get_building(0).is_materialised())
	_gate_ok("and the city never made a body for the staircase itself",
			int(world.get_memory_report().chunks) >= 1)
	await _frames(60)
	await _save("fixture_collapse")

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Rooms of one building that are holding their contents. The global count is
## not the same question once another building in view has a hole in it.
## The longest side of the widest opening a room reports, in metres.
##
## A window is 4 studs (1.4 m). Much wider than that means the scan merged
## two of them across the pier between, which is what used to make the portal
## test aim its ray at solid brickwork.
func _widest_opening(id: int, index: int) -> float:
	var widest := 0.0
	for box in registry.openings_of(id, index):
		widest = maxf(widest, maxf((box as AABB).size.x, (box as AABB).size.z))
	return widest


## Somewhere on this building that still HAS brick in it, high up.
##
## Aiming at a fixed fraction of the height was wrong twice over. The walls have
## windows in them, so a ray at an arbitrary height goes through one and out of
## the far side; and the shot that damaged this building in the first place can
## have detached everything above it, so the brick that was at 80% of the height
## is an island lying on the ground by the time the second shot is fired. Both
## read as "damage does not carry to 200 m", which is not what either of them is.
##
## So: the floor slabs, from the top down, because a slab spans the whole
## footprint and is the one band of a tower that is solid all the way across --
## and the first one whose wall cell is still solid.
func _intact_aim(id: int) -> Vector3:
	var b := registry.get_building(id)
	var cell := BrickWorld.get_cell_size()
	var stud: int = int(b.recipe.footprint_x * 0.5)
	var bands := TowerRecipe.layout(b.recipe.courses)
	for i in range(bands.size() - 1, -1, -1):
		var band: Dictionary = bands[i]
		if str(band.kind) != "slab":
			continue
		var plate: int = int(band.y)
		if b.is_materialised() and not world.is_solid(b.chunk, Vector3i(stud, plate, 0)):
			continue
		return b.xform * Vector3(stud * cell.x, plate * cell.y, 0.0)
	# Nothing left standing at any slab: aim at the middle and let the check say
	# so rather than inventing a point.
	return b.xform * (registry.local_box(id).position
			+ registry.local_box(id).size * 0.5)


## The height in metres of the floor slab nearest `fraction` of the way up a
## tower of this many courses. Somewhere to aim that is not a window.
func _slab_height(courses: int, fraction: float) -> float:
	var bands := TowerRecipe.layout(courses)
	var top := TowerRecipe.total_plates(courses)
	var want := float(top) * fraction
	var best := want
	var gap := INF
	for band in bands:
		if str(band.kind) != "slab":
			continue
		var y := float(band.y)
		if absf(y - want) < gap:
			gap = absf(y - want)
			best = y
	return best * PLATE


## How many of a building's bands actually hold a surface.
func _drawn_surfaces(id: int) -> int:
	var n := 0
	for mesh in (_brick_band_meshes.get(id, []) as Array):
		if mesh != null and (mesh as ArrayMesh).get_surface_count() > 0:
			n += 1
	return n


func _drawn_rooms_of(id: int) -> int:
	var b := registry.get_building(id)
	return b.drawn_rooms.size() if b != null else 0


## Shut every room of a building by hand, open or drawn, so the next check
## starts from nothing.
func _shut_all_rooms(id: int) -> void:
	for room in registry.rooms_of(id):
		if room.active:
			_close_room(id, room.id)
		if room.drawn:
			registry.undraw_room(id, room.id)
	_sync_drawn(id)


func _open_rooms_of(id: int) -> int:
	var n := 0
	for room in registry.rooms_of(id):
		if room.active:
			n += 1
	return n


## How many of these blocks are still alive in this chunk.
func _alive_of(chunk: int, ids: PackedInt32Array) -> int:
	var dead := {}
	for id in world.get_dead_blocks(chunk):
		dead[id] = true
	var n := 0
	for id in ids:
		if not dead.has(id):
			n += 1
	return n


# ---------------------------------------------------------------------------
# The placed-creation gate
# ---------------------------------------------------------------------------

## Is a multi-frame player build a building like any other once it is in the
## city -- cheap when nobody is near it, bricks when somebody shoots it, and
## damaged in both?
##
## Docs/BuildMode.md section 11 (the seam Stage 4 left open) and section 12
## question 3 (the cheap tier). A build used to arrive materialised and stay
## that way forever, because there was nothing cheap to draw it with.
func _run_build_pass() -> void:
	print("[build] a creation placed in the city, and what it costs when nobody is near it")
	var id := registry.buildings.size() - 1
	var b := registry.get_building(id)
	if b == null or not b.is_build():
		print("  FAIL nothing was placed -- run tools/demo_build.gd first")
		get_tree().quit(1)
		return

	_gate_ok("it is in the registry as a build", b.is_build())
	_gate_ok("with more than one frame in its recipe", b.build.frame_count() > 1,
			"%d" % b.build.frame_count())
	_gate_ok("and welds in it", b.build.weld_count() > 0)
	_gate_ok("and a staircase authored in the workshop", b.build.fixture_count() == 1)

	# The cheap tier: a shell, and no bricks anywhere in the world.
	_gate_ok("it arrives as a shell rather than as bricks", _shells.has(id))
	_gate_ok("holding no bricks at all", not b.is_materialised()
			and int(world.get_memory_report().chunks) == 0,
			"%d chunks" % int(world.get_memory_report().chunks))
	var shell_mesh: Mesh = (_shells[id] as MeshInstance3D).mesh
	var shell_tris := 0
	if shell_mesh != null and shell_mesh.get_surface_count() > 0:
		@warning_ignore("integer_division")
		shell_tris = shell_mesh.get_faces().size() / 3
	_gate_ok("with something to draw", shell_tris > 0, "%d triangles" % shell_tris)
	_gate_ok("and far fewer triangles than its bricks would be",
			shell_tris < b.build.size() * 12, "%d for %d bricks" % [shell_tris, b.build.size()])
	_gate_ok("it is solid to a shot", _shell_bodies.has(id))
	await _frames(20)

	# Look at it.
	var box := registry.local_box(id)
	var mid: Vector3 = b.xform * (box.position + box.size * 0.5)
	camera.global_position = mid + Vector3(9.0, 3.0, -9.0)
	camera.look_at(mid, Vector3.UP)
	await _frames(6)
	await _save("build_shell")

	# Shoot it: the shell gives way to bricks, frames and all.
	_fire(1.4)
	var guard := 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(40)
	_gate_ok("shooting it turns the shell into bricks", b.is_materialised())
	_gate_ok("as one chunk per frame", b.chunks().size() == b.build.frame_count(),
			"%d chunks for %d frames" % [b.chunks().size(), b.build.frame_count()])
	# The weld TABLE, not how many survived: what is alive depends on which
	# bricks the shot took, and the shot is aimed at whatever the shell put in
	# front of the camera.
	_gate_ok("the welds were rebuilt with them",
			b.asm != null and b.asm.welds.size() == b.build.weld_count(),
			"%d of %d" % [b.asm.welds.size() if b.asm != null else -1, b.build.weld_count()])
	_gate_ok("the staircase went in with the bricks",
			b.fixtures.size() == 1 and not b.fixtures[0].blocks.is_empty())
	_gate_ok("every frame past the root has a node",
			(_frame_nodes.get(id, []) as Array).size() == b.frames.size() - 1)
	_gate_ok("and the shell is gone, because the bricks are there",
			not _shells.has(id))
	_gate_ok("it is damaged", b.is_damaged())
	await _save("build_bricks")

	# Walk away: the bricks go back and the shell returns -- WITH the hole in
	# it. That is the whole point of generating it from the recipe.
	var intact_tris := shell_tris
	var chunks_with_bricks := int(world.get_memory_report().chunks)
	_demote(id, 200.0)
	_materialised.erase(id)
	await _frames(10)
	# Its own chunks, not the world's: the shot left debris, and a piece of
	# wreckage is not the build's to give back.
	_gate_ok("walking away gives the bricks back",
			not b.is_materialised() and b.chunks().is_empty())
	_gate_ok("and the world is holding fewer chunks for it",
			int(world.get_memory_report().chunks) < chunks_with_bricks,
			"%d, was %d" % [int(world.get_memory_report().chunks), chunks_with_bricks])
	_gate_ok("and puts a shell back", _shells.has(id))
	var damaged_mesh: Mesh = (_shells[id] as MeshInstance3D).mesh
	var damaged_tris := 0
	if damaged_mesh != null and damaged_mesh.get_surface_count() > 0:
		@warning_ignore("integer_division")
		damaged_tris = damaged_mesh.get_faces().size() / 3
	_gate_ok("the shell shows the hole rather than an intact silhouette",
			damaged_tris != intact_tris,
			"%d triangles against %d intact" % [damaged_tris, intact_tris])
	_gate_ok("the damage record is what it was drawn from",
			not b.dead.is_empty() or not b.dead_in(1).is_empty())
	camera.global_position = mid + Vector3(9.0, 3.0, -9.0)
	camera.look_at(mid, Vector3.UP)
	await _frames(6)
	await _save("build_shell_damaged")

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


# ---------------------------------------------------------------------------
# The walk gate
# ---------------------------------------------------------------------------

var _gate_pass := 0
var _gate_fail := 0


func _gate_ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_gate_pass += 1
		print("  ok   %s" % what)
	else:
		_gate_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## Synthesise a key the way the OS would. `Input.is_key_pressed` is what the
## camera reads, so the event has to go through the input singleton rather than
## straight to `_unhandled_input`.
func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)


## A box on the WORLD layer, for the two things the city has no natural example
## of: a kerb low enough to step over and a wall too high to.
func _test_block(centre: Vector3, size: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.collision_layer = Layers.WORLD
	sb.collision_mask = Layers.STRUCTURE_MASK
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	sb.add_child(cs)
	add_child(sb)
	sb.global_position = centre
	return sb


## Does the camera collide with the world when it is walking, and stop
## colliding when it is not?
##
## Everything here is a question the free-fly camera could not be asked at all:
## it had no body, so there was nothing for the ground, a building or a kerb to
## push against.
func _run_walk_pass() -> void:
	print("[walk] walking, flying, and what stops each of them")
	camera.allow_walk = true
	camera.drive_uncaptured = true

	# Open ground, well clear of a 22-building block 13 m apart.
	var open := Vector3(-70.0, 12.0, -70.0)
	camera.global_position = open
	camera.rotation = Vector3.ZERO
	camera.set_walking(true)
	await _frames(120)
	var body := camera.body()
	print("\nit falls to the ground and stands on it")
	_gate_ok("a body exists once walking", body != null)
	_gate_ok("it is on the floor", body != null and body.is_on_floor())
	_gate_ok("the eye is at standing height (%.2f m)" % camera.global_position.y,
			absf(camera.global_position.y - DebugCamera.EYE_HEIGHT) < 0.12)

	# A kerb, 0.3 m: lower than STEP_HEIGHT, so it is walked over.
	print("\na kerb is stepped over, a wall is not")
	var here := camera.global_position
	var kerb := _test_block(Vector3(here.x, 0.15, here.z + 3.0), Vector3(6.0, 0.3, 1.0))
	camera.look_at(Vector3(here.x, here.y, here.z + 10.0), Vector3.UP)
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	var after_kerb := camera.global_position
	_gate_ok("the kerb was crossed (z %.2f, kerb at %.2f)" % [after_kerb.z, here.z + 3.0],
			after_kerb.z > here.z + 3.5)
	_gate_ok("and it is standing on the ground beyond it",
			absf(after_kerb.y - DebugCamera.EYE_HEIGHT) < 0.2)
	kerb.queue_free()

	# A wall, 1.5 m: higher than STEP_HEIGHT, so it stops the body.
	here = camera.global_position
	var wall := _test_block(Vector3(here.x, 0.75, here.z + 2.5), Vector3(8.0, 1.5, 1.0))
	await _frames(4)
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	var at_wall := camera.global_position
	_gate_ok("the wall stopped it (z %.2f, wall face at %.2f)" % [at_wall.z, here.z + 2.0],
			at_wall.z < here.z + 2.0)
	_gate_ok("it did walk up to the wall rather than not moving at all",
			at_wall.z > here.z + 0.5)
	wall.queue_free()
	await _frames(4)

	# A real building: the shell tier's own collision, which is what a player
	# meets long before anything is made of bricks.
	print("\na building's shell is solid to a walker and not to a flier")
	var b := registry.get_building(0)
	var w: float = b.recipe.footprint_x * STUD
	var d: float = b.recipe.footprint_z * STUD
	var centre: Vector3 = b.xform.origin + Vector3(w * 0.5, 0.0, d * 0.5)
	var start := centre - Vector3(0.0, 0.0, d * 0.5 + 4.0)

	# The shell's own collision, tested from outside PROMOTE_RANGE -- which is
	# now the only place a shell survives being looked at, because walking up to
	# a building is what makes it bricks. A ray is how a shell gets hit in
	# practice anyway: FIRE_RANGE is 2 km against SHELL_RANGE's 260 m, so most
	# shots that land on a building land on one of these.
	camera.set_walking(false)
	camera.global_position = centre - Vector3(0.0, -3.0, d * 0.5 + 70.0)
	camera.look_at(Vector3(centre.x, 3.0, centre.z), Vector3.UP)
	await _frames(20)
	_gate_ok("from seventy metres it is a shell and nothing else",
			_shells.has(0) and not b.is_materialised())
	var shell_q := PhysicsRayQueryParameters3D.create(
			camera.global_position, Vector3(centre.x, 3.0, centre.z))
	shell_q.collision_mask = Layers.PAWN_MASK
	_gate_ok("and it is solid to the thing a walker collides with",
			not get_world_3d().direct_space_state.intersect_ray(shell_q).is_empty())

	camera.set_walking(false)
	camera.global_position = start + Vector3(0.0, DebugCamera.EYE_HEIGHT, 0.0)
	camera.look_at(Vector3(centre.x, camera.global_position.y, centre.z), Vector3.UP)
	camera.set_walking(true)
	await _frames(60)
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(10)
	var walked := camera.global_position
	_gate_ok("walking stops outside the wall (z %.2f, wall at %.2f)" % [
			walked.z, centre.z - d * 0.5],
			walked.z < centre.z - d * 0.5)
	# And what stopped it is the brick tier, not the shell: standing four metres
	# from a wall is inside PROMOTE_RANGE, so by the time the walker arrives the
	# building it walked up to is made of bricks. That is the whole point of the
	# range -- the interior has to exist before anybody shoots a hole in it.
	_gate_ok("and walking up to it made it bricks, with nobody firing",
			b.is_materialised() and not b.is_damaged())
	_gate_ok("so the shell that used to stop the walker is gone", not _shells.has(0))

	camera.set_walking(false)
	camera.global_position = start + Vector3(0.0, DebugCamera.EYE_HEIGHT, 0.0)
	camera.look_at(Vector3(centre.x, camera.global_position.y, centre.z), Vector3.UP)
	_key(KEY_W, true)
	await _frames(60)
	_key(KEY_W, false)
	await _frames(4)
	var flown := camera.global_position
	_gate_ok("flying goes straight through it (z %.2f)" % flown.z, flown.z > centre.z - d * 0.5)

	# The toggle itself. Two taps inside DOUBLE_TAP_MS swap modes; two taps
	# further apart than that are two jumps.
	# The reported bug: a figure that walks under a beam from a tile floor is
	# stopped dead by the same beam when it is standing on a brick. Two plates of
	# floor is the whole difference, and there was no way to duck.
	print("\na brick floor costs headroom, and ducking gets it back")
	camera.set_walking(false)
	var room := Vector3(open.x + 30.0, 0.0, open.z)
	# A beam with 1.40 m under it: clear standing from the ground, not clear
	# standing on one brick course.
	var beam := _test_block(room + Vector3(0.0, 1.5, 0.0), Vector3(6.0, 0.2, 1.2))
	camera.global_position = room + Vector3(0.0, DebugCamera.EYE_HEIGHT, -4.0)
	camera.look_at(Vector3(room.x, DebugCamera.EYE_HEIGHT, room.z + 6.0), Vector3.UP)
	camera.set_walking(true)
	await _frames(40)
	_key(KEY_W, true)
	await _frames(150)
	_key(KEY_W, false)
	await _frames(6)
	_gate_ok("from the ground it walks under the beam standing",
			camera.global_position.z > room.z + 1.0 and not camera.is_crouched(),
			"z %.2f of %.2f, crouched %s" % [
				camera.global_position.z, room.z + 1.0, camera.is_crouched()])

	# The same beam, with one brick course of floor under it.
	var ledge := _test_block(room + Vector3(0.0, PLATE * 1.5, 0.0), Vector3(6.0, PLATE * 3.0, 6.0))
	camera.set_walking(false)
	camera.global_position = room + Vector3(0.0, DebugCamera.EYE_HEIGHT, -5.0)
	camera.look_at(Vector3(room.x, DebugCamera.EYE_HEIGHT, room.z + 6.0), Vector3.UP)
	camera.set_walking(true)
	await _frames(40)
	var ducked := false
	_key(KEY_W, true)
	for i in 240:
		await _frames(1)
		ducked = ducked or camera.is_auto_crouched()
	_key(KEY_W, false)
	await _frames(6)
	_gate_ok("standing on a brick it ducks under the same beam", ducked)
	_gate_ok("and gets past it rather than stopping dead",
			camera.global_position.z > room.z + 1.0,
			"z %.2f of %.2f" % [camera.global_position.z, room.z + 1.0])
	_gate_ok("on top of the brick course, not in front of it",
			camera.global_position.y > room.y + 0.8, "%.2f m" % camera.global_position.y)
	beam.queue_free()
	await _frames(20)
	_key(KEY_W, true)
	await _frames(30)
	_key(KEY_W, false)
	await _frames(10)
	_gate_ok("and stands up again once the beam is behind it", not camera.is_crouched())
	ledge.queue_free()
	await _frames(4)

	print("\nSPACE twice swaps the mode, SPACE once does not")
	camera.global_position = open
	camera.set_walking(false)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(2)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(4)
	_gate_ok("a double tap started walking", camera.is_walking())
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(2)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(4)
	_gate_ok("a second double tap went back to flying", not camera.is_walking())
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(40)   # 40 frames at 60 fps is well past DOUBLE_TAP_MS
	_gate_ok("a single tap left it flying", not camera.is_walking())

	# And the tool that used to be on SPACE is not on it any more.
	print("\nSPACE no longer fires")
	camera.global_position = start + Vector3(0.0, DebugCamera.EYE_HEIGHT, 0.0)
	camera.look_at(Vector3(centre.x, camera.global_position.y, centre.z), Vector3.UP)
	await _frames(4)
	var damaged_before: bool = registry.get_building(0).is_damaged()
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(20)
	_gate_ok("nothing was destroyed by it",
			registry.get_building(0).is_damaged() == damaged_before)

	print("\nthe wheel sets how big the next hole is")
	var was := _blast_radius
	_set_blast_radius(_blast_radius * BLAST_STEP)
	_gate_ok("a notch up is bigger", _blast_radius > was)
	_set_blast_radius(1000.0)
	_gate_ok("and it is clamped at %.1f m" % BLAST_MAX, is_equal_approx(_blast_radius, BLAST_MAX))
	_set_blast_radius(0.0)
	_gate_ok("and at %.1f m" % BLAST_MIN, is_equal_approx(_blast_radius, BLAST_MIN))

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit()


## How many collision shapes the scene is actually holding, and where.
##
## One box per brick is what a large body costs the solver, and the only honest
## way to decide whether to merge anything is to know who is carrying the boxes
## -- the standing buildings, the pieces still falling, or the settled wreckage
## that already merges.
func _collision_report() -> String:
	var building_shapes := 0
	var building_blocks := 0
	for id in _materialised:
		if _brick_bodies.has(id):
			building_shapes += PhysicsServer3D.body_get_shape_count(_brick_bodies[id])
		var b := registry.get_building(id)
		if b != null and b.is_materialised():
			building_blocks += world.get_alive_block_count(b.chunk)
	var falling := 0
	var settled_boxes := 0
	for isl in islands.islands:
		if not isl.is_valid():
			continue
		if isl.settled:
			settled_boxes += isl.shape_count
		else:
			falling += isl.shape_count
	# The furniture bodies are separate from the buildings' own (see _room_body),
	# so they are counted separately or the census quietly stops adding up.
	var furniture := 0
	for fid in _room_bodies:
		furniture += PhysicsServer3D.body_get_shape_count(_room_bodies[fid])
	return ("%d box(es) in %d standing building(s) (%d bricks), %d on open room contents, "
			+ "%d in pieces still falling, "
			+ "%d in settled wreckage; buildings merged %d time(s) (%.1f ms total, worst %.1f) "
			+ "and un-merged %d (%.1f ms); "
			+ "islands merged %d time(s), %d boxes against %d unmerged") % [
			building_shapes, _materialised.size(), building_blocks, furniture,
			falling, settled_boxes,
			_merges, _merge_ms, _merge_worst, _unmerges, _unmerge_ms,
			islands.merged_shapes, islands.merged_boxes, islands.unmerged_boxes]


func _report_phases() -> void:
	# `name` is a Node property, so it cannot be a loop variable here.
	for phase_name in _phases:
		var ph: Dictionary = _phases[phase_name]
		if int(ph.n) == 0:
			continue
		print("[stress] %-22s mean %6.1f ms (%5.1f physics) worst %6.1f  %5.1f fps  %d of %d over 33.3" % [
				phase_name, float(ph.sum) / int(ph.n),
				float(ph.get("phys", 0.0)) / int(ph.n), float(ph.worst),
				1000.0 / maxf(float(ph.sum) / int(ph.n), 0.001),
				int(ph.over), int(ph.n)])


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


func _save(shot_name: String) -> void:
	var was := _sampling
	_sampling = false
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/%s.png" % shot_name)
	print("[city] shot written: %s.png" % shot_name)
	await RenderingServer.frame_post_draw
	_sampling = was


# ---------------------------------------------------------------------------

func _build_scenery() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.55, 0.78)
	sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.83)
	sky_mat.ground_bottom_color = Color(0.30, 0.31, 0.29)
	sky_mat.ground_horizon_color = Color(0.72, 0.78, 0.83)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	ground.collision_mask = Layers.STRUCTURE_MASK
	var gcs := CollisionShape3D.new()
	gcs.shape = WorldBoundaryShape3D.new()
	ground.add_child(gcs)
	var gmesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(800, 800)
	gmesh.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.34, 0.35, 0.33)
	gmat.roughness = 1.0
	gmesh.material_override = gmat
	ground.add_child(gmesh)
	add_child(ground)

	brick_material = ShaderMaterial.new()
	brick_material.shader = load("res://shaders/brick.gdshader")
	for key in _shader_toggles:
		brick_material.set_shader_parameter(key, _shader_toggles[key])

	camera = DebugCamera.new()
	camera.name = "DebugCamera"
	# Every scripted pass drives the camera itself. Leaving the debug camera
	# captured let it keep applying its own movement and mouse-look on top,
	# which is why the reach probe reported misses at 40 m.
	camera.capture_mouse = not (_shot_mode or _stress_mode or _reach_mode or _lod_mode
			or _walk_mode or _build_mode or _fixture_mode or _dormant_mode
			or _rooms_mode or _chamfer_mode or _interiors_mode or _audit_mode
			or _windows_mode)
	# A scripted pass puts the camera where it wants it and must not be able to
	# fall out of the sky halfway through a capture.
	camera.allow_walk = camera.capture_mouse
	camera.far = 3000.0
	# Outside the corner of the city, looking in along the diagonal. Scaled by
	# the spacing, because --big puts 84 m towers on a 46 m pitch and the fixed
	# position that was fine for a 13 m one starts INSIDE a building.
	var stand: float = 52.0 * (BIG_SPACING / 13.0 if _big else 1.0)
	camera.position = Vector3(-stand, stand * 0.65, -stand)
	camera.rotation = Vector3(-0.42, -2.36, 0.0)
	add_child(camera)
	camera.mode_changed.connect(func(_walking: bool) -> void: _update_hud())

	var layer := CanvasLayer.new()
	stats_label = Label.new()
	stats_label.position = Vector2(14, 12)
	stats_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	stats_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	stats_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(stats_label)

	# The live profiler, top right, off until F2. Monospace, because a column
	# of numbers that will not line up is a column of numbers nobody reads.
	_live_label = Label.new()
	_live_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_live_label.position = Vector2(-430, 12)
	_live_label.add_theme_font_override("font", ThemeDB.fallback_font)
	_live_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.62))
	_live_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_live_label.add_theme_constant_override("outline_size", 4)
	_live_label.visible = false
	layer.add_child(_live_label)

	_reticle = Reticle.new()
	_reticle.set_anchors_preset(Control.PRESET_FULL_RECT)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A capture pass is a picture of the city, not of the aiming UI.
	_reticle.visible = camera.capture_mouse
	layer.add_child(_reticle)
	add_child(layer)
