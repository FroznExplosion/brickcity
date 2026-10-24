class_name AssetPlacements
extends RefCounted

## Furniture and items placed into a build: what a room keeps is WHERE, not the
## bricks. Docs/AssetWorkshop.md, "Furniture and items".
##
## A build's `placements` (BuildRecipe) are {"asset": catalogue id, "cell":
## [x, y, z], "turn": 0-3}: the turned asset's min corner on that cell of the
## build's frame-0 grid. The bricks come from the asset's file when the build is
## laid (`expand`), the same reference generated rooms make to authored items
## (Docs/Workshop.md section 0): edit a chair, and every room it stands in that
## is laid afresh has the new chair.

## (id, turn) -> {"mesh": ArrayMesh or null, "studs": PackedFloat32Array}
static var _meshes := {}


## A placement record.
static func make(asset: String, cell: Vector3i, turn: int) -> Dictionary:
	return {"asset": asset, "cell": [cell.x, cell.y, cell.z], "turn": posmod(turn, 4)}


static func cell_of(p: Dictionary) -> Vector3i:
	return BuildRecipe.cell_from(p.cell)


## Part rows of an asset turned (RoomManifest's item rows), [] if unknown.
static func parts(asset: String, turn: int) -> Array:
	var type := RoomTemplates.item_type(asset, turn)
	return RoomTemplates.parts(type) if type != "" else []


## The turned asset's box in cells, from its min corner.
static func size_of(asset: String, turn: int) -> Vector3i:
	var hi := Vector3i.ZERO
	for p: Array in parts(asset, turn):
		var at: Vector3i = p[1]
		var s := BuildRecipe.part_size(str(p[0]))
		hi = Vector3i(maxi(hi.x, at.x + s.x), maxi(hi.y, at.y + s.y), maxi(hi.z, at.z + s.z))
	return hi


## Every cell a placed asset fills (whole part boxes).
static func cells_of(asset: String, turn: int, at: Vector3i) -> Array:
	var out := []
	for p: Array in parts(asset, turn):
		var o: Vector3i = at + (p[1] as Vector3i)
		var s := BuildRecipe.part_size(str(p[0]))
		for x in s.x:
			for y in s.y:
				for z in s.z:
					out.append(o + Vector3i(x, y, z))
	return out


## The build with its placements as bricks, appended after its own so no block
## id of its own moves (block id is the damage contract): Interior for
## furniture, Detail for an item, the author's colours and materials. What the
## city lays (BuildingRegistry.register_build). A build with no placements is
## handed back as it is; otherwise a copy, with no placements left in it.
static func expand(r: BuildRecipe) -> BuildRecipe:
	if r.placements.is_empty():
		return r
	var out := BuildRecipe.from_dict(r.to_dict())
	out.placements = []
	for p: Dictionary in r.placements:
		var rows := parts(str(p.asset), int(p.turn))
		if rows.is_empty():
			push_warning("[furnish] '%s' is not in the catalogue; left out" % p.asset)
			continue
		var at := cell_of(p)
		for row: Array in rows:
			var colour := int(row[4]) if row.size() > 4 and int(row[4]) >= 0 else 4
			out.add(str(row[0]), at + (row[1] as Vector3i), colour, 0,
					int(row[3]) if row.size() > 3 else BuildRecipe.Role.INTERIOR,
					int(row[5]) if row.size() > 5 else 0)
	return out


## The asset drawn, its min corner at the node's origin: its bricks through
## `material` (the host's brick material, or a ghost's) and its studs through
## `stud_material` (the same when not given). A ghost casts no shadow. Meshed
## once per (asset, turn).
static func node_for(asset: String, turn: int, material: Material = null,
		stud_material: Material = null, ghost := false) -> Node3D:
	var key := "%s@%d" % [asset, posmod(turn, 4)]
	if not _meshes.has(key):
		_meshes[key] = _mesh(asset, turn)
	var m: Dictionary = _meshes[key]
	var root := Node3D.new()
	root.name = "Furnish_" + asset.validate_node_name()
	if m.mesh == null:
		return root
	var mi := MeshInstance3D.new()
	mi.mesh = m.mesh
	mi.material_override = material
	if ghost:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	var studs: PackedFloat32Array = m.studs
	@warning_ignore("integer_division")
	var n := studs.size() / 16
	if n > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = PieceMeshes.stud()
		mm.instance_count = n
		mm.set_buffer(studs)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = stud_material if stud_material != null else material
		if ghost:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)
	return root


## Forget the meshes (an asset was saved again).
static func forget_meshes() -> void:
	_meshes.clear()


static func _mesh(asset: String, turn: int) -> Dictionary:
	var rows := parts(asset, turn)
	if rows.is_empty():
		return {"mesh": null, "studs": PackedFloat32Array()}
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, size_of(asset, turn) + Vector3i.ONE)
	for row: Array in rows:
		if not pal.has(str(row[0])):
			continue
		var colour := int(row[4]) if row.size() > 4 and int(row[4]) >= 0 else 4
		var id := w.place_block(c, row[1] as Vector3i, pal[str(row[0])], colour)
		if id >= 0 and row.size() > 5 and int(row[5]) != 0:
			w.set_block_material(c, id, int(row[5]))
	var arrays := w.build_chunk_chamfer_mesh(c, BrickNear.BEVEL) if BrickNear.enabled \
			else w.build_chunk_mesh(c)
	var mesh: ArrayMesh = null
	if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": mesh, "studs": w.get_chunk_studs(c)}
