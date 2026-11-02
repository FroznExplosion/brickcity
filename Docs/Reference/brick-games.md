# Other brick and destruction games

Research done 2026-11-02, from public pages only. Nothing here is a decision for this game; §5 is
a menu of features we could take, each with where it would land in our code.

**Sources and their limits.** *Sink My Bricks!* (the closest game to ours) publishes its
development as short TikTok / YouTube videos. Five shorts' transcripts were read (§1.1); the rest
of its techniques are not known -- only its features. The technique notes come from games that write things down:
Brickadia's devlogs (Unreal, millions of bricks), Teardown, and Red Faction Guerrilla's designer's
newer game, Instruments of Destruction. Items marked *(general knowledge)* were not re-read for
this page.

---

## 1. Sink My Bricks! (was *Shiver My Bricks!*)

Sleepy Amigos, three people (Nikolai Egorov solo for most of it), Unreal Engine 5. Steam page and
first trailer 2026-11-02; release and price TBA; PS5 / Xbox being pursued. Renamed October 2026.
Dev videos past 10 M views, 50k+ followers.

| Feature | What it is |
|---|---|
| Co-op | first-person PvE, 1-4 players online, no PvP |
| Run | ~60 min: three procedurally generated archipelagos, a safe island after each, a boss per archipelago, final boss the Flying Dutchman |
| World | islands, ships **and the sea** are bricks; all of it breaks |
| Hull breach | cannon holes let water in; the crew **plugs holes with bricks by hand** mid-fight |
| Ship = respawn | while the ship floats nobody dies for good; if it sinks, no respawns -- reach the level end or capture an enemy ship (capture = move your crew's flag) |
| No health bar | hits knock off limbs; reattach them, take a crewmate's, a prosthetic, or a monster's limb that grants a power (with a curse) |
| Pressure | difficulty rises the longer you stay; weather worsens; ghost enemies at night |
| Ship building | modify template ships or build from scratch; modules anywhere; paint sails; draw your own skin |
| Meta | unlocks between runs: weapons, ship modules, parts, rule-changing artifacts -- never permanent stat boosts |
| Minimum PC | i5-8400, 8 GB, GTX 1050 Ti (4 GB), DX12. No performance numbers published |

### 1.1 What its dev shorts say (transcripts, 2026-11-02)

| Short | What they do | Us |
|---|---|---|
| [Ocean that follows you](https://www.youtube.com/shorts/BrtSAGVzesU) | the ocean's detail moves with the camera so you never reach its edge: three rings -- small bricks, larger bricks, then a flat surface with a water material | **the same**: tier 0 pieces snapped round the camera, the coarse ring, the sheet (Water.md 3) |
| [Voxel ocean](https://www.youtube.com/shorts/alkBYN1nI70) | FFT waves (wave spectrum + inverse FFT, as Sea of Thieves and Black Flag) give a displacement map that also moves points sideways; rigid bricks moved sideways overlap and leave holes; moving them only up and down loses the choppiness ("rolling hills"). **Fix:** each brick stays in its column and finds its height by *inverting* the sideways shift -- start at the brick's own position, see where that point is carried, step back by the miss, repeat 2-3 times -- then read height and foam there | **different.** We chose a vertical-only sine sum (Water.md 1.1), partly because sideways displacement "shears the stud grid". Their trick keeps every brick on the grid *and* gets sharp crests. Worth a look by the water area; FFT itself is harder for us (the CPU has to give the same heights for buoyancy, Water.md 1), but the inversion works on a Gerstner sum too |
| [Ghost ships](https://www.youtube.com/shorts/eFA2LoEvL-g) | every ship (and character) has a **ghost double**: a still copy of the ship's collision far away; a character who boards walks on the ghost, and the camera stays on the real ship at the same ship-local position. No jitter, no collision rebuilt as the ship moves, a walk map baked once. Rejected: Unreal's moving-base movement (laggy) and plain ship-local movement (fixes jitter, not collision or walk maps) | **adopted into the plan** ([../Hulls.md](../Hulls.md) 7b). Today a moving ship puts its brick collision away, so nobody can walk inside one while it moves |
| [Mesh to bricks](https://www.youtube.com/shorts/vLCg_JG9omE) | voxelise the mesh's shell; each voxel's nearest polygons' normal picks a brick, slope or tile by its angle to the horizon; colour = the nearest palette colour by **CIE76** (distance in Lab colour space, because the eye does not see RGB evenly) | **mostly the same** (our converter fits slopes and wedges). Check the converter matches colour in a perceptual space (Lab / Oklab) rather than RGB -- the converter's job (bc-convert) |
| [Octrees](https://www.youtube.com/shorts/WmRWPGaMmxY) | a general explainer: collision found by walking a tree instead of testing everything | nothing new; Jolt does this, and Brickadia's index (§2.1) is the brick-specific version |

## 2. Brickadia -- the technique source

Unreal 5, a brick sandbox in Early Access (EA3, 2026). Everything below is from its devlogs.

### 2.1 Collision for large editable builds (Devlog #4)

- **One custom collision shape per build**, not one shape per brick. The shape holds a spatial
  index; on an overlap it moves the other shape into its local space, asks the index for nearby
  bricks, makes contacts per brick, and moves them back. Concave, one-way.
- Rejected: physics-engine aggregates (re-sort every shape every tick: too slow at 100k bricks)
  and a voxel grid (brick sizes vary ~500x).
- **The index ("OctoBVH")** is an octree with *tight* per-node bounds and *forced splits* of
  overfull nodes (flat stacks of plates otherwise pile into one huge node). Nodes in blocks of 8,
  ~40 bytes a node, up to 8 bricks a leaf.
- **Edits are local.** Insert / remove never rebuilds or rebalances; a node collapses back at 8
  or fewer bricks; forced splits are undone by remembering, per node, the deepest level a forced
  brick came from.
- **Build-vs-build collision** uses a convex hull of the smaller build (from the index's top
  levels), swapped for a box when it is one. A subtree under 1/16 the size of the incoming shape
  counts as a solid box. Player collision always uses full detail.
- **Rays** visit children nearest-first so the first hit ends the search: 104 tests in the right
  order vs 477 reversed; 254 vs 1,129 for a loose octree.
- **Memory reserved once** (VirtualAlloc / mmap) so arrays never move; pages committed as needed.
  No stall when they grow.
- **Render updates batched**: every thread was queueing its own render command; one command per
  frame took the frame from ~30 ms to ~8 ms.
- Client memory roughly halved, server memory cut 3-5x, big saves load 2x faster.

### 2.2 Rendering and scale (Devlogs #2, #5, #8)

- 2 M bricks at 60 fps, 4 M mostly off screen at 87 fps on a GTX 1650 (UE5.1). ~5 M bricks on
  screen at 147 fps on an RTX 4090.
- Brick geometry drawn in **clusters** that skip the engine's per-component overhead; clusters
  merge across chunks. A tick manager updates brick components only when something changed.
- Planned: streaming clusters so only nearby ones stay in VRAM; a vertex layout ~5x smaller.
- **Buoyancy ~10x faster and run in parallel**, now on every entity including wheels.
- Network: sleeping objects no longer polled every frame; animations not evaluated on the server
  unless someone sees the player; melee hits predicted by the client.
- **Debug views** worth copying: brick clusters, colliders with centre of mass and inertia, stray
  physics bodies, overlapping lights, network update sources.

## 3. Teardown

Already used in [../Multiplayer.md](../Multiplayer.md) (commands reliable, physics state
unreliable; ~1 Mbit/s per client, sent by priority).

- Its original destruction had **no structural support**: reviewers noted whole buildings held up
  by a single voxel. A structural-integrity system was later shown as a prototype.
- Physics voxel data is derived at runtime from the render voxels, not stored twice.
- *(general knowledge)* Small cut-off bits become short-lived debris rather than real bodies.

Our joints already fail in tension and weight already flows down ([../BrickFailure.md](../BrickFailure.md)),
so on support we are ahead of where Teardown shipped.

## 4. Red Faction Guerrilla / Instruments of Destruction

Instruments of Destruction (Radiangames, one person, Red Faction Guerrilla's lead tech designer).
Reviews praise a steady frame rate through big collapses, dust and rubble.

- *(general knowledge)* Guerrilla solved stress on a **simplified support graph** of large pieces,
  not per brick, on a budget across frames. That is what our storey units already do.

**Ship games** *(general knowledge)*: Stormworks and From the Depths flood **one sealed
compartment at a time** -- a flood fill of the air inside the hull finds compartments; a hole
connects a compartment to the sea; water rises in it at a rate set by the hole's size; buoyancy
comes from each block's displaced volume. From the Depths is known for slowing down with very
large block counts, especially online.

---

## 5. What we could take

Ordered roughly cheapest and most useful first. Each says what it is, where it would land, and
what is unknown. None of it is started.

### A. Engine and performance

**A1. Debug views for bricks** -- *small.* Overlays like Brickadia's: band and section bounds,
collision shapes per band, centre of mass of loose pieces, physics bodies that never sleep, live
counts against the caps. Lands in a debug toggle in `CityScene` / `IslandManager`. Helps every
destruction bug hunt.

**A2. Batch loose pieces' render updates** -- *small to medium.* A loose piece today is a
`RigidBody3D` with its own `MeshInstance3D` (`IslandManager`, ~line 1405). Pieces that share a
mesh could draw from one `MultiMesh` written once a frame. Unknown: how much this costs us now --
measure first (`viewport_get_measured_render_time_gpu` and the CPU tick, editor closed). The live
caps (80 / 24 / 96) may already keep it small.

**A3. Reserve memory up front for the first hit** -- *medium.* The first hit on a building turns
its recipe into bricks; growing arrays there can stall (the user's "first-hit lag"). Pre-size the
C++ brick arrays per building from the recipe's brick count, or reserve a pool, so materialising
never reallocates. Lands in `BrickWorld` (C++). Measure the first-hit tick before and after.

**A4. Collision that edits locally** -- *large.* Brickadia's one-shape-plus-index. Ours is one
static body per band (`BuildingCollision`), so a hit rebuilds a whole band. The full version needs
a custom Jolt shape, which Godot does not expose -- it would mean reaching below Godot's physics
API in the GDExtension. A cheaper step first: smaller bands near the damage, or rebuilding only
the touched part of a band's compound shape. Only worth it if band rebuilds still show in the
worst tick of a collapse.

**A5. Nearest-first ray order** -- *small, if it applies.* Wherever we ray-march our own brick
structures in C++ (hit tests, line of sight), visit children nearest-first and stop on the first
hit.

**A6. Batched, parallel buoyancy** -- *with water.* Water.md already plans one batched
`sample_wave_heights` call. When buoyancy is built, sample every floating thing in one call and
spread it across threads, as Brickadia did.

### B. Gameplay (from Sink My Bricks)

**B1. Hull breach and flooding** (planned in [../Hulls.md](../Hulls.md)) -- *medium to large; needs water.* A hole in a ship's hull floods
the compartment behind it; water rises at a rate set by the hole's size; the ship lists and sinks
when enough compartments fill. Compartments found by a flood fill of the hull's inside air when
the ship is built (`ship_build.gd`), re-run only for the compartments a hit opens. Works for
space too: a breach vents air instead of taking in water.

**B2. Patch holes with bricks in combat** -- *small once B1 exists.* A quick-place mode of the
build tools usable mid-fight: aim at a hole, place a plate, it seals the compartment. Gives the
building tools a combat job.

**B3. Ship (or mech) as respawn point** -- *small to medium.* While your ship / dropship / Titan
stands, the crew respawns at it; lose it and respawns stop until you capture another. Fits the
co-op mech direction and the parked ship's gangway (`--gate=hull`). Capture by planting the
crew's flag, as they do.

**B4. Limbs instead of a health bar** -- *medium to large; a design call.* Brick bodies lose
arms and legs; reattach, borrow, or replace with prosthetics or enemy parts that carry perks.
Brick characters suit it, and our first-person arms are already rigid brick hands (`city.tscn
-- --arms`). For mechs: lose an arm and lose its weapon. Clashes with the Borderlands-style shield
and health we adopted -- decide which wins before building.

**B5. Rising pressure** -- *small.* The longer a squad stays somewhere, the harder it gets: more
enemies, worse weather (the disasters already exist), night spawns. A timer feeding the AI
director and the disasters.

**B6. Runs and unlocks** -- *large; a design call.* An hour-long run across generated worlds with
a boss each, and unlocks that open options rather than raise stats. We already have generated
star systems and worlds; this is a game-structure decision, not a system.

### C. Where they are ahead and we have only groundwork

- **Multiplayer:** they ship 4-player online. Ours is the deterministic groundwork
  ([../Multiplayer.md](../Multiplayer.md)), no transport or server yet. Brickadia's lessons for
  when it is built: never poll sleeping objects; don't run animation on the server for unseen
  players; predict melee on the client.
- **Water:** theirs is brick, breakable, and floats ships. Ours is further than first written
  here: real brick pieces near the camera, swimming, and flowing pools (`BrickPools`,
  [../Water.md](../Water.md) 12.7) -- but nothing floats a ship or floods a hull yet. That plan is
  [../Hulls.md](../Hulls.md).
- **Raw brick count:** Brickadia draws millions of live bricks; we hold tens of thousands live and
  keep the rest as recipes. Fine for play, as long as a busy fight does not have to materialise
  more than the budget.

---

Sources: [Games Press reveal](https://www.gamespress.com/en-US/Co-op-pirate-roguelite-Sink-My-Bricks-reveals-its-Steam-page-and-first),
[sinkmybricks.com](https://sinkmybricks.com/),
[Steam 4433220](https://store.steampowered.com/app/4433220/Sink_My_Bricks/),
[Gamezilla](https://www.gamezilla.it/sink-my-bricks-pirati-a-pezzi-e-navi-da-ricostruire-nel-nuovo-roguelite-cooperativo/),
[Brickadia Devlog #4](https://brickadia.com/blog/devlog-4/),
[#2](https://brickadia.com/blog/devlog-2/),
[#8](https://brickadia.com/blog/devlog-8/),
[PC Gamer Teardown review](https://www.pcgamer.com/teardown-review/),
[80.lv Teardown structural prototype](https://80.lv/articles/this-real-time-voxel-building-demolition-is-so-satisfying/),
[NME Instruments of Destruction](https://www.nme.com/features/instruments-of-destruction-is-a-demolition-simulator-with-great-potential-3178981).
