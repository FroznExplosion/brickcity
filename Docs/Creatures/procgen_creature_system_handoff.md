# Procedural Creature System — Godot 4.6 — Implementation Handoff

**Status:** 2026-07-17 · validated against Godot 4.6-stable headless (smoke test: 0 failures).
Part of the [Procedural Characters master doc](README.md). Verbose implementation handoff for the
**Procedural Gait** (kinematic) system — the concise contract is
[`procgen_creatures_spec.md`](procgen_creatures_spec.md); shared concepts live in
[`_shared/shared_core.md`](_shared/shared_core.md); reference code in
[`procgen_creatures/`](procgen_creatures/).

Complete spec + reference code for a NMS/Spore-style procedural creature system: seeded DNA → generated skeleton + skinned mesh → physics-based procedural walking → 4-tier animation LOD → optional C++ mesh forge.

**Everything in this document was built and validated against Godot 4.6-stable headless.** The smoke test (included, section 7) passed with 0 failures: IK foot accuracy 0.2 mm mean over 1620 samples on uneven terrain, exact GDScript/C++ mesh parity, x2.5 native build speedup. The code blocks are the verbatim tested files — implement them as-is, then iterate.

**Suggested repo layout** (no project.godot included — drop into your existing project; paths inside files use `res://creature/...` only in tests, the library itself is path-independent):

```
creature/
  creature_dna.gd        # seeded genome
  part_mesh_lib.gd       # geometry batch (GDScript + native router)
  creature_builder.gd    # DNA → skeleton, skinned mesh, IK/modifier stack
  gait_controller.gd     # physics-based gait (LOD0/1)
  canned_gait.gd         # cheap sine FK gait (LOD2)
  creature_lod.gd        # LOD manager
  proc_creature.gd       # root node: ProcCreature.spawn(dna)
native/                  # optional C++ MeshForge GDExtension
  SConstruct
  src/mesh_forge.h
  src/mesh_forge.cpp
  src/register_types.cpp
creature_forge.gdextension
tests/smoke_test.gd      # headless CI test
test/main.gd             # visual playground scene script
```

Usage:

```gdscript
var c := ProcCreature.spawn(CreatureDNA.random(seed))
world.add_child(c)
c.global_position = spawn_point   # safe: gait lazy-inits feet on first tick
```

---

## 1. Core design decisions

- **One pipeline, two archetypes.** Organic vs robotic is a *skin-weight policy*, not two mesh systems. Organic: ring vertices near a joint weighted ~50/50 across both bones → smooth blended flesh; leg tubes' first ring blends 55/45 with the spine bone so shoulders weld into the body. Robotic: segments 100% one bone, inset gaps + servo spheres at joints + emissive sensor eye → hard swivel look. Same builder, one flag.
- **Engine solvers, not custom IK.** Godot 4.6's `SkeletonModifier3D` stack does all solving in engine C++: `TwoBoneIK3D` (legs), `LookAtModifier3D` (head), `SpringBoneSimulator3D` (tails/antennae). Stackable, deterministic order.
- **Animation is morphology-independent** (the Spore insight). The gait engine writes world-space IK *targets*, never bone rotations — so 2, 4, or 6 legs of any length walk from the same code.
- **Multiplayer (decided): client-side cosmetic animation.** Replicate `{seed, root transform, velocity}` only. Every client rebuilds the identical creature from the seed and runs its own gait locally. No pose sync.

## 2. Validated Godot 4.6 engine facts (ground truth — probed against the real binary)

1. `TwoBoneIK3D` uses a **per-setting-index API**: set `setting_count`, then `set_root_bone_name(i, ...)`, `set_middle_bone_name(i, ...)`, `set_end_bone_name(i, ...)`, `set_target_node(i, path)`, `set_pole_node(i, path)`. One node drives all legs.
2. `TwoBoneIK3D` **silently no-ops without a pole node**. Always assign one per setting. With a pole, solve error ≈ 0.
3. The modifier stack only runs on frames where the skeleton is **dirtied** (some bone pose written). The gait writing the body bone pose every physics tick handles this for free.
4. Bone rests must be **+Y oriented along the bone** (toward the child). Use a `basis_y_to(dir)` helper when building rests.
5. Post-IK ("modified") poses are readable **inside the `skeleton_updated` signal callback** — sample there for tests/foot-planting queries.
6. `LookAtModifier3D.forward_axis` takes `SkeletonModifier3D.BoneAxis` — `BONE_AXIS_PLUS_Y` for Y-toward-nose head bones.
7. **Ordering bug to avoid:** controllers that write targets/poses must run *before* the skeleton's modifier pass in the same physics frame → set `process_physics_priority = -10` on them. Symptom otherwise: feet trail body bob/pitch by exactly the body-dynamics magnitude (we measured 0.19 m mean error before the fix, 0.0002 m after).
8. **Spawn-order bug to avoid:** never snapshot world-space foot positions in `_ready()` — it fires during `add_child()`, *before* the caller sets `global_position`. Lazy-init planted feet on the first physics tick and expose `teleport_reset()`. (Symptom: first steps sweep from the world origin.)

---

## 3. How the physics-based animation works (+ setup recipe)

### 3.1 The layer stack

```
_physics_process, priority -10:   GaitController (or CannedGait at LOD2)
    writes:  IK target node positions (world), pole node positions,
             body bone pose (bob/pitch/roll)  ← this also dirties the skeleton
_physics_process, priority 0:     Skeleton3D modifier pass (engine, in order):
    TwoBoneIK3D      solves every leg to its target around its pole
    LookAtModifier3D bends the head toward the look target
    SpringBoneSimulator3D  physically lags tail/antenna bones (gravity+stiffness)
skeleton_updated signal:          final poses readable here
```

Physics-based means three concrete things:
1. **Feet are planted in world space** and only move when a step is *triggered by body motion* — locomotion emerges from the body dragging its support polygon, exactly like real legged locomotion, rather than from a looping clip.
2. **Raycasts** place every foothold and the body root on actual collision geometry — slopes, steps, and bumps are handled with zero authored data.
3. **Secondary motion is simulated**: `SpringBoneSimulator3D` runs a per-bone spring sim (Jolt-era, engine-side) for tails/antennae, and body pitch/roll/height are driven by the *measured* planted-foot heights, so the torso reacts to terrain.

### 3.2 Skeleton + modifier setup recipe (do this once per creature, in the builder)

```gdscript
# 1. Skeleton with +Y-along-bone rests, knees PRE-BENT in rest pose
#    (TwoBoneIK bends the middle joint the way the rest pose hints).
#    Pre-bend via analytic two-circle solve: place knee at the intersection
#    of spheres (hip, upper_len) and (foot, lower_len), pushed forward (-Z).
skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS

# 2. One TwoBoneIK3D child, one setting per leg:
var ik := TwoBoneIK3D.new()
skeleton.add_child(ik)
ik.setting_count = legs.size()
for i in legs.size():
    ik.set_root_bone_name(i, legs[i].upper_name)
    ik.set_middle_bone_name(i, legs[i].lower_name)
    ik.set_end_bone_name(i, legs[i].foot_name)
    ik.set_target_node(i, legs[i].target.get_path())  # Node3D, child of creature root
    ik.set_pole_node(i, legs[i].pole.get_path())      # REQUIRED (fact #2) — knee aim
# Pole placement: in front of the knee, creature-local:
#   pole_local = hip_local + Vector3(0, -reach*0.3, -reach*0.9)

# 3. Head look:
var look := LookAtModifier3D.new()
skeleton.add_child(look)
look.bone_name = "head"
look.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_Y
look.target_node = look_target.get_path()
look.influence = 0.7
# + angle limits (use_angle_limitation etc.) to stop owl necks

# 4. Tail/antennae springs:
var spring := SpringBoneSimulator3D.new()
skeleton.add_child(spring)
spring.setting_count = 1
spring.set_root_bone_name(0, "tail_0")
spring.set_end_bone_name(0, "tail_%d" % (tail_joints - 1))
```

### 3.3 The gait algorithm (per physics tick, priority -10)

Per-leg **stepper state machine** — each foot is either PLANTED (a fixed world point) or SWINGING (interpolating to a new foothold):

```
for each leg:
    home    = creature_xform * leg.home_local          # neutral foot pos under hip
    ground  = raycast_down(home + up*stand_h, 3*stand_h).position
    if PLANTED:
        overstretch = planted.distance_to(ground)
        may_step = other_phase_group_fully_planted OR overstretch > trigger*1.9
        if overstretch > trigger AND may_step:  begin swing
        target.global_position = planted                # hold world point
    if SWINGING (t: 0→1 over step_time):
        p = from.lerp(to, smoothstep(t)) ; p.y += sin(PI*t) * step_height
        target.global_position = p
    pole.global_position = creature_xform * leg.pole_local
```

Key constants (DNA-scaled): `trigger = stand_h * step_trigger_f` (~0.3–0.45), `step_height = stand_h * step_height_f`, landing target leads by `velocity * step_time * 0.7`. Phase group = `(pair_index + side) % 2` — the "only step when the other group is planted" rule makes diagonal/trot gaits **emerge** with zero choreography, for any leg count. The 1.9x emergency override guarantees a foot can never be left behind (e.g. after knockback).

**Body dynamics from the feet** (this is what sells it): average planted-foot height → body height offset; front-vs-back foot heights → pitch (`atan2(Δh, body_len)`); left-vs-right → roll; all exponentially smoothed (`lerp` with `1-pow(k, dt)`), plus a stride-frequency bob written to the body bone pose. Root Y terrain-follows its own downward ray.

### 3.4 LOD degradation

| Tier | Distance | Running |
|---|---|---|
| 0 | <25 m | gait 60 Hz + IK + springs + look |
| 1 | <60 m | same gait at ~15 Hz (`tick_divisor=4`), IK on, springs/look off |
| 2 | <120 m | `CannedGait`: sine FK thigh/knee + bob at ~10 Hz, **all modifiers off** |
| 3 | beyond | frozen pose, zero cost |

4 Hz distance poll, ±12% hysteresis, `force_now(tier)` applies immediately (don't wait for the poll — matters in tests). The canned gait captures each leg's rest rotations at setup and writes `Quaternion(axis, sin(...)) * rest` directly to bone poses — version-safe, no custom modifier subclassing.

---

## 4. GDScript implementation (verbatim tested files)

#### `creature/creature_dna.gd`

```gdscript
class_name CreatureDNA
extends RefCounted
## Seeded "genome" describing a creature body plan.
## Pure data — no scene nodes. Deterministic from `seed`.

enum Archetype { ORGANIC, ROBOTIC }

var seed_value: int = 0
var archetype: int = Archetype.ORGANIC
var creature_name: String = "Unnamed"

# --- Body plan -------------------------------------------------------------
var scale: float = 1.0
var spine_joints: int = 4            # number of spine bones/joints (>= 2)
var body_len: float = 1.4            # rear spine joint -> front spine joint
var body_r: float = 0.3              # base body radius
var belly: PackedFloat32Array = []   # per-spine-joint radius multiplier

var leg_pairs: Array[Dictionary] = []  # { spine_i, upper, lower, hip_out, splay, knee_forward }

var neck_len: float = 0.3
var head_r: float = 0.22
var snout_len: float = 0.3
var head_up: float = 0.12

var tail_joints: int = 3             # 0 disables tail. Robots grow an antenna instead.
var tail_seg: float = 0.25

var color: Color = Color(0.5, 0.6, 0.4)
var accent: Color = Color(0.95, 0.9, 0.2)

# --- Gait ------------------------------------------------------------------
var move_speed: float = 1.6
var step_time: float = 0.22
var step_height_f: float = 0.30      # fraction of stand height
var step_trigger_f: float = 0.38     # fraction of stand height
var bob_amp: float = 0.03

const _SYL_A := ["Vro", "Ka", "Zu", "Mor", "Tik", "Gla", "Ur", "Ske", "Bo", "Ny"]
const _SYL_B := ["k", "rr", "th", "z", "l", "m", "x", "g"]
const _SYL_C := ["tar", "ok", "una", "eth", "ilo", "ash", "orn", "ub", "ee", "ax"]

func stand_height() -> float:
	var reach := 0.0
	for lp in leg_pairs:
		reach = maxf(reach, float(lp.upper) + float(lp.lower))
	return reach * 0.82

func front_spine_z() -> float: return -body_len * 0.5
func rear_spine_z() -> float: return body_len * 0.5

static func random(p_seed: int) -> CreatureDNA:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var d := CreatureDNA.new()
	d.seed_value = p_seed
	d.archetype = Archetype.ROBOTIC if rng.randf() < 0.4 else Archetype.ORGANIC
	d.creature_name = _SYL_A[rng.randi() % _SYL_A.size()] \
		+ _SYL_B[rng.randi() % _SYL_B.size()] \
		+ _SYL_C[rng.randi() % _SYL_C.size()]

	d.scale = rng.randf_range(0.7, 1.6)
	d.spine_joints = rng.randi_range(3, 5)
	d.body_len = rng.randf_range(0.9, 2.0) * d.scale
	d.body_r = rng.randf_range(0.18, 0.4) * d.scale
	d.belly = PackedFloat32Array()
	for i in d.spine_joints:
		var t := float(i) / maxf(1.0, d.spine_joints - 1.0)
		# widest slightly behind center, taper at both ends
		var bulge := 1.0 + 0.45 * sin(PI * clampf(t * 1.1, 0.0, 1.0)) * rng.randf_range(0.6, 1.2)
		d.belly.append(bulge)

	var pairs := rng.randi_range(1, 3)
	var upper := rng.randf_range(0.35, 0.7) * d.scale
	var lower := upper * rng.randf_range(0.8, 1.2)
	for p in pairs:
		# spread pairs along spine; single pair sits mid-rear
		var si: int
		if pairs == 1:
			si = d.spine_joints / 2
		else:
			si = int(round(lerpf(d.spine_joints - 1, 0, float(p) / float(pairs - 1))))
		d.leg_pairs.append({
			"spine_i": si,
			"upper": upper * rng.randf_range(0.92, 1.08),
			"lower": lower * rng.randf_range(0.92, 1.08),
			"hip_out": d.body_r * rng.randf_range(0.75, 1.05),
			"splay": rng.randf_range(1.15, 1.6),
			"knee_forward": rng.randf() < 0.65,
		})

	d.neck_len = rng.randf_range(0.12, 0.55) * d.scale
	d.head_r = d.body_r * rng.randf_range(0.55, 0.95)
	d.snout_len = rng.randf_range(0.15, 0.6) * d.scale
	d.head_up = rng.randf_range(0.0, 0.3) * d.scale

	d.tail_joints = rng.randi_range(0, 4)
	d.tail_seg = rng.randf_range(0.18, 0.35) * d.scale
	if d.archetype == Archetype.ROBOTIC:
		d.tail_joints = rng.randi_range(2, 4)  # antenna
		d.tail_seg = rng.randf_range(0.12, 0.2) * d.scale

	d.color = Color.from_hsv(rng.randf(), rng.randf_range(0.35, 0.8), rng.randf_range(0.45, 0.9))
	if d.archetype == Archetype.ROBOTIC:
		d.color = Color.from_hsv(rng.randf(), rng.randf_range(0.05, 0.3), rng.randf_range(0.5, 0.85))
	d.accent = Color.from_hsv(fmod(d.color.h + 0.5, 1.0), 0.9, 1.0)

	var sh := d.stand_height()
	d.move_speed = rng.randf_range(0.9, 2.2) * sqrt(maxf(sh, 0.2))
	d.step_time = rng.randf_range(0.16, 0.3)
	d.bob_amp = sh * rng.randf_range(0.02, 0.05)
	return d
```

#### `creature/part_mesh_lib.gd`

```gdscript
class_name PartMeshLib
extends RefCounted
## Geometry batch that emits skinned primitives into a SurfaceTool surface.
## The core idea: organic vs robotic is a SKIN-WEIGHT POLICY, not a different
## mesh system. Blended ring weights across a joint => smooth organic flesh.
## Hard 100%-one-bone segments with inset gaps + servo balls => machine.

## One ring "station" along a limb/body polyline.
class Station:
	var pos: Vector3
	var basis: Basis          # y = tube direction
	var radius: float
	var rx: float = 1.0       # lateral ellipse factor
	var bones: PackedInt32Array
	var weights: PackedFloat32Array
	var v: float = 0.0        # uv v

	static func make(p: Vector3, b: Basis, r: float, bn: PackedInt32Array, w: PackedFloat32Array, pv: float, prx := 1.0) -> Station:
		var s := Station.new()
		s.pos = p; s.basis = b; s.radius = r; s.bones = bn; s.weights = w; s.v = pv; s.rx = prx
		return s

## Backend selection: "auto" uses the native MeshForge GDExtension when the
## library is loaded and falls back to SurfaceTool otherwise. "gd"/"native"
## pin a path (tests, benchmarks).
static var backend := "auto"

static func native_available() -> bool:
	return ClassDB.class_exists(&"MeshForge") and ClassDB.can_instantiate(&"MeshForge")

var st: SurfaceTool
var smooth: bool
var _vcount: int = 0
var _n: Object = null   # native MeshForge, when in use

func _init(p_smooth: bool) -> void:
	smooth = p_smooth
	var use_native: bool = backend != "gd" and native_available()
	if backend == "native" and not native_available():
		push_warning("PartMeshLib: native backend requested but MeshForge missing; using GDScript")
	if use_native:
		_n = ClassDB.instantiate(&"MeshForge")
		_n.begin(smooth)
	else:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

static func _station_dict(s: Station) -> Dictionary:
	return {"pos": s.pos, "basis": s.basis, "radius": s.radius, "rx": s.rx,
		"v": s.v, "bones": s.bones, "weights": s.weights}

static func bw(b0: int, w0: float, b1: int = 0, w1: float = 0.0) -> Array:
	return [PackedInt32Array([b0, b1, 0, 0]), PackedFloat32Array([w0, w1, 0.0, 0.0])]

## Basis with local +Y aligned to dir.
static func basis_y_to(dir: Vector3) -> Basis:
	var y := dir.normalized()
	if y.length_squared() < 0.0001:
		y = Vector3.UP
	var hint := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.98 else Vector3.FORWARD
	var z := hint.cross(y).normalized()
	var x := y.cross(z).normalized()
	return Basis(x, y, z)

func _emit(pos: Vector3, normal: Vector3, uv: Vector2, bones: PackedInt32Array, weights: PackedFloat32Array) -> int:
	st.set_smooth_group(0 if smooth else _vcount)  # unique group per vertex = flat after generate_normals
	st.set_normal(normal)
	st.set_uv(uv)
	st.set_bones(bones)
	st.set_weights(weights)
	st.add_vertex(pos)
	var i := _vcount
	_vcount += 1
	return i

func _ring(s: Station, n: int) -> int:
	var base := _vcount
	for k in n + 1:  # +1 duplicated seam vertex for clean UVs
		var a := TAU * float(k % n) / float(n)
		var off := s.basis.x * (cos(a) * s.radius * s.rx) + s.basis.z * (sin(a) * s.radius)
		_emit(s.pos + off, off.normalized(), Vector2(float(k) / float(n), s.v), s.bones, s.weights)
	return base

## Continuous smooth tube through stations (organic). Caps both ends.
func add_tube(stations: Array, ring_n: int = 8, cap_start := true, cap_end := true) -> void:
	if stations.size() < 2:
		return
	if _n:
		var arr: Array = []
		for s: Station in stations:
			arr.append(_station_dict(s))
		_n.add_tube(arr, ring_n, cap_start, cap_end)
		return
	var bases: Array[int] = []
	for s: Station in stations:
		bases.append(_ring(s, ring_n))
	for i in stations.size() - 1:
		var b0: int = bases[i]
		var b1: int = bases[i + 1]
		for k in ring_n:
			st.add_index(b0 + k); st.add_index(b1 + k); st.add_index(b0 + k + 1)
			st.add_index(b0 + k + 1); st.add_index(b1 + k); st.add_index(b1 + k + 1)
	if cap_start:
		var s0: Station = stations[0]
		_cap(bases[0], ring_n, s0.pos - s0.basis.y * s0.radius * 0.6, s0, true)
	if cap_end:
		var se: Station = stations[stations.size() - 1]
		_cap(bases[stations.size() - 1], ring_n, se.pos + se.basis.y * se.radius * 0.6, se, false)

func _cap(ring_base: int, ring_n: int, tip: Vector3, s: Station, flip: bool) -> void:
	var nrm := (-s.basis.y) if flip else s.basis.y
	var tip_i := _emit(tip, nrm, Vector2(0.5, s.v), s.bones, s.weights)
	for k in ring_n:
		if flip:
			st.add_index(ring_base + k + 1); st.add_index(tip_i); st.add_index(ring_base + k)
		else:
			st.add_index(ring_base + k); st.add_index(tip_i); st.add_index(ring_base + k + 1)

## Rigid machine tube: each segment hard-bound to one bone, inset gaps at joints.
func add_rigid_segment(p0: Vector3, p1: Vector3, r0: float, r1: float, bone: int, ring_n: int = 6, inset: float = 0.03) -> void:
	if _n:
		_n.add_rigid_segment(p0, p1, r0, r1, bone, ring_n, inset)
		return
	var dir := (p1 - p0).normalized()
	var b := basis_y_to(dir)
	var q0 := p0 + dir * inset
	var q1 := p1 - dir * inset
	var pair0 := bw(bone, 1.0)
	var s0 := Station.make(q0, b, r0, pair0[0], pair0[1], 0.0)
	var s1 := Station.make(q1, b, r1, pair0[0], pair0[1], 1.0)
	add_tube([s0, s1], ring_n, true, true)

## Lat/long sphere bound to (up to two) bones. Smooth-friendly.
func add_sphere(center: Vector3, r: float, bones: PackedInt32Array, weights: PackedFloat32Array, lat: int = 6, lon: int = 8, squash := Vector3.ONE) -> void:
	if _n:
		_n.add_sphere(center, r, bones, weights, lat, lon, squash)
		return
	var rows: Array[int] = []
	for i in lat + 1:
		var phi := PI * float(i) / float(lat)
		var y := cos(phi) * r * squash.y
		var rr := sin(phi) * r
		var base := _vcount
		for k in lon + 1:
			var a := TAU * float(k % lon) / float(lon)
			var off := Vector3(cos(a) * rr * squash.x, y, sin(a) * rr * squash.z)
			_emit(center + off, off.normalized() if off.length() > 0.001 else Vector3.UP,
				Vector2(float(k) / float(lon), float(i) / float(lat)), bones, weights)
		rows.append(base)
	for i in lat:
		var b0: int = rows[i]
		var b1: int = rows[i + 1]
		for k in lon:
			st.add_index(b0 + k); st.add_index(b0 + k + 1); st.add_index(b1 + k)
			st.add_index(b0 + k + 1); st.add_index(b1 + k + 1); st.add_index(b1 + k)

## Commit this batch as a new surface on `mesh`.
func commit(mesh: ArrayMesh, material: Material) -> void:
	if _n:
		if _n.get_vertex_count() > 0:
			_n.commit(mesh, material)
		return
	if _vcount == 0:
		return
	st.generate_normals()
	st.set_material(material)
	st.commit(mesh)

## Weight blend across a polyline of joints. joint_bones[i] owns segment i -> i+1.
## f in [0,1] along segment seg_i. Returns [bones, weights].
static func polyline_weights(seg_i: int, f: float, joint_bones: PackedInt32Array, organic: bool, blend_zone := 0.45) -> Array:
	var nseg := joint_bones.size() - 1
	var bone: int = joint_bones[mini(seg_i, joint_bones.size() - 1)]
	if not organic:
		return bw(bone, 1.0)
	if f < blend_zone and seg_i > 0:
		var t := 0.5 + 0.5 * smoothstep(0.0, 1.0, f / blend_zone)
		return bw(bone, t, joint_bones[seg_i - 1], 1.0 - t)
	if f > 1.0 - blend_zone and seg_i < nseg - 1:
		var t2 := 0.5 + 0.5 * smoothstep(0.0, 1.0, (1.0 - f) / blend_zone)
		return bw(bone, t2, joint_bones[seg_i + 1], 1.0 - t2)
	return bw(bone, 1.0)
```

#### `creature/creature_builder.gd`

```gdscript
class_name CreatureBuilder
extends RefCounted
## Turns a CreatureDNA into a live rig:
##   Skeleton3D (Y-along-bone oriented rests — REQUIRED by 4.6 IK solvers)
##   + single skinned ArrayMesh (organic weight-blend OR rigid robot binding)
##   + TwoBoneIK3D (one node, one setting per leg; poles are REQUIRED)
##   + LookAtModifier3D head tracking + SpringBoneSimulator3D tail/antenna.
## Creature model space: +Y up, forward = -Z, feet on y=0 plane.

const FWD := Vector3(0, 0, -1)

## Builds everything under `root`. Returns a rig description dictionary.
static func build(dna: CreatureDNA, root: Node3D) -> Dictionary:
	var organic := dna.archetype == CreatureDNA.Archetype.ORGANIC
	var stand_h := dna.stand_height()

	# ------------------------------------------------------------------ joints
	var spine_j: Array[Vector3] = []
	for i in dna.spine_joints:
		var t := float(i) / float(dna.spine_joints - 1)
		var z := lerpf(dna.rear_spine_z(), dna.front_spine_z(), t)
		spine_j.append(Vector3(0, stand_h, z))
	var neck_j := spine_j[-1] + Vector3(0, dna.head_up * 0.6, -dna.neck_len * 0.55)
	var head_j := spine_j[-1] + Vector3(0, dna.head_up, -dna.neck_len)
	var nose_j := head_j + Vector3(0, -dna.head_r * 0.15, -(dna.head_r + dna.snout_len))
	var tail_j: Array[Vector3] = []
	for k in dna.tail_joints:
		var up_curve := (0.4 if organic else 1.2) * dna.tail_seg * float(k + 1) * 0.5
		tail_j.append(spine_j[0] + Vector3(0, up_curve, dna.tail_seg * float(k + 1)))

	# ---------------------------------------------------------------- skeleton
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	root.add_child(skel)

	var g_rest: Array[Transform3D] = []   # global rest per bone index
	var add_bone := func(bname: String, parent: int, g_xf: Transform3D) -> int:
		var idx := skel.get_bone_count()
		skel.add_bone(bname)
		if parent >= 0:
			skel.set_bone_parent(idx, parent)
			skel.set_bone_rest(idx, g_rest[parent].affine_inverse() * g_xf)
		else:
			skel.set_bone_rest(idx, g_xf)
		g_rest.append(g_xf)
		return idx

	var body_i: int = add_bone.call("body", -1, Transform3D(Basis(), Vector3(0, stand_h, 0)))

	var spine_i: Array[int] = []
	for i in dna.spine_joints:
		var aim: Vector3 = (spine_j[i + 1] - spine_j[i]) if i < dna.spine_joints - 1 else (head_j - spine_j[i])
		var parent: int = body_i if i == 0 else spine_i[i - 1]
		spine_i.append(add_bone.call("spine_%d" % i, parent, Transform3D(PartMeshLib.basis_y_to(aim), spine_j[i])))
	var head_i: int = add_bone.call("head", spine_i[-1], Transform3D(PartMeshLib.basis_y_to(nose_j - head_j), head_j))

	var tail_i: Array[int] = []
	for k in dna.tail_joints:
		var o: Vector3 = spine_j[0] if k == 0 else tail_j[k - 1]
		var parent: int = spine_i[0] if k == 0 else tail_i[k - 1]
		tail_i.append(add_bone.call("tail_%d" % k, parent, Transform3D(PartMeshLib.basis_y_to(tail_j[k] - o), o)))

	# Legs: analytic pre-bent rest so solvers inherit a sane bend plane.
	var legs: Array[Dictionary] = []
	for p in dna.leg_pairs.size():
		var lp: Dictionary = dna.leg_pairs[p]
		var sj: Vector3 = spine_j[lp.spine_i]
		for side in [-1.0, 1.0]:
			var hip := Vector3(side * lp.hip_out, sj.y - dna.body_r * 0.25, sj.z)
			var lat: float = lp.hip_out * (lp.splay - 1.0)
			var reach: float = lp.upper + lp.lower
			var d_max := reach * 0.96
			if sqrt(hip.y * hip.y + lat * lat) > d_max:
				lat = sqrt(maxf(0.0, d_max * d_max - hip.y * hip.y))
			var foot := Vector3(hip.x + side * lat, 0.0, hip.z)
			var bend: Vector3 = FWD if lp.knee_forward else -FWD
			var knee := _solve_knee(hip, foot, lp.upper, lp.lower, bend)
			var g_hip := Transform3D(PartMeshLib.basis_y_to(knee - hip), hip)
			var g_knee := Transform3D(PartMeshLib.basis_y_to(foot - knee), knee)
			var g_foot := Transform3D(g_knee.basis, foot)
			var sfx := "%d_%s" % [p, "l" if side < 0 else "r"]
			var ui: int = add_bone.call("upper_" + sfx, spine_i[lp.spine_i], g_hip)
			var li: int = add_bone.call("lower_" + sfx, ui, g_knee)
			var fi: int = add_bone.call("foot_" + sfx, li, g_foot)
			legs.append({
				"upper": ui, "lower": li, "foot": fi,
				"upper_name": "upper_" + sfx, "lower_name": "lower_" + sfx, "foot_name": "foot_" + sfx,
				"side": side, "pair": p,
				"hip_local": hip, "knee_local": knee, "foot_local": foot,
				"home_local": foot,
				"pole_local": hip.lerp(foot, 0.5) + bend * (reach * 0.9),
				"group": (p + (0 if side < 0 else 1)) % 2,
				"reach": reach,
			})
	skel.reset_bone_poses()
	skel.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS

	# -------------------------------------------------------------------- mesh
	var mesh := ArrayMesh.new()
	if organic:
		_mesh_organic(dna, mesh, spine_j, neck_j, head_j, nose_j, tail_j, spine_i, head_i, tail_i, legs, dna.body_r)
	else:
		_mesh_robot(dna, mesh, spine_j, neck_j, head_j, nose_j, tail_j, spine_i, head_i, tail_i, legs)

	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = mesh
	skel.add_child(mi)
	mi.skeleton = NodePath("..")
	mi.skin = skel.create_skin_from_rest_transforms()

	# ------------------------------------------------------ targets & modifiers
	var targets := Node3D.new()
	targets.name = "Targets"
	root.add_child(targets)

	var ik := TwoBoneIK3D.new()
	ik.name = "LegIK"
	skel.add_child(ik)
	ik.setting_count = legs.size()
	for i in legs.size():
		var leg: Dictionary = legs[i]
		var tgt := Node3D.new(); tgt.name = "FootTarget_%d" % i
		targets.add_child(tgt); tgt.position = leg.foot_local
		var pole := Node3D.new(); pole.name = "Pole_%d" % i
		targets.add_child(pole); pole.position = leg.pole_local
		leg["target"] = tgt
		leg["pole"] = pole
		ik.set_root_bone_name(i, leg.upper_name)
		ik.set_middle_bone_name(i, leg.lower_name)
		ik.set_end_bone_name(i, leg.foot_name)
		ik.set_target_node(i, ik.get_path_to(tgt))
		ik.set_pole_node(i, ik.get_path_to(pole))

	var look_target := Node3D.new()
	look_target.name = "LookTarget"
	targets.add_child(look_target)
	look_target.position = head_j + FWD * 3.0
	var look := LookAtModifier3D.new()
	look.name = "HeadLook"
	skel.add_child(look)
	look.bone_name = "head"
	look.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_Y
	look.target_node = look.get_path_to(look_target)
	look.use_angle_limitation = true
	look.symmetry_limitation = true
	look.primary_limit_angle = deg_to_rad(70.0)
	look.duration = 0.25
	look.influence = 0.7

	var spring: SpringBoneSimulator3D = null
	if dna.tail_joints >= 2:
		spring = SpringBoneSimulator3D.new()
		spring.name = "TailSpring"
		skel.add_child(spring)
		spring.setting_count = 1
		spring.set_root_bone_name(0, "tail_0")
		spring.set_end_bone_name(0, "tail_%d" % (dna.tail_joints - 1))
		spring.set_extend_end_bone(0, true)
		spring.set_end_bone_length(0, dna.tail_seg)

	return {
		"skeleton": skel, "mesh_instance": mi, "targets": targets,
		"ik": ik, "look": look, "spring": spring, "look_target": look_target,
		"legs": legs, "body": body_i, "head": head_i,
		"spine": spine_i, "tail": tail_i,
		"stand_h": stand_h, "head_local": head_j,
		"body_rest_pos": Vector3(0, stand_h, 0),
	}

static func _solve_knee(hip: Vector3, foot: Vector3, u: float, l: float, bend: Vector3) -> Vector3:
	var d := foot - hip
	var dl := clampf(d.length(), 0.01, (u + l) * 0.999)
	var dirn := d / d.length()
	var a := (u * u - l * l + dl * dl) / (2.0 * dl)
	var h := sqrt(maxf(0.0, u * u - a * a))
	var perp := (bend - dirn * bend.dot(dirn))
	perp = perp.normalized() if perp.length() > 0.001 else Vector3(0, 0, -1)
	return hip + dirn * a + perp * h

# --------------------------------------------------------------------- ORGANIC
static func _mesh_organic(dna: CreatureDNA, mesh: ArrayMesh, spine_j: Array[Vector3], neck_j: Vector3, head_j: Vector3, nose_j: Vector3, tail_j: Array[Vector3], spine_i: Array[int], head_i: int, tail_i: Array[int], legs: Array[Dictionary], body_r: float) -> void:
	var mb := PartMeshLib.new(true)

	# Central polyline: tail tip -> spine (rear->front) -> neck -> head -> nose.
	var pts: Array[Vector3] = []
	var own := PackedInt32Array()
	var radii := PackedFloat32Array()
	for k in range(dna.tail_joints - 1, -1, -1):
		pts.append(tail_j[k]); own.append(tail_i[k])
		radii.append(lerpf(0.04, body_r * 0.5, 1.0 - float(k) / maxf(1.0, dna.tail_joints)))
	for i in dna.spine_joints:
		pts.append(spine_j[i]); own.append(spine_i[i])
		radii.append(body_r * dna.belly[i])
	pts.append(neck_j); own.append(spine_i[-1])
	radii.append(minf(body_r * dna.belly[-1], dna.head_r) * 0.6)
	pts.append(head_j); own.append(head_i)
	radii.append(dna.head_r)
	pts.append(nose_j); own.append(head_i)
	radii.append(maxf(0.03, dna.head_r * 0.18))
	mb.add_tube(_stations(pts, own, radii, true, 1.25), 10)

	# Legs — first ring blends into the spine bone: the "shoulder weld".
	for leg in legs:
		var lr: float = clampf(body_r * 0.42, 0.05, 0.2 * dna.scale + 0.06)
		var toe: Vector3 = leg.foot_local + FWD * (lr * 2.2)
		var lpts: Array[Vector3] = [leg.hip_local, leg.knee_local, leg.foot_local, toe]
		var lown := PackedInt32Array([leg.upper, leg.lower, leg.foot, leg.foot])
		var lradii := PackedFloat32Array([lr, lr * 0.7, lr * 0.62, 0.03])
		var stns: Array = _stations(lpts, lown, lradii, true, 1.0)
		var s0: PartMeshLib.Station = stns[0]
		var w := PartMeshLib.bw(leg.upper, 0.55, spine_i[dna.leg_pairs[leg.pair].spine_i], 0.45)
		s0.bones = w[0]; s0.weights = w[1]
		mb.add_tube(stns, 8)

	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = dna.color
	skin_mat.roughness = 0.85
	mb.commit(mesh, skin_mat)

	# Accent surface: eyes.
	var ab := PartMeshLib.new(true)
	var wh := PartMeshLib.bw(head_i, 1.0)
	for side in [-1.0, 1.0]:
		var e := head_j + FWD * (dna.head_r * 0.55) + Vector3(side * dna.head_r * 0.55, dna.head_r * 0.35, 0)
		ab.add_sphere(e, dna.head_r * 0.22, wh[0], wh[1])
	var eye_mat := StandardMaterial3D.new()
	eye_mat.albedo_color = Color(0.08, 0.08, 0.08)
	eye_mat.emission_enabled = true
	eye_mat.emission = dna.accent
	eye_mat.emission_energy_multiplier = 0.6
	ab.commit(mesh, eye_mat)

# --------------------------------------------------------------------- ROBOTIC
static func _mesh_robot(dna: CreatureDNA, mesh: ArrayMesh, spine_j: Array[Vector3], neck_j: Vector3, head_j: Vector3, nose_j: Vector3, tail_j: Array[Vector3], spine_i: Array[int], head_i: int, tail_i: Array[int], legs: Array[Dictionary]) -> void:
	var mb := PartMeshLib.new(false)  # flat shaded hull
	var br := dna.body_r
	for i in dna.spine_joints - 1:
		mb.add_rigid_segment(spine_j[i], spine_j[i + 1], br * dna.belly[i], br * dna.belly[i + 1], spine_i[i], 8, 0.015)
	mb.add_rigid_segment(spine_j[-1], head_j, br * 0.4, br * 0.35, spine_i[-1], 6, 0.01)     # neck strut
	mb.add_rigid_segment(head_j + Vector3(0, 0, dna.head_r * 0.4), nose_j, dna.head_r, dna.head_r * 0.5, head_i, 4, 0.0)  # boxy head
	for k in dna.tail_joints:  # antenna struts
		var o: Vector3 = spine_j[0] if k == 0 else tail_j[k - 1]
		mb.add_rigid_segment(o, tail_j[k], 0.03 * dna.scale, 0.02 * dna.scale, tail_i[k], 4, 0.0)
	for leg in legs:
		var lr: float = clampf(br * 0.3, 0.04, 0.14 * dna.scale + 0.04)
		mb.add_rigid_segment(leg.hip_local, leg.knee_local, lr, lr * 0.8, leg.upper, 6, 0.02)
		mb.add_rigid_segment(leg.knee_local, leg.foot_local, lr * 0.75, lr * 0.6, leg.lower, 6, 0.02)
		mb.add_rigid_segment(leg.foot_local + Vector3(0, 0.02, lr), leg.foot_local + Vector3(0, 0.02, 0) + FWD * lr * 2.0, lr * 0.9, lr * 0.9, leg.foot, 4, 0.0)
	var hull := StandardMaterial3D.new()
	hull.albedo_color = dna.color
	hull.metallic = 0.85
	hull.roughness = 0.4
	mb.commit(mesh, hull)

	# Accent: servo balls at every joint + sensor eye + antenna tip.
	var ab := PartMeshLib.new(true)
	for leg in legs:
		var lr2: float = clampf(br * 0.3, 0.04, 0.14 * dna.scale + 0.04)
		var wu := PartMeshLib.bw(leg.upper, 1.0)
		var wl := PartMeshLib.bw(leg.lower, 1.0)
		ab.add_sphere(leg.hip_local, lr2 * 1.15, wu[0], wu[1], 5, 7)
		ab.add_sphere(leg.knee_local, lr2 * 0.95, wl[0], wl[1], 5, 7)
	var whd := PartMeshLib.bw(head_i, 1.0)
	ab.add_sphere(head_j + FWD * (dna.head_r * 0.9), dna.head_r * 0.3, whd[0], whd[1], 5, 8)
	if dna.tail_joints > 0:
		var wt := PartMeshLib.bw(tail_i[-1], 1.0)
		ab.add_sphere(tail_j[-1], 0.05 * dna.scale, wt[0], wt[1], 4, 6)
	var servo := StandardMaterial3D.new()
	servo.albedo_color = Color(0.15, 0.15, 0.17)
	servo.metallic = 0.6
	servo.roughness = 0.3
	servo.emission_enabled = true
	servo.emission = dna.accent
	servo.emission_energy_multiplier = 1.2
	ab.commit(mesh, servo)

# Subdivide a polyline into ring stations with blended weights + tapered radii.
static func _stations(pts: Array[Vector3], own: PackedInt32Array, radii: PackedFloat32Array, organic: bool, rx: float) -> Array:
	var out: Array = []
	var nseg := pts.size() - 1
	var v := 0.0
	for i in nseg:
		var dir_here: Vector3
		if i == 0:
			dir_here = pts[1] - pts[0]
		else:
			dir_here = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
		for f in [0.0, 0.5]:
			var b := PartMeshLib.basis_y_to(dir_here if f == 0.0 else pts[i + 1] - pts[i])
			var w := PartMeshLib.polyline_weights(i, f, own, organic)
			var r := lerpf(radii[i], radii[i + 1], smoothstep(0.0, 1.0, f))
			out.append(PartMeshLib.Station.make(pts[i].lerp(pts[i + 1], f), b, r, w[0], w[1], v, rx))
			v += 0.5
	var wl := PartMeshLib.polyline_weights(nseg - 1, 1.0, own, organic)
	out.append(PartMeshLib.Station.make(pts[nseg], PartMeshLib.basis_y_to(pts[nseg] - pts[nseg - 1]), radii[nseg], wl[0], wl[1], v, rx))
	return out
```

#### `creature/gait_controller.gd`

```gdscript
class_name GaitController
extends Node
## Physics-based procedural locomotion (LOD0/LOD1).
## Per-leg steppers keep feet planted in WORLD space while the body moves;
## a step triggers when a foot is overstretched and its phase group is free.
## Raycasts place feet on real geometry; body height/pitch/roll are derived
## from the planted feet. Writing the body bone pose every physics tick also
## dirties the skeleton, which is what makes the 4.6 modifier stack run.

var creature: Node3D
var rig: Dictionary
var dna: CreatureDNA

var tick_divisor: int = 1         # LOD1 runs the stepper at a reduced rate
var wander: bool = true
var move_dir := Vector3(0, 0, -1) # creature-local forward is -Z

var _steppers: Array[Dictionary] = []
var _tick := 0
var _time := 0.0
var _heading := 0.0
var _body_y_off := 0.0
var _pitch := 0.0
var _roll := 0.0
var _stepping_in_group := [0, 0]
var _needs_replant := false
var _rng := RandomNumberGenerator.new()

var steps_taken := 0              # telemetry for tests
var path_len := 0.0

func setup(p_creature: Node3D, p_rig: Dictionary, p_dna: CreatureDNA) -> void:
	creature = p_creature
	rig = p_rig
	dna = p_dna
	_rng.seed = dna.seed_value ^ 0xBEEF
	_heading = creature.rotation.y
	# Write targets/poses BEFORE the skeleton's modifier pass runs this frame.
	process_physics_priority = -10
	for leg in rig.legs:
		_steppers.append({
			"leg": leg,
			"planted": Vector3.ZERO,
			"swing_t": -1.0,   # <0 means planted
			"from": Vector3.ZERO, "to": Vector3.ZERO,
		})
	_needs_replant = true  # snap feet on first tick — robust to positioning after add_child
	set_physics_process(true)

## Call after teleporting the creature to snap feet under it instantly.
func teleport_reset() -> void:
	_needs_replant = true

func _physics_process(delta: float) -> void:
	if rig.is_empty():
		return
	_tick += 1
	if _tick % tick_divisor != 0:
		return
	var dt := delta * float(tick_divisor)
	_time += dt

	if _needs_replant:
		_needs_replant = false
		_heading = creature.rotation.y
		for s in _steppers:
			s.planted = creature.global_transform * (s.leg as Dictionary).foot_local
			s.swing_t = -1.0
		_stepping_in_group = [0, 0]

	# ---- locomotion / wander --------------------------------------------
	if wander:
		_heading += (sin(_time * 0.37 + float(dna.seed_value % 7)) * 0.8 + _rng.randf_range(-0.2, 0.2)) * dt
		creature.rotation.y = _heading
	var fwd := -creature.global_transform.basis.z
	var vel := fwd * dna.move_speed
	creature.global_position += vel * dt
	path_len += vel.length() * dt

	# root follows terrain under the body center
	var space := creature.get_world_3d().direct_space_state
	var hit := _ray(space, creature.global_position + Vector3.UP * (rig.stand_h * 2.0 + 1.0), rig.stand_h * 4.0 + 2.0)
	if hit:
		creature.global_position.y = lerpf(creature.global_position.y, hit.position.y, 1.0 - pow(0.001, dt))

	# ---- steppers --------------------------------------------------------
	var step_trig: float = rig.stand_h * dna.step_trigger_f
	var step_h: float = rig.stand_h * dna.step_height_f
	var xf := creature.global_transform
	for s in _steppers:
		var leg: Dictionary = s.leg
		var home: Vector3 = xf * leg.home_local
		var ghit := _ray(space, home + Vector3.UP * rig.stand_h, rig.stand_h * 3.0)
		var ground: Vector3 = ghit.position if ghit else Vector3(home.x, creature.global_position.y, home.z)

		if s.swing_t >= 0.0:  # mid-swing
			s.swing_t = minf(s.swing_t + dt / dna.step_time, 1.0)
			var t: float = s.swing_t
			var p: Vector3 = s.from.lerp(s.to, smoothstep(0.0, 1.0, t))
			p.y += sin(PI * t) * step_h
			leg.target.global_position = p
			if s.swing_t >= 1.0:
				s.planted = s.to
				s.swing_t = -1.0
				_stepping_in_group[leg.group] -= 1
				steps_taken += 1
		else:
			var overstretch: float = (s.planted as Vector3).distance_to(ground)
			var other: int = 1 - int(leg.group)
			var may: bool = _stepping_in_group[other] == 0 or overstretch > step_trig * 1.9
			if overstretch > step_trig and may:
				s.swing_t = 0.0
				s.from = s.planted
				s.to = ground + vel * dna.step_time * 0.7
				_stepping_in_group[leg.group] += 1
			leg.target.global_position = s.planted

		# knee pole rides with the body
		leg.pole.global_position = xf * leg.pole_local

	# ---- body dynamics from feet ----------------------------------------
	var front := 0.0; var back := 0.0; var left := 0.0; var right := 0.0
	var nf := 0; var nb := 0; var nl := 0; var nr := 0
	var avg_y := 0.0
	for s in _steppers:
		var lp: Vector3 = xf.affine_inverse() * (s.planted as Vector3)
		avg_y += lp.y
		if lp.z < 0.0: front += lp.y; nf += 1
		else: back += lp.y; nb += 1
		if lp.x < 0.0: left += lp.y; nl += 1
		else: right += lp.y; nr += 1
	avg_y /= maxf(1.0, _steppers.size())
	var tgt_pitch := 0.0
	if nf > 0 and nb > 0:
		tgt_pitch = atan2((front / nf) - (back / nb), maxf(dna.body_len, 0.3))
	var tgt_roll := 0.0
	if nl > 0 and nr > 0:
		tgt_roll = atan2((right / nr) - (left / nl), maxf(dna.body_r * 4.0, 0.3))
	var k := 1.0 - pow(0.002, dt)
	_pitch = lerpf(_pitch, tgt_pitch * 0.6, k)
	_roll = lerpf(_roll, tgt_roll * 0.5, k)
	_body_y_off = lerpf(_body_y_off, avg_y * 0.7, k)

	var bob := sin(_time * TAU * (dna.move_speed / maxf(rig.stand_h, 0.2)) * 0.7) * dna.bob_amp
	var skel: Skeleton3D = rig.skeleton
	skel.set_bone_pose_position(rig.body, rig.body_rest_pos + Vector3(0, _body_y_off + bob, 0))
	skel.set_bone_pose_rotation(rig.body, Quaternion(Vector3.RIGHT, _pitch) * Quaternion(Vector3.BACK, _roll))

	# look target drifts ahead with a little curiosity
	rig.look_target.global_position = xf * (rig.head_local + Vector3(sin(_time * 0.8) * 1.2, sin(_time * 0.53) * 0.5, -3.0))

func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, dist: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * dist)
	return space.intersect_ray(q)
```

#### `creature/canned_gait.gd`

```gdscript
class_name CannedGait
extends Node
## LOD2 fallback animation: pure sine-driven forward-kinematics leg swing plus
## body bob, written straight into bone poses. No raycasts, no IK, no springs.
## Looks worse up close, reads fine at 60m+, costs almost nothing.
## Swing axes are captured in bone-local space at setup so any morphology works.

var creature: Node3D
var rig: Dictionary
var dna: CreatureDNA
var tick_divisor: int = 6

var _tick := 0
var _time := 0.0
var _leg_data: Array[Dictionary] = []
var pose_writes := 0  # telemetry for tests

func setup(p_creature: Node3D, p_rig: Dictionary, p_dna: CreatureDNA) -> void:
	creature = p_creature
	rig = p_rig
	dna = p_dna
	process_physics_priority = -10
	var skel: Skeleton3D = rig.skeleton
	for leg in rig.legs:
		var rest_u: Quaternion = skel.get_bone_rest(leg.upper).basis.get_rotation_quaternion()
		var rest_l: Quaternion = skel.get_bone_rest(leg.lower).basis.get_rotation_quaternion()
		# world +X (sagittal swing axis) expressed in each bone's parent space:
		# parents are near-identity in rotation, so X is a fine approximation for a far LOD.
		_leg_data.append({
			"leg": leg, "rest_u": rest_u, "rest_l": rest_l,
			"phase": PI * float(leg.group),
		})
	set_physics_process(false)

func _physics_process(delta: float) -> void:
	_tick += 1
	if _tick % tick_divisor != 0:
		return
	var dt := delta * float(tick_divisor)
	_time += dt
	var skel: Skeleton3D = rig.skeleton
	var freq: float = TAU * clampf(dna.move_speed / maxf(rig.stand_h, 0.25), 0.8, 4.0) * 0.55
	var amp := 0.45
	for ld in _leg_data:
		var leg: Dictionary = ld.leg
		var sw: float = sin(_time * freq + ld.phase) * amp
		var kn: float = maxf(0.0, cos(_time * freq + ld.phase)) * amp * 1.2
		skel.set_bone_pose_rotation(leg.upper, Quaternion(Vector3.RIGHT, sw) * ld.rest_u)
		skel.set_bone_pose_rotation(leg.lower, Quaternion(Vector3.RIGHT, kn) * ld.rest_l)
	skel.set_bone_pose_position(rig.body, rig.body_rest_pos + Vector3(0, sin(_time * freq * 2.0) * dna.bob_amp, 0))
	pose_writes += 1
	# root still drifts forward so far crowds read as alive
	creature.global_position += -creature.global_transform.basis.z * dna.move_speed * dt
```

#### `creature/creature_lod.gd`

```gdscript
class_name CreatureLOD
extends Node
## Animation LOD tiers (distance to current camera, checked at 4 Hz):
##  LOD0  < 25 m  full: 60 Hz gait, IK, springs, head look
##  LOD1  < 60 m  gait at ~15 Hz, IK on, springs/look off
##  LOD2  < 120 m canned FK sine gait at ~10 Hz, all modifiers off
##  LOD3  beyond  frozen pose, zero per-frame cost
## force_lod >= 0 pins a tier (debug/testing).

const D0 := 25.0
const D1 := 60.0
const D2 := 120.0
const HYST := 0.12

var creature: Node3D
var rig: Dictionary
var gait: GaitController
var canned: CannedGait
var force_lod: int = -1
var current: int = -1

var _accum := 0.0

func setup(p_creature: Node3D, p_rig: Dictionary, p_gait: GaitController, p_canned: CannedGait) -> void:
	creature = p_creature
	rig = p_rig
	gait = p_gait
	canned = p_canned
	_apply(0)
	set_process(true)

func _process(delta: float) -> void:
	_accum += delta
	if _accum < 0.25:
		return
	_accum = 0.0
	var tier := force_lod
	if tier < 0:
		var cam := creature.get_viewport().get_camera_3d() if creature.is_inside_tree() else null
		if cam == null:
			tier = 0
		else:
			var d := cam.global_position.distance_to(creature.global_position)
			# hysteresis: harder to leave the current tier than to enter it
			var m := 1.0 + (HYST if current >= 0 else 0.0)
			if d < D0 * (m if current == 0 else 1.0): tier = 0
			elif d < D1 * (m if current == 1 else 1.0): tier = 1
			elif d < D2 * (m if current == 2 else 1.0): tier = 2
			else: tier = 3
	if tier != current:
		_apply(tier)

## Set and apply a tier right now (no wait for the 4 Hz poll). -1 = auto.
func force_now(tier: int) -> void:
	force_lod = tier
	if tier >= 0:
		_apply(tier)

func _apply(tier: int) -> void:
	current = tier
	var ik: TwoBoneIK3D = rig.ik
	var look: LookAtModifier3D = rig.look
	var spring: SpringBoneSimulator3D = rig.spring
	match tier:
		0:
			gait.tick_divisor = 1
			gait.set_physics_process(true)
			canned.set_physics_process(false)
			ik.active = true
			look.active = true
			if spring: spring.active = true
		1:
			gait.tick_divisor = 4
			gait.set_physics_process(true)
			canned.set_physics_process(false)
			ik.active = true
			look.active = false
			if spring: spring.active = false
		2:
			gait.set_physics_process(false)
			canned.tick_divisor = 6
			canned.set_physics_process(true)
			ik.active = false
			look.active = false
			if spring: spring.active = false
		3:
			gait.set_physics_process(false)
			canned.set_physics_process(false)
			ik.active = false
			look.active = false
			if spring: spring.active = false
```

#### `creature/proc_creature.gd`

```gdscript
class_name ProcCreature
extends Node3D
## A procedurally generated, procedurally animated creature.
## Usage:  var c := ProcCreature.spawn(CreatureDNA.random(seed))
##         world.add_child(c)   # position it, done.

var dna: CreatureDNA
var rig: Dictionary = {}
var gait: GaitController
var canned: CannedGait
var lod: CreatureLOD

static func spawn(p_dna: CreatureDNA) -> ProcCreature:
	var c := ProcCreature.new()
	c.dna = p_dna
	c.name = "%s_%d" % [p_dna.creature_name, p_dna.seed_value]
	return c

func _ready() -> void:
	rig = CreatureBuilder.build(dna, self)
	gait = GaitController.new()
	gait.name = "Gait"
	add_child(gait)
	gait.setup(self, rig, dna)
	canned = CannedGait.new()
	canned.name = "CannedGait"
	add_child(canned)
	canned.setup(self, rig, dna)
	lod = CreatureLOD.new()
	lod.name = "LOD"
	add_child(lod)
	lod.setup(self, rig, gait, canned)

func set_forced_lod(tier: int) -> void:
	lod.force_now(tier)
```

---

## 5. Native mesh forge (C++ GDExtension — optional but recommended)

Exact port of `PartMeshLib`'s emission with identical ring/index patterns → **bit-identical vertex counts and AABBs** vs the GDScript path (parity-asserted in the smoke test). Normal generation replicates SurfaceTool semantics: smooth mode accumulates area-weighted face normals per *bitwise position* (so UV-seam duplicate vertices unify); flat mode accumulates per emitted vertex.

Integration contract: `PartMeshLib.backend = "auto" | "gd" | "native"`. Auto prefers native when the extension is loaded and **falls back silently** — the project must always run without the compiled lib. Stations cross the GDScript↔C++ boundary as Dictionaries (cheap; the hot per-vertex loops are all C++). Measured x2.5 end-to-end creature-build speedup (the mesh bake itself is far faster; GDScript skeleton/node setup now dominates). The native path is also safe to run in a `WorkerThreadPool` task for hitch-free herd spawning — bake the ArrayMesh off-thread, attach on the main thread.

### 5.1 Build setup

```bash
# 1. godot-cpp — use master until an official 4.6 branch exists
git clone --depth 1 https://github.com/godotengine/godot-cpp.git

# 2. CRITICAL: dump the extension API from YOUR exact binary (ABI match)
godot --headless --dump-extension-api    # produces extension_api.json

# 3. build godot-cpp, then the extension (SConstruct below expects
#    godot-cpp as a sibling of the project root — adjust the path if not)
cd godot-cpp && scons platform=linux target=template_debug \
    custom_api_file=/abs/path/extension_api.json -j$(nproc)
cd ../native && scons platform=linux target=template_debug \
    custom_api_file=/abs/path/extension_api.json
# outputs bin/libcreatureforge.linux.template_debug.x86_64.so
```

The `.gdextension` manifest (project root) — Godot auto-loads it on import:

```ini
[configuration]

entry_symbol = "forge_init"
compatibility_minimum = "4.6"

[libraries]

linux.debug.x86_64 = "res://bin/libcreatureforge.linux.template_debug.x86_64.so"
linux.release.x86_64 = "res://bin/libcreatureforge.linux.template_release.x86_64.so"
windows.debug.x86_64 = "res://bin/libcreatureforge.windows.template_debug.x86_64.dll"
windows.release.x86_64 = "res://bin/libcreatureforge.windows.template_release.x86_64.dll"
macos.debug = "res://bin/libcreatureforge.macos.template_debug.framework"
macos.release = "res://bin/libcreatureforge.macos.template_release.framework"
```

### 5.2 Native sources (verbatim tested files)

#### `native/SConstruct`

```python
#!/usr/bin/env python
import os
env = SConscript("../../godot-cpp/SConstruct")
env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")
lib = env.SharedLibrary(
    "../bin/libcreatureforge{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)
Default(lib)
```

#### `native/src/mesh_forge.h`

```cpp
#ifndef MESH_FORGE_H
#define MESH_FORGE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <vector>

namespace godot {

// Native port of PartMeshLib's geometry batch. Same emission order, same
// index patterns, so vertex counts and AABBs match the GDScript path exactly.
// Organic vs robotic stays a *skin-weight policy*: callers pass blended or
// hard weights per ring station; the forge just emits fast.
class MeshForge : public RefCounted {
	GDCLASS(MeshForge, RefCounted)

	struct Vtx {
		Vector3 pos;
		Vector2 uv;
		int32_t bones[4];
		float weights[4];
		uint32_t smooth_group;
	};

	std::vector<Vtx> verts;
	std::vector<int32_t> indices;
	bool smooth = true;
	uint32_t vcount = 0;

	int32_t emit(const Vector3 &pos, const Vector2 &uv,
			const PackedInt32Array &bones, const PackedFloat32Array &weights);
	int32_t ring(const Vector3 &pos, const Basis &basis, float radius, float rx,
			float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, int n);
	void cap(int32_t ring_base, int ring_n, const Vector3 &tip, const Vector3 &axis_y,
			float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, bool flip);

protected:
	static void _bind_methods();

public:
	void begin(bool p_smooth);

	// stations: Array of Dictionaries {pos, basis, radius, rx, v, bones, weights}
	void add_tube(const Array &stations, int ring_n, bool cap_start, bool cap_end);
	void add_rigid_segment(const Vector3 &p0, const Vector3 &p1, float r0, float r1,
			int bone, int ring_n, float inset);
	void add_sphere(const Vector3 &center, float r, const PackedInt32Array &bones,
			const PackedFloat32Array &weights, int lat, int lon, const Vector3 &squash);

	int get_vertex_count() const { return (int)vcount; }
	void commit(const Ref<ArrayMesh> &mesh, const Ref<Material> &material);

	static Basis basis_y_to(const Vector3 &dir);
};

} // namespace godot

#endif
```

#### `native/src/mesh_forge.cpp`

```cpp
#include "mesh_forge.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

void MeshForge::_bind_methods() {
	ClassDB::bind_method(D_METHOD("begin", "smooth"), &MeshForge::begin);
	ClassDB::bind_method(D_METHOD("add_tube", "stations", "ring_n", "cap_start", "cap_end"),
			&MeshForge::add_tube, DEFVAL(8), DEFVAL(true), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("add_rigid_segment", "p0", "p1", "r0", "r1", "bone", "ring_n", "inset"),
			&MeshForge::add_rigid_segment, DEFVAL(6), DEFVAL(0.03));
	ClassDB::bind_method(D_METHOD("add_sphere", "center", "r", "bones", "weights", "lat", "lon", "squash"),
			&MeshForge::add_sphere, DEFVAL(6), DEFVAL(8), DEFVAL(Vector3(1, 1, 1)));
	ClassDB::bind_method(D_METHOD("get_vertex_count"), &MeshForge::get_vertex_count);
	ClassDB::bind_method(D_METHOD("commit", "mesh", "material"), &MeshForge::commit);
}

void MeshForge::begin(bool p_smooth) {
	smooth = p_smooth;
	verts.clear();
	indices.clear();
	vcount = 0;
	verts.reserve(1024);
	indices.reserve(4096);
}

Basis MeshForge::basis_y_to(const Vector3 &dir) {
	Vector3 y = dir.normalized();
	if (y.length_squared() < 0.0001f) {
		y = Vector3(0, 1, 0);
	}
	Vector3 hint = Math::abs(y.dot(Vector3(1, 0, 0))) < 0.98f ? Vector3(1, 0, 0) : Vector3(0, 0, -1);
	Vector3 z = hint.cross(y).normalized();
	Vector3 x = y.cross(z).normalized();
	return Basis(x, y, z);
}

int32_t MeshForge::emit(const Vector3 &pos, const Vector2 &uv,
		const PackedInt32Array &bones, const PackedFloat32Array &weights) {
	Vtx v;
	v.pos = pos;
	v.uv = uv;
	for (int i = 0; i < 4; i++) {
		v.bones[i] = i < bones.size() ? bones[i] : 0;
		v.weights[i] = i < weights.size() ? weights[i] : 0.0f;
	}
	v.smooth_group = smooth ? 0u : vcount; // unique group per vertex = flat
	verts.push_back(v);
	return (int32_t)vcount++;
}

int32_t MeshForge::ring(const Vector3 &pos, const Basis &basis, float radius, float rx,
		float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, int n) {
	int32_t base = (int32_t)vcount;
	const Vector3 bx = basis.get_column(0);
	const Vector3 bz = basis.get_column(2);
	for (int k = 0; k <= n; k++) { // +1 duplicated seam vertex, identical position
		float a = (float)Math_TAU * (float)(k % n) / (float)n;
		Vector3 off = bx * (Math::cos(a) * radius * rx) + bz * (Math::sin(a) * radius);
		emit(pos + off, Vector2((float)k / (float)n, v), bones, weights);
	}
	return base;
}

void MeshForge::cap(int32_t ring_base, int ring_n, const Vector3 &tip, const Vector3 &axis_y,
		float v, const PackedInt32Array &bones, const PackedFloat32Array &weights, bool flip) {
	int32_t tip_i = emit(tip, Vector2(0.5f, v), bones, weights);
	for (int k = 0; k < ring_n; k++) {
		if (flip) {
			indices.push_back(ring_base + k + 1);
			indices.push_back(tip_i);
			indices.push_back(ring_base + k);
		} else {
			indices.push_back(ring_base + k);
			indices.push_back(tip_i);
			indices.push_back(ring_base + k + 1);
		}
	}
	(void)axis_y;
}

void MeshForge::add_tube(const Array &stations, int ring_n, bool cap_start, bool cap_end) {
	const int ns = stations.size();
	if (ns < 2) {
		return;
	}
	std::vector<int32_t> bases;
	bases.reserve(ns);
	// cache first/last station data for caps
	Vector3 s0_pos, se_pos, s0_y, se_y;
	float s0_r = 0, se_r = 0, s0_v = 0, se_v = 0;
	PackedInt32Array s0_b, se_b;
	PackedFloat32Array s0_w, se_w;
	for (int i = 0; i < ns; i++) {
		Dictionary s = stations[i];
		Vector3 pos = s["pos"];
		Basis basis = s["basis"];
		float radius = s["radius"];
		float rx = s.has("rx") ? (float)s["rx"] : 1.0f;
		float v = s["v"];
		PackedInt32Array b = s["bones"];
		PackedFloat32Array w = s["weights"];
		bases.push_back(ring(pos, basis, radius, rx, v, b, w, ring_n));
		if (i == 0) { s0_pos = pos; s0_y = basis.get_column(1); s0_r = radius; s0_v = v; s0_b = b; s0_w = w; }
		if (i == ns - 1) { se_pos = pos; se_y = basis.get_column(1); se_r = radius; se_v = v; se_b = b; se_w = w; }
	}
	for (int i = 0; i < ns - 1; i++) {
		int32_t b0 = bases[i];
		int32_t b1 = bases[i + 1];
		for (int k = 0; k < ring_n; k++) {
			indices.push_back(b0 + k); indices.push_back(b1 + k); indices.push_back(b0 + k + 1);
			indices.push_back(b0 + k + 1); indices.push_back(b1 + k); indices.push_back(b1 + k + 1);
		}
	}
	if (cap_start) {
		cap(bases[0], ring_n, s0_pos - s0_y * s0_r * 0.6f, s0_y, s0_v, s0_b, s0_w, true);
	}
	if (cap_end) {
		cap(bases[ns - 1], ring_n, se_pos + se_y * se_r * 0.6f, se_y, se_v, se_b, se_w, false);
	}
}

void MeshForge::add_rigid_segment(const Vector3 &p0, const Vector3 &p1, float r0, float r1,
		int bone, int ring_n, float inset) {
	Vector3 dir = (p1 - p0).normalized();
	Basis b = basis_y_to(dir);
	Vector3 q0 = p0 + dir * inset;
	Vector3 q1 = p1 - dir * inset;
	PackedInt32Array bn;
	bn.push_back(bone); bn.push_back(0); bn.push_back(0); bn.push_back(0);
	PackedFloat32Array w;
	w.push_back(1.0f); w.push_back(0.0f); w.push_back(0.0f); w.push_back(0.0f);

	Array sts;
	Dictionary s0, s1;
	s0["pos"] = q0; s0["basis"] = b; s0["radius"] = r0; s0["rx"] = 1.0f; s0["v"] = 0.0f;
	s0["bones"] = bn; s0["weights"] = w;
	s1["pos"] = q1; s1["basis"] = b; s1["radius"] = r1; s1["rx"] = 1.0f; s1["v"] = 1.0f;
	s1["bones"] = bn; s1["weights"] = w;
	sts.push_back(s0);
	sts.push_back(s1);
	add_tube(sts, ring_n, true, true);
}

void MeshForge::add_sphere(const Vector3 &center, float r, const PackedInt32Array &bones,
		const PackedFloat32Array &weights, int lat, int lon, const Vector3 &squash) {
	std::vector<int32_t> rows;
	rows.reserve(lat + 1);
	for (int i = 0; i <= lat; i++) {
		float phi = (float)Math_PI * (float)i / (float)lat;
		float y = Math::cos(phi) * r * (float)squash.y;
		float rr = Math::sin(phi) * r;
		int32_t base = (int32_t)vcount;
		for (int k = 0; k <= lon; k++) {
			float a = (float)Math_TAU * (float)(k % lon) / (float)lon;
			Vector3 off(Math::cos(a) * rr * (float)squash.x, y, Math::sin(a) * rr * (float)squash.z);
			emit(center + off, Vector2((float)k / (float)lon, (float)i / (float)lat), bones, weights);
		}
		rows.push_back(base);
	}
	for (int i = 0; i < lat; i++) {
		int32_t b0 = rows[i];
		int32_t b1 = rows[i + 1];
		for (int k = 0; k < lon; k++) {
			indices.push_back(b0 + k); indices.push_back(b0 + k + 1); indices.push_back(b1 + k);
			indices.push_back(b0 + k + 1); indices.push_back(b1 + k + 1); indices.push_back(b1 + k);
		}
	}
}

void MeshForge::commit(const Ref<ArrayMesh> &mesh, const Ref<Material> &material) {
	ERR_FAIL_COND(mesh.is_null());
	if (vcount == 0) {
		return;
	}
	const size_t nv = verts.size();

	// ---- normal generation, SurfaceTool-compatible ------------------------
	// smooth: vertices sharing (bitwise) position accumulate together, so the
	// duplicated UV-seam vertex gets the same normal as ring vertex 0.
	// flat (unique smooth groups): accumulate per emitted vertex only.
	std::vector<Vector3> nrm(nv, Vector3());
	HashMap<Vector3, Vector3> pos_accum;
	const size_t ntri = indices.size() / 3;
	for (size_t t = 0; t < ntri; t++) {
		int32_t i0 = indices[t * 3 + 0];
		int32_t i1 = indices[t * 3 + 1];
		int32_t i2 = indices[t * 3 + 2];
		const Vector3 &p0 = verts[i0].pos;
		const Vector3 &p1 = verts[i1].pos;
		const Vector3 &p2 = verts[i2].pos;
		// winding matches SurfaceTool's convention (clockwise front faces)
		Vector3 fn = (p0 - p1).cross(p0 - p2); // area-weighted
		if (smooth) {
			pos_accum[p0] += fn;
			pos_accum[p1] += fn;
			pos_accum[p2] += fn;
		} else {
			nrm[i0] += fn;
			nrm[i1] += fn;
			nrm[i2] += fn;
		}
	}
	for (size_t i = 0; i < nv; i++) {
		Vector3 n = smooth ? (pos_accum.has(verts[i].pos) ? pos_accum[verts[i].pos] : Vector3(0, 1, 0)) : nrm[i];
		float l = n.length();
		nrm[i] = l > 0.00001f ? n / l : Vector3(0, 1, 0);
	}

	// ---- pack arrays -------------------------------------------------------
	PackedVector3Array pv, pn;
	PackedVector2Array puv;
	PackedInt32Array pb, pidx;
	PackedFloat32Array pw;
	pv.resize(nv); pn.resize(nv); puv.resize(nv);
	pb.resize(nv * 4); pw.resize(nv * 4);
	pidx.resize(indices.size());
	Vector3 *pvw = pv.ptrw();
	Vector3 *pnw = pn.ptrw();
	Vector2 *puvw = puv.ptrw();
	int32_t *pbw = pb.ptrw();
	float *pww = pw.ptrw();
	int32_t *pidxw = pidx.ptrw();
	for (size_t i = 0; i < nv; i++) {
		pvw[i] = verts[i].pos;
		pnw[i] = nrm[i];
		puvw[i] = verts[i].uv;
		for (int j = 0; j < 4; j++) {
			pbw[i * 4 + j] = verts[i].bones[j];
			pww[i * 4 + j] = verts[i].weights[j];
		}
	}
	for (size_t i = 0; i < indices.size(); i++) {
		pidxw[i] = indices[i];
	}

	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = pv;
	arrays[Mesh::ARRAY_NORMAL] = pn;
	arrays[Mesh::ARRAY_TEX_UV] = puv;
	arrays[Mesh::ARRAY_BONES] = pb;
	arrays[Mesh::ARRAY_WEIGHTS] = pw;
	arrays[Mesh::ARRAY_INDEX] = pidx;

	Ref<ArrayMesh> m = mesh;
	int surf = m->get_surface_count();
	m->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	if (material.is_valid()) {
		m->surface_set_material(surf, material);
	}
}
```

#### `native/src/register_types.cpp`

```cpp
#include "mesh_forge.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_forge(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(MeshForge);
}

void uninitialize_forge(ModuleInitializationLevel p_level) {}

extern "C" {
GDExtensionBool GDE_EXPORT forge_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_forge);
	init_obj.register_terminator(uninitialize_forge);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
```

---

## 6. Test + playground sources (verbatim tested files)

#### `tests/smoke_test.gd`

```gdscript
extends SceneTree
## Headless smoke test. Run AFTER an import pass:
##   godot --headless --path . --import
##   godot --headless --path . --script tests/smoke_test.gd
## Validates: skeleton counts, mesh integrity (verts/normals/weights/AABB),
## locomotion, stepping, IK foot accuracy at LOD0, canned gait at LOD2,
## and (if the native MeshForge extension is present) GDScript/C++ parity + speed.

const FRAMES_SETTLE := 30
const FRAMES_RUN := 240

var _fail := 0
var _ik_samples: Array[float] = []
var _watch_rig: Dictionary = {}
var _worst_note := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS  ", msg)
	else:
		_fail += 1
		printerr("  FAIL  ", msg)

func _init() -> void:
	await physics_frame  # let the tree come up
	print("=== procgen creature smoke test (Godot %s) ===" % Engine.get_version_info().string)

	var world := Node3D.new()
	root.add_child(world)
	# flat ground + one bump to exercise raycast placement
	world.add_child(_static_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400)))
	world.add_child(_static_box(Vector3(4, -0.2, -6), Vector3(6, 0.8, 6)))

	var DNA = load("res://creature/creature_dna.gd")
	var PC = load("res://creature/proc_creature.gd")

	# ---- build a mixed herd ------------------------------------------------
	var creatures: Array = []
	var seeds := [11, 22, 33, 44, 55, 66]
	for i in seeds.size():
		var dna = DNA.random(seeds[i])
		if i < 3: dna.archetype = DNA.Archetype.ORGANIC
		else: dna.archetype = DNA.Archetype.ROBOTIC
		var c = PC.spawn(dna)
		world.add_child(c)
		c.global_position = Vector3(float(i) * 5.0 - 12.0, 0.0, 0.0)
		creatures.append(c)

	await physics_frame
	await physics_frame

	# ---- structural checks -------------------------------------------------
	print("\n-- structure --")
	for c in creatures:
		var dna = c.dna
		var skel: Skeleton3D = c.rig.skeleton
		var expected: int = 1 + dna.spine_joints + 1 + dna.tail_joints + dna.leg_pairs.size() * 2 * 3
		_check(skel.get_bone_count() == expected,
			"%s bones %d == %d" % [c.name, skel.get_bone_count(), expected])
		var mi: MeshInstance3D = c.rig.mesh_instance
		var vtx := 0
		for s in mi.mesh.get_surface_count():
			vtx += (mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		_check(vtx > 100, "%s mesh verts %d > 100" % [c.name, vtx])
		_check(mi.skin != null, "%s has skin" % c.name)
		var aabb := mi.mesh.get_aabb()
		_check(aabb.size.length() > 0.5 and aabb.size.length() < 60.0,
			"%s AABB sane (%.2f)" % [c.name, aabb.size.length()])
		# normals normalized
		var nrm: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
		var ok_n := true
		for k in mini(nrm.size(), 50):
			if absf(nrm[k].length() - 1.0) > 0.02: ok_n = false
		_check(ok_n, "%s normals unit length" % c.name)
		# weights sum ~1
		var wts: PackedFloat32Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_WEIGHTS]
		var ok_w := true
		var stride := wts.size() / (mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		for k in mini(40, (wts.size() / stride)):
			var sum := 0.0
			for j in stride: sum += wts[k * stride + j]
			if absf(sum - 1.0) > 0.01: ok_w = false
		_check(ok_w, "%s skin weights sum to 1 (stride %d)" % [c.name, stride])

	# ---- LOD0 run: locomotion, stepping, IK accuracy ------------------------
	print("\n-- LOD0 gait + IK (%d frames) --" % FRAMES_RUN)
	for c in creatures:
		c.set_forced_lod(0)
	_watch_rig = creatures[0].rig
	var skel0: Skeleton3D = _watch_rig.skeleton
	skel0.skeleton_updated.connect(_sample_ik)
	var starts := {}
	for c in creatures: starts[c] = c.global_position
	for f in FRAMES_SETTLE + FRAMES_RUN:
		await physics_frame
	skel0.skeleton_updated.disconnect(_sample_ik)

	for c in creatures:
		var moved: float = (c.global_position - starts[c]).length()
		_check(moved > 1.0, "%s moved %.2f m" % [c.name, moved])
		_check(c.gait.steps_taken >= c.rig.legs.size() * 2,
			"%s steps %d >= %d" % [c.name, c.gait.steps_taken, c.rig.legs.size() * 2])
	_check(_ik_samples.size() > 50, "IK sampled %d times" % _ik_samples.size())
	if _ik_samples.size() > 0:
		var worst := 0.0
		var mean := 0.0
		for e in _ik_samples: worst = maxf(worst, e); mean += e
		mean /= _ik_samples.size()
		var reach: float = _watch_rig.legs[0].reach
		_check(mean < reach * 0.06, "IK mean err %.4f < %.4f" % [mean, reach * 0.06])
		_check(worst < reach * 0.35, "IK worst err %.4f < %.4f (swing incl.)" % [worst, reach * 0.35])
		if worst >= reach * 0.35:
			print("    worst context: ", _worst_note)

	# ---- LOD2 canned gait ----------------------------------------------------
	print("\n-- LOD2 canned gait --")
	for c in creatures:
		c.set_forced_lod(2)
	await physics_frame
	var c0 = creatures[0]
	var upper0: int = c0.rig.legs[0].upper
	var rot_before: Quaternion = c0.rig.skeleton.get_bone_pose_rotation(upper0)
	var pos_before: Vector3 = c0.global_position
	for f in 90: await physics_frame
	_check(c0.canned.pose_writes > 5, "canned gait wrote %d poses" % c0.canned.pose_writes)
	_check((c0.rig.skeleton.get_bone_pose_rotation(upper0).angle_to(rot_before)) > 0.001
		or (c0.global_position - pos_before).length() > 0.1, "LOD2 visibly animates")
	_check(not c0.rig.ik.active, "LOD2 IK disabled")

	# ---- LOD3 freeze ----------------------------------------------------------
	for c in creatures: c.set_forced_lod(3)
	await physics_frame
	var pos3: Vector3 = c0.global_position
	for f in 30: await physics_frame
	_check((c0.global_position - pos3).length() < 0.001, "LOD3 frozen")

	# ---- native MeshForge parity + benchmark (if extension loaded) -----------
	print("\n-- native MeshForge --")
	var PML = load("res://creature/part_mesh_lib.gd")
	if PML.native_available():
		var CB = load("res://creature/creature_builder.gd")
		# parity first: same seed, same vertex counts per surface + same AABB
		PML.backend = "gd"
		var m_gd := _build_mesh_only(DNA, CB, 777)
		PML.backend = "native"
		var m_cpp := _build_mesh_only(DNA, CB, 777)
		_check(m_gd.get_surface_count() == m_cpp.get_surface_count(),
			"parity surfaces %d == %d" % [m_gd.get_surface_count(), m_cpp.get_surface_count()])
		for s in mini(m_gd.get_surface_count(), m_cpp.get_surface_count()):
			var v_gd := (m_gd.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var v_cpp := (m_cpp.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			_check(v_gd == v_cpp, "parity surf %d verts %d == %d" % [s, v_gd, v_cpp])
		var d: Vector3 = (m_gd.get_aabb().size - m_cpp.get_aabb().size).abs()
		_check(d.length() < 0.01, "parity AABB delta %.4f" % d.length())
		# benchmark
		PML.backend = "gd"
		var t_gd := _bench_build(DNA, CB)
		PML.backend = "native"
		var t_cpp := _bench_build(DNA, CB)
		PML.backend = "auto"
		print("  build 20 creatures  gdscript %.1f ms   native %.1f ms   speedup x%.1f"
			% [t_gd, t_cpp, t_gd / maxf(t_cpp, 0.001)])
		_check(t_cpp < t_gd, "native path faster")
	else:
		print("  (extension not present — GDScript fallback in use, skipping)")

	print("\n=== %s — %d failure(s) ===" % ["OK" if _fail == 0 else "FAILED", _fail])
	quit(1 if _fail > 0 else 0)

func _sample_ik() -> void:
	# inside skeleton_updated the modified (post-IK) poses are readable
	var skel: Skeleton3D = _watch_rig.skeleton
	var worst_prev := 0.0
	for e in _ik_samples: worst_prev = maxf(worst_prev, e)
	for leg in _watch_rig.legs:
		var foot_g: Vector3 = (skel.global_transform * skel.get_bone_global_pose(leg.foot)).origin
		var tgt: Vector3 = leg.target.global_position
		var err := foot_g.distance_to(tgt)
		_ik_samples.append(err)
		if err > worst_prev:
			worst_prev = err
			_worst_note = "leg u=%d foot_g=%s tgt=%s dist_from_hip=%.2f reach=%.2f" % [
				leg.upper, foot_g, tgt,
				tgt.distance_to((skel.global_transform * skel.get_bone_global_pose(leg.upper)).origin),
				leg.reach]

func _bench_build(DNA, CB) -> float:
	var holder := Node3D.new()
	root.add_child(holder)
	var t0 := Time.get_ticks_usec()
	for i in 20:
		var n := Node3D.new()
		holder.add_child(n)
		CB.build(DNA.random(9000 + i), n)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	holder.queue_free()
	return ms

func _build_mesh_only(DNA, CB, seed_v: int) -> ArrayMesh:
	var n := Node3D.new()
	root.add_child(n)
	var rig: Dictionary = CB.build(DNA.random(seed_v), n)
	var m: ArrayMesh = rig.mesh_instance.mesh
	n.queue_free()
	return m

func _static_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.position = pos
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	b.add_child(cs)
	return b
```

#### `test/main.gd`

```gdscript
extends Node3D
## Visual playground. Spawns a mixed herd on uneven terrain.
## Keys:  R = reroll seeds | 0 = auto LOD | 1-4 = force LOD0..3 | Esc = quit
## Mouse: drag = orbit, wheel = zoom.

const HERD := 9

var _seed_base := 1000
var _creatures: Array[ProcCreature] = []
var _cam_pivot: Node3D
var _cam: Camera3D
var _yaw := 0.6
var _pitch := -0.45
var _dist := 16.0
var _label: Label

func _ready() -> void:
	_build_environment()
	_build_camera()
	_spawn_herd()
	_label = Label.new()
	_label.position = Vector2(12, 8)
	add_child(_label)

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = Sky.new()
	e.sky.sky_material = ProceduralSkyMaterial.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)

	_add_box(Vector3(0, -0.5, 0), Vector3(300, 1, 300), Color(0.35, 0.42, 0.3))  # ground
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 24:  # bumps and ramps so raycast foot placement has work to do
		var p := Vector3(rng.randf_range(-30, 30), rng.randf_range(-0.35, 0.15), rng.randf_range(-30, 30))
		var s := Vector3(rng.randf_range(1.5, 6), rng.randf_range(0.3, 0.9), rng.randf_range(1.5, 6))
		_add_box(p, s, Color(0.42, 0.4, 0.36), rng.randf_range(-0.15, 0.15))

func _add_box(pos: Vector3, size: Vector3, col: Color, tilt := 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation.z = tilt
	var shape := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	shape.shape = bx
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	bm.material = mat
	mi.mesh = bm
	body.add_child(mi)
	add_child(body)

func _build_camera() -> void:
	_cam_pivot = Node3D.new()
	add_child(_cam_pivot)
	_cam = Camera3D.new()
	_cam_pivot.add_child(_cam)
	_update_cam()

func _update_cam() -> void:
	_cam_pivot.rotation = Vector3(_pitch, _yaw, 0)
	_cam.position = Vector3(0, 0, _dist)
	_cam.look_at_from_position(_cam_pivot.to_global(Vector3(0, 0, _dist)), Vector3(0, 1, 0))

func _spawn_herd() -> void:
	for c in _creatures:
		c.queue_free()
	_creatures.clear()
	var side := int(ceil(sqrt(float(HERD))))
	for i in HERD:
		var dna := CreatureDNA.random(_seed_base + i)
		var c := ProcCreature.spawn(dna)
		add_child(c)
		c.global_position = Vector3((i % side) * 6.0 - side * 3.0, 0, (i / side) * 6.0 - side * 3.0)
		c.rotation.y = randf() * TAU
		_creatures.append(c)
		print("spawned %s  (%s, %d legs, tail %d)" % [dna.creature_name,
			"organic" if dna.archetype == CreatureDNA.Archetype.ORGANIC else "robotic",
			dna.leg_pairs.size() * 2, dna.tail_joints])

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed:
		match ev.keycode:
			KEY_R:
				_seed_base += 100
				_spawn_herd()
			KEY_0:
				for c in _creatures: c.set_forced_lod(-1)
			KEY_1, KEY_2, KEY_3, KEY_4:
				for c in _creatures: c.set_forced_lod(ev.keycode - KEY_1)
			KEY_ESCAPE:
				get_tree().quit()
	elif ev is InputEventMouseMotion and ev.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_yaw -= ev.relative.x * 0.008
		_pitch = clampf(_pitch - ev.relative.y * 0.008, -1.4, -0.05)
		_update_cam()
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP: _dist = maxf(4.0, _dist * 0.9)
		if ev.button_index == MOUSE_BUTTON_WHEEL_DOWN: _dist = minf(140.0, _dist * 1.1)
		_update_cam()

func _process(_dt: float) -> void:
	if _creatures.is_empty():
		return
	var lods := ""
	for c in _creatures:
		lods += str(c.lod.current)
	_label.text = "R reroll | 0 auto-LOD | 1-4 force LOD | drag orbit | wheel zoom\nLOD tiers: %s   fps %d" % [lods, Engine.get_frames_per_second()]
```

---

## 7. Validation (headless CI)

Run order matters — an import pass must generate `.godot/` (and load the extension) before the script pass:

```bash
godot --headless --path . --import
godot --headless --path . --script tests/smoke_test.gd   # exit 0 = pass
```

The smoke test (verbatim below) asserts: bone counts match DNA; mesh verts/normals/skin-weights/AABB sane; every creature locomotes and steps; **IK foot accuracy sampled inside `skeleton_updated`** (thresholds: mean < 6% of leg reach, worst < 35% — swings included); LOD2 animates with IK disabled; LOD3 fully frozen; native parity (surface count, per-surface vertex counts, AABB delta < 0.01) and native-faster benchmark. Reference results on 4.6-stable: mean IK error 0.0002 m, worst 0.033 m (one-frame swing lag), parity AABB delta 0.0000, speedup x2.5.

Expected structural bone count per creature: `1 body + spine_joints + 1 head + tail_joints + legs*3`.

Note: quitting the SceneTree with dozens of live creatures mid-physics can print a harmless teardown abort *after* all assertions pass (exit code still reflects test status); isolated runs are clean on both backends.

## 8. Visual playground

`test/main.gd` (verbatim below) — attach to an empty `Node3D` scene root, set it as the main scene. Spawns a 3x3 mixed herd on bumpy terrain. Keys: **R** reroll seeds, **0** auto-LOD, **1-4** force LOD0..3, **Esc** quit; drag orbits, wheel zooms. On-screen label shows each creature's live LOD tier + fps.

## 9. Production roadmap

1. **Seam quality (organic):** current shoulder weld is weight-blended tube-into-tube — good, not seamless. Upgrades in effort order: (a) shader normal blending at the weld ring; (b) metaball/SDF skinning — evaluate part SDFs into a small `godot_voxel` buffer, Transvoxel-mesh once per DNA, cache by seed.
2. **Part library growth:** mouths, horns, fins, wings as new forge emitters; DNA gains part slots; sockets = named bones + local transforms (the NMS model).
3. **Active ragdoll:** per-limb `PhysicalBoneSimulator3D` blend-in on damage, crossfade back to gait.
   *Prototyped in [`../gait_physics_merge/`](../gait_physics_merge/). `CreatureBuilder` gained an
   optional `build(dna, root, split := true)` + `split_rig()` that emits the Target/Puppet split for
   it (added 2026-07-17, not headless-validated — the verbatim `build()` in §4 above predates it).*
4. **Threaded herd spawning:** run the builder's mesh phase (native forge) in `WorkerThreadPool`; attach mesh + skeleton on the main thread.
5. **Behavior layer:** gait exposes `wander` / `move_dir` — plug a steering/AI brain on top (reuse the AdventureCraft awareness-state spec).
6. **Cross-platform forge builds:** `platform=windows` / macOS lipo, or ship GDScript-only — auto fallback means the extension is never a hard dependency.

## 10. Pitfall checklist for the implementing agent

- [ ] Pole node set for **every** TwoBoneIK setting (silent no-op otherwise).
- [ ] `process_physics_priority = -10` on anything writing IK targets or bone poses.
- [ ] Knee pre-bent in rest pose so the solver bends the right way.
- [ ] No world-space snapshots in `_ready()`; feet lazy-init on first physics tick; call `teleport_reset()` after teleports.
- [ ] `skeleton.modifier_callback_mode_process = MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS` (gait is physics-tick).
- [ ] `force_now()` when forcing LOD in tests — the 4 Hz poll is too slow for assertions.
- [ ] Import pass before any headless script run.
- [ ] Godot 4.6 `@GDScript` floats are fine, but Vector3 components are 32-bit — the C++ forge must use the same single-precision math for exact parity.

---

## 11. Synty animation pack integration (humanoid archetype)

*Design guidance — the import pipeline needs the actual FBX assets, so this section is not headless-validated like the rest. The modifier-ordering fact it relies on (modifiers run after AnimationMixer) is engine-documented behavior.*

### 11.1 Scope

Synty animation packs target a humanoid rig. They can drive a new `HUMANOID` DNA archetype; quadruped/hexapod/arbitrary morphologies keep the procedural gait. The organic/robotic **skin-weight policy is unchanged** — humanoid robots get inset segments + servo balls, humanoid organics get blended tubes, both playing Synty clips.

### 11.2 Asset import + retarget pipeline (one-time)

1. Import the Synty animation FBXs into the project (Godot 4.6 ufbx importer handles them directly).
2. In the Advanced Import Settings of a Synty rig scene: select the Skeleton3D → assign a **BoneMap** using `SkeletonProfileHumanoid` → map Synty bone names to profile bones (mostly auto-detected; fix stragglers by hand once).
3. Enable retargeting in the importer (Retarget → the profile). Imported `AnimationLibrary` tracks are now expressed against profile bone names.
4. Extract animations into a shared `AnimationLibrary` resource (`synty_locomotion.res`) so generated creatures reference clips without carrying Synty scenes.

### 11.3 Builder changes for the HUMANOID archetype

- Bone **names must match `SkeletonProfileHumanoid`** exactly: `Hips`, `Spine`, `Chest`, `Neck`, `Head`, `LeftUpperLeg`, `LeftLowerLeg`, `LeftFoot`, `LeftShoulder`, `LeftUpperArm`, ... Retargeted clips then apply to the generated skeleton with any DNA-rolled proportions.
- Rest orientation rule (+Y along bone, fact #4) still applies and is compatible with retargeting.
- Add an `AnimationPlayer` (or `AnimationTree` with a blend space: idle/walk/run by speed) as a sibling of the skeleton, `root_node` pointing at it, with the shared library.
- Keep the same `TwoBoneIK3D` setup for legs (pole nodes and all) — see next section.

### 11.4 Runtime layering: clips below, physics correction above

Frame order (engine-guaranteed): `AnimationTree` poses bones → `SkeletonModifier3D` stack runs → final pose. So:

```
AnimationTree      : Synty locomotion (blend by speed), full body
TwoBoneIK3D        : feet corrected onto raycast ground hits (terrain adaptation)
LookAtModifier3D   : head aim (influence ~0.5 over clips)
SpringBoneSimulator3D : tails/gear/antennae secondary motion
```

For HUMANOID, `GaitController` drops its stepper state machine and becomes a **foot-correction driver**:

- Each physics tick (still priority -10): raycast under each foot's *animated* position (readable from last frame inside `skeleton_updated`, or approximated by `home_local` + stride phase), set the IK target to the hit point when the clip's foot is in its contact phase, and to the animated position during swing. Simplest robust contact test: animated foot height below a small threshold relative to root.
- Set per-setting IK influence, if exposed, to fade correction in/out; otherwise snap targets to animated positions during swing (equivalent effect).
- Body pitch on slopes: keep the existing planted-height → pitch/roll logic with reduced gain (~0.3), since clips already contain body motion.
- Root motion: prefer velocity-driven movement (current design) and treat clips as in-place; if using Synty root-motion variants, set the AnimationTree root motion track and feed `get_root_motion_position()` into the creature root instead of `move_speed`.

### 11.5 LOD table (HUMANOID)

| Tier | Running |
|---|---|
| 0 | AnimationTree + foot IK + springs + look |
| 1 | AnimationTree + foot IK, springs/look off |
| 2 | AnimationTree only (cheap clip playback replaces CannedGait) |
| 3 | AnimationTree paused, frozen pose |

### 11.6 Licensing note

Synty's license covers use in shipped games but not redistributing the assets themselves — keep the FBX/clip library out of any public repo; the generated-creature code itself has no Synty dependency (HUMANOID archetype degrades to the procedural gait if the library resource is absent — keep that fallback).

### 11.7 Proportion clamps (retarget stretch — important)

Humanoid retargeting transfers **bone rotations**, not positions. When DNA proportions diverge from the Synty source rig, rotations stay valid but the pose distorts:

- Foot placement drifts → the foot IK layer fixes this (that's its job).
- Knee/elbow angles hyperflex or hyperextend → IK **cannot** fix this; it looks broken.
- Stride length no longer matches root velocity → foot sliding.

Mitigations (implement all three):
1. **Clamp HUMANOID DNA proportions** tighter than organic archetypes: leg/torso/arm length ratios within ~±25–30% of the Synty rig's ratios. Wilder silhouettes come from radii, head shape, attachments (horns/gear/tails) — not limb ratios.
2. **Scale locomotion speed by leg length**: `move_speed = clip_reference_speed * (dna_leg_length / synty_leg_length)` so stride frequency matches ground speed (no skating).
3. Drive clip blend (walk↔run) by *normalized* speed (`speed / leg_length`), not absolute speed.

---

## 12. Animation-sourced gait styles — feeding the physics gait FROM Synty clips

*Design + reference code. The baker needs the actual assets to run, so this section is not headless-validated; the gait-controller deltas modify validated code paths.*

### 12.1 Two integration modes — use both

| | Mode A (§11.4) | Mode B (this section) |
|---|---|---|
| Authority | Animation clip | Physics gait |
| Synty role | Full-body pose source | **Style source** (timing/arcs/bob) |
| Terrain | IK corrects contacts | Native (raycast footholds, world-planted feet) |
| Morphologies | Humanoid only | **Any** — style transfers to quadrupeds/hexapods |
| Best for | Humanoid enemies on mild terrain, LOD2 | Creatures, rough terrain, knockback robustness |

Mode B keeps everything validated in sections 3/6 — steppers, raycasts, emergent phase groups — and swaps the *hardcoded feel constants* for data baked from clips.

### 12.2 `GaitStyle` resource

```gdscript
class_name GaitStyle
extends Resource
## Locomotion style extracted from an animation clip. Morphology-independent:
## everything is normalized (times by cycle, lengths by leg length, heights by hip height).

@export var cycle_time := 0.8          # seconds per full gait cycle at reference speed
@export var reference_speed := 1.4     # root m/s the clip was authored at
@export var duty_factor := 0.62        # fraction of cycle a foot is planted (walk ~0.6, run ~0.35)
@export var phase_offsets: Array[float] = [0.0, 0.5]   # per phase-group cycle offset
@export var swing_arc: Curve           # normalized foot height over swing t 0..1 (replaces sin(PI*t))
@export var swing_reach: Curve         # normalized horizontal progress over swing t (replaces smoothstep)
@export var bob: Curve                 # hip vertical offset over cycle t, normalized by hip height
@export var bob_amp := 0.03            # meters at reference leg length
@export var stride_norm := 0.9         # stride length / leg length at reference speed
@export var sway_amp := 0.0            # lateral hip sway, normalized

func step_time() -> float: return cycle_time * (1.0 - duty_factor)
func step_trigger(leg_len: float) -> float: return stride_norm * leg_len * 0.5
```

### 12.3 One-time baker (headless tool script)

Runs the source Synty scene, samples foot bones through the clip, detects contacts, fits the curves. Run per pack once; commit the `.tres` outputs.

```gdscript
# tools/bake_gait_style.gd — run:
#   godot --headless --path . --script tools/bake_gait_style.gd -- <scene.tscn> <clip> <out.tres>
extends SceneTree

const SAMPLES := 120
const CONTACT_H := 0.06     # foot below this height (× hip height) = planted
const FOOT_BONES := ["LeftFoot", "RightFoot"]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var scene: Node = (load(args[0]) as PackedScene).instantiate()
	root.add_child(scene)
	var ap: AnimationPlayer = scene.find_child("AnimationPlayer")
	var skel: Skeleton3D = scene.find_child("Skeleton3D")
	var clip: Animation = ap.get_animation(args[1])
	var hips := skel.find_bone("Hips")
	var feet: Array[int] = []
	for f in FOOT_BONES: feet.append(skel.find_bone(f))

	# ---- sample ----
	var foot_pos: Array = [[], []]      # world-ish (skeleton space) per foot
	var hip_y: Array[float] = []
	ap.play(args[1])
	for i in SAMPLES:
		ap.seek(clip.length * float(i) / SAMPLES, true)   # true = update immediately
		skel.force_update_all_bone_transforms()
		for f in feet.size():
			foot_pos[f].append(skel.get_bone_global_pose(feet[f]).origin)
		hip_y.append(skel.get_bone_global_pose(hips).origin.y)

	# ---- contact detection ----
	var hip_h: float = hip_y.reduce(func(a, b): return a + b) / SAMPLES
	var planted: Array = [[], []]
	for f in 2:
		for i in SAMPLES:
			planted[f].append(foot_pos[f][i].y < hip_h * CONTACT_H + _min_y(foot_pos[f]))
	var duty: float = (_count_true(planted[0]) + _count_true(planted[1])) / float(2 * SAMPLES)
	# phase offset between feet = circular offset of contact-start indices
	var off := absf(_first_rise(planted[1]) - _first_rise(planted[0])) / float(SAMPLES)

	# ---- swing arc / reach curves (average both feet's swing windows) ----
	var style := GaitStyle.new()
	style.cycle_time = clip.length
	style.duty_factor = duty
	style.phase_offsets = [0.0, off]
	style.swing_arc = _fit_swing_curve(foot_pos, planted, true, hip_h)
	style.swing_reach = _fit_swing_curve(foot_pos, planted, false, hip_h)
	style.bob = _fit_cycle_curve(hip_y, hip_h)
	style.bob_amp = _amplitude(hip_y)
	# stride: horizontal travel of a foot during one contact (world-planted ⇒ root travels it)
	style.stride_norm = _stride(foot_pos[0], planted[0]) / _leg_length(skel)
	style.reference_speed = style.stride_norm * _leg_length(skel) / (clip.length * duty)
	ResourceSaver.save(style, args[2])
	print("baked ", args[2], "  duty=", duty, " cycle=", clip.length)
	quit(0)

# _min_y/_count_true/_first_rise/_fit_swing_curve/_fit_cycle_curve/_amplitude/
# _stride/_leg_length: straightforward array helpers — implement alongside.
```

Implementation notes for the agent:
- `seek(t, true)` + `force_update_all_bone_transforms()` is the reliable headless sampling pattern; verify the first sampled hip height is nonzero before trusting the run.
- Curve fitting = `Curve.new()` with ~12 evenly spaced `add_point` samples of the averaged normalized window.
- Bake walk, run, and sprint clips separately; the controller blends between two styles by normalized speed.

### 12.4 GaitController deltas (Mode B)

Replace the hardcoded feel with style lookups — the state machine, raycasts, phase-group rule, and priority ordering all stay exactly as validated:

```gdscript
@export var style: GaitStyle            # null ⇒ built-in heuristic constants (fallback)
@export var style_fast: GaitStyle       # optional run style for speed blending

# in the stepper, replacing sin/smoothstep swing:
var t: float = s.swing_t
var reach_t: float = style.swing_reach.sample(t) if style else smoothstep(0.0, 1.0, t)
var p: Vector3 = s.from.lerp(s.to, reach_t)
var arc: float = style.swing_arc.sample(t) if style else sin(PI * t)
p.y += arc * step_h

# timing/trigger derived from the clip instead of DNA constants:
var cycle := style.cycle_time * (dna.move_speed / style.reference_speed) if style else 0.0
var step_time := style.step_time() if style else dna.step_time
var step_trig := style.step_trigger(leg_len) if style else rig.stand_h * dna.step_trigger_f

# body bob sampled from the clip's hip curve, phase-locked to the cycle clock:
var bob := style.bob.sample(fposmod(_time / cycle, 1.0)) * style.bob_amp * scale if style else <old sine>
```

Morphology transfer: for quadrupeds/hexapods keep the existing group assignment and apply `style.phase_offsets[group % offsets.size()]` as each group's cycle offset — human walk style yields trot-like quadrupeds; bake a Synty run for gallop-flavored timing.

### 12.5 Optional: motion-warped swings (humanoid, highest fidelity)

For HUMANOID creatures, instead of curves, store the clip's full foot swing trajectory (local to hip, normalized) in the style; at runtime warp it: rotate/scale the stored trajectory so its start matches the lift point and its end matches the raycast foothold, then feed the warped points to the IK target. This preserves Synty's exact heel-strike character on arbitrary terrain. Recommended only after Mode B ships — it's polish, not foundation.

### 12.6 Fallback chain (keep it)

`style resource present → Mode B  |  absent → heuristic constants (validated defaults)`. The creature system must never hard-depend on Synty data — same principle as the native forge fallback.
