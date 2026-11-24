# The mine world's water, next -- research and plan

Written 2026-11-24. Plan only: nothing here is built yet.
Builds on Docs/MineWater.md (what is built) and Docs/TerrainRegions.md 7 (the
water audit). Area: Terrain and water (`brick_fluid.*`, `scripts/water/`,
`shaders/water*`).

## 0. What the user asked for

- **Water like Minecraft's, but finite inland and in caves.** The sea stays
  infinite; what the player finds inland and underground is a volume that
  can be emptied, spilled, moved and lost.
- The water as built is "pretty good" with **a few bugs, mostly visual**:
  fix those.
- Keep the research from other water systems (section 1) and plan the
  improvements it suggested (sections 3-6).

## 1. Research: other water systems (2026-11-24)

From search results; CurseForge, Modrinth and 9minecraft were not reachable
from the container this was written in, so their pages were read through
search summaries, not directly.

| Project | Source | What it does |
|---|---|---|
| **Flowcraft** (Vrakk; Fabric, MC 1.21.1) | **closed**: CurseForge lists it "All Rights Reserved"; no repository found (the GitHub "FlowCraft"s are unrelated: a CFD viewer, workflow engines) | water (and later lava) simulated **on the GPU**: pours, splashes, fills any shape, a breached wall drains, waterfalls are water over an edge, `/tsunami`, `/water cube`, pause/speed. **Single player or LAN host only**, nothing on a dedicated server; no shader packs (Iris); turns itself off on a GPU that cannot run it. Grid size and algorithm not published. |
| **Flowing Fluids** (Traben) | listed with a GitHub presence; repository and license not confirmed | mostly finite: 1-8 levels a block, buckets take 1-8; a full block is saved as a vanilla source, partials as vanilla flowing (the world survives removing the mod); exposed fluids plugged after generation so oceans do not drain into caves; rain and wet biomes (ocean, river, swamp) refill; v0.2 made water settle "much faster" for fewer updates; tick delay and flow distance per fluid are settings |
| **Gradient** ([GitHub](https://github.com/Jaddotish/Gradient); Fabric 1.20.1) | open (license not checked) | region-based, water conserved exactly every step, regions run only when activated, vanilla water becomes simulated only when touched; experimental, no releases |
| **mc-fluid-physics** ([LolHens](https://github.com/LolHens/mc-fluid-physics)) | Apache 2.0 | a hybrid, "intentionally not a realistic fluid simulation" so vanilla play still works |
| **DwarfCorp** ([write-up](https://gamedeveloper.com/programming/how-water-works-in-dwarfcorp)) | write-up and a 2D prototype | cellular automaton on ~1 m voxels; a surface mesh from heights averaged between neighbours, hidden faces dropped; no pressure (water never rose) as of 2013 |
| Dwarf Fortress, Noita, Terraria | -- | cellular automata on cells; Dwarf Fortress has pressure (water rises through U-bends) |

**Against ours.** Already the same or ahead: per-cell volume in whole units
(our 1-6 half-tiles, their 1-8 levels) so water stops exactly; finite water
conserved exactly (Gradient); only what changed runs, sections made only where
water was changed (Gradient's lazy regions); caves sealed against the sea at
generation (Flowing Fluids' plugging); infinite sea and rivers beside finite
spills; host authority and a change log for multiplayer (Flowcraft has none).
**Flowcraft is ahead on one thing**: water that rises to fill a shape. Ours
has no pressure (MineWater.md 4.5): no rising through a U-bend, and pits fill
only by the special rule of 4.5 (built 2026-11-19).

**The GPU: no**, for us. Gameplay reads the water on the CPU (swimming,
floating, buckets, lava rock, the collapse); reading a GPU simulation back in
play breaks CLAUDE.md's no-read-back rule and the renderer's move off the main
thread; the Legion Go is GPU-bound already (12.5 of 16.6 ms); and Flowcraft's
own limits (no servers, off on weak GPUs) are what our multiplayer groundwork
avoids. The water stays on its own CPU thread (main-thread lock wait measured
0.00 ms).

## 2. Who is finite today, and who will be

| Water | Today (MineWater.md 3, 9, 14) | Wanted |
|---|---|---|
| the sea, up to the sea line | sources, ocean, infinite | **infinite** (unchanged) |
| rivers (cut to just under the sea line, filled as sea) | sources, infinite | **infinite**: they are the sea, joined to it (decision 1) |
| lakes above the sea | sources, infinite; "a lake cannot be emptied by bucket" (4.1.7) | **finite**: still water, a volume |
| cave pools | still, finite | finite (unchanged) |
| springs on cliff faces | sources, infinite | **decision 2**: finite (a reservoir) or a slow trickle |
| water the player pours | still, finite | finite (unchanged) |
| a source bucket's source | a source, infinite | **decision 3** |
| the new-source rule (two sources make a third, 4.1.7) | on for all water | **only for ocean water**: inland it would make finite water infinite again |

Decisions for the user (asked before stage F1):
1. **Rivers** stay infinite, being the sea's own level and joined to it?
   (Recommended: yes. Rivers above the sea, when the generator makes them,
   are finite like lakes.)
2. **Springs**: (a) a finite reservoir -- a spring holds N bricks behind the
   face and runs dry; (b) a trickle -- infinite but slow, one tile every few
   seconds, so it fills a pond over minutes and a dam holds it; (c) remove
   them. Recommended: (b), the closest to "finite" that still lets the world
   keep its waterfalls.
3. **The source bucket** (makes an infinite spring anywhere): keep it as a
   creative / test tool only, or remove it from play.

## 3. Stage F: finite inland water

- **F1 Lakes as still water.** `gen_fluid` gives lake cells as STILL,
  full, instead of source; the generator's bowl is unchanged. A full still
  body costs nothing (no wakes), so a calm lake stays free. Breaking its
  rim spills it; a bucket takes 3 tiles from it; a drained lake's bed stays
  (sand). Saved as differences from the generated lake, as now.
- **F2 New sources only in the sea.** 4.1.7 asks for the ocean bit on the
  neighbouring sources.
- **F3 Springs** by decision 2.
- **F4 Rain refill** (from Flowing Fluids, optional, with the user): rain
  adds a tile now and then to open still water under the sky, so a world does
  not dry out over hours. Uses the timers the water already has.
- **F5 Drying.** Today a one-tile cell next to only one-tile cells dries
  after 15-45 s (4.2.3). Finite lakes make every spill matter more: check
  with the user that a spilled lake should lose its thin edges (Minecraft-
  like) or keep them (no loss but by buckets).
- Checks: `fluid_probe` (volume conserved through a spill; a lake drained by
  buckets stays drained across save and load; the new-source rule only by
  the sea), the water gate (`-- --gate=water`), the generation gate
  (`-- --gate=gen`).

## 4. Stage P: water that fills its shape (pressure, by bodies)

Not a pressure field per cell: when a STILL body has been calm a moment, level
it as one body.

- Find the connected still body (the pit rule's flood fill already does this,
  `PIT_MAX` 4,096 cells, brick_fluid.cpp ~1738).
- Count its volume (units). Fill it again from its lowest open floor up,
  course by course, across every connected opening -- so a U-bend's far arm
  rises to the same level, a sealed chamber fills up to its roof, and a pit
  joined to a pond fills to the pond's level.
- Only the cells that changed are written (and woken); the volume is exact.
- Runs on the water's thread, on bodies that have just settled (no wakes for
  N ticks), never per tick; a body over the cap is left to the cell rules.
- This replaces the special "pit fills from a river" rule of 4.5 for still
  water (that rule stays for fed water).
- Checks: a U-bend probe (pour in one arm: both arms end level), a sealed
  room filled by a bucket at the top (fills from the floor), volume
  conserved, a calm world still 0 awake.

## 5. Stage V: the visual bugs

The user says the bugs are mostly visual; the list is theirs to give. Steps:

- **V0** Collect: the user's list, plus a picture pass of the water gate and
  the sea gate at MSAA 2x (the user's setting), with each bug's picture and
  where it is. Known from the docs: the wave tiers' sea is shaded a little
  lighter than the fluid's, so the real-sea band's edge shows as a soft
  change of colour at about 50 m (MineWater.md 11.8, "Seen").
- **V1+** One fix per bug, each with its picture before and after and the
  gate re-run. Easing (7.5), see-through (7.4) and the band (11.9) are the
  places most visual fixes have needed so far.

## 6. Stage W: cost and memory (from TerrainRegions.md 7)

- **W1** The water reads the ground from the terrain's kept cells (after
  TerrainRegions stage A): `sample_column` stops working out noise per column
  (a column's first read 10-13 us; the real-sea square ~12 ms a tile;
  springs ~10 ms a tile).
- **W2** Re-measure the tick in a release build, editor closed: the readings
  are 885 ns a flowing cell and 173 ns a still cell (fluid_bench_probe,
  2026-11-17). Finite lakes (F) and levelling (P) add still work; know the
  start first.
- **W3** Far written or wet sections kept in their save form (run-length),
  expanded when the player comes back: today they stay in memory for good.
- **W4** (optional) still-water tops as packed brick pieces (the region fit).

## 7. Order

1. **V0** (the list) and the three decisions of section 2, with the user.
2. **V1+** the visual fixes (they need no new design).
3. **W2** the tick measured.
4. **F1-F2** lakes finite, new sources only in the sea; **F3** springs.
5. **P** levelling by bodies.
6. **W1** after TerrainRegions stage A; **W3**; **F4**, **F5**, **W4** with the
   user.

Windowed gates one at a time with a heat check after each (CLAUDE.md);
timing (W2) only with the editor closed.
