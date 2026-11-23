# The mine world (terrain test)

`scenes/terrain_test.tscn` is a flat, endless, Minecraft-like world built from
the brick terrain. The old fixed-field destruction bench is still there:
`-- --bench` (`scripts/terrain/terrain_bench.gd`, Docs/Terrain.md).

    godot --path . scenes/terrain_test.tscn
    godot --path . scenes/terrain_test.tscn -- --seed=123 --preset=islands
    godot --path . scenes/terrain_test.tscn -- --gate      (scripted pass, pictures in user://dev/)
    godot --headless --path . --script res://tools/probes/mine_world_probe.gd

Keys: **F** fly/walk (flying goes through everything; landing is where you
are) · **B** build mode (section 8) · **M** world generation
menu · **F3** readout · **T** one hour on · left mouse on foot (not building)
shoots, and the ground breaks where it is hit.

## 1. What is shared, not copied

| Part | Comes from |
|---|---|
| ground | `BrickTerrain` with `set_generator(1)`: `gdextension/brick/src/terrain_biomes.cpp` |
| full detail near the player | `TerrainStreamer` (as the heightfield test) |
| far LOD rings | `TerrainCoarse`, blocky at every ring (`set_coarse_smooth_step(0)`) |
| trees | `TerrainTrees` streaming mode + `Trees.scatter` callables |
| player | `FpsRig` (`scripts/pawn/fps_rig.gd`): planet.tscn's pawn on foot and `PlanetWalker` flying; planet_scene uses it too |
| light | `LightRig` (`set_sun`, `set_sky`, `expose`) |

The scene script is `scripts/terrain/mine_world.gd`; `terrain_scene.gd` only
picks it or the bench.

## 2. The generator (terrain_biomes.cpp)

Off unless a scene turns it on, so the city, heightfield test, editor and
planets keep the classic field. The mine world turns it off again when it
leaves. One column is decided at a time:

1. **Macro height** from continentalness (continents, basins), erosion (flat
   when eroded: plains) and ridged noise (mountains above the mountain
   threshold), plus dry river valleys cut to just under the sea line.
2. **Biome.** The ground picks Dry Ocean (below the sea line), Dry River,
   Beach / Snowy Beach / Stony Shore (at the coast), Stony / Snowy Peaks
   (high mountains), Windswept Hills (high, rough ground); everywhere else the
   nearest enabled land biome to the column's temperature, humidity and
   weirdness: Plains, Forest, Birch Forest, Dark Forest, Taiga, Snowy Plains,
   Snowy Taiga, Desert, Savanna, Badlands, Jungle, Meadow.
3. **Local detail.** Each land biome's hilliness, blended over nearby climate
   (no step at a border); cliff terraces where a cliff mask says so; an
   **overhang band** of 3D noise above the surface on cliffs and mountain
   flanks, so faces lean out and are undercut.
4. **Layers.** Top block, under block, second under block (desert sandstone),
   stone (banded terracotta in badlands), deep layers (deepslate by default),
   a jagged **bedrock** floor that `carve` will not remove. Caves (tunnels and
   deeper chambers), ravines, ores (coal, iron, copper, gold, redstone, lapis,
   diamond) at their depths, granite/diorite/gravel patches.

Water is off: below the sea line there is no water, only a sand floor with
gravel and stone under it.

The new materials are appended to `Material` in `brick_terrain.h` (snow,
gravel, sandstone, red sand, three terracottas, clay, bedrock, seven ores,
podzol, four grass colours, granite, diorite, ice), each on an existing palette
colour.

Cost (mine_world_probe, 2026-11-16): a tile bakes in 9-14 ms, a 4x4 coarse
block in about 3 ms, a 256 px map in about 20 ms.

## 3. Endless

The near tier already streams. The far rings were laid out round the world's
origin; `TerrainCoarse.anchor` now lays them out round any tile, and
`build_begin` / `build_poll` bake a tier without blocking. When the player is
16 tiles from the tile the rings were laid out round, a new tier is baked
round them on the workers and swapped in when done. Positions are float32;
the origin shift (section 15) keeps the eye near the global origin.

## 4. Trees

`TerrainTrees.stream(seed, chance_at, variant_at)`: cells of 128 studs within
420 m of the camera, nearest first, a few a frame; dropped past 500 m. Chance
per biome is the menu's "Trees" row; which of the four tree kinds grow there
is `BIOME_VARIANTS` in `worldgen_presets.gd`.

**Solid trunks.** The trunks of every tree cell whose middle is within
`TerrainTrees.solid_m` (64 m here) of the camera are boxes the player and
rounds meet, on PlanetTrees' layers (FIXTURE | TREE), taken away past 1.5
times that. The box and its foot are `Trees.trunk_size` / `Trees.trunk_foot`,
shared with PlanetTrees. Nodeless: one PhysicsServer body per cell, one box
shape per tree kind; only looked at again when the camera has moved 2 m. The
editor and the heightfield test leave `solid_m` at 0.

## 5. Day, night, caves

A day is 20 minutes. The sun turns, the sky and ambient follow, exposure
adapts. Nothing bakes the sun into the ground (it moves); the detail tiles
within two tiles of the player cast into the shadow map. Caves are dark by
the light in their cells (section 18): the sky's light spreads into them
from their openings, per pixel, and enclosed ones are dark. Before that one
factor from the eye's depth faded ambient, sun and sky for the whole frame
(`--no-sky-light` keeps it, for A/B). The flashlight has its own key.

## 6. World generation menu (M, or Escape > World generation...)

`scripts/terrain/worldgen_menu.gd`, modelled on the zylanntest world builder.
It edits a copy; nothing changes until **Generate world**, which tears every
tier down (waiting for bakes), sets the new params, and rebuilds round the
spawn. M or Escape closes it.

**Not F9.** It was F9, and in the editor's embedded game view F9 is the
editor's own "Suspend/Resume Embedded Project" shortcut: the menu opened and
the editor suspended the game in the same keypress. A suspended tree makes
`can_process()` false for every node, PROCESS_MODE_ALWAYS included, so the
menu took no clicks at all; F9 again resumed the game and closed the menu,
and the mouse was left as a cursor. The pause menu (Escape) is allowed here
too (`terrain_scene.gd` and BrickcityMenuHost's scene hooks) and has a
"World generation..." entry.

It opens like the pause menu (`menu/core/MenuManager.gd`): a canvas layer of
its own above everything (layer 80, process always) with a dimmed backdrop
that takes every click, the world stopped, the mouse freed and put back on
close. Two things it had to get right:

- It stops the world by DISABLING the mine world's node, not by pausing the
  tree: run from the editor the tree can be held "suspended", and then
  `SceneTree.paused` refuses to change ("Pause state cannot be modified while
  suspended") and nothing stopped. Every child -- camera, pawn, walker, gun,
  builder, streaming -- stops with the node; the menu's layer runs anyway.
- It releases the camera the camera's own way (`PlayerCamera._set_captured`):
  the camera turns on mouse motion whenever it counts itself captured,
  whatever the mouse mode says, so freeing the mouse alone left the view
  turning under the menu.

It is a `MenuScreen` (menu/core/MenuScreen.gd), sized to the window the way
the Options menu is: the presets bar sits in the header beside the title, the
status, **Close** and **Generate world** in the footer -- both outside the
scrolling body, so they are on screen at any window size; each tab page
scrolls, the row labels wrap, and the map shrinks to the height left or, on a
narrow window (under 900 px), goes under the tabs and the body scrolls.
`-- --gate=menu` opens it at 800x450 and 640x400, checks Generate world is
inside the viewport and `MenuFit.audit` finds nothing cut off, then clicks it.

Tabs: World (name, seed + Random, detail radius, view distance, height
scale), Shape (continents, hills, mountains, dry rivers, cliffs and
overhangs, Far Lands), Sea & Beach, Caves, Ores, Biomes (climate, and per
biome: enabled, climate point, blocks, depths, hilliness, trees), Underground
(bedrock, stone patches, deep layers). Beside them a top-down **map** drawn by
C++ from the menu's settings (Ground or Biomes view, zoom); click it to choose
where you start.

Presets: shipped in `content/base/worldgen/*.json` (Default, Amplified
Mountains, Flat Plains, Islands, Snow World, Desert, Far Lands), any pack's
`worldgen/` too; the player's own in `user://library/worldgen/`. A preset
only lists what it changes (`Presets.complete` fills in the rest; biomes and
ores by name).

## 7. Not yet

Flowers and tall grass, clouds, villages and structures, animals, enemies. (Falling sand: Docs/TerrainCollapse.md; water: Docs/MineWater.md; chests and the inventory: Docs/Inventory.md.)

## 8. Build mode

`scripts/terrain/mine_builder.gd`, owned by the mine world. **B** switches
the hands between the guns and the items, on foot or flying: build mode is
the items hands. What is in the hand comes from the inventory (two hotbars,
off-hand, storage; Docs/Inventory.md), saved with the world's edits.

| Input | Does |
|---|---|
| left mouse | break the block looked at (held: keeps breaking); a bucket scoops |
| right mouse | use the item in hand: place its block on the face looked at (held: repeats), pour |
| middle mouse | pick the block looked at into the hand |
| 1-9, wheel | choose a slot of the active hotbar |
| X | tap: the other hotbar; held: the other off-hand slot |
| Z | block size: 2x2, 1x1 or 4x4 studs, always one brick tall (was X) |

- Reach 6 m. The block looked at is outlined.
- A block is a terrain edit: `BrickTerrain.fill_box` writes plate cells (0
  breaks, a material places; placing only fills air; bedrock never breaks),
  then the streamer rebakes those tiles behind the old ones. A placed block is
  ground like any other: packed into pieces with its neighbours, studded,
  collided with, shot apart.
- `BrickTerrain.ray_cell` walks the stud x plate x stud grid exactly and
  returns the cell and the face it entered by; the block placed is the next
  one on the block lattice past that face, so blocks line up.
- Blocks placed above the generated ground: the field records the highest
  placed plate per tile (`highest_edit_near`), so the tile's mask and the
  surface scan reach up to them.
- While building the gun neither fires nor aims (`PlayerController.hold_fire`)
  and is put away; slot keys and the wheel go to the hotbar, not the arsenal
  or the fly speed. A block is never placed inside the player.
- Starting kit: hotbar 1 grass, dirt, stone, dark stone, sand, sandstone,
  gravel, snow, terracotta; hotbar 2 bucket, source bucket, water source,
  water brick, lava source, pickaxe. Creative: nothing runs out.

## 9. Saving changes, and what an edit costs

**Saving.** Every block broken, placed or shot away is a terrain edit, and the
world's edits are saved per seed AND generator settings (an edit means nothing
against a different field): `user://saves/mine_world/<seed>_<hash>.edits`,
zstd-compressed, header `BCME`, format 1, `BrickTerrain.get_field_version()`,
then `get_edits()`' 13-byte records. Saved every 30 s if anything changed (the
write on a worker), and on leaving the scene or generating another world (on
the main thread: those are load moments). Generating a world loads its file
before any tile bakes. The menu's World tab has **Forget changes to this
world**. A scripted pass writes to `user://dev/mine_saves/` and clears it
first.

**Saved by region (2026-11-20).** The edits are kept by 256 x 256-stud
region in C++ (each region's edited cells and a changed flag; the edit table
is still what readers look cells up in), and a save writes only the regions
edited since the last one: `<save>.regions/r_<rx>_<rz>.edits` (zstd, `BCMR`
format 1, field version, rx, rz, count, the same 13-byte records), on the
worker. It used to pack every edit of the world on the main thread each
autosave (`get_edits`: 1.6 ms at 100k edits, 16.6 ms at 1M) and rewrite the
whole file (6.4 MB at 1M); after one brick at 1M edits it is now 0.11 ms and
23 KB (mine_world_probe). A world with the old one-file save loads it, its
first save writes every region, and only then is the file removed (`--gate`
checks it). `BrickTerrain.take_dirty_regions` / `get_region_edits` /
`get_region_studs`; `last_save_ms` is the save's main-thread part.

**The edit hitch** (measured with `-- --gate`, 2026-11-17; other chats' probes
were running, so the numbers are rough):

| | worst frame | mean | tile rebuilds (rapid fire) |
|---|---|---|---|
| far tier re-baked waiting (`--sync-far`) | 24.5 ms | 16.5 ms | |
| far tier re-baked on workers (default) | 25.4 ms | 16.7 ms | |
| each edit handed over at once (`--no-coalesce`) | 24.2 ms | 16.6 ms | 106 |
| edits gathered, handed over every 0.1 s (default) | 24.9 ms | 16.6 ms | 78 |

- `TerrainCoarse.field_changed` lands every job in flight and waits for its
  bake: right for an editor's stroke, wrong in play. The mine world uses
  `field_changed_soon` (no wait; only blocks that are nodes of their own).
- A rebuilt tile's instances (studs, tufts, pebbles) stalled 11-21 ms about
  one time in 78: the tile it replaced still held its MultiMeshes until it
  was freed at the end of the frame, the pool was empty, and a never-drawn
  MultiMesh in a new node is slow to show. Now the streamer `recycle()`s a
  tile as it replaces or drops it -- its instance NODES, each with its
  MultiMesh, go to a pool at once and the next tile reuses them. The
  instances phase went from 12-21 ms worst to 0.2-0.3 ms; in the rapid-fire
  test all 78 rebuilt tiles reused pooled nodes. Tiles also build only the
  stud set they show (near or far) and the other when they first switch.
  `TerrainTile.profile_instances` times each step; the pass prints it.
- After that, an edit costs nothing measurable: 180 frames with no edits had
  a worst frame of 23.8 ms and 69 over 20 ms; 180 frames of rapid fire, 25.8
  ms and 65 over 20 ms. Those ~24 ms frames are this machine's frame pacing
  with the test window off-screen and other tests running, not the edits.

**The flicker round an edit (fixed 2026-11-20).** A tile an edit rebuilt went
in at once as the new tile's flat surface with no studs, tufts or pebbles (the
old tile's were recycled into the pool), the studs came back a few frames
later and the chamfered near mesh later still: bevelled, flat and bare,
studded, bevelled. Now a refresh bakes its chamfered mesh in the same worker
job, the new tile is made hidden and finished a step a frame (bevel, then
collider) while the old one is still drawn and collided with, and the two swap
in one frame (`TerrainStreamer._swaps`, `_swap_step`): the old tile's instance
nodes go to the pool and the new one fills them, it is shown, the old one goes.
`--gate` counts frames with a near tile drawn flat or bare
(`bare_near_tiles`): 0 of 300 edit frames. Swapping whole in ONE frame was a
5.2 ms step; staged, the worst step is 1.1 ms (it was 1.0 before).

**The hesitation after a break, measured and cut (2026-11-21,
`-- --gate=breaklag`).** Each stage of a broken brick timed, from the shot
to the new tile drawn:

| | found | baked | swapped | total |
|---|---|---|---|---|
| 1 brick, before | 16 | 38 | 33 | 87 ms |
| 3 bricks at once, before | 22 | 145 | 35 | 201 ms |
| 1 brick, now | 12 | 22 | 2 | 37 ms |
| 3 bricks at once, now | 14 | 40 | 4 | 58 ms |

- Three bricks chained whole-tile bakes: a second edit marked the running
  bake stale, waited for it, and baked again. Now each refresh counts the
  tile's generation up and starts its own bake at once, beside the older one;
  a bake lands only if it is newer than the last that landed
  (`TerrainStreamer._gen` / `_slot_gen` / `_landed_gen`).
- The edits were gathered 0.1 s (`REFRESH_EVERY`): the second and third brick
  waited that long. 0 now: handed over the frame they land; one frame's edits
  still make one bake a tile.
- The flat and the chamfered near mesh bake on two tasks, not one after the
  other.
- The chamfer goes on in the frame the bake lands, the collider and the swap
  as soon as the budget allows (usually the same frame); it was two frames.
- Still the edit gate's frames: worst 23.3-23.5 ms against 22.8 idle, worst
  step 1.5 ms, flicker 0 of 300. Rapid fire bakes more tiles (42 for 30
  shots, was 30): workers' time, not the frame's.
- Left: finding the brick (12-22 ms: one or two frames, find_brick samples
  and packs the whole tile on a worker).

**Sections were measured first, and are not the edit cost** (2026-11-20, quiet
machine, 71 C start): `--gate`'s 12 shots and 30 rapid-fire shots beside the
player rebuilt 42 whole tiles and no frame was worse than an idle frame
(worst 23-24 ms both, mean 16.6 ms); the worst main-thread step of a rebuild
was 1.0 ms. Splitting a tile into sections would cut a cost that is not there
(and multiply the near tier's draws, ~300 a frame now). The lag the user sees
breaking bricks has to be found where it is: beside running water, with the
collapse surveying, debris bodies, a paging machine (LOW RAM in heat_sum).

**Breaking beside running water, measured** (`-- --gate=breakwater`,
2026-11-20, 70 C start, editor closed; another chat's headless probe was
running): four sources poured on the ground ahead, then 120 shots into the
ground beside and under the water (1026 edits, 214 tiles rebuilt, 60 collapse
surveys, water flowing into the holes).

| window | mean | worst | over 25 ms | main thread (process) | draw | GPU | world's own parts |
|---|---|---|---|---|---|---|---|
| water only | 16.6 | 27.0 | 7 of 240 | 2.6 | 13.5 | 12.5 | 1.1 |
| shooting into it | 16.7 | 26.0 | 5 of 480 | 3.0 | 13.2 | 12.7 | 1.4 |
| settling | 16.7 | 25.9 | 4 of 240 | 2.4 | 13.7 | 12.4 | 1.0 |

Shooting into water costs the frame nothing measurable: every worst frame is
the renderer (draw 21-23 ms with the GPU at 15-18 ms), with or without shots.
The water's worker tick reached 70 ms while shooting, on its own thread (the
frame never waits: lock wait 0.00 ms). The frame is GPU-bound -- 12.5 ms of a
16.6 ms frame on this machine before anything happens -- so what lags in play
is what pushes the GPU over: the chip clocking down hot (heat_sum's held
back), the editor's game view (frame times several-fold), paging on low RAM
(heat_sum's LOW RAM: 350-520 ms stalls), and GPU load (67 lava lights were live
in this run). The F3 readout's slow-frame line says which: small world parts
in a slow frame mean the time went outside the world.

## 10. Shots break whole bricks; flying

**Whole bricks.** A shot breaks what a LEGO player would expect: the surface
piece it hits, all of it (a 2x4, a 2x6 ...), when the hit is in a column's top
course; one brick cell (a stud by a brick) on a wall or a cave face; never
bedrock. The brick flies off as a body (`terrain_debris.gd`, shared with the
bench). It used to carve a sphere of plate cells, which cut bricks in pieces.

- `BrickTerrain.find_brick(point, normal)` samples and packs the hit tile to
  find the piece (~10 ms), so it runs on a WORKER; the main thread applies
  `clear_runs` a frame or two later (`MineWorld._land_breaks`).
  `break_brick` does both at once, for probes.
- **No re-laying round a hole.** The packer gave columns next to a hole no
  studs (their neighbour was lower), so it cut them differently and the
  ground round every shot looked rebuilt. `TileSample.gtp` keeps each
  column's generated top: an untouched column judges an edited neighbour by
  its generated top, so it is laid exactly as before; an edited column gets
  studs when nothing beside it stands higher (a placed block, the floor a
  shot opened). mine_world_probe: 157 of 157 other pieces in the tile kept.

**Flying.** Collision is off entirely while flying (the walker's layer and
mask are 0). The pawn's camera stays the one drawn, moved with the flight
every frame, so the arms and gun come along (`FpsRig.switch_mode(...,
keep_view)`, `follow_flight`). planet.tscn does the same since 2026-11-17
(`planet_scene._process`; `view_camera()` says which camera should be drawn:
the ship's in the seat, else the pawn's); `-- --gate=pawn` checks it.
Landing puts the pawn exactly where the flight is -- in mid-air it falls --
unless that is inside the ground, then on top of it.

## 11. Why the bricks looked fuzzy

Not a texture, and not the printed-plastic pattern: SHADOW ACNE. The mine
world let the ground cast into the sun's shadow map (the sun moves, so its
shadow cannot be baked into the ground as the heightfield test bakes it), and
a brick top shadowing itself drew a fine diagonal grain over every lit
surface, the soft-shadow filter's noise on top. Measured with
`-- --gate=look --look=parts` (the same close view with each of the terrain
shader's effects off in turn, then the sun's shadow off): only the shadow
made the difference.

- The ground no longer casts sun shadows (`TerrainStreamer.shadow_radius
  -1`). Trees, the player and debris still cast onto it. Underground, the
  sun fades with depth as the ambient does, so caves stay dark.
- `TerrainTile._add_surface` now honours the tile's shadow choice: the
  chamfered near mesh lands frames after the tile is built and cast whatever
  the tile said -- in every scene with terrain, not just this one.
- FXAA (the Options menu's default) softens fine detail a little on top;
  `-- --gate=look` takes the view with it on and off.
- The printed surface itself is drawn by the shaders (layer lines, nozzle
  paths, `print_surface.gdshaderinc` and a baked bead texture); leaf bricks
  use the leaf texture, which is soft when seen from inside a crown.

## 12. Testing

| Pass | What it checks |
|---|---|
| `tools/probes/mine_world_probe.gd` (headless) | generator, biomes, ores, bedrock, blocks, whole-brick breaking, saves |
| `-- --gate` | spawn, flight (no collision, arms follow), endless far rings, holes, menu stops the world, build, landing, edit frame times, save round trip |
| `-- --gate=deep` | the deep tier: into a cave 78 m down, sections load, land and stand, the seam |
| `-- --gate=shift` | origin shifts on a 1.2 km flight: no holes, lands, builds, falling ground in place |
| `-- --gate=stop [--walk]` | the 8 s after stopping, quarter-second windows: frames, GPU, each system, what each tier did |
| `-- --gate=mega` | the Mega Pickaxe against the pickaxe: cells per break, repeat |
| `-- --gate=spawn` | the first new ground after a world is made: frames, instance nodes new vs reused |
| `-- --gate=flight` | fast flight: worst frame, frames over 33 ms, what each slow one spent |
| `-- --gate=cave` | land in a reachable cave, still standing 200 ticks later |
| `-- --gate=menu` | the generation menu and the pause menu clicked with real mouse events |
| `-- --gate=look [--look=parts]` | the close view under different settings (the fuzz hunt) |

## 13. Cave floors are collided

Flying into a cave and landing, the pawn fell through a floor of bricks it
could see. `build_tile`'s collider follows each column's TOP: merged boxes
from the top a brick (or to the lowest neighbour) down. A cave floor, the
ground under an overhang, a tunnel's walls -- everything under a column's top
-- had no box at all.

Now `build_tile` also collides every solid plate cell under its column's top
box that touches OPEN air (the air the mesher draws faces against: sealed
chambers are neither drawn nor collided), or lies within a brick under a
floor, merged greedily along x, then z, then up. A box may grow through any
cell that is not open air (rock, a sealed chamber), so the rock round a cave
is a few large boxes; floors are at least a brick thick. A column only looks
at its cells when it or a neighbour has open air under its top, so tiles with
no caves pay nothing.

- mine_world_probe, 40 tiles: 584 of 584 cave floors inside a box; ~260 cave
  boxes in a cave tile (the shell alone, without growing through rock, was
  ~400; up-first merging ~10% more); a tile bakes in about 13 ms
  (`cave_box_count` in the result).
- `-- --gate=cave` (also inside `-- --gate`): finds a cave the player can
  reach near the spawn, flies in, lands, and checks the pawn is still on the
  floor 200 physics ticks later (STANDING / FELL).
- The mask reaches down to the deepest cave a column can have (`low_p`), so a
  cave never runs out of the bottom of it (the second suspect).

## 14. Fast flight: detail held, far tier swapped in slices

`-- --gate=flight` flies 1.44 km at ~100 m/s and prints the worst frame,
frames over 33 ms, and what each slow frame spent (2026-11-17, equal start
temperature 59-63 C):

| | worst | over 33 ms |
|---|---|---|
| before (`--no-fast-hold`, old swap) | 103 ms | 14 |
| detail held above 80 m/s | 70 ms | 13 |
| + far tier assembled in 2 ms slices | 42 ms | 2 |

- **Hold** (after zylanntest's DynamicLodController): above
  `FAST_HOLD_MPS` (80) the near tier starts no bakes, adds no studs, chamfer
  or collision and switches no stud sets; the far tier starts no refine or
  relod; below `FAST_RESUME_MPS` (40) everything resumes. Default flight (50
  m/s) is not held; Shift is. F3 shows "DETAIL HELD".
- **The real spike was the far re-anchor**: swapping in a new tier did all
  its meshes in one frame, mostly `_offset_surface` (a GDScript loop over
  every ring vertex). Ring blocks are now offset on the worker and
  `build_poll(budget_ms)` puts the meshes in a slice per frame while the new
  tier is hidden.
- **The first new ground** after a world is made (`-- --gate=spawn`: 600
  frames at 30 m/s from the spawn, under the hold). The pool was empty until
  tiles dropped, and the resident set grows from the first square to its full
  240 tiles, so 194 far-stud, 185 pebble and 45 near-stud nodes were made new,
  never drawn, and stalled the render thread. `TerrainTile.prewarm_begin` /
  `prewarm_end` now fill the pool while the world is made (220 / 220 / 56 /
  32 nodes, one invisible speck each in view for 3 frames, ~330 ms at load;
  `--no-prewarm` for A/B). Every node is reused; the worst instance step went
  from 36.5 to 0.3 ms, the worst frame 69 -> 55 ms, frames over 33 ms 11 -> 5
  (similar start temperatures, 51 and 53 C; what is left is not the pool).
- **"The fps drops for a few seconds after I stop"** (the user, 2026-11-19,
  playing in the editor). `-- --gate=stop` (flies 8 s at 50 m/s, or `--walk`:
  15 s at 6 m/s at eye height) then prints the 8 s after stopping in
  quarter-second windows: worst/mean frame, GPU, the main thread's parts,
  near / deep / far / trees / water / ground collapse, triangles, draws, lava
  lights, and what each tier did. Standalone, nothing catches up after a stop
  (0 tiles, 0 chamfer meshes, 0 far swaps, 0 deep sections in every window);
  frames stay at 16.6 ms mean with ~12 ms GPU (1280x720). One run's GPU
  crept to 15-16 ms while standing, the same scene a cooler run held at 12-13:
  the chip clocking down, near the 16.6 ms vsync line, where one miss shows
  as 33 ms. Not reproduced outside the editor; the F3 readout now has a "slow
  frames" line (frames over 25 ms in 10 s, and the world's own parts in the
  last one -- small parts mean the GPU, the editor or vsync). Tufts are
  pre-filled like the rest now (220): the flight's worst instance step was
  118 ms in a grassy spot.
- With the stud-set switch held too (and the pool pre-filled), `--gate=flight`
  at 58 C: worst frame 30 ms, none over 33 ms during the fast flight (42 ms
  and 2 before); slowing down after it, 42 ms worst, one over.

- **Walking, the re-anchor waited on the workers** (2026-11-21, the
  collapse chat's `--gate=stop --walk`, quiet machine): one frame of 57-62 ms
  in every walk, 52 of it process time, 42-44 ms in `_follow_far`. The swap
  called `cover(_streamer)`, whose default `wait` finishes every split round
  the detail on the spot: 29 ms of `_job_wait` on the main thread. The new
  tier now lands its splits while still hidden, `cover(.., false)` a frame,
  and swaps in when `refining()` is false. Worst walking frame 41 ms (swap
  7.8 ms). Left in that frame: one `_rebuild_ring` in `build_poll(2.0)`,
  14 ms -- a merged ring is the smallest slice, so the 2 ms budget could not
  hold; each ring (~48 blocks, ~200k vertices) was 6-9 ms of
  `add_surface_from_arrays`. Now the rings' meshes are made on the worker
  pool once the bakes are in (`_start_ring_meshes`, for a new tier and for
  every split that lands) and the main thread only attaches them: walking,
  **0 frames over 33 ms**, swap 1.9 ms, GPU median 8.2 ms (quiet machine,
  72 C peak). Fast flight is held (no refines), so `--gate=flight` is
  as before: 34 ms worst, 1 over 33 ms, 0 holes (70-82 C, warmer than 58).

## 15. The ground comes down

What an edit leaves hanging falls: loose ground as pieces (they stay, are
unloaded past the detail tiles and saved with the world), sand and gravel
straight down like Minecraft's, landing as ground again. The buildings'
stress rules on virtual bricks; Docs/TerrainCollapse.md. Gate:
`terrain_test.tscn -- --gate=collapse`; probe `terrain_collapse_probe`.

## 15. Origin shift

Positions are float32: past ~20 km from the origin the precision shows. When
the eye is `shift_at` (4 km) from the global origin, the mine world node
moves back by whole tiles, with `PlanetFrame.shift` (the node half of the
planet's `recentre`, without its WorldFrame: the mine world keeps its own
`origin_shift`). The planet's way, so nothing inside has to know:

- Every child of the mine world -- tiles, far rings, trees, water, ground
  collapse pieces, debris, the player -- keeps its LOCAL position, and the
  local frame is the TERRAIN frame the field is laid out in (integer studs
  and plates, which never move). Only global positions change.
- So only two kinds of code had to change: a global position used as a
  terrain one takes `to_local` (`_eye()` is the terrain eye, `_eye_render()`
  the drawn one; a shot's hit point; the builder's ray and the player box;
  the pawn's water probes; TerrainTrees' camera), and a terrain position used
  to place a node takes `to_global` (`_fly_to`, the builder's outline,
  landing).
- Nodeless bodies follow their node: a tile's collider and the trunks' bodies
  update on NOTIFICATION_TRANSFORM_CHANGED.
- Whole tiles, so anything patterned on the stud lattice in world space (the
  printed surface, the grid light) lines up as before.
- Ground collapse (ground_collapse.gd) keeps PlanetPieces' frame, where chunk
  transforms are GLOBAL: a new piece's transform is the terrain one through
  the mine world's transform, a piece's tile comes from `to_local` of its box,
  and the put-away distances use the global eye (`_eye_render`). The shift
  gate drops a block after five shifts: the piece lands where it was.
- `-- --gate=shift` lowers `shift_at` to 300 m and flies 1.2 km: 5 shifts,
  the eye 4 m from the global origin, no holes, the pawn lands and stands, a
  block placed where looked at (2026-11-18).

## 16. Deep worlds

Goal: 300 bricks (126 m) of world under the sea line before the bedrock,
caves all the way down.

**Stage 1, built (2026-11-18): the depths.** `bedrock_m` -48 -> -126 m.
Everything laid out for the 48 m world is stretched to it (x 2.625 below the
sea line): deepslate from -42 m (a third of the way down, as before); ores
coal -52..70, iron -105..30, copper -52..20, gold -121..-31, redstone
-126..-63, lapis -118..-21, diamond -126..-84 m. The menu's ore sliders reach
-200 m. mine_world_probe finds every ore between the sea line and the
bedrock. A different default means a different settings hash, so edits
saved against the old default stay with the old world. Caves are still
generated to 18 m under the surface: digging down reaches the new depth (a
tile's mask follows what is dug), caves do not yet.

**The cost of deep caves in today's tiles** (bake per tile, 24 tiles, no other
Godot running, 2026-11-18):

| caves to | ms a tile | triangles | boxes |
|---|---|---|---|
| 18 m | 13.9 | 4,640 | 476 |
| 30 m | 21.0 | 6,733 | 638 |
| 45 m | 29.9 | 9,382 | 839 |
| 60 m | 36.9 | 11,254 | 986 |

Linear: about 0.55 ms, 170 triangles and 12 boxes per metre of mask. Caves
to the bedrock under a surface tile (~140 m of mask) would be ~80 ms, ~25k
triangles and ~2,000 boxes a tile, for 49 near tiles, almost all of it
underground and unseen. So the surface tiles keep their shallow mask.

**Stage 2, built (2026-11-18): the deep tier** (`scripts/terrain/terrain_deep.gd`,
`BrickTerrain.build_section`, `set_deep_tier`, `deep_top`). As designed below,
with these results and details:

- `deep_caves` (default on, the menu's Caves tab): below `cave_max_depth_m`
  the same caves go on to three bricks over the bedrock, chambers growing
  rarer over the first 10 m (at full strength a quarter of the underground was
  air; now a fifth).
- mine_world_probe: a tile draws nothing under its floor, a section nothing
  outside its plates; 636 of 636 deep cave floors inside a section's collider.
  A section bakes in ~8.7 ms (2,200 triangles, 175 boxes); a surface tile
  ~16 ms (13.9 before: caves no longer thin out at its floor).
- The tier loads only while the eye is 30 plates under its column's surface:
  5 x 5 tiles by 3 sections round the eye, 4 bakes in flight, a 1.5 ms node
  budget, colliders within a tile and a section of the eye. Sections are
  drawn by TerrainTile (build_section returns its keys). A section out of
  range goes only after 0.6 s.
- `-- --gate=deep`: flies into a reachable cave 78 m under the surface, 69
  sections in 62 frames (worst 38 ms, one over 33), lands and stands; then a
  picture across a tile's floor for seams (none seen).
- Found on the way: landing from a flight, the pawn's camera flashed back for
  ~4 ticks to where the pawn was left (its interpolated position had not
  caught up with the teleport; the body is disabled while flying). The deep
  tier followed the flash and dropped the floor under the pawn.
  `Pawn._origin_interpolated` now uses the real position when the two are
  over 8 m apart -- the flash is gone in every scene.

The design it follows:

- A tile column's surface mask ends at a fixed plate B(tile) computed from
  the generator alone (lowest generated surface in the tile minus the
  shallow cave depth), never from edits. Below B is the deep tier's.
- A section is 32 x 32 studs by 96 plates (32 bricks, 13.4 m): about the
  cost of 13 m of mask, ~8-9 ms. Sections load round the EYE in 3D (a few
  tiles across, a couple of sections up and down), only below B, so a player
  on the surface loads few or none; underground, the tier follows them.
- Caves become absolute-depth (down to just over the bedrock); the cave rule
  is one function of (x, y, z), so a cave crossing B is simply drawn half by
  the tile and half by the section.
- Seams: both sides sample one plate past their boundary from the field for
  their faces (today a mask treats below itself as rock and above as air),
  and the open-air fill seeds all six sides of a section and the bottom of a
  tile, conservatively.
- Edits below B are the section's: the tile mask stops following deep digs.
- Collision: the cave colliders (section 13) per section, within the collide
  radius; sections take the same hold while flying fast (section 14) and
  live inside the mine world node (section 15).


## 17. Where the GPU goes (`-- --gate=gpu`, 2026-11-20)

The frame is GPU-bound (section 9's breakwater run: 12.5 ms of 16.6 vsynced).
`--gate=gpu` runs flat out (vsync and the fps cap off in memory, never saved:
a vsynced iGPU clocks down to fill the frame) and switches each suspect off
in turn against a baseline taken just before it, from two views. Four runs,
editor closed, 63-75 C starts; baselines drift run to run (7.8-9.0 ms on
foot at 1280x720, render scale 0.75), the rows' deltas held:

| switched off | on foot | 25 m up |
|---|---|---|
| (baseline GPU) | 7.8-9.0 | 6.1-7.5 |
| trees hidden | -4.1 to -4.6 | -2.9 to -3.5 |
| of which the NEAR (brick) trees | -3.6 to -4.2 | -2.5 to -3.0 |
| of which the cards | -0.1 to -0.5 | -0.4 to -0.6 |
| sun shadows off | -2.9 to -3.0 | -2.1 to -2.2 |
| shadow 4 -> 2 cascades | -1.3 to -1.5 | -0.7 to -1.3 |
| sea hidden | -0.9 to -1.2 | -0.8 to -1.3 |
| studs, tufts, pebbles hidden | -0.3 to -0.7 | -0.2 to -0.7 |
| near tiles / far tier hidden | -0.5 / -0.1 to -0.7 | about -0.6 / -0.5 |
| mesh LOD threshold 1 -> 4 px | -0.5 | -0.2 |
| day/night not written, sky radiance, glow, lava lights, deep tier | about 0 | about 0 |

- **Done: two shadow cascades**, the first 12 m (`directional_shadow_split_1`
  0.1): -1.1 to -1.4 ms, shadows round the player as fine as before.
- **The near trees are half the GPU.** Not their shadow pass by itself: a
  shadow-only twin with the opaque material (the near material fades by
  dithering, ALPHA + scissor, so it is alpha-tested) moved their shadow row
  from -2.6 to -0.8 ms yet left the trees' total cost where it was, and was
  taken out again. What is left to decide is a look: how far real brick
  trees reach before the cards (ImpostorLod `near_range`, 40 m), or how many
  trees there are.
- **The day/night's per-frame sky write** costs nothing measurable on the GPU,
  but it compounded: the cave factor was multiplied into the ambient and the
  sky's energy every frame while set_sky wrote them only when the sky changed,
  so underground they faded towards nothing and stayed wrong after the cave
  until the sky next changed. Fixed: the factor applies to what set_sky last
  wrote (`_amb_base`, `_sky_energy_base`), and the sky is written only when the
  product changes.
- The sea (about 1 ms) is the water's (Docs/MineWater.md).
- **Done: real brick trees to 25 m, cards past it** (`TerrainTrees.near_m`,
  the mine world's `TREE_NEAR_M`; it was 45; `-- --tree-near=N` to compare).
  `--gate=gpu` at 45 then 25 m, same views, both started at 62-63 C, two
  cascades in both: baseline GPU on foot 7.01 -> 5.50 ms (-22 %), 25 m up
  5.75 -> 3.93 ms (-32 %); the trees' share on foot 3.0 -> 1.7 ms. The view
  from 25 m up looks the same (`user://dev/mine_gpu_up_near45.png` /
  `_near25.png`); on foot inside a forest is the place a card could show.
  The heightfield scene keeps 45.

## 18. Sky light in the cells (2026-11-21)

Section 5's cave light was ONE factor a frame, from how far the eye was under
its column's top: it scaled the ambient, the sun and the sky for everything
on screen. Standing in a cave mouth darkened the sunny world outside, nothing
was lit locally, and cave interiors were dark only because of that global
fade (the ground casts no sun shadow, section 11). Now the light lives in the
cells, as in Minecraft. `--no-sky-light` is the old factor, for A/B.

**The light (C++, `brick_terrain.cpp`, `sky_light_pass`).** A light cell is
one stud by one course (3 plates); it is OPAQUE when all three of its plates
are solid (a one- or two-plate top course lets light through). Every column
is lit at level 15 from the sky down to its first opaque cell (its sky
floor); from there light spreads to the six neighbours, one level less a
step, through cells that are not opaque: a bucketed breadth-first fill,
levels 15 to 0, so light reaches 15 studs or courses (about 5-6 m) into a
cave mouth, and all the way down an open shaft. It runs in the tile bake
(`build_tile`, and with it `build_tile_chamfered`; the deep tier's
`build_section`) after the mesh is made, so every face path gets it at once.

- **Per vertex, smooth.** A vertex reads the light half a cell out along its
  normal, blended over the eight cell centres round that point, opaque cells
  left out of the weights. A face corner then averages the four air cells
  that meet there (Minecraft's smooth lighting); inside corners come out a
  little darker.
- **Exact at the seams.** A cell's light depends only on cells within 15
  steps, so the fill covers the tile plus 17 studs and the mesh's courses
  plus 17, reading the field past the sample the way `BondView` does (the
  sample where it reaches, `biome_cell` and the edits past it, columns kept
  as they are worked out). Seeds are the sky cells within 15 of the cells the
  vertices read that are under their sky floor, and no step is taken where
  even full light could not reach one of them any more. In the deep tier a
  column's sky floor is settled by the first opaque cell above the box (one
  cell nearly always), not by a scan from the surface.
- **Carried in CUSTOM0.a**, a byte that was always 255: no new vertex channel,
  nothing more to upload. `BrickTerrain.set_sky_light(true)` turns the pass
  on; only the mine world does, so every other scene's mesh is the same.
- **The eye's level**, `BrickTerrain.sky_light_at(point)`: a fill backwards
  from the eye's cell through open cells, the first sky cell met at d steps
  giving 15 - d, the same answer the bake gives (0.15 ms in a dark cave,
  asked when the eye changes cell or every 0.5 s).

**The shader (`terrain.gdshader`, `#ifdef SKY_LIGHT`).** The mine world draws
its ground with a copy of the shader with `#define SKY_LIGHT` in front
(`TerrainTile.ground_material(sun, true)`, like ImpostorLod's fading copy);
every other scene compiles the file as it was. In the copy the level maps to
a brightness by Minecraft's curve, `0.8^(15 - level)`, run from
`sky_light_floor` (1.5 %, the old `CAVE_DEEP_LIGHT`) to 1, and per pixel:

- `AO` = the brightness: the ambient.
- `SPECULAR` x sqrt(brightness): the sky's REFLECTIONS ignore AO (a level-0
  cave measured 0.033 without them, 0.079 with); they scale with f0 = 0.16 x
  SPECULAR^2 and their grazing part with clamp(50 f0), so this takes them
  down about as AO takes the ambient (0.034 with, after).
- the SUN, in a `light()` that writes out the engine's own Burley diffuse,
  Schlick-GGX specular and rim, scaled by the brightness squared for
  directional lights only: a lamp, a lava glow or the flashlight in a cave
  lights it as the engine would. The surface pictures of `-- --gate` with and
  without sky light differ by 0.4-2 grey levels of 255 (mean absolute).
- `--sky-debug=1` draws the vertex light flat, `=2` the AO.

**The global factor is retired.** `_day_night` (`_eye_lights`) no longer
scales the ambient, the sun or the sky, and no longer turns reflections off:
the environment is the open air's, so the sky, trees, water and everything
else outdoors look the same from a cave mouth as from outside. What follows
the eye's level (eased over 0.25 s):

- the exposure (`LightRig.expose`'s `light_scale`), so the eye opens up in a
  dark cave (EXPOSE_MAX 2) and the day looks a little bright from inside;
- the first-person gun and arms, which are always where the eye is: off the
  open sky they move to their own render layer (`HELD_LAYER`, 1 << 11), where
  an interior ReflectionProbe riding the camera (LightRig's ambient box
  pattern, `reflection_mask` that layer only) gives them the eye's share of
  the ambient and no sky reflections, and the sun skips them for a shadowless
  twin at the eye's share of the sun. (A multiply overlay was tried first: it
  drew nothing over the gun.)

Edits re-light through the tile refresh, which rebakes the edited tile and
its neighbours (light reaches 15 studs, a tile is 32).

**Measured (2026-11-21).**

| | |
|---|---|
| the pass, a surface tile | 3.4 ms on the worker (tiles bake in ~14-17 ms; 12 of 12 had dark cells) |
| the pass, a deep section | 2.0 ms |
| seams (mine_world_probe) | 0 of 378 tile-tile vertices differ, 0 of 76 tile-section |
| `--gate=cave`, 15 m down, enclosed | dark, shapes just visible; the old factor gave this cave 8.5 % and it read as a dim street |
| `--gate=deep`, 78 m down | picture mean 0.044 (old 0.051); ambient and sun add nothing |
| `--gate=mouth`, 4 studs into a tunnel looking out | centre 0.661 vs 0.607 with no tunnel (eye level 10, exposure 2) |
| `--gate=mouth`, its walls | 0.446 by the mouth, 0.066 by the back (level 1) |
| `--gate=gpu`, baseline GPU on foot / 25 m up | 5.48 / 3.89 ms with sky light (62 C start), 5.48 / 3.73 without (57 C); the near tiles' own share 0.75 vs 0.40 ms on foot (the `light()`), editor closed, nothing else running |

**Not in it.** Collapse pieces, dropped items and chests were lit by the
open-air environment wherever they were, so in a cave they glowed brighter
than the walls: section 19 gives them their own cell's level. Studs,
tufts, pebbles and the bricks in curved ground are instances in their own
material and stay sky-lit; they stand on tops, which are sky. Water passes
light freely. A one-course slab (found building the tunnel for
`--gate=mouth`) had no underside: its course is the columns' top, drawn as
top pieces, and the face mesher left every face of a piece's brick to the
piece, which draws none below. `mask_faces` now draws a piece's downward
faces itself, merged per piece; the tunnel's roof is one course again, and
`terrain_probe` (`_check_thin_roof`) checks the underside's area.

**Block light from lava (2026-11-21).** Minecraft's second light, beside
the sky's, in the same cells and the same bake (`sky_light_pass`):

- **The fill.** Every lava cell is a seed at level 15; light steps to the six
  neighbours one level less through cells that are not opaque (sky cells
  too: block light ignores the sky). Exact at the seams the same way: it
  answers for every open cell a vertex reads, seeds within 15 of them, no
  step where it could no longer arrive (`SkyGrid::fill_block`). Per vertex,
  the same eight-cell blend.
- **Carried in CUSTOM0.g**, as bytes 0..60 (`BLOCK_BYTE`). G is the far
  meshes' smooth-ground flag (128 blocky, 255 smooth, read as `> 0.25`);
  near tiles and deep sections always wrote 0 there, so block light stays
  under 64 and no other scene's shader sees it. A tile with no lava near
  writes nothing.
- **The lava cells come from the water** (`BrickFluid::lava_cells_in`, C++
  only): under the water's `g_state` for a moment, reading only sections
  with lava (a per-section count, `Section::lava`) and only columns the
  water has read from the field. What glows is what is drawn: a generated
  lava pool lights its cave once a tile coming near primes it. No lava
  anywhere, no lock (`lava_total`). The bake takes no terrain lock, so the
  water's worker (which holds `g_state` while it samples the field) and a
  bake cannot wait on each other.
- **Lava changing relights the ground.** The water marks every terrain tile
  within 16 studs of a lava cell that came or went (write_cell, and a
  column read with generated lava), with its courses +-16; `take()` hands
  them over as `"lava_light"` (tx, tz, first plate, last plate). The mine
  world gathers them and every 0.5 s (`LAVA_RELIGHT_EVERY`: running lava
  changes cells twice a second) rebakes the deep sections over those
  plates and the drawn tiles whose light grid reaches them (the bake's
  `light_lo` / `light_hi`): priming a deep pool asked for 185 surface tiles
  in `--gate=water` before that filter, 25 after. No collapse, no far tier.
- **The shader** maps it by the same curve as the sky's and draws it as a
  warm glow x albedo, `EMISSION += block_light_colour (1.0, 0.52, 0.22) x
  albedo x brightness x block_light_energy (1.0)`, and it lifts the AO to
  `max(sky, block x block_light_ao (0.5))`, so a lava-lit wall takes some
  ambient too. `--sky-debug=3` draws the block light flat.

| | |
|---|---|
| the pass, with lava in reach | 0.1-0.2 ms a tile, 0.04-0.07 ms a deep section (the lock and the fill) |
| seams (mine_world_probe) | 0 of 14 lit tile-tile vertices differ, 0 of 16 deep section-section |
| fall-off | a cave floor's 158 vertices all within one byte of `15 - steps` blended (worst 0 of 60) |
| `--gate=deep`, a 3 x 3 pit of lava 5 studs ahead | picture mean 0.085 (the dark cave 0.044); block light off 0.048; the water's 26 lava lights hidden 0.084 |
| `--gate=water`, the lava pool at night | 0.289 with the lava lights, 0.235 block light alone |

**The water's per-tile OmniLights stay**, for now. Underground they add
nearly nothing over the block light (0.085 vs 0.084), and they cost about
nothing on the GPU (section 17's "lava lights hidden"). But they light what
the cells do not: studs, tufts, pebbles and the bricks in curved ground
(instances in their own material), the wood block in the pool, pawns,
drops, chests, the gun -- in the night pool without them the studs round
the lava are dark discs on warm tops (`water_lava_night_nolights.png`).
With both, the ground near lava is lit twice. Taking them away needs those
lit some other way (a block-light level per instance, like the gun's sky
level); a cheaper middle step is to take the ground out of their
`light_cull_mask`. The water area's call (MineWater.md 6).

**Taken (2026-11-22, the water area):** the middle step. Ground drawn with
the SKY_LIGHT shader goes on render layer `RenderLayers.BLOCK_LIT` (1 << 12,
TerrainTile._add_surface) and the lava lights' cull mask leaves it out, so
it is lit once, by its cells; studs, props, pawns and drops keep the lights.
Bullet-hole decals take that layer too. `--gate=water` night pool: 0.265 with
the lights, 0.249 without (was 0.289 / 0.235); the studs round the lava stay
lit.

**Checks.** `-- --gate=cave`, `-- --gate=deep --light-sweep` (now also
"reflections on"), `-- --gate=mouth` (new: a tunnel built on the ground, the
day seen from inside against no tunnel, its walls by the mouth and the back),
`-- --gate` with and without `--no-sky-light`; `mine_world_probe`
(`_check_sky_light`, `_check_block_light`: no lava no light, a cave dug
across a tile seam and again across two deep sections with lava put in it,
both sides agree, the floor falls off a level a step, `take()` names the
tiles, gone once the lava is), `terrain_probe`, `fluid_probe`; `-- --gate=deep`
(now with a lava pit: `mine_deep_lava.png`, `_nolights`), `-- --gate=water`
(`water_lava_night_nolights.png`); `-- --gate=gpu` against section 17.

## 19. Sky light on things (2026-11-22)

Section 18 lit the ground's cells; everything else kept the open-air
environment, so a collapse piece, a dropped item or a chest in a closed cave
glowed against black walls. Now each takes the sky light of the cell it is
in (`scripts/terrain/mine_sky_lit.gd`), and in a dark cave it is
as dark as the walls round it.

**Copies of the materials, a level per node.** The mine world draws them with
copies that read an `instance uniform float sky_level` (0..15), made only
there (`MineSkyLit`, made when sky light is on), so every other scene, and
the mine world's near trees, which share the pieces' brick material, draw as
before:

- the collapse pieces (their mesh and their studs) with `brick.gdshader` plus
  `#define SKY_LIT` (`MineSkyLit.brick_material`, a duplicate of the mine
  world's `_brick_mat`, registered with WeatherFx like it);
- ItemIcons' models (drops, chests) and the sand boxes that landed on a piece
  with `shaders/sky_lit_item.gdshader`, StandardMaterial3D's look (colour,
  roughness, alpha, glow; specular 0.5) written out, one material per look
  (`item_material`), `#define ITEM_ALPHA` for the see-through ones.

Both include `shaders/sky_lit.gdshaderinc`, which does what terrain.gdshader's
`#ifdef SKY_LIGHT` block does, from the node's level instead of the vertex's:
the same curve and uniforms (`MineWorld.sky_brightness`), `AO` x the
brightness, `SPECULAR` x sqrt(brightness) (and for a brick, `METALLIC` too:
a metal's reflections take f0 from its albedo), and a `light()` that writes
out the engine's Burley diffuse, Schlick-GGX specular (the brick's
anisotropic form, which the engine takes whenever ANISOTROPY is written) and
rim, with the SUN scaled by brightness^2. Lamps, the lava's OmniLights and
the flashlight light them as the engine would. The lava's BLOCK light comes
on top (`block_level`, below).

**When the level is asked** (`MineSkyLit`, a node of the mine world, not of
the collapse, so a gate that stops the collapse keeps it): a thing is
tracked when it appears (`DroppedItems.spawn`, `MineChests.place`,
`PlanetPieces.mesh_hung` -- a new signal, emitted when a piece's mesh is hung,
first or again after a hit -- and the collapse's own mesh and sand-column
paths); each frame 24 tracked things are checked for a new light cell (a
falling piece or item), and `terrain_edited` asks again everything within
16 cells of an edit's box (light reaches 15). `BrickTerrain.sky_light_at`
(0.2-0.3 ms in a dark cave, a cheap early out under the sky) at most
0.25 ms a frame, the rest next frame; a new thing that does not fit in the
frame is drawn at the eye's level meanwhile (things appear near the player).
Painted with `set_instance_shader_parameter` on its meshes: nothing is read
back from the renderer, nothing waits on a worker.

**Measured (`-- --gate=skylit`, 2026-11-22).** A stone room built on the
ground near spawn (13 x 17 studs, 6 courses), a floating dirt block let fall
into it as a piece, a chest and a dropped grass block; its way out a tunnel a
stud wide, 20 studs long, up to the sky (a room with no way out is a sealed
chamber, which the mesher does not draw). Picture brightness at each thing's
middle and on the floor a stud in front of it:

| | piece | chest | drop | floor |
|---|---|---|---|---|
| open to the sky (level 15) | 0.507 | 0.396 | 0.436 | 0.62-0.73 |
| same, `--no-sky-light` (the shared materials) | 0.507 | 0.396 | 0.429 | 0.62-0.73 |
| roofed over (level 0, exposure 2) | 0.020 | 0.014 | 0.012 | 0.04 |
| roofed, level forced to 15 (the old look) | 0.661 | 0.553 | 0.605 | 0.04 |

The open pictures with and without sky light differ by 0.38 grey levels of
255 overall, 1.5 on the piece, 0.17 on the chest (the drop spins).
`mine_skylit_open.png`, `_cave.png`, `_cave_old.png` in `user://dev/`.

**Checks.** `-- --gate=skylit` (PASS: each thing at level <= 2 in the closed
room, no brighter than twice the floor beside it, under half its forced-15
brightness), and with `--no-sky-light` for the open numbers;
`mine_world_probe`, `terrain_collapse_probe`; `-- --gate=gpu` against
section 17.

**Block light from lava on things (2026-11-22, later).**
`BrickTerrain.block_light_at(point)` mirrors `sky_light_at`: the bake's own
`SkyGrid::fill_block` over a box light's reach (15 cells) round the point,
seeded by `BrickFluid::lava_cells_in` of that box; with no lava anywhere
(`lava_total`) or none in the box it returns 0 without making a grid.
MineSkyLit asks it beside the sky level and paints `instance uniform float
block_level`; `sky_lit.gdshaderinc` draws it as the ground does (section
18): EMISSION of `block_light_colour` x albedo x its brightness x
`block_light_energy`, and AO lifted to `block_light_ao` of it where that is
brighter than the sky's. The water's `lava_light` (mine_world.gd
`lava_relit`) marks things within reach to be asked again, as an edit does.
The lava's OmniLights stay (they still light pawns, studs, props).
`--gate=skylit` now ends with a 3 x 3 lava pool on the room's floor behind
the things (2026-11-22): piece 0.020 -> 0.264 (block level 8), chest 0.014
-> 0.410 (13), drop 0.012 -> 0.361 (12), each must be at level 5 or more
and half as bright again as in the dark (`mine_skylit_lava.png`). An ask
beside lava costs more than one under the sky: worst 0.93 ms (sky and block
together, the block fill over 31^3 cells); one thing is always asked a
frame, the rest wait for room.

**Falling sand and crumbs.** The falling sand is one MultiMesh for every
column; with sky light on it carries each column's levels in
`INSTANCE_CUSTOM` (r sky, g block, as 0..1) and draws with
`MineSkyLit.sand_material()` (`sky_lit_item.gdshader` with
`#define SKY_LIT_SAND`: colour from the instance, levels per instance). A
column's foot cell is asked when it falls into a new one, inside the same
0.25 ms a frame; till first asked it takes the eye's level. The crumbs a
landing throws (PlanetCrumbs, shared with the planets) have no spare
per-instance channel and last a second: `PlanetCrumbs.shade`, set by the
collapse to `MineSkyLit.tint_at`, gives one colour a throw (sky brightness,
or the lava's ambient share, plus its warm glow) that the crumbs' colours
are multiplied by. Other scenes leave it unset.

**Slits up a dark room's walls (the near tier's chamfer).** The bright
dotted lines up the inside corners and wall seams of a level-0 room
(`mine_skylit_cave.png`) were daylight through the near tier's geometry
chamfer (`MeshBuf::quad` via `mask_faces`), not light. Three faults, in
`brick_terrain.cpp`:

1. The edge flags were read in the wrong order. `mask_faces` probes each
   quad's neighbours in slice order (V-, U+, V+, U-), and `quad` reads bit i
   as the edge from corner i to i+1. The -X and +Z walls are wound along -U
   and the -Y faces along +V, so on those faces the two upright edges'
   flags were swapped: a brick at an inside corner bevelled its corner edge
   (nothing meets it there) and squared its seam edge (its half of the
   groove missing). Two slits a course tall, up every inside corner.
   Remapped per face direction.
2. A groove that ends against a square join (a wall's seams at the floor, a
   wall's course seams at the other wall) left its end open behind that
   face. The wall's foot already reached a bevel below the floor for the
   floor's grooves; now every face reaches a bevel past every edge whose
   neighbour is solid and covered, in its own plane, behind the face it
   meets.
3. Where grooves cross, one brick's edge meets two bricks' edges part way
   (a T-junction) and the groove's floor cracked to single pixels. Each
   chamfered face now has a backing quad a bevel and a half behind it,
   widened under its coplanar neighbours and pulled in from convex and
   square edges. Two triangles a face, near tier only.

`-- --gate=seams` measures it: the stone room roofed over, an unlit magenta
box round its outside (a black card across the tunnel), 36 close views at
14 degrees of the inside corners, the walls, the floor's and roof's edges;
magenta pixels counted with the chamfer off (the flat tier) and on. Before:
145,117 px with it on, in 32 of 36 views (the dotted lines). After: 0.
The flat tier shows a few single pixels (3-14 a run) at seam crossings;
it has no chamfer and was not changed. The heightfield scene's
`bevel_gap_probe` still passes (0 magenta, chamfer on and off, wide and
scoped); terrain_probe's thin-roof underside check needed the skirts kept
off edges squared only by a piece beside them.

**The flat tier's dots (2026-11-23).** The deep sections (and the flat
near and far tiles) are drawn unchamfered, and the user still saw white
dots at the seams of 1x1 bricks in a dark cave: T-junction cracks, one
face's edge meeting two faces' edges part way along. Unchamfered, each
`mask_faces` face now overlaps its neighbours by `FLAT_OVERLAP` (1 mm) past
every edge that is not an outside corner; no triangles added. `--gate=seams`
now requires 0 on both tiers: flat 3-14 px -> 0. With the chamfer on, one
run in three showed 2 px at the top of one view where a wall's seam meets
the roof; open. mine_world_probe's seam keys round to the cm (the two
tiles' copies of a vertex now differ by up to 2 mm).

**Caves as far as the surface.** The deep tier loaded 2 tiles round the
eye (about 25 m) while the surface's detail is 4 (the settings'
`detail_tiles`): a long cave ended in nothing, its water (drawn further)
hanging in the air. `TerrainDeep.radius` now follows `detail_tiles`.

**Water in the dark.** `water_fluid.gdshader` read no light of the cells:
a cave pool was lit as the open sea. BrickFluid's `mesh_tile` now writes
each water vertex's sky level into COLOR.b (`brick::sky_levels_into`, the
bake's own sampling over a SkyGrid round the mesh; the flow direction that
was there is no longer read), the far meshes and sea pieces say open sky;
the shader includes `sky_lit.gdshaderinc` and, with `sky_light` set (the
mine world, `_sky_light_on`), scales the ambient, the sky's reflections and
the sun by it. Lava keeps its glow. Not block light: `lava_cells_in` takes
the fluid's lock, which `mesh_tile` holds. `--gate=skylit` puts a 3 x 3 pool
in the closed room: 0.014 against a floor of about 0.03.

`--gate=gpu` after all this (2026-11-22 23:26) is NOT a clean number: six
headless runs of other chats went on through it and it started near 81 C.
Baseline GPU 6.06 ms on foot, 4.02 ms 25 m up (section 18: 5.48 / 3.89,
quiet, 62 C); the chamfered near mesh's own share 0.57 ms; 0.69M triangles
on foot against 0.64M with it hidden. Retake it quiet and cool.

## 20. The ground's bricks, checked against its data (2026-11-22)

An audit of what a tile draws and collides against what the field holds
(`BrickTerrain.audit_tile`, run by `tools/probes/terrain_audit_probe.gd`,
headless, over 30 tiles of generator 1, with and without the deep tier, and
again after shots). Six faults, from the user's list:

**Invisible walls.** A column top's collider box reached down through a cave
under a roof one or two bricks thick: 7,158 open-air cells inside boxes over
30 tiles. A box now stops where its column stops being solid (`WHERE EACH
COLUMN'S TOP STOPS BEING SOLID`, brick_terrain.cpp); the gaps where tiles
meet the deep sections are closed too. Now 0, and no exposed ground lost its
collider.

**See-through faces.** A top brick's side facing a cave or an overhang was
drawn by nothing, nor were a brick's sides under the tile or plate laid on
it: 213 faces missing, 687 after shots. Each piece now notes which of its
sides another piece draws (`sides_drawn`) and draws the rest. Now 0.

**Studs.** 24 % of surface cells had studs, and 5,373 of 5,487 bricks with a
brick standing on them were smooth. The user's rule: any brick with a brick
on it has studs. A top brick whose bond footprint reaches under a higher
column is HELD: a studded brick, and if it takes a second course, a studded
plate, never a smooth tile. The surface is now 54 % studded, still a mix.
Cave floors had none; the deep sections' floors now take them
(`CAVE_STUD_CHANCE`, 0.9), drawn by their TerrainTile like a surface tile's.

**Cave studs go dark with the floor.** With sky light on (section 18) a stud
carries its cell's sky and block light in its MultiMesh custom data (stride
20, `stud_stride`), and `TerrainTile.sky_stud_material` (printed.gdshader
with `#define INSTANCE_SKY`, printed_core's curve and light) draws it as dark
as the floor it stands on.

**The underside.** A cave roof or an overhang is the bottoms of the bricks
over it, and drew as flat plastic. terrain.gdshader now draws a falling
brick's open bottom there -- rim, ribs, the hollow with parallax -- from
`shaders/print_underside.gdshaderinc`, the uniforms and `ps_under_sd` split
out of print_surface so both shaders share them (print_surface still has
`ps_underside`; terrain has its own copy, with no print_surface in it: the
two share print-line uniform names).

**The flashes as ground breaks or falls.** `-- --gate=handover` notes, after
every drawn frame, which tiles have swapped and what is out:

- the break flash: a brick across a tile edge was in one tile and out of
  the other for a frame, its studs with it. Every tile one edit names is now
  one batch and swaps in the same frame (`TerrainStreamer._batch_of`;
  `TerrainDeep` the same for sections);
- the sand flash: sand had a frame with its ground swapped and nothing drawn.
  What falls HOLDS the tiles that still draw it (`hold_tiles`) until its own
  mesh is made, then swaps them and lets it go in one call (`swap_ready`);
- stray studs as a block started to fall: physics interpolation drew a
  pooled stud halfway between its old and new buffer slot for a tick.
  TerrainTile is not interpolated.

Run on the fixes: 0 frames half swapped, 0 gaps, 0 drawn twice, for the
break, a falling piece and falling sand. The break check also checks the
shot brick's cells are empty. Its pictures (`user://dev/handover/`) never
showed the hole a break leaves, though the cells, the rebuilt tiles' meshes
and the game all have it, so the check is the swap count, not the pictures.
The gate aims with `_aim_eye`, which corrects for where the walker's eye
really lands.

**The chamfer's edge test stays main's.** This work also had the near
tier's chamfer test every cell along a merged face's edge (one probe at its
first cell, the thought was, could bevel an edge whose far half was
coplanar). Merged with section 19's fix of which bit is which edge, it
opened 927 magenta pixels in `-- --gate=seams` (0 with one probe), and
`bevel_gap_probe` showed no slit with one probe either; so one probe it is.

**Probes.** `terrain_audit_probe` (above), `terrain_probe`,
`terrain_collapse_probe`, `mine_world_probe`; `-- --gate=handover`.
`terrain_probe`'s two smooth-terrain checks ("turning it off gives the
packer its cells back", "every cell has exactly one top surface") fail on
main too, from before this work.
