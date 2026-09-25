# Active Ragdoll Animation System — Reference

Status 2026-07-02. The player's physics-driven animation system: what it is, why it's built
this way, the research behind it, every parameter, known issues, and the roadmap.

Code: `native/src/active_ragdoll.{h,cpp}` (class `ActiveRagdoll : Node`, registered in
`sta_native`), driven from `scenes/player/PlayerController.gd`. Tuning UI:
`scenes/player/anim_debug_menu.gd` (**F3** in game). Test stage: `scenes/anim_studio.tscn`
(**F6** / Play Scene). See also `Docs/12_SWARM_ENEMY_SYSTEM.md` §8 and memory note
`nut-up-character-ragdoll-source`.

---

## 1. Architecture — Target / Puppet

Two copies of the same Synty rig (`assets/characters/Enemy1.glb`):

```
TARGET  (hidden "AnimTarget" duplicate)         PUPPET  (visible CharacterMesh)
  AnimationTree: BlendSpace1D by speed            Skeleton3D + PhysicalBoneSimulator3D
  idle / walk / run / sprint clips                16 PhysicalBone3D capsules, cone-twist joints
        │  writes bone poses                            ▲
        └────────── velocity drive per bone ────────────┘
                    (ragdoll ON)
        └────────── full pose copy ─────────────────────┘
                    (ragdoll OFF — mesh just plays the clip)
```

- **Target** = "what the body wants to do." Clips play here; later, procedural layers (foot
  IK, lean, aim) stack on top of the clip pose.
- **Puppet** = "what the body physically does." Physics bones chase the target each frame.
- Ragdoll OFF: puppet copies every bone rotation from the target (`_copy_target_to_puppet`)
  = looks exactly like the standard animation.
- Ragdoll ON (**G**): the 16 physical bones are velocity-driven at the target pose
  (`_pd_step`); bones *without* physics bodies (Head, Neck, fingers, toes) still copy from
  the clip (`_copy_unsimulated_to_puppet`) so they don't freeze at rest.

Player CharacterBody3D (ceramicedge movement port) stays the gameplay authority: camera,
collision capsule, aim all read the kinematic body/Target — the puppet is visual.

## 2. Why velocity drive (the research)

We first built a torque/force PD controller (springs pushing every bone). Result: untunable
whack-a-mole — fix standing, break walking. Research verdict:

- **Jolt's author** (our physics engine) lists three active-ragdoll methods and calls manual
  force/torque application "difficult to tune". Recommended: **velocity-based driving** or
  **joint motors**. https://github.com/jrouwe/JoltPhysics/discussions/1764
- **CBerry22's Godot 4 active ragdoll** (the known-working Godot example) also drives
  velocities, with a ~1 m "snap teleport" blow-up guard.
  https://github.com/CBerry22/Active-Ragdoll---Physics-Animations-in-Godot-4.0
- **PuppetMaster** (Unity — Human Fall Flat-class tech) drives rotation at the *constraint*
  level (ConfigurableJoint SLERP drives = solver-integrated, stable) + world-position pin
  forces. External torque is exactly what it avoids.
  http://root-motion.com/puppetmasterdox/html/page5.html
- **R3X-G1L6AME5H/Godot-Active-Ragdolls** abandons PhysicalBone3D for RigidBody+6DOF joints
  ("you'll find PhysicalBones to be unsatisfactory" for active ragdolls).
  https://github.com/R3X-G1L6AME5H/Godot-Active-Ragdolls

**Velocity drive ("soft keying"):** per physical bone, per physics frame:

```
lin_vel = (target_pos − current_pos) / dt × track_position    (clamped to max_lin_speed)
ang_vel = axis·angle(target_rot × current_rot⁻¹) / dt × track_rotation   (clamped to max_ang_speed)
error > snap_distance  →  hard-teleport bone to target
```

Set through `PhysicsServer3D::body_set_state`. Unconditionally stable (no spring gains to
explode), tracks exactly at track=1, and collisions still perturb the body — the next frame
re-aims, so impacts read physically. Gravity/damping on the bones are effectively overridden
each frame; bone **mass now only matters for collision response**, not tracking.

Other reference points for the broader goal:
- Uncharted 4 GDC: powered ragdolls via motorized joints + gravity compensation.
- Overgrowth GDC (David Rosen "An Indie Approach to Procedural Animation"): rich motion from
  very few keyframes + physics — the model for our later procedural layers.
- Rain World / Spore / NMS: fully procedural gait for arbitrary creatures (see §6).

## 3. Parameters (F3 menu → ActiveRagdoll)

Velocity drive (the ones that matter):

| Param | Default | Meaning |
|---|---|---|
| `use_velocity_drive` | true | off = legacy torque PD (comparison only) |
| `track_position` | 1.0 | 0–1, how hard bones chase target positions. 1 ≈ clip-exact |
| `track_rotation` | 1.0 | 0–1, same for orientation. Lower ⇒ looser, more physical |
| `max_lin_speed` | 12 | m/s clamp on corrective velocity — lower = heavier feel |
| `max_ang_speed` | 50 | rad/s clamp |
| `snap_distance` | 1.0 | m; bone farther than this teleports back (blow-up guard) |

Legacy torque-PD gains (only when `use_velocity_drive` off): `anim_authority`,
`root_pos_kp/kd`, `root_rot_kp/kd`, `limb_rot_kp/kd`. Kept for A/B testing.

Other: `simulating` (= G key), `pd_enabled`, `use_procedural_walk` (the old sine walk —
off since clips landed), `set_head_hidden(bool)` (FPS scales Head bone to 0).

Physical rig (16 bones): Hips(root) · Spine_01/02/03 · UpperLeg/LowerLeg/Ankle L+R ·
Shoulder/Elbow/Hand L+R. Cone-twist joints, per-bone mass 6→1. Collision layer 3, mask
World-only (never the player capsule, never each other). Blender cm→m scale fix from nut-up
applied via `body_offset` (see Docs/12 §5) — do not remove.

## 4. Animation source & pipeline

- Clips: **Synty POLYGON Base Locomotion** pack at
  `res://ANIMATION_Base_Locomotion_SourceFiles_v3 (1)/` — same skeleton as Enemy1.glb ⇒
  **zero retargeting**. Use the in-place variants, not `_RootMotion_`.
- `tools/extract_anims.gd` (run headless) packs chosen FBX clips into an AnimationLibrary:
  currently idle/walk/run/sprint (Masculine) → `assets/characters/locomotion_slice1.res`.
- `PlayerController._setup_locomotion()` builds in code: AnimationPlayer (lib, root `..`) +
  AnimationTree BlendSpace1D on the **target** skeleton. Blend points: idle 0 / walk 2.5 /
  run 6 / sprint 10 (game `walk_speed` 8, `sprint_speed` 11).
- Blend input = tangential speed (radial component stripped — works on the sphere),
  **smoothed** (`lerp` ~6/s) — raw speed sweeps 0→8 in ~0.1 s through phase-unsynced clips
  and the oscillating blend makes the ragdoll jitter at every start/stop.
- Gotcha: the clips' Hips/Root **position** tracks are wrong-scale for our rig — the PD/
  velocity step pins target root+hips translation to rest and uses **rotations only**,
  otherwise the ragdoll folds to the floor.

## 5. Known issues / current state

- Start/stop jitter (~1 s): mitigated by blend smoothing (§4). If still visible, raise the
  smoothing rate or sync clip phases (§6).
- Head side-sway while running: fixed by `_copy_unsimulated_to_puppet` (head now plays the
  clip's stabilizing counter-rotation). Residual sway = spine physics; lower `max_ang_speed`
  or reduce `track_rotation` slightly.
- FPS arms: locomotion clips swing arms naturally; a weapon-ready hold needs an **additive
  upper-body aim layer** (later).
- Feet still slide a little on slopes/turns: needs foot IK (§6).
- `AnimStudio` (F6): infinite platform, obstacle spawner, tools panel; F3 sliders write live.
  "Print Values → Output Log" dumps current numbers for baking into defaults.

## 6. Roadmap

Near (locomotion completeness):
1. ~~2D strafe blendspace~~ **DONE 2026-07-02** — loco is a BlendSpace2D: idle center, 8-way
   walk ring @2.5 m/s, 8-way run ring @6, sprint fwd @10; input = body-local (side, fwd)
   tangential velocity, smoothed. Library = 24 clips.
   Also fixed >12 m/s fall jitter: velocity drive now feed-forwards the player's base
   velocity (`want = player_vel + clamped_correction`) — the max_lin_speed clamp only limits
   the correction, so fast falls no longer hit the snap-teleport loop.
2. ~~Jump/land~~ **DONE 2026-07-02** — layered BlendTree (built in code, `_setup_locomotion`):
   `loco → air(Blend2: fall blendspace by fall speed) → land(Blend2: soft/med/hard one-shot,
   restarted via TimeSeek) → crouch(Blend2: crouch_idle by jump charge)`. Landing weight AND
   clip choice scale with peak fall speed (max at `LAND_MAX_IMPACT` 14 m/s, linear below);
   land pose releases over `LAND_FADE_TIME` 0.8 s. Crouch-charge: blend follows
   `_jump_charge_t/jump_charge_time` (tap ⇒ no crouch); library now has 10 clips
   (`tools/extract_anims.gd`, land clips LOOP_NONE). Weights fed per-physics-frame in
   `_update_anim_layers` (PlayerController).
3. ~~Clip phase sync~~ **DONE 2026-07-02** — extractor post-process (`_phase_align` +
   `_rescale` in `tools/extract_anims.gd`): every gait cycle is rotated so UpperLeg_L's max
   forward swing sits at t=0 (comparable anchor across clips), then rescaled to a shared
   0.75 s cycle. Combined with `sync = true` on the loco blendspace and all Blend2 layers
   (zero-weight branches keep advancing), every gait clip stays phase-locked forever —
   blends never mix opposite foot phases.

3b. **DONE 2026-07-02 — moving jumps + slope locomotion + strafe-triangulation fix.**
   Library = 34 clips. Jump one-shots (idle/walk/run/sprint by takeoff speed) restart via
   TimeSeek on the airborne edge, cross-fade to the fall pose once descending (`airpose`
   Blend2, `_fall_mix`). Slope: `slope` Blend3 (downhill / flat loco / uphill), amount =
   signed steepness vs 25° × forwardness × speed ramp; up/down 1D blends by speed.
   Loco BlendSpace2D now uses MANUAL triangles (`auto_triangles = false`) — auto-Delaunay
   degenerated on the collinear idle→walk_r→run_r axes and pure-side strafing showed the
   walk ring at run speed. Remaining unused pack clips: transitions (Idle_ToRun/Walk,
   ToIdle L/R-foot, Stand↔Crouch, Sprint_ToCrouch), turn-in-place, shuffles, 12-way crouch
   ring, Neutral additive Lean/HeadLook/BodyLook.

3c. **DONE 2026-07-02 — transitions + speed remap.** Library = 44 clips. One reusable
   `trans` one-shot slot (AnimationNodeAnimation swapped at runtime + TimeSeek + 80 ms/250 ms
   weight envelope, cancelled if airborne): start (Idle_ToWalkF/ToRunF by sprint key), stop
   (Walk/Run_ToIdle, alternating planted foot, picked by exit speed), turn-in-place
   (Turn_90/180 L/R when idle body yaw accumulates past 60°/150°). `_map_speed` piecewise
   remap (game 0/2.5/8/11 → blend 0/2.5/6/10) fixes walk_speed-8 over-blending sprint and
   full-speed strafes under-blending the 6 m/s run ring.

3d. **DONE 2026-07-02 — crouch locomotion.** Library = 56 clips. `crouch_bs` BlendSpace2D
   (manual triangles): crouch_idle center → 4-way crouch-shuffle ring @1.2 → 8-way crouch
   strafe ring @3.0; input = body-local velocity scaled so full crouch speed (4 m/s) hits
   the strafe ring. Crouch Blend2 weight: 1.0 in State.CROUCHING, else jump-charge fraction
   (tap = no crouch). Pack leftovers: standing shuffles, Crouch_ToStand/Stand_ToCrouch/
   Sprint_ToCrouch transitions, crouch turns, 90/180 directional starts, Neutral additive
   Lean/HeadLook/BodyLook.

3e. **DONE 2026-07-02 — pack complete (75 clips).** Standing shuffle ring @0.9 added inside
   the walk ring (loco = idle → shuffle4 → walk8 → run8 → sprint). Transitions: stand↔crouch
   + sprint→slide (state-edge one-shots, override current), directional starts (F/90/180 L-R
   by initial move angle), crouch turn-in-place (cturn_90). Sliding holds the crouch pose.
   Additive Neutral sweeps layered at the chain end (Add2 + TimeSeek scrub): lean by smoothed
   yaw-rate×speed, head-look (1.0) + body-look (0.35) by camera pitch; mid-frame = neutral.
   Chain: loco→slope→air→land→crouch→trans→lean→hlook→blook→out. Trans moved ABOVE crouch so
   crouch one-shots aren't masked at crouch weight 1. Skipped: Feminine set, _RootMotion_
   variants, redundant Bck/Fwd strafe overlaps. If additive sweeps distort the pose (they're
   assumed delta-authored), zero parameters/lean|hlook|blook/add_amount.

Mid (the PrimalCore payoff):
4. ~~Foot IK~~ **DONE 2026-07-02** — C++ `_foot_ik` in ActiveRagdoll, runs on the TARGET
   skeleton each physics frame (after the root-position pin, before PD/copy → both modes
   inherit it). Per foot: ray (mask=World) at the animated ankle's XZ from knee height;
   correction = terrain height vs capsule-bottom plane, clamped ±0.5/0.45 m; weighted by
   stance phase (ankle < 0.12 m = full plant, fades to 0 by 0.37 m so swinging feet are
   untouched); pelvis drops by the most-negative offset so the downhill leg reaches;
   2-pass analytic 2-bone solve (swing upper leg → law-of-cosines knee → re-aim), foot
   keeps the clip's world orientation; eased master weight, off in air. Toggle in F3
   (`foot_ik_enabled`). Hips pose position copies to the visible mesh (pelvis drop shows
   ragdoll-off).
5. **Additive aim/hold layer** for FPS arms; head look-at.
6. **Ledge grab / vault**: gross motion from clip, hand IK pins palms to the actual edge,
   body follows via ragdoll. Hooks into existing ceramicedge climbing states.
7. **Event-driven authority drops** — on impact/land/hit, momentarily lower `track_*` (or
   per-region) → physical stumble → blend back. This is the "dial back for physics" knob.
8. **Joint motors** (Jolt `PoweredRigTest.cpp` model) if velocity drive ever feels too
   kinematic: constraint-level drives = PuppetMaster-grade stability at max stiffness.

Far:
9. **MP**: replicate Target anim-state + events only; each client runs its own puppet
   (cosmetic). Never sync bone transforms.
10. **LOD**: distant characters = kinematic copy only (skip physics), swarm enemies stay on
    the cheap procedural tier (Docs/12 — never active-ragdoll a horde).
11. **Procedural creatures** (NMS/Spore-like): same Target/Puppet + velocity drive core;
    replace clip Target with a generic N-legged gait solver (lift/pause/plan per foot IK) on
    procedurally generated rigs. Humanoid clips don't transfer; the physics layer does.

## 7. Build / workflow notes

- Rebuild native: close the Godot editor (DLL lock!) → `python -m SCons -C native`
  (scons isn't on PATH; SCons 4.10.1 via Python 3.13). Compile works with the editor open;
  only the final link needs it closed.
- GDScript gate: `Godot_v4.6.1..._console.exe --headless --path . --check-only --script
  res://<file>.gd` (filter voxel-DLL noise when the editor is open).
- The F3 menu writes properties live — tune in `anim_studio.tscn`, hit **Print Values**,
  bake the numbers into `active_ragdoll.h` defaults.

## 8. Weapon handling & animation layering

### 8.1 Doctrine — author the finger-work, procedural the rest

The question "should we author real animations for everything, then add physics/procedural on
top?" — answer: **layer, but don't author everything.** Split by what each layer is good at:

| Author real clips | Keep procedural / physics |
|---|---|
| Reload (fingers + mag swap) | Recoil kick & settle |
| Draw / holster / weapon switch | Sway (look-lag) + walk bob |
| Bolt / charge handle, inspect | Aim-pitch blend, look-at |
| 1 weapon-ready idle + ADS pose | Hand-to-grip IK (support hand) |
| Fire "flourish" (optional) | Foot IK, landing spring, breathing |

Rule of thumb: **fingers manipulating an object ⇒ author. Continuous / reactive / infinite-angle
⇒ procedural.** You cannot author every aim angle or recoil pattern; you cannot fake a mag swap.
"Everything authored" also fights STA's whole bet (§1–2): minimize clip count, let the
Target→PD→Puppet physics chain carry weight and secondary motion.

### 8.2 The layer stack, mapped to Target/Puppet

Bottom → top, all composed on the **Target** skeleton *before* the PD (so the physical body
reacts to them), except the last which is cosmetic:

1. **Base locomotion clips** — have this (§4, 75-clip Synty pack).
2. **Weapon clips** (authored, blended into the AnimationTree): weapon-ready idle, ADS pose,
   **reload**, **draw/holster**. These override the unarmed arm swing.
3. **Procedural Target adjust** (pre-PD): support-hand-to-foregrip IK, aim-pitch offset, foot IK.
4. **Active-ragdoll PD / velocity drive** chases that composed Target ⇒ free weight, recoil
   settle, impact reaction (§2). Recoil "through physics" = push the Target pose / impulse the
   arm bones and let PD recover — this is where the ragdoll pays off vs a stiff viewmodel.
5. **Viewmodel handling** (post, cosmetic, on the gun **holder** — needs no body): sway, bob,
   recoil spring, ADS offset + FOV. This is the fast render-frame layer.

### 8.3 Current STA state (2026-07-04)

`scripts/player/weapon_controller.gd` (built in code by `PlayerController._setup_weapon`):
- Gun (`assets/weapons/SM_Civilian_Submachine_Gun.fbx`, static mesh) bolted to `Hand_R` via
  `BoneAttachment3D` → `WeaponHolder` Node3D → gun. Rides clips OR ragdoll automatically.
- Layer 5 (holder handling): **spring-based** sway/look-sway/move-tilt/bob/landing/breathing/
  ADS/recoil/holster, ported from reddawn (§8.4). Camera recoil via `RecoilHolder`
  (`scripts/player/recoil_holder.gd`) — a logic node that writes recoil onto the camera's own
  x/y each frame (NOT in the transform chain: reparenting the camera broke the hardcoded
  `CameraPivot/Camera3D` path solar_system.gd relies on; z stays with the movement roll tween).
- **Mount (`aim_mounted`, default on) = gun-authority rig**: the GUN is placed each frame from the
  EYE/aim (`_eye` = CameraPivot) so it lines up with the camera; BOTH arms are IK'd so the hands
  reach hard grip markers on the gun (`GripR` trigger hand, `GripL` foregrip). ADS slides the gun
  so its `Sight` marker lands on the aim axis (`ads_sight_distance` ahead) → model-independent
  auto-sight. Immune to ragdoll arm flail (gun isn't bolted to a physical hand). WeaponRoot is a
  standardized node (barrel −Z, grip at origin); the visual FBX is a `Mesh` child holding all
  model correction (`model_*`). Hand-mounted fallback (`aim_mounted=false`) = bolt to Hand_R +
  left-only IK. 2-bone solve = `_solve_arm_ik` (ported `ActiveRagdoll::_solve_leg_ik`), runs on
  the visible puppet post-`_physics_process`.
- Inputs: `fire`/`aim`/`reload`/`holster`. Hitscan from camera centre. Muzzle = OmniLight flash.
- Layer 2 (authored weapon clips) still **not done** — the aim-mount rig makes the arms *reach*
  the gun procedurally, but there's no authored rifle-idle/reload/draw clip on the body yet.

### 8.4 reddawn asset mine (`C:\Users\lbaun\Documents\reddawn`)

reddawn is the user's own working FPS. It is a **classic separate-viewmodel** design (arms +
weapon as a `Camera` child with `top_level`, per-weapon authored `AnimationTree` state machines,
a hidden 3P `WeaponProxy` barrel, recoil on a `CameraRecoilHolder` node). STA is **one body,
two cameras** — so the *structure* does NOT port, but the *procedural math* is directly reusable
(both are just transform offsets). License: user's own code, free to reuse.

**PULL (high value):**
- **Spring handling** — `player/scripts/procedural_anim_layer.gd`. Proper critically-damped
  springs (`force = k·(target−x) − c·v; v+=f·dt; x+=v·dt`) for velocity sway, look sway
  (pitch + roll from accumulated mouse delta), movement tilt (strafe roll / sprint pitch), walk
  bob, **landing impact spring**, idle breathing — each with an ADS multiplier. Strict upgrade to
  STA's lerp layer-5; port the math onto `WeaponHolder`. Note its undo/reapply pattern (subtract
  last frame's offset first) is a viewmodel move-toward quirk — STA doesn't need it (holder is
  authoritative), just write the offset each frame.
- **Two-phase recoil holder** — `addons/Weapons/Scripts/Camera/CameraRecoilHolderScript.gd`.
  A node between pivot and camera: `targetRotation` accumulates on fire and decays to zero;
  `currentRotation` chases it; clamped to `MAX_RECOIL_PITCH`. Auto-recovering camera kick —
  better than STA's current `PlayerMovement.add_view_punch` (permanent pitch shift). Port as a
  `RecoilHolder` Node3D inserted `CameraPivot → RecoilHolder → Camera3D`.
- **Recoil model** — `addons/fps-hands/fps-hands.gd`: streak-based hip-fire recoil curve
  (smoothstep bell, controlled→worst→settled), ADS-vs-hip multiplier, camera shake via
  `h_offset`/`v_offset`/roll, close-range raycast fix (enemy between camera & muzzle).
- **VFX + ammo (later slices)** — bullethole/scratch decals, muzzle flash/smoke scenes;
  Insurgency-style per-magazine ammo (`_magazines` dict, chamber +1, tactical vs speed reload,
  fullest-mag-first) in the same file.

**DON'T pull:** the viewmodel arms and per-weapon authored `AnimationTree`s — they live on a
camera-child viewmodel skeleton, are FPS-only, and won't show in STA's third-person body. STA's
weapon clips (layer 2) must target the **Enemy1/Synty body rig** instead (author or retarget).

### 8.5 Next steps

1. ~~Port the spring layer onto `WeaponHolder`~~ **DONE 2026-07-04** — `weapon_controller.gd`
   `_update_handling` is now the full spring stack (§8.4).
2. ~~Add the RecoilHolder camera node~~ **DONE 2026-07-04** — `recoil_holder.gd` (logic node,
   created in `PlayerController._setup_recoil_holder`, writes onto `camera.rotation.x/y`); `_fire`
   routes camera kick through it. `PlayerMovement.add_view_punch` kept for hit reactions, unused
   by recoil. **Do NOT reparent Camera3D** — the `CameraPivot/Camera3D` path is hardcoded in
   solar_system.gd / PlayerMovement.
3. **VFX slice**: tracer/bullethole decal + muzzle flash/smoke from reddawn (currently only an
   OmniLight muzzle pulse + hitscan signal).
4. **Layer 2 weapon clips** (bigger job): a weapon-ready idle + ADS pose additive on the body
   rig; reload/draw/holster one-shots. Author in Blender on Enemy1 or find a Synty-rig weapon
   pack (loco pack matched Enemy1 zero-retarget — a weapon pack likely needs retargeting).

**Tuning caveat (all handling params are @export, can't verify headless):** grip seating
(`grip_position/rotation/scale`), `ads_position`, `foregrip_position`, and spring strengths.
Recoil is now split: `recoil_*` = gun kick on the holder, `cam_recoil_*` = view punch on the
RecoilHolder; `RecoilHolder.recover_speed/snap_speed/max_pitch` shape recovery.
