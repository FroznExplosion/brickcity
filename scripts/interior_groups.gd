class_name InteriorGroups
extends RefCounted

## What stands in a building's rooms, drawn a GROUP OF STOREYS at a time.
## [Interiors §8.2](../Docs/Interiors.md).
##
## The rungs this stands beside each have a unit and a rule of their own: a room
## drawn inside 40 m on the player's storey, an outer room faked inside 70 m for
## the whole building, a room laid as bricks at arm's length. Three rules, three
## ranges, and a seam wherever a room crosses from one to the next.
##
## Here the unit is a few storeys together and the only rule is distance:
##
##   * one drawing of every INTERIOR piece in the group -- desks, tables, beds,
##     shelves -- shown out to INTERIOR_RANGE;
##   * one drawing of its ITEMS -- the small things, `BuildRecipe.Role.DETAIL` --
##     shown out to ITEM_RANGE;
##   * both faded over a band by the shader (shaders/interior_group.gdshader),
##     so nothing appears or goes in one frame.
##
## Not one drawing for the building (user, 2026-10-06): a tower is tens of
## storeys, and one buffer for all of it is rebuilt whole for one shot and draws
## its top floor because somebody stands at its foot. A group is rebuilt alone
## when something in ITS storeys changes, and comes and goes by ITS distance.
##
## This file is the groups, what each holds and how it is drawn. Who is near
## what, and the collision boxes for what is near, are CityScene's
## (`_stream_groups`).

## Storeys to a group, at most. A storey is 2.66 m, so four is a slab of
## building 10.6 m tall: near enough to the 20 m items are shown at that a
## group's items are not drawn for a floor nobody is near.
const GROUP_STOREYS := 4
## And interior pieces to a group, about: storeys with many rooms get fewer to a
## group, down to one. Every shape in the city today has 4-6 rooms a storey
## (8-13 pieces), so all of them take GROUP_STOREYS; this is for the floor
## plates the game wants later.
const GROUP_PIECES := 300
## What a room holds on average: the manifest draws two to five, and a quarter
## of rooms are empty.
const PIECES_PER_ROOM := 3.5
## Interior pieces are shown inside this, measured to each piece. Past it a
## building that is still bricks shows its rooms empty; one that is a shell
## shows painted windows (BuildingShell.build_window_mesh), as it always has.
const INTERIOR_RANGE := 100.0
const INTERIOR_BAND := 15.0
## Items are shown inside this.
const ITEM_RANGE := 20.0
const ITEM_BAND := 5.0
## How far past INTERIOR_RANGE a group is kept before it is dropped, so one on
## the boundary is not built and dropped pass after pass. Everything in it is
## faded right out by then.
const RELEASE := 12.0
## Interior pieces cast shadows inside this and not past it: a shadow pass over
## a desk a hundred metres off is the cost the far drawing exists to avoid.
const SHADOW_RANGE := 45.0
const SHADOW_RELEASE := 55.0
## Milliseconds a pass may spend working out rooms. A room is a manifest and a
## floor check for each piece, 0.05-0.15 ms; a group is 16-24 of them.
const BUDGET_MS := 2.0


class Group:
	extends RefCounted
	var index := 0
	var first_storey := 0
	var last_storey := 0          ## one past
	var first_room := 0
	var last_room := 0            ## one past; rooms are storey-major (RoomManifest.rooms_for)
	## The storeys it covers, in the building's own space, in metres.
	var box := AABB()
	## Its drawing is on screen (and may be behind: see `dirty`).
	var shown := false
	## A room in it may have changed since it was worked out.
	var dirty := true
	## Bumped when blocks in its storeys may have changed: every piece's floor is
	## asked again (RoomManifest.item_supported).
	var struct_stamp := 0
	## Per room, what its drawing was worked out against.
	var room_stamp := PackedInt32Array()
	var room_gone := PackedInt32Array()
	var room_state := PackedByteArray()
	## Per room: MultiMesh rows for its interior pieces and its items, and one
	## box per piece in the chunk's own metres (collision, crushing).
	var pieces: Array[PackedFloat32Array] = []
	var items: Array[PackedFloat32Array] = []
	var boxes: Array = []
	## The rows have moved on since they were last put on screen.
	var changed := false
	var piece_count := 0
	var item_count := 0
	var shadows := true
	## CityScene's: its pieces have collision boxes on the building's furniture
	## body.
	var cover := false


var world: BrickWorld
var registry: BuildingRegistry

## Building id -> Array of Group, made the first time it is asked for.
var _layouts := {}
## key_of(building, group) -> MultiMeshInstance3D.
var _piece_nodes := {}
var _item_nodes := {}

var rooms_worked := 0     ## rooms worked out, all told
var attaches := 0         ## drawings put on screen or refreshed
var releases := 0
var work_ms := 0.0
var worst_attach_ms := 0.0

## Read with the script, not at the first group drawn: that was a hitch in the
## middle of walking up to a building.
const SHADER := preload("res://shaders/interior_group.gdshader")

static var _piece_material: ShaderMaterial
static var _item_material: ShaderMaterial


static func piece_material() -> ShaderMaterial:
	if _piece_material == null:
		_piece_material = ShaderMaterial.new()
		_piece_material.shader = SHADER
		_piece_material.set_shader_parameter("fade_range", INTERIOR_RANGE)
		_piece_material.set_shader_parameter("fade_band", INTERIOR_BAND)
	return _piece_material


static func item_material() -> ShaderMaterial:
	if _item_material == null:
		_item_material = ShaderMaterial.new()
		_item_material.shader = SHADER
		_item_material.set_shader_parameter("fade_range", ITEM_RANGE)
		_item_material.set_shader_parameter("fade_band", ITEM_BAND)
	return _item_material


## Have the renderer build the shader now, under `parent`, rather than under
## the first group drawn: that first drawing took 16-19 ms where every one
## after it took one or two (the `--groups` gate), in the middle of walking up
## to a building. A speck far under the world, with each material, for a few
## frames.
static func warm(parent: Node) -> void:
	for mat in [piece_material(), item_material()]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = FurnitureMesh.unit_mesh()
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis().scaled(Vector3.ONE * 0.001), Vector3.ZERO))
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.material_override = mat
		node.position = Vector3(0.0, -2000.0, 0.0)
		node.extra_cull_margin = 16384.0   # drawn wherever the camera looks
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(node)
		parent.get_tree().create_timer(1.0).timeout.connect(node.queue_free)


static func key_of(building_id: int, group: int) -> int:
	return building_id * 4096 + group


## How many storeys go in a group, for a floor of this many rooms.
static func storeys_per_group(rooms_per_storey: int) -> int:
	var per_storey := maxf(float(rooms_per_storey) * PIECES_PER_ROOM, 1.0)
	return clampi(int(float(GROUP_PIECES) / per_storey), 1, GROUP_STOREYS)


## The storey ranges a building of `storeys` storeys is cut into: as few groups
## as `span` allows, and those as even as they come -- five storeys is three and
## two, not four and a stub of one. Returns [first, one past] pairs, in order.
static func cut(storeys: int, span: int) -> Array:
	var out := []
	if storeys <= 0:
		return out
	@warning_ignore("integer_division")
	var n := (storeys + maxi(span, 1) - 1) / maxi(span, 1)
	for k in n:
		@warning_ignore("integer_division")
		out.append([k * storeys / n, (k + 1) * storeys / n])
	return out


## A building's groups. Nothing is worked out or drawn by asking.
func layout(b: BuildingRegistry.Building) -> Array:
	var have = _layouts.get(b.id)
	if have != null:
		return have
	var out: Array = []
	_layouts[b.id] = out
	if b.is_build():
		return out   # a player build's furniture is bricks in its own chunk
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var lat := RoomManifest.lattice_for(fx, fz, b.recipe.courses)
	var per: int = (lat.rects as Array).size()
	var storeys: Array = lat.storeys
	if per == 0:
		return out
	var cs := BrickWorld.get_cell_size()
	for pair in cut(storeys.size(), storeys_per_group(per)):
		var g := Group.new()
		g.index = out.size()
		g.first_storey = pair[0]
		g.last_storey = pair[1]
		g.first_room = g.first_storey * per
		g.last_room = g.last_storey * per
		var y0 := float(int(storeys[g.first_storey].floor_y)) * cs.y
		var top: Dictionary = storeys[g.last_storey - 1]
		var y1 := float(int(top.floor_y) + int(top.height)) * cs.y
		g.box = AABB(Vector3(0.0, y0, 0.0), Vector3(fx * cs.x, y1 - y0, fz * cs.z))
		out.append(g)
	return out


## The groups a building has been cut into, if it has been asked for; none
## otherwise. For whoever must not make a layout by looking.
func known(building_id: int) -> Array:
	var have = _layouts.get(building_id)
	return have if have != null else []


func known_ids() -> Array:
	return _layouts.keys()


## A room was laid as bricks or taken back out: its group draws it, or stops.
func room_changed(building_id: int, room_index: int) -> void:
	for g in known(building_id):
		if room_index >= g.first_room and room_index < g.last_room:
			g.dirty = true
			return


## Blocks between these heights (the building's own space, metres) may have
## changed: the groups there ask every piece's floor again. A floor is the slab
## UNDER a group's lowest storey, so the test reaches a little below each.
func touch(building_id: int, y_lo: float = -INF, y_hi: float = INF) -> void:
	var have = _layouts.get(building_id)
	if have == null:
		return
	for g in (have as Array):
		if g.box.position.y - 0.6 > y_hi or g.box.end.y < y_lo:
			continue
		g.struct_stamp += 1
		g.dirty = true


## Bring a group's rooms up to date, until `until_usec` (at least one room is
## always done). True once every room is; the caller then calls `attach` if
## `changed` says the drawing is behind.
##
## A room that is bricks (laid by a blast) or spilled into wreckage draws
## nothing here: its contents are in a chunk, and drawn from it.
func work(b: BuildingRegistry.Building, g: Group, until_usec: int) -> bool:
	var t0 := Time.get_ticks_usec()
	var rooms := registry.rooms_of(b.id)
	var n := g.last_room - g.first_room
	if g.room_stamp.size() != n:
		g.room_stamp.resize(n)
		g.room_stamp.fill(-1)
		g.room_gone.resize(n)
		g.room_gone.fill(-1)
		g.room_state.resize(n)
		g.room_state.fill(0)
		g.pieces.clear()
		g.items.clear()
		g.boxes.clear()
		for k in n:
			g.pieces.append(PackedFloat32Array())
			g.items.append(PackedFloat32Array())
			g.boxes.append([])
	var offset: Vector3i = registry._rebase_of(b)
	var worked := 0
	var done := true
	for k in n:
		var room: Room = rooms[g.first_room + k]
		var state := (1 if room.active else 0) | (2 if room.spilled else 0)
		if g.room_stamp[k] == g.struct_stamp and g.room_gone[k] == room.gone.size() \
				and g.room_state[k] == state:
			continue
		if worked > 0 and Time.get_ticks_usec() >= until_usec:
			done = false
			break
		worked += 1
		if state != 0:
			g.pieces[k] = PackedFloat32Array()
			g.items[k] = PackedFloat32Array()
			g.boxes[k] = []
		else:
			if room.items.is_empty():
				room.items = RoomManifest.items_for(room)
			var d := RoomManifest.draw_items(world, b.chunk, registry.palette, room, offset)
			g.pieces[k] = d.buffer
			g.items[k] = d.details
			g.boxes[k] = d.boxes
		g.room_stamp[k] = g.struct_stamp
		# After the drawing: a piece whose floor has gone is written off BY it.
		g.room_gone[k] = room.gone.size()
		g.room_state[k] = state
		g.changed = true
	rooms_worked += worked
	work_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	if done:
		g.dirty = false
	return done


## Put a group's drawing on screen under `parent` -- the node that draws the
## building's bricks, so it is in the chunk's own space -- or refresh it.
func attach(b: BuildingRegistry.Building, g: Group, parent: Node3D) -> void:
	var t0 := Time.get_ticks_usec()
	var key := key_of(b.id, g.index)
	g.piece_count = FurnitureMesh.attach_group(g.pieces, parent, _piece_nodes, key,
			piece_material())
	g.item_count = FurnitureMesh.attach_group(g.items, parent, _item_nodes, key,
			item_material())
	var items = _item_nodes.get(key)
	if items != null and is_instance_valid(items):
		(items as MultiMeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	g.shown = true
	g.changed = false
	_apply_shadows(key, g.shadows)
	attaches += 1
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	work_ms += ms
	worst_attach_ms = maxf(worst_attach_ms, ms)


## Is what `attach` made still there, and under `parent`? A building's mesh node
## is freed and made again as it leaves and re-enters mesh range, and what hung
## from it went with it.
func nodes_ok(building_id: int, g: Group, parent: Node3D) -> bool:
	var key := key_of(building_id, g.index)
	return _node_ok(_piece_nodes.get(key), g.piece_count, parent) \
			and _node_ok(_item_nodes.get(key), g.item_count, parent)


static func _node_ok(node, count: int, parent: Node3D) -> bool:
	if count == 0:
		return true
	return node != null and is_instance_valid(node) and (node as Node).get_parent() == parent


func set_shadows(building_id: int, g: Group, on: bool) -> void:
	if g.shadows == on:
		return
	g.shadows = on
	_apply_shadows(key_of(building_id, g.index), on)


func _apply_shadows(key: int, on: bool) -> void:
	var node = _piece_nodes.get(key)
	if node != null and is_instance_valid(node):
		(node as MultiMeshInstance3D).cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)


## Stop drawing one group and forget what was worked out for it.
func release(building_id: int, g: Group) -> void:
	var key := key_of(building_id, g.index)
	FurnitureMesh.drop(key, _piece_nodes)
	FurnitureMesh.drop(key, _item_nodes)
	if g.shown:
		releases += 1
	g.shown = false
	g.dirty = true
	g.changed = false
	g.piece_count = 0
	g.item_count = 0
	g.room_stamp = PackedInt32Array()
	g.room_gone = PackedInt32Array()
	g.room_state = PackedByteArray()
	g.pieces.clear()
	g.items.clear()
	g.boxes.clear()


## Everything of one building: its bricks went, or it came down.
func drop(building_id: int) -> void:
	var have = _layouts.get(building_id)
	if have == null:
		return
	for g in (have as Array):
		release(building_id, g)
	_layouts.erase(building_id)


func drop_all() -> void:
	for id in _layouts.keys():
		drop(id)


## Stop drawing, at once, everything of this building standing inside one of
## `boxes` (the chunk's own space): a section that has just left it. The groups
## that held any are worked out again from what is left. See
## FurnitureMesh.hide_inside. Returns how many boxes it hid.
func hide_inside(building_id: int, boxes: Array[AABB]) -> int:
	var have = _layouts.get(building_id)
	if have == null:
		return 0
	var hidden := 0
	for g in (have as Array):
		if not g.shown:
			continue
		var key := key_of(building_id, g.index)
		var n := FurnitureMesh.hide_inside(_piece_nodes, key, boxes) \
				+ FurnitureMesh.hide_inside(_item_nodes, key, boxes)
		if n > 0:
			g.struct_stamp += 1
			g.dirty = true
		hidden += n
	return hidden


func piece_node(building_id: int, group: int) -> MultiMeshInstance3D:
	var node = _piece_nodes.get(key_of(building_id, group))
	return node if node != null and is_instance_valid(node) else null


func item_node(building_id: int, group: int) -> MultiMeshInstance3D:
	var node = _item_nodes.get(key_of(building_id, group))
	return node if node != null and is_instance_valid(node) else null


## What is on screen, for the HUD and the reports.
func report() -> Dictionary:
	var groups := 0
	var pieces := 0
	var items := 0
	var buildings := 0
	for id in _layouts:
		var any := false
		for g in (_layouts[id] as Array):
			if g.shown:
				groups += 1
				pieces += g.piece_count
				items += g.item_count
				any = true
		if any:
			buildings += 1
	return {"groups": groups, "buildings": buildings, "piece_boxes": pieces,
			"item_boxes": items, "rooms_worked": rooms_worked, "attaches": attaches,
			"releases": releases, "work_ms": work_ms, "worst_attach_ms": worst_attach_ms}
