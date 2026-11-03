# Lighting

Plan for lighting across the game, the planet scene first: simpler, cheaper, and
right indoors. Written 2026-11-02. Steps 1-4 are built in the planet scene
(9, "Built"); section 1 is what there was before them.

## 1. What there is now

| Part | Now | Where |
|---|---|---|
| Sun | one `DirectionalLight3D`, aimed from the star at the camera each frame (in steps of 0.05 deg); energy `1.1 * seen` (how much of the star's disc no body covers: night, eclipse) | `planet_system.gd` `_light` |
| Sun colour | **never set**: white on every world. `star_color` only colours the star's disc | `star_system.gd` `_star_colour` |
| Sun size | **never set** (`light_angular_distance` 0): hard shadows whatever the star's size | -- |
| Sun brightness by distance | **none**: a planet near a bright star is lit as one far from a dim one | -- |
| Shadows | 400 m directional, the terrain's own shadows baked per vertex (Terrain.md 19.9) | `planet_scene.gd` `_build_light` |
| Ambient | from the procedural sky, energy 0.04-0.6 by day and air | `planet_scene.gd` `_process` |
| Sky colour | home's sky times `cast = atmosphere_color / (0.45, 0.65, 1.0)` | `planet_scene.gd:906` |
| Ground colour | biome colour times `data.tint` (white blended up to 40% to a random hue) | `planet_biomes.gd:159`, `star_system.gd:374` |
| Tonemap | not set: Linear (clips; snow near white) | -- |
| SSAO / SSIL / SDFGI / auto exposure | none | -- |
| Indoors | sun blocked by shadows; **sky ambient everywhere, inside too** | -- |
| Lamps | a few unshadowed omnis (torch, workbench, fire, disasters) | -- |

Each scene builds its own sun and environment: `city_scene`, `heightfield_scene`,
`terrain_scene`, `brick_sandbox`, `planet_scene`, and the thumbnail/look tools.

### Why the gun and the planet look odd

Not the sun -- it is white. The **sky ambient**: about 30% of generated worlds
get an air colour of any hue at 0.35-0.7 saturation, and the cast divides it by
home's. Red air `(1, 0.3, 0.3)` gives a cast of about **(2.2, 0.46, 0.3)**: the
sky, and so the ambient on everything (the gun included), goes strongly red.
The ground's `tint` adds up to 40% of another random hue on top.

## 2. The sun: a near light, its distance and its size

Question asked: put the light source close to the player, measure from it to
the sun, and size it to match the sun as seen from there -- is that how it
works, and does distance matter?

**A light near the player is the wrong kind.** A point or spot light near the
player fades with distance from itself and its rays spread out: the near side
of a building bright, the far side dim, shadows that splay from one point, and
a shadowed omni costs six shadow maps. The sun is far enough that its rays are
parallel across everything the player sees. A `DirectionalLight3D` is exactly
that: a light at infinite distance, with a direction and no position.

**The direction is already "from where the player is".** Each frame the light is
aimed from the star at the camera, and `sun_height` (how high the sun stands
over the local horizon) is taken at the camera too. On a curved planet that is
what matters: walking 1 km round a 6 km world moves the sun 9.5 deg in the sky.
Across the 400 m of shadows the true direction changes by 400 m / 2,000 km =
0.01 deg: nothing. So for direction, distance does not matter.

**Distance does matter for two things, and neither is used yet:**

1. **Size, so shadow softness.** The star's angular size is
   `2 * asin(star_radius / distance)`. A 40 km star at 2,000 km is 2.3 deg
   across (the real sun: 0.53 deg) -- the star sphere already looks that big.
   Godot's `light_angular_distance` is that angle: shadows sharpen near their
   caster and blur further away, as real ones do. That is the "size of the
   light source" idea, done the way the engine supports. Set it from the
   computed angle each time the sun turns. Cost: soft shadows take more shadow
   samples; measure, and keep a cap (and 0 on Low).
2. **Brightness.** Light falls as `luminosity / distance^2`. Worlds near a bright
   star should be brighter, far ones dimmer. Not the full ratio (a world at
   twice home's distance would be a quarter as bright and auto exposure would
   undo most of it anyway): `energy = 1.1 * (L / d^2 relative to home)^0.3`,
   clamped 0.6-1.6, so it reads as harsher or gloomier, never black or white.

The same holds for light off a moon or planet (5): direction from that body,
size from its radius and distance, brightness from how much of it is lit.

**Built (step 2):** `LightRig.set_sun` takes the star's angular radius and its
flux at the camera against home's, from `PlanetSystem._light`;
`light_angular_distance` = the star's size (held at 3 deg), energy
`1.1 x gain x seen`. Home reads 2.29 deg and gain 1.00.

### 2a. Planets and moons shadow each other

A body between a planet and the star must darken that planet, wherever the
player is.

- **On the ground** (the player in the shadow): `PlanetSystem._light` already
  measures how much of the star's disc every body leaves the camera (`seen`)
  and scales the sun by it -- an eclipse dims the whole scene, with the
  penumbra's soft edge. Unchanged.
- **From space or another body** (built): each body's far look (the impostor)
  and its halo take up to 4 shadowing bodies (`PlanetSystem._shadows_on`, each
  frame in `_place`): those between it and the star, near enough the sun's
  line. The shaders (`shaders/body_shadow.gdshaderinc`) do the same disc
  arithmetic per pixel, so a moon's shadow is a soft round spot that moves
  across its planet, a planet's shadow can swallow its moon, and the halo
  dims in it.
- **The voxel ground near the camera** is lit by the real sun, so the shadow
  there is the camera's `seen` -- one value for the whole view. Only a few km
  of ground are voxels and an umbra is hundreds of km across, so the edge of a
  moon's shadow on the near ground is not drawn; from high up the impostor
  shows it.
- **Rings** do not shadow yet.

### 2b. Clouds (later)

There are no clouds yet. When they come, their shadows are faked, not
shadow-mapped:

- One cloud-cover function (noise in the planet's frame, drifting with the
  wind), shared by the cloud layer and a **global shader uniform** set.
- Shaders that take the sun (brick, ground, trees, the gun) multiply the sun's
  light by the cover, sampled where the sun's ray from that pixel meets the
  cloud height. On the voxel ground and bricks: a texture lookup a pixel.
- The impostor takes the same function from space; `seen` at the camera dims
  the whole view under thick cover, as the sun does in an eclipse.
- Godot's `DirectionalLight3D` has no light cookie, so this is shader work, in
  the rig's include alongside `body_shadow`.

## 3. Colour that does not paint the player

Goal: worlds still differ, but a gun, a figure, a brick wall look like
themselves on every one.

- **Tonemap AgX** (or Filmic) with a white point in place of Linear.
- **Sky cast:** keep the air colour's hue, cap saturation (~0.25), normalise
  luminance; no channel of the cast over ~1.15 or under ~0.85.
- **Ambient:** turn `ambient_light_sky_contribution` down and blend toward a
  neutral grey (~70% neutral), so the sky's hue tints shade only a little.
- **Sun colour** = star colour, 25% of the way from white, times the air's
  colour shift by the sun's height: the light's path through the air
  (`1 / max(sun_height, 0.05)`, scaled by air density) reddens it at dawn and
  dusk, white at noon, none on airless worlds. This is the "depends where the
  player stands" part: it follows `sun_height` at the camera.
- **Ground tint** capped at ~15%.
- **Exposure** that adapts stepping indoors and out rather than going black
  or blown out. Built as the rig's own (9), from the light it knows is at the
  camera: Godot's auto exposure measures the picture a few frames late and
  its limits are in ISO, hard to hold to "a room is darker than noon".

## 4. One light rig

`scripts/light_rig.gd` (new): owns the sun, the second light (5), the
environment, sky, tonemap and exposure, and the settings-menu quality level.
Every scene asks it for these instead of building its own; the planet scene
feeds it the star, the bodies and the camera. One place for the numbers, one
place to read when the look is wrong.

## 5. Light off moons and planets

A second `DirectionalLight3D`, no shadows. Each step, score each body in the
sky: angular size x lit fraction (from the sun's angle to it) x albedo; take
the best, aim the light from it, energy from the score, colour cool and low in
saturation, `light_angular_distance` its size. At night it is the main light,
so its shadows may turn on then (Godot allows four shadowed directionals);
in daylight it is a faint fill. A planet filling the sky from its moon gives a
strong planetshine. Eclipses already come free from `seen`.

## 6. Indoors: buildings and ships

Shadows already stop the sun. What leaks is the **sky ambient**, the same in a
closed room as in a field, so rooms look flat grey; and far from the camera
shadow detail falls off, so thin walls let sun through.

### 6.1 Skylight on the brick grid (the system)

The brick game's own answer, as voxel games do it: light values in the grid.

- Each cell holds **sky** (how open it is to the sky: 15 in the open, less
  each step into a building) and **lamp** (from light-giving bricks and
  fixtures). Filled by flood from the open air and from lamps; changed cells
  re-flood locally only.
- The mesher writes both into the vertices when it builds a chunk, as it does
  already after a break. A hole blown in a wall lets daylight in; a sealed
  room goes dark; nothing extra each frame on the GPU.
- The brick shader scales the ambient (and the sun past the shadow range) by
  sky, and adds lamp light warm.
- **Things that move** (figures, the gun, mechs, pieces) sample the grid at
  their position, smoothed over a few frames, into a global shader uniform or
  their material: the gun darkens as the player walks in.
- **Ships** keep their own grid in ship space: the light rides with the hull.
- Owner: the grid and mesher are Build mode's (`brick_grid.h`, `bake_faces_into`);
  this needs that area to agree or do the C++ side.

**As built (2026-11-03)** -- not in the vertices: the mesher bakes a chunk
once and a hit only patches its indices, so per-vertex light would mean a
re-bake (50-80 ms a tower) per hit. A grid beside the mesh instead:

- `BrickWorld.chunk_light_tiles` (C++): a cell a stud across and a brick (3
  plates) up, with a cell of open air all round and ground under. Any opaque
  plate makes a cell opaque; see-through costs three steps; Glow PLA is a
  lamp. Sky: straight down from the top (a quarter step less a cell, so a
  stairwell or courtyard dims with depth), then breadth first from every lit
  cell and the open sides, `SKY_STEP` 16 of 255 less a cell (about 5.6 m into
  a room from a wide hole). Lamp: the same from Glow cells, 24 a cell. Two
  bytes a cell, each y layer a tile of a 512 x 512 RG8 image. 0.7-0.9 ms a
  town tower.
- `BrickGridLight` (GDScript): one `Texture2DArray`, a layer (slot) a
  building, 16 at once; a building too big for a layer is drawn as before.
  Each band gets its slot by the instance uniform `grid_light` (slot, cells
  x, y, z), so the one brick material stays shared; bands made later (a hit's
  redraw) get it on `child_entered_tree`. A building is lit again when its
  count of live bricks changes (one a frame), or by `relight`.
- `brick.gdshader`: half a cell out from the face (the air it looks into),
  bilinear in a layer, mixed between two; `AO *= mix(0.1, 1, sky)` (ambient
  and reflections only -- the sun is the shadows' job) and warm emission
  from lamp light. Nothing happens without a slot: every other scene draws as
  before.
- The room's ambient box no longer lights the bricks (`reflection_mask`
  leaves out `BrickGridLight.RENDER_LAYER`, the layer the grid's bricks are
  on); it lights what is in the room -- figures, the gun -- at the grid's sky
  where the camera is (`LightRig.room_open`), so they match the walls, and
  the exposure follows it.
- Not yet: ships and stations (their cabin box still stands for their own
  lights; `space_station.gd` was being changed elsewhere), the city scene,
  furniture lamps (only Glow bricks are lamps), the sun past the shadow range.

### 6.2 Quick stand-in: ambient boxes

Before 6.1: a `ReflectionProbe` per room module and per ship hull, its
`ambient_mode = color` overriding the ambient inside its box (dim, neutral),
update once. Moves with a ship when parented to it. Coarse, and blind to
destruction (could lerp toward outdoors by the room's open wall area).

### 6.3 Real lights indoors

Unshadowed `OmniLight3D` is cheap in Forward+ (clustered): fixtures from the
asset placer's lamps, ship strip lights. Shadowed ones only the 2-4 nearest the
player, from a budget in the rig.

## 7. SDFGI and the other GI

Godot can mix: SDFGI in the environment, and `ReflectionProbe` / `VoxelGI`
override it inside their boxes. As the base everywhere, no:

| | Why not as the base |
|---|---|
| Cost | Heavy on the Legion Go's iGPU (measure; likely several ms), where heat is already a suspect in the crashes |
| Thin walls | Its voxels are coarse; brick walls leak. Godot's docs point interiors elsewhere |
| Origin shifts | The planet scene moves the world (`PlanetFrame.recentre`): its cascades rebuild, the light pops |
| Destruction | Changed geometry updates late; moving debris adds no light |
| Ships | World-space data: a flying ship's interior would smear |

- **VoxelGI**: moves with its node, so it could suit a ship, but it is a bake
  (seconds), stale after damage.
- **LightmapGI**: no -- generated and destructible worlds.
- **SSAO + SSIL**: screen-space contact shadow and bounce, cheap-ish; a "High"
  setting.
- **SDFGI**: an "Ultra", outdoors-only option, only if it measures well.

Mix chosen: sun + moon/planet light (shadowed) -> grid skylight and lamp
light on all bricks, ships included -> optional SSAO/SSIL -> SDFGI experiment.

**As built (2026-11-03):** Options > Video, **Global Illumination**: Off
(default), Screen-Space (SSAO radius 0.8 intensity 1.6, SSIL radius 3
intensity 0.8), SDFGI (Ultra: that and SDFGI, 4 cascades from 0.2 m cells,
occlusion on, bounce 0.4). `LightRig.set_gi` puts it on every rig up and
every one built after (all scenes use the rig). The windowed light gate
times each level outside and inside and takes `light_gate_gi<n>_out/_in`.

Measured (planet town, noon, 1280x720, editor closed, no other runs; the
chip warm, 92-97 C peaks, so +-1 ms): GPU draw off 14.8 out / 13.0-13.6 in;
screen-space 16.0 / 16.7 (+1-3 ms), its look subtle; SDFGI 21.4 / 21.0
(+7 ms), and it looked wrong -- rooms dark orange, windows black from
outside, with the grid's sky shade off under it or not. **SDFGI is not in the
menu**; the level stays in `LightRig` for later trials (VoxelGI on a ship is
the other one to try). Screen-space is offered, default off.

## 8. Steps

| # | Step | Size | Test |
|---|---|---|---|
| 1 | `LightRig`; AgX; capped sky cast and ground tint; neutral ambient; sun colour from star and air; auto exposure | small, GDScript | **built** (planet scene) |
| 2 | Distance (2): **the sun's size** from the star's radius and distance (`light_angular_distance`, soft shadows); **its brightness** from the star's light at the camera against home's (`gain`) | small | **built**; soft shadows cost nothing measurable (9) |
| 2a | Planets and moons shadow each other: on the ground by `seen`; from space on impostors and halos (2a) | small | **built** |
| 3 | Moon/planet light (5) | small | **built** |
| 4 | Ambient boxes in buildings, stations and ships (6.2) | small-medium | **built** |
| 4b | Clouds and their faked shadows (2b) | medium | when clouds come |
| 5 | Grid skylight and lamp light (6.1) | large, C++ with Build mode | **built** for the planet's buildings (9); ships and the city next |
| 6 | SSAO/SSIL High, SDFGI Ultra (7) | small to try | **built**: screen-space offered (+1-3 ms); SDFGI tried, not offered (7) |

Area: new, Lighting -- `light_rig.gd`, `shaders/body_shadow.gdshaderinc`, this
doc; the planet and city scenes call the rig (small changes to theirs).

## 9. Built (2026-11-02)

The planet scene runs the whole rig. The city, heightfield, terrain and
sandbox scenes use its fixed day (`LightRig.build_day`, 2026-11-03): the same
sky, neutral ambient, AgX, home's sun size (2.29 deg) and sunset-free sun
colour, each scene's own sun angle and energy; no exposure changes, no fill,
no ambient boxes there. Underwater keeps the air's ambient colour and puts it
back on surfacing (the rig's neutral colour counts now).

| Part | What | Where |
|---|---|---|
| Rig | sun, fill, environment, sky, exposure, ambient boxes | `scripts/light_rig.gd` (`LightRig`); `planet_scene._build_light` |
| Sky cast | hue kept, luminance 1, no channel past 0.45 from 1: a red air was (2.2, 0.46, 0.3), now (1.45, 0.88, 0.83) | `LightRig.sky_cast` |
| Ambient | 35% sky, 65% a neutral grey as bright as the sky; never under starlight (0.6 x a cool grey (0.4, 0.45, 0.6)) so a moonless night is dark but playable | `LightRig.set_sky` |
| Ground tint | worlds 5-15% (was 10-40%), moons 15-35% (was 20-60%) of a hue | `star_system.gd` |
| Tonemap | AgX | `LightRig.build` |
| Sunlight | 25% the star's colour; air mass by `sun_height` reddens it (blue/red 0.87 at noon, 0.24 on the horizon); none without air | `LightRig.sunlight_colour` |
| Exposure | the rig's own, not Godot's auto exposure: from the light at the camera (ambient, or a box's; the sun, a tenth of it inside a box), `sqrt(0.8 / light)`, 1 to 2, half-way in 0.5 s. Daylight 1.0, a room 1.9, night 2.0 | `LightRig.expose` |
| Sun size, brightness | 2: home 2.29 deg, gain 1.00 | `LightRig.set_sun`, `PlanetSystem._light` |
| Shadows between bodies | 2a: ground by `seen`; impostor and halo per pixel | `PlanetSystem._shadows_on`, `PlanetBody.set_shadowers`, `body_shadow.gdshaderinc` |
| Fill | 5: brightest body over the horizon, `0.6 x sqrt(score)`, at most 0.35 of the sun; shadows at night above 0.02 | `PlanetSystem._fill`, `LightRig.set_fill` |
| Ambient boxes | 6.2: every building laid in bricks ("room": 25% of outdoor ambient + 0.02), every station or ship module laid ("cabin": its own lights, 0.3); walls (0.45 m) left outside; reflections black inside; a toppled building's goes | `planet_scene._ambient_boxes`, `LightRig.add_box` |

| Grid light | 6.1: sky and lamp on the brick grid of every building laid here; a hole lets the sky in, Glow bricks light rooms; the box lights only what is in it | `BrickWorld.chunk_light_tiles`, `scripts/brick_grid_light.gd`, `brick.gdshader` (`grid_light`), `planet_scene._ambient_boxes` |

Gate: `res://scenes/planet.tscn -- --gate=light` (headless for the numbers;
windowed adds pictures `shots/light_gate_*.png` and checks that the box
darkens the picture and the exposure brightens it again).

Grid numbers (2026-11-03): the gate's darkest air at eye height in a town
tower 0.12 sky; a hole knocked in a solid wall takes the air behind it from
0.69 (the windows nearby) to 0.81 (three steps from the open); a Glow floor
brick puts 0.72 lamp at eye height over it; the inside picture's mean 0.435
with the grid, 0.563 without.

Known limits: the fill at home's
midnight is often none (its moon under the horizon).

Soft shadows' cost (2026-11-03, editor closed, no other runs, the gate's
outdoor view at noon, 1280x720): GPU draw 15.65 / 15.55 ms with the sun at
2.29 deg, 15.59 / 16.28 ms hard -- no cost above the noise. The windowed
gate prints it again each run ("GPU draw").
