class_name OutdoorProps
extends Node3D

## Furniture and items placed OUTSIDE buildings in a game world: a bench in a
## park, a crate on a roof. Docs/AssetWorkshop.md, "Furniture and items".
##
## Inside a building a piece rides the building's own machinery (its room, its
## storey group's drawing, its bricks when hit). Out here there is no building,
## so a prop is cheap until something touches it:
##
##   drawn     one MultiMesh per (asset, turn) per TILE metres of ground, with
##             Godot's visibility range as the LOD: furniture to FURNITURE_RANGE,
##             items to ITEM_RANGE (InteriorGroups' ranges), faded over a band.
##             A hundred benches in a park are one draw call per tile.
##   solid     one box per prop in a static body per tile, on Layers.WORLD: it
##             is walked on, stood on and aimed at.
##   bricks    when a blast reaches it (`promote_near`): it becomes a small build
##             of its own (`promote`, the scene's `make_build`), ordinary brick
##             destruction from then on -- the same one-way step a room's piece
##             takes when it is shot (Interiors.md 8.4).

const TILE := 16.0
const FURNITURE_RANGE := 60.0
const ITEM_RANGE := 20.0
const FADE_BAND := 6.0

## `func(recipe: BuildRecipe, xform: Transform3D) -> int`: register a build
## and index it as the city does a placed build. Returns its id or -1.
var make_build := Callable()

## Each prop: {"asset", "turn", "cell": Vector3i (world grid), "tile": Vector2i,
## "alive": bool, "build": building id once bricks}.
var props: Array = []

var _tiles := {}        ## Vector2i -> {"node": Node3D, "body": StaticBody3D, "dirty": bool}
var _material: Material
var _stud_material: Material


func setup(material: Material, stud_material: Material) -> void:
	_material = material
	_stud_material = stud_material


## Place a prop with its turned box's min corner on world cell `cell`.
## Returns its index.
func add(asset: String, turn: int, cell: Vector3i) -> int:
	var p := {"asset": asset, "turn": posmod(turn, 4), "cell": cell,
			"tile": tile_of(cell), "alive": true, "build": -1}
	props.append(p)
	_redraw_tile(p.tile)
	return props.size() - 1


## Take a prop away (not shot: picked up). Returns whether there was one.
func remove(i: int) -> bool:
	if i < 0 or i >= props.size() or not props[i].alive:
		return false
	props[i].alive = false
	_redraw_tile(props[i].tile)
	return true


static func tile_of(cell: Vector3i) -> Vector2i:
	var cs := BrickWorld.get_cell_size()
	return Vector2i(int(floor(cell.x * cs.x / TILE)), int(floor(cell.z * cs.z / TILE)))


## The prop's box in the world.
func box_of(i: int) -> AABB:
	var p: Dictionary = props[i]
	var s := AssetPlacements.size_of(str(p.asset), int(p.turn))
	return AABB(BrickWorld.grid_to_world(p.cell), BrickWorld.grid_to_world(s))


## Every world cell the live props fill.
func taken_cells() -> Dictionary:
	var out := {}
	for p: Dictionary in props:
		if p.alive:
			for c in AssetPlacements.cells_of(str(p.asset), int(p.turn), p.cell):
				out[c] = true
	return out


## Live props whose box is within `radius` of a point: [index].
func near(point: Vector3, radius: float) -> Array:
	var out := []
	for i in props.size():
		if props[i].alive and box_of(i).grow(radius).has_point(point):
			out.append(i)
	return out


## The prop a ray meets first: {index, t} or {}.
func ray(from: Vector3, dir: Vector3, reach := 200.0) -> Dictionary:
	var best := {}
	for i in props.size():
		if not props[i].alive:
			continue
		var hit = box_of(i).intersects_ray(from, dir)
		if hit == null:
			continue
		var t := from.distance_to(hit)
		if t <= reach and (best.is_empty() or t < float(best.t)):
			best = {"index": i, "t": t}
	return best


## Every prop a blast reaches becomes bricks, so the blast can break it.
## Returns the new building ids.
func promote_near(point: Vector3, radius: float) -> Array:
	var out := []
	for i in near(point, radius):
		var id := promote(i)
		if id >= 0:
			out.append(id)
	return out


## The prop as a build of its own, at its place. Its bricks are STRUCTURE: out
## here nothing else holds it up or draws it (a decorative block is outside a
## chunk's bake and body). Returns the building id, or -1.
func promote(i: int) -> int:
	var p: Dictionary = props[i]
	if not p.alive or not make_build.is_valid():
		return -1
	var r := BuildRecipe.new()
	r.kind = "item"
	r.name = str(p.asset)
	for row: Array in AssetPlacements.parts(str(p.asset), int(p.turn)):
		var colour := int(row[4]) if row.size() > 4 and int(row[4]) >= 0 else 4
		r.add(str(row[0]), row[1] as Vector3i, colour, 0, BuildRecipe.Role.STRUCTURE,
				int(row[5]) if row.size() > 5 else 0)
	if r.is_empty():
		return -1
	var id: int = make_build.call(r, Transform3D(Basis(), BrickWorld.grid_to_world(p.cell)))
	if id < 0:
		return -1
	p.alive = false
	p.build = id
	_redraw_tile(p.tile)
	print("[props] '%s' is bricks now (building %d)" % [p.asset, id])
	return id


## How many draw nodes and shapes a tile holds: for the probe.
func tile_stats(t: Vector2i) -> Dictionary:
	var tile: Dictionary = _tiles.get(t, {})
	if tile.is_empty():
		return {"drawings": 0, "shapes": 0}
	return {"drawings": (tile.node as Node3D).get_child_count(),
			"shapes": (tile.body as StaticBody3D).get_child_count()}


## Redraw one tile: a MultiMesh per (asset, turn) of its live props, a box each.
func _redraw_tile(t: Vector2i) -> void:
	var tile: Dictionary = _tiles.get(t, {})
	if tile.is_empty():
		var node := Node3D.new()
		node.name = "PropTile_%d_%d" % [t.x, t.y]
		add_child(node)
		var body := StaticBody3D.new()
		body.collision_layer = Layers.WORLD
		body.collision_mask = 0
		add_child(body)
		tile = {"node": node, "body": body}
		_tiles[t] = tile
	for holder: Node in [tile.node, tile.body]:
		for c in holder.get_children():
			holder.remove_child(c)
			c.queue_free()
	# The drawing's origin is the tile's middle: Godot measures a visibility
	# range from there.
	var centre := Vector3((t.x + 0.5) * TILE, 0.0, (t.y + 0.5) * TILE)
	var groups := {}
	for i in props.size():
		var p: Dictionary = props[i]
		if not p.alive or p.tile != t:
			continue
		var key := "%s@%d" % [p.asset, p.turn]
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(i)
		var box := box_of(i)
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = box.size
		shape.shape = bs
		shape.position = box.get_center()
		(tile.body as StaticBody3D).add_child(shape)
	for key in groups:
		var list: Array = groups[key]
		var first: Dictionary = props[list[0]]
		var item := AssetTags.type_of(AssetCatalog.entry(str(first.asset)).get("tags", {})) == AssetTags.ITEM
		var range_m := ITEM_RANGE if item else FURNITURE_RANGE
		var shape := AssetPlacements.node_for(str(first.asset), int(first.turn), _material, _stud_material)
		for child in shape.get_children():
			var gi := child as GeometryInstance3D
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			var src_studs: MultiMesh = null
			if gi is MeshInstance3D:
				mm.mesh = (gi as MeshInstance3D).mesh
				mm.instance_count = list.size()
				for k in list.size():
					var p: Dictionary = props[list[k]]
					mm.set_instance_transform(k, Transform3D(Basis(),
							BrickWorld.grid_to_world(p.cell) - centre))
			else:
				# The studs: every stud of the piece, at every prop.
				src_studs = (gi as MultiMeshInstance3D).multimesh
				mm.use_colors = true
				mm.mesh = src_studs.mesh
				var n := src_studs.instance_count
				mm.instance_count = n * list.size()
				for k in list.size():
					var p: Dictionary = props[list[k]]
					var shift := Transform3D(Basis(), BrickWorld.grid_to_world(p.cell) - centre)
					for s in n:
						mm.set_instance_transform(k * n + s, shift * src_studs.get_instance_transform(s))
						mm.set_instance_color(k * n + s, src_studs.get_instance_color(s))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = gi.material_override
			mmi.position = centre
			mmi.visibility_range_end = range_m
			mmi.visibility_range_end_margin = FADE_BAND
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			(tile.node as Node3D).add_child(mmi)
		shape.free()
