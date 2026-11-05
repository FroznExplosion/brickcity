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
