# What the planet scene's frame costs (2026-11-19)

The user asked what makes the planet scene lag (lighting, textures, world streaming, the other
planets, the sun), how to make light cheaper or fake it with only a few expensive lights, and what
intact brick buildings cost: how many can be near the player, and against ordinary 3D-mesh
buildings.

Measured with `res://scenes/planet.tscn -- --gate=cost` (tools/passes/planet_gates.gd) and
`tools/probes/building_budget_probe.gd` (headless). Two windowed runs, editor closed, no other
Godot running, started at 51-59 C, peak 85 / 88 C, never held back, RAM 705 MB+ free. The test
window is 1280x720 at the default render scale 0.75 (960x540 drawn), FXAA on, MSAA off, GI off.
Flat out (vsync off, no cap), because a vsynced iGPU clocks itself down and reads the same whatever
it draws. Each row is read against a baseline taken just before it. Noise between two baselines is
about +-0.5 ms, so anything under that is "nothing".

## 1. The short answer

- **At rest the scene is not slow.** Town view, flat out: 6.4-7.2 ms GPU, 7-8 ms a frame
  (130+ fps possible). The open land and the sky: 3-5 ms. At 1920x1080 drawn: ~9 ms GPU.
- **Streaming is not where the hitches are.** A 30 s walk round the town, 25 s flying low at
  40 m/s and 15 s at 300 m/s (an origin shift, new ground, new trees): **no frame over 40 ms** in
  any of them. Worst brick step 1.6 ms, tree build 0.3 ms.
- **The hitches are one-off jobs**: the load (260 ms frames), and the AI waking -- the nav net
  over the town is built in 354-444 ms and the frames round it are 130-456 ms. That is the "lag"
  a player feels on reaching the town.
- **The biggest steady cost is the brick buildings**: 26 bricked buildings (54k bricks) are
  4.2-4.3 ms of the GPU's 6.4 (two thirds), 2.3 ms of render CPU and 1.6 ms of `_process`.
- **The sky costs ~1 ms for nothing**: it is set again every frame, which makes Godot draw its
  radiance map again every frame. Easy fix (section 5, item 1).
- **Lighting is cheap here**: sun shadows 0.4-0.7 ms; clouds, atmosphere, sea, the other planets
  and the star are all inside the noise. Trees and terrain likewise.
- **What makes it laggy on the user's own machine**, most likely: (a) playing from the editor
  (an open editor inflates frame times about 4.5x -- memory note, CLAUDE.md), (b) a bigger window
  (2560x1600 at 0.75 is 4.4x the test's pixels), (c) SSAO/SSIL on in Options (+4.1 ms at 1080p),
  (d) heat (a 90 C+ chip clocks down: the same scene measured 6-14 ms apart on temperature alone,
  HandoffPerf.md 8.1), and (e) a lead found by this run, section 2.4.

## 2. Measured

### 2.1 Town view (88 m from the middle, facing it), 960x540 drawn

Baseline 6.43 ms GPU, render CPU 3.6, process 3.1; 271 objects, 2.34 M triangles drawn
(depth prepass counted), shadows 0.32 M.

| switched off | dGPU ms | notes |
|---|---|---|
| brick buildings hidden | **-4.30** | -1.08 M tris, -94 objects; render CPU -2.3, process -1.6 |
| sky not set each frame | **-1.07** | also -0.5 process |
| sky radiance 256 -> 32 | **-1.32** | same cause: the radiance map is redrawn every frame |
| render scale 0.75 -> 0.5 | -1.11 | the picture is not pixel-bound at this size |
| shells + far boxes hidden | -1.00 | all 32 near shells + far tier |
| sun shadows off | -0.68 | 4 cascades, 400 m |
| shadow 400 -> 150 m | -0.50 | |
| 4 -> 2 cascades | ~0 | |
| terrain / trees / buildings cast no shadow | ~0 | already cheap: bricks cast none, shells cast one box |
| clouds, atmosphere, sea, other planets + star, terrain, trees, ship hidden | all within +-0.4 | |
| SSAO + SSIL on | +0.3 to +1.4 | +4.1 at 1080p |

`_process` (main thread, 3.1 ms): trees 0.74, buildings 0.66, clouds 0.38, star system 0.33.
The voxel ground's own process is ~0.

### 2.2 Other views

| view | baseline GPU | what moves it |
|---|---|---|
| open land | 2.9 ms | shadows -0.55, sky -0.5/-0.7; everything else noise |
| sky, 50 deg up | 3.7 ms | buildings at the edge -1.6, sky -0.35/-0.56 |
| 250 m up over the town | 3.7 ms | sky -0.5/-0.8, shadows -0.36 |

The other planets, the star, the clouds and the atmosphere shell never cost more than the noise
from any view.

### 2.3 At 1920x1080 drawn (render scale 1.5 on the test window)

~9 ms GPU in the town. Bricks hidden -4.2 ms (the same as at 960x540: their cost is triangles and
objects, not pixels). SSAO+SSIL **+4.1 ms**. The rest of the rows were too noisy at this size
(the first baseline was read before the scale had settled); repeat if needed.

### 2.4 A lead: the frame got dearer after flying

Back on foot after the flights, the same town drew **977 objects / 980 draws** where it drew 271
before them, at 10.5 ms GPU against 6.4. Something made while flying (or while the AI woke) is
still drawn after. Not yet found. It is worth chasing: in play it would make the scene slower
the longer it is played. Check with the gate's last two rows, then a census of visible
instances by node before and after a flight.

### 2.5 Hitches over the whole run (frames over 40 ms, with the altitude)

All at the load (28 m: 43-259 ms) and round the AI waking at the end (130-456 ms; nav net 354-444
ms on the main thread's finish, garrison 25.6 ms). None during the walk or the flights.

## 3. Cheaper light that still looks good

The game already does the main trick: a few lights are real and the rest are faked.

- The brick grid's light (Lighting.md 6.1) is the fake: sky and lamp light worked out per cell on
  the CPU and read by the shader. No light in the renderer's lists.
- Near lamps (6.5): only the 4 lamps nearest the camera are real lights, only 1 casts a shadow.
- Ambient boxes (6.2): ReflectionProbes that draw nothing (cull mask 0, update once); they only
  change the ambient inside a room.

What to add, cheapest first:

| Trick | What it does | Worth |
|---|---|---|
| **Set the sky only when it changes** | `planet_scene._process` calls `LightRig.set_sky` every frame; every material write makes Godot redraw the sky's radiance map | **0.5-1.3 ms GPU, every view** |
| **Radiance 256 -> 64** | reflections and ambient from the sky are low detail anyway; covers dusk, when the sky does change | most of the same again while it changes |
| **Light by score, faded** | pick the real lamps by brightness / distance^2, on screen first (today: nearest first); fade one in over 0.3 s when it joins and out when it leaves, so a swap never pops | small, looks better |
| **Distance fade on every light** | `distance_fade_enabled`, begin 30-40 m: a far light is not drawn | free |
| **Glow instead of light** | a lamp brick glows (emission + bloom) and lights the grid; only lamps the player is near get a real light | already the rule: keep new lights on it |
| **One shadow, moved** | one shadow slot for the light that matters most; the rest use the grid's "walls in the way" | already the rule (`near_shadowed` 1) |
| **Flashes and blasts** | a few frames of an unshadowed light from a fixed pool | already (PerfCaps 2.3) |
| **Fake far shadows** | past ~100 m the grid's open-to-sky value, the cloud shade and a darker ambient stand in for the sun's shadow; the cascades then cover 150 m | 0.5 ms here; more at a big window |
| **Bake the ground's light** | with the clock running, bake the terrain's shading again every few degrees on a worker (Planets.md 10a: 1.3 s, no frame cost) | only if terrain shadows grow |
| **SSAO/SSIL stay off by default** | +4.1 ms at 1080p; the grid's contact darkening covers bricks | -- |
| **No SDFGI, no VoxelGI** | +7 ms and leaks through brick walls (Lighting.md 7) | -- |

The rule for new lights: real only when near, on screen and bright enough to matter; a shadow
only for the one that matters most; everything else is grid light, glow or ambient.

## 4. Brick buildings: what one costs, and how many

### 4.1 Per building

Planet towns are 24-36 studs a side, 12-60 courses. The 26 bricked in the run held 54,228 bricks
(about 2,100 each). Per building, from the run's rows (GPU and CPU) and the probe (memory):

| | intact brick building (planet today: baked bands) | the same as a box a brick (the city's default) | ordinary 3D-mesh building (typical game numbers, NOT measured here) |
|---|---|---|---|
| GPU a frame, in view | ~0.16 ms | about the same (triangles similar), less memory | ~0.02-0.05 ms |
| render CPU a frame | ~0.09 ms | about the same | ~0.01 ms |
| triangles drawn | ~40k (incl. prepass): every face, inner floors and walls, open studs | 12 a brick | 5-15k near, ~1k at 100 m (LODs) |
| draw calls | ~4 | ~4 | 1-3 |
| CPU memory | 360 B a brick + **~1.8 KB a brick for the bake** kept for hits | 360 B a brick | ~0 (nothing simulated) |
| GPU memory | **~1.7 KB a brick** (56 B vertices x 32 a brick) | 80 B a brick | ~0.5-1 MB with shared textures |
| a 30x30x36 (1,672 bricks) | 0.6 + 2.9 + 2.8 = **6.3 MB** | 0.7 MB | ~1 MB |
| a 36x36x60 (3,965 bricks) | 1.4 + 7.1 + 6.8 = **15.3 MB** | 1.7 MB | ~1 MB |
| made | template 0.6 ms + bake 16-34 ms on a worker + bands | ~0.5 ms | load once |
| collision | merged per band, static: ~0 a frame | same | a few boxes |
| destructible | yes, brick by brick | yes | no |

Steady cost is GPU triangles and objects; collision and the bricks' data cost nothing a frame
once still. What is per frame on the CPU is the renderer walking the objects and the buildings'
own `_process` (0.66 ms for the town).

### 4.2 How many can be near the player

Budget at 60 fps on the Legion Go: 16.6 ms, of which the scene without bricks is ~5 ms at 1080p
and fights, effects and heat need ~5 ms of headroom. That leaves **~6 ms for drawn bricks**:

- **Drawn** (within `BRICK_DRAW_M`, 80 m): ~35-40 buildings of this size, ~80k bricks. Today a
  town view draws 26 (4.3 ms). Past 80 m the shell look draws them (the 32 shells + far tier are
  1 ms together), so the drawn count is bounded by the 80 m circle, not the town.
- **In bricks but not drawn** (80-160 m: collision, AI, damage): bounded by memory, not frame
  time. Baked: ~8 MB a building -> 100 buildings ~800 MB, too much on a machine that already
  dips under 200 MB free. As boxes without the bake: ~1 MB a building -> 100 for ~100 MB.

So today: about 25-40 drawn and ~50 in bricks is safe; with boxes and no bake, 100+ in bricks.

### 4.3 Making them cheaper

1. **Boxes on the planet** (the city's `instanced_bands`, HandoffPerf.md 8.2): no bake, no upload,
   GPU memory /20, a hit refreshes a buffer. The planet still bakes.
2. **Drop the bake once boxed** (HandoffPerf.md 8.4 item 6): ~1.8 KB a brick of CPU memory.
3. **Occlusion culling**: an `OccluderInstance3D` box per building from its shell; the inner
   storeys and the buildings behind it then cost nothing. Godot's occlusion culling is CPU-side
   and cheap at a few dozen boxes.
4. **Inner storeys only near**: the city's room streaming already draws inside only where needed;
   from the street an intact building is its outer walls and roof.
5. **`BRICK_DRAW_M` 80 -> 50-60 m** with the shell look past it: the GPU share falls with the
   circle's area (80 -> 56 m halves it).

## 5. What to do, in order

All six done 2026-11-19: section 7.

1. **Sky only when it changes** (small; the planet scene and `LightRig`): skip `set_sky` while
   day, air, sun height and the local up (by ~0.5 deg) are the same; radiance 64. ~1 ms GPU.
2. **Find the 271 -> 977 objects after flying** (2.4).
3. **AI wake off the main thread's frame**: the nav net's finish over the town (354-444 ms) in
   slices or earlier (while the player is still far), so reaching the town does not stall.
4. **Planet buildings as boxes, then no bake** (4.3 items 1-2).
5. Occlusion boxes per building; `BRICK_DRAW_M` to ~60 m.
6. Options defaults stay: SSAO/SSIL off, render scale 0.75, FSR. Tell players the editor's game
   view is not representative.

## 6. Re-running

    godot --path . res://scenes/planet.tscn -- --gate=cost          (windowed, ~4 min, editor closed)
    godot --path . res://scenes/planet.tscn -- --gate=cost --quick  (baseline, trips, census, AI wake only)
    godot --headless --path . --script res://tools/probes/building_budget_probe.gd

The gate prints `[cost]` rows; read deltas over ~0.5 ms only. `PlanetScene.sky_hold` exists for
the gate's sky row; `-- --no-occluders` turns the buildings' occluders off.

## 7. State (2026-11-19): all six steps done

Every step of section 5 was built the same day, in worktree `bc-plcost` (branch `planet-cost`).

| Step | What was built | Where | Measured (`--gate=cost`, same window) |
|---|---|---|---|
| 1. Sky | `LightRig.set_sky` writes the sky only when day, air, sun height (0.002), the local up (0.3 deg), the air or the star's colour moved; the ambient boxes still follow every call. Radiance 256 -> 64 for every rig | `scripts/render/light_rig.gd` | the "sky not set" row went from -1.1 ms to noise: nothing left to save |
| 2. Objects after flying | the cause: `ImpostorLod` squares whose trees were dropped kept their MultiMeshes with 0 visible instances, each still an object and a draw. A square with nothing in a tier is hidden now | `scripts/render/impostor_lod.gd` | before the fix 225 -> 929 objects after the trips, +1,408 visible tree nodes (census); after it **225 -> 224** |
| 3. AI wake | the town's nav regions are started on workers while the scene loads (`PlanetScene._prepare_ai`: the grids are the planet's data, the sites and the trees, all known up front); `setup_ai` at the spawn collects them | `scripts/planet/planet_scene.gd` | 354-444 ms on the main thread -> **25 ms** (3 ms the player's region) |
| 4. Boxes, no bake | a planet building's bands are a box a brick (`BrickBoxes.fill`, as the city's), filled in the frame, a hit refilling only its band; no bake, no worker mesh, no upload. Open studs a MultiMesh per band, drawn to 30 m (`STUD_DRAW_M`) | `scripts/planet/planet_buildings.gd` | town GPU **6.4 -> 3.9-4.4 ms**, triangles 2.34 M -> 1.45 M; bricks hidden now saves 0.2-0.9 ms (was 4.3); at 1080p 2.2 (was 4.2). Memory a building ~1/20 on the GPU and no bake (section 4.1) |
| 5. Occluders, 60 m | an `OccluderInstance3D` box per near building, inset 1 m from its walls; none once a hit opens it, none toppled, off while the camera is within 2 m of it; occlusion culling on for the planet's viewport. `BRICK_DRAW_M` 80 -> 60 | `planet_buildings.gd`, `planet_scene.gd` | town 273 -> 225 objects with them; GPU within noise at this size (the town is small and the CPU raster cheap) |
| 6. Options | defaults unchanged (SSAO/SSIL off, 0.75, FSR); the editor's game view is not representative | -- | -- |

Gates after the change, headless: bricks 11/0, damage 12/0 (its "band drawn again" now checks
the band's box stamp, not a new node), fall 7/0, hits 8/0, topple 6/0, storey 13/0, pieces_ai
4/0, farfight 11/0, snap 8/0, squad 10/0, trees 7/0; `planet_tree_probe` 12/0,
`planet_tree_ai_probe` 8/0.

The stairs' own faces (the parts that are not boxes) are made into a mesh on a worker and given
to their band when done: made in the frame they were a 48 ms frame on a walk. With that, the
walk round the town, the low flight and the fast one have **no frame over 40 ms**, the worst
brick step 4.2 ms (was 0.8-1.6 baked on workers, 6.5-9.2 boxed before the stairs went to a
worker), and the AI wakes in 20 ms with no long frame after it. `impostor_probe` (windowed)
30/0 with the hidden-empty-square change.

Runs: editor closed; other chats' terrain runs were going between them (each windowed run here
waited until no Godot ran and the chip was under 78 C). Peak 97 C, never held back; RAM fell
to 0 MB free once (22:48, during another chat's run), so a worst frame then may be paging.

**Ships and stations too (2026-11-20).** `SpaceStation` (every ship is one) draws its bands
as boxes the same way: no bake, its stairs' faces on a worker, open studs a MultiMesh to 30 m.
A piece that drifts off still gets its mesh from `build_chunk_mesh`, which bakes that small
chunk itself. Gates headless: ship 9/0, dock 10/0, seat 14/0, debris 14/0, adrift 5/0, falling
5/0, system 17/0, rocks 5/0, belt 6/0; hull 22/1 then 23/0 -- its one failure ("up from the seat
in flight ... the pawn 1.3 m along its deck") fails on main the same way, without this change
(flaky, Hulls area). The gangway is still one small baked mesh, made once.

The quick cost gate now takes three pictures of the bricks as drawn: `shots/planet_cost_town`,
`_wall` (8 m from a wall: its windows, stairs and furniture) and `_roof` (its studs). Checked
by eye 2026-11-20: as the bricks should look.

**The last open items (2026-11-20).**

- *The gangway* is boxes too (`SpaceShip._lower_gangway`): its bricks' instance buffers and open
  studs straight from its chunk, no bake and no mesh made on the main thread at the landing.
  `--gate=hull` 23/0 (it walks up it).
- *Occluders in a bigger town*: `-- --town-rows=N` makes the home town N x N (the cost gate
  stands at its edge; its flat pad grows with it). In a 10 x 10 town (83 near, 34 in bricks) the
  quick gate reads them on and off twice from the edge and from a street: they cull 33-36
  objects and 30-90k triangles; the GPU moved -0.7 to +0.4 ms, inside the noise. They stay
  (no cost seen either), but the drawn bricks are already only the 60 m circle and the shells
  past it are cheap, so there is little left for them to hide.
- *Flying low over the big town* showed the frames the small town hid, found by timing each
  `_process` by part (the gate prints them: buildings, trees, scene, system):
  - the trees' free/make-solid loop and their changed sets' re-sort had no budget: now 2 ms each
    a frame (`PlanetTrees.CELL_BUDGET_US`, `SETS_BUDGET_US`), the rest next frame;
  - `ImpostorLod.update(here, budget_us)` refills a set's squares inside a budget, the rest in
    `_pending` for `drain` (other callers pass none: as before);
  - one square emptying its near tier SHRANK its MultiMesh, and that call waited on the renderer
    98-140 ms: an emptied tier now keeps its buffer, drawn as none and hidden;
  - the voxel ground's main-thread work is held to 4 ms a frame (`[voxel]
    threads/main/time_budget_ms=4` in project.godot; only the planets use Zylann's voxels).
  Worst trees `_process` 186 ms -> 10-30 ms, the low flight's worst frame 195 ms -> 40 ms.
  What is left of that 40 ms is a wait on the renderer at whichever call comes first (most
  likely the voxel ground handing its meshes over from its threads); nothing in the scripts.
- Tests: `planet_tree_probe` 12/0, `planet_tree_ai_probe` 8/0, `impostor_probe` (windowed)
  30/0, `hurricane_probe` 21/0, `snow_probe` 13/0, gates trees 7/0, bricks 11/0, damage 12/0,
  hull 23/0. (`mine_world_probe` would not parse against this worktree's library: it calls
  `BrickTerrain.find_bricks`, C++ added by another chat after the library was copied.)

Left: the load's 240-530 ms frames (behind the loading veil now).

## 8. The load, timed and cut (2026-11-20)

`res://scenes/planet.tscn -- --gate=load` (windowed: the trees' cards need a renderer) times
`_ready` part by part (`PlanetScene._lap`), then every frame by the clock until 12 s after the
player stands (`LOAD_WATCH_MS`), printing each long frame after the spawn, the trees', the
buildings', the scene's and the ship's worst `_process` by part. `-- --ship-off` stops the
parked ship's processing at the spawn (an A/B).

**What the load was** (before): engine up to the scene 4.1-6.0 s (Godot's own start and the
autoloads; not timed further); `_ready` 3.7 s -- the home planet's far-look bake 1.5-1.7 s, the
star system 1.0-1.1 s (the generated ship: grown 0.74 s, a room count that worked out every
door's sides ~0.1-0.2 s), the brick shapes 0.33-0.37 s, the buildings' setup 0.2-0.3 s; then
~1.3 s to the player standing, with long frames for the trees' cards and first shaders (200-300
ms, frame 2), and the spawn's own frame (280-345 ms: the pawn, gun, arms and kit made).

**Found on the way, worse than the load: a stutter in play.** Standing by the parked ship, a
frame of 85-120 ms came every 0.25 s, for as long as the player stayed (46 in 12 s). `--ship-off`
took all of them away; timing the ship's `_process` by part put 123 ms in `VentDust.update`,
which four times a second asked `HullAir.compartments()` -- every room's door sides worked out
-- only to find the rooms with holes. It asks `HullAir.breached_roots()` now: 0.0 ms, and the
long frames after the spawn went from 46 to 1 (the spawn's own).

**Also fixed:** quitting before the AI took the town's nav regions (a gate that has no AI, or
the player quitting while it loads) left their worker tasks never waited for: signal 11 at exit.
`PlanetScene._exit_tree` waits for them (`PlanetNavNet.wait_builds`).

**Cut:**

| | before | after |
|---|---|---|
| the planet's far look (`PlanetImpostorBake.cached`) | 1.5-1.7 s every start | 60-105 ms from `user://cache/` (first start, or after its code or numbers change: baked and kept) |
| the system's other worlds (`cached_images`, on their worker) | baked every visit | from the cache too |
| the ship's room count at load (`HullAir.room_count`) | `compartments()` | a count |
| `_ready`, warm cache | 3.7 s | ~1.6 s |
| player standing, after `_ready` | 1.3 s | ~1.0 s |

The cache key is the planet's numbers that shape its ground and the md5 of the four scripts that
make the maps (`PlanetImpostorBake.CACHE_SCRIPTS`): a change to the terrain, the biomes or the
trees' table bakes again, and nothing stale is ever loaded. `UserPaths.CACHE` (`user://cache/`) is
new: safe to delete whole. `user_paths_probe` 22/0, `content_packs_probe` 46/0.

**Tried and kept out:** the brick shapes made within 200 m at load instead of 400 m: 230 ms off
the load, but the shapes left were built in play in 15-21 ms frames and `--gate=bricks` failed its
"< 12 ms a frame" check. Back at 400 m.

**Not cached, on purpose:** the generated ship (0.74 s). Its growth reads the whole room-module
library, the player's own rooms included; a key safe against all of it would be most of the work
it saves, and a stale ship after a room is edited is worse than the time. Cheaper next steps if
wanted: grow it on a worker during the load (its recipe is plain data), or lay it after the spawn.

**Left, behind the loading veil** (it lifts 20 frames after the spawn): the spawn's own frame
(~280 ms, making the player), the first card bakes and shaders (~200 ms), the engine's start.

Gates after: hull 23/0, system 17/0, worlds 8/0, jump 10/0, bricks 11/0, ship 9/0, `system_probe`
34/0.

## 9. The rest of the load, the mine world, and the renderer on its own thread (2026-11-20)

**1. The ship, grown ahead.** `ShipBuild.start(seed)` grows the parked ship on a worker from the
top of `PlanetScene._ready`, alongside the planet's bake, the buildings' setup, the towns and the
trees; `ShipBuild.finish` waits for it before the brick shapes (they share its room caches,
`RoomManifest` / `RoomTemplates`, through `KitFurnish`), and `SpaceStation._prepare_generated`
takes it (`ShipBuild.take`). The star system's part of `_ready`: 810 ms -> ~245 ms, plus a
150-210 ms wait for the worker -- ~400 ms off.

**2. The spawn, over three frames.** In play (and the load gate) `_spawn_player` makes the pawn,
gun and arms, then the AI a frame later, then the kit a frame after that; the loading veil
and a saved game's way back come at its end. One ~420 ms frame is now frames of ~110 ms
(FpsRig), ~75 ms (the AI) and ~110 ms (the kit), all under the veil. The gates take it in one
frame as before (they use the kit the moment the pawn is there).

**3. The cards, from disk.** `ImpostorLod.baked` keeps a mesh's baked cards in
`user://cache/cards_<key>.bin` -- the key is the mesh's own arrays, the tile and grid, and the
md5 of the bake shader and `impostor_baker.gd` -- and loads them next time with no SubViewport,
no render and no read-back. The planet's four tree variants: ready 725 ms -> 23 ms after
`_ready`, and the long frames while they baked are gone. Every ImpostorLod mesh gets it: the
mine world's trees, the city's, the heightfield's. `UserPaths.prune_cache` keeps `user://cache/`
under 256 MB (the oldest files go first): a change to the code that made a file gives it a new
name, and this clears the old ones.

**4. The renderer on its own thread: tried, not taken.** `--render-thread separate` (Godot's own
switch, nothing changed in the project) against the default, the 10 x 10 town's quick cost gate,
each run started under 76 C:

| | safe (default) | separate |
|---|---|---|
| town, frame (flat out) | 5.4-10.7 ms | 19.2-22.3 ms |
| main thread's `process` | 3.2-5.2 ms | 11.7-13.6 ms (waiting on the renderer) |
| frames over 40 ms: walk / low / fast | 0 / 3 / 5 | 4 / 17 / 31 |
| card bakes | fine | "p_image is empty" errors (read-backs) |

Every call into the renderer from the main thread then waits for the render thread; the scripts
make many. Godot also prints that the mode "can lead to project crashes or instability". It
would need Docs/WhereWorkRuns.md 3.1's work first (far fewer renderer calls from scripts, no
read-backs). Not adopted; the flag stays off. (The safe run had 18 MB free RAM at its start,
22:19: its slow-frame counts may be high.)

**The mine world (`terrain_test.tscn`).** Its trees are `TerrainTrees` on the same
`ImpostorLod`, so the fixes reach it:
- already since 7: an emptied square hidden, and its MultiMesh kept instead of shrunk (the
  98-140 ms renderer wait);
- now: its sets' refills inside a 2 ms budget, the rest drained a frame at a time
  (`TerrainTrees.SETS_BUDGET_US`), as the planet's; the cards from the disk cache.
- **A bug of 7's sky change, fixed here.** The mine world calls `LightRig.set_sky` every frame and
  then scales the ambient and the sky's energy for caves (`*= cave`); with the sky's writes
  skipped when nothing changed, those scalings compounded frame after frame. `set_sky`'s
  skipping path now puts the ambient and the sky's energy back to what it last set (the sky's
  energy only when someone changed it, so no radiance redraw in the open). `--gate=deep`: in a
  cave 78 m down the ambient 0.018, sun 0.016, sky 0.015 for a cave factor of 0.015 -- once, not
  compounded.
- `mine_world_probe` 49 ok, PASS. `--gate=flight` against main: flying 1 / 1 frames over 33 ms
  against main's 3; slowing down 10 then 0 on two runs against main's 3 (its slow frames are the
  terrain's section instancing, not the trees -- noise).

**Gates after:** bricks 11/0, damage 12/0, trees 7/0, hull 23/0, system 17/0, save stages 1 and
2 3/0 and 13/0; `impostor_probe` 30/0 twice (cache written, then read). Save stage 3 fails one
check, "the player where they were ... 2.52 m off" -- on main too, the same 2.52 m: not this
work.

## 10. The spawn's last frame, first use, the render thread again, and two failing gates (2026-11-22)

**The player's gun, made ahead.** Timing `FpsRig.make_player` by part: the pawn ~14 ms, its
controllers ~16, the arms ~20, the gun ~80 -- of which `GunPlaceholderParts.build_library()`
45-110 ms, and the kit (`PlayerKit.attach`) built the same library again. Now:
- `GunPlaceholderParts.build_library(per_tier, fresh := false)` builds once a `per_tier` and
  hands the same library after (nothing changes a library once built). Every caller gains: the
  kit, the spawn, a soldier's gun, the city's waves and vehicles.
- `FpsRig.prewarm()` makes the player's first gun while the scene loads; `make_player` takes it.
- The spawn's parts (load gate): pawn/gun/arms 110 -> 21 ms, the kit 85 -> 0.1 ms.

**First use.** `--gate=load --first-use` fires the gun 0.3 s twice and blasts a building twice,
the worst frame of each with FrameClock's parts. Firing was not consistent (51/36 ms one run,
24/165 the next: a burst whose drawing met something new). The first blast is consistently
40-60 ms dearer than the second, all in scripts (process), in the buildings' damage path; it
cannot be warmed without blowing up a real building, so it is left, measured.

**The render thread, measured again -- fairly.** 9's A/B was wrong: FrameClock reads the
renderer every frame (GPU time, draw counts), and with the renderer on its own thread each read
makes the main thread wait for it. The cost gate now has `-- --plain` (the wall clock only, no
renderer reads). The 10 x 10 town, quick, plain, each run started under 76 C:

| | safe (default) | separate |
|---|---|---|
| town | 5.5-5.9 ms | 4.5-6.0 ms |
| walk / low / fast flight, mean | 5.8 / 5.6 / 5.9 ms | 5.9 / 5.8 / 6.3 ms |
| frames over 33 ms | 0 / 1 / 0 | 0 / 1 / 0 |

So: about the same, not worse -- and not better either; the frame is not waiting on the renderer
here. And separate breaks things: 15 card bakes came back empty ("p_image is empty": a
`get_image()` read-back from the main thread), a "finalize can only be called from the render
thread" error, textures leaked at exit. Before it could be used: `ImpostorBaker.bake`'s
read-back (cards of node sources -- a gun on the ground -- are not disk-cached),
`PartThumbnail`'s, and `brick_near.gd`'s `surface_get_arrays` in play (against CLAUDE.md's rule
already). Not adopted: nothing to gain today.

**The hull gate's "up from the seat in flight" -- a real bug, fixed.** Stepping out of the
pilot's seat while the ship flies, `pawn.place` left the pawn standing still in the world; put on
the ship's ghost, its velocity relative to the deck was the ship's own backwards, and it slammed
into the bulkhead behind the seat: 1.3 m sternward at 68 m/s, EVERY time. The gate only failed
when it read the pawn's place before the slam (3 frames was sometimes not enough), so it looked
flaky. Now the pawn leaves the seat moving with the deck (`ship.deck_velocity`, in the scene's
stepping-out): it stays at the seat. Three runs, 23/0 each, the pawn 0.000-0.001 m along the deck.

**The save gate's stage 3 "2.52 m off" -- the gate's own placing, fixed.** On the other system's
world stage 2 put the pawn at the planet's sum surface (`surface_point`) + 0.3 m and saved it
before it stood: it was saved inside the meshed ground, and the load rightly lifted it out
(`keep_over_ground`) -- 2.16-2.52 m. Stage 2 now stands it on the ground's own layer (a ray from
15 m over, `Layers.WORLD` only: `_ground_hit` from 50 m up meets roofs, trees and the ship
first) and waits for it to be on the floor before saving. Stage 3's position check: 0.00 m off.
Two full save sequences after: the first 3/0, 13/0, 7/1 -- stage 3's position right, but
"home again, its wall's bricks still gone -- 0" failed; the second 3/0, 13/0, 8/0. That one check
(the home town's saved damage read 1 s after landing back home from another system) is a
separate flake, seen once in two, not looked into further: two more sequences to count it were
stopped by Claude Code when the machine ran short of memory.

Also seen, not this work's, failing the same on main: `alt_fire_probe` "a shield over the marked
head takes the bent round plain -- 15.00" and `fights_back_probe` "while it hid, the rounds went
into the wall, not into it -- 0 of 9" (weapons). Every other probe that uses the gun library:
aim_assist 23/0, chip 21/0, combat_numbers 45/0, crit 10/0, defence 23/0, fire_mode 22/0,
frozen_soldier 10/0, gun_kind 20/0, held_gun_drop 5/0.

## 11. The save gate's "home again" flake (2026-11-22)

Stage 3 flies the ship out and jumps home (`system.jump(0)`), then checks that the home town's
blown wall is still gone. Printing the site and the save at that check: in the failing run the
system was still 386 -- **the jump had been refused** and never checked, so "home" was the other
system's sky, with no home damage loaded (its world keys empty). `_ship_out` stops thrusting once
the ship is its own frame, which can come before the ship is out of the planet's gravity shell,
and a jump is only allowed out of it (`PlanetSystem.can_jump`: `ship.ref == null`).

`_jump_when_open(index)` (planet_gates.gd) flies on until a jump can be made (up to 60 s), makes
it, and returns whether it was; stage 2's jump to the map's pick and stage 3's jump home use it,
each a check of its own ("jumped to the map's pick", "jumped home"). Three full sequences after:
3/0, 14/0, 9/0 each, every jump made. The game was right; the gate was not.

Tried first and taken out: re-laying a home building that is already bricks when its saved
damage comes back (`restore_site`). In every run the building was not bricks at that moment, so
the change answered nothing; it is not in.

Still seen, not looked into: a segfault now and then at the exit of a save stage that passed
(signal 11 after "372 RID allocations of type 'P11JoltShape3D' were leaked at exit"): 2 of ~21
stage runs. The checks before it pass; it is the quit with bodies still live.
