extends SceneTree

## Dressing: bricks on a part's studs outside the workshop (Docs/ModularParts.md section 4,
## stage 11), headless.
##
##     godot --headless --path . --script res://tools/dressing_probe.gd
##
##   studs      a part's studs found from its stud multimeshes, with their pitch
##   rules      on a free stud: yes; the same stud again, no stud there, too near a joint, out
##              into the swing: no; mass adds up
##   drawn      each brick on its stud, standing up off it; a stud a newer rev moved: left off
##   owned      kept by owner and part id: it goes with the part to another mech, and is not
##              another player's; saved and read back
##   debris     bricks knocked off become falling bodies; the owned part keeps them

const DIR := "user://_probe_dressing/"
const PITCH := 0.175

var _pass := 0
var _fail := 0


func _init() -> void:
	print("dressing probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A part: a 6 x 6 stud slab, its studs on top, a socket at one corner, a mount below.
func _part_node(shift := Vector3.ZERO) -> Node3D:
	var root := Node3D.new()
	root.name = "leg"
	var model := Node3D.new()
	model.name = "Model"
	root.add_child(model)
	var slab := MeshInstance3D.new()
	slab.name = "Bricks"
	var bm := BoxMesh.new()
	bm.size = Vector3(6 * PITCH, 0.2, 6 * PITCH)
	slab.mesh = bm
	model.add_child(slab)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Studs"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = CylinderMesh.new()
	mm.instance_count = 36
	var buf := PackedFloat32Array()
	for i in 36:
		var x := (i % 6 - 2.5) * PITCH
		var z := (i / 6 - 2.5) * PITCH
		var t := Transform3D(Basis(), Vector3(x, 0.1, z) + shift)
		mm.set_instance_transform(i, t)
		buf.append_array(PartDressing.buffer_row(t, Color.WHITE))
	mmi.multimesh = mm
	mmi.set_meta(&"buffer", buf)   # as the workshop writes a part's studs
	slab.add_child(mmi)
	var sock := Node3D.new()
	sock.name = "socket_hand"
	sock.position = Vector3(2.5 * PITCH, 0.1, 2.5 * PITCH)
	root.add_child(sock)
	var mount := Node3D.new()
	mount.name = "mount"
	mount.position = Vector3(0, -0.6, 0)   # the joint at the far end of the part
	root.add_child(mount)
	return root


func _key(s: Dictionary, x: int, z: int) -> String:
	for st in s.studs:
		if is_equal_approx(st.at.x, (x - 2.5) * PITCH) and is_equal_approx(st.at.z, (z - 2.5) * PITCH):
			return st.key
	return ""


func _run() -> void:
	var part := _part_node()
	root.add_child(part)
	print("studs")
	var s := PartDressing.studs(part)
	_ok("36 studs found", (s.studs as Array).size() == 36)
	_ok("their pitch", is_equal_approx(s.pitch, PITCH), str(s.pitch))

	print("rules")
	var mid := _key(s, 1, 1)
	var r := PartDressing.add(part, [], mid, "brick", 3)
	_ok("a brick on a free stud", r.ok, String(r.get("why", "")))
	var list: Array = r.list
	_ok("the same stud again: no", PartDressing.add(part, list, mid, "plate", 1).why.contains("already"))
	_ok("no stud there: no", PartDressing.add(part, list, "9,9,9", "brick", 1).why.contains("no stud"))
	_ok("next to the socket: no, it would cross the joint", PartDressing.add(part, list, _key(s, 5, 5), "brick", 1)
			.why.contains("joint"))
	_ok("no such brick", PartDressing.add(part, list, _key(s, 2, 2), "castle", 1).why.contains("no such"))
	var r2 := PartDressing.add(part, list, _key(s, 2, 1), "plate", 5)
	list = r2.list
	_ok("a plate beside it", r2.ok)
	_ok("mass: a brick and a plate", is_equal_approx(PartDressing.mass(list), PartDressing.BRICK_MASS + PartDressing.PLATE_MASS))
	# A tall stack can not be made here: one layer, so the sweep is tried with a part whose
	# studs stand far off its body.
	var odd := _part_node(Vector3(0, 1.0, 0))
	root.add_child(odd)
	var so := PartDressing.studs(odd)
	_ok("out into the space it swings through: no", PartDressing.add(odd, [], _key(so, 1, 1), "brick", 1).why.contains("swings"),
			PartDressing.add(odd, [], _key(so, 1, 1), "brick", 1).get("why", ""))

	print("drawn")
	var off := PartDressing.apply(part, list)
	var holder := part.get_node_or_null(^"Dressing")
	_ok("each brick drawn", off.is_empty() and holder != null and holder.get_child_count() == 2)
	var b0 := holder.get_child(0) as MeshInstance3D
	var st0: Dictionary = (s.studs as Array).filter(func(x: Dictionary) -> bool: return x.key == mid)[0]
	_ok("standing up off its stud", is_equal_approx(b0.position.x, st0.at.x) and b0.position.y > st0.at.y)
	var moved := _part_node(Vector3(PITCH * 0.5, 0, 0))
	root.add_child(moved)
	var left := PartDressing.apply(moved, list)
	_ok("a newer rev moved its studs: those bricks left off, and said", left.size() == 2
			and moved.get_node(^"Dressing").get_child_count() == 0)

	print("owned")
	var store := {}
	PartDressing.put(store, "lu", "lu.leg", list)
	PartDressing.save_store(store, DIR + "dressing.json")
	var back := PartDressing.load_store(DIR + "dressing.json")
	_ok("saved and read back", PartDressing.of(back, "lu", "lu.leg") == list)
	_ok("not another player's", PartDressing.of(back, "kim", "lu.leg").is_empty())
	var m := Mech.spawn(root, Vector3.ZERO, 0.0, 0)
	var on_mech := _part_node()
	on_mech.set_meta(&"part_id", "lu.leg")
	var joint := Node3D.new()
	joint.name = "Joint_leg_L"
	m.legs.add_child(joint)
	joint.add_child(on_mech)
	_ok("it goes with the part to a mech", PartDressing.dress_mech(m, "lu", back) == 2
			and on_mech.get_node(^"Dressing").get_child_count() == 2)
	_ok("another owner's mech of the same part: none of it", PartDressing.dress_mech(m, "kim", back) == 0)

	print("debris")
	PartDressing.dress_mech(m, "lu", back)
	await process_frame
	var n := PartDressing.shed(on_mech, 1, root)
	var bodies := root.get_children().filter(func(c: Node) -> bool: return c is RigidBody3D)
	_ok("knocked off: a falling body", n == 1 and bodies.size() == 1)
	_ok("one brick left on", on_mech.get_node(^"Dressing").get_child_count() == 1)
	_ok("the owned part keeps both", PartDressing.of(back, "lu", "lu.leg").size() == 2)
	_wipe(DIR)
	print("dressing probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
