# Handoff: performance -- where work runs, and what is left

Written 2026-11-04 at the end of a long chat (worktree `C:\Users\lbaun\bc-wood`, branch
`pbr-wood`, last merge `9ceb827`). The detail is in **Docs/WhereWorkRuns.md** (the audit: every
system, where it runs, the large fixes in section 3, ranked in section 4) and
**Docs/GpuOffload.md** (the GPU side). This page is where to start.

## 1. State

### Done (all merged into main and pushed)

| What | Result | Where |
|---|---|---|
| Crumbs, particles, ice shards on the GPU | written once, moved by their shaders | GpuOffload.md 2.1, 2.2, 2.7 |
| Planet pieces bake on a C++ worker | shed 11-13 ms -> 4-8 | Planets.md, `PlanetPieces._start_mesh` |
| Stand-in and bevel arrays made on their workers | `take_coarse_mesh` / `take_chamfer_section` 2-5 ms -> 0 | WhereWorkRuns.md 1 |
| City structure solve on a worker | main-thread solve 87 ms -> 0.2 ms over a collapse run | WhereWorkRuns.md 3.3; `BrickWorld.solve_structure_async`, `CityScene._start_solves` |
| Rule for new code: no renderer read-backs, no waits on unfinished workers during play | stops 3.1's list growing | CLAUDE.md "Where new code runs" |
| Instance parameters kept CPU side | `InstanceParams.put` / `of` | WhereWorkRuns.md 3.1 a |
| Unwanted worker meshes left to finish | `TaskReaper.drop` | WhereWorkRuns.md 3.1 b |
| No tick flush with the renderer on its own thread | `CityScene._one_thread` | WhereWorkRuns.md 3.1 c |

**Separate render thread:** works now (street walk 16.7 ms mean either way; collapses lean
better), all gates pass with it. **Not the default -- the user's decision (2026-11-04): keep the
default thread model.** Godot calls it experimental, and the PC has unexplained power-offs.
Godot cannot put only some systems on the render thread; it is all or nothing.

### Things to know

- The async solve must start AFTER `_ai_tick` -- the AI reads the buildings, and started before
  it, 383 of 416 solves were waited for on the main thread.
- A stale async solve (the building written meanwhile) logs its SOLVE at the tick that takes it,
  after the write; 4 in 855. If net replays ever disagree there, look here (WhereWorkRuns 3.3).
- `city.tscn -- --chamfer` check "and they draw exactly the bricks left" failed 1 run in 5
  (52 triangles off -- a patch not landed in time); passed 4 of 5 with the change, 2 of 2
  without. Looks like a flaky timing check; if it fails again, run it on main.
- `get_meta(key, null)` errors for an unset key (a null default counts as none): `has_meta` first.

## 2. What the user saw (play test 2026-11-04, default thread model)

1. **Big city lags hard in collapses** -- easy huge spikes, stretches near 30 fps -- while the
   small city (`city.tscn`) holds a locked 60 through the same destruction. Something scales
   with building size. **Biggest open item; performance area (this chat's).**
2. **A piece loses its detail and windows the moment it breaks off**, until it settles. It
   should keep them if the player is near. By design today: `BrickNear` draws anything moving
   flat (`STILL`, back after `SETTLE_MS` at rest), and windows are drawn per building
   (`_brick_panes`), so a piece has none until it settles. Fix: hand the building's chamfered
   mesh and its share of the panes to the piece as it leaves, rather than rebuilding it plain.
   **Destruction area** (`island_manager.gd`, `brick_near.gd`, `city_scene.gd` hand-over).
3. **A building or piece vanishes for a flash**, usually going from no detail / no windows to
   detail with windows. Known: Docs/Collapse.md "a piece flickers as it separates"; the
   `--big --shot` report counts it ("invisible pieces: 122 went blind, worst 21 tick(s)" before
   any of this chat's changes). Fix: keep the old mesh drawn until the new one is up.
   **Destruction area.**
4. **Flying down to a planet** dropped under 30 fps, settling near 50. Probably terrain / planet
   streaming as it comes in; not looked at. Profile it before guessing.

## 3. What is left, ranked

| # | What | Gain | Effort | Area / first step |
|---|---|---|---|---|
| 1 | **Collapse spikes** (WhereWorkRuns 3.2): `split_island`, a piece's collision reshape, landings | the 80-420 ms spikes and the big-city lag (section 2 item 1) | large | performance. First: a profiled big-city collapse (`[prof]` report) to see which dominates there. Tonight's city runs: split 84 ms (9,400 bricks), reshape 419 ms (7,000 bricks, all `space`), a landing 417 ms (`what it hit` 295) |
| 2 | **Ground snow** (3.6): fewer rays, mesh on a worker | 2.4 ms a tick while snow fills | small-medium | terrain |
| 3 | **Shadow proxy damage profile** (3.4) on a worker | 0.1-7 ms when a big building's proxy is rebuilt | medium | city/buildings; measure first |
| 4 | **Planet structure solve on a worker** | 3-6 ms a big planet building | small | `PlanetBuildings._solve_site`: the city's two calls (`solve_structure_async`, `take_solve`). Only if planet collapses spike |
| 5 | **Planet far-tier fade on the GPU** (3.5) | tenths of a ms a frame | medium | probably not worth it; measure first |

Render thread leftovers (only matter if it is ever switched on): the four waits that need their
result (`CityScene._take_bands`, `PlanetSystem._full_bake`, `PlanetSystem.jump`,
`SpaceStation.deactivate`, each with its reason in 3.1 b) and 2-6 `_texture_2d_update`
"p_image is empty" errors at start (a render-thread race, source not found; not the dust or
torch gradients).

GPU ideas, all "only if needed" (GpuOffload.md): terrain / planet noise in a compute shader with
scatter placed by the shader (2.3, 2.4 -- big; only if streaming shows up, maybe section 2 item 4
above); far buildings as GPU impostors (2.5 -- only if the far tier's build time shows up);
tracers as one shader-driven MultiMesh (2.6 -- only if tracers are wanted; shots draw none).

Not worth moving (checked in the audit): autosave (2.5-3.2 ms), AI and combat (in budget),
physics (Jolt threads itself), nodes and bodies (the scene tree and physics space need the
main thread).

## 4. Suggested next chats

1. **Big city collapse lag** (performance): section 3 item 1. Start with
   `big_city.tscn` collapse profiling.
2. **Pieces keep detail and windows, no flash** (destruction): section 2 items 2 and 3.

## 5. How runs were done

- Timing: editor closed, no other chat's Godot running (check processes), one windowed run at
  a time, `python tools/heat_sum.py <start>` after each (held back = 99 C+; then wait under 80).
- Street walk: `big_city.tscn -- --chamfer --cost --street --long`. Collapse:
  `city.tscn -- --big --shot`. Add `--render-thread separate` to try the other thread model.
- Collapse runs never break the same amount twice: alternate A/B pairs, three or more, and
  compare ticks over 25 ms and the worst ticks, not just the mean.
- Gates for this work: `solve_probe`, `collapse_probe`, `replay_probe`, `storey_probe`,
  `storey_unit_probe`, `hang_probe` (headless); `city.tscn -- --chamfer`, `-- --light`,
  `brick_bevel_probe` (windowed); planet `--gate=topple|bricks|fall|light`.
- After a C++ merge, rebuild main's DLL (`python -m SCons` in main's `gdextension/brick`, editor
  closed) and `--import` in main.

## 6. Section 4 item 1, first measurements (2026-11-04, later chat, worktree `C:\Users\lbaun\bc-perf`)

- **Godot's TIME_PHYSICS_PROCESS / TIME_PROCESS monitors are the worst frame of the last
  second**, set once a second -- not "this frame". The census's "physics N ms this frame" and the
  live profiler's "solver ~" (physics minus script) are not what they say. New
  `scripts/frame_clock.gd` (FrameClock) splits each frame by the wall clock (city tick, other
  scripts, physics step, idle, draw, sync/wait) plus the GPU's own time; a pass prints it as
  `[prof] frames by the clock` / `[prof] slow frames`. Screenshots and censuses are left out.
- `big_city.tscn -- --shot` (1280x720 test window, one headless probe of another chat running):
  frame 19.9 ms mean = city tick 5.1, Jolt step 1.3, idle 1.7, draw 10.9; **GPU 15.4 ms mean**.
  108 slow frames (43 ms mean): **GPU 24.4 mean** (33-62 in the worst), city tick 18.3; biggest
  part draw 56 times, city tick 46. Jolt is NOT the problem (3.8 ms on slow frames).
- `city.tscn -- --shot` for comparison: 17.0 ms mean, GPU 10.9, city tick 1.6; 7 slow frames.
- So the big-city lag is two things: (a) GPU-bound collapse frames -- ~60 moving pieces, 200k
  bricks loose; next: what the GPU draws then (shadow casters of moving pieces, overdraw, piece
  meshes un-culled) -- try `--render-thread` off, shadows off A/B, count draw calls; (b) city tick
  spikes 40-70 ms (`dmg_rooms` 59, `bd_pieces` 55, shell-piece spawn split 23 ms for 24k bricks,
  main-thread mesh bake 31 ms) -- see the `[prof] N tick(s) over 25 ms` list.

### 6.1 Piece shadows from stand-ins (2026-11-05)

- FrameClock now also counts what the renderer drew: main pass and shadow passes apart
  (`draws_k`, `tris_M`, `sh_draws_k`, `sh_tris_M`). Draw calls are few (~200); triangles are the
  cost. Big-city collapse: **shadow passes 13-18 M triangles a frame, the main pass 4-5 M**.
- Loose pieces cast with their full bricks (and their bands) at any distance, into all four sun
  cascades; buildings already had shadow shells. A/B with pieces casting nothing: shadow
  triangles 13.1 M -> 0.9 M, GPU 44 -> 17 ms. So pieces were ~93% of the shadow work.
- Fix (merged): a big piece (radius > `SMALL_ISLAND_RADIUS`) further than `BRICK_SHADOW_RANGE`
  (15 m) casts its coarse stand-in, shadows only (`IslandManager.want_shadow_proxy`, built on a
  worker with `coarse_chunk_async`, uploaded on another, rebuilt at most every
  `COARSE_REBUILD_TICKS` when it lost bricks). Its bricks and bands cast until the first is hung.
  Close up nothing changed. Result: shadow triangles 13.1 M -> 3.6 M a frame; invisible pieces
  no worse (worst 17 ticks).
- **The times in these runs are not trustworthy**: they were taken past midnight with the
  display asleep (frames ~93 ms, draw stalls -- see the display-sleep note) and one other chat's
  headless gate going. Triangle counts are. **Next: re-measure GPU ms awake, editor closed**
  (`big_city.tscn -- --shot`, read `[prof] frames by the clock`), then the city-tick spikes.
- Gates: solve, collapse, replay, storey, storey_unit, hang probes pass; `--light` passes;
  `--chamfer` failed "the picture is the same either way" once (1.01% vs 1%), then passed 2 of 2.
- **Measured awake (2026-11-05 10:27-10:29, editor closed, nothing else running),
  `big_city.tscn -- --shot`, two A/B pairs** (B = pieces casting their bricks, as before):

  | | frame mean | frames over 33 ms | GPU mean | GPU in slow frames | shadow tris (slow frames) |
  |---|---|---|---|---|---|
  | A1 / A2 (stand-in shadows) | 18.6 / 17.4 ms | 32 / 23 of 906 | 13.6 / 12.4 ms | 18.6 / 14.4 | 1.2 / 0.9 M |
  | B1 / B2 (bricks) | 21.2 / 21.1 ms | 71 / 87 of 906 | 15.8 / 16.1 ms | 29.0 / 32.7 | 8.6 / 10.3 M |

  Slow frames cut to about a third; the slow ones' GPU time halved. What is left in them is the
  city tick (17-19 ms on a slow frame) about as often as draw: section 3 item 1's spikes are next.

### 6.2 What still lands on the main thread from mesh building (2026-11-05)

Every mesh is already BUILT on a worker (bakes, arrays, packing). With the renderer on the main
thread (the default, kept), Godot still makes each mesh's GPU buffers on the main thread at the
next call into the renderer -- CityScene's "render" phase. `UploadLedger` (scripts/upload_ledger.gd)
now counts what each worker handed over, and `[prof] render flush` names what a slow flush carried.
One big-city collapse (editor open, so times are rough): the slow flushes were each ONE piece mesh
-- 748k vertices 33 ms, 494k 23 ms, 866k 13 ms, 577k 10 ms. Over the pass, pieces uploaded 14.5 M
vertices in 45 meshes (bands 1.3 M in 160, piece shadows 1.1 M in 103). The island budget
(UPLOAD_VERTS_PER_TICK, 150k) cannot help: the first mesh of a tick always goes, and a mesh
cannot be split. Options: (a) cut a big piece's mesh into slices (as a building's bands) uploaded
a few a tick, the old mesh drawing until all are up; (b) fewer vertices in it (dead faces left
out, as compaction does after settling); (c) the separate render thread (declined for now).

**(b) done (2026-11-06, `IslandManager.PIECES_SKIP_DEAD`).** A new piece is baked from its live
bricks from the start; one adopted whole (a toppled building, one back from sleep) switches at its
next full rebuild, so a bake its band holes wait on is not dropped. Big building pieces halved:
11,700 live bricks 748k -> 373k vertices. One quiet run after (big_city --shot, machine 95 C, not
held back): 66 slow frames (93-256 before), worst flush 24 ms (one 375k piece), worst invisible
stretch 15 ticks. What is left in the flushes is single pieces of 200-400k vertices -- (a) is the
remaining lever. Pieces come out as one section (`get_chunk_sections` 1), so slicing needs a new
split in the mesher, not the band scheme as it is.

Also seen: spiral stair pieces are 1,444 drawn triangles a step (722 authored, each stored as a
quad), so a 200-brick stair piece is 577k vertices (build mode's `spiralcw_10x10`; not changed here). And
twice a small piece's mesh built on the main thread at spawn took 44 / 116 ms (146-185 bricks,
mesh under 30k vertices, so not the stairs); it did not happen in the run after, so the cause is
not known yet -- time `rebuild_mesh(isl, true, true)` in `spawn` when it comes back.

**(a) done (2026-11-07, `IslandManager.SLICE_VERTS`).** A piece whose mesh
would be 120k vertices or more (32 a brick, 4 an authored triangle) is cut into sections before
its first bake -- bands of about 30k (`SLICE_BAND_VERTS`, at most 24). Its full rebuild builds
them a band at a time within `UPLOAD_VERTS_PER_TICK` (`_advance_slices`), hidden, while what it
drew goes on drawing, and swaps them in whole (`_swap_slices`); hits patch per band
(`_patch_bands`). Settled banded pieces now go to stand-ins when far (bands draw until the
stand-in is up), so do a toppled building's once it has settled and has no band holes. Report
line: `[city] big pieces in bands`. To check on the first run: render flushes per piece, the
invisible stretch (a big piece's first mesh now waits for all its bands), draw calls.

*Measured and reworked (2026-11-07, merged).* First run (`city.tscn -- --big --shot`): one piece,
5 bands, swapped cleanly -- but a band was up to 9.9 ms ON THE MAIN THREAD (cut out of the bake
and its mesh made there) and the upload budget alone let several into one tick: a 24 ms islands
tick, the flush's cost moved, not removed. Now: the band is cut on the main thread (it writes
its range of the patch baseline, so it stays there), its `ArrayMesh` is made on a worker
(`_submit_slice_job`, started with the other mesh jobs at the tick's end, hung hidden by
`_harvest_slice_jobs`), and a tick stops cutting after `SLICE_TICK_MS` (3). A dropped bake bumps
`slice_gen`, so meshes still on a worker are thrown away, never waited for; `_exit_tree` waits
for the started ones. `tools/piece_band_probe.gd` (headless, 11 checks) makes a 6,109-brick piece
every time: 7 sections, swapped in 11 ticks, no band shown early, meshes made on workers, worst
tick 3.5 ms (cut 1.4, worker mesh 2.5), a hit patched in place, a mid-way drop begun again with
nothing left hanging. **Big pieces are rare now**: since the strength tree went in (e0545c84,
7f32c143) buildings seldom come down whole -- 1 of 5 collapse runs made a piece big enough, and
`big_city --shot` none -- so this matters less than it did on 11-06. Not yet seen windowed with
the worker meshes (no run made a big piece since); the probe is the check.

Every windowed run today crashed ON QUIT (signal 11, after `BUG, indexing did not unpair
geometries from light` from renderer_scene_cull.cpp) -- after the report, with or without the
lighting follow-up 61221639; it looks like the near lamps (b03e165c), not checked on main alone.

**Band patches at the band's own index width (brick_world.cpp `update_index_regions`).** A patch
was written at one width for the whole chunk -- the width of the LAST band built (CityScene
`_brick_index_width`) -- so a building with one band over 65,536 vertices and others under got
garbage patched into the bands at the other width. Each section's width now follows from its
own faces x 4 vertices, as the chamfered bands' patches already did. The width argument is kept
and ignored.

Also seen in the last run's ticks: the 118 ms "shed: spawns" tick was the 116 ms main-thread
spawn mesh above (one event, not two). A shell piece's bricks "laid" 100 ms once for 11,863
bricks, against 8-21 ms for 7,000-24,000 in the same run -- not the size; next time, time the
`cut_record` kills apart from `_lay_runs` (BuildingRegistry.shell_piece_chunk).

### 6.3 Small meshes uploaded in the tick, and renderer stalls (2026-11-08, worktree `C:\Users\lbaun\bc-stree`)

Found from the destruction side (Docs/DestructionFirstPrinciples.md B9-B12). Windowed `--stress
--buildings=200`, editor closed, nothing else running.

- **Uploads under `THREAD_MESH_VERTS` were done in the tick.** The mesh queue's main-thread part
  (`IslandManager.drain_ms`, new) was 410-478 ms a run; every item over 8 ms (`drain_slow`, new;
  `--stress` prints them with `rebuild_split`: assembly / upload / apply) was a 28,880-vertex
  staircase piece -- just under 30,000 -- whose `add_surface_from_arrays` took 8-37 ms (assembly
  0.1 ms). The constant's note prices an upload at ~50 ns a vertex; windowed under a collapse it
  was 300-1,300 ns. **Now `thread_mesh_verts` = 4,000** (A/B: `-- --stress --thread-verts=N`),
  and a piece with nothing drawn is stood in while its upload runs (`IslandStandins`, a box per
  brick from `BrickWorld.get_standin_buffers`). Main-thread mesh work ~314 ms against ~520-593,
  the worst single item ~15 ms against 37-55.
- **Some of it moved, not went:** spawns' own mesh time rose (103-115 -> 245 ms), consistent with
  6.2 -- the buffers of worker-uploaded meshes are made at the next main-thread call into the
  renderer, and a spawn is often that call.
- **What is left is the renderer stalling, not size:** the two slow queue items left were 344 and
  424 vertices, 9-12 ms each. A threshold cannot fix that; 6.2 option (c), the separate render
  thread (or 3.1's renderer-off-main list), is the lever if these show in play.
- Small pieces baked on the worker instead of in the tick: worse while uploads were in the tick
  (DestructionFirstPrinciples B11), **better once they went to a worker from 4,000 -- on since
  2026-11-08** (B13): main-thread mesh work ~207 ms against ~314, the worst item 5.8 ms against
  15.5 (`-- --stress --sync-small` for the old way).
