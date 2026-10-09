class_name InteriorGroups
extends RefCounted

## What stands in a building's rooms, drawn a GROUP OF STOREYS at a time.
## [Interiors §8.2](../Docs/Interiors.md).
##
## What this replaced (the "rungs", removed 2026-10-08) had a unit and a rule
## each: a room drawn inside 40 m on the player's storey, an outer room faked
## inside 70 m for the whole building, a room laid as bricks at arm's length.
## Three rules, three ranges, and a seam wherever a room crossed from one to
## the next.
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
	## asked again (RoomManifest.item_floor_share).
	var struct_stamp := 0
	## Per room, what its drawing was worked out against.
	var room_stamp := PackedInt32Array()
	var room_gone := PackedInt32Array()
	## Per room: MultiMesh rows for its interior pieces and its items, and one
	## box per piece in the chunk's own metres (collision, crushing).
	var pieces: Array[PackedFloat32Array] = []
	var items: Array[PackedFloat32Array] = []
	var boxes: Array = []
	## Per room, which rows are whose (RoomManifest.draw_items' `pieces`), and
	## where each room's rows start in the two drawings as they were last put
	## on screen.
	var piece_rows: Array = []
	var room_row0 := PackedInt32Array()
	var room_item0 := PackedInt32Array()
	## The rows have moved on since they were last put on screen.
	var changed := false
	## Its boxes have changed since CityScene last gave them collision.
	var cover_stale := false
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
var checks := 0           ## times pieces were asked for their floors (check_floors)
var check_ms := 0.0
var pieces_lost := 0      ## groups that lost a piece to one
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


## Something in a room changed -- a piece written off, or laid as bricks: its
## group draws the room again.
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
		g.pieces.clear()
		g.items.clear()
		g.boxes.clear()
		g.piece_rows.clear()
		for k in n:
			g.pieces.append(PackedFloat32Array())
			g.items.append(PackedFloat32Array())
			g.boxes.append([])
			g.piece_rows.append(PackedInt32Array())
	var offset: Vector3i = registry._rebase_of(b)
	var worked := 0
	var done := true
	for k in n:
		var room: Room = rooms[g.first_room + k]
		if g.room_stamp[k] == g.struct_stamp and g.room_gone[k] == room.diff_stamp():
			continue
		if worked > 0 and Time.get_ticks_usec() >= until_usec:
			done = false
			break
		worked += 1
		if room.items.is_empty():
			room.items = RoomManifest.items_for(room)
		var d := RoomManifest.draw_items(world, b.chunk, registry.palette, room, offset)
		g.pieces[k] = d.buffer
		g.items[k] = d.details
		g.boxes[k] = d.boxes
		g.piece_rows[k] = d.pieces
		g.cover_stale = true
		g.room_stamp[k] = g.struct_stamp
		g.room_gone[k] = room.diff_stamp()
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
		if not (items as Node).is_in_group(DebugView.GROUP_ITEMS):
			DebugView.tag(items as MultiMeshInstance3D, DebugView.Kind.ITEMS)
	g.shown = true
	g.changed = false
	# Where each room's rows are in what is now on screen (check_floors).
	g.room_row0.resize(g.pieces.size())
	g.room_item0.resize(g.pieces.size())
	var at := 0
	var item_at := 0
	for k in g.pieces.size():
		g.room_row0[k] = at
		g.room_item0[k] = item_at
		@warning_ignore("integer_division")
		at += g.pieces[k].size() / FurnitureMesh.STRIDE
		@warning_ignore("integer_division")
		item_at += g.items[k].size() / FurnitureMesh.STRIDE
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
	g.pieces.clear()
	g.items.clear()
	g.boxes.clear()
	g.piece_rows.clear()
	g.room_row0 = PackedInt32Array()
	g.room_item0 = PackedInt32Array()


## Everything of one building: its bricks went, or it came down.
func drop(building_id: int) -> void:
	var have = _layouts.get(building_id)
	if have == null:
		return
	for g in (have as Array):
		release(building_id, g)
	_layouts.erase(building_id)


## Ask every piece of the shown groups between two heights (the building's
## own space) whether a brick is still under it -- now, the tick its floor was
## destroyed or left. [Interiors §8.3](../Docs/Interiors.md).
##
## A piece that no longer has most of its floor here (RoomManifest.
## item_floor_share) is out of both drawings at once: its rows are scaled to
## nothing where they are, so nothing else in the drawing moves and nothing is
## worked out again. It is NOT written off in its room's record: its floor may
## have left as a piece of the building, and then it is on that piece (the
## rider this hands back, and `piece_work` once the piece is still). Each is returned
## as {group, room, item, rows, details, box} -- the rows it was drawn with, in
## the building chunk's own space -- for whoever shows what became of it (it
## rides the section that took its floor: CityScene._groups_floor_went).
##
## This is §8.3's "one index, block id -> pieces" without the index. A storey
## group is thirty or forty pieces, so asking each "is there a brick under you"
## is a few dozen grid reads, 30-60 microseconds a group; an index would be
## looked up once for every brick that left, and a section is thousands.
func check_floors(b: BuildingRegistry.Building, y_lo: float, y_hi: float) -> Array:
	var out: Array = []
	var have = _layouts.get(b.id)
	if have == null:
		return out
	var t0 := Time.get_ticks_usec()
	var rooms := registry.rooms_of(b.id)
	var offset: Vector3i = registry._rebase_of(b)
	for g in (have as Array):
		if not g.shown or g.piece_rows.is_empty():
			continue
		if g.box.position.y - 0.6 > y_hi or g.box.end.y < y_lo:
			continue
		var lost := false
		for k in g.piece_rows.size():
			var mine: PackedInt32Array = g.piece_rows[k]
			if mine.is_empty():
				continue
			var room: Room = rooms[g.first_room + k]
			var room_lost := false
			for j in range(0, mine.size(), 6):
				var i := mine[j]
				if room.gone.has(i) or room.laid.has(i) or (mine[j + 2] == 0 and mine[j + 4] == 0):
					continue   # gone, bricks now, or taken out by an earlier asking
				var item: Dictionary = room.items[i]
				if RoomManifest.item_floor_share(world, b.chunk, str(item.type),
						(item.cell as Vector3i) - offset) > 0.5:
					continue
				var box := AABB()
				if mine[j + 5] >= 0:
					box = g.boxes[k][mine[j + 5]]
					g.boxes[k][mine[j + 5]] = AABB()   # no box: no collision
				out.append({"group": g, "room": g.first_room + k, "item": i,
						"rows": _take_rows(g.pieces, k, mine[j + 1], mine[j + 2]),
						"details": _take_rows(g.items, k, mine[j + 3], mine[j + 4]),
						"box": box})
				# No rows any more: the mark that it has been taken out.
				mine[j + 2] = 0
				mine[j + 4] = 0
				room_lost = true
			if room_lost:
				g.piece_rows[k] = mine
				lost = true
		if lost:
			pieces_lost += 1
			g.cover_stale = true
			if g.changed:
				continue   # a newer drawing is owed already: it has them out
			var key := key_of(b.id, g.index)
			_rewrite(_piece_nodes.get(key), g.pieces)
			_rewrite(_item_nodes.get(key), g.items)
	checks += 1
	check_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	return out


## Rows [first, first + count) of one room's buffer, copied out; the originals
## are scaled to nothing.
static func _take_rows(buffers: Array[PackedFloat32Array], k: int, first: int,
		count: int) -> PackedFloat32Array:
	if count <= 0:
		return PackedFloat32Array()
	var buffer: PackedFloat32Array = buffers[k]
	var taken := buffer.slice(first * FurnitureMesh.STRIDE, (first + count) * FurnitureMesh.STRIDE)
	for r in range(first, first + count):
		var at := r * FurnitureMesh.STRIDE
		for f in [0, 1, 2, 4, 5, 6, 8, 9, 10]:
			buffer[at + f] = 0.0
	buffers[k] = buffer
	return taken


## Put a group's rows, as they now are, back into the drawing that shows them.
## Same rows in the same places, so the instance count does not change.
static func _rewrite(node, buffers: Array[PackedFloat32Array]) -> void:
	if node == null or not is_instance_valid(node):
		return
	var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
	var buffer := PackedFloat32Array()
	for b in buffers:
		buffer.append_array(b)
	if mm == null or buffer.size() != mm.instance_count * FurnitureMesh.STRIDE:
		return
	mm.buffer = buffer
	(node as MultiMeshInstance3D).set_meta(&"buffer", buffer)


func piece_node(building_id: int, group: int) -> MultiMeshInstance3D:
	var node = _piece_nodes.get(key_of(building_id, group))
	return node if node != null and is_instance_valid(node) else null


func item_node(building_id: int, group: int) -> MultiMeshInstance3D:
	var node = _item_nodes.get(key_of(building_id, group))
	return node if node != null and is_instance_valid(node) else null


# ---------------------------------------------------------------------------
# Pieces: what a fallen part of a building carries
# ---------------------------------------------------------------------------

## The interior of one PIECE of a building: every item of the building whose
## floor is mostly in that piece's chunk, drawn on the piece.
## [Interiors §8.3](../Docs/Interiors.md), the other half.
##
## An item is on whichever chunk holds its floor. For the standing building
## that is a storey group; for a piece that has come off it -- a section lying
## in the street, a tower gone over whole -- it is this, worked out by the same
## question asked of the piece's chunk instead (RoomManifest.draw_items takes
## any chunk, and a piece keeps the building's cells). So a collapsed building
## is not empty: what stood on a floor is still on that floor, wherever the
## floor ended up and whichever way up, whether or not anybody watched it fall.
##
## It is a drawing, not bricks: it holds nothing and collides with nothing.
## CityScene decides which pieces get one (`_stream_pieces`): still ones, near
## the player -- nothing is made for wreckage nobody is near, or still moving.
class PieceDraw:
	extends RefCounted
	var chunk := -1
	var owner := -1
	## The owner's rooms whose floors reach into the piece's box, and how far
	## through them the working out has got.
	var rooms := PackedInt32Array()
	var cursor := 0
	var pieces: Array[PackedFloat32Array] = []
	var items: Array[PackedFloat32Array] = []
	var shown := false
	var dirty := true
	## The piece's own count of changes (BrickIsland.edits) when it was drawn,
	## and how many live bricks it had: not everything that takes bricks off a
	## piece counts as an edit (a drawing was ten boxes ahead of its piece once,
	## the edit count unmoved), so CityScene counts them again now and then.
	var edits := -1
	var alive := -1
	## The sum of its rooms' `gone` counts when it was drawn: something crushed
	## or blasted since shows as that moving on.
	var gone_sum := -1
	var boxes := 0


var _piece_draws := {}        ## piece chunk -> PieceDraw
var _piece_nodes_p := {}      ## piece chunk -> MultiMeshInstance3D, interior pieces
var _piece_nodes_i := {}      ## piece chunk -> MultiMeshInstance3D, items
var pieces_drawn := 0         ## piece drawings put up, all told


func piece(chunk: int) -> PieceDraw:
	return _piece_draws.get(chunk)


func piece_chunks() -> Array:
	return _piece_draws.keys()


## How many items of a piece's rooms are written off, all told, now.
func piece_gone_sum(p: PieceDraw) -> int:
	var rooms := registry.rooms_of(p.owner)
	var n := 0
	for index in p.rooms:
		n += (rooms[index] as Room).diff_stamp()
	return n


func piece_drop(chunk: int) -> void:
	FurnitureMesh.drop(chunk, _piece_nodes_p)
	FurnitureMesh.drop(chunk, _piece_nodes_i)
	_piece_draws.erase(chunk)


## Work out one piece's interior, until `until_usec` (a room is always done),
## and put it on screen under `parent` -- the piece's own node -- once every
## room is. `lo`..`hi` is the piece's box in cells (the building's grid).
## True when it is drawn and up to date.
func piece_work(b: BuildingRegistry.Building, chunk: int, lo: Vector3i, hi: Vector3i,
		edits: int, parent: Node3D, until_usec: int, alive: int = -1) -> bool:
	var t0 := Time.get_ticks_usec()
	var p: PieceDraw = _piece_draws.get(chunk)
	if p == null:
		p = PieceDraw.new()
		p.chunk = chunk
		p.owner = b.id
		_piece_draws[chunk] = p
	var rooms := registry.rooms_of(b.id)
	if p.dirty or p.edits != edits or (alive >= 0 and p.alive != alive):
		p.dirty = false
		p.edits = edits
		p.alive = alive
		p.cursor = 0
		p.pieces.clear()
		p.items.clear()
		p.rooms = PackedInt32Array()
		for room in rooms:
			# Its FLOOR is the cell under it; its plan is its own box.
			if room.lo.y - 1 < lo.y or room.lo.y - 1 >= hi.y:
				continue
			if room.lo.x >= hi.x or room.lo.x + room.size.x <= lo.x \
					or room.lo.z >= hi.z or room.lo.z + room.size.z <= lo.z:
				continue
			p.rooms.push_back(room.id)
	var offset: Vector3i = registry._rebase_of(b)
	var worked := 0
	while p.cursor < p.rooms.size():
		if worked > 0 and Time.get_ticks_usec() >= until_usec:
			work_ms += float(Time.get_ticks_usec() - t0) / 1000.0
			return false
		var room: Room = rooms[p.rooms[p.cursor]]
		p.cursor += 1
		worked += 1
		if room.items.is_empty():
			room.items = RoomManifest.items_for(room)
		if room.items.is_empty():
			continue
		var d := RoomManifest.draw_items(world, chunk, registry.palette, room, offset)
		if not (d.buffer as PackedFloat32Array).is_empty():
			p.pieces.append(d.buffer)
		if not (d.details as PackedFloat32Array).is_empty():
			p.items.append(d.details)
	rooms_worked += worked
	p.boxes = FurnitureMesh.attach_group(p.pieces, parent, _piece_nodes_p, chunk, piece_material())
	FurnitureMesh.attach_group(p.items, parent, _piece_nodes_i, chunk, item_material())
	var items = _piece_nodes_i.get(chunk)
	if items != null and is_instance_valid(items):
		(items as MultiMeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if not (items as Node).is_in_group(DebugView.GROUP_ITEMS):
			DebugView.tag(items as MultiMeshInstance3D, DebugView.Kind.ITEMS)
	if not p.shown:
		pieces_drawn += 1
	p.shown = true
	p.gone_sum = piece_gone_sum(p)
	work_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	return true


## Every row a building's shown groups are drawing now, pieces and items
## together, in its chunk's own space: what goes over with it when it topples
## whole (CityScene._topple).
func rows_of(building_id: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for g in known(building_id):
		if not g.shown:
			continue
		for buffer in g.pieces:
			out.append_array(buffer)
		for buffer in g.items:
			out.append_array(buffer)
	return out


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
			"releases": releases, "work_ms": work_ms, "worst_attach_ms": worst_attach_ms,
			"checks": checks, "check_ms": check_ms,
			"piece_drawings": _piece_draws.size(), "pieces_drawn": pieces_drawn}
