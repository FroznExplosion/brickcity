class_name WorkshopTools
extends Node

## The building workshop's tools (Docs/BuildTools.md): the rail down the left (`ToolRail`,
## the asset workshop's own), and the tools that build buildings fast -- Shapes of the held
## brick, flat or standing as a wall, staggered or aligned; Cut, for doorways and windows;
## Sketch, an outline drawn by hand with the asset workshop's own pen (SketchPen); Repeat,
## for storeys and rows of windows; Select,
## to change or let go of a kept shape. Place, Paint and Rooms are the workshop's
## own hand, brush and spaces tool.
##
## A shape stays a shape: it is kept in `recipe.meta.shapes` with its cuts and the bricks
## it laid, so a doorway cut through a wall later lays the wall again round it and leaves
## the rest of the wall's bricks where they are.

const TOOLS := [
	["place", "Place", "Esc", "Click to put the brick in hand on the stud you aim at; hold and move to lay a run. RMB takes one away; R turns it; 1-9 and the wheel pick the brick."],
	["paint", "Paint", "B", "Click or drag over bricks to give them the colour in hand."],
	["shape", "Shapes", "K", "Drag out a shape of the held brick: flat on the plane you aim at, or standing as a wall. RMB drag cuts the same shape out. Shift keeps a circle round."],
	["cut", "Cut", "N", "Drag a doorway, window or any shape on a wall: the wall is laid again round it. Door and window: one click."],
	["sketch", "Sketch", "Alt D", "Draw an outline on the plane you aim at, flat or standing -- freehand, brush, rectangle, ellipse or clicked corners: it fills with the held brick as a kept shape. RMB draws one to cut out."],
	["repeat", "Repeat", "J", "Copy the picked shape -- or a storey, everything between two heights -- N times up, or along X or Z. Click a brick here to pick what to repeat; a door or window repeats with its cut."],
	["select", "Select", "L", "Click a shape's brick to pick the shape: change its height, bond or brick, take its cuts out, delete it, or let it go (keep the bricks)."],
	["rooms", "Rooms", "O", "Rooms and openings, as O: LMB marks a room or an opening, RMB forgets it."],
]
const LIE_NAMES := [["flat", "flat (floor, or walls round it)"], ["wall", "standing wall"]]
const CUT_KINDS := [["rect", "rectangle (drag)"], ["arch", "arch (drag)"], ["circle", "circle (drag)"],
		["door", "door (click)"], ["window", "window (click)"]]
## A door and a window cut by one click, to start: studs across, plates up; a window's sill
## is where it is clicked, a door stands on the floor of the wall.
const DOOR := Vector2i(4, 18)
const WINDOW := Vector2i(4, 9)
const REPEAT_WHAT := [["shape", "the picked shape"], ["storey", "a storey (from / to)"]]
const REPEAT_DIRS := [["up", "up"], ["x", "along X"], ["z", "along Z"]]

var ws    ## the workshop (workshop.gd)
var rail: ToolRail
var tool := "place"

## Shapes options.
var kind := "rect"
var lie := "flat"
var tall := 3        # plates, flat
var thick := 1       # studs, a wall's depth
var rim := 1         # studs, a hollow rectangle's or a ring's
var staggered := true
var cut_kind := "rect"
## Doors and windows (Docs/BuildTools.md section 6): their size, and whether they get a
## frame (the held brick and colour) and, windows, glass.
var door_size := DOOR
var window_size := WINDOW
var frame_on := true
var glass_on := true
## Repeat: what, which way, how many, the gap between copies, and a storey's plates.
var rep_what := "shape"
var rep_dir := "up"
var rep_times := 1
var rep_gap := 0
var rep_lo := 1
var rep_hi := 9
## Sketch: the pen (the asset workshop's), its brush, and the plane a stroke is on --
## {lie, at} while one is drawn, else empty.
var pen := SketchPen.new()
var brush_size := 1
var brush_square := false
var _sk := {}

## A drag under way: {button, lie, at, a, b, depth} in the plane's own cells; empty if none.
var _drag := {}
## The kept shape picked with Select: its id, or -1.
var selected := -1
## Undo records, newest last, one for each "shape" edit: {before: {id: shape or null},
## hand: [[part, [x, y, z], colour, mat, role]]} -- hand-laid bricks a cut took up.
var _undo := []
## "part|x|y|z" -> shape id, for the bricks of kept shapes; rebuilt when stale.
var _owner := {}
var _owner_dirty := true
## Bumped when a kept shape changes: Select's options are read back then, not each frame
## (a number being typed would be put back under the cursor).
var _rev := 0
var _shown := Vector2i(-2, -1)

var _lines: MeshInstance3D
var _im: ImmediateMesh
var _shape_box: VBoxContainer
var _cut_box: VBoxContainer
var _select_box: VBoxContainer
var _sketch_box: VBoxContainer
var _select_label: Label
var _kind_pick: OptionButton
var _lie_pick: OptionButton
var _bond_pick: OptionButton
var _tall_spin: SpinBox
var _thick_spin: SpinBox
var _rim_spin: SpinBox
var _sel_depth: SpinBox
var _sel_rim: SpinBox
var _sel_bond: OptionButton
var _repeat_box: VBoxContainer
var _repeat_label: Label
var _rep_lo_spin: SpinBox
var _rep_hi_spin: SpinBox
var _door_box: VBoxContainer
var _window_box: VBoxContainer
var _syncing := false


func setup(workshop, layer: CanvasLayer) -> void:
	ws = workshop
	rail = ToolRail.new(184.0)
	rail.name = "ToolRail"
	layer.add_child(rail)
	rail.fill("Build", TOOLS, pick)
	_build_options()
	_im = ImmediateMesh.new()
	_lines = MeshInstance3D.new()
	_lines.mesh = _im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_lines.material_override = m
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ws.add_child(_lines)


# ---------------------------------------------------------------------------
# Kept shapes: recipe.meta.shapes
# ---------------------------------------------------------------------------

func shapes() -> Array:
	if not ws.recipe.meta.has("shapes"):
		ws.recipe.meta["shapes"] = []
	return ws.recipe.meta["shapes"]


func _index_of(id: int) -> int:
	var list := shapes()
	for i in list.size():
		if int(list[i].id) == id:
			return i
	return -1


func shape_of(id: int) -> Dictionary:
	var i := _index_of(id)
	return {} if i < 0 else shapes()[i]


func _next_id() -> int:
	var n := 0
	for sh in shapes():
		n = maxi(n, int(sh.id) + 1)
	return n


## Put a shape's record in (or with `sh` empty, take it out). Records are never changed in
## place, so an undo can hold the old one as it is.
func _store(id: int, sh: Dictionary) -> void:
	var i := _index_of(id)
	if sh.is_empty():
		if i >= 0:
			shapes().remove_at(i)
	elif i >= 0:
		shapes()[i] = sh
	else:
		shapes().append(sh)
	_owner_dirty = true
	_rev += 1


## A new build was opened or begun: its shapes are its own.
func recipe_changed() -> void:
	_undo.clear()
	_drag = {}
	selected = -1
	_owner_dirty = true


## The kept shape a brick was laid by, or -1.
func owner_of(part: String, cell: Vector3i) -> int:
	if _owner_dirty:
		_owner.clear()
		for sh in shapes():
			for b in sh.bricks:
				_owner["%s|%d|%d|%d" % [b[0], b[1][0], b[1][1], b[1][2]]] = int(sh.id)
		_owner_dirty = false
	return int(_owner.get("%s|%d|%d|%d" % [part, cell.x, cell.y, cell.z], -1))


## A kept shape's brick taken up by hand (RMB): it is no longer the shape's until the shape
## is laid again.
func forget_brick(part: String, cell: Vector3i) -> void:
	var id := owner_of(part, cell)
	var i := _index_of(id)
	if i < 0:
		return
	var sh: Dictionary = shapes()[i].duplicate(true)
	sh.bricks = (sh.bricks as Array).filter(func(b: Array) -> bool:
		return not (String(b[0]) == part and BuildRecipe.cell_from(b[1]) == cell))
	shapes()[i] = sh
	_owner_dirty = true


## A new kept shape, from the options in hand: returns its id.
func add_shape(k: String, l: String, a: Vector2i, b: Vector2i, at: int, points: Variant = []) -> int:
	var sh := _new_shape(k, l, a, b, at, points)
	var rec := _begin()
	_add_into(rec, sh)
	_end(rec)
	return int(sh.id)


## A shape's record from the options in hand (the held brick, colour, material), not laid.
func _new_shape(k: String, l: String, a: Vector2i, b: Vector2i, at: int, points: Variant = []) -> Dictionary:
	var sh := {
		"id": _next_id(), "kind": k, "lie": l, "a": [a.x, a.y], "b": [b.x, b.y], "at": at,
		"depth": tall if l == "flat" else thick, "rim": rim, "bond": "stagger" if staggered else "align",
		"part": BrickPalette.part_of(ws._archetype_name()), "colour": ws._colour, "mat": ws._mat,
		"role": ws._role, "cuts": [], "bricks": [],
	}
	if (points is Array and not (points as Array).is_empty()) or points is Dictionary:
		sh.points = points
	return sh


## Lay a new shape as part of an undo record (it gets the next id if its own is taken).
func _add_into(rec: Dictionary, sh: Dictionary) -> int:
	if not shape_of(int(sh.id)).is_empty():
		sh.id = _next_id()
	rec.before[int(sh.id)] = null
	_lay(sh)
	return int(sh.id)


## Change a kept shape -- `change` merged into it -- and lay it again whole. One undo.
func change_shape(id: int, change: Dictionary) -> void:
	var old := shape_of(id)
	if old.is_empty():
		return
	var sh := old.duplicate(true)
	sh.merge(change, true)
	var rec := _begin()
	rec.before[id] = old
	_take_up(old)
	_lay(sh)
	_end(rec)


## Take a kept shape and its bricks away. One undo.
func delete_shape(id: int) -> void:
	var old := shape_of(id)
	if old.is_empty():
		return
	var rec := _begin()
	rec.before[id] = old
	_take_up(old)
	_store(id, {})
	if selected == id:
		selected = -1
	_end(rec)


## Forget a shape and keep its bricks: plain bricks from now on. One undo.
func let_go(id: int) -> void:
	var old := shape_of(id)
	if old.is_empty():
		return
	var rec := _begin()
	rec.before[id] = old
	_store(id, {})
	# Its bricks stay: the undo must not take them up, only give the record back.
	rec["kept"] = true
	if selected == id:
		selected = -1
	_end(rec)


## Cut a shape (a cut record: kind, lie, a, b, at, depth) out of every kept shape it
## touches -- each laid again near the cut only -- and take up hand-laid bricks in it.
## One undo. Returns how many shapes it cut.
func apply_cut(cut: Dictionary) -> int:
	var rec := _begin()
	var n := _cut_into(rec, cut)
	_end(rec)
	return n


## A cut, as part of an undo record. Returns how many shapes and hand bricks it cut.
func _cut_into(rec: Dictionary, cut: Dictionary) -> int:
	var cells := BrickShapes.solid_cells(cut)
	if cells.is_empty():
		return 0
	var n := 0
	for sh in shapes().duplicate():
		var mine := BrickShapes.shape_cells(sh)
		var hit := false
		for c in cells:
			if mine.has(c):
				hit = true
				break
		if not hit:
			continue
		var next: Dictionary = sh.duplicate(true)
		(next.cuts as Array).append(cut.duplicate(true))
		if not rec.before.has(int(sh.id)):
			rec.before[int(sh.id)] = sh
		_lay(next, _near_box(cells, sh, String(cut.get("lie", ""))))
		n += 1
	# Hand-laid bricks in the cut go too: the hole is a hole.
	var hand := {}
	for c in cells:
		var rid := _rid_at(c)
		if rid >= 0 and owner_of(ws.recipe.part_of(rid), ws.recipe.cell_of(rid)) < 0:
			hand[rid] = true
	var rids := hand.keys()
	rids.sort()
	rids.reverse()
	for rid in rids:
		rec.hand.append([ws.recipe.part_of(rid), _plain(ws.recipe.cell_of(rid)), ws.recipe.colour_of(rid),
				ws.recipe.material_of(rid), ws.recipe.role_of(rid)])
		ws._remove_rid(int(rid))
	return n + rids.size()


# ---------------------------------------------------------------------------
# Doors and windows (Docs/BuildTools.md section 6)
# ---------------------------------------------------------------------------

## A door or a window where a face was clicked, with its frame and glass as the options
## say: one cut through the wall (the opening and its frame), the frame and the glass kept
## shapes of their own. One undo. Returns the opening's spec.
func apply_opening(k: String, face: Dictionary) -> Dictionary:
	var op := opening_spec(k, face)
	var rec := _begin()
	_open_into(rec, op)
	_end(rec)
	return op


## What a door or a window clicked on a face would be: {kind, lie, at, depth, a, b (the
## opening), frame, glass, part, colour, mat (the frame's: the held brick)}.
func opening_spec(k: String, face: Dictionary) -> Dictionary:
	var size := door_size if k == "door" else window_size
	var l := String(face.lie)
	var uvw := BrickShapes.from_3d(l, face.cell)
	var u0 := uvw.x - (size.x >> 1)
	var v0 := uvw.y
	if k == "door":
		var v := uvw.y
		# Down while there is wall (the build's own bricks: not the baseplate).
		while v > 0 and _rid_at(BrickShapes.to_3d(l, Vector2i(uvw.x, v - 1), uvw.z)) >= 0:
			v -= 1
		v0 = v
	return {"kind": k, "lie": l, "at": int(face.at), "depth": int(face.depth),
			"a": [u0, v0], "b": [u0 + size.x - 1, v0 + size.y - 1],
			"frame": frame_on, "glass": glass_on and k == "window",
			"part": BrickPalette.part_of(ws._archetype_name()), "colour": ws._colour, "mat": ws._mat}


## The box an opening takes out of its wall: the opening, and its frame round it -- a stud
## each side, a brick's height over it, and under a window a brick's height of sill.
static func opening_box(op: Dictionary) -> Array:
	var a := BrickShapes._v2(op.a)
	var b := BrickShapes._v2(op.b)
	if not bool(op.get("frame", true)):
		return [a, b]
	var rv := maxi(1, int(round(1.0 / BrickShapes.aspect(String(op.lie)))))
	var lo := Vector2i(a.x - 1, a.y if op.kind == "door" else a.y - rv)
	return [lo, Vector2i(b.x + 1, b.y + rv)]


func _open_into(rec: Dictionary, op: Dictionary) -> void:
	var box := opening_box(op)
	var l := String(op.lie)
	_cut_into(rec, {"kind": "rect", "lie": l, "a": [box[0].x, box[0].y], "b": [box[1].x, box[1].y],
			"at": op.at, "depth": op.depth})
	if bool(op.frame):
		var fr := _new_shape("jamb" if op.kind == "door" else "hollow", l, box[0], box[1], int(op.at))
		fr.depth = int(op.depth)
		fr.rim = 1
		fr.part = op.part
		fr.colour = op.colour
		fr.mat = op.mat
		fr.opening = op
		_add_into(rec, fr)
	if bool(op.glass):
		var paint := glass_paint()
		var gl := _new_shape("rect", l, BrickShapes._v2(op.a), BrickShapes._v2(op.b),
				int(op.at) + ((int(op.depth) - 1) >> 1))
		gl.depth = 1
		gl.part = op.part
		gl.colour = paint.y
		gl.mat = paint.x
		gl.opening = op
		_add_into(rec, gl)


## Glass: (the see-through material, its clearest colour).
static func glass_paint() -> Vector2i:
	for m in BrickWorld.get_material_count():
		if not BrickWorld.is_material_translucent(m):
			continue
		var best := 0
		var score := -1
		for c in BrickWorld.get_material_colour_count(m):
			var n := BrickWorld.get_material_colour_name(m, c).to_lower()
			var sc := 0
			for w in [["clear", 5], ["transparent", 5], ["glass", 4], ["sky", 3], ["light blue", 3], ["ice", 3],
					["blue", 2], ["white", 1]]:
				if n.contains(String(w[0])):
					sc = maxi(sc, int(w[1]))
			if sc > score:
				score = sc
				best = c
		return Vector2i(m, best)
	return Vector2i(0, 0)


# ---------------------------------------------------------------------------
# Repeat: storeys and bays (Docs/BuildTools.md section 6)
# ---------------------------------------------------------------------------

## Copy what Repeat has (`rep_what`: the picked shape, or the storey rep_lo..rep_hi) `times`
## times `dir` ("up", "x", "z"), `gap` cells apart. One undo. Returns how many copies of
## shapes, openings and plain bricks were made.
func repeat(dir: String, times: int, gap: int) -> int:
	var g := _repeat_group()
	if g.is_empty() or times < 1:
		return 0
	var axis := 1 if dir == "up" else (0 if dir == "x" else 2)
	var lo: Vector3i = g.lo
	var hi: Vector3i = g.hi
	var span := hi[axis] - lo[axis] + 1 + gap
	var rec := _begin()
	rec.laid = []
	var n := 0
	ws._batch = true
	for k in range(1, times + 1):
		var d := Vector3i.ZERO
		d[axis] = span * k
		for sh in g.shapes:
			_add_into(rec, BrickShapes.shifted(sh, d))
			n += 1
		for op in g.openings:
			_open_into(rec, BrickShapes.shifted(op, d))
			n += 1
		ws._batch = true
		for b in g.bricks:
			var at: Vector3i = b[1] + d
			if ws.lay_part(String(b[0]), at, int(b[2]), int(b[3]), int(b[4])):
				rec.laid.append([b[0], _plain(at)])
				n += 1
	ws._batch = false
	_end(rec)
	return n


## What Repeat copies: {shapes, openings, bricks ([part, cell, colour, mat, role]), lo, hi
## (the box round it all, in cells)}, or empty for nothing.
func _repeat_group() -> Dictionary:
	var g := {"shapes": [], "openings": [], "bricks": [], "lo": Vector3i(1 << 30, 1 << 30, 1 << 30),
			"hi": -Vector3i(1 << 30, 1 << 30, 1 << 30)}
	if rep_what == "shape":
		var sh := shape_of(selected)
		if sh.is_empty():
			return {}
		if sh.has("opening"):
			var op: Dictionary = sh.opening
			g.openings.append(op)
			var box := opening_box(op)
			_grow(g, BrickShapes.solid_cells({"kind": "rect", "lie": op.lie, "a": [box[0].x, box[0].y],
					"b": [box[1].x, box[1].y], "at": op.at, "depth": op.depth}))
		else:
			g.shapes.append(sh)
			_grow(g, BrickShapes.solid_cells(sh))
		return g
	# A storey: the shapes wholly inside it, and every other brick inside it.
	var lo := mini(rep_lo, rep_hi)
	var hi := maxi(rep_lo, rep_hi)
	var copied := {}
	for sh in shapes():
		var cells := BrickShapes.solid_cells(sh)
		var inside := true
		for c in cells:
			if c.y < lo or c.y > hi:
				inside = false
				break
		if inside and not cells.is_empty():
			g.shapes.append(sh)
			copied[int(sh.id)] = true
	for i in ws.recipe.size():
		if ws.recipe.frame_of(i) != 0:
			continue
		var c: Vector3i = ws.recipe.cell_of(i)
		var size := BrickPalette.size_of(ws.recipe.part_of(i))
		if c.y < lo or c.y + size.y - 1 > hi:
			continue
		if copied.has(owner_of(ws.recipe.part_of(i), c)):
			continue
		g.bricks.append([ws.recipe.part_of(i), c, ws.recipe.colour_of(i), ws.recipe.material_of(i), ws.recipe.role_of(i)])
		_grow(g, {c: true, c + size - Vector3i.ONE: true})
	for sh in g.shapes:
		_grow(g, BrickShapes.solid_cells(sh))
	if g.shapes.is_empty() and g.bricks.is_empty():
		return {}
	# Up, a storey is its own height, whatever is built in it.
	g.lo.y = lo
	g.hi.y = hi
	return g


static func _grow(g: Dictionary, cells: Dictionary) -> void:
	for c in cells:
		g.lo = Vector3i(mini(g.lo.x, c.x), mini(g.lo.y, c.y), mini(g.lo.z, c.z))
		g.hi = Vector3i(maxi(g.hi.x, c.x), maxi(g.hi.y, c.y), maxi(g.hi.z, c.z))


## Repeat: a click picks the shape under it, and sets the storey to its height (or a
## plain brick's own).
func _repeat_click() -> void:
	_select_click()
	var sh := shape_of(selected)
	var ray := _ray()
	var hit: Dictionary = ws._first_hit(ray[0], ray[1])
	if not sh.is_empty():
		var cells := BrickShapes.solid_cells(sh)
		var lo := 1 << 30
		var hi := -(1 << 30)
		for c in cells:
			lo = mini(lo, c.y)
			hi = maxi(hi, c.y)
		rep_lo = lo
		rep_hi = hi
	elif not hit.is_empty() and hit.frame == ws.asm.frames[0]:
		var rid: int = ws._recipe_id_at(0, hit.block)
		if rid >= 0:
			rep_lo = ws.recipe.cell_of(rid).y
			rep_hi = rep_lo + BrickPalette.size_of(ws.recipe.part_of(rid)).y - 1
	_rep_lo_spin.set_value_no_signal(rep_lo)
	_rep_hi_spin.set_value_no_signal(rep_hi)


func _rid_at(c: Vector3i) -> int:
	var block: int = ws.world.block_at(ws.asm.frames[0], c)
	if block < 0 or not ws.world.is_solid(ws.asm.frames[0], c):
		return -1
	return ws._recipe_id_at(0, block)


## The box round a cut, a brick's length out along its plane and a course up and down (not
## deeper than the cut: a wall's cut leaves the wall behind it alone): a shape's bricks
## outside it stay where they are when it is laid again.
func _near_box(cells: Dictionary, sh: Dictionary, cut_lie: String = "") -> AABB:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for c in cells:
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	var size := BrickPalette.part_size(String(sh.part))
	var reach := maxi(size.x, size.z)
	var up := maxi(1, size.y)
	var g := Vector3i(reach, up, reach)
	match cut_lie:
		"flat": g.y = 0
		"wall_x": g.z = 0
		"wall_z": g.x = 0
	return AABB(Vector3(lo - g), Vector3(hi - lo + g * 2 + Vector3i.ONE))


## Lay a shape's bricks and store it. `near`: only the bricks touching it are taken up and
## laid again (the rest of the shape stays as it was); without it, all of them.
func _lay(sh: Dictionary, near: AABB = AABB()) -> void:
	var cells := BrickShapes.shape_cells(sh)
	var keep := []
	ws._batch = true
	if near.size == Vector3.ZERO:
		_take_up(sh)
	else:
		for b in sh.bricks:
			var at := BuildRecipe.cell_from(b[1])
			var size := BrickPalette.size_of(String(b[0]))
			var box := AABB(Vector3(at), Vector3(size))
			if box.intersects(near):
				_take_part(String(b[0]), at)
			else:
				keep.append(b)
	var taken := {}
	for c in cells:
		if _rid_at(c) >= 0:
			taken[c] = true
	var parts := BrickShapes.parts_for(String(sh.part), ws.palette)
	var base := _base_layer(sh)
	var laid := keep.duplicate()
	for pc in BrickShapes.pack_courses(cells, parts, String(sh.bond) != "align", taken, base):
		if ws.lay_part(String(pc[0]), pc[1], int(sh.colour), int(sh.mat), int(sh.get("role", 0))):
			laid.append([pc[0], _plain(pc[1])])
	ws._batch = false
	var out := sh.duplicate(true)
	out.bricks = laid
	_store(int(sh.id), out)


## The layer a shape's courses count from: its lowest, cuts or not, so a cut does not move
## the courses of the wall round it.
func _base_layer(sh: Dictionary) -> int:
	var l := String(sh.lie)
	if l == "flat":
		return int(sh.at)
	return mini(int(sh.a[1]), int(sh.b[1]))


## Take up a shape's bricks. The caller redraws (`_end`): taking up does not.
func _take_up(sh: Dictionary) -> void:
	for b in sh.bricks:
		_take_part(String(b[0]), BuildRecipe.cell_from(b[1]))


func _take_part(part: String, cell: Vector3i) -> bool:
	var rid: int = ws.find_brick(part, cell)
	if rid < 0:
		return false
	# A shape's bricks have no edit of their own: the shape's undo puts them back.
	ws._remove_rid(rid, false)
	return true


static func _plain(c: Vector3i) -> Array:
	return [c.x, c.y, c.z]


func _begin() -> Dictionary:
	return {"before": {}, "hand": []}


func _end(rec: Dictionary) -> void:
	_undo.append(rec)
	ws._edits.append("shape")
	ws._after_edit()


## Z on a shape edit: each shape it changed back as it was, its bricks with it; hand-laid
## bricks a cut took up laid again.
func undo() -> bool:
	if _undo.is_empty():
		return false
	var rec: Dictionary = _undo.pop_back()
	ws._edits.pop_back()
	ws._batch = true
	# Everything the edit laid comes up first, then what was there goes back: a door's frame
	# stands where its wall's bricks will go.
	for b in rec.get("laid", []):
		_take_part(String(b[0]), BuildRecipe.cell_from(b[1]))
	for id in rec.before:
		var now := shape_of(int(id))
		if not now.is_empty() and not rec.get("kept", false):
			_take_up(now)
	for id in rec.before:
		var was = rec.before[id]
		if was == null:
			_store(int(id), {})
			continue
		_store(int(id), was)
		if rec.get("kept", false):
			continue
		for b in was.bricks:
			ws.lay_part(String(b[0]), BuildRecipe.cell_from(b[1]), int(was.colour), int(was.mat), int(was.get("role", 0)))
	for h in rec.hand:
		ws.lay_part(String(h[0]), BuildRecipe.cell_from(h[1]), int(h[2]), int(h[3]), int(h[4]))
	ws._batch = false
	ws._after_edit()
	if selected >= 0 and shape_of(selected).is_empty():
		selected = -1
	return true


# ---------------------------------------------------------------------------
# The rail
# ---------------------------------------------------------------------------

## A rail button or its key: that tool in hand, everything else put down.
func pick(id: String) -> void:
	_drag = {}
	_sk = {}
	pen.points.clear()
	if ws._spaces != null and ws._spaces.active and id != "rooms":
		ws._spaces.toggle()
	match id:
		"paint":
			ws._set_painting(true)
		"rooms":
			ws._set_painting(false)
			if ws._spaces != null and not ws._spaces.active:
				ws._spaces.toggle()
		_:
			ws._set_painting(false)
	tool = id if id != "paint" and id != "rooms" else "place"
	if id != "select" and id != "repeat":
		selected = -1


## The tool in hand, as the rail lights it.
func active() -> String:
	if ws._painting:
		return "paint"
	if ws._spaces != null and ws._spaces.active:
		return "rooms"
	return tool


## True while a shape or a cut is dragged: the workshop holds the ghost's plane.
func dragging() -> bool:
	return not _drag.is_empty() or not _sk.is_empty()


func _build_options() -> void:
	rail.options.visible = true
	rail.options.add_child(HSeparator.new())
	_shape_box = VBoxContainer.new()
	rail.options.add_child(_shape_box)
	_kind_pick = _choice(_shape_box, "shape", BrickShapes.KINDS, func(i: int) -> void:
		kind = BrickShapes.KINDS[i][0])
	_lie_pick = _choice(_shape_box, "lies", LIE_NAMES, func(i: int) -> void:
		lie = LIE_NAMES[i][0])
	_tall_spin = _spin(_shape_box, "tall (plates; a brick is 3)", 1, 240, tall, func(v: float) -> void: tall = int(v))
	_thick_spin = _spin(_shape_box, "thick (studs)", 1, 16, thick, func(v: float) -> void: thick = int(v))
	_rim_spin = _spin(_shape_box, "rim (studs)", 1, 16, rim, func(v: float) -> void: rim = int(v))
	_bond_pick = _choice(_shape_box, "bond", [["stagger", "staggered (running bond)"], ["align", "aligned (stack bond)"]],
			func(i: int) -> void: staggered = i == 0)

	_sketch_box = VBoxContainer.new()
	rail.options.add_child(_sketch_box)
	rail.options.move_child(_sketch_box, _shape_box.get_index())
	_choice(_sketch_box, "draw with", SketchPen.DRAWS, func(i: int) -> void:
		pen.draw = SketchPen.DRAWS[i][0]
		pen.points.clear()
		_sk = {})
	_spin(_sketch_box, "brush (studs)", 0, 8, brush_size, func(v: float) -> void: brush_size = int(v))
	var sq := CheckBox.new()
	sq.text = "square brush"
	sq.focus_mode = Control.FOCUS_NONE
	sq.toggled.connect(func(on: bool) -> void: brush_square = on)
	_sketch_box.add_child(sq)

	_cut_box = VBoxContainer.new()
	rail.options.add_child(_cut_box)
	_choice(_cut_box, "cut", CUT_KINDS, func(i: int) -> void: cut_kind = CUT_KINDS[i][0])
	_door_box = VBoxContainer.new()
	_cut_box.add_child(_door_box)
	_spin(_door_box, "door wide (studs)", 1, 32, door_size.x, func(v: float) -> void: door_size.x = int(v))
	_spin(_door_box, "door tall (plates)", 3, 120, door_size.y, func(v: float) -> void: door_size.y = int(v))
	_window_box = VBoxContainer.new()
	_cut_box.add_child(_window_box)
	_spin(_window_box, "window wide (studs)", 1, 32, window_size.x, func(v: float) -> void: window_size.x = int(v))
	_spin(_window_box, "window tall (plates)", 1, 120, window_size.y, func(v: float) -> void: window_size.y = int(v))
	var gc := CheckBox.new()
	gc.text = "glass"
	gc.button_pressed = glass_on
	gc.focus_mode = Control.FOCUS_NONE
	gc.toggled.connect(func(on: bool) -> void: glass_on = on)
	_window_box.add_child(gc)
	var fc := CheckBox.new()
	fc.text = "frame (the held brick and colour)"
	fc.button_pressed = frame_on
	fc.focus_mode = Control.FOCUS_NONE
	fc.toggled.connect(func(on: bool) -> void: frame_on = on)
	_cut_box.add_child(fc)
	var cl := Label.new()
	cl.text = "Goes through the wall clicked, not the one behind it."
	_cut_box.add_child(cl)

	_repeat_box = VBoxContainer.new()
	rail.options.add_child(_repeat_box)
	_repeat_label = Label.new()
	_repeat_box.add_child(_repeat_label)
	_choice(_repeat_box, "repeat", REPEAT_WHAT, func(i: int) -> void: rep_what = REPEAT_WHAT[i][0])
	_rep_lo_spin = _spin(_repeat_box, "storey from (plate)", 0, 2000, rep_lo, func(v: float) -> void: rep_lo = int(v))
	_rep_hi_spin = _spin(_repeat_box, "to (plate)", 0, 2000, rep_hi, func(v: float) -> void: rep_hi = int(v))
	_choice(_repeat_box, "which way", REPEAT_DIRS, func(i: int) -> void: rep_dir = REPEAT_DIRS[i][0])
	_spin(_repeat_box, "times", 1, 50, rep_times, func(v: float) -> void: rep_times = int(v))
	_spin(_repeat_box, "gap (studs, or plates up)", 0, 100, rep_gap, func(v: float) -> void: rep_gap = int(v))
	_button(_repeat_box, "Repeat", func() -> void: repeat(rep_dir, rep_times, rep_gap))

	_select_box = VBoxContainer.new()
	rail.options.add_child(_select_box)
	_select_label = Label.new()
	_select_box.add_child(_select_label)
	_sel_depth = _spin(_select_box, "tall / thick", 1, 240, 3, func(v: float) -> void:
		if not _syncing and selected >= 0:
			change_shape(selected, {"depth": int(v)}))
	_sel_rim = _spin(_select_box, "rim (studs)", 1, 16, 1, func(v: float) -> void:
		if not _syncing and selected >= 0:
			change_shape(selected, {"rim": int(v)}))
	_sel_bond = _choice(_select_box, "bond", [["stagger", "staggered"], ["align", "aligned"]], func(i: int) -> void:
		if not _syncing and selected >= 0:
			change_shape(selected, {"bond": "stagger" if i == 0 else "align"}))
	_button(_select_box, "Lay it with the held brick", func() -> void:
		if selected >= 0:
			change_shape(selected, {"part": BrickPalette.part_of(ws._archetype_name()), "colour": ws._colour,
					"mat": ws._mat}))
	_button(_select_box, "Take its cuts out", func() -> void:
		if selected >= 0:
			change_shape(selected, {"cuts": []}))
	_button(_select_box, "Let go (keep the bricks)", func() -> void:
		if selected >= 0:
			let_go(selected))
	_button(_select_box, "Delete it", func() -> void:
		if selected >= 0:
			delete_shape(selected))
	_fit(rail.options)


func _choice(box: Container, label: String, items: Array, then: Callable) -> OptionButton:
	var l := Label.new()
	l.text = label
	box.add_child(l)
	var o := OptionButton.new()
	for it in items:
		o.add_item(String(it[1]))
	o.focus_mode = Control.FOCUS_NONE
	o.item_selected.connect(then)
	box.add_child(o)
	return o


func _spin(box: Container, label: String, lo: int, hi: int, v: int, then: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	box.add_child(row)
	var l := Label.new()
	l.text = label
	row.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.value = v
	s.value_changed.connect(then)
	row.add_child(s)
	return s


func _button(box: Container, text: String, then: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(then)
	box.add_child(b)


## Everything kept to the rail's width: labels wrap, choices clip.
func _fit(n: Node) -> void:
	for c in n.get_children():
		if c is Label:
			(c as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			(c as Label).custom_minimum_size.x = 168
			(c as Label).add_theme_font_size_override("font_size", 11)
		elif c is OptionButton:
			(c as OptionButton).clip_text = true
			(c as OptionButton).custom_minimum_size.x = 168
		elif c is HBoxContainer:
			for k in c.get_children():
				if k is Label:
					(k as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
					(k as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
					(k as Label).custom_minimum_size.x = 96
					(k as Label).add_theme_font_size_override("font_size", 11)
				elif k is SpinBox:
					(k as SpinBox).custom_minimum_size.x = 64
			continue
		_fit(c)


func _rail_right() -> float:
	return rail.position.x + rail.size.x + 12.0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## The tools' share of the input. True when it was theirs.
func input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and rail.has_mouse():
		return true
	if tool == "sketch" and _sketch_input(e):
		return true
	if e is InputEventKey and e.pressed and not e.echo and not e.ctrl_pressed:
		if e.alt_pressed:
			if e.keycode == KEY_D:
				pick("place" if tool == "sketch" else "sketch")
				return true
			return false
		match e.keycode:
			KEY_K:
				pick("place" if tool == "shape" else "shape")
				return true
			KEY_N:
				pick("place" if tool == "cut" else "cut")
				return true
			KEY_L:
				pick("place" if tool == "select" else "select")
				return true
			KEY_J:
				pick("place" if tool == "repeat" else "repeat")
				return true
			KEY_ESCAPE:
				if tool != "place" and _drag.is_empty() and _sk.is_empty():
					pick("place")
				else:
					_drag = {}
					_sk = {}
					pen.points.clear()
				return false   # Esc still frees the mouse
	if not (e is InputEventMouseButton) or e.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	match tool:
		"shape":
			return _shape_input(e)
		"cut":
			return _cut_input(e)
		"select":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_select_click()
				return true
		"repeat":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_repeat_click()
				return true
	return false


func _ray() -> Array:
	return ws._mouse_ray()


## Shapes: press where the ghost is, drag, let go. LMB lays the shape, RMB cuts it out.
func _shape_input(e: InputEventMouseButton) -> bool:
	if e.pressed:
		if not _drag.is_empty() or ws._frame != 0:
			return true
		var pl := _plane_at_ghost(lie)
		var l := String(pl.lie)
		var a: Vector2i = pl.a
		_drag = {"button": e.button_index, "lie": l, "at": pl.at, "a": a, "b": a,
				"depth": tall if l == "flat" else thick, "kind": kind}
		return true
	if _drag.is_empty() or e.button_index != int(_drag.button):
		return true
	var d := _drag
	_drag = {}
	if d.button == MOUSE_BUTTON_LEFT:
		add_shape(String(d.kind), String(d.lie), d.a, d.b, int(d.at))
	else:
		apply_cut({"kind": d.kind, "lie": d.lie, "a": [d.a.x, d.a.y], "b": [d.b.x, d.b.y],
				"at": d.at, "depth": d.depth, "rim": rim})
	return true


## Sketch: the plane is where the ghost is when the stroke begins (flat on that layer, or
## standing through it across the view, as Shapes); the pen draws on it; let go (or close a
## polygon) and it is a kept shape of the held brick -- drawn with RMB, a cut.
func _sketch_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if e.pressed:
			if _sk.is_empty():
				if ws._frame != 0:
					return true
				_sk = _plane_at_ghost(lie)
			var q = _plane_point(String(_sk.lie), int(_sk.at))
			if q == null:
				return true
			var rmb: bool = e.button_index == MOUSE_BUTTON_RIGHT
			if pen.draw == "polygon":
				if pen.polygon_click(q, rmb, e.double_click):
					_sketch_commit()
			else:
				pen.press(q, rmb)
		elif pen.draw != "polygon" and not _sk.is_empty():
			_sketch_commit()
		return true
	if e is InputEventMouseMotion and not _sk.is_empty() and pen.draw != "polygon" \
			and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		var q = _plane_point(String(_sk.lie), int(_sk.at))
		if q != null:
			pen.move(q, brush_size)
		return true
	if e is InputEventKey and pen.draw == "polygon" and not _sk.is_empty():
		match pen.polygon_key(e):
			"commit":
				_sketch_commit()
				return true
			"back":
				return true
	return false


## The stroke drawn, as a kept shape (or with RMB, a cut).
func _sketch_commit() -> void:
	var sk := _sk
	var entry = pen.entry("top" if sk.lie == "flat" else "side", brush_size, brush_square)
	var remove := pen.out
	_sk = {}
	pen.points.clear()
	if entry == null:
		return
	var cells := SketchPen.region_cells(entry)
	if cells.is_empty():
		return
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for c in cells:
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	if remove:
		apply_cut({"kind": "outline", "lie": sk.lie, "a": [lo.x, lo.y], "b": [hi.x, hi.y], "at": sk.at,
				"depth": tall if sk.lie == "flat" else thick, "points": entry})
	else:
		add_shape("outline", String(sk.lie), lo, hi, int(sk.at), entry)


## The plane a shape or a stroke starts on: where the ghost is -- flat on its layer, or
## standing through it across the view. {lie, at, a}: `a` the ghost's cell in the plane.
func _plane_at_ghost(want: String) -> Dictionary:
	var c: Vector3i = ws._cell
	var l := "flat"
	if want == "wall":
		var fwd: Vector3 = -ws._camera.global_transform.basis.z
		l = "wall_x" if absf(fwd.z) >= absf(fwd.x) else "wall_z"
	var uvw := BrickShapes.from_3d(l, c)
	return {"lie": l, "at": uvw.z, "a": Vector2i(uvw.x, uvw.y)}


## Cut: press on a face of the build, drag on its plane, let go; a door or a window is
## one click.
func _cut_input(e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if e.pressed:
		var face := face_under(_ray()[0], _ray()[1])
		if face.is_empty():
			return true
		var uvw := BrickShapes.from_3d(String(face.lie), face.cell)
		var a := Vector2i(uvw.x, uvw.y)
		if cut_kind in ["door", "window"]:
			apply_opening(cut_kind, face)
			return true
		_drag = {"button": MOUSE_BUTTON_LEFT, "lie": face.lie, "at": face.at, "a": a, "b": a,
				"depth": face.depth, "kind": cut_kind, "cut": true}
		return true
	if _drag.is_empty():
		return true
	var d := _drag
	_drag = {}
	apply_cut({"kind": d.kind, "lie": d.lie, "a": [d.a.x, d.a.y], "b": [d.b.x, d.b.y],
			"at": d.at, "depth": d.depth})
	return true


## The face of the build under a ray: {cell, lie, at, depth} -- the cell hit, the plane
## of the face (a side facing Z is wall_x, facing X wall_z, a top or bottom flat), and how
## deep the build is behind it there: a cut goes that far in, through the wall and no
## further. Empty if the ray hits nothing of the upright grid.
func face_under(from: Vector3, dir: Vector3) -> Dictionary:
	var hit: Dictionary = ws._first_hit(from, dir)
	if hit.is_empty() or hit.frame != ws.asm.frames[0]:
		return {}
	var f: int = ws.asm.frames[0]
	var c: Vector3i = ws._cell_in(f, hit.point)
	var back: Vector3i = ws._cell_in(f, hit.point - dir * BrickPalette.PLATE_M * 0.34)
	var n := back - c
	var l := "wall_x"
	var axis := 2
	if n.y != 0 and n.x == 0 and n.z == 0:
		l = "flat"
		axis = 1
	elif n.x != 0 and n.z == 0:
		l = "wall_z"
		axis = 0
	elif n == Vector3i.ZERO or (n.x != 0 and n.z != 0):
		# A corner: the way the ray mostly went.
		var ldir: Vector3 = ws.world.get_chunk_transform(f).basis.inverse() * dir
		if absf(ldir.x) > absf(ldir.z) and absf(ldir.x) > absf(ldir.y):
			l = "wall_z"
			axis = 0
		elif absf(ldir.y) > absf(ldir.z):
			l = "flat"
			axis = 1
	# In from the face while there is something built: that is the wall's thickness here.
	var step := Vector3i.ZERO
	step[axis] = -1 if n[axis] > 0 else 1
	if n[axis] == 0:
		var ldir2: Vector3 = ws.world.get_chunk_transform(f).basis.inverse() * dir
		step[axis] = 1 if ldir2[axis] > 0.0 else -1
	var p := c
	var depth := 0
	while depth < 64 and ws.world.is_solid(f, p):
		depth += 1
		p += step
	var first := c[axis]
	var last := c[axis] + step[axis] * (depth - 1)
	return {"cell": c, "lie": l, "at": mini(first, last), "depth": maxi(1, depth)}


## A door or a window where a face was clicked: a door stands on the lowest brick of the
## wall below the click, a window's sill is the click.
func preset_cut(k: String, face: Dictionary) -> Dictionary:
	var size := DOOR if k == "door" else WINDOW
	var l := String(face.lie)
	var uvw := BrickShapes.from_3d(l, face.cell)
	var u0 := uvw.x - (size.x >> 1)
	var v0 := uvw.y
	if k == "door":
		var v := uvw.y
		# Down while there is wall (the build's own bricks: not the baseplate).
		while v > 0 and _rid_at(BrickShapes.to_3d(l, Vector2i(uvw.x, v - 1), uvw.z)) >= 0:
			v -= 1
		v0 = v
	return {"kind": "rect", "lie": l, "a": [u0, v0], "b": [u0 + size.x - 1, v0 + size.y - 1],
			"at": face.at, "depth": face.depth}


func _select_click() -> void:
	var ray := _ray()
	var hit: Dictionary = ws._first_hit(ray[0], ray[1])
	selected = -1
	if hit.is_empty() or hit.frame != ws.asm.frames[0]:
		return
	var rid: int = ws._recipe_id_at(0, hit.block)
	if rid >= 0:
		selected = owner_of(ws.recipe.part_of(rid), ws.recipe.cell_of(rid))


func _sync_select() -> void:
	var sh := shape_of(selected)
	_syncing = true
	if sh.is_empty():
		_select_label.text = "Click a brick of a shape to pick it."
	else:
		var names := {}
		for k in BrickShapes.KINDS:
			names[k[0]] = k[1]
		_select_label.text = "%s, %s, %d bricks of %s%s" % [names.get(sh.kind, sh.kind),
				"flat" if sh.lie == "flat" else "a wall", (sh.bricks as Array).size(), sh.part,
				"" if (sh.cuts as Array).is_empty() else ", %d cut%s" % [(sh.cuts as Array).size(),
				"" if (sh.cuts as Array).size() == 1 else "s"]]
		_sel_depth.set_value_no_signal(int(sh.depth))
		_sel_rim.set_value_no_signal(int(sh.rim))
		_sel_bond.select(0 if sh.bond != "align" else 1)
	_syncing = false


# ---------------------------------------------------------------------------
# Each frame
# ---------------------------------------------------------------------------

func process() -> void:
	var top: float = 12.0 + (ws._menu.bar_height() if ws._menu != null else 0.0)
	rail.position = Vector2(12, top)
	rail.size = Vector2.ZERO
	var on := active()
	rail.show_active(on, TOOLS)
	_shape_box.visible = on == "shape" or on == "sketch"
	_sketch_box.visible = on == "sketch"
	_kind_pick.get_parent().get_child(_kind_pick.get_index() - 1).visible = on == "shape"
	_kind_pick.visible = on == "shape"
	_sketch_box.get_child(2).visible = pen.draw == "brush"   # the brush's size
	_sketch_box.get_child(3).visible = pen.draw == "brush"   # and shape
	_cut_box.visible = on == "cut"
	_door_box.visible = cut_kind == "door"
	_window_box.visible = cut_kind == "window"
	_repeat_box.visible = on == "repeat"
	if on == "repeat":
		var sh := shape_of(selected)
		_repeat_label.text = ("Click a brick to pick what to repeat." if sh.is_empty()
				else "Picked: %s%s." % [sh.kind, " (a door or window: it repeats with its cut)" if sh.has("opening") else ""])
		_rep_lo_spin.get_parent().visible = rep_what == "storey"
		_rep_hi_spin.get_parent().visible = rep_what == "storey"
	_select_box.visible = on == "select"
	_tall_spin.get_parent().visible = lie == "flat"
	_thick_spin.get_parent().visible = lie == "wall"
	_rim_spin.get_parent().visible = on == "shape" and kind in ["hollow", "ring", "line"]
	if on == "select" and _shown != Vector2i(selected, _rev):
		_shown = Vector2i(selected, _rev)
		_sync_select()
	# The workshop's readout and the paint palette move over beside the rail.
	var x := _rail_right()
	if ws._hud != null:
		ws._hud.position = Vector2(x, top)
	if ws._paint_palette != null:
		ws._paint_palette.position = Vector2(x, top + 110.0)
	if not _drag.is_empty():
		_drag.b = _drag_point()
		ws._ghost.visible = false
	elif tool in ["cut", "select", "repeat"] or not _sk.is_empty():
		ws._ghost.visible = false
	_draw()


## Where the drag is now, in its plane's cells.
func _drag_point() -> Vector2i:
	var l := String(_drag.lie)
	var q = _plane_point(l, int(_drag.at))
	if q == null:
		return _drag.b
	var b := Vector2i(int(floor(q.x)), int(floor(q.y)))
	if Input.is_key_pressed(KEY_SHIFT) and String(_drag.kind) in ["circle", "ring", "rect", "hollow"]:
		b = _square(_drag.a, b, BrickShapes.aspect(l))
	if l != "flat":
		b.y = maxi(b.y, 0)
	return b


## The ray under the cursor on a lie's plane `at` layers along, in the plane's own numbers
## (cells, as floats), or null if it misses. A flat plane is the bottom of its layer (the
## top of what it stands on); a standing one goes through the middle of its layer.
func _plane_point(l: String, at: int) -> Variant:
	var ray := _ray()
	var f: int = ws.asm.frames[0]
	var xf: Transform3D = ws.world.get_chunk_transform(f)
	var from: Vector3 = xf.affine_inverse() * (ray[0] as Vector3)
	var dir: Vector3 = xf.basis.inverse() * (ray[1] as Vector3)
	var axis := 1 if l == "flat" else (2 if l == "wall_x" else 0)
	var unit := BrickPalette.PLATE_M if axis == 1 else BrickPalette.STUD_M
	var plane := float(at) * unit if axis == 1 else (float(at) + 0.5) * unit
	if absf(dir[axis]) < 1e-5:
		return null
	var t := (plane - from[axis]) / dir[axis]
	if t <= 0.0:
		return null
	var p := from + dir * t
	var g := Vector3(p.x / BrickPalette.STUD_M, p.y / BrickPalette.PLATE_M, p.z / BrickPalette.STUD_M)
	match l:
		"flat": return Vector2(g.x, g.z)
		"wall_x": return Vector2(g.x, g.y)
	return Vector2(g.z, g.y)


## `b` moved so the box from `a` is as tall as it is wide, in metres.
static func _square(a: Vector2i, b: Vector2i, asp: float) -> Vector2i:
	var du := b.x - a.x
	var dv := b.y - a.y
	var w := maxf(absf(du) + 1.0, (absf(dv) + 1.0) * asp)
	var su := 1 if du >= 0 else -1
	var sv := 1 if dv >= 0 else -1
	return Vector2i(a.x + su * (int(round(w)) - 1), a.y + sv * (int(round(w / asp)) - 1))


func _draw() -> void:
	_im.clear_surfaces()
	var any := false
	if not _drag.is_empty():
		var d := _drag.duplicate()
		d.a = [d.a.x, d.a.y]
		d.b = [d.b.x, d.b.y]
		d.rim = rim
		var col := Color(1.0, 0.4, 0.3) if d.get("cut", false) or d.button == MOUSE_BUTTON_RIGHT \
				else Color(0.4, 0.95, 1.0)
		any = _outline(d, col, any)
	if not _sk.is_empty():
		var l := String(_sk.lie)
		var q = _plane_point(l, int(_sk.at))
		var w0 := float(_sk.at) + (0.0 if l == "flat" else 0.5)
		for seg in pen.preview(q, "top" if l == "flat" else "side", brush_size, brush_square):
			if not any:
				_im.surface_begin(Mesh.PRIMITIVE_LINES)
				any = true
			_im.surface_set_color(seg[2])
			_im.surface_add_vertex(_local(l, seg[0], w0))
			_im.surface_set_color(seg[2])
			_im.surface_add_vertex(_local(l, seg[1], w0))
	if tool in ["select", "repeat"] and selected >= 0:
		var sh := shape_of(selected)
		if not sh.is_empty():
			any = _outline(sh, Color(1.0, 0.85, 0.3), any)
			for cut in sh.cuts:
				any = _outline(cut, Color(1.0, 0.4, 0.3), any)
	if any:
		_im.surface_end()
	_lines.transform = ws.world.get_chunk_transform(ws.asm.frames[0])


## A shape's outline in its plane, drawn on its front and back face. True once begun.
func _outline(sh: Dictionary, col: Color, begun: bool) -> bool:
	var l := String(sh.lie)
	var c2 := BrickShapes.cells_2d(String(sh.kind), BrickShapes._v2(sh.a), BrickShapes._v2(sh.b),
			int(sh.get("rim", 1)), BrickShapes.aspect(l), sh.get("points", []))
	if c2.size() > 20000:
		return begun
	if not begun:
		_im.surface_begin(Mesh.PRIMITIVE_LINES)
	var ws_ := [float(sh.at), float(sh.at) + maxi(1, int(sh.depth))]
	for c in c2:
		for side in 4:
			var nb: Vector2i = c + [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)][side]
			if c2.has(nb):
				continue
			var p0: Vector2
			var p1: Vector2
			match side:
				0: p0 = Vector2(c.x, c.y); p1 = Vector2(c.x, c.y + 1)
				1: p0 = Vector2(c.x + 1, c.y); p1 = Vector2(c.x + 1, c.y + 1)
				2: p0 = Vector2(c.x, c.y); p1 = Vector2(c.x + 1, c.y)
				_: p0 = Vector2(c.x, c.y + 1); p1 = Vector2(c.x + 1, c.y + 1)
			for w in ws_:
				_im.surface_set_color(col)
				_im.surface_add_vertex(_local(l, p0, w))
				_im.surface_set_color(col)
				_im.surface_add_vertex(_local(l, p1, w))
	return true


## A point of a lie's plane (u, v) `w` layers along, in the grid's own metres.
static func _local(l: String, p: Vector2, w: float) -> Vector3:
	var s := BrickPalette.STUD_M
	var pl := BrickPalette.PLATE_M
	match l:
		"flat": return Vector3(p.x * s, w * pl, p.y * s)
		"wall_x": return Vector3(p.x * s, p.y * pl, w * s)
	return Vector3(w * s, p.y * pl, p.x * s)
