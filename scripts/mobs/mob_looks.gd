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


## The pig: 2 studs across, 3 long, 6 plates (2 bricks) to its back.
static func pig() -> Node3D:
	var root := Node3D.new()
	root.name = "PigLook"
	var pink := _mat(Color("e89aa8"))
	var dark := _mat(Color("c97585"))
	var legs := 2 * PLATE
	var body := 4 * PLATE
	_box(root, "body", Vector3(STUD * 2.0, body, STUD * 3.0), Vector3(0, legs + body * 0.5, 0), pink)
	var head := Node3D.new()
	head.name = "head"
	head.position = Vector3(0, legs + body * 0.7, -STUD * 1.5)
	root.add_child(head)
	_box(head, "skull", Vector3(STUD * 1.4, PLATE * 3.5, STUD * 1.2), Vector3(0, 0, -STUD * 0.5), pink)
	_box(head, "snout", Vector3(STUD * 0.7, PLATE * 1.5, STUD * 0.3), Vector3(0, -PLATE * 0.5, -STUD * 1.2), dark)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_limb(root, "leg", Vector3(STUD * 0.5, legs, STUD * 0.5),
					Vector3(sx * STUD * 0.6, legs, sz * STUD * 1.0), dark)
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
