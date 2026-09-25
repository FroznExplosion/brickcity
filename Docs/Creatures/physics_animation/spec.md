# Physics Animation System — Spec

**Status:** 2026-07-17 · validated against Godot 4.6-stable + Jolt (STA reference implementation
in `../sta_active_ragdoll/`). Game-agnostic: this spec describes the *system*, not any one game's
rig. Shared concepts (Target/Puppet, LOD, MP, engine facts) live in
[`../_shared/shared_core.md`](../_shared/shared_core.md) — read that first.

A **dynamic** character-animation layer: a ragdoll of real rigid bodies that **chases a target
pose** every physics frame, so the body follows animation *and* reacts to forces — gets shot,
shoved, knocked down, tangled — then recovers on its own. The counterpart to the **kinematic**
procedural-gait system ([`../procgen_creatures_spec.md`](../procgen_creatures_spec.md)); the two
share one spine (`_shared`) and plug into each other via the **PoseProvider** interface (§7).

---

## 1. Goal

Given any skeleton and a source of desired poses ("the Target"), make a physically-simulated copy
of that skeleton ("the Puppet") track the Target closely enough to read as normal animation, while
remaining a true rigid-body system so external forces produce **emergent** reactions (stumble,
stagger, knockdown, ragdoll death) with no authored hit animations.

Design pillars:
- **One drive, any rig.** The controller loops over a bone list and drives each toward its target;
  it never hardcodes "leg" or "spine." Humanoid (16 bones) and generated creatures (N bones) use
  the same code.
- **Any Target source.** Clip-driven `AnimationTree`, procedural gait, or a static rest pose — all
  are just "a skeleton posed each frame." The physics layer doesn't care which (§7).
- **Velocity drive, not spring gains.** Set each bone's velocity to reach its target this step
  (soft keying). Unconditionally stable, one tuning knob, no gains to explode (§4, research in
  `_shared`).
- **Pay only where seen.** Physics runs on near/important characters; everything else stays
  kinematic. LOD-gated, pooled, never herd-simulated (§8).

## 2. When to use (scope)

| Use the physics layer | Stay kinematic (gait / clip copy only) |
|---|---|
| Player, important NPCs, bosses | Distant crowd, herds (hundreds+) |
| Anything that must react to hits/impacts | Background actors that never get shot |
| Getting knocked down / ragdoll death | Anything past LOD1 |
| Piling up, being trampled, physical contact | Cutscene-precise motion (drive fights authored contact) |

The physics layer is a **toggleable overlay** on top of a kinematic pose source. Off = the Puppet
copies the Target = identical to plain animation, zero physics cost. On = the ragdoll takes over.

## 3. Architecture — Target / Puppet

Canonical definition in [`_shared`](../_shared/shared_core.md#targetpuppet). Summary:

```
TARGET skeleton (kinematic, hidden)            PUPPET skeleton (visible, physical)
  posed each frame by a PoseProvider (§7)        PhysicalBoneSimulator3D
  = "what the body WANTS to do"                    one PhysicalBone3D per driven bone
            │                                       joints hold the chain together
            │                                              ▲
            ├─ drive ON  ─ velocity-drive per bone ─────────┘  → follows + reacts (physics)
            └─ drive OFF ─ copy bone rotations ─────────────┘  → identical to plain animation
```

Two skeletons because the simulator overwrites the Puppet's poses while simulating — the animation
must live somewhere physics can't clobber. Bones **without** a physical body (fingers, toes, head,
tail if spring-driven) copy straight from the Target every frame so they don't freeze at rest
(`_copy_unsimulated_to_puppet` in the reference).

Ordering, per physics frame (critical):
```
1. PoseProvider poses the TARGET skeleton        (clips / gait / rest)
2. optional pre-drive layers on the Target       (foot IK, lean, aim — so the body reacts to them)
3. drive step: velocity-drive PUPPET → Target    (this section)
4. copy unsimulated bones Target → Puppet
```
The Target must be fully posed before step 3 reads it. In one `_physics_process`, do them in this
order (reference: `active_ragdoll.cpp::_physics_process`).

## 4. Validated engine facts (Godot 4.6 + Jolt — ground truth)

Physics-specific; general 4.6 skeleton facts, the engine-version floor, and the spring-vs-physical
choice are in [`_shared` §engine-facts](../_shared/shared_core.md#engine-facts). **Version floor:**
the ragdoll classes exist since Godot 4.3, so this system runs pre-4.6 — but tune for **Jolt**
(default for new 4.6 projects; opt-in for older/existing projects, and ~2–3× faster than
GodotPhysics3D for many-body ragdolls). Don't drive appendages that only jiggle (tails, antennae,
hair) with this system — use `SpringBoneSimulator3D` for those (see `_shared`
[§secondary-motion](../_shared/shared_core.md#secondary-motion)).

1. **Rig = `PhysicalBoneSimulator3D` child of the `Skeleton3D`.** Add `PhysicalBone3D` children to
   *it*, not the skeleton. Start/stop with `physical_bones_start_simulation()` /
   `physical_bones_stop_simulation()`. Keep the sim node `PROCESS_MODE_DISABLED` until simulating.
2. **Each `PhysicalBone3D` needs:** its `bone_name` set, a child `CollisionShape3D` (capsule),
   a `joint_type`, and (for cone-twist) `joint/cone_twist/swing_span_1|2` + `twist_span`. The root
   bone uses `JOINT_TYPE_NONE` (it's the driven anchor, not jointed to a parent).
3. **Velocity drive is set through `PhysicsServer3D::body_set_state(rid, BODY_STATE_LINEAR_VELOCITY
   , v)`** and `..._ANGULAR_VELOCITY`. Writing velocity every frame **overrides gravity and damping**
   for tracking purposes — so bone **mass only affects collision response**, not how well it tracks.
4. **The Blender cm→m scale trap.** Rigs imported from Blender (Synty, most GLB/FBX) carry a 0.01
   armature scale. Without compensation the physical bodies spawn ~100× off and the ragdoll
   explodes. Fix: multiply each bone's `set_body_offset` basis by `1 / inherited_scale`
   (`active_ragdoll.cpp:97–136`). Free guard even when scale is 1 — keep it.
5. **Collision layering is mandatory.** Put all ragdoll bones on their own layer; mask **World
   only**. Bones must **not** collide with each other (self-tangle) or with the character's own
   movement capsule (fights the controller). Reference: `collision_layer = <ragdoll bit>`,
   `collision_mask = <world bit>`.
6. **Snap guard against blow-ups.** If a bone's position error exceeds `snap_distance`, hard-set its
   transform to the target (teleport) instead of driving — catches explosions, respawns, and
   teleports before they feed back into a runaway velocity loop.
7. **Feed-forward the character's base velocity.** The Target rides the moving character; a bone's
   *total* wanted velocity is `base_velocity + clamped_correction`. Clamp only the **correction**,
   never the total — clamping the total makes bones lag during fast motion (>`max_lin_speed` falls)
   and hit the snap loop → jitter. (`active_ragdoll.cpp:493–507`.)

## 5. Rig-build contract (game-agnostic)

Input: a `Skeleton3D` + a **bone spec list**. Output: a `PhysicalBoneSimulator3D` with one
`PhysicalBone3D` per spec, plus a `simulated[]` mask marking which skeleton bones are physical.

A bone spec:

| Field | Meaning |
|---|---|
| `bone_name` / `bone_idx` | which skeleton bone this body drives |
| `radius`, `height` | capsule collider dimensions (from limb thickness/length) |
| `joint_type` | `NONE` for the root anchor, `CONE` (cone-twist) for the rest |
| `swing_deg`, `twist_deg` | cone-twist limits (looser on shoulders, tighter on knees) |
| `mass` | collision-response weight (heavier torso → lighter extremities), e.g. 6→1 |
| `is_root` | exactly one true: the driven anchor (hips/body) |

The spec list is **where morphology lives**:
- **Humanoid:** a fixed 16-entry list keyed on the rig's bone names (reference: Hips· Spine_01/02/03
  · UpperLeg/LowerLeg/Ankle L+R · Shoulder/Elbow/Hand L+R).
- **Procedural creature:** generate the list from the creature's rig dictionary — one entry per spine
  joint, per leg segment (`upper`/`lower`/`foot`), head. Sizes come from DNA limb lengths/radii.
  Leave tail/antennae to a spring sim, don't double-drive them.

Everything downstream (§6) is identical regardless of which list built the rig. **To support a new
creature type you write a spec list, not new drive code.**

**Reference implementation (done 2026-07-17).** The C++ `ActiveRagdoll` now takes an optional
`custom_bone_specs` (Array of Dictionaries) — empty falls back to the built-in Synty humanoid rig, so
the player is unchanged. Set it from GDScript *before* `add_child()` (so `_ready()`'s `_build_rig()`
sees it). Dictionary keys = this table: `bone_name` (String), `radius`, `height`, `joint_type` (int;
omit/`0` for the root, cone otherwise), `swing_deg`, `twist_deg`, `mass`, `is_root` (bool).

```gdscript
var specs := []
specs.append({"bone_name": "body", "is_root": true, "mass": 6.0, "radius": 0.14, "height": 0.3})
for leg in creature.rig.legs:
    specs.append({"bone_name": creature.rig.skeleton.get_bone_name(leg.upper), "mass": 3.0,
                  "radius": 0.05, "height": leg_upper_len, "swing_deg": 50, "twist_deg": 30})
    # …lower, spine, head…
var rag := ClassDB.instantiate("ActiveRagdoll")
rag.set("custom_bone_specs", specs)   # BEFORE add_child
creature.add_child(rag)
```

This is the "ship path" the GDScript merge reference ([`../gait_physics_merge/`](../gait_physics_merge/))
pointed at: one C++ drive for players and generated creatures alike. For creatures with no
`CharacterBody3D` parent, call `set_base_velocity(v)` each physics frame so the drive's feed-forward
(§6) still carries the body motion (else fast-moving creatures lag toward the snap loop). Both are
independent of the drive itself — see §6.

## 6. The drive (velocity drive / "soft keying")

Per physical bone, per physics frame. `target` = the bone's world pose on the Target skeleton;
`cur` = the physical body's current world transform; `dt` = physics delta.

```
pos_err = target.origin − cur.origin
if |pos_err| > snap_distance:                       # blow-up guard (§4.6)
    hard-set body transform to target; velocity = base_vel; continue

corr    = pos_err / dt × track_position             # corrective linear velocity
clamp |corr| to max_lin_speed                        # clamp CORRECTION only (§4.7)
lin_vel = base_vel + corr                             # feed-forward base motion

q_err   = target.rot × cur.rot⁻¹                     # shortest-arc orientation error
(axis, angle) = q_err.axis_angle()
ang_vel = axis × angle / dt × track_rotation
clamp |ang_vel| to max_ang_speed

body_set_state(LINEAR_VELOCITY,  lin_vel)
body_set_state(ANGULAR_VELOCITY, ang_vel)
```

Properties: unconditionally stable (no spring gains); tracks clip-exact at `track_*=1`; collisions
perturb the body mid-step and the next frame re-aims, so impacts read physically; lowering `track_*`
makes the body looser/floppier. Reference: `active_ragdoll.cpp::_pd_step`.

**Torque-PD fallback** (kept for A/B only, off by default): apply orientation torque + root position
force via spring gains. Documented as "difficult to tune" by Jolt's author and superseded by
velocity drive — see `_shared` research and `ACTIVE_RAGDOLL_ANIMATION.md §2`. New games should
leave `use_velocity_drive = true`.

## 7. PoseProvider interface — how any animation source plugs in

The physics layer only needs one thing from the animation side: **a Target skeleton that is fully
posed before the drive runs each physics frame.** Anything that can do that is a valid provider.

Contract:
- Provider owns/poses the **Target** skeleton (same bone layout as the Puppet).
- Provider writes poses in `_physics_process` at a priority **earlier** than the drive (or the
  drive calls the provider first, as the reference does with its built-in walk).
- Provider does not touch the Puppet.

Built-in / example providers:
| Provider | Target source | Used by |
|---|---|---|
| **ClipTree** | `AnimationTree` blending authored clips | humanoid player (STA: 75-clip Synty pack) |
| **ProceduralGait** | N-legged gait + `TwoBoneIK3D` (the kinematic system) | procedural creatures |
| **RestPose** | static rest transforms | "stand against gravity" fallback / v1 bring-up |
| **BuiltinWalk** | sine FK walk composed on rest (`_drive_walk`) | reference default before clips land |

Swapping providers is a flag, not a rewrite. Two ways to wire the Target:
- **Reference builds its own** (humanoid): the drive duplicates the visible mesh into a hidden Target,
  and GDScript attaches an `AnimationTree` to it via `get_anim_target_skeleton()`.
- **Inject a foreign Target** (creatures): call `set_target_skeleton(skel)` **before** `add_child()` to
  hand the drive a skeleton posed by *something else* — e.g. a procedural creature's gait skeleton.
  The drive then skips its built-in mesh-duplication and chases the provided skeleton. Set
  `use_procedural_walk = false` so the external provider (gait), not the built-in sine walk, poses it.

**This is the seam that lets one physics system serve different games** — and, with `set_target_skeleton`
+ `custom_bone_specs` + `set_base_velocity`, lets the *same C++ drive* serve procedural creatures, not
just the humanoid player.

## 8. Parameters

Canonical defaults from the reference (`active_ragdoll.h`). All live-tunable (reference ships an F3
slider menu, `anim_debug_menu.gd`).

| Param | Default | Meaning |
|---|---|---|
| `use_velocity_drive` | true | off = legacy torque-PD (comparison only) |
| `track_position` | 1.0 | 0–1, how hard bones chase target positions (1 ≈ exact) |
| `track_rotation` | 1.0 | 0–1, same for orientation; lower ⇒ looser/floppier |
| `max_lin_speed` | 12 m/s | clamp on the linear **correction** (heavier feel when lower) |
| `max_ang_speed` | 50 rad/s | clamp on angular correction |
| `snap_distance` | 1.0 m | error beyond which a bone teleports to target (blow-up guard) |
| *(torque-PD only)* | | `anim_authority`, `limb_rot_kp/kd`, `root_pos_kp/kd`, `root_rot_kp/kd` |

Tuning intent: **track_* = fidelity vs floppiness**; **max_* = how violently it recovers**;
**snap_distance = safety net**. That's the whole surface for the default drive.

## 9. Hit reactions — stumble, knockdown, death

This is what the kinematic gait **cannot** do (a `Skeleton3D` pose has no mass for a force to push —
see `../sta_active_ragdoll/INTEGRATION_WITH_PROCGEN.md §1`). With real bodies it's nearly free:

```gdscript
func hit(bone_idx, world_impulse, stagger := 0.5):
    PhysicsServer3D.body_apply_impulse(bone_rid(bone_idx), world_impulse)  # knock the bone
    track_rotation = 0.15    # event-driven AUTHORITY DROP: let physics win for a beat
    track_position = 0.4
    _recover_timer = stagger # tween track_* back to 1.0 over `stagger` seconds
```

- **Stumble/stagger:** impulse + brief authority drop → body lurches off the pose, then the drive
  ramps back and recovers. Strength scales with impulse size and how far/long `track_*` drops.
- **Knockdown:** larger impulse + longer, deeper authority drop.
- **Ragdoll death:** stop driving (`track_*` → 0 or stop the provider) → bones fall under gravity =
  passive ragdoll. Optionally crossfade back if revived.
- **Environmental:** knockback, explosions, being trampled = the same `apply_impulse` on the same
  bones. No special cases.

Per-region drops (drop only the struck arm's authority) give localized reactions; the reference
lists this under roadmap (§11).

## 10. LOD gating & performance

Physics is the expensive tier — gate it hard (policy shared with the gait system, see `_shared`):

- Build the physical rig **lazily on LOD0 entry**; tear it down (`physical_bones_stop_simulation`,
  free the sim) on demotion. Far characters never allocate bodies.
- **Cap concurrent physical characters** (pool them). A dozen active ragdolls = fine; a full herd =
  the wall. Distant/crowd actors stay on the kinematic tier.
- Mass matters only for collision response under velocity drive (§4.3) — don't over-tune it.

## 11. Multiplayer

Identical policy to the gait system (`_shared`): replicate `{seed, root transform, velocity}` +
**authoritative hit/death events**. Each client runs its own Puppet physics locally (cosmetic, may
diverge). **Never sync bone transforms.** The Target is deterministic from inputs/seed; the Puppet
is local flavor.

## 12. Public API surface (reference class `ActiveRagdoll : Node`)

Attach as a child of the character; it finds the visible `Skeleton3D`, builds the Puppet rig and a
hidden Target duplicate on `_ready`.

- `set_simulating(bool)` / `get_simulating()` — physics on/off (drive ON vs pose-copy).
- `get_anim_target_skeleton() -> Skeleton3D` — the **PoseProvider seam** (§7): attach your gait or
  AnimationTree to the built-in Target.
- `set_target_skeleton(Skeleton3D)` — **inject a foreign Target** before `add_child()` (e.g. a
  creature's gait skeleton); the drive then chases it instead of duplicating a mesh (§7).
- `set_custom_bone_specs(Array)` — build the rig from a bone-spec list (§5); empty = humanoid default.
- `set_base_velocity(Vector3)` — per-frame feed-forward when there's no `CharacterBody3D` parent (§5).
- `set_use_procedural_walk(bool)` — use the built-in walk vs an external provider.
- Drive tuning props: `track_position`, `track_rotation`, `max_lin_speed`, `max_ang_speed`,
  `snap_distance`, `use_velocity_drive`.
- `set_head_hidden(bool)` — FPS convenience (collapse a head bone).
- `foot_ik_enabled` — optional CPU foot planting on the Target (`_foot_ik`).
- Measurement hooks: `get_physical_bone_count()`, `get_physical_bone_rid(i)`, `get_mean_tracking_error()`.
- `hit(...)` / impulse helpers — add per your game (§9); the reference drives via `PhysicsServer3D`
  directly.

**Creature on the C++ drive (all four seams together):**
```gdscript
var rag := ClassDB.instantiate("ActiveRagdoll")
rag.set("custom_bone_specs", specs)              # rig from morphology (§5)
rag.set_target_skeleton(creature.rig.skeleton)   # gait skeleton = Target
rag.set("use_procedural_walk", false)            # gait drives it, not the sine walk
puppet_holder.add_child(rag)                      # rig builds on the puppet skeleton under the holder
# each physics frame: rag.set_base_velocity(creature_velocity)
```

Full signatures: [`../sta_active_ragdoll/src/active_ragdoll.h`](../sta_active_ragdoll/src/active_ragdoll.h).

## 13. Reference implementation

Complete, shipping, game-specific instance of this spec:
- `../sta_active_ragdoll/src/active_ragdoll.{h,cpp}` — the class. Read `_build_rig` (§5),
  `_pd_step` (§6), `_physics_process` (§3 ordering), `_foot_ik` (§7 pre-drive layer).
- `../sta_active_ragdoll/gdscript/PlayerController.gd` — a real ClipTree provider + integration.
- `../sta_active_ragdoll/gdscript/anim_debug_menu.gd` — the F3 live-tuning panel (§8).
- `../sta_active_ragdoll/ACTIVE_RAGDOLL_ANIMATION.md` — its narrative reference + research links.

Treat the reference as *one implementation*; this spec is the contract. Improving the reference
should not require editing this spec unless the **contract** changes.

## 14. Validation plan

Full plan + invariant table (V1–V13), thresholds, harness, and the reference script:
[`VERIFICATION.md`](VERIFICATION.md) + [`tests/smoke_test.gd`](tests/smoke_test.gd) (design only —
not yet executed), following the shared [verification strategy](../_shared/verification_strategy.md).
In brief, headless + in-editor checks (mirror the gait system's smoke test):
- Rig builds: N physical bones == spec list; capsules/joints/masks set; scale-fix applied.
- Drive off: Puppet pose == Target pose (bit-for-bit rotation copy).
- Drive on, no external force: bone-to-target error stays < a few cm at `track_*=1` over many
  frames on flat and moving characters.
- Snap guard: teleport the character → bones re-converge within one frame, no runaway velocity.
- Hit: apply a known impulse → body leaves the pose then returns to < tolerance within `stagger`.
- LOD: build/teardown on tier change leaks no bodies; far tier allocates none.

## 15. Known issues / roadmap

From the reference (`ACTIVE_RAGDOLL_ANIMATION.md §5–6`), generalized:
- **Start/stop jitter** if the Target pose oscillates (phase-unsynced clips) — smooth the provider's
  blend input; not a physics-layer bug.
- **Extremities without bodies** freeze unless copied from the Target every frame (§3) — required,
  not optional.
- Roadmap: per-region authority drops (localized reactions); **joint-motor / 6-DOF position-servo
  drive** if velocity drive ever feels too kinematic — a **supported Godot 4.6 + Jolt technique**
  (drive the constraint motor toward the target angle; solver-integrated ⇒ max-stiffness stability),
  not experimental. See `_shared` [§drive-options](../_shared/shared_core.md#drive-options). Also:
  event-driven authority as a general "dial back for physics" knob; procedural-creature rig
  generation (§5) = the merge with the gait system, prototyped in
  [`../gait_physics_merge/`](../gait_physics_merge/) (GDScript reference). C++ support landed —
  `custom_bone_specs` rig (§5) + `set_base_velocity()` feed-forward; the Target/Puppet split now lives
  in `CreatureBuilder.build(split:=true)` / `split_rig` (GDScript). A fully-C++ creature would also
  need the builder itself in C++ (procgen is GDScript-by-design) — out of scope.

## 16. Porting to a different game / engine

- **Different Godot game:** register the GDExtension class, attach `ActiveRagdoll` to your
  character, feed it a Target via `get_anim_target_skeleton()` (§7). Write a bone spec list for your
  rig (§5). Nothing else is game-specific in the core.
- **Different rig:** only the spec list changes.
- **Different engine:** the *design* ports (Target/Puppet + velocity drive + authority drop are
  engine-neutral); the API calls (`PhysicalBoneSimulator3D`, `PhysicsServer3D::body_set_state`) map
  to that engine's articulated-body + set-velocity equivalents. Keep §4.4–4.7 as the checklist of
  traps.
