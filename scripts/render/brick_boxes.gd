class_name BrickBoxes
extends RefCounted

## A band of bricks drawn as a box a brick (Docs/HandoffPerf.md 8): one
## MultiMesh, a child `Boxes` of the band's node, a UNIT box an instance
## scaled to its brick (BrickWorld.get_instance_buffers; the brick shader
## works the face out from the scale, shaders/brick_boxed.gdshaderinc). No
## bake, no mesh job, no upload.
##
## What a band is drawn from is kept ON its node (its stamps, below), so a
## band goes on being refreshed by whoever holds it: the city for a building
## (CityDrawing), the pieces' manager once the building has toppled
## (IslandManager). Both ask `changed` which bands to fill again and `fill`
## them.
##
## A part that is not a true box (a slope, a round brick, a stair) is drawn by
## its own faces, on the band node's own mesh, made with the band's buffer and
## again only when one of those parts goes.

const BOXES := ^"Boxes"
## A band node's stamps: which bricks its boxes were filled from, and which of
## its parts that are not boxes its own mesh was made from (0: none made).
const STAMP := &"box_stamp"
const SPECIAL := &"box_special"
## On the Boxes node: the bounds of what it draws, in the band's space.
const BOUNDS := &"box"
## Floats an instance: a 3x4 transform, a colour, the brick's centre.
const STRIDE := 20

static var _unit_box_mesh: ArrayMesh = null
## For a report: fills, instances written, vertices of faces made for parts
## that are not boxes, fills that kept the faces they had.
static var fills := 0
static var instances := 0
static var special_verts := 0
static var special_kept := 0
static var specials := 0


## A unit box, centred, marked for the brick shader by its UV2 (0, -1): the
## shader works the face rectangle out from the instance's scale
## (brick_boxed.gdshaderinc). White, for the instance's colour to tint.
static func unit_box() -> ArrayMesh:
	if _unit_box_mesh != null:
		return _unit_box_mesh
	var both := unit_box_points()
	var verts: PackedVector3Array = both[0]
	var norms: PackedVector3Array = both[1]
	var uv2s := PackedVector2Array()
	var cols := PackedColorArray()
	for k in verts.size():
		uv2s.append(Vector2(0.0, -1.0))
		cols.append(Color.WHITE)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols
	_unit_box_mesh = ArrayMesh.new()
	_unit_box_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _unit_box_mesh


## The unit box's 36 corners and their normals, in drawing order (a gate lays
## the same triangles under its rays: tools/city_passes.gd, _boxes_tri_mesh).
static func unit_box_points() -> Array:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var faces := [
		[Vector3.RIGHT, Vector3.BACK, Vector3.UP], [Vector3.LEFT, Vector3.FORWARD, Vector3.UP],
		[Vector3.UP, Vector3.RIGHT, Vector3.BACK], [Vector3.DOWN, Vector3.RIGHT, Vector3.FORWARD],
		[Vector3.BACK, Vector3.LEFT, Vector3.UP], [Vector3.FORWARD, Vector3.RIGHT, Vector3.UP],
	]
	for f in faces:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var pts := [n * 0.5 - u * 0.5 - v * 0.5, n * 0.5 + u * 0.5 - v * 0.5,
				n * 0.5 + u * 0.5 + v * 0.5, n * 0.5 - u * 0.5 + v * 0.5]
		# Clockwise seen from outside (Godot's front), as IslandStandins._box.
		var order := [0, 2, 1, 0, 3, 2] if u.cross(v).dot(n) > 0.0 else [0, 1, 2, 0, 2, 3]
		for k in order:
			verts.append(pts[k])
			norms.append(n)
	return [verts, norms]


## A band's boxes, or null.
static func of(band: Node) -> MultiMeshInstance3D:
	if band == null or not is_instance_valid(band):
		return null
	return band.get_node_or_null(BOXES) as MultiMeshInstance3D


## Whether any of `bands` is drawn as boxes.
static func any(bands: Array) -> bool:
	for band in bands:
		if of(band as Node) != null:
			return true
	return false


## The bounds of a band's boxes, in the band's space (an empty box: none).
static func bounds_of(band: Node) -> AABB:
	var boxes := of(band)
	if boxes == null or not boxes.has_meta(BOUNDS):
		return AABB()
	return boxes.get_meta(BOUNDS)


static func _stamp(band: Variant, key: StringName) -> int:
	if band == null or not is_instance_valid(band) or not (band as Node).has_meta(key):
		return 0
	return int((band as Node).get_meta(key))


## The stamps `bands` hold of their parts that are not boxes, one a slot (for
## BrickWorld.get_instance_buffers, asked for every section).
static func special_held(bands: Array) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(bands.size())
	for s in bands.size():
		out[s] = _stamp(bands[s], SPECIAL)
	return out


## The sections of `chunk` whose bricks are not the ones their band was filled
## from, as BrickWorld.get_instance_buffers gives them: for the owner to
## `fill`. A slot with no node counts as holding nothing. An empty array when
## `bands` is not a band a section (the owner lays them out again).
static func changed(world: BrickWorld, chunk: int, bands: Array) -> Array:
	var stamps: PackedInt64Array = world.get_section_stamps(chunk)
	if stamps.size() != bands.size():
		return []
	var sections := PackedInt32Array()
	var held := PackedInt64Array()
	for s in stamps.size():
		if stamps[s] != _stamp(bands[s], STAMP):
			sections.append(s)
			held.append(_stamp(bands[s], SPECIAL))
	if sections.is_empty():
		return []
	return world.get_instance_buffers(chunk, sections, held)


## Stamps that ask get_instance_buffers for no faces at all (-1 a section):
## for a whole building's buffers in one call. Each band's entry then goes
## through `with_special` before it is filled.
static func special_none(sections: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(sections)
	out.fill(-1)
	return out


## An entry made with no faces (special_none), given the faces of its band's
## parts that are not boxes: the ones `node` has when they are still the same
## parts, else baked now, for this band alone. A building's stairs are most
## of what filling it costs (12.7 ms of one tick for a 27,000-brick tower,
## all its bands' in one call); a band at a time they fit the bands' budget.
static func with_special(world: BrickWorld, chunk: int, node: Variant, entry: Dictionary) -> Dictionary:
	if not bool(entry.get("special_skipped", false)):
		return entry
	if node != null and is_instance_valid(node) and (node as MeshInstance3D).mesh != null \
			and _stamp(node, SPECIAL) == int(entry.special_stamp):
		entry["special_same"] = true
		return entry
	var one: Array = world.get_instance_buffers(chunk, PackedInt32Array([int(entry.section)]),
			PackedInt64Array([0]))
	if not one.is_empty():
		entry["special"] = (one[0] as Dictionary).special
		entry["special_stamp"] = (one[0] as Dictionary).special_stamp
	entry["special_same"] = false
	return entry


## Fill a band's node from its section's `entry` (get_instance_buffers): its
## boxes, the faces of its parts that are not boxes, its stamps. `retire` is
## handed a mesh the node no longer draws. Returns the boxes' node.
static func fill(node: MeshInstance3D, entry: Dictionary, material: Material,
		retire: Callable) -> MultiMeshInstance3D:
	node.set_meta(STAMP, int(entry.stamp))
	# The parts that are not boxes: kept while none of them has gone.
	if bool(entry.get("special_same", false)) and node.mesh != null:
		special_kept += 1
	else:
		if node.mesh != null:
			if retire.is_valid():
				retire.call(node.mesh)
			node.mesh = null
		var special: Array = entry.get("special", [])
		if not special.is_empty():
			var sm := ArrayMesh.new()
			sm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, special)
			node.mesh = sm
			special_verts += (special[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		# Nothing made though the stamp matched (the mesh has gone since):
		# asked for again next time.
		node.set_meta(SPECIAL, 0 if bool(entry.get("special_same", false))
				else int(entry.get("special_stamp", 0)))
	var mmi := of(node)
	if mmi == null:
		mmi = _new_boxes(node, material)
		var made := MultiMesh.new()
		made.transform_format = MultiMesh.TRANSFORM_3D
		made.use_colors = true
		made.use_custom_data = true
		made.mesh = unit_box()
		mmi.multimesh = made
	var buf: PackedFloat32Array = entry.buffer
	@warning_ignore("integer_division")
	var n := buf.size() / STRIDE
	var mm := mmi.multimesh
	if mm.instance_count != n:
		mm.instance_count = n
	if n > 0:
		mm.buffer = buf
	var box: AABB = entry.aabb
	mm.custom_aabb = box
	mmi.set_meta(BOUNDS, box)
	mmi.visible = int(entry.alive) > 0
	fills += 1
	instances += n
	specials += int(entry.authored)
	return mmi


## A band's boxes drawn by another node as well: `to` gets a Boxes of its own
## on the SAME MultiMesh (a resource backs any number of instances, so nothing
## is copied), and `from`'s stamps. For a toppled building, whose bands the
## piece draws from new nodes while the building's own go on drawing for a
## frame or two (IslandManager.adopt).
static func share(from: MeshInstance3D, to: MeshInstance3D) -> void:
	var src := of(from)
	if src == null or src.multimesh == null:
		return
	var mmi := _new_boxes(to, src.material_override)
	# Plain again: whoever bevels it next starts from the plain box.
	if src.multimesh.mesh != unit_box():
		src.multimesh.mesh = unit_box()
	mmi.multimesh = src.multimesh
	mmi.visible = src.visible
	if src.has_meta(BOUNDS):
		mmi.set_meta(BOUNDS, src.get_meta(BOUNDS))
	for key in [STAMP, SPECIAL]:
		if from.has_meta(key):
			to.set_meta(key, from.get_meta(key))


static func _new_boxes(node: MeshInstance3D, material: Material) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Boxes"
	mmi.material_override = material
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	mmi.cast_shadow = node.cast_shadow
	for param in [&"weather_snowcap", &"grain_origin", &"grid_light"]:
		var v: Variant = InstanceParams.of(node, param)
		if v != null:
			InstanceParams.put(mmi, param, v)
	node.add_child(mmi)
	return mmi


## Instances of a buffer that draw anything: a dead brick's is a zero matrix.
static func live_in(buf: PackedFloat32Array) -> int:
	var live := 0
	for i in range(0, buf.size() - STRIDE + 1, STRIDE):
		if buf[i] > 0.0:
			live += 1
	return live
