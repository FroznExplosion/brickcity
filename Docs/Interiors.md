# Interiors, items and visibility

Design note, and now partly a description. Extends [Plan.md](Plan.md) §4.2 (three layers, only the
last is LOD'd) to the things inside buildings, which is where the object count actually explodes.

**Built: §1-§5, in first pass -- portal test and seeded spill included.** `scripts/room.gd`, `scripts/room_manifest.gd` and the room
half of `BuildingRegistry`: rooms generated from the recipe, contents generated from
`(building seed, room id)`, activation by proximity and by damage volume, a diff that survives
deactivation, and §5.2's analytic resolve for a room that fell over. `tools/interior_probe.gd`
passes 39 checks and `godot --path . -- --rooms` passes 13.

**Not built:** occlusion (§3's `OccluderInstance3D`), item behaviours beyond being brick, and
§5.3's audio rule, which needs audio. The portal test IS built, and it turns out to need no doors
and no windows: a generated building has neither, so every opening in the city is a hole somebody
blew, which falls out of the damage record exactly as §3 said it would -- and means the test costs
nothing until a wall is broken.

One thing the implementation settled that this document argued the other way. §9.2 of
[BuildMode.md](BuildMode.md) wanted fixtures *decorative* -- no load path, crumbling on their own --
and said "the same should be true of a chair". It is not. A fixture with a body of its own turned
out to be a staircase a collapsing building landed on and stopped, and then a staircase left
standing in the rubble of the building it was fixed to; the answer was to build it out of the host's
own bricks. **A chair is the same: it is a small cluster of blocks in the building's grid.** That
makes it destructible, spillable and able to ride a falling floor for free, which is §4.2's
requirement, and it answers §7 question 3 -- yes, items are brick.

---

## 1. The problem is worse than buildings

A building is one recipe. A building with rooms holds *contents*, and contents are the thing that
multiplies: 5000 buildings × 20 rooms × 15 objects is **1.5 million items**. Spawned as nodes that
is not a budget question, it is an instant crash.

But the same answer works, because it is the same shape of problem:

| Layer | Holds | Cost |
|---|---|---|
| **Truth** | a seeded **manifest** — what is in this room, as a list of (item type, slot) | bytes, generated from the room seed on demand |
| **Materialisation** | actual objects | only for rooms that can currently be seen or entered |
| **Presentation** | meshes, collision, physics | by distance, as everything else |

A room nobody has looked into has **no objects at all** — not hidden ones, not culled ones. It has a
seed. That is the same trick as parametric-until-touched, applied one level down.

---

## 2. Rooms come from the recipe, not from authoring

The building recipe already generates walls by rule. It generates **rooms** the same way: floor
plates, internal partitions, door and window openings. A room is then a named volume in the
building's local grid:

```
Room = { id, bounds (grid AABB), kind, seed, openings[] }
```

`kind` (kitchen, office, stairwell, storeroom) drives the manifest generator, so what you find in a
room is consistent with what the room is. `seed` is derived from `(building seed, room id)`, which
makes the contents **reproducible without being stored** — the same room always holds the same
things, and nothing has to be written down until a player changes it.

Only a *changed* room needs a record, and the record is a diff: this item was taken, that one moved.
Same pattern as the building damage record, same reason.

---

## 3. Visibility is per room, not per item

Testing a million items against a frustum is the wrong question. Test **rooms**, and rooms are
cheap because they are few and they are volumes.

- A room is **active** if the player is inside it, or can see into it through an opening.
- Openings are the portals: doors, windows, and — importantly — **holes blown in the walls**.
  A destroyed wall is a new opening, which falls out of the damage record for free.
  > **Built, and windows had to come first.** For a while every opening in the city was a hole
  > somebody had blown, because a generated building had none — so this test could not fire on an
  > intact building, and a room could be walked into but never seen into. `TowerRecipe` cuts
  > windows into every storey now (Status.md, "Windows, so the portal test has something to be a
  > test of"), and the scan reports one box per APERTURE rather than one per side, because the
  > bounding box of two windows is centred on the pier between them and the ray aimed at it always
  > hit brickwork.
- Activating a room materialises its manifest; deactivating frees the objects and keeps the diff.
- Hysteresis on the transition, so standing in a doorway does not thrash.

This is portal/cell visibility, and it suits brick buildings unusually well: the rooms are
axis-aligned boxes on a grid, so the portal test is integer work, not geometry.

**Occlusion is then nearly free.** Godot's `OccluderInstance3D` is render-only and safe at every LOD
(Reference/reddawn.md §9), so the building shell occludes its own interior and the room system
decides what exists at all.

---

### 3.1 What is in a room is not what holds it up ✅ **built**

A room's contents are **blocks in the building's own chunk**, and they are marked
`Block::decorative`. The role changes two things and nothing else: a decorative block weighs
nothing in `solve_stress`, and it is left out of the centre of mass and the support footprint in
`check_stability`. Everything else is deliberately identical — same grid, same occupancy, same
bake, same collision, same damage record — so it is grounded through whatever it rests on, and it
is still in the list `check_stability` hands to `split_island`, which is §4.2 for free.

That is the third answer to a question BuildMode §9.2 got wrong twice on the unit rather than on
the idea. A "decorative" **frame**, with a chunk and a body of its own, gave a building that landed
on its own staircase; moving it to a layer nothing structural could touch gave a staircase left
standing in the rubble. The unit is the **block**.

The workshop authors it. `I` switches between STRUCTURE and INTERIOR and everything else about
placing a brick is the same in both; the recipe carries one bit per block (v4) and the city reads
it back. Nothing about a brick's shape or position could have inferred this — a table built out of
wall bricks is a table, and only its author knows.

**Grounding goes into a room's contents and never back out of them.** The role takes a block out
of the load and out of the balance test; for a while it left the connectivity graph alone, and that
was not a limitation but a bug — grounding is reachability, so a chair was a perfectly good step on
the path and a section that should have come down hung off the table standing in it. Two directed
rules fix it: grounding never leaves a decorative block for a structural one, and a decorative block
is reached only from BELOW. Structure keeps the old rule and needs it — undercut a wall and its
weight travels sideways to the corners that still stand — but furniture has no such story, and
without the second rule a chair still touching a wall floated after its floor had gone.

**And the role is what lets a room be the streaming unit.** A decorative block is outside the
chunk's face bake and outside the building's collision body, so opening a room touches neither: it
lays its bricks, adds them to the building's own small furniture body, and redraws a MultiMesh over
the furniture's blocks alone. **0.9 ms on a 50,000-brick, 4,000-room tower**, against 224.7 ms when
a chair invalidated the building's bake. Measured in `--interiors --big`; Status.md, "What a room
costs, and the two whole-building bills inside it".

---

## 4. What happens to the contents when the building comes down

Three cases, and the middle one is the interesting one.

**The room survives.** Nothing happens. Its objects are where they were.

**The room is destroyed.** Its objects should not survive intact — but they should not simply
vanish either, because the player watched a building fall and expects to find what was in it.

**The room is cut in half.** Objects on the standing side stay; objects on the falling side go with
the island.

### 4.1 Spill the manifest, do not randomise it ✅ **built**

The obvious implementation is to delete the contents and scatter random debris. **Seeded spill is
better and costs the same**: when a room is destroyed, run its manifest and spawn *those* items into
the rubble volume, in a damaged state.

- A kitchen spills kitchen things. A storeroom spills crates.
- Looting wreckage becomes meaningful rather than a slot machine — the building you flattened had
  contents, and you can still find them.
- It is **free**, because the manifest was already the cheap representation. Nothing extra is stored.
- It is deterministic, which matters for co-op and for saves (Plan D9).

Cap it with the same degradation ladder as debris: spill the N most valuable or most visible items
in full, represent the rest as generic rubble, and let distance and budget decide N.

> **As built.** A room open when the building fell needs nothing -- its contents are already bricks
> in the chunk that becomes the island. A shut one is marked `spilled` and **nothing is built until
> somebody arrives** (§5.1), at which point the manifest runs into the wreck: each item against the
> face that is now the floor (§5.2), a third of its bricks killed from the room's seed, four items
> in full and the rest written off. There is no generic-rubble item yet, so "the rest" means gone
> rather than reduced — the honest version of the same trade.

### 4.2 Items ride the island, not the world

A detached island is already a chunk with its own transform (Plan §4.2). Objects on a falling piece
of floor should be **parented to that island's body**, so they travel with it and land with it —
then spill when it hits. Anything else reads as furniture hanging in mid-air where a room used to be.

---

## 5. Activation, and where things are after a collapse

§3 said *when* a room activates. This says **why**, because the three reasons are not the same
urgency and conflating them is what makes a collapse either expensive or wrong.

| Trigger | What it is | When | Layer |
|---|---|---|---|
| **Compromised** | the room's bounds intersect a damage or collapse volume | **immediately, whether or not anyone can see it** | truth |
| **Visible** | the portal test reaches it | when it happens | presentation |
| **Proximate** | player inside or adjacent | when it happens | presentation |

That split is [Plan §4.4](Plan.md)'s, unchanged: *apply at truth level immediately, promote
presentation only if somebody can see it.* A compromised room has to resolve now because its
contents are part of what the collapse **does**. A merely visible room only has to look right.

### 5.1 Compromised rooms spawn so their contents can be thrown clear

This is the case that earns immediate activation, and it is worth the cost: a room in the path of a
collapse materialises its manifest, parents its objects to the island holding that piece of floor
(§4.2), and lets them ride it down — so a kitchen in a toppling building throws its contents out of
the hole instead of quietly deleting them.

**Budget it exactly as everything else is budgeted.** A twelve-building collapse can compromise
hundreds of rooms in one tick, and [Status](Status.md) records the worst tick at 949 ms before
structure work was budgeted. So: rooms near the camera spawn full contents; distant ones write
**spilled** into the diff and resolve analytically (§5.2) if anybody ever arrives. §4.1's
N-most-valuable cap is the same lever, applied here.

### 5.2 A room that fell while nobody was looking: resolve, do not simulate

The hard case, and the one that decides whether deferred interiors feel honest. A building topples.
Room R was never materialised. Ten minutes later a player walks up to the wreckage and R activates.
Its contents must **already** be where a collapse would have put them.

**A — analytic resolve. The default.** A room is an axis-aligned box in building-local space, and the
island holding it has a known world transform. Snap world-down into the room's local frame and take
the nearest of six — **the operation `set_chunk_gravity` already performs**, and exact for a section
lying on a face. That names the room's *new floor*. Place each item against that face at its
authored position projected onto it, with a seeded yaw and a small seeded offset.

No physics, no settling frames, deterministic, instant, and it replicates for free. Nobody can tell
whether a chair tumbled into that corner or was put there.

**B — spawn and settle, hidden.** Spawn at authored local positions under the island's real
transform, let Jolt settle them, reveal when quiet. More faithful, and it costs real time.

> Note what B cannot be. Godot's `PhysicsServer3D` exposes `space_create` and `space_set_active` but
> **no public per-space step**, so there is no isolated, time-accelerated settle to hide this in. B
> means spawning into the *real* space over real frames with the objects hidden — more expensive and
> less deterministic than A, and visible if the player is already looking in.

**C — resolve at collapse time** and store the result. Correct, and it pays the cost at the worst
possible moment: during the collapse, for rooms nobody may ever enter.

**A by default; B behind a budget for the room the player is actually standing in; C never.**
Whichever runs, the answer is written into the room diff, so the second visit is identical to the
first — which is the same reason the damage record exists.

### 5.3 Deferred events are silent

A room resolving ten minutes after the collapse must make no noise. The rule that gets this right
everywhere, not just here:

> **Audio belongs to the event, not to the presentation of the event.**

The crash happened when the building fell. Materialising its consequences later is replaying
history, not causing it. The same rule already covers debris meshes arriving one to three ticks late
(Status, "Presentation lags the world by a few ticks"), and it is what stops deferred work from
sounding like a bug.

The corollary matters as much: a **compromised** room activating during a live collapse *is*
concurrent with its event, so it is audible, and should be. The test is not "was this spawned late"
but "is the event happening now".

### 5.4 What an uncompromised room costs: nothing

Worth stating plainly, because it is the entire point. A room that was never in a damage volume and
that nobody has approached has **no objects, no bodies, no meshes and no diff**. It has a seed. The
building around it collapsing does not change that until something asks.

---

## 6. Why this does not need a new system

Everything above is the existing architecture applied one level down:

| Buildings | Interiors |
|---|---|
| recipe → blocks on damage | room seed → items on visibility |
| damage record survives de-materialisation | item diff survives de-activation |
| a blown wall is a hole in the mesh | a blown wall is a **new portal** |
| islands carry bricks | islands carry the furniture standing on them |
| debris settles into rubble | contents spill into the same rubble |

The one genuinely new piece is the **room graph and its portal test**, and that is a small,
integer, grid-aligned problem.

---

## 7. Open questions

1. ~~**Does a room's manifest depend on damage state?**~~ **Answered in §5.2: already-spilled**, by
   analytic resolve rather than simulation. Cheaper, deterministic, and indistinguishable. Built:
   `RoomManifest.down_axis` snaps world-down into the room's frame and takes the nearest of six, and
   `resolved_cell` puts each item against that face.
2. ~~**How far does "can see into" reach?**~~ **Answered: 70 m, plus a view cone.** A room is opened
   by an opening that is inside the cap, within 20 degrees or so of where the player is looking, and
   reachable by a ray that gets to the middle of the hole. The coarse impostor for far interiors is
   still open, but at 70 m a room is a few pixels of dark and nothing has asked for one.
3. ~~**Do items connect to the brick grid?**~~ **Answered: yes, and it was the cheap option rather
   than the expensive one.** An item is a handful of blocks laid into the HOST's chunk -- three
   blocks for a crate, five for a table -- so it is destructible, meshed, collided, rideable and
   spillable by paths that already existed. A chair with a body of its own would have needed all
   five of those written again. What it costs is that a room's contents only exist while the
   building holds bricks, which is what §1's ladder wanted anyway.
4. **Multiplayer**: seeded manifests are deterministic, so two clients agree without syncing
   contents. The diff is what replicates. Same shape as the damage record.
