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
	# Four legs, two 4x4 plates for the mattress, a headboard along one end.
	"bed": [
		["brick_1x1", Vector3i(0, 0, 0), 0],
		["brick_1x1", Vector3i(3, 0, 0), 0],
		["brick_1x1", Vector3i(0, 0, 7), 0],
		["brick_1x1", Vector3i(3, 0, 7), 0],
		["plate_4x4", Vector3i(0, 3, 0), 1],
		["plate_4x4", Vector3i(0, 3, 4), 1],
		["brick_1x4_x", Vector3i(0, 4, 0), 0],
	],
	# A low block with a seat plate: sofa, bench, counter stool.
	"bench": [
		["brick_2x4_x", Vector3i(0, 0, 0), 0],
		["plate_2x4_x", Vector3i(0, 3, 0), 1],
	],
	# Waist-high, long: a counter or a workbench.
	"counter": [
		["brick_2x4_x", Vector3i(0, 0, 0), 0],
		["brick_2x4_x", Vector3i(0, 3, 0), 0],
		["tile_2x4_x", Vector3i(0, 6, 0), 1],
	],
}

## What each kind of room is likely to hold. Repeats are weights.
const BY_KIND := {
	"storeroom": ["crate", "crate", "crate", "shelf"],
	"office": ["table", "chair", "chair", "shelf"],
	"kitchen": ["table", "chair", "crate", "crate"],
	"empty": [],
	# Reached only through a program: see Room.LEGACY_KINDS.
	"bedroom": ["bed", "shelf", "chair"],
	"living": ["bench", "bench", "table", "shelf"],
	"bathroom": ["counter", "shelf"],
	"lab": ["counter", "counter", "table", "shelf", "crate"],
	"shop": ["shelf", "shelf", "counter", "crate"],
}

## Studs to keep clear of a wall, so a room's contents are not inside the
## masonry. The walls themselves are already excluded -- this is the gap left
## in front of them.
const WALL_MARGIN := 1


## The rooms a building's storeys are cut into, without building a single one.
##
## The cuts are **the recipe's own**: `TowerRecipe.plan` decides where the
## interior walls go and this reads the same answer, so a room is the volume
## between four walls that are actually there. It used to be a grid of this
## file's own invention laid over an undivided floor, which made every room
## boundary imaginary -- and two descriptions of one layout is how every item in
## the city came to be laid a plate above the floor.
##
## Rooms are ordered storey-major, so which room is where is still arithmetic.
## Knowing that without generating them is the difference between a streaming
## pass that costs what it opens and one that costs what EXISTS: the pass used
## to walk every room of every building within seventy metres, and a building of
## the big shapes has four thousand of them.
## Memoised. A lattice is a pure function of three integers, there are a
## handful of distinct shapes in a city, and working it out involves
## rebuilding the recipe's band layout -- a couple of hundred Dictionaries.
## The streaming pass asks for it twice per building per tick.
static var _lattices := {}


static func lattice_for(footprint_x: int, footprint_z: int, courses: int) -> Dictionary:
	var key := Vector3i(footprint_x, footprint_z, courses)
	if _lattices.has(key):
		return _lattices[key]
	var lat := _build_lattice(footprint_x, footprint_z, courses)
	_lattices[key] = lat
	return lat


static func _build_lattice(footprint_x: int, footprint_z: int, courses: int) -> Dictionary:
	var pl := TowerRecipe.plan(footprint_x, footprint_z)
	# The recipe's own columns, where it will stand them. Read, not worked out
	# again: two descriptions of one layout is how items came to be laid a
	# plate above the floor.
	var posts: Array[Rect2i] = []
	for entry in (pl.columns as Array):
		posts.append(entry)
	var rects: Array[Rect2i] = []
	var mine: Array = []
	var m := WALL_MARGIN
	var t := TowerRecipe.WALL_THICK
	for entry in (pl.rooms as Array):
		var r: Rect2i = entry
		var inset := Rect2i(r.position + Vector2i(m, m), r.size - Vector2i(m, m) * 2)
		if inset.size.x < 4 or inset.size.y < 4:
			continue
		rects.append(inset)
		var here: Array[Rect2i] = []
		for q in posts:
			if (q as Rect2i).intersects(inset):
				here.append(q)
		mine.append(here)
	return {"rects": rects, "posts": mine, "storeys": storeys_of(courses)}


## Which rooms lie within `radius` metres of a point in the building's own
## space, as indices into `rooms_for`.
##
## A conservative prefilter: it returns everything that could be in range and
## the caller still measures the ones it gets. What it does not do is look at
## the ones that cannot be.
## `storey_span` limits the answer to the storey the point is on and that many
## either side of it. -1 means every storey the radius reaches.
##
## It is a correctness rule before it is an optimisation: a room you can WALK
## into is on your floor, or one flight away. A 26 m sphere in a building of the
## big shapes spans fifteen storeys, and fourteen of them are rooms the player
## is standing above or below with a concrete slab in between -- and measuring
## all of them was most of what the streaming pass cost.
static func rooms_near(footprint_x: int, footprint_z: int, courses: int,
		local: Vector3, radius: float, storey_span: int = -1) -> PackedInt32Array:
	var out := PackedInt32Array()
	var lat := lattice_for(footprint_x, footprint_z, courses)
	var rects: Array = lat.rects
	if rects.is_empty():
		return out
	var cs := BrickWorld.get_cell_size()
	# Which rooms of a storey the radius reaches, in plan. A handful per floor,
	# so this is a loop rather than the index arithmetic it replaced -- and it
	# runs once here instead of once per storey below.
	var near := PackedInt32Array()
	for ri in rects.size():
		var r: Rect2i = rects[ri]
		if (local.x + radius >= float(r.position.x) * cs.x
				and local.x - radius <= float(r.position.x + r.size.x) * cs.x
				and local.z + radius >= float(r.position.y) * cs.z
				and local.z - radius <= float(r.position.y + r.size.y) * cs.z):
			near.push_back(ri)
	if near.is_empty():
		return out
	var storeys: Array = lat.storeys
	# Which storey the point is standing on, for `storey_span`.
	var on := -1
	if storey_span >= 0:
		for si in storeys.size():
			var st: Dictionary = storeys[si]
			var top: float = float(int(st.floor_y) + int(st.height)) * cs.y
			if local.y <= top:
				on = si
				break
		if on < 0:
			on = storeys.size() - 1
	for si in storeys.size():
		if storey_span >= 0 and absi(si - on) > storey_span:
			continue
		var storey: Dictionary = storeys[si]
		var y0: float = float(storey.floor_y) * cs.y
		var y1: float = float(int(storey.floor_y) + int(storey.height)) * cs.y
		if local.y + radius < y0 or local.y - radius > y1:
			continue
		for ri in near:
			out.push_back(si * rects.size() + ri)
	return out


## The rooms of a generated building, in its own cells: one per storey per room
## the recipe's interior walls cut that storey into.
##
## `program` is the building's mix of rooms (Docs/Workshop.md, Stage F):
## {kind: weight}. Empty is every kind equally, which is what every building
## had before programs existed -- and draws the same kinds it always drew.
static func rooms_for(footprint_x: int, footprint_z: int, courses: int,
		building_seed: int, program: Dictionary = {}) -> Array[Room]:
	var out: Array[Room] = []
	# One description of the lattice, read by the generator and by rooms_near.
	# Two would drift, and the last time two numbers described one layout here
	# every item in the city was laid a plate above the floor.
	var lat := lattice_for(footprint_x, footprint_z, courses)
	var rects: Array = lat.rects
	if rects.is_empty():
		return out
	for storey in (lat.storeys as Array):
		for ri in rects.size():
			var box: Rect2i = rects[ri]
			var r := Room.new()
			r.id = out.size()
			r.lo = Vector3i(box.position.x, int(storey.floor_y), box.position.y)
			r.size = Vector3i(box.size.x, int(storey.height), box.size.y)
			r.posts = (lat.posts as Array)[ri]
			r.room_seed = hash3(building_seed, r.id, 0x9E37)
			r.kind = Room.KINDS[kind_index(r.room_seed, program)]
			out.append(r)
	return out


## What kind of room stands behind a point on a building's plan, on one storey,
## as an index into Room.KINDS -- or -1 if no room does.
##
## Without generating a single Room. The kind is a pure function of the
## building's seed and the room's id, and the id is storey-major lattice
## arithmetic, so a far building's window can show the room that is really
## behind it -- a storeroom's window shows crates, an office's a desk -- and a
## city of five thousand buildings still holds no rooms at all.
##
## `building_seed` is the one `rooms_for` is given. The point is in studs; a
## point on the wall itself is fine, it is matched to the nearest room.
static func kind_at(footprint_x: int, footprint_z: int, courses: int,
		building_seed: int, storey: int, plan: Vector2, program: Dictionary = {}) -> int:
	var lat := lattice_for(footprint_x, footprint_z, courses)
	var rects: Array = lat.rects
	if rects.is_empty() or storey < 0 or storey >= (lat.storeys as Array).size():
		return -1
	var best := -1
	var best_d := INF
	for ri in rects.size():
		var r: Rect2i = rects[ri]
		var dx := maxf(maxf(r.position.x - plan.x, plan.x - r.end.x), 0.0)
		var dz := maxf(maxf(r.position.y - plan.y, plan.y - r.end.y), 0.0)
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = ri
	var id := storey * rects.size() + best
	return kind_index(hash3(building_seed, id, 0x9E37), program)


## Which of Room.KINDS a room with this seed is, under a program of weights.
## One function for `rooms_for` and `kind_at`, so a far building's window and
## the room behind it cannot disagree.
static func kind_index(room_seed: int, program: Dictionary = {}) -> int:
	var n := Room.KINDS.size()
	var total := 0
	for k in Room.KINDS:
		total += maxi(int(program.get(k, 0)), 0)
	if total <= 0:
		# No program: the four kinds every building has always had.
		return posmod(room_seed, Room.LEGACY_KINDS)
	var v := posmod(room_seed, total)
	for i in n:
		var w := maxi(int(program.get(Room.KINDS[i], 0)), 0)
		if v < w:
			return i
		v -= w
	return n - 1


## Parts of an item type: the built-in ITEMS, or one authored in the workshop
## (RoomTemplates). Rows are [part, offset, colour offset] for a built-in and
## carry [.., role, colour, material] as well for an authored one.
static func parts_of(type: String) -> Array:
	if ITEMS.has(type):
		return ITEMS[type]
	return RoomTemplates.parts(type)


## The authored room template this room is furnished from, or {} to use the
## built-in manifest. Chosen by the room's seed among every template of its
## kind that fits.
static func template_for(room: Room) -> Dictionary:
	if not RoomTemplates.has_rooms(room.kind):
		return {}
	return RoomTemplates.room_for(room.kind, room.size, hash3(room.room_seed, 3, 37))


## Every habitable storey of a tower: where its floor's TOP surface is, and how
## many plates of clear air stand on it before the next slab.
##
## Read from the recipe's own band layout, and that is the point. This file used
## to recompute the storeys from a `COURSES_PER_STOREY` of its own -- six, while
## the recipe laid a floor every four (`TowerRecipe.COURSES_PER_FLOOR`) -- so the
## two never agreed and had no way to. Rooms sat at heights no floor was at, and
## the header above `rooms_for` claimed the opposite: "a building is cut into
## boxes by the same rule that lays its floors, so a room's ceiling is a floor
## and its walls are walls."
##
## What it cost was invisible until the blocks were asked a structural question.
## A base slab is `SLAB_PLATES` thick, so its surface is at `y + plates` and NOT
## at `y + 1`; with the storey heights wrong as well, every item in the building
## was laid a plate above the floor, resting on nothing, clutched to nothing.
## They sat there looking correct -- a static body holds anything up -- until a
## grounding pass ran, at which point the entire contents of a building were a
## dozen detached groups waiting to be spawned as debris.
static func storeys_of(courses: int) -> Array:
	var out := []
	var floor_y := -1
	for band in TowerRecipe.layout(courses):
		var kind := str(band.kind)
		if kind != "base" and kind != "slab" and kind != "cornice":
			continue
		# A slab closes the storey under it and opens the one above it.
		if floor_y >= 0 and int(band.y) - floor_y >= 2:
			out.append({"floor_y": floor_y, "height": int(band.y) - floor_y})
		floor_y = -1 if kind == "cornice" else int(band.y) + int(band.plates)
	return out


## How many things are in this room, without working out what they are.
##
## The count is the first thing `items_for` computes, and the indices do not
## require the list.
static func item_count_for(room: Room) -> int:
	var tpl := template_for(room)
	if not tpl.is_empty():
		return (tpl.types as Array).size()
	if _kinds_for(room.kind).is_empty():
		return 0
	return 2 + int(hash3(room.room_seed, 11, 3) % 4)


## The item types a room of this kind draws from: the built-in list, and every
## authored item meant for it once each.
static func _kinds_for(kind: String) -> Array:
	var out: Array = (BY_KIND.get(kind, []) as Array).duplicate()
	out.append_array(RoomTemplates.items_for_kind(kind))
	return out


## The manifest: what is in this room. A pure function of its seed.
##
## Returns a list of {type, cell, yaw}. The cell is in the BUILDING's grid, on
## the room's floor, which is where the item's own blocks are laid from.
static func items_for(room: Room) -> Array:
	var out := []
	# An authored room first: its pieces where its author put them, centred
	# in the room, each slid off a column as a built-in item would be.
	var tpl := template_for(room)
	if not tpl.is_empty():
		var spare: Vector3i = room.size - (tpl.size as Vector3i)
		@warning_ignore("integer_division")
		var base := room.lo + Vector3i(spare.x / 2, 0, spare.z / 2)
		var placed: Array[Rect2i] = []
		for k in (tpl.types as Array).size():
			var type: String = tpl.types[k]
			var span := _item_span(type)
			var at := _off_the_posts(room, base + (tpl.offsets[k] as Vector3i), span, placed)
			if at == NOWHERE:
				continue
			placed.append(Rect2i(at.x, at.z, span.x, span.z))
			out.append({"type": type, "cell": at, "yaw": 0})
		return out
	var kinds := _kinds_for(room.kind)
	if kinds.is_empty():
		return out
	# Two to five things. A room is furnished, not warehoused: the count is what
	# keeps 5000 buildings x 20 rooms from being a million items even when
	# every one of them is awake.
	var n := item_count_for(room)
	# Each item gets a SLOT of the floor to itself and is jittered inside it,
	# rather than being dropped at an independent random cell. Independent
	# draws put two things in the same place often enough to matter -- and two
	# items sharing cells is one item's bricks refusing to place and the other's
	# damage record claiming both of them were destroyed. It got much more
	# likely when rooms stopped being a 7-stud grid of this file's own invention
	# and became whatever the recipe's interior walls cut the floor into.
	var cols := int(ceil(sqrt(float(n))))
	@warning_ignore("integer_division")
	var rows := (n + cols - 1) / cols
	@warning_ignore("integer_division")
	var slot_x: int = maxi(room.size.x / cols, 1)
	@warning_ignore("integer_division")
	var slot_z: int = maxi(room.size.z / rows, 1)
	# What the items already placed stand on, in plan. A later item slid off a
	# column must not slide onto one of THEM: a crate placed over a table lays
	# nothing but its lid, and the lid hangs in the air above the tabletop.
	var taken: Array[Rect2i] = []
	for i in n:
		var type: String = kinds[hash3(room.room_seed, i, 7) % kinds.size()]
		var span: Vector3i = _item_span(type)
		@warning_ignore("integer_division")
		var gz: int = i / cols
		var free_x := maxi(slot_x - span.x, 1)
		var free_z := maxi(slot_z - span.z, 1)
		var at := Vector3i(
				room.lo.x + (i % cols) * slot_x + int(hash3(room.room_seed, i, 19) % free_x),
				room.lo.y,
				room.lo.z + gz * slot_z + int(hash3(room.room_seed, i, 23) % free_z))
		# A slot narrower than the item would otherwise push it through a wall.
		at.x = mini(at.x, room.lo.x + maxi(room.size.x - span.x, 0))
		at.z = mini(at.z, room.lo.z + maxi(room.size.z - span.z, 0))
		at = _off_the_posts(room, at, span, taken)
		if at == NOWHERE:
			# Nowhere on this floor it fits -- a room that is mostly
			# stairwell. Better one thing fewer than one thing in the shaft.
			continue
		taken.append(Rect2i(at.x, at.z, span.x, span.z))
		out.append({"type": type, "cell": at,
				"yaw": int(hash3(room.room_seed, i, 29) % 4)})
	return out


## Slide an item off any column it landed on, along the room's own floor.
##
## A column runs from this room's floor to the next one, so an item inside one
## does not place at all -- `place_block` refuses it and the room quietly comes
## up short. On the shapes the city is built from a room has two to six of them
## and they took three items in four.
##
## The walk is deterministic and bounded: the same room furnishes the same way
## on the second visit and on another machine, which is the property the whole
## tier rests on.
static func _off_the_posts(room: Room, at: Vector3i, span: Vector3i,
		taken: Array[Rect2i] = []) -> Vector3i:
	if room.posts.is_empty() and taken.is_empty():
		return at
	var hi_x := room.lo.x + maxi(room.size.x - span.x, 0)
	var hi_z := room.lo.z + maxi(room.size.z - span.z, 0)
	# A short walk first: a column is two studs, and a step or two clears it.
	for step in 12:
		if not _on_a_post(room, at, span, taken):
			return at
		# Past the far side of whatever it is standing in, wrapping along the
		# row and then down to the next one.
		at.x += 2
		if at.x > hi_x:
			at.x = room.lo.x
			at.z += 2
			if at.z > hi_z:
				at.z = room.lo.z
	# A stairwell is ten studs across, and twelve steps of two do not clear
	# it. Every spot on the floor, then, from the room's corner -- and if none
	# of them is clear, nowhere.
	var z := room.lo.z
	while z <= hi_z:
		var x := room.lo.x
		while x <= hi_x:
			var here := Vector3i(x, at.y, z)
			if not _on_a_post(room, here, span, taken):
				return here
			x += 2
		z += 2
	return NOWHERE


## Where an item that fits nowhere goes: not in the manifest.
const NOWHERE := Vector3i(-1, -1, -1)


static func _on_a_post(room: Room, at: Vector3i, span: Vector3i,
		taken: Array[Rect2i] = []) -> bool:
	var box := Rect2i(at.x, at.z, span.x, span.z)
	for q in room.posts:
		if (q as Rect2i).intersects(box):
			return true
	for q in taken:
		if q.intersects(box):
			return true
	return false


## An item's box in its building's own space, in metres: where it stands and
## how much room it takes. What a blast is measured against (BuildingRegistry.
## compromise_items).
static func item_box(item: Dictionary) -> AABB:
	var cs := BrickWorld.get_cell_size()
	return AABB(Vector3(item.cell as Vector3i) * cs, Vector3(_item_span(str(item.type))) * cs)


## How much of an item's floor is live brick in this chunk: 0 to 1, over the
## cells under its footprint.
##
## The storey groups' rule for WHERE an item is (InteriorGroups): on the chunk
## that holds most of its floor -- the standing building, or the piece of it
## that floor went with. More than half, so no two chunks can both claim it:
## a floor cracked under a table leaves the table on the bigger part, not on
## both. `cell` is in the chunk's grid, which a piece shares with the building
## it came from (a split keeps every block's cell).
static func item_floor_share(world: BrickWorld, chunk: int, type: String,
		cell: Vector3i) -> float:
	var span := _item_span(type)
	var held := 0
	for x in span.x:
		for z in span.z:
			if world.is_solid(chunk, Vector3i(cell.x + x, cell.y - 1, cell.z + z)):
				held += 1
	return float(held) / float(maxi(span.x * span.z, 1))


## A part row's colour: the author's own when it has one, the room's otherwise.
static func _part_colour(part: Array, colour: int, filaments: int) -> int:
	if part.size() > 4 and int(part[4]) >= 0:
		return int(part[4])
	return (colour + int(part[2])) % filaments


## Is this part row DETAIL -- laid only when the room is real?
static func is_detail(part: Array) -> bool:
	return part.size() > 3 and int(part[3]) == BuildRecipe.Role.DETAIL


## Lay one item's bricks into a chunk. Returns the block ids it produced, which
## is what the room keeps so that it can take them out again.
##
## `offset` is the host's own rebase, the same argument `Fixture.build_into`
## takes and for the same reason.
##
## `roles`, when given, gets one BuildRecipe.Role per block laid, in order: an
## authored item's DETAIL parts are laid here like any other (they are bricks
## now) and the caller may want to know which they were.
static func build_item(world: BrickWorld, chunk: int, palette: Dictionary,
		item: Dictionary, colour: int, offset: Vector3i = Vector3i.ZERO,
		roles: Array = []) -> PackedInt32Array:
	var out := PackedInt32Array()
	var parts: Array = parts_of(str(item.type))
	var first_role := roles.size()
	var at: Vector3i = (item.cell as Vector3i) - offset
	for part in parts:
		var name: String = part[0]
		if not palette.has(name):
			continue
		# Decorative AT BIRTH, not marked afterwards, and that is worth the
		# argument: a decorative block is not in the chunk's face bake, so
		# placing one leaves the bake this chunk already holds exactly right.
		# Marking it after the fact cannot -- place_block has already thrown the
		# bake away by then, and re-baking a 50,000-brick building to add a
		# chair is what made one room cost 225 ms.
		var id := world.place_block(chunk, at + (part[1] as Vector3i), palette[name],
				_part_colour(part, colour, BrickWorld.get_filament_count()), true)
		if id < 0:
			# All of it or none of it. A part that is refused -- something is
			# in the way -- takes the rest out with it: a crate whose bricks
			# were refused and whose lid was not is a lid hanging in the air.
			for laid in out:
				world.remove_block(chunk, laid)
			roles.resize(first_role)
			return PackedInt32Array()
		if part.size() > 5 and int(part[5]) != 0:
			world.set_block_material(chunk, id, int(part[5]))
		out.push_back(id)
		roles.append(BuildRecipe.Role.DETAIL if is_detail(part) else BuildRecipe.Role.INTERIOR)
	return out


## What a room looks like DRAWN: every part of every item it still holds, as a
## MultiMesh buffer, and one box per item for collision -- without laying a
## single block. What a storey group is drawn from (InteriorGroups).
##
## The same parts, cells and colours `build_item` would lay, so a piece laid as
## bricks changes nothing on screen. `offset` is the host's rebase, as there.
## Returns {buffer, details, boxes, parts, pieces}; `boxes` holds one
## AABB per item drawn, in the chunk's own metres, which is the space the
## building's mesh and its furniture body are both in. `pieces` says which
## rows are whose: six ints an item drawn -- its index in `room.items`, its
## first row and row count in `buffer`, the same two for `details`, and its
## box in `boxes` (-1 for an item that is all DETAIL). `details` is the same
## kind of buffer for the DETAIL parts -- the small things on and round the
## pieces -- which a storey group shows only up close
## (InteriorGroups.ITEM_RANGE).
##
## An item is drawn where the manifest says, which for a standing building is
## where it would be laid. That is what `Room.posts` bought: an item placed
## clear of the columns, so the drawing does not have to ask the chunk whether
## there is room for it.
##
## Only the items whose floor is mostly in THIS chunk (item_floor_share), and
## nothing is written off: an item not drawn here may be on a piece of the
## building -- `chunk` can be that piece -- so its not being here says nothing
## about its being gone.
static func draw_items(world: BrickWorld, chunk: int, palette: Dictionary,
		room: Room, offset: Vector3i = Vector3i.ZERO) -> Dictionary:
	var buffer := PackedFloat32Array()
	var details := PackedFloat32Array()
	var pieces := PackedInt32Array()
	var boxes: Array[AABB] = []
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = world.get_chunk_origin(chunk)
	var filaments := BrickWorld.get_filament_count()
	var parts := 0
	for i in room.items.size():
		if room.gone.has(i) or room.laid.has(i):
			continue   # gone, or bricks now and drawn from them
		var item: Dictionary = room.items[i]
		# Its floor is not here -- blown out, or fallen with a piece of the
		# building. It went with it, and is not drawn standing on nothing.
		if item_floor_share(world, chunk, str(item.type),
				(item.cell as Vector3i) - offset) <= 0.5:
			continue
		var at: Vector3i = (item.cell as Vector3i) - offset - origin
		var colour := 4 + int(i % 8)
		var box := AABB()
		var any := false
		@warning_ignore("integer_division")
		var row0 := buffer.size() / 16
		@warning_ignore("integer_division")
		var detail0 := details.size() / 16
		for part in parts_of(str(item.type)):
			var name: String = part[0]
			if not palette.has(name):
				continue
			var size := Vector3(world.get_archetype_size(palette[name])) * cs
			var lo := Vector3(at + (part[1] as Vector3i)) * cs
			var pc := _part_colour(part, colour, filaments)
			var c := BrickWorld.get_filament_colour(pc) if part.size() <= 5 or int(part[5]) == 0 \
					else BrickWorld.get_material_colour(int(part[5]), pc)
			var mid := lo + size * 0.5
			# MultiMesh's own row layout: the basis by rows with the origin at
			# the end of each, then the colour.
			var row := [size.x, 0.0, 0.0, mid.x,
					0.0, size.y, 0.0, mid.y,
					0.0, 0.0, size.z, mid.z,
					c.r, c.g, c.b, c.a]
			# DETAIL is not part of the piece's own drawing or its box: it
			# exists only with somebody near (Docs/Workshop.md, Stage D), so
			# it goes in a buffer of its own for whoever draws up close.
			if is_detail(part):
				details.append_array(row)
				continue
			buffer.append_array(row)
			parts += 1
			box = box.merge(AABB(lo, size)) if any else AABB(lo, size)
			any = true
		@warning_ignore("integer_division")
		var rows := buffer.size() / 16 - row0
		@warning_ignore("integer_division")
		var detail_rows := details.size() / 16 - detail0
		if rows > 0 or detail_rows > 0:
			pieces.append_array([i, row0, rows, detail0, detail_rows,
					boxes.size() if any else -1])
		if any:
			boxes.append(box)
	return {"buffer": buffer, "details": details, "boxes": boxes, "parts": parts,
			"pieces": pieces}


## How many cells an item needs, so that it is placed inside the room rather
## than through its wall.
static func _item_span(type: String) -> Vector3i:
	# Asked for every piece every time a floor near it changes
	# (InteriorGroups.check_floors): worked out once a type.
	if _spans.has(type):
		return _spans[type]
	var span := _item_span_of(type)
	_spans[type] = span
	return span


## Authored items can be added and reloaded (RoomTemplates): forget theirs.
static func forget_spans() -> void:
	_spans.clear()


static var _spans := {}


static func _item_span_of(type: String) -> Vector3i:
	var hi := Vector3i.ONE
	for part in parts_of(type):
		var size := BuildRecipe.part_size(part[0])
		var at: Vector3i = part[1]
		hi = Vector3i(maxi(hi.x, at.x + size.x), maxi(hi.y, at.y + size.y),
				maxi(hi.z, at.z + size.z))
	return hi


## Where the walls of this room are missing.
##
## Interiors §3's portals, and the whole of what makes them cheap: a room is an
## axis-aligned box on a grid, so "is there a hole in that wall" is a walk over
## integer cells rather than anything geometric. Returns one box per APERTURE --
## per contiguous run of missing wall along a side -- in the building's own local
## metres.
##
## Per aperture and not per side, and the difference is the whole test. A side
## used to report the bounding box of every hole in it, which was harmless while
## the only holes were blast craters (one blast, one crater) and became wrong the
## moment walls had windows: two windows with a pier between them reported one
## box spanning both, whose centre is the pier. §3 aims a ray at that centre to
## ask whether the opening can be seen through, and the answer was always no --
## the ray hit the brickwork between the two windows.
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
	var m := WALL_MARGIN
	# Each side: the wall plane it sits in, the axis that runs along it, and
	# whether this room is actually against it. Since rooms became the volumes
	# between real interior walls, most of them are not against any exterior
	# wall at all -- and a room in the middle of a floor that reports the
	# windows of the room two doors down is a room the streaming pass opens
	# every time the player looks at the building from outside.
	var sides := [
		{"axis": "z", "at": inner - 1, "from": room.lo.x, "to": room.lo.x + room.size.x,
			"touch": room.lo.z - m <= inner},
		{"axis": "z", "at": footprint_z - inner, "from": room.lo.x, "to": room.lo.x + room.size.x,
			"touch": room.lo.z + room.size.z + m >= footprint_z - inner},
		{"axis": "x", "at": inner - 1, "from": room.lo.z, "to": room.lo.z + room.size.z,
			"touch": room.lo.x - m <= inner},
		{"axis": "x", "at": footprint_x - inner, "from": room.lo.z, "to": room.lo.z + room.size.z,
			"touch": room.lo.x + room.size.x + m >= footprint_x - inner},
	]
	for side in sides:
		if not bool(side.touch):
			continue
		# One pass along the side. A column of the wall either has a hole
		# somewhere up it or does not; consecutive columns that do are one
		# aperture, and the first solid column closes it.
		var run_from := -1
		var run_to := -1
		var run_lo_y := 0
		var run_hi_y := 0
		var u: int = side.from
		while u <= side.to:
			var top := -1
			var bottom := -1
			if u < side.to:
				var y := room.lo.y
				while y < room.lo.y + room.size.y:
					var at: Vector3i = (Vector3i(u, y, int(side.at)) if side.axis == "z"
							else Vector3i(int(side.at), y, u))
					if not world.is_solid(chunk, at):
						if bottom < 0:
							bottom = y
						top = y
					y += plates
			if bottom >= 0:
				if run_from < 0:
					run_from = u
					run_lo_y = bottom
					run_hi_y = top
				else:
					run_lo_y = mini(run_lo_y, bottom)
					run_hi_y = maxi(run_hi_y, top)
				run_to = u + 2
			elif run_from >= 0:
				out.append(_aperture(side, run_from, run_to, run_lo_y, run_hi_y, plates, cell))
				run_from = -1
			u += 2
		if run_from >= 0:
			out.append(_aperture(side, run_from, run_to, run_lo_y, run_hi_y, plates, cell))
	return out


## One opening's box, in the building's own local metres. `side` says which wall
## plane it is in and which axis the run measures along.
static func _aperture(side: Dictionary, from_u: int, to_u: int, lo_y: int, hi_y: int,
		plates: int, cell: Vector3) -> AABB:
	var thick := TowerRecipe.WALL_THICK
	var lo: Vector3
	var size: Vector3
	if side.axis == "z":
		lo = Vector3(from_u * cell.x, lo_y * cell.y, int(side.at) * cell.z)
		size = Vector3((to_u - from_u) * cell.x, (hi_y - lo_y + plates) * cell.y,
				thick * cell.z)
	else:
		lo = Vector3(int(side.at) * cell.x, lo_y * cell.y, from_u * cell.z)
		size = Vector3(thick * cell.x, (hi_y - lo_y + plates) * cell.y,
				(to_u - from_u) * cell.z)
	return AABB(lo, size)


## A small integer hash. Deterministic, order-independent and cheap -- the same
## properties `TerrainGrid` needs of its own, and for the same reason.
static func hash3(a: int, b: int, c: int) -> int:
	var h := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791)
	h = h & 0x7FFFFFFF
	h ^= (h >> 13)
	h = (h * 1274126177) & 0x7FFFFFFF
	return h ^ (h >> 16)
