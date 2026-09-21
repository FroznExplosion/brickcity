# Build mode — connecting bricks

Design note. Implements [`printed-brick-city-spec.md`](printed-brick-city-spec.md) §9, and reaches
forward into §7 (gun assembly) and §8 (character assembly) because all three are the same problem.
Interaction prior art is [reddawn §8](Reference/reddawn.md#8-forge-style-placement-and-snapping);
structural prior art is [reddawn §5](Reference/reddawn.md#5-structural-orientation--walls-floors-ceilings-roofs).

**§11 is built and probed end to end** -- the part palette, an editable chunk, the workshop, eight
orientations, frames, a multi-frame creation placed in the city (Stage 4b) and fixtures: a spiral
staircase that costs nothing until somebody walks up to it (Stage 5). §11 records what each one actually cost and what it found; the
sections above it are the design the implementation was measured against, and where the two
disagree the implementation won and the section says so.

> **Scope: buildings only.** Vehicles, aircraft and guns are deferred — there are existing systems
> to pull from for those, and nothing below should be built to anticipate them. Concretely that
> **defers every link kind with a degree of freedom** (hinge, swivel, slider, axle, motor) and the
> float connector table (§6.1). It does **not** defer the link *mechanism*, because a frame weld is
> a zero-DOF link and sideways building needs it (§2). §6.3's DOF table is written down so the shape
> is known, and is not on the build list in §10.

---

## 0. Conclusion first

**There are exactly two ways two parts can be attached, and everything else is a special case of
one of them.**

| | Between | Stored? | Geometry | Degrees of freedom |
|---|---|---|---|---|
| **Stud joint** | two blocks **in one frame** | never — derived from the occupancy grid | integer, axis-aligned | none. rigid |
| **Link** | two **frames**, or two blocks | yes, explicitly | exact integer for a frame weld; float for a connector | 0–6, authored |

The stud joint is what already exists and what the whole destruction stack rides on
([Plan.md](Plan.md) D4, D5). It needs almost nothing new.

A **frame** is one chunk at one of the 24 axis-aligned rotations. Upright bricks are frame 0;
sideways bricks live in a rotated frame and connect to each other normally *inside* it. Frames are
how sideways building happens, and §2 is the argument for them — including why the obvious
alternatives (rotating a block, authoring a lying-down part) cannot work.

The link is the thing that has to be invented, and it is **one mechanism, not three**. The
"floating piece attached to an object but not by studs" is a link with zero DOF. A whole sideways
sub-grid is welded on by a link with zero DOF. A Technic swivel is the same link with one DOF. A
hinge, a slider, a steering knuckle, a gun barrel clipped to a core (spec §7), a character shoulder
(spec §8) — all the same edge type with different limits.

Building them as one system is the whole design. Building them as four is how this goes wrong.

**The second claim:** the destruction solver is already the build-mode validator. `solve_stress`
computes tension against a physical constant derived in [BrickFailure.md](BrickFailure.md) §4.5, and
`check_stability` asks whether the centre of mass is over the footprint. Point them at a
half-finished creation and they answer "will this hold" and "will this tip over" with no new code.
That answer is what build mode should be drawing on the screen.

---

## 1. A creation is a tree of chunks

```
ASSEMBLY            the thing the player made. a recipe, a name, a save file.
   └ FRAME             an orientation the player is building in. ONE chunk. usually 1-3 per build.
        └ BLOCK           one placed part, integer cell in that frame, one of 8 orientations.
   └ LINK              frame -> frame, or block -> block. 0-6 DOF. breakable.
```

A **frame** is a chunk whose `Transform3D` carries one of the 24 axis-aligned rotations, at an
origin offset from its parent. Upright bricks live in frame 0; sideways bricks live in a rotated
frame; everything inside a frame is ordinary integer grid work, unchanged. §2 is entirely about why
this is the answer to sideways bricks and what makes it exact.

This is not a new hierarchy. **A chunk with its own transform and its own `PhysicsServer3D` body
already exists** — that is what `split_island` produces and what `island_manager.gd` drives. A link
is a `PhysicsServer3D` joint RID between two of those bodies. A creation that articulates and a
building that has come apart are the same runtime objects.

Consequences that fall out for free:

- A link that fails under load makes the child an island. `split_island` already does that.
- A creation is destructible without writing anything: it is chunks, and chunks break.
- A creation can be shot, re-solved and split, because [Status.md](Status.md) says islands can.

### 1.1 Bodies merge even though chunks do not

A 200-piece build must not become 200 rigid bodies. Chunks cannot merge — their grids are at
different orientations, which is the entire point of a frame. **Bodies can.**

At commit, walk the link tree. Any maximal subtree joined only by **weld** links collapses into
**one body** carrying every chunk's shapes, transformed into the root's space. Only a link with at
least one DOF gets a real constraint and forces a body boundary.

A gun with an upright frame, two side frames and a hinged stock is therefore **four chunks and two
bodies**, not twenty of either.

Overlapping shapes from two frames on one merged body are harmless — a body does not self-collide.
Overlap has to be rejected at *placement* time instead, which is §2.3.

---

## 2. Sideways bricks: a second grid, not a rotated block

Sideways building is required — spec §7 guns, §2's curves, and vehicles and aircraft all need it. It
is also the one thing the integer grid cannot express directly. The resolution is the **frame**.

### 2.1 Why rotating a block does not work, and why authoring a "sideways brick" does not either

One stud is 0.35 m, one plate 0.14 m (D6). A 1×1 brick is 0.35 × 0.42 × 0.35. Rotate it ±90° about
X or Z and the stud axis swaps with the plate axis:

| | before | after | in **that chunk's** grid units |
|---|---|---|---|
| X extent | 0.35 m | 0.42 m | **1.2 studs** |
| Y extent | 0.42 m | 0.35 m | **2.5 plates** |

Neither is an integer, so the block has no cell footprint and `place_block` has nothing to write.

**Authoring a separate lying-down part does not escape this**, and that is worth being explicit
about because it is the obvious first idea. The grid quantises *world extents*; it does not care how
the part was modelled. A part authored 0.42 m along a stud axis is 1.2 studs whoever authored it.

What *does* work as an authored part is a piece whose extents are already integer and which carries
**studs on a side face** — a bracket, a headlight brick. That part is ordinary and grid-aligned.
It does not solve sideways building on its own; it is the *anchor* for it. Something still has to
attach to that side stud, and that something is a frame.

### 2.2 A frame is a chunk with a rotated transform, and the arithmetic is exact

A frame is one of the 24 axis-aligned rotations plus an origin offset. Inside it, studs are studs
and plates are plates and every existing solve runs unchanged. It costs no new type: `Chunk.xform`
is already a full `Transform3D`, and `set_chunk_gravity` already solves a chunk whose grid is not
world-aligned — that is how toppled buildings work today. For a frame rotated exactly 90° the
gravity snap is **exact**, so [limitation 5](Status.md#known-limitations) does not bite here.

The question is whether two frames can be offset so their bricks actually meet. They can, because
our ratios inherit the coincidence the real system is built on:

```
5 plates = 5 x 0.14 = 0.70 m = 2 x 0.35 = 2 studs
```

So define a **tick** = `gcd(0.35, 0.14)` = **0.07 m**. One stud is 5 ticks, one plate is 2. Every
frame origin offset is stored as a `Vector3i` in ticks, and every cell boundary in every frame lands
on the tick lattice whatever its rotation. Cross-frame alignment is therefore **exact integer
arithmetic**, with no float drift — which G6 and D9 require and which a metres-based offset could
not give.

> **This is where the earlier draft of this document was wrong, and the distinction matters.** A
> 0.07 m *occupancy* grid is fatal: 50× the cells per block, and the 150 m tower's chunk goes from
> 9.9 MB to **497 MB** (limitation 11 already calls the current density wrong). But the tick lattice
> is never an occupancy grid. It is **only the coordinate system weld offsets are expressed in** —
> three integers per frame, not per cell. Nothing allocates against it. The 50× figure has no
> bearing on it at all.

### 2.3 What frames buy that per-brick welding does not

Welding every sideways brick individually would work and would be much worse. **All the bricks at
one orientation and one commensurate offset share a frame**, so:

- A wall face with 30 sideways tiles is **one rotated chunk holding 30 blocks**, welded once — not
  30 chunks and 30 welds.
- Those 30 blocks connect *to each other* by ordinary stud joints, inside their own grid. They hold
  together as a real sub-structure rather than as thirty independent things glued to a wall.
- The face bake — 98% of what a chunk costs (Status, "What a grid costs") — is paid once per frame,
  not once per brick.

A typical build is 1 upright frame plus 1–3 rotated ones. A complicated gun might reach 6.

**The cost, and it is a real new gap:** occupancy is per chunk, so nothing currently detects a
sideways brick intersecting an upright one. Frames need a **cross-frame overlap test** — block AABBs
in tick space, checked at placement. Build-mode counts are small and this is authoring-time only, so
it never touches the hot path (B2). It does have to exist before the first frame is placed.

### 2.4 Frames and links divide the work

| | Handles | Cost |
|---|---|---|
| **Frame** | axis-aligned SNOT. the common case, many bricks per weld | one chunk, one weld |
| **Link** | articulation (hinge, swivel, motor), non-90° angles, pin/clip/dovetail connectors | one constraint |

Frame-to-frame attachment **is** a weld link, so §0's two-edge claim survives intact. A frame is not
a third mechanism; it is the cheap, bulk specialisation of the one we already have.

### 2.5 The eight in-frame orientations still apply

Within any frame, a block has 8 grid-legal orientations: 4 yaw (90° about the frame's own Y swaps
two stud axes) × 2 flip (180° about X or Z leaves every extent unchanged, and swaps which face
carries studs — §3.1).

So the full orientation space is **24 frames × 8 in-frame orientations**, and every one of them is
integer.

### 2.6 45° and anything else: allowed, but welded rather than clutched

Frames are **not** limited to two orientations, and not really to 24 either. A frame is a chunk with
a `Transform3D`, and a `Transform3D` holds any rotation. What the 24 buy is not *possibility*, it is
*exactness*, and it is worth being precise about which of four things each rotation costs:

| frame rotation | grid inside it | gravity | stud-mating across frames | weld offset |
|---|---|---|---|---|
| one of the 24 axis-aligned | exact | **exact** | **exact, integer ticks** | integer |
| any **yaw** (45°, 22.5°, anything) | exact | **exact** — yaw never changes which way is down | impossible | float |
| arbitrary pitch/roll | exact | nearest of six ([limitation 5](Status.md#known-limitations)) | impossible | float |

Two things fall out.

**Internal connectivity never degrades.** Whatever the frame's rotation, the grid inside it is
integer and every existing solve runs on it unchanged. Rotation lives in the transform, which is
already true today: a toppled building keeps the tall narrow grid it had standing (Status, "What a
grid costs").

**Only cross-frame *stud* mating is lost.** At 45° a cell corner lands at `0.35 · cos 45°`, which is
irrational against the 0.07 m tick lattice, so two frames cannot be guaranteed to actually touch
stud to socket. The weld becomes a glue joint with a stated capacity rather than a clutch
connection.

That limit lands exactly where the physical system's limit is, which is a good sign rather than a
compromise: **a 45° section in a real brick model is held by a turntable or a hinge, not by studs.**

> **Rule.** Snap frame rotations to the 24 by default. Allow free rotation behind `ALT`, and mark
> such a frame **weld-only** in the UI, so the one thing you lose is visible at the moment you
> choose it.

### 2.7 A building placed at 45° in the city

**This already works, and mostly because it was made to work for a different reason.** A toppled
building is a chunk at an arbitrary rotation, and every path that touches one had to be fixed for
that during M4. The same fixes carry a deliberately rotated building:

| | |
|---|---|
| Placement | `BuildingRegistry.register()` already takes a full `Transform3D` and hands it to `set_chunk_transform` |
| Damage | world queries transform into chunk space before touching the grid (Status, "Islands are chunks") |
| Debris impact | contact points and the collider come from the solver's own manifold, **not** from AABB containment — which is precisely the bug that was fixed for rotated islands (Status, "Falling debris damages what it lands on") |
| Gravity | a **yaw-only** rotation leaves local down exactly `-Y`, so `set_chunk_gravity` is exact here. Limitation 5 does not apply |
| Collision | shapes are local; the body carries the transform |

One real hazard, and it is narrow: `BrickWorld::world_to_grid` is a static function that assumes the
world grid is axis-aligned. Today it is called **only by the probes**, never on a gameplay path — so
nothing is broken, but it is a trap sitting in the API for whoever writes the placement UI.

Two things to check rather than assume, because neither has ever been run at a non-zero yaw: the
shell's collision boxes, and the far-tier per-512 m MultiMesh. Both should already be local-space
plus a transform.

**Add a probe for it** in the shape of the existing G-gates: register one building at 0° and the
same building at 45°, apply the same hit in each building's own local frame, and assert the
block-level outcome is identical. That is the cheap way to keep this true rather than
true-by-accident.

### 2.8 What frames cost destruction

Frames are the only thing in this document that makes destruction *harder*, so the cost belongs in
one place.

**Connectivity becomes two-level.** Inside a frame, stud joints, derived from occupancy, free.
Between frames, welds. `find_detached_groups` runs per frame as it does now; a union-find over the
weld edges then merges the per-frame components. Welds number in the tens per building against
thousands of blocks, so this is noise.

**Grounding runs root-first through the weld tree** (§3.3), instead of once per chunk from a plane.

**Detachment operates on weld-graph components, not on one chunk.** A released weld may take several
frames with it, and a frame may still be held by a second weld. `split_island` already produces the
runtime object; what is new is deciding *which* frames leave together.

**Weld capacity needs no new constant.** Side-stud contact count × the 9.3 N-per-stud figure from
BrickFailure §4.5. A decorative sideways detail welded on by two studs comes off when the wall near
it is hit, by the same physics that decides everything else.

**And the one genuine regression:**

> Status is explicit that *"the edge list is never stored… a derived graph cannot go stale when a
> block dies."* **A weld violates that.** It names two specific blocks, so killing either leaves a
> dangling edge, and every weld must be invalidated on block death.

That is the true cost of frames — not memory, not solve time, but a stored graph that has to be
maintained. It is the reason to keep frame counts low and to prefer an archetype over a frame
wherever one will do (§9.1), rather than treating frames as free because they are cheap.

---

## 3. Orientation is baked, not stored

[Limitation 14](Status.md#known-limitations) says both orientations of a 2×4 are separate
archetypes. **Keep it.** Bake the eight orientations as eight archetype variants at load, deduped by
symmetry: a 2×2 brick needs 1, a 2×4 needs 2, a 2×4 with an asymmetric mask needs 8.

The expected library is tens of parts (Plan §2), so this lands in the low hundreds of archetypes and
stays in the low MB. Nothing downstream changes — not the cell mask, not the surface cells, not the
face bake, not the shared collision shapes — which is the whole reason it is the right answer.

The recipe stores `(base_archetype, orientation)` and resolves to a variant id at load, so the
recipe survives a re-bake with a different variant ordering.

### 3.1 Flips force a two-bit face mask, and that is an improvement

`Archetype` today carries `studs` and `sockets` as one bit per column, and `joint_exists` asks
"does the lower block have a stud here and the upper block a socket". A flipped brick has studs on
its **bottom** and sockets on its **top**, which that test cannot express.

Replace the two one-bit masks with **one two-bit mask per face**:

```
up_face[x][z]   in { NONE, STUD, SOCKET }
down_face[x][z] in { NONE, STUD, SOCKET }

joint exists at column c  iff  (up_face(L,c)==STUD   && down_face(U,c)==SOCKET)
                            || (up_face(L,c)==SOCKET && down_face(U,c)==STUD)
```

Flipping a variant swaps the two masks and mirrors `cells` in Y. Three things then work that do not
work today, at no cost:

- **Inverted parts.** An upside-down slope is a roof underside; a bracket is how real builds change
  direction. Both become ordinary blocks on the ordinary grid.
- **Tiles**, already handled, stay handled: `up_face = NONE`.
- **Double-sided plates** (studs above *and* below) become expressible, which they are not now.

### 3.2 Side studs need a third pair of masks, or a connector

A bracket has studs on a **side** face, and that is what a frame welds to (§2.1). Two ways to say so:

- **As masks.** Add `side_face[dir][u][v]` for the four lateral directions. Exact, integer,
  and it makes a side joint the same kind of object a vertical one is.
- **As connectors** (§6.1). One `STUD_GRID` connector per side stud, float-positioned.

Prefer the masks. A side stud is on the grid — it is at an exact tick offset by construction — and
demoting it to a float connector throws that away, then asks the weld arithmetic to recover it.
Connectors should stay reserved for things that genuinely are not on any grid.

---

### 3.3 Grounding has to cross a frame boundary

`solve_grounded` floods from a foundation level: the cells lowest along the chunk's gravity axis. A
rotated frame has no foundation of its own — its path to ground runs **sideways, through a weld,
into another chunk**. Left alone, every sideways sub-assembly reads as ungrounded and falls off on
the first solve. That is the same failure mode the interior floor slabs had (Status, "Floors are
structure"), and it will present identically: *everything sideways comes off the instant the build
is touched.*

The generalisation is small. `set_foundation_level` takes a plane; it needs a sibling that takes an
explicit **seed block set**. A weld link then contributes its attachment blocks as grounding seeds
in the child frame, and the flood proceeds normally from there.

Three things follow, none of them expensive:

- **Solve order is the link tree, root first.** A frame is solved after whatever grounds it.
- **A weld carries the child frame's whole weight** as tension, so it needs the capacity computed in
  §6.4 — a frame welded on by two side studs really should fall off.
- **Islands want this too.** [Limitation 16](Status.md#known-limitations) says a settled island is
  never re-anchored and gets no stress solve. Seed-set grounding is most of what that needs.

---

## 4. The placement loop

[reddawn §8](Reference/reddawn.md#8-forge-style-placement-and-snapping)'s interaction transfers
verbatim. Its *geometry* does not, and the reason is worth stating because it inverts their hardest
lesson.

> Reddawn deleted their world grid — it was "the thing preventing rooms", because arbitrary OBB walls
> forced into 2 m cells either intersected or refused to place. **Our pieces are integer footprints
> on a stud grid by construction, so the grid is not an obstacle to snapping, it *is* the snap.** We
> get their result without their magnet passes, for the 95% of placements that are stud joints.

1. Palette selection spawns a translucent **ghost** using the archetype's own mesh.
2. Camera ray. Hitting a block face gives the cell across that face's normal; hitting the baseplate
   gives a cell on it. Snap to the grid.
3. **Tint states** (theirs, worth stealing exactly): cyan = fits and connects · amber = fits but
   connects to nothing · red = occupied. The target joint face highlights.
4. `Q`/`E` yaw by 90°, `F` flip, wheel raises/lowers by one plate, `SHIFT`+wheel by one brick.
5. **`TAB` switches frame.** Aiming at a side stud offers the frame that stud faces into, creating
   it if this is the first brick in it. The grid overlay redraws in the active frame's orientation,
   so which grid you are building in is always visible rather than inferred.
6. `ALT` enters **link mode** (§6) — the off-grid escape hatch, exactly where reddawn put precise
   mode.
7. Place. Push to the undo stack.

Amber is load-bearing, not cosmetic: a piece that fits but connects to nothing is precisely the case
the "floating piece" question is about — it is legal, and it is where build mode offers to make it a
link instead.

---

## 5. Three questions, deliberately not conflated

| Question | Answered by | Gates placement? |
|---|---|---|
| **Does it fit?** | occupancy free in this frame — `place_block` already tests this — **and** no overlap with any other frame in tick space (§2.3) | **yes** |
| **Does it connect?** | ≥1 stud joint to the assembly, or a link | no — amber, offer a link |
| **Will it hold?** | `solve_stress` + `check_stability` | **no** — it is an overlay |

The third is the interesting one and it is nearly free. Build a cantilever too long and the joints
at its root go over capacity; the overlay draws them red **while you are building**, using the same
9.3 N-per-stud constant that decides whether a real building falls down (BrickFailure §4.5). Build a
tower too narrow and `check_stability` says the centre of mass has left the footprint.

Budget it: run the solve on a debounce after placement, not per frame. Whole-chunk stress on 16,590
blocks is 6.6 ms, and a player creation is orders of magnitude smaller — so this is free at
build-mode scale even before [limitation 17](Status.md#known-limitations)'s local solve arrives.

**It must not gate placement.** Players build impossible things on purpose and then brace them.
Telling the truth about what is over capacity is useful; refusing the placement is not.

---

## 6. Links

### 6.1 Connectors are the one place float is allowed

`Archetype` gains connector metadata — the `socket_<type>_<key>_<n>` empties the Blender pipeline
already emits (spec §10 ¶3, and the AI part prompt already requires them):

```cpp
struct Connector {
    Vector3 local_pos;   // metres, archetype-local
    Vector3 local_dir;   // +Z out of the joint, per the part prompt
    uint8_t type;        // STUD_GRID | DOVETAIL | PIN_CLIP | BALL | AXLE
    uint8_t key;         // compatibility key within the type (spec section 7)
};
```

Float enters the model here and **nowhere else**. A connector never participates in the integer
adjacency test. That fence is what keeps D5 true.

### 6.2 A link is a socket match, not free placement

Reddawn needed corner-to-corner and corner-to-edge magnet passes because they were guessing at
geometric intent. We are not: a connector match fully determines the pose except for spin about the
shared axis.

```
Link {
  a: (frame, block, connector)
  b: (frame, block, connector)
  kind:   WELD | HINGE | SWIVEL | SLIDER | AXLE | MOTOR
  spin:   authored angle about the shared axis, 15 deg steps, ALT for free
  limits: per-kind (min/max angle, travel, motor target)
}
```

A **frame weld** is the degenerate, common case: `kind = WELD`, both sides are side-stud columns
rather than float connectors, and the relative pose is the frame's own tick offset (§2.2). It
carries no float at all.

Two clicks: a connector on the ghost, a connector on the target. Types must match and keys must
match — which is spec §7's *"every part in a class uses the class's standard connector, so every
generated combination assembles"*, enforced in the editor instead of hoped for.

### 6.3 Kinds map straight onto `PhysicsServer3D` joints

Bodies here are RIDs, not nodes (Status, "Collision"), so joints are RIDs too — `joint_create`,
then `joint_make_hinge` / `joint_make_pin` / `joint_make_slider` / `joint_make_generic_6dof`. No
`Node` is held across systems, which is B5.

| kind | constraint | used for |
|---|---|---|
| `WELD` | none — bodies merge (§1.1) | sideways bricks, decorative curves, glued sub-assemblies |
| `HINGE` | hinge, with limits | doors, hatches, folding wings |
| `SWIVEL` | cone-twist / 6DOF | ball joints, character shoulders (spec §8) |
| `SLIDER` | slider | pistons, sliding doors |
| `AXLE` | hinge, free spin | wheels |
| `MOTOR` | hinge or slider with motor enabled | driven wheels, steering, cranes |

> **Verify before the connector table hard-codes limits and motors.** Godot's Jolt backend is not
> parameter-identical to GodotPhysics on 6DOF and on motor drive. Build one hinge and one motor as a
> throwaway and measure first.

### 6.4 Links break, and they break into the existing system

A link has a capacity, from the same source the stud capacity comes from: connector contact area ×
a per-type strength constant. A pin-and-clip grip is weaker than a dovetail rail, and that should be
a number in the connector table, not a feel.

When a link exceeds capacity it releases. The child subtree becomes an island — an existing chunk
with an existing body, handed to `island_manager`. Destroying a Technic creation therefore costs
close to nothing new, and it is consistent with BrickFailure §5: **the link separates, both parts
survive.**

---

## 7. Three physics states, and why Test is not Live

| State | Bodies | Solver | Destructible |
|---|---|---|---|
| **Build** | none. static preview. | stress + stability, debounced, drawn as an overlay | — |
| **Test** | one per weld-subtree, links as joints | full Jolt | **no** |
| **Live** | identical | full Jolt | yes |

**Test must not be destructible, and reset must be exact.** You need to drive the thing you built,
watch it fall over, and get it back. If test mode could damage the creation you would lose work every
time you tried it — the same argument spec §7 already makes for gun test mode.

Reset is cheap because the authored pose is the recipe: restore each chunk's `Transform3D`, zero
every velocity, re-create the joints. D9's single seeded RNG is what makes "byte-identical" a claim
rather than a hope.

---

## 8. The recipe is the save, the print and the network payload

Same pattern as every other representation in this project (Plan §4.2, spec §5, spec §7's "a gun is
a seed + part ID list"):

```
BuildRecipe {
  version                                    # invalidates saved damage, per M3's RECIPE_VERSION
  name, palette, kind                        # STRUCTURE | VEHICLE | AIRCRAFT | GUN | PROP | CHARACTER
  frames: [(rotation_index, origin_ticks)]   # frame 0 is identity. Vector3i, exact. section 2.2
  blocks: [(frame, base_archetype, orientation, cell, colour)]   # placement order IS id order
  links:  [(a_frame, a_block, a_conn, b_frame, b_block, b_conn, kind, spin, limits)]
}
```

**Placement order is id order** — that is the determinism guarantee M3 rides on, and it is what
makes a player creation eligible for the same damage record, the same de-materialisation and the
same LOD ladder as a generated building. A build that cannot be de-materialised cannot go in the
city.

It is also what the exporter walks for STL (spec §10 ¶4), and what replicates if multiplayer
happens (mvs-c §7: one serializer, three consumers).

### 8.1 In the city you place a recipe, you do not edit bricks

Building happens in a **workshop**: its own scene, its own baseplate, no streaming, no LOD, no
neighbours. In the free-roam city the only build action is **placing a finished assembly at a
transform** — which is exactly what `BuildingRegistry` already stores, so a player-built house
enters the city by the same door `TowerRecipe` does.

That decision pays for itself several times over:

- **The workshop needs no streaming and no LOD ladder.** One assembly, up close, always at full
  detail. Every hard problem in [Status](Status.md)'s limitation list about promotion, trimming and
  de-materialisation is out of scope while authoring.
- **The stress overlay can be exact.** Nothing is budgeted, nothing is deferred, nothing is
  approximated — one small assembly, solved outright on every change.
- **Placement in the city is registration, not construction.** No in-world grid, no cross-building
  connectivity, no question about what a player build does to its neighbours' chunks.
- **`kind` decides anchoring at placement**, which is where open question 2 lands: a `STRUCTURE`
  registers anchored and grounded, everything else spawns as an island with a body.

---

## 9. Fixtures, and the spiral staircase

A spiral staircase inside a building that can collapse is a good test question, because it is the
smallest thing that needs frames, dormancy and a stress solve at once.

### 9.1 Three ways to build one, and the cheapest is not frames

**A — masked archetypes, no frames at all.** If the step angle divides 90°, a wedge step has an
integer footprint and is an ordinary masked archetype on frame 0. Four or eight steps per revolution
work; sixteen does not.

**Eight per revolution is also the right look.** A brick-built spiral is a chunky sequence of eighth
turns, not a smooth helix — spec §2's house style is faceted, and a smooth spiral would be the one
thing on the building that is not. So the cheapest option is also the correct-looking one, and it
should be the default rather than the fallback.

**B — one frame per step**, when the angle genuinely does not divide 90°. Three storeys at sixteen
steps per revolution is 48 frames. Worth costing honestly rather than assuming it is too many:

| | |
|---|---|
| A step | ~10 blocks, ~60 baked faces after the cell-face merge (§10.1) |
| Per face | ~232 B across verts, normals, colours, uvs, uv2s, owner/other |
| **Whole staircase** | **~700 KB of bake, and occupancy is negligible** |
| Bodies | **1** — every weld is rigid, so §1.1 merges the lot |

So **memory is not the objection**. The objection is 48 entries in a weld table that has to be
invalidated on block death (§2.8), and 48 per-chunk solve calls with fixed overhead. That is what
makes A preferable, not the byte count.

**C — its own `BuildRecipe`, welded in**, when the staircase is reused across buildings. That is
open question 6, and a staircase is the case that justifies it.

### 9.2 A fixture should be decorative, and that is what makes it cheap

A frame declares one of two roles, and the choice changes almost everything it costs:

| | Structural | Decorative |
|---|---|---|
| In `solve_stress` | carries load, contributes capacity | **absent entirely** |
| Grounding | welded into the host's grounding tree (§3.3) | none — held by assertion |
| Weld invalidation on block death | required | required. it is still a stored edge |
| When the host region dies | detaches as an island and is re-solved | **released, or destroyed outright** |

A spiral staircase is decorative. So are cornices, railings, signage, pipework and shutters —
everything that in a real building is fixed *to* structure rather than *being* structure.

> **This section did not survive contact, and what replaced it is simpler.** Built as written — a
> fixture outside `solve_stress`, with a chunk and a body of its own — a staircase is a separate
> object standing inside a building, and it behaves like one. A collapsing building landed on its
> own staircase and stopped there; moving the fixture onto a collision layer nothing structural
> could touch fixed that and produced the opposite bug, a building coming down around a staircase
> left standing in the rubble.
>
> Both are the same mistake. **A staircase in a brick building is made of bricks, in the same grid,
> clipped to the floors it lands on.** Its blocks go in the host's chunk and everything follows:
> the stress solve carries them, a section that breaks off takes the steps inside it, the island it
> becomes has them, the damage record already keys on block id, and something landing on the flight
> breaks it the way it breaks anything else. The trade is accepted rather than hidden — a staircase
> that comes apart with the building is a staircase the building can lean on.
>
> What survives of "decorative" is the **frame** flag (§2.4, `Assembly.set_decorative`), for
> something welded on rather than built in, and the `Role` the recipe still carries for when a
> fixture is genuinely not brick.
>
> **And then the idea came back on the right unit: the BLOCK.** `Block::decorative` is exactly the
> left-hand column of the table above, minus the parts that needed a separate object to mean
> anything: absent from `solve_stress`, absent from the centre of mass and the support footprint in
> `check_stability`, and otherwise identical to every other brick in the chunk. It is held by the
> structure it rests on rather than by assertion, so it needs no grounding of its own; it detaches
> with whatever it was standing on rather than being "released"; and it rides the island, because
> it is in the island. A room's contents are marked this way, and the workshop's INTERIOR layer
> authors it (§11, and Docs/Interiors.md §3.1).
>
> The staircase is **not** marked, and that is the trade §9.2 already accepted written down once
> more: a staircase in a brick building is made of bricks and the building is allowed to lean on
> it.

Three costs vanish at once:

- **48 staircase frames add nothing to the solve**, because a decorative frame is never in it.
  §9.1's cost model drops to weld-table maintenance alone.
- **Seed-set grounding (§3.3) is needed only for *structural* sideways frames.** That is gap 5, the
  largest single thing frames require, and fixtures do not need it at all.
- **No load path means no ordering constraint.** Decorative frames materialise, break and release in
  any order without changing anyone else's answer.

Behaviourally it is also exactly right: a staircase struck by a collapsing building **crumbles on
its own** instead of participating in the collapse. It has no capacity to exceed and nothing depends
on it, so the only question left is whether its own blocks survive — which `apply_hit` and
`separate_near` already answer.

> **The flag is authored, not player-facing, in the first version.** "Decorative" is a promise that
> nothing load-bearing rests on it, and a player handed the flag will build a floor out of decorative
> parts and get a bridge that holds for free. If build mode ever exposes it, the rule is that a
> structural frame may not weld *to* a decorative one.

### 9.3 The structural warning, which is not a bug

A spiral staircase is a cantilever, and BrickFailure §4.5 has a number for that: a full 8-stud
connection holds **~29 hanging bricks** at game scale, so two studs of contact holds about seven. A
step is roughly eight blocks.

**Steps hanging off a central column are therefore right at the failure threshold and will shed
under any load.** That is physically correct and it will look excellent when something hits the
building. It also means the part has to be authored so the steps **rest on** the column — compression,
which is free (BrickFailure §4.1) — rather than hang off it. A constraint on the model, not a defect
to engineer around.

### 9.4 Dormancy: the same ladder, a third time

A **fixture** is a sub-assembly of a building with its own materialisation state. This is not a new
system; it is [Plan §4.2](Plan.md) and [Interiors §1](Interiors.md) applied to fixtures instead of
furniture, and that is now the third question this ladder has answered.

| Layer | Holds | Cost |
|---|---|---|
| **Dormant** | recipe + damage record | bytes. Drawn as part of the building's shell, or not at all |
| **Materialised** | frames, blocks, collision, stress | only on interaction |
| **Presented** | mesh and face bake | by distance |

Materialisation triggers, in the order they will actually fire: **room activation** (Interiors §3's
portal test — and a hole blown in a wall is a portal), **damage inside the fixture's volume**, and
**player proximity**.

Freezing is already built. A cluster that comes to rest freezes into a static body, and the stress
solve runs on change rather than per tick — so a materialised, quiet staircase costs one static body
and no per-frame work at all. What is missing is only the *dormant* tier, which is
[limitation 2](Status.md#known-limitations) (islands have no LOD ladder) wearing a different hat.

**If the building comes down while the fixture is dormant, do not simulate it.** Interiors §4.1's
seeded spill is the answer: materialise it already-broken into the rubble volume. Cheap,
deterministic, and indistinguishable from having simulated it.

### 9.5 A damaged fixture bakes exactly as cheaply as an undamaged one

Yes — and the reason is already in [Plan §4.2](Plan.md): damage lives in the **truth** layer and
presentation is *derived* from it. A cheap mesh built from `(recipe + damage record)` is the same
walk as one built from `(recipe)`, with holes. Same order of triangle count, same memory, and it
regenerates only when the damage record changes — which for a quiet fixture is never.

**This is not currently done, and the gap is in buildings rather than fixtures.** `_make_shell()` in
`city_scene.gd` builds from `(footprint_x, footprint_z, courses)` and consults the damage record
nowhere. `BuildingRegistry.trim()` frees a damaged building's bricks at distance while keeping the
damage, and the streaming loop then hands that building a shell — **an intact one**. So a building
you blew a hole in, walked away from and looked back at presents an undamaged silhouette.

G1 says damage state survives demote → promote byte-identical, and it does. **The picture does
not.** That is the companion gate nobody wrote:

> **G1b — the cheap representation must show the damage the truth layer is holding.**

The fix is small in principle and has one real dependency: the shell is generated from
`TowerRecipe.layout()`'s vertical bands, not from block ids, so it cannot currently ask "is block N
dead". Either the shell walk moves to block ids, or the damage record grows a coarse per-band
summary the band walk can read. The second is cheaper and is almost certainly enough at shell
distance — at 110 m a hole is a few pixels, and what has to read right is that there *is* one.

---

## 10. What has to be built

Ordered by dependency. Items 1–4 are small; item 8 dominates.

| # | Work | Why now | Size |
|---|---|---|---|
| 1 | **`remove_block`** — free the cells, invalidate the bake | [Limitation 22](Status.md#known-limitations): a dead block still owns its cells. Build mode needs delete and undo on day one | S |
| 2 | **8 orientation variants per archetype**, with the two-bit face mask (§3.1) and side-stud masks (§3.2) | Limitation 14. No downstream change | S |
| 3 | **`would_connect(frame, cell, archetype)`** — non-mutating | Drives the ghost tint every frame; must not touch the chunk | S |
| 4 | **Tick-space frame offsets + cross-frame overlap test** (§2.2, §2.3) | The only new thing frames actually need. Integer, authoring-time only | S |
| 5 | **Seed-set grounding** — `solve_grounded` from an explicit block set, not a plane (§3.3) | Without it every sideways frame falls off on the first solve. Also most of what limitation 16 needs | M |
| 6 | **Weld table** — stored edges, **invalidated on block death** (§2.8) — plus weld-subtree body merging (§1.1) and weld-graph component detachment | The one genuinely new graph in the system, and the one that can go stale | M |
| 7 | **Ghost, snap, tint, undo, palette, frame picker** | §4 | M |
| 8 | **Baked mesh + convex colliders per archetype** | [Limitation 12](Status.md#known-limitations). Today a masked part is a voxel approximation. In a city at 100 m that is invisible; **in build mode a curve is a metre from the camera and reads as a staircase.** Build mode is what makes this unavoidable. The seam is already in `Archetype` | **L** |
| 9 | **`Assembly`** — a first-class owner of frames + welds + recipe | Today `island_manager` owns chunks ad hoc. Nothing owns a *creation* | M |
| 10 | **Rotated-building probe** (§2.7) | Cheap, and it keeps a property that is currently true by accident | S |
| 11 | **Structural / decorative flag on a frame** (§9.2) | Removes fixtures from the stress solve and from seed-set grounding entirely | S |
| 12 | **Damage-aware shell — gate G1b** (§9.5) | A trimmed damaged building currently redraws intact. Not a build-mode bug; build mode is what made it visible | M |
| — | *Float connectors on `Archetype`; hinge/swivel/slider/axle/motor* | **Deferred with vehicles and guns.** Not needed for buildings | — |

Note what is **not** on this list: streaming, LOD, promotion, trimming, in-world grid arbitration.
§8.1 is what removes them.

### 10.1 The two prerequisites ✅ **both done**

**Merging cell faces into block faces** was already in the bake when it was written down as
outstanding. Re-measured on the real gate tower: **8.34 baked faces per block**, not the 43.9
[limitation 1](Status.md#known-limitations) claimed, against a floor of 6 for an isolated box. The
extra 2.3 is `other` fragmentation in a running bond and is required by the index partition. Status
limitations 1 and 24 are corrected.

**The damage-aware shell** is done and is now gate **G1b** (§9.5). 744 bytes and 2.43 ms per
damaged building, computed at de-materialisation; intact buildings draw byte-identical geometry to
before. `tools/shell_probe.gd` passes 28 checks.

One thing build mode still stresses and nobody has measured:
[limitation 9](Status.md#known-limitations) -- surfaces under 65,536 vertices cannot be
index-patched and take a full rebuild -- becomes the common case rather than the rare one, because
every build-mode chunk is small. Cheap per event, but it should be measured rather than assumed.

---

## 11. The build order, concretely

Scoped to **buildings and their fixtures**. Six stages. Every one is a thing that runs, and every
one carries a probe, because that is how the rest of this project is gated.

### Stage 0 — the part palette ✅ **done**

`scripts/brick_palette.gd` is the single table of what a part is. **20 parts** — plates, bricks and
tiles at 1x1, 1x2, 1x4, 1x6, 2x2, 2x4 and 4x4 — expanding to **64 archetypes** once Stage 3's
orientations are in, squares deduped. One naming rule, one mass rule, and orientation is *generated* rather than written,
which is §3's argument made concrete: the recipe names a part and an orientation, the runtime only
ever sees a resolved archetype id.

Plates and bricks can be built on. **Tiles are studless** — solid, sockets underneath, nothing on
top — which is the only thing separating a tile from the plate of the same size, and it is
structural rather than a finish. A studless *brick*, for capping a wall head, is one more table row
when it is wanted.

`tools/palette_probe.gd` passes **532 checks** — that game scale and print scale are one system at
43.75x on every axis, that a square part expands to exactly one archetype and others to two that are
the same part rotated, that mass is a pure function of cell count anchored on the real 2.4 g 2x4,
and that every studded part stacked on itself **joins** while every tile **does not**.

`TowerRecipe.bake_palette()` delegates to it and adds only its own masked cornice.

### Stage 1 — an editable chunk ✅ **done**

Three calls on `BrickWorld`, and the placement loop sits entirely on them.

| | |
|---|---|
| `remove_block(chunk, block_id)` | Undo a placement and **give the cells back** — the half `kill_block` deliberately does not do ([limitation 22](Status.md#known-limitations)) |
| `can_place(chunk, cell, archetype)` | Exactly `place_block`'s occupancy test, without the write |
| `would_connect(chunk, cell, archetype)` | Stud joints a part *would* make. **-1 red, 0 amber, positive cyan** — §4's three tint states in one call |

`would_connect` counts upward and downward joints alike, so sliding a plate in underneath something
already standing reads as connected; and it honours the stud masks, so a brick on a tile reports
**no** connection rather than promising a joint the solver will not make. The count is contact area,
which is what the stress solve charges for.

**Gate met.** Build a wall, build the same wall with a placement undone in the middle, and the two
are byte-identical — same alive count, faces emitted, vertex buffer and colours.
`tools/edit_probe.gd` passes **67 checks**.

> **The one real trap.** A tombstone cannot null its `archetype`: the face bake and
> `get_block_boxes` walk every block and index `archetypes[b.archetype]` with no guard at all. So a
> removed block keeps a valid archetype and carries an explicit `removed` flag instead, and the four
> whole-list loops skip on that. An edit is also **not damage** — `get_dead_blocks` excludes removed
> blocks, or undoing a placement would punch a permanent hole in the recipe's damage record.

### Stage 2 — the workshop ✅ **done**

`scenes/workshop.tscn`. One frame, upright only. A baseplate, a ghost that snaps to the grid and
tints from `would_connect`, `[`/`]` and the wheel for parts, `R` between the two axis variants,
`,`/`.` for colour, `Z` to undo, `H` for the stress overlay, `F5`/`F9` to save and load, and `ENTER`
to place the result in a city and shoot it.

**Gate met.** Hand-build a house, save it, place it in the city, shoot it, and it breaks like a
generated building — because it is one: `BuildingRegistry.register_build()` takes a `BuildRecipe`
and materialise, damage, de-materialise and replay are all unchanged.
`tools/build_probe.gd` passes **46 checks**.

Two things the implementation settled that §8 only asserted:

* **`pop()` is the only removal `BuildRecipe` allows.** Placement order is block id order, the damage
  record keys on block id, so removing from the middle would renumber everything after it and
  invalidate saved damage. Undo removes the last placement; mid-build removal needs the stable ids
  Stage 3 brings.
* **The same recipe builds two different ways on purpose.** Rebased to the chunk origin for a city
  placement (a tight chunk around exactly these bricks), and *not* rebased in the workshop, whose
  chunk is a fixed baseplate the recipe is already expressed in.

And one that confirms §5: **an empty stress overlay is correct.** Compression is free, so a building
that is merely standing loads no joint — a plain stack measures a max stress ratio of exactly
0.0000. The probe asserts the stack at zero and a real cantilever above it, so "nothing drawn"
cannot quietly become "nothing working".

### Stage 3 — orientations ✅ **done**

A part is baked once canonically; every other orientation comes from
`BrickWorld.bake_variant(base, name, yaw, flip)`, which transforms the cell mask and **both** face
masks together and dedupes. The palette is **20 parts → 64 archetypes**, and the workshop's `R`
and `F` select among them.

§3.1's two-bit masks are in: `up_face` and `down_face` each hold NONE / STUD / SOCKET, and a joint
is a stud meeting a socket either way round. `bake_shaped_archetype` keeps its one-bit signature and
translates, so nothing existing had to change.

**Gate met**, and one consequence of the rule was not anticipated here:

> **An upside-down brick cannot clip to a right-way-up one.** Normal-over-normal and
> inverted-over-inverted both join; the two mixed pairings put stud against stud or socket against
> socket and do not. That is correct — in the real system you need a bracket between them — and it
> is what gives the **double-sided plate** (studs on both faces, newly expressible) a job: it mates
> with a socket on both sides, so it bridges exactly the join neither part can make alone.
>
> Four assertions in the first probe run were wrong in this way and the implementation was right.
> §3.1 should be read as describing *what can be expressed*, not as a promise that inverting a
> brick lets it attach from below.

`tools/orient_probe.gd` passes **51 checks**. The one worth keeping is that the cell mask and the
face masks move *together*: an inverted slope's downward stud must sit under the column that is
actually full height, which is what catches transforming one and not the other.

**Side-stud masks (§3.2) are NOT done, deliberately.** Nothing reads them until a frame welds to
one, so they would be a mask with no consumer and no test. They move to Stage 4, where they have a
job.

### Stage 4 — frames ✅ **done**

Sideways building. A frame is a chunk at one of the 24 axis-aligned rotations at an exact integer
tick offset, and `Assembly` (`scripts/assembly.gd`) owns the frames and the welds between them.
The workshop stands **all six build grids up front** -- upright, four sideways, inverted -- all over
the same volume, and `TAB` switches between them. The build box is a cube in tick space (48 studs and
120 plates are both 240 ticks), so a grid covers the same region whichever way it is turned.

Aiming marches the ray in **world** space and tests every grid, then resolves the cell in the active
one: what you point at was probably built in a different grid, and that is what makes co-located
grids usable rather than six separate scenes.

| Built | |
|---|---|
| Ticks | `ticks_per_stud` = 5, `ticks_per_plate` = 2, asserted as `5 plates == 2 studs` in integers |
| 24 rotations | signed axis permutations with determinant +1; the transform is **derived** from (rotation, ticks) |
| `get_block_ticks` | exact world box at any rotation — a signed permutation maps a box to a box with no slop |
| `overlaps_frame` | the cross-frame test, authoring-time only. One tick of overlap is refused; exactly flush is allowed |
| Weld table | endpoints stored, **aliveness derived** (see §2.8) |
| `solve_grounded_from` | grounding from a seed set, so a frame can be grounded through a weld |

**Gate met.** A sideways panel welded on by two bricks stands; damage elsewhere leaves it alone;
killing the two bricks kills both welds and the panel sheds, its own bricks intact.
`tools/frame_probe.gd` passes **67 checks**.

`BuildRecipe` gained frames to match — a rotation and tick offset per frame, a frame index per
block, and `build_into(assembly)`. A pre-frames recipe loads with every brick in frame 0 rather than
being rejected.

> **The seam Stage 4 left open is closed.** A multi-frame build can be placed in the city; see
> Stage 4b below. `register_build` used to refuse one rather than drop its sideways frames.

**Side-stud masks (§3.2) are still not built.** Frames weld by an explicit `add_weld` call rather
than by finding a side stud to clip to, which is enough for the gate and for authoring. The masks
become worth having when placement should *offer* a weld because a bracket is there — a UI
affordance, not a structural one.

### Stage 4b — a multi-frame build, placed in the city ✅ **done**

A `Building` holds an `Assembly`: one chunk per frame, the welds between them, and a damage record
**per frame**, because a block id only means anything inside one chunk. Everything downstream was
already general enough to take it -- the city draws and collides one node per frame, and a hit on
the panel and a hit on the wall are the same code path.

Three things had to be true first, and only the first was obvious:

* **Welds live in the recipe.** They were made at placement time in the workshop and existed nowhere
  else, so a saved sideways build loaded with its frames and *nothing holding them on*, and every
  rotated frame fell off on the first solve. `BuildRecipe` v2 adds a weld column -- two BLOCK IDS
  per weld, because the frames are already known from the blocks and a second copy of that fact
  could only disagree with the first. A v1 file loads as a weldless v2, which is exactly what it
  was saved as.
* **A rotated frame cannot be rebased.** A city placement wants a tight chunk around exactly the
  bricks it holds, and frame 0 gets one -- but a frame's offset from the root is stored in ticks,
  so moving its grid origin moves its bricks away from the welds that hold them. **The rebase goes
  in the transform instead**: one translation, in root space, applied to every frame alike. That is
  a rigid move of the whole assembly, so the tick lattice is untouched and the build still lands
  with its own floor on the ground.
* **Grounding is asked in cell space.** The root's bricks start at the author's own lowest cell,
  not at zero, so the foundation level has to be set to it. Without that the whole build reads as
  ungrounded and sheds itself on the first solve.

**Gate met.** `tools/build_probe.gd` passes **74 checks** -- the welds round-trip, the frames keep
their exact offset under a rotated placement, damage lands in the frame that was hit and nowhere
else, both frames keep their record across de-materialisation, and killing the two anchor bricks
takes the panel off whole with its own bricks intact. In the city itself,
`godot --path . -- --buildshot` passes **12** more against a real scene: every frame past the root
has a node with something in it, the panel is solid to a ray where the panel is, and shooting it
removes panel bricks and leaves the house alone. `tools/demo_build.gd` writes a two-frame demo, so
the scene has something to place without hand-building one first.

**What a placed build gets.** A shell of its own (§12 question 3, answered), so it streams and trims
on the same rules as a generated building: it arrives as a silhouette holding no bricks, becomes
bricks when something shoots it, and goes back to a silhouette -- **with the hole in it** -- when
nobody is near. The stress solve and the detached-group
search still run per chunk, so a *whole frame* comes off when its welds die (which is the Stage 4
gate) but bricks inside a sideways frame do not shed locally the way the root's do. Toppling sheds
the frames as separate pieces rather than as one welded body: a weld is authoring-time structure,
and §6.3 defers real joints.

### Stage 5 — fixtures ✅ **done**

| | |
|---|---|
| Build | The structural/decorative flag (§9.2); the dormant tier (§9.4); a spiral staircase as masked wedge archetypes at eight steps per revolution (§9.1 A) |
| Gate | A dormant staircase costs zero chunks and zero bodies; is built with the building; comes apart with the building; and is ordinary brick while it stands |

`scripts/fixture.gd` is the tier, `scripts/staircase_recipe.gd` is the part, and every building in
`scenes/city.tscn` has one up the middle of it.

**Option A, exactly as §9.1 argued it.** Eight steps a revolution is 45°, which divides 90, so a step
is an ordinary masked archetype and there are no frames anywhere in a staircase. The eight sectors
are authored as eight masks rather than one mask in four yaws, so which way the flight winds is a
property of the recipe rather than of the extension's rotation enumeration.

**The steps rest on the newel** (§9.3). Every step carries its own two-stud slice of the central
column and clips to the slice below it, so the load path is compression, which is free. What
cantilevers is the tread — three studs of it — and that is the part §9.3 says will shed when
something hits the building. The tread is two plates thick and the rise is two plates, so the
treads meet: a continuous helicoid rather than a ladder with gaps in it.

**No triggers, and no tier of its own.** A fixture is built into its host's chunk when the host is
built, and that is the whole of its life cycle: dormancy is **inherited**, because a building that
is still a recipe has no bricks at all, its staircase included. The first version had three wake
triggers, a streaming budget, a sleep range, a support test and a release path; all of it went when
the blocks moved into the host's grid, and none of it is missed.

**A staircase needs a stairwell.** The floors it passes through are the building's own blocks, so
the fixture carves the shaft before it lays its steps — `remove_block`, not `kill_block`, because
this is an EDIT and not damage: the cells come back, the ids stay, and `get_dead_blocks` leaves a
removed block out, so a stairwell never reads as a hole somebody shot. Without it, three steps of a
twenty-seven step flight were silently refused wherever a floor crossed them.

**Gate met**, in two halves. `tools/fixture_probe.gd` passes **47 checks** on the truth layer: the
eight masks tile one revolution with the newel in all of them and no tread cell in two, a flight is
grounded through the step below it, attaching a fixture creates no chunk and no bricks, the flight
goes into the building's own chunk with stable ids and is clipped to the building's own bricks, the
stairwell leaves the damage record empty, a hit on the flight lands in the *building's* record and
survives de-materialisation, cutting the building through detaches a section that brings its steps
with it, and a decorative frame is skipped by `solve_grounded` and *released* rather than detached
when its welds die — including the rule that a structural frame may not be grounded through a
decorative one. `godot --path . -- --fixture` passes **17** more against the real scene: one chunk
for a building and not two, a figure a little under three bricks tall standing on a tread it found
by looking, shooting the flight damaging the building, and toppling the building taking the whole
flight with it. The
authoring end has a gate of its own -- `godot --path . res://scenes/workshop.tscn -- --gate`, **16
checks**: `K` attaches a fixture and draws it as a chunk that is none of the build's frames, undo
takes it back without touching the bricks, a reload rebuilds both the record and the preview, and
the result still places in a city.

**And they are authored in the workshop.** `K` drops a staircase where the ghost is, and
`BuildRecipe` v3 carries it: one record per fixture rather than a column, holding a kind, a cell, a
role and its parameters. The cell is in **frame 0's grid**, the same coordinates the bricks are in,
which is what makes it rebase with the build — and the two rebases had to be made to agree, because
a single-frame placement moves the cells and a multi-frame one moves the transform (Stage 4b). The
fixture is previewed as its own chunk, never as part of a frame, and undo is one stack: bricks and
fixtures come off in the order they went on.

The default flight is measured rather than guessed — from the placement cell to the highest brick
above it, at two plates a step, never shorter than one revolution — because a staircase to nowhere
is what a guess produces.

**What is not done.** The structural/decorative *choice* is still not player-facing (§9.2's own
condition): `K` makes a decorative staircase, and nothing in the workshop offers the flag. A fixture
has no shell tier — it is drawn when awake and not at all when dormant, rather than appearing in the
building's cheap representation (§9.5 is about buildings; the fixture half of it waits on the same
answer as §12 question 3). A fixture is still materialised wherever it is when a blast reaches it,
which is what a building does too. And a staircase is the only kind there is: railings, cornices and
pipework are more masks on the same machinery, not new machinery.

### Two things that are not build mode, but build mode needed them ✅ **both done**

| | |
|---|---|
| **Merge cell faces into block faces in the bake** | Already done when it was written down as outstanding. Re-measured on the real gate tower: **8.34 baked faces per block**, not 43.9. See §10.1 |
| **Damage-aware shell — gate G1b** | Done, §9.5. 744 bytes and 2.43 ms per damaged building; intact ones draw byte-identical geometry to before |

### What is deferred, and stays deferred

Hinges, swivels, sliders, axles, motors and the float connector table — so vehicles, aircraft and
guns. §6.3 records the shape so nothing built now forecloses it, and nothing above depends on it.

### Why this order

**Stage 2 before Stage 3 and 4.** A workshop that can only build upright is already a complete,
shippable thing: buildings are mostly upright bricks. Orientations and frames make it *better*, not
possible.

**Stage 4 builds the weld table on the easy case.** A weld is a zero-DOF link, so the table, the
component detachment and the invalidation bookkeeping all get exercised with no constraint solver
involved. If articulation is ever picked up, it adds kinds to a table that already works.

**Stage 5 is not really a build-mode stage.** The dormant tier it needs is
[limitation 2](Status.md#known-limitations) — islands have no LOD ladder — and
[Interiors §5](Interiors.md) needs the identical thing for room contents. Whoever does it first
should do it for all three.

---

## 12. Open questions

**Answered since the first draft** — kept here because both answers shaped the document above.

- *Where can you build?* In a **workshop**, on its own baseplate. The city gets finished assemblies
  placed at a transform, never brick-by-brick editing (§8.1).
- *Structure or object?* From `kind` on the recipe, decided at authoring time and applied at
  placement (§8, §8.1).

- *Do vehicles, aircraft and guns drive the design?* No — deferred, see the scope note at the top.

Still open:

1. **Can a placed building be edited in place, or only removed and re-placed?** "Removed and
   re-placed" costs nothing and is the assumption above. Editing in place drags most of §8.1's
   savings back in.
2. **Do player buildings get the LOD ladder?** Half answered by §11 Stage 4b, and the half that is
   answered is the one that was guessed wrong: a build with frames has *several* chunks where a
   generated building has one, and that part is now built -- materialise, damage, the record and
   the presentation all take a list of chunks. What is still open is the cheap end. A placed build
   is resident and untrimmable today because there is nothing to trim it *to*, which is question 3
   below, and the LOD ladder cannot start until that has an answer.
3. **How does a multi-frame building generate a shell?** ✅ **Answered: a voxelised silhouette**
   (`scripts/build_shell.gd`). A tower's shell comes from its parameters; a build's comes from its
   **recipe**, which is the same truth layer by another name. Every block's box is mapped into root
   ticks — a rotated frame included, so a sideways panel is part of the silhouette rather than a
   special case — dropped into a voxel grid two studs and a course across, and the faces between
   filled voxels are culled. The demo house is 165 bricks and **868 triangles** of shell.

   Two things came free with choosing the recipe rather than a box. **Damage is exact**: a tower's
   shell cannot ask "is block N dead" and takes the per-band segment mask of gate G1b, while a
   build's shell walks block ids and leaves the dead ones out, so the hole is in the right place.
   And **a build is trimmable at last**: it streams and trims on the same rules as everything else,
   where before it was resident from the moment it was placed.
4. **How many frames is too many?** Not decidable on paper, same as Plan §8's chunk-size question.
   §9.1 says the cost is weld-table maintenance rather than memory. Start unbounded, measure a
   deliberately frame-heavy building.
5. **Sub-assembly reuse.** Can a saved build be placed as a *part* inside another one? §9.1 C — a
   weld to a whole `BuildRecipe` rather than to a block. One extra indirection, a large gain, and a
   staircase is the case that justifies it. Cheap to allow for now, expensive to retrofit.
6. **Is a prop its own `BrickWorld` chunk?** [Interiors.md](Interiors.md) §6.3 asks the same thing
   about furniture, and §9.3 above answers most of it for fixtures. Interiors should be re-read in
   that light.
