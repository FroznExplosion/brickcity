# Planets — curved horizon now, spherical planets deferred

Status (2026-10-05): **deferred.** Nothing here is scheduled. If the game wants the look of a
planet from the ground, §2 is the route and it is small. If it ever wants real planets — landing
from orbit, walking all the way round, several bodies — §3 is the route, and it is large.

Prior art, both ours: STA's cubed-sphere blocky planets (`Docs/Reference/sta.md`,
STA `Docs/23_CUBED_SPHERE_BLOCKY.md`) and zylanntest's curvature shader
(`Docs/Reference/zylanntest.md`).

---

## 1. The question, and the answer in one line

Can the brick terrain sit on a real sphere? **Yes** — a cubed sphere puts our heightfield on each
of six faces, and STA has measured that it holds up. But every system that assumes "up is +Y"
changes with it. A curved HORIZON on a flat world is a vertex-shader bend and changes no gameplay.

---

## 2. The cheap route: bend the flat world in the vertex shader

What zylanntest does (`shaders/blocky_terrain.gdshader`, `Docs/voxel_planet_game_design.md` §5):
every vertex drops by its horizontal distance from the player squared over twice a radius.

```glsl
vec3 d3 = world_pos - player_pos;
vec3 horiz = d3 - up * dot(d3, up);
VERTEX.y -= min(dot(horiz, horiz) / (2.0 * planet_radius), 10000.0) * strength;
```

`strength` is blended by the player's altitude (`u_curve_low_altitude` .. `u_curve_high_altitude`),
so the curve can be faint on the ground and full from the air, and it is 0 in a flat editor
(zylanntest zeroes it for its structure builder).

### 2.1 What it gives and what it does not

* **Gives:** the ground falls away at the horizon like a planet's, from any height, at the cost
  of a few ALU per vertex. Gameplay, physics, AI, water simulation, the city grid, buildings,
  weapons and saving are all untouched: the world IS flat; only its picture curves.
* **Does not give:** going round, orbit, several planets, gravity toward a centre. What you see
  far off is drawn lower than where it really is, so a long-range shot at something on the
  horizon aims at where it is, not where it is drawn. At 300 m on a 10 km radius that is 4.5 m —
  noticeable for a sniper, invisible for a mech brawl. Keep the radius large enough, or fade the
  bend in only past weapon range.

### 2.2 Radius

The drop at distance `d` is `d^2 / 2R`:

| R | drop at 100 m | at 300 m | at 1 km | feel |
|---|---|---|---|---|
| 2 km | 2.5 m | 22 m | 250 m | a small moon, horizon very close |
| 10 km | 0.5 m | 4.5 m | 50 m | visibly a planet from a mech's height |
| 50 km | 0.1 m | 0.9 m | 10 m | a hint at the horizon only |

Start at ~10 km with the altitude blend, tune by eye.

### 2.3 What applying it here takes

Every shader that draws the world needs the same bend, or things float off the ground at range:

* `shaders/terrain*` (detail and coarse tiers, studs and scatter instances),
* `shaders/water.gdshader` (both tiers and the sheet), `water_pool.gdshader`,
* `shaders/brick*` (buildings, debris), `impostor.gdshader` and the near-tree fade copy that
  `ImpostorLod._fading` injects, `printed*.gdshader` (studs, tufts, pebbles),
* the sky / horizon (the sea sheet already reaches the world's edge; past the curve it drops below
  the horizon naturally).

Best done as one `#include` (a `curvature.gdshaderinc` beside `weather.gdshaderinc`) with one
global shader uniform for the player position and radius, so no material has to be told.

Traps: culling uses the UNBENT bounds, so far objects bent down can be culled while still on
screen near the horizon — give the far tiers an extra cull margin. Shadows are drawn bent too, so
the sun's shadow camera needs the same include (it does, if every shader has it). Picking and
physics rays stay flat, which is right.

Effort: a few days, mostly touching every shader and checking the far tiers line up.

---

## 3. The large route: a real spherical planet (STA's cubed sphere)

### 3.1 The geometry

A cube whose six faces are projected onto a sphere. Each face is a flat 2-D grid — which is what
our heightfield already is — so each face is our terrain: tiles, slopes, pools, LOD, with every
vertex mapped through the sphere function and height measured outward from the centre.

STA measured, at `R = 2000 m` (`23_CUBED_SPHERE_BLOCKY.md` §4, §16, §26–27):

* With an equiangular warp (blend 0.48) cells are square to within 3.8% everywhere except the 8
  cube corners; size drifts 1.49:1 from a face's middle to its corner — never visible, because
  neighbours differ by a fraction of a percent.
* A CONFORMAL map makes cells exact squares everywhere and the face seams meet at 90.00°; the cost
  is that corner cells shrink (to 13.5% at the very corner). Past a 10% margin it beats the warp on
  area too. STA covers the corners with a pre-warp and hides what is left under terrain.
* The 8 corners are irreducible (a quad grid cannot close round a sphere without them).
* Unedited ground stores nothing — "the heightmap is the store, which is also the far LOD"
  (§31.1), the same principle as our heightfield and Terrain.md §22.

### 3.2 What changes in this game

| system | change | size |
|---|---|---|
| terrain mesher, slopes, LOD | the same mesher in face (u, v, height) coordinates, a quadtree per face, seams between faces | moderate |
| bricks | a stud is no longer exactly 0.35 m everywhere (drifts with the face scale); pieces are very slightly trapezoid | accept, or keep LEGO-exact pieces only near the player |
| gravity, player, mechs, camera | gravity to the centre (Godot Area3D point gravity), every controller's "up" is local | large |
| AI navigation | AINav is one flat grid: one per face, joined across seams | large |
| sea and waves | the sea becomes a spherical shell; BrickWave's plane waves run in the local tangent plane; pools work per face | moderate |
| city and buildings | each building stays its own flat brick grid on its pad, tilted to local up. Ground under a 30 m building on a 2 km planet drops ~6 cm at its edge — under half a plate | small |
| weapons, debris, ballistics | fall toward the centre; long shots curve over the horizon | medium |
| saving, multiplayer | positions become (face, u, v, height) or stay Cartesian with a face lookup | medium |

### 3.3 Size decides the feel

Horizon distance on a sphere, `sqrt(2 R h)`:

| R | eye 1.7 m | mech 10 m |
|---|---|---|
| 2 km | ~80 m | ~200 m |
| 10 km | ~180 m | ~450 m |

A small planet reads well from space and closes in on the ground. A mech shooter wants sight lines,
so a real planet here would be 10 km or more — 6 faces of ~45,000 studs a side, streamed.

### 3.4 If it is ever taken up

1. A stand-alone prototype: one planet of our tiles on a conformal cubed sphere, radial gravity,
   a walking player, no game systems. Gate: seams invisible, walking over an edge seamless.
2. Per-face LOD and streaming.
3. The sea shell; pools per face.
4. Controllers and camera with local up; then AI per face; then the city.

---

## 4. Decision

Deferred. If curvature is wanted before then, §2 (the shader) is the route: it costs days and
changes no gameplay. §3 only if the game grows real planets.
