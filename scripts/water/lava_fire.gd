extends Node3D

## LAVA STARTS FIRES (Docs/MineWater.md 4.6): a wood or leaves plate next to
## lava catches fire (BrickFluid's take() lists them, "fire"); it burns a few
## seconds -- flames and a flickering light -- may set the wood and leaves
## touching it alight, then is gone (a terrain edit to air, so what stood on it
## may come down: ground_collapse.gd). Leaves go faster than wood.
##
## Preloaded by path, not named (see terrain_scene.gd).

const WOOD_S := Vector2(4.0, 7.0)
const LEAVES_S := Vector2(1.5, 3.0)
## Every SPREAD_EVERY, each burning plate lights each burnable neighbour
## with this chance.
const SPREAD_EVERY := 0.5
const SPREAD_CHANCE := 0.25
## Lights at most (the rest burn without one).
const MAX_LIGHTS := 16
const MAX_FIRES := 400

var host: Node = null
var burning := {}                 ## Vector3i plate cell -> {left: float, node: Node3D}
var burned := 0

## Every colour of wood and of leaves (Docs/Inventory.md 13), material indices.
var _wood: Array[int] = []
var _leaves: Array[int] = []
var _spread_in := 0.0
var _flame_mesh: BoxMesh
var _flame_mat: StandardMaterial3D
var _lights := 0


func setup(p_host: Node) -> void:
	host = p_host
	var names := BrickTerrain.material_names()
	_wood.clear()
	_leaves.clear()
	for m in names.size():
		if names[m] == "wood" or names[m].ends_with(" wood"):
			_wood.append(m)
		elif names[m] == "leaves" or names[m].ends_with(" leaves"):
			_leaves.append(m)
	_flame_mesh = BoxMesh.new()
	var stud := BrickWorld.get_stud_metres()
	_flame_mesh.size = Vector3(stud * 0.8, BrickWorld.get_plate_metres() * 2.5, stud * 0.8)
	_flame_mat = StandardMaterial3D.new()
	_flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flame_mat.albedo_color = Color(1.0, 0.55, 0.1)
	_flame_mat.emission_enabled = true
	_flame_mat.emission = Color(1.0, 0.45, 0.05)
	_flame_mat.emission_energy_multiplier = 3.0
	_flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flame_mat.albedo_color.a = 0.75


func clear() -> void:
	for k in burning:
		var n: Node3D = burning[k].node
		if is_instance_valid(n):
			n.queue_free()
	burning.clear()
	_lights = 0


func burnable(cell: Vector3i) -> bool:
	var m := BrickTerrain.solid_at(cell.x, cell.y, cell.z)
	return _wood.has(m) or _leaves.has(m)


## Set one plate cell alight (x, plate, z), if it burns and is not already.
func ignite(cell: Vector3i) -> bool:
	if burning.has(cell) or burning.size() >= MAX_FIRES or not burnable(cell):
		return false
	var leaves := _leaves.has(BrickTerrain.solid_at(cell.x, cell.y, cell.z))
	var span: Vector2 = LEAVES_S if leaves else WOOD_S
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var node := Node3D.new()
	node.position = Vector3((cell.x + 0.5) * stud, (cell.y + 1.0) * plate + 0.1, (cell.z + 0.5) * stud)
	var mi := MeshInstance3D.new()
	mi.mesh = _flame_mesh
	mi.material_override = _flame_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(mi)
	if _lights < MAX_LIGHTS:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.55, 0.15)
		l.light_energy = 1.6
		l.omni_range = 3.5
		l.shadow_enabled = false
		node.add_child(l)
		_lights += 1
	add_child(node)
	burning[cell] = { "left": randf_range(span.x, span.y), "node": node }
	return true


func _process(delta: float) -> void:
	if burning.is_empty():
		return
	var t := Time.get_ticks_msec() / 1000.0
	var done: Array[Vector3i] = []
	for cell in burning:
		var f: Dictionary = burning[cell]
		f.left = float(f.left) - delta
		var n: Node3D = f.node
		if is_instance_valid(n):
			# Flicker: the flame breathes and the light with it.
			var k := 0.75 + 0.25 * sin(t * 13.0 + cell.x * 1.7 + cell.z * 2.3)
			n.scale = Vector3(1.0, k, 1.0)
			for ch in n.get_children():
				if ch is OmniLight3D:
					(ch as OmniLight3D).light_energy = 1.6 * k
		if float(f.left) <= 0.0:
			done.append(cell)
	_spread_in -= delta
	if _spread_in <= 0.0:
		_spread_in = SPREAD_EVERY
		var lit: Array[Vector3i] = []
		for cell in burning:
			for o in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
					Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
				if randf() < SPREAD_CHANCE:
					lit.append(cell + o)
		for c in lit:
			ignite(c)
	for cell in done:
		var f: Dictionary = burning[cell]
		burning.erase(cell)
		var n: Node3D = f.node
		if is_instance_valid(n):
			for ch in n.get_children():
				if ch is OmniLight3D:
					_lights -= 1
			n.queue_free()
		# Burned away: air, so what it held may fall (ground_collapse.gd).
		if burnable(cell):
			var r: Dictionary = BrickTerrain.fill_box(cell, cell, 0, false)
			if int(r.get("changed", 0)) > 0:
				burned += 1
				host.terrain_edited(r)
