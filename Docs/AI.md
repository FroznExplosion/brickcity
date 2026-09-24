# AI — enemies, squads and the commander

**Status: planning, 2026-09-23. Nothing here is built.** §0 records what has been decided; §14 is
what is still open.

The game is a co-op FPS with Titanfall-style mechs in the destructible brick city. Enemies are
mechs, flyers, infantry, animals and swarms. They shoot, melee, dodge, plan and fight as squads —
and the player's own mech can fight on its own, so **friendly AI is the same problem as enemy
AI**. Behaviour trees (LimboAI) plus ONNX policies, under a commander per encounter.

Prior art, read before this: [Reference/reddawn.md §12](Reference/reddawn.md#12-fps-feel-ai-and-vehicles--inventory),
[Reference/mvs-c.md §6](Reference/mvs-c.md#6-ai-squads-and-the-wanted-system),
[Reference/boomer-border.md](Reference/boomer-border.md), and F.E.A.R. (§1.4).

---

## 0. Decided

| # | Decision | Where |
|---|---|---|
| A1 | **Co-op first.** Host-authoritative AI from the first line | §12 |
| A2 | **About 10 smart agents, under 50 with any tree, a swarm beyond that.** Importance decides who is smart | §10 |
| A3 | **Mechs enter buildings built for them**, and others once enough is gone | §3.6 |
| A4 | **Mech command is one button:** tap = FOLLOW ↔ HOLD, hold while aiming = ATTACK_AREA | §2.1 |
| A5 | **LimboAI used as a tree, not a state machine**; ONNX policies are leaves in it | §7 |
| A6 | **Copy** BoomerBorder's weapon system and docs, and **both** procedural systems (guns and creatures) | [boomer-border §0](Reference/boomer-border.md#0-porting-checklist--read-before-copying-anything) |
| A7 | **A commander per encounter**, shaped by a threat profile saved with the character | §9 |
| A8 | **Aggro, Army of Two style, shown as a meter** | §8 |
| A9 | **All AI shares one world model and one set of navigation data.** Knowledge of *contacts* stays per faction | §4 |
| A10 | **Performance over perfection.** Every AI system runs on a budget and is allowed to be slightly stupid to stay inside it | §10 |
| A11 | **Small wreckage is deleted fast and is purely visual. Large wreckage is the host's, and every client's matches it** | §3.5, §12 |
| A12 | **Mechs can go on upper floors.** Most floors hold a standing mech. A mech that falls **one storey (6 bricks) breaks through one floor; two storeys (12 bricks), about three** — confirmed as the starting numbers | §3.9–3.11 |
| A13 | **Tactics pulled from F.E.A.R. and improved:** cover arcs, stacking at doors, slicing corners, moves masked by suppression and smoke | §6 |
| A14 | **Save model is Borderlands:** the character, mech, guns and mission progress persist. **An area's destruction is saved while you are in it and reset when the area reloads.** **No pieces respawn during play** | §12.3 |
| A15 | **Mechs aim like the player** — full pitch, no arm limit of −45°/+40° | [boomer-border §0](Reference/boomer-border.md#0-porting-checklist--read-before-copying-anything) |
| A16 | **Weight for everything that rests on bricks**, through a per-block headroom check that costs one lookup. **Settled wreckage on buildings first; players, infantry, animals and mechs after** | §3.10 |
| A17 | **Save anywhere, the exact situation, mid-fight and mid-collapse.** Checkpoints are the fallback if that proves too hard, and ship first | §12.3 |
| A18 | **Callouts are subtitles for now, with a talking marker over the speaker** when the player can both hear and see them. **Enemies: never through walls** (a possible upgrade later). **Friendlies: marked through walls** | §6.5 |
| A19 | **A summoned mech landing on a building does massive damage** — the fall rule runs to the ground, no cap | §3.11 |
| A20 | **Anything that damages or lands on a building activates it** — materialises it first, then breaks it | §3.2 |

---

## 1. What the prior art tells us

### 1.1 Red Dawn: the ideas were right; the structure did not hold

| Level | Ideas to keep |
|---|---|
| Agent | Patrol / Idle / Investigate / Combat / Search / Return / Dead · cover scoring · peek-hide cycle (hide 1.5–3 s, 2–5 round bursts) · **suppression as a number** (decays 12/s; 30 = cautious, 60 = pinned) · flank positions 60–120° off the threat axis · suppressive fire · 20 m passive / 40 m alerted detection · 3 s line-of-sight grace · spiral search · "being aimed at" awareness · close-range panic |
| Squad | Tactics `HOLD, ADVANCE, FLANK, SUPPRESS_AND_PUSH, BOUNDING_OVERWATCH, RETREAT, DISTRACT_AND_FLANK, AMBUSH` · bounding pairs · morale (death −0.25, leader death −0.4, retreat at 0.2) · shared sighting · player-style classifier → counter-tactic · reload-opportunity pushes |
| Vehicles | Infantry linked to a vehicle, dismounting, screening it, using it as moving cover |
| Commander | Event-driven · desperation · `priority × aggression` · a points budget · off-screen battles by points · a killable commander and radio |

Why it never came together — **inferred from the code**, not from a post-mortem:

1. **The tree was never the brain.** `combat_state.gd` is one 67 KB `_update`; the only behaviour
   trees are LimboAI's demos.
2. **Orders were strings with no reply** (`squad_command` in a blackboard).
3. **The world was rediscovered by raycast every time** — 12-ray cover fans per agent, and SDF
   deformation invalidating the navmesh.
4. **Player-shaped, not faction-shaped**; friendlies were a separate code path.
5. **Node references everywhere**, against [rule 1](Reference/README.md#the-five-rules-both-projects-converged-on).

### 1.2 mvs-c: the squad rules that held

**A casualty outranks a target**, being badly hurt outranks both. **The leash outranks the fight.**
**Formation, not a huddle**, slots snapped onto the navmesh. In combat, path against the current
facing. AI tick rate and the right to query navigation are functions of distance to a player.

### 1.3 BoomerBorder: the brain contract

`TitanIntents` — the motor reads one struct and never knows who filled it; swapping the brain is
the whole piloted ↔ autonomous switch.

### 1.4 F.E.A.R.: what made soldiers read as smart

Jeff Orkin's GDC 2006 talk *Three States and a Plan: The AI of F.E.A.R.* is the source. What
transfers is less the planner than the behaviours and one insight:

- **Squad behaviours were few and simple** — get to cover, advance from cover to cover while
  others cover, an orderly advance in file, and a search in pairs. Flanking was not a scripted
  behaviour; it came out of cover selection plus a line of dialogue.
- **Dialogue explains the AI.** A soldier shouting that he is flanking makes a cover move read as
  a plan. The player credits the AI with the intelligence the callout describes. This is the
  cheapest intelligence there is.
- **Cover had a direction.** Cover nodes were valid only against threats inside their arc.
- **The environment was a verb:** blind fire over cover, vaulting rails and diving through
  windows, kicking doors, **knocking furniture over to make cover**, flushing a hiding player with
  grenades.

Our improvements on it: cover that knows how long it will survive (§3.7), a world where *making*
cover and doors is general rather than scripted (§3.8, §6.2), aggro (§8), and callouts that the
squad actually acts on through the order/reply system (§2).

---

## 2. The shape: four layers, one contract at each seam

```
 Commander   one per faction,       roster, doctrine, objectives,         0.5–1 Hz + events
             per encounter          reinforcements, off-screen fights
     │  Order ─────────────▶        {squad, kind, area, posture, priority, id}
     │  ◀───────────── Report       {order id, ACCEPTED | DONE | FAILED(reason), contacts, strength}
 Squad       one per group          choose a play, assign roles and slots   2–5 Hz
     │  Assignment ────────▶        {member, role, slot, facing, fire lane, until}
     │  ◀───────────── Status       {reached | blocked | pinned | low ammo | down}
 Brain       one per smart agent    behaviour tree + utility + policies     5–10 Hz
     │  Intents ───────────▶        {move, aim, fire, melee, dash, jump, crouch, ability[n]}
 Body        one per agent          motor, weapon, animation                30 Hz physics
```

- **Every downward message has an upward reply.** An order carries an id and is always answered.
- **Everything is addressed by stable id** — agents, squads, contacts, buildings, wreckage (by
  content hash), cover points. Nothing holds a node across a tick.
- **Factions are symmetric.** Each player is a contact like any other; friendlies run the same
  code.

| Seam | Scripted | Player | ONNX (§11) |
|---|---|---|---|
| Intents | BT brain | piloting | combat-micro policy |
| Assignment | squad play | — | play selection |
| Order | scripted commander | the mech button | strategic policy |

### 2.1 The player's mech

Out of the cockpit, the mech's brain slot holds a BT brain and the mech joins the pilot's squad.

| Input | Order | Behaviour |
|---|---|---|
| Tap | FOLLOW ↔ HOLD | FOLLOW is BoomerBorder's (5/8 m band, waits below when unreachable). HOLD holds the spot. Both fight back |
| Hold, while aiming | ATTACK_AREA(aim point) | Path there, engage anything in the area, stay until tapped again. The point is the pilot's own aim ray, so it lands on a street, a window or a building |

---

## 3. The world model

The AI **reads** the world instead of probing it: integer grids with stable block ids, a recipe for
every building and a log of every change.

### 3.1 Every piece of the world is a grid with a transform

There is no single world grid. A materialised building is a chunk with its own frame; a piece that
came off it is a chunk at any rotation; a dormant piece is a `ChunkRecord`. The query layer —
`AIWorld`, C++, **inside the brick extension** so it can read chunk grids directly (a separate
extension could only reach them one `Variant` call per cell — [AIPlan R1](AIPlan.md#11--would-have-forced-a-rewrite)) —
treats them alike:

- **Broad phase:** a spatial hash of chunk world AABBs — a building's from its recipe, an island's
  from `world_aabb`, a dormant piece's from `ChunkRecord.box`.
- **Narrow phase:** transform the ray or point into the chunk's frame, divide by the stud and
  plate pitch, and walk *that chunk's* occupancy with an integer DDA. A tilted slab is no harder
  than a wall.

### 3.2 Never materialise a building to answer an AI question

A pristine building is answered from `TowerRecipe.plan`. **An AI query must never cause a
materialisation** — probed by counting materialisations during an AI-only run.

*Presence* is different. An undamaged building's collision is four wall slabs and a ground floor —
no roof, no upper floors, no openings (`BuildingShell.collision_boxes`) — so nobody can fight in or
from one. **An encounter pre-materialises the buildings in its zone** at load, inside the budget,
exactly as a player walking up to them would ([AIPlan R3](AIPlan.md#11--would-have-forced-a-rewrite)).

### 3.3 Tactical data is baked per recipe

Baked **once per recipe**, placed per building by its transform, zero cost for a pristine
building:

- **Cover points** with a height class (low / high), a **valid threat arc** from the wall's normal
  (F.E.A.R.), and a lean side.
- **Corners** with their handedness, for slicing and for leaning out the side that shows less.
- **Doors and openings** with **stack slots** on both sides and **entry points** inside
  (§6.2), from `RoomManifest.openings_for`.
- **Room corners** — the points of domination a clearing team takes — from the room bounds.
- **Firing positions:** windows, roof edges.
- **The room neighbour graph** ([Next.md §2.3](Next.md#23-a-room-neighbour-graph-replacing-the-radius)),
  shared with the interiors.

### 3.4 Invalidate by event, never by polling

Structural changes arrive as `DamageLog` entries and as the wreckage lifecycle events of §3.5.
Tactical points in range go dirty and are re-scored inside a budget; new holes become openings,
nav links and sightlines; falling islands become danger volumes.

### 3.5 Seeing a building after it has fallen

After a collapse the bricks are no longer in the building's grid — they are in new chunks lying at
angles in the street, and later some are not chunks at all.

**Sight is already solved.** Perception uses physics rays on `Layers.HITSCAN_MASK`, which includes
`DEBRIS`, `RUBBLE` and `FALLING`.

**Everything else follows the piece's lifecycle**, with an event at each change and one small
summary per large piece:

| Piece | What the AI does with it |
|---|---|
| **Building topples or is handed over** | Drop its recipe points, room graph and navmesh obstacle |
| **Falling** | A **danger volume**: AABB swept along its velocity for ~1 s. Everything flees it |
| **Large, settles** | A **wreck summary**, once: a world-aligned column height map over the piece at 2-stud cells, cover points on its faces tall enough to crouch or stand behind, whether the top is walkable. Its merged collision boxes go into the tile navmesh rebake |
| **Small** | **Nothing. Deleted fast and purely visual** — see below |
| **Large, damaged or split** | Summary dirty; recomputed when it settles again |
| **Large, slept** | No body, **no collision**. The summary and the nav bake survive; its cover points are withdrawn from agents in reach |
| **Large, woken** | Re-registered; same content hash, so the old summary is reused |

**Small pieces (A11):** "small" is **physical size, not block count** — a floor panel is a single
`plate_10x10` block 3.5 m across, and it is a landmark ([AIPlan R2](AIPlan.md#11--would-have-forced-a-rewrite)).
Below the landmark size, pieces are deleted soon after they settle — a short
fade, well under the current 2.5 s — and **pawns do not collide with the `RUBBLE` layer**, so they
never affect movement, cover or navigation, on any machine. That makes them safe to differ between
clients, and safe for the AI to ignore. It is a change to `Layers.PAWN_MASK`; the step height
already walks over anything that small, so nothing is lost but a stumble.

**Large pieces:** the landmark class. The AI hides behind them, so every machine must have the same
ones in the same place — §12.1.

Traps:

1. **The large-piece cap can sleep a piece beside a fight.** Pieces a smart agent is using as cover
   or standing on are exempt from the cap, as `Room.hit` keeps a room real; AI agents count as
   interest points for wake and sleep.
2. The height map is also what flyers (§3.6) and the commander's sector grid (§9) read, so a street
   full of wreckage is blocked at every level.

### 3.6 Navigation: one representation per way of moving

Terrain does not deform — only buildings do — which removes Red Dawn's worst problem outright.

| Mover | Representation | Destruction |
|---|---|---|
| **Infantry, small animals** | Navmesh per terrain tile, buildings as obstacles; interiors as **per-storey regions baked once per recipe**, placed by transform and joined by door and stair links; the room graph for long routes | A change in a tile queues an async tile rebake, budgeted. Source is boxes (`get_body_boxes`, `get_block_boxes`, wreck summaries), never a trimesh |
| **Mechs** | A separate map at mech radius, plus **breach links**, plus mech-rated storeys (§3.11) | A breach link crosses a wall at the cost of cutting a mech-sized hole; taking it runs a *Breach* action through the ordinary damage path |
| **Flyers** | A 2.5D height field of building tops (recipes) and wreck summaries; A* on a coarse grid with an altitude band | A changed cell is one write |
| **Swarms** | `SwarmCore` flow fields with vertical layers | Regenerated when goal or obstacles change |

**Mechs in buildings (A3):** a recipe can declare mech-sized openings and mech-clearance storeys —
hangars, garages, atriums, a warehouse ground floor — and those interiors go into the mech map's
bake. A pilot-sized door has no polygons. Anything else opens up by breaching or collapse, after
which the clearance is recomputed.

**Nav links from destruction.** A hole a body fits through, a window, a low wall, a floor with a
hole in it — each becomes an off-mesh link of the right kind (walk, vault, climb through, drop),
found from the opening's size in the grid. F.E.A.R.'s window dives and rail vaults fall out of
this, on geometry the player made.

### 3.7 Cover is a number: how long it will last

Cover against a threat = the live bricks between the two points, by the DDA in §3.1, across every
chunk the line crosses, standing or fallen. Divided by the threat's structural damage rate, that is
**seconds this cover survives that weapon**. Cover is taken only against threats inside its arc.
An agent leaves cover *before* it runs out, not after. Structural danger —
`get_max_stress_ratio`, `is_support_broken`, `check_stability` — says whether the building itself
is about to go.

### 3.8 Using the destruction on purpose

A BT action with a utility score from a structure query, each: **shoot through** thin walls,
**take the cover away**, **make a door** (mouse-holing, §6.2), **make cover** (drop a wall section
so its wreck is cover — F.E.A.R.'s table flip, built from the city), **drop it on them** (a
`check_stability` what-if, rare, telegraphed), **flush the room**, **drop a mech through a floor**
onto a squad below (§3.11), and **fear** — infantry flee a collapsing building, animals stampede.
What-if queries run on one chunk in C++ and are capped per second.

### 3.9 What weight does today

Worth being exact, because it decides what the mech needs. [BrickFailure.md](BrickFailure.md) has
four mechanisms and **self-weight drives only one of them:**

| Mechanism | What breaks it | Example |
|---|---|---|
| **Compression** | nothing — a joint carrying weight straight down never fails (D11) | a building balanced on a few bricks does **not** crush them |
| **Tension** | weight *hanging* from a joint, with no downward path to ground (~29 brick-weights per full connection at world scale, D12) | an overhang, a wall section held by a corner, a floor whose column was shot out |
| **Toppling** | the centre of mass leaving the footprint (`check_stability`, D13) | the building balanced on a few bricks **tips over** — that is what happens to it, not crushing |
| **Impact shear** | a collision pushing a band of joints off their studs (`SHEAR`, `fracture_on_impact`) | a building falling onto another **shears the top of the one it lands on** — impact, not weight |

So a floor plate sitting on its column is pure compression and holds anything — which is exactly
A12's "most floors hold a mech". **No new compression rule is needed.** A mech standing on a
floor matters only where that floor *hangs* (the tension row), and a mech landing matters through
the impact-shear row.

### 3.10 Weight for everything that stands on bricks (A16)

The solver already carries each brick's own weight. What it does not carry is anything standing on
it — settled wreckage resting on a building, and players, infantry, animals and mechs.

**The cheap way: headroom.** When `solve_stress` runs it already walks every joint's load. Have it
also store, per block, its **headroom**: how much more mass could hang from that block before the
weakest tension joint on its path to ground lets go. Blocks whose path is all compression have
infinite headroom — which is almost every block in a standing building.

Then weight costs **one lookup:**

- Each tick, sum the mass of everything standing on each block (a pawn knows the block under it
  from its floor contact). Most blocks have nothing on them; a pawn checks only when the block under
  it *changes*.
- If the sum exceeds the block's headroom, queue a real solve with that load in it, inside the
  destruction budget. Otherwise nothing happens, and that is the common case.

| Load | Mass, roughly | What it will realistically do |
|---|---|---|
| A person | well under one brick-weight | nothing — except on a section already hanging by a thread, where stepping on it is what finally drops it. That is a good moment and it costs nothing |
| An animal, a squad | a few | the same, a little sooner |
| A mech | many brick-weights | snaps hanging floors, balconies and overhangs; stands on anything sitting on columns |
| Settled wreckage on a building | its own mass, at its contact blocks | a toppled building lying across another loads whatever it rests on; rubble piled on a balcony can bring the balcony down |

Headroom goes stale when the structure changes; every solve rewrites it. Two loads on the same
hanging section are summed per block, which is approximate when they stand on different blocks of
one section — allowed to be slightly stupid (A10).

**Order of work: wreckage first, then pawns.** Wreckage is the load the city already produces
and the one that changes a collapse, so it goes in first:

1. **When a large piece settles** on the host, its contact points are known (`_contact_points`, the
   same query `fracture_on_impact` uses). Contacts whose collider is a building's body map to that
   chunk's blocks by `block_at`; the piece's mass is shared across them.
2. Each contact block is checked against its headroom. Over it, a solve is queued with those loads
   in it — and what breaks, falls, and may land on something else, which is how one toppled
   building can bring down a second in stages.
3. The loads stay registered while the piece rests there, so later damage that shrinks a block's
   headroom re-checks them in the same solve. They are removed when the piece moves, is slept, or
   is destroyed.

Pawn weight then reuses the same headroom, the same per-block sum and the same queued solve —
only the source of the load differs.

**For co-op**, a load takes part in every later solve on its chunk, so a client missing one would
break differently at the next blast. **Persistent loads on blocks with finite headroom are logged
when added and removed** (`LOAD` / `UNLOAD`); that is rare, because almost every block has infinite
headroom. Loads on compression-only blocks are never sent, because they can never matter
([AIPlan R5](AIPlan.md#11--would-have-forced-a-rewrite)). Headroom for a building nobody has solved
yet is **baked per recipe**; the first solve overwrites it.

### 3.11 Mechs falling through floors (A12)

A landing is energy, not weight, and the rule can be stated in **bricks of fall** so it does not
depend on how heavy a mech turns out to be. With `COURSES_PER_FLOOR = 6`, one storey is 6 bricks:

- A floor **breaks** if the mech arrives with the energy of a fall of at least **T = 6 bricks**.
- Breaking a floor **costs A = 8.5 bricks** of that energy; falling the next storey **adds 6
  back**. So each floor it goes through costs a net 2.5 bricks.

| Falls from | Floors it breaks |
|---|---|
| under 6 bricks | none — it lands |
| 6 bricks (one storey) | **1**: arrives with 6, breaks, 6 − 8.5 + 6 = 3.5 left, stops on the next floor |
| 12 bricks (two storeys) | **3**: 12 → 9.5 → 7 → 4.5, stops |
| 18 bricks | 5 |

A must be more than one storey (6) or a mech that breaks one floor never stops; 8.5 is what makes
A12's numbers come out. The arriving energy comes from the mech's actual vertical speed, as the fall
height it is worth — `v² / (2 g)` using the mech's own gravity scale — so a dash off a roof counts
the same as a drop.

Per floor, T scales with what the recipe says the floor is: a normal floor T = 6, a
**mech-rated** floor (hangar, garage) higher, a floor that is already hanging or damaged lower. A
heavier mech class can have a lower T and a higher A; it is still two numbers.

When a floor breaks, the host shears the plates under the mech's footprint (the existing `SHEAR`,
radius from the foot size), and they fall as an island. **The mech ignores collision with the
plates it just broke and their own landing fracture is suppressed**, so the rule — not a
double-counted impact — decides the next floor.

A mech (5.6 m) is taller than a storey (2.52 m), so "upper floors" for a mech means roofs,
mech-clearance storeys and floors destruction has opened up; an ordinary storey has no room for
it, and the mech map's clearance says so. No physics decides whether
it goes through — the rule does — so it is cheap, deterministic, and it is the same on every
machine.

**For the AI:** mech-rated storeys go into the mech map. An AI mech avoids floors that would break
under the way it is moving — unless the tree has chosen **drop through**, when it jumps or dashes
off the storey above on purpose. Infantry learn that an upper floor is safe from a mech only until
the mech decides it is not.

---

## 4. Sharing information and pathfinding (A9)

### 4.1 One world model for everyone

Geometry, navigation and tactical data are **built once and shared by every agent of every
faction** — the ten smart ones, the forty directed ones and the swarm:

`AIWorld` (chunks, DDA, wreck summaries) · tile navmeshes per agent class · the room graph · the
flyer height field · baked tactical points · danger volumes · smoke volumes · flow fields.

Geometry is ground truth; there is no fog on *where the walls are*.

### 4.2 Knowledge is shared inside a side, never across

What is known about **contacts** — where an enemy is, where it was last seen, how sure — is per
faction. Enemies share with enemies, friendlies with friendlies. Sharing across sides would be the
enemies knowing where your mech saw you, which is cheating the player can feel.

- **Squad:** instant. One member sees, the squad knows.
- **Faction:** through the commander, with a radio delay, and not at all once the radio is
  destroyed.
- **One perception pass feeds all of it:** sight is checked per *squad* per target, not per member
  — one or two members' eyes, round-robin — and the result goes to the squad's table.

### 4.3 Pathfinding shared, in four ways

1. **Hierarchical.** A small abstract graph — street sectors, building openings and breaches,
   rooms — carries the long route. A* on it is microseconds and its results are cached by
   `(from, to, agent class)`, invalidated only when an event touches a portal on the route. The
   navmesh is asked only for the next couple of sectors.
2. **Squads path once.** The leader (or the squad's anchor point) paths; members follow the
   corridor at their formation offsets, snapped to the navmesh by a closest-point query. mvs-c's
   formation rule, and ten times fewer path queries.
3. **Flow fields when many go to one place.** Directed agents and swarms converging on a player or
   an objective read one field per `(goal, agent class)`, regenerated when the goal moves past a
   threshold. Five hundred rats cost one field.
4. **Requests are queued, not called.** A path request goes into a queue with the agent's
   importance as priority and is served inside a per-frame budget. An agent keeps its old path
   until the new one arrives. Re-path only when the target has moved past a threshold, an event
   touched the corridor, or the agent is stuck.

---

## 5. The agent

### 5.1 Shared services

- **Perception** — sight rays on a global budget; hearing from gunfire, explosions and collapses;
  damage direction; being inside a player's aim cone. **Smoke** is tested by `AIWorld` after the
  physics ray, because physics cannot see smoke.
- **Aim** — the AI fires the same gun through the same calls as anyone. Error lives in the aim:
  reaction time, a cone that tightens while it tracks, lead for projectiles, difficulty scaling.
- **Threats** — slow projectiles, grenades, falling islands, mech stomps and mechs falling through
  floors, as short-lived volumes. `Evade` sits at the top of every tree.
- **Weapon choice** — range band against class, element against the target's top defence layer.
- **Attack tokens** — only so many shoot one target at once; aggro (§8) decides who gets them.
- **Callouts** — every play, state change and discovery emits one (§6.5).

### 5.2 Archetypes

| | Body | Moves on | The tree is mostly about |
|---|---|---|---|
| **Infantry** | `CharacterBody3D` + `Pawn` component (D7) | tile navmesh + rooms + links | cover, peek, suppress, stack and clear, flank, grenades, breach |
| **Mech** | BoomerBorder titan motor + weapon | mech map + breach links + rated storeys | the duel: dash out of rockets, strafe, torso lead, melee, abilities, crushing cover, dropping through floors |
| **Flyer** | its own body | height field | orbit, strafing runs, climb out to evade |
| **Animal** | procedural creature | tile navmesh | graze, flee, hunt, pack encircle, stampede |
| **Swarm** | `SwarmCore` row | flow field | none per agent — the swarm is the behaviour |

---

## 6. Tactics (A13)

Each is a squad **play** or an agent **subtree** (§7), with slots taken from the baked tactical
data of §3.3 and moves checked against §3.7.

### 6.1 Cover and movement

- **Cover with an arc.** A point is cover only against threats inside its arc and only while its
  life (§3.7) lasts. Low cover means crouch and pop up; high cover means lean out the corner side.
- **Advance from cover to cover** — F.E.A.R.'s core squad move. One or two suppress, one moves,
  then they swap. A bound is capped at a few seconds of exposure.
- **Mask every move.** A mover goes only when the route is *masked*, and the route is chosen to
  stay masked:
  - the target is **suppressed** — a squadmate's rounds are landing around it;
  - the target is **looking elsewhere** — the mover is outside its aim cone, or it is reloading;
  - the route is **occluded** — by walls (DDA), by wreckage, or by **smoke**.
  Path cost includes the seconds each segment spends in the target's view, so the route a squad
  takes is the covered one, not the short one.
- **Smoke.** Smoke volumes are occluders in `AIWorld` for every faction — the player's smoke blinds
  the AI and the AI's smoke blinds the player. Units with thermal sights (mechs, some elites) see
  through it; that is the counter, and it is the Titanfall electric-smoke loop.
- **Blind fire** from cover: suppression without exposure, at low accuracy.
- **Vault and dive** through the links of §3.6 — windows, low walls, holes the player made.
- **Make cover** when there is none: drop a wall section and hide behind the wreck (§3.8).

### 6.2 Doors, rooms and corners

- **Stack before a door.** Squad members take the baked stack slots either side of an opening and
  report *reached*. The play waits on the replies — a barrier, which is exactly what the order/reply
  system makes possible and string orders did not.
- **Prep the room.** A grenade or a flashbang goes in first; the room graph says which room, and
  whether the player is thought to be in it.
- **Enter and clear.** First through crosses to the far corner, second hooks to the near one — the
  crisscross or button-hook, from baked entry points — and each takes a room corner (a point of
  domination) and sweeps its sector. Rooms are marked **cleared** in the squad's knowledge.
- **Don't use the door.** The doorway is the fatal funnel and the defender is watching it. The
  destruction-native alternative is **mouse-holing**: blow a hole in the wall beside the door —
  chosen by the grid for the thinnest bricks and an angle the defender is not covering — and enter
  through that. Real urban doctrine, and only this game can do it everywhere.
- **Slice the pie.** Approaching a corner, the agent swings wide and sidesteps in small arcs,
  checking each new angle, rather than walking round it. It leans out the side the corner's
  handedness gives it, so it shows the least of itself.
- **Hold angles, not doors.** Defenders split the openings into sectors so each approach is covered
  once, and they stand back from the opening, not in it. The room's opening list says what there is
  to cover.

### 6.3 Squad plays

- **Suppress and push**, **bounding overwatch**, **orderly advance in file** (F.E.A.R.), with masked
  moves.
- **Flank** — a route chosen for being out of the target's view the whole way, called out when it
  starts.
- **Flush** — grenades into the cover or the room the player is in; a building brought down on a
  player who will not move.
- **Search in pairs** over the room graph from the last known position, rooms marked cleared, the
  spiral outside.
- **Fall back** on losses or broken morale to rally cover, then **hold a chokepoint**.
- **Bait** — one member deliberately draws aggro (§8) while the rest move.
- **Reload push** — rush or suppress when a target reloads (Red Dawn), and hold when a squadmate
  reloads.

### 6.4 Against mechs, and as mechs

- **Infantry against a mech:** get into a building it cannot enter, go up to floors that would not
  hold it falling (§3.11), and fire anti-armour from windows. Up close, circle it: the mech aims as
  freely as a player (A15), but its torso turns at 240 °/s and its legs lag behind that. Rodeo when
  it is close.
- **A mech against infantry:** it cannot follow them in, so it takes the building away — crush the
  cover, open a wall, or walk onto an unrated floor and drop through on them (§3.11). That loop —
  hide in a building, the building stops being there — is the game's signature.
- **Mechs with infantry:** the infantry screen, and advance in the mech's lee; the mech spends its
  dashes and smoke protecting them.

### 6.5 Callouts

F.E.A.R.'s cheapest trick, and here it is also a mechanic. Every play start, state change and
discovery emits a callout — *flanking left*, *smoke out*, *reloading*, *mech's on the second
floor*, *he's behind that wall*, *man down*. They make a cover move read as a plan, they tell the
player what is coming (which is what makes a hard fight fair), and friendly callouts from the
player's own squad and mech are information the player uses.

**Subtitles for now (A18), and a talking marker.** A callout reaches a player only if they can
**hear** it — the speaker is inside that callout's range (a shout carries further than a mutter).
Then:

| Player can hear it and... | Shown |
|---|---|
| **can see the speaker** — inside the view, and a sight ray from the camera reaches them | the subtitle, **and a talking marker over the speaker's head** for as long as the line lasts |
| cannot see them, and they are an **enemy** | the subtitle only, unattributed. **No marker through walls** |
| cannot see them, and they are a **friendly** | the subtitle, attributed, **and the marker, drawn through walls** — the player's own squad and mech are always locatable |
| cannot hear it | nothing. The squad still acts on it |

The sight ray is the same physics ray as perception, on `Layers.HITSCAN_MASK`, plus the smoke test
— so wreckage and smoke hide an enemy speaker too. It costs one ray per enemy line spoken, and a
squad speaks a few lines a second at most; friendly lines need no ray at all. **Seeing enemy
markers through walls is left as a possible player upgrade** — it is the same flag friendlies
already have.

Rate limits keep it readable: one line per squad per couple of seconds, repeats suppressed, and
urgent lines (*grenade!*) jump the queue. In co-op each player gets their own set, from their own
position and view.

---

## 7. LimboAI, used as it is meant to be used

- **The HSM is the lifecycle and nothing else:** `Swarm row → Directed → Smart → Piloted → Down →
  Dead`. The level-of-detail tiers of §10 *are* HSM states, so promotion and demotion are
  transitions with enter and exit hooks.
- **Behaviour lives in trees.** One tree per archetype, built from shared subtrees (`BTSubtree`):
  Evade, TakeCover, Engage, Stack, Clear, Search, FollowOrder. The root is a dynamic selector —
  Evade, then Order, then Engage, then Idle — so a new threat pre-empts whatever was running.
- **Blackboard scopes carry the hierarchy.** An agent's blackboard reads through to its squad's,
  which reads through to its faction's. Play, target and slots live one level up. Variables are
  declared in a `BlackboardPlan` per archetype, so a typo is an editor error.
- **Squads and the commander run trees too** (`BTPlayer` on each), in the same debugger.
- **Tasks are thin.** A GDScript task reads the blackboard, calls `AIWorld` for anything that loops,
  and writes the result back.
- **ONNX is a leaf.** `BTRunPolicy(model)` writes the agent's observation into the model's batch,
  reads last tick's action into Intents, and returns RUNNING. It always sits under a guard, so the
  tree decides *when* and pre-empts it. A missing or mismatched model returns FAILURE and the
  selector falls through to the **scripted twin** beside it.

---

## 8. Aggro (A8)

The enemy's attention is a meter shared between the players' side, and whoever it is *not* on is
free to flank. With two pilots and two mechs there are four things to divide it between, and the
pilot/mech split is the fantasy on its own: send the mech in loud, go round on foot.

- **One aggro table per enemy faction**, over every player-side entity. Gain from damage dealt to
  the faction, fire rate and noise, visibility, proximity, and abilities built to draw it. Decays
  over time.
- **Targeting reads it:** attack tokens go to the highest-aggro target; plays weight it; a squad
  that loses a low-aggro pilot is the reward for playing it.
- **Hysteresis:** aggro must lead by a margin before it moves.
- **Shown as a meter** (A8) — per player, with their mech's share beside it.
- **The commander reads its history** (§9), not the current value.

---

## 9. The commander

One per faction **per encounter**. A coarse sector grid (~32 m) of force strength in points, known
threats, objectives, standing buildings and wreckage; it sends Orders, owns reinforcements, and
resolves fights no player is near by Red Dawn's points formula. Its radio is a destructible part.
Event-driven, plus a slow tick. It never pathfinds — it reads the abstract graph of §4.3.

**It carries in a threat profile**, saved with the character (A14) alongside the mech, the guns
and mission progress:

| Profile number | Measured as | The next commander... |
|---|---|---|
| Destructiveness | bricks destroyed, buildings dropped, per minute | fields flyers and mechs that destruction does not stop, and orders better cover discipline — thicker cover by §3.7, nobody in a building under stress, spread out |
| Pilot vs mech damage | share of kills and damage from each | if the pilot does the killing while the mech draws fire, **targets the pilot** and brings fewer anti-mech weapons |
| Aggro history | where aggro sat (§8) | sustained on the pilot → anti-personnel (snipers, flyers, animals); on the mech → rocket infantry and enemy mechs |
| Range and element habits | preferred distance, elements used | counter-picks: close on a sniper, shields that resist the favourite element |

These feed **doctrine** (how units behave) and **roster** (what spawns). They are clamped so no
counter is a hard counter, and they decay so a player who changes style is followed, not punished.

---

## 10. Performance: allowed to be slightly stupid (A10)

The same discipline as destruction ([Plan.md D8](Plan.md#0-locked-decisions), the degradation
ladder in [reddawn §7](Reference/reddawn.md#7-lod-and-activation-bubbles)): **what the player can
check is correct; everything else is allowed to be approximate, late or second-best.** A soldier
that takes the second-best cover a quarter-second late is fine. A frame spike is not.

### 10.1 One scheduler, one budget

`AIWorld` owns a scheduler. Everything is a job — a perception ray batch, a path request, a cover
search, a tile rebake, a what-if, an ONNX batch, a squad tick — with the agent's importance as its
priority, served inside a per-frame millisecond budget. Work that does not fit waits for next frame.
Only **Evade** and **firing** are never deferred.

Starting targets, to be replaced by measurements (60 fps):

| | ms / frame |
|---|---|
| Perception | 0.5 |
| Paths and nav | 0.5 |
| Tactical queries (cover, DDA, danger) | 0.5 |
| Trees (all tiers) | 0.6 |
| ONNX | 0.2 |
| Commander, amortised | 0.1 |
| **Total** | **≈ 2.5** |

### 10.2 Who is smart (A2)

Importance: distance to the nearest player, in a player's view, shooting a player, holding or
targeting aggro, role (mech, leader, sniper), recently hurt. The budget is filled best-first, with
hysteresis and a cap on promotions per frame — the swarm plan's rule.

| Tier (HSM state) | Cap | Brain | Perception | Body |
|---|---|---|---|---|
| **Smart** | ~10 | full tree at 10 Hz, policies allowed | full | full |
| **Directed** | ~40 | reduced tree at 2–5 Hz: follow the squad, shoot what is in front | 2 Hz, per squad | full |
| **Swarm row** | hundreds | `SwarmCore` state machine in C++ on flow fields | census queries | MultiMesh, promoted when close |
| **Abstract** | — | none; a squad is a point on the abstract graph, fights by points | — | none |

A swarm row can be promoted straight to Smart when it matters; a demoted agent keeps its health and
knowledge.

### 10.3 The rules

1. **Amortise everything.** Agents tick staggered across frames by id; nothing but evade must
   finish this frame.
2. **Stale is fine.** Cover scores up to half a second old; knowledge at 2–5 Hz; the commander at
   about 1 Hz.
3. **Cheap test first, exact test on demand.** AABB before DDA; spheres for smoke; boxes for danger.
4. **Precompute at load.** Tactical points, stacks, corners, entry points, the abstract graph — all
   baked from recipes.
5. **One query for many.** A squad cover search returns points for every member; one sight check
   per squad per target; one flow field per goal.
6. **Cap everything.** Rays per frame, paths per frame, rebakes per second, what-ifs per second,
   smart agents, ONNX batch size.
7. **Degrade in a fixed order** under load: directed-tier rate, then perception rays, then fewer
   smart agents, then the commander's rate. Never evade, never firing.
8. **C++ for anything that loops; no allocation per tick** — structs reused, as `TitanIntents` is.
9. **Threads after measuring.** Queries run sliced on the main thread first. Moving them to the
   `WorkerThreadPool` needs a read-only view of chunk occupancy, which destruction mutates on the
   main thread; decide that from a profile, not in advance.
10. **Measure with a tool.** An AI stats overlay beside `F1`, and a headless arena probe with N
    agents that reports milliseconds per subsystem — the project's gate culture.

### 10.4 What "slightly stupid" is allowed to mean

Second-best cover · a path that is a little long · far agents moving along the abstract graph with
no body · knowledge that lags a few hundred milliseconds · smoke as spheres · cover life as an
estimate · wreck summaries at 2-stud cells · the commander deciding once a second.

What it is **not** allowed to mean: shooting through a wall that is not there, walking through
wreckage, hiding behind a piece with no collision, or knowing where the player is without having
seen or heard them.

---

## 11. ONNX

### 11.1 Where, in order

1. **Mech combat micro, at the Intents seam.** Observations: the target relative to me, dash
   charges, my defence layers, incoming threats, a few cover rays. Actions: `move_dir`, an aim
   offset, dash, fire, melee. Only smart mechs run it — two to four at a time.
2. **Squad play selection**, learnable by imitation from the scripted squad.
3. **The commander's roster and doctrine.** Last, after the scripted commander has logged thousands
   of decisions. A policy trained to win is not one that is fun to fight.

### 11.2 Where not

Perception, navigation, legality, anything the designer must clamp. Every output passes through
limits — reaction delay, accuracy cap, attack tokens — so difficulty stays a slider.

### 11.3 Runtime and training

- **ONNX Runtime's C++ API in its own GDExtension** (`gdextension/onnx`). `AIWorld` is not in it — it lives in the brick extension (§3.1); only float arrays cross between them.
  **One batched inference per model per AI tick**, at 10 Hz at most. Host only. Small MLPs on the
  CPU; a hand-written C++ forward pass is the alternative if that is all we ever need.
- Confirm the Linux (Steam Deck) build of ONNX Runtime before relying on it.
- **Models declare their contract** — versioned observation and action specs; a mismatch refuses
  to load and the scripted twin runs, loudly.
- **Godot RL Agents** for the training loop; it trains, our extension infers.
- **Train in an arena, not the city:** headless, high time scale, destruction as grid operations
  only, many instances. **Imitation first, reinforcement second.**

---

## 12. Co-op, saving and wreckage

### 12.1 Large wreckage is the host's (A11)

[Multiplayer.md](Multiplayer.md) treats piece transforms as cosmetic. Once large wreckage is cover
and navigation it is not, and there is a gap today that makes it worse:

> **Impact fractures are not logged.** `IslandManager.fracture_on_impact` and `solve_island` break
> pieces apart when they land, driven by local contact points, speeds and the body's orientation.
> None of it reaches `DamageLog` — only `BLAST` and building `SHEAR` are recorded
> (`city_scene.gd`). So two machines can end up with differently broken large pieces, and different
> content hashes for them.

The fix, for large pieces only:

1. **Only the host turns physics into structure** — landing fractures, island solves, and a falling piece shearing a standing building alike ([AIPlan R5](AIPlan.md#11--would-have-forced-a-rewrite)). **Only the host breaks large pieces after they come loose.** Landing fractures and island stress
   solves run on the host and are recorded as commands addressed to the piece — its content hash
   plus **grid-space** cells, never world points, because the piece's transform differs between
   machines. Clients apply those and never fracture large pieces themselves.
2. **While falling:** transforms on the unreliable stream, visible pieces first (Multiplayer.md §4).
3. **When the host's piece settles:** its final transform is sent once, reliably, keyed by content
   hash. The client's piece moves to match.
4. **Small pieces** stay entirely local, deleted fast, and collide with no pawn (§3.5).

The AI only ever looks at the host's pieces, and after this every client's large pieces are the
host's.

### 12.2 Authority

Host-authoritative AI; clients receive bodies. Anything the AI does to the city goes through
`DamageLog` like a player's shot. Loads that break something are `LOAD` entries (§3.10). AI randomness
comes from the seeded RNG (D9); ONNX need not be bit-identical because only the host runs it.

### 12.3 Saving (A14, A17)

Two kinds of save:

- **The character**, Borderlands-style: character, mech, guns (as recipes), mission progress, and
  the commander's threat profile (§9). Persistent.
- **The area**, which is what makes save-anywhere hard. It is saved while you are in the area and
  **reset when the area reloads.** No pieces respawn during play.

**Save anywhere, the exact situation (A17).** Mid-fight, and mid-collapse. It is the
[one-serializer rule](Reference/README.md#the-five-rules-both-projects-converged-on) — the save is
the same payload a joining client needs, so co-op pays for most of it. What goes in:

| | Saved as | Where it already exists |
|---|---|---|
| Buildings | recipe + dead-block list per damaged building | `BuildingRegistry`; Multiplayer.md's late-join record |
| Every piece that came off | `ChunkRecord` (17 bytes a block) + transform + **linear and angular velocity** + settled / asleep | `ChunkRecord`, used for dormancy today |
| Destruction still queued | flushed before capture, with a time cap; anything left over is written as the command it would become | the budgeted queues in `IslandManager` / `city_scene` |
| Pawns | id, archetype and seed, transform, velocity, defence layers, statuses, ammo, gun recipes, HSM tier, squad, current order | — new |
| Mechs | the above + motor state (dash charges, sprint spool), pilot aboard or not | — new |
| In flight | projectiles, grenades (fuse), smoke volumes (time left), danger volumes | — new |
| AI | knowledge tables, aggro table, squad plays and slots, commander state and budget, encounter progress | — new |

What is **not** saved, because it is rebuilt or does not matter: tactical points, the room graph,
nav tiles, wreck summaries (all derived from recipes plus pieces), behaviour-tree running state
(trees restart from the root on restored blackboards), small debris (deleted within a second
anyway), particles, animation.

**What "exact" means.** The same pieces in the same places moving at the same speeds, and the same
enemies knowing the same things. It does not mean the next second plays out bit-identically: Jolt's
contact caches are not saved, so a collapse *continues* from where it was rather than *replays*.
That is the same line Multiplayer.md draws — the outcome must agree, the trajectory need not.

**Checkpoints first.** A checkpoint is a save taken at a quiet moment — nothing falling, no fight —
through the **same** serializer. So checkpoints ship first and nothing is thrown away: save-anywhere
is that serializer plus the in-motion rows of the table. If those prove too hard, checkpoints are
the fallback A17 allows.

In co-op the host saves the area; each player's character is theirs.

---

## 13. Milestones

Replaced by the phased plan in [AIPlan.md](AIPlan.md), which also reviews this design against
the code. Co-op moved to Phase 0 there (A1).

---

## 14. Open questions

One, partly answered: how buildings nobody has touched take part in fights — see
[AIPlan §4](AIPlan.md#4-decisions).
