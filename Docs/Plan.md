# Printed Brick City — Architecture Plan

Godot 4.6 · Jolt · Forward+ · Vulkan · C++ GDExtension for the destruction core.

Implements [`printed-brick-city-spec.md`](printed-brick-city-spec.md). Prior art and the reasoning
behind most decisions below is in the [Reference Library](Reference/README.md) — this document
records what we chose, not why every alternative lost.

---

## 0. Locked decisions

| # | Decision | Consequence |
|---|---|---|
| D1 | **Destruction core is C++ GDExtension from day one** | We start at [reddawn's *end state*](Reference/reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact), not their migration path. No GDScript prototype to throw away. Slower iteration; no port step |
| D2 | **Desktop 60 fps @1080p, Steam Deck 30 fps floor** | Brick granularity is **identical on all platforms** — determinism and fair gameplay. Only presentation scales: simultaneous FULL collapses, LOD0 radius, debris caps, particle density |
| D3 | **5000 buildings, full city** | ~250M bricks if fully materialised. Parametric-until-touched is not an optimisation, it is the only way the game exists |
| D4 | **Studless blocks first** | Studs are render + export geometry. Nothing in destruction touches them. Connectivity is integer grid adjacency |
| D5 | **Grid alignment is never relaxed** | Every block is an integer footprint on the stud/plate grid, from the first block. The integer adjacency test is what the entire stack rides on |
| D6 | **1 stud = 0.35 m, 1 plate = 0.14 m, 1 brick = 0.42 m** | Spec §3's 1:43.75. Player 4 bricks ≈ 1.68 m |
| D7 | **`RigidBody3D` for clusters, debris and vehicles; `CharacterBody3D` for characters; `PhysicsServer3D` RIDs for intact structure** | `Pawn` must be a **component or interface**, never `extends CharacterBody3D` — GDScript has single inheritance and we need both roots |
| D8 | **Correctness is never LOD'd. Only presentation is** | Cell-accurate damage, stress solve and collision truth run at every LOD. LOD controls how the result is *shown* |
| D11 | **Brick joints fail in TENSION, never compression** | ~4,200 N in compression against ~4 N in tension is a thousand to one, so a stack never crushes and a standing tower is stable forever. Destruction comes from damage, from pieces being pulled off, and from toppling. A released joint **separates** — both bricks survive, because ABS does not pulverise. [Docs/BrickFailure.md](BrickFailure.md) |
| D12 | **The tension constant scales with the world, not with the toy** | Clutch force scales with stud area, weight with volume, so at 0.35 m studs the structure is **43.75x weaker relative to its own weight** than a real one. A full connection holds ~29 hanging bricks here against ~1280 on a desk. Using the print-scale figure directly made walls that could hang anything |
| D13 | **Toppling is a separate question from stress** | Standing structure is a static body, so a building whose base is half gone stays up forever unless something *disconnects*. `check_stability` asks the rigid-body question — is the centre of mass still over what holds it up — and hands the whole building to physics when it is not. Without it a horizontal cut only lowers a tower; it never tips one |
| D9 | **Determinism hedge taken now** | All randomness through one seeded RNG owned by `BrickWorld` — never `randf()` at a call site. Fixed ID iteration order. Impulses recorded in the event log. Costs ~zero now; a rewrite later |
| D10 | **Vulkan on every platform, not D3D12** | Forced by D2: Steam Deck is Linux, which is Vulkan-only, so Vulkan gets tested regardless. Keeping D3D12 on Windows means two backends, two sets of shader and driver bugs, for no gameplay benefit — and shipping the Windows build to Deck via Proton would translate D3D12 → Vulkan through vkd3d-proton anyway. Vulkan is also Godot's primary backend; D3D12 arrived in 4.3 and is less exercised. Ships user-overridable via `--rendering-driver d3d12` |

Multiplayer is not decided (spec §12). D9 means it stays cheap to add.

---

## 1. Constraints

Every structural decision traces to one of these.

| # | Constraint | Consequence |
|---|---|---|
| **B1** | A city is ~250M bricks; RAM is not | **A building is its recipe until something damages it.** Brick data materialises per damaged region, never per building |
| **B2** | Everything breaks, at brick granularity, anywhere, at any time | **No geometry work on the hot path.** Impact flips bits: alive mask, shape disabled, index range excluded, stress edge dirty |
| **B3** | Every model is a print model | **The game mesh and the print mesh are the same authored part**, differing only by decimation and scale. Nothing may be modelled twice |
| **B4** | Save at any instant, including mid-collapse | Alive bitmask + per-brick HP + per-edge strain + every falling cluster's transform and velocity. No safe-to-save state |
| **B5** | The world streams | **No long-lived `Node` references between systems.** Address by stable id, resolve on use |

---

## 2. Core data model

### The grid

Integer, three axes, two units. `x` and `z` in **studs**, `y` in **plates**.

```gdscript
# 2x4 brick lying with its long axis on +Z:
#   size = Vector3i(2, 3, 4)   # 2 studs wide, 3 plates tall (= 1 brick), 4 studs long
```

`cell` is the **min corner**, so a block occupies `[cell, cell + size)` in grid space.
World position is `Vector3(cell.x * 0.35, cell.y * 0.14, cell.z * 0.35)`.

### Connectivity — no geometry, no sockets

```
A connects B  iff  footprint_xz(A) overlaps footprint_xz(B)
                   AND (top_plate(A) == bottom_plate(B) OR top_plate(B) == bottom_plate(A))
```

Pure integer rectangle overlap plus an equality. This is the spec §5 brick connectivity graph,
complete, and it needs no stud geometry to exist.

> **Connector types are a later *filter* on this edge list, not a replacement for it.** When
> slopes, tiles and keyed gun connectors arrive, they remove edges the grid would otherwise
> grant (a tile has no studs to grip). They never add edges.

### The archetype library (flyweight)

Adapted from [reddawn's pattern library](Reference/reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact).
An **archetype** is a part type — `1x1 plate`, `2x4 brick`, `1x2 slope`, later a gun barrel.
Each bakes once, in C++:

- footprint `size` and mass
- **one shared `BoxShape3D` RID** (compound hulls later for slopes) — one shape instance serves
  millions of blocks
- vertex buffer with **per-face contiguous index ranges**, so face culling is index exclusion
- stud positions and connector metadata (unused until studs land)
- `print_axis`, minimum print scale, support flag (spec §10)

Expected count: tens, not reddawn's ~150. Memory in the low MB.

### Mapping from reddawn's model to ours

| reddawn | brickcity |
|---|---|
| fracture pattern `(material, w, h, variant)` | **archetype** (part type) |
| wall = `pattern_id` + transform | **brick chunk** = dense grid region |
| cell within a pattern | **one block** in the chunk |
| alive bitmask per damaged wall | alive bitmask per damaged chunk |
| cell adjacency **baked into the pattern** | stud adjacency **derived from the grid** — cheaper still |
| shared convex prism per cell | shared `BoxShape3D` per archetype |
| index range per cell | index range per block, per face |

### Three resolutions, live at once

This is the refinement over reddawn, forced by B1 and D3. Their model materialises a whole wall
panel on first damage. At 5000 buildings that is still too much, so the connectivity graph runs at
**mixed resolution** (spec §5's hierarchy, made load-bearing):

```
BUILDING   one node. recipe only. no brick data exists.
   └ SECTION   one node while intact. a floor, a wing, a wall run.
        └ GROUP    one node while intact.
             └ BLOCK   materialised only inside a damaged group.
```

Damage expands **only the path from the hit down to blocks**, and only in the groups actually
touched. Flood fill and the stress solve run over the mixed graph — an intact section is a single
heavy node with an edge to the ground, a damaged group is a few hundred block nodes.

Settling collapses the tree back: a quiet damaged group merges into a static chunk, and its blocks
de-materialise to a bitmask.

### Memory budget

| | |
|---|---|
| Materialised block | 16 B (cell 6 B, size 3 B, archetype 2 B, colour 1 B, hp 1 B, flags 1 B, pad) |
| Alive bitmask | 1 bit per block |
| Intact building at rest | recipe + baked mesh handle — spec §5, [under 100 bytes of *state*](Reference/reddawn.md#3-the-target-architecture--bake-everything-flip-bits-at-impact) |
| 50k-block tower, fully materialised | ~800 KB |
| Global cap | 2M materialised blocks ≈ 32 MB, LRU-evicted back to recipe + damage bitmask when quiet and distant |

---

## 3. `BrickWorld` — the resident C++ state

The GDExtension **owns** destruction state. It is not a stateless helper.

```
BrickWorld (C++ singleton)
  archetypes[]      baked archetype library
  buildings[]       SoA: recipe_id, transform, section tree, lod
  chunks[]          SoA: origin, archetype ids, alive bitset*, hp*, mesh index partition
  graph             mixed-resolution nodes + edges; grid adjacency derived, seams baked at placement
  stress            per-edge capacity and strain, per-node load — persistent, never rebuilt per solve
  rng               ONE seeded generator. D9.
```

GDScript API is **deltas only** — never dictionaries of block data crossing the boundary:

```
bake_archetype(desc)                       -> archetype_id
register_building(recipe, xform)           -> building_id
apply_hit(point, energy, radius, explosive)-> HitResult
tick(budget_ms)                            -> events   # overloaded nodes, detached components, dead chunks
get_compacted_indices(chunk_id)            -> PackedInt32Array
serialize() / deserialize(bytes)
```

Rules taken from the reference projects and not up for re-litigation:

- **No `ConcavePolygonShape3D` anywhere in the destruction path.** Trimesh BVH rebuild per hit is
  the documented #1 scaling killer.
- **Bodies are `PhysicsServer3D` RIDs.** One node per *building* at most, for damage routing.
- **Pristine collision is a single shared box at every LOD**, so a projectile can always hit.
  First damage swaps it for a compound of shared archetype shapes; block death is
  `body_set_shape_disabled`, O(1).
- **Rendering is index concatenation.** A block's face range is included iff alive; an interior
  face range is included iff `alive[i] && !alive[j]`. No triangulation, no normal generation, no
  hole clipping, ever, at runtime.
- **Generation and baking run on worker threads as pure maths.** Node building is budgeted per frame.

---

## 4. LOD, and what LOD does not do

Three tiers. Damage, stress and collision truth run identically at all of them (D8).

| LOD | Render | Collision | Simulation |
|---|---|---|---|
| **0** near | per-chunk compacted mesh; MultiMesh for intact | compound of shared archetype shapes | FULL — falling clusters, dust, audio |
| **1** mid | baked building mesh + damaged chunk instances | same, always true | INSTANT-SETTLE — same solve, detached components removed immediately as static rubble |
| **2** far | MultiMesh of building boxes per 512 m cell, never unloads | same, always true | INSTANT-SETTLE, particles only |

### 4.1 LOD alone does not make a city possible

**Measured, and it decides the build order.** A 150 m tower costs **10 MB untouched and 220 MB once
meshed** — and the 10 MB is almost entirely its dense occupancy grid, ~150 cells per block because
the tower is hollow. At 5000 buildings the untouched figure alone is 50 GB.

So a tier ladder does not save anything by itself: an LOD 2 building still holds a dense grid it
has no use for. **LOD tiers need something cheap to point at, and that is the recipe.** The
resting representation comes first, inside the same milestone — not because LOD is less important,
but because the far tiers are meaningless until a resting building costs bytes.

The budget to aim at: 5000 buildings inside a few hundred MB is **well under 100 KB each**, which a
recipe plus a damage record reaches easily. Nothing else in the current representation does.

### 4.2 Three layers, and only the last one is LOD'd

The question "how does damage persist when a building is not at LOD 0" answers itself once the
layers are separated, because **damage never lived in the presentation to begin with**.

| Layer | Holds | LOD'd? |
|---|---|---|
| **Truth** | the recipe, plus a damage record: which block ids are dead, per-block HP, which sections are dirty | **never** — bytes per building |
| **Materialisation** | a real `Block` array and occupancy grid, for a damaged **section** only | by need, not by distance |
| **Presentation** | meshes, physics bodies, debris | yes, by distance |

An undamaged building's damage record is empty and it materialises nothing. A damaged one
materialises the sections that were hit and no more.

**This requires stable block ids**, which means the recipe must be a pure, deterministic generator:
the same parameters always produce the same blocks in the same order, so block id N means the same
brick before and after de-materialisation. `TowerRecipe` is already written that way; it now has to
be a guarantee with a version stamp, and a stale stamp must invalidate saved damage rather than
silently misapply it (mvs-c's `LAYOUT_VERSION` lesson, Reference/mvs-c.md §3).

### 4.2b The presentation layer has three tiers, not two

"Shell or bricks" was one tier too few. Measured on a 5000-building city at 13 m spacing, with the
camera in the middle of it:

| Tier | Range | Per building | 1256 resident |
|---|---|---|---|
| **Bricks** | on damage only | 48k blocks, ~500 MB | — |
| **Shell, course-banded** | < 110 m | ~830 tris | 216 of them |
| **Shell, coarse** | 110–260 m | 10 tris | 1040 of them |
| **Nothing** | > 290 m | recipe + damage record | the other 3744 |

That is **190,940 triangles and 32.8 MB resident, against 712.8 MB** if every registered building
kept a detailed shell. The coarse tier alone accounts for 82% of the saving, and it is justified
by the same argument the banding was: past about a hundred metres a course is thinner than a
pixel, so the geometry that draws it buys nothing.

Both shell tiers keep the same five collision boxes. **A building you can see is a building you
can shoot**, whatever it is drawn with — the ray has to find it so the hit can promote it.

The 30 m hysteresis band on both thresholds is not decoration: without it a building sitting on a
threshold rebuilds its mesh every tick as the camera drifts.

### 4.3 Materialise sections, not buildings

The measurement above is also an argument about granularity. `create_chunk` currently allocates a
dense grid for a whole building — 2.5M cells for the 150 m tower. A rocket hitting one corner has
no business allocating that.

A building is a set of **sections**. A section is the unit that materialises, the unit that gets a
chunk, and the unit LOD 0 is granted to. Intact sections draw from the building's cheap batched
mesh; materialised ones draw their own real geometry. That is spec §5's hierarchy
(building → section → group → block) doing actual work rather than being organisational.

### 4.4 Applying damage and showing it are different questions

A projectile hitting a building far from any player does **not** need that building promoted to
LOD 0. Promotion is about presentation:

1. **Apply immediately, at truth level.** Materialise the hit section, run connectivity and stress,
   resolve the collapse with INSTANT-SETTLE — detached components are removed and replaced with
   static rubble rather than simulated as falling debris. Update the damage record. Rebuild the
   building's cheap mesh so its silhouette is right.
2. **Promote presentation only if somebody can see it.** Falling debris, dust and audio are the
   only things LOD 0 buys.

The end state is identical either way, which is the whole point of D8: a player who walks over
later finds exactly the building the simulation said they would. Reference/reddawn.md §7 and §10
reached the same conclusion, and it is why their activation bubbles survive as a presentation
concern only.

Interest sources forcing LOD 0: players (radius); **impacts, for presentation**; and active
collapses until quiet. Demotion is distance-based after N quiet seconds, with hysteresis.
Promotion queue capped per frame; an explosion's direct target is forced synchronously, neighbours
over the next 1–2 frames.

**Degradation ladder** (D2 — fidelity drops, correctness never): solve budget → promotion cap →
coarser clusters → debris cap → instant rubble → shorter lifetimes → closest-N building budget.

Far-tier rendering follows [mvs-c's `BuildingMap`](Reference/mvs-c.md#3-world-streaming-and-the-authored-island):
buildings are **map data, not chunk data**, drawn from a MultiMesh per 512 m cell that never
unloads, at ~50 draw calls.

---

## 5. Milestones

Each is a working, playable thing. Every one carries a Feature Card and runs the
[Gauntlet Loop](Reference/mvs-c.md#9-process--the-gauntlet-loop).

| M | Milestone | Proves | Deliverables |
|---|---|---|---|
| **M0** ✅ | Blocks exist | The grid and the C++ boundary | GDExtension scaffold building against 4.6; `BrickWorld`; archetype library; grid ↔ world transform; one hand-placed tower rendered from a chunk mesh with face culling; a debug camera. **Measured: 824 blocks, 36,256 triangles, 82.9% of faces culled, 3.2 ms mesh build.** `tools/m0_probe.gd` passes 22 checks including mesh determinism |
| **M1** ✅ | Blocks break | Spec §5 runtime flow, end to end | Connectivity graph; `apply_hit` flipping bits; local flood fill; detached group becomes **one `RigidBody3D` cluster** that stays rigid until it hits something. **Measured: 824 blocks on 824 shared shapes (4 distinct), grounding solve 0.05–0.33 ms, 74 blocks detaching as 3 clusters.** `tools/m1_probe.gd` passes 37 checks |
| **M2** ✅ | Towers fall | B2 and the budget | Stress/anchor solve, cascade over successive ticks, crushing, settling. **Gate: a 150 m tower collapses with 3 of 302 frames over 33 ms, worst frame 128 ms, mean 17.4 ms** — not a clean 60 fps hold, but from ~1 fps for three seconds. 16,590 blocks; stress solve 6.6 ms. `tools/m2_probe.gd` passes 26 checks |
| **M2b** ✅ | Islands are chunks, parts are not boxes | Spec §5 secondary impact, spec §2 curves | A detached island IS a chunk — own grid, own connectivity — so it can be shot, re-solved and split when it lands. Archetypes carry an occupancy mask plus stud/socket masks, so nothing downstream assumes a box. **Measured: impact fracture fires at both scales (17 m: 1 landing cost 41 blocks; 150 m: 4 landings, 3 splits); island collision via `PhysicsServer3D` RIDs instead of nodes.** `tools/m3_probe.gd` passes 41 checks |
| **M2c** ✅ | The gate closes | B2 | Faces baked once, damage flips index slots; the surface is created once and patched in place. **Cascade step 213 ms → 22 ms, worst step 2654 ms → 67 ms.** Three separate quadratic traps found and fixed |
| **M3** ✅ | Buildings are recipes | B1, and §4.1 says these are one job | `BuildingRegistry`: recipe + transform + damage record, bricks materialised on first damage, given back on trim. **Gate met: 5000 buildings registered in 19 ms holding 0.0 MB and 0 chunks.** 12 hits materialise 12 buildings at 4.8 ms each; trimming returns to 0.0 MB with the damage kept. Damage survives de-materialisation — 735 standing, freed, rebuilt, 735 standing |
| **M4** ⚙️ | A city that breaks | D3 and the LOD ladder | `scenes/city.tscn`: 22 buildings, mixed heights, 13 m apart. Undamaged ones hold **no bricks** — a recipe, a 695-triangle shell and five boxes; shooting one promotes it to bricks in ~42 ms. Debris budget: unseen small pieces are never spawned, single bricks draw from a shared MultiMesh, anything under 10 blocks is swept after 6 s. **Measured: 22 buildings in 12 ms holding 0.00 MB; 11 toppled; mean frame 18.7 ms, worst 143.8, 8 of 303 over 33.3 ms.** Still missing: streaming, LOD 1, de-materialisation of quiet buildings |
| **M5** | Studs | D4 pays off | Stud geometry layer, stud LOD (instanced → shader → none), layer-line shader, connector-type edge filter. One implementation serves bricks, terrain and water — [Docs/Terrain.md §5](Terrain.md) has the rule, the three tiers and the faked contact shadow, and argues the work lands inside terrain's T2 |
| **M6** ⚙ | Build mode | Spec §9 | Workshop, stud placement, frames for sideways building, fixtures. Scoped to **buildings** — [Docs/BuildMode.md](BuildMode.md) §11 has the staged order. **Stages 0–4 done**, and the seam Stage 4 left open with them: the part palette, an editable chunk, a workshop whose builds register as buildings and break like them, eight grid-legal orientations on two-bit face masks, frames — sideways building on an exact tick lattice, welded, with grounding that crosses a weld — and **a multi-frame build placed in the city**, and **Stage 5, fixtures**: welds are part of the recipe, a `Building` holds an `Assembly`, every frame draws, collides and takes damage with a record of its own, every building in the city has a dormant spiral staircase in it — masked wedge archetypes, eight steps a revolution, in no solve at all until something wakes it — and `K` in the workshop attaches one to a build, carried in the recipe like everything else. §11 is complete, and so is the cheap tier a player creation needed to live in the city (§12 question 3): a build's shell is a voxelised silhouette of its own recipe, exact about damage because it walks block ids, so a creation streams and trims like anything else |
| **M7** ⚙ | Terrain | Spec §4, and that the ground should be made of the same thing buildings are | **Palettised voxel sections near, derived heightmap far** — ~42 MB for a diggable, cave-bearing square kilometre, against 1.05 GB if `Chunk` held it. Brick-tall voxels with an auto-tiled slope layer on the surface so a hillside is walkable; the surface is **packed, not greedily merged** — a stateless hashed cut rule lays 1×2, 1×6, 2×4 pieces with staggered joints, so the ground reads as built and craters throw recognisable bricks; studs by the M5 layer, `add_chunk_shapes(..., merge)` for collision, hashed scatter for grass and rock, prefab stamps for arches and boulders. **Terrain is a chunk, so `apply_hit` digs it with no new code.** [Docs/Terrain.md](Terrain.md) §14 has the staged order and §16 what is built. **Slice 1 done and probed: T0–T2b, T4, most of T5.** Measured on 25 tiles — 5147 pieces over 25,600 cells, 2×4 is 35% of the ground by area, 29,096 triangles, `build_tile` 0.55 ms a tile |
| **M8** ⚙ | Water | Spec §4's brick-film water | One vertical-only wave function in `BrickWorld`, sampled identically by the shader; brick-step quantisation; four tiers from real pieces to colour banding; opaque absorption off the terrain heightmap; buoyancy, swimming, waterline split. [Docs/Water.md](Water.md) §10 has the staged order. **W0–W3 done and probed**; the probe checks the C++ and packed-shader forms of the wave agree to 4e-7 m. §2.1 records the sea state the probe corrected |
| **M9+** | Everything else | — | Guns, characters, vehicles, export pipeline — see spec §11 |

**M3 sits before M4 deliberately.** The recipe/materialise boundary is what makes 5000 buildings
possible at all; building streaming first means writing the memory strategy twice.

---

## 6. Standing gates

Run against every feature before it is accepted.

| Gate | Check | Live from |
|---|---|---|
| **G1** | Damage state survives LOD demote → promote, byte-identical | M4 |
| **G1b** | The cheap representation SHOWS that damage. A building demoted to a shell must not redraw intact | M4 |
| **G2** | Survives chunk unload + reload (walk two chunks away and back) | M3 |
| **G3** | Survives save → quit → load, state identical, **including mid-collapse** | M2 |
| **G4** | No geometry work on the impact path — profiler shows no triangulation, no BVH build, no hole clipping | M1 (static review + profile) |
| **G5** | No `Node` references held across systems; no `randf()` outside `BrickWorld.rng` | M0 (static review) |
| **G6** | Same seed + same event sequence → identical settled state (which blocks dead, which components detached) | M2 |
| **G7** | Frame budget held at the platform floor with the degradation ladder engaged | M4 |

G4, G5 and G6 are review checks from day zero. They are cheap now and unaffordable to retrofit.

---

## 7. Toolchain

Verified on this machine, 2026-09-15.

| | |
|---|---|
| Godot editor | `C:\Users\lbaun\Documents\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe` (use `_console.exe` for CLI output) |
| Python | 3.13.7 |
| SCons | 4.11.1 — **not on PATH**, invoke as `python -m SCons` |
| MSVC | present; reddawn's extension built with it |
| godot-cpp | reddawn has it generated and compiled against **Godot 4.6.0 stable** — copy or submodule it |

Two gaps to close before M4's perf gate: only `template_debug` is built (need `template_release`),
and there is no Linux build for a native Steam Deck target. Proton running the Windows release
build is acceptable for the first measurement.

Build:

```bash
python -m SCons -C gdextension/brick platform=windows target=template_debug
```

---

## 8. Open questions

1. **Chunk size.** Not decidable on paper. Start at 32×32×32 grid units (11.2 m × 4.5 m × 11.2 m)
   and measure against real building density.
2. **Singleplayer, coop or online?** Spec §12. D9 keeps the door open cheaply; the answer changes
   privacy and ratings obligations more than it changes this document.
3. **Does a slope need a compound hull or does a box suffice for collision?** Box until a gate
   fails.
4. **Where the stress capacity numbers come from.** Material × contact stud count is the obvious
   first form; it needs a tower that falls convincingly to calibrate against.
5. ~~**Terrain.** Spec §4 says heightfield + Terrain3D.~~ **Answered** in
   [Docs/Terrain.md](Terrain.md): **palettised voxel sections near, a derived heightmap far.**
   "Voxel terrain is too expensive" turned out to be true only of `Chunk`'s `int32`-per-cell
   storage, not of voxels — Minecraft spends about a quarter of a byte, and the same split puts a
   diggable square kilometre at ~42 MB. It is worth the ~2x over a pure heightmap because the
   ground then **is** a chunk: `apply_hit` digs it, `find_detached_groups` drops an undercut
   ledge, and terrain destruction stops being a special case. Three spec §4 revisions fall out:
   **Terrain3D leaves the runtime** (§13 there), **no textures** — the seam grid, hashed colour
   jitter and scatter parts do that job instead (§9 there) — and slope pieces on the surface are
   mandatory rather than a biome option, because they are what makes a brick-tall voxel walkable
   (§4, §6), which also closes spec §12's slope question. The city still sits on a flat plate
   until M7. Water's own revisions are in [Docs/Water.md](Water.md) §1.1, §3.0 and §3.4.
