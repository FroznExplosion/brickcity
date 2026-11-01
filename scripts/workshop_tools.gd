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
	["hand", "Hand", "B", "Place a brick (click; hold and move lays a run), pick one up (click a brick to hold its part and colour), or paint: the pop-out says which. RMB takes a brick away, R turns it."],
	["draw", "Draw", "K", "Pick an outline and what it makes. Press and drag it on the floor or on a wall, let go; then drag the height and click to place. Right-click or Esc cancels. A wall that meets another at its height joins it."],
	["roof", "Roof", "", "Click a shape (a room's walls): a gable or hip roof of slopes on top of it."],
	["stairs", "Stairs", "", "Click the lower floor, then the upper one: a straight stair between them."],
	["cut", "Cut", "N", "Press on a wall or a floor, drag a shape on it, let go; click to cut right through, or drag first for a depth. The bricks round it are laid again. Door and window: one click, framed."],
	["repeat", "Repeat", "J", "Copy the picked shape -- or a storey, everything between two heights -- N times up, or along X or Z. Click a brick here to pick what to repeat; a door or window repeats with its cut."],
	["select", "Select", "L", "Click a shape or an inserted build to pick it. A shape: drag its top for its height, its side to move it; change its bond or brick, delete it, or let it go. A build: move, copy or delete it."],
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
	]],
	["Edit", [
		["undo", "Undo", "Z", "Take back the last edit: a brick, a run, a shape."],
		["redo", "Redo", "Shift Z", "Lay back what Undo took."],
		["cancel", "Cancel", "Esc", "Drop what is being drawn (a drag, a sketch, a wall line, a stair's first click)."],
	]],
	["View", [
		["fps", "FPS", "Y", "Swap the camera: FPS (the mouse looks, tools work at the dot; hold Alt for the cursor), or orbit (the cursor is free: MMB orbits, Shift MMB pans, the wheel zooms, RMB held looks round).", true],
		["grid", "Grid", "G", "Show the grid.", true],
		["stress", "Stress", "H", "Show how hard each brick is working.", true],
		["keys", "Keys", "F1", "Show every key.", true],
		["guide", "Guide", "U", "Room guide: a room template's size; again for the next."],
	]],
]
## The pop-out's pictures: [id, name, icon].
const OUTLINE_PICS := [["line", "Line", "k_line"], ["box", "Box", "k_rect"], ["circle", "Circle", "k_circle"],
		["triangle", "Triangle", "k_triangle"], ["arch", "Arch", "k_arch"], ["free", "Freehand", "k_free"],
		["brush", "Brush", "k_brush"], ["corners", "Corners", "k_poly"]]
## An outline is a shape on the grid, dragged, or the sketch pen's.
const OUTLINE_KIND := {"line": "line", "box": "rect", "circle": "circle", "triangle": "triangle", "arch": "arch"}
const OUTLINE_PEN := {"free": "outline", "brush": "brush", "corners": "polygon"}
const LIE_PICS := [["flat", "Flat", "l_flat"], ["wall", "Standing", "l_stand"]]
const BOND_PICS := [["stagger", "Staggered", "b_stagger"], ["align", "Aligned", "b_align"]]
const MAKE_PICS := [["solid", "Solid", "m_solid"], ["walls", "Walls", "m_walls"], ["floor", "Floor", "f_here"],
		["building", "Building", "m_building"]]
const CUT_PICS := [["rect", "Box", "k_rect"], ["arch", "Arch", "k_arch"], ["circle", "Circle", "k_circle"],
		["triangle", "Triangle", "k_triangle"], ["outline", "Freehand", "k_free"], ["polygon", "Corners", "k_poly"],
		["door", "Door", "k_door"], ["window", "Window", "k_window"]]
const ROOF_PICS := [["gable", "Gable", "t_gable"], ["hip", "Hip", "t_hip"]]
const FILL_PICS := [["here", "Inside", "f_here"], ["top", "Over walls", "f_top"]]
const BRICK_PICS := [["fill", "Fill gaps"], ["only", "Only this"]]
const THICK_PICS := [["0", "Brick"], ["1", "1"], ["2", "2"], ["3", "3"]]
const HAND_PICS := [["place", "Place", "place"], ["pick", "Pick", "pick"], ["paint", "Paint", "paint"]]
const POPOUT_W := 204.0
## Tools that place: their pop-out leaves the screen to the build while they work.
const POPOUT_HIDES := ["hand", "draw", "roof", "stairs", "cut"]
## A door and a window cut by one click, to start: studs across, plates up; a window's sill
## is where it is clicked, a door stands on the floor of the wall.
const DOOR := Vector2i(4, 18)
const WINDOW := Vector2i(4, 9)
const REPEAT_WHAT := [["shape", "Picked shape"], ["storey", "A storey"]]
const REPEAT_DIRS := [["up", "Up"], ["x", "Along X"], ["z", "Along Z"]]

var ws    ## the workshop (workshop.gd)
var rail: ToolRail
## Hand, Edit and View's buttons, across the screen under the menus.
var _bar: PanelContainer
## The button under the tools for the brick menu.
var bricks_button: Button
## The pop-out is out: it goes when the cursor moves into the scene (POPOUT_HIDES), and comes
## back on the tool's button.
var _fly_open := true
## The numbers beside the cursor, and a height being typed while pulling.
var _tag: Label
var typed := ""
var _hand_row := {}
var _hand_box: VBoxContainer
var _last_hand := "place"
var view: WorkshopView
var tool := "place"

## Shapes options.
## Draw (Docs/BuildTools.md section 11): the outline in hand and what it makes; ticked,
## outlines gather into one plan until it is raised.
var outline := "line"
var makes := "walls"
var combine := false
var kind := "line"
var lie := "flat"
var tall := 3        # plates, flat
var thick := 1       # studs, a wall's depth
var staggered := true
var cut_kind := "rect"
## Every laying tool (section 10): only the held brick, as many as fit -- or smaller ones
## of its kind fill the gaps. A wall's thickness in studs, 0 the held brick's width.
var only_held := false
var wall_thick := 0
var _plan_gaps := 0
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
## Sketch: the pen (the asset workshop's), its brush, and the plane a stroke is on --
## {lie, at} while one is drawn, else empty.
var pen := SketchPen.new()
var brush_size := 1
var brush_square := false
var _sk := {}
## Sketch as a floor plan (section 9): the level drawn on (-1: where you aim), what raising
## it makes, a building's storey (courses of wall) and flat roof; the plan being drawn
## ({at, adds, subs}); the last plan raised. Cut: a window on a building on every floor.
var sketch_level := -1
var storey_courses := 4
var flat_roof := true
var every_floor := true
var _draft := {}
var _last_plan := -1
var _drawon_row := {}
var _outline_row := {}
var _lie_row := {}
var _round_box: CheckBox
var _draft_row: HBoxContainer
var _level_row: HBoxContainer
var _level_spin: SpinBox
var _storey_box: VBoxContainer
var _plan_box: VBoxContainer
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
var _kind_box: VBoxContainer
var _brush_row: Control
var _brush_sq: CheckBox
var _lie_box: VBoxContainer
var _bricks_box: VBoxContainer
var _thick_box: VBoxContainer
var _sel_thick: VBoxContainer
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
## The module's rules on the rooms panel (Docs/RoomModules.md 1).
var _module_on: CheckBox
var _module_role: OptionButton
var _module_storeys: OptionButton
var _module_zone: OptionButton
var _module_min: SpinBox
var _module_max: SpinBox
var _module_weight: SpinBox
## What Generate grows (RoomGrow.PARAMS).
var grow_params := {"seed": 1, "rooms": 10, "path": 3}
var pack_params := {"generator": "pack", "seed": 1, "passes": 4, "section_studs": 32}
var station_params := {"generator": "station", "seed": 1, "modules": 16, "spine": 4, "docks": 2, "bridges": 4}
## What Generate tower sets out (RoomShell.PARAMS).
var shell_params := {"generator": "shell", "seed": 1, "width": 44, "depth": 28, "storeys": 4,
		"setback": 0, "setback_every": 0, "setback_sides": "nsew", "outline": false}
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
	bricks_button = rail.add_under_tools("Bricks   Tab", "place", "Bricks  (Tab)\nOpen or close the menu of every brick.",
			func() -> void: act("parts"))
	_bar = PanelContainer.new()
	_bar.name = "ToolBar"
	_bar.add_theme_stylebox_override("panel", rail.get_theme_stylebox("panel"))
	layer.add_child(_bar)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 3)
	flow.add_theme_constant_override("v_separation", 2)
	_bar.add_child(flow)
	rail.actions(ACTIONS, act, flow)
	_tag = Label.new()
	_tag.name = "CursorTag"
	_tag.add_theme_font_size_override("font_size", 14)
	_tag.add_theme_color_override("font_color", Color(1.0, 0.95, 0.75))
	_tag.add_theme_color_override("font_outline_color", Color.BLACK)
	_tag.add_theme_constant_override("outline_size", 5)
	_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tag.visible = false
	layer.add_child(_tag)
	# The keys panel waits to be asked for: every key has a button now.
	ws._keys_on = false
	if ws._keys_panel != null:
		ws._keys_panel.visible = false
	_build_options()
	view = WorkshopView.new()
	view.setup(ws)
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
	_draft = {}
	_last_plan = -1
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
		"strict": only_held,
		"part": BrickPalette.part_of(ws._archetype_name()), "colour": ws._colour, "mat": ws._mat,
		"role": ws._role, "cuts": [], "bricks": [],
	}
	if (points is Array and not (points as Array).is_empty()) or points is Dictionary:
		sh.points = points
	return sh


## A wall's thickness: as chosen, else the held brick's width.
func wall_rim() -> int:
	return wall_thick if wall_thick > 0 else held_width()


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
	var ops := _every_floor(op, face) if every_floor else [op]
	var b := _building_at(face.cell) if every_floor else {}
	for o in ops:
		_open_into(rec, o)
		if ws.mirror_on:
			var plane: float = ws.mirror_x if ws.mirror_axis == 0 else ws.mirror_z
			var m := BrickShapes.reflected(o, ws.mirror_axis, plane)
			if m != o:
				_open_into(rec, m)
	# Kept with the building, as if on its first storey: new storeys get it.
	if not b.is_empty():
		var pitch := int(b.storey) + maxi(1, int(b.get("floor", 1)))
		var k0 := floori(float(int(opening_box(op)[0].y) - int(b.at)) / pitch)
		var now: Dictionary = shape_of(int(b.id)).duplicate(true)
		var kept: Array = now.get("openings", [])
		kept.append(BrickShapes.shifted(op, Vector3i(0, -k0 * pitch, 0)))
		now.openings = kept
		_store(int(b.id), now)
	_end(rec)
	return op


## The building a face belongs to (a plan with storeys), or empty.
func _building_at(c: Vector3i) -> Dictionary:
	var rid := _rid_at(c)
	if rid < 0:
		return {}
	var sh := shape_of(owner_of(ws.recipe.part_of(rid), ws.recipe.cell_of(rid)))
	if String(sh.get("kind", "")) != "plan" or int(sh.get("storey", 0)) <= 0:
		return {}
	return sh


## A door or a window on a building's wall, at the same place on each of its storeys where
## it fits in that storey's wall; on anything else, just the one.
func _every_floor(op: Dictionary, face: Dictionary) -> Array:
	var b := _building_at(face.cell)
	if b.is_empty():
		return [op]
	var ft := int(b.get("floor", 1))
	var pitch := int(b.storey) + ft
	var at := int(b.at)
	var storeys := floori(float(int(b.depth) - (ft if b.get("roof", false) else 0)) / pitch)
	var box := opening_box(op)
	var k0 := floori(float(int(box[0].y) - at) / pitch)
	var out := []
	for k in storeys:
		var o := BrickShapes.shifted(op, Vector3i(0, (k - k0) * pitch, 0))
		var ob := opening_box(o)
		var wall_lo := at + k * pitch + ft
		var wall_hi := at + (k + 1) * pitch - 1
		if int(ob[0].y) >= wall_lo and int(ob[1].y) <= wall_hi:
			out.append(o)
	return out if not out.is_empty() else [op]


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
		var b := _building_at(face.cell)
		if not b.is_empty():
			# A building's door stands on its storey's floor.
			var ft := int(b.get("floor", 1))
			var pitch := int(b.storey) + ft
			v = int(b.at) + floori(float(uvw.y - int(b.at)) / pitch) * pitch + ft
		else:
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
	var parts := BrickShapes.parts_for(_fill_part(String(sh.part)), ws.palette, bool(sh.get("strict", false)))
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
	var starts := BrickShapes.course_starts(sh, height_step("flat"))
	for pc in BrickShapes.pack_courses(cells, parts, String(sh.bond) != "align", taken, base, starts,
			bool(sh.get("strict", false))):
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
	_fly_open = true
	if id == "hand":
		id = _last_hand
	if id in ["place", "pick", "paint"]:
		_last_hand = id
	cancel()
	if id == "draw" and pen_outline():
		pen.draw = OUTLINE_PEN[outline]
	elif id == "cut" and cut_pen():
		pen.draw = cut_kind
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
		_: say("")


## Drop what is being drawn: a drag, a stroke, a wall line, a stair's first click.
func cancel() -> void:
	_drag = {}
	typed = ""
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
		"fps": view.toggle()
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


## The plan's level a course (the held brick's height) up or down.
func _step_level(d: int) -> void:
	var base := sketch_level if sketch_level >= 0 else int(_draft.get("at", ws._cell.y))
	sketch_level = maxi(0, base + d * height_step("flat"))
	if not _draft.is_empty():
		_draft.at = sketch_level
	_level_spin.set_value_no_signal(sketch_level)
	ToolRail.light(_drawon_row, "level")


## Say something on the rail for a few seconds (a fill refused, the next click wanted).
func say(text: String) -> void:
	_status.text = text
	_status.visible = text != ""
	_status_left = 6.0


## How tall the bar across the top is.
func bar_height() -> float:
	return _bar.size.y + 4.0 if _bar != null else 0.0


## The rail's button for a tool: Place, Pick and Paint are Hand's.
static func rail_id(on: String) -> String:
	return "hand" if on in ["place", "pick", "paint"] else on


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
	rail.pop_out(ws._hud_layer, POPOUT_W)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", Color(1.0, 0.88, 0.5))
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", 5)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.visible = false
	ws._hud_layer.add_child(_status)
	_hand_box = VBoxContainer.new()
	rail.options.add_child(_hand_box)
	_hand_row = rail.pictures(_hand_box, "", HAND_PICS, pick, "place", 3)
	_kind_box = VBoxContainer.new()
	rail.options.add_child(_kind_box)
	_outline_row = rail.pictures(_kind_box, "Outline", OUTLINE_PICS, set_outline, outline, 4)
	rail.pictures(_kind_box, "Makes", MAKE_PICS, func(id: String) -> void: makes = id, makes, 4)
	_lay_box = VBoxContainer.new()
	rail.options.add_child(_lay_box)
	rail.pictures(_lay_box, "", [["lay", "Lay bricks"], ["cut", "Cut out"]],
			func(id: String) -> void: cut_mode = id == "cut", "lay", 2)
	_round_box = CheckBox.new()
	_round_box.text = "keep it square / round (Shift)"
	_round_box.focus_mode = Control.FOCUS_NONE
	_round_box.toggled.connect(func(on: bool) -> void: keep_round = on)
	_lay_box.add_child(_round_box)
	_shape_box = VBoxContainer.new()
	rail.options.add_child(_shape_box)
	_lie_box = VBoxContainer.new()
	_shape_box.add_child(_lie_box)
	_lie_row = rail.pictures(_lie_box, "Lies", LIE_PICS, func(id: String) -> void: lie = id, lie, 2)
	rail.pictures(_shape_box, "Bond", BOND_PICS, func(id: String) -> void: staggered = id == "stagger", "stagger", 2)
	_thick_box = VBoxContainer.new()
	_shape_box.add_child(_thick_box)
	rail.pictures(_thick_box, "Wall thickness (studs)", THICK_PICS, func(id: String) -> void: wall_thick = int(id), "0", 4)
	_bricks_box = VBoxContainer.new()
	_shape_box.add_child(_bricks_box)
	rail.pictures(_bricks_box, "Bricks", BRICK_PICS, func(id: String) -> void: only_held = id == "only", "fill", 2)

	_sketch_box = VBoxContainer.new()
	rail.options.add_child(_sketch_box)
	rail.options.move_child(_sketch_box, _shape_box.get_index())
	_brush_row = _spin(_sketch_box, "brush (studs)", 0, 8, brush_size, func(v: float) -> void: brush_size = int(v)).get_parent()
	_brush_sq = CheckBox.new()
	_brush_sq.text = "square brush"
	_brush_sq.focus_mode = Control.FOCUS_NONE
	_brush_sq.toggled.connect(func(on: bool) -> void: brush_square = on)
	_sketch_box.add_child(_brush_sq)

	_plan_box = VBoxContainer.new()
	_sketch_box.add_child(_plan_box)
	_drawon_row = rail.pictures(_plan_box, "Draw on", [["aim", "Where I aim"], ["level", "A set level"]],
			func(id: String) -> void:
				sketch_level = -1 if id == "aim" else maxi(0, int(_draft.get("at", ws._cell.y)))
				if not _draft.is_empty() and sketch_level >= 0:
					_draft.at = sketch_level
				_level_spin.set_value_no_signal(maxi(0, sketch_level)), "aim", 2)
	_level_row = HBoxContainer.new()
	_plan_box.add_child(_level_row)
	_button(_level_row, "v", func() -> void: _step_level(-1))
	_level_spin = SpinBox.new()
	_level_spin.min_value = 0
	_level_spin.max_value = 4000
	_level_spin.value_changed.connect(func(v: float) -> void:
		sketch_level = int(v)
		if not _draft.is_empty():
			_draft.at = sketch_level)
	_level_row.add_child(_level_spin)
	_button(_level_row, "^", func() -> void: _step_level(1))
	_button(_plan_box, "On top of the last building", func() -> void: plan_on_top(false))
	_button(_plan_box, "... starting from its plan", func() -> void: plan_on_top(true))
	_storey_box = VBoxContainer.new()
	_plan_box.add_child(_storey_box)
	_spin(_storey_box, "storey (courses of wall)", 1, 40, storey_courses, func(v: float) -> void: storey_courses = int(v))
	var fr := CheckBox.new()
	fr.text = "flat roof on top"
	fr.button_pressed = flat_roof
	fr.focus_mode = Control.FOCUS_NONE
	fr.toggled.connect(func(on: bool) -> void: flat_roof = on)
	_storey_box.add_child(fr)
	var cb := CheckBox.new()
	cb.text = "combine outlines into one plan"
	cb.focus_mode = Control.FOCUS_NONE
	cb.toggled.connect(func(on: bool) -> void: combine = on)
	_plan_box.add_child(cb)
	_draft_row = HBoxContainer.new()
	var drow := _draft_row
	_plan_box.add_child(drow)
	_button(drow, "Raise", func() -> void: raise_plan())
	_button(drow, "Take back", func() -> void:
		if not _draft.is_empty():
			var last_sub: bool = not (_draft.subs as Array).is_empty()
			if last_sub:
				(_draft.subs as Array).pop_back()
			elif not (_draft.adds as Array).is_empty():
				(_draft.adds as Array).pop_back()
			if (_draft.adds as Array).is_empty() and (_draft.subs as Array).is_empty():
				_draft = {})
	_button(drow, "Clear", func() -> void: _draft = {})

	_poly_box = HBoxContainer.new()
	rail.options.add_child(_poly_box)
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

	_floor_box = VBoxContainer.new()
	rail.options.add_child(_floor_box)
	rail.pictures(_floor_box, "A click (no drag) fills", FILL_PICS, func(id: String) -> void: floor_on_top = id == "top", "here", 2)

	_stairs_box = VBoxContainer.new()
	rail.options.add_child(_stairs_box)
	_spin(_stairs_box, "wide (studs)", 1, 16, stair_wide, func(v: float) -> void: stair_wide = int(v))

	_roof_box = VBoxContainer.new()
	rail.options.add_child(_roof_box)
	rail.pictures(_roof_box, "Roof", ROOF_PICS, func(id: String) -> void: roof_style = id, roof_style, 2)
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
	_button(_rooms_box, "Point kind (shift P)", func() -> void: ws._spaces.cycle_point_kind())
	# What a click marks, and the module's rules (Docs/RoomModules.md).
	_choice(_rooms_box, "click marks", WorkshopSpaces.MARK_MODES,
			func(i: int) -> void: ws._spaces.mark = WorkshopSpaces.MARK_MODES[i][0])
	_module_on = CheckBox.new()
	_module_on.text = "Module: the generator may use it"
	_module_on.focus_mode = Control.FOCUS_NONE
	_module_on.toggled.connect(func(on: bool) -> void: ws._spaces.set_rule("on", on))
	_rooms_box.add_child(_module_on)
	var roles := WorkshopSpaces.MODULE_ROLES.map(func(r) -> Array: return [r, r])
	_module_role = _choice(_rooms_box, "module is a", roles,
			func(i: int) -> void: ws._spaces.set_rule("role", WorkshopSpaces.MODULE_ROLES[i]))
	var storeys := WorkshopSpaces.MODULE_STOREYS.map(func(r) -> Array: return [r, "storeys: " + r])
	_module_storeys = _choice(_rooms_box, "where", storeys,
			func(i: int) -> void: ws._spaces.set_rule("storeys", WorkshopSpaces.MODULE_STOREYS[i]))
	var zones := WorkshopSpaces.MODULE_ZONES.map(func(r) -> Array: return [r, "in a ship: " + r])
	_module_zone = _choice(_rooms_box, "zone", zones,
			func(i: int) -> void: ws._spaces.set_rule("zone", WorkshopSpaces.MODULE_ZONES[i]))
	_module_min = _spin(_rooms_box, "at least", 0, 99, 0,
			func(v: float) -> void: ws._spaces.set_rule("min", int(v)))
	_module_max = _spin(_rooms_box, "at most (-1 any)", -1, 99, -1,
			func(v: float) -> void: ws._spaces.set_rule("max", int(v)))
	_module_weight = _spin(_rooms_box, "weight", 0, 100, 1,
			func(v: float) -> void: ws._spaces.set_rule("weight", v))
	_module_weight.step = 0.1
	# Grow a building from the saved modules (Docs/RoomModules.md 3).
	var gl := Label.new()
	gl.text = "Grow a building from saved modules:"
	_rooms_box.add_child(gl)
	var seed_spin := _spin(_rooms_box, "seed", 1, 99999, int(grow_params.seed),
			func(v: float) -> void: grow_params.seed = int(v))
	_spin(_rooms_box, "modules", 1, 200, int(grow_params.rooms),
			func(v: float) -> void: grow_params.rooms = int(v))
	_spin(_rooms_box, "path length", 0, 50, int(grow_params.path),
			func(v: float) -> void: grow_params.path = int(v))
	var grow_row := HBoxContainer.new()
	_rooms_box.add_child(grow_row)
	_button(grow_row, "Generate", func() -> void: ws._spaces.generate(grow_params))
	_button(grow_row, "Next seed", func() -> void:
			grow_params.seed = int(grow_params.seed) + 1
			seed_spin.set_value_no_signal(int(grow_params.seed))
			ws._spaces.generate(grow_params))
	# Sections (Docs/RoomModules.md 7.1): the most bricks a part of either has.
	_spin(_rooms_box, "section (most bricks)", 500, 100000, int(grow_params.get("section_bricks", BuildSections.BUDGET)),
			func(v: float) -> void:
				grow_params.section_bricks = int(v)
				shell_params.section_bricks = int(v)
				station_params.section_bricks = int(v))
	# A ship's inside (Docs/RoomModules.md 7.4): the build open is the hull.
	var ptl := Label.new()
	ptl.text = "Fill this build as a ship's hull:"
	_rooms_box.add_child(ptl)
	var pack_seed := _spin(_rooms_box, "seed", 1, 99999, int(pack_params.seed),
			func(v: float) -> void: pack_params.seed = int(v))
	_spin(_rooms_box, "passes (best kept)", 1, 16, int(pack_params.passes),
			func(v: float) -> void: pack_params.passes = int(v))
	_spin(_rooms_box, "bulkhead every (studs)", 12, 200, int(pack_params.section_studs),
			func(v: float) -> void: pack_params.section_studs = int(v))
	var pack_row := HBoxContainer.new()
	_rooms_box.add_child(pack_row)
	_button(pack_row, "Generate interior", func() -> void: ws._spaces.generate(pack_params))
	_button(pack_row, "Next seed", func() -> void:
			pack_params.seed = int(pack_params.seed) + 1
			pack_seed.set_value_no_signal(int(pack_params.seed))
			ws._spaces.generate(pack_params))
	# A station (Docs/RoomModules.md 7.2): grown from a core module, docks, tubes, wings.
	var stl := Label.new()
	stl.text = "Grow a station (modules with station roles):"
	_rooms_box.add_child(stl)
	var station_seed := _spin(_rooms_box, "seed", 1, 99999, int(station_params.seed),
			func(v: float) -> void: station_params.seed = int(v))
	_spin(_rooms_box, "modules", 2, 300, int(station_params.modules),
			func(v: float) -> void: station_params.modules = int(v))
	_spin(_rooms_box, "spine (core to dock)", 0, 40, int(station_params.spine),
			func(v: float) -> void: station_params.spine = int(v))
	_spin(_rooms_box, "docks", 1, 12, int(station_params.docks),
			func(v: float) -> void: station_params.docks = int(v))
	_spin(_rooms_box, "bridging tubes", 0, 40, int(station_params.bridges),
			func(v: float) -> void: station_params.bridges = int(v))
	var station_row := HBoxContainer.new()
	_rooms_box.add_child(station_row)
	_button(station_row, "Generate station", func() -> void: ws._spaces.generate(station_params))
	_button(station_row, "Next seed", func() -> void:
			station_params.seed = int(station_params.seed) + 1
			station_seed.set_value_no_signal(int(station_params.seed))
			ws._spaces.generate(station_params))
	# Set by shell: a tower's box, its inside split and filled (Docs/RoomModules.md 4).
	var tl := Label.new()
	tl.text = "Set a tower by its shell:"
	_rooms_box.add_child(tl)
	var shell_seed := _spin(_rooms_box, "seed", 1, 99999, int(shell_params.seed),
			func(v: float) -> void: shell_params.seed = int(v))
	_spin(_rooms_box, "width (studs)", 18, 400, int(shell_params.width),
			func(v: float) -> void: shell_params.width = int(v))
	_spin(_rooms_box, "depth (studs)", 14, 400, int(shell_params.depth),
			func(v: float) -> void: shell_params.depth = int(v))
	_spin(_rooms_box, "storeys", 1, 60, int(shell_params.storeys),
			func(v: float) -> void: shell_params.storeys = int(v))
	_spin(_rooms_box, "setback (studs in)", 0, 20, int(shell_params.setback),
			func(v: float) -> void: shell_params.setback = int(v))
	_spin(_rooms_box, "every (storeys, 0 none)", 0, 30, int(shell_params.setback_every),
			func(v: float) -> void: shell_params.setback_every = int(v))
	# The sides that step in: north +Z, south -Z, east +X, west -X.
	var sides_row := HBoxContainer.new()
	_rooms_box.add_child(sides_row)
	var sl := Label.new()
	sl.text = "sides in:"
	sides_row.add_child(sl)
	for side in ["n", "s", "e", "w"]:
		var sb := CheckBox.new()
		sb.text = side.to_upper()
		sb.focus_mode = Control.FOCUS_NONE
		sb.button_pressed = String(shell_params.setback_sides).contains(side)
		sb.toggled.connect(func(on: bool) -> void:
				var now := String(shell_params.setback_sides).replace(side, "")
				shell_params.setback_sides = now + side if on else now)
		sides_row.add_child(sb)
	var foot := CheckBox.new()
	foot.text = "this build's outline as the footprint"
	foot.focus_mode = Control.FOCUS_NONE
	foot.toggled.connect(func(on: bool) -> void: shell_params.outline = on)
	_rooms_box.add_child(foot)
	var shell_row := HBoxContainer.new()
	_rooms_box.add_child(shell_row)
	_button(shell_row, "Generate tower", func() -> void: ws._spaces.generate(shell_params))
	_button(shell_row, "Next seed", func() -> void:
			shell_params.seed = int(shell_params.seed) + 1
			shell_seed.set_value_no_signal(int(shell_params.seed))
			ws._spaces.generate(shell_params))

	_cut_box = VBoxContainer.new()
	rail.options.add_child(_cut_box)
	rail.pictures(_cut_box, "Cut", CUT_PICS, func(id: String) -> void:
		cut_kind = id
		if cut_pen():
			pen.draw = id
		pen.points.clear()
		_sk = {}, cut_kind, 4)
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
	var ef := CheckBox.new()
	ef.text = "on every floor of a building"
	ef.button_pressed = every_floor
	ef.focus_mode = Control.FOCUS_NONE
	ef.toggled.connect(func(on: bool) -> void: every_floor = on)
	_cut_box.add_child(ef)
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
	rail.pictures(_repeat_box, "Repeat", REPEAT_WHAT, func(id: String) -> void: rep_what = id, rep_what, 2)
	_rep_lo_spin = _spin(_repeat_box, "storey from (plate)", 0, 2000, rep_lo, func(v: float) -> void: rep_lo = int(v))
	_rep_hi_spin = _spin(_repeat_box, "to (plate)", 0, 2000, rep_hi, func(v: float) -> void: rep_hi = int(v))
	rail.pictures(_repeat_box, "Which way", REPEAT_DIRS, func(id: String) -> void: rep_dir = id, rep_dir, 3)
	_spin(_repeat_box, "times", 1, 50, rep_times, func(v: float) -> void: rep_times = int(v))
	_spin(_repeat_box, "gap (studs, or plates up)", 0, 100, rep_gap, func(v: float) -> void: rep_gap = int(v))
	_button(_repeat_box, "Repeat", func() -> void: repeat(rep_dir, rep_times, rep_gap))

	_select_box = VBoxContainer.new()
	rail.options.add_child(_select_box)
	_select_label = Label.new()
	_select_box.add_child(_select_label)
	_sel_thick = VBoxContainer.new()
	_select_box.add_child(_sel_thick)
	rail.pictures(_sel_thick, "Wall thickness (studs)", THICK_PICS.slice(1), func(id: String) -> void:
		if selected >= 0:
			change_shape(selected, {"rim": int(id)}), "1", 3)
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
		elif c is CheckBox:
			(c as CheckBox).add_theme_font_size_override("font_size", 11)
		elif c is OptionButton:
			(c as OptionButton).add_theme_font_size_override("font_size", 11)
			(c as OptionButton).clip_text = true
			(c as OptionButton).custom_minimum_size.x = 168
		elif c is Button:
			if not (c as Button).has_theme_font_size_override("font_size"):
				(c as Button).add_theme_font_size_override("font_size", 11)
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
	if rail.flyout != null and rail.flyout.visible:
		return rail.flyout.position.x + rail.flyout.size.x + 12.0
	return rail.position.x + rail.size.x + 12.0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## The tools' share of the input. True when it was theirs.
func input(e: InputEvent) -> bool:
	if e is InputEventMouseMotion and not rail.near_mouse(14.0):
		_fly_open = false
	if e is InputEventMouseButton and rail.has_mouse():
		return true
	if e is InputEventMouseButton and _drag.get("phase", "") == "height" \
			and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return _make_input(e)
	if ((tool == "draw" and pen_outline()) or (tool == "cut" and cut_pen())) and _drag.is_empty() and _sketch_input(e):
		return true
	if e is InputEventKey and e.pressed and not e.echo and not e.ctrl_pressed:
		if _drag.get("phase", "") == "height" and _typed_key(e):
			return true
		if e.alt_pressed:
			if e.keycode == KEY_D:
				pick("place" if tool == "draw" else "draw")
				return true
			return false
		match e.keycode:
			KEY_K:
				pick("place" if tool == "draw" else "draw")
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
				if dragging() or _stair_from != NO_CELL or not pen.points.is_empty():
					cancel()
					say("")
					ws.get_viewport().set_input_as_handled()
					return true
				return false   # the pause menu's
			KEY_ENTER, KEY_KP_ENTER:
				if _drag.get("phase", "") == "height":
					commit_pending()
					return true
				if tool == "draw" and not _draft.is_empty():
					raise_plan()
					return true
	if not (e is InputEventMouseButton) or e.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	match tool:
		"draw":
			return _make_input(e)
		"cut":
			return _cut_input(e)
		"select":
			return _select_input(e)
		"repeat":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_repeat_click()
				return true
		"pick":
			if e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				ws._pick_block()
				pick("place")
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
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT:
		# Outside a stroke RMB is the workshop's own; in one it cancels.
		if _sk.is_empty():
			return false
		if e.pressed:
			cancel()
			say("")
		return true
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			if _sk.is_empty():
				if ws._frame != 0:
					return true
				_sk = _stroke_plane()
				if _sk.is_empty():
					return true
			var q = _plane_point(String(_sk.lie), int(_sk.get("plane_at", _sk.at)))
			if q == null:
				return true
			var cutting: bool = cut_mode or tool == "cut"
			if pen.draw == "polygon":
				if pen.polygon_click(q, cutting, e.double_click):
					_sketch_commit()
			else:
				pen.press(q, cutting)
		elif pen.draw != "polygon" and not _sk.is_empty():
			_sketch_commit()
		return true
	if e is InputEventMouseMotion and not _sk.is_empty() and pen.draw != "polygon" \
			and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		var q = _plane_point(String(_sk.lie), int(_sk.get("plane_at", _sk.at)))
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


## The plane a stroke goes on: the face pressed, for a cut or a solid (a wall's side; a cut,
## any face); else the level. Empty: a cut pressed on nothing.
func _stroke_plane() -> Dictionary:
	var cutting: bool = cut_mode or tool == "cut"
	var face := {}
	if cutting or (makes == "solid" and lie == "flat"):
		face = face_under(_ray()[0], _ray()[1])
	if tool == "cut" and face.is_empty():
		say("Press on a wall or a floor of the build.")
		return {}
	if not face.is_empty() and (cutting or String(face.lie) != "flat"):
		var into := int(face.into)
		var sk := {"lie": String(face.lie), "at": int(face.front) if cutting else int(face.front) - into,
				"into": into, "face": face}
		if sk.lie == "flat":
			sk.plane_at = int(face.front) + (1 if into < 0 else 0)
		return sk
	return _plane_at_ghost(lie if makes == "solid" else "flat")


## The stroke drawn: on a level, into the plan being drawn (in, or with RMB out of it); a
## click inside the plan raises it. Standing -- or RMB with no plan -- it goes on to its
## thickness (or depth, cutting) at once, as Shapes.
func _sketch_commit() -> void:
	var sk := _sk
	var entry = pen.entry("top" if sk.lie == "flat" else "side", brush_size, brush_square)
	var remove := pen.out
	var tap: Array = pen.points.duplicate()
	_sk = {}
	pen.points.clear()
	if sk.lie == "flat" and not (remove and _draft.is_empty()) and not sk.has("into"):
		if entry == null or (pen.draw != "brush" and _spread(tap) < 0.6):
			# A click, not a stroke: inside the plan, raise it.
			if not tap.is_empty() and not _draft.is_empty() and BrickShapes.plan_region(_draft).has(
					Vector2i(int(floor(tap[0].x)), int(floor(tap[0].y)))):
				raise_plan()
			return
		if not combine and _draft.is_empty():
			# One outline: on to its height at once.
			var rec := _plan_record({"adds": [entry], "subs": []}, int(sk.at))
			if rec.is_empty():
				return
			_drag = {"phase": "base", "tool": "plan", "button": MOUSE_BUTTON_LEFT, "lie": "flat", "at": int(sk.at),
					"a": BrickShapes._v2(rec.a), "b": BrickShapes._v2(rec.b), "kind": "plan", "cut": false}
			_to_height(rec)
			return
		if _draft.is_empty():
			_draft = {"at": int(sk.at), "adds": [], "subs": []}
		(_draft.subs if remove else _draft.adds).append(entry)
		say("Draw more, or Raise (or click inside the plan) to pull it up.")
		return
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
	if sk.has("into"):
		_drag.into = sk.into
		_drag.face = sk.face
	_to_height(_new_shape("outline", String(sk.lie), lo, hi, int(sk.at), entry))


static func _spread(pts: Array) -> float:
	var d := 0.0
	for q in pts:
		d = maxf(d, (q as Vector2).distance_to(pts[0]))
	return d


## Raise the plan drawn: then its height follows the cursor, and a click places what
## "makes" says -- a solid, walls along its outline, or a building (a floor every storey).
func raise_plan() -> void:
	if _draft.is_empty() or (_draft.adds as Array).is_empty():
		say("Draw the plan first: a box, a circle, an outline...")
		return
	var rec := _plan_record({"adds": (_draft.adds as Array).duplicate(true),
			"subs": (_draft.subs as Array).duplicate(true)}, int(_draft.at))
	if rec.is_empty():
		say("That plan has nothing left in it.")
		return
	_drag = {"phase": "base", "tool": "plan", "button": MOUSE_BUTTON_LEFT, "lie": "flat", "at": int(rec.at),
			"a": BrickShapes._v2(rec.a), "b": BrickShapes._v2(rec.b), "kind": "plan", "cut": false}
	_to_height(rec)


## What strokes and outlines (`points`, {adds, subs}) on a level come to, as "makes" says:
## not laid. Empty if they hold no cells.
func _plan_record(points: Dictionary, at: int) -> Dictionary:
	var region := BrickShapes.plan_region(points)
	if region.is_empty():
		return {}
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for c in region:
		lo = lo.min(c)
		hi = hi.max(c)
	var rec := _new_shape("plan", "flat", lo, hi, at, points)
	rec.fill = makes in ["solid", "floor"]
	rec.rim = wall_rim()
	if makes == "building":
		rec.storey = storey_courses * height_step("flat")
		rec.floor = 1
		rec.roof = flat_roof
		rec.step = int(rec.storey) + 1
		rec.extra = 1 if flat_roof else 0
	return rec


## Pick an outline: a shape on the grid, or the pen.
func set_outline(id: String) -> void:
	outline = id
	if OUTLINE_KIND.has(id):
		kind = OUTLINE_KIND[id]
	else:
		pen.draw = OUTLINE_PEN[id]
	pen.points.clear()
	_sk = {}


func pen_outline() -> bool:
	return OUTLINE_PEN.has(outline)


## Cut with the pen: its Freehand and Corners.
func cut_pen() -> bool:
	return cut_kind in ["outline", "polygon"]


## How a drag in the tool in hand goes: walls joining walls, a floor, a shape, a cut.
func _route() -> String:
	if tool == "cut":
		return "cut"
	if cut_mode:
		return "shape"
	if makes == "floor":
		return "floor"
	if (outline == "line" and makes in ["walls", "building"]) or (outline == "box" and makes == "walls" and not combine):
		return "walls"
	return "shape"


## A dragged outline into the plan being drawn; a click inside the plan raises it.
func _add_outline() -> void:
	var d := _drag
	_drag = {}
	var a: Vector2i = d.a
	var b: Vector2i = d.b
	if a == b:
		if not _draft.is_empty() and BrickShapes.plan_region(_draft).has(a):
			raise_plan()
		return
	if _draft.is_empty():
		_draft = {"at": int(d.at), "adds": [], "subs": []}
	(_draft.subs if d.get("cut", false) else _draft.adds).append(
			{"kind": d.kind, "a": [a.x, a.y], "b": [b.x, b.y], "rim": held_width()})
	say("Draw more, or Raise (or click inside the plan) to pull it up.")


## Draw the next plan on top of the last building (or the picked plan): its level its top;
## `with_plan`, starting from its outline.
func plan_on_top(with_plan: bool) -> void:
	var sh := shape_of(selected) if String(shape_of(selected).get("kind", "")) == "plan" else shape_of(_last_plan)
	if sh.is_empty():
		say("Raise a plan first (or pick one with Select).")
		return
	sketch_level = int(sh.at) + int(sh.depth)
	_draft = {"at": sketch_level, "adds": [], "subs": []}
	if with_plan:
		_draft.adds = (sh.points.adds as Array).duplicate(true)
		_draft.subs = (sh.points.subs as Array).duplicate(true)
	if _level_spin != null:
		_level_spin.set_value_no_signal(sketch_level)
		ToolRail.light(_drawon_row, "level")
	say("On top, at plate %d. Draw%s, then Raise." % [sketch_level, " onto its plan" if with_plan else ""])


## The plane a shape or a stroke starts on: where the ghost is -- flat on its layer, or
## standing through it across the view. {lie, at, a}: `a` the ghost's cell in the plane.
func _plane_at_ghost(want: String) -> Dictionary:
	var c: Vector3i = ws._cell
	var l := "flat"
	if want == "wall":
		var fwd: Vector3 = -ws._camera.global_transform.basis.z
		l = "wall_x" if absf(fwd.z) >= absf(fwd.x) else "wall_z"
	var uvw := BrickShapes.from_3d(l, c)
	var at := uvw.z
	var a := Vector2i(uvw.x, uvw.y)
	if l == "flat":
		# On the plan's level, else the set level, else where you aim.
		at = int(_draft.get("at", sketch_level if sketch_level >= 0 else at))
		var q = _plane_point("flat", at)
		if at != uvw.z and q != null:
			a = Vector2i(int(floor(q.x)), int(floor(q.y)))
	return {"lie": l, "at": at, "a": a}


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
		# Push-pull is a drag: letting go lays it.
		if not e.pressed and e.button_index == MOUSE_BUTTON_LEFT and String(_drag.get("tool", "")) in ["pull", "move"]:
			commit_pending()
		elif e.pressed:
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
		# RMB outside a drawing is the workshop's own: it takes a brick away.
		if e.button_index == MOUSE_BUTTON_RIGHT:
			return false
		var route := _route()
		var cutting: bool = tool == "cut" or cut_mode
		# On a face: a cut goes in from it; a solid, on a wall's side, comes out of it.
		var face := {}
		if cutting or (route == "shape" and makes == "solid" and lie == "flat"):
			face = face_under(_ray()[0], _ray()[1])
		if tool == "cut" and face.is_empty():
			say("Press on a wall or a floor of the build.")
			return true
		if not face.is_empty() and (cutting or String(face.lie) != "flat"):
			_begin_on_face(face, cutting, e.button_index)
			return true
		var pl := _plane_at_ghost(lie if makes == "solid" else "flat")
		var a: Vector2i = pl.a
		if route == "walls":
			a = _wall_snap(a, int(pl.at))
		var k := kind
		if route == "walls" and outline == "line":
			k = "polyline"
		_drag = {"phase": "base", "tool": route, "button": e.button_index, "lie": pl.lie, "at": pl.at,
				"a": a, "b": a, "kind": k, "cut": cutting}
		say("Drag it, then let go." if route != "floor" else "Drag it, or let go here to fill the walls round it.")
		return true
	if _drag.is_empty() or e.button_index != int(_drag.get("button", -1)):
		return true
	if combine and tool == "draw" and String(_drag.tool) != "walls" and (not _drag.get("cut", false) or not _draft.is_empty()):
		_add_outline()
		return true
	_to_height()
	return true


## Draw on a face of the build: a cut's shape, or a shape to come out of a wall.
func _begin_on_face(face: Dictionary, cutting: bool, button: int) -> void:
	var l := String(face.lie)
	var uvw := BrickShapes.from_3d(l, face.cell)
	var a := Vector2i(uvw.x, uvw.y)
	var into := int(face.into)
	var at: int = int(face.front) if cutting else int(face.front) - into
	_drag = {"phase": "base", "tool": tool, "button": button, "lie": l, "at": at, "a": a, "b": a,
			"kind": cut_kind if tool == "cut" else kind, "cut": cutting, "into": into, "face": face}
	# A floor's top: the plane is the top of the layer hit, not its bottom.
	if l == "flat":
		_drag.plane_at = int(face.front) + (1 if into < 0 else 0)
	say("Drag the shape, then let go.")


## The wall ends and lines near `c` on layer `at`: a corner of a wall within two cells, else
## the nearest cell of a wall's straight line within one -- so a wall drawn to meet another
## meets it.
func _wall_snap(c: Vector2i, at: int) -> Vector2i:
	var best := c
	var near := 3
	for sh in shapes():
		if String(sh.kind) != "polyline" or int(sh.at) != at:
			continue
		for line in _wall_lines(sh):
			for q in line:
				var v := BrickShapes._v2(q)
				var d := maxi(absi(v.x - c.x), absi(v.y - c.y))
				if d < near:
					near = d
					best = v
	if near < 3:
		return best
	for sh in shapes():
		if String(sh.kind) != "polyline" or int(sh.at) != at:
			continue
		for line in _wall_lines(sh):
			for i in (line as Array).size() - 1:
				var p := BrickShapes._v2(line[i])
				var r := BrickShapes._v2(line[i + 1])
				if p.x == r.x and absi(c.x - p.x) <= 1 and c.y >= mini(p.y, r.y) and c.y <= maxi(p.y, r.y):
					return Vector2i(p.x, c.y)
				if p.y == r.y and absi(c.y - p.y) <= 1 and c.x >= mini(p.x, r.x) and c.x <= maxi(p.x, r.x):
					return Vector2i(c.x, p.y)
	return c


## A wall shape's lines: its first and each joined one; a closed one comes back to its start.
static func _wall_lines(sh: Dictionary) -> Array:
	var first: Array = (sh.points.pts as Array).duplicate()
	if bool(sh.points.get("closed", false)) and first.size() > 2:
		first.append(first[0])
	return [first] + (sh.points.get("more", []) as Array)


## The kept walls a new wall `rec` touches at its layer, the same brick and bond: if it is
## as tall, it joins them.
func _walls_meeting(rec: Dictionary) -> Array:
	var mine := BrickShapes.cells_2d("polyline", Vector2i.ZERO, Vector2i.ZERO, int(rec.rim), 1.0, rec.points)
	var out := []
	for sh in shapes():
		if String(sh.kind) != "polyline" or int(sh.at) != int(rec.at) or int(sh.rim) != int(rec.rim) \
				or String(sh.part) != String(rec.part) or String(sh.bond) != String(rec.bond) \
				or int(sh.colour) != int(rec.colour) or int(sh.mat) != int(rec.mat):
			continue
		var theirs := BrickShapes.cells_2d("polyline", Vector2i.ZERO, Vector2i.ZERO, int(sh.rim), 1.0, sh.points)
		for c in mine:
			if theirs.has(c) or theirs.has(c + Vector2i(1, 0)) or theirs.has(c - Vector2i(1, 0)) \
					or theirs.has(c + Vector2i(0, 1)) or theirs.has(c - Vector2i(0, 1)):
				out.append(sh)
				break
	return out


## The record the base drawn so far makes (its depth one step), or empty.
func _base_record(d: Dictionary) -> Dictionary:
	if d.has("rec"):
		return d.rec
	var a: Vector2i = d.a
	var b: Vector2i = d.b
	var key := "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [d.tool, d.kind, d.lie, d.at, a, b, ws._archetype_name(), wall_rim(),
			only_held, makes, str(d.get("cut", false))]
	if key == _base_key:
		return _base_rec
	var rec := {}
	match String(d.tool):
		"walls":
			var lo := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
			var hi := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
			var pts := [[a.x, a.y], [b.x, b.y]]
			# A box that makes walls is a room: four walls, closed.
			if d.kind == "rect" and lo.x != hi.x and lo.y != hi.y:
				pts = [[lo.x, lo.y], [hi.x, lo.y], [hi.x, hi.y], [lo.x, hi.y]]
			rec = _new_shape("polyline", "flat", lo, hi, int(d.at), {"pts": pts, "closed": pts.size() > 2})
			rec.rim = wall_rim()
		"floor":
			if a == b:
				rec = floor_record(Vector3i(a.x, int(d.at), a.y), floor_on_top)
			else:
				rec = _new_shape(String(d.kind), "flat", a, b, int(d.at))
		_:
			if d.get("cut", false) or makes == "solid":
				rec = _new_shape(String(d.kind), String(d.lie), a, b, int(d.at))
			else:
				rec = _plan_record({"adds": [{"kind": d.kind, "a": [a.x, a.y], "b": [b.x, b.y],
						"rim": held_width()}], "subs": []}, int(d.at))
	if not rec.is_empty():
		rec.depth = int(rec.get("step", height_step(String(rec.lie)))) + int(rec.get("extra", 0))
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
	rec.depth = int(rec.get("step", height_step(String(rec.lie)))) + int(rec.get("extra", 0))
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
	if _drag.has("into"):
		var into := int(_drag.into)
		if _drag.get("cut", false):
			# In from the face; to start with, right through.
			var face: Dictionary = _drag.face
			rec.at = int(face.at)
			rec.depth = int(face.depth)
			_drag.at0 = int(face.front)
			_drag.anchor = _local(l, (lo + hi) * 0.5, float(int(face.front) + (0 if into > 0 else 1)))
			_drag.through = true
			_drag.from_dir = _ray()[1]
			typed = ""
			say("Click now to cut right through, or drag (or type) a depth first.")
			return
		_drag.anchor = _local(l, (lo + hi) * 0.5, float(int(rec.at) + (1 if into > 0 else 0)))
	typed = ""
	say("Move the cursor for the height (or type it); click to place. Right-click or Esc cancels.")
	if String(rec.kind) == "polyline":
		var meet := _walls_meeting(rec)
		if not meet.is_empty():
			rec.depth = int(meet[0].depth)
			_drag.stick = int(meet[0].depth)


## The height under the cursor: where the ray passes closest to the line straight up (or,
## standing, straight out) from the base's middle, in steps of the held brick.
func _pull_height() -> void:
	var rec: Dictionary = _drag.rec
	var l := String(rec.lie)
	var axis := Vector3.UP if l == "flat" else (Vector3.BACK if l == "wall_x" else Vector3.RIGHT)
	var unit := BrickPalette.PLATE_M if l == "flat" else BrickPalette.STUD_M
	var ray := _ray()
	# Only when the cursor (or the view) moved, and nothing is typed: a height set stays set.
	if _drag.get("last_ray") == ray or typed != "":
		return
	_drag.last_ray = ray
	var xf: Transform3D = ws.world.get_chunk_transform(ws.asm.frames[0])
	var from: Vector3 = xf.affine_inverse() * (ray[0] as Vector3)
	var dir: Vector3 = (xf.basis.inverse() * (ray[1] as Vector3)).normalized()
	if _drag.get("tool", "") == "move":
		axis = Vector3.ZERO
		axis[int(_drag.axis)] = 1.0
		unit = BrickPalette.STUD_M
	var w0: Vector3 = (_drag.anchor as Vector3) - from
	var b := axis.dot(dir)
	var den := 1.0 - b * b
	if absf(den) < 1e-6:
		return
	var along := (b * dir.dot(w0) - axis.dot(w0)) / den
	if _drag.get("tool", "") == "move":
		var by := Vector3i.ZERO
		by[int(_drag.axis)] = int(round(along / unit))
		_drag.by = by
		_drag.rec = BrickShapes.shifted(_drag.orig, by)
		return
	var step := int(rec.get("step", height_step(l)))
	var n := int(round(along / unit / step)) * step
	if _drag.get("cut", false) and _drag.has("into"):
		# A cut: right through until the cursor moves, then as deep as it is dragged.
		if bool(_drag.through):
			if dir.dot(_drag.from_dir) > 0.9997:
				return
			_drag.through = false
		var into := int(_drag.into)
		var d := clampi(int(round(along / unit)) * into, 1, 64)
		rec.depth = d
		rec.at = int(_drag.at0) if into > 0 else int(_drag.at0) - d + 1
		return
	if _drag.has("into"):
		# A shape coming out of a wall's face.
		var out_d := maxi(1, int(round(along / unit)) * -int(_drag.into))
		rec.depth = out_d
		rec.at = int(_drag.at0) if int(_drag.into) < 0 else int(_drag.at0) - out_d + 1
		return
	if l == "flat":
		rec.depth = maxi(step, n) + int(rec.get("extra", 0))
		rec.at = int(_drag.at0)
		# Walls stick to the height of the wall they meet, so they join it.
		if _drag.has("stick") and absi(int(rec.depth) - int(_drag.stick)) <= step:
			rec.depth = int(_drag.stick)
	else:
		# Standing: pulled toward you or away, its thickness.
		rec.depth = maxi(1, absi(n))
		rec.at = int(_drag.at0) if n >= 0 else int(_drag.at0) - rec.depth + 1


## Place what is being made, at the height pulled. Returns its id (or -1: a cut, nothing).
func commit_pending() -> int:
	if _drag.get("phase", "") != "height":
		if _drag.get("phase", "") == "base":
			_to_height()
		else:
			return -1
	var d := _drag
	_drag = {}
	_base_key = ""
	typed = ""
	var rec: Dictionary = d.rec
	say("")
	if String(d.get("tool", "")) == "pull":
		resize_shape(int(rec.id), int(rec.depth))
		return int(rec.id)
	if String(d.get("tool", "")) == "move":
		move_shape(int(rec.id), d.get("by", Vector3i.ZERO))
		return int(rec.id)
	if d.get("cut", false):
		var cut := {}
		for k in ["kind", "lie", "a", "b", "at", "depth", "rim", "points"]:
			if rec.has(k):
				cut[k] = rec[k]
		apply_cut(cut)
		return -1
	if String(rec.kind) == "polyline":
		return _commit_wall(rec)
	if String(rec.kind) == "plan":
		rec.erase("step")
		rec.erase("extra")
		_last_plan = create(rec)
		_draft = {}
		return _last_plan
	return create(rec)


## A wall: one that meets others at their height (a corner, a T) joins them -- one shape,
## laid again whole, so the courses interlock.
func _commit_wall(rec: Dictionary) -> int:
	if ws.mirror_on:
		return create(rec)
	var meet := _walls_meeting(rec).filter(func(sh: Dictionary) -> bool: return int(sh.depth) == int(rec.depth))
	if meet.is_empty():
		return create(rec)
	var first: Dictionary = meet[0]
	var joined: Dictionary = first.duplicate(true)
	var more: Array = joined.points.get("more", [])
	more.append_array(_wall_lines(rec))
	var u := _begin()
	u.before[int(first.id)] = first
	_take_up(first)
	for i in range(1, meet.size()):
		var o: Dictionary = meet[i]
		more.append_array(_wall_lines(o))
		u.before[int(o.id)] = o
		_take_up(o)
		_store(int(o.id), {})
	joined.points.more = more
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for line in _wall_lines(joined):
		for q in line:
			lo = lo.min(BrickShapes._v2(q))
			hi = hi.max(BrickShapes._v2(q))
	joined.a = [lo.x, lo.y]
	joined.b = [hi.x, hi.y]
	joined.bricks = []
	_lay(joined)
	_end(u)
	return int(first.id)


## The bricks a shape will lay, worked out as it would lay them (cached while it does not
## change): [[part, cell], ...].
func _plan_for(rec: Dictionary) -> Array:
	var key := "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [rec.kind, rec.lie, rec.a, rec.b, rec.at, rec.depth,
			rec.get("rim", 1), rec.part, str(rec.get("points", [])).hash(), rec.get("fill", false),
			rec.get("storey", 0), rec.get("roof", false), rec.get("strict", false)]
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
	var strict := bool(rec.get("strict", false))
	var parts := BrickShapes.parts_for(_fill_part(String(rec.part)), ws.palette, strict)
	_plan = BrickShapes.pack_courses(cells, parts, String(rec.bond) != "align", taken, _base_layer(rec),
			BrickShapes.course_starts(rec, height_step("flat")), strict)
	var covered := 0
	for pc in _plan:
		var size := BrickPalette.size_of(String(pc[0]))
		covered += size.x * size.y * size.z
	_plan_gaps = cells.size() - taken.size() - covered
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
	sh.rim = wall_rim()
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


## Cut: a door or a window is one click; any other shape is drawn on the face pressed, then
## dragged in for a depth (the same way as everything else: `_make_input`).
func _cut_input(e: InputEventMouseButton) -> bool:
	if _drag.is_empty() and e.button_index == MOUSE_BUTTON_LEFT and e.pressed and cut_kind in ["door", "window"]:
		var face := face_under(_ray()[0], _ray()[1])
		if face.is_empty():
			say("Press on a wall of the build.")
		else:
			apply_opening(cut_kind, face)
		return true
	if cut_kind in ["door", "window"] and _drag.is_empty():
		return e.button_index == MOUSE_BUTTON_LEFT
	return _make_input(e)


## The face of the build under a ray: {cell, lie, at, depth, front, into} -- the cell hit,
## the plane of the face (a side facing Z is wall_x, facing X wall_z, a top or bottom flat),
## how deep the build is behind it there (`at` its lowest layer): a cut goes that far in,
## through the wall and no further; `front` the layer the face is on, `into` +1 or -1 the
## way in. Empty if the ray hits nothing of the upright grid.
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
	return {"cell": c, "lie": l, "at": mini(first, last), "depth": maxi(1, depth), "front": first,
			"into": step[axis]}


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
		var b := _building_at(face.cell)
		if not b.is_empty():
			# A building's door stands on its storey's floor.
			var ft := int(b.get("floor", 1))
			var pitch := int(b.storey) + ft
			v = int(b.at) + floori(float(uvw.y - int(b.at)) / pitch) * pitch + ft
		else:
			# Down while there is wall (the build's own bricks: not the baseplate).
			while v > 0 and _rid_at(BrickShapes.to_3d(l, Vector2i(uvw.x, v - 1), uvw.z)) >= 0:
				v -= 1
		v0 = v
	return {"kind": "rect", "lie": l, "a": [u0, v0], "b": [u0 + size.x - 1, v0 + size.y - 1],
			"at": face.at, "depth": face.depth}


## Select: a click picks; pressed on a picked shape's top and dragged, its height follows;
## on its side, the whole shape moves along that face's way. Letting go lays it.
func _select_input(e: InputEventMouseButton) -> bool:
	if e.button_index != MOUSE_BUTTON_LEFT:
		return false
	if not e.pressed:
		return true
	_select_click()
	var sh := shape_of(selected)
	if sh.is_empty():
		return true
	var face := face_under(_ray()[0], _ray()[1])
	if not face.is_empty():
		begin_push_pull(sh, face)
	return true


## Start dragging a shape by the face pressed: its top (a flat shape): the height; a
## side: the shape moves. Anything else, nothing.
func begin_push_pull(sh: Dictionary, face: Dictionary) -> void:
	var c: Vector3i = face.cell
	var cell := Vector2(c.x + 0.5, c.z + 0.5)
	var base := {"phase": "height", "button": MOUSE_BUTTON_LEFT, "lie": sh.lie, "at": sh.at, "a": BrickShapes._v2(sh.a),
			"b": BrickShapes._v2(sh.b), "kind": sh.kind, "cut": false, "at0": int(sh.at)}
	if String(face.lie) == "flat":
		if String(sh.lie) != "flat" or int(face.into) > 0 or c.y != int(sh.at) + int(sh.depth) - 1:
			return
		var rec: Dictionary = sh.duplicate(true)
		rec.bricks = []
		if int(sh.get("storey", 0)) > 0:
			rec.step = int(sh.storey) + maxi(1, int(sh.get("floor", 1)))
			rec.extra = maxi(1, int(sh.get("floor", 1))) if sh.get("roof", false) else 0
		else:
			rec.step = maxi(1, BrickPalette.part_size(BrickPalette.part_of(_fill_part(String(sh.part)))).y)
		_drag = base
		_drag.tool = "pull"
		_drag.rec = rec
		_drag.anchor = _local("flat", cell, float(sh.at))
		say("Drag the height (or type it), let go to lay it. Right-click or Esc cancels.")
		return
	var axis := 2 if String(face.lie) == "wall_x" else 0
	_drag = base
	_drag.tool = "move"
	_drag.rec = BrickShapes.shifted(sh, Vector3i.ZERO)
	_drag.orig = sh
	_drag.axis = axis
	_drag.anchor = Vector3(c) * Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M) \
			+ Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M) * 0.5
	say("Drag to move it, let go to lay it. Right-click or Esc cancels.")


## A shape's new height: its bricks laid again; a building's kept doors and windows put on
## the storeys it gained, and taken off those it lost. One undo.
func resize_shape(id: int, depth: int) -> void:
	var old := shape_of(id)
	if old.is_empty() or int(old.depth) == depth:
		return
	var u := _begin()
	u.before[id] = old
	_take_up(old)
	var sh: Dictionary = old.duplicate(true)
	sh.depth = depth
	sh.bricks = []
	_lay(sh)
	var ops: Array = old.get("openings", [])
	if int(old.get("storey", 0)) > 0 and not ops.is_empty():
		var pitch := int(old.storey) + maxi(1, int(old.get("floor", 1)))
		var was := storeys_of(old)
		var now := storeys_of(sh)
		for k in range(was, now):
			for op in ops:
				_open_into(u, BrickShapes.shifted(op, Vector3i(0, k * pitch, 0)))
		if now < was:
			var top := int(old.at) + depth
			for o in shapes().duplicate():
				if o.has("opening") and int(opening_box(o.opening)[0].y) >= top:
					u.before[int(o.id)] = o
					_take_up(o)
					_store(int(o.id), {})
	_end(u)


## Move a shape by `d` cells, with the frames and glass of the doors and windows cut in it.
## One undo.
func move_shape(id: int, d: Vector3i) -> void:
	var old := shape_of(id)
	if old.is_empty() or d == Vector3i.ZERO:
		return
	var moving := [old]
	for cut in old.get("cuts", []):
		for o in shapes():
			if not o.has("opening"):
				continue
			var box := opening_box(o.opening)
			if BrickShapes._v2(cut.a) == box[0] and BrickShapes._v2(cut.b) == box[1] and int(cut.at) == int(o.opening.at):
				moving.append(o)
	var u := _begin()
	for o in moving:
		u.before[int(o.id)] = o
		_take_up(o)
	for o in moving:
		_lay(BrickShapes.shifted(o, d))
	_end(u)


func _select_click() -> void:
	var ray := _ray()
	var hit: Dictionary = ws._first_hit(ray[0], ray[1])
	selected = -1
	if hit.is_empty() or hit.frame != ws.asm.frames[0]:
		return
	var rid: int = ws._recipe_id_at(0, hit.block)
	if rid >= 0:
		selected = owner_of(ws.recipe.part_of(rid), ws.recipe.cell_of(rid))
	# Not a shape: an inserted build, if it is one of those.
	if selected < 0:
		ws.select_group_ray(ray[0], ray[1])
	else:
		ws._select_group(-1)


func _sync_select() -> void:
	var sh := shape_of(selected)
	_syncing = true
	if sh.is_empty():
		_select_label.text = "Click a shape or an inserted build."
	else:
		var names := {}
		for k in BrickShapes.KINDS:
			names[k[0]] = k[1]
		_select_label.text = "%s, %s, %d bricks of %s%s" % [names.get(sh.kind, sh.kind),
				"flat" if sh.lie == "flat" else "a wall", (sh.bricks as Array).size(), sh.part,
				"" if (sh.cuts as Array).is_empty() else ", %d cut%s" % [(sh.cuts as Array).size(),
				"" if (sh.cuts as Array).size() == 1 else "s"]]
		_sel_bond.select(0 if sh.bond != "align" else 1)
	_syncing = false


# ---------------------------------------------------------------------------
# Each frame
# ---------------------------------------------------------------------------

func process() -> void:
	view.sync()
	var menu_h: float = ws._menu.bar_height() if ws._menu != null else 0.0
	var vw: float = ws.get_viewport().get_visible_rect().size.x
	_bar.position = Vector2(8, menu_h + 4.0)
	_bar.custom_minimum_size.x = vw - 16.0
	_bar.size = Vector2(vw - 16.0, 0.0)
	var top: float = 8.0 + menu_h + bar_height()
	rail.position = Vector2(12, top)
	rail.size = Vector2.ZERO
	var on := active()
	rail.show_active(rail_id(on), TOOLS)
	_hand_box.visible = rail_id(on) == "hand"
	ToolRail.light(_hand_row, on)
	rail.show_toggles({"lock": ws.plane_locked, "snap": ws._snap_on, "mirror": ws.mirror_on,
			"grid": ws._grid_on, "stress": ws._overlay_on, "keys": ws._keys_on, "fps": view.mode == "fps"})
	rail.set_action_text("layer", ["Structure", "Interior", "Detail"][clampi(ws._role, 0, 2)])
	rail.set_action_text("mirror_axis", "across X" if ws.mirror_axis == 0 else "across Z")
	var vh: float = ws.get_viewport().get_visible_rect().size.y
	rail.fit_height(vh - top - 104.0)
	if _status_left > 0.0:
		_status_left -= ws.get_process_delta_time()
		_status.visible = _status_left > 0.0 and _status.text != ""
	if _status.visible:
		_status.reset_size()
		_status.position = Vector2((vw - _status.size.x) * 0.5, vh - 128.0)
	var drawing := on == "draw"
	_lay_box.visible = drawing
	_round_box.visible = outline in ["box", "circle"]
	_poly_box.visible = (drawing and outline == "corners") or (on == "cut" and cut_kind == "polygon")
	_walls_box.visible = drawing and outline == "line" and makes in ["walls", "building"]
	_floor_box.visible = drawing and makes == "floor"
	_stairs_box.visible = on == "stairs"
	_roof_box.visible = on == "roof"
	_paint_box.visible = on == "paint"
	_paint_spin.set_value_no_signal(ws._paint_radius)
	_builds_box.visible = on == "select" and ws._selected >= 0
	if _builds_box.visible:
		_builds_label.text = "Picked: %s" % String(ws.recipe.groups[ws._selected].get("name", "a build"))
	_rooms_box.visible = on == "rooms"
	if on == "rooms":
		_rooms_label.text = "next room: %s   point: %s" % [ws._spaces.kind, ws._spaces.point_kind]
		# The loaded build's module rules, without setting them.
		var mod: Dictionary = ws.recipe.meta.get("module", {})
		_module_on.set_pressed_no_signal(bool(mod.get("on", false)))
		_module_role.select(maxi(WorkshopSpaces.MODULE_ROLES.find(String(mod.get("role", "room"))), 0))
		_module_storeys.select(maxi(WorkshopSpaces.MODULE_STOREYS.find(String(mod.get("storeys", "any"))), 0))
		_module_zone.select(maxi(WorkshopSpaces.MODULE_ZONES.find(String(mod.get("zone", "any"))), 0))
		_module_min.set_value_no_signal(int(mod.get("min", 0)))
		_module_max.set_value_no_signal(int(mod.get("max", -1)))
		_module_weight.set_value_no_signal(float(mod.get("weight", 1.0)))
	_shape_box.visible = drawing or on in ["stairs", "roof"]
	_sketch_box.visible = drawing
	_plan_box.visible = lie == "flat" or makes != "solid"
	_level_row.visible = sketch_level >= 0
	_storey_box.visible = makes == "building"
	_draft_row.visible = combine or not _draft.is_empty()
	_kind_box.visible = drawing
	_brush_row.visible = outline == "brush"
	_brush_sq.visible = outline == "brush"
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
	_select_box.visible = on == "select" and ws._selected < 0
	_sel_thick.visible = String(shape_of(selected).get("kind", "")) in ["polyline", "plan"]
	_lie_box.visible = drawing and makes == "solid"
	_thick_box.visible = drawing and makes in ["walls", "building"]
	_bricks_box.visible = true
	if on == "select" and _shown != Vector2i(selected, _rev):
		_shown = Vector2i(selected, _rev)
		_sync_select()
	# The tool's pop-out beside its button; the readout and the paint palette beside that.
	var rid := rail_id(on)
	var bt: Button = rail.buttons.get(rid)
	if bt != null and bt.is_hovered():
		_fly_open = true
	var show_fly := _fly_open or not (rid in POPOUT_HIDES)
	if dragging() or (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and rid in POPOUT_HIDES):
		show_fly = false
	rail.place_flyout(bt.global_position.y if bt != null else top, vh - 100.0, show_fly)
	if not show_fly and rid in POPOUT_HIDES and rail.hint != null:
		rail.hint.text += "  (Point at the tool for its options.)"
	bricks_button.set_pressed_no_signal(ws._hotbar.is_browsing())
	# The readout stays put; the pop-out comes and goes over it. The paint palette is beside it.
	if ws._hud != null:
		ws._hud.position = Vector2(rail.position.x + rail.size.x + 12.0, top)
	if ws._paint_palette != null:
		ws._paint_palette.position = Vector2(_rail_right(), top + 110.0)
	var said := tag_text() if not _drag.is_empty() else ""
	_tag.visible = said != ""
	if said != "":
		_tag.text = said
		var at: Vector2 = ws.get_viewport().get_mouse_position() + Vector2(18, 14)
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			at = ws.get_viewport().get_visible_rect().size * 0.5 + Vector2(18, 14)
		_tag.position = at
	if _drag.get("phase", "") == "height":
		_pull_height()
		ws._ghost.visible = false
	elif not _drag.is_empty():
		_drag.b = _drag_point()
		if _drag.get("tool", "") == "walls":
			_drag.b = _wall_snap(_drag.b, int(_drag.at))
			if wall_straight and String(_drag.kind) == "polyline":
				_drag.b = _straight(_drag.a, _drag.b)
		ws._ghost.visible = false
	elif tool in ["cut", "select", "repeat", "pick", "roof"] or not _sk.is_empty():
		ws._ghost.visible = false
	_draw()


## The numbers beside the cursor: the size of a base being dragged, the height being pulled
## (or typed). "" for nothing.
func tag_text() -> String:
	var rec := _making()
	if rec.is_empty():
		return ""
	var l := String(rec.lie)
	if String(_drag.get("tool", "")) == "move":
		var by: Vector3i = _drag.get("by", Vector3i.ZERO)
		var far := absi(by.x) + absi(by.z)
		return "%d stud%s" % [far, "" if far == 1 else "s"]
	if _drag.get("phase", "") == "base":
		var a := BrickShapes._v2(rec.a)
		var b := BrickShapes._v2(rec.b)
		var w := absi(b.x - a.x) + 1
		var h := absi(b.y - a.y) + 1
		if String(rec.kind) == "polyline" and not bool(rec.points.get("closed", false)):
			return "%d stud%s" % [maxi(w, h), "" if maxi(w, h) == 1 else "s"]
		return "%d x %d %s" % [w, h, "studs" if l == "flat" else "(studs, plates)"]
	var head := ""
	if int(rec.get("storey", 0)) > 0:
		var n := storeys_of(rec)
		head = "%d storey%s" % [n, "" if n == 1 else "s"]
	elif _drag.has("into"):
		head = "%d %s %s" % [rec.depth, "stud" if l != "flat" else "plate", "deep" if _drag.get("cut", false) else "out"]
	elif l == "flat":
		head = "%d plates" % int(rec.depth)
		var c := height_step("flat")
		if c > 1:
			head += " (%d courses)" % floori(float(int(rec.depth)) / c)
	else:
		head = "%d studs thick" % int(rec.depth)
	if typed != "":
		head = "typing: %s   %s" % [typed, head]
	if rec.get("strict", false) and _plan_gaps > 0:
		head += "   %d cells empty" % _plan_gaps
	return head


## How many storeys a building's depth is.
static func storeys_of(rec: Dictionary) -> int:
	var ft := maxi(1, int(rec.get("floor", 1)))
	var pitch := int(rec.storey) + ft
	return floori(float(int(rec.depth) - (ft if rec.get("roof", false) else 0)) / pitch)


## While pulling: a digit types the height (plates; storeys for a building; studs for a depth
## or a thickness), Backspace takes one back. True if the key was this.
func _typed_key(e: InputEventKey) -> bool:
	var d := -1
	if e.keycode >= KEY_0 and e.keycode <= KEY_9:
		d = e.keycode - KEY_0
	elif e.keycode >= KEY_KP_0 and e.keycode <= KEY_KP_9:
		d = e.keycode - KEY_KP_0
	if d >= 0:
		typed += str(d)
	elif e.keycode == KEY_BACKSPACE and typed != "":
		typed = typed.substr(0, typed.length() - 1)
	else:
		return false
	apply_typed()
	return true


## The typed number as the height.
func apply_typed() -> void:
	if typed == "" or _drag.get("phase", "") != "height":
		return
	var rec: Dictionary = _drag.rec
	var n := maxi(1, typed.to_int())
	if int(rec.get("storey", 0)) > 0:
		rec.depth = n * int(rec.step) + int(rec.get("extra", 0))
		return
	rec.depth = n + int(rec.get("extra", 0))
	if _drag.has("into"):
		var into := int(_drag.into)
		var out := -into if not _drag.get("cut", false) else into
		rec.at = int(_drag.at0) if out > 0 else int(_drag.at0) - n + 1
		_drag.through = false


## Where the drag is now, in its plane's cells.
func _drag_point() -> Vector2i:
	var l := String(_drag.lie)
	var q = _plane_point(l, int(_drag.get("plane_at", _drag.at)))
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
	# A set level's grid, and a plan being drawn; aiming, the workshop's own grid says it.
	if tool == "draw" and (sketch_level >= 0 or not _draft.is_empty()):
		any = _draw_level(any)
	if tool in ["select", "repeat"] and selected >= 0:
		var sh := shape_of(selected)
		if not sh.is_empty():
			any = _outline(sh, Color(1.0, 0.85, 0.3), any)
			for cut in sh.cuts:
				any = _outline(cut, Color(1.0, 0.4, 0.3), any)
	if any:
		_im.surface_end()
	_lines.transform = ws.world.get_chunk_transform(ws.asm.frames[0])


## Sketch on a level: that level's grid, faint, and the plan drawn so far.
func _draw_level(begun: bool) -> bool:
	var at := int(_draft.get("at", sketch_level if sketch_level >= 0 else int(ws._cell.y)))
	if not begun:
		_im.surface_begin(Mesh.PRIMITIVE_LINES)
	var n := float(ws.plate_studs)
	var y := at * BrickPalette.PLATE_M + 0.004
	var col := Color(0.55, 0.75, 1.0, 0.22)
	for i in int(n) + 1:
		var t := i * BrickPalette.STUD_M
		for seg in [[Vector3(t, y, 0), Vector3(t, y, n * BrickPalette.STUD_M)],
				[Vector3(0, y, t), Vector3(n * BrickPalette.STUD_M, y, t)]]:
			_im.surface_set_color(col)
			_im.surface_add_vertex(seg[0])
			_im.surface_set_color(col)
			_im.surface_add_vertex(seg[1])
	if not _draft.is_empty():
		_outline({"kind": "plan", "lie": "flat", "a": [0, 0], "b": [0, 0], "at": at, "depth": 1,
				"points": _draft}, Color(1.0, 1.0, 0.6), true)
	return true


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
