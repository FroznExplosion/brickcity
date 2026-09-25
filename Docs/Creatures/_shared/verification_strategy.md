# Verification Strategy — shared testing doctrine

**Status:** 2026-07-17 · **design only, nothing here has been executed yet.** How both systems are
tested and verified. Defined once; each system's own test plan
([gait](../procgen_creature_system_handoff.md) §6–7, [physics](../physics_animation/VERIFICATION.md))
follows this doctrine and links back here. Part of the
[Procedural Characters master doc](../README.md).

---

## 1. The four verification tiers

Every system is checked at four escalating levels. Cheap/fast gates run first and fail loud before
the expensive ones.

| Tier | What | Runs | Gates | Human? |
|---|---|---|---|---|
| **T0 · Static gate** | GDScript `--check-only` parse + C++ compile/link | seconds, headless/CI | syntax, missing symbols, ABI | no |
| **T1 · Headless smoke** | `SceneTree` script asserting invariants, exit 0/1 | ~seconds, headless/CI | build correctness, behavior, thresholds | no |
| **T2 · Visual harness** | live scene, tuning UI, print-values bake | interactive | look/feel, param tuning | yes |
| **T3 · Regression / parity** | golden values, backend A/B, determinism | headless/CI | drift, backend divergence, non-determinism | no |

T0+T1+T3 are CI-able (exit codes). T2 is the human loop that produces the numbers T3 later guards.

## 2. Principles

- **Headless-first.** Anything assertable must run under `godot --headless --script …` with no
  window. Reserve the editor for T2 tuning only.
- **Deterministic by seed.** Same seed ⇒ same mesh, same bone count, same step count, same result.
  This is also the multiplayer contract ([`shared_core` §MP](shared_core.md#multiplayer)) — a
  determinism failure is a gameplay bug, not just a test flake.
- **Thresholds as fractions, not absolutes.** Express tolerances relative to the character's scale
  (fraction of leg reach / stand height / bone length), so the same test passes for a mouse and a
  giant.
- **Sample inside the right signal.** Post-solve poses are only correct inside `skeleton_updated`
  (gait IK) or after the physics step (ragdoll). Sampling elsewhere reads stale poses — a test bug
  that looks like a code bug.
- **Fail closed.** `quit(1)` on any failed assertion; `quit(0)` only when all pass. CI reads the
  exit code, nothing else.
- **Minimize asset hard-deps.** Prefer a synthetic rig built in code over shipping a `.glb`, so the
  core is testable without art. Where a test *must* couple to a specific rig (bone names), isolate
  that in one harness helper and say so.
- **One invariant per assertion,** with a human-readable message including the measured value — a
  failing line should tell you what and by how much.

## 3. Headless run protocol

```bash
# T0 — static gate
godot --headless --path . --check-only --script res://<file>.gd   # per script; parse only
scons -C native                                                    # C++ compile + link (editor CLOSED: DLL lock)

# T1/T3 — import pass MUST precede any script run (generates .godot/, loads the GDExtension)
godot --headless --path . --import
godot --headless --path . --script res://tests/<smoke_test>.gd     # exit 0 = pass
```

- **Import first, always.** A script run before an import pass sees no extension classes and no
  imported assets.
- **DLL lock (Windows):** close the editor before the final native link; compiling with it open is
  fine.
- **Teardown caveat:** quitting a `SceneTree` with many live physics/creature nodes mid-step can
  print a harmless teardown abort *after* all assertions pass. Trust the exit code; isolated
  single-subject runs are clean.

## 4. Harness anatomy (shared shape)

A T1 smoke test builds the same skeleton every run:

```
SceneTree._init():
  await physics_frame            # let the tree come up
  world = Node3D under root
  world += ground StaticBody + a bump/slope   # gives raycasts / collisions something to hit
  subject = build_subject(seed) # creature (from DNA) OR character (synthetic rig + ActiveRagdoll)
  await physics_frame ×N         # settle
  assert structural invariants   # counts, masks, resources
  run behavior for FRAMES_RUN    # sampling telemetry inside the right signal
  assert behavioral invariants   # movement, tracking error, recovery
  force each LOD / mode; assert  # force_now(tier) — never wait for the 4 Hz poll in a test
  quit(0 if fail==0 else 1)
```

Helpers every harness shares: `_check(cond, msg)` (counts failures), `_static_box(pos,size)`,
deterministic seed list, a telemetry accumulator (mean + worst).

## 5. What each tier proves, per system

| | Gait (kinematic) | Physics (dynamic) |
|---|---|---|
| **T0** | GDScript parse | GDScript parse + `scons` link of the GDExtension |
| **T1** | bone counts vs DNA, mesh sanity, locomotes+steps, IK error inside `skeleton_updated`, LOD2 animates / LOD3 frozen | rig built, drive-off pose parity, drive-on tracking error, snap-guard recovery, hit→recover, sim start/stop |
| **T2** | herd playground (reroll, force LOD, orbit) | AnimStudio (F3 sliders, print-values bake) |
| **T3** | GDScript↔native mesh **parity** + native-faster | velocity-drive vs torque-PD **A/B**, determinism, baked-default regression |

Concrete assertion lists live in each system's plan; this table is the map.

## 6. Test seams (make the code verifiable) {#test-seams}

Headless assertions need read access the gameplay code doesn't otherwise expose. Add minimal
**test hooks** rather than reaching into privates:

- A count of built sub-objects (physical bones / creature bones).
- Per-item handles for measurement (a bone's `RID` or global pose).
- A rolled-up telemetry number the test can threshold (mean tracking error, steps taken, pose
  writes).

Keep hooks side-effect-free getters. The gait reference already exposes `steps_taken`,
`pose_writes`, `rig`; the physics reference needs a few more (listed in its plan).

## 7. CI wiring (sketch, not yet set up)

```
job: verify
  - checkout
  - build native (scons) for the runner platform
  - godot --headless --import
  - T0: check-only over changed .gd files
  - T1: run each tests/*smoke*.gd, fail job on nonzero exit
  - T3: run parity/determinism scripts
  # T2 is manual, pre-merge, produces the golden numbers T3 pins
```

Matrix later: {GodotPhysics3D, Jolt} × {gd, native} to catch backend divergence.

## 8. Status of the test system itself

**None of this has been run yet.** The gait system ships a written smoke test
(`procgen_creatures/tests/smoke_test.gd`, reproduced in the handoff) with reference numbers claimed
by the author; the physics system has a *drafted* script (`physics_animation/tests/smoke_test.gd`)
that has **not** been executed. Treat all "reference results" as targets to reproduce, not as
passing CI, until a real run is recorded here.
