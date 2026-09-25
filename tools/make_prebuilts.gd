extends SceneTree

## Writes the prebuilt structures the city's placer ships with, to res://builds/.
##
##     godot --headless --path . --script tools/make_prebuilts.gd
##
## Generated rather than hand-saved, so they are always made of the current
## palette -- and its MATERIALS, stone and wood and metal -- and follow the
## current rules: a four-brick figure, six-course storeys,
## doorways four studs wide and five bricks clear under a lintel course, windows
## three courses tall from a sill two bricks up (Docs/Parts/README.md section 6).
## Walls are laid in running bond -- every other course starts half a brick
## over -- so each is one structure and not a stack of columns. Nothing here uses
## a staircase fixture: the old one carves its stairwell through whatever it
## lands in.
##
## Every build is checked before it is written: every brick has to go in (no
## two overlapping) and the whole thing has to stand, grounded, in one piece.

const OUT := "res://builds/"
const STOREY := 6            ## courses: TowerRecipe.COURSES_PER_FLOOR
const DOOR := 4              ## studs wide, STOREY - 1 courses tall
const SILL := 2              ## courses of wall under a window
const WINDOW := 3            ## courses tall

var _fail := 0


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_write("cottage", _cottage())
	_write("watchtower", _watchtower())
	_write("kiosk", _kiosk())
	_write("garden_wall", _garden_wall())
	quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# The structures
# ---------------------------------------------------------------------------

## One storey, a door in front and a window in each side, a flat plate roof.
func _cottage() -> BuildRecipe:
	var r := _named("Cottage")
	var w := 12
	var d := 8
	_box(r, w, d, 0, 0, 5, {"front": [Vector2i(4, 4 + DOOR)]},
			{"left": [Vector2i(3, 5)], "right": [Vector2i(3, 5)], "back": [Vector2i(5, 7)]})
	_made_of(r, 0, "Stone")                  # sandstone walls
	var roof := r.size()
	_slab(r, w, d, STOREY * 3, 1)
	_made_of(r, roof, "Wood")                # a walnut roof
	return r


## Three storeys, eight studs square: a floor of plates on each, a door at the
## bottom, a window in every wall above it. No stair -- the kind of thing the
## new stair pieces are for, placed in the workshop.
func _watchtower() -> BuildRecipe:
	var r := _named("Watchtower")
	var n := 8
	for s in 3:
		var doors := {"front": [Vector2i(2, 2 + DOOR)]} if s == 0 else {}
		var windows := {"left": [Vector2i(3, 5)], "right": [Vector2i(3, 5)],
				"back": [Vector2i(3, 5)]}
		if s > 0:
			windows["front"] = [Vector2i(3, 5)]
		var y := s * (STOREY * 3 + 1)
		var walls := r.size()
		_box(r, n, n, y, s * STOREY, 2, doors, windows)
		_made_of(r, walls, "Stone")          # grey granite
		var floor_at := r.size()
		_slab(r, n, n, y + STOREY * 3, 0)
		_made_of(r, floor_at, "Wood")        # oak floors
	return r


## A market kiosk: three walls and an open front under a roof.
func _kiosk() -> BuildRecipe:
	var r := _named("Kiosk")
	var w := 8
	var d := 8
	_box(r, w, d, 0, 0, 10, {"front": [Vector2i(1, w - 1)]}, {})
	_made_of(r, 0, "Wood")                   # cedar
	var roof := r.size()
	_slab(r, w, d, STOREY * 3, 0)
	_made_of(r, roof, "Metal")               # a steel roof
	return r


## A garden wall, two courses, with a round post at each end.
func _garden_wall() -> BuildRecipe:
	var r := _named("Garden wall")
	var l := 16
	for c in 2:
		_run(r, "x", 1, l - 1, 0, c * 3, c, 11, [])
	_made_of(r, 0, "Stone")                  # travertine
	var posts := r.size()
	for c in 2:
		r.add("round_1x1", Vector3i(0, c * 3, 0), 12)
		r.add("round_1x1", Vector3i(l - 1, c * 3, 0), 12)
	_made_of(r, posts, "Metal")              # gunmetal posts
	return r


## Everything added from block `first` on is made of `material` (by name), its
## colour index now naming one of that material's own kinds.
func _made_of(r: BuildRecipe, first: int, material: String) -> void:
	var m := -1
	for i in BrickWorld.get_material_count():
		if BrickWorld.get_material_name(i) == material:
			m = i
	assert(m >= 0, "no material called " + material)
	for i in range(first, r.size()):
		r.set_material(i, m)


# ---------------------------------------------------------------------------
# Laying bricks
# ---------------------------------------------------------------------------

func _named(n: String) -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = n
	return r


## Four walls one stud thick, STOREY courses tall, standing at plate `y`.
## `doors` and `windows` are {side: [Vector2i(from, to)]} along that wall, in
## studs from its own start; a door runs up to the lintel, a window from the
## sill for WINDOW courses. The front and back run the full width; the sides
## sit between them, so the corners interlock course by course.
func _box(r: BuildRecipe, w: int, d: int, y: int, bond: int, colour: int,
		doors: Dictionary, windows: Dictionary) -> void:
	for c in STOREY:
		var at := y + c * 3
		var odd := (bond + c) % 2
		_run(r, "x", 0, w, 0, at, odd, colour, _gaps(doors.get("front", []), windows.get("front", []), c, 0))
		_run(r, "x", 0, w, d - 1, at, odd, colour, _gaps(doors.get("back", []), windows.get("back", []), c, 0))
		_run(r, "z", 1, d - 1, 0, at, odd, colour, _gaps(doors.get("left", []), windows.get("left", []), c, 1))
		_run(r, "z", 1, d - 1, w - 1, at, odd, colour, _gaps(doors.get("right", []), windows.get("right", []), c, 1))


## The openings a course has, shifted into the run's own coordinates.
func _gaps(doors: Array, windows: Array, course: int, shift: int) -> Array:
	var out := []
	if course < STOREY - 1:
		for g in doors:
			out.append(Vector2i(g.x + shift, g.y + shift))
	if course >= SILL and course < SILL + WINDOW:
		for g in windows:
			out.append(Vector2i(g.x + shift, g.y + shift))
	return out


## One course of wall from `a` to `b` (exclusive) along `axis`, at `across` on
## the other axis. Longest brick that fits wins; an odd course starts with a
## half brick so its joints fall mid-brick on the course below.
func _run(r: BuildRecipe, axis: String, a: int, b: int, across: int, y: int,
		odd: int, colour: int, gaps: Array) -> void:
	var at := a
	var first := true
	while at < b:
		var blocked := false
		for g in gaps:
			if at >= g.x and at < g.y:
				at = g.y
				blocked = true
		if blocked:
			first = false
			continue
		var room := b - at
		for g in gaps:
			if g.x > at:
				room = mini(room, g.x - at)
		var len := 4
		if first and odd == 1:
			len = 2
		while len > room:
			len = 2 if len == 4 else 1
		var part := "brick_1x1" if len == 1 else "brick_1x%d_%s" % [len, axis]
		var cell := Vector3i(at, y, across) if axis == "x" else Vector3i(across, y, at)
		r.add(part, cell, colour)
		at += len
		first = false


## A layer of plates over the whole footprint at plate `y`: 4x4s, then 2x4s,
## then 1x-somethings for what is left.
func _slab(r: BuildRecipe, w: int, d: int, y: int, colour: int) -> void:
	var taken := {}
	for z in range(0, d - d % 4, 4):
		for x in range(0, w - w % 4, 4):
			r.add("plate_4x4", Vector3i(x, y, z), colour)
			for i in 4:
				for j in 4:
					taken[Vector2i(x + i, z + j)] = true
	for z in d:
		for x in w:
			if not taken.has(Vector2i(x, z)):
				r.add("plate_1x1", Vector3i(x, y, z), colour)


# ---------------------------------------------------------------------------
# Checking and writing
# ---------------------------------------------------------------------------

func _write(file: String, r: BuildRecipe) -> void:
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var asm := Assembly.new(w, pal)
	var placed := r.build_into(asm, pal)
	var chunk: int = asm.frames[0]
	w.set_foundation_level(chunk, 0)
	w.solve_grounded(chunk)
	var loose: Array = w.find_detached_groups(chunk)
	var ok := placed == r.size() and loose.is_empty()
	if not ok:
		_fail += 1
	var path := OUT + file + ".json"
	if ok:
		r.save_to(path)
	print("%s %-12s %3d bricks, %d placed, %d loose group(s)  %s" % [
			"ok  " if ok else "FAIL", file, r.size(), placed, loose.size(),
			path if ok else "(not written)"])
