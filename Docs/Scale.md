# City scale: interiors, destruction, and what other people found out first

How a city of fully destructible buildings *with interiors* is supposed to work, what the shipped
games do, what stops them, and where this project stands against that.

Written because of a proposal worth taking seriously: **bake interiors for their LOD levels, draw
the cheap version until something touches them, then switch to the real destructible thing — warm
on approach, unwarm if untouched, and resolve an unwarmed room procedurally if it is destroyed
without ever having been looked at.**

Short answer: that is the right shape, it is what the ladder already does for buildings
([Plan §4.2](Plan.md)), and two thirds of it exist. What is missing is the middle rung — and the
proposal's own best idea is the part that names it.

Four decisions taken here, which the rest of the document is written against:

* **everything is authored in the workshop eventually** — buildings and their interiors both;
* **only the terrain is protected**; every structure in the city can come down;
* **the debris cap is two connected caps**, so large pieces outlive small ones, with ages and
  oldest-first eviction;
* **baking is per item type**, and it is what makes authored interiors affordable.

---

## 0. Conclusion first

1. **The proposal is correct and the project half-implements it already.** Rooms have a truth layer
   (a seed and a diff) and a real layer (blocks in the host's grid). They have no *cheap* layer: a
   room is either nothing or fully laid brick. That is the gap.
2. **Baking is worth it — per item TYPE, never per room.** Baking a room's contents into the
   building is the thing to reject, and there is a measurement behind that: interiors were in the
   building's face bake until recently, and taking them out dropped a room from 225 ms to 0.9 ms and
   a furnished building from +50.7 MB to +1.0 MB ([Status](Status.md)). Baking a *chair* once, and
   instancing it everywhere a chair stands, is the opposite trade and it is how every engine ships
   props. See §4.2.
3. **The industry's answer to "hundreds of objects in a room" is not a faster physics engine.** It
   is that almost nothing in the room is a physics object, almost nothing is an individual draw,
   and nothing is asked a question proportional to how much exists.
4. **What holds games back is not object count. It is authoring cost and design cost.** Every
   shipped fully-destructible game is fully destructible over a *small, authored* space. Nobody has
   shipped city-scale full destruction with interiors. That is the actual frontier, and it is where
   procedural generation — this project's whole premise — is an advantage rather than a shortcut.
5. **Our real risk is not the same as theirs.** They pay artists to pre-fracture; we generate. They
   fight network determinism; we have a deterministic integer model already
   ([Multiplayer §3](Multiplayer.md)). Our exposure is *resident cost* — how much a city of warm
   buildings holds when nobody is shooting.
6. **Authored buildings kill the room lattice**, and that is the largest consequence of the plan to
   build everything in the workshop. Rooms are found by arithmetic today only because a generated
   tower puts them on a regular grid. An authored building has rooms wherever its walls are. The
   answer is not to keep the lattice or to replace it, but to put both behind one index — and to
   get rooms, storeys, portals and the neighbour graph out of a single flood fill of the building's
   own empty space. See §4.6.

---

## 1. What shipped systems actually do

Sources are at the bottom. Two of the most relevant talks (Embark's on THE FINALS, Ubisoft's on
Siege) are behind the GDC Vault paywall, so those two are secondary summaries and are marked as
such rather than quoted as fact.

### 1.1 Pre-fracture, don't fracture

**Red Faction: Guerrilla (2009)** is the closest relative this project has. Geo-Mod 2.0 dropped the
real-time CSG of the first game and moved to **pre-broken meshes with a stress-based collapse
model** — a "voxel-like representation of structural integrity", with buildings composed of
destroyable components that fail when the layers below them can no longer carry what is above.
Notably it also used **stress-based collapse delays to avoid real-time computation spikes**: the
answer is computed, and the *consequence* is spread over frames.

That is our `solve_stress` / `check_stability` / `find_detached_groups` split, and our
budget-per-tick, arrived at seventeen years apart.

**Control** keeps two versions of an object, intact and destroyed, and swaps. That is the cheapest
possible destructible: no simulation at all, just a state change.

### 1.2 Real-time fracture is the expensive option, and everyone bounds it

Real-time Voronoi or FEM fracture is the highest-fidelity approach and the one that "rapidly
inflates memory usage for complex scenes". Reported symptoms are the familiar ones — frame rate
falling from a 30 fps target to 22-23 during destruction events, script time up to ~18.6 ms on
low-spec hardware.

The mitigations are always the same list: LOD on fragments, frustum and occlusion culling that
excludes debris from *physics as well as rendering*, instancing shared debris meshes, deleting
small or dormant fragments, and **modular chunking** — buildings segmented into blocks joined by
breakable joints, which is our grid.

### 1.3 Voxel games make the loose voxels the physics objects, and cap them

**Teardown** builds objects out of voxel clusters; when voxels come loose from a cluster they
become new rigid bodies. The interesting part is not the technique, it is the shipped setting:
Teardown exposes **maximum debris count and maximum debris size** to the player, and anything under
the threshold is not processed at all.

A shipping voxel destruction game gives up on simulating all of it and says so in the options menu.
Our `IslandManager` dormancy, small-piece discard and "bricks discarded unseen" counter are the
same admission, made internally.

### 1.4 Multiplayer moves the whole simulation to the server

**THE FINALS** runs destruction server-side and replicates the result, so every client sees the
same debris in the same place. This costs bandwidth and latency and buys away the entire class of
"my wall fell differently from yours" bugs.

We have chosen the other road — a deterministic integer model where the same commands produce the
same collapse everywhere ([Multiplayer §3](Multiplayer.md)). That is cheaper on the wire and
strictly harder to keep true; every float that creeps into the structural path is a divergence.

### 1.5 Destruction *masking* instead of destruction geometry

Frostbite 1 had artists UV-map a destruction mask per destructible part; Frostbite 2 replaced that
with signed volume distance fields and deferred decals, which is faster and — more importantly —
removed a per-asset authoring step.

The lesson is about workflow, not rendering: **the thing that got fixed was the artist's time**,
not the frame time.

### 1.6 Streaming: cells, not radii; packed actors, not actors

The standard open-world answer is a grid of cells loaded around the player (UE5's World Partition
defaults to 256 m cells), hierarchical LOD that merges whole clusters of distant objects into one
mesh with one texture, and instanced static meshes for repeated props. Crucially, **"each prop as a
separate actor introduces overhead"**, so engines provide Packed Level Actors to collapse many
props into one container.

Interiors specifically are authored once as a Level Instance and instanced many times.

---

## 2. The failure modes everyone hits, and the fix

| Failure | What it looks like | The standard fix |
|---|---|---|
| **Physics body explosion** | A collapse spawns thousands of dynamic bodies; the solver stalls | Budget spawns per tick; merge settled pieces; sleep aggressively; discard small debris; cap total debris |
| **Contact explosion** | Bodies overlap or rest in piles; the constraint solver runs out | Merge collision for anything at rest; never respawn geometry where debris lies; raise or respect the manifold cap |
| **Per-object work** | Cost grows with what exists, not what changed | Spatial index; cell/portal graphs; work proportional to the neighbourhood |
| **Draw call explosion** | Hundreds of props in a room = hundreds of draws | Instancing, merged/packed actors, hierarchical LOD |
| **Memory inflation** | Fracture data and per-piece meshes dwarf the level | Pre-fracture shared across instances; procedural regeneration from a seed; drop data for anything dormant |
| **Network divergence** | Two clients see different rubble | Server authority (THE FINALS) or a deterministic integer model |
| **Authoring cost** | Every destructible needs an artist pass | Procedural fracture; masks rather than geometry; generation from recipes |
| **Design cost** | Players destroy the level's routing and pacing | Bound *where* destruction is allowed; keep structural cores indestructible |

The last two are the ones that actually stop projects. As one designer put it, "a fully
destructible environment is compelling for the player but a nightmare for the game designer."

---

## 3. What actually holds games back

Not the physics. Three things, in order:

1. **Authoring cost.** Full destructibility multiplies the art budget by the number of damage
   states. This is why destructible games are small: you can afford to pre-fracture a Siege house,
   not a city.
2. **Design control.** Destruction deletes the level designer's sightlines, cover and routing.
   Shipped games answer this by *restricting* destruction — Geo-Mod 2.0 explicitly excludes level
   borders and terrain; Siege makes surfaces destructible per material, not universally.
3. **Determinism and bandwidth**, once it is multiplayer at all.

Frame time is a constraint, not the wall. DICE's stated reason for more destruction in the current
Battlefield is dropping last-generation consoles and spending the RAM and CPU headroom that freed —
which is to say, the ceiling moved because the hardware floor moved, not because anyone invented a
new algorithm.

**Where this project sits in that list:** authoring cost is near zero by construction (buildings are
recipes; rooms are a seed and a manifest). Design control is an open question we have not had to
answer yet. Determinism is chosen and half-built.

---

## 4. The ideal system for city-scale buildings with destructible interiors

Stated as the design we should be measuring ourselves against, independent of what exists today.

### 4.1 Four rungs, for rooms as well as buildings

The project's ladder ([Plan §4.2](Plan.md)) is **truth → materialisation → presentation**. At city
scale with interiors it wants a fourth rung, between "nothing" and "real":

| Rung | A room is… | Costs | Becomes real when |
|---|---|---|---|
| **0. Record** | a seed, plus a diff of what has been destroyed | bytes | — |
| **1. Resolved** | a list of items with positions, derived from the seed, held in memory | a few dictionaries | — |
| **2. Drawn** | instanced boxes at those positions, one collider per *item* | a MultiMesh instance and ~1 box per item | — |
| **3. Real** | blocks in the host's grid, per-brick collision, damageable, collapsible | ~30 blocks/item, a box each | something damages it, or the player is close enough to touch it |

Rung 2 is the missing one, and it is the proposal's core. A drawn room is not simulable and does not
need to be: it is furniture nobody has touched.

### 4.2 Bake per item TYPE, and instance it

The question was whether to bake interiors for the LOD tier. Yes — but the unit of the bake is the
**item type**, not the room and not the building.

A city has a few dozen kinds of thing that stand in rooms and millions of placements of them. Bake
a chair once — its faces, and a merged collider — and every chair anywhere is an instance with a
transform and a colour. Memory is per type; a million chairs cost a million transforms, not a
million meshes. Damage never invalidates it, because a damaged chair has already been promoted to
real blocks and is not being drawn from the bake any more.

Baking per ROOM would be the opposite of all three: memory per instance, invalidated by every hit,
and rebuilt constantly.

Right now this does not pay, and it is worth being honest about why: the current items are boxes,
and a `MultiMesh` of scaled unit cubes is already one draw call with less memory than a baked mesh
would use. **It starts paying the moment items are authored in the workshop**, because an authored
chair is a brick assembly with a silhouette, and drawing it as a box is simply wrong.

Two levels are enough:

| | what it is | when |
|---|---|---|
| **LOD0** | the item type's baked faces, instanced | near |
| **LOD1** | the item's merged boxes, instanced — what we draw today | far, or crowded |

The machinery exists: an item type is a tiny chunk, and `bake_chunk_faces` already turns a chunk
into faces. Baking one at load and keeping it is a handful of kilobytes per type.

### 4.3 The promotion rule is "touched", not "near"

Distance decides **drawn**. Interaction decides **real**. A blast whose radius reaches a room, or a
player within arm's reach, promotes rung 2 → 3 for that room alone. Everything else in the building
stays drawn.

This is the pattern the engines use for props: register cheap proxies, swap in the destructible in
place of the proxy on interaction, hide the proxy.

### 4.4 Demotion is the same ladder backwards, and it keeps the diff

Walk away and a room goes 3 → 2 → 1, dropping blocks then instances, keeping only what changed.
This is already how `deactivate_room` works: free the objects, keep the diff.

### 4.5 A room destroyed at rung 0 or 1 resolves, it does not simulate

If a shell nobody ever entered comes down, its rooms' contents are computed — thrown, broken, and
placed — from the seed, deterministically, rather than simulated. This is the proposal's
"randomise the contents" and it is **already built**: `spill_room` and the analytic resolve
([Interiors §5.2](Interiors.md)) do exactly this, down to killing about a third of each item's
bricks from the room's own seed so the same wreck looks the same on a second visit and on another
machine.

### 4.6 One room index, two ways of filling it — and a flood fill that gives four things at once

Generated buildings put rooms on a lattice, so "which rooms are near this point" is arithmetic.
Authored buildings do not, and everything is going to be authored. So the arithmetic is not the
design — it is one **implementation** of an index that also has to serve arbitrary rooms.

The index a building needs is small: per room, a local box and a storey number, plus a coarse
bucket per storey. Queries go through one API; a generated tower fills it from the lattice and pays
nothing, an authored building fills it from its own rooms.

**Where an authored building's rooms come from is the interesting half, and one pass gives all of
it.** Flood-fill the *empty* cells inside the building's bounds:

* each **connected region of air between two slabs is a room** — its box is the region's bounds;
* the **slabs fall out on the way**, as the y-layers where solidity crosses a threshold, which is
  what defines a storey;
* two regions on one storey that touch through a gap are **connected** — that is the neighbour
  graph, and it is what replaces "rooms within R metres" with "the room you are in, and the rooms
  it opens onto";
* a region that reaches the outside air does so **through a window or a door** — that is the portal
  list, computed once instead of raycast every tick.

Rooms, storeys, portals and connectivity from one walk over the empty space, cached in the recipe.
It is what portal-cell systems do offline, and it works for generated buildings too — which means
the lattice is a fast path that can eventually be deleted rather than a second system to maintain.

Manual override sits on top: a workshop tool to drag a room box, name it and set its kind, for the
cases where the fill is wrong or the author wants two rooms where the geometry says one.

### 4.7 Never ask a question proportional to the building

Every per-tick decision is over the *neighbourhood*: the cell the player is in and its neighbours.
Not a radius over everything that exists. This is the single lesson that cost the most to relearn —
a streaming pass was 183 ms because it measured every room in a 4,000-room building fifteen times a
second.

### 4.8 Bound the debris — two classes, and the cap drives the ladder we already have

A hard cap, and not one number. A collapse makes two kinds of thing and they are worth different
amounts:

* a **large piece** is a landmark. It changes how the place is navigated and it is what the player
  remembers doing. It should outlast everything.
* a **small piece** is texture. Hundreds of them are what fill the solver, and nobody misses one.

So two caps, connected by one eviction order. Every piece carries the two facts that decide its
fate — **how big it is** and **when it settled** — and eviction is oldest-first within a class:

| | over its cap | what happens |
|---|---|---|
| small, oldest first | → | **deleted**, outright |
| large, oldest first | → | **slept** — a dormant record at 17 bytes a block, able to come back |

That second row is the point of connecting the cap to what already exists: a large piece never has
to be *destroyed* to stop costing anything, because dormancy already reduces it to a record. The cap
is not a new mechanism, it is the thing that finally *drives* the mechanism on a schedule rather
than on distance.

Connected, because a total budget sits over both: when the total is exceeded the small class is
spent first, down to a floor, and only then does the large class begin to sleep. And it should be a
user setting, as Teardown ships it — the honest admission that the cap exists.

### 4.9 Only the terrain is protected

Decided, rather than left open: **the terrain is the only thing that does not come down.** No
protected cores, no indestructible frames, no borders. That is a harder promise than Geo-Mod 2.0
made — it explicitly excluded level borders and ground — and it is the one this project is for.

The cost of that promise is that every mitigation has to be real. Nothing is saved by a building
that cannot fall.

---

## 5. Where we stand against it

| | Ideal | Ours today | Gap |
|---|---|---|---|
| Truth layer for rooms | seed + diff | ✅ seed + `gone` diff, 17 bytes/block for dormant chunks | — |
| Resolved layer | items from a seed | ✅ `items_for`, `item_count_for` without building the list | — |
| **Drawn layer** | instanced, one collider per item | ❌ **missing** — a room is nothing, or real blocks | **the whole gap** |
| Real layer | blocks, per-brick damage | ✅ blocks in the host's grid, decorative role | — |
| Promotion trigger | touched | ⚠️ distance only (`ROOM_RANGE`) | promote on damage/reach instead |
| Demotion | keeps the diff | ✅ `deactivate_room` | — |
| Destroyed-unseen | resolve from seed | ✅ `spill_room`, analytic resolve | — |
| Neighbourhood queries | cells + portals | ⚠️ lattice lookup + storey span; portals are raycasts | one index, then a graph from the flood fill |
| Rooms in authored buildings | detected or authored | ❌ **nothing** — the lattice assumes a generated grid | flood fill, plus a manual tool |
| Item drawing | baked per type, instanced | ⚠️ unit boxes, instanced | fine until items are authored; then bake per type |
| Instanced drawing | one draw per chunk | ✅ `FurnitureMesh` MultiMesh | — |
| Collision merging | merge at rest | ✅ buildings and settled islands | falling pieces still per-brick |
| Debris cap | two classes, ages, oldest first | ⚠️ budgets and dormancy, no cap and no ages | small deleted, large slept, total over both |
| Determinism | integer, reproducible | ✅ integer stress, seeded contents, command replay | keep floats out |
| Authoring cost | procedural | ✅ recipes and seeds | — |
| Design control | authored limits | ✅ decided: terrain only | nothing to build; the promise raises the bar on everything else |

### 5.1 What the gap actually costs today

A room at rung 3 costs ~0.9 ms and roughly 30 blocks per item, with a collision box each. At rung 2
it would cost a MultiMesh instance per item part and one box per item — call it 5-10× less, with no
blocks in the chunk at all, no grounding, no stress participation and no chunk growth.

The measured consequence of *not* having rung 2: a building with every room open holds **+25,537
collision boxes** and its rooms took 189 ms to lay. At rung 2 the same building would hold a few
thousand instances and a few hundred boxes.

### 5.2 The two things to build, in order

1. **Rung 2.** Drive `FurnitureMesh` from the manifest rather than from placed blocks, with one
   collider per item. Promotion to rung 3 on damage-in-range or player-in-reach. This is the
   proposal, it is the largest single win available, and nothing in the current design fights it —
   the manifest already knows item type, cell and yaw, and the MultiMesh already draws boxes.
   **Done, 2026-09-23** — [Status: Drawn, not built](Status.md#drawn-not-built-the-third-state-of-a-room).
2. **A neighbour graph.** Replace "rooms within R metres" with "the room you are in, and the rooms
   it connects to". Storey-span was 90% of the win for 10% of the work; the graph is the rest of it,
   and it also replaces the raycast portal test with a walk.

Everything else in the table is a tightening, not a hole.

---

## 6. The plan

Six stages. Each is shippable on its own, each has something to measure, and the order is chosen so
that nothing has to be written twice.

### Stage 1 — The debris cap

**Why first:** it is independent of everything else and it fixes a bug that is happening now —
Jolt's manifold cache overflowing at 20,480 contacts in the big city.

* every island records `settled_at` and its block count;
* two classes split on a block-count threshold, each with its own cap, and a total over both;
* eviction is oldest-first within a class: **small pieces are deleted, large pieces are slept** into
  the dormant record that already exists;
* both caps are settings, exposed on the scene alongside `respawn_buildings`.

**Measure:** live body count and contact count during a big-city collapse, against the manifold
cap; that the total holds under a sustained fight; that a large piece slept and came back.

### Stage 1 results, and what they redirected

Measured on `--stress --big --buildings=4`, which is the case that hurts:

| caps (small / large / total) | mean | over budget | islands left |
|---|---|---|---|
| uncapped | 38.0 ms | 24.5% | 510 |
| 220 / 60 / 240 | **45.6 ms** | 37.0% | 300 |
| 80 / 24 / 96 | **33.8 ms** | 16.5% | 210 |

**A loose cap is worse than no cap.** Firing occasionally pays for the record a
sleep captures without removing enough bodies to earn it back. Tight beats loose,
loose loses to none, and 80/24/96 is what ships.

**And the cap is not the problem.** The damage phase is 74-77 ms in all three
runs and the worst frame is ~164 ms in all three. Debris does not own either.
The profile of the worst tick says who does:

    remesh 106.3   damage 52.4   islands 3.8   everything else ~0
    collapsing phase: 132.8 ms mean, 7.5 fps, 180 of 180 frames over budget
    45,248 collision boxes in pieces still falling

**One full mesh rebuild of a big building is ~100 ms**, and a collapse forces
them: blocks leaving the chunk invalidate the face bake, and the rebuild is
linear in the whole tower however few bricks left it. Eight of them in that run.

That is [Plan §4.3](Plan.md) — **sections, not buildings** — which has been on
the backlog since before any of this and now has a number against it. A building
drawn as N section meshes rebuilds one section, not the tower. It is worth more
than everything below, and nothing below touches it.

So the order changed: **sections first**, then the drawn rung.

### Floors were 75% of a building. Six attempts, and what the sixth got right

Measured, on the shape the big city is built from:

| | blocks | share |
|---|---|---|
| `plate_4x4` | 30,855 | **61.1%** |
| `plate_2x2` | 7,140 | **14.1%** |
| `brick_2x4_x` | 6,900 | 13.7% |
| `brick_2x4_z` | 5,400 | 10.7% |
| everything else | 240 | 0.5% |

**Three quarters of every building is its floors.** Two plate layers per storey,
offset so they interlock — because stud connections are vertical and plates side
by side in one layer are not joined to each other at all, so a single layer is
held only at its edges and drops out on the first solve. That was true, the fix
was the wrong one, and it has cost 75% of the brick budget ever since.

The replacement is not in doubt: **one layer of large panels standing on
columns**, which is how a building holds a floor up. `plate_10x10`,
`column_1x1` and `column_2x2` are in the palette and probe-verified. Built
naively it gives **50,535 blocks → 17,508**, with five of seven shapes solving
with zero stress failures and nothing detached.

It has not landed, across two attempts, and the reason is always the same: the
leftover strip. What was tried, in order, with what it cost:

| attempt | result |
|---|---|
| greedy fill, column per panel corner | 5 of 7 shapes clean; **9 blocks orphan round every stairwell** |
| keep-outs so columns dodge the stairwell | stairwell fixed; still clean on conforming shapes |
| interior walls standing on panels | **880 stress failures, 1,724 shed** — four courses of wall through one column |
| wall lines cut out of the floor | shattered the panel layout; tower grew to **53,422** |
| one planned lattice: columns, walls and panels all on it | 20x20 clean but for the stairs; non-conforming footprints shed hundreds |

**What the fifth attempt got right**, and is worth keeping when this is picked
up again: plan the lattice before placing anything. Lines inset by the wall
thickness, stepping by `PANEL`; columns on every lattice point; interior walls
along lattice lines; floor panels as lattice cells. Then every panel has a
column at its corner and every stretch of wall has one under it every `PANEL`
studs, by construction, with nothing cut around anything. Keep-outs from
`Fixture.footprint()` snap outward to whole cells, so a stairwell removes whole
cells rather than cutting one in half and taking its column.

**What it got wrong is the remainder.** A footprint of 80 studs with a 2-stud
wall band leaves 76 inside, which is seven panels and a six-stud strip. That
strip fills with 2x2s that reach neither a column nor the wall, and every
attempt to support it — a column at its far end, a column under every panel,
requiring columns for wall-straddling panels — made some other shape worse.

**The fix was to stop stretching the lattice to fit the footprint and choose
footprints that fit the lattice**: `2 * WALL_THICK + k * PANEL`. 24, 34, 44, 84
rather than 20, 30, 40, 80. Then there is no remainder, no fill, no strip, and
the whole class of failure goes away. It is a change to the shape tables, not to
the algorithm, and making it *first* — before touching the algorithm again — is
what made the sixth attempt land.

#### What landed

Conforming shape tables, then, in order, each checked on its own:

1. **Footprints that divide.** `2 * WALL_THICK + k * PANEL`, minimum 24 — a
   staircase is a whole lattice cell across and the interior of a 14-stud
   building is 10.
2. **One-plate floors, one `plate_10x10` per lattice cell**, with a column at
   each panel's corner.
3. **`StaircaseRecipe.DIAMETER = TowerRecipe.PANEL`**, so the stairwell IS a
   cell: it is left out of the floor and the flight fills it, with the panels
   around it to clip to. At 8 in a cell of 10 the steps touched nothing and
   every one of them read as detached.
4. **The base band ignores keep-outs.** A stairwell needs a hole in every floor
   *above* it and none in the ground.
5. **Interior walls on lattice lines**, `ROOM_PANELS` apart, with a doorway that
   moves storey to storey and a solid top course.

Result, against the same eleven shapes:

| | before | after |
|---|---|---|
| biggest tower | 50,535 blocks | **34,215** |
| stress failures | — | **0 on all eleven** |
| detached blocks | — | **0 on all eleven** |
| interior walls and rooms | none | included in the 34,215 |

So a third fewer bricks *and* the rooms that were not there before.

#### Three bugs it flushed out, all of the same shape

Each was a case of **one thing sizing itself without asking what else was
going in**, and each was invisible until the geometry changed:

* **The lintel laid a brick across its own window.** Openings step by the brick
  length, so a course laid from a brick boundary comes down exactly across one,
  bridging nothing. Everywhere but the top of a tower the course above the slab
  ties the stranded brick back in, so it only showed on shapes with
  `courses % COURSES_PER_FLOOR == 0` — which is why five shapes were clean and
  six shed 12 to 42 blocks apiece. Half a brick of lead on the lintel fixes it,
  and the same lead is what bonds an interior wall.
* **`frame_dims` sized frame 0 from its bricks and ignored its fixtures**, while
  `chunk_dims` counted them. A 12-stud house with a 10-stud stairwell kept three
  of its twelve steps and dropped the rest into a chunk two studs too narrow —
  silently. At a diameter of 8 it had fitted by exactly nothing.
* **`snap_keepouts` could not reach the last cell.** On a footprint that does
  not divide, that cell is wider than `PANEL` and the lattice line before it is
  a panel short of the wall, so the keep-out stopped short — and the fixture's
  own carve then took out the columns under the floor the keep-out had spared.

#### Four things learned and worth not relearning

* **Hold up what the floor LAID, not what the grid says.** Columns follow the
  panels. On a conforming footprint that is the same set — a cell is one
  `plate_10x10` on one column — but the moment a footprint does not divide, the
  leftover strip fills with parts the lattice knows nothing about, and plates
  side by side in one layer are not joined to each other at all.
* **Interior walls must not stand on floor panels.** A wall is four courses
  running the width of the building; resting it on a panel puts all of that
  through whichever column is under that panel. Walls want a column line of
  their own, which a lattice gives them for free.
* **Rooms cost real bricks.** An interior wall is a run across the whole floor
  on every storey, so room size is a budget decision before it is a spatial one.
  At three panels a room (~10 m) the interior walls of the big tower are about
  9,000 blocks; at one panel they would cost more than the floors do.
* **A column stands IN a room**, from its floor to the next one. It is not
  scenery to be drawn round: furniture placed on one does not place at all, and
  three items in four landed on one the day the columns went in. `Room.posts`
  is why that is now a question the manifest can answer.

#### A probe that was measuring nothing

`fallen_probe` undercut thirteen courses of what had been a nineteen-course
tower and expected the rest to come loose. Once floors went from two plate
layers to one, the tower got shorter, thirteen courses stopped covering its
support face, and the top of that face held the whole thing up — so the check
passed nothing and failed. The undercut is worked out from the recipe now.
**A hard-coded extent in a probe is a check with a shelf life.**

#### The seventh: floors IN the walls (2026-09-23)

The sixth attempt stood up, and `tools/structure_probe.gd` asked it a question
nobody had: **which floor panels share a joint with an exterior wall?** None.
Not one in the city — 0 of 840 on the biggest tower. The lattice started at the
inside face of the wall, the ring under the wall was its own 2x2 plates, and
plates side by side are not joined, so every floor hung on its columns and
interior walls alone. Take the columns out and 1,020 of 1,646 panels fell.

The fix is the one a real modular building uses: **the floor runs to the outer
face**, so the edge panels go under the walls and every course above and below
clamps them. Three changes, each for a reason:

* **The lattice starts at 0; footprints are `k * PANEL`.** Every shape is four
  studs smaller outside with the same panels, and the separate wall ring is gone.
* **Columns stand centred on lattice points**, so a column's top carries the
  corners of all four panels meeting there and ties them together. Under one
  panel's corner, a column joined nothing.
* **Interior walls straddle the seam** they stand on, so a wall ties its two
  panels along their whole length.

And one thing it forced: **a stairwell must be a cell clear of the walls**
(`TowerRecipe.stair_line`). An edge cell is under a wall now, and a staircase
there cut through it. So the smallest shape is 30, not 20.

| shape (old → new) | blocks before | after | panels fall, columns removed |
|---|---|---|---|
| 24x24x18 → 30x30x18 | 787 | 651 | 0 → 0 |
| 44x34x24 → 40x30x24 | 1,619 | 1,157 | 24 → 0 |
| 44x44x120 → 40x40x120 | 8,829 | 6,758 | 160 → 0 |
| 64x44x162 → 60x40x162 | 15,073 | 11,016 | 378 → 81 |
| 84x64x204 → 80x60x204 | 29,716 | **22,507** | 1,020 → **136** |

Every shape: 0 stress failures, 0 detached, **every edge panel joined to its
wall**. Some of the saving is the smaller footprint (shorter walls); the rest is
the wall ring and the columns the walls now replace. Laid on its side, a
30x30 tower that shed 591 blocks under the old lattice sheds none.

**1x4 walls were measured and are not the default.** `ROOM_WALL_THICK` (and
`WALL_THICK`) can be 1:

| walls | blocks, biggest | panels fall, columns removed | shapes standing |
|---|---|---|---|
| 2-stud (default) | 22,507 | 136 | 12 of 12 |
| 1-stud interior | 22,909 | 408 | 10 of 12 |
| 1-stud interior and exterior | 24,348 | 408 | 10 of 12 |

A run costs the same number of bricks whatever its thickness, so thin walls
save nothing — and a one-stud wall cannot straddle a seam, so it stops tying the
floor together. Use it for the look if it is wanted, and add columns under it.

**Non-conforming footprints still stand, and one thing about them is worth
knowing:** the leftover strip's plates reach neither a wall nor a lattice
column, so they get columns of their own — a stack tied to the building only
through the base. Upright that is fine; lying on its side it comes loose
(five blocks on a 16x12). Workshop builds may hit this; the city does not.

### Stage 2 — The drawn rung


**Why second:** it is the biggest single win left and nothing else depends on its internals.

* `FurnitureMesh` draws from the **manifest** — item type, cell, yaw — with no blocks laid;
* one collider per *item*, not per block, on the building's furniture body;
* rooms promote to real blocks when something **touches** them: a blast whose radius reaches the
  room, or the player within reach. Not on distance.
* demotion drops blocks back to drawn, and drawn back to nothing, keeping the diff.

**Measure:** a room at rung 2 against 0.9 ms and ~30 blocks an item at rung 3; a building with every
room drawn against +25,537 collision boxes and 189 ms; that a blast still destroys what it reaches.

### Stage 3 — One room index

**Why third:** small, and Stage 4 needs it.

* per building: room id, local box, storey number, and a bucket per storey;
* one query API — `rooms_in_range(building, point, radius, storey_span)` — with the lattice as the
  fast path that fills it for generated towers;
* `_stream_rooms` does not change, which is the point.

**Measure:** the streaming pass stays at its current 3.3 ms with the index in the way.

### Stage 4 — Rooms, storeys and portals from a flood fill

**Why fourth:** it is what makes authored buildings have interiors at all, and it retires three
other things on its way past.

* find the slabs: y-layers whose solidity crosses a threshold;
* flood-fill the air between slabs; each connected region is a room, its bounds are its box;
* regions that touch on one storey are **connected** — the neighbour graph;
* regions that reach outside air do so through **portals** — windows and doors, found once instead
  of raycast every tick;
* cache all of it in the recipe, so it is computed at authoring time and not at runtime.

Then: the streaming pass walks the graph instead of testing a radius, and `_can_see_into` stops
casting rays.

**Measure:** detected rooms against the generated lattice's rooms for a tower (they should agree);
the pass cost with a graph walk against the radius query; portal tests at zero raycasts.

### Stage 5 — Baked item types, instanced, with two LODs

**Why fifth:** it does not pay until items are authored, and Stage 2 defines where drawing happens.

* an item type is a tiny chunk; bake its faces once at load and keep them;
* LOD0 instances the baked faces, LOD1 instances merged boxes — what Stage 2 draws;
* one merged collider per type, reused by every instance.

**Measure:** memory per type against per instance; draw calls for a furnished storey; the distance
at which LOD1 is indistinguishable.

### Stage 6 — Workshop room tools

**Why last:** the flood fill covers most of it, and this is the override.

* drag a room box, name it, set its kind;
* mark a region as its own room, or merge two the fill split;
* the existing STRUCTURE / INTERIOR layer already covers "what is actually holding this up", so
  there is nothing new to invent for structure — only for rooms.

**Measure:** a building authored end to end in the workshop, placed in the city, shot, and its
interiors behaving like a generated one's.

### What is deliberately not in the plan

* **Occlusion.** `OccluderInstance3D` would let a building hide its own interior. It is a real win
  and it is orthogonal; it can land any time.
* **Falling pieces merging their collision.** Tried twice, reverted twice, and the reason is
  recorded in `IslandManager.spawn`. Stage 1 reduces the pressure that made it attractive.
* **Anything about networking.** The determinism is in place; nothing here should be allowed to put
  a float on the structural path.

---

## 7. Honest limits of this write-up

The two most directly relevant talks — Embark's *Engineering Mayhem: Technical Deep-Dive into
Environmental Destruction in THE FINALS* and Ubisoft's *The Art of Destruction in Rainbow Six:
Siege* — are paywalled on GDC Vault, and the Siege slide PDF is image-only. What is written above
about those two games comes from secondary reporting and should be treated as weaker than the
Frostbite and Teardown material, which comes from first-party sources.

No shipped game does what this project is trying to do — city-scale, fully destructible, with
interiors — so section 4 is reasoning from the constraints, not a description of anything that
exists.

---

## Sources

* [Geo-Mod 2.0 — Red Faction Wiki](https://www.redfactionwiki.com/wiki/Geo-Mod_2.0)
* [Geo-Mod — Red Faction Wiki](https://redfaction.fandom.com/wiki/Geo-Mod)
* [How Games Do Destruction — Game Maker's Toolkit](https://gmtk.substack.com/p/how-games-do-destruction)
* [Destructible environment — Grokipedia](https://grokipedia.com/page/Destructible_environment)
* [Teardown Developer Breaks Down Multiplayer and Voxel Destruction Tech — 80.lv](https://80.lv/articles/teardown-developer-breaks-down-multiplayer-and-voxel-destruction-tech)
* [Destruction Masking in Frostbite 2 using Volume Distance Fields — EA/Frostbite](https://www.ea.com/frostbite/news/destruction-masking-in-frostbite-2-using-volume-distance-fields)
* [How Battlefield 6's Frostbite Engine Pushes Physics to Its Limits — Niche Gamer](https://nichegamer.com/how-battlefield-6s-frostbite-engine-pushes-physics-to-its-limits/)
* [Engineering Mayhem: Technical Deep-Dive into Environmental Destruction in THE FINALS — GDC Vault (paywalled)](https://gdcvault.com/play/1034307/Engineering-Mayhem-Technical-Deep-Dive)
* [The Art of Destruction in Rainbow Six: Siege — GDC Vault (paywalled)](https://www.gdcvault.com/play/1023003/The-Art-of-Destruction-in)
* [World Partition Explained: Open Worlds for Small Teams](https://sarahhyperdense.substack.com/p/world-partition-explained-open-worlds)
* [World Partition & Streaming Performance — PerfGuard](https://getperfguard.com/tutorials/world-partition)
* [Instance Damage System — proxy-instance swapping for open-world props](https://gfx-hub.co/unreal-engine-asset/ue-code-plugins/146173-instance-damage-system.html)
