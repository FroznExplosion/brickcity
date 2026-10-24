class_name PartDressing
extends RefCounted
## Bricks a player puts on a part's studs outside the workshop (Docs/ModularParts.md section 4,
## "Studs: dressing"; stage 11). Dressing is kept on the part as the player owns it -- by
## owner and part id, keyed by stud -- so it goes with the part to whatever mech it is put on.
##
##   may not cross a joint   no brick within JOINT_CLEAR stud pitches of the part's mount or
##                           any of its sockets (where the next part turns)
##   may not enter a sweep   no brick further out than SWEEP_GROW pitches past the part's own
##                           bounds (what a limb passes through as it swings)
##   one brick a stud        and only on a stud the part has
##   adds mass               BRICK_MASS each, PLATE_MASS a plate
##   breaks off              shed(): bricks fly off as debris (the owned part keeps them: a
##                           fight knocks them off this mech, not out of the player's things)

const KINDS := {"brick": 1.2, "plate": 0.4}   # height in stud pitches
const BRICK_MASS := 0.9   # kg at mech scale; a nano brick is ~2 cm of real plastic, x43.75
const PLATE_MASS := 0.3
const JOINT_CLEAR := 1.6
const SWEEP_GROW := 2.0
const STORE := "user://parts/dressing.json"
## Colours: the brick colours by index, as BrickWorld has them.
const COLOURS := 16


## Every stud of a part scene, in the part root's frame: [{key, at, up}], and the pitch
## (the distance between neighbouring studs). From the part's stud multimeshes.
static func studs(part: Node3D) -> Dictionary:
	var out := []
	for mmi in part.find_children("*", "MultiMeshInstance3D", true, false):
		var chain := _chain(mmi, part)
		for it in instance_transforms(mmi):
			var t := chain * (it as Transform3D)
			out.append({"key": key_of(t.origin), "at": t.origin, "up": t.basis.y.normalized()})
	var pitch := INF
	for i in mini(out.size(), 64):
		for j in out.size():
			if i != j:
				pitch = minf(pitch, (out[i].at as Vector3).distance_to(out[j].at))
	return {"studs": out, "pitch": pitch if pitch < INF else 0.175}


## A stud multimesh's instances: from the buffer kept on the node (`buffer` meta: what the
## workshop and packages write), else from the multimesh -- which only the renderer holds,
## so headless it has none.
static func instance_transforms(mmi: MultiMeshInstance3D) -> Array:
	var mm := mmi.multimesh
	if mm == null:
		return []
	var buf: PackedFloat32Array = mmi.get_meta(&"buffer", PackedFloat32Array())
	var out := []
	if not buf.is_empty() and mm.instance_count > 0:
		var stride := buf.size() / mm.instance_count
		for i in mm.instance_count:
			var o := i * stride
			out.append(Transform3D(Basis(Vector3(buf[o], buf[o + 4], buf[o + 8]), Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
					Vector3(buf[o + 2], buf[o + 6], buf[o + 10])), Vector3(buf[o + 3], buf[o + 7], buf[o + 11])))
		return out
	for i in mm.instance_count:
		out.append(mm.get_instance_transform(i))
	return out


## One instance as a multimesh buffer row: the transform (rows of the basis and origin), then
## the colour.
static func buffer_row(t: Transform3D, c: Color) -> PackedFloat32Array:
	var b := t.basis
	return PackedFloat32Array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y,
			b.x.z, b.y.z, b.z.z, t.origin.z, c.r, c.g, c.b, c.a])


static func key_of(at: Vector3) -> String:
	return "%d,%d,%d" % [roundi(at.x * 1000.0), roundi(at.y * 1000.0), roundi(at.z * 1000.0)]


## Why a brick of `kind` cannot go on stud `key` of `part` with `list` already on it ("" when
## it can).
static func why_not(part: Node3D, key: String, kind: String, list: Array) -> String:
	if not KINDS.has(kind):
		return "no such brick '%s'" % kind
	var s := studs(part)
	var stud: Dictionary = {}
	for st in s.studs:
		if st.key == key:
			stud = st
	if stud.is_empty():
		return "no stud there"
	if list.any(func(d: Dictionary) -> bool: return d.stud == key):
		return "a brick is on that stud already"
	var pitch: float = s.pitch
	var box := brick_box(stud, kind, pitch)
	for j in _joints(part):
		if _box_distance(box, j) < JOINT_CLEAR * pitch:
			return "too near a joint: it would cross where the next part turns"
	var own := _bounds(part)
	if own.size != Vector3.ZERO and not own.grow(SWEEP_GROW * pitch).encloses(box):
		return "it sticks out into the space the part swings through"
	return ""


## Put it on: the list with the brick added, or the same list and why not.
static func add(part: Node3D, list: Array, key: String, kind: String, colour: int) -> Dictionary:
	var why := why_not(part, key, kind, list)
	if why != "":
		return {"ok": false, "why": why, "list": list}
	var out := list.duplicate(true)
	out.append({"stud": key, "kind": kind, "colour": posmod(colour, COLOURS)})
	return {"ok": true, "list": out}


static func remove(list: Array, key: String) -> Array:
	return list.filter(func(d: Dictionary) -> bool: return d.stud != key)


static func mass(list: Array) -> float:
	var m := 0.0
	for d: Dictionary in list:
		m += BRICK_MASS if d.kind == "brick" else PLATE_MASS
	return m


## The box a brick takes on `stud`, in the part's frame.
static func brick_box(stud: Dictionary, kind: String, pitch: float) -> AABB:
	var h: float = KINDS[kind] * pitch
	var up: Vector3 = stud.up
	var centre: Vector3 = stud.at + up * h * 0.5
	var half := Vector3.ONE * pitch * 0.5
	half += up.abs() * (h * 0.5 - pitch * 0.5)
	return AABB(centre - half, half * 2.0)


## Draw `list` on `part`: a "Dressing" node of bricks. Bricks whose stud the part no longer
## has (a newer rev moved it) are left off; their keys come back.
static func apply(part: Node3D, list: Array) -> Array:
	var old := part.get_node_or_null(^"Dressing")
	if old != null:
		part.remove_child(old)
		old.queue_free()
	var s := studs(part)
	var by_key := {}
	for st in s.studs:
		by_key[st.key] = st
	var holder := Node3D.new()
	holder.name = "Dressing"
	part.add_child(holder)
	var left_off := []
	for d: Dictionary in list:
		if not by_key.has(d.stud) or not KINDS.has(String(d.kind)):
			left_off.append(d.stud)
			continue
		var box := brick_box(by_key[d.stud], String(d.kind), s.pitch)
		var mi := MeshInstance3D.new()
		mi.name = "Brick_%d" % holder.get_child_count()
		var bm := BoxMesh.new()
		bm.size = box.size * 0.96
		mi.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = BrickWorld.get_material_colour(0, int(d.colour)) if ClassDB.class_has_method(
				"BrickWorld", "get_material_colour") else Color.from_hsv(float(d.colour) / COLOURS, 0.6, 0.9)
		mi.material_override = mat
		mi.position = box.get_center()
		mi.set_meta(&"stud", d.stud)
		holder.add_child(mi)
	return left_off


## Knock up to `count` dressing bricks off `part` as debris into `world` (falling bodies that
## go after `life` seconds). How many came off.
static func shed(part: Node3D, count: int, world: Node, life: float = 8.0) -> int:
	var holder := part.get_node_or_null(^"Dressing")
	if holder == null or world == null:
		return 0
	var n := 0
	for mi in holder.get_children():
		if n >= count:
			break
		var at: Transform3D = (mi as Node3D).global_transform if (mi as Node3D).is_inside_tree() \
				else (mi as Node3D).transform
		holder.remove_child(mi)
		var body := RigidBody3D.new()
		body.name = "DressingDebris"
		body.collision_layer = 0
		body.collision_mask = 1
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = ((mi as MeshInstance3D).mesh as BoxMesh).size
		shape.shape = bs
		body.add_child(shape)
		body.add_child(mi)
		(mi as Node3D).transform = Transform3D.IDENTITY
		world.add_child(body)
		body.global_transform = at
		body.linear_velocity = (at.basis.y + Vector3(randf_range(-1, 1), 1.0, randf_range(-1, 1))).normalized() * 4.0
		world.get_tree().create_timer(life).timeout.connect(body.queue_free)
		n += 1
	return n


# --- what the player owns --------------------------------------------------------

## {owner: {part id: [bricks]}} from the store.
static func load_store(path: String = STORE) -> Dictionary:
	var t := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var d = JSON.parse_string(t) if t != "" else null
	if not d is Dictionary:
		return {}
	# JSON reads every number back as a float: a colour is a whole one.
	for owner in d:
		for id in (d[owner] as Dictionary):
			for b in d[owner][id]:
				if b is Dictionary and b.has("colour"):
					b.colour = int(b.colour)
	return d


static func save_store(store: Dictionary, path: String = STORE) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(store, "\t"))
	return OK


static func of(store: Dictionary, owner: String, part_id: String) -> Array:
	return ((store.get(owner, {}) as Dictionary).get(part_id, []) as Array).duplicate(true)


static func put(store: Dictionary, owner: String, part_id: String, list: Array) -> void:
	var mine: Dictionary = store.get_or_add(owner, {})
	if list.is_empty():
		mine.erase(part_id)
	else:
		mine[part_id] = list.duplicate(true)


## Every part of mech `m` that is a part (has a part id): {id: node}.
static func parts_of(m: Mech) -> Dictionary:
	var out := {}
	for n: Node3D in [m.legs, m.torso, m.arm]:
		if n == null:
			continue
		for c in n.find_children("*", "Node3D", true, false):
			if c.has_meta(&"part_id") and not c.get_parent().has_meta(&"part_id"):
				out[String(c.get_meta(&"part_id"))] = c
	return out


## Dress every part of mech `m` as `owner` has them. How many bricks went on.
static func dress_mech(m: Mech, owner: String, store: Dictionary) -> int:
	var n := 0
	var parts := parts_of(m)
	for id: String in parts:
		var list := of(store, owner, id)
		if not list.is_empty():
			n += list.size() - apply(parts[id], list).size()
	return n


static func _chain(n: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c := n
	while c != null and c != root:
		t = (c as Node3D).transform * t
		c = c.get_parent()
	return t


static func _joints(part: Node3D) -> Array:
	var out := []
	for c in part.find_children("*", "Node3D", true, false):
		var nm := String(c.name)
		if nm == "mount" or nm.begins_with("socket_"):
			out.append(_chain(c, part).origin)
	return out


static func _box_distance(box: AABB, p: Vector3) -> float:
	var q := p.clamp(box.position, box.end)
	return q.distance_to(p)


static func _bounds(part: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in part.find_children("*", "MeshInstance3D", true, false):
		if mi.get_parent() != null and String(mi.get_parent().name) == "Dressing":
			continue
		var m := (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var b := _chain(mi, part) * m.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out
