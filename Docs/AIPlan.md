# AI — review and implementation plan

**2026-09-23.** [AI.md](AI.md) is the design and records every decision (A1–A20). This file is
two things: a **review** of that design against the code as it stands, and the **order of work**
to build it. Where the review changed the design, AI.md has been corrected to match and the
change is noted here.

Nothing here is built yet.

---

## 1. Review

The design was read end to end against the engine it has to live in. Twenty-three findings; the
ones marked 🔴 would have forced a rewrite if found late.

Severity: 🔴 breaks the design as written · 🟡 needs a change before it is built · 🔵 worth knowing.

### 1.1 🔴 Would have forced a rewrite

| # | Finding | Evidence | Resolution |
|---|---|---|---|
| R1 | **`AIWorld` cannot live in its own GDExtension.** The DDA walks chunk occupancy cell by cell. Two extensions are two DLLs that can only talk through Godot's API — every cell would be a `Variant` call | AI.md §3.1 put it in `gdextension/ai` | **`AIWorld` goes in the brick extension**, as its own source files, reading `BrickWorld`'s grids directly. ONNX Runtime stays in a separate extension — only float arrays cross that boundary, which is exactly what the API is good at |
| R2 | **"Small" wreckage is measured in blocks, and a floor panel is one block.** A detached floor is a single `plate_10x10`, 3.5 m square, so it counts as disposable debris: deleted in seconds, and under A11 something pawns walk through | `island_manager.gd:391` `disposable = count < DEBRIS_MIN_BLOCKS`; floors are one `plate_10x10` per cell (`tower_recipe.gd`) | **Class pieces by physical size**, not block count: a piece is a *landmark* if a crouched person could hide behind it or stand on it. The debris cap, deletion, pawn collision, host sync and the AI all use this one classifier. **Since `a473800`** pieces of 3 blocks or fewer are deleted before they get a body unless within 30 m of *the* player and in view (`TINY_BLOCKS` / `TINY_RANGE`) — so a floor that breaks away out of sight now vanishes outright, and "the player" has to become every player (co-op) |
| R3 | **An undamaged building has no roof, no upper floors and no openings in collision** — four wall slabs and a ground floor. The AI cannot see out of its windows, cannot go in, and a mech on its roof falls into it | `BuildingShell.collision_boxes` | **An encounter pre-materialises the buildings in its zone** at load, inside the budget. *Queries* still never materialise (AI.md §3.2); *presence* may, exactly as a player's does. Outside encounter zones nobody fights, so the shell is enough |
| R4 | **Co-op is decided first (A1) but was milestone seven.** Building nine milestones single-player and then adding authority is the retrofit both reference projects warn about | AI.md §13 | **The authority seam and a loopback client are Phase 0.** Every later gate runs host + client in one process and checks they agree |
| R5 | **Every physics-derived change to structure must be the host's, not only landing fractures.** A falling piece that shears a standing building (`city_scene.gd:2120` records a `SHEAR` from local physics) diverges the same way. And **loads take part in every later solve**: a load the host has but a client does not changes the outcome of the next blast, even if the load itself broke nothing | AI.md §3.10 said loads that break nothing are never sent | **Two rules.** (1) Only the host turns physics into structure — collision shears, landing fractures, island solves — and sends the result as a command. (2) **Persistent loads on blocks with finite headroom are always logged**, add and remove. That is rare, because almost every block has infinite headroom, so it is cheap. Loads on compression-only blocks are never sent because they can never matter |

### 1.2 🟡 Needs a change before it is built

| # | Finding | Resolution |
|---|---|---|
| R6 | **Headroom does not exist for an undamaged or unsolved building** — no solve has ever run on it | Bake headroom **per recipe**, once, like the tactical points; the first real solve on a building overwrites it |
| R7 | **Load does not follow one path — it splits among supports**, so "headroom along the path" is not one number | Use the worst case: the whole added mass on every joint downstream. It is conservative, so a mistake only costs an unnecessary solve, never a wrong break. **Coalesce solves** per chunk per budget window, because a big collapse settles dozens of pieces at once |
| R8 | **A mech (5.6 m) is taller than a storey (2.52 m, `COURSES_PER_FLOOR = 6`).** It cannot stand inside an ordinary storey | "Upper floors" for a mech means **roofs, mech-clearance storeys (14+ courses of clear height — in practice a triple-height storey), and floors opened up by destruction**. The mech map bakes with clearance, so this falls out of the bake |
| R9 | **The fall rule fights the physics.** The plate a mech breaks falls with it and lands first; its own impact fracture double-counts, and the mech then lands on a loose piece where the rule does not apply | The mech **ignores collision with the plates it just broke**, their landing fracture is suppressed, and the rule is applied at each building floor by the mech's own position. The rule decides; physics only carries the pieces |
| R10 | **A skyfall summon onto a building goes through all of it.** 100 m is ~238 bricks of fall — about 93 floors by the rule | **Decided: that is the point.** A summoned mech landing on a building does massive damage; the rule runs until the ground. The landing is damage, so it **activates the building** (materialises it) like any hit |
| R11 | **A dead-block list does not capture a building's state.** Severed joints and `support_broken` flags matter to every later solve; and replaying the log to rebuild would spawn every piece again | **An area save is the `DamageLog` replayed with island spawning switched off, plus the saved pieces.** `DamageLog` becomes always on |
| R12 | **Snapping a client's piece to the host's settle transform can interpenetrate** and make Jolt explode it apart | A settled piece is inert already; the client places it **frozen** at the host's transform and it only wakes on damage |
| R13 | **Interior navigation was undefined.** A tile navmesh baked from shell boxes has no inside | **Per building, per storey navigation regions, baked once per recipe** and placed by transform, joined by stair and door links to the outdoor tiles. Damage rebakes that building's storey from its chunk boxes |
| R14 | **Destruction's budgets were tuned with nothing else in the frame.** The stress pass now holds 58.9–60 fps in every phase (Status.md), with no AI, no enemies and no weapons in it. A 2.5 ms AI budget lands in that same frame, and collapses are where both peak | **One frame-budget arbiter** shared by destruction and AI. During a heavy collapse the AI steps down its ladder; evade and firing never do. Re-run the stress pass with the arena's agents in it as a gate |
| R15 | **Physics interpolation is already on** (`project.godot`, Status.md) — checked, not a gap. But every place the AI *teleports* a body must reset it, as the island spawn path already does: promotion from a swarm row, a client's frozen settle placement (R12), load from a save | `reset_physics_interpolation()` at each of those, and a probe that promotes and places without a one-frame smear |
| R16 | **AI gunfire is destruction load.** Ten agents suppressing is hundreds of `apply_hit`s a minute on the same walls | Tune the gun → brick-damage mapping with AI in the loop. The first arena runs destruction on and measures the damage queue |
| R17 | **Seven navigation representations** (outdoor tiles, building storeys, mech map, flyer height field, swarm flow grid, abstract graph, room graph), each needing destruction to invalidate it | **One `NavChange` event**, and every representation derived from `AIWorld` data. A probe checks each consumer heard each event |

### 1.3 🔵 Worth knowing

| # | Finding |
|---|---|
| R18 | The porting list lacked what the AI needs most: **`SwarmCore` source, the titan scripts, `PlayerRig` and the pilot**, and BoomerBorder's weapon test beds. Added to [the checklist](Reference/boomer-border.md#0-porting-checklist--read-before-copying-anything). LimboAI needs its Windows and Linux binaries |
| R19 | A piece's content hash changes every time it loses a block, so AI data keyed by it re-keys on the piece's change event |
| R20 | The procedural creature extension ships a Linux `.so` only; it needs a Windows build |
| R21 | Deleting small pieces fast trades away part of [BrickFailure §5](BrickFailure.md#5-bricks-separate-they-do-not-vanish) ("bricks can be picked up") for small pieces. Accepted by A11; written down so nobody rediscovers it |
| R22 | `DamageLog` is off by default. Co-op and saving need it always on |
| R23 | With two players, importance and the smart cap are per encounter, not per player — one player standing in the fight should not starve the other's side of smart agents. Importance is the max over players |

---

## 2. How this gets built

This project's rules apply unchanged:

- **Nothing is believed without a probe.** Every phase ends in a gate a headless `tools/*_probe.gd`
  or a `-- --flag` scene pass decides, with numbers.
- **Measure on a quiet machine**, editor closed.
- **Commit at each gate.**
- **The existing 26 probes stay green** at every gate.

Two additions for this work:

- **Every gate from Phase 0 on runs twice: once as host alone, once as host + loopback client**
  (two `BrickWorld`s in one process, the client fed only the host's log). The client must end with
  the same structure and the same large pieces. This is how A1 stays true without a network.
- **An arena scene** (`scenes/arena.tscn`, one node, world built in code) is the AI's test bed: a
  few buildings, a street, spawn points, headless and windowed, `-- --agents=N`.

---

## 3. Phases

Each phase lists what it builds, where, and the gate that ends it. Sizes are relative:
S (days), M (a week or two), L (several weeks).

### P0 — Foundations in the engine · M

Nothing AI yet. These are the engine changes the review found the AI cannot stand on without.

**Progress.** Step 1 done (2026-09-24): `DamageLog` always on with a host `seq`;
`WorldAuthority` in `city_scene` (`_blast` asks, both record sites commit, landings shear only on
the host); `tools/loopback_probe.gd` — 22 checks, host and client agree through a delaying,
reordering wire, and a cheating client is caught. Baseline before it: 28 of 28 probes clean at
`2445311`.

Steps 2–4 done (2026-09-24), and step 4 grew. Sending only physics results was not enough:
solves and detachments run on per-tick budgets, so *when* they happen differs between machines,
and timing changes outcomes. So **every structural operation the host performs is a command** —
`SOLVE`, `TOPPLE`, `DETACH` and four `PIECE_*` kinds alongside the hits — and a client (or a
save being loaded) replays the stream exactly (`StructureReplayer`). Found on the way, each now
handled and written into [Multiplayer.md](Multiplayer.md): room furniture is per machine, so
pieces are named by the seq of the command that made them, not by content hash; a sleeping
piece's block ids are renumbered, so a piece's blocks are named by a cell they fill; a stair step
need not fill its own corner; fixture parts get different archetype numbers per registry.

Two bugs in the dormant tier, found the same way and fixed — **they affect single-player too**:
- **A piece that slept woke with the bricks it had shed standing in it again.** `ChunkRecord`
  asked `get_dead_blocks`, which leaves detached blocks out on purpose, so they were captured and
  restored — twice in the world. `dormant_probe`: 50 shed, 80 standing, the old rule kept 130.
- **A piece's furniture woke up as structure**, bearing load. The record now keeps which blocks
  are decorative.
- **A piece's furniture became structure every time the piece broke.** `split_island` lays the
  new piece's blocks with `place_block`'s default, which is not decorative.
  `IslandManager.carry_furniture` puts the flag back (`dormant_probe`: a bare split keeps 0 of
  25). Fixed in GDScript because the DLL holds another session's uncommitted C++; the real fix
  belongs in `split_island`.
- **Not fixed, noted:** `split_island` does not carry `support_broken` / `bottom_broken` either,
  so joints severed inside a group heal when it becomes a piece. Every machine does the same, so
  it is not a divergence — it is a fidelity bug for the next C++ pass.

- **Step 4 gate:** the city `--shot` pass replays its own log into fresh twin buildings after the
  collapse — 1,698 commands, 0 missed, 4 of 4 buildings and 66 of 66 pieces identical.
- **Step 3:** `IslandManager` announces spawned / settled / changed / slept / woken / removed
  (with a reason); `BuildingRegistry.handed_over`; building changes are `WorldAuthority.committed`.
- **Step 2:** `AreaSnapshot` — the log plus each piece's transform, speed and rest, and sleeping
  pieces as records with archetypes by name. `tools/snapshot_probe.gd`, 29 checks: a mid-fall
  checkpoint and a later one with a piece asleep both load into a fresh world with every piece
  back brick for brick, where it was, moving as it was.

Not done, and why:
- **No save key in the city scene yet.** Loading there also has to rebuild the buildings'
  meshes and bodies and re-queue their solves; the world half is done and probed.
- **Queued work at save time** (a landing waiting to fracture, a building waiting to solve) is not
  carried: the structure is exact, but a pending decision is lost. The scene has to flush or
  re-queue.
- **Furniture riding a piece** is not in the log and does not come back on load.
- A building dematerialised and rematerialised after pieces left it brings those blocks back
  (`get_dead_blocks` skips detached ones) — pre-existing, and a replay would disagree with it.
- Step 5 (debris classed by size, R2) is next.

| Work | Where |
|---|---|
| `DamageLog` always on (R22) | `city_scene.gd` |
| **Authority seam:** every structural mutation goes through one `WorldAuthority`. Single-player is a host with no clients (R4) | new `scripts/world_authority.gd`; `city_scene.gd` `_fire` / `_apply_blast` / `_shear_building` |
| **Host-only physics outcomes** as commands: collision shears, landing fractures, island solves — addressed by content hash + chunk-local cells (R5) | `damage_log.gd` new kinds; `island_manager.gd` `fracture_on_impact`, `solve_island`, `shear_near` |
| **Landmark classifier** by physical size, used by the debris cap and deletion (R2); small pieces deleted fast; pawns off `RUBBLE` | `island_manager.gd`, `layers.gd` |
| **Lifecycle signals:** `piece_settled / slept / woken / changed / removed`, `building_handed_over`, `blocks_changed` | `island_manager.gd`, `building_registry.gd` |
| **Area snapshot v0:** log replay with island spawning off + piece records; checkpoint save and load (R11) | new `scripts/area_snapshot.gd` |
| **Loopback client harness** | new `tools/loopback_probe.gd` |

**Gate:** `loopback_probe` — a scripted collapse on the host; the client ends with identical dead
blocks, severed joints and large-piece content hashes, and its large pieces within tolerance of the
host's settle transforms. `snapshot_probe` — checkpoint mid-scene, load, same structure and pieces.
All 26 probes green.

### P1 — The port · M

Per the [porting checklist](Reference/boomer-border.md#0-porting-checklist--read-before-copying-anything).

| Work | Where |
|---|---|
| Weapons, loot, combat, elements, status, effects, core, the three autoloads; their docs | `scripts/guns/` etc., `Docs/Weapons/` |
| The two RNG fixes; autoload state keyed by owner; damage as a host-confirmed request | `damage_system.gd`, `effect_dispatch.gd`, autoloads |
| **Gun → brick damage mapping**, one place (R16) | new `scripts/combat/structural_damage.gd` |
| `PlayerRig`, pilot, titan scripts (motor, weapon — pitch unclamped, A15), `EntityTime` | `scripts/player/`, `scripts/mech/` |
| Procedural guns and creatures; creature extension built for Windows (R20) | `scripts/guns/`, `scripts/creatures/`, `gdextension/creature/` |
| `SwarmCore` source into the build (R18) | `gdextension/swarm/` |
| LimboAI 1.7 addon, Windows + Linux | `addons/limboai/` |
| A real player controller on the `Pawn` component (D7), replacing the debug walker for play | `scripts/pawn.gd`, `scripts/player_controller.gd` |

**Gate:** BoomerBorder's weapon and loot suites ported as probes and green; a player walks the city
and shoots bricks with a generated gun, and the damage goes through `WorldAuthority`; a greybox
brick mech is piloted with the ported motor. Loopback agrees.

### P2 — `AIWorld` core · M

In the brick extension (R1): `ai_world.{h,cpp}`, `ai_scheduler.{h,cpp}`.

- Broad phase over every chunk's world AABB (buildings, islands, dormant records).
- **Grid DDA** across chunks at any rotation; **cover life** (bricks between × material ÷ threat
  damage rate).
- Danger volumes (falling pieces), smoke volumes.
- **Scheduler and the frame-budget arbiter** shared with destruction (R14).
- An AI overlay beside `F1`: ms per subsystem, queue depths, jobs deferred.

**Gate:** `ai_world_probe` — DDA through a tilted slab, through a hole, across two chunks, against
a hand count; 10,000 cover queries inside budget; scheduler holds its budget under a synthetic
flood; arbiter steps AI down during a `--stress` collapse and back up after.

### P3 — Navigation · L

| Work | Where |
|---|---|
| Outdoor navmesh per terrain tile, buildings as obstacles, async budgeted rebake from boxes | `scripts/ai/nav_tiles.gd` |
| **Per-recipe storey regions** placed by transform; stair and door links (R13) | `scripts/ai/building_nav.gd`; bake from `TowerRecipe.plan` |
| Room graph from `TowerRecipe.plan` (shared with interiors, Next.md §2.3) | `scripts/room_graph.gd` |
| Abstract graph (sectors, openings, rooms) with cached routes | `scripts/ai/route_graph.gd` |
| Path request queue with importance priority | `AIWorld` scheduler |
| **Encounter zones pre-materialise their buildings** (R3) | `scripts/ai/encounter.gd` |
| `NavChange` event and consumer registry (R17) | `AIWorld` |

**Gate:** `nav_probe` — a path from street into a third-floor room and out through a blown hole; a
wall shot out makes a new route within the rebake budget; **zero materialisations from queries**;
path queue holds its budget with 50 requesters.

### P4 — One soldier · M

`Pawn` + `Intents` + BT brain; perception (budgeted rays + smoke), faction knowledge; one infantry
tree in LimboAI (Engage, TakeCover, peek-and-fire, Search, Evade); aim model; tactical points baked
per recipe (cover with arcs, corners, openings) — just enough for one soldier.

**Gate:** `soldier_probe` in the arena, headless — engages, takes cover against the threat's side,
peeks, loses the player and searches, re-acquires; never shoots through a wall that is not there;
inside the AI budget. Windowed `--shot` of the same.

**This is the first vertical slice:** a soldier fighting in the destructible city, with a
checkpoint save and a loopback client that agrees.

### P5 — The city fights back · L

Event invalidation of tactical points; **wreck summaries**; cover life in decisions; nav links from
holes; destruction-as-verb actions (shoot through, take cover away, make a door, make cover);
**headroom baked per recipe and written by solves (R6, R7)**; **settled-wreckage loads** with solve
coalescing and logged finite-headroom loads (R5).

**Gate:** shoot a soldier's cover away and it relocates before the cover runs out; after a collapse
soldiers hide behind and walk over the wreck; nobody stands under a falling piece; a building
toppled across another loads it — a hanging section under it gives way, a floor over columns does
not — and the loopback client agrees on both.

### P6 — Squads, tactics, aggro · L

Order / Assignment / Report with ids; squad `BTPlayer`s with blackboard scopes; plays (advance from
cover, suppress and push, bounding, flank, flush, search in pairs, fall back, bait); masked moves;
stacking and clearing with the reply barrier; slicing corners; mouse-holing; attack tokens; morale;
**subtitled callouts with talking markers** (enemies by sight, friendlies through walls); **the
aggro table and meter**.

**Gate:** a scripted room-clearing — four soldiers stack, prep, enter crisscross, clear, report —
completes in the arena; a squad advances only while masked; the aggro meter moves with damage and
holds with hysteresis; callout markers appear only when heard and seen.

### P7 — Mechs and weight · L

Brick-built mech on the ported motor, in studs; mech map with clearance (R8) and breach links;
the enemy mech tree; the player's mech on the one-button command; **pawn weight** on the headroom
from P5; **the fall rule** with the plate handling of R9.

**Gate:** a mech from 6 bricks goes through 1 floor, from 12 through 3; a person on a hanging
section drops it, on a floor over columns does not; an enemy mech breaches a building to reach
infantry; the player's mech follows, holds, and attacks an aimed area. Loopback agrees on every
break.

### P8 — Many · L

Tiers as HSM states; importance budget (max over players, R23); shared squad paths and flow fields;
`SwarmCore` rows with promotion; flyers on the height field; animals and packs on procedural
creatures.

**Gate:** 10 smart + 40 directed + 300 swarm in the arena inside the AI budget, with the budget
arbiter stepping down cleanly during a collapse; the `--stress` pass re-run with those agents in it
(R14).

### P9 — The commander · M

Per-encounter commander with a tree; sector grid; roster and doctrine from the **threat profile**;
off-screen fights by points; the friendly side; **the character save** (character, mech, guns,
missions, threat profile).

**Gate:** two scripted player styles (destructive vs not; pilot kills vs mech kills) produce
measurably different rosters and doctrine in the next encounter, within the clamps.

### P10 — Real co-op and save-anywhere · L

A transport on the loopback seam; clients receive bodies; the falling-piece transform stream;
settled-piece sync (frozen placement, R12). Save-anywhere: flush queues with a time cap, in-flight
objects, AI state.

**Gate:** two machines through a full encounter with a collapse agree on every large piece; a save
taken mid-collapse loads with the same pieces moving the same way.

### P11 — ONNX · L

The ONNX Runtime extension (R1), versioned observation and action specs, `BTRunPolicy` with its
scripted twin; a headless training arena with grid-only destruction; the first model — mech combat
micro — imitation first.

**Gate:** the model loads, runs batched inside 0.2 ms, falls back loudly on a mismatched spec, and
beats its scripted twin in the arena without breaking the designer clamps.

### Order and overlap

```
P0 ─► P1 ─► P2 ─► P3 ─► P4 ═══ first vertical slice
                   │      └─► P5 ─► P6 ─► P7 ─► P8 ─► P9 ─► P10
                   └──────────────────────────────────────────► P11 (training arena can start after P4)
```

P1's weapon port and P2's `AIWorld` touch different code and can run side by side.

---

## 4. Decisions

1. **Skyfall onto buildings (R10) — decided 2026-09-23.** No cap: a summoned mech that lands on a
   building does massive damage, floor after floor to the ground. The landing counts as damage, so
   an undamaged building it lands on is activated (materialised) first, then broken.
2. **Undamaged buildings in fights (R3) — partly decided.** Anything that damages or lands on a
   building activates it (decided). For AI to fight *inside* buildings nobody has touched yet, the
   default is that an encounter activates the buildings in its zone at load; the alternative, a
   richer shell with a roof and openings, stays open until an encounter is measured.

---

## 5. Risks

| Risk | Watch for | Fallback |
|---|---|---|
| The frame is full during collapses | AI overlay shows the arbiter pinned at the bottom rung for seconds | Fewer smart agents during a collapse; directed agents freeze in place |
| Host-only structure makes clients look late | a piece lands, the wall it hits breaks ~100 ms later | Predict cosmetic dust locally; keep structure authoritative |
| Save-anywhere mid-collapse | queue flush takes too long; loaded pieces pop | Checkpoints (A17 allows it) |
| LimboAI on Godot 4.6 / Linux | editor or runtime crashes | Red Dawn ran 1.7 on 4.6; if it breaks, the trees are small enough to run on a thin BT runtime of our own |
| ONNX Runtime on Steam Deck | no working Linux build or too large | A hand-written forward pass for small MLPs |
| AI gunfire floods the damage queue | damage queue depth in the overlay during a firefight | Lower structural damage per round for automatic weapons, in the one mapping |
