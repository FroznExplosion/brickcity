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
## `split := true` also emits a Target/Puppet split for the physics layer (gait_physics_merge):
## the built skeleton stays the kinematic TARGET (gait + IK run on it, its mesh hidden); a bones-only
## PUPPET skeleton is added and the visible mesh re-skinned onto it. Adds rig.target/puppet/puppet_mesh.
static func build(dna: CreatureDNA, root: Node3D, split := false) -> Dictionary:
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

	var rig := {
		"skeleton": skel, "mesh_instance": mi, "targets": targets,
		"ik": ik, "look": look, "spring": spring, "look_target": look_target,
		"legs": legs, "body": body_i, "head": head_i,
		"spine": spine_i, "tail": tail_i,
		"stand_h": stand_h, "head_local": head_j,
		"body_rest_pos": Vector3(0, stand_h, 0),
	}
	if split:
		split_rig(rig, root)
	return rig

## Emit a Target/Puppet split on an already-built rig (see build(split:=true)). Canonical location —
## gait_physics_merge/CreatureSplit delegates here. TARGET = rig.skeleton (gait/IK keep posing it,
## mesh hidden); PUPPET = a bones-only duplicate under `parent` with the visible mesh re-skinned onto
## it. Bone order is identical, so the same skin is valid. Adds rig.target/puppet/puppet_mesh; returns rig.
static func split_rig(rig: Dictionary, parent: Node) -> Dictionary:
	var target: Skeleton3D = rig.skeleton
	var puppet := Skeleton3D.new()
	puppet.name = "Puppet"
	# Parents are always lower-indexed here (parent bone added before child), so a 0..N copy is safe.
	for i in target.get_bone_count():
		puppet.add_bone(target.get_bone_name(i))
		puppet.set_bone_parent(i, target.get_bone_parent(i))
		puppet.set_bone_rest(i, target.get_bone_rest(i))
	puppet.reset_bone_poses()
	parent.add_child(puppet)
	puppet.transform = target.transform                        # same placement ⇒ world poses line up

	var tgt_mi: MeshInstance3D = rig.mesh_instance
	var pup_mi := MeshInstance3D.new()
	pup_mi.name = "PuppetMesh"
	pup_mi.mesh = tgt_mi.mesh                                   # share the ArrayMesh
	puppet.add_child(pup_mi)
	pup_mi.skeleton = pup_mi.get_path_to(puppet)               # ".."
	pup_mi.skin = puppet.create_skin_from_rest_transforms()    # identical bone order ⇒ valid
	tgt_mi.visible = false                                      # target is kinematic-only now

	rig["target"] = target
	rig["puppet"] = puppet
	rig["puppet_mesh"] = pup_mi
	return rig

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
