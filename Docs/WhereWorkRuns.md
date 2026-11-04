# Where the work runs

Every system the game runs, where its work happens now (main thread, a worker, the GPU, an
engine thread), whether that is the right place, and what would move it if not. Audited
2026-11-04 from the code (every `_process` / `_physics_process` and what it calls, plus every
`WorkerThreadPool` / `std::thread` use), the profilers' phase names (`CityScene._SPIKE_PARTS`,
`[ai-prof]`, `[street]`) and the measurements in PerfCaps.md, Status.md, Planets.md and AI.md.
The GPU side has its own doc, [GpuOffload.md](GpuOffload.md); the large jobs that would change
where things run are in section 3.

The machine this is for: a Legion Go (Ryzen Z1 Extreme, 8 cores, the GPU on the same chip and
the same power budget). More threads busy at once is more heat (CLAUDE.md, the crash issue), so
"move it to a worker" is only a win where the main thread is what a frame waits for.

## 1. The rules the code already follows

* **Never bake bricks on the main thread.** Bakes are `BrickWorld.bake_chunk_async` (a C++
  thread a chunk); the caller comes back when `bake_ready`. Islands, stations and (since
  2026-11-04) planet pieces all do this.
* **Meshes are built on workers and uploaded there** (`WorkerThreadPool`, compressed,
  `UPLOAD_COMPRESS`); the main thread attaches the finished mesh. About a third of an upload
  still lands on the main thread: the renderer makes the buffers at its next main-thread call
  (section 3.1).
* **Arrays from a C++ worker are made into Godot arrays on that worker** (stand-ins and
  chamfered bands since 2026-11-04: `take_coarse_mesh` 2-5 ms -> 0.0).
* **Per-tick budgets** where work cannot leave: `SPAWN_BUDGET_MS`, `BAND_VERTS_PER_TICK`,
  `Encounter.BUDGET_MS`, one stand-in / one snow square / one shadow proxy a pass.
* **Things that move without being decided are the GPU's**: crumbs, particles and ice shards
  are written once and moved by their shaders (GpuOffload.md 2.1, 2.2, 2.7).
* **Nodes, bodies and shapes are made on the main thread.** The scene tree and the physics
  space are not thread-safe; Godot allows building a body's shapes before it joins the space,
  and the code does that (`add_chunk_shapes` before `add_child`).

## 2. System by system

Columns: where it runs now; the cost where it was measured; the verdict -- **right** (leave
it), **could move** (worth it if the number says so), or **moved** (done, with when).

### Bricks, buildings, destruction

| System | Runs on | Cost measured | Verdict |
|---|---|---|---|
| Face bake of a chunk | C++ thread a chunk | most of a second for a 2,000-brick half | right |
| Band / pane / glass / shadow-shell meshes (city) | worker, uploaded there | renderer's share 1-1.5 ms a 62k-vertex band | right; renderer share is 3.1 |
| Far stand-ins (coarse) | C++ thread + worker upload | show 0.1-0.5 ms, one spike 35 ms (renderer wait) | moved 2026-11-04 (array copy); renderer share is 3.1 |
| Chamfered near bands | C++ thread + worker upload | -- | moved 2026-11-04 (array copy) |
| Structure solve, several buildings in a tick | a thread each (`solve_structures`) | -- | right |
| Structure solve, one building | **main** (`solve_structure`) | 3-6 ms worst for a 22,000-brick tower | could move: 3.3 |
| Damage applied to bricks (`DamageLog.apply_entry`) | main (C++) | sub-ms | right: it is the write everything else reads |
| Shadow proxy damage profile | **main** (C++ walk) | 2-7 ms logged 10-23; walk since 0.12 ms mean | measure first: 3.4 |
| Shadow casting switch (`_set_brick_shadows_near`) | main, renderer calls | 33 ms once on the walk (a renderer wait) | right; the wait is 3.1 |
| Fracture: split, pieces spawned (nodes, bodies) | main | the worst ticks of a collapse (`spawn`, `fracture`, `promote_finish` 42 ms) | right place; must get cheaper, not move |
| Island tick (landings, reshapes, resolve) | main (GDScript + C++) | worst `islands.tick` 8-12 ms | right; bodies and shapes are main-thread |
| Building collision (merged boxes) | main | 1-2 ms a promotion | right (physics space) |
| Promotion (a building into bricks) | main, budgeted 3 ms a tick | ~3 ms, 7.5 for a 42-course tower | right; budgeted |
| Planet pieces' mesh | C++ bake + worker upload | shed on a landing 11-13 -> 4-8 ms | moved 2026-11-04 |
| Planet far tier (one box per site) | **main**, a loop over every site every frame | not measured; ~210 sites a town, a sqrt and a fade each | could move to the GPU: 3.5 |
| Crumbs, city and planets | GPU (shader), CPU writes on events | -- | moved 2026-11-02/03 |

### Effects

| System | Runs on | Verdict |
|---|---|---|
| Death bursts, hit debris, collapse dust, torch, vehicle smoke | GPU particles | moved 2026-11-03 |
| Ice shards (frozen kill) | GPU (shader), written once | moved 2026-11-03 |
| Decals (bullet marks, puddles) | GPU; CPU places once | right |
| Disasters (rain, snow, hail, sand, fire, meteors) | GPU particles and shaders | right |
| Snow lying on the ground | **main**: 1,024 physics rays from GDScript and a mesh a square, one square a tick | could move: 3.6 (2.4 ms a tick mean while it fills, slowest square 2.9 ms headless) |
| Snow on buildings | main, C++ `build_snow_cover`, at most every second a building | right |
| Tracers, muzzle flashes | not drawn (no barrel sets them) | if wanted, GPU: GpuOffload.md 2.6 |

### Terrain, planets, space

| System | Runs on | Verdict |
|---|---|---|
| Terrain tiles, coarse terrain, streaming | workers (group tasks) | right |
| Planet generation, impostor bakes (~1.2 s) | workers | right |
| Planet buildings' bands, nav regions | workers, finished on main (3-7 ms a region) | right |
| Planet trees (cells built a few a frame, budgeted) | main, budgeted | right |
| Star system placement (bodies, stations, ships) | main, a few nodes a frame | right |
| Space drift pieces (capped, closed form) | main, one transform a piece | right |
| Water, sky, clouds, weather looks | GPU shaders | right |
| Terrain noise, scatter placement, far stand-ins | workers | could go to the GPU only if streaming stalls: GpuOffload.md 2.3-2.5 |

### AI, characters, combat

| System | Runs on | Verdict |
|---|---|---|
| Navigation queries (`AIWorld`, HPA) | main, C++, sliced | right until a profile says otherwise (AI.md rule 9); worst nav service 1.9 ms |
| Squad / commander / tactic decisions | main | right; worst 1.3 ms |
| Swarm flow field | its own C++ thread | right |
| Swarm piles | main, rebuilt on events | right |
| Character movement (`move_and_slide`) | main (physics API) | right |
| Creature gait, IK, ragdolls | main, LOD'd (`creature_lod`) | right; skinning itself is on the GPU |
| Weapons, hits, damage numbers | main, per shot | right |

### Engine and the rest

| System | Runs on | Verdict |
|---|---|---|
| Physics solver (Jolt) | Jolt's own job threads | right; running physics on its own thread was measured worse (Status.md) |
| Rendering | main thread (thread model "safe") | the separate thread was measured 3x slower: 3.1 |
| Audio | Godot's audio thread | right |
| Autosave (planets) | main, every 30 s | right: 2.5-3.2 ms (`--gate=save`, 2026-11-04), the file writes ~1 ms of it; one run of 31 ms, the disk |
| UI, HUD, menus | main | right |

## 3. Large fixes, kept for later

None of these is started. Each says what it would gain, what it costs, and what to measure first.

### 3.1 The renderer off the main thread

**What:** Godot's `rendering/driver/threads/thread_model` = Separate, so the renderer's half of
every upload (buffer creation) and every renderer call stops landing on the main thread.

**Why it matters:** the one main-thread cost every system shares. Measured: a band's attach 4-7
ms, a spawn's node step 7-12, `MeshInstance3D.new()` 0.7-5 ms in fights, a stand-in show 35 ms
once, a shadow switch 33 ms once. Each is a main-thread renderer call waiting for an upload a
worker has in flight.

**Tried 2026-11-04 as a setting** (`--render-thread separate`, street walk): mean frame 19.2 ->
58.7 ms, 210 frames over 25 ms against 49, and texture updates from workers arriving empty
(PerfCaps.md 4). The code assumes the default model.

**What it would take:** every place that waits on a worker's upload
(`WorkerThreadPool.wait_for_task_completion` on a mesh job, `BrickNear`'s waits, the tick's
flush in `CityScene._physics_process`), every renderer read-back (`get_image`,
`mesh_surface_get_arrays`, `get_instance_shader_parameter`), and every worker texture update
(the `_texture_2d_update` errors) reworked so none blocks on the render thread; then the walk,
`--big --shot` and the gates again. Days, across city, islands, the near tier and planets.
**Measure first:** how much of a collapse's worst frames is renderer waits (the `render` mark
and the stalls above) against real work (`spawn`, `fracture`).

**Smaller ways at the same cost** if 3.1 is never done: fewer, larger uploads (a building's
bands merged), uploads only between ticks, and renderer calls batched to one point a tick
after the flush.

### 3.2 Collapse spikes: spawn and fracture

**What:** the worst frames of a big collapse are pieces genuinely coming apart -- `split_island`,
a body and its shapes, a mesh job, `promote_finish` (42 ms worst). They make nodes and physics
bodies, so they stay on the main thread.

**What it would take:** make them cheaper -- reuse bodies from a pool, build shapes for a piece
on a worker as data (`add_chunk_shapes` reads only the chunk) and hand them over, split by
storey lines (the storey-units work already does part). **Measure:** `--big --shot`'s `[prof]`
report, ticks over `SPIKE_MS`.

### 3.3 A single building's structure solve on a worker

**What:** `solve_structure` for one building runs in the tick, 3-6 ms for a 22,000-brick tower.
Several in a tick already run a thread each.

**What it would take:** start the solve on a worker against a snapshot of the chunk (the solver
already has per-thread scratch slots) and apply the answer next tick. A tick of delay before a
building starts to fall. Damage written to that chunk meanwhile must cancel or redo the solve
(`join_chunk_readers` does this for bakes). **Measure:** the solve's share of collapse ticks.

### 3.4 The shadow proxy damage profile off the main thread

**What:** `registry.live_damage_profile` reads the live bricks on the main thread when a big
building's proxy is rebuilt (2-7 ms, 2026-10-23; the walk since got to 0.12 ms mean).

**What it would take:** a copy of the cells it reads (as the panes' `get_solid_cells`) and the
profile built on the worker with the proxy mesh. City and buildings area. **Measure first:**
`--cost --street --long`'s `sh_profile`; if it is under a millisecond now, drop this.

### 3.5 The planet far tier's fade on the GPU

**What:** `PlanetBuildings.far_tier` loops over every site every frame for a fade and a size on
screen, and writes each site's MultiMesh data when it changes (most frames, when the camera
moves).

**What it would take:** the per-site constants (footprint, height, top's altitude) written once;
the fade worked out in the far tier's vertex shader from the camera (distance, horizon, size on
screen); the CPU keeping only the near/brick decisions, every few frames. The pop counter the
gates read would need a CPU copy of the rule. **Measure first:** time the loop on a town; if it
is a few tenths of a millisecond, it is not worth it.

### 3.6 Ground snow without a ray a cell

**What:** a square of ground snow casts 1,024 rays from GDScript to find what stands over each
cell, then builds its mesh on the main thread.

**What it would take:** rays only where something can be (the building index and the tree cells
first: most squares have nothing over most cells), the mesh made and uploaded on a worker as the
city's bands are. Or on the GPU: a top-down depth render of what stands over the ground, read as
the snow mask. **Measure:** `snow_probe`'s "physics tick while it lies" and slowest square,
windowed.

### 3.7 Elsewhere

GPU candidates (terrain noise in compute, shader-placed scatter, impostors, texture streaming
once Godot 4.8 is stable, tracers if wanted) are ranked in GpuOffload.md section 5.

## 4. Ranked by what they would gain

| # | Fix | Gain | Effort |
|---|---|---|---|
| 1 | 3.1 renderer off the main thread | the shared cause of most remaining spikes (renderer waits 4-35 ms) | days; tried as a setting, failed |
| 2 | 3.2 cheaper spawn / fracture | the worst collapse frames | large |
| 3 | 3.3 single solve on a worker | 3-6 ms a big building's solve | medium |
| 4 | 3.6 ground snow | 2.4 ms a tick while snow fills in | small-medium |
| 5 | 3.4 shadow proxy profile | 0.1-7 ms, measure first | medium |
| 6 | 3.5 planet far tier fade | tenths of a ms a frame, measure first | medium |
