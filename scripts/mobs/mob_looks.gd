class_name MobLooks
extends RefCounted
## Block-out looks for the mine world's creatures (Docs/MineCreatures.md 3, 5):
## boxes measured in studs and plates, a placeholder until real models come.
## Each look is a Node3D with its feet at its origin, facing -Z; legs are
## named "leg*" so a walk can swing them (swing()).

const STUD := 0.35
const PLATE := 0.14


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


static func _box(parent: Node3D, name: String, size: Vector3, centre: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = centre
	parent.add_child(mi)
	return mi


## A pivot at `at` holding a box hanging down from it (legs, arms).
static func _limb(parent: Node3D, name: String, size: Vector3, at: Vector3, mat: Material, forward := false) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = name
	pivot.position = at
	parent.add_child(pivot)
	var c := Vector3(0, 0, -size.z * 0.5) if forward else Vector3(0, -size.y * 0.5, 0)
	_box(pivot, "box", size, c, mat)
	return pivot


## The zombie: 2 studs across, 4 bricks (12 plates) tall -- legs 5 plates,
## body 4, head 3. Arms held out in front.
static func zombie() -> Node3D:
	var root := Node3D.new()
	root.name = "ZombieLook"
	var skin := _mat(Color("5f8f4a"))
	var shirt := _mat(Color("2e6b80"))
	var pants := _mat(Color("3a3a6a"))
	var legs := 5 * PLATE
	var torso := 4 * PLATE
	var head := 3 * PLATE
	_limb(root, "leg_l", Vector3(STUD * 0.95, legs, STUD * 0.9), Vector3(-STUD * 0.5, legs, 0), pants)
	_limb(root, "leg_r", Vector3(STUD * 0.95, legs, STUD * 0.9), Vector3(STUD * 0.5, legs, 0), pants)
	_box(root, "torso", Vector3(STUD * 2.0, torso, STUD), Vector3(0, legs + torso * 0.5, 0), shirt)
	_box(root, "head", Vector3(STUD * 1.25, head, STUD * 1.25), Vector3(0, legs + torso + head * 0.5, 0), skin)
	# Eyes: two dark plates on the face.
	var eye := _mat(Color("1a1010"))
	for sx in [-1.0, 1.0]:
		_box(root, "eye", Vector3(STUD * 0.25, PLATE * 0.6, 0.02),
				Vector3(sx * STUD * 0.28, legs + torso + head * 0.55, -STUD * 0.63), eye)
	var shoulder := legs + torso - PLATE * 0.6
	_limb(root, "arm_l", Vector3(STUD * 0.5, STUD * 0.5, torso * 1.2), Vector3(-STUD * 1.2, shoulder, 0), skin, true)
	_limb(root, "arm_r", Vector3(STUD * 0.5, STUD * 0.5, torso * 1.2), Vector3(STUD * 1.2, shoulder, 0), skin, true)
	return root


## The look of creature `kind`: a real model if a content pack has one --
## creatures/<kind>.tscn, .scn or .glb, feet at its origin, facing -Z, legs
## named "leg*" to swing -- else the block-out (Docs/MineCreatures.md 11).
static func make(kind: StringName, def: Dictionary) -> Node3D:
	for ext in ["tscn", "scn", "glb"]:
		var path := ContentPacks.resolve("creatures/%s.%s" % [kind, ext])
		if path != "" and ResourceLoader.exists(path):
			var scene := load(path) as PackedScene
			if scene != null:
				var n := scene.instantiate()
				if n is Node3D:
					return n
				n.free()
	if kind == &"zombie":
		return zombie()
	return quadruped(def)


## A four-legged block-out from a CreatureBook entry: its body box the
## creature's width x `look.len` studs, its height the body's plates.
static func quadruped(def: Dictionary) -> Node3D:
	var look: Dictionary = def.get("look", {})
	var b: Vector4i = def.get("body", Vector4i(2, 6, 3, 9))
	var root := Node3D.new()
	root.name = "%sLook" % str(def.get("name", "Animal"))
	var main := _mat(Color(str(look.get("colour", "#a08060"))))
	var dark := _mat(Color(str(look.get("dark", "#604830"))))
	var w := b.x * STUD
	var length := float(look.get("len", 3)) * STUD
	var legs := float(look.get("legs", 2)) * PLATE
	var h := b.y * PLATE
	var body_h := maxf(h - legs - PLATE, PLATE * 1.5)
	_box(root, "body", Vector3(w, body_h, length), Vector3(0, legs + body_h * 0.5, 0), main)
	var head := Node3D.new()
	head.name = "head"
	head.position = Vector3(0, legs + body_h * 0.75, -length * 0.5)
	root.add_child(head)
	var hs := minf(w * 0.7, h * 0.5)
	_box(head, "skull", Vector3(hs, hs, hs * 0.9), Vector3(0, 0, -hs * 0.4), main)
	if bool(look.get("snout", false)) or bool(look.get("tusks", false)):
		_box(head, "snout", Vector3(hs * 0.5, hs * 0.4, STUD * 0.3), Vector3(0, -hs * 0.15, -hs * 0.95), dark)
	if bool(look.get("tusks", false)):
		for sx in [-1.0, 1.0]:
			_box(head, "tusk", Vector3(0.03, 0.08, 0.03), Vector3(sx * hs * 0.3, -hs * 0.2, -hs * 1.05), _mat(Color("e8e0c8")))
	if bool(look.get("ears", false)):
		for sx in [-1.0, 1.0]:
			_box(head, "ear", Vector3(hs * 0.2, hs * 0.6, hs * 0.1), Vector3(sx * hs * 0.3, hs * 0.65, -hs * 0.2), dark)
	if bool(look.get("antlers", false)):
		for sx in [-1.0, 1.0]:
			_box(head, "antler", Vector3(0.04, hs * 1.1, 0.04), Vector3(sx * hs * 0.35, hs * 0.95, -hs * 0.1), _mat(Color("d8c8a0")))
	if bool(look.get("tail", false)):
		_box(root, "tail", Vector3(STUD * 0.25, STUD * 0.25, STUD * 0.9), Vector3(0, legs + body_h * 0.8, length * 0.5 + STUD * 0.35), dark)
	var leg_w := clampf(w * 0.25, 0.08, STUD * 0.5)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_limb(root, "leg", Vector3(leg_w, legs, leg_w), Vector3(sx * (w * 0.5 - leg_w * 0.6), legs, sz * (length * 0.5 - leg_w)), dark)
	return root


## Swing the legs (and a zombie's arms a little) at walking speed `speed` m/s.
static func swing(look: Node3D, t: float, speed: float) -> void:
	var amp := clampf(speed / 3.0, 0.0, 1.0) * 0.7
	var i := 0
	for c in look.get_children():
		var n := String(c.name)
		if n.begins_with("leg"):
			(c as Node3D).rotation.x = sin(t * 9.0 + (PI if i % 2 == 1 else 0.0) + (PI * 0.5 if i >= 2 else 0.0)) * amp
			i += 1
		elif n.begins_with("arm"):
			(c as Node3D).rotation.x = sin(t * 4.0 + (0.5 if n == "arm_l" else 0.0)) * 0.08
