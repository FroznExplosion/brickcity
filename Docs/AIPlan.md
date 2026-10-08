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
| R2 | **"Small" wreckage is measured in blocks, and a floor panel is one block.** A detached floor is a single `plate_10x10`, 3.5 m square, so it counts as disposable debris: deleted in seconds, and under A11 something pawns walk through | `island_manager.gd:391` `disposable = count < DEBRIS_MIN_BLOCKS`; floors are one `plate_10x10` per cell (`tower_recipe.gd`) | **Class pieces by physical size**, not block count: a piece is a *landmark* if a crouched person could hide behind it or stand on it. The debris cap, deletion, pawn collision, host sync and the AI all use this one classifier. **Since `a473800`** pieces of 3 blocks or fewer are deleted before they get a body unless within 30 m of *the* player and in view (`TINY_BLOCKS` / `TINY_RANGE`) — so a floor that breaks away out of sight now vanishes outright, and "the player" has to become every player (co-op). **Revised 2026-09-25:** a piece of 8 bricks or fewer is small however big it is -- a lone floor panel included -- and small pieces live as long as the local camera can see them, shrinking away rather than popping (AI.md A11) |
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
- **A piece's furniture became structure every time the piece broke, and its severed joints
  healed.** `split_island` laid each block fresh. Fixed in C++ (2026-09-24): it now carries the
  decorative flag, `support_broken`, `bottom_broken` and `hp`. `dormant_probe` checks all of it,
  and that a sleeping piece's record keeps severed joints (new `get_block_joints` /
  `set_block_joints`) and its grid origin.

- **Step 4 gate:** the city `--shot` pass replays its own log into fresh twin buildings after the
  collapse — 1,698 commands, 0 missed, 4 of 4 buildings and 66 of 66 pieces identical.
- **Step 3:** `IslandManager` announces spawned / settled / changed / slept / woken / removed
  (with a reason); `BuildingRegistry.handed_over`; building changes are `WorldAuthority.committed`.
- **Step 2:** `AreaSnapshot` — the log plus each piece's transform, speed and rest, and sleeping
  pieces as records with archetypes by name. `tools/snapshot_probe.gd`, 29 checks: a mid-fall
  checkpoint and a later one with a piece asleep both load into a fresh world with every piece
  back brick for brick, where it was, moving as it was.

**Step 5 done, and the three follow-ups (2026-09-24):**
- **Debris by size (R2).** `IslandManager.is_landmark_size`: a piece at least 2.0 m long or 0.9 m³
  of box is a *landmark* — never deleted, solid to people, the same on every machine. Anything
  smaller is presentation: deleted where it came loose when unseen or beyond 30 m, otherwise swept
  0.3 s after it comes to rest (2.5 s backstop), and `Layers.PAWN_MASK` no longer includes
  `RUBBLE`. Dormancy and the debris cap ask `interest_points()` (every player, later AI agents)
  instead of the camera; the cap sleeps landmarks farthest-first and never one within 8 m of
  anybody. `tools/debris_probe.gd`, 20 checks.
- **Piece commands are in grid space**, not chunk-local: a piece's local frame starts at the
  corner of the group it was cut as, which on the host included furniture a replay never has.
- **Queued work survives a save.** `AreaSnapshot` v2 carries the island manager's pending
  re-solves and landings (`pending_state` / `restore_pending`) and hands the scene's own queue
  back. `snapshot_probe`: saved with a re-solve queued, the host and the loaded copy each finish
  into the same 13 pieces with the same ids.
- **Furniture riding a piece comes back on load**, by absolute cell and part name.
- **Found on the way:** commands for furniture-only pieces (which exist in no replay) were being
  recorded — twelve orphans once the probe's tower had real furniture. Now not recorded.

Measured on the worktree build (HEAD + these changes + the rebuilt DLL): 31 of 31 probes clean;
city `--shot` log replay exact in 5 of 5 runs (up to 154 of 154 pieces, 2,074 commands); more
pieces stay alive (83–154 against 56–73, the floor panels and clumps that used to be deleted) with
frame time unchanged at 16.6 ms; `--stress` 200 mean 18.4 ms against 18.2.

**P0 complete (2026-09-24).** The last four pieces:
- **Where a landmark comes to rest is a command** (`PIECE_REST`: the chunk transform, once per
  rest, host only). Every machine — and a late joiner or a replay — has the wreckage the AI hides
  behind in the same place. The city `--shot` replay check and `loopback_probe` both compare it.
- **`loopback_probe` has a pieces phase:** real physics on the host, a client with no bodies
  applying the stream through a reordering wire, chunk ids deliberately different. Detach, topple,
  shear and rest all arrive; every piece identical, every landmark at rest where the host's is.
- **F5 saves the city, F9 loads it** (`user://checkpoint.area`). Load reloads the scene and
  replays the save into the recipes; damaged buildings get their bake and bodies *after* the
  replay, so they start from the damaged building. Gate: city `-- --checkpoint` saves 45 frames
  into a collapse (1,718 commands, 92 pieces, 73 of them still falling), reloads, and checks every
  damaged building and every piece brick for brick, where it was, moving as it was, with a node to
  draw into — then lets it run 4 s and replays the whole log against it: 8 of 8.
- **A checkpoint carries the builds placed into the city (2026-10-08).** A load rebuilds the
  scene, which is the city's own buildings and nothing else: a build placed with P or `--build`
  was gone after F9, and every command naming it went nowhere. The save's scene data now lists
  them (`_placed`: id, recipe, transform, whether a pad was cut for it); `_restore_checkpoint`
  registers them first, in order, so each has the id the log knows it by, and cuts its pad again.
  `--build` is not placed a second time after a load.
- **A blast is logged whether or not it killed.** It was committed only when a brick died — every
  blast on PLA, and not on anything tougher: a stone cottage takes the first 1 m blast as wear and
  loses bricks to the second. A load, a replay or a client told only about the second had 76
  bricks standing where the host had 69. Found by putting a placed, twice-hit cottage in the
  `--checkpoint` gate; `_apply_blast` now commits every blast it applies, as it always did a chip.
  The gate's replay check gives a one-frame placed build a twin too. `--checkpoint`: 9 of 9.
- **A rebuilt building no longer regrows what left it as pieces.** The registry records detached
  blocks (`get_detached_blocks`, new) alongside the damage. `dormant_probe` checks it.
- **Found on the way:** a piece woken from sleep or loaded from a save had no mesh node — solid
  but invisible (`IslandManager.adopt` only made one when a building's node was handed over). And
  a loaded piece woke the settled pieces around it.

Measured on the worktree build (origin/main 984fce0 + these changes + the rebuilt DLL): 31 of 31
probes clean; `--checkpoint` 8 of 8; `--shot` log replay exact twice (151 and 94 pieces); `--stress`
200 clean (96 buildings trimmed and rebuilt). Frame times not compared: other Godot processes were
running. `N RID allocations of type 'P10JoltBody3D' were leaked at exit` shows on every city pass,
before these changes too.

Still open:
- A player build placed with P is not in a save: the load rebuilds the city from its recipes.
- The first one or two scene passes after an `--import` run 50–80 ms mean with the same code that
  runs 16.6 ms afterwards. Suspected shader compilation; not established.

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

**Progress.**
- **Stage 1 done (8e7d63e, 2026-09-24): the code and docs are in.** Guns, loot, combat, elements,
  status, effects, core, `ElementalTarget`/`FreezeVisual`, the three autoloads, the element FX;
  specs in [Weapons/](Weapons/README.md). The two RNG fixes; `ElementalManager` stripped to FX and
  `ElementalTarget`'s private health removed; no third-party assets. `test/core_test.tscn` and
  `test/loot_range_test.tscn -- --probe` pass here as they do in BoomerBorder.
- **Stage 2 done (2026-09-24): guns hurt bricks, through the authority.**
  - **Bullets wear, they do not delete.** Every brick has 255 hp (`BrickWorld.chip_hit`, new);
    a round takes hp off the brick it struck, and it dies at 0. Two new log kinds, `CHIP` and
    `PIECE_CHIP`, recorded even when nothing died, because hp is state. Wear survives everything a
    brick survives: the registry keeps it across dematerialise (`get_worn_blocks` /
    `set_worn_blocks`), `ChunkRecord` across sleep and saves, `split_island` across breaking.
  - **`StructuralDamage`** is the one mapping (R16). By class, never by tier, rarity or crit — a
    wall is the same wall at every tier: a pistol breaks a brick in 3 hits, SMG 7, rifle 4, LMG 5,
    DMR 2, sniper/shotgun/revolver 1; shells and sniper rounds wear a small ball, an explosive
    gun 0.5 m. Ordnance is a real blast at 0.35 of its enemy radius, capped at 2 m.
  - **`GunController`** fires a generated gun for any owner — player, mech, AI: rate, magazine,
    reload, spread and crits from an injected RNG. Something with a `HealthPool` goes to
    `DamageSystem`; anything else is structure and goes to the owner's callback, which in the city
    is `chip()` / `_blast()` through `WorldAuthority`. City keys: `1` gun, `2` debug blast, `T`
    next class, `R` reload.
  - Gates: `tools/chip_probe.gd` 21 checks (wear, rebuild, sleep, save, split, replay, the
    mapping); city `-- --gun` 6 checks (one round one CHIP; the third pistol round breaks the brick;
    a living target takes the bullet and the wall nothing; a held SMG fires at its rate, one
    command a round; a rocket blasts; the log replays).
  - Found on the way: `StatusManager` named the `StatusTicker` autoload directly, which fails to
    compile under `--script` — and every probe that loads the city scene now reaches it through
    the gun. Looked up by path.
- **Stage 3 done (2026-09-25): a player on the `Pawn` component (D7).**
  - **`PawnIntents`** is the brain contract for characters, BoomerBorder's one idea: a brain
    fills it, the motor reads it and never knows which brain it has — move (world direction),
    look, run, crouch, fire, and edge-triggered jump and reload.
  - **`Pawn`** is a component under a `CharacterBody3D`, never a base class. Its motor is the
    debug walker's rules (walk/run/crouch speeds in bricks per second, auto-crouch along the
    motion, step over one course, jump one course) moved onto the physics tick, so the same
    intents make the same move for every brain and on every machine. It carries a team, a
    `HealthPool` where a bullet finds it, and a `GunController` it feeds `fire`/`reload`.
  - **`PlayerController`** turns keys and mouse into intents and puts the camera on the pawn's
    interpolated eye; look is whatever the camera points at. In the city, **`V`** stands a
    player pawn where the camera is and hands it the gun; `V` again leaves. The debug walker
    (SPACE SPACE) is untouched — Terrain and water have swimming in progress in it.
  - Gates: `tools/pawn_probe.gd` 7 (scripted intents, as an AI will send them: walks, steps a
    kerb, runs, crouches, strafes at crouch speed, jumps and lands; **two pawns given the same
    intents walk the same path to 0.00000 m over 150 ticks**); city `-- --play` 9 (lands, eye
    at `EYE_HEIGHT`, kerb yes and wall no, ducks a beam from a brick floor, holding the mouse
    fires the pawn's gun into a wall through the authority and never into itself, V leaves).
  - Found: the debug walker puts the eye a plate under the crown (1.54 m) where its own
    `EYE_HEIGHT` says 1.42 m, and `--walk`'s beam (1.40 m underside) predates the figure being
    resized — 3 of its checks fail on main. The pawn uses the head's middle and a beam at
    1.75 m. And `--shot`'s "settled wreckage is still breakable" fails on current main without
    any of this (a blast hits 3 settled pieces and removes nothing) — from another area's merge.
- **Stage 4 done (2026-09-25): a greybox mech, piloted with the ported motor.**
  - BoomerBorder's `TitanMotor` and `TitanIntents` are copied unchanged (`scripts/mech/`) apart
    from the step height, restated as three brick courses. `titan.gd` (3,460 lines of scene,
    cockpit, exits and summon built around Synty meshes), `TitanWeapon` and the AI brain stayed
    behind: the arm is a `GunController` like every other gun, and the brain belongs to the AI
    phases on LimboAI.
  - **`Mech`** is a component like `Pawn`: the motor, a body sized on the grid (16 courses tall,
    5 studs of radius, cockpit 10 courses up — BoomerBorder's 6.9 × 1.7 m titan and its 4.2 m
    torso, which lands on a course exactly), a 2,500 hp `HealthPool`, a greybox, and **the arm:
    yaw ±55° of the torso, pitch free to ±89° (A15)**, converging on where the crosshair lands.
  - **`MechPilot`** is the pilot brain: WASD relative to the torso, look from the camera, SHIFT
    sprint, Q dash, LMB fire, R reload; the camera rides the interpolated cockpit. In the city
    **`M`** boards (spawning a mech ahead of the camera if there is none) and leaves.
  - Gate: city `-- --mech` 13 — stands, cockpit at 4.2 m, walks at 9 m/s, sprints faster, stops,
    dashes on a charge, the torso lags the look then arrives and the legs follow, steps a metre of
    cover and not a storey, the arm pitches past 40° and its rounds wear a wall high above the
    cockpit through the authority, M leaves it parked, and the log replays.
- **Stage 5 done (2026-09-25): LimboAI v1.7.0** (`addons/limboai`, MIT), from Red Dawn's copy:
  Windows and Linux x86_64 only, 19 MB, the descriptor trimmed to match. Used as AI.md says:
  **a behaviour tree is a brain that fills `PawnIntents`**, never a second way to move a body.
  `BTMoveTo` (`scripts/ai/`) is the first task. Gate: `tools/limbo_probe.gd` 5 — the extension
  loads, a two-task tree walks a Pawn to one point and then runs to another by the Pawn's own
  motor, reports success and leaves the intents at rest.
- **Stage 6 done (2026-09-25): SwarmCore is in the build** — compiled into the brick extension
  (`gdextension/brick/src/swarm/`), not as an extension of its own: one godot-cpp, one DLL, and
  horde code can read the brick grid directly, which a second extension could not (R1's reason
  for AIWorld). It built against brick's newer godot-cpp unchanged. **Its seven global rolls**
  (lane lateral offsets, lane picks, spawn scatter, point-damage picks) **now draw from its own
  seeded splitmix64** (`SwarmCore.set_seed`), per D9. `SwarmPileMesh` and `SwarmAuthor` came with
  it; `SwarmActors` (built around a third-party character model), `SwarmEffects` and
  `SwarmPromoter` (built around BoomerBorder's test gun and ghosts) wait for P8 and our own brick
  figure. Gate: `tools/swarm_probe.gd` 8 — loads, a 400-agent ring spawns and closes on the goal,
  every live agent has a tier, a bullet finds one, a grenade kills a clump, deaths come back for
  effects, worst tick 0.71 ms. Note for P8: the horde ticks in `_process`, at render rate, which
  co-op will have to change.
- **Stage 7 done (2026-09-25): the procedural creatures, and `MeshForge` built for Windows.**
  The creature system (`scripts/creatures/`) and its native mesh builder, compiled into the brick
  extension (`src/creature/`) since it shipped as a Linux `.so` only; docs and reference code in
  [Creatures/](Creatures/README.md). `tools/creature_probe.gd` (BoomerBorder's smoke test) passes
  whole: six seeds build valid skinned meshes, walk, step, IK and LOD2 gait, and the native path
  matches GDScript to the vertex at 2.1× the speed. The gait ⇄ physics merge had never been run;
  its first run here (`tools/creature_merge_draft.gd`, not a gate) is 6 of 13 — it builds,
  walks and leaks nothing, but tracks at 5.7 cm against 5 and cannot stumble or recover yet.
- **Stage 8 done (2026-09-25): loopback agrees with a player's gun in it.** `loopback_probe`'s
  fight now has pistol rounds from both machines — CHIPs, 30 of them, the client's as requests
  the host answers — and checks the wear arrives intact: same bricks worn by the same amount on
  the client and for a late joiner replaying the log. (Found on the way: a stray carriage return
  from an earlier edit sat in one of its comments.)

**P1 complete (2026-09-25).** Every line of the gate holds: BoomerBorder's suites green here; a
player walks the city and wears bricks with a generated gun through `WorldAuthority`; a greybox
mech is piloted with the ported motor; loopback agrees. Carried forward: the city gates count
frames, not seconds (one run with the editor open failed `--play` and `--mech` on timing and
passed clean on the rerun); `SwarmActors` and the horde's promotion wait for our own brick figure
(P8); the creature physics merge is 6 of 13 on its first run.

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

**Done (2026-09-25).**
- **`AIWorld`** (`src/ai/ai_world.*`, in the brick extension with `friend` access to the chunk
  grids — R1). Broad phase: a 2D hash of every live chunk's world AABB, walked along the segment
  by a 2D DDA, so a long sight line costs the cells it crosses. Narrow phase: into the chunk's own
  frame, into cell units, and a 3D integer DDA through its occupancy — counting distinct live
  structural blocks (furniture is not cover), metres of solid, the first brick and its chunk.
  **Proxies** stand in for bricks nobody has built: the city registers every pristine building's
  five shell boxes (one brick per stud of travel) and drops them when the bricks arrive — an AI
  query never materialises a building (AI.md 3.2). **Smoke** as spheres blocks sight but is not
  cover; **danger** boxes are every big piece still falling, refreshed each tick.
- **Cover is seconds** (AI.md 3.7): `cover_seconds(threat, target, hp_per_hit, rate)` sums, brick by
  brick, the rounds `BrickWorld.chip_hit` will actually need — each brick's own hp and material,
  the same integer wear rule — so a worn wall is shorter cover and a steel one longer. Batched for
  a squad's search.
- **`AIScheduler`** (`src/ai/ai_scheduler.*`): jobs by subsystem and priority, best-first inside
  the budget, the budget checked before each job so the overrun is at most one; waiting jobs age so
  nothing starves; `must_run` (evade, firing) runs whatever the budget. **The arbiter** is fed this
  script's own tick — destruction's spend — and steps the AI down a five-level ladder (budget
  2.5 → 0.75 ms; `rate_scale` thins directed trees, then rays, then smart agents, then the
  commander, AI.md 10.3 rule 7) on a streak of heavy ticks, and back up on quiet ones. Heavy and
  quiet are **relative to the city's own normal**, which falls fast and rises slowly: a
  200-building city ticks at several ms doing nothing, and single periodic spikes are not a
  collapse. The city syncs and runs it every tick (`--no-ai` turns it off to measure).
- **F4** shows the AI overlay: level, budget, sync and run ms, the city's normal, indexed chunks,
  proxies, danger, smoke, queries and their mean cost, and per subsystem ms / ran / deferred.
- Gates: **`tools/ai_world_probe.gd` 35** — hand counts through a wall (3 bricks, 1.05 m), a slab
  tilted 30° (1 brick along its normal, 10 along its plane), two chunks (3 + 2), a hole (0) and
  beside it (3); **200 random rays through four chunks at random rotations agree with a
  millimetre brute force, 200 of 200**; cover life to the round, worn and not, pistol and sniper;
  proxies, smoke, danger; **10,000 cover queries through six materialised towers in 6.1 ms —
  0.44 µs each in C++, 0.61 with the call**; a 2,000-job flood served 2.5 ms a frame with no frame
  more than a job over; importance first; nothing starves; evade always; the ladder down under a
  collapse, held, back up, and a sustained load taken as the new normal. **`--stress 200`**: level
  0 under fire, 4 while the queue drains and the city collapses, back to 0 in the trimmed phase;
  the AI's tick is 0.25 ms. `--gun` checks the overlay.
- Found: at rest the 200-building city spends ~20 ms on one physics tick in thirty (periodic city
  work, not destruction), and its settled and trimmed phases now run 19–21 ms a frame with the AI
  off too, against 16.7 this morning — a regression from another area's merge today, not this.

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

**Done (2026-09-26), grid-native rather than a navmesh.** The table above planned Recast tiles and
per-recipe storey regions. What was built reads navigation **straight from the bricks**, for the
same reason AIWorld lives in the brick extension (R1):
- **`AINav`** (`src/ai/ai_nav.*`). A *column* is one stud square; a *floor* in it is a plate a body
  stands on — solid below, air above — read in one pass per chunk down its own Y axis
  (`AIWorld.column_solid`), over every chunk at any rotation and every proxy. A node is the
  **2×2 studs** a 0.525 m figure needs, allowed to overhang lower ground (how a drop starts) or the
  foot of a step it is about to climb. Eight neighbours; up one course (`STEP_UP` 3 plates, the
  Pawn's own step), down three (`MAX_DROP` 9); stand in 12 plates of air, crouch in 9 at double
  cost. A* with the octile heuristic (exact on this grid), resumable, served from a queue
  best-first inside a budget.
- **Destruction needs no rebake.** A hole a body fits through is walkable the moment its columns
  are re-read. The city forgets columns (and memoised node fits, per column) under every
  committed hit's ball, a building's box for a solve, topple or cut-out, the box of a piece that
  settles or goes, and a building that turns shell ⇄ bricks — and `nav_changed(box)` goes out for
  path followers (**NavChange, R17**).
- **Queries never materialise** (AI.md 3.2): a pristine building is its shell's proxy boxes — a wall
  — so a path round it costs nothing. **`Encounter`** (`scripts/ai/encounter.gd`, **R3**) is the one
  sanctioned way to bricks: its zone's buildings are promoted two a tick and pinned against the trim.
- **Budget:** the city queues `AINav.service` as a NAV job on the scheduler at 0.5 ms a tick (AI.md
  10.1), scaled by the arbiter's ladder. The caches are reserved up front: a rehash of a 60k-entry
  map was a 6.6 ms search step, now 281 µs at worst.
- Gates: **`tools/nav_probe.gd` 21** — open ground straight; a one-stud door lets nobody in, three
  do; nobody under 8 plates, crouching under 10, standing under 13; up one course, not two without
  a step, two with one; off three courses, not four; a room entered round by its door, then
  through a hole shot in its back wall 79 µs after the change was announced; a proxy walked round;
  50 requesters answered in 27 frames, 0.5 ms a frame, the important first. **City `-- --nav` 7** —
  an encounter brings its buildings in; there is floor two storeys up; **a tower is sealed at
  street level**; breached, the path runs from the street through the hole and up the stairs to the
  room; a wall blown out on the far side is the new way out; 20 paths across the city materialise
  nothing; 50 requesters inside the budget.
- **Found: towers have no street doors,** and their ground-floor sills are four plates up — more
  than a course, which nobody steps and nobody jumps. The way into a tower is made (AI.md 3.8,
  *make a door*), for the AI and for the player alike. A level wanting enterable buildings needs
  a recipe with doors.
- **Not built, and why:** per-recipe storey regions and stair/door links (the grid has them already);
  the room graph and the abstract route graph — a path across the city is about 1 ms of A* here,
  so the hierarchy waits for a measurement that needs it (P5/P6, many agents, long routes); flyer
  and mech maps belong to P7. Not yet handled: walking ON settled wreckage at an angle (it is an
  obstacle and, where flat enough, a floor, but untested), and releasing finished requests is the
  caller's job (`release(id)`).

### P4 — One soldier · M

`Pawn` + `Intents` + BT brain; perception (budgeted rays + smoke), faction knowledge; one infantry
tree in LimboAI (Engage, TakeCover, peek-and-fire, Search, Evade); aim model; tactical points baked
per recipe (cover with arcs, corners, openings) — just enough for one soldier.

**Gate:** `soldier_probe` in the arena, headless — engages, takes cover against the threat's side,
peeks, loses the player and searches, re-acquires; never shoots through a wall that is not there;
inside the AI budget. Windowed `--shot` of the same.

**This is the first vertical slice:** a soldier fighting in the destructible city, with a
checkpoint save and a loopback client that agrees.

**Done (2026-09-26).**
- **`Soldier`** (`scripts/ai/soldier.gd`), a component under a Pawn's body like Pawn itself: a
  rifle on a `GunController` aimed down the pawn's new **eye** node (turned to the intents' look
  every tick), a LimboAI brain, and the services every task needs. **Sensing** at 5 Hz is a
  PERCEPTION job on the scheduler: range, a 70° cone (or anyone within 4 m), a physics ray, then
  AIWorld's **smoke**, which physics cannot see — into the side's **`FactionKnowledge`**
  (`scripts/ai/faction_knowledge.gd`: contacts seen, heard, searched; shared inside a side, never
  across). **Noise** — every round fired — is heard within 40 m by the other side, as a place, not a
  who. **Thinking** at 10 Hz is a TREES job. **Aim and fire** run every tick and are never
  deferred: **`AimModel`** (`scripts/ai/aim_model.gd`) puts the error where AI.md 5.1 says — a
  0.35 s reaction, a cone from 7° tightening to 1.2° over 1.6 s of tracking — and a round goes only
  if AIWorld says the line to the target is clear *this tick*, since sensing is 5 Hz. **Moving**
  follows AINav paths requested through the queue, re-requested on `nav_changed` or when stuck.
- **The tree** (`scripts/ai/soldier_tree.gd`, tasks in `scripts/ai/bt/`), built in code, thin
  tasks writing `PawnIntents`: a dynamic selector of Evade (a falling piece's danger box) → Engage
  (a contact seen or heard in the last 2.5 s: FindCover → PeekAndFire, else FireInOpen) → Search (a
  contact up to 25 s old and not yet searched: go where it was, look round) → Idle. Seen again while
  searching, it is fighting again the same tick.
- **Cover is found, not baked** (the plan said tactical points baked per recipe). AIWorld already
  answers what an arc stands for — whether *these* bricks hide a body from *that* eye, and for how
  long — against the actual threat, in a city where a baked arc is wrong the moment the wall is
  shot. **`AINav.find_cover`** (C++; the GDScript first version was 2.9 ms a search) rings the
  soldier with candidates, rejects open ground with one DDA, and rates the rest: LOW cover hides a
  crouched body (peek by standing), HIGH a standing one (peek by stepping to its side), scored by
  cover seconds, distance, range and how close the body is to what covers it — a wall's shadow six
  metres back is cover on paper only. 150–180 µs a search, 1.4 ms at worst in the shadow of a big
  block on first reading its columns. Corners and openings wait for P6's stack-and-clear.
- Gates: **`tools/soldier_probe.gd` 8** in an arena — first round at 1.1–2.0 s; **hidden behind
  the wall on the side away from the player on every one of 151–216 hiding ticks**; five peeks,
  firing only while peeking; the player gone behind a block, searched for to within 0.5–2.9 m of
  the last sighting; back and firing, re-acquired in 0.5–1.3 s; blinded by smoke, no rounds into
  it; **0 of 35–72 rounds with bricks in the line**; AI 0.02–0.14 ms a tick on average, **worst
  1.45–1.6 ms** (judged headless; `-- --shot` runs it windowed and writes `soldier_cover.png` and
  `soldier.png`). **City `-- --soldier` 3** — the vertical slice: a soldier in a street against the
  player's pawn, firing, its misses wearing the buildings as CHIPs through the authority, never
  through a wall, and the log replaying into the same city. `K` puts a soldier 20 m ahead of the
  camera.
- **Not yet:** a soldier's own state in a checkpoint and on a loopback client (its effect on the
  city is in both — the CHIPs — but the pawn itself is P10's save-anywhere and replication);
  grenades; interiors (towers are sealed, P3) and stack-and-clear (P6).

### P5 — The city fights back · L

Event invalidation of tactical points; **wreck summaries**; cover life in decisions; nav links from
holes; destruction-as-verb actions (shoot through, take cover away, make a door, make cover);
**headroom baked per recipe and written by solves (R6, R7)**; **settled-wreckage loads** with solve
coalescing and logged finite-headroom loads (R5).

**Gate:** shoot a soldier's cover away and it relocates before the cover runs out; after a collapse
soldiers hide behind and walk over the wreck; nobody stands under a falling piece; a building
toppled across another loads it — a hanging section under it gives way, a floor over columns does
not — and the loopback client agrees on both.

**Done (2026-09-26).**
- **Wreckage weighs on buildings** (AI.md 3.10, R5). `BrickWorld.set_load / clear_load`: weight
  resting on a chunk from outside it, per owner (the piece), in the solver's integer mass units,
  added to the blocks' own weight by every `solve_stress` — so the existing tension rule decides:
  weight hanging from a joint can pull it apart, weight in compression cannot. Two new commands,
  **`LOAD`** (mass on each block named by absolute cell, under the piece's id, replacing what that
  piece had on the building) and **`UNLOAD`**, applied by `DamageLog.apply_entry` and the
  replayer. The city, as host, commits them: when a large piece settles it finds every standing
  brick just under one of its own, shares the piece's mass across them per building, and queues
  the building's solve; a piece that loses bricks is re-weighed once a tick (and commits nothing
  if nothing changed); one that is woken, slept, removed or moved takes its load with it.
  **All loads are logged**, not only those on finite-headroom blocks: settling large pieces are a
  handful per collapse, so the headroom filter (and headroom baked per recipe, R6/R7) waits for
  pawn weight in P7, where the per-step lookup is what matters.
- **Danger volumes project the fall** (`scripts/ai/danger.gd`): a moving large piece's box swept
  along its velocity and gravity over 1.5 s, stopped at the ground, so a soldier under a piece
  ten metres up moves before it has picked up speed.
- **Cover life in decisions:** a soldier in cover checks it every think and leaves with 0.8 s still
  in it against the threat's gun (`BTPeekAndFire.LEAVE`); the engage selector is dynamic, so a
  soldier standing in the open takes cover the moment there is some, and a search that found
  nothing is not repeated for 1.5 s.
- **What was already there:** event invalidation of tactical points is moot — cover is found
  against the current bricks (P4); nav links from holes are the grid (P3); wreck *summaries* are
  not needed for cover or navigation, because AIWorld and AINav read a settled piece's own chunk at
  its own angle — they wait for the flyer height field and the commander's grid (P7, P9).
  Destruction-as-verb actions (shoot through, take cover away, make a door, make cover) are
  deferred to P6, where squads have a reason to use them.
- Gates: **`tools/wreck_load_probe.gd` 9** — a floor plate over a column holds 500 of wreckage; a
  balcony hung from one 2×2 brick under 60 gives way and comes away while the loaded floor stands;
  a piece that moves takes its load; a client replaying LOAD, SOLVE and UNLOAD has the same joints
  broken and the same loads. **`tools/fights_back_probe.gd` 5** — shot at, its cover worn away, a
  soldier leaves with 0.67 s of cover left, and 16 of 18 rounds fired while it hid went into the
  wall (a three-course wall is exactly a crouched figure's height, so a skimming round can clip a
  head); after a collapse it hides behind a fallen wall section lying at 35° (85 ticks with the
  wreck in the player's line), and walks over a slab of wreck lying across its lane; under a piece
  dropped from ten metres it is 3.5 m clear when it lands. **City `-- --wreck` 2** — a tower's top
  cut free settles on its base, its weight goes onto the building as a LOAD, and the log's twin
  buildings replay it.
- Found on the way: a probe arena must disable a dead brick's collision as the city does, or
  rounds stop at bricks that are not there.

### P6 — Squads, tactics, aggro · L

Order / Assignment / Report with ids; squad `BTPlayer`s with blackboard scopes; plays (advance from
cover, suppress and push, bounding, flank, flush, search in pairs, fall back, bait); masked moves;
stacking and clearing with the reply barrier; slicing corners; mouse-holing; attack tokens; morale;
**subtitled callouts with talking markers** (enemies by sight, friendlies through walls); **the
aggro table and meter**.

**Gate:** a scripted room-clearing — four soldiers stack, prep, enter crisscross, clear, report —
completes in the arena; a squad advances only while masked; the aggro meter moves with damage and
holds with hysteresis; callout markers appear only when heard and seen.

**Done (2026-09-29).** Built in the ai-p6 worktree; the squad code was adopted onto main mid-way
(93dcac2, merged there with the engage policy, A21's no-crouch rule, and morale that recovers
only out of the enemy's sight), and the rest — the city, two of the four gates, the docs — came
after on ai-p6b.
- **The layers talk in messages** (`scripts/ai/squad/squad_msg.gd`, AI.md 2): `Order` → `Report`
  (ACCEPTED at once, then DONE or FAILED with a reason; a replaced order is FAILED "superseded"),
  `Assignment` → `Status` (REACHED, BLOCKED, DONE), every one with an id. A `Squad` node
  (`squad/squad.gd`) runs its own LimboAI tree (`SquadTree`) as a TACTICAL job; its blackboard is
  every member's parent scope, so the play and target live one level up. Members have an Order
  branch above their own fight (`BTHasAssignment` › `BTDoAssignment`); with no assignment a member
  fights on its own tree.
- **Clearing a room** (`bt_play_clear_room.gd`, `room_tactics.gd`): stack slots either side of the
  way in, and the play waits on every REACHED (the reply barrier); a flashbang in; entry
  crisscross, 0.6 s apart — the first through crosses to the far corner, the second to the near one
  on the other side, the rest buttonhook; each sweeps its sector, firing at what shows; clear when
  all have swept and nothing is in sight in the room. The points are worked out from the room's box
  and its opening when needed, not baked — a hole the squad blew is as good a way in as a door.
- **Mouse-holing:** no door, or the door watched by a known defender, and the squad makes its own:
  along the walls facing it, clear of corners and the door, the point with the fewest bricks
  through and the least in the defender's view. The breacher sets the charge, rejoins the stack,
  "Breaching!", and the blast goes through `AIServices.on_breach` — in the city the host's `_blast`,
  a logged `BLAST` that clients replay.
- **Masked moves** (`squad/masking.gd`): a mover goes only while the enemy is suppressed (a hostile
  round within 1.6 m of it in the last 0.8 s), looking elsewhere (outside a 50° cone, or
  reloading), or blind to it (bricks, smoke). Checked every physics tick and inside `move_to`. A
  bounding mover holds its fire: the covering half shoots, or a mover's own rounds would be the
  suppression that lets it go.
- **Plays:** bounding overwatch, search in pairs, fall back (and, since the adoption, travel in
  formation for the commander). **Morale:** −0.35 per member lost, and losing half the squad breaks
  it; −0.04/s per member pinned. **Attack tokens:** two shooters per target, asked for only by a
  soldier that would fire this tick with a clear line. **Suppression fire** over the enemy's cover,
  never through bricks or with a squadmate within 0.6 m of the line.
- **Aggro** (`aggro_table.gd`, `aggro_meter.gd`, AI.md 8): per enemy side, a row per player-side
  entity — hp dealt to the side, rounds fired in earshot, seconds seen, seconds within 10 m —
  halving every 8 s; the focus moves only when another row leads by 25 % and by 15, and
  `FactionKnowledge.best` returns it while it is fresh, so the soldiers aim at whoever holds it. The
  meter shows a player's pilot and mech shares and marks the holder; a pawn with meta
  `aggro_kind = "mech"` stands in for the mech until P7 gives it a body.
- **Callouts** (`callouts.gd`, `callout_hud.gd`, AI.md 6.5, A18): heard within 35 m of the
  listener's camera; an enemy speaker in sight gets a named subtitle and a depth-tested marker,
  unseen only an unattributed subtitle; a friendly is always named and marked through walls. One
  line per squad every 1.5 s, the same line not within 6 s, a line waiting over 2 s dropped, urgent
  lines first. "In view" is worked out from the camera's FOV: `Camera3D.is_position_in_frustum`
  needs a drawn viewport and is wrong headless.
- **City:** the breach hook is `_blast`; entering a pawn (V) shows the callouts and the aggro meter;
  **U** spawns a squad of four 30 m ahead, ordered to advance on the player when on foot.
- Gates: **`tools/room_clear_probe.gd` 15** — two squads, two rooms: in through the door, the hidden
  defender dropped, DONE; with the door watched, a hole along the wall and in through it; both
  crisscross into four corners, nothing through a wall, nobody hit by a squadmate.
  **`tools/squad_advance_probe.gd` 10** — 124 m moved masked and 0.00 m unmasked; with every
  suppressor reloading the movers hold (917 → 1103 held mover-ticks); never more than two
  shooting the player; searched for in pairs (2 and 2); two dropped, the rest fall back from 10 to
  34 m and hold. **`tools/aggro_probe.gd` 7** — the table's margin and half-life; player 1 shoots
  and takes the focus (share 0.33 → 0.98) and both soldiers aim at it; player 2 shooting as hard
  does not take it; player 1 stops and it moves; the mech's share shows. **`tools/callout_probe.gd`
  9** — the six cases of AI.md 6.5, the subtitles on screen, the rate limits. **City `-- --squad`
  4** — in a sealed tower a squad blows its own door (a BLAST in the log), stacks, flashes, goes in,
  drops the defender, reports DONE, and the log still replays.
- **Found, not fixed:** sight and aim test the chest only, so a player standing behind a wall that
  hides the chest but not the head is not seen; the advance probe's walls are sized round it. A
  head test (the chest, then the head) was tried in the ai-p6 worktree (commit 95461fa) and left
  out here so as not to shift the engage policy's tuning under it.
- **Deferred:** flank, flush and bait (flush needs grenades; flank needs a path cost for time in
  the enemy's view), the orderly advance in file, slicing corners, blind fire. Perception is still
  per soldier, not per squad round-robin (AI.md 4.2); the faction's radio delay waits for the
  commander. The flash has no effect on a player's view yet — `AIServices.flashed` is the hook.

### P7 — Mechs and weight · L

Brick-built mech on the ported motor, in studs; mech map with clearance (R8) and breach links;
the enemy mech tree; the player's mech on the one-button command; **pawn weight** on the headroom
from P5; **the fall rule** with the plate handling of R9.

**Gate:** a mech from 6 bricks goes through 1 floor, from 12 through 3; a person on a hanging
section drops it, on a floor over columns does not; an enemy mech breaches a building to reach
infantry; the player's mech follows, holds, and attacks an aimed area. Loopback agrees on every
break.

**Done (2026-09-29).**
- **Headroom** (AI.md 3.10, R6/R7): every `solve_stress` now also leaves, per block, how much
  more mass could rest on it before a tension joint on its way down lets go — worked out in the
  same pass order, forward: a joint fails when a block's load passes `capacity × contact`, so its
  own room is the difference, and a block's headroom is the least of its own and its supporters'
  (R7's worst case: the whole added mass reaches every joint below). `INF` where every way down is
  compression — almost every block of a standing building. `BrickWorld.get_headroom`; −1 where
  the chunk has not been solved (R6: rather than baking per recipe, the lookup asks for a solve —
  the city already solves every building it promotes).
- **Weight for everything that stands on bricks** (`scripts/ai/weight_tracker.gd`, A16): the host
  looks up each bearer's foot block when it changes (`AIWorld.block_at`, new): headroom `INF` —
  nothing; finite — a `LOAD` is logged (R5: it takes part in every later solve) and, if the
  bearer is heavier, a solve; stepping off — `UNLOAD`. A person is 1.0 (a 2×4 brick is 2.4), a
  mech 45. Owner ids are negative so they never meet a piece's. The player's pawn, every soldier
  and every mech are bearers in the city.
- **The fall rule** (`scripts/mech/fall_rule.gd`, AI.md 3.11, A12): energy in bricks of fall —
  the height from the top of the fall, so a dash off a roof counts as a drop — against T = 6 (3 on
  a floor with finite headroom); a break costs A = 8.5 and the rest is CARRIED, possibly negative,
  to the next floor, judged on it plus the height fallen since. The break is a `SHEAR` with the
  new `FLAG_WHOLE` (every block in the ball lets go on its own, not a peeled clump), over the
  mech's whole footprint plus half a metre — a hole it does not fit through is a hole it lands on
  the rim of. **R9:** building collision is off from the broken floor down to the next building
  floor under it (posts and walls under a floor are where its feet were), pieces that come off
  under it are collision exceptions, the rule ignores pieces when it looks for the floor, and the
  pieces land quietly (`IslandManager.quiet_landings`). A building still in its shell is made
  bricks when a mech lands on it (A20).
- **The mech map** (R8): `AINav.set_agent(span, head, crouch, step, drop, safe_drop)` — the
  navigation that was hard-coded to a two-stud figure takes any footprint; a mech's is 10 studs,
  48 plates of head, 9 of step, 17 of drop (a drop past that is the fall rule's). The city keeps a
  second AINav with those numbers, invalidated by everything that invalidates the figure's.
- **Mechs with brains** (`scripts/mech/mech_brain.gd`, `mech_tree.gd`, `bt/`): the brain half of
  the titan contract — it fills the same TitanIntents the pilot's keys do. It senses from the
  cockpit, fires every tick at the nearest hostile it sees with a clear line (never through a
  wall, never with a friend in the way), and walks the mech map, steering torso-local every tick
  as the torso turns. **The enemy's mech:** in sight — hold range and shoot; known, behind bricks —
  **breach**: a launcher (ordnance: a `BLAST` through `on_structure_hit`) into the first brick on
  the line from its cockpit to them until it sees them (AI.md 6.4). **The player's mech:** on the
  one button (`mech_command.gd`, A4) — tap FOLLOW ↔ HOLD, held while aiming ATTACK_AREA at the aim
  ray's point; it fights back whatever the order. Its brain is off while piloted.
- **City:** weight on the host; the fall rule on every mech; **Y** spawns an enemy mech 40 m
  ahead; **F** on foot is the mech's button (out of the cockpit it holds where it stands).
- Gates: **`tools/mech_fall_probe.gd` 4** — five-storey towers: from 5 bricks it lands (energy
  5.0), from 6 it breaks the roof and stops (6.0 → 3.9), from 12 three floors (12.0 → 9.9 → 7.7 →
  5.5); a client applying the log lets the same 44 blocks go. **`tools/pawn_weight_probe.gd` 6** —
  headroom is the solve's (one unit under it holds, one over it breaks; a floor on a column
  `INF`); a balcony left 0.5 of room by wreckage: a person on the floor over the column changes
  nothing, a person on the balcony drops it and falls with it, an UNLOAD on the ground; the client
  agrees. **`tools/mech_ai_probe.gd` 6** — the enemy's mech breaches a roofed building (one
  rocket, 66 bricks) and drops both infantry in 8.8 s, no round through a wall, the client agrees
  on 1,732 blocks; the player's mech follows a 22 m walk (6.1 m at the end, 8.8 m at most), holds
  while the pilot walks 22 m off, and sent to an area behind a 6 m wall goes round it and drops the
  enemy there. **City `-- --mechfall` 2** — twelve bricks onto a tower's roof: three floors, three
  SHEARs, standing three storeys down; the log replays.
- **Found on the way:** a mech's capsule is as wide as a floor plate, so it came to rest on the
  posts under the plate it broke, then on the plate itself, then wedged in a hole narrower than
  itself — each a case R9 had in words. And a roof has openings: the gate measures the surface
  under the whole footprint, not under its middle.
- **Not done:** the mech is not a `Pawn`, so soldiers do not shoot at it and aggro's mech row is a
  stand-in until it is; the mech body is still greybox (the brick-built mech); weight is by the
  one block under a bearer's middle (a mech spans many — allowed to be slightly stupid, A10); no
  mech-rated storeys or deliberate drop-through yet; the enemy mech has no dash, evade or melee;
  the one button is gated in the arena, not in the city.

### P8 — Many · L

Tiers as HSM states; importance budget (max over players, R23); shared squad paths and flow fields;
`SwarmCore` rows with promotion; flyers on the height field; animals and packs on procedural
creatures.

**Gate:** 10 smart + 40 directed + 300 swarm in the arena inside the AI budget, with the budget
arbiter stepping down cleanly during a collapse; the `--stress` pass re-run with those agents in it
(R14).

**Done (2026-09-29).**
- **Tiers as HSM states** (`scripts/ai/agent_tier.gd`, `tier_state.gd`, AI.md 7): a LimboHSM per
  agent, SMART ↔ DIRECTED, whose state's enter hook tells the agent (`set_tier`). A soldier swaps
  its tree — DIRECTED runs `SoldierTree.build_directed()`: Evade › the squad's assignment ›
  `BTDirectedEngage` (in sight and within 30 m, stand and shoot; otherwise walk the shared flow
  field toward the contact) › Idle; no cover search, no tactic — at 3 Hz thinking and 2 Hz eyes
  instead of 10 and 5. Evade and firing are the same code at both tiers. A SWARM ROW is not a
  state: an agent demoted that far stops being a node. (An event dispatched to an HSM spawned the
  same tick was not taken; the tier falls back to changing the state directly.)
- **The importance budget** (`importance_budget.gd`, AI.md 10.2, R23): twice a second each agent's
  importance — distance to a player (halving every ~10 m), ×1.5 in that player's view, +25
  shooting, +20 hurt, +15 leading a squad, +20 an animal hunting close — the MAX over players. Best
  first: ten SMART, the rest DIRECTED; an agent already smart counts 1.25× for keeping its place,
  and no more than three are promoted a tick (a displaced smart agent keeps its place while a
  promotion waits, so there are always ten). Swarm-born agents that are not smart and are 45 m
  from every player go back to rows.
- **Flow fields** (`AINav.request_field` / `field_dir`, AI.md 4.3): one Dijkstra field per goal,
  over the STEPS INTO each node (so a drop is one-way, as it is for a path), within 45 m of the
  goal, worked out inside `service()` after the paths and restarted by an invalidation that reaches
  it. A* and the field share one step function (`_step`), extracted from the search. Agents read
  it through `AIServices.field_dir(goal, from)`, keyed by the goal to 3 m, so everyone after the
  same contact reads the same field; directed soldiers steer on it every physics tick.
- **Swarm rows with promotion** (`swarm_side.gd`): `SwarmCore` in its own hands (its director
  off); the goal is the nearest player; the obstacles are the chunks' boxes, or in the city the
  buildings' boxes, shell or bricks, refreshed every 5 s; a player-side round hits the first row on
  its line no further than what the bullet struck (`AIServices.round_listeners`). A row within
  16 m of a player is released without a death and becomes an **animal hunting that player**,
  born DIRECTED, at most two a tick and never past the budget's room; the budget hands it back as
  a row, with its health, once the player is gone.
- **Animals and packs** (`animal.gd`, `animal_pack.gd`): a procedural creature (`ProcCreature`, its
  gait animated from how the body moves) on a Pawn's body — or a greybox for the many. The pack
  decides for all of them: GRAZE round a wandering anchor, FLEE together from a noise, HUNT —
  encircle the prey at 7 m, each to its own angle, then close on the shared field and bite.
  Wildlife is on no side (a negative team): nobody's enemy (`hostiles_of`), and it has none.
- **Flyers** (`flyer.gd`): a kinematic drone on the HEIGHT FIELD — `AIWorld.top_at` over a patch
  round it and 1.2 s of flight ahead of it, never lower than 5 m over what it is over (under it, it
  climbs at once and holds off going forward) — orbiting its target, a strafing run every 10 s,
  climbing out when hit.
- **City:** `-- --stress --agents` puts the P8 population round the stress pass's centre: six
  squads of six, three flyers, a herd, 300 swarm rows, all after one player-side body; the budget
  runs in `_ai_tick`, and the swarm's tick counts in the AI's time.
- Gates: **`tools/many_probe.gd` 11** — 36 soldiers in squads, 3 flyers, a herd of 5 and 300
  rows round one player: exactly ten smart and the rest directed in all 70 samples, the smart the
  most important by the budget's own scores; rows walk on the player and its rounds hit them (54);
  9 rows promoted into hunting animals that bite; with the player gone all 6 go back to rows;
  directed soldiers close on the shared field (59.7 → 52.7 m, 5 fields); flyers never lower than
  5.8 m over what they are over, firing; the herd grazes within 3.7 m of itself and runs from
  gunfire; a tower cut at its foot comes down and soldiers keep firing through it; no round through
  a wall; **AI 1.43 ms a tick mean (99th percentile 2.97 ms), the swarm's own tick included**.
  **City `-- --stress --buildings=200 --agents`** — 10 smart, 40 directed, 294 rows through the
  whole pass; the arbiter steps down to level 4 while the city comes down and back to 0; AI sync
  and run 1.90 ms a tick.
- **Timing, A/B on a quiet machine (2026-09-30, no editor, no other Godot runs;
  `-- --stress --buildings=200`, twice each):** without agents the whole run's mean frame was 17.9
  and 17.5 ms (1.9 % and 1.5 % of frames over 33 ms), AI sync and run 0.34 and 0.29 ms a tick; with
  `--agents`, 25.4 and 19.6 ms (12.7 % and 2.9 % over 33 ms), AI 1.93 and 1.65 ms. So the AI's own
  cost is steady -- about 1.5 ms a tick for 50 node agents and 300 rows, inside its 2.5 ms budget
  -- and the whole frame pays 2-8 ms more, noisily: fifty more bodies moving in physics and the
  swarm's drawing are outside the AI's budget. Where that goes next: the budget's own tick
  (0.8-1.4 ms at 2 Hz, GDScript) to C++, and the directed tier's per-tick Soldier script.
- **Not done:** the arena's collapse is one clean piece, which does not fill the frame, so the
  arbiter stepping DOWN is gated in the city stress pass rather than the arena; perception is still
  per agent, not per squad round-robin; the budget ticks in GDScript (0.5–1.4 ms at 2 Hz — a
  candidate for C++); a promoted row becomes an animal, not a soldier; flyers are not Pawns, so
  soldiers do not shoot at them.

### P9 — The commander · M

Per-encounter commander with a tree; sector grid; roster and doctrine from the **threat profile**;
off-screen fights by points; the friendly side; **the character save** (character, mech, guns,
missions, threat profile).

**Gate:** two scripted player styles (destructive vs not; pilot kills vs mech kills) produce
measurably different rosters and doctrine in the next encounter, within the clamps.

**Done (2026-09-30), in two hands.** The commander itself came from the combat-arena work
(`scripts/ai/commander/`, `tools/commander_probe.gd` 28): a per-encounter `Commander` that
orders squads (ADVANCE, MOVE in file, CLEAR_ROOM) and buys reinforcements with points; a
`SectorGrid` of where its men died; a `Doctrine` from the `ThreatProfile` (sniper, rusher,
demolisher), its desperation and the difficulty, every weight clamped to ×0.5..×2 of its base;
`PointsBattle` fronts resolved off-screen; an HQ whose officer and radio can be killed. The rest
of P9, on ai-p9:
- **Pilot kills against mech kills** (A8): `ThreatProfile.note_kill(by_mech)`, `mech_share()`,
  `armor_style()` ("mech", "pilot", "mixed"), kept in the profile's dictionary. Against a player
  whose MECH does the killing the doctrine goes for the PILOT: assault ×1.4 to reach them, marksmen
  ×1.4 to pick them off, and a `pilot_focus` of 0.7 that the commander hands to its side's aggro
  table (`AggroTable.bias`) — gains on the pilot's row count 1.7× — so its fire follows. Anti-armor
  (the rocketeer) is weighted ×2 in the roster but not fielded: a mech is not a `Pawn`, so nothing
  can aim at it yet, and making rocketeers fieldable changed the combat arena's draws enough that
  its wave-3 check missed its window.
- **The careful player** — enough seen, under 10 bricks a minute broken — is answered like the
  opposite of the demolisher: the buildings are safe, 80 % of a reinforcement goes inside.
- **The character save** (`scripts/character_save.gd`, A14): the character, the mech, the guns,
  the missions, the threat profile and the aggro history (pilot and mech shares), as versioned
  JSON at `user://character.json`. A gun is kept as what made it — class, seed, tier — and made
  again the same; a file from a newer version is refused rather than half-read.
  `take_encounter(commander, aggro)` at the end of one; `profile()` for the next commander.
- **The friendly side:** a `Commander` on the player's team, its `rally` kept on the player, sends
  its squads to MOVE in file after the player when they fall behind — the same code as the enemy's.
- Gate: **`tools/threat_style_probe.gd` 7** — three scripted minutes each of A (a demolisher whose
  mech kills: 240 bricks a minute, kills mostly the mech's) and B (a careful pilot), each ended into
  a save on disk and read by a FRESH commander: A is read demolisher/mech, B balanced/pilot; the
  save carries the profile exactly, the character, the missions and three guns made again
  identical; A's rosters put 38 % of 1,600 units into assault and marksmen against B's 31 %, pilot
  focus 0.7 against 0, rocketeer weight 1.0 against 0.25; A's reinforcements go 25 % inside
  against B's 80 %, marksmen 9.9 % against 6.4 %; every weight inside ×0.5..×2; the pilot bias
  reaches the side's aggro (1.7); a friendly squad 40 m off is brought to the player (1.8 m)
  by two MOVE orders.
- **Not done:** the commander is a script on a one-second think, not a LimboAI tree as planned —
  it works, and it is the combat-arena work's to convert if a tree earns its keep; the pilot/mech
  kill split is fed by the gate, not yet by a host (the combat arena has no player mech; the city
  has no commander); the rocketeer waits for the mech to be a target. The combat arena's gate
  (31) passed 2 of 3 runs with this change — the miss a squad's stack taking too long, in a check
  that is timing-sensitive; it passed 1 of 1 without.

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
