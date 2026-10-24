extends SceneTree

## Mechs from parts in the game (Docs/ModularParts.md stage 6), headless.
##
##     godot --headless --path . --script res://tools/mech_parts_probe.gd
##
##   roll       nothing to roll from: no build, with why; a whole mech from a catalogue, every
##              part fitting, both legs one length (even when the left and right legs on offer
##              share one length only), the same mech from the same seed, a heavy chassis when
##              asked; custom parts never in the pools unless asked
##   designs    a fixed slot is kept; a pool narrows a slot; an empty optional slot stays
##              empty; a fixed part that does not fit makes no mech; John (a figure): his
##              body fixed, his hat rolled
##   assemble   every part on its host's socket, the hand on the arm's
##   dress      a mech's boxes give way to its parts: legs on the legs, the gun arm posed
##              forward, the chassis's class its layers, the eye on long legs higher; a
##              build with problems leaves the boxes

const DIR := "user://_probe_mech_parts/"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("mech parts probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	_wipe(DIR)
	_roll()
	_designs()
	await _assemble_and_dress()
	_wipe(DIR)
	print("mech parts probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# --- parts --------------------------------------------------------------------

## A part with a scene: a box, and a socket node per `sockets` entry {name: [iface, pos]}.
func _part(d: Dictionary, sockets: Dictionary = {}) -> PartRecord:
	var socks := []
	for k in sockets:
		socks.append({"name": k, "accepts": [sockets[k][0]]})
	d["sockets"] = socks
	if not d.has("source"):
		d["source"] = "official"
	var r := PartRecord.from_dict(d)
	r.dir = DIR + r.id + "/"
	DirAccess.make_dir_recursive_absolute(r.dir)
	var node := Node3D.new()
	node.name = r.slot
	var box := MeshInstance3D.new()
	box.name = "Model"
	box.mesh = BoxMesh.new()
	node.add_child(box)
	box.owner = node
	if d.has("mount"):
		var m := Node3D.new()
		m.name = "mount"
		node.add_child(m)
		m.owner = node
	for k in sockets:
		var s := Node3D.new()
		s.name = "socket_" + k
		s.position = sockets[k][1]
		node.add_child(s)
		s.owner = node
	var ps := PackedScene.new()
	ps.pack(node)
	node.free()
	ResourceSaver.save(ps, r.dir + "part.scn")
	return r


func _chassis(id: String, klass: String, maker := "korr", source := "official") -> PartRecord:
	var d := {"id": id, "family": "mech", "slot": "chassis", "class": klass, "manufacturer": maker,
			"source": source}
	if source == "custom":
		d["creator"] = {"name": "Lu"}
	return _part(d, {"neck": ["mech.neck", Vector3(0, 1.3, 0)],
			"arm_L": ["mech.shoulder", Vector3(-1.9, 0.4, 0)], "arm_R": ["mech.shoulder", Vector3(1.9, 0.4, 0)],
			"leg_L": ["mech.hip", Vector3(-0.9, 0, 0)], "leg_R": ["mech.hip", Vector3(0.9, 0, 0)],
			"pod_L": ["mech.pod", Vector3(-1.2, 1.3, 0.5)], "pod_R": ["mech.pod", Vector3(1.2, 1.3, 0.5)]})


func _limb(id: String, slot: String, side: String, iface: String, maker := "korr", params := {},
		sockets := {}) -> PartRecord:
	return _part({"id": id, "family": "pod" if slot == "pod" else "mech", "slot": slot, "side": side,
			"manufacturer": maker, "mount": {"interface": iface, "params": params}}, sockets)


func _catalog() -> PartCatalog:
	var cat := PartCatalog.new()
	for r in [
		_chassis("korr_chassis_l", "light"), _chassis("vex_chassis_h", "heavy", "vex"),
		_chassis("lu.chassis", "normal", "workshop", "custom"),
		_limb("korr_head", "head", "any", "mech.neck"),
		_limb("korr_arm_L", "arm", "L", "mech.shoulder", "korr", {}, {"hand": ["mech.wrist", Vector3(0, -1.7, -0.35)]}),
		_limb("vex_arm_L", "arm", "L", "mech.shoulder", "vex", {}, {"hand": ["mech.wrist", Vector3(0, -1.7, -0.35)]}),
		_limb("korr_arm_R", "arm", "R", "mech.shoulder", "korr", {}, {"hand": ["mech.wrist", Vector3(0, -1.7, -0.35)]}),
		_limb("hand_fist", "hand", "any", "mech.wrist"),
		# Left legs 1 and 2 long, right legs 2 and 3: only 2 is both's.
		_limb("leg_L1", "leg", "L", "mech.hip", "korr", {"length": 1}),
		_limb("leg_L2", "leg", "L", "mech.hip", "korr", {"length": 2}),
		_limb("leg_R2", "leg", "R", "mech.hip", "korr", {"length": 2}),
		_limb("leg_R3", "leg", "R", "mech.hip", "korr", {"length": 3}),
		_limb("pod_missiles", "pod", "any", "mech.pod"),
	]:
		_ok("fixture %s" % r.id, cat.add(r), "; ".join(r.problems()))
	return cat


func _ids(b: Dictionary) -> String:
	var bits := PackedStringArray([(b.root as PartRecord).id if b.root != null else "-"])
	var paths: Array = (b.at as Dictionary).keys()
	paths.sort()
	for p in paths:
		bits.append("%s=%s" % [p, b.at[p].id])
	return " ".join(bits)


# --- the checks -----------------------------------------------------------------

func _roll() -> void:
	print("roll")
	var none := PartBuilder.generate("mech", null, 1, PartCatalog.new())
	_ok("nothing to roll from: no mech, and why", none.root == null and not (none.problems as Array).is_empty(),
			str(none.problems))
	var cat := _catalog()
	var b := PartBuilder.generate("mech", null, 1, cat)
	_ok("a whole mech", (b.problems as Array).is_empty() and (b.at as Dictionary).size() == 9,
			"%s %s" % [b.problems, _ids(b)])
	var again := PartBuilder.generate("mech", null, 1, cat)
	_ok("the same seed, the same mech", _ids(again) == _ids(b))
	var all_ok := true
	var heavy_ok := true
	var custom_seen := false
	var builds := {}
	for s in 60:
		var r := PartBuilder.generate("mech", null, s, cat)
		builds[_ids(r)] = true
		var legs_two: bool = r.at.has("leg_L") and int(r.at.leg_L.param("length")) == 2 \
				and int(r.at.leg_R.param("length")) == 2
		all_ok = all_ok and (r.problems as Array).is_empty() and legs_two
		custom_seen = custom_seen or (r.root as PartRecord).is_custom()
		var h := PartBuilder.generate("mech", null, s, cat, {"class": "heavy"})
		heavy_ok = heavy_ok and h.root != null and h.root.weight_class == "heavy"
	_ok("60 seeds: every one whole, its legs both 2 long (the one length both sides have)", all_ok)
	_ok("and not all alike", builds.size() > 3, str(builds.size()))
	_ok("asked for heavy: a heavy chassis every time", heavy_ok)
	_ok("custom parts never in the pools", not custom_seen)
	var any_custom := false
	for s in 40:
		any_custom = any_custom or (PartBuilder.generate("mech", null, s, cat, {"custom": true}).root as PartRecord).is_custom()
	_ok("unless asked", any_custom)


func _designs() -> void:
	print("designs")
	var cat := _catalog()
	var d := PartDesign.from_dict({"id": "vex_line", "plan": "mech", "slots": {
		"root": {"fixed": "vex_chassis_h"}, "arm_L": {"pool": {"manufacturer": ["vex"]}},
		"pod_L": {"empty": true}}})
	var kept := true
	for s in 20:
		var b := PartBuilder.generate("mech", d, s, cat)
		kept = kept and (b.problems as Array).is_empty() and b.root.id == "vex_chassis_h" \
				and b.at.arm_L.id == "vex_arm_L" and not b.at.has("pod_L") and b.at.has("pod_R")
	_ok("fixed root kept, the pool narrowed, the empty pod left empty", kept)
	var bad := PartDesign.from_dict({"id": "bad", "plan": "mech", "slots": {"arm_L": {"fixed": "korr_arm_R"}}})
	var bb := PartBuilder.generate("mech", bad, 1, cat)
	_ok("a fixed part that does not fit: problems, so no mech", not (bb.problems as Array).is_empty()
			and str(bb.problems).contains("korr_arm_R does not fit"), str(bb.problems))
	var odd := PartDesign.from_dict({"id": "odd", "plan": "mech", "slots": {"leg_L": {"fixed": "leg_L1"}}})
	var ob := PartBuilder.generate("mech", odd, 1, cat)
	_ok("a fixed leg 1 long: no right leg that long, so no mech", not (ob.problems as Array).is_empty(), str(ob.problems))
	var file := DIR + "designs/vex_line.json"
	d.save_file(file)
	var loaded := PartDesign.load_all([DIR + "designs/"])
	_ok("a design file round trip", loaded.has("vex_line")
			and (loaded.vex_line as PartDesign).slots == d.slots)

	# John: a figure whose body is fixed and whose hat is rolled.
	var fc := PartCatalog.new()
	for r in [
		_part({"id": "john_torso", "family": "figure", "slot": "torso"}, {"neck": ["fig.neck", Vector3.UP],
				"arm_L": ["fig.shoulder", Vector3.LEFT], "arm_R": ["fig.shoulder", Vector3.RIGHT],
				"leg_L": ["fig.hip", Vector3.DOWN], "leg_R": ["fig.hip", Vector3.DOWN]}),
		_part({"id": "john_head", "family": "figure", "slot": "head", "mount": {"interface": "fig.neck"}},
				{"hat": ["fig.hat", Vector3.UP]}),
		_part({"id": "plain_head", "family": "figure", "slot": "head", "mount": {"interface": "fig.neck"}}),
		_part({"id": "fig_arm", "family": "figure", "slot": "arm", "side": "any", "mount": {"interface": "fig.shoulder"}},
				{"hand": ["fig.wrist", Vector3.DOWN]}),
		_part({"id": "fig_hand", "family": "figure", "slot": "hand", "mount": {"interface": "fig.wrist"}}),
		_part({"id": "fig_leg", "family": "figure", "slot": "leg", "mount": {"interface": "fig.hip"}}),
		_part({"id": "hat_cap", "family": "figure", "slot": "hat", "tags": ["hat"], "mount": {"interface": "fig.hat"}}),
		_part({"id": "hat_top", "family": "figure", "slot": "hat", "tags": ["hat"], "mount": {"interface": "fig.hat"}}),
	]:
		fc.add(r)
	var john := PartDesign.from_dict({"id": "john", "plan": "figure", "slots": {
		"root": {"fixed": "john_torso"}, "neck": {"fixed": "john_head"}, "neck/hat": {"pool": {"tags": ["hat"]}}}})
	var hats := {}
	var same_body := true
	for s in 30:
		var b := PartBuilder.generate("figure", john, s, fc)
		same_body = same_body and (b.problems as Array).is_empty() and b.root.id == "john_torso" \
				and b.at.neck.id == "john_head"
		if b.at.has("neck/hat"):
			hats[b.at["neck/hat"].id] = true
	_ok("John: always his body and head", same_body)
	_ok("his hat rolled: both hats seen", hats.size() == 2, str(hats.keys()))


func _assemble_and_dress() -> void:
	print("assemble")
	var cat := _catalog()
	var b := PartBuilder.generate("mech", PartDesign.from_dict({"id": "x", "plan": "mech", "slots": {
		"root": {"fixed": "vex_chassis_h"}, "leg_L": {"fixed": "leg_L2"}}}), 3, cat)
	var model := MechAssembler.assemble(b)
	var joints: Dictionary = model.get_meta(&"joints", {}) if model != null else {}
	_ok("every part on a joint", model != null and joints.size() == 9, str(joints.keys()))
	_ok("the right arm on the chassis's right shoulder", joints.has("arm_R")
			and (joints.arm_R as Node3D).position.is_equal_approx(Vector3(1.9, 0.4, 0)))
	_ok("the hand on the arm's wrist", joints.has("arm_R/hand")
			and (joints["arm_R/hand"] as Node3D).position.is_equal_approx(Vector3(1.9, 0.4, 0) + Vector3(0, -1.7, -0.35)))
	_ok("hips 16 nano bricks up for legs 2 long", is_equal_approx(MechAssembler.hip_height(b), 3.36))
	model.free()

	print("dress")
	var m := Mech.spawn(root, Vector3.ZERO, 0.0, 0)
	var boxes_before := m.legs.get_child_count()
	var broken := {"root": b.root, "at": b.at, "problems": PackedStringArray(["x: nothing fits"])}
	_ok("a build with problems: the boxes stay", not MechAssembler.dress(m, broken)
			and m.legs.get_child_count() == boxes_before)
	var long := PartBuilder.generate("mech", PartDesign.from_dict({"id": "y", "plan": "mech", "slots": {
		"root": {"fixed": "vex_chassis_h"}, "leg_R": {"fixed": "leg_R3"}}}), 3, cat)
	_ok("a right leg 3 long does not roll: no left leg that long", not (long.problems as Array).is_empty())
	_ok("dressed", MechAssembler.dress(m, b, true))
	await process_frame
	var boxes := 0
	for n: Node3D in [m.legs, m.torso, m.arm]:
		for c in n.find_children("*", "MeshInstance3D", true, false):
			if (c as MeshInstance3D).mesh is BoxMesh and not c.get_parent().name.begins_with("Joint") \
					and c.get_parent() != m.torso.get_node_or_null(^"Chassis") \
					and not _in_part(c):
				boxes += 1
	_ok("the boxes are gone", boxes == 0, str(boxes))
	_ok("the legs on the legs", m.legs.get_node_or_null(^"Joint_leg_L") != null
			and m.legs.get_node_or_null(^"Joint_leg_R") != null)
	_ok("the gun arm and its hand on the arm", m.arm.get_node_or_null(^"Pose/Joint_arm_R") != null
			and m.arm.get_node_or_null(^"Pose/Joint_arm_R_hand") != null)
	var pose := m.arm.get_node(^"Pose") as Node3D
	var wrist := pose.transform * (m.arm.get_node(^"Pose/Joint_arm_R_hand") as Node3D).position
	_ok("posed forward: the wrist ahead of the shoulder", wrist.z < -1.0 and absf(wrist.x) < 0.01 and absf(wrist.y) < 0.01,
			str(wrist))
	_ok("the muzzle beyond the wrist", m.muzzle.position.z < wrist.z, str(m.muzzle.position))
	_ok("the shoulder where the chassis has it, over the hips", m.shoulder.is_equal_approx(Vector3(1.9, 3.36 + 0.4, 0)),
			str(m.shoulder))
	_ok("the chassis's class its layers: heavy, 600 shield, 2400 armour", m.layers.hatch_side == "front"
			and is_equal_approx(m.health.layer_configs[0].max_value, 600.0) and is_equal_approx(m.health.layer_configs[1].max_value, 2400.0),
			"%s %s" % [m.health.layer_configs[0].max_value, m.health.layer_configs[1].max_value])
	_ok("the eye as the greybox's, legs 2 long", is_equal_approx(m.cockpit_y, Mech.COCKPIT_Y))
	var m2 := Mech.spawn(root, Vector3(30, 0, 0), 0.0, 0)
	var tall := PartBuilder.generate("mech", PartDesign.from_dict({"id": "z", "plan": "mech", "slots": {
		"root": {"fixed": "korr_chassis_l"}, "leg_R": {"fixed": "leg_R3"}, "leg_L": {"fixed": "leg_L2"}}}), 3, cat)
	_ok("mismatched fixed legs: no mech", not (tall.problems as Array).is_empty())
	var light := PartBuilder.generate("mech", PartDesign.from_dict({"id": "w", "plan": "mech", "slots": {
		"root": {"fixed": "korr_chassis_l"}}}), 3, cat)
	MechAssembler.dress(m2, light, true)
	_ok("a light chassis: its hatch at the back", m2.layers.hatch_side == "back")


func _in_part(n: Node) -> bool:
	var c := n.get_parent()
	while c != null:
		if c.has_meta(&"part_id"):
			return true
		c = c.get_parent()
	return false


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
