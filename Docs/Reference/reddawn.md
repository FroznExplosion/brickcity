# Reference — Red Dawn (destruction, FPS, crowds)

**Location:** `C:\Users\lbaun\Documents\reddawn`
**Stack:** Godot 4.6 · GDScript + C++ GDExtension · Jolt · Forward+.
**State:** playable guerrilla-resistance FPS. Destructible buildings with structural stress,
6 vehicle types, LimboAI enemy squads, base capture, prison, civilians, a C++ zombie swarm,
and a documented plan to migrate destruction to a bake-everything architecture.

**This is the closest prior art we have to spec §5 (Destruction), §6 (Rendering) and §9 (Build
modes).** Its destruction docs were written *after* hitting the walls, so they are unusually
honest about cost.

Primary sources: `docs/destruction_migration_plan.md` (1226 lines — the master plan),
`docs/destruction_system_roadmap.md`, `docs/fracture_sliverfree_implementation.md`,
`docs/destruction_addon_extraction.md`, `docs/wall_building_overhaul_plan.md`,
`docs/SwarmEngine.md`, `docs/Bulletpeephole.md`, `FEATURES.md`, `unreal_migration/`.

---

## 1. What exists today

| Piece | Where | What it is |
|---|---|---|
| `DestructionMeshAccel` | `gdextension/destruction/src/destruction_mesh_accel.{h,cpp}` | Merged-mesh builder. 3 draw calls per building (exterior, interior, edge). Rebuilds the merged `ArrayMesh` from raw float buffers when a chunk dies — "50-100× faster than GDScript Dictionary/PackedArray iteration" |
| `DestructionGraphAccel` | `destruction_graph_accel.{h,cpp}` | BFS connectivity over `Vector3i` chunk nodes. `find_unsupported()`, `find_connected_components()`, `classify_explosion(center, radius, vaporize_radius, …)` |
| `DestructionIslandAccel` | `destruction_island_accel.{h,cpp}` | Per-panel cell grounding. `register_panel(id, wall_group, seg_col/row, roles, alive, neighbour CSR arrays, polygon CSR arrays)`, `add_cross_link`, `set_cell_dead`, `get_grounded(id) -> PackedByteArray`, `get_components(id)` |
| `DestructionStressAccel` | `destruction_stress_accel.{h,cpp}` | Load-flow solver. Cells carry `weight / hp_frac / is_anchor / depth / total_load`; edges carry `capacity / hp_factor_at_build / load`. Has a **resident** mode (`register_building`, `solve_resident`) as well as the old stateless `solve(Dictionary)` |
| `DestructionFracture` | `destruction_fracture.{h,cpp}` | Voronoi + brick + plank + glass patterns. `generate_wall_grid(w, h, mat_type, seed_hash)`, `generate_wall_grid_with_boundary_seeds(…)` for cross-panel crack continuity, `clip_impact_hole(polygons, point, radius, …)`, plus an **async** path (`fracture_region_async` / `is_ready` / `get_result`) |
| GDScript layer | `core_systems/destruction/` (17 files) | `structural_building.gd`, `structural_chunk.gd`, `structural_graph.gd`, `stress_solver.gd`, `joint_graph.gd`, `fracture_generator.gd`, `fracture_pattern_library.gd`, `building_materials.gd`, `debris_pool.gd`, `pristine_render_pool.gd`, `building_lod.gd`, `destruction_manager.gd`, `destruction_tuning.gd` |

Collision layer convention: **1** = world/terrain, **5 (bit 4 = 16)** = structural chunks,
**6 (bit 5 = 32)** = falling debris.

---

## 2. Material-aware fracture patterns

From `docs/destruction_system_roadmap.md`. A 2D fracture grid is generated over each panel at
build time. **The grid is metadata only — no mesh cost.** A hit destroys the cell at that point
and the mesh is rebuilt from the remaining solid cells, which produces angular low-poly fracture
edges rather than smooth bullet holes.

| Material | Pattern | Density |
|---|---|---|
| Concrete | Irregular angular Voronoi | 3–5 cells/m² |
| **Brick** | **Rectangular grid aligned to brick courses (~0.3 × 0.15 m), fractures follow mortar lines** | — |
| Plaster | Dense Voronoi, thin brittle shards | 5–7 /m² |
| Wood | Horizontal planks ~0.8 × 0.15 m, splits along grain | — |
| Glass | Dense radial Voronoi, spiderweb from impact | 8–10 /m² |

Behaviour: a single bullet destroys 1–2 cells; an explosive destroys all cells in the blast
radius; adjacent destroyed cells merge into one contiguous hole; **cells share boundaries so
adjacent hits produce seamless breaks**; side hits project onto the panel's 2D plane.

> **For us, the brick row is the interesting one and it is nearly free.** Our fracture pattern is
> not generated — it is *given*, because our cells are literal bricks on an 8 mm pitch. Everything
> downstream of the pattern (adjacency, index ranges, shared convex shapes, stress edges) applies
> unchanged with a pattern generator that just enumerates the brick grid.

### Sliver-free Voronoi, for anything not on a grid

`docs/fracture_sliverfree_implementation.md`. If we ever want irregular breakage (rock, terrain
craters, non-brick props), this is the finished pipeline:

```
1. seeds = poisson_disk_sample(w, h, N, seed_hash)   # Bridson, k=30, r = sqrt(W·H/(N·π))·0.90
2. seeds = lloyd_relax(seeds, 5 iterations)          # AREA-WEIGHTED centroid, not vertex centroid
3. seeds = enforce_min_distance(seeds, 3 iterations) # pairwise push, min_dist = avg_spacing·0.60
4. cells = voronoi(seeds)                            # half-plane clipping
5. snap_boundary_vertices(snap = avg_spacing · 0.08)
6. collapse_near_duplicate_vertices(eps = avg_spacing · 0.05)
7. merge_slivers(r_min = avg_spacing · 0.18)         # inscribed-circle test, merge into the
                                                     # neighbour with the longest shared edge
8. compute_adjacency()
```

Guarantees: no cell's inscribed radius below `avg_spacing · 0.18`; all cells within ~±20% of mean
area; `area_stddev / area_mean < 0.25`; **< 2 ms per wall** on a worker thread; byte-identical
output for the same `seed_hash`.

Why Bridson and not rejection sampling: rejection sampling clusters in patches on unlucky draws,
and **close seed pairs are the root cause of thin bisector slivers**.

Two recorded risks: polygon merge can return a concave result (the rendering path wants convex —
fall back to a convex hull), and Bridson under-samples on long narrow panels (if
`seeds.size() < N · 0.7`, fall back to the jittered grid).

---

## 3. The target architecture — "bake everything, flip bits at impact"

`docs/destruction_migration_plan.md`. **The single most relevant document in either reference
project.** Its core principle is the answer to spec §5's "a city is millions of bricks":

> All geometry work (fracture, triangulation, convex hulls, adjacency, UVs) happens at BUILD/BAKE
> time. Impact time only flips bits: cell alive-mask, shape disable, index-buffer compaction,
> stress-graph delta. **Impact cost is O(1) per cell, independent of wall size.**

### The flyweight pattern library

They do **not** pre-generate unique fracture data per wall. Walls share canonical patterns keyed
by `(material, panel_width, panel_height, variant)` — ~6 materials × ~6 sizes × 4 variants ≈ 150
patterns. Each bakes once, in C++:

- cell polygons + areas + centroids
- cell adjacency + support roles (`FOUNDATION` / `BEAM` / `FILLER`)
- **one shared vertex buffer**: per-cell face triangles + per-half-edge fracture strips, each
  owning a contiguous **index range**
- **one shared `ConvexPolygonShape3D` per cell** — Godot shapes are RID resources, so one shape
  instance serves thousands of walls
- a point→cell lookup raster (e.g. 32×32) for O(1) hit routing

Memory: ~50 KB per pattern variant → **~7 MB for the whole library**.

Per wall at rest:

```
{ pattern_id: int, transform: Transform3D, neighbors: [wall ids], damage: null }
```

**Under 100 bytes.** A 50k-panel city ≈ 5 MB of wall records. Damage state (cell bitmask +
per-cell HP) is allocated **lazily on first damage** — undamaged walls carry nothing.

> **This is spec §5's "buildings are parametric until touched", already designed and costed.**
> Anti-repetition is 4–8 variants per archetype plus mirrored UVs; industry standard, players do
> not notice. Variety via symmetry: rectangles get mirror-X / mirror-Y / 180° (4 orientations),
> squares add 90°/270° (8). Bake reversed-winding index copies and mirrored shape copies — **do
> not use negative scale on Jolt shapes.**

### Collision

- **Pristine wall at any LOD:** a single shared `BoxShape3D`. Cheapest possible, and required so
  projectiles can always hit a wall at every LOD.
- **First damage:** swap box → compound body with per-cell shared convex prisms, via
  `PhysicsServer3D.body_add_shape` with shared RIDs. Microseconds; no cooking.
- **Cell death:** `body_set_shape_disabled(body, idx, true)`. O(1).
- **No `ConcavePolygonShape3D` anywhere in the destruction path.** Trimesh BVH rebuild per hit is
  named as *the #1 scaling killer in the current system*.
- Bodies are `PhysicsServer` RIDs, not `StaticBody3D` nodes. One node per *building* at most, for
  damage routing; the manager maps `body RID → wall_id`.

### Rendering

- **Pristine:** MultiMesh per archetype.
- **Damaged:** its own `MeshInstance3D` whose mesh is the pattern's shared vertex buffer plus a
  per-wall **index buffer compacted from alive cells' index ranges**:
  - a cell's face range is included iff `alive[i]`
  - a half-edge (i→j) fracture strip is included iff `alive[i] && !alive[j]` — this is what puts
    a broken interior face on the exposed edge of a hole
  - pure index concatenation, memcpy-level. **No triangulation, no normal generation, no hole
    clipping, ever, at runtime.**
- Later upgrade path: cell-id vertex attribute + mask-texture shader discard = zero CPU per hit.
- A periodic compaction job can re-merge long-quiet damaged walls back into a static batch.

> **Direct answer to spec §6.** Our "remove covered studs, shared internal faces, fully enclosed
> bricks" is the same operation as their index compaction — and it should be a *bake-time* index
> partition plus a runtime concatenation, not a runtime mesher.

### Resident C++ state

The GDExtension becomes the **owner** of destruction state, not a stateless helper:

```
DestructionWorld (C++ singleton)
  patterns[]      baked pattern library
  walls[]         SoA: pattern_id, transform, alive bitset*, hp*, lod
  graph           cell-level edges: intra-panel (from pattern)
                  + cross-seam (baked at wall placement)
                  + cross-building joints
  stress state    per-edge capacity/strain, per-cell load — persistent, not rebuilt per solve
```

API to GDScript is **deltas only**, never dictionaries of cell data:
`bake_pattern(desc) -> pattern_id` · `register_wall(pattern_id, xform, links) -> wall_id` ·
`apply_hit(wall_id, point, energy, radius, explosive) -> HitResult` ·
`tick(budget_ms) -> events` · `get_compacted_indices(wall_id) -> PackedInt32Array`.

Deleted outright in that design: per-solve full re-marshalling, GDScript BFS island checks,
string-keyed visited/seam caches, and runtime geometric cross-seam matching (**cross-seam
adjacency is baked once when the wall is placed**, since segment seams are known).

---

## 4. Structural stress and collapse

Red Faction Guerrilla semantics, kept because they already match Chaos/RFG:

- **Graph:** cells are nodes; edges are shared boundaries, seams and joints; edge capacity comes
  from material × boundary length; anchors are foundation cells.
- **Solve:** incremental load-flow from anchors over **dirty regions only**, budgeted per frame
  inside `tick()`. Two outputs:
  1. **Overstressed** edges/cells → break (secondary collapse)
  2. **Disconnected** components → detach as falling clusters
- Flavour that sells it: delay + dust + audio between "overstressed" and "break", so structures
  groan before they go.

### Segmentation matters for cost as well as looks

Splitting large walls into 1–2 m panels that tile seamlessly: **remeshing a 2 m panel is ~9×
faster than a 6 m panel**, collapse becomes finer-grained, merged meshes mean zero extra draw
calls, and segment boundaries are natural break points. Adjacent panels **mirror their Voronoi
seeds at the shared edge** so cracks run continuously across the seam, and a hit within
`fracture_radius` of an edge fractures both panels.

### The bug worth memorising: joints must be grounding-aware

Confirmed by playtest, `docs/wall_building_overhaul_plan.md`:

> Placed rotated walls become separate buildings linked by contact joints. When a support wall is
> **cut in half** (not fully destroyed), its top chunks still exist and stay joint-linked to
> neighbours. `inherited_anchor_cells` then makes those joint cells **anchors** for the
> neighbour's solve — *without checking the joint cell is itself still grounded in its own
> building*. Result: the severed top floats, anchored by the roof; the roof is anchored by the
> floating top. A mutual floating-support loop. Cell grounding says "ungrounded" but the joint
> says "held", so nothing falls.

Fix direction: cross-building support must be grounding-aware, which needs an **iterated** solve
(solve grounding → drop joints whose source cell is ungrounded → re-solve until stable), not the
current single pass.

**We will hit this exactly.** Spec §5's hierarchical clusters (building → section → group →
brick) has the same shape: a cluster anchored by another cluster that is itself unanchored.

---

## 5. Structural orientation — walls, floors, ceilings, roofs

The other half of that document, and a real design trap.

Their cell support roles were **panel-local**: cells with low panel-local Y were tagged
`FOUNDATION`. That is correct only when the panel's local bottom is the ground-facing edge — i.e.
an upright wall. Rotate a wall flat and it should become a floor (grounded by the terrain it
rests on) or a ceiling (held up by whatever walls touch it, *from any point*, not a bottom row).
It did not.

Proposed fix: derive a per-panel `structural_kind` from its **world normal**, then branch:

| Kind | Normal | Anchoring |
|---|---|---|
| WALL | roughly horizontal | bottom (world-Y-lowest) edge cells, when ground level |
| FLOOR | roughly +Y, resting | all cells if ground level; else grounded where a wall touches from below |
| CEILING | ±Y, held from below | grounded where **any** wall cell touches, anywhere across the span. No wall contact → falls as a whole |
| ROOF | tilted | ceiling model, plus optional ridge anchoring |

And promote the existing 3D-centroid proximity matcher to the **primary** cross-panel connector
for all adjacent panels regardless of shared axis — two cells connect if their world-space cell
volumes are within tolerance. That is what lets differently-oriented panels cooperate: corners,
wall-meets-ceiling, angled roof-meets-wall.

> **Our version is easier and we should not squander it.** A brick's connection is a *stud*, not a
> geometric proximity guess: connectivity is exact, directional and known at placement. But the
> *role* problem is identical — a plate laid flat across two walls is a ceiling, and "anchored =
> lowest row" will be wrong the first time someone builds a bridge.

---

## 6. Debris, clusters and lifecycle

- **Clustered debris (Chaos-style):** a detached component falls as **one** RigidBody — a compound
  of its cells' shared convex shapes, rendered via MultiMesh or the compacted-index mesh. On hard
  impact, a strain threshold splits the cluster into cells or sub-clusters. **10–100× fewer bodies**
  than per-cell debris.
- **Detached clusters stay shootable.** A cluster keeps its cell ids, its shape-index→cell map and
  a sub-adjacency graph. Shooting it kills cells, recompacts its mesh, disables shapes and re-runs
  connectivity on the sub-graph — so a cluster can split in two mid-air.
- **Lifecycle:** FALLING (rigid) → sleep-detect → **STATIC RUBBLE** (frozen body, still damageable;
  re-damage can split it and wake physics). Pieces below N cells fade out; pieces ≥ N persist as
  interactive rubble.

> **Spec §5 says "detached groups stay rigid until they hit something; on secondary impact break
> down only near the contact; settled rubble merges back into static chunks." That is this,
> line for line.** Take the implementation.

Also planned (roadmap Priority 6): replace per-debris `RigidBody3D` nodes with
`PhysicsServer3D` RIDs + `MultiMeshInstance3D`, pre-created mesh variants per material
(small/medium/large shard), transforms synced to the MultiMesh buffer each frame, RIDs pooled.
One draw call per material/size class.

---

## 7. LOD and activation bubbles

**Two-axis LOD, decided after they got it wrong once:** destruction *correctness* is never LOD'd —
only *presentation* is.

| LOD | Render | Collision | Destruction sim |
|---|---|---|---|
| 0 near | per-instance damaged mesh, MultiMesh pristine | box (pristine) / compound (damaged) | FULL — falling clusters, dust |
| 1 mid | merged batches + damaged instances | same — always true | INSTANT-SETTLE |
| 2 far | block mesh / impostor | same — always true | INSTANT-SETTLE, particles only |

- **Collision truth at all LODs.** Bullets, rockets and AI sight rays pass through holes
  everywhere. This deletes the old "stale LOD-1 box" edge case and the promotion re-test.
- **INSTANT-SETTLE** runs the same stress solve but skips simulating detached components: removed
  immediately, static rubble + scaled particles spawned. **Identical end state, no debris cost.**
- A rocket destroying a wall at LOD 1+ needs **no promotion for correctness** — damage, stress and
  collapse outcome apply identically. The region promotes to FULL only if a player is close enough
  to see debris fall.

Interest sources that force LOD 0: players (radius); **impacts** — a projectile hits the wall's
always-present box collider and the hit handler *synchronously* promotes an activation bubble
(target wall + blast radius + stress-coupled neighbours); and **active collapses** until quiet.

Demotion is distance-based after N quiet seconds with hysteresis. **Damage state persists in C++
across demote/promote**, so a half-destroyed wall at LOD 2 keeps its bitmask and restores exactly
— which also gives co-op deferred damage application for free.

Budgeting: promotion queue capped per frame (~2 buildings), explosion's direct target forced
synchronously, neighbours over the next 1–2 frames.

**Degradation ladder** (fidelity drops, correctness never): 1) solve budget → slower propagation,
2) promotion queue cap, 3) coarser clusters, 4) debris cap → instant rubble, 5) shorter lifetimes
/ particle-only distant collapses, 6) closest-N active-building budget.

**Platform scaling:** fracture cell density is **identical on all platforms** — determinism and
fair gameplay. Only presentation scales (simultaneous FULL collapses, FULL radius, debris caps,
particle density).

---

## 8. Forge-style placement and snapping

`docs/wall_building_overhaul_plan.md` + `unreal_migration/forge_builder.md`. Shipped in Godot,
then ported. Directly applicable to spec §9 build modes and §7 gun assembly.

**What broke first:** a 2 m world grid. A 4-wall room could not connect because the grid forced
adjacent walls into overlapping cells — they either intersected or refused to place. **The grid
was the thing preventing rooms.** It was removed entirely.

**What replaced it — free 6-DOF transform + magnetic snap to the *target piece*, not the world:**

1. Select a palette piece → spawn a translucent **ghost**.
2. Aim → raycast from camera, ghost base at the hit point.
3. **Magnetise.** Pass 1: **corner-to-corner** across OBB corners (this is the room builder —
   walls join end to end). Pass 2 fallback: **corner-to-edge** via closest-point-on-segment, which
   is the T-junction case and works at any angle *because the closest-point test slides along the
   edge* — no exact corner alignment needed.
4. **Rotate** with RMB+mouse (yaw/pitch) and A/D roll, snapping to 15° increments.
5. Hold **ALT** = precise mode: magnet and angular snap both off.
6. Place if not deeply overlapping; auto-group with whatever structures it touched.

Three fixes that made it actually work, each worth stealing:

- **Orientation-aware OBB corners.** Snap must use the real basis (ghost rotation, target world
  basis). The original axis-aligned face-flush ignored rotation entirely.
- **Deep-containment-only overlap rule.** Reject placement only when penetration exceeds half the
  piece extent on *every* axis. The old "any penetration on all 3 axes" rejected every
  perpendicular corner — that was the "room walls won't place" bug.
- **Keep free and snapped rotation separate.** Accumulate a free rotation from input and derive the
  snapped display rotation by quantising. Quantising in place loses small mouse deltas, so the
  ghost stops responding — a real bug they hit and fixed.

Feedback: ghost tints **cyan** when snapped, red when it would bury, green when free; the chosen
target edge draws as an amber highlight.

> **Our connectors are keyed and typed, so snapping is a socket match rather than a geometric
> guess** — but the *interaction* (ghost, free rotation, angular snap, precise modifier, tint
> states, snap-target highlight) transfers verbatim, and the deep-containment rule is exactly the
> right placement gate for parts that must touch at connectors.

---

## 9. Swarm engine — C++ crowd simulation

`docs/SwarmEngine.md` + `gdextension/zombie_swarm/`. Relevant to spec §8: thousands of rigid-part
brick characters.

**Design principles:** zero per-character nodes (they are array indices in C++, not scene-tree
nodes); one draw call via `MultiMeshInstance3D`; **flow lanes, not per-agent paths** (8–16 shared
`NavigationServer3D.map_get_path()` results, recalculated every 1.5 s or when the target moves
10 m); climb only when density forces it.

Struct-of-arrays, `MAX = 2048`: `pos_x/y/z`, `vel_x/z`, `height_offset`, `state`, `health`,
`attack_cooldown`, `path_progress`, `lane_id`, plus a free-list pool.

Spatial hash: 2D grid, **2.0 m cells, rebuilt from scratch every frame** (faster than incremental
at 2k entities), serving neighbour queries, damage detection and density checks.

Per-step forces: seek along the flow lane → separation (0.8 m) → mild cohesion (3 m) → avoidance
of moving obstacles → density-triggered climb. **Characters have no collision shapes at all**;
damage uses the C++ spatial hash, not Godot physics, so no new collision layers were needed.

Budget targets: sim < 1 ms, render < 0.5 ms, nav < 2 ms per 1.5 s, **total < 3 ms**.

Cited as proof the approach works: `Shmupo/GodotBoids` (2k @ 100 fps in pure GDScript),
`yusdacra/godot_boids` (Rust GDExtension, 2k boids @ 11 ms).

---

## 10. Multiplayer destruction

Their conclusion, reached twice (in Godot and again when evaluating Unreal's Chaos):

> **Do NOT replicate physics or debris state.** Replicating destruction physics state is
> unreliable — documented cases where mesh division appears only on the host.

The model:

1. **Server-authoritative damage EVENTS, replicated.** What crosses the wire is
   `(wall_id, hit_point, energy, radius, explosive)` — small, deterministic-ish inputs. Each
   client applies the same events to its own local sim.
2. **Debris is cosmetic and allowed to diverge per client.** Only the **settled structural
   outcome** must agree — which cells are dead, which components detached, final standing state.
3. **Late join = a compact snapshot**: per-damaged-wall alive bitmask (+ cell HP).
4. Per-player LOD is client-side only.

**Determinism scope, stated explicitly:** settled outcomes must be identical for all players —
achieved via quantized HP, integer cell ids and fixed iteration order in the C++ solver. Collapse
*trajectories* are explicitly non-deterministic and cosmetic.

**The cheap hedge for future determinism** (cost now ≈ zero; retrofit cost ≈ rewrite):

1. **All** randomness flows through one seeded RNG owned by the destruction world — never
   `randf()` at call sites.
2. Solver and event processing iterate in fixed ID order.
3. Debris clusters are driven by recorded impulses in the event log, so a future game can replay
   them into a deterministic stepper.

### Save policy

Saving is allowed at **any** moment, including mid-collapse. At save: flush pending stress solves
(fast in C++), then serialise (a) per-damaged-wall alive bitmask + cell HP, (b) per-edge strain,
(c) every falling cluster as `{cell list, transform, linear + angular velocity}`. On load the
clusters respawn as rigid bodies and the collapse continues. No save-on-settle restriction.

**Off-screen destruction:** no real-time simulation away from players. World events feed batched
damage into the same API with INSTANT-SETTLE for unloaded regions; the player sees the aftermath.
Same code path, no physics, no rendering.

### Per-cell HP

Damage state per damaged wall = alive bitset + per-cell HP **quantized to 8-bit** (0–255 scaled by
material max). Persists forever — never decays, never dropped on LOD change. It is both the save
format and the determinism substrate.

---

## 11. Bullet holes — the hybrid rule

`docs/Bulletpeephole.md`, researching how Rainbow Six Siege does it. The useful conclusions:

- Siege's `RealBlast` is layered: **alpha-mask discard** for small see-through holes, **procedural
  Voronoi fracturing** for large ones. Ubisoft later removed single-bullet see-through holes for
  competitive balance — single bullets now just spawn an opaque decal.
- **The hybrid is the shippable answer:** a `Decal` node for standard impacts (cheap), real
  geometry removal only for high-calibre rounds, shotguns and explosives.
- **Track accumulated damage in a spatial dictionary**, rounding the hit to a grid coordinate;
  when a coordinate crosses a threshold, carve for real and clear the entry.
- **Cleanup is the part people forget:** once real geometry is removed, previously placed decals
  float in mid-air. Query the region and delete decals inside the new hole's radius.
- If you fake a hole with a shader mask, the collider is still solid. Either accept that bullets
  do not pass through the fake hole (they did — enemies die fast enough that it does not matter),
  or pay for custom raycast bypass logic, which gets expensive on full auto.
- A world-space distance-mask shader (`uniform vec3 hole_positions[MAX_HOLES]`, `discard` when the
  fragment is within `hole_radius`) is the way to do it on procedurally generated geometry with no
  stable UVs. Keep `MAX_HOLES` small — the cap is a feature, since holes get promoted to real
  geometry anyway.

> **For us the calculus differs:** our minimum destructible unit is a brick, which is already the
> size of a bullet hole at game scale. A single shot should kill 1–2 bricks via the same O(1) cell
> path, and decals are probably only needed for scorch marks. The *accumulate-then-promote* pattern
> is still the right shape for anything sub-brick.

---

## 12. FPS feel, AI and vehicles — inventory

From `FEATURES.md`. Useful when the shooting layer comes up (spec §7); mostly a catalogue of what
exists to copy.

**Weapons:** barrel-direction bullets (not screen-centre aim) · **inverse recoil pattern** (first
shots wild, sustained fire settles) · ADS with FOV zoom and reduced spread · no hip-fire crosshair
· projectile bullets with gravity falloff · camera recoil in pitch *and* yaw · melee · equipment
manager for slots/grenades/launchers/mines/C4.

**Player feel:** procedural weapon animation layer (sway, bob, tilt, breathing, landing impact) ·
wall interaction / weapon retract near walls · corner peeking.

**Enemy AI** (LimboAI, F.E.A.R.-inspired): hierarchical state machine
(Patrol/Idle/Investigate/Combat/Search/Return/Dead) with a 13-branch dynamic-selector combat tree.
16-ray cover scan with scoring and staleness refresh · flanking positions 60–120° off axis with
cover verification · suppressive fire (faster rate, lower accuracy, half damage) · dual detection
ranges (20 m passive, 40 m alerted) · 3 s LOS grace before losing a target · alert spread at 25 m ·
spiral 4-point search · **weapon threat detection** (knife = low, gun = armed, ADS = aiming) with a
hesitate branch at the top of the tree.

**Squad:** shared knowledge (one sees, all know) · 5 tactics · morale (death −0.25, leader death
−0.4, retreat at 0.2) · callout relay · reload-opportunity response (an ally rushes or suppresses
when a teammate reloads).

**Vehicles:** 6 types split between `VehicleBody3D` (jeep, APC) and `CharacterBody3D` with
differential tracks (tank, IFV, helis). Damage-zone routing via `PhysicsPointQuery` on layer 3,
**colour-coded components** (red = engine, yellow = fuel, cyan = tracks, orange = explosive),
trophy/APS intercept systems, engine→ammo→turret damage chains.

**Autoloads:** GameMgr, TimeMgr, AlertMgr, EnemyMgr, CivilianMgr, ExecutionMgr, BaseMgr, POIMgr,
SupplyMgr, PrisonMgr, ExplosiveMgr, CoopMgr, ResourceManager.

---

## 13. Packaging destruction as a reusable module

`docs/destruction_addon_extraction.md`. Relevant because we want this system in *this* game and
possibly the next.

> The addon's **public API is the boundary that protects games from internal change.** Stabilise
> the API and inject the couplings *first*, extract second, refactor internals later — behind the
> boundary, without changing a line in any game.

The whole coupling audit found only four things to inject, which is the point:

1. **Player/interest lookup** — `get_nodes_in_group("player")` in three places. Replace with an
   `InterestProvider` interface returning `Array[Vector3]` of interest points.
2. A dead singleton check. Delete.
3. **Collision layers as magic numbers** — the main hardcode. Centralise into a `DestructionLayers`
   config exposing `WORLD` / `CHUNK` / `DEBRIS`. Doing this *now* is value-identical, behaviour
   neutral, and removes the biggest extraction friction.
4. Autoload registration, which the `EditorPlugin` does.

Public API to keep stable: `build_wall_block()`, `build_segmented_wall()`, `build_hollow_box()`,
`build_multistory()`, `receive_damage(damage, point, is_explosive)`, `apply_explosion(center,
radius, damage)`, `explode_structures_in_radius(tree, center, radius, damage)`, a `BuildingLOD`
manager with `force_lod0_at()`, and signals `chunk_removed` / `building_collapsed`.

Extraction is behaviour-neutral: the gate is that benchmarks match the pre-extraction numbers.

---

## 14. What to take, and what to leave

**Take directly**

- The bake-everything principle and the flyweight pattern library (§3). It is the answer to
  millions of bricks.
- Shared convex prism per cell + `body_set_shape_disabled` (§3 Collision). Never a trimesh.
- Index-buffer compaction for damaged meshes (§3 Rendering) — including the
  `alive[i] && !alive[j]` rule for exposed interior faces.
- Resident C++ destruction state with a delta-only GDScript API (§3).
- Clustered debris and the FALLING → RUBBLE lifecycle (§6).
- Two-axis LOD: correctness never LOD'd, presentation always (§7), plus the degradation ladder.
- The multiplayer model and the three-point determinism hedge (§10) — the hedge costs nothing now.
- Forge placement interaction, the deep-containment rule, and free-vs-snapped rotation (§8).
- The C++ SOA + spatial hash + MultiMesh crowd pattern (§9) for brick characters.
- The addon-extraction discipline (§13): stabilise the API, inject couplings, extract, then refactor.

**Take with a change**

- Fracture patterns. Ours are *given* by the brick grid, not generated — but keep the pattern
  library structure, the variant/symmetry scheme, and the sliver-free Voronoi pipeline in reserve
  for rock, craters and non-brick props.
- Structural roles. Derive from world orientation as they plan (§5), but our connectivity is exact
  (studs), so use the stud graph instead of proximity matching.
- Segmentation. Their 1–2 m panels map onto our hierarchical clusters (spec §5); the ~9× remesh
  argument is why cluster size matters.

**Leave**

- `ConcavePolygonShape3D` anywhere near destruction.
- Per-cell `RigidBody3D` debris.
- A world-aligned placement grid for the build mode (§8) — with the caveat that *our* grid is the
  brick grid itself, which is a piece-local snap, not a world-cell exclusion.
- Their "promotion re-test" edge case — it only exists because collision was once LOD'd, which the
  final design fixed by never LOD'ing collision.
