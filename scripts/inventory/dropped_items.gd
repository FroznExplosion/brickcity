class_name DroppedItems
extends Node3D
## Items lying in the mine world (Docs/Inventory.md 4, stage 5): what a
## broken chest held, a stack dropped from the inventory screen (Q), what did
## not fit. Each is a stack, a small model of it (ItemIcons' model) turning
## and bobbing, falling onto the ground; walk over one and it goes into the
## inventory (`Inventory.add_item`; what does not fit stays). Gone after
## LIFETIME, Minecraft's five minutes. Saved with the world (`to_save`).
##
## A child of the mine world with no transform of its own, so positions are
## the terrain frame (the origin shift moves the parent, Docs/MineWorld.md 15).
## The ground is BrickTerrain's cells (`solid_at`), no physics bodies: a drop
## lands on top of the plate cell under it.

const LIFETIME := 300.0
const PICK_RADIUS := 1.3
## A drop can be picked up this long after it appears (not at once by the
## player who dropped it).
const PICK_DELAY := 1.0
const GRAVITY := 9.8
const MAX_DROPS := 200
## The model's size, metres (about a 2x2 block's width).
const MODEL_M := 0.45

var host: Node = null
var inv: Inventory = null
## The mine world's sky light on things (Docs/MineWorld.md 19), or null:
## each drop drawn with its cell's sky light.
var sky: MineSkyLit = null
## [{stack, pos, vel, age, node}]
var drops: Array = []
var _stud := 0.35
var _plate := 0.14


func setup(p_host: Node, p_inv: Inventory) -> void:
	host = p_host
	inv = p_inv
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()


func count() -> int:
	return drops.size()


## A stack into the world at `pos` (terrain frame), thrown with `vel`.
func spawn(s: ItemStack, pos: Vector3, vel := Vector3.ZERO, age := 0.0) -> void:
	if s == null or s.is_empty():
		return
	while drops.size() >= MAX_DROPS:
		_remove(0)
	var node := _model(s.id)
	node.position = pos
	add_child(node)
	if sky != null:
		sky.sky_lit_model(node)
		sky.track(node)
	drops.append({"stack": s, "pos": pos, "vel": vel, "age": age, "node": node, "rest": false})


func clear() -> void:
	while not drops.is_empty():
		_remove(drops.size() - 1)


func _remove(i: int) -> void:
	var d: Dictionary = drops[i]
	if is_instance_valid(d.node):
		(d.node as Node).queue_free()
	drops.remove_at(i)


func _physics_process(delta: float) -> void:
	if drops.is_empty() or host == null:
		return
	var feet: Vector3 = host.player_feet_local() if host.has_method("player_feet_local") else Vector3.INF
	var i := 0
	var changed := false
	while i < drops.size():
		var d: Dictionary = drops[i]
		d.age += delta
		if d.age > LIFETIME:
			_remove(i)
			changed = true
			continue
		if not d.rest:
			_fall(d, delta)
		if feet != Vector3.INF and d.age > PICK_DELAY and inv != null \
				and (d.pos as Vector3).distance_to(feet + Vector3(0, 0.5, 0)) < PICK_RADIUS:
			var left := inv.add_item(d.stack)
			changed = true
			if left == null:
				_remove(i)
				continue
			d.stack = left
		var node: Node3D = d.node
		node.position = d.pos + Vector3(0, 0.12 + 0.06 * sin(d.age * 2.5), 0)
		node.rotation.y = d.age * 1.6
		i += 1
	if changed and host.has_method("world_items_changed"):
		host.world_items_changed()


## Gravity onto the plate cell under it; at rest once it stands on one.
func _fall(d: Dictionary, delta: float) -> void:
	var v: Vector3 = d.vel
	v.y -= GRAVITY * delta
	v.x *= exp(-delta * 2.0)
	v.z *= exp(-delta * 2.0)
	var p: Vector3 = d.pos + v * delta
	var cx := floori(p.x / _stud)
	var cz := floori(p.z / _stud)
	var cy := floori(p.y / _plate)
	if BrickTerrain.solid_at(cx, cy, cz) != 0:
		# Inside the ground: onto the top of the cell, stopped.
		p.y = (cy + 1) * _plate
		while BrickTerrain.solid_at(cx, floori(p.y / _plate), cz) != 0 and p.y < d.pos.y + 4.0:
			p.y += _plate
		v = Vector3.ZERO
		d.rest = true
	d.pos = p
	d.vel = v
	if p.y < -200.0:
		d.age = LIFETIME + 1.0


## The ground under a resting drop went (a block broken, the ground fell):
## it falls again.
func wake() -> void:
	for d in drops:
		d.rest = false


func _model(id: StringName) -> Node3D:
	var root := Node3D.new()
	var m := ItemIcons._model(ItemCatalog.get_def(id))
	m.scale = Vector3.ONE * MODEL_M
	root.add_child(m)
	return root


func to_save() -> Array:
	var out := []
	for d in drops:
		var p: Vector3 = d.pos
		out.append({"stack": (d.stack as ItemStack).to_dict(), "pos": [p.x, p.y, p.z], "age": d.age})
	return out


func restore(saved) -> void:
	clear()
	if not (saved is Array):
		return
	for e in saved:
		if not (e is Dictionary):
			continue
		var s := ItemStack.from_dict(e.get("stack"))
		var p = e.get("pos", [])
		if s == null or not ItemCatalog.has(s.id) or not (p is Array) or p.size() != 3:
			continue
		spawn(s, Vector3(p[0], p[1], p[2]), Vector3.ZERO, float(e.get("age", 0.0)))
