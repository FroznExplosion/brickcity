class_name KitFurnish
extends RefCounted

## Furniture for a generated station's or ship's rooms (Docs/RoomModules.md 7.7):
## each room furnished the city's way (RoomManifest.items_for: two to five
## things, or an authored room template of its kind) and laid into the build
## as plain bricks on its floor's studs -- drawn, shot and carried off with its
## section like the walls round it. Not in the interior role: a station's and a
## ship's meshes are their face bake, which leaves interior bricks out (the
## city draws those apart, FurnitureMesh). `meta.furniture`: {"from": the first
## furniture brick (they are the build's last), "items", "turned": how many of
## them stand turned}.
##
## Each item stands turned by the manifest's `yaw` (quarter turns about +Y, its
## box's min corner kept), or the next turn that fits when that one does not.
##
## A lane from each door to the room's middle, and the middle itself, are kept
## clear (a way through a hub, a bridge's seat), and nothing goes where a brick
## already is or without a floor brick under it. A room that already holds
## furniture (a player's module built with its own: interior bricks) is left
## as it is -- its furniture made plain bricks too, so it is drawn.
##
##   var n := KitFurnish.furnish(made.recipe, seed)

## A space's kind (a ship room's name) -> the city's (Room.KINDS).
const KINDS := {"bridge": "office", "engine room": "lab", "reactor": "lab", "quarters": "bedroom",
		"cabin": "bedroom", "galley": "kitchen", "med bay": "lab", "cargo": "storeroom"}
## A plain room (`office`: RoomPack's filler rooms, a station's pods) is one of
## these by its seed.
const MIXED := ["office", "bedroom", "lab", "storeroom", "kitchen", "living"]
## Ways through, and closed nooks: left empty.
const SKIP := ["corridor", "hall", "stairwell", "storage", "empty", "other"]
## Studs kept clear either side of a door's lane, and round a room's middle.
const LANE := 1
const MIDDLE := 2


## Lays the furniture into `r`; how many items it laid. Its sections (meta)
## take each new brick into the section of the floor under it.
static func furnish(r: BuildRecipe, seed: int) -> int:
	var spaces: Array = (r.meta.get("structure", {}) as Dictionary).get("spaces", [])
	if spaces.is_empty():
		return 0
	var of := BuildSections.of_build(r)
	var cells := {}
	var held := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		var inner := r.is_interior(i)
		if inner:
			r.set_role(i, BuildRecipe.Role.STRUCTURE)
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells[c + Vector3i(x, y, z)] = i
					if inner:
						held[c + Vector3i(x, y, z)] = true
	var doors: Array = r.meta.get("doors", [])
	var filaments := BrickWorld.get_filament_count()
	var laid := 0
	var turns := 0
	var first := r.size()
	for sp: Dictionary in spaces:
		var kind := _kind_of(String(sp.kind), seed, int(sp.id))
		if kind == "" or (sp.get("columns", []) as Array).is_empty():
			continue
		var cols := {}
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := -lo
		for c in sp.columns:
			var v := Vector2i(int(c[0]), int(c[1]))
			cols[v] = true
			lo = Vector2i(mini(lo.x, v.x), mini(lo.y, v.y))
			hi = Vector2i(maxi(hi.x, v.x), maxi(hi.y, v.y))
		var floor_y := int(sp.floor_y)
		if _holds(held, cols, floor_y, int(sp.ceil_y)):
			continue
		var room := Room.new()
		room.kind = kind
		room.room_seed = RoomManifest.hash3(seed, int(sp.id), 41)
		room.lo = Vector3i(lo.x, floor_y + 1, lo.y)
		room.size = Vector3i(hi.x - lo.x + 1, maxi(int(sp.ceil_y) - floor_y - 1, 1), hi.y - lo.y + 1)
		var keep := _keep_clear(cols, lo, hi, floor_y + 1, doors)
		for z in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var v := Vector2i(x, z)
				if not cols.has(v) or keep.has(v):
					room.posts.append(Rect2i(x, z, 1, 1))
		var colour := posmod(RoomManifest.hash3(room.room_seed, 5, 1), filaments)
		for item: Dictionary in RoomManifest.items_for(room):
			var parts := RoomManifest.parts_of(String(item.type))
			for q in 4:
				if _lay(r, item.cell, turned(parts, int(item.get("yaw", 0)) + q), room, cols, keep, cells, of,
						colour, filaments):
					laid += 1
					turns += 1 if posmod(int(item.get("yaw", 0)) + q, 4) != 0 else 0
					break
	if of.size() == r.size() and r.meta.has("sections"):
		BuildSections.rerecord(r, of)
	r.meta["furniture"] = {"from": first, "items": laid, "turned": turns}
	return laid


## Has the room furniture of its own (an interior brick over its floor)?
static func _holds(held: Dictionary, cols: Dictionary, floor_y: int, ceil_y: int) -> bool:
	if held.is_empty():
		return false
	for v: Vector2i in cols:
		for y in range(floor_y + 1, ceil_y):
			if held.has(Vector3i(v.x, y, v.y)):
				return true
	return false


static func _kind_of(kind: String, seed: int, id: int) -> String:
	if SKIP.has(kind):
		return ""
	if KINDS.has(kind):
		return KINDS[kind]
	if kind == "office":
		return MIXED[posmod(RoomManifest.hash3(seed, id, 43), MIXED.size())]
	return kind if Room.KINDS.has(kind) else ""


## Plan cells kept clear: a lane LANE studs either side from each door into the
## room to its middle, and MIDDLE studs round the middle.
static func _keep_clear(cols: Dictionary, lo: Vector2i, hi: Vector2i, y: int, doors: Array) -> Dictionary:
	var keep := {}
	var mid := Vector2((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5)
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if absf(x - mid.x) <= MIDDLE and absf(z - mid.y) <= MIDDLE:
				keep[Vector2i(x, z)] = true
	for d: Dictionary in doors:
		var dlo := Vector3i(int(d.lo[0]), int(d.lo[1]), int(d.lo[2]))
		var ds := Vector3i(int(d.size[0]), int(d.size[1]), int(d.size[2]))
		if y < dlo.y or y >= dlo.y + ds.y:
			continue
		# The room's cells beside the hole: where the lane starts.
		var entry := []
		for z in range(dlo.z, dlo.z + ds.z):
			for x in range(dlo.x, dlo.x + ds.x):
				for n: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var v := Vector2i(x, z) + n
					if cols.has(v):
						entry.append(v)
		for e: Vector2i in entry:
			var steps := int(ceil((Vector2(e) - mid).length())) + 1
			for k in steps + 1:
				var p := Vector2(e).lerp(mid, float(k) / steps)
				for dz in range(-LANE, LANE + 1):
					for dx in range(-LANE, LANE + 1):
						keep[Vector2i(roundi(p.x) + dx, roundi(p.y) + dz)] = true
	return keep


## An item's parts (RoomManifest's rows) turned `k` quarter turns about +Y in
## the box they fill, its min corner kept: each part's cell as BuildRecipe.turned
## moves a block, its name turned as the palette turns it.
static func turned(parts: Array, k: int) -> Array:
	k = posmod(k, 4)
	if k == 0 or parts.is_empty():
		return parts
	var d := Vector3i.ZERO
	for part: Array in parts:
		d = d.max((part[1] as Vector3i) + BuildRecipe.part_size(String(part[0])))
	var out := []
	for part: Array in parts:
		var n := String(part[0])
		var at := BuildRecipe._turn_box(part[1], BuildRecipe.part_size(n), d, k)
		for q in k:
			var t := BrickPalette.turn(n)
			n = t if t != "" else n
		var row := part.duplicate()
		row[0] = n
		row[1] = at
		out.append(row)
	return out


## One item's bricks, all or none: every cell free and in the room, kept clear
## of the lanes, and a floor brick under it to hold it.
static func _lay(r: BuildRecipe, at: Vector3i, parts: Array, room: Room, cols: Dictionary, keep: Dictionary,
		cells: Dictionary, of: PackedInt32Array, colour: int, filaments: int) -> bool:
	if parts.is_empty():
		return false
	var under := -1
	var want := {}
	for part: Array in parts:
		var c: Vector3i = at + (part[1] as Vector3i)
		var s := BuildRecipe.part_size(String(part[0]))
		if s == Vector3i.ZERO:
			return false
		for y in s.y:
			for z in s.z:
				for x in s.x:
					var v := c + Vector3i(x, y, z)
					var plan := Vector2i(v.x, v.z)
					if cells.has(v) or want.has(v) or not cols.has(plan) or keep.has(plan) \
							or v.y >= room.lo.y + room.size.y:
						return false
					want[v] = true
					if y == 0 and under < 0 and v.y == room.lo.y and cells.has(v - Vector3i(0, 1, 0)):
						under = int(cells[v - Vector3i(0, 1, 0)])
	if under < 0:
		return false
	for part: Array in parts:
		var id := r.add(String(part[0]), at + (part[1] as Vector3i), RoomManifest._part_colour(part, colour, filaments),
				0, BuildRecipe.Role.STRUCTURE, int(part[5]) if part.size() > 5 else 0)
		var s := BuildRecipe.part_size(String(part[0]))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					cells[at + (part[1] as Vector3i) + Vector3i(x, y, z)] = id
		if not of.is_empty():
			of.append(of[under])
	return true

