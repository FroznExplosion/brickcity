# Elemental FX Kit — Godot 4.6 (Borderlands-style)

Eight elements: **Ice, Fire, Acid, Corrosive, Shock, Slag, Radiation** + environmental
surfaces (**oil, water, environmental ice**). Built around three performance pillars:

1. **One shared shader, per-instance uniforms.** Every enemy gets the *same*
   `ShaderMaterial` as a `material_overlay`. Element color / coat amount / freeze amount
   are `instance uniform`s set via `set_instance_shader_parameter()`. Zero material
   duplication, zero shader recompiles, batches beautifully.
2. **One ticker.** No per-enemy Timers. A single autoload (`ElementalManager`) ticks
   every active status in one `_physics_process` loop. 500 burning enemies = one loop.
3. **Pooled everything.** GPUParticles3D emitters, shatter MultiMeshes, and puddle
   Decals come from pools. `emitting = true` restarts a pooled emitter; nothing is
   instantiated during combat.

## File map

| File | Purpose |
|---|---|
| `autoload/elemental_manager.gd` | Status ticking, element application, combos |
| `autoload/vfx_pool.gd` | Pooled GPUParticles3D / Decals / MultiMesh shatters |
| `enemy/elemental_target.gd` | Component on each enemy: mesh refs, overlay control, death hook |
| `elements/*.gd` | One StatusEffect class per element |
| `fx/shaders/elemental_overlay.gdshader` | Uber overlay: freeze, coat, pulse glow (all elements share it) |
| `fx/shaders/acid_dissolve.gdshader` | Dissolve-to-skeleton base material |
| `fx/shaders/ice_shard.gdshader` | Shatter shards (fade via INSTANCE_CUSTOM) |
| `fx/shaders/puddle_decal.gdshader` | Animated corrosive/water/oil puddles |
| `fx/shaders/electric_arc.gdshader` | Scrolling arc ribbons (shock/radiation) |
| `fx/shaders/ground_fire.gdshader` | Burning oil surface |
| `environment/surface_*.gd` | Oil (ignitable), water (electrifiable), ice (meltable → water) |

## How elements map to techniques

| Element | Body treatment | Extra |
|---|---|---|
| Ice | Overlay: icy fresnel + frost coat, `freeze_amount` desaturates & crystallizes. Freeze pauses AnimationTree. Mid-air freezes drop like a block (ElementalTarget takes over gravity) and take impact damage on landing — slag-amplifiable, can shatter-kill | On kill while frozen: hide meshes, spawn pooled MultiMesh shard burst bouncing on the enemy's actual floor height; shard count auto-scales with enemy volume |
| Fire | Overlay: ember glow creeping via noise + fresnel heat | Pooled flame+smoke GPUParticles parented to a body socket. Ignites `SurfaceOil`, melts `SurfaceIce` → spawns `SurfaceWater` |
| Acid | Base material swapped to shared dissolve shader; `dissolve_amount` instance uniform eats flesh revealing an **inner skeleton mesh** on the same Skeleton3D | Sizzle particles at the dissolve edge |
| Corrosive | Overlay: drippy coat (green) via triplanar noise | Pooled `Decal` puddle under enemy, grows + fades |
| Slag | Same overlay path as corrosive, purple, stronger pulse | **No** ground decal. Sets `slagged` flag → damage amp |
| Shock | Arc ribbons: 3–4 quads with scrolling electric shader orbiting the enemy + spark particles | Electrifies `SurfaceWater` (arcs across plane, DoT area) |
| Radiation | Same arc ribbon system, fewer/slower arcs, + smoky green particles + pulsing overlay glow | Aura Area3D damages nearby enemies; on death can chain |

## Synty VFX pack — what you have vs. what's missing

Synty's POLYGON *Particle FX / VFX* pack gives you: flipbook flame & smoke atlases, spark
and glow billboards, electric arc textures, drip/splash sprites, and low-poly chunk
meshes (crystals, rocks). That covers ~80%. **You will need to add:**

- **Inner skeleton meshes** for acid. The VFX pack has none. Options: Synty's POLYGON
  Fantasy/Horror packs include skeleton characters whose mesh you can re-skin onto your
  enemy's `Skeleton3D` (bone names must match or be retargeted); or commission one
  generic "skeleton suit" per rig family. A cheap fallback: dissolve to a dark
  emissive-edge silhouette instead of a real skeleton.
- **Pre-fractured / shard-friendly ice chunk mesh.** The crystal chunks work for the
  shard *burst*, but the "popsicle" look needs an ice **shell**: a slightly inflated
  copy of the enemy silhouette. We generate it at runtime by re-rendering the enemy
  mesh with the ice overlay (no asset needed) — but if you want a chunky low-poly
  encasement, model one generic capsule-ish ice block (5 min in Blender).
- **Seamless 3D-ish noise textures** (one RGB noise, one Voronoi/caustic). Synty
  flipbooks aren't tileable. Use Godot's built-in `NoiseTexture2D` (free, done in
  editor) — the shaders below assume it.
- **Decal albedo/normal for puddles** (corrosive goo, water, scorch). Easy to author:
  radial-gradient alpha + the caustic noise. Synty has splash sprites but not
  ground-projected puddle textures.
- **A caustics texture** for electrified water (Voronoi again works).

## Should anything be GDExtension C++?

**Short answer: no — ship it all in GDScript + shaders first.** Every effect here is
GPU-bound (particles are `GPUParticles3D`, all animation of overlays/arcs is in-shader,
shards are one MultiMesh transform loop). GDScript's cost is per-call overhead, and the
architecture is designed so per-frame script work is tiny: one status-tick loop and one
shard-update loop.

Rough budgets (mid-range desktop): 200 simultaneous statuses ticking at 10 Hz is
microseconds; 4 concurrent shatters × 40 shards = 160 transform writes/frame via
`RenderingServer.multimesh_instance_set_transform` — still well under 0.1 ms.

**When C++ (GDExtension) becomes worth it:**

1. **Runtime mesh fracturing** (real Voronoi fracture of the frozen enemy instead of
   generic shards). CPU-heavy geometry work — do it in C++ *or* pre-fracture offline
   in Blender (Cell Fracture) and just swap meshes, which is what Borderlands-style
   games actually do.
2. **Thousands of simultaneous statuses** (horde game, 2–5k enemies). Port only
   `ElementalManager._physics_process` to C++; keep everything else.
3. **Chain lightning / radiation-spread graph queries** over hundreds of targets per
   frame. Alternatively batch them through `PhysicsServer3D` direct-space queries
   spread across frames in GDScript.

Middle ground before C++: GDScript can call `RenderingServer` / `PhysicsServer3D`
directly (the shard system below does), and Godot 4's typed GDScript + `@export`ed
packed arrays close much of the gap. Profile first — the bottleneck in effects-heavy
scenes is nearly always fill-rate (overlapping transparent particles), not script.

## Fill-rate rules (the actual perf killer)

- Overlay shader renders the mesh a **second time** — keep it `unshaded`, no depth
  write, and skip it entirely when all amounts are 0 (we toggle `material_overlay`
  on/off, not just fade to 0).
- Particles: small quads, few of them, no soft-particle depth reads on mobile.
  Fire = ~12 flame quads + 6 smoke, not 200.
- Decals are cheap but not free — pool caps them (16 puddles worldwide, oldest fades).
- Arcs are 3–4 ribbons per shocked enemy, `billboard` off, additive, no shadows.
- Everything sets `cast_shadow = OFF` and uses `VisibleOnScreenNotifier3D` culling via
  the pool's auto-sleep.

## Setup checklist

1. Autoloads: `ElementalManager`, `VfxPool` (project settings → Globals).
2. Each enemy scene: add `ElementalTarget` node, assign its exports
   (body `MeshInstance3D`, optional skeleton `MeshInstance3D` [hidden], `AnimationTree`,
   chest/ground `Marker3D` sockets).
3. Create the shared materials once (see `elemental_target.gd` header comment) and
   assign in `ElementalManager`'s exports, plus your Synty textures in the pool scenes.
4. Surfaces: instance `SurfaceOil` / `SurfaceWater` / `SurfaceIce` scenes in levels.
5. Deal elemental damage: `ElementalManager.apply(target, ElementalManager.Element.FIRE, 25.0)`.
