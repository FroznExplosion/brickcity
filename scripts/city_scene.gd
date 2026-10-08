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
## The city on the terrain field rather than the flat plane (`--terrain`), set in
## a scene so it can be opened and played.
@export var terrain_ground := false
## The combat arena (WaveDirector, scenes/combat_arena.tscn): the player's pawn
## and waves of soldiers in and round one building. `--arena` does the same.
@export var combat_arena := false
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
const BAND_THREAD_VERTS := 4000
## Bands being uploaded: [building id, band, task id, [mesh], arrays, pass].
var _band_jobs: Array = []
var _band_verts_now := 0
## A mesh with nothing in it, to ask the renderer something cheap. See
## _physics_process.
var _flush_mesh := ArrayMesh.new()
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
var _promote_queue: Array[int] = []
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
var _many_target: Pawn
var _many := {"soldiers": 0, "flyers": 0, "animals": 0, "hunters": 0}
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
## On foot it is an FPS: the gun in the hands, the view's feel, its HUD
## (PlayerView, PlayerHud); the debug stats and blast reticle are put away.
var _view: PlayerView
var _fps_hud: PlayerHud
var _stats_were_visible := false
## Hitmarkers and numbers outside the arena, which has its own.
var _feedback: CombatFeedback
## M boards a mech (spawning one ahead of the camera if there is none) and M
## again climbs out; the mech stays where it was parked.
var _pilot := MechPilot.new()
var _mech: Mech
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
var _chunk_owner := {}
## Mechs with no brain and no pilot (the --mechfall gate's).
var _loose_mechs: Array[Mech] = []
var _mech_mode := false
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
var _nav_mode := false
## Fights in progress: their buildings are held materialised (R3).
var _encounters: Array[Encounter] = []
## What every agent shares (AIServices): built from this city's own AI world,
## nav and scheduler; an agent's missed rounds go through the authority.
var ai_services: AIServices
var soldiers: Array[Soldier] = []
## Squads (AIPlan P6): U spawns one; the --squad gate clears a room with one.
var squads: Array[Squad] = []
## The player's callouts and aggro meter, made the first time a pawn is entered.
var _callout_hud: CalloutHud
var _aggro_layer: CanvasLayer
var _aggro_meter: AggroMeter
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
var arena: WaveDirector
var _wreck_mode := false
var _jam_mode := false
var _drawn_mode := false
var _groups_mode := false
var _squad_mode := false
var _mechfall_mode := false
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
	# The scene's settings first, the command line over the top of them.
	_big = big_shapes or "--big" in args
	_city_size = maxi(building_count, 1)
	_chamfer_mode = "--chamfer" in args
	_checkpoint_mode = "--checkpoint" in args
	_gun_mode = "--gun" in args
	_play_mode = "--play" in args
	_mech_mode = "--mech" in args
	_no_ai = "--no-ai" in args
	_nav_mode = "--nav" in args
	_soldier_mode = "--soldier" in args
	_arena_mode = combat_arena or "--arena" in args
	_wreck_mode = "--wreck" in args
	_jam_mode = "--jam" in args
	_drawn_mode = "--drawn" in args
	# `--rooms` was the gate of the interior drawing this replaced, and is the
	# name other docs and habits still use for "the interiors gate".
	_groups_mode = "--groups" in args or "--rooms" in args
	_view_mode = "--view" in args
	DebugView.reset()
	_breaklag_mode = "--breaklag" in args
	_squad_mode = "--squad" in args
	_mechfall_mode = "--mechfall" in args
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
	# A recipe tower's pieces break along its storeys (IslandManager._floor_line).
	islands.storey_plates = func(id: int) -> int:
		var ob := registry.get_building(id)
		return TowerRecipe.STOREY_PLATES if ob != null and not ob.is_build() else 0
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
	mech_nav = MechBrain.mech_nav(ai_world)
	# Whatever changes where a figure can walk changes where a mech can.
	ai_nav.nav_changed.connect(mech_nav.invalidate_box)
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
	# One of the passes below, unless none of them is asked for (the `else` at
	# the end of the chain).
	_scripted = true
	if _lod_mode:
		_run_lod_pass()
	elif _reach_mode:
		_run_reach_pass()
	elif _far_mode:
		_run_far_pass()
	elif _tree_mode:
		_run_tree_pass()
	elif _walk_mode:
		_run_walk_pass()
	elif _build_mode:
		_run_build_pass()
	elif _fixture_mode:
		_run_fixture_pass()
	elif _dormant_mode:
		_run_dormant_pass()
	elif _windows_mode:
		_run_windows_pass()
	elif _chamfer_mode:
		_run_chamfer_pass()
	elif _checkpoint_mode:
		_run_checkpoint_pass()
	elif _gun_mode:
		_run_gun_pass()
	elif _play_mode:
		_run_play_pass()
	elif _mech_mode:
		_run_mech_pass()
	elif _nav_mode:
		_run_nav_pass()
	elif _soldier_mode:
		_run_soldier_pass()
	elif _breaklag_mode:
		_run_breaklag_pass()
	elif _wreck_mode:
		_run_wreck_pass()
	elif _jam_mode:
		_run_jam_pass()
	elif _drawn_mode:
		_run_drawn_pass()
	elif _groups_mode:
		_run_groups_pass()
	elif _view_mode:
		_run_view_pass()
	elif _squad_mode:
		_run_squad_pass()
	elif _mechfall_mode:
		_run_mechfall_pass()
	elif _arena_mode:
		_start_arena("--gate" in args)
	elif _stress_mode:
		_run_stress_pass()
	elif _bench_mode:
		_run_bench()
	elif _shot_mode:
		_run_shot_pass()
	else:
		_scripted = false
	# The arena is in the chain and is the game, not a pass, unless it is run
	# as its gate.
	if _arena_mode and not ("--gate" in args):
		_scripted = false
	if _scripted:
		# A pass clicks for itself (--play, --mech), and a click is what takes
		# the mouse: never the real one.
		DebugCamera.hands_off = true
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
	if ai_services != null and ai_services.tally != null:
		ai_services.tally.call(&"save")
	# A band still uploading on a worker at shutdown was a crash on quit, as a
	# piece's was (IslandManager._exit_tree).
	for job in _band_jobs:
		if int(job[2]) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(job[2]))
	_band_jobs.clear()
	# And a shadow proxy being built.
	for job in _shadow_jobs.values():
		WorkerThreadPool.wait_for_task_completion(int((job as Array)[0]))
	_shadow_jobs.clear()
	for bodies in _frame_bodies.values():
		for rid in (bodies as Array):
			PhysicsServer3D.free_rid(rid)
	for rid in _shell_bodies.values():
		PhysicsServer3D.free_rid(rid)
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
## The detail tier covers the CITY and stops there: this is an authored place
## of a known size, not an infinite world, so `world_half` is a real edge and
## the resident square never moves. Everything out to the horizon is the
## coarse tier, with a fixed hole cut for the city (TerrainCoarse).
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
	# THE WHOLE CITY, RESIDENT. Not a camera-centred square: a scripted pass
	# stands outside the city looking in, and a camera-centred region would
	# leave the far half of it standing on coarse ground.
	_terrain_streamer.world_half = half
	_terrain_streamer.whole_world = true
	# COLLISION EVERYWHERE IN THE CITY, not just under the camera. Debris from
	# a collapse two streets away still has to land on something.
	_terrain_streamer.collide_radius = -1
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
	# A FIXED HOLE: the detail tier covers the city and never moves.
	_terrain_coarse.build(TERRAIN_REACH_TILES, _terrain_mat, Rect2i(-_terrain_half,
			-_terrain_half, _terrain_half * 2 + 1, _terrain_half * 2 + 1))


# ---------------------------------------------------------------------------
# The terrain dev menu (terrain_dev_menu.gd, Docs/Terrain.md §20.10, §22.15).
#
# F10 on terrain: the same menu the heightfield test opens, on this scene's
# ground and sea. What it asks of a host is in its header; the rows about a
# detail square that follows the camera are not offered here, because this
# one covers the city and never moves.

const TerrainDevMenu := preload("res://scripts/terrain_dev_menu.gd")
var _terrain_dev_menu = null
var _lod_debug := false


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
	for tier in [_sea.near, _sea.sheet]:
		if tier != null and tier._mat != null:
			tier._mat.set_shader_parameter(param, value)


func dev_sea():
	return _sea


## Every detail tile again from the field, behind the ones on screen.
func rebuild_detail() -> void:
	_terrain_streamer.refresh(Rect2i(-_terrain_half, -_terrain_half,
			_terrain_half * 2 + 1, _terrain_half * 2 + 1))


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
		"drowned": _terrain_drowned, "world_half": _terrain_half,
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


## The city's shore (§21.6): standing on dry ground a little inland of the
## nearest water, looking out over it, so the brick tiers, the sheet and the
## seabed's shallows are all in one picture.
func _shot_shore() -> void:
	var sea: float = TerrainWorldScript.sea_level
	var wet := Vector3.INF
	for r in range(20, 400, 8):
		for k in 48:
			var a := TAU * float(k) / 48.0
			var p := _on_ground(Vector3(cos(a) * r, 0.0, sin(a) * r))
			if p.y < sea - 0.5:
				wet = p
				break
		if wet != Vector3.INF:
			break
	if wet == Vector3.INF:
		return
	var inland := Vector3(wet.x, 0.0, wet.z).normalized() * -18.0
	var stand := _on_ground(wet + inland)
	camera.position = Vector3(stand.x, maxf(stand.y, sea) + 6.0, stand.z)
	camera.look_at(Vector3(wet.x, sea, wet.z) - inland, Vector3.UP)
	await _frames(8)
	await _save("city_shore")


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


## What is straight under a figure, for a gate's failure message: which body,
## and how far down.
func _what_is_under(body: CharacterBody3D) -> String:
	if body == null:
		return "nothing (no figure)"
	var q := PhysicsRayQueryParameters3D.create(body.global_position,
			body.global_position - Vector3(0.0, 6.0, 0.0))
	q.collision_mask = Layers.HITSCAN_MASK
	q.exclude = [body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return "nothing within 6 m"
	var rid: RID = hit.rid
	var what := "something else"
	for bid in _brick_cols:
		var bc: BuildingCollision = _brick_cols[bid]
		if bc.owns(rid):
			what = "band %d of building %d's bricks" % [bc.bodies.find(rid), bid]
	for bid in _shell_bodies:
		if _shell_bodies[bid] == rid:
			what = "building %d's shell" % bid
	for bid in _room_bodies:
		if _room_bodies[bid] == rid:
			what = "building %d's furniture" % bid
	if islands.find_by_body(hit.collider) != null:
		what = "a piece"
	return "%s, shape %d, %.2f m down" % [what, int(hit.shape),
			body.global_position.y - (hit.position as Vector3).y]


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
					held = 1 if _mid_collapse(id) else 0
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
	var damage: Dictionary = b.damage_profile
	var nothing_left := false
	if b.is_materialised() and not b.is_build():
		damage = registry.live_damage_profile(id)
		nothing_left = world.get_alive_block_count(b.chunk) == 0
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
		mi.mesh = (BuildingShell.build_coarse_mesh(b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses)
				if coarse else
				BuildingShell.build_mesh(b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses,
						damage))
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
	# Its windows, with a room painted behind each: a shell has no openings, so
	# the fake rung cannot show through it. Not on the coarse tier -- past a
	# hundred metres a window is a pixel -- and not on a player build, which
	# has no recipe windows. A child of the shell, so it goes when the shell
	# does, and with its own material so the brick material is untouched.
	if not coarse and not b.is_build() and not nothing_left:
		var panes := BuildingShell.build_window_mesh(b.recipe.footprint_x,
				b.recipe.footprint_z, b.recipe.courses, registry.room_seed_of(id),
				damage, b.recipe.get("program", {}))
		if panes != null:
			var glass := MeshInstance3D.new()
			glass.mesh = panes
			glass.material_override = BuildingShell.window_material()
			glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if fades:
				_fade_out(glass)
			mi.add_child(glass)
	# A shell and a far box would be the same building drawn twice -- unless
	# the far box IS this shell's drawing. So would a shell and a tree's copy.
	_far_sync(b)
	_inst_sync(b)
	if far:
		_shell_far[id] = true
		return
	_make_shell_body(id)


## The collision boxes of a shell, and the AI's proxies of them.
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
func _promote(id: int, solve: bool = true) -> int:
	var b := registry.get_building(id)
	if b == null:
		return -1
	if b.is_materialised():
		return b.chunk

	var t0 := Time.get_ticks_usec()
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
	# Bricks now: the AI asks them, not the shell.
	_drop_proxies(id)
	_nav_touch(id)
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

	# The CHUNK's transform, not the building's. They are the same thing for a
	# generated tower, and they are not for a build: a multi-frame placement
	# rebases the whole assembly in its transform so the author's lowest brick
	# lands on the ground (BuildingRegistry.materialise).
	var root_x: Transform3D = world.get_chunk_transform(chunk)
	# A static body a band -- the bands set just above -- so a hit rebuilds
	# the band it lands in, not the building (BuildingCollision).
	_brick_cols[id] = BuildingCollision.new(world, chunk, get_world_3d().space, root_x,
			MERGE_SHAPES)
	# And the shell's boxes go now -- its MESH stays until the bands are drawn
	# (_advance_bands). Both in the space was a solid box where the building's
	# insides are, for as long as its bands took to draw: a figure dropped down
	# the stairwell of a building still drawing its bands stood on the shell's
	# roof, and fell to the stairs when the shell went.
	_free_shell_body(id)

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
const CRUSH_PER_STUD := 20.0   ## x tension_per_stud: an intact tower asks at most 12.4 (big city), one corner left ~22
var gravity_fails := {"tip": 0, "crush": 0}
## CRUSH_PER_STUD, settable: collapse_probe weakens one tower to crush it.
var crush_per_stud := CRUSH_PER_STUD


func _gravity_fail(b: BuildingRegistry.Building) -> bool:
	if not authority.may_decide() or b.toppled or not b.is_materialised():
		return false
	var r: Dictionary = world.gravity_check(b.chunk, crush_per_stud)
	if float(r.get("ratio", 0.0)) < 1.0 or not r.has("level"):
		return false
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
	if box.size.y < (TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * BrickPalette.PLATE_M:
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
			if leaving.has(bid) or gone.has(bid):
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
	var from_y := box.position.y + (TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * BrickPalette.PLATE_M * 0.5
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
		_band_hits[id] = int(_band_hits.get(id, 0)) + 1
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
	_band_todo.erase(id)
	var built_at := PackedInt32Array()
	built_at.resize(n)
	built_at.fill(-1)
	_band_built_at[id] = built_at
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
	# A pass over some bands only (_bands_done): the cursor walks that list.
	var todo: PackedInt32Array = _band_todo.get(id, PackedInt32Array())
	var count := todo.size() if not todo.is_empty() else nodes.size()
	if pos >= count:
		_band_cursor.erase(id)
		return false
	var at: int = todo[pos] if not todo.is_empty() else pos
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
	# What this band was built from: the bricks as they are after every hit
	# counted so far.
	var built_at: PackedInt32Array = _band_built_at.get(id, PackedInt32Array())
	if at < built_at.size():
		built_at[at] = int(_band_hits.get(id, 0))
		_band_built_at[id] = built_at
	var ok := not arrays.is_empty() \
			and IslandManager.mesh_arrays_ok(arrays, "building %d band %d" % [id, at])
	if ok:
		_brick_index_width[id] = IslandManager.index_width(arrays)
		_band_verts_now += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	if ok and (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() >= BAND_THREAD_VERTS:
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
	if pos + 1 >= count:
		_band_cursor.erase(id)
		return false
	return true


func _is_tree(id: int) -> bool:
	var b := registry.get_building(id)
	return b != null and b.is_build() and b.build != null and String(b.build.name).begins_with("tree_")


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
	if b.is_build() and b.build != null and String(b.build.name).begins_with("tree_"):
		return WeatherFx.sway_tree(h)
	return WeatherFx.sway_building(h)


## Hang a finished band mesh in its slot.
func _apply_band(id: int, at: int, mesh: ArrayMesh, arrays: Array) -> void:
	var nodes: Array = _brick_bands.get(id, [])
	if at >= nodes.size() or not _brick_nodes.has(id):
		_retirer.retire(mesh)
		return
	var node: MeshInstance3D = nodes[at]
	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.material_override = brick_material
		# It sways in the wind, a little (weather.gdshaderinc); a tree more.
		node.set_instance_shader_parameter("weather_sway", _sway_of(id))
		# A tree's crown takes a cap of snow; a building gets real cover.
		node.set_instance_shader_parameter("weather_snowcap", 1.0 if _is_tree(id) else 0.0)
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
			var hits := int(_band_hits.get(id, 0))
			var built_at: PackedInt32Array = _band_built_at.get(id, PackedInt32Array())
			var stale := PackedInt32Array()
			for si in built_at.size():
				if built_at[si] < hits:
					stale.append(si)
			var nodes: Array = _brick_bands.get(id, [])
			if built_at.size() != nodes.size():
				_rebuild_bands(id, rb.chunk)
			elif not stale.is_empty():
				_band_todo[id] = stale
				_band_cursor[id] = 0
				_band_pass[id] = int(_band_pass.get(id, 0)) + 1
			else:
				_free_shell(id)
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
		_build_one_band(id)
		built += 1
		if not _bands_building(id):
			_bands_done(id)
		if Time.get_ticks_usec() >= until:
			break


## Drop a building's band nodes, returning them so a caller can hand them on.
func _take_bands(id: int) -> Array:
	# Whatever is being uploaded for it lands first: a piece carrying these
	# bands away patches them, and a slot still waiting holds nothing to patch.
	_harvest_band_jobs(id)
	_band_pass.erase(id)
	var nodes: Array = _brick_bands.get(id, [])
	_band_cursor.erase(id)
	_band_redo.erase(id)
	_band_hits.erase(id)
	_band_built_at.erase(id)
	_band_todo.erase(id)
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
		for b in registry.buildings:
			if far and not b.is_materialised():
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
						room.gone[i] = true
						if not redraw.has(index):
							redraw.append(index)
						break
		if redraw.is_empty():
			continue
		_groups_refresh(b, redraw)
		crushed_by_wreckage += redraw.size()


## Shear, not destroy: a brick struck by falling masonry comes loose.
func _shear_building(id: int, point: Vector3, radius: float) -> void:
	var chunk := _promote(id)
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
			if not promote or _promote(b.id) < 0:
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
		var e := DamageLog.Entry.new()
		e.tick = pf
		e.kind = DamageLog.Kind.SCORCH
		e.target = id
		e.frame = frame
		e.flags = DamageLog.FLAG_BLOCKS
		e.blocks = charred
		e.point = at
		authority.commit_entry(e)
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
	var gi := GunInstance.from_result(res)
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
	# The AI overlay (F4) draws, and says something.
	_ai_label.visible = true
	_update_ai_label()
	_gate_ok("the AI overlay reports the AI's world and budget",
			_ai_label.text.begins_with("AI (F4)") and _ai_label.text.contains("chunks"),
			_ai_label.text.get_slice("
", 0))
	await _frames(12)
	await _save("city_gun")
	_check_log_replays()
	print("[city] gun gate: %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


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
	# After the gun: add_pawn arms it, so its rounds suppress, are heard and
	# earn aggro (AIServices).
	ai_services.add_pawn(_player_pawn)
	_gun.exclude = [_player_pawn.body.get_rid()] as Array[RID]
	if not _player_pawn.has_meta(&"weight"):
		_player_pawn.set_meta(&"weight", weight.add(_player_pawn.body, _player_pawn.feet,
				WeightTracker.PERSON))
	if _mech_cmd != null:
		_mech_cmd.brain.leader = _player_pawn
	_player_hud()
	_fps_on()
	print("[city] playing: pawn at %v" % feet)


## The gun into the view's hands, its HUD up, the debug overlays away.
func _fps_on() -> void:
	if _view == null:
		_view = PlayerView.new()
		_view.name = "PlayerView"
		add_child(_view)
		_view.setup(camera, _player_pawn, _gun)
	_player.view = _view
	if _fps_hud == null:
		_fps_hud = PlayerHud.new()
		_fps_hud.name = "PlayerHud"
		add_child(_fps_hud)
		_fps_hud.setup(_player_pawn, _gun, _view)
	if _feedback == null and arena == null:
		_feedback = CombatFeedback.new()
		_feedback.name = "Feedback"
		add_child(_feedback)
		_feedback.setup(self)
		_gun.fired.connect(_feedback.on_player_shot)
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
	if _fps_hud != null:
		_fps_hud.queue_free()
		_fps_hud = null
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
	if _aggro_layer != null:
		_aggro_layer.visible = false


## What the player is shown of the fight (AI.md 6.5, 8): the callouts it can hear
## -- markers over the speakers it can see, over friendlies always -- and the
## enemy's aggro meter. Heard from the camera, which is the player's eye.
func _player_hud() -> void:
	if _callout_hud == null:
		var l := ai_services.callouts.listen(camera, 0, _player_pawn)
		_callout_hud = CalloutHud.new()
		_callout_hud.name = "Callouts"
		_callout_hud.setup(ai_services.callouts, l)
		add_child(_callout_hud)
		_aggro_layer = CanvasLayer.new()
		_aggro_layer.name = "Aggro"
		_aggro_layer.layer = 5
		_aggro_meter = AggroMeter.new()
		_aggro_meter.table = ai_services.aggro_of(1)
		_aggro_meter.position = Vector2(20.0, 180.0)
		_aggro_layer.add_child(_aggro_meter)
		add_child(_aggro_layer)
	_callout_hud.listener.pawn = _player_pawn
	_aggro_layer.visible = true


## Climb into the mech -- spawning one on the ground ahead of the camera if there
## is none -- and take its controls. Its arm gets a gun of its own.
func _board_mech() -> void:
	if _player.is_possessing():
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
	_pilot.board(_mech, camera)
	print("[city] piloting: mech at %v, %s" % [_mech.feet(), _mech.gun.gun.gun_name])


func _spawn_mech(feet: Vector3, yaw: float) -> Mech:
	_mech = Mech.spawn(self, feet, yaw, 0)
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var res := GunGenerator.generate(_gun_library, _combat_rng.randi(),
			WeaponClass.builtin(&"lmg"), 1)
	var gi := GunInstance.from_result(res)
	gi.visible = false  # the arm's greybox is the gun, for now
	_mech.arm.add_child(gi)
	_mech.gun.equip(gi)
	_mech.gun.rng = _combat_rng
	_mech.gun.on_structure_hit = _gun.on_structure_hit
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


## A mech's weight and its fall rule, on this city (Docs/AI.md 3.10, 3.11).
func _wire_mech(m: Mech) -> void:
	m.fall.decides = authority.may_decide()
	m.fall.floor_at = _mech_floor_at
	m.fall.on_break = _mech_break
	m.fall.next_floor = _next_floor_below
	weight.add(m.body, m.feet, Mech.MASS)


## The enemy's mech (Y), ahead of the camera: an LMG, a launcher for walls, and
## the enemy tree -- it breaches to get at infantry (AI.md 6.4).
func _spawn_enemy_mech(feet: Vector3, yaw: float) -> MechBrain:
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	var m := Mech.spawn(self, feet, yaw, 1)
	var gi := GunInstance.from_result(GunGenerator.generate(_gun_library, _combat_rng.randi(),
			WeaponClass.builtin(&"lmg"), 1))
	gi.visible = false
	m.arm.add_child(gi)
	m.gun.equip(gi)
	m.gun.rng = _combat_rng
	m.gun.on_structure_hit = _gun.on_structure_hit
	_wire_mech(m)
	var br := MechBrain.attach(ai_services, m, mech_nav, MechTree.enemy(), 1)
	# A medium mech by the roster: its layers and the name over it (AIRoster.md RO6).
	m.set_type("medium_gunner", Roster.shared())
	br.arm_launcher(GunInstance.from_result(GunGenerator.generate(_gun_library,
			_combat_rng.randi(), WeaponClass.builtin(&"rocket_launcher"), 1)), _combat_rng,
			_gun.on_structure_hit)
	mech_brains.append(br)
	print("[city] enemy mech at %v" % feet)
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
			if b != null and not b.is_materialised() and _world_box(b).grow(0.3).has_point(under):
				_promote(id)
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
	for b in registry.buildings:
		if b.is_materialised() and b.chunk == chunk:
			_chunk_owner[chunk] = b.id
			return b.id
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


## The gate for the mech (Docs/AIPlan.md P1): BoomerBorder's motor under a body
## sized in bricks, piloted by the keys -- walks at its speed, sprints faster,
## dashes on a charge, its torso follows the look at its own pace, it steps over a
## figure's cover and not a storey -- and its arm aims UP as far as the player can
## (A15) and puts rounds into a wall high above through the authority.
func _run_mech_pass() -> void:
	print("[mech] a greybox mech, piloted")
	_pilot.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	camera.global_position = open + Vector3(0.0, 6.0, 12.0)
	camera.rotation = Vector3.ZERO
	_spawn_mech(open, 0.0)
	_board_mech()
	await _frames(60)
	var m := _mech
	_gate_ok("it stands on the ground", m.body.is_on_floor() and absf(m.feet().y) < 0.1,
			"feet %.2f" % m.feet().y)
	_gate_ok("the camera is in the cockpit, ten courses up",
			absf(camera.global_position.y - Mech.COCKPIT_Y) < 0.15,
			"%.2f m" % camera.global_position.y)

	_key(KEY_W, true)
	await _frames(90)
	var walk := m.motor.planar_speed()
	_key(KEY_SHIFT, true)
	await _frames(90)
	var sprint := m.motor.planar_speed()
	_key(KEY_SHIFT, false)
	_key(KEY_W, false)
	await _frames(60)
	_gate_ok("it walks at the motor's speed", absf(walk - m.motor.max_speed) < 0.6,
			"%.1f m/s" % walk)
	_gate_ok("and sprints faster", sprint > walk * 1.3, "%.1f m/s" % sprint)
	_gate_ok("and stops when let go", m.motor.planar_speed() < 0.5)

	var charges := m.motor.charges()
	_key(KEY_W, true)
	_key(KEY_Q, true)
	await _frames(4)
	var dashing := m.motor.is_dashing()
	_key(KEY_Q, false)
	_key(KEY_W, false)
	await _frames(60)
	_gate_ok("Q dashes on a charge", dashing and m.motor.charges() == charges - 1,
			"%d -> %d charges" % [charges, m.motor.charges()])

	# The look turns at once; the torso follows at its own pace, the legs after.
	camera.rotation = Vector3(0.0, PI * 0.5, 0.0)
	await _frames(2)
	var lag := absf(wrapf(m.motor.torso_yaw - PI * 0.5, -PI, PI))
	await _frames(60)
	var settled := absf(wrapf(m.motor.torso_yaw - PI * 0.5, -PI, PI))
	_gate_ok("the torso chases the look, heavy but arriving",
			lag > 0.2 and settled < deg_to_rad(3.0),
			"%.0f deg behind, then %.1f" % [rad_to_deg(lag), rad_to_deg(settled)])
	_gate_ok("and the legs follow it round",
			absf(wrapf(m.motor.legs_yaw - m.motor.torso_yaw, -PI, PI)) < deg_to_rad(40.0))

	# Cover a figure hides behind is a step; a storey is a wall. Facing -Z again.
	camera.rotation = Vector3.ZERO
	await _frames(60)
	var here := m.feet()
	var cover := _test_block(here + Vector3(0.0, 0.5, -6.0), Vector3(8.0, 1.0, 2.0))
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(30)
	_gate_ok("it walks over a metre of cover", m.feet().z < here.z - 8.0,
			"z %.2f, cover at %.2f" % [m.feet().z, here.z - 6.0])
	cover.queue_free()
	here = m.feet()
	var storey := _test_block(here + Vector3(0.0, 1.5, -6.0), Vector3(10.0, 3.0, 2.0))
	await _frames(4)
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(30)
	_gate_ok("and not over a storey", m.feet().z > here.z - 5.0 - Mech.RADIUS + 0.5
			and m.feet().z < here.z - 1.0, "z %.2f, face at %.2f" % [m.feet().z, here.z - 5.0])
	storey.queue_free()

	# Aim UP (A15): stand back from the tallest building and fire at its wall well
	# above the cockpit.
	var tall := registry.get_building(0)
	for b in registry.buildings:
		if b.recipe.courses > tall.recipe.courses:
			tall = b
	var face := tall.xform * Vector3(tall.recipe.footprint_x * 0.5 * STUD, 0.0, 0.0)
	var out := tall.xform.basis * Vector3(0.0, 0.0, -1.0)
	_leave_mech()
	m.body.global_position = face + out * 6.0 + Vector3.UP * Mech.HEIGHT * 0.5
	m.body.reset_physics_interpolation()
	_board_mech()
	await _frames(60)
	var high := face + Vector3.UP * minf(tall.recipe.courses * Mech.COURSE * 0.9, 30.0)
	print("[mech]   tallest: %d courses; aiming at %.1f m from 6 m out" % [tall.recipe.courses, high.y])
	camera.look_at(high, Vector3.UP)
	await _frames(30)
	var n0 := authority.commands.size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(40)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await _shoot(0)
	var top := 0.0
	var chips := 0
	for i in range(n0, authority.commands.size()):
		var e: DamageLog.Entry = authority.commands.entries[i]
		if e.kind == DamageLog.Kind.CHIP:
			chips += 1
			top = maxf(top, e.point.y)
	_gate_ok("the arm aims up as far as the player can (A15)",
			m.arm_pitch > deg_to_rad(40.0), "%.0f deg" % rad_to_deg(m.arm_pitch))
	_gate_ok("and its rounds wear the wall high above the cockpit",
			chips > 0 and top > Mech.COCKPIT_Y + 4.0, "%d CHIP(s), highest %.1f m" % [chips, top])

	_leave_mech()
	await _frames(30)
	_gate_ok("M leaves: the camera flies and the mech stays parked",
			camera.is_processing() and is_instance_valid(m) and m.motor.planar_speed() < 0.5)
	# From above the street: the blocks are 13 m apart, so anywhere level with the
	# mech and a few metres off is inside a building.
	camera.global_position = m.feet() + out * 3.0 + out.cross(Vector3.UP) * 3.0 + Vector3.UP * 13.0
	camera.look_at(m.feet() + Vector3.UP * 3.5, Vector3.UP)
	await _frames(3)
	await _save("city_mech")
	_check_log_replays()
	print("[mech] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


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
	ai_world.sync()
	# Where not to stand: anything big still falling, swept to where it is going.
	Danger.update(ai_world, islands)
	# And whatever a disaster has marked: a meteor's ring, a funnel, a fire.
	if disasters != null:
		disasters.ctx.push_hazards(ai_world)
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
	for enc in _encounters:
		enc.step(func(id: int) -> void: _promote(id, false))
	if ai_nav.pending() > 0:
		ai_sched.submit(AIScheduler.NAV, 5.0, _nav_service)
	if mech_nav.pending() > 0:
		ai_sched.submit(AIScheduler.NAV, 6.0, _mech_nav_service)
	# Weight is structure: only the host turns it into commands (R5).
	if authority.may_decide():
		weight.tick(ai_services.now())
	var t1 := Time.get_ticks_usec()
	_ai_sync_ms = float(t1 - t0) / 1000.0
	ai_sched.report_destruction_ms(destruction_ms)
	_ai_heavy_run = _ai_heavy_run + 1 if destruction_ms > AI_HEAVY_MS else 0
	_ai_heavy_run_max = maxi(_ai_heavy_run_max, _ai_heavy_run)
	_ai_destruction_peak = maxf(_ai_destruction_peak, destruction_ms)
	ai_sched.run()
	# Aggro and callouts (AIServices.tick): never ran in the city before.
	ai_services.tick()
	_ai_run_ms = float(Time.get_ticks_usec() - t1) / 1000.0
	if budget != null:
		budget.tick(ai_services.now())
	if swarm != null and ai_services.now() >= _next_swarm_refresh:
		# Buildings come down: the field goes round what is still standing.
		_next_swarm_refresh = ai_services.now() + 5.0
		swarm.refresh()
	_prof["ai"] = _ai_sync_ms + _ai_run_ms + (swarm.tick_ms() if swarm != null else 0.0)
	if _phase != "":
		_ai_phase_level[_phase] = maxi(int(_ai_phase_level.get(_phase, 0)), ai_sched.get_level())
		var k := "tick:" + _phase
		_ai_phase_level[k] = float(_ai_phase_level.get(k, 0.0)) + destruction_ms
		_ai_phase_level["n:" + _phase] = int(_ai_phase_level.get("n:" + _phase, 0)) + 1
	if _ai_label != null and _ai_label.visible and Engine.get_physics_frames() % 10 == 0:
		_update_ai_label()


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
	]
	for sub in ["perception", "nav", "tactical", "trees", "onnx", "commander"]:
		var d: Dictionary = s[sub]
		lines.append("  %-11s %5.2f ms  %3d ran  %3d deferred" % [sub, float(d.ms),
				int(d.ran), int(d.deferred)])
	_ai_label.text = "\n".join(lines)


## The gate for navigation (Docs/AIPlan.md P3): an encounter brings a tower and
## its neighbours in; a path from the street into a room two storeys up, found
## through the queue; a wall blown out on the far side makes a new way out that
## is taken within a few ticks of the blast; paths round pristine buildings
## materialise nothing; fifty requesters are served inside the budget.
## A point on dry ground within `half` metres of the origin: on terrain the
## sea is not somewhere a path can start or end, and a random point can land
## in it.
func _dry_point(rng: RandomNumberGenerator, half: float) -> Vector3:
	var p := Vector3.ZERO
	for attempt in 64:
		p = _on_ground(Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half)))
		if not _terrain_mode or p.y >= ai_nav.get_water_level() + ai_nav.get_wade():
			return p
	return p


## A point on dry ground in the 80 x 40 m in front of `street`. On the plane
## that is the first draw, every time, so the flat pass asks exactly what it
## always asked.
func _dry_near(rng: RandomNumberGenerator, street: Vector3) -> Vector3:
	var p := street
	for attempt in 64:
		p = _on_ground(street + Vector3(rng.randf_range(-40.0, 40.0), 0.0,
				rng.randf_range(-40.0, 0.0)))
		if not _terrain_mode or p.y >= ai_nav.get_water_level() + ai_nav.get_wade():
			return p
	return p


## Buildings on the terrain (Docs/Terrain.md §21.8): on the world's stud and
## plate grid, and the ground flush with the floor under every column of the
## footprint -- and a build placed on a hillside gets the same.
func _ground_gates() -> void:
	var off_grid := 0
	var off_ground := 0
	var cols := 0
	for id in _site_ids:
		var b := registry.get_building(id)
		var o: Vector3 = b.xform.origin
		if absf(o.x / STUD - roundf(o.x / STUD)) > 1e-3 				or absf(o.z / STUD - roundf(o.z / STUD)) > 1e-3 				or absf(o.y / PLATE - roundf(o.y / PLATE)) > 1e-3:
			off_grid += 1
		off_ground += _unflush(b)
		cols += int(b.recipe.footprint_x) * int(b.recipe.footprint_z)
	print("[nav]   grid: %d building(s), %d off the stud grid, %d of %d footprint columns not flush" % [
		_site_ids.size(), off_grid, off_ground, cols])
	_gate_ok("every site building is on the stud grid and flush with the ground",
			off_grid == 0 and off_ground == 0)

	# A saved build, aimed at open hillside, placed like the player does.
	var path := BuildRecipe.shipped("cottage")
	# Open, dry hillside: clear of every registry entry -- trees and small
	# items too, since the placer would land a build ON one -- searched on a
	# widening spiral, which a city full of trees needs more tries for.
	var spot := _dry_point(RandomNumberGenerator.new(), 30.0)
	var found_clear := false
	for attempt in 400:
		var ang := float(attempt) * 2.39996
		var cand := _on_ground(Vector3(cos(ang), 0.0, sin(ang)) * (10.0 + float(attempt) * 0.6))
		if cand.y < ai_nav.get_water_level() + 0.5:
			continue
		var clear := true
		for b in registry.buildings:
			if _world_box(b).grow(8.0).has_point(Vector3(cand.x, b.xform.origin.y + 1.0, cand.z)):
				clear = false
				break
		if clear:
			spot = cand
			found_clear = true
			break
	if not found_clear:
		print("[nav]   placed: no clear hillside found; trying anyway at %s" % spot)
	if not _placer.start(path):
		_gate_ok("a build placed on the hillside gets ground at its floor", false, "no " + path)
		return
	var eye := spot + Vector3(0.0, 30.0, 12.0)
	_placer.aim_ray(eye, (spot - eye).normalized())
	var before_y := _ground_y(spot.x, spot.z)
	var id := _placer.place()
	_placer.stop()
	await _frames(20)
	var ok := id >= 0 and _placer.on_ground
	var unflush := -1
	var pb = null
	if id >= 0:
		pb = registry.get_building(id)
		unflush = _unflush(pb)
	print("[nav]   placed: %s at %s, ground was %.2f m, floor %.2f m, %d column(s) not flush" % [
		path.get_file(), spot, before_y, pb.xform.origin.y if pb != null else 0.0, unflush])
	_gate_ok("a build placed on the hillside gets ground at its floor",
			ok and unflush == 0)


## Footprint columns of a building whose ground is not at its floor.
func _unflush(b) -> int:
	var box: AABB = CityPlacer.box_of(b)
	var n := 0
	var x0 := int(roundf(box.position.x / STUD))
	var z0 := int(roundf(box.position.z / STUD))
	for dz in int(roundf(box.size.z / STUD)):
		for dx in int(roundf(box.size.x / STUD)):
			var gy := float(BrickTerrain.surface_plate(x0 + dx, z0 + dz) + 1) * PLATE
			if absf(gy - box.position.y) > 1e-3:
				n += 1
	return n


## What navigation has to get right on a hillside (Docs/Terrain.md §21.7).
func _nav_terrain_gates(rng: RandomNumberGenerator) -> void:
	await _ground_gates()
	# Up the hill: from in front of the lowest building to in front of the
	# highest, which on this seed is metres of climb across the city.
	# The SITE buildings: the registry also holds trees and small items now,
	# and a tree on a hilltop is not a building a path climbs to.
	var lo_b := registry.get_building(_site_ids[0])
	var hi_b := lo_b
	for id in _site_ids:
		var c := registry.get_building(id)
		if c.xform.origin.y < lo_b.xform.origin.y:
			lo_b = c
		if c.xform.origin.y > hi_b.xform.origin.y:
			hi_b = c
	var a := _on_ground(lo_b.xform * Vector3(lo_b.recipe.footprint_x * STUD * 0.5, 0.0, -3.0))
	var z := _on_ground(hi_b.xform * Vector3(hi_b.recipe.footprint_x * STUD * 0.5, 0.0, -3.0))
	var climb := ai_nav.find_path(a, z, 120000)
	# Every corner of it is ON the ground (or on bricks above it), never
	# under it: a path that tunnels through a hill is a y=0 path in disguise.
	var worst_under := 0.0
	var top := -INF
	var bottom := INF
	for q in climb:
		worst_under = maxf(worst_under, _ground_y(q.x, q.z) - q.y)
		top = maxf(top, q.y)
		bottom = minf(bottom, q.y)
	# A corner is where four columns meet and stands on ONE of them, so the
	# ground next to it can be a step higher: a step is the tolerance.
	var step_m := float(AINav.STEP_UP) * PLATE + 0.05
	var climb_detail := ("%.1f m to %.1f m: %.0f m long, spans %.1f m, never more than %.2f m under the ground" % [
			a.y, z.y, _path_len(climb), top - bottom, worst_under]) if not climb.is_empty() 			else "none, %.1f m to %.1f m" % [a.y, z.y]
	print("[nav]   climb: %s" % climb_detail)
	_gate_ok("a path climbs the hillside from the lowest building to the highest",
			not climb.is_empty() and worst_under <= step_m
			and absf(climb[0].y - a.y) <= step_m and absf(climb[-1].y - z.y) <= step_m,
			climb_detail)
	_draw_path(climb, Color(0.3, 0.7, 1.0))

	# A hill hides a body. Two points either side of a crest, eye height, and
	# the AI's own line of sight says so -- as physics does, which is what
	# the soldiers' eyes use.
	var hidden := 0
	var tried := 0
	var physics_agrees := 0
	var space := get_world_3d().direct_space_state
	for i in 4000:
		if tried >= 12:
			break
		var p := _dry_point(rng, 110.0)
		var dir := Vector3.FORWARD.rotated(Vector3.UP, rng.randf() * TAU)
		var q := _on_ground(p + dir * rng.randf_range(20.0, 60.0))
		var mid := _on_ground((p + q) * 0.5)
		var eye_p := p + Vector3.UP * 1.6
		var eye_q := q + Vector3.UP * 1.6
		# A metre of ground over the sight line between two eyes: a crest,
		# not a bump the line grazes.
		if mid.y < (eye_p.y + eye_q.y) * 0.5 + 1.0:
			continue
		tried += 1
		if not ai_world.line_clear(eye_p, eye_q) \
				and is_inf(ai_world.cover_seconds(eye_p, eye_q, 30, 10.0)):
			hidden += 1
		# What a soldier's own eyes do (Soldier.can_see): a physics ray, and
		# the field where there are no colliders.
		var ray := PhysicsRayQueryParameters3D.create(eye_p, eye_q, Layers.HITSCAN_MASK)
		if not space.intersect_ray(ray).is_empty() or ai_world.ground_blocks(eye_p, eye_q):
			physics_agrees += 1
	print("[nav]   crest: %d of %d lines over a crest blocked (a soldier's eyes: %d)" % [
			hidden, tried, physics_agrees])
	_gate_ok("a crest blocks the AI's sight and is cover no gun wears away",
			tried > 0 and hidden == tried and physics_agrees == tried,
			"%d of %d lines over a crest blocked (physics: %d)" % [hidden, tried, physics_agrees])

	# And nobody walks into the sea.
	var sea := ai_nav.get_water_level()
	var wet := Vector3.INF
	for i in 400:
		var w := _on_ground(Vector3(rng.randf_range(-200.0, 200.0), 0.0,
				rng.randf_range(-200.0, 200.0)))
		if w.y < sea - 1.0:
			wet = w
			break
	if wet == Vector3.INF:
		print("[nav]   (no ground under the sea within 200 m; the sea gate is skipped)")
	else:
		var swim := ai_nav.find_path(a, wet, 40000)
		print("[nav]   sea: seabed %.1f m under a %.1f m sea; can stand %s, path %s" % [
				wet.y, sea, ai_nav.can_stand(wet),
				"none" if swim.is_empty() else "ends at %.2f m" % swim[-1].y])
		_gate_ok("the sea is not somewhere a path goes",
				not ai_nav.can_stand(wet) and (swim.is_empty()
				or swim[-1].y >= sea - ai_nav.get_wade() - 0.05),
				"seabed %.1f m under a %.1f m sea" % [wet.y, sea])


func _run_nav_pass() -> void:
	print("[nav] paths through a city that falls down")
	var b := registry.get_building(0)
	for c in registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	camera.position = b.xform * Vector3(fx * 0.5, 30.0, -25.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, 4.0, fz * 0.5), Vector3.UP)
	await _frames(4)

	# The encounter: the tower and whatever else its zone touches.
	var zone := _world_box(b).grow(6.0)
	var enc := start_encounter(zone)
	var guard := 0
	while not enc.is_ready() and guard < 300:
		await _frames(1)
		guard += 1
	await _frames(30)
	var all_in := true
	for id in enc.buildings:
		if not registry.get_building(id).is_materialised():
			all_in = false
	_gate_ok("an encounter brings its buildings in", all_in and enc.buildings.size() >= 1,
			"%d building(s) in %d tick(s)" % [enc.buildings.size(), guard])

	# From the street in front of the tower to a room two storeys up. On
	# terrain the tower stands on its pad and the street is wherever the
	# hillside is, so both are measured from the ground rather than from 0.
	var floor0 := b.xform.origin.y
	var street := _on_ground(b.xform * Vector3(fx * 0.5, 0.0, -4.0))
	var storey_y := (1 + 2 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * PLATE
	var room := ai_nav.snap(b.xform * Vector3(fx * 0.3, storey_y + 0.05, fz * 0.3))
	_gate_ok("there is floor to stand on two storeys up",
			absf(room.y - floor0 - storey_y) < 0.3,
			"snapped to %.2f m, the floor is at %.2f" % [room.y, floor0 + storey_y])
	# A tower is sealed at street level: no door, and its sills are four plates
	# up -- over a course, which nobody steps and nobody jumps. The way in is
	# made, not found (AI.md 3.8, "make a door").
	var sealed := ai_nav.find_path(street, room, 20000)
	_gate_ok("a sealed tower has no way in from the street", sealed.is_empty())
	var breach := b.xform * Vector3(fx * 0.5, 1.0, 0.2)
	var id_in := await _path_after_blast(breach, street, room)
	var path_in := ai_nav.get_path(id_in)
	var inside := false
	var top := 0.0
	var box := _world_box(b)
	for p in path_in:
		if box.grow(-0.4).has_point(p + Vector3.UP * 0.5) and p.y < floor0 + 1.0:
			inside = true
		top = maxf(top, p.y)
	_gate_ok("breached, a path from the street through the hole and up to the room",
			ai_nav.get_status(id_in) == AINav.DONE and path_in[-1].distance_to(room) < 0.8
			and inside and top >= room.y - 0.2 and _passes(path_in, breach),
			"%d corners, %.0f m, %d tick(s) from the blast" % [path_in.size(),
			_path_len(path_in), _last_wait])
	_draw_path(path_in, Color(1.0, 0.9, 0.2))

	# Out the far side: back down and out through the breach, the long way...
	var far := _on_ground(b.xform * Vector3(fx * 0.5, 0.0, fz + 4.0))
	var before := ai_nav.find_path(room, far)
	# ...until the far wall is blown open too.
	var hole := b.xform * Vector3(fx * 0.5, 1.0, fz - 0.2)
	var id_out := await _path_after_blast(hole, room, far)
	var after := ai_nav.get_path(id_out)
	_gate_ok("a wall shot out on the far side is the new way out",
			not after.is_empty() and _passes(after, hole)
			and (before.is_empty() or _path_len(after) < _path_len(before) - 2.0),
			"%.0f m, was %s; %d tick(s) from the blast to the new path" % [
			_path_len(after), ("%.0f m" % _path_len(before)) if not before.is_empty() else "none",
			_last_wait])
	_draw_path(after, Color(0.3, 1.0, 0.4))

	# Paths round pristine buildings, far from the encounter: they ask the
	# shells, and nothing is materialised to answer them.
	var mat0: int = registry.report().materialised
	var promos := _promotions
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var found := 0
	for i in 20:
		var a := _dry_point(rng, 120.0)
		var z := _dry_point(rng, 120.0)
		if not ai_nav.find_path(a, z, 30000).is_empty():
			found += 1
	_gate_ok("paths across the city materialise nothing",
			registry.report().materialised == mat0 and _promotions == promos and found >= 15,
			"%d of 20 found, %d materialised before and after" % [found, mat0])
	if _terrain_mode:
		await _nav_terrain_gates(rng)

	# Fifty requesters at once, served from the scheduler's share.
	_nav_worst_us = 0
	ai_nav.reset_stats()
	var ids := []
	for i in 50:
		var a := _dry_near(rng, street)
		var z := _dry_near(rng, street)
		ids.append(ai_nav.request_path(a, z, rng.randf() * 10.0))
	var frames := 0
	while ai_nav.pending() > 0 and frames < 600:
		await get_tree().physics_frame
		frames += 1
	var answered := 0
	for id in ids:
		if ai_nav.get_status(id) != AINav.PENDING:
			answered += 1
	print("[nav]   %s" % ai_nav.get_stats())
	var found_paths := 0
	for id in ids:
		if ai_nav.get_status(id) == AINav.DONE:
			found_paths += 1
	_gate_ok("fifty requesters answered inside the nav budget",
			answered == 50 and _nav_worst_us < NAV_BUDGET_US + 400,
			"%d answered (%d found) in %d tick(s); worst tick %d us against %d" % [
			answered, found_paths, frames, _nav_worst_us, NAV_BUDGET_US])
	_ai_label.visible = true
	_update_ai_label()
	camera.position = b.xform * Vector3(fx * 0.5 + 18.0, 20.0, fz + 14.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, 3.0, fz * 0.5), Vector3.UP)
	await _frames(20)
	await _save("city_nav")
	print("[nav] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


var _last_wait := 0


## Blow a hole at `at`, and once the blast has been committed (and the columns
## it touched forgotten), queue a path. Returns the request once it is answered.
func _path_after_blast(at: Vector3, from: Vector3, to: Vector3) -> int:
	var n0 := authority.commands.size()
	_blast(at, 1.3)
	var id := -1
	_last_wait = 0
	while _last_wait < 600:
		await get_tree().physics_frame
		_last_wait += 1
		if id < 0 and _damage_queue.is_empty() and authority.commands.size() > n0:
			id = ai_nav.request_path(from, to, 5.0)
		if id >= 0 and ai_nav.get_status(id) != AINav.PENDING:
			break
	return id


func _passes(p: PackedVector3Array, point: Vector3) -> bool:
	for i in range(1, p.size()):
		var a: Vector3 = p[i - 1]
		var b: Vector3 = p[i]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var t := 0.0
		if ab.length_squared() > 0.0:
			t = clampf(Vector2(point.x - a.x, point.z - a.z).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var q := a.lerp(b, t)
		# Through the hole, not over it: within half a metre of its height,
		# which on terrain is wherever the building's floor is.
		if Vector2(q.x - point.x, q.z - point.z).length() < 1.6 and q.y < point.y + 0.5:
			return true
	return false


func _path_len(p: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, p.size()):
		total += p[i - 1].distance_to(p[i])
	return total


func _draw_path(p: PackedVector3Array, col: Color) -> void:
	if p.size() < 2:
		return
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.no_depth_test = true
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for q in p:
		im.surface_add_vertex(q + Vector3.UP * 0.3)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	add_child(mi)


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


## The P8 population round `center` (the --stress --agents pass): six squads of
## six in a ring 30-60 m out, three flyers, a herd, and 300 swarm rows 50-80 m
## out -- all after one player-side body at `center` (the player's pawn if it
## is out, a stand-in otherwise). The ImportanceBudget keeps ten smart.
func _spawn_many(center: Vector3) -> void:
	if ai_services.world3d == null:
		ai_services.world3d = get_world_3d()
		ai_services.on_structure_hit = _gun.on_structure_hit
	budget = ImportanceBudget.new()
	var target := _player_pawn
	if target == null or not is_instance_valid(target):
		target = Pawn.spawn(self, ai_nav.snap(_on_ground(center)), 0, true, 1e7)
		Soldier._greybox(target, 0)
		ai_services.add_pawn(target)
	_many_target = target
	budget.players = [target]
	var rng := RandomNumberGenerator.new()
	rng.seed = 88
	for q in 6:
		var ang := TAU * q / 6.0
		var at := center + Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(30.0, 60.0)
		var members: Array[Soldier] = []
		for i in 6:
			var so := _spawn_soldier(ai_nav.snap(_on_ground(at + Vector3((i % 3) * 1.5, 0.0, floori(i / 3.0) * 1.5))))
			members.append(so)
			budget.add(so)
		squads.append(Squad.make(ai_services, self, members, 1))
		_many.soldiers += 6
	if _gun_library == null:
		_gun_library = GunPlaceholderParts.build_library()
	for i in 3:
		var ang := TAU * i / 3.0
		var g := GunInstance.from_result(GunGenerator.generate(_gun_library, _combat_rng.randi(),
				WeaponClass.builtin(&"rifle"), 1))
		var f := Flyer.spawn(ai_services, self, _on_ground(center + Vector3(cos(ang), 0.0, sin(ang)) * 40.0)
				+ Vector3.UP * 30.0, 1, g)
		budget.add(f)
		_many.flyers += 1
	var home := center + Vector3(-25.0, 0.0, -20.0)
	var herd := AnimalPack.new(ai_services, -1, _on_ground(home), 5)
	for i in 5:
		budget.add(Animal.spawn(ai_services, self, ai_nav.snap(_on_ground(home + Vector3(i * 1.5, 0.0, 0.0))),
				herd, 60.0, 400 + i if i < 2 else -1))
		_many.animals += 1
	var pts := PackedVector3Array()
	for i in 300:
		var ang := rng.randf() * TAU
		pts.append(_on_ground(center + Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(50.0, 80.0)))
	swarm = SwarmSide.new()
	swarm.boxes = func() -> Array:
		var out := []
		for id in _near_buildings(center, 150.0):
			var b := registry.get_building(id)
			if b != null and not b.toppled:
				out.append(_world_box(b))
		return out
	swarm.spawn_promoted = func(pos: Vector3, hp: float) -> Object:
		var pack := AnimalPack.new(ai_services, 1, pos, _many.hunters)
		var an := Animal.spawn(ai_services, self, ai_nav.snap(pos), pack, maxf(hp, 1.0), -1,
				AgentTier.DIRECTED)
		an.swarm_born = true
		pack.hunt(_many_target)
		budget.add(an)
		_many.hunters += 1
		return an
	swarm.node_room = func() -> int:
		return ImportanceBudget.SMART_CAP + ImportanceBudget.DIRECTED_CAP - budget.agents.size()
	swarm.setup(ai_services, self, 1, pts, 40.0, 17)
	swarm.refresh()
	budget.demote_to_swarm = swarm.demote
	print("[city] %d soldiers, %d flyers, %d animals, %d swarm rows round %v" % [_many.soldiers,
			_many.flyers, _many.animals, swarm.alive(), center])


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


## The squad gate (AIPlan P6): a tower is sealed at street level, so a squad told
## to clear a ground-floor room blows its own door (mouse-holing, AI.md 6.2)
## through the authority, stacks either side of it, flashes the room, goes in
## crisscross, drops whoever is in there, and reports the room clear. The blast
## is in the log, so the twins replay the hole.
func _run_squad_pass() -> void:
	print("[squad] a squad clears a room in a sealed tower")
	var b := registry.get_building(0)
	for c in registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var fx: float = b.recipe.footprint_x * STUD
	var _fz: float = b.recipe.footprint_z * STUD
	camera.position = b.xform * Vector3(fx * 0.5, 14.0, -16.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, 1.0, 2.0), Vector3.UP)
	var enc := start_encounter(_world_box(b).grow(6.0))
	var guard := 0
	while not enc.is_ready() and guard < 300:
		await _frames(1)
		guard += 1
	await _frames(20)
	# A ground-storey room against the street wall (-Z).
	var cell := BrickWorld.get_cell_size()
	var pick: Room = null
	for r in registry.rooms_of(b.id):
		if r.lo.z > TowerRecipe.WALL_THICK + RoomManifest.WALL_MARGIN:
			continue
		if pick == null or r.lo.y < pick.lo.y or (r.lo.y == pick.lo.y and r.size.x > pick.size.x):
			pick = r
	_gate_ok("the tower has a ground-storey room on the street", pick != null)
	if pick == null:
		get_tree().quit(1)
		return
	var box := AABB(Vector3(pick.lo) * cell, Vector3(pick.size) * cell)
	var room := RoomTactics.make(b.xform, box, pick.id)
	# Somebody in there, whom nobody has seen.
	var inside := ai_nav.snap(b.xform * (box.position + box.size * Vector3(0.5, 0.0, 0.7)))
	var defender := Pawn.spawn(self, inside, 0, true, 100.0)
	Soldier._greybox(defender, 0)
	ai_services.add_pawn(defender)
	var street := _on_ground(b.xform * Vector3(box.get_center().x, 0.0, -9.0))
	var q := _spawn_squad(street)
	await _frames(10)
	var n0 := authority.commands.size()
	var o := SquadMsg.Order.make(SquadMsg.OrderKind.CLEAR_ROOM)
	o.room = room
	o.wall_thick = TowerRecipe.WALL_THICK * STUD
	var oid := q.give(o)
	var t0 := Engine.get_physics_frames()
	var inside_n := {}
	var done: SquadMsg.Report = null
	while done == null and Engine.get_physics_frames() - t0 < 30 * 90:
		await get_tree().physics_frame
		for m in q.members:
			if room.contains(m.pawn.feet()):
				inside_n[m.get_instance_id()] = true
		for r in q.reports:
			if r.order_id == oid and r.kind != SquadMsg.ReportKind.ACCEPTED:
				done = r
	var secs := float(Engine.get_physics_frames() - t0) / 30.0
	var blasts := 0
	for i in range(n0, authority.commands.size()):
		if authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	print("[squad] events %s" % [q.events.keys()])
	_gate_ok("no door, so it makes one: a BLAST through the authority",
			bool(q.events.get("breach", false)) and q.events.has("breached") and blasts >= 1,
			"%d BLAST(s)" % blasts)
	_gate_ok("it stacks, flashes the room and goes in", q.events.has("stacked")
			and q.events.has("flashed") and inside_n.size() >= 3,
			"%d of 4 went in" % inside_n.size())
	_gate_ok("the room is cleared and the order reported DONE",
			done != null and done.kind == SquadMsg.ReportKind.DONE and defender.health.is_dead(),
			"%s in %.1f s; defender %s" % [done, secs, "down" if defender.health.is_dead() else "UP"])
	var said := {}
	for l in ai_services.callouts.said:
		said[l[2]] = true
	print("[squad] said %s" % [said.keys()])
	# The picture: the hole it made, from the street.
	var hole: Vector3 = q.events.get("opening", street)
	var back := street - hole
	back.y = 0.0
	camera.position = hole + back.normalized() * 7.0 + Vector3.UP * 2.5
	camera.look_at(hole + Vector3.UP * 0.9, Vector3.UP)
	await _frames(30)
	await _save("city_squad")
	_check_log_replays()
	print("[squad] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## The fall rule in the city (Docs/AI.md 3.11, AIPlan P7): a mech dropped twelve
## bricks onto a tower's roof goes through three floors -- each a SHEAR the host
## commits -- and stops on the fourth down; the pieces it broke land without
## breaking anything more; and the log's twin buildings replay every break.
func _run_mechfall_pass() -> void:
	print("[mechfall] a mech dropped onto a tower")
	var b := registry.get_building(0)
	for c in registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var enc := start_encounter(_world_box(b).grow(4.0))
	var guard := 0
	while not enc.is_ready() and guard < 300:
		await _frames(1)
		guard += 1
	await _frames(20)
	# Over the middle of the biggest room of the top storey: over floor, not a
	# column or a wall.
	var cell := BrickWorld.get_cell_size()
	var pick: Room = null
	for r in registry.rooms_of(b.id):
		if pick == null or r.lo.y > pick.lo.y or (r.lo.y == pick.lo.y
				and r.size.x * r.size.z > pick.size.x * pick.size.z):
			pick = r
	var mid := b.xform * ((Vector3(pick.lo) + Vector3(pick.size) * Vector3(0.5, 0.0, 0.5)) * cell)
	# The roof's surface there -- the highest under the mech's footprint, which is
	# what it lands on. top_at is only a bound (the parapet is above it), and a
	# roof has openings.
	var roof := -INF
	var high := ai_world.top_at(mid.x, mid.z) + 1.0
	for r in [0.0, Mech.RADIUS * 0.5, Mech.RADIUS * 0.9]:
		for k in (1 if r == 0.0 else 8):
			var a := k * TAU / 8.0
			roof = maxf(roof, _next_floor_below(Vector3(mid.x + cos(a) * r, high, mid.z + sin(a) * r)))
	camera.position = Vector3(mid.x + 18.0, roof + 4.0, mid.z - 18.0)
	camera.look_at(Vector3(mid.x, roof - 6.0, mid.z), Vector3.UP)
	var n0 := authority.commands.size()
	var feet := Vector3(mid.x, roof + 12.0 * FallRule.BRICK + 0.02, mid.z)
	var m := Mech.spawn(self, feet, 0.0, 1)
	_wire_mech(m)
	_loose_mechs.append(m)
	var t0 := Engine.get_physics_frames()
	var still := 0
	while still < 30 and Engine.get_physics_frames() - t0 < 30 * 12:
		await get_tree().physics_frame
		still = still + 1 if m.body.is_on_floor() and not m.fall.is_carrying() else 0
	var shears := 0
	for i in range(n0, authority.commands.size()):
		var e: DamageLog.Entry = authority.commands.entries[i]
		if e.kind == DamageLog.Kind.SHEAR and e.flags & DamageLog.FLAG_WHOLE:
			shears += 1
	var judged := m.fall.landings.map(func(l): return "%.1f%s" % [float(l[1]), "!" if l[2] else ""])
	var storeys := (roof - m.feet().y) / ((TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * PLATE)
	_gate_ok("dropped twelve bricks onto the roof, it goes through three floors",
			m.fall.breaks == 3 and shears == 3,
			"%d broken, %d SHEAR(s); landings (bricks of energy) %s" % [m.fall.breaks, shears, judged])
	_gate_ok("and stands on the floor three storeys down", absf(storeys - 3.0) < 0.35
			and m.body.is_on_floor(), "%.2f storeys under the roof" % storeys)
	# The picture: down through the holes it made.
	camera.position = Vector3(mid.x + 4.0, roof + 12.0, mid.z + 4.0)
	camera.look_at(m.feet() + Vector3.UP * 3.0, Vector3.UP)
	await _frames(60)
	await _save("city_mechfall")
	_check_log_replays()
	print("[mechfall] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## The vertical slice (AIPlan P4): a soldier in the city, against the player's
## pawn in a street. It sees and fires; its misses wear the buildings through the
## WorldAuthority like anybody's; it never fires through a wall; and the log --
## its rounds in it -- still replays into the same city.
func _run_soldier_pass() -> void:
	print("[soldier] one soldier in the city")
	var b := registry.get_building(0)
	var fx: float = b.recipe.footprint_x * STUD
	var street := ai_nav.snap(b.xform * Vector3(fx * 0.5, 0.0, -3.0))
	camera.global_position = street + Vector3(0.0, 6.0, 0.0)
	_enter_pawn(street)
	_player.drive_uncaptured = true
	_player_pawn.health.layer_configs[0].max_value = 100000.0
	_player_pawn.health.reset()
	camera.rotation = Vector3(0.0, 0.0, 0.0)   # the player looks down -Z, out of the street
	await _frames(20)
	var spot := ai_nav.snap(street + Vector3(0.0, 0.0, -18.0))
	var so := _spawn_soldier(spot)
	so.pawn.intents.look_yaw = PI   # toward the player
	var n0 := authority.commands.size()
	var hp0 := _player_pawn.health.total_current()
	var t0 := Engine.get_physics_frames()
	while Engine.get_physics_frames() - t0 < 30 * 16:
		await get_tree().physics_frame
	var chips := 0
	for i in range(n0, authority.commands.size()):
		if authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	_gate_ok("the soldier sees the player's pawn and fires", so.shots > 5
			and _player_pawn.health.total_current() < hp0,
			"%d round(s); %.0f hp taken; now %s" % [so.shots, hp0 - _player_pawn.health.total_current(), so.state])
	_gate_ok("its misses wear the city through the authority", chips > 0, "%d CHIP(s)" % chips)
	_gate_ok("it never fired through a wall", so.blocked_shots == 0,
			"%d of %d" % [so.blocked_shots, so.shots])
	_leave_pawn()
	camera.global_position = spot + Vector3(-4.0, 3.0, -6.0)
	camera.look_at(street + Vector3.UP, Vector3.UP)
	await _frames(10)
	await _save("city_soldier")
	_check_log_replays()
	print("[soldier] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


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


## The gate for wreckage weight in the city (Docs/AIPlan.md P5): a tower's top
## cut free comes to rest on what is left of it, and its weight goes onto the
## bricks it lies on -- a LOAD command, applied and solved on the host, replayed
## by the twin buildings of the log check like everything else.
var _breaklag_mode := false


## How long a break takes to show. Reported: a break, then pieces that do
## nothing for a few frames or vanish, and nothing falling for about a second.
## A building is shot through as a player would -- its ground storey's walls
## all round, or the whole storey -- and every physics tick after the first blast
## is watched: the damage still queued, the buildings waiting for a solve, rounds
## the collapse director held, and the pieces: when the first is cut out, when
## the BIGGEST is (the building's body, which is what is seen hanging), when
## they are drawn and when they move. Two ordinary buildings and the biggest
## there is (a mega one in the big city: -- --breaklag --big).
func _run_breaklag_pass() -> void:
	print("[breaklag] a break, and how long before anything moves")
	var biggest: BuildingRegistry.Building = null
	var ordinary: Array = []
	for c in registry.buildings:
		if c.is_build():
			continue
		var size: int = c.recipe.courses * c.recipe.footprint_x * c.recipe.footprint_z
		if biggest == null or size > biggest.recipe.courses * biggest.recipe.footprint_x \
				* biggest.recipe.footprint_z:
			biggest = c
		if c.recipe.courses >= 12 and c.recipe.courses <= 30 and ordinary.size() < 3:
			ordinary.append(c)
	# The first shot at a building that is still a shell: it is made bricks by
	# the shot, and drawn by its shell until its bands are up.
	var shell: BuildingRegistry.Building = null
	for c in registry.buildings:
		if c.is_build() or c.is_materialised() or ordinary.has(c) or c == biggest:
			continue
		if shell == null or absi(c.recipe.courses - 24) < absi(shell.recipe.courses - 24):
			shell = c
	if shell != null:
		await _shell_lag(shell)
	# Another shell, aimed at before it is shot (_aim_promote).
	var aimed: BuildingRegistry.Building = null
	for c in registry.buildings:
		if c.is_build() or c.is_materialised() or ordinary.has(c) or c == biggest or c == shell:
			continue
		aimed = c
		break
	if aimed != null:
		await _aim_check(aimed)
	# And one a falling piece is about to land on (_path_promote).
	var under: BuildingRegistry.Building = null
	for c in registry.buildings:
		if c.is_build() or c.is_materialised() or ordinary.has(c) or c == biggest \
				or c == shell or c == aimed:
			continue
		under = c
		break
	if under != null:
		await _path_check(under)
	# On a building of its own: the walls case below wants one nothing has hit.
	if ordinary.size() > 2:
		await _proxy_check(ordinary[2])
		await _far_shell_check(ordinary[2], true)
	if ordinary.size() > 0:
		await _break_lag(ordinary[0], false)
	if ordinary.size() > 1:
		await _break_lag(ordinary[1], true)
		await _far_shell_check(ordinary[1], false)
	if biggest != null and not ordinary.has(biggest):
		# A third of the way up: what is above falls on what is below, rather
		# than the whole tower toppling off its stump.
		await _break_lag(biggest, true,
				TowerRecipe.total_plates(biggest.recipe.courses) * PLATE / 3.0)
	print("[breaklag] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


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
			if not dead.has(bid):
				live.append([fi, k, bid])
	if live.is_empty():
		return out
	var ids := PackedInt32Array()
	for e in live:
		ids.append(int(e[2]))
	var storey := (TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * BrickPalette.PLATE_M
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


## A building's shadow proxy (_stream_shadows) is built on a worker now: it has
## to turn up, and to catch up with a hit once the building has stopped losing
## bricks.
func _proxy_check(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	camera.position = b.xform * Vector3(fx * 0.5 + 30.0, 20.0, -30.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, 6.0, fz * 0.5), Vector3.UP)
	_promote(b.id)
	var t := 0
	while t < 90 and not _proxy_drawn(b.id):
		await get_tree().physics_frame
		t += 1
	_gate_ok("building %d: its shadow proxy is up" % b.id, _proxy_drawn(b.id),
			"after %d tick(s)" % t)
	_blast(b.xform * Vector3(fx * 0.5, 4.0, 0.0), 1.5)
	await _frames(10)
	t = 0
	while t < 150 and not (_proxy_drawn(b.id) and not _shadow_jobs.has(b.id)
			and int(_shadow_proxy_alive.get(b.id, -1)) == world.get_alive_block_count(b.chunk)):
		await get_tree().physics_frame
		t += 1
	# And a hit that leaves its floors standing leaves its stairs (_sweep_stairs
	# cuts out only flights whose storey has gone). Past a sweep or two first.
	await _frames(STAIR_SWEEP_TICKS * 3)
	var stairs_all := 0
	var stairs_live := 0
	var gone := {}
	for d in world.get_dead_blocks(b.chunk):
		gone[d] = true
	for d in world.get_detached_blocks(b.chunk):
		gone[d] = true
	for f in b.fixtures:
		if f.kind == "staircase":
			for bid in f.blocks:
				stairs_all += 1
				if not gone.has(bid):
					stairs_live += 1
	_gate_ok("building %d: its stairs stand while its floors do" % b.id,
			stairs_all > 0 and stairs_live == stairs_all, "%d of %d" % [stairs_live, stairs_all])
	_gate_ok("building %d: and it catches up with a hit" % b.id,
			_proxy_drawn(b.id) and int(_shadow_proxy_alive.get(b.id, -1))
					== world.get_alive_block_count(b.chunk),
			"built from %d bricks, %d alive, after %d tick(s)" % [
				int(_shadow_proxy_alive.get(b.id, -1)), world.get_alive_block_count(b.chunk), t])


## A building still in bricks gives its mesh up past DEMESH_RANGE and stands in
## as a shell (_demesh). That shell has to be drawn from the damage its bricks
## have now -- nothing, if none are left -- and take a hit while it is far. It
## used to be drawn from the profile of the last time the building was given
## back: a building damaged since came back whole at range, and went again up
## close, which is what "buildings respawning" was.
func _far_shell_check(b: BuildingRegistry.Building, hit_it: bool) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	camera.global_position = b.xform.origin + Vector3(0.0, 40.0,
			-(DEMESH_RANGE + DEMESH_HYSTERESIS + 30.0))
	camera.look_at(b.xform.origin + Vector3(0.0, 10.0, 0.0), Vector3.UP)
	var t := 0
	while t < 300 and not (_shells.has(b.id) and not _brick_nodes.has(b.id)):
		await get_tree().physics_frame
		t += 1
	_gate_ok("building %d: far off, a shell stands in for it" % b.id,
			_shells.has(b.id) and not _brick_nodes.has(b.id), "after %d tick(s)" % t)
	_gate_ok("building %d: drawn with the damage it has, not what it had" % b.id,
			_far_shell_true(b), _far_shell_note(b))
	if not hit_it or not b.is_materialised() or world.get_alive_block_count(b.chunk) == 0:
		return
	var before := world.get_alive_block_count(b.chunk)
	_blast(b.xform * Vector3(fx * 0.5, 6.0, 0.0), 2.0)
	t = 0
	while t < 150 and (world.get_alive_block_count(b.chunk) == before or not _far_shell_true(b)):
		await get_tree().physics_frame
		t += 1
	_gate_ok("building %d: and a hit taken while far shows on it" % b.id,
			world.get_alive_block_count(b.chunk) < before and _far_shell_true(b),
			"%d -> %d bricks; %s" % [before, world.get_alive_block_count(b.chunk), _far_shell_note(b)])


## Vertices the shell draws, and what it should: from the bricks while it has
## them, from the profile once it has given them back.
func _far_shell_counts(b: BuildingRegistry.Building) -> Array:
	var got := 0
	var mi = _shells.get(b.id)
	if is_instance_valid(mi) and (mi as MeshInstance3D).mesh != null \
			and (mi as MeshInstance3D).mesh.get_surface_count() > 0:
		got = ((mi as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				as PackedVector3Array).size()
	var r: Dictionary = b.recipe
	var profile: Dictionary = b.damage_profile
	var want := 0
	if b.is_materialised():
		profile = registry.live_damage_profile(b.id)
		if world.get_alive_block_count(b.chunk) == 0:
			return [got, 0, -1]
	want = (BuildingShell.build_arrays(int(r.footprint_x), int(r.footprint_z), int(r.courses),
			profile)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var whole := (BuildingShell.build_arrays(int(r.footprint_x), int(r.footprint_z),
			int(r.courses), {})[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return [got, want, whole]


func _far_shell_true(b: BuildingRegistry.Building) -> bool:
	var n := _far_shell_counts(b)
	return int(n[0]) == int(n[1])


func _far_shell_note(b: BuildingRegistry.Building) -> String:
	var n := _far_shell_counts(b)
	return "%d vertices drawn, %d from its damage, %s whole" % [n[0], n[1],
			"n/a" if int(n[2]) < 0 else str(n[2])]


func _proxy_drawn(id: int) -> bool:
	var mi = _shadow_proxy.get(id)
	return is_instance_valid(mi) and (mi as MeshInstance3D).mesh != null \
			and (mi as MeshInstance3D).mesh.get_surface_count() > 0


## A slab dropped from twenty-five metres onto a shell: by the time it lands
## the building is bricks with its bands drawn, so the landing shows on it.
func _path_check(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	var top: float = TowerRecipe.total_plates(b.recipe.courses) * PLATE
	var centre: Vector3 = b.xform * Vector3(fx * 0.5, top, fz * 0.5)
	camera.global_position = centre + Vector3(0.0, 10.0, 0.0) \
			+ (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized() * (fz * 0.5 + 35.0)
	# Looking AWAY: aimed at, it would be made bricks for that (_aim_promote),
	# and this is about the piece.
	camera.look_at(camera.global_position * 2.0 - centre, Vector3.UP)
	await _frames(4)
	var c := world.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(6, 6, 3))
	TowerRecipe.build(world, c, palette, 6, 6, 3)
	world.set_chunk_transform(c, Transform3D(Basis(), centre + Vector3(-1.0, 25.0, -1.0)))
	var ids := PackedInt32Array()
	for id in world.get_block_count(c):
		ids.append(id)
	var p0 := path_promotions
	var piece := islands.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	world.release_chunk(c)
	if piece == null:
		_gate_ok("a slab to drop on building %d" % b.id, false)
		return
	var start := piece.body.global_position
	var promoted_at := -1
	var t := 0
	while t < 240 and piece.is_valid() and not piece.landed:
		await get_tree().physics_frame
		t += 1
		if promoted_at < 0 and b.is_materialised():
			promoted_at = t
	print("[breaklag]   slab: %d bricks, %s, from %s to %s; building box %s; made bricks at tick %d, landed %d" % [
			world.get_alive_block_count(piece.chunk) if piece.is_valid() else -1,
			"landmark" if piece.landmark else ("rubble" if piece.disposable else "piece"),
			start, piece.body.global_position if piece.is_valid() else Vector3.ZERO,
			_world_box(b), promoted_at, t])
	_gate_ok("building %d: a slab falling on it made it bricks, drawn, before it landed" % b.id,
			b.is_materialised() and not _shells.has(b.id) and path_promotions > p0,
			"landed after %d tick(s); materialised %s, shell %s, %d promoted from a path" % [
				t, b.is_materialised(), _shells.has(b.id), path_promotions - p0])


## Aimed at from past PROMOTE_RANGE, a shell is bricks with its bands drawn
## before the shot: the first hit shows the tick it lands.
func _aim_check(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	# A side and a distance, past PROMOTE_RANGE, with nothing between the
	# camera and the wall: a city block is dense, and the ray takes the first
	# building it meets (the one really aimed at).
	var face := Vector3.ZERO
	var found := false
	for side in [[Vector3(fx * 0.5, 3.0, 0.0), Vector3(0, 0, -1)], [Vector3(fx * 0.5, 3.0, fz), Vector3(0, 0, 1)],
			[Vector3(0.0, 3.0, fz * 0.5), Vector3(-1, 0, 0)], [Vector3(fx, 3.0, fz * 0.5), Vector3(1, 0, 0)]]:
		for dist in [35.0, 45.0, 60.0, 80.0]:
			var f: Vector3 = b.xform * (side[0] as Vector3)
			var out: Vector3 = b.xform.basis * (side[1] as Vector3)
			var at: Vector3 = Vector3(f.x, 3.0, f.z) + out * dist
			var hit := get_world_3d().direct_space_state.intersect_ray(
					PhysicsRayQueryParameters3D.create(at, f + (f - at).normalized() * 2.0,
					Layers.WORLD | Layers.STRUCTURE))
			if not hit.is_empty() and _building_for_body(hit.rid) == b.id:
				camera.global_position = at
				camera.look_at(f, Vector3.UP)
				face = f
				found = true
				break
		if found:
			break
	if not found:
		print("[breaklag] no clear view of building %d; aim check skipped" % b.id)
		return
	var t := 0
	while t < 120 and not (b.is_materialised() and not _shells.has(b.id)):
		await get_tree().physics_frame
		t += 1
	_gate_ok("building %d: aimed at from 60 m, it is bricks, drawn, before the shot" % b.id,
			b.is_materialised() and not _shells.has(b.id), "after %d tick(s)" % t)
	# The shot, then: on bricks already drawn.
	var n0 := authority.commands.size()
	chip(face, 0.3, 60)
	await _frames(4)
	_gate_ok("building %d: and the shot lands on bricks already drawn" % b.id,
			b.is_materialised() and not _shells.has(b.id) and authority.commands.size() > n0)


## A building still drawn as its shell, its ground storey blown out: how long
## until the shot is SEEN on it -- the shell gone, its bands up -- and that no
## piece comes out of it before then. The shell draws the building whole, so a
## piece cut out earlier fell out of a wall that went on showing it.
func _shell_lag(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	camera.position = b.xform * Vector3(fx * 0.5 + 30.0, 20.0, -30.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, 6.0, fz * 0.5), Vector3.UP)
	await _frames(2)
	var was_shell := _shells.has(b.id) and not b.is_materialised()
	var known := {}
	for isl in islands.islands:
		known[isl] = true
	var x := 0.0
	while x <= fx + 0.01:
		var z := 0.0
		while z <= fz + 0.01:
			_blast(b.xform * Vector3(x, 1.2, z), 2.2)
			z += 2.5
		x += 2.5
	var materialised_at := -1
	var cut_at := -1
	var shell_gone_at := -1
	var t := 0
	var timeline: Array[String] = []
	while t < 240 and (shell_gone_at < 0 or cut_at < 0 or t < shell_gone_at + 10):
		await get_tree().physics_frame
		t += 1
		var fresh := 0
		for isl in islands.islands:
			if not known.has(isl) and isl.is_valid():
				fresh += 1
		if b.is_materialised() and materialised_at < 0:
			materialised_at = t
		var shelled := _shells.has(b.id)
		if materialised_at > 0 and not shelled and shell_gone_at < 0:
			shell_gone_at = t
		if fresh > 0 and cut_at < 0:
			cut_at = t
		if t <= 30 or t % 10 == 0:
			timeline.append("%d: materialised %s, shell %s, bands building %s, redo %s, pieces %d" % [
					t, b.is_materialised(), shelled, b.is_materialised() and _bands_building(b.id),
					_band_redo.has(b.id), fresh])
	print("[breaklag] building %d, a shell when shot (%s), %d bricks:" % [b.id, was_shell,
			world.get_block_count(b.chunk) if b.is_materialised() else 0])
	for line in timeline:
		print("[breaklag]   " + line)
	print("[breaklag]   made bricks at tick %d, the shell gone at %d, first piece cut out %d" % [
			materialised_at, shell_gone_at, cut_at])
	_gate_ok("building %d: a shot shell shows the shot within 15 ticks" % b.id,
			shell_gone_at > 0 and shell_gone_at <= 15, "shell gone at %d" % shell_gone_at)
	_gate_ok("building %d: and nothing comes out of it while the shell still shows it whole" % b.id,
			cut_at < 0 or shell_gone_at < 0 or cut_at >= shell_gone_at,
			"first piece %d, shell gone %d" % [cut_at, shell_gone_at])
	await _frames(60)


## `storey`: the whole storey blown out; otherwise its walls all round. At
## height `y` -- the ground storey unless told.
func _break_lag(b: BuildingRegistry.Building, storey: bool, y := 1.2) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	camera.position = b.xform * Vector3(fx * 0.5 + 30.0, 20.0, -30.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, y + 5.0, fz * 0.5), Vector3.UP)
	_promote(b.id)
	await _frames(40)
	var bricks := world.get_block_count(b.chunk)
	var known := {}
	for isl in islands.islands:
		known[isl] = true
	var held0 := director.held_rounds
	var blasts := 0
	var step := 2.5
	var x := 0.0
	while x <= fx + 0.01:
		var z := 0.0
		while z <= fz + 0.01:
			var wall := x < 0.01 or z < 0.01 or x > fx - step or z > fz - step
			if storey or wall:
				_blast(b.xform * Vector3(minf(x, fx), y, minf(z, fz)), 2.2 if storey else 2.0)
				blasts += 1
			z += step
		x += step
	var cut_at := -1
	var drawn_at := -1
	var moving_at := -1
	var gone_at := -1
	var biggest_at := -1
	var biggest := 0
	# Every piece as it is first seen: when, and how many bricks. Counted in
	# bricks, not boxes -- a piece that lands is split back into a box a brick,
	# and a child of it could "outgrow" the building's body. And only pieces
	# cut out while the building was still losing bricks: what comes off a
	# piece once it lands is not the break.
	var first_seen := {}   # island -> [tick, bricks]
	var last_loss := 0
	var alive_was := bricks
	# Small pieces are crumbs now (IslandManager._crumble): no body, and falling
	# from the tick they appear. They are what showed the break at once before,
	# as bodies, and still are.
	var crumbs0 := islands.crumbled
	var crumbs_at := -1
	var t := 0
	var timeline: Array[String] = []
	# Until nothing has changed for a second: the damage applied, what was
	# going to come away gone.
	var last_change := 0
	var last_state := ""
	while t < 240 and (t - last_change < 30 or not _damage_queue.is_empty()):
		await get_tree().physics_frame
		t += 1
		var fresh := 0
		var drawn := 0
		var fastest := 0.0
		for isl in islands.islands:
			if known.has(isl) or not isl.is_valid():
				continue
			fresh += 1
			if not islands.is_blind(isl):
				drawn += 1
			fastest = maxf(fastest, isl.body.linear_velocity.length())
			if not first_seen.has(isl):
				first_seen[isl] = [t, world.get_alive_block_count(isl.chunk)]
		if fresh > 0 and cut_at < 0:
			cut_at = t
		if drawn > 0 and drawn_at < 0:
			drawn_at = t
		if islands.crumbled > crumbs0 and crumbs_at < 0:
			crumbs_at = t
		if (fastest > 1.0 or crumbs_at >= 0) and moving_at < 0:
			moving_at = t
		var alive := world.get_alive_block_count(b.chunk) if b.is_materialised() else 0
		if gone_at < 0 and alive < int(bricks * 0.98):
			gone_at = t
		if alive != alive_was:
			alive_was = alive
			last_loss = t
		var state := "%d/%d" % [alive, fresh]
		if state != last_state:
			last_state = state
			last_change = t
		if t <= 30 or t % 10 == 0:
			timeline.append("%d: queue %d, dirty %d, held %d, alive %d, pieces %d (%d drawn), fastest %.1f m/s" % [
					t, _damage_queue.size(), _dirty.size(), director.held_rounds - held0,
					alive, fresh, drawn, fastest])
	for isl in first_seen:
		var seen: Array = first_seen[isl]
		if int(seen[0]) <= last_loss + 1 and int(seen[1]) > biggest:
			biggest = int(seen[1])
			biggest_at = int(seen[0])
	print("[breaklag] building %d, %d bricks (mega %s), %s at %.1f m, %d blasts:" % [b.id, bricks,
			CollapseDirector.is_mega(bricks), "the storey" if storey else "its walls", y, blasts])
	for line in timeline:
		print("[breaklag]   " + line)
	print("[breaklag]   bricks gone at tick %d; first piece cut out %d, the biggest (%d bricks) %d, drawn %d, moving %d (crumbs from %d, %d piece(s)); the director held %d round(s)" % [
			gone_at, cut_at, biggest, biggest_at, drawn_at, moving_at, crumbs_at,
			islands.crumbled - crumbs0, director.held_rounds - held0])
	_gate_ok("building %d: pieces move within 10 ticks of its bricks going" % b.id,
			moving_at > 0 and gone_at > 0 and moving_at - gone_at <= 10,
			"gone %d, moving %d" % [gone_at, moving_at])
	# Stairs go with their floors (_sweep_stairs): none left standing on its own
	# once the break is over. Given the sweep's time to come round.
	if b.is_materialised() and not b.fixtures.is_empty():
		var w := 0
		while w < STAIR_SWEEP_TICKS * 6 and not _orphan_stairs(b).is_empty():
			await get_tree().physics_frame
			w += 1
		var left := 0
		for r in _orphan_stairs(b):
			left += (r as PackedInt32Array).size()
		_gate_ok("building %d: no flight of stairs stands without its storey" % b.id,
				left == 0, "%d left standing alone" % left)
	# The body is let go with the first of them, not after the debris: it was
	# 13 ticks behind when two pieces went a tick, smallest first.
	if not CollapseDirector.is_mega(bricks):
		_gate_ok("building %d: and the biggest piece within 3 ticks of the first" % b.id,
				biggest_at > 0 and cut_at > 0 and biggest_at - cut_at <= 3,
				"first %d, biggest %d" % [cut_at, biggest_at])
	else:
		# A mega tower: when it comes down is the structure's -- what still
		# holds it, and when it tips -- as much as anything held back, so it
		# is reported, not judged. (The director's hold is HOLD_NEAR_MS where
		# somebody is watching.)
		print("[breaklag]   mega: the director held %d round(s); the biggest piece at tick %d" % [
				director.held_rounds - held0, biggest_at])
	await _frames(60)


func _run_wreck_pass() -> void:
	print("[wreck] a piece resting on a building loads it")
	var b := registry.get_building(0)
	for c in registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	camera.position = b.xform * Vector3(fx * 0.5 + 20.0, 25.0, -20.0)
	camera.look_at(b.xform * Vector3(fx * 0.5, 8.0, fz * 0.5), Vector3.UP)
	_promote(b.id)
	await _frames(20)
	# Cut the tower through at a storey's slab, as a collision would.
	# On the joint plane between the second storey's slab and the course above.
	var cut := b.xform * Vector3(fx * 0.5, (1 + 2 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * PLATE, fz * 0.5)
	if authority.request(DamageLog.Kind.SEVER, b.id, cut, 0.14, Vector3.UP):
		world.separate_plane(b.chunk, cut, Vector3.UP, 0.14)
		authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SEVER, b.id, cut, 0.14,
				Vector3.UP)
		_mark_dirty(b.id)
	var n0 := authority.commands.size()
	var landed: DamageLog.Entry = null
	var waited := 0
	while landed == null and waited < 30 * 20:
		await get_tree().physics_frame
		waited += 1
		for i in range(n0, authority.commands.size()):
			var e: DamageLog.Entry = authority.commands.entries[i]
			if e.kind == DamageLog.Kind.LOAD and e.target == b.id:
				landed = e
				break
	_gate_ok("the cut-free top comes to rest on the tower and loads it", landed != null,
			"%s" % ("%d brick(s) under %.1f each, after %d tick(s)" % [landed.points.size(),
			landed.radius, waited] if landed != null else "no LOAD in %d tick(s)" % waited))
	if landed != null:
		_gate_ok("the landed is on the building's solve",
				world.get_load_owners(b.chunk).has(landed.owner) and b.is_materialised(),
				"owners %s" % [world.get_load_owners(b.chunk)])
	await _frames(30)
	await _save("city_wreck")
	_check_log_replays()
	print("[wreck] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Does a building draw what it has, and nothing it has lost?
##
## A building's bands are index-patched when it is hit (_remesh), against a
## baseline of what they draw (BrickWorld.update_index_regions). The baseline
## was set by the first patch asked for -- after the hit it was for -- so that
## hit was never drawn: three big blasts into a wall left 3,467 of 9,516
## triangles drawn with no brick behind them, a staircase and walls floating in
## the hole, real to nobody's grid (user report, 2026-10-02). Each triangle is
## asked: a step inside it, along its normal, is a live brick? A shaped part
## (a spiral tread, a slope) answers no for a few of its own -- 246 of 15,106
## on this building whole -- so the measure has slack for that.
const DRAWN_SLACK := 0.02

func _run_drawn_pass() -> void:
	print("[drawn] a building draws the bricks it has, and none it has lost")
	# The recipe tower nearest thirty courses: the big city has none in the
	# twenties or thirties.
	var b: BuildingRegistry.Building = null
	for c in registry.buildings:
		if c.is_build():
			continue
		if b == null or absi(c.recipe.courses - 30) < absi(b.recipe.courses - 30):
			b = c
	var fx: float = b.recipe.footprint_x * STUD
	var face: Vector3 = b.xform * Vector3(fx * 0.5, 7.0, 0.0)
	var out: Vector3 = (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized()
	camera.global_position = face + out * 16.0 + Vector3(0.0, 2.0, 0.0)
	camera.look_at(face, Vector3.UP)
	await _frames(90)
	_gate_ok("building %d is bricks, its bands drawn" % b.id,
			b.is_materialised() and _brick_nodes.has(b.id) and not _bands_building(b.id))
	var before := _drawn_stale(b)
	_gate_ok("whole, it draws nothing but bricks", float(before[1]) <= float(before[0]) * DRAWN_SLACK,
			"%d of %d triangles with no brick behind them" % [before[1], before[0]])
	for shot in 3:
		_blast(face + Vector3(0.0, float(shot) * 2.5 - 2.0, 0.0) + out * 0.5, 5.8)
		await _frames(20)
	for t in 240:
		await get_tree().physics_frame
	await _frames(4)
	var after := _drawn_stale(b)
	_gate_ok("three big blasts into a wall later, it draws only what it has left",
			float(after[1]) <= float(after[0]) * DRAWN_SLACK,
			"%d of %d triangles with no brick behind them: %s" % [after[1], after[0], after[2]])
	# Furniture holds nothing up: its body is no layer a piece collides with.
	var furniture_ok := true
	for id in _room_bodies:
		if PhysicsServer3D.body_get_collision_layer(_room_bodies[id]) \
				& (Layers.FALLING_MASK | Layers.SETTLED_MASK | Layers.AIRBORNE_MASK):
			furniture_ok = false
	_gate_ok("and no piece can come to rest on furniture", furniture_ok,
			"%d furniture bodies" % _room_bodies.size())
	print("[drawn] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## The storey groups' gate (Docs/Interiors.md 8.2 and 8.7, stage 1).
##
##     godot --path . --resolution 1280x720 scenes/city.tscn -- --groups --big
##
## One tower seen through its windows from three ranges, drawn by the rungs and
## then by the storey groups: shots/interior_rungs_*.png beside
## shots/interior_groups_*.png. And what a screenshot does not show:
##
##   * a group is drawn by its own distance and by nothing else -- the rungs
##     draw nothing while the groups do, and a group past its range is not kept;
##   * collision is for the group the player is at, not for what is far off;
##   * a shot works out the groups at its height and leaves the rest alone;
##   * nothing of a group is left drawn in a section that has fallen;
##   * no group is made in a building that is coming apart, and the storeys
##     left standing get theirs once it is still (Docs/CollapseNext.md 1.8).
func _run_groups_pass() -> void:
	print("[groups] interiors by storey group")
	# The towers looked at keep their bricks at every range they are looked from.
	respawn_buildings = false
	var picks := _groups_pick(2)
	_gate_ok("two towers of eight storeys or more with a face nothing stands in front of",
			picks.size() == 2, "%d found" % picks.size())
	if picks.size() < 2:
		print("[groups] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
		get_tree().quit(1)
		return
	var b: BuildingRegistry.Building = picks[0][0]
	var face: Vector3 = picks[0][1]
	var out: Vector3 = picks[0][2]
	var eye := 8.0
	var ranges := [14.0, 50.0, 92.0]
	# Nothing over the picture, and the same 22 m of wall filling it from each
	# range (the lens narrowed, not the picture cropped): what changes between
	# the shots is how the interior is drawn, not how big it is.
	stats_label.visible = false
	if _reticle != null:
		_reticle.visible = false
	var fov_was := camera.fov
	_promote(b.id)
	for t in 600:
		await get_tree().physics_frame
		if _brick_nodes.has(b.id) and not _bands_building(b.id):
			break
	_gate_ok("building %d (%d storeys) is bricks, its bands drawn" % [b.id,
			int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR],
			b.is_materialised() and _brick_nodes.has(b.id) and not _bands_building(b.id))

	var layout: Array = interior_groups.layout(b)
	for k in ranges.size():
		_groups_look(face, out, ranges[k], eye)
		camera.fov = rad_to_deg(2.0 * atan(11.0 / float(ranges[k])))
		var took: int = await _groups_settle(b)
		var local: Vector3 = b.xform.affine_inverse() * camera.global_position
		var in_range := 0
		var shown := 0
		var kept_past := 0
		var boxes := 0
		var covered := 0
		var cover_boxes := 0
		var cover_shapes := 0
		var shadowed := 0
		for g in layout:
			var d := _box_distance(g.box, local)
			if d <= InteriorGroups.INTERIOR_RANGE:
				in_range += 1
				if g.shown and not g.dirty and not g.changed:
					shown += 1
			elif d > InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE and g.shown:
				kept_past += 1
			if g.shown:
				boxes += g.piece_count
				if g.shadows:
					shadowed += 1
			if g.cover:
				covered += 1
				for room_boxes in g.boxes:
					for box in (room_boxes as Array):
						if (box as AABB).size != Vector3.ZERO:
							cover_boxes += 1
				cover_shapes += (_group_shapes.get(InteriorGroups.key_of(b.id, g.index),
						PackedInt32Array()) as PackedInt32Array).size()
		print("[groups] from %.0f m: %d of %d group(s) in range and drawn after %d tick(s), %d box(es); %d with collision, %d casting shadows" % [
				ranges[k], shown, layout.size(), took, boxes, covered, shadowed])
		_gate_ok("from %.0f m: every storey group within %.0f m is drawn and up to date, none kept past it" % [
				ranges[k], InteriorGroups.INTERIOR_RANGE],
				in_range > 0 and shown == in_range and kept_past == 0,
				"%d in range, %d drawn, %d kept past" % [in_range, shown, kept_past])
		if k == 0:
			print("[groups]   %d of its %d group(s) are past the range from its foot, and not drawn" % [
					layout.size() - in_range, layout.size()])
			_gate_ok("  every interior piece of those storeys is in it once",
					boxes > 0 and boxes == _groups_expected_boxes(b, layout),
					"%d box(es), %d part(s) in the rooms' manifests" % [boxes, _groups_expected_boxes(b, layout)])
			_gate_ok("  the group at the player's height has a collision box a piece",
					covered >= 1 and cover_boxes > 0 and cover_shapes == cover_boxes,
					"%d group(s), %d piece(s), %d shape(s)" % [covered, cover_boxes, cover_shapes])
			var met := false
			var chunk_xf := world.get_chunk_transform(b.chunk)
			for g in layout:
				if not g.cover or met:
					continue
				for room_boxes in g.boxes:
					if (room_boxes as Array).is_empty():
						continue
					var q := PhysicsRayQueryParameters3D.create(camera.global_position,
							chunk_xf * (room_boxes[0] as AABB).get_center())
					q.collision_mask = Layers.FIXTURE
					var hit := get_world_3d().direct_space_state.intersect_ray(q)
					met = not hit.is_empty() and hit.rid == _room_bodies.get(b.id, RID())
					break
			_gate_ok("  and something aimed at a piece meets it", met)
			_gate_ok("  near, the pieces cast shadows", shadowed >= 1)
		if k == ranges.size() - 1:
			_gate_ok("  from here it is drawn with no collision and no shadows",
					shown > 0 and covered == 0 and shadowed == 0,
					"%d drawn, %d with collision, %d casting" % [shown, covered, shadowed])
		await _frames(2)
		await _save("interior_groups_%d" % int(ranges[k]))
	camera.fov = fov_was

	# Out of range altogether: nothing of it is kept.
	_groups_look(face, out, InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE + 6.0, eye)
	for t in 40:
		await get_tree().physics_frame
	var left := 0
	for g in interior_groups.known(b.id):
		if g.shown or interior_groups.piece_node(b.id, g.index) != null:
			left += 1
	_gate_ok("past the range and its margin no group of it is kept", left == 0, "%d kept" % left)

	# One shot. The groups at its height are asked again; the top ones are not.
	_groups_look(face, out, ranges[0], eye)
	await _groups_settle(b)
	layout = interior_groups.layout(b)
	var stamps := []
	var buffers := []
	for g in layout:
		stamps.append(g.struct_stamp)
		var node := interior_groups.piece_node(b.id, g.index)
		buffers.append(node.get_meta(&"buffer", PackedFloat32Array()) if node != null
				else PackedFloat32Array())
	var worked0 := interior_groups.rooms_worked
	_blast(face + Vector3(0.0, eye, 0.0) - out * 0.5, 2.0)
	for t in 40:
		await get_tree().physics_frame
	await _groups_settle(b)
	var asked := 0
	var far_same := true
	var hit_group := -1
	var hit_off := INF
	var why := ""
	var local_hit: Vector3 = b.xform.affine_inverse() * (face + Vector3(0.0, eye, 0.0))
	for g in layout:
		if g.struct_stamp != stamps[g.index]:
			asked += 1
		# The nearest by height: a shot at a slab is between two groups' storeys.
		var off := maxf(maxf(g.box.position.y - local_hit.y, local_hit.y - g.box.end.y), 0.0)
		if off < hit_off:
			hit_off = off
			hit_group = g.index
	for g in layout:
		if hit_group < 0 or g.index < hit_group + 2 or not g.shown:
			continue
		var node := interior_groups.piece_node(b.id, g.index)
		var now: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array()) if node != null \
				else PackedFloat32Array()
		if g.struct_stamp != stamps[g.index] or now != buffers[g.index]:
			far_same = false
			why += " group %d: stamp %d->%d, %d->%d floats;" % [g.index, stamps[g.index],
					g.struct_stamp, (buffers[g.index] as PackedFloat32Array).size(), now.size()]
	# Nothing is walked for a shot: the rooms it reached are laid as bricks and
	# drop out of their group, and what lost its floor is found the tick it
	# does (InteriorGroups.check_floors). The groups above do not change.
	_gate_ok("a shot has no storey group walk its rooms again, and leaves the ones above as they were",
			hit_group >= 0 and asked == 0 and far_same,
			"%d of %d group(s) asked again (the shot in group %d), %d room(s) worked out;%s" % [
				asked, layout.size(), hit_group, interior_groups.rooms_worked - worked0, why])

	# A blast at a PIECE: that piece becomes bricks and is broken as bricks
	# are. Its room is not laid, and the rest of the storey goes on being a
	# drawing (Interiors.md 8.4). A room of two pieces or more that nothing
	# has touched, in a group near enough to have its collision.
	var shot_room: Room = null
	var shot_item := -1
	var shot_group: InteriorGroups.Group = null
	var shot_offset: Vector3i = registry._rebase_of(b)
	for g in layout:
		if not g.cover or shot_room != null:
			continue
		for index in range(g.first_room, g.last_room):
			var r := registry.get_room(b.id, index)
			if r == null or r.items.size() < 2 or not r.gone.is_empty() or not r.laid.is_empty():
				continue
			if RoomManifest.item_floor_share(world, b.chunk, str(r.items[0].type),
					(r.items[0].cell as Vector3i) - shot_offset) > 0.5:
				shot_room = r
				shot_item = 0
				shot_group = g
				break
	if shot_room != null:
		var laid0: int = registry.items_laid
		var boxes0: int = shot_group.piece_count
		_blast(b.xform * RoomManifest.item_box(shot_room.items[shot_item]).get_center(), 0.5)
		for t in 30:
			await get_tree().physics_frame
		await _groups_settle(b)
		_gate_ok("a blast at a piece makes that piece bricks, and no other in its room",
				registry.items_laid > laid0 and shot_room.laid.has(shot_item)
				and shot_room.laid.size() + shot_room.gone.size() < shot_room.items.size(),
				"%d piece(s) laid, room %d of %d piece(s): laid %s, gone %s" % [
					registry.items_laid - laid0, shot_room.id, shot_room.items.size(),
					shot_room.laid.keys(), shot_room.gone.keys()])
		_gate_ok("  and the rest of its storeys are still a drawing, less what the blast reached",
				shot_group.shown and not shot_group.dirty and shot_group.piece_count > 0
				and shot_group.piece_count < boxes0,
				"%d box(es) before, %d after" % [boxes0, shot_group.piece_count])
	else:
		_gate_ok("a blast at a piece makes that piece bricks, and lays no room", false,
				"no untouched room of two pieces in a group with collision")

	# A section comes off: nothing of a group stays drawn where its floor has left.
	var wb := _world_box(b)
	var cut_storey := mini(9, int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR - 3)
	# A metre up its storey: the blasts (1.3 m) stop short of the slab above.
	var cut_world := wb.position.y + float(1 + cut_storey * TowerRecipe.STOREY_PLATES) * PLATE + 1.0
	var cut_local: float = (b.xform.affine_inverse() * Vector3(face.x, cut_world, face.z)).y
	_groups_look(face, out, 30.0, eye + 10.0)
	await _groups_settle(b)
	var above := _groups_shown_above(b, cut_local + 2.8)
	var rides0 := _group_rides
	var orphans0 := _group_orphans
	_groups_cut(wb, cut_world)
	var hung_ticks := 0
	var hung_worst := 0
	var riding_most := 0
	var rider_off := 0   # riders on a section that has landed, or on nothing
	for t in 240:
		await get_tree().physics_frame
		riding_most = maxi(riding_most, _group_riders.size())
		if t == 50:
			await _save("interior_groups_fall")   # the sections on their way down, furniture aboard
		if t % 4 == 0:
			for rider in _group_riders:
				var on: BrickIsland = rider[0]
				if rider[1] == null or not is_instance_valid(rider[1]) or not on.is_valid():
					continue
				# Drawn under the section's own node, and that node is where the
				# section's bricks are (a tick of travel allowed): the rows were
				# carried into the section's space on that understanding.
				if (rider[1] as Node).get_parent() != on.mesh \
						or on.mesh.global_transform.origin.distance_to(
							world.get_chunk_transform(on.chunk).origin) > 0.6:
					rider_off += 1
		if b.toppled or not b.is_materialised():
			break
		var hung := _groups_hanging(b, cut_local + 2.8)
		if hung > 0:
			hung_ticks += 1
			hung_worst = maxi(hung_worst, hung)
	_gate_ok("a section falls: of %d box(es) above the cut, none is left drawn over a floor that has gone" % above,
			above > 0 and hung_ticks == 0,
			"%d tick(s), up to %d box(es)" % [hung_ticks, hung_worst])
	_gate_ok("  what stood in it rides the section down, drawn on the section",
			_group_rides > rides0 and riding_most > 0 and rider_off == 0,
			"%d piece(s) lost their floor, %d rode; up to %d section(s) carrying some; %d found off its section" % [
				_group_orphans - orphans0, _group_rides - rides0, riding_most, rider_off])
	# The wreckage is not empty (user, 2026-10-07: "the building just stays
	# empty"). Once its pieces are still, what stood on a floor is drawn on
	# the piece that has that floor -- and nothing is made on one still moving.
	var wreck: Dictionary = await _groups_wreck_settle(b)
	_gate_ok("the wreckage has its interior: still pieces draw what stood on their floors",
			int(wreck.pieces) > 0 and int(wreck.boxes) > 0 and int(wreck.made_moving) == 0,
			"%d piece(s) with a drawing, %d box(es); %d drawing(s) made on a piece still moving; still after %d tick(s)" % [
				wreck.pieces, wreck.boxes, wreck.made_moving, wreck.ticks])
	_gate_ok("  each is what its own chunk holds, and no rider is left on a piece that has one",
			int(wreck.wrong) == 0 and int(wreck.riders) == 0,
			"%d drawing(s) not what the piece's chunk gives, %d rider(s) on a piece with a drawing;%s" % [
				wreck.wrong, wreck.riders, wreck.get("why", "")])
	await _save("interior_groups_wreck")

	# A building that is coming apart when somebody arrives gets no groups
	# until it is still; then the storeys left standing get theirs.
	var b2: BuildingRegistry.Building = picks[1][0]
	var face2: Vector3 = picks[1][1]
	var out2: Vector3 = picks[1][2]
	_groups_look(face2, out2, InteriorGroups.INTERIOR_RANGE + 5.0, eye)
	_promote(b2.id)
	for t in 600:
		await get_tree().physics_frame
		if _brick_nodes.has(b2.id) and not _bands_building(b2.id):
			break
	for t in 30:
		await get_tree().physics_frame
	var before_any := 0
	for g in interior_groups.known(b2.id):
		if g.shown:
			before_any += 1
	var wb2 := _world_box(b2)
	var storeys2: int = int(b2.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR
	var cut2 := wb2.position.y + float(1 + (storeys2 * 2 / 3) * TowerRecipe.STOREY_PLATES) * PLATE + 1.0
	_groups_cut(wb2, cut2)
	_groups_look(face2, out2, 30.0, eye)
	var mid_ticks := 0
	var made_mid := 0
	var still_at := -1
	for t in 1800:
		await get_tree().physics_frame
		var any := 0
		for g in interior_groups.known(b2.id):
			if g.shown:
				any += 1
		if _mid_collapse(b2.id):
			mid_ticks += 1
			made_mid = maxi(made_mid, any)
		elif mid_ticks > 0:
			still_at = t
			break
	_gate_ok("building %d cut at two thirds of its height with nobody in range: no group before, none while it comes apart" % b2.id,
			before_any == 0 and mid_ticks > 0 and made_mid == 0,
			"%d before; coming apart for %d tick(s), up to %d group(s) made in them" % [
				before_any, mid_ticks, made_mid])
	var after := 0
	if still_at >= 0 and not b2.toppled and b2.is_materialised():
		await _groups_settle(b2)
		for g in interior_groups.known(b2.id):
			if g.shown and g.piece_count > 0:
				after += 1
	_gate_ok("  once it is still, the storeys left standing get theirs", after > 0,
			"%d group(s); still at tick %d, toppled %s" % [after, still_at, b2.toppled])

	# What is left of it goes over whole. Its furniture goes with it: the piece
	# it becomes is the same chunk, so every box it was drawing rides. (Dropped
	# with the groups, a toppling tower's rooms emptied the tick it leaned.)
	if not b2.toppled and b2.is_materialised():
		@warning_ignore("integer_division")
		var drawing: int = interior_groups.rows_of(b2.id).size() / FurnitureMesh.STRIDE
		var went := b2.chunk
		_topple(b2.id)
		await get_tree().physics_frame
		var carried := 0
		for rider in _group_riders:
			if (rider[0] as BrickIsland).is_valid() and (rider[0] as BrickIsland).chunk == went \
					and rider[1] != null and is_instance_valid(rider[1]):
				carried += (rider[1] as MultiMeshInstance3D).multimesh.instance_count
		_gate_ok("a tower that goes over whole takes its furniture with it",
				b2.toppled and drawing > 0 and carried == drawing
				and interior_groups.known(b2.id).is_empty(),
				"%d box(es) drawn before, %d riding the piece it became" % [drawing, carried])
		var wreck2: Dictionary = await _groups_wreck_settle(b2)
		_gate_ok("  and what is left of it on the ground has its interior",
				int(wreck2.pieces) > 0 and int(wreck2.boxes) > 0 and int(wreck2.wrong) == 0,
				"%d piece(s) with a drawing, %d box(es), %d wrong; still after %d tick(s);%s" % [
					wreck2.pieces, wreck2.boxes, wreck2.wrong, wreck2.ticks, wreck2.get("why", "")])
	else:
		_gate_ok("a tower that goes over whole takes its furniture with it", false,
				"nothing left standing to topple")

	# Its bricks given back, a building keeps no group and none of its collision.
	_demote(b2.id, 0.0)
	_gate_ok("a building that gives its bricks back keeps no group and none of their collision",
			interior_groups.known(b2.id).is_empty() and not _room_bodies.has(b2.id),
			"%d group(s) known, furniture body %s" % [interior_groups.known(b2.id).size(),
				_room_bodies.has(b2.id)])
	var gr: Dictionary = interior_groups.report()
	print("[groups] all told: %d room(s) worked out, %d drawing(s) put up or refreshed, %d let go, %.1f ms (the slowest drawing %.2f ms); %d time(s) collision put on or taken off" % [
			gr.rooms_worked, gr.attaches, gr.releases, gr.work_ms, gr.worst_attach_ms, _group_covers])
	print("[groups]   floors asked %d time(s), %.2f ms all told (%.3f ms each); %d piece(s) lost theirs, %d rode a section" % [
			gr.checks, gr.check_ms, float(gr.check_ms) / maxf(float(gr.checks), 1.0),
			_group_orphans, _group_rides])
	print("[groups] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## The view switches' gate (DebugView).
##
##     godot --path . --resolution 1280x720 scenes/city.tscn -- --view --big
##
## A tower in bricks, looked at in each view (shots/view_*.png), and the two
## halves of what the switches promise:
##
##   * a switch changes what is DRAWN -- the picture really is different, for
##     bricks cut loose after the switch as much as for those there before it;
##   * and nothing else -- the wall that is not drawn still stops a ray, the
##     desk that is not drawn still has its box, and with every switch back
##     each node is drawn exactly as it was.
func _run_view_pass() -> void:
	print("[view] what is drawn can be switched off; what is there cannot")
	respawn_buildings = false
	var picks := _groups_pick(1)
	_gate_ok("a tower with a face nothing stands in front of", picks.size() == 1)
	if picks.is_empty():
		print("[view] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
		get_tree().quit(1)
		return
	var b: BuildingRegistry.Building = picks[0][0]
	var face: Vector3 = picks[0][1]
	var out: Vector3 = picks[0][2]
	var eye := 8.0
	_promote(b.id)
	for t in 600:
		await get_tree().physics_frame
		if _brick_nodes.has(b.id) and not _bands_building(b.id):
			break
	stats_label.visible = false
	if _reticle != null:
		_reticle.visible = false
	_groups_look(face, out, 16.0, eye)
	await _groups_settle(b)
	await _frames(4)
	var S := DebugView.Mode.SHOWN
	var C := DebugView.Mode.CLEAR
	var H := DebugView.Mode.HIDDEN

	# What every drawing in the scene is drawn with, before anything is switched.
	var before := {}
	for node in find_children("*", "GeometryInstance3D", true, false):
		before[node] = [(node as GeometryInstance3D).layers, (node as GeometryInstance3D).transparency]
	var shown := _view_grab()
	await _save("view_shown")

	# See-through: the bricks, not what stands in them.
	_view_set(C, S, S)
	await _frames(6)
	var tally := _view_tally(b)
	_gate_ok("structure see-through: every brick mesh of the tower is, and no interior piece",
			tally.structure > 0 and tally.structure_clear == tally.structure
			and tally.interior > 0 and tally.interior_clear == 0 and tally.structure_hidden == 0,
			str(tally))
	var clear := _view_grab()
	await _save("view_structure_clear")

	# Hidden: not drawn, and still there.
	_view_set(H, S, S)
	await _frames(6)
	tally = _view_tally(b)
	var cam := get_viewport().get_camera_3d()
	_gate_ok("structure hidden: every brick mesh of the tower is on the layer the camera does not draw",
			tally.structure > 0 and tally.structure_hidden == tally.structure
			and tally.interior_hidden == 0 and (cam.cull_mask & DebugView.HIDDEN_LAYER) == 0,
			str(tally))
	var hidden := _view_grab()
	await _save("view_structure_hidden")
	var d_clear := _view_differ(shown, clear)
	var d_hidden := _view_differ(shown, hidden)
	_gate_ok("  and the picture shows it: see-through and hidden are each a different picture from shown, and from each other",
			d_clear > 0.05 and d_hidden > 0.05 and _view_differ(clear, hidden) > 0.02,
			"%.0f%% of the picture changed see-through, %.0f%% hidden" % [d_clear * 100.0, d_hidden * 100.0])
	await get_tree().physics_frame
	var centre := _world_box(b).get_center()
	var q := PhysicsRayQueryParameters3D.create(camera.global_position,
			Vector3(centre.x, camera.global_position.y, centre.z))
	q.collision_mask = Layers.STRUCTURE
	var wall := get_world_3d().direct_space_state.intersect_ray(q)
	_gate_ok("  the wall that is not drawn still stops a ray",
			not wall.is_empty() and _brick_cols.has(b.id)
			and (_brick_cols[b.id] as BuildingCollision).owns(wall.rid)
			and camera.global_position.distance_to(wall.position) < 17.0,
			"%s" % ("nothing hit" if wall.is_empty() else "%.1f m off" % camera.global_position.distance_to(wall.position)))

	# Bricks cut loose AFTER the switch are in the same view.
	var pieces0 := islands.islands.size()
	_blast(face + Vector3(0.0, eye, 0.0) - out * 0.5, 2.6)
	for t in 45:
		await get_tree().physics_frame
	await _frames(4)
	var loose := 0
	var loose_drawn := 0
	for node in islands.find_children("*", "GeometryInstance3D", true, false):
		if DebugView.kind_of(node) != DebugView.Kind.STRUCTURE:
			continue
		loose += 1
		if (node as GeometryInstance3D).layers != DebugView.HIDDEN_LAYER:
			loose_drawn += 1
	_gate_ok("  what a blast cuts loose after the switch is hidden with the rest",
			loose > 0 and loose_drawn == 0,
			"%d drawing(s) of pieces and crumbs (%d piece(s) made), %d still drawn" % [
				loose, islands.islands.size() - pieces0, loose_drawn])

	# Interior pieces off, walls see-through: the rooms are empty to look at.
	_view_set(H, S, S)
	await _frames(4)
	var with_pieces := _view_grab()
	_view_set(H, H, S)
	await _frames(6)
	tally = _view_tally(b)
	var without := _view_grab()
	await _save("view_structure_and_interior_hidden")
	_gate_ok("interior pieces hidden: every drawing of them is, and the picture loses them",
			tally.interior > 0 and tally.interior_hidden == tally.interior
			and _view_differ(with_pieces, without) > 0.0005,
			"%s; %.2f%% of the picture" % [str(tally), _view_differ(with_pieces, without) * 100.0])
	await get_tree().physics_frame
	var met := false
	var chunk_xf := world.get_chunk_transform(b.chunk)
	for g in interior_groups.known(b.id):
		if not g.cover or met:
			continue
		for room_boxes in g.boxes:
			for box in (room_boxes as Array):
				if (box as AABB).size == Vector3.ZERO or met:
					continue
				var fq := PhysicsRayQueryParameters3D.create(camera.global_position,
						chunk_xf * (box as AABB).get_center())
				fq.collision_mask = Layers.FIXTURE
				var fhit := get_world_3d().direct_space_state.intersect_ray(fq)
				met = not fhit.is_empty() and fhit.rid == _room_bodies.get(b.id, RID())
	_gate_ok("  the desk that is not drawn still has its box", met)
	_view_set(C, H, S)
	await _frames(6)
	await _save("view_clear_no_interior")

	# Items: the storey groups' item drawings and loot. A generated city has
	# no authored item with a DETAIL part, so there may be none to hide.
	_view_set(S, S, H)
	await _frames(6)
	var items := 0
	var items_drawn := 0
	for node in get_tree().get_nodes_in_group(DebugView.GROUP_ITEMS):
		items += 1
		if (node as GeometryInstance3D).layers != DebugView.HIDDEN_LAYER:
			items_drawn += 1
	_gate_ok("items hidden: every item drawing is (%d here)" % items, items_drawn == 0,
			"%d still drawn" % items_drawn)

	# Everything back: each node drawn exactly as it was.
	_view_set(S, S, S)
	await _frames(6)
	var changed := 0
	var checked := 0
	var metas := 0
	for node in before:
		if not is_instance_valid(node):
			continue
		checked += 1
		var g := node as GeometryInstance3D
		if g.layers != int(before[node][0]) or not is_equal_approx(g.transparency, float(before[node][1])):
			changed += 1
		if g.has_meta(&"view_layers") or g.has_meta(&"view_alpha"):
			metas += 1
	_gate_ok("everything shown again: each drawing is on the layer and at the transparency it had",
			checked > 0 and changed == 0 and metas == 0
			and get_tree().get_nodes_in_group(DebugView.GROUP_TOUCHED).is_empty()
			and (cam.cull_mask & DebugView.HIDDEN_LAYER) != 0,
			"%d checked, %d changed, %d still marked, %d still listed" % [checked, changed, metas,
				get_tree().get_nodes_in_group(DebugView.GROUP_TOUCHED).size()])
	print("[view] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## How the tower's drawings stand under the view switches: of its structure
## and of its interior pieces, how many, how many see-through, how many hidden.
func _view_tally(b: BuildingRegistry.Building) -> Dictionary:
	var t := {"structure": 0, "structure_clear": 0, "structure_hidden": 0,
			"interior": 0, "interior_clear": 0, "interior_hidden": 0}
	var root: Node = _brick_nodes.get(b.id)
	if root == null:
		return t
	var nodes: Array = [root]
	nodes.append_array(root.find_children("*", "GeometryInstance3D", true, false))
	for node in nodes:
		var g := node as GeometryInstance3D
		var kind := DebugView.kind_of(g)
		if kind == DebugView.Kind.ITEMS:
			continue
		var name := "structure" if kind == DebugView.Kind.STRUCTURE else "interior"
		t[name] += 1
		if g.layers == DebugView.HIDDEN_LAYER:
			t[name + "_hidden"] += 1
		if is_equal_approx(g.transparency, DebugView.CLEAR):
			t[name + "_clear"] += 1
	return t


func _view_grab() -> Image:
	return get_viewport().get_texture().get_image()


## The share of two pictures' pixels (every fourth, each way) that differ.
func _view_differ(a: Image, b: Image) -> float:
	var size := a.get_size()
	var n := 0
	var differ := 0
	for y in range(0, size.y, 4):
		for x in range(0, size.x, 4):
			n += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.06:
				differ += 1
	return float(differ) / maxf(float(n), 1.0)


## Up to `n` recipe towers of eight storeys or more, tallest first, each with a
## face no other building stands within 100 m in front of:
## [building, the foot of that face, which way it looks].
func _groups_pick(n: int) -> Array:
	var cands: Array = []
	for c in registry.buildings:
		if c.is_build() or int(c.recipe.courses) < 8 * TowerRecipe.COURSES_PER_FLOOR:
			continue
		cands.append(c)
	cands.sort_custom(func(a, c) -> bool: return int(a.recipe.courses) > int(c.recipe.courses))
	var found: Array = []
	for c in cands:
		var box := _world_box(c)
		for dir: Vector3 in [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0)]:
			var along_z: bool = dir.z != 0.0
			var foot: Vector3 = box.get_center() + dir * (box.size.z if along_z else box.size.x) * 0.5
			foot.y = box.position.y
			# As wide as the face and a little over, from just clear of it.
			var across := Vector3(box.size.x * 0.5 + 0.5, 0.0, 0.0) if along_z \
					else Vector3(0.0, 0.0, box.size.z * 0.5 + 0.5)
			var a: Vector3 = foot + dir * 1.0 - across
			var e: Vector3 = foot + dir * 100.0 + across
			var corridor := AABB(Vector3(minf(a.x, e.x), foot.y, minf(a.z, e.z)),
					Vector3(absf(e.x - a.x), 40.0, absf(e.z - a.z)))
			var clear := true
			for o in registry.buildings:
				if o.id != c.id and _world_box(o).intersects(corridor):
					clear = false
					break
			if clear:
				found.append([c, foot, dir])
				break
		if found.size() >= n:
			break
	return found


## Wait for a building's pieces to come to rest and for the piece drawings to
## catch up, then say what the wreckage is drawing: {pieces with a drawing,
## their boxes, drawings that are not what the piece's own chunk gives when
## asked afresh, riders left on a piece that has a drawing, drawings first
## seen on a piece that was not still, ticks waited}.
func _groups_wreck_settle(b: BuildingRegistry.Building) -> Dictionary:
	var out := {"pieces": 0, "boxes": 0, "wrong": 0, "riders": 0, "made_moving": 0, "ticks": 0}
	var seen := {}
	var quiet := 0
	for t in 2400:
		await get_tree().physics_frame
		out.ticks = t
		for chunk in interior_groups.piece_chunks():
			if seen.has(chunk):
				continue
			seen[chunk] = true
			var at := islands.find_by_chunk(int(chunk))
			if at != null and not at.settled:
				out.made_moving += 1
		quiet = quiet + 1 if (t > 90 and islands.moving_of(b.id) == 0 and _pieces_owed == 0) else 0
		# Long enough for every piece's bricks to have been counted again
		# (_stream_pieces: every eighth pass, a pass every fourth tick).
		if quiet >= 48:
			break
	var rooms := registry.rooms_of(b.id)
	var offset: Vector3i = registry._rebase_of(b)
	for chunk in interior_groups.piece_chunks():
		var p: InteriorGroups.PieceDraw = interior_groups.piece(int(chunk))
		if p == null or p.owner != b.id or not p.shown:
			continue
		for rider in _group_riders:
			if (rider[0] as BrickIsland).is_valid() and (rider[0] as BrickIsland).chunk == int(chunk):
				out.riders += 1
		if p.boxes > 0:
			out.pieces += 1
			out.boxes += p.boxes
		# Asked afresh, of every room of the building and not only the ones
		# its box was thought to reach.
		var want := 0
		for room in rooms:
			if room.items.is_empty():
				continue
			@warning_ignore("integer_division")
			want += (RoomManifest.draw_items(world, int(chunk), registry.palette, room,
					offset).buffer as PackedFloat32Array).size() / FurnitureMesh.STRIDE
		if want != p.boxes:
			out.wrong += 1
			var isl := islands.find_by_chunk(int(chunk))
			out["why"] = "%s piece %d: draws %d, its chunk gives %d; %d room(s) tried; drawn at edit %d, now %d; settled %s, %d brick(s)" % [
					out.get("why", ""), int(chunk), p.boxes, want, p.rooms.size(), p.edits,
					isl.edits if isl != null else -1, isl.settled if isl != null else false,
					world.get_alive_block_count(int(chunk))]
	return out


## Stand `dist` out from the foot of a face, `eye` up it, looking at it.
func _groups_look(foot: Vector3, dir: Vector3, dist: float, eye: float) -> void:
	camera.global_position = foot + dir * dist + Vector3(0.0, eye, 0.0)
	camera.look_at(foot + Vector3(0.0, eye, 0.0), Vector3.UP)


## Wait until every group of `b` in range is drawn and up to date, and the
## passes have had time to hand out collision. Returns the ticks it took.
func _groups_settle(b: BuildingRegistry.Building) -> int:
	var quiet := 0
	for t in 600:
		await get_tree().physics_frame
		var local: Vector3 = b.xform.affine_inverse() * camera.global_position
		var owed := 0
		for g in interior_groups.layout(b):
			if _box_distance(g.box, local) <= InteriorGroups.INTERIOR_RANGE \
					and (not g.shown or g.dirty or g.changed):
				owed += 1
		quiet = quiet + 1 if owed == 0 else 0
		if quiet >= 12:
			return t - 11
	return 600


## The interior parts the manifests of `b`'s shown groups hold: what their
## drawings should add up to.
func _groups_expected_boxes(b: BuildingRegistry.Building, layout: Array) -> int:
	var rooms := registry.rooms_of(b.id)
	var n := 0
	for g in layout:
		if not g.shown:
			continue
		for index in range(g.first_room, g.last_room):
			var room: Room = rooms[index]
			for i in room.items.size():
				if room.gone.has(i):
					continue
				for part in RoomManifest.parts_of(str((room.items[i] as Dictionary).type)):
					if registry.palette.has(part[0]) and not RoomManifest.is_detail(part):
						n += 1
	return n


## Blast a building through, wall to wall, at one height: what is above comes off.
func _groups_cut(wb: AABB, cut_world: float) -> void:
	var x := wb.position.x + 0.6
	while x < wb.end.x:
		var z := wb.position.z + 0.6
		while z < wb.end.z:
			_blast(Vector3(x, cut_world, z), 1.3)
			z += 2.0
		x += 2.0


## Boxes of `b`'s group drawings still shown above a height (its own space).
func _groups_shown_above(b: BuildingRegistry.Building, y: float) -> int:
	var n := 0
	for g in interior_groups.known(b.id):
		var node := interior_groups.piece_node(b.id, g.index)
		if node == null:
			continue
		var buffer: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array())
		for i in buffer.size() / FurnitureMesh.STRIDE:
			var at := i * FurnitureMesh.STRIDE
			if buffer[at + 7] > y and absf(buffer[at]) + absf(buffer[at + 5]) + absf(buffer[at + 10]) > 0.0001:
				n += 1
	return n


## And of those, the ones with no brick anywhere in the twelve plates under
## them: drawn over a floor that is not there any more.
func _groups_hanging(b: BuildingRegistry.Building, y: float) -> int:
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = world.get_chunk_origin(b.chunk)
	var n := 0
	for g in interior_groups.known(b.id):
		var node := interior_groups.piece_node(b.id, g.index)
		if node == null:
			continue
		var buffer: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array())
		for i in buffer.size() / FurnitureMesh.STRIDE:
			var at := i * FurnitureMesh.STRIDE
			if buffer[at + 7] <= y or absf(buffer[at]) + absf(buffer[at + 5]) + absf(buffer[at + 10]) <= 0.0001:
				continue
			var foot := Vector3(buffer[at + 3], buffer[at + 7] - buffer[at + 5] * 0.5, buffer[at + 11])
			var cell := Vector3i(floori(foot.x / cs.x), roundi(foot.y / cs.y), floori(foot.z / cs.z)) + origin
			var held := false
			for down in range(1, 13):
				if world.is_solid(b.chunk, Vector3i(cell.x, cell.y - down, cell.z)):
					held = true
					break
			if not held:
				n += 1
	return n


## [triangles drawn, of them with no live brick behind, what was there].
func _drawn_stale(b: BuildingRegistry.Building) -> Array:
	var node: MeshInstance3D = _brick_nodes.get(b.id)
	if node == null:
		return [0, 0, {}]
	var inv := world.get_chunk_transform(b.chunk).affine_inverse()
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = world.get_chunk_origin(b.chunk)
	var meshes: Array = [node]
	for k in node.get_children():
		if k is MeshInstance3D:
			meshes.append(k)
	var tris := 0
	var stale := 0
	var kinds := {}
	for m in meshes:
		var mesh: Mesh = (m as MeshInstance3D).mesh
		if mesh == null:
			continue
		var xf: Transform3D = inv * (m as MeshInstance3D).global_transform
		for si in mesh.get_surface_count():
			var arr: Array = mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				var a := idx[t]
				var bb := idx[t + 1]
				var c := idx[t + 2]
				if a == bb or bb == c or a == c:
					continue
				tris += 1
				var centre: Vector3 = xf * ((v[a] + v[bb] + v[c]) / 3.0)
				var inside: Vector3 = centre - (xf.basis * nrm[a]).normalized() * 0.02
				var cell := origin + Vector3i(floori(inside.x / cs.x), floori(inside.y / cs.y),
						floori(inside.z / cs.z))
				if world.is_solid(b.chunk, cell):
					continue
				stale += 1
				var bid := world.block_at(b.chunk, cell)
				var what := "no block" if bid < 0 else \
						world.get_archetype_name(world.get_block_archetype(b.chunk, bid)).get_slice("#", 0)
				kinds[what] = int(kinds.get(what, 0)) + 1
	return [tris, stale, kinds]


## Does a collapse come down, or hang?
##
## A storey blown out under three towers with stairs, watched for ten seconds
## from inside FRACTURE_RANGE, so landings break things. A piece is STUCK when it
## has stayed slower than JAM_SLOW for a second, a second and a half after it
## came loose, and still not settled: held up and jittering, the thing a
## collapse was seen doing in mid-air. What it is touching says why. Measured
## first (--diag stairs, 2026-09-30): 22 stuck, 17 of them on pieces that were
## themselves still falling. And a piece THROWN -- going up faster than
## JAM_THROWN with nothing having blown it -- is what pushing two overlapping
## bodies apart looks like, which is the price of letting falling pieces pass
## through each other if it is done wrong (IslandManager.MAX_RISE_SPEED). It
## was counted as a jump in one tick; the push builds over three or four, and
## 1 -> 6 -> 10 -> 11 m/s was never one jump.
const JAM_SLOW := 0.8
const JAM_THROWN := 6.0

func _run_jam_pass() -> void:
	print("[jam] a collapse comes down, and nothing hangs in mid-air")
	var picks: Array = []
	for b in registry.buildings:
		if b.is_build() or b.toppled or b.recipe.courses < 12:
			continue
		for f in b.fixtures:
			if f.kind == "staircase":
				picks.append(b)
				break
		if picks.size() >= 3:
			break
	_gate_ok("three towers with stairs to bring down", picks.size() == 3, "%d" % picks.size())
	for b in picks:
		_promote(b.id)
		_jam_look(b, 30.0, 15.0)
		await _frames(40)
	var stuck := {}
	var reported := {}
	var on := {}
	var thrown := 0
	var worst_up := 0.0
	var spawned0: int = islands.islands.size()
	var t_quiet := -1
	var blasts := 0
	for b in picks:
		var fx: float = b.recipe.footprint_x * STUD
		var fz: float = b.recipe.footprint_z * STUD
		var y: float = 1.2 + (TowerRecipe.COURSES_PER_FLOOR * 3 + 1) * PLATE
		var x := 0.0
		while x <= fx + 0.01:
			var z := 0.0
			while z <= fz + 0.01:
				_blast(b.xform * Vector3(x, y, z), 2.0)
				blasts += 1
				z += 2.5
			x += 2.5
	var blasted_at := Engine.get_physics_frames()
	var b0: BuildingRegistry.Building = picks[0]
	_jam_look(b0, 35.0, 20.0)
	var prev_vy := {}
	for t in 600:
		await get_tree().physics_frame
		var by_body := {}
		var moving := 0
		for isl in islands.islands:
			if isl.is_valid():
				by_body[isl.body.get_rid()] = isl
		for isl in islands.islands:
			if not isl.is_valid() or isl.settled:
				continue
			moving += 1
			var v: Vector3 = isl.body.linear_velocity
			if v.y > JAM_THROWN and float(prev_vy.get(isl, 0.0)) <= JAM_THROWN:
				thrown += 1
			if v.y > 5.0 and v.y > worst_up:
				print("[jam]   up %.1f m/s (%.1f a tick ago): %d bricks, %s, age %d ms, at y %.1f, %d contact(s)%s" % [
						v.y, float(prev_vy.get(isl, 0.0)), world.get_alive_block_count(isl.chunk),
						"landed" if isl.landed else "in the air", Time.get_ticks_msec() - isl.born_ms,
						isl.body.global_position.y, isl.body.get_contact_count(), _jam_others(isl, by_body)])
			worst_up = maxf(worst_up, v.y)
			prev_vy[isl] = v.y
			if t % 10 != 0:
				continue
			if v.length() < JAM_SLOW and Time.get_ticks_msec() - isl.born_ms > 1500:
				stuck[isl] = int(stuck.get(isl, 0)) + 10
			else:
				stuck[isl] = 0
			if int(stuck.get(isl, 0)) >= 60 and not reported.has(isl):
				reported[isl] = true
				var kinds := _jam_touching(isl, by_body)
				for k in kinds:
					on[k] = int(on.get(k, 0)) + 1
				print("[jam]   stuck: %d bricks, %s, %s, on %s; %s, %.2f m/s, spin %.2f, tries %d, at y %.1f%s" % [
						world.get_alive_block_count(isl.chunk),
						"landmark" if isl.landmark else "debris",
						"rubble" if isl.disposable else "falling", kinds,
						"landed" if isl.landed else "in the air", v.length(),
						isl.body.angular_velocity.length(), isl.unsupported_tries,
						isl.body.global_position.y, _jam_others(isl, by_body)])
		if moving == 0 and t_quiet < 0 and t > 60:
			t_quiet = Engine.get_physics_frames() - blasted_at
	var r := islands.report()
	print("[jam]   %d blasts; %d pieces came loose; stuck %d, by what they touch %s; thrown %d (fastest up %.1f m/s); all still after %s tick(s); settled by rule %d (jittering %d), by age %d; landed %d" % [
			blasts, islands.islands.size() - spawned0, reported.size(), on, thrown, worst_up,
			str(t_quiet) if t_quiet >= 0 else "never", int(r.settled_by_rule),
			int(r.get("settled_jittering", 0)), int(r.settled_by_age), int(r.get("landings_noted", 0))])
	print("[jam]   crumbs: %d piece(s), %d brick(s) drawn, %d not (CRUMBS_MAX); worst crumb tick %.2f ms, worst crumble %.2f ms; small bodies %d; rises capped %d" % [
			int(r.crumbled), int(r.crumb_bricks), int(r.crumbs_over), float(r.crumb_worst_ms),
			float(r.crumble_worst_ms), int(islands.spawn_census.small[0]), int(r.rises_capped)])
	for line in islands.body_census_lines():
		print("[jam]   bodies " + line)
	_gate_ok("no piece hangs on another that is still falling",
			int(on.get("falling piece", 0)) == 0, "%d" % int(on.get("falling piece", 0)))
	_gate_ok("and hardly any hang at all", reported.size() <= 3, "%d stuck" % reported.size())
	_gate_ok("and none is thrown out of another", thrown == 0,
			"%d thrown, fastest up %.1f m/s" % [thrown, worst_up])
	print("[jam] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


func _jam_look(b: BuildingRegistry.Building, dist: float, height: float) -> void:
	var fx: float = b.recipe.footprint_x * STUD
	var fz: float = b.recipe.footprint_z * STUD
	var centre: Vector3 = b.xform * Vector3(fx * 0.5, 0.0, fz * 0.5)
	camera.global_position = centre + (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized() \
			* (fz * 0.5 + dist) + Vector3(0.0, height, 0.0)
	camera.look_at(centre + Vector3(0.0, 8.0, 0.0), Vector3.UP)


func _jam_others(isl: BrickIsland, by_body: Dictionary) -> String:
	var out := ""
	var st := PhysicsServer3D.body_get_direct_state(isl.body.get_rid())
	for i in (st.get_contact_count() if st != null else 0):
		var rid: RID = st.get_contact_collider(i)
		var n := st.get_contact_local_normal(i)
		var what := "?"
		if by_body.has(rid):
			var o: BrickIsland = by_body[rid]
			what = "piece %d br %s %.2f m/s" % [world.get_alive_block_count(o.chunk),
					"settled" if o.settled else ("landed" if o.landed else "air"),
					o.body.linear_velocity.length()]
		elif _building_for_body(rid) >= 0:
			what = "building"
		else:
			what = "ground"
		out += "
[jam]       n (%.2f %.2f %.2f) %s" % [n.x, n.y, n.z, what]
	return out


## What a stuck piece's contacts are: standing structure, the ground, settled
## wreckage, or pieces still falling.
func _jam_touching(isl: BrickIsland, by_body: Dictionary) -> Array:
	var kinds := {}
	for ct in islands._contact_points(isl):
		var rid: RID = (ct as Dictionary).collider
		var kind := "ground/other"
		if _building_for_body(rid) >= 0:
			kind = "structure"
		elif by_body.has(rid):
			var o: BrickIsland = by_body[rid]
			kind = ("settled piece" if o.settled else "falling piece")
		kinds[kind] = true
	return kinds.keys()


## The gate for the player (Docs/AIPlan.md P1): a Pawn driven by PlayerController
## lands, walks, steps a kerb and not a wall, ducks a beam from a brick floor --
## the debug walker's rules, now on the physics tick -- and shoots a wall from its
## own eye, through the authority, without shooting itself.
func _run_play_pass() -> void:
	print("[play] a player pawn, driven by the keys")
	_player.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	camera.global_position = open + Vector3(0.0, 6.0, 0.0)
	camera.rotation = Vector3.ZERO
	_enter_pawn(open + Vector3(0.0, 4.0, 0.0))
	await _frames(90)
	var pawn := _player_pawn
	_gate_ok("it falls to the ground and stands on it", pawn.is_on_floor(),
			"feet at %.2f" % pawn.feet().y)
	_gate_ok("and the camera is at its eye (%.2f m)" % camera.global_position.y,
			absf(camera.global_position.y - Pawn.EYE_HEIGHT) < 0.12)

	# A kerb is stepped over, a wall is not. Facing +Z: the camera looks down -Z.
	camera.rotation = Vector3(0.0, PI, 0.0)
	var here := pawn.feet()
	var kerb := _test_block(Vector3(here.x, 0.15, here.z + 3.0), Vector3(6.0, 0.3, 1.0))
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	_gate_ok("a kerb is walked over", pawn.feet().z > here.z + 3.5 and pawn.feet().y < 0.2,
			"z %.2f, feet %.2f" % [pawn.feet().z, pawn.feet().y])
	kerb.queue_free()
	here = pawn.feet()
	var wall := _test_block(Vector3(here.x, 0.75, here.z + 2.5), Vector3(8.0, 1.5, 1.0))
	await _frames(4)
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	_gate_ok("a wall is not", pawn.feet().z < here.z + 2.0 and pawn.feet().z > here.z + 0.5,
			"z %.2f, face at %.2f" % [pawn.feet().z, here.z + 2.0])
	wall.queue_free()

	# The debug walker's headroom bug, on the pawn: a beam that clears a figure
	# on the ground stops one standing on a brick, and ducking gets past it. Its
	# underside at 1.75 m: over a standing figure's 1.68, under the 2.10 of one
	# standing on a brick, over the 1.68 of one crouched on it. (The --walk gate's
	# beam sits at 1.40, from before the figure was resized, and fails.)
	var room := Vector3(open.x + 30.0, 0.0, open.z)
	var beam := _test_block(room + Vector3(0.0, 1.85, 0.0), Vector3(6.0, 0.2, 1.2))
	var ledge := _test_block(room + Vector3(0.0, PLATE * 1.5, 0.0), Vector3(6.0, PLATE * 3.0, 6.0))
	pawn.place(room + Vector3(0.0, 0.0, -5.0))
	await _frames(20)
	var ducked := false
	_key(KEY_W, true)
	for i in 180:
		await _frames(1)
		ducked = ducked or pawn.is_auto_crouched()
	_key(KEY_W, false)
	await _frames(6)
	_gate_ok("standing on a brick it ducks under the beam and gets past",
			ducked and pawn.feet().z > room.z + 1.0 and pawn.feet().y > 0.3,
			"ducked %s, z %.2f, feet %.2f" % [ducked, pawn.feet().z, pawn.feet().y])
	beam.queue_free()
	ledge.queue_free()
	await _frames(20)
	_gate_ok("and stands up again", not pawn.is_crouched())

	# Shooting from the pawn: face a building's wall from close and hold LMB.
	var b := registry.get_building(0)
	var face := b.xform * Vector3(b.recipe.footprint_x * 0.5 * STUD, 0.0, 0.0)
	var out := b.xform.basis * Vector3(0.0, 0.0, -1.0)
	pawn.place(face + out * 5.0)
	await _frames(30)
	camera.look_at(face + Vector3.UP * 1.2, Vector3.UP)
	await _frames(2)
	var n0 := authority.commands.size()
	var hp := pawn.health.total_current()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(30)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await _shoot(0)
	var chips := 0
	for i in range(n0, authority.commands.size()):
		if authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	_gate_ok("holding the button fires the pawn's gun into the wall",
			chips > 0, "%d CHIP(s) from %s" % [chips, _gun.gun.gun_name])
	# That was a click, and a click is what takes the mouse. A pass must not:
	# it runs on a machine somebody is using (DebugCamera.hands_off).
	_gate_ok("and the pass's own click did not take the real mouse",
			Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	_gate_ok("and it never shoots its own body", pawn.health.total_current() == hp)

	# The settings menu (Ceramic Edge's menu/, Docs/Reference/ceramicedge.md section 8):
	# Escape pauses the city under it and resuming gives it back; what is set in Options
	# reaches the game (BrickcityMenuHost).
	var mm := get_node_or_null(^"/root/MenuManager")
	var ms := get_node_or_null(^"/root/MenuSettings")
	_gate_ok("the menu autoloads are there", mm != null and ms != null)
	if mm != null and ms != null:
		_key(KEY_ESCAPE, true)
		await _frames(2)
		_key(KEY_ESCAPE, false)
		await _frames(2)
		_gate_ok("Escape opens the pause menu over the city, and the city stops",
				mm.is_open() and get_tree().paused)
		mm.close_pause()
		await _frames(2)
		_gate_ok("and resuming starts it again", not mm.is_open() and not get_tree().paused)
		var fov_was: Variant = ms.get_value(&"fov")
		ms.set_value(&"fov", 110, false)
		await _frames(30)
		var vp := get_viewport().get_visible_rect().size
		var want := rad_to_deg(2.0 * atan(tan(deg_to_rad(110.0) * 0.5) / (vp.x / vp.y)))
		_gate_ok("a field of view set in Options is the view's",
				is_equal_approx(PlayerView.hfov, 110.0) and absf(camera.fov - want) < 1.0,
				"camera %.1f, want %.1f" % [camera.fov, want])
		ms.set_value(&"fov", fov_was, false)
		var sens_was: Variant = ms.get_value(&"mouse_sensitivity")
		var crouch_was: Variant = ms.get_value(&"toggle_crouch")
		ms.set_value(&"mouse_sensitivity", 2.0, false)
		ms.set_value(&"toggle_crouch", true, false)
		_gate_ok("and so are the mouse and hold-or-toggle",
				is_equal_approx(DebugCamera.look_mult, 2.0) and PlayerController.toggle_crouch)
		ms.set_value(&"mouse_sensitivity", sens_was, false)
		ms.set_value(&"toggle_crouch", crouch_was, false)
	_leave_pawn()
	await _frames(4)
	_gate_ok("V leaves: the camera flies again", camera.is_processing() and _player_pawn == null)
	_check_log_replays()
	print("[play] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
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
		var woke: int = (reached.laid as Array).size() + int(reached.gone)
		if not (reached.laid as Array).is_empty():
			_add_item_shapes(b.id, reached.laid)
			# The building has to be told it holds furniture now, or the
			# redraw's guard skips it for ever.
			_furnished[b.id] = true
			_refresh_furniture(b.id)
		if woke > 0:
			# Laid as bricks or written off: out of its group's drawing now. A
			# pass later is a piece drawn twice for four ticks.
			_groups_rooms_moved(b, local.y - reach, local.y + reach)
			_pieces_hit += woke
			_pieces_laid += (reached.laid as Array).size()
			_pieces_hit_ms += float(Time.get_ticks_usec() - t_room) / 1000.0
		t_part = _part("dmg_rooms", t_part)
		var killed: PackedInt32Array = world.chip_hit(chunk, point, radius, chip_hp) 				if chip_hp > 0 else world.apply_hit(chunk, point, radius)
		t_part = _part("dmg_hit", t_part)
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
				if chip_hp > 0:
					_nav_chip_broke(point, radius)
				b.hit = true
				_disable_frame(b.id, fi, hit_frame)
				_mark_dirty(b.id)
				_queue_remesh(b.id)
		if killed.is_empty():
			continue
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
	# What the workers finished uploading since the last call into the
	# renderer, paid here and measured, rather than by whatever next makes a
	# node or sets a mesh -- which is where it landed: a spawn's "node" step at
	# 7-12 ms, a small piece's mesh at 8. Any call that answers flushes the
	# renderer's queue; asking a tiny mesh its surface count is the cheapest.
	# See IslandManager.UPLOAD_VERTS_PER_TICK.
	RenderingServer.mesh_get_surface_count(_flush_mesh.get_rid())
	t = _mark("render", t)
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
			var ab := registry.get_building(_dirty[k])
			if ab != null and ab.is_materialised():
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
		if ahead.has(id):
			solve = ahead[id]
			ahead.erase(id)
		else:
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

		var groups: Array = solve.groups
		if groups.is_empty():
			# Nothing hanging has failed and nothing is loose -- but is each
			# storey still able to carry what is above it? (_gravity_fail)
			if not b.is_build() and _gravity_fail(b):
				_mark_dirty(b.id)
				continue
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
		if _shells.has(b.id) and _bands_building(b.id):
			continue
		# Breakage as it always was; a mega building's collapse as a few big
		# chunks, its furniture split out to be written off (CollapseDirector).
		var plan: Array = director.plan(b.id, b.chunk, b.blocks, _world_box(b), groups,
				islands.interest_points(), 0 if b.is_build() else TowerRecipe.STOREY_PLATES,
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
	for sid in _stairs_due.keys():
		if spawned >= SPAWNS_PER_TICK or (spawned > 0 and Time.get_ticks_usec() >= spawn_until):
			break
		var cut := _sweep_stairs(int(sid))
		if cut >= 0:
			_stairs_due.erase(sid)
			spawned += cut
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

	_flush_furniture()
	_retirer.drain()
	t = _mark("retire", t)
	_advance_bands()
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
		_promote(pid, pb == null or pb.is_damaged())
		promoted += 1
	t = _mark("promote", t)

	# M4: buildings that have been quiet and are far away give their bricks
	# back. The damage record stays, so the holes are still there next time.
	if not _measuring:
		var t_st := Time.get_ticks_usec()
		if camera != null and Engine.get_physics_frames() % TRIM_EVERY == 0:
			_trim_quiet()
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
	if camera != null and Engine.get_physics_frames() % 4 == 0:
		_stream_shells()
	if not _shadow_jobs.is_empty():
		_harvest_shadow_jobs()
	if camera != null and Engine.get_physics_frames() % 8 == 2:
		_stream_shadows()
	if camera != null and Engine.get_physics_frames() % 4 == 1:
		_inst_update()
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
	_ai_tick(tick_total)
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
	var shell_budget := SHELLS_PER_TICK
	var looked := 0
	# A full pass over the register every eight, however many there are: with
	# trees in it the register is ten times the city, and a fixed slice left a
	# building waiting seconds for its tier.
	var slice := mini(count, maxi(SHELLS_PER_TICK * 16, floori(count / 8.0) + 1))
	while looked < slice and shell_budget > 0:
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

## Hits a building took while its bands were being built (_remesh), and the
## count each band was built at: a band built before the latest hit is out of
## date, one built after it is not (_bands_done). And the bands a pass is to
## build, when it is not all of them.
var _band_hits := {}      ## building id -> int
var _band_built_at := {}  ## building id -> PackedInt32Array, per band
var _band_todo := {}      ## building id -> PackedInt32Array of band indices

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
		if stale and built < SHADOW_PROXIES_PER_PASS and _make_shadow_proxy(b):
			built += 1
			_shadow_stale.erase(id)
		casting += _set_brick_shadows_near(id, here)
	var quiet := 0
	for isl in islands.islands:
		if isl == null or not is_instance_valid(isl.mesh):
			continue
		var cast := isl.radius > SMALL_ISLAND_RADIUS \
				or isl.mesh.global_position.distance_to(here) < SMALL_SHADOW_RANGE + isl.radius
		isl.mesh.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		if not cast:
			quiet += 1
	_shadow_stats = {"proxies": _shadow_proxy.size(), "bricks_casting": casting,
			"small_quiet": quiet}


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
		g.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
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
			_shell_stale.erase(id)
			_remesh_bricks(id)
			done += 1
		elif _shell_stale.has(id):
			_shell_stale.erase(id)
			_free_shell(id)
			_make_shell(id, true)
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
## (_advance_bands). Not one being shot: its bands built while the hits are
## still landing are built again after the last one (_band_hits), and going
## first made that more of them -- the shot showed at 15 ticks, not 9.
var _band_first := {}
var aim_promotions := 0
## Drawn rooms a landing piece crushed furniture in (_crush_drawn).
var crushed_by_wreckage := 0


func _aim_promote() -> void:
	# The far pass looks straight at buildings to check the shell ladder, and
	# a look within AIM_PROMOTE_RANGE made each one bricks under it: no shell
	# left to check (two of its checks failed on this, not on the ladder).
	if _far_mode:
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
	if b == null or b.is_materialised() or b.toppled or _promote_queue.has(id):
		return
	_promote_queue.push_front(id)
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
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) \
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
			if b == null or b.is_materialised() or b.toppled or _promote_queue.has(id):
				continue
			_promote_queue.push_front(id)
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


func _process(delta: float) -> void:
	if _terrain_streamer != null:
		_terrain_streamer.follow(Vector2(camera.global_position.x,
				camera.global_position.z))
	if brick_near != null:
		brick_near.step(camera.global_position)
	if _sea != null:
		_sea.follow(camera.global_position, delta)
	_update_reticle()
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
		"rooms         %d  (%d with a diff, %d piece(s) laid as bricks)" % [
			rooms.rooms, rooms.changed, rooms.laid],
		_groups_hud_line(),
		_view_hud_line(),
		"",
		("%s  %d/%d%s   %s (SPACE SPACE)" % [_gun.gun.gun_name, _gun.ammo, _gun.mag_size(),
				"  reloading" if _gun.is_reloading() else "",
				_mode_word()]) if _gun_armed and _gun.gun != null
			else "blast %.1f m (wheel)   %s (SPACE SPACE)" % [
				_blast_radius, _mode_word()],
		"1 gun · 2 blast · T next gun · R reload · V on foot · K soldier · U squad · Y enemy mech · F mech order" + (" · H disasters (shift: end)" if disasters != null else ""),
		"LMB fire · X big blast · P place a saved build · WASD move · shift fast · G grids · B bevel · J overlap"
			+ "
F1 stats · F2 profiler · F3 reset worst · F4 AI · F5 save · F9 load · F10 terrain dev menu · F11 terrain edit · N respawn
7 structure solid/see-through/hidden · 8 interior pieces · 9 items  (what is hidden is still there)"
			+ ("" if respawn_buildings else "\nRESPAWN OFF (N) — buildings keep their bricks once promoted"),
	])


## One of the view switches (DebugView): 7, 8 and 9 in play.
func _view_cycle(kind: int) -> void:
	DebugView.cycle(kind)
	_view_owed = true
	print("[city] view: %s" % DebugView.line())
	_update_hud()


func _view_set(structure: int, interior: int, items: int) -> void:
	DebugView.modes = [structure, interior, items] as Array[int]
	_view_owed = true


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


func _unhandled_input(event: InputEvent) -> void:
	# Terrain edit mode: everything but these is the editor's.
	if _edit_mode:
		if event is InputEventKey and event.pressed and not event.echo:
			match event.keycode:
				KEY_F11:
					_toggle_terrain_edit()
				KEY_F10:
					_toggle_terrain_dev_menu()
				KEY_F1:
					stats_label.visible = not stats_label.visible
		return
	# On foot the buttons are the player's own (rebindable input actions,
	# PlayerController): firing, aiming and reloading go through the pawn.
	if event is InputEventMouseButton and _player.is_possessing():
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
	if event is InputEventKey and not event.echo and event.keycode == KEY_F \
			and _mech_cmd != null and _player.is_possessing():
		if event.pressed:
			_mech_cmd.press(ai_services.now())
		else:
			var o := _mech_cmd.release(ai_services.now(), _aim_point())
			print("[city] mech order: %s" % MechBrain.Order.keys()[o])
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_X:
			_fire(BIG_BLAST)
		KEY_H:
			if disasters != null:
				disasters.on_key(event.shift_pressed)
		KEY_F1:
			stats_label.visible = not stats_label.visible
		KEY_1:
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
			_spawn_enemy_mech(mech_nav.snap(_on_ground(ahead)), camera.global_rotation.y + PI)
		KEY_M:
			if _pilot.is_piloting():
				_leave_mech()
			else:
				_board_mech()
		KEY_V:
			if _pilot.is_piloting():
				return
			if _player.is_possessing():
				_leave_pawn()
			else:
				_enter_pawn(camera.global_position - Vector3.UP * Pawn.EYE_HEIGHT)
		KEY_T:
			_gun_class = (_gun_class + 1) % GUN_CLASSES.size()
			_equip_gun(GUN_CLASSES[_gun_class], _combat_rng.randi())
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

## What the city costs a frame, from three viewpoints.
##
##     godot --path . scenes/city.tscn -- --bench
##
## Vsync off, or every reading is the monitor. See Docs/Terrain.md 19.5 for
## the comparison against terrain.
func _run_bench() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await _frames(30)
	var rep: Dictionary = registry.report()
	print("[bench] city: %d buildings, %d live bricks" % [
		rep.buildings, rep.live_blocks])

	await _bench_at("over the city", Vector3(-52.0, 34.0, -52.0),
			Vector3(-0.42, -2.36, 0.0))
	await _bench_at("street level", Vector3(-8.0, 1.7, -8.0),
			Vector3(-0.05, -2.36, 0.0))
	await _bench_at("high and far", Vector3(-140.0, 90.0, -140.0),
			Vector3(-0.42, -2.36, 0.0))
	get_tree().quit()


func _bench_at(label: String, pos: Vector3, rot: Vector3) -> void:
	camera.position = pos
	camera.rotation = rot
	# The shell tier streams a few buildings a tick; sampling before it has
	# caught up with the jump measured a different city on every run.
	await _far_settle()
	var samples: Array[float] = []
	for i in 90:
		await RenderingServer.frame_post_draw
		samples.append(get_process_delta_time() * 1000.0)
	var sum := 0.0
	for i in range(floori(samples.size() / 2.0), samples.size()):
		sum += samples[i]
	var detailed := 0
	var meshed_coarse := 0
	for id in _shells:
		if _shell_box.has(id):
			continue
		if _shell_coarse.get(id, false):
			meshed_coarse += 1
		else:
			detailed += 1
	@warning_ignore("integer_division")
	print("[bench]   %-16s %10d tris  %5d calls  %5.1f ms  (%d banded shells, %d coarse meshes, %d far boxes; %d brick buildings, %d brick nodes casting, %d shadow shells)" % [
		label,
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		sum / float(samples.size() / 2), detailed, meshed_coarse, _far_on.size(),
		_brick_nodes.size(), int(_shadow_stats.bricks_casting), int(_shadow_stats.proxies)])


func _run_shot_pass() -> void:
	camera.position = Vector3(-52.0, 34.0, -52.0)
	camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(4)
	await _save("city_intact")
	if _sea != null:
		await _shot_shore()

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
	camera.position.y = inside.xform.origin.y + 2.4
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
	print("[city]   debris: %d brick(s) deleted where they came loose (beyond %.0f m or out of view); %d piece(s) gone once out of view, %d shrunk away in view; %d of furniture; %.0f ms deciding"
			% [isl.tiny_deleted, IslandManager.SMALL_KEEP_RANGE, int(isl.get("debris_unseen", 0)),
			int(isl.get("debris_faded", 0)), isl.furniture_deleted, float(islands.spawn_prof.deleted)])
	var cen: Dictionary = islands.census
	var sc: Dictionary = islands.spawn_census
	var nt := maxi(int(cen.ticks), 1)
	print("[city]   in motion: mean %.1f piece(s) (%.1f landmarks, %.0f boxes), peak %d (%d landmarks, %d boxes)" % [
			float(cen.moving) / nt, float(cen.landmarks) / nt, float(cen.blocks) / nt,
			int(cen.moving_peak), int(cen.landmarks_peak), int(cen.blocks_peak)])
	print("[city]   came loose: %d landmark bodies (%d bricks), %d small bodies (%d), %d deleted where they were (%d), %d dropped over the moving cap (%d)" % [
			sc.landmark[0], sc.landmark[1], sc.small[0], sc.small[1], sc.deleted[0], sc.deleted[1],
			sc.capped[0], sc.capped[1]])
	print("[city]   of which pieces coming off pieces: %d (%d bricks)" % [sc.shed[0], sc.shed[1]])
	for line in islands.body_census_lines():
		print("[city]   bodies " + line)
	print("[city]   " + islands.hit_census_line())
	print("[city]   crumbs: %d piece(s), %d brick(s), %d not drawn (CRUMBS_MAX), worst tick %.2f ms, worst crumble %.2f ms, all told drawing %.1f + cutting out %.1f + deciding %.1f ms; landings snapped %d time(s), %d on a storey line" % [
			islands.crumbled, islands.crumb_bricks, islands.crumbs_over, islands.crumb_worst_ms,
			islands.crumble_worst_ms, islands.crumble_parts[0], islands.crumble_parts[1],
			islands.crumble_parts[2], islands.breaks, islands.floor_breaks])
	# Started can pass built: a start is dropped when its chunk changes under
	# the worker, and asked for again.
	print("[city]   stand-ins: %d built; %d started on a worker; the slowest on the main thread %.1f ms (of any, %.1f)" % [
			islands.coarse_built, islands.coarse_async, islands.coarse_main_worst_ms, islands.coarse_worst_ms])
	print("[city]   collapse director: %d mega round(s) turned %d group(s) into %d chunk(s) (%d round(s) held); %d breakage group(s); %d furniture brick(s) written off; %d building(s) came down big" % [
			director.rounds, director.groups_in, director.chunks_out, director.held_rounds,
			director.breakage_out, director.furniture_out, director.collapsing.size()])
	print("[city]   sleep: %d piece(s) put to sleep (%d by the cap), %d woken (%d of the cap's), %d asleep now" % [
			islands.slept, islands.cap_slept, islands.woken, islands.cap_woken, islands.dormant.size()])
	print("[city]   support: %d settled piece(s) woken because what held them went, %d because something landed on them; %d nudged down instead of settling with nothing under them; %d jolt(s) not taken for landings" % [
			islands.ripple_woken, islands.touch_woken, islands.unsupported_nudges, islands.jolts_ignored])
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
			"camera": camera.global_transform, "placed": _placed.duplicate(true)}
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


## A placed build from a checkpoint, put back as it was placed: registered (so
## it has the id the log knows it by), its pad cut again if it stood on the
## ground, indexed and shelled.
func _replace_build(d: Dictionary) -> void:
	var recipe := BuildRecipe.from_dict(d.get("recipe", {}))
	if recipe.is_empty():
		return
	var id := registry.register_build(recipe, d.get("xform", Transform3D()))
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
			world.set_tension_per_stud(chunk, 9.3)
			if not toppling.has(id):
				shown.append(id)
		var cs := b.chunks()
		return cs[frame] if frame < cs.size() else -1
	var on_toppled := func(id: int) -> void:
		var b := registry.get_building(id)
		_free_shell(id)
		_drop_groups(id)
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
	print("[city] checkpoint loaded in %d ms, %d placed build(s): %s" % [
		Time.get_ticks_msec() - t0, _placed.size(), report])
	return report


## The gate for F5/F9. Knock the city about, save partway through the collapse
## -- pieces still falling, some at rest -- reload the scene from the save, and
## check it is the same area: every damaged building brick for brick, every
## piece brick for brick, where it was, moving or not as it was. Then let the
## loaded city carry on and check the log still replays into it.
func _run_checkpoint_pass() -> void:
	var root := get_tree().root
	if root.has_meta(CHECKPOINT_GATE_META):
		var saved_want: Dictionary = root.get_meta(CHECKPOINT_GATE_META)
		root.remove_meta(CHECKPOINT_GATE_META)
		await _check_checkpoint(saved_want)
		return
	camera.position = Vector3(-52.0, 34.0, -52.0)
	camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(4)
	var probe = registry.buildings[0]
	_blast(probe.xform.origin + Vector3(probe.recipe.footprint_x * 0.5 * STUD, 0.8, 0.3), 1.4)
	# A build placed after the city was built, and hit: the save has to carry
	# it, or the load has no building for those commands to land on.
	var placed_id := -1
	if _placed.is_empty():
		_place_build(BuildRecipe.shipped("cottage"))
	if not _placed.is_empty():
		placed_id = int(_placed[0]["id"])
		var pbox: AABB = CityPlacer.box_of(registry.get_building(placed_id))
		# Twice, a few ticks apart: the hit that turns a placed build into
		# bricks destroys none of them (measured 2026-10-08: 76 of 76 alive
		# after the first, 3 after the second -- not this gate's to fix).
		for shot in 2:
			_blast(pbox.position + Vector3(0.2, 1.0, pbox.size.z * 0.5), 1.0)
			await _frames(8)
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
	want["placed"] = placed_id
	want["placed_hit"] = want.buildings.has(placed_id)
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
	var pb := registry.get_building(int(want.get("placed", -1)))
	_gate_ok("a build placed before the save is there after the load, hit as it was",
			bool(want.get("placed_hit", false)) and pb != null and pb.is_build()
			and pb.is_materialised() and _placed.size() == 1,
			"building %d, hit before the save: %s, %d placed now" % [
			int(want.get("placed", -1)), want.get("placed_hit", false), _placed.size()])
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
		# A placed build of one frame has a twin too (its fixtures come with
		# its recipe); one of several frames is skipped, as every build was:
		# the replay below resolves frame 0 only.
		if b == null or (b.is_build() and not b.build.is_single_frame()):
			skipped += 1
			continue
		if b.is_build():
			twin_of[int(id)] = twin.register_build(b.build, b.xform)
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

	var loads := 0
	var unloads := 0
	for e in entries:
		if e.kind == DamageLog.Kind.LOAD:
			loads += 1
		elif e.kind == DamageLog.Kind.UNLOAD:
			unloads += 1
	print("[city] log replay: %d command(s) into %d twin building(s) (%d skipped), %d missed, %.0f ms; wreckage %d LOAD, %d UNLOAD" % [
		entries.size(), twin_of.size(), skipped, rep.missed, Time.get_ticks_msec() - t0, loads, unloads])
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
	var keys := ["render", "solve", "disable", "spawn", "remesh",
			"bands", "retire", "damage", "promote", "promote_finish", "stream", "collision",
			"islands", "hud"]
	if _frame_samples > 0:
		print("[prof] mean frame: %.1f ms physics (solver + this script), %.1f ms idle process" % [
				_phys_sum / _frame_samples, _proc_sum / _frame_samples])
	print("[prof] worst script tick %.1f ms  (%d islands)" % [
			_prof_worst_ms, int(_prof_worst.get("island_count", 0))])
	if not _prof_spikes.is_empty():
		var spikes := _prof_spikes.duplicate()
		spikes.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
		print("[prof] %d tick(s) over %.0f ms; the worst:" % [spikes.size(), SPIKE_MS])
		for k in mini(12, spikes.size()):
			print("[prof]   %.1f ms at tick %d: %s" % [spikes[k][0], spikes[k][1], spikes[k][2]])
	var line := ""
	for k in keys:
		line += "%s %.1f  " % [k, float(_prof_worst.get(k, 0.0))]
	print("[prof]   " + line)
	print("[prof]   of which damage: promote %.1f  rooms %.1f  hit %.1f  loose pieces %.1f  collision update %.1f"
			% [float(_prof_worst.get("dmg_promote", 0.0)), float(_prof_worst.get("dmg_rooms", 0.0)),
			float(_prof_worst.get("dmg_hit", 0.0)), float(_prof_worst.get("dmg_pieces", 0.0)),
			float(_prof_worst.get("dmg_disable", 0.0))])
	print("[prof]   of which collision: %d band(s) merged again, the worst building's %d in %.1f ms" % [
			int(_prof_worst.get("col_bands", 0.0)), int(_prof_worst.get("col_worst_bands", 0.0)),
			float(_prof_worst.get("col_worst", 0.0))])
	print("[prof]   of which rooms: scan %.1f  draw %.1f  open %.1f  body back %.1f  redraw %.1f  wrecks %.1f  shut %.1f  sync drawn %.1f  fake %.1f" % [
			float(_prof_worst.get("rm_scan", 0.0)), float(_prof_worst.get("rm_draw", 0.0)),
			float(_prof_worst.get("rm_open", 0.0)), float(_prof_worst.get("rm_swap", 0.0)),
			float(_prof_worst.get("rm_redraw", 0.0)), float(_prof_worst.get("rm_wreck", 0.0)),
			float(_prof_worst.get("rm_ladder", 0.0)), float(_prof_worst.get("rm_sync", 0.0)),
			float(_prof_worst.get("rm_fake", 0.0))])
	print("[prof]   of which fake: rooms worked out %.1f, drawing rebuilt %.1f (%d rooms in it)" % [
			float(_prof_worst.get("fk_rooms", 0.0)), float(_prof_worst.get("fk_attach", 0.0)),
			int(_prof_worst.get("fk_count", 0.0))])
	print("[prof] solves: worst single %.1f ms (%d bricks, %d groups, collapsing %s); mega buildings solved alone %d time(s), %.0f ms; %d batch(es) solved at once, worst %.1f ms" % [
			float(_solve_worst[0]), int(_solve_worst[1]), int(_solve_worst[2]), _solve_worst[3],
			int(_solve_mega[0]), float(_solve_mega[1]), _solve_batches, _solve_batch_worst])
	print("[prof] cascades: %d round(s) that failed something, at most %d in one solve; %d small group(s) held on by their own studs; %d second solve(s) in a tick put off" % [
			_cascade_rounds, _cascade_worst, _held_groups, _resolves_put_off])
	var sw: Array = islands.spawn_worst
	print("[prof] worst single spawn %.1f ms (%d bricks): split %.1f  shapes %.1f  node %.1f (furniture %.1f, into the scene %.1f, %d boxes)  mesh %.1f" % [
			float(sw[0]), int(sw[5]), float(sw[1]), float(sw[2]), float(sw[3]), float(sw[6]),
			float(sw[7]), int(sw[8]), float(sw[4])])
	print("[prof] worst single piece landing / re-solve: %s" % [islands.unit_worst])
	print("[prof] worst single building given back %.1f ms (%d bricks): dematerialise %.1f  free %.1f  shell %.1f; %d piece upload(s) waited a tick" % [
			float(_demote_worst[0]), int(_demote_worst[4]), float(_demote_worst[1]),
			float(_demote_worst[2]), float(_demote_worst[3]), islands.uploads_waited])
	var bw: Dictionary = islands.blind_worst_stages
	print("[prof] the longest invisible stretch, tick by tick: %s" % [bw])
	print("[prof]   of which disable: collision %.1f  furniture bodies %.1f; furniture redraw %.1f (in retire)" % [
			float(_prof_worst.get("dis_collision", 0.0)), float(_prof_worst.get("dis_rooms", 0.0)),
			float(_prof_worst.get("furniture", 0.0))])
	print("[prof]   of which bands: harvest %.1f (attach %.1f, finished %.1f)  bake slices %.1f  upload %.1f" % [
			float(_prof_worst.get("bd_harvest", 0.0)), float(_prof_worst.get("bd_apply", 0.0)),
			float(_prof_worst.get("bd_done", 0.0)), float(_prof_worst.get("bd_cpp", 0.0)),
			float(_prof_worst.get("bd_upload", 0.0))])
	print("[prof]   of which stream: trim %.1f  merge %.1f  rooms %.1f  detail %.1f  residency %.1f  shells %.1f"
			% [float(_prof_worst.get("st_trim", 0.0)), float(_prof_worst.get("st_merge", 0.0)),
			float(_prof_worst.get("st_rooms", 0.0)), float(_prof_worst.get("st_detail", 0.0)),
			float(_prof_worst.get("st_residency", 0.0)), float(_prof_worst.get("st_shells", 0.0))])
	print("[prof] %d building meshes rebuilt from scratch (the rest were index patches)"
			% _full_rebuilds)
	var tw: Dictionary = islands.tick_worst
	if not tw.is_empty():
		print("[prof] worst islands.tick %.1f ms = loop %.1f + resolve %.1f + fracture %.1f + mesh %.1f  (%d islands)" % [
				float(tw.total), float(tw.loop), float(tw.resolve), float(tw.fracture),
				float(tw.mesh), int(tw.islands)])
		print("[prof]   of which fracture: landings %.1f + merged rebuilds %.1f" % [
			float(tw.get("landings", 0.0)), float(tw.get("reshapes", 0.0))])
		print("[prof]   of which resolve (harvest, upload, mesh queue, band holes, resolve queue): %s; the slowest mesh the queue made %s" % [
			tw.get("resolve parts: harvest, upload, mesh queue, band holes, resolve queue", []),
			islands.mesh_drain_worst])
		print("[prof]   worst single piece reshape %.1f ms (%d bricks, %d boxes): shapes %.1f + space %.1f" % [
			float(islands.reshape_worst[0]), int(islands.reshape_worst[1]), int(islands.reshape_worst[2]),
			float(islands.reshape_worst[3]), float(islands.reshape_worst[4])])
	print("[prof]   of which the loop: pieces %.1f + dormancy %.1f (wake %.1f, sleep %.1f) + debris cap %.1f" % [
				float(tw.get("pieces", 0.0)), float(tw.get("dormancy", 0.0)),
				float(tw.get("wake", 0.0)), float(tw.get("sleep", 0.0)), float(tw.get("cap", 0.0))])
	print("[prof]   worst single wake %.1f ms (%d bricks), worst single sleep %.1f ms (%d bricks)" % [
				float(islands.wake_worst[0]), int(islands.wake_worst[1]),
				float(islands.sleep_worst[0]), int(islands.sleep_worst[1])])
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
			line += "%s %.2f  " % [k, float(_prof_sum.get(k, 0.0)) / maxi(_tick_samples, 1)]
		print("[prof] mean per tick: " + line)
		var tp: Dictionary = islands.tick_prof
		var n := maxi(int(islands.census.ticks), 1)
		print("[prof] islands per tick, whole run: loop %.2f (pieces %.2f, dormancy %.2f, cap %.2f)  resolve %.2f  fracture %.2f  mesh %.2f  multimesh %.2f" % [
				float(tp.loop) / n, float(tp.pieces) / n, float(tp.dormancy) / n, float(tp.cap) / n,
				float(tp.resolve) / n, float(tp.fracture) / n, float(tp.mesh) / n, float(tp.mm) / n])


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

	if _agents_mode:
		_spawn_many(Vector3(0.0, 0.0, 30.0))
		await _frames(30)
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
	# The arbiter (AIPlan R14): the AI stepped down while the city came apart,
	# and back up once it was quiet again.
	var ladder := ""
	for ph in ["under fire", "damage queue draining", "collapsing", "settled", "trimmed"]:
		ladder += "%s %d (tick %.1f ms)  " % [ph, int(_ai_phase_level.get(ph, 0)),
				float(_ai_phase_level.get("tick:" + ph, 0.0)) / maxi(int(_ai_phase_level.get("n:" + ph, 0)), 1)]
	print("[stress] AI ladder, deepest level per phase: %s-> now %d (deepest %d); AI sync+run %.2f ms a tick" % [
			ladder, ai_sched.get_level(), ai_sched.get_max_level_seen(),
			float(_prof_sum.get("ai", 0.0)) / maxi(_tick_samples, 1)])
	if budget != null:
		print("[stress] agents: %d smart, %d directed, %d swarm row(s); %d soldier(s), %d flyer(s), %d animal(s), %d promoted, %d demoted; budget %.2f ms a tick, swarm %.2f ms" % [
					int(budget.counts.smart), int(budget.counts.directed), swarm.alive(),
					_many.soldiers, _many.flyers, _many.animals, swarm.promoted, swarm.demoted,
					budget.last_ms, swarm.tick_ms()])
	# Stepped down when the collapse was heavy enough to call for it -- a run of
	# AI_HEAVY_TICKS ticks over AI_HEAVY_MS -- and back up after, either way.
	# The check used to require a step down, full stop, and failed once the
	# collapse itself got cheap enough never to need one (its worst ticks well
	# under 8 ms, one at a time): the arbiter doing nothing was the right answer.
	# The ladder itself, driven by a load that does call for it, is
	# tools/ai_world_probe.gd's.
	var called_for := _ai_heavy_run_max >= AI_HEAVY_TICKS
	print("[stress] destruction for the arbiter: worst tick %.1f ms, longest run over %.0f ms %d tick(s) -- a step down %s" % [
			_ai_destruction_peak, AI_HEAVY_MS, _ai_heavy_run_max,
			"was called for" if called_for else "was not called for"])
	print("[stress] %s  the AI stepped down under the collapse if it was heavy, and back up after" % (
			"ok   " if (ai_sched.get_max_level_seen() >= 1 or not called_for)
					and ai_sched.get_level() == 0
			else "FAIL "))
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
	print("[stress] islands %d (%d settled, %d small), %d gone coarse for distance, %d split(s)" % [
			isl.islands, isl.settled, isl.disposable, isl.dropped, isl.splits])
	print("[stress] coarse stand-ins: %d built (worst %.2f ms, %d vertices in all), %d left by pieces put to sleep" % [
			int(isl.coarse_built), float(isl.coarse_worst_ms), int(isl.coarse_verts), int(isl.stand_ins)])
	print("[stress] small pieces deleted where they came loose: %d brick(s) beyond %.0f m, %d unseen, %d of furniture"
			% [int(islands.report().tiny_deleted), IslandManager.SMALL_KEEP_RANGE,
			int(islands.report().discarded), int(islands.report().furniture_deleted)])
	print("[stress] bands built %d: C++ %.0f ms, upload %.0f ms, worst one %.1f ms" % [
			_band_builds, _band_cpp_ms, _band_upload_ms, _band_worst])
	print("[stress] near tier: %s" % brick_near.report())
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
	print("[stress] interior pieces a blast reached %d (%d laid as bricks) in %.0f ms" % [
			_pieces_hit, _pieces_laid, _pieces_hit_ms])
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
		if not seen.is_empty() and _building_for_body(struck_rid) == 0:
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


## Trees in the city (Docs/Impostors.md 8).
##
##     godot --path . scenes/city.tscn -- --terrain --trees
##
## They are there, drawn by their sets and nothing else; one materialised
## whole stands up on its own; one shot through the trunk comes down.
func _run_tree_pass() -> void:
	print("[trees] brick trees on the ground")
	await _frames(30)
	_gate_ok("trees were placed", _trees_placed > 0, "%d" % _trees_placed)
	if _trees_placed == 0:
		print("[trees] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
		get_tree().quit(1)
		return
	# The nearest tree to the middle of the city, and the camera by it.
	var trees: Array = _inst_handle.keys()
	var pick: int = trees[0]
	var best := INF
	for id in trees:
		var d := registry.get_building(id).xform.origin.length()
		if d < best:
			best = d
			pick = id
	var tb := registry.get_building(pick)
	var base := tb.xform * (registry.local_box(pick).get_center() * Vector3(1, 0, 1))
	camera.global_position = base + Vector3(10.0, 5.0, 14.0)
	camera.look_at(base + Vector3(0.0, 3.0, 0.0), Vector3.UP)
	await _far_settle()
	for i in 20:
		await RenderingServer.frame_post_draw
	var near := 0
	var far := 0
	for s in _inst_sets.values():
		near += (s as ImpostorLod).near_count
		far += (s as ImpostorLod).far_count
	var meshed := 0
	for id in trees:
		if _shells.has(id) and (_shells[id] as MeshInstance3D).mesh != null:
			meshed += 1
	print("[trees] %d trees in %d kinds: %d drawn as bricks, %d as cards; %d with a shell mesh" % [
		_trees_placed, _inst_sets.size(), near, far, meshed])
	# Counted by copy, not by buffer: a tree crossing the mesh-to-card band is
	# in both buffers, dithered into itself.
	var drawn := 0
	for id in trees:
		var tset: ImpostorLod = _inst_sets[_inst_key(registry.get_building(id))]
		if tset.is_drawn(int(_inst_handle[id])):
			drawn += 1
	_gate_ok("every tree is drawn by its set", drawn == _trees_placed,
			"%d of %d" % [drawn, _trees_placed])
	_gate_ok("  and none by a shell mesh of its own", meshed == 0)
	var baked := 0
	for s in _inst_sets.values():
		if not (s as ImpostorLod).bake.is_empty():
			baked += 1
	_gate_ok("every kind has its impostor baked", baked == _inst_sets.size(),
			"%d of %d" % [baked, _inst_sets.size()])
	_gate_ok("a tree in reach has collision", _shell_bodies.has(pick))
	await _save("trees_near")

	# Materialised whole, it has to stand: the canopy rests on the trunk.
	var chunk := _promote(pick)
	await _frames(90)
	var alive := world.get_alive_block_count(chunk) if chunk >= 0 else -1
	_gate_ok("a tree materialised whole stands", chunk >= 0 and not tb.toppled
			and alive == tb.build.size(), "%d of %d bricks, toppled %s" % [
				alive, tb.build.size(), tb.toppled])
	_gate_ok("  and its copy is not drawn over its bricks",
			not (_inst_sets[_inst_key(tb)] as ImpostorLod).is_drawn(int(_inst_handle[pick])))

	# Shot through the trunk, low: it comes down.
	var islands_before := islands.islands.size()
	_blast(base + Vector3(0.35, 0.6, 0.35), 0.9)
	var fell := false
	for i in 240:
		await RenderingServer.frame_post_draw
		if tb.toppled or islands.islands.size() > islands_before:
			fell = true
			break
	await _save("trees_shot")
	_gate_ok("a tree shot through the trunk comes down", fell,
			"toppled %s, islands %d -> %d" % [tb.toppled, islands_before, islands.islands.size()])

	# From the edge of the city: the cards.
	camera.global_position = base + Vector3(0.0, 40.0, 160.0)
	camera.look_at(base, Vector3.UP)
	await _far_settle()
	for i in 20:
		await RenderingServer.frame_post_draw
	await _save("trees_far")
	print("[trees] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## The far city's gate (Docs/Impostors.md, Stage 1).
##
##     godot --path . scenes/big_city.tscn -- --far --buildings=150
##
## Every building is drawn by exactly one thing at every distance; a damaged
## building out past SHELL_RANGE keeps a shell that shows the damage, with no
## body, and a shot still lands on it; walking back in gives the body back.
func _run_far_pass() -> void:
	print("[far] the city past SHELL_RANGE")
	# Outside the corner, low enough to see a skyline rather than a map.
	var span := _world_box(registry.buildings[registry.buildings.size() - 1]).end
	var corner := Vector3(-120.0, 40.0, -120.0)
	camera.global_position = corner
	camera.look_at(Vector3(span.x, 0.0, span.z) * 0.5, Vector3.UP)
	await _far_settle()

	var here := camera.global_position
	var undrawn := 0
	var twice := 0
	var past := 0
	for b in registry.buildings:
		if b.toppled or b.is_materialised():
			continue
		if b.xform.origin.distance_to(here) > SHELL_RANGE + SHELL_HYSTERESIS:
			past += 1
		# A coarse shell the far box draws has no mesh: that is one drawer.
		var shell: bool = _shells.has(b.id) and not _shell_box.has(b.id)
		var on_far: bool = _far_on.has(b.id)
		if _shell_box.has(b.id) and (_shells[b.id] as MeshInstance3D).mesh != null:
			twice += 1
		# A box under a banded shell that is fading (Stage 5) is what the
		# shell blends over: one building drawn, not two.
		if shell and on_far and float(_far_fade.get(b.id, 0.0)) == 0.0:
			twice += 1
		elif not shell and not on_far:
			undrawn += 1
	print("[far] %d buildings, %d past the shell range, %d shells, %d far boxes" % [
		registry.buildings.size(), past, _shells.size(), _far_on.size()])
	_gate_ok("there is a far city to draw", past > 0)
	_gate_ok("every building past the shell range is a far box", _far_on.size() >= past,
			"%d boxes for %d" % [_far_on.size(), past])
	var boxed := 0
	var coarse_bodies := 0
	for id in _shell_box:
		boxed += 1
		if _shell_bodies.has(id):
			coarse_bodies += 1
	print("[far] %d coarse shells drawn by the far box" % boxed)
	_gate_ok("the coarse tier is drawn by the far box", boxed > 0)
	_gate_ok("  and keeps its collision", coarse_bodies == boxed,
			"%d of %d" % [coarse_bodies, boxed])
	_gate_ok("no building is left undrawn", undrawn == 0, "%d undrawn" % undrawn)
	_gate_ok("no building is drawn twice", twice == 0, "%d twice" % twice)
	await _save("far_skyline")
	if _far_on.is_empty():
		# Nothing out there to shoot: a city too small for this pass.
		print("[far] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
		get_tree().quit(1)
		return

	# The farthest far box, its top blown off and left to settle the way the
	# trim leaves one.
	var far_id := -1
	var far_d := 0.0
	for id in _far_on:
		var d := registry.get_building(id).xform.origin.distance_to(here)
		if d > far_d:
			far_d = d
			far_id = id
	var fb := registry.get_building(far_id)
	var box := registry.local_box(far_id)
	_promote(far_id)
	await _frames(20)
	# A hole in the front wall low down, and the crown taken off.
	registry.damage(far_id, fb.xform * (box.position + box.size * Vector3(0.5, 0.3, 0.0)), 2.0)
	for f in [0.1, 0.3, 0.5, 0.7, 0.9]:
		for g in [0.1, 0.3, 0.5, 0.7, 0.9]:
			for h in [0.86, 0.93, 1.0]:
				registry.damage(far_id, fb.xform * (box.position + box.size * Vector3(f, h, g)), 6.0)
	await _frames(2)
	_demote(far_id, far_d)
	await _far_settle()
	print("[far] shot building %d at %.0f m: %d band(s) damaged" % [
		far_id, far_d, fb.damage_profile.size()])
	_gate_ok("a damaged far building is a far box", _far_on.has(far_id)
			and not _shells.has(far_id))
	_gate_ok("  with its damage in a row of the texture", _far_dmg_row.has(far_id)
			and _far_dmg_tex != null)
	var centre := fb.xform * (box.position + box.size * Vector3(0.5, 0.5, 0.5))
	# From straight above it, so no nearer building stands in the way.
	var hit := _ray_recipes(centre + Vector3(0.0, box.size.y + 30.0, 0.0), centre)
	_gate_ok("  a shot at it still lands", int(hit.get("building", -1)) == far_id,
			str(hit))

	# Docs/Impostors.md Stage 3: the blown-off top reads from every range.
	# From outside the city, on the line from its middle through this building,
	# so nothing nearer stands in the way.
	var middle := Vector3.ZERO
	for ob in registry.buildings:
		middle += ob.xform.origin
	middle /= float(registry.buildings.size())
	var front := fb.xform * (box.position + box.size * Vector3(0.5, 0.6, 0.5))
	var out := Vector3(front.x - middle.x, 0.0, front.z - middle.z).normalized()
	for dist in [130.0, 300.0, 1000.0]:
		camera.global_position = front + out * dist + Vector3(0.0, dist * 0.08, 0.0)
		camera.look_at(front, Vector3.UP)
		await _far_settle()
		var drawn := ("far box" + (" for its coarse shell" if _shell_box.has(far_id) else "") if _far_on.has(far_id)
				else "shell" if _shells.has(far_id) else "nothing")
		print("[far]   at %4.0f m: %s" % [dist, drawn])
		await _save_crop("far_top_%d" % int(dist), 60.0 / dist)

	# Walk up to it: inside the shell range it is a solid shell again.
	var aim := fb.xform * (box.position + box.size * 0.5)
	camera.global_position = aim + Vector3(0.0, 20.0, -(SHELL_RANGE - 80.0))
	camera.look_at(aim, Vector3.UP)
	await _far_settle()
	_gate_ok("closer in, it is a coarse shell with a body, drawn by the far box",
			_shell_bodies.has(far_id) and _shell_box.has(far_id) and _far_on.has(far_id))
	# And inside SHELL_DETAIL_RANGE, the banded shell with its holes.
	camera.global_position = aim + Vector3(0.0, 0.0, -(SHELL_DETAIL_RANGE - 70.0))
	camera.look_at(aim, Vector3.UP)
	await _far_settle()
	# Its far box is still there, flagged, just inside the banded shell for
	# the shell's fade to blend over (Stage 5); inside FADE_NEAR the shell is
	# opaque and hides it.
	_gate_ok("closer still, a banded shell, its box only its crossfade", _shells.has(far_id)
			and not _shell_box.has(far_id) and _shell_bodies.has(far_id)
			and (not _far_on.has(far_id) or float(_far_fade.get(far_id, 0.0)) > 0.0),
			"shell %s, box tier %s, body %s, far box %s, bricks %s, aim-promoted %d" % [
			_shells.has(far_id), _shell_box.has(far_id), _shell_bodies.has(far_id),
			_far_on.has(far_id), fb.is_materialised(), aim_promotions])

	# Stage 4: player builds out there are cards, one bake for identical ones.
	var tower := BuildRecipe.load_from(BuildRecipe.shipped("watchtower"))
	var far_at := here + Vector3(-600.0, 0.0, -600.0)
	var b1 := registry.register_build(tower, Transform3D(Basis(), BrickWorld.grid_to_world(
			Vector3i(int(far_at.x / STUD), 0, int(far_at.z / STUD)))))
	var b2 := registry.register_build(tower, Transform3D(Basis(), BrickWorld.grid_to_world(
			Vector3i(int(far_at.x / STUD) + 60, 0, int(far_at.z / STUD)))))
	_index_building(b1)
	_index_building(b2)
	camera.global_position = here
	camera.look_at(far_at, Vector3.UP)
	await _far_settle()
	var bb1 := registry.get_building(b1)
	var key := _inst_key(bb1)
	var set_: ImpostorLod = _inst_sets.get(key)
	_gate_ok("Stage 4: a far player build has no shell", not _shells.has(b1) and not _shells.has(b2))
	_gate_ok("  both are drawn by one set", set_ != null and _inst_key(registry.get_building(b2)) == key
			and set_.is_drawn(int(_inst_handle.get(b1, -1)))
			and set_.is_drawn(int(_inst_handle.get(b2, -1))))
	var baked_guard := 0
	while set_ != null and set_.bake.is_empty() and baked_guard < 300:
		await RenderingServer.frame_post_draw
		baked_guard += 1
	_gate_ok("  as a card, baked once for both", set_ != null and not set_.bake.is_empty()
			and set_.tier_of(int(_inst_handle[b1])) == 2)
	await _save_crop("far_builds", 0.25)
	camera.global_position = bb1.xform.origin + Vector3(40.0, 30.0, 150.0)
	camera.look_at(bb1.xform.origin, Vector3.UP)
	await _far_settle()
	_gate_ok("  closer in, its own shell and no card", _shells.has(b1)
			and (_shells[b1] as MeshInstance3D).mesh != null
			and not set_.is_drawn(int(_inst_handle[b1])),
			"shell %s, mesh %s, card tier %d, %.0f m" % [_shells.has(b1),
			_shells.has(b1) and (_shells[b1] as MeshInstance3D).mesh != null,
			set_.tier_of(int(_inst_handle[b1])), bb1.xform.origin.distance_to(camera.global_position)])
	# Damaged, it keeps its exact shell even out there.
	var bb2 := registry.get_building(b2)
	_promote(b2)
	await _frames(20)
	var lb := registry.local_box(b2)
	for f in [Vector3(0.5, 0.1, 0.0), Vector3(0.0, 0.1, 0.5), Vector3(0.5, 0.5, 0.5)]:
		registry.damage(b2, bb2.xform * (lb.position + lb.size * f), 1.5)
	await _frames(2)
	_demote(b2, 400.0)
	camera.global_position = here
	camera.look_at(far_at, Vector3.UP)
	await _far_settle()
	print("[far]   damaged build: damaged %s, shell %s, far shell %s, card %s, bricks %s" % [
		bb2.is_damaged(), _shells.has(b2), _shell_far.has(b2),
		set_.is_drawn(int(_inst_handle[b2])), bb2.is_materialised()])
	_gate_ok("  a damaged one keeps its shell out there, without the card",
			_shells.has(b2) and _shell_far.has(b2) and not set_.is_drawn(int(_inst_handle[b2])))

	# Stage 5: across the fade band a banded shell and its box are both drawn,
	# the shell fading out and the box flagged to fade in.
	var mid_id := -1
	for ob in registry.buildings:
		if not ob.is_build() and not ob.toppled and not ob.is_materialised():
			mid_id = ob.id
			break
	var mb := registry.get_building(mid_id)
	var mc := _world_box(mb).get_center()
	camera.global_position = mc + Vector3(0.0, 10.0, -(FADE_NEAR + FADE_FAR) * 0.5)
	camera.look_at(mc, Vector3.UP)
	await _far_settle()
	var banded: bool = _shells.has(mid_id) and not _shell_coarse.get(mid_id, true)
	var faded: bool = banded and (_shells[mid_id] as GeometryInstance3D).visibility_range_fade_mode \
			== GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_gate_ok("Stage 5: in the fade band, a banded shell that fades out", faded,
			"banded %s" % banded)
	_gate_ok("  and its far box, flagged to fade in", _far_on.has(mid_id)
			and float(_far_fade.get(mid_id, 0.0)) > 0.0)
	for d in [70.0, 100.0, 125.0, 150.0]:
		camera.global_position = mc + Vector3(0.0, 10.0, -d)
		camera.look_at(mc, Vector3.UP)
		await _far_settle()
		await _save_crop("fade_%d" % int(d), 0.5)

	# The crossfade leaves no holes. It rests on how Godot fades an instance
	# (blended, over [end - margin, end + margin] from its bounds' centre);
	# if an engine update changes that, this is what fails.
	# In the middle of the band, from low down so the building stands on sky:
	#   A  the crossfade as it runs;
	#   B  the shell alone, not fading -- the reference;
	#   C  the shell fading with no box under it -- holes at the fade's rate.
	# Holes are pixels of the building far from B: the box under the blend
	# makes A nearly B, where C shows the sky through the fading shell.
	camera.global_position = mc + Vector3(0.0, -mc.y + 1.5, -(FADE_NEAR + FADE_FAR) * 0.5)
	camera.look_at(mc + Vector3(0.0, mb.recipe.courses * 0.1, 0.0), Vector3.UP)
	await _far_settle()
	var shell_mi: MeshInstance3D = _shells.get(mid_id)
	if shell_mi != null and _far_on.has(mid_id):
		var rect := _screen_rect(_world_box(mb))
		var img_a := await _grab()
		var ranged: Array[GeometryInstance3D] = [shell_mi]
		for ch in shell_mi.get_children():
			if ch is GeometryInstance3D:
				ranged.append(ch)
		for g in ranged:
			g.visibility_range_end = 0.0
		var img_b := await _grab()
		for g in ranged:
			_fade_out(g)
		_far.visible = false
		var img_c := await _grab()
		_far.visible = true
		var holes_a := _holes(img_a, img_b, rect)
		var holes_c := _holes(img_c, img_b, rect)
		print("[far]   crossfade: %.1f%% of the building off its reference, against %.1f%% with no box" % [
			holes_a * 100.0, holes_c * 100.0])
		# The control's floor is for the settings a pass runs on -- the menu's
		# defaults (TestWindow.use_default_settings): MSAA 2x and FXAA, under
		# which a fading shell with no box shows 4.7 % holes. It was 0.05, set
		# when passes ran on whatever was saved in Options: 8.8 % with both
		# off, 6.4 and 5.1 with one. What the check is for is the second half:
		# the crossfade is a small fraction of that, whatever it is.
		_gate_ok("Stage 5: the crossfade leaves no holes", holes_c > 0.03 and holes_a < holes_c * 0.25,
				"%.3f vs %.3f" % [holes_a, holes_c])
	else:
		_gate_ok("Stage 5: the crossfade leaves no holes", false,
				"no fading shell to look at: shell %s, far box %s, bricks %s, aim-promoted %d" % [
				shell_mi != null, _far_on.has(mid_id), mb.is_materialised(), aim_promotions])

	print("[far] %d ok, %d FAIL" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## A screenshot of the middle of the view, blown up: `frac` of the screen's
## size, scaled back to full height, so a building a kilometre off is big
## enough to judge.
func _save_crop(shot_name: String, frac: float) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var full := img.get_size()
	var size := Vector2i(int(full.x * frac), int(full.y * frac))
	img = img.get_region(Rect2i(Vector2i(Vector2(full - size) / 2.0), size))
	img.resize(full.x, full.y, Image.INTERPOLATE_NEAREST)
	img.save_png("res://shots/%s.png" % shot_name)
	print("[city] shot written: %s.png" % shot_name)


## The screen rectangle a world box covers, clamped to the view.
func _screen_rect(box: AABB) -> Rect2i:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var p := box.position + box.size * Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1)
		if camera.is_position_behind(p):
			continue
		var s := camera.unproject_position(p)
		lo = lo.min(s)
		hi = hi.max(s)
	var view := Vector2(get_viewport().get_visible_rect().size)
	lo = lo.clamp(Vector2.ZERO, view)
	hi = hi.clamp(Vector2.ZERO, view)
	return Rect2i(Vector2i(lo), Vector2i(hi - lo))


func _grab() -> Image:
	for i in 3:
		await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Share of `rect`, shrunk a little off its edges, where `img` is far from
## `ref`: a hole shows what is behind, and here that is sky.
static func _holes(img: Image, ref: Image, rect: Rect2i) -> float:
	var r := rect.grow(-floori(maxi(rect.size.x, rect.size.y) / 12.0))
	if r.size.x <= 0 or r.size.y <= 0:
		return 0.0
	var off := 0
	var n := 0
	for y in range(r.position.y, r.end.y, 2):
		for x in range(r.position.x, r.end.x, 2):
			n += 1
			var a := img.get_pixel(x, y)
			var b := ref.get_pixel(x, y)
			if absf(a.get_luminance() - b.get_luminance()) > 0.2:
				off += 1
	return float(off) / maxf(n, 1)


## Frames until the shell streamer has had a full quiet pass over the register.
func _far_settle() -> void:
	var last := -1
	var quiet := 0
	# And two whole passes of the streamer over the register: ninety quiet
	# FRAMES is a third of a second at a high frame rate, less than one pass
	# with the trees in it, and a building it had not reached yet was read as
	# having no shell.
	var from := _stream_cursor
	for i in 1200:
		await RenderingServer.frame_post_draw
		var n := _shells_made + _shells_freed + _shells_swapped + _far_on.size() \
				+ _shell_far.size() + _shell_bodies.size()
		quiet = quiet + 1 if n == last else 0
		last = n
		if quiet >= 90 and _stream_cursor - from >= registry.buildings.size() * 2:
			return


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
			if _brick_cols.has(0):
				(_brick_cols[0] as BuildingCollision).free_bodies()
				_brick_cols.erase(0)
			if _brick_nodes.has(0):
				(_brick_nodes[0] as MeshInstance3D).queue_free()
				_brick_nodes.erase(0)
			_brick_meshes.erase(0)
			_brick_index_bytes.erase(0)
			_brick_index_width.erase(0)
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

## Does the shaded chamfer do anything, and does it stop doing it at range?
##
## A bevel on every edge of every block would be four quads a face -- five times
## the triangles for something 13 mm wide. It is shaded instead, so the only
## test that means anything is the rendered picture: one frame with it and one
## without, differenced. The second half matters as much as the first: a
## sub-pixel highlight that does not fade out shimmers, which is the same reason
## the seam fades (spec section 2, layer lines).
func _run_chamfer_pass() -> void:
	# `-- --chamfer --cost`: what the near tier costs where it is paid --
	# shooting at, and then bringing down, a building the camera stands beside.
	# A timing run (CLAUDE.md: the editor closed), and with `--no-near` the
	# same run without the tier, to set beside it.
	if "--cost" in OS.get_cmdline_user_args():
		await _run_chamfer_cost()
		get_tree().quit(0)
		return
	print("[chamfer] real bevels where the camera is, none where it is not")
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

	# The wall in front of the camera is drawn with its chamfered mesh
	# (BrickNear), and the studs within reach as studs.
	var near_off := await _capture_chamfer(false, "chamfer_off")
	_gate_ok("with the near tier off, nothing is chamfered", brick_near.chamfered_bands == 0)
	var near_on := await _capture_chamfer(true, "chamfer_on")
	_gate_ok("a wall a metre and a half off is drawn chamfered", brick_near.chamfered_bands > 0,
			"%d bands, %d triangles, %d studs; worst step %.2f ms" % [brick_near.chamfered_bands,
				brick_near.chamfered_tris, brick_near.stud_instances, brick_near.worst_step_ms])
	_gate_ok("and its exposed studs are geometry", brick_near.stud_instances > 0,
			"%d" % brick_near.stud_instances)
	var near_diff := _image_difference(near_off, near_on)
	_gate_ok("up close, the bevel changes the picture", near_diff > 0.01,
			"%.1f%% of sampled pixels" % (near_diff * 100.0))
	_gate_ok("but does not repaint the whole wall -- it is edges, not a tint",
			near_diff < 0.75, "%.1f%%" % (near_diff * 100.0))

	# Shot at: the chamfered bands are patched as the flat ones are. What their
	# index buffers draw is read back and set against the bricks left alive.
	var before: Dictionary = brick_near.audit()
	_blast(wall + Vector3(0.6, 0.3, 0.2), 1.1)
	await _frames(20)
	brick_near.settle(camera.global_position)
	await _frames(4)
	var after: Dictionary = brick_near.audit()
	_gate_ok("a hit takes triangles out of the chamfered bands", int(after.bands) > 0
			and int(after.drawn) != int(before.drawn),
			"%d drawn before, %d after" % [before.drawn, after.drawn])
	_gate_ok("and they draw exactly the bricks left", int(after.drawn) == int(after.wanted),
			"%d drawn, %d wanted, over %d bands" % [after.drawn, after.wanted, after.bands])
	await _save("chamfer_hit")

	# And from across the street there is none: at that size it is noise, and
	# it is not paid for.
	camera.global_position = wall - Vector3(0.0, -6.0, 110.0)
	camera.look_at(wall, Vector3.UP)
	await _frames(10)
	var far_off := await _capture_chamfer(false, "")
	var far_on := await _capture_chamfer(true, "")
	_gate_ok("at a hundred metres no band is chamfered", brick_near.chamfered_bands == 0
			and brick_near.stud_instances == 0,
			"%d bands, %d studs" % [brick_near.chamfered_bands, brick_near.stud_instances])
	var far_diff := _image_difference(far_off, far_on)
	_gate_ok("and the picture is the same either way", far_diff < 0.01,
			"%.2f%% of sampled pixels" % (far_diff * 100.0))

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Frame times while a building six metres from the camera is shot at and then
## cut down, with whatever near tier the run has.
func _run_chamfer_cost() -> void:
	print("[chamfer] cost, near tier %s" % ("ON" if BrickNear.enabled else "OFF (--no-near)"))
	# The renderer's own clock as well as the frame's: a frame is held to the
	# display's 16.6 ms whatever it cost to draw.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var b := registry.get_building(0)
	var chunk := _promote(0)
	await _frames(60)
	var fx: float = b.recipe.footprint_x * STUD
	var wall: Vector3 = b.xform * Vector3(fx * 0.5, 2.6, 0.0)
	camera.global_position = wall - Vector3(1.5, -0.4, 6.0)
	camera.look_at(wall, Vector3.UP)
	await _frames(10)
	brick_near.settle(camera.global_position)
	await _frames(30)
	print("[chamfer]   standing: %d bricks, %d bands; %s" % [world.get_alive_block_count(chunk),
			world.get_chunk_sections(chunk), brick_near.report()])
	var idle: Array = await _frame_times(120)
	print("[chamfer]   looking at it: %s" % _frame_line(idle))

	# Twelve shots into the wall, one every five frames.
	var hits := []
	for i in 12:
		_blast(wall + Vector3(-1.5 + 0.5 * float(i % 6), -0.8 + 0.9 * floorf(float(i) / 6.0), 0.3), 0.9)
		hits.append_array(await _frame_times(5))
	hits.append_array(await _frame_times(30))
	print("[chamfer]   twelve shots: %s" % _frame_line(hits))
	print("[chamfer]   %s" % brick_near.report())

	# And down: its bottom courses cut through from the camera's side.
	for i in 10:
		_blast(b.xform * Vector3(fx * (0.05 + 0.1 * float(i)), 0.9, 0.3), 2.2)
	var fall: Array = await _frame_times(360)
	print("[chamfer]   brought down: %s" % _frame_line(fall))
	print("[chamfer]   %s" % brick_near.report())
	await _save("chamfer_cost_%s" % ("near" if BrickNear.enabled else "flat"))


## The next `n` frames: each one's length, and what the renderer says the
## frame before it took to draw on the CPU and on the GPU, in ms.
func _frame_times(n: int) -> Array:
	var out := []
	var view := get_viewport().get_viewport_rid()
	var last := Time.get_ticks_usec()
	for i in n:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		out.append([float(now - last) / 1000.0,
				RenderingServer.viewport_get_measured_render_time_cpu(view)
				+ RenderingServer.get_frame_setup_time_cpu(),
				RenderingServer.viewport_get_measured_render_time_gpu(view)])
		last = now
	return out


func _frame_line(times: Array) -> String:
	var sum := 0.0
	var worst := 0.0
	var cpu := 0.0
	var gpu := 0.0
	var gpu_worst := 0.0
	for t in times:
		sum += float(t[0])
		worst = maxf(worst, float(t[0]))
		cpu += float(t[1])
		gpu += float(t[2])
		gpu_worst = maxf(gpu_worst, float(t[2]))
	var n := maxf(times.size(), 1.0)
	return "%d frames, mean %.1f ms, worst %.1f; drawing them: CPU %.2f ms, GPU %.2f (worst %.2f)" % [
			times.size(), sum / n, worst, cpu / n, gpu / n, gpu_worst]


## Render one frame with the near tier -- chamfered bands, bevelled studs -- on
## or off and hand back the image. A name also writes it to shots/, for the eye
## to judge what a number cannot.
func _capture_chamfer(on: bool, shot_name: String) -> Image:
	BrickNear.enabled = on
	brick_near.settle(camera.global_position)
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


# ---------------------------------------------------------------------------
# The interiors gate
# ---------------------------------------------------------------------------


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
	# Asleep is not gone from view: each piece left its coarse stand-in drawn
	# where it lay (IslandManager._leave_stand_in). A single brick is drawn by
	# the shared MultiMesh and leaves none.
	var drawn := 0
	var singles := 0
	for d in islands.dormant:
		if d.record.block_count() == 1:
			singles += 1
		elif d.stand_in != null and is_instance_valid(d.stand_in) \
				and d.stand_in.is_inside_tree() and d.stand_in.mesh != null:
			drawn += 1
	_gate_ok("and it is still drawn where it lay", drawn > 0 and drawn + singles == int(rep.dormant),
			"%d stand-in(s) for %d asleep, %d single brick(s)" % [drawn, int(rep.dormant), singles])
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
	# Each piece as it wakes draws its stand-in until its bricks are baked: a
	# woken piece used to be invisible for the tick or two that took.
	var blind_on_waking := 0
	var woken_before := int(islands.report().woken)
	while guard < 1200 and int(islands.report().dormant) > 0:
		await _frames(1)
		guard += 1
		if int(islands.report().woken) > woken_before:
			woken_before = int(islands.report().woken)
			for isl in islands.islands:
				if islands.is_blind(isl):
					blind_on_waking += 1
	var stand_ins_left := 0
	for child in islands.get_children():
		if child is MeshInstance3D and not child.is_queued_for_deletion():
			stand_ins_left += 1
	rep = islands.report()
	_gate_ok("a piece waking draws from its first tick", blind_on_waking == 0,
			"%d blind piece-tick(s) as they woke" % blind_on_waking)
	_gate_ok("and the stand-ins it left are gone", stand_ins_left == 0,
			"%d left" % stand_ins_left)
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
	var slept_id := target.piece_id
	var before_blast := {}
	for isl in islands.islands:
		before_blast[isl] = true
	_blast(at, 3.0)
	guard = 0
	while not _damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)
	# THAT piece, by its id -- not every piece within 20 m of the blast, which
	# counted its neighbours' bricks too (2,814 "left" of a 1,421-brick piece).
	var woke := false
	var left := 0
	for isl in islands.islands:
		if isl.is_valid() and isl.piece_id == slept_id:
			woke = true
			left = world.get_alive_block_count(isl.chunk)
	_gate_ok("a blast wakes what it reaches", woke, "piece %d" % slept_id)
	_gate_ok("and takes bricks out of it", left > 0 and left < held,
			"%d of %d left" % [left, held])
	# Out here -- 300 m off -- the piece it woke goes on drawing the stand-in it
	# left, rebuilt for what the blast took, and anything the blast broke off
	# comes up as a stand-in too: nothing out here is baked or uploaded as
	# bricks (IslandManager.ISLAND_MESH_RANGE).
	var woken_coarse := false
	var new_coarse := 0
	var new_bricks := 0
	for isl in islands.islands:
		if not isl.is_valid() or isl.mesh == null:
			continue
		if isl.piece_id == slept_id:
			woken_coarse = isl.coarse and isl.coarse_drawn
		elif not before_blast.has(isl):
			if isl.coarse:
				new_coarse += 1
			else:
				new_bricks += 1
	_gate_ok("far off, the piece it woke draws its stand-in", woken_coarse)
	_gate_ok("and what it broke off comes up as stand-ins, never as bricks", new_bricks == 0,
			"%d stand-in(s), %d as bricks" % [new_coarse, new_bricks])

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
	# One spiral piece per two steps (StaircaseRecipe.build_flight): the count
	# is pieces. It was steps, from before the flight was built from spiral
	# pieces, and 27 steps are 14 pieces.
	var pieces := StaircaseRecipe.flight_pieces(steps)
	_gate_ok("every step is there", f.blocks.size() == pieces,
			"%d pieces of %d for %d steps" % [f.blocks.size(), pieces, steps])
	_gate_ok("in the SAME chunk as the building", chunk == b.chunk)
	# A chunk per building in bricks and none more: the staircase is not one.
	# It was "one chunk", which counted on nothing else being bricks -- and the
	# camera at rest here may be aiming at another building (_aim_promote).
	var in_bricks := 0
	for o in registry.buildings:
		if o.is_materialised():
			in_bricks += 1
	_gate_ok("so the city holds a chunk for each building in bricks, none for its stairs",
			int(world.get_memory_report().chunks) == in_bricks,
			"%d chunk(s), %d building(s) in bricks" % [
				int(world.get_memory_report().chunks), in_bricks])

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
	# DROPPED: feet a little above the tread, the eye EYE_HEIGHT above them. It
	# was put a metre above the tread, which is the figure half a metre INTO it,
	# and whether the solver pushed it out upwards or let it sink through was
	# down to the shape of the box it was stuck in.
	camera.global_position = tread + Vector3(0.0, DebugCamera.EYE_HEIGHT + 0.3, 0.0)
	camera.set_walking(true)
	var body := camera.body()
	var landed := 0
	# Until it is on the floor. A figure just put down has no speed yet, so
	# "slow enough" is true before it has fallen at all.
	while landed < 150 and (body == null or not body.is_on_floor()):
		await _frames(1)
		landed += 1
		body = camera.body()
	var stood_on := _what_is_under(body)
	await _frames(10)
	_gate_ok("a figure dropped onto the flight comes to rest on it",
			body != null and (body.is_on_floor() or absf(body.velocity.y) < 0.15),
			"on floor %s, vy %.2f; landed on %s, now over %s" % [
					body.is_on_floor() if body != null else false,
					body.velocity.y if body != null else 0.0, stood_on, _what_is_under(body)])
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
	# In the BUILDING's own dead list -- the steps it lost are its bricks. Not
	# "fewer bricks than before": the rooms around the camera open while this
	# waits and lay their furniture, and the count went up (638 -> 647).
	var dead_steps := 0
	for id in world.get_dead_blocks(chunk):
		if f.blocks.has(id):
			dead_steps += 1
	_gate_ok("and the building is the thing that is damaged",
			registry.get_building(0).is_damaged() and dead_steps > 0,
			"%d dead steps in the building's record" % dead_steps)

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

	# The shell's own collision, tested from outside AIM_PROMOTE_RANGE -- which
	# is now the only place a shell survives being looked at: walking up to a
	# building makes it bricks (PROMOTE_RANGE), and so does aiming at it from
	# nearer than that (_aim_promote). It was seventy metres, which aiming now
	# reaches. A ray is how a shell gets hit in practice anyway: FIRE_RANGE is
	# 2 km against SHELL_RANGE's 260 m, so most shots that land on a building
	# land on one of these.
	camera.set_walking(false)
	camera.global_position = centre - Vector3(0.0, -3.0, d * 0.5 + AIM_PROMOTE_RANGE + 20.0)
	camera.look_at(Vector3(centre.x, 3.0, centre.z), Vector3.UP)
	await _frames(20)
	_gate_ok("from past aiming range it is a shell and nothing else",
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
	# A beam with 1.90 m under it: clear standing from the ground (the figure is
	# four bricks, 1.68 m), not clear standing on one brick course (2.10 m), and
	# clear again crouched on it (a brick shorter, 1.68 m). It was 1.40 m, sized
	# for the old three-brick figure, which a four-brick one could not get under
	# on the ground or crouched on the brick.
	var beam := _test_block(room + Vector3(0.0, 2.0, 0.0), Vector3(6.0, 0.2, 1.2))
	camera.global_position = room + Vector3(0.0, DebugCamera.EYE_HEIGHT, -4.0)
	camera.look_at(Vector3(room.x, DebugCamera.EYE_HEIGHT, room.z + 6.0), Vector3.UP)
	camera.set_walking(true)
	await _frames(40)
	# Until it is past the beam, in physics ticks, ten seconds at most. It was
	# 150 drawn frames, which at a few hundred frames a second is half a second
	# of walking -- a metre and a half of the five it had to cover.
	_key(KEY_W, true)
	var walk_ticks := 0
	while walk_ticks < 300 and camera.global_position.z <= room.z + 1.0:
		await get_tree().physics_frame
		walk_ticks += 1
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
	# Physics ticks, as above: until past the beam, ten seconds at most.
	var ticks := 0
	while ticks < 300 and camera.global_position.z <= room.z + 1.0:
		await get_tree().physics_frame
		ticks += 1
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
		if _brick_cols.has(id):
			building_shapes += (_brick_cols[id] as BuildingCollision).shape_count()
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
			+ "%d in settled wreckage; building bands merged %d time(s) (%.1f ms total, worst %.1f) "
			+ "and un-merged %d (%.1f ms, worst %.1f); "
			+ "islands merged %d time(s), %d boxes against %d unmerged") % [
			building_shapes, _materialised.size(), building_blocks, furniture,
			falling, settled_boxes,
			BuildingCollision.merges, BuildingCollision.merge_ms, BuildingCollision.merge_worst,
			BuildingCollision.unmerges, BuildingCollision.unmerge_ms, BuildingCollision.unmerge_worst,
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
	# A raking sun in terrain mode: at 50 degrees nothing on the ground is in
	# shadow, because the steepest slope the field makes is 42, and the baked
	# shadow is a no-op that reads as flat lighting (Docs/Terrain.md §19.7).
	sun.rotation_degrees = Vector3(-30 if _terrain_mode else -50, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	_setup_sun_shadows(sun)
	add_child(sun)
	_sun = sun

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

	camera = DebugCamera.new()
	camera.name = "DebugCamera"
	# Every scripted pass drives the camera itself. Leaving the debug camera
	# captured let it keep applying its own movement and mouse-look on top,
	# which is why the reach probe reported misses at 40 m.
	camera.capture_mouse = not (_shot_mode or _stress_mode or _reach_mode or _far_mode or _tree_mode or _lod_mode
			or _walk_mode or _build_mode or _fixture_mode or _dormant_mode
			or _chamfer_mode
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
