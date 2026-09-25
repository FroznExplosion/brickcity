# Gait ⇄ Physics Merge

**Status:** 2026-07-17 · **reference artifact, NOT yet run.** The module that fuses the two systems:
a procedurally-generated creature (kinematic **gait** = Target) driven by the **physics** layer
(active-ragdoll Puppet) so it walks *any* morphology **and** reacts to forces — stumble, knockdown,
ragdoll death — then recovers its gait. Part of the [master doc](../README.md).

This is where [`procgen_creatures`](../procgen_creatures_spec.md) and
[`physics_animation`](../physics_animation/spec.md) stop being two systems and start being one
pipeline. The *why* and the design are in
[`sta_active_ragdoll/INTEGRATION_WITH_PROCGEN.md`](../sta_active_ragdoll/INTEGRATION_WITH_PROCGEN.md);
this folder is the *concrete code + test*.

---

## Files

```
gait_physics_merge/
├── README.md                    ← this
├── creature_ragdoll.gd          ← the merge: gait Target → physics Puppet velocity drive, hit/LOD
├── creature_split.gd            ← split an already-built creature (thin wrapper → CreatureBuilder.split_rig)
├── VERIFICATION.md              ← merge test plan (invariants M1–M7)
└── tests/merge_smoke_test.gd    ← reference headless test — DRAFT, not run
```

## How it works (one screen)

```
ProcCreature (Target)                         Puppet (physical duplicate)
  GaitController + TwoBoneIK3D                   PhysicalBoneSimulator3D
  pose rig.skeleton kinematically                 one PhysicalBone3D per {body, spine, leg}
  = "walk any morphology"                         sized from DNA, cone-twist joints
            │                                              ▲
            └──── CreatureRagdoll: velocity-drive ──────────┘   (LOD0, physics ON)
            └──── copy Target → Puppet ─────────────────────┘   (LOD1+, physics OFF)

hit(bone, impulse) →  impulse + drop track_* briefly →  stumble →  drive ramps back →  recover
```

The drive (`_drive_step`) is **morphology-blind** — it loops the built bone list and pushes each
toward `target.get_bone_global_pose(idx)`. The rig (`_build_physical_rig`) is generated from the
creature's `rig` dict + `dna`, so 1-leg-pair or 3-leg-pair creatures work from the same code — no
hardcoded bone names (contrast the humanoid `ActiveRagdoll`, which hardcodes Synty names).

## Usage

```gdscript
# creature already built; its gait runs on rig.skeleton (the Target).
# One call: CreatureSplit makes the visible mesh render from a Puppet skeleton, CreatureRagdoll
# builds the physical rig on it and drives it. Physics ON at LOD0.
var rag := CreatureRagdoll.attach_to(creature)

rag.set_lod(1)                                         # far away → kinematic, physics off
rag.hit(creature.rig.legs[0].lower, hit_dir * force)  # on damage → stumble + recover

# Manual form (if you already have the two skeletons):
#   rag.setup(puppet_skel, target_skel, creature.dna, creature.rig)
```

## Two implementation paths

| | This module (GDScript) | Production (C++) |
|---|---|---|
| Drive | GDScript velocity drive per bone | `ActiveRagdoll` — **now takes `custom_bone_specs`** (spec §5, done 2026-07-17) |
| Speed | fine for the few LOD0 creatures at once | C++, same drive as the humanoid player |
| Rebuild | none | rebuild the GDExtension |
| Use | portable reference, proves the wiring | ship path |

Both share the exact same *design* (Target/Puppet + velocity drive + authority-drop hits). This
module proves it end-to-end without a C++ change. **The C++ ship path is now open:** `ActiveRagdoll`
accepts a `custom_bone_specs` Array (empty = the humanoid default, so the player is untouched), so one
C++ physics core serves players and generated creatures alike — see spec §5 for the Dictionary keys +
a GDScript example. Both C++ creature gaps are closed: rig from `custom_bone_specs`, and
`set_base_velocity()` (call per physics frame) feeds the drive when there's no `CharacterBody3D`
parent. The Target/Puppet split is folded into the (GDScript) builder —
`CreatureBuilder.build(dna, root, true)` or `CreatureBuilder.split_rig(rig, parent)`; `CreatureSplit`
delegates there. And `ActiveRagdoll.set_target_skeleton()` closes the last drive coupling (it no
longer assumes a `"CharacterMesh"` Target), so a creature can now ride the **C++** drive directly:
`custom_bone_specs` (rig) + `set_target_skeleton` (gait as Target) + `set_base_velocity` (feed-forward)
— see [physics spec §12](../physics_animation/spec.md) for the snippet. The only thing still
GDScript-by-design is `CreatureBuilder` itself (scene construction, tuning-heavy — no perf reason to
port). This GDScript module remains the no-rebuild path.

## Verify

See [`VERIFICATION.md`](VERIFICATION.md) — M1 rig-from-morphology, M2 tracks-the-walk, M3
stumble+recover, M4 knockdown/death, M5 LOD gate, M6 morphology-agnostic, M7 determinism. Nothing run
yet; numbers are targets.
