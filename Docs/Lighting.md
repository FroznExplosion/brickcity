# Lighting

Plan for lighting across the game, the planet scene first: simpler, cheaper, and
right indoors. Written 2026-11-02. Nothing here is built yet.

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
- **Auto exposure** (`CameraAttributesPractical`) so stepping indoors and out
  adapts rather than going black or blown out.

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

## 8. Steps

| # | Step | Size | Test |
|---|---|---|---|
| 1 | `LightRig`; AgX; capped sky cast and ground tint; neutral ambient; sun colour from star and air; auto exposure | small, GDScript | screenshots on 6 generated worlds (red, green, airless, near/far star) + a gun close up; existing planet gates |
| 2 | Sun size (`light_angular_distance`) and distance brightness (2) | small | shadow softness shot; frame cost, editor closed |
| 3 | Moon/planet light (5) | small | night shots; a moon world under its planet |
| 4 | Ambient boxes in rooms and ships (6.2) | small-medium | walk in/out of a building and a ship; probe count |
| 5 | Grid skylight and lamp light (6.1) | large, C++ with Build mode | sealed room dark, blown wall lit, ship flying; mesh time per chunk |
| 6 | SSAO/SSIL High, SDFGI Ultra (7) | small to try | GPU ms, editor closed, heat log after |

Area: new, Lighting -- `light_rig.gd`, this doc; the planet and city scenes call
the rig (small changes to theirs).
