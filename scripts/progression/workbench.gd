class_name Workbench
extends Node3D
## A safehouse workbench (COMBAT_DESIGN 1.2): where guns are infused and broken down
## for scrap. The player holds R looking at it (PlayerArsenal) and the backpack opens on
## the bench's page. A greybox counter for now -- a bench, a vice, a lamp -- solid, so
## it is walked round.

## Every bench is in this group: what a player can reach for.
const GROUP := &"workbenches"
const SIZE := Vector3(1.6, 0.9, 0.7)
## Where the player looks to use it: the middle of the top.
const USE_HEIGHT := 0.95


static func create() -> Workbench:
	var w := Workbench.new()
	w.name = "Workbench"
	w.add_to_group(GROUP)
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	cs.shape = box
	cs.position.y = SIZE.y * 0.5
	body.add_child(cs)
	w.add_child(body)
	w._part(Vector3(SIZE.x, 0.08, SIZE.z), Vector3(0, SIZE.y - 0.04, 0), Color(0.55, 0.38, 0.2))
	w._part(Vector3(SIZE.x - 0.1, SIZE.y - 0.08, SIZE.z - 0.1), Vector3(0, (SIZE.y - 0.08) * 0.5, 0),
			Color(0.25, 0.27, 0.3))
	w._part(Vector3(0.18, 0.14, 0.12), Vector3(-0.5, SIZE.y + 0.07, 0.1), Color(0.6, 0.62, 0.66))
	w._part(Vector3(0.04, 0.5, 0.04), Vector3(0.6, SIZE.y + 0.25, -0.2), Color(0.2, 0.2, 0.22))
	var lamp := w._part(Vector3(0.22, 0.08, 0.14), Vector3(0.52, SIZE.y + 0.5, -0.15), Color(1.0, 0.8, 0.3))
	(lamp.material_override as StandardMaterial3D).emission_enabled = true
	(lamp.material_override as StandardMaterial3D).emission = Color(1.0, 0.75, 0.3)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.8, 0.5)
	light.omni_range = 3.0
	light.light_energy = 0.8
	light.position = Vector3(0.52, SIZE.y + 0.4, -0.15)
	w.add_child(light)
	return w


func _part(size: Vector3, at: Vector3, col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	m.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	m.material_override = mat
	m.position = at
	add_child(m)
	return m


## Where the player looks at it.
func use_point() -> Vector3:
	return global_position + Vector3.UP * USE_HEIGHT
