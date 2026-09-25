# Procedural Creature System — Godot 4.6

**Status:** 2026-07-17 · validated against Godot 4.6-stable headless (smoke test: 0 failures).
Part of the [Procedural Characters master doc](README.md). This is the **Procedural Gait**
(kinematic) system. Shared concepts — Target/Puppet, LOD, multiplayer, engine facts — live in
[`_shared/shared_core.md`](_shared/shared_core.md). Reference code:
[`procgen_creatures/`](procgen_creatures/). Verbose handoff + verbatim source:
[`procgen_creature_system_handoff.md`](procgen_creature_system_handoff.md). Test plan:
[`procgen_creatures_VERIFICATION.md`](procgen_creatures_VERIFICATION.md). Adds physical
reactions (stumble/knockdown) via the [physics animation system](physics_animation/spec.md) —
see [the merge](sta_active_ragdoll/INTEGRATION_WITH_PROCGEN.md).

> **Engine notes (web-verified 2026-07-17).** The §2 `TwoBoneIK3D` API below is confirmed against
> the official Godot 4.6 class reference. `TwoBoneIK3D` is **new in 4.6** (IK "returned" via the
> `IKModifier3D` family) → **this system's hard floor is Godot 4.6**. Two-bone legs use
> `TwoBoneIK3D`; limbs with **3+ segments** (multi-joint legs, tentacles, long necks) should use the
> 4.6 `ChainIK3D`/`FABRIK3D`/`CCDIK3D` solvers instead — and `IterateIK3D`'s **deterministic mode**
> for any IK you replicate in multiplayer. Give tails/antennae `SpringBoneCollision3D` (4.5+) so they
> don't clip the body. Full version matrix + solver-selection guide:
> [`_shared` §engine-facts](_shared/shared_core.md#engine-facts).

Spec + validated reference implementation. Everything below was **verified against Godot 4.6-stable headless** (smoke test: 0 failures; IK mean error 0.2 mm; native/GDScript mesh parity exact; native build path x2.5 faster end-to-end).

## 1. Goal

NMS/Spore-style creatures assembled from procedural parts, walking with physics-based procedural animation, degrading gracefully with distance.

- **One pipeline, two archetypes.** Organic vs robotic is a *skin-weight policy*, not two mesh systems. Organic: ring vertices near a joint are weighted ~50/50 across the two bones → smooth blended flesh. Robotic: segments weighted 100% to one bone, inset gaps + servo spheres at joints → hard swivel look. Same builder, one flag.
- **Engine solvers, not custom IK.** Godot 4.6 ships a full `SkeletonModifier3D` stack: `TwoBoneIK3D` (legs), `LookAtModifier3D` (head), `SpringBoneSimulator3D` (tails/antennae). All native C++, stackable, deterministic order.
- **Animation is morphology-independent.** A gait engine writes IK *targets* (world-space foot goals), not bone rotations, so any leg count/length walks.

## 2. Validated engine facts (Godot 4.6-stable)

These were probed headless against the real binary — treat as ground truth:

1. `TwoBoneIK3D` uses **per-setting-index API**: `setting_count`, then `set_root_bone_name(i, ...)`, `set_middle_bone_name`, `set_end_bone_name`, `set_target_node`, `set_pole_node`. One node drives all legs.
2. `TwoBoneIK3D` **silently no-ops without a pole node**. Always set one per setting. With a pole, solve error is ~0.
3. The modifier stack only runs when the skeleton is **dirtied that frame**. Writing the body bone pose every physics tick (gait bob) handles this naturally.
4. Bone rests must be oriented **+Y along the bone** (toward the child). Build rest basis with a `basis_y_to(dir)` helper.
5. Post-modifier ("modified") poses are readable **inside the `skeleton_updated` signal** — that's where tests sample IK accuracy.
6. `LookAtModifier3D.forward_axis` takes `SkeletonModifier3D.BoneAxis` (`BONE_AXIS_PLUS_Y` for Y-toward-nose head bones).
7. **Ordering:** controllers that write targets/poses must run *before* the skeleton's modifier pass. Set `process_physics_priority = -10` on gait controllers. (Symptom otherwise: feet lag body motion by exactly the body-dynamics magnitude.)
8. **Spawn robustness:** never snapshot world-space foot positions in `_ready()` — it runs during `add_child()`, *before* the caller positions the node. Lazy-init planted feet on the first physics tick, and expose `teleport_reset()`.

## 3. File layout

```
procgen_creatures/
├── project.godot
├── creature_forge.gdextension     # native mesh forge manifest (optional)
├── bin/                           # built GDExtension libs
├── creature/
│   ├── creature_dna.gd            # seeded genome
│   ├── part_mesh_lib.gd           # geometry batch (GDScript + native router)
│   ├── creature_builder.gd        # DNA → skeleton + skinned mesh + modifiers
│   ├── gait_controller.gd         # LOD0/1 physics gait (raycasts + IK targets)
│   ├── canned_gait.gd             # LOD2 sine FK fallback
│   ├── creature_lod.gd            # 4-tier animation LOD
│   └── proc_creature.gd           # root node; ProcCreature.spawn(dna)
├── native/                        # C++ MeshForge GDExtension
│   ├── SConstruct
│   └── src/{mesh_forge.h,mesh_forge.cpp,register_types.cpp}
├── test/main.tscn + main.gd       # visual playground (herd, orbit cam, LOD keys)
└── tests/smoke_test.gd            # headless CI test
```

## 4. Data model — `CreatureDNA`

Seeded genome; `CreatureDNA.random(seed)` is fully deterministic. Fields: `archetype` (ORGANIC/ROBOTIC), `spine_joints` 3–5, `leg_pairs` (1–3 pairs, each with z-offset, splay, upper/lower lengths), `tail_joints`, antennae, belly radius profile, palette, gait params (`move_speed`, `step_time`, `step_height_f`, `step_trigger_f`, `bob_amp`), syllable-built name. `stand_height() = max leg reach * 0.82` (pre-bent knees).

**Multiplayer note (decided):** animation is client-side cosmetic. Replicate only `{seed, root transform, velocity}`; every client rebuilds the identical creature from the seed and runs its own gait. No pose sync.

## 5. Build pipeline — `CreatureBuilder.build(dna, root) -> rig`

1. **Skeleton**: body → spine chain → head; tail chain; per leg: upper/lower/foot with the knee **pre-bent in the rest pose** (analytic two-circle solve) so TwoBoneIK knows the bend direction.
2. **Mesh**: single skinned `ArrayMesh`.
   - Organic: one continuous blended tube tail-tip→nose (belly profile), leg tubes whose first ring blends **55/45 with the spine bone** — the shoulder "welds" into the body.
   - Robotic: rigid inset segments per bone + servo spheres at joints + emissive sensor eye.
3. **Modifiers** (children of skeleton, in order): one `TwoBoneIK3D` with a setting per leg (+pole `Node3D` per knee), `LookAtModifier3D` (influence 0.7, angle-limited), `SpringBoneSimulator3D` on tail/antennae. `skeleton.modifier_callback_mode_process = PHYSICS`.
4. Returns a `rig` dictionary: skeleton, mesh_instance, per-leg dicts (bone indices, `home_local`, `pole_local`, reach, target/pole nodes, phase `group`), body/head indices, `stand_h`.

## 6. Gait — `GaitController` (LOD0/1)

- **Steppers**: each foot stays *planted in world space* while the body moves. A step triggers when `planted.distance_to(ground_under_home) > stand_h * step_trigger_f` **and** the opposite phase group is fully planted (diagonal gait emerges for free; group = `(pair+side) % 2`). Emergency override at 1.9x trigger so feet can never be left behind.
- **Swing**: smoothstep lerp `from → to` over `step_time`, plus `sin(π t) * step_height`. Landing target leads by `velocity * step_time * 0.7`.
- **Raycasts** place feet on real geometry; the root terrain-follows a downward ray.
- **Body dynamics**: pitch/roll from front/back and left/right planted-foot height averages; bob sine tied to stride frequency. Writing the body pose each tick also dirties the skeleton (fact #3).
- Runs at `process_physics_priority = -10` (fact #7). LOD1 = same controller, `tick_divisor = 4`.

Measured: mean foot-to-target error **0.0002 m**, worst 0.033 m (one-frame swing lag) over 1620 samples, 6 creatures, uneven ground.

## 7. LOD — `CreatureLOD`

| Tier | Distance | What runs |
|------|----------|-----------|
| 0 | < 25 m | full gait 60 Hz, IK, springs, head look |
| 1 | < 60 m | gait at ~15 Hz, IK on, springs/look off |
| 2 | < 120 m | `CannedGait`: sine FK legs + bob at ~10 Hz, all modifiers off |
| 3 | beyond | frozen pose, zero cost |

4 Hz distance poll, ±12% hysteresis, `force_now(tier)` for debug/tests (applies immediately — don't wait for the poll).

## 8. Native mesh forge (GDExtension, C++)

`MeshForge : RefCounted` — exact port of `PartMeshLib`'s emission (`begin / add_tube / add_rigid_segment / add_sphere / commit`). Same ring/index patterns → **bit-identical vertex counts and AABBs** vs GDScript (parity-tested). Normal generation replicates SurfaceTool semantics: smooth = accumulate area-weighted face normals per *bitwise position* (UV-seam duplicates unify), flat = per emitted vertex.

- `PartMeshLib.backend = "auto" | "gd" | "native"` — auto prefers native when the lib is loaded, falls back silently. The project **runs without the compiled lib**.
- Stations cross the boundary as Dictionaries; the hot per-vertex loops are all C++.
- Measured x2.5 end-to-end creature build speedup (mesh bake itself far higher; skeleton/node setup now dominates). Native path is also safe to call from background threads for hitch-free herd spawning.

Build (from `native/`):
```
scons platform=linux target=template_debug custom_api_file=<4.6 extension_api.json>
```
godot-cpp: `master` branch until a `4.6` branch lands; dump the API from your exact binary: `godot --headless --dump-extension-api`.

## 9. Tests — `tests/smoke_test.gd`

Headless CI: `godot --headless --path . --import` then `--script tests/smoke_test.gd`. Asserts: bone counts match DNA; mesh verts/normals/weights/AABB sane; every creature locomotes and steps; IK accuracy sampled inside `skeleton_updated`; LOD2 animates with IK off; LOD3 frozen; native parity (surfaces, per-surface vertex counts, AABB) + native faster. Exit code 0/1.

## 10. Production roadmap

1. **Seam quality** (organic): current shoulder weld is weight-blended tube-into-tube. Upgrades, in effort order: (a) shader-space normal blending at the weld ring; (b) metaball/SDF skinning — evaluate part SDFs into a small `godot_voxel` buffer and Transvoxel-mesh it (you already ship the library); bake once per DNA, reuse.
2. **Part library growth**: mouths, horns, fins, wings as new emitters in the forge; DNA gains part slots. Sockets = named bones + local transforms.
3. **Active ragdoll / hit reactions**: per-limb `PhysicalBoneSimulator3D` blend-in on damage, return to gait via pose crossfade.
4. **Herd spawning**: move `CreatureBuilder.build` mesh phase to a `WorkerThreadPool` task using the native forge; hand back the ArrayMesh on the main thread.
5. **Attack/behavior layer**: reuse the AdventureCraft AI spec's awareness states; gait already exposes `wander`/`move_dir` for steering.
6. **Windows/mac exports**: cross-build the forge (`platform=windows`) or ship GDScript-only — auto fallback means no hard dependency.

## 11. Known notes

- godot-cpp `master` against 4.6-stable: use `custom_api_file` from your binary (done here). Rebuild when the official `4.6` branch lands.
- Quitting the whole SceneTree with dozens of live creatures mid-physics can print a harmless teardown abort in headless test runs (assertions all pass, exit 0; isolated single-creature runs are clean on both backends).
