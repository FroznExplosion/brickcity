# Water and lava in the mine world — plan

Status: **stages 1-8 built** (multiplayer: groundwork, 11.5) (2026-11-17; section 14). For `scenes/terrain_test.tscn`, the mine world
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
6. **Spreading out by one plate** (stage 5; replaced stage 2's "a core thins"): each still
   cell keeps its distance to dry floor at its own level the sheet could spread onto (0 beside
   it, else one more than its nearest still neighbour's; 63 = none, as for a walled pond). A
   cell two or more deep gives a tile to a neighbour one plate lower that is nearer that edge.
   A spill on open ground thins to a tile and dries; water only moves outward, so nothing
   ping-pongs; a pond with walls round it has no edge and stays.
7. **A cut-off stream keeps a tile** (4.1.6): flowing water losing its feed becomes still water of
   one tile, unless it held more than its stream level (pond water a river ran over: kept). A
   cut-off fall keeps its whole brick and drains down.

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
| still kind dries | yes | no: cools into stone, 30-60 s at rest (built) |
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

*As built (stage 5):* not baked into the coarse blocks. A tile past the sim ring, where water
is frozen, swaps its full mesh for a **far mesh** built once on the worker (one flat quad per
4 x 4 studs at the highest top, no sides; `request_far_mesh`), and back inside the ring the full
one returns. One draw call per tile with water, which only player-made water has (the sea is
the wave tiers' sheet to 1 km). Baking into `build_coarse` stays the way to do it if far
water ever becomes common (lakes, stage 8).

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
* *Built (stage 4):* build mode slot 10 (key 0) the bucket, 11 (-) the source bucket, 12 (=) the
  test fluids (= again cycles them). The pawn swims past 1.05 m deep (`Pawn.water_probe`,
  `PawnMoves._swim_tick`: move keys steer, jump up, crouch down, idle floats the eye 0.12 m out,
  jump at a bank climbs out); shallower it wades at 70 % speed and running water pushes it.
  Under water the view takes `Underwater`'s fog (orange in lava); lava burns 40 health a second.

## 11. Saving

Beside the terrain's edits: `user://saves/mine_world/<seed>_<hash>.fluid` — each section that
differs from `gen_fluid`, run-length coded, zstd, plus its pending wakes, so a river that was
flowing is still flowing after a load. Same cadence and worker write as the edits (MineWorld.md
9); keyed by seed and settings the same way.

### 11.5 Multiplayer: the groundwork (built 2026-11-19)

Not networked yet; what is in place so finishing it is wiring, not redesign.

* **One authority simulates.** The host runs the rules as now. A client is a **mirror**:
  `BrickFluid.set_simulating(false)` -- its ticks apply what it is sent and build meshes,
  nothing else (no evaluations, no timers). The rules are not lockstep-safe (the order of
  wakes follows hash sets), so peers must not each simulate.
* **The host keeps a change log**: `set_change_log(true)`. Every cell whose drawn state
  changes is logged with the write count. `get_changes_since(version)` gives
  `{version, cells, full}`: the cells changed since `version`, each in the save's 15-byte
  form with its state *now* (so a cell changed ten times is sent once). `full` is true when
  `version` is older than the log reaches (it keeps a million changes, then starts over):
  send `get_save()` instead, the whole difference from the generated world.
* **A client applies** with `apply_changes(cells, false)` (no waking: it runs no rules) and
  keeps the version it was sent. On joining it gets `get_save()` once (its header is 5
  bytes; the rest is the same cell form).
* **Commands go to the host**: `place`, `remove` and the terrain's boxes
  (`terrain_changed`) are already plain values -- a client sends them, the host calls the same
  functions, and the result comes back in the next changes. Buckets work the same way (their
  contents live in the player's kit, which the game's own netcode will carry).
* **Generated water is never sent**: the sea, lakes, springs, lava pools and cave pools are
  functions of the seed and settings, the same on every peer. Only differences travel.
* **Bandwidth**: 15 bytes a changed cell. A spreading stream changes ~100-400 cells a second;
  sent at 10 Hz that is a few kB a second, compressed far less. A flood of thousands of cells
  wants interest management (only tiles near a player) -- the change log can be filtered by
  tile when that is built.
* Checked by `fluid_probe`: an authority's water, read from its log, rebuilt on a mirror
  that runs no rules (423 cells, 0 differ, 6.3 kB).

### 11.6 Look and feel, round 2 (2026-11-19, from the user's notes)

* **One water.** The fluid mesher's water is the sea's colour, the same however deep (it was
  dark until thin, then light), with a texture laid in WORLD space: ripples that move the same
  way everywhere and the sea's thin stud grid. It used to scroll along each cell's own flow,
  so neighbouring cells slid different ways and the surface read as a mess. Thin water is no
  longer dithered (the speckle of bricks through it was the "textures fighting"). Lava: one
  crust drifting one way.
* **No slide show.** Each vertex carries how far it moved since its tile's last mesh
  (CUSTOM0); the shader eases it there over a tick (`swap_s` per instance, `now_s` from
  the script). New cells rise from their floor. The water never edits the terrain; only lava
  rock and fire do (terrain edits, so those tiles rebake).
* **Minecraft's meeting, at once**: lava waiting for its slow tick still meets water every
  tick -- a source touched by water is obsidian, running lava stone. Water poured on running
  lava takes its place (a lava source cannot be poured over).
* **Finite water joins the sea**: still water touching a source of its own fluid drains into
  it, a tile a tick.
* **Lava starts fires** (`scripts/water/lava_fire.gd`): wood and leaves next to lava catch,
  burn a few seconds (flames, a light), set the wood and leaves touching them alight, then
  burn away. Trees (TerrainTrees) are not terrain and do not burn yet.
* **The swash** (water.gdshader): ground above still water gets the wave later the higher it
  is, and less of it, so the water climbs a beach terrace by terrace instead of welling up
  out of the sand. The swimmer's wave (BrickWave, CPU) does not have it: on a beach the two
  differ by a few centimetres.
* Found on the way: the mine world's new deep-cave darkening also darkened everything above
  ground (its curve sat at 0.12 for negative depth); fixed to apply only below 7.5 m.
* The `--gate=gen --with-collapse` crash happens with the water stopped too
  (`--no-water`): it is the ground collapse's, not the water's.

### 11.7 Cave pools redone, and what runs how often (2026-11-20)

* **Cave pools** no longer fill a grid region under a level behind stone walls and floors (the
  user: "floating rectangles filled with water", and one broken brick of a floor dropped it
  all). A pool region now finds, for each cave cell, the lowest height water there would have
  to reach to get out -- over the region's sides, down under it, or into open air (a priority
  flood) -- and the cells under it are water: the dips of cave floors, each filled to its own
  lip. Nothing is added to the ground. The water is STILL (a volume): broken into, a pool
  spills what it holds and settles. Worked out a region at a time on the water's thread and
  cached; the main thread only reads what is known. Fewer and smaller pools than before.
* **Per frame, the water now does less**: tile meshes swap six a frame at most, nearest first
  (a tick could put 24 uploads in one frame); a tick's lava rock is one terrain edit, not one
  per cell (each was a tile rebuild and a collapse survey); lava burns pawns at 10 Hz; the
  floaters see half the bodies a physics tick (force doubled) and reject a body nowhere near
  fluid with one native call (`BrickFluid.ocean_at`, no Dictionary). The rules run at 10 Hz
  on the water's own thread, as before.
* Not the water's, for the collapse's chat: the survey (`TerrainCollapse.survey`, on a
  worker) took 2.5 s; tile rebuilds after the edits it makes cost the streamer 150 ms frames;
  whole cave ceilings come down for one brick (ground strength `TERRAIN_TIMES`).

### 11.8 What runs where nobody is, and what the main thread waits for (2026-11-20, audit)

* **Pit checks** (4.5): a landing whose body is OPEN (it spills) waits 30 ticks before the
  next look. It used to stay due, so every waterfall onto open ground was flood-filled (up
  to 4096 cells) once a second for good, wherever it was; and only the first 32 landings in
  the set's order were ever looked at, so with more than that a real pit elsewhere never
  filled. Now the due ones in reach, longest waiting first. Landings past the sim radius wait.
* **Timers** (drying, lava setting) past the sim radius wait in their own list and fire when
  the player comes back (not frozen as cells: their armed flag would stop a woken cell from
  arming them again).
* **Sections far away are let go**: past twice the sim radius (plus a tile), a section never
  written, dry and with nothing queued is dropped every 5 s -- it is the seed and the
  terrain's edits again. Written or wet sections stay. `stats().evicted`.
* **The sea mask** (7.2) is built on a worker, at most every 0.5 s for water changes (the
  window moving starts one at once), and BrickFluid.sea_mask holds the lock only for its
  scan, not the distance passes. It was built on the main thread on every tick that
  touched the sea's courses.
* **Waiting on the lock, measured**: the main thread's questions (surface_at, flow_at,
  fluid_at, ocean_at, ray_cell, cell_info, sea_mask, drawn_tiles, get_save) time their
  wait for `g_state`; `stats()` gives `main_wait_ms` (worst since the last ask),
  `main_waits_1ms` and the worker's hold `apply_ms`. If those are large, the next step
  is a read copy for the main thread.
* **The terrain's edits** (brick_terrain.cpp) are a table safe to read while the main
  thread writes (one writer, readers take no lock). The tile bakes, find_brick and the
  collapse survey read the old maps with no lock while edits landed -- a race, and past
  65 536 edited cells a rehash under a reader. set_edit no longer takes the edit lock per
  cell, so an edit never waits for the water to finish sampling a column.
* A lava tile's light is placed from at most 64 of its vertices, not all of them.

### 11.8 The real sea near the player; spreading water stays low (2026-11-20)

* **The real sea.** In a square of 9 x 9 tiles (about 100 m) round the player the sea's top
  course is drawn by the fluid mesher like any water (`BrickFluid.set_real_sea`). The wave
  tiers leave that square out (water.gdshader `real_rect`, discard) and calm to flat over
  16 m toward it (`real_ramp`); the real sea's own waves fade to flat at its edge too, so the
  two meet level. A dug beach there takes real sea water; waves no longer come up through sand.
  The swimmer reads the fluid's surface inside the square and the calmed waves near it.
* The square moves in steps (two tiles of slack). A new square's sea columns are read three
  tiles a tick on the water's thread (about 12 ms a tile), nearest first; take() reports
  `real_rect` once all its meshes are out, the script moves the tiers' hole when they are
  swapped in and calls `real_sea_shown`, and only then are the old square's tops dropped --
  never a hole between them.
* **Its waves** are drawn only (the water stays level): CUSTOM0.y marks a sea top, .z how
  open it is (0 against ground, 1 four studs out). Open water swells about 0.1 m, water
  against ground laps up it. Tops are 4 x 4 stud quads out in open water, a quad a stud
  within four studs of the shore.
* **Spreading water stays low.** A top corner averaged its neighbours but snapped to a full
  brick if any had water stacked over it, so the thin water round a poured pile jumped to a
  brick and back as the pile drained. A stacked neighbour is now left out of the mean (the
  pile's own side covers the step); only a stacked cell is full at its corners.
* Seen: the wave tiers' sea is shaded a little lighter than the fluid's, so the square's
  edge shows as a soft change of colour at about 50 m.

### 11.9 The real sea is a band along ground, waving with the sea (2026-11-20)

Replaces 11.8's square (the user: its edge showed from above, flat against waving, and the
channel's water stood apart from the waves).

* **Where:** sea within 6 studs (`REAL_BAND`) of ground at the sea's top course -- a shore, a
  pier, a dug hole, a brick set in open sea -- is drawn by the fluid mesher; all other sea is
  the wave tiers'. Sea columns are read in a 9 x 9 tile square round the player (three tiles a
  tick on the water's thread); the band is drawn only there. The mesher marks the band's studs
  (`Section::real`) and `sea_mask` hides them from the tiers, stud by stud.
* **One surface:** `shaders/sea_wave.gdshaderinc` holds the sea's wave code and its uniforms,
  included by water.gdshader and water_fluid.gdshader; MineWater copies the near tier's values
  to the fluid material (wave_time each frame, the rest four times a second). Band water rides
  the same waves (a third of them against ground, where it laps); water over ground the field
  calls land (a channel dug inland) only laps.
* **One look:** all fluid water uses the sea's colours (trough to crest by the wave, darker
  with depth), copied from the sea's material. Found on the way: the fluid tops were wound so
  that from above is their back, and with cull_disabled Godot flipped their normal down --
  they were lit as facing down, which is why the water had been dark (first "black", then
  "darker than the sea"). The shader now takes the mesher's normal.
* **Pieces, as the tiers draw them** (the user saw the band as a smooth sheet against the
  tiers' bricks): each band stud is a flat piece that rides the wave at its middle (CUSTOM0 x,
  w: the way to the middle), with four sides a brick deep -- the risers. The fragment restates
  the tiers' look: crest colour by wave, whitecaps, depth tint, print lines, stud grid; those
  values are copied from the sea's material too. Side by side the two cannot be told apart.
* **The ocean cannot be emptied:** still water laid on the open sea joins it; a source bucket
  dipped in the ocean takes nothing (`ray_cell` ocean); a bucket always filled free from a
  source. Two sources still make a third. Only a brick placed where sea was moves sea water;
  broken, the sea runs back.
* The swimmer reads the tiers' waves over all ocean, the band included (the same waves).

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

### 12.1 Measured (2026-11-17, before stage 5)

`tools/probes/fluid_bench_probe.gd`, headless, editor closed, nothing else running, chip at 54 C.
The DLL is godot-cpp's template_debug, which is /O2 (`optimize=speed_trace`): optimised numbers.

| | Measured | Estimate |
|---|---|---|
| rules, flowing water (64 sources spreading) | **885 ns a cell** | 50 ns |
| rules, still water (a 10k-brick spill spreading) | **173 ns a cell** | 50 ns |
| a column read from the field the first time water reaches it | **10-13 us** (16 courses x 3 plates) | � |
| a tile mesh | **0.10-0.34 ms** | 0.2-0.6 ms |
| a calm world | **0.07 ms a tick, 0 awake** | 0 |
| the shore field, 3072 studs each way every 8 | **261 ms** on a worker | � |

So a tick with 20k flowing cells is ~18 ms on the worker at 10 Hz (~18 % of a core), not 1 ms;
the 64k budget is ~57 ms. Fine off the main thread; the budget may want lowering to ~20k.
Where the time goes: first touches are column reads (a flood front is mostly that), and a
spreading spill is two-thirds meshing (every still top is its own quad: merging still tops,
7.1, is the next saving). Before this run, a section lookup cache and an allocation-free
`seek_dirs` took flowing water from 7.2 us (sampling included) to 5.9 us; the split above
shows the rest was column reads, not rules.

The bench also found two rule bugs, fixed in stage 5: a big still spill stopped spreading
after one ring and stood three deep for ever (fixed by the edge distance, 4.2.6), and a
drying tile could lose its timer to a same-tick write (timers now run first).

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
   *Built 2026-11-17 (28 checks, 4 s). First cost reading, debug build with the editor open:
   a 1600-cell spill ticks 1260 cells in ~3 ms, ~2.3 �s a cell � far over the 50 ns estimate
   in section 12; measure a release build on a quiet machine before stage 5, and look first at
   `seek_dirs` (a hash set per call) and the hash-map lookups per neighbour.*
2. **Drawing it in the mine world**: per-tile meshes, the water shader, hotbar test entries.
   `-- --gate` pictures: a stream down a stepped hill, a waterfall, a pond, a stream drying.
   *Built 2026-11-17:* `scripts/water/mine_water.gd` (ticks on its own thread, recycled tile
   meshes, lava rock laid as terrain edits), `shaders/water_fluid.gdshader` (depth colour, dithered
   thin water, ripples along the flow, falls scroll down, lava glows), build mode slots 10-12
   (keys 0, -, =): water source, water brick, lava source; RMB pours, LMB takes. Pass:
   `scenes/terrain_test.tscn -- --gate=water` (pictures `user://dev/water_*.png`).
3. **The sea on**: `gen_fluid`, the sea course, caves sealed, the wave tiers streamed with the
   shore field, the mask, the Water tab. Gate: coast, river mouth, a dug channel off the sea.
   *Built 2026-11-17:* gen param `water` (on by default in the mine world's presets) seals
   caves and ravines under the sea course in sea-floor and low-shore columns
   (`terrain_biomes.cpp`); `BrickFluid.reset(sea, true)` snaps the sea to a course and
   `BrickWave` takes that level; `WaterSea` draws it (no pools of its own, `use_fluid_mask`:
   `BrickFluid.sea_mask`), its shore field 3072 studs each way computed round the player on a
   worker (`compute_shore_field`) and swapped in after 768 studs or 1.5 s after an edit under the
   sea line. A source re-made in dug ground is calm, not ocean (the tiers do not draw dug
   ground). The Sea & Water tab: water on/off, wave height. Pass `-- --gate=sea`.
4. **The player**: swimming, underwater fog, flow push, both buckets, placing into water.
5. **LOD**: the sim ring and frozen sections, far water in the coarse blocks, the budget.
   Measured with the editor closed (CLAUDE.md).
6. **Lava**: the second fluid's table, its look and glow, burning, obsidian and stone.
   *Built 2026-11-18:* lava turns to rock only as thick as it was (the rock output is per cell
   `x, z, first plate, last plate, material`: a tile of lava, a tile of rock); a source meeting
   water makes obsidian, running lava stone; still (cut-off) lava at rest cools into stone 30-60 s
   later; a crust of dark plates drifts over the melt with bright cracks, breathing; one light a
   tile with lava (`OmniLight3D`, recycled, faded past 80 m); every pawn in lava burns (40 a
   second, `Elements.FIRE`) and moves at 35 % (`Pawn.water_drag`). `--gate=water` has a lava
   pool at night, a pawn burning in it, and the pool cut off and cooled.
7. **Saving** the water with the edits.
   *Built 2026-11-18:* `<seed>_<hash>.fluid` beside the edits (zstd), written on the same worker
   as the edits when the ground or the water changed (`BrickFluid.change_count`); each cell that
   differs from `gen_fluid` (15 bytes). `get_save` never waits on a tick: it reads under the
   state lock, ~5 ms on the main thread for 135 sections (the bench). Loaded after the edits;
   every cell is woken, so running water runs on and drying starts again (the timers are not
   saved). "Forget changes" deletes it. `--gate=water` saves, generates again, and compares.
8. **Later**: pits filling from rivers (4.5), lakes above the sea, cave pools, springs, lava
   pools, floating debris, mixed water pieces, multiplayer diffs (STA §10.8–10.9).
   *Built 2026-11-18 (part of it):*
   * **Merged water tops** ("mixed water pieces", for drawing): flat tops of a course with the
     same height and look are one rectangle (greedy, per section course). A calm 8 x 8 pond is
     one quad, not 64; meshing was two thirds of a spreading spill's time (12.1).
   * **Lava pools deep down**: gen params `lava_pools`, `lava_m` (from the sea line, default -112 m,
     a few bricks over the bedrock now that caves reach it):
     all cave air under that line is lava, a source (Minecraft's cave-bottom lava). Generated,
     not stored. Calm: nothing is awake until something is dug into it.
   * **Springs**: gen params `springs`, `spring_chance` (default 2 %): a column beside a cliff of
     three bricks or more, chosen by hash, has a source in the air under the cliff's real top
     (the overhang band counted). It falls down the face and runs on as a stream.
   * **Priming**: generated lava and springs live in the field, so a tile coming into the sim ring
     is primed once (`BrickFluid.prime_tile`): its lava band is read, so it is drawn, and its
     springs are woken, so they run. Six tiles a half second, nearest first. ~10 ms a tile on the
     worker.
   * Fixes found on the way: `BrickTerrain.generated_plate` read the classic field in the biome
     world, and dug ground under the sea line was marked only a plate above the sea in the shore
     field, so wave crests drew the sea down any pit dug inland; now 100 m over it. The save skips
     sections never written (generated lava would have been scanned every autosave).
   * The Sea & Water tab has lava pools, the lava line, springs and the spring chance.
     `-- --gate=gen` pictures a spring near the spawn and a lava pool down a dug shaft.
   *Built 2026-11-19 (the rest):*
   * **Pits filling from rivers (4.5)**: still water as deep as what would feed it stays
     still (a fall lands on a full pit as on ground; a river no longer turns a pond into a
     river). Every 10 ticks the running water round each landed fall is looked at: a closed
     body (no drop, no dry floor lower than its top, no source joined) becomes full still
     water, and the fall lands a course higher -- the pit rises to its rim and spills.
   * **Lakes above the sea**: `lakes`, `lake_chance` (generator, `terrain_biomes.cpp`). A region
     of 384 studs may hold one: at the lowest of nine hashed points, an ellipse 18-47 studs a
     radius, its level a brick under the lowest column of its rim; inside the rim the ground
     is cut to a sand bowl 1-4 bricks under it, so every lake has water. Trees keep out.
   * **Cave pools** (Minecraft's aquifers): `cave_pools`, `cave_pool_chance`. A region 40
     studs across and 12 bricks tall may hold water up to a level in it; the generator leaves
     stone barriers on the region's floor and on faces between regions of different levels,
     so no pool water stands beside cave air. Over the lava line only. Primed by the band of
     courses round the eye.
   * **Floating and sinking debris** (`scripts/water/floaters.gd`): the bricks a shot throws
     and the pieces that come loose float or sink by what they are MOSTLY made of: mostly
     wood (0.6) or leaves (0.35) floats, mostly anything else (stone 2.4) sinks. Lifted by
     the share under the surface over their density, slowed by the fluid, carried by running
     water; lava is 3x as dense, so wood floats on it too. New building materials `wood` and
     `leaves` (on the hotbar) use filaments no ground uses, so a block's colour says what it is.
   * **Multiplayer groundwork**: section 11.5.
   * Fixes found on the way: a section read while dry (priming) kept stale solids when ground
     was laid there later -- water fell through a floor (`box_near_water` now counts every
     section read); lava and pools filled holes the player dug (only generated air fills
     now); the deep tier stayed off in a dug shaft (it measured from the dug surface);
     `ground_collapse.gd` waited twice on a finished task ("Invalid Task ID" at exit); the
     water's thread and the shore field read the terrain's edit tables under a lock now
     (`edit_lock`), and the water's thread prints its own crash and backtrace (Windows).
   *Open:* `--gate=gen --with-collapse` (ground collapse running while a 4 x 4 shaft 120 m deep
   is dug) crashes the scene about half the runs with no backtrace at all -- not the water's
   thread, which now reports its own; it smells of a stack overflow in the collapse's survey
   of a very big region. The gate pauses the collapse by default.
   *2026-11-21:* not seen since the collapse split its edit boxes (TerrainCollapse.md 8.1,
   "Surveys per box"): 5 runs of `--gate=gen --with-collapse` in a row, all to `[gen-gate] done`,
   exit 0 (was about 1 in 2). The gate still pauses the collapse unless the flag is given.

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
