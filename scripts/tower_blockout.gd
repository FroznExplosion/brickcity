class_name TowerBlockout
extends RefCounted

## A generated building inside a player build: TowerRecipe's parameters, held
## as parameters. Docs/Workshop.md, Stage C.
##
## The workshop drops one on the baseplate and the author drags it wider,
## deeper and taller. It stays a handful of numbers in the recipe
## (`BuildRecipe.towers`) until somebody asks for bricks -- the workshop's
## preview, a Bake, or the city placing the build -- and then it is built by
## the SAME generator the city's own buildings come from, so its floors, walls,
## columns and stairwell are the ones already measured to stand.
##
##   {"cell": [x, y, z], "params": {"x": 20, "z": 20, "courses": 12,
##    "rooms": true, "stairs": true, "windows": true}}
##
## Footprints are whole panels and heights whole storeys. TowerRecipe only
## stands when its footprint divides into panels (see its lattice notes), and
## a storey that stops mid-way has a floor with nothing over it.

const PANEL := TowerRecipe.PANEL
const STOREY := TowerRecipe.COURSES_PER_FLOOR
## Two panels: one panel is all wall, and the lattice has no line inside it
## for a column, a room wall or a stairwell.
const MIN_PANELS := 2
const MIN_STOREYS := 1


static func defaults() -> Dictionary:
	return {"x": 3 * PANEL, "z": 3 * PANEL, "courses": 2 * STOREY,
			"rooms": true, "stairs": true, "windows": true}


## The same parameters, snapped to what the generator can build and clamped to
## `limit` (cells; zero means no limit).
static func normalised(p: Dictionary, limit: Vector3i = Vector3i.ZERO) -> Dictionary:
	var out := defaults()
	for k in p:
		out[k] = p[k]
	var px := maxi(MIN_PANELS, int(round(float(out.x) / PANEL)))
	var pz := maxi(MIN_PANELS, int(round(float(out.z) / PANEL)))
	var st := maxi(MIN_STOREYS, int(round(float(out.courses) / STOREY)))
	if limit != Vector3i.ZERO:
		@warning_ignore("integer_division")
		px = mini(px, maxi(MIN_PANELS, limit.x / PANEL))
		@warning_ignore("integer_division")
		pz = mini(pz, maxi(MIN_PANELS, limit.z / PANEL))
		while st > MIN_STOREYS and dims({"x": px * PANEL, "z": pz * PANEL,
				"courses": st * STOREY}).y > limit.y:
			st -= 1
	out.x = px * PANEL
	out.z = pz * PANEL
	out.courses = st * STOREY
	out.rooms = bool(out.rooms)
	out.stairs = bool(out.stairs)
	out.windows = bool(out.windows)
	return out


## Cells it occupies, min corner at its own origin.
static func dims(p: Dictionary) -> Vector3i:
	var d := TowerRecipe.chunk_dims(int(p.x), int(p.z), int(p.courses))
	return Vector3i(d.x, d.y - 1, d.z)


## Where the stairwell goes, as a TowerRecipe keep-out, or Rect2i() for none.
static func stair_rect(p: Dictionary) -> Rect2i:
	if not bool(p.get("stairs", true)):
		return Rect2i()
	var sx := TowerRecipe.stair_line(int(p.x))
	var sz := TowerRecipe.stair_line(int(p.z))
	if sx < 0 or sz < 0:
		return Rect2i()
	return Rect2i(sx, sz, StaircaseRecipe.DIAMETER, StaircaseRecipe.DIAMETER)


## Every brick the generator lays, in the order it lays them:
## [[archetype name, cell, colour], ...], cells from the building's own origin.
##
## Built for real into a scratch chunk and read back, rather than re-deriving
## the generator's rules here: there is exactly one description of how a
## building is laid, and a second one could only disagree with it. The
## stairwell carve removes floor bricks it built a moment earlier; a removed
## brick reads back as nothing and is left out.
static func bricks(world: BrickWorld, palette: Dictionary, p: Dictionary) -> Array:
	var d := TowerRecipe.chunk_dims(int(p.x), int(p.z), int(p.courses))
	var c := world.create_chunk(Vector3i.ZERO, d)
	var keep: Array = []
	var stair := stair_rect(p)
	if stair.size != Vector2i.ZERO:
		keep.append(stair)
	TowerRecipe.build(world, c, palette, int(p.x), int(p.z), int(p.courses), keep,
			{"rooms": p.rooms, "windows": p.windows})
	if stair.size != Vector2i.ZERO:
		var f := Fixture.new()
		f.kind = "staircase"
		f.cell = Vector3i(stair.position.x, TowerRecipe.SLAB_PLATES, stair.position.y)
		f.params = {"steps": StaircaseRecipe.steps_for_courses(int(p.courses)), "colour": 11}
		f.build_into(world, c, StaircaseRecipe.flight_parts(palette))
	var names := names_of(palette)
	var out := []
	var ts := BrickWorld.ticks_per_stud()
	var tp := BrickWorld.ticks_per_plate()
	for id in world.get_block_count(c):
		var box: Array = world.get_block_ticks(c, id)
		if box.is_empty():
			continue   # carved out for the stairwell
		var lo: Vector3i = box[0]
		@warning_ignore("integer_division")
		var cell := Vector3i(lo.x / ts, lo.y / tp, lo.z / ts)
		out.append([names.get(world.get_block_archetype(c, id), ""), cell,
				world.get_block_colour(c, id)])
	world.release_chunk(c)
	return out


## Archetype id -> the palette NAME a recipe stores it under. The extension's
## own name for a baked variant ("plate_10x10#base") is not a palette key; the
## first key the palette gives for an id is, and it is the same key on every
## run because the palette is baked in one fixed order.
static func names_of(palette: Dictionary) -> Dictionary:
	var out := {}
	for n in palette:
		var id = palette[n]
		if typeof(id) == TYPE_INT and not out.has(id):
			out[id] = n
	return out


## The recipe with every generated building turned into bricks, and nothing
## else changed -- what the city places. The generated bricks go FIRST, as the
## workshop lays them first, so a brick the author put on a roof lands on the
## roof rather than where the roof would have been. A recipe with no generated
## building comes back as itself.
static func flatten(r: BuildRecipe) -> BuildRecipe:
	if r.towers.is_empty():
		return r
	var w := BrickWorld.new()
	w.set_seed(1)
	var pal := TowerRecipe.bake_palette(w)
	var out := BuildRecipe.new()
	out.name = r.name
	out.kind = r.kind
	out.meta = r.meta.duplicate(true)
	for t in r.towers:
		var at := BuildRecipe.cell_from(t.cell)
		for b in bricks(w, pal, normalised(t.params)):
			out.add(b[0], (b[1] as Vector3i) + at, int(b[2]))
	out.append(r, Vector3i.ZERO)
	out.towers.clear()   # built above; append copied the records as well
	return out
