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


## A building's bricks have become a piece: it toppled whole. Its recipe points,
## room graph and navmesh obstacle are gone with it (Docs/AI.md section 3.5).
## Everything else a building does to its structure is a command, and arrives
## as WorldAuthority.committed.
signal handed_over(id: int)


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
	## frame -> ids of blocks that LEFT as part of a piece of their own. Not damage
	## (get_dead_blocks leaves them out on purpose) and not here: a building rebuilt
	## from its recipe has to leave them out, or every brick that fell off it grows
	## back while the piece it fell on still lies in the street. Found in the AI
	## work's P0 review; the stress pass trims a hundred buildings a run.
	var gone := {}
	## frame -> flat [id, hp, ...] of living blocks a gun has worn down
	## (BrickWorld.chip_hit). A rebuild from the recipe starts every brick at full
	## hp, and a building that forgot its chips would take more shots to break than
	## the same building on a machine that never let go of it.
	var worn := {}
	## frame -> ids of living blocks fire has charred (BrickWorld.scorch_hit): a
	## rebuild from the recipe paints every brick its own colour again.
	var scorched := {}
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
	## Bumped by every change to its blocks -- a hit, a detach, a cut. Caches
	## drawn from its structure (a room's fake) are stamped with it and redrawn
	## when it moves on. Kept across being given back and rebuilt, because the
	## damage is (Docs/Collapse.md 2.2).
	var structure_version := 0
	var recipe_version := 0
	var blocks := 0               ## what the recipe would produce, known after one build
	var materialised_at := 0      ## msec, for LRU de-materialisation
	## floor_lines, worked out once; null until asked.
	var floors_memo = null
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
	## Laid a storey at a time (Docs/Space.md 5.3a): `chunk` is a band chunk of
	## the template `band_template`, and only `storeys_laid` (ascending) are
	## bricks -- the rest are the rest shell. False for a building laid whole.
	var banded := false
	var band_template := -1
	var storeys_laid := PackedInt32Array()
	## How many runs of laid storeys carried a load of the storeys over them
	## (BuildingRegistry.ABOVE_OWNER), so a run that has merged into another
	## has its load taken off.
	var load_runs := 0
	## The storey that gave way under everything above it, which left as a
	## shell piece: storeys from here up are not this building's any more. -1
	## while it has them all.
	var cut_storey := -1
	## The damage record of the storeys that left, taken from the chunk as they
	## went -- they were absent, so it is only there (shell_piece_chunk).
	var cut_record := {}
	## storey -> when it was laid, msec: a storey just laid is not given back
	## to the brick budget at once (CityScene._trim_budget).
	var storey_laid_at := {}

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

	## What left one frame as pieces. See gone.
	func gone_in(frame: int) -> PackedInt32Array:
		return gone.get(frame, PackedInt32Array())

	## What a gun has worn down in one frame. See worn.
	func worn_in(frame: int) -> PackedInt32Array:
		return worn.get(frame, PackedInt32Array())

	func scorched_in(frame: int) -> PackedInt32Array:
		return scorched.get(frame, PackedInt32Array())

	## How many blocks this building has lost, and the frame that was counted on.
	##
	## Memoised because counting walks every block in the chunk, and the room
	## streaming pass asks "have the holes moved" once per ROOM -- which on the
	## big shapes is four thousand walks of a fifty-thousand-block chunk in a
	## single tick.
	var dead_count := -1
	var dead_frame := -1

	## Which of this building's rooms hold an item laid as bricks (Room.laid).
	##
	## Kept rather than found, because finding it means walking `rooms`, and a
	## building of the big shapes has four thousand of them.
	var laid_rooms: Array[int] = []

	func is_damaged() -> bool:
		if hit or not dead.is_empty():
			return true
		# Asked several times per building per shell pass: an untouched one
		# answers without values(), which copies the dictionary into an Array.
		if not dead_frames.is_empty():
			for ids in dead_frames.values():
				if not (ids as PackedInt32Array).is_empty():
					return true
		# Bricks that left as a piece: nothing died, and the building is still
		# a different shape. A tower cut clean through had its top fall off,
		# and was handed back with no profile -- its shell drawn whole again.
		if not gone.is_empty():
			for ids in gone.values():
				if not (ids as PackedInt32Array).is_empty():
					return true
		return false


## 2: every other floor's seams staggered (TowerRecipe.STAGGER).
const RECIPE_VERSION := 2

## Storey units (Docs/Space.md 5.3a): a building a blast or a look reaches is
## laid as the storeys reached, not whole. Off, every materialise lays the
## whole building, as it always did (CityScene --whole: the gate's "today").
var storey_units := true
## set_load owner for the weight of the intact storeys over a run of laid ones:
## ABOVE_OWNER - run. Wreckage on a building is owned by its piece id, >= 0.
const ABOVE_OWNER := -1000

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
##
## Snapped in the GRID FRAME at the spot (`grid_frame_at`): the world's own
## today, so this is the world grid exactly as before. On a planet it is the
## tangent frame there (Docs/Planets.md 9.2), and a building stands on that.
static func on_grid(xform: Transform3D) -> Transform3D:
	var frame := grid_frame_at(xform.origin)
	var local := frame.affine_inverse() * xform
	var yaw := local.basis.get_euler().y
	var quarter := int(round(yaw / (PI * 0.5)))
	var o := local.origin
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	return frame * Transform3D(Basis(Vector3.UP, quarter * PI * 0.5),
			Vector3(round(o.x / stud) * stud, round(o.y / plate) * plate, round(o.z / stud) * stud))


## The frame the stud grid is laid in at a world point: identity on the flat
## world. On a planet, the tangent frame at that point (Planets.md 4).
static func grid_frame_at(_p: Vector3) -> Transform3D:
	return Transform3D.IDENTITY


# --- building space: the one door (Docs/Planets.md 9.2) ----------------------
#
# A query that goes from the world into a building -- is this point in it,
# where does this ray meet it -- goes through these, in the building's own
# space, not through its world AABB. Today every building is on the world grid
# at a quarter turn and the two agree; a building tilted to a tangent frame, or
# drawn bent (Planets.md 4.2), changes only `to_building` and `to_world`.

## The building's box in its OWN space: corner at the origin, its cells' size.
static func own_box(b) -> AABB:
	var cell := BrickWorld.get_cell_size()
	var size: Vector3
	if b.is_build():
		var d: Vector3i = b.build.chunk_dims()
		size = Vector3(d.x * cell.x, d.y * cell.y, d.z * cell.z)
	else:
		size = Vector3(int(b.recipe.footprint_x) * cell.x,
				TowerRecipe.total_plates(int(b.recipe.courses)) * cell.y,
				int(b.recipe.footprint_z) * cell.z)
	return AABB(Vector3.ZERO, size)


static func to_building(b, p: Vector3) -> Vector3:
	return b.xform.affine_inverse() * p


static func to_world(b, p: Vector3) -> Vector3:
	return b.xform * p


## Is a world point inside the building's box, within `margin` metres?
static func contains(b, p: Vector3, margin := 0.0) -> bool:
	return own_box(b).grow(margin).has_point(to_building(b, p))


## How far along a world ray (unit `dir`) it first meets the building's box:
## INF for a miss or a box behind it. Distances survive the rigid transform.
static func ray_hit(b, from: Vector3, dir: Vector3) -> float:
	var inv: Transform3D = b.xform.affine_inverse()
	var f := inv * from
	var d := inv.basis * dir
	var box := own_box(b)
	var t0 := -INF
	var t1 := INF
	for a in 3:
		if absf(d[a]) < 1e-9:
			if f[a] < box.position[a] or f[a] > box.end[a]:
				return INF
			continue
		var ta := (box.position[a] - f[a]) / d[a]
		var tb := (box.end[a] - f[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t1 < maxf(t0, 0.0):
		return INF
	return maxf(t0, 0.0)


## Record a building. No chunk, no blocks, no mesh — just what it is and where.
##
## `program` is which rooms it has, as {room kind: weight} (Docs/Workshop.md,
## Stage F); empty is every kind alike.
func register(footprint_x: int, footprint_z: int, courses: int, xform: Transform3D,
		program: Dictionary = {}) -> int:
	var b := Building.new()
	b.id = buildings.size()
	b.recipe = {"footprint_x": footprint_x, "footprint_z": footprint_z, "courses": courses}
	if not program.is_empty():
		b.recipe["program"] = program.duplicate()
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
	# A generated building inside a player build is parameters until it is
	# placed (Docs/Workshop.md, Stage C), and so is furniture placed from the
	# catalogue (AssetPlacements). Everything below wants bricks.
	recipe = TowerBlockout.flatten(AssetPlacements.expand(recipe))
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
					b.recipe.courses, room_seed_of(building_id),
					b.recipe.get("program", {}))
			# The stairwell is a shaft with no floor in it, on every storey,
			# and furniture generated inside it stood on nothing: laid, it
			# hung in the air until something nearby broke and the solve
			# noticed. It is a keep-out exactly as a column is, so it goes
			# where the columns go. Copied first: a room's posts are the
			# lattice's own array, shared by every storey of every building
			# of this shape.
			# SNAPPED, as the recipe snaps them: the floor it leaves out is the
			# whole cells a keep-out touches, not the keep-out itself.
			var keep := TowerRecipe.snap_keepouts(_keepouts_of(b),
					b.recipe.footprint_x, b.recipe.footprint_z)
			if not keep.is_empty():
				for room in b.rooms:
					var plan := Rect2i(room.lo.x, room.lo.z, room.size.x, room.size.z)
					var mine: Array[Rect2i] = room.posts.duplicate()
					for k in keep:
						if (k as Rect2i).intersects(plan):
							mine.append(k)
					room.posts = mine
	return b.rooms


## The seed a building's rooms are generated from. One place, because a far
## building's windows paint the kind of room that is really behind them
## (BuildingShell.build_window_mesh) and have to ask with the same number.
func room_seed_of(building_id: int) -> int:
	return building_id * 2654435761


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


## The plate heights of a building's floors, in its own grid, bottom up: where
## a landing snaps a piece of it and a big collapse cuts it (IslandManager,
## CollapseDirector). From the structure record (Docs/DestructionLod.md 4): a
## generated building's frame (TowerRecipe.frame); a build's own `floors` when
## it has them, found in its bricks when it does not
## (StructureSpaces.floors_of_build, Docs/Structures.md 2.4) -- a build with no
## wide layer of structure has none, and a piece of it breaks where it is
## weakest, with no floor to prefer.
func floor_lines(building_id: int) -> PackedInt32Array:
	var b := get_building(building_id)
	if b == null:
		return PackedInt32Array()
	if b.floors_memo != null:
		return b.floors_memo
	var lines := PackedInt32Array()
	var floors: Array = []
	var down := 0   # the build's own grid to its chunk's (_rebase_of)
	if b.is_build():
		# The build's own recipe: `b.recipe` of a build is only its box.
		floors = (b.build.meta.get("structure", {}) as Dictionary).get("floors", [])
		if floors.is_empty():
			floors = StructureSpaces.floors_of_build(b.build)
		down = _rebase_of(b).y
	else:
		floors = TowerRecipe.frame(b.recipe.footprint_x, b.recipe.footprint_z,
				b.recipe.courses).floors
	for f in floors:
		lines.append(int(f[0]) - down)
	lines.sort()
	b.floors_memo = lines
	return lines


## Lay ONE item of a room into the building's chunk as bricks.
## [Interiors §8.4](../Docs/Interiors.md): what a blast or a bullet reaches
## becomes bricks -- that piece, and only that piece -- and is ordinary brick
## destruction from then on. The room is not opened and its other pieces stay
## a drawing. Returns how many blocks were laid.
##
## Only where it stands: an item whose floor is not mostly in this chunk is on
## a piece somewhere else (RoomManifest.item_floor_share), and is not here to
## be laid.
func lay_item(building_id: int, index: int, i: int) -> int:
	var b := get_building(building_id)
	var room := get_room(building_id, index)
	if b == null or room == null or not b.is_materialised() or b.toppled:
		return 0
	if room.items.is_empty():
		room.items = RoomManifest.items_for(room)
	if i < 0 or i >= room.items.size() or room.gone.has(i) or room.laid.has(i):
		return 0
	var item: Dictionary = room.items[i]
	var offset := _rebase_of(b)
	if RoomManifest.item_floor_share(world, b.chunk, str(item.type),
			(item.cell as Vector3i) - offset) <= 0.5:
		return 0
	var blocks := RoomManifest.build_item(world, b.chunk, palette,
			{"type": item.type, "cell": item.cell, "yaw": item.yaw}, 4 + int(i % 8), offset)
	if blocks.is_empty():
		# Something is already where it stands -- rubble, a fallen beam. It
		# cannot be both: it is gone, as an item a room could not place is.
		room.gone[i] = true
		return 0
	item["blocks"] = blocks
	room.laid[i] = true
	if not b.laid_rooms.has(index):
		b.laid_rooms.append(index)
	items_laid += 1
	return blocks.size()


var items_laid := 0   ## items laid as bricks one at a time, all told
var lay_usec := 0     ## the time compromise_items spent in lay_item, all told


## Lay ONE item of a room as bricks into a PIECE of the building: `chunk`, an
## island that came off it and kept the building's cells. Wreckage furniture
## is bricks (Interiors §8.14): it collides, it can be shot, it stays on its
## floor whichever way up the piece lies and at every distance. Returns how
## many blocks were laid.
##
## Only an item whose floor is mostly in `chunk` (item_floor_share), as for
## the building. Not recorded in the building's `laid_rooms` and its blocks are
## not kept: they are the piece's, and go where its bricks go. `room.laid`
## stays set, so neither the building nor a later piece lays or draws it again.
func lay_item_into(building_id: int, index: int, i: int, chunk: int) -> int:
	var b := get_building(building_id)
	var room := get_room(building_id, index)
	if b == null or room == null or chunk < 0:
		return 0
	if room.items.is_empty():
		room.items = RoomManifest.items_for(room)
	if i < 0 or i >= room.items.size() or room.gone.has(i) or room.laid.has(i):
		return 0
	var item: Dictionary = room.items[i]
	var offset := _rebase_of(b)
	if RoomManifest.item_floor_share(world, chunk, str(item.type),
			(item.cell as Vector3i) - offset) <= 0.5:
		return 0
	var blocks := RoomManifest.build_item(world, chunk, palette,
			{"type": item.type, "cell": item.cell, "yaw": item.yaw}, 4 + int(i % 8), offset)
	if blocks.is_empty():
		# Wreckage where it stood: it cannot be both, as in lay_item.
		room.gone[i] = true
		return 0
	room.laid[i] = true
	items_laid += 1
	return blocks.size()


## Every interior piece a blast reaches, where it stands: laid as bricks if
## somebody could see it (`build`), written off if nobody could -- for the
## pieces inside `radius` of the point and no others. Returns
## {laid: [[room, item], ...], gone: how many were written off}.
##
## Interiors section 5.1 is why nothing is built unseen: laying bricks means
## new collision on the host's body, and a firefight reaches thousands of
## pieces nobody will ever look at.
##
## Only what stands HERE. An item is on whichever chunk holds its floor -- the
## building, or a piece of it lying in the street (InteriorGroups) -- so one
## with no floor in this building is not gone, it is elsewhere, and a blast in
## the building may not write it off.
func compromise_items(building_id: int, world_point: Vector3, radius: float,
		build: bool = true) -> Dictionary:
	var out := {"laid": [], "gone": 0}
	var b := get_building(building_id)
	if b == null or b.is_build() or not b.is_materialised() or b.toppled:
		return out
	var local := b.xform.affine_inverse() * world_point
	var offset := _rebase_of(b)
	for room in rooms_of(building_id):
		if not room.local_box().grow(radius).has_point(local):
			continue
		if room.items.is_empty():
			room.items = RoomManifest.items_for(room)
		for i in room.items.size():
			if room.gone.has(i) or room.laid.has(i):
				continue
			var item: Dictionary = room.items[i]
			var box := RoomManifest.item_box(item)
			var nearest := local.clamp(box.position, box.end)
			if nearest.distance_to(local) > radius:
				continue
			if RoomManifest.item_floor_share(world, b.chunk, str(item.type),
					(item.cell as Vector3i) - offset) <= 0.5:
				continue   # not standing here: on a piece somewhere
			if build:
				var t_lay := Time.get_ticks_usec()
				var laid_n := lay_item(building_id, room.id, i)
				lay_usec += Time.get_ticks_usec() - t_lay
				if laid_n > 0:
					(out.laid as Array).append([room.id, i])
				elif room.gone.has(i):
					out.gone += 1
			else:
				room.gone[i] = true
				out.gone += 1
	return out


## The building's bricks are going back: an item laid as bricks goes with
## them. One with a brick destroyed is written off; one nothing touched is a
## drawing again the next time the building is bricks.
func _unlay_all(b: Building, dead: Dictionary) -> void:
	for index in b.laid_rooms:
		var room: Room = b.rooms[index]
		for i in room.laid:
			var item: Dictionary = room.items[i]
			for id in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
				if dead.has(id):
					room.gone[i] = true
					break
			item["blocks"] = PackedInt32Array()
		room.laid.clear()
	b.laid_rooms.clear()


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


## How many rooms there are, how many have a diff to their name, and how many
## interior pieces are bricks right now (lay_item).
func room_report() -> Dictionary:
	var total := 0
	var changed := 0
	var laid := 0
	for b in buildings:
		total += b.rooms.size()
		for room in b.rooms:
			if room.is_changed():
				changed += 1
		for index in b.laid_rooms:
			laid += (b.rooms[index] as Room).laid.size()
	return {"rooms": total, "changed": changed, "laid": laid}


# ---------------------------------------------------------------------------
# Fixtures (Docs/BuildMode.md section 9)
# ---------------------------------------------------------------------------

## The footprints a building's fixtures need clear of columns and floor.
##
## Asked BEFORE the recipe lays anything, because a stairwell is a shaft up the
## middle of a building and that is exactly where the columns carrying its
## floors want to stand. Taking them out afterwards left the panels above them
## holding on to nothing. See `Fixture.footprint`.
## A generated tower's bricks, its staircase's included, by what decides them:
## recipe + fixtures -> [BrickWorld template id, each fixture's block ids]. The
## biggest tower of the big city was 26 ms of laying bricks and 4 ms of stairs at
## every promotion; copying the first one built takes a few. Built for every
## shape when the city is laid out (prepare_templates), so not even the first
## promotion of a shape -- often the one a hit forces, mid-fight -- pays for it.
var _templates := {}


func _template_key(b: Building) -> String:
	# A build is its recipe: one template a recipe, however many are placed.
	var key := ("build %d" % b.build.get_instance_id()) if b.is_build() \
			else "%d,%d,%d" % [b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses]
	for f in b.fixtures:
		key += "|%s %s %s %d" % [f.kind, var_to_str(f.params), f.cell, f.role]
	return key


## Lay a generated tower and its fixtures into an empty chunk: from the template
## when there is one, and saving one when there is not. Returns true, having
## laid the fixtures too.
func _lay_tower(b: Building, chunk: int) -> bool:
	var key := _template_key(b)
	var t: Array = _templates.get(key, [])
	if not t.is_empty() and world.load_template(int(t[0]), chunk):
		var saved: Array = t[1]
		for i in b.fixtures.size():
			b.fixtures[i].blocks = (saved[i] as PackedInt32Array).duplicate()
		return true
	# What the fixtures need clear, before the columns go in. See
	# Fixture.footprint.
	TowerRecipe.build(world, chunk, palette,
			b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses, _keepouts_of(b))
	# Straight after the building's own blocks, as materialise always laid
	# them: a block id has to mean the same brick every time (_build_fixtures).
	var offset := _rebase_of(b)
	var lists := []
	for f in b.fixtures:
		f.build_into(world, chunk, fixture_parts(f.kind), offset)
		lists.append(f.blocks.duplicate())
	_templates[key] = [world.save_template(chunk), lists]
	return true


## Build the template of every tower shape in the city now, while it is being
## laid out, rather than at the first promotion of each. Returns milliseconds.
func prepare_templates() -> float:
	var t0 := Time.get_ticks_usec()
	for b in buildings:
		if b == null or b.is_build() or b.is_materialised() or b.toppled:
			continue
		_template_of(b)
	return float(Time.get_ticks_usec() - t0) / 1000.0


## The template of a generated tower's shape, built now if it was not: laid
## whole into a chunk of its own, saved, and the chunk let go. -1 for a build.
func _template_of(b: Building) -> int:
	if b.is_build():
		return _build_template_of(b)
	var key := _template_key(b)
	if not _templates.has(key):
		var chunk := world.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(
				b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses))
		# The fixtures' block lists are the building's own; put them back after.
		var kept := []
		for f in b.fixtures:
			kept.append(f.blocks)
		_lay_tower(b, chunk)
		for i in b.fixtures.size():
			b.fixtures[i].blocks = kept[i]
		world.release_chunk(chunk)
	return int((_templates[key] as Array)[0])


## A single-frame build's template, as a tower's: laid once, as materialise
## lays it -- the build, then its fixtures straight after (_build_fixtures) --
## saved, and the chunk let go. -1 for one of several frames.
func _build_template_of(b: Building) -> int:
	if not b.build.is_single_frame():
		return -1
	var key := _template_key(b)
	if not _templates.has(key):
		var chunk := world.create_chunk(Vector3i.ZERO, b.build.chunk_dims())
		b.build.build(world, chunk, palette)
		var kept := []
		for f in b.fixtures:
			kept.append(f.blocks)
		var offset := _rebase_of(b)
		var lists := []
		for f in b.fixtures:
			f.build_into(world, chunk, fixture_parts(f.kind), offset)
			lists.append(f.blocks.duplicate())
		for i in b.fixtures.size():
			b.fixtures[i].blocks = kept[i]
		_templates[key] = [world.save_template(chunk), lists]
		world.release_chunk(chunk)
	return int((_templates[key] as Array)[0])


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
			parts = StaircaseRecipe.flight_parts(palette)
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


## Goes up every time any building takes a chunk: an answer "this chunk is no
## building's" holds until it changes.
func materialise_count() -> int:
	return _materialise_count


## Build the real bricks. Idempotent: already-materialised buildings are returned
## as they are.
##
## `storeys` (Docs/Space.md 5.3a): with storey units on, a generated tower is
## laid as those storeys only -- a band chunk of its template, the rest absent
## -- and one already laid that way gets any of them it lacks. Empty lays the
## whole building, as it always did; so does a build, for now.
func materialise(id: int, storeys: PackedInt32Array = PackedInt32Array()) -> int:
	var b := get_building(id)
	if b == null:
		return -1
	if b.is_materialised():
		b.materialised_at = Time.get_ticks_msec()
		# Idempotent asked for nothing: a replay resolving a building's chunk
		# comes through here. Laying the rest is the caller's (lay_storeys).
		if b.banded and not storeys.is_empty():
			_lay_storeys(b, storeys)
		return b.chunk
	if b.toppled:
		return -1  # its bricks are an island now; building them again would double it

	# A building whose top left as a shell piece is never laid whole again:
	# that would grow back what is lying in the street.
	if storeys.is_empty() and b.cut_storey >= 0:
		for s in b.cut_storey:
			storeys.append(s)
	var banded := not storeys.is_empty() \
			and (not b.is_build() or b.build.is_single_frame()) \
			and (storey_units or b.cut_storey >= 0)
	var t0 := Time.get_ticks_usec()
	var fixtures_laid := false
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
	elif b.is_build() and not banded:
		b.chunk = world.create_chunk(Vector3i.ZERO, b.build.chunk_dims())
		b.build.build(world, b.chunk, palette)
	elif banded:
		# Every block of the template, absent; the storeys asked for are laid
		# below, once the record is in -- so they come in with their damage.
		var tid := _template_of(b)
		b.chunk = world.create_band_chunk(tid)
		b.band_template = tid
		b.banded = true
		b.storeys_laid = PackedInt32Array()
		b.load_runs = 0
		var saved: Array = (_templates[_template_key(b)] as Array)[1]
		for i in b.fixtures.size():
			b.fixtures[i].blocks = (saved[i] as PackedInt32Array).duplicate()
		fixtures_laid = true
	else:
		b.chunk = world.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(
				b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses))
		fixtures_laid = _lay_tower(b, b.chunk)
	if b.frames.is_empty():
		world.set_chunk_transform(b.chunk, b.xform)
	# The staircases and everything else fixed to it, in the same grid and the
	# same chunk. A fixture is not a separate object standing inside a building
	# (Fixture's own notes on why that was wrong); it is part of the building.
	if not b.fixtures.is_empty() and not fixtures_laid:
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
		b.gone = {}
		b.worn = {}
		b.scorched = {}
		b.recipe_version = RECIPE_VERSION
	var cs := b.chunks()
	for i in cs.size():
		world.kill_blocks(cs[i], b.dead_in(i))
		# And what left as pieces, which are still out there. Taken out as dead:
		# the bricks are not in this building any more, which is all a rebuilt
		# building has to know, and the next record lists them with the damage.
		world.kill_blocks(cs[i], b.gone_in(i))
		world.set_worn_blocks(cs[i], b.worn_in(i))
		world.set_scorched_blocks(cs[i], b.scorched_in(i))
	if b.banded:
		_lay_storeys(b, storeys)

	b.materialised_at = Time.get_ticks_msec()
	_materialised += 1
	_materialise_count += 1
	_materialise_ms += (Time.get_ticks_usec() - t0) / 1000.0
	return b.chunk


# ---------------------------------------------------------------------------
# Storey units (Docs/Space.md 5.3a)
# ---------------------------------------------------------------------------

## Where a building's storeys start, in plates of its own grid, bottom up, and
## then its top: storey s is [lines[s], lines[s + 1]). A tower's storey is its
## slab and the six courses over it (TowerRecipe.STOREY_PLATES); the last one
## is the roof slab and the cornice. A build has none yet.
func storey_lines(b: Building) -> PackedInt32Array:
	var out := PackedInt32Array()
	if b == null:
		return out
	if b.is_build():
		# A build's storeys are cut at the floors the floor finder finds in it
		# (Structures 2.4, floor_lines): each its slab and what stands on it, as
		# a tower's. One of several frames is laid whole (no storeys).
		if not b.build.is_single_frame():
			return out
		var btop: int = b.build.chunk_dims().y
		out.append(0)
		for f in floor_lines(b.id):
			if f > out[out.size() - 1] and f < btop:
				out.append(f)
		out.append(btop)
		return out
	var top: int = TowerRecipe.chunk_dims(b.recipe.footprint_x, b.recipe.footprint_z,
			b.recipe.courses).y
	var y := 0
	while y < top:
		out.append(y)
		y += TowerRecipe.STOREY_PLATES
	out.append(top)
	return out


## Every storey the building still has (none past one that left as a shell piece).
func all_storeys(b: Building) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n := storey_lines(b).size() - 1
	if b.cut_storey >= 0:
		n = mini(n, b.cut_storey)
	for s in n:
		out.append(s)
	return out


func storey_count(id: int) -> int:
	return maxi(storey_lines(get_building(id)).size() - 1, 0)


## The storeys a blast of `radius` metres at a world point reaches, by height
## alone: the caller has already found it inside the building's box.
func storeys_in(id: int, world_point: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var b := get_building(id)
	if b == null:
		return out
	var lines := storey_lines(b)
	var local := b.xform.affine_inverse() * world_point
	var plate := BrickWorld.get_plate_metres()
	var lo := floori((local.y - radius) / plate)
	var hi := floori((local.y + radius) / plate)
	for s in lines.size() - 1:
		if lines[s + 1] > lo and lines[s] <= hi:
			out.append(s)
	# Over its roof or under its ground floor: the storey nearest. Never none --
	# none asks for the whole building.
	if out.is_empty() and lines.size() > 1:
		out.append(0 if hi < 0 else lines.size() - 2)
	return out


## Is it bricks only in part -- a band chunk with storeys still absent?
func is_partial(b: Building) -> bool:
	if b == null or not b.banded or not b.is_materialised():
		return false
	var n := storey_count(b.id)
	if b.cut_storey >= 0:
		n = mini(n, b.cut_storey)
	return b.storeys_laid.size() < n


## Lay more storeys of a building already laid a storey at a time. Returns how
## many blocks came in: 0 for a building laid whole, or with them all.
func lay_storeys(id: int, storeys: PackedInt32Array) -> int:
	var b := get_building(id)
	if b == null or not b.is_materialised() or not b.banded:
		return 0
	return _lay_storeys(b, storeys)


## Give storeys of a building laid a storey at a time back to its rest shell
## (Docs/Space.md 5.3, the brick budget): their bricks absent again, their
## damage kept -- in the record, and in the profile the rest shell draws them
## with. A room's piece laid as bricks on them goes back to being drawn, or is
## written off if a brick of it died (as dematerialise does). Returns how many
## blocks went; the caller gives the building back whole if none are left.
func unlay_storeys(id: int, storeys: PackedInt32Array) -> int:
	var b := get_building(id)
	if b == null or not b.banded or not b.is_materialised():
		return 0
	var lines := storey_lines(b)
	var going := PackedInt32Array()
	for s in storeys:
		if b.storeys_laid.has(s):
			going.append(s)
	if going.is_empty():
		return 0
	# What the shell will draw of them: their damage as it is now. (A build's
	# shell asks its blocks' record instead, which the chunk keeps.)
	if not b.is_build():
		b.damage_profile = _build_damage_profile(b)
	if not b.laid_rooms.is_empty():
		var dead := {}
		for d in world.get_dead_blocks(b.chunk):
			dead[d] = true
		for index in b.laid_rooms.duplicate():
			var room: Room = b.rooms[index]
			var on := false
			for s in going:
				if room.lo.y >= lines[s] and room.lo.y < lines[s + 1]:
					on = true
			if not on:
				continue
			for i in room.laid:
				var item: Dictionary = room.items[i]
				for bid in (item.get("blocks", PackedInt32Array()) as PackedInt32Array):
					if dead.has(bid):
						room.gone[i] = true
					world.remove_block(b.chunk, bid)
				item["blocks"] = PackedInt32Array()
			room.laid.clear()
			b.laid_rooms.erase(index)
	var n := 0
	for s in going:
		n += world.unlay_band(b.chunk, lines[s], lines[s + 1], b.blocks)
		var k := b.storeys_laid.find(s)
		if k >= 0:
			b.storeys_laid.remove_at(k)
	b.structure_version += 1
	b.floors_memo = null
	set_storey_bounds(b)
	storeys_unlaid_total += going.size()
	return n


var storeys_unlaid_total := 0   ## storeys given back to a rest shell, all told


## How many storeys this building has laid, of how many (for the gates).
func storey_report(id: int) -> Dictionary:
	var b := get_building(id)
	if b == null:
		return {}
	return {"banded": b.banded, "laid": b.storeys_laid.duplicate(), "of": storey_count(id),
			"cut": b.cut_storey,
			"bricks": (world.get_block_count(b.chunk) - world.get_absent_count(b.chunk))
					if b.is_materialised() else 0,
			"occupancy_bytes": world.get_occupancy_bytes(b.chunk) if b.is_materialised() else 0}


var storeys_laid_total := 0     ## storeys laid one at a time, all told
var storey_blocks_total := 0    ## and the blocks they brought in
var storey_ms := 0.0


func _lay_storeys(b: Building, storeys: PackedInt32Array) -> int:
	var t0 := Time.get_ticks_usec()
	var lines := storey_lines(b)
	var n := lines.size() - 1
	var taking := PackedInt32Array()
	for s in storeys:
		if s < 0 or s >= n or b.storeys_laid.has(s) or taking.has(s):
			continue
		if b.cut_storey >= 0 and s >= b.cut_storey:
			continue   # left as a shell piece
		taking.append(s)
	if taking.is_empty():
		return 0
	var laid := _lay_runs(b.chunk, b.band_template, lines, taking)
	for s in taking:
		b.storeys_laid.append(s)
		b.storey_laid_at[s] = Time.get_ticks_msec()
		storeys_laid_total += 1
	b.storeys_laid.sort()
	storey_blocks_total += laid
	b.structure_version += 1
	b.floors_memo = null
	set_storey_bounds(b)
	storey_ms += float(Time.get_ticks_usec() - t0) / 1000.0
	return laid


## Lay `storeys` of a band chunk from its template: each run of storeys one
## over the other in ONE BrickWorld.lay_band. A lay that reaches past the grid's
## window builds the grid again for every brick laid so far (set_occupancy_window),
## so a storey a call, from the bottom up, built it again for every storey: a
## shell piece of 34 storeys, 23,801 bricks, took 68.5 ms to lay in a blast's
## tick (--big --shot, 2026-10-23). The same bricks either way -- a storey's
## band ends where the next begins. Sorts `storeys`. Returns the blocks laid.
func _lay_runs(chunk: int, template: int, lines: PackedInt32Array, storeys: PackedInt32Array) -> int:
	storeys.sort()
	var laid := 0
	var k := 0
	while k < storeys.size():
		var first := storeys[k]
		var last := first
		while k + 1 < storeys.size() and storeys[k + 1] == last + 1:
			k += 1
			last = storeys[k]
		laid += world.lay_band(chunk, template, lines[first], lines[last + 1])
		k += 1
	return laid


## The runs of laid storeys, as [first, one past the last].
static func storey_runs(laid: PackedInt32Array) -> Array:
	var runs: Array = []
	for s in laid:
		if not runs.is_empty() and int(runs[-1][1]) == s:
			runs[-1][1] = s + 1
		else:
			runs.append([s, s + 1])
	return runs


## What holds the laid storeys and what they hold (Docs/Space.md 5.2): each run
## stands on the intact storey under it -- its bottom plate anchored -- and
## carries the weight of everything over it on its top bricks. Asked again after
## a solve, because the top bricks a hit takes out carry nothing any more and
## their share has to go to the ones still standing.
func set_storey_bounds(b: Building) -> void:
	if b == null or not b.banded or not b.is_materialised():
		return
	var lines := storey_lines(b)
	var top_y: int = lines[lines.size() - 1] if b.cut_storey < 0 else lines[b.cut_storey]
	var runs := storey_runs(b.storeys_laid)
	if runs.is_empty():
		return
	world.set_foundation_level(b.chunk, lines[int(runs[0][0])])
	var anchors := PackedInt32Array()
	for r in range(1, runs.size()):
		anchors.append(lines[int(runs[r][0])])
	world.set_anchor_levels(b.chunk, anchors)
	for r in runs.size():
		var y_top: int = lines[int(runs[r][1])]
		var ids := world.get_blocks_topping(b.chunk, y_top) if y_top < top_y \
				else PackedInt32Array()
		var mass := world.get_template_mass(b.band_template, y_top, top_y) \
				if not ids.is_empty() else 0.0
		if ids.is_empty() or mass <= 0.0:
			world.clear_load(b.chunk, ABOVE_OWNER - r)
		else:
			world.set_load(b.chunk, ABOVE_OWNER - r, ids, mass / ids.size())
	for r in range(runs.size(), b.load_runs):
		world.clear_load(b.chunk, ABOVE_OWNER - r)
	b.load_runs = runs.size()


## The runs whose top has nothing left standing under the storey on it -- the
## intact storeys over such a run hang on nothing -- or what is left stands
## off to one side of their weight, so they tip (Docs/Space.md 5.3a). Returns
## the lowest storey that has lost its support, or -1.
func storey_gave_way(id: int) -> int:
	var b := get_building(id)
	if b == null or not b.banded or not b.is_materialised():
		return -1
	var lines := storey_lines(b)
	var n := lines.size() - 1
	var top := n if b.cut_storey < 0 else b.cut_storey
	gave_way_tipping = false
	for run in storey_runs(b.storeys_laid):
		var above: int = int(run[1])
		if above >= top:
			continue   # nothing over it
		var under := world.get_blocks_topping(b.chunk, lines[above])
		if under.is_empty():
			return above
		# Still carried, but off balance: the weight of everything over it
		# stands outside what is left under it, on plan. The stress solve never
		# sees that -- what is left only takes it in compression -- and the
		# building, laid whole, would have tipped (BrickWorld.check_stability).
		# What is above leaves resting on what is left, and tips over its edge.
		var com := world.get_template_com(b.band_template, lines[above], lines[top])
		var hull := Geometry2D.convex_hull(world.get_blocks_footprint(b.chunk, under))
		if hull.size() >= 3 and not Geometry2D.is_point_in_polygon(Vector2(com.x, com.z), hull):
			gave_way_tipping = true
			return above
	return -1


## Whether the last storey_gave_way was a tip (true) or nothing left under it.
var gave_way_tipping := false


## Everything from storey `s` up has left the building as a shell piece: it is
## not this building's any more. Laid storeys up there leave as brick pieces --
## the caller cuts them out; this only says they are not the building's.
func cut_storeys(id: int, s: int) -> void:
	var b := get_building(id)
	if b == null:
		return
	if b.is_materialised():
		b.cut_record = {"dead": world.get_dead_blocks(b.chunk),
				"gone": world.get_detached_blocks(b.chunk),
				"worn": world.get_worn_blocks(b.chunk),
				"scorched": world.get_scorched_blocks(b.chunk)}
	b.cut_storey = s if b.cut_storey < 0 else mini(b.cut_storey, s)
	var keep := PackedInt32Array()
	for k in b.storeys_laid:
		if k < b.cut_storey:
			keep.append(k)
	b.storeys_laid = keep
	b.structure_version += 1
	b.floors_memo = null
	b.hit = true
	set_storey_bounds(b)
	# Their rooms went with them: written off, as a fallen building's are, so
	# nothing draws them where the storeys stood -- now or after it is given
	# back. (The pieces on laid storeys that left as bricks ride those.)
	if not b.is_build():
		var y_cut: int = storey_lines(b)[b.cut_storey]
		for room in rooms_of(id):
			if room.lo.y < y_cut:
				continue
			if room.items.is_empty():
				room.items = RoomManifest.items_for(room)
			for i in room.items.size():
				if not room.laid.has(i):
					room.gone[i] = true


## A chunk holding storeys [lo, hi) of a building that left it as a shell
## piece -- all but `holes`, the storeys that left as bricks -- laid from its
## template with the record they went with, at `xform`. What a shell piece
## becomes when it is made bricks (CityScene._piece_to_bricks); a replay makes
## the same one (StructureReplayer, SHELL_BRICKS). The caller cuts the piece
## out of it (`get_blocks_in_band`) and releases it.
func shell_piece_chunk(id: int, lo: int, hi: int, holes: PackedInt32Array,
		xform: Transform3D) -> int:
	var b := get_building(id)
	if b == null:
		return -1
	var lines := storey_lines(b)
	var tid := _template_of(b)
	if tid < 0:
		return -1
	var chunk := world.create_band_chunk(tid)
	if not b.cut_record.is_empty():
		world.kill_blocks(chunk, b.cut_record.dead)
		world.kill_blocks(chunk, b.cut_record.gone)
		world.set_worn_blocks(chunk, b.cut_record.worn)
		world.set_scorched_blocks(chunk, b.cut_record.scorched)
	var storeys := PackedInt32Array()
	for s in range(lo, hi):
		if not holes.has(s):
			storeys.append(s)
	_lay_runs(chunk, tid, lines, storeys)
	world.set_chunk_transform(chunk, xform)
	return chunk


## The bands of the shell (TowerRecipe.layout, as the damage profile counts
## them) of each storey: storey -> [first band, one past the last].
func _band_storeys(b: Building) -> PackedInt32Array:
	var out := PackedInt32Array()
	for band in TowerRecipe.layout(b.recipe.courses):
		@warning_ignore("integer_division")
		out.append(int(band.y) / TowerRecipe.STOREY_PLATES)
	return out


## What a build's shell (BuildShell, which walks block ids) leaves out to draw
## only the storeys `keep` says: one Dictionary of block ids, frame 0's -- every
## block of a storey `keep` refuses, and every block the record has dead or
## gone. The rest shell of a build laid a storey at a time, and its shell piece.
func build_hidden(b: Building, keep: Callable) -> Array:
	var hide := {}
	var lines := storey_lines(b)
	if b.is_materialised():
		for d in world.get_dead_blocks(b.chunk):
			hide[d] = true
		for d in world.get_detached_blocks(b.chunk):
			hide[d] = true
	elif not b.dead.is_empty():
		for d in b.dead:
			hide[d] = true
	var lo: Vector3i = b.build.origin()
	for i in b.build.size():
		if b.build.frame_of(i) != 0:
			continue
		var y: int = b.build.cell_of(i).y - lo.y
		var s := lines.size() - 2
		while s > 0 and lines[s] > y:
			s -= 1
		if not bool(keep.call(s)):
			hide[i] = true
	return [hide]


## A profile of a partly laid building: the bricks' own for laid storeys
## (`live`), the kept one for the rest, and every band of a storey cut away
## gone. `hide_laid` marks laid storeys' bands gone instead -- the rest shell,
## drawn beside the bricks rather than in place of them.
func merged_profile(b: Building, live: Dictionary, hide_laid := false) -> Dictionary:
	var out := {}
	var storey_of := _band_storeys(b)
	for i in storey_of.size():
		var s: int = storey_of[i]
		if b.cut_storey >= 0 and s >= b.cut_storey:
			out[i] = PackedInt32Array([0, 0, 0, 0])
		elif b.banded and b.storeys_laid.has(s):
			if hide_laid:
				out[i] = PackedInt32Array([0, 0, 0, 0])
			elif live.has(i):
				out[i] = live[i]
		elif b.damage_profile.has(i):
			out[i] = b.damage_profile[i]
	return out


## What the rest shell of a partly laid building draws: its storeys still
## whole, with the damage they had when its bricks were last given back.
func rest_profile(id: int) -> Dictionary:
	var b := get_building(id)
	if b == null or b.is_build():
		return {}
	return merged_profile(b, {}, true)


## Give the bricks back but keep the damage. The building returns to being a
## recipe plus a list of what is missing from it.
## Give the chunk away rather than freeing it: the caller now owns those bricks.
## Everything dematerialise() does, except the release.
func hand_over(id: int) -> void:
	var b := get_building(id)
	if b == null or not b.is_materialised():
		return
	# The bricks are about to belong to an island, a piece laid as bricks
	# included: it rides the piece it was standing on (Interiors section 4.2),
	# and stays `laid` so that no drawing of that piece shows it twice.
	_record_damage(b)
	b.recipe_version = RECIPE_VERSION
	b.toppled = true
	b.chunk = -1
	b.frames = PackedInt32Array()
	b.asm = null
	_materialised -= 1
	handed_over.emit(id)


func dematerialise(id: int) -> void:
	var b := get_building(id)
	if b == null or not b.is_materialised():
		return
	# A piece laid as bricks is bricks in this chunk. It goes when the chunk
	# goes, and what it leaves behind is the diff. The dead are asked once for
	# all of them, and nothing is taken out of a chunk that is about to be
	# released -- and only if something was laid at all: the dead of a big
	# building is a walk of fifty thousand blocks.
	if not b.laid_rooms.is_empty():
		var dead := {}
		for dead_id in world.get_dead_blocks(b.chunk):
			dead[dead_id] = true
		_unlay_all(b, dead)
	_record_damage(b)
	b.recipe_version = RECIPE_VERSION
	# The profile is expressed in the tower recipe's vertical bands, and a player
	# build has none. Docs/BuildMode.md section 12 question 3 is exactly this:
	# what a multi-frame build's cheap representation should be. Until that is
	# answered a build has no shell tier, so it needs no profile either.
	if (b.is_damaged() or b.cut_storey >= 0) and not b.is_build():
		b.damage_profile = _build_damage_profile(b)
	for c in b.chunks():
		world.release_chunk(c)
	b.chunk = -1
	b.frames = PackedInt32Array()
	b.asm = null
	b.banded = false
	b.storeys_laid = PackedInt32Array()
	b.load_runs = 0
	_materialised -= 1


## Read what is missing, frame by frame, back out of the world.
##
## This is the step that makes destruction permanent, and it is per frame
## because a block id only means anything inside one chunk.
func _record_damage(b: Building) -> void:
	var cs := b.chunks()
	for i in cs.size():
		b.set_dead_in(i, world.get_dead_blocks(cs[i]))
		b.gone[i] = world.get_detached_blocks(cs[i])
		b.worn[i] = world.get_worn_blocks(cs[i])
		b.scorched[i] = world.get_scorched_blocks(cs[i])


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
	# The storeys it reaches, and no others (Docs/Space.md 5.3a). A build of
	# several frames is laid whole (storey_lines gives it none).
	var chunk := materialise(id, storeys_in(id, world_point, radius)
			if storey_units else PackedInt32Array())
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
	var fixtures := 0
	for b in buildings:
		if b.is_damaged():
			damaged += 1
		# Only a building holding bricks has chunks to count (chunks() is
		# empty otherwise), and most of the register -- trees and far
		# towers -- holds none.
		if b.chunk >= 0 or not b.frames.is_empty():
			for c in b.chunks():
				blocks += world.get_block_count(c)
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
## A building's damage as shell segment masks, from its bricks if it has them.
## For drawing a stand-in of a building that is still bricks (its shadow).
func live_damage_profile(id: int) -> Dictionary:
	var b := get_building(id)
	if b == null or b.is_build():
		return {}
	if not b.is_materialised():
		return b.damage_profile
	return _build_damage_profile(b)


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
	var live: Dictionary = world.build_damage_profile(b.chunk, b.recipe.footprint_x,
			b.recipe.footprint_z, TowerRecipe.WALL_THICK, BuildingShell.SEGMENTS, bands)
	# Laid a storey at a time: the storeys never laid are not gone, they are
	# what the profile last said (Docs/Space.md 5.3a).
	if b.banded or b.cut_storey >= 0:
		return merged_profile(b, live)
	return live

