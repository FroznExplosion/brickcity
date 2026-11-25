# The mine world's water, next -- the user's design, research and plan

Written 2026-11-24; the design (section 2) is the user's, given that day.
Plan only: nothing here is built yet. Builds on Docs/MineWater.md (what is
built) and Docs/TerrainRegions.md 7 (the audit). Area: Terrain and water
(`brick_fluid.*`, `scripts/water/`, `shaders/water*`, `shaders/sea_wave*`).

## 0. What the user asked for

- Water like Minecraft's: **oceans, lakes and rivers infinite, flat source
  bricks** with waves drawn over them; **everything else finite** (ponds,
  puddles, cave pools, above or below the surface) and drainable.
- The water as built is "pretty good" with **a few bugs, mostly visual**: the
  user's list is still to be collected (section 5).
- Keep the research on other water systems (section 1).

## 1. Research: other water systems (2026-11-24)

From search results; CurseForge, Modrinth and 9minecraft were not reachable
from the container this was written in, so their pages were read through
search summaries, not directly.

| Project | Source | What it does |
|---|---|---|
| **Flowcraft** (Vrakk; Fabric, MC 1.21.1) | **closed**: CurseForge lists it "All Rights Reserved"; no repository found (the GitHub "FlowCraft"s are unrelated) | water (later lava) simulated **on the GPU**: pours, splashes, fills any shape, a breached wall drains, `/tsunami`, `/water cube`, pause/speed. **Single player or LAN host only**; no shader packs (Iris); off on a GPU that cannot run it. Grid and algorithm not published. |
| **Flowing Fluids** (Traben) | a GitHub presence; repository and license not confirmed | mostly finite, 1-8 levels a block, buckets take 1-8; full blocks saved as vanilla sources; exposed fluids plugged after generation; rain and wet biomes refill; settles "much faster" since v0.2 |
| **Gradient** ([GitHub](https://github.com/Jaddotish/Gradient); Fabric 1.20.1) | open (license not checked) | region-based, water conserved exactly, regions run only when activated; experimental |
| **mc-fluid-physics** ([LolHens](https://github.com/LolHens/mc-fluid-physics)) | Apache 2.0 | a hybrid, "intentionally not a realistic fluid simulation" |
| **DwarfCorp** ([write-up](https://gamedeveloper.com/programming/how-water-works-in-dwarfcorp)) | write-up, 2D prototype | cellular automaton on ~1 m voxels; surface mesh from averaged neighbour heights; no pressure as of 2013 |
| Dwarf Fortress, Noita, Terraria | -- | cellular automata; Dwarf Fortress has pressure (water rises through U-bends) |

**Against ours**: whole-unit volumes so water stops exactly, exact
conservation, only changed cells run, caves sealed against the sea at
generation, infinite and finite water side by side, host authority with a
change log -- the same as or ahead of these. Flowcraft is ahead on water
that rises to fill a shape (ours has no pressure: section 4).
**A GPU simulation: no.** Gameplay reads the water on the CPU (swimming,
floating, buckets, lava rock, the collapse); a read-back in play breaks
CLAUDE.md; the Legion Go is GPU-bound (12.5 of 16.6 ms); Flowcraft's limits
(no servers) are what our multiplayer groundwork avoids.

## 2. The design (the user, 2026-11-24)

**R1 -- Infinite bodies are flat source bricks.** Oceans, lakes and rivers
are made entirely of source bricks, flat in the grid. The grid never moves:
a crest drawn above a cell or a trough below its top changes no cell. The
waves are drawing plus a height query (BrickWave): swimmers, floating things
and boats ride the drawn wave.

**R2 -- A wave is the source under it.** A bucket used on a wave (on the
drawn surface, above or below the flat top) takes from the source column
under it: infinite water.

**R3 -- No bricks placed on water.** A brick cannot be put down on the water
surface. The player builds up from the floor, out from a beach, or down from
above.

**R4 -- Bricks in water make a beach.** Bricks that replace source cells
remove them; any brick touching source water, wherever it is, acts as a
beach there (waves lap it, the shore look). Taking the brick away gives the
water back (the body heals).

**R5 -- Everything else is finite.** Ponds, puddles, cave pools, water above
or below the surface, water poured from a bucket: still water, conserved,
drainable.

**R6 -- Infinite water never collects.** Water flowing from a source runs
like Minecraft's and does not pile up or add water anywhere.
**R7 -- Finite water does collect** (pools in hollows, as now).

**R8 -- Springs exist**: infinite, with a level that keeps their waterfall
running.

**R9 -- The source bucket stays**, and a source touching FULL finite water
turns those full bricks infinite.

**R10 -- Rain, later**: rain adds finite water to the ground, which collects
(hollows, under springs, ...).

## 3. What changes, against what is built

| Rule | Built today (MineWater.md) | To do |
|---|---|---|
| R1 sea | sources + ocean bit, flat; waves drawn (tiers, the real band, `sea_wave.gdshaderinc`) and queried (`BrickWave`, `MineWater.surface_at`) | none for the sea |
| R1 lakes, rivers | lakes: sources, drawn flat by the fluid mesher, **no waves**; rivers: the sea's level, sea sources | **waves on every infinite body**: a wavy flag on source tops open to the sky (not only the ocean bit), the amplitude per body (by its open reach: the mesher's CUSTOM0.z already says how open a top is); `surface_at` and the floaters ask the wave at any body's level, not only within 3 m of the sea line |
| R2 | `ray_cell` walks the grid to the first water; a wave crest above the top is air | the bucket's aim takes the drawn wave: a ray that crosses the wave height over a source column hits that source; a trough below the top still hits the top cell |
| R3 | the builder's aim passes through water and places INTO it (deleting it, 4.3) | refuse a placement on the water: a brick needs solid support, not water (decision A) |
| R4 | the real band: sea within 6 studs of ground at the sea's top course, 9 x 9 tiles round the player (11.9); a placed brick in the sea is a shore already | the same for lakes and rivers and any source surface; a brick taken out of a body: its cells refill from the body (the new-source rule does it beside 2+ sources; check a 1x1 hole and a hole against the shore) |
| R5, R7 | still water (4.2): conserved, pools, dries at one tile after 15-45 s | unchanged (drying: decision C) |
| R6 | three rules make finite water from fed water: a cut-off stream becomes still water (4.1.6); a closed pit under a fall becomes full still water and rises (4.5, built 2026-11-19); fed water over a pond takes its cells over and gives them back as still water when cut (4.2.5) | **all three off**: a cut-off stream drains away and is gone (Minecraft); a fall into a pit covers its floor as a thin stream and never fills it; fed water flows over or beside a pond without changing its volume |
| R8 | springs: generated sources on cliff faces (`springs`, `spring_chance` 2 %) | unchanged; check each runs a waterfall |
| R9 | still water touching a source drains into it (4.2.4) | **full** still cells touching a source become sources, through every connected full cell (one flood fill, capped); partial cells still drain in as now (decision B) |
| R10 | none (disasters' rain is drawing) | later: rain on open sky adds a tile now and then to the ground or to still water under it |

**Decisions -- the user's answers (2026-11-24):**
- **A: build up or down only, for now.** Bricks laid sideways fall today and
  the user wants that solved later: an automatic bridging system for sideways
  placement, maybe sideways bricks joining the terrain (which may break the
  terrain system -- with the terrain chat). R3 refuses bricks on water; no
  side joint now.
- **B: the whole connected full body** turns source.
- **C: keep drying.**
- **Visual list:** the flow looked choppy -- a cell water reaches rose from
  its floor and at once fell as it passed water on. Wanted: a new cell pops
  in at its height, holds it, and eases down only as it loses water. Done
  2026-11-24 (MineWater.md 7.5). The far-sea edge and pale shallows were not
  on the list (the MSAA fix of 2026-11-23, MineWater.md 7.4, came first).

**Decisions as asked** (kept for the record):
- **A. Building out from a beach.** Terrain bricks join only up and down
  (TerrainBond.md), so a brick laid beside a beach with water under it holds
  nothing and the collapse would drop it. Either (1) "out from a beach"
  means building up from the shallow floor near the shore (no rule change),
  or (2) a brick at the water's top course may join its solid side
  neighbour (a side joint, the plan's later side studs, TerrainRegions.md 5).
  Recommended: (1) now, (2) with side studs.
- **B. How far R9 spreads.** Through the whole connected full body (a
  brim-full pond becomes a lake) -- recommended -- or only the cells touching
  the source.
- **C. Drying.** Finite thin water dries today (Minecraft-like). Keep it, or
  only buckets and drains lose finite water.

## 4. Water that fills its shape (levelling by bodies)

Finite water has no pressure: it does not rise through a U-bend, and a
sealed room fills unevenly. When a still body has been calm a moment, level
it as one body: find it (the pit rule's flood fill, `PIT_MAX` 4,096 cells,
brick_fluid.cpp ~1738), count its units, fill it again from its lowest open
floor up across every connected opening, write only the cells that changed.
On the water's thread, on bodies that just settled, never per tick. With R6
this is the only way a pit fills: with finite water.

## 5. The visual bugs

The user's list first (where, what, a picture). Known from the docs: the wave
tiers' sea is a little lighter than the fluid's, so the real band's edge
shows as a soft colour change about 50 m out (MineWater.md 11.8, "Seen").
Then a picture pass of `-- --gate=water` and the sea gate at MSAA 2x (the
user's setting). One fix per bug, a picture before and after, the gate re-run.
Easing (7.5), see-through (7.4) and the band (11.9) are where visual fixes
have needed work before.

## 6. Cost and memory (TerrainRegions.md 7)

- **W1** read the ground from the terrain's kept cells (after TerrainRegions
  stage A): `sample_column` stops working out noise per column (a first read
  10-13 us; the real-sea square ~12 ms a tile; springs ~10 ms a tile).
- **W2 -- measured 2026-11-24**, editor closed, nothing else running, started under 75 C
  (`fluid_bench_probe`). Release library (template_release, the worktree's .gdextension
  pointed at it for the run) and the usual debug one, which is /O2 too, come out the same
  within heat noise -- the debug build is the game's real number:

  | | release | debug |
  |---|---|---|
  | flood, 64 sources (rules a cell) | 943 ns | 776 ns |
  | spill, 10k bricks (rules a cell) | 223 ns | 186 ns |
  | spill: mean / worst busy tick | 32.8 / 105 ms | 27.7 / 89 ms |
  | spill: meshing share of the tick | 66 % (0.91 ms a tile) | 77 % (0.78 ms a tile) |
  | calm world, a tick | 0.038 ms | 0.033 ms |

  The same as 2026-11-17 (885 / 173 ns). **The rules are not the cost: meshing is** -- two
  thirds or more of a busy tick, ~0.8 ms a tile re-meshed. That is where to look before
  anything else (fewer re-meshes a tick for slow changes, cheaper tops), not the cells.

  **Done 2026-11-24:** the easing's per-corner hash map is a vector sorted once a mesh;
  a tile changing every tick is re-meshed every `MESH_GAP` (2) ticks -- its corners ease
  over 0.2 s, two ticks -- except round the player or when asked. Spill bench: 14,150 ->
  10,867 meshes, mean busy tick 34.9 -> 22.3 ms (part of it a cooler machine).
  2026-11-25, a tile meshed 200 times with no sim running (one tile, ~5,000 vertices):
  the easing's corner lookups and writes were half the cell loop; a flat open-addressing
  table (`EaseMap`) for them: 0.57 -> ~0.45 ms a mesh. Not the cost: Godot's packed
  arrays' push_back (MeshBuf now builds in std::vector and copies once anyway) and
  `wcell` reads (a same-section fast path, kept, changed nothing measurable).
- **W3 -- done 2026-11-24.** Past 1.5 x the sim radius plus a tile (~112 m;
  was 2 x), with nothing queued: a section never written -- dry, or only the
  generated sea, lakes, pools -- is let go (sampled afresh if asked); a written
  one is PARKED: only its cells that differ from the generated world, sorted
  by column (`g_parked`, ~5 bytes a cell), put back as each column is sampled
  again (`Section::pending`). The save writes parked cells as they are; the
  main thread's reads (`rcell`) see them. `--gate=mem` (the terrain chat's
  probe, a second leg added): 1,359 sections / 122 MB after a 480 m flight
  over sea before; now 629 / 56 MB, and 566 / 51 MB after a second 480 m --
  level, not growing; 14 parked sections, 3 KB. `fluid_probe` 13. Seen: far
  water meshes read only existing sections, so water let go past ~112 m is
  drawn again once back within the sim ring (as unvisited water always was;
  the sea is the tiers').
- **W4** (optional) still tops as packed brick pieces (the region fit).

## 7. Stages, in order

1. **V0** the user's bug list and decisions A-C.
2. **V1+** the visual fixes.
3. **S1 -- done 2026-11-24.** R6: the three fed-to-finite rules off (water only; lava still
   comes to rest and cools). A pond under a river is kept in the cell (`held`) and given back
   exactly. Was: `fluid_probe`: a cut-off
   stream leaves no water; a fall into a pit never fills it; a river over a
   pond leaves its volume as it was.
4. **S2 -- done 2026-11-24.** A full still cell touching a source turns source, a cell a tick
   through the full body (no capped flood fill needed: the body turns as the rule passes on).
   Was: **S2** R9: full still water beside a source becomes source (decision B).
   Probe: a source bucket into a brim-full pond makes it heal like a lake; a
   half-full pond does not turn.
5. **S3 -- done 2026-11-24 (lakes).** An infinite body's open top -- a water source not of
   the open sea, a full course, open to the sky -- is a piece a stud riding a small wave at
   its middle (`lake_wave` in brick_fluid.cpp and water_fluid.gdshader, the same two sines on
   MineWater's clock: `now_s` / `BrickFluid.set_wave_clock`), 0.09 m at most, ramped over 5
   studs from the body's rim (`lake_amp`: a lone source, a channel, a rim stays flat and
   merged). `BrickFluid.surface_at` gives that wave from the water or the crest over it, so
   swimmers and floaters ride it (MineWater.fluid_at counts under a crest as water);
   `ray_cell` through a crest hits the source under it (R2). Rivers at the sea's level were
   the sea band's already. `fluid_probe` 14, `water_lake*.png` in `--gate=water`.
   Was: **S3** R1/R2: waves on lakes and rivers; `surface_at`, floaters and
   swimming on every body; the bucket on a crest or trough. Gate pictures of
   a lake; a probe for the bucket's aim at a crest.
6. **S4 -- done 2026-11-24.** R3: a block put where water or lava is must stand on ground
   under it or hang under ground over it (`MineBuilder.floats_on_water`; decision A: up or
   down only) -- laid sideways off a shore over water it is refused (it held nothing and
   fell). R4: where a brick goes it takes the water's place; a lake's waves calm beside it
   (the wave's ramp counts any brick as rim), so it reads as shore; broken, the body heals
   (two sources beside it and ground or source under it: the middle and the shore both,
   `fluid_probe` 14). The sea's own lapping band (11.9) stays the sea's. Sea gate: the
   `no bricks on water` line.
   Was: **S4** R3/R4: no placing on water (decision A); the beach on lakes and
   rivers; a removed brick heals. Probe: place on water refused; a 1x1 hole
   and a shore hole refill.
7. **W2 -- done** (section 6). **P -- done 2026-11-24.** A still cell resting on full still
   water seeds its body (`g_level_due`); 2 s calm, the body (connected still cells, at most
   4,096) is levelled: its units laid again from the lowest floor up, a unit layer at a time,
   through every opening (a priority flood over the cells' floors), only changed cells
   written. Left alone when open (a cell found lower than the level: the rules run it),
   joined to running or infinite water, or too big. That tick's earlier sets and moves on
   levelled cells are dropped (the apply keeps a cell's FIRST set: an edge-distance update
   had won and two units went). `fluid_probe` 15: a U-bend fills both arms to one level,
   48 of 48 units.
8. **W1** after TerrainRegions stage A; **W3**; **R10** rain and **W4** with
   the user.

Each: `fluid_probe`, `-- --gate=water`, `-- --gate=gen` where generation is
touched. Windowed gates one at a time, heat check after each (CLAUDE.md);
timing only with the editor closed. Boats (`scripts/hulls/`, HullFloat rides
BrickWave) are not in the mine world yet; when they come, they ride the same
wave query as R1.
