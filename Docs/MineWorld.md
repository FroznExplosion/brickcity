# The mine world (terrain test)

`scenes/terrain_test.tscn` is a flat, endless, Minecraft-like world built from
the brick terrain. The old fixed-field destruction bench is still there:
`-- --bench` (`scripts/terrain/terrain_bench.gd`, Docs/Terrain.md).

    godot --path . scenes/terrain_test.tscn
    godot --path . scenes/terrain_test.tscn -- --seed=123 --preset=islands
    godot --path . scenes/terrain_test.tscn -- --gate      (scripted pass, pictures in user://dev/)
    godot --headless --path . --script res://tools/probes/mine_world_probe.gd

Keys: **F** fly/walk · **F9** world generation menu · **F3** readout ·
**T** one hour on · left mouse on foot shoots, and the ground breaks where it
is hit.

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
spawn.

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

Placing blocks and a hotbar, saving edits per seed, falling sand, flowers and
tall grass, clouds, villages and structures, animals, enemies, chests, and
water.
