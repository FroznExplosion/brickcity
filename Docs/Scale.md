# City scale: interiors, destruction, and what other people found out first

How a city of fully destructible buildings *with interiors* is supposed to work, what the shipped
games do, what stops them, and where this project stands against that.

Written because of a proposal worth taking seriously: **bake interiors the way buildings are baked,
draw a cheap version until something touches them, then switch to the real destructible thing —
warm on approach, unwarm if untouched, and resolve an unwarmed room procedurally if it is destroyed
without ever having been looked at.**

Short answer: that is the right shape, it is what the ladder already does for buildings
([Plan §4.2](Plan.md)), and two thirds of it exist. What is missing is the middle rung — and the
proposal's own best idea is the part that names it.

---

## 0. Conclusion first

1. **The proposal is correct and the project half-implements it already.** Rooms have a truth layer
   (a seed and a diff) and a real layer (blocks in the host's grid). They have no *cheap* layer: a
   room is either nothing or fully laid brick. That is the gap.
2. **"Bake interiors like buildings" is the one part to reject**, and there is a measurement behind
   that. Interiors were in the building's face bake until recently; taking them out is what dropped
   a room from 225 ms to 0.9 ms and a furnished building from +50.7 MB to +1.0 MB
   ([Status](Status.md)). The cheap tier must be *drawn from the manifest*, not baked into anything.
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

### 4.2 The promotion rule is "touched", not "near"

Distance decides **drawn**. Interaction decides **real**. A blast whose radius reaches a room, or a
player within arm's reach, promotes rung 2 → 3 for that room alone. Everything else in the building
stays drawn.

This is the pattern the engines use for props: register cheap proxies, swap in the destructible
in place of the proxy on interaction, hide the proxy.

### 4.3 Demotion is the same ladder backwards, and it keeps the diff

Walk away and a room goes 3 → 2 → 1, dropping blocks then instances, keeping only what changed.
This is already how `deactivate_room` works: free the objects, keep the diff.

### 4.4 A room destroyed at rung 0 or 1 resolves, it does not simulate

If a shell nobody ever entered comes down, its rooms' contents are computed — thrown, broken, and
placed — from the seed, deterministically, rather than simulated. This is the proposal's
"randomise the contents" and it is **already built**: `spill_room` and the analytic resolve
([Interiors §5.2](Interiors.md)) do exactly this, down to killing about a third of each item's
bricks from the room's own seed so the same wreck looks the same on a second visit and on another
machine.

### 4.5 Never ask a question proportional to the building

Every per-tick decision is over the *neighbourhood*: the cell the player is in and its neighbours.
Not a radius over everything that exists. This is the single lesson that cost the most to relearn —
a streaming pass was 183 ms because it measured every room in a 4,000-room building fifteen times a
second.

### 4.6 Bound the debris, and say so

A hard cap on live dynamic bodies, with the smallest and oldest discarded first. Teardown ships this
as a user setting. Pretending the cap does not exist is how a collapse becomes a slideshow.

### 4.7 Structure is destructible; the *frame* of the game is not

The design answer, stated up front rather than discovered late: some things do not come down.
Terrain, level borders, and — probably — a load-bearing core per building. Geo-Mod 2.0 drew that
line and shipped.

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
| Neighbourhood queries | cells + portals | ⚠️ lattice lookup + storey span; portals are raycasts | a real neighbour graph |
| Instanced drawing | one draw per chunk | ✅ `FurnitureMesh` MultiMesh | — |
| Collision merging | merge at rest | ✅ buildings and settled islands | falling pieces still per-brick |
| Debris cap | hard, with discard | ⚠️ budgets and dormancy, no hard cap | a cap, and a setting for it |
| Determinism | integer, reproducible | ✅ integer stress, seeded contents, command replay | keep floats out |
| Authoring cost | procedural | ✅ recipes and seeds | — |
| Design control | authored limits | ❌ nothing is protected | decide, then enforce |

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
2. **A neighbour graph.** Replace "rooms within R metres" with "the room you are in, and the rooms
   it connects to". Storey-span was 90% of the win for 10% of the work; the graph is the rest of it,
   and it also replaces the raycast portal test with a walk.

Everything else in the table is a tightening, not a hole.

---

## 6. Honest limits of this write-up

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
