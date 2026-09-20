# Reference — External: addons, techniques, engine landmines

Research already done by [mvs-c](mvs-c.md) and [reddawn](reddawn.md), consolidated. Verdicts are
theirs; the "for us" column is the brickcity read.

**Verify the `LICENSE` file in a repo at the moment you adopt it.** Licences change, and what is
recorded below is what was found during research, not a legal opinion.

Verdict vocabulary:

- **Adopt** — take it as a dependency.
- **Reference** — read the code, lift the patterns, do not depend on it.
- **Defer** — right tool, wrong milestone.

---

## Godot addons

### Adopt

| Package | Licence | Purpose | For us |
|---|---|---|---|
| [LimboAI](https://github.com/limbonaut/limboai) | MIT | Behaviour trees + state machines, editor, visual debugger | **Use the GDExtension build — no engine recompile.** The GDExtension variant is slightly feature-reduced vs the C++ module; that gap never mattered in either project. reddawn's whole enemy AI runs on it |
| [netfox](https://github.com/foxssake/netfox) — `NetworkTime` only | MIT | Shared fixed tick across host and clients | Adopt the timing core early; cheap, and every later system hangs off a consistent clock. **Do not adopt `RollbackSynchronizer`** (see below) |
| [Terrain3D](https://github.com/TokisanGames/Terrain3D) | MIT | GPU clipmap terrain, region streaming 64 m–65.5 km, up to 10 LODs, 32 textures | C++ GDExtension, mature. Spec §4 names it for the heightfield. **It runs its own region streaming, independent of any entity streamer — keep the two separate and never try to unify them.** mvs-c adopted it on paper and ended up not needing it once the world was authored and bounded |

### Reference — read, do not depend

| Package | Licence | What to take | Why not adopt |
|---|---|---|---|
| [Godot-Open-World-Database](https://github.com/DigitallyTailored/Godot-Open-World-Database) | MIT | **Size-tiered chunking** (small props stream at 8 m, buildings at 16 m, terrain at 64 m); per-frame `batch_time_limit_ms` load budgeting; chunk-based network visibility | Its own README says load/unload "may cause unexpected node deletion", and nested nodes are unsupported. Streaming is the load-bearing wall — own that code |
| [chunx](https://github.com/SlashScreen/chunx) | check repo | Partitioning an *authored* world into streamable chunks — the editor-side tooling problem we will also have | Smaller scope than needed |
| [remram44/godot-multiplayer-example](https://github.com/remram44/godot-multiplayer-example) | MIT | **Character decoupled from Player**, multiple local players on one peer, remote machines puppet the Character directly, initial-sync-on-join | Godot 3. Port the pattern, not the code |
| [expressobits/character-controller](https://github.com/expressobits/character-controller) | MIT | Modular FPS movement — headbob, crouch, sprint, swim, fly. **The feel maths is the value** | Input-driven; ours must be intent-driven so AI can share it. Rewrite the plumbing, keep the curves |
| [savekit](https://github.com/fernforestgames/godot-savekit) · [savestate](https://github.com/youssof20/savestate) | MIT | `collect_snapshot()` / `apply_snapshot()` node-group pattern, `.bak` rotation, schema migration, atomic write | Generic save addons have no concept of streamed chunk baselines |
| [2Retr0/GodotOceanWaves](https://github.com/2Retr0/GodotOceanWaves) | MIT | FFT ocean on `RenderingDevice` compute (Stockham FFT, TMA spectrum, cascades, **foam from the wave Jacobian**, GGX lighting after the *Atlas* GDC talk) | Best-looking water in Godot; no CPU height query, no buoyancy, no rivers. Known problems: tiling at distance, stutter on cascade updates. Lift the foam-from-Jacobian idea and the wind/fetch parameterisation |
| [tessarakkt/godot4-oceanfft](https://github.com/tessarakkt/godot4-oceanfft) | MIT | Tessendorf FFT, compute shaders, quadtree LOD, "basic buoyancy" | Self-described early WIP; its own todo has "Multiplayer synchronization?" open. Its buoyancy is the GPU-readback path we are avoiding |
| [Ocean3D](https://ocean3d.itch.io/ocean3d) | Commercial, USD 2, no redistribution | **The shape of the API we want**: `get_height`, `get_displacement`, `get_surface_velocity_y`, fixed-point iteration to undo the horizontal Gerstner offset. Confirms hundreds of GDScript trig samples per frame is affordable | `RigidBody3D`-only, ocean-only, four waves, closed source on a load-bearing surface |
| [Arnklit/Waterways](https://github.com/Arnklit/Waterways/tree/godot4_0) · [waterways-net](https://github.com/Tshmofen/waterways-net) | MIT | **The flow shader**: two phase-offset samples of the flow map, cross-faded, so scrolling water never visibly resets | Bezier-authored rivers; our water is procedural, so the editor tooling is useless |
| [ueshita/godot-floatable-body](https://github.com/ueshita/godot-floatable-body) | MIT | Tidy drag formulation | Flat surface only, `RigidBody3D` only |
| [Shmupo/GodotBoids](https://github.com/Shmupo/GodotBoids) | check repo | Spatial grid + MultiMesh pattern — 2k agents at 100 fps in pure GDScript | Pattern, not a dependency |
| [yusdacra/godot_boids](https://github.com/yusdacra/godot_boids) | check repo | Rust GDExtension, 2k boids @ 11 ms — proves the extension approach | Language mismatch; the SOA layout is the lesson |
| HungryProton `godot_volumetric_smoke` | check repo | CS2-style responsive smoke: **loose voxel** `FogVolume` expansion that collision-checks outward, stops at walls, flows through doorways. Godot composites overlapping volumes into one buffer so it reads as a single cloud | Only if we want volumetric smoke; hundreds of `FogVolume`s is a real render cost |

### Defer

| Package | Licence | Purpose | Reopen at |
|---|---|---|---|
| [steam-multiplayer-peer](https://github.com/expressobits/steam-multiplayer-peer) | MIT | Steam Sockets as a drop-in `MultiplayerPeer` — lobbies, NAT traversal, no gameplay changes | After direct-IP works. A small change **if nothing above it assumed ENet** |
| [GodotSteam](https://github.com/GodotSteam/GodotSteam) · [GodotSteamHL](https://github.com/JDare/GodotSteamHL) | MIT (Steamworks SDK is free-to-use, not open source) | Full Steam integration; HL adds a lobby/P2P layer | Only for achievements, friend invites, or workshop |
| [Phantom Camera](https://github.com/ramokz/phantom-camera) | MIT | Cinemachine-style follow / look-at / damping / blending; **multi-target framing** | At third person. Its multi-target framing is genuinely useful for a shared-camera splitscreen fallback |
| [Beehave](https://github.com/bitbrain/beehave) | MIT | Behaviour trees, GDScript-native | Only if LimboAI's GDExtension build causes friction. **Pick one; do not run both** |
| [Zylann voxel tools](https://github.com/Zylann/godot_voxel) | MIT | SDF voxel terrain, `VoxelTool.do_sphere()` real boolean carving, collision updates automatically | reddawn vendors it. For us: **probably not** — our destruction unit is a brick, not a voxel field. Keep it in mind only for terrain craters (spec §4 says lower the heightmap and spawn debris, which is cheaper) |
| [Godot Rapier Physics](https://github.com/appsinacup/godot-rapier-physics) | check repo | Drop-in physics replacement with 2D (experimental 3D) fluid simulation | Only if particle-based liquid ever becomes a requirement |

### Not a code dependency

Commercially licensed art (Synty in mvs-c) is a separate track from code dependencies. For us,
**all part geometry is our own parametric output** — see [`brick-part-ai-prompt.md`](../brick-part-ai-prompt.md)
and the AI-authorship constraints in [`printed-brick-city-legal-brief.md`](../printed-brick-city-legal-brief.md) §5.

---

## Published techniques worth knowing

### Water

- **Rare, *The Technical Art of Sea of Thieves*, SIGGRAPH 2018 Talks.** Gerstner ocean, deterministic
  and seeded; the server owns wave parameters and sends them to clients; ships sample the same
  function for buoyancy. **This is the reference implementation of "one function, two evaluators".**
- **Ottosson, *Real-time Interactive Water Waves* (Frostbite, 2011).** Boundary-aware wave
  propagation on a Laplacian pyramid. Research lineage only.
- **Kerner, *Water interaction model for boats in video games*** ([part 1](https://www.gamedeveloper.com/programming/water-interaction-model-for-boats-in-video-games),
  [part 2](https://www.gamedeveloper.com/programming/water-interaction-model-for-boats-in-video-games-part-2)).
  The Just Cause 3 hull model: buoyancy per submerged hull triangle, viscous resistance, pressure
  drag, slamming. Definitive, and far more than arcade boats need — **take the drag terms and the
  planing behaviour, skip per-triangle buoyancy.**
- **Battlefield 6 Season 4 (July 2026)** ships changing sea states mid-match, with waves affecting
  boat handling, mounted-weapon aim and line of sight. Method unpublished, but a replicated
  sea-state parameter set over a deterministic simulation is the standard way to get that. (Also:
  its water maps were crashing RTX 50-series drivers at launch — a reminder that this is the
  expensive end of the feature.)
- **Deep-water dispersion**: `c = sqrt(g·λ / 2π)`. Never author wave speed; derive it, and long
  swells outrun chop correctly for free.
- **The volumetric-water illusion**: large water bodies in ~99% of games are hollow. The surface is
  a displaced plane; "volume" comes from the depth buffer (distance from surface to solid ground
  drives absorption and colour). A `FogVolume` bounded under the surface gives real light
  scattering and god rays underwater and removes the need for fake post-processing.

### Destruction

- **Red Faction Guerrilla (Re-Mars-tered)** — the semantics both projects converged on: cells as
  nodes, edges as shared boundaries with material-derived capacity, anchors as foundations,
  load-flow from anchors, overstress → break, disconnect → detach. Plus the *feel*: a delay with
  dust and audio between "overstressed" and "break", so structures groan before they fall.
- **Chaos / Frostbite cluster breaking** — a detached component falls as one rigid body and splits
  into sub-clusters on hard impact. 10–100× fewer bodies than per-cell debris.
- **Rainbow Six Siege `RealBlast`** — layered surfaces, alpha-mask discard for small holes,
  procedural Voronoi fracture for large ones. Note that Ubisoft *removed* single-bullet
  see-through holes for competitive balance; single bullets now spawn an opaque decal.
- **Teardown / The Finals** — the reference points for "fully destructible level" expectations, via
  voxel grids with Surface Nets / Dual Contouring meshing (the cousins of Marching Cubes that give
  the asymmetric faceted look).
- **Bridson Poisson-disk sampling** + **Lloyd's relaxation with area-weighted centroids** — the
  standard route to fracture cells with no slivers. Full pipeline in
  [reddawn §2](reddawn.md#2-material-aware-fracture-patterns).
- **Flyweight fracture patterns** (Chaos, Frostbite): walls share ~150 canonical patterns rather
  than baking unique data per wall, with 4–8 variants plus mirroring for anti-repetition.

### Crowds

- **World War Z swarm engine** (GDC): density-based climbing and flow-field navigation. The key
  rule is that **climbing is a last resort triggered by density**, not a default behaviour — a
  forward-cone neighbour count crossing a threshold, with a support check below to stay elevated.

---

## Godot engine specifics and landmines

Each of these cost somebody a debugging cycle. Read before writing the system that hits it.

### Geometry and physics

- **Face winding decides the collision normal, and mesh collision is one-sided.** Godot derives a
  face's plane as `(p1 - p3) cross (p1 - p2)`. Generated geometry with reversed winding is
  invisible from above *and* lets rays, bullets and falling bodies pass straight through.
- **Never negative-scale a Jolt shape.** Bake mirrored shape copies instead.
- **`ConcavePolygonShape3D` in a destruction path is the #1 scaling killer.** Trimesh BVH rebuilds
  per hit. Use shared convex prisms plus `body_set_shape_disabled`.
- **Prefer `PhysicsServer3D` RIDs over nodes** for anything with thousands of instances (debris,
  cells). Shapes are RID resources — one shape instance serves thousands of bodies.
- **Jolt's `Body::ApplyBuoyancyImpulse` is not exposed** through Godot's `PhysicsServer3D` /
  `RigidBody3D` API. `Area3D` gravity and damping overrides know nothing about wave height. Do not
  wait for it.
- **A box collider against a triangle-mesh ground jams on every slope.** Both projects ended up
  sampling an analytic height field for vehicles instead of colliding with terrain.

### Rendering

- **Transparency sorts per object, not per instance.** A MultiMesh of transparent instances will
  sort wrong. Use opaque geometry with fake depth colour, dithered alpha, or `depth_prepass_alpha`
  plus opaque-past-a-distance.
- **Depth fog `fog_density` is "the amount of fog at `fog_depth_end`", not a rate.** Writing an
  exponential-fog number (e.g. 0.0016) into depth-mode fog leaves the world with effectively no fog.
- **The sky's own ground colour is visible in the sliver between the last geometry and the horizon
  line.** Set darker than the fog, it draws a grey band across the whole view. Give the fog the
  sky's horizon colour and give the sky's ground the same.
- **View distance is a chain and every link must agree:** camera far plane ≥ guaranteed geometry
  extent, and fog fully closed *inside* the geometry, never past it.
- **Shadow distance, not triangle count, is the real cost of a long view.**
- **Under ~4 samples per wavelength, a displaced surface boils.** Cap wave number per LOD ring
  rather than fading distant surfaces to a mirror.
- **Flat shading without normal arrays:** `NORMAL = -normalize(cross(dFdx(world_vertex), dFdy(world_vertex)))`
  in the fragment shader, on the **world-space** vertex — the world-space form is the one that
  works in Godot 4.x.
- **Screen-space derivatives (`fwidth`) are how you fade a procedural line pattern out with
  distance** without shimmer — directly relevant to spec §2's layer-line shader.
- Godot 4.6 rewrote **SSR** around Hi-Z tracing with half- and full-resolution modes. Half-res is
  the splitscreen budget setting; disable entirely in four-pane.
- **`OccluderInstance3D` is render-only** and safe at every LOD — it never affects
  destruction or physics state.
- Godot 4.4+ has **non-stalling GPU readback** (`RenderingDevice.texture_get_data_async`,
  `buffer_get_data_async`), a few frames late. Recorded so nobody re-researches it; a design that
  needs it has usually taken a wrong turn.

### Navigation

- **Navigation map synchronisation cost scales badly with navmesh edge count**, and physics time
  tracks agent count more closely than anything else. Measured in mvs-c: 1 m cells → 9014 polygons
  and a **184 ms** frame; 2 m cells → 2243 polygons and a **23 ms** frame.
- **Never bake a navmesh at runtime on dense geometry.** Pre-bake into the scene file, or bake on a
  worker thread through a serialised queue with a radius limit. Use `NavigationObstacle3D` for
  runtime dynamic blockers.
- `NavigationServer3D.map_get_path()` is thread-safe and can be batched — which is what makes
  shared flow lanes cheaper than per-agent agents.
- **Culled bodies must have their avoidance switched off explicitly**, in the cull path, not in the
  brain — the brain is exactly what is not running.

### Multiplayer

- **`is_multiplayer_authority()` is per-peer.** With local splitscreen one machine drives two pawns
  and it returns `true` for both. Route input by device, then slot; use authority only for
  replication decisions.
- **Every `MultiplayerSynchronizer` on an entity must share the same visibility filter.** A
  mismatch between two synchronizers on one entity produces the classic "spawns but never moves" bug.
- **Do not replicate destruction physics or debris state.** Replicate damage *events*; let debris
  diverge; make only the settled outcome deterministic.

### Threading and hitching

- Generation on `WorkerThreadPool` must be **pure maths with no node access**; node building is
  then budgeted per frame (mvs-c: one chunk per frame).
- **GDScript integer arithmetic is not a shortcut past a C++ call.** A hand-written hash noise
  measured **five times slower** than `FastNoiseLite`.
- Watch the hidden cost multiplier: mvs-c's terrain was doing **five** `height_at` evaluations per
  vertex, four of them only to build a normal the grid spacing already implied. Fixing that took a
  chunk from 137 ms to 58 ms — more than every other optimisation combined. Interior normals now
  come off the grid; **chunk-edge normals still ask the sampler**, because a one-sided difference
  there would not match the neighbour and the seam would light differently.

### Measurement

- **Close every other engine instance before quoting a number.** Two competing headless runs
  produced a consistent, entirely fictitious 10× slowdown in one project and swings from 36 ms to
  133 ms on identical configurations in another. Repeat any measurement three times.
- Prefer an **ablation harness** (turn one system off, measure, turn it back on, fresh baseline
  between every pair) over a profiler when the question is "what do I cut", and a **headless census**
  when the question has nothing to do with drawing.

---

## Legal and policy pointers

Not code, but part of the reference surface. Full treatment in
[`printed-brick-city-legal-brief.md`](../printed-brick-city-legal-brief.md).

- Basic brick geometry is not protectable: **Kirkbi v. Ritvik (Supreme Court of Canada, 2005)** and
  **Lego Juris v. OHIM (CJEU, 2010)** both refused protection because the shape is functional.
- But **a 2021 EU General Court ruling confirmed interlocking toy pieces can still receive design
  protection** — EU registered designs last up to 25 years, US design patents 15. Check EUIPO and
  USPTO for anything distinctive from roughly the last 25 years.
- The minifigure is a **registered 3D trademark upheld in the EU**. Avoid its hands, head, and
  torso/hip/leg silhouettes entirely.
- Steam requires **disclosure of AI-generated content**. In the US, content without meaningful
  human authorship may not be protected at all — keep humans authoring designs, parameters and
  final approval.
- Major STL hosts and platforms restrict weapon files, and moderators may not distinguish a toy
  prop from a real design. Check before relying on third-party hosting.
