extends SceneTree

## Figures: action figures with swappable limbs (Docs/ModularParts.md section 10, stage 12),
## headless.
##
##     godot --headless --path . --script res://tools/figure_probe.gd
##
##   workshop   Make a figure: its nine parts, the reference's joints laid ready with fig.*
##              interfaces, its sockets in the point panel; Save writes nine figure parts --
##              no class, no leg length -- that make a whole figure by the plan
##   game       the saved parts are a design; the figure stands on its hips, one size; it
##              walks by the figure walk, left against right
##   swap       any figure's arm on any figure's shoulder; what hangs on it stays; a head on
##              a shoulder, or a mech's arm, refused, and nothing changes
##   joints     a leg bends at its knee, an arm at its elbow: the bricks below in the scene
##              under the bend, the wrist with them; on the figure the hand rides the elbow;
##              walking, the knee folds back as its leg swings through
##   back       Make a mech after: a mech's parts, a mech's reference

const DIR := "user://_probe_figure/"

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
	_ws._hotbar.save_path = "user://_probe_figure_hotbar.json"
	_ws.toolbars_save = "user://_probe_figure_toolbars.json"
	for yaw in 2:
		var n := BrickPalette.variant_name("brick_1x4", yaw, false)
		if BrickPalette.size_of(n).x == 4:
			_arch = n
	_wipe(DIR)
	print("figure probe")
	var cat := _workshop()
	await _game(cat)
	_back()
	_ws._builds_dir = BuildRecipe.player_dir()
	_wipe(DIR)
	print("figure probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _workshop() -> PartCatalog:
	print("workshop")
	_ws._new_build()
	_ws.set_asset_kind("figure")
	_ok("a figure's nine parts", Array(_ws.part_names) == FigureReference.PARTS, str(_ws.part_names))
	var ready: Array = _ws.points.filter(func(q: Dictionary) -> bool: return q.get("ready", false) and q.kind != "bend")
	_ok("eight joints laid ready, a mount and a socket each", ready.size() == 16, str(ready.size()))
	_ok("on fig interfaces", ready.all(func(q: Dictionary) -> bool: return String(q.interface).begins_with("fig.")))
	var hat: Array = ready.filter(func(q: Dictionary) -> bool: return q.part == "head" and q.kind == "socket")
	_ok("the head's socket takes a hat", hat.size() == 1 and hat[0].interface == "fig.hat" and hat[0].slot == "hat")
	_ok("the status line says figure", _ws.ruler_text().contains("FIGURE"))
	var slots := []
	for i in _ws._point_slot.item_count:
		slots.append(_ws._point_slot.get_item_text(i))
	_ok("the point panel offers the figure's sockets", slots == ["neck", "arm_L", "arm_R", "hand", "leg_L", "leg_R", "hat"],
			str(slots))
	_ok("its reference is drawn", _ws._mech_ref != null and _ws._mech_ref.get_node_or_null("Joint_hat") != null)
	for part in FigureReference.PARTS:
		_ws.select_part(_ws.part_names.find(part))
		var j: Vector3 = _ws.mech_joint(part)
		var c := Vector3i(int(j.x) - 2, int(j.y), int(floor(j.z)))
		if part.begins_with("leg") or part.begins_with("hand") or part.begins_with("arm"):
			c.y -= 3
		_ok("a brick for %s" % part, _ws.place_named(_arch, c), str(c))
		var bend: Vector3 = FigureReference.bend_at(part, "knee" if part.begins_with("leg") else "")
		if bend != Vector3.INF:
			# And one below its knee or elbow: the part's lower half.
			var low: Vector3 = _ws.mech_origin() + bend
			_ws.place_named(_arch, Vector3i(int(low.x) - 2, int(low.y) - 4, int(floor(low.z))))
	_ws._builds_dir = DIR
	_ws._save_as("Probe Figure")
	var cat := PartCatalog.new()
	_ok("nine parts saved, each on its own", cat.load_dir(_ws.parts_dir(), "custom") == 9)
	var arm := cat.get_part(String(_ws.part_ids.arm_L))
	var leg := cat.get_part(String(_ws.part_ids.leg_R))
	var torso := cat.get_part(String(_ws.part_ids.torso))
	_ok("a figure's arm: no class, left, on fig.shoulder", arm != null and arm.family == "figure"
			and arm.weight_class == "" and arm.side == "L" and arm.interface() == "fig.shoulder")
	_ok("a leg: no length (one size)", leg != null and leg.param("length") == null and leg.interface() == "fig.hip")
	_ok("the torso takes every part", torso != null and torso.socket("neck").get("accepts") == ["fig.neck"]
			and torso.socket("leg_L").get("accepts") == ["fig.hip"])
	var build := {"root": torso, "at": {}}
	for part in FigureReference.PARTS:
		if part != "torso":
			build.at[FigureReference.path_of(part)] = cat.get_part(String(_ws.part_ids[part]))
	var bad := PartFit.problems(build, "figure")
	_ok("saved apart, they make a whole figure", bad.is_empty(), "; ".join(bad))
	return cat


## A figure arm of its own: a box with a wrist socket.
func _arm(id: String, iface: String, family := "figure", slot := "arm") -> PartRecord:
	var r := PartRecord.from_dict({"id": id, "family": family, "slot": slot, "side": "any",
			"source": "custom", "creator": {"name": "Lu"}, "mount": {"interface": iface},
			"sockets": [{"name": "hand", "accepts": ["fig.wrist"]}] if slot == "arm" else []})
	r.dir = DIR + "extra/" + id + "/"
	DirAccess.make_dir_recursive_absolute(r.dir)
	var n := Node3D.new()
	n.name = slot
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	n.add_child(box)
	box.owner = n
	var mount := Node3D.new()
	mount.name = "mount"
	n.add_child(mount)
	mount.owner = n
	var s := Node3D.new()
	s.name = "socket_hand"
	s.position = Vector3(0, -0.5, 0)
	n.add_child(s)
	s.owner = n
	var ps := PackedScene.new()
	ps.pack(n)
	n.free()
	ResourceSaver.save(ps, r.dir + "part.scn")
	return r


func _game(cat: PartCatalog) -> void:
	print("game")
	var made := Figure.designs(cat)
	var d: PartDesign = made.get("probe_figure")
	_ok("the saved parts are a figure design", d != null and d.slots.size() == 9 and d.plan == "figure",
			str(made.keys()))
	var b := PartBuilder.generate("figure", d, 1, cat)
	var f := Figure.make(b)
	_ok("a figure made of them", f != null, str(b.problems))
	if f == null:
		return
	root.add_child(f)
	_ok("standing on its hips, one size: 0.84 m", is_equal_approx(f.model.position.y, 0.84))
	_ok("every part on a joint", f.joint("arm_L") != null and f.joint("arm_L/hand") != null and f.joint("neck/hat") != null)
	_ok("it walks by the figure walk", f.walk_id == "figure.walk.stride" and f.walk != null and f.walk.hips.size() == 2)
	f.speed = 1.5
	for i in 20:
		await physics_frame
	_ok("its legs swing, left against right", absf(f.joint("leg_L").rotation.x) > 0.01
			and is_equal_approx(f.joint("leg_L").rotation.x, -f.joint("leg_R").rotation.x))

	print("joints")
	var leg_rec: PartRecord = f.build.at.leg_L
	var leg_scene := (load(leg_rec.dir + "part.scn") as PackedScene).instantiate() as Node3D
	var lower := leg_scene.get_node_or_null(^"Bend_knee/Lower")
	_ok("a leg's scene: its bricks below the knee under the bend", lower != null and lower.get_child_count() > 0
			and leg_scene.get_node(^"Model").get_child_count() > 0)
	_ok("its record says where it bends", leg_rec.extra.get("bends", []) == ["knee", "ankle"], str(leg_rec.extra.get("bends")))
	var ankle_pivot := (load(leg_rec.dir + "part.scn") as PackedScene).instantiate() as Node3D
	_ok("the ankle hangs on the knee", ankle_pivot.get_node_or_null(^"Bend_knee/Bend_ankle") != null)
	ankle_pivot.free()
	leg_scene.free()
	var elbow := f.joint("arm_L").find_child("Bend_elbow", true, false) as Node3D
	var hand := f.joint("arm_L/hand")
	_ok("the hand rides the elbow", elbow != null and hand != null and elbow.is_ancestor_of(hand))
	var before_hand := hand.global_position
	elbow.rotation.x = 1.0
	_ok("the elbow bent: the hand moved", not hand.global_position.is_equal_approx(before_hand))
	elbow.rotation.x = 0.0
	var knee := f.joint("leg_L").find_child("Bend_knee", true, false) as Node3D
	_ok("the walk has both knees", f.walk.knees.size() == 2 and f.walk.knees[0] == knee)
	var folded := 0.0
	for i in 40:
		f.walk.step(0.03, 1.5)
		folded = minf(folded, knee.rotation.x)
	_ok("walking, the knee folds back as the leg swings through", folded < -0.05 and knee.rotation.x <= 0.0, str(folded))
	f.walk.step(0.03, 0.0)
	_ok("standing, the knees straight", is_zero_approx(knee.rotation.x))
	var ankle := knee.get_node_or_null(^"Bend_ankle") as Node3D
	_ok("the walk has both ankles", f.walk.ankles.size() == 2 and f.walk.ankles[0] == ankle)
	var level := true
	for i in 30:
		f.walk.step(0.03, 1.5)
		level = level and is_zero_approx(f.joint("leg_L").rotation.x + knee.rotation.x + ankle.rotation.x)
	_ok("walking, the foot kept level", level)

	print("swap")
	var other := _arm("lu.long_arm", "fig.shoulder")
	var hand_id: String = f.build.at["arm_L/hand"].id
	_ok("any figure's arm on its shoulder", f.swap("arm_L", other)
			and (f.joint("arm_L").get_child(0) as Node).get_meta(&"part_id") == "lu.long_arm")
	_ok("its hand stays on, on the new arm's wrist", f.build.at["arm_L/hand"].id == hand_id
			and f.joint("arm_L/hand") != null
			and f.joint("arm_L/hand").position.is_equal_approx(f.joint("arm_L").position + Vector3(0, -0.5, 0)))
	var head := cat.get_part(String(_ws.part_ids.head))
	_ok("a head on a shoulder: refused", f.why_not_swap("arm_R", head).contains("takes a arm") or
			f.why_not_swap("arm_R", head) != "", f.why_not_swap("arm_R", head))
	var mech_arm := _arm("lu.mech_arm", "mech.shoulder", "mech")
	var before: String = f.build.at.arm_R.id
	_ok("a mech's arm: refused, nothing changes", not f.swap("arm_R", mech_arm) and f.build.at.arm_R.id == before)
	f.queue_free()


func _back() -> void:
	print("back")
	_ws._new_build()
	_ws.set_asset_kind("mech")
	_ok("Make a mech after: a mech's parts and reference", Array(_ws.part_names) == MechReference.PARTS
			and _ws._mech_ref != null and _ws._mech_ref.get_node_or_null("Joint_pod_L") != null)
	_ws.set_asset_kind("gun")


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
