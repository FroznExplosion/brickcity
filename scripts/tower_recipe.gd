class_name TowerRecipe

## A building as a recipe rather than as brick data.
##
## Today it is a test fixture. It is also the shape M3 needs: a building at rest
## is its recipe plus a baked mesh, and brick data is generated on first damage
## (Docs/Plan.md section 2 / spec section 5). Keeping the generator pure and
## re-runnable from parameters is the whole trick, so it is written that way.

const WALL_THICK := 2        # studs
const PLATES_PER_COURSE := 3
## Six brick courses, then a floor, then six more on top of it. The floor
## spans the WHOLE footprint -- walls included -- so it is part of the exterior,
## reads as a band from outside, and the walls above genuinely sit on it.
##
## And the floor is IN the wall. Its edge panels run out under the exterior
## walls to the building's face, so every course of wall below a floor carries
## that floor's edge on its studs and every course above stands on it. It used
## to stop at the inside face of the wall, with a ring of 2x2 plates under the
## wall itself -- and plates side by side are not joined to each other, so not
## one floor panel in the city touched a wall (tools/structure_probe.gd: 0 of
## 840 on the biggest tower). Every floor hung on its columns alone.
## Six, not four. The figure is four bricks tall (Docs/Parts/README.md), so a
## storey is the figure, a course of headroom, and the lintel course a doorway
## is cut under: five bricks clear through a door, six under the slab. At four
## the figure could not stand up indoors. Buildings did NOT get taller when this
## changed -- the city's shapes kept their height and lost floors instead, and
## floors are three quarters of a building's bricks (Docs/Scale.md).
const COURSES_PER_FLOOR := 6
const SLAB_PLATES := 1
const SLAB_COLOUR := 2

## THE LATTICE.
##
## A storey is laid on one grid, worked out before a block is placed: floor
## panels as the cells, columns on the points where four cells meet, interior
## walls along the lines. The grid starts at the building's OUTER face, so the
## cells round the edge run under the exterior walls and the floor is part of
## the wall rather than a lid set inside it.
##
## A column stands CENTRED on its lattice point, so its top carries the corner
## of all four panels that meet there and ties them together -- plates side by
## side are not joined, and a column under one panel's corner joined nothing.
##
## It only works if the footprint DIVIDES: `k * PANEL`. Five earlier attempts
## stretched the lattice to fit arbitrary footprints and every one failed in
## the same place -- the strip left over at the far wall, too narrow for a
## panel and too far from a column. The city's shape tables carry conforming
## footprints and the strip does not exist. Docs/Scale.md.
##
## PANEL is in studs, so a printed brick still lines up: this is a multiple of
## the stud pitch, not a departure from it. The 10x10 panel is a structural
## part rather than a real brick, which is allowed -- the building's frame is
## not something anybody prints.
const PANEL := 10
## A column is six bricks, which is COURSES_PER_FLOOR of brickwork -- so it
## stands on one floor and the next floor stands on it.
const COLUMN_PLATES := COURSES_PER_FLOOR * PLATES_PER_COURSE
const COLUMN_COLOUR := 3

## How many panels wide a room is. It is a cost decision before it is a spatial
## one: an interior wall is COURSES_PER_FLOOR of brickwork running the width of
## the building on EVERY storey, so halving the room roughly doubles what the
## interior costs. Three panels is about ten metres.
const ROOM_PANELS := 3
const ROOM_WALL_COLOUR := 2
## How thick an interior wall is, in studs: 2 is 2x4 bricks, 1 is 1x4.
##
## Two, and it is a structural choice rather than a look. A two-stud wall is
## centred on the seam between two floor panels, so its bottom course stands
## on both of them and its top course carries both panels above -- the wall
## TIES the floor together along the seam. A one-stud wall can only stand on
## one side of a seam, so the panels either side of it are joined by the columns
## at their corners and nothing else. Measured both ways; see Docs/Scale.md.
const ROOM_WALL_THICK := 2
const DOOR_WIDE := 4         ## studs of doorway

## Windows: where a wall is deliberately missing.
##
## Interiors §3 makes visibility a portal test -- "can the player see into this
## room through an opening" -- and until now every opening in the city was a hole
## somebody blew, because a generated building had none. So the test could not
## fire on an intact building and a room could only be entered, never seen into.
##
## A window is a gap in a RUN, which is all it needs to be: the run lays the full
## wall thickness in one pass, so a gap in it is a hole clean through.
##
## The two constraints that fix everything else about them:
##
##   * **The lintel is the last course, and the slab is over that.** A gap with
##     brickwork over it is brickwork resting on air unless something bridges
##     the opening, and a greedy run gives no such guarantee on its own. What
##     does guarantee it is the bond: courses alternate which pair of walls owns
##     the corners, so the course above a window always starts half a brick
##     offset from the course the window is cut in, and the bricks over the
##     opening are carried on the pier at one end each. That is a brick lintel,
##     built the way a brick lintel is built. Above it is the floor slab, which
##     is tied to all four walls and is the strongest thing in the building.
##
##     Cutting the top TWO courses instead -- letting the slab be the lintel --
##     works and looks the same, and it is not free: it leaves the slab joined
##     to its walls only at the piers. Measured on the 200-building stress pass
##     that tripled the splits (1321 against 440), doubled the breaks and put
##     the damage phase at 7.5 fps. A building is held together at the band
##     where its floors meet its walls, and windows do not go there.
##   * **The corners stay solid.** WINDOW_INSET studs at each end of every run,
##     because the corners are what make the four walls one structure
##     (see `build`) and a quoin with a hole in it is four walls again.
const WINDOW_WIDE := 4       ## studs of opening
const WINDOW_PITCH := 8      ## studs from one opening to the next
## On a four-stud boundary, so a run breaks into whole bricks either side of an
## opening instead of closing each pier with 2x2s and 1x2s.
const WINDOW_INSET := 4      ## solid wall to leave at each corner
## Three: a sill two bricks up and a head five up, under the lintel -- a window
## a four-brick figure looks out of rather than a slot at its feet.
const WINDOW_COURSES := 3    ## how many courses tall, below the lintel course
## A lintel has to LAND on the solid wall either side of its opening, and laid
## from a multiple of the brick length it does not -- the openings are on that
## same multiple, so a brick comes down exactly across one and bridges nothing.
## Half a brick of lead shifts the joints off the opening edges.
const LINTEL_LEAD := 2

# Filament indices, matching brick_grid.h.
const COURSE_COLOURS := [4, 5, 6, 11, 2, 8]  # red, orange, yellow, tan, grey, blue
const BASE_COLOUR := 3                        # dark grey


## Bake the parts this recipe needs: the standard palette plus its own cornice.
##
## The palette itself lives in BrickPalette -- one table, one naming rule, one
## mass rule -- because build mode needs the same list and a test tower has no
## business owning it.
static func bake_palette(world: BrickWorld) -> Dictionary:
	var out := BrickPalette.bake(world)
	out["buttress_2x2"] = bake_buttress(world)
	return out


## A part that does NOT fill its bounding box, used as a cornice so the masked
## path is exercised by the real scene rather than only by a probe.
##
## Profile, looking along +X, with +Z to the right:
##
##     y=2  # .
##     y=1  # .
##     y=0  # #
##          z0 z1
##
## The z=1 column only reaches one plate, so it carries no stud at the bounding
## box top -- and the stud mask says so, which is what stops the next course
## clipping to thin air. That mask is a structural fact the connectivity graph
## reads, not decoration.
static func bake_buttress(world: BrickWorld) -> int:
	var size := Vector3i(2, 3, 2)
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var solid := 1 if (z == 0 or y == 0) else 0
				cells[x + size.x * (y + size.y * z)] = solid

	var studs := PackedByteArray()
	studs.resize(size.x * size.z)
	for z in size.z:
		for x in size.x:
			studs[x + size.x * z] = 1 if z == 0 else 0

	# Solid all across the underside, so it clips down onto anything.
	var sockets := PackedByteArray()
	sockets.resize(size.x * size.z)
	sockets.fill(1)

	return world.bake_shaped_archetype("buttress_2x2", size, 0.9, cells, studs, sockets)


## The vertical layout of a building, band by band. Both the brick recipe and
## the shell mesh walk this, so what you see at a distance and what you get when
## it materialises are the same building by construction.
## Memoised. The bands of a tower are a pure function of its course count,
## and this is asked for on hot paths -- room streaming reaches it twice per
## building per tick through RoomManifest.lattice_for -- while building a
## couple of hundred Dictionaries every time it is.
static var _layouts := {}


static func layout(courses: int) -> Array[Dictionary]:
	if _layouts.has(courses):
		return _layouts[courses]
	var built := _build_layout(courses)
	_layouts[courses] = built
	return built


static func _build_layout(courses: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var y := 0
	out.append({"kind": "base", "y": y, "plates": SLAB_PLATES})
	y += SLAB_PLATES
	for c in courses:
		out.append({"kind": "course", "y": y, "plates": PLATES_PER_COURSE, "index": c})
		y += PLATES_PER_COURSE
		if (c + 1) % COURSES_PER_FLOOR == 0:
			@warning_ignore("integer_division")
			var floor_number := (c + 1) / COURSES_PER_FLOOR
			out.append({"kind": "slab", "y": y, "plates": SLAB_PLATES, "floor": floor_number})
			y += SLAB_PLATES
	out.append({"kind": "cornice", "y": y, "plates": PLATES_PER_COURSE})
	return out


static func total_plates(courses: int) -> int:
	var l := layout(courses)
	var last: Dictionary = l[l.size() - 1]
	return int(last.y) + int(last.plates)


static func chunk_dims(footprint_x: int, footprint_z: int, courses: int) -> Vector3i:
	return Vector3i(footprint_x, total_plates(courses) + 1, footprint_z)


## The lattice lines along one axis: the building's outer face, then every
## PANEL studs. On a conforming footprint the last line is exactly one panel
## short of the far face, so the cells tile the footprint with nothing over.
static func lattice(footprint: int) -> Array:
	var out: Array = [0]
	var at := PANEL
	while at + PANEL <= footprint:
		out.append(at)
		at += PANEL
	return out


## Where the interior walls run, and what they divide a storey into.
##
## Walls are on lattice lines and nowhere else, so every stretch of wall has a
## column under it every PANEL studs by construction. An earlier version stood
## the walls on the floor panels instead and put four courses of brickwork
## through whichever single column happened to be under the panel they crossed:
## 880 stress failures, 1,724 blocks shed.
##
## Pure arithmetic on two integers, so the builder and RoomManifest get the same
## answer -- which is the point. Two descriptions of one layout is how every
## item in the city came to be laid a plate above the floor.
static func plan(footprint_x: int, footprint_z: int) -> Dictionary:
	var key := Vector2i(footprint_x, footprint_z)
	if _plans.has(key):
		return _plans[key]
	var built := _build_plan(footprint_x, footprint_z)
	_plans[key] = built
	return built


static var _plans := {}


static func _build_plan(footprint_x: int, footprint_z: int) -> Dictionary:
	var t := WALL_THICK
	var xs := lattice(footprint_x)
	var zs := lattice(footprint_z)
	# Where the floor's panels land. Worked out here so that anything else that
	# needs to know reads the same answer instead of its own.
	var panels: Array = []
	for i in xs.size():
		var px0: int = int(xs[i])
		var px1: int = int(xs[i + 1]) if i + 1 < xs.size() else footprint_x
		for j in zs.size():
			var pz0: int = int(zs[j])
			var pz1: int = int(zs[j + 1]) if j + 1 < zs.size() else footprint_z
			for e in pack_cell(px1 - px0, pz1 - pz0):
				var p: Vector3i = e
				panels.append(Vector3i(px0 + p.x, pz0 + p.y, p.z))
	# The columns: one centred on every point where four cells meet. The
	# points on the outer face need none -- the wall is the column there.
	var columns: Array[Rect2i] = []
	for i in range(1, xs.size()):
		for j in range(1, zs.size()):
			columns.append(Rect2i(int(xs[i]) - 1, int(zs[j]) - 1, 2, 2))
	# A footprint that does not divide leaves a strip of smaller plates. Any
	# of them that reaches neither the wall nor a column gets one of its own
	# at its corner, which is the old rule and the right price for not
	# dividing.
	for e in panels:
		var p: Vector3i = e
		if p.z >= PANEL:
			continue
		if p.x < t or p.y < t or p.x + p.z > footprint_x - t or p.y + p.z > footprint_z - t:
			continue
		var n: int = 2 if p.z >= 2 else 1
		var r := Rect2i(p.x, p.y, n, n)
		var taken := false
		for c in columns:
			if c.intersects(r):
				taken = true
				break
		if not taken:
			columns.append(r)
	# Interior walls, on lattice lines, as the WALL'S near face: a two-stud
	# wall straddles the seam, a one-stud wall stands just past it.
	@warning_ignore("integer_division")
	var half: int = ROOM_WALL_THICK / 2
	var wall_x: Array = []
	for line in _wall_lines(xs, footprint_x):
		wall_x.append(int(line) - half)
	var wall_z: Array = []
	for line in _wall_lines(zs, footprint_z):
		wall_z.append(int(line) - half)
	# The rooms are what is left between the walls, inside the exterior band.
	var rects: Array[Rect2i] = []
	var edges_x: Array = _room_edges(wall_x, footprint_x)
	var edges_z: Array = _room_edges(wall_z, footprint_z)
	for i in edges_x.size():
		for j in edges_z.size():
			var ex: Vector2i = edges_x[i]
			var ez: Vector2i = edges_z[j]
			if ex.y - ex.x >= 4 and ez.y - ez.x >= 4:
				rects.append(Rect2i(ex.x, ez.x, ex.y - ex.x, ez.y - ez.x))
	return {"xs": xs, "zs": zs, "wall_x": wall_x, "wall_z": wall_z,
			"rooms": rects, "panels": panels, "columns": columns}


## The clear spans along one axis between the exterior walls and the interior
## walls standing at `walls` (each wall's near face), as (from, to).
static func _room_edges(walls: Array, footprint: int) -> Array:
	var out: Array = []
	var at := WALL_THICK
	for w in walls:
		out.append(Vector2i(at, int(w)))
		at = int(w) + ROOM_WALL_THICK
	out.append(Vector2i(at, footprint - WALL_THICK))
	return out


## How one lattice cell packs into panels, as (x, z, span) relative to the
## cell. On a conforming footprint every cell is PANEL square and the answer is
## a single `plate_10x10` at its corner; the odd cell a non-conforming footprint
## leaves over breaks into 4x4s and 2x2s instead.
##
## Memoised on the cell's size, of which a city has two or three.
static var _packs := {}


static func pack_cell(w: int, l: int) -> Array:
	var key := Vector2i(w, l)
	if _packs.has(key):
		return _packs[key]
	var out: Array = []
	var used := {}
	var x := 0
	while x < w:
		var z := 0
		while z < l:
			for n in [PANEL, 4, 2, 1]:
				if w - x < n or l - z < n:
					continue
				var clash := false
				for dx in n:
					for dz in n:
						if used.has(Vector2i(x + dx, z + dz)):
							clash = true
							break
					if clash:
						break
				if clash:
					continue
				for dx in n:
					for dz in n:
						used[Vector2i(x + dx, z + dz)] = true
				out.append(Vector3i(x, z, n))
				break
			z += 1
		x += 1
	_packs[key] = out
	return out


## Every ROOM_PANELS-th lattice line carries a wall -- never the first, which is
## the exterior wall itself, and never one so near the far wall that it divides
## nothing. A footprint too narrow for that gets one wall down the middle
## anyway, because a storey that is one room is a storey the room system has
## nothing to say about.
static func _wall_lines(lines: Array, footprint: int) -> Array:
	var out: Array = []
	@warning_ignore("integer_division")
	var limit := footprint - PANEL / 2
	for i in range(ROOM_PANELS, lines.size(), ROOM_PANELS):
		if int(lines[i]) < limit:
			out.append(int(lines[i]))
	if out.is_empty() and lines.size() >= 2:
		@warning_ignore("integer_division")
		var mid: int = int(lines[lines.size() / 2])
		if mid < limit:
			out.append(mid)
	return out


## Which lattice line a stairwell starts on along one axis: the cell nearest
## the middle that is clear of the exterior walls, or -1 if there is none.
##
## Clear of the walls because the floor runs out under them now: an edge cell
## is under the wall along its outer side, and a staircase there cuts its way
## through the wall to fit. A footprint of two panels has no such cell.
static func stair_line(footprint: int) -> int:
	var lines := lattice(footprint)
	var middle := float(footprint) * 0.5 - float(PANEL) * 0.5
	var best := -1
	for i in range(1, lines.size()):
		var v: int = int(lines[i])
		if v + PANEL > footprint - WALL_THICK:
			continue  # the last cell: its far side is under the wall
		if best < 0 or absf(float(v) - middle) < absf(float(best) - middle):
			best = v
	return best


## Does this footprint divide into whole panels? Everything below assumes so.
static func conforming(footprint: int) -> bool:
	return footprint % PANEL == 0


## Is this rectangle inside any keep-out?
##
## Keep-outs are where a FIXTURE is going. The recipe has to know before it lays
## its columns: a stairwell is carved up the middle of a building and that is
## exactly where the columns carrying the floor stand. Removing them afterwards
## left the panel above holding on to nothing.
static func _blocked(keepouts: Array, x: int, z: int, w: int, l: int) -> bool:
	for k in keepouts:
		var r: Rect2i = k
		if (x < r.position.x + r.size.x and x + w > r.position.x
				and z < r.position.y + r.size.y and z + l > r.position.y):
			return true
	return false


## Grow each keep-out to the whole lattice cells it touches.
##
## A keep-out that cuts a cell in half takes that cell's corner column with it
## and leaves the rest of the cell holding on to nothing. Whole cells in, whole
## cells out.
static func snap_keepouts(keepouts: Array, footprint_x: int, footprint_z: int) -> Array:
	var out: Array = []
	var xs := lattice(footprint_x)
	var zs := lattice(footprint_z)
	for k in keepouts:
		var r: Rect2i = k
		var x0 := _snap(r.position.x, xs, footprint_x, false)
		var z0 := _snap(r.position.y, zs, footprint_z, false)
		var x1 := _snap(r.position.x + r.size.x, xs, footprint_x, true)
		var z1 := _snap(r.position.y + r.size.y, zs, footprint_z, true)
		out.append(Rect2i(x0, z0, maxi(x1 - x0, PANEL), maxi(z1 - z0, PANEL)))
	return out


static func _snap(at: int, lines: Array, footprint: int, up: bool) -> int:
	# The cell edges are the lattice lines and the far face; on a footprint
	# that does not divide, the last cell is wider than PANEL and its far edge
	# is the face, not a line -- which a clamp to lines could not reach, and
	# which once left eleven plates hanging off the top floor of a stair tower.
	var edges: Array = lines.duplicate()
	edges.append(footprint)
	if up:
		for e in edges:
			if int(e) >= at:
				return int(e)
		return footprint
	var best := 0
	for e in edges:
		if int(e) <= at:
			best = int(e)
	return best


## Hollow tower: one plate layer of base, then `courses` of bonded brickwork.
##
## Courses alternate which pair of walls owns the corners. On an even course the
## long walls run the full width and the short walls fit between them; on an odd
## course it is the other way round. That quoin bond does two jobs at once:
##
##   * it offsets every wall by WALL_THICK course to course, so vertical joints
##     never line up and a wall is not a stack of independent columns;
##   * it makes the four walls ONE structure. Stud connections need footprints
##     to overlap in XZ, and with a fixed corner the front wall and the side
##     wall never overlap at all -- they would stand and fall separately, which
##     is what the first version of this recipe did.
static func build(world: BrickWorld, chunk_id: int, palette: Dictionary,
		footprint_x: int, footprint_z: int, courses: int,
		keepouts: Array = []) -> void:
	var t := WALL_THICK
	var clear := snap_keepouts(keepouts, footprint_x, footprint_z)
	var pl := plan(footprint_x, footprint_z)

	# Which floors carry interior walls, and which storey each one is. A floor
	# with no courses above it is a roof, and a wall standing on a roof divides
	# nothing.
	var bands := layout(courses)
	var walled := {}
	for i in bands.size() - 1:
		var b: Dictionary = bands[i]
		if (b.kind == "base" or b.kind == "slab") and bands[i + 1].kind == "course":
			walled[int(b.y)] = walled.size()

	for band in bands:
		match band.kind:
			"base":
				# The base ignores the keep-outs. A stairwell needs a hole in every
				# floor ABOVE it and none in the ground: without this the flight
				# starts on nothing and every step in the building reads as
				# detached.
				_lay_slab(world, chunk_id, palette, band.y, footprint_x, footprint_z,
						BASE_COLOUR, [], pl)
				_lay_room_walls(world, chunk_id, palette, band, footprint_x,
						footprint_z, pl, clear, walled)
			"slab":
				# Full footprint, walls included. This is what ties the four
				# walls together across the span AND what you see from outside.
				_lay_slab(world, chunk_id, palette, band.y, footprint_x,
						footprint_z, SLAB_COLOUR, clear, pl)
				# The columns carrying it, standing on the floor below.
				_lay_columns(world, chunk_id, palette, int(band.y) - COLUMN_PLATES,
						pl, clear)
				_lay_room_walls(world, chunk_id, palette, band, footprint_x,
						footprint_z, pl, clear, walled)
			"course":
				var colour: int = COURSE_COLOURS[int(band.index) % COURSE_COLOURS.size()]
				var y: int = band.y
				# Gaps are in the RUN's own axis, so both window courses take the
				# same openings whichever pair of walls owns the corners this
				# course. That is what makes a window a rectangle instead of two
				# staggered slots.
				var lit := is_window_course(int(band.index), courses)
				var gx: Array = window_gaps(footprint_x) if lit else []
				var gz: Array = window_gaps(footprint_z) if lit else []
				# Is this course the lintel of the openings below it? Only the
				# runs that START on a brick boundary need shifting -- the ones
				# starting at WALL_THICK are already half a brick off, which is
				# what the alternating bond is for.
				var lead := LINTEL_LEAD if int(band.index) > 0 						and is_window_course(int(band.index) - 1, courses) else 0
				if int(band.index) % 2 == 0:
					_run_x(world, chunk_id, palette, y, 0, footprint_x, 0, colour, gx, lead)
					_run_x(world, chunk_id, palette, y, 0, footprint_x, footprint_z - t, colour, gx, lead)
					_run_z(world, chunk_id, palette, y, t, footprint_z - t, 0, colour, gz)
					_run_z(world, chunk_id, palette, y, t, footprint_z - t, footprint_x - t, colour, gz)
				else:
					_run_z(world, chunk_id, palette, y, 0, footprint_z, 0, colour, gz, lead)
					_run_z(world, chunk_id, palette, y, 0, footprint_z, footprint_x - t, colour, gz, lead)
					_run_x(world, chunk_id, palette, y, t, footprint_x - t, 0, colour, gx)
					_run_x(world, chunk_id, palette, y, t, footprint_x - t, footprint_z - t, colour, gx)
			"cornice":
				for x in range(0, footprint_x - 1, 2):
					world.place_block(chunk_id, Vector3i(x, band.y, 0), palette.buttress_2x2, 1)


## A floor: one whole panel per lattice cell, the outer ones under the walls.
##
## One plate thick, standing on the walls round its edge and on columns inside. It used to be two offset plate layers
## -- plates side by side in one layer are not joined to each other at all, so a
## single layer was held only at its edges and dropped out on the first solve --
## and that fix cost **75% of every block in the building**: 30,855 plate_4x4
## and 7,140 plate_2x2 of a 50,535-block tower.
##
## One panel per cell, and no fill anywhere, because the footprint divides. See
## the lattice.
static func _lay_slab(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, footprint_x: int, footprint_z: int, colour: int,
		keepouts: Array, pl: Dictionary) -> Array:
	var t := WALL_THICK
	# One cell at a time, from the building's face. On a conforming footprint
	# every cell is exactly PANEL square and `_fill_rect` lays it as a single
	# `plate_10x10`, the ones round the edge reaching out under the walls.
	var laid: Array = []
	var xs: Array = pl.xs
	var zs: Array = pl.zs
	for i in xs.size():
		var x0: int = int(xs[i])
		var x1: int = int(xs[i + 1]) if i + 1 < xs.size() else footprint_x
		for j in zs.size():
			var z0: int = int(zs[j])
			var z1: int = int(zs[j + 1]) if j + 1 < zs.size() else footprint_z
			laid.append_array(_fill_rect(world, chunk_id, palette, y, x0, z0,
					x1, z1, colour, keepouts))
	# A cell left out -- a stairwell against a wall -- still has wall standing
	# on its edge above and below. That strip is laid anyway, and only that:
	# everywhere else the band is already panel, and placing there fails.
	if not keepouts.is_empty():
		_fill_rect(world, chunk_id, palette, y, 0, 0, footprint_x, t, colour, [])
		_fill_rect(world, chunk_id, palette, y, 0, footprint_z - t, footprint_x,
				footprint_z, colour, [])
		_fill_rect(world, chunk_id, palette, y, 0, t, t, footprint_z - t, colour, [])
		_fill_rect(world, chunk_id, palette, y, footprint_x - t, t, footprint_x,
				footprint_z - t, colour, [])
	return laid


## Fill a rectangle with the largest parts that fit, biggest first, and say
## where each one went as (x, z, span).
##
## It steps by one stud rather than by the part it just laid. A strided version
## left unfilled rectangles between the big parts and the far edge, and an
## unfilled rectangle in a floor is a hole; the wasted probes are a few hundred
## per floor against a bake that is measured in milliseconds.
static func _fill_rect(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, x0: int, z0: int, x1: int, z1: int, colour: int,
		keepouts: Array) -> Array:
	var sizes := [[PANEL, palette.plate_10x10], [4, palette.plate_4x4],
			[2, palette.plate_2x2], [1, palette.plate_1x1]]
	var laid: Array = []
	var x := x0
	while x < x1:
		var z := z0
		while z < z1:
			for entry in sizes:
				var n: int = int(entry[0])
				if x1 - x < n or z1 - z < n:
					continue
				if _blocked(keepouts, x, z, n, n):
					continue
				if world.place_block(chunk_id, Vector3i(x, y, z), entry[1], colour) >= 0:
					laid.append(Vector3i(x, z, n))
					break
			z += 1
		x += 1
	return laid


## The columns under a floor: one centred on every interior lattice point, and
## one for each fragment of a footprint that does not divide. See `plan`.
##
## A column the stairwell crosses is left out. It would only have clipped the
## shaft's corner, but the staircase clears its whole cell, and the panels round
## the shaft each keep three columns and the walls.
static func _lay_columns(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, pl: Dictionary, keepouts: Array) -> void:
	if y < 0:
		return
	for entry in (pl.columns as Array):
		var r: Rect2i = entry
		if _blocked(keepouts, r.position.x, r.position.y, r.size.x, r.size.y):
			continue
		world.place_block(chunk_id, Vector3i(r.position.x, y, r.position.y),
				palette.column_2x2 if r.size.x >= 2 else palette.column_1x1, COLUMN_COLOUR)


## The interior walls that make a storey into rooms.
##
## One wall line thick and COURSES_PER_FLOOR tall, so it reaches the slab above
## and carries some of it: a room divider in a building that falls down has to
## be part of why it stood up, or the first collapse leaves every floor hanging
## on the columns alone.
##
## Walls run on lattice lines and nowhere else, so there is a column under every
## PANEL studs of every one of them. An earlier version stood them on the floor
## panels and put four courses of brickwork through whichever single column
## happened to be under the panel they crossed: 880 stress failures, 1,724
## blocks shed. See `plan`.
static func _lay_room_walls(world: BrickWorld, chunk_id: int, palette: Dictionary,
		band: Dictionary, footprint_x: int, footprint_z: int, pl: Dictionary,
		keepouts: Array, walled: Dictionary) -> void:
	if not walled.has(int(band.y)):
		return
	var t := WALL_THICK
	var y: int = int(band.y) + SLAB_PLATES
	var storey: int = int(walled[int(band.y)])
	for at in (pl.wall_x as Array):
		_lay_wall_line(world, chunk_id, palette, y, t, footprint_z - t, int(at),
				keepouts, storey, true, ROOM_WALL_THICK)
	for at in (pl.wall_z as Array):
		_lay_wall_line(world, chunk_id, palette, y, t, footprint_x - t, int(at),
				keepouts, storey, false, ROOM_WALL_THICK)


## One wall, course by course.
##
## The top course runs unbroken. That is what a lintel is, and without one the
## course above a doorway is a brick laid across the opening with solid wall
## nowhere under it -- the same fault that shed the top floor of every tower
## tall enough to have one. A fixture's keep-out stays clear the whole height
## instead, because a stairwell has to come through.
static func _lay_wall_line(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, from: int, to: int, line: int, keepouts: Array, storey: int,
		along_z: bool, thick: int = WALL_THICK) -> void:
	var blocked := _keepout_spans(keepouts, line, along_z, thick)
	var door := _door_span(from, to, storey, blocked)
	for k in COURSES_PER_FLOOR:
		var gaps: Array = blocked.duplicate()
		if k < COURSES_PER_FLOOR - 1 and door != Vector2i.ZERO:
			gaps.append(door)
		# Alternate courses start half a brick over, so a wall is bonded rather
		# than a row of independent four-brick stacks.
		var lead := LINTEL_LEAD if k % 2 == 1 else 0
		var at := y + k * PLATES_PER_COURSE
		if along_z:
			_run_z(world, chunk_id, palette, at, from, to, line, ROOM_WALL_COLOUR,
					gaps, lead, thick)
		else:
			_run_x(world, chunk_id, palette, at, from, to, line, ROOM_WALL_COLOUR,
					gaps, lead, thick)


## Where a fixture crosses this wall line, in the line's own axis.
static func _keepout_spans(keepouts: Array, line: int, along_z: bool,
		thick: int = WALL_THICK) -> Array:
	var out: Array = []
	for k in keepouts:
		var r: Rect2i = k
		var across_lo: int = r.position.x if along_z else r.position.y
		var across_hi: int = across_lo + (r.size.x if along_z else r.size.y)
		if line < across_hi and line + thick > across_lo:
			var lo: int = r.position.y if along_z else r.position.x
			out.append(Vector2i(lo, lo + (r.size.y if along_z else r.size.x)))
	return out


## One doorway per wall, moved storey to storey so a building does not read as
## one floor stacked forty times. Zero if the wall is too short for one, or if
## every position it would take is already a stairwell.
static func _door_span(from: int, to: int, storey: int, blocked: Array) -> Vector2i:
	var span := to - from
	if span < DOOR_WIDE * 3:
		return Vector2i.ZERO
	for tries in 3:
		@warning_ignore("integer_division")
		var at: int = from + (span * ((storey + tries) % 3 + 1)) / 4 - LINTEL_LEAD
		at = clampi(at, from + LINTEL_LEAD, to - DOOR_WIDE - LINTEL_LEAD)
		var clash := false
		for b in blocked:
			if at < (b as Vector2i).y and at + DOOR_WIDE > (b as Vector2i).x:
				clash = true
				break
		if not clash:
			return Vector2i(at, at + DOOR_WIDE)
	return Vector2i.ZERO


## Is this course one of the ones a window is cut through?
##
## The courses just under the storey's LAST one, which is left solid to be the
## lintel -- and only in a storey that actually has a slab over it, because the
## last few courses of a tower are capped by a cornice and a cornice carries
## nothing.
static func is_window_course(index: int, courses: int) -> bool:
	@warning_ignore("integer_division")
	var storey := index / COURSES_PER_FLOOR
	if (storey + 1) * COURSES_PER_FLOOR > courses:
		return false  # no slab above this one: the cornice is not a lintel
	var within := index % COURSES_PER_FLOOR
	return within >= COURSES_PER_FLOOR - 1 - WINDOW_COURSES \
			and within < COURSES_PER_FLOOR - 1


## Where the openings are along a wall of this length, as [from, to) in studs.
static func window_gaps(span: int) -> Array:
	var out := []
	var at := WINDOW_INSET
	while at + WINDOW_WIDE <= span - WINDOW_INSET:
		out.append(Vector2i(at, at + WINDOW_WIDE))
		at += WINDOW_PITCH
	return out


## If `at` is inside an opening, where that opening ends. Otherwise `at`.
static func _gap_end(gaps: Array, at: int) -> int:
	for g in gaps:
		if at >= (g as Vector2i).x and at < (g as Vector2i).y:
			return (g as Vector2i).y
	return at


## Where the next opening starts after `at`, or a number past any wall.
static func _gap_next(gaps: Array, at: int) -> int:
	var best := 1 << 30
	for g in gaps:
		if (g as Vector2i).x > at:
			best = mini(best, (g as Vector2i).x)
	return best


## Lay a short piece first, so this course's joints fall between the course
## below's rather than on top of them. Returns how far it advanced.
static func _lead(lead: int, gaps: Array, start: int, world: BrickWorld,
		chunk_id: int, _palette: Dictionary, y: int, x: int, z: int, colour: int,
		part: int) -> int:
	if lead <= 0:
		return 0
	# The main loop tests the openings; the lead runs before it and has to test
	# them too, or a doorway gets a brick laid across its bottom corner.
	if _gap_end(gaps, start) > start or _gap_next(gaps, start) < start + lead:
		return 0
	if world.place_block(chunk_id, Vector3i(x, y, z), part, colour) < 0:
		return 0
	return lead


## Lay a course along X. Largest piece that fits wins, so a run closes its ends
## with shorter bricks instead of leaving a gap -- and stops short of a window
## rather than laying a brick halfway across one.
static func _run_x(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, x0: int, x1: int, z: int, colour: int, gaps: Array = [],
		lead: int = 0, thick: int = WALL_THICK) -> void:
	# The same three lengths whatever the thickness: four, two, one along the
	# run. A one-stud wall is 1x4s; a two-stud wall is 2x4s.
	var four: int = palette.brick_2x4_x if thick >= 2 else palette.brick_1x4_x
	var two: int = palette.brick_2x2 if thick >= 2 else palette.brick_1x2_x
	var one: int = palette.brick_1x2_z if thick >= 2 else palette.brick_1x1
	var x := x0 + _lead(lead, gaps, x0, world, chunk_id, palette, y, x0, z, colour, two)
	while x < x1:
		var skip := _gap_end(gaps, x)
		if skip > x:
			x = skip
			continue
		var remaining := mini(x1, _gap_next(gaps, x)) - x
		if remaining >= 4 and world.place_block(chunk_id, Vector3i(x, y, z), four, colour) >= 0:
			x += 4
		elif remaining >= 2 and world.place_block(chunk_id, Vector3i(x, y, z), two, colour) >= 0:
			x += 2
		elif remaining >= 1 and world.place_block(chunk_id, Vector3i(x, y, z), one, colour) >= 0:
			x += 1
		else:
			x += 1  # cell already taken, or the last stud before a window


static func _run_z(world: BrickWorld, chunk_id: int, palette: Dictionary,
		y: int, z0: int, z1: int, x: int, colour: int, gaps: Array = [],
		lead: int = 0, thick: int = WALL_THICK) -> void:
	var four: int = palette.brick_2x4_z if thick >= 2 else palette.brick_1x4_z
	var two: int = palette.brick_2x2 if thick >= 2 else palette.brick_1x2_z
	var one: int = palette.brick_1x2_x if thick >= 2 else palette.brick_1x1
	var z := z0 + _lead(lead, gaps, z0, world, chunk_id, palette, y, x, z0, colour, two)
	while z < z1:
		var skip := _gap_end(gaps, z)
		if skip > z:
			z = skip
			continue
		var remaining := mini(z1, _gap_next(gaps, z)) - z
		if remaining >= 4 and world.place_block(chunk_id, Vector3i(x, y, z), four, colour) >= 0:
			z += 4
		elif remaining >= 2 and world.place_block(chunk_id, Vector3i(x, y, z), two, colour) >= 0:
			z += 2
		elif remaining >= 1 and world.place_block(chunk_id, Vector3i(x, y, z), one, colour) >= 0:
			z += 1
		else:
			z += 1
