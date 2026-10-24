extends SceneTree

## The motion sets (Docs/ModularParts.md section 8, stage 8), headless.
##
##     godot --headless --path . --script res://tools/motion_probe.gd
##
##   pick       a mech's walk by its class (light and normal stride, heavy stomps); a pick it
##              satisfies wins, one it does not is passed over; no legs, no walk; a gun's
##              reload by whether its magazine comes off; animals of 1 to 10 legs walk, 11
##              do not; a pod's arm by its kind
##   stride     the feet keep pace with the ground at every leg length (no skid); longer legs
##              step slower at the same speed; standing, the legs hang straight; left against
##              right
##   mech       a dressed mech walks by its set, a design's pick taken; a pod arm swings and
##              settles; a stand-in for a pod on a mech with no pod part

const DIR := "user://_probe_motion/"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("motion probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	_pick()
	_stride()
	await _mech()
	_wipe(DIR)
	print("motion probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _pick() -> void:
	print("pick")
	var legs := {"paths": ["neck", "arm_L", "arm_R", "leg_L", "leg_R"]}
	_ok("a light mech strides", MotionSets.best("mech", ["walk", "light"], legs) == "mech.walk.stride")
	_ok("a normal one too", MotionSets.best("mech", ["walk", "normal"], legs) == "mech.walk.stride")
	_ok("a heavy one stomps", MotionSets.best("mech", ["walk", "heavy"], legs) == "mech.walk.stomp")
	_ok("a pick it satisfies wins", MotionSets.best("mech", ["walk", "light"], legs, "mech.walk.stomp") == "mech.walk.stomp")
	_ok("a pick for another body is passed over", MotionSets.best("mech", ["walk", "light"], legs, "pod.arm.strike")
			== "mech.walk.stride")
	_ok("no legs: no walk", MotionSets.best("mech", ["walk"], {"paths": ["neck"]}) == "")
	_ok("a magazine that comes off: the magazine reload", MotionSets.best("gun", ["reload", "reload.mag"],
			{"paths": ["barrel", "magazine"]}) == "gun.reload.mag")
	_ok("none: the plain reload", MotionSets.best("gun", ["reload", "reload.mag"], {"paths": ["barrel"]})
			== "gun.reload.fixed")
	var walks := true
	for n in range(1, 11):
		walks = walks and MotionSets.best("creature", ["walk", "near"], {"legs": n}) == "creature.gait"
	_ok("animals of 1 to 10 legs walk", walks)
	_ok("11 legs: no set does", MotionSets.best("creature", ["walk"], {"legs": 11}) == "")
	_ok("far off, the cheap gait", MotionSets.best("creature", ["walk", "far"], {"legs": 4}) == "creature.gait.far")
	_ok("a strike arm's pod swings as a strike", MotionSets.best("pod", ["pod.arm", "melee_arm"], {}) == "pod.arm.strike")
	_ok("a grenade arm's as a throw", MotionSets.best("pod", ["pod.arm", "grenade_arm"], {}) == "pod.arm.throw")
	_ok("a set run elsewhere makes no mover", MotionSets.make("gun.reload.mag") == null)


func _stride() -> void:
	print("stride")
	var cad := {}
	var no_skid := true
	for length in [1, 2, 3, 6]:
		var s := MotionSets.make("mech.walk.stride") as MechStride
		s.hip_height = MechAssembler.hip_bricks(length) * 3 * MechAssembler.NANO_PLATE_M
		for v in [1.0, 4.0, 9.0, 12.0]:
			s.step(0.016, v)
			no_skid = no_skid and is_equal_approx(s.foot_speed(), v)
		s.step(0.016, 4.0)
		cad[length] = s.cadence
		s.free()
	_ok("the feet keep pace with the ground, legs 1, 2, 3 and a boss's 6 long", no_skid)
	_ok("longer legs step slower at the same speed", cad[1] > cad[2] and cad[2] > cad[3] and cad[3] > cad[6], str(cad))
	var st := MotionSets.make("mech.walk.stride") as MechStride
	var l := Node3D.new()
	var r := Node3D.new()
	st.hips = [l, r]
	for i in 20:
		st.step(0.05, 6.0)
	_ok("left against right", is_equal_approx(l.rotation.x, -r.rotation.x) and absf(l.rotation.x) > 0.0)
	for i in 3:
		st.step(0.05, 0.0)
	_ok("standing: the legs hang straight", is_zero_approx(l.rotation.x) and is_zero_approx(r.rotation.x))
	var stomp := MotionSets.make("mech.walk.stomp") as MechStride
	stomp.step(0.016, 9.0)
	st.step(0.016, 9.0)
	_ok("a stomp swings shorter", absf(stomp.swing_max) < absf(st.swing_max))
	for n in [st, stomp, l, r]:
		n.free()


func _part(d: Dictionary, sockets: Dictionary = {}) -> PartRecord:
	var socks := []
	for k in sockets:
		socks.append({"name": k, "accepts": [sockets[k][0]]})
	d["sockets"] = socks
	d["source"] = "official"
	var rec := PartRecord.from_dict(d)
	rec.dir = DIR + rec.id + "/"
	DirAccess.make_dir_recursive_absolute(rec.dir)
	var node := Node3D.new()
	node.name = rec.slot
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	node.add_child(box)
	box.owner = node
	for k in sockets:
		var s := Node3D.new()
		s.name = "socket_" + k
		s.position = sockets[k][1]
		node.add_child(s)
		s.owner = node
	var ps := PackedScene.new()
	ps.pack(node)
	node.free()
	ResourceSaver.save(ps, rec.dir + "part.scn")
	return rec


func _mech() -> void:
	print("mech")
	var cat := PartCatalog.new()
	for rec in [
		_part({"id": "ch_h", "family": "mech", "slot": "chassis", "class": "heavy"}, {
			"neck": ["mech.neck", Vector3(0, 1.3, 0)], "arm_L": ["mech.shoulder", Vector3(-1.9, 0.4, 0)],
			"arm_R": ["mech.shoulder", Vector3(1.9, 0.4, 0)], "leg_L": ["mech.hip", Vector3(-0.9, 0, 0)],
			"leg_R": ["mech.hip", Vector3(0.9, 0, 0)]}),
		_part({"id": "head", "family": "mech", "slot": "head", "mount": {"interface": "mech.neck"}}),
		_part({"id": "arm", "family": "mech", "slot": "arm", "side": "any", "mount": {"interface": "mech.shoulder"}},
				{"hand": ["mech.wrist", Vector3(0, -1.7, -0.3)]}),
		_part({"id": "hand", "family": "mech", "slot": "hand", "mount": {"interface": "mech.wrist"}}),
		_part({"id": "leg", "family": "mech", "slot": "leg", "side": "any",
				"mount": {"interface": "mech.hip", "params": {"length": 3}}}),
	]:
		cat.add(rec)
	var m := Mech.spawn(root, Vector3.ZERO, 0.0, 0)
	var b := PartBuilder.generate("mech", null, 1, cat)
	_ok("a heavy mech", (b.problems as Array).is_empty(), str(b.problems))
	MechAssembler.dress(m, b)
	var walk := m.body.get_node_or_null(^"MotionWalk") as MechStride
	_ok("dressed, it walks by its class's set", walk != null and walk.set_id == "mech.walk.stomp"
			and walk.hips.size() == 2)
	_ok("its legs as long as its parts'", walk != null and is_equal_approx(walk.hip_height, 4.2), str(walk.hip_height if walk else 0))
	var d := PartDesign.from_dict({"id": "s", "plan": "mech", "slots": {}, "motion": {"walk": "mech.walk.stride"}})
	var b2 := PartBuilder.generate("mech", d, 1, cat)
	MechAssembler.dress(m, b2)
	await process_frame
	walk = m.body.get_node_or_null(^"MotionWalk") as MechStride
	_ok("a design's pick taken, the old walk gone", walk != null and walk.set_id == "mech.walk.stride"
			and m.body.get_children().filter(func(c: Node) -> bool: return c is MechStride).size() == 1)

	print("pod arm")
	var g := Mech.spawn(root, Vector3(40, 0, 0), 0.0, 0)
	var pods := MechPods.attach(g)
	pods.fit(0, PodGenerator.generate(3, 2, 1, &"melee_arm"))
	var stand := g.torso.get_node_or_null(^"PodStandIn_L") as Node3D
	_ok("a pod on a mech with no pod part: a stand-in on the torso", stand != null)
	var arm := pods._arms[0] as PodArmMotion
	_ok("its arm: the strike set, on the stand-in", arm != null and arm.set_id == "pod.arm.strike" and arm.target == stand)
	pods.fit(1, PodGenerator.generate(3, 2, 1, &"shield_boost"))
	_ok("a passive has no arm", pods._arms[1] == null and g.torso.get_node_or_null(^"PodStandIn_R") != null)
	arm.play()
	var peak := 0.0
	for i in 30:
		await physics_frame
		peak = maxf(peak, absf(stand.rotation.x))
	_ok("used, it swings", peak > 0.5, str(peak))
	for i in 60:
		await physics_frame
	_ok("and settles at rest", not arm.playing() and is_zero_approx(stand.rotation.x))
	pods.take_off(0)
	await process_frame
	_ok("taken off: its stand-in and arm go", g.torso.get_node_or_null(^"PodStandIn_L") == null and pods._arms[0] == null)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
