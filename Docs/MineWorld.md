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
round them on the workers and swapped in when done. Positions are float32, so
past about 20 km from the origin precision starts to show; an origin shift is
the next step if that matters.

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
within two tiles of the player cast into the shadow map. Under the ground the
ambient fades with depth, so caves are dark.

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

Falling sand, flowers and tall grass, clouds, villages and structures, animals, enemies, chests, and water.

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
- Not yet measured: the deferred stud-set switch (last change) in a window.
