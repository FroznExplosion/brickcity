# Terrain regions -- ground kept in memory, bricks fitted per region

Written 2026-11-24. Plan only: nothing here is built yet.
Scene: `scenes/terrain_test.tscn` (the mine world, Docs/MineWorld.md).
Area: Terrain and water (`brick_terrain.*`, `terrain_bond.h`, `brick_fluid.*`,
`scripts/terrain/`, `scripts/water/`).

## 0. What the user asked for

- The world is a grid of 1x1 brick cells. Generation makes every cell, cuts
  caves, overhangs and cliffs, then **groups cells into real brick shapes**
  (2x2, 1x2, 2x4 ...) in **random sizes and orientations** that follow the
  caves and the terrain, then draws them.
- The cells of a shape are bonded for good; stress is checked only between
  bricks, at their tops and bottoms (where the studs are). Side connections
  (as in workshop.tscn) are a special case, for later.
- Tiles (1/3 of a brick) only on the surface and in caves, never in the bulk.
- Teardown as the model for destruction and stress.
- Two problems this has to help with: **a broken brick takes too long to
  disappear**, and **the terrain uses too much memory and frame time**.
- The water gets the same audit.

Chosen (2026-11-24): bricks fitted **per region, regions offset every
course** (section 3). Storing a brick id per cell as world state is kept as
an idea (section 9).

## 1. Where things stand (what the plan changes)

| | now | after |
|---|---|---|
| ground cells | not kept: every bake, `find_brick` and water read samples the tile again from the noise plus the edit table (`sample_tile`, ~4.5 ms a tile) | kept for the near tiles, compact, edits written in (section 2) |
| brick shapes below the top | `brick::bond_rect`: a fixed 4x4-block lattice, 4x2 / 2x2 / 1x2 / 1x1, parity-offset seams (Docs/TerrainBond.md) | a random fit per region, worked out from the generated cells (section 3) |
| top course | the packer's size ladder, or the bond (`set_bond_top`) | the same region fit, tiles allowed (section 3.5) |
| a broken brick | ~38-57 ms before the hole is drawn (MineWorld.md 21: find on a worker, whole-tile rebake from the noise, swap) | the hole in the shot's own frame, the rebake following (section 4) |
| stress | `TerrainCollapse.survey`: virtual bricks from `bond_rect`, the buildings' solver | the same solver, bricks read from the region cache (section 5) |
| water's view of the ground | `sample_column` reads the noise and the edits again per column (the real-sea square ~12 ms a tile, springs ~10 ms a tile) | a lookup in the same store (section 7) |

What does NOT change: the plate grid (x, z in studs, y in plates, so tiles
live in it), the solver (`solve_structure`, tension only at stud joints), the
pieces (`PlanetPieces`), the brick overlay (Docs/BrickOverlay.md), the far
tier, saving edits as differences from the seed.

## 2. Stage A -- the ground kept in memory (the Teardown / Minecraft part)

MineWorld.md 21 item 1, now unblocked: it was waiting on the brick overlay,
and the overlay is in (the old chamfered bake is off while it is on, so item
3 there, "one task for the flat and chamfered mesh", mostly goes away).

**What is kept.** For every tile the streamer keeps (`keep_radius`, ~240
tiles), the plate cells **as they are now (edits applied)** and **as
generated**, column by column, as runs: `(top plate, material)` pairs from
the bottom of the sampled band up. A generated column is a handful of runs
(air, grass, dirt, stone, a cave, stone, deepslate, ores); the generator is
already column-based, so a column is made in one go.

| form | per tile | ~240 tiles |
|---|---|---|
| `TileSample` as sampled today (`vox` + `open`, 2 bytes a plate, plus margin) | ~250-300 KB, made again per bake, per worker | not kept (transient, but paid on every bake) |
| runs, ~10 a column, 3 bytes a run, twice (now and generated) | ~60 KB | **~15 MB** |

These are estimates; stage A0 measures them. If the runs turn out slow to
read for the mesher, the fallback is 16^3 palettised sections (Docs/Terrain.md
2): more memory, faster random access. Both are much smaller than keeping
samples.

**Who reads it.** `sample_tile` fills a `TileSample` from the store instead
of the noise (a copy, ~0.2 ms instead of ~4.5); `find_brick`, the collapse
survey, sky light, `solid_at` near the player and the water (section 7) read
it directly. Tiles outside the store fall back to the noise, as now.

**Edits** write the store and the edit table together (the table stays: it
is what is saved, and what rebuilds a tile that left the store). One writer
(the main thread), readers by tile version, as the edit table already works
(MineWater.md 11.8).

**A0 -- measure first.** No measurement of the mine world's terrain memory
exists. Before building: a headless `terrain_mem_probe` (tools/probes/) that
prints, for the default preset after a walk: tile meshes (vertex bytes),
collision shapes, studs' MultiMeshes, the overlay's buffer, the deep
sections, the coarse rings, `PackStore` (up to 768 packs, 10-30 KB each,
~8-23 MB), the edit table, the water's sections, plus Godot's static and
video memory. That table decides what to cut first: if the packs or the
meshes dominate, they are cut before anything else in this plan, and the
store must pay for itself out of what it removes (the packs become part of
the region cache, section 3.4).

## 3. Stage B -- bricks fitted per region, regions offset every course

### 3.1 The rule

- A **region** is 16 x 16 studs of one course (3 plates). On even courses
  regions start on multiples of 16; on odd courses they are shifted 8 studs
  in X and Z. A region edge is never over a region edge (the same parity
  trick `bond_rect` uses for its seams, at a larger scale).
- Inside a region, a **fit** groups its solid, bondable cells into bricks.
  It is seeded from the region's coordinates and the world seed, and reads
  **only the region's GENERATED cells**. So it is a pure function: any tile,
  any load order, any thread gives the same bricks, and nothing is saved.
- **Edits never refit.** A refit after a break would reshuffle the bricks
  round the hole. A broken brick goes whole (as now); its neighbours keep
  their shapes. A crater (`carve`) takes every brick it touches, whole,
  rounded out to brick edges -- or, if that reads wrong, keeps a cut brick's
  remaining cells as one fragment brick. That is a decision for the
  first test (B3).
- **Placed blocks** keep their own shape (`mark_placed`, as now); the fit
  never sees them, because it reads generated cells.
- **Loose ground** (sand, red sand, gravel) stays 1x1, joined up and down
  only, so it falls in columns.

### 3.2 The stagger rule

A purely random fit makes seams that stand over the seams of the course
below, and an overhang peels apart along them (TerrainBond.md 1: "a 2-course
arm came apart in two"). The fit therefore knows the course under it (also a
pure function: the region fits of the course below, generated cells only)
and does not place a brick whose edge runs along a seam below for more than
one stud. Where nothing else fits, a 1x1 is allowed (scored, section 3.3).

### 3.3 Which fit -- measured, not guessed

A headless `region_fit_probe` runs each candidate over the same 30 tiles
(default preset, with caves and cliffs) and prints:

| measure | why |
|---|---|
| share by size (1x1, 1x2, 2x2, 2x4, 2x6 ...) and mean brick size | the look; Terrain.md 6.2 got 50 % 2x4 and 4 % 1x1 with its ladder |
| orientation balance | courses running both ways |
| seams over seams per 1000 joints | the bond's strength (TerrainBond.md 3 checks this today: 0) |
| test arms held (terrain_collapse_probe's stone arm, dirt arm, 40-stud arm) | what the stress feels like |
| fit ms per region, per tile | the cost |
| bricks per tile | what the overlay, the survey and the seams pay for |

Candidates:
1. **Largest first** (the surface packer's way): 2x6 / 2x4 everywhere they
   fit, a hashed skip so they do not carpet; then 2x3, 2x2, 1x4 ...; 1x1 last.
2. **All sizes at once**: visit cells in a hashed order, at each pick a size
   and orientation by weights, place the first that fits; 1x1 last.
3. **Largest first along walls**: as 1, but cells next to cave air or open
   air are fitted first, so long bricks run along walls, cliffs and cave
   roofs (they are what is seen).

Every candidate: both orientations of every non-square size, chosen by hash;
the material rule of the bond (a brick is one bond group; a 2x4 / 2x6 only
in strong ground, medium ground up to 2x4 -- to be tuned in the probe).

### 3.4 Where the fit lives

The region cache: per region, the bricks (corner, size, material) and a
cell -> brick index for the 256 cells. Made on demand (a tile's bake asks
for its regions and the ones half over its edges), kept with the tile in the
store, dropped with it. It replaces `bond_rect` for every caller (drawing,
breaking, falling), so they keep agreeing, and it takes the place of the
`PackStore` packs. A miss costs a fit of the region and the one under it
(the stagger rule): microseconds per region, to be measured (B1).

### 3.5 The top course and tiles

The top course is fitted the same way, with tiles allowed: a cell whose top
is a tile (ledge edges, corners, cave floors) fits into tile pieces, never
into a brick. Tiles are generated only there (surface and cave floors), never
in the bulk. A brick placed by the player one plate up, on a tile, is a
placed block (`mark_placed`), so the fit is not involved; whether the
builder allows it, and whether its joints solve right, is checked in B3.
If not, the builder refuses it.

### 3.6 Stages

- **B1** `region_fit` (C++, `terrain_bond.h` beside `bond_rect`) and the
  probe of 3.3; all three candidates; pick one with the user, from the probe's
  table and its pictures (`user://dev/region_fit/`).
- **B2** The region cache; `bond_rect`'s callers switched to it behind a
  world setting (old bond kept for A/B until B4).
- **B3** Craters, placed blocks, the brick on a tile; `mine_world_probe`
  `_check_bond` changed to check regions (every cell of a brick names it, no
  seam over a seam, a buried break takes one brick); `terrain_collapse_probe`
  arms; `--gate=collapse`.
- **B4** The top course on the fit; the old bond and `set_bond_top` retired,
  their checks removed with them (say why in the commit).

## 4. Stage C -- the hole in the shot's frame

What a break waits for today (MineWorld.md 21): the find on a worker (~5 ms,
but queued), the whole tile rebaked from the noise (~9-10 ms), the swap. Best
case ~47 ms, three frames; under fire more.

With stages A and B:

1. **Find on the main thread.** With the store and the region cache,
   `find_brick` is a ray walk over kept cells and a cache lookup: well under
   0.1 ms. It runs in the shot's frame, no worker, no queue.
2. **Hide it in that frame.** The overlay drops the brick's instance at once
   (BrickOverlay.md 4 stage 6). The flat mesh still has its faces until the
   rebake: the terrain shader gets a small per-tile list of **cut boxes**
   (uniforms written from the main thread, no read-back) and discards what is
   inside them.
3. **Fill what the hole opens, in that frame.** The bricks around the hole
   whose faces were inside the ground are boxes in the region cache; the
   overlay adds them as instances at once, so the hole has walls and a floor
   before any mesh is rebuilt.
4. **Then the rebake**, from the store (no noise), and only of the part of
   the tile the edit touched (MineWorld.md 21 item 4: a 16 x 16 quarter, which
   is now also a region's width). When it swaps, the cut boxes and the extra
   instances go.

Target: the hole drawn in the shot's frame (16 ms) or the next. Measured with
`-- --gate=breaklag --burst` (it times trigger to drawn hole) against today's
57 / 84 ms at a shot a frame and 50 / 62 ms at one every 6 frames.

- **C1** find on the main thread from the store; breaklag.
- **C2** cut boxes in terrain.gdshader + the overlay's instant fill; gate
  pictures of a hole in the shot's frame (`--gate=handover` must stay 0 gaps,
  0 drawn twice).
- **C3** quarter-tile rebakes; breaklag, `--gate=handover`, `--gate=deep`.

## 5. Stage D -- stress on the region bricks

- The survey takes its bricks from the region cache (the bricks drawn and
  broken), not `bond_rect`. The solver does not change: one node a brick,
  joints where footprints overlap between courses, tension only. The cells
  inside a brick are never checked against each other (they are one node).
- Bigger bricks mean fewer nodes; the survey's region is the same.
- **Side joints** (later): a placed part with side studs
  (`BrickWorld.set_side_studs`) joins the brick its studs face. Ground the
  generator makes never has them. Today `get_block_neighbours` joins
  overlapping footprints up and down only; side joints are an extra list of
  edges per block, from its archetype's side studs.

## 6. What it buys, by the user's three problems

**Breaks too slow to disappear.** The biggest win of the plan. Today ~13 of
the ~24 ms of worker time a break costs is making ground again that did not
change, and the find waits on workers. With A + C the hole is there in the
shot's frame, before any mesh is made, and the rebake that follows is a
quarter tile from memory.

**Frame time.** The terrain's own main-thread share is already small
(1.0-1.4 ms, MineWorld.md 21), so the frame wins are indirect but real on
this machine:
- This is an APU: worker heat comes out of the GPU's clocks, and the frame is
  GPU-bound. Every bake that stops making ground from the noise (each tile
  streamed in, each edit, each water section, each collapse survey) is CPU
  that stops slowing the GPU.
- Fewer, bigger bricks (B) are fewer overlay instances and fewer merged
  faces, so fewer triangles and a cheaper overlay fill.
- Quarter-tile rebakes (C3) are a quarter of the swap and upload.

**Memory.** It depends on A0's table. The store is a new cost (~15 MB
estimated); it is meant to pay for itself by removing the `PackStore` packs
(up to ~23 MB) and the per-worker samples (~300 KB each, per bake in flight),
and by letting meshes be rebuilt from it instead of being kept for tiles that
are not drawn. If A0 shows the big costs are elsewhere (meshes, collision,
the far tier, trees), those come first and this plan says so.

**And the look.** Random sizes and directions that follow walls, cliffs and
cave roofs, in place of the 4x4-block lattice that reads as regular.

## 7. The water (audit, 2026-11-24)

The water already works the way this plan wants the ground to work: its
cells are kept (`BrickFluid` sections, 32 x 32 x 16 bricks, 48 KB each, only
where water was changed or moves), only what changed runs (an active set),
on its own thread, with its own small mesher, and calm water costs nothing
(0.07 ms a tick, 0 awake). It is in good shape. What it would gain:

1. **Read the ground from the store** (the biggest). `sample_column`
   (brick_fluid.cpp) works out the biome column and the cave noise again, and
   looks up the edit table per plate, under the edit lock, for every column
   it fills: a new section, the real-sea square (~12 ms a tile, three tiles a
   tick), springs (~10 ms a tile), cave pools, every terrain edit's re-read.
   With stage A that is a copy of kept runs. It also means the ground and the
   water can never disagree about which plates are solid.
2. **Tick cost.** The only reading (MineWater.md 12) is ~2.3 us a cell, a
   debug build with the editor open: 20k flowing cells ~18 ms a tick, the 64k
   budget ~57 ms, against an estimate of 50 ns. Re-measure in a release build
   with the editor closed. If it holds, profile it before guessing; the doc
   already suggests lowering the budget to ~20k.
3. **Written sections never go.** A section ever written, or wet, stays in
   memory for the session (11.8 drops only dry, unwritten ones). A big flood
   far away stays resident. Calm sections past the sim ring could be kept in
   their save form (run-length, as `.fluid` stores them) and expanded when
   the player comes back.
4. **Water tops as bricks** (MineWater.md 2, "later"): still water and the
   real-sea band packed into mixed pieces by the same region fit (tops only),
   so a pond reads as laid bricks and has fewer quads. Optional, after B.
5. **Its own lock and the edits.** The water reads the edit table under
   `edit_lock()` shared; with the store, the store's tile version replaces
   that lock for reads near the player.

Water stages (after A): **W1** `sample_column` from the store; water gate and
`fluid_probe`. **W2** the tick measured in a release build; profile if
needed. **W3** far written sections compressed. **W4** water tops as pieces,
with the user, after B.

## 8. Order of work, and the checks each must pass

1. **A0** memory table (headless). Report it before building anything.
2. **A** the store; `sample_tile` from it. `terrain_audit_probe` (0 faults),
   `terrain_probe`, `mine_world_probe`, `terrain_cost_probe` (bake ms before
   and after), `--gate=handover`.
3. **C1** find from the store; `--gate=breaklag --burst`.
4. **W1** water from the store; the water gate, `fluid_probe`.
5. **B1-B3** region fit, chosen with the user; probes of 3.6.
6. **C2-C3** the hole in the shot's frame; quarter-tile rebakes.
7. **D** stress on region bricks; `terrain_collapse_probe`, `--gate=collapse`.
8. **B4**, **W2-W4**.

Windowed gates one at a time with a heat check between (CLAUDE.md); timing
runs (`--gate=gpu`, breaklag, cost probe) only with the editor closed.

## 9. Kept as an idea: a brick id per cell, stored

The other way to fit: run the fit once when a chunk is first generated, in
any order, and **store** each cell's brick id as world state (saved with the
world, sent to peers). No regions, no stagger across region edges to worry
about, any fit at all (even one that looks across a whole cave).

Why not now: a brick crossing a chunk edge needs both chunks generated, so
the fit depends on the order the player walks in (two players, or one world
reloaded, get different bricks unless the order is fixed); the ids are new
saved state for every chunk ever visited, where today an untouched world
saves nothing; and the far tier and the water would need the same ids or
disagree. Worth revisiting if the region fit's seams at region edges show,
or if bricks wanted across whole cave walls.
