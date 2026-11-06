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
##       V on foot · K a soldier · U a squad (advances on you when on foot)
##       On foot it plays as an FPS (PlayerController): WASD · SHIFT sprint ·
##       SPACE jump / climb · C slide · Q grapple · RMB aim · LMB fire · R reload
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
## `--big` also has wide, low buildings past the far edge of the grid: two to
## four floors of ordinary rooms, 42-84 m long (user, 2026-10-16: "a couple wide
## building of varying lengths and height"). Everything here was made with
## towers in mind -- bands that are slices across the whole building, a load
## check over a whole storey at once -- and these are what a big floor plan
## does to it (Docs/CollapseNext.md item 25). Rows of the grid beyond its last,
## packed along x with WIDE_GAP_STUDS between; the grid's own buildings keep
## their places and their ids. `--no-wide` leaves them out, for numbers that
## compare with the big city before them.
const WIDE_SHAPES := [
	[{"x": 240, "z": 50, "courses": 12}, {"x": 160, "z": 60, "courses": 18}],
	[{"x": 200, "z": 80, "courses": 24}, {"x": 120, "z": 40, "courses": 12}],
]
const WIDE_GAP_STUDS := 40
## What each building's rooms are for (Docs/Workshop.md, Stage F). A shape row
## may carry its own "program"; otherwise, with `--programs` (or the export
## below), buildings take these mixes in turn. Off by default: with no
## program a building draws the four kinds it always has, and every
## measurement taken of the city stays comparable.
const PROGRAMS := [
	{"office": 4, "storeroom": 1, "kitchen": 1},          # office block
	{"bedroom": 3, "living": 2, "kitchen": 1, "bathroom": 1},   # apartments
	{"shop": 2, "storeroom": 2, "office": 1},             # shops, stock above
	{"lab": 3, "office": 2, "storeroom": 1},              # labs
]
@export var room_programs := false


## The room mix for building `index` of this shape: its own, a rotation
## through PROGRAMS, or none.
func _program_for(shape: Dictionary, index: int) -> Dictionary:
	if shape.has("program"):
		return shape.program
	if room_programs or "--programs" in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		return PROGRAMS[index % PROGRAMS.size()]
	return {}


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
## The brick budget (Docs/Space.md 5.3): how many bricks of buildings may be in
## play at once. Over it, the quietest storeys furthest from everybody are given
## back to their rest shells -- a building laid whole goes back whole -- until
## it is not (_trim_budget). `--brick-budget=` overrides it. The first guess the
## doc made, to be set by a gate.
@export var brick_budget := 150000
## The city on the terrain field rather than the flat plane (`--terrain`), set in
## a scene so it can be opened and played.
@export var terrain_ground := false
## The combat arena (WaveDirector, scenes/combat_arena.tscn): the player's pawn
## and waves of soldiers in and round one building. `--arena` does the same.
@export var combat_arena := false
## Firefight (FirefightDirector, scenes/firefight.tscn): waves of soldiers in a
## walled-in ring of the city, in rounds and sets, with lives and a score.
## `--firefight` does the same.
@export var firefight := false
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
var _big := false
var _wide := false   ## the big city's wide buildings (WIDE_SHAPES)
var _wide_ids := {}  ## their building ids
## Metres between buildings. Big ones need more, or they start inside each
## other -- the shapes above are up to 28 m across against a 13 m pitch.
const BIG_SPACING := 46.0
## The narrowest street between two buildings' footprints, in studs: what the
## small city had at 13 m before its footprints grew (3.2 m).
const STREET_STUDS := 9

var world: BrickWorld
var registry: BuildingRegistry
var islands: IslandManager
## The near tier of everything drawn in bricks here -- buildings' bands, a
## build's other frames, loose pieces: chamfered meshes and stud geometry
## close to the camera (BrickNear).
var brick_near: BrickNear
## How a building comes apart: breakage or collapse, and a mega building's
## collapse in a few big chunks (CollapseDirector).
var director: CollapseDirector
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
## F6: furniture and items from the catalogue, into rooms, builds or outdoors
## (Docs/AssetWorkshop.md, "Furniture and items").
var _furnisher: WorldFurnisher
var _props: OutdoorProps
## Hit marks, debris and sounds by material, and footsteps (material_fx.gd).
var _material_fx: MaterialFx
## Natural disasters (Docs/Disasters.md), in every city.
var disasters: DisasterDirector

## Per building: the shell it shows while undamaged, and the bricks once it is not.
var _shells := {}          ## building id -> MeshInstance3D
## Buildings still in bricks, their mesh given up at range, hit since their
## shell was made: rebuilt from their bricks by _stream_detail.
var _shell_stale := {}
var _shell_bodies := {}    ## building id -> RID
var _brick_nodes := {}     ## building id -> MeshInstance3D
## The light on the brick grid (Docs/Lighting.md 6.1): the nearest buildings
## in bricks, shut rooms dark and blown walls letting the sky in.
var grid_light := BrickGridLight.new()
var _grid_at := 0
## chunk id -> the MultiMeshInstance3D drawing that chunk's interiors, parented
## to the building's own mesh so it inherits the chunk's transform.
var _furniture := {}
## building id -> the static body its open rooms' furniture collides on, and
## that body's block -> shape indices. See _room_body.
var _room_bodies := {}
var _room_shapes := {}
## Buildings that have had a room laid in them. See _refresh_furniture.
var _furnished := {}
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
## And across: a section is a TILE of this many studs square on plan, not a
## band across the whole building (Docs/Structures.md 2.2) -- so a hit on a
## 240 x 80 building rebuilds the tile it landed in, not the whole of that
## floor. The load check's region is the same width (GRAVITY_REGION). A tower
## no wider than this is one tile a layer, as it was a band.
const SECTION_STUDS := 32
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
## frame's problem. A count of 2 was for bands across the whole building; a
## tile (SECTION_STUDS) is a sixth of the big tower's band, and at 2 a tick its
## 96 tiles kept the shell up -- and the solve waiting -- 40 ticks after a hit
## (--breaklag --big). The time and the vertices below are what bound a tick.
const BANDS_PER_TICK := 12
const BAND_BUDGET_MS := 6.0
## And how many vertices of band meshes may be handed over in one tick. A mesh
## built on a worker is not free on this thread: the worker packs the arrays,
## but the renderer creates the buffers on the main thread, at the next call
## into it -- measured on a 62,000-vertex mesh, 3-4 ms built here against 1-1.5
## attached from a worker. So what the workers finish in one tick is paid in
## one tick, and this keeps that bounded. Lower than a piece's
## (IslandManager.UPLOAD_VERTS_PER_TICK): a band waiting still draws its old
## mesh, and a piece waiting draws nothing.
const BAND_VERTS_PER_TICK := 60000
## A band with at least this many vertices is uploaded on a worker, as a big
## piece's mesh is (IslandManager.THREAD_MESH_VERTS). Of what a band cost,
## four fifths was handing the arrays to the renderer -- 98 ms of 120 across a
## stress pass, a band of a big tower 3-7 ms, two a tick -- and the arrays
## themselves come out of the bake in a fraction of a millisecond. About two
## thirds of the handing-over moves to the worker (BAND_VERTS_PER_TICK says
## where the rest goes). The band's old mesh goes on drawing until the new one
## is attached, and a band waits behind a piece for a worker, since a piece
## without a mesh is a hole and a band without a new one is not.
## Now every band (2026-10-23): it was 4,000 vertices, and a band under it,
## a few hundred vertices, took 6-13 ms in the tick on a street walk -- handing
## arrays to the renderer here waits for whatever a worker is uploading, and
## something nearly always is (bands, pieces, the near tier, terrain, glass).
## It was the biggest part of most of the walk's long frames (PerfCaps.md 4).
const BAND_THREAD_VERTS := 0
## Headless, the renderer is the dummy one, and its meshes are not safe to make
## on two threads at once: a band made on a worker while the main thread made
## another mesh broke its RIDs ("Initializing already initialized RID") and
## the probe after it. There, meshes are made on the main thread as before --
## nothing is drawn, so nothing waits -- and big bands still go to a worker
## as they always did.
static var worker_meshes := DisplayServer.get_name() != "headless"
const BAND_THREAD_VERTS_HEADLESS := 4000
## Bands being uploaded: [building id, band, task id, [mesh], arrays, pass].
var _band_jobs: Array = []
var _band_verts_now := 0
## A mesh with nothing in it, to ask the renderer something cheap. See
## _physics_process.
var _flush_mesh := ArrayMesh.new()
## The renderer is on this thread (the default thread model). With it on a
## thread of its own (--render-thread separate) a renderer getter waits for it
## to catch up, so the tick's flush below is skipped and the walk reads its
## render times every RENDER_SAMPLE_EVERY frames (Docs/WhereWorkRuns.md 3.1 c).
var _one_thread := RenderingServer.is_on_render_thread()
## building id -> which rebuild of its bands is current. A job from an older
## pass is thrown away when it lands, not attached over a newer band.
var _band_pass := {}
var band_jobs_done := 0
var _brick_bands := {}
var _brick_band_meshes := {}
var _brick_band_bytes := {}
var _brick_meshes := {}    ## building id -> the ArrayMesh whose indices we patch
## Meshes the renderer may still be holding. See MeshRetirer.
var _retirer := MeshRetirer.new()
var _brick_index_bytes := {}  ## building id -> that surface's index buffer length
var _brick_index_width := {} ## building id -> 2 or 4, that surface's index width
## building id -> its collision, a static body a band (BuildingCollision).
var _brick_cols := {}
## How a building's collision is merged down, and when each was last hit.
##
## A standing building carries ONE BOX PER BRICK, and measured on the
## 200-building stress pass that is 112,321 boxes across 37 buildings against
## 1,827 in all the settled wreckage put together -- the wreckage already merges
## and the buildings did not. So they merge too, on the same rule that works
## for a settled piece: **once it has stopped**.
##
## It used to merge only once the shooting had moved on, because a hit had to
## un-merge it again -- two whole-building shape builds for one. With a body a
## band (BuildingCollision) a hit does not un-merge anything: the band it took
## bricks out of is merged again without them at the end of the tick, which is
## cheaper than the box-a-brick band it would otherwise switch them off in. So
## a building is merged from promotion on.
##
## _merge_quiet_buildings is what is left of the old rule: it merges any band
## still a box a brick (none, unless MERGE_SHAPES is off), one a tick, once the
## building has been quiet MERGE_AFTER_MS.
var _last_hit := {}
## How long a building has to have been quiet, and how many bands may be
## merged in one tick. A merge is one `add_chunk_shapes` over the band.
const MERGE_AFTER_MS := 10000
const MERGES_PER_TICK := 1
## The experiment's other arm: rebuild the body exactly as a merge does, but
## per block. If the cost is the same either way, it is the REBUILD and not the
## merged geometry.
const MERGE_SHAPES := true
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
##
## And then lowered, from 46 to 28: a building is bricks when somebody could be
## at its door in a few seconds, not whenever they are in the same block. Every
## building in a 46 m radius was a full promotion -- up to 60 ms for the big
## city's tallest -- plus its bake and its body, for rooms the window shader
## already fakes from outside (BuildingShell's panes). What is given up is the
## band between 28 and 46 m where real rooms could be drawn through real
## openings; a shell's windows show a room there instead.
const PROMOTE_RANGE := 28.0
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
##
## Two does more than bound the cost. What a cascade's first solves let go in
## small groups, and is not cut out this tick, is solved again with the next --
## by when it has come loose together, and leaves as one piece. At eight a tick
## the same collapses came down in 14-30 pieces where they had been 3, and a far
## one in 9 where it had been 1 (collapse_probe). What two a tick did get wrong
## was the order: the building's body came last and hung in the air for 13
## ticks (--breaklag) -- the director hands it over first now.
const SPAWNS_PER_TICK := 2
## Groups small enough to be crumbs (IslandManager._crumble) are cut out on a
## count of their own: no body, a fraction of a millisecond each, and two a
## tick of them held up whatever came after (CollapseDirector.plan).
const CRUMBS_CUT_PER_TICK := 24
## How many building bands may be merged again in one tick
## (BuildingCollision.flush). ~0.45 ms each on a mega tower, and one chunk cut
## out of one can leave fifteen stale: the rest are parked out of the space and
## merged over the next ticks.
const FLUSH_BANDS_PER_TICK := 6
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
## A building's cascade runs to its end in the tick it starts, as far as this
## allows (BrickWorld.solve_structure's rounds): a joint failing puts its load
## on the next, which the next solve fails, and at one solve a tick the top of
## a tower with its storey blown out hung for half a second while its last
## walls gave way a generation at a time (--breaklag --big). Rounds are cheap
## -- a stress solve, no Dictionary -- and the clock is per building.
const CASCADE_ROUNDS := 48
const CASCADE_BUDGET_MS := 3.0
##
## A count, not a clock like spawns. A solve put off to the next tick meets more
## damage: on the big city a 6 ms budget turned towers that toppled as
## 6,000-brick sections into one 21,000-brick piece and doubled the mean frame.
## Four big solves are affordable because the solve got cheaper instead
## (BrickWorld.solve_structure: a 23,000-brick tower in 4 ms, not 15).
const TRIM_AFTER_MS := 12000
## From 90: promotion comes in at PROMOTE_RANGE (28 m from the box) now, and a
## building's origin is at most ~20 m inside its box, so 70 m from the origin is
## still well clear of anything the trim could take back straight away.
const TRIM_RADIUS := 70.0
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
## And no second building started after this much of a run.
const TRIM_START_MS := 2.0
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
## Past this, a shell pass makes no more shells (one at least; _stream_shells).
const SHELL_BUDGET_MS := 2.0
var _promote_queue: Array[int] = []
## building id -> the storeys its queued promotion asks for (Docs/Space.md
## 5.3a): what was aimed at, walked up to or about to be landed on. Absent, or
## storey units off: the whole building.
var _promote_storeys := {}
## How far round an aimed-at point, and round the camera on a walk-up, the
## storeys are made bricks: a storey is 2.8 m, so this is the one looked at or
## stood in and its neighbour on the near side.
const AIM_STOREY_REACH := 1.0
var _remesh_queue: Array[int] = []
## Buildings fire has charred -> the physics frame their bands are rebuilt on
## (scorch). A colour is in the vertices, which an index patch never touches,
## so it takes a full rebuild; RECOLOUR_TICKS gathers a fire's scorches into one.
var _recolour := {}
const RECOLOUR_TICKS := 15
## Materialised, collidable, still drawn by its shell: waiting on a worker to
## finish baking its faces.
var _pending_bricks: Array[int] = []
## building id -> process frame before which its remesh must wait.
var _remesh_hold := {}
## Hand-overs in flight (Docs/Collapse.md 2.4): building id -> {pieces, born,
## gap, double}. A piece leaving a building has to start drawing its bricks the
## same frame the building stops. GAP: a tick the building no longer draws them
## and a piece that took them draws nothing -- the flicker. DOUBLE: a tick the
## pieces all draw and the building still draws them too -- a section seen
## falling and still standing.
var _handovers := {}
const HANDOVERS_PER_TICK := 3
const HANDOVER_MAX_FRAMES := 20
var handover_stats := {"count": 0, "gap_ticks": 0, "gap_worst": 0, "gap_handovers": 0,
		"double_ticks": 0, "double_worst": 0, "double_handovers": 0,
		"double_queued": 0, "double_bands": 0}
var _demesh_ms := 0.0
var _demeshed := 0
var _remeshed_back := 0
var _trim_split := {"demat": 0.0, "free": 0.0, "shell": 0.0}
var _demote_worst := [0.0, 0.0, 0.0, 0.0, 0]
var _trim_ms := 0.0
var _trims := 0
var _damage_queue: Array = []
var _pending_disable := {}
## Solves of mega buildings [count, ms], and the worst single solve
## [ms, blocks, groups, collapsing].
var _solve_mega := [0, 0.0]
var _held_groups := 0      ## groups put back as held (Block::held), all told
var _resolves_put_off := 0 ## solves of a building already solved that tick, left for the next
var _cascade_rounds := 0   ## stress rounds that failed something, all told
var _cascade_worst := 0    ## the most in one solve
var _solve_worst := [0.0, 0, 0, false]
var _solve_batches := 0
## Buildings whose next solve is running on a worker (_start_solves), id ->
## chunk, and how those went: [taken, stale (solved again in the tick),
## dropped (the building was no longer waiting to be solved)].
var _solving := {}
var _solve_async := [0, 0, 0]
var _solve_batch_worst := 0.0
## Buildings whose furniture has to be redrawn at the end of the tick.
var _furniture_due := {}
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
var _show_grids := false
var _grid_count := 0
var _grid_view: MeshInstance3D
## What the physics sees (Shift+G): band boxes, pieces' shapes and centres of
## mass by sleep state (PhysicsView, Docs/Hulls.md 11 E1). Made on first use.
var _physics_view: PhysicsView
## How wide the next shot hits, in metres. The wheel sets it; the reticle draws
## it at the range it is actually pointing at, because a radius in metres means
## nothing to the eye until it is a circle over the wall it is about to remove.
## How near the player has to be for a storey group's pieces to have their
## collision boxes (_stream_groups), how far before they lose them, and how
## many storeys either side of the player's own still count. The first is also
## what "near enough to see" a blast's furniture means (_apply_blast).
const ROOM_RANGE := 40.0
const ROOM_SLEEP_RANGE := 58.0
const ROOM_STOREY_SPAN := 1

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
var _shell_far := {}       ## building id -> a shell past SHELL_RANGE, drawn with no body
var _stream_cursor := 0
var _shells_made := 0
var _shells_freed := 0
var _shells_swapped := 0

var _shot_mode := false
## Frame-cost measurement, the same reading `heightfield_test -- --bench`
## takes, so the city and the terrain can be compared on one scale.
var _bench_mode := false
## `--bench --with-bricks`: let the viewpoints promote what is beside them, to
## measure what brick buildings cost (the shadow pass, section 7.2).
var _bench_bricks := false

## THE CITY ON GROUND. `-- --terrain`.
##
## Off by default. Every measurement, probe and capture this scene has ever
## taken was taken against a flat grey plane at y=0, and a hill under a
## collapse test is a variable nobody asked for.
##
## On, the plane goes and the city stands on the heightfield. Each building
## stamps a PAD into the field BEFORE any ground is built, so the terrain is
## flat exactly where a building needs it and rolls everywhere else
## (Docs/Terrain.md §19.12) — the generator is told first rather than the
## ground being flattened afterwards, which is the whole point of authored
## pads. The building's floor is then read back out of the field, so the two
## cannot disagree.
var _terrain_mode := false
## How far the coarse tier reaches, in tiles. 40 is 448 m — about the grey
## plane it replaces, and far enough that the city has a horizon.
const TERRAIN_REACH_TILES := 40
## Which world the city is cut into. Its own, not the heightfield scene's:
## that seed was chosen for a landscape to look at, this one for ground a
## city can stand on.
const TERRAIN_SEED := 20260921
var _terrain_streamer: TerrainStreamer = null
## The same streamer under the name the terrain dev menu reads (a host whose
## detail square follows the camera: terrain_dev_menu.gd's header).
@warning_ignore("unused_private_class_variable")
var _streamer: TerrainStreamer:
	get:
		return _terrain_streamer
## Full-detail tiles either side of the camera, and the hysteresis past it:
## the heightfield test's NEAR_TILES, so every scene on terrain streams the
## same ground the same way (Docs/Terrain.md §22.18).
const TERRAIN_NEAR_TILES := 4
# Preloaded rather than named: a brand new `class_name` is not in the global
# class cache until the editor has scanned for it, and a headless run of this
# scene must not depend on that having happened.
const TerrainCoarseScript := preload("res://scripts/terrain_coarse.gd")
var _terrain_coarse: TerrainCoarseScript = null
var _terrain_mat: ShaderMaterial = null
## Kept so terrain mode can drop it, and so the baked sun shadow can be taken
## from the light that actually shines rather than from a constant.
var _ground_plane: StaticBody3D = null
var _sun: DirectionalLight3D = null
## The world the city is cut into: seed, sea and the SITES its buildings stand
## on (Docs/Terrain.md §21.5). `worlds/city.json`, or `big_city.json` with
## --big; `-- --world=<name>` picks another. A missing file is the street grid.
const TerrainWorldScript := preload("res://scripts/terrain_world.gd")
const WaterSeaScript := preload("res://scripts/water_sea.gd")
## How much of the ground round the city is under water (TerrainWorld's
## drowned fraction), for a city with no world file yet. A fifth puts the sea
## at 10.3 m on this seed: the default city (ground 12.5 m and up) stays dry,
## and the big one, which reaches down to -13 m, has a shore.
const CITY_DROWNED := 0.20
var _terrain_world_path := ""
var _terrain_drowned := CITY_DROWNED
var _sea = null
## `--buildings=` was on the command line. With a world file the SITES decide
## how many buildings there are, and this caps them only when asked to.
var _buildings_arg := false
## The buildings stood on the world's SITES: what the flush-with-the-ground
## gate checks. The registry also holds trees and small items now, which are
## not on pads and are not the gate's business.
var _site_ids: Array[int] = []
var _stress_mode := false
## `--agents` with --stress: the P8 population in the city while it comes down.
var _agents_mode := false
## Many at once (AIPlan P8): who is smart, the swarm, and whom they are after.
var budget: ImportanceBudget
var swarm: SwarmSide
var _next_swarm_refresh := 0.0
var _reach_mode := false
var _far_mode := false
var _tree_mode := false
var _lod_mode := false
var _walk_mode := false
var _no_fixtures := false
var _build_mode := false
var _fixture_mode := false
var _dormant_mode := false
var _windows_mode := false
var _light_mode := false
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
## V puts a player pawn where the camera is and hands it the controls and the
## gun; V again leaves it. The debug walker (SPACE SPACE) stays a debug tool.
var _player := PlayerController.new()
var _player_pawn: Pawn
var _play_mode := false
## --arms: the first-person arms and hands (ViewArms), with pictures.
var _arms_mode := false
## `--asset-gun=<id>`: the asset gun pass with that gun (one exported from the asset workshop).
var _asset_gun := &""
## On foot it is an FPS: the gun in the hands, the view's feel, its HUD
## (PlayerView, PlayerHud); the debug stats and blast reticle are put away.
var _view: PlayerView
## The player's kit round the pawn -- HUD, arsenal, aim assist, hit feedback,
## callouts, aggro meter -- the same one the planet has (PlayerKit). Made the
## first time a pawn is entered.
var _kit: PlayerKit
## The player's guns in play: two groups of two, ordnance, grenades, the floor and
## the backpack (PlayerArsenal; COMBAT_DESIGN 7). The kit's, kept here by name.
var _arsenal: PlayerArsenal
## Loot rolls: their own stream, so a drop never moves the gun's or the fight's.
## The kit's arsenal fills its default kit from it too (seeded when it is made).
var _loot_rng := RandomNumberGenerator.new()
var _stats_were_visible := false
## M boards a mech (spawning one ahead of the camera if there is none) and M
## again climbs out; the mech stays where it was parked.
var _pilot := MechPilot.new()
var _mech: Mech
## Tanks (AIRoster.md RO10): Z puts an enemy one ahead with a squad screening it,
## SHIFT+Z an empty one of ours; CTRL+Z an empty truck of ours, CTRL+SHIFT+Z an
## enemy truck with a squad in the back, coming for the player. M beside a
## vehicle gets in at the wheel, or on its deck when somebody else drives it;
## E beside an enemy's climbs on a tank or takes a truck's cab (Halo's
## boarding; Docs/AIVehicles.md 4).
var tanks: Array[Tank] = []
## The trucks spawned here; the arena's are its own. All of them are in the
## "trucks" group, which is what M and E look through.
var trucks: Array[TransportTruck] = []
var _vehicle_pilot := VehiclePilot.new()
## When the player's side next looks for soldiers to hop on the player's vehicle.
var _hop_in_at := 0.0
## Friendly soldiers this near the player's vehicle, stopped, hop on its deck.
const HOP_IN_RANGE := 15.0
## What a tank's lost damage zone means, for the log (Tank, VehicleBricks).
const ZONE_LOST_LINES := {&"engine": "engine destroyed -- it will not drive, and the turret turns by hand",
		&"track_l": "left track thrown -- it can only turn", &"track_r": "right track thrown -- it can only turn",
		&"turret": "turret jammed", &"gun": "cannon shot off -- the machine gun still works",
		&"ammo": "AMMO RACK HIT -- it cooks off"}
const TRUCK_ZONE_LOST_LINES := {&"engine": "engine shot out -- it will not drive",
		&"wheels": "wheels shot off -- half speed", &"gun": "its gun shot off"}
## Weight on bricks (Docs/AI.md 3.10, AIPlan P7): the host looks up what each
## pawn and mech stands on and commits LOAD / UNLOAD where it can matter.
var weight: WeightTracker
## The mech map (AIPlan R8): an AINav with a mech's footprint, height and step.
var mech_nav: AINav
## Every mech with a brain: the player's (its brain off while piloted) and the
## enemy's (Y).
var mech_brains: Array[MechBrain] = []
## The player's one button to their mech (F, on foot; AI.md 2.1, A4).
var _mech_cmd: MechCommand
## The player got into the mech on foot, and gets out on foot (_leave_mech).
var _boarded_on_foot := false
var _chunk_owner := {}
var _chunk_not_owned := {}   ## chunk -> registry.materialise_count() when it was no building's
## Mechs with no brain and no pilot (the --mechfall gate's).
var _loose_mechs: Array[Mech] = []
var _mech_mode := false
## --vehicles: the player's vehicles by their keys (_run_vehicles_pass).
var _vehicles_mode := false
## The AI's view of the city (Docs/AIPlan.md P2): what stands between two points,
## how long cover lasts, where not to stand. Synced once a tick; it reads the
## bricks and never changes them.
var ai_world := AIWorld.new()
## The AI's one budget, and the arbiter that shares the frame with destruction:
## fed this script's own tick time, it steps the AI down during a collapse.
var ai_sched := AIScheduler.new()
var _ai_label: Label
var _ai_sync_ms := 0.0
var _ai_run_ms := 0.0
## The deepest the ladder went in each --stress phase.
var _ai_phase_level := {}
## The arbiter's line (AIPlan R14): destruction over AI_HEAVY_MS for
## AI_HEAVY_TICKS ticks running is a collapse, and the AI steps down for it.
const AI_HEAVY_MS := 8.0
const AI_QUIET_MS := 4.0
const AI_HEAVY_TICKS := 3
## The longest run of ticks the destruction spent over AI_HEAVY_MS, and its
## worst tick: what tells the stress gate whether a step down was called for.
var _ai_heavy_run := 0
var _ai_heavy_run_max := 0
var _ai_destruction_peak := 0.0
## `-- --no-ai`: the city without the AI's tick, to measure what it costs.
var _no_ai := false
## Where a figure can walk, read from the bricks (AIPlan P3). Paths are
## requested and served from the scheduler's NAV share; columns are forgotten
## where the structure changes, by the same commands that change it.
var ai_nav := AINav.new()
## AI.md 10.1: paths and nav, half a millisecond a frame.
const NAV_BUDGET_US := 500
var _nav_worst_us := 0
## `_ai_tick`'s steps this tick, its worst tick and that tick's steps, and the
## ticks over AI_SPIKE_MS (`_ai_track_worst`).
var _ai_steps := {}
var _ai_worst_ms := 0.0
var _ai_worst_steps := {}
var _ai_spikes: Array = []
const AI_SPIKE_MS := 8.0
var _nav_mode := false
## Fights in progress: their buildings are held materialised (R3).
var _encounters: Array[Encounter] = []
## What every agent shares (AIServices): built from this city's own AI world,
## nav and scheduler; an agent's missed rounds go through the authority.
var ai_services: AIServices
var soldiers: Array[Soldier] = []
## Squads (AIPlan P6): U spawns one; the --squad gate clears a room with one.
var squads: Array[Squad] = []
## Pieces hurt the pawns they fall on and push out the ones inside them
## (Docs/Collapse.md 4.4).
var crush := Crush.new()


## Every living pawn: the soldiers', and the player's when the player is in one.
func _all_pawns() -> Array[Pawn]:
	var out: Array[Pawn] = []
	for so in soldiers:
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn):
			out.append(so.pawn)
	if _player_pawn != null and is_instance_valid(_player_pawn) and _player.is_possessing():
		out.append(_player_pawn)
	return out
## Settled wreckage resting on buildings (AI.md 3.10): piece id -> the building
## ids it loads. Loads are LOAD / UNLOAD commands, so a client has them too.
var _wreck_loads := {}
## Loads as last committed: piece id -> {building id: [cells, mass each]}, so a
## re-check that finds the same thing commits nothing.
var _wreck_state := {}
var _wreck_dirty := {}
var _soldier_mode := false
var _arena_mode := false
var _firefight_mode := false
var arena: WaveDirector
var _wreck_mode := false
var _jam_mode := false
var _drawn_mode := false
var _floating_mode := false
var _ring_mode := false
var _groups_mode := false
var _squad_mode := false
var _mechfall_mode := false
## `--planet=<test>`: the sphere-planet feasibility tests (Docs/Planets.md 10b),
## run by tools/planet_passes.gd on this scene.
var _planet_test := ""
const GUN_CLASSES: Array[StringName] = [&"pistol", &"smg", &"rifle", &"shotgun", &"sniper",
		&"rocket_launcher"]
## `--build[=res://or/user://path.json]`: drop a saved workshop build into the
## city. Empty means nothing was asked for; with no path it is the workshop's
## quick save (BuildRecipe.QUICK_SAVE).
var _build_path := ""
## How many buildings the stress pass destabilises. Every building is damaged
## either way; this is how many are hit hard enough to come down. -1 means all
## of them, which is the old behaviour -- see `_run_stress_pass`.
var _stress_collapse := 8
var _city_size := 22
var _promotions := 0
var _promote_ms := 0.0
## The slowest promotion and where its time went (_promote_part), for the exit
## report's "[ai-prof] promotions" line: an encounter brings buildings in a
## couple a tick, and that is what its first ticks cost.
var _promote_worst := [0.0, -1, {}]
var _promote_parts := {}
## Every promotion over PROMOTE_SLOW_MS: [ms, building, nth promotion, parts].
var _promote_slow: Array = []
const PROMOTE_SLOW_MS := 4.0
var _promote_part_at := 0
var _frame_worst := 0.0
var _frame_sum := 0.0
var _frame_samples := 0
## Physics ticks sampled. The per-tick means divide by THIS: a slow frame runs
## several ticks, and dividing tick sums by frames overstated every mean.
var _tick_samples := 0
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
## The frame split by the clock, while a pass samples (FrameClock).
var _clock: FrameClock
## The render phase's worst flushes and what the workers had handed over for
## each (UploadLedger), and all that landed over the pass.
const RENDER_SPIKE_MS := 8.0
var _render_spikes: Array = []
var _render_landed := {}
var _phases := {}
## Per-phase microseconds for the current physics tick, and the breakdown of
## the single worst frame seen. Guessing which phase owns a spike has been wrong
## every time so far, so it is measured.
var _prof := {}
var _prof_worst := {}
var _prof_worst_ms := 0.0
## Every tick over SPIKE_MS, as [ms, physics frame, its three biggest phases]:
## the worst tick alone hides the second-worst thing, which is often the one
## that happens at every break.
const SPIKE_MS := 25.0
var _prof_spikes: Array = []
var _prof_sum := {}


## The test passes (`-- --lod`, `-- --groups`, ...) live in
## tools/city_passes.gd, out of the game's own code: made the first time a
## pass is asked for, never in a plain run.
var _passes_node: Node = null


func _pass_runner() -> Node:
	if _passes_node == null:
		_passes_node = (load("res://tools/city_passes.gd") as GDScript).new(self)
		add_child(_passes_node)
	return _passes_node


func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	_shot_mode = "--shot" in args
	_bench_mode = "--bench" in args
	_bench_bricks = "--with-bricks" in args
	_terrain_mode = terrain_ground or "--terrain" in args
	_stress_mode = "--stress" in args
	_agents_mode = "--agents" in args
	_reach_mode = "--reach" in args
	_far_mode = "--far" in args
	_tree_mode = "--trees" in args
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
	_windows_mode = "--windows" in args
	_light_mode = "--light" in args
	# The scene's settings first, the command line over the top of them.
	_big = big_shapes or "--big" in args
	_wide = _big and not "--no-wide" in args and not combat_arena and not firefight
	_city_size = maxi(building_count, 1)
	_chamfer_mode = "--chamfer" in args
	_checkpoint_mode = "--checkpoint" in args
	_gun_mode = "--gun" in args
	_play_mode = "--play" in args
	_arms_mode = "--arms" in args
	for a: String in args:
		if a.begins_with("--asset-gun="):
			_asset_gun = StringName(a.trim_prefix("--asset-gun="))
	_mech_mode = "--mech" in args
	_vehicles_mode = "--vehicles" in args
	_no_ai = "--no-ai" in args
	_nav_mode = "--nav" in args
	_soldier_mode = "--soldier" in args
	_arena_mode = combat_arena or "--arena" in args
	_firefight_mode = firefight or "--firefight" in args
	_wreck_mode = "--wreck" in args
	_jam_mode = "--jam" in args
	_drawn_mode = "--drawn" in args
	_floating_mode = "--floating" in args
	_ring_mode = "--ring" in args
	# `--rooms` was the gate of the interior drawing this replaced, and is the
	# name other docs and habits still use for "the interiors gate".
	_groups_mode = "--groups" in args or "--rooms" in args
	_view_mode = "--view" in args
	DebugView.reset()
	_breaklag_mode = "--breaklag" in args
	_bigbreak_mode = "--bigbreak" in args
	_wide_mode = "--widecheck" in args
	_rubble_mode = "--rubble" in args
	_landing_mode = "--landing" in args
	# The A/B for staggered floor seams: every floor laid as before.
	TowerRecipe.stagger = not ("--no-stagger" in args)
	_storeys_mode = "--storeys" in args
	_whole_mode = "--whole" in args
	_squad_mode = "--squad" in args
	_mechfall_mode = "--mechfall" in args
	for a: String in args:
		if a.begins_with("--planet="):
			_planet_test = a.trim_prefix("--planet=")
	if _build_mode:
		_build_path = BuildRecipe.QUICK_SAVE
	for a in args:
		if a == "--build":
			_build_path = BuildRecipe.QUICK_SAVE
		elif a.begins_with("--build="):
			_build_path = a.split("=", true, 1)[1]
	# Not only in the stress pass. Walking round a city is the reason to want a
	# different number of buildings in it -- and with --big, six shapes is six
	# towers and twenty-two is a district.
	for a in args:
		if a.begins_with("--buildings="):
			_city_size = maxi(1, int(a.split("=")[1]))
			_buildings_arg = true
		elif a.begins_with("--debris-small="):
			debris_small_max = maxi(0, int(a.split("=")[1]))
		elif a.begins_with("--debris-large="):
			debris_large_max = maxi(0, int(a.split("=")[1]))
		elif a.begins_with("--debris-total="):
			debris_total_max = maxi(0, int(a.split("=")[1]))
		elif a.begins_with("--brick-budget="):
			brick_budget = maxi(0, int(a.split("=")[1]))
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
	# Storey units (Docs/Space.md 5.3a); --whole lays every building whole, as
	# it always was -- the storeys gate's "today".
	registry.storey_units = not _whole_mode
	# Doors in the builds' doorways, swung by whoever comes near, and lifts in their
	# shafts (Docs/RoomModules.md 3.2, 4).
	add_child(BuildDoors.new(world, BuildDoors.from_registry(registry)))
	add_child(BuildLifts.new(world, BuildDoors.from_registry(registry)))

	islands = IslandManager.new()
	islands.small_live_max = debris_small_max
	islands.large_live_max = debris_large_max
	islands.total_live_max = debris_total_max
	islands.name = "Islands"
	add_child(islands)
	islands.setup(world, brick_material, camera)
	brick_near = BrickNear.new(world)
	islands.near_tier = brick_near
	# For measurement: the same city with no near tier at all, to set a pass
	# against one with it.
	# `--no-studs` and `--no-bevel` are its two halves, one at a time.
	var near_args := OS.get_cmdline_user_args()
	if "--no-near" in near_args or "--no-bevel" in near_args:
		BrickNear.enabled = false
	if "--no-near" in near_args or "--no-studs" in near_args:
		brick_near.studs_on = false
	# This scene starts the pieces' mesh jobs itself, after everything else in
	# its tick (IslandManager._submit_mesh_job).
	islands.defer_job_start = true
	islands.on_impact = _on_island_impact
	# A building's pieces break along its floors (IslandManager._floor_line):
	# the floors its structure record names (Docs/DestructionLod.md 4).
	islands.floor_lines = func(id: int) -> PackedInt32Array:
		return registry.floor_lines(id)
	director = CollapseDirector.new(world)
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
	ai_world.set_world(world)
	ai_nav.set_ai_world(ai_world)
	AIServices.use_hierarchy(ai_nav)
	# NavChange (R17): the commands that change structure are the ones that say
	# where navigation is stale.
	authority.committed.connect(_nav_on_command)
	islands.piece_settled.connect(func(isl: BrickIsland) -> void:
		ai_nav.invalidate_box(islands.world_aabb(isl).grow(0.5))
		_crush_drawn(isl)
		_wreck_settled(isl))
	islands.piece_woken.connect(func(isl: BrickIsland) -> void:
		if isl.settled:
			_wreck_settled(isl))
	islands.piece_changed.connect(func(isl: BrickIsland) -> void:
		# Lost bricks: what it weighs, and what it rests on, may have changed.
		# Looked at once a tick, not once a bullet.
		if _wreck_loads.has(isl.piece_id):
			_wreck_dirty[isl.piece_id] = isl)
	islands.piece_slept.connect(func(piece_id: int, _record: ChunkRecord) -> void:
		_wreck_unload(piece_id))
	islands.piece_removed.connect(func(isl: BrickIsland, _reason: StringName) -> void:
		_wreck_unload(isl.piece_id)
		if isl.is_valid():
			ai_nav.invalidate_box(islands.world_aabb(isl).grow(0.5)))
	ai_services = AIServices.new()
	ai_services.ai_world = ai_world
	ai_services.ai_nav = ai_nav
	ai_services.sched = ai_sched
	ai_services.rng.seed = 0x50DD1E4
	# What the casebook chooses is counted across runs (TacticsTally), for the
	# graph on the Tactics Casebook page -- but not a gate's scripted fights.
	var tally_args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if not "--gate" in tally_args and not "--squad" in tally_args:
		ai_services.tally = (load("res://scripts/ai/tactics/tactics_tally.gd") as GDScript).call(&"open")
	# A squad's breaching charge is a blast like any other: asked for, queued,
	# committed by the host, replayed by clients.
	ai_services.on_breach = _blast
	# Cover and garrison spots authors marked in builds (Docs/AI.md 3.3.1).
	ai_services.marks = func(p: Vector3, radius: float, kind: String) -> Array[Vector3]:
		return BuildingMarks.near(p, radius, kind, registry)
	mech_nav = MechBrain.mech_nav(ai_world)
	# Whatever changes where a figure can walk changes where a mech can.
	ai_nav.nav_changed.connect(mech_nav.invalidate_box)
	ai_services.share_nav(mech_nav)
	weight = WeightTracker.new(ai_world, world)
	weight.on_load = _weight_load
	weight.on_unload = _weight_unload
	weight.on_solve = _weight_solve
	# A piece that comes off under a mech crashing through is not something it
	# lands on (R9).
	islands.piece_spawned.connect(_mech_ignore_piece)
	ai_sched.set_base_budget_ms(2.5)
	# This script's own tick: a quiet city is 1-3 ms of it, a collapse tens.
	ai_sched.set_thresholds(AI_HEAVY_MS, AI_QUIET_MS)
	ai_sched.set_hysteresis(AI_HEAVY_TICKS, 45)
	# The field first: `_build_city` asks it how high each building stands,
	# and a question asked before the field is configured is answered by the
	# wrong world.
	if _terrain_mode:
		_setup_terrain_field()
	_build_city()
	# And the ground last, because every pad the city stamped is part of the
	# field now and a tile built before them would be the wrong shape.
	if _terrain_mode:
		# `--save-world`: write the layout the city was just built from --
		# the street grid, the first time -- to its world file, and stop.
		# That file is what the terrain editor opens (`--world=city`) and
		# what the city reads from then on.
		if "--save-world" in args:
			var err := TerrainWorldScript.save_world(_terrain_world_path,
					int(BrickTerrain.get_seed()), _terrain_drowned)
			print("[city] terrain: %s %s (%d sites, %d pads)" % [
				"wrote" if err == OK else "COULD NOT WRITE", _terrain_world_path,
				TerrainWorldScript.sites.size(), BrickTerrain.pad_count()])
			get_tree().quit(0 if err == OK else 1)
			return
		_build_terrain_ground()
		if not "--no-trees" in args:
			_place_trees()
	# F9 reloaded the scene to get here: the city is recipes again, and the
	# checkpoint goes on top of them.
	var root := get_tree().root
	if root.has_meta(CHECKPOINT_META):
		var path: String = root.get_meta(CHECKPOINT_META)
		root.remove_meta(CHECKPOINT_META)
		_restore_checkpoint(path)
	# Not after a load: the save carries every placed build, `--build`'s too.
	if _build_path != "" and not _checkpoint_restored:
		_place_build(_build_path)
	# P picks up a saved workshop build and places it like a brick
	# (scripts/city_placer.gd); what it places goes through the same
	# index-and-shell path as `_place_build`.
	_placer = CityPlacer.new()
	_placer.name = "Placer"
	add_child(_placer)
	_placer.setup(registry, camera)
	_placer.on_placed = func(id: int) -> void:
		var grounded: bool = _terrain_mode and _placer.on_ground
		if grounded:
			_ground_building(id)
		_index_building(id)
		_make_shell(id)
		_note_placed(id, grounded)
	if _terrain_mode:
		# The ground a build is aimed at is the terrain's own collider, so
		# the ghost stands where the ground is drawn.
		_placer.ground_ray = func(from: Vector3, dir: Vector3) -> Vector3:
			var q := PhysicsRayQueryParameters3D.create(from, from + dir * 800.0, Layers.WORLD)
			var hit := get_world_3d().direct_space_state.intersect_ray(q)
			return Vector3.INF if hit.is_empty() else hit["position"]
		# The drawn top: a curve's own height, else the column's brick top.
		_placer.ground_top = func(x: int, z: int) -> float:
			var brick := float(BrickTerrain.surface_plate(x, z) + 1) * BrickWorld.get_plate_metres()
			return BrickTerrain.surface_raw(x, z) if BrickTerrain.smooth_at(x, z) else brick
	_setup_furnisher()
	_material_fx = MaterialFx.new()
	_material_fx.name = "MaterialFx"
	add_child(_material_fx)
	_material_fx.setup(world, registry, camera)
	# Every city, big included: what a disaster touches is ranged round the
	# player (targets, failures, fire), so a bigger city is not a bigger bill.
	disasters = DisasterDirector.new()
	disasters.name = "Disasters"
	add_child(disasters)
	disasters.setup(self)
	InteriorGroups.warm(self)
	_warm_shaders()
	# One of the passes below, unless none of them is asked for (the `else` at
	# the end of the chain).
	_scripted = true
	if _lod_mode:
		_pass_runner()._run_lod_pass()
	elif _reach_mode:
		_pass_runner()._run_reach_pass()
	elif _far_mode:
		_pass_runner()._run_far_pass()
	elif _tree_mode:
		_pass_runner()._run_tree_pass()
	elif _walk_mode:
		_pass_runner()._run_walk_pass()
	elif _build_mode:
		_pass_runner()._run_build_pass()
	elif _fixture_mode:
		_pass_runner()._run_fixture_pass()
	elif _dormant_mode:
		_pass_runner()._run_dormant_pass()
	elif _windows_mode:
		_pass_runner()._run_windows_pass()
	elif _light_mode:
		_pass_runner()._run_light_pass()
	elif _chamfer_mode:
		_pass_runner()._run_chamfer_pass()
	elif _checkpoint_mode:
		_pass_runner()._run_checkpoint_pass()
	elif _gun_mode:
		_pass_runner()._run_gun_pass()
	elif _play_mode:
		_pass_runner()._run_play_pass()
	elif _asset_gun != &"":
		_pass_runner()._run_asset_gun_pass()
	elif _arms_mode:
		_pass_runner()._run_arms_pass()
	elif _mech_mode:
		_pass_runner()._run_mech_pass()
	elif _vehicles_mode:
		_pass_runner()._run_vehicles_pass()
	elif _nav_mode:
		_pass_runner()._run_nav_pass()
	elif _soldier_mode:
		_pass_runner()._run_soldier_pass()
	elif _breaklag_mode:
		_pass_runner()._run_breaklag_pass()
	elif _bigbreak_mode:
		_pass_runner()._run_bigbreak_pass()
	elif _wide_mode:
		_pass_runner()._run_wide_pass()
	elif _rubble_mode:
		_pass_runner()._run_rubble_pass()
	elif _landing_mode:
		_pass_runner()._run_landing_pass()
	elif _storeys_mode:
		_pass_runner()._run_storeys_pass()
	elif _wreck_mode:
		_pass_runner()._run_wreck_pass()
	elif _jam_mode:
		_pass_runner()._run_jam_pass()
	elif _drawn_mode:
		_pass_runner()._run_drawn_pass()
	elif _floating_mode:
		_pass_runner()._run_floating_pass()
	elif "--lodbreak" in OS.get_cmdline_user_args():
		_pass_runner()._run_lodbreak_pass()
	elif "--roomcost" in OS.get_cmdline_user_args():
		_pass_runner()._run_roomcost_pass()
	elif "--roomsview" in OS.get_cmdline_user_args():
		_pass_runner()._run_roomsview_pass()
	elif "--breakshape" in OS.get_cmdline_user_args():
		_pass_runner()._run_breakshape_pass()
	elif _ring_mode:
		_pass_runner()._run_ring_pass()
	elif _groups_mode:
		_pass_runner()._run_groups_pass()
	elif _view_mode:
		_pass_runner()._run_view_pass()
	elif "--physview" in OS.get_cmdline_user_args():
		_pass_runner()._run_physview_pass()
	elif "--piececost" in OS.get_cmdline_user_args():
		_pass_runner()._run_piececost_pass()
	elif "--boat" in OS.get_cmdline_user_args():
		_pass_runner()._run_boat_pass()
	elif _squad_mode:
		_pass_runner()._run_squad_pass()
	elif _mechfall_mode:
		_pass_runner()._run_mechfall_pass()
	elif _planet_test != "":
		var planet_pass: Node = (load("res://tools/planet_passes.gd") as GDScript).new(self)
		add_child(planet_pass)
		planet_pass.run(_planet_test)
	elif _firefight_mode:
		_start_firefight("--gate" in args)
	elif _arena_mode:
		_start_arena("--gate" in args)
	elif _stress_mode:
		_pass_runner()._run_stress_pass()
	elif _bench_mode:
		_pass_runner()._run_bench()
	elif _shot_mode:
		_pass_runner()._run_shot_pass()
	else:
		_scripted = false
	# The arena is in the chain and is the game, not a pass, unless it is run
	# as its gate.
	if (_arena_mode or _firefight_mode) and not ("--gate" in args):
		_scripted = false
	# A pass's clouds held still: its pictures do not drift between shots.
	CloudLayer.still = _scripted
	if _scripted:
		# A pass clicks for itself (--play, --mech), and a click is what takes
		# the mouse: never the real one.
		PlayerCamera.hands_off = true
		# On the menu's default settings, not whatever the user has set in
		# Options: a pass's answer must not depend on their brightness.
		var test_window := get_node_or_null(^"/root/TestWindow")
		if test_window != null:
			test_window.use_default_settings()
		# "Pause When Unfocused" off for this run, not saved: see pause_allowed.
		var menu_settings := get_node_or_null(^"/root/MenuSettings")
		if menu_settings != null:
			menu_settings.set_value(&"pause_on_focus_loss", false, false)


## A scripted pass is running: a gate, a probe pass, a measurement -- anything
## the chain at the end of _ready started. It runs in a window nobody is at,
## on a machine somebody is using.
var _scripted := false
var clouds: CloudLayer


## May the pause menu open over this scene? (BrickcityMenuHost asks.)
##
## Not over a scripted pass. Paused, the city stands still while the pass goes
## on counting ticks and taking pictures: two gates on 2026-10-06 each wrote
## the pause menu as one of their screenshots -- once when the window lost
## focus ("Pause When Unfocused", which a pass also turns off for its run),
## once when Escape was pressed at the keyboard while the window had it.
## `--play` is the pass that checks Escape opens the menu, so it may.
func pause_allowed() -> bool:
	return not _scripted or _play_mode


func _exit_tree() -> void:
	_report_ai_profile()
	if ai_services != null and ai_services.tally != null:
		ai_services.tally.call(&"save")
	# A band still uploading on a worker at shutdown was a crash on quit, as a
	# piece's was (IslandManager._exit_tree).
	for job in _band_jobs:
		if int(job[2]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(job[2]))
	_band_jobs.clear()
	# And a shell's windows.
	for job in _glass_jobs:
		WorkerThreadPool.wait_for_task_completion(int((job as Array)[0]))
	_glass_jobs.clear()
	if brick_near != null:
		brick_near.shutdown()
	for job in _far_coarse_jobs.values():
		if int((job as Array)[1]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int((job as Array)[1]))
	_far_coarse_jobs.clear()
	# And the panes of a building in bricks.
	if not _pane_job.is_empty():
		WorkerThreadPool.wait_for_task_completion(int(_pane_job[0]))
		_pane_job = []
	# And a shadow proxy being built.
	for job in _shadow_jobs.values():
		WorkerThreadPool.wait_for_task_completion(int((job as Array)[0]))
	_shadow_jobs.clear()
	for bodies in _frame_bodies.values():
		for rid in (bodies as Array):
			PhysicsServer3D.free_rid(rid)
	for rid in _shell_bodies.values():
		PhysicsServer3D.free_rid(rid)
	for r in _rest_shells.values():
		PhysicsServer3D.free_rid((r as Array)[1])
	_rest_shells.clear()
	for col in _brick_cols.values():
		(col as BuildingCollision).free_bodies()
	for rid in _shape_cache.values():
		PhysicsServer3D.free_rid(rid)
	# The furniture bodies too: the one Jolt body every run leaked at exit.
	for rid in _room_bodies.values():
		PhysicsServer3D.free_rid(rid)
	_room_bodies.clear()
	# And the player's controller and the mech pilot, which are only in the tree
	# while possessing or piloting -- otherwise nothing frees them ("2 resources
	# still in use at exit": their scripts).
	for n in [_player, _pilot]:
		if is_instance_valid(n) and not (n as Node).is_inside_tree():
			(n as Node).free()
# ---------------------------------------------------------------------------

func _build_city() -> void:
	var t0 := Time.get_ticks_usec()
	if _terrain_mode:
		_build_city_on_sites()
	else:
		var shapes: Array = BIG_SHAPES if _big else SHAPES
		var spacing := _grid_spacing(shapes)
		var index := 0
		var side := int(ceil(sqrt(float(_city_size))))
		for row in side:
			for col in side:
				if index >= _city_size:
					break
				var shape: Dictionary = shapes[(row * side + col) % shapes.size()]
				# Close together on purpose: these have to be able to fall on
				# each other, which is the whole point of the scene.
				@warning_ignore("integer_division")
				var half := (side - 1) * spacing / 2
				var pos := BrickWorld.grid_to_world(
						Vector3i(col * spacing - half, 0, row * spacing - half))
				_place_building(shape.x, shape.z, shape.courses, pos,
						_program_for(shape, index))
				index += 1
		if _wide:
			_place_wide_buildings(side, spacing, index)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	# Each tower shape's bricks, built once now so no promotion builds them
	# (BuildingRegistry.prepare_templates).
	var template_ms := registry.prepare_templates()
	print("[city] %d tower template(s) in %.0f ms" % [world.get_template_count(), template_ms])

	var mem: Dictionary = world.get_memory_report()
	print("[city] %d buildings in %.0f ms — BrickWorld holds %.2f MB across %d chunks" % [
		registry.buildings.size(), ms, float(mem.total_bytes) / 1048576.0, mem.chunks])
	var tris := 0
	for mi in _shells.values():
		if (mi as MeshInstance3D).mesh == null:
			continue  # drawn by its far box
		@warning_ignore("integer_division")
		var t := (mi as MeshInstance3D).mesh.get_faces().size() / 3
		tris += t
	print("[city] shells: %d triangles total, %.0f per building" % [
		tris, float(tris) / maxf(registry.buildings.size(), 1)])
	_update_hud()


## Studs between one building's corner and the next on the street grid.
##
## In STUDS, so every building's corner is on the grid by construction rather
## than by BuildingRegistry.on_grid rounding it there: 13 m was 37.14 studs,
## and the rounding nudged each tower a different way.
##
## And never closer than the widest footprint plus a street. The lattice
## footprints (up to 44 studs, 15.4 m) outgrew the old 13 m pitch, and two
## pairs of towers stood 2.45 m inside each other.
func _grid_spacing(shapes: Array) -> int:
	var spacing := roundi((BIG_SPACING if _big else 13.0) / STUD)
	var widest := 0
	for s in shapes:
		widest = maxi(widest, maxi(int(s.x), int(s.z)))
	return maxi(spacing, widest + STREET_STUDS)


## The wide buildings (WIDE_SHAPES), in rows past the grid's last.
func _place_wide_buildings(side: int, spacing: int, index: int) -> void:
	@warning_ignore("integer_division")
	var half := (side - 1) * spacing / 2
	for r in WIDE_SHAPES.size():
		var x := -half
		var z := (side + r) * spacing - half
		for shape: Dictionary in WIDE_SHAPES[r]:
			var id := _place_building(shape.x, shape.z, shape.courses,
					BrickWorld.grid_to_world(Vector3i(x, 0, z)), _program_for(shape, index))
			_wide_ids[id] = true
			index += 1
			x += int(shape.x) + WIDE_GAP_STUDS


## One building into the registry, with its stair, its index and its shell.
func _place_building(fx: int, fz: int, courses: int, pos: Vector3,
		program: Dictionary) -> int:
	var id := registry.register(fx, fz, courses, Transform3D(Basis(), pos), program)
	_add_staircase(id, fx, fz, courses)
	_index_building(id)
	_make_shell(id)
	return id


## THE CITY FROM ITS SITES (Docs/Terrain.md §21.5).
##
## On terrain the layout is the world's, not a lattice this script makes up:
## each site is a centre, a footprint, a pad and a number of storeys, saved
## in the world file and moved in the terrain editor. A world with no sites
## yet gets the street grid AS sites, so there is one path either way and the
## grid is only ever a starting point.
func _build_city_on_sites() -> void:
	var sites: Array[Dictionary] = TerrainWorldScript.sites
	if sites.is_empty():
		sites = _grid_sites()
		TerrainWorldScript.sites = sites
		# The pads, in order: each one sees the ones before it, so a row
		# terraces instead of each tower carving its own island.
		TerrainWorldScript.stamp_sites_only(sites)
		print("[city] terrain: no sites in %s; %d from the street grid" % [
			_terrain_world_path, sites.size()])
	else:
		print("[city] terrain: %d sites from %s" % [sites.size(), _terrain_world_path])
	var index := 0
	for site in sites:
		if _buildings_arg and index >= _city_size:
			break
		var fp := TerrainWorldScript.site_footprint(site)
		var corner := TerrainWorldScript.site_corner(site)
		var courses: int = int(site["storeys"]) * TowerRecipe.COURSES_PER_FLOOR
		# The floor is READ from the field, after every pad is in: there is
		# one height function, and both the tower and the ground under it
		# read it (§21.1).
		var pos := BrickWorld.grid_to_world(Vector3i(corner.x, 0, corner.y))
		pos.y = TerrainWorldScript.site_level(site)
		var program: Dictionary = site["program"] if site.has("program") \
				else _program_for({}, index)
		_site_ids.append(_place_building(fp.x, fp.y, courses, pos, program))
		index += 1


## The street grid, as sites: the same lattice `_build_city` lays on the flat
## plane, one site per building, each carrying its own centre and footprint
## because a street is nine studs and a tile is 32.
##
## Except where the grid lands in the SEA. A building does not stand in the
## water, and leaving those cells empty is what gives a city on low ground
## its shoreline; a site on ground just above the water gets a quay instead
## (TerrainWorld.FREEBOARD_BRICKS).
func _grid_sites() -> Array[Dictionary]:
	var shapes: Array = BIG_SHAPES if _big else SHAPES
	var spacing := _grid_spacing(shapes)
	var plate := BrickWorld.get_plate_metres()
	var tile := BrickTerrain.get_tile_studs()
	var out: Array[Dictionary] = []
	var index := 0
	var drowned := 0
	var side := int(ceil(sqrt(float(_city_size))))
	for row in side:
		for col in side:
			if index >= _city_size:
				break
			var shape: Dictionary = shapes[(row * side + col) % shapes.size()]
			index += 1
			@warning_ignore("integer_division")
			var half := (side - 1) * spacing / 2
			@warning_ignore("integer_division")
			var centre := Vector2i(col * spacing - half + int(shape.x) / 2,
					row * spacing - half + int(shape.z) / 2)
			var ground := float(BrickTerrain.surface_plate(centre.x, centre.y) + 1) * plate
			if ground < TerrainWorldScript.sea_level:
				drowned += 1
				continue
			# The pad is the footprint plus a step of margin -- ground to
			# stand on, not ground exactly its own size -- with a skirt half
			# as wide again back to the hillside.
			@warning_ignore("integer_division")
			var radius: int = maxi(int(shape.x), int(shape.z)) / 2 + 4
			@warning_ignore("integer_division")
			var site := {
				"tile": Vector2i(floori(float(centre.x) / tile), floori(float(centre.y) / tile)),
				"centre": centre,
				"footprint": Vector2i(int(shape.x), int(shape.z)),
				"radius": radius,
				"skirt": radius / 2 + 2,
				"storeys": int(shape.courses) / TowerRecipe.COURSES_PER_FLOOR,
			}
			if shape.has("program"):
				site["program"] = shape.program
			out.append(site)
	if drowned > 0:
		print("[city] terrain: %d grid cell(s) are sea, left empty" % drowned)
	return out


## The field this city is cut into. Before anything asks it a question.
func _setup_terrain_field() -> void:
	# Brick heightfield ground -- a city wants ground to stand on, not caves
	# under it -- and the world file in it: its sea, its pads and its sites
	# (TerrainWorld.open_world, the same call the heightfield test makes).
	# Loading clears the pad list first -- it is global, and a scene reload
	# would otherwise stamp a second set on top of the first -- and settles
	# the sea on the field as generated, before any pad is cut
	# (TerrainWorld.sea_level).
	_terrain_world_path = TerrainWorldScript.world_path("big_city" if _big else "city")
	var loaded: Dictionary = TerrainWorldScript.open_world(_terrain_world_path, TERRAIN_SEED)
	if loaded.is_empty():
		BrickTerrain.clear_pads()
		BrickTerrain.clear_paints()
		BrickTerrain.clear_sculpt()
		TerrainWorldScript.sites = []
		TerrainWorldScript.settle_sea(CITY_DROWNED)
	else:
		_terrain_drowned = float(loaded.get("drowned", CITY_DROWNED))
	# Taken FROM THE LIGHT, so the baked shadow and the lit ground can never
	# disagree. A DirectionalLight3D shines along its own -Z.
	BrickTerrain.set_sun_direction(_sun.global_transform.basis.z)
	# The AI's ground is the field too (§21.7): a column's first floor is on
	# the hillside, a crest blocks a sight line, and the sea is not a floor.
	ai_world.set_terrain_ground(true)
	ai_nav.set_water_level(TerrainWorldScript.sea_level)
	mech_nav.set_water_level(TerrainWorldScript.sea_level)


## The ground the city stands on, when it stands on ground.
##
## STREAMED, as in the heightfield test (Docs/Terrain.md §22.18): full detail
## in a square round the camera, the coarse tier everywhere else out to
## TERRAIN_REACH_TILES, hidden under the detail as it moves. The city's own
## square is PINNED: held resident with its collider wherever the camera is,
## so an enemy across the map and the debris of a collapse two streets away
## still stand on something -- but drawn only while the square reaches it.
func _build_terrain_ground() -> void:
	var t0 := Time.get_ticks_usec()
	var stud := BrickWorld.get_stud_metres()
	var tile_m := float(BrickTerrain.get_tile_studs()) * stud

	# How far the city actually reaches, from the buildings themselves rather
	# than from a constant: --big is 240 m across where the default is 96.
	var reach := 0.0
	for b in registry.buildings:
		var o := b.xform.origin
		var w := float(maxi(int(b.recipe.footprint_x), int(b.recipe.footprint_z))) * stud
		reach = maxf(reach, maxf(absf(o.x), absf(o.z)) + w)
	var half: int = int(ceil(reach / tile_m)) + 1
	_terrain_half = half

	_terrain_mat = TerrainTile.ground_material(-_sun.global_transform.basis.z)

	_terrain_streamer = TerrainStreamer.new()
	_terrain_streamer.name = "TerrainStreamer"
	_terrain_streamer.near_radius = TERRAIN_NEAR_TILES
	_terrain_streamer.keep_radius = TERRAIN_NEAR_TILES + 2
	# Detail can be walked to anywhere the coarse ground reaches.
	_terrain_streamer.world_half = TERRAIN_REACH_TILES
	# COLLISION EVERYWHERE IN THE CITY, not just under the camera: the
	# pinned square always has its collider.
	_terrain_streamer.pinned = Rect2i(-half, -half, half * 2 + 1, half * 2 + 1)
	add_child(_terrain_streamer)
	_terrain_streamer.setup(_terrain_mat)
	# The camera can start inside a hill: its position was chosen against a
	# plane at y=0 and the field has 48 m of relief.
	var ground_y := float(BrickTerrain.surface_plate(
			int(floor(camera.position.x / stud)),
			int(floor(camera.position.z / stud)) ) + 1) * BrickWorld.get_plate_metres()
	camera.position.y = maxf(camera.position.y, ground_y + 12.0)
	_terrain_streamer.settle(Vector2(camera.position.x, camera.position.z))
	var detail_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	_build_terrain_coarse()

	var lo := 1e9
	var hi := -1e9
	for b in registry.buildings:
		lo = minf(lo, b.xform.origin.y)
		hi = maxf(hi, b.xform.origin.y)
	print("[city] terrain: %d pads, floors %.1f..%.1f m, %d detail tiles in %.0f ms" % [
		BrickTerrain.pad_count(), lo, hi, _terrain_streamer.tile_count(), detail_ms])
	print("[city] terrain: coarse %d blocks in %d ring(s), %d triangles, %.0f ms total" % [
		_terrain_coarse.block_count(), _terrain_coarse.ring_count(),
		_terrain_coarse.triangle_count(),
		float(Time.get_ticks_usec() - t0) / 1000.0])
	_build_sea(tile_m)


## The coarse ground out to the horizon, with the city's square cut out of it.
func _build_terrain_coarse() -> void:
	_terrain_coarse = TerrainCoarseScript.new()
	_terrain_coarse.name = "TerrainCoarse"
	add_child(_terrain_coarse)
	# No hole: the detail square moves, so the coarse tier covers the world
	# and hides under it, down to the block the two are aligned on -- as in
	# the heightfield test.
	_terrain_coarse.build(TERRAIN_REACH_TILES, _terrain_mat, Rect2i(),
			_terrain_streamer.align)
	_terrain_coarse.cover(_terrain_streamer)


# ---------------------------------------------------------------------------
# The terrain dev menu (terrain_dev_menu.gd, Docs/Terrain.md §20.10, §22.15).
#
# F10 on terrain: the same menu the heightfield test opens, on this scene's
# ground and sea. What it asks of a host is in its header; the detail square
# follows the camera here too, so Freeze LOD and Detail radius are offered.

const TerrainDevMenu := preload("res://scripts/terrain_dev_menu.gd")
var _terrain_dev_menu = null
var _lod_debug := false
var _lod_frozen := false
var _frozen_at := Vector3.ZERO


func set_lod_frozen(on: bool) -> void:
	_lod_frozen = on
	_frozen_at = camera.global_position


func set_detail_radius(tiles: int) -> void:
	_terrain_streamer.near_radius = tiles
	_terrain_streamer.keep_radius = tiles + 2
	if _lod_frozen:
		# One step at the frozen spot, so the change is seen while frozen.
		_terrain_streamer.settle(Vector2(_frozen_at.x, _frozen_at.z))
		_terrain_coarse.cover(_terrain_streamer)


func _toggle_terrain_dev_menu() -> void:
	if _terrain_streamer == null:
		print("[city] no terrain here: the dev menu is the ground's (F10)")
		return
	var opening: bool = _terrain_dev_menu == null
	if not opening:
		_terrain_dev_menu.queue_free()
		_terrain_dev_menu = null
	else:
		# Built fresh each time, so every control shows the state as it is now.
		_terrain_dev_menu = TerrainDevMenu.new()
		_terrain_dev_menu.name = "TerrainDevMenu"
		stats_label.get_parent().add_child(_terrain_dev_menu)
		_terrain_dev_menu.setup(self)
		_fit_terrain_dev_menu()
		if not get_viewport().size_changed.is_connected(_fit_terrain_dev_menu):
			get_viewport().size_changed.connect(_fit_terrain_dev_menu)
	# The mouse is the menu's while it is open, and the camera's again after.
	camera._set_captured(not opening)


## Down the right-hand side: the stats fill the left, top to bottom.
func _fit_terrain_dev_menu() -> void:
	if _terrain_dev_menu != null and is_instance_valid(_terrain_dev_menu):
		_terrain_dev_menu.fit(12.0, get_viewport().get_visible_rect().size.x - 480.0)


func set_lod_view(on: bool) -> void:
	_lod_debug = on
	_terrain_mat.set_shader_parameter("lod_debug", on)
	if _sea != null:
		_sea.set_lod_debug(on)


func set_ground_param(param: String, value: Variant) -> void:
	_terrain_mat.set_shader_parameter(param, value)


func set_water_param(param: String, value: Variant) -> void:
	if _sea == null:
		return
	for tier in _sea.tiers():
		tier._mat.set_shader_parameter(param, value)


func dev_sea():
	return _sea


## Every detail tile again from the field, behind the ones on screen.
func rebuild_detail() -> void:
	var h: int = _terrain_streamer.world_half
	_terrain_streamer.refresh(Rect2i(-h, -h, h * 2 + 1, h * 2 + 1))


## The coarse tier from scratch: after the smooth step changed.
func rebuild_far() -> void:
	_terrain_coarse.rebuild()
	print("[city] terrain: coarse rebuilt, %d blocks, %d triangles, smooth from step %d" % [
		_terrain_coarse.block_count(), _terrain_coarse.triangle_count(),
		BrickTerrain.get_coarse_smooth_step()])


# ---------------------------------------------------------------------------
# Terrain edit mode (terrain_editor.gd, Docs/Terrain.md §20, §22.17).
#
# F11 on terrain: the level editor's tools, on this scene's ground. While it
# is on, the number keys, the left button and the rest of the editor's keys
# are the editor's (`_unhandled_input` gives them up), and the camera flies.
# Pads, paint and the brushes are live; a SITE here is a real building on
# its pad, so the site tool and site pads are locked (`sites: false`) --
# those are edited in heightfield_test with `-- --world=city`.

const TerrainEditTools := preload("res://scripts/terrain_editor.gd")
var _terrain_editor = null
var _edit_mode := false


func _toggle_terrain_edit() -> void:
	if _terrain_streamer == null:
		print("[city] no terrain here: nothing to edit (F11)")
		return
	if not _edit_mode and _pilot.is_piloting():
		print("[city] terrain edit: get out of the mech first (M)")
		return
	_edit_mode = not _edit_mode
	if _edit_mode:
		# The tools are aimed with a free camera.
		if _player.is_possessing():
			_leave_pawn()
		# And the gun put down (as 2 does): the left button is the brush's.
		_gun_armed = false
		_gun.set_trigger(false)
		if _gun.gun != null:
			_gun.gun.visible = false
		if _terrain_editor == null:
			_terrain_editor = TerrainEditTools.new()
			_terrain_editor.name = "TerrainEditor"
			add_child(_terrain_editor)
			_terrain_editor.setup(self)
		_terrain_editor.set_active(true)
	else:
		_terrain_editor.set_active(false)
	print("[city] terrain edit mode: %s" % ("ON -- the editor's keys, top right; F11 leaves"
			if _edit_mode else ("off, UNSAVED edits kept (CTRL+S in edit mode writes %s)"
			% _terrain_world_path if _terrain_editor.is_dirty() else "off")))
	_update_hud()


## What the editing tools are handed (terrain_editor.gd's header).
func edit_context() -> Dictionary:
	return {
		"camera": camera, "streamer": _terrain_streamer,
		"world_path": _terrain_world_path, "seed": int(BrickTerrain.get_seed()),
		"drowned": _terrain_drowned, "world_half": _terrain_streamer.world_half,
		"status": "editing %s" % _terrain_world_path.get_file(), "sites": false,
		# Under the arena's readout, which has the top right.
		"hud_top": 190.0,
	}


## The editor's stand-in buildings on the sites: here the sites have their
## real ones.
func rebuild_sites() -> void:
	pass


## THE SEA, at the level the world settled (§21.6), out as far as the coarse
## ground goes. Only if there is any: a world whose sea is under all of its
## ground has nothing to draw, and the brick tiers are not free.
## A disaster moves the sea (DisasterContext.set_sea): a hurricane's surge.
## Nothing where the city has no sea.
func disaster_sea(surge: float, wave_mul: float) -> void:
	if _sea != null:
		_sea.set_surge(surge, wave_mul)


func _build_sea(tile_m: float) -> void:
	var t0 := Time.get_ticks_usec()
	_sea = WaterSeaScript.new()
	_sea.name = "Sea"
	add_child(_sea)
	_sea.build(TERRAIN_REACH_TILES * BrickTerrain.get_tile_studs(),
			float(TERRAIN_REACH_TILES) * tile_m + 200.0)
	if not _sea.has_water():
		print("[city] terrain: sea %.2f m is under all the ground; no water" % [
			TerrainWorldScript.sea_level])
		_sea.queue_free()
		_sea = null
		return
	camera.water_probe = func(p: Vector3) -> float: return _sea.surface_at(p)
	print("[city] terrain: sea at %.2f m, %d wet cells, built in %.0f ms" % [
		TerrainWorldScript.sea_level, _sea._wet_count,
		float(Time.get_ticks_usec() - t0) / 1000.0])


## A build placed on the ground: the ground comes to ITS floor (§21.8).
##
## A pad the shape of its footprint plus a pavement, at exactly the height the
## placer put the floor, cut into the field; the tiles over it rebuild behind
## the ones on screen, and the AI forgets the ground it had read there. The
## building never moves to suit the hill -- it is on the stud grid where it
## was aimed, and the hill is what gives.
const PLACED_MARGIN := 2
const PLACED_SKIRT := 8
func _ground_building(id: int) -> void:
	var b := registry.get_building(id)
	var box: AABB = CityPlacer.box_of(b)
	var cx := int(floor((box.position.x + box.size.x * 0.5) / STUD))
	var cz := int(floor((box.position.z + box.size.z * 0.5) / STUD))
	var hx := int(ceil(box.size.x / STUD * 0.5)) + PLACED_MARGIN
	var hz := int(ceil(box.size.z / STUD * 0.5)) + PLACED_MARGIN
	BrickTerrain.add_pad(cx, cz, hx, PLACED_SKIRT, box.position.y, hz)
	var studs: Rect2i = BrickTerrain.pad_bounds(BrickTerrain.pad_count() - 1)
	_reground(studs)


## The field changed over these studs: rebuild the ground there, and make the
## AI read it again.
func _reground(studs: Rect2i) -> void:
	if _terrain_streamer != null:
		_terrain_streamer.refresh(_tiles_over(studs))
	terrain_changed(studs)


static func _tiles_over(studs: Rect2i) -> Rect2i:
	var tile := BrickTerrain.get_tile_studs()
	var lo := Vector2i(floori(float(studs.position.x) / tile), floori(float(studs.position.y) / tile))
	var hi := Vector2i(floori(float(studs.end.x) / tile), floori(float(studs.end.y) / tile))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## The field changed over these studs, and the detail tiles over them are
## already being rebuilt (by `_reground`, or by the editing tools, which
## know which tiles their brush is under): everything else that was read
## from the field there.
func terrain_changed(studs: Rect2i) -> void:
	# A pad's skirt, or a brush, can reach past the city's square onto
	# coarse ground.
	if _terrain_coarse != null:
		_terrain_coarse.field_changed(_tiles_over(studs))
	# The seabed the water reads its shore from.
	if _sea != null:
		_sea.refresh_seabed(studs)
	# The AI caches the ground per column; this drops the cache.
	ai_world.set_terrain_ground(true)
	ai_nav.invalidate_box(AABB(Vector3(studs.position.x * STUD, -100.0, studs.position.y * STUD),
			Vector3(studs.size.x * STUD, 400.0, studs.size.y * STUD)))


## Where the ground is under (x, z): the field on terrain, 0 on the plane.
func _ground_y(x: float, z: float) -> float:
	return ai_world.ground_at(x, z)


## A point put down on the ground, keeping its x and z.
func _on_ground(p: Vector3) -> Vector3:
	return Vector3(p.x, _ground_y(p.x, p.z), p.z)


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


# ---------------------------------------------------------------------------
# Interiors (Docs/Interiors.md section 8)
# ---------------------------------------------------------------------------


## Is this building coming apart right now -- or its wreckage still coming to
## rest?
##
## No interior and no items are made for a building in that state (user,
## 2026-10-06): walking up to a collapse, or a tower made bricks while it is
## falling, used to have interiors drawn in storeys on their way down --
## furniture popping in mid-air. They are made once it has been still for
## COLLAPSE_QUIET_MS: nothing loose or failing in its solve, and none of its
## pieces (rubble aside) moving. What is drawn already stays, and goes with
## the floor it stands on (_groups_floor_went).
const COLLAPSE_QUIET_MS := 2000
var _broke_ms := {}   ## building id -> msec its solve last had something loose, failing or unbalanced
var interior_waits := 0   ## storey groups not made, a pass at a time, because of _mid_collapse
var _touched_ms := {}     ## building id -> when its bricks last changed (_mark_dirty)


## Hit, and not yet known to be standing: its bands still building (nothing
## leaves it until they are), its floors' reach not asked yet (_span_owed), or
## hit within COLLAPSE_QUIET_MS. No storey group is made for it meanwhile.
## Damage does not change how an interior is drawn (Docs/DestructionLod.md
## 1.2): a building shot from 40 m made bricks, drew its rooms, and then the
## span rule cut it and it fell -- "when a building takes any damage it spawns
## everything inside then starts to fall" (user, 2026-10-19).
func _interior_unsure(id: int) -> bool:
	# The switch off is interiors made whatever the building is doing, as they
	# were (hold_interiors_mid_collapse): far_rules_probe's case without the
	# rule, which has to draw them.
	if not hold_interiors_mid_collapse:
		return false
	if _mid_collapse(id) or _bands_building(id) or _span_owed.has(id):
		return true
	return Time.get_ticks_msec() - int(_touched_ms.get(id, -1000000)) < COLLAPSE_QUIET_MS
## Off: interiors are made in a building whatever it is doing, as they were.
## For far_rules_probe, which has to fail without the rule.
var hold_interiors_mid_collapse := true

## Interiors are drawn a group of storeys at a time (InteriorGroups;
## Docs/Interiors.md section 8): one drawing of a group's interior pieces and
## one of its items, shown and faded by distance alone.
var interior_groups := InteriorGroups.new()
## InteriorGroups.key_of(building, group) -> that group's shapes on its
## building's furniture body (_room_body): one box per interior piece, for the
## groups the player is near.
var _group_shapes := {}
var _pieces_hit := 0        ## interior pieces a blast reached, all told
var _pieces_laid := 0       ## and of those, the ones laid as bricks (somebody could see)
var _pieces_hit_ms := 0.0
var _group_covers := 0     ## times a group's boxes were put on or taken off a body
## Pieces drawn on the section that took their floor, riding it down:
## [BrickIsland, MultiMeshInstance3D]. See _groups_floor_went.
var _group_riders: Array = []
## The view switches (DebugView): a sweep is owed -- something was switched --
## and the frame the last one ran.
var _view_owed := false
var _view_frame := 0
var _view_mode := false
var _group_orphans := 0    ## pieces whose floor went, all told
var _group_rides := 0      ## and of those, the ones that rode a section
var _groups_leaving := false   ## _disable is being told of bricks about to leave, not yet gone


func _mid_collapse(id: int) -> bool:
	if not hold_interiors_mid_collapse:
		return false
	var b := registry.get_building(id)
	if b != null and _toppling.has(id) and not b.toppled:
		return true
	if director.holding(id):
		return true
	# Hit since it was last solved: nobody knows yet whether it is coming apart.
	# The solve is a tick away, and a room or a storey group made in that tick
	# was made in a tower already cut through (--groups: one group, every run).
	# Only where solves happen -- a machine that does not decide never empties
	# the list.
	if authority.may_decide() and _dirty.has(id):
		return true
	if Time.get_ticks_msec() - int(_broke_ms.get(id, -1000000)) < COLLAPSE_QUIET_MS:
		return true
	if islands.moving_of(id) > 0:
		# Still falling: the quiet starts when the last of it has stopped.
		_broke_ms[id] = Time.get_ticks_msec()
		return true
	return false


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
var _furniture_ms := 0.0
var _furniture_calls := 0


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
	# Furniture holds nothing up (Layers.FIXTURE). It was STRUCTURE, so a
	# section of the building coming down landed on a drawn table or cupboard --
	# static, unbreakable -- and hung there inside the building (user report,
	# 2026-10-02). Walkers and bullets still meet it; wreckage goes through.
	PhysicsServer3D.body_set_collision_layer(body, Layers.FIXTURE)
	PhysicsServer3D.body_set_collision_mask(body, Layers.FIXTURE_MASK)
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
	_spare_shapes.erase(id)
	for g in interior_groups.known(id):
		_group_shapes.erase(InteriorGroups.key_of(id, g.index))
		g.cover = false


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


## Draw, refresh and drop the storey groups round the player (InteriorGroups;
## Docs/Interiors.md 8.2). The rungs' pass, with one rule in place of three.
##
## A group is wanted while its storeys are within INTERIOR_RANGE of the camera,
## in a building that is standing, is bricks and has its mesh. A wanted group
## that is not shown is worked out and shown; a shown one that something
## changed is worked out again; one out of range is dropped. Nearest first,
## under one clock (InteriorGroups.BUDGET_MS).
##
## Two things from Docs/CollapseNext.md 1.8 hold here as they do for the rungs:
## nothing NEW is drawn in a building that is coming apart (_mid_collapse) --
## what is drawn already is still redrawn, which only ever takes pieces away --
## and a building that has come down has no groups at all.
##
## Collision is for what the player is near: a group within ROOM_RANGE and a
## storey of the camera's height has one box per interior piece on the
## building's furniture body, as the drawn rung's rooms had.
func _stream_groups(here: Vector3) -> void:
	var groups := interior_groups
	if groups.world == null:
		groups.world = world
		groups.registry = registry
	var reach := InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE
	var storey_m := float(TowerRecipe.STOREY_PLATES) * PLATE
	var todo: Array = []     # [distance, building, group]
	var covers: Array = []   # [building id, group, wanted]
	var near := {}
	for id in _near_buildings(here, reach):
		var b := registry.get_building(id)
		if b == null or not b.is_materialised() or b.is_build() or b.toppled:
			continue
		if not _brick_nodes.has(id):
			continue   # demeshed: nothing to hang a drawing from
		near[id] = true
		var parent: Node3D = _brick_nodes[id]
		var local: Vector3 = b.xform.affine_inverse() * here
		var held := -1   # mid-collapse? Asked once, and only if something is new.
		for g in groups.layout(b):
			var d := _box_distance(g.box, local)
			if d > (reach if g.shown else InteriorGroups.INTERIOR_RANGE):
				if g.shown:
					_group_cover(id, g, false)
					groups.release(id, g)
				continue
			if not g.shown:
				if held < 0:
					held = 1 if _interior_unsure(id) else 0
				if held == 1:
					interior_waits += 1
					continue
				g.shadows = d <= InteriorGroups.SHADOW_RANGE
				todo.append([d, b, g])
				continue
			if g.dirty or g.changed or not groups.nodes_ok(id, g, parent):
				todo.append([d, b, g])
			groups.set_shadows(id, g, d <= (InteriorGroups.SHADOW_RELEASE if g.shadows
					else InteriorGroups.SHADOW_RANGE))
			var gap := maxf(maxf(g.box.position.y - local.y, local.y - g.box.end.y), 0.0)
			var want: bool = (d <= (ROOM_SLEEP_RANGE if g.cover else ROOM_RANGE)
					and gap <= storey_m * float(ROOM_STOREY_SPAN) * (2.0 if g.cover else 1.0))
			# Boxes from a drawing that is behind would be boxes for pieces that
			# have gone: it waits for the group to be current.
			if want != g.cover and (not want or not g.dirty):
				covers.append([id, g, want])
			elif want and g.cover_stale and not g.dirty:
				covers.append([id, g, true])   # a piece has gone: its box with it
	todo.sort_custom(func(a, c) -> bool: return float(a[0]) < float(c[0]))
	var until := Time.get_ticks_usec() + int(InteriorGroups.BUDGET_MS * 1000.0)
	var first := true
	for entry in todo:
		if not first and Time.get_ticks_usec() >= until:
			break
		first = false
		var b: BuildingRegistry.Building = entry[1]
		var g: InteriorGroups.Group = entry[2]
		if not groups.work(b, g, until):
			break   # the clock ran out inside it: the rest of it next pass
		_group_show(b, g)
	for c in covers:
		_group_cover(int(c[0]), c[1], bool(c[2]))
	for id in groups.known_ids():
		if not near.has(id):
			_drop_groups(id)
	_stream_pieces(here)
	_groups_tend_riders()


## A piece smaller than this carries no interior drawing: it is rubble, and a
## floor that small has nothing standing on most of it.
const PIECE_INTERIOR_BLOCKS := 24
var _pieces_owed := 0   ## piece drawings wanted and not yet up to date, as of the last pass
var _pieces_pass := 0   ## passes run: a piece's bricks are counted again every eighth


## Give the still pieces of buildings near the player their interiors
## (InteriorGroups.piece_work; Interiors.md 8.3).
##
## A collapsed building is not empty: what stood on a floor is on that floor,
## wherever it came to rest. Which pieces get a drawing is the user's rule for
## wreckage (CollapseNext.md 1.8): **nothing until somebody is near** -- inside
## the range a standing building's interior is drawn at, fading the same way --
## and **nothing new on a piece that is still moving**. A piece that has a
## drawing keeps it if it is knocked again, worked out afresh when its bricks
## change (it can only lose things), and loses it past the range, or when it
## breaks up (its parts get their own once they are still), sleeps or goes.
## Nearest first, on what is left of the groups' clock.
func _stream_pieces(here: Vector3) -> void:
	var groups := interior_groups
	var reach := InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE
	var todo: Array = []
	var live := {}
	for isl in islands.islands:
		if not isl.is_valid() or isl.owner < 0 or isl.mesh == null:
			continue
		var have: InteriorGroups.PieceDraw = groups.piece(isl.chunk)
		if have == null and not isl.settled:
			continue   # still coming down: nothing new
		var d := maxf(isl.body.global_position.distance_to(here) - isl.radius, 0.0)
		if d > (reach if have != null else InteriorGroups.INTERIOR_RANGE):
			continue   # dropped below, with every other drawing not kept
		var b := registry.get_building(isl.owner)
		if b == null or b.is_build():
			continue
		if have == null and world.get_alive_block_count(isl.chunk) < PIECE_INTERIOR_BLOCKS:
			continue
		live[isl.chunk] = true
		# Its bricks counted again every eighth pass (half a second), each piece
		# on its own pass: an edit count that did not move is not proof that
		# nothing left it.
		var alive := have.alive if have != null else -1
		if have != null and (isl.chunk + _pieces_pass) % 8 == 0:
			alive = world.get_alive_block_count(isl.chunk)
			if have.shown and groups.piece_gone_sum(have) != have.gone_sum:
				have.dirty = true   # something in its rooms was crushed or blasted
		if have == null or not have.shown or have.dirty or have.edits != isl.edits 				or have.alive != alive:
			todo.append([d, isl, b])
	for chunk in groups.piece_chunks():
		if not live.has(chunk):
			groups.piece_drop(chunk)
	_pieces_pass += 1
	_pieces_owed = todo.size()
	if todo.is_empty():
		return
	todo.sort_custom(func(a, c) -> bool: return float(a[0]) < float(c[0]))
	var cs := BrickWorld.get_cell_size()
	var until := Time.get_ticks_usec() + int(InteriorGroups.BUDGET_MS * 500.0)
	var first := true
	for entry in todo:
		if not first and Time.get_ticks_usec() >= until:
			break
		first = false
		var isl: BrickIsland = entry[1]
		# The piece's box in cells: the building's grid, which it kept.
		var box: AABB = islands._island_aabb(isl)
		var origin: Vector3i = world.get_chunk_origin(isl.chunk)
		var lo := Vector3i((box.position / cs).floor()) + origin - Vector3i.ONE
		var hi := Vector3i((box.end / cs).ceil()) + origin + Vector3i.ONE
		if groups.piece_work(entry[2], isl.chunk, lo, hi, isl.edits, isl.mesh, until,
				world.get_alive_block_count(isl.chunk)):
			_pieces_owed -= 1
			var p: InteriorGroups.PieceDraw = groups.piece(isl.chunk)
			if p != null and p.laid > 0:
				# Its furniture is bricks now: drawn, solid, counted. Asked
				# again only when something else changes it.
				islands.rebuild_chunk(isl.chunk)
				p.laid = 0
				p.edits = isl.edits
				p.alive = world.get_alive_block_count(isl.chunk)
				p.gone_sum = groups.piece_gone_sum(p)
		else:
			break


## Bricks of `b` inside `box` (its chunk's own space) have just been destroyed
## or have left it. Every piece of its storey groups there with nothing under
## it now is out of the building this tick (InteriorGroups.check_floors) --
## and when its floor left as a section (`came`), it is drawn on that section
## and rides it down. [Interiors §8.3](../Docs/Interiors.md).
##
## What rides is a drawing, as it was in the building: it holds nothing and
## nothing lands on it. It is taken off when the section lands or breaks up
## (_groups_tend_riders) -- the fall is what destroyed it, and its room's
## record has said so since the moment it left.
func _groups_floor_went(b: BuildingRegistry.Building, box: AABB,
		came: BrickIsland = null) -> void:
	if interior_groups.known(b.id).is_empty():
		return
	var orphans := interior_groups.check_floors(b, box.position.y, box.end.y)
	if orphans.is_empty():
		return
	_group_orphans += orphans.size()
	if came == null or not came.is_valid() or came.mesh == null \
			or not is_instance_valid(came.mesh):
		return
	# From the building chunk's space into the section's, as the two stand this
	# tick: the section has not moved yet.
	var into: Transform3D = world.get_chunk_transform(came.chunk).affine_inverse() \
			* world.get_chunk_transform(b.chunk)
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = world.get_chunk_origin(came.chunk)
	var rows := PackedFloat32Array()
	var riding := 0
	for o in orphans:
		var piece: AABB = o.box
		if piece.size == Vector3.ZERO:
			continue
		# Is its floor in THIS section? Half a plate under its foot, at the
		# middle and toward each corner.
		var carried := false
		for f in [Vector2(0.5, 0.5), Vector2(0.15, 0.15), Vector2(0.85, 0.15),
				Vector2(0.15, 0.85), Vector2(0.85, 0.85)]:
			var under: Vector3 = into * Vector3(piece.position.x + piece.size.x * f.x,
					piece.position.y - cs.y * 0.5, piece.position.z + piece.size.z * f.y)
			if world.is_solid(came.chunk, Vector3i((under / cs).floor()) + origin):
				carried = true
				break
		if not carried:
			continue   # destroyed under it, or gone with another section
		rows.append_array(o.rows)
		rows.append_array(o.details)
		riding += 1
	if rows.is_empty():
		return
	_rider_add(came, rows, into)
	_group_rides += riding


## Draw `rows` (a building chunk's own space) on a piece, taken into the
## piece's space by `into`: what rides it.
func _rider_add(isl: BrickIsland, rows: PackedFloat32Array, into: Transform3D) -> void:
	if isl == null or not isl.is_valid() or isl.mesh == null or not is_instance_valid(isl.mesh):
		return
	@warning_ignore("integer_division")
	var n := rows.size() / FurnitureMesh.STRIDE
	if n == 0:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = FurnitureMesh.unit_mesh()
	mm.instance_count = n
	for r in n:
		var at := r * FurnitureMesh.STRIDE
		# A row is the basis by rows with the origin at the end of each.
		mm.set_instance_transform(r, into * Transform3D(
				Basis(Vector3(rows[at], rows[at + 4], rows[at + 8]),
					Vector3(rows[at + 1], rows[at + 5], rows[at + 9]),
					Vector3(rows[at + 2], rows[at + 6], rows[at + 10])),
				Vector3(rows[at + 3], rows[at + 7], rows[at + 11])))
		mm.set_instance_color(r, Color(rows[at + 12], rows[at + 13], rows[at + 14], rows[at + 15]))
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = InteriorGroups.piece_material()
	DebugView.tag(node, DebugView.Kind.INTERIOR)
	isl.mesh.add_child(node)
	_group_riders.append([isl, node])


## Forget riders whose piece has gone -- broken up, crumbled, put to sleep --
## and take one off a piece that has a drawing of its own now (_stream_pieces:
## the same things, worked out from the piece instead of carried over). Until
## then it stays where it is: a section that lands whole keeps its furniture.
func _groups_tend_riders() -> void:
	var k := 0
	while k < _group_riders.size():
		var isl: BrickIsland = _group_riders[k][0]
		var node = _group_riders[k][1]
		var own: InteriorGroups.PieceDraw = interior_groups.piece(isl.chunk) \
				if isl != null and isl.is_valid() else null
		if node != null and is_instance_valid(node) and isl != null and isl.is_valid() \
				and (own == null or not own.shown):
			k += 1
			continue
		if node != null and is_instance_valid(node):
			(node as Node).queue_free()
		_group_riders.remove_at(k)


## Put a worked-out group on screen, or refresh what it shows, and its
## collision boxes with it if it has any.
func _group_show(b: BuildingRegistry.Building, g: InteriorGroups.Group) -> void:
	if not _brick_nodes.has(b.id):
		return
	var parent: Node3D = _brick_nodes[b.id]
	if g.shown and not g.changed and interior_groups.nodes_ok(b.id, g, parent):
		return
	interior_groups.attach(b, g, parent)
	if g.cover and g.cover_stale:
		_group_cover(b.id, g, true)


## Give a group's interior pieces their collision boxes, or take them away.
## One box a piece, on the building's furniture body,
## in the slots closed rooms and dropped groups left (_take_shape). Asked again
## for a group that has them, it replaces them: the pieces have changed.
func _group_cover(id: int, g: InteriorGroups.Group, on: bool) -> void:
	var key := InteriorGroups.key_of(id, g.index)
	var have: PackedInt32Array = _group_shapes.get(key, PackedInt32Array())
	if not on and (have.is_empty() or not _room_bodies.has(id)):
		_group_shapes.erase(key)
		g.cover = false
		return
	var body := _room_body(id)
	if not body.is_valid():
		return
	PhysicsServer3D.body_set_space(body, RID())
	var spare: PackedInt32Array = _spare_shapes.get(id, PackedInt32Array())
	for shape in have:
		PhysicsServer3D.body_set_shape_disabled(body, shape, true)
		spare.push_back(shape)
	_spare_shapes[id] = spare
	var mine := PackedInt32Array()
	if on:
		for room_boxes in g.boxes:
			for box in (room_boxes as Array):
				if (box as AABB).size == Vector3.ZERO:
					continue   # its piece has gone (InteriorGroups.check_floors)
				mine.push_back(_take_shape(id, body, (box as AABB).size,
						Transform3D(Basis(), (box as AABB).position + (box as AABB).size * 0.5)))
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	if mine.is_empty():
		_group_shapes.erase(key)
	else:
		_group_shapes[key] = mine
	g.cover = on
	g.cover_stale = false
	_group_covers += 1


## Collision for items just laid as bricks one at a time (BuildingRegistry.
## lay_item): a box a block on the building's furniture body, so each goes
## when its block does (_disable).
## `laid` is [[room index, item index], ...].
func _add_item_shapes(id: int, laid: Array) -> void:
	var b := registry.get_building(id)
	if b == null or laid.is_empty() or not _brick_cols.has(id):
		return
	var body := _room_body(id)
	if not body.is_valid():
		return
	var map: Dictionary = _room_shapes.get(id, {})
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	PhysicsServer3D.body_set_space(body, RID())
	for pair in laid:
		var room := registry.get_room(id, int(pair[0]))
		if room == null:
			continue
		var item: Dictionary = room.items[int(pair[1])]
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
	PhysicsServer3D.body_set_space(body, get_world_3d().space)


## Everything the groups hold for one building: its drawings, and its boxes
## off the furniture body.
func _drop_groups(id: int) -> void:
	for g in interior_groups.known(id):
		if g.cover:
			_group_cover(id, g, false)
	interior_groups.drop(id)


## The room indices of a building's shown groups that reach into `local_box`
## (the building's own space).
func _group_rooms_in(b: BuildingRegistry.Building, local_box: AABB) -> Array:
	var out: Array = []
	for g in interior_groups.known(b.id):
		if g.shown and (g.box as AABB).grow(0.5).intersects(local_box):
			out.append_array(range(g.first_room, g.last_room))
	return out


## Rooms of a building changed (a piece crushed): their groups are worked out
## and shown again now, not at the next pass. Only the rooms that changed are
## worked out; the rest of each group is a concatenation.
func _groups_refresh(b: BuildingRegistry.Building, room_indices: Array) -> void:
	for g in interior_groups.known(b.id):
		if not g.shown:
			continue
		var mine := false
		for index in room_indices:
			if int(index) >= g.first_room and int(index) < g.last_room:
				mine = true
				break
		if not mine:
			continue
		g.dirty = true
		interior_groups.work(b, g, Time.get_ticks_usec() + 1000000)
		_group_show(b, g)


## Rooms between these heights were laid as bricks or written off (a blast):
## the shown groups there drop them from their drawings now. Only the rooms
## that moved are worked out -- none of them draws anything -- unless the group
## was owed a full walk already, which the clock then cuts short.
func _groups_rooms_moved(b: BuildingRegistry.Building, y_lo: float, y_hi: float) -> void:
	for g in interior_groups.known(b.id):
		if not g.shown or g.box.position.y > y_hi or g.box.end.y < y_lo:
			continue
		g.dirty = true
		interior_groups.work(b, g, Time.get_ticks_usec() + 2000)
		_group_show(b, g)


## The far tier: a shell mesh and five boxes. No bricks anywhere.
## `coarse` picks the far-far tier: a box and a cap instead of a course-banded
## hollow shell. Same collision either way, because a building you can see is a
## building you can shoot, however few triangles it is drawn with.
##
## `far` is a shell past SHELL_RANGE: drawn, but with no body. Out there a shot
## resolves against recipes (_ray_recipes), as it does for any far building.
## Only a building the far MultiMesh cannot draw truthfully gets one -- see
## _needs_far_shell.
func _make_shell(id: int, coarse: bool = false, far: bool = false) -> void:
	var b := registry.get_building(id)
	# Damage has to show at any distance a shell is drawn (Docs/Collapse.md
	# 2.3); a tower with its top blown off was once drawn whole from 110 m out.
	# The far box shows a recipe building's damage profile, so that building
	# can take the coarse tier damaged or not. The old coarse MESH is a plain
	# box and cannot, so what still needs it -- a build, or a building whose
	# damage is in live bricks rather than a profile -- stays banded.
	var boxed := coarse and _far_draws_coarse(b)
	# Nor a recipe building still in bricks (_demesh), damaged or not: the far
	# box will not draw it, and the coarse mesh is an untextured box -- every
	# tower walked past and left behind stood there as a plain white block,
	# with no courses and no windows, until the camera came back.
	coarse = coarse and (boxed or (b.is_build() and not b.is_damaged()))
	# A building still in bricks -- its mesh given up at range (_demesh) --
	# draws the damage its bricks have NOW. Its profile is only brought up to
	# date when it gives its bricks back (dematerialise), so the shell standing
	# in for it drew what it looked like before: a tower with its top blown off
	# came back whole past DEMESH_RANGE, windows and all, and went again inside
	# it -- "respawning" as the camera moved. One with no bricks left draws
	# nothing.
	var t_sh := Time.get_ticks_usec()
	var damage: Dictionary = b.damage_profile
	var nothing_left := false
	if b.is_materialised() and not b.is_build():
		damage = registry.live_damage_profile(id)
		nothing_left = world.get_alive_block_count(b.chunk) == 0 and not registry.is_partial(b)
	t_sh = _part("sh_profile", t_sh)
	var mi := MeshInstance3D.new()
	# G1b: a damaged building that has given its bricks back must still LOOK
	# damaged. A tower takes that as a per-band segment mask, because its shell
	# is generated from parameters and cannot ask "is block N dead"; a BUILD's
	# shell is generated from its recipe and asks exactly that, so its damage is
	# exact rather than approximate (Docs/BuildMode.md section 12, question 3).
	if boxed:
		# Drawn by its far box (Docs/Impostors.md Stage 2): the node stays so
		# every "has a shell" question still has its answer, with no mesh and
		# so no draw call of its own.
		_shell_box[id] = true
	elif _inst_ok(b) and _inst_near(b):
		# Drawn by its instanced set (a tree): the same, for the same reason.
		_shell_inst[id] = true
	elif b.is_build():
		mi.mesh = BuildShell.build_mesh(world, b.build, _dead_by_frame(b), coarse)
	elif nothing_left:
		pass  # the node, for every "has a shell" question; nothing drawn
	else:
		mi.mesh = _recipe_shell_mesh(b, coarse, damage)
	t_sh = _part("sh_mesh", t_sh)
	mi.material_override = brick_material
	mi.transform = b.xform
	# Stage 5: a banded shell fades out over the fade band, blended over its
	# far box drawn whole beneath it (city_far.gdshader), so the swap at
	# SHELL_DETAIL_RANGE is a blend rather than a pop.
	var fades := not coarse and not b.is_build() and not b.is_materialised()
	if fades:
		_fade_out(mi)
	add_child(mi)
	_shells[id] = mi
	_shell_coarse[id] = coarse
	# Damaged and still in bricks (_demesh): drawn from its bricks as they are
	# once a coarse mesh of them is made (_far_real); the shell meanwhile. Laid
	# a storey at a time too: its bricks are the laid storeys, and its rest
	# shell draws the others beside them (_rest_drawn). Left to the shell, its
	# damage was the profile's -- a hole per band, the floors drawn across it
	# from 110 m out (CollapseNext 29(a), --lodbreak's ghost walls: 14-31 of
	# 337-355 hits on the 320 m tower).
	var real := b.is_materialised() and not b.is_build() and not nothing_left and not boxed \
			and not damage.is_empty() and not _toppling.has(id)
	if real:
		_far_real(id, mi)
	t_sh = _part("sh_real", t_sh)
	# Its windows, with a room painted behind each: a shell has no openings, so
	# the fake rung cannot show through it. Not on the coarse tier -- past a
	# hundred metres a window is a pixel -- and not on a player build, which
	# has no recipe windows. A child of the shell, so it goes when the shell
	# does, and with its own material so the brick material is untouched.
	# Owed, not built here: _build_owed_glass makes them a tick or two later,
	# nearest first, on a worker.
	# A damaged one drawn from its bricks (`real`) gets them too, each pane
	# only where its window still stands in the bricks (Docs/Structures.md
	# 4.2, the faked state): it used to get none, and past DEMESH_RANGE a
	# damaged building was the one building with empty black windows.
	if not coarse and not b.is_build() and not nothing_left:
		_glass_owed.append([mi, id, {} if real else damage, fades, real])
	# A shell and a far box would be the same building drawn twice -- unless
	# the far box IS this shell's drawing. So would a shell and a tree's copy.
	_far_sync(b)
	_inst_sync(b)
	if far:
		_shell_far[id] = true
		return
	_make_shell_body(id)
	_part("sh_body", t_sh)


## The collision boxes of a shell, and the AI's proxies of them.
## A shell's windows -- panes with a room painted behind each -- are built
## apart from the shell: a tall tower's are 1-10 ms, as much again as its
## shell, and a city streaming in made four shells and their windows in one
## tick, 33 ms (2026-10-15). A shell stands a tick or two without its glass --
## solid bands where the panes go, at a shell's distance.
##
## Built on workers (BuildingShell.window_arrays), GLASS_JOBS at a time, the
## nearest owed first; the main thread only turns the arrays into a mesh and
## hangs it on the shell. On the main thread it was 2.7 ms every tick of a
## bench over an 800-building city, 10 ms at worst (2026-10-18), and most of
## it for shells the streamer was about to take back: so a shell past the
## line where its banded tier is swapped for the coarse one waits (kept owed,
## not built) until it is either replaced -- its successor owes its own -- or
## near again. A shell drawn from its bricks (`real`) asks the bricks about
## each pane: a copy of which cells stand (BuildingShell.standing_copy), so it is made on a
## worker as well (it was built here, 3-8 ms a tick; PerfCaps.md 4).
const GLASS_JOBS := 4
var _glass_owed: Array = []   ## [shell node, building id, damage, fades, drawn from its bricks]
var _glass_jobs: Array = []   ## [task, [arrays], shell node, building id, fades]
var glass_built := 0


## What the glass cost the main thread (the exit report's "[prof] glass"): a
## tick's _build_owed_glass, summed over every tick it ran and the worst one.
## On the main thread it was 2.7 ms a tick, 10 ms at worst (above).
var _glass_usec := 0
var _glass_ticks := 0
var _glass_worst_usec := 0
## Of it: the worst worker result turned into a mesh and hung, and the worst
## window built here from the live bricks (a shell drawn from its bricks).
var _glass_hang_worst_usec := 0


func _glass_note(usec: int) -> void:
	_glass_usec += usec
	_glass_ticks += 1
	_glass_worst_usec = maxi(_glass_worst_usec, usec)


func _build_owed_glass() -> void:
	# Land what the workers finished.
	for i in range(_glass_jobs.size() - 1, -1, -1):
		var job: Array = _glass_jobs[i]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		_glass_jobs.remove_at(i)
		var gm = job[1][0]
		if gm is Array:
			gm = BuildingShell.window_mesh_of(gm)   # headless: made here (worker_meshes)
		if gm == null or not is_instance_valid(job[2]) \
				or not _is_shell_node(int(job[3]), job[2]):
			continue
		var t_hang := Time.get_ticks_usec()
		_hang_glass(job[2], gm, job[4])
		_glass_hang_worst_usec = maxi(_glass_hang_worst_usec, Time.get_ticks_usec() - t_hang)
	if _glass_owed.is_empty():
		return
	# The owed, nearest first; the gone dropped, the about-to-go kept back.
	var here := camera.global_position if camera != null else Vector3.ZERO
	var swap_at := SHELL_DETAIL_RANGE + SHELL_HYSTERESIS
	var live: Array = []
	var due: Array = []   ## [distance, index into live]
	for owed in _glass_owed:
		var mi = owed[0]
		var id: int = owed[1]
		# Replaced or freed since -- its successor owes its own.
		if not is_instance_valid(mi) or not _is_shell_node(id, mi):
			continue
		var b := registry.get_building(id)
		if b == null:
			continue
		live.append(owed)
		var dist := b.xform.origin.distance_to(here)
		if dist <= swap_at:
			due.append([dist, live.size() - 1])
	_glass_owed = live
	if due.is_empty():
		return
	due.sort_custom(func(a: Array, c: Array) -> bool: return float(a[0]) < float(c[0]))
	var taken := {}
	for r in due:
		var owed: Array = _glass_owed[int(r[1])]
		if _glass_jobs.size() < GLASS_JOBS:
			_submit_glass(owed)
			taken[int(r[1])] = true
	if not taken.is_empty():
		var left: Array = []
		for i in _glass_owed.size():
			if not taken.has(i):
				left.append(_glass_owed[i])
		_glass_owed = left


func _submit_glass(owed: Array) -> void:
	var id: int = owed[1]
	var b := registry.get_building(id)
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var room_seed := registry.room_seed_of(id)
	# Made here, where the caches they come from are filled; the worker only
	# reads them. Its own copies of the rest, which this thread may change.
	var layout := TowerRecipe.layout(courses)
	var lattice := RoomManifest.lattice_for(fx, fz, courses)
	var damage: Dictionary = (owed[2] as Dictionary).duplicate(true)
	var program: Dictionary = (b.recipe.get("program", {}) as Dictionary).duplicate(true)
	# A window still in bricks asks the bricks which panes stand: a copy of
	# them, made here (it was the whole build here, 3-8 ms a tick, PerfCaps.md 4).
	var standing := Callable()
	if owed[4] and b.is_materialised():
		standing = BuildingShell.standing_copy(world, b.chunk,
				BuildingShell.window_rows(courses, layout, lattice))
	# The mesh is made there too: handed to the renderer here, it waited for
	# whatever else was being uploaded.
	var holder := [null]
	var on_worker := worker_meshes
	var task := WorkerThreadPool.add_task(func() -> void:
		var arrays := BuildingShell.window_arrays(fx, fz, courses, room_seed, layout,
				lattice, damage, program, standing)
		if not arrays.is_empty():
			holder[0] = BuildingShell.window_mesh_of(arrays) if on_worker else (arrays as Variant)
			UploadLedger.note("glass", UploadLedger.verts_of(arrays)),
			true, "shell glass")
	glass_built += 1
	_glass_jobs.append([task, holder, owed[0], id, owed[3]])


func _hang_glass(mi: MeshInstance3D, panes: Mesh, fades: bool) -> void:
	# One set a shell: a shell drawn from its bricks has its panes asked again
	# after a hit (_refresh_real_shell), and the old set goes as the new hangs.
	for c in mi.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).material_override == BuildingShell.window_material():
			_retirer.retire((c as MeshInstance3D).mesh)
			c.queue_free()
	var glass := MeshInstance3D.new()
	glass.mesh = panes
	glass.material_override = BuildingShell.window_material()
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if fades:
		_fade_out(glass)
	mi.add_child(glass)


## Is this cell of a building's own grid (cells from its corner) a brick?
## BuildingShell's question of a window still in bricks.
func _cell_standing(cell: Vector3i, chunk: int, origin: Vector3i) -> bool:
	return world.is_solid(chunk, origin + cell)


## The shaders the first fight would otherwise have built in the middle of it,
## built at load instead, as InteriorGroups.warm does its own: a speck far under
## the world with each, for a second. The loose bricks' and the furniture's are
## one StandardMaterial3D shader with vertex colour (FurnitureMesh.material, the
## crumbs, the heap, single loose bricks), and whichever of them came first
## built it -- 14 ms, in the tick of the first blast that laid a room's
## furniture (2026-10-15). A collapse's dust is another.
func _warm_shaders() -> void:
	# The shells' window panes too: the first pane hung loaded and built their
	# shader, 17.7 ms in one tick of a --stress run (2026-10-21).
	var specks := [[FurnitureMesh.unit_mesh(), FurnitureMesh.material()],
			[CollapseDust._quad(), null],
			[FurnitureMesh.unit_mesh(), BuildingShell.window_material()]]
	for speck in specks:
		var mi := MeshInstance3D.new()
		mi.mesh = speck[0]
		if speck[1] != null:
			mi.material_override = speck[1]
		mi.position = Vector3(0.0, -2000.0, 0.0)
		mi.scale = Vector3.ONE * 0.001
		mi.extra_cull_margin = 16384.0   # drawn wherever the camera looks
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		get_tree().create_timer(1.0).timeout.connect(mi.queue_free)
	# A collapse's dust is GPU particles, whose process shader is its own.
	CollapseDust.puff(self, Vector3(0.0, -2000.0, 0.0), 1.0)


## A recipe building's shell mesh. An undamaged one is the same mesh for every
## building of its footprint, height and tier, so it is built once and shared:
## a tower's banded shell is 1-8 ms of the main thread, and a city repeats its
## designs -- the big city's twelve towers are six, and the first tick it
## streamed in made four of them, 33 ms (2026-10-15). A damaged one is its own.
## Shared is safe: a shell's mesh is never edited, only replaced.
var _shell_meshes := {}   ## Vector4i(x, z, courses, coarse) -> ArrayMesh
var shell_meshes_shared := 0


func _recipe_shell_mesh(b: BuildingRegistry.Building, coarse: bool, damage: Dictionary) -> Mesh:
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	if not coarse and not damage.is_empty():
		return BuildingShell.build_mesh(fx, fz, courses, damage)
	var key := Vector4i(fx, fz, courses, 1 if coarse else 0)
	if _shell_meshes.has(key):
		shell_meshes_shared += 1
		return _shell_meshes[key]
	var mesh: Mesh = BuildingShell.build_coarse_mesh(fx, fz, courses) if coarse \
			else BuildingShell.build_mesh(fx, fz, courses, damage)
	_shell_meshes[key] = mesh
	return mesh


func _make_shell_body(id: int) -> void:
	_shell_far.erase(id)
	var b := registry.get_building(id)
	# No boxes for a building that is bricks already: its bricks collide
	# (see _free_shell_body).
	if _brick_cols.has(id):
		return
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
	PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
	var boxes: Array = (BuildShell.collision_boxes(world, b.build, _dead_by_frame(b))
			if b.is_build() else
			BuildingShell.collision_boxes(b.recipe.footprint_x, b.recipe.footprint_z,
					b.recipe.courses, b.damage_profile.is_empty(), b.damage_profile))
	for box in boxes:
		PhysicsServer3D.body_add_shape(body, _shape_rid(box.size), Transform3D(Basis(), box.pos))
	# The same boxes stand in for the bricks with the AI (AIWorld proxies) while
	# the building has none -- one brick of wall per stud of travel. An AI query
	# never materialises a building (Docs/AI.md 3.2); it asks the shell.
	if not b.is_materialised():
		for k in boxes.size():
			ai_world.set_proxy(_proxy_id(id, k), b.xform * Transform3D(Basis(), boxes[k].pos),
					boxes[k].size, 1.0 / STUD)
		_nav_touch(id)
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
	# Storeys that left as a shell piece are not drawn either (Docs/Space.md 5.3a).
	if b.cut_storey >= 0:
		return registry.build_hidden(b, func(s: int) -> bool: return s < b.cut_storey)
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
##
## Its collision is merged from the start, hit or walk-up, a body a band
## (BuildingCollision): what a hit takes out is merged again without it at the
## end of the tick. One box a brick was 9-15 ms of shapes and 8-10 ms putting
## them in the space for the biggest tower, at every promotion.
func _promote(id: int, solve: bool = true,
		storeys: PackedInt32Array = PackedInt32Array()) -> int:
	var b := registry.get_building(id)
	if b == null:
		return -1
	if b.is_materialised():
		# Laid a storey at a time: the ones asked for that it lacks come in
		# now (Docs/Space.md 5.3a) -- all of them, asked for none.
		if b.banded:
			_lay_more(id, storeys if not storeys.is_empty() else registry.all_storeys(b))
		return b.chunk

	var t0 := Time.get_ticks_usec()
	_promote_parts = {}
	_promote_part_at = t0
	# Past SHELL_RANGE a recipe building has no shell, only its far box, and a
	# promotion hid that box at once: the building was then drawn by however
	# many bands had been built, and anything cut off it fell while bands built
	# from the bricks before the cut went on drawing it standing -- a second
	# copy of every section that came off a building shot from far away. A
	# placeholder now, as any building inside the range has: the far box goes
	# on drawing it and pieces wait for its bands (_bands_done frees it).
	# Before materialise: the far box draws a building that is not bricks yet.
	if not b.is_build() and not b.toppled and not _shells.has(id):
		_make_shell(id, true, true)
	_promote_part("shell")
	var chunk := registry.materialise(id, storeys)
	_promote_part("bricks")
	if chunk < 0:
		return -1  # already toppled: its bricks are an island, not a building
	if b.banded:
		_commit_lay(id, PackedInt32Array())
	world.set_tension_per_stud(chunk, BrickStrength.tension())
	_dress(id, chunk, solve)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_promote_ms += ms
	if ms > float(_promote_worst[0]):
		_promote_worst = [ms, id, _promote_parts.duplicate()]
	if ms > PROMOTE_SLOW_MS and _promote_slow.size() < 64:
		_promote_slow.append([ms, id, _promotions, _promote_parts.duplicate()])
	return chunk


## Time since the last part of this promotion, put down to `part`.
func _promote_part(part: String) -> void:
	var now := Time.get_ticks_usec()
	_promote_parts[part] = float(_promote_parts.get(part, 0.0)) + (now - _promote_part_at) / 1000.0
	_promote_part_at = now


# ---------------------------------------------------------------------------
# Storey units (Docs/Space.md 5.3a)
# ---------------------------------------------------------------------------

## Does a promotion asking for `want` have anything to do: a building not in
## bricks, or one laid a storey at a time that lacks some of them.
func _wants_bricks(b: BuildingRegistry.Building, want: PackedInt32Array) -> bool:
	if not b.is_materialised():
		return true
	if not b.banded or want.is_empty():
		return false
	for s in want:
		if not b.storeys_laid.has(s) and (b.cut_storey < 0 or s < b.cut_storey):
			return true
	return false


## Queue a promotion of `want` (empty: the whole building), at the front for
## one somebody is about to shoot.
func _queue_promotion(id: int, want: PackedInt32Array, first: bool) -> void:
	if first:
		_promote_queue.push_front(id)
	else:
		_promote_queue.append(id)
	if want.is_empty():
		_promote_storeys.erase(id)
	else:
		_promote_storeys[id] = want


## The storeys `what` reaches of building `id` when storey units are on, and
## none (the whole building) when they are off or it is a build.
func _storeys_for(id: int, point: Vector3, radius: float) -> PackedInt32Array:
	var b := registry.get_building(id)
	if b == null or not registry.storey_units \
			or (b.is_build() and not b.build.is_single_frame()):
		return PackedInt32Array()
	return registry.storeys_in(id, point, radius)


var storeys_laid_later := 0
var _lay_more_ms := 0.0
var _lay_more_worst := 0.0


## More storeys of a building laid a storey at a time: laid into its chunk,
## baked again, its bands rebuilt -- each old one drawn until its replacement
## is up -- and the collision of the sections they are in built again. The rest
## shell goes on drawing them until the bands are up (_rest_sync waits).
func _lay_more(id: int, storeys: PackedInt32Array) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not b.banded:
		return
	var t0 := Time.get_ticks_usec()
	var before := b.storeys_laid.duplicate()
	if registry.lay_storeys(id, storeys) == 0:
		return
	_commit_lay(id, before)
	storeys_laid_later += 1
	var fresh := PackedInt32Array()
	for s in b.storeys_laid:
		if not before.has(s):
			fresh.append(s)
	world.bake_chunk_async(b.chunk)
	if not _pending_bricks.has(id) and _brick_nodes.has(id):
		# A promotion still waiting for its bake builds every band anyway.
		_rebuild_bands(id, b.chunk)
		_band_first[id] = true
	_reshape_storeys(id, fresh)
	_refresh_furniture(id)
	_nav_touch(id)
	_mark_dirty(id)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	_lay_more_ms += ms
	_lay_more_worst = maxf(_lay_more_worst, ms)


## The storey commands (DamageLog LAY, UNLAY, GIVE_WAY, SHELL_BRICKS) applied
## to a registry's buildings by a replay: a twin's (_check_log_replays), or this
## city's own when a checkpoint loads. `map` turns a logged building id into
## that registry's, -1 for one not there; `laid` is told each building laid.
func _storey_hooks(rep: StructureReplayer, reg: BuildingRegistry, map: Callable,
		laid := Callable()) -> void:
	rep.on_lay = func(id: int, storeys: PackedInt32Array) -> void:
		var t: int = map.call(id)
		if t < 0:
			return
		reg.materialise(t, storeys)
		if laid.is_valid():
			laid.call(t)
	rep.on_unlay = func(id: int, storeys: PackedInt32Array) -> void:
		var t: int = map.call(id)
		if t < 0:
			return
		if storeys.is_empty():
			reg.dematerialise(t)
			return
		reg.unlay_storeys(t, storeys)
		var ub := reg.get_building(t)
		if ub != null and ub.banded and ub.storeys_laid.is_empty():
			reg.dematerialise(t)
	rep.on_give_way = func(id: int, s: int) -> void:
		var t: int = map.call(id)
		if t >= 0:
			reg.cut_storeys(t, s)
	rep.on_shell_bricks = func(e: DamageLog.Entry) -> int:
		var t: int = map.call(e.target)
		if t < 0 or e.blocks.size() < 2:
			return -1
		return reg.shell_piece_chunk(t, e.blocks[0], e.blocks[1], e.blocks.slice(2),
				DamageLog.rest_transform(e))


## Storeys given back to a building's rest shell, the reverse of _lay_more:
## unlaid in its chunk, the bands rebuilt, their collision taken out -- and the
## rest shell rebuilt AT ONCE, so they are solid and drawn the tick they go (the
## old bands draw their bricks too until each is replaced). A building left
## with none laid is given back whole (_demote).
func _unlay(id: int, storeys: PackedInt32Array) -> void:
	var b := registry.get_building(id)
	if b == null or not b.banded or not b.is_materialised():
		return
	if registry.unlay_storeys(id, storeys) == 0:
		return
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.UNLAY
	e.target = id
	e.blocks = storeys
	authority.commit_entry(e)
	storeys_given_back += storeys.size()
	if b.storeys_laid.is_empty():
		_demote(id, 0.0)
		_materialised.erase(id)
		return
	world.bake_chunk_async(b.chunk)
	if not _pending_bricks.has(id) and _brick_nodes.has(id):
		_rebuild_bands(id, b.chunk)
	_reshape_storeys(id, storeys)
	_refresh_furniture(id)
	_free_rest(id)
	if _rest_wanted(b):
		_make_rest(id, [b.storeys_laid.duplicate(), b.cut_storey])
	_nav_touch(id)
	_mark_dirty(id)


var storeys_given_back := 0
var budget_trims := 0
## Never given back to the budget: a storey somebody is within this of, or one
## laid or hit more recently than BUDGET_QUIET_MS.
const BUDGET_KEEP := 20.0
const BUDGET_QUIET_MS := 3000


## Bricks of buildings in play: a building laid a storey at a time counts what
## is laid, one laid whole all of it.
func bricks_in_play() -> int:
	var n := 0
	for id in _materialised:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		for c in b.chunks():
			n += world.get_block_count(c) - world.get_absent_count(c)
	return n


## The brick budget (Docs/Space.md 5.3): over it, the one unit -- a storey of a
## building laid a storey at a time, or a building laid whole -- that is
## quietest and furthest from everybody goes back to its shell. One a pass. A
## unit somebody is near, or one just laid or hit, is never given back; a
## building toppling, burning, pinned by an encounter or aimed at is left be.
func _trim_budget() -> void:
	if not respawn_buildings or brick_budget <= 0:
		return
	if bricks_in_play() <= brick_budget:
		return
	var now := Time.get_ticks_msec()
	var points := islands.interest_points()
	var best := []   # [distance, id, storey or -1]
	for id in _materialised:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised() or b.toppled or _toppling.has(id) or _pinned(id):
			continue
		if now - int(_aimed_at.get(id, -1000000)) < AIM_KEEP_MS:
			continue
		if now - int(_last_hit.get(id, -1000000)) < BUDGET_QUIET_MS:
			continue
		if world.fire_burning(b.chunk) > 0 or _bands_building(id) or _pending_bricks.has(id):
			continue
		if not b.banded:
			var d := _nearest_to(points, _world_box(b))
			if d > BUDGET_KEEP and (best.is_empty() or d > float(best[0])):
				best = [d, id, -1]
			continue
		var lines := registry.storey_lines(b)
		var cell := BrickWorld.get_cell_size()
		var box := registry.local_box(id)
		for s in b.storeys_laid:
			if now - int(b.storey_laid_at.get(s, 0)) < BUDGET_QUIET_MS:
				continue
			var lb := AABB(Vector3(box.position.x, lines[s] * cell.y, box.position.z),
					Vector3(box.size.x, (lines[s + 1] - lines[s]) * cell.y, box.size.z))
			var wb := AABB(b.xform * lb.position, Vector3.ZERO).expand(b.xform * lb.end)
			var d := _nearest_to(points, wb)
			if d > BUDGET_KEEP and (best.is_empty() or d > float(best[0])):
				best = [d, id, s]
	if best.is_empty():
		return
	budget_trims += 1
	if int(best[2]) < 0:
		_demote(int(best[1]), float(best[0]))
		_materialised.erase(int(best[1]))
	else:
		_unlay(int(best[1]), PackedInt32Array([int(best[2])]))


func _nearest_to(points: PackedVector3Array, box: AABB) -> float:
	if points.is_empty():
		return INF
	var d := INF
	for p in points:
		d = minf(d, _box_distance(box, p))
	return d


## Storeys laid are a command (DamageLog LAY): which are laid changes how the
## building's solves come out, so every machine lays the same ones, in the same
## place in the log. The ones laid now that were not in `before`.
func _commit_lay(id: int, before: PackedInt32Array) -> void:
	var b := registry.get_building(id)
	var fresh := PackedInt32Array()
	for s in b.storeys_laid:
		if not before.has(s):
			fresh.append(s)
	if fresh.is_empty():
		return
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.LAY
	e.target = id
	e.blocks = fresh
	authority.commit_entry(e)


## Build again the collision of the sections that hold these storeys.
func _reshape_storeys(id: int, storeys: PackedInt32Array) -> void:
	var b := registry.get_building(id)
	if b == null or not _brick_cols.has(id) or storeys.is_empty():
		return
	var col: BuildingCollision = _brick_cols[id]
	var lines := registry.storey_lines(b)
	var sp := _section_plates(b.chunk)
	var dims_y: int = world.get_chunk_dims(b.chunk).y
	@warning_ignore("integer_division")
	var layers := maxi((dims_y + sp - 1) / sp, 1)
	var n := col.bodies.size()
	@warning_ignore("integer_division")
	var per_layer := maxi(n / layers, 1)
	var done := {}
	for s in storeys:
		@warning_ignore("integer_division")
		var l0: int = clampi(lines[s] / sp, 0, layers - 1)
		@warning_ignore("integer_division")
		var l1: int = clampi((lines[s + 1] - 1) / sp, 0, layers - 1)
		for layer in range(l0, l1 + 1):
			for k in per_layer:
				var si: int = layer * per_layer + k
				if si < n and not done.has(si):
					done[si] = true
					col.reshape(si, col.merged[si], true)


## The rest shell of a building laid a storey at a time: its storeys still
## whole, drawn and collided with as its shell would, beside the bricks of the
## laid ones. building id -> [MeshInstance3D, body RID, key, proxy count].
var _rest_shells := {}
var rest_shells_made := 0


## A rest shell belongs on every building partly in bricks: its boxes are the
## only collision -- and its proxies the only thing the AI asks -- where the
## storeys are not laid. It is DRAWN only while the bricks are: behind a
## stand-in shell (promoting, or its mesh given up at range) that shell draws
## all of it (_rest_drawn) -- until that shell is drawn from the bricks
## (_far_real), which are only the laid storeys: then it draws the rest again.
func _rest_wanted(b: BuildingRegistry.Building) -> bool:
	return b != null and registry.is_partial(b) and not _toppling.has(b.id)


func _rest_drawn(id: int) -> bool:
	if not _shells.has(id):
		return _brick_nodes.has(id)
	return _far_real_done.get(id) == _shells[id]


func _rest_sync(id: int) -> void:
	var b := registry.get_building(id)
	if not _rest_wanted(b):
		if _rest_shells.has(id):
			_free_rest(id)
		return
	var key := [b.storeys_laid.duplicate(), b.cut_storey]
	if _rest_shells.has(id):
		# Storeys just laid are drawn by it until their bands are up.
		if _rest_shells[id][2] != key and not _bands_building(id):
			_free_rest(id)
			_make_rest(id, key)
	else:
		_make_rest(id, key)
	var mi = _rest_shells[id][0]
	if is_instance_valid(mi):
		(mi as MeshInstance3D).visible = _rest_drawn(id)


func _make_rest(id: int, key: Array) -> void:
	var b := registry.get_building(id)
	var profile := registry.rest_profile(id) if not b.is_build() else {}
	var hidden: Array = []
	if b.is_build():
		# A build's shell walks its blocks: the laid storeys' are left out.
		hidden = registry.build_hidden(b, func(s: int) -> bool:
			return not b.storeys_laid.has(s) and (b.cut_storey < 0 or s < b.cut_storey))
	var mi := MeshInstance3D.new()
	if b.is_build():
		mi.mesh = BuildShell.build_mesh(world, b.build, hidden)
	else:
		mi.mesh = BuildingShell.build_mesh(b.recipe.footprint_x, b.recipe.footprint_z,
				b.recipe.courses, profile)
	mi.material_override = brick_material
	mi.transform = b.xform
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(mi)
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, Layers.STRUCTURE)
	PhysicsServer3D.body_set_collision_mask(body, Layers.STRUCTURE_MASK)
	var boxes: Array = BuildShell.collision_boxes(world, b.build, hidden) if b.is_build() \
			else BuildingShell.collision_boxes(b.recipe.footprint_x, b.recipe.footprint_z,
					b.recipe.courses, false, profile)
	var proxies := 0
	for box in boxes:
		# The shell's ground plate is the bricks' when storey 0 is laid.
		if b.storeys_laid.has(0) and float(box.pos.y) < PLATE:
			continue
		PhysicsServer3D.body_add_shape(body, _shape_rid(box.size), Transform3D(Basis(), box.pos))
		# The AI asks the shell where there are no bricks (Docs/AI.md 3.2).
		if proxies < 64:
			ai_world.set_proxy(_rest_proxy_id(id, proxies),
					b.xform * Transform3D(Basis(), box.pos), box.size, 1.0 / STUD)
			proxies += 1
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, b.xform)
	PhysicsServer3D.body_set_space(body, get_world_3d().space)
	_rest_shells[id] = [mi, body, key, proxies]
	rest_shells_made += 1
	_nav_touch(id)
	# Its windows, as any shell's (_build_owed_glass). A build has none.
	if not b.is_build():
		_glass_owed.append([mi, id, profile, false, false])


func _free_rest(id: int) -> void:
	if not _rest_shells.has(id):
		return
	var r: Array = _rest_shells[id]
	if is_instance_valid(r[0]):
		(r[0] as MeshInstance3D).queue_free()
	PhysicsServer3D.free_rid(r[1])
	for k in int(r[3]):
		ai_world.remove_proxy(_rest_proxy_id(id, k))
	_rest_shells.erase(id)
	_nav_touch(id)
	# Its boxes held whatever lay on them -- a piece, a heap brick -- and the
	# next rest shell, or the bricks laid in its place, may not hold it where
	# it lies: everything resting on the building asks again.
	var b := registry.get_building(id)
	if b != null:
		islands.support_gone(_world_box(b))


## Rest shell proxies have ids of their own: a building's shell's are
## id * 64 + k (_proxy_id), and the two may be up in the same tick.
func _rest_proxy_id(id: int, k: int) -> int:
	return -(id * 64 + k) - 1


## Is this mesh node a shell of building `id` -- its own or its rest shell?
func _is_shell_node(id: int, mi) -> bool:
	if _shells.get(id) == mi:
		return true
	return _rest_shells.has(id) and _rest_shells[id][0] == mi


## Every building in bricks gets its rest shell made, rebuilt or freed as its
## state says, once a tick: cheap, and it keeps the one rule (_rest_wanted) in
## one place rather than at every door a building goes through.
func _tend_rest_shells() -> void:
	for id in _materialised:
		var b := registry.get_building(id)
		if b != null and (b.banded or _rest_shells.has(id)):
			_rest_sync(id)
	for id in _rest_shells.keys():
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			_free_rest(id)


# --- a storey gives way: the rest leaves as a shell piece ---------------------

var _shell_pieces: Array[ShellPiece] = []
var shell_pieces_made := 0
var shell_pieces_bricked := 0   ## shell pieces made bricks


## Everything from storey `s` up has nothing under it: the laid storeys up
## there leave as brick pieces, the rest as ONE shell piece, and the building
## is what is left under it.
func _give_way(id: int, s: int) -> void:
	var b := registry.get_building(id)
	if b == null or not b.banded:
		return
	var lines := registry.storey_lines(b)
	var top: int = lines.size() - 1 if b.cut_storey < 0 else b.cut_storey
	if s >= top:
		return
	var tipping := registry.gave_way_tipping
	var holes := PackedInt32Array()
	for k in b.storeys_laid:
		if k >= s:
			holes.append(k)
	# The bricks up there go as pieces, as any group that lost its hold does.
	var up := world.get_blocks_in_band(b.chunk, lines[s], lines[top])
	var came: BrickIsland = null
	if not up.is_empty():
		_disable(id, up)
		var piece := islands.record_detach(id, null, b.chunk, up, DamageLog.FLAG_CHUNK)
		came = islands.spawn(b.chunk, up, Vector3.ZERO, Vector3.ZERO, piece, id)
		if came != null:
			_note_handover(id, came)
			world.heal_joints(came.chunk)   # one piece until it lands, as a section is
	# What its rooms drew up there has no floor here now: on the bricks that
	# left, it rides them; anywhere else it is out of the drawing.
	_groups_floor_went(b, AABB(Vector3(-1.0, lines[s] * PLATE, -1.0),
			Vector3(1e4, (lines[top] - lines[s]) * PLATE, 1e4)), came)
	# A command: from here every machine solves the building without them.
	authority.commit(Engine.get_physics_frames(), DamageLog.Kind.GIVE_WAY, id, Vector3.ZERO,
			0.0, Vector3.ZERO, s)
	registry.cut_storeys(id, s)
	_refresh_furniture(id)
	_queue_remesh(id)
	var p := ShellPiece.new()
	p.building = id
	p.lo = s
	p.hi = top
	p.holes = holes
	p.transform = b.xform
	add_child(p)
	if not p.shape(registry, brick_material):
		p.queue_free()
	else:
		_shell_pieces.append(p)
		shell_pieces_made += 1
		print("[storeys] building %d: storey %d %s; storeys %d-%d leave as one shell piece (%d laid up there went as bricks)" % [
				id, s - 1, "carries what is over it off to one side: it tips" if tipping
				else "gave way", s, top - 1, holes.size()])
	_nav_touch(id)
	_rest_sync(id)


## A shell piece becomes bricks: ALL of it, laid from the template into a chunk
## of its own with every joint it had, placed where the piece is and let go as
## one brick piece moving as it moved. One piece, as a section is (heal_joints):
## a storey nobody hit is as stiff as LEGO, and what breaks is what the landing
## or the blast breaks -- not a floor at a time.
func _piece_to_bricks(p: ShellPiece) -> BrickIsland:
	var b := registry.get_building(p.building)
	_shell_pieces.erase(p)
	if b == null:
		p.queue_free()
		return null
	var lines := registry.storey_lines(b)
	var xf := p.global_transform
	var _t0 := Time.get_ticks_usec()
	var chunk := registry.shell_piece_chunk(p.building, p.lo, p.hi, p.holes, xf)
	var _t1 := Time.get_ticks_usec()
	var ids := world.get_blocks_in_band(chunk, lines[p.lo], lines[p.hi]) if chunk >= 0 \
			else PackedInt32Array()
	var isl: BrickIsland = null
	if not ids.is_empty():
		# A command, and the piece's id is its place in the log, as a DETACH's
		# piece's is: every machine makes the same piece where the host's is.
		var e := DamageLog.Entry.new()
		e.tick = Engine.get_physics_frames()
		e.kind = DamageLog.Kind.SHELL_BRICKS
		e.target = p.building
		e.limit = lines[p.lo]
		e.radius = float(lines[p.hi])
		e.blocks = PackedInt32Array([p.lo, p.hi])
		e.blocks.append_array(p.holes)
		e.points = DamageLog.rest_points(xf)
		var done := authority.commit_entry(e)
		var piece := DamageLog.piece_id(done.seq) if done != null else -1
		var _t2 := Time.get_ticks_usec()
		isl = islands.spawn(chunk, ids, p.linear_velocity, p.angular_velocity, piece, p.building)
		var _t3 := Time.get_ticks_usec()
		if isl != null and isl.is_valid():
			world.heal_joints(isl.chunk)
		shell_brick_split = "%d bricks, storeys %d-%d, %d ms old: laid %.1f + log %.1f + spawn %.1f (%s) + joints %.1f ms" % [
				ids.size(), p.lo, p.hi - 1, Time.get_ticks_msec() - p.made_at,
				float(_t1 - _t0) / 1000.0, float(_t2 - _t1) / 1000.0,
				float(_t3 - _t2) / 1000.0, str(islands.spawn_last),
				float(Time.get_ticks_usec() - _t3) / 1000.0]
	if chunk >= 0:
		world.release_chunk(chunk)
	shell_pieces_bricked += 1
	p.queue_free()
	return isl


## The last shell piece made bricks, where its time went (a --big --shot's
## damage spikes, 2026-10-23: 23-80 ms in _blast_shell_pieces).
var shell_brick_split := ""


## Once a tick: a shell piece that landed hard where somebody could see it
## break becomes bricks, and the landing breaks them as it would any brick
## piece's (IslandManager.fracture_on_impact). Far from everyone it lands
## whole and stays a shell (FRACTURE_RANGE, as a brick piece). One that fell
## out of the world goes.
func _tend_shell_pieces() -> void:
	for i in range(_shell_pieces.size() - 1, -1, -1):
		var p := _shell_pieces[i]
		if not is_instance_valid(p):
			_shell_pieces.remove_at(i)
			continue
		if p.global_position.y < -200.0:
			_shell_pieces.remove_at(i)
			p.queue_free()
			continue
		if p.landed_hard:
			p.landed_hard = false
			var speed := p.landed_speed
			p.landed_speed = 0.0
			# Measured from its box, as a brick piece's landing is
			# (IslandManager._landing_matters): a tall piece's middle is far up.
			var points := islands.interest_points()
			if not points.is_empty() and islands._distance_to_interest(p.world_box(registry),
					points) > IslandManager.FRACTURE_RANGE:
				continue
			var isl := _piece_to_bricks(p)
			if isl != null and isl.is_valid():
				islands.fracture_on_impact(isl, speed)


## A blast reaching a shell piece: it becomes bricks first, and the blast then
## lands on them as on any piece.
func _blast_shell_pieces(point: Vector3, radius: float) -> void:
	for p in _shell_pieces.duplicate():
		if not is_instance_valid(p) or not p.reaches(registry, point, radius):
			continue
		if p.storeys_at(registry, point, radius).is_empty():
			continue
		var isl := _piece_to_bricks(p)
		if isl != null and isl.is_valid():
			islands.damage(isl, point, radius)


func _shell_piece_of(collider: Object) -> ShellPiece:
	return collider as ShellPiece if collider is ShellPiece else null


## Everything a materialised building needs to be seen and stood on: its bands,
## its bake, its static body and its mesh node. Split from _promote so a loaded
## checkpoint can replay the damage into the bricks FIRST and dress the building
## after -- the bake and the shapes then start from the damaged building.
func _dress(id: int, chunk: int, solve: bool) -> void:
	# Bricks now: the AI asks them, not the shell.
	_drop_proxies(id)
	_nav_touch(id)
	_promote_part("tension, proxies, nav")
	# BEFORE the bake is started. Changing the band height invalidates the
	# bake and cancels one in flight, so doing it afterwards cancels the very
	# bake this promotion is waiting on -- the shell never comes down and the
	# building never finishes promoting.
	world.set_chunk_section_plates(chunk, _section_plates(chunk))
	world.set_chunk_section_studs(chunk, SECTION_STUDS)

	# The shell STAYS UP. Bricks and collision exist from this instant, but the
	# mesh that draws them is baked on a worker and arrives a tick or two later
	# -- and a building that drops its shell before it has a mesh is a building
	# that vanishes for a frame. See _finish_promotions.
	world.bake_chunk_async(chunk)
	_promote_part("sections, bake start")

	# The CHUNK's transform, not the building's. They are the same thing for a
	# generated tower, and they are not for a build: a multi-frame placement
	# rebases the whole assembly in its transform so the author's lowest brick
	# lands on the ground (BuildingRegistry.materialise).
	var root_x: Transform3D = world.get_chunk_transform(chunk)
	# A static body a band -- the bands set just above -- so a hit rebuilds
	# the band it lands in, not the building (BuildingCollision).
	_brick_cols[id] = BuildingCollision.new(world, chunk, get_world_3d().space, root_x,
			MERGE_SHAPES)
	_promote_part("collision")
	# And the shell's boxes go now -- its MESH stays until the bands are drawn
	# (_advance_bands). Both in the space was a solid box where the building's
	# insides are, for as long as its bands took to draw: a figure dropped down
	# the stairwell of a building still drawing its bands stood on the shell's
	# roof, and fell to the stairs when the shell went.
	_free_shell_body(id)
	_promote_part("shell body freed")

	var mi := MeshInstance3D.new()
	mi.material_override = brick_material
	mi.transform = root_x
	# A standing building never moves; its mesh is rewritten in place instead.
	# See IslandManager.spawn for why that and interpolation do not mix.
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	BrickMaterials.set_grain_origin(mi, world, registry.get_building(id).chunk)
	add_child(mi)
	_brick_nodes[id] = mi
	_pending_bricks.append(id)

	_materialised.append(id)
	_promote_part("mesh node")
	_promote_frames(id)
	_promote_part("frames")
	if solve:
		_mark_dirty(id)
		# Made bricks is not hit: a hit marks it after this (_interior_unsure).
		_touched_ms.erase(id)
	_promotions += 1
	_promote_part("solve queued")


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
		world.set_tension_per_stud(c, BrickStrength.tension())
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
			brick_near.untrack(mi)
			continue
		var arrays: Array = world.build_chunk_mesh(c)
		var mesh := ArrayMesh.new()
		if not arrays.is_empty() and IslandManager.mesh_arrays_ok(arrays, "frame %d" % c):
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_retirer.retire(mi.mesh)
		mi.mesh = mesh
		# A frame is its own chunk, drawn whole.
		brick_near.track(mi, c)


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
		# The shell stays up until every band is built -- see _advance_bands.
		# Dropping it here would leave a half-drawn building standing in the
		# open for the few ticks the rest of the bands take.
		if not _bands_building(id):
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
	_free_rest(id)
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

	if _brick_cols.has(id):
		(_brick_cols[id] as BuildingCollision).free_bodies()
	var carried_mesh: ArrayMesh = _brick_meshes.get(id)
	var carried_bytes: int = int(_brick_index_bytes.get(id, 0))
	var carried_width: int = int(_brick_index_width.get(id, 4))
	# The furniture node goes with the mesh node to the island, and the island
	# then makes its OWN from its own chunk -- so the first one hangs there
	# drawing furniture that has already been redrawn, forever. It is the
	# floating brick over a building that has come down.
	FurnitureMesh.drop(chunk, _furniture)
	# What its storey groups are drawing goes over with it: the piece it
	# becomes is this same chunk, so the rows are in the right space as they
	# are. Dropped with the groups, every desk in a toppling tower vanished the
	# tick it began to lean.
	var riding_rows := interior_groups.rows_of(id)
	_drop_groups(id)
	# A banded building has no single mesh to hand over -- it has its bands,
	# and they already hold the right geometry. The island draws them until
	# the first thing that changes it, and becomes an ordinary one-mesh
	# island then. See BrickIsland.bands.
	# And each band's index size, so the piece can go on patching them.
	var carried_band_bytes: Array = (_brick_band_bytes.get(id, []) as Array).duplicate()
	var carried_bands: Array = _take_bands(id)
	_brick_cols.erase(id)
	# The furniture body belongs to a STANDING building. What is falling
	# carries its own -- an island builds collision from the chunk, and a
	# decorative block is in the chunk like any other.
	_free_room_body(id)
	_furnished.erase(id)
	_brick_nodes.erase(id)
	_brick_meshes.erase(id)
	_brick_index_bytes.erase(id)
	_brick_index_width.erase(id)
	_last_hit.erase(id)
	_materialised.erase(id)
	_dirty.erase(id)
	_remesh_queue.erase(id)
	_pending_bricks.erase(id)

	# What was in the rooms: nothing is written off or marked. An item is on
	# whichever piece holds its floor, and is drawn there once that piece is
	# still and somebody is near (_stream_pieces; Interiors.md 8.10). A piece
	# laid as bricks is bricks in this chunk, and rides it down as they do.

	# The sideways frames go with it, each as its own piece. A welded assembly
	# coming down in one piece would need the solver to carry the welds, which
	# it does not: a weld is authoring-time structure (Docs/BuildMode.md
	# section 6.3 defers real joints), so what falls is the frames.
	_free_frames(id, true)
	registry.hand_over(id)
	islands.adopt(chunk, mi, carried_mesh, carried_bytes, carried_width, carried_bands,
			piece, id, true, true, carried_band_bytes)
	if not riding_rows.is_empty():
		_rider_add(islands.find_by_chunk(chunk), riding_rows, Transform3D.IDENTITY)
		_group_rides += 1
	for i in range(1, extra_frames.size()):
		if i - 1 >= extra_nodes.size():
			break
		var node: MeshInstance3D = extra_nodes[i - 1]
		islands.adopt(extra_frames[i], node, null, 0, 4, [], piece + i, id)


## Storey by storey, can what is left carry what is above it? (BrickWorld.
## gravity_check.) The stress solve fails only joints in tension, and the
## stability test only asks whether the whole building stands on its
## foundation: a storey shot away but for one corner held the eight storeys
## above it up on six bricks, for good.
##   TIP    what is above, off the edge of what is left: cut clean at that
##          boundary (a seam, as an earthquake cuts), and it goes over the edge.
##   CRUSH  too much on too little: everything in the storey under that
##          boundary is torn loose, and what is above comes down a floor.
## A command either way (SEVER), so every machine does the same.
## What the studs' strength decided: [building solves, of them with a joint
## failed in tension, joints failed]. What BrickStrength.times moves.
var stud_census := [0, 0, 0]


func stud_census_line() -> String:
	return "studs at x%.1f (%.1f each): %d building solve(s), %d with a joint failed in tension, %d joint(s) in all; storeys tipped %d, crushed %d, crushed under one region %d" % [
			BrickStrength.times, BrickStrength.tension(), stud_census[0], stud_census[1],
			stud_census[2], int(gravity_fails.tip), int(gravity_fails.crush),
			int(gravity_fails.get("region", 0))]


## What a stud holds, as the buildings that are bricks now have it. The
## setting can be moved in play (Options > Gameplay, "Stud Strength";
## BrickStrength.times): when it has, every building in bricks is given the new
## value, and its next solve -- the next thing that hits it -- uses that.
var _stud_times := BrickStrength.times


func _restud() -> void:
	_stud_times = BrickStrength.times
	var t := BrickStrength.tension()
	var n := 0
	for id in _materialised:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		for c in b.chunks():
			world.set_tension_per_stud(c, t)
		n += 1
	print("[city] stud strength x%.1f: a stud holds %.1f in %d building(s) of bricks" % [_stud_times, t, n])


## In units of what a stud held in tension when this was set (BrickStrength.
## SCALED): an intact tower asks at most 12.4 (big city), one corner left ~22.
## A storey gives way at the same LOAD whatever a stud holds in tension now --
## crushing is not the studs' doing -- so the check is handed this over how many
## times stronger they have been made (_gravity_fail).
const CRUSH_PER_STUD := 20.0
var gravity_fails := {"tip": 0, "crush": 0, "region": 0}
## CRUSH_PER_STUD, settable: collapse_probe weakens one tower to crush it.
var crush_per_stud := CRUSH_PER_STUD


func _gravity_fail(b: BuildingRegistry.Building) -> bool:
	if not authority.may_decide() or b.toppled or not b.is_materialised():
		return false
	var r: Dictionary = world.gravity_check(b.chunk,
			crush_per_stud * BrickStrength.SCALED / world.get_tension_per_stud(b.chunk))
	if float(r.get("ratio", 0.0)) < 1.0 or not r.has("level"):
		return _region_fail(b, r)
	var level: Vector3 = r.level
	var kind := str(r.kind)
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.SEVER
	e.target = b.id
	e.normal = Vector3.UP
	if kind == "tip":
		e.point = level
		e.flags = DamageLog.FLAG_SEAM
	else:
		# The storey under the boundary: its middle, and a storey thick.
		var storey := float(TowerRecipe.STOREY_PLATES) * BrickPalette.PLATE_M
		e.point = level - Vector3.UP * storey * 0.5
		e.radius = storey
	if not authority.request(DamageLog.Kind.SEVER, b.id, e.point, e.radius, Vector3.UP):
		return false
	if DamageLog.apply_entry(world, b.chunk, e).is_empty():
		return false
	authority.commit_entry(e)
	gravity_fails[kind] = int(gravity_fails.get(kind, 0)) + 1
	print("[city] building %d: storey at %.1f m %s (%.1fx what it can, %.0f above)" % [
			b.id, level.y, "tips over" if kind == "tip" else "is crushed", float(r.ratio),
			float(r.get("mass_above", 0.0))])
	return true


## The whole boundary holds; does each part of it? (gravity_check's regions,
## Docs/Structures.md 2.3.) A sum over the whole boundary hardly moves when one
## part of a building loses what holds it -- the columns under a tower standing
## on a wide base thinned to a few. Where a region cannot carry what stands over
## it, the storey under it is torn loose there, and only there: what is above
## is then held by its neighbours, or not (the stress solve, the span rule).
func _region_fail(b: BuildingRegistry.Building, r: Dictionary) -> bool:
	if float(r.get("region_ratio", 0.0)) < 1.0 or not r.has("region"):
		return false
	var storey := float(TowerRecipe.STOREY_PLATES) * BrickPalette.PLATE_M
	var e := DamageLog.region_crush(world, b.chunk, r, storey)
	e.tick = Engine.get_physics_frames()
	e.target = b.id
	if not authority.request(DamageLog.Kind.SEVER, b.id, e.point, e.radius, Vector3.UP):
		return false
	if DamageLog.apply_entry(world, b.chunk, e).is_empty():
		return false
	authority.commit_entry(e)
	gravity_fails["region"] = int(gravity_fails.get("region", 0)) + 1
	print("[city] building %d: storey at %.1f m is crushed under %s studs of it (%.1fx what it can, %.0f above)" % [
			b.id, e.point.y + storey * 0.5, str(r.region), float(r.region_ratio),
			float(r.get("region_mass_above", 0.0))])
	return true


## How far a floor reaches between its supports: BrickStrength.span_reach
## (BrickWorld.cut_spans; Docs/Structures.md 2.3). A tower's floor panels lie on
## columns every PANEL studs, so a whole building is never near it; a wide one
## with its ground storey shot out between its ends is, and the floors over the
## middle come down as one piece where they stood on nothing.
## Each building asked at most this often; one a tick.
const SPAN_EVERY_MS := 250
var _span_owed := {}      ## building id -> true: solved since its floors were asked
var _span_asked := {}     ## building id -> when they last were
var span_cuts := [0, 0]   ## cuts made, bricks in their rims
var span_asks := [0, 0.0, 0.0]   ## checks made (buildings and pieces), ms all told, the worst


func _span_time(t0: int) -> void:
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	span_asks[0] += 1
	span_asks[1] += ms
	span_asks[2] = maxf(span_asks[2], ms)


func span_line() -> String:
	return "floors past their reach: %d check(s), %.1f ms all told, %.2f the worst; %d cut, %d bricks in their rims" % [
			int(span_asks[0]), float(span_asks[1]), float(span_asks[2]), int(span_cuts[0]), int(span_cuts[1])]


## One building owed the question, if one is due: does every floor still reach
## something holding it up? Where one does not, a SEVER command (FLAG_SPAN)
## cuts its rim on every machine, and the building is solved again -- what the
## rim bounded is loose then, and leaves as a piece.
func _pay_span_owed() -> void:
	if not authority.may_decide():
		_span_owed.clear()
		return
	var now := Time.get_ticks_msec()
	for id in _span_owed.keys():
		if now - int(_span_asked.get(id, -1000000)) < SPAN_EVERY_MS:
			continue
		# Not while it is still coming apart: what the stress solve, the
		# storeys' check (tipping over a corner left, crushing) and the collapse
		# director make of it first; a span is asked of what is left hanging
		# once it is quiet. Asked first, it cut the floors over a storey shot
		# down to one corner, which should tip off it whole (storey_probe), and
		# broke a close collapse into three pieces (collapse_probe).
		if _mid_collapse(id):
			continue
		_span_owed.erase(id)
		_span_asked[id] = now
		var b := registry.get_building(id)
		if b == null or b.is_build() or b.toppled or not b.is_materialised() or _toppling.has(id):
			return
		var t0 := Time.get_ticks_usec()
		var rim := world.cut_spans(b.chunk, BrickStrength.span_reach, false)
		_span_time(t0)
		if rim.is_empty():
			return
		var e := DamageLog.Entry.new()
		e.tick = Engine.get_physics_frames()
		e.kind = DamageLog.Kind.SEVER
		e.target = b.id
		e.normal = Vector3.UP
		e.flags = DamageLog.FLAG_SPAN
		e.radius = BrickStrength.span_reach
		e.point = world.get_chunk_transform(b.chunk) * world.get_blocks_box(b.chunk, rim).get_center()
		if not authority.request(DamageLog.Kind.SEVER, b.id, e.point, e.radius, Vector3.UP):
			return
		var cut := DamageLog.apply_entry(world, b.chunk, e)
		if cut.is_empty():
			return
		authority.commit_entry(e)
		span_cuts[0] += 1
		span_cuts[1] += cut.size()
		_mark_dirty(b.id)
		print("[city] building %d: a floor past its reach (%.0f studs) gives way, %d bricks round it" % [
				b.id, BrickStrength.span_reach, cut.size()])
		return


## The staircase goes with the floors it serves (Docs/Collapse.md 2.1). Its
## blocks have no joint to any slab -- they are grounded by their own column,
## down to the ground -- so a section breaking off left them standing, and fell
## threaded on them: the shaft fits the stairwell exactly, and the section
## caught on it and hung. Every live stair block inside the height of a group
## leaving the building leaves with it -- if the group is a SECTION: a storey
## tall at least, STAIR_SECTION_BLOCKS or more, and over the stairwell. Debris
## coming off a wall must not take the stairs of floors still standing (it did,
## a brick at a time, and left soldiers no way down).
const STAIR_SECTION_BLOCKS := 150


func _with_stairs(b: BuildingRegistry.Building, group: PackedInt32Array) -> PackedInt32Array:
	if b.is_build() or b.fixtures.is_empty() or group.size() < STAIR_SECTION_BLOCKS:
		return group
	var box := world.get_blocks_box(b.chunk, group)
	if box.size.y < TowerRecipe.STOREY_PLATES * BrickPalette.PLATE_M:
		return group
	var leaving := {}
	for bid in group:
		leaving[bid] = true
	# Dead, or cut out already -- a detached block still has a box.
	var gone := {}
	for bid in world.get_dead_blocks(b.chunk):
		gone[bid] = true
	for bid in world.get_detached_blocks(b.chunk):
		gone[bid] = true
	var stairs := {}
	var candidates := PackedInt32Array()
	for f in b.fixtures:
		if f.kind != "staircase":
			continue
		for bid in f.blocks:
			stairs[bid] = true
			# Not laid (Docs/Space.md 5.3a): its storey is the rest shell's.
			if leaving.has(bid) or gone.has(bid) or world.is_block_absent(b.chunk, bid):
				continue
			# Any stair block reaching up into the section: one left standing
			# with its top in the section's shaft is a rod through it. (Only
			# taken when nothing stands round the shaft above -- below.)
			var sb := world.get_blocks_box(b.chunk, PackedInt32Array([bid]))
			if sb.end.y > box.position.y + 0.3 and sb.position.y < box.end.y:
				candidates.append(bid)
	if candidates.is_empty():
		return group
	# Will anything still stand round the shaft, from the section's bottom up,
	# once it has gone? If so the stairs serve floors that are still there and
	# stay, all of them. Only a shaft left with nothing round it -- the column a
	# section would hang on -- goes with the section.
	# From half a storey above the section's bottom: below that is the stump's
	# own top course, which the section sat on -- not a floor beside the stairs.
	# (It held every cut-free top on its staircase: Docs/Collapse.md 6.)
	var shaft := world.get_blocks_box(b.chunk, candidates).grow(1.2)
	var from_y := box.position.y + TowerRecipe.STOREY_PLATES * BrickPalette.PLATE_M * 0.5
	shaft = AABB(Vector3(shaft.position.x, from_y, shaft.position.z),
			Vector3(shaft.size.x, maxf(box.end.y + 1.0 - from_y, 0.1), shaft.size.z))
	# Anything live, not stairs and not leaving, centred in the shaft? (Dead and
	# cut-out blocks are not live.) Asked of the engine: walked here over
	# get_block_boxes it was 60-70 ms for a 22,000-brick tower, in the very tick
	# the section broke away.
	var exclude := PackedInt32Array(stairs.keys())
	exclude.append_array(group)
	if world.any_block_centre_in(b.chunk, shaft, exclude):
		return group
	var out := group.duplicate()
	out.append_array(candidates)
	return out


## A piece has just left building `id`: watch the hand-over (_handovers).
func _note_handover(id: int, isl: BrickIsland) -> void:
	if not _handovers.has(id):
		_handovers[id] = {"pieces": [], "born": Engine.get_process_frames(), "gap": 0, "double": 0}
		handover_stats.count += 1
	(_handovers[id].pieces as Array).append(isl)


## Must building `id` keep drawing what it shed? Yes for OVERLAP_FRAMES (the
## newborn instance), and after that while any piece that took the bricks draws
## nothing -- up to HANDOVER_MAX_FRAMES, so a stalled bake cannot hold it for good.
func _handover_waiting(id: int, now: int) -> bool:
	var h: Dictionary = _handovers[id]
	var age := now - int(h.born)
	if age <= IslandManager.OVERLAP_FRAMES:
		return true
	if age > HANDOVER_MAX_FRAMES:
		return false
	for isl in h.pieces:
		if islands.is_blind(isl):
			return true
	return false


## Is building `id` still drawing bricks it has shed? Its remesh is queued or
## held, or deferred behind bands still building -- with its whole shell up.
func _parent_stale(id: int) -> bool:
	return _remesh_queue.has(id) or _band_redo.has(id) \
			or (_shells.has(id) and _bands_building(id))


## Once a tick: score every hand-over in flight, and close the finished ones.
func _watch_handovers() -> void:
	var now := Engine.get_process_frames()
	for id in _handovers.keys():
		var h: Dictionary = _handovers[id]
		var blind := false
		for isl in h.pieces:
			if islands.is_blind(isl):
				blind = true
				break
		var stale := _parent_stale(id)
		if blind and not stale:
			h.gap += 1
		elif stale and not blind and now - int(h.born) > IslandManager.OVERLAP_FRAMES:
			h.double += 1
			if _remesh_queue.has(id):
				handover_stats.double_queued += 1
			else:
				handover_stats.double_bands += 1
		if (not blind and not stale) or now - int(h.born) > 600:
			handover_stats.gap_ticks += int(h.gap)
			handover_stats.double_ticks += int(h.double)
			handover_stats.gap_worst = maxi(handover_stats.gap_worst, int(h.gap))
			handover_stats.double_worst = maxi(handover_stats.double_worst, int(h.double))
			handover_stats.gap_handovers += 1 if int(h.gap) > 0 else 0
			handover_stats.double_handovers += 1 if int(h.double) > 0 else 0
			_handovers.erase(id)


## Whether every band of a building's collision is merged.
func _building_merged(id: int) -> bool:
	return _brick_cols.has(id) and (_brick_cols[id] as BuildingCollision).all_merged()


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
	if not MERGE_SHAPES:
		return
	var merged := 0
	var now := Time.get_ticks_msec()
	for id in _materialised:
		if merged >= MERGES_PER_TICK:
			break
		if not _brick_cols.has(id) or _building_merged(id) or _toppling.has(id):
			continue
		if _dirty.has(id) or _remesh_queue.has(id) or _pending_disable.has(id):
			continue
		if now - int(_last_hit.get(id, 0)) < MERGE_AFTER_MS:
			continue
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		# One band, not the building: the next tick does the next one.
		(_brick_cols[id] as BuildingCollision).merge_next()
		merged += 1


## Something changed this building's structure, so it needs re-solving.
## `y_lo`..`y_hi`, when the caller knows it, is where in the building (its own
## space, metres) the change was: only the storey groups there have their
## pieces' floors asked again (InteriorGroups.touch). Not given, all of them.
func _mark_dirty(id: int, y_lo: float = -INF, y_hi: float = INF) -> void:
	if not _dirty.has(id):
		_dirty.append(id)
	_touched_ms[id] = Time.get_ticks_msec()
	_panes_owed[id] = true
	var b := registry.get_building(id)
	if b != null:
		b.structure_version += 1
		# A caller that knows where says so; then what died or left tells the
		# storey groups itself, the tick it does (_disable, the detach). Only a
		# change nobody can place has every group walk its pieces again.
		if y_lo == -INF and y_hi == INF:
			interior_groups.touch(id)


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
		# Its mesh given up at range (_demesh): the shell standing in for it
		# has to show the hit too, or it goes on drawing what was there.
		# Rebuilt by _stream_detail, in its budget.
		if b != null and b.is_materialised() and _shells.has(id):
			_shell_stale[id] = true
		return
	# Its bricks changed: drawn as bricks again, at once (_tend_far_coarse).
	_far_coarse_drop(id)
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
	if _bands_building(id):
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
			# And the chamfered ones, and the studs the hit uncovered: of the
			# bands this patch moved, no others.
			var touched := PackedInt32Array()
			for entry in moved:
				touched.append(int((entry as Dictionary).section))
			if not touched.is_empty():
				brick_near.damaged(b.chunk, touched)
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
	_band_pass[id] = int(_band_pass.get(id, 0)) + 1
	# The parent draws nothing itself; it is the transform the bands hang off
	# and the node the furniture is parented to.
	_retirer.retire(parent.mesh)
	parent.mesh = null
	_brick_meshes[id] = null
	_brick_index_bytes[id] = 0


## Build one band of a building's mesh. Returns false when there are none left.
func _build_one_band(id: int) -> bool:
	var pos: int = int(_band_cursor.get(id, -1))
	if pos < 0:
		return false
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or not _brick_nodes.has(id):
		_band_cursor.erase(id)
		return false
	var nodes: Array = _brick_bands.get(id, [])
	var at := pos
	if at >= nodes.size():
		_band_cursor.erase(id)
		return false
	# A band built against a stale bake re-bakes the WHOLE chunk on this
	# thread -- measured at 55 ms against 2.6 for an ordinary band, and it
	# lands in one frame. Wait for the worker instead.
	# bake_ready, not has_bake: it is what adopts a finished job. Asking only
	# has_bake waited forever on a bake nobody else collected (a recolour).
	if not world.bake_ready(b.chunk):
		if not world.bake_pending(b.chunk):
			world.bake_chunk_async(b.chunk)
		return true
	var _t0 := Time.get_ticks_usec()
	var arrays: Array = world.build_chunk_mesh_section(b.chunk, at)
	var _t1 := Time.get_ticks_usec()
	var ok := not arrays.is_empty() \
			and IslandManager.mesh_arrays_ok(arrays, "building %d band %d" % [id, at])
	if ok:
		_brick_index_width[id] = IslandManager.index_width(arrays)
		_band_verts_now += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if ok and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() \
			>= (BAND_THREAD_VERTS if worker_meshes else BAND_THREAD_VERTS_HEADLESS):
		_submit_band_job(id, at, arrays)
	else:
		var mesh := ArrayMesh.new()
		if ok:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_apply_band(id, at, mesh, arrays)
	var _t2 := Time.get_ticks_usec()
	_band_cpp_ms += float(_t1 - _t0) / 1000.0
	_band_upload_ms += float(_t2 - _t1) / 1000.0
	_prof["bd_cpp"] = float(_prof.get("bd_cpp", 0.0)) + float(_t1 - _t0) / 1000.0
	_prof["bd_upload"] = float(_prof.get("bd_upload", 0.0)) + float(_t2 - _t1) / 1000.0
	_band_builds += 1
	_band_worst = maxf(_band_worst, float(_t2 - _t0) / 1000.0)
	_band_cursor[id] = pos + 1
	if pos + 1 >= nodes.size():
		_band_cursor.erase(id)
		return false
	return true


func _is_tree(id: int) -> bool:
	return Trees.is_tree(registry.get_building(id))


## Ground for snow to lie on (SnowCover): only a city on terrain has any.
func has_terrain() -> bool:
	return _terrain_mat != null


## The buildings snow can lie on (SnowCover): standing, bricks in, one frame,
## not trees (their crowns take a cap in the shader instead).
func snow_buildings() -> Array:
	var out := []
	for b in registry.buildings:
		if b.toppled or b.chunk < 0 or b.frames.size() > 1 or not _brick_nodes.has(b.id):
			continue
		if _is_tree(b.id):
			continue
		out.append({"id": b.id, "chunk": b.chunk, "parent": _brick_nodes[b.id],
				"version": b.structure_version, "sway": _sway_of(b.id)})
	return out


## A standing building's wind sway (WeatherFx): a tree's crown moves, a
## tower's top a few centimetres. Height from the ground it stands on.
func _sway_of(id: int) -> Vector3:
	var b := registry.get_building(id)
	if b == null or b.toppled:
		return Vector3.ZERO
	var h := registry.local_box(id).end.y
	if Trees.is_tree(b):
		return WeatherFx.sway_tree(h)
	return WeatherFx.sway_building(h)


## The grid's light on the buildings in bricks nearest the camera (as many as
## it has layers), twice a second; between, a building lit again when its
## bricks change (BrickGridLight.step).
func _tend_grid_light() -> void:
	grid_light.step()
	var now := Time.get_ticks_msec()
	if now - _grid_at < 500:
		return
	_grid_at = now
	var eye := camera.global_position
	var near: Array = []
	for id in _brick_nodes:
		var node := _brick_nodes[id] as Node3D
		var b := registry.get_building(id)
		if b == null or b.chunk < 0 or not is_instance_valid(node):
			continue
		var d := Vector3(world.get_chunk_dims(b.chunk)) * Vector3(BrickWorld.get_stud_metres(),
				BrickWorld.get_plate_metres(), BrickWorld.get_stud_metres())
		near.append([eye.distance_to(node.global_transform * (d * 0.5)), id])
	near.sort_custom(func(x, y): return x[0] < y[0])
	var keep := {}
	for k in mini(near.size(), BrickGridLight.SLOTS):
		keep[near[k][1]] = true
	for id in _brick_nodes:
		if not keep.has(id):
			grid_light.release(id)
	# Two new a pass: each is a flood and a layer's upload (~1 ms).
	var added := 0
	for id in keep:
		if not grid_light.tracked(id) and added < 2:
			grid_light.track(id, world, registry.get_building(id).chunk, _brick_nodes[id])
			added += 1


## Hang a finished band mesh in its slot.
func _apply_band(id: int, at: int, mesh: ArrayMesh, arrays: Array) -> void:
	# Its bricks changed: its far stand-in is out of date, and the bands are
	# what is right (_tend_far_coarse makes it again once it is quiet).
	_far_coarse_drop(id)
	var nodes: Array = _brick_bands.get(id, [])
	if at >= nodes.size() or not _brick_nodes.has(id):
		_retirer.retire(mesh)
		return
	var node: MeshInstance3D = nodes[at]
	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.material_override = brick_material
		# It sways in the wind, a little (weather.gdshaderinc); a tree more.
		InstanceParams.put(node, &"weather_sway", _sway_of(id))
		# A tree's crown takes a cap of snow; a building gets real cover.
		InstanceParams.put(node, &"weather_snowcap", 1.0 if _is_tree(id) else 0.0)
		InstanceParams.put(node, &"grain_origin",
				InstanceParams.of(_brick_nodes[id] as MeshInstance3D, &"grain_origin"))
		# In the parent's space, which already carries the chunk transform.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		# Casting as the building does: a shadow shell may be standing in
		# for its bricks (_stream_shadows).
		node.cast_shadow = (_brick_nodes[id] as MeshInstance3D).cast_shadow
		(_brick_nodes[id] as MeshInstance3D).add_child(node)
		nodes[at] = node
	else:
		_retirer.retire(node.mesh)
	var live := mesh != null and mesh.get_surface_count() > 0
	node.mesh = mesh if live else null
	# Its chamfered mesh and studs, when the camera is near (and again: this is
	# a new mesh, from what may be a new bake).
	var band_of := registry.get_building(id)
	if live and band_of != null:
		brick_near.track(node, band_of.chunk, at)
	else:
		brick_near.untrack(node)
	(_brick_band_meshes[id] as Array)[at] = mesh if live else null
	(_brick_band_bytes[id] as Array)[at] = (IslandManager.index_patch_bytes(arrays) if live else 0)


## Upload a band's arrays on a worker (BAND_THREAD_VERTS). Attached by
## _harvest_band_jobs when it is done.
## Started at the end of the tick, as a piece's are (IslandManager.
## _submit_mesh_job says why).
func _submit_band_job(id: int, at: int, arrays: Array) -> void:
	var holder := [null]
	var work := func() -> void:
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				IslandManager.UPLOAD_COMPRESS)
		holder[0] = m
		UploadLedger.note("band", UploadLedger.verts_of(arrays))
	_band_jobs.append([id, at, IslandManager.JOB_NOT_STARTED, holder, arrays,
			int(_band_pass.get(id, 0)), work])


func _start_band_jobs() -> void:
	for job in _band_jobs:
		if int(job[2]) == IslandManager.JOB_NOT_STARTED:
			job[2] = WorkerThreadPool.add_task(job[6] as Callable, false, "building band mesh")


## Whether a building's bands are still on their way: being built, or built
## and still being uploaded.
func _bands_building(id: int) -> bool:
	if _band_cursor.has(id):
		return true
	for job in _band_jobs:
		if int(job[0]) == id:
			return true
	return false


## Attach the band meshes the workers have finished. `wait_for` >= 0 waits for
## that building's jobs instead of leaving them for the next tick -- for a
## building about to hand its bands on (_take_bands).
func _harvest_band_jobs(wait_for: int = -1) -> void:
	var finished: Array[int] = []
	var k := 0
	while k < _band_jobs.size():
		var job: Array = _band_jobs[k]
		var id: int = job[0]
		var task: int = job[2]
		# Waiting for one building: only its jobs, the rest are next tick's.
		if (wait_for >= 0 and id != wait_for) \
				or (wait_for < 0 and (task < 0 or not WorkerThreadPool.is_task_completed(task))):
			k += 1
			continue
		if task < 0:
			# Waited for before it was started: done here and now.
			(job[6] as Callable).call()
		else:
			WorkerThreadPool.wait_for_task_completion(task)
		_band_jobs.remove_at(k)
		var mesh: ArrayMesh = job[3][0]
		# A pass since superseded, or a building since gone: not attached.
		if int(job[5]) != int(_band_pass.get(id, 0)) or not _brick_bands.has(id):
			_retirer.retire(mesh)
			continue
		var ta := Time.get_ticks_usec()
		_apply_band(id, int(job[1]), mesh, job[4])
		_part("bd_apply", ta)
		band_jobs_done += 1
		if not finished.has(id):
			finished.append(id)
	if wait_for >= 0:
		return
	var td := Time.get_ticks_usec()
	for id in finished:
		if not _bands_building(id):
			_bands_done(id)
	_part("bd_done", td)


## A building's bands are all built and attached.
func _bands_done(id: int) -> void:
	_band_first.erase(id)
	if _band_redo.has(id):
		# Something hit it on the way through. A band built after the hit was
		# built from the bricks as they are, and is right; only the ones built
		# before it are not, and only those are built again -- the old ones
		# drawn meanwhile. It was a whole second pass, with the shell kept up
		# for it: the first shot at a building still in its shell showed on it
		# 14 ticks after it was made bricks, the pieces it cut out drawn twice
		# all that time -- falling, and still in the wall.
		_band_redo.erase(id)
		var rb := registry.get_building(id)
		if rb != null and rb.is_materialised():
			var nodes: Array = _brick_bands.get(id, [])
			if nodes.size() != world.get_chunk_sections(rb.chunk):
				_rebuild_bands(id, rb.chunk)
			else:
				# Every band is drawn now, and each wrote the index baseline it
				# was built with (BrickWorld.build_chunk_mesh_section): a patch
				# finds exactly the bands hit since and moves only those. The
				# second pass this was -- every band built before the last hit
				# built again, behind the shell -- kept a mega tower under fire
				# drawn whole by its shell for 30 ticks with its storey shot
				# through, and nothing could leave it until then (CityScene's
				# solve waits on the shell): the walls showed unbroken, then it
				# all came down at once (user, big city, 2026-10-16).
				_free_shell(id)
				_remesh(id)
	else:
		# Finished: the shell it was hiding behind can go.
		_free_shell(id)


## Drain the band work, a budget at a time.
func _advance_bands() -> void:
	var th := Time.get_ticks_usec()
	_harvest_band_jobs()
	_part("bd_harvest", th)
	if _band_cursor.is_empty():
		return
	var until := Time.get_ticks_usec() + int(BAND_BUDGET_MS * 1000.0)
	var built := 0
	_band_verts_now = 0
	while built < BANDS_PER_TICK and not _band_cursor.is_empty() \
			and _band_verts_now < BAND_VERTS_PER_TICK:
		var id: int = _band_cursor.keys()[0]
		for first in _band_first:
			if _band_cursor.has(first):
				id = first
				break
		var at_before := int(_band_cursor.get(id, -1))
		var verts_before := _band_verts_now
		_build_one_band(id)
		# An empty band is free, and a building laid a storey at a time is
		# mostly empty bands: only a band with something in it -- or a wait on
		# the bake -- counts against BANDS_PER_TICK.
		if _band_verts_now > verts_before or int(_band_cursor.get(id, -1)) == at_before:
			built += 1
		if not _bands_building(id):
			_bands_done(id)
		if Time.get_ticks_usec() >= until:
			break


## Drop a building's band nodes, returning them so a caller can hand them on.
func _take_bands(id: int) -> Array:
	# Drawn again, wherever they are going (_far_coarse_drop).
	_far_coarse_drop(id)
	# Whatever is being uploaded for it lands first: a piece carrying these
	# bands away patches them, and a slot still waiting holds nothing to patch.
	_harvest_band_jobs(id)
	_band_pass.erase(id)
	var nodes: Array = _brick_bands.get(id, [])
	_band_cursor.erase(id)
	_band_redo.erase(id)
	_brick_bands.erase(id)
	_brick_band_meshes.erase(id)
	_brick_band_bytes.erase(id)
	return nodes


func _disable(id: int, ids: PackedInt32Array) -> void:
	if ids.is_empty():
		return
	# What stood on these, in the storey groups: gone this tick, not when a
	# pass next walks the group (Interiors.md 8.3). Not for bricks that are
	# about to leave as a section -- they are still here; the detach asks once
	# they have gone, and what stood on them rides.
	if not _groups_leaving and not interior_groups.known(id).is_empty():
		var held := registry.get_building(id)
		if held != null and held.is_materialised():
			_groups_floor_went(held, world.get_blocks_box(held.chunk, ids).grow(0.2))
	if not _brick_cols.has(id):
		return
	# Interiors are drawn from their own blocks rather than from the face
	# bake, so a blast that takes a chair out has to be told to redraw one --
	# once a tick (_flush_furniture), not once a call: a collapse cuts a dozen
	# pieces out of one building in a tick, and each redrew all its furniture.
	_furniture_due[id] = true
	var t := Time.get_ticks_usec()
	# Only the bands these blocks are in -- un-merged first if they were, since
	# a merged box spans blocks and cannot be switched off one at a time.
	(_brick_cols[id] as BuildingCollision).disable(ids)
	t = _part("dis_collision", t)
	# And the furniture body, if this building has one. A blast does not
	# know which of the two a block it killed was on, so both are asked.
	if _room_bodies.has(id):
		_disable_on(_room_bodies[id], _room_shapes.get(id, {}), ids)
		_part("dis_rooms", t)


## Redraw the furniture of every building _disable touched this tick.
func _flush_furniture() -> void:
	if _furniture_due.is_empty():
		return
	var t := Time.get_ticks_usec()
	for id in _furniture_due:
		_refresh_furniture(id)
	_furniture_due.clear()
	_part("furniture", t)


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
	# A building that is still a shell is not made bricks for a landing nobody is
	# near -- the same line the piece that landed was held to (FRACTURE_RANGE:
	# it came down whole). Promoting a tower 70 m away to knock three bricks
	# loose, and giving the bricks back when the trim came round, was a
	# promotion and a demotion per landing: the same building, three times in one
	# collapse. A building already in bricks still takes the hit.
	var far := islands.far_from_everyone(point)

	# The collider the solver named is the answer when there is one. Falling
	# back to "which building's bounding box contains this point" was what made
	# impact damage intermittent: a contact sits ON the surface, so whether it
	# counts as inside depends on which side of the skin the solver put it.
	var named := _building_for_body(collider)
	if named >= 0:
		if not (far and not registry.get_building(named).is_materialised()):
			_shear_building(named, point, radius)
	else:
		# The buildings whose footprint is near, from the index shots use --
		# not every building in the city, trees and all, a landing at a time.
		for id in _near_buildings(point, radius):
			var b := registry.get_building(id)
			if b == null or (far and not b.is_materialised()):
				continue
			var local := b.xform.affine_inverse() * point
			var size := Vector3(b.recipe.footprint_x * STUD,
					TowerRecipe.total_plates(b.recipe.courses) * PLATE,
					b.recipe.footprint_z * STUD)
			if AABB(Vector3.ZERO, size).grow(radius).has_point(local):
				_shear_building(b.id, point, radius)

	islands.shear_near(point, radius, source)
	_crush_drawn(source)


## A piece came down in a drawn room. Its furniture is drawn, not bricks, and
## holds nothing up (Layers.FIXTURE), so the piece went through the table --
## and the table stayed drawn inside the wreckage until the floor under it
## went (Docs/CollapseNext.md 1.2). An item with a brick of the piece where it
## stands is crushed: gone from the room's record, as anything destroyed is,
## and the room drawn again at once without it. Asked when a piece lands hard
## and when one settles -- a slow one ends up in the furniture too.
func _crush_drawn(source: BrickIsland) -> void:
	if source == null or not source.is_valid():
		return
	var piece := islands.world_aabb(source).grow(0.2)
	var piece_inv := world.get_chunk_transform(source.chunk).affine_inverse()
	var piece_origin: Vector3i = world.get_chunk_origin(source.chunk)
	var cs := BrickWorld.get_cell_size()
	for id in _near_buildings(piece.get_center(), piece.size.length() * 0.5 + 1.0):
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		# Every room of the storey groups the piece reaches (InteriorGroups).
		var indices: Array = _group_rooms_in(b, b.xform.affine_inverse() * piece)
		if indices.is_empty():
			continue
		var chunk_xf := world.get_chunk_transform(b.chunk)
		var origin: Vector3i = world.get_chunk_origin(b.chunk)
		var offset: Vector3i = registry._rebase_of(b)
		var redraw := []
		var crushed := {}   ## room index -> {item: true}
		for index in indices:
			var room := registry.get_room(id, index)
			if room == null or not room.world_box(b.xform).intersects(piece):
				continue
			for i in room.items.size():
				if room.gone.has(i) or room.laid.has(i):
					continue   # gone already, or bricks: the piece meets those itself
				var cell: Vector3i = (room.items[i] as Dictionary).cell
				# An item is where its floor is, and a room whose floor has
				# left is air here: what falls through that air crushes nothing
				# (it was writing off furniture lying on a piece in the street,
				# ten boxes at a time).
				if RoomManifest.item_floor_share(world, b.chunk,
						str((room.items[i] as Dictionary).type), cell - offset) <= 0.5:
					continue
				var base := chunk_xf * (Vector3(cell - offset - origin) * cs)
				# Its foot and a little above it: a piece through a table is in
				# the table's space, one resting on the floor beside it is not.
				for up in [0.5, 1.5, 2.5]:
					var p := base + Vector3(cs.x * 0.5, cs.y * up, cs.z * 0.5)
					if not piece.has_point(p):
						continue
					var at := Vector3i((piece_inv * p / cs).floor()) + piece_origin
					if world.is_solid(source.chunk, at):
						if not crushed.has(index):
							crushed[index] = {}
						(crushed[index] as Dictionary)[i] = true
						if not redraw.has(index):
							redraw.append(index)
						break
		# Broken under it, into its parts, not gone between one frame and the
		# next (_break_items).
		for index in crushed:
			_break_items(b, b.chunk, registry.get_room(id, index), crushed[index],
					piece.get_center(), CRUSH_THROW)
		crushed.clear()
		if redraw.is_empty():
			continue
		_groups_refresh(b, redraw)
		crushed_by_wreckage += redraw.size()


## **Furniture breaks into its parts** (Docs/CollapseNext.md 0, item 9). A piece
## of furniture is drawn, not bricks, where nobody has laid it (Interiors.md
## 8.4) -- so wreckage falling on it, or a blast on the wreckage it stands on,
## took it out of the room's record and it was gone between one frame and the
## next, or (on wreckage) it stood there whole while the bricks round it flew.
## Now each part of it is thrown as a crumb from where it stood
## (IslandManager.throw_rows) as it is written off. `items` are indices in
## `room.items`, standing on `chunk` (the building, or a piece of it); `at` is
## what broke them, which they are thrown from. Returns how many broke.
const CRUSH_THROW := 1.0          ## m/s at most: pressed out from under a piece
const BLAST_ITEM_THROW := 3.0     ## m/s at most: a blast in the room
func _break_items(b: BuildingRegistry.Building, chunk: int, room: Room, items: Dictionary,
		at: Vector3, speed: float) -> int:
	if room == null or items.is_empty():
		return 0
	# Its rows, worked out as they are drawn -- before it is written off, after
	# which it is drawn no more.
	var d := RoomManifest.draw_items(world, chunk, registry.palette, room, registry._rebase_of(b))
	var buffer: PackedFloat32Array = d.buffer
	var details: PackedFloat32Array = d.details
	var pieces: PackedInt32Array = d.pieces
	var xf := world.get_chunk_transform(chunk)
	var broke := 0
	for k in range(0, pieces.size(), 6):
		var i := pieces[k]
		if not items.has(i):
			continue
		var rows := buffer.slice(pieces[k + 1] * 16, (pieces[k + 1] + pieces[k + 2]) * 16)
		rows.append_array(details.slice(pieces[k + 3] * 16, (pieces[k + 3] + pieces[k + 4]) * 16))
		islands.throw_rows(rows, xf, at, speed)
		broke += 1
	for i in items:
		room.gone[i] = true
	return broke


## Shear, not destroy: a brick struck by falling masonry comes loose.
func _shear_building(id: int, point: Vector3, radius: float) -> void:
	# The storeys it lands on, not the building (Docs/Space.md 5.3a).
	var chunk := _promote(id, true, _storeys_for(id, point, radius))
	if chunk < 0:
		return
	director.note_hit(id, point)
	# peel: masonry landing on a wall knocks a clump of it loose, not a cloud of
	# individual bricks. See BrickWorld::separate_near.
	var loosened: PackedInt32Array = world.separate_near(chunk, point, radius,
			IslandManager.SHEAR_MAX_BLOCKS, true)
	if loosened.is_empty():
		return
	authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SHEAR,
			id, point, radius, Vector3.ZERO, IslandManager.SHEAR_MAX_BLOCKS)
	_impact_damage += loosened.size()
	var sheared_at: float = (registry.get_building(id).xform.affine_inverse() * point).y
	_mark_dirty(id, sheared_at - radius, sheared_at + radius)
	# Queued, as a blast's is: a landing is inside the islands' own tick, and a
	# rebuild there is paid in the worst tick of a collapse.
	_queue_remesh(id)


## Which building owns a physics body -- shell tier or brick tier, either counts.
func _building_for_body(body: RID) -> int:
	if not body.is_valid():
		return -1
	for id in _brick_cols:
		if (_brick_cols[id] as BuildingCollision).owns(body):
			return id
	for id in _shell_bodies:
		if _shell_bodies[id] == body:
			return id
	for id in _rest_shells:
		if _rest_shells[id][1] == body:
			return id
	return -1


## Queue a hit. Applying it is the next tick's problem; see DAMAGE_BUDGET_MS.
## On a client the hit is only asked for: the host applies it and it comes back
## as a committed command.
func _blast(point: Vector3, radius: float) -> void:
	if not authority.request(DamageLog.Kind.BLAST, -1, point, radius):
		return
	# Guns on the floor are thrown by it (and the ones it leaves without a floor fall).
	WorldGunPickup.blast(point, radius * 2.0)
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


## Char the bricks in a ball (DamageLog.Kind.SCORCH): fire's mark. Host only,
## like the fire that calls it, and only on bricks that are here -- a building
## out of reach is not materialised for a colour. Returns how many blackened.
func scorch(point: Vector3, radius: float) -> int:
	if not authority.may_decide():
		return 0
	var n := 0
	for id in _near_buildings(point, radius):
		var b := registry.get_building(id)
		if b == null or b.chunk < 0:
			continue
		var cs := b.chunks()
		var here := 0
		for fi in cs.size():
			if world.scorch_hit(cs[fi], point, radius).is_empty():
				continue
			here += 1
			var e := DamageLog.Entry.new()
			e.tick = Engine.get_physics_frames()
			e.kind = DamageLog.Kind.SCORCH
			e.target = b.id
			e.frame = fi
			e.point = point
			e.radius = radius
			authority.commit_entry(e)
		if here > 0:
			n += here
			if not _recolour.has(b.id):
				_recolour[b.id] = Engine.get_physics_frames() + RECOLOUR_TICKS
	return n


## The chunks fire can reach round `point` (BrickFire): [building id, frame,
## chunk] for each standing building whose box is within `radius`. With
## `promote`, a building out of brick range is materialised first -- a flame put
## to it (lightning, a meteor) -- but fire that is only spreading does not drag
## far buildings in.
func fire_chunks(point: Vector3, radius: float, promote := false) -> Array:
	var out := []
	for id in _near_buildings(point, radius + 2.0):
		var b := registry.get_building(id)
		if b == null or b.toppled:
			continue
		if not registry.local_box(b.id).grow(radius).has_point(b.xform.affine_inverse() * point):
			continue
		if not b.is_materialised():
			if not promote or _promote(b.id, true, _storeys_for(b.id, point, radius)) < 0:
				continue
		var cs := b.chunks()
		for fi in cs.size():
			out.append([b.id, fi, cs[fi]])
	return out


## Is this building still standing in bricks (BrickFire): fire steps only those.
## A toppled one is a piece now -- the burning debris carries its fire on.
func fire_standing(id: int) -> bool:
	var b := registry.get_building(id)
	return b != null and not b.toppled and b.is_materialised()


## What fire did to a building's bricks (BrickWorld.fire_step, which already
## did it): `killed` burnt out, `charred` blackened. Committed -- BURN and
## SCORCH by ids -- and followed up as a hit's kills are: the bricks stop
## colliding and drawing, the building is re-solved (a burnt support brings
## down what it held), the AI's ground is redone round `at`.
func fire_burnt(id: int, frame: int, killed: PackedInt32Array, charred: PackedInt32Array,
		at: Vector3) -> void:
	var b := registry.get_building(id)
	if b == null or not authority.may_decide():
		return
	var pf := Engine.get_physics_frames()
	if not charred.is_empty():
		var charred_entry := DamageLog.Entry.new()
		charred_entry.tick = pf
		charred_entry.kind = DamageLog.Kind.SCORCH
		charred_entry.target = id
		charred_entry.frame = frame
		charred_entry.flags = DamageLog.FLAG_BLOCKS
		charred_entry.blocks = charred
		charred_entry.point = at
		authority.commit_entry(charred_entry)
		if not _recolour.has(id):
			_recolour[id] = pf + RECOLOUR_TICKS
	if killed.is_empty():
		return
	var cs := b.chunks()
	var box := AABB(at, Vector3.ZERO)
	if frame < cs.size():
		var lb: AABB = world.get_blocks_box(cs[frame], killed)
		box = world.get_chunk_transform(cs[frame]) * lb
	var e := DamageLog.Entry.new()
	e.tick = pf
	e.kind = DamageLog.Kind.BURN
	e.target = id
	e.frame = frame
	e.blocks = killed
	e.point = box.get_center()
	e.radius = box.size.length() * 0.5
	authority.commit_entry(e)
	b.hit = true
	_mark_dirty(id)
	_last_hit[id] = Time.get_ticks_msec()
	director.note_hit(id, e.point)
	if frame == 0:
		if not _pending_disable.has(id):
			_pending_disable[id] = PackedInt32Array()
		_pending_disable[id].append_array(killed)
	else:
		_disable_frame(id, frame, killed)
	_queue_remesh(id)
	islands.wake_near(e.point, e.radius + 2.0)


func _setup_gun() -> void:
	_combat_rng.seed = 0xC0FFEE
	DamageSystem.rng.seed = 0xC0FFEE + 1
	_gun = GunController.new()
	_gun.name = "Gun"
	_gun.rng = _combat_rng
	_gun.aim = camera
	# What a bullet does to bricks is StructuralDamage's to say, and it goes
	# through the same door as every other change to the world.
	_gun.on_structure_hit = func(point: Vector3, dir: Vector3, shot: Dictionary) -> void:
		# The mark, debris and sound of whatever material was struck. Local
		# and cosmetic, so not through the authority. No face normal comes
		# with the hit; facing back up the shot is the mark's plane.
		if _material_fx != null and dir.length() > 0.001:
			_material_fx.impact_at(point, -dir.normalized())
		if bool(shot.blast):
			_blast(point, float(shot.radius))
		else:
			chip(point, float(shot.radius), int(shot.hp))
	add_child(_gun)
	# The walker's own body is not something to shoot.
	camera.mode_changed.connect(func(walking: bool) -> void:
		var body := camera.body()
		var skip: Array[RID] = []
		if walking and body != null:
			skip.append(body.get_rid())
		_gun.exclude = skip)


## Roll a gun of this class and put it in the player's hands.
func _equip_gun(class_id: StringName, gen_seed: int) -> GunInstance:
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var res := GunGenerator.generate(_gun_library, gen_seed, WeaponClass.builtin(class_id), 1)
	return _equip_result(res, class_id)


## A gun made in the asset workshop (AssetGuns) into the player's hands, or null if
## there is no such design.
func _equip_asset_gun(id: StringName, gen_seed: int) -> GunInstance:
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var res := AssetGuns.generate(_gun_library, id, gen_seed, 1)
	if res == null:
		print("[city] no asset gun '%s' (export it from the asset workshop, Alt X)" % id)
		return null
	return _equip_result(res, res.weapon_class.id)


func _equip_result(res: GunGenerator.Result, class_id: StringName) -> GunInstance:
	var gi := GunInstance.from_result(res)
	if _arsenal != null and _player.is_possessing():
		# The hands are the arsenal's: the new gun takes the place of the one held.
		_arsenal.replace_in_hand(gi)
	else:
		if _gun.gun != null:
			_gun.gun.queue_free()
		_gun.equip(gi)
		if _view != null:
			_view.hold(gi)
		else:
			camera.add_child(gi)
			gi.position = Vector3(0.22, -0.2, -0.45)
	var shot := StructuralDamage.for_shot(gi.weapon_class, gi.active_effects)
	print("[city] gun: %s -- %s, %s" % [gi.gun_name, class_id,
			("blast %.2f m" % float(shot.radius)) if bool(shot.blast)
			else ("%d hits a brick" % StructuralDamage.hits_per_brick(gi.weapon_class))])
	return gi


## What a kill drops (LootRoller, Docs/Weapons/PROGRESSION_SPEC.md 3): guns of the
## fight's tier on the floor round `at`, as `archetype` (trash .. boss) is generous.
func drop_loot(at: Vector3, archetype: StringName = &"trash") -> Array[WorldGunPickup]:
	var out: Array[WorldGunPickup] = []
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var t := arena.level if arena != null else 1
	var drops := LootRoller.roll_drops(archetype, t, t, _loot_rng)
	for i in drops.size():
		var d: LootRoller.Drop = drops[i]
		var cls: StringName = GUN_CLASSES[_loot_rng.randi() % GUN_CLASSES.size()]
		var gen_seed := _loot_rng.randi()
		# A third of the ordnance drops is the arc caster, the shock special weapon -- off
		# the seed, so the loot stream draws what it always did.
		if cls == &"rocket_launcher" and gen_seed % 3 == 0:
			cls = GunController.ARC_CASTER
		# A light or a heavy, off the seed and the rarity (COMBAT_DESIGN 7.8).
		var res := GunGenerator.generate(_gun_library, gen_seed, WeaponClass.rolled(cls, gen_seed,
				d.rarity), d.tier, d.rarity, d.luck)
		var a := TAU * float(i) / float(maxi(drops.size(), 1))
		out.append(drop_gun(res, at + Vector3(cos(a), 0.0, sin(a)) * (0.5 if drops.size() > 1 else 0.0)
				+ Vector3.UP * 0.8))
	return out


## The pods' own dice: a pod drop never moves what the guns' loot stream draws.
var _pod_rng := RandomNumberGenerator.new()


## A pod on the ground at `at`, of the fight's tier and a rolled rarity (as loot is): the
## player walking onto it takes it into the backpack's mech page.
func drop_pod(at: Vector3) -> WorldPodPickup:
	if _pod_rng.seed == 0:
		_pod_rng.seed = 0x90D0
	var t := arena.level if arena != null else 1
	var pod := PodGenerator.generate(_pod_rng.randi(), LootRoller.roll_rarity(_pod_rng,
			LootRoller.total_luck(t, t, &"heavy")), t)
	var w := WorldPodPickup.create(pod)
	add_child(w)
	w.global_position = _on_ground(at)
	w.taker_of = func() -> Node3D:
		return _player_pawn.body if _player.is_possessing() and _player_pawn != null 				and is_instance_valid(_player_pawn) else null
	w.picked.connect(func(p: PodGenerator.Result) -> void:
		_pod_stash().stash.append(p)
		if _arsenal != null:
			_arsenal._say("Pod: %s (backpack, mech page)" % p.pod_name)
		print("[city] picked up pod %s" % p.pod_name))
	print("[city] pod dropped: %s" % pod.pod_name)
	return w


## The backpack's mech page, made if the player has had no mech yet: where pods go.
func _pod_stash() -> MechLoadoutScreen:
	if _mech_screen == null:
		_mech_screen = MechLoadoutScreen.new()
		_mech_screen.name = "MechLoadout"
		add_child(_mech_screen)
		if _arsenal != null:
			_arsenal.mech_screen = _mech_screen
	return _mech_screen


## A gun on the floor, made from what it is (the recipe, not a re-roll): up off the
## ground at `at` and tossed, it falls, lands and lies (WorldGunPickup). What a dead
## soldier's gun becomes, and every loot drop.
func drop_gun(res: GunGenerator.Result, at: Vector3) -> WorldGunPickup:
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var p := WorldGunPickup.create(_gun_library, res)
	add_child(p)
	p.global_position = at
	p.toss()
	return p


## Put the gun in the player's hands, rolling one if there is none.
func _arm_gun() -> void:
	_gun_armed = true
	if _gun.gun == null:
		_equip_gun(GUN_CLASSES[_gun_class], _combat_rng.randi())
	_gun.gun.visible = true


func _mode_word() -> String:
	if _pilot.is_piloting():
		return "PILOTING (M leaves) · Q dash"
	if _player.is_possessing():
		return "PLAYING (V leaves)"
	return "WALKING" if camera.is_walking() else "FLYING"


## Stand a player pawn with its feet at `feet` and take its controls. The camera
## stops flying and rides the pawn's eye; the gun goes into its hands.
func _enter_pawn(feet: Vector3) -> void:
	if camera.is_walking():
		camera.set_walking(false)
	if _player_pawn == null or not is_instance_valid(_player_pawn):
		_player_pawn = Pawn.spawn(self, feet, 0)
		_player_pawn.moves = PawnMoves.new(_player_pawn)
	else:
		_player_pawn.place(feet)
	if _player.get_parent() == null:
		_player.name = "Player"
		add_child(_player)
	camera.set_process(false)
	camera.allow_walk = false
	_player.possess(_player_pawn, camera)
	_arm_gun()
	_player_pawn.gun = _gun
	_player.melee_context = _melee_context
	_gun.exclude = [_player_pawn.body.get_rid()] as Array[RID]
	if not _player_pawn.has_meta(&"weight"):
		_player_pawn.set_meta(&"weight", weight.add(_player_pawn.body, _player_pawn.feet,
				WeightTracker.PERSON))
	if _mech_cmd != null:
		_mech_cmd.brain.leader = _player_pawn
	_fps_on()
	var first := _kit == null
	if first:
		if _gun_library == null:
			_gun_library = GunPlaceholderParts.build_library()
		_kit = PlayerKit.attach(self, _player, camera, _gun, ai_services, {
				"scripted": _scripted, "library": _gun_library, "world": self,
				"meter_at": Vector2(20.0, 180.0), "rng": _loot_rng,
				"board": _hold_board, "mech_screen": _mech_screen})
	# Melee hits and the arsenal's rolls at the fight's tier: the arena's level,
	# else tier 1 (COMBAT_DESIGN 4.1). The arena marks hits on its own feedback.
	_kit.enter(_player_pawn, _view, arena.level if arena != null else 1,
			arena.feedback if arena != null else null)
	_arsenal = _kit.arsenal
	if first and not _scripted:
		_place_workbench(feet)
	print("[city] playing: pawn at %v" % feet)


## A safehouse workbench by where the player first stands (COMBAT_DESIGN 1.2): a stand-in
## until there are safehouses. Set down on what is under it, a few steps ahead.
func _place_workbench(feet: Vector3) -> void:
	var yaw := _player_pawn.intents.look_yaw if _player_pawn != null else 0.0
	var at := feet + Vector3(-sin(yaw), 0.0, -cos(yaw)) * 3.0 + Vector3(-cos(yaw), 0.0, sin(yaw)) * 1.5
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 2.0,
			at + Vector3.DOWN * 6.0, Layers.WORLD))
	if not hit.is_empty():
		at = hit.position
	var w := Workbench.create()
	add_child(w)
	w.global_position = at
	w.rotation.y = yaw


## The gun into the view's hands, its HUD up, the debug overlays away.
func _fps_on() -> void:
	if _view == null:
		_view = PlayerView.new()
		_view.name = "PlayerView"
		add_child(_view)
		_view.setup(camera, _player_pawn, _gun)
	_player.view = _view
	if stats_label != null:
		_stats_were_visible = stats_label.visible
		stats_label.visible = false
	if _reticle != null:
		_reticle.visible = false


func _fps_off() -> void:
	_player.view = null
	if _view != null:
		_view.teardown()
		_view.queue_free()
		_view = null
	if _kit != null:
		_kit.leave()
	if stats_label != null:
		stats_label.visible = _stats_were_visible
	if _reticle != null:
		_reticle.visible = camera.capture_mouse


func _leave_pawn() -> void:
	_fps_off()
	_player.release()
	camera.set_process(true)
	camera.allow_walk = camera.capture_mouse
	if _player_pawn != null and is_instance_valid(_player_pawn):
		_player_pawn.gun = null
		if _player_pawn.has_meta(&"weight"):
			weight.remove(int(_player_pawn.get_meta(&"weight")))
		_player_pawn.body.queue_free()
	_player_pawn = null
	_gun.set_trigger(false)
	_gun.exclude = [] as Array[RID]
	_gun.team = -1


## Climb into the mech -- spawning one on the ground ahead of the camera if there
## is none -- and take its controls. Its arm gets a gun of its own. On foot it is
## got into from its hatch's side, and only our own: trying another side's sets
## it off (Docs/AIRoster.md 4.4, R14). From the free camera it is a debug key
## and boards from anywhere.
func _board_mech() -> void:
	_boarded_on_foot = false
	if _player.is_possessing() and _player_pawn != null and is_instance_valid(_player_pawn):
		var near := _mech_at_hatch(_player_pawn)
		if near == null:
			# Firefight: no hatch in reach is a call for the mech (Titanfall's).
			if arena is FirefightDirector and (arena as FirefightDirector).call_mech(_aim_point()):
				return
			print("[city] no mech's hatch within reach: walk to its hatch side")
			return
		if not near.layers.try_enter(_player_pawn.team):
			print("[city] not our mech: its self-destruct is lit -- get clear")
			return
		if near != _mech:
			print("[city] a mech of ours, but not yours to drive")
			return
		_boarded_on_foot = true
		_leave_pawn()
	if camera.is_walking():
		camera.set_walking(false)
	if _mech == null or not is_instance_valid(_mech):
		var ahead := camera.global_position - camera.global_transform.basis.z * 12.0
		var q := PhysicsRayQueryParameters3D.create(ahead + Vector3.UP * 50.0,
				ahead - Vector3.UP * 200.0, Layers.PAWN_MASK)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		var feet: Vector3 = hit.position if not hit.is_empty() else Vector3(ahead.x, 0.0, ahead.z)
		_spawn_mech(feet, camera.global_rotation.y)
	if _pilot.get_parent() == null:
		_pilot.name = "Pilot"
		add_child(_pilot)
	camera.set_process(false)
	camera.allow_walk = false
	# The pilot's keys drive it now, not its brain.
	var br := _mech.body.get_node_or_null(^"MechBrain") as MechBrain
	if br != null:
		br.enabled = false
	# The player's own gun is put down: the mech's arm is the only gun now.
	_gun_armed = false
	_gun.set_trigger(false)
	if _gun.gun != null:
		_gun.gun.visible = false
	_pilot.board(_mech, camera)
	_mech.occupy()
	print("[city] piloting: mech at %v, %s" % [_mech.feet(), _mech.gun.gun.gun_name])


## The enemy mech or tank the player's pawn is on (Rodeo, VehicleDeck), or null.
func _riding() -> Object:
	if _player_pawn == null or not is_instance_valid(_player_pawn) or not _player_pawn.has_meta(&"riding"):
		return null
	var m: Object = _player_pawn.get_meta(&"riding")
	return m if m != null and is_instance_valid(m) else null


## The vehicle of ours the player's pawn rides on (VehicleDeck), or null.
func _aboard() -> Node3D:
	if _player_pawn == null or not is_instance_valid(_player_pawn) or not _player_pawn.has_meta(&"aboard"):
		return null
	var v: Node3D = _player_pawn.get_meta(&"aboard")
	return v if v != null and is_instance_valid(v) else null


## E on foot: climb the enemy mech within reach, if there is one.
## The melee button, before it is a melee (PlayerController.melee_context): on a
## mech's back it is the charge's (held, _process); next to one it climbs. True when
## it was used here.
func _melee_context() -> bool:
	if _riding() != null:
		return true
	return _rodeo_climb()


func _rodeo_climb() -> bool:
	if _riding() != null or _aboard() != null:
		return false
	for n in get_tree().get_nodes_in_group(&"mech_layers"):
		var ml := n as MechLayers
		if ml != null and not ml.dead and ml.mech.rodeo.can_climb(_player_pawn):
			ml.mech.rodeo.climb(_player_pawn)
			print("[city] on its back: hold E to plant the charge (%.1f s), jump to get off" % Rodeo.PLANT_SECONDS)
			return true
	# An enemy tank: onto its back deck, to pry the hatch (Halo's boarding).
	for t in tanks:
		if is_instance_valid(t) and t.rodeo.can_climb(_player_pawn):
			t.rodeo.climb(_player_pawn)
			print("[city] on its deck: hold E to pry the hatch open (%.1f s) and drag the crew out, jump to get off" % VehicleDeck.PRY_SECONDS)
			return true
	# An enemy truck: its cab, at once.
	for n in get_tree().get_nodes_in_group(&"trucks"):
		var truck := n as TransportTruck
		if truck != null and truck.can_hijack(_player_pawn):
			print("[city] hijacked a truck%s" % (": its squad is out at the tailgate" if not truck.cargo.is_empty() else ""))
			truck.hijack(_player_pawn)
			_drive_vehicle(truck)
			return true
	return false


## What a rider on `m` hears of it: the player's own ride, in the log.
func _wire_rodeo(m: Mech) -> void:
	var r := m.rodeo
	r.noticed.connect(func(p: Pawn) -> void:
		if p == _player_pawn:
			print("[city] rodeo: it has noticed you"))
	r.climbed.connect(func(_p: Pawn) -> void:
		if m == _mech:
			print("[city] a rider on your mech! C: electric smoke, or scrape it off under something low"))
	r.dropped.connect(func(p: Pawn, why: String) -> void:
		if p == _player_pawn:
			print("[city] rodeo: off (%s)" % why))
	r.charge_planted.connect(func() -> void:
		print("[city] rodeo: charge planted -- %.1f s" % Rodeo.CHARGE_FUSE))
	r.charge_blew.connect(func() -> void:
		print("[city] rodeo: its hatch is off"))
	r.smoked.connect(func() -> void:
		print("[city] rodeo: electric smoke"))


## The mech whose hatch `p` stands at, any side's; null for none.
## Hold reload on foot (PlayerArsenal.interact): into our mech at its hatch, or the
## vehicle beside -- what M does, but only when there is one to get in. True if it did.
func _hold_board() -> bool:
	if not _player.is_possessing() or _player_pawn == null or not is_instance_valid(_player_pawn):
		return false
	var m := _mech_at_hatch(_player_pawn)
	if m != null and m == _mech:
		_board_mech()
		return true
	var v := _vehicle_at_side()
	if v != null:
		_use_vehicle(v)
		return true
	return false


func _mech_at_hatch(p: Pawn) -> Mech:
	for n in get_tree().get_nodes_in_group(&"mech_layers"):
		var ml := n as MechLayers
		if ml != null and not ml.dead and ml.mech.can_reach(p):
			return ml.mech
	return null


func _spawn_mech(feet: Vector3, yaw: float) -> Mech:
	_mech = Mech.spawn(self, feet, yaw, 0)
	# The player's dressing on it -- not in a scripted pass, which must not change with what
	# this machine's player has put on.
	if not _scripted:   # a scripted pass's mech stays the boxes its numbers were taken with
		MechAssembler.dress_rolled(_mech, hash(feet), "normal", null, false, "player")
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	_give_pods(_mech)
	var res := GunGenerator.generate(_gun_library, _combat_rng.randi(),
			WeaponClass.builtin(&"lmg"), 1)
	var gi := GunInstance.from_result(res)
	gi.visible = false  # the arm's greybox is the gun, for now
	_mech.arm.add_child(gi)
	_mech.gun.equip(gi)
	# A mech gun made in the workshop, if there is one, in its hand instead (stage 7) --
	# not in a scripted pass, which must not change with what this machine has saved.
	if not _scripted:
		MechAssembler.arm_gun(_mech, MechAssembler.roll_gun(_gun_library, hash(feet)))
	_mech.gun.rng = _combat_rng
	_mech.gun.on_structure_hit = _gun.on_structure_hit
	# The player's mech's kills are the player's XP (PlayerLevel).
	_mech.gun.set_meta(PlayerLevel.SOURCE_META, _player.progress)
	_wire_mech(_mech)
	# Out of the cockpit it fights on its own, on the one button (AI.md 2.1).
	var br := MechBrain.attach(ai_services, _mech, mech_nav, MechTree.companion(), 0)
	br.enabled = false
	mech_brains.append(br)
	_mech_cmd = MechCommand.new(br, _player_pawn)
	return _mech


func _leave_mech() -> void:
	_pilot.leave()
	camera.set_process(true)
	camera.allow_walk = camera.capture_mouse
	if _mech_cmd != null and is_instance_valid(_mech):
		# Out: it holds where it stands until told otherwise.
		var br := _mech_cmd.brain
		br.enabled = true
		br.order = MechBrain.Order.HOLD
		br.order_point = _mech.feet()
	if is_instance_valid(_mech):
		_mech.dismount()
		# Out of the hatch, on foot, if that is how the player got in.
		if _boarded_on_foot:
			_boarded_on_foot = false
			_enter_pawn(_mech.mount_point())


# --- tanks (Docs/AIRoster.md RO10) --------------------------------------------------

## A tank of side `team` on the ground at `feet`: a cannon that opens walls, a
## machine gun, a brain for its crew -- and a crew of soldiers of its side in
## both seats if `crewed`.
func _spawn_tank(feet: Vector3, yaw: float, team: int, crewed: bool) -> Tank:
	if ai_services.world3d == null:
		ai_services.world3d = get_world_3d()
		ai_services.on_structure_hit = _gun.on_structure_hit
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var main := GunInstance.from_result(GunGenerator.generate(_gun_library, _combat_rng.randi(),
			WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(_gun_library, _combat_rng.randi(),
			WeaponClass.builtin(&"lmg"), 1))
	var t := Tank.make(ai_services, self, feet, yaw, team, main, mg, _gun.on_structure_hit, _combat_rng)
	ai_services.add_pawn(t.make_target())
	TankBrain.attach(ai_services, t)
	weight.add(t, t.feet, WeightTracker.MECH)
	if crewed:
		for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
			var so := _spawn_soldier(feet)
			so.team = team
			so.pawn.team = team
			t.board(so.pawn, seat, true)
	t.wrecked.connect(func(w: Tank) -> void:
		print("[city] tank wrecked at %v%s" % [w.feet(), " -- its ammo cooked off" if w.cooked_off else ""]))
	t.damaged.connect(func(zone: StringName) -> void:
		var whose := "your tank" if _vehicle_pilot.vehicle == t else "a tank of side %d" % t.team
		print("[city] %s: %s" % [whose, ZONE_LOST_LINES.get(zone, String(zone) + " gone")]))
	_wire_deck(t)
	t.player_thrown.connect(func() -> void:
		if _vehicle_pilot.vehicle == t:
			print("[city] a boarder pried the hatch open: you are dragged out")
			_leave_vehicle(Tank.DRAGGED_HURT))
	tanks.append(t)
	print("[city] tank of side %d at %v, %s" % [team, feet, "crewed" if crewed else "empty"])
	return t


## The enemy's tank (Z), with a squad that screens it (AIVehicles.md 4): it goes
## for the player at the squad's pace.
func _spawn_enemy_tank(feet: Vector3, yaw: float) -> Tank:
	var t := _spawn_tank(feet, yaw, 1, true)
	var back := Basis(Vector3.UP, yaw).z
	var q := _spawn_squad(ai_nav.snap(feet + back * 9.0))
	var br := t.get_node(^"TankBrain") as TankBrain
	br.escort = q
	if _player_pawn != null and is_instance_valid(_player_pawn):
		br.send(_player_pawn.feet())
	return t


## The vehicle -- a tank or a truck, any side's -- the player's pawn stands
## beside; null for none.
func _vehicle_at_side() -> CharacterBody3D:
	if not _player.is_possessing() or _player_pawn == null or not is_instance_valid(_player_pawn):
		return null
	for t in tanks:
		if is_instance_valid(t) and not t.is_wrecked() and t.can_reach(_player_pawn):
			return t
	for n in get_tree().get_nodes_in_group(&"trucks"):
		var truck := n as TransportTruck
		if truck != null and not truck.is_wrecked() and (truck.can_reach(_player_pawn)
				or truck.rodeo.beside(_player_pawn, VehicleDeck.RIDE_REACH)):
			return truck
	return null


## M beside a vehicle (Halo): the wheel if nobody has it -- an empty one of any
## side, a tank of ours with no driver, a truck from beside its cab -- and
## otherwise a place on its deck, if it is ours.
func _use_vehicle(v: CharacterBody3D) -> void:
	var drive := false
	if v is Tank:
		# A seat: the driver's if it is free, the gunner's with one of ours driving.
		var t := v as Tank
		drive = not t.player_in and (t.is_empty() or (t.team == _player_pawn.team
				and (t.seat_free(Tank.Seat.DRIVER) or t.seat_free(Tank.Seat.GUNNER))))
	else:
		var truck := v as TransportTruck
		drive = truck.is_empty() and truck.can_reach(_player_pawn)
	if drive:
		_drive_vehicle(v)
	elif v.rodeo.ride(_player_pawn):
		print("[city] riding on it: shoot from there; jump or M to get off")
	elif v.team == _player_pawn.team:
		print("[city] no room on it")
	else:
		print("[city] not yours: E beside it to %s" % ("climb on and pry its hatch" if v is Tank else "take its cab"))


## In at the wheel (a tank: both seats). An empty vehicle of any side, or one of ours.
func _drive_vehicle(v: CharacterBody3D) -> void:
	if not v.take_player(_player_pawn.team):
		print("[city] its crew is in it: not yours to take")
		return
	_leave_pawn()
	# The free camera's gun stays down: the buttons are the vehicle's (its view
	# drew over the tank, and its left button fired beside the cannon).
	_gun_armed = false
	_gun.set_trigger(false)
	if _gun.gun != null:
		_gun.gun.visible = false
	if camera.is_walking():
		camera.set_walking(false)
	if _vehicle_pilot.get_parent() == null:
		_vehicle_pilot.name = "VehiclePilot"
		add_child(_vehicle_pilot)
	camera.set_process(false)
	camera.allow_walk = false
	_vehicle_pilot.board(v, camera)
	if not v.wrecked.is_connected(_on_driven_wrecked):
		v.wrecked.connect(_on_driven_wrecked)
	_hop_in_at = 0.0
	if v is Tank:
		print("[city] in a tank, %s; C inside/behind, M to get out" % VehiclePilot.seat_line(v as Tank))
	else:
		if (v as TransportTruck).is_apc():
			print("[city] driving an APC: W/S throttle, A/D steer, LMB its gun, C inside/behind, M to get out")
		else:
			print("[city] driving a truck: W/S throttle, A/D steer, C inside/behind, M to get out -- friends near hop in the back")


## Out on foot beside it, `hurt` for a wreck or a boarder; its riders get down
## with the driver -- they have a fight to get back to.
func _leave_vehicle(hurt := 0.0) -> void:
	var v := _vehicle_pilot.vehicle
	_vehicle_pilot.leave()
	camera.set_process(true)
	camera.allow_walk = camera.capture_mouse
	if v != null and is_instance_valid(v):
		v.rodeo.all_off("driver out")
		_enter_pawn(v.mount_point())
		if hurt > 0.0 and _player_pawn != null and _player_pawn.health != null:
			_player_pawn.health.apply_impact(hurt, &"")


func _on_driven_wrecked(v: Node) -> void:
	if _vehicle_pilot.vehicle == v:
		print("[city] wrecked: you climb out")
		_leave_vehicle(float(v.get(&"bail_hurt")) if v is Tank else Tank.BAIL_HURT)


## Halo's marines: while the player drives a vehicle of theirs and it stands
## still, soldiers of the player's side near it go and get on its deck, as many
## as it has room for. They ride and shoot until the player gets out.
func _hop_in() -> void:
	var now := ai_services.now()
	if now < _hop_in_at or not _vehicle_pilot.is_driving():
		return
	_hop_in_at = now + 1.0
	var v := _vehicle_pilot.vehicle
	if v.is_wrecked() or Vector2(v.velocity.x, v.velocity.z).length() > 3.0:
		return
	var deck: VehicleDeck = v.rodeo
	var room := deck.riders.size() - deck.rider_count()
	# A tank's gunner's seat first, if the player drives it alone (Halo's
	# marine on the Warthog's gun).
	var tank := v as Tank
	var seat := Tank.Seat.GUNNER if tank != null and tank.player_drives() \
			and tank.seat_free(Tank.Seat.GUNNER) else -1
	var near := []
	for p in ai_services.pawns:
		if not is_instance_valid(p) or p.team != v.team or p.body == null:
			continue
		var so := p.body.get_node_or_null(^"Soldier") as Soldier
		if so == null or p.health == null or p.health.is_dead():
			continue
		if so.board_vehicle == v:
			if so.board_seat >= 0:
				seat = -1
			else:
				room -= 1
			continue
		if so.board_vehicle != null or so.board_mech != null or so.rodeo_target != null \
				or p.has_meta(&"riding") or p.has_meta(&"aboard") or p.has_meta(&"in_vehicle"):
			continue
		var d := p.feet().distance_to(v.feet())
		if d < HOP_IN_RANGE:
			near.append([d, so])
	near.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	if seat >= 0 and not near.is_empty():
		(near.pop_front()[1] as Soldier).ride_on(v, seat)
	for i in mini(room, near.size()):
		(near[i][1] as Soldier).ride_on(v)


## What a deck does, in the log for the player.
func _wire_deck(v: Node3D) -> void:
	var d: VehicleDeck = v.rodeo
	d.climbed.connect(func(p: Pawn) -> void:
		if v == _vehicle_pilot.vehicle:
			print("[city] a boarder on your tank! Get out (M) and shoot it off, before it pries the hatch")
		elif p == _player_pawn:
			pass)
	d.noticed.connect(func(p: Pawn) -> void:
		if p == _player_pawn:
			print("[city] boarding: they have seen you"))
	d.dropped.connect(func(p: Pawn, why: String) -> void:
		if p == _player_pawn and why != "in":
			print("[city] boarding: off (%s)" % why))
	d.hijacked.connect(func(by: Pawn) -> void:
		if by == _player_pawn:
			print("[city] the hatch is open: its crew is out, and it is yours")
			_drive_vehicle(v)
		else:
			print("[city] a boarder has a tank of side %d" % v.team))
	d.rider_off.connect(func(p: Pawn, why: String) -> void:
		if p == _player_pawn:
			print("[city] off the deck (%s)" % why))


## A truck of side `team` at `feet`, facing `yaw`, with `cargo` in the back
## (put down at its tailgate when it stops: _truck_unload).
func _spawn_truck(feet: Vector3, yaw: float, team: int, cargo: Array[StringName],
		kind := &"truck") -> TransportTruck:
	var gi: GunInstance = null
	if kind == &"apc":
		if ai_services.world3d == null:
			ai_services.world3d = get_world_3d()
			ai_services.on_structure_hit = _gun.on_structure_hit
		if _gun_library == null:
			_gun_library = GunPlaceholderParts.build_library()
		gi = GunInstance.from_result(GunGenerator.generate(_gun_library, _combat_rng.randi(),
				WeaponClass.builtin(&"lmg"), 1))
	var truck := TransportTruck.make(ai_services, self, feet, yaw, kind, gi, _gun.on_structure_hit, _combat_rng)
	truck.team = team
	truck.cargo = cargo
	truck.arrived.connect(_truck_unload)
	_wire_deck(truck)
	truck.damaged.connect(func(zone: StringName) -> void:
		var whose := "your truck" if _vehicle_pilot.vehicle == truck else "a truck of side %d" % truck.team
		print("[city] %s: %s" % [whose, TRUCK_ZONE_LOST_LINES.get(zone, String(zone) + " gone")]))
	truck.wrecked.connect(func(w: TransportTruck) -> void:
		print("[city] truck wrecked at %v%s" % [w.feet(), (" with %d aboard" % w.cargo.size()) if not w.cargo.is_empty() else ""])
		w.cargo.clear()
		trucks.erase(w)
		get_tree().create_timer(10.0).timeout.connect(func() -> void:
			if is_instance_valid(w):
				w.queue_free()))
	trucks.append(truck)
	print("[city] %s of side %d at %v%s" % [truck.name.to_lower(), team, feet,
			(", %d in the back" % cargo.size()) if not cargo.is_empty() else ", empty"])
	return truck


## A truck spawned here has stopped (or was hijacked): its squad is put down at
## the tailgate, on the side away from the player.
func _truck_unload(truck: TransportTruck) -> void:
	if truck.cargo.is_empty():
		return
	var threat := _player_pawn.feet() if _player_pawn != null and is_instance_valid(_player_pawn) \
			else truck.global_position + Vector3.FORWARD
	var spots := truck.tailgate_points(threat, truck.cargo.size())
	var members: Array[Soldier] = []
	for i in truck.cargo.size():
		var at: Vector3 = spots[i] if i < spots.size() else ai_nav.snap(truck.global_position
				+ truck.global_transform.basis.z * (truck.size.z * 0.5 + 1.2 + i))
		members.append(_spawn_soldier(at))
	print("[city] %s unloaded %d at %v (%s)" % [truck.name.to_lower(), truck.cargo.size(), truck.global_position,
			truck.stopped_because])
	truck.cargo.clear()
	# An APC's squad is one, and it covers them (moving cover).
	if truck.is_apc() and not members.is_empty():
		var q := Squad.make(ai_services, self, members, 1)
		squads.append(q)
		if _player_pawn != null and is_instance_valid(_player_pawn):
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = _player_pawn.feet()
			for m in members:
				m.knowledge().heard(_player_pawn, _player_pawn.feet(), ai_services.now())
			q.give(o)
		truck.escort = q


## A mech's weight and its fall rule, on this city (Docs/AI.md 3.10, 3.11).
func _wire_mech(m: Mech) -> void:
	m.fall.decides = authority.may_decide()
	m.fall.floor_at = _mech_floor_at
	m.fall.on_break = _mech_break
	m.fall.next_floor = _next_floor_below
	weight.add(m.body, m.feet, Mech.MASS)
	_wire_rodeo(m)


## The enemy's mech (Y), ahead of the camera: an LMG, a launcher for walls, and
## the enemy tree -- it breaches to get at infantry (AI.md 6.4).
## `recipe`: which of the roster's mechs it is (AIRoster.md RO11: a commander
## buys one by its recipe).
## Which workshop mech Ctrl Y spawned last.
var _mech_design := -1
## The figures Ctrl T put down, and which design was last.
var _figures: Array[Figure] = []
var _figure_design := -1


func _spawn_figure() -> String:
	var cat := MechAssembler.catalog(true)
	var made := Figure.designs(cat)
	if made.is_empty():
		return "no figure saved in the asset workshop yet"
	var ids := made.keys()
	ids.sort()
	_figure_design = (_figure_design + 1) % ids.size()
	var b := PartBuilder.generate("figure", made[ids[_figure_design]], hash(ids[_figure_design]), cat)
	var f := Figure.make(b)
	if f == null:
		return "figure %s does not go together: %s" % [ids[_figure_design], "; ".join(b.problems)]
	f.position = _on_ground(camera.global_position - camera.global_transform.basis.z * 6.0)
	f.wander = true
	add_child(f)
	_figures.append(f)
	return "figure %s" % ids[_figure_design]


var _builder: CharacterBuilder


## Ctrl Alt T: the character builder. What it puts in the world stands ahead of the camera
## and follows the player on foot (else walks a circle).
func _open_character_builder() -> void:
	if _builder == null:
		_builder = CharacterBuilder.new()
		_builder.name = "CharacterBuilder"
		add_child(_builder)
		_builder.spawned.connect(func(f: Figure) -> void:
			f.position = _on_ground(camera.global_position - camera.global_transform.basis.z * 4.0)
			add_child(f)
			if _player.is_possessing() and _player_pawn != null and is_instance_valid(_player_pawn):
				f.mode = "follow"
				f.target = _player_pawn.body
			else:
				f.mode = "wander"
			_figures.append(f)
			print("[city] character put down, %s" % f.mode))
	_builder.open(MechAssembler.catalog(true))


func _swap_figure_limb() -> String:
	while not _figures.is_empty() and not is_instance_valid(_figures[-1]):
		_figures.pop_back()
	if _figures.is_empty():
		return "no figure to swap a limb of (Ctrl T puts one down)"
	var f := _figures[-1]
	var cat := MechAssembler.catalog()
	var paths: Array = (f.build.at as Dictionary).keys()
	paths.shuffle()
	for path: String in paths:
		var now: PartRecord = f.build.at[path]
		var options := cat.filter({"family": ["figure"], "slot": [now.slot]}).filter(
				func(r: PartRecord) -> bool: return r.id != now.id and f.why_not_swap(path, r) == "")
		if not options.is_empty():
			var pick: PartRecord = options[randi() % options.size()]
			f.swap(path, pick)
			return "figure's %s is now %s" % [path, pick.display_name]
	return "no other part fits any of its slots"
var _dress_colour := 1


## Put a dressing brick on (or take one off) the player's mech's stud nearest the crosshair
## line, within half a metre of it and 30 m off. What happened, in words.
func _dress_at_crosshair(take_off: bool) -> String:
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z
	var best_d := 0.5
	var best := {}
	var parts := PartDressing.parts_of(_mech)
	for id: String in parts:
		var part: Node3D = parts[id]
		for st in PartDressing.studs(part).studs:
			var at: Vector3 = part.global_transform * (st.at as Vector3)
			var along := (at - from).dot(dir)
			if along < 0.0 or along > 30.0:
				continue
			var d := (from + dir * along).distance_to(at)
			if d < best_d:
				best_d = d
				best = {"id": id, "key": st.key}
	if best.is_empty():
		return "no stud of your mech under the crosshair"
	var store := PartDressing.load_store()
	var list := PartDressing.of(store, "player", best.id)
	if take_off:
		list = PartDressing.remove(list, best.key)
	else:
		var r := PartDressing.add(parts[best.id], list, best.key, "brick", _dress_colour)
		if not r.ok:
			return "not there: " + String(r.why)
		list = r.list
	PartDressing.put(store, "player", best.id, list)
	PartDressing.save_store(store)
	PartDressing.apply(parts[best.id], list)
	return "%d bricks on %s, %.1f kg" % [list.size(), best.id, PartDressing.mass(list)]
## The player's mech's pods and the mech page of the backpack (Docs/ModularParts.md stage 7).
var _mech_pods: MechPods
var _mech_screen: MechLoadoutScreen
## The pods the player starts with: one of each kind, rolled from fixed seeds.
const START_POD_SEED := 0x90D5


## The player's mech gets its two pod slots, and the backpack its mech page with the
## pods the player has; a missile pod and a shield booster fitted to start (not in a
## scripted pass, whose mech must fight as it always has).
func _give_pods(m: Mech) -> void:
	_mech_pods = MechPods.attach(m, _gun_library, _combat_rng)
	_mech_pods.on_structure_hit = _gun.on_structure_hit
	if _mech_screen == null:
		_mech_screen = MechLoadoutScreen.new()
		_mech_screen.name = "MechLoadout"
		add_child(_mech_screen)
		var kinds := PodGenerator.kinds()
		for i in kinds.size():
			_mech_screen.stash.append(PodGenerator.generate(START_POD_SEED + i, 2, 1, kinds[i]))
		_mech_screen.index = 0
		# Not in a scripted pass: a pass's mech fights as it always has.
		for want in ([] if _scripted else [&"missiles", &"shield_boost"]):
			for i in _mech_screen.stash.size():
				if (_mech_screen.stash[i] as PodGenerator.Result).kind == want:
					_mech_screen.index = i
					_mech_screen.fit_selected(0 if want == &"missiles" else 1)
					break
	else:
		# A new mech of the player's: the pods it had go on it again.
		var old: Array = _mech_screen.pods.slots.duplicate() if _mech_screen.pods != null else []
		for i in old.size():
			if old[i] != null:
				_mech_pods.fit(i, old[i])
	_mech_screen.pods = _mech_pods
	if _arsenal != null:
		_arsenal.mech_screen = _mech_screen


func _spawn_enemy_mech(feet: Vector3, yaw: float, recipe := "medium_gunner", design: PartDesign = null) -> MechBrain:
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var m := Mech.spawn(self, feet, yaw, 1)
	var gi := GunInstance.from_result(GunGenerator.generate(_gun_library, _combat_rng.randi(),
			WeaponClass.builtin(&"lmg"), 1))
	gi.visible = false
	m.arm.add_child(gi)
	m.gun.equip(gi)
	if not _scripted:
		# A mech gun in its hand, seen: the shipped one, or one made in the workshop.
		MechAssembler.arm_gun(m, MechAssembler.roll_gun(_gun_library, hash(feet)))
	m.gun.rng = _combat_rng
	m.gun.on_structure_hit = _gun.on_structure_hit
	_wire_mech(m)
	var br := MechBrain.attach(ai_services, m, mech_nav, MechTree.enemy(), 1)
	# A mech by the roster: its layers and the name over it (AIRoster.md RO6).
	m.set_type(recipe, Roster.shared())
	# Made of parts when there are parts to make it of (Docs/ModularParts.md stage 6): a
	# chassis of its class, every part fitting -- or a design's, of the design's class.
	# Else the boxes. Seeded from where it stands: no roll of the combat dice moves.
	if not _scripted or design != null:   # a scripted pass's mechs stay the boxes it measured
		MechAssembler.dress_rolled(m, hash(feet), MechAssembler.class_of(
				str(Roster.shared().recipe(recipe).get("class", ""))) if design == null else "",
				design, design != null)
	# Its pilot, a soldier of its side, inside: one who can bail out (RO8).
	var pilot := _spawn_soldier(feet)
	m.mount(pilot.pawn, true)
	# One that fights with its fists carries no launcher: it punches its way.
	if not m.no_gun:
		br.arm_launcher(GunInstance.from_result(GunGenerator.generate(_gun_library,
				_combat_rng.randi(), WeaponClass.builtin(&"rocket_launcher"), 1)), _combat_rng,
				_gun.on_structure_hit)
	mech_brains.append(br)
	# Destroyed, it leaves a pod (stage 7's pods as loot) -- not in a scripted pass.
	if not _scripted and m.layers != null:
		m.layers.destroyed.connect(func(_why: String) -> void: drop_pod(m.feet()))
	print("[city] enemy mech (%s) at %v" % [m.name_tag.text if m.name_tag != null else recipe, feet])
	return br


## What a mech's feet land on, for the fall rule: a building's brick is a floor
## (T = 6 bricks; a floor already hanging, T = 3); a loose piece or the ground is
## not. A building still in its shell is made bricks first -- a landing is damage
## (A20).
func _mech_floor_at(feet: Vector3) -> Dictionary:
	var under := feet - Vector3.UP * 0.07
	var v := _block_under_footprint(under)
	if v.x < 0:
		for id in _near_buildings(feet, 1.0):
			var b := registry.get_building(id)
			if b != null and _world_box(b).grow(0.3).has_point(under) 					and _wants_bricks(b, _storeys_for(id, under, 1.0)):
				_promote(id, true, _storeys_for(id, under, 1.0))
				ai_world.sync()
				v = _block_under_footprint(under)
				break
	if v.x < 0:
		return {}
	var id := _building_of_chunk(v.x)
	if id < 0:
		return {}
	var t := FallRule.T
	var h := world.get_headroom(v.x, v.y)
	if h >= 0.0 and not is_inf(h):
		t *= 0.5
	return {"chunk": v.x, "building": id, "t": t}


## The host breaks the floor under a mech: a SHEAR that lets every block in the
## ball go on its own. The pieces land quietly -- the rule, not their landing,
## decides the next floor (R9).
func _mech_break(point: Vector3, radius: float, fl: Dictionary) -> void:
	var id := int(fl.building)
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.SHEAR
	e.target = id
	e.point = point
	e.radius = radius
	e.limit = 48
	e.flags = DamageLog.FLAG_WHOLE
	DamageLog.apply_entry(world, int(fl.chunk), e)
	authority.commit_entry(e)
	islands.quiet_landings(point, radius + 2.5, 3.0)
	_mark_dirty(id)
	_queue_remesh(id)
	var r := Vector3.ONE * (radius + 1.0)
	ai_nav.invalidate_box(AABB(point - r, r * 2.0))


## A mech is three and a half metres across: what it stands on may be under its
## rim, not its middle (a stair shaft, a gap between plates). The middle first,
## then a ring under the rim.
## Only a building's bricks count: the plate it just broke falls with it and is
## under it too, and the rule does not apply to a loose piece (R9).
func _block_under_footprint(under: Vector3) -> Vector2i:
	var v := ai_world.block_at(under)
	if v.x >= 0 and _building_of_chunk(v.x) >= 0:
		return v
	for r in [Mech.RADIUS * 0.5, Mech.RADIUS * 0.9]:
		for k in 8:
			var a := k * TAU / 8.0
			v = ai_world.block_at(under + Vector3(cos(a), 0.0, sin(a)) * r)
			if v.x >= 0 and _building_of_chunk(v.x) >= 0:
				return v
	return Vector2i(-1, -1)


func _mech_ignore_piece(isl: BrickIsland) -> void:
	if not isl.is_valid():
		return
	var box := islands.world_aabb(isl)
	for m in _crashing_mechs():
		var f := m.feet()
		if box.grow(Mech.RADIUS + 1.0).has_point(Vector3(f.x, clampf(f.y, box.position.y, box.end.y), f.z)):
			m.fall.ignore(isl.body)


func _crashing_mechs() -> Array[Mech]:
	var out: Array[Mech] = []
	if _mech != null and is_instance_valid(_mech) and _mech.fall.is_carrying():
		out.append(_mech)
	for br in mech_brains:
		if is_instance_valid(br) and br.mech.fall.is_carrying() and not out.has(br.mech):
			out.append(br.mech)
	for m in _loose_mechs:
		if is_instance_valid(m) and m.fall.is_carrying() and not out.has(m):
			out.append(m)
	return out


## The top of the first building brick (or the ground) straight under `from`,
## or -INF. Pieces are passed: the one it broke is falling under it.
func _next_floor_below(from: Vector3) -> float:
	var p := from
	var stop := from.y - 40.0
	while p.y > stop:
		var v := ai_world.block_at(p)
		if (v.x >= 0 and _building_of_chunk(v.x) >= 0) or (v.x < 0 and ai_world.solid_at(p)):
			return (floorf(p.y / PLATE) + 1.0) * PLATE
		p.y -= PLATE * 0.5
	return -INF


## Which building a chunk is, or -1 (a piece, or nothing).
func _building_of_chunk(chunk: int) -> int:
	var id := int(_chunk_owner.get(chunk, -1))
	if id >= 0:
		var b := registry.get_building(id)
		if b != null and b.is_materialised() and b.chunk == chunk:
			return id
	# A miss -- a loose piece's chunk -- walked the whole register, up to
	# seventeen times a tick per mech standing on rubble (_block_under_footprint).
	# Remembered until any building next takes a chunk.
	if int(_chunk_not_owned.get(chunk, -1)) == registry.materialise_count():
		return -1
	for b in registry.buildings:
		if b.is_materialised() and b.chunk == chunk:
			_chunk_owner[chunk] = b.id
			return b.id
	_chunk_not_owned[chunk] = registry.materialise_count()
	return -1


func _weight_load(chunk: int, owner_id: int, cell: Vector3i, mass: float) -> void:
	var id := _building_of_chunk(chunk)
	if id < 0:
		return
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.LOAD
	e.target = id
	e.owner = owner_id
	e.radius = mass
	e.points.append(Vector3(cell))
	DamageLog.apply_entry(world, chunk, e)
	authority.commit_entry(e)


func _weight_unload(chunk: int, owner_id: int) -> void:
	var id := _building_of_chunk(chunk)
	if id < 0:
		return
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.UNLOAD
	e.target = id
	e.owner = owner_id
	DamageLog.apply_entry(world, chunk, e)
	authority.commit_entry(e)


func _weight_solve(chunk: int) -> void:
	var id := _building_of_chunk(chunk)
	if id >= 0:
		_mark_dirty(id)


## Where the player is aiming, for ATTACK_AREA: the camera's ray, on whatever it
## meets. INF at nothing.
func _aim_point() -> Vector3:
	var from := camera.global_position
	var ex: Array[RID] = []
	if _player_pawn != null and is_instance_valid(_player_pawn):
		ex.append(_player_pawn.body.get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, from - camera.global_transform.basis.z * 300.0,
			Layers.PAWN_MASK, ex)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if not hit.is_empty() else Vector3.INF


## Shell box `k` of building `id`, as an AIWorld proxy id. A shell is five boxes
## for a tower; a player build's shell can be more.
func _proxy_id(id: int, k: int) -> int:
	return id * 64 + k


func _drop_proxies(id: int) -> void:
	for k in 64:
		ai_world.remove_proxy(_proxy_id(id, k))


## A large piece has come to rest: what is it lying on? Every standing brick just
## under one of its own takes a share of its weight -- a LOAD command per
## building, applied here and replayed on every client -- and that building is
## solved again, so a hanging section under it can give way (AI.md 3.10). Host
## only: the loads are how a client learns of them.
func _wreck_settled(isl: BrickIsland) -> void:
	if not authority.may_decide() or not isl.is_valid() or not isl.landmark or isl.piece_id < 0:
		return
	_wreck_load(isl)
	# Then does it reach what holds it? (Its weight first: what it lies on
	# breaking under it is what brings the rest down -- asked first, a close
	# collapse came down in three pieces where it came down in more.)
	if isl.is_valid():
		_span_piece(isl)


func _wreck_load(isl: BrickIsland) -> void:
	var xf := isl.chunk_transform()
	var contacts := {}   # building id -> Array of absolute cells
	var total := 0
	# Every brick's point just under it, and the building cell there if solid
	# (BrickWorld.rest_contacts) -- for the buildings near the piece's box, found
	# once: every brick's point is inside it. Walked in script, a Dictionary a
	# brick and a building lookup per brick, it was 12-43 ms for a piece of
	# 4,000-8,000 bricks coming to rest, and 107 for one of 2,000 boxes -- the
	# worst tick of a big collapse by four times, every time one settled.
	var box := islands.world_aabb(isl)
	for id in _near_buildings(box.get_center(), maxf(box.size.x, box.size.z) * 0.5 + 0.3):
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var cells := world.rest_contacts(isl.chunk, xf, b.chunk)
		if cells.is_empty():
			continue
		var at_list := []
		for k in range(0, cells.size(), 3):
			at_list.append(Vector3i(cells[k], cells[k + 1], cells[k + 2]))
		contacts[id] = at_list
		total += at_list.size()
	var before: Array = _wreck_loads.get(isl.piece_id, [])
	var was: Dictionary = _wreck_state.get(isl.piece_id, {})
	for id in before:
		if not contacts.has(id):
			_wreck_unload_one(isl.piece_id, int(id))
	if total == 0:
		_wreck_loads.erase(isl.piece_id)
		_wreck_state.erase(isl.piece_id)
		return
	var mass_each := world.get_chunk_mass(isl.chunk) / float(total)
	var now_state := {}
	for id in contacts:
		now_state[id] = [contacts[id], mass_each]
		# The same cells under the same weight: nothing to say.
		if was.has(id) and was[id][0] == contacts[id] and is_equal_approx(float(was[id][1]), mass_each):
			continue
		var e := DamageLog.Entry.new()
		e.tick = Engine.get_physics_frames()
		e.kind = DamageLog.Kind.LOAD
		e.target = int(id)
		e.owner = isl.piece_id
		e.radius = mass_each
		for at in contacts[id]:
			e.points.append(Vector3(at))
		DamageLog.apply_entry(world, registry.get_building(int(id)).chunk, e)
		authority.commit_entry(e)
		_mark_dirty(int(id))
	_wreck_loads[isl.piece_id] = contacts.keys()
	_wreck_state[isl.piece_id] = now_state
	_wreck_load_count += 1


var _wreck_load_count := 0


## A piece come to rest lying level -- a building's floors that came away whole
## when its ground storey went, lying across what is left of it -- is held only
## where it rests on something: a building's bricks, or the ground. Past its
## reach from those (BrickStrength.span_reach) it gives way, as a standing building's floor
## does (BrickWorld.cut_spans_resting; Docs/Structures.md 2.3): the rim is cut,
## and what it bounded is shed from the piece and falls, a DETACH for every
## machine as any piece's. Resting on another piece is not held, yet. True when
## it was cut.
func _span_piece(isl: BrickIsland) -> bool:
	var box := islands.world_aabb(isl)
	if maxf(box.size.x, box.size.z) < BrickStrength.span_reach * BrickPalette.STUD_M * 2.0:
		return false
	# Far from everybody a collapse is a few big pieces by rule, and a landing
	# there breaks nothing (IslandManager.FRACTURE_RANGE); nor does this. Cut
	# there, a far collapse came down in three pieces where it is one
	# (collapse_probe).
	var points := islands.interest_points()
	if points.is_empty() or islands._nearest_interest(box.get_center(), points) > IslandManager.FRACTURE_RANGE:
		return false
	var chunks := PackedInt32Array()
	for id in _near_buildings(box.get_center(), maxf(box.size.x, box.size.z) * 0.5 + 0.3):
		var b := registry.get_building(id)
		if b != null and b.is_materialised():
			chunks.append(b.chunk)
	var ground := -1.0e9 if _terrain_mode else 0.0
	var t0 := Time.get_ticks_usec()
	var rim := world.cut_spans_resting(isl.chunk, isl.chunk_transform(), chunks, ground, BrickStrength.span_reach, true)
	_span_time(t0)
	if rim.is_empty():
		return false
	span_cuts[0] += 1
	span_cuts[1] += rim.size()
	print("[city] piece %d: lying across what holds it, past its reach (%.0f studs) -- gives way, %d bricks round it" % [
			isl.piece_id, BrickStrength.span_reach, rim.size()])
	islands.solve_island(isl)
	islands.rebuild_mesh(isl)
	return true


func _wreck_unload(piece_id: int) -> void:
	if piece_id < 0 or not _wreck_loads.has(piece_id):
		return
	for id in _wreck_loads[piece_id]:
		_wreck_unload_one(piece_id, int(id))
	_wreck_loads.erase(piece_id)
	_wreck_state.erase(piece_id)


func _wreck_unload_one(piece_id: int, id: int) -> void:
	var b := registry.get_building(id)
	if b == null or not authority.may_decide():
		return
	if b.is_materialised():
		world.clear_load(b.chunk, piece_id)
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.UNLOAD
	e.target = id
	e.owner = piece_id
	authority.commit_entry(e)


## Navigation is stale where a command changed structure: a hit's ball, a
## building's whole box for a solve, a topple or a cut-out.
func _nav_on_command(e: DamageLog.Entry) -> void:
	if e.is_piece():
		return  # pieces are re-read when they settle or go
	if e.kind == DamageLog.Kind.LOAD or e.kind == DamageLog.Kind.UNLOAD \
			or e.kind == DamageLog.Kind.SCORCH:
		return   # weight or colour, not shape
	# A chip is committed whether or not a brick died -- the hp it took is
	# state -- and one that broke nothing changed nowhere anybody can walk.
	# The hit itself says where it did break something (_nav_chip_broke).
	if e.kind == DamageLog.Kind.CHIP:
		return
	match e.kind:
		DamageLog.Kind.BLAST, DamageLog.Kind.SHEAR, DamageLog.Kind.SEVER, DamageLog.Kind.BURN:
			var r := Vector3.ONE * (e.radius + 1.0)
			ai_nav.invalidate_box(AABB(e.point - r, r * 2.0))
		_:
			_nav_touch(e.target)


## A round broke a brick: navigation is stale round it.
func _nav_chip_broke(point: Vector3, radius: float) -> void:
	var r := Vector3.ONE * (radius + 1.0)
	ai_nav.invalidate_box(AABB(point - r, r * 2.0))


## A building changed what it is to the AI -- shell to bricks, bricks to shell.
func _nav_touch(id: int) -> void:
	var b := registry.get_building(id)
	if b != null:
		ai_nav.invalidate_box(_world_box(b).grow(1.0))


func _mech_nav_service() -> void:
	mech_nav.service(int(NAV_BUDGET_US * ai_sched.rate_scale(AIScheduler.NAV)))


func _nav_service() -> void:
	var t0 := Time.get_ticks_usec()
	ai_nav.service(int(NAV_BUDGET_US * ai_sched.rate_scale(AIScheduler.NAV)))
	_nav_worst_us = maxi(_nav_worst_us, Time.get_ticks_usec() - t0)


## Start a fight here: the buildings in `zone` are materialised over the next
## ticks and held that way (R3). Returns the encounter.
func start_encounter(zone: AABB) -> Encounter:
	var enc := Encounter.new()
	enc.setup(registry, zone, func(id: int) -> AABB: return _world_box(registry.get_building(id)))
	_encounters.append(enc)
	return enc


func _pinned(id: int) -> bool:
	for enc in _encounters:
		if enc.holds(id):
			return true
	return false


## Once a physics tick, after everything else the city did: bring the AI's view
## up to date, tell the arbiter what destruction just cost, and serve the AI's
## queue inside what is left.
func _ai_tick(destruction_ms: float) -> void:
	if _no_ai:
		return
	var t0 := Time.get_ticks_usec()
	_ai_steps = {}
	var ts := t0
	ai_world.sync()
	ts = _ai_step("world_sync", ts)
	# Where not to stand: anything big still falling, swept to where it is going.
	Danger.update(ai_world, islands)
	ts = _ai_step("danger", ts)
	# And whatever a disaster has marked: a meteor's ring, a funnel, a fire.
	if disasters != null:
		disasters.ctx.push_hazards(ai_world)
	ts = _ai_step("hazards", ts)
	# Wreckage that lost bricks since last tick: re-weigh it, a few a tick.
	var n_wreck := 0
	for pid in _wreck_dirty.keys():
		var isl: BrickIsland = _wreck_dirty[pid]
		_wreck_dirty.erase(pid)
		if is_instance_valid(isl.body) and isl.is_valid() and isl.settled:
			_wreck_settled(isl)
		else:
			_wreck_unload(int(pid))
		n_wreck += 1
		if n_wreck >= 4:
			break
	ts = _ai_step("wreck", ts)
	for enc in _encounters:
		enc.step(func(id: int) -> void: _promote(id, false))
	ts = _ai_step("encounters", ts)
	if ai_nav.pending() > 0:
		ai_sched.submit(AIScheduler.NAV, 5.0, _nav_service)
	elif ai_nav.warm_pending() > 0:
		# Nothing asked: the hierarchy round the player, last in line (AINav.warm).
		ai_sched.submit(AIScheduler.NAV, 1.0, _nav_service)
	if mech_nav.pending() > 0:
		ai_sched.submit(AIScheduler.NAV, 6.0, _mech_nav_service)
	elif mech_nav.warm_pending() > 0:
		ai_sched.submit(AIScheduler.NAV, 1.0, _mech_nav_service)
	# Weight is structure: only the host turns it into commands (R5).
	if authority.may_decide():
		weight.tick(ai_services.now())
	ts = _ai_step("weight", ts)
	var t1 := Time.get_ticks_usec()
	_ai_sync_ms = float(t1 - t0) / 1000.0
	ai_sched.report_destruction_ms(destruction_ms)
	_ai_heavy_run = _ai_heavy_run + 1 if destruction_ms > AI_HEAVY_MS else 0
	_ai_heavy_run_max = maxi(_ai_heavy_run_max, _ai_heavy_run)
	_ai_destruction_peak = maxf(_ai_destruction_peak, destruction_ms)
	ts = Time.get_ticks_usec()
	ai_sched.run()
	ts = _ai_step("sched_run", ts)
	# Aggro and callouts (AIServices.tick): never ran in the city before.
	ai_services.tick()
	ts = _ai_step("services", ts)
	_ai_run_ms = float(Time.get_ticks_usec() - t1) / 1000.0
	if budget != null:
		budget.tick(ai_services.now())
	ts = _ai_step("budget", ts)
	if swarm != null and ai_services.now() >= _next_swarm_refresh:
		# Buildings come down: the field goes round what is still standing.
		_next_swarm_refresh = ai_services.now() + 5.0
		swarm.refresh()
	ts = _ai_step("swarm_refresh", ts)
	_ai_track_worst(float(ts - t0) / 1000.0)
	_prof["ai"] = _ai_sync_ms + _ai_run_ms + (swarm.tick_ms() if swarm != null else 0.0)
	if _phase != "":
		_ai_phase_level[_phase] = maxi(int(_ai_phase_level.get(_phase, 0)), ai_sched.get_level())
		var k := "tick:" + _phase
		_ai_phase_level[k] = float(_ai_phase_level.get(k, 0.0)) + destruction_ms
		_ai_phase_level["n:" + _phase] = int(_ai_phase_level.get("n:" + _phase, 0)) + 1
	if _ai_label != null and _ai_label.visible and Engine.get_physics_frames() % 10 == 0:
		_update_ai_label()


## One step of `_ai_tick`, timed into `_ai_steps`. The city's own spike report
## (`_prof`) is taken before the AI runs, so without this an AI spike showed
## only as "_ai_tick" in the profiler, with nothing to say which part.
func _ai_step(step: String, since: int) -> int:
	var now := Time.get_ticks_usec()
	_ai_steps[step] = float(now - since) / 1000.0
	return now


## Keep the worst AI tick and its breakdown, and every tick over AI_SPIKE_MS
## with its three biggest steps. Shown on F4, printed at exit.
func _ai_track_worst(total_ms: float) -> void:
	var s: Dictionary = ai_sched.get_stats()
	for sub in ["perception", "nav", "tactical", "trees", "onnx", "commander"]:
		_ai_steps["run:" + sub] = float((s[sub] as Dictionary).ms)
	for k in ai_services.tick_steps:
		_ai_steps["svc:" + k] = float(ai_services.tick_steps[k])
	if total_ms > _ai_worst_ms:
		_ai_worst_ms = total_ms
		_ai_worst_steps = _ai_steps.duplicate()
	if total_ms > AI_SPIKE_MS and _ai_spikes.size() < 200:
		_ai_spikes.append([total_ms, Engine.get_physics_frames(), _ai_top(_ai_steps, 3)])


static func _ai_top(steps: Dictionary, n: int) -> String:
	var all: Array = []
	for k in steps:
		all.append([float(steps[k]), k])
	all.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
	var out := ""
	for i in mini(n, all.size()):
		out += "%s %.1f  " % [all[i][1], all[i][0]]
	return out


func _report_ai_profile() -> void:
	if _ai_worst_steps.is_empty():
		return
	print("[ai-prof] worst AI tick %.1f ms: %s" % [_ai_worst_ms, _ai_top(_ai_worst_steps, 6)])
	if _promotions > 0:
		var pw: Dictionary = _promote_worst[2]
		var wb := registry.get_building(int(_promote_worst[1])) if registry != null else null
		print("[ai-prof] promotions %d, %.1f ms each; the worst %.1f ms (building %d, %s, %d bricks): %s" % [
				_promotions, _promote_ms / _promotions, float(_promote_worst[0]),
				int(_promote_worst[1]),
				"" if wb == null else ("build" if wb.is_build() else "%dx%d, %d courses" % [
					int(wb.recipe.footprint_x), int(wb.recipe.footprint_z), int(wb.recipe.courses)]),
				0 if wb == null else wb.blocks, _ai_top(pw, 9)])
		if wb != null and wb.is_build():
			print("[ai-prof]   that build: %d frame(s), '%s'" % [maxi(wb.frames.size(), 1), wb.build.name])
		for sl in _promote_slow.slice(0, 8):
			print("[ai-prof]   slow: %.1f ms, building %d, promotion #%d: %s" % [
					float(sl[0]), int(sl[1]), int(sl[2]), _ai_top(sl[3], 3)])
	var spikes := _ai_spikes.duplicate()
	spikes.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
	print("[ai-prof] %d AI tick(s) over %.0f ms; the worst:" % [_ai_spikes.size(), AI_SPIKE_MS])
	for k in mini(12, spikes.size()):
		print("[ai-prof]   %.1f ms at tick %d: %s" % [spikes[k][0], spikes[k][1], spikes[k][2]])
	if ai_services != null:
		print("[ai-prof] tactic decisions %d, worst %d us, %d put off to a later think" % [
				ai_services.decisions_made, ai_services.decide_worst_usec, ai_services.decisions_deferred])
	var navs: Array = ai_services.all_navs() if ai_services != null else []
	if mech_nav != null and not navs.has(mech_nav):
		navs.append(mech_nav)
	for n in navs:
		var st: Dictionary = (n as AINav).get_stats()
		if not st.has("worst_service_us"):
			continue
		print("[ai-prof] nav span %d: worst service %d us, hier begin %d, enclosed %d, side edges %d, cluster sides %d, column %d, snap %d, expand %d" % [
				(n as AINav).get_span(), int(st.worst_service_us), int(st.worst_hier_begin_us), int(st.get("worst_enclosed_us", 0)),
				int(st.worst_side_edges_us), int(st.worst_cluster_sides_us),
				int(st.worst_column_us), int(st.worst_snap_us), int(st.worst_expand_us)])
		print("[ai-prof]   of which one step: search %d us, flow field %d, warming %d" % [
				int(st.get("worst_search_step_us", 0)), int(st.get("worst_field_step_us", 0)),
				int(st.get("worst_warm_step_us", 0))])


func _update_ai_label() -> void:
	var w: Dictionary = ai_world.get_stats()
	var s: Dictionary = ai_sched.get_stats()
	var lines := [
		"AI (F4)   level %d of %d   budget %.2f ms   sync %.2f ms   run %.2f ms   city normal %.1f ms" % [
			ai_sched.get_level(), AIScheduler.LEVEL_MAX, ai_sched.get_budget_ms(),
			_ai_sync_ms, _ai_run_ms, ai_sched.get_baseline_ms()],
		"world     %d chunks  %d proxies  %d danger  %d smoke  %d queries, %.2f us mean" % [
			int(w.indexed_chunks), int(w.proxies), int(w.danger), int(w.smoke),
			int(w.queries), float(w.mean_usec)],
		"queue     %d waiting, %d ran last tick, %.2f ms over" % [
			int(s.queued), int(s.ran), float(s.overrun_ms)],
		"nav       %d columns  %d pending  %d paths  %d failed  %.1f ms searching  worst tick %d us" % [
			int(ai_nav.get_stats().columns_cached), int(ai_nav.get_stats().pending),
			int(ai_nav.get_stats().paths), int(ai_nav.get_stats().failed),
			float(ai_nav.get_stats().search_ms), _nav_worst_us],
		"worst     %.1f ms: %s" % [_ai_worst_ms, _ai_top(_ai_worst_steps, 4)],
	]
	for sub in ["perception", "nav", "tactical", "trees", "onnx", "commander"]:
		var d: Dictionary = s[sub]
		lines.append("  %-11s %5.2f ms  %3d ran  %3d deferred" % [sub, float(d.ms),
				int(d.ran), int(d.deferred)])
	_ai_label.text = "\n".join(lines)


## A soldier at `feet`, with a rifle, on the other side (K ahead of the camera).
func _spawn_soldier(feet: Vector3) -> Soldier:
	if ai_services.world3d == null:
		ai_services.world3d = get_world_3d()
		ai_services.on_structure_hit = _gun.on_structure_hit
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(_gun_library,
			_combat_rng.randi(), WeaponClass.builtin(&"rifle"), 1))
	var so := Soldier.spawn(ai_services, self, feet, 1, gun)
	soldiers.append(so)
	weight.add(so.pawn.body, so.pawn.feet, WeightTracker.PERSON)
	print("[city] soldier at %v" % feet)
	return so


## A squad of four at `at`, on the other side (U, 30 m ahead of the camera). With
## the player on foot, it is ordered to advance on the player; otherwise it
## fights as its members find things.
func _spawn_squad(at: Vector3) -> Squad:
	var members: Array[Soldier] = []
	for i in 4:
		members.append(_spawn_soldier(ai_nav.snap(at + Vector3((i % 2) * 1.4 - 0.7, 0.0,
				floori(i / 2.0) * 1.4 - 0.7))))
	var q := Squad.make(ai_services, self, members, 1)
	squads.append(q)
	if _player_pawn != null and is_instance_valid(_player_pawn):
		var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
		o.point = _player_pawn.feet()
		for m in members:
			m.knowledge().heard(_player_pawn, _player_pawn.feet(), ai_services.now())
		q.give(o)
	print("[city] squad %d at %v" % [q.id, at])
	return q


## The pools held from damage for the developer's invincible player (DevMode):
## the pawn's, and the mech's or vehicle's while the player drives it. One left
## behind -- the player got out -- takes damage again.
var _invincible_pools: Array[HealthPool] = []


func _sync_invincible() -> void:
	var want: Array[HealthPool] = []
	# A scripted pass measures the player being hurt; it is never invincible.
	if DevMode.player_invincible() and not _scripted:
		if _player_pawn != null and is_instance_valid(_player_pawn) and _player_pawn.health != null:
			want.append(_player_pawn.health)
		if _pilot.is_piloting() and _pilot.mech != null and is_instance_valid(_pilot.mech) 				and _pilot.mech.health != null:
			want.append(_pilot.mech.health)
		if _vehicle_pilot.is_driving() and _vehicle_pilot.vehicle != null 				and is_instance_valid(_vehicle_pilot.vehicle):
			var vh = _vehicle_pilot.vehicle.get(&"health")
			if vh is HealthPool:
				want.append(vh)
	for hp in _invincible_pools:
		if is_instance_valid(hp) and not want.has(hp):
			hp.invulnerable = false
	for hp in want:
		hp.invulnerable = true
	_invincible_pools = want


## The combat arena: waves of soldiers in and round a building (WaveDirector).
## With `--gate`, the scripted check of where they are put, and quit.
func _start_arena(gate: bool) -> void:
	# A building an encounter is fought in stays bricks; one that comes down
	# must not come back as a shell over its own rubble.
	respawn_buildings = false
	arena = WaveDirector.new()
	arena.name = "Arena"
	add_child(arena)
	arena.setup(self)
	if "--watch" in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		arena.invulnerable = true
		_player.drive_uncaptured = true
		await arena.begin()
		await arena.run_watch()
		get_tree().quit(0)
	elif gate:
		arena.invulnerable = true
		_player.drive_uncaptured = true
		await arena.begin()
		await arena.run_gate()
		print("[arena] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
		get_tree().quit(1 if _gate_fail > 0 else 0)
	else:
		arena.begin()


## Firefight: waves of soldiers in a walled ring, in rounds and sets
## (FirefightDirector). With `--gate`, its scripted check, and quit.
func _start_firefight(gate: bool) -> void:
	respawn_buildings = false
	var ff := FirefightDirector.new()
	ff.name = "Firefight"
	arena = ff
	add_child(ff)
	ff.setup(self)
	if gate:
		ff.invulnerable = true
		_player.drive_uncaptured = true
		await ff.begin()
		await ff.run_firefight_gate()
		print("[firefight] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
		get_tree().quit(1 if _gate_fail > 0 else 0)
	else:
		ff.begin()


## The gate for wreckage weight in the city (Docs/AIPlan.md P5): a tower's top
## cut free comes to rest on what is left of it, and its weight goes onto the
## bricks it lies on -- a LOAD command, applied and solved on the host, replayed
## by the twin buildings of the log check like everything else.
var _breaklag_mode := false
## -- --bigbreak [--big] [--far]: a player's widest shots, close up (_run_bigbreak_pass)
var _bigbreak_mode := false
## -- --widecheck --big: the wide buildings' own break checks (_run_wide_pass)
var _wide_mode := false
## -- --rubble --big: what wreckage at rest costs (_run_rubble_pass)
var _rubble_mode := false
## -- --landing [--big]: a toppled tower landing, watched for blinks (_run_landing_pass)
var _landing_mode := false
var _storeys_mode := false   ## -- --storeys: the storey-units gate (Docs/Space.md 5.3a)
var _whole_mode := false     ## -- --whole: every building laid whole, as before storey units


## Stairs go with their floors.
##
## A staircase is one spiral column from the ground slab up, standing on
## itself: nothing is joined to it, and it holds nothing up -- it must not, or a
## tower would stand on its stairs (collapse_probe's "stairs"). So when the
## building round it came down, the column stood on alone: whole spirals left
## standing after their towers had gone (82 of 90 flights of one, 114 of 122
## of another, in the big city), and falling sections caught on them. A flight
## now stands while its own storey does -- live structure round the stairwell
## within STAIR_STOREY_REACH of it. A run of flights that has lost its storeys
## is cut out as rubble, which falling sections pass through; the flights above
## it, with nothing under them now, come away at the next solve.
const STAIR_SWEEP_TICKS := 10
## Round the stairwell: the floor panels it clips to and a little more.
const STAIR_RING := 1.2
var _stairs_due := {}        ## building id -> true: solved since it was last swept
var _stairs_swept_at := {}   ## building id -> the physics tick it was last swept


## Sweep one building's stairs. -1 when it is not time yet (it stays due);
## otherwise how many pieces were cut out.
func _sweep_stairs(id: int) -> int:
	var now := Engine.get_physics_frames()
	if now - int(_stairs_swept_at.get(id, -100000)) < STAIR_SWEEP_TICKS:
		return -1
	_stairs_swept_at[id] = now
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or b.toppled or _toppling.has(id):
		return 0
	var runs := _orphan_stairs(b)
	if runs.is_empty():
		return 0
	var cut := 0
	for run in runs:
		_disable(b.id, run)
		var piece := islands.record_detach(b.id, null, b.chunk, run, 0)
		var came := islands.spawn(b.chunk, run, Vector3.ZERO, Vector3.ZERO, piece, b.id)
		if came != null:
			_note_handover(b.id, came)
			islands.make_debris(came)
		cut += 1
	_refresh_furniture(b.id)
	b.structure_version += 1
	interior_groups.touch(b.id)
	if int(_remesh_hold.get(b.id, -1)) <= Engine.get_process_frames():
		_remesh_hold[b.id] = Engine.get_process_frames() + IslandManager.OVERLAP_FRAMES
	_queue_remesh(b.id)
	# What stood on them has nothing under it now: solved again.
	_mark_dirty(b.id)
	return cut


## The runs of live stair blocks that have lost their storeys, bottom to top,
## each a stack of consecutive flights.
func _orphan_stairs(b: BuildingRegistry.Building) -> Array:
	var out: Array = []
	if b.is_build() or not b.is_materialised():
		return out
	# Gone: dead, or cut out already (a detached block is not in the dead list).
	var dead := {}
	for d in world.get_dead_blocks(b.chunk):
		dead[d] = true
	for d in world.get_detached_blocks(b.chunk):
		dead[d] = true
	var all_stairs := PackedInt32Array()
	var live: Array = []   # [fixture index, position in its blocks, block id]
	for fi in b.fixtures.size():
		var f = b.fixtures[fi]
		if f.kind != "staircase":
			continue
		for k in f.blocks.size():
			var bid: int = f.blocks[k]
			all_stairs.append(bid)
			# Not laid (Docs/Space.md 5.3a): not here to be swept. Its storey is
			# the rest shell's, and the shell holds it.
			if not dead.has(bid) and not world.is_block_absent(b.chunk, bid):
				live.append([fi, k, bid])
	if live.is_empty():
		return out
	var ids := PackedInt32Array()
	for e in live:
		ids.append(int(e[2]))
	var storey := TowerRecipe.STOREY_PLATES * BrickPalette.PLATE_M
	var shaft := world.get_blocks_box(b.chunk, ids)
	var ring := AABB(shaft.position - Vector3(STAIR_RING, storey, STAIR_RING),
			shaft.size + Vector3(2.0 * STAIR_RING, 2.0 * storey, 2.0 * STAIR_RING))
	var level := storey * 0.25
	var levels := world.block_centre_levels(b.chunk, ring, level, all_stairs)
	# Held: live structure round the stairwell within its own storey. A flight
	# stands if ITS storey or any above it does -- the flights below a floor
	# that still stands are the way up to it, even through a storey cut out
	# round them (collapse_probe: floors still standing keep their stairs). So
	# what goes is the top of each column: every flight above the highest held.
	var top_held := {}   # fixture index -> highest position held
	for e in live:
		var bid: int = e[2]
		var box := world.get_blocks_box(b.chunk, PackedInt32Array([bid]))
		# Its own storey: from most of a storey below its foot to a little above
		# its head -- the slab it stands on, the walls and landing beside it.
		var lo := int(floor((box.position.y - storey * 0.75 - ring.position.y) / level))
		var hi := int(floor((box.end.y + storey * 0.25 - ring.position.y) / level))
		var held := false
		for l in range(maxi(lo, 0), mini(hi, levels.size() - 1) + 1):
			if levels[l] != 0:
				held = true
				break
		if held:
			top_held[e[0]] = maxi(int(top_held.get(e[0], -1)), int(e[1]))
	var run := PackedInt32Array()
	var last := [-1, -1]
	for e in live:
		if int(e[1]) <= int(top_held.get(e[0], -1)):
			continue
		var next_to_last: bool = int(e[0]) == int(last[0]) and int(e[1]) == int(last[1]) + 1
		if not run.is_empty() and not next_to_last:
			out.append(run)
			run = PackedInt32Array()
		run.append(int(e[2]))
		last = [e[0], e[1]]
	if not run.is_empty():
		out.append(run)
	return out


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


## F6 places furniture and items from the catalogue (WorldFurnisher): into a
## generated building's room as one more of its items, into a player build as
## its bricks, or outdoors as a prop (OutdoorProps) that is bricks once shot.
func _setup_furnisher() -> void:
	_props = OutdoorProps.new()
	_props.name = "Props"
	add_child(_props)
	_props.setup(brick_material, TerrainTile.stud_material())
	_props.make_build = func(r: BuildRecipe, xf: Transform3D) -> int:
		var id := registry.register_build(r, xf)
		if id >= 0:
			_index_building(id)
			_make_shell(id)
			_note_placed(id, false)
		return id
	_furnisher = WorldFurnisher.new()
	_furnisher.name = "Furnisher"
	add_child(_furnisher)
	_furnisher.setup(registry, camera, _props)
	_furnisher.ground_ray = func(from: Vector3, dir: Vector3) -> Vector3:
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * 200.0, Layers.HITSCAN_MASK)
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		return Vector3.INF if hit.is_empty() else hit["position"]
	# A room gained a piece: every drawing of the storeys it is on is stale.
	_furnisher.room_changed = func(b: BuildingRegistry.Building, y_lo: float, y_hi: float) -> void:
		for g in interior_groups.known(b.id):
			if g.box.position.y > y_hi or g.box.end.y < y_lo:
				continue
			g.dirty = true
			if g.shown:
				interior_groups.work(b, g, Time.get_ticks_usec() + 2000)
				_group_show(b, g)
	_furnisher.build_furnished = func(id: int, _blocks: PackedInt32Array) -> void:
		_furnished[id] = true
		_refresh_furniture(id)


## `chip` > 0: a gun's wear instead of a blast (DamageLog.Kind.CHIP).
func _apply_blast(point: Vector3, radius: float, chip_hp := 0) -> void:
	# A bullet has no radius, but it still has to find the building it struck.
	var reach := maxf(radius, 0.25)
	# A prop the blast reaches becomes bricks first, so the blast breaks it
	# like anything else (OutdoorProps).
	if _props != null:
		_props.promote_near(point, reach)
	var took_bricks := false   ## from a building: what rested on them is woken
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
		var t_hit := Time.get_ticks_usec()
		var chunk := _promote(b.id, true, _storeys_for(b.id, point, reach))
		t_hit = _part("dmg_promote", t_hit)
		if chunk < 0:
			continue
		# What the blast reaches of the interior is dealt with before the hit
		# lands: its contents are part of what the damage does (Interiors
		# section 5), and the blast then destroys them like anything else in
		# its way. Only what somebody could actually see is laid as bricks.
		# The rest is resolved in the record, which is Interiors section 5.1's
		# own rule and the difference between 20 ms a frame and 108 in a
		# firefight.
		var watched_room: bool = camera != null 				and camera.global_position.distance_to(point) < ROOM_RANGE * 1.5
		var t_room := Time.get_ticks_usec()
		# A blast lays the PIECES it reaches, each on its own, and no room
		# (Interiors.md 8.4): what is hit is bricks from here on, and the rest
		# of the room goes on being drawn.
		var reached: Dictionary = registry.compromise_items(b.id, point, reach, watched_room)
		var t_rm := _part("rm_items", t_room)
		var woke: int = (reached.laid as Array).size() + int(reached.gone)
		if not (reached.laid as Array).is_empty():
			_add_item_shapes(b.id, reached.laid)
			t_rm = _part("rm_shapes", t_rm)
			# The building has to be told it holds furniture now, or the
			# redraw's guard skips it for ever.
			_furnished[b.id] = true
			_refresh_furniture(b.id)
			t_rm = _part("rm_refresh", t_rm)
		if woke > 0:
			# Laid as bricks or written off: out of its group's drawing now. A
			# pass later is a piece drawn twice for four ticks.
			_groups_rooms_moved(b, local.y - reach, local.y + reach)
			t_rm = _part("rm_groups", t_rm)
			_pieces_hit += woke
			_pieces_laid += (reached.laid as Array).size()
			_pieces_hit_ms += float(Time.get_ticks_usec() - t_room) / 1000.0
		_prof["rm_laid"] = float(_prof.get("rm_laid", 0.0)) + (reached.laid as Array).size()
		_prof["rm_gone"] = float(_prof.get("rm_gone", 0.0)) + int(reached.gone)
		t_hit = _part("dmg_rooms", t_hit)
		var killed: PackedInt32Array = world.chip_hit(chunk, point, radius, chip_hp) 				if chip_hp > 0 else world.apply_hit(chunk, point, radius)
		t_hit = _part("dmg_hit", t_hit)
		# Committed as soon as it is applied, so the log's order is the order
		# the world changed in. ALWAYS, whether or not a brick died: the hp a
		# hit took is state. A blast used to be logged only when it killed,
		# which is every blast on PLA and not on anything tougher -- a stone
		# cottage takes the first one as wear and loses bricks to the second,
		# so a load, a replay or a client that was told only about the second
		# had 76 bricks standing where the host had 69 (the --checkpoint gate).
		if chip_hp > 0:
			authority.commit(Engine.get_physics_frames(), DamageLog.Kind.CHIP,
					b.id, point, radius, Vector3.ZERO, chip_hp)
		else:
			authority.commit(Engine.get_physics_frames(), DamageLog.Kind.BLAST,
					b.id, point, radius)
		# Every other frame of a multi-frame build takes the same hit: a blast
		# does not care which grid the brick it removed was authored in.
		if b.frames.size() > 1:
			for fi in range(1, b.frames.size()):
				var hit_frame: PackedInt32Array = 						world.chip_hit(b.frames[fi], point, radius, chip_hp) if chip_hp > 0 						else world.apply_hit(b.frames[fi], point, radius)
				# Each frame is its own grid, so each hit is its own command
				# -- logged whether or not it killed, as above.
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
				took_bricks = true
				islands.throw_killed(b.frames[fi], hit_frame, point, radius, chip_hp > 0)
				if chip_hp > 0:
					_nav_chip_broke(point, radius)
				b.hit = true
				_disable_frame(b.id, fi, hit_frame)
				_mark_dirty(b.id)
				_queue_remesh(b.id)
		if killed.is_empty():
			continue
		took_bricks = true
		# The middle of a blast is gone; the ring round it is thrown out, as
		# crumbs (IslandManager.BLAST_CORE). Drawn only: the bricks are dead in
		# the grid either way, and the log says what it always said.
		islands.throw_killed(chunk, killed, point, radius, chip_hp > 0)
		if chip_hp > 0:
			_nav_chip_broke(point, radius)
		b.hit = true
		_mark_dirty(b.id, local.y - reach, local.y + reach)
		# Both the collision update and the remesh are deferred to the end of
		# the tick. _disable lifts the body out of its space and back, and
		# _remesh walks every baked face; doing either once per HIT meant a
		# burst of fire paid for them over and over on the same building.
		_last_hit[b.id] = Time.get_ticks_msec()
		director.note_hit(b.id, point)
		if not _pending_disable.has(b.id):
			_pending_disable[b.id] = PackedInt32Array()
		_pending_disable[b.id].append_array(killed)
		# The damage record is NOT refreshed here. get_dead_blocks walks every
		# block in the building, and a burst of fire would do that once per hit;
		# dematerialise() is the only place the record has to be current, and it
		# captures it there.
		_queue_remesh(b.id)

	# Loose pieces in range are damaged. And a settled section resting on a
	# wall that has just gone must fall, not hang: what touches where the blast
	# took bricks from a building, and is not wholly below it, is woken
	# (support_gone). Not everything within four radii, as it was -- wreckage at
	# rest stays at rest until something is taken from under it (CollapseNext
	# 1.10); a piece's own bricks say the same for themselves in damage().
	var t_pieces := Time.get_ticks_usec()
	var t_part := t_pieces
	if not _shell_pieces.is_empty():
		_blast_shell_pieces(point, reach)
		t_part = _part("dmg_shell_pieces", t_part)
	islands.damage_near(point, radius, chip_hp)
	t_part = _part("dmg_near", t_part)
	if took_bricks:
		islands.support_gone(AABB(point - Vector3.ONE * reach, Vector3.ONE * reach * 2.0))
		_part("dmg_support", t_part)
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
	# The mark, the debris and the sound of what was hit, BEFORE the blast
	# takes the brick away -- afterwards there is nothing there to ask.
	if not _material_fx.impact_at(hit.position, hit.normal):
		_material_fx.impact(hit.position, hit.normal, 0, Color(0.6, 0.6, 0.6))
	var struck := islands.find_by_body(hit.collider)
	if struck != null:
		# A client asks; the host's blast finds the same piece by its volume.
		if not authority.request(DamageLog.Kind.BLAST, -1, hit.position, radius):
			return
		islands.damage(struck, hit.position, radius)
		islands.push_near(hit.position, radius)
		return
	_blast(hit.position, radius)


# ---------------------------------------------------------------------------
# Per-tick: collapse whatever is materialised
# ---------------------------------------------------------------------------

## What inside a slow tick's biggest phase it was, from this tick's parts: the
## spikes of a --big --shot are a different phase run to run (islands, damage,
## promote, stream, bands), and only the worst tick used to say its parts.
const _SPIKE_PARTS := {"damage": ["dmg_promote", "dmg_rooms", "dmg_hit", "dmg_pieces",
				"dmg_shell_pieces", "dmg_near", "dmg_support", "dmg_disable"],
		"stream": ["st_trim", "st_merge", "st_rooms", "st_detail", "sd_far", "sd_panes", "sd_coarse", "pn_prep",
				"pn_copy",
				"st_demesh", "st_remesh",
				"st_reshell", "st_residency", "st_shells", "ss_shells", "ss_glass", "ss_proxies",
				"ss_shadows", "sp_make", "sp_near", "ss_inst", "sh_profile", "sh_mesh", "sh_real", "sh_body"],
		"bands": ["bd_harvest", "bd_apply", "bd_done", "bd_cpp", "bd_upload", "bd_rest",
				"bd_pieces"],
		"disable": ["dis_collision", "dis_rooms"],
		"promote": ["bricks", "collision", "frames", "furniture", "shell"]}

func _spike_parts(phase: String) -> String:
	if phase == "islands":
		var lt: Array = islands.last_tick
		if lt.size() < 6:
			return ""
		return "loop %.1f, resolve %s, landings %.1f, reshapes %.1f, mesh %.1f; slowest mesh so far %s" % [
				lt[1], str(lt[2]), lt[3], lt[4], lt[5], str(islands.mesh_drain_worst)]
	var out := ""
	for k in _SPIKE_PARTS.get(phase, []):
		var v := float(_prof.get(k, 0.0))
		if v >= 0.5:
			out += "%s %.1f  " % [k, v]
	if phase == "damage" and float(_prof.get("dmg_shell_pieces", 0.0)) >= 0.5:
		out += "(last shell piece made bricks: %s) " % shell_brick_split
	if phase == "damage" and _near_at_tick.size() == 5:
		var dn: Array = islands.damage_near_ms
		out += "(near: wake %.1f, walk %.1f, hits %.1f, push %.1f, %d call(s); worst unit so far %s)" % [
				dn[0] - _near_at_tick[0], dn[1] - _near_at_tick[1], dn[2] - _near_at_tick[2],
				dn[3] - _near_at_tick[3], dn[4] - _near_at_tick[4], str(islands.unit_worst)]
	return out


var _near_at_tick: Array = []   ## islands.damage_near_ms as this tick began


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


## The next tick's structure solves, started now on workers
## (BrickWorld.solve_structure_async): they run while the physics steps and the
## frames draw, and the tick takes their answers where it would have solved
## (_take_solve) -- 3-6 ms of a 22,000-brick tower off the tick, and up to 15.
## The buildings first in line, as many as the tick will solve. Anything that
## touches one of their chunks meanwhile waits for its solve first; a write to
## its structure (a hit, a brick laid) makes the answer stale, and the tick
## solves that building again itself. Only the host decides (as below).
## Docs/WhereWorkRuns.md 3.3.
func _start_solves() -> void:
	# A building no longer waiting -- given back, or its turn taken some other
	# way -- has its answer thrown away, or its slot would stay taken.
	for id in _solving.keys():
		if not _dirty.has(id):
			world.take_solve(_solving[id])
			_solving.erase(id)
			_solve_async[2] += 1
	if not authority.may_decide():
		return
	for k in mini(SOLVES_PER_TICK, _dirty.size()):
		var id: int = _dirty[k]
		if _solving.has(id):
			continue
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		if b.banded:
			registry.set_storey_bounds(b)
		if world.solve_structure_async(b.chunk, CASCADE_ROUNDS, CASCADE_BUDGET_MS):
			_solving[id] = b.chunk


## A solve _start_solves began for this building, if there is one and it still
## holds: {} otherwise, and the tick solves it as before. A stale one has
## already failed what it failed in the chunk, so that is logged for a replay
## (as the solve below logs its own) before the building is solved again.
func _take_solve(id: int, b: BuildingRegistry.Building) -> Dictionary:
	if not _solving.has(id):
		return {}
	var got: Dictionary = world.take_solve(_solving[id])
	_solving.erase(id)
	if got.is_empty() or b == null or not b.is_materialised():
		return {}
	_solve_async[0] += 1
	if not bool(got.get("stale", false)):
		return got
	_solve_async[1] += 1
	var res: Dictionary = got.get("stress", {})
	if int(res.get("failures", 0)) > 0 or int(res.get("reattached", 0)) > 0:
		authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SOLVE,
				b.id, Vector3.ZERO, 0.0, Vector3(1.0, 0.0, 0.0), int(res.get("rounds", 0)))
	return {}


func _physics_process(_delta: float) -> void:
	if _stud_times != BrickStrength.times:
		_restud()
	_prof = {}
	_sync_invincible()
	if _sampling:
		_near_at_tick = islands.damage_near_ms.duplicate()
	var t_tick := Time.get_ticks_usec()
	var t := t_tick
	# What the workers finished uploading since the last call into the
	# renderer, paid here and measured, rather than by whatever next makes a
	# node or sets a mesh -- which is where it landed: a spawn's "node" step at
	# 7-12 ms, a small piece's mesh at 8. Any call that answers flushes the
	# renderer's queue; asking a tiny mesh its surface count is the cheapest.
	# See IslandManager.UPLOAD_VERTS_PER_TICK.
	# With the renderer on its own thread the uploads are its to make, and this
	# would wait for the frame it is drawing.
	if _one_thread:
		RenderingServer.mesh_get_surface_count(_flush_mesh.get_rid())
	var landed := UploadLedger.take()
	if _sampling:
		var flush_ms := float(Time.get_ticks_usec() - t) / 1000.0
		if flush_ms > RENDER_SPIKE_MS:
			_render_spikes.append([flush_ms, Engine.get_physics_frames(), UploadLedger.line(landed)])
			_render_spikes.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
			if _render_spikes.size() > 10:
				_render_spikes.resize(10)
		for k in landed:
			var row: Array = _render_landed.get(k, [0, 0])
			row[0] += int(landed[k][0])
			row[1] += int(landed[k][1])
			_render_landed[k] = row
	t = _mark("render", t)
	if not _span_owed.is_empty():
		_pay_span_owed()
		t = _mark("solve", t)
	var spawn_until := Time.get_ticks_usec() + int(SPAWN_BUDGET_MS * 1000.0)
	var spawned := 0
	var crumbs_cut := 0
	var solved := 0
	# Solving, toppling and detaching decide what a building does next, and on
	# budgets whose timing differs machine to machine. The host decides; a client
	# gets the SOLVE / TOPPLE / DETACH commands instead (AIPlan P0 step 4).
	var decide_limit := SOLVES_PER_TICK if authority.may_decide() else 0
	# The buildings this loop is about to solve, solved at once, a thread each
	# (BrickWorld.solve_structures): four in turn were up to 10 ms of the worst
	# tick of a big collapse. Each solve reads and writes only its own building,
	# and handling one building's answer touches no other building's bricks, so
	# the answers are the ones solving them in turn gave. One the loop comes
	# back to in the same tick -- re-marked while it was handled -- is solved
	# again then, as it always was.
	var ahead := {}
	if decide_limit > 1 and _dirty.size() > 1:
		var ids: Array[int] = []
		var chunks := PackedInt32Array()
		for k in mini(decide_limit, _dirty.size()):
			if _solving.has(_dirty[k]):
				continue
			var ab := registry.get_building(_dirty[k])
			if ab != null and ab.is_materialised():
				if ab.banded:
					registry.set_storey_bounds(ab)
				ids.append(_dirty[k])
				chunks.append(ab.chunk)
		if ids.size() > 1:
			var _tb := Time.get_ticks_usec()
			var answers: Array = world.solve_structures(chunks, CASCADE_ROUNDS, CASCADE_BUDGET_MS)
			var _batch_ms := float(Time.get_ticks_usec() - _tb) / 1000.0
			_solve_batches += 1
			_solve_batch_worst = maxf(_solve_batch_worst, _batch_ms)
			for k in ids.size():
				ahead[ids[k]] = answers[k]
	# Once a tick each. A building re-marked while it was handled -- something
	# came loose, a joint failed -- used to come round again in the same tick,
	# up to SOLVES_PER_TICK times: the same groups found again before anything
	# had been cut out of it, and each with a cascade's clock of its own
	# (CASCADE_BUDGET_MS, so 12 ms where 3 was meant). It waits for the next.
	var solved_now := {}
	var again: Array[int] = []
	while solved < decide_limit and not _dirty.is_empty():
		var id: int = _dirty.pop_front()
		if solved_now.has(id):
			again.append(id)
			continue
		solved_now[id] = true
		solved += 1
		var b := registry.get_building(id)
		var early := _take_solve(id, b)
		if b == null or not b.is_materialised():
			continue
		if not b.fixtures.is_empty():
			_stairs_due[id] = true
		var quiet := true
		# Stress, then balance, then what has come loose -- one call, which
		# walks the building's joints once where the three calls walked them
		# three times, and answers exactly as they did (BrickWorld.solve_structure,
		# tools/solve_probe.gd).
		var solve: Dictionary
		if not early.is_empty():
			solve = early
		elif ahead.has(id):
			solve = ahead[id]
			ahead.erase(id)
		else:
			if b.banded:
				registry.set_storey_bounds(b)
			var _ts := Time.get_ticks_usec()
			solve = world.solve_structure(b.chunk, CASCADE_ROUNDS, CASCADE_BUDGET_MS)
			var _solve_ms := float(Time.get_ticks_usec() - _ts) / 1000.0
			var _blocks := world.get_block_count(b.chunk)
			if _blocks >= CollapseDirector.MEGA_BLOCKS:
				_solve_mega[0] += 1
				_solve_mega[1] += _solve_ms
			if _solve_ms > float(_solve_worst[0]):
				_solve_worst = [_solve_ms, _blocks, int(solve.groups.size()),
						director.collapsing.has(b.id)]
		t = _mark("solve", t)
		var res: Dictionary = solve.stress
		stud_census[0] += 1
		if int(res.get("failures", 0)) > 0:
			stud_census[1] += 1
			stud_census[2] += int(res.failures)
		# Structural: joints failing, or the building off balance. A brick
		# knocked loose by a shot is not a collapse (see the plan, below).
		if int(res.get("failures", 0)) > 0 \
				or not bool((solve.stability as Dictionary).get("stable", true)):
			_broke_ms[b.id] = Time.get_ticks_msec()
		if int(res.get("failures", 0)) > 0 or int(res.get("reattached", 0)) > 0:
			quiet = false
			# A solve that failed something changed the structure, and when it
			# ran relative to the hits around it decides what it failed.
			authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SOLVE,
					b.id, Vector3.ZERO, 0.0, Vector3(1.0, 0.0, 0.0), int(res.get("rounds", 0)))
			_held_groups += int(res.get("reattached", 0))
			_cascade_rounds += int(res.get("rounds", 1))
			_cascade_worst = maxi(_cascade_worst, int(res.get("rounds", 1)))

		# Is what is left actually balanced on what holds it up? Stress cannot
		# answer that -- toppling is a rigid-body question. Without this a tower
		# with half its base gone stands forever, because standing structure is
		# a static body and only a DETACHED piece is ever dynamic.
		var stability: Dictionary = solve.stability
		if not bool(stability.get("stable", true)):
			quiet = false
		# Not one laid a storey at a time: its bricks are a storey or two of
		# it, and what those balance on says nothing of the building. A storey
		# of it that gives way is _give_way's (below).
		if not bool(stability.get("stable", true)) and not _toppling.has(b.id) \
				and not b.banded and spawned < SPAWNS_PER_TICK \
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

		var groups: Array = solve.groups
		if groups.is_empty():
			# Nothing hanging has failed and nothing is loose -- but is each
			# storey still able to carry what is above it? (_gravity_fail)
			if not b.is_build() and _gravity_fail(b):
				_mark_dirty(b.id)
				continue
			# And does every floor reach its supports? Owed, not asked here:
			# a big tower's check is 4 ms (_pay_span_owed).
			if not b.is_build():
				_span_owed[b.id] = true
			# Nothing failed, nothing is falling, nothing is unbalanced: this
			# building is at rest and does not need looking at again until
			# something hits it.
			if quiet:
				continue
			# Solved again; no block of it has changed, so no storey group is
			# asked anything (an empty range).
			_mark_dirty(b.id, INF, -INF)
			continue
		# What leaves it below tells the storey groups where (left_boxes).
		_mark_dirty(b.id, INF, -INF)
		# Still drawn by its shell -- made bricks this moment, its bands not up
		# yet: nothing is cut out of it. The shell draws the building whole, so
		# a piece let go now fell out of a wall that went on showing it: two of
		# it, for as long as the bands took (collapse_probe's "no double"). Left
		# where they are, the groups are solved again next tick and go the
		# moment the bands are drawn -- with the holes they leave, which is also
		# when the shot is first seen on the building.
		# Laid a storey at a time and its bands rebuilding for storeys just laid
		# (_lay_more): no shell stands in, and the old bands still draw what
		# would leave -- held the same way, for the few ticks the bands take.
		if _bands_building(b.id) and (_shells.has(b.id) or b.banded):
			continue
		# Breakage as it always was; a mega building's collapse as a few big
		# chunks, its furniture split out to be written off (CollapseDirector).
		# What it holds now: laid a storey at a time, a storey or two of its
		# template's bricks, not a mega building's worth (Docs/Space.md 5.3a).
		var held: int = b.blocks if not b.banded 				else world.get_block_count(b.chunk) - world.get_absent_count(b.chunk)
		var plan: Array = director.plan(b.id, b.chunk, held, _world_box(b), groups,
				islands.interest_points(), registry.floor_lines(b.id),
				int(res.get("failures", 0)) > 0)
		for entry in plan:
			if entry[1] != &"breakage" and entry[1] != &"furniture":
				_broke_ms[b.id] = Time.get_ticks_msec()   # a section, not a chip (_mid_collapse)
				break
		# Stairs a section took with it (_with_stairs) can be a group of their own
		# further down this same plan: what of it they were is gone already.
		# Recorded as named, that DETACH cut nothing on any other machine (the
		# log replay missed it) -- once the biggest section went first and eight
		# a tick, where two a tick had left that group for the next solve.
		var taken_by_stairs := {}
		# Where each group that leaves was, in the building's own space: what
		# its rooms drew there stops being drawn this tick (below).
		var left_boxes: Array[AABB] = []
		for entry in plan:
			var kind: StringName = entry[1]
			var before: PackedInt32Array = entry[0]
			if not taken_by_stairs.is_empty():
				var kept := PackedInt32Array()
				for bid in before:
					if not taken_by_stairs.has(bid):
						kept.append(bid)
				if kept.is_empty():
					continue
				before = kept
			if kind != &"furniture":
				var named := before.size()
				before = _with_stairs(b, before)
				for k in range(named, before.size()):
					taken_by_stairs[before[k]] = true
			# Furniture is deleted where it is unless somebody is right there:
			# it costs next to nothing and is not held to the spawn budget. Nor
			# is a group small enough to be crumbs (IslandManager._crumble): no
			# body, no mesh -- but the clock still holds it.
			if kind != &"furniture" and before.size() <= IslandManager.DEBRIS_MAX_BLOCKS:
				if crumbs_cut >= CRUMBS_CUT_PER_TICK 						or (crumbs_cut > 0 and Time.get_ticks_usec() >= spawn_until):
					break
				crumbs_cut += 1
			elif kind != &"furniture":
				if spawned >= SPAWNS_PER_TICK \
						or (spawned > 0 and Time.get_ticks_usec() >= spawn_until):
					break
				spawned += 1
			# Parent first, island second -- see the note above the toppling
			# spawn. spawn() returns null for debris discarded unseen; either
			# way the blocks have left this building.
			left_boxes.append(world.get_blocks_box(b.chunk, before).grow(0.2))
			_groups_leaving = true
			_disable(b.id, before)
			_groups_leaving = false
			t = _mark("disable", t)
			# The detach is a command: WHEN a group leaves is a budget, and timing
			# changes what the next hit does (DamageLog, "Every operation").
			var piece := islands.record_detach(b.id, null, b.chunk, before,
					DamageLog.FLAG_CHUNK if kind == &"chunk" else 0)
			var came := islands.spawn(b.chunk, before, Vector3.ZERO, Vector3.ZERO, piece, b.id)
			# What stood on it, in the storey groups, goes with it.
			_groups_floor_went(b, left_boxes[left_boxes.size() - 1], came)
			if came != null:
				_note_handover(b.id, came)
			if came == null:
				# Deleted where it stood -- debris, furniture, a far chunk over the
				# moving cap: whatever settled on it has nothing under it now.
				islands.support_gone(world.get_chunk_transform(b.chunk)
						* world.get_blocks_box(b.chunk, before))
			if kind == &"chunk" and came != null:
				# One piece until it lands: mended, as every client mends it.
				world.heal_joints(came.chunk)
				CollapseDust.puff(self, came.body.global_position, came.radius)
			t = _mark("spawn", t)
		# NOW the furniture is redrawn, from what is left. _disable redrew it
		# too, but before the spawn took the blocks out of this chunk -- so the
		# building went on drawing every piece that had just left it, a flat
		# untextured ghost where the floor used to be, until the next hit on
		# this building happened to redraw it again.
		_refresh_furniture(b.id)
		b.structure_version += 1
		# Keep drawing those bricks until the piece that took them has come up.
		# See IslandManager.OVERLAP_FRAMES.
		# Start a hold, never extend one -- see the same guard in _shed.
		if int(_remesh_hold.get(b.id, -1)) <= Engine.get_process_frames():
			_remesh_hold[b.id] = Engine.get_process_frames() + IslandManager.OVERLAP_FRAMES
		_queue_remesh(b.id)
	for id in again:
		if not _dirty.has(id):
			_dirty.append(id)
	_resolves_put_off += again.size()
	# A storey with nothing left under the storey on it (Docs/Space.md 5.3a):
	# asked once the groups it shed have left, so what is left is what holds.
	for id in solved_now:
		var gb := registry.get_building(id)
		if gb == null or not gb.banded or not gb.is_materialised():
			continue
		if _bands_building(id):
			continue   # its groups wait for its bands; so does this
		var gave := registry.storey_gave_way(id)
		if gave >= 0:
			_give_way(id, gave)
	t = _mark("after_spawn", t)
	for sid in _stairs_due.keys():
		if spawned >= SPAWNS_PER_TICK or (spawned > 0 and Time.get_ticks_usec() >= spawn_until):
			break
		var cut := _sweep_stairs(int(sid))
		if cut >= 0:
			_stairs_due.erase(sid)
			spawned += cut
	t = _mark("stairs", t)
	# M4: spread promotions rather than letting several land in one frame.
	var hits := 0
	var damage_until := Time.get_ticks_usec() + int(DAMAGE_BUDGET_MS * 1000.0)
	while not _damage_queue.is_empty() \
			and hits < DAMAGE_PER_TICK \
			and (hits == 0 or Time.get_ticks_usec() < damage_until):
		var h: Array = _damage_queue.pop_front()
		_apply_blast(h[0], h[1], int(h[2]) if h.size() > 2 else 0)
		hits += 1
	islands.flush_meshes()
	# One space lift per building per tick, however many hits landed on it.
	var t_dis := Time.get_ticks_usec()
	for id in _pending_disable:
		_disable(id, _pending_disable[id])
	_pending_disable.clear()
	_part("dmg_disable", t_dis)
	t = _mark("damage", t)

	_flush_furniture()
	_retirer.drain()
	t = _mark("retire", t)
	_advance_bands()
	var t_rest := Time.get_ticks_usec()
	_tend_rest_shells()
	_part("bd_rest", t_rest)
	var t_pieces := Time.get_ticks_usec()
	_tend_shell_pieces()
	_part("bd_pieces", t_pieces)
	t = _mark("bands", t)
	_finish_promotions()
	t = _mark("promote_finish", t)

	var remeshed := 0
	var now_frame := Engine.get_process_frames()
	var remesh_until := Time.get_ticks_usec() + int(REMESH_BUDGET_MS * 1000.0)
	# Hand-overs first, and outside the budget (Docs/Collapse.md 2.4). A building
	# that shed a piece stops drawing those bricks the tick every piece that
	# took them is drawing -- not two frames after the split whatever the piece
	# is doing (the flicker: a piece's mesh is baked on a worker and was up to 2
	# ticks late), and not whenever the queue gets round to it (the double: 6 of
	# 7 hand-overs, up to 6 ticks, all waiting in this queue). A patch is
	# microseconds; HANDOVERS_PER_TICK bounds the odd full rebuild.
	var handed := 0
	var hi := 0
	while hi < _remesh_queue.size() and handed < HANDOVERS_PER_TICK:
		var hid: int = _remesh_queue[hi]
		if not _handovers.has(hid) or _handover_waiting(hid, now_frame):
			hi += 1
			continue
		_remesh_queue.remove_at(hi)
		_remesh_hold.erase(hid)
		_remesh(hid)
		handed += 1
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
		if int(_remesh_hold.get(rid_b, -1)) > now_frame or _handovers.has(rid_b):
			ri += 1
			continue
		_remesh_queue.remove_at(ri)
		_remesh_hold.erase(rid_b)
		_remesh(rid_b)
		remeshed += 1
	if not _recolour.is_empty():
		var pf := Engine.get_physics_frames()
		for cid in _recolour.keys():
			if int(_recolour[cid]) <= pf:
				_recolour.erase(cid)
				_remesh(int(cid), true)
	t = _mark("remesh", t)
	_watch_handovers()

	if camera != null and Engine.get_physics_frames() % 3 == 0:
		_aim_promote()
		_path_promote()
	var promoted := 0
	while promoted < PROMOTIONS_PER_FRAME and not _promote_queue.is_empty():
		var pid: int = _promote_queue.pop_front()
		var pb := registry.get_building(pid)
		_promote(pid, pb == null or pb.is_damaged(),
				_promote_storeys.get(pid, PackedInt32Array()))
		_promote_storeys.erase(pid)
		promoted += 1
	t = _mark("promote", t)

	# M4: buildings that have been quiet and are far away give their bricks
	# back. The damage record stays, so the holes are still there next time.
	if not _measuring:
		var t_st := Time.get_ticks_usec()
		if camera != null and Engine.get_physics_frames() % TRIM_EVERY == 0:
			_trim_quiet()
		@warning_ignore("integer_division")
		if camera != null and Engine.get_physics_frames() % TRIM_EVERY == TRIM_EVERY / 2:
			_trim_budget()
		t_st = _part("st_trim", t_st)
		if Engine.get_physics_frames() % 8 == 5:
			_merge_quiet_buildings()
		t_st = _part("st_merge", t_st)
		# Every fourth tick: who is near which storey group, and which still
		# pieces of wreckage (InteriorGroups).
		if camera != null and Engine.get_physics_frames() % 4 == 3:
			_stream_groups(camera.global_position)
		t_st = _part("st_rooms", t_st)
		if camera != null and Engine.get_physics_frames() % 4 == 2:
			_stream_detail()
		t_st = _part("st_detail", t_st)
		if camera != null and Engine.get_physics_frames() % 4 == 1:
			_stream_residency()
		t_st = _part("st_residency", t_st)
	# Every fourth tick is fifteen times a second: far faster than anyone can
	# cross an LOD band, and a quarter of the cost.
	var t_sh := Time.get_ticks_usec()
	var t_ss := t_sh
	if camera != null and Engine.get_physics_frames() % 4 == 0:
		_stream_shells()
	t_ss = _part("ss_shells", t_ss)
	if not _glass_owed.is_empty() or not _glass_jobs.is_empty():
		var t_gl := Time.get_ticks_usec()
		_build_owed_glass()
		_glass_note(Time.get_ticks_usec() - t_gl)
	t_ss = _part("ss_glass", t_ss)
	if not _shadow_jobs.is_empty():
		_harvest_shadow_jobs()
	t_ss = _part("ss_proxies", t_ss)
	if camera != null and Engine.get_physics_frames() % 8 == 2:
		_stream_shadows()
	t_ss = _part("ss_shadows", t_ss)
	if camera != null and Engine.get_physics_frames() % 4 == 1:
		_inst_update()
	_part("ss_inst", t_ss)
	_part("st_shells", t_sh)
	if _show_grids:
		_draw_grids()
	t = _mark("stream", t)

	# Merged bands that lost bricks this tick, merged again without them
	# (BuildingCollision.flush): after everything that can take bricks out --
	# detaches, blasts, rooms shut -- and before the physics steps.
	# FLUSH_BANDS_PER_TICK between them; what is left over is parked.
	var flushed := 0
	var worst := 0.0
	var worst_bands := 0
	for cid in _brick_cols:
		var bc: BuildingCollision = _brick_cols[cid]
		if not bc.any_stale():
			continue
		var n := bc.flush(maxi(FLUSH_BANDS_PER_TICK - flushed, 0))
		flushed += n
		if bc.last_flush_ms > worst:
			worst = bc.last_flush_ms
			worst_bands = n
	_prof["col_bands"] = float(flushed)
	_prof["col_worst"] = worst
	_prof["col_worst_bands"] = float(worst_bands)
	t = _mark("collision", t)

	islands.tick()
	t = _mark("islands", t)
	# Falling masonry hurts, and nobody is left inside it (Crush).
	crush.tick(islands, _all_pawns())
	t = _mark("crush", t)
	# Nobody can read it at 60 Hz, and at 400 islands it was costing more than
	# the stress solve.
	if Engine.get_physics_frames() % 10 == 0:
		_update_hud()
	_mark("hud", t)
	# Last: the tick's mesh uploads go to the workers now, so they finish
	# during the frame rather than halfway through this tick (see
	# IslandManager._submit_mesh_job).
	islands.start_mesh_jobs()
	_start_band_jobs()

	var tick_total := float(Time.get_ticks_usec() - t_tick) / 1000.0
	_prof["script_total"] = tick_total
	if _sampling:
		if _clock == null:
			_clock = FrameClock.new()
			add_child(_clock)
		_clock.script_ms += tick_total
	_ai_tick(tick_total)
	# After the AI, which reads the buildings (cover, sight) and would only
	# wait for these: from here they run while the physics steps.
	_start_solves()
	if _sampling:
		_tick_samples += 1
		for k in _prof:
			_prof_sum[k] = float(_prof_sum.get(k, 0.0)) + float(_prof[k])
		if tick_total > SPIKE_MS:
			var phases: Array = []
			for k in _prof:
				if not (k as String).contains("_"):
					phases.append([float(_prof[k]), k])
			phases.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
			var top := ""
			for k in mini(3, phases.size()):
				top += "%s %.1f  " % [phases[k][1], phases[k][0]]
			if not phases.is_empty():
				top += "| " + _spike_parts(phases[0][1])
			_prof_spikes.append([tick_total, Engine.get_physics_frames(), top])
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
	_drop_proxies(id)
	_nav_touch(id)
	_shell_coarse.erase(id)
	_shell_far.erase(id)
	_shell_box.erase(id)
	_far_hide(id)
	_shell_inst.erase(id)
	_far_real_done.erase(id)
	var fb := registry.get_building(id)
	if fb != null:
		_inst_sync(fb)
	if _shells.has(id):
		(_shells[id] as MeshInstance3D).queue_free()
		_shells.erase(id)
	_free_shell_body(id)


func _free_shell_body(id: int) -> void:
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
	# The bench measures shells (Docs/Terrain.md 19.5). A street-level
	# viewpoint promoting the buildings beside it, at whatever tick it got
	# round to them, made every reading after it a different city.
	if _bench_mode and not _bench_bricks:
		return
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
		if b == null or b.toppled or b.is_build():
			continue
		if _promote_queue.has(id):
			continue
		var dist := _box_distance(_world_box(b), here)
		if dist > PROMOTE_RANGE:
			continue
		# The storeys at the camera's height (Docs/Space.md 5.3a): a walk-up
		# is for the rooms about to be asked for, and those are on its storey.
		var want := _storeys_for(id, here, AIM_STOREY_REACH)
		if not _wants_bricks(b, want):
			continue
		found.append([dist, id, want])
	if found.is_empty():
		return
	# Nearest first: the one whose rooms are about to be asked for is the one
	# worth a promotion this pass.
	found.sort_custom(func(a, c) -> bool: return float(a[0]) < float(c[0]))
	for i in mini(PROMOTE_PER_PASS, found.size()):
		_queue_promotion(int(found[i][1]), found[i][2], false)
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
	var shell_budget := SHELLS_PER_TICK
	var looked := 0
	# A full pass over the register every eight, however many there are: with
	# trees in it the register is ten times the city, and a fixed slice left a
	# building waiting seconds for its tier.
	var slice := mini(count, maxi(SHELLS_PER_TICK * 16, floori(count / 8.0) + 1))
	# And a time budget, as the glass has: a tall tower's shell and its
	# collision are several ms, and four in one tick was a 5+ ms hitch. The
	# rest wait for the next pass, a quarter of a tick-group later.
	var t0 := Time.get_ticks_usec()
	while looked < slice and shell_budget > 0:
		if shell_budget < SHELLS_PER_TICK \
				and Time.get_ticks_usec() - t0 > int(SHELL_BUDGET_MS * 1000.0):
			break
		var b = registry.buildings[_stream_cursor % count]
		_stream_cursor += 1
		looked += 1
		shell_budget -= _stream_shell(b, here)
		# After the shell's own step, so a building whose shell just went
		# gets its far box in the same tick rather than a pass later.
		_far_sync(b)
		_inst_sync(b)
	_far_dmg_upload()


## One building's step of _stream_shells. Returns how much of the budget it used.
func _stream_shell(b: BuildingRegistry.Building, here: Vector3) -> int:
	if b.is_materialised() or b.toppled:
		return 0
	var dist: float = b.xform.origin.distance_to(here)
	if not _shells.has(b.id):
		if dist < SHELL_RANGE or _needs_far_shell(b):
			_make_shell(b.id, dist > SHELL_DETAIL_RANGE, dist >= SHELL_RANGE)
			_shells_made += 1
			return 1
		return 0
	if dist > SHELL_RANGE + SHELL_HYSTERESIS:
		if not _needs_far_shell(b):
			_free_shell(b.id)
			_shells_freed += 1
			return 1
		if not _shell_far.has(b.id):
			# Drawn on, but past the range anything collides with.
			_drop_proxies(b.id)
			_nav_touch(b.id)
			_free_shell_body(b.id)
			_shell_far[b.id] = true
			return 1
		return 0
	if _shell_far.has(b.id) and dist < SHELL_RANGE:
		_make_shell_body(b.id)
		return 1
	# Tier swap, with the same hysteresis band so a building on the line
	# does not rebuild its mesh every tick.
	var coarse: bool = _shell_coarse.get(b.id, false)
	# A damaged building the far box cannot draw is never coarse (see
	# _make_shell), so it has no tier to swap to: without this it rebuilt its
	# banded shell every pass.
	if not coarse and b.is_damaged() and not _far_draws_coarse(b):
		return 0
	# In at FADE_IN_AT, out past the far end of the fade band: the crossfade
	# covers the whole band, so the old wide hysteresis is not needed to hide
	# a pop, only to stop a building on the line rebuilding every pass.
	if coarse and dist < FADE_IN_AT:
		_free_shell(b.id)
		_make_shell(b.id, false)
		_shells_swapped += 1
		return 1
	if not coarse and dist > SHELL_DETAIL_RANGE + SHELL_HYSTERESIS:
		_free_shell(b.id)
		_make_shell(b.id, true)
		_shells_swapped += 1
		return 1
	return 0


# ---------------------------------------------------------------------------
# Instanced builds: trees, and later items (Docs/Impostors.md 8)
# ---------------------------------------------------------------------------
#
# A tree is a registered build, so it is destructible like any building: shot,
# it materialises, sheds pieces, topples (Trees). But hundreds of them each
# with a shell mesh would be hundreds of draw calls. So an INTACT one is drawn
# by the ImpostorLod of its recipe -- its real bricks instanced up close, an
# octahedral card further out, two draw calls for every tree of that kind --
# and its shell node, inside SHELL_RANGE, has no mesh: only its collision.
# Once it is damaged or holds bricks, it draws itself the ordinary way.

## Nearer than this a tree is its real bricks (instanced); further, a card.
const TREE_NEAR := 45.0
## Trees at most, and how far out from the middle they grow, in studs. Past
## the city's own detailed ground: the city stands on rock, and the grass is
## round it. A tree out there stands on the coarse ring, whose surface is the
## field's height within a plate or two.
const TREE_MAX := 800
const TREE_REACH_STUDS := 1200

var _inst_sets := {}      ## impostor key -> ImpostorLod
var _recipe_keys := {}    ## recipe instance id -> its impostor key
var _inst_handle := {}    ## building id -> its handle in that set
var _shell_inst := {}     ## building id -> its shell is drawn by the set
var _trees_placed := 0
var _terrain_half := 0   ## tiles each way the detailed ground reaches


## The key of the instanced set a build belongs to, or "" if it draws itself.
## A tree names its own; any other build is keyed by what it is made of, so
## two copies of the same watchtower share one bake (Stage 4).
func _inst_key(b: BuildingRegistry.Building) -> String:
	if not b.is_build():
		return ""
	var k := str(b.build.meta.get("impostor_key", ""))
	if k != "":
		return k
	var rid := b.build.get_instance_id()
	if not _recipe_keys.has(rid):
		_recipe_keys[rid] = "build_%x" % str(b.build.to_dict()).hash()
	return _recipe_keys[rid]


## Drawn by its set up close too (instanced bricks), not only past SHELL_RANGE:
## small, many and identical -- a tree. A player build keeps its own shell
## inside SHELL_RANGE, where it may be the thing somebody is looking at.
func _inst_near(b: BuildingRegistry.Building) -> bool:
	return b.is_build() and b.build.meta.has("impostor_key")


## Can its set draw it: one of a set, and exactly as its recipe says.
func _inst_ok(b: BuildingRegistry.Building) -> bool:
	return _inst_key(b) != "" and not b.is_damaged() and not b.is_materialised() \
			and not b.toppled


## Show or hide a building's copy in its set to match what else draws it.
func _inst_sync(b: BuildingRegistry.Building) -> void:
	if not _inst_handle.has(b.id):
		# A build placed any other way than _place_trees gets its copy the
		# first time it is asked about, and only once it is far enough out
		# to need one: meshing a big build for its bake is not free.
		if not b.is_build() or _inst_key(b) == "" or _shells.has(b.id) or not _inst_ok(b):
			return
		var s := _inst_set(_inst_key(b), b.build, _inst_near(b))
		_inst_handle[b.id] = s.add(b.xform, false)
	var set_: ImpostorLod = _inst_sets[_inst_key(b)]
	var want: bool
	if _shell_inst.has(b.id):
		# As the far box does for a coarse shell (_far_sync): kept while the
		# placeholder is, so a tree shot and materialising is never undrawn.
		want = not b.toppled
	else:
		want = _inst_ok(b) and not _shells.has(b.id)
	set_.set_wanted(int(_inst_handle[b.id]), want)


func _inst_set(key: String, recipe: BuildRecipe, near := true) -> ImpostorLod:
	if _inst_sets.has(key):
		return _inst_sets[key]
	var s := ImpostorLod.new()
	s.name = "Inst_%s" % key
	add_child(s)
	# A player build is only ever a card here: up close it is its own shell.
	var inst_mesh := RecipeMesh.build(recipe, key)
	if inst_mesh != null and String(recipe.name).begins_with("tree_"):
		s.sway = WeatherFx.sway_tree(inst_mesh.get_aabb().end.y)
		s.snowcap = 1.0
	s.setup(inst_mesh, brick_material, TREE_NEAR if near else -1.0)
	_inst_sets[key] = s
	return s


## Trees over the detailed ground (Trees.scatter), each a registered build.
## Shells are left to _stream_shells: a tree past SHELL_RANGE never needs one.
func _place_trees() -> void:
	var t0 := Time.get_ticks_usec()
	var span := maxi(_terrain_half * BrickTerrain.get_tile_studs(), TREE_REACH_STUDS)
	var spots: Array = Trees.scatter(Rect2i(-span, -span, span * 2, span * 2),
			int(BrickTerrain.get_seed()), TREE_MAX)
	for s in spots:
		var variant: int = s.variant
		var recipe := Trees.recipe(variant)
		# Past the detail square the ground drawn is the coarse tier's, which
		# is not the field's height: stand on what is drawn.
		var cell: Vector3i = s.cell
		var ground := NAN
		if _terrain_coarse != null:
			ground = _terrain_coarse.height_at(cell.x, cell.z)
		var id := registry.register_build(recipe, Trees.placement(cell, variant, ground))
		if id < 0:
			continue
		_index_building(id)
		var b := registry.get_building(id)
		var set_ := _inst_set(_inst_key(b), recipe)
		_inst_handle[id] = set_.add(b.xform, false)
		_inst_sync(b)
		_trees_placed += 1
	print("[city] trees: %d placed in %.0f ms (%d kinds)" % [
		_trees_placed, float(Time.get_ticks_usec() - t0) / 1000.0, _inst_sets.size()])


func _inst_update() -> void:
	var here := camera.global_position
	for s in _inst_sets.values():
		(s as ImpostorLod).update(here)


# ---------------------------------------------------------------------------
# Shadow LOD (Docs/Impostors.md section 7.2)
# ---------------------------------------------------------------------------
#
# The directional light draws every caster again into each of its cascades, and
# a building's brick mesh is a million triangles: three brick buildings in view
# were 3.3M triangles of shadow pass alone (section 7.1). But a big thing's
# shadow is big, and seen from far off, so it cannot just be switched off.
#
# So what casts is chosen by size and distance, not dropped:
#
#   * a materialised building casts with a shadow-only SHELL of itself --
#     BuildingShell from the live damage profile, or BuildShell for a build --
#     about three thousand triangles, the right shape, holes included -- and
#     only the bands of its bricks within BRICK_SHADOW_RANGE cast as well;
#   * a big piece of wreckage (an island wider than SMALL_ISLAND_RADIUS) casts
#     at any range; a small one only inside SMALL_SHADOW_RANGE, where its
#     shadow is more than a few pixels;
#   * a far box casts (the far MultiMesh), so a tower past the shell range
#     still throws its long shadow into view.

const BRICK_SHADOW_RANGE := 15.0
## Proxies built or rebuilt per pass: a profile and a shell are ~0.5 ms.
const SHADOW_PROXIES_PER_PASS := 2
## A piece of wreckage up to this radius is "small" (metres, BrickIsland.radius).
const SMALL_ISLAND_RADIUS := 2.5
const SMALL_SHADOW_RANGE := 30.0
## Directional shadows reach this far, so a tower's shadow does too. The splits
## keep the first cascades as tight as the 100 m default had them.
const SUN_SHADOW_DISTANCE := 400.0

var _shadow_proxy := {}       ## building id -> MeshInstance3D, shadows only
## Proxies being built on a worker: building id -> [task, [mesh], alive bricks
## it was built from, dropped since]. The old proxy -- or, before the first,
## the bricks themselves -- casts until the new one is hung.
var _shadow_jobs := {}
var _shadow_proxy_alive := {} ## building id -> alive bricks when it was built
## A proxy is rebuilt once its building has stopped losing bricks -- the same
## count two passes running -- or after SHADOW_STALE_PASSES of it going on.
## Rebuilt on every pass that saw a brick go, a building being taken apart
## rebuilt its proxy every eight ticks, and a proxy is not the 0.5 ms above for
## a big one: 10-28 ms (6,000-22,000 bricks), the worst tick of a collapse
## after the solve's. A shadow a second or two behind the bricks it is cast
## by, while they are still coming down, is not something anyone sees.
const SHADOW_STALE_PASSES := 8
var _shadow_seen := {}        ## building id -> alive bricks at the last pass
var _shadow_stale := {}       ## building id -> passes it has been stale
var _shadow_stats := {"proxies": 0, "bricks_casting": 0, "small_quiet": 0}


func _setup_sun_shadows(sun: DirectionalLight3D) -> void:
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = SUN_SHADOW_DISTANCE
	# Fractions of the distance: 10, 36 and 120 m, against 10, 20 and 50 m of
	# the default at 100 m. The first cascade, the one a figure's feet are
	# in, is exactly as sharp as it was.
	sun.directional_shadow_split_1 = 0.025
	sun.directional_shadow_split_2 = 0.09
	sun.directional_shadow_split_3 = 0.3
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.9
	# Options > Video: two slices, the near one as sharp as the four's, the
	# far one to the end (PerfCaps.md 2.2).
	if BrickcityMenuHost.sun_cascades == 2:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_split_1 = 0.025


## Every so often: who casts what. Cheap -- a distance per brick building and
## per island, and a proxy mesh only when one changes tier or is shot.
func _stream_shadows() -> void:
	var here := camera.global_position
	var built := 0
	var casting := 0
	# Proxies whose building has no bricks drawn any more.
	for id in _shadow_proxy.keys():
		if not _brick_nodes.has(id):
			_drop_shadow_proxy(id)
	for id in _brick_nodes:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var alive := world.get_alive_block_count(b.chunk)
		var stale: bool = not _shadow_proxy.has(id)
		if not stale and int(_shadow_proxy_alive.get(id, -1)) != alive:
			_shadow_stale[id] = int(_shadow_stale.get(id, 0)) + 1
			stale = alive == int(_shadow_seen.get(id, -1)) \
					or int(_shadow_stale[id]) >= SHADOW_STALE_PASSES
		_shadow_seen[id] = alive
		var t_sp := Time.get_ticks_usec()
		if stale and built < SHADOW_PROXIES_PER_PASS and _make_shadow_proxy(b):
			built += 1
			_shadow_stale.erase(id)
		t_sp = _part("sp_make", t_sp)
		casting += _set_brick_shadows_near(id, here)
		_part("sp_near", t_sp)
	var quiet := 0
	var proxied := 0
	for isl in islands.islands:
		if isl == null or not is_instance_valid(isl.mesh):
			continue
		var dist := isl.mesh.global_position.distance_to(here)
		var cast := isl.radius > SMALL_ISLAND_RADIUS \
				or dist < SMALL_SHADOW_RANGE + isl.radius
		# A big piece further off casts its coarse stand-in instead of its
		# bricks once it has one (IslandManager.want_shadow_proxy).
		var proxy := false
		if cast and not isl.coarse and isl.radius > SMALL_ISLAND_RADIUS \
				and dist > BRICK_SHADOW_RANGE + isl.radius:
			islands.want_shadow_proxy(isl)
			proxy = islands.has_shadow_proxy(isl)
		var mode := (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast and not proxy
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		if isl.mesh.cast_shadow != mode:
			isl.mesh.cast_shadow = mode
		for band in isl.bands:
			if is_instance_valid(band) and (band as GeometryInstance3D).cast_shadow != mode:
				(band as GeometryInstance3D).cast_shadow = mode
		if is_instance_valid(isl.shadow_mesh) and isl.shadow_mesh.visible != proxy:
			isl.shadow_mesh.visible = proxy
		if proxy:
			proxied += 1
		if not cast:
			quiet += 1
	_shadow_stats = {"proxies": _shadow_proxy.size(), "bricks_casting": casting,
			"small_quiet": quiet, "pieces_proxied": proxied}


## Which of a building's bricks cast. Without a shadow shell, all of them.
## With one, only the bands (and extra frames) within BRICK_SHADOW_RANGE of the
## camera: a tower beside you is mostly far above you, and the part that is
## not is where a stud's shadow can be seen. Where both cast, the shadow is the
## same. Returns how many brick nodes cast.
func _set_brick_shadows_near(id: int, here: Vector3) -> int:
	var all: bool = not _shadow_proxy.has(id)
	var nodes: Array = []
	var mi = _brick_nodes.get(id)
	if is_instance_valid(mi):
		nodes.append(mi)
		nodes.append_array((mi as Node).get_children())
	nodes.append_array(_frame_nodes.get(id, []))
	var casting := 0
	for node in nodes:
		if not is_instance_valid(node) or not (node is GeometryInstance3D):
			continue
		var g := node as GeometryInstance3D
		var on := all
		if not on and g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			var box: AABB = g.global_transform * (g as MeshInstance3D).get_aabb()
			on = _box_distance(box, here) < BRICK_SHADOW_RANGE
		# Only when it changes: every set is a renderer call, and this pass
		# set every node of every building in bricks every eighth tick
		# (PerfCaps.md 4).
		var mode := (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		if g.cast_shadow != mode:
			g.cast_shadow = mode
		if on:
			casting += 1
	return casting


func _set_brick_shadows(id: int, on: bool) -> void:
	var mode := (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	var mi = _brick_nodes.get(id)
	if is_instance_valid(mi):
		(mi as MeshInstance3D).cast_shadow = mode
		for band in (mi as Node).get_children():
			if band is GeometryInstance3D:
				(band as GeometryInstance3D).cast_shadow = mode
	for node in _frame_nodes.get(id, []):
		if is_instance_valid(node) and node is GeometryInstance3D:
			(node as GeometryInstance3D).cast_shadow = mode


## A shadow-only shell of a materialised building, from what is standing now.
func _make_shadow_proxy(b: BuildingRegistry.Building) -> bool:
	if _shadow_jobs.has(b.id):
		return false  # one on its way already
	if b.is_build():
		# A build's shell reads the world's blocks: here, as it always was.
		var built: Mesh = BuildShell.build_mesh(world, b.build, _dead_by_frame(b), false)
		if built == null:
			return false
		_attach_shadow_proxy(b, built, world.get_alive_block_count(b.chunk))
		return true
	# A recipe building's shell is arithmetic on the recipe and the damage
	# masks, and nothing of the world: only the masks are worked out here (they
	# read the bricks), the rest on a worker. Built here it was 4-25 ms a proxy
	# -- the biggest thing left at the top of a collapse's worst ticks.
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var profile := registry.live_damage_profile(b.id)
	var layout: Array = TowerRecipe.layout(courses)
	var holder := [null]
	var work := func() -> void:
		holder[0] = BuildingShell.build_mesh(fx, fz, courses, profile, layout)
		UploadLedger.note("building shadow", -1)
	var task := WorkerThreadPool.add_task(work, false, "shadow proxy")
	_shadow_jobs[b.id] = [task, holder, world.get_alive_block_count(b.chunk), false]
	return true


## Hang the proxies the workers have finished. Every tick, and nothing to do
## on most of them.
func _harvest_shadow_jobs() -> void:
	for id in _shadow_jobs.keys():
		var job: Array = _shadow_jobs[id]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		_shadow_jobs.erase(id)
		var b := registry.get_building(int(id))
		# Dropped meanwhile (its bricks given back), or gone.
		if bool(job[3]) or b == null or not b.is_materialised() or not _brick_nodes.has(id) \
				or job[1][0] == null:
			continue
		_attach_shadow_proxy(b, job[1][0], int(job[2]))


func _attach_shadow_proxy(b: BuildingRegistry.Building, mesh: Mesh, alive: int) -> void:
	var mi: MeshInstance3D = _shadow_proxy.get(b.id)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "ShadowProxy_%d" % b.id
		mi.material_override = brick_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mi.transform = b.xform
		add_child(mi)
		_shadow_proxy[b.id] = mi
	mi.mesh = mesh
	# What it was built from: bricks lost since then make it stale again.
	_shadow_proxy_alive[b.id] = alive


func _drop_shadow_proxy(id: int) -> void:
	if _shadow_jobs.has(id):
		(_shadow_jobs[id] as Array)[3] = true  # still waited for; never hung
	var mi = _shadow_proxy.get(id)
	if is_instance_valid(mi):
		(mi as Node).queue_free()
	_shadow_proxy.erase(id)
	_shadow_proxy_alive.erase(id)
	_shadow_seen.erase(id)
	_shadow_stale.erase(id)
	_set_brick_shadows(id, true)


# ---------------------------------------------------------------------------
# The far city (Docs/Impostors.md, Stages 1-3)
# ---------------------------------------------------------------------------
#
# Past SHELL_RANGE a recipe building is one instance of a unit box in one
# MultiMesh: the whole far city in one draw call, where it used to draw nothing
# at all out to camera.far. A recipe building IS a box, so the box is its true
# shape, and shaders/city_far.gdshader draws its courses, slabs and windows
# from the recipe's own rules.
#
# Damage shows at every distance (Docs/Collapse.md 2.3): a damaged building's
# BuildingShell segment masks go into one row of _far_dmg_tex, and the shader
# cuts the same holes the shell would. The profile only changes when a building
# gives its bricks back, and a building with bricks has no far box, so the row
# is written whenever the box is shown and is never stale.
#
# A player build can be any shape, so it keeps its shell out there instead,
# drawing only (_needs_far_shell), until Stage 4 bakes it.

## Room for this many far instances before the buffer has to grow.
const FAR_INITIAL_CAPACITY := 256
## Stage 5, the crossfade. A banded shell is fully drawn nearer than FADE_NEAR
## and gone at FADE_FAR, alpha-blended in between over its far box, which is
## drawn whole under it (city_far.gdshader): a real crossfade.
## Coarse -> banded at FADE_IN_AT; banded -> coarse past FADE_FAR (the old
## SHELL_DETAIL_RANGE + SHELL_HYSTERESIS), where the shell has faded out.
const FADE_NEAR := 80.0
const FADE_FAR := 140.0
const FADE_IN_AT := 130.0
var _far_fade := {}   ## building id -> 1.0 while its box crossfades with a shell


## Godot's own visibility-range fade over the band. It BLENDS a fading
## instance, alpha = smoothstep over [end - margin, end + margin] from its
## bounds' centre (renderer_scene_cull / render_forward_clustered, 4.6) -- so
## end and margin are set for that span to be exactly FADE_NEAR..FADE_FAR,
## and the shell is gone by the time the streamer frees it.
func _fade_out(g: GeometryInstance3D) -> void:
	g.visibility_range_end = (FADE_NEAR + FADE_FAR) * 0.5
	g.visibility_range_end_margin = (FADE_FAR - FADE_NEAR) * 0.5
	g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
## Rows of damage before the texture has to grow.
const FAR_DMG_INITIAL_ROWS := 16
var _far: MultiMeshInstance3D = null
var _far_slot := {}   ## building id -> its instance in the far MultiMesh
var _far_on := {}     ## building id -> true while its far box is drawn
var _shell_box := {}  ## building id -> its coarse shell is drawn by its far box
var _far_dmg_row := {}                  ## building id -> its row of damage
var _far_dmg_free: Array[int] = []      ## rows given back
var _far_dmg_rows := 0                  ## rows handed out, ever
var _far_dmg_width := 0                 ## texels a row: four per band
var _far_dmg_height := 0
var _far_dmg_bytes := PackedByteArray()
var _far_dmg_tex: ImageTexture = null
var _far_dmg_dirty := false


## A building past SHELL_RANGE the far box would draw wrongly: it keeps a shell.
func _needs_far_shell(b: BuildingRegistry.Building) -> bool:
	# An intact tree is drawn by its instanced set out there instead.
	return b.is_build() and not _inst_ok(b)


## Can the far box stand in for this building's coarse shell (Stage 2)? A
## recipe building whose damage, if any, is in its profile: not a build, and
## not holding bricks, whose damage the profile does not have yet.
func _far_draws_coarse(b: BuildingRegistry.Building) -> bool:
	return not b.is_build() and not b.is_materialised()


## Show or hide one building's far box to match what else draws it.
func _far_sync(b: BuildingRegistry.Building) -> void:
	var want: bool
	if _shell_box.has(b.id):
		# Its coarse shell is drawn by the far box. Kept while the shell is,
		# materialised or not: a building shot at range holds its shell until
		# its bricks are built, and hiding the box would leave nothing drawn.
		want = not b.toppled
	else:
		want = not (b.toppled or b.is_materialised() or _shells.has(b.id)
				or b.is_build())
	# Under a banded shell that is fading (Stage 5), drawn too, flagged so it
	# sits just inside the shell for the shell to blend over.
	var fade := 0.0
	if not want and _shells.has(b.id) and not b.is_build() and not b.is_materialised() \
			and not b.toppled and not _shell_coarse.get(b.id, false):
		want = true
		fade = 1.0
	if want == _far_on.has(b.id) and fade == float(_far_fade.get(b.id, 0.0)):
		return
	if not want:
		_far_hide(b.id)
		return
	var mm := _far_multimesh()
	var slot := _far_slot_of(b.id)
	var r: Dictionary = b.recipe
	# The cornice is left off: it is a row of black buttresses along one edge
	# (BuildingShell.build_arrays), a pixel at this range, and a box that
	# included its height would put the roof above the other three walls.
	var size := Vector3(int(r.footprint_x) * STUD,
			(TowerRecipe.total_plates(int(r.courses)) - TowerRecipe.PLATES_PER_COURSE) * PLATE,
			int(r.footprint_z) * STUD)
	mm.set_instance_transform(slot, b.xform * Transform3D(Basis.from_scale(size), Vector3.ZERO))
	if _far_dmg_row.has(b.id):
		_far_dmg_free.append(int(_far_dmg_row[b.id]))
		_far_dmg_row.erase(b.id)
	mm.set_instance_custom_data(slot, Color(float(r.courses), float(_far_dmg_write(b)),
			float(b.id), fade))
	_far_on[b.id] = true
	_far_fade[b.id] = fade


## Hide a building's far box, if it has one drawn. Zero scale rather than a
## compacted buffer: slots never move, so nothing else has to be rewritten.
func _far_hide(id: int) -> void:
	if not _far_on.has(id):
		return
	_far_on.erase(id)
	_far_fade.erase(id)
	_far.multimesh.set_instance_transform(int(_far_slot[id]),
			Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
	if _far_dmg_row.has(id):
		_far_dmg_free.append(int(_far_dmg_row[id]))
		_far_dmg_row.erase(id)


func _far_slot_of(id: int) -> int:
	if _far_slot.has(id):
		return _far_slot[id]
	var mm := _far.multimesh
	var slot := _far_slot.size()
	if slot >= mm.instance_count:
		_far_grow(mm.instance_count * 2)
	_far_slot[id] = slot
	mm.visible_instance_count = slot + 1
	return slot


## A bigger buffer with the same contents: setting instance_count clears it.
func _far_grow(capacity: int) -> void:
	var mm := _far.multimesh
	var old := mm.buffer
	var used := mm.visible_instance_count
	mm.instance_count = capacity
	var buf := mm.buffer
	for i in old.size():
		buf[i] = old[i]
	mm.buffer = buf
	mm.visible_instance_count = used


## Write a building's damage into a row of the texture. -1 if it has none.
##
## Four texels a band, one per side in BuildingShell's SIDE_* order, whose
## RGBA bytes are that side's 32-bit segment mask, low byte first. A band the
## profile does not name is standing all round.
func _far_dmg_write(b: BuildingRegistry.Building) -> int:
	if b.damage_profile.is_empty():
		return -1
	var bands := TowerRecipe.layout(int(b.recipe.courses)).size()
	var row: int
	if not _far_dmg_free.is_empty():
		row = _far_dmg_free.pop_back()
	else:
		row = _far_dmg_rows
		_far_dmg_rows += 1
	_far_dmg_fit(bands * 4, row + 1)
	_far_dmg_row[b.id] = row
	var at := row * _far_dmg_width * 4
	for band in bands:
		var masks: PackedInt32Array = b.damage_profile.get(band, PackedInt32Array())
		for side in 4:
			var m: int = masks[side] if masks.size() == 4 else BuildingShell.ALL_STANDING
			_far_dmg_bytes[at] = m & 0xFF
			_far_dmg_bytes[at + 1] = (m >> 8) & 0xFF
			_far_dmg_bytes[at + 2] = (m >> 16) & 0xFF
			_far_dmg_bytes[at + 3] = (m >> 24) & 0xFF
			at += 4
	_far_dmg_dirty = true
	return row


## Make the damage texture at least this big, keeping what is in it.
func _far_dmg_fit(width: int, height: int) -> void:
	if width <= _far_dmg_width and height <= _far_dmg_height:
		return
	var w := maxi(width, _far_dmg_width)
	var h := maxi(_far_dmg_height, FAR_DMG_INITIAL_ROWS)
	while h < height:
		h *= 2
	var bytes := PackedByteArray()
	bytes.resize(w * h * 4)
	bytes.fill(0xFF)
	for y in _far_dmg_height:
		for x in _far_dmg_width * 4:
			bytes[(y * w) * 4 + x] = _far_dmg_bytes[(y * _far_dmg_width) * 4 + x]
	_far_dmg_bytes = bytes
	_far_dmg_width = w
	_far_dmg_height = h
	# A new size is a new texture; update() only takes the same size.
	_far_dmg_tex = null


## Upload the damage rows written this tick, once.
func _far_dmg_upload() -> void:
	if not _far_dmg_dirty or _far == null:
		return
	_far_dmg_dirty = false
	var img := Image.create_from_data(_far_dmg_width, _far_dmg_height, false,
			Image.FORMAT_RGBA8, _far_dmg_bytes)
	if _far_dmg_tex == null:
		_far_dmg_tex = ImageTexture.create_from_image(img)
		(_far.material_override as ShaderMaterial).set_shader_parameter("damage_tex", _far_dmg_tex)
	else:
		_far_dmg_tex.update(img)


func _far_multimesh() -> MultiMesh:
	if _far != null:
		return _far.multimesh
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _far_box_mesh()
	mm.instance_count = FAR_INITIAL_CAPACITY
	mm.visible_instance_count = 0
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/city_far.gdshader")
	WeatherFx.register(mat)
	# The colours the shell is built in (BuildingShell.build_arrays), so the
	# swap from a shell has no colour step.
	var courses := []
	for c in TowerRecipe.COURSE_COLOURS:
		courses.append(_far_rgb(c))
	mat.set_shader_parameter("course_colours", courses)
	mat.set_shader_parameter("base_colour", _far_rgb(TowerRecipe.BASE_COLOUR))
	mat.set_shader_parameter("slab_colour", _far_rgb(TowerRecipe.SLAB_COLOUR))
	_far = MultiMeshInstance3D.new()
	_far.name = "FarCity"
	# Not interpolated: a slot shown or hidden (a zero-scale transform) would
	# otherwise grow or shrink over a frame, and the buildings never move.
	_far.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_far.multimesh = mm
	_far.material_override = mat
	# Casts: a tower's shadow is long and seen from far off (section 7.2).
	# Ten triangles a building, and the cascades cut away what is out of reach.
	_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_far)
	return mm


static func _far_rgb(filament: int) -> Vector3:
	var c := BrickWorld.get_filament_colour(filament)
	return Vector3(c.r, c.g, c.b)


## A box from (0,0,0) to (1,1,1), four walls and a roof, white. The instance
## transform scales it to the building; the underside is never seen.
static func _far_box_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	# Each face's corners run anticlockwise seen from outside.
	var faces := [
		[Vector3(0, 0, 1), [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)]],
		[Vector3(0, 0, -1), [Vector3(1, 0, 0), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)]],
		[Vector3(1, 0, 0), [Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1)]],
		[Vector3(-1, 0, 0), [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)]],
		[Vector3(0, 1, 0), [Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(0, 1, 0)]],
	]
	var indices := PackedInt32Array()
	for f in faces:
		var base := verts.size()
		for c in f[1]:
			verts.append(c)
			normals.append(f[0])
		# Godot's front face is clockwise, so the triangles run backwards.
		indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	var colours := PackedColorArray()
	colours.resize(verts.size())
	colours.fill(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A building in bricks past DEMESH_RANGE that is damaged is drawn from its
## bricks as they are: a coarse mesh of its own grid, as a far piece's stand-in
## is (IslandManager._build_coarse), on a worker past COARSE_ASYNC_BLOCKS. Its
## shell draws its damage as holes in each band, and a hole cannot say a floor
## has come down: a collapsed wide building stood as a skeleton of floors and
## columns from far off, rubble from close (user, 2026-10-16; Docs/Structures.md
## 2.1). The shell node stays -- its collision, and every "has a shell" question
## -- and draws the shell until the coarse mesh is ready. No windows: a coarse
## mesh has its holes where the bricks are gone. Asked again whenever the shell
## is (_shell_stale, after a hit).
var _far_real_owed := {}   ## building id -> the shell node waiting for its mesh
var _far_real_done := {}   ## building id -> the shell node drawn from its bricks
var far_real_built := 0


func _far_real(id: int, mi: MeshInstance3D) -> void:
	var b := registry.get_building(id)
	if world.get_alive_block_count(b.chunk) < IslandManager.COARSE_ASYNC_BLOCKS:
		_far_real_apply(id, mi, world.build_chunk_coarse_mesh(b.chunk))
		return
	if not world.coarse_pending(b.chunk):
		world.coarse_chunk_async(b.chunk)
	_far_real_owed[id] = mi


func _harvest_far_real() -> void:
	for id in _far_real_owed.keys():
		var mi = _far_real_owed[id]
		var b := registry.get_building(id)
		if not is_instance_valid(mi) or _shells.get(id) != mi or b == null or not b.is_materialised():
			_far_real_owed.erase(id)
			continue
		if world.coarse_ready(b.chunk):
			_far_real_owed.erase(id)
			_far_real_apply(id, mi, world.take_coarse_mesh(b.chunk))
		elif not world.coarse_pending(b.chunk):
			# Settled by an edit (BrickWorld.settle_coarse_job): asked again.
			world.coarse_chunk_async(b.chunk)


## A shell drawn from its bricks, hit again: asked again of the bricks, in
## place -- its coarse mesh (on a worker past COARSE_ASYNC_BLOCKS) and its
## panes, each drawing what it has until the new one lands. Made anew it was
## a damage profile and a recipe shell (7.2 + 7.3 ms on a --big --shot,
## 2026-10-23) for a drawing replaced a tick or two later. False when it is
## not one, or no longer can be: made anew as before.
func _refresh_real_shell(id: int) -> bool:
	var mi = _shells.get(id)
	if mi == null or not is_instance_valid(mi):
		return false
	if _far_real_done.get(id) != mi and _far_real_owed.get(id) != mi:
		return false
	var b := registry.get_building(id)
	if b == null or not b.is_materialised() or b.is_build() or _toppling.has(id):
		return false
	if world.get_alive_block_count(b.chunk) == 0 and not registry.is_partial(b):
		return false
	_far_real(id, mi)
	_glass_owed.append([mi, id, {}, false, true])
	return true


func _far_real_apply(id: int, mi: MeshInstance3D, arrays: Array) -> void:
	var m := ArrayMesh.new()
	if not arrays.is_empty() and IslandManager.mesh_arrays_ok(arrays, "far building"):
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mi.mesh != null:
		_retirer.retire(mi.mesh)
	mi.mesh = m
	_far_real_done[id] = mi
	far_real_built += 1


## Drop the mesh of resident buildings nobody can see the bricks of, and put it
## back for ones that have come close again. See DEMESH_RANGE.
func _stream_detail() -> void:
	var t_sd := Time.get_ticks_usec()
	if not _far_real_owed.is_empty():
		_harvest_far_real()
	t_sd = _part("sd_far", t_sd)
	_tend_brick_panes()
	t_sd = _part("sd_panes", t_sd)
	_tend_far_coarse()
	_part("sd_coarse", t_sd)
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
			var t_one := Time.get_ticks_usec()
			_demesh(id)
			_part("st_demesh", t_one)
			done += 1
		elif dist < DEMESH_RANGE:
			_shell_stale.erase(id)
			var t_one := Time.get_ticks_usec()
			_remesh_bricks(id)
			_part("st_remesh", t_one)
			done += 1
		elif _shell_stale.has(id):
			_shell_stale.erase(id)
			var t_one := Time.get_ticks_usec()
			if not _refresh_real_shell(id):
				_free_shell(id)
				_make_shell(id, true)
			_part("st_reshell", t_one)
			done += 1
	_demesh_ms += float(Time.get_ticks_usec() - t0) / 1000.0


## A building drawn in bricks has painted windows too, past the range its rooms
## are drawn in (Docs/DestructionLod.md 3.2): the shell's panes, each only
## where its window still stands in the bricks (`_cell_standing`, as a
## demeshed one's, Structures.md 4.2), hidden inside InteriorGroups'
## range by the shader's `near_hide` -- the rooms dither in as they dither out.
## Before, a building in bricks showed its rooms empty past INTERIOR_RANGE and
## a shot from mid range changed painted windows into drawn furniture.
## Made again once its bricks have changed and it is quiet (_interior_unsure),
## nearest first, one a pass.
var _brick_panes := {}    ## building id -> its pane node, a child of its brick node
var _panes_owed := {}     ## building id -> true: its bricks changed since its panes were made
var brick_panes_built := 0
var brick_panes_ms := 0.0
func _tend_brick_panes() -> void:
	if not _harvest_panes():
		return
	var here := camera.global_position
	var best := -1
	var best_d := INF
	for id in _brick_nodes:
		var cand := registry.get_building(id)
		if cand == null or cand.is_build() or cand.toppled or _toppling.has(id):
			continue
		var have = _brick_panes.get(id)
		if have != null and not is_instance_valid(have):
			_brick_panes.erase(id)
			have = null
		if have != null and not _panes_owed.has(id):
			continue
		if _interior_unsure(id):
			continue
		var d := cand.xform.origin.distance_to(here)
		if d < best_d:
			best_d = d
			best = id
	if best < 0:
		return
	var t0 := Time.get_ticks_usec()
	var b := registry.get_building(best)
	_panes_owed.erase(best)
	# Made on a worker, from a copy of which cells stand: made here, the panes
	# of a big building were 6-15 ms in one tick, half of it handing the mesh to
	# the renderer while some other upload held it (PerfCaps.md 4). The old
	# panes stay up until the new ones are hung.
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	var room_seed := registry.room_seed_of(best)
	var t_pp := Time.get_ticks_usec()
	var layout := TowerRecipe.layout(courses)
	var lattice := RoomManifest.lattice_for(fx, fz, courses)
	var program: Dictionary = (b.recipe.get("program", {}) as Dictionary).duplicate(true)
	t_pp = _part("pn_prep", t_pp)
	var standing := BuildingShell.standing_copy(world, b.chunk,
			BuildingShell.window_rows(courses, layout, lattice))
	_part("pn_copy", t_pp)
	var holder := [null]
	var on_worker := worker_meshes
	var task := WorkerThreadPool.add_task(func() -> void:
		var arrays := BuildingShell.window_arrays(fx, fz, courses, room_seed, layout, lattice,
				{}, program, standing)
		if not arrays.is_empty():
			holder[0] = BuildingShell.window_mesh_of(arrays) if on_worker else (arrays as Variant)
			UploadLedger.note("panes", UploadLedger.verts_of(arrays)),
			true, "brick panes")
	_pane_job = [task, holder, best]
	brick_panes_built += 1
	brick_panes_ms += float(Time.get_ticks_usec() - t0) / 1000.0


var _pane_job: Array = []   ## [task, [mesh], building id] while panes are being made


## A building in bricks far off is drawn as its coarse stand-in -- the live
## bricks' outer surface merged across bricks of a colour, brick outlines
## still drawn from its UV2 (BrickWorld.build_chunk_coarse_mesh, a far
## piece's stand-in) -- instead of its bands, every brick's faces. Looking down
## a street of twelve buildings in bricks the bands were 4.6M triangles and
## 16.7 ms of a 21.7 ms GPU frame; the four past 80 m drawn coarse, 1.7M
## triangles became 140k and the frame 12.7 ms, the picture the same
## (PerfCaps.md 5). Past FAR_COARSE_RANGE, quiet for FAR_COARSE_QUIET_MS; back
## to its bands inside FAR_COARSE_BACK, or the moment a band of it changes. The
## bands stay built underneath, only hidden: what a hit patches is them.
const FAR_COARSE_RANGE := 60.0
const FAR_COARSE_BACK := 50.0
const FAR_COARSE_QUIET_MS := 3000
static var far_coarse_enabled := true
var _far_coarse := {}        ## building id -> its stand-in node (bands hidden)
## building id -> [alive bricks asked at, upload task or -1, [mesh]]: being made.
var _far_coarse_jobs := {}
var far_coarse_built := 0


func _tend_far_coarse() -> void:
	var here := camera.global_position
	# Stand-ins come in: arrays from the world's worker, then the mesh made on
	# one of ours (handed to the renderer here, it would wait as a band did).
	for id in _far_coarse_jobs.keys():
		var job: Array = _far_coarse_jobs[id]
		var b := registry.get_building(id)
		var gone: bool = b == null or not b.is_materialised() or not _brick_nodes.has(id)
		if int(job[1]) >= 0:
			if not WorkerThreadPool.is_task_completed(int(job[1])):
				continue
			WorkerThreadPool.wait_for_task_completion(int(job[1]))
			_far_coarse_jobs.erase(id)
			var mesh: ArrayMesh = (job[2] as Array)[0]
			if mesh != null and not gone and far_coarse_enabled \
					and world.get_alive_block_count(b.chunk) == int(job[0]) \
					and not _bands_building(id) and not _toppling.has(id) \
					and _box_distance(CityPlacer.box_of(b), here) > FAR_COARSE_BACK:
				_far_coarse_show(id, mesh)
			elif mesh != null:
				_retirer.retire(mesh)
			continue
		if gone:
			if b == null or not world.coarse_pending(b.chunk):
				_far_coarse_jobs.erase(id)
			continue
		if not world.coarse_ready(b.chunk):
			if not world.coarse_pending(b.chunk):
				_far_coarse_jobs.erase(id)   # settled by a change to the chunk
			continue
		var arrays: Array = world.take_coarse_mesh(b.chunk)
		if arrays.is_empty():
			_far_coarse_jobs.erase(id)
			continue
		var holder := [null]
		if not worker_meshes:
			# Headless: made here, and shown next pass (worker_meshes).
			var hm := ArrayMesh.new()
			hm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			holder[0] = hm
			job[1] = WorkerThreadPool.add_task(func() -> void: pass, false, "far coarse building")
		else:
			job[1] = WorkerThreadPool.add_task(func() -> void:
				var m := ArrayMesh.new()
				m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				UploadLedger.note("far building", UploadLedger.verts_of(arrays))
				holder[0] = m, false, "far coarse building")
		job[2] = holder
	# Which go coarse, and which come back. At most one asked for a pass.
	var now := Time.get_ticks_msec()
	var asked := false
	for id in _brick_nodes:
		var b := registry.get_building(id)
		if b == null or not b.is_materialised():
			continue
		var dist := _box_distance(CityPlacer.box_of(b), here)
		if _far_coarse.has(id) and not is_instance_valid(_far_coarse[id]):
			_far_coarse.erase(id)   # its node went with its bricks' node
		if _far_coarse.has(id):
			if not far_coarse_enabled or dist < FAR_COARSE_BACK or _toppling.has(id) \
					or b.toppled:
				_far_coarse_drop(id)
			continue
		if asked or not far_coarse_enabled or _far_coarse_jobs.has(id) \
				or dist <= FAR_COARSE_RANGE or now - b.materialised_at < FAR_COARSE_QUIET_MS \
				or _bands_building(id) or _toppling.has(id) or b.toppled \
				or world.coarse_pending(b.chunk):
			continue
		world.coarse_chunk_async(b.chunk)
		_far_coarse_jobs[id] = [world.get_alive_block_count(b.chunk), -1, []]
		asked = true


func _far_coarse_show(id: int, mesh: ArrayMesh) -> void:
	var parent = _brick_nodes.get(id)
	if parent == null or not is_instance_valid(parent):
		_retirer.retire(mesh)
		return
	var node := MeshInstance3D.new()
	node.name = "FarCoarse"
	node.mesh = mesh
	node.material_override = brick_material
	InstanceParams.put(node, &"weather_sway", _sway_of(id))
	InstanceParams.put(node, &"weather_snowcap", 1.0 if _is_tree(id) else 0.0)
	InstanceParams.put(node, &"grain_origin",
			InstanceParams.of(parent as MeshInstance3D, &"grain_origin"))
	node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	node.cast_shadow = (parent as MeshInstance3D).cast_shadow
	(parent as Node3D).add_child(node)
	for band in _brick_bands.get(id, []):
		if is_instance_valid(band):
			(band as Node3D).visible = false
	_far_coarse[id] = node
	far_coarse_built += 1


## Its bands drawn again, and its stand-in gone. Nothing if it has none.
func _far_coarse_drop(id: int) -> void:
	if not _far_coarse.has(id):
		return
	var node = _far_coarse[id]
	_far_coarse.erase(id)
	for band in _brick_bands.get(id, []):
		if is_instance_valid(band):
			(band as Node3D).visible = true
	if node != null and is_instance_valid(node):
		_retirer.retire((node as MeshInstance3D).mesh)
		(node as Node).queue_free()


## Hang the panes a worker has finished. False while one is still being made.
func _harvest_panes() -> bool:
	if _pane_job.is_empty():
		return true
	if not WorkerThreadPool.is_task_completed(int(_pane_job[0])):
		return false
	WorkerThreadPool.wait_for_task_completion(int(_pane_job[0]))
	var id: int = _pane_job[2]
	var made = (_pane_job[1] as Array)[0]
	if made is Array:
		made = BuildingShell.window_mesh_of(made)   # headless: made here (worker_meshes)
	var panes: ArrayMesh = made
	_pane_job = []
	var parent = _brick_nodes.get(id)
	if parent == null or not is_instance_valid(parent):
		return true
	var old = _brick_panes.get(id)
	if old != null and is_instance_valid(old):
		(old as Node).queue_free()
	_brick_panes.erase(id)
	if panes != null:
		var glass := MeshInstance3D.new()
		glass.mesh = panes
		glass.material_override = BuildingShell.window_material()
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glass.set_instance_shader_parameter("near_hide", InteriorGroups.INTERIOR_RANGE)
		(parent as Node3D).add_child(glass)
		_brick_panes[id] = glass
	return true


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
		_drop_groups(id)
		mi.queue_free()
		_brick_nodes.erase(id)
	_brick_meshes.erase(id)
	_brick_index_bytes.erase(id)
	_brick_index_width.erase(id)
	_pending_bricks.erase(id)
	# The bake is the expensive part -- 3.4 MB a building against a few hundred
	# kilobytes for its occupancy and blocks.
	world.drop_chunk_bake(b.chunk)
	# A shell still up here is the one kept through its bands (_bands_done),
	# drawn from the building before it was made bricks -- given back before
	# the bands were done, a building shot from afar went on drawing the wall
	# it had been shot in whole, until something else hit it or the camera
	# came back. Built again from the bricks as they are.
	if _shells.has(id):
		_free_shell(id)
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
	BrickMaterials.set_grain_origin(mi, world, b.chunk)
	add_child(mi)
	_brick_nodes[id] = mi
	if not _pending_bricks.has(id):
		_pending_bricks.append(id)
	_remeshed_back += 1


## Hand the bricks back for buildings nobody is near. Damage is kept.
## Bricks for what the player is aiming at, before the shot.
##
## The first shot at a building still drawn as its shell made it bricks in that
## tick, and the shot showed on it only once its bands were drawn -- 5 to 11
## ticks, and several times that with the editor open: the lag on the first
## hit (--diag firsthit, 2026-09-30). Aimed at for AIM_PROMOTE_TICKS within
## AIM_PROMOTE_RANGE, a shell goes to the front of the promotion queue, its
## bands first in line; and a building aimed at is not trimmed back to a shell
## for AIM_KEEP_MS (_trim_quiet), or it would go and come back with every look.
## Past DEMESH_RANGE a building in bricks has no mesh anyway, so the range is
## inside it.
const AIM_PROMOTE_RANGE := 100.0
const AIM_PROMOTE_TICKS := 6
const AIM_KEEP_MS := 8000
var _aim_target := -1
var _aim_since := 0
var _aimed_at := {}   ## building id -> msec it was last aimed at
## Building id -> true: aimed at, behind its shell -- its bands go first
## (_advance_bands). Not one being shot: going first made the shot show on
## it later -- at 15 ticks, not 9 -- when the bands built before the last hit
## were built again (they are patched now: _bands_done).
var _band_first := {}
var aim_promotions := 0
## Drawn rooms a landing piece crushed furniture in (_crush_drawn).
var crushed_by_wreckage := 0


func _aim_promote() -> void:
	# The far pass looks straight at buildings to check the shell ladder, and
	# a look within AIM_PROMOTE_RANGE made each one bricks under it: no shell
	# left to check (two of its checks failed on this, not on the ladder).
	# The build pass likewise: it stands in front of a creation to check its
	# shell, hands its bricks back ("walk away") and checks the shell again
	# without moving -- and six ticks of looking made it bricks both times. It
	# passed while ten frames were fewer than six ticks, and stopped when the
	# near tier's drawing made frames longer (2026-10-08).
	if _far_mode or _build_mode:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z * AIM_PROMOTE_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to, Layers.WORLD | Layers.STRUCTURE)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var id := _building_for_body(hit.rid) if not hit.is_empty() else -1
	if id < 0:
		_aim_target = -1
		return
	_aimed_at[id] = Time.get_ticks_msec()
	var now := Engine.get_physics_frames()
	if id != _aim_target:
		_aim_target = id
		_aim_since = now
		return
	if now - _aim_since < AIM_PROMOTE_TICKS:
		return
	var b := registry.get_building(id)
	if b == null or b.toppled or _promote_queue.has(id):
		return
	# The storeys round where it is looked at (Docs/Space.md 5.3a): the shot
	# that follows lands within a few metres of the look.
	var want := _storeys_for(id, hit.position, AIM_STOREY_REACH)
	if not _wants_bricks(b, want):
		return
	_queue_promotion(id, want, true)
	_band_first[id] = true
	aim_promotions += 1


## Bricks for what a falling piece is about to land on.
##
## A piece that came down on a building still drawn as its shell made it bricks
## in the tick it landed (_shear_building -> _promote), and the hit showed only
## once the bands were drawn -- the first shot's lag, for a falling building
## instead of a gun. Every few ticks a falling piece near somebody is swept
## PATH_AHEAD_S ahead along its velocity and gravity, and a shell in the way
## goes to the front of the promotion queue, bands first, as one aimed at does
## (_aim_promote). Far from everyone a landing does not promote (FRACTURE_RANGE),
## so neither does this. A few pieces a pass, round the list.
const PATH_AHEAD_S := 1.0
const PATH_MIN_SPEED := 3.0
const PATH_CHECKS_PER_PASS := 12
var path_promotions := 0
var _path_cursor := 0
var _path_box := BoxShape3D.new()


func _path_promote() -> void:
	var n := islands.islands.size()
	if n == 0:
		return
	var space := get_world_3d().direct_space_state
	var g := Gravity.strength() \
			* IslandManager.DEBRIS_GRAVITY
	var t := PATH_AHEAD_S
	var checked := 0
	var looked := 0
	while checked < PATH_CHECKS_PER_PASS and looked < n:
		_path_cursor = (_path_cursor + 1) % n
		looked += 1
		var isl: BrickIsland = islands.islands[_path_cursor]
		if not isl.is_valid() or isl.settled or isl.disposable:
			continue
		var v := isl.body.linear_velocity
		if v.length() < PATH_MIN_SPEED:
			continue
		var box := islands.world_aabb(isl)
		if islands.far_from_everyone(box.get_center()):
			continue
		checked += 1
		var ahead := box.merge(AABB(box.position + v * t + Vector3.DOWN * 0.5 * g * t * t, box.size))
		_path_box.size = ahead.size
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = _path_box
		q.transform = Transform3D(Basis(), ahead.get_center())
		q.collision_mask = Layers.STRUCTURE
		for hit in space.intersect_shape(q, 8):
			var id := _building_for_body(hit.rid)
			if id < 0:
				continue
			var b := registry.get_building(id)
			if b == null or b.toppled or _promote_queue.has(id):
				continue
			# A piece falling inside the building laid a storey at a time that
			# it came from lands on the laid slab under it, not on the storeys
			# under that: the sweep reaches them, the piece never does.
			if b.banded and isl.owner == id:
				continue
			# The storeys the swept box reaches (Docs/Space.md 5.3a).
			var want := _storeys_for(id, ahead.get_center(), ahead.size.y * 0.5)
			if not _wants_bricks(b, want):
				continue
			_queue_promotion(id, want, true)
			_band_first[id] = true
			path_promotions += 1
			return   # one a pass: a promotion is the expensive part


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
		if _pinned(id):
			continue  # an encounter is being fought in it
		if Time.get_ticks_msec() - int(_aimed_at.get(id, -1000000)) < AIM_KEEP_MS:
			continue  # being aimed at (_aim_promote)
		var dist: float = b.xform.origin.distance_to(here)
		if dist < TRIM_RADIUS:
			continue
		if world.fire_burning(b.chunk) > 0:
			continue  # on fire: its heat is only in its bricks
		if Time.get_ticks_msec() - b.materialised_at < TRIM_AFTER_MS:
			continue
		# Not another once this run has had its share: the clock below is
		# looked at AFTER a building goes, and a big one is 5-10 ms by itself,
		# so two in a row was a 10 ms trim.
		if freed > 0 and Time.get_ticks_usec() >= t0 + int(TRIM_START_MS * 1000.0):
			break
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
func _demote(id: int, _dist: float) -> void:
	var _ta := Time.get_ticks_usec()
	var _t_all := _ta
	var _w := [0.0, 0.0, 0.0, 0.0, 0]
	var _gb := registry.get_building(id)
	if _gb != null and _gb.is_materialised():
		_w[4] = world.get_block_count(_gb.chunk)
	# Before dematerialising, which is what takes the chunk id away: the
	# furniture node is keyed on the chunk, not on the building.
	var gone := registry.get_building(id)
	if gone != null and gone.banded:
		# Laid again, it lays what it is asked then, not what it had: every
		# machine has to drop what it had too (DamageLog UNLAY).
		authority.commit(Engine.get_physics_frames(), DamageLog.Kind.UNLAY, id,
				Vector3.ZERO, 0.0)
	_free_rest(id)
	FurnitureMesh.drop(gone.chunk if gone != null else -1, _furniture)
	_drop_groups(id)
	_free_room_body(id)
	_furnished.erase(id)
	registry.dematerialise(id)
	_trim_split.demat += float(Time.get_ticks_usec() - _ta) / 1000.0
	_w[1] = float(Time.get_ticks_usec() - _ta) / 1000.0
	_ta = Time.get_ticks_usec()
	if _brick_cols.has(id):
		(_brick_cols[id] as BuildingCollision).free_bodies()
		_brick_cols.erase(id)
	if _brick_nodes.has(id):
		(_brick_nodes[id] as MeshInstance3D).queue_free()
		_brick_nodes.erase(id)
	_free_frames(id)
	_take_bands(id)
	_band_cursor.erase(id)
	_brick_meshes.erase(id)
	_brick_index_bytes.erase(id)
	_brick_index_width.erase(id)
	_last_hit.erase(id)
	_dirty.erase(id)
	_remesh_queue.erase(id)
	_pending_bricks.erase(id)
	_trim_split.free += float(Time.get_ticks_usec() - _ta) / 1000.0
	_w[2] = float(Time.get_ticks_usec() - _ta) / 1000.0
	_ta = Time.get_ticks_usec()
	# At the detail the distance calls for. This built a FULL shell for every
	# building it trimmed, and everything it trims is by definition past
	# TRIM_RADIUS (90 m) -- so it was paying for near detail on buildings that
	# _stream_shells would have given a coarse one anyway. That was most of the
	# 5.4 ms a trim cost, and the reason the budget only ever allowed one of
	# them per run.
	#
	# And coarse whatever the distance, now: the trim runs from TRIM_RADIUS
	# (70 m), inside SHELL_DETAIL_RANGE, and a detailed shell was 7-13 ms of the
	# same tick as the release. _stream_shells swaps in the detailed one on its
	# own budget, a pass or two later.
	_make_shell(id, true)
	_trim_split.shell += float(Time.get_ticks_usec() - _ta) / 1000.0
	_w[3] = float(Time.get_ticks_usec() - _ta) / 1000.0
	_w[0] = float(Time.get_ticks_usec() - _t_all) / 1000.0
	if float(_w[0]) > float(_demote_worst[0]):
		_demote_worst = _w


## The rooms view (Shift+O; SpacesView): the rooms the finder makes of the
## nearest building in bricks, outlined, sealed or not, with their openings.
## Found again when the camera's nearest building changes, and a second after
## its bricks do.
var _spaces_view: SpacesView
var _spaces_of := -1
var _spaces_alive := -1
var _spaces_ms := 0


func _toggle_spaces_view() -> void:
	if _spaces_view != null:
		_spaces_view.queue_free()
		_spaces_view = null
		print("[city] rooms view off")
		return
	_spaces_view = SpacesView.new()
	add_child(_spaces_view)
	_spaces_of = -1
	print("[city] rooms view on: the nearest building in bricks (walk up to one, or shoot it)")


func _follow_spaces_view() -> void:
	var now := Time.get_ticks_msec()
	if now - _spaces_ms < 1000:
		return
	_spaces_ms = now
	var here := camera.global_position
	var best: BuildingRegistry.Building = null
	var best_d := INF
	for id in _near_buildings(here, 120.0):
		var b := registry.get_building(id)
		if b == null or b.is_build() or not b.is_materialised():
			continue
		var d := here.distance_to(b.xform * Vector3(b.recipe.footprint_x * STUD * 0.5, 0.0,
				b.recipe.footprint_z * STUD * 0.5))
		if d < best_d:
			best = b
			best_d = d
	if best == null:
		if _spaces_of >= 0:
			_spaces_view.clear()
			_spaces_of = -1
		return
	var alive := world.get_alive_block_count(best.chunk)
	if best.id == _spaces_of and alive == _spaces_alive:
		return
	_spaces_of = best.id
	_spaces_alive = alive
	_spaces_view.show_building(world, best, registry.room_seed_of(best.id))
	print("[city] rooms of building %d: %s" % [best.id, _spaces_view.report()])


func _process(delta: float) -> void:
	if _physics_view != null:
		_physics_view.tick(_brick_cols, islands)
	# Frozen (F10), the detail square and the coarse tier's hiding hold still
	# for where the camera WAS, as in the heightfield test.
	if _terrain_streamer != null and not _lod_frozen:
		var lod_at := camera.global_position
		_terrain_streamer.follow(Vector2(lod_at.x, lod_at.z))
		_terrain_coarse.cover(_terrain_streamer, false)
		_terrain_coarse.relod(lod_at, false)
	# How far the camera is zoomed in (a scope, any narrowed view): the
	# unzoomed horizontal field over the camera's, as tangents. Detail goes by
	# distance over that -- the near tier's and the shaders' (lod_zoom).
	var aspect := get_viewport().get_visible_rect().size.aspect()
	var zoom_in := maxf(tan(deg_to_rad(PlayerView.hfov) * 0.5)
			/ maxf(tan(deg_to_rad(camera.fov) * 0.5) * aspect, 1e-4), 1.0)
	zoom_in = minf(zoom_in, 6.0)   # a scripted shot through a pinhole is not a scope
	RenderingServer.global_shader_parameter_set(&"lod_zoom", 1.0 / zoom_in)
	if brick_near != null:
		# Every upload on a worker: the bands', the pieces', the shadow proxies'
		# (BuildingShell.build_mesh makes its ArrayMesh there too), the windows'
		# (shells' glass, and the panes of a building in bricks).
		brick_near.uploads = _band_jobs.size() + islands.mesh_jobs() + _shadow_jobs.size() \
				+ _glass_jobs.size() + (0 if _pane_job.is_empty() else 1)
		brick_near.step(camera.global_position, zoom_in, -camera.global_basis.z)
	_tend_grid_light()
	if _spaces_view != null:
		_follow_spaces_view()
	if _sea != null:
		_sea.follow(camera.global_position, delta)
	_update_reticle()
	var ridden := _riding()
	if ridden != null:
		ridden.rodeo.planting = InputMap.has_action(&"melee") and Input.is_action_pressed(&"melee")
	_hop_in()
	_update_live_prof(delta)
	if _view_owed or (DebugView.active() and Engine.get_process_frames() - _view_frame >= 2):
		_view_sweep()
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

## The HUD's counts, each a walk of something big (every building, every
## room, every island): together 7 ms, six times a second. One of them is
## brought up to date per refresh, in turn, so each is under a second old
## and no refresh walks them all; none while the stats are hidden (F1).
const _HUD_PARTS := ["mem", "rep", "isl", "rooms", "groups"]
var _hud_cache := {}
var _hud_turn := 0


func _hud_part(key: String) -> Variant:
	match key:
		"mem":
			return world.get_memory_report()
		"rep":
			return registry.report()
		"isl":
			return islands.report()
		"rooms":
			return registry.room_report()
		_:
			return _groups_hud_line()


func _update_hud() -> void:
	if stats_label == null or not stats_label.visible:
		return
	# Shown or hidden before the city is built (visibility_changed).
	if registry == null or islands == null or world == null:
		return
	if _hud_cache.size() < _HUD_PARTS.size():
		for key in _HUD_PARTS:
			_hud_cache[key] = _hud_part(key)
	else:
		var key: String = _HUD_PARTS[_hud_turn % _HUD_PARTS.size()]
		_hud_cache[key] = _hud_part(key)
		_hud_turn += 1
	var mem: Dictionary = _hud_cache.mem
	var rep: Dictionary = _hud_cache.rep
	var isl: Dictionary = _hud_cache.isl
	var rooms: Dictionary = _hud_cache.rooms
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
		"rooms         %d  (%d with a diff, %d piece(s) laid as bricks)" % [
			rooms.rooms, rooms.changed, rooms.laid],
		_hud_cache.groups,
		_caps_hud_line(),
		_physics_view.hud_line() if _physics_view != null else "physics view  off (shift+G)",
		_view_hud_line(),
		"",
		("%s  %d/%d%s   %s (SPACE SPACE)" % [_gun.gun.gun_name, _gun.ammo, _gun.mag_size(),
				"  reloading" if _gun.is_reloading() else "",
				_mode_word()]) if _gun_armed and _gun.gun != null
			else "blast %.1f m (wheel)   %s (SPACE SPACE)" % [
				_blast_radius, _mode_word()],
		"1 gun · 2 blast · T next gun · R reload · V on foot · K soldier · U squad · Y enemy mech · F mech order" + (" · H disasters (shift: end)" if disasters != null else ""),
		"LMB fire · X big blast · P place a saved build · WASD move · shift fast · G grids (shift: physics) · B bevel · J overlap"
			+ "\nF1 stats · F2 profiler · F3 reset worst · F4 AI · F5 save · F9 load · F10 terrain dev menu · F11 terrain edit · N respawn\n7 structure solid/see-through/hidden · 8 interior pieces · 9 items  (what is hidden is still there)"
			+ ("" if respawn_buildings else "\nRESPAWN OFF (N) — buildings keep their bricks once promoted"),
	])


## The debris caps against what holds them (IslandManager.cap_counts).
func _caps_hud_line() -> String:
	var c := islands.cap_counts()
	return "caps          settled small %d/%d · large %d/%d · total %d/%d · %d falling" % [
		c.small, islands.small_live_max, c.large, islands.large_live_max,
		c.small + c.large, islands.total_live_max, c.falling]


## One of the view switches (DebugView): 7, 8 and 9 in play.
func _view_cycle(kind: int) -> void:
	DebugView.cycle(kind)
	_view_owed = true
	print("[city] view: %s" % DebugView.line())
	_update_hud()


## Make everything the city draws match the view switches.
##
## Structure is what draws under the nodes that ARE the city's bricks: each
## building's brick mesh and its bands, a build's frames, the shells, the far
## boxes, the instanced sets, and everything of the pieces (IslandManager:
## bodies, bands, stand-ins, crumbs). Interior pieces and items hang under the
## same nodes and are told apart by what they were tagged when made. Loot is
## items wherever it is.
##
## Every other frame while a switch is thrown, so a piece cut loose or a room
## drawn a moment ago is in the same view as the rest; once more when the last
## switch goes back, to put everything as it was; and then not at all.
func _view_sweep() -> void:
	_view_owed = false
	_view_frame = Engine.get_process_frames()
	DebugView.seen = [[0, 0], [0, 0], [0, 0]]
	DebugView.aim(get_viewport().get_camera_3d())
	if camera != null:
		DebugView.aim(camera)
	if not DebugView.active():
		DebugView.restore(get_tree())
		return
	for id in _brick_nodes:
		DebugView.apply_tree(_brick_nodes[id])
	for id in _frame_nodes:
		for node in (_frame_nodes[id] as Array):
			DebugView.apply_tree(node)
	for id in _shells:
		DebugView.apply_tree(_shells[id])
	DebugView.apply_tree(_far)
	for key in _inst_sets:
		DebugView.apply_tree(_inst_sets[key])
	DebugView.apply_tree(islands)
	for node in get_tree().get_nodes_in_group(ImpostorItems.GROUP):
		DebugView.apply_tree(node, DebugView.Kind.ITEMS)
	# Loot lying about: a pickup is a node of its own, wherever it was put.
	# Looked for now and then -- it is a walk of the whole scene.
	if Engine.get_process_frames() % 30 < 2 or _view_pickups.is_empty():
		_view_pickups = find_children("*", "WorldGunPickup", true, false)
	for node in _view_pickups:
		if is_instance_valid(node):
			DebugView.apply_tree(node, DebugView.Kind.ITEMS)


var _view_pickups: Array = []


func _view_hud_line() -> String:
	if not DebugView.active():
		return "view          everything shown  (7 structure · 8 interior pieces · 9 items)"
	var s: Array = DebugView.seen
	return "view          %s\n              drawn now: %d structure mesh(es), %d interior box(es) in %d drawing(s), %d item(s) in %d" % [
			DebugView.line(), int(s[0][1]), int(s[1][1]), int(s[1][0]), int(s[2][1]), int(s[2][0])]


func _groups_hud_line() -> String:
	var gr: Dictionary = interior_groups.report()
	return "interiors     %d storey group(s) in %d building(s): %d piece box(es), %d item box(es); %d piece(s) of wreckage drawn" % [
			gr.groups, gr.buildings, gr.piece_boxes, gr.item_boxes, gr.piece_drawings]


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
	lines.append("resident buildings %d · interior pieces laid as bricks %d" % [
			_materialised.size(), int(registry.room_report().laid)])
	# The census in one line rather than the full sentence _collision_report
	# writes: this label is 430 pixels wide.
	var boxes := 0
	for bid in _brick_cols:
		boxes += (_brick_cols[bid] as BuildingCollision).shape_count()
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


# --- keys (Options > Controls, and > Developer) ----------------------------------

## The player's actions the city handles itself, and the key each stands for in
## _unhandled_input's match (its arms keep the default keys' names).
const PLAYER_KEYS := {&"use_vehicle": KEY_M}
## Developer mode's actions (project.godot's dev_*, rebound on Options >
## Developer), by the key each stands for.
const DEV_KEYS := {
	&"dev_big_blast": KEY_X, &"dev_disasters": KEY_H, &"dev_stats": KEY_F1, &"dev_gun_out": KEY_1,
	&"dev_gun_away": KEY_2, &"dev_spawn_soldier": KEY_K, &"dev_spawn_squad": KEY_U,
	&"dev_spawn_enemy_mech": KEY_Y, &"dev_spawn_tank": KEY_Z, &"dev_play_on_foot": KEY_V,
	&"dev_gun_class": KEY_T, &"dev_gun_reload": KEY_R, &"dev_ai_overlay": KEY_F4, &"dev_save": KEY_F5,
	&"dev_load": KEY_F9, &"dev_view_structure": KEY_7, &"dev_view_interior": KEY_8,
	&"dev_view_items": KEY_9, &"dev_terrain_menu": KEY_F10, &"dev_terrain_edit": KEY_F11,
	&"dev_seams": KEY_L, &"dev_bevel": KEY_B, &"dev_finish": KEY_I, &"dev_overlap": KEY_J,
	&"dev_slow_motion": KEY_O, &"dev_profiler": KEY_F2, &"dev_worst_frame": KEY_F3,
	&"dev_brick_shells": KEY_N, &"dev_placer": KEY_P, &"dev_grids": KEY_G,
}


## The key `event` stands for, by the action it is bound to (so a rebinding
## counts), or KEY_NONE. Modifiers are ignored: Shift+Z is still the tank key,
## and its arm reads the Shift.
static func _key_of(event: InputEvent) -> Key:
	for a in PLAYER_KEYS:
		if event.is_action_pressed(a):
			return PLAYER_KEYS[a]
	# The developer keys only in developer mode (DevMode, Options > Gameplay).
	if not DevMode.on:
		return KEY_NONE
	for a in DEV_KEYS:
		if event.is_action_pressed(a):
			return DEV_KEYS[a]
	return KEY_NONE


func _unhandled_input(event: InputEvent) -> void:
	# Terrain edit mode: everything but these is the editor's.
	if _edit_mode:
		if event is InputEventKey and event.pressed and not event.echo:
			match _key_of(event):
				KEY_F11:
					_toggle_terrain_edit()
				KEY_F10:
					_toggle_terrain_dev_menu()
				KEY_F1:
					stats_label.visible = not stats_label.visible
		return
	# Rodeo (Docs/AIRoster.md 4.5): on foot, melee (E) climbs an enemy mech in reach
	# instead of striking (_melee_context); on its back, E held plants the charge and
	# jump gets off.
	if _player.is_possessing() and _player_pawn != null and is_instance_valid(_player_pawn):
		if _riding() != null and event.is_action_pressed(&"jump"):
			_riding().rodeo.drop("jumped")
			return
		if _aboard() != null and event.is_action_pressed(&"jump"):
			_aboard().rodeo.get_off(_player_pawn, "jumped")
			return
	# On foot the buttons are the player's own (rebindable input actions,
	# PlayerController): firing, aiming and reloading go through the pawn.
	if event is InputEventMouseButton and (_player.is_possessing() or _pilot.is_piloting()):
		return
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
				if not _player.is_possessing():
					_set_blast_radius(_blast_radius * BLAST_STEP)
				return
			MOUSE_BUTTON_WHEEL_DOWN:
				if not _player.is_possessing():
					_set_blast_radius(_blast_radius / BLAST_STEP)
				return
	# The mech's one button (AI.md 2.1): on foot, F -- a tap toggles FOLLOW and
	# HOLD, held while aiming sends it to attack where the crosshair is.
	if event is InputEventKey and not event.echo and event.is_action(&"mech_order") \
			and _mech_cmd != null and _player.is_possessing():
		if event.pressed:
			_mech_cmd.press(ai_services.now())
		else:
			var o := _mech_cmd.release(ai_services.now(), _aim_point())
			print("[city] mech order: %s" % MechBrain.Order.keys()[o])
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# On foot by the player's own mech of parts: Ctrl B puts a brick on the stud under the
	# crosshair, Ctrl Shift B takes it off, Ctrl Alt B the next colour (stage 11: dressing).
	if event.ctrl_pressed and event.keycode == KEY_B and _player.is_possessing() and _mech != null \
			and is_instance_valid(_mech) and not PartDressing.parts_of(_mech).is_empty():
		if event.alt_pressed:
			_dress_colour = (_dress_colour + 1) % PartDressing.COLOURS
			print("[city] dressing colour %d" % _dress_colour)
		else:
			print("[city] dressing: %s" % _dress_at_crosshair(event.shift_pressed))
		return
	# Ctrl T: the figures made in the asset workshop, in turn, walking a circle ahead of the
	# camera; Ctrl Shift T swaps a limb of the last one for another that fits (stage 12).
	if event.ctrl_pressed and event.keycode == KEY_T:
		if event.alt_pressed:
			_open_character_builder()
		else:
			print("[city] %s" % (_swap_figure_limb() if event.shift_pressed else _spawn_figure()))
		return
	# In the mech, 1 and 2 are its pods (MechPods).
	if _pilot.is_piloting() and _mech_pods != null and _pilot.mech == _mech_pods.mech:
		for slot in MechPods.SLOTS:
			if event.is_action_pressed(StringName("slot_%d" % (slot + 1))):
				if not _mech_pods.use(slot):
					var pod: PodGenerator.Result = _mech_pods.slots[slot]
					print("[city] pod %d: %s" % [slot + 1, "empty" if pod == null else
							("passive" if not pod.is_active() else "cooling, %.1f s" % _mech_pods.cool[slot])])
				return
	match _key_of(event):
		KEY_X:
			_fire(BIG_BLAST)
		KEY_H:
			if disasters != null:
				disasters.on_key(event.shift_pressed)
		KEY_F1:
			stats_label.visible = not stats_label.visible
		KEY_1:
			# On foot 1 is the first gun slot (slot_1): the free camera's gun only.
			if _player.is_possessing():
				return
			_arm_gun()
		KEY_2:
			if _player.is_possessing():
				return
			_gun_armed = false
			_gun.set_trigger(false)
			if _gun.gun != null:
				_gun.gun.visible = false
		KEY_K:
			var ahead := camera.global_position - camera.global_transform.basis.z * 20.0
			_spawn_soldier(ai_nav.snap(_on_ground(ahead)))
		KEY_U:
			var ahead := camera.global_position - camera.global_transform.basis.z * 30.0
			_spawn_squad(_on_ground(ahead))
		KEY_Y:
			var ahead := camera.global_position - camera.global_transform.basis.z * 40.0
			var design: PartDesign = null
			if event.ctrl_pressed:
				# Ctrl Y: the mechs made in the asset workshop, in turn.
				var made := MechAssembler.designs(MechAssembler.catalog(true))
				if made.is_empty():
					print("[city] no mech saved in the asset workshop yet")
					return
				var ids := made.keys()
				ids.sort()
				_mech_design = (_mech_design + 1) % ids.size()
				design = made[ids[_mech_design]]
			_spawn_enemy_mech(mech_nav.snap(_on_ground(ahead)), camera.global_rotation.y + PI,
					"medium_gunner", design)
		KEY_M:
			if _vehicle_pilot.is_driving():
				_leave_vehicle()
			elif _pilot.is_piloting():
				_leave_mech()
			elif _aboard() != null:
				_aboard().rodeo.get_off(_player_pawn, "jumped")
			elif _vehicle_at_side() != null:
				_use_vehicle(_vehicle_at_side())
			else:
				_board_mech()
		KEY_Z:
			var ahead := camera.global_position - camera.global_transform.basis.z * 30.0
			var truck_nav = ai_services.vehicle_nav(&"truck")
			if event.alt_pressed and event.shift_pressed:
				_spawn_truck(ai_services.vehicle_nav(&"apc").snap(_on_ground(ahead)), camera.global_rotation.y, 0,
						[] as Array[StringName], &"apc")
			elif event.alt_pressed:
				# An enemy APC from further off with a squad inside: it stops at
				# contact, lets them out in its lee and covers them.
				var far := camera.global_position - camera.global_transform.basis.z * 80.0
				var apc := _spawn_truck(ai_services.vehicle_nav(&"apc").snap(_on_ground(far)),
						camera.global_rotation.y + PI, 1,
						[&"rifleman", &"rifleman", &"rifleman", &"rifleman"] as Array[StringName], &"apc")
				apc.send(_player_pawn.feet() if _player_pawn != null and is_instance_valid(_player_pawn)
						else _on_ground(camera.global_position))
			elif event.ctrl_pressed and event.shift_pressed:
				# From further off, coming for the player with a squad in the back.
				var far := camera.global_position - camera.global_transform.basis.z * 60.0
				var truck := _spawn_truck(truck_nav.snap(_on_ground(far)), camera.global_rotation.y + PI, 1,
						[&"rifleman", &"rifleman", &"rifleman", &"rifleman"] as Array[StringName])
				truck.send(_player_pawn.feet() if _player_pawn != null and is_instance_valid(_player_pawn)
						else _on_ground(camera.global_position))
			elif event.ctrl_pressed:
				_spawn_truck(truck_nav.snap(_on_ground(ahead)), camera.global_rotation.y, 0, [] as Array[StringName])
			elif event.shift_pressed:
				_spawn_tank(ai_nav.snap(_on_ground(ahead)), camera.global_rotation.y, 0, false)
			else:
				_spawn_enemy_tank(ai_nav.snap(_on_ground(ahead)), camera.global_rotation.y + PI)
		KEY_V:
			if _pilot.is_piloting() or _vehicle_pilot.is_driving():
				return
			if _player.is_possessing():
				_leave_pawn()
			else:
				_enter_pawn(camera.global_position - Vector3.UP * Pawn.EYE_HEIGHT)
		KEY_T:
			# The classes, then each gun made in the asset workshop.
			var made := AssetGuns.ids()
			_gun_class = (_gun_class + 1) % (GUN_CLASSES.size() + made.size())
			if _gun_class < GUN_CLASSES.size():
				_equip_gun(GUN_CLASSES[_gun_class], _combat_rng.randi())
			else:
				_equip_asset_gun(made[_gun_class - GUN_CLASSES.size()], _combat_rng.randi())
			_gun_armed = true
		KEY_R:
			if _gun_armed and not _player.is_possessing():
				_gun.reload()
		KEY_F4:
			_ai_label.visible = not _ai_label.visible
			_update_ai_label()
		KEY_F5:
			save_checkpoint()
		KEY_7:
			_view_cycle(DebugView.Kind.STRUCTURE)
		KEY_8:
			_view_cycle(DebugView.Kind.INTERIOR)
		KEY_9:
			_view_cycle(DebugView.Kind.ITEMS)
		KEY_F9:
			load_checkpoint()
		KEY_F10:
			_toggle_terrain_dev_menu()
		KEY_F11:
			_toggle_terrain_edit()
		KEY_L:
			if event.shift_pressed:
				# What drew each brick pixel (brick.gdshader tier_debug).
				var on := not bool(_shader_toggles.get("tier_debug", false))
				_shader_toggles["tier_debug"] = on
				brick_material.set_shader_parameter("tier_debug", on)
				print("[city] tier debug: %s" % ("ON" if on else "OFF"))
			else:
				print("[city] seams: %s" % ("ON" if _toggle_shader("seams_enabled") else "OFF"))
		KEY_B:
			# Both halves of the bevel: the shaded one, and the real one near
			# the camera (BrickNear), so the key shows the wall with and
			# without. Shift+B is the near tier alone.
			if not event.shift_pressed:
				_toggle_shader("chamfer_enabled")
			BrickNear.enabled = not BrickNear.enabled if event.shift_pressed \
					else bool(_shader_toggles["chamfer_enabled"])
			print("[city] chamfered edges: shaded %s, built near the camera %s (%.0f m)" % [
					"ON" if _shader_toggles["chamfer_enabled"] else "OFF",
					"ON" if BrickNear.enabled else "OFF", BrickNear.radius])
		KEY_I:
			# Printed on glass / smooth PEI / textured PEI, or injection
			# moulded (BrickMaterials.set_look).
			print("[city] finish: %s" % BrickMaterials.cycle_look())
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
		KEY_O when event.shift_pressed:
			_toggle_spaces_view()
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
			_placer.toggle(_build_path if _build_path != "" else BuildRecipe.QUICK_SAVE)
		KEY_G:
			if event.shift_pressed:
				_toggle_physics_view()
				return
			_show_grids = not _show_grids
			if _grid_view != null:
				_grid_view.visible = _show_grids
			if _show_grids:
				_draw_grids()


## Shift+G: the physics view on or off (PhysicsView).
func _toggle_physics_view() -> void:
	if _physics_view == null:
		_physics_view = PhysicsView.new()
		add_child(_physics_view)
	_physics_view.visible = not _physics_view.visible
	if _physics_view.visible:
		_physics_view.redraw(_brick_cols, islands)
	print("[city] physics view %s" % ("ON" if _physics_view.visible else "off"))
	_update_hud()


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


## Save the area exactly as it is -- the log, every piece where it is and how it
## is moving, what is asleep, what is queued -- to CHECKPOINT_PATH.
func save_checkpoint() -> bool:
	# The stud's strength with it: the log is what happened at THAT strength,
	# and replayed at another the solves in it come out differently.
	# Hits still queued are [point, radius, ...] with the point in the world:
	# in the body's frame in the save, as every other position (WorldFrame).
	var queued := []
	for h in _damage_queue:
		var row: Array = (h as Array).duplicate()
		row[0] = WorldFrame.to_body(row[0])
		queued.append(row)
	var scene := {"damage": queued, "dirty": Array(_dirty),
			"camera": WorldFrame.xform_to_body(camera.global_transform),
			"placed": _placed_to_body(),
			"stud_times": BrickStrength.times}
	var bytes := AreaSnapshot.capture(authority.commands, islands, scene).to_bytes()
	var f := FileAccess.open(CHECKPOINT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[city] checkpoint: cannot write %s" % CHECKPOINT_PATH)
		return false
	f.store_buffer(bytes)
	f.close()
	print("[city] checkpoint saved: %d command(s), %d piece(s), %d asleep, %d KB" % [
		authority.commands.size(), islands.islands.size(), islands.dormant.size(),
		int(bytes.size() / 1024.0)])
	return true


## Every build put into the city after the city was built -- `--build`, or P --
## in the order it was registered: {id, recipe (BuildRecipe.to_dict), xform,
## grounded}. A checkpoint carries them. The scene a load rebuilds is the city's
## own buildings and nothing else, so without this a placed build was gone after
## F9, and every command in the log that named it went nowhere.
var _placed: Array[Dictionary] = []
## This scene was built from a checkpoint.
var _checkpoint_restored := false


func _note_placed(id: int, grounded: bool) -> void:
	var b := registry.get_building(id)
	if b == null or not b.is_build():
		return
	_placed.append({"id": id, "recipe": b.build.to_dict(), "xform": b.xform,
			"grounded": grounded})


## The placed builds as a save carries them: in the body's frame (WorldFrame).
func _placed_to_body() -> Array:
	var out := []
	for d in _placed:
		var row: Dictionary = d.duplicate(true)
		row["xform"] = WorldFrame.xform_to_body(d["xform"])
		out.append(row)
	return out


## A placed build from a checkpoint, put back as it was placed: registered (so
## it has the id the log knows it by), its pad cut again if it stood on the
## ground, indexed and shelled.
func _replace_build(d: Dictionary) -> void:
	var recipe := BuildRecipe.from_dict(d.get("recipe", {}))
	if recipe.is_empty():
		return
	var id := registry.register_build(recipe,
			WorldFrame.xform_from_body(d.get("xform", Transform3D())))
	if id < 0:
		return
	if id != int(d.get("id", -1)):
		push_warning("[city] checkpoint: a placed build came back as building %d, was %d -- the city under it is not the one that was saved"
				% [id, int(d.get("id", -1))])
	var grounded: bool = bool(d.get("grounded", false)) and _terrain_mode
	if grounded:
		_ground_building(id)
	_index_building(id)
	_make_shell(id)
	_note_placed(id, grounded)


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
	_checkpoint_restored = true
	# At the stud strength it was saved at (save_checkpoint), in memory: the
	# setting in Options is not touched, and moving it again takes over.
	var saved_times := float(snap.scene.get("stud_times", BrickStrength.times))
	if not is_equal_approx(saved_times, BrickStrength.times):
		print("[city] checkpoint: saved at stud strength x%.1f, the setting is x%.1f -- loaded at x%.1f" % [
				saved_times, BrickStrength.times, saved_times])
		BrickStrength.times = saved_times
	_stud_times = BrickStrength.times
	# The builds placed after the city was built, first and in order: the log
	# names a building by its id, and theirs come after the city's own.
	for d in snap.scene.get("placed", []):
		_replace_build(d)
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
			world.set_tension_per_stud(chunk, BrickStrength.tension())
			if not toppling.has(id):
				shown.append(id)
		var cs := b.chunks()
		return cs[frame] if frame < cs.size() else -1
	var on_toppled := func(id: int) -> void:
		_free_shell(id)
		_drop_groups(id)
		registry.hand_over(id)
	# Laid a storey at a time on the host, laid the same here (Docs/Space.md 5.3a).
	var on_laid := func(id: int) -> void:
		var lb := registry.get_building(id)
		if lb != null and lb.is_materialised():
			world.set_tension_per_stud(lb.chunk, BrickStrength.tension())
			if not toppling.has(id) and not shown.has(id):
				shown.append(id)
	var same := func(id: int) -> int: return id
	var hooks := func(rep: StructureReplayer) -> void:
		_storey_hooks(rep, registry, same, on_laid)
	var report := snap.restore(world, resolve, islands, on_toppled, hooks)
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
		var row: Array = (h as Array).duplicate()
		row[0] = WorldFrame.from_body(row[0])
		_damage_queue.append(row)
	for id in scene.get("dirty", []):
		_mark_dirty(int(id))
	if scene.has("camera"):
		camera.global_transform = WorldFrame.xform_from_body(scene.camera)
	print("[city] checkpoint loaded in %d ms, %d placed build(s): %s" % [
		Time.get_ticks_msec() - t0, _placed.size(), report])
	return report


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
		# A far shell is drawing only (_make_shell): no body, so the recipe
		# is what a shot hits.
		if b.toppled or b.is_materialised() or _shell_bodies.has(b.id):
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
	_note_placed(id, false)
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


# ---------------------------------------------------------------------------
# What interiors cost, per room against per building
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# The interiors gate
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# The dormant gate
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# The fixture gate
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# The placed-creation gate
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# The walk gate
# ---------------------------------------------------------------------------

var _gate_pass := 0
var _gate_fail := 0


# ---------------------------------------------------------------------------

func _build_scenery() -> void:
	# The shared light (Docs/Lighting.md): sky, ambient, AgX, the sun's size.
	# A raking sun in terrain mode: at 50 degrees nothing on the ground is in
	# shadow, because the steepest slope the field makes is 42, and the baked
	# shadow is a no-op that reads as flat lighting (Docs/Terrain.md §19.7).
	var rig := LightRig.new()
	rig.build_day(self, Vector3(-30 if _terrain_mode else -50, -35, 0), 1.1, 0.6)
	_setup_sun_shadows(rig.sun)
	_sun = rig.sun
	# Clouds and their shadows (Docs/Lighting.md 2b).
	clouds = CloudLayer.for_city(rig, self)

	if not _terrain_mode:
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
		WeatherFx.register_tint(gmat)   # white under snow, dark when wet
		ground.add_child(gmesh)
		add_child(ground)
		_ground_plane = ground

	brick_material = ShaderMaterial.new()
	brick_material.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(brick_material)
	WeatherFx.register(brick_material)
	for key in _shader_toggles:
		brick_material.set_shader_parameter(key, _shader_toggles[key])
	grid_light.use_layer = false
	grid_light.bind(brick_material)
	grid_light.bind(BrickNear.grid_stud_material())

	camera = DebugCamera.new()
	camera.name = "DebugCamera"
	# Every scripted pass drives the camera itself. Leaving the debug camera
	# captured let it keep applying its own movement and mouse-look on top,
	# which is why the reach probe reported misses at 40 m.
	camera.capture_mouse = not (_shot_mode or _stress_mode or _reach_mode or _far_mode or _tree_mode or _lod_mode
			or _walk_mode or _build_mode or _fixture_mode or _dormant_mode
			or _chamfer_mode
			or _windows_mode or _light_mode)
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
	# The AI overlay, beside F1's stats, off until F4 (AIPlan P2).
	_ai_label = Label.new()
	_ai_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_ai_label.position = Vector2(14, -250)
	_ai_label.add_theme_font_override("font", ThemeDB.fallback_font)
	_ai_label.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0))
	_ai_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_ai_label.add_theme_constant_override("outline_size", 4)
	_ai_label.visible = false
	layer.add_child(_ai_label)
	stats_label = Label.new()
	stats_label.position = Vector2(14, 12)
	stats_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	stats_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	stats_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(stats_label)
	# Not refreshed while hidden (_update_hud), so brought up to date the
	# moment it shows, whoever shows it (F1, the menu, a pass ending).
	stats_label.visibility_changed.connect(func() -> void:
		_hud_cache.clear()
		_update_hud())

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
