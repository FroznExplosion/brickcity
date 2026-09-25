# Integration: give procedural creatures the STA physics layer

How the kinematic creature gait and the dynamic active-ragdoll fuse into one Target/Puppet
pipeline — and the answer to **"why can't the procedural approach stumble when shot?"**

> **This design now has a working reference module:**
> [`../gait_physics_merge/`](../gait_physics_merge/) — `creature_ragdoll.gd` (the code) +
> `VERIFICATION.md` + a smoke test. This doc is the *why*; that folder is the *how*. (Draft, not yet
> run.)

---

## 1. Why the gait can't stumble when shot (the core reason)

Short version: **the creature body has no dynamic bodies for a force to push.**

The `procgen_creatures` system is **kinematic**. Walk the data flow:

```
GaitController  →  writes IK target Node3D positions (world space)
TwoBoneIK3D     →  solves leg bone ROTATIONS to reach those targets
Skeleton3D      →  holds the resulting bone poses (pure math, a transform tree)
LookAtModifier  →  bends the head (math)
SpringBoneSim   →  the ONLY physics — and only on tail/antennae
```

Everything that defines the creature's *body* (torso, legs, head) is a `Skeleton3D` pose. A
`Skeleton3D` bone is not a rigid body. It has no mass, no velocity, no collider in the physics
world. So when a bullet arrives and you call `apply_impulse(...)`, **there is nothing to call it
on** — the torso and legs simply aren't present in the physics simulation. The impulse has no
target.

A "stumble" is by definition a *dynamic* response: an external force perturbs a mass, momentum
carries it off-balance, and a controller fights to recover. The gait has none of those
ingredients for the body. The best it can do is a **scripted** reaction — detect the hit in
code, play a canned hurt pose, or nudge the gait's targets. That can look okay, but it's
authored, not emergent, and it won't interact correctly with terrain, other creatures, or the
exact hit direction/strength.

(The tail and antennae *can* react — `SpringBoneSimulator3D` runs a real per-bone spring sim.
But those are cosmetic appendages. You can't stumble on your antenna.)

### Why STA's active ragdoll CAN stumble

STA's player body is **16 `PhysicalBone3D` rigid bodies** in a `PhysicalBoneSimulator3D`, joined
by cone-twist joints, living in the Jolt physics world (`src/active_ragdoll.cpp` `_build_rig`).
Each physics frame, `_pd_step` **velocity-drives** each bone toward the animated target pose:

```
lin_vel = base_vel + clamp((target_pos − cur_pos)/dt × track_position, max_lin_speed)
ang_vel =            clamp( axis·angle(target_rot × cur_rot⁻¹)/dt × track_rotation, max_ang_speed)
if |target_pos − cur_pos| > snap_distance → hard-teleport (blow-up guard)
```

Because the bones are real rigid bodies, a bullet impulse (`body_apply_impulse`) knocks them off
the target. Next frame the drive re-aims, but the `max_*_speed` clamps mean it can only pull back
so fast — so the body **visibly lurches, then recovers**. Drop `track_rotation`/`track_position`
for a moment (event-driven "authority drop", roadmap §6.7 in the reference) and it stumbles
*harder* before catching itself. Collisions with the ground/other bodies perturb it the same way,
for free. That reactivity is the entire reason the dynamic system exists — and exactly what the
kinematic gait cannot do.

---

## 2. The fix: gait = Target, ragdoll = Puppet

The two systems already share an architecture; they just don't know it yet.

| Concept | procgen_creatures calls it | STA active ragdoll calls it |
|---|---|---|
| "What the body *wants* to do" | the gait + IK solve | the **Target** skeleton (`AnimTarget`, clip-driven) |
| "What the body *physically* does" | (nothing — it's the same skeleton) | the **Puppet** skeleton (`PhysicalBoneSimulator3D`) |
| The bridge | — | **velocity drive** (`_pd_step`) |

Merge = split the creature's one skeleton into two:

```
TARGET skeleton (kinematic, hidden)              PUPPET skeleton (visible, physical)
  GaitController writes IK targets                 PhysicalBoneSimulator3D
  TwoBoneIK3D / LookAt / SpringBone solve            one PhysicalBone3D per generated bone
  → a full desired pose every frame                  cone-twist joints (limits from DNA)
            │                                                 ▲
            └──────────── velocity drive per bone ─────────────┘   (LOD0 only)
            └──────────── plain pose copy ─────────────────────┘   (LOD1+, or physics off)
```

- **LOD0 (near):** run the gait on the Target, velocity-drive the Puppet at it. Now the creature
  can be shot, shoved, knocked down, pile up on other creatures — all emergent.
- **LOD1+ (far):** skip the physics entirely, copy Target→visible skeleton (what the creature
  does today). Zero extra cost. **Never physics-sim a whole herd** (STA reference §6.10, and your
  own spec's multiplayer note — this is the same "performance wall" rule).

This is literally STA's own roadmap item #11 ("Procedural creatures… same Target/Puppet +
velocity-drive core; replace clip Target with a generic N-legged gait solver") meeting your
roadmap item #3 ("Active ragdoll / hit reactions: per-limb PhysicalBoneSimulator3D blend-in on
damage, return to gait via pose crossfade"). Same feature from both sides.

---

## 3. Concrete wiring

### 3.1 Build a physical rig on the generated skeleton

Reuse `active_ragdoll.cpp` `_build_rig`'s pattern, but drive it from `CreatureBuilder`'s rig dict
instead of hardcoded Synty names. The builder already returns per-leg `{upper, lower, foot}` bone
indices, `body`, `spine[]`, `tail[]`, plus lengths — everything a capsule needs.

```cpp
// pseudo, in a CreatureRagdoll : Node built after CreatureBuilder.build():
for each spine bone i:      add_phys_bone(idx, r=body_r*belly[i], len=segment_len, CONE, 25°,15°, mass);
for each leg  {up,lo,foot}: add_phys_bone(up,   r=leg_r,  len=upper_len, CONE, 50°,30°, mass);
                            add_phys_bone(lo,   r=leg_r*.8,len=lower_len, CONE, 25°,10°, mass);
add_phys_bone(head, ...);
// tail/antennae: LEAVE to SpringBoneSimulator3D (already good, don't double-drive).
```

Keep the **cm→m `body_offset` scale fix** verbatim (`active_ragdoll.cpp:97–136`) — the creature
mesh forge builds in metres so you may not need it, but the guard is free and saves the classic
"ragdoll explodes at 100× scale" bug if any parent node carries a scale.

Collision: bones on their own layer, mask = World only (never each other, never the capsule) —
`active_ragdoll.cpp:129`. Same rule keeps the rig from self-tangling.

### 3.2 Point the drive at the gait, not at clips

STA's `_pd_step` reads `target_skel->get_bone_global_pose(bone_idx)`. For creatures the Target
skeleton is the one the `GaitController` + `TwoBoneIK3D` already pose. Two ways:

- **Two skeletons:** run the gait/modifier stack on a hidden Target skeleton (exactly STA's
  `AnimTarget`), velocity-drive the visible Puppet. Cleanest; matches STA 1:1.
- **One skeleton, read post-IK:** the gait's IK writes into the skeleton inside the
  `skeleton_updated` signal (spec fact #5). Sample the modified pose there, cache it, drive the
  physical bones toward the cache. Saves a skeleton but you must respect the modifier ordering
  (controllers at `process_physics_priority = -10`, spec fact #7).

Either way `_pd_step` itself is unchanged — it's morphology-blind.

### 3.3 The stumble itself

```gdscript
func hit(bone_idx: int, world_impulse: Vector3, stagger := 0.6) -> void:
    var pb := ragdoll.get_physical_bone(bone_idx)
    PhysicsServer3D.body_apply_impulse(pb.get_rid(), world_impulse)
    # Event-driven authority drop: let physics win for a beat, then ramp back.
    ragdoll.track_rotation = 0.15     # was 1.0
    ragdoll.track_position = 0.4
    _stagger_timer = stagger          # a tween/timer eases track_* back to 1.0
```

- Big impulse + low `track_*` for ~0.3–0.6 s = real stagger, then the drive recovers the gait.
- Death = stop driving entirely (`set_simulating` keeps the sim but zero track, or just stop the
  gait) → passive ragdoll collapse. This is your spec §10.3 "return to gait via pose crossfade,"
  now physically grounded.
- Knockback/explosions/being trampled by the herd: all just impulses on the same bones. Free.

### 3.4 Keep it cheap

- Physical rig **only on LOD0** creatures near the camera. Build it lazily on LOD0 entry, tear it
  down (`physical_bones_stop_simulation`, free the sim) on demotion. Far creatures never allocate
  a body.
- Cap the number of simultaneously-physical creatures (pool them, like STA's swarm plan). A dozen
  active ragdolls is fine; fifteen hundred is the wall.
- Multiplayer: unchanged from both specs — replicate `{seed, root xform, velocity}` + authoritative
  hit/death events. Each client runs its own puppet physics locally (cosmetic, may differ). Never
  sync bone transforms. Both systems already agreed on this; the merge doesn't change it.

---

## 4. What each side contributes

**procgen_creatures gives the merged system:** morphology-independent gait (any leg count),
generated skeleton + skinned mesh, the engine `TwoBoneIK3D`/`LookAt`/`SpringBone` solve, the 4-tier
LOD, the native mesh forge, seeded determinism.

**STA active ragdoll gives the merged system:** the `PhysicalBoneSimulator3D` rig build (+ scale
fix), the **velocity-drive** that makes dynamics chase a target without untunable spring gains, the
snap-distance blow-up guard, the base-velocity feed-forward (so fast-moving creatures don't hit the
snap loop), event-driven authority drops for hit reactions, and the F3 live-tuning menu to dial it.

Result: creatures that walk any body plan for free **and** stumble, get knocked down, and pile up
like the STA player does — with physics paid for only where the camera can see it.

---

## 5. Files to read, in order

1. `ACTIVE_RAGDOLL_ANIMATION.md` §1–2 — the Target/Puppet idea and the velocity-drive research.
2. `src/active_ragdoll.cpp` `_build_rig` (rig + scale fix), `_pd_step` (the drive), `_foot_ik`.
3. `../procgen_creatures/creature/gait_controller.gd` — the Target source for creatures.
4. Back here §3 — the wiring that connects them.
