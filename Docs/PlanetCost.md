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

Left, smaller:
- Ships' and stations' bands are still baked (`space_ship.gd`, `space_station.gd`): the same
  change would do for them.
- The load still has 240-530 ms frames (the spawn: the impostor bake, the brick shapes, the
  first streaming), and the cost gate's own 5 km teleport back after the flights 100-330 ms.
- Occluders measured within noise in this small town; they matter more in a big one.
