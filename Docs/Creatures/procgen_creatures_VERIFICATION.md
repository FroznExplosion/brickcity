# Procedural Gait — Verification Plan

**Status:** 2026-07-17 · plan formalizes an **existing** script; reference numbers are
**author-claimed, not re-run in this pass.** Test/verification plan for the
[procedural gait (kinematic) system](procgen_creatures_spec.md), following the shared
[verification strategy](_shared/verification_strategy.md). The smoke test itself already exists —
`procgen_creatures/tests/smoke_test.gd` (reproduced verbatim in
[handoff §6](procgen_creature_system_handoff.md)); this doc is the plan/invariant contract that was
missing next to it. Part of the [Procedural Characters master doc](README.md).

> Unlike the physics system, the gait system's script is **written and its author reports it passing
> on Godot 4.6-stable headless** (numbers in §5). It has not been re-executed during this
> documentation pass — treat §5 as targets to reproduce in CI, not a fresh green run.

---

## 1. What we verify (invariants)

| # | Invariant | Tier | How | Pass threshold |
|---|---|---|---|---|
| G1 | Bone count matches DNA | T1 | `skel.get_bone_count()` vs `1 + spine_joints + 1 + tail_joints + legs*3` | exact |
| G2 | Mesh sane | T1 | verts, skin, AABB, normals, weights | verts > 100; skin ≠ null; 0.5 < AABB < 60 m; ‖n‖≈1; Σweights≈1 |
| G3 | Locomotes | T1 | root displacement over `FRAMES_RUN` | moved > 1 m |
| G4 | Steps trigger | T1 | `gait.steps_taken` | ≥ `legs × 2` |
| G5 | IK foot accuracy | T1 | sample foot-vs-target **inside `skeleton_updated`** | mean < 6% leg reach, worst < 35% (swings incl.) |
| G6 | LOD2 canned animates | T1 | `canned.pose_writes` + bone/pos change, IK off | writes > 5; visible motion; `ik.active == false` |
| G7 | LOD3 frozen | T1 | root displacement while forced LOD3 | < 1 mm over 30 frames |
| G8 | Native↔GDScript parity | T3 | same seed, both backends → surfaces, per-surface verts, AABB | counts equal; AABB Δ < 0.01 |
| G9 | Native faster | T3 | build 20 creatures each backend | `t_native < t_gd` |
| G10 | Determinism | T3 | same seed twice → bone count + mesh verts + AABB | identical counts; AABB Δ < 1e-3 |

## 2. Tiers mapped to this system

- **T0 static gate:** `--check-only` on `creature/*.gd`; `scons` compile/link of the `MeshForge`
  GDExtension (optional — the project runs GDScript-only if absent).
- **T1 headless smoke:** `procgen_creatures/tests/smoke_test.gd` — G1–G7. Deterministic seed herd
  (organic + robotic), flat ground + a bump/ramp for raycast placement, `force_now(tier)` for LOD.
- **T2 visual harness:** `test/main.gd` playground — R reroll, 0 auto-LOD, 1–4 force LOD, orbit/zoom,
  on-screen live LOD + fps. Human check of gait feel, seam quality, LOD pop.
- **T3 regression/parity:** G8–G10 — the smoke test's native block already does parity + benchmark
  when the extension is loaded; determinism is a seed-repeat assertion to add.

## 3. Harness (already implemented)

`extends SceneTree`; builds a `world` with a ground box + a raised bump, spawns a 6-creature herd
(seeds `[11,22,33,44,55,66]`, first three organic, rest robotic), settles, then runs and samples.
Key patterns (shared doctrine): sample IK **inside `skeleton_updated`**; `force_now(tier)` so LOD is
immediate (the 4 Hz poll is too slow for assertions); import pass before the script run.

## 4. Test seams — already present (no new hooks needed)

The gait code exposes what the test needs without extra getters, unlike the physics system:

| Seam | Used by |
|---|---|
| `gait.steps_taken` | G4 |
| `canned.pose_writes` | G6 |
| `c.rig` dict (skeleton, mesh_instance, legs[], stand_h, …) | G1/G2/G5 |
| `c.lod.current`, `set_forced_lod(t)` / `lod.force_now(t)` | G6/G7, T2 |
| `PartMeshLib.native_available()` / `.backend` | G8/G9 |

## 5. Reference results (author-claimed, Godot 4.6-stable — reproduce in CI)

| Metric | Reported |
|---|---|
| IK foot error, mean | **0.0002 m** (0.2 mm) over 1620 samples, 6 creatures, uneven ground |
| IK foot error, worst | 0.033 m (one-frame swing lag) |
| GDScript↔native mesh parity | surfaces + per-surface verts equal; **AABB Δ 0.0000** |
| Native build speedup | **×2.5** end-to-end (mesh bake far higher; node setup now dominates) |
| Smoke test result | 0 failures, exit 0 |

Record any re-run here with `{engine build, backend}` alongside.

## 6. Known limitations / caveats

- **Not re-executed in this pass** — §5 is the author's report; CI needs to reproduce it.
- **Teardown abort:** quitting the `SceneTree` with dozens of live creatures mid-physics can print a
  harmless abort *after* all asserts pass (exit code still valid); isolated runs are clean.
- **Single precision:** the C++ forge must use 32-bit math to match GDScript `Vector3` for exact G8
  parity (handoff §10).
- **Humanoid archetype (Synty)** and **gait-style baking** (handoff §11–12) are **design guidance,
  not headless-validated** — they need the actual FBX assets. Verify them separately once assets land.
- The gait↔physics **merge** now has its own module + test —
  [`gait_physics_merge/`](gait_physics_merge/) (feed a gait Target into the ragdoll drive; assert
  track + stumble). Draft, not yet run.

## 7. Pitfall checklist (from handoff §10 — a test guards these)

- Pole node on **every** `TwoBoneIK3D` setting (silent no-op otherwise) → G5 catches regressions.
- `process_physics_priority = -10` on target/pose writers → feet-lag regression shows as G5 worst-err.
- Knee pre-bent in rest pose (solver bends the right way).
- No world-space snapshots in `_ready()`; feet lazy-init first tick; `teleport_reset()` after teleports.
- `skeleton.modifier_callback_mode_process = MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS`.
- `force_now(tier)` in tests — don't wait for the 4 Hz poll.
- Import pass before any headless script run.

## 8. How to run (when reproducing — see [strategy §3](_shared/verification_strategy.md))

```bash
# optional native backend
scons -C native                                   # build MeshForge (editor closed)
godot --headless --path . --import                # generate .godot/, load the extension
godot --headless --path . --script tests/smoke_test.gd   # exit 0 = pass
```
