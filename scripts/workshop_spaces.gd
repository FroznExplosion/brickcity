class_name WorkshopSpaces
extends Node3D

## The spaces tool in the workshop (O): what the rooms of a build are, and
## where their openings are. Docs/Structures.md 3.2.
##
##   LMB on a room's floor   find the room -- its footprint, floor, ceiling and
##                           openings -- as a space of the kind K is on
##   LMB on an opening       its kind, round: doorway, door, window, glass, arch, open
##   LMB in a room found     select it
##   K / shift K             the selected room's kind (the next room's, with none)
##   RMB in a room           forget it
##   P / shift P             a point (spawn, loot, cover) where the cursor is, or
##                           take it away; shift: which kind P puts
##
## Kept in recipe.meta["structure"] (StructureSpaces), so it is saved with the
## build. Every room is found again from where it was clicked a moment after the
## bricks stop changing, and an opening's kind set by hand stays on it. Only the
## upright grid is looked at: a wall built sideways is not a wall to it yet.

const COLOURS := {
	"doorway": Color(0.35, 1.0, 0.45), "door": Color(0.1, 0.65, 0.25),
	"window": Color(0.45, 0.75, 1.0), "glass": Color(0.7, 0.95, 1.0),
	"arch": Color(1.0, 0.65, 0.2), "open": Color(1.0, 0.35, 0.35)}
const ROOM := Color(0.35, 0.9, 1.0)
const ROOM_SELECTED := Color(1.0, 0.85, 0.2)
const ROOM_LOST := Color(1.0, 0.25, 0.25)
const POINT := Color(1.0, 0.4, 1.0)
## How long the bricks must be still before the rooms are found again: a held
## click lays a brick a frame, and each one would find every room again.
const REFIND_AFTER_MS := 200

var ws   ## the workshop, untyped: it is the one that makes this
var active := false
var kind := "office"         ## what the next room found is
var point_kind := "loot"
var selected := -1           ## index into the record's spaces
var message := ""
var _dirty := false
var _edited_ms := 0
var _mesh: MeshInstance3D
var _labels: Array[Label3D] = []
var _decor := {}             ## Vector2i(frame, block id) of furniture and detail
## Which frame's brick fills an upright cell (StructureSpaces.frames_reader),
## made again with _decor.
var _reader := Callable()


func setup(workshop) -> void:
	ws = workshop
	name = "Spaces"
	_mesh = MeshInstance3D.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = true
	_mesh.material_override = m
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
	visible = false


## The build's record, made the first time it is asked for.
func record() -> Dictionary:
	if not ws.recipe.meta.has("structure"):
		ws.recipe.meta["structure"] = StructureSpaces.empty()
	return ws.recipe.meta["structure"]


func toggle() -> void:
	active = not active
	visible = active
	selected = -1
	message = ""
	if active:
		refind()


## The bricks changed (Workshop._after_edit), or the build did (a load).
func edited() -> void:
	_dirty = true
	_edited_ms = Time.get_ticks_msec()
	selected = -1 if not active else selected


## Every frame, from the workshop's: the rooms found again once the bricks
## have been still for a moment, whether or not the tool is out, so a save
## always has them as they are.
func process() -> void:
	if _dirty and Time.get_ticks_msec() - _edited_ms >= REFIND_AFTER_MS:
		var rec: Dictionary = ws.recipe.meta.get("structure", {})
		if (rec.get("spaces", []) as Array).is_empty():
			_dirty = false
			if active:
				draw()
			return
		refind()


## Every room found again from its seed; the kinds set by hand kept.
func refind() -> void:
	_dirty = false
	var rec := record()
	_collect_decor()
	var openings: Array = rec.openings
	var kept := []
	for s: Dictionary in rec.spaces:
		var start := _v3(s.seed)
		var mine := openings.filter(func(o) -> bool: return int(o.space) == int(s.id))
		var found := _find(start)
		if not found.ok:
			# Keep what it was, and say why it cannot be found now.
			s["lost"] = found.why
			kept.append_array(mine)
			continue
		s.erase("lost")
		var made := StructureSpaces.record_space(int(s.id), String(s.kind), 0, start, found, mine)
		s.floor_y = made[0].floor_y
		s.ceil_y = made[0].ceil_y
		s.columns = made[0].columns
		kept.append_array(made[1])
	rec.openings = kept
	if active:
		draw()


func click(from: Vector3, dir: Vector3) -> void:
	var aim := _aim(from, dir)
	var oi := _opening_hit(from, dir, float(aim[2]) if not aim.is_empty() else 120.0)
	var rec := record()
	if oi >= 0:
		var o: Dictionary = rec.openings[oi]
		StructureSpaces.cycle_opening(o)
		# The same hole seen from the room on its other side is the same hole.
		for other: Dictionary in rec.openings:
			if other != o and _shares_cell(other, o):
				other.kind = o.kind
				other.set = true
		message = "opening: %s" % o.kind
		_changed()
		return
	if aim.is_empty():
		message = "nothing there"
		return
	var start: Vector3i = aim[0]
	var si := StructureSpaces.space_at(rec, start)
	if si >= 0:
		selected = si
		message = "selected: %s" % rec.spaces[si].kind
		draw()
		return
	_collect_decor()
	var found := _find(start)
	if not found.ok:
		message = "no room there: %s" % found.why
		return
	var made := StructureSpaces.record_space(_next_id(), kind, 0, start, found)
	rec.spaces.append(made[0])
	rec.openings.append_array(made[1])
	selected = rec.spaces.size() - 1
	message = "%s found: %d x %d studs of floor, %d plates high, %d opening(s)" % [kind,
			_extent(found.columns).x, _extent(found.columns).y, int(found.ceil_y) - int(found.floor_y) - 1,
			(made[1] as Array).size()]
	_changed()


func right_click(from: Vector3, dir: Vector3) -> void:
	var aim := _aim(from, dir)
	if aim.is_empty():
		return
	var rec := record()
	var si := StructureSpaces.space_at(rec, aim[0])
	if si < 0:
		message = "no room there to forget"
		return
	var id := int(rec.spaces[si].id)
	rec.spaces.remove_at(si)
	rec.openings = (rec.openings as Array).filter(func(o) -> bool: return int(o.space) != id)
	selected = -1
	message = "room forgotten"
	_changed()


## K: the selected room's kind, or with none selected the next room's.
func cycle_kind(step: int) -> void:
	var rec := record()
	if selected >= 0 and selected < rec.spaces.size():
		StructureSpaces.cycle_kind(rec.spaces[selected], step)
		message = "room: %s" % rec.spaces[selected].kind
		_changed()
	else:
		var i := StructureSpaces.KINDS.find(kind)
		kind = StructureSpaces.KINDS[posmod(i + step, StructureSpaces.KINDS.size())]
		message = "next room: %s" % kind


## P: a point where the cursor is, or the one there taken away.
func toggle_point(from: Vector3, dir: Vector3) -> void:
	var aim := _aim(from, dir)
	if aim.is_empty():
		return
	var at: Vector3i = aim[0]
	var rec := record()
	for i in (rec.points as Array).size():
		if _v3(rec.points[i].at) == at:
			rec.points.remove_at(i)
			message = "point taken away"
			_changed()
			return
	rec.points.append({"kind": point_kind, "at": [at.x, at.y, at.z]})
	message = "%s point" % point_kind
	_changed()


func cycle_point_kind() -> void:
	var i := StructureSpaces.POINT_KINDS.find(point_kind)
	point_kind = StructureSpaces.POINT_KINDS[posmod(i + 1, StructureSpaces.POINT_KINDS.size())]
	message = "P puts: %s" % point_kind


func status() -> String:
	var rec := record()
	var sel := ""
	if selected >= 0 and selected < rec.spaces.size():
		var s: Dictionary = rec.spaces[selected]
		sel = "   selected: %s%s" % [s.kind, ("  [lost: %s]" % s.lost) if s.has("lost") else ""]
	return "SPACES (O) -- LMB: find a room, select it, or turn an opening's kind   K: kind (next: %s)   RMB: forget   P: %s point (shift P)\n%d room(s), %d opening(s), %d point(s)%s   %s" % [
			kind, point_kind, (rec.spaces as Array).size(), (rec.openings as Array).size(),
			(rec.points as Array).size(), sel, message]


# ---------------------------------------------------------------------------

func _changed() -> void:
	ws._dirty = true
	draw()


func _next_id() -> int:
	var id := 0
	for s in record().spaces:
		id = maxi(id, int(s.id) + 1)
	return id


func _find(start: Vector3i) -> Dictionary:
	var f: int = ws.asm.frames[0]
	var lo: Vector3i = ws.world.get_chunk_origin(f)
	var hi: Vector3i = lo + ws.world.get_chunk_dims(f)
	return StructureSpaces.find_space(start, _cell_kind, lo, hi)


## What the finder sees in a cell of the upright grid -- from the bricks of
## every frame, so a wall built sideways walls a room too: furniture and detail
## are air (a room is not walled by its desks); see-through bricks are glass;
## a door part is a door.
func _cell_kind(c: Vector3i) -> int:
	if not _reader.is_valid():
		_collect_decor()
	var at: Vector2i = _reader.call(c)
	if at.y < 0 or _decor.has(at):
		return StructureSpaces.Cell.AIR
	var f: int = ws.asm.frames[at.x]
	var id := at.y
	if BrickWorld.is_material_translucent(ws.world.get_block_material(f, id)):
		return StructureSpaces.Cell.GLASS
	if String(ws.world.get_archetype_name(ws.world.get_block_archetype(f, id))).contains("door"):
		return StructureSpaces.Cell.DOOR
	return StructureSpaces.Cell.SOLID


func _collect_decor() -> void:
	_decor.clear()
	_reader = StructureSpaces.frames_reader(ws.world, ws.asm.frames)
	var r = ws.recipe
	for i in r.size():
		if r.role_of(i) == BuildRecipe.Role.STRUCTURE or i >= ws._placed_at.size():
			continue
		var at: Array = ws._placed_at[i]
		_decor[Vector2i(int(at[0]), int(at[1]))] = true


## Along the ray in the upright grid: [the last air cell, the first cell that is
## not air, how far], or [] when it meets nothing.
func _aim(from: Vector3, dir: Vector3) -> Array:
	var f: int = ws.asm.frames[0]
	_collect_decor()
	var step := BrickPalette.PLATE_M * 0.34
	var t := 0.0
	var prev := Vector3i.ZERO
	var started := false
	while t < 120.0:
		var c: Vector3i = ws._cell_in(f, from + dir * t)
		if not started or c != prev:
			if started and _cell_kind(c) != StructureSpaces.Cell.AIR:
				return [prev, c, t]
			prev = c
			started = true
		t += step
	return []


## The nearest opening the ray goes into before `limit` (and a little past it:
## glass is the first thing the ray meets), by index, or -1.
func _opening_hit(from: Vector3, dir: Vector3, limit: float) -> int:
	var xf: Transform3D = ws.world.get_chunk_transform(ws.asm.frames[0])
	var inv := xf.affine_inverse()
	var lf: Vector3 = inv * from
	var ld: Vector3 = (inv.basis * dir).normalized()
	var best := -1
	var best_t := limit + BrickPalette.STUD_M
	var openings: Array = record().openings
	for i in openings.size():
		var box := _box(openings[i])
		var hit = box.grow(0.01).intersects_ray(lf, ld)
		if hit == null:
			continue
		var t: float = ((hit as Vector3) - lf).length()
		if t < best_t:
			best_t = t
			best = i
	return best


func _shares_cell(a: Dictionary, b: Dictionary) -> bool:
	var cells := {}
	for c in a.cells:
		cells[_v3(c)] = true
	for c in b.cells:
		if cells.has(_v3(c)):
			return true
	return false


## An opening's cells as a box, in the upright grid's metres.
func _box(o: Dictionary) -> AABB:
	var lo := Vector3i(1000000000, 1000000000, 1000000000)
	var hi := -lo
	for c in o.cells:
		var v := _v3(c)
		lo = Vector3i(mini(lo.x, v.x), mini(lo.y, v.y), mini(lo.z, v.z))
		hi = Vector3i(maxi(hi.x, v.x), maxi(hi.y, v.y), maxi(hi.z, v.z))
	var a := BrickWorld.grid_to_world(lo)
	var b := BrickWorld.grid_to_world(hi + Vector3i.ONE)
	return AABB(a, b - a)


func _extent(columns: Array) -> Vector2i:
	if columns.is_empty():
		return Vector2i.ZERO
	var lo := Vector2i(1000000000, 1000000000)
	var hi := -lo
	for c in columns:
		var v := Vector2i(int(c.x) if c is Vector2i else int(c[0]), int(c.y) if c is Vector2i else int(c[1]))
		lo = Vector2i(mini(lo.x, v.x), mini(lo.y, v.y))
		hi = Vector2i(maxi(hi.x, v.x), maxi(hi.y, v.y))
	return hi - lo + Vector2i.ONE


static func _v3(a) -> Vector3i:
	return Vector3i(int(a[0]), int(a[1]), int(a[2]))


# ---------------------------------------------------------------------------
# Drawing: each room's outline at its floor and its ceiling, each opening a box
# in its kind's colour, each point a cross, each room's kind over it.

func draw() -> void:
	for l in _labels:
		l.queue_free()
	_labels.clear()
	var rec := record()
	var im := ImmediateMesh.new()
	var any := not (rec.spaces as Array).is_empty() or not (rec.openings as Array).is_empty() \
			or not (rec.points as Array).is_empty()
	if not any:
		_mesh.mesh = null
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in (rec.spaces as Array).size():
		var s: Dictionary = rec.spaces[i]
		var col := ROOM_LOST if s.has("lost") else (ROOM_SELECTED if i == selected else ROOM)
		var cols := {}
		for c in s.columns:
			cols[Vector2i(int(c[0]), int(c[1]))] = true
		var y0 := int(s.floor_y) + 1
		var y1 := int(s.ceil_y)
		var sum := Vector2.ZERO
		for c: Vector2i in cols:
			sum += Vector2(c)
			for side in [[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1)],
					[Vector2i(1, 0), Vector2i(1, 0), Vector2i(1, 1)],
					[Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, 0)],
					[Vector2i(0, 1), Vector2i(0, 1), Vector2i(1, 1)]]:
				if cols.has(c + (side[0] as Vector2i)):
					continue
				var a: Vector2i = c + (side[1] as Vector2i)
				var b: Vector2i = c + (side[2] as Vector2i)
				for y in [y0, y1]:
					_line(im, Vector3i(a.x, y, a.y), Vector3i(b.x, y, b.y), col)
					any = true
		if not cols.is_empty():
			var mid := sum / float(cols.size())
			var l := Label3D.new()
			l.text = String(s.kind) + ("  (lost)" if s.has("lost") else "")
			l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			l.no_depth_test = true
			l.pixel_size = 0.004
			l.modulate = col
			l.position = BrickWorld.grid_to_world(Vector3i(int(mid.x), int((y0 + y1) * 0.5), int(mid.y))) \
					+ Vector3(BrickPalette.STUD_M, 0.0, BrickPalette.STUD_M) * 0.5
			_mesh.add_child(l)
			_labels.append(l)
	for o: Dictionary in rec.openings:
		var box := _box(o)
		ws._wire_box(im, box.get_center(), box.size + Vector3.ONE * 0.02,
				COLOURS.get(String(o.kind), Color.WHITE))
		any = true
	for p: Dictionary in rec.points:
		var c := BrickWorld.grid_to_world(_v3(p.at)) + Vector3(BrickPalette.STUD_M,
				BrickPalette.PLATE_M, BrickPalette.STUD_M) * 0.5
		for d in [Vector3(0.15, 0, 0), Vector3(0, 0.15, 0), Vector3(0, 0, 0.15)]:
			im.surface_set_color(POINT)
			im.surface_add_vertex(c - d)
			im.surface_set_color(POINT)
			im.surface_add_vertex(c + d)
		any = true
	if any:
		im.surface_end()
		_mesh.mesh = im
	else:
		_mesh.mesh = null
	_mesh.transform = ws.world.get_chunk_transform(ws.asm.frames[0])


func _line(im: ImmediateMesh, a: Vector3i, b: Vector3i, col: Color) -> void:
	im.surface_set_color(col)
	im.surface_add_vertex(BrickWorld.grid_to_world(a))
	im.surface_set_color(col)
	im.surface_add_vertex(BrickWorld.grid_to_world(b))
