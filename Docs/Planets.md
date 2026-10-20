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
| mesh | generated per tile while streaming | **baked once** (at world build or first visit, cached to disk) and simplified per chunk -- flat ground collapses to a few triangles |
| collision | 100–200 merged boxes a tile | one heightmap shape a chunk, baked |
| lighting | sun shadow baked per vertex already | the same, plus baked AO |
| navigation outdoors | brick-column grid, read live | **baked once** per chunk (§7) |
| edit store | copy-on-write sculpt tiles | none at runtime |
| explosions | (already do not dig) | scorch decals |

Streaming becomes LOADING, not generating -- which is where most of this month's terrain hitches
came from. Triangles: indestructibility does not remove any by itself; it permits offline
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

### 9.3 Room-graph pathfinding

Docs/AI.md §3.6.1. Faster and smarter in the flat game (fewer nodes, doors and stairs understood,
no materialising to route), and it is the half of planet AI that then costs nothing.

### 9.4 The low-poly ground with brick patches on their own frames

Terrain.md 18.6's follow-up: smooth low-poly ground almost everywhere, bricks in patches. Build the
patches as small grids with their own transform (as scatter and buildings are) rather than as
cells of the world's stud grid, wherever the look allows. On a planet those are exactly the
tangent-plane patches of §3.1. In the flat game it is also what lets a patch sit on a slope.

### 9.5 Bake the static ground

Cache built tile meshes and colliders to disk, keyed by world, edits generation and tile. Streaming
then loads instead of generating -- the hitches go, and §3.3 is already half done.

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

## 10. If it is taken up: order of work

1. **Prototype, outside the game:** one planet of our low-poly tiles on a cubed sphere, baked,
   STA's radial controller and floating origin, one rigid building on a pad with a gravity zone.
   Gate: seams invisible, walking over a face edge seamless, the building's roof level.
2. Streaming and LOD per face; STA's impostor from orbit.
3. Buildings: tangent placement through §9.2; destruction under point gravity.
4. AI: room graphs (already done by then, §9.3), outdoor charts per chunk.
5. Water shell; co-op and saving in planet-local positions.
6. Bent buildings, if wide buildings on small bodies are wanted.
