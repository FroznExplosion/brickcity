# Handoff: slopes ground, planet prep, building room graph (2026-10-20)

For the next chat picking up this line of work. Everything below is merged into `main` and
pushed (last commit `2f10145`). Read the doc sections cited for the detail; this is the map.

## State of `main`

**Main's DLL is NOT current.** The last C++ merge (`9302c79`, broad flats / mask fix) could not be
built in the main folder because the user's Godot editor was open and locks
`addons/brick/bin/libbrick.windows.template_debug.x86_64.dll`. With the editor closed:
`python -m SCons` in `gdextension/brick` (main folder). Never close the editor yourself.

## What was built this session

### Terrain -- "slopes" ground (Terrain.md 18.6, 18.7, 18.8)
A third way to lay a world, opt-in: `"ground": "slopes"` in the world file, F10 > Ground, or C
(cycles brick → hills → slopes) in `heightfield_test`. Default world ground is still `brick`.

* ~90% smooth low-poly curve, laid brick (flush, with studs) only on broad flats.
* `smooth_column` slopes branch (`brick_terrain.cpp`): painted form wins (BRICK brush, editor
  tool 9, `paint_form`, saved per tile as `"form"`), pads are brick, else curve where
  `broad_slope` (steepest of 3x3 8-stud blocks, blended) > `g_curve_slope` (0.15) and regional
  slope < `CLIFF_SLOPE` (3.0).
* **Shelves** (`set_shelves(4, 0.3)`) in `Field::base_plate`, slopes ground only: every 4 bricks of
  height the first 30% of the rise is flat → the flat places that become brick (~10%).
* **Low-poly** (`set_curve_step(4)`): 4-stud grid edges with curve both sides are straightened,
  all-curve blocks drawn as one quad; tile-edge safe.
* **The big fix:** `mask_faces` no longer draws tops/sides of curved columns (the voxel staircase
  stood through every curve since 18.5). Detail ground 408k → 44k tris; frame ~25% cheaper than
  laid brick.
* Curves plain (`plain_curves` in `terrain.gdshader`), unstudded, slow colour drift; studs on
  curves scattered (level spots, 1 in 8). Poking bricks (`set_curve_bricks`) exist but default 0.
* **Placement** (`city_placer.ground_top`): a build on the ground stands at the HIGHEST ground under
  its footprint, the pad fills brick up to it (Terrain.md 21.8).
* Test: `tools/terrain_probe.gd` (slopes section). Shots: `heightfield_test -- --slopeshot
  --curve=0.15 [--curvestep=N] [--nobevel] [--lodview]` writes `shots/hf_ground_*`.

**Next for terrain:**
1. Lighting seams where a 4-stud block meets 1x1 curve cells (normals per corner from moved
   corners; weight them consistently).
2. The far tier (369k tris) is now the biggest ground cost -- it could go smooth/coarser on slopes
   ground since near and far now share the outline.
3. Decide whether a real world (the city's) goes `slopes`; check sites/pads and the sea there
   (shelves change the field, so pads and sea level move with the mode).

### Planet prep (Planets.md; §9 is the "change now" list)
* 9.1 built: `scripts/gravity.gd` -- every per-frame fall and every project-gravity read.
* 9.2 built: `BuildingRegistry.to_building/to_world/own_box/contains/ray_hit`, `on_grid` snaps in
  `grid_frame_at(p)`.
* 9.5 dropped (measured: reading a tile from disk 14 ms vs building it 2.9 ms).
* 9.6 built: `scripts/world_frame.gd` -- saves and damage-log wire form in the body's frame;
  `tools/world_frame_probe.gd`.
* 9.3 / 9.4: see below / done via slopes ground.

### AI -- buildings by their rooms (AI.md 3.6.1)
* Step 2 built: `scripts/ai/building_layout.gd` (`BuildingLayout.for_tower` from the recipe,
  `for_record` from a structure record; `space_at`, `route`, `reachable`). Uses
  `TowerRecipe.wall_doorway` / `doorways` (the same function the bricks use).
  `tools/building_layout_probe.gd` checks it against built bricks. Nothing calls it yet.
* **Next: step 1 = the VAULT** (written up in 3.6.1): an `AINav` vault link (sill 6 plates over the
  floor, gap to 15, ≥2 studs wide, across a 2-stud wall), the mantle half of `PawnMoves` for AI
  pawns (soldiers have `moves == null` today), then window entries in `bt_play_clear_room`,
  vault-outs, glass, callouts. Then steps 3 (broken rooms on the grid) and 4 (plays read the
  graph), both designed in 3.6.1.

## Findings handed to other areas (not fixed)
* **Building:** sealed rooms (one doorway per interior wall LINE per storey: corner room of a
  40x40 tower has no way in); doorways placed across a wall junction (40x30 storeys 1-2, 2 studs
  clear); towers have no street doors. In AI.md 3.6.1.
* **Disasters:** `disaster_probe` fails "the ring is gone from the AI's world once it lands" and
  "once out, neither is left" on code from before this session too (pre-existing).

## Older open items
* Time the threaded window-glass fix (needs the editor closed).
* Measure AI / pathfinding / vehicle cost in a real fight; batch squad brains if it shows.
* `buffer_update` errors, unexplained.

## Working notes (things that bit this session)
* Worktree per task; C++ needs the godot-cpp junction (remove it FIRST before
  `git worktree remove`); script-only work can copy main's DLL. A new worktree's first SCons
  rebuilds godot-cpp objs through the junction and can hit "Permission denied" (antivirus) --
  rerun with `-j4`.
* Bash heredocs halve backslashes: write Python patch files with the Write tool.
* Windowed runs: check `python tools/heat_sum.py --last 3` and other chats' windowed Godot runs
  first; wait under 80 °C (a background until-loop on the heat CSV works).
* A shot that "doesn't change" with settings: compare images numerically and inspect the mesh
  (`build_tile(...)["mesh"]`) before trusting the HUD -- that is how the staircase was found.
