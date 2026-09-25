# Physics Animation — Verification Plan

**Status:** 2026-07-17 · **design only — NOT yet executed.** Concrete test/verification plan for the
[physics animation system](spec.md), following the shared
[verification strategy](../_shared/verification_strategy.md). Expands `spec.md` §14 into runnable
tiers, invariants, thresholds, and a reference script (`tests/smoke_test.gd`).

> ⚠️ Nothing here has been run. The script is a drafted artifact. "Expected" numbers are **targets**,
> not recorded passes. Reaching parity with the gait system's validated smoke test requires an actual
> headless run + recording the result.

---

## 1. What we verify (invariants)

| # | Invariant | Tier | How | Pass threshold |
|---|---|---|---|---|
| V1 | Class loads | T0/T1 | `ClassDB.class_exists("ActiveRagdoll")` | true (else skip w/ message) |
| V2 | Rig built | T1 | count `PhysicalBone3D` under the `PhysicalBoneSimulator3D` | == spec-list size (16 for the humanoid rig) |
| V3 | Simulated mask | T1 | each physical bone maps to a real skeleton bone index | all indices ≥ 0, unique |
| V4 | Scale-fix applied | T1 | a physical bone's `body_offset` basis scale ≈ `1/inherited_scale` | within 1% |
| V5 | Drive-OFF parity | T1 | `simulating=false`, one frame → puppet bone rotations == target bone rotations | max Δquat angle < 0.5° |
| V6 | Drive-ON tracking | T1 | `simulating=true`, hold a static target, run N frames → each physical bone vs target global pose | mean pos err < 3 cm, worst < 10 cm |
| V7 | Snap guard | T1 | teleport the character `> snap_distance` in one frame → bones re-converge, no NaN/blow-up | converge < 3 frames; all finite |
| V8 | Hit → recover | T1 | impulse a bone + drop `track_*` → pose error spikes, then returns | spikes > 5 cm, recovers < tolerance within `stagger` |
| V9 | Unsimulated copy | T1 | a body-less bone (e.g. `Head`) follows the target while simulating | Δquat < 0.5° |
| V10 | Start/stop clean | T1 | `set_simulating` true→false→true leaks no bodies, no error spam | body count stable; `get_simulating()` matches |
| V11 | Velocity vs torque A/B | T3 | run V6 under both `use_velocity_drive` true/false | velocity path err ≤ torque path err |
| V12 | Determinism | T3 | same seed/setup twice → identical bone counts + within-eps poses | bit-identical counts; poses < 1e-4 |
| V13 | Baked-default regression | T3 | tuned defaults from T2 stay within band | each param == golden ± eps |

## 2. Tiers mapped to this system

- **T0 static gate:** `scons -C native` (compile + link `ActiveRagdoll`) + `--check-only` on the
  GDScript harness/integration. Catches ABI/link/syntax before runtime.
- **T1 headless smoke:** [`tests/smoke_test.gd`](tests/smoke_test.gd) — V1–V10. Deterministic,
  synthetic rig (no art dependency), exit 0/1.
- **T2 visual harness:** `sta_active_ragdoll` AnimStudio (F3 sliders, "Print Values"). Human tunes
  `track_*` / `max_*` / `snap_distance`, then bakes numbers into defaults → feeds V13.
- **T3 regression/parity:** V11–V13 as separate headless scripts (A/B and determinism reuse the T1
  harness with different flags).

## 3. Harness requirements

The reference `ActiveRagdoll` builds itself in `_ready()` from its surroundings, so the harness must
reproduce that shape (this is the one place the test couples to the reference impl):

```
CharacterBody3D  "TestChar"
├── Node3D "CharacterMesh"          # ActiveRagdoll duplicates this for the hidden Target
│    └── Skeleton3D                 # named bones matching the spec list (Hips, Spine_01, …)
└── ActiveRagdoll                   # added via ClassDB; finds the skeleton + CharacterMesh in _ready
```

- **Synthetic rig**, built in code (`_make_humanoid_skeleton()`): 16 bones with the reference names,
  `+Y`-along-bone rests, plausible limb lengths. Keeps the test **asset-free**. (If `Enemy1.glb`
  exists, a variant can load it to also exercise the real skin — optional.)
- **Ground** `StaticBody3D` on the World layer so foot-IK/collision have a surface.
- **Isolate the drive:** set `use_procedural_walk=false` and `foot_ik_enabled=false` for V5–V8 so the
  Target holds a known rest pose and only the drive is under test; re-enable them in dedicated cases.

## 4. Test hooks — ADDED 2026-07-17

`ActiveRagdoll` drives but couldn't *measure* headless, so these side-effect-free getters were added
to the reference (`src/active_ragdoll.{h,cpp}`; rebuild the extension for them to take effect —
see [strategy §6](../_shared/verification_strategy.md#test-seams)):

| Hook | Signature | Enables |
|---|---|---|
| bone count | `get_physical_bone_count() -> int` | V2 without walking the node tree |
| bone handles | `get_physical_bone_rid(i) -> RID` · `get_physical_bone_node(i) -> PhysicalBone3D` | V8 impulse, V6 per-bone read |
| tracking error | `get_mean_tracking_error() -> float` | V6/V11 as a one-number threshold |
| mask | `get_bone_index_for(i) -> int` | V3 mask check |

The smoke test uses these when present and keeps `PhysicalBoneSimulator3D` tree-discovery as a
fallback (older DLLs / other rigs). ⚠️ The hooks exist in source only — **nobody has built or run
this yet.**

## 5. Thresholds (targets)

- Drive-off parity V5: < 0.5° per bone (should be exact — it's a pose copy).
- Drive-on tracking V6: mean < 3 cm, worst < 10 cm at `track_*=1` on a settled character. (Gait
  system's IK hits sub-mm; a velocity-driven ragdoll is looser by nature — 3 cm is "reads as
  animation.")
- Snap guard V7: full recovery < 3 physics frames; **no NaN ever** (hard fail on any non-finite).
- Hit recovery V8: measurable divergence then return within the authored `stagger` window.

Record real measured numbers here after the first run, alongside `{engine build, physics backend}`.

## 6. Known limitations / honest caveats

- **`@export` handling params can't be verified headless** (grip seating, ADS offsets, spring
  strengths) — visual-only, same caveat the reference's `ACTIVE_RAGDOLL_ANIMATION.md §8` notes.
- **Physics determinism** across backends/platforms is not guaranteed bit-for-bit; V12 uses an eps
  band, and V11/V12 should pin one backend (Jolt) per run.
- Foot-IK and procedural walk are exercised in dedicated cases, not V5–V8 (kept isolated on purpose).
- This plan tests the **physics layer in isolation**. The gait↔physics **merge** now has its own
  module + plan + test — [`../gait_physics_merge/`](../gait_physics_merge/) (M1–M7: creature tracks
  the gait *and* stumbles on impulse).

## 7. How to run (when ready — do not run yet)

```bash
scons -C native                                   # T0: build ActiveRagdoll (editor closed)
godot --headless --path . --import                # load the extension + assets
godot --headless --path . --script res://physics_animation/tests/smoke_test.gd   # T1: exit 0 = pass
```

Then bake T2 numbers and add the T3 A/B + determinism scripts. Log the first real result in §5.
