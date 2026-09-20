class_name RoomManifest

## Where rooms come from, what is in them, and what those things are made of.
##
## [Interiors §2](../Docs/Interiors.md): rooms are generated from the building's
## recipe, and their contents from `(building seed, room id)`. Nothing is stored
## -- the same room always holds the same things, and only a room somebody has
## **changed** needs a record.
##
## Everything here is a pure function of integers. That is the property the
## whole tier rests on: a room approached from the other side of the city, or
## ten minutes later, or on another machine in a co-op game, has to produce the
## same contents. A generator that carries state cannot promise that; a hash
## can.

## Items are brick clusters, not props (Interiors §7 question 3). Each is a list
## of (part, offset cell, colour offset) -- small, so a room of six of them is
## thirty blocks rather than six bodies.
const ITEMS := {
	"crate": [
		["brick_2x2", Vector3i(0, 0, 0), 0],
		["brick_2x2", Vector3i(0, 3, 0), 0],
		["tile_2x2", Vector3i(0, 6, 0), 0],
	],
	"table": [
		["brick_1x1", Vector3i(0, 0, 0), 0],
		["brick_1x1", Vector3i(3, 0, 0), 0],
		["brick_1x1", Vector3i(0, 0, 3), 0],
		["brick_1x1", Vector3i(3, 0, 3), 0],
		["plate_4x4", Vector3i(0, 3, 0), 1],
	],
	"chair": [
		["brick_1x1", Vector3i(0, 0, 0), 0],
		["tile_1x2_z", Vector3i(0, 3, 0), 1],
	],
	"shelf": [
		["brick_1x4_z", Vector3i(0, 0, 0), 0],
		["plate_1x4_z", Vector3i(0, 3, 0), 1],
		["brick_1x4_z", Vector3i(0, 4, 0), 0],
		["plate_1x4_z", Vector3i(0, 7, 0), 1],
	],
}

## What each kind of room is likely to hold. Repeats are weights.
const BY_KIND := {
	"storeroom": ["crate", "crate", "crate", "shelf"],
	"office": ["table", "chair", "chair", "shelf"],
	"kitchen": ["table", "chair", "crate", "crate"],
	"empty": [],
}

## Rooms per storey, and how tall a storey is in courses. A building is cut into
## boxes by the same rule that lays its floors, so a room's ceiling is a floor
## and its walls are walls.
const COURSES_PER_STOREY := 6
## Studs of wall to keep clear of, so a room's contents are not inside the
## masonry.
const WALL_MARGIN := 3


## The rooms of a generated building, in its own cells.
##
## One per storey for a small footprint, quartered for a large one -- which is
## the whole of "rooms come from the recipe" for a building whose recipe is
## four walls and a floor every few courses.
static func rooms_for(footprint_x: int, footprint_z: int, courses: int,
		building_seed: int) -> Array[Room]:
	var out: Array[Room] = []
	var plates := TowerRecipe.PLATES_PER_COURSE
	@warning_ignore("integer_division")
	var storeys := maxi(courses / COURSES_PER_STOREY, 1)
	var split := 2 if mini(footprint_x, footprint_z) >= 20 else 1
	var inner_x := footprint_x - WALL_MARGIN * 2
	var inner_z := footprint_z - WALL_MARGIN * 2
	if inner_x < 4 or inner_z < 4:
		return out
	@warning_ignore("integer_division")
	var cell_x: int = inner_x / split
	@warning_ignore("integer_division")
	var cell_z: int = inner_z / split
	for s in storeys:
		var y := TowerRecipe.SLAB_PLATES + s * COURSES_PER_STOREY * plates
		for gx in split:
			for gz in split:
				var r := Room.new()
				r.id = out.size()
				r.lo = Vector3i(WALL_MARGIN + gx * cell_x, y + 1, WALL_MARGIN + gz * cell_z)
				r.size = Vector3i(cell_x, COURSES_PER_STOREY * plates - 1, cell_z)
				r.room_seed = hash3(building_seed, r.id, 0x9E37)
				r.kind = Room.KINDS[r.room_seed % Room.KINDS.size()]
				out.append(r)
	return out


## The manifest: what is in this room. A pure function of its seed.
##
## Returns a list of {type, cell, yaw}. The cell is in the BUILDING's grid, on
## the room's floor, which is where the item's own blocks are laid from.
static func items_for(room: Room) -> Array:
	var kinds: Array = BY_KIND.get(room.kind, [])
	var out := []
	if kinds.is_empty():
		return out
	# Two to five things. A room is furnished, not warehoused: the count is what
	# keeps 5000 buildings x 20 rooms from being a million items even when
	# every one of them is awake.
	var n := 2 + int(hash3(room.room_seed, 11, 3) % 4)
	for i in n:
		var type: String = kinds[hash3(room.room_seed, i, 7) % kinds.size()]
		var span: Vector3i = _item_span(type)
		var free_x := maxi(room.size.x - span.x, 1)
		var free_z := maxi(room.size.z - span.z, 1)
		out.append({
			"type": type,
			"cell": room.lo + Vector3i(
					int(hash3(room.room_seed, i, 19) % free_x), 0,
					int(hash3(room.room_seed, i, 23) % free_z)),
			"yaw": int(hash3(room.room_seed, i, 29) % 4),
		})
	return out


## Lay one item's bricks into a chunk. Returns the block ids it produced, which
## is what the room keeps so that it can take them out again.
##
## `offset` is the host's own rebase, the same argument `Fixture.build_into`
## takes and for the same reason.
static func build_item(world: BrickWorld, chunk: int, palette: Dictionary,
		item: Dictionary, colour: int, offset: Vector3i = Vector3i.ZERO) -> PackedInt32Array:
	var out := PackedInt32Array()
	var parts: Array = ITEMS.get(str(item.type), [])
	var at: Vector3i = (item.cell as Vector3i) - offset
	for part in parts:
		var name: String = part[0]
		if not palette.has(name):
			continue
		var id := world.place_block(chunk, at + (part[1] as Vector3i), palette[name],
				(colour + int(part[2])) % BrickWorld.get_filament_count())
		if id >= 0:
			out.push_back(id)
	return out


## How many cells an item needs, so that it is placed inside the room rather
## than through its wall.
static func _item_span(type: String) -> Vector3i:
	var hi := Vector3i.ONE
	for part in (ITEMS.get(type, []) as Array):
		var size := BrickPalette.size_of(part[0])
		var at: Vector3i = part[1]
		hi = Vector3i(maxi(hi.x, at.x + size.x), maxi(hi.y, at.y + size.y),
				maxi(hi.z, at.z + size.z))
	return hi


## Where the walls of this room are missing.
##
## Interiors §3's portals, and the whole of what makes them cheap: a room is an
## axis-aligned box on a grid, so "is there a hole in that wall" is a walk over
## integer cells rather than anything geometric. Returns one box per side that
## has a hole in it, in the building's own local metres.
##
## The step is two studs and a course -- a brick -- because a hole you can see a
## room through is at least one brick wide, and sampling every cell of four wall
## planes for every room of every damaged building is the kind of loop this
## project measures and then regrets.
static func openings_for(world: BrickWorld, chunk: int, room: Room,
		footprint_x: int, footprint_z: int) -> Array[AABB]:
	var out: Array[AABB] = []
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return out
	var cell := BrickWorld.get_cell_size()
	var plates := TowerRecipe.PLATES_PER_COURSE
	var inner := TowerRecipe.WALL_THICK
	# Each side: the wall plane it sits in, and the axis that runs along it.
	var sides := [
		{"axis": "z", "at": inner - 1, "from": room.lo.x, "to": room.lo.x + room.size.x},
		{"axis": "z", "at": footprint_z - inner, "from": room.lo.x, "to": room.lo.x + room.size.x},
		{"axis": "x", "at": inner - 1, "from": room.lo.z, "to": room.lo.z + room.size.z},
		{"axis": "x", "at": footprint_x - inner, "from": room.lo.z, "to": room.lo.z + room.size.z},
	]
	for side in sides:
		var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
		var hi := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
		var holes := 0
		var y := room.lo.y
		while y < room.lo.y + room.size.y:
			var u: int = side.from
			while u < side.to:
				var at: Vector3i = (Vector3i(u, y, int(side.at)) if side.axis == "z"
						else Vector3i(int(side.at), y, u))
				if not world.is_solid(chunk, at):
					holes += 1
					lo = Vector3i(mini(lo.x, at.x), mini(lo.y, at.y), mini(lo.z, at.z))
					hi = Vector3i(maxi(hi.x, at.x), maxi(hi.y, at.y), maxi(hi.z, at.z))
				u += 2
			y += plates
		if holes == 0:
			continue
		out.append(AABB(
				Vector3(lo.x * cell.x, lo.y * cell.y, lo.z * cell.z),
				Vector3(maxf((hi.x - lo.x + 2) * cell.x, cell.x),
						maxf((hi.y - lo.y + plates) * cell.y, cell.y),
						maxf((hi.z - lo.z + 2) * cell.z, cell.z))))
	return out


## Which way is down for a room whose building has fallen over.
##
## [Interiors §5.2](../Docs/Interiors.md), the analytic resolve: snap world-down
## into the room's own frame and take the nearest of six. Exact for a section
## lying on a face, which is most of them, and it names the room's NEW floor
## without simulating anything.
static func down_axis(chunk_xform: Transform3D) -> Vector3i:
	var local: Vector3 = chunk_xform.basis.inverse() * Vector3.DOWN
	var ax := absf(local.x)
	var ay := absf(local.y)
	var az := absf(local.z)
	if ay >= ax and ay >= az:
		return Vector3i(0, -1 if local.y < 0.0 else 1, 0)
	if ax >= az:
		return Vector3i(-1 if local.x < 0.0 else 1, 0, 0)
	return Vector3i(0, 0, -1 if local.z < 0.0 else 1)


## Where an item ends up in a room that fell while nobody was looking.
##
## Against whatever face is now the floor, at its authored position projected
## onto it, with a seeded offset. No physics, no settling frames, deterministic,
## instant -- and nobody can tell whether the chair tumbled into that corner or
## was put there.
static func resolved_cell(room: Room, item: Dictionary, down: Vector3i,
		index: int) -> Vector3i:
	if down == Vector3i(0, -1, 0):
		return item.cell  # still upright: it is where it was
	var span := _item_span(str(item.type))
	var at: Vector3i = item.cell
	var jitter := Vector3i(
			int(hash3(room.room_seed, index, 41) % maxi(room.size.x - span.x, 1)),
			int(hash3(room.room_seed, index, 43) % maxi(room.size.y - span.y, 1)),
			int(hash3(room.room_seed, index, 47) % maxi(room.size.z - span.z, 1)))
	# Against the new floor: the axis that is now down goes to the low (or high)
	# end of the room, and the other two keep the authored position, jittered.
	match down:
		Vector3i(1, 0, 0):
			return Vector3i(room.lo.x + room.size.x - span.x, room.lo.y + jitter.y, at.z)
		Vector3i(-1, 0, 0):
			return Vector3i(room.lo.x, room.lo.y + jitter.y, at.z)
		Vector3i(0, 0, 1):
			return Vector3i(at.x, room.lo.y + jitter.y, room.lo.z + room.size.z - span.z)
		Vector3i(0, 0, -1):
			return Vector3i(at.x, room.lo.y + jitter.y, room.lo.z)
		Vector3i(0, 1, 0):
			# Upside down: the ceiling is the floor now.
			return Vector3i(at.x, room.lo.y + room.size.y - span.y, at.z)
	return at


## A small integer hash. Deterministic, order-independent and cheap -- the same
## properties `TerrainGrid` needs of its own, and for the same reason.
static func hash3(a: int, b: int, c: int) -> int:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791)
	h = h & 0x7FFFFFFF
	h ^= (h >> 13)
	h = (h * 1274126177) & 0x7FFFFFFF
	return h ^ (h >> 16)
