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

### 2.1 A0 measured (2026-11-24)

`res://scenes/terrain_test.tscn -- --gate=mem` (windowed: video memory is
only real with a renderer; `tools/probes/terrain_mem_probe.gd`, run by the
gate). Default preset, near radius 4, keep radius 6; spawn, then a 480 m
flight along X at 40 m, 40 cells carved, then 25 m underground. Debug build,
other chats' runs going (LOW RAM samples): bytes are right, ms are not.

| what | at spawn | after the flight | note |
|---|---|---|---|
| **reflection atlas** (video textures) | 0 | **+536 MB** once one probe shows | the first visible ReflectionProbe makes the whole atlas (256 px x 64 slots); process private +830 MB (the Z1 shares RAM). Every probe in the game is ambient-only (`cull_mask = 0`): the atlas holds nothing. The mine world's held-item box (`MineWorld._held_light`) shows one as soon as the eye is dim |
| other video textures | 548 MB | 548 MB | materials' own textures only 50 MB (9 ImageTextures ~5.6 MB); the rest is the renderer's (shadow maps, screen targets, sky) |
| video buffers | 143 MB | 115 MB | |
| water sections (C++) | 24 MB, 272 | **122 MB, 1,359** | ~90 KB a section; **wet sections are never evicted** (`evict_far` keeps written or wet), so a flight over sea grows it without end (1,030 wet) |
| near tiles' kept `_data` (CPU) | 74 MB | 35 MB | the bake's whole Dictionary, mesh arrays included, kept after upload |
| near tiles' meshes (GPU) | 36 MB | 13 MB | 144 -> 217 tiles |
| near tiles' MultiMeshes (studs, tufts) | 8 MB | 12 MB | 103k -> 154k instances |
| far rings' meshes (GPU) | 28 MB | 20 MB | 335 meshes |
| packed tiles (C++ `PackStore`) | 2.3 MB, 144 | 9.9 MB, 704 | 30 B a piece, ~14 KB a pack |
| trees | 2.1 + 0.7 MB | 2.1 + 0.3 MB | |
| collision boxes | 4,941 | 5,708 | ~2 MB at an estimated 400 B a box |
| brick overlay | 0.04 MB | 0.04 MB | |
| edit table | 0.025 MB | 0.025 MB | 120 edits |
| Godot static | 464 MB | 457 MB | |
| process private | 2.2 GB | 2.4 GB (3.0 GB with the atlas) | |

Stage A's store, counted from the real cells (every resident tile and deep
section sampled as a bake samples it, its columns' material runs counted,
3 B a run twice plus 2 B a column):

| | runs a column | store each | all resident | a sample today (transient) |
|---|---|---|---|---|
| surface band (141 plates) | 6.2 | 39 KB | 8.7 MB, 217 tiles | 378 KB, 4.6 ms |
| deep section (93 plates) | 2.5 | 17 KB | 4.3 MB, 247 sections | 253 KB, 3.2 ms |

So the store is ~13 MB, smaller than the section estimate (15 MB), and less
than the packs (10 MB, which it replaces) plus the tiles' kept `_data`
(35-74 MB, whose mesh arrays it makes unneeded).

What this says to do first: the reflection atlas (one setting, ~530 MB of
video and ~800 MB of RAM, not terrain: the lighting rig's) and the water's
wet sections (W3, moved up: unbounded) are bigger than everything the
terrain keeps put together.

**Done 2026-11-24 (the reflection atlas):** project.godot
`rendering/reflections/reflection_atlas/reflection_size = 32` (count left at
64: a box per near bricked building, per near ship/station module, the held
box -- 4 in --gate=light). `--gate=mem`'s line: one visible probe +16.9 MB
(was +536). Pictures and numbers the same at 32 as at 256: planet
--gate=light (room inside 0.550 both, pictures differ only in the HUD's fps),
--gate=hull (cabin; the still views differ only in HUD text), mine
--gate=deep (cave with the held gun, picture mean 0.044 / 0.046, the lava's
flow differing).

**Done 2026-11-24 (the rest of the video textures):** the ~550 MB left was
NOT the renderer's buffers. Taken apart (terrain_mem_probe's "renderer"
steps, tools/probes/vram_baseline_probe.gd):
- an empty Godot window on this GPU already holds 186 MB of textures, a bare
  3D view (camera, sky, shadowed sun) 264 MB; of that only the directional
  shadow atlas shrinks (2048 at the default Shadow Quality: 16 MB). The
  positional atlas, glow, sky radiance (1.7 MB), screen targets (13.6 MB at
  render scale 0.75 -> 0.25) are small. The compressed PBR texture arrays
  (~170 MB BPTC) are not in this counter at all.
- **ItemIcons kept its 1792x2408 SubViewport alive, 3D, MSAA 4x**: ~300 MB of
  multisampled buffers for a ~17 MB picture. Now copied once into an
  ImageTexture at load (a read-back at load, allowed) and the viewport freed.
  --gate=mem: video textures at spawn 597.9 -> 299.4 MB, video total 830 ->
  492 MB. The icon sheet is pixel-identical (--gate=inventory saves it to
  user://dev/mine_item_icons.png; INV-GATE PASS).
- Left: ~264 MB the engine holds for any 3D window, ~35 MB of game textures
  the counter sees (impostors 50 MB, grid light 16 MB counted elsewhere).

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

### 3.6 Bricks across chunk edges -- measured (2026-11-24)

The user asked: does it cost performance or generation time if bricks cross
chunks, a 2x2 in up to 8 chunks? Measured with a standalone C++ bench in a
Linux container (no Godot there): the REAL generator (`terrain_biomes.cpp`,
`biome_column` + `biome_cell`, the default preset) linked with a stand-in
region fit (largest first, 2x4 down to 1x1, hashed skip, the bond's groups;
no stagger rule). Three areas of 6 x 6 tiles, the surface band (31-36
courses). One thread, not the Legion Go: read the ratios, not the ms.

- **At most 4 chunks, never 8.** Every vertical boundary is on a course
  (deep sections are 96 plates = 32 courses; the surface floor and
  `SECTION_BELOW` are multiples of 3), and a brick is one course tall. A
  brick shorter than a tile is in 4 only at a tile corner.
- **How many cross**: regions offset 8 on odd courses -> **3.3-3.5 %** of
  bricks cross a tile edge, **0.04 %** are in 4 tiles. Each of those makes a
  break rebuild 2 (or 4) tiles instead of 1: ~3-4 % more tile rebuilds over
  all breaks. With quarter-tile rebuilds (C3) roughly twice that, still small.
  The bond already crosses tile edges on odd courses (TerrainBond.md 1).
- **Fit time**: 8.7-9.6 us a region with crossing, 11-12 us aligned to tiles
  (the same work; the offset just cuts it differently): **~1.3 ms a tile**
  for the surface band, once, cached. Not a reason either way.
- **Generation time**: the bench's own sample, 4.8-5.8 ms a 32 x 32 tile,
  agrees with `sample_tile`'s ~4.5 ms (MineWorld.md 21), so the generator in
  the bench is the game's. Fitting a tile's offset regions needs cells 8
  studs past its edges: from the noise that is a 48 x 48 sample, **10.7-13.1
  ms** against 6.0-7.3 for today's 2-stud margin. With the store (stage A)
  the neighbours' cells are already kept (the streamer keeps two tiles past
  what it draws), so it costs nothing except at the outer edge of the kept
  ring, which is never drawn.
- **Stress**: none. The survey's region is a box round the edit, whatever
  tiles it covers.
- **And it is needed.** With no brick crossing a tile (regions aligned to
  tiles), every tile edge is a seam in every course: a crack plane through
  the whole ground. Allowing the crossing cut the seams over seams ON tile
  edges by 40-44 % (12,441 -> 7,132; 12,817 -> 7,162; 10,881 -> 6,077).

**The real open problem is the stagger, not the chunks.** The stand-in fit
has 257-326 seams over seams per 1,000 joints (the bond today: 0). A simple
rule (refuse a brick with more than a quarter of its edge over seams below)
cascaded: once a course was mostly 1x1, every brick above it was refused, and
96 % of bricks were 1x1. B1 must design the stagger (a parity rule like the
bond's, or a fit that scores against the course below rather than refusing),
and the probe of 3.3 must show it.

The bench: `bench.cpp`, `noise.cpp` (the noise copied from brick_terrain.cpp),
`stubs.cpp`, built with godot-cpp's headers only; not in the repo (tools/
holds Godot scripts). B1's `region_fit_probe` replaces it.

### 3.7 Stages

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
5. **B1-B3** region fit, chosen with the user; probes of 3.7.
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

## 10. GDScript or C++? An audit (2026-11-24)

The user asked what in the terrain, water and bricks should move from
GDScript to C++. Read from the code and the costs the docs have measured;
nothing new was timed (no Godot in the container this was written in).

**The finding first: GDScript is not what makes breaks slow or frames long.**
- The frame is GPU-bound (12.5 of 16.6 ms on the Legion Go before anything
  happens, MineWorld.md 9). The whole world's main-thread share is 1.0-1.4 ms
  a frame, and an edit's worst main-thread step 1.1-1.5 ms.
- A break's latency is on the workers (the find, the whole-tile rebake from
  the noise, the swap), all C++ already. Its GDScript (`_break_from_box`,
  `terrain_edited`, `_flush_edits`) is a few calls. Stage A and C fix the
  break; moving its GDScript would not.
- The heavy work is already C++: generation, bakes, packing, the collapse
  survey and solver, the overlay's pick (moved 2026-11-23: it was a 5 ms
  GDScript loop), the water's rules, its mesher and its locks. Waits on
  workers in the mine world are all checked with `is_task_completed` first.

**What is worth moving**, by how often it runs and what it costs:

| # | What | Where | Why | Verdict |
|---|---|---|---|---|
| 1 | Falling sand | `ground_collapse.gd` `_fall_sand` | every frame, per column: a physics ray, a `solid_at` per plate fallen, and a `set_instance_transform` per cell (one renderer call each). A sand cliff let go is hundreds of columns, thousands of cells. Not measured. | **move**: one C++ step for all columns (solid tests from the store, one buffer out, `multimesh.buffer` set once). Measure first with a big sand fall. |
| 2 | Tree scatter | `trees.gd` `Trees.scatter`, called by `terrain_trees.gd` | per 128-stud cell, on the main thread: a Callable per grid point (biome chance), four `surface_plate` per tree (each a generator column). The 'budget' is checked between cells, so one cell is never split. Not measured. | **move** to C++ on a worker (pure function of seed and ground), main thread only places; with stage A, `surface_plate` reads the store |
| 3 | Laying a fallen piece | `ground_collapse.gd` `_let_group_go` | GDScript loops build the runs and the BrickWorld arrays from the survey's result: ~1 ms a 1,000 bricks, main (TerrainCollapse.md 6) | **move into the survey**: it returns the runs and arrays ready, on its worker |
| 4 | Collision boxes of a tile | `terrain_tile.gd` | one `PhysicsServer3D.body_add_shape` a box from GDScript (~65 a tile; 670 measured 0.77 ms) | small; a C++ helper adding a tile's boxes in one call, if a profile shows it |
| 5 | Lava rock | `mine_water.gd` `apply` | one `fill_box` a cell in a GDScript loop | small; one batched call |
| 6 | Floaters, pieces' physics | `floaters.gd`, `planet_pieces.gd` | per body, a few native calls a tick; capped (100 pieces laid) | **leave**: glue on bodies, which are main-thread anyway |
| 7 | Sky light on things | `mine_sky_lit.gd` | budgeted, 250 us a frame | **leave** |
| 8 | Water glue | `mine_water.gd`, `water_sea.gd` | swaps meshes (6 a frame), copies wave numbers, burns at 10 Hz | **leave**; the water's work is C++ |

**Outside the mine world, measured, other areas** (for their chats; listed in
Docs/WhereWorkRuns.md 2 and EngineChoice.md):
- The city's destruction: the island tick (worst 8-12 ms), fracture spawning
  and promotion (42 ms) -- GDScript plus node and body creation, the largest
  measured GDScript costs in the project. EngineChoice.md's first
  recommendation is moving them to C++ and making fewer nodes and bodies.
- `BuildingShell.build_arrays`: geometry in GDScript, 2.7-5.7 ms
  (HandoffPerf.md).
- Snow lying on the ground (`snow_cover.gd`, city and planets, not the mine
  world): 1,024 physics rays a square from GDScript, 2.4 ms a tick while it
  fills. On brick terrain it needs no rays: the ground's top is known (the
  store, or `surface_plate`).
- `TerrainCoarse.field_changed` waits for its bakes on the main thread
  (`wait_for_group_task_completion`, then `_rebuild_ring` bakes and waits
  again). The mine world uses the non-blocking `field_changed_soon`; the
  city (`city_scene.gd`) and the heightfield scene still call the blocking
  one on every terrain edit -- a CLAUDE.md "no waiting on a worker" break.

**Order**: 3 goes with stage D (the survey's output); 1 and 2 after stage A
(they read the store); 4 and 5 only if a profile asks. The coarse tier's
blocking edit is the terrain area's, small, and can go any time.

## 11. Decisions (the user, 2026-11-24, after A0)

- **Bricks stay whole in cells.** No brick sits a plate off the course grid
  in generated ground (a brick on a tile would rest, not connect, and an
  off-course brick could be in 8 chunks). The surface and cave surfaces get
  tiles and plates, smooth and studded.
- **Taller bricks for the caves' look.** All-horizontal courses look uniform
  in caves; bricks 2 and 3 courses tall break the lines. Fitted in LAYERS of
  3 courses: a tall brick stays inside its layer, layers fitted bottom-up,
  each staggered against the layer below only (deterministic, no long
  dependency chains). A tall brick never crosses a deep-section boundary
  (keeps the 4-chunk limit).
- **Sizes wanted** (not built yet): footprints 1x1-1x6, 2x2-2x6, 3x3-3x6;
  1, 2 and 3 bricks tall; plates (studded) and tiles (smooth) in the same
  footprints. Drawing costs nothing per size (the overlay is one scaled box
  a brick); the fit has more candidates to try (measure in
  region_fit_probe).
- **Connections cost by joint, not by cell.** A brick is one body: its cells
  are never checked against each other. A face with nothing to connect
  (sides, a smooth face) is no joint at all. So bigger and taller bricks make
  the survey and the solve CHEAPER (fewer bodies, fewer joints).
- **Faces say what they connect** (the stud model, below): studs on top
  (joins what is above), sockets underneath (joins studs below), smooth
  (joins nothing). A joint exists only where a studded face meets a socket
  face; its strength is the studs that overlap. Kinds this allows:
  - brick / plate: studs on top, sockets under (today's);
  - tile: smooth top, sockets under;
  - **smooth-top brick**: a brick with a tile's top, so areas can be smooth
    without ever laying tiles;
  - **smooth-bottom, studded-top** tile or brick: cave decoration that sits
    on the ground and connects nothing below (like the city's light pieces),
    something to build on.
- **Studs as data, not part of a brick's shape (later; the design leaves
  room).** Each brick face has a stud mask; the generated ground's masks
  come from the brick's kind (nothing stored); only a changed brick stores
  its masks, in an exception table saved like the edits. That allows a
  future stud tool (add or take studs on tops, bottoms and sides; side studs
  on the side-stud grid only, gated), and custom bricks such as a 2x4 with
  7 studs. Studs are already drawn one instance a stud, so drawing from a
  mask is natural; joints read the mask's overlap.
- **Slopes and curves as dress-up (question, not decided).** The old try
  (Terrain.md 17.15, 19.22) baked them into the tile mesh: 1x1 ramps read
  as melted, terrace slopes cost 381k -> 660k triangles, specks at tile
  seams. Now: a slope is a fitted brick kind (fills its cells, studs only
  on its flat strip by the stud mask), placed by hash at open edges (tops,
  cliff lips, inverted under overhangs and cave roofs), never 1x1 ramps.
  Drawn as overlay instances within the overlay's 12 m (one draw call a
  kind, nothing stored); 12-45 m either plain baked faces or the step as
  now -- pictures decide; far rings never. Stage B5, after the fit.
- **The fill (chosen 2026-11-24): a quota fit, not largest-first.** Each
  world (its worldgen preset) names target shares BY COUNT, e.g. 20 % 2x4,
  20 % 2x2, a few % of every other size, filled with 1x2 and 1x1. Inside a
  region the fit visits cells in a hashed order and picks, among the shapes
  that fit, by how far each is under its share (deficit-weighted), both
  directions by hash; 1x2/1x1 fill last. Same mix at walls and inside them
  (walls-first was dropped: bland caves, odd filler when digging). Loose:
  regions are small samples, the world hits the shares on average.
- **Stagger: option (c), scored, never refused.** The score's weight is a
  per-world (or per-depth) knob: lower in caves means more seams over seams,
  weaker roofs, the instability wanted there.
- **Bricks cross every chunk seam**, tile edges and section boundaries alike
  (tall bricks too: up to 8 chunks, rarely). Measure the extra rebuilds.
- **Bricks jut into caves**: a wall brick may run 1-2 studs out into cave
  air (hashed, strong ground, most of the brick in the wall). A pure part of
  the fit, so the ground "as generated" is the generator plus the juts; it
  waits until every reader takes the store (find_brick, light, collision,
  water W1); the far tiers never see juts.
- **Big groups float.** A loose group over N cells (per world, ~500) does not
  fall: it is held as if grounded; groups under N fall as now. No 1,000-brick
  breaks from one hit, and the survey can stop counting at N (cheaper than
  today's 1.2 M-cell limit). Groups under N hanging by a neck are the
  instability. Stage D, or earlier on its own (it is the survey only).
- **Shares are loose: target +-5 points** (20 % means 15-25 % by count).
  The shapes a world may use and their shares are SETTINGS (the worldgen
  preset and its menu); sand, red sand and gravel are always 1x1 whatever
  the settings say.
- **Crossing chunk seams is a knob too**: a chance a brick may cross a tile
  edge or section boundary (where it fits). Lower = fewer 2-4 chunk
  rebuilds per break; higher = fewer crack planes on tile edges (crossing
  cut seams over seams there 40-44 %). region_fit_probe reports both so the
  default is picked from numbers.
- **Stage A, done by the terrain-audit chat** (2970aa35, MineWorld.md 21
  item 1): tiles and deep sections keep their GENERATED cells (`GenStore`,
  the sample's raw `vox`, ~180 KB a surface tile, 64 kept each, LRU by use),
  edits laid over on each sample; find_brick 5.1 -> 0.2 ms, a rebuild 10 ->
  5 ms. Not the run form of section 2 and not every near tile (64, not
  ~240): enough for breaks; the fit's 8-stud reach and the water (W1) may
  want more kept, to be measured. W3 (far water let go or parked) merged by
  the water chat (f546587b).

## 12. Stage B3: the switch-over (plan, 2026-11-24)

Built so far (main a540db67): `TerrainFit` (terrain_fit.*) fits regions in
the probe; the world's settings reach it (`TerrainFit.configure`, preset
"bricks", M menu Bricks tab). Nothing drawn from it yet.

What B3 changes, every caller of the old pattern (`brick::bond_rect`):

| where | what it does now | with the fit |
|---|---|---|
| `brick_terrain.cpp` top course (~2058, ~2098) | the packer cuts the top course from the bond; "held" studs | the fit's top-course bricks; plates and tiles (smooth/studded) from section 11 |
| `BondView::rect` (~2253) and `brick_key` in the mesher (~4345) | seams = bond rectangles, a brick's key is its course | `fitted_brick(x, c, z)`: the key is the brick's BOTTOM course, so a tall brick draws no seam inside it |
| `find_brick` / `find_bricks` / `piece_runs` | the whole bond brick goes | the whole fitted brick (all its courses) |
| the overlay's brick list (`overlay_bricks`) | a box per bond brick, one course | a box per fitted brick, `h` courses tall |
| `terrain_collapse.cpp` (~403-472) | virtual bricks from the bond | fitted bricks; a tall brick as one body (stage D) |
| cell colours | per cell | per cell (coal shows in a stone brick), properties from the brick's material |

The lookup: `brick::fitted_brick(x, course, z) -> {x, z, c, sx, sz, h, mat}`,
from a cache of region fits keyed (rx, rz, layer), filled on a miss from the
kept generated cells (GenStore), LRU like the packs. A region needs its
squares' cells, cells 2 round (cave air) and column tops; an odd layer
needs the two even layers' fits round it. `region_fit_probe` gains a check:
the cached lookup equals the batch fit, queried in any order and from
several threads.

Behind a switch (`TerrainFit.set_enabled`, off until the gates pass):
`terrain_bricks_probe`, `terrain_audit_probe`, `mine_world_probe`,
`terrain_collapse_probe`, `--gate=bricks`, `--gate=breaklag --burst`.

Who: the terrain-audit chat owns the overlay and break speed and is editing
the mesher and `find_brick`; the lookup and the cache are this chat's
(terrain_fit.*). The callers' switch is one change across their code: agree
who makes it before starting.

### 12.1 The lookup, built (2026-11-25; rebuilt per region the same day)

`brick::fitted_brick(x, course, z, FitBrick&)` and, for many lookups from
one thread, `brick::FitView` (terrain_fit.h; scripts: `TerrainFit.brick_at`).

- **Per region, any depth.** A cell's brick is in exactly one region (the
  square of its course holding it, in its layer). Regions are fitted on a
  miss and kept, least recently used out (32768, ~500 B each: 4-byte bricks
  from the region's corner; sand and gravel not listed). An even layer's
  region is fitted from its own cells; an odd one's with the even regions
  round it, fitted with it or laid in from the cache (their sand and gravel
  laid back as 1x1s: the seams there count). Each region's whole reach is in
  the area it is fitted in, so it is the same whoever asks first.
- **The generator's cells**, never the edits: `brick::generated_cells` reads
  the kept generated tiles and the deep tier's sections (deep tier on or off:
  the fit must not depend on what has been dug or sampled so far). The top
  course (the surface's pieces) is never fitted.
- **Checked** (`region_fit_probe -- --lookup`): every cell the batch fit
  has whole (48 studs in from its sides) asked from 4 threads in a shuffled
  tile order equals the batch fit, at the surface and 200 courses down
  (~330k cells, 0 wrong).
- **Memory**: ~400-650 B a region, ~130 KB a freshly baked tile's worth
  (regions it needs and those round it; neighbours share them). The old
  per-tile cache was 390-500 KB a tile.

The old note that a release build would be several times faster was wrong:
the "debug" template is built optimised (godot-cpp's `speed_trace`).

### 12.2 The switch-over, built (2026-11-25)

`TerrainFit.set_enabled(on)` (preset `bricks.fitted`, M menu Bricks tab
"Use these bricks in the game (test)", `--fitted` on the mine world and on
the probes below). **Off by default.** On:

| where | with the fit |
|---|---|
| `BondView::rect` (mesher seams, overlay, find_brick, find_bricks) | the fitted brick, with its bottom course and height (`BondRect::c`, `h`): a tall brick draws no seam inside it, breaks whole, is one overlay box |
| ground no fitted brick holds whole (built up by edits, the rest of a brick a hole cut) | the old pattern among those cells only (it never overlaps a fitted brick) |
| `terrain_collapse.cpp` survey | the fitted footprint a course (a tall brick is one body a course until stage D), the same fallback |
| top course | the packer's pieces, as before (plates and tiles on cave surfaces: later) |
| colours | per cell (coal shows in a stone brick); a brick's strength is its main material's |

The mesh asks the regions of its open faces first (`prefetch_open`), so a
region is fitted where something of it is drawn, plus the even regions an
odd one reads.

Probes with `--fitted`: `terrain_bricks_probe`, `terrain_audit_probe`,
`terrain_collapse_probe` PASS; `mine_world_probe` passes all but its bake
time; old path unchanged (all four PASS). `mine_world_probe`'s "no seam over
a seam" is the old pattern's rule; under the fit it checks "few" (10% of
joints at most, measured 2 of 108): the stagger is scored (section 11).

**Open: the cold bake.** Once a tile's regions are kept a bake costs what it
did (tiles 15.1 vs 13.6 ms, sections 8.1 vs 5.8). Cold, a tile took 143-174
ms (120 allowed) and a deep section ~170 ms: about 70% of it is sampling --
a region's fit reads the generated cells ~1.5 tiles round (an odd region's
even neighbours), and making those neighbours' noise early is most of the
cost (3,500 cells sampled a region for 768 fitted). To do before the switch
is on: keep the fit's own coarse cell store wider than the generated-tile
store (64 tiles), or fit in the order tiles stream so neighbours are kept;
then the fitter's own time (~200 us a region: the candidate loop's fits and
seam counts).

**Measured with the switch on (2026-11-25, windowed, one run at a time):**

- `--gate=bricks --fitted` PASS (fill 0.5 ms, a shot brick hidden the frame
  it is hit, its hole handed over in 2-5 frames).
- `--gate=breaklag --burst`: fitted 30 of 30 broke, trigger to hole mean 34
  ms, worst 47; old pattern mean 33, worst 38.
- `--gate=flight` (1440 m fast flight, streaming): old pattern worst frame 38
  ms, 1 over 33 ms, 0 holes; fitted worst 659 ms, 23 over 33 ms, the flight
  15 -> 18 s. Free RAM hit 0 MB in the fitted run (142 MB in the old), so
  paging is in those spikes too; but no main-thread path fits a region (the
  coarse far tier does not use the bond; tiles bake on workers), so the cost
  is the workers' load (about 3x a tile's bake, cold) taking cores from the
  main thread.
- Cold split, a tile in a row of 4 (`build_tile`, headless): neighbours'
  noise ~114 ms, the fit ~45 ms (~270 regions: the tile's and the even
  regions round them, fitted ahead for its neighbours), the mesh 14. The
  fitter: the wide pass 37%, the raster fill 34%, cave air 17%. Speedups
  that change no brick (keys sorted once, the course under counted once a
  footprint, free cells as row masks): the batch fit 13.2 -> 9.1 ms a tile.

Next, before the switch is on: the halo (an odd region's even neighbours
reach ~1.5 tiles, so a tile's fit makes its neighbours' noise and regions
early) -- fit regions where a tile's own bake asks, keep the noise the
fit made for the tiles that follow (the generated-tile store holds 64), and
the seams count a candidate does (40% of the fit).

**The cold cost, cut (2026-11-26).** What changed (no brick changed:
region_fit_probe's numbers the same, lookup PASS):

- The fit's own cells, kept: a byte a cell in blocks of a tile by 12
  courses (~18 MB at most, least recently used out), so neighbouring tiles'
  jobs stop sampling the same cells again.
- Missing cells made straight from the generator (a column's biome once,
  a material a course), only the slice asked for: not a whole sample with
  its drawing arrays, nor a deep section's flood fill. Checked equal to the
  kept tiles and sections (region_fit_probe: 0 of ~1.1 M cells differ).
- Jobs split by bands of 4 layers (a tile's surface and its caves far under
  it no longer share one box); the course under counted from a seam map in
  the wide pass and the fill.

| 49 tiles baked in streaming order (headless) | a tile |
|---|---|
| old pattern | 38 ms |
| fit, before | 128 ms |
| fit, now | ~75 ms |

`--gate=flight --fitted`: worst frame 61 ms, 1 over 33 ms, 0 holes, 15.1 s
(before: 659 ms, 23, 18 s; old pattern 38 ms, 1). `mine_world_probe
--fitted`: a cold 2 x 2 at the mountain spot 129 ms (allowed 120), 96 at the
other. The rest of a cold tile is mostly its neighbours' noise (a region's
fit reads ~1.5 tiles round). The switch stays off until that check passes.

### 12.3 The top course from the fit (built 2026-11-26)

With the fit on, the packer cuts the surface's top course from the fit too
(`brick::fit_top`, `pack_tile`): a column's top cell takes the brick of a
one-course region fit of its square among the columns of its GENERATED
class (generated top plate, material, colour; `brick::generated_top`, kept
by tile), by the material's group (sand and gravel 1x1, grass and dirt 8
cells at most). A fitted top brick is kept while every cell of it is as
generated and free (not smooth, a ramp's or slope's, placed); a column an
edit changed, or the rest of a brick it cut, takes the old pattern among
the cells no whole fitted brick holds -- so a hole re-lays only the bricks
it touches (`mine_world_probe`: every other brick laid as before). Placed
blocks first, as always. Studs: the old rule (a brick whose old 4 x 2 cut
reaches under a higher column is studded), so the surface stays a mix.

Checks with `--fitted`: bricks, audit, collapse PASS; `mine_world_probe`
all but the cold bake (136 ms, 120 allowed); `--gate=bricks` PASS.
`terrain_bricks_probe` now counts a surface piece under a laid plate apart
(a listed brick of the same footprint on it): with the plates off there
are none without a face, so all of them were that harmless case; the fit
has more top pieces, so more of them (60 a tile, the old 28).

Open (the user, 2026-11-26): should building materials be left out of the
"a group of 500+ cells floats" rule (stage D) so an undermined building
still tips? Left open; building cells reach the collapse as placed blocks.

### 12.4 Stage D in the collapse (2026-11-26)

- **Big groups float** (the user, section 11), with the fit on: a group the
  survey lets go of `float_cells` cells or more (preset `bricks.float_cells`,
  500; menu Bricks tab) stays where it is; the survey reports `floated`.
  Groups holding a building material still fall (open question, 12.3).
  `terrain_collapse_probe --fitted`: a ~640-cell stone arm floats, the
  180-cell long arm falls.
- **A tall brick as one body: built, OFF** (`TALL_BODIES` in
  terrain_collapse.cpp). On, the survey makes a fitted tall brick one solver
  body (archetype `h` courses tall; its groups still listed a course an
  entry, so ground_collapse.gd is unchanged), but `terrain_collapse_probe`'s
  "weak studs" (stud strength 0.001) then lets two ground bricks beside the
  pillar go with the arm -- every body was placed, so the solver's stress
  walk treats the tall body differently; not yet understood. Off, a tall
  brick is a body a course, as before.

### 12.5 Shares, the store, the top course deferred (2026-11-26)

**Shares closer to what is set.** By count, rough ground leaves room for a
1x2 where a 2x2 will not fit: the fill landed 2x2 at 13 % (20 asked), 1x2 at
33 (25). Raising aim did not move it; raising 2x2's own share did (0.35 ->
21 %), with floors near 25 % for 1x2 and 14 % for 1x1 that no share pushes
lower. So:
- a pair merge after the fill: two like bricks side by side become the
  listed shape they make (1x2 + 1x2 a 2x2, 2x2 + 2x2 a 2x4) where that shape
  is further under its share than the pair's (`pair_merge`, on);
- the shares CALIBRATED once a world (`calibrate`, on): a fixed sample of
  its ground (5 x 5 tiles near the origin, the first with enough bricks)
  fitted three times, each share scaled by (target / got)^0.8. The same
  bricks every session. ~0.4 s once at world set-up.

region_fit_probe, the shipped settings: every shape within 5 points (2x4
16, 2x2 21, 1x2 28, 1x1 14); not calibrated, 2 off.

**The packs no longer kept.** `PackStore` kept each tile's packed top course
(~14 KB a tile, 9.9 MB at 704). Now a tile is packed when baked (as it was
the first time anyway) and only its `TileTops` is kept: each column's top
plate and top brick (~6 KB). The survey (`top_columns`), rain (`rain_top`)
and the pickaxe (`find_brick`, `find_bricks`: sample plus the kept tops)
read that. Fit off, all probes pass; the old bake is 14-18 ms as before.

**The top course from the fit deferred** (the user): behind its own switch
`fit_top` (preset `bricks.fit_top`, off): with the fit on, the ground is
fitted and the surface's top course is the old pattern until performance
is good.

### 12.6 Where it stands (2026-11-26, measured)

Windowed, one run at a time, editor closed, nothing else running:

| gate | fit off | fit on (ground; tops deferred) |
|---|---|---|
| `--gate=bricks` | PASS | PASS |
| `--gate=breaklag --burst` (trigger to hole) | mean 34, worst 40 ms | mean 33, worst 36 ms (46 before the prefetch fix) |
| `--gate=flight` | worst 38 ms, 1 over 33; 192 tiles in after 120 frames | worst 27 ms, 0 over 33; 102 tiles in |
| `--gate=deep` (into a cave) | loaded in 200 frames, worst 24 ms | 383 frames, worst 23 ms |
| headless probes (bricks, audit, collapse, mine_world, fluid) | all PASS | all PASS but mine_world's cold bake (134-144 ms, 120 allowed) |

Frames are smooth with the fit on; what it costs is the workers' time: new
ground fills in about half as fast (the fit reads ~1.5 tiles round each
region). That, and the cold-bake check, keep the switch off.

`--gate=gpu` (fit off; 1280x720 at render scale 0.75, flat out): on foot,
frame 8.3 ms, GPU 7.6: water 3.0 (the sea 2.0), near tiles 1.2, near trees
1.1, far tier 1.0, sun shadows 0.6, behind faces 0.5. Up high: GPU 5.6, water
2.0, far tier 1.3. Standing in a deep cave the readout gave the world's
scripts 3.9 ms of a 17.5 ms frame: the rest is drawing at the window's real
size and the vsync. The game is GPU-bound at full resolution, the water the
largest single part.
