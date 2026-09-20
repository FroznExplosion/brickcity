# Reference Library

Prior-art notes for **Printed Brick City**, pulled from two of our own shipped-far-enough
Godot projects and from the research those projects did.

Nothing here is a decision for this game. It is the set of answers we already paid for —
architecture that survived contact, numbers that were actually measured, and the traps that
cost a debugging cycle somewhere else. Read the relevant page before designing a system, not
after.

| Page | Source | What it carries |
|---|---|---|
| [mvs-c.md](mvs-c.md) | `C:\Users\lbaun\Documents\mvs-c` | Open-world streaming, authored island, Gerstner water, vehicles, traffic, squad AI, wanted system, performance discipline, the build process |
| [reddawn.md](reddawn.md) | `C:\Users\lbaun\Documents\reddawn` | Destructible buildings, fracture generation, structural stress, destruction LOD, Forge-style placement, C++ crowd sim, FPS feel |
| [external.md](external.md) | Research in both projects | Third-party addons with verdicts, published techniques, and Godot engine landmines |

Both source projects are Godot 4.6 · Jolt · Forward+ · D3D12 on Windows — the same stack as
this one. Code lifts, not just ideas.

What we actually chose off the back of this is recorded in [`../Plan.md`](../Plan.md).

---

## Spec → reference map

Where to look when you open a section of [`printed-brick-city-spec.md`](../printed-brick-city-spec.md).

| Spec section | Read first | Why |
|---|---|---|
| §4 World — city | [mvs-c §3 Streaming](mvs-c.md#3-world-streaming-and-the-authored-island) | Chunks as pure functions of `(coord, seed)`; buildings as map data, not chunk data |
| §4 World — terrain | [mvs-c §3](mvs-c.md#3-world-streaming-and-the-authored-island), [external — Terrain3D](external.md#godot-addons) | Authored-vs-noise argument; why the far distance is one static mesh |
| §4 World — water | [mvs-c §4 Water](mvs-c.md#4-water) | The spec's water section is *this system* restated in bricks. One function, two evaluators, the whole design already exists |
| §5 Destruction — data model | [reddawn §3 Bake everything](reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact) | Brick connectivity graph = their cell adjacency graph. The flyweight pattern answers "millions of bricks" |
| §5 Destruction — runtime flow | [reddawn §4 Stress](reddawn.md#4-structural-stress-and-collapse), [§6 Clusters](reddawn.md#6-debris-clusters-and-lifecycle) | "Rigid until it hits something" is Chaos-style cluster breaking; already specced |
| §5 Destruction — memory | [reddawn §3](reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact) | "Parametric until touched" = their `< 100 bytes per wall at rest, damage allocated lazily` |
| §5 Budgets | [mvs-c §8 Performance](mvs-c.md#8-performance-discipline), [reddawn §7 LOD](reddawn.md#7-lod-and-activation-bubbles) | How to measure before believing a budget |
| §6 Rendering — chunk meshing | [reddawn §3 Rendering](reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact) | Index-buffer compaction beats re-meshing; never rebuild a trimesh per hit |
| §6 Rendering — studs | [mvs-c §4 Water LOD](mvs-c.md#4-water), [external — MultiMesh](external.md#godot-engine-specifics-and-landmines) | Instance→normal→flat LOD ladders that were measured |
| §7 Guns — parts and sockets | [reddawn §8 Forge placement](reddawn.md#8-forge-style-placement-and-snapping) | Connector snapping is the same OBB corner/edge magnet problem |
| §8 Characters | [reddawn §9 Swarm engine](reddawn.md#9-swarm-engine--c-crowd-simulation), [mvs-c §6 Squads](mvs-c.md#6-ai-squads-and-the-wanted-system) | Rigid parts on bones + zero-node crowds is how thousands of brick figures get affordable |
| §9 Build modes | [reddawn §8](reddawn.md#8-forge-style-placement-and-snapping), [§5 Orientation](reddawn.md#5-structural-orientation--walls-floors-ceilings-roofs) | Free 6-DOF magnetic placement, and why a rotated wall must become a floor. **Adopted in [../BuildMode.md](../BuildMode.md)** — the interaction transfers verbatim, the geometry does not (§4) |
| §10 Asset pipeline | [reddawn §3 Pattern library](reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact) | Bake-time vs impact-time split applies to parts as well as fractures |
| §11 Phase plan | [mvs-c §9 Process](mvs-c.md#9-process--the-gauntlet-loop) | Feature cards, acceptance tests, regression gates, halt-on-regression |
| §12 Open questions — multiplayer | [mvs-c §7 Netcode](mvs-c.md#7-netcode-model), [reddawn §10 MP destruction](reddawn.md#10-multiplayer-destruction) | Host-authoritative + deterministic event streams; do NOT replicate debris |

---

## The five rules both projects converged on

Stated here because they are cheap now and unaffordable to retrofit — and because both
codebases arrived at them independently.

1. **Everything addressable by stable ID, never by node reference.** Anything you hold can be
   freed next frame by streaming or by LOD. (mvs-c `EntityRegistry`; reddawn `wall_id` / cell ids.)
2. **One serializer, three consumers.** Save file, client-join payload and chunk-unload
   persistence are the same operation. Write it once. (mvs-c `WorldState`; reddawn's damage
   bitmask snapshot.)
3. **Pure functions of `(position, seed)` beat authored data you have to stream.** The world,
   the surface type, the water height and the fracture pattern are all derived, so every peer
   agrees without talking and nothing has to be resident to be asked.
4. **Bake at build time, flip bits at impact.** Geometry work — fracture, triangulation, hulls,
   adjacency — never happens on the hot path.
5. **Measure with a tool, not with the fps counter, and close the editor first.** Both projects
   recorded a multi-hour scare that turned out to be a second Godot process competing for the GPU.

---

## Maintaining this library

- Add a page per new source project or research track; keep this index's table current.
- When something here is *adopted*, note the brickcity file that implements it, so the
  reference stops being aspirational.
- When something here is *rejected*, keep the entry and write down why. The expensive part of
  research is re-doing it.
