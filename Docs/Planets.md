# Planets — real spheres, brick patches, buildings on their own grids

Status (2026-10-19): **design, not scheduled.** Replaces the 2026-10-05 version, which deferred
real planets because every system would have to change. Two decisions since then make the large
route much smaller:

* **The ground stops being a brick grid.** Smooth low-poly ground with sparse patches of bricks
  (Terrain.md 18.6 and §3 here) needs no global stud grid, so it does not have to wrap a sphere.
* **On a planet the ground is indestructible; buildings stay destructible.** The ground becomes
  baked static data, and everything destructible already lives on each building's own grid.

Prior art, both ours: STA (`C:\Users\lbaun\Documents\sta`: smooth SDF planets on Zylann's voxel
engine, radial gravity, floating origin, orbits, simple Gerstner water; its cubed-sphere study is
`Docs/23_CUBED_SPHERE_BLOCKY.md` and `25_PLANET_SHAPES.md`) and zylanntest's curvature shader
(`Docs/Reference/zylanntest.md`).

§9 lists what can be changed NOW, in the flat game, so the move costs less later.
Asteroids, ships, stations and bricks only where a building was hit: [Space.md](Space.md).

---

## 1. The two routes

| | cheap: a bent picture (§2) | large: real planets (§3–§8) |
|---|---|---|
| what it is | the flat world drawn falling away at the horizon | spherical bodies you land on, walk round and fly between |
| gameplay change | none | gravity, AI outdoors, terrain, coordinates |
| cost | days | months; much less after §9 |

---

## 2. The cheap route: bend the flat world in the vertex shader

Every vertex drops by its horizontal distance from the player squared over twice a radius
(zylanntest `shaders/blocky_terrain.gdshader`):

```glsl
vec3 d3 = world_pos - player_pos;
vec3 horiz = d3 - up * dot(d3, up);
VERTEX.y -= min(dot(horiz, horiz) / (2.0 * planet_radius), 10000.0) * strength;
```

`strength` blends in with the player's altitude, so the curve is faint on the ground and full from
the air, and 0 in an editor.

* **Gives:** a planet's horizon from any height for a few ALU a vertex. Gameplay, physics, AI,
  water, the city grid and saving are untouched.
* **Does not give:** going round, orbit, several bodies, gravity to a centre. Far things are drawn
  lower than they are: 4.5 m at 300 m on a 10 km radius -- fade the bend in past weapon range.

| R | drop at 100 m | at 300 m | at 1 km |
|---|---|---|---|
| 2 km | 2.5 m | 22 m | 250 m |
| 10 km | 0.5 m | 4.5 m | 50 m |
| 50 km | 0.1 m | 0.9 m | 10 m |

Applying it: one `curvature.gdshaderinc` with a global uniform, included by every world shader
(terrain tiers, studs, scatter, water, bricks, impostors, printed parts, glass). Traps: culling
uses unbent bounds (extra margin on far tiers); shadows need the include too. A few days.

It also makes a good LANDING transition for §3: from orbit you see the real sphere (STA's impostor),
and on the ground the bent picture of the local chart, the two agreeing at the switch altitude.

---

## 3. The ground on a planet: smooth low-poly, brick patches, never broken

### 3.1 Why bricks cannot wrap a sphere, and why that stops mattering

A quad grid closed round a sphere has at least 8 irregular corners (Euler: total defect `4χ = 8`;
STA doc 23 measured them). A stud grid laid round a planet is therefore never exactly a stud grid.

The ground Terrain.md 18.6 is heading to does not need one. It is a smooth low-poly surface with
**bricks in patches** -- flat ground and the odd scatter -- and each patch can carry its OWN little
grid, laid flat in the local tangent plane. The sag of a flat thing of width `w` on a sphere of
radius `R` is `w² / 8R`:

| width | R = 1.5 km | R = 6 km |
|---|---|---|
| 6 m patch | 3 mm | 1 mm |
| 40 m | 0.13 m (a plate) | 0.03 m |
| 70 m | 0.42 m (a brick) | 0.10 m |
| 140 m | 1.6 m | 0.42 m (a brick) |
| 300 m | 7.5 m | 1.9 m |

A brick patch of a few metres is flat to a fraction of a plate on any planet worth landing on.

### 3.2 The surface itself

A **cubed sphere of heightmap chunks** -- the same tiles we stream now, mapped through the sphere
on each of six faces, height measured outward from the centre, a LOD quadtree per face. STA
measured the mapping (doc 23 §4, §16, §26–32): cells square to within 4% except at the 8 corners,
which are hidden under terrain.

**Not** STA's voxel terrain. Zylann's SDF voxels are what made STA's planets destructible, with
caves and overhangs, and they are its most expensive system: transvoxel meshing, edit storage,
re-meshing. Indestructible ground needs none of it. Caves and overhangs, where wanted, are
authored meshes placed on the surface, like buildings.

### 3.3 What "indestructible" buys

| | today (flat, editable in the editor) | planet ground (static) |
|---|---|---|
| mesh | generated per tile while streaming | **simplified offline** per chunk -- flat ground collapses to a few triangles |
| collision | 100–200 merged boxes a tile | one heightmap shape a chunk, baked |
| lighting | sun shadow baked per vertex already | the same, plus baked AO |
| navigation outdoors | brick-column grid, read live | **baked once** per chunk (§7) |
| edit store | copy-on-write sculpt tiles | none at runtime |
| explosions | (already do not dig) | scorch decals |

Not a disk cache of raw tiles: measured, reading one back is slower than building it (§9.5). The
win is what can be done to ground that never changes -- simplified meshes, baked colliders and
navigation -- before anyone plays. Triangles: indestructibility does not remove any by itself; it permits offline
simplification. With the low-poly look (Terrain.md 18.6 follow-up) the near ground estimate is
~100–190k triangles where laid brick is ~400k; offline simplification of the far ground could
plausibly halve its ~370k again. **Estimates, not measured.**

### 3.4 Size decides the feel

Horizon distance `sqrt(2 R h)`:

| R | eye 1.7 m | mech 10 m |
|---|---|---|
| 1.5 km (STA's moon) | ~70 m | ~170 m |
| 6 km (STA's planets) | ~140 m | ~350 m |
| 10 km | ~180 m | ~450 m |

A mech shooter wants sight lines: 6 km or more for a planet you fight on; small bodies for
set pieces. STA's planets are 5–6 km with a 1.5 km moon.

---

## 4. Buildings: rigid grids, or bent grids

Every building already has its own brick grid and transform (`BuildingRegistry`, `b.xform`).
On a planet each one is placed in the local tangent frame at its site.

### 4.1 Rigid (the default)

The building stays exactly as it is; the ground comes to it: the pad and brick fill already built
for placing on hillsides (Terrain.md 21.8, 18.6), which is also what STA's structure builder does
(STA doc 16 §3, "flatten pad"). From the §3.1 table, no visible problem below about a brick of sag
-- ~70 m on a 1.5 km body, ~140 m on 6 km. Wider, the plinth shows at the edges as a terrace.

**The real limit is gravity, not the look.** On a flat 300 m roof on a 1.5 km body, radial gravity
is 5.7° off the roof's normal at its edges: the roof feels like a slope. The fix is a **gravity
zone per building**: inside its box, down is the building's down (Godot `Area3D` gravity override,
the Mario Galaxy way). With that, any width works rigidly.

### 4.2 Bent (for wide buildings on small bodies, and long things)

Render-only curvature, as asked: the bricks are never printed bent and the curve belongs only to
that planet's grids.

**Simulate flat, draw bent.** The building is simulated in its flat building space exactly as now
-- placement, damage, stress, collapse, rooms, AI -- and only drawn wrapped onto the sphere:

```
world(p_building) = centre + (R + p.y) * dir(azimuthal_map(p.x, p.z))
```

What that gives:

* **Gravity comes out right by itself.** Flat-space −Y maps to "toward the centre" everywhere, so
  the stress solver, the hang check and collapse need no change, and no gravity zone is needed.
* **No width limit in practice.** The azimuthal map's distortion over 300 m on a 1.5 km body is
  ~0.07%.

What it costs:

1. **Bricks widen with height** by `(R + h) / R`: 6.7% at the top of a 100 m tower on a 1.5 km
   body. Unavoidable on a sphere without gaps; invisible except beside an unbent copy.
2. **Collision cannot bend.** Each collision box gets its own small rigid transform (a box is a
   brick or a merged run, so its own bend is nothing). Chunk boxes, slab colliders, the roofs a
   player stands on.
3. **Everything that crosses between world and building space** -- bullets, `AIWorld`'s DDA,
   explosion radii, the placer's aim, debris breaking off -- converts through ONE pair of
   functions per building (`to_building(p)`, `to_world(p)`). Short rays go straight in building
   space; long ones in segments. **This is most of the work, and §9.2 makes it cheaper now.**
4. **Debris** that breaks off becomes an ordinary rigid body at its bent pose.
5. **Every drawing of a building bends the same way:** chunk meshes, instanced bricks, stud cards,
   shells, impostors, glass -- a few lines of vertex shader each, or bent at bake.
6. Two buildings never share one continuous wall: each is its own island (true today).

Rigid with a gravity zone is the default; bent is the tool for very wide buildings on small bodies,
and for long runs -- roads, walls, ring cities -- that would otherwise need a terrace every 70 m.

---

## 5. Gravity, controllers and physics

* **Bodies:** Godot's `Area3D` point gravity on each planet, an override inside each building
  zone. Rigid bodies (debris, falling bricks, ragdolls, loot) then need no code.
* **Controllers** (player, soldiers, mechs, vehicles, camera): local up = `-gravity_at(p)`.
  STA has a radial-gravity character controller (STA doc 05) to copy from.
* **Projectiles:** fall toward the centre; long shots curve over the horizon.

Today: 515 uses of `Vector3.UP` in 104 GDScript files (many are only `look_at` up-vectors) and
~21 hard-coded gravity constants. §9.1.

---

## 6. Coordinates, travel and water

* **Floating origin: STA has it.** `solar_system.gd` rebases the world every 500 m
  (`_rebase_distance`), and anything that must move with it joins the `origin_shift` group (its
  build system, goo and effects do). For us: everything on a planet lives in **that planet's
  local frame**; building grids are local to their buildings already, so a rebase moves the
  planet node and touches nothing inside them. The C++ that holds absolute positions --
  `AIWorld`'s spatial hash, `AINav`'s columns, `BrickWorld` chunk transforms, the registry's
  boxes -- either works in planet-local coordinates or joins the shift.
* **Seamless space travel:** STA's impostor and LOD tier swap (STA doc 02 §6–7) carries a planet
  from orbit to the surface.
* **Water: STA's simple water** -- Gerstner surfaces on a spherical shell at sea level, no flow
  simulation (STA doc 20). Our `BrickWave` plane waves run in the local tangent plane; pools stay
  per chunk. The brick-stepped wave look (Water.md) carries over as a shader.

---

## 7. AI and pathfinding on a planet

The hard part was always the outdoors: `AINav` is one flat grid of stud columns, height up.
Three things make it tractable:

1. **Buildings route by their rooms** (Docs/AI.md §3.6.1, worth doing in the flat game now): the
   inside of a building is a graph of spaces, openings and stairwells in **building space**, so
   curvature never reaches it.
2. **The ground is static**, so the outdoor map is baked once per chunk -- a flat grid in each
   chunk's own tangent frame (a cubed-sphere face chart), joined at chunk edges. The HPA* that
   exists (`ai_nav_hpa.cpp`) is already a graph of clusters joined at borders; a chunk is a
   cluster with its own frame.
3. **What stays live is small:** damaged rooms, wreckage and vehicles -- the brick grid, read
   locally, in the frame of the building or the chunk it is in.

Flow fields for swarms run on the chunk charts; a fight is a few hundred metres across, so it
rarely spans more than a few charts.

---

## 8. What happens to each system

| system | flat game today | on a planet | size |
|---|---|---|---|
| ground | brick heightfield, streamed | static cubed-sphere heightmap, baked, brick patches on local grids | large (new mesher path, reuses tiles) |
| buildings | own grid + transform | the same, tangent-frame placement; rigid + gravity zone or bent | small (rigid) / medium (bent) |
| destruction | building space | unchanged; debris under point gravity | small |
| gravity / controllers | +Y | local up | large, smaller after §9.1 |
| AI indoors | brick grid (room graph planned) | room graph, unchanged | none after AI.md §3.6.1 |
| AI outdoors | brick grid | baked per-chunk charts | medium |
| water | sea plane + pools | STA simple water on a shell | medium |
| coordinates | world space | planet-local + STA's floating origin | medium |
| saving / co-op | world positions | (body, local) positions | medium |

---

## 9. What to change now, in the flat game, to make the switch cheaper

Each of these is worth doing for the flat game on its own, or costs nothing in it. None changes how
the game plays.

### 9.1 One source of "up" and of gravity

`Gravity.up_at(p)` and `Gravity.at(p)` (an autoload, or statics on an existing one) returning +Y
and the project gravity today. Move the ~21 hard-coded gravity constants to it first, then the
`Vector3.UP` uses that mean "away from the ground" -- not the `look_at` up-vectors, which can wait.
Do it as files are touched anyway; no big-bang pass. Rigid bodies already take the project's
gravity, so they need nothing.

*Built 2026-10-20:* `scripts/gravity.gd` (`Gravity.down_at`, `up_at`, `at`, `strength`). Every
per-frame fall in the game goes through it -- pawn (walk, air, slide, grapple), titan, tank,
truck, flyer, debug camera, grenade, dart, VFX shards, rain and hail particles -- and every read of
the project's gravity (debris, danger volumes, the mech fall rule, the city's path-ahead). Each
system keeps its own magnitude. What is left is the `.y` logic round it -- "on the floor, zero the
vertical speed" and the like -- which becomes "along up_at" when a controller goes radial.

### 9.2 Building space through one door

Every query that goes from world space into a building -- `AIWorld`'s DDA, bullets, explosions,
the placer, debris -- should go through the building's transform (`b.xform` and its inverse), not
through `CityPlacer.box_of`'s "a building is on the grid at a quarter turn, so its box is an AABB"
(14 call sites, 7 of `on_grid`). Keep the AABB as a broad phase only. That makes buildings tilted
in a tangent frame free later, and a bent building one function swap.

*Built 2026-10-20:* `BuildingRegistry.to_building`, `to_world`, `own_box`, `contains`, `ray_hit`
-- the one door. `on_grid` snaps in `grid_frame_at(p)` (the world's frame today, the tangent frame
on a planet), so a building's grid follows the ground it stands on. `CityPlacer.box_of` is the
AABB round `own_box` and is documented as the broad phase; the placer's aim ray and the disaster
context's "which building is this point in" go through the building's own space. The other
`box_of` callers (earthquake, material effects, the city's pad and range checks) use it as a broad
phase or a footprint and are right as they are on the flat world; on a tilted frame they are the
list to revisit. The placer itself still snaps to the world's stud grid -- on a planet it will
snap in `grid_frame_at` too.

### 9.3 Room-graph pathfinding

Docs/AI.md §3.6.1. Faster and smarter in the flat game (fewer nodes, doors and stairs understood,
no materialising to route), and it is the half of planet AI that then costs nothing.

### 9.4 The low-poly ground with brick patches on their own frames

Terrain.md 18.6's follow-up: smooth low-poly ground almost everywhere, bricks in patches. Build the
patches as small grids with their own transform (as scatter and buildings are) rather than as
cells of the world's stud grid, wherever the look allows. On a planet those are exactly the
tangent-plane patches of §3.1. In the flat game it is also what lets a patch sit on a slope.

### 9.5 Bake the static ground

~~Cache built tile meshes and colliders to disk.~~ **Measured, not worth it (2026-10-20):** a tile
builds in 2.9 ms on a worker thread (chamfered 3.0 ms) and reading the same tile back from disk
(`bytes_to_var`, 198 KB) took 14 ms -- five times slower, and the build was never on the main
thread anyway: this month's hitches were in assembling nodes and uploading meshes, which a cache
does not touch. What §3.3 wants on a planet is OFFLINE SIMPLIFICATION of static ground, which is
planet work, not a cache.

### 9.6 Keep positions local where they are stored

Saves, the AI's caches and the registry store positions relative to a building or a tile where they
can. A world-space position in a save is the one thing a floating origin cannot shift for you.

*Built 2026-10-20:* `scripts/world_frame.gd`. A save and the damage log's wire form carry world
positions in the BODY's frame (`WorldFrame.to_body` out, `from_body` in): hit points of the
building commands, a resting piece's origin, every piece's transform in a checkpoint, the camera,
the placed builds and the hits still queued. Grid coordinates -- the piece commands, a region's
corners, LOAD's cells -- were never world positions and go as they are. `WorldFrame.origin` is
zero until a floating origin moves it; `tools/world_frame_probe.gd` moves it and checks each.

### 9.7 The bent horizon (§2)

Optional, days. It gives the planet look now and becomes the landing transition later.

### Not now

The cubed-sphere mesher, radial controllers, the per-chunk outdoor charts and the floating origin
are planet-only work with no payoff in the flat game: they wait for the decision to go to planets.

---

## 10a. Decision notes (2026-10-20): size, the sun, the story

### Size: past which nothing needs to know it is on a sphere

**Buildings never need bending at our sizes.** Rigid is invisible while the sag `w² / 8R` is under
a plate (0.14 m) and the tilt at the edge `w / 2R` under half a degree:

| R | widest rigid building | our towers (10–14 m) | a 300-stud build (105 m) |
|---|---|---|---|
| 1.5 km | ~25 m (tilt) | 0.016 m, 0.27° | 0.9 m sag: terrace or gravity zone |
| 6 km | ~80 m | nothing | 0.23 m |
| 10 km | ~105 m | nothing | 0.14 m |

Bent bricks (§4.2) are only for LONG things: a street grid, a wall, a ring city (a 1 km city sags
12.5 m at 10 km). Cities become districts on their own tangent frames, with the slopes ground
between them.

*2026-10-21: the bubble below is now the **alternative**; the chosen route is local down, §10b.*

**The AI, physics and controllers need nothing special if the simulation runs in a flat
bubble.** Instead of radial gravity everywhere, keep ONE flat frame for the active area -- the
floating origin plus a floating ROTATION, so the bubble's centre is at the origin with its up
along +Y -- and simulate everything in it exactly as today (every `Vector3.UP`, the `.y` logic,
`AINav`'s columns, the stress solver). The ground and buildings are drawn where they really are
on the sphere; the curve inside the bubble is just a gentle hill to the nav map (300 m out on
10 km is 4.5 m down). The only error is gravity: constant over the bubble where it should tilt
`d / R` at distance `d`:

| bubble radius | under 1° | under 2° |
|---|---|---|
| 150 m | R ≥ 8.6 km | R ≥ 4.3 km |
| 300 m (a mech's sight) | R ≥ 17 km | R ≥ 8.6 km |

So **~10–20 km planets** (moons ~5 km for set pieces) let the gameplay code stay flat. Re-anchor
the bubble when the FIGHT moves, not the player -- at a mech drop, a landing, between encounters
-- because a re-anchor moves every physics body (a hitch) and drops `AINav`'s columns and the
hierarchy's caches in the area (a cold search was 214 ms against 87 ms warm, §4.3 of AI.md).
Radial gravity is then only for the ship's flight, orbits, and things far from any bubble (frozen
or impostors).

What the bubble does not solve: **co-op players far apart.** Two bubbles 2 km apart on 10 km are
11° apart and cannot share one flat frame. Either missions keep the squad together (a leash of
~1 km), or each bubble gets its own physics space (Godot can run several) -- the second is real
work.

Horizon at 10–20 km: 180–260 m on foot, 450–630 m from a mech; the curve shows from the air (1 km up on
10 km the horizon is 4.5 km off and visibly round). Surface 1,250–5,000 km², procedural.

### The sun as the solar system's light

Never a real point light: an `OmniLight3D` at planet-to-sun distance has no usable shadows (six
cube faces, range and precision). The sun is **one `DirectionalLight3D` whose direction is set
from the sun's position relative to the bubble** -- what the game has now, so the ground's frame
cost does not change. What it changes:

* **The sun's height depends on where you stand**: 1 km on a 6 km body is 9.5° of sun. On a
  NON-rotating planet every place keeps its own time of day forever, and the baked terrain
  shadows (Terrain.md 19.9) stay free: each tile is baked with its own local sun direction.
* **A day/night cycle costs the bake.** Baking saved 1.6 ms a frame (4.9 → 3.3 ms, 19.9). A moving
  sun either re-bakes tiles near the player every few degrees (a tile is 2.9 ms on a worker) or
  has the terrain cast into the shadow map again (+~1.6 ms). The sky's radiance re-render on sun
  moves is extra (not measured; update every few degrees).
* **Night side** needs lights of its own; clustered omni lights are cheap, shadowed ones are not.
* **From the air and orbit**: an atmosphere shader on the planet's shell, about a full-screen pass
  (estimate ~0.5–1.5 ms at 720p on the Z1 Extreme, not measured), only while flying. Planets and
  satellites seen from space are impostors lit by the sun direction: nothing. An eclipse by the
  moon is an analytic sphere test in the shader: a few ALU.

Rough total: a fight on the ground costs what it does now; flight adds the atmosphere; a day cycle
adds ~1.6 ms or a re-bake schedule.

### What the story gets from real orbits

The story (enemy satellites change the weather and cause disasters; destroy them, then the moon
base) fits a **bounded system**: one planet, its moon, satellites on rails -- not free planet
hopping, which can come later on the same tech.

* **Satellites are real objects overhead.** A storm comes where a satellite's ground track passes:
  the player sees it rise, can time strikes, and a destroyed one falls as a burning streak.
  Satellites are brick builds -- destructible, with interiors, room graphs and marks, gravity
  off inside.
* **The mech drop is literal:** the player's ship is overhead and the drop is a fall from orbit
  into the bubble (the natural moment to re-anchor it). **Enemy reinforcements need their carrier
  overhead**, so killing the carrier cuts them off -- an objective the systems make, not a script.
* **The moon base is in the sky the whole game**, and can eclipse the sun.
* **Cost:** a ship flight mode (new code either way), orbits on rails (no n-body), the bubble and
  re-anchor, the cubed-sphere ground, districts on tangent frames. The flat game can fake most of
  the look -- an impostor ship overhead, drop pods from the sky, space as separate scenes -- but not
  the continuity or the satellite tracks.

## 10b. Decision (2026-10-21): local down, translation-only origin, single precision

The user: planets are spheres, curved everywhere with few flat areas; everything should have its
own down from where it is, bullets inheriting it, so on a big planet the downs barely differ and
nothing has to be re-centred the way the bubble is. Chosen over the bubble of §10a, which stays
the alternative.

### Local down: everything takes its down from where it is

| what | its down | work |
|---|---|---|
| debris, falling bricks, pieces, loot | toward the planet's centre: Godot point gravity on an `Area3D` | none: Jolt applies it per body |
| buildings (and their stress solve, hangs, collapse) | their own frame, square to the ground at their site (`grid_frame_at`, §9.2) | the solver already runs in building space; tangent placement is new |
| bullets, rockets, grenades | the shooter's down when fired, then straight | trivial. Over a 300 m shot on 10 km gravity's direction is 1.7° off: the drop is wrong by ~3% of itself, centimetres |
| players, soldiers, mechs, vehicles, the camera | `Gravity.up_at(p)` (built, §9.1) | ~6 controllers rebuild their whole basis from up every frame (STA doc 05: the strafe-drift fix); their `.y` logic becomes "along up" |
| the AI | the down of the **nav region** or building it is in | the big item, below |

**The AI through local frames.** The AI's code assumes +Y is up about 580 times (~280 `.y` and
~150 `Vector3.UP/DOWN` in `scripts/ai`, ~150 `.y` in the AI C++), and `AINav` is columns of studs
along world Y. Rather than change those, give each **nav region** its own flat frame and let the AI
see the world through the frame of the region it is in -- then nearly all of that stays true:

- A terrain tile is 32 studs (11.2 m): on a 10 km planet it sags 1.6 mm and tilts 0.06° across.
  A region of 8 x 8 tiles (90 m) sags 0.1 m (under a plate) and tilts 0.26°: flat to anything the
  AI measures. Regions are `AINav`'s HPA* clusters (`ai_nav_hpa.cpp` is already clusters joined
  at borders), each with its own transform; a path crossing a border crosses frames there.
- Inside buildings the AI routes by the room graph in building space (`BuildingLayout`, §9.3) --
  no curvature ever reaches it.
- `AIWorld`'s queries (line of sight, DDA through bricks) already go into a building through its
  own transform (§9.2); between buildings a ray is a ray.

Every region is in effect a small flat bubble that **never moves** -- so nothing is re-anchored and
no cache goes cold when the fight moves.

| | bubble (§10a, the alternative) | local down (chosen) |
|---|---|---|
| controllers | unchanged | ~6 rebuild their basis from up |
| AI | unchanged | nav regions with their own frames (large); most AI code unchanged |
| re-centring | rotate + move the whole area: a hitch, `AINav` caches dropped (214 vs 87 ms) | translation only, rare, nothing recomputed |
| co-op players apart | leash ~1 km or a second physics world | anywhere (precision aside, below) |
| gravity error | 1-2° at the bubble's edge | none |
| long shots | straight in the bubble | straight, with the shooter's down |

### Precision: one origin, moved by translation only

The direction of down no longer needs re-centring; **precision** still does. With the origin at the
planet's centre the surface is 10-20 km out, where a 32-bit float steps 1-2 mm. Godot's guidance
(Large world coordinates) is about 2 km from the origin for a first-person game, ~8 km for a whole
open world on foot: past that, the gun and hands jitter and stacked bricks wobble in physics.

So: **one origin per planet, moved by translation only** -- STA's floating origin
(`solar_system.gd`, every 500 m) or zylanntest's `solar_system_manager.gd` (`shift_world`) --
when the player is ~2 km from it, at a quiet moment if possible. Nothing turns, so building
frames, nav regions and their caches are untouched; the cost is moving every body and node once.
What must follow the shift is whatever holds an absolute position: `BrickWorld` chunk transforms,
`AIWorld`'s spatial hash, the registry's boxes, `AINav` region origins (§6, §9.6).

**Orbits do not move the ground.** While anyone is on a planet, the planet is the fixed frame and
the sun and sky move round it (STA doc 12's two frames); the solar system's coordinates are only for
flight and the sky.

### Double precision: checked, not worth it (2026-10-21)

| | |
|---|---|
| builds | no official double builds: the editor and export templates compiled with `precision=double`, then `--dump-extension-api` and godot-cpp and our extension rebuilt against it (`custom_api_file`, as Terrain3D documents) -- again at every Godot upgrade, and for every chat's worktree and the test binary |
| physics | Godot's Jolt module defines `JPH_DOUBLE_PRECISION` in a double build (`modules/jolt_physics/SCsub`): positions double, velocities, rotations and the broad phase still float; Jolt's docs: **5-10% slower** |
| rendering | camera and object translations are emulated as two floats (a small cost); **shaders stay single** -- our 8 shaders that use world positions (terrain, water, studs, impostors) would still jitter far out unless rewritten camera-relative |
| our C++ | `Vector3` / `Transform3D` become double: mesh arrays double on the CPU (the GPU stays float); ~1,000 explicit `float`s in the extension to check for places that drop the precision again |
| co-op | server and clients must run the same build |

It pays only for co-op spread across a whole planet with no other answer, or seamless space without
any shifting. Translation-only shifting does the job for 10-20 km planets.

### How other games do it

- **Minecraft Java** keeps entity positions in 64-bit doubles and draws relative to the camera; its
  own simple physics is all doubles, so it never shifts an origin. Jitter still showed from
  ~40,000 blocks in older versions. **Bedrock** uses 32-bit floats and jitters from ~131,000
  blocks. We cannot copy Java's way directly: our physics is Jolt, in floats.
- **Unreal's** ordinary origin rebasing does not work in multiplayer (server and clients cannot
  have different origins); its multiplayer rebasing sends positions in an absolute frame.
- **Networking SDKs** (coherence for Unity): the server holds absolute 64-bit positions, each client
  has its **own** floating origin and works in 32-bit near it. The catch they all name: the
  server's own physics cannot run in 64-bit with a stock engine, so far-apart players need the
  world split into simulators, each near its own origin.

### Co-op players far apart: two origins

Yes, by the last pattern. **Each group of players gets its own region: its own origin and its own
physics space** (in Godot a `World3D` holds a physics space; a second one lives in a viewport that
draws nothing), and the host simulates both. Positions on the wire and in saves are planet-local
(`WorldFrame`, §9.6 -- built), so each client places what it receives near its own origin.

- What sits in a region -- buildings, pieces, enemies -- belongs to it; something crossing between
  regions is handed over (the frame handoff STA uses for ships).
- When the groups come within ~2 km of each other, the regions merge into one.
- Local down makes it simple: buildings and nav regions are stored in their own frames, so a
  region's origin is only which point is at zero.
- Not yet checked: that Godot's Jolt runs two spaces independently (`PhysicsServer3D.space_create`).
  First test before relying on it. Until then, missions keep the squad within ~2 km.

### The far tier shows what still stands

Each far building is one instance of one MultiMesh (Impostors.md); it gains one number, its
**standing height**: the top of the highest storey still joined to the ground. Its top half gone,
the box ends at the break; a storey damaged in the middle with the top still standing, the whole
height (the scars in the facade data). Pieces that broke off are never in the far tier -- near,
they are pieces; far, asleep and hidden. The storey record of Space.md §5 is what gives the height.

### Bending

Rigid buildings on tangent pads are the default; at 10-20 km a 100 m building sags 0.14-0.9 m.
Bending (§4.2) stays possible and visual only -- the AI keeps the flat building -- for long things.

### Feasibility tests (2026-10-21)

Before any planet work: does anything break the route above? Prototype measurements only -- probes
and passes under `tools/`, nothing that changes how the game plays. Each ends **passed**, **problem
found** (with the size of the fix) or **plan-breaking**. Windowed runs one at a time, the heat log
read after each; timings only with the editor closed.

The scene passes run inside the city scene (it has the buildings, pieces, pawn, gun and AI wired
up) through one hook, `-- --planet=<test>`, that hands the scene to `tools/planet_passes.gd`; the
city scene gains those lines and nothing else.

**Tier 1 -- could break the plan**

| # | test | how | passes if |
|---|---|---|---|
| 1 | jitter at distance | a small brick scene -- one building, a stack of loose bricks, settled pieces, the pawn with arms and gun -- moved to 2, 8 and 15 km from the origin (along the diagonal, the worst case per axis) and left there. The camera strafes 1 mm a frame. Pictures of the viewmodel and of a brick 2 m away at each distance; per frame, the gun's transform relative to the camera (float32, as the GPU gets it) against its value at the origin; the stack's drift, its sleep state and Jolt's contacts over 20 s | at 2 km nothing a player could see; the doc's ~2 km shift distance stands |
| 2 | origin shift cost | the terrain city, debris settled, soldiers out; ONE frame moves everything by ~2 km in whole 32-stud tiles, through a reusable shift function. Measured: the frame's time, the sleeping bodies before and after, pictures before/after with the camera moved by the same offset (pixel difference per shader), and a list of every place that holds an absolute position | under the user's guess of 5-30 ms; no wake storm; no visible change, or a known fix; every holder listed with its fix |
| 3 | tilted building, point gravity | a tower on a pad tilted 7°, its frame square to the pad; an `Area3D` with point gravity toward a centre 10 km below the pad. Shoot it, blast it, collapse it, let it settle | the solve, hang check, pieces, sleep and collision work in the building's frame; every remaining "AABB / world grid" assumption listed with its size |
| 4 | debris and gravity reads | grep: every read of fixed gravity or +Y-as-down for loose bodies and VFX outside `gravity.gd`; then pieces dropped on a curved ground (a small sphere with point gravity, the curvature exaggerated) | pieces come to rest on the curve and sleep; the list sized |

**Tier 2 -- needed for the route, with fallbacks**

| # | test | how | passes if |
|---|---|---|---|
| 5 | walking round a sphere | a plain-mesh sphere planet, `Gravity` pointed at its centre (a test hook, off by default), the pawn and the mech on local down after STA doc 05's radial controller | strafing with no drift, jumping, slopes, mantling and the camera behave; a full great-circle loop ends where it began |
| 6 | cubed-sphere ground | our terrain tiles' meshes mapped onto a cube face edge and a corner by STA doc 23's mapping, with trimesh colliders | no visible seam, no collision gap, walking over the edge smooth |
| 7 | two physics spaces | two `World3D`s (the second in a viewport that draws nothing), bodies in both, stepped together | no interaction; the second space's cost measured |
| 8 | two nav regions | two flat nav regions 1-2° apart, each in its own frame, joined at a border; a path across | the joined path is continuous across the border and the AI's flat assumptions hold inside each |
| 9 | moving sun | frame cost of terrain casting real-time shadows against re-baking nearby tiles every few degrees (§10a "The sun": baked saves 1.6 ms; a tile bakes in 2.9 ms on a worker) | one of them affordable |

Results below, as each test is run.

#### Test 2, origin shift: problem found (fixes small to medium), not plan-breaking

`tools/planet_origin.gd` -- `shift(city, offset)`, one frame, whole 32-stud tiles (11.2 m). It moves
every Node3D with no Node3D above it (children follow) and resets their physics interpolation;
the static bodies that live only on the physics server (shells, rooms, bands, terrain tiles, the
sea); every BrickWorld chunk transform; the registry's building transforms; the AI (new C++
`AIWorld.shift_origin`: proxies, cover, smoke, danger, and the ground asked at the shifted stud
column); drops `AINav`'s caches; and moves `WorldFrame.origin` the other way.

Checked by asking the scene the same questions before and after, moved by the offset (1.41 km X,
1.41 km Z): 600 random physics rays, 200 AI lines, a path across the city, the sleep census.

| | plain city (22 buildings) | terrain city (822 registry entries, 277 tiles, sea) |
|---|---|---|
| rays the same | 600 / 600 (worst 0.84 mm) | 599 / 600 (one tile collider at the streaming edge), worst 0.10 mm |
| AI lines the same | 197 / 200 (3 off by 0.01 of a proxy brick: rounding) | 199 / 200 |
| path across the city | the same 97 points, 216.6 m | -- |
| sleep | 22 Jolt-asleep bricks stay asleep, 2 settled pieces stay frozen, 0 woken | the same |
| pictures (plain city, 3 views) | 0.00 / 0.75 / 1.08 % of pixels differ (two shots before it: 0.01 / 0.11 / 0.00 %) | the sea vanishes (below) |
| first frame after it | identical to before: no interpolation smear | |

**No wake storm.** Moving a sleeping body's transform does not wake it in Jolt, and the city's own
"sleep" (a settled piece is frozen, a quiet one dormant as a record) is untouched.

**Cost.** The user's guess of 5-30 ms holds at the low end. The prototype found the server-only
bodies with one 30 km shape query (9-250 ms, not counted: a real shift keeps a list).

| step | plain | terrain |
|---|---|---|
| nodes + interpolation reset | 0.7 ms | 4.0 ms |
| server-only bodies | 0.07 (23) | 0.9 (532) |
| chunks, registry | 0.03 | 0.45 |
| AIWorld shift + sync | 0.03 | 7.0 |
| AINav caches dropped | 13.2 (warm with one 216 m path) | 0.03 (empty) |
| frame with the shift | 26.8 ms against 13-22 round it | ~23 ms, +~12 |

The one thing that scales badly is dropping `AINav`'s caches: 13 ms for one path's worth, several
times that after a fight, then cold searches (127 ms against 21 warm here). **Fix (small C++):**
key `AINav` by field column with one integer origin at its boundary, as `AIWorld`'s ground now is
-- the shift is then free for it and the caches stay warm.

**What breaks: everything keyed by world stud column into the static field.** In the terrain city
the sea and the underwater tint vanish after the shift, because the water's wet cells, shore field
and mask/seabed textures are looked up at the new world column, where the field has dry land.
Ground, buildings, trees, bricks and their studs are unchanged (the shift is whole tiles, so the
world-space stud lattice of the terrain and brick shaders lands on itself).

![terrain city: the sea before the shift, gone after](Planets/t2_terrain_before_after.jpg)

What holds an absolute position and must follow a shift:

| where | what | fix |
|---|---|---|
| BrickWorld (C++) | chunk transforms | loop over chunks (done in the shift) |
| AIWorld (C++) | proxies, cover, smoke, danger, ground cache | `shift_origin` (built) |
| AINav (C++) | columns and clusters keyed by world stud; pending path and cover requests (goal, path, breaches); water level is absolute Y; columns count plates from y = 0 | field-column origin (small); a vertical shift needs the nav regions' own frames (test 8) |
| BrickTerrain (C++), TerrainStreamer, TerrainCoarse | the field is sampled at world stud columns; tiles keyed by world tile | one integer tile origin in the field, applied at every world-to-column conversion (medium-small, terrain area); the streamer was frozen for the test |
| sea and water (BrickWave, water_sea / sheet / surface) | wet cells, shore field, `snapped_origin`, `seabed_origin`, `pool_mask_origin`, `hole_centre` | the same field origin (water area) |
| SnowCover, BrickHeap | squares and heap cells keyed by world XZ; heap `_tops` height per world stud | the same |
| IslandManager | crumbs' positions and floor heights, dormant records (`ChunkRecord.xform`, box) | shift them (small) |
| MultiMeshes with world instance transforms (crumbs, heap, joined pieces) | nodes moved by the shift, but later writes are world positions | keep those nodes at identity and shift the instances, or write positions relative to the node |
| swarm (C++) | ~17 world positions: rows, goals, lattice and field origins | shift (small) |
| ImpostorSet (C++) | instance transforms | shift (small) |
| GDScript AI and gameplay | ~180 typed position/vector members in 76 files, about half positions: goals, paths, rally / breach / cover points (soldier 11, mech brain 12, vehicles ~10, squads, commander), danger and airspace boxes, storm paths, ledge and hook points | STA's `origin_shift` group: each holder adds the offset (mechanical, 1-2 days), or shift only between encounters and re-plan |
| GPU particles in world space | the emitter moves, live particles stay | accept at a quiet moment, or restart |

#### Test 3, tilted building under point gravity: problem found (small to medium), not plan-breaking

`--planet=tilt [--tilt=7]` (`tools/planet_tilt.gd`): a 70 m pad in a tangent frame, an `Area3D`
with point gravity toward a centre 10 km below the pad (replacing the project's), a 16 x 16 tower
of 30 courses registered as any is and then **re-framed onto the pad** -- `on_grid` would have
snapped the tilt away, since `grid_frame_at` is still the world's frame. Shot (six small blasts up
a face), then its ground storey blasted out, then left to settle. Run at 0° (the baseline), 7°
(a building 1.2 km round a 10 km planet) and 60°: with a translation-only origin the scene's axes
never turn, so most of a planet is further round than 7° -- 60° is the honest case.

| | 0° | 7° | 60° |
|---|---|---|---|
| stands when made bricks (752) | yes | yes | yes |
| chunk gravity | grid -Y | grid -Y | grid -Y |
| shot: bricks left | 686 | 686 | 686 |
| collapse settles | 135 ticks | 139 | 190 |
| the falling section | 1 piece, on the pad, frozen | the same | the same |
| crumbs laid on the heap | 207, flat on the pad (0.0°) | 204, **turned 7.0°** from the pad | 222, **median 32 m below the pad**, 36° off: they fell along world -Y |
| AI line square through it | 2 bricks | 2 | 2 |
| AI: stand on its ground floor | -- (baseline) | as the baseline | snap moves it 60 m: columns run along world Y |

- **Stress solve, hang check, collision: work in building space at any tilt.** The solve and the
  hang rule run in the chunk's own grid, and a building on a tangent frame has its grid -Y along
  local down, so the default chunk gravity is right. (`set_chunk_gravity` snaps the world's down to
  the nearest grid axis: past 45° that would be a building on its side -- but nothing should ask it
  for a standing building, whose down IS its grid -Y.) Shells and bands collide where they are
  drawn.
- **Pieces: work.** Jolt applies the area's point gravity to every loose body; the falling
  section lands on the pad and settles, at 60° as at 0°.
- **Crumbs and the heap: broken past a few degrees.** They are integrated along world -Y with a
  floor height found by a ray down -Y, and laid flat in the world (`BrickHeap`, IslandManager
  ~1900-2160). Fix: integrate along `Gravity.down_at`, floor along the local down, lay square to
  the local up, heap cells in the tangent frame -- small to medium.
- **IslandManager's support checks** (rays down -Y `SUPPORT_REACH`, `SUPPORT_NUDGE`,
  `MAX_RISE_SPEED` on `.y`, impact on `linear_velocity.y`, `_wake_resting_on` comparing box Y) did
  not misbehave here -- the section landed flat on the pad -- but each is a -Y assumption that a
  piece resting on a slope will meet. Same fix, same list as test 4.
- **The AI's view:** lines go into the building through its own transform and count the same
  bricks at any tilt. Navigation does not: `AINav` columns are along world Y, so on a tilted floor
  it finds no standing place -- the room graph (§9.3) and nav regions in their own frames (test 8)
  are what fix it.
- **Code still assuming the AABB or the world grid:** `on_grid` / `grid_frame_at` (must return the
  tangent frame), the placer's snap, `_index_building` (an XZ hash of the 8 corners: fine as a broad
  phase), and the `box_of` callers -- the placer (2), the city (4: pad and range checks, a fall
  line), the disaster context (3), the earthquake (3), material effects (1). All are broad phases or
  footprints that work on a tilted box's AABB, but a fall line or a "which building is this point
  in" through them must go through `BuildingRegistry.contains` instead.

#### Test 4, fixed gravity and +Y-as-down for loose bodies and VFX: problem found (small to medium)

**Pieces come to rest on curved ground.** `--planet=tilt --ground=sphere`: a 40 m sphere (the
curvature 250 times a 10 km planet's) with point gravity to its centre and a 12 x 12 tower in the
tangent frame at 0°, 45° and 90° round it, each brought down and its fallen section broken up
again where it lay.

| tower at | pieces | settled | centres over the ground | laid bricks near it | their faces off the ground's |
|---|---|---|---|---|---|
| 0° | 2 | 2 | -0.65 .. 2.14 m | 192 | median 5.4° (the small sphere's curve) |
| 45° | 2 | 2 | 2.08 .. 2.16 m | 60 | median **42.8°** |
| 90° | 3 | 3 | -0.26 .. 2.12 m | **1** | 24° |

Of 820 laid bricks, 253 are on the sphere and **567 fell to the world's flat ground 50 m below**.
Rigid pieces are right everywhere (Jolt); crumbs and the heap are right only where the scene's -Y
is the local down.

What reads fixed gravity or uses -Y as down outside `scripts/gravity.gd` (loose bodies, VFX,
projectiles), ~25 places in ~15 files:

| file | what |
|---|---|
| island_manager.gd | crumbs: `v.y -= g * dt`, floor by a ray down -Y (`_crumb_floor`), laid at `floor_y`; support rays down -Y (`_under`), `SUPPORT_NUDGE` along -Y, `MAX_RISE_SPEED` and impact tests on `.y`, `_wake_resting_on` comparing box Y; `DEBRIS_GRAVITY` is a `gravity_scale` and follows the area (fine) |
| brick_heap.gd | lays flat in the world (`cols[up] = Vector3.UP`), piles by a height per world stud |
| ai/danger.gd, city_scene.gd (path ahead) | a falling piece's predicted path along -Y |
| autoload/vfx_pool.gd | shards fall along `Gravity.down_at` (right) but land on a `floor_y` plane |
| disasters: hailstorm, rain_splash | particle gravity `Gravity.down_at(Vector3.ZERO)`: the origin's down, not the emitter's |
| disasters: sandstorm, tornado, meteor_shower, acid_rain, lightning_storm, brick_fire | directions and ground rays along ±Y |
| ai/air_strike.gd | fall along -Y with its own `FALL_G` |
| loot/world_gun_pickup.gd, pawn/player_arsenal.gd | floor rays down -Y |
| tank, truck, debug camera, pawn, dart, grenade, flyer, titan | already `Gravity.down_at` (§9.1); their `.y` logic is the controllers' work (test 5) |

Fix: each takes `Gravity.down_at(p)` at its own position, and `Gravity` answers from the planet
(a point toward the body's centre). Mechanical, ~1-2 days; the crumbs and the heap are the part
that needs thought (a heap in a tangent cell).

#### Test 7, two physics spaces: passed

`tools/planet_spaces_probe.gd` (headless, `--fixed-fps 30`, frames flat out): a second `World3D`
in a `SubViewport` that never draws (`UPDATE_DISABLED`), and a pile of 400 boxes dropped onto a
floor in each **at the same coordinates**.

- The two piles come to rest identical to 0.000000 m and four boxes high (shared, they would be
  eight); a ray in the first space meets only its own bodies. The spaces are separate Jolt
  `PhysicsSystem`s, as Godot's module promises.
- Cost, per tick, while the piles fall (another chat's run was on the machine, so roughly):

| bodies | one space | two spaces |
|---|---|---|
| 400 (+ an empty second space) | 0.24 ms | 0.24 ms |
| 800 | 0.44-0.77 ms (two piles side by side) | 0.42-0.56 ms (400 in each) |

An empty second space costs nothing measurable, and a body costs the same in either: the second
region's cost is its own bodies. Asleep, both are 0.01 ms.

## 10. If it is taken up: order of work

1. **Prototype, outside the game:** one planet of our low-poly tiles on a cubed sphere, baked;
   STA's radial controller; translation-only floating origin; one rigid building on a tangent
   pad. Gate: seams invisible, walking over a face edge seamless, the building's roof level, no
   jitter 15 km from the planet's centre after a shift.
2. Streaming and LOD per face; STA's impostor from orbit.
3. Buildings: tangent placement through §9.2; destruction under point gravity.
4. AI: room graphs (§9.3), nav regions with their own frames (§10b).
5. Controllers on local down; water shell; co-op in planet-local positions, two regions if needed
   (test Jolt with two spaces first).
6. Bent buildings, if long things want them.
