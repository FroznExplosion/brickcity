# Procedural creatures — copied from BoomerBorder

Copied 2026-09-25 from `boomer-border/Docs/ProceduralChracters/` ([AIPlan](../AIPlan.md) P1, R20).
The docs and reference code are here as they stood; a `.gdignore` keeps Godot from importing this
folder, because the reference code defines classes (`PlayerController`) that clash with ours.

| What | Where now | State |
|---|---|---|
| Procgen creatures: DNA, builder, part meshes, gait, LOD | `scripts/creatures/` | **Works.** `tools/creature_probe.gd` passes: six seeds build valid skinned meshes (bones, weights, normals, AABB), walk, step, IK within tolerance, canned gait at LOD2 |
| `MeshForge` — the native mesh builder (`creature_forge`) | `gdextension/brick/src/creature/`, built into the brick extension | **Windows build done** (it shipped Linux-only). Same meshes as the GDScript path to the vertex; 2.1× faster (20 creatures: 31.9 → 14.9 ms) |
| Gait ⇄ physics merge (`CreatureRagdoll`, `CreatureSplit`) | `scripts/creatures/` | **First run ever** (`tools/creature_merge_draft.gd`, not a gate): 6 of 13. Builds physical bones from any morphology, walks, leaks nothing; tracking 5.7 cm against its 5 cm target, and the stumble, knockdown and recovery do not work yet |
| Physics animation (`ActiveRagdoll`) and the STA active ragdoll | `physics_animation/`, `sta_active_ragdoll/` here | Specs and reference code only; never built, not built here |

Numbers are targets from BoomerBorder's VERIFICATION docs unless measured above. The creatures'
randomness is already a seeded `RandomNumberGenerator` per DNA, which D9 wants.
