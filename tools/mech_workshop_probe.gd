extends SceneTree

## The asset workshop's mech mode (Docs/ModularParts.md section 9, stage 5), headless.
##
##     godot --headless --path . --script res://tools/mech_workshop_probe.gd
##
##   mode        Make a mech: a mech's ten parts, the reference mech, every joint's mount
##               and socket laid ready; the point panel offers the mech's sockets
##   class       another class or leg length moves the ready points and the reference;
##               a point put by hand stays; J on a ready joint takes the current part's
##   save        every part on its own: family, slot, side, class, mount, a leg's length,
##               what the sockets take; scenes with their mount and sockets; together
##               they make a whole mech by the body plan; saved again, nothing written
##   try on      a mech part goes on its slot and side; a gun part does not; legs of two
##               lengths are marked; a tried chassis brings its sockets
##   catalogue   Fits aims at the socket of the part being built, on the mech plan
##   back        Make a gun: the gun's parts again, no reference

const DIR := "user://_probe_mech/"

var _pass := 0
var _fail := 0
var _ws
var _frames := 0
var _arch := ""


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tick() -> void:
	_frames += 1
	if _frames != 2:
		return
	_ws.set_process(false)
	_ws._hotbar.save_path = "user://_probe_mech_hotbar.json"
	_ws.toolbars_save = "user://_probe_mech_toolbars.json"
	for yaw in 2:
		var n := BrickPalette.variant_name("brick_1x4", yaw, false)
		if BrickPalette.size_of(n).x == 4:
			_arch = n
	_wipe(DIR)
	print("mech workshop probe")
	_mode()
	_save()
	_try_on()
	_back()
	_ws._builds_dir = BuildRecipe.player_dir()
	_wipe(DIR)
	print("mech workshop probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ready_points(part: String, kind: String) -> Array:
	return _ws.points.filter(func(q: Dictionary) -> bool:
		return q.get("ready", false) and q.part == part and q.kind == kind)


func _at(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func _mode() -> void:
	print("mode")
	_ws._new_build()
	_ws.set_asset_kind("mech")
	_ok("a mech's ten parts", Array(_ws.part_names) == MechReference.PARTS, str(_ws.part_names))
	_ok("nine joints laid ready, a mount and a socket each", _ws.points.size() == 18, str(_ws.points.size()))
	var mount: Array = _ready_points("arm_L", "mount")
	var sock: Array = _ws.points.filter(func(q: Dictionary) -> bool:
		return q.part == "chassis" and q.kind == "socket" and q.slot == "arm_L")
	_ok("the left arm mounts on mech.shoulder at its joint, the chassis's socket there takes it",
			mount.size() == 1 and mount[0].interface == "mech.shoulder" and mount[0].at == _at(_ws.mech_joint("arm_L"))
			and sock.size() == 1 and sock[0].at == mount[0].at and sock[0].interface == "mech.shoulder")
	var hand_sock: Array = _ws.points.filter(func(q: Dictionary) -> bool:
		return q.part == "arm_L" and q.kind == "socket")
	_ok("the arm's wrist takes the hand", hand_sock.size() == 1 and hand_sock[0].slot == "hand"
			and hand_sock[0].interface == "mech.wrist")
	_ok("the left is +Z, across the mirror", _ws.mech_joint("arm_L").z > _ws.mirror_z
			and _ws.mech_joint("arm_R").z < _ws.mirror_z
			and is_equal_approx(_ws.mech_joint("arm_L").z - _ws.mirror_z, _ws.mirror_z - _ws.mech_joint("arm_R").z))
	var ref: Node3D = _ws._mech_ref
	_ok("the reference mech is drawn, a label on each joint", ref != null
			and ref.get_node_or_null("Joint_arm_L") != null
			and (ref.get_node("Joint_arm_L") as Node3D).position.is_equal_approx(_ws.mech_joint_m("arm_L") + Vector3.UP * 0.25))
	_ok("the status line says mech, class and legs", _ws.ruler_text().contains("MECH normal, legs 2 long"))
	var slots := []
	for i in _ws._point_slot.item_count:
		slots.append(_ws._point_slot.get_item_text(i))
	_ok("the point panel offers the mech's sockets", slots == ["neck", "arm_L", "arm_R", "hand", "leg_L", "leg_R",
			"pod_L", "pod_R"], str(slots))
	_ws._point_slot.select(slots.find("leg_L"))
	_ws._fill_point_ifaces()
	_ok("and a hip's interface for a leg", _ws._point_iface.item_count == 1
			and _ws._point_iface.get_item_text(0) == "mech.hip")

	print("class")
	var light_arm: Vector3 = _ws.mech_joint("arm_L")
	_ws.select_part(_ws.part_names.find("chassis"))
	_ws.toggle_point([1.0, 2.0, 3.0], "socket", "pod_L", "mech.pod")
	_ws.set_mech_class("heavy")
	_ws.set_leg_length(3)
	var arm: Array = _ready_points("arm_L", "mount")
	_ok("heavy: the shoulders further out", arm.size() == 1 and float(arm[0].at[2]) > light_arm.z, str(arm))
	var leg: Array = _ready_points("leg_L", "mount")
	_ok("legs 3 long: the hip 20 bricks up", leg.size() == 1
			and is_equal_approx(float(leg[0].at[1]), _ws.mech_origin().y + 60.0), str(leg))
	_ok("a point put by hand stays", _ws.points.any(func(q: Dictionary) -> bool: return q.at == [1.0, 2.0, 3.0]))
	_ok("still 18 ready", _ws.points.filter(func(q: Dictionary) -> bool: return q.get("ready", false)).size() == 18)
	_ws.toggle_point([1.0, 2.0, 3.0], "", "", "")
	_ws.select_part(_ws.part_names.find("arm_L"))
	var at: Array = _at(_ws.mech_joint("arm_L"))
	_ws.toggle_point(at, "", "", "")
	_ok("J on a joint takes the current part's point (the arm's mount), not the chassis's socket",
			_ready_points("arm_L", "mount").is_empty() and _ws.points.any(func(q: Dictionary) -> bool:
				return q.part == "chassis" and q.at == at))
	_ws.lay_ready_points()
	_ok("laid ready again", _ready_points("arm_L", "mount").size() == 1)


## A brick for each part at its joint: the chassis on the hips, the rest hanging off theirs.
func _build_mech() -> void:
	for part in MechReference.PARTS:
		_ws.select_part(_ws.part_names.find(part))
		var j: Vector3 = _ws.mech_joint(part)
		var c := Vector3i(int(j.x) - 2, int(j.y), int(floor(j.z)))
		if part.begins_with("leg") or part.begins_with("hand") or part.begins_with("arm"):
			c.y -= 3   # under the joint
		_ok("a brick for %s" % part, _ws.place_named(_arch, c), str(c))


func _save() -> void:
	print("save")
	_build_mech()
	_ws._builds_dir = DIR
	var path: String = _ws._save_as("Probe Mech")
	var parts_dir: String = _ws.parts_dir()
	var folders := Array(DirAccess.get_directories_at(parts_dir))
	_ok("ten parts, ten folders", path != "" and folders.size() == 10, str(folders))
	var cat := PartCatalog.new()
	var n := cat.load_dir(parts_dir, "custom")
	_ok("the catalogue takes all ten", n == 10, str(n))
	var by := {}
	for part in MechReference.PARTS:
		by[part] = cat.get_part(String(_ws.part_ids[part]))
	var arm: PartRecord = by.arm_L
	_ok("an arm: mech, arm, left, heavy, on mech.shoulder", arm != null and arm.family == "mech"
			and arm.slot == "arm" and arm.side == "L" and arm.weight_class == "heavy"
			and arm.interface() == "mech.shoulder")
	_ok("its wrist takes a hand", arm != null and arm.socket("hand").get("accepts") == ["mech.wrist"])
	_ok("a leg says its length", by.leg_R != null and int(by.leg_R.param("length")) == 3)
	_ok("a pod's body is a pod", by.pod_L != null and by.pod_L.family == "pod" and by.pod_L.interface() == "mech.pod")
	var ch: PartRecord = by.chassis
	_ok("the chassis takes every part", ch != null and ch.socket("neck").get("accepts") == ["mech.neck"]
			and ch.socket("leg_L").get("accepts") == ["mech.hip"] and ch.socket("pod_R").get("accepts") == ["mech.pod"]
			and ch.interface() == "")
	var build := {"root": ch, "at": {}}
	for part in MechReference.PARTS:
		if part != "chassis":
			build.at[MechReference.path_of(part)] = by[part]
	var bad := PartFit.problems(build, "mech")
	_ok("saved apart, they make a whole mech by the body plan", bad.is_empty(), "; ".join(bad))
	var ps := load(arm.dir + "part.scn") as PackedScene
	var scene := ps.instantiate() as Node3D if ps != null else null
	_ok("the arm's scene has its mount and its wrist socket", scene != null
			and scene.get_node_or_null("mount") != null and scene.get_node_or_null("socket_hand") != null)
	if scene != null:
		var wrist: Vector3 = (scene.get_node("socket_hand") as Node3D).position
		var want: Vector3 = _ws.mech_basis() * (_ws.mech_joint_m("hand_L") - _ws.mech_joint_m("arm_L"))
		_ok("the wrist where the reference has it, at game size", wrist.is_equal_approx(want), "%s vs %s" % [wrist, want])
		_ok("an arm 24 nano plates long is 1.68 m in the game", is_equal_approx(snappedf(-wrist.y, 0.001), 1.68),
				str(wrist.y))
		scene.free()
	var again: Dictionary = _ws.save_parts()
	_ok("saved again unchanged: nothing written", (again.written as Array).is_empty(), str(again))

	# Into the game (stage 6): the build's parts are a design, the design a mech.
	var made := MechAssembler.designs(cat)
	var d: PartDesign = made.get("probe_mech")
	_ok("the saved parts are a design by the build's name, every slot fixed", d != null
			and d.slots.size() == 10 and d.slots.root.fixed == _ws.part_ids.chassis, str(made.keys()))
	var b := PartBuilder.generate("mech", d, 1, cat)
	_ok("it rolls whole: every part its own", (b.problems as Array).is_empty() and b.at.size() == 9, str(b.problems))
	var m := Mech.spawn(root, Vector3(0, 0, 50), 0.0, 0)
	_ok("a mech in the game made of them", MechAssembler.dress(m, b, true)
			and m.legs.get_node_or_null(^"Joint_leg_L") != null and m.arm.get_node_or_null(^"Pose/Joint_arm_R") != null)
	_ok("heavy, as its chassis", is_equal_approx(m.health.layer_configs[1].max_value, 2400.0))
	_ok("legs 3 long: the eye higher than the greybox's", m.cockpit_y > Mech.COCKPIT_Y + 0.8, str(m.cockpit_y))
	var arm_j: Vector3 = _ws.mech_basis() * (_ws.mech_joint_m("arm_R") - _ws.mech_joint_m("chassis"))
	_ok("its right shoulder where the reference has it", m.shoulder.is_equal_approx(
			Vector3(arm_j.x, MechAssembler.hip_height(b) + arm_j.y, arm_j.z)), "%s vs %s" % [m.shoulder, arm_j])


func _try_part(id: String, slot: String, side: String, mount: String, params: Dictionary = {},
		sockets: Dictionary = {}) -> PartRecord:
	var d := {"id": id, "name": "Tried " + slot, "family": "mech", "slot": slot, "side": side,
			"class": "light", "source": "custom", "creator": {"name": "Lu"}, "manufacturer": "workshop"}
	if mount != "":
		d["mount"] = {"interface": mount, "params": params}
	var socks := []
	for k in sockets:
		socks.append({"name": k, "accepts": [sockets[k][0]]})
	d["sockets"] = socks
	var r := PartRecord.from_dict(d)
	r.dir = DIR + "try/" + id + "/"
	DirAccess.make_dir_recursive_absolute(r.dir)
	var node := Node3D.new()
	node.name = slot
	var box := MeshInstance3D.new()
	box.name = "Model"
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
	ResourceSaver.save(ps, r.dir + "part.scn")
	return r


func _try_on() -> void:
	print("try on")
	var gun_mag := PartRecord.from_dict({"id": "mag", "family": "gun", "scale": "held", "slot": "magazine",
			"mount": {"interface": "mag.narrow"}})
	_ok("a gun's magazine cannot go on a mech", _ws.try_part(gun_mag).contains("not a mech's part"))
	var leg := _try_part("lu.leg_2", "leg", "R", "mech.hip", {"length": 2})
	_ws.select_part(_ws.part_names.find("arm_L"))
	_ok("a right leg goes on the right leg", _ws.try_part(leg) == "" and _ws.tried.has("leg_R"))
	_ok("it mounts on the hip", not String(_ws.fit_marks.get("leg_R", "")).contains("mounts on"))
	_ok("a leg 2 long beside one 3 long: both marked", String(_ws.fit_marks.get("leg_R", "")) == "legs 3 and 2 long"
			and String(_ws.fit_marks.get("leg_L", "")) == "legs 3 and 2 long", str(_ws.fit_marks))
	_ok("drawn on the right hip", (_ws._tried_nodes.leg_R as Node3D).position.is_equal_approx(_ws.mech_joint_m("leg_R")),
			str((_ws._tried_nodes.leg_R as Node3D).position))
	var arm := _try_part("lu.arm_any", "arm", "any", "mech.shoulder")
	_ok("an arm for either side goes on the arm being built", _ws.try_part(arm) == "" and _ws.tried.has("arm_L"))
	var off := Vector3(0, 0.5, 2.5)
	var ch := _try_part("lu.chassis", "chassis", "any", "", {}, {"arm_L": ["mech.shoulder", off],
			"leg_L": ["mech.hip", Vector3(0, -1, 1)], "leg_R": ["mech.hip", Vector3(0, -1, -1)]})
	_ok("a chassis goes on", _ws.try_part(ch) == "" and _ws.tried.has("chassis"))
	var want: Vector3 = _ws._try_place.chassis + _ws.mech_basis().inverse() * off
	_ok("the tried arm on the tried chassis's shoulder", (_ws._tried_nodes.arm_L as Node3D).position.is_equal_approx(want))
	_ok("a chassis with no neck: the head marked", String(_ws.fit_marks.get("head", "")).contains("no socket 'neck'"),
			str(_ws.fit_marks.get("head")))
	var cat := PartCatalog.new()
	cat.load_dir(_ws.parts_dir(), "custom")
	for r in [leg, arm, ch]:
		cat.add(r)
	_ws.toggle_catalog()
	var panel: PartCatalogPanel = _ws._catalog_panel
	panel.set_catalog(cat)
	_ws.select_part(_ws.part_names.find("hand_R"))
	_ok("Fits aims at the right arm's wrist on the mech plan", panel.has_fit_target()
			and panel._fit_path == "arm_R/hand" and panel._fit_plan == "mech"
			and panel._fit_host.id == _ws.part_ids.arm_R, "%s %s" % [panel._fit_path, panel._fit_plan])
	_ws.toggle_catalog()
	var before: Dictionary = _ws.save_parts()
	_ok("Save with parts tried on writes none", (before.written as Array).is_empty())
	_ws.untry_all()
	_ok("all off", _ws.tried.is_empty() and _ws.fit_marks.is_empty())


func _back() -> void:
	print("back")
	_ws._new_build()
	_ws.set_asset_kind("gun")
	_ok("Make a gun: a gun's parts again, no reference mech", Array(_ws.part_names) == _ws.GUN_PARTS
			and _ws._mech_ref == null)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
