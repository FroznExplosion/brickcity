class_name WorldFurnisher
extends Node3D

## Placing furniture and items in a game world, the way the workshop's F6 does:
## pick from the catalogue, a ghost on the stud under the aim, R turns, LMB
## places. Docs/AssetWorkshop.md, "Furniture and items".
##
## Where the aim lands decides what a placement IS:
##
##   a room of a generated building   one more item in that room's own list
##       (`room.items`, {type, cell, yaw}), exactly as the generator's own: drawn
##       with its storey group by distance, laid as bricks when hit, riding a
##       floor that falls (Interiors.md 8). The scene redraws the group
##       (`room_changed`).
##   a player build                   laid into its chunk as decorative bricks
##       (RoomManifest.build_item), as its own furniture is (`build_furnished`).
##   anywhere else                    a prop (OutdoorProps): drawn by distance,
##       solid, bricks when a blast reaches it.
##
## Knows nothing of the city scene but what it is handed, and `aim_ray` is
## public so a probe can drive it with exact rays.

## `func(b, y_lo: float, y_hi: float)`: a room of building `b` gained an item
## between these local heights; redraw what shows it.
var room_changed := Callable()
## `func(building_id: int, blocks: PackedInt32Array)`: decorative bricks were
## laid into a player build.
var build_furnished := Callable()
## `func(from, dir) -> Vector3` where the ground or anything solid is along a
## ray (Vector3.INF for none). Without it, the plane y = 0.
var ground_ray := Callable()
## The planet underfoot: the catalogue starts filtered to it.
var planet := "earth"

## How far a room can be furnished from: rooms are only asked of buildings this
## close along the aim (asking generates them).
const REACH := 60.0

var registry: BuildingRegistry
var props: OutdoorProps
var panel: AssetCatalogPanel

var held := ""
var turn := 0
## What the last aim found: {"kind": "room" | "build" | "outdoor", "at":
## Vector3i, "ok": bool, "b", "room", "room_index"}; {} for nothing.
var target := {}

var _camera: Camera3D
var _layer: CanvasLayer
var _hud: Label
var _ghost: Node3D
var _ghost_material: StandardMaterial3D
var _placed := []   ## what this placer did, newest last, for Backspace


func setup(reg: BuildingRegistry, camera: Camera3D, outdoor: OutdoorProps) -> void:
	registry = reg
	_camera = camera
	props = outdoor
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_layer = CanvasLayer.new()
	_layer.layer = 6
	_layer.visible = false
	add_child(_layer)
	panel = AssetCatalogPanel.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -400
	panel.offset_right = -12
	panel.offset_top = 12
	panel.picked.connect(hold)
	_layer.add_child(panel)
	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hud.offset_top = -170
	_hud.offset_left = -380
	_hud.offset_right = 380
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	_layer.add_child(_hud)


func is_open() -> bool:
	return _layer != null and _layer.visible


func open(on: bool) -> void:
	_layer.visible = on
	if on:
		panel.reload()
		panel.set_level("planet", [planet])
		_free_mouse(true)
	else:
		put_down()
	print("[furnish] catalogue %s" % ("open" if on else "closed"))


func _free_mouse(on: bool) -> void:
	if _camera != null and _camera.has_method("_set_captured"):
		_camera.call("_set_captured", not on)


func hold(id: String) -> void:
	if AssetCatalog.entry(id).is_empty():
		return
	held = id
	turn = 0
	_make_ghost()


func put_down() -> void:
	held = ""
	target = {}
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null


func turn_held() -> void:
	if held != "":
		turn = (turn + 1) % 4
		_make_ghost()


func _make_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
	_ghost = AssetPlacements.node_for(held, turn, _ghost_material, _ghost_material, true)
	add_child(_ghost)


func _process(_dt: float) -> void:
	if not is_open():
		return
	if held == "":
		_hud.text = "FURNISH   pick a piece from the list   Backspace take back the last   F6 close"
		return
	if _camera == null:
		return
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var vp := get_viewport()
	if vp != null and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var m := vp.get_mouse_position()
		from = _camera.project_ray_origin(m)
		dir = _camera.project_ray_normal(m)
	aim_ray(from, dir)
	var where: String = {"room": "in the %s" % (target.room.kind if target.has("room") else "room"),
			"build": "in the build", "outdoor": "outdoors"}.get(target.get("kind", ""), "aim at a floor")
	_hud.text = "PLACING %s %s   %s\nLMB place   R turn   Backspace take back the last   Esc put down   F6 close" % [
			AssetCatalog.entry(held).get("name", held), where,
			"fits" if target.get("ok", false) else ("BLOCKED" if not target.is_empty() else "")]


# ---------------------------------------------------------------------------
# Aiming
# ---------------------------------------------------------------------------

## Where the held piece would go for one ray. Public for probes.
func aim_ray(from: Vector3, dir: Vector3) -> void:
	target = {}
	if held == "":
		return
	var size := AssetPlacements.size_of(held, turn)
	var limit := INF
	var ground := Vector3.INF
	if ground_ray.is_valid():
		ground = ground_ray.call(from, dir)
	elif absf(dir.y) > 1e-4 and -from.y / dir.y > 0.0:
		ground = from + dir * (-from.y / dir.y)
	if ground != Vector3.INF:
		limit = from.distance_to(ground)
	# Rooms of generated buildings: their floors, or a piece already in them.
	var best_t := INF
	for b in registry.buildings:
		if b.is_build() or BuildingRegistry.ray_hit(b, from, dir) > minf(limit, REACH):
			continue
		var hit := _room_hit(b, from, dir, minf(limit + 0.5, best_t))
		if not hit.is_empty():
			best_t = float(hit.t)
			target = hit
	if target.is_empty() and ground != Vector3.INF:
		target = _build_or_outdoor(from, dir, ground)
	if target.is_empty():
		if _ghost != null:
			_ghost.visible = false
		return
	@warning_ignore("integer_division")
	var at: Vector3i = target.stud - Vector3i((size.x - 1) / 2, 0, (size.z - 1) / 2)
	target["at"] = at
	target["ok"] = _fits(at, size)
	if _ghost != null:
		_ghost.visible = true
		_ghost.global_transform = _xform_of(at)
		_ghost_material.albedo_color = Color(0.35, 0.9, 1.0, 0.45) if target.ok \
				else Color(1.0, 0.25, 0.22, 0.5)


## The nearest room floor (or piece in a room) of a generated building along a
## ray, nearer than `limit`: {kind "room", b, room, room_index, stud, t} or {}.
func _room_hit(b, from: Vector3, dir: Vector3, limit: float) -> Dictionary:
	var inv: Transform3D = b.xform.affine_inverse()
	var f: Vector3 = inv * from
	var d: Vector3 = inv.basis * dir
	if absf(d.y) < 1e-6:
		return {}
	var cs := BrickWorld.get_cell_size()
	var rooms := registry.rooms_of(b.id)
	var best := {}
	var best_t := limit
	for ri in rooms.size():
		var room: Room = rooms[ri]
		var box := room.local_box()
		# Its floor: the plane at the room's bottom, seen from above.
		if d.y < 0.0:
			var t := (box.position.y - f.y) / d.y
			if t > 0.0 and t < best_t:
				var p := f + d * t
				if p.x >= box.position.x and p.x < box.end.x and p.z >= box.position.z and p.z < box.end.z:
					best_t = t
					best = {"kind": "room", "b": b, "room": room, "room_index": ri, "t": t,
							"stud": Vector3i(int(floor(p.x / cs.x)), room.lo.y, int(floor(p.z / cs.z)))}
		# A piece already in it: its top.
		if not box.grow(0.05).intersects_ray(f, d):
			continue
		for i in room.items.size():
			if room.gone.has(i):
				continue
			var item: Dictionary = room.items[i]
			var ib := RoomManifest.item_box(item)
			var hit = ib.intersects_ray(f, d)
			if hit == null:
				continue
			var t2 := f.distance_to(hit)
			if t2 < best_t:
				best_t = t2
				var on: Vector3 = hit
				var c: Vector3i = item.cell
				var span := Vector3i(roundi(ib.size.x / cs.x), roundi(ib.size.y / cs.y), roundi(ib.size.z / cs.z))
				best = {"kind": "room", "b": b, "room": room, "room_index": ri, "t": t2,
						"stud": Vector3i(clampi(int(floor(on.x / cs.x)), c.x, c.x + span.x - 1),
								c.y + span.y, clampi(int(floor(on.z / cs.z)), c.z, c.z + span.z - 1))}
	return best


## Not in a room: on a player build's bricks, or outdoors on whatever is there.
func _build_or_outdoor(from: Vector3, dir: Vector3, ground: Vector3) -> Dictionary:
	var cs := BrickWorld.get_cell_size()
	var p := ground - dir * 0.01   # just this side of the surface
	for b in registry.buildings:
		if not b.is_build() or not b.is_materialised():
			continue
		if not BuildingRegistry.contains(b, ground + dir * 0.02, 0.02):
			continue
		var local: Vector3 = b.xform.affine_inverse() * (ground + dir * 0.02)
		var c := Vector3i(int(floor(local.x / cs.x)), int(floor(local.y / cs.y)), int(floor(local.z / cs.z)))
		var y := c.y
		while y < c.y + 400 and registry.world.is_solid(b.chunk, Vector3i(c.x, y, c.z)):
			y += 1
		return {"kind": "build", "b": b, "stud": Vector3i(c.x, y, c.z), "t": from.distance_to(ground)}
	# Outdoors: on the course just above what was hit.
	var stud := Vector3i(int(floor(p.x / cs.x)), int(ceil((ground.y - 0.005) / cs.y)), int(floor(p.z / cs.z)))
	return {"kind": "outdoor", "stud": stud, "t": from.distance_to(ground)}


## Does the held piece fit with its min corner at `at` where the aim is?
func _fits(at: Vector3i, size: Vector3i) -> bool:
	match str(target.get("kind", "")):
		"room":
			var room: Room = target.room
			if at.x < room.lo.x or at.z < room.lo.z or at.x + size.x > room.lo.x + room.size.x \
					or at.z + size.z > room.lo.z + room.size.z or at.y + size.y > room.lo.y + room.size.y:
				return false
			var plan := Rect2i(at.x, at.z, size.x, size.z)
			for post in room.posts:
				if (post as Rect2i).intersects(plan):
					return false
			var cs := BrickWorld.get_cell_size()
			var mine := AABB(Vector3(at) * cs, Vector3(size) * cs).grow(-0.01)
			for i in room.items.size():
				if not room.gone.has(i) and mine.intersects(RoomManifest.item_box(room.items[i])):
					return false
			return true
		"build":
			# Inside the build's own box: its chunk is no bigger.
			var b = target.b
			var dims: Vector3i = b.build.chunk_dims()
			for c: Vector3i in AssetPlacements.cells_of(held, turn, at):
				if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= dims.x or c.y >= dims.y or c.z >= dims.z 						or registry.world.is_solid(b.chunk, c):
					return false
			return true
		"outdoor":
			var taken := props.taken_cells() if props != null else {}
			for c in AssetPlacements.cells_of(held, turn, at):
				if taken.has(c):
					return false
			var cs := BrickWorld.get_cell_size()
			var mine := AABB(BrickWorld.grid_to_world(at), Vector3(size) * cs).grow(-0.01)
			for b in registry.buildings:
				if mine.intersects(CityPlacer.box_of(b)):
					return false
			return true
	return false


func _xform_of(at: Vector3i) -> Transform3D:
	var local := Transform3D(Basis(), BrickWorld.grid_to_world(at))
	match str(target.get("kind", "")):
		"room":
			return (target.b.xform as Transform3D) * local
		"build":
			return registry.world.get_chunk_transform(target.b.chunk) * local
	return local


# ---------------------------------------------------------------------------
# Placing
# ---------------------------------------------------------------------------

## Place the held piece where it is aimed. Returns whether it went in.
func place() -> bool:
	if held == "" or target.is_empty() or not target.get("ok", false):
		return false
	var at: Vector3i = target.at
	match str(target.kind):
		"room":
			var b = target.b
			var room: Room = target.room
			if room.items.is_empty():
				room.items = RoomManifest.items_for(room)
			room.items.append({"type": RoomTemplates.item_type(held, turn), "cell": at, "yaw": turn})
			room.placed_edits += 1
			_placed.append({"kind": "room", "b": b, "room": room, "index": room.items.size() - 1})
			if room_changed.is_valid():
				var cs := BrickWorld.get_cell_size()
				room_changed.call(b, room.lo.y * cs.y, (room.lo.y + room.size.y) * cs.y)
		"build":
			var b = target.b
			var blocks := RoomManifest.build_item(registry.world, b.chunk, registry.palette,
					{"type": RoomTemplates.item_type(held, turn), "cell": at, "yaw": turn}, 4)
			if blocks.is_empty():
				return false
			_placed.append({"kind": "build", "b": b, "blocks": blocks})
			if build_furnished.is_valid():
				build_furnished.call(b.id, blocks)
		"outdoor":
			var i := props.add(held, turn, at)
			_placed.append({"kind": "outdoor", "index": i})
	print("[furnish] placed '%s' %s at %v, turned %d" % [held, target.kind, at, turn])
	return true


## Take back the last piece this placer put down, if it is still as it was.
func take_back() -> bool:
	if _placed.is_empty():
		return false
	var u: Dictionary = _placed.pop_back()
	match str(u.kind):
		"room":
			var room: Room = u.room
			var i := int(u.index)
			if i != room.items.size() - 1 or room.laid.has(i) or room.gone.has(i):
				return false   # shot or laid since: it is the world's now
			room.items.pop_back()
			room.placed_edits += 1
			if room_changed.is_valid():
				var cs := BrickWorld.get_cell_size()
				room_changed.call(u.b, room.lo.y * cs.y, (room.lo.y + room.size.y) * cs.y)
		"build":
			for block in (u.blocks as PackedInt32Array):
				registry.world.remove_block(u.b.chunk, block)
			if build_furnished.is_valid():
				build_furnished.call(u.b.id, PackedInt32Array())
		"outdoor":
			props.remove(int(u.index))
	return true


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F6:
		open(not is_open())
		get_viewport().set_input_as_handled()
		return
	if not is_open():
		return
	if e is InputEventMouseButton and e.pressed:
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				place()
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_RIGHT:
				put_down()
				get_viewport().set_input_as_handled()
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_R:
				turn_held()
				get_viewport().set_input_as_handled()
			KEY_BACKSPACE:
				take_back()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				if held != "":
					put_down()
				else:
					open(false)
				get_viewport().set_input_as_handled()
