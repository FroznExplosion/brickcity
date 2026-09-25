extends SceneTree
## Headless smoke test. Run AFTER an import pass:
##   godot --headless --path . --import
##   godot --headless --path . --script tools/creature_probe.gd
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

	var DNA = load("res://scripts/creatures/creature_dna.gd")
	var PC = load("res://scripts/creatures/proc_creature.gd")

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
	var PML = load("res://scripts/creatures/part_mesh_lib.gd")
	if PML.native_available():
		var CB = load("res://scripts/creatures/creature_builder.gd")
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
