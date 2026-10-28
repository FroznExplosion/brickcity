class_name WorkshopTools
extends Node

## The building workshop's tools (Docs/BuildTools.md): the rail down the left (`ToolRail`,
## the asset workshop's own), and the tools that build buildings fast -- Shapes of the held
## brick, flat or standing as a wall, staggered or aligned; Cut, for doorways and windows;
## Walls, Floor, Roof and Stairs, the parts of a house a click or two each;
## Sketch, an outline drawn by hand with the asset workshop's own pen (SketchPen); Repeat,
## for storeys and rows of windows; Select,
## to change or let go of a kept shape. Place, Paint and Rooms are the workshop's
## own hand, brush and spaces tool.
##
## A shape stays a shape: it is kept in `recipe.meta.shapes` with its cuts and the bricks
## it laid, so a doorway cut through a wall later lays the wall again round it and leaves
## the rest of the wall's bricks where they are.

const TOOLS := [
	["place", "Place", "Esc", "Click to put the brick in hand on the stud you aim at; hold and move to lay a run (one undo). RMB takes one away."],
	["pick", "Pick", "MMB", "Click a brick to hold its part, colour and material."],
	["paint", "Paint", "B", "Click or drag over bricks to give them the colour in hand."],
	["shape", "Shapes", "K", "Press and drag the shape's outline on the floor (or a wall facing you), let go; then move the cursor up for its height and click to place. Right-click or Esc cancels."],
	["walls", "Walls", "", "Press and drag a line on the floor, let go; then move the cursor up for the wall's height and click to place. A wall drawn from where the last one ended joins it."],
	["floor", "Floor", "", "Press and drag the floor's rectangle, let go -- or just click inside closed walls to fill them; then move the cursor up for its thickness and click to place."],
	["roof", "Roof", "", "Click a shape (a room's walls): a gable or hip roof of slopes on top of it."],
	["stairs", "Stairs", "", "Click the lower floor, then the upper one: a straight stair between them."],
	["cut", "Cut", "N", "Drag a doorway, window or any shape on a wall: the wall is laid again round it. Door and window: one click, framed."],
	["sketch", "Sketch", "Alt D", "Draw an outline on the plane you aim at -- freehand, brush, rectangle, ellipse or clicked corners; then move the cursor up for its height and click to place."],
	["repeat", "Repeat", "J", "Copy the picked shape -- or a storey, everything between two heights -- N times up, or along X or Z. Click a brick here to pick what to repeat; a door or window repeats with its cut."],
	["select", "Select", "L", "Click a shape's brick to pick the shape: change its height, bond or brick, take its cuts out, delete it, or let it go (keep the bricks)."],
	["builds", "Builds", "X", "Click an inserted build to pick it, then Move, Copy or Delete it."],
	["rooms", "Rooms", "O", "Rooms and openings: click a room to find it or an opening to turn its kind; RMB forgets one."],
]
## Every key's button (Docs/BuildTools.md section 7): [id, label, key, what it does, toggle?].
const ACTIONS := [
	["Hand", [
		["rotate", "Rotate", "R", "Turn the brick in hand a quarter."],
		["flip", "Flip", "F", "Turn it over: studs down."],
		["turn_last", "Turn last", "T", "Turn the brick just placed a quarter."],
		["lock", "Lock", "E", "Lock height: keep the ghost at the height it is on now (as E held) until this is pressed again.", true],
		["snap", "Side stud", "V", "Snap to side studs.", true],
		["layer", "Structure", "I", "The layer the next brick goes in: structure, interior or detail (press for the next)."],
		["mirror", "Mirror", "", "Lay every brick and shape again across the mirror plane.", true],
		["mirror_axis", "across Z", "", "Which way the mirror plane goes: across Z or across X."],
		["mirror_here", "Set plane", "", "Mirror plane here: through the middle of the ghost."],
		["colour_back", "< Colour", ",", "The colour before, in the slot in hand."],
		["colour_on", "Colour >", ".", "The next colour, in the slot in hand."],
		["parts", "All parts", "Tab", "Open the parts browser."],
	]],
	["Edit", [
		["undo", "Undo", "Z", "Take back the last edit: a brick, a run, a shape."],
		["redo", "Redo", "Shift Z", "Lay back what Undo took."],
		["cancel", "Cancel", "Esc", "Drop what is being drawn (a drag, a sketch, a wall line, a stair's first click)."],
	]],
	["View", [
		["grid", "Grid", "G", "Show the grid.", true],
		["stress", "Stress", "H", "Show how hard each brick is working.", true],
		["keys", "Keys", "F1", "Show every key.", true],
		["guide", "Guide", "U", "Room guide: a room template's size; again for the next."],
	]],
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
## What was a modifier, as an option (section 7): LMB lays or cuts out; Shift's round.
var cut_mode := false
var keep_round := false
## Walls: the corners clicked (cells of the flat plane at `_wall_at`), straight or free.
var wall_straight := true
var _wall_pts: Array[Vector2i] = []
var _wall_at := 0
## Floor: how thick (plates), and on the floor clicked or on top of the walls round it.
var floor_tall := 1
var floor_on_top := false
## Stairs: how wide (studs); the first click (the lower floor), or NO_CELL.
const NO_CELL := Vector3i(-1048576, 0, 0)
var stair_wide := 3
var _stair_from := NO_CELL
## Roof: gable or hip, and how far it reaches past the walls (studs).
var roof_style := "gable"
var roof_overhang := 1
## Rooms: a click marks an opening point (P) instead of finding a room.
var room_points := false
## Sketch: the pen (the asset workshop's), its brush, and the plane a stroke is on --
## {lie, at} while one is drawn, else empty.
var pen := SketchPen.new()
var brush_size := 1
var brush_square := false
var _sk := {}
## The wall the last Walls drag made: the next one, drawn from its end, joins it.
var _last_wall := -1
## The bricks a shape in the making will lay, shown: its key, and [[part, cell], ...].
var _plan_key := ""
var _plan := []
var _base_key := ""
var _base_rec := {}
var _bricks_mi: MeshInstance3D
var _bim: ImmediateMesh

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
var _sel_depth: SpinBox
var _sel_rim: SpinBox
var _sel_bond: OptionButton
var _repeat_box: VBoxContainer
var _status: Label
var _status_left := 0.0
var _lay_box: VBoxContainer
var _poly_box: HBoxContainer
var _walls_box: VBoxContainer
var _floor_box: VBoxContainer
var _stairs_box: VBoxContainer
var _roof_box: VBoxContainer
var _paint_box: VBoxContainer
var _paint_spin: SpinBox
var _builds_box: VBoxContainer
var _builds_label: Label
var _rooms_box: VBoxContainer
var _rooms_label: Label
var _slope_cache := {}
var _repeat_label: Label
var _rep_lo_spin: SpinBox
var _rep_hi_spin: SpinBox
var _door_box: VBoxContainer
var _window_box: VBoxContainer
var _syncing := false


func setup(workshop, layer: CanvasLayer) -> void:
	ws = workshop
	rail = ToolRail.new(210.0, true)
	rail.name = "ToolRail"
	layer.add_child(rail)
	rail.fill("Build", TOOLS, pick, [], 2)
	rail.actions(ACTIONS, act)
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
	# What a shape in the making will lay: its bricks, see-through.
	_bim = ImmediateMesh.new()
	_bricks_mi = MeshInstance3D.new()
	_bricks_mi.mesh = _bim
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.vertex_color_use_as_albedo = true
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bricks_mi.material_override = bm
	_bricks_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ws.add_child(_bricks_mi)


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
	return create(sh)


## Lay a new shape (and, with the mirror on, its mirror image) as one undo. Returns its id.
func create(sh: Dictionary) -> int:
	var rec := _begin()
	var id := _add_into(rec, sh)
	var m = _mirrored(sh)
	if m != null:
		_add_into(rec, m)
	_end(rec)
	return id


## A shape's (or a cut's, or an opening's) mirror image while the mirror is on, or null --
## also when it is its own mirror image.
func _mirrored(sh: Dictionary) -> Variant:
	if not ws.mirror_on:
		return null
	var plane: float = ws.mirror_x if ws.mirror_axis == 0 else ws.mirror_z
	var m := BrickShapes.reflected(sh, ws.mirror_axis, plane)
	if m.has("kind") and BrickShapes.solid_cells(m) == BrickShapes.solid_cells(sh):
		return null
	if m.has("id"):
		m.id = _next_id()
	return m


## A shape's record from the options in hand (the held brick, colour, material), not laid.
func _new_shape(k: String, l: String, a: Vector2i, b: Vector2i, at: int, points: Variant = []) -> Dictionary:
	var sh := {
		"id": _next_id(), "kind": k, "lie": l, "a": [a.x, a.y], "b": [b.x, b.y], "at": at,
		"depth": tall if l == "flat" else thick, "rim": held_width(), "bond": "stagger" if staggered else "align",
		"part": BrickPalette.part_of(ws._archetype_name()), "colour": ws._colour, "mat": ws._mat,
		"role": ws._role, "cuts": [], "bricks": [],
	}
	if (points is Array and not (points as Array).is_empty()) or points is Dictionary:
		sh.points = points
	return sh


## The held brick's width (its narrow side, in studs): a wall's thickness, a ring's rim.
func held_width() -> int:
	var size := BrickPalette.part_size(BrickPalette.part_of(_fill_part(ws._archetype_name())))
	return maxi(1, mini(size.x, size.z)) if size != Vector3i.ZERO else 1


## What a pull of the height goes up by: the held brick's own height (3 plates for a brick,
## 1 for a plate); standing (a thickness, in studs) one stud.
func height_step(l: String) -> int:
	if l != "flat":
		return 1
	var size := BrickPalette.part_size(BrickPalette.part_of(_fill_part(ws._archetype_name())))
	return maxi(1, size.y) if size != Vector3i.ZERO else 3


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
	var m = _mirrored(cut)
	if m != null:
		n += _cut_into(rec, m)
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
	if ws.mirror_on:
		var plane: float = ws.mirror_x if ws.mirror_axis == 0 else ws.mirror_z
		var m := BrickShapes.reflected(op, ws.mirror_axis, plane)
		if m != op:
			_open_into(rec, m)
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
				rec.laid.append([b[0], _plain(at), b[2], b[3], b[4]])
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
	var roof := String(sh.kind) == "roof"
	if near.size == Vector3.ZERO or roof:
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
	var parts := BrickShapes.parts_for(_fill_part(String(sh.part)), ws.palette)
	var base := _base_layer(sh)
	var laid := keep.duplicate()
	if roof:
		# The slopes along its edges first, facing out; the bricks fill the rest.
		# The held brick when it is a slope that steps a stud a course (a 1x2 or 2x2 slope
		# or curve), else the 45-degree 1x2; a hip's corners, the corner slope.
		var held := String(sh.part)
		var own := held if _roof_slope(held) else ""
		for sl in BrickShapes.roof_plan(sh).slopes:
			var at: Vector3i = sl[1]
			var tries: Array = [String(sl[2])] if sl.size() > 2 else ([own, "slope_1x2"] if own != "" else ["slope_1x2"])
			for part in tries:
				var v := _part_facing(part, sl[0])
				if v == "":
					continue
				var size := BrickPalette.size_of(v)
				var free := true
				var inside := 0
				for dx in size.x:
					for dy in size.y:
						for dz in size.z:
							var c := at + Vector3i(dx, dy, dz)
							free = free and not taken.has(c)
							if cells.has(c):
								inside += 1
				# All of it the roof's, but for the top plate where its face falls away (none
				# of it cut out, none past the roof's end).
				free = free and inside >= size.x * size.y * size.z - size.x * size.z
				if free and ws.lay_part(v, at, int(sh.colour), int(sh.mat), int(sh.get("role", 0))):
					laid.append([v, _plain(at)])
					for dx in size.x:
						for dy in size.y:
							for dz in size.z:
								taken[at + Vector3i(dx, dy, dz)] = true
					break
	for pc in BrickShapes.pack_courses(cells, parts, String(sh.bond) != "align", taken, base):
		if ws.lay_part(String(pc[0]), pc[1], int(sh.colour), int(sh.mat), int(sh.get("role", 0))):
			laid.append([pc[0], _plain(pc[1])])
	ws._batch = false
	var out := sh.duplicate(true)
	out.bricks = laid
	_store(int(sh.id), out)


## `part` turned to face `dir`, or "" if the palette has no such turn of it.
func _part_facing(part: String, dir: Vector3i) -> String:
	var key := "%s|%s" % [part, dir]
	if _slope_cache.has(key):
		return _slope_cache[key]
	var out := ""
	for y in 4:
		var v := BrickPalette.variant_name(part, y, false)
		if ws.palette.has(v) and BrickPalette.front_of(v) == dir:
			out = v
			break
	_slope_cache[key] = out
	return out


## True for a slope a roof can step with: a brick high, falling two studs (a 1x2 or 2x2
## slope or curve), so each course steps in a stud.
static func _roof_slope(part: String) -> bool:
	var p := BrickPalette.part_of(part) if BrickPalette.part_of(part) != "" else part
	if not (p.begins_with("slope_") or p.begins_with("curve_")):
		return false
	var size := BrickPalette.part_size(p)
	return size.y == 3 and size.z == 2 and size.x <= 2


## What fills a shape when the held part is no brick, plate or tile (a slope, a round): a
## brick of its footprint, else a 1x2 brick -- slopes laid in courses would face anywhere.
static func _fill_part(part: String) -> String:
	var p := BrickPalette.part_of(part) if BrickPalette.part_of(part) != "" else part
	if BrickPalette.family_of(p) in ["brick", "plate", "tile"]:
		return part
	var size := BrickPalette.part_size(p)
	var b := "brick_%dx%d" % [mini(size.x, size.z), maxi(size.x, size.z)]
	return b if BrickPalette.part_size(b) != Vector3i.ZERO else "brick_1x2"


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
## bricks a cut took up laid again, plain bricks a repeat laid taken up. What it undid goes
## on the workshop's redo list.
func undo() -> bool:
	if _undo.is_empty():
		return false
	var rec: Dictionary = _undo.pop_back()
	ws._edits.pop_back()
	ws._redo_list.append({"kind": "shape", "rec": _apply(rec)})
	return true


## Redo: a record `undo` gave back, done again (and undoable again).
func redo(rec: Dictionary) -> bool:
	_undo.append(_apply(rec))
	ws._edits.append("shape")
	ws._after_edit()
	return true


## Put the shapes in `rec.before` back as they were (null: gone), take up `rec.laid`, lay
## `rec.hand` back. Returns the record that does the opposite.
func _apply(rec: Dictionary) -> Dictionary:
	var kept: bool = rec.get("kept", false)
	var inv := {"before": {}, "hand": (rec.get("laid", []) as Array).duplicate(true),
			"laid": (rec.get("hand", []) as Array).duplicate(true), "kept": kept}
	for id in rec.before:
		var now := shape_of(int(id))
		if now.is_empty():
			inv.before[id] = null
		else:
			inv.before[id] = now
	ws._batch = true
	# Everything the edit laid comes up first, then what was there goes back: a door's frame
	# stands where its wall's bricks will go.
	for b in rec.get("laid", []):
		_take_part(String(b[0]), BuildRecipe.cell_from(b[1]))
	for id in rec.before:
		var now := shape_of(int(id))
		if not now.is_empty() and not kept:
			_take_up(now)
	for id in rec.before:
		var was = rec.before[id]
		if was == null:
			_store(int(id), {})
			continue
		_store(int(id), was)
		if kept:
			continue
		for b in was.bricks:
			ws.lay_part(String(b[0]), BuildRecipe.cell_from(b[1]), int(was.colour), int(was.mat), int(was.get("role", 0)))
	for h in rec.get("hand", []):
		ws.lay_part(String(h[0]), BuildRecipe.cell_from(h[1]), int(h[2]), int(h[3]), int(h[4]))
	ws._batch = false
	ws._after_edit()
	if selected >= 0 and shape_of(selected).is_empty():
		selected = -1
	return inv


# ---------------------------------------------------------------------------
# The rail
# ---------------------------------------------------------------------------

## A rail button or its key: that tool in hand, everything else put down.
func pick(id: String) -> void:
	cancel()
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
	if id != "select" and id != "repeat" and id != "roof":
		selected = -1
	match id:
		"stairs": say("Click the lower floor where the stair starts.")
		"walls": say("Click the first corner.")
		_: say("")


## Drop what is being drawn: a drag, a stroke, a wall line, a stair's first click.
func cancel() -> void:
	_drag = {}
	_base_key = ""
	_sk = {}
	pen.points.clear()
	_wall_pts.clear()
	_stair_from = NO_CELL


## An action button (or its key, which the workshop handles as before).
func act(id: String) -> void:
	match id:
		"rotate": ws._yaw = (ws._yaw + 1) % 4
		"flip": ws._flip = not ws._flip
		"turn_last": ws._rotate_last()
		"lock": ws.plane_locked = not ws.plane_locked
		"snap": ws._snap_on = not ws._snap_on
		"layer": ws._toggle_layer()
		"mirror": ws.set_mirror(not ws.mirror_on)
		"mirror_axis":
			ws.mirror_axis = 0 if ws.mirror_axis == 2 else 2
			ws.set_mirror(ws.mirror_on)
		"mirror_here":
			ws.mirror_here()
			if not ws.mirror_on:
				ws.set_mirror(true)
		"colour_back": ws._hotbar.set_colour(ws._colour - 1)
		"colour_on": ws._hotbar.set_colour(ws._colour + 1)
		"parts": ws._hotbar.toggle_browser()
		"undo": ws._undo()
		"redo": ws.redo_last()
		"cancel": cancel()
		"grid":
			ws._grid_on = not ws._grid_on
			ws._grid.visible = ws._grid_on
		"stress":
			ws._overlay_on = not ws._overlay_on
			ws._stress_dirty = true
			ws._refresh_overlay()
		"keys":
			ws._keys_on = not ws._keys_on
			ws._keys_panel.visible = ws._keys_on
		"guide": ws._cycle_guide()


## Say something on the rail for a few seconds (a fill refused, the next click wanted).
func say(text: String) -> void:
	_status.text = text
	_status.visible = text != ""
	_status_left = 6.0


## The tool in hand, as the rail lights it.
func active() -> String:
	if ws._painting:
		return "paint"
	if ws._spaces != null and ws._spaces.active:
		return "rooms"
	return tool


## True while a shape or a cut is dragged: the workshop holds the ghost's plane.
func dragging() -> bool:
	return not _drag.is_empty() or not _sk.is_empty() or not _wall_pts.is_empty()


func _build_options() -> void:
	rail.options.visible = true
	rail.options.add_child(HSeparator.new())
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(1.0, 0.88, 0.5))
	_status.visible = false
	rail.options.add_child(_status)
	_lay_box = VBoxContainer.new()
	rail.options.add_child(_lay_box)
	_choice(_lay_box, "a drag (or a stroke)", [["lay", "lays bricks"], ["cut", "cuts them out (as RMB)"]],
			func(i: int) -> void: cut_mode = i == 1)
	var kr := CheckBox.new()
	kr.text = "keep circles round (Shift)"
	kr.focus_mode = Control.FOCUS_NONE
	kr.toggled.connect(func(on: bool) -> void: keep_round = on)
	_lay_box.add_child(kr)
	_shape_box = VBoxContainer.new()
	rail.options.add_child(_shape_box)
	_kind_pick = _choice(_shape_box, "shape", BrickShapes.KINDS, func(i: int) -> void:
		kind = BrickShapes.KINDS[i][0])
	_lie_pick = _choice(_shape_box, "lies", LIE_NAMES, func(i: int) -> void:
		lie = LIE_NAMES[i][0])
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

	_poly_box = HBoxContainer.new()
	_sketch_box.add_child(_poly_box)
	_button(_poly_box, "Close", func() -> void:
		if pen.draw == "polygon" and not _sk.is_empty():
			_sketch_commit())
	_button(_poly_box, "Take back", func() -> void:
		if not pen.points.is_empty():
			pen.points.pop_back())

	_walls_box = VBoxContainer.new()
	rail.options.add_child(_walls_box)
	var st := CheckBox.new()
	st.text = "straight (along X or Z)"
	st.button_pressed = wall_straight
	st.focus_mode = Control.FOCUS_NONE
	st.toggled.connect(func(on: bool) -> void: wall_straight = on)
	_walls_box.add_child(st)
	var wl := Label.new()
	wl.text = "As thick as the held brick is wide."
	_walls_box.add_child(wl)

	_floor_box = VBoxContainer.new()
	rail.options.add_child(_floor_box)
	_choice(_floor_box, "a click (no drag) fills", [["here", "the floor inside the walls"], ["top", "over the walls' tops"]],
			func(i: int) -> void: floor_on_top = i == 1)

	_stairs_box = VBoxContainer.new()
	rail.options.add_child(_stairs_box)
	_spin(_stairs_box, "wide (studs)", 1, 16, stair_wide, func(v: float) -> void: stair_wide = int(v))

	_roof_box = VBoxContainer.new()
	rail.options.add_child(_roof_box)
	_choice(_roof_box, "roof", [["gable", "gable (two sides slope)"], ["hip", "hip (all four slope)"]],
			func(i: int) -> void: roof_style = "gable" if i == 0 else "hip")
	_spin(_roof_box, "overhang (studs)", 0, 4, roof_overhang, func(v: float) -> void: roof_overhang = int(v))

	_paint_box = VBoxContainer.new()
	rail.options.add_child(_paint_box)
	_paint_spin = _spin(_paint_box, "brush (studs; - =)", 0, ws.PAINT_RADIUS_MAX, ws._paint_radius, func(v: float) -> void:
		ws._paint_radius = int(v)
		if ws._paint_palette != null:
			ws._paint_palette.info = ws._paint_info())

	_builds_box = VBoxContainer.new()
	rail.options.add_child(_builds_box)
	_builds_label = Label.new()
	_builds_box.add_child(_builds_label)
	var brow := HBoxContainer.new()
	_builds_box.add_child(brow)
	_button(brow, "Move", func() -> void: ws.move_group())
	_button(brow, "Copy", func() -> void: ws.copy_group())
	_button(brow, "Delete", func() -> void: ws.delete_group())

	_rooms_box = VBoxContainer.new()
	rail.options.add_child(_rooms_box)
	_rooms_label = Label.new()
	_rooms_box.add_child(_rooms_label)
	var rrow := HBoxContainer.new()
	_rooms_box.add_child(rrow)
	_button(rrow, "< kind", func() -> void: ws._spaces.cycle_kind(-1))
	_button(rrow, "kind >", func() -> void: ws._spaces.cycle_kind(1))
	_button(_rooms_box, "Opening point kind (shift P)", func() -> void: ws._spaces.cycle_point_kind())
	var rp := CheckBox.new()
	rp.text = "click marks an opening point (P)"
	rp.focus_mode = Control.FOCUS_NONE
	rp.toggled.connect(func(on: bool) -> void: room_points = on)
	_rooms_box.add_child(rp)

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
	if e is InputEventMouseButton and _drag.get("phase", "") == "height" \
			and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return _make_input(e)
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
				if tool != "place" and not dragging() and _stair_from == NO_CELL:
					pick("place")
				else:
					cancel()
				return false   # Esc still frees the mouse
			KEY_ENTER, KEY_KP_ENTER:
				if _drag.get("phase", "") == "height":
					commit_pending()
					return true
	if not (e is InputEventMouseButton) or e.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	match tool:
		"shape", "walls", "floor":
			return _make_input(e)
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
		"pick":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				ws._pick_block()
				return true
		"builds":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				var ray := _ray()
				ws.select_group_ray(ray[0], ray[1])
				return true
		"stairs":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_stairs_click()
				return true
		"roof":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_select_click()
				if selected >= 0:
					roof_on(selected)
				else:
					say("Click a brick of a shape (a room's walls).")
				return true
	return false


func _ray() -> Array:
	return ws._mouse_ray()


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
			var rmb: bool = e.button_index == MOUSE_BUTTON_RIGHT or cut_mode
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
	# Then its height, as Shapes.
	_drag = {"phase": "base", "tool": "sketch", "button": MOUSE_BUTTON_LEFT, "lie": sk.lie, "at": sk.at,
			"a": lo, "b": hi, "kind": "outline", "cut": remove}
	_to_height(_new_shape("outline", String(sk.lie), lo, hi, int(sk.at), entry))


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


# ---------------------------------------------------------------------------
# Walls, Floor, Stairs, Roof (Docs/BuildTools.md section 7)
# ---------------------------------------------------------------------------

## Shapes, Walls and Floor (Docs/BuildTools.md section 8): press where you aim and drag
## the base -- the outline, the line, the rectangle -- and let go; then the height follows
## the cursor up, and a click places it. Right-click (or Esc) cancels. A Floor clicked
## without a drag fills the walls round the click. Shapes drawn with RMB, or with "cuts them
## out", cut instead.
func _make_input(e: InputEventMouseButton) -> bool:
	if _drag.get("phase", "") == "height":
		if e.pressed:
			if e.button_index == MOUSE_BUTTON_LEFT:
				commit_pending()
			else:
				cancel()
				say("")
		return true
	if e.pressed:
		if not _drag.is_empty():
			return true
		if ws._frame != 0:
			say("Shapes go on the upright grid: aim at a brick top or the floor.")
			return true
		# RMB outside a drag is the workshop's own (it takes a brick away), but in Shapes.
		if e.button_index == MOUSE_BUTTON_RIGHT and tool != "shape":
			return false
		var pl := _plane_at_ghost(lie if tool == "shape" else "flat")
		var a: Vector2i = pl.a
		var k := kind
		match tool:
			"walls": k = "polyline"
			"floor": k = "rect"
		_drag = {"phase": "base", "tool": tool, "button": e.button_index, "lie": pl.lie, "at": pl.at,
				"a": a, "b": a, "kind": k, "cut": tool == "shape" and (e.button_index == MOUSE_BUTTON_RIGHT or cut_mode)}
		say("Drag, then let go." if tool != "floor" else "Drag a rectangle, or let go here to fill the walls round it.")
		return true
	if _drag.is_empty() or e.button_index != int(_drag.get("button", -1)):
		return true
	_to_height()
	return true


## The record the base drawn so far makes (its depth one step), or empty.
func _base_record(d: Dictionary) -> Dictionary:
	if d.has("rec"):
		return d.rec
	var a: Vector2i = d.a
	var b: Vector2i = d.b
	var key := "%s|%s|%s|%s|%s|%s|%s" % [d.tool, d.kind, d.lie, d.at, a, b, ws._archetype_name()]
	if key == _base_key:
		return _base_rec
	var rec := {}
	match String(d.tool):
		"walls":
			rec = _new_shape("polyline", "flat", Vector2i(mini(a.x, b.x), mini(a.y, b.y)),
					Vector2i(maxi(a.x, b.x), maxi(a.y, b.y)), int(d.at),
					{"pts": [[a.x, a.y], [b.x, b.y]], "closed": false})
		"floor":
			if a == b:
				rec = floor_record(Vector3i(a.x, int(d.at), a.y), floor_on_top)
			else:
				rec = _new_shape("rect", "flat", a, b, int(d.at))
		_:
			rec = _new_shape(String(d.kind), String(d.lie), a, b, int(d.at))
	if not rec.is_empty():
		rec.depth = height_step(String(rec.lie))
	_base_key = key
	_base_rec = rec
	return rec


## The base is drawn: now the height. `rec` the shape so far, if not the drag's.
func _to_height(rec: Dictionary = {}) -> void:
	if rec.is_empty():
		rec = _base_record(_drag).duplicate(true)
	if rec.is_empty():
		_drag = {}
		return
	rec.depth = height_step(String(rec.lie))
	var l := String(rec.lie)
	var c2 := BrickShapes.cells_2d(String(rec.kind), BrickShapes._v2(rec.a), BrickShapes._v2(rec.b),
			int(rec.get("rim", 1)), BrickShapes.aspect(l), rec.get("points", []))
	var lo := Vector2(INF, INF)
	var hi := -lo
	for c in c2:
		lo = lo.min(Vector2(c))
		hi = hi.max(Vector2(c) + Vector2.ONE)
	if c2.is_empty():
		lo = Vector2(BrickShapes._v2(rec.a))
		hi = lo + Vector2.ONE
	_drag.phase = "height"
	_drag.rec = rec
	_drag.at0 = int(rec.at)
	_drag.anchor = _local(l, (lo + hi) * 0.5, float(rec.at))
	say("Move the cursor up for the height; click to place. Right-click or Esc cancels.")


## The height under the cursor: where the ray passes closest to the line straight up (or,
## standing, straight out) from the base's middle, in steps of the held brick.
func _pull_height() -> void:
	var rec: Dictionary = _drag.rec
	var l := String(rec.lie)
	var axis := Vector3.UP if l == "flat" else (Vector3.BACK if l == "wall_x" else Vector3.RIGHT)
	var unit := BrickPalette.PLATE_M if l == "flat" else BrickPalette.STUD_M
	var ray := _ray()
	# Only when the cursor (or the view) moved: a height set stays set.
	if _drag.get("last_ray") == ray:
		return
	_drag.last_ray = ray
	var xf: Transform3D = ws.world.get_chunk_transform(ws.asm.frames[0])
	var from: Vector3 = xf.affine_inverse() * (ray[0] as Vector3)
	var dir: Vector3 = (xf.basis.inverse() * (ray[1] as Vector3)).normalized()
	var w0: Vector3 = (_drag.anchor as Vector3) - from
	var b := axis.dot(dir)
	var den := 1.0 - b * b
	if absf(den) < 1e-6:
		return
	var along := (b * dir.dot(w0) - axis.dot(w0)) / den
	var step := height_step(l)
	var n := int(round(along / unit / step)) * step
	if l == "flat":
		rec.depth = maxi(step, n)
		rec.at = int(_drag.at0)
	else:
		# Standing: pulled toward you or away, its thickness.
		rec.depth = maxi(1, absi(n))
		rec.at = int(_drag.at0) if n >= 0 else int(_drag.at0) - rec.depth + 1
	var bricks := ""
	if l == "flat" and step == 1:
		bricks = " (%d brick%s and %d plate%s)" % [rec.depth / 3, "" if rec.depth / 3 == 1 else "s",
				rec.depth % 3, "" if rec.depth % 3 == 1 else "s"]
	elif l == "flat":
		bricks = " (%d course%s)" % [rec.depth / step, "" if rec.depth / step == 1 else "s"]
	say(("%d plate%s tall%s" % [rec.depth, "" if rec.depth == 1 else "s", bricks] if l == "flat"
			else "%d stud%s thick" % [rec.depth, "" if rec.depth == 1 else "s"])
			+ ". Click to place; right-click or Esc cancels.")


## Place what is being made, at the height pulled. Returns its id (or -1: a cut, nothing).
func commit_pending() -> int:
	if _drag.get("phase", "") != "height":
		if _drag.get("phase", "") == "base":
			_to_height()
		else:
			return -1
	var d := _drag
	_drag = {}
	var rec: Dictionary = d.rec
	say("")
	if d.get("cut", false):
		var cut := {}
		for k in ["kind", "lie", "a", "b", "at", "depth", "rim", "points"]:
			if rec.has(k):
				cut[k] = rec[k]
		apply_cut(cut)
		return -1
	if String(d.get("tool", "")) == "walls":
		return _commit_wall(rec)
	return create(rec)


## A wall line: drawn from where the last one ended, at its height, it joins it (and on its
## first corner it closes it), so the corners interlock.
func _commit_wall(rec: Dictionary) -> int:
	var last := shape_of(_last_wall)
	var pts: Array = rec.points.pts
	var a := BrickShapes._v2(pts[0])
	var b := BrickShapes._v2(pts[1])
	if not last.is_empty() and String(last.kind) == "polyline" and int(last.at) == int(rec.at) \
			and int(last.depth) == int(rec.depth) and String(last.part) == String(rec.part) \
			and not bool(last.points.get("closed", false)) and not ws.mirror_on:
		var lp: Array = (last.points.pts as Array).duplicate(true)
		if BrickShapes._v2(lp.back()) == a:
			var closes := lp.size() >= 3 and BrickShapes._v2(lp[0]) == b
			if not closes:
				lp.append([b.x, b.y])
			var lo := Vector2i(1 << 30, 1 << 30)
			var hi := -lo
			for q in lp:
				lo = lo.min(BrickShapes._v2(q))
				hi = hi.max(BrickShapes._v2(q))
			change_shape(_last_wall, {"points": {"pts": lp, "closed": closes}, "a": [lo.x, lo.y], "b": [hi.x, hi.y]})
			var id := _last_wall
			if closes:
				_last_wall = -1
			return id
	_last_wall = create(rec)
	return _last_wall


## The bricks a shape will lay, worked out as it would lay them (cached while it does not
## change): [[part, cell], ...].
func _plan_for(rec: Dictionary) -> Array:
	var key := "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [rec.kind, rec.lie, rec.a, rec.b, rec.at, rec.depth,
			rec.get("rim", 1), rec.part, str(rec.get("points", [])).hash()]
	if key == _plan_key:
		return _plan
	_plan_key = key
	_plan = []
	var cells := BrickShapes.shape_cells(rec)
	if cells.size() > 12000:
		return _plan
	var taken := {}
	for c in cells:
		if ws.world.is_solid(ws.asm.frames[0], c):
			taken[c] = true
	var parts := BrickShapes.parts_for(_fill_part(String(rec.part)), ws.palette)
	_plan = BrickShapes.pack_courses(cells, parts, String(rec.bond) != "align", taken, _base_layer(rec))
	return _plan


## What is being made now, as a record (the base's, or the one being pulled), or empty.
func _making() -> Dictionary:
	if _drag.get("phase", "") == "height":
		return _drag.rec
	if _drag.get("phase", "") == "base":
		return _base_record(_drag)
	return {}


## The bricks it will lay, drawn see-through in the held colour.
func _draw_plan() -> void:
	_bim.clear_surfaces()
	var rec := _making()
	if rec.is_empty() or _drag.get("cut", false):
		return
	var plan := _plan_for(rec)
	if plan.is_empty() or plan.size() > 3000:
		return
	var base: Color = WorkshopHotbar.rgb(int(rec.mat), int(rec.colour))
	_bim.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var unit := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
	for pc in plan:
		var size := BrickPalette.size_of(String(pc[0]))
		var lo := Vector3(pc[1]) * unit + Vector3.ONE * 0.012
		var hi := Vector3(pc[1] + size) * unit - Vector3.ONE * 0.012
		_box(lo, hi, base)
	_bim.surface_end()
	_bricks_mi.transform = ws.world.get_chunk_transform(ws.asm.frames[0])


## A box's six faces, shaded a little by which way each looks.
func _box(lo: Vector3, hi: Vector3, col: Color) -> void:
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
			Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	for f in [[4, 5, 6, 7, 1.0], [0, 3, 2, 1, 0.5], [0, 1, 5, 4, 0.8], [2, 3, 7, 6, 0.8], [1, 2, 6, 5, 0.68], [3, 0, 4, 7, 0.68]]:
		var k: float = f[4]
		var shade := Color(col.r * k, col.g * k, col.b * k, 0.5)
		for i in [0, 1, 2, 0, 2, 3]:
			_bim.surface_set_color(shade)
			_bim.surface_add_vertex(c[int(f[i])])


## `c` moved so the segment from `last` runs along X or along Z.
static func _straight(last: Vector2i, c: Vector2i) -> Vector2i:
	var d := c - last
	return Vector2i(c.x, last.y) if absi(d.x) >= absi(d.y) else Vector2i(last.x, c.y)


## A wall line through `_wall_pts`, as one kept shape: the held brick's width, `tall` plates. `closed`: the
## last corner joins the first.
func finish_walls(closed: bool) -> int:
	if _wall_pts.size() < 2:
		say("A wall needs two corners.")
		return -1
	var pts := []
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for c in _wall_pts:
		pts.append([c.x, c.y])
		lo = Vector2i(mini(lo.x, c.x), mini(lo.y, c.y))
		hi = Vector2i(maxi(hi.x, c.x), maxi(hi.y, c.y))
	var sh := _new_shape("polyline", "flat", lo, hi, _wall_at, {"pts": pts, "closed": closed and _wall_pts.size() >= 3})
	sh.rim = held_width()
	sh.depth = tall
	_wall_pts.clear()
	say("")
	return create(sh)


## Floor: the space closed in by walls round `c`'s cell, on its layer -- filled where it is,
## `floor_tall` plates thick, or with `on_top` over the walls' tops out to their outer
## faces. Refused when the walls do not close. Returns the shape's id, or -1.
func floor_at(c: Vector3i, on_top: bool) -> int:
	var sh := floor_record(c, on_top)
	if sh.is_empty():
		return -1
	sh.depth = floor_tall
	return create(sh)


## The floor `floor_at` would lay, not laid (its depth the held brick's height), or empty
## (and why, said) when the walls do not close.
func floor_record(c: Vector3i, on_top: bool) -> Dictionary:
	var f0: int = ws.asm.frames[0]
	if ws._frame != 0 or ws.world.is_solid(f0, c):
		say("Click the floor inside closed walls.")
		return {}
	var region := {}
	var edge := {}
	var todo: Array[Vector2i] = [Vector2i(c.x, c.z)]
	region[todo[0]] = true
	var n: int = ws.plate_studs
	while not todo.is_empty():
		var p: Vector2i = todo.pop_back()
		if p.x <= 0 or p.y <= 0 or p.x >= n - 1 or p.y >= n - 1 or region.size() > 20000:
			say("Those walls do not close: the floor would run out of the plate.")
			return {}
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + d
			if region.has(q) or edge.has(q):
				continue
			if ws.world.is_solid(f0, Vector3i(q.x, c.y, q.y)):
				edge[q] = true
			else:
				region[q] = true
				todo.append(q)
	var at := c.y
	if on_top:
		# Over the walls: their highest top, and out over them -- corners too, which touch
		# the inside only across a diagonal.
		for p in region.keys():
			for d in [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]:
				var q: Vector2i = p + d
				if not region.has(q) and ws.world.is_solid(f0, Vector3i(q.x, c.y, q.y)):
					edge[q] = true
		var top := c.y
		for q in edge:
			var t := c.y
			while t < c.y + 600 and ws.world.is_solid(f0, Vector3i(q.x, t + 1, q.y)):
				t += 1
			top = maxi(top, t)
		at = top + 1
		region.merge(edge)
	var pts := []
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for q in region:
		pts.append([q.x, q.y])
		lo = Vector2i(mini(lo.x, q.x), mini(lo.y, q.y))
		hi = Vector2i(maxi(hi.x, q.x), maxi(hi.y, q.y))
	var sh := _new_shape("cells", "flat", lo, hi, at, pts)
	sh.depth = height_step("flat")
	return sh


## Stairs: the first click the lower floor, the second the upper one.
func _stairs_click() -> void:
	if ws._frame != 0:
		return
	if _stair_from == NO_CELL:
		_stair_from = ws._cell
		say("Now click the upper floor where the stair arrives.")
		return
	stairs_between(_stair_from, ws._cell)


## A straight stair from `lo` (a cell on the lower floor) up to `up` (one on the upper):
## `stair_wide` studs across, a step a brick high. Returns its id, or -1.
func stairs_between(lo: Vector3i, up: Vector3i) -> int:
	_stair_from = NO_CELL
	if up.y <= lo.y + 2:
		say("The second click must be on a higher floor.")
		return -1
	var d := up - lo
	var l := "wall_x" if absi(d.x) >= absi(d.z) else "wall_z"
	var a3 := BrickShapes.from_3d(l, lo)
	var b3 := BrickShapes.from_3d(l, up)
	var sh := _new_shape("stairs", l, Vector2i(a3.x, lo.y), Vector2i(b3.x, up.y - 1), a3.z - ((stair_wide - 1) >> 1))
	sh.depth = stair_wide
	say("")
	return create(sh)


## Roof: on top of a kept shape, its footprint and the overhang round it; the ridge along
## its longer side. Returns the roof's id, or -1.
func roof_on(id: int) -> int:
	var sh := shape_of(id)
	if sh.is_empty():
		return -1
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for c in BrickShapes.solid_cells(sh):
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	var o := roof_overhang
	var r := _new_shape("roof", "flat", Vector2i(lo.x - o, lo.z - o), Vector2i(hi.x + o, hi.z + o), hi.y + 1)
	r.style = roof_style
	r.ridge = "x" if hi.x - lo.x >= hi.z - lo.z else "z"
	r.depth = 1
	selected = -1
	return create(r)


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
	rail.show_toggles({"lock": ws.plane_locked, "snap": ws._snap_on, "mirror": ws.mirror_on,
			"grid": ws._grid_on, "stress": ws._overlay_on, "keys": ws._keys_on})
	rail.set_action_text("layer", ["Structure", "Interior", "Detail"][clampi(ws._role, 0, 2)])
	rail.set_action_text("mirror_axis", "across X" if ws.mirror_axis == 0 else "across Z")
	var vh: float = ws.get_viewport().get_visible_rect().size.y
	rail.fit_height(vh - top - 104.0)
	if _status_left > 0.0:
		_status_left -= ws.get_process_delta_time()
		_status.visible = _status_left > 0.0
	_lay_box.visible = on in ["shape", "sketch"]
	_poly_box.visible = pen.draw == "polygon"
	_walls_box.visible = on == "walls"
	_floor_box.visible = on == "floor"
	_stairs_box.visible = on == "stairs"
	_roof_box.visible = on == "roof"
	_paint_box.visible = on == "paint"
	_paint_spin.set_value_no_signal(ws._paint_radius)
	_builds_box.visible = on == "builds"
	if on == "builds":
		_builds_label.text = ("Click an inserted build." if ws._selected < 0
				else "Picked: %s" % String(ws.recipe.groups[ws._selected].get("name", "a build")))
	_rooms_box.visible = on == "rooms"
	if on == "rooms":
		_rooms_label.text = "next room: %s   point: %s" % [ws._spaces.kind, ws._spaces.point_kind]
	_shape_box.visible = on in ["shape", "sketch", "walls", "floor"]
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
	_lie_pick.visible = on in ["shape", "sketch"]
	_lie_pick.get_parent().get_child(_lie_pick.get_index() - 1).visible = on in ["shape", "sketch"]
	if on == "select" and _shown != Vector2i(selected, _rev):
		_shown = Vector2i(selected, _rev)
		_sync_select()
	# The workshop's readout and the paint palette move over beside the rail.
	var x := _rail_right()
	if ws._hud != null:
		ws._hud.position = Vector2(x, top)
	if ws._paint_palette != null:
		ws._paint_palette.position = Vector2(x, top + 110.0)
	if _drag.get("phase", "") == "height":
		_pull_height()
		ws._ghost.visible = false
	elif not _drag.is_empty():
		_drag.b = _drag_point()
		if _drag.get("tool", "") == "walls" and wall_straight:
			_drag.b = _straight(_drag.a, _drag.b)
		ws._ghost.visible = false
	elif tool in ["cut", "select", "repeat", "pick", "builds", "roof"] or not _sk.is_empty():
		ws._ghost.visible = false
	_draw()


## Where the drag is now, in its plane's cells.
func _drag_point() -> Vector2i:
	var l := String(_drag.lie)
	var q = _plane_point(l, int(_drag.at))
	if q == null:
		return _drag.b
	var b := Vector2i(int(floor(q.x)), int(floor(q.y)))
	if (Input.is_key_pressed(KEY_SHIFT) or keep_round) and String(_drag.kind) in ["circle", "ring", "rect", "hollow"]:
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
	_draw_plan()
	var any := false
	if not _making().is_empty():
		var col := Color(1.0, 0.4, 0.3) if _drag.get("cut", false) else Color(0.4, 0.95, 1.0)
		any = _outline(_making(), col, any)
	elif not _drag.is_empty():
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
	if not _wall_pts.is_empty():
		var q = _plane_point("flat", _wall_at)
		var pts: Array = _wall_pts.duplicate()
		if q != null:
			var c := Vector2i(int(floor(q.x)), int(floor(q.y)))
			pts.append(_straight(_wall_pts.back(), c) if wall_straight else c)
		for i in pts.size() - 1:
			if not any:
				_im.surface_begin(Mesh.PRIMITIVE_LINES)
				any = true
			for p in [pts[i], pts[i + 1]]:
				_im.surface_set_color(Color(0.4, 0.95, 1.0))
				_im.surface_add_vertex(_local("flat", Vector2(p) + Vector2(0.5, 0.5), _wall_at))
	if _stair_from != NO_CELL:
		if not any:
			_im.surface_begin(Mesh.PRIMITIVE_LINES)
			any = true
		var s0 := Vector3(_stair_from) * Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
		for d in [Vector3(BrickPalette.STUD_M, 0, 0), Vector3(0, 0, BrickPalette.STUD_M), Vector3(0, 1.0, 0)]:
			_im.surface_set_color(Color(1.0, 0.85, 0.3))
			_im.surface_add_vertex(s0)
			_im.surface_set_color(Color(1.0, 0.85, 0.3))
			_im.surface_add_vertex(s0 + d)
	if ws.mirror_on:
		if not any:
			_im.surface_begin(Mesh.PRIMITIVE_LINES)
			any = true
		var n := float(ws.plate_studs)
		var h := 20.0 * BrickPalette.STUD_M
		var corners: Array
		if ws.mirror_axis == 0:
			var x: float = ws.mirror_x * BrickPalette.STUD_M
			corners = [Vector3(x, 0, 0), Vector3(x, 0, n * BrickPalette.STUD_M), Vector3(x, h, n * BrickPalette.STUD_M), Vector3(x, h, 0)]
		else:
			var z: float = ws.mirror_z * BrickPalette.STUD_M
			corners = [Vector3(0, 0, z), Vector3(n * BrickPalette.STUD_M, 0, z), Vector3(n * BrickPalette.STUD_M, h, z), Vector3(0, h, z)]
		for k in 4:
			_im.surface_set_color(Color(0.9, 0.5, 1.0, 0.8))
			_im.surface_add_vertex(corners[k])
			_im.surface_set_color(Color(0.9, 0.5, 1.0, 0.8))
			_im.surface_add_vertex(corners[(k + 1) % 4])
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
