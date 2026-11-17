# Water and lava in the mine world — plan

Status: **plan, not built** (2026-11-17). For `scenes/terrain_test.tscn`, the mine world
([MineWorld.md](MineWorld.md)). It takes [Water.md](Water.md) §12's idea (brick water that
flows) and settles its model for a volumetric, endless, Minecraft-like world. The heightfield
test's sea ([Water.md](Water.md) §1–9) is kept and reused for the ocean's waves.

## 0. What is asked

| # | Requirement |
|---|---|
| R1 | Water takes brick space: it lives on the brick grid, as bricks do. |
| R2 | Flowing water has levels and thins down to tile height (one plate). |
| R3 | Water above a brick or a tile flows over it; water lower than it does not. |
| R4 | **Source brick**: never dries; what flows from it reaches a set distance, thins to tile height and stops (Minecraft). For seas, lakes, rivers. |
| R5 | **Water brick**: a real volume. Flows out and thins; once it would be under one tile deep it stops spreading and dries up. For ponds, cave pools, spills. |
| R6 | Sea sources can have the heightfield test's waves. |
| R7 | Any other brick can be placed into a source's space; the source is removed. |
| R8 | Buckets: a bucket holds 3 bricks = 9 tiles of water. Picking up a source brick needs a special bucket. |
| R9 | Fast, with a LOD that looks right at a distance (a heightfield out there is fine). |
| R10 | The same system carries lava (and any later fluid). |

## 1. The one big decision: water is a layer on the terrain grid, not a terrain material

Water is **not** a terrain material. A terrain tile bakes in 9–14 ms (MineWorld.md 2), and
moving water changes cells ten times a second; rebaking ground for that is impossible. Water
gets its own sparse grid (`BrickFluid`, new C++ beside `brick_terrain.cpp`) with its own small
mesher. The terrain sees water as air (it draws the lake bed as it does now), and the water
reads the terrain as solid or open.

## 2. Cells and units

**A water cell is 1 stud x 1 brick** (0.35 x 0.42 x 0.35 m), on the brick courses. Inside the
cell the water has a **level in plates: 1, 2 or 3**. One plate of water is a **tile** of water.

```
   side view, one cell              level 3 = a full brick of water
   +-----------+  plate 3           level 2 = a plate-and-tile
   |~~~~~~~~~~~|  plate 2           level 1 = a tile (the thinnest water there is)
   |~~~~~~~~~~~|  plate 1
   +===========+  ground
```

Why this size, not another:

| Cell | Against it |
|---|---|
| **1 stud x 1 brick** (chosen) | — . The ground is per stud (coasts, craters, 1x1 blocks the builder places), and the level in plates is exactly "brick down to tile". |
| 2x2 studs x 1 brick (a builder block) | a 1x1 block or a crater edge splits a cell: water leaks through 1-stud walls or stands inside rock. 4x fewer cells, but the active set (section 6) makes the cell count matter far less than it seems. |
| 1 stud x 1 plate | 3x the cells, and a level is then a stack of cells, so "flow distance thins the water" needs three cells to agree. |

The terrain inside a cell can be partly solid (a crater floor, a tile laid on the ground): the
cell keeps a **solid mask of 3 bits**, one a plate, read from the field. Water stands on the top
solid plate in the cell; a cell's room is the open plates.

**Volumes the player sees** (decided 2026-11-17): a *brick of water* is one **1x1 brick** —
one cell, full; a *tile of water* is 1x1 x 1 plate. A bucket holds **9 tiles = 3 bricks** (R8).
Later the water may be drawn as a mixed set of pieces (2x2s, 1x4s ...) packed over the cells,
the way the ground is packed; the cells stay 1x1.

**Same lattice, own layer.** The water grid IS the terrain's grid: the same stud columns, its
cells are three of the terrain's plate cells stacked (a brick course). Every water cell knows
exactly which terrain plates it covers, so the two meet cell for cell. What is separate is only
the **storage and the mesh**: water is a layer over the terrain grid, not a material inside the
terrain's voxels, so a moving stream re-meshes its own small water mesh, never the ground's.

**A cell is 16 bits**, plus the 3-bit solid mask:

| bits | field |
|---|---|
| 2 | fluid: none, water, lava, (spare) |
| 2 | kind: source, flowing, falling, still |
| 2 | level, plates 0–3 |
| 5 | distance from the source (flowing), 0–31 |
| 1 | ocean: drawn with waves (sea sources) |
| 4 | timer (drying, slow fluids) |

## 3. Four kinds of water

| Kind | What it is | Volume |
|---|---|---|
| **source** | a source brick: level 3, never changes by itself. The sea, lakes, rivers, springs; a source bucket places one. | infinite |
| **flowing** | fed by a source `distance` cells away; its level comes from that distance, not from a volume (Minecraft). | infinite while fed |
| **falling** | flowing water dropping down an open column (a waterfall); resets the distance where it lands on a brick drop. | infinite while fed |
| **still** | a water brick's water: a whole number of tiles that moves and is never made or lost except by drying. | finite |

## 4. The rules, per tick

All water ticks at **10 Hz**; lava every 5th tick (2 Hz). One rule set, a table of numbers per
fluid (section 4.6).

### 4.1 Fed water (sources, flowing, falling) — Minecraft's rules on the brick grid

1. **Down first.** If the cell under the water is open, the water goes down as falling water,
   one cell a tick (0.42 m a tick = 4.2 m/s, Minecraft's ~4 m/s).
2. **Then sideways**, into a neighbour whose floor is **below this water's top** (R3): a tile
   or a two-plate step is flowed over by deeper water; a full brick step is not. The neighbour
   gets `distance + 1`.
3. **Level by distance** (R2, R4), water's defaults:

   | distance | level |
   |---|---|
   | 0 (source) | 3 plates — a brick |
   | 1–7 | 2 plates |
   | 8–14 | 1 plate — a tile |
   | 15 | nothing: the flow stops |

   Reach 14 studs = 4.9 m, Minecraft's 7 blocks at two studs a block. A drop of a full brick
   or more resets the distance (it is a fall), so water runs on down a hillside as it does in
   Minecraft; a drop of one or two plates does not.
4. **Never higher than what feeds it.** The new top is the lower of (the neighbour's floor +
   the level) and the feeding water's top. A tile-deep sheet reaching a tile step therefore
   stops: it would have to stand above its own feed.
5. **Toward the drop.** Like Minecraft, flowing water spreads only toward the nearest place it
   can fall, if one is within 8 studs; otherwise every way. This one rule is most of what makes
   water look like it is finding its way downhill.
6. **Losing the feed.** Flowing water whose feed is gone (the source was filled in, scooped up,
   or cut off) does not vanish as in Minecraft: it **becomes still water** at its current
   level. Then section 4.2 runs it downhill into the hollows, and the thin parts dry. Cut off a
   stream and its bed drains, leaving puddles that dry — it feels like water, not like a
   texture switching off.
7. **New sources** (Minecraft's infinite-water rule, on for water, off for lava): a flowing
   cell with two or more source neighbours beside it and a source or ground under it becomes a
   source. A hole dug at the edge of a lake fills to the lake and stays full; a lake cannot be
   emptied by bucket, only walled off and filled in.

### 4.2 Still water (water bricks) — a volume

Tiles are whole and are conserved exactly; nothing is ever a fraction of a tile.

1. **Down**: as much as the cell below has room for.
2. **Sideways**: one tile to a neighbour whose water top (or floor, if dry) is **two or more
   plates lower** at a place the water can pass (R3). A difference of one plate does not move.
   That is R5 for free: water that is one tile deep on flat ground has nothing to give, so it
   stops spreading.
3. **Drying** (R5): a cell holding one tile, on ground, whose wet neighbours are also only a
   tile deep, has been still for 15–45 s (hashed per cell, so a spill dries from its edges in
   patches, not all at once) — the tile is gone. Deeper ponds never dry; their thin edges are
   next to deeper water, so they do not either.
4. **Into fed water**: still water that reaches a source or flowing water joins it (the river
   or the sea takes it; the tiles are gone into the infinite body).
5. Fed water spreading over still water whose top is lower takes those cells over: a river
   running into a pond keeps the pond topped up. Cut the river and those cells become still
   water again (4.1.6), so the pond stays a pond.

Gather form (STA's rule, [Reference/sta.md](Reference/sta.md)): each cell works out only its own
next state from the last tick's states, so a tick is the same whatever order cells are visited
in, can be split over threads later, and runs the same on every peer.

If a still pond's last tiles leave one-plate steps on its top that look wrong, a **levelling
pass** on a body that has been calm for a second spreads them flat (count its tiles, fill from
the lowest floor up). Probably not needed: a part-laid top course is a LEGO look anyway.

### 4.3 When the ground changes

* **A block placed into water** (R7): source or flowing cells there are simply removed (the
  feed rules re-run round them). Still water there is **deleted**, as in Minecraft (decided
  2026-11-17).
* **A block broken, a shot, a crater** next to water: the cells round the change are woken. A
  crater in a lake bed fills; a crater next to a river takes a stream.
* The terrain edit is passed to the water as a box and the new materials (`fill_box`, `carve`
  already return what changed); the water updates its solid masks from that, so its worker
  never reads the edit map while the main thread is writing it.

### 4.4 Sea waves (R6)

A source carries an **ocean** bit. The generated sea's sources have it; a source the player
places does not. Ocean water is drawn by the heightfield test's wave tiers (section 7.2) — the
studded pieces bobbing on `BrickWave` — and everything else is calm. Nothing in the rules
depends on the bit: a wave is drawing, the sea's level for the rules is its still level.

### 4.5 What it does NOT do (on purpose, at first)

* **Pressure.** Water does not rise up the far side of a U-bend. Minecraft does not either;
  STA's compression term could add it later.
* **A pit filling from a river.** Fed water that falls into a closed pit covers its floor and
  stays a thin flowing sheet there — Minecraft's behaviour. Filling it to the river's level is
  stage 8: a fed body whose every edge is walled (no cell stopped by reach, no drop) turns its
  bottom course into still water and rises a course at a time.

### 4.6 Lava, and other fluids (R10)

The rules are the same; the numbers are a table per fluid:

| | water | lava |
|---|---|---|
| tick | 10 Hz | 2 Hz (every 5th) |
| reach | 14 studs, levels 2 then 1 | 6 studs, levels 2 then 1 |
| new sources (4.1.7) | yes | no |
| still kind dries | yes | no (cools into stone instead, optional) |
| looks | calm blue, flow scroll | glowing, slow crust scroll, emissive |
| touches the other | — | lava source + water: **obsidian**; flowing lava + water: **stone** (terrain edits, new materials appended to `Material`) |
| to a body in it | swim | burn and damage |

## 5. Where the water lives

**Generated water is a function, like the ground** (MineWorld.md 2; the "recipe plus
differences" rule of the terrain's edits). The sea, rivers and later lakes are worked out from
the seed when asked; nothing stores them. A world nobody has disturbed stores no water at all.

* `gen_fluid(x, course, z)`: a column whose generated top is under the sea course is sea from
  its floor up to the sea course — source, ocean. Rivers are already cut to just under the sea
  line, so they fill to it.
* **Sections** hold everything else: 32 x 32 studs (one terrain tile) x 16 bricks (6.7 m) =
  16,384 cells, 48 KB with the solid masks. A section is made **only** when water in it is
  changed or starts moving; it is filled from `gen_fluid` and the field on a worker when made.
  Saved as the difference from `gen_fluid`.

## 6. When it runs

* **Only what changed runs** (Minecraft's scheduled ticks, STA's active set). A cell that changed
  wakes itself and its six neighbours for the next tick; nothing else is visited. **A still
  world — a calm sea, a full lake, a settled pond — costs nothing.** That is why tiles are whole
  numbers: a volume in fractions creeps by tiny amounts for minutes and keeps cells awake, a
  volume in whole tiles stops exactly.
* **On a worker.** Each tick is one job: work out the changes from the last state, apply them
  (a short lock), mesh the tiles they dirtied (Godot arrays made on the worker, WhereWorkRuns.md
  1). The main thread starts a tick when the last one is done (`is_task_completed`, never a
  wait), hands in commands (edits, buckets, placed water) and swaps in finished meshes.
* **Queries** (swim, bucket aim, the HUD) read the last applied state under a shared lock; only
  the apply step holds it.
* **Budget:** at most 64k cell updates a tick, nearest the player first; past that the far
  ones wait a tick. A huge flood is slower water far away, never a slow frame.
* **Rings:** water ticks within the **sim ring** (the terrain's detail tiles plus two, ~90 m).
  Past it a section is **frozen**: its pending wakes are kept with it and run when someone comes
  back (Minecraft, STA, Enshrouded). A river frozen mid-flow resumes.

## 7. How it looks

### 7.1 Near: water meshes per terrain tile

One mesh per terrain tile that holds visible water, built on the worker after the tick that
changed it, at most 10 times a second a tile, coalesced like terrain edits (0.1 s).

* **Faces:** a top where nothing wet is above; a side where the neighbour's water is lower or
  absent (from its top to this cell's); a bottom over open air (a waterfall seen from under).
  Still and source tops are merged into big quads (a calm lake tile is a handful of triangles);
  flowing cells are a quad each and carry their flow direction.
* **Sloped tops, like Minecraft** (decided 2026-11-17): each top corner is the mean of the wet
  cells round it (STA §3), so a stream's surface slopes down from the source to its tile-deep
  end. Still water that is level stays flat. Stepped plate tops remain a dev switch.
* **Shader** (`shaders/water_fluid.gdshader`): opaque, colour by depth, as the sea does
  (Water.md 5) — the mesher knows each cell's depth, so no texture is read for it. Water a tile
  or two deep is **dithered** (alpha hash), so a thin stream shows the ground through it and
  there is nothing to sort. Ripples scroll along the flow direction; foam at steps and where a
  fall lands; a fall's faces scroll down. Optional painted studs on still tops (Water.md 4).
* **Nodes are recycled**, never made per rebuild: the stall a fresh instance node costs is what
  the terrain tiles just fixed by recycling theirs (9ee68bd0).
* **Underwater**: `underwater.gd`'s fog, asked of the fluid at the eye (water or lava colour).

### 7.2 The sea keeps the heightfield test's waves

The generated sea's top is **not** meshed. `WaterSea` (the studded pieces to 40 m, the smooth
sheet past that) draws it exactly as in heightfield_test (R6). Three changes:

* **Streamed shore field.** `build_shore_field` covers a fixed world today. It is rebuilt round
  the player on a worker each time the far rings re-anchor (MineWorld.md 3), the same window.
* **A per-stud mask from the water**, the job `BrickPools.sea_mask` does for pools: the waves are
  not drawn where the sea was walled off and emptied, and lie still where they meet calm water.
* The sheet reaches the view distance (~1 km), not 600 m.

The sea's still level is **snapped to a brick course**, so its top is a course of bricks like
everything else and the calm water beside it lines up with it.

## 8. The LOD

| Ring | Range | What draws | What runs |
|---|---|---|---|
| **W0 near** | the terrain's detail tiles (4–8 tiles) | water meshes per tile (7.1); sea by the studded wave tier | ticks |
| **W1 frozen** | to the sim ring, ~90 m | nothing new: the terrain's coarse blocks start here (below) | ticks to ~90 m, frozen past it |
| **W2 far** | to the view distance | **inland water baked into the coarse blocks**; the sea by the smooth sheet with fading waves | nothing |

**The far water is a heightfield, baked with the far ground.** `build_coarse` already samples
the ground's height every `step` studs for the blocky far rings; it also samples the **water top**
there (from `gen_fluid`, and from a per-tile summary of changed water: the highest water top per
4x4 studs) and emits a flat quad at it, flagged as water in the same surface. So:

* no extra draw call and no per-frame cost — it is part of the far block's mesh;
* the shores line up with the blocky far ground exactly, because it is the same lattice;
* a lake the player made, or a river they dammed, is visible from a mountain;
* lava is the same with an emissive flag: lava pools glow at night from far away;
* a far block is re-baked when its summary changes, on the path edits already use
  (`field_changed_soon`) — and water out there does not move (it is frozen).

**The seam is the terrain's own seam.** A tile's water mesh draws exactly when that terrain tile
is detailed, and the coarse blocks are hidden there (`TerrainCoarse.cover`). Near water and far
water hand over where near ground and far ground do, so there is no new seam to hide.

## 9. Generated water

* The mine world turns water **on**: the Dry Ocean basins and Dry River valleys fill to the sea
  course ("Dry Ocean" and "Dry River" can drop the "Dry").
* **Caves are sealed against the sea**: no cave air within 2 studs of a sea column below the sea
  course. Without it a cave mouth on the sea floor is a wall of water over air until something
  wakes it (Minecraft's old "water walls"). A rule in the cave test, per column, cached in the
  tile sampler.
* World generation menu (F9): a **Water** tab — water on/off, sea level (exists), wave height,
  flow reach; later lava level, lava pools, springs, cave pools, lakes.
* **Later** (stage 8): lakes above the sea in basins (the generator cuts the rim and fills under
  it), still cave pools (water bricks, R5: Minecraft's aquifers, with barriers between pools of
  different levels), springs on cliff faces (a source in the face), lava pools deep down.

## 10. The player

* **Swimming.** The pawn (FpsRig) does not swim today; only `DebugCamera` does (Water.md 7.2:
  wade, then swim at chest depth, steer by look, a spring to the surface). The pawn gets the same
  `water_probe`: the fluid's top above a point, or `BrickWave` over the sea. Flowing water pushes
  (0.5–1.5 m/s along its flow). Lava burns (the status system, Weapons and effects' area).
* **Bucket** (R8): holds 9 tiles (3 1x1 bricks). RMB pours a brick of still water at the placing
  spot the builder would use. LMB on still water scoops a brick (3 tiles) out of the pond. LMB on
  a **source** (all sea water is source bricks) **fills the bucket to 9 at once** and the source
  stays — it is infinite (decided 2026-11-17).
* **Source bucket** (R8): scoops one source brick (removed; with 4.1.7 a lake heals it at once,
  as in Minecraft) and pours it out as a source brick somewhere else — a spring. Lava buckets the
  same way.
* **Aim**: `BrickFluid.ray_cell` walks the grid to the first water or ground. The builder's own
  aim ignores water (it is terrain-only), so blocks are placed into water (R7).
* Hotbar entries for testing (water source, water, lava source) before the buckets exist.

## 11. Saving

Beside the terrain's edits: `user://saves/mine_world/<seed>_<hash>.fluid` — each section that
differs from `gen_fluid`, run-length coded, zstd, plus its pending wakes, so a river that was
flowing is still flowing after a load. Same cadence and worker write as the edits (MineWorld.md
9); keyed by seed and settings the same way.

## 12. What it costs (estimates — stage 1 and 5 measure them)

| | Where | Estimate |
|---|---|---|
| a still world | — | **0**: no active cells |
| a tick with 20k active cells | worker, 10 Hz | ~1 ms (50 ns a cell) = 1% of a core |
| the cap | worker | 64k cells a tick, ~3 ms |
| re-meshing one tile | worker | 0.2–0.6 ms |
| main thread | commands, mesh swaps, queries | under 0.3 ms a frame |
| near water drawn | GPU | calm water a few quads a tile; a flowing tile up to ~4k triangles |
| far inland water | GPU | inside the coarse blocks: no draw calls of its own |
| the sea | GPU | as measured in heightfield_test: 176k triangles (Water.md 9.11) |
| memory | — | 48 KB a section, only where water was changed |

## 13. Decided with the user (2026-11-17)

1. A brick of water is a **1x1 brick**; a bucket holds 3 of them = 9 tiles. A mixed set of
   water pieces packed over the cells may come later.
2. Flowing water has **sloped tops**, like Minecraft.
3. Water bricks **drain, then dry**. Source bricks and what they feed work like Minecraft; flowing
   water cut off from its source becomes still water and drains and dries (4.1.6).
4. A block placed into still water **deletes** it.
5. **No soaking**: ground never takes water; water only spreads, thins and dries.
6. All sea water is source bricks. A normal bucket on a source **fills to 9 in one action**,
   and the source is unchanged.
7. Water shares the terrain's grid (same stud columns, brick courses of its plates) as a layer of
   its own (section 2).

## 14. Build order

Each stage is merged on its own. C++ stages need the main folder's DLL rebuilt after merging
(editor closed).

1. **The rules in C++** (`gdextension/brick/src/brick_fluid.*`, class `BrickFluid`): sections,
   solid masks from the field, fed and still rules, falling, drying, new sources, scheduled
   wakes, a tick on a worker, commands, queries, `ray_cell`. Headless `tools/probes/fluid_probe.gd`:
   a source on flat ground reaches 14 studs and stops; levels 3, 2, 1; water flows over a tile and
   not over a brick; still water poured on flat ground keeps every tile and stops at one tile
   deep; a cut-off stream drains to its hollows and the thin parts dry; a hole by a lake fills;
   a still world has 0 active cells; cells a millisecond.
2. **Drawing it in the mine world**: per-tile meshes, the water shader, hotbar test entries.
   `-- --gate` pictures: a stream down a stepped hill, a waterfall, a pond, a stream drying.
3. **The sea on**: `gen_fluid`, the sea course, caves sealed, the wave tiers streamed with the
   shore field, the mask, the Water tab. Gate: coast, river mouth, a dug channel off the sea.
4. **The player**: swimming, underwater fog, flow push, both buckets, placing into water.
5. **LOD**: the sim ring and frozen sections, far water in the coarse blocks, the budget.
   Measured with the editor closed (CLAUDE.md).
6. **Lava**: the second fluid's table, its look and glow, burning, obsidian and stone.
7. **Saving** the water with the edits.
8. **Later**: pits filling from rivers (4.5), lakes above the sea, cave pools, springs, lava
   pools, floating debris, mixed water pieces, multiplayer diffs (STA §10.8–10.9).

## 15. Risks

* **Water walls** where generated water meets cave air: section 9's sealing rule. A probe looks
  for wet cells beside open air that are not awake in a freshly generated world.
* **A flood that never ends** (a sea let into a huge cave system): the budget makes it slow far
  away, the frozen ring stops it out of range. Not a frame problem; maybe a gameplay one.
* **Thin water hidden under the ground's overlay tiles** (a course laid one plate proud on some
  bricks): the water treats an overlay as one solid plate, or the mine world turns overlays off
  near water.
* **The generator's settings change**: the water's differences are only valid for the same
  seed and settings, the same rule the edits already follow.
