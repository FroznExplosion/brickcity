# Handoff: terrain regions (kept ground, per-region brick fit, instant breaks)

From a cloud chat with no Godot (2026-11-24), to a chat with the project and
Godot. Area: **Terrain and water** (CLAUDE.md Areas table).

## Where the work is

- Branch **`claude/terrain-brick-system-zoyz08`** on GitHub
  (FroznExplosion/brickcity), 3 commits on top of main `157b0b0`, **docs
  only, no code**. Not merged into main.
- **Read first: `Docs/TerrainRegions.md`**: the plan (sections 1-8), the
  chunk-crossing measurements (3.6), the water audit (7), the idea kept for
  later (9), the GDScript-or-C++ audit (10).
- To start: make your own worktree (CLAUDE.md), `git fetch origin
  claude/terrain-brick-system-zoyz08` and merge it in (or merge it into main:
  docs only, it cannot break anything).

## What the user wants

1. **Breaks that show at once.** Today a broken brick's hole takes ~38-57 ms
   to be drawn (more under fire; MineWorld.md 21).
2. **Less memory and frame time** spent on terrain.
3. **Brick shapes that read as laid LEGO**: random sizes (2x4, 2x3, 2x2, 1x4,
   1x2, 1x1 ...) and both orientations, following caves, cliffs and terrain,
   in place of today's regular `brick::bond_rect` lattice
   (Docs/TerrainBond.md). Teardown is the model for destruction.
4. Rules they gave: the world is a grid of 1x1-brick cells (the field stays
   in plates in Y, so tiles fit); cells grouped into a brick are bonded for
   good and never stress-checked against each other; stress only between
   bricks, at tops and bottoms (side studs, as in workshop.tscn, are a later
   special case); tiles only on the surface and in caves, never in the bulk;
   a brick sitting one plate up on a tile is a placed block, or refused.

## The plan (TerrainRegions.md 8), in order

1. **A0: measure memory first.** Nobody has measured the mine world's terrain
   memory. A headless `tools/probes/terrain_mem_probe.gd`: tile meshes,
   collision, stud MultiMeshes, overlay buffer, deep sections, coarse rings,
   `PackStore` (up to 768 packs x 10-30 KB), edit table, water sections,
   Godot static and video memory, after a walk on the default preset.
   **Report the table to the user before building anything**: if the big
   costs are elsewhere (meshes, trees, far tier), those come first.
2. **A: keep the near tiles' ground in memory** (MineWorld.md 21 item 1; it
   waited on the brick overlay, which is in). Per kept tile, the plate
   cells now and as generated, as per-column runs (~60 KB a tile, ~15 MB for
   ~240 tiles: an ESTIMATE). Edits write it and the edit table. `sample_tile`
   copies from it instead of the noise (~4.5 ms -> well under 1 ms);
   `find_brick`, the collapse survey, sky light and the water read it.
   Checks: `terrain_audit_probe`, `terrain_probe` (2 checks fail on main
   already), `mine_world_probe`, `terrain_cost_probe`, `--gate=handover`.
3. **C1: find the broken brick on the main thread** from the store, in the
   shot's frame. `-- --gate=breaklag --burst` (today 57/84 ms mean/worst at
   a shot a frame, 50/62 at one every 6).
4. **W1: water reads the ground from the store** (`sample_column` in
   brick_fluid.cpp recomputes noise and edits per column: the real-sea square
   ~12 ms a tile, springs ~10 ms). Water gate, `fluid_probe`.
5. **B1-B3: bricks fitted per region**: 16x16-stud regions per course,
   shifted 8 studs on odd courses so region edges never stack; a fit inside
   seeded from the region's coordinates, reading only GENERATED cells (a
   pure function: any tile, thread or load order gives the same bricks;
   nothing saved). Edits never refit; a broken brick goes whole; placed
   blocks keep their shape (`mark_placed`); sand/gravel stay 1x1. A new
   headless `region_fit_probe` compares three fits (largest first; all
   sizes at once; largest first along walls) on size mix, orientation
   balance, seams over seams, the collapse probe's arms, ms. **The user picks
   the fit** from its table and pictures.
6. **C2-C3: the hole in the shot's frame**: the overlay already hides the
   shot brick (`TerrainBricks.hide_at`, `overlay_holes`); add the newly
   exposed neighbours as overlay boxes at once; rebake only a quarter tile
   (16x16) from the store. Target: hole drawn the frame it is shot or the
   next.
7. **D: stress on the fitted bricks**: `TerrainCollapse.survey` takes bricks
   from the region cache instead of `bond_rect`; solver unchanged.
8. **B4** retire `bond_rect`/`set_bond_top` (prune their checks, say why);
   **W2-W4** water (below).

## Measured (a standalone C++ bench of the real generator, Linux, one thread)

Read the ratios, not the ms. Bench not in the repo; the probe replaces it.

- Generating a tile from the noise: 4.8-5.8 ms (agrees with `sample_tile`'s
  ~4.5 ms in MineWorld.md 21).
- **Bricks crossing chunks are fine and needed.** At most 4 chunks, never 8:
  every vertical boundary is on a course (deep sections 96 plates,
  `SECTION_BELOW` 54, the surface floor in courses). With offset regions
  3.3-3.5 % of bricks cross a tile edge, 0.04 % are in 4 tiles: ~3-4 % more
  tile rebuilds over all breaks. Fit ~1.3 ms a tile (surface band) with or
  without crossing. The 8-stud margin costs 10.7-13.1 ms a tile from the
  noise but nothing with the store. Forbidding crossing makes every tile
  edge a seam in every course: crossing cut seams-over-seams on tile edges
  40-44 %.
- **The open problem is the stagger.** A random fit had 257-326 seams over
  seams per 1,000 joints (the bond today: 0). A simple "refuse a brick with
  too much edge over seams below" cascaded into 96 % 1x1s. B1 must design it
  (a parity rule like the bond's, or scoring against the course below).

## Water audit (TerrainRegions.md 7)

**The water now has its own plan: Docs/MineWaterNext.md** (finite water
inland and in caves, the sea infinite; levelling by bodies; the user's visual
bugs first; research on Flowcraft and other water mods). Three decisions are
the user's before its stage F (rivers, springs, the source bucket).

Already the right shape (kept sparse sections, active set, own thread and
mesher, calm costs nothing). Gains: W1 above; **W2** re-measure the tick in a
release build with the editor closed (the only reading is ~2.3 us a cell,
debug, editor open: 20k cells ~18 ms against a 50 ns estimate) and profile
only if it holds; **W3** written/wet sections never leave memory, so keep far
calm ones in their save form; **W4** (optional, after B) water tops as
packed brick pieces.

## GDScript or C++ (TerrainRegions.md 10)

GDScript is not why breaks are slow (worker bakes) or frames long
(GPU-bound; the world's main-thread share 1.0-1.4 ms). Worth moving:
falling sand (`ground_collapse.gd _fall_sand`: a ray, solid tests and a
renderer call per cell, every frame; measure a big sand fall first), tree
scatter (`Trees.scatter` on the main thread, unsplittable per cell), laying
a fallen piece (`_let_group_go`, ~1 ms a 1,000 bricks: have the survey return
it ready). Small: tile collision boxes, lava rock. Leave: floaters, pieces'
physics, sky light, water glue.

Found for other areas (tell the user, do not fix there): the city's island
tick / fracture / promotion (8-42 ms, the biggest measured GDScript cost),
`BuildingShell.build_arrays` (2.7-5.7 ms), `snow_cover.gd`'s 1,024 rays a
square. In the terrain area and small: `TerrainCoarse.field_changed` blocks
on workers and is still called by `city_scene.gd` and
`heightfield_scene.gd` on every edit (the mine world uses
`field_changed_soon`) -- a CLAUDE.md "no waiting on a worker" break.

## Rules to keep (CLAUDE.md)

Own worktree; godot-cpp junction removed FIRST before `git worktree remove`;
`override.cfg` from `tools/test_window.cfg` in the worktree; launch from
Bash; one windowed pass at a time, heat summary after each
(`python tools/heat_sum.py`); timing runs only with the editor closed; no
renderer read-backs or worker waits during play; merge small and often.
