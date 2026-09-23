class_name BuildingRegistry
extends RefCounted

## A building is its recipe until something damages it. Plan.md B1 and §4.2.
##
## Measured, and this is the whole reason the class exists: a 150 m tower costs
## 10 MB as brick data and 220 MB once meshed. At 5000 buildings that is 50 GB
## before anything is drawn. A registered-but-untouched building here costs a
## few hundred bytes.
##
## Three layers, and only the last is LOD'd:
##
##   TRUTH           recipe + damage record. Never LOD'd, never freed.
##   MATERIALISATION a real chunk, created on first damage, freed when quiet.
##   PRESENTATION    meshes and bodies, by distance.
##
## The damage record survives de-materialisation, which is what makes damage
## permanent regardless of where the player is. It keys on BLOCK ID, so the
## recipe has to be a pure deterministic generator -- the same parameters always
## producing the same blocks in the same order. `recipe_version` is the guard: a
## saved record from a different version must be discarded rather than applied
## to bricks that have moved.


class Building:
	var id := -1
	var recipe := {}              ## parameters, not geometry
	var xform := Transform3D()
	var chunk := -1               ## the ROOT frame's chunk; -1 while only a recipe
	## Every frame's chunk, root first. Empty for anything that is not a
	## multi-frame build, because one chunk is the overwhelmingly common case and
	## a second array for it would only be a second thing to keep in step.
	var frames := PackedInt32Array()
	## The frames and the welds between them, for a multi-frame build. This is
	## what makes a sideways panel stand: it is grounded THROUGH its welds, not
	## by a foundation of its own (Docs/BuildMode.md section 3.3).
	var asm: Assembly = null
	var dead := PackedInt32Array() ## block ids destroyed in the ROOT frame
	## frame index >= 1 -> block ids destroyed in it. Same contract as `dead`:
	## keyed on block id, stable across de-materialisation, per frame because a
	## block id only means anything inside one chunk.
	var dead_frames := {}
	## Local bounds of everything this building occupies, frames included. Empty
	## until it has been materialised once; `BuildingRegistry.local_box` is what
	## reads it, and falls back to the parametric footprint until then.
	var box := AABB()
	## Set the moment a hit lands. `dead` is only refreshed when the bricks are
	## handed back, because walking every block in a building on every hit is
	## what a burst of fire cannot afford -- so "has this been damaged" needs an
	## answer that does not depend on the record being current.
	var hit := false
	## It came down and is now an island. The recipe and the damage record stay
	## -- for a save file, or a rebuild mode -- but nothing may materialise or
	## shell it again, because the bricks already exist somewhere in the world.
	var toppled := false
	var recipe_version := 0
	var blocks := 0               ## what the recipe would produce, known after one build
	var materialised_at := 0      ## msec, for LRU de-materialisation
	## Gate G1b: what the CHEAP representation needs to know about the damage.
	##
	## band index -> four segment masks, one per wall side. Computed when the
	## bricks are handed back, because that is exactly when the shell becomes
	## the thing on screen, and kept forever after. An empty dictionary means an
	## intact silhouette, which is what an undamaged building always has.
	var damage_profile := {}
	## Rooms, generated from the recipe on first demand and then kept, because
	## what has to persist is not the room but what somebody did to it
	## (Docs/Interiors.md section 2). An untouched room is a box and a seed.
	var rooms: Array[Room] = []
	var rooms_built := false
	## Fixtures: sub-assemblies with a materialisation state of their own --
	## a staircase, a cornice, a railing. Dormant until something wakes them,
	## and absent from every solve while they are (Docs/BuildMode.md section
	## 9.4). A building with fifty fixtures and none awake costs what a
	## building with none costs.
	var fixtures: Array[Fixture] = []
	## A player build rather than a generated tower. Mutually exclusive with the
	## parametric `recipe` fields; `kind` says which.
	var build: BuildRecipe = null

	func is_build() -> bool:
		return build != null

	func is_materialised() -> bool:
		return chunk >= 0

	## Every live chunk this building is made of, root first.
	func chunks() -> PackedInt32Array:
		if not frames.is_empty():
			return frames
		return PackedInt32Array([chunk]) if chunk >= 0 else PackedInt32Array()

	## What was destroyed in one frame. Frame 0 is `dead`, which everything
	## written before frames existed already reads.
	func dead_in(frame: int) -> PackedInt32Array:
		if frame == 0:
			return dead
		return dead_frames.get(frame, PackedInt32Array())

	func set_dead_in(frame: int, ids: PackedInt32Array) -> void:
		if frame == 0:
			dead = ids
		else:
			dead_frames[frame] = ids

	## How many blocks this building has lost, and the frame that was counted on.
	##
	## Memoised because counting walks every block in the chunk, and the room
	## streaming pass asks "have the holes moved" once per ROOM -- which on the
	## big shapes is four thousand walks of a fifty-thousand-block chunk in a
	## single tick.
	var dead_count := -1
	var dead_frame := -1

	## Which of this building's rooms are holding contents right now.
	##
	## Kept rather than found, because finding it means walking `rooms`, and a
	## building of the big shapes has four thousand of them. The streaming pass
	## asks this every tick; the answer is normally a handful.
	var open_rooms: Array[int] = []

	func is_damaged() -> bool:
		if hit or not dead.is_empty():
			return true
		for ids in dead_frames.values():
			if not (ids as PackedInt32Array).is_empty():
				return true
		return false


const RECIPE_VERSION := 1

var world: BrickWorld
var palette := {}
var buildings: Array[Building] = []

var _materialised := 0
var _materialise_count := 0
var _materialise_ms := 0.0
## Archetypes a kind of fixture needs, baked once, on first use. A dormant
## fixture must cost nothing, and baking eight wedge archetypes for a city that
## never wakes one is not nothing.
var _fixture_parts := {}
var _rooms_active := 0


func _init(brick_world: BrickWorld, part_palette: Dictionary) -> void:
	world = brick_world
	palette = part_palette


## Where a building may stand: on the SAME grid as everything else.
##
## The city, the terrain and the workshop all measure in one stud (0.35 m) and
## one plate (0.14 m) from the world origin, and a building's own cells are that
## grid only if its transform puts cell (0, 0, 0) on a grid point and turns it
## by whole quarter turns. The city spaced its towers 13 m apart -- 37.14 studs
## -- and dropped workshop builds in at 23 degrees, so every building's bricks
## sat a fraction of a stud off the terrain's and off each other's. Snapped here,
## at the one door every building comes in by, so no caller can get it wrong.
static func on_grid(xform: Transform3D) -> Transform3D:
	var yaw := xform.basis.get_euler().y
	var quarter := int(round(yaw / (PI * 0.5)))
	var o := xform.origin
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	return Transform3D(Basis(Vector3.UP, quarter * PI * 0.5),
			Vector3(round(o.x / stud) * stud, round(o.y / plate) * plate, round(o.z / stud) * stud))


## Record a building. No chunk, no blocks, no mesh — just what it is and where.
func register(footprint_x: int, footprint_z: int, courses: int, xform: Transform3D) -> int:
	var b := Building.new()
	b.id = buildings.size()
	b.recipe = {"footprint_x": footprint_x, "footprint_z": footprint_z, "courses": courses}
	b.xform = on_grid(xform)
	b.recipe_version = RECIPE_VERSION
	buildings.append(b)
	return b.id


## Record a player build. Same door a generated building comes through -- recipe
## plus a transform -- which is the whole reason Docs/BuildMode.md section 8.1
## puts authoring in a workshop and makes the city do placement only.
## A multi-frame build is placed as an ASSEMBLY: one chunk per frame, welded,
## grounded through the welds. Docs/BuildMode.md section 12 question 2 -- a
## Building used to hold one chunk and refuse anything sideways.
func register_build(recipe: BuildRecipe, xform: Transform3D) -> int:
	var b := Building.new()
	b.id = buildings.size()
	b.build = recipe
	var d := recipe.chunk_dims()
	# Kept so anything reading footprint/courses gets a sane box rather than a
	# missing key. A build has no courses, so this is its height in plates.
	b.recipe = {"footprint_x": d.x, "footprint_z": d.z, "courses": 0, "kind": "build"}
	b.xform = on_grid(xform)
	b.recipe_version = RECIPE_VERSION
	buildings.append(b)
	# Whatever was fixed to it in the workshop comes with it, dormant. The cell
	# is in the recipe's own frame-0 grid, and a placed build is rebased to its
	# min corner -- in the CELLS for a single-frame build, in the TRANSFORM for
	# a multi-frame one -- so subtracting that corner here puts the fixture in
	# the same place under both.
	for i in recipe.fixture_count():
		var f := recipe.fixture_at(i)
		add_fixture(b.id, f.kind, f.params, f.cell as Vector3i, f.role as Fixture.Role)
	return b.id


# ---------------------------------------------------------------------------
# Rooms and their contents (Docs/Interiors.md)
# ---------------------------------------------------------------------------

## The rooms of a building, generated from its recipe the first time anything
## asks.
##
## Interiors section 2: rooms come from the recipe rather than from authoring,
## so a city of five thousand buildings holds no rooms at all until something
## looks inside one. A player creation has no layout to cut into rooms -- its
## recipe is a pile of bricks somebody chose -- so it has none.
func rooms_of(building_id: int) -> Array[Room]:
	var b := get_building(building_id)
	if b == null:
		return []
	if not b.rooms_built:
		b.rooms_built = true
		if not b.is_build():
			b.rooms = RoomManifest.rooms_for(b.recipe.footprint_x, b.recipe.footprint_z,
					b.recipe.courses, b.id * 2654435761)
	return b.rooms


func get_room(building_id: int, index: int) -> Room:
	var rooms := rooms_of(building_id)
	return rooms[index] if index >= 0 and index < rooms.size() else null


## The holes in a room's walls, found again whenever the building's damage has
## moved on. Interiors §3: a destroyed wall is a new opening, and it falls out
## of the damage record for free.
##
## An undamaged building used to have none, and the scan was skipped outright
## for one. That was true when every opening in the city was a hole somebody
## blew, and it is not true now: TowerRecipe cuts windows into the top courses
## of every storey, which is what gives §3's portal test something to be a test
## OF. So the scan runs whatever the damage is, and what keeps it off the bill
## is the cache below -- an undamaged building's walls are scanned once and
## never again until something changes them.
func openings_of(building_id: int, index: int, may_scan: bool = true) -> Array[AABB]:
	var b := get_building(building_id)
	var room := get_room(building_id, index)
	if b == null or room == null or not b.is_materialised() or b.is_build():
		return []
	# The COUNT, not the list, and memoised for the frame. "Have the holes
	# moved since I last looked" is a comparison, and answering it walks every
	# block in the chunk -- which the streaming pass asks once per room.
	#
	# Not named `damage`: that is a method on this class, and shadowing it
	# here means a later call inside this function would hit the int.
	var frame := Engine.get_physics_frames()
	if b.dead_frame != frame:
		b.dead_frame = frame
		b.dead_count = world.get_dead_block_count(b.chunk)
	var dead: int = b.dead_count
	if room.openings_at == dead:
		return room.openings
	if not may_scan:
		# The walls have moved on and this pass has already spent its scan. The
		# last answer is a tick or two stale, which for "is there a hole in that
		# wall" is not wrong enough to pay for: a hole that appeared this tick
		# is a hole next tick too.
		return room.openings
	room.openings_at = dead
	room.openings = RoomManifest.openings_for(
			world, b.chunk, room, b.recipe.footprint_x, b.recipe.footprint_z)
	return room.openings


## Materialise a room's contents: run the manifest and lay the bricks.
##
## `chunk` is where they go. Left at -1 it is the building's own chunk, which is
## materialised first if it has to be -- the ordinary case, a room in a building
## that is standing. A caller that owns the blocks somewhere else passes them:
## after a topple the bricks belong to an island, and the room's contents belong
## in that island with them.
##
## **Which way is down is read from the chunk, not assumed.** A room in a piece
## that has fallen over resolves its contents against whatever face is now the
## floor (Interiors section 5.2) -- deterministic, instant, and indistinguishable
## from having simulated the fall.
func activate_room(building_id: int, index: int, chunk: int = -1) -> int:
	var b := get_building(building_id)
	var room := get_room(building_id, index)
	if b == null or room == null or room.active:
		return 0
	var into := chunk
	if into < 0:
		into = materialise(building_id)
	if into < 0 or not world.is_chunk_alive(into):
		return 0
	if room.items.is_empty():
		room.items = RoomManifest.items_for(room)
	var down := RoomManifest.down_axis(world.get_chunk_transform(into))
	var offset := _rebase_of(b)
	var placed := 0
	for i in room.items.size():
		if room.gone.has(i):
			continue
		var item: Dictionary = room.items[i]
		var at := RoomManifest.resolved_cell(room, item, down, i)
		var laid := RoomManifest.build_item(world, into, palette,
				{"type": item.type, "cell": at, "yaw": item.yaw},
				4 + int(i % 8), offset)
		item["blocks"] = laid
		if laid.is_empty():
			# Nowhere to put it -- something is already there. It is gone in the
			# same sense a taken item is: the room has been resolved, and this
			# is what the resolution says.
			room.gone[i] = true
		else:
			placed += laid.size()
	room.active = true
	if not b.open_rooms.has(index):
		b.open_rooms.append(index)
	_rooms_active += 1
	return placed


## Take a room's contents back out, keeping what changed.
##
## Interiors section 3: deactivating frees the objects and keeps the diff. The
## diff is one thing -- which items are gone -- because everything else about a
## room regenerates from its seed.
func deactivate_room(building_id: int, index: int) -> void:
	var b := get_building(building_id)
	var room := get_room(building_id, index)
	if b == null or room == null or not room.active:
		return
	var chunk := b.chunk
	var dead := {}
	if chunk >= 0 and world.is_chunk_alive(chunk):
		for id in world.get_dead_blocks(chunk):
			dead[id] = true
	for i in room.items.size():
		var item: Dictionary = room.items[i]
		var blocks: PackedInt32Array = item.get("blocks", PackedInt32Array())
		if blocks.is_empty():
			continue
		var lost := false
		for id in blocks:
			if dead.has(id):
				lost = true
				break
		if lost:
			# Shot, crushed, or taken down with the wall it stood against.
			room.gone[i] = true
		elif chunk >= 0 and world.is_chunk_alive(chunk):
			for id in blocks:
				world.remove_block(chunk, id)
		item["blocks"] = PackedInt32Array()
	room.active = false
	b.open_rooms.erase(index)
	_rooms_active -= 1


## The host is coming down. Decide what happens to each room's contents.
##
## Interiors §4.1: a destroyed room's contents "should not survive intact -- but
## they should not simply vanish either, because the player watched a building
## fall and expects to find what was in it". So the manifest is **spilled**: the
## same items the room would have held, in the wreckage, damaged.
##
## A room that was OPEN needs nothing done -- its bricks are in the chunk that
## is about to become an island, so they ride it (§4.2). A room that was shut is
## marked `spilled`, and `spill_room` puts its contents in when somebody is
## close enough for it to matter. §5.1's rule, and the one this project keeps
## arriving at: do not build, in the most expensive moment there is, something
## nobody can see.
func mark_rooms_spilled(building_id: int) -> int:
	var b := get_building(building_id)
	if b == null:
		return 0
	# Generated here if nobody has asked before. A building coming down is
	# exactly the moment its rooms start to matter, whether or not anybody
	# had looked inside it first -- and rooms are lazy, so without this a
	# tower nobody had approached spilled nothing at all.
	var n := 0
	for room in rooms_of(building_id):
		if room.active or room.spilled:
			continue
		room.spilled = true
		n += 1
	return n


## Put a spilled room's contents into the wreckage.
##
## `chunk` is the island that holds what the building became. Where each item
## lands is §5.2's analytic resolve -- against whatever face is now the floor --
## and what state it is in is seeded from the room: roughly a third of each
## item's bricks are gone, deterministically, so the same wreck looks the same
## on a second visit and on another machine.
##
## `budget` caps how many items are laid in full; the rest are written off.
## §4.1's degradation ladder: "spill the N most valuable or most visible items
## in full, represent the rest as generic rubble, and let distance and budget
## decide N". There is no generic rubble item yet, so the remainder is simply
## gone, which is the honest version of the same trade.
func spill_room(building_id: int, index: int, chunk: int, budget: int = 4) -> int:
	var b := get_building(building_id)
	var room := get_room(building_id, index)
	if b == null or room == null or not room.spilled or room.active:
		return 0
	if chunk < 0 or not world.is_chunk_alive(chunk):
		return 0
	if room.items.is_empty():
		room.items = RoomManifest.items_for(room)
	var down := RoomManifest.down_axis(world.get_chunk_transform(chunk))
	var offset := _rebase_of(b)
	var laid := 0
	var placed := 0
	for i in room.items.size():
		if room.gone.has(i):
			continue
		var item: Dictionary = room.items[i]
		if laid >= budget:
			room.gone[i] = true      # rubble, in the sense that nothing is left of it
			continue
		var at := RoomManifest.resolved_cell(room, item, down, i)
		var blocks := RoomManifest.build_item(world, chunk, palette,
				{"type": item.type, "cell": at, "yaw": item.yaw},
				4 + int(i % 8), offset)
		if blocks.is_empty():
			room.gone[i] = true
			continue
		# Damaged, not intact: a third of it, chosen from the room's seed.
		var broken := PackedInt32Array()
		for k in blocks.size():
			if RoomManifest.hash3(room.room_seed, i, k) % 3 == 0:
				broken.push_back(blocks[k])
		if not broken.is_empty():
			world.kill_blocks(chunk, broken)
		item["blocks"] = blocks
		laid += 1
		placed += blocks.size()
	room.spilled = false
	room.active = true
	if not b.open_rooms.has(index):
		b.open_rooms.append(index)
	_rooms_active += 1
	return placed


## Rooms of this building that came down without being opened.
func spilled_rooms(building_id: int) -> Array[Room]:
	var out: Array[Room] = []
	var b := get_building(building_id)
	if b == null:
		return out
	for room in b.rooms:
		if room.spilled:
			out.append(room)
	return out


## Every room this volume reaches, activated where it stands.
##
## Interiors section 5: a COMPROMISED room resolves immediately, whether or not
## anybody can see it, because its contents are part of what the damage does.
## Plan section 4.4 is the same rule one level up.
func compromise_rooms(building_id: int, world_point: Vector3, radius: float,
		build: bool = true) -> int:
	var b := get_building(building_id)
	if b == null or b.is_build():
		return 0
	var woken := 0
	var local := b.xform.affine_inverse() * world_point
	for room in rooms_of(building_id):
		if room.active:
			continue
		if not room.local_box().grow(radius).has_point(local):
			continue
		if build:
			if activate_room(building_id, room.id) > 0:
				woken += 1
			continue
		# Nobody is near enough to see it, so nothing is built. Interiors
		# section 5.1: "rooms near the camera spawn full contents; distant ones
		# write spilled into the diff and resolve analytically if anybody ever
		# arrives". What the blast did to this room is recorded and costs
		# nothing -- and it costs nothing in the right way, because BUILDING it
		# means taking the host's body out of the physics space to add the
		# collision, which wakes everything resting on that building. Doing
		# that once per blast took the stress pass's damage phase from 20 ms a
		# frame to 108.
		# Not even the manifest: how many things were in here is a function of
		# the room's seed, so "all of them are gone" is writable without a list
		# of what they were. `items_for` is deterministic, so the indices still
		# line up if anybody ever does build it.
		var count: int = room.items.size() if not room.items.is_empty() 				else RoomManifest.item_count_for(room)
		for i in count:
			room.gone[i] = true
		room.spilled = false
		woken += 1
	return woken


## Which of this building's rooms are within `radius` metres of a world point.
##
## Arithmetic on the room lattice rather than a walk over the rooms. The
## streaming pass used to measure every room of every building within seventy
## metres, which on the big shapes is tens of thousands of box tests fifteen
## times a second, and that was most of what the interiors cost.
func rooms_in_range(building_id: int, world_point: Vector3, radius: float,
		storey_span: int = -1) -> PackedInt32Array:
	var b := get_building(building_id)
	if b == null or b.is_build() or b.recipe == null:
		return PackedInt32Array()
	var local: Vector3 = b.xform.affine_inverse() * world_point
	return RoomManifest.rooms_near(b.recipe.footprint_x, b.recipe.footprint_z,
			b.recipe.courses, local, radius, storey_span)


## How many rooms are holding contents, and how many have a diff to their name.
func room_report() -> Dictionary:
	var total := 0
	var changed := 0
	for b in buildings:
		total += b.rooms.size()
		for room in b.rooms:
			if room.is_changed():
				changed += 1
	return {"rooms": total, "active": _rooms_active, "changed": changed}


# ---------------------------------------------------------------------------
# Fixtures (Docs/BuildMode.md section 9)
# ---------------------------------------------------------------------------

## The footprints a building's fixtures need clear of columns and floor.
##
## Asked BEFORE the recipe lays anything, because a stairwell is a shaft up the
## middle of a building and that is exactly where the columns carrying its
## floors want to stand. Taking them out afterwards left the panels above them
## holding on to nothing. See `Fixture.footprint`.
func _keepouts_of(b: Building) -> Array:
	var out: Array = []
	for f in b.fixtures:
		var span: Rect2i = f.footprint()
		if span.size.x > 0 and span.size.y > 0:
			out.append(span)
	return out


## Attach a fixture, in the building's OWN cells.
##
## It costs nothing until the building is built, because it is not a separate
## thing that gets built -- it is part of what the building is. A registered
## building holds no bricks at all, its staircase included.
func add_fixture(building_id: int, kind: String, params: Dictionary,
		cell: Vector3i, role: Fixture.Role = Fixture.Role.DECORATIVE) -> int:
	var b := get_building(building_id)
	if b == null:
		return -1
	var f := Fixture.new()
	f.id = b.fixtures.size()
	f.kind = kind
	f.params = params
	f.cell = cell
	f.role = role
	b.fixtures.append(f)
	if b.is_materialised():
		# Built after the fact: its blocks go on the end, which is where they
		# would have gone anyway.
		f.build_into(world, b.chunk, fixture_parts(kind), _rebase_of(b))
	return f.id


func get_fixture(building_id: int, index: int) -> Fixture:
	var b := get_building(building_id)
	if b == null or index < 0 or index >= b.fixtures.size():
		return null
	return b.fixtures[index]


## The archetypes a kind of fixture is built from, baked on first demand.
##
## A city of five thousand buildings that never materialises one should not pay
## for eight wedge archetypes it never places.
func fixture_parts(kind: String) -> PackedInt32Array:
	if _fixture_parts.has(kind):
		return _fixture_parts[kind]
	var parts := PackedInt32Array()
	match kind:
		"staircase":
			parts = StaircaseRecipe.bake_parts(world)
		_:
			push_error("BuildingRegistry: no parts for fixture kind '%s'" % kind)
	_fixture_parts[kind] = parts
	return parts


## How far a build's own bricks were moved when it was placed. A fixture is
## authored against those bricks, so it moves by the same amount.
func _rebase_of(b: Building) -> Vector3i:
	if b.is_build() and b.build.is_single_frame():
		return b.build.origin()
	return Vector3i.ZERO


## Lay every fixture's bricks into the chunk that has just been built.
##
## Called at ONE point in the build order, after the building's own blocks, so
## that a block id means the same brick every time -- which is what the damage
## record rides on.
func _build_fixtures(b: Building) -> int:
	var placed := 0
	var offset := _rebase_of(b)
	for f in b.fixtures:
		placed += f.build_into(world, b.chunk, fixture_parts(f.kind), offset)
	return placed


func get_building(id: int) -> Building:
	return buildings[id] if id >= 0 and id < buildings.size() else null


## Build the real bricks. Idempotent: already-materialised buildings are returned
## as they are.
func materialise(id: int) -> int:
	var b := get_building(id)
	if b == null:
		return -1
	if b.is_materialised():
		b.materialised_at = Time.get_ticks_msec()
		return b.chunk
	if b.toppled:
		return -1  # its bricks are an island now; building them again would double it

	var t0 := Time.get_ticks_usec()
	if b.is_build() and not b.build.is_single_frame():
		# One chunk per frame, at the tick offset the author built it at, with
		# the welds rebuilt from the recipe. Nothing is rebased: a frame's
		# offset from the root is stored in ticks, and moving a grid origin
		# moves its bricks away from the welds holding them (BuildRecipe.frame_dims).
		b.asm = Assembly.new(world, palette)
		b.build.build_into(b.asm, palette)
		b.frames = b.asm.frames.duplicate()
		b.chunk = b.frames[0]
		# The build is not rebased, so its lowest brick sits wherever the author
		# left it -- a plate up, if it was built on the workshop's baseplate.
		# The REBASE GOES IN THE TRANSFORM instead: one translation, in root
		# space, applied to every frame alike. That is a rigid move of the whole
		# assembly, so the tick lattice the frames meet on is untouched, and the
		# build still lands with its own floor on the ground.
		var cell := BrickWorld.get_cell_size()
		var lo: Vector3i = b.build.origin()
		var shift := Transform3D(Basis(), -Vector3(
				lo.x * cell.x, lo.y * cell.y, lo.z * cell.z))
		for c in b.frames:
			# set_chunk_frame derived a transform from (rotation, ticks) in the
			# assembly's own space; the building's placement is on top of it.
			world.set_chunk_transform(c, b.xform * shift * world.get_chunk_transform(c))
		# Grounding is asked in CELL space, and the root's bricks start at `lo`,
		# not at zero. Without this the whole build reads as ungrounded and
		# sheds itself on the first solve.
		world.set_foundation_level(b.frames[0], lo.y)
	elif b.is_build():
		b.chunk = world.create_chunk(Vector3i.ZERO, b.build.chunk_dims())
		b.build.build(world, b.chunk, palette)
	else:
		b.chunk = world.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(
				b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses))
		# What the fixtures need clear, before the columns go in. See
		# Fixture.footprint.
		TowerRecipe.build(world, b.chunk, palette,
				b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses,
				_keepouts_of(b))
	if b.frames.is_empty():
		world.set_chunk_transform(b.chunk, b.xform)
	# The staircases and everything else fixed to it, in the same grid and the
	# same chunk. A fixture is not a separate object standing inside a building
	# (Fixture's own notes on why that was wrong); it is part of the building.
	if not b.fixtures.is_empty():
		_build_fixtures(b)
	b.blocks = 0
	for c in b.chunks():
		b.blocks += world.get_block_count(c)
	if b.box == AABB():
		b.box = _measure(b)

	# Replay the damage record. This is the step that makes destruction
	# permanent: the bricks are freshly generated, but the ones that were
	# destroyed are destroyed again, by id.
	if b.recipe_version != RECIPE_VERSION:
		push_warning("[registry] building %d has a v%d damage record against a v%d recipe; discarding it"
				% [b.id, b.recipe_version, RECIPE_VERSION])
		b.dead = PackedInt32Array()
		b.dead_frames = {}
		b.recipe_version = RECIPE_VERSION
	var cs := b.chunks()
	for i in cs.size():
		world.kill_blocks(cs[i], b.dead_in(i))

	b.materialised_at = Time.get_ticks_msec()
	_materialised += 1
	_materialise_count += 1
	_materialise_ms += (Time.get_ticks_usec() - t0) / 1000.0
	return b.chunk


## Give the bricks back but keep the damage. The building returns to being a
## recipe plus a list of what is missing from it.
## Give the chunk away rather than freeing it: the caller now owns those bricks.
## Everything dematerialise() does, except the release.
func hand_over(id: int) -> void:
	var b := get_building(id)
	if b == null or not b.is_materialised():
		return
	# The bricks are about to belong to an island, contents included: what was
	# in the room rides the piece it was standing on (Interiors section 4.2).
	# The rooms themselves stop being materialised, because the building they
	# were cut out of is not there any more.
	for room in b.rooms:
		if room.active:
			room.active = false
			_rooms_active -= 1
			for item in room.items:
				item["blocks"] = PackedInt32Array()
	b.open_rooms.clear()
	_record_damage(b)
	b.recipe_version = RECIPE_VERSION
	b.toppled = true
	b.chunk = -1
	b.frames = PackedInt32Array()
	b.asm = null
	_materialised -= 1


func dematerialise(id: int) -> void:
	var b := get_building(id)
	if b == null or not b.is_materialised():
		return
	# A room's contents are bricks in this chunk. They go when it goes, and what
	# they leave behind is the diff.
	for room in b.rooms:
		if room.active:
			deactivate_room(id, room.id)
	_record_damage(b)
	b.recipe_version = RECIPE_VERSION
	# The profile is expressed in the tower recipe's vertical bands, and a player
	# build has none. Docs/BuildMode.md section 12 question 3 is exactly this:
	# what a multi-frame build's cheap representation should be. Until that is
	# answered a build has no shell tier, so it needs no profile either.
	if b.is_damaged() and not b.is_build():
		b.damage_profile = _build_damage_profile(b)
	for c in b.chunks():
		world.release_chunk(c)
	b.chunk = -1
	b.frames = PackedInt32Array()
	b.asm = null
	_materialised -= 1


## Read what is missing, frame by frame, back out of the world.
##
## This is the step that makes destruction permanent, and it is per frame
## because a block id only means anything inside one chunk.
func _record_damage(b: Building) -> void:
	var cs := b.chunks()
	for i in cs.size():
		b.set_dead_in(i, world.get_dead_blocks(cs[i]))


## The whole thing's local bounds, frames included -- what a blast has to test
## against before it can decide this building is out of range.
##
## Measured from the chunks rather than from the recipe: a rotated frame's
## extent is its grid turned by its rotation, and the world already holds that
## transform exactly.
func _measure(b: Building) -> AABB:
	var inv := b.xform.affine_inverse()
	var box := AABB()
	var first := true
	for c in b.chunks():
		var dims: Vector3i = world.get_chunk_dims(c)
		var cell := BrickWorld.get_cell_size()
		var size := Vector3(dims.x * cell.x, dims.y * cell.y, dims.z * cell.z)
		var local := inv * world.get_chunk_transform(c)
		for i in 8:
			var corner := local * Vector3(
					size.x if (i & 1) else 0.0,
					size.y if (i & 2) else 0.0,
					size.z if (i & 4) else 0.0)
			if first:
				box = AABB(corner, Vector3.ZERO)
				first = false
			else:
				box = box.expand(corner)
	return box


## Local bounds, whether or not this building has ever been built. A parametric
## tower knows its own box from its footprint; a build only knows it once its
## frames have stood up at least once.
func local_box(id: int) -> AABB:
	var b := get_building(id)
	if b == null:
		return AABB()
	if b.box != AABB():
		return b.box
	var cell := BrickWorld.get_cell_size()
	if b.is_build():
		var d: Vector3i = b.build.chunk_dims()
		return AABB(Vector3.ZERO, Vector3(d.x * cell.x, d.y * cell.y, d.z * cell.z))
	return AABB(Vector3.ZERO, Vector3(
			b.recipe.footprint_x * cell.x,
			TowerRecipe.total_plates(b.recipe.courses) * cell.y,
			b.recipe.footprint_z * cell.z))


## Damage a building wherever it is. Materialises it if it was only a recipe --
## applying damage does NOT require the building to be near a player, only
## showing the result does (Plan §4.4).
func damage(id: int, world_point: Vector3, radius: float) -> PackedInt32Array:
	var b := get_building(id)
	if b == null:
		return PackedInt32Array()
	var chunk := materialise(id)
	if chunk < 0:
		return PackedInt32Array()
	# Every frame, not only the root: a blast does not care which grid the brick
	# it removed happened to be authored in.
	var killed := PackedInt32Array()
	var cs := b.chunks()
	for i in cs.size():
		var hit_here: PackedInt32Array = world.apply_hit(cs[i], world_point, radius)
		if hit_here.is_empty():
			continue
		b.hit = true
		b.set_dead_in(i, world.get_dead_blocks(cs[i]))
		if i == 0:
			killed = hit_here
	return killed


## Free the bricks of buildings that have been quiet and are far away. Damage is
## kept; only the materialisation is given back.
func trim(keep_near: Vector3, radius: float, min_age_ms: int, budget: int = 8) -> int:
	var now := Time.get_ticks_msec()
	var freed := 0
	for b in buildings:
		if freed >= budget:
			break
		if not b.is_materialised():
			continue
		if now - b.materialised_at < min_age_ms:
			continue
		if b.xform.origin.distance_to(keep_near) < radius:
			continue
		dematerialise(b.id)
		freed += 1
	return freed


func report() -> Dictionary:
	var damaged := 0
	var blocks := 0
	for b in buildings:
		if b.is_damaged():
			damaged += 1
		for c in b.chunks():
			blocks += world.get_block_count(c)
	var fixtures := 0
	for b in buildings:
		fixtures += b.fixtures.size()
	return {
		"buildings": buildings.size(),
		"fixtures": fixtures,
		"materialised": _materialised,
		"damaged": damaged,
		"live_blocks": blocks,
		"materialise_count": _materialise_count,
		"materialise_ms": _materialise_ms,
	}


## Reduce a materialised building's occupancy to what a shell can draw.
##
## Gate G1b. A shell is generated from the recipe, so it cannot ask "is block N
## dead" -- but it can be told which stretches of which wall, in which band, are
## still standing. That is a few hundred bytes and it survives the bricks being
## freed, which is the whole point: damage lives in the truth layer and the
## picture is derived from it (Plan.md section 4.2).
##
## Only called for a DAMAGED building, and only at de-materialisation. The bands
## partition the building's height, so the whole profile is one pass over the
## chunk however many bands there are.
func _build_damage_profile(b: Building) -> Dictionary:
	# The walk itself is in C++ (BrickWorld::build_damage_profile). It used to
	# be here, and it cost 3.4 ms a building -- 128 rectangle scans per band
	# over roughly thirty bands -- which was two thirds of what de-materialising
	# cost and what kept the trim budget down to one building a run.
	#
	# The split is deliberate: the recipe owns where the bands are, the world
	# owns what is left standing in them.
	var bands := PackedInt32Array()
	for band in TowerRecipe.layout(b.recipe.courses):
		bands.push_back(int(band.y))
		bands.push_back(int(band.plates))
	return world.build_damage_profile(b.chunk, b.recipe.footprint_x, b.recipe.footprint_z,
			TowerRecipe.WALL_THICK, BuildingShell.SEGMENTS, bands)


