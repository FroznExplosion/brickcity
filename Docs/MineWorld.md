# The mine world (terrain test)

`scenes/terrain_test.tscn` is a flat, endless, Minecraft-like world built from
the brick terrain. The old fixed-field destruction bench is still there:
`-- --bench` (`scripts/terrain/terrain_bench.gd`, Docs/Terrain.md).

    godot --path . scenes/terrain_test.tscn
    godot --path . scenes/terrain_test.tscn -- --seed=123 --preset=islands
    godot --path . scenes/terrain_test.tscn -- --gate      (scripted pass, pictures in user://dev/)
    godot --headless --path . --script res://tools/probes/mine_world_probe.gd

Keys: **F** fly/walk · **B** build mode (section 8) · **F9** world generation
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
round them on the workers and swapped in when done. Positions are float32, so
past about 20 km from the origin precision starts to show; an origin shift is
the next step if that matters.

## 4. Trees

`TerrainTrees.stream(seed, chance_at, variant_at)`: cells of 128 studs within
420 m of the camera, nearest first, a few a frame; dropped past 500 m. Chance
per biome is the menu's "Trees" row; which of the four tree kinds grow there
is `BIOME_VARIANTS` in `worldgen_presets.gd`.

## 5. Day, night, caves

A day is 20 minutes. The sun turns, the sky and ambient follow, exposure
adapts. Nothing bakes the sun into the ground (it moves); the detail tiles
within two tiles of the player cast into the shadow map. Under the ground the
ambient fades with depth, so caves are dark.

## 6. World generation menu (F9)

`scripts/terrain/worldgen_menu.gd`, modelled on the zylanntest world builder.
It edits a copy; nothing changes until **Generate world**, which tears every
tier down (waiting for bakes), sets the new params, and rebuilds round the
spawn. F9 or Escape closes it.

It opens the way the pause menu does (`menu/core/MenuManager.gd`): a canvas
layer of its own above everything (layer 80, process always), a dimmed
backdrop that takes every click, the tree **paused** so nothing in the world
reads input, the mouse freed and put back on close. It used to sit on the
HUD layer as a plain PanelContainer, whose default mouse filter passes clicks
on its empty parts to the game: the walker captured the mouse and the camera
turned under the menu.

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

Falling sand, flowers and tall grass, clouds, solid
tree trunks, villages and structures, animals, enemies, chests, and water.

## 8. Build mode

`scripts/terrain/mine_builder.gd`, owned by the mine world. **B** turns it on
or off, on foot or flying.

| Input | Does |
|---|---|
| left mouse | break the block looked at (held: keeps breaking) |
| right mouse | place the selected block on the face looked at (held: repeats) |
| middle mouse | pick the block looked at into the selected slot |
| 1-9, wheel | choose a hotbar slot |
| X | block size: 2x2, 1x1 or 4x4 studs, always one brick tall |

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
- Default hotbar: grass, dirt, stone, deepslate, sand, sandstone, gravel,
  snow, terracotta.

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
