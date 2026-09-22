# Printed Brick City — Design & Technical Spec

*Working title. Engine: Godot 4.6, C++ GDExtension for heavy systems, GDScript for gameplay glue. Physics: Jolt.*

Companion documents: **Legal & Political Risk Brief** and **AI Part Modeling Prompt**.
Prior art and research: [**Reference Library**](Reference/README.md) — it carries a spec-section →
reference map, so start there before designing any system below.

---

## 1. Concept

A city-sized, fully destructible open world where every object — guns, vehicles, characters, props, buildings — is a real 3D-print-ready model. The look is brick-toy, but shaped by how home FDM printers work rather than by injection molding: more curves, odd shapes, chamfered bottoms, faceted studs. Players can export any model as STL files and print it at home.

### Pillars
1. **Everything is printable.** Game models are the print models, only rescaled and lightly optimized.
2. **Everything breaks like bricks.** Big chunks hold together, then crumble on impact.
3. **Everything is built from parts.** Buildings, guns, and characters are assembled from connectable pieces.
4. **Our own brick language.** Brick-toy feel, clearly our own design.

---

## 2. Art Direction

### Brick house style
| Feature | Our design | Why |
|---|---|---|
| Studs | Slightly tapered, faceted (8 or 16 sides), ~2mm center hole | Reads as "printed"; taper gives good friction fit |
| Bottom edges | 45° chamfer | Printers handle chamfers; rounded bottoms droop |
| Top edges | Small rounded fillet | Distinct silhouette |
| Underside | Straight rib grid | Prints well; distinct from round tubes |
| Surfaces | Flat filament colors, no textures | Matches real prints; very low memory |
| Branding | None on parts | IP safety |

### Layer lines
- Procedural shader, not modeled.
- Computed in object space along each part's stored `print_axis`, so lines tumble correctly with debris.
- Fade out with screen-space derivatives (`fwidth`) to avoid shimmer at distance.
- Toggle in settings.

### Characters and animation
- Stiff, rigid-part animation in the spirit of brick-film animation; not stop-motion by default.
- **Stop-motion toggle:** accumulate delta time and advance the AnimationPlayer in fixed 1/12s steps ("on twos"). Camera and physics stay smooth so it reads as style, not lag.
- Characters must have our own proportions (see legal brief).

---

## 3. Scale & Dimensions

### Brick system (1:1 print scale)
- Stud pitch 8.0mm · plate 3.2mm · brick 9.6mm (3 plates)
- Stud contact diameter 4.8mm, height 1.7mm
- Outer walls inset 0.1mm per side from the grid
- Matches common brick spacing; **never marketed as compatible**.

### In-game scale
- Characters are **4 bricks tall** (38.4 mm in print, 1.68 m in game; one stud = 35 cm), the height real brick buildings are designed around. Our own proportions: a bigger head and a slimmer body; never the minifigure's shape (legal brief).
- Buildings are sized for them: a storey is 6 courses (2.52 m), a doorway 5 bricks clear and 4 studs wide. `tools/scale_probe.gd` enforces all of it; measurements in `Docs/Parts/`.
- Rough density: a 150m tower is on the order of 50k bricks; a city is millions.

### Export scaling
- Per-part scale: small real-world items (e.g. a banana) export at real size; others scale up or down.
- **Clearance is never baked into meshes.** The exporter scales first, then applies clearance per connector type.
- Player settings: scale picker + tolerance slider, informed by a calibration print (§9).
- Minimum feature thickness ~1.2mm at the smallest supported print scale (0.4mm nozzle).
- Exporter warns when a part exceeds a common 220–256mm bed.

---

## 4. World

### City
- Fictional city. No recognizable real skyscrapers.
- Buildings made of bricks; streets smooth; natural ground studded.

### Terrain
- Standard heightfield (e.g. Terrain3D) with Jolt `HeightMapShape3D` collision. Not brick geometry.
- **Studs decided per grid cell:** shader snaps to the world stud grid, samples the normal at each cell center — flat cells get a full stud, sloped cells none. No half-studs melting into hills.
- Terrain grid aligned to the brick grid; flat build zones authored at plate-height steps so placed bricks sit flush.
- Stud LOD: instanced mesh studs near camera → normal/parallax mid-range → flat far.
- Craters: lower the heightmap and spawn loose brick debris together.
- Bonus: export a terrain chunk as a printable baseplate diorama.

### Water
Brick-film look: stepped pieces on top, real waves, swimmable, underwater allowed.

**One wave function drives everything.** Sum of Gerstner waves + wave packets + ripple texture, evaluated identically on GPU (visuals) and in C++ (buoyancy, swimming, boats, knockback).

- **Surface pieces:** height sampled at each stud cell, snapped to plate steps. A camera-following MultiMesh of 1x1 round plates (~50m radius, ~20k instances), height set in the vertex shader.
- **Columns:** each instance stretches down toward the local trough so steps form solid walls from the side and below.
- **Undersides modeled** with the rib grid — visible from underwater.
- **LOD:** instances → stepped mesh with shader studs → smooth surface with color banding.
- **Transparency:** avoid true alpha (Godot sorts per object, not per instance). Use opaque pieces with fake depth color, or dithered alpha.
- **Big waves:** wave packets in the shared function. Curling/overhead waves are a separate spline-tube actor filled with instanced pieces that blends back into the surface; gameplay uses a volume check along the spline.
- **Splashes:** GPU particles using piece meshes that tumble and land.
- **Ripples:** small wave-equation sim on a texture around the camera (compute shader); debris impacts push out stepping rings.
- **Waterline split:** evaluate the wave function along the near plane's bottom edge; underwater effect below, normal view above.
- **Underwater look:** depth fog, color absorption (reds fade first), light shafts, stud-grid-snapped caustics.
- **Swimming states** from wave samples at feet/chest/head: wading, surface swim, dive; optional air meter.
- **Depth:** max ~30m (100ft). Fog limits visibility to ~20–40m, so the seabed reuses the terrain system with no deep-ocean systems.
- **Debris:** a few buoyancy sample points per rigid body; heavy chunks sink, small pieces float.

---

## 5. Destruction

### Data model
- **Brick connectivity graph:** bricks are nodes, stud connections are edges.
- Connected groups become one rigid body with compound box collision.
- **Hierarchical clusters** (building → section → group → brick), precomputed. Floors are not assumed to be break lines.

### Runtime flow
1. Impact breaks edges near the hit, weighted by impulse.
2. Local flood fill finds groups no longer connected to ground.
3. Detached groups become new rigid bodies that **stay rigid until they hit something**.
4. On secondary impact, break down only near the contact; distant parts stay clustered.
5. Settled rubble merges back into static chunks.

### Memory strategy
- **Buildings are parametric until touched:** an intact building is its fast-build recipe (palette, floors, footprint) plus a baked mesh.
- Brick-level data is generated on first damage.
- Saves store recipe + edits only.

### Budgets (initial targets, to validate)
- ~1–3k simultaneously active brick bodies in Jolt.
- Collapse of one large tower at stable framerate on target hardware.

---

## 6. Rendering

- **Chunk meshing in C++ worker threads** (voxel-style): remove covered studs, shared internal faces, and fully enclosed bricks. Rebuild a chunk when a neighbor changes.
- Intact buildings use a baked mesh; damaged regions switch to chunk meshes.
- **Studs are the main polygon cost:** geometry near, normal/parallax mid, none far.
- Vertex colors / flat material slots; no texture memory for parts.
- Characters are rigid parts parented to bones — no skinning, cheap crowds.

---

## 7. Guns

### Acquisition
- **Found as loot**, Borderlands-style: procedural, with manufacturers and rarity.
- **Test mode:** freely assemble guns from parts to experiment.

### Structure
- Parts: **core** (never "receiver"/"lower"), barrel, grip, stock, magazine, sight, accessory.
- Core defines sockets; parts attach by connector type.
- Stats derive from parts; manufacturer rules bias part selection.
- **A gun is a seed + part ID list.** Tiny saves and network sync.
- Runtime: merge chosen parts into one cached mesh (one draw call). Guns can break apart at connectors when destroyed.

### Connector standard (shared by game and prints)
- 3–4 keyed connector types, e.g.:
  - Stud grid — light accessories
  - Keyed dovetail rail with stud/detent lock — barrels, stocks
  - Pin-and-clip — grips, magazines
- Every part in a class uses the same connector, so every generated combination assembles in real life.
- Key shapes define both physical fit and in-game compatibility (one source of truth).
- Connectors are **non-standard**: no Picatinny, M-LOK, or real firearm part dimensions.

### Printing
- Parts orient by stress: flexing clips and pins print lying down so layers run along their length.
- Separate clearance per connector type (friction stud, sliding rail, flex clip).
- Every part solid, no bores, toy proportions, colored tip region.

### Generator validation (hard rules)
- Enforce toy proportions, allowed color palettes, and colored tip on every output.
- Reject combinations that read as realistic.
- Same rules apply to test-mode assemblies before export.

### Balance note
- Loot must be balanced across generated combinations; test mode lets any combination exist, so decide whether test-mode guns can enter normal play.

---

## 8. Characters

- Procedural from parts: head, torso, hips, legs, arms, hands, headgear, accessories.
- Same socket system; each part rigidly attached to a bone.
- **Our own proportions** — signature head, hand, and joint design defined early and enforced by the generator.
- Filament-color palettes so characters look like real printed toys.
- Seed-based storage.
- Printable joints (snap pins / ball joints) with scale-then-clearance export.

---

## 9. Build Modes

- **Brick build:** grid snapping, stud connections, part palette.
- **Fast build:** pick a brick palette, raise/lower by floors, expand/shrink width and depth. Output is a parametric recipe (feeds §5 memory strategy).
- **Other build modes:** vehicles, props — same socket/connector system.
- **Gun test mode** (§7).

---

## 10. Asset Pipeline

1. **Source of truth:** parametric Blender (Python) scripts or CAD, generating watertight print meshes. See the AI Part Modeling Prompt.
2. **Automated game conversion:** decimation, vertex colors / filament material slots, LODs, box collision, separate stud objects, socket empties.
3. **Metadata per part:** `print_axis`, connector types and keys, minimum print scale, support flag.
4. **Exporter:** per-part scale → per-connector clearance → manifold check → bed-size check → license/disclaimer bundled.
5. **Calibration print:** one of each connector type at several clearances; player choices set exporter tolerances.
6. **Human IP review** of every new part before it ships.

---

## 11. Proposed Phase Plan

*Proposed milestones and kill criteria; numbers are starting points to refine.*

| Phase | Goal | Milestone | Kill / rethink criteria |
|---|---|---|---|
| 0 | House style & connectors | Stud, rib grid, and gun connectors test-printed on 2+ printers at 2+ scales | Reliable fit not achievable with a tolerance slider |
| 1 | Asset pipeline | Parametric part → print STL + game mesh + exporter with scale/clearance | Manual cleanup needed on most parts |
| 2 | Destruction prototype | One tower: connectivity graph, clusters, rigid-until-impact collapse | Can't hold target framerate within active-body budget |
| 3 | City scale | Chunk meshing, parametric-until-touched buildings, streaming a city block | Memory or rebuild hitches exceed budget |
| 4 | Guns & test mode | Procedural loot + test mode + printable snap assemblies | Generated combos regularly fail to print/assemble or look realistic |
| 5 | Characters & animation | Procedural characters, rigid animation, stop-motion toggle | Proportions drift toward protected designs |
| 6 | Terrain & water | Studded heightfield, stepped water, swimming, underwater | Waterline split or piece water can't hit visual/perf bar |
| 7 | Build modes | Brick build, fast build, vehicle/prop build | — |

---

## 12. Open Questions

- Target hardware and framerate?
- Singleplayer, co-op, or online? (Drives privacy/rating obligations.)
- Can test-mode guns be used in normal play?
- Is there a sharing hub for player creations?
- Monetization model (affects loot-box rules)?
- Terrain slopes: smooth only, or stepped/slope bricks in some biomes?
- Vehicle construction and physics scope?
- Export license choice (e.g. CC BY-NC)?
