# Brick destruction and furnished rooms -- a plan from first principles

Written 2026-11-07. **Part A** was written before reading any of the project's
code or docs: it is how I would build a LEGO-style game whose buildings collapse
like real brick builds and whose rooms are full of furniture and small items,
aiming for the best performance. **Part B** compares Part A with what the project
already has, and says what to keep, what to change, and what to try.

---

# Part A -- the plan

## A1. What we want, as behaviours we can test

1. A building is made of real bricks joined by studs. Nothing falls unless the
   connections holding it fail, or nothing connects it to the ground.
2. When a building loses support, what is above falls as **one or a few large
   pieces**, not hundreds of loose bricks.
3. A falling piece hits the ground and splits **along its weakest joints** into a
   few more parts (a wall panel, a floor slab, a corner). Only small bits scatter
   as loose bricks.
4. Rooms hold many furniture pieces and small items. They ride along with the
   piece they stand on, and spill out when it tips, breaks or opens up.
5. All of this in a city of many buildings at a steady frame rate on a handheld
   class machine (Ryzen Z1 / RDNA3 iGPU).

Working budgets (assumptions to measure against, not promises):

| Thing | Budget |
|---|---|
| Bricks in a loaded city | 1-5 million (200 buildings x 5k-30k) |
| Main-thread cost of one destruction event | under 2 ms, spread over frames |
| Moving rigid pieces at once | 64 (hard cap 128) |
| Loose flying bricks (debris) | 20 000 |
| Furniture and items in a loaded city | 50 000-100 000 |
| Simulated (rigid) furniture at once | 32 |

## A2. The key idea: the unit of breaking is the joint

Real LEGO bricks almost never break. What fails is the **clutch** between studs
and tubes. So the simulation is a **graph of joints**, and everything a player
sees or touches -- meshes, colliders, pieces -- is derived from that graph and
cached. Bricks are the nodes; stud connections are the edges; an edge's strength
is how many studs it couples. Breaking means removing edges, then asking which
bricks are still connected to the ground.

This one choice gives realism (pieces break where a real build would) and
performance (a graph of a few million small integers is cheap to walk; meshes
and physics only change when a piece actually moves).

## A3. Data model

All hot data lives in flat arrays in native code (C++), indexed by integers.
Scripts only orchestrate.

- **Brick record**, 16 bytes: position in the building's local grid
  (studs x plates, 3 x int16), part id (u16), rotation (u8), colour (u8),
  flags (u16), owning piece id (u32).
- **Occupancy**: a sparse chunked grid (16 x 16 x 16 cells, one cell = 1 stud x 1
  plate) mapping a cell to the brick in it. Used for hit lookups (ray hit ->
  brick), meshing and neighbour search; never for the structural logic itself.
- **Joint graph** in compressed rows (CSR): for each brick, its joints. A joint
  is (other brick, studs coupled u8, kind). Kinds: stud-tube (vertical clutch:
  strong in compression, weak in tension), side contact (compression and
  friction only, no tension), hinge/pin (special parts). About 4-8 joints per
  brick: 1 M bricks ~ 16 MB records + ~40 MB joints.
- **Piece**: a connected set of bricks that moves as one. The standing building
  is the anchored piece. A piece holds its brick list, mass, centre of mass,
  inertia, cached mesh and collider, and a link into the strength hierarchy
  (A5).
- **Baked at build/import time and saved with the build** (so loading does no
  graph work): the joint graph, the strength hierarchy, the region meshes, and
  the colliders and meshes of the largest likely pieces (A6).

## A4. When does a building stand?

### A4.1 Connectivity -- exact, and paid for by what falls

Anchors are bricks touching the ground or baseplate. A set of bricks with no
joint path to an anchor falls.

When joints break, run **two searches at once**, one from each side of the cut,
advancing them alternately one brick at a time:

- if the two searches meet, nothing fell -- stop;
- if one search runs out of bricks first, that side is a separate piece -- and
  it is found in time proportional to **its** size, not the building's;
- if a search touches an anchor, that side stands.

This "smallest side first" rule is the whole performance trick: knocking a
window out of a 30 000-brick tower costs a few hundred steps, not 30 000. Only
huge cuts (a whole storey shot out) need a worker thread.

### A4.2 Load -- cheap, approximate, local

No finite elements. A top-down pass over the bricks above the damage:

- each brick carries its own weight plus what rests on it, shared among the
  joints below it in proportion to their studs;
- a joint fails in **tension** (pulled apart) when the load hanging from it
  exceeds studs x clutch;
- it fails in **bending** (cantilevers, overhangs) when load x horizontal lever
  arm exceeds a capacity that grows with the joint's stud count and width;
- compression almost never fails.

Run it only on the region above the dirty joints, on a worker, and apply the
result next tick. Over-stressed joints may "creak" for a few frames before they
let go -- that gives a readable warning and spreads cost -- but keep it short
(well under half a second) so collapse feels fast.

## A5. Breaking into a few parts -- the strength hierarchy

This is the core of "collapse, then break into a few parts".

### A5.1 Bake

Cluster the bricks by joint strength, bottom up:

1. start with every brick as its own cluster;
2. repeatedly merge the two **connected** clusters whose shared joints are
   strongest in total (normalised by size, with a nudge towards compact,
   not stringy, shapes);
3. record each merge as a node in a binary tree. A node's **threshold** is the
   total strength of the joints between its two children.

Because merges only happen across joints, every node of the tree is a connected
set of bricks. And the tree reflects how the thing is *built*, not authored
markers: a staggered-bond wall is a deep, strong subtree; the seam where a floor
plate sits on a wall (few studs) is a weak node high up. Natural break lines fall
out of the build itself.

### A5.2 Runtime split

A piece hits something with energy E at point p. Walk the piece's subtree from
its root:

- at each node, the energy reaching the cut is E x falloff(distance from p to the
  cut);
- if it beats the node's threshold, split there, subtract the threshold from E,
  and recurse into both children with what remains;
- if not, that child stays whole.

Cost is (pieces produced x tree depth) -- microseconds. Because each split spends
energy, a hard hit makes several pieces and a soft one makes one or two:
"a few parts" emerges without special cases.

### A5.3 Damage keeps the tree valid

When a brick is shot away or a joint breaks, walk from its leaf to the root and
subtract the lost strength from every ancestor's threshold (O(depth)). A cluster
that lost bricks may no longer be connected; a cheap connectivity check on the
produced piece (its own size) splits it further if needed. When a building has
taken a lot of damage, rebuild its tree in the background.

### A5.4 Small pieces are not rigid bodies

A piece under N bricks (about 8) becomes **debris** (A7), never a rigid body.

## A6. Moving pieces

- **One rigid body per piece.** Collider: a few greedy-merged boxes from the
  piece's occupancy (cap 8-16; beyond that, coarser boxes or one convex hull).
  Built on a worker when the piece is born.
- **Pre-bake the first collapse.** The top few levels of each building's tree
  are the pieces a collapse most likely produces. Bake their colliders and mass
  properties with the build, so the first hit spawns instantly -- no first-hit
  hitch.
- **Rendering moving bricks by instancing, not re-meshing.** Each moving brick
  is an instance carrying (part, colour, local transform, piece index). The
  vertex shader fetches its piece's matrix from one buffer. Splitting a piece
  just changes some bricks' piece index -- no meshing, no new draw calls; all
  moving bricks of a part type are one draw.
- **Hand-off without a hitch.** When a piece leaves the building, draw its
  bricks as instances at once, while the static region mesh still shows them for
  a frame or two (they coincide exactly, so no one sees the double). The
  region's new mesh is built on a worker and swapped in when ready.
- **Impacts.** Contact impulse above a threshold -> A5.2 split. At most a few
  splits per frame; extra ones queue.
- **Settling.** A piece asleep for about a second becomes **rubble**: its body
  freezes (or its boxes join a static rubble body for the area). It stays
  splittable if hit again.
- **Budget.** Over the moving-piece cap, the smallest or farthest pieces turn
  into debris or freeze where they are.

## A7. Debris -- small loose bricks

- A particle per brick: position, velocity, orientation, spin. Collides with
  the terrain and a coarse version of the static world (building boxes); no
  brick-on-brick collision. Bounce, friction, settle, sleep.
- Simulated in native code with SIMD on the CPU (cheap at 20 000, readable by
  gameplay, deterministic) or on the GPU if gameplay never needs the positions.
  Rendered by instancing, one draw per part type.
- Settled debris becomes static rubble instances (no collider, or one shared
  coarse one), and fades out past a cap, oldest and farthest first.

## A8. Rooms, furniture and small items

### A8.1 Representation

- A **room** is a volume of a building (a set of cells) plus a list of items:
  {asset, local transform, host brick}.
- An **asset** is authored once (a small brick build, or a prop) and instanced
  everywhere.
- Items are **not** nodes of the building's joint graph -- 100 000 extra nodes
  for no structural gain. Each item hangs off a **host brick** (the floor plate
  it stands on; the wall a shelf is fixed to). The building keeps a list
  host brick -> items.

### A8.2 Tiers

| State | Cost |
|---|---|
| Room intact, out of view | nothing (not drawn, not simulated) |
| Room intact, in view | instanced draw per asset type, culled per room |
| Host is in a moving piece | rides along: its instance uses the piece's matrix (free) |
| Spilled, large (table, sofa) | rigid body from a small pool (32) |
| Spilled, small (cup, book) | debris particle |
| Settled | static rubble instance |

### A8.3 Spill rule

An item riding a moving piece detaches when the piece tilts past about 30
degrees, decelerates hard (an impact), or the item's host brick is torn off. A
detached large item can break too: furniture is a small brick build, so it has
its own small joint graph and strength tree, **baked once per asset type** and
shared by every copy.

### A8.4 Seeing interiors cheaply

Interiors are invisible from far away except through windows. Far: windows use
an interior-mapping shader (a fake room behind the glass), no items drawn. Mid:
one merged mesh per room. Near or breached: per-item instances. A room is drawn
only when the camera can see into it (through an opening, or because a wall is
gone) -- a cheap portal test per room.

### A8.5 Gameplay reads data, not the renderer

Loot, cover and AI read the item lists, never the GPU.

## A9. The static building on screen

- **Region meshes** (about 16 x 16 x 12 plates) built on workers from occupancy,
  hidden internal faces removed, studs only where a top is exposed (normal-
  mapped studs at a distance).
- Breaking joints changes nothing on screen; only bricks that leave do (A6
  hand-off).
- Far buildings: a baked proxy mesh or impostor. Destruction far away: pieces
  only, no debris, no items.

## A10. Threads and the frame

- **Main thread:** input, apply finished results, spawn bodies, physics step.
- **Workers:** large connectivity searches, load solve, re-meshing, collider
  building, tree repair.
- **Never wait on a worker.** Check whether a job is done next tick. Data goes
  in as snapshots; results come back as small change lists.
- **Per-frame caps:** splits, spawned bodies, remesh jobs. A big collapse spawns
  its largest pieces first and the rest over the next frames.

## A11. Weapons

A hit is a ray against the region colliders -> occupancy -> brick. A bullet
knocks off a surface brick or two (debris). An explosion breaks joints within a
radius with probability by distance and energy. Either way, the result is a
list of broken joints fed into A4.

## A12. Co-op

Send **causes**, not results: (tick, hit point, energy, seed). Graph, tree and
split logic are integer-only and deterministic, so every machine makes the same
pieces. Rigid body motion is not deterministic: the host sends large pieces'
transforms at a low rate. Debris and spilled small items are cosmetic and local.

## A13. Tiers at a glance

| Tier | What it is | Cost |
|---|---|---|
| Static | brick and joint data only | memory only |
| Stressed | the region a solve is checking | worker, a few ms, rare |
| Piece | a rigid body + instanced bricks | physics body, no meshing |
| Debris | a particle | a few ns per step |
| Rubble | a frozen piece or instance | draw only |

## A14. Build order

Each step lands with a probe that proves it.

1. Brick records, joint graph, two-sided connectivity search. *Probe:* remove a
   brick; count what falls; time it against building size.
2. Pieces as rigid bodies with greedy box colliders; instanced moving bricks.
3. Strength tree bake and impact split. *Probe:* drop a tower; count pieces;
   check the splits sit on the weakest seams.
4. Debris particles; settle to rubble; caps.
5. Load and cantilever solve.
6. Rooms and items on host bricks; ride-along; spill; per-asset trees.
7. Budgets, far LOD, interior culling.
8. Co-op replication.

## A15. Risks and open questions

- Merging by "strongest total joints" can make long, thin clusters; the
  compactness nudge needs tuning per kind of build.
- Pure stud-count strength ignores friction of side-by-side bricks; walls of
  unstaggered columns will look weaker than players expect (true to LEGO, but
  check it feels right).
- Instance buffers for very many moving bricks need a cap and a fallback
  (merge a settled piece back into a mesh).
- The tree is baked per building; procedurally generated buildings need a bake
  fast enough for load time (it is O(joints log joints), so should be fine, but
  measure).

---

# Part B -- comparison with the current project

*(written after Part A, from reading the code and docs)*

Read for this: [BrickFailure.md](BrickFailure.md), [Collapse.md](Collapse.md),
[CollapseNext.md](CollapseNext.md) §1.10, [DestructionLod.md](DestructionLod.md) §2,
[Interiors.md](Interiors.md) §8, [HandoffStructBugs.md](HandoffStructBugs.md) (merged plan),
`brick_types.h` (`Block`), `brick_world.h`, `brick_world.cpp` (`solve_grounded`,
`detached_groups_of`, `solve_stress`), and the heads of `island_manager.gd` and
`brick_island.gd`. Not read line by line: the 6 600 lines of `island_manager.gd`, so the
details below about it come from its comments and the docs.

## B1. The short answer

The project already **is** Part A's design in its bones, and in several places it is
further along than Part A:

- the joint is the unit of failure, bricks separate and never vanish, compression is free and
  tension governs ([BrickFailure.md](BrickFailure.md) -- the same conclusion as A2/A4.2, with
  sources and the square-cube correction Part A missed);
- a falling piece is a connected group of bricks with its own body and merged-box collision;
- furniture hangs off the bricks it stands on and rides the piece (Interiors §8.3, the same as
  A8.1);
- co-op replicates commands, not results (the damage log, the same as A12);
- **truth is never LOD'd**, and far buildings are a recipe plus a damage record, not bricks
  in memory -- better than Part A, which assumed every building's bricks stay loaded.

Where it differs, the biggest gap is **how a piece chooses where to break** (A5): the project
finds one seam per landing by scanning course boundaries; Part A bakes a strength tree that
finds any number of cuts, in any direction, in microseconds. Next come **how moving pieces are
drawn** (meshes per piece vs instancing), **how loose single bricks are simulated** (bodies vs
particles) and **whether furniture spills from a tipping piece**.

## B2. Side by side

| Topic | Part A | The project now | Verdict |
|---|---|---|---|
| Unit of failure | joint, strength = studs | joint; `JointCache`, `seam_studs`, `BrickStrength` tension per stud (a setting, default 4x scaled) | **same** |
| Failure modes | tension, bending; compression free | tension via the support DAG (`solve_stress`), compression free; spans by a reach rule (`cut_spans`, Floor Reach), shear ring at a blast (`throw_killed`) | **same idea**; the span rule stands in for A4.2's bending moment |
| Brick record | 16 B, flat arrays | `Block` 24 B or more (`Vector3i` cell, `int32` archetype, flags as separate bools) in per-chunk vectors | close; size only matters at millions loaded, and the project never loads millions (B2 row "far") |
| Connectivity after a cut | two searches from each side of the cut, cost = the smaller side | `solve_grounded`: one flood from the anchors over the whole chunk, then `detached_groups_of` over the rest; on a worker; storey units keep the chunk small | **different** -- see B3.2 |
| Choosing break lines | baked strength tree (A5), any orientation, energy-spent splits | `_weak_seam` at a landing: scan each course boundary within half a storey of the contact, cut the one with fewest studs (with a preference for storey lines); pieces "long the other way" tear as a band (34 of 89 snaps in `barrage_probe`); ~0.2 ms per 859 bricks per landing | **biggest gap** -- see B3.1 |
| First collapse | pre-bake top tree levels' colliders | storey units: the unhit part is a *rest shell* and a storey that gives way sends a whole shell piece off; bakes cancelled and restarted rather than waited on | **same spirit**; storey units are a hand-chosen top level of A5's tree |
| Moving piece mesh | instanced bricks + per-piece matrix, no meshing at a split | each piece is its own chunk, meshed (synchronously up to 200 blocks / 2 000 tris, else on a worker; far ones coarse) | **different** -- see B3.3 |
| Moving piece collision | greedy boxes, cap | merged boxes on the body RID, rebuilt after a change | **same** |
| Moving cap | 64 | `MAX_MOVING` 48, debris cap evicts oldest | same |
| Single loose bricks | particles, no brick-brick collision | a piece of 8 bricks or fewer is never a body: crumbs, drawn from the shared brick MultiMesh, falling in a shader (`scripts/islands/island_crumbs.gd`, `crumb.gdshader`), bouncing, then laid where they stop (`BrickHeap`); groups up to a landmark's size crumble the same way when shed off a piece | **same** (corrected 2026-11-07; the first reading went by an outdated comment at the head of `island_manager.gd`) |
| Settling | asleep 1 s -> rubble, still splittable | settled -> frozen + merged collision -> asleep record beyond 150 m, woken at 120 m; frozen only on something still | **same, more thorough** |
| Furniture representation | items on host bricks, not in the joint graph | manifest per room; block id -> pieces index; laid as *decorative* bricks only when shot (weightless in the solve, but in the chunk) | **same** |
| Furniture on a moving piece | rides; **spills** past a tilt or a hard stop | rides it down; spill/write-off removed in Interiors §8.6 | **different** -- see B3.5 |
| Furniture breaking | per-asset strength tree baked once | shot piece becomes decorative bricks, then ordinary destruction | fine as is |
| Interior visibility | per-room portal test; interior mapping far | per storey group, by distance only (user decision 2026-10-06); painted windows past 60 m | keep the project's: it is decided, simpler, measured |
| Distance rings | far = pieces only | near / mid / far rings, one rule, by distance only (DestructionLod §2) | **same, more detailed** |
| Threads | never wait on a worker | Docs/WhereWorkRuns.md rule; city solve on a worker; bake readers joined before writes | same |
| Co-op | causes + host transforms for big pieces | damage log commands, landmarks identical on every machine, debris local | same |

## B3. The differences worth acting on

### B3.1 A strength tree instead of one seam per landing

Today a landing asks "which course boundary near the contact has the fewest studs" and cuts it.
That is right for a tower toppling across something (it parts through its windows), but:

- it only looks at **horizontal** seams across the piece's own Y. A piece lying the other way,
  a floor slab, a wall that landed on its face, an L-shaped corner has no such seam and **tears
  as a band** (34 of 89 snaps);
- it makes **one** cut per landing, so a hard landing and a soft one both make two parts;
- the storey-line preference (`SEAM_PREFERS_FLOOR`) is a rule written by hand for recipe
  towers; workshop builds and round buildings (the direction in the user's notes) will have
  weak lines in places that rule does not know about;
- it walks every block of the piece each landing.

Part A5's tree gives all of that for free: built once from the joint graph (corners that
interlock become strong subtrees, floor-on-wall seams weak nodes, vertical seams between wall
panels found as easily as horizontal ones), and a landing walks it with its energy, making one
to several pieces in microseconds. Storey units already are its top level, chosen by hand; the
tree would generalise them to any build.

**How to try it without risk:** a probe first (`tools/strength_tree_probe.gd`, C++ bake in
`BrickWorld` behind a new method). Bake the recipe tower and two workshop builds; print the
top ten cuts; compare with `seam_probe`'s counts (the tower's windows at 112 studs should be
the first cuts under the 208-stud storey line). Only then route `_snap_across` through it,
and keep `_weak_seam` as the fallback until `barrage_probe` shows fewer bands.

### B3.2 Connectivity paid for by what falls

`solve_grounded` floods the whole chunk from its anchors every solve. It is on a worker, and
storey units keep chunks small, so this may already be cheap enough -- **measure before
changing**: the `SolveStats.solve_ms` it records, on the mega tower, for one shot window.
If a single knocked-off brick still costs a whole-chunk flood plus a tick of worker latency,
A4.1's two-sided search answers the common case (a small cut) on the main thread in tens of
microseconds and leaves the full solve for big cuts. It must use the same `grounding_flows`
rule as the full solve, and a probe should check both agree on random cuts.

### B3.3 Drawing moving pieces by instancing (small and medium pieces)

A piece is a chunk that is meshed when it is born. That is where the hand-over bugs came from
(Collapse §2.4-2.5: doubling, flicker, "18 went blind") and why small pieces are meshed
synchronously on the main thread (up to 200 blocks / 2 000 triangles). Part A6 draws moving
bricks as instances with a piece index, so a split needs no mesh at all.

The honest trade-off: instancing draws every face of every brick (no hidden-face removal, no
merged chamfers), so a 5 000-brick piece would cost more to draw than its mesh. So: **instance
pieces up to a few hundred bricks** (exactly the band meshed synchronously today), keep meshing
big ones. Worth a measured A/B with the renderer clock (`viewport_get_measured_render_time_gpu`,
not frame time), editor closed.

### B3.4 Single loose bricks as particles, not bodies -- already built

**Corrected 2026-11-07:** this is what the project does. A piece of `DEBRIS_MAX_BLOCKS` (8)
or fewer never becomes a body: its bricks are crumbs (`IslandManager.crumbler`,
`scripts/islands/island_crumbs.gd`), instanced, falling in `shaders/crumb.gdshader`,
bouncing (`CRUMB_BOUNCE`), and laid as a heap where they stop; the main thread pays per
event, not per frame. The paragraph below was written from the comment at the top of
`island_manager.gd`, which predates crumbs. Nothing to build.


A visible loose brick is a real `RigidBody3D` today (drawn from a MultiMesh, but simulated by
the physics engine). Part A7 simulates them as particles in native code: no broadphase, no
brick-on-brick contact, thousands for the cost of dozens of bodies, and positions still readable
on the CPU (so no renderer read-back, per WhereWorkRuns). The `BrickHeap` already takes over
once they land; particles would just be how they get there. Lower priority than B3.1-B3.3:
the debris cap keeps today's cost bounded; this would let the cap rise.

### B3.5 Furniture spilling from a tipping piece -- a question for the user

Interiors §8.6 removed spilling on purpose (one rule: a thing is where its floor is). Part A8.3
adds back one physical rule: an item detaches when its piece tilts past ~30 degrees or stops
hard, and then becomes a pooled body (large) or a particle (small). That is what a real brick
model does when you tip it -- the chairs slide out -- and it is cheap (a check per riding item
on a landing). It is a game-feel choice, not a performance one, so it is the user's call.

## B4. What the project does better than Part A -- keep it

- **Recipe + damage record for everything far** (the shell ladder): memory and load time Part A
  would have spent on millions of resident bricks.
- **Storey units**: a hit materialises only the storeys it reaches. Part A had no idea like it.
- **The square-cube correction** of stud strength (BrickFailure §4.5) and the tunable setting.
- **Landmark vs debris** distinction: big pieces are identical on every machine and the AI uses
  them as cover; debris is per-machine presentation. Part A12 only hinted at this.
- **Interiors by storey group with fades** -- simpler than per-room portals and already measured.
- **Decorative blocks**: furniture laid into the host chunk is weightless in the solve but still
  connected, so it rides and falls with its floor without being a load case.

## B5. Suggested order

1. **B3.1 strength tree** -- probe and bake first, then route snaps through it. Largest gain in
   "breaks into a few parts along real weak lines", especially for workshop and round builds.
2. **B3.2 measure** `solve_grounded` on small cuts; build the two-sided search only if it shows.
3. **B3.3 instanced small pieces** -- A/B on the renderer clock.
4. **B3.5** ask the user about spilling.
5. ~~**B3.4 particles for loose bricks**~~ -- already built (crumbs; see B3.4).

Each of these touches `island_manager.gd` / `brick_world.cpp`, which other chats work in
(struct-bugs, storey units, planet falling): check `git log main` and the handoff docs
([HandoffStructBugs.md](HandoffStructBugs.md)) before starting, and land each one small.

## B6. The strength tree, probed (2026-11-07)

`scripts/strength_tree.gd` (`StrengthTree`, a GDScript prototype nothing in the game calls)
and `tools/strength_tree_probe.gd` (32 checks, all pass). Joint studs come from block boxes
(footprint overlap of one block on another), which matches `seam_studs` everywhere the probe
checks and over-counts masked parts.

**How merges are scored decides everything.** The first version scored a merge by studs per
block of the smaller cluster (as A5.1 suggested). One cluster then swallows single bricks
first, and the top of the tree peels ends off: a running-bond wall's first cut was 4 bricks
at its end; the recipe tower's second, 6 bricks. Scored by studs per *pair* of blocks across
(average linkage, `Score.PRODUCT`, now the default) the top of the tree is balanced parts:

| Build | Bricks | First cut | Notes |
|---|---|---|---|
| long wall, running bond, lying | 105 | 52 / 53 on 36 studs, running **up** the wall (y 3-27) | a course boundary across it holds 80; `_weak_seam` has no seam this way and tears it as a band |
| recipe tower | 982 | 321 / 661 on 160 studs, then 258 / 403 on 156 | cuts step through a storey (y 61-82), cheaper than the storey line (184) or a window row with its columns |
| cottage | 76 | 33 / 43 on 6 studs | |
| watchtower | 215 | 42 / 173 on 14 studs | |
| kiosk | 56 | 4 / 52 on **1** stud, twice | a part on one stud really is the weakest thing in it |

**Energy is shared, not copied.** First version: each child of a cut got all the energy left,
and a hit went from 1 piece to 28 at one step. Now what is left is shared by size, and a
rising hit makes a few parts: cottage 1, 2, 4, 9; watchtower 1, 3, 6; tower 1, 3. Pieces
always partition the part (checked).

**Every node is connected** (checked on 400 nodes a build), so any node can be a piece.

**Bake time** in GDScript: 79 ms for the 982-brick tower, 7 ms for the watchtower. The C++
bake over `JointCache` would be one to two orders faster, and it runs once per build.

**Not shown yet:** the energy scale (a hit's energy vs studs) is uncalibrated -- the probe
uses multiples of the root's studs and a 2 m falloff. That gets tuned against `barrage_probe`
and `--shot` once `_snap_across` can ask the tree.

**Next, if this is wanted:** move the bake into `BrickWorld` (C++, over `JointCache`, baked
with the chunk and kept valid on damage as A5.3 says), then let `_snap_across` take the tree's
pieces for a landing, with `_weak_seam` as the fallback, and compare `barrage_probe`'s band
count (34 of 89 today).

## B7. In C++, and landings use it (2026-11-07)

- **`gdextension/brick/src/strength_tree.{h,cpp}`**: the bake and the split, pure. Scores
  compare by int64 cross-multiplication, ties by node id, so the tree is the same on every
  machine. `strength_tree_probe` holds it to the script prototype: the same bricks, parts,
  merges and first twelve cuts on every build (61 checks).
- **`BrickWorld.strength_split(chunk, point, energy, falloff, relative)`**: bakes the tree
  from the live joint cache (decorative and sheared blocks left out), splits each part, and
  returns groups covering every live block: furniture goes with what it stands on, a sheared
  block alone. `strength_tree_info` is the tree, for probes. Bake 2.6 ms for 982 bricks in
  the debug build.
- **Energy is relative.** In studs per brick, no number fitted both a tower and a cottage
  (the cottage's joints are ~20x weaker for its size; one setting left the tower whole and
  shattered the cottage, the other the reverse). Now energy is a multiple of what each part's
  first cut costs from the contact: `TREE_FIRST_CUTS` 1.2 at the snap threshold, and that
  again each time severity / need doubles, counted up to 8x (`TREE_RATIO_MAX`). By rising
  landing: tower 3, 5, 10 pieces; cottage 2, 5, 8; watchtower 2, 4, 7; kiosk 2, 3, 3.
- **`IslandManager._snap_across`** (`snap_by_tree`, on): after its gates (length, severity),
  a piece up to `TREE_MAX_BLOCKS` (3,000) asks the tree; if it makes more than one piece the
  landing is a tree break (`BrickIsland.tree_hit`) and `split_if_broken` cuts the pieces as
  the crack path does -- each leaves as a DETACH, which clients and replays take as it is.
  Otherwise the seam and crack rules decide as before. `seam_probe` and `crack_probe` test
  those rules with the tree off (23 and 9, pass).
- **`barrage_probe`, tree on vs `-- --tree=0`** (8 of 8 pass both ways): the tree broke 69
  landings into 367 pieces; single bricks coming off landings went from 292 to 95, groups of
  2-8 from 145 to 92, groups of 9+ about the same.

Open:

1. ~~**Cost.**~~ The split search's worst went from 1.4 to 7.7 ms, and a tree landing baked
   twice. **Cut 2026-11-07:** the tree is kept per chunk until something structural changes
   in it (`ConnWatch.stamp`, moved by every `conn_touch` / `conn_forget` and a role change;
   `BrickWorld.strength_tree_of`), so the ask and the cut share one bake and a piece that
   lands again untouched is not baked again; and the bake keeps neighbours in plain vectors,
   not hash maps (982-brick tower 2.6 -> 1.35 ms). `barrage_probe` with the tree: split
   searches 90.4 -> 44.8 ms all told, worst 7.66 -> 2.85 (tree off: 57.7, 1.40).
   `get_strength_tree_stats` counts bakes, cache hits and bake time. Still on the main
   thread; a worker bake is the next step if big pieces need it. That run's one FAIL --
   "throwing them is a small part of a blast", 17.2 ms the worst blast (3.4-4.4 in the two
   runs before) -- is in crumb throwing, which this does not touch; the machine was at 99 C
   when it started.
2. ~~**The fallback tore 10 bands**~~ with the tree on (0 with it off). **Found and fixed
   2026-11-07:** counted (`tree_skip_big`, `tree_whole`, `band_sizes` in the snap census),
   no landing was over `TREE_MAX_BLOCKS`; every band came from a landing the tree made one
   piece of -- which, with energy in first cuts, is a piece with no joint left to cut
   (bricks only sheared loose, or one brick) -- and the seams tore it down to its last brick.
   A brick does not break, so such a landing now snaps nothing. `barrage_probe`: 0 bands, 15
   landings with nothing to cut, 63 broken by the tree. Pieces a tree landing makes vary
   from run to run (5.0-7.3 on average over four runs; the physics is not deterministic).
3. Not looked at in play yet: whether the parts read as "a few big parts" on screen.
4. `PlanetPieces._snap_across` (planets) is untouched.

## B8. Grounding after a small cut, measured (2026-11-07) -- B3.2: not worth building

`tools/ground_search_probe.gd`: recipe towers of rising size, about forty random single-brick
kills each. For every kill, the time of `solve_grounded` (the whole-chunk flood a building's
solve starts with) and of `solve_stress`, the blocks the flood walks, and what A4.1's local
search would walk (from each block that touched the dead one, lowest first, until the ground
or nothing is left; script-side, counting blocks). Editor closed, no other Godot running.

| Tower | Bricks | `solve_grounded` median / worst | `solve_stress` median / worst | Flood walks | Local search walks (median / worst) |
|---|---|---|---|---|---|
| 28 x 16, 30 courses | 982 | 0.01 / 0.05 ms | 0.05 / 0.07 ms | 963 | 33 / 62 (3.4 %) |
| 28 x 16, 120 courses | 3,812 | 0.07 / 0.12 ms | 0.21 / 2.07 ms | 3,792 | 106 / 192 (2.8 %) |
| 40 x 40, 180 courses | 10,966 | 0.22 / 0.77 ms | 0.71 / 1.06 ms | 10,946 | 61 / 171 (0.6 %) |
| 40 x 40, 360 courses | 21,911 | 0.49 / 1.68 ms | 1.35 / 3.50 ms | 21,891 | 97 / 258 (0.4 %) |

The local search agreed with the flood on what falls in all 157 kills.

**Conclusion: do not build it now.** The local search walks a hundredth of what the flood
walks, but the flood itself is half a millisecond on a 22,000-brick tower -- the joint cache
made it cheap. And it could not replace the solve anyway: a brick gone changes the loads, and
a joint can fail in tension far from the cut, so the load pass (`solve_stress`, about three
times the flood) runs either way. What a hit costs a big building is the load pass and the
cascade rounds `solve_structure` adds (3-6 ms on the 22,000-brick tower, city_scene.gd
`_start_solves`), and the stale-solve case that puts it on the main thread. If hit latency
needs cutting, that is the target: a load pass over the region above the cut only (A4.2),
not a faster grounding walk.

Not measured: blasts (many bricks at once; the flood is the same, the local search grows
with the cut) and `solve_structure`'s cascade on its own.

## B9. Small pieces meshed at spawn, measured (2026-11-07) -- B3.3: not now

Counted in `IslandManager` (`sync_meshed`, `sync_mesh_ms`, `sync_mesh_worst`,
`queued_meshed`) and printed by `barrage_probe` beside the spawn profile and the blind-piece
report. One run, headless, with four other chats' Godot runs going -- so the times are high
and the upload to the renderer (a dummy headless) is not in them:

- 43 small pieces meshed on the main thread at their spawn: **32 ms over the whole run,
  0.75 ms each, the worst 3.4 ms**. 20 bigger pieces went to the worker.
- Spawning took 108 ms all told, meshing 37 of it.
- 19 pieces went blind, the worst for 4 ticks, mean 1.95; the biggest blind one was 2,671
  bricks -- a worker-baked piece, which instancing small pieces would not change.

**Conclusion: not worth building now.** Instancing would take away about 0.75 ms per small
piece and spikes of up to ~3.4 ms, and nothing for the big pieces that go blind. Against
that: a per-brick instance draws every face (no hidden-face removal, no merged chamfers, so
the bevelled near look -- Docs/BrickBevel.md -- would need its own instance mesh), and every
moving brick's transform has to reach the renderer each frame (instance buffer writes on
the main thread, or a piece-matrix buffer and a new shader). The cheap fix if the spawn
spikes ever show: a millisecond budget for the main-thread bakes per tick, past which a
piece goes to the worker (and may be blind a tick or two, the trade-off SYNC_MESH_MAX_BLOCKS
was made to avoid). Worth a windowed `--stress` with the editor closed first, which counts
the real upload.

That run also failed `barrage_probe`'s "throwing them is a small part of a blast" (5.71 ms
the worst blast) -- crumb throwing, not touched by any of this, and the second failure of
that timing check in five runs, both on a busy, hot machine.

## B10. Stand-ins: a piece is drawn while its mesh is made (2026-11-07)

The narrow form of B3.3, reviewed by another chat before it was built: instances only until
a piece's worker mesh is ready, not instancing as the way bricks are drawn.

**Measured first, windowed, editor closed, nothing else running** (`--stress
--buildings=200`; peak 93 C, not held back): 284 small pieces meshed on the main thread at
their spawn -- **166.7 ms all told, the worst 14.7 ms**; spawn meshing was 184 of 295 ms of
spawning; 266 pieces went blind, the worst for 3 ticks, the biggest 843 bricks. The headless
figures in B9 (worst 3.4 ms) understated it: they had no upload to the renderer.

**Built: `scripts/islands/island_standins.gd` (`IslandManager.standins`).** Each frame, for the
pieces waiting on a mesh: one that is blind (`is_blind`) gets a stand-in -- a box per live
brick, one MultiMesh per brick size, children of the piece's own mesh node (so they move with
its interpolated transform and cannot jump at the swap), in the piece's own brick material.
`BrickWorld.get_standin_buffers` hands over one ready MultiMesh buffer per size with each
block's colour encoded as the mesher writes it (`block_rgba_grain`: material and grain in
alpha), so the script does no per-brick work. It goes the frame the mesh has something to
draw. No studs and no bevel: a piece stands in only while new and moving, and the near tier
draws a moving piece flat anyway (`BrickNear.SETTLE_MS`). `standins.enabled` turns it off for
an A/B.

- `tools/standin_probe.gd` (11): a 982-brick piece over the bake-here limit is stood in for
  every frame it has no mesh, never both at once, one box per brick, its material, under its
  mesh node, gone when the mesh is up; a box's place and alpha are the block's; off, blind as
  before.
- `tools/standin_shot.gd` (not headless): a small build baked and stood in side by side in the
  real brick shader -- colours and materials match.
- `barrage_probe`: 18-19 stand-ins a run, worst 0.71-0.97 ms for up to 2,656 bricks, covering
  108-117 frames that drew nothing before. Its "some hits found wreckage at rest" check failed
  once (0 hits at rest that run) and passed on the rerun (15) -- the scenario varies; stand-ins
  have no collision.

Next (the review's step 3): send small pieces to the worker too, with stand-ins covering their
first ticks, behind a flag, and A/B the `--stress` numbers above.

## B11. Small pieces on the worker too: measured worse, off (2026-11-08)

The review's step 3: send small pieces (9-200 bricks) to the worker as well, a stand-in
covering their first ticks, so none is baked on the main thread at its spawn. Built behind
`IslandManager.small_meshes_on_worker`; the mesh queue's main-thread part (once a worker bake
is in: assembling and uploading it) is now counted too (`drain_ms`, `drain_count`).

Windowed `--stress --buildings=200`, editor closed, nothing else running, one run each
(peaks 91 and 89 C, not held back):

| | on (`--worker-small`) | off (as before) |
|---|---|---|
| meshed at spawn, main thread | 203, 41 ms (worst 0.8) | 277, 103 ms (worst 2.9) |
| the queue's main-thread part | 213, **832 ms** | 138, 410 ms |
| stand-ins | 134, 19 ms | 50, 8 ms |
| main-thread mesh work, all told | **~892 ms** | **~520 ms** |
| mean frame / city tick | 32.4 / 12.1 ms | 28.8 / 9.7 ms |

Each piece moved saved ~0.8 ms at its spawn and cost ~5.6 ms in the queue: the worker's bake
is the cheap part; assembling and uploading it on the main thread is not. So it is **off by
default**; the switch stays for when the queue's main-thread part is cheaper. (The 14.7 ms
worst spawn bake of B10's run did not come back in either run: 0.8 and 2.9 ms.)

What it found that matters more: **the mesh queue's main-thread part is the expensive one** --
410 ms over the run with small pieces baked as before, and single items of 47-55 ms, for a
10-brick piece. That is a spike source of its own and the next thing to look at for break lag.

Kept from this step: a piece whose mesh goes to the worker is stood in at its spawn
(`IslandStandins.cover`), not at the next frame's update, so nothing processed after the
manager can leave it blind for a frame. `standin_probe` 15.
