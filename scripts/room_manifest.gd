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
	var outer: Array = []
	var m := WALL_MARGIN
	var t := TowerRecipe.WALL_THICK
	for entry in (pl.rooms as Array):
		var r: Rect2i = entry
		var inset := Rect2i(r.position + Vector2i(m, m), r.size - Vector2i(m, m) * 2)
		if inset.size.x < 4 or inset.size.y < 4:
			continue
		rects.append(inset)
		# Against an exterior wall: the same test openings_for makes per side.
		outer.append(inset.position.x - m <= t or inset.position.y - m <= t
				or inset.end.x + m >= footprint_x - t or inset.end.y + m >= footprint_z - t)
		var here: Array[Rect2i] = []
		for q in posts:
			if (q as Rect2i).intersects(inset):
				here.append(q)
		mine.append(here)
	return {"rects": rects, "posts": mine, "outer": outer, "storeys": storeys_of(courses)}


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
static func rooms_for(footprint_x: int, footprint_z: int, courses: int,
		building_seed: int) -> Array[Room]:
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
			r.outer = bool((lat.outer as Array)[ri])
			r.room_seed = hash3(building_seed, r.id, 0x9E37)
			r.kind = Room.KINDS[r.room_seed % Room.KINDS.size()]
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
		building_seed: int, storey: int, plan: Vector2) -> int:
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
	return hash3(building_seed, id, 0x9E37) % Room.KINDS.size()


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
## The count is the first thing `items_for` computes and the only thing a blast
## nobody is watching needs: "everything in here is gone" is a set of indices,
## and the indices do not require the list. A city under fire compromises
## thousands of rooms it will never build, and each of those used to generate a
## manifest purely to count it.
static func item_count_for(room: Room) -> int:
	if (BY_KIND.get(room.kind, []) as Array).is_empty():
		return 0
	return 2 + int(hash3(room.room_seed, 11, 3) % 4)


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


## Is there anything under this item, in the chunk it would be laid into?
##
## `cell` is in the chunk's grid, as `place_block` takes it. Any one cell of
## live block under its footprint will do: that is the solve's own notion of
## held up, so an item this passes is one grounding reaches.
static func item_supported(world: BrickWorld, chunk: int, type: String,
		cell: Vector3i) -> bool:
	var span := _item_span(type)
	for x in span.x:
		for z in span.z:
			if world.is_solid(chunk, Vector3i(cell.x + x, cell.y - 1, cell.z + z)):
				return true
	return false


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
		# Decorative AT BIRTH, not marked afterwards, and that is worth the
		# argument: a decorative block is not in the chunk's face bake, so
		# placing one leaves the bake this chunk already holds exactly right.
		# Marking it after the fact cannot -- place_block has already thrown the
		# bake away by then, and re-baking a 50,000-brick building to add a
		# chair is what made one room cost 225 ms.
		var id := world.place_block(chunk, at + (part[1] as Vector3i), palette[name],
				(colour + int(part[2])) % BrickWorld.get_filament_count(), true)
		if id < 0:
			# All of it or none of it. A part that is refused -- something is
			# in the way -- takes the rest out with it: a crate whose bricks
			# were refused and whose lid was not is a lid hanging in the air.
			for laid in out:
				world.remove_block(chunk, laid)
			return PackedInt32Array()
		out.push_back(id)
	return out


## What a room looks like DRAWN: every part of every item it still holds, as a
## MultiMesh buffer, and one box per item for collision -- without laying a
## single block. [Scale §4.1](../Docs/Scale.md) rung 2.
##
## The same parts, cells and colours `build_item` would lay, so promoting a
## drawn room to bricks changes nothing on screen. `offset` is the host's
## rebase, as there. Returns {buffer, boxes, parts}; `boxes` holds one AABB
## per item drawn, in the chunk's own metres, which is the space the building's
## mesh and its furniture body are both in.
##
## An item is drawn where the manifest says, which for a standing building is
## where it would be laid. That is what `Room.posts` bought: an item placed
## clear of the columns, so the drawing does not have to ask the chunk whether
## there is room for it.
static func draw_items(world: BrickWorld, chunk: int, palette: Dictionary,
		room: Room, offset: Vector3i = Vector3i.ZERO) -> Dictionary:
	var buffer := PackedFloat32Array()
	var boxes: Array[AABB] = []
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = world.get_chunk_origin(chunk)
	var filaments := BrickWorld.get_filament_count()
	var parts := 0
	for i in room.items.size():
		if room.gone.has(i):
			continue
		var item: Dictionary = room.items[i]
		# Its floor went while nobody was looking -- blown out, or fallen with
		# a piece of the building. It went with it: written off, not drawn
		# standing on nothing.
		if not item_supported(world, chunk, str(item.type), (item.cell as Vector3i) - offset):
			room.gone[i] = true
			continue
		var at: Vector3i = (item.cell as Vector3i) - offset - origin
		var colour := 4 + int(i % 8)
		var box := AABB()
		var any := false
		for part in (ITEMS.get(str(item.type), []) as Array):
			var name: String = part[0]
			if not palette.has(name):
				continue
			var size := Vector3(world.get_archetype_size(palette[name])) * cs
			var lo := Vector3(at + (part[1] as Vector3i)) * cs
			var c := BrickWorld.get_filament_colour((colour + int(part[2])) % filaments)
			var mid := lo + size * 0.5
			# MultiMesh's own row layout: the basis by rows with the origin at
			# the end of each, then the colour.
			buffer.append_array([size.x, 0.0, 0.0, mid.x,
					0.0, size.y, 0.0, mid.y,
					0.0, 0.0, size.z, mid.z,
					c.r, c.g, c.b, c.a])
			parts += 1
			box = box.merge(AABB(lo, size)) if any else AABB(lo, size)
			any = true
		if any:
			boxes.append(box)
	return {"buffer": buffer, "boxes": boxes, "parts": parts}


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
