# Shared Core — concepts both systems depend on

**Status:** 2026-07-17. Single source of truth for ideas the **procedural gait** (kinematic) and
**physics animation** (dynamic) systems both rely on. Defined **once here**; every other doc links
to a section instead of restating it. Change a shared behavior → edit this file → both systems
inherit it. That's the whole point of the `_shared/` folder.

Systems that reference this: [`../procgen_creatures_spec.md`](../procgen_creatures_spec.md),
[`../physics_animation/spec.md`](../physics_animation/spec.md),
[`../sta_active_ragdoll/`](../sta_active_ragdoll/).

---

## Target / Puppet {#targetpuppet}

Both systems separate **intent** from **result**:

- **Target** — "what the body *wants* to do." A kinematic skeleton posed each frame by a pose
  source (clips, a gait solver, or rest). Never simulated. Deterministic.
- **Puppet** — "what the body *actually does*." In the kinematic system the Puppet *is* the Target
  (one skeleton). In the physics system the Puppet is a separate, simulated skeleton that chases
  the Target.

Why they matter together:
- The **gait system** writes world-space IK *targets* and solves a Target pose. Morphology-independent.
- The **physics system** adds a Puppet that follows the Target and reacts to forces.
- The seam between them is the **PoseProvider** (below): the gait is just one provider the physics
  layer can consume. This is how the two compose instead of competing.

## PoseProvider {#poseprovider}

Anything that **fully poses a Target skeleton each physics frame, before consumers read it.**

Contract:
1. Owns/poses the Target skeleton (bone layout must match any Puppet that consumes it).
2. Runs early in the physics tick — controllers that write poses/targets use
   `process_physics_priority = -10` so they finish before the engine's skeleton-modifier pass and
   before the physics drive samples the pose.
3. Does not touch the Puppet.

Known providers: clip `AnimationTree` (humanoid), procedural N-legged gait (creatures), static rest
pose, built-in sine walk. Swapping providers is a flag, never a rewrite.

## Velocity drive ("soft keying") {#velocity-drive}

The physics system's method for making a rigid body track a target pose: each physics frame, **set
the body's velocity to what reaches the target this step**, instead of applying spring forces.

```
lin_vel = base_vel + clamp((target_pos − cur_pos)/dt × track_position, max_lin_speed)
ang_vel =            clamp( axis·angle(target_rot × cur_rot⁻¹)/dt × track_rotation, max_ang_speed)
if |target_pos − cur_pos| > snap_distance → hard-teleport to target (blow-up guard)
```

Why velocity drive, not torque/force PD (the research):
- **Jolt's author** lists three active-ragdoll methods and calls manual force/torque application
  "difficult to tune"; recommends **velocity-based driving** or **joint motors**.
  <https://github.com/jrouwe/JoltPhysics/discussions/1764>
- **CBerry22 Godot-4 active ragdoll** — the known-working Godot example — also drives velocities
  with a ~1 m snap-teleport guard.
  <https://github.com/CBerry22/Active-Ragdoll---Physics-Animations-in-Godot-4.0>
- **PuppetMaster** (Unity, Human-Fall-Flat-class) drives rotation at the *constraint* level
  (solver-integrated) + world-position pins; avoids external torque.
  <http://root-motion.com/puppetmasterdox/html/page5.html>
- **R3X-G1L6AME5H/Godot-Active-Ragdolls** abandons `PhysicalBone3D` for RigidBody+6DOF for the same
  reason. <https://github.com/R3X-G1L6AME5H/Godot-Active-Ragdolls>

Consequences: unconditionally stable (no gains to explode); tracks exactly at `track_*=1`;
collisions perturb mid-step and the next frame re-aims (physical reads for free); **bone mass only
affects collision response, not tracking**. Full detail: [`../physics_animation/spec.md §6`](../physics_animation/spec.md).

## Animation LOD policy {#lod}

Both systems degrade with distance; the physics tier is the most expensive and gated hardest.

| Tier | Distance (tune per game) | Gait system | Physics system |
|---|---|---|---|
| 0 | near (<~25 m) | full gait 60 Hz + IK + springs + look | Puppet simulated, velocity-driven |
| 1 | mid (<~60 m) | gait ~15 Hz, IK on, springs/look off | **no physics** — Puppet copies Target |
| 2 | far (<~120 m) | canned sine FK, all modifiers off | kinematic only |
| 3 | beyond | frozen pose | frozen pose |

Rules:
- Poll distance at a few Hz with hysteresis (±~12%) so tiers don't flicker.
- Build the physical rig **lazily on LOD0 entry**, tear it down on demotion — far actors allocate
  no bodies.
- **Never physics-simulate a herd.** Cap concurrent physical characters and pool them. This is the
  performance wall both systems are designed around.

## Multiplayer model {#multiplayer}

Decided, identical for both systems: **animation is client-side cosmetic.**

- Replicate only `{seed, root transform, velocity}` + **authoritative gameplay events** (hit,
  death, spawn).
- Every client rebuilds the identical character from the seed and runs its own gait / its own
  Puppet physics locally. Puppets may diverge cosmetically — that's fine.
- **Never replicate bone transforms / pose sync.**

### Scope: poses vs positions {#mp-scope}

The rule above governs **pose** — how a body is animated. It does **not** govern **position**,
and the distinction is load-bearing:

| What | Model | Why |
|---|---|---|
| Bone poses, gait phase, Puppet physics, ragdoll | client-local, from seed | cosmetic; divergence is invisible |
| Character / agent **world positions** | host-authoritative | the host owns hit registration |

An earlier revision of this section extended the seed rule to herds ("replicate the flow-field +
spawn/RNG seed, simulate locally"). **That is superseded.** For the horde specifically, follow
[`../../../swarm_master_plan.md` §9](../../../swarm_master_plan.md), which argues the case against
deterministic client simulation explicitly and wins it:

- Cross-machine float determinism is fragile (CPU architecture, compiler flags, SIMD paths, math
  libraries), and in a swarm with tight agent-agent feedback the divergence **amplifies within
  seconds**.
- That is fatal rather than cosmetic here, because the host owns hit registration: players would be
  shooting zombies that are not where they appear.
- The bandwidth saving that motivates seed-replication is real but unnecessary at 500 agents.

Shipping model for the horde is therefore **host-authoritative simulation with per-client tiered
snapshots** — snapshot rate tiered by distance from the *receiving* client's camera, positions
quantized to the level AABB in 16-bit fixed point, delta-encoded, deaths batched one packet per
tick, ~15–25 KB/s per client. Clients run a visual-only mirror and interpolate over a ~100 ms
buffer; they never extrapolate. Full detail, including host migration, in §9.

The two rules compose cleanly: the host streams *where* each agent is, and every client derives
*how it looks* locally from `state` + velocity + seed. Nothing about animation crosses the wire in
either model.

## Godot 4.6 engine facts {#engine-facts}

Ground truth probed against the real 4.6-stable binary. Class/method names and version gates
re-verified against the official Godot 4.6 class reference on 2026-07-17 (sources at end of section).
Split by which system needs them.

**Skeleton / IK (gait system):**
1. `TwoBoneIK3D` uses a per-setting-index API (`setting_count`, `set_root/middle/end_bone_name(i)`,
   `set_target_node(i)`, `set_pole_node(i)`); one node drives all legs.
2. `TwoBoneIK3D` **silently no-ops without a pole node** — always set one per setting.
3. The modifier stack runs only on frames where the skeleton is **dirtied** (some bone pose written).
4. Bone rests must be **+Y along the bone** (toward the child); use a `basis_y_to(dir)` helper.
5. Post-modifier ("modified") poses are readable **inside the `skeleton_updated` signal**.
6. `LookAtModifier3D.forward_axis` takes `SkeletonModifier3D.BoneAxis` (`BONE_AXIS_PLUS_Y`).
7. Pose/target writers must run **before** the modifier pass → `process_physics_priority = -10`.
8. Never snapshot world-space positions in `_ready()` (runs during `add_child`, before the caller
   positions the node) — lazy-init on the first physics tick; expose a `teleport_reset()`.

**Ragdoll / physics (physics system):**
9. Rig = `PhysicalBoneSimulator3D` child of the `Skeleton3D`; `PhysicalBone3D` children of *it*;
   start/stop via `physical_bones_start_simulation()/stop`.
10. Each `PhysicalBone3D`: set `bone_name`, add a child `CollisionShape3D`, set `joint_type` +
    cone-twist spans; root bone = `JOINT_TYPE_NONE`.
11. Velocity drive via `PhysicsServer3D::body_set_state(rid, BODY_STATE_LINEAR/ANGULAR_VELOCITY, v)`;
    writing velocity each frame overrides gravity/damping for tracking.
12. **Blender cm→m scale fix:** scale each bone's `set_body_offset` basis by `1/inherited_scale` or
    the ragdoll explodes ~100×. Keep the guard even at scale 1.
13. **Collision layering:** ragdoll bones on their own layer, mask World only — never each other,
    never the character's movement capsule.

**Build/toolchain (both):**
14. `godot-cpp` `master` against 4.6-stable — dump the API from your exact binary
    (`godot --headless --dump-extension-api`) and pass `custom_api_file`. Rebuild when an official
    `4.6` branch lands.
15. Close the editor before the final link (DLL lock on Windows); compiling with the editor open is
    fine.

### Minimum engine version {#min-version}

The two systems have **different floors** — matters when reusing them in another project:

| Feature used | First shipped | Gates which system |
|---|---|---|
| `PhysicalBoneSimulator3D`, cone-twist `PhysicalBone3D`, `body_set_state` velocity | 4.0–4.3 | Physics system (works pre-4.6) |
| `SkeletonModifier3D` base, `LookAtModifier3D`, `RetargetModifier3D` | **4.4** | Gait head-look / clip retarget |
| `SpringBoneSimulator3D` (+ `SpringBoneCollision3D`) | **4.5** | Gait tails/antennae |
| `IKModifier3D` family incl. **`TwoBoneIK3D`** | **4.6** | **Gait legs — hard 4.6 floor** |
| Jolt as the **default** 3D engine | **4.6** (new projects only) | Physics system (recommended, not required) |

- **Gait system → minimum Godot 4.6** (needs `TwoBoneIK3D`). No back-port; IK "returned" in 4.6.
- **Physics system → runs on 4.3+**, but tune for Jolt. Jolt is default only for *new* 4.6 projects;
  existing projects must switch it on in Project Settings → Physics → 3D → Physics Engine. Jolt is
  ~2–3× faster than GodotPhysics3D for many-body ragdolls (supports the LOD/herd budgets in
  [§LOD](#lod)) and is the stability baseline the physics spec assumes.

### IK solver selection (Godot 4.6 `IKModifier3D` family) {#ik-solvers}

4.6 shipped a whole solver family under `IKModifier3D`, not just `TwoBoneIK3D`. Pick per limb:

| Solver | Use for |
|---|---|
| **`TwoBoneIK3D`** | exactly-two-bone limbs (upper+lower leg/arm). The gait system's default. Analytic, cheap, deterministic, needs a **pole** (fact #1–2). |
| **`ChainIK3D` / `SplineIK3D`** | multi-bone chains posed as a whole; spline = smooth necks/spines/tentacles. |
| **`FABRIK3D` / `CCDIK3D` / `JacobianIK3D`** (`IterateIK3D`) | limbs with **3+ segments** (multi-joint legs, tails-as-limbs, trunks). |

Extra 4.6 knobs the current gait code doesn't yet use, worth adopting:
- `IterateIK3D` has a **deterministic mode** (frame-independent) — use it for any IK you replicate
  in multiplayer, so clients converge identically (dovetails with [§MP](#multiplayer)).
- `TwoBoneIK3D.set_pole_direction(i, …)` / `set_pole_direction_vector(i, …)` — explicit bend control
  if a pole node isn't convenient.
- Refinement modifiers stack after the solver: `BoneTwistDisperser3D` (spread twist along a chain),
  `LimitAngularVelocityModifier3D` (damp popping). Cheap polish for procedural limbs.
- `BoneConstraint3D` now accepts `Node3D` targets (not just bones) — simplifies world-space aiming.

### Secondary motion — spring vs physical {#secondary-motion}

Two different tools; don't confuse them:
- **`SpringBoneSimulator3D`** (4.5) — a *modifier* that wiggles a chain and **returns toward the
  original pose**. Kinematic, cheap, deterministic-ish. Right for tails, antennae, ears, hair, gear.
  Add **`SpringBoneCollision3D`** children (`…Sphere3D` / `…Capsule3D`) so those appendages don't
  clip the body — collision is resolved inside the modifier pass, independent of `PhysicsServer3D`.
- **`PhysicalBoneSimulator3D`** (the physics system) — real rigid bodies; does **not** self-return,
  needs a drive to chase a pose. Right for the load-bearing body that must react to forces.

Rule: appendages that only need to jiggle → SpringBone. Body parts that must be hit/knocked → Physical.

### Active-ragdoll drive options (physics system) {#drive-options}

Validated in 4.6 (Jolt), in ascending stability/complexity:
1. **Velocity drive / "soft keying"** (this spec's default, [§velocity-drive](#velocity-drive)) —
   `body_set_state` velocity each frame. Simplest, unconditionally stable, one knob. Start here.
2. **Jolt constraint motors / 6-DOF position servo** — drive the *joint* toward the target angle
   (equilibrium-point angular spring + high damping) instead of the body's velocity. Solver-integrated
   ⇒ PuppetMaster-grade stability at max stiffness. This is the roadmap upgrade if velocity drive ever
   feels too kinematic; it is a **supported 4.6 technique**, not experimental (godot-jolt exposes
   driving constraint motors to an animated pose). Community reports it still needs careful constraint
   tuning — which is why velocity drive stays the default.

**Sources (verified 2026-07-17):**
[TwoBoneIK3D class ref](https://docs.godotengine.org/en/latest/classes/class_twoboneik3d.html) ·
[IK returns to Godot 4.6](https://godotengine.org/article/inverse-kinematics-returns-to-godot-4-6/) ·
[SkeletonModifier3D](https://docs.godotengine.org/en/stable/classes/class_skeletonmodifier3d.html) ·
[SpringBoneCollision3D](https://docs.godotengine.org/en/stable/classes/class_springbonecollision3d.html) ·
[Godot 4.6 release notes](https://godotengine.org/releases/4.6/) ·
[Using Jolt Physics (4.6)](https://docs.godotengine.org/en/4.6/tutorials/physics/using_jolt_physics.html) ·
[Jolt active-ragdoll discussion #1764](https://github.com/jrouwe/JoltPhysics/discussions/1764)

## Glossary {#glossary}

- **Active ragdoll** — a ragdoll that actively drives toward a target pose (vs a passive ragdoll
  that just falls).
- **Authority drop** — briefly lowering `track_*` (globally or per-region) so physics wins → stumble
  → then ramping back to recover. The "dial back for physics" knob.
- **Morphology-independent** — animation written as world-space targets, so any leg count/length
  works from the same code.
- **Soft keying** — synonym for velocity drive.
