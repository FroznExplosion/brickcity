# Handoff: the AI's nav regions on a planet (Planets.md 11.8)

For a new chat. Read this, then Docs/Planets.md §10b test 8, §11.7 and §11.8, then the repo's
CLAUDE.md (worktrees, heat log, test windows, timing rules).

## Where things are (2026-10-24)

- Everything that moves -- pawn, titan, tank, truck, APC, flyer, the soldier's BODY -- is on local
  down (§11.7): up is `Gravity.up_at(p)` through the helpers in `scripts/gravity.gd`, exact in the
  flat game. Planet gates in `scenes/planet.tscn`: `-- --gate=pawn` 12, `--gate=mech` 11,
  `--gate=tank` 12, `--gate=soldier` 9, all passing headless.
- The soldier's BRAIN is not: `AIWorld` / `AINav` (C++, `gdextension/brick/src/ai/`) and the squad
  and tactics GDScript assume world +Y up and read ground from the flat terrain
  (`AIWorld::_ground_plate` -> `BrickTerrain::surface_plate`).
- **Built for you (N1b's GDScript half):** `scripts/planet/planet_nav_region.gd` --
  `PlanetNavRegion.make(data, dir, studs := 1024, step := 4)`: a tangent frame (planet-local;
  world is `planet.global_transform * frame`, axes = `Gravity.tangent_basis`'s) and the ground as
  257 x 257 heights in that frame, the frame's origin 1 m under the lowest ground, `sea_y`,
  `ground_at(lx, lz)` (bilinear, INF outside). Probe: `tools/planet_nav_grid_probe.gd` (headless,
  9/9: 222 ms to build, samples on the ground within 2.4 mm, 1.3 cm between samples, corner tilt
  1.45 deg).

## State (2026-10-24, planet-nav chat)

Steps 1-5 are done and merged (Planets.md 11.8, "N1 and N1b's C++ half built", "N2 built",
"N3 done"): `AIWorld.set_frame` / `set_ground_grid` / `ground_under` / `top_over`, probe
`tools/planet_nav_frame_probe.gd` 18/18; `PlanetScene.setup_ai` and `--gate=squad` 10/10; the
squad and tactics GDScript on the Gravity helpers. Step 6 (N4) too: `PlanetNavNet`, probe
`tools/planet_nav_net_probe.gd` 12/12, `--gate=travel` 10/10 (11.8 "N4 built"); each agent
asks its own region (`AIServices.focus`, `--gate=far` 11/11). Lines and danger across
regions too (`AIWorld.set_peers`, `LINE_REACH`, `AIServices.set_danger`). Open: size/vehicle
maps per region; buildings'
own bricks in the AI's world on a planet (proxies stand in for now); VehicleNav / VehicleCover;
`AINav.field_dir` is zero everywhere on main (see 11.8) -- a fix moves the flat game.

## What to do, in order (each step merged to main when it works)

1. **N1, the region frame (C++).** `AIWorld.set_frame(Transform3D region_to_world)`; AINav reads
   it from its AIWorld. Every BOUND method of AIWorld and AINav converts at the boundary: position
   arguments in through the inverse, positions / paths / cover points out through the frame,
   directions (`field_dir`) through its basis, the boxes of `invalidate_box` transformed to an
   AABB in the frame. Methods taking `(x, z)` (`top_at`, `ground_at`) stay region-local -- check
   their GDScript callers (`flyer.gd` already skips them on a planet). Do it with thin wrapper
   functions bound in place of the originals, so AINav's own C++ calls into AIWorld are never
   converted twice. **With the frame IDENTITY every wrapper must take the old path untouched**
   (an `if (framed)` branch, no transform math), so the flat game is bit-identical. `shift_origin`
   / `ground_dx` stay for the flat game; on a planet PlanetFrame's translation re-centre just
   moves the frame's origin.
2. **N1b, ground from the grid (C++).** `AIWorld.set_ground_grid(origin: Vector2, step: float,
   size: int, heights: PackedFloat32Array)`: when set, `_ground_plate` reads the grid (bilinear at
   the stud's centre, as `PlanetNavRegion.ground_at`), outside the grid a very high plate (a
   wall); `set_terrain_ground(true)` with it. Clear `ground_cache` on set. Water level from
   `region.sea_y` via `AINav.set_water_level`.
3. Rebuild (`python -m SCons` in `gdextension/brick`), `--import`, then the flat AI probes
   (below) must all pass unchanged. Then a headless probe: a region over the planet, a framed
   AIWorld+AINav on its grid, `find_path` between two world points on the ground: the path's
   points within a plate of `PlanetData.height`, and the same path as the unframed nav over the
   same grid, transformed.
4. **N2, one region round the fight:** in `scripts/planet/planet_scene.gd`, an `AIServices` set up
   the way `tools/ai_arena.gd` (and `city_scene.gd:1155`) does, its AIWorld framed on a
   `PlanetNavRegion` round the player's town (`town_dirs[0]`). Gate `--gate=squad`: a squad set
   down on the region walks to the player round the curve, takes cover, fires; bodies tracked with
   `PlanetBody.track` (else they fall through the planet away from the player).
5. **N3, the squad/tactics GDScript onto the Gravity helpers**, file by file as §11.7 did, the flat
   path exact or kept literal behind `if Gravity.planet == null`: wave_director (39 sites),
   firefight_director 18, building_layout 18, spawn_survey 13, air_strike 11, tactics_sense 8,
   room_tactics 6, then the rest (`grep -nE "\.y\b|Vector3\.(UP|DOWN)" scripts/ai`). Run each
   file's probes before the next.
6. **N4, many regions** (HPA* clusters of 8 x 8 tiles in their own frames, portals per border,
   §11.8) -- after the gate in 4 works with one region.

## Probes that must stay green (headless, from the worktree)

soldier, frozen_soldier, ally, commander, squad_advance, squad_travel, ai_moves, nav, nav_hier,
mech_rodeo, tank, apc, vehicle_bricks, vehicle_seats, vehicle_nav, moves, melee, pawn; planet:
planet_nav_grid, planet_nav, and the four planet gates. `soldier_probe`'s "inside the AI budget"
can spike once (3.2 ms vs 2.5) -- rerun before believing it. The windowed city `--walk` gate's
"gets past it rather than stopping dead" fails on main too (3 of 3, 2026-10-23): not yours.

## Rules that bite

- Own worktree and branch; `git merge main` before starting. Kill Godot by PID only.
- Windowed runs: one at a time, start under 80 C, report peak and held-back after each
  (`python tools/heat_sum.py --last <min>`). Headless where you can.
- After a C++ merge, main's DLL is not live until SCons runs in the main folder with the editor
  closed; never close the user's editor.
- Stay out of the destruction internals (storey units, another chat's).
- Write Python patch files with Write, not heredocs (the Bash tool halves backslashes).
