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

## 8. Built and measured

(filled in as each stage lands)
