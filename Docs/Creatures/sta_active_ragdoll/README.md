# STA Active-Ragdoll — dropped in beside the procedural creatures

This folder is a **verbatim copy** of STA's physics-driven animation system (the "active
ragdoll"), placed next to the `procgen_creatures` procedural-creature system so the two can
share a core. They solve **two different problems** and should stay separate front-ends over
one shared physics spine.

| System | Lives in | Good at |
|---|---|---|
| **procgen_creatures** (this repo) | `../procgen_creatures/` | Any morphology, herds, zero clips, cheap, LOD. **Kinematic** — no dynamics. |
| **STA active ragdoll** (here) | `sta_active_ragdoll/` | Humanoid, authored clips, real physics reaction (get shot → stumble). **Dynamic** — heavy. |

Neither replaces the other. The endgame (see `INTEGRATION_WITH_PROCGEN.md`) is: keep the
procedural gait as the **Target**, bolt the active-ragdoll physics layer on as the **Puppet**,
LOD-gate it so only near creatures pay for physics.

---

## What's in here (all copied from the live STA project)

```
sta_active_ragdoll/
├── README.md                       ← you are here
├── INTEGRATION_WITH_PROCGEN.md     ← the merge design + "why can't the gait stumble?" answer
├── ACTIVE_RAGDOLL_ANIMATION.md     ← STA's own canonical reference (architecture, research, params, roadmap)
├── src/
│   ├── active_ragdoll.h            ← the C++ GDExtension class (ActiveRagdoll : Node)
│   └── active_ragdoll.cpp          ← full implementation: rig build, velocity-drive PD, foot IK
└── gdscript/
    ├── PlayerController.gd          ← the real integration: builds ragdoll + AnimationTree, feeds blend params
    ├── anim_debug_menu.gd           ← in-game F3 tuning panel (sliders write params live)
    ├── extract_anims.gd             ← headless FBX → AnimationLibrary packer (phase-align + rescale)
    ├── weapon_controller.gd         ← STA-specific (gun rig + IK) — reference only
    └── recoil_holder.gd             ← STA-specific (camera recoil) — reference only
```

## Which parts are reusable vs STA-specific

**Reusable for creatures (the shared spine):**
- `active_ragdoll.cpp` → `_build_rig()` — how to build a `PhysicalBoneSimulator3D` + cone-twist
  `PhysicalBone3D` chain on a skeleton, **including the Blender cm→m scale fix** (`body_offset`).
- `active_ragdoll.cpp` → `_pd_step()` — the **velocity-drive** ("soft keying") that makes physical
  bones chase a target pose. This is morphology-agnostic: it just loops over `bones` and drives
  each toward `target_skel->get_bone_global_pose(idx)`. Drop in as-is.
- The **Target / Puppet split** (`_build_target`, `_copy_target_to_puppet`,
  `_copy_unsimulated_to_puppet`) — identical idea to the creature's "gait writes targets, body
  follows." The procedural gait becomes the Target.
- `_foot_ik()` + `_solve_leg_ik()` — analytic 2-bone solve. The creature system already does its
  own foot placement via `TwoBoneIK3D`; this is the CPU-side alternative if you don't want the
  engine modifier.
- The **research + parameter table** in `ACTIVE_RAGDOLL_ANIMATION.md` §2–3 (why velocity drive,
  not torque PD; the snap-distance blow-up guard; the feed-forward-base-velocity fix).

**STA-specific — reference only, do NOT copy wholesale:**
- The 16 hardcoded Synty bone names (`Hips`, `Spine_01`, `UpperLeg_L`…). Creatures have a
  generated skeleton — you feed bone indices from `CreatureBuilder`'s rig dictionary instead.
- The whole 75-clip humanoid AnimationTree in `PlayerController.gd` (`_setup_locomotion`,
  `_update_anim_layers`, transitions). Creatures don't use clips — the gait engine IS the Target.
- `weapon_controller.gd`, `recoil_holder.gd`, camera modes — FPS player only.

## Build / registration note

`ActiveRagdoll` is a `godot-cpp` GDExtension class registered in STA's `register_types.cpp`
alongside its other native classes. To use it in *this* project, register it in the
`procgen_creatures/native` extension exactly like `MeshForge`:

```cpp
// register_types.cpp, in initialize_*_module(MODULE_INITIALIZATION_LEVEL_SCENE):
GDREGISTER_CLASS(ActiveRagdoll);
```

Build: close the Godot editor (DLL lock), then `scons` in the native dir. Same toolchain the
creature forge already uses (godot-cpp master vs 4.6, `custom_api_file` from your binary).

See `INTEGRATION_WITH_PROCGEN.md` for the actual wiring.
