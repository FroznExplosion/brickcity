class_name MineChests
extends Node3D
## Chests in the mine world (Docs/Inventory.md 4, stage 5), the store of
## zylanntest's chest_store.gd: each placed chest owns CHEST_SIZE slots, keyed
## by its block. A chest is not a terrain material (the field's C++ is not
## touched): a node 2 x 2 studs on the stud lattice, one brick (3 plates)
## tall standing at any plate height -- ground tops are at any plate, so a
## 3-plate lattice would leave most chests half in the ground. The chest
## item's model fitted to that box, and a box collider on Layers.WORLD so the
## pawn stands on it and bullets hit it. Its `block` is (x / 2 studs, bottom
## plate, z / 2 studs).
##
##   place   the chest item's RMB: on the face looked at, into air, on ground
##   open    RMB on a chest: its slots borrowed by the inventory screen
##   break   LMB, a shot (`shot`), or what holds it gone (`check`: the ground
##           under it all air, or a block put into it) -- its contents fall
##           out as dropped items, and in survival the chest itself
##
## A child of the mine world with no transform of its own: positions are the
## terrain frame. Saved with the world (`to_save` / `restore`).

const STUDS := 2
const PLATES := 3

var host: Node = null
var drops: DroppedItems = null
var inv: Inventory = null
## The mine world's sky light on things (Docs/MineWorld.md 19), or null.
var sky: MineSkyLit = null
## key "x,y,z" (block) -> {"block": Vector3i, "slots": Array, "node": Node3D}
var chests := {}
var _stud := 0.35
var _plate := 0.14


func setup(p_host: Node, p_inv: Inventory, p_drops: DroppedItems) -> void:
	host = p_host
	inv = p_inv
	drops = p_drops
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()


func count() -> int:
	return chests.size()


static func key_of(block: Vector3i) -> String:
	return "%d,%d,%d" % [block.x, block.y, block.z]


## The chest standing on plate cell `cell` (its bottom plate is that cell's).
static func block_of(cell: Vector3i) -> Vector3i:
	return Vector3i(floori(float(cell.x) / STUDS), cell.y, floori(float(cell.z) / STUDS))


func lo_cell(block: Vector3i) -> Vector3i:
	return Vector3i(block.x * STUDS, block.y, block.z * STUDS)


func box_of(block: Vector3i) -> AABB:
	return AABB(Vector3(block.x * STUDS * _stud, block.y * _plate, block.z * STUDS * _stud),
			Vector3(STUDS * _stud, PLATES * _plate, STUDS * _stud))


## Does any chest stand in `box` (terrain frame)? A block is not put there.
func overlaps(box: AABB) -> bool:
	for key in chests:
		if box_of(chests[key].block).grow(-0.01).intersects(box):
			return true
	return false


## Is any plate cell of the block solid ground?
func _any_solid(block: Vector3i) -> bool:
	var lo := lo_cell(block)
	for x in STUDS:
		for y in PLATES:
			for z in STUDS:
				if BrickTerrain.solid_at(lo.x + x, lo.y + y, lo.z + z) != 0:
					return true
	return false


## Does anything solid hold it from under (any cell under its footprint)?
func _supported(block: Vector3i) -> bool:
	var lo := lo_cell(block)
	for x in STUDS:
		for z in STUDS:
			if BrickTerrain.solid_at(lo.x + x, lo.y - 1, lo.z + z) != 0:
				return true
	return false


## Would a chest fit at `block`: air, held from under, no chest in the way.
func can_place(block: Vector3i) -> bool:
	return not overlaps(box_of(block)) and not _any_solid(block) and _supported(block)


## A chest at `block`, empty (or holding `slots`). False if it does not fit.
func place(block: Vector3i, slots: Array = [], force := false) -> bool:
	if not force and not can_place(block):
		return false
	var key := key_of(block)
	if chests.has(key):
		return false
	var s := slots
	if s.size() != Inventory.CHEST_SIZE:
		s = Inventory._empty(Inventory.CHEST_SIZE)
	var node := _node(block)
	add_child(node)
	if sky != null:
		sky.sky_lit_model(node)
		sky.track(node)
	chests[key] = {"block": block, "slots": s, "node": node}
	_changed()
	return true


func slots_of(key: String) -> Array:
	return chests[key].slots if chests.has(key) else []


## The nearest chest along a ray (terrain frame) within `reach`:
## {key, dist, normal} or {}.
func ray(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
	var best := {}
	for key in chests:
		var box := box_of(chests[key].block)
		var hit = box.intersects_ray(from, dir)
		if hit == null:
			continue
		var d := from.distance_to(hit)
		if d <= reach and (best.is_empty() or d < best.dist):
			best = {"key": key, "dist": d, "point": hit}
	return best


## The chest a point (terrain frame) is in or on, or "".
func at_point(p: Vector3) -> String:
	for key in chests:
		if box_of(chests[key].block).grow(0.08).has_point(p):
			return key
	return ""


## A bullet reached `p` (terrain frame): a chest there breaks. True if one did.
func shot(p: Vector3) -> bool:
	var key := at_point(p)
	if key.is_empty():
		return false
	break_chest(key, inv != null and not inv.creative)
	return true


## The chest goes; what it held falls out (and the chest itself, `drop_self`).
func break_chest(key: String, drop_self: bool) -> void:
	if not chests.has(key):
		return
	var c: Dictionary = chests[key]
	chests.erase(key)
	if inv != null and inv.chest_key == key and host != null and host.has_method("inventory_open") \
			and host.inventory_open():
		host.toggle_inventory()
	if inv != null and inv.chest_key == key:
		inv.close_chest()
	if is_instance_valid(c.node):
		(c.node as Node).queue_free()
	var mid := box_of(c.block).get_center()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var all: Array = (c.slots as Array).filter(func(s): return s != null)
	if drop_self:
		all.append(ItemStack.make(&"chest", 1))
	for s in all:
		if drops != null:
			var v := Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(2.0, 3.5), rng.randf_range(-1.2, 1.2))
			drops.spawn(s, mid, v)
	_changed()


## The ground changed: a chest with nothing under it, or with ground put into
## it, breaks (its contents drop). Few chests, a few cells each: cheap.
func check() -> void:
	var gone: Array[String] = []
	for key in chests:
		var b: Vector3i = chests[key].block
		if not _supported(b) or _any_solid(b):
			gone.append(key)
	for key in gone:
		break_chest(key, inv != null and not inv.creative)


func clear() -> void:
	for key in chests:
		var n = chests[key].node
		if is_instance_valid(n):
			(n as Node).queue_free()
	chests.clear()


func _changed() -> void:
	if host != null and host.has_method("world_items_changed"):
		host.world_items_changed()


func _node(block: Vector3i) -> Node3D:
	var box := box_of(block)
	var root := StaticBody3D.new()
	root.name = "Chest_%s" % key_of(block).replace(",", "_").replace("-", "m")
	root.collision_layer = Layers.WORLD
	root.collision_mask = 0
	root.position = box.get_center()
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	root.add_child(shape)
	var m := ItemIcons._model(ItemCatalog.get_def(&"chest"))
	# The model is fitted to 1.0 on its longest side: fit it inside the block.
	var aabb := _model_aabb(m)
	var k := minf(box.size.x / maxf(aabb.size.x, 0.001), minf(box.size.y / maxf(aabb.size.y, 0.001),
			box.size.z / maxf(aabb.size.z, 0.001))) * 0.96
	m.scale = Vector3.ONE * k
	m.position = Vector3(0, -box.size.y * 0.5 - aabb.position.y * k, 0)
	root.add_child(m)
	return root


static func _model_aabb(m: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for c in m.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		var t := Transform3D()
		var n: Node = mi
		while n != null and n != m:
			t = (n as Node3D).transform * t
			n = n.get_parent()
		var b := t * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


func to_save() -> Dictionary:
	var out := {}
	for key in chests:
		out[key] = Inventory._save_array(chests[key].slots)
	return out


func restore(saved) -> void:
	clear()
	if not (saved is Dictionary):
		return
	for key in saved:
		var parts := str(key).split(",")
		if parts.size() != 3:
			continue
		var slots := Inventory._empty(Inventory.CHEST_SIZE)
		Inventory._load_array(slots, saved[key])
		place(Vector3i(int(parts[0]), int(parts[1]), int(parts[2])), slots, true)
