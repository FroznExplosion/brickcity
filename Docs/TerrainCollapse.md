# Terrain collapse -- the buildings' stress rules on the mine world's ground

Written 2026-11-17. Branch `terrain-collapse` (worktree `C:\Users\lbaun\bc-tcollapse`).
Scene: `scenes/terrain_test.tscn` (the mine world, Docs/MineWorld.md).

## 0. What the user asked for

- The building destruction system's stress rules on the terrain: ground that
  loses what holds it falls, an undercut overhang comes down where its joints
  cannot carry it.
- **Sand and gravel have no strength.** They fall like Minecraft's and stand
  only on what is directly under them: stacked, never hanging.
- **Ground the generator made is left alone until an edit touches it.**
- **Broken-off pieces stay** (to change later). A settled piece whose tile is
  not in the near-detail tier (LOD 0) is **unloaded**: kept as a record where it
  lies, laid again when its tile is near-detail again. Pieces are **saved with
  the world** and come back on load.

## 1. What comes across from the buildings, and what does not

The buildings run several rules (Docs/HandoffDestructionNext.md, city_scene):

| Rule | Comes to terrain? | Why |
|---|---|---|
| Stud joints, grounding (`solve_grounded`, `find_detached_groups`) | **yes** | the whole idea: nothing falls while something joins it to the ground |
| Stress solve, tension only (`solve_stress`, the cascade in `solve_structure`) | **yes** | an overhang hangs from its joints; compression is free |
| Stud strength (`BrickStrength.tension()`, the Options setting) | **yes** | the same number buildings use, so one setting tunes both |
| Landing breaks, settling (`PlanetPieces`) | **yes** | the planet's falling pieces, whose up is any direction: flat here |
| Storey TIP/CRUSH (`gravity_check`, `CRUSH_PER_STUD`) | no | storey lines from a recipe; tuned against towers |
| Region crush (`_region_fail`) | no | the same, per region of a storey |
| Span rule (`cut_spans`, `span_reach`) | no | a floor's reach between columns; a cave roof is not a floor |
| Storey give-way (`_give_way`) | no | storeys again |
| `CollapseDirector` clustering | no | big buildings' groups merged into 1500-4000 brick chunks |

The last five are where big city's very large pieces come from (whole storeys
cut and released together); none of them is a brick rule, and none is used here.

## 2. Virtual bricks

Below its top course the ground has no bricks: it is plate cells, a material
each (BrickTerrain's field plus its sparse edits). There are no joints to
stress. So a survey packs the cells it looks at into **virtual bricks**, a
fixed bond worked out from absolute coordinates (stateless, like the surface
packer), and never stored or drawn:

- A **cell** of the survey is a stud by a brick (3 plates); solid if any of its
  plates is, of the material of its lowest solid plate.
- **Strong** (stone, deepslate, ores, granite, diorite, sandstone,
  terracottas, obsidian, ice, bedrock): 2x4 bricks, the long side along X on
  even courses and along Z on odd ones, shifted 2 studs every other pair of
  courses -- a cross bond: every brick sits on several.
- **Medium** (dirt, grass and its colours, podzol, snow, clay): 2x2, shifted
  one stud in X and Z on odd courses: each sits on four by a stud each.
- **Loose** (sand, red sand, gravel): 1x1 -- joined only up and down.
- A footprint is one material; where it is not, or not all solid, it falls back
  to halves (2x2, then 1x2, then 1x1).

Strength by material is therefore the bond, not a new number: a stone ledge
hangs by 2x4 laps, a dirt one by single studs. The joint strength itself is the
buildings' `BrickStrength.tension()`.

## 3. A survey

After every edit (a shot, a block broken or placed, cells cleared by a fall,
sand landing) the box it changed is surveyed. Edits are gathered for 0.1 s,
as the tile refresh does; one survey is on a worker at a time.

`TerrainCollapse.survey(lo, hi, tension, mass_per_cell)` (C++, a worker):

1. **Region**: the edit box grown `REACH` studs round (10), from 4 bricks
   under it to 20 over it, plus a one-stud **ring** round that. Sampled once,
   column by column (the generator's column is worked out once a column, not
   once a cell).
2. **Sand and gravel**, in the edit's columns and one stud round: a loose cell
   with air under it falls, with every loose cell stacked on it. Each such run
   is a **falling column** (cells, materials). They are taken out of the region
   before step 4.
3. **Is there anything to solve?** Only if some solid cell near the edit (5
   studs round, the region's height) has air under it. Ground under a shot that
   stands on ground stops here: almost every shot.
4. **The solve**: the region's virtual bricks go into a private `BrickWorld`
   made for the survey on the worker (nothing shared with the scene's), the
   ring's columns filled with pillar bricks to the bottom (the region's edge is
   held by the ground past it), the bottom course the foundation. Then the
   buildings' own `solve_structure` (stress cascade, then grounding). Every
   loose group that holds no ring brick comes back: its bricks, absolute.

Generated ground is only ever looked at inside a region round an edit: that is
"left alone until edited". A natural overhang next to a shot is in the region,
so it is asked -- and it may come down: it was edited.

## 4. What the main thread does with the answer

- **A falling column**: its cells cleared (`clear_runs`), drawn as boxes
  (one MultiMesh for all of them) falling straight down with gravity; where the
  cell under its bottom is solid it lands and its cells are written back
  (`fill_box`, only into air), on any plate. Landing is an edit, so what it
  lands on is surveyed too. It does not see pieces (it falls through them).
- **A loose group**: its cells cleared, its bricks laid into a chunk of the
  scene's `BrickWorld` (palette parts `brick_2x4_x` ...) and handed to
  `PlanetPieces.adopt` as a piece: it falls, breaks where it lands hard
  (PlanetPieces' landing rule), settles and freezes. The cells cleared are an
  edit: the cut is surveyed next, so a cascade goes on a survey at a time.
- **Shots on a piece** chip it (`PlanetPieces.damage`).

## 5. Pieces kept, unloaded, saved

- `PlanetPieces` caps pieces (MAX_PIECES 160, the oldest unseen shrinks away)
  and turns small groups into crumbs. The mine world sets `max_pieces` and
  `debris_max` so neither happens: every piece stays.
- Every half second, a **settled** piece whose tile (the centre of its box) is
  not a tile of the streamer (`TerrainStreamer.has_tile`, the near-detail tier)
  is unloaded: its bricks recorded (`ChunkRecord`) with where it lies, its body
  and chunk freed. When the tile is near-detail again it is laid again, settled.
  A moving piece is never unloaded.
- **A cap, nearest the player first** (2026-11-19, the user): at most
  `MAX_LOADED` (100) pieces laid. Past it the farthest settled ones are put
  away; a put-away piece nearer than a laid one by `SWAP_MARGIN` (8 m) takes
  its place, `RELOAD_PER_TEND` (12) a tend at most.
- **Put away = unloaded or deleted by size**: a piece of more than
  `SMALL_MAX` (3) bricks becomes a record (kept, saved, laid again); 3 bricks
  or fewer is deleted -- at once when its tile is not drawn, shrunk away
  (PlanetPieces' fade) when it is over the cap and may be in view. A piece
  whose mesh is still being made waits a tend.
- Saved in a file of its own beside the edits: `<seed>_<hash>.pieces`
  (zstd, header `BCMP`, format 1, then `var_to_bytes` of the records), written
  when the edits are; loaded after them, as dormant records, laid as their
  tiles come near.

## 6. Cost (guessed 2026-11-17, measured in section 8)

| Case | Where | Guess |
|---|---|---|
| no edits | -- | nothing runs |
| a shot, ground held (step 3 stops) | worker | ~1-3 ms of sampling |
| a shot under an overhang | worker | sampling + 1-5k virtual bricks + solve, ~5-20 ms |
| a piece let go | main | laying its bricks ~1 ms a 1000, one body; mesh baked on a worker |
| falling sand | main | one MultiMesh, a solid_at a column a frame |
| settled pieces | GPU | one mesh each, ~1-3 ms per 100 near ones; unloaded past LOD 0 |

Known risk: `BrickTerrain`'s edit map has no lock; the survey reads it on a
worker as `find_brick` already does while the main thread writes. It is
reserved large up front so it does not rehash under a reader.

## 7. Stages

1. Doc (this).
2. C++ `TerrainCollapse.survey`: region sampling, sand columns, virtual bricks,
   private-world solve. Probe `terrain_collapse_probe` (headless).
3. Falling sand and gravel in the mine world.
4. Loose groups as pieces; shots on pieces.
5. Kept pieces: unload past LOD 0, reload, save/load.
6. Gate `terrain_test.tscn -- --gate=collapse`; costs measured into section 8.

## 8. Built and measured (2026-11-17)

All stages built. Files: `gdextension/brick/src/terrain_collapse.{h,cpp}`
(the survey), `scripts/terrain/ground_collapse.gd` (the mine world's side:
sand, pieces, unload, save), hooks in `mine_world.gd` (`terrain_edited` ->
`collapse.queue`, `_mine` -> `collapse.shoot`, `tiles_fresh`, `near_tile`,
the `.pieces` file), `TerrainStreamer.fresh`, and `PlanetPieces.max_pieces` /
`debris_max` (defaults unchanged for the planet).

What changed from the plan while building:

- **Superseded 2026-11-20 (Docs/TerrainBond.md):** the virtual bricks are
  the ground's bond again -- fixed from absolute coordinates, but every seam
  of a course on studs of its parity and the next course's on the other, so
  no seam stands over a seam whatever the shape -- the same bricks the tiles
  draw and a shot breaks; the top course is the tiles' own pieces. The found
  bond below was a different brick each survey and drawn nowhere.
- **The bond is found, not fixed.** A fixed pattern from absolute coordinates
  left seam over seam wherever a shape did not line up with it (a 2-course
  arm came apart in two). Now each course is packed from the bottom, each
  cell's brick the largest that fits, placed where it laps the most bricks
  under it and never with an edge right over a seam below. Rock may use 2x4s,
  dirt up to 2x2, sand 1x1.
- **Bricks bond across a material border** (a dirt ledge on rock is joined
  to it), never with sand; a 2x4 only through rock. Strength by material is
  still only the bond.
- **One course alone joins nothing** (bricks side by side): a one-brick-thick
  ledge or bridge with nothing under it falls. A placed block packs whole
  (the scan meets its corner first), so a lone 2x2 is one brick.
- **Pieces wait for their tile**: the cells are cleared at once, the piece's
  mesh is made on workers, and it is let go when the tiles over it are
  rebuilt (`tiles_fresh`), at most 2 s: the old tile and the piece never draw
  together and the body never starts inside the old tile's collision.
- **Piece chunks are zero-origin grids placed by their transform**, as
  `split_island` makes them: `piece_at` and the landing rule read the grid in
  the chunk's own frame.

Measured (`terrain_collapse_probe`, headless; `terrain_test.tscn --
--gate=collapse`, windowed, editor open, other chats idle):

| | |
|---|---|
| survey, flat ground shot (no solve) | 0.7 ms, worker |
| survey, an arm on a pillar (~850 virtual bricks, solved) | 2.1-2.4 ms, worker (sample 1.4-1.8, solve 0.5) |
| survey worst in the gate | 1.9-7.5 ms, worker |
| applying a survey (clear cells, lay a piece's bricks) | 0.7-1.5 ms worst, main |
| frames while blocks and an arm fell (FrameClock, read-backs left out) | 187 frames, **0 over 33 ms**, mean 16.8 ms |
| default `--gate` edits / rapid fire | 24.1 / 24.5 ms worst, 16.7 / 16.6 mean: as before (section 9 of MineWorld.md) |
| stud strength a 10-stud, 2-course arm needs | rock 2.1, dirt 5.7 (the game's is 37.2: both hold) |

### 8.1 2026-11-19: what play showed

The user: broken bricks fell and lay forever, could not be broken, and drew
with smooth tops; islands came off a brick at a time, never in big chunks.

- **Big islands fall whole.** A survey's region was the edit +-10 studs, and
  everything reaching its side was held by the ring -- so an island wider
  than that never came loose; only the bricks round a shot did. Now, before
  the solve, a walk from the region's own bottom course (not the ring's
  pillars) finds ground with no way down inside the region; if any reaches
  the side, the region grows 16 studs round (3 times at most) and is asked
  again. Probe: a 40-stud arm falls as one group of 180 cells (28 ms,
  12k virtual bricks, on a worker).
- **Pieces are breakable.** `PlanetPieces.piece_at` passed `block_at` a cell
  relative to the grid's origin where it takes an absolute cell: a piece split
  off another keeps the parent's grid and its own origin, so a round on any
  split piece found nothing, forever. It also took cut-out (dead) cells as
  the piece's: new `BrickWorld.is_block_alive`. The planet's pieces had the
  same bug. And a round wore the point 5 cm in -- the empty stud layer of a
  top face; now 10 cm, where it found the brick.
- **Build mode mines pieces**: the builder rays pieces (DEBRIS, FALLING)
  before the ground; the brick looked at is outlined and taken whole.
- **Studs on pieces** (`PlanetPieces.studs`): each piece draws its open studs
  (`get_chunk_studs`, a CPU query). Their first draw cost a 260 ms frame
  (the pipeline), so one stud is drawn tiny in front of the camera for four
  frames when the world starts.
- **Landing chips are crumbs**: 3 bricks or fewer knocked off by a landing
  fly and shrink away (`debris_max = SMALL_MAX`), not lie forever.
- **Surveys per box** (the water chat saw `--gate=gen --with-collapse`
  crash with a 120 m shaft): edits were one bounding box per 0.1 s, so a shaft
  (or two edits far apart) made a region hundreds of bricks tall. Now each
  edit box is queued, merged only with boxes within 6 cells, up to 32 x 96 x
  32 (studs, plates, studs); a bigger one is split. The survey stops growing
  at 1.2 M cells or 120k virtual bricks (what reaches past is held).
  2026-11-21: 5 runs of `--gate=gen --with-collapse` in a row, no crash
  (it was about 1 run in 2 before this).

### 8.4 2026-11-22: the drawn tiles' bricks are the survey's

The ground is not stored like Minecraft's chunks: it is the generator plus
the edit table, and every reader worked its bricks out again (the drawing,
the pickaxe, the brick lookup and the survey each sampled and packed the
tile). Now one store keeps each tile's packed top course by tile version
(`brick::packed_tile`, brick_terrain.cpp): the drawing fills it as it bakes
a tile, and the others read the same pieces.

- `TilePack`: the pieces, each column's owning piece, and each column's top
  plate. `packed_tile` samples (the drawing and the pickaxe need the whole
  sample) and packs only on a miss; `packed_tops` (the survey) does not
  even sample on a hit. Most recently used 768 tiles kept.
  `BrickTerrain.get_tile_pack_stats()`; the F3 ground line shows it.
- **Sampling was the cost, not packing**: with the pieces kept but the
  tile still sampled, a survey on drawn ground was 35 ms (tops 34). Without
  the sample: **1.4 ms**. The old "packing was 97%" was both together.
- The survey's own cache (`SharedTops`, `TOPS_MAX`) is gone: the store does
  its job. The probe's "survey again" check stays (nothing changed: no tile
  packed); new check: a survey on drawn ground packs no tile.
- `set_edit` bumps the tile version after its write too, so a reader that
  sampled before the write cannot keep it under the new version.
- **What is left**: the tiles the edit itself changed (the edit bumps the
  tiles within one of it). The survey starts before the redraw, so it
  samples them (`--gate=collapse`: worst survey 25.6 ms, 3 tiles, on a
  worker; it was 33.9 before the store). Waiting for the redraw's pack was
  tried: the redraw never started first (0 waits), so it went. Ground nobody
  has drawn (the probe's 40 cave ceilings, headless) costs as before: 42 ms
  mean, 195 worst.

### 8.3 2026-11-21: walking in a cave

`--gate=stop --walk --cave` starts the walk in a cave room 4-28 m under the
ground with a way out at least 60 studs long, and steers along its floor
(steps of 0.8 m at most, up or down; wall following when blocked). It prints
how far it got, its turns and dead ends, and its own cost apart (0.14 ms).

Quiet machine, editor closed, 78 C peak, not held back; 16 m under the
ground, 25 m walked in 15 s: one frame over 33 ms (35 ms: process 8, draw
26), GPU median 11.3 ms, near tier worst 11.7 ms once (instances; 1.1-1.4 in
the other runs), deep tier 82 sections built, 34 dropped, worst 1.6 ms. Still
after stopping: 16.6 ms mean. Nothing of the ground collapse's shows: it runs
only on an edit.

### 8.2 2026-11-20: cost, and cave ceilings

After the ground's bond (Docs/TerrainBond.md) the survey read the top course
from the tiles' own pieces, packing each tile it covered: 97% of a survey
(29 of 31 ms for an arm, 137 of 155 for a long one; 2.5 s seen in play), and
cave ceilings came down whole from one shot.

- **Top course cached across surveys** by `brick::tile_version` (a lock-free
  counter per tile, bumped by an edit or placement in or next to it, and for
  all tiles when the world is set up again). The same survey again: 1.3 ms.
  The real fix is ground bricks kept per section (another chat's plan): the
  survey would read each cell's brick from them and pack nothing.
- **Growing the region is asked of cells** (a face-to-face flood from the
  region's bottom) before any brick is laid, so a grown region lays and
  solves its bricks once, at its final size.
- **Only what touches the edit falls**: a group with no brick within a stud
  and a course of the edit box was loose before it (the generator leaves bits
  floating) and stays.
- **Ground is 4x the buildings' stud strength** (`TERRAIN_TIMES`): a real
  ceiling at 1x dropped 4,030 cells in 164 groups from one shot. Probe, 40
  generated cave ceilings shot: the most that comes down is 8 loose cells;
  survey 39 ms mean, 185 worst, on a worker, cold cache.

Not done / known:

- **Sand lands on pieces** (2026-11-19): a falling column casts down along its
  middle each frame (DEBRIS and FALLING layers); meeting a piece it becomes a
  piece of its own (1x1 bricks, drawn by the boxes it fell as) and drops onto
  it. A column whose middle misses a piece lands on the ground as before.
- A survey's region is the edit +-10 studs, 4 bricks under, 20 over (grown
  twice by 24 when a loose group reaches the top). A mass reaching past that
  counts as held.
- Settled pieces draw one mesh each; unloaded past LOD 0. The long-term cost
  of keeping them is the user's "change later".
