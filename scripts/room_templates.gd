class_name RoomTemplates
extends RefCounted

## Rooms and items authored in the workshop, as the generator consumes them.
## Docs/Workshop.md, Stage E.
##
## The one place a player build IS used by reference (Docs/Workshop.md
## section 0): a generated room names a template and the template's bricks are
## laid on demand, so five thousand buildings share a handful of files and
## nothing is stored per room. Changing a template changes every generated room
## nobody has touched -- which is how the built-in `RoomManifest.ITEMS` has
## always behaved.
##
## Everything comes out as ITEM PARTS, the shape `RoomManifest.ITEMS` already
## uses, with three more columns so an authored thing keeps what its author
## gave it:
##
##   [part name, offset cell, colour offset, role, colour, material]
##
## `role` is BuildRecipe.Role (INTERIOR or DETAIL); `colour` is the author's
## own, or -1 to take the room's; `material` is the author's.
##
##   item:<file>          an Item build: all of it is one item.
##   room:<file>@<turn>#k  cluster k of a Room template, turned <turn> quarters.
##                        A cluster is one connected piece of furniture: each
##                        is placed, refused or written off on its own, as a
##                        built-in item is, so one chair in a column does not
##                        take the room with it.
##
## A template's STRUCTURE bricks are not furniture -- they are what its author
## stood it in to see it -- and are left out. The room's own walls are the
## generator's.

const ROOM_DIRS := ["res://rooms/", "user://rooms/"]
const ITEM_DIRS := ["res://items/", "user://items/"]

static var _loaded := false
## type -> parts
static var _parts := {}
## room kind -> [{"id", "size": Vector3i (unturned), "turns": {turn: [types]},
##                "sizes": {turn: Vector3i}, "offsets": {turn: [Vector3i per cluster]}}]
static var _rooms := {}
## room kind -> [item type], authored items meant for that kind of room
static var _items_for := {}


## Forget what was read, so a template saved a moment ago is picked up.
static func reload() -> void:
	_loaded = false
	_parts.clear()
	_rooms.clear()
	_items_for.clear()


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	for dir in ITEM_DIRS:
		for path in _files(dir):
			add_item(path.get_file().get_basename(), BuildRecipe.load_from(path))
	for dir in ROOM_DIRS:
		for path in _files(dir):
			add_room(path.get_file().get_basename(), BuildRecipe.load_from(path))


static func _files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return out
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if f.ends_with(".json"):
			out.append(dir + f)
	var subs := DirAccess.get_directories_at(dir)
	subs.sort()
	for s in subs:
		out.append_array(_files(dir + s + "/"))
	return out


## Register an Item build under `item:<id>`. Every brick is the item, whatever
## layer it was built on -- an item is furniture by definition -- except that
## DETAIL stays detail.
static func add_item(id: String, r: BuildRecipe) -> String:
	if r.is_empty():
		return ""
	var ids := []
	for i in r.size():
		if r.frame_of(i) == 0:
			ids.append(i)
	var type := "item:" + id
	_parts[type] = _parts_of(r, ids, _lo_of(r, ids))
	for k in _kinds_meant(r):
		var list: Array = _items_for.get(k, [])
		list.append(type)
		_items_for[k] = list
	return type


## Register a Room template, in all four turns.
static func add_room(id: String, r: BuildRecipe) -> bool:
	var kind := str(r.meta.get("room_kind", ""))
	if kind == "":
		return false
	var entry := {"id": id, "turns": {}, "sizes": {}, "offsets": {}}
	for turn in 4:
		var t := r.turned(turn)
		if t == null:
			if turn == 0:
				return false
			continue
		var furniture := []
		for i in t.size():
			if t.frame_of(i) == 0 and t.role_of(i) != BuildRecipe.Role.STRUCTURE:
				furniture.append(i)
		if furniture.is_empty():
			return false
		var lo := _lo_of(t, furniture)
		var hi := lo
		for i in furniture:
			var c := t.cell_of(i)
			var s := BuildRecipe.part_size(t.part_of(i))
			hi = Vector3i(maxi(hi.x, c.x + s.x), maxi(hi.y, c.y + s.y), maxi(hi.z, c.z + s.z))
		var types := []
		var offsets := []
		var clusters := _clusters(t, furniture)
		for k in clusters.size():
			var ids: Array = clusters[k]
			var clo := _lo_of(t, ids)
			var type := "room:%s@%d#%d" % [id, turn, k]
			_parts[type] = _parts_of(t, ids, clo)
			types.append(type)
			offsets.append(clo - lo)
		entry.turns[turn] = types
		entry.sizes[turn] = hi - lo
		entry.offsets[turn] = offsets
	var list: Array = _rooms.get(kind, [])
	list.append(entry)
	_rooms[kind] = list
	return true


## The room kinds an item is meant for: its meta "room_kind" (one) or
## "room_kinds" (several). None means every kind that has furniture.
static func _kinds_meant(r: BuildRecipe) -> Array:
	if r.meta.has("room_kinds"):
		return (r.meta.room_kinds as Array).duplicate()
	if r.meta.has("room_kind"):
		return [str(r.meta.room_kind)]
	var out := []
	for k in Room.KINDS:
		if k != "empty":
			out.append(k)
	return out


static func _lo_of(r: BuildRecipe, ids: Array) -> Vector3i:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	for i in ids:
		var c := r.cell_of(i)
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
	return lo


static func _parts_of(r: BuildRecipe, ids: Array, lo: Vector3i) -> Array:
	var out := []
	for i in ids:
		var role := BuildRecipe.Role.DETAIL if r.role_of(i) == BuildRecipe.Role.DETAIL \
				else BuildRecipe.Role.INTERIOR
		out.append([r.part_of(i), r.cell_of(i) - lo, 0, role, r.colour_of(i), r.material_of(i)])
	return out


## Connected pieces: two bricks are one piece when their boxes touch face to
## face or overlap. Authoring-sized, so the square loop is fine.
static func _clusters(r: BuildRecipe, ids: Array) -> Array:
	var n := ids.size()
	var lo := []
	var hi := []
	for i in ids:
		var c := r.cell_of(i)
		lo.append(c)
		hi.append(c + BuildRecipe.part_size(r.part_of(i)))
	var group := []
	for k in n:
		group.append(k)
	var find := func(x: int) -> int:
		while group[x] != x:
			x = group[x]
		return x
	for a in n:
		for b in range(a + 1, n):
			var la: Vector3i = lo[a]
			var ha: Vector3i = hi[a]
			var lb: Vector3i = lo[b]
			var hb: Vector3i = hi[b]
			if la.x <= hb.x and lb.x <= ha.x and la.y <= hb.y and lb.y <= ha.y \
					and la.z <= hb.z and lb.z <= ha.z:
				# Touching on at most one axis (an edge or a corner is not a join).
				var flush := int(la.x == hb.x or lb.x == ha.x) + int(la.y == hb.y or lb.y == ha.y) \
						+ int(la.z == hb.z or lb.z == ha.z)
				if flush <= 1:
					var ra: int = find.call(a)
					var rb: int = find.call(b)
					if ra != rb:
						group[maxi(ra, rb)] = mini(ra, rb)
	var by_root := {}
	var order := []
	for k in n:
		var root: int = find.call(k)
		if not by_root.has(root):
			by_root[root] = []
			order.append(root)
		(by_root[root] as Array).append(ids[k])
	var out := []
	for root in order:
		out.append(by_root[root])
	return out


# ---------------------------------------------------------------------------
# What the generator asks
# ---------------------------------------------------------------------------

## Parts of an authored item type, or [] if it is not one.
static func parts(type: String) -> Array:
	if not (type.begins_with("item:") or type.begins_with("room:")):
		return []
	_ensure()
	return _parts.get(type, [])


## Authored items meant for this kind of room.
static func items_for_kind(kind: String) -> Array:
	_ensure()
	return _items_for.get(kind, [])


## A template of this kind that fits a room this size, chosen by `pick`, as
## {"types": [...], "offsets": [...], "size": Vector3i}; {} if none fits. Every
## turn of every template is a candidate, so a long room takes a long template
## whichever way it runs.
static func room_for(kind: String, size: Vector3i, pick: int) -> Dictionary:
	_ensure()
	var fits := []
	for entry in (_rooms.get(kind, []) as Array):
		for turn in (entry.turns as Dictionary):
			var s: Vector3i = entry.sizes[turn]
			if s.x <= size.x and s.z <= size.z and s.y <= size.y:
				fits.append({"types": entry.turns[turn], "offsets": entry.offsets[turn],
						"size": s})
	if fits.is_empty():
		return {}
	return fits[posmod(pick, fits.size())]


static func has_rooms(kind: String) -> bool:
	_ensure()
	return not (_rooms.get(kind, []) as Array).is_empty()
