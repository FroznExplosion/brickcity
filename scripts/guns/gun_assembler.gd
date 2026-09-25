class_name GunAssembler
extends RefCounted
## Turns a recipe (Slot -> GunPartDef) into an assembled Node3D tree by matching
## "socket_*" Node3Ds (Blender empties) on receiving parts with an optional
## "mount" Node3D (Blender empty) on attaching parts.
##
## Authoring contract (see spec §2):
##  - Receiving parts contain empties named socket_<slot>, e.g. "socket_barrel".
##  - Attaching parts contain one empty named "mount" as a DIRECT CHILD of the
##    part root, marking the point/orientation that must coincide with the socket.
##  - If "mount" is absent, the part's origin is used as the mount point.

const SOCKET_PREFIX := "socket_"
const MOUNT_NODE_NAME := "mount"

## Group added to every instantiated part root, handy for material overrides etc.
const PART_GROUP := &"gun_part"


## recipe: Dictionary[GunPartDef.Slot, GunPartDef]. Must contain Slot.BODY.
## Returns the assembled gun root (the body instance), or null on failure.
static func assemble(recipe: Dictionary) -> Node3D:
	var body_def: GunPartDef = recipe.get(GunPartDef.Slot.BODY)
	if body_def == null or body_def.scene == null:
		push_error("GunAssembler: recipe has no BODY part.")
		return null

	var placed: Dictionary[GunPartDef.Slot, bool] = { GunPartDef.Slot.BODY: true }
	var body := _instantiate_part(body_def)

	# Breadth-first: parts attached this pass can expose sockets for the next
	# (body -> barrel -> muzzle). Each slot is placed at most once.
	var queue: Array[Node3D] = [body]
	while not queue.is_empty():
		var host: Node3D = queue.pop_front()
		for socket in find_sockets(host):
			var slot := slot_for_socket(socket)
			if slot == -1 or placed.get(slot, false):
				continue
			var def: GunPartDef = recipe.get(slot)
			if def == null or def.scene == null:
				continue # Optional slot left empty — fine.
			var part := _instantiate_part(def)
			attach_to_socket(part, socket)
			placed[slot] = true
			queue.append(part)
	return body


## Snaps `part` onto `socket` so the part's mount frame coincides with the
## socket frame. This one line of math is the entire alignment system.
static func attach_to_socket(part: Node3D, socket: Node3D) -> void:
	socket.add_child(part)
	var mount := part.get_node_or_null(MOUNT_NODE_NAME) as Node3D
	if mount != null:
		part.transform = mount.transform.affine_inverse()
	else:
		part.transform = Transform3D.IDENTITY


## All direct-descendant socket nodes of a part instance, excluding any that
## belong to parts already attached beneath it.
static func find_sockets(part_root: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for node in part_root.find_children(SOCKET_PREFIX + "*", "Node3D", true, false):
		if _owning_part(node, part_root) == part_root:
			out.append(node)
	return out


## Parses "socket_barrel" / "socket_barrel_2" -> Slot.BARREL. Returns -1 if unknown.
static func slot_for_socket(socket: Node3D) -> int:
	var suffix := String(socket.name).trim_prefix(SOCKET_PREFIX)
	# Allow numbered duplicates and Godot's import de-duplication suffixes.
	var key := suffix.rstrip("0123456789_")
	if GunPartDef.SLOT_BY_SUFFIX.has(key):
		return GunPartDef.SLOT_BY_SUFFIX[key]
	push_warning("GunAssembler: unrecognized socket '%s'." % socket.name)
	return -1


static func _instantiate_part(def: GunPartDef) -> Node3D:
	var inst := def.scene.instantiate()
	if inst is not Node3D:
		push_error("GunAssembler: part '%s' root is not a Node3D." % def.id)
		var wrapper := Node3D.new()
		wrapper.add_child(inst)
		inst = wrapper
	inst.name = String(def.id)
	inst.add_to_group(PART_GROUP)
	inst.set_meta(&"part_id", def.id)
	inst.set_meta(&"part_slot", def.slot)
	return inst


## Walks up from `node` to find the nearest ancestor that is a part root.
static func _owning_part(node: Node, stop_at: Node) -> Node:
	var cur := node.get_parent()
	while cur != null:
		if cur == stop_at or cur.is_in_group(PART_GROUP):
			return cur
		cur = cur.get_parent()
	return null
