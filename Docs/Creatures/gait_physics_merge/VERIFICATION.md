# Gait ⇄ Physics Merge — Verification Plan

**Status:** 2026-07-17 · **design only — NOT executed.** Test plan for the
[merge module](creature_ragdoll.gd) that makes procedural creatures walk *and* react to forces,
following the shared [verification strategy](../_shared/verification_strategy.md). Design rationale:
[INTEGRATION_WITH_PROCGEN.md](../sta_active_ragdoll/INTEGRATION_WITH_PROCGEN.md). Part of the
[master doc](../README.md).

> The merge is the payoff of both systems: gait supplies the **Target** (any morphology), the
> physics layer supplies the **Puppet** (real reactions). This proves they compose — a creature
> that couldn't stumble (kinematic gait alone) now stumbles and recovers.

---

## 1. What we verify (invariants)

| # | Invariant | Tier | How | Pass threshold |
|---|---|---|---|---|
| M1 | Rig built from morphology | T1 | `get_physical_bone_count()` | == body + spine + legs×2 (+head); **no hardcoded names** |
| M2 | Tracks the walking gait | T1 | physics ON, no force, run N frames → `get_mean_tracking_error()` while root moves | mean < 5 cm **and** creature displaced > 1 m |
| M3 | Stumbles on hit, recovers | T1 | `hit(bone, impulse)` → error spikes, then returns; creature keeps locomoting | spike > 8 cm; recover < 5 cm within `stagger`; still moving after |
| M4 | Knockdown / death | T1 | `knockdown()` (track→0) → bones leave target far (collapse); restore → recovers | collapse err > 25 cm; after restore < 5 cm |
| M5 | LOD gate | T1 | `set_lod(1)` → sim off, kinematic copy; `set_lod(0)` → sim on again | `get_simulating`-equivalent flips; no body leak; copy matches target |
| M6 | Morphology-agnostic | T1 | run M1–M3 for two different creatures (e.g. 1-leg-pair vs 3-leg-pair) | both build + track; zero name assumptions |
| M7 | Determinism | T3 | same seed twice → identical physical bone count | exact |

## 2. Tiers

- **T0 static gate:** `--check-only` on `creature_ragdoll.gd` + the procgen `creature/*.gd` it depends
  on. (No C++ — the merge drive is GDScript; only procgen's optional `MeshForge` needs `scons`.)
- **T1 headless smoke:** [`tests/merge_smoke_test.gd`](tests/merge_smoke_test.gd) — M1–M6.
- **T2 visual harness:** reuse procgen's `test/main.gd` playground with `CreatureRagdoll` attached +
  a "kick" key that calls `hit()`; watch a creature stagger then recover its gait.
- **T3 regression:** M7 determinism; later, tracking-error regression band per morphology.

## 3. Harness (the split, INTEGRATION §3.2 "two skeletons")

```
world
├── ground StaticBody (World layer)
└── ProcCreature  "Target"          # gait + TwoBoneIK3D pose rig.skeleton kinematically
     rig.skeleton  ← TARGET
     Skeleton3D "Puppet"   ← CreatureSplit: visible mesh re-skinned here; physics rig lives here
          └── CreatureRagdoll (via CreatureRagdoll.attach_to(creature))
```

The test builds a `ProcCreature` (its gait runs on `rig.skeleton` = Target) and calls
`CreatureRagdoll.attach_to(creature)` — which runs `CreatureSplit.make` (real bones-only Puppet, the
visible mesh re-skinned onto it, Target mesh hidden) then builds + drives the physics rig. Physics
bones are driven in world space toward the Target's moving bone poses, so the Puppet chases the walk.
(This is the real builder-level split, no longer a faked `duplicate()`; §5.)

## 4. Thresholds (targets — not measured)

- Tracking M2: mean < 5 cm. Looser than the humanoid ragdoll (3 cm) because the creature's gait
  translates the whole body fast; the base-velocity feed-forward carries it, correction clamps do
  the rest.
- Stumble M3: measurable spike (> 8 cm) then recovery within the authored `stagger` window.
- **No NaN ever** (hard fail on any non-finite bone position).

## 5. Known limitations / caveats

- **Not run.** Every number is a target.
- **Reference is GDScript.** Fine for the few LOD0 creatures that are ever physical at once. The
  **C++ ship path is now open:** `ActiveRagdoll` accepts a `custom_bone_specs` bone-spec list
  (physics_animation/spec.md §5) **and** a `set_base_velocity()` feed-forward (both done
  2026-07-17), so the rig builds and tracks in C++ for any morphology with no `CharacterBody3D`
  parent. `set_target_skeleton()` closes the last coupling — the drive no longer assumes a
  `"CharacterMesh"` Target, so a creature can hand it the gait skeleton and ride the **C++** drive
  directly. The Target/Puppet split lives in the (GDScript) builder —
  `CreatureBuilder.build(split:=true)` / `split_rig`. The only remaining GDScript-by-design piece is
  `CreatureBuilder` itself (scene construction, no perf reason to port). This module stays the
  no-rebuild path.
- **Two-skeleton split is real now.** `CreatureBuilder.split_rig` (canonical) produces a bones-only
  Puppet, re-skins the visible mesh onto it, and hides the Target mesh (gait/IK keep running on the
  Target). `CreatureSplit.make` delegates to it; the test uses it via `CreatureRagdoll.attach_to` — no
  faked `duplicate()`.
- **Cone-twist limits + capsule sizes** are generic (from DNA thickness/lengths); wild morphologies
  may need per-DNA tuning (a T2 pass), same as the gait's own feel constants.
- **Determinism** of the *physics* (M7 asserts only bone count) isn't bit-exact across
  backends/platforms — pin Jolt; rely on the seed→rebuild MP model, not pose sync.

## 6. How to run (when ready — do not run yet)

```bash
# in a project that has BOTH the procgen creature system AND this module:
godot --headless --path . --import
godot --headless --path . --script res://gait_physics_merge/tests/merge_smoke_test.gd   # exit 0 = pass
```
