# Multiplayer — can this destruction system be networked?

Short answer: **yes, and the substrate for it is now in and tested.** The grid is integer, the
recipes are deterministic generators, damage is a recordable command, every random draw goes through
one seeded RNG, the stress solve is fixed-point integer arithmetic, and a piece is named by what it
holds rather than when it was cut.

What is *not* built is a networking layer — a transport, server authority, and a bandwidth budget
for physics state. That is deliberate. What is built is everything that would have been expensive to
retrofit afterwards, and `tools/replay_probe.gd` proves it rather than this document asserting it.

---

## 1. The conclusion everyone reaches

Two independent sources land in the same place, and it is not the obvious one.

**Red Dawn** (`Reference/reddawn.md` §10), having tried it in Godot and then evaluated Unreal's
Chaos:

> **Do NOT replicate physics or debris state.** Replicating destruction physics state is
> unreliable — documented cases where mesh division appears only on the host.

**Teardown**, whose 2026 post-mortem describes a 2021 experiment that failed exactly that way:
naive synchronisation of moving objects and voxel data "used enormous amounts of bandwidth and
completely choked the connection when large objects were destroyed."

What both settled on is a **split**, not a single model:

| Stream | Carries | Guarantee |
|---|---|---|
| **Reliable, ordered** | destruction *commands* — what was hit, where, how hard | every client applies the same commands in the same order and gets the same structure |
| **Unreliable, periodic** | physics state — transforms and velocities of loose pieces | eventual consistency; divergence is tolerated because it is cosmetic |

Teardown budgets roughly 1 Mbit/s per client for the second stream and runs a priority queue over
it, sending what the player can see first. The first stream is tiny: "commands are the same
regardless of object size".

The important consequence: **the settled outcome must agree; the way it got there need not.** Which
bricks are dead and which pieces detached is authoritative. The tumbling trajectory of a falling
section is decoration.

---

## 2. Why this maps unusually well onto Printed Brick City

Most destruction systems have to invent a compact authoritative representation. This one already has
three:

**A building is a recipe, not geometry.** `BuildingRegistry` holds `(footprint_x, footprint_z,
courses, transform, RECIPE_VERSION)` and a damage record. `TowerRecipe.build()` is a pure
deterministic generator — the same parameters always produce the same blocks in the same order, and
that is already load-bearing, because de-materialisation and re-materialisation depend on block id
*N* meaning the same brick before and after. A client can be sent a city as a few hundred bytes of
recipe parameters and build it locally.

**Damage is an event with four numbers.** Everything that hurts a building goes through
`apply_hit(chunk, world_point, radius)` or `separate_near` / `separate_planes`. Over the wire that is
a building id, a point, a radius and a kind. Nothing else.

**The state that must agree is already integer.** `Block` stores `cell` as `Vector3i`, `archetype`
as an index, `colour` and `hp` as bytes, and `alive` / `support_broken` as flags. The damage record
is a list of block ids. Connectivity is integer cell adjacency. None of that can drift.

**Every random draw already goes through one seeded generator.** `BrickWorld` owns the RNG, there
is not a single `randf()` at any call site in the project, and iteration is in fixed block-id order
with components sorted largest-first. This was Red Dawn's "cheap hedge, retrofit cost ≈ rewrite",
and it has been paid.

---

## 3. What was not ready, and now is

All three gaps from the first draft of this document are closed, and each is proven by
`tools/replay_probe.gd` rather than asserted here.

### The stress solve is integer

`solve_stress` used to accumulate `b.load += share` in floats and compare `pull / capacity > 1.0`.
Iteration order is fixed, so two runs of the *same binary* agreed. What was not guaranteed was
agreement across **different builds or architectures**, where FMA contraction or a compiler's
reassociation moves the last bit and flips a comparison sitting on the threshold. One flipped joint
cascades into a different collapse.

Load is now `int64_t` in fixed-point mass units (`brick::MASS_FIXED`, 1024 per unit of archetype
mass), and the failure test is a pure integer comparison with no division in it:

```cpp
const int64_t pull     = b.load * contact_tension;
const int64_t capacity = contact_tension * capacity_per_stud * contact;
if (pull > capacity && !b.support_broken) { ... }
```

Sharing load down the graph divides, so the remainder is handed out one unit at a time in neighbour
order — integer division alone would quietly destroy load and a tall building would get *lighter*
further down. `max_ratio` is still a float because it is reported and never decided on.

This is the same move Teardown made: destruction logic in fixed-point, floats everywhere else.

### Damage is a recordable command

`DamageLog` (`scripts/damage_log.gd`) records `(tick, kind, target, point, radius, normal, limit,
seq)` and replays it into a world. It is **always on** now: co-op and save-anywhere both need it
([AI.md](AI.md) A1, A17). Nothing writes to it directly any more — `_apply_blast` and
`_shear_building` commit through `WorldAuthority` (`scripts/world_authority.gd`), the one door every
structural change goes through. On the host a change is applied, committed and published; on a
client it is only requested, and applied when the host's committed entry comes back, in the
host's `seq` order. `tools/loopback_probe.gd` runs a host and a client over a wire that delays and
reorders, and checks they end with the same world.

The same recording is the wire format, the join-in-progress mechanism and a save file. Nothing about
islands, transforms or velocities goes in it — that is physics state, it is allowed to differ, and
replicating it is what both sources warn against.

### Pieces are named by content

`get_chunk_content_hash` is an FNV-1a over every living block's absolute cell and archetype, in
sorted cell order. No float touches it and it does not depend on block ordering, so the same piece
has the same name on every machine — regardless of the order the pieces happened to be cut out in,
which is decided by wall-clock budgets and therefore by hardware.

### What the probe proves

```
the solve is decided by integers
  ok    same peak load, exactly  137.929688 vs 137.929688
  ok    every block carries an identical load  0 differ
a recorded log replays into the same world
  recorded 14 command(s) against 612 surviving brick(s)
  ok    the replayed world is the recorded world
  ok    a log survives serialisation
pieces are named by their content
  cut order A gave chunk ids 1, 2; order B gave 2, 1
  ok    the first piece has the same name in both
  ok    and the two pieces are told apart
```

That third block is the point: two worlds cut the same pieces in opposite orders, got different
chunk ids, and still agree on what each piece is.

---

## 4. What would cross the wire

| | Size | Stream |
|---|---|---|
| City definition | recipe parameters per building, ~24 B each | once, at join |
| Damage event | building id, point, radius, kind | reliable, ordered |
| Damage record (late join) | dead block ids per damaged building | once, at join |
| Piece transforms | id, position, orientation, velocities | unreliable, periodic, prioritised by what the player can see |

The third row is the one that would need watching: after a heavy collapse the city held **5,900
splits and 400 islands**. Sending a transform for every loose piece every tick is not affordable;
this is exactly what Teardown's priority queue and bandwidth budget exist for. The mitigations the
system already has help directly — settled pieces stop moving and need no updates, small debris is
deleted after 2.5 s, and distant wreckage gives its geometry back.

---

## 5. What is left

The substrate is done. What remains is a networking layer, and it is deliberately not built:

1. **A transport.** Godot's `MultiplayerAPI`, or anything else. `DamageLog.to_data()` already
   produces something a socket will take.
2. **A priority queue and a bandwidth budget for physics state.** This is the hard part and the one
   with no shortcut — see §6.
3. **Server authority over what counts as a hit** — *the seam is in* (`WorldAuthority`): `_blast`
   asks before it queues, a client's ask is forwarded, and landings shear buildings only on the
   host. Still missing: `_fire` hits on loose pieces, and island landing fractures, which each
   machine still decides from its own physics ([AIPlan](AIPlan.md) P0 step 4).

The three items that used to be here were done because they were nearly free today and expensive to
retrofit — the same argument that got the seeded RNG in before anything needed it.

---

## 6. The honest risks

**Budgets are wall-clock, and wall-clock is not deterministic.** `WORK_BUDGET_MS`, `SPAWNS_PER_TICK`,
`DAMAGE_PER_TICK` and friends decide *when* work happens. They do not change the settled outcome —
the queues drain eventually and the same pieces come away — but they do change the order pieces are
created in, and therefore their chunk ids. Content-derived identity is the answer and is in; it is
worth knowing that this is *why* it is in, because a future refactor that reintroduces id-based
identity would break multiplayer silently and only under load.

**Physics state is large during a collapse and small at rest.** The bandwidth problem is
concentrated in exactly the phase that is already the hardest — hundreds of pieces moving at once.
Teardown's answer is a budget and a priority queue, and accepting that distant debris is wrong on
your screen. That is the right answer here too, and it is worth saying out loud before anyone
assumes the collapse will look identical to two players.

**The floor slabs are 54% of the block count.** Whatever the damage record costs per building, most
of it is flooring (`Status.md`, "Why the floors came away in sheets"). Not a blocker, but the number
to check any per-block wire format against.

---

## Sources

* `Reference/reddawn.md` §10 — the prior-art conclusion, reached twice.
* [The unlikely story of Teardown Multiplayer](https://blog.voxagon.se/2026/03/13/teardown-multiplayer.html)
  — deterministic command stream, the two-stream split, fixed-point destruction logic, join-in-progress
  by replay, and the 2021 naive-sync failure.
* [Teardown Developer Breaks Down Multiplayer and Voxel Destruction Tech](https://80.lv/articles/teardown-developer-breaks-down-multiplayer-and-voxel-destruction-tech)
