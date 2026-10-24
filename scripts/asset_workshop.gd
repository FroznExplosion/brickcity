extends "res://scripts/workshop.gd"
## The asset workshop: the workshop, with tools for blocking out assets -- guns first --
## against a photo. Docs/AssetWorkshop.md.
##
##     godot --path . res://scenes/asset_workshop.tscn
##
## Everything the workshop does works here unchanged. Phase 1 adds:
##
##   the ruler   the ghost's cell and the build's size, in studs and plates and in
##               print mm and real mm
##   photos      F2: a reference picture on a plane behind the build -- side, top or
##               front -- calibrated by two clicks and the real length between them
##   flat views  F6: perspective, side, top, front in turn; Home / End zoom a flat view
##   measure     F7: two clicks, the distance between them in all four units
##   mirror      F8: every brick placed is placed again, mirrored across the plane down
##               the middle of the build; shift F8 puts the plane under the ghost
##
## Phase 2 adds:
##
##   part toolbars  Y (shift Y back): a toolbar for each part of the asset -- body, barrel,
##                  stock ... -- with its own nine slots. Every brick placed is tagged
##                  with the part whose toolbar it came from, so the split lines are built
##                  in as the asset is
##   drag to lay    hold LMB and move: the brick is laid again wherever the ghost goes on
##                  the plane of the first one -- a line, a wall, a floor
##   connections    J: a mount or a socket for the current part, its slot and interface,
##                  on the lattice under the ghost; J on one already there takes it away
##
## Phase 3 adds:
##
##   shapes      K: drag a box, cylinder, sphere or wedge out on the ghost's plane; it is
##               filled with bricks, clean (fewest) or random (mixed sizes)
##   select      L: drag a box over the build; delete it, re-pack it, give it to the
##               current part, copy or move it to the ghost
##   guides      F3: a model (glTF, FBX) on a locked see-through layer, scaled to a real
##               length, to build inside. Never exported
##   section     O, in a flat view: cut away what is nearer than the mirror plane (side),
##               above the ghost (top) or past it (front)
##   outlines    P: every brick outlined in its part's colour; again, the current part only
##
## Phase 4 adds:
##
##   smooth      N: the current part becomes a smooth custom piece on export -- its brick
##               outline lofted -- or goes back to bricks
##   wand        F4, then click a photo: the patch of the photo's colour under the click,
##               filled with bricks for the current part, so many studs across
##   export      F12: the build sheet, the part kit run on it, and its picture shown here
##   undo, redo  Z undoes a whole fill, copy or mirrored pair at once; shift Z redoes
##   readout     the ruler adds each part's bricks and the asset's length in the game
##
## After the first use (2026-10-15):
##
##   keys        nothing on F5-F8: run from the Godot editor, those are the editor's (F8
##               stopped the game and lost a build). Views, measure and mirror moved to
##               Alt chords, and the build is autosaved every few seconds
##   free place  on by default (Alt F): the ghost goes where the cursor meets the working
##               plane -- the side plane at a depth, the top plane at a height, the front
##               plane at a stud -- with no stud to aim at; PgUp / PgDn move the plane
##   no floor    a floating build area and a starting brick, laid again if all are gone
##   photos      a stud grid over a photo, calibrating in studs as well as mm, zoom at the
##               cursor in a flat view (Alt + wheel), Alt + drag moves a photo, and
##               buttons that put it behind the build or through its middle
##   sketch      Alt D: draw an outline on the side plane; it is filled with bricks for
##               the current part, as thick as that part is set to be
##
## Round 3 (2026-10-16):
##
##   undo        an RMB delete undoes (Z) and redoes (shift Z) like anything else
##   one click   one brick: a held click lays a run only once the mouse has really moved
##   sketch mode the sketch is kept: LMB draws area in, RMB draws it out, and the part's
##               bricks are worked out again from what is left. An outline that crosses
##               itself is filled to its outermost line. Slopes can be eager: on any edge
##               climbing one to three plates a stud, not only at a slope's own pitch
##
## A stud here is a nano stud on export: 4 mm printed, 16 mm of the real thing. A plate
## is 1.6 mm printed, 6.4 mm real (Docs/Parts/joints.md section 7).
##
## What it adds to a build is kept in the recipe's `meta.asset`, which nothing structural
## reads, so a build made here opens anywhere a build does.

const PRINT_MM_PER_STUD := 4.0
const PRINT_MM_PER_PLATE := 1.6
## A gun's nano model is a quarter of the real one.
const REAL_PER_PRINT := 4.0
const PLANES := ["side", "top", "front"]
const VIEWS := ["perspective", "side", "top", "front"]
const KEYS_TEXT := "F10 instructions   F2 photos   F3 guide models   F7 parts   Alt 0-3 view   Alt C the game's view   Alt M measure   Alt S mirror (shift: plane here)   Alt F free place   Alt D block out   Alt U studs   Alt G move part   Alt E explode   Alt H hands   Alt P play   PgUp/PgDn working plane\nY part toolbar (shift: back)   hold LMB + move: lay a run   J connection point   K shapes   L select   O section   P outlines\nN part smooth / bricks   F4 wand from a photo   F12 export and preview   Z undo (a fill at once)   shift Z redo"

## Each: {path, plane, px (image size), mpp (metres a pixel), centre, opacity, shown, node}.
var photos: Array = []
var photo_sel := -1
var mirror_on := false
## Where the mirror plane is, in studs across (Z). Half a stud past a whole one is the
## middle of a stud, so a part an odd number of studs wide sits centred on it.
var mirror_z := 0.0
var view := 0
var measure_on := false
var measure_points: Array[Vector3] = []
## Points clicked while calibrating the selected photo; calibrating while not null.
var calibrating = null

var _ortho_size := 1.0
var _persp_xf := Transform3D()
var _ruler: Label
var _panel: PanelContainer
var _photo_list: OptionButton
var _plane_list: OptionButton
var _opacity: HSlider
var _shown: CheckBox
var _photo_info: Label
var _file_dialog: FileDialog
var _length_dialog: AcceptDialog
var _length_edit: LineEdit
var _measure_line: MeshInstance3D
var _measure_label: Label3D
var _mirror_sheet: MeshInstance3D

## The parts an asset is split into, by name; a gun's are its slots. Every brick has one.
var part_names := PackedStringArray()
## The part of each brick, by recipe index: kept beside the recipe, in step with it.
var part_of := PackedInt32Array()
var part_sel := 0
## part name -> its toolbar's nine slots, as WorkshopHotbar.slots holds them.
var toolbars := {}
## Mounts and sockets: {part, kind, slot, interface, at: [studs along, plates up, studs across]}.
var points: Array = []
## Holding LMB to lay a run: the cell last laid, or NO_STUD between runs.
var _run_last := NO_STUD
var _run_on := false
## A brick the workshop is about to delete, by recipe index, so its tag goes with it.
var _removing := -1
var _loading := false
var _part_label: Label
var _points_root: Node3D
var _point_panel: PanelContainer
## The parts catalogue (F7, Docs/ModularParts.md section 6), made when first opened.
var _catalog_panel: PartCatalogPanel
var _point_kind: OptionButton
var _point_slot: OptionButton
var _point_iface: OptionButton
var _interfaces := {}

## Phase 3. The drag tool in hand: "", "shape" or "select".
var tool := ""
var shape_kind := "box"
var shape_fill := "clean"
## How many plates tall a box, cylinder or wedge is.
var shape_plates := 3
## Recipe ids of the bricks the select tool holds.
var selection: Array[int] = []
var section_on := false
## 0 off, 1 every brick in its part's colour, 2 the current part's only.
var outlines := 0
## Each: {path, real_mm, offset, turn, opacity, node, box (AABB of the model as loaded)}.
var guides: Array = []
var _drag_from := Vector3i.ZERO
var _drag_to := Vector3i.ZERO
var _dragging := false
var _tool_lines: MeshInstance3D
var _outline_lines: MeshInstance3D
var _outlines_dirty := false
var _tool_panel: PanelContainer
var _shape_box: VBoxContainer
var _select_box: VBoxContainer
var _sketch_box: VBoxContainer
var _width_spin: SpinBox
var _guide_panel: PanelContainer
var _guide_list: OptionButton
var _guide_mm: LineEdit
var _guide_dialog: FileDialog
var _rng := RandomNumberGenerator.new()
const SHAPES := ["box", "cylinder", "sphere", "wedge"]

## Free placement: the ghost goes where the cursor meets the working plane.
var free_place := true
## The working plane: "side" (at `work_depth` studs across), "top" (at `work_height`
## plates up) or "front" (at `work_x` studs along). A flat view picks its own.
var work_plane := "side"
var work_depth := 40.5
var work_height := 30
var work_x := 40
## Lay a starting brick when the build is empty (off in a headless run: probes count bricks).
var auto_start_brick := true
## How thick each part is across the gun, in studs, for sketching it.
var part_width := {}
const AUTOSAVE := "user://asset_workshop_autosave.json"
var _autosave_dirty := false
## A scripted run (--shot, --gate) must never write over the user's autosave.
var _no_autosave := false
var _autosave_at := 0
var _plane_lines: MeshInstance3D
var _photo_lines: MeshInstance3D
var photo_grid := false
## A sketch being drawn: points on the side plane, (studs along, plates up).
var _sketch: Array[Vector2] = []
var _photo_drag = null
## An RMB delete, for undo: what it took, newest last, one for each "delete" edit.
var _deleted: Array = []
## A held click lays a run only after the mouse has moved this far, this long after.
const RUN_START_PX := 14.0
const RUN_START_MS := 150
var _run_moved := 0.0
var _run_press_ms := 0
## The kept sketches: "part|plane|where" -> {part, plane, at, width, adds, subs, n}. `n`
## orders them: a part's first plane is its base (Round 4 in Docs/AssetWorkshop.md).
## adds and subs are outlines ([[across, up], ...]); bricks are what the sketch laid,
## [[archetype, [x, y, z]], ...], so it can take them up again when it changes.
var sketches := {}
## The bricks each part's sketches laid: part -> [[archetype, [x, y, z]] ...].
var part_bricks := {}
var _part_vol := {}       # part -> its volume (cells), as last laid
var _sketch_seq := 0
var cut_deep := 0         # RMB in sketch: 0 cuts right through, else this many studs in
var _sketch_sig := ""
var _course := 0          # the lowest plate of the part last worked out: its courses count from there
var _box := [Vector3i.ZERO, Vector3i.ZERO]   # and the box round it
var _part_box := {}       # part -> the box round its volume, as last laid
var _sketch_static: MeshInstance3D
## Slopes on any edge climbing one to three plates a stud, not only two.
var slope_eager := false
## How many slopes and curves a part's form is laid with (the curve slider): 0 steps only,
## 1 slopes, 2 slopes and curves, 3 those fitted from the side and the front whichever
## views the part was drawn in, 4 slopes eager too (a plate proud of or short of the line).
var curve_level := 2:
	set(v):
		curve_level = clampi(v, 0, CURVE_LEVELS.size() - 1)
		slope_eager = curve_level >= 4
const CURVE_LEVELS := ["steps only", "slopes", "slopes and curves", "from the side and front",
		"eager slopes too"]
var _sketch_out := false
var _sketch_cache := {}

## Phase 4. Parts that leave as smooth custom pieces rather than bricks.
var smooth_parts := PackedStringArray()
## Which end of the build is the muzzle: "-x" (the low end) or "+x".
var muzzle_end := "-x"
## How many studs across the wand fills.
var wand_width := 3
## Groups of bricks undone, newest last, for shift Z: each a list of what to lay again.
var _redo: Array = []
## Edits that undo together: {end: the edit count after them, n: how many}.
var _edit_groups: Array = []
var _redoing := false
## Where Blender is, to run the part kit. BRICKCITY_BLENDER overrides it.
var blender_path := "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe"
var _export_png := ""
var _export_check := ""
## The last triangle count (`triangle_stats`), and when to count again: a moment after
## the last edit, so a sketch stroke or a held run is counted once, when it stops.
var _tris := {}
var _tris_due := 0
const TRIS_SETTLE_MS := 400
## The `view_box` the grid and the mirror sheet were last drawn round.
var _view_drawn := []
var _export_started := 0
var _preview_panel: PanelContainer
var _preview_image: TextureRect
var _preview_text: Label

## Where the toolbars are remembered; a probe points it elsewhere.
var toolbars_save := "user://asset_workshop_toolbars.json"
## The parts a new asset starts with: a gun's slots (Docs/Parts/custom.md section 4).
const GUN_PARTS := ["body", "barrel", "stock", "grip", "magazine", "sight", "muzzle", "underbarrel"]
const PART_COLOURS := [Color(0.62, 0.66, 0.72), Color(0.95, 0.55, 0.2), Color(0.85, 0.72, 0.45),
		Color(0.55, 0.85, 0.4), Color(0.4, 0.7, 1.0), Color(0.9, 0.4, 0.85), Color(1.0, 0.85, 0.3),
		Color(0.45, 0.9, 0.85)]

## The build area: 1000 studs each way and 2500 plates up (a cube: 5000 ticks each way),
## for mechs and vehicles as well as guns. The engine holds a grid this big paged, only
## where there are bricks (`Occupancy`, brick_types.h). A new build starts in its middle.
const ASSET_PLATE_STUDS := 1000
const ASSET_HEIGHT_PLATES := 2500
## The area before paging (80 studs, 200 plates): what a brick library without
## `BrickWorld.paged_chunk_cells` gets, since it would allocate the big one whole.
const SMALL_PLATE_STUDS := 80
const SMALL_HEIGHT_PLATES := 200
## What is drawn and framed round the build -- the working plane's grid, the mirror
## sheet, a new photo's size, the flat views' zoom: this many studs, not the whole area.
const VIEW_STUDS := 80


func _init() -> void:
	plate_studs = ASSET_PLATE_STUDS
	height_plates = ASSET_HEIGHT_PLATES
	if not ClassDB.class_has_method("BrickWorld", "paged_chunk_cells"):
		push_warning("[asset workshop] this brick library cannot page a chunk: build area %d studs, not %d (rebuild the extension)"
				% [SMALL_PLATE_STUDS, ASSET_PLATE_STUDS])
		plate_studs = SMALL_PLATE_STUDS
		height_plates = SMALL_HEIGHT_PLATES
	mirror_z = plate_studs * 0.5 + 0.5
	@warning_ignore("integer_division")
	work_x = plate_studs / 2
	_ortho_size = VIEW_STUDS * BrickPalette.STUD_M * 0.75


func _ready() -> void:
	super()
	# What is made here is a gun (or a mech): File > Save, Save As and Open use their
	# library (user://guns/), not the buildings'. F5 has its own slot, not the workshop's.
	_save_path = ASSET_QUICK_SAVE
	if _menu != null:
		_menu.asset_mode(ASSET_KINDS)
		_build_menus()
	_set_asset_kind(recipe.kind)
	_build_asset_tools()
	_setup_parts()
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var headless := DisplayServer.get_name() == "headless"
	auto_start_brick = not headless
	_no_autosave = headless or "--shot" in args or "--gate" in args
	work_depth = mirror_z
	if "--shot" in args:
		call_deferred("_shot")
	elif not ("--gate" in args):
		print("[asset workshop] " + KEYS_TEXT)
		if not headless and FileAccess.file_exists(AUTOSAVE):
			call_deferred("_restore_autosave")
	_grid.visible = not free_place
	# The workshop's own key list starts hidden here (F1 shows it): it covers half the
	# screen, and F10 lists this scene's keys.
	_keys_on = false
	_keys_panel.visible = false
	call_deferred("_ensure_start_brick")
	call_deferred("_look_at_build")


## `-- --shot [--photo=<file> --from=x,y --to=x,y --mm=<real length>]`: a photo on the
## side plane, calibrated by two of its pixels and the real length between them, the
## mirror on, pictures from the perspective and side views into user://asset_shots/.
## For looking at the tools without driving them by hand.
func _shot() -> void:
	var opt := {"photo": "", "from": "", "to": "", "mm": ""}
	for a in OS.get_cmdline_user_args():
		for k in opt:
			if a.begins_with("--%s=" % k):
				opt[k] = a.substr(k.length() + 3)
	if opt.photo != "":
		var i := load_photo(opt.photo, "side")
		if i >= 0 and opt.from != "" and opt.to != "" and opt.mm != "":
			var f: PackedStringArray = opt.from.split(",")
			var t: PackedStringArray = opt.to.split(",")
			calibrate(i, photo_point(i, Vector2(float(f[0]), float(f[1]))),
					photo_point(i, Vector2(float(t[0]), float(t[1]))), float(opt.mm))
			set_photo_depth(i, "behind")
			photo_grid = true
			_draw_photo_grid()
	set_mirror(true)
	show_help(false)
	DirAccess.make_dir_recursive_absolute("user://asset_shots")
	if "--ramp" in OS.get_cmdline_user_args():
		# A sketched ramp climbing a slope's pitch, to look at the slopes it lays.
		for _i in 3:
			await get_tree().process_frame
		sketch_fill([Vector2(30, 36), Vector2(38, 52), Vector2(46, 52), Vector2(46, 20), Vector2(38, 20)])
		# And a drum magazine, a circle on the front plane (on the body it would be a view
		# through it, cutting it to the circle).
		select_part(part_names.find("magazine"))
		work_plane = "front"
		work_x = 52
		var circle := []
		for a in 32:
			var t := a * TAU / 32.0
			circle.append(Vector2(mirror_z + 4.0 * cos(t), 36.0 + 10.0 * sin(t)))
		sketch_fill(circle)
		select_part(0)
		work_plane = "side"
		rail_pick("sketch")
		sketch_draw = "brush"
		_look_at_build()
		var f := FileAccess.open("user://asset_shots/ramp.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(export_sheet(), " "))
			f.close()
	var views := [0, 1]
	if "--brush" in OS.get_cmdline_user_args():
		# The shape brush: a cube laid, a ball carved out of its corner, a flat circle on top.
		for _i in 3:
			await get_tree().process_frame
		set_mirror(false)
		var at := Vector3i(40, 40, 40)
		shape_place(brush_shape_cells("cube", at, 8))
		shape_carve(brush_shape_cells("ball", at + Vector3i(4, 10, 4), 8))
		shape_place(brush_shape_cells("circle", at + Vector3i(0, 10, 0), 6, 1, 1))
		rail_pick("shape")
		shape_mode = "brush"
		_look_at_build()
	if "--sculpt" in OS.get_cmdline_user_args():
		# The SDF block-out: a body, a barrel, a stock blended on and a grip, each its part.
		for _i in 3:
			await get_tree().process_frame
		set_mirror(false)
		var base := Vector3(recipe.cell_of(0)) if recipe.size() > 0 else Vector3(500, 30, mirror_z)
		base.z = mirror_z
		var at := func(x: float, y: float) -> Vector3:
			return sculpt.to_sample(Vector3((base.x + x) * BrickPalette.STUD_M, (base.y + y) * BrickPalette.PLATE_M,
					base.z * BrickPalette.STUD_M))
		sculpt.form.begin_edit()
		_sculpt_op = SdfForm.ADD
		for st in [["body", 1.5, 0.0, 0.0, 8.0, 20.0, 8.0], ["barrel", 0.6, 0.0, 20.0, 12.0, 40.0, 12.0],
				["stock", 1.3, 1.0, 0.0, 6.0, -14.0, -2.0], ["grip", 0.8, 0.6, 4.0, 2.0, 2.0, -24.0]]:
			select_part(maxi(0, part_names.find(st[0])))
			sculpt_radius = st[1]
			sculpt_blend = st[2]
			_sculpt_dab(at.call(st[3], st[4]), at.call(st[5], st[6]))
		# All marked smooth but the barrel's far half, which stays bricks (--plain: nothing
		# marked, all bricks, slopes and curves on the edges).
		if not "--plain" in OS.get_cmdline_user_args():
			_sculpt_op = SdfForm.MARK
			sculpt_radius = 20.0
			_sculpt_dab(at.call(-16.0, 0.0), at.call(30.0, 0.0))
			_sculpt_op = SdfForm.UNMARK
			sculpt_radius = 3.0
			_sculpt_dab(at.call(30.0, 12.0), at.call(42.0, 12.0))
		_sculpt_record(sculpt.form.end_edit())
		sculpt_blend = 0.0
		if "--stamps" in OS.get_cmdline_user_args():
			# Round 2's tools: a box stamp over the body, a cylinder and a cone on the
			# barrel, the body's side flattened, the grip grown; round 3's lathe, and a lathe's ghost left showing.
			sculpt.form.begin_edit()
			_sculpt_plane = Plane(Vector3.BACK, at.call(0.0, 0.0).z)
			sculpt_snap = true
			sculpt_radius = 1.0
			select_part(maxi(0, part_names.find("body")))
			sculpt_shape = "box"
			_stamp_from = _stamp_snap(at.call(2.0, 9.0))
			_stamp_to = _stamp_snap(at.call(14.0, 15.0))
			_lay_stamp(_stamp_desc(), SdfForm.ADD)
			select_part(maxi(0, part_names.find("barrel")))
			sculpt_shape = "cylinder"
			sculpt_radius = 0.8
			_stamp_from = at.call(20.0, 12.0)
			_stamp_to = at.call(34.0, 12.0)
			_lay_stamp(_stamp_desc(), SdfForm.ADD)
			sculpt_shape = "cone"
			sculpt_radius = 1.2
			_stamp_from = at.call(34.0, 12.0)
			_stamp_to = at.call(40.0, 12.0)
			_lay_stamp(_stamp_desc(), SdfForm.ADD)
			select_part(maxi(0, part_names.find("body")))
			sculpt_radius = 2.0
			sculpt_strength = 1.0
			_sculpt_op = OP_FLATTEN
			var side: Vector3 = at.call(8.0, 4.0) + Vector3(0, 0, 4)
			_flat_point = side
			_flat_normal = Vector3.BACK
			_sculpt_dab(side, side)
			_sculpt_dab(side + Vector3(20, 0, 0), side + Vector3(20, 0, 0))
			select_part(maxi(0, part_names.find("grip")))
			_sculpt_op = SdfForm.GROW
			sculpt_strength = 1.0
			_sculpt_dab(at.call(3.0, -20.0), at.call(3.0, -20.0))
			sculpt.remesh()
			_sculpt_record(sculpt.form.end_edit())
			# A lathe: a muzzle brake turned on the barrel's end, and one being drawn below.
			select_part(maxi(0, part_names.find("barrel")))
			sculpt_shape = "lathe"
			_lathe_axis = [at.call(40.0, 12.0), at.call(47.0, 12.0)]
			_lathe_op = SdfForm.ADD
			for q in [Vector2(40, 13), Vector2(41, 14.5), Vector2(44, 14.5), Vector2(45, 13.5), Vector2(47, 14)]:
				lathe_click(at.call(q.x, q.y))
			lathe_finish()
			rail_pick("sculpt")
			sculpt_mode = "stamp"
			_lathe_axis = [at.call(10.0, 24.0), at.call(24.0, 24.0)]
			for q in [Vector2(10, 26), Vector2(16, 29)]:
				lathe_click(at.call(q.x, q.y))
			_show_stamp(at.call(24.0, 27.0))
		if "--pick" in OS.get_cmdline_user_args():
			# Pick and move (Docs/AssetWorkshop.md, "Pick and move"): the test gun as a model of
			# its pieces beside the block-out, its second piece picked (lighter); the block-out's
			# barrel lifted, raised four studs and turned, the gizmo on it.
			rail_pick("sculpt")
			var scene := _test_gun_scene()
			var pieces := []
			for mi in scene.find_children("*", "MeshInstance3D", true, false):
				var one := ArrayMesh.new()
				ModelMesh._add_one(mi as MeshInstance3D, scene, one)
				pieces.append(["box %d" % (pieces.size() + 1), one])
			scene.free()
			add_model(pieces, "test_gun.glb")
			var m: Dictionary = _placed
			m.xf = Transform3D((m.xf as Transform3D).basis, (m.xf as Transform3D).origin + Vector3(0, 0, 25.0 * BrickPalette.STUD_M))
			_stamp_model(m)
			lift_part(maxi(0, part_names.find("barrel")) + 1)
			m.piece = 1
			_colour_model(m)
			_gizmo_xf0 = _placed.xf
			_gizmo.position = _placed_centre()
			_placed.xf = dragged_xf({"move": Vector3(0, BrickPalette.STUD_M * 4.0, 0)}, false)
			_held_follow()
			_gizmo_xf0 = _placed.xf
			_gizmo.position = _placed_centre()
			_placed.xf = dragged_xf({"turn": [Vector3.BACK, deg_to_rad(15.0)]}, false)
			_held_moved([])
			_gizmo.set_hover("move1")
			sculpt_mode = "models"
			print("[pick] lifted %s, %s studs; model pieces %d, picked %d" % [_placed.path, str(placed_size()),
					pieces.size(), int(m.piece)])
		if "--convert" in OS.get_cmdline_user_args():
			var t0 := Time.get_ticks_msec()
			sculpt_convert()
			var shaped := {}
			for i in recipe.size():
				var part := BrickPalette.part_of(recipe.part_of(i))
				if BrickPalette.is_shaped(part):
					shaped[part] = int(shaped.get(part, 0)) + 1
			print("[sculpt] converted in %d ms: %d bricks, shaped %s, shells %s" % [Time.get_ticks_msec() - t0,
					recipe.size(), str(shaped), str(_shell_tris)])
		# Picking the tool again would put a lifted part down (--pick wants it held).
		if _held_kind() != "part":
			rail_pick("sculpt")
		var bb := sculpt.form.bounds()
		print("[sculpt] %d blocks, %d triangles, %d cells, bounds %s" % [sculpt.form.block_count(),
				sculpt.triangles(), sculpt.form.cells().size() / 5, str(bb)])
		_look_at_build()
	if "--model" in OS.get_cmdline_user_args():
		# Round 4: a gun-shaped model (boxes under an armature at 1/100, lying across) placed
		# by its gizmo, moved up and turned, with the SMG's ruler and grip box; --gameview
		# lays it and looks through the game's first-person view.
		for _i in 3:
			await get_tree().process_frame
		set_mirror(false)
		rail_pick("sculpt")
		var scene := _test_gun_scene()
		place_mesh(ModelMesh.flatten(scene), "test_gun.glb")
		scene.free()
		muzzle_end = "-x"
		_gizmo_xf0 = _placed.xf
		_gizmo.position = _placed_centre()
		_placed.xf = dragged_xf({"move": Vector3(0, BrickPalette.STUD_M * 4.0, 0)}, false)
		_gizmo_xf0 = _placed.xf
		_gizmo.position = _placed_centre()
		_placed.xf = dragged_xf({"turn": [Vector3.BACK, deg_to_rad(5.0)]}, false)
		_stamp_placed()
		_show_gizmo()
		_gizmo.set_hover("turn2")
		_size_sig = ""
		draw_size_marks()
		print("[model] placed %s studs, field %d blocks" % [str(placed_size()), sculpt.form.block_count()])
		if "--gameview" in OS.get_cmdline_user_args():
			lay_model()
			set_game_view(true)
			views = [0]
		else:
			_frame_placed()
	if "--receiver" in OS.get_cmdline_user_args():
		# A receiver in three views: a side slab, a charging slot cut through and a port cut
		# a stud in, then its top corners chamfered from the front.
		for _i in 3:
			await get_tree().process_frame
		set_mirror(false)
		slope_eager = true
		part_width["body"] = 5
		work_plane = "side"
		sketch_region([Vector2(20, 30), Vector2(50, 30), Vector2(50, 46), Vector2(20, 46)])
		sketch_region([Vector2(24, 41), Vector2(36, 41), Vector2(36, 43), Vector2(24, 43)], true)
		cut_deep = 1
		sketch_region([Vector2(30, 34), Vector2(40, 34), Vector2(40, 39), Vector2(30, 39)], true)
		cut_deep = 0
		work_plane = "front"
		work_x = 60
		var z := mirror_z
		sketch_region([Vector2(z - 2.5, 28), Vector2(z + 2.5, 28), Vector2(z + 2.5, 42), Vector2(z + 0.5, 46),
				Vector2(z - 0.5, 46), Vector2(z - 2.5, 42)])
		work_plane = "side"
		# Studs on its flank, a row, and one on a chamfer.
		for x in [22.0, 23.0, 24.0, 44.0, 45.0]:
			var h := stud_hit(Vector3(x * BrickPalette.STUD_M, 33.0 * BrickPalette.PLATE_M, 60.0 * BrickPalette.STUD_M),
					Vector3.FORWARD)
			if not h.is_empty():
				stud_edit(true, h)
		var lean := stud_hit(Vector3(46.0 * BrickPalette.STUD_M, 60.0 * BrickPalette.PLATE_M, (mirror_z + 2.0) * BrickPalette.STUD_M),
				Vector3(0, -1, -0.6).normalized())
		if not lean.is_empty():
			stud_edit(true, lean)
		rail_pick("stud")
		if "--explode" in OS.get_cmdline_user_args():
			# The rest of a gun round it, then pulled apart.
			for spec in [["barrel", 1, [Vector2(4, 37), Vector2(20, 37), Vector2(20, 41), Vector2(4, 41)]],
					["stock", 3, [Vector2(50, 33), Vector2(66, 30), Vector2(66, 44), Vector2(50, 45)]],
					["grip", 3, [Vector2(42, 14), Vector2(47, 14), Vector2(48, 30), Vector2(43, 30)]],
					["magazine", 3, [Vector2(30, 12), Vector2(36, 12), Vector2(36, 30), Vector2(30, 30)]]]:
				select_part(part_names.find(spec[0]))
				part_width[spec[0]] = spec[1]
				work_plane = "side"
				sketch_region(spec[2])
			select_part(0)
			if "--hands" in OS.get_cmdline_user_args():
				set_hands(true)
			else:
				set_exploded(true)
		_look_at_build()
		views = [0, 1, 3]
	DirAccess.make_dir_recursive_absolute("user://asset_shots")
	for v in views:
		if not game_view_on:
			set_view(v)
		for _i in 12:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "user://asset_shots/%s.png" % ("game" if game_view_on else VIEWS[v])
		img.save_png(path)
		print("[asset workshop] wrote %s" % ProjectSettings.globalize_path(path))
	if "--menu" in OS.get_cmdline_user_args():
		# The Gun menu open, to see the menus.
		for c in _menu._spacer.get_parent().get_children():
			if c is MenuButton and (c as MenuButton).text == "Gun":
				(c as MenuButton).show_popup()
		for _i in 6:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("user://asset_shots/menu.png")
	if hands_on:
		# Mid-reload: the magazine out, the left hand pinching it.
		set_view(1)
		_play = {"t": 3.0, "last": Time.get_ticks_msec()}
		_display_dirty = true
		_rebuild_display()
		for _i in 3:
			_play.t = 3.0
			_play.last = Time.get_ticks_msec()
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("user://asset_shots/reload.png")
		_play = {}
		_clear_display()
	show_help(true)
	for _i in 12:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("user://asset_shots/help.png")
	print("[asset workshop] wrote %s" % ProjectSettings.globalize_path("user://asset_shots/help.png"))
	get_tree().quit()


# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

static func studs_text(studs: float) -> String:
	var mm := studs * PRINT_MM_PER_STUD
	return "%s studs = %.1f mm print = %.0f mm real" % [_num(studs), mm, mm * REAL_PER_PRINT]


static func plates_text(plates: float) -> String:
	var mm := plates * PRINT_MM_PER_PLATE
	return "%s plates = %.1f mm print = %.0f mm real" % [_num(plates), mm, mm * REAL_PER_PRINT]


## Metres in the workshop to millimetres printed: a stud is 0.35 m here and 4 mm there.
static func print_mm(metres: float) -> float:
	return metres / BrickPalette.STUD_M * PRINT_MM_PER_STUD


static func _num(v: float) -> String:
	return str(int(round(v))) if absf(v - round(v)) < 0.005 else "%.2f" % v


# ---------------------------------------------------------------------------
# Photos
# ---------------------------------------------------------------------------

## Put a picture on a plane behind the build. Returns its index.
func add_photo_image(img: Image, path: String, plane: String = "side") -> int:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = ImageTexture.create_from_image(img)
	var node := MeshInstance3D.new()
	node.mesh = QuadMesh.new()
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	var p := {"path": path, "plane": plane, "px": Vector2i(img.get_width(), img.get_height()),
			"mpp": VIEW_STUDS * BrickPalette.STUD_M * 0.9 / maxf(img.get_width(), 1.0),
			"centre": _default_centre(plane), "opacity": 0.6, "shown": true, "node": node, "image": img}
	if plane != "top":
		# Standing on the plate, not floating over it.
		p.centre.y = BrickPalette.PLATE_M + img.get_height() * float(p.mpp) * 0.5
	photos.append(p)
	photo_sel = photos.size() - 1
	_fit_photo(p)
	_store_asset_meta()
	_refresh_panel()
	return photo_sel


func load_photo(path: String, plane: String = "side") -> int:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		push_warning("asset workshop: could not read %s" % path)
		return -1
	return add_photo_image(img, path, plane)


func remove_photo(i: int) -> void:
	if i < 0 or i >= photos.size():
		return
	(photos[i].node as Node).queue_free()
	photos.remove_at(i)
	photo_sel = mini(photo_sel, photos.size() - 1)
	_store_asset_meta()
	_refresh_panel()


func set_photo_plane(i: int, plane: String) -> void:
	var p: Dictionary = photos[i]
	p.plane = plane
	p.centre = _default_centre(plane)
	_fit_photo(p)
	_store_asset_meta()


## Two points on a photo, and how far apart they are on the real thing (mm): the photo
## is scaled about the first point, which stays where it is.
func calibrate(i: int, a: Vector3, b: Vector3, real_mm: float) -> void:
	var p: Dictionary = photos[i]
	var d := a.distance_to(b)
	if d < 1e-6 or real_mm <= 0.0:
		return
	var want := real_mm / (PRINT_MM_PER_STUD * REAL_PER_PRINT) * BrickPalette.STUD_M
	var f := want / d
	p.mpp = float(p.mpp) * f
	p.centre = a + ((p.centre as Vector3) - a) * f
	_fit_photo(p)
	_store_asset_meta()
	_refresh_panel()


## Move a photo: `along` and `up` in its own plane, `out` towards the camera, in studs.
func nudge_photo(i: int, along: float, up: float, out: float) -> void:
	var p: Dictionary = photos[i]
	var b := _photo_basis(p.plane)
	p.centre = (p.centre as Vector3) + (b.x * along + b.y * up + b.z * out) * BrickPalette.STUD_M
	_fit_photo(p)
	_store_asset_meta()


func set_photo_opacity(i: int, a: float) -> void:
	photos[i].opacity = clampf(a, 0.05, 1.0)
	_fit_photo(photos[i])
	_store_asset_meta()


func set_photo_shown(i: int, on: bool) -> void:
	photos[i].shown = on
	_fit_photo(photos[i])
	_store_asset_meta()


## A pixel of a photo, where it is in the workshop.
func photo_point(i: int, px: Vector2) -> Vector3:
	var p: Dictionary = photos[i]
	var size := Vector2(p.px) * float(p.mpp)
	var local := Vector3((px.x / float(p.px.x) - 0.5) * size.x, (0.5 - px.y / float(p.px.y)) * size.y, 0.0)
	return (p.node as Node3D).transform * local


## Where a ray meets a photo's plane, or null behind the camera or edge-on.
func ray_on_photo(i: int, from: Vector3, dir: Vector3) -> Variant:
	var node: Node3D = photos[i].node
	var n := node.transform.basis.z.normalized()
	var denom := n.dot(dir)
	if absf(denom) < 1e-5:
		return null
	var t := n.dot(node.transform.origin - from) / denom
	return from + dir * t if t > 0.0 else null


func _default_centre(plane: String) -> Vector3:
	var c := build_centre()
	var up := VIEW_STUDS * BrickPalette.STUD_M * 0.25
	var box := view_box()
	match plane:
		"top":
			return Vector3(c.x, BrickPalette.PLATE_M + 0.004, c.z)
		"front":
			return Vector3((box[0] as Vector3i).x * BrickPalette.STUD_M, up, c.z)
	return Vector3(c.x, up, (box[0] as Vector3i).z * BrickPalette.STUD_M)


## The cells drawn round the build (`VIEW_STUDS` along and across, two and a half times
## that in plates up), inside the build area: [min cell, max cell + 1].
func view_box() -> Array:
	var c := build_centre()
	var half := Vector3i(VIEW_STUDS / 2, int(VIEW_STUDS * 1.25), VIEW_STUDS / 2)
	var mid := Vector3i(int(c.x / BrickPalette.STUD_M), int(c.y / BrickPalette.PLATE_M), int(c.z / BrickPalette.STUD_M))
	var area := Vector3i(plate_studs, height_plates, plate_studs)
	var lo := (mid - half).clamp(Vector3i.ZERO, area)
	var hi := (mid + half).clamp(Vector3i.ZERO, area)
	if lo.y == 0:
		hi.y = mini(area.y, half.y * 2)
	return [lo, hi]


## The plane's axes: x along the picture, y up it, z out of it towards the viewer.
static func _photo_basis(plane: String) -> Basis:
	match plane:
		"top":
			return Basis(Vector3.RIGHT, -PI * 0.5)
		"front":
			return Basis(Vector3.UP, PI * 0.5)
	return Basis()


func _fit_photo(p: Dictionary) -> void:
	if _photo_lines != null:
		_draw_photo_grid.call_deferred()
	var node: MeshInstance3D = p.node
	(node.mesh as QuadMesh).size = Vector2(p.px) * float(p.mpp)
	node.transform = Transform3D(_photo_basis(p.plane), p.centre)
	var mat := node.material_override as StandardMaterial3D
	mat.albedo_color = Color(1, 1, 1, float(p.opacity))
	node.visible = bool(p.shown)


# ---------------------------------------------------------------------------
# Measure
# ---------------------------------------------------------------------------

## What a measurement says: how far along, up and across, and the straight distance.
static func measure_text(a: Vector3, b: Vector3) -> String:
	var d := (b - a).abs()
	var straight := print_mm(a.distance_to(b))
	return "%s along, %s up, %s across\n%.1f mm print, %.0f mm real" % [
			_num(d.x / BrickPalette.STUD_M) + " studs", _num(d.y / BrickPalette.PLATE_M) + " plates",
			_num(d.z / BrickPalette.STUD_M) + " studs", straight, straight * REAL_PER_PRINT]


## Where a ray lands for measuring: a brick, else a shown photo, else the baseplate.
func measure_point(from: Vector3, dir: Vector3) -> Variant:
	var hit := _first_hit(from, dir)
	if not hit.is_empty():
		# The workshop's ray steps a third of a plate at a time, so its hit is somewhere
		# inside the brick. Halve back onto the face: a measurement is between surfaces.
		var outside := maxf(float(hit.t) - BrickPalette.PLATE_M * 0.34, 0.0)
		var inside := float(hit.t)
		for _i in 24:
			var mid := (outside + inside) * 0.5
			var p := from + dir * mid
			var f: int = hit.frame
			if world.block_at(f, _cell_in(f, p)) >= 0 and world.is_solid(f, _cell_in(f, p)):
				inside = mid
			else:
				outside = mid
		return from + dir * inside
	if photo_sel >= 0 and bool(photos[photo_sel].shown):
		var on = ray_on_photo(photo_sel, from, dir)
		if on != null:
			return on
	if absf(dir.y) > 1e-5:
		var t := (BrickPalette.PLATE_M - from.y) / dir.y
		if t > 0.0:
			return from + dir * t
	return null


func set_measure(on: bool) -> void:
	measure_on = on
	measure_points.clear()
	_draw_measure()


func _measure_click() -> void:
	var ray := _mouse_ray()
	var p = measure_point(ray[0], ray[1])
	if p == null:
		return
	if measure_points.size() >= 2:
		measure_points.clear()
	measure_points.append(p)
	_draw_measure()


func _draw_measure() -> void:
	var im := ImmediateMesh.new()
	_measure_line.mesh = im
	_measure_label.visible = false
	if measure_points.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var tick := BrickPalette.STUD_M * 0.25
	for p in measure_points:
		for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			im.surface_add_vertex(p - axis * tick)
			im.surface_add_vertex(p + axis * tick)
	if measure_points.size() == 2:
		im.surface_add_vertex(measure_points[0])
		im.surface_add_vertex(measure_points[1])
		_measure_label.text = measure_text(measure_points[0], measure_points[1])
		_measure_label.position = (measure_points[0] + measure_points[1]) * 0.5 + Vector3.UP * 0.2
		_measure_label.visible = true
	im.surface_end()


# ---------------------------------------------------------------------------
# Mirror
# ---------------------------------------------------------------------------

## The first stud across of a part `width` studs wide at `z`, mirrored across the plane.
func mirrored_z(z: int, width: int) -> int:
	return int(round(2.0 * mirror_z - float(z + width)))


func set_mirror(on: bool) -> void:
	mirror_on = on
	_mirror_sheet.visible = on
	_place_mirror_sheet()
	_store_asset_meta()


## Put the plane down the middle of the ghost.
func mirror_here() -> void:
	mirror_z = _cell.z + BrickPalette.size_of(_archetype_name()).z * 0.5
	_place_mirror_sheet()
	_store_asset_meta()


func _place() -> void:
	var before := recipe.size()
	super._place()
	if recipe.size() > before:
		_redo.clear()
	if mirror_on and recipe.size() > before and _frame == 0:
		_place_mirrored()
		if recipe.size() == before + 2:
			_edit_groups.append({"end": _edits.size(), "n": 2})


## The brick just placed, again, on the other side of the plane. A part with a front
## that looks across the plane is turned to look the other way; one straddling the plane
## exactly is its own mirror and is not placed twice. Upright grid only, for now.
func _place_mirrored() -> void:
	var arch := _archetype_name()
	var size := BrickPalette.size_of(arch)
	var z := mirrored_z(_cell.z, size.z)
	if z == _cell.z:
		return
	var keep := [_cell, _yaw, _snapped]
	var front := BrickPalette.front_of(arch)
	if front.z != 0:
		var want := Vector3i(front.x, front.y, -front.z)
		for y in 4:
			if BrickPalette.front_of(BrickPalette.variant_name(_part(), y, _flip)) == want:
				_yaw = y
				break
	_snapped = {}
	_cell = Vector3i(_cell.x, _cell.y, z)
	_update_ghost()
	super._place()
	_cell = keep[0]
	_yaw = keep[1]
	_snapped = keep[2]
	_update_ghost()


func _place_mirror_sheet() -> void:
	var box := view_box()
	var x0 := (box[0] as Vector3i).x * BrickPalette.STUD_M
	var w := (box[1] as Vector3i).x * BrickPalette.STUD_M
	var y0 := maxf(0.15, (box[0] as Vector3i).y * BrickPalette.PLATE_M)
	var h := y0 + VIEW_STUDS * BrickPalette.STUD_M * 0.4
	var z := mirror_z * BrickPalette.STUD_M
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var corners := [Vector3(x0, y0, z), Vector3(w, y0, z), Vector3(w, h, z), Vector3(x0, h, z)]
	for k in 4:
		im.surface_add_vertex(corners[k])
		im.surface_add_vertex(corners[(k + 1) % 4])
	im.surface_end()
	_mirror_sheet.mesh = im


# ---------------------------------------------------------------------------
# Flat views
# ---------------------------------------------------------------------------

func set_view(v: int) -> void:
	if game_view_on:
		set_game_view(false)
	if v == view:
		return
	if view == 0:
		_persp_xf = _camera.global_transform
	view = v
	if v == 0:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera.global_transform = _persp_xf
		_camera.set_process_unhandled_input(true)
		_apply_section()
		return
	# Looking straight at the build. The camera's own click-to-look is off: a flat view
	# is built in with the cursor, and a captured mouse would turn it.
	_camera.set_process_unhandled_input(false)
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = _ortho_size
	work_plane = VIEWS[v]
	_draw_work_plane()
	var c := build_centre()
	match VIEWS[v]:
		"side":
			_camera.global_position = c + Vector3.BACK * 60.0
			_camera.look_at(c, Vector3.UP)
		"top":
			_camera.global_position = c + Vector3.UP * 60.0
			_camera.look_at(c, Vector3.FORWARD)
		"front":
			_camera.global_position = c + Vector3.RIGHT * 60.0
			_camera.look_at(c, Vector3.UP)
	_apply_section()


func zoom(by: float) -> void:
	_ortho_size = clampf(_ortho_size * by, 0.5, 80.0)
	if view != 0:
		_camera.size = _ortho_size


## The middle of what has been built, or of the baseplate before anything is.
func build_centre() -> Vector3:
	# While sculpting the block-out and the models are the build, not the starting brick
	# (models spawned away from the grid: Docs/AssetWorkshop.md, "Models as objects").
	if sculpt != null and sculpt_state == "sdf" and (sculpt.form.block_count() > 0 or not models.is_empty()):
		var sb := size_box()
		if sb.size != Vector3.ZERO:
			return sb.get_center()
	if recipe.size() == 0:
		var mid := plate_studs * BrickPalette.STUD_M * 0.5
		return Vector3(mid, 1.5, mid)
	var b := recipe.bounds()
	var lo: Vector3i = b[0]
	var d: Vector3i = b[1]
	return Vector3((lo.x + d.x * 0.5) * BrickPalette.STUD_M, (lo.y + d.y * 0.5) * BrickPalette.PLATE_M,
			(lo.z + d.z * 0.5) * BrickPalette.STUD_M)


# ---------------------------------------------------------------------------
# Input, the ruler, the panel
# ---------------------------------------------------------------------------

func _unhandled_input(e: InputEvent) -> void:
	if (_file_dialog != null and _file_dialog.visible) or (_length_dialog != null and _length_dialog.visible):
		return
	# The catalogue (F6) first: while it is open, clicks place furniture.
	if _furnish != null and _furnish.input(e):
		get_viewport().set_input_as_handled()
		return
	# The wheel over the rail scrolls the rail only: at its end it must not go on to the
	# hotbar (or zoom).
	if e is InputEventMouseButton and _over_rail():
		get_viewport().set_input_as_handled()
		return
	if _gizmo_input(e) or _shape_brush_input(e) or _photo_input(e) or _zoom_input(e) or _sketch_input(e) or _stud_input(e) \
			or _move_input(e):
		get_viewport().set_input_as_handled()
		return
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
			and (calibrating != null or measure_on):
		if calibrating != null:
			_calibrate_click()
		else:
			_measure_click()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and tool == "wand":
		if e.pressed:
			var ray := _mouse_ray()
			for i in photos.size():
				var hit = ray_on_photo(i, ray[0], ray[1])
				if hit != null and bool(photos[i].shown):
					wand_fill(i, hit, wand_width)
					break
		get_viewport().set_input_as_handled()
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and tool in ["shape", "select"]:
		if e.pressed:
			_drag_from = _cell
			_drag_to = _cell
			_dragging = true
		elif _dragging:
			_dragging = false
			_finish_drag()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and not _painting and _stamp == null:
			_run_on = true
			_run_last = _cell
			_run_moved = 0.0
			_run_press_ms = Time.get_ticks_msec()
		elif not e.pressed:
			_run_on = false
	if e is InputEventKey and e.pressed and not e.echo and not e.ctrl_pressed and e.alt_pressed:
		var alt := true
		match e.keycode:
			KEY_0: set_view(0)
			KEY_C: set_game_view(not game_view_on)
			KEY_1: set_view(1)
			KEY_2: set_view(2)
			KEY_3: set_view(3)
			KEY_M: set_measure(not measure_on)
			KEY_S:
				if e.shift_pressed:
					mirror_here()
				else:
					set_mirror(not mirror_on)
			KEY_F: set_free(not free_place)
			KEY_D: rail_pick("place" if rail_active() == "sketch" else "sketch")
			KEY_V: rail_pick("place" if rail_active() == "sculpt" else "sculpt")
			KEY_U: set_tool("" if tool == "stud" else "stud")
			KEY_G: set_tool("" if tool == "move" else "move")
			KEY_E: set_exploded(not exploded)
			KEY_H: set_hands(not hands_on)
			KEY_P: play_cycle()
			KEY_X: export_game()
			KEY_B: export_print()
			_: alt = false
		if alt:
			get_viewport().set_input_as_handled()
			return
	if e is InputEventKey and e.pressed and not e.ctrl_pressed and not e.alt_pressed and free_place \
			and not _painting and e.keycode in [KEY_PAGEUP, KEY_PAGEDOWN]:
		move_work_plane(1 if e.keycode == KEY_PAGEUP else -1)
		get_viewport().set_input_as_handled()
		return
	if e is InputEventKey and e.pressed and not e.echo and not e.ctrl_pressed:
		var mine := true
		match e.keycode:
			KEY_Y: select_part(part_sel + (-1 if e.shift_pressed else 1))
			KEY_K: set_tool("" if tool == "shape" else "shape")
			KEY_L: set_tool("" if tool == "select" else "select")
			KEY_F3: _toggle_guide_panel()
			KEY_O: set_section(not section_on)
			KEY_P: set_outlines((outlines + 1) % 3)
			KEY_N: toggle_smooth()
			KEY_F4: set_tool("" if tool == "wand" else "wand")
			KEY_F12: export_and_preview()
			KEY_Z:
				if e.shift_pressed:
					redo()
				else:
					mine = false
			KEY_J: toggle_point_here()
			KEY_F10: show_help(not _help.visible)
			KEY_F2: _toggle_panel()
			KEY_F7: toggle_catalog()
			KEY_HOME: zoom(0.85)
			KEY_END: zoom(1.0 / 0.85)
			_: mine = false
		if mine:
			get_viewport().set_input_as_handled()
			return
	super._unhandled_input(e)


func _process(dt: float) -> void:
	super._process(dt)
	if _ruler == null:
		return
	if _run_on and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_run_on = false
	run_step()
	if tool in ["sketch", "stud", "move"]:
		_ghost.visible = false
		_ghost_studs.visible = false
	if _shape_brush_on():
		_ghost.visible = false
		_ghost_studs.visible = false
	_stud_ghost_process()
	_explode_process()
	_rail_process()
	if _dragging:
		_drag_to = _cell
	_draw_tool()
	if _outlines_dirty:
		_draw_outlines()
	_poll_export()
	_poll_print()
	_size_marks_process()
	if _autosave_dirty and not _no_autosave and Time.get_ticks_msec() > _autosave_at:
		_autosave_dirty = false
		_autosave_at = Time.get_ticks_msec() + 4000
		recipe.save_to(AUTOSAVE)
	if _tris_due >= 0 and Time.get_ticks_msec() >= _tris_due:
		_tris_due = -1
		_tris = triangle_stats()
		_sync_shell_ui(false)
	if _shell_ui_part != part_sel:
		_shell_ui_part = part_sel
		_sync_shell_ui(true)
	_part_label.text = "part %d of %d: %s   (Y next, shift Y back)" % [
			part_sel + 1, part_names.size(), part_names[part_sel].to_upper()]
	_part_label.modulate = PART_COLOURS[part_sel % PART_COLOURS.size()]
	_part_label.position = Vector2((get_viewport().get_visible_rect().size.x - _part_label.size.x) * 0.5,
			get_viewport().get_visible_rect().size.y - 104)
	var vp := get_viewport().get_visible_rect().size
	_ruler.text = ruler_text()
	# Stacked on the part label, which sits on the hotbar: measured, not guessed.
	_ruler.reset_size()
	_ruler.position = Vector2(_rail_right(), vp.y - 136 - _ruler.size.y)
	if _panel.visible:
		_panel.position = Vector2(vp.x - _panel.size.x - 12, vp.y * 0.42)


func ruler_text() -> String:
	var size := BrickPalette.size_of(_archetype_name())
	var lines := PackedStringArray()
	lines.append("ghost: %d studs along, plate %d up, %d studs across; it is %s long" % [
			_cell.x, _cell.y, _cell.z, studs_text(size.x)])
	if recipe.size() > 0:
		var d: Vector3i = recipe.bounds()[1]
		lines.append("build: %d x %d studs, %d plates high -> %.0f x %.0f x %.1f mm print, %.0f x %.0f x %.0f mm real" % [
				d.x, d.z, d.y, d.x * PRINT_MM_PER_STUD, d.z * PRINT_MM_PER_STUD, d.y * PRINT_MM_PER_PLATE,
				d.x * PRINT_MM_PER_STUD * REAL_PER_PRINT, d.z * PRINT_MM_PER_STUD * REAL_PER_PRINT,
				d.y * PRINT_MM_PER_PLATE * REAL_PER_PRINT])
	var modes := PackedStringArray(["view: " + VIEWS[view]])
	if free_place:
		modes.append("FREE on the %s plane at %s (PgUp/PgDn)" % [work_plane, _plane_at_text()])
	else:
		modes.append("aiming at studs (Alt F frees)")
	if tool == "sketch":
		modes.append("BLOCK OUT %s: draw on the %s plane, %d studs thick" % [part_names[part_sel], work_plane, width_of(part_names[part_sel])])
	if mirror_on:
		modes.append("mirror at %s studs across" % _num(mirror_z))
	if measure_on:
		modes.append("MEASURE: click two points")
	if calibrating != null:
		modes.append("CALIBRATE: click point %d of 2 on the photo" % ((calibrating as Array).size() + 1))
	lines.append("   ".join(modes))
	if recipe.size() > 0:
		var counts := part_counts()
		var bits := PackedStringArray()
		for name in part_names:
			if counts[name] > 0:
				bits.append("%s%s %d" % [name, "~" if smooth_parts.has(name) else "", counts[name]])
		var d: Vector3i = recipe.bounds()[1]
		lines.append("parts: %s   (~ leaves smooth)   in the game %.2f m long" % [", ".join(bits),
				d.x * PRINT_MM_PER_STUD * REAL_PER_PRINT / 1000.0])
	var tris := triangles_text()
	if tris != "":
		lines.append(tris)
	if _export_check != "":
		lines.append(_export_check)
	if measure_on and measure_points.size() == 2:
		lines.append(measure_text(measure_points[0], measure_points[1]).replace("\n", "   "))
	lines.append("F10: how to start, and every key")
	return "\n".join(lines)


func _build_asset_tools() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ruler = Label.new()
	_style(_ruler, Color(1.0, 0.92, 0.6), 14)
	layer.add_child(_ruler)

	_measure_line = MeshInstance3D.new()
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(1.0, 0.85, 0.1)
	line_mat.no_depth_test = true
	_measure_line.material_override = line_mat
	add_child(_measure_line)
	_measure_label = Label3D.new()
	_measure_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_measure_label.no_depth_test = true
	_measure_label.font_size = 48
	_measure_label.pixel_size = 0.004
	_measure_label.modulate = Color(1.0, 0.92, 0.4)
	_measure_label.visible = false
	add_child(_measure_label)

	# An outline of the plane, not a sheet: face-on in the side view a sheet tinted all of it.
	_mirror_sheet = MeshInstance3D.new()
	var sheet_mat := StandardMaterial3D.new()
	sheet_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sheet_mat.albedo_color = Color(1.0, 0.3, 0.9)
	_mirror_sheet.material_override = sheet_mat
	_mirror_sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mirror_sheet.visible = false
	add_child(_mirror_sheet)
	_place_mirror_sheet()

	_build_panel(layer)


func _build_panel(layer: CanvasLayer) -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	layer.add_child(_panel)
	var box := VBoxContainer.new()
	_panel.add_child(box)
	var title := Label.new()
	title.text = "Reference photos (F2)"
	box.add_child(title)

	var row := HBoxContainer.new()
	box.add_child(row)
	var load_btn := Button.new()
	load_btn.text = "Load photo..."
	load_btn.pressed.connect(func() -> void: _file_dialog.popup_centered_ratio(0.6))
	row.add_child(load_btn)
	_photo_list = OptionButton.new()
	_photo_list.item_selected.connect(func(i: int) -> void:
		photo_sel = i
		_refresh_panel())
	row.add_child(_photo_list)

	_plane_list = OptionButton.new()
	for p in PLANES:
		_plane_list.add_item("on the %s plane" % p)
	_plane_list.item_selected.connect(func(i: int) -> void:
		if photo_sel >= 0:
			set_photo_plane(photo_sel, PLANES[i]))
	box.add_child(_plane_list)

	var cal := Button.new()
	cal.text = "Calibrate: click two points, type the real length"
	cal.pressed.connect(func() -> void:
		if photo_sel >= 0:
			calibrating = [])
	box.add_child(cal)

	var op_row := HBoxContainer.new()
	box.add_child(op_row)
	var op_label := Label.new()
	op_label.text = "opacity"
	op_row.add_child(op_label)
	_opacity = HSlider.new()
	_opacity.min_value = 0.05
	_opacity.max_value = 1.0
	_opacity.step = 0.05
	_opacity.custom_minimum_size = Vector2(160, 0)
	_opacity.value_changed.connect(func(v: float) -> void:
		if photo_sel >= 0:
			set_photo_opacity(photo_sel, v))
	op_row.add_child(_opacity)

	var grid := GridContainer.new()
	grid.columns = 4
	box.add_child(grid)
	for b in [["left", -1, 0, 0], ["right", 1, 0, 0], ["up", 0, 1, 0], ["down", 0, -1, 0],
			["nearer", 0, 0, 1], ["farther", 0, 0, -1], ["smaller", 0, 0, 0], ["bigger", 0, 0, 0]]:
		var btn := Button.new()
		btn.text = b[0]
		var name_: String = b[0]
		var along: float = b[1]
		var up: float = b[2]
		var out: float = b[3]
		btn.pressed.connect(func() -> void:
			if photo_sel < 0:
				return
			if name_ == "smaller" or name_ == "bigger":
				_scale_photo(photo_sel, 0.95 if name_ == "smaller" else 1.0 / 0.95)
			else:
				nudge_photo(photo_sel, along, up, out))
		grid.add_child(btn)

	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	_shown = CheckBox.new()
	_shown.text = "shown"
	_shown.toggled.connect(func(on: bool) -> void:
		if photo_sel >= 0:
			set_photo_shown(photo_sel, on))
	bottom.add_child(_shown)
	var rm := Button.new()
	rm.text = "Remove"
	rm.pressed.connect(func() -> void: remove_photo(photo_sel))
	bottom.add_child(rm)

	var depth := HBoxContainer.new()
	box.add_child(depth)
	for b in [["behind the build", "behind"], ["through its middle", "middle"]]:
		var btn := Button.new()
		btn.text = b[0]
		var where: String = b[1]
		btn.pressed.connect(func() -> void:
			if photo_sel >= 0:
				set_photo_depth(photo_sel, where))
		depth.add_child(btn)
	var grid_box := CheckBox.new()
	grid_box.text = "stud grid on the photo (side)"
	grid_box.toggled.connect(func(on: bool) -> void:
		photo_grid = on
		_draw_photo_grid())
	box.add_child(grid_box)
	var hint := Label.new()
	hint.text = "Alt + drag moves the photo.  Alt + wheel zooms a flat view."
	box.add_child(hint)
	_photo_info = Label.new()
	box.add_child(_photo_info)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	_file_dialog.file_selected.connect(func(path: String) -> void:
		load_photo(path, PLANES[maxi(_plane_list.selected, 0)]))
	layer.add_child(_file_dialog)

	_length_dialog = AcceptDialog.new()
	_length_dialog.title = "Real length between the two points"
	_length_edit = LineEdit.new()
	_length_edit.placeholder_text = "852 (mm on the real thing) or 53s (studs here)"
	_length_dialog.add_child(_length_edit)
	_length_dialog.confirmed.connect(func() -> void:
		var pts: Array = _length_dialog.get_meta("points", [])
		var mm := length_mm(_length_edit.text)
		if pts.size() == 2 and mm > 0.0:
			calibrate(photo_sel, pts[0], pts[1], mm))
	layer.add_child(_length_dialog)
	_refresh_panel()


func _toggle_panel() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible and _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	_refresh_panel()



## Open or close the parts catalogue (F7). It reads the part folders each time it opens, so
## a part just saved is in it.
func toggle_catalog() -> void:
	if _catalog_panel == null:
		_catalog_panel = PartCatalogPanel.new()
		_catalog_panel.visible = false
		_catalog_panel.position = Vector2(RAIL_W + 24, 60)
		_catalog_panel.part_picked.connect(func(r: PartRecord) -> void:
			var why := try_part(r)
			if why != "":
				_export_check = "parts: " + why)
		_ruler.get_parent().add_child(_catalog_panel)
	_catalog_panel.visible = not _catalog_panel.visible
	if not _catalog_panel.visible:
		return
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	var cat := PartCatalog.load_all()
	if not parts_dir().begins_with(PartCatalog.OFFICIAL_DIR) and parts_dir() != PartCatalog.CUSTOM_DIR:
		cat.load_dir(parts_dir(), "custom")   # a test's own folder
	_catalog_panel.set_catalog(cat)
	_aim_catalog(cat)


## Point the catalogue's Fits at the part being built: the socket it goes in, on the saved
## part it hangs from. Nothing to fit to for the body, a build that is not a gun, or a host
## not saved yet.
func _aim_catalog(cat: PartCatalog) -> void:
	var part := String(part_names[part_sel]) if part_sel < part_names.size() else ""
	var sockets: Dictionary = PartStandards.plan("gun").get("sockets", {})
	var path := part if sockets.has(part) else "barrel/" + part
	if recipe.kind != "gun" or part == "body" or not sockets.has(path):
		_catalog_panel.set_fit_target(null, "", "")
		return
	var host_name := path.get_base_dir() if path.contains("/") else "body"
	var host: PartRecord = tried.get(host_name, cat.get_part(String(part_ids.get(host_name, ""))))
	_catalog_panel.set_fit_target(host, path, "gun")


func _scale_photo(i: int, f: float) -> void:
	var p: Dictionary = photos[i]
	p.mpp = float(p.mpp) * f
	_fit_photo(p)
	_store_asset_meta()
	_refresh_panel()


func _calibrate_click() -> void:
	var ray := _mouse_ray()
	var p = ray_on_photo(photo_sel, ray[0], ray[1])
	if p == null:
		return
	(calibrating as Array).append(p)
	if (calibrating as Array).size() < 2:
		return
	_length_dialog.set_meta("points", calibrating)
	calibrating = null
	_length_edit.text = ""
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	_length_dialog.popup_centered(Vector2i(360, 90))
	_length_edit.grab_focus()


func _refresh_panel() -> void:
	if _photo_list == null:
		return
	_photo_list.clear()
	for p in photos:
		_photo_list.add_item((p.path as String).get_file())
	if photo_sel < 0:
		_photo_info.text = "no photo"
		return
	_photo_list.select(photo_sel)
	var p: Dictionary = photos[photo_sel]
	_plane_list.select(PLANES.find(p.plane))
	_opacity.set_value_no_signal(float(p.opacity))
	_shown.set_pressed_no_signal(bool(p.shown))
	var w := float(p.px.x) * float(p.mpp) / BrickPalette.STUD_M
	_photo_info.text = "%d x %d px, %.1f studs wide\n1 px = %.2f mm real" % [p.px.x, p.px.y, w,
			float(p.mpp) / BrickPalette.STUD_M * PRINT_MM_PER_STUD * REAL_PER_PRINT]


# ---------------------------------------------------------------------------
# What is saved: the recipe's meta.asset
# ---------------------------------------------------------------------------

func _store_asset_meta() -> void:
	var list := []
	for p in photos:
		var c: Vector3 = p.centre
		list.append({"path": p.path, "plane": p.plane, "px": [p.px.x, p.px.y], "mpp": p.mpp,
				"centre": [c.x, c.y, c.z], "opacity": p.opacity, "shown": p.shown})
	var pts := []
	for q in points:
		pts.append(q.duplicate())
	var gds := []
	for g in guides:
		var o: Vector3 = g.offset
		gds.append({"path": g.path, "real_mm": g.real_mm, "offset": [o.x, o.y, o.z],
				"turn": g.turn, "opacity": g.opacity, "adjust": _xf_list(g.get("adjust", Transform3D()))})
	recipe.meta["asset"] = {"photos": list, "mirror": {"on": mirror_on, "z": mirror_z},
			"parts": {"names": Array(part_names), "of": Array(part_of)}, "points": pts, "guides": gds,
			"smooth": Array(smooth_parts), "muzzle": muzzle_end, "part_width": part_width.duplicate(),
			"sketches": sketches, "part_bricks": part_bricks, "studs": extra_studs, "curves": curve_level,
			"shells": shells, "sdf": _sdf_meta, "sculpt": {"state": sculpt_state, "cells": Array(_sdf_cells),
			"stash": _sdf_stash, "shell_cells": Array(_sdf_shell)}, "models": _models_meta(),
			"part_ids": part_ids, "part_hashes": part_hashes, "part_revs": part_revs}   # not a copy: this runs on every edit, and a save writes it out as it is


func _restore_asset_meta() -> void:
	var a: Dictionary = recipe.meta.get("asset", {})
	part_ids = (a.get("part_ids", {}) as Dictionary).duplicate()
	part_hashes = (a.get("part_hashes", {}) as Dictionary).duplicate()
	part_revs = (a.get("part_revs", {}) as Dictionary).duplicate()
	var parts: Dictionary = a.get("parts", {})
	if parts.has("names") and not (parts.names as Array).is_empty():
		part_names = PackedStringArray(parts.names)
	part_of = PackedInt32Array()
	for v in parts.get("of", []):
		part_of.append(int(v))
	_reconcile_parts()
	points = []
	for q in a.get("points", []):
		points.append(q)
	_draw_points()
	smooth_parts = PackedStringArray(a.get("smooth", []))
	part_width = {}
	var widths: Dictionary = a.get("part_width", {})
	for k in widths:
		part_width[k] = int(widths[k])
	sketches = (a.get("sketches", {}) as Dictionary).duplicate(true)
	part_bricks = (a.get("part_bricks", {}) as Dictionary).duplicate(true)
	extra_studs = (a.get("studs", []) as Array).duplicate(true)
	_draw_studs()
	_part_vol.clear()
	_sketch_seq = 0
	for k in sketches:
		var sk: Dictionary = sketches[k]
		# Saved before a part's sketches were one thing: each laid its own bricks.
		if sk.has("bricks"):
			var list: Array = part_bricks.get_or_add(String(sk.part), [])
			list.append_array(sk.bricks)
			sk.erase("bricks")
		if not sk.has("n"):
			sk["n"] = _sketch_seq
		_sketch_seq = maxi(_sketch_seq, int(sk.n) + 1)
	_sketch_cache.clear()
	curve_level = int(a.get("curves", 2))
	_sdf_meta = a.get("sdf", {})
	var sst: Dictionary = a.get("sculpt", {})
	sculpt_state = String(sst.get("state", "sdf"))
	_sdf_cells = PackedInt32Array(sst.get("cells", []))
	_sdf_stash = (sst.get("stash", []) as Array).duplicate(true)
	_sdf_shell = PackedInt32Array(sst.get("shell_cells", []))
	if sculpt != null:
		sculpt.set_parts(part_names.size())
		sculpt.load_meta(_sdf_meta)
		sculpt.visible = sculpt_state == "sdf"
	shells = (a.get("shells", {}) as Dictionary).duplicate(true)
	for part in _shell_nodes.keys():
		_shell_mesh(String(part), {})
	for part in shells:
		_refresh_shell(String(part))
	muzzle_end = String(a.get("muzzle", "-x"))
	for g in a.get("guides", []):
		var i := load_guide(String(g.path), float(g.real_mm))
		if i >= 0:
			guides[i].offset = Vector3(float(g.offset[0]), float(g.offset[1]), float(g.offset[2]))
			guides[i].turn = int(g.get("turn", 0))
			guides[i].opacity = float(g.get("opacity", 0.35))
			if g.get("adjust") is Array and (g.adjust as Array).size() == 12:
				guides[i].adjust = _list_xf(g.adjust)
			_fit_guide(guides[i])
	_restore_models(a.get("models", []))
	var m: Dictionary = a.get("mirror", {})
	mirror_z = float(m.get("z", mirror_z))
	set_mirror(bool(m.get("on", false)))
	for d in a.get("photos", []):
		var img := Image.load_from_file(String(d.path)) if FileAccess.file_exists(String(d.path)) else null
		if img == null or img.is_empty():
			# Keep its place and size, so it saves back as it was: a grey stand-in.
			img = Image.create(maxi(int(d.px[0]), 1), maxi(int(d.px[1]), 1), false, Image.FORMAT_RGBA8)
			img.fill(Color(0.5, 0.5, 0.5, 0.5))
			push_warning("asset workshop: photo not found, shown grey: %s" % d.path)
		var i := add_photo_image(img, String(d.path), String(d.plane))
		var p: Dictionary = photos[i]
		p.mpp = float(d.mpp)
		p.centre = Vector3(float(d.centre[0]), float(d.centre[1]), float(d.centre[2]))
		p.opacity = float(d.opacity)
		p.shown = bool(d.shown)
		_fit_photo(p)
	_store_asset_meta()
	_refresh_panel()


func _reset_space() -> void:
	super._reset_space()
	if not tried.is_empty():
		untry_all()
	part_of = PackedInt32Array()
	points = []
	if _points_root != null:
		_draw_points()
	for g in guides:
		(g.node as Node).queue_free()
	guides.clear()
	if _placed != null:
		select_model(null)
	for m in models:
		(m.node as Node).queue_free()
	models.clear()
	selection.clear()
	smooth_parts = PackedStringArray()
	_redo.clear()
	_edit_groups.clear()
	_deleted.clear()
	sketches.clear()
	shells.clear()
	for part in _shell_nodes.keys():
		_shell_mesh(String(part), {})
	part_bricks.clear()
	if sculpt != null:
		sculpt.form.clear()
		sculpt.remesh()
		sculpt.visible = true
	sculpt_state = "sdf"
	_sdf_cells = PackedInt32Array()
	_sdf_stash = []
	_sdf_shell = PackedInt32Array()
	_sdf_meta = {}
	extra_studs.clear()
	_draw_studs()
	_forget_part_ids()
	_part_vol.clear()
	_sketch_cache.clear()
	for p in photos:
		(p.node as Node).queue_free()
	photos.clear()
	photo_sel = -1
	measure_points.clear()
	if _measure_line != null:
		_draw_measure()


const ASSET_QUICK_SAVE := "user://asset_workshop_quick.json"
## What is made here: the asset kinds, and furniture and items for rooms -- the item
## library is shared with the building workshop, so the generator furnishes rooms from
## what is saved here (Docs/AssetWorkshop.md, "Furniture and items").
const ASSET_KINDS := ["gun", "mech", "item"]


## A build here is one of the asset kinds; anything else (a build saved before guns had a
## library) becomes a gun.
func _set_asset_kind(k: String) -> void:
	recipe.kind = k if ASSET_KINDS.has(k) else "gun"
	if _menu != null:
		_menu.set_kind(recipe.kind)


## Asset > Make a gun / a mech / furniture or an item: what this build is saved as.
func set_asset_kind(k: String) -> void:
	_set_asset_kind(k)
	_dirty = true
	print("[asset workshop] making %s: Save As files it in %s" % [
			"furniture or an item" if recipe.kind == "item" else "a " + recipe.kind,
			BuildRecipe.player_dir(recipe.kind)])


func _load_recipe(r: BuildRecipe) -> void:
	# The workshop's load ends in an edit, and an edit saves this scene's state into the
	# recipe: while loading, that state is still the last build's, so it waits.
	_loading = true
	super._load_recipe(r)
	_loading = false
	_set_asset_kind(recipe.kind)
	_restore_asset_meta()


# ---------------------------------------------------------------------------
# Phase 2: part toolbars
# ---------------------------------------------------------------------------

func _setup_parts() -> void:
	if part_names.is_empty():
		part_names = PackedStringArray(GUN_PARTS)
	# Its own file: switching toolbars must never write over the main workshop's hotbar.
	_hotbar.save_path = "user://asset_workshop_hotbar.json"
	if FileAccess.file_exists(toolbars_save):
		var d = JSON.parse_string(FileAccess.get_file_as_string(toolbars_save))
		if d is Dictionary:
			toolbars = d
	_part_label = Label.new()
	_style(_part_label, Color.WHITE, 16)
	(_ruler.get_parent() as Node).add_child(_part_label)
	_points_root = Node3D.new()
	add_child(_points_root)
	sculpt = AssetSculpt.new()
	add_child(sculpt)
	sculpt.place(world.get_chunk_transform(asm.frames[0]), BrickPalette.STUD_M / BrickWorld.ticks_per_stud())
	sculpt.set_parts(part_names.size())
	_load_interfaces()
	_build_point_panel(_ruler.get_parent() as CanvasLayer)
	_build_phase3(_ruler.get_parent() as CanvasLayer)
	_build_rail(_ruler.get_parent() as CanvasLayer)
	_build_preview(_ruler.get_parent() as CanvasLayer)
	_build_help(_ruler.get_parent() as CanvasLayer)
	var env := OS.get_environment("BRICKCITY_BLENDER")
	if env != "":
		blender_path = env
	_reconcile_parts()
	_load_toolbar(part_names[part_sel])


## Make part `i` current: its toolbar comes up, and the bricks laid from now are its.
func select_part(i: int) -> void:
	toolbars[part_names[part_sel]] = _hotbar.slots.duplicate(true)
	part_sel = posmod(i, part_names.size())
	_load_toolbar(part_names[part_sel])
	_outlines_dirty = true
	if _width_spin != null:
		_width_spin.set_value_no_signal(width_of(part_names[part_sel]))
	if _catalog_panel != null and _catalog_panel.visible:
		_aim_catalog(_catalog_panel.catalog)
	var f := FileAccess.open(toolbars_save, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(toolbars))


func _load_toolbar(part: String) -> void:
	if toolbars.has(part):
		var slots: Array = toolbars[part]
		for k in mini(slots.size(), _hotbar.slots.size()):
			_hotbar.slots[k] = (slots[k] as Array).duplicate()
		_hotbar._refresh()
	_hotbar.select(_hotbar.selected)


## Keep a tag for every brick: one for each brick added since (the current part's) and
## none for a brick taken away. A delete says which brick it took; anything else that
## shortens the recipe (undo) takes from the end, as it does.
func _reconcile_parts() -> void:
	var n := recipe.size()
	if _removing >= 0 and _removing < part_of.size() and part_of.size() == n + 1:
		part_of.remove_at(_removing)
	_removing = -1
	while part_of.size() > n:
		part_of.remove_at(part_of.size() - 1)
	while part_of.size() < n:
		part_of.append(part_sel)


func _after_edit() -> void:
	super._after_edit()
	if _loading:
		return
	_reconcile_parts()
	if _batch:
		return   # the batch's own closing _after_edit does the rest, once
	_pick_dirty = true
	_display_dirty = true
	_store_asset_meta()
	_outlines_dirty = true
	_autosave_dirty = true
	_tris_due = Time.get_ticks_msec() + TRIS_SETTLE_MS
	# The grid and the mirror sheet are drawn round the build: they follow it.
	var vb := view_box()
	if vb != _view_drawn:
		_view_drawn = vb
		_draw_work_plane()
		_place_mirror_sheet()
	if recipe.size() == 0:
		_ensure_start_brick.call_deferred()


func _delete_ray(from: Vector3, dir: Vector3) -> bool:
	var hit := _first_hit(from, dir)
	var took = null
	if not hit.is_empty():
		_removing = _recipe_id_at(asm.frames.find(hit.frame), hit.block)
		if _removing >= 0:
			took = _brick_info(_removing)
	var done := super._delete_ray(from, dir)
	if not done:
		_removing = -1
	elif took != null:
		# The workshop drops a deleted brick from its edits; this puts the delete in as an
		# edit of its own, so Z can lay it back.
		_edits.append("delete")
		_deleted.append(took)
		if not _redoing:
			_redo.clear()
	return done


func _brick_info(i: int) -> Dictionary:
	return {"arch": recipe.part_of(i), "cell": recipe.cell_of(i), "colour": recipe.colour_of(i),
			"mat": recipe.material_of(i), "tag": part_of[i] if i < part_of.size() else part_sel}


## The upright-grid brick of this part at this cell, by recipe index, or -1. Found
## through the world's own cell lookup, not by walking the recipe.
func find_brick(arch: String, cell: Vector3i) -> int:
	var size := BrickPalette.size_of(arch)
	for dx in size.x:
		for dy in size.y:
			for dz in size.z:
				var block := world.block_at(chunk, cell + Vector3i(dx, dy, dz))
				if block < 0:
					continue
				var i := _recipe_id_at(0, block)
				if i >= 0 and recipe.cell_of(i) == cell and recipe.part_of(i) == arch:
					return i
	return -1


## Take a brick up as RMB would, found by part and cell. True if it went.
func remove_brick(arch: String, cell: Vector3i) -> bool:
	var i := find_brick(arch, cell)
	return i >= 0 and take_brick(i)


## Take up the brick at recipe index `i` as RMB does -- world, recipe, edits and paint
## renumbered together (`_remove_rid`) -- and keep it, so Z can lay it back.
## As the workshop's, and edits being gathered into one undo keep count: an edit from
## before them dropped out of the list moves where they start.
func _drop_edit(kind: String, n: int) -> void:
	for i in _edits.size():
		if _edits[i] != kind:
			continue
		if n == 0:
			_edits.remove_at(i)
			if not _gather.is_empty() and i < int(_gather.start):
				_gather.start = int(_gather.start) - 1
			return
		n -= 1


func take_brick(i: int) -> bool:
	if i < 0 or i >= recipe.size():
		return false
	var took := _brick_info(i)
	_removing = i
	_remove_rid(i)
	_after_edit()
	_edits.append("delete")
	_deleted.append(took)
	if not _redoing:
		_redo.clear()
	return true


## How many bricks each part has.
func part_counts() -> Dictionary:
	var out := {}
	for name in part_names:
		out[name] = 0
	for i in part_of:
		out[part_names[i]] += 1
	return out


# ---------------------------------------------------------------------------
# Phase 2: holding LMB lays a run
# ---------------------------------------------------------------------------

## While a run is held, the ghost stays on the plane it started on, as with E.
func _hold_lock(on: bool) -> void:
	super._hold_lock(on or _run_on or _dragging)


## Lay the held brick where the ghost has moved to, if it fits there -- once the click
## has become a drag: a hand that shook a little while clicking laid two bricks.
func run_step() -> void:
	if not _run_on or _cell == _run_last:
		return
	if _run_moved < RUN_START_PX or Time.get_ticks_msec() - _run_press_ms < RUN_START_MS:
		return
	_run_last = _cell
	if _valid:
		_place()


# ---------------------------------------------------------------------------
# Phase 2: connection points
# ---------------------------------------------------------------------------

func _load_interfaces() -> void:
	var path := "res://Docs/Parts/standards.json"
	if not FileAccess.file_exists(path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if d is Dictionary:
		for k in (d.get("gun_interfaces", {}) as Dictionary):
			if k != "note":
				_interfaces[k] = d.gun_interfaces[k]
		if d.get("held_grip") is Dictionary:
			for k in ["length_min", "fore_aft", "thick"]:
				if d.held_grip.has(k):
					_grip_std[k] = d.held_grip[k]


## The lattice point under the ghost: its first stud line along, the plate it stands on,
## the middle of it across.
func point_under_ghost() -> Array:
	var size := BrickPalette.size_of(_archetype_name())
	return [_cell.x, _cell.y, _cell.z + size.z * 0.5]


## A mount or socket where the ghost is, for the current part; or, if one is there
## already, take it away. Returns true if one was added.
func toggle_point(at: Array, kind: String, slot: String, iface: String, dir: Array = []) -> bool:
	for i in points.size():
		if points[i].at == at:
			points.remove_at(i)
			_draw_points()
			_store_asset_meta()
			return false
	var q := {"part": part_names[part_sel], "kind": kind, "slot": slot, "interface": iface, "at": at}
	if not dir.is_empty():
		q["dir"] = dir   # on a stud: the way the stud faces
	points.append(q)
	_draw_points()
	_store_asset_meta()
	return true


func toggle_point_here() -> void:
	var at := point_under_ghost()
	for q in points:
		if q.at == at:
			toggle_point(at, "", "", "")
			return
	_point_panel.visible = true
	_point_panel.set_meta("at", at)
	_point_panel.set_meta("dir", [])
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	_fill_point_ifaces()


func _build_point_panel(layer: CanvasLayer) -> void:
	_point_panel = PanelContainer.new()
	_point_panel.visible = false
	_point_panel.position = Vector2(RAIL_W + 24, 300)
	layer.add_child(_point_panel)
	var box := VBoxContainer.new()
	_point_panel.add_child(box)
	var title := Label.new()
	title.text = "Connection point (J)"
	box.add_child(title)
	_point_kind = OptionButton.new()
	for k in ["mount", "socket"]:
		_point_kind.add_item(k)
	box.add_child(_point_kind)
	_point_slot = OptionButton.new()
	for k in GUN_PARTS:
		_point_slot.add_item(k)
	_point_slot.item_selected.connect(func(_i: int) -> void: _fill_point_ifaces())
	box.add_child(_point_slot)
	_point_iface = OptionButton.new()
	box.add_child(_point_iface)
	var row := HBoxContainer.new()
	box.add_child(row)
	var ok := Button.new()
	ok.text = "Place"
	ok.pressed.connect(func() -> void:
		if _point_iface.item_count > 0:
			toggle_point(_point_panel.get_meta("at"), _point_kind.get_item_text(_point_kind.selected),
					_point_slot.get_item_text(_point_slot.selected),
					_point_iface.get_item_text(_point_iface.selected), _point_panel.get_meta("dir", []))
		_point_panel.visible = false)
	row.add_child(ok)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: _point_panel.visible = false)
	row.add_child(cancel)


## The interfaces of the chosen slot: a mount and a socket join only on the same one.
func _fill_point_ifaces() -> void:
	_point_iface.clear()
	var slot := _point_slot.get_item_text(maxi(_point_slot.selected, 0))
	for k in _interfaces:
		if String(_interfaces[k].get("slot", "")) == slot:
			_point_iface.add_item(k)


func _draw_points() -> void:
	for c in _points_root.get_children():
		c.queue_free()
	for q in points:
		var at: Array = q.at
		var where := Vector3(float(at[0]) * BrickPalette.STUD_M, float(at[1]) * BrickPalette.PLATE_M,
				float(at[2]) * BrickPalette.STUD_M) + part_offset(String(q.part))
		var mark := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.09
		m.height = 0.18
		m.radial_segments = 8
		m.rings = 4
		mark.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mat.albedo_color = Color(0.3, 1.0, 0.4) if q.kind == "mount" else Color(1.0, 0.35, 0.3)
		mark.material_override = mat
		mark.position = where
		_points_root.add_child(mark)
		var label := Label3D.new()
		label.text = "%s %s\n%s" % [q.part, q.kind, q.interface]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.pixel_size = 0.003
		label.font_size = 40
		label.position = where + Vector3.UP * 0.25
		_points_root.add_child(label)


# ---------------------------------------------------------------------------
# Phase 3: the packer -- cells to bricks
# ---------------------------------------------------------------------------

## The plain parts a fill is made of: plates and bricks, each way round, biggest first.
## [archetype name, Vector3i size in studs along, plates up, studs across].
func fill_parts() -> Array:
	var out := []
	for part in _parts():
		var name := String(part)
		if not (name.begins_with("plate_") or name.begins_with("brick_")) 				or name in ["plate_10x10", "plate_5x10", "plate_5x5"]:
			continue
		var seen := {}
		for yaw in 2:
			var arch := BrickPalette.variant_name(name, yaw, false)
			var size := BrickPalette.size_of(arch)
			if not seen.has(size) and palette.has(arch):
				seen[size] = true
				out.append([arch, size])
	out.sort_custom(func(a: Array, b: Array) -> bool:
		var va: int = a[1].x * a[1].y * a[1].z
		var vb: int = b[1].x * b[1].y * b[1].z
		return va > vb)
	return out


## Cover `cells` (Vector3i -> true) with parts, bottom up. Clean takes the biggest part
## that fits at each place; random takes any that fits, so sizes mix. Bricks start only
## on shared courses, so neighbouring columns line up to be bridged; each layer grows
## from the other corner to the one under it, so seams do not stack.
## Returns [[archetype name, min cell]].
func pack_cells(cells: Dictionary, random: bool = false, free: Dictionary = {}, course: int = 1 << 30,
		z_width: int = 0) -> Array:
	# Cells something is already built in are not the fill's: packed as if empty, the big
	# parts that hit what is there are refused when laid, and leave holes round it.
	# `free`: cells built in now that will be empty when this is laid.
	var left := {}
	for c in cells:
		if free.has(c) or not world.is_solid(chunk, c):
			left[c] = true
	var parts := fill_parts()
	var out := []
	if left.is_empty():
		return out
	var ys := {}
	for c in left:
		ys[c.y] = true
	var layers := ys.keys()
	layers.sort()
	# `course`: the layer courses count from, when it is not the lowest packed here (a
	# part packed again in places keeps its courses).
	var base: int = layers[0] if course == 1 << 30 else course
	for y in layers:
		var flip: bool = posmod(y - base, 2) == 1
		var here := []
		for c in left:
			if c.y == y:
				here.append(c)
		here.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			if a.x != b.x:
				return (a.x > b.x) if flip else (a.x < b.x)
			return (a.z > b.z) if flip else (a.z < b.z))
		for c in here:
			if not left.has(c):
				continue
			var fits := []
			for pe in parts:
				var size: Vector3i = pe[1]
				if size.y > 1 and posmod(y - base, 3) != 0:
					continue
				# `z_width`: only parts this many studs across (a symmetric Convert's middle).
				if z_width > 0 and size.z != z_width:
					continue
				var at := Vector3i(c.x - size.x + 1 if flip else c.x, y, c.z - size.z + 1 if flip else c.z)
				if _box_in(left, at, size):
					fits.append([pe[0], at, size])
			if fits.is_empty():
				continue
			var pick: Array = fits[_rng.randi_range(0, fits.size() - 1)] if random else fits[0]
			for dx in pick[2].x:
				for dy in pick[2].y:
					for dz in pick[2].z:
						left.erase(pick[1] + Vector3i(dx, dy, dz))
			out.append([pick[0], pick[1]])
	return out


static func _box_in(cells: Dictionary, at: Vector3i, size: Vector3i) -> bool:
	for dx in size.x:
		for dy in size.y:
			for dz in size.z:
				if not cells.has(at + Vector3i(dx, dy, dz)):
					return false
	return true


## Lay a named part at a cell in the upright grid, in the held colour and material, as
## a click would. Returns false if it does not fit there.
## `af`: lay it in that frame's grid (`asm.frames`; a sideways one), at a cell of that grid.
func place_named(arch: String, cell: Vector3i, colour: int = -1, mat: int = -1, af: int = 0) -> bool:
	if not palette.has(arch) or (af == 0 and _frame != 0) or af < 0 or af >= asm.frames.size():
		return false
	var f: int = asm.frames[af]
	var id: int = palette[arch]
	if world.would_connect(f, cell, id) < 0 or not asm.can_place(f, cell, id):
		return false
	var c := _colour if colour < 0 else colour
	var m := _mat if mat < 0 else mat
	var placed := asm.place(f, cell, id, c)
	if placed < 0:
		return false
	if m != 0:
		world.set_block_material(f, placed, m)
	if not _redoing:
		_redo.clear()
	recipe.add(arch, cell, c, _recipe_frame_for(af), _role, m)
	_placed_at.append([af, placed])
	_edits.append("brick")
	_after_edit()
	return true


## Fill cells with bricks, as one edit: the mesh is rebuilt once, at the end.
func fill_cells(cells: Dictionary, random: bool = false, group: bool = true) -> int:
	var laid := 0
	_batch = true
	for pc in pack_cells(cells, random):
		if place_named(pc[0], pc[1]):
			laid += 1
	_batch = false
	_after_edit()
	if group:
		_group(laid)
	return laid


func _group(n: int) -> void:
	if n > 1:
		_edit_groups.append({"end": _edits.size(), "n": n})


# ---------------------------------------------------------------------------
# Phase 3: shapes and select
# ---------------------------------------------------------------------------

## The cells of a shape between two cells of one plane: `kind` is box, cylinder (an
## upright ellipse), sphere (an ellipsoid as tall as it is wide) or wedge (falling from
## full height to one plate along the gun).
func shape_cells(kind: String, a: Vector3i, b: Vector3i, plates: int) -> Dictionary:
	var lo := Vector3i(mini(a.x, b.x), a.y, mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), a.y, maxi(a.z, b.z))
	var w := hi.x - lo.x + 1
	var d := hi.z - lo.z + 1
	var tall := plates
	if kind == "sphere":
		tall = maxi(1, int(round(maxf(w, d) * BrickPalette.STUD_M / BrickPalette.PLATE_M)))
	var out := {}
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.z, hi.z + 1):
			var u := (x + 0.5 - lo.x) / w * 2.0 - 1.0
			var v := (z + 0.5 - lo.z) / d * 2.0 - 1.0
			for k in tall:
				var t := (k + 0.5) / tall * 2.0 - 1.0
				var inside := true
				match kind:
					"cylinder":
						inside = u * u + v * v <= 1.0
					"sphere":
						inside = u * u + v * v + t * t <= 1.0
					"wedge":
						inside = k < maxi(1, int(ceil(tall * (1.0 - (x - lo.x) / float(w)))))
				if inside:
					out[Vector3i(x, lo.y + k, z)] = true
	return out


func set_tool(t: String) -> void:
	_set_down()
	tool = t
	_dragging = false
	_shape_box.visible = t == "shape"
	_select_box.visible = t == "select"
	if t == "" :
		selection.clear()
	_sketch.clear()
	_sketch_box.visible = t == "sketch"
	if t != "" and _painting:
		_set_painting(false)
	_outlines_dirty = true


func _finish_drag() -> void:
	if tool == "shape":
		fill_cells(shape_cells(shape_kind, _drag_from, _drag_to, shape_plates), shape_fill == "random")
	elif tool == "select":
		select_box(_drag_from, _drag_to)


## Every brick of the upright grid whose corner is over the rectangle, any height.
func select_box(a: Vector3i, b: Vector3i) -> void:
	selection.clear()
	for i in recipe.size():
		if recipe.frame_of(i) != 0:
			continue
		var c := recipe.cell_of(i)
		if c.x >= mini(a.x, b.x) and c.x <= maxi(a.x, b.x) and c.z >= mini(a.z, b.z) and c.z <= maxi(a.z, b.z):
			selection.append(i)
	_outlines_dirty = true


## Delete the selection, top first, each as RMB would (so its part tag goes with it).
func delete_selection() -> int:
	var ids := selection.duplicate()
	ids.sort_custom(func(a: int, b: int) -> bool: return recipe.cell_of(a).y > recipe.cell_of(b).y)
	var cells := []
	for i in ids:
		var size := BrickPalette.size_of(recipe.part_of(i))
		var c := recipe.cell_of(i)
		cells.append(Vector3((c.x + size.x * 0.5) * BrickPalette.STUD_M, (c.y + 0.5) * BrickPalette.PLATE_M,
				(c.z + size.z * 0.5) * BrickPalette.STUD_M))
	selection.clear()
	var gone := 0
	for at in cells:
		if _delete_ray(at, Vector3.DOWN):
			gone += 1
	_group(gone)
	_outlines_dirty = true
	return gone


## The cells the selection's plain bricks fill, and the colour most of them are.
func _selection_cells() -> Array:
	var cells := {}
	var colours := {}
	for i in selection:
		var name := recipe.part_of(i)
		if not (name.begins_with("plate_") or name.begins_with("brick_")):
			continue
		var size := BrickPalette.size_of(name)
		var c := recipe.cell_of(i)
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					cells[c + Vector3i(dx, dy, dz)] = true
		colours[recipe.colour_of(i)] = colours.get(recipe.colour_of(i), 0) + 1
	var best := _colour
	for k in colours:
		if colours[k] > colours.get(best, 0):
			best = k
	return [cells, best]


## Lay the selection's plain bricks again, clean or random. Returns bricks before, after.
func repack_selection(random: bool = false) -> Array:
	var got := _selection_cells()
	var before := selection.size()
	selection = selection.filter(func(i: int) -> bool:
		return recipe.part_of(i).begins_with("plate_") or recipe.part_of(i).begins_with("brick_"))
	delete_selection()
	var keep := _colour
	_colour = got[1]
	var after := fill_cells(got[0], random)
	_colour = keep
	return [before, after]


## Give the selection to the current part.
func assign_selection() -> void:
	for i in selection:
		if i < part_of.size():
			part_of[i] = part_sel
	_store_asset_meta()
	_outlines_dirty = true


## Copy the selection so its lowest corner lands on the ghost; with `move`, the original
## goes. Returns how many bricks were laid.
func copy_selection_to_ghost(move: bool = false) -> int:
	if selection.is_empty():
		return 0
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	for i in selection:
		var c := recipe.cell_of(i)
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
	var off := _cell - lo
	var items := []
	for i in selection:
		items.append([recipe.part_of(i), recipe.cell_of(i) + off, recipe.colour_of(i), recipe.material_of(i)])
	if move:
		delete_selection()
	var laid := 0
	_batch = true
	items.sort_custom(func(a: Array, b: Array) -> bool: return a[1].y < b[1].y)
	for it in items:
		if place_named(it[0], it[1], it[2], it[3]):
			laid += 1
	_batch = false
	_after_edit()
	_group(laid)
	return laid


# ---------------------------------------------------------------------------
# Phase 3: guide models
# ---------------------------------------------------------------------------

## Load a model to build inside: glTF or FBX, see-through, never built on, never exported.
## `real_mm` is how long its longest side is on the real thing. Returns its index.
func load_guide(path: String, real_mm: float) -> int:
	# One mesh in the model's frame, a skinned one posed (ModelMesh): drawn, sized and
	# stamped from the same vertices.
	var mesh := ModelMesh.read(path)
	if mesh == null:
		return -1
	var holder := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	holder.add_child(mi)
	add_child(holder)
	var box := mesh.get_aabb()
	var g := {"path": path, "real_mm": real_mm, "offset": Vector3.ZERO, "turn": 0, "opacity": 0.35,
			"node": holder, "box": box, "adjust": Transform3D()}
	guides.append(g)
	_fit_guide(g)
	_store_asset_meta()
	_refresh_guide_panel()
	return guides.size() - 1


## Size, turn, place and shade a guide: its longest side to `real_mm` at quarter scale,
## standing on the plate, centred on the mirror plane, then `offset` in studs, then the
## gizmo's `adjust` (Docs/AssetWorkshop.md, "Pick and move").
func _fit_guide(g: Dictionary) -> void:
	var holder: Node3D = g.node
	var box: AABB = g.box
	if maxf(box.size.x, maxf(box.size.y, box.size.z)) <= 0.0:
		return
	holder.transform = (g.get("adjust", Transform3D()) as Transform3D) * _guide_fit_xf(g)
	_shade_guide(holder, float(g.opacity))
	if is_same(_placed.get("guide"), g):
		_placed.xf = holder.transform
		_gizmo.position = _placed_centre()


## Where the panel's fit puts a guide, before the gizmo's adjust.
func _guide_fit_xf(g: Dictionary) -> Transform3D:
	var box: AABB = g.box
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	var k := float(g.real_mm) / (PRINT_MM_PER_STUD * REAL_PER_PRINT) * BrickPalette.STUD_M / longest
	var turn := Basis(Vector3.UP, int(g.turn) * PI * 0.5)
	var centre := box.get_center() * k
	var bottom := box.position.y * k
	var mid := plate_studs * BrickPalette.STUD_M * 0.5
	var at := Vector3(mid, BrickPalette.PLATE_M - bottom, mirror_z * BrickPalette.STUD_M) - turn * Vector3(centre.x, 0.0, centre.z)
	return Transform3D(turn.scaled(Vector3.ONE * k), at + (g.offset as Vector3) * BrickPalette.STUD_M)


static func _xf_list(x: Transform3D) -> Array:
	return [x.basis.x.x, x.basis.x.y, x.basis.x.z, x.basis.y.x, x.basis.y.y, x.basis.y.z,
			x.basis.z.x, x.basis.z.y, x.basis.z.z, x.origin.x, x.origin.y, x.origin.z]


static func _list_xf(f: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]), Vector3(f[6], f[7], f[8])),
			Vector3(f[9], f[10], f[11]))


func _shade_guide(n: Node, opacity: float) -> void:
	if n is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.4, 0.85, 1.0, opacity)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		(n as MeshInstance3D).material_override = mat
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_shade_guide(c, opacity)


## The guide's size as placed, in workshop metres.
func guide_size(i: int) -> Vector3:
	var g: Dictionary = guides[i]
	var holder: Node3D = g.node
	return (holder.transform.basis * (g.box as AABB).size).abs()


# ---------------------------------------------------------------------------
# Phase 3: section and outlines
# ---------------------------------------------------------------------------

## In a flat view, cut away what is nearer than a plane: the mirror plane from the side,
## the ghost's plate from above, the ghost's stud line from the front.
func set_section(on: bool) -> void:
	section_on = on
	_apply_section()


func _apply_section() -> void:
	if not section_on or view == 0:
		_camera.near = 0.05
		return
	var cam := _camera.global_position
	match VIEWS[view]:
		"side":
			_camera.near = maxf(0.05, cam.z - mirror_z * BrickPalette.STUD_M)
		"top":
			_camera.near = maxf(0.05, cam.y - (_cell.y + 1) * BrickPalette.PLATE_M)
		"front":
			_camera.near = maxf(0.05, cam.x - (_cell.x + 1) * BrickPalette.STUD_M)


func set_outlines(mode: int) -> void:
	outlines = mode
	_outlines_dirty = true


func _draw_outlines() -> void:
	_outlines_dirty = false
	var im := ImmediateMesh.new()
	_outline_lines.mesh = im
	var any := false
	var sel := {}
	for i in selection:
		sel[i] = true
	for i in recipe.size():
		if recipe.frame_of(i) != 0:
			continue
		var tag := part_of[i] if i < part_of.size() else 0
		var show := sel.has(i) or outlines == 1 or (outlines == 2 and tag == part_sel)
		if not show:
			continue
		if not any:
			im.surface_begin(Mesh.PRIMITIVE_LINES)
			any = true
		var size := BrickPalette.size_of(recipe.part_of(i))
		var c := recipe.cell_of(i)
		var lo := Vector3(c.x * BrickPalette.STUD_M, c.y * BrickPalette.PLATE_M, c.z * BrickPalette.STUD_M)
		var hi := lo + Vector3(size.x * BrickPalette.STUD_M, size.y * BrickPalette.PLATE_M, size.z * BrickPalette.STUD_M)
		var col: Color = Color(1, 1, 1) if sel.has(i) else PART_COLOURS[tag % PART_COLOURS.size()]
		_box_lines(im, lo, hi, col)
	if any:
		im.surface_end()


func _draw_tool() -> void:
	var im := ImmediateMesh.new()
	_tool_lines.mesh = im
	if tool == "sketch":
		_draw_sketch(im)
		return
	if tool == "move":
		_draw_move(im)
		return
	if _shape_brush_on():
		_draw_shape_brush(im)
		return
	if not _dragging:
		return
	var a := _drag_from
	var b := _drag_to
	var lo := Vector3(mini(a.x, b.x) * BrickPalette.STUD_M, a.y * BrickPalette.PLATE_M, mini(a.z, b.z) * BrickPalette.STUD_M)
	var tall := float(shape_plates) if tool == "shape" else 0.2
	if tool == "shape" and shape_kind == "sphere":
		tall = (maxi(absi(a.x - b.x), absi(a.z - b.z)) + 1) * BrickPalette.STUD_M / BrickPalette.PLATE_M
	var hi := Vector3((maxi(a.x, b.x) + 1) * BrickPalette.STUD_M, a.y * BrickPalette.PLATE_M + tall * BrickPalette.PLATE_M,
			(maxi(a.z, b.z) + 1) * BrickPalette.STUD_M)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	_box_lines(im, lo, hi, Color(1.0, 0.9, 0.2) if tool == "shape" else Color(1, 1, 1))
	im.surface_end()


static func _box_lines(im: ImmediateMesh, lo: Vector3, hi: Vector3, col: Color) -> void:
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
			Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	for e in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		im.surface_set_color(col)
		im.surface_add_vertex(c[e[0]])
		im.surface_set_color(col)
		im.surface_add_vertex(c[e[1]])


# ---------------------------------------------------------------------------
# Phase 3: panels
# ---------------------------------------------------------------------------

func _build_phase3(layer: CanvasLayer) -> void:
	_rng.seed = 1
	for which in ["tool", "outline", "plane", "photo"]:
		var mi := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = which == "tool"
		if which in ["plane", "photo"]:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = mat
		add_child(mi)
		match which:
			"tool": _tool_lines = mi
			"outline": _outline_lines = mi
			"plane": _plane_lines = mi
			"photo": _photo_lines = mi
	_draw_work_plane()

	_tool_panel = PanelContainer.new()
	_tool_panel.visible = false
	_tool_panel.position = Vector2(12, 300)
	layer.add_child(_tool_panel)
	var box := VBoxContainer.new()
	_tool_panel.add_child(box)

	_shape_box = VBoxContainer.new()
	box.add_child(_shape_box)
	var t1 := Label.new()
	t1.text = "Shapes (K)"
	_shape_box.add_child(t1)
	var modes := OptionButton.new()
	modes.add_item("drag a box: fill it")
	modes.add_item("brush: LMB lays, RMB carves")
	modes.item_selected.connect(func(i: int) -> void:
		shape_mode = "drag" if i == 0 else "brush"
		_dragging = false)
	_shape_box.add_child(modes)
	_shape_mode_pick = modes
	_drag_box = VBoxContainer.new()
	_shape_box.add_child(_drag_box)
	var kinds := OptionButton.new()
	for k in SHAPES:
		kinds.add_item(k)
	kinds.item_selected.connect(func(i: int) -> void: shape_kind = SHAPES[i])
	_drag_box.add_child(kinds)
	var fills := OptionButton.new()
	fills.add_item("clean: fewest bricks")
	fills.add_item("random: mixed sizes")
	fills.item_selected.connect(func(i: int) -> void: shape_fill = "clean" if i == 0 else "random")
	_shape_box.add_child(fills)
	var hrow := HBoxContainer.new()
	_drag_box.add_child(hrow)
	var hl := Label.new()
	hl.text = "plates tall"
	hrow.add_child(hl)
	var hs := SpinBox.new()
	hs.min_value = 1
	hs.max_value = 120
	hs.value = shape_plates
	hs.value_changed.connect(func(v: float) -> void: shape_plates = int(v))
	hrow.add_child(hs)

	_sketch_box = VBoxContainer.new()
	box.add_child(_sketch_box)
	var t4 := Label.new()
	t4.text = "Sculpt in 3D (Alt V)"
	_sketch_box.add_child(t4)
	_sketch_title = t4
	var how := Label.new()
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.custom_minimum_size.x = RAIL_W - 16
	how.text = ("1. Pick the part (top of the rail, or Y).\n"
			+ "2. Draw its shape on the working plane: LMB draws in, RMB draws out. "
			+ "Alt 1 / 2 / 3 for side, top, front; PgUp / PgDn move the plane. "
			+ "Draw the same part from another view to cut it to that outline too.\n"
			+ "3. Add balls, cubes and cylinders with the Shapes tool's brush (K).\n"
			+ "4. Then finish it below: size, curves, and a smooth shell.")
	_sketch_box.add_child(how)
	_sketch_how = how
	_build_sculpt_box()
	_sketch_box.move_child(_sculpt_box, 1)
	var wrow := HBoxContainer.new()
	_sketch_box.add_child(wrow)
	var wl := Label.new()
	wl.text = "thickness, studs"
	wrow.add_child(wl)
	_width_spin = SpinBox.new()
	_width_spin.min_value = 1
	_width_spin.max_value = 20
	_width_spin.value = 3
	_width_spin.value_changed.connect(func(v: float) -> void:
		part_width[part_names[part_sel]] = int(v)
		_store_asset_meta()
		resketch(_sketch_key(), {"width": int(v)}))
	wrow.add_child(_width_spin)
	var sk_fill := OptionButton.new()
	sk_fill.add_item("clean: fewest bricks")
	sk_fill.add_item("random: mixed sizes")
	sk_fill.item_selected.connect(func(i: int) -> void: shape_fill = "clean" if i == 0 else "random")
	_sketch_box.add_child(sk_fill)
	# Curves: let go and every part is laid again from its form with that many, as one undo.
	var curve_label := Label.new()
	curve_label.text = "curves: " + CURVE_LEVELS[curve_level]
	_sketch_box.add_child(curve_label)
	_curve_slider = HSlider.new()
	_curve_slider.min_value = 0
	_curve_slider.max_value = CURVE_LEVELS.size() - 1
	_curve_slider.step = 1
	_curve_slider.value = curve_level
	_curve_slider.focus_mode = Control.FOCUS_NONE
	_curve_slider.custom_minimum_size.x = 150
	_curve_slider.value_changed.connect(func(v: float) -> void:
		curve_label.text = "curves: " + CURVE_LEVELS[int(v)])
	_curve_slider.drag_ended.connect(func(_changed: bool) -> void:
		if int(_curve_slider.value) != curve_level:
			set_curves(int(_curve_slider.value)))
	_sketch_box.add_child(_curve_slider)
	# The part's shell: a smooth outside over its bricks (Docs/AssetWorkshop.md, "Shells").
	_sketch_box.add_child(HSeparator.new())
	var shell_title := Label.new()
	shell_title.text = "Smooth shell (this part)"
	_sketch_box.add_child(shell_title)
	_shell_check = CheckBox.new()
	_shell_check.text = "smooth shell on this part"
	_shell_check.focus_mode = Control.FOCUS_NONE
	_shell_check.toggled.connect(func(on: bool) -> void:
		var part := part_names[part_sel]
		if on:
			set_shell(part, _shell_settings())
		else:
			set_shell(part, null)
		_sync_shell_ui(true))
	_sketch_box.add_child(_shell_check)
	_shell_label = Label.new()
	_sketch_box.add_child(_shell_label)
	_shell_thick = HSlider.new()
	_shell_thick.min_value = 0.0
	_shell_thick.max_value = 3.0
	_shell_thick.step = 0.25
	_shell_thick.value = 0.5
	_shell_res = HSlider.new()
	_shell_res.min_value = 1
	_shell_res.max_value = 8
	_shell_res.step = 1
	_shell_res.value = 4
	# Triangles: a budget, on a log scale -- 100 to 30,000.
	_shell_budget = HSlider.new()
	_shell_budget.min_value = 2.0
	_shell_budget.max_value = 4.5
	_shell_budget.step = 0.05
	_shell_budget.value = log(SHELL_TRIS) / log(10.0)
	for sl: HSlider in [_shell_thick, _shell_res, _shell_budget]:
		sl.focus_mode = Control.FOCUS_NONE
		sl.custom_minimum_size.x = 150
		sl.value_changed.connect(func(_v: float) -> void: _sync_shell_ui(false))
		sl.drag_ended.connect(func(_changed: bool) -> void:
			var part := part_names[part_sel]
			if shells.has(part):
				set_shell(part, _shell_settings())
			_sync_shell_ui(true))
		_sketch_box.add_child(sl)
	var finish := Label.new()
	finish.text = "Finish the block-out (whole asset)"
	_sketch_box.add_child(HSeparator.new())
	_sketch_box.add_child(finish)
	# Resize the whole block-out: let go of the slider and every part is laid again at that
	# size, as one undo, and the slider is back at 100%.
	var size_label := Label.new()
	size_label.text = "size of the block-out: 100%"
	_sketch_box.add_child(size_label)
	var size_slider := HSlider.new()
	size_slider.min_value = 25
	size_slider.max_value = 300
	size_slider.step = 5
	size_slider.value = 100
	size_slider.focus_mode = Control.FOCUS_NONE
	size_slider.custom_minimum_size.x = 150
	size_slider.value_changed.connect(func(v: float) -> void:
		size_label.text = "size of the block-out: %d%% (let go to apply)" % int(v))
	size_slider.drag_ended.connect(func(changed: bool) -> void:
		if not changed or is_equal_approx(size_slider.value, 100.0):
			return
		var ok := scale_form(size_slider.value / 100.0)
		size_label.text = "size of the block-out: 100%%%s" % ("" if ok else "  (too big for the build area)")
		size_slider.set_value_no_signal(100))
	_sketch_box.add_child(size_slider)
	var crow := HBoxContainer.new()
	_sketch_box.add_child(crow)
	var cl := Label.new()
	cl.text = "cut depth (0: through)"
	crow.add_child(cl)
	var cs := SpinBox.new()
	cs.min_value = 0
	cs.max_value = 20
	cs.value = cut_deep
	cs.value_changed.connect(func(v: float) -> void: cut_deep = int(v))
	crow.add_child(cs)
	var any := CheckBox.new()
	any.text = "RMB erases any brick"
	any.button_pressed = erase_any
	any.focus_mode = Control.FOCUS_NONE
	any.toggled.connect(func(on: bool) -> void: erase_any = on)
	_sketch_box.add_child(any)
	var hint := Label.new()
	hint.text = "LMB draws in, RMB draws out. A part's first plane sets its thickness; on another plane, in keeps what is inside, out cuts through."
	_sketch_box.add_child(hint)
	# Everything after the sculpt panel but the curves (Convert uses them too) is the 2D
	# sketch's own: its box, shown only with the Sketch tool.
	_sketch2d_box = VBoxContainer.new()
	var keep := [t4, _sculpt_box, curve_label, _curve_slider]
	for c in _sketch_box.get_children():
		if not keep.has(c):
			_sketch_box.remove_child(c)
			_sketch2d_box.add_child(c)
	_sketch_box.add_child(_sketch2d_box)
	_sync_sketch_panels()
	var clear := Button.new()
	clear.text = "Clear this view"
	clear.pressed.connect(func() -> void: clear_sketch(_sketch_key()))
	_sketch_box.add_child(clear)
	var clear_all := Button.new()
	clear_all.text = "Clear the part, every view"
	clear_all.pressed.connect(func() -> void: clear_part_sketch(part_names[part_sel]))
	_sketch_box.add_child(clear_all)

	_select_box = VBoxContainer.new()
	box.add_child(_select_box)
	var t2 := Label.new()
	t2.text = "Select (L): drag a box over the build"
	_select_box.add_child(t2)
	for b in [["Delete", func() -> void: delete_selection()],
			["Re-pack clean", func() -> void: repack_selection(false)],
			["Re-pack random", func() -> void: repack_selection(true)],
			["Give to current part", func() -> void: assign_selection()],
			["Copy to ghost", func() -> void: copy_selection_to_ghost(false)],
			["Move to ghost", func() -> void: copy_selection_to_ghost(true)]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(b[1])
		_select_box.add_child(btn)

	_guide_panel = PanelContainer.new()
	_guide_panel.visible = false
	layer.add_child(_guide_panel)
	var g := VBoxContainer.new()
	_guide_panel.add_child(g)
	var t3 := Label.new()
	t3.text = "Guide models (F3): to build inside, never exported"
	g.add_child(t3)
	var mm_row := HBoxContainer.new()
	g.add_child(mm_row)
	var mm_l := Label.new()
	mm_l.text = "real length, mm"
	mm_row.add_child(mm_l)
	_guide_mm = LineEdit.new()
	_guide_mm.text = "852"
	_guide_mm.custom_minimum_size = Vector2(80, 0)
	mm_row.add_child(_guide_mm)
	var load_btn := Button.new()
	load_btn.text = "Load model..."
	load_btn.pressed.connect(func() -> void: _guide_dialog.popup_centered_ratio(0.6))
	g.add_child(load_btn)
	_guide_list = OptionButton.new()
	_guide_list.item_selected.connect(func(i: int) -> void: select_guide(i))
	g.add_child(_guide_list)
	var grid := GridContainer.new()
	grid.columns = 4
	g.add_child(grid)
	for b in [["left", Vector3(-1, 0, 0)], ["right", Vector3(1, 0, 0)], ["up", Vector3(0, 1, 0)],
			["down", Vector3(0, -1, 0)], ["nearer", Vector3(0, 0, 1)], ["farther", Vector3(0, 0, -1)]]:
		var btn := Button.new()
		btn.text = b[0]
		var step: Vector3 = b[1]
		btn.pressed.connect(func() -> void:
			var i := _guide_list.selected
			if i >= 0:
				guides[i].offset = (guides[i].offset as Vector3) + step
				_fit_guide(guides[i])
				_store_asset_meta())
		grid.add_child(btn)
	for b in [["turn 90", "turn"], ["set length", "length"], ["fainter", "fainter"], ["remove", "remove"]]:
		var btn := Button.new()
		btn.text = b[0]
		var what: String = b[1]
		btn.pressed.connect(func() -> void: _guide_action(what))
		grid.add_child(btn)
	_guide_dialog = FileDialog.new()
	_guide_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_guide_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_guide_dialog.use_native_dialog = true
	_guide_dialog.filters = PackedStringArray(["*.glb, *.gltf, *.fbx, *.obj, *.stl ; Models"])
	_guide_dialog.file_selected.connect(func(path: String) -> void:
		if _guide_into_sdf:
			# Added from the sculpt panel: into the field only, placed, the gizmo on it.
			_guide_into_sdf = false
			place_model(path)
			return
		load_guide(path, float(_guide_mm.text) if _guide_mm.text.is_valid_float() else 852.0))
	_guide_dialog.canceled.connect(func() -> void: _guide_into_sdf = false)
	layer.add_child(_guide_dialog)


func _guide_action(what: String) -> void:
	var i := _guide_list.selected
	if i < 0 or i >= guides.size():
		return
	var g: Dictionary = guides[i]
	match what:
		"turn":
			g.turn = (int(g.turn) + 1) % 4
		"length":
			if _guide_mm.text.is_valid_float():
				g.real_mm = float(_guide_mm.text)
		"fainter":
			g.opacity = 0.6 if float(g.opacity) < 0.2 else float(g.opacity) * 0.6
		"remove":
			if is_same(_placed.get("guide"), g):
				select_model(null)
			(g.node as Node).queue_free()
			guides.remove_at(i)
			_store_asset_meta()
			_refresh_guide_panel()
			return
	_fit_guide(g)
	_store_asset_meta()


func _toggle_guide_panel() -> void:
	_guide_panel.visible = not _guide_panel.visible
	if _guide_panel.visible and _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	var vp := get_viewport().get_visible_rect().size
	_guide_panel.position = Vector2(vp.x - 420, 60)
	_refresh_guide_panel()


func _refresh_guide_panel() -> void:
	if _guide_list == null:
		return
	_guide_list.clear()
	for g in guides:
		_guide_list.add_item((g.path as String).get_file())
	if not guides.is_empty():
		_guide_list.select(guides.size() - 1)


# ---------------------------------------------------------------------------
# Phase 4: smooth parts, undo and redo
# ---------------------------------------------------------------------------

## The current part leaves as a smooth custom piece, or as bricks again.
func toggle_smooth() -> void:
	var name := part_names[part_sel]
	var i := smooth_parts.find(name)
	if i >= 0:
		smooth_parts.remove_at(i)
	else:
		smooth_parts.append(name)
	_store_asset_meta()


## What laying the last brick again needs, if the last edit was a brick.
func _last_brick() -> Variant:
	if _edits.is_empty() or _edits.back() != "brick" or recipe.size() == 0:
		return null
	var i := recipe.size() - 1
	return {"arch": recipe.part_of(i), "cell": recipe.cell_of(i), "colour": recipe.colour_of(i),
			"mat": recipe.material_of(i), "tag": part_of[i] if i < part_of.size() else part_sel}


## Z: a fill, a copy, a mirrored pair or a sketch change goes at once; anything else one
## edit at a time. An RMB delete is laid back.
func _undo() -> bool:
	# The selected model is let go while the undo runs and picked again after.
	var pick := _pick_id()
	_set_down()
	var n := 1
	var sketch = null
	if not _edit_groups.is_empty() and int(_edit_groups.back().end) == _edits.size():
		var g: Dictionary = _edit_groups.pop_back()
		n = int(g.n)
		sketch = g.get("sketch")
	var items := []
	var lay_back := []
	var any := false
	for _k in n:
		if _edits.is_empty():
			break
		if _edits.back() == "stud":
			_edits.pop_back()
			var rec: Dictionary = _stud_log.pop_back()
			_stud_apply(rec, false)
			items.append({"op": "stud", "rec": rec})
			any = true
			continue
		if _edits.back() == "delete":
			# Laid back after the loop: laying one now adds an edit the loop would undo next.
			_edits.pop_back()
			lay_back.append(_deleted.pop_back())
			any = true
			continue
		var b = _last_brick()
		if not super._undo():
			break
		any = true
		if b != null:
			items.append(b)
	if not lay_back.is_empty():
		_redoing = true
		var keep := part_sel
		_batch = true
		for b in lay_back:
			part_sel = int(b.tag)
			if place_named(b.arch, b.cell, b.colour, b.mat):
				items.append({"op": "remove", "arch": b.arch, "cell": b.cell})
		_batch = false
		part_sel = keep
		_after_edit()
		_redoing = false
	if sketch != null:
		_restore_sketch(sketch, "before")
	if not items.is_empty() or sketch != null:
		_redo.append({"items": items, "sketch": sketch})
	_repick(pick)
	return any


## Shift Z: do the last undone group again -- each brick back in its own part, each
## delete taken up again, a sketch back to what it was.
func redo() -> int:
	# Set down first: a lifted part put down where it was moved is a new edit, and clears redo.
	var pick := _pick_id()
	_set_down()
	if _redo.is_empty():
		_repick(pick)
		return 0
	var entry: Dictionary = _redo.pop_back()
	var items: Array = (entry.items as Array).duplicate()
	items.reverse()
	_redoing = true
	var keep := part_sel
	var done := 0
	_batch = true
	for b in items:
		if b.get("op", "place") == "stud":
			stud_edit(b.rec.op == "add", b.rec.stud)
			done += 1
		elif b.get("op", "place") == "remove":
			if remove_brick(b.arch, b.cell):
				done += 1
		else:
			part_sel = int(b.tag)
			if place_named(b.arch, b.cell, b.colour, b.mat):
				done += 1
	_batch = false
	part_sel = keep
	_after_edit()
	var sketch = entry.get("sketch")
	if sketch != null:
		_restore_sketch(sketch, "after")
	_group_with(done, sketch)
	_redoing = false
	_repick(pick)
	return done


## Edits that undo together, with the sketch they changed, if any.
func _group_with(n: int, sketch) -> void:
	# A sketch change that moved no brick (an area cut where nothing was) still undoes.
	if n > 1 or sketch != null:
		var g := {"end": _edits.size(), "n": n}
		if sketch != null:
			g["sketch"] = sketch
		_edit_groups.append(g)


# ---------------------------------------------------------------------------
# Phase 4: the wand -- a patch of a photo's colour, filled
# ---------------------------------------------------------------------------

## The photo pixel under a point of the workshop, or (-1, -1) off the photo.
func photo_pixel(i: int, at: Vector3) -> Vector2i:
	var p: Dictionary = photos[i]
	var node: Node3D = p.node
	var size := Vector2(p.px) * float(p.mpp)
	var local := node.transform.affine_inverse() * at
	var px := Vector2i(int((local.x / size.x + 0.5) * p.px.x), int((0.5 - local.y / size.y) * p.px.y))
	if px.x < 0 or px.y < 0 or px.x >= p.px.x or px.y >= p.px.y:
		return Vector2i(-1, -1)
	return px


func _sample(img: Image, px: Vector2i) -> Color:
	var c := Color(0, 0, 0, 0)
	var n := 0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var q := px + Vector2i(dx, dy)
			if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
				c += img.get_pixelv(q)
				n += 1
	return c / maxf(n, 1)


## Fill, for the current part, the cells in front of the patch of a side photo that has
## the colour under `hit` and joins it, `width` studs across on the mirror plane.
## Returns how many bricks were laid.
func wand_fill(i: int, hit: Vector3, width: int, tolerance: float = 0.14) -> int:
	var p: Dictionary = photos[i]
	if p.plane != "side" or not p.has("image"):
		return 0
	var img: Image = p.image
	var start := photo_pixel(i, hit)
	if start.x < 0:
		return 0
	var want := _sample(img, start)
	var z := (p.node as Node3D).transform.origin.z
	var seed_cell := Vector2i(int(floor(hit.x / BrickPalette.STUD_M)), int(floor(hit.y / BrickPalette.PLATE_M)))
	var seen := {}
	var keep := {}
	var todo: Array[Vector2i] = [seed_cell]
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		if seen.has(c) or c.y < 1 or c.x < 0 or c.x >= plate_studs or c.y >= height_plates:
			continue
		seen[c] = true
		var at := Vector3((c.x + 0.5) * BrickPalette.STUD_M, (c.y + 0.5) * BrickPalette.PLATE_M, z)
		var px := photo_pixel(i, at)
		if px.x < 0:
			continue
		var got := _sample(img, px)
		if absf(got.r - want.r) + absf(got.g - want.g) + absf(got.b - want.b) > tolerance * 3.0:
			continue
		keep[c] = true
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			todo.append(c + d)
	var z0 := int(round(mirror_z - width * 0.5))
	var cells := {}
	for c in keep:
		for k in width:
			cells[Vector3i(c.x, c.y, z0 + k)] = true
	return fill_cells(cells)


# ---------------------------------------------------------------------------
# Phase 4: export to the part kit
# ---------------------------------------------------------------------------

## The build as a part-kit build sheet (tools/brickify/gunsmith.py), in its frame: mm at
## print size, x along the gun from the muzzle, y across from the mirror plane, z up from
## the plate. A smooth part's brick outline becomes a loft; the rest go as laid.
func export_sheet() -> Dictionary:
	settle_muzzle()
	var by_part := {}
	var x_lo := 1 << 30
	var x_hi := -(1 << 30)
	var y_lo := 1 << 30
	var z_lo := 1 << 30
	var z_hi := -(1 << 30)
	for i in recipe.size():
		var af := _brick_frame(i)
		if af < 0:
			continue
		if af == 0:
			var size := BrickPalette.size_of(recipe.part_of(i))
			var c := recipe.cell_of(i)
			x_lo = mini(x_lo, c.x)
			x_hi = maxi(x_hi, c.x + size.x)
			y_lo = mini(y_lo, c.y)
			z_lo = mini(z_lo, c.z)
			z_hi = maxi(z_hi, c.z + size.z)
		else:
			# A sideways brick's box, in cells of the upright grid (not whole ones).
			var box := _brick_box(i)
			x_lo = mini(x_lo, int(floor(box.position.x / BrickPalette.STUD_M + 1e-4)))
			x_hi = maxi(x_hi, int(ceil(box.end.x / BrickPalette.STUD_M - 1e-4)))
			y_lo = mini(y_lo, int(floor(box.position.y / BrickPalette.PLATE_M + 1e-4)))
			z_lo = mini(z_lo, int(floor(box.position.z / BrickPalette.STUD_M + 1e-4)))
			z_hi = maxi(z_hi, int(ceil(box.end.z / BrickPalette.STUD_M - 1e-4)))
		var tag := part_of[i] if i < part_of.size() else 0
		by_part.get_or_add(tag, []).append(i)
	var along := func(x: float) -> float:
		return (x - x_lo) * PRINT_MM_PER_STUD if muzzle_end == "-x" else (x_hi - x) * PRINT_MM_PER_STUD
	var up := func(y: float) -> float: return (y - y_lo) * PRINT_MM_PER_PLATE
	# Across from the mirror plane when it is on -- it is the asset's middle -- else from
	# the middle of what was built.
	var mid_z := mirror_z if mirror_on else (z_lo + z_hi) * 0.5
	var across := func(z: float) -> float: return (z - mid_z) * PRINT_MM_PER_STUD
	var parts := []
	var made := {}
	for tag in by_part:
		var name := part_names[tag]
		var ids: Array = by_part[tag]
		var spec := {"name": name, "slot": name if GUN_PARTS.has(name) else "body",
				"colour": _part_colour(ids), "sockets": []}
		if smooth_parts.has(name):
			_loft_spec(spec, ids, along, up)
		else:
			spec["kind"] = "placed"
			# Built muzzle-right, the gun's frame runs the other way: a shaped part is drawn
			# mirrored along the gun to match.
			spec["mirror_along"] = muzzle_end == "+x"
			var bricks := []
			if _shell_nodes.has(name):
				spec["shell"] = _shell_sheet(name, along, across, up)
				ids = _uncovered(name, ids)
			for i in ids:
				var size := BrickPalette.size_of(recipe.part_of(i))
				var c := recipe.cell_of(i)
				if _brick_frame(i) == 0:
					var x0: float = along.call(c.x) if muzzle_end == "-x" else along.call(c.x + size.x)
					bricks.append({"part": recipe.part_of(i), "min_mm": [x0, across.call(c.z), up.call(c.y)],
							"size": [size.x, size.z, size.y]})
				else:
					bricks.append(_turned_brick(i, along, across, up, spec))
			spec["bricks"] = bricks
		parts.append(spec)
		made[name] = spec
	# Studs put on by hand: where and which way, in the gun's frame (along, across, up).
	var sign := 1.0 if muzzle_end == "-x" else -1.0
	for st in extra_studs:
		if not made.has(st.part):
			continue
		var a: Array = st.at
		var d: Array = st.dir
		(made[st.part].get_or_add("studs_extra", []) as Array).append({
				"at": [snappedf(along.call(float(a[0])), 0.001), snappedf(across.call(float(a[2])), 0.001),
						snappedf(up.call(float(a[1])), 0.001)],
				"normal": [snappedf(float(d[0]) * sign, 0.0001), snappedf(float(d[2]), 0.0001), snappedf(float(d[1]), 0.0001)]})
	for q in points:
		var at: Array = q.at
		var joint := {"at": [snappedf(along.call(float(at[0])), 0.001), snappedf(up.call(float(at[1])), 0.001)],
				"interface": q.interface}
		if q.has("dir"):
			var d: Array = q.dir
			joint["across"] = snappedf(across.call(float(at[2])), 0.001)
			joint["normal"] = [snappedf(float(d[0]) * sign, 0.0001), snappedf(float(d[2]), 0.0001),
					snappedf(float(d[1]), 0.0001)]
		if not made.has(q.part):
			continue
		if q.kind == "mount":
			made[q.part]["mount"] = joint
		else:
			joint["slot"] = q.slot
			made[q.part]["sockets"].append(joint)
	return {"name": slug(recipe.name) if recipe.name != "" else "asset",
			"note": "Written by the asset workshop's export (Docs/AssetWorkshop.md).",
			"reference": "asset workshop", "class": "held",
			"platform": String(recipe.meta.get("asset", {}).get("platform", "")), "parts": parts}


## A smooth part's loft: along the gun if it is longer than tall, else up it, one section
## for each stud column (or plate row) of its bricks, its width the part's across.
func _loft_spec(spec: Dictionary, ids: Array, along: Callable, up: Callable) -> void:
	var cells := {}
	for i in ids:
		var size := BrickPalette.size_of(recipe.part_of(i))
		var c := recipe.cell_of(i)
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					cells[c + Vector3i(dx, dy, dz)] = true
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for c in cells:
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x), maxi(hi.y, c.y), maxi(hi.z, c.z))
	var w := (hi.z - lo.z + 1) * PRINT_MM_PER_STUD * 0.5
	var long := (hi.x - lo.x + 1) * PRINT_MM_PER_STUD
	var tall := (hi.y - lo.y + 1) * PRINT_MM_PER_PLATE
	var stations := []
	if long >= tall:
		for x in range(lo.x, hi.x + 1):
			var ys := []
			for c in cells:
				if c.x == x:
					ys.append(c.y)
			if ys.is_empty():
				continue
			var a := [up.call(float(ys.min())), up.call(float(ys.max() + 1))]
			for edge in ([x, x + 1] if x == lo.x or x == hi.x else [x + 0.5]):
				stations.append({"t": along.call(float(edge)), "a": a, "w": w, "round": 0.45})
		spec["axis"] = "x"
		# Studs on both flat sides, wherever a whole stud fits (the reference's furniture has
		# them); a grip, held in the hand, gets none.
		if spec.slot != "grip":
			var x0: float = along.call(float(lo.x))
			var x1: float = along.call(float(hi.x + 1))
			var span := [minf(x0, x1), maxf(x0, x1)]
			var zs := [up.call(float(lo.y)), up.call(float(hi.y + 1))]
			spec["studs"] = [{"face": "+y", "x": span, "z": zs, "shape": "all"},
					{"face": "-y", "x": span, "z": zs, "shape": "all"}]
	else:
		for y in range(lo.y, hi.y + 1):
			var xs := []
			for c in cells:
				if c.y == y:
					xs.append(c.x)
			if xs.is_empty():
				continue
			var ends := [along.call(float(xs.min())), along.call(float(xs.max() + 1))]
			ends.sort()
			for edge in ([y, y + 1] if y == lo.y or y == hi.y else [y + 0.5]):
				stations.append({"t": up.call(float(edge)), "a": ends, "w": w, "round": 0.5})
		spec["axis"] = "z"
	stations.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.t < b.t)
	spec["kind"] = "loft"
	spec["stations"] = stations
	spec["arc"] = 3
	spec["smooth"] = true


func _part_colour(ids: Array) -> Array:
	var count := {}
	for i in ids:
		var k := Vector2i(recipe.material_of(i), recipe.colour_of(i))
		count[k] = count.get(k, 0) + 1
	var best := Vector2i(0, _colour)
	for k in count:
		if count[k] > count.get(best, 0):
			best = k
	var c := WorkshopHotbar.rgb(best.x, best.y)
	return [c.r, c.g, c.b]


## F12: write the sheet, run the part kit on it in Blender, and show its picture here
## when it is drawn.
func export_and_preview() -> void:
	var sheet := export_sheet()
	if (sheet.parts as Array).is_empty():
		_export_check = "export: nothing built yet"
		return
	var dir := ProjectSettings.globalize_path("user://asset_exports")
	DirAccess.make_dir_recursive_absolute(dir)
	var sheet_path := "%s/%s.json" % [dir, sheet.name]
	var f := FileAccess.open(sheet_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(sheet, " "))
	f.close()
	if not FileAccess.file_exists(blender_path):
		_export_check = "export: wrote %s; Blender not found at %s (set BRICKCITY_BLENDER)" % [sheet_path, blender_path]
		return
	var kit := ProjectSettings.globalize_path("res://tools/brickify/gunsmith.py")
	var out := "%s/%s" % [dir, sheet.name]
	_export_png = "%s/%s_iso.png" % [out, sheet.name]
	_export_started = int(Time.get_unix_time_from_system())
	OS.create_process(blender_path, ["--background", "--factory-startup", "--python", kit, "--", sheet_path, out])
	_export_check = "export: the part kit is running..."


func _poll_export() -> void:
	if _export_png == "" or not FileAccess.file_exists(_export_png):
		return
	if FileAccess.get_modified_time(_export_png) < _export_started:
		return
	var img := Image.load_from_file(_export_png)
	var parts_json := _export_png.replace("_iso.png", ".parts.json")
	var good := 0
	var bad := PackedStringArray()
	if FileAccess.file_exists(parts_json):
		var d = JSON.parse_string(FileAccess.get_file_as_string(parts_json))
		if d is Dictionary:
			for line in d.get("check", []):
				if line.ok:
					good += 1
				else:
					bad.append(String(line.what))
	_export_check = "export: %d checks ok, %d failed%s   (%s)" % [good, bad.size(),
			(": " + "; ".join(bad)) if not bad.is_empty() else "", _export_png.get_base_dir()]
	_export_png = ""
	if img != null and not img.is_empty():
		_preview_image.texture = ImageTexture.create_from_image(img)
		_preview_text.text = _export_check
		_preview_panel.visible = true


func _build_preview(layer: CanvasLayer) -> void:
	_preview_panel = PanelContainer.new()
	_preview_panel.visible = false
	_preview_panel.position = Vector2(60, 60)
	layer.add_child(_preview_panel)
	var box := VBoxContainer.new()
	_preview_panel.add_child(box)
	_preview_image = TextureRect.new()
	_preview_image.custom_minimum_size = Vector2(880, 360)
	_preview_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(_preview_image)
	_preview_text = Label.new()
	box.add_child(_preview_text)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func() -> void: _preview_panel.visible = false)
	box.add_child(close)


# ---------------------------------------------------------------------------
# Instructions
# ---------------------------------------------------------------------------

const HELP_SAVE := "user://asset_workshop.cfg"
const HELP_TEXT := """[font_size=22][b]Asset workshop[/b][/font_size]
Block out a gun (or any asset) in bricks against a photo. Each brick here becomes its nano twin when exported.

[b]Sizes[/b]   1 stud here = 4 mm printed = 16 mm on the real gun.   1 plate = 1.6 mm printed = 6.4 mm real.
A gun is a quarter-size model: a Thompson is 53 studs long, 3 studs wide.

[font_size=18][b]Getting started[/b][/font_size]
[b]1. Photo.[/b]  F2, [i]Load photo...[/i], pick a side view. Click [i]Calibrate[/i], click two points on the photo (butt and muzzle), type the real length in mm (852 for a Thompson).
[b]2. Look at it flat.[/b]  Alt 1 for the side view (Alt 2 top, Alt 3 front, Alt 0 back to 3D). Alt + wheel zooms where the cursor is, WASD moves. ESC frees the mouse for the panels. Tick [i]stud grid on the photo[/i] in F2 to check its size.
[b]3. Pick the part.[/b]  Y (shift Y back) to body, barrel, stock, grip ... Every brick you lay belongs to the part you are on, and each part keeps its own 9 toolbar slots.
[b]4. Build.[/b]  Bricks go where the cursor is on the working plane (free placement, Alt F to aim at studs instead); PgUp / PgDn move the plane. The tools are down the left, with the open tool's options under them and the part picker at the top; every other action is in the menus at the top (View, Part, Brick, Gun, Photos, Help), its key beside it. Keys still work. [b]Saving:[/b] File > Save (Ctrl S), Save As (Ctrl Shift S) and Open (Ctrl O) keep guns in their own library (user://guns/), apart from the buildings, and Save also writes every part on its own (user://parts/custom/): the parts are what the game makes guns of, and only parts whose connection points fit. The build is also autosaved every few seconds. [b]Explode[/b] (Alt E) pulls the parts apart -- barrel forward, stock behind, grip and underbarrel under, sight over, a magazine out the way it sits -- and you keep building on them where they are drawn. [b]Move part[/b] (Alt G): drag a part across the view to move it whole, studs, sketch and points with it (one Z). [b]Export to game[/b] (Alt X): each part as a game scene in a folder beside the gun's file (user://guns/<name>/), real size, muzzle forward, with the sockets the game's assembler joins them on. Which end is the muzzle is read off the build (barrel forward of the body, stock behind). [b]Hands[/b] (Alt H): the game's brick hands at the gun's scale, the right C round the grip, the left round the underbarrel (or the barrel). [b]Play[/b] (Alt P): three shots and a reload, the magazine out and back in -- the parts are baked into pieces of their own first. [b]Shapes[/b] (K) drags a box and fills it, or, set to [i]brush[/i], LMB lays a shape and RMB carves one out, held and dragged to go on; Ctrl + click does the same from any tool. The brush: Ctrl + LMB lays a ball, cube, cylinder, or a flat circle or square (on the plane the ghost is on -- hold E to lock its height, as for bricks); Ctrl + RMB carves the shape out of whatever is built, the rest of each brick it touches laid again. Hold and drag to keep going (one Z). Ctrl + wheel sizes it; its shape is on the left. [b]Studs[/b] (Alt U): LMB puts a stud on any face of any brick, a slope's too, on that face's half-stud lattice; RMB takes it off; shift LMB makes a stud a connection point (mount or socket), facing the way the stud does. LMB places one brick; hold it and drag to lay a row. RMB deletes (Z brings it back). R turns, F flips. Alt S mirrors: every brick is placed on the other side too.
[b]   Or block it out.[/b]  The [i]Block out[/i] tool on the rail (Alt D): its panel says how, step by step. Draw each part's shape, add shapes with the Shapes brush, then at the bottom of the panel [i]size of the block-out[/i] scales the whole asset, [i]curves[/i] sets how many slopes and curves it is laid with, and [i]smooth shell[/i] gives a part a smooth custom outside (thickness: how far in the bricks start; detail: how many triangles). In detail: set the part's thickness, then draw on the working plane: LMB draws area in, RMB draws it out -- and takes up any brick under the stroke, a hand-laid one or another part's (untick [i]RMB erases any brick[/i] to keep them) -- and the part's bricks are worked out again each time (one Z undoes a change). An outline that crosses itself fills to its outermost line. Edges at a slope's or curve's pitch get slopes and curves, flipped under bottom edges; set slopes to [i]eager[/i] for more of them. Draw a drum magazine as a circle on the front plane (Alt 3). [b]Three views:[/b] the first plane a part is drawn on gives it its thickness; drawn for the same part on another plane (Alt 2 top, Alt 3 front, PgUp/PgDn to move it), area in keeps only what is inside it and area out cuts right through, or set [i]RMB cuts in[/i] to make a pocket so many studs deep. A blue line is the whole part from this plane, grey the other parts. Draw with an outline, a brush (its size and shape on the left), a rectangle, an ellipse, or a polygon of clicked corners (Enter, a double click or the first corner closes it).
[b]5. Smooth parts.[/b]  On a part that should be a smooth custom piece (stock, grip, handguard), press N. Its bricks are only its outline.
[b]6. Joints.[/b]  J where a part attaches: a [i]mount[/i] on the part, a [i]socket[/i] on the part it goes onto, same interface.
[b]7. Export.[/b]  F12 runs the part kit and shows the result and its checks here.

[font_size=18][b]Tools[/b][/font_size]
[b]F2[/b] photos   [b]F3[/b] guide models (an existing model to build inside, never exported)   [b]F4[/b] wand: click a colour patch on a photo to fill it
[b]F7[/b] parts: every saved part, official and custom; tick any maker, part, class, gun class or creator, sort, and [i]Fits[/i] shows only what goes on the part being built
[b]Alt 0-3[/b] view: 3D, side, top, front   [b]Alt M[/b] measure: two clicks   [b]Alt S[/b] mirror (Alt shift S: plane under the ghost)
[b]Alt F[/b] free placement / aim at studs   [b]PgUp PgDn[/b] move the working plane   [b]Alt D[/b] block out   [b]Alt + drag[/b] move a photo
[b]Y[/b] next part   [b]J[/b] mount / socket   [b]K[/b] shapes: drag a box, cylinder, sphere or wedge, filled clean or random
[b]L[/b] select: drag a box, then delete, re-pack, give to the part, copy or move to the ghost
[b]O[/b] section: in a flat view, cut away what is in front   [b]P[/b] outline bricks by part   [b]N[/b] part smooth / bricks
[b]Z[/b] undo (a whole fill at once)   [b]shift Z[/b] redo   [b]F12[/b] export   [b]F1[/b] the workshop's own keys   [b]F10[/b] this page

[font_size=18][b]Tips[/b][/font_size]
Build the gun with its muzzle at the low end (left in the side view). Keep it on the mirror plane (the pink outline) so both halves match.
The panels need a free mouse: ESC, then click. Click the scene again to look around.
[b]Run it outside the editor, or turn off the editor's game embedding:[/b] F5-F8 belong to the Godot editor (run, run scene, pause, stop) and the workshop's F5 / F9 quick save / load can be taken by it. The build is autosaved every few seconds and comes back next start.
Exports land in your user folder, [i]asset_exports[/i]. Bought photos and models stay guides only: never exported."""

var _help: PanelContainer


func _build_help(layer: CanvasLayer) -> void:
	_help = PanelContainer.new()
	_help.visible = false
	# Solid, so the scene and the workshop's own panels do not show through the text.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.11, 0.98)
	sb.border_color = Color(1.0, 0.85, 0.4, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	_help.add_theme_stylebox_override("panel", sb)
	layer.add_child(_help)
	var box := VBoxContainer.new()
	_help.add_child(box)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.text = HELP_TEXT
	text.custom_minimum_size = Vector2(880, 500)
	text.add_theme_font_size_override("normal_font_size", 15)
	text.add_theme_font_size_override("bold_font_size", 15)
	text.add_theme_font_size_override("italics_font_size", 15)
	text.scroll_active = true
	box.add_child(text)
	var row := HBoxContainer.new()
	box.add_child(row)
	var at_start := CheckBox.new()
	at_start.text = "show at start"
	at_start.button_pressed = _help_at_start()
	at_start.toggled.connect(func(on: bool) -> void:
		var cfg := ConfigFile.new()
		cfg.set_value("help", "at_start", on)
		cfg.save(HELP_SAVE))
	row.add_child(at_start)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var close := Button.new()
	close.text = "Close (F10)"
	close.pressed.connect(func() -> void: show_help(false))
	row.add_child(close)
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if _help_at_start() and not ("--shot" in args or "--gate" in args) and DisplayServer.get_name() != "headless":
		show_help.call_deferred(true)


func _help_at_start() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(HELP_SAVE) != OK:
		return true
	return bool(cfg.get_value("help", "at_start", true))


func show_help(on: bool) -> void:
	_help.visible = on
	# The workshop's key list sits behind it; it comes back as it was.
	if _keys_panel != null:
		_keys_panel.visible = _keys_on and not on
	if on:
		if _camera.has_method("_set_captured"):
			_camera.call("_set_captured", false)
		var vp := get_viewport().get_visible_rect().size
		_help.reset_size()
		_help.position = (vp - _help.get_combined_minimum_size()) * 0.5


# ---------------------------------------------------------------------------
# Round 2: free placement on a working plane
# ---------------------------------------------------------------------------

func set_free(on: bool) -> void:
	free_place = on
	_grid.visible = _grid_on and not on
	_draw_work_plane()


func move_work_plane(d: int) -> void:
	match work_plane:
		"side": work_depth += d
		"top": work_height = clampi(work_height + d, 0, height_plates - 1)
		"front": work_x = clampi(work_x + d, 0, plate_studs - 1)
	_draw_work_plane()


func _plane_at_text() -> String:
	match work_plane:
		"top": return "plate %d" % work_height
		"front": return "stud %d along" % work_x
	return "%s studs across" % _num(work_depth)


## Where a ray meets the working plane, or null.
func work_plane_hit(from: Vector3, dir: Vector3) -> Variant:
	var n := Vector3.BACK
	var at := work_depth * BrickPalette.STUD_M
	match work_plane:
		"top":
			n = Vector3.UP
			at = work_height * BrickPalette.PLATE_M
		"front":
			n = Vector3.RIGHT
			at = work_x * BrickPalette.STUD_M
	var denom := n.dot(dir)
	if absf(denom) < 1e-5:
		return null
	var t := (at - n.dot(from)) / denom
	return from + dir * t if t > 0.0 else null


## The cell a part of `size` takes with its middle under `hit`, on the working plane.
func free_cell(hit: Vector3, size: Vector3i) -> Vector3i:
	var x := int(floor(hit.x / BrickPalette.STUD_M - size.x * 0.5 + 0.5))
	var y := int(floor(hit.y / BrickPalette.PLATE_M - size.y * 0.5 + 0.5))
	var z := int(floor(hit.z / BrickPalette.STUD_M - size.z * 0.5 + 0.5))
	match work_plane:
		"side": z = int(round(work_depth - size.z * 0.5))
		"top": y = work_height
		"front": x = int(round(work_x - size.x * 0.5))
	return _clamp_cell(Vector3i(x, y, z), size)


## Free placement: no stud is aimed at; the ghost goes where the cursor meets the plane,
## mid-air or not, flipped or not. Only an overlap stops it.
func _aim() -> void:
	if not free_place:
		super._aim()
		return
	var ray := _mouse_ray()
	_lock = {}
	_snapped = {}
	_stud = NO_STUD
	_studs = []
	_frame = 0
	var hit = work_plane_hit(ray[0], ray[1])
	if hit != null:
		_cell = free_cell(hit, BrickPalette.size_of(_archetype_name()))


func _draw_work_plane() -> void:
	if _plane_lines == null:
		return
	var im := ImmediateMesh.new()
	_plane_lines.mesh = im
	if not free_place:
		return
	var s := BrickPalette.STUD_M
	var p := BrickPalette.PLATE_M
	# Round the build only: the area is 1000 studs, a line a stud would be thousands.
	var box := view_box()
	var lo: Vector3i = box[0]
	var hi: Vector3i = box[1]
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var line := func(a: Vector3, b: Vector3, strong: bool) -> void:
		var col := Color(1, 1, 1, 0.16 if strong else 0.05)
		im.surface_set_color(col)
		im.surface_add_vertex(a)
		im.surface_set_color(col)
		im.surface_add_vertex(b)
	match work_plane:
		"side":
			var z := work_depth * s
			for i in range(lo.x, hi.x + 1):
				line.call(Vector3(i * s, lo.y * p, z), Vector3(i * s, hi.y * p, z), i % 4 == 0)
			for j in range(lo.y - lo.y % 3, hi.y + 1, 3):
				line.call(Vector3(lo.x * s, j * p, z), Vector3(hi.x * s, j * p, z), j % 12 == 0)
		"top":
			var y := work_height * p
			for i in range(lo.x, hi.x + 1):
				line.call(Vector3(i * s, y, lo.z * s), Vector3(i * s, y, hi.z * s), i % 4 == 0)
			for i in range(lo.z, hi.z + 1):
				line.call(Vector3(lo.x * s, y, i * s), Vector3(hi.x * s, y, i * s), i % 4 == 0)
		"front":
			var x := work_x * s
			for i in range(lo.z, hi.z + 1):
				line.call(Vector3(x, lo.y * p, i * s), Vector3(x, hi.y * p, i * s), i % 4 == 0)
			for j in range(lo.y - lo.y % 3, hi.y + 1, 3):
				line.call(Vector3(x, j * p, lo.z * s), Vector3(x, j * p, hi.z * s), j % 12 == 0)
	im.surface_end()


# ---------------------------------------------------------------------------
# Round 2: a floating build area, a starting brick, autosave
# ---------------------------------------------------------------------------

## No floor here: a build floats, and starts from one brick.
func _lay_baseplate() -> void:
	pass


func _baseplate_blocks() -> int:
	return 0


## The brick a build starts from: a 1x4 along the gun on the mirror plane, mid-air.
func _ensure_start_brick() -> void:
	if not auto_start_brick or recipe.size() > 0 or _loading:
		return
	var arch := ""
	for yaw in 2:
		var name := BrickPalette.variant_name("brick_1x4", yaw, false)
		if BrickPalette.size_of(name).x == 4:
			arch = name
	if arch == "":
		return
	var keep := _batch
	_batch = true
	place_named(arch, Vector3i(plate_studs / 2 - 2, work_height, int(floor(mirror_z))))
	_batch = keep
	_after_edit()
	_edit_groups.clear()


func _look_at_build() -> void:
	if view != 0:
		return
	var c := build_centre()
	_camera.global_position = c + Vector3(-5.0, 3.0, 8.0)
	_camera.look_at(c, Vector3.UP)


func _restore_autosave() -> void:
	var r := BuildRecipe.load_from(AUTOSAVE)
	if r == null or not r.has_content():
		return
	_load_recipe(r)
	_current_path = ""
	print("[asset workshop] the last session's build is back (autosave). Ctrl N starts a new one.")


# ---------------------------------------------------------------------------
# Round 2: photos -- a stud grid, depth, dragging, calibrating in studs
# ---------------------------------------------------------------------------

## "852" is mm on the real thing; "53s" or "53 studs" is studs here (16 mm each).
static func length_mm(text: String) -> float:
	var t := text.strip_edges().to_lower()
	var studs := t.ends_with("s") or t.contains("stud")
	t = t.replace("studs", "").replace("stud", "").rstrip("s").strip_edges()
	if not t.is_valid_float():
		return -1.0
	return float(t) * (PRINT_MM_PER_STUD * REAL_PER_PRINT if studs else 1.0)


## Put a side photo just behind the build, or through the middle of it.
func set_photo_depth(i: int, where: String) -> void:
	var p: Dictionary = photos[i]
	if p.plane != "side":
		return
	var z := mirror_z * BrickPalette.STUD_M
	if where == "behind" and recipe.size() > 0:
		var b := recipe.bounds()
		z = (b[0] as Vector3i).z * BrickPalette.STUD_M - BrickPalette.STUD_M * 0.5
	p.centre = Vector3((p.centre as Vector3).x, (p.centre as Vector3).y, z)
	_fit_photo(p)
	_store_asset_meta()


## Alt + LMB on the selected photo drags it about its plane.
func _photo_input(e: InputEvent) -> bool:
	if photo_sel < 0:
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and e.alt_pressed:
			var ray := _mouse_ray()
			var hit = ray_on_photo(photo_sel, ray[0], ray[1])
			if hit == null:
				return false
			_photo_drag = [hit, photos[photo_sel].centre]
			return true
		if not e.pressed and _photo_drag != null:
			_photo_drag = null
			_store_asset_meta()
			return true
	if e is InputEventMouseMotion and _photo_drag != null:
		var ray := _mouse_ray()
		var hit = ray_on_photo(photo_sel, ray[0], ray[1])
		if hit != null:
			var p: Dictionary = photos[photo_sel]
			p.centre = (_photo_drag[1] as Vector3) + ((hit as Vector3) - (_photo_drag[0] as Vector3))
			_fit_photo(p)
		return true
	return false


## Alt + wheel in a flat view: zoom about the point under the cursor (Ctrl + wheel sizes the
## shape brush).
func _zoom_input(e: InputEvent) -> bool:
	if view == 0 or not (e is InputEventMouseButton) or not e.pressed:
		return false
	if not e.alt_pressed:
		return false
	if e.button_index != MOUSE_BUTTON_WHEEL_UP and e.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	var ray := _mouse_ray()
	zoom_at(ray[0], 0.85 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.85)
	return true


## Zoom a flat view by `by`, keeping the point at `under` (on the camera's own plane)
## where it is on the screen.
func zoom_at(under: Vector3, by: float) -> void:
	var n := -_camera.global_transform.basis.z
	var cam := _camera.global_position
	var d := cam - under
	var flat := d - n * d.dot(n)
	zoom(by)
	_camera.global_position = under + flat * by + n * d.dot(n)


func _draw_photo_grid() -> void:
	var im := ImmediateMesh.new()
	_photo_lines.mesh = im
	if not photo_grid or photo_sel < 0 or photo_sel >= photos.size():
		return
	var p: Dictionary = photos[photo_sel]
	if p.plane != "side" or not bool(p.shown):
		return
	var size := Vector2(p.px) * float(p.mpp)
	var c: Vector3 = p.centre
	var x0 := c.x - size.x * 0.5
	var x1 := c.x + size.x * 0.5
	var y0 := c.y - size.y * 0.5
	var y1 := c.y + size.y * 0.5
	var z := c.z + 0.01
	var s := BrickPalette.STUD_M
	var brick := BrickPalette.PLATE_M * 3.0
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(int(ceil(x0 / s)), int(floor(x1 / s)) + 1):
		var col := Color(1.0, 0.95, 0.3, 0.75 if i % 10 == 0 else 0.3)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(i * s, y0, z))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(i * s, y1, z))
	for j in range(int(ceil(y0 / brick)), int(floor(y1 / brick)) + 1):
		var col := Color(1.0, 0.95, 0.3, 0.3)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(x0, j * brick, z))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(x1, j * brick, z))
	im.surface_end()


# ---------------------------------------------------------------------------
# Round 2: sketch -- draw an outline, fill it with bricks
# ---------------------------------------------------------------------------

func width_of(part: String) -> int:
	return int(part_width.get(part, 3))


func _plane_value(plane: String) -> float:
	match plane:
		"front": return float(work_x)
		"top": return float(work_height)
	return work_depth


## Which kept sketch the current part, plane and depth draw into.
func _sketch_key() -> String:
	return "%s|%s|%s" % [part_names[part_sel], work_plane, _num(_plane_value(work_plane))]


func _sketch_input(e: InputEvent) -> bool:
	if tool != "sketch":
		return false
	if sketch_draw == "sculpt":
		return _sculpt_input(e)
	if sketch_draw == "polygon":
		return _polygon_input(e)
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if e.pressed:
			_sketch.clear()
			_sketch_out = e.button_index == MOUSE_BUTTON_RIGHT
			var q = _sketch_mouse()
			if q != null:
				_sketch_anchor = q
				_sketch.append(q)
		else:
			_sketch_commit()
		return true
	if e is InputEventMouseMotion and not _sketch.is_empty() and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		_sketch_add()
		return true
	return false


# ---------------------------------------------------------------------------
# The SDF block-out: sculpting (Docs/AssetWorkshop.md, "The SDF block-out")
# ---------------------------------------------------------------------------

## LMB / RMB with the sculpt brush: one stroke is one undo. Shift smooths whatever the
## mode. A stroke that adds keeps the depth it started at (the surface it is adding to
## would pull it toward the camera); the others follow the surface.
func _sculpt_input(e: InputEvent) -> bool:
	if sculpt_state == "bricks":
		# Converted: only bricks are shown. Edit as SDF brings the block-out back.
		sculpt.show_cursor(null, 0.0, Color.WHITE)
		if e is InputEventMouseButton and e.pressed and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_show_sculpt_note(true)
			return true
		return false
	if _gizmo_input(e) or _model_pick_input(e):
		return true
	var stamping: bool = sculpt_mode == "stamp" and not (e is InputEventWithModifiers and e.shift_pressed and not _sculpt_on)
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if e.pressed:
			# Sculpting on: a placed model is laid first (its stamp is one undo before this).
			_set_down()
			var right: bool = e.button_index == MOUSE_BUTTON_RIGHT
			if stamping and sculpt_shape == "lathe" and not _lathe_axis.is_empty():
				# The axis is down: LMB adds a point of the outline, RMB lays it.
				if right:
					lathe_finish()
				else:
					var q = _sculpt_point(false)
					if q != null:
						lathe_click(q)
				return true
			_sculpt_op = _sculpt_op_for(right, e.shift_pressed)
			var p = _sculpt_point(true)
			if p == null:
				return true
			_sculpt_on = true
			if stamping:
				# A stamp: dragged out on the stroke plane, laid when let go.
				_stamp_from = _stamp_snap(p)
				_stamp_to = _stamp_from
				_show_stamp()
				return true
			if sculpt_mode == "flatten" and not e.shift_pressed:
				_flat_point = p
				_flat_normal = _sculpt_plane.normal if sculpt_place == "work" else _field_normal(p)
			sculpt.form.begin_edit()
			_sculpt_dab(p, p)
		elif _sculpt_on:
			if stamping and sculpt_shape == "lathe":
				# The axis dragged: now the outline, a click a point.
				_sculpt_on = false
				if _stamp_from.distance_to(_stamp_to) >= 1.0:
					_lathe_axis = [_stamp_from, _stamp_to]
					_lathe_pts = PackedVector2Array()
					_lathe_op = SdfForm.REMOVE if _sculpt_op == SdfForm.REMOVE else SdfForm.ADD
				_show_stamp()
				_show_sculpt_note(false, "Lathe: click the outline's points, out from the axis. "
						+ "Enter or RMB lays it, Backspace takes a point back, Esc drops it.")
				return true
			if stamping:
				_sculpt_on = false
				sculpt.show_ghost({})
				sculpt.form.begin_edit()
				_lay_stamp(_stamp_desc(), _sculpt_op)
				sculpt.remesh()
				_sculpt_record(sculpt.form.end_edit())
				return true
			_sculpt_end()
		return true
	if e is InputEventMouseMotion:
		var p = _sculpt_point(false)
		sculpt.show_cursor(p, _sculpt_r(), _sculpt_colour(),
				_sculpt_plane.normal if sculpt_place != "surface" or stamping else Vector3.ZERO)
		if _sculpt_on and stamping:
			if p != null:
				_stamp_to = _stamp_snap(p)
				_show_stamp()
			return true
		if stamping and sculpt_shape == "lathe" and not _lathe_axis.is_empty():
			_show_stamp(p)
			return false
		if _sculpt_on and p != null and p.distance_to(_sculpt_last) > maxf(0.3, _sculpt_r() * 0.25):
			_sculpt_dab(_sculpt_last, p)
		return _sculpt_on
	return false


## The surface's outward direction at `p` (samples): the field's gradient.
func _field_normal(p: Vector3) -> Vector3:
	var f := sculpt.form
	var g := Vector3(f.sample(p + Vector3.RIGHT) - f.sample(p + Vector3.LEFT),
			f.sample(p + Vector3.UP) - f.sample(p + Vector3.DOWN),
			f.sample(p + Vector3.BACK) - f.sample(p + Vector3.FORWARD))
	return g.normalized() if g.length_squared() > 1e-6 else _sculpt_plane.normal


## A stamp's drag point on the brick grid when snapping: half a stud along and across, a
## plate up (samples: 2.5 and 2), so a box's faces land on brick faces.
func _stamp_snap(p: Vector3) -> Vector3:
	if not sculpt_snap:
		return p
	var s := Vector3(BrickWorld.ticks_per_stud() * 0.5, BrickWorld.ticks_per_plate(), BrickWorld.ticks_per_stud() * 0.5)
	return (p / s).round() * s


## The stamp being dragged, as what to lay: {kind: "box", center, half} | {kind: "cone",
## xform, size} | {kind: "line", a, b, r} | {kind: "lathe", xform, profile}. Empty when
## there is nothing to lay yet. `mouse`: a lathe's next point, shown before it is clicked.
func _stamp_desc(mouse: Variant = null) -> Dictionary:
	var a := _stamp_from
	var b := _stamp_to
	var r := _sculpt_r()
	var n := _sculpt_plane.normal.abs()
	match sculpt_shape:
		"lathe":
			if _lathe_axis.is_empty():
				# Dragging the axis: shown as a thin rod.
				return {"kind": "line", "a": a, "b": b, "r": 0.4}
			var prof := _lathe_pts.duplicate()
			if mouse != null:
				prof.append(_lathe_point(mouse))
			return _lathe_desc(_lathe_axis[0], _lathe_axis[1], prof)
		"box":
			# The footprint corner to corner on the plane; across it the brush's diameter.
			var lo := a.min(b)
			var hi := a.max(b)
			var mid := (lo + hi) * 0.5
			var half := (hi - lo) * 0.5
			var across := r
			if sculpt_snap:
				var step := n.dot(Vector3(BrickWorld.ticks_per_stud(), BrickWorld.ticks_per_plate(), BrickWorld.ticks_per_stud()))
				across = maxf(step * 0.5, roundf(r * 2.0 / step) * step * 0.5)
			half = half * (Vector3.ONE - n) + n * across
			half = half.max(Vector3.ONE * 0.5)
			return {"kind": "box", "center": mid, "half": half}
		"cylinder", "cone":
			if a.distance_to(b) < 0.5:
				return {}
			return _cone_desc(a, b, r, r if sculpt_shape == "cylinder" else 0.0)
		"ball":
			return {"kind": "line", "a": a, "b": a, "r": maxf(a.distance_to(b), 0.5)}
	return {"kind": "line", "a": a, "b": b, "r": r}


## A capped cone from `a` (radius `r1`) to `b` (radius `r2`), samples: a rigid frame with y
## along the axis.
func _cone_desc(a: Vector3, b: Vector3, r1: float, r2: float) -> Dictionary:
	var y := (b - a).normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).normalized()
	return {"kind": "cone", "a": a, "b": b, "xform": Transform3D(Basis(x, y, x.cross(y)), (a + b) * 0.5),
			"size": Vector3(r1, a.distance_to(b) * 0.5, r2)}


func _show_stamp(mouse: Variant = null) -> void:
	var carve := _lathe_op == SdfForm.REMOVE if not _lathe_axis.is_empty() else _sculpt_op == SdfForm.REMOVE
	sculpt.show_ghost(_stamp_desc(mouse), Color(1.0, 0.4, 0.35) if carve else Color(0.6, 0.9, 1.0))


## A lathe on the axis from `a` to `b` (samples): a frame with y along the axis from its
## middle, and the outline as (out, along) in it.
func _lathe_desc(a: Vector3, b: Vector3, prof: PackedVector2Array) -> Dictionary:
	var c := _cone_desc(a, b, 0.0, 0.0)
	return {"kind": "lathe", "a": a, "b": b, "xform": c.xform, "profile": prof}


## A point on the stroke plane as a lathe outline point: how far out from the axis, how
## far along it from its middle.
func _lathe_point(p: Vector3) -> Vector2:
	var a: Vector3 = _lathe_axis[0]
	var b: Vector3 = _lathe_axis[1]
	var y := (b - a).normalized()
	var mid := (a + b) * 0.5
	var along := (p - mid).dot(y)
	return Vector2((p - mid - y * along).length(), along)


## A click while drawing a lathe's outline: a point, or -- on the last point -- lay it.
func lathe_click(p: Vector3) -> void:
	var q := _lathe_point(p)
	if not _lathe_pts.is_empty() and q.distance_to(_lathe_pts[_lathe_pts.size() - 1]) < 1.0:
		lathe_finish()
		return
	_lathe_pts.append(q)
	_show_stamp(p)


## Lay the lathe drawn so far (one undo), or drop it if its outline has no length.
func lathe_finish() -> void:
	if _lathe_axis.is_empty():
		return
	if _lathe_pts.size() >= 2:
		sculpt.form.begin_edit()
		_lay_stamp(_lathe_desc(_lathe_axis[0], _lathe_axis[1], _lathe_pts), _lathe_op)
		sculpt.remesh()
		_sculpt_record(sculpt.form.end_edit())
	lathe_drop()


func lathe_drop() -> void:
	_lathe_axis = []
	_lathe_pts = PackedVector2Array()
	sculpt.show_ghost({})
	_show_sculpt_note()


## Keys while a lathe's outline is drawn: Enter lays it, Backspace takes a point back,
## Escape drops it. True when the key was the lathe's.
func _lathe_key(e: InputEvent) -> bool:
	if _lathe_axis.is_empty() or not (e is InputEventKey and e.pressed):
		return false
	match (e as InputEventKey).keycode:
		KEY_ENTER, KEY_KP_ENTER:
			lathe_finish()
		KEY_BACKSPACE:
			if not _lathe_pts.is_empty():
				_lathe_pts.resize(_lathe_pts.size() - 1)
			_show_stamp()
		KEY_ESCAPE:
			lathe_drop()
		_:
			return false
	return true


## Lay a stamp (and its mirror image when the mirror is on).
func _lay_stamp(d: Dictionary, op: int) -> void:
	if d.is_empty():
		return
	if sculpt.palette.size() < part_names.size() + 1:
		sculpt.set_parts(part_names.size())
	var blend := sculpt_blend * BrickWorld.ticks_per_stud()
	var part := part_sel + 1
	match String(d.kind):
		"box": sculpt.form.box(op, d.center, d.half, blend, part)
		"cone": sculpt.form.shape(op, SdfForm.SHAPE_CONE, d.xform, d.size, blend, part)
		"lathe": sculpt.form.lathe(op, d.xform, d.profile, blend, part)
		_: sculpt.form.stroke(op, d.a, d.b, d.r, blend, part)
	if mirror_on:
		var m := d.duplicate()
		match String(d.kind):
			"box": m.center = _mirror_sample(d.center)
			"cone": m = _cone_desc(_mirror_sample(d.a), _mirror_sample(d.b), d.size.x, d.size.z)
			"lathe": m = _lathe_desc(_mirror_sample(d.a), _mirror_sample(d.b), d.profile)
			_:
				m.a = _mirror_sample(d.a)
				m.b = _mirror_sample(d.b)
		match String(m.kind):
			"box": sculpt.form.box(op, m.center, m.half, blend, part)
			"cone": sculpt.form.shape(op, SdfForm.SHAPE_CONE, m.xform, m.size, blend, part)
			"lathe": sculpt.form.lathe(op, m.xform, m.profile, blend, part)
			_: sculpt.form.stroke(op, m.a, m.b, m.r, blend, part)


## A sample point mirrored across the mirror plane.
func _mirror_sample(s: Vector3) -> Vector3:
	var w := sculpt.to_world(s)
	w.z = 2.0 * mirror_z * BrickPalette.STUD_M - w.z
	return sculpt.to_sample(w)


func _sculpt_op_for(right: bool, shift: bool) -> int:
	if shift or sculpt_mode == "smooth":
		return SdfForm.SMOOTH
	match sculpt_mode:
		"paint": return SdfForm.PAINT
		"zone": return SdfForm.UNMARK if right else SdfForm.MARK
		"grow": return SdfForm.GROW
		"flatten": return OP_FLATTEN
	return SdfForm.REMOVE if right else SdfForm.ADD


## The brush's radius in samples (a stud is 5).
func _sculpt_r() -> float:
	return maxf(0.5, sculpt_radius * BrickWorld.ticks_per_stud())


func _sculpt_colour() -> Color:
	if _sculpt_on and _sculpt_op == SdfForm.REMOVE:
		return Color(1.0, 0.35, 0.3)
	if sculpt_mode == "paint" and part_sel + 1 < sculpt.palette.size():
		return sculpt.palette[part_sel + 1]
	return Color(0.6, 0.9, 1.0)


## Where the brush is, in samples, or null (after Blender's Grease Pencil "stroke
## placement"). A stroke starts on the block-out's surface under the mouse, else on the
## working plane. Then, placed "on a plane", it stays on the plane through its start that
## faces the camera most squarely (one of the grid's three), and "on the working plane"
## on a plane parallel to that one -- kept for the whole stroke, so turning or flying the
## camera does not bend it (a fixed distance from the camera once did: strokes curved
## round the player). "On the surface" follows the surface all the way.
func _sculpt_point(start: bool) -> Variant:
	var ray := _mouse_ray()
	var r := sculpt.ray_to_samples(ray[0], ray[1])
	if _sculpt_on and not start and (sculpt_place != "surface" or sculpt_mode == "stamp"):
		return _sculpt_plane.intersects_ray(r[0], r[1])
	var h = sculpt.hit(ray[0], ray[1]) if sculpt_place != "work" else null
	if h == null:
		var w = work_plane_hit(ray[0], ray[1])
		if w == null:
			return null
		h = sculpt.to_sample(w)
	if not _sculpt_on or start:
		_sculpt_plane = Plane(_sculpt_normal(r[1]), h)
	return h


## The normal of the plane a stroke stays on: the working plane's, or the grid axis the
## view looks along most (samples run along the grid's axes).
func _sculpt_normal(dir: Vector3) -> Vector3:
	if sculpt_place == "work":
		match work_plane:
			"top": return Vector3.UP
			"front": return Vector3.RIGHT
		return Vector3.BACK
	var a := dir.abs()
	if a.x >= a.y and a.x >= a.z:
		return Vector3.RIGHT
	return Vector3.UP if a.y >= a.z else Vector3.BACK


## A capsule of the brush from `a` to `b`, and its mirror image when the mirror is on.
func _sculpt_dab(a: Vector3, b: Vector3) -> void:
	if sculpt.palette.size() < part_names.size() + 1:
		sculpt.set_parts(part_names.size())
	if _sculpt_op == OP_FLATTEN:
		sculpt.form.flatten(b, _sculpt_r(), _flat_normal, _flat_point, sculpt_strength, part_sel + 1)
		if mirror_on:
			sculpt.form.flatten(_mirror_sample(b), _sculpt_r(), _flat_normal * Vector3(1, 1, -1),
					_mirror_sample(_flat_point), sculpt_strength, part_sel + 1)
		sculpt.remesh()
		_sculpt_last = b
		return
	var blend := 0.5 if _sculpt_op == SdfForm.SMOOTH else sculpt_blend * BrickWorld.ticks_per_stud()
	if _sculpt_op == SdfForm.GROW:
		# Samples a dab: LMB swells, RMB shrinks.
		blend = sculpt_strength * 1.5 * (-1.0 if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) else 1.0)
	sculpt.form.stroke(_sculpt_op, a, b, _sculpt_r(), blend, part_sel + 1)
	if mirror_on:
		var z := mirror_z * BrickPalette.STUD_M
		var ma := sculpt.to_world(a)
		var mb := sculpt.to_world(b)
		ma.z = 2.0 * z - ma.z
		mb.z = 2.0 * z - mb.z
		sculpt.form.stroke(_sculpt_op, sculpt.to_sample(ma), sculpt.to_sample(mb), _sculpt_r(), blend, part_sel + 1)
	sculpt.remesh()
	_sculpt_last = b


func _sculpt_end() -> void:
	_sculpt_on = false
	_sculpt_record(sculpt.form.end_edit())


## An edit of the field, as one undo.
func _sculpt_record(rec: PackedByteArray) -> void:
	_edit_groups.append({"end": _edits.size(), "n": 0, "sketch": [{"sdf": rec}]})
	_redo.clear()
	_sdf_meta = sculpt.save_meta()
	_store_asset_meta()
	_autosave_dirty = true


## The guide models made solid in the field, in this part: a quick start from a model.
## A guide model into the current part's field (ADD) or carved out of it (REMOVE), where
## the guide stands now. One undo. Returns how many meshes went in.
func sculpt_model_into(i: int, op: int) -> int:
	if i < 0 or i >= guides.size():
		_show_sculpt_note(true, "No model yet: add a 3D model first.")
		return 0
	if sculpt.palette.size() < part_names.size() + 1:
		sculpt.set_parts(part_names.size())
	sculpt.form.begin_edit()
	var n := 0
	for mi in (guides[i].node as Node).find_children("*", "MeshInstance3D", true, false):
		_stamp_soup(_mesh_soup((mi as MeshInstance3D).mesh), (mi as MeshInstance3D).global_transform, op)
		n += 1
	sculpt.remesh()
	_sculpt_record(sculpt.form.end_edit())
	_show_sculpt_note(false, "%s %s %s." % [String(guides[i].path).get_file(),
			"went into" if op == SdfForm.ADD else "was carved out of", part_names[part_sel]])
	return n


## The guide picked in the guide panel, else the last one loaded; -1 for none.
func _picked_guide() -> int:
	if guides.is_empty():
		return -1
	if _guide_list != null and _guide_list.selected >= 0 and _guide_list.selected < guides.size():
		return _guide_list.selected
	return guides.size() - 1


## A mesh's surfaces as one triangle soup [vertices, index]: a model split by material
## into surfaces is still one closed solid, and the stamp tells inside from outside by
## counting crossings through all of it at once.
static func _mesh_soup(mesh: Mesh) -> Array:
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	for si in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(si)
		var sv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var si_idx = arr[Mesh.ARRAY_INDEX]
		var base := v.size()
		v.append_array(sv)
		if si_idx == null or (si_idx as PackedInt32Array).is_empty():
			for k in sv.size():
				idx.append(base + k)
		else:
			for k in (si_idx as PackedInt32Array):
				idx.append(base + k)
	return [v, idx]


## A soup into the current part's field, placed by `xf` (global). Inside an edit.
func _stamp_soup(soup: Array, xf: Transform3D, op: int) -> void:
	var to_s := sculpt.global_transform.affine_inverse() * xf
	var v: PackedVector3Array = (soup[0] as PackedVector3Array).duplicate()
	for i in v.size():
		v[i] = to_s * v[i]
	sculpt.form.stamp_mesh(op, v, soup[1], part_sel + 1)


## Size and smoothness of the whole block-out, each one undo.
func sculpt_scale(factor: float) -> void:
	var bb := sculpt.form.bounds()
	if bb.size == Vector3.ZERO or is_equal_approx(factor, 1.0):
		return
	sculpt.form.begin_edit()
	sculpt.form.scale(factor, Vector3(bb.get_center().x, bb.position.y, bb.get_center().z))
	sculpt.remesh()
	_sculpt_record(sculpt.form.end_edit())


func sculpt_smooth(passes: int) -> void:
	sculpt.form.begin_edit()
	sculpt.form.blur(passes)
	sculpt.remesh()
	_sculpt_record(sculpt.form.end_edit())


func sculpt_clear() -> void:
	sculpt.form.begin_edit()
	sculpt.form.clear()
	sculpt.remesh()
	_sculpt_record(sculpt.form.end_edit())



## The sculpt brush's options, at the top of the Block out panel.
func _build_sculpt_box() -> void:
	_sculpt_box = VBoxContainer.new()
	_sculpt_box.visible = sketch_draw == "sculpt"
	_sketch_box.add_child(_sculpt_box)
	var how := Label.new()
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.custom_minimum_size.x = RAIL_W - 16
	how.text = ("Sculpt in 3D: LMB adds to this part, RMB carves, Shift smooths. "
			+ "The brush starts on the working plane, then follows the surface; an add keeps "
			+ "the depth it started at. Parts blend while sculpting; each has its colour. "
			+ "Convert makes it all bricks, except what is marked smooth (lighter): that "
			+ "becomes the part's custom piece.")
	_sculpt_box.add_child(how)
	_sculpt_note = Label.new()
	_sculpt_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sculpt_note.custom_minimum_size.x = RAIL_W - 16
	_sculpt_note.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	_sculpt_box.add_child(_sculpt_note)
	_show_sculpt_note()
	var modes := OptionButton.new()
	for m in SCULPT_MODES:
		modes.add_item(m[1])
	modes.focus_mode = Control.FOCUS_NONE
	_sculpt_box.add_child(modes)
	# Stamp: its shape and the grid snap; flatten and grow: their strength.
	var shapes := OptionButton.new()
	for m in SCULPT_SHAPES:
		shapes.add_item(m[1])
	shapes.focus_mode = Control.FOCUS_NONE
	shapes.item_selected.connect(func(i: int) -> void:
		lathe_drop()
		sculpt_shape = SCULPT_SHAPES[i][0])
	_sculpt_box.add_child(shapes)
	var snap := CheckBox.new()
	snap.text = "snap to the brick grid"
	snap.button_pressed = sculpt_snap
	snap.focus_mode = Control.FOCUS_NONE
	snap.toggled.connect(func(on: bool) -> void: sculpt_snap = on)
	_sculpt_box.add_child(snap)
	var strength_label := Label.new()
	var strength := HSlider.new()
	strength.min_value = 0.05
	strength.max_value = 1.0
	strength.step = 0.05
	strength.value = sculpt_strength
	strength.focus_mode = Control.FOCUS_NONE
	strength.custom_minimum_size.x = 150
	strength_label.text = "strength: %.2f" % sculpt_strength
	strength.value_changed.connect(func(x: float) -> void:
		sculpt_strength = x
		strength_label.text = "strength: %.2f" % x)
	_sculpt_box.add_child(strength_label)
	_sculpt_box.add_child(strength)
	var show_for := func(mode: String) -> void:
		shapes.visible = mode == "stamp"
		snap.visible = mode == "stamp"
		strength_label.visible = mode in ["flatten", "grow"]
		strength.visible = mode in ["flatten", "grow"]
	show_for.call(sculpt_mode)
	modes.item_selected.connect(func(i: int) -> void:
		sculpt_mode = SCULPT_MODES[i][0]
		show_for.call(sculpt_mode))
	var places := OptionButton.new()
	for m in SCULPT_PLACES:
		places.add_item(m[1])
	places.focus_mode = Control.FOCUS_NONE
	places.item_selected.connect(func(i: int) -> void: sculpt_place = SCULPT_PLACES[i][0])
	_sculpt_box.add_child(places)
	var slider := func(text: String, lo: float, hi: float, step: float, v: float, set_v: Callable) -> HSlider:
		var l := Label.new()
		_sculpt_box.add_child(l)
		var hs := HSlider.new()
		hs.min_value = lo
		hs.max_value = hi
		hs.step = step
		hs.focus_mode = Control.FOCUS_NONE
		hs.custom_minimum_size.x = 150
		hs.value_changed.connect(func(x: float) -> void:
			l.text = text % x
			set_v.call(x))
		hs.value = v
		l.text = text % v
		_sculpt_box.add_child(hs)
		return hs
	slider.call("brush radius: %.1f studs", 0.2, 10.0, 0.1, sculpt_radius,
			func(x: float) -> void: sculpt_radius = x)
	slider.call("blend: %.1f studs", 0.0, 3.0, 0.1, sculpt_blend,
			func(x: float) -> void: sculpt_blend = x)
	# Size: let go and the whole block-out is scaled about its bottom middle, one undo.
	var size_label := Label.new()
	var size_s := HSlider.new()
	size_s.min_value = 25
	size_s.max_value = 300
	size_s.step = 5
	size_s.value = 100
	size_s.focus_mode = Control.FOCUS_NONE
	size_s.custom_minimum_size.x = 150
	size_label.text = "size of the block-out: 100%"
	size_s.value_changed.connect(func(x: float) -> void: size_label.text = "size of the block-out: %d%%" % int(x))
	size_s.drag_ended.connect(func(_c: bool) -> void:
		sculpt_scale(size_s.value / 100.0)
		size_s.set_value_no_signal(100)
		size_label.text = "size of the block-out: 100%")
	_sculpt_box.add_child(size_label)
	_sculpt_box.add_child(size_s)
	# Detail of this part's custom piece (after Convert): its triangles, applied on let go.
	var tris_label := Label.new()
	var tris_s := HSlider.new()
	tris_s.min_value = 2.5
	tris_s.max_value = 4.5
	tris_s.step = 0.05
	tris_s.value = log(float(SDF_PIECE_TRIS)) / log(10.0)
	tris_s.focus_mode = Control.FOCUS_NONE
	tris_s.custom_minimum_size.x = 150
	var tris_text := func(x: float) -> void:
		tris_label.text = "this part's piece: %d triangles" % int(pow(10.0, x))
	tris_text.call(tris_s.value)
	tris_s.value_changed.connect(tris_text)
	tris_s.drag_ended.connect(func(_c: bool) -> void:
		sculpt_piece_detail(part_names[clampi(part_sel, 0, part_names.size() - 1)], int(pow(10.0, tris_s.value))))
	_sculpt_box.add_child(tris_label)
	_sculpt_box.add_child(tris_s)
	var row := HFlowContainer.new()
	_sculpt_box.add_child(row)
	for b in [["smoother", func() -> void: sculpt_smooth(1)],
			["add a 3D model...", func() -> void:
				_guide_into_sdf = true
				_guide_dialog.popup_centered_ratio(0.6)],
			["model into this part", func() -> void: model_op(SdfForm.ADD)],
			["carve the model out", func() -> void: model_op(SdfForm.REMOVE)],
			["lay the model (Enter)", func() -> void: lay_model()],
			["snap to studs", func() -> void: snap_to_studs()],
			["centre on mirror", func() -> void: centre_on_mirror()],
			["clear", func() -> void: sculpt_clear()],
			["Convert", func() -> void: sculpt_convert()],
			["Edit as SDF", func() -> void: sculpt_to_sdf()]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(b[1])
		row.add_child(btn)
	_build_nudge_row(_sculpt_box)
	_build_models_box(_sculpt_box)
	_build_size_row(_sculpt_box)
	_sculpt_box.add_child(HSeparator.new())

# ---------------------------------------------------------------------------
# The SDF block-out: Convert, and back (Docs/AssetWorkshop.md, "The SDF block-out")
# ---------------------------------------------------------------------------

## Every upright brick's cells with its part: as `SdfForm.cells` gives them (label is the
## part + 1), for `sync_cells`.
func _brick_cell_list() -> PackedInt32Array:
	# A slope or a curve fills only part of its box: the cells of it the field had at the
	# last Convert are what it stands for (so one Convert laid goes back unchanged); one
	# laid since counts whole.
	var had := {}
	for i in range(0, _sdf_cells.size(), 5):
		had[Vector3i(_sdf_cells[i], _sdf_cells[i + 1], _sdf_cells[i + 2])] = true
	var m := {}
	for i in recipe.size():
		if _brick_frame(i) != 0:
			continue
		var c := recipe.cell_of(i)
		var arch := recipe.part_of(i)
		var size := BrickPalette.size_of(arch)
		var part := (part_of[i] if i < part_of.size() else 0) + 1
		var cs := []
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					cs.append(c + Vector3i(dx, dy, dz))
		if BrickPalette.is_shaped(BrickPalette.part_of(arch)):
			var kept := cs.filter(func(k: Vector3i) -> bool: return had.has(k))
			if not kept.is_empty():
				cs = kept
		for k in cs:
			m[k] = part
	var out := PackedInt32Array()
	for c in m:
		out.append_array([c.x, c.y, c.z, m[c], 0])
	return out


## What Convert and Edit as SDF change besides bricks and the field, for undo.
func _sculpt_state() -> Dictionary:
	return {"state": sculpt_state, "cells": _sdf_cells.duplicate(), "stash": _sdf_stash.duplicate(true),
			"shell_cells": _sdf_shell.duplicate(),
			"part_bricks": part_bricks.duplicate(true), "shells": shells.duplicate(true)}


func _set_sculpt_state(st: Dictionary) -> void:
	sculpt_state = String(st.state)
	_sdf_cells = PackedInt32Array(st.cells)
	_sdf_stash = (st.stash as Array).duplicate(true)
	_sdf_shell = PackedInt32Array(st.get("shell_cells", []))
	part_bricks = (st.part_bricks as Dictionary).duplicate(true)
	shells = (st.shells as Dictionary).duplicate(true)
	sculpt.visible = sculpt_state == "sdf"
	if sculpt_state == "sdf" and exploded:
		set_exploded(false)
	_show_sculpt_note()
	for part in _shell_nodes.keys():
		_shell_mesh(String(part), {})
	for part in shells:
		_refresh_shell(String(part))
	_sdf_meta = sculpt.save_meta()
	_store_asset_meta()


## The upright bricks into the field (the cells that changed since `before`) and taken up,
## kept so Convert can lay each back where the field still has it. Inside a gather.
func _bricks_into_field(before: PackedInt32Array, shell_cells := PackedInt32Array()) -> void:
	var after := _brick_cell_list()
	var have := {}
	for i in range(0, after.size(), 5):
		have[Vector3i(after[i], after[i + 1], after[i + 2])] = true
	for i in range(0, shell_cells.size(), 5):
		if not have.has(Vector3i(shell_cells[i], shell_cells[i + 1], shell_cells[i + 2])):
			after.append_array(shell_cells.slice(i, i + 5))
	sculpt.form.sync_cells(before, after)
	_batch = true
	for i in range(recipe.size() - 1, -1, -1):
		if _brick_frame(i) != 0:
			continue
		var b := _brick_info(i)
		var c: Vector3i = b.cell
		_sdf_stash.append([b.arch, c.x, c.y, c.z, b.colour, b.mat, b.tag])
		take_brick(i)
	_batch = false
	_after_edit()


## Edit as SDF: the bricks back into the block-out -- only the cells changed since the
## last Convert, so the smooth surface stays where they were not touched -- and the
## block-out shown again. A build never converted (bricks only) goes in whole. One undo.
func sculpt_to_sdf() -> void:
	# Not yet converted: whatever bricks there are (a bricks-only gun) go in whole.
	var before := _sdf_cells if sculpt_state == "bricks" else PackedInt32Array()
	_begin_gather()
	var was := _sculpt_state()
	sculpt.form.begin_edit()
	_bricks_into_field(before, _sdf_shell if sculpt_state == "bricks" else PackedInt32Array())
	var rec := sculpt.form.end_edit()
	for part in shells.keys():
		if shells[part].get("sdf", false):
			shells.erase(part)
	sculpt_state = "sdf"
	_sdf_cells = sculpt.form.cells()
	_sculpt_finish(was, rec)
	_end_gather()


## Convert: the block-out into the asset. Every solid cell gets a brick, in its part; a
## brick that was there before goes back where all its cells are still the part's, with
## its colour and shape; the rest packed biggest first. Cells in a brick zone stay bricks;
## the rest of a part becomes its custom piece -- a shell from the field, over bricks the
## game and the print leave out except where it meets bricks (the join, with studs).
## Bricks laid in the meantime go into the field first. One undo.
func sculpt_convert() -> void:
	_set_down()
	if sculpt_state == "bricks":
		return
	_begin_gather()
	var was := _sculpt_state()
	sculpt.form.begin_edit()
	_bricks_into_field(PackedInt32Array())
	var rec := sculpt.form.end_edit()
	# The models join the block-out for this Convert, and leave it after: they stay objects.
	var mrec := _models_into_field()
	var cells := sculpt.form.cells()
	var label_of := {}
	var zone := {}
	for i in range(0, cells.size(), 5):
		var c := Vector3i(cells[i], cells[i + 1], cells[i + 2])
		label_of[c] = cells[i + 3]
		if cells[i + 4] == 0:   # not marked smooth: bricks
			zone[c] = true
	# A brick in every zone cell; in a part's smooth cells only where the surface holds the
	# whole cell (inside its custom piece) or where it meets a brick (the join).
	var brick_at := {}
	_sdf_shell = PackedInt32Array()
	for c in label_of:
		if zone.has(c) or _cell_inside(c) or _cell_joins(c, label_of, zone):
			brick_at[c] = true
		else:
			_sdf_shell.append_array([c.x, c.y, c.z, label_of[c], 0])
	# With the mirror on, the near half is the truth and the far half its mirror image
	# (Docs/AssetWorkshop.md, "Symmetric Convert"); the plane on a stud line.
	var sym := mirror_on
	var pz := 0
	if sym:
		if not is_equal_approx(mirror_z, roundf(mirror_z)):
			set_mirror_z(ceilf(mirror_z))
			_show_sculpt_note(true, "The mirror was on a stud's middle: moved half a stud to a stud line, "
					+ "so the two halves can be joined. Centre on mirror lines the model up with it.")
		pz = int(roundf(mirror_z))
		_symmetric(label_of, pz)
		_symmetric(zone, pz)
		_symmetric(brick_at, pz)
		_sdf_shell = PackedInt32Array()
		for c in label_of:
			if not brick_at.has(c):
				_sdf_shell.append_array([c.x, c.y, c.z, label_of[c], 0])
	var keep_sel := part_sel
	var used := {}
	var colour_of := {}   # part -> [colour, material] of its first brick, for its piece
	var laid := {}   # part -> [[arch, [x, y, z]]] in smooth cells
	# Bricks packed new take their part's colour: the one most of its old bricks had, else
	# its piece's, else the hotbar's.
	var tally := {}   # label -> {[colour, material]: count}
	for s in _sdf_stash:
		var cm := [int(s[4]), int(s[5])]
		var t: Dictionary = tally.get_or_add(int(s[6]) + 1, {})
		t[cm] = int(t.get(cm, 0)) + 1
	var part_col := {}   # label -> [colour, material]
	for label in range(1, part_names.size() + 1):
		var st: Dictionary = shells.get(part_names[label - 1], {})
		part_col[label] = [int(st.colour), int(st.get("mat", 0))] if st.has("colour") else [-1, -1]
		var best := 0
		var t: Dictionary = tally.get(label, {})
		for cm in t:
			if t[cm] > best:
				best = t[cm]
				part_col[label] = cm
	_batch = true
	if sym:
		# Old bricks are one-sided: not laid again.
		_sdf_stash = []
	for s in _sdf_stash:
		var arch := String(s[0])
		var at := Vector3i(int(s[1]), int(s[2]), int(s[3]))
		var label := int(s[6]) + 1
		var size := BrickPalette.size_of(arch)
		var fits := true
		var cs := []
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					var c := at + Vector3i(dx, dy, dz)
					fits = fits and int(label_of.get(c, -1)) == label and brick_at.has(c) and not used.has(c)
					cs.append(c)
		if not fits:
			continue
		part_sel = label - 1
		if place_named(arch, at, int(s[4]), int(s[5])):
			for c in cs:
				used[c] = true
			_note_laid(laid, arch, at, cs, zone)
			colour_of.get_or_add(part_names[part_sel], [int(s[4]), int(s[5])])
	_sdf_stash = []
	var by_part := {}
	for c in brick_at:
		if not used.has(c):
			(by_part.get_or_add(maxi(1, int(label_of[c])), {}) as Dictionary)[c] = true
	for label in by_part:
		part_sel = clampi(int(label) - 1, 0, part_names.size() - 1)
		var col: Array = part_col.get(part_sel + 1, [-1, -1])
		var left: Dictionary = by_part[label]
		var mirror := false
		if sym:
			# The two columns either side of the plane first, bricks two studs across on it:
			# they join the halves. Then the near half, each brick mirrored across.
			var band := {}
			var near := {}
			for c in left:
				if c.z == pz - 1 or c.z == pz:
					band[c] = true
				elif c.z < pz - 1:
					near[c] = true
			for b in pack_cells(band, false, {}, 1 << 30, 2):
				_lay_converted(String(b[0]), b[1], col, laid, zone, colour_of, false)
			left = near
			mirror = true
		# Slopes, wedges and curves fitted to the field where they match it better than
		# the cells as bricks, as the curve slider has them (FitKit, SdfForm.fit_pieces).
		if curve_level >= 1:
			var free := PackedInt32Array()
			for c in left:
				if zone.has(c):
					free.append_array([c.x, c.y, c.z])
			var kit := FitKit.kit(curve_level >= 2)
			var fit := sculpt.form.fit_pieces(free, kit.pieces, SDF_FIT_EAGER if slope_eager else SDF_FIT_GAIN)
			var edges := []
			for i in range(0, fit.size(), 4):
				edges.append([kit.names[fit[i]], Vector3i(fit[i + 1], fit[i + 2], fit[i + 3])])
			for b in edges:
				var at: Vector3i = b[1]
				var size := BrickPalette.size_of(String(b[0]))
				var cs := []
				for dx in size.x:
					for dy in size.y:
						for dz in size.z:
							var c := at + Vector3i(dx, dy, dz)
							if left.has(c):
								cs.append(c)
				if not cs.is_empty() and place_named(String(b[0]), at, col[0], col[1]):
					for c in cs:
						left.erase(c)
					if mirror:
						_lay_mirrored(String(b[0]), at, col)
		for b in pack_cells(left):
			_lay_converted(String(b[0]), b[1], col, laid, zone, colour_of, mirror)
	_batch = false
	part_sel = keep_sel
	_after_edit()
	var smooth_parts_now := {}
	for c in label_of:
		if not zone.has(c):
			smooth_parts_now[part_names[clampi(int(label_of[c]) - 1, 0, part_names.size() - 1)]] = true
	for part in smooth_parts_now:
		part_bricks[part] = laid.get(part, [])
		var st: Dictionary = shells.get(part, {})
		var col: Array = colour_of.get(part, [int(st.get("colour", 0)), int(st.get("mat", 0))])
		shells[part] = {"sdf": true, "thick": 0.0, "res": 1, "tris": int(st.get("tris", SDF_PIECE_TRIS)),
				"colour": col[0], "mat": col[1]}
	sculpt_state = "bricks"
	_sdf_cells = cells
	_sculpt_finish(was, rec)
	_models_out(mrec)
	_end_gather()


## A packed brick laid by Convert, noted for its part's piece; `mirror`: and again across
## the mirror plane.
func _lay_converted(arch: String, at: Vector3i, col: Array, laid: Dictionary, zone: Dictionary,
		colour_of: Dictionary, mirror: bool) -> void:
	if not place_named(arch, at, col[0], col[1]):
		return
	var size := BrickPalette.size_of(arch)
	var cs := []
	for dx in size.x:
		for dy in size.y:
			for dz in size.z:
				cs.append(at + Vector3i(dx, dy, dz))
	_note_laid(laid, arch, at, cs, zone)
	var last: int = recipe.size() - 1
	colour_of.get_or_add(part_names[part_sel], [recipe.colour_of(last), recipe.material_of(last)])
	if mirror:
		var m := _lay_mirrored(arch, at, col)
		if m != _NO_CELL:
			var ms := []
			for c in cs:
				ms.append(Vector3i(c.x, c.y, 2 * int(roundf(mirror_z)) - 1 - c.z))
			_note_laid(laid, arch, m, ms, zone)


const _NO_CELL := Vector3i(-1073741824, 0, 0)


## A brick or shaped piece laid again across the mirror plane: a shaped one turned to its
## mirror image (FitKit.mirror_name). Where it went, or _NO_CELL when it could not be.
func _lay_mirrored(arch: String, at: Vector3i, col: Array) -> Vector3i:
	var size := BrickPalette.size_of(arch)
	var name := arch
	if BrickPalette.is_shaped(BrickPalette.part_of(arch)):
		name = FitKit.mirror_name(arch)
		if name == "":
			return _NO_CELL
	var m := Vector3i(at.x, at.y, mirrored_z(at.z, size.z))
	return m if place_named(name, m, col[0], col[1]) else _NO_CELL


## Cells made symmetric about the stud line `pz`: the near side's kept and mirrored onto
## the far side, the far side's own dropped.
static func _symmetric(cells: Dictionary, pz: int) -> void:
	var far := []
	for c in cells:
		if c.z >= pz:
			far.append(c)
	for c in far:
		cells.erase(c)
	var near := cells.keys()
	for c in near:
		cells[Vector3i(c.x, c.y, 2 * pz - 1 - c.z)] = cells[c]


## Move the mirror plane (studs across), the sheet with it.
func set_mirror_z(z: float) -> void:
	mirror_z = z
	_place_mirror_sheet()
	_store_asset_meta()


## Centre the placed model, else the block-out, on the mirror plane across z, the plane put
## on a stud line first: then Convert can mirror it brick for brick.
func centre_on_mirror() -> void:
	if not mirror_on:
		set_mirror(true)
	set_mirror_z(roundf(mirror_z))
	var plane := mirror_z * BrickPalette.STUD_M
	if not _placed.is_empty():
		var bb := (_placed.xf as Transform3D) * (_placed.box as AABB)
		var before := models_state()
		var xf: Transform3D = _placed.xf
		_placed.xf = Transform3D(xf.basis, xf.origin + Vector3(0, 0, plane - bb.get_center().z))
		_held_moved(before)
		return
	if sculpt_state == "bricks" or sculpt.form.block_count() == 0:
		return
	# The field's own middle across, from its inside samples: moved by whole samples (or a
	# half, resampled) so it sits on the plane.
	var bb := sculpt.form.bounds()
	var mid := bb.position.z + bb.size.z * 0.5
	move_field(Vector3(0, 0, roundf((mirror_z * BrickWorld.ticks_per_stud() - mid) * 2.0) * 0.5))


## The surface holds the whole cell: its corners and middle all inside the field.
func _cell_inside(c: Vector3i) -> bool:
	var per := Vector3(BrickWorld.ticks_per_stud(), BrickWorld.ticks_per_plate(), BrickWorld.ticks_per_stud())
	var o := Vector3(c) * per
	if sculpt.form.sample(o + per * 0.5) >= 0.0:
		return false
	for k in 8:
		if sculpt.form.sample(o + per * Vector3(k & 1, (k >> 1) & 1, (k >> 2) & 1)) >= 0.0:
			return false
	return true


## A part's smooth cell beside a brick zone or another part: where its piece meets bricks.
static func _cell_joins(c: Vector3i, label_of: Dictionary, zone: Dictionary) -> bool:
	for d in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
		var n: Vector3i = c + d
		if label_of.has(n) and (zone.has(n) or label_of[n] != label_of[c]):
			return true
	return false


## The SDF block-out is what is shown: something sculpted, not yet converted.
func _sculpting() -> bool:
	return sculpt != null and sculpt_state == "sdf" and sculpt.form.block_count() > 0


## The sculpt panel's line on where things stand; `loud` after a click it refused.
func _show_sculpt_note(loud: bool = false, text: String = "") -> void:
	if _sculpt_note == null:
		return
	if text == "":
		text = ("Converted: these are bricks now. Edit as SDF to sculpt again." if sculpt_state == "bricks"
				else "Sculpting: no bricks yet. Convert when the shape is right.")
	_sculpt_note.text = text
	if loud:
		var tw := _sculpt_note.create_tween()
		_sculpt_note.modulate = Color(1.6, 1.6, 1.6)
		tw.tween_property(_sculpt_note, "modulate", Color.WHITE, 0.6)


## How many triangles a part's custom piece is made of: its look. One undo.
func sculpt_piece_detail(part: String, tris: int) -> void:
	if not shells.has(part) or not shells[part].get("sdf", false):
		return
	var was := _sculpt_state()
	shells[part]["tris"] = clampi(tris, 50, 50000)
	var now := _sculpt_state()
	_edit_groups.append({"end": _edits.size(), "n": 0,
			"sketch": [{"sculpt_before": was, "sculpt_after": now}]})
	_redo.clear()
	_set_sculpt_state(now)
	_autosave_dirty = true


## A brick laid by Convert in a part's smooth cells: one its shell covers.
func _note_laid(laid: Dictionary, arch: String, at: Vector3i, cs: Array, zone: Dictionary) -> void:
	for c in cs:
		if zone.has(c):
			return
	var part := part_names[clampi(part_sel, 0, part_names.size() - 1)]
	(laid.get_or_add(part, []) as Array).append([arch, [at.x, at.y, at.z]])


func _sculpt_finish(was: Dictionary, rec: PackedByteArray) -> void:
	var now := _sculpt_state()
	_edit_groups.append({"end": _edits.size(), "n": 0,
			"sketch": [{"sdf": rec}, {"sculpt_before": was, "sculpt_after": now}]})
	_set_sculpt_state(now)
	_autosave_dirty = true


## A part's custom piece from the field: its smooth samples (not its brick zone, not
## another part's) as distances, the surface where they cross zero, a sample a tick.
## Pinned (kept flat) in the cells where it meets a brick it does not cover: the join.
func _sdf_shell_field(part: String) -> Dictionary:
	var label := part_names.find(part) + 1
	var mine := {}
	var bricks := {}   # every other solid cell: a zone, or another part
	for i in range(0, _sdf_cells.size(), 5):
		var c := Vector3i(_sdf_cells[i], _sdf_cells[i + 1], _sdf_cells[i + 2])
		if _sdf_cells[i + 3] == label and _sdf_cells[i + 4] != 0:
			mine[c] = true
		else:
			bricks[c] = true
	if mine.is_empty():
		return {}
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for c in mine:
		lo = lo.min(c)
		hi = hi.max(c)
	var per := Vector3i(BrickWorld.ticks_per_stud(), BrickWorld.ticks_per_plate(), BrickWorld.ticks_per_stud())
	var slo := (lo - Vector3i.ONE) * per
	var dims := (hi - lo + Vector3i(3, 3, 3)) * per
	var joins := {}
	for c in mine:
		for d in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
			if bricks.has(c + d):
				joins[c] = true
	var pins := PackedByteArray()
	pins.resize(dims.x * dims.y * dims.z)
	for c in joins:
		var o: Vector3i = c * per - slo
		for z in per.z:
			for y in per.y:
				for x in per.x:
					pins[(o.x + x) + dims.x * ((o.y + y) + dims.y * (o.z + z))] = 1
	var mrec := _models_into_field()
	var dist: PackedFloat32Array = sculpt.form.part_field(label, slo, dims, true)
	_models_out(mrec)
	# A join cell holds a brick (its studs meet the bricks beside it): the piece wraps the
	# brick's box, so the brick never shows through where the surface is thinner.
	var half := Vector3(per) * 0.5
	for c in joins:
		var o: Vector3i = c * per - slo
		var mid := Vector3(o) + half
		for z in range(maxi(o.z - 2, 0), mini(o.z + per.z + 2, dims.z)):
			for y in range(maxi(o.y - 2, 0), mini(o.y + per.y + 2, dims.y)):
				for x in range(maxi(o.x - 2, 0), mini(o.x + per.x + 2, dims.x)):
					var q := (Vector3(x, y, z) + Vector3.ONE * 0.5 - mid).abs() - half
					var box := q.max(Vector3.ZERO).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
					var i := x + dims.x * (y + dims.y * z)
					dist[i] = minf(dist[i], box)
	return {"distance": dist, "pins": pins, "ddims": dims, "dlo": slo, "k": 1, "tick": true,
			"joins": joins, "lo": slo, "dims": dims}


## The point of the working plane under the mouse, in sketch numbers, or null.
func _sketch_mouse() -> Variant:
	var ray := _mouse_ray()
	var hit = work_plane_hit(ray[0], ray[1])
	return null if hit == null else sketch_point(hit)


func _sketch_add() -> void:
	var q = _sketch_mouse()
	if q == null:
		return
	match sketch_draw:
		"rect", "ellipse":
			_sketch.assign(drag_shape(sketch_draw, _sketch_anchor, q))
		"brush":
			if _sketch.is_empty() or q.distance_to(_sketch.back()) > maxf(0.25, brush_size * 0.25):
				_sketch.append(q)
		_:
			if _sketch.is_empty() or q.distance_to(_sketch.back()) > 0.3:
				_sketch.append(q)


## What the stroke under way comes to, into the sketch: an outline, or a brush's path.
func _sketch_commit() -> void:
	if sketch_draw == "brush" and not _sketch.is_empty():
		sketch_region_entry(brush_entry(_sketch, brush_size, brush_shape == "square", work_plane), _sketch_out)
	elif _sketch.size() >= 3:
		sketch_region(_sketch, _sketch_out)
	_sketch.clear()


## Polygon: each click a corner (the first click's button says in or out); a click on
## the first corner, a double click or Enter closes it, Backspace takes the last corner.
func _polygon_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.pressed and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var q = _sketch_mouse()
		if q == null:
			return true
		if _sketch.is_empty():
			_sketch_out = e.button_index == MOUSE_BUTTON_RIGHT
		elif e.double_click or (_sketch.size() >= 3 and q.distance_to(_sketch[0]) < 0.7):
			_sketch_commit()
			return true
		_sketch.append(q)
		return true
	if e is InputEventKey and e.pressed and not _sketch.is_empty():
		match e.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				_sketch_commit()
				return true
			KEY_BACKSPACE:
				_sketch.pop_back()
				return true
	return false


## A rectangle or an ellipse dragged from corner `a` to corner `b`, as an outline.
static func drag_shape(kind: String, a: Vector2, b: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	if kind == "rect":
		out.assign([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])
		return out
	var c := (lo + hi) * 0.5
	var r := (hi - lo) * 0.5
	for i in 32:
		var t := TAU * i / 32.0
		out.append(c + Vector2(cos(t) * r.x, sin(t) * r.y))
	return out


## A brush stroke as a sketch entry: its path, and its reach across and up the plane (a
## stud across is two and a half plates up on the side and front planes).
static func brush_entry(path: Array, size: int, square: bool, plane: String) -> Dictionary:
	var pts := []
	for q in path:
		pts.append([q.x, q.y])
	var rx := maxf(0.5, float(size))
	return {"brush": pts, "rx": rx, "ry": rx * (1.0 if plane == "top" else 2.5), "square": square}


## A point of the working plane in the sketch's own two numbers: across the plane and up
## it. Side: studs along, plates up. Front: studs across, plates up. Top: studs along,
## studs across.
func sketch_point(at: Vector3) -> Vector2:
	match work_plane:
		"front": return Vector2(at.z / BrickPalette.STUD_M, at.y / BrickPalette.PLATE_M)
		"top": return Vector2(at.x / BrickPalette.STUD_M, at.z / BrickPalette.STUD_M)
	return Vector2(at.x / BrickPalette.STUD_M, at.y / BrickPalette.PLATE_M)


func _sketch_world(q: Vector2, plane: String, at: float) -> Vector3:
	var s := BrickPalette.STUD_M
	var pl := BrickPalette.PLATE_M
	match plane:
		"front": return Vector3(at * s, q.y * pl, q.x * s)
		"top": return Vector3(q.x * s, at * pl, q.y * s)
	return Vector3(q.x * s, q.y * pl, at * s)


## Draw an outline into the current part's sketch on the working plane: area in, or with
## `remove` area out. The part's bricks are worked out again from what the sketch holds,
## as one undo. Returns how many bricks it laid.
func sketch_region(outline: Array, remove: bool = false) -> int:
	var plain := []
	for q in outline:
		plain.append([q.x, q.y])
	return sketch_region_entry(plain, remove)


## An outline ([[x, y] ...]) or a brush stroke (`brush_entry`) into the current part's
## sketch on the working plane.
func sketch_region_entry(entry: Variant, remove: bool = false) -> int:
	var key := _sketch_key()
	var plain = entry
	var sk: Dictionary
	if sketches.has(key):
		sk = (sketches[key] as Dictionary).duplicate()
		sk.adds = (sk.adds as Array).duplicate()
		sk.subs = (sk.subs as Array).duplicate()
	else:
		sk = {"part": part_names[part_sel], "plane": work_plane, "at": _plane_value(work_plane),
				"width": width_of(part_names[part_sel]), "adds": [], "subs": [], "n": _sketch_seq}
		_sketch_seq += 1
	var erase := []
	if remove and erase_any:
		erase = bricks_under(region_cells(plain), work_plane, cut_deep, _camera_side(work_plane))
		if part_sketches(part_names[part_sel]).is_empty():
			# Nothing sketched for this part: the stroke only takes up what is under it.
			return erase_bricks(erase)
	if remove and cut_deep > 0:
		plain = {"cut": plain, "deep": cut_deep, "from": _camera_side(work_plane)}
	(sk.subs if remove else sk.adds).append(plain)
	# What changed is under the area drawn -- except area drawn into a view through a part,
	# which changes everything outside it.
	var area := {}
	if remove or _base_plane(String(sk.part)) in ["", work_plane]:
		area = region_cells(plain.cut if plain is Dictionary and plain.has("cut") else plain)
	return resketch(key, sk, area, erase)


## The plane a part was first drawn on, or "".
func _base_plane(part: String) -> String:
	for e in part_sketches(part):
		if not (e[1].adds as Array).is_empty():
			return String(e[1].plane)
	return ""


## Which way along a plane's normal the camera is: a depth cut goes in from that face.
func _camera_side(plane: String) -> int:
	var cam := _camera.global_position
	match plane:
		"front": return 1 if cam.x > _plane_value(plane) * BrickPalette.STUD_M else -1
		"top": return 1 if cam.y > _plane_value(plane) * BrickPalette.PLATE_M else -1
	return 1 if cam.z > _plane_value(plane) * BrickPalette.STUD_M else -1


## The old way in, kept: an outline filled for the current part.
func sketch_fill(outline: Array) -> int:
	return sketch_region(outline, false)


func clear_sketch(key: String) -> void:
	if sketches.has(key):
		resketch(key, {"adds": [], "subs": []})


## Every sketch of a part, in every view, and the bricks they laid: gone, as one undo.
func clear_part_sketch(part: String) -> void:
	var gone := {}
	for k in sketches:
		if String(sketches[k].part) == part:
			gone[k] = null
	if not gone.is_empty():
		resketch_part(part, gone)


## Change a sketch -- `change` is merged into it -- and lay its part's bricks again. One
## undo, which puts the sketch and the bricks back. Returns how many bricks the part has.
## `area`, if given: the sketch cells the change drew over -- nothing outside them changed.
func resketch(key: String, change: Dictionary, area: Dictionary = {}, erase: Array = []) -> int:
	if not sketches.has(key) and not change.has("adds"):
		return 0
	# Stored sketches are never changed in place (here or in sketch_region), so the undo
	# can hold them as they are rather than as copies.
	var sk: Dictionary = (sketches.get(key, {}) as Dictionary).duplicate()
	sk.merge(change, true)
	var empty: bool = (sk.adds as Array).is_empty() and (sk.subs as Array).is_empty() and not sk.has("solid")
	var thicker: bool = sketches.has(key) and int(sketches[key].width) != int(sk.width)
	return resketch_part(String(sk.part), {key: null if empty else sk}, change.is_empty() or thicker,
			String(sk.plane), area, erase)


## A part's sketches changed (`change`: key -> its new state, or null for gone), and its
## bricks laid again from all its views.
##
## Worked out near the change only: a brick of the old layout two studs (and a course)
## clear of every cell that came or went stays where it is, and only the rest is packed
## again. `whole` (a new thickness or slope setting) lays it all again. Taking every brick
## up and laying it again was ~140 ms on a 500-brick part -- a hitch per stroke.
##
## `erase`: the recipe indices of other bricks to take up with it (RMB over bricks that
## are not this sketch's), as part of the same undo.
func resketch_part(part: String, change: Dictionary, whole: bool = false, plane: String = "",
		area: Dictionary = {}, erase: Array = []) -> int:
	var before := {}
	for k in change:
		before[k] = sketches.get(k)
	var old_vol: Dictionary = _part_vol[part] if _part_vol.has(part) else part_volume(part_sketches(part))
	var old_box: Array = _part_box[part] if _part_box.has(part) and _part_vol.has(part) else _box.duplicate()
	var list := part_sketches(part, change)
	var vol := part_volume(list)
	var sf := {}
	if shells.has(part) and ClassDB.class_exists("FormMesher"):
		sf = shell_field(part, list, vol)
		vol = shell_core(part, sf)
	whole = whole or old_vol.is_empty()
	var near := {}   # cells worked out again
	var near_lo := Vector3i(1 << 30, 1 << 30, 1 << 30)   # and the box round them
	var near_hi := -near_lo
	if not whole:
		var changed := {}
		if area.is_empty():
			for c in vol:
				if not old_vol.has(c):
					changed[c] = true
			for c in old_vol:
				if not vol.has(c):
					changed[c] = true
		else:
			# Only under the area drawn over: down its depth, through the part.
			var axis := 2 if plane == "side" else (0 if plane == "front" else 1)
			var lo := mini((old_box[0] as Vector3i)[axis], (_box[0] as Vector3i)[axis])
			var hi := maxi((old_box[1] as Vector3i)[axis], (_box[1] as Vector3i)[axis])
			for g in area:
				for k in range(lo, hi + 1):
					var c := _sketch_cell(g, k, plane)
					if vol.has(c) != old_vol.has(c):
						changed[c] = true
		near = _dilate(changed)
		for c in changed:
			near_lo = near_lo.min(c - NEAR_REACH)
			near_hi = near_hi.max(c + NEAR_REACH)
	var rid_of := {}
	for i in _placed_at.size():
		if int(_placed_at[i][0]) == 0:
			rid_of[int(_placed_at[i][1])] = i
	# The old bricks: kept (a plain brick clear of the change), or going.
	var bricks_before: Array = part_bricks.get(part, [])
	var laid := []
	var kept := {}    # "arch|cell" of the old bricks still there afterwards
	var going := {}   # "arch|cell" -> recipe index
	var free := {}    # cells of the going bricks: built in now, empty when the new are laid
	var only := near.duplicate()   # cells to pack: near the change, and under any brick going
	for b in bricks_before:
		var arch := String(b[0])
		var cell := Vector3i(int(b[1][0]), int(b[1][1]), int(b[1][2]))
		var size := BrickPalette.size_of(arch)
		var stays := not whole
		if stays and (cell.x > near_hi.x or cell.y > near_hi.y or cell.z > near_hi.z
				or cell.x + size.x <= near_lo.x or cell.y + size.y <= near_lo.y or cell.z + size.z <= near_lo.z):
			# Clear of the change: the part there is as it was, and so is the brick.
			kept["%s|%s" % [arch, cell]] = true
			laid.append(b)
			continue
		var cells := []
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					var c := cell + Vector3i(dx, dy, dz)
					cells.append(c)
					if stays and (near.has(c) or not vol.has(c)):
						stays = false
		var k := "%s|%s" % [arch, cell]
		if stays:
			kept[k] = true
			laid.append(b)
			continue
		var i := _rid_at(cells, rid_of)
		if i < 0:
			continue   # taken up some other way since
		going[k] = i
		for c in cells:
			free[c] = true
			only[c] = true
	var taken := {}
	for i in going.values():
		taken[int(i)] = true
	for i in erase:
		if taken.has(int(i)):
			continue
		var arch := String(recipe.part_of(int(i)))
		var cell := recipe.cell_of(int(i))
		var k := "%s|%s" % [arch, cell]
		if kept.has(k):
			kept.erase(k)
			laid = laid.filter(func(b: Array) -> bool: return "%s|%s" % [b[0], Vector3i(int(b[1][0]), int(b[1][1]), int(b[1][2]))] != k)
		taken[int(i)] = true
		going["erase|%d" % i] = int(i)
		var size := BrickPalette.size_of(arch)
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					var c := cell + Vector3i(dx, dy, dz)
					free[c] = true
					only[c] = true
	_no_edges = shells.has(part)
	var plan := _plan_volume(list, vol, free, {} if whole else only, {} if whole else near)
	_no_edges = false
	# A going brick the new layout lays again, the same part in the same place, stays.
	var lay := []
	for pk in plan:
		var k := "%s|%s" % [pk[0], pk[1]]
		if going.has(k):
			going.erase(k)
			laid.append([pk[0], [pk[1].x, pk[1].y, pk[1].z]])
		elif not kept.has(k):
			lay.append(pk)
	var gone: Array = going.values()
	gone.sort()
	gone.reverse()   # from the end, so the indices still to go do not move
	var ops := 0
	_batch = true
	for i in gone:
		if take_brick(int(i)):
			ops += 1
	var keep_sel := part_sel
	var idx := part_names.find(part)
	if idx >= 0:
		part_sel = idx
	for pk in lay:
		if place_named(pk[0], pk[1]):
			laid.append([pk[0], [pk[1].x, pk[1].y, pk[1].z]])
			ops += 1
	part_sel = keep_sel
	_batch = false
	_after_edit()
	for k in change:
		_set_sketch(k, change[k])
	part_bricks[part] = laid
	_part_vol[part] = vol
	_part_box[part] = _box.duplicate()
	_shell_mesh(part, sf)
	_store_asset_meta()
	_group_with(ops, {"part": part, "before": before, "after": change.duplicate(),
			"bricks_before": bricks_before, "bricks_after": laid})
	return laid.size()


## Put a part's sketches and its brick list back as they were (`which`: "before") or as
## they became ("after"), for undo and redo; the bricks themselves are the edits'.
## `g` may be a list of them (a shape stroke over several stamps and parts): put back in
## reverse for "before", in order for "after".
func _restore_sketch(g: Variant, which: String) -> void:
	if g is Array:
		var list: Array = (g as Array).duplicate()
		if which == "before":
			list.reverse()
		for one in list:
			_restore_sketch(one, which)
		return
	if g.has("sdf"):
		g.sdf = sculpt.form.swap_blocks(g.sdf)
		sculpt.remesh()
		_sdf_meta = sculpt.save_meta()
		_store_asset_meta()
		return
	if g.has("sculpt_" + which):
		_set_sculpt_state(g["sculpt_" + which])
		return
	if g.has("models_" + which):
		_set_models(g["models_" + which])
		return
	if g.has("curves_" + which):
		_show_curves(int(g["curves_" + which]))
		return
	if g.has("shell_part"):
		var was = g["shell_" + which]
		if was == null:
			shells.erase(String(g.shell_part))
		else:
			shells[String(g.shell_part)] = was
		_refresh_shell(String(g.shell_part))
		return
	var states: Dictionary = g.get(which, {})
	for k in states:
		_set_sketch(k, states[k])
	part_bricks[String(g.part)] = g.get("bricks_" + which, [])
	_part_vol.erase(String(g.part))
	_refresh_shell(String(g.part))
	if g.has("studs_" + which):
		extra_studs = (g["studs_" + which] as Array).duplicate()
		points = (g["points_" + which] as Array).duplicate()
		_draw_studs()
		_draw_points()
	_store_asset_meta()


## Grow a set of cells by two studs across and along, a course (three plates) up and down.
const NEAR_REACH := Vector3i(2, 3, 2)


static func _dilate(cells: Dictionary) -> Dictionary:
	var out := cells
	for step in [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]:
		var reach := NEAR_REACH.y if step.y == 1 else NEAR_REACH.x
		var grown := {}
		for c in out:
			for d in range(-reach, reach + 1):
				grown[c + step * d] = true
		out = grown
	return out


## A part's sketches, oldest first, with `change` (key -> state or null) put in.
func part_sketches(part: String, change: Dictionary = {}) -> Array:
	var out := []
	for k in sketches:
		if String(sketches[k].part) == part and not change.has(k):
			out.append([k, sketches[k]])
	for k in change:
		if change[k] != null:
			out.append([k, change[k]])
	out.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1].get("n", 0)) < int(b[1].get("n", 0)))
	return out


## The cells a part fills, from all its views. The plane of its first sketch with area in
## it is its base: its sketches there are slabs, their thickness centred on their plane.
## A sketch on another plane is a view through the part -- area drawn in keeps only what
## is inside it, area drawn out cuts right through. A depth cut, from any view, takes so
## many studs in from the face toward the camera when it was drawn. Shapes stamped with
## the shape brush (entries with a `solid`) are laid over all that, or carved out of it.
func part_volume(list: Array) -> Dictionary:
	_course = 1 << 30
	_box = [Vector3i(1 << 30, 1 << 30, 1 << 30), -Vector3i(1 << 30, 1 << 30, 1 << 30)]
	var base := ""
	for e in list:
		if not (e[1].adds as Array).is_empty():
			base = e[1].plane
			break
	var vol := {}
	if base != "":
		_sketched_volume(list, base, vol)
	# Shapes stamped with the shape brush: over the sketch, in the order they were made.
	for e in list:
		var sk: Dictionary = e[1]
		if not sk.has("solid"):
			continue
		var cells := _cells_of(e[0], sk)
		if bool(sk.solid.carve):
			for c in cells:
				vol.erase(c)
		else:
			for c in cells:
				vol[c] = true
				_box[0] = (_box[0] as Vector3i).min(c)
				_box[1] = (_box[1] as Vector3i).max(c)
	_course = (_box[0] as Vector3i).y
	return vol


## The sketches' part of `part_volume`: the slabs on the base plane, cut by the views
## through the part and the pockets.
func _sketched_volume(list: Array, base: String, vol: Dictionary) -> void:
	for e in list:
		var sk: Dictionary = e[1]
		if sk.plane != base or (sk.adds as Array).is_empty():
			continue
		var depth := _sketch_depth(sk)
		if depth.is_empty():
			continue
		var pl := String(sk.plane)
		var glo := Vector2i(1 << 30, 1 << 30)
		var ghi := -glo
		# Written out per plane: this runs for every cell of the part on every stroke.
		for g: Vector2i in _cells_of(e[0], sk):
			if pl != "top" and g.y < 0:
				continue
			glo = glo.min(g)
			ghi = ghi.max(g)
			match pl:
				"side":
					for k: int in depth:
						vol[Vector3i(g.x, g.y, k)] = true
				"front":
					for k: int in depth:
						vol[Vector3i(k, g.y, g.x)] = true
				_:
					for k: int in depth:
						vol[Vector3i(g.x, k, g.y)] = true
		if glo.x > ghi.x:
			continue
		var c0 := _sketch_cell(glo, int(depth[0]), pl)
		var c1 := _sketch_cell(ghi, int(depth[depth.size() - 1]), pl)
		_box[0] = (_box[0] as Vector3i).min(c0.min(c1))
		_box[1] = (_box[1] as Vector3i).max(c0.max(c1))
	for e in list:
		var sk: Dictionary = e[1]
		if sk.plane == base or sk.has("solid"):
			continue
		var keep := not (sk.adds as Array).is_empty()
		var g2: Dictionary = _cells_of(e[0], sk) if keep else through_cuts(sk)
		for c in vol.keys():
			if g2.has(_sketch_grid(c, sk.plane)) != keep:
				vol.erase(c)
	for e in list:
		for cut in e[1].subs:
			if cut is Dictionary and cut.has("cut"):
				_cut_pocket(vol, region_cells(cut.cut), e[1].plane, int(cut.deep), int(cut.get("from", 1)))


## A sketch's own cells (area in, less area cut right through), kept until it changes.
func _cells_of(key: String, sk: Dictionary) -> Dictionary:
	if sketches.get(key) == sk and _sketch_cache.has(key):
		return _sketch_cache[key]
	var cells := sketch_cells(sk)
	if sketches.get(key) == sk:
		_sketch_cache[key] = cells
	return cells


## The area a sketch cuts right through.
static func through_cuts(sk: Dictionary) -> Dictionary:
	var out := {}
	for cut in sk.get("subs", []):
		if not (cut is Dictionary and cut.has("cut")):
			out.merge(region_cells(cut))
	return out


## Take `deep` studs (on the top plane, plates: two and a half a stud) out of the part
## under each cell of `area`, in from its face on side `from` of the plane.
func _cut_pocket(vol: Dictionary, area: Dictionary, plane: String, deep: int, from: int) -> void:
	var axis := 2
	match plane:
		"front": axis = 0
		"top": axis = 1
	var n := deep if axis != 1 else int(round(deep * 2.5))
	var columns := {}   # sketch cell -> the part's cells under it, along the axis
	for c in vol:
		var g := _sketch_grid(c, plane)
		if area.has(g):
			(columns.get_or_add(g, []) as Array).append(c[axis])
	for g in columns:
		var ks: Array = columns[g]
		ks.sort()
		if from > 0:
			ks.reverse()
		for i in mini(n, ks.size()):
			vol.erase(_sketch_cell(g, int(ks[i]), plane))


## A sketch's depth cells: its thickness centred on its plane (across the gun from the
## side, along it from the front, upward from the top, a stud being 2.5 plates).
static func _sketch_depth(sk: Dictionary) -> Array:
	var at: float = float(sk.at)
	var w := int(sk.width)
	var depth := []
	if sk.plane == "top":
		for k in maxi(1, int(round(w * 2.5))):
			depth.append(int(at) + k)
	else:
		var k0 := int(round(at - w * 0.5))
		for k in w:
			depth.append(k0 + k)
	return depth


## The pieces for a part's volume: edge pieces from each view it was sketched in (side
## slopes slice by slice across it, front slopes slice by slice along it), then the rest
## packed. `own`: cells built in now that will be empty when it is laid. `only`, if given:
## the cells to pack; `near`, the cells round a change -- edge pieces are looked for
## only where they would touch it.
func _plan_volume(list: Array, vol: Dictionary, own: Dictionary, only: Dictionary,
		near: Dictionary = {}) -> Array:
	var views := []
	if _no_edges:
		pass
	elif curve_level >= 3:
		views = ["side", "front"]
	elif curve_level >= 1:
		for e in list:
			var pl: String = e[1].plane
			if pl != "top" and not views.has(pl) and not e[1].has("solid"):
				views.append(pl)
	var used := {}
	var placements := []
	for view in views:
		placements.append_array(_edge_runs(list, vol, view, own, used, near))
	var cells := {}
	var course := _course
	for c in (vol if only.is_empty() else only):
		if used.has(c) or not vol.has(c):
			continue
		cells[c] = true
	return pack_cells(cells, shape_fill == "random", own, course) + placements


## Edge pieces for a volume seen from one view: the edges of each slice (across it for
## the side, along it for the front), a piece the same in neighbouring slices laid as one
## wider piece. A part that is one outline drawn straight through (one sketch on this
## plane, no other view, no pocket) has every slice the same: found once.
func _edge_runs(list: Array, vol: Dictionary, view: String, own: Dictionary, used: Dictionary,
		near: Dictionary = {}) -> Array:
	var slices := {}
	var ks := []
	var straight := list.size() == 1 and String(list[0][1].plane) == view and not _has_pocket(list[0][1])
	# Where pieces may go: touching `near`, in the cells across the slices (u) and along
	# them (k); slices cut a little wider so a piece there sees its neighbours.
	var lo := Vector2i(-(1 << 30), -(1 << 30))
	var hi := Vector2i(1 << 30, 1 << 30)
	if not near.is_empty():
		lo = Vector2i(1 << 30, 1 << 30)
		hi = Vector2i(-(1 << 30), -(1 << 30))
		for c in near:
			var u: int = c.x if view == "side" else c.z
			var k: int = c.z if view == "side" else c.x
			lo = Vector2i(mini(lo.x, u), mini(lo.y, k))
			hi = Vector2i(maxi(hi.x, u), maxi(hi.y, k))
	if straight:
		var sk: Dictionary = list[0][1]
		var grid: Dictionary = _cells_of(list[0][0], sk)
		var one := {}
		for g in grid:
			if g.y >= 0 and g.x >= lo.x - 6 and g.x <= hi.x + 6:
				one[g] = true
		for k in _sketch_depth(sk):
			if k >= lo.y and k <= hi.y:
				slices[k] = one
				ks.append(k)
	else:
		for c in vol:
			var u: int = c.x if view == "side" else c.z
			var k: int = c.z if view == "side" else c.x
			if u < lo.x - 6 or u > hi.x + 6 or k < lo.y - 1 or k > hi.y + 1:
				continue
			if not slices.has(k):
				slices[k] = {}
				ks.append(k)
			(slices[k] as Dictionary)[_sketch_grid(c, view)] = true
		ks.sort()
	var runs := {}   # what a piece is -> [the piece, the slices it is in]
	var once = null  # a straight part's pieces: every slice is the same
	for k in ks:
		var pieces: Array
		if straight and once != null:
			pieces = once
		else:
			pieces = edge_pieces(slices[k], slope_eager, curve_level >= 2)
			once = pieces
		for pc in pieces:
			if pc.u + 1 < lo.x or pc.u > hi.x:
				continue
			var what := "%s|%d|%d|%d|%s" % [pc.kind, pc.u, pc.base, pc.rises, pc.under]
			((runs.get_or_add(what, [pc, []]) as Array)[1] as Array).append(k)
	var out := []
	for what in runs:
		var pc: Dictionary = runs[what][0]
		var kl: Array = runs[what][1]
		var i := 0
		while i < kl.size():
			var j := i
			while j + 1 < kl.size() and int(kl[j + 1]) == int(kl[j]) + 1:
				j += 1
			var k := int(kl[i])
			while k <= int(kl[j]):
				var left := int(kl[j]) - k + 1
				var wide := 4 if pc.kind == "slope" and left >= 4 else (2 if left >= 2 else 1)
				# Its box clear: nothing built there but what is going, no other piece.
				var box := []
				var clear := true
				for du in 2:
					for dv in 3:
						for dk in wide:
							var c := _sketch_cell(Vector2i(pc.u + du, pc.base + dv), k + dk, view)
							box.append(c)
							if used.has(c) or (world.is_solid(chunk, c) and not own.has(c)):
								clear = false
				if clear:
					for c in box:
						used[c] = true
					out.append([edge_variant(pc.kind, wide, pc.rises, pc.under, view),
							_sketch_cell(Vector2i(pc.u, pc.base), k, view)])
					k += wide
				else:
					k += 1
			i = j + 1
	return out


static func _has_pocket(sk: Dictionary) -> bool:
	for cut in sk.get("subs", []):
		if cut is Dictionary and cut.has("cut"):
			return true
	return false


## A cell of the build as a sketch cell (across, up): `_sketch_cell` the other way.
static func _sketch_grid(c: Vector3i, plane: String) -> Vector2i:
	match plane:
		"front": return Vector2i(c.z, c.y)
		"top": return Vector2i(c.x, c.z)
	return Vector2i(c.x, c.y)


## The recipe index of the brick in these cells, through block id -> index.
func _rid_at(cells: Array, rid_of: Dictionary) -> int:
	for c in cells:
		var block := world.block_at(chunk, c)
		if block >= 0 and rid_of.has(block):
			return int(rid_of[block])
	return -1


func _set_sketch(key: String, state) -> void:
	var part := String(state.part) if state != null else (String(sketches[key].part) if sketches.has(key) else "")
	if state == null:
		sketches.erase(key)
	else:
		sketches[key] = state
	_sketch_cache.erase(key)
	_part_vol.erase(part)
	_part_box.erase(part)
	_sketch_sig = ""


## What a sketch fills, as (across, up) cells: every area drawn in, less every area drawn
## out. An outline's area is everything inside its outermost line, so one that crosses
## itself or goes round twice is filled whole.
func sketch_cells(sk: Dictionary) -> Dictionary:
	if sk.has("solid"):
		return solid_cells(sk.solid)
	var cells := {}
	for poly in sk.get("adds", []):
		for c in region_cells(poly):
			cells[c] = true
	if not cells.is_empty():
		for c in through_cuts(sk):
			cells.erase(c)
	return cells


## The cells of a shape-brush stroke kept in a part's form: its shape stamped at each of
## its centres, inside the build area. `solid`: {kind, size, axis, thick, carve, at: [[x, y, z] ...]}.
func solid_cells(solid: Dictionary) -> Dictionary:
	var out := {}
	for q in solid.at:
		var centre := Vector3i(int(q[0]), int(q[1]), int(q[2]))
		for c in brush_shape_cells(String(solid.kind), centre, int(solid.size), int(solid.axis), int(solid.thick)):
			if _no_clip or (c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < plate_studs and c.y < height_plates
					and c.z < plate_studs):
				out[c] = true
	return out


static func region_cells(poly: Variant) -> Dictionary:
	if poly is Dictionary:
		return brush_cells(poly)
	var pts := PackedVector2Array()
	for q in poly:
		pts.append(Vector2(float(q[0]), float(q[1])))
	if pts.size() < 3:
		return {}
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for q in pts:
		lo = Vector2i(mini(lo.x, int(floor(q.x))), mini(lo.y, int(floor(q.y))))
		hi = Vector2i(maxi(hi.x, int(ceil(q.x))), maxi(hi.y, int(ceil(q.y))))
	# A bitmap one cell wider all round, so the outside is connected: 1 inside, 2 outside.
	var w := hi.x - lo.x + 2
	var h := hi.y - lo.y + 2
	var map := PackedByteArray()
	map.resize(w * h)
	# Inside by winding, not even-odd (a stretch circled twice is in, not cancelled out),
	# a row at a time: where each edge crosses the row's centre line, and which way.
	var n := pts.size()
	for v in range(lo.y, hi.y):
		var y := v + 0.5
		var xs := []
		for i in n:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if (a.y <= y) == (b.y <= y):
				continue
			xs.append([a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x), 1 if b.y > a.y else -1])
		if xs.is_empty():
			continue
		xs.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
		var wind := 0
		for j in xs.size() - 1:
			wind += int(xs[j][1])
			if wind == 0:
				continue
			# Cells whose centres lie between this crossing and the next.
			var u0 := maxi(lo.x, int(ceil(float(xs[j][0]) - 0.5)))
			var u1 := mini(hi.x - 1, int(ceil(float(xs[j + 1][0]) - 0.5)) - 1)
			for u in range(u0, u1 + 1):
				map[(v - lo.y + 1) * w + (u - lo.x + 1)] = 1
	# Outermost: whatever the outside cannot reach is in, holes the crossing made included.
	var todo := PackedInt32Array([0])
	map[0] = 2
	while not todo.is_empty():
		var at := todo[todo.size() - 1]
		todo.resize(todo.size() - 1)
		var ax := at % w
		@warning_ignore("integer_division")
		var ay := at / w
		for nb in [at - 1 if ax > 0 else -1, at + 1 if ax < w - 1 else -1, at - w if ay > 0 else -1,
				at + w if ay < h - 1 else -1]:
			if nb >= 0 and map[nb] == 0:
				map[nb] = 2
				todo.append(nb)
	var out := {}
	for v in range(lo.y, hi.y):
		for u in range(lo.x, hi.x):
			if map[(v - lo.y + 1) * w + (u - lo.x + 1)] != 2:
				out[Vector2i(u, v)] = true
	return out


## The cells a brush stroke covers: every cell whose centre is within its reach of the
## path (an ellipse, or a box when square), the path walked in steps shorter than that.
static func brush_cells(entry: Dictionary) -> Dictionary:
	var out := {}
	var rx := float(entry.get("rx", 0.5))
	var ry := float(entry.get("ry", 0.5))
	var square := bool(entry.get("square", false))
	var path: Array = entry.get("brush", [])
	var pts: Array[Vector2] = []
	for i in path.size():
		var b := Vector2(float(path[i][0]), float(path[i][1]))
		if i > 0:
			var a: Vector2 = pts.back()
			var steps := int(ceil(maxf(absf(b.x - a.x) / (rx * 0.5), absf(b.y - a.y) / (ry * 0.5))))
			for k in range(1, steps):
				pts.append(a.lerp(b, float(k) / steps))
		pts.append(b)
	for p in pts:
		for u in range(int(floor(p.x - rx)), int(ceil(p.x + rx)) + 1):
			for v in range(int(floor(p.y - ry)), int(ceil(p.y + ry)) + 1):
				var d := Vector2((u + 0.5 - p.x) / rx, (v + 0.5 - p.y) / ry)
				if (maxf(absf(d.x), absf(d.y)) <= 1.0) if square else (d.length_squared() <= 1.0):
					out[Vector2i(u, v)] = true
	return out


## How many times an outline goes round a point, counting direction.
static func _winding(pts: PackedVector2Array, q: Vector2) -> int:
	var w := 0
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var side := (b.x - a.x) * (q.y - a.y) - (q.x - a.x) * (b.y - a.y)
		if a.y <= q.y:
			if b.y > q.y and side > 0.0:
				w += 1
		elif b.y <= q.y and side < 0.0:
			w -= 1
	return w


## A sketch cell (across the plane, up it) at depth `k`, as a cell of the build. A
## piece's min corner is its cell at its lowest across-and-up.
static func _sketch_cell(g: Vector2i, k: int, plane: String) -> Vector3i:
	match plane:
		"front": return Vector3i(k, g.y, g.x)
		"top": return Vector3i(g.x, k, g.y)
	return Vector3i(g.x, g.y, k)


func _draw_sketch(im: ImmediateMesh) -> void:
	_draw_sketch_static()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var any := false
	var col := Color(1.0, 0.35, 0.3) if _sketch_out else Color(1, 1, 1)
	var mouse = _sketch_mouse()
	var line: Array[Vector2] = _sketch.duplicate()
	var closed := sketch_draw in ["outline", "rect", "ellipse"]
	if sketch_draw == "polygon" and not line.is_empty() and mouse != null:
		line.append(mouse)
	if sketch_draw == "brush" and mouse != null:
		# The brush's reach round the cursor.
		var e := brush_entry([mouse], brush_size, brush_shape == "square", work_plane)
		var ring: Array[Vector2] = drag_shape("rect" if e.square else "ellipse",
				mouse - Vector2(e.rx, e.ry), mouse + Vector2(e.rx, e.ry))
		for i in ring.size():
			im.surface_set_color(Color(0.6, 0.9, 1.0))
			im.surface_add_vertex(_sketch_world(ring[i], work_plane, _plane_value(work_plane)))
			im.surface_set_color(Color(0.6, 0.9, 1.0))
			im.surface_add_vertex(_sketch_world(ring[(i + 1) % ring.size()], work_plane, _plane_value(work_plane)))
			any = true
	if line.size() >= 2:
		for i in (line.size() if closed else line.size() - 1):
			var a := line[i]
			var b := line[(i + 1) % line.size()]
			im.surface_set_color(col)
			im.surface_add_vertex(_sketch_world(a, work_plane, _plane_value(work_plane)))
			im.surface_set_color(col)
			im.surface_add_vertex(_sketch_world(b, work_plane, _plane_value(work_plane)))
			any = true
	if not any:
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(Vector3.ZERO)
	im.surface_end()


## Where catalogue pieces go on the edges of a sketch (Vector2i(across, up) -> true):
## [{kind: "slope" or "curve", u: its first column, base: its bottom plate, rises: +1
## if the edge climbs toward +u, under: true for a bottom edge (the piece flipped)}].
## A bottom edge is a top edge of the sketch turned upside down, so one rule does both.
## `eager` lays slopes on edges climbing one to three plates a stud, not only two.
## `curves` false: slopes only.
static func edge_pieces(grid: Dictionary, eager: bool = false, curves: bool = true) -> Array:
	var out := _top_pieces(grid, {}, eager, curves)
	var flipped := {}
	for g in grid:
		flipped[Vector2i(g.x, -g.y - 1)] = true
	var used := {}
	for pc in out:
		used[pc.u] = true
		used[pc.u + 1] = true
	for pc in _top_pieces(flipped, used, eager, curves):
		# Back the right way up: the flipped box held plates base .. base + 2.
		pc.base = -pc.base - 3
		pc.under = true
		out.append(pc)
	return out


static func _top_pieces(grid: Dictionary, used_already: Dictionary = {}, eager: bool = false,
		curves: bool = true) -> Array:
	var top := {}
	for g in grid:
		top[g.x] = maxi(int(top.get(g.x, -(1 << 30))), g.y + 1)
	var out := []
	var used := used_already.duplicate()
	var us := top.keys()
	us.sort()
	# Slopes at their own pitch first, then curves, then (eager) slopes a plate off the line
	# where neither went: an eager slope must not take a curve's columns.
	_slopes_into(out, grid, top, us, used, [2])
	# Then curves: an end that rounds over -- a column two plates up from nothing (or from
	# two plates lower), then one more plate -- is a curve's profile, three plates in two
	# studs from its front edge.
	for u in (us if curves else []):
		for dir in [1, -1]:
			var a: int = u
			var b: int = u + dir
			if not top.has(b) or used.has(a) or used.has(b):
				continue
			if top[b] - top[a] != 1:
				continue
			var before: int = top.get(a - dir, -(1 << 30))
			if top[a] - before < 2:
				continue
			var base: int = top[b] - 3
			var first := mini(a, b)
			if not (grid.has(Vector2i(a, base)) and grid.has(Vector2i(b, base)) and grid.has(Vector2i(a, base + 1))):
				continue
			out.append({"kind": "curve", "u": first, "base": base, "rises": dir, "under": false})
			used[a] = true
			used[b] = true
	if eager:
		_slopes_into(out, grid, top, us, used, [1, 3])
	return out


## Slopes on edges climbing `climbs` plates a stud. A slope's flat back sits over the
## higher column, its top level with that column's; its low front over the lower column.
## At its own pitch the edge climbs two plates a stud; eager, one or three too, the slope a
## plate proud of or short of the line.
static func _slopes_into(out: Array, grid: Dictionary, top: Dictionary, us: Array, used: Dictionary,
		climbs: Array) -> void:
	for u in us:
		if not top.has(u + 1) or used.has(u) or used.has(u + 1):
			continue
		var d: int = top[u + 1] - top[u]
		if not (absi(d) in climbs):
			continue
		var low: int = u if d > 0 else u + 1
		var high: int = u + 1 if d > 0 else u
		var base: int = top[high] - 3
		if not grid.has(Vector2i(high, base)) or top[low] < base:
			continue
		out.append({"kind": "slope", "u": u, "base": base, "rises": 1 if d > 0 else -1, "under": false})
		used[u] = true
		used[u + 1] = true


## The catalogue piece for an edge: a slope or curve, `wide` studs deep (a 2x4 slope for
## four), 2 long across the plane, its low front looking down the edge, flipped under a
## bottom edge.
func edge_variant(kind: String, wide: int, rises: int, under: bool, plane: String = "") -> String:
	if plane == "":
		plane = work_plane
	var part := "%s_%s" % [kind, {1: "1x2", 2: "2x2", 4: "2x4"}[wide]]
	var along := Vector3i(1, 0, 0) if plane != "front" else Vector3i(0, 0, 1)
	var want := along * (-1 if rises > 0 else 1)
	for yaw in 4:
		var name := BrickPalette.variant_name(part, yaw, under)
		var size := BrickPalette.size_of(name)
		var long := size.x if plane != "front" else size.z
		var deep := size.z if plane != "front" else size.x
		if BrickPalette.front_of(name) == want and long == 2 and deep == wide:
			return name
	return BrickPalette.variant_name(part, 0, under)


## How far the mouse moves while a click is held: a run starts only past RUN_START_PX.
## Seen here, ahead of the camera, which takes the motion when the mouse is captured.
func _input(e: InputEvent) -> void:
	# The rail keeps no keyboard focus once the mouse is off it: Space (fly up) and the
	# arrows would press or step whatever was clicked last. A text or number box keeps it
	# while it is being typed in.
	if (e is InputEventKey or e is InputEventMouseMotion) and _rail != null:
		var f := get_viewport().gui_get_focus_owner()
		if f != null and _rail.is_ancestor_of(f) and not (f is LineEdit or f is SpinBox or f is TextEdit) \
				and (e is InputEventKey or not _over_rail()):
			f.release_focus()
	if _lathe_key(e) or _placed_key(e) or _game_view_input(e):
		get_viewport().set_input_as_handled()
		return
	super._input(e)
	if _run_on and e is InputEventMouseMotion:
		_run_moved += (e as InputEventMouseMotion).relative.length()


# ---------------------------------------------------------------------------
# Round 4: the tool rail and the brushes
# ---------------------------------------------------------------------------

## The sketch's still lines, drawn again only when something they show changed: this
## sketch's outline (yellow), the whole part seen from this plane (blue), the other parts
## seen from it (grey).
func _draw_sketch_static() -> void:
	if _sketch_static == null:
		_sketch_static = MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = true
		_sketch_static.material_override = mat
		add_child(_sketch_static)
	var key := _sketch_key()
	var sig := "%s|%d|%d" % [key, recipe.size(), sketches.size()]
	_sketch_static.visible = tool == "sketch"
	if sig == _sketch_sig or tool != "sketch":
		return
	_sketch_sig = sig
	var im := ImmediateMesh.new()
	_sketch_static.mesh = im
	var at := _plane_value(work_plane)
	var lines := []
	for part in part_names:
		if part == part_names[part_sel]:
			continue
		if not _part_vol.has(part):
			_part_vol[part] = part_volume(part_sketches(part))
			_part_box[part] = _box.duplicate()
		var vol: Dictionary = _part_vol[part]
		lines.append([_seen_from(vol, work_plane), Color(0.55, 0.58, 0.65, 0.7)])
	var mine := part_names[part_sel]
	if not _part_vol.has(mine):
		_part_vol[mine] = part_volume(part_sketches(mine))
		_part_box[mine] = _box.duplicate()
	lines.append([_seen_from(_part_vol[mine], work_plane), Color(0.35, 0.75, 1.0)])
	if sketches.has(key):
		lines.append([_cells_of(key, sketches[key]), Color(1.0, 0.9, 0.2)])
	var any := false
	for l in lines:
		var cells: Dictionary = l[0]
		for c in cells:
			for e in [[Vector2i(0, -1), Vector2(0, 0), Vector2(1, 0)], [Vector2i(0, 1), Vector2(0, 1), Vector2(1, 1)],
					[Vector2i(-1, 0), Vector2(0, 0), Vector2(0, 1)], [Vector2i(1, 0), Vector2(1, 0), Vector2(1, 1)]]:
				if cells.has(c + e[0]):
					continue
				if not any:
					im.surface_begin(Mesh.PRIMITIVE_LINES)
					any = true
				for corner in [e[1], e[2]]:
					im.surface_set_color(l[1])
					im.surface_add_vertex(_sketch_world(Vector2(c) + corner, work_plane, at))
	if any:
		im.surface_end()


## A volume as this plane sees it: every sketch cell with some of it behind.
static func _seen_from(vol: Dictionary, plane: String) -> Dictionary:
	var out := {}
	for c in vol:
		out[_sketch_grid(c, plane)] = true
	return out

## The rail's tools: id, name, key. "place" is no tool at all: the workshop's own hand.
## Sculpt and Sketch are one tool inside ("sketch"): sculpt draws into the SDF in 3D, the
## sketch's 2D draws lay bricks (Docs/AssetWorkshop.md, "SDF tools, round 3").
const RAIL_TOOLS := [["place", "Place", "Esc"], ["paint", "Paint", "B"], ["sculpt", "Sculpt (3D)", "Alt V"],
		["sketch", "Sketch (2D)", "Alt D"], ["shape", "Shapes", "K"], ["select", "Select", "L"], ["stud", "Studs", "Alt U"],
		["move", "Move part", "Alt G"], ["measure", "Measure", "Alt M"]]
const SKETCH_DRAWS := [["outline", "outline (freehand)"], ["brush", "brush"], ["rect", "rectangle"],
		["ellipse", "ellipse"], ["polygon", "polygon (click corners)"]]
const PAINT_WHAT := [["both", "colour and material"], ["colour", "colour only"], ["material", "material only"]]

const RAIL_W := 184.0
const RAIL_FONT := 12
var sketch_draw := "sculpt"
## The Sketch tool's last 2D draw, for when it is picked again.
var _draw_2d := "outline"
## The SDF block-out (Docs/AssetWorkshop.md, "The SDF block-out"): its brush.
const SCULPT_MODES := [["shape", "add (LMB) / carve (RMB)"], ["stamp", "stamp a shape (drag)"],
		["flatten", "flatten"], ["grow", "grow (LMB) / shrink (RMB)"], ["smooth", "smooth"],
		["paint", "paint this part"], ["zone", "mark smooth (LMB) / back to bricks (RMB)"],
		["models", "pick and move (models, parts, guides)"]]
## Stamp shapes (Docs/AssetWorkshop.md, "SDF tools, round 2").
const SCULPT_SHAPES := [["box", "box: corner to corner"], ["cylinder", "cylinder: end to end"],
		["cone", "cone: base to tip"], ["ball", "ball: centre to edge"], ["line", "line: end to end"],
		["lathe", "lathe: axis, then outline"]]
## Not an SdfForm op: the flatten brush, which calls `SdfForm.flatten`.
const OP_FLATTEN := 100
## How much better a fitted piece must match the field than its box's cells as bricks, as
## a share of its samples; eager (curve level 4) lower.
const SDF_FIT_GAIN := 0.03
const SDF_FIT_EAGER := 0.015
var sculpt_shape := "box"
var sculpt_snap := true
var sculpt_strength := 0.5   # flatten and grow, 0-1
var _stamp_from := Vector3.ZERO
## The lathe being drawn (Docs/AssetWorkshop.md, "SDF tools, round 3"): its axis [from, to]
## (samples) once dragged, the outline's points (out from the axis, along it from its
## middle) clicked since, and whether it adds or carves. No axis: nothing pending.
var _lathe_axis := []
var _lathe_pts := PackedVector2Array()
var _lathe_op := SdfForm.ADD
## The guide dialog was opened by the sculpt panel's "add a 3D model": the model goes
## into the field once loaded.
var _guide_into_sdf := false
var _stamp_to := Vector3.ZERO
var _flat_point := Vector3.ZERO
var _flat_normal := Vector3.UP
var sculpt: AssetSculpt
var sculpt_mode := "shape"
var sculpt_radius := 1.0     # studs
var sculpt_blend := 0.0      # studs: how far an add or a carve blends into what is there
var _sculpt_on := false
var _sculpt_op := 0
var _sculpt_last := Vector3.ZERO
## Where the brush sits; the plane a stroke stays on (samples).
const SCULPT_PLACES := [["plane", "brush on a plane facing you"], ["surface", "brush on the surface"],
		["work", "brush on the working plane"]]
var sculpt_place := "plane"
var _sculpt_plane := Plane(Vector3.BACK, 0.0)
var _sculpt_box: VBoxContainer
var _sculpt_note: Label
var _sketch_how: Label
var _sketch2d_box: VBoxContainer
var _sketch_title: Label
var _sdf_meta := {}
## "sdf" while the block-out is sculpted; "bricks" once converted.
var sculpt_state := "sdf"
## The field's cells at the last Convert or Edit as SDF: what the bricks are synced from.
var _sdf_cells := PackedInt32Array()
## Bricks Edit as SDF took up, for Convert to lay back: [arch, x, y, z, colour, mat, part].
var _sdf_stash := []
## Cells a converted part's custom piece fills with no brick inside (its edge): still the
## asset's for Edit as SDF. x, y, z, label, 0 each, as `SdfForm.cells`.
var _sdf_shell := PackedInt32Array()
var brush_size := 1          # studs: a sketch brush's reach; a paint brush's is the workshop's own
var brush_shape := "round"   # or "square", for both
var paint_what := "both"
var _sketch_anchor := Vector2.ZERO
var _rail: PanelContainer
var _rail_buttons := {}
var _brush_box: VBoxContainer
var _brush_slider: HSlider
var _brush_label: Label
var _paint_box: VBoxContainer
var _draw_box: VBoxContainer
var _draws: OptionButton
var _rail_scroll: ScrollContainer
var _part_pick: OptionButton
var _shape_box2: VBoxContainer
var _shape_size_label: Label
var _shape_size_slider: HSlider
var _explode_button: Button
var _hands_button: Button
var _rail_box: VBoxContainer


func _build_rail(layer: CanvasLayer) -> void:
	_rail = PanelContainer.new()
	_rail.position = Vector2(12, 60)
	_rail.custom_minimum_size.x = RAIL_W
	_rail.size.x = RAIL_W
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.11, 0.12, 0.15, 0.96)
	bg.set_content_margin_all(5)
	bg.set_corner_radius_all(4)
	_rail.add_theme_stylebox_override("panel", bg)
	# Small type and tight buttons: the rail is a strip, not a panel.
	var theme := Theme.new()
	theme.default_font_size = RAIL_FONT
	for kind in ["Button", "OptionButton"]:
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.2, 0.22, 0.27) if state in ["pressed", "hover_pressed"] else (
					Color(0.16, 0.17, 0.21) if state == "hover" else Color(0.13, 0.14, 0.17))
			if state == "focus":
				sb.draw_center = false
			sb.content_margin_left = 6
			sb.content_margin_right = 6
			sb.content_margin_top = 2
			sb.content_margin_bottom = 2
			sb.set_corner_radius_all(3)
			theme.set_stylebox(state, kind, sb)
	theme.set_constant("separation", "VBoxContainer", 2)
	theme.set_constant("separation", "HBoxContainer", 4)
	_rail.theme = theme
	layer.add_child(_rail)
	# Scrolls when the open tool's options run past the bottom of the screen.
	_rail_scroll = ScrollContainer.new()
	_rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rail.add_child(_rail_scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = RAIL_W - 16
	_rail_scroll.add_child(box)
	_rail_box = box
	var prow := HBoxContainer.new()
	box.add_child(prow)
	var pl := Label.new()
	pl.text = "Part"
	prow.add_child(pl)
	_part_pick = OptionButton.new()
	_part_pick.focus_mode = Control.FOCUS_NONE
	_part_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_part_pick.item_selected.connect(func(i: int) -> void: select_part(i))
	prow.add_child(_part_pick)
	var title := Label.new()
	title.text = "Tools"
	box.add_child(title)
	var group := ButtonGroup.new()
	for t in RAIL_TOOLS:
		var b := Button.new()
		b.text = "%s   %s" % [t[1], t[2]]
		b.toggle_mode = true
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(rail_pick.bind(String(t[0])))
		box.add_child(b)
		_rail_buttons[t[0]] = b
	box.add_child(HSeparator.new())

	_explode_button = Button.new()
	_explode_button.text = "Explode   Alt E"
	_explode_button.toggle_mode = true
	_explode_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_explode_button.focus_mode = Control.FOCUS_NONE
	_explode_button.toggled.connect(func(on: bool) -> void: set_exploded(on))
	box.add_child(_explode_button)
	_hands_button = Button.new()
	_hands_button.text = "Hands   Alt H"
	_hands_button.toggle_mode = true
	_hands_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_hands_button.focus_mode = Control.FOCUS_NONE
	_hands_button.toggled.connect(func(on: bool) -> void: set_hands(on))
	box.add_child(_hands_button)
	var play := Button.new()
	play.text = "Play: fire, reload   Alt P"
	play.alignment = HORIZONTAL_ALIGNMENT_LEFT
	play.focus_mode = Control.FOCUS_NONE
	play.pressed.connect(func() -> void: play_cycle())
	box.add_child(play)
	var to_game := Button.new()
	to_game.text = "Export to game   Alt X"
	to_game.alignment = HORIZONTAL_ALIGNMENT_LEFT
	to_game.focus_mode = Control.FOCUS_NONE
	to_game.pressed.connect(func() -> void: export_game())
	box.add_child(to_game)
	var to_print := Button.new()
	to_print.text = "Export to print   Alt B"
	to_print.alignment = HORIZONTAL_ALIGNMENT_LEFT
	to_print.focus_mode = Control.FOCUS_NONE
	to_print.pressed.connect(func() -> void: export_print())
	box.add_child(to_print)
	box.add_child(HSeparator.new())

	# The shape brush: Ctrl + LMB lays a shape, Ctrl + RMB carves it out, in any tool.
	_shape_box2 = VBoxContainer.new()
	box.add_child(_shape_box2)
	var sbt := Label.new()
	sbt.text = "drag to go on; Ctrl + click does it in any tool"
	_shape_box2.add_child(sbt)
	var kinds2 := OptionButton.new()
	for k in BRUSH_SHAPES:
		kinds2.add_item(k[1])
	kinds2.focus_mode = Control.FOCUS_NONE
	kinds2.item_selected.connect(func(i: int) -> void: brush3d = BRUSH_SHAPES[i][0])
	_shape_box2.add_child(kinds2)
	_shape_size_label = Label.new()
	_shape_box2.add_child(_shape_size_label)
	_shape_size_slider = HSlider.new()
	_shape_size_slider.min_value = 1
	_shape_size_slider.max_value = SHAPE_SIZE_MAX
	_shape_size_slider.step = 1
	_shape_size_slider.focus_mode = Control.FOCUS_NONE
	_shape_size_slider.value_changed.connect(func(v: float) -> void: shape_size = int(v))
	_shape_box2.add_child(_shape_size_slider)
	var trow := HBoxContainer.new()
	_shape_box2.add_child(trow)
	var tl := Label.new()
	tl.text = "flat ones, thick"
	trow.add_child(tl)
	var ts := SpinBox.new()
	ts.min_value = 1
	ts.max_value = 12
	ts.value = shape_thick
	ts.value_changed.connect(func(v: float) -> void: shape_thick = int(v))
	trow.add_child(ts)
	box.add_child(HSeparator.new())

	# The brush: paint and sketch share it.
	_brush_box = VBoxContainer.new()
	box.add_child(_brush_box)
	_brush_label = Label.new()
	_brush_box.add_child(_brush_label)
	_brush_slider = HSlider.new()
	_brush_slider.min_value = 0
	_brush_slider.max_value = 8
	_brush_slider.step = 1
	_brush_slider.focus_mode = Control.FOCUS_NONE
	_brush_slider.value_changed.connect(func(v: float) -> void: set_brush_size(int(v)))
	_brush_box.add_child(_brush_slider)
	var shapes := OptionButton.new()
	shapes.add_item("round")
	shapes.add_item("square")
	shapes.focus_mode = Control.FOCUS_NONE
	shapes.item_selected.connect(func(i: int) -> void: brush_shape = "round" if i == 0 else "square")
	_brush_box.add_child(shapes)

	_paint_box = VBoxContainer.new()
	box.add_child(_paint_box)
	var paints := OptionButton.new()
	for w in PAINT_WHAT:
		paints.add_item("paints " + w[1])
	paints.focus_mode = Control.FOCUS_NONE
	paints.item_selected.connect(func(i: int) -> void: paint_what = PAINT_WHAT[i][0])
	_paint_box.add_child(paints)

	_draw_box = VBoxContainer.new()
	box.add_child(_draw_box)
	var dl := Label.new()
	dl.text = "draw with"
	_draw_box.add_child(dl)
	var draws := OptionButton.new()
	_draws = draws
	for d in SKETCH_DRAWS:
		draws.add_item(d[1])
	draws.focus_mode = Control.FOCUS_NONE
	draws.item_selected.connect(func(i: int) -> void:
		sketch_draw = SKETCH_DRAWS[i][0]
		_draw_2d = sketch_draw
		_sync_sketch_panels()
		_sketch.clear())
	_draw_box.add_child(draws)

	# The open tool's own options, which had a panel of their own.
	var inner := _tool_panel.get_child(0)
	_tool_panel.remove_child(inner)
	box.add_child(inner)
	_tool_panel.queue_free()
	_tool_panel = null
	# The brush's options under the Shapes tool's own choice of drag or brush.
	_shape_box2.get_parent().remove_child(_shape_box2)
	_shape_box.add_child(_shape_box2)
	_shape_box.move_child(_shape_box2, _shape_mode_pick.get_index() + 1)
	_fit_rail(box)
	set_brush_size(brush_size)


## Everything in the rail kept to its width: labels wrap, choices clip their text.
func _fit_rail(n: Node) -> void:
	for c in n.get_children():
		if c is Label:
			(c as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			(c as Label).custom_minimum_size.x = RAIL_W - 16
		elif c is OptionButton:
			(c as OptionButton).clip_text = true
			(c as OptionButton).custom_minimum_size.x = RAIL_W - 16
		elif c is HBoxContainer:
			# A label and its number side by side: the label takes what the number leaves.
			for k in c.get_children():
				if k is Label:
					(k as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
					(k as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
					(k as Label).custom_minimum_size.x = RAIL_W - 16 - 72
				elif k is SpinBox:
					(k as SpinBox).custom_minimum_size.x = 64
			continue
		_fit_rail(c)


func _over_rail() -> bool:
	return _rail != null and _rail.is_visible_in_tree() \
			and _rail.get_global_rect().has_point(_rail.get_global_mouse_position())


## Where things to the right of the rail start.
func _rail_right() -> float:
	return 12.0 if _rail == null else _rail.position.x + maxf(RAIL_W, _rail.size.x) + 12.0


## A rail button: the tool it names, everything else put down.
func rail_pick(id: String) -> void:
	if not _lathe_axis.is_empty() and id != rail_active():
		lathe_drop()
	match id:
		"sculpt", "sketch":
			set_measure(false)
			_set_painting(false)
			var draw := "sculpt" if id == "sculpt" else _draw_2d
			if draw != sketch_draw:
				_sketch.clear()
			sketch_draw = draw
			set_tool("sketch")
			_sync_sketch_panels()
		"place":
			set_tool("")
			_set_painting(false)
			set_measure(false)
		"paint":
			set_tool("")
			set_measure(false)
			_set_painting(true)
		"measure":
			set_tool("")
			_set_painting(false)
			set_measure(true)
		_:
			set_measure(false)
			set_tool(id)


func rail_active() -> String:
	if _painting:
		return "paint"
	if measure_on:
		return "measure"
	if tool == "sketch":
		return "sculpt" if sketch_draw == "sculpt" else "sketch"
	if _rail_buttons.has(tool):
		return tool
	return "place"


## The Sculpt tool's panel or the Sketch tool's, as the tool in hand is.
func _sync_sketch_panels() -> void:
	if _sculpt_box == null:
		return
	var sculpting := sketch_draw == "sculpt"
	_sculpt_box.visible = sculpting
	_sketch2d_box.visible = not sculpting
	_sketch_title.text = "Sculpt in 3D (Alt V)" if sculpting else "Sketch in 2D: bricks (Alt D)"
	if not sculpting and sculpt != null:
		sculpt.show_cursor(null, 0.0, Color.WHITE)
		sculpt.show_ghost({}, Color.WHITE)


## The brush in hand: the paint brush while painting, else the sketch brush.
func set_brush_size(n: int) -> void:
	if _painting:
		_paint_radius = clampi(n, 0, PAINT_RADIUS_MAX)
		if _paint_palette != null:
			_paint_palette.info = _paint_info()
	else:
		brush_size = clampi(n, 0, 8)


## Each frame: the rail shows the tool in hand, the brush its size (the - and = keys
## size the paint brush), and only the options of what is open.
func _rail_process() -> void:
	if _rail == null:
		return
	var on := rail_active()
	if _part_pick.item_count != part_names.size():
		_part_pick.clear()
		for n in part_names:
			_part_pick.add_item(n)
	if _part_pick.selected != part_sel:
		_part_pick.select(part_sel)
	for id in _rail_buttons:
		(_rail_buttons[id] as Button).set_pressed_no_signal(id == on)
	var n := _paint_radius if on == "paint" else brush_size
	_brush_slider.set_value_no_signal(n)
	_brush_box.visible = on == "paint" or (on == "sketch" and sketch_draw == "brush")
	if on == "paint" and n == 0:
		_brush_label.text = "brush: one brick"
	elif n == 0:
		_brush_label.text = "brush: half a stud round"
	else:
		_brush_label.text = "brush: %d stud%s round" % [n, "" if n == 1 else "s"]
	_paint_box.visible = on == "paint"
	_draw_box.visible = on == "sketch"
	_shape_box.visible = tool == "shape"
	_sketch_box.visible = tool == "sketch"
	_select_box.visible = tool == "select"
	_shape_box2.visible = (tool == "shape" and shape_mode == "brush") or _shape_brush_on()
	_drag_box.visible = shape_mode == "drag"
	_shape_mode_pick.select(0 if shape_mode == "drag" else 1)
	_shape_size_slider.set_value_no_signal(shape_size)
	_shape_size_label.text = "%d stud%s across%s" % [shape_size, "" if shape_size == 1 else "s",
			"  (Ctrl + wheel)" if on == "place" else ""]
	_rail.position.y = 12.0 + (_menu.bar_height() if _menu != null else 0.0)
	var room := get_viewport().get_visible_rect().size.y - _rail.position.y - 28.0
	_rail_scroll.custom_minimum_size = Vector2(RAIL_W - 16, minf(_rail_box.get_combined_minimum_size().y, room))
	_rail.size = Vector2.ZERO
	if _paint_palette != null:
		_paint_palette.position = Vector2(_rail_right(), _rail.position.y)
	# The workshop's own readout moves over beside the rail.
	_hud.position = Vector2(_rail_right(), _rail.position.y)
	_draws.select(SKETCH_DRAWS.map(func(d: Array) -> String: return d[0]).find(_draw_2d))


## Paint only what the rail says: colour, material, or both (the workshop's own).
func _paint_one(rid: int) -> bool:
	if paint_what == "both":
		return super._paint_one(rid)
	if rid < 0:
		return false
	var c := _colour if paint_what == "colour" else recipe.colour_of(rid)
	var m := _mat if paint_what == "material" else recipe.material_of(rid)
	if recipe.colour_of(rid) == c and recipe.material_of(rid) == m:
		return false
	for e in _stroke:
		if int(e[0]) == rid:
			return false
	_stroke.append([rid, recipe.colour_of(rid), recipe.material_of(rid)])
	_repaint(rid, c, m)
	return true


## A square brush reaches a box round the dot rather than a ball.
func _bricks_near(point: Vector3, reach: float) -> Array[int]:
	if brush_shape != "square":
		return super._bricks_near(point, reach)
	var out: Array[int] = []
	var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	for rid in _placed_at.size():
		var at: Array = _placed_at[rid]
		if int(at[0]) < 0:
			continue
		var box: Array = world.get_block_ticks(asm.frames[at[0]], at[1])
		if box.is_empty():
			continue
		var lo := Vector3(box[0] as Vector3i) * tick
		var hi := lo + Vector3(box[1] as Vector3i) * tick
		var q := Vector3(clampf(point.x, lo.x, hi.x), clampf(point.y, lo.y, hi.y), clampf(point.z, lo.z, hi.z))
		var d := (q - point).abs()
		if maxf(d.x, maxf(d.y, d.z)) <= reach:
			out.append(rid)
	return out


# ---------------------------------------------------------------------------
# Round 4: studs anywhere, and connection points on them
# ---------------------------------------------------------------------------

## Studs put on by hand: {part, at: [studs along, plates up, studs across] of the stud's
## foot, dir: the way it faces, colour, mat}. Any face of any brick, a slope's too.
var extra_studs := []
var _stud_log := []          # what each "stud" edit did, for undo: {op: "add" or "remove", stud}
var _pick_mesh: TriangleMesh
var _pick_dirty := true
var _studs_mmi: MultiMeshInstance3D
var _stud_ghost: MeshInstance3D
const STUD_SNAP := 0.5       # the lattice studs go on: half a stud across a face, half a plate up a side


## Where a stud would go for this ray: on the face it meets, snapped to the face's half-
## stud lattice. {at, dir, part (tag), colour, mat}, or {} off the build.
##
## Found on the drawn surface, not the cells: a slope's face leans, and its stud leans
## with it. Plain (unbevelled) geometry, so an edge's bevel never reads as a face.
func stud_hit(from: Vector3, dir: Vector3) -> Dictionary:
	if _pick_dirty or _pick_mesh == null:
		_pick_dirty = false
		var arrays := world.build_chunk_mesh(chunk)
		var m := ArrayMesh.new()
		if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			_pick_mesh = m.generate_triangle_mesh()
		else:
			_pick_mesh = null
	if _pick_mesh == null:
		return {}
	var inv := world.get_chunk_transform(chunk).affine_inverse()
	var r := _pick_mesh.intersect_ray(inv * from, inv.basis * dir)
	if r.is_empty():
		return {}
	var p: Vector3 = r.position
	var n: Vector3 = (r.normal as Vector3).normalized()
	if n.dot(dir) > 0.0:
		n = -n
	var ax := n.abs()
	var axis := -1
	if ax.x > 0.94:
		axis = 0
	elif ax.y > 0.94:
		axis = 1
	elif ax.z > 0.94:
		axis = 2
	if axis >= 0:
		var sgn := signf(n[axis])
		n = Vector3.ZERO
		n[axis] = sgn
	var cell := _cell_in(chunk, p - n * 0.02)
	var block := world.block_at(chunk, cell)
	if block < 0:
		return {}
	var rid := _recipe_id_at(0, block)
	if rid < 0:
		return {}
	var q: Vector3
	if axis >= 0:
		q = Vector3(p.x / BrickPalette.STUD_M, p.y / BrickPalette.PLATE_M, p.z / BrickPalette.STUD_M)
		for a in 3:
			if a != axis:
				q[a] = snappedf(q[a], STUD_SNAP)
	else:
		# A leaning face: half studs across it and up it, from the brick's own corner.
		var box: Array = world.get_block_ticks(chunk, block)
		var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
		var origin := Vector3(box[0] as Vector3i) * tick
		var across := n.cross(Vector3.UP).normalized()
		var upward := across.cross(n).normalized()
		var d := p - origin
		var step := BrickPalette.STUD_M * STUD_SNAP
		var w := origin + across * snappedf(d.dot(across), step) + upward * snappedf(d.dot(upward), step) \
				+ n * d.dot(n)
		q = Vector3(w.x / BrickPalette.STUD_M, w.y / BrickPalette.PLATE_M, w.z / BrickPalette.STUD_M)
	return {"at": [snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001)],
			"dir": [snappedf(n.x, 0.0001), snappedf(n.y, 0.0001), snappedf(n.z, 0.0001)],
			"part": part_names[part_of[rid] if rid < part_of.size() else part_sel],
			"colour": recipe.colour_of(rid), "mat": recipe.material_of(rid)}


## The stud put on by hand at this spot, by index, or -1.
func stud_at(at: Array) -> int:
	for i in extra_studs.size():
		var a: Array = extra_studs[i].at
		if Vector3(a[0], a[1], a[2]).distance_to(Vector3(at[0], at[1], at[2])) < 0.3:
			return i
	return -1


## Put a stud on, or take one off: an edit of its own, undone with Z.
func stud_edit(add: bool, stud: Dictionary) -> bool:
	var i := stud_at(stud.at)
	if add == (i >= 0):
		return false
	var rec := {"op": "add" if add else "remove", "stud": stud if add else extra_studs[i]}
	_stud_apply(rec, true)
	_edits.append("stud")
	_stud_log.append(rec)
	if not _redoing:
		_redo.clear()
	return true


func _stud_apply(rec: Dictionary, forward: bool) -> void:
	var add: bool = (rec.op == "add") == forward
	var i := stud_at(rec.stud.at)
	if add and i < 0:
		extra_studs.append(rec.stud)
	elif not add and i >= 0:
		extra_studs.remove_at(i)
	_draw_studs()
	_store_asset_meta()
	_autosave_dirty = true
	_tris_due = Time.get_ticks_msec() + TRIS_SETTLE_MS


## The stud tool: LMB puts a stud on, RMB takes one off, shift LMB makes a stud a
## connection point (the panel asks which).
func _stud_input(e: InputEvent) -> bool:
	if tool != "stud" or not (e is InputEventMouseButton and e.pressed):
		return false
	if not e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	var ray := _mouse_ray()
	var hit := stud_hit(ray[0], ray[1])
	if hit.is_empty():
		return true
	if e.button_index == MOUSE_BUTTON_RIGHT:
		var i := stud_at(hit.at)
		if i >= 0:
			stud_edit(false, extra_studs[i])
	elif e.shift_pressed:
		point_on_stud(hit)
	else:
		stud_edit(true, hit)
	return true


## A connection point on a stud: one there already goes, else the panel asks for it.
func point_on_stud(hit: Dictionary) -> void:
	for q in points:
		if Vector3(q.at[0], q.at[1], q.at[2]).distance_to(Vector3(hit.at[0], hit.at[1], hit.at[2])) < 0.3:
			toggle_point(q.at, "", "", "")
			return
	_point_panel.visible = true
	_point_panel.set_meta("at", hit.at)
	_point_panel.set_meta("dir", hit.dir)
	_fill_point_ifaces()


## Every stud put on by hand, as one MultiMesh: the build's own stud, in its brick's paint.
func _draw_studs() -> void:
	if _studs_mmi == null:
		_studs_mmi = MultiMeshInstance3D.new()
		_studs_mmi.material_override = _stud_material()
		_studs_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_studs_mmi)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.stud()
	mm.instance_count = extra_studs.size()
	for i in extra_studs.size():
		var st: Dictionary = extra_studs[i]
		mm.set_instance_transform(i, _stud_transform(st).translated(part_offset(String(st.get("part", "")))))
		mm.set_instance_color(i, BrickWorld.get_material_colour(int(st.get("mat", 0)), int(st.get("colour", 0))))
	_studs_mmi.multimesh = mm


static func _stud_transform(st: Dictionary) -> Transform3D:
	var a: Array = st.at
	var d: Array = st.dir
	return Transform3D(_basis_up(Vector3(d[0], d[1], d[2])),
			Vector3(float(a[0]) * BrickPalette.STUD_M, float(a[1]) * BrickPalette.PLATE_M, float(a[2]) * BrickPalette.STUD_M))


## In the stud tool, a see-through stud where one would go.
func _stud_ghost_process() -> void:
	if _stud_ghost == null:
		_stud_ghost = MeshInstance3D.new()
		_stud_ghost.mesh = PieceMeshes.stud()
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 0.95, 0.4, 0.6)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_stud_ghost.material_override = mat
		add_child(_stud_ghost)
	_stud_ghost.visible = false
	if tool != "stud":
		return
	var ray := _mouse_ray()
	var hit := stud_hit(ray[0], ray[1])
	if hit.is_empty():
		return
	_stud_ghost.visible = true
	_stud_ghost.transform = _stud_transform(hit).translated(_ray_offset())


# ---------------------------------------------------------------------------
# Round 4: the exploded view, and whole parts moved
# ---------------------------------------------------------------------------

const EXPLODE_GAP := 10      # studs between a part and the one it sits on, exploded
var exploded := false
var _display := {}           # part -> {mesh, pick (TriangleMesh), xform, offset}
var _display_dirty := true
var _offsets := {}           # part -> where it is drawn, exploded (metres)
var _ray_part := ""          # the part the last mouse ray was taken into
var _move := {}              # a part being dragged: {part, from (plane point), normal, by}


func set_exploded(on: bool) -> void:
	if on and _sculpting():
		on = false
		_show_sculpt_note(true, "Explode works once the block-out is converted to bricks.")
	exploded = on
	_display_dirty = true
	if not on and tried.is_empty():
		_clear_display()
		_offsets.clear()
	if _explode_button != null:
		_explode_button.set_pressed_no_signal(on)
	_draw_studs()
	_draw_points()
	_outlines_dirty = true


## Where each part goes, exploded: the body stays, the barrel goes forward of it, the
## muzzle further, the stock behind, the grip under it, the underbarrel under the barrel,
## the sight over it. Anything else (a magazine sits where the gun has it) goes out the
## way it already is from the body, twice as far.
func explode_offsets() -> Dictionary:
	settle_muzzle()
	var sums := {}
	var counts := {}
	for i in recipe.size():
		if recipe.frame_of(i) != 0:
			continue
		var name := part_names[part_of[i] if i < part_of.size() else part_sel]
		var size := BrickPalette.size_of(recipe.part_of(i))
		var c := recipe.cell_of(i)
		var m := Vector3((c.x + size.x * 0.5) * BrickPalette.STUD_M, (c.y + size.y * 0.5) * BrickPalette.PLATE_M,
				(c.z + size.z * 0.5) * BrickPalette.STUD_M)
		sums[name] = sums.get(name, Vector3.ZERO) + m
		counts[name] = int(counts.get(name, 0)) + 1
	var body: Vector3 = sums["body"] / counts["body"] if sums.has("body") else Vector3.ZERO
	var fwd := Vector3(-1 if muzzle_end == "-x" else 1, 0, 0)
	var g := EXPLODE_GAP * BrickPalette.STUD_M
	var out := {}
	for name in sums:
		match name:
			"body": out[name] = Vector3.ZERO
			"barrel": out[name] = fwd * g
			"muzzle": out[name] = fwd * g * 2.0
			"stock": out[name] = -fwd * g
			"grip": out[name] = Vector3.DOWN * g
			"sight": out[name] = Vector3.UP * g
			"underbarrel": out[name] = fwd * g + Vector3.DOWN * g
			_:
				var d: Vector3 = sums[name] / counts[name] - body
				out[name] = (d.normalized() if d.length() > 0.01 else Vector3.DOWN) * g * 2.0
	return out


## Where a part is drawn: its exploded place, or where it is.
func part_offset(part: String) -> Vector3:
	return _offsets.get(part, Vector3.ZERO) if _drawn_apart() else Vector3.ZERO


## Are the parts drawn one by one: exploded, or a catalogue part tried on (one of them
## hidden, the rest maybe moved onto a tried body's sockets)?
func _drawn_apart() -> bool:
	return exploded or not tried.is_empty()


## The offset the last mouse ray was taken in by: the part it met, else the current part.
func _ray_offset() -> Vector3:
	if not _drawn_apart():
		return Vector3.ZERO
	return part_offset(_ray_part if _ray_part != "" else part_names[part_sel])


## Each part as its own mesh -- its bricks laid again in a chunk of their own -- so the
## parts can be drawn apart (and, later, moved by the hands). Built again after an edit.
func _rebuild_display() -> void:
	_display_dirty = false
	_clear_display()
	_offsets = _drawn_offsets()
	var by_part := {}
	for i in recipe.size():
		if recipe.frame_of(i) == 0:
			(by_part.get_or_add(part_names[part_of[i] if i < part_of.size() else part_sel], []) as Array).append(i)
	var base := world.get_chunk_transform(chunk)
	for name in by_part:
		if tried.has(name):
			continue   # a catalogue part is tried in its place
		var ids: Array = by_part[name]
		var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
		var hi := -lo
		for i in ids:
			lo = lo.min(recipe.cell_of(i))
			hi = hi.max(recipe.cell_of(i) + BrickPalette.size_of(recipe.part_of(i)))
		var c := world.create_chunk(Vector3i.ZERO, hi - lo)
		for i in ids:
			var arch := String(recipe.part_of(i))
			if not palette.has(arch):
				continue
			var bid := world.place_block(c, recipe.cell_of(i) - lo, palette[arch], recipe.colour_of(i))
			if bid >= 0 and recipe.material_of(i) != 0:
				world.set_block_material(c, bid, recipe.material_of(i))
		var xform := base * Transform3D(Basis(), Vector3(lo.x * BrickPalette.STUD_M, lo.y * BrickPalette.PLATE_M,
				lo.z * BrickPalette.STUD_M))
		xform = xform.translated(_offsets.get(name, Vector3.ZERO))
		var mi := MeshInstance3D.new()
		mi.material_override = _material
		var arrays := world.build_chunk_chamfer_mesh(c, BrickNear.BEVEL) if BrickNear.enabled \
				else world.build_chunk_mesh(c)
		var m := ArrayMesh.new()
		if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mi.mesh = m
		mi.set_instance_shader_parameter("geo_bevel", 1.0 if BrickNear.enabled else 0.0)
		mi.transform = xform
		add_child(mi)
		var studs: PackedFloat32Array = world.get_chunk_studs(c)
		@warning_ignore("integer_division")
		var count := studs.size() / 16
		if count > 0:
			var mmi := MultiMeshInstance3D.new()
			mmi.material_override = _stud_material()
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = PieceMeshes.stud()
			mm.instance_count = count
			mm.set_buffer(studs)
			mmi.multimesh = mm
			mi.add_child(mmi)
		var plain := world.build_chunk_mesh(c)
		var pm := ArrayMesh.new()
		var pick: TriangleMesh = null
		if plain.size() > 0 and not (plain[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			pm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plain)
			pick = pm.generate_triangle_mesh()
		world.release_chunk(c)
		_display[name] = {"mesh": mi, "pick": pick, "xform": xform, "offset": _offsets.get(name, Vector3.ZERO),
				"centre": xform * (Vector3(hi - lo) * Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M) * 0.5)}
	_draw_studs()
	_draw_points()
	_draw_tried()


func _clear_display() -> void:
	for name in _display:
		(_display[name].mesh as Node).queue_free()
	_display.clear()


## Each frame, exploded: the parts built again if an edit changed them, the build itself
## hidden behind them, and what follows the mouse drawn where its part is.
func _explode_process() -> void:
	var apart := _drawn_apart() or not _play.is_empty()
	for f in _frame_meshes:
		(_frame_meshes[f] as Node3D).visible = not apart
	if apart and _display_dirty:
		_rebuild_display()
	_play_process()
	_place_hands()
	if not _drawn_apart():
		_tool_lines.position = Vector3.ZERO
		return
	var off := _ray_offset()
	_ghost.global_position += off
	_tool_lines.position = off
	if _sketch_static != null:
		_sketch_static.position = part_offset(part_names[part_sel])


## Exploded, the mouse ray is taken into the part it meets: moved back by that part's
## offset and started just short of it, so everything after (the ghost, a place, a delete,
## a stud, paint) works on the build where it really is. A ray that meets no part is
## the current part's.
func _mouse_ray() -> Array:
	return ray_into_parts(super._mouse_ray())


func ray_into_parts(r: Array) -> Array:
	_ray_part = ""
	if not _drawn_apart():
		return r
	if _display_dirty:
		_rebuild_display()
	var best_t := INF
	for name in _display:
		var d: Dictionary = _display[name]
		if d.pick == null:
			continue
		var inv := (d.xform as Transform3D).affine_inverse()
		var hit := (d.pick as TriangleMesh).intersect_ray(inv * (r[0] as Vector3), inv.basis * (r[1] as Vector3))
		if hit.is_empty():
			continue
		var t := ((d.xform as Transform3D) * (hit.position as Vector3) - (r[0] as Vector3)).length()
		if t < best_t:
			best_t = t
			_ray_part = name
	var off := _ray_offset()
	var from: Vector3 = r[0]
	if _ray_part != "":
		from += (r[1] as Vector3) * maxf(best_t - 0.05, 0.0)
	return [from - off, r[1]]


## Move a whole part by `by` cells: its bricks taken up and laid again there, its
## sketches, studs and connection points with it, as one undo. Refused (false) if
## anything else is in the way.
func move_part(part: String, by: Vector3i) -> bool:
	var tag := part_names.find(part)
	if tag < 0 or by == Vector3i.ZERO:
		return false
	var ids := []
	var own := {}
	for i in recipe.size():
		if recipe.frame_of(i) == 0 and (part_of[i] if i < part_of.size() else -1) == tag:
			ids.append(i)
			var size := BrickPalette.size_of(recipe.part_of(i))
			for dx in size.x:
				for dy in size.y:
					for dz in size.z:
						own[recipe.cell_of(i) + Vector3i(dx, dy, dz)] = true
	if ids.is_empty():
		return false
	for c in own:
		var t: Vector3i = c + by
		if t.x < 0 or t.y < 0 or t.z < 0 or t.x >= plate_studs or t.y >= height_plates or t.z >= plate_studs:
			return false
		if not own.has(t) and world.block_at(chunk, t) >= 0:
			return false
	var items := []
	for i in ids:
		items.append(_brick_info(i))
	var g := {"part": part, "before": {}, "after": {}, "bricks_before": part_bricks.get(part, []),
			"studs_before": extra_studs.duplicate(), "points_before": points.duplicate()}
	ids.sort()
	ids.reverse()
	var ops := 0
	_batch = true
	for i in ids:
		if take_brick(int(i)):
			ops += 1
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.cell.y < b.cell.y)
	var keep := part_sel
	for b in items:
		part_sel = int(b.tag)
		if place_named(b.arch, b.cell + by, b.colour, b.mat):
			ops += 1
	part_sel = keep
	_batch = false
	_after_edit()
	for k in sketches.keys():
		var sk: Dictionary = sketches[k]
		if String(sk.part) != part:
			continue
		var moved := shift_sketch(sk, by)
		var nk: String = k if sk.has("solid") else "%s|%s|%s" % [part, moved.plane, _num(float(moved.at))]
		g.before[k] = sk
		if not g.before.has(nk):
			g.before[nk] = sketches.get(nk)
		g.after[k] = null
		g.after[nk] = moved
	var bricks := []
	for b in part_bricks.get(part, []):
		bricks.append([b[0], [int(b[1][0]) + by.x, int(b[1][1]) + by.y, int(b[1][2]) + by.z]])
	g["bricks_after"] = bricks
	var studs := []
	for st in extra_studs:
		var moved_st: Dictionary = st.duplicate()
		if String(st.part) == part:
			moved_st.at = [float(st.at[0]) + by.x, float(st.at[1]) + by.y, float(st.at[2]) + by.z]
		studs.append(moved_st)
	g["studs_after"] = studs
	var pts := []
	for q in points:
		var moved_q: Dictionary = q.duplicate()
		if String(q.part) == part:
			moved_q.at = [float(q.at[0]) + by.x, float(q.at[1]) + by.y, float(q.at[2]) + by.z]
		pts.append(moved_q)
	g["points_after"] = pts
	_restore_sketch(g, "after")
	_group_with(ops, g)
	return true


## While a part is dragged: the box round it, where it would go.
func _draw_move(im: ImmediateMesh) -> void:
	if _move.is_empty():
		return
	var tag := part_names.find(String(_move.part))
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for i in recipe.size():
		if recipe.frame_of(i) == 0 and i < part_of.size() and part_of[i] == tag:
			lo = lo.min(recipe.cell_of(i))
			hi = hi.max(recipe.cell_of(i) + BrickPalette.size_of(recipe.part_of(i)))
	if lo.x > hi.x:
		return
	var by: Vector3i = _move.by
	var cell := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	_box_lines(im, Vector3(lo + by) * cell, Vector3(hi + by) * cell, Color(0.4, 1.0, 0.6))
	im.surface_end()


## A sketch moved by `by` cells: its outlines across and up its plane, its depth along it.
static func shift_sketch(sk: Dictionary, by: Vector3i) -> Dictionary:
	if sk.has("solid"):
		var shifted := sk.duplicate()
		shifted.solid = (sk.solid as Dictionary).duplicate()
		shifted.solid.at = (sk.solid.at as Array).map(func(q: Array) -> Array:
			return [int(q[0]) + by.x, int(q[1]) + by.y, int(q[2]) + by.z])
		return shifted
	var d := Vector3(by)
	match String(sk.plane):
		"front": d = Vector3(by.z, by.y, by.x)
		"top": d = Vector3(by.x, by.z, by.y)
	var out := sk.duplicate()
	out.at = float(sk.at) + d.z
	out.adds = (sk.adds as Array).map(func(e: Variant) -> Variant: return _shift_entry(e, d.x, d.y))
	out.subs = (sk.subs as Array).map(func(e: Variant) -> Variant: return _shift_entry(e, d.x, d.y))
	return out


## Resize the block-out: every part's form scaled by `s` about `pivot` (a cell: studs
## along, plates up, studs across; by default the middle of the forms, on their bottom)
## and every part laid again from it, as one undo. If that runs off the build area but
## would fit in it, the whole block-out slides back in. Bricks no form laid, hand studs
## and connection points stay as they are. Refused (false, nothing changed) when it is
## too big for the build area.
func scale_form(s: float, pivot: Variant = null) -> bool:
	if is_equal_approx(s, 1.0) or s <= 0.0 or sketches.is_empty():
		return false
	var at: Vector3 = form_pivot() if pivot == null else pivot
	if pivot != null:
		form_pivot()
	# Too big is told from the forms' box before anything is worked out at that size: a
	# form a hundred times over is millions of cells.
	var span := Vector3(_forms_hi - _forms_lo + Vector3i.ONE) * s
	var room := Vector3(plate_studs, height_plates, plate_studs)
	for i in 3:
		if span[i] > room[i] + 1.0:
			print("[asset workshop] resize x%.2f refused: %d cells %s, the build area is %d" % [s,
					int(span[i]), ["along", "up", "across"][i], int(room[i])])
			return false
	var scaled := {}   # part -> {old key: scaled sketch}
	for k in sketches:
		var sk: Dictionary = sketches[k]
		(scaled.get_or_add(String(sk.part), {}) as Dictionary)[k] = scale_sketch(sk, s, at)
	# The box round every part as it would be, then what slides it back in.
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for part in scaled:
		var list := []
		for k in scaled[part]:
			list.append([k, scaled[part][k]])
		list.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1].get("n", 0)) < int(b[1].get("n", 0)))
		if part_volume(list).is_empty():
			continue
		lo = lo.min(_box[0])
		hi = hi.max(_box[1])
	var area := Vector3i(plate_studs, height_plates, plate_studs)
	var by := Vector3i.ZERO
	for i in 3:
		if lo[i] > hi[i]:
			break
		if hi[i] - lo[i] + 1 > area[i]:
			print("[asset workshop] resize x%.2f refused: %d cells %s, the build area is %d" % [s,
					hi[i] - lo[i] + 1, ["along", "up", "across"][i], area[i]])
			return false
		by[i] = maxi(0, -lo[i]) - maxi(0, hi[i] - (area[i] - 1))
	var gone := {}   # part -> {old key: null}
	var made := {}   # part -> {new key: its sketch}
	for part in scaled:
		for k in scaled[part]:
			var sk: Dictionary = scaled[part][k]
			if by != Vector3i.ZERO:
				sk = shift_sketch(sk, by)
			var nk: String = k if sk.has("solid") else "%s|%s|%s" % [part, sk.plane, _num(float(sk.at))]
			(gone.get_or_add(part, {}) as Dictionary)[k] = null
			(made.get_or_add(part, {}) as Dictionary)[nk] = sk
	_begin_gather()
	# Every part taken up before any is laid again: a part grown into where another's old
	# bricks still were would be laid round them.
	for part in gone:
		resketch_part(part, gone[part], true)
	for part in made:
		resketch_part(part, made[part], true)
	_end_gather()
	return true


## Give a part a shell (`settings`: {thick, res}, or null to take it off) and lay it again:
## its bricks become the form shrunk by the thickness, inside one smooth surface. One undo,
## which puts the settings back too.
func set_shell(part: String, settings: Variant) -> void:
	var was = (shells[part] as Dictionary).duplicate() if shells.has(part) else null
	if settings == null:
		shells.erase(part)
	else:
		var st: Dictionary = (settings as Dictionary).duplicate()
		st["thick"] = clampf(float(st.get("thick", 0.5)), 0.0, 4.0)
		st["res"] = clampi(int(st.get("res", 4)), 1, 8)
		st["tris"] = clampi(int(st.get("tris", was.get("tris", SHELL_TRIS) if was != null else SHELL_TRIS)), 50, 50000)
		if not st.has("colour"):
			st["colour"] = was.colour if was != null else _colour
			st["mat"] = was.mat if was != null else _mat
		shells[part] = st
	var now = (shells[part] as Dictionary).duplicate() if shells.has(part) else null
	_store_asset_meta()
	_begin_gather()
	if not part_sketches(part).is_empty():
		resketch_part(part, {}, true)
	_end_gather()
	var rec := {"shell_part": part, "shell_before": was, "shell_after": now}
	if not _edit_groups.is_empty() and _edit_groups.back().get("sketch") is Array \
			and int(_edit_groups.back().end) == _edits.size():
		(_edit_groups.back().sketch as Array).push_front(rec)
	else:
		_edit_groups.append({"end": _edits.size(), "n": 0, "sketch": [rec]})
	_refresh_shell(part)


## A part's form sampled finely for its shell: {field, dims, lo, k} -- `field` a byte a
## sample, `lo` the first sample, samples 1/k of a stud along and across and 1/k of a
## plate up -- or {} when it has no form. The sketches are scaled k times and laid out as
## a part's volume is (`scale_sketch`, `part_volume`): the same outlines, finer cells.
## A sample on a face where the form meets another part's brick is pinned (2): the
## shell stays flat there, on the face, so it meets the next part rather than shrinking
## off it as the smoothing rounds everything else. `form`: the part's cells, if known.
func shell_field(part: String, list: Array = [], form: Dictionary = {}) -> Dictionary:
	if not shells.has(part):
		return {}
	if shells[part].get("sdf", false):
		return _sdf_shell_field(part)
	if list.is_empty():
		list = part_sketches(part)
	if form.is_empty():
		var keep := _box.duplicate()
		var keep_c := _course
		form = part_volume(list)
		_box = keep
		_course = keep_c
	var k := int(shells[part].res)
	var scaled := []
	for e in list:
		scaled.append([e[0], scale_sketch(e[1], float(k), Vector3.ZERO)])
	var keep_box := _box.duplicate()
	var keep_course := _course
	_no_clip = true
	var fine := part_volume(scaled)
	_no_clip = false
	_box = keep_box
	_course = keep_course
	if fine.is_empty():
		return {}
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for c in fine:
		lo = lo.min(c)
		hi = hi.max(c)
	var dims := hi - lo + Vector3i.ONE
	var field := PackedByteArray()
	field.resize(dims.x * dims.y * dims.z)
	# Another part's bricks, by block: this part's own (old slopes, a brick laid by hand)
	# are not a face it meets -- pinned there, the shell kept their stairs.
	var tag := part_names.find(part)
	var other := {}
	for i in _placed_at.size():
		if int(_placed_at[i][0]) == 0 and i < part_of.size() and part_of[i] != tag:
			other[int(_placed_at[i][1])] = true
	var joins := {}   # the part's cells against another part's bricks
	for c in fine:
		var d: Vector3i = c - lo
		var v := 1
		var cell := Vector3i(floori(c.x / float(k)), floori(c.y / float(k)), floori(c.z / float(k)))
		var r: Vector3i = c - cell * k
		for axis in 3:
			for side in [-1, 1]:
				if (side < 0 and r[axis] != 0) or (side > 0 and r[axis] != k - 1):
					continue
				var nb := cell
				nb[axis] += side
				if not form.has(nb) and other.has(world.block_at(chunk, nb)):
					v = 2
					if form.has(cell):
						joins[cell] = true
		field[d.x + dims.x * (d.y + dims.y * d.z)] = v
	var sf := {"field": field, "dims": dims, "lo": lo, "k": k, "joins": joins}
	_shell_distance(list, sf)
	return sf


## The form as distances (studs; negative inside) on the samples round `sf`'s, one more
## all round: what the drawn outlines are, exactly, not which samples they cover -- so the
## shell follows a slanted outline and its corners instead of stepping with the samples.
## Into `sf` as `distance`, `dlo`, `ddims`, `pins`. Only for forms of sketches (outlines and
## brush strokes, in every view): a part with a pocket or a shape-brush shape keeps the
## samples (and its shell is the blurred one).
func _shell_distance(list: Array, sf: Dictionary) -> void:
	var base := ""
	for e in list:
		var sk: Dictionary = e[1]
		if sk.has("solid") or _has_pocket(sk):
			return
		if base == "" and not (sk.adds as Array).is_empty():
			base = String(sk.plane)
	if base == "" or not ClassDB.class_exists("FormMesher"):
		return
	var k: int = sf.k
	var lo: Vector3i = sf.lo - Vector3i.ONE
	var dims: Vector3i = sf.dims + Vector3i(2, 2, 2)
	var n := dims.x * dims.y * dims.z
	var dist := PackedFloat32Array()
	dist.resize(n)
	dist.fill(INF)
	# The slabs on the base plane: each its outline's distance, cut to its thickness.
	for e in list:
		var sk: Dictionary = e[1]
		if String(sk.plane) != base or (sk.adds as Array).is_empty():
			continue
		var grid := _sketch_distance(sk, lo, dims, k)
		var axis := _plane_axis(base)
		var lo_d: float
		var hi_d: float
		if base == "top":
			lo_d = float(int(sk.at)) * 0.4
			hi_d = lo_d + maxi(1, int(round(int(sk.width) * 2.5))) * 0.4
		else:
			lo_d = float(roundi(float(sk.at) - int(sk.width) * 0.5))
			hi_d = lo_d + int(sk.width)
		var scale_d := 0.4 if axis == 1 else 1.0
		for z in dims.z:
			for y in dims.y:
				for x in dims.x:
					var cell := Vector3i(x, y, z)
					var a := ((lo + cell)[axis] + 0.5) / float(k) * scale_d
					var depth := maxf(lo_d - a, a - hi_d)
					var i := x + dims.x * (y + dims.y * z)
					var g := _plane_cell(cell, base)
					var v := maxf(grid[g.x + _plane_size(dims, base).x * g.y], depth)
					dist[i] = minf(dist[i], v)
	# Views through it: drawn in, only what is inside; drawn out, cut right through.
	for e in list:
		var sk: Dictionary = e[1]
		var pl := String(sk.plane)
		if pl == base:
			continue
		var keep := not (sk.adds as Array).is_empty()
		var grid := _sketch_distance(sk, lo, dims, k, not keep)
		var w := _plane_size(dims, pl).x
		for z in dims.z:
			for y in dims.y:
				for x in dims.x:
					var g := _plane_cell(Vector3i(x, y, z), pl)
					var i := x + dims.x * (y + dims.y * z)
					var v: float = grid[g.x + w * g.y]
					dist[i] = maxf(dist[i], v if keep else -v)
	var pins := PackedByteArray()
	pins.resize(n)
	var fd: Vector3i = sf.dims
	var field: PackedByteArray = sf.field
	for z in fd.z:
		for y in fd.y:
			for x in fd.x:
				if field[x + fd.x * (y + fd.y * z)] == 2:
					pins[(x + 1) + dims.x * ((y + 1) + dims.y * (z + 1))] = 1
	sf["distance"] = dist
	sf["dlo"] = lo
	sf["ddims"] = dims
	sf["pins"] = pins


## Which axis of the build a plane's normal is.
static func _plane_axis(plane: String) -> int:
	match plane:
		"front": return 0
		"top": return 1
	return 2


## A sample of the box as a cell of a plane's grid (across, up): `_sketch_grid` for samples.
static func _plane_cell(c: Vector3i, plane: String) -> Vector2i:
	match plane:
		"front": return Vector2i(c.z, c.y)
		"top": return Vector2i(c.x, c.z)
	return Vector2i(c.x, c.y)


static func _plane_size(dims: Vector3i, plane: String) -> Vector2i:
	return _plane_cell(dims, plane)


## A sketch's outlines as distances (studs) over the box's samples seen from its plane:
## its area drawn in (outlines and brush strokes), less what is cut right through -- or,
## `cuts`, the cut-through area alone.
func _sketch_distance(sk: Dictionary, lo: Vector3i, dims: Vector3i, k: int, cuts: bool = false) -> PackedFloat32Array:
	var pl := String(sk.plane)
	var size := _plane_size(dims, pl)
	var origin := Vector2(_plane_cell(lo, pl)) / float(k)
	var step := Vector2.ONE / float(k)
	var sc := Vector2(1.0, 1.0) if pl == "top" else Vector2(1.0, 0.4)
	var area := _entries_distance(sk.subs if cuts else sk.adds, origin, step, size, sc, cuts)
	if cuts:
		return area
	var subs := _entries_distance(sk.subs, origin, step, size, sc, true)
	if subs.is_empty():
		return area
	for i in area.size():
		area[i] = maxf(area[i], -subs[i])
	return area


## The distance to some sketch entries -- outlines and brush strokes -- over a plane's
## samples. `through_only`: only the entries that cut right through (not depth pockets).
func _entries_distance(entries: Array, origin: Vector2, step: Vector2, size: Vector2i, sc: Vector2,
		through_only: bool) -> PackedFloat32Array:
	var polys := []
	var brushes := []
	for e in entries:
		if e is Dictionary:
			if e.has("cut"):
				continue
			if e.has("brush"):
				brushes.append(e)
		else:
			var pts := PackedVector2Array()
			for q in e:
				pts.append(Vector2(float(q[0]), float(q[1])))
			polys.append(pts)
	var out := PackedFloat32Array()
	if polys.is_empty() and brushes.is_empty():
		return out
	if not polys.is_empty():
		out = ClassDB.class_call_static("FormMesher", "polygon_distance", polys, origin, step, size, sc)
	else:
		out.resize(size.x * size.y)
		out.fill(INF)
	# A brush stroke: within its reach of its path (round, its reach in studs).
	for b in brushes:
		var path: Array = b.brush
		var r := float(b.get("rx", 0.5)) * sc.x
		for v in size.y:
			for u in size.x:
				var q := Vector2((origin.x + (u + 0.5) * step.x) * sc.x, (origin.y + (v + 0.5) * step.y) * sc.y)
				var best := INF
				for j in path.size():
					var a := Vector2(float(path[j][0]) * sc.x, float(path[j][1]) * sc.y)
					var c := a if j + 1 >= path.size() else Vector2(float(path[j + 1][0]) * sc.x, float(path[j + 1][1]) * sc.y)
					best = minf(best, Geometry2D.get_closest_point_to_segment(q, a, c).distance_to(q))
				var i := u + size.x * v
				out[i] = minf(out[i], best - r)
	return out


## The cells a shelled part's bricks fill: every cell of the grid whose samples are all
## inside the form shrunk by the shell's thickness -- and every cell where the part meets
## another part's bricks: real bricks there, embedded in the shell, join it to that part
## exactly (a drawn outline that stops a little short of the body still meets it).
func shell_core(part: String, sf: Dictionary) -> Dictionary:
	var core := (sf.get("joins", {}) as Dictionary).duplicate()
	if sf.is_empty():
		return core
	var k: int = sf.k
	var t := float(shells[part].thick)
	if sf.has("distance"):
		# Every sample of the cell at least the thickness inside the drawn surface.
		var dd: Vector3i = sf.ddims
		var dlo: Vector3i = sf.dlo
		var dist: PackedFloat32Array = sf.distance
		var worst := {}
		for z in dd.z:
			for y in dd.y:
				for x in dd.x:
					var f := dlo + Vector3i(x, y, z)
					var c := Vector3i(floori(f.x / float(k)), floori(f.y / float(k)), floori(f.z / float(k)))
					var v := dist[x + dd.x * (y + dd.y * z)]
					worst[c] = maxf(float(worst.get(c, -INF)), v)
		var counted := {}
		for z in dd.z:
			for y in dd.y:
				for x in dd.x:
					var f := dlo + Vector3i(x, y, z)
					var c := Vector3i(floori(f.x / float(k)), floori(f.y / float(k)), floori(f.z / float(k)))
					counted[c] = int(counted.get(c, 0)) + 1
		for c in worst:
			if int(counted[c]) == k * k * k and float(worst[c]) <= -t:
				core[c] = true
		return core
	var reach := Vector3i(int(ceil(t * k)), int(ceil(t * 2.5 * k)), int(ceil(t * k)))
	var dims: Vector3i = sf.dims
	var lo: Vector3i = sf.lo
	var left: PackedByteArray = _form_mesher("erode", [sf.field, dims, reach])
	if left.is_empty():
		return core
	var cells := {}
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				if left[x + dims.x * (y + dims.y * z)] != 0:
					var f := lo + Vector3i(x, y, z)
					var c := Vector3i(floori(f.x / float(k)), floori(f.y / float(k)), floori(f.z / float(k)))
					cells[c] = int(cells.get(c, 0)) + 1
	var whole := k * k * k
	for c in cells:
		if int(cells[c]) == whole:
			core[c] = true
	return core


## Make (or take away) a part's shell mesh from its sampled form.
func _shell_mesh(part: String, sf: Dictionary) -> void:
	var mi: MeshInstance3D = _shell_nodes.get(part)
	if sf.is_empty() or not shells.has(part):
		if mi != null:
			mi.queue_free()
			_shell_nodes.erase(part)
		_shell_tris.erase(part)
		_shell_joins.erase(part)
		return
	var k: int = sf.k
	var cell := CELL_M / float(k)
	if sf.get("tick", false):
		cell = Vector3.ONE * BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	var st: Dictionary = shells[part]
	var arrays: Array
	var at: Vector3i = sf.lo
	if sf.has("distance"):
		arrays = _form_mesher("surface_sdf", [sf.distance, sf.pins, sf.ddims, cell, SHELL_SMOOTH_EXACT,
				int(st.get("tris", SHELL_TRIS))])
		at = sf.dlo
	else:
		arrays = _form_mesher("surface", [sf.field, sf.dims, cell, SHELL_SMOOTH, shell_blur(k),
				int(st.get("tris", SHELL_TRIS))])
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Shell_" + part
		add_child(mi)
		_shell_nodes[part] = mi
	var m := ArrayMesh.new()
	if not arrays.is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = m
	mi.material_override = shell_material(part)
	mi.transform = world.get_chunk_transform(asm.frames[0]) * Transform3D(Basis(), Vector3(at) * cell)
	_shell_tris[part] = 0 if arrays.is_empty() else (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	_shell_joins[part] = sf.get("joins", {})
	_tris_due = Time.get_ticks_msec() + TRIS_SETTLE_MS


## FormMesher's `method`, through ClassDB: a brick library built before it (an old DLL)
## has no FormMesher, and naming the class would stop this script loading at all. There,
## shells are simply not made (and say so once).
func _form_mesher(method: String, args: Array) -> Variant:
	if not ClassDB.class_exists("FormMesher"):
		if not _warned_mesher:
			_warned_mesher = true
			push_warning("[asset workshop] this brick library has no FormMesher: no shells (rebuild the extension)")
		return PackedByteArray() if method == "erode" else []
	return ClassDB.class_call_static.callv(["FormMesher", method] + args)


var _warned_mesher := false


## A part's shell drawn again from what is saved (after an undo, a load).
func _refresh_shell(part: String) -> void:
	_shell_mesh(part, shell_field(part) if shells.has(part) else {})


## A shell's look: the colour and material it was given, smooth and plain (no brick seams).
func shell_material(part: String) -> StandardMaterial3D:
	var st: Dictionary = shells.get(part, {})
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BrickWorld.get_material_colour(int(st.get("mat", 0)), int(st.get("colour", 0)))
	mat.roughness = 0.55
	return mat


## The bricks of some that a form laid (`part_bricks`), as "arch|cell" keys: inside a
## shell they are covered, and the game and the count leave them out.
func _form_laid(part: String) -> Dictionary:
	var out := {}
	for b in part_bricks.get(part, []):
		out["%s|%s" % [b[0], Vector3i(int(b[1][0]), int(b[1][1]), int(b[1][2]))]] = true
	return out


## Some bricks of a part less those its shell covers. The embedded bricks where it meets
## another part are kept: they are the join.
func _uncovered(part: String, ids: Array) -> Array:
	if not shells.has(part) or not _shell_nodes.has(part):
		return ids
	var laid := _form_laid(part)
	var joins: Dictionary = _shell_joins.get(part, {})
	return ids.filter(func(i: int) -> bool:
		if _brick_frame(i) != 0 or not laid.has("%s|%s" % [recipe.part_of(i), recipe.cell_of(i)]):
			return true
		var c := recipe.cell_of(i)
		var size := BrickPalette.size_of(recipe.part_of(i))
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					if joins.has(c + Vector3i(dx, dy, dz)):
						return true
		return false)


## Lay every part again from its form with `level` slopes and curves (`curve_level`), as
## one undo. Returns how many parts were laid.
func set_curves(level: int) -> int:
	var was := curve_level
	_show_curves(level)
	var n := 0
	_begin_gather()
	for part in part_names:
		if not part_sketches(part).is_empty():
			resketch_part(part, {}, true)
			n += 1
	_end_gather()
	# The level goes back and forth with the bricks.
	if not _edit_groups.is_empty() and _edit_groups.back().get("sketch") is Array:
		(_edit_groups.back().sketch as Array).append({"curves_before": was, "curves_after": curve_level})
	return n


func _show_curves(level: int) -> void:
	curve_level = level
	if _curve_slider != null:
		_curve_slider.set_value_no_signal(curve_level)
		_curve_slider.value_changed.emit(curve_level)
	_store_asset_meta()


var _curve_slider: HSlider
var _shell_check: CheckBox
var _shell_label: Label
var _shell_thick: HSlider
var _shell_res: HSlider
var _shell_budget: HSlider
var _shell_ui_part := -1


## The shell sliders as settings: thickness, detail, triangles.
func _shell_settings() -> Dictionary:
	return {"thick": _shell_thick.value, "res": int(_shell_res.value),
			"tris": int(round(pow(10.0, _shell_budget.value)))}


## The shell controls: the current part's settings when it changes (or `from_part`), and
## the line over the sliders -- thickness, detail and what the shell costs.
func _sync_shell_ui(from_part: bool) -> void:
	if _shell_check == null:
		return
	var part := part_names[part_sel]
	var st: Dictionary = shells.get(part, {})
	if from_part:
		_shell_check.set_pressed_no_signal(not st.is_empty())
		if not st.is_empty():
			_shell_thick.set_value_no_signal(float(st.thick))
			_shell_res.set_value_no_signal(int(st.res))
			_shell_budget.set_value_no_signal(log(float(st.get("tris", SHELL_TRIS))) / log(10.0))
	_shell_label.text = "thickness %.2f studs, detail %d a stud, up to %s triangles%s" % [_shell_thick.value,
			int(_shell_res.value), _thousands(int(round(pow(10.0, _shell_budget.value)))),
			(" (now %s)" % _thousands(int(_shell_tris.get(part, 0)))) if _shell_tris.has(part) else ""]


## The box round every part's form, as `form_pivot` last found it.
var _forms_lo := Vector3i.ZERO
var _forms_hi := -Vector3i.ONE


## Where `scale_form` scales about: the middle of every part's form along and across,
## and its bottom. Notes the box round the forms (`_forms_lo`, `_forms_hi`).
func form_pivot() -> Vector3:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for part in part_names:
		var list := part_sketches(part)
		if list.is_empty() or part_volume(list).is_empty():
			continue
		lo = lo.min(_box[0])
		hi = hi.max(_box[1])
	_forms_lo = lo
	_forms_hi = hi
	if lo.x > hi.x:
		_forms_hi = lo - Vector3i.ONE
		return Vector3.ZERO
	return Vector3((lo.x + hi.x + 1) * 0.5, lo.y, (lo.z + hi.z + 1) * 0.5)


## A sketch scaled by `s` about `pivot` (a cell, as `scale_form`): its outlines and brush
## strokes across and up its plane, its depth and thickness along it, its pockets' depth;
## a shape's centres, size and thickness.
static func scale_sketch(sk: Dictionary, s: float, pivot: Vector3) -> Dictionary:
	var out := sk.duplicate()
	if sk.has("solid"):
		var so: Dictionary = (sk.solid as Dictionary).duplicate()
		so.at = (sk.solid.at as Array).map(func(q: Array) -> Array:
			var c := pivot + (Vector3(float(q[0]), float(q[1]), float(q[2])) - pivot) * s
			return [int(round(c.x)), int(round(c.y)), int(round(c.z))])
		so.size = maxi(1, int(round(float(so.size) * s)))
		so.thick = maxi(1, int(round(float(so.thick) * s)))
		out.solid = so
		return out
	var p := Vector3(pivot.x, pivot.y, pivot.z)   # across, up, along the normal
	match String(sk.plane):
		"front": p = Vector3(pivot.z, pivot.y, pivot.x)
		"top": p = Vector3(pivot.x, pivot.z, pivot.y)
	out.at = p.z + (float(sk.at) - p.z) * s
	out.width = maxi(1, int(round(float(sk.width) * s)))
	out.adds = (sk.adds as Array).map(func(e: Variant) -> Variant: return _scale_entry(e, s, p.x, p.y))
	out.subs = (sk.subs as Array).map(func(e: Variant) -> Variant: return _scale_entry(e, s, p.x, p.y))
	return out


static func _scale_entry(e: Variant, s: float, pu: float, pv: float) -> Variant:
	if e is Dictionary:
		var out: Dictionary = (e as Dictionary).duplicate()
		if out.has("cut"):
			out.cut = _scale_entry(out.cut, s, pu, pv)
			out.deep = maxi(1, int(round(float(out.deep) * s)))
		if out.has("brush"):
			out.brush = _scale_entry(out.brush, s, pu, pv)
			out.rx = float(out.rx) * s
			out.ry = float(out.ry) * s
		return out
	return (e as Array).map(func(q: Array) -> Array:
		return [pu + (float(q[0]) - pu) * s, pv + (float(q[1]) - pv) * s])


static func _shift_entry(e: Variant, du: float, dv: float) -> Variant:
	if e is Dictionary:
		var out: Dictionary = (e as Dictionary).duplicate()
		if out.has("cut"):
			out.cut = _shift_entry(out.cut, du, dv)
		if out.has("brush"):
			out.brush = (out.brush as Array).map(func(q: Array) -> Array: return [float(q[0]) + du, float(q[1]) + dv])
		return out
	return (e as Array).map(func(q: Array) -> Array: return [float(q[0]) + du, float(q[1]) + dv])


## The move tool: press on a part and drag it across the view's plane; let go to put it
## there. Exploded, it moves where it is drawn and where it belongs together.
func _move_input(e: InputEvent) -> bool:
	if tool != "move":
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			var ray := _mouse_ray()
			var hit := _first_hit(ray[0], ray[1])
			if hit.is_empty() or hit.frame != chunk:
				return true
			var rid := _recipe_id_at(0, hit.block)
			if rid < 0:
				return true
			var n := -(_camera.global_transform.basis.z)
			var ax := n.abs()
			var normal := Vector3(signf(n.x), 0, 0) if ax.x >= ax.y and ax.x >= ax.z else (
					Vector3(0, signf(n.y), 0) if ax.y >= ax.z else Vector3(0, 0, signf(n.z)))
			select_part(part_of[rid] if rid < part_of.size() else part_sel)
			_move = {"part": part_names[part_sel], "from": hit.point, "normal": normal, "by": Vector3i.ZERO}
		elif not _move.is_empty():
			move_part(String(_move.part), _move.by)
			_move = {}
		return true
	if e is InputEventMouseMotion and not _move.is_empty():
		var ray := _mouse_ray()
		var pl := Plane(_move.normal, _move.from)
		var at = pl.intersects_ray(ray[0], ray[1])
		if at != null:
			var d: Vector3 = at - _move.from
			_move.by = Vector3i(int(round(d.x / BrickPalette.STUD_M)), int(round(d.y / BrickPalette.PLATE_M)),
					int(round(d.z / BrickPalette.STUD_M)))
		return true
	return false


# ---------------------------------------------------------------------------
# Round 4: the hands, and the gun worked
# ---------------------------------------------------------------------------

## A game metre in the workshop's metres: the gun is real size in the game (the readout's
## "in the game"), a quarter-size model in nano bricks here.
const GAME_PER_WORKSHOP := PRINT_MM_PER_STUD * REAL_PER_PRINT / 1000.0 / BrickPalette.STUD_M
## The play cycle's times, seconds: three shots, then the magazine out and in.
const PLAY_SHOT := 0.4
const PLAY_LENGTH := 4.6
var hands_on := false
var _hand_nodes := [null, null]   # right, left: Node3D, shapes under it by name
var _play := {}                    # the cycle under way: {t}


func set_hands(on: bool) -> void:
	hands_on = on
	if on and _hand_nodes[0] == null:
		for side in 2:
			_hand_nodes[side] = _build_hand(side)
	if _hands_button != null:
		_hands_button.set_pressed_no_signal(on)
	_place_hands()


## The game's own brick hand, the first-person arms' (ViewArms), at the gun's scale here:
## a wrist, a stub of forearm, and the C (or, reaching for a magazine, the pinch).
func _build_hand(side: int) -> Node3D:
	var root := Node3D.new()
	root.name = "HandR" if side == 0 else "HandL"
	var skin := StandardMaterial3D.new()
	skin.albedo_color = ViewArms.SKIN
	skin.roughness = 0.6
	var add := func(m: Mesh, at: Vector3, label: String) -> MeshInstance3D:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.material_override = skin
		mi.position = at
		mi.name = label
		root.add_child(mi)
		return mi
	var wrist := CylinderMesh.new()
	wrist.top_radius = 0.018
	wrist.bottom_radius = 0.018
	wrist.height = 0.03
	add.call(wrist, Vector3(0, 0.015, 0), "Wrist")
	var fore := CylinderMesh.new()
	fore.top_radius = 0.027
	fore.bottom_radius = 0.032
	fore.height = 0.22
	var sleeve: MeshInstance3D = add.call(fore, Vector3(0, -0.11, 0), "Forearm")
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = ViewArms.SLEEVE
	sleeve.material_override = cloth
	add.call(ViewArms.c_mesh(0.019, 0.034, 0.042, deg_to_rad(70.0)), Vector3.ZERO, "C")
	var pinch: MeshInstance3D = add.call(ViewArms.c_mesh(0.009, 0.024, 0.034, deg_to_rad(110.0)), Vector3.ZERO, "PINCH")
	pinch.visible = false
	root.visible = false
	add_child(root)
	return root


func _hand_shape(side: int, shape: String) -> void:
	var h: Node3D = _hand_nodes[side]
	if h == null:
		return
	(h.get_node("C") as Node3D).visible = shape == "C"
	(h.get_node("PINCH") as Node3D).visible = shape == "PINCH"


## Where each hand holds the gun, assembled, in the workshop's metres: the middle of its
## C's hole and its frame (X along the hole, Y to the fingers; ViewArms' hand frame).
## The right hand round the grip, its hole along the grip's length, fingers forward; the
## left round the underbarrel -- or the barrel, or the front of the body -- its hole along
## the gun, fingers up. {right: [hole, Basis], left: ..., grip: part, fore: part}.
func hand_targets() -> Dictionary:
	settle_muzzle()
	var fwd := Vector3(-1 if muzzle_end == "-x" else 1, 0, 0)
	var out := {}
	var grip := _part_cells("grip")
	if grip.is_empty():
		grip = _part_cells("body")
	if not grip.is_empty():
		var c := _centroid(grip)
		var axis := _long_axis(grip, c)
		if axis.y < 0.0:
			axis = -axis
		out["right"] = [c, ViewArms.hand_basis(axis, fwd)]
		out["grip"] = "grip" if not _part_cells("grip").is_empty() else "body"
	for part in ["underbarrel", "barrel", "body"]:
		var cells := _part_cells(part)
		if cells.is_empty():
			continue
		var c := _centroid(cells)
		if part == "body":
			# The front third of the body.
			var lo := INF
			var hi := -INF
			for p in cells:
				lo = minf(lo, p.dot(fwd))
				hi = maxf(hi, p.dot(fwd))
			var front := []
			for p in cells:
				if p.dot(fwd) > lo + (hi - lo) * 0.66:
					front.append(p)
			c = _centroid(front)
		out["left"] = [c, ViewArms.hand_basis(fwd, Vector3.UP)]
		out["fore"] = part
		break
	return out


## The centres of a part's bricks' cells, in metres.
func _part_cells(part: String) -> Array:
	var tag := part_names.find(part)
	var out := []
	if tag < 0:
		return out
	for i in recipe.size():
		if recipe.frame_of(i) != 0 or i >= part_of.size() or part_of[i] != tag:
			continue
		var size := BrickPalette.size_of(recipe.part_of(i))
		var c := recipe.cell_of(i)
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					out.append(Vector3((c.x + dx + 0.5) * BrickPalette.STUD_M, (c.y + dy + 0.5) * BrickPalette.PLATE_M,
							(c.z + dz + 0.5) * BrickPalette.STUD_M))
	return out


static func _centroid(pts: Array) -> Vector3:
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / maxf(1.0, pts.size())


## The way a part runs longest in the side view (along and up the gun).
static func _long_axis(pts: Array, c: Vector3) -> Vector3:
	var xx := 0.0
	var yy := 0.0
	var xy := 0.0
	for p in pts:
		var d: Vector3 = p - c
		xx += d.x * d.x
		yy += d.y * d.y
		xy += d.x * d.y
	var a := 0.5 * atan2(2.0 * xy, xx - yy)
	return Vector3(cos(a), sin(a), 0.0)


## A hand's node put on its target: its frame, scaled to the gun, the wrist back from the
## hole along its fingers, and the extra `move` (the play cycle's) on top.
func _put_hand(side: int, hole: Vector3, b: Basis, move: Transform3D = Transform3D()) -> void:
	var h: Node3D = _hand_nodes[side]
	if h == null:
		return
	var k := 1.0 / GAME_PER_WORKSHOP
	var wrist := hole - b.y * ViewArms.HOLE_Y * k
	h.transform = move * Transform3D(b.scaled(Vector3.ONE * k), wrist)


func _place_hands() -> void:
	for side in 2:
		if _hand_nodes[side] != null:
			(_hand_nodes[side] as Node3D).visible = hands_on
	if not hands_on or not _play.is_empty():
		return
	var t := hand_targets()
	if t.has("right"):
		_put_hand(0, t.right[0] + part_offset(String(t.grip)), t.right[1])
	if t.has("left"):
		_put_hand(1, t.left[0] + part_offset(String(t.fore)), t.left[1])
	_hand_shape(1, "C")


## Play the gun: three shots (the whole gun kicks back and its muzzle rises, about the
## grip), then the left hand goes to the magazine, takes it out and puts it back. The parts
## are baked first -- each laid again on its own (as Explode does) -- so they can move apart.
func play_cycle() -> void:
	if not _play.is_empty():
		return
	set_hands(true)
	_display_dirty = true
	_play = {"t": 0.0, "last": Time.get_ticks_msec()}


func _play_process() -> void:
	if _play.is_empty():
		return
	var now := Time.get_ticks_msec()
	_play.t = float(_play.t) + (now - int(_play.last)) / 1000.0
	_play.last = now
	if float(_play.t) >= PLAY_LENGTH:
		_play = {}
		_display_dirty = true
		if not _drawn_apart():
			_clear_display()
		for name in _display:
			(_display[name].mesh as Node3D).transform = _display[name].xform
		_place_hands()
		return
	play_pose(float(_play.t))


## The cycle at time `t`: each part's mesh and both hands where they are then.
func play_pose(t: float) -> void:
	var targets := hand_targets()
	if not targets.has("right"):
		return
	var fwd := Vector3(-1 if muzzle_end == "-x" else 1, 0, 0)
	var pivot: Vector3 = targets.right[0] + part_offset(String(targets.grip))
	var kick := 0.0
	if t < PLAY_SHOT * 3.0:
		var u := fmod(t, PLAY_SHOT) / PLAY_SHOT
		kick = exp(-u * 9.0) * (1.0 - exp(-u * 60.0))
	# Recoil: back along the gun and the muzzle up, about the grip.
	var rise := Basis(Vector3(0, 0, 1), deg_to_rad(6.0) * kick * signf(fwd.x))
	var recoil := Transform3D(Basis(), pivot) * Transform3D(rise, -fwd * BrickPalette.STUD_M * 0.8 * kick) \
			* Transform3D(Basis(), -pivot)
	# Reload: the left hand to the magazine, the magazine down and out with it, and back.
	var mag_out := 0.0
	var reach := 0.0
	if t > 1.6 and t < 2.2:
		reach = (t - 1.6) / 0.6
	elif t >= 2.2 and t <= 3.8:
		reach = 1.0
	elif t > 3.8 and t < 4.4:
		reach = 1.0 - (t - 3.8) / 0.6
	if t > 2.2 and t < 2.8:
		mag_out = (t - 2.2) / 0.6
	elif t >= 2.8 and t <= 3.2:
		mag_out = 1.0
	elif t > 3.2 and t < 3.8:
		mag_out = 1.0 - (t - 3.2) / 0.6
	mag_out = smoothstep(0.0, 1.0, mag_out)
	reach = smoothstep(0.0, 1.0, reach)
	var mag_move := Vector3.DOWN * BrickPalette.STUD_M * 8.0 * mag_out + fwd * BrickPalette.STUD_M * 1.5 * mag_out
	for name in _display:
		var d: Dictionary = _display[name]
		var x: Transform3D = recoil * (d.xform as Transform3D)
		if name == "magazine":
			x = x.translated(mag_move)
		(d.mesh as Node3D).transform = x
	_put_hand(0, targets.right[0] + part_offset(String(targets.grip)), targets.right[1], recoil)
	if targets.has("left"):
		var hole: Vector3 = targets.left[0] + part_offset(String(targets.fore))
		var b: Basis = targets.left[1]
		if _display.has("magazine") and reach > 0.0:
			var mag: Vector3 = (_display.magazine.centre as Vector3) + mag_move
			hole = hole.lerp(mag, reach)
			b = b.slerp(ViewArms.hand_basis(fwd, Vector3.UP), reach)
		_hand_shape(1, "PINCH" if reach > 0.9 else "C")
		_put_hand(1, hole, b, recoil)


# ---------------------------------------------------------------------------
# Round 5: a sketch's RMB takes up whatever is under it
# ---------------------------------------------------------------------------

## RMB in sketch also takes up every brick under the stroke, not only the sketch's own.
var erase_any := true
## Edits being gathered into one undo (`_begin_gather`): {start, groups}, or empty.
var _gather := {}

## Shells (Docs/AssetWorkshop.md, "Shells"): part -> {thick: studs, res: samples a stud,
## colour, mat}. A shelled part's form is sampled `res` times finer than the grid and
## wrapped in one smooth closed surface; its bricks are the form shrunk by `thick`,
## snapped down to whole cells, and lie inside the shell.
var shells := {}
var _shell_nodes := {}       # part -> MeshInstance3D, in the upright grid
var _shell_tris := {}        # part -> triangles of its shell
var _shell_joins := {}       # part -> its cells against other parts: embedded bricks
var _no_clip := false        # sampling a form finely: shapes are not cut to the build area
var _no_edges := false       # laying a shelled part: no slopes or curves, the shell is the outside
## How many times a shell's surface is smoothed, after its samples are blurred.
const SHELL_SMOOTH := 4
## Laid from the drawn outlines' distances, the surface is already where they are: only a
## touch of smoothing, to even out the sampling.
const SHELL_SMOOTH_EXACT := 1
## A shell's triangles unless set: its surface is decimated to about this many.
const SHELL_TRIS := 1500
## A custom piece from the SDF block-out: finer, its surface is curved all over.
const SDF_PIECE_TRIS := 4000


## How many times a shell's samples are blurred before the surface is laid (FormMesher):
## a staircase of samples becomes the slant it stood for. Fewer at a coarse detail, where
## a blur would round a thin part away.
static func shell_blur(res: int) -> int:
	return 2 if res >= 4 else (1 if res >= 2 else 0)


## The upright-grid bricks under an area of a plane, by recipe index, highest first: right
## through, or with `deep` (studs) only that far in from the face toward the camera.
func bricks_under(area: Dictionary, plane: String, deep: int, from: int) -> Array:
	var axis := 2 if plane == "side" else (0 if plane == "front" else 1)
	var reach := {}   # sketch cell -> [first cell in, last cell in] along the axis
	if deep > 0:
		var n := deep if axis != 1 else int(round(deep * 2.5))
		var dims := Vector3i(plate_studs, height_plates, plate_studs)
		for g in area:
			var ks := range(dims[axis] - 1, -1, -1) if from > 0 else range(dims[axis])
			for k in ks:
				if world.is_solid(chunk, _sketch_cell(g, k, plane)):
					reach[g] = [mini(k, k - (n - 1) * from), maxi(k, k - (n - 1) * from)]
					break
	var out := []
	for i in recipe.size():
		if recipe.frame_of(i) != 0:
			continue
		var cell := recipe.cell_of(i)
		var size := BrickPalette.size_of(recipe.part_of(i))
		var hit := false
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					var c := cell + Vector3i(dx, dy, dz)
					var g := _sketch_grid(c, plane)
					if not area.has(g):
						continue
					if deep <= 0 or (reach.has(g) and c[axis] >= int(reach[g][0]) and c[axis] <= int(reach[g][1])):
						hit = true
		if hit:
			out.append(i)
	return out


## Take these bricks up (recipe indices), as one undo. Returns how many went.
func erase_bricks(ids: Array) -> int:
	var order := ids.duplicate()
	order.sort()
	order.reverse()
	var n := 0
	_batch = true
	for i in order:
		if take_brick(int(i)):
			n += 1
	_batch = false
	_after_edit()
	_group(n)
	return n


## How many cells of bricks have some of themselves between x0 and x1 (studs): for checks.
func _volume_in(x0: int, x1: int) -> int:
	var n := 0
	for i in recipe.size():
		var c := recipe.cell_of(i)
		var size := BrickPalette.size_of(recipe.part_of(i))
		for dx in size.x:
			if c.x + dx >= x0 and c.x + dx < x1:
				n += size.y * size.z
	return n


# ---------------------------------------------------------------------------
# Round 6: the shape brush -- Ctrl + click, in any tool
# ---------------------------------------------------------------------------

## The shape brush's shapes: solid ones round where the ghost is, flat ones lying on the
## plane the ghost is on (E's locked height, the working plane, or a brick top).
const BRUSH_SHAPES := [["ball", "ball"], ["cube", "cube"], ["cylinder", "cylinder (through the plane)"],
		["circle", "circle (flat)"], ["square", "square (flat)"]]
const SHAPE_SIZE_MAX := 24
var brush3d := "ball"
var shape_mode := "drag"     # the Shapes tool: "drag" a box and fill it, or "brush"
var _shape_mode_pick: OptionButton
var _drag_box: VBoxContainer
var shape_size := 4          # studs across (up: two and a half plates a stud)
var shape_thick := 1         # a flat shape's thickness: cells off its plane
var _sb := {}                # a stroke under way: {erase, start (edits), last (centre)}


func _shape_brush_on() -> bool:
	return brushing_shapes() or Input.is_key_pressed(KEY_CTRL) or not _sb.is_empty()


## The Shapes tool set to brush: its clicks lay and carve with no Ctrl.
func brushing_shapes() -> bool:
	return tool == "shape" and shape_mode == "brush"


## The axis a flat shape lies across: the plane the ghost is on. 1 (up) on a brick top or
## the locked height, else the working plane's normal when placing freely on it.
func shape_axis() -> int:
	if not _lock.is_empty() or not free_place:
		return 1
	match work_plane:
		"side": return 2
		"front": return 0
	return 1


## The cells of a shape `size` studs across round `centre` (a cell): even sizes centred
## on its corner, odd ones on its middle, so a shape is exactly that many cells across.
## Up is in plates, two and a half a stud. `axis`: a flat shape's or a cylinder's.
static func brush_shape_cells(kind: String, centre: Vector3i, size: int, axis: int = 1, thick: int = 1) -> Dictionary:
	var dims := Vector3i(size, int(round(size * 2.5)), size)
	var flat := kind in ["circle", "square"]
	if flat:
		dims[axis] = thick
	var half := Vector3(dims) * 0.5
	var c := Vector3(centre) + Vector3(dims.x % 2, dims.y % 2, dims.z % 2) * 0.5
	if flat:
		c[axis] = centre[axis] + thick * 0.5   # from the plane outward
	var lo := Vector3i((c - half).floor())
	var out := {}
	for x in range(lo.x, lo.x + dims.x + 1):
		for y in range(lo.y, lo.y + dims.y + 1):
			for z in range(lo.z, lo.z + dims.z + 1):
				var u := (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5) - c) / half
				if maxf(absf(u.x), maxf(absf(u.y), absf(u.z))) > 1.0 + 1e-6:
					continue
				var inside := true
				match kind:
					"ball":
						inside = u.length_squared() <= 1.0 + 1e-6
					"cylinder", "circle":
						var r := u
						r[axis] = 0.0
						inside = r.length_squared() <= 1.0 + 1e-6
				if inside:
					out[Vector3i(x, y, z)] = true
	return out


## The box round `brush_shape_cells`: [min cell, max cell + 1].
static func brush_shape_box(kind: String, centre: Vector3i, size: int, axis: int = 1, thick: int = 1) -> Array:
	var dims := Vector3i(size, int(round(size * 2.5)), size)
	if kind in ["circle", "square"]:
		dims[axis] = thick
	var c := Vector3(centre) + Vector3(dims.x % 2, dims.y % 2, dims.z % 2) * 0.5
	if kind in ["circle", "square"]:
		c[axis] = centre[axis] + thick * 0.5
	var lo := Vector3i((c - Vector3(dims) * 0.5).round())
	return [lo, lo + dims]


## Lay a shape's cells as bricks of the current part (what is built there stays).
## Returns how many bricks went down.
func shape_place(cells: Dictionary) -> int:
	var free := {}
	for c in cells:
		if c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < plate_studs and c.y < height_plates and c.z < plate_studs:
			free[c] = true
	return fill_cells(free, shape_fill == "random", false)


## Carve a shape out of whatever is built: every brick it touches is taken up and what of
## it lies outside the shape laid again, in its own part, colour and material. Returns
## how many edits that made (bricks taken up and laid), for the undo.
func shape_carve(cells: Dictionary) -> int:
	var rid_of := {}
	for i in _placed_at.size():
		if int(_placed_at[i][0]) == 0:
			rid_of[int(_placed_at[i][1])] = i
	var touched := {}
	for c in cells:
		var b := world.block_at(chunk, c)
		if b >= 0 and rid_of.has(b):
			touched[int(rid_of[b])] = true
	if touched.is_empty():
		return 0
	var left := {}   # [tag, colour, mat] -> cells to lay again
	var ids := touched.keys()
	for i in ids:
		var info := _brick_info(i)
		var size := BrickPalette.size_of(info.arch)
		var what := [int(info.tag), int(info.colour), int(info.mat)]
		for dx in size.x:
			for dy in size.y:
				for dz in size.z:
					var c: Vector3i = info.cell + Vector3i(dx, dy, dz)
					if not cells.has(c) and world.block_at(chunk, c) == int(_placed_at[i][1]) and world.is_solid(chunk, c):
						(left.get_or_add(what, {}) as Dictionary)[c] = true
	ids.sort()
	ids.reverse()
	var n := 0
	_batch = true
	for i in ids:
		if take_brick(int(i)):
			n += 1
	var keep := [part_sel, _colour, _mat]
	for what in left:
		part_sel = int(what[0])
		_colour = int(what[1])
		_mat = int(what[2])
		for pc in pack_cells(left[what], false):
			if place_named(pc[0], pc[1]):
				n += 1
	part_sel = int(keep[0])
	_colour = int(keep[1])
	_mat = int(keep[2])
	_batch = false
	_after_edit()
	return n


## Where a stamp goes: laying, the ghost's cell; carving, the cell of the brick the mouse
## is on (or the ghost's, over nothing).
func _shape_centre(erase: bool) -> Vector3i:
	if erase:
		var ray := _mouse_ray()
		var hit := _first_hit(ray[0], ray[1])
		if not hit.is_empty() and hit.frame == chunk:
			return _cell_in(chunk, (hit.point as Vector3) + (ray[1] as Vector3) * 0.01)
	return _cell


## One stamp of the brush. It goes into the parts' forms, not straight into bricks: laying,
## the current part's; carving, every part whose form it touches -- so the bricks there
## are that part's, worked out again with its sketch, and a part can be laid again from
## its form later (Docs/AssetWorkshop.md, "The form"). Bricks no form laid (laid by hand,
## or a part with no form) are carved as before.
func _stamp_shape(erase: bool) -> void:
	var centre := _shape_centre(erase)
	_sb.last = centre
	var cells := brush_shape_cells(brush3d, centre, shape_size, shape_axis(), shape_thick)
	if not erase:
		form_stamp(part_names[part_sel], centre, false)
		return
	for part in part_names:
		if part_sketches(part).is_empty():
			continue
		if not _part_vol.has(part):
			_part_vol[part] = part_volume(part_sketches(part))
			_part_box[part] = _box.duplicate()
		var vol: Dictionary = _part_vol[part]
		for c in cells:
			if vol.has(c):
				form_stamp(part, centre, true)
				break
	shape_carve(cells)


## Put a stamp of the brush (its shape, size and plane as set now) at `centre` into a
## part's form, and lay the part again. A stroke's stamps in one part are one entry.
func form_stamp(part: String, centre: Vector3i, carve: bool) -> void:
	var keys: Dictionary = _sb.get_or_add("keys", {})
	var key := String(keys.get(part, ""))
	var sk: Dictionary
	if key == "" or not sketches.has(key):
		key = "%s|solid|%d" % [part, _sketch_seq]
		sk = {"part": part, "plane": "solid", "at": 0.0, "width": 0, "adds": [], "subs": [], "n": _sketch_seq,
				"solid": {"kind": brush3d, "size": shape_size, "axis": shape_axis(), "thick": shape_thick,
					"carve": carve, "at": []}}
		_sketch_seq += 1
		keys[part] = key
	else:
		sk = (sketches[key] as Dictionary).duplicate()
		sk.solid = (sk.solid as Dictionary).duplicate()
		sk.solid.at = (sk.solid.at as Array).duplicate()
	sk.solid.at.append([centre.x, centre.y, centre.z])
	resketch(key, sk)


## Edits made from now to `_end_gather` undo as one: a shape stroke's stamps, a resize.
func _begin_gather() -> void:
	_gather = {"start": _edits.size(), "groups": _edit_groups.size()}


## Every edit since `_begin_gather` as one group, the groups made since folded into it
## with every sketch change they held.
func _end_gather() -> void:
	if _gather.is_empty():
		return
	var n := _edits.size() - int(_gather.start)
	var groups_from := int(_gather.groups)
	_gather = {}
	var records := []
	while _edit_groups.size() > groups_from:
		var g: Dictionary = _edit_groups.pop_back()
		var s = g.get("sketch")
		if s is Array:
			var flat: Array = (s as Array).duplicate()
			flat.reverse()
			records.append_array(flat)
		elif s != null:
			records.append(s)
	records.reverse()
	if n > 1 or not records.is_empty():
		var g := {"end": _edits.size(), "n": n}
		if not records.is_empty():
			g["sketch"] = records
		_edit_groups.append(g)


## Ctrl + LMB lays the shape, Ctrl + RMB carves it; held and dragged, it goes on doing
## it every half a shape. One stroke is one undo. Ctrl + wheel sizes it.
func _shape_brush_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.pressed and e.ctrl_pressed \
			and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		shape_size = clampi(shape_size + (1 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -1), 1, SHAPE_SIZE_MAX)
		return true
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if e.pressed and (e.ctrl_pressed or brushing_shapes()) and _sb.is_empty():
			_sb = {"erase": e.button_index == MOUSE_BUTTON_RIGHT, "start": _edits.size(), "last": _cell,
					"button": e.button_index}
			_begin_gather()
			_stamp_shape(bool(_sb.erase))
			return true
		if not e.pressed and not _sb.is_empty() and e.button_index == int(_sb.button):
			_end_gather()
			_sb = {}
			return true
	if e is InputEventMouseMotion and not _sb.is_empty():
		var at := _shape_centre(bool(_sb.erase))
		if Vector3(at - (_sb.last as Vector3i)).length() >= maxf(1.0, shape_size * 0.5):
			_stamp_shape(bool(_sb.erase))
		return true
	return false


## The shape brush where it would go: its box, and its round outline across the plane.
func _draw_shape_brush(im: ImmediateMesh) -> void:
	var erase: bool = bool(_sb.get("erase", Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)))
	# Its box worked out, not its cells: this is drawn every frame Ctrl is down.
	var box := brush_shape_box(brush3d, _shape_centre(erase), shape_size, shape_axis(), shape_thick)
	var lo: Vector3i = box[0]
	var hi: Vector3i = box[1]
	var cell := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
	var a := Vector3(lo) * cell
	var b := Vector3(hi) * cell
	var col := Color(1.0, 0.35, 0.3) if erase else Color(0.4, 1.0, 0.55)
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	_box_lines(im, a, b, col)
	if brush3d in ["ball", "cylinder", "circle"]:
		var mid := (a + b) * 0.5
		var r := (b - a) * 0.5
		var axes := [0, 1, 2] if brush3d == "ball" else [shape_axis()]
		for ax in axes:
			var u := Vector3.ZERO
			var v := Vector3.ZERO
			var ua: int = (int(ax) + 1) % 3
			var va: int = (int(ax) + 2) % 3
			u[ua] = r[ua]
			v[va] = r[va]
			for i in 32:
				for t in [TAU * i / 32.0, TAU * (i + 1) / 32.0]:
					im.surface_set_color(col)
					im.surface_add_vertex(mid + u * cos(t) + v * sin(t))
	im.surface_end()


## Enter (and the building workshop's "Test in city"): a gun is not a building to stand in
## the city. Its way out is Export (F12).
func _place_in_city() -> void:
	print("[asset workshop] a gun does not go in the city: F12 exports its parts")


# ---------------------------------------------------------------------------
# Out to the game: each part a scene the game's GunAssembler puts together
# ---------------------------------------------------------------------------

## Which part each part attaches to (its socket is there): the barrel to the body, the
## muzzle and underbarrel to the barrel (or the body without one), the rest to the body.
const GAME_HOST := {"barrel": "body", "stock": "body", "grip": "body", "magazine": "body",
		"sight": "body", "muzzle": "barrel", "underbarrel": "barrel"}


## Where this gun's game parts go: a folder beside its file (user://guns/thompson/).
func game_dir() -> String:
	var base := _current_path
	if base == "":
		base = BuildRecipe.player_dir(recipe.kind) + slug(recipe.name if recipe.name != "untitled" else "gun") + ".json"
	return base.get_basename() + "/"


## The workshop's frame to the game's: the gun real size (a game metre is the gun's
## real metre, GAME_PER_WORKSHOP), its muzzle along -Z, up up; across the gun is X.
func game_basis() -> Basis:
	var turn := -PI * 0.5 if muzzle_end == "-x" else PI * 0.5
	return Basis(Vector3.UP, turn).scaled(Vector3.ONE * GAME_PER_WORKSHOP)


## Export the gun for the game: each part (of the gun's slots) as a scene of its own --
## its bricks and studs, in their colours, real size, muzzle along -Z -- with the
## game's assembly nodes: a `mount` on each part but the body, and on the part it
## attaches to a `socket_<slot>` at the same point, so GunAssembler puts it back exactly
## where it was built. The point is the part's connection point (a mount) if it has
## one, else the middle of its bricks -- which is also where the game's hands take the
## grip, the magazine and the barrel. The barrel (or whatever is foremost) carries a
## `socket_muzzle` at its tip. Writes <dir>/<part>.scn and <dir>/gun.json.
## Returns {ok, dir, parts, length_m} or {ok: false, why}.
func export_game(dir: String = "") -> Dictionary:
	if dir == "":
		dir = game_dir()
	settle_muzzle()
	var by_part := _gun_bricks()
	if not by_part.has("body"):
		print("[asset workshop] export to game: the gun needs a body")
		return {"ok": false, "why": "no body"}
	var fwd := Vector3(-1 if muzzle_end == "-x" else 1, 0, 0)
	var at := _part_points(by_part)
	var host := _game_hosts(by_part)
	# The muzzle socket: on the muzzle part's tip, else the barrel's, else the body's.
	var front := "muzzle" if by_part.has("muzzle") else ("barrel" if by_part.has("barrel") else "body")
	var b := game_basis()
	DirAccess.make_dir_recursive_absolute(dir)
	var written := {}
	for name in by_part:
		var root := Node3D.new()
		root.name = name
		var model := Node3D.new()
		model.name = "Model"
		model.transform = Transform3D(b, -(b * (at[name] as Vector3)))
		root.add_child(model)
		# A mesh a frame the part has bricks in: sideways bricks are in grids of their own.
		var groups := _by_frame(_uncovered(name, by_part[name]))
		for af in groups:
			var mi := _bake_part_mesh(groups[af], af)
			if af != groups.keys()[0]:
				mi.name = "Bricks%d" % af
			model.add_child(mi)
		if _shell_nodes.has(name):
			# The shell, in the workshop metres the bricks are in; the bricks it covers left out.
			var sh := MeshInstance3D.new()
			sh.name = "Shell"
			var src: MeshInstance3D = _shell_nodes[name]
			sh.mesh = src.mesh
			sh.material_override = src.material_override
			sh.transform = world.get_chunk_transform(asm.frames[0]).affine_inverse() * src.transform
			model.add_child(sh)
		var extra := extra_studs.filter(func(st: Dictionary) -> bool: return String(st.get("part", "")) == name)
		if not extra.is_empty():
			model.add_child(_studs_node(extra))
		if name != "body":
			var mount := Node3D.new()
			mount.name = "mount"
			root.add_child(mount)
		for child in host:
			if host[child] == name:
				_game_node(root, "socket_" + String(child), b * ((at[child] as Vector3) - (at[name] as Vector3)))
		if name == front:
			_game_node(root, "socket_muzzle", b * (_tip(by_part[name], fwd) - (at[name] as Vector3)))
		_own(root, root)
		var ps := PackedScene.new()
		var err := ps.pack(root)
		root.free()
		var path: String = dir + name + ".scn"
		if err == OK:
			err = ResourceSaver.save(ps, path)
		if err != OK:
			print("[asset workshop] export to game: %s failed (%s)" % [name, error_string(err)])
			return {"ok": false, "why": "%s: %s" % [name, error_string(err)]}
		written[name] = path
	# How long it is in the game, muzzle to butt.
	var lo := INF
	var hi := -INF
	for name in by_part:
		for i in by_part[name]:
			var box := _brick_box(i)
			lo = minf(lo, box.position.x)
			hi = maxf(hi, box.end.x)
	var length := (hi - lo) * GAME_PER_WORKSHOP
	var manifest := {"name": recipe.name, "source": _current_path, "parts": written,
			"hosts": host, "length_m": snappedf(length, 0.001)}
	var f := FileAccess.open(dir + "gun.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("[asset workshop] exported %d parts to %s, %.2f m long in the game" % [written.size(),
			ProjectSettings.globalize_path(dir), length])
	return {"ok": true, "dir": dir, "parts": written, "length_m": length}


## Each gun part's bricks, by recipe index: {part name: [index ...]}.
func _gun_bricks() -> Dictionary:
	var by_part := {}
	for i in recipe.size():
		if _brick_frame(i) < 0:
			continue
		var name := part_names[part_of[i] if i < part_of.size() else part_sel]
		if GUN_PARTS.has(name):
			(by_part.get_or_add(name, []) as Array).append(i)
	return by_part


## The part each part hangs from in the game: GAME_HOST's, or the body when that is missing.
static func _game_hosts(by_part: Dictionary) -> Dictionary:
	var host := {}
	for name in by_part:
		if name == "body":
			continue
		var h: String = GAME_HOST.get(name, "body")
		host[name] = h if by_part.has(h) else "body"
	return host


# ---------------------------------------------------------------------------
# Trying catalogue parts on (Docs/ModularParts.md section 9)
# ---------------------------------------------------------------------------

## Parts from the catalogue (F7) tried on this build: {slot: PartRecord}. Any part of a
## held gun goes on its own slot, fitting or not: it is drawn from its saved game scene,
## its mount on this build's socket for it, and this build's own part of that slot is
## hidden meanwhile. A tried body brings its sockets: this build's other parts are drawn
## on them. Never saved, never exported: a tried part is already saved on its own, and
## Save writes only this build's own parts.
var tried := {}
## Why each part does not fit what it hangs from, with tried parts on: {slot: reason};
## "" fits.
var fit_marks := {}
var _tried_packed := {}       # slot -> PackedScene
var _tried_nodes := {}        # slot -> its scene, drawn
var _tried_root: Node3D
## Where each part sits with tried parts on, in the build's metres: {slot: Vector3}.
var _try_place := {}


## Try catalogue part `r` on its slot. "" when it is on, else why it cannot be: not a held
## gun's part, no scene, or this is not a gun build. Trying this build's own saved part
## of a slot takes off what was tried there.
func try_part(r: PartRecord) -> String:
	if recipe.kind != "gun":
		return "parts are tried on a gun build"
	if r.family != "gun" or r.scale != "held" or not GUN_PARTS.has(r.slot):
		return "%s is not a part of a held gun" % r.id
	if String(part_ids.get(r.slot, "")) == r.id:
		untry(r.slot)
		return ""
	var ps: PackedScene = null
	if r.dir != "":
		ps = ResourceLoader.load(r.dir + AssetGuns.PART_SCENE) as PackedScene
	if ps == null:
		return "%s has no scene" % r.id
	tried[r.slot] = r
	_tried_packed[r.slot] = ps
	_try_changed()
	return ""


func untry(slot: String) -> void:
	if tried.erase(slot):
		_tried_packed.erase(slot)
		_try_changed()


func untry_all() -> void:
	tried.clear()
	_tried_packed.clear()
	_try_changed()


func _try_changed() -> void:
	_display_dirty = true
	if _drawn_apart():
		_rebuild_display()   # draws the tried parts too
	else:
		_clear_display()
		_offsets.clear()
		fit_marks.clear()
		_draw_tried()
		_draw_studs()
		_draw_points()
	_outlines_dirty = true
	_export_check = try_text()
	if _catalog_panel != null and _catalog_panel.visible:
		_aim_catalog(_catalog_panel.catalog)


## What is tried on, and what does not fit: the status line.
func try_text() -> String:
	if tried.is_empty():
		return ""
	var bad := PackedStringArray()
	for slot in fit_marks:
		if fit_marks[slot] != "":
			bad.append("%s: %s" % [slot, fit_marks[slot]])
	var on := PackedStringArray()
	for slot in tried:
		on.append("%s %s" % [slot, (tried[slot] as PartRecord).display_name])
	return "trying %s -- %s" % [", ".join(on), "all fit" if bad.is_empty() else "; ".join(bad)]


## The part `slot` hangs from: its game host (GAME_HOST), own or tried, else the body.
func _try_host(slot: String, by_part: Dictionary) -> String:
	var h: String = GAME_HOST.get(slot, "body")
	return h if by_part.has(h) or tried.has(h) else "body"


## Each own part's draw offset with tried parts on: where a tried host's socket puts it,
## against where it was built. Fills _try_place and fit_marks.
func _try_offsets() -> Dictionary:
	var by_part := _gun_bricks()
	var at := _part_points(by_part)
	var b_inv := game_basis().inverse()
	var offset := {}
	_try_place.clear()
	_make_tried_nodes()
	for slot: String in GUN_PARTS:
		var own := by_part.has(slot)
		if not own and not tried.has(slot):
			continue
		var h := _try_host(slot, by_part)
		if slot == "body" or not _try_place.has(h):
			_try_place[slot] = at.get(slot, Vector3.ZERO)
			offset[slot] = Vector3.ZERO
			continue
		var p: Vector3
		if tried.has(h):
			# On the tried host's own socket for it: where its own build had that part.
			var sock := (_tried_nodes[h] as Node3D).get_node_or_null("socket_" + slot) as Node3D
			p = (_try_place[h] as Vector3) + (b_inv * sock.position if sock != null else Vector3.ZERO)
		else:
			var built: Vector3 = at[slot] if own else _socket_point(h, slot, by_part, at)
			p = built + (offset[h] as Vector3)
		_try_place[slot] = p
		offset[slot] = p - (at[slot] as Vector3) if own else Vector3.ZERO
	_check_fit(by_part)
	return offset


## Where this build's own `host` takes a `slot` part it does not have: its socket point
## for it, the tip for a muzzle, else the host's point.
func _socket_point(host: String, slot: String, by_part: Dictionary, at: Dictionary) -> Vector3:
	for q in points:
		if String(q.part) == host and q.kind == "socket" and String(q.slot) == slot:
			return _point_m(q)
	if slot == "muzzle" and by_part.has(host):
		return _tip(by_part[host], Vector3(-1 if muzzle_end == "-x" else 1, 0, 0))
	return at.get(host, Vector3.ZERO)


## Every part against what it hangs from, tried or own, by the game's rule: parts that
## both say their interfaces join on a shared one (PartFit, layer 1); parts that say none
## join by slot (GunPartDef.takes).
func _check_fit(by_part: Dictionary) -> void:
	fit_marks.clear()
	var hosts := _game_hosts(by_part)
	var recs := {}
	for slot: String in GUN_PARTS:
		if tried.has(slot):
			recs[slot] = tried[slot]
		elif by_part.has(slot):
			recs[slot] = _part_record(slot, by_part, hosts, false)
	var sockets: Dictionary = PartStandards.plan("gun").get("sockets", {})
	for slot: String in recs:
		if slot == "body":
			continue
		var h := _try_host(slot, by_part)
		if not recs.has(h):
			fit_marks[slot] = "nothing to hang from"
			continue
		var path := slot if sockets.has(slot) else "barrel/" + slot
		fit_marks[slot] = fit_reason(recs[slot], recs[h], path)


## Why `part` does not go on `host` at `path` ("" when it does), as the game decides.
static func fit_reason(part: PartRecord, host: PartRecord, path: String) -> String:
	if not _declares(part) and not _declares(host):
		return ""   # both from before interfaces: they join by slot
	return PartFit.why_not(part, host, path, "gun")


static func _declares(r: PartRecord) -> bool:
	if r.interface() != "":
		return true
	for sk: Dictionary in r.sockets:
		if not (sk.get("accepts", []) as Array).is_empty():
			return true
	return false


## The draw offsets: exploded, plus where tried hosts' sockets put this build's parts.
func _drawn_offsets() -> Dictionary:
	var out: Dictionary = explode_offsets() if exploded else {}
	if tried.is_empty():
		fit_marks.clear()
		return out
	var t := _try_offsets()
	for slot in t:
		out[slot] = (out.get(slot, Vector3.ZERO) as Vector3) + (t[slot] as Vector3)
	return out


func _make_tried_nodes() -> void:
	for slot in _tried_nodes.keys():
		if not tried.has(slot) or (_tried_nodes[slot] as Node3D).get_meta(&"part_id", "") != (tried[slot] as PartRecord).id:
			_tried_root.remove_child(_tried_nodes[slot])
			(_tried_nodes[slot] as Node).queue_free()
			_tried_nodes.erase(slot)
	if _tried_root == null:
		_tried_root = Node3D.new()
		_tried_root.name = "Tried"
		add_child(_tried_root)
	for slot in tried:
		if _tried_nodes.has(slot):
			continue
		var n := (_tried_packed[slot] as PackedScene).instantiate() as Node3D
		n.set_meta(&"part_id", (tried[slot] as PartRecord).id)
		_tried_root.add_child(n)
		_tried_nodes[slot] = n


## The tried parts where their sockets put them, and a mark on every part that does not
## fit, saying why (and on every tried part that does).
func _draw_tried() -> void:
	if _tried_root != null:
		for c in _tried_root.get_children():
			if c is Label3D:
				_tried_root.remove_child(c)
				c.queue_free()
	if tried.is_empty():
		for slot in _tried_nodes:
			_tried_root.remove_child(_tried_nodes[slot])
			(_tried_nodes[slot] as Node).queue_free()
		_tried_nodes.clear()
		return
	_make_tried_nodes()
	_tried_root.transform = world.get_chunk_transform(chunk)
	var xo: Dictionary = explode_offsets() if exploded else {}
	var b_inv := game_basis().inverse()
	for slot in _tried_nodes:
		(_tried_nodes[slot] as Node3D).transform = Transform3D(b_inv,
				(_try_place.get(slot, Vector3.ZERO) as Vector3) + (xo.get(slot, Vector3.ZERO) as Vector3))
	for slot in fit_marks:
		var ok: bool = fit_marks[slot] == ""
		if ok and not tried.has(slot):
			continue
		var mark := Label3D.new()
		mark.name = "Mark_" + slot
		mark.text = ("%s fits" % slot) if ok else ("%s does not fit:\n%s" % [slot, fit_marks[slot]])
		mark.modulate = Color(0.4, 1.0, 0.5) if ok else Color(1.0, 0.35, 0.3)
		mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		mark.no_depth_test = true
		mark.font_size = 40
		mark.pixel_size = 0.004
		mark.outline_size = 8
		mark.position = (_try_place.get(slot, Vector3.ZERO) as Vector3) \
				+ (xo.get(slot, Vector3.ZERO) as Vector3) + Vector3.UP * 0.4
		_tried_root.add_child(mark)


# ---------------------------------------------------------------------------
# Save: every part on its own (Docs/ModularParts.md section 7)
# ---------------------------------------------------------------------------

## Each part's id, made on its first save and kept: {part name: id}. In meta.asset.
var part_ids := {}
## What each part was when last saved, to tell whether a save changes it: {name: md5}.
var part_hashes := {}
## Each part's rev: {name: rev}.
var part_revs := {}
## Who makes the parts saved here: a name until there is a Steam one (ModularParts stage 10).
var creator_name := "player"


## A new build, or the same bricks saved as another: new parts, not new revs of the old.
func _forget_part_ids() -> void:
	part_ids = {}
	part_hashes = {}
	part_revs = {}


## Where this build's parts go: the shipped catalogue for a shipped build (written only
## from the editor), the player's custom folder otherwise, a test's own folder in a test.
func parts_dir() -> String:
	if _builds_dir != BuildRecipe.player_dir():
		return _builds_dir + "parts/"
	if _current_path.begins_with("res://"):
		return PartCatalog.OFFICIAL_DIR + "gun/"
	return PartCatalog.CUSTOM_DIR


## File > Save As under another name makes new parts; the old ones stay as they were.
func _save_as(build_name: String, room_kind: String = "", tags: Dictionary = {}) -> String:
	if build_name != recipe.name:
		_forget_part_ids()
	return super._save_as(build_name, room_kind, tags)


## File > Save writes the build (the workshop's own file, to open here again: the game
## never reads it) and then every part of it on its own (save_parts).
func _write(path: String) -> bool:
	if not super._write(path):
		return false
	if recipe.kind == "gun":
		save_parts()
	return true


## Every gun part as a part record and its game scene, each in its own folder:
## <dir>/<id>/part.json and part.scn. A part unchanged since its last save is not written
## again. Returns {ok, written: [id ...], kept: [id ...]} or {ok: false, why}.
func save_parts(dir: String = "") -> Dictionary:
	if dir == "":
		dir = parts_dir()
	var by_part := _gun_bricks()
	if not by_part.has("body"):
		return {"ok": false, "why": "no body"}
	# The scenes as Export to game makes them, into a staging folder, each then moved into
	# its part's folder. Staging has no part.json, so the catalogue never reads it.
	var staging := dir + ".staging/"
	var out := export_game(staging)
	if not out.get("ok", false):
		return out
	var official := dir.begins_with("res://")
	var hosts := _game_hosts(by_part)
	var written := []
	var kept := []
	for name: String in by_part:
		if not part_ids.has(name):
			part_ids[name] = ("%s_%s" % [slug(recipe.name), name]) if official else ("%s.%s_%s.%s" % [
					slug(creator_name), slug(recipe.name), name, _short_hash()])
		var r := _part_record(name, by_part, hosts, official)
		# The scene too: shells, hand-put studs and where the parts on it sit change it
		# without changing a brick of its own.
		var sig := (_part_signature(r) + scene_signature(staging + name + ".scn")).md5_text()
		var folder := dir + String(part_ids[name]) + "/"
		if part_hashes.get(name, "") == sig and FileAccess.file_exists(folder + PartCatalog.FILE):
			kept.append(r.id)
			continue
		if part_hashes.has(name):
			part_revs[name] = int(part_revs.get(name, 1)) + 1
		r.rev = int(part_revs.get(name, 1))
		part_revs[name] = r.rev
		r.saved = int(Time.get_unix_time_from_system())
		DirAccess.make_dir_recursive_absolute(folder)
		DirAccess.remove_absolute(folder + "part.scn")
		var err := DirAccess.rename_absolute(staging + name + ".scn", folder + "part.scn")
		if err == OK:
			err = r.save_file(folder + PartCatalog.FILE)
		if err != OK:
			return {"ok": false, "why": "%s: %s" % [name, error_string(err)]}
		part_hashes[name] = sig
		written.append(r.id)
	for f in DirAccess.get_files_at(staging):
		DirAccess.remove_absolute(staging + f)
	DirAccess.remove_absolute(staging)
	_store_asset_meta()
	print("[asset workshop] saved %d part(s) to %s, %d unchanged" % [written.size(),
			ProjectSettings.globalize_path(dir), kept.size()])
	return {"ok": true, "written": written, "kept": kept}


## A part's record: what it is, what it mounts with and what its sockets take (its J
## points), its bricks, and the build it was last saved from (`from`: where it came from,
## never a gun -- the game only makes guns of parts that fit).
func _part_record(name: String, by_part: Dictionary, hosts: Dictionary, official: bool) -> PartRecord:
	var r := PartRecord.new()
	r.id = String(part_ids.get(name, "unsaved." + name))   # unsaved: a fit check before a save
	r.family = "gun"
	r.scale = "held"
	r.slot = name
	r.display_name = "%s %s" % [recipe.name, name]
	r.manufacturer = String(AssetGuns.BRAND)
	r.source = "official" if official else "custom"
	if not official:
		r.creator = {"name": creator_name}
	if name == "body":
		r.weapon_class = gun_class
		r.name_fragment = recipe.name
	if name == "magazine":
		r.tags = PackedStringArray(["detaches"])   # PlayerView takes it out on a reload
	for q in points:
		if String(q.part) == name and q.kind == "mount" and String(q.interface) != "":
			r.mount = {"interface": String(q.interface)}
	var accepts := {}
	for child in hosts:
		if hosts[child] == name:
			accepts[child] = []
	for q in points:
		if String(q.part) == name and q.kind == "socket" and String(q.interface) != "":
			(accepts.get_or_add(String(q.slot), []) as Array).append(String(q.interface))
	for k in accepts:
		r.sockets.append({"name": k, "accepts": accepts[k]})
	r.extra["from"] = recipe.name
	r.extra["bricks"] = _part_recipe(by_part[name]).to_dict()
	return r


## The bricks `ids` as a recipe of their own, in the build's frames.
func _part_recipe(ids: Array) -> BuildRecipe:
	var out := BuildRecipe.new()
	out.name = recipe.name
	out.kind = "gun"
	for f in range(1, recipe.frame_count()):
		out.add_frame(recipe.frame_rotation(f), recipe.frame_ticks(f))
	for i: int in ids:
		out.add(recipe.part_of(i), recipe.cell_of(i), recipe.colour_of(i), recipe.frame_of(i),
				recipe.role_of(i), recipe.material_of(i))
	return out


## What decides whether a save changes a part: everything but its rev and time.
static func _part_signature(r: PartRecord) -> String:
	var d := r.to_dict()
	d.erase("rev")
	d.erase("saved")
	return JSON.stringify(d).md5_text()


## What a saved scene holds, as a hash: every node's name and place, every mesh's
## vertices and colours, every material's colour. The file itself is no good for this:
## the same scene saved twice is not the same bytes.
static func scene_signature(path: String) -> String:
	var ps := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if ps == null:
		return ""
	var top := ps.instantiate()
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	var nodes: Array[Node] = [top]
	nodes.append_array(top.find_children("*", "", true, false))
	for n in nodes:
		h.update(String(top.get_path_to(n)).to_utf8_buffer())
		if n is Node3D:
			h.update(var_to_bytes((n as Node3D).transform))
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mesh := (n as MeshInstance3D).mesh
			for i in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(i)
				h.update(var_to_bytes(arrays[Mesh.ARRAY_VERTEX]))
				if arrays[Mesh.ARRAY_COLOR] != null:
					h.update(var_to_bytes(arrays[Mesh.ARRAY_COLOR]))
			var mat := (n as MeshInstance3D).material_override as BaseMaterial3D
			if mat != null:
				h.update(var_to_bytes(mat.albedo_color))
	top.free()
	return h.finish().hex_encode()


static func _short_hash() -> String:
	return ("%d%d" % [Time.get_ticks_usec(), randi()]).md5_text().substr(0, 8)


## The middle of some bricks' cells, workshop metres (sideways ones too).
func _cells_centre(ids: Array) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for i in ids:
		for p in _cell_points(i):
			sum += p
			n += 1
	return sum / maxf(1.0, n)


## The foremost face of some bricks, at the middle of what is there: where a shot leaves.
func _tip(ids: Array, fwd: Vector3) -> Vector3:
	var best := -INF
	var cells := []
	for i in ids:
		for p: Vector3 in _cell_points(i):
			var d := p.dot(fwd)
			if d > best + 1e-4:
				best = d
				cells = [p]
			elif absf(d - best) <= 1e-4:
				cells.append(p)
	var mid := Vector3.ZERO
	for p in cells:
		mid += p
	mid /= maxf(1.0, cells.size())
	return mid + fwd * BrickPalette.STUD_M * 0.5


## A part's shell for the print sheet: {verts: [[along, across, up] mm ...], tris: [i ...]}.
## The kit makes it the part's solid (its winding is put right there: the gun's frame is
## the workshop's mirrored).
func _shell_sheet(part: String, along: Callable, across: Callable, up: Callable) -> Dictionary:
	var mi: MeshInstance3D = _shell_nodes[part]
	var a: Array = mi.mesh.surface_get_arrays(0)
	var xf: Transform3D = world.get_chunk_transform(asm.frames[0]).affine_inverse() * mi.transform
	var verts := []
	for p: Vector3 in a[Mesh.ARRAY_VERTEX]:
		var w := xf * p
		verts.append([snappedf(along.call(w.x / BrickPalette.STUD_M), 0.001), snappedf(across.call(w.z / BrickPalette.STUD_M), 0.001),
				snappedf(up.call(w.y / BrickPalette.PLATE_M), 0.001)])
	return {"verts": verts, "tris": Array(a[Mesh.ARRAY_INDEX] as PackedInt32Array)}


## A sideways brick for the print sheet: its middle in the gun's frame (mm: along, across,
## up), `turn` -- where its own grid's x, y and z point in the gun's frame -- and its size
## as an upright brick's (studs, studs, plates). The kit lays it as a solid of its own, off
## the upright grid's cells. A plain brick's studs (those with nothing of its grid on them)
## go into the part's hand studs, which the kit already lays; a shaped piece's come from
## its catalogue profile, turned.
func _turned_brick(i: int, along: Callable, across: Callable, up: Callable, spec: Dictionary) -> Dictionary:
	var af := _brick_frame(i)
	var rel := _frame_rel(af)
	var arch := String(recipe.part_of(i))
	var size := BrickPalette.size_of(arch)
	var c := recipe.cell_of(i)
	var gun := func(p: Vector3) -> Array:
		return [snappedf(along.call(p.x / BrickPalette.STUD_M), 0.001), snappedf(across.call(p.z / BrickPalette.STUD_M), 0.001),
				snappedf(up.call(p.y / BrickPalette.PLATE_M), 0.001)]
	var sign := 1.0 if muzzle_end == "-x" else -1.0
	var dir := func(v: Vector3) -> Array:
		var d := rel.basis * v
		return [snappedf(d.x * sign, 0.0001), snappedf(d.z, 0.0001), snappedf(d.y, 0.0001)]
	var centre := rel * ((Vector3(c) + Vector3(size) * 0.5) * CELL_M)
	if arch.begins_with("brick_") or arch.begins_with("plate_"):
		var f: int = asm.frames[af]
		for dx in size.x:
			for dz in size.z:
				if world.is_solid(f, c + Vector3i(dx, size.y, dz)):
					continue
				var foot := rel * ((Vector3(c.x + dx + 0.5, c.y + size.y, c.z + dz + 0.5)) * CELL_M)
				(spec.get_or_add("studs_extra", []) as Array).append({"at": gun.call(foot), "normal": dir.call(Vector3.UP)})
	return {"part": arch, "centre_mm": gun.call(centre), "size": [size.x, size.z, size.y],
			"turn": [dir.call(Vector3.RIGHT), dir.call(Vector3.UP), dir.call(Vector3.BACK)]}


## The frame of the workshop a brick is laid in (`asm.frames` index: 0 upright, else a
## sideways grid), or -1 for a brick in a frame this workshop has no grid for.
func _brick_frame(i: int) -> int:
	return int(_placed_at[i][0]) if i < _placed_at.size() else -1


## A frame's grid in the upright one's: frame-local metres to the workshop metres every
## export works in.
func _frame_rel(af: int) -> Transform3D:
	if af <= 0:
		return Transform3D.IDENTITY
	return world.get_chunk_transform(asm.frames[0]).affine_inverse() * world.get_chunk_transform(asm.frames[af])


## Some bricks by the frame they are laid in, the upright one first: frame -> ids.
func _by_frame(ids: Array) -> Dictionary:
	var out := {}
	var frames := []
	for i in ids:
		var af := _brick_frame(i)
		if af < 0:
			continue
		if not out.has(af):
			frames.append(af)
			out[af] = []
		(out[af] as Array).append(i)
	frames.sort()
	var sorted := {}
	for af in frames:
		sorted[af] = out[af]
	return sorted


const CELL_M := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)


## The middles of a brick's cells, in workshop metres, whichever grid it is laid in.
func _cell_points(i: int) -> Array:
	var rel := _frame_rel(_brick_frame(i))
	var c := recipe.cell_of(i)
	var size := BrickPalette.size_of(recipe.part_of(i))
	var out := []
	for dx in size.x:
		for dy in size.y:
			for dz in size.z:
				out.append(rel * ((Vector3(c + Vector3i(dx, dy, dz)) + Vector3(0.5, 0.5, 0.5)) * CELL_M))
	return out


## A brick's box in workshop metres, whichever grid it is laid in.
func _brick_box(i: int) -> AABB:
	var c := recipe.cell_of(i)
	var size := BrickPalette.size_of(recipe.part_of(i))
	return _frame_rel(_brick_frame(i)) * AABB(Vector3(c) * CELL_M, Vector3(size) * CELL_M)


## Some bricks laid on their own in a chunk of their own: [chunk, the cell of its corner].
## The bricks are all of one frame; their cells are that frame's. The caller releases it.
func _part_chunk(ids: Array) -> Array:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for i in ids:
		lo = lo.min(recipe.cell_of(i))
		hi = hi.max(recipe.cell_of(i) + BrickPalette.size_of(recipe.part_of(i)))
	var c := world.create_chunk(Vector3i.ZERO, hi - lo)
	for i in ids:
		var arch := String(recipe.part_of(i))
		if not palette.has(arch):
			continue
		var bid := world.place_block(c, recipe.cell_of(i) - lo, palette[arch], recipe.colour_of(i))
		if bid >= 0 and recipe.material_of(i) != 0:
			world.set_block_material(c, bid, recipe.material_of(i))
	return [c, lo]


## Some bricks laid on their own and meshed for the game, studs and all: a MeshInstance3D
## in workshop metres (its studs a child), at their box's corner. No chamfer: at a held
## gun's size it is too small to see and cost 18% of the Thompson's triangles; the shader
## draws the brick outlines and its own bevel (geo_bevel 0).
## `af`: the frame they are laid in -- the mesh is placed where that grid is.
func _bake_part_mesh(ids: Array, af: int = 0) -> MeshInstance3D:
	var made := _part_chunk(ids)
	var c: int = made[0]
	var lo: Vector3i = made[1]
	var mi := MeshInstance3D.new()
	mi.name = "Bricks"
	mi.material_override = _material
	var arrays := world.build_chunk_mesh(c)
	var m := ArrayMesh.new()
	if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = m
	mi.set_instance_shader_parameter("geo_bevel", 0.0)
	mi.transform = _frame_rel(af) * Transform3D(Basis(), Vector3(lo) * CELL_M)
	var studs: PackedFloat32Array = world.get_chunk_studs(c)
	@warning_ignore("integer_division")
	var count := studs.size() / 16
	if count > 0:
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Studs"
		mmi.material_override = _stud_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = PieceMeshes.stud()
		mm.instance_count = count
		mm.set_buffer(studs)
		mmi.multimesh = mm
		mi.add_child(mmi)
	world.release_chunk(c)
	return mi


## What the gun costs to draw, as Export to game meshes it: each part's triangles (its
## bricks, and its studs -- every stud is the stud mesh again) and the draws.
## {parts: {name: {bricks, studs, draws}}, total, draws, ms}.
func triangle_stats() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var by_part := {}
	for i in recipe.size():
		if _brick_frame(i) < 0:
			continue
		var name := part_names[part_of[i] if i < part_of.size() else part_sel]
		(by_part.get_or_add(name, []) as Array).append(i)
	var stud_tris := _mesh_triangles(PieceMeshes.stud())
	var parts := {}
	var total := 0
	var draws := 0
	for name in by_part:
		var bricks := 0
		var n_studs := 0
		var meshes := 0
		var groups := _by_frame(_uncovered(name, by_part[name]))
		for af in groups:
			var made := _part_chunk(groups[af])
			var c: int = made[0]
			var t := _arrays_triangles(world.build_chunk_mesh(c))
			bricks += t
			meshes += 1 if t > 0 else 0
			@warning_ignore("integer_division")
			n_studs += (world.get_chunk_studs(c) as PackedFloat32Array).size() / 16
			world.release_chunk(c)
		var hand := 0
		for st in extra_studs:
			if String(st.get("part", "")) == name:
				hand += 1
		var studs := (n_studs + hand) * stud_tris
		var d := meshes + (groups.size() if n_studs > 0 else 0) + (1 if hand > 0 else 0)
		var shell := int(_shell_tris.get(name, 0))
		bricks += shell
		d += 1 if shell > 0 else 0
		parts[name] = {"bricks": bricks, "studs": studs, "draws": d, "shell": shell}
		total += bricks + studs
		draws += d
	return {"parts": parts, "total": total, "draws": draws,
			"ms": (Time.get_ticks_usec() - t0) / 1000.0}


static func _arrays_triangles(arrays: Array) -> int:
	if arrays.is_empty():
		return 0
	var idx = arrays[Mesh.ARRAY_INDEX]
	if idx != null and (idx as PackedInt32Array).size() > 0:
		@warning_ignore("integer_division")
		return (idx as PackedInt32Array).size() / 3
	@warning_ignore("integer_division")
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


static func _mesh_triangles(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		n += _arrays_triangles(m.surface_get_arrays(s))
	return n


## The readout's triangle line, from the last count (worked out again a moment after an edit).
func triangles_text() -> String:
	if _tris.is_empty() or int(_tris.total) == 0:
		return ""
	var bits := PackedStringArray()
	var parts: Dictionary = _tris.parts
	var names := parts.keys()
	names.sort_custom(func(a, b) -> bool:
		return parts[a].bricks + parts[a].studs > parts[b].bricks + parts[b].studs)
	for name in names:
		bits.append("%s %s" % [name, _thousands(parts[name].bricks + parts[name].studs)])
	var studs := 0
	for name in parts:
		studs += int(parts[name].studs)
	return "triangles: %s in %d draws (studs %s)   %s" % [
			_thousands(_tris.total), _tris.draws, _thousands(studs), ", ".join(bits)]


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## Studs put on by hand, as the workshop draws them (workshop metres).
func _studs_node(list: Array) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "HandStuds"
	mmi.material_override = _stud_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.stud()
	mm.instance_count = list.size()
	for i in list.size():
		var st: Dictionary = list[i]
		mm.set_instance_transform(i, _stud_transform(st))
		mm.set_instance_color(i, BrickWorld.get_material_colour(int(st.get("mat", 0)), int(st.get("colour", 0))))
	mmi.multimesh = mm
	return mmi


## Each part's point, in the build's metres: its mount, else the middle of its bricks.
func _part_points(by_part: Dictionary) -> Dictionary:
	var at := {}
	for name in by_part:
		at[name] = _cells_centre(by_part[name])
	for q in points:
		if q.kind == "mount" and by_part.has(String(q.part)):
			at[q.part] = _point_m(q)
	return at


static func _point_m(q: Dictionary) -> Vector3:
	return Vector3(float(q.at[0]) * BrickPalette.STUD_M, float(q.at[1]) * BrickPalette.PLATE_M,
			float(q.at[2]) * BrickPalette.STUD_M)


static func _game_node(parent: Node3D, node_name: String, pos: Vector3) -> void:
	var n := Node3D.new()
	n.name = node_name
	n.position = pos
	parent.add_child(n)


## A packed scene keeps only the nodes the root owns.
static func _own(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_own(c, root)


## Which end the muzzle is, read off the build: the barrel (and the muzzle) forward of the
## body, the stock behind it. Left as it was when the build cannot say (no barrel or
## stock yet). The Thompson was built muzzle toward +x and came out of the first export
## backwards: nothing had said so.
func settle_muzzle() -> void:
	var sum := {}
	var n := {}
	for i in recipe.size():
		if _brick_frame(i) < 0 or i >= part_of.size():
			continue
		var name := part_names[part_of[i]]
		if not name in ["body", "barrel", "muzzle", "stock"]:
			continue
		for p: Vector3 in _cell_points(i):
			sum[name] = float(sum.get(name, 0.0)) + p.x / BrickPalette.STUD_M
			n[name] = int(n.get(name, 0)) + 1
	var c := {}
	for k in sum:
		c[k] = float(sum[k]) / int(n[k])
	var lean := 0.0
	var mid: float = c.get("body", (float(c.get("barrel", 0.0)) + float(c.get("stock", 0.0))) * 0.5)
	for k in ["barrel", "muzzle"]:
		if c.has(k):
			lean += float(c[k]) - mid
	if c.has("stock"):
		lean -= float(c.stock) - mid
	if absf(lean) > 0.5:
		muzzle_end = "-x" if lean < 0.0 else "+x"


# ---------------------------------------------------------------------------
# Out to the printer: each part one watertight STL (tools/brickify/printkit.py)
# ---------------------------------------------------------------------------

var _print_report := ""
var _print_started := 0


## Where a gun's print files go: beside the other print files, outside the repository
## (Documents/brickcity-print/guns/<name>/).
func print_dir() -> String:
	var sheet_name := slug(recipe.name if recipe.name != "untitled" else "gun")
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).replace("\\", "/") + "/brickcity-print/guns/" + sheet_name


## Export the gun for printing: its build sheet, then Blender's print kit makes each part
## one watertight solid at print size (one nano stud is 4 mm) -- its bricks one shell,
## slopes and studs unioned on, a stud hole wherever it sits on another part's studs --
## as <part>.stl, with pictures and a report. Runs in the background; the report shows
## when it is done. `run` false only writes the sheet (for checks). Returns the folder.
func export_print(run: bool = true) -> String:
	var sheet := export_sheet()
	if (sheet.parts as Array).is_empty():
		_export_check = "print: nothing built yet"
		return ""
	var dir := ProjectSettings.globalize_path("user://asset_exports")
	DirAccess.make_dir_recursive_absolute(dir)
	var sheet_path := "%s/%s.json" % [dir, sheet.name]
	var f := FileAccess.open(sheet_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(sheet, " "))
	f.close()
	var out := print_dir()
	if not run:
		return out
	if not FileAccess.file_exists(blender_path):
		_export_check = "print: Blender not found at %s (set BRICKCITY_BLENDER)" % blender_path
		return out
	DirAccess.make_dir_recursive_absolute(out)
	var kit := ProjectSettings.globalize_path("res://tools/brickify/printkit.py")
	_print_report = "%s/%s.print.json" % [out, sheet.name]
	_print_started = int(Time.get_unix_time_from_system())
	OS.create_process(blender_path, ["--background", "--factory-startup", "--python", kit, "--", sheet_path, out])
	_export_check = "print: making the STLs..."
	print("[asset workshop] print files going to %s" % out)
	return out


func _poll_print() -> void:
	if _print_report == "" or not FileAccess.file_exists(_print_report):
		return
	if FileAccess.get_modified_time(_print_report) < _print_started:
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(_print_report))
	var text := "print: no report"
	if d is Dictionary:
		var bad := PackedStringArray()
		for p in d.get("parts", []):
			if not bool(p.watertight) or int(p.get("loose_bits", 0)) > 0:
				bad.append(String(p.part))
		var pinched := PackedStringArray()
		for p in d.get("parts", []):
			if int(p.get("pinched_edges", 0)) > 0:
				pinched.append("%s %d" % [p.part, int(p.pinched_edges)])
		var size: Array = d.get("print_mm", [0, 0, 0])
		text = "print: %d parts, %.0f x %.0f x %.0f mm, %s   (%s)" % [(d.parts as Array).size(),
				float(size[0]), float(size[1]), float(size[2]),
				("every part watertight, no loose bits" if bad.is_empty() else "NOT CLEAN: " + ", ".join(bad))
				+ ("; touching only along a line: " + ", ".join(pinched) if not pinched.is_empty() else "")
				+ _whole_text(d.get("whole", {})),
				_print_report.get_base_dir()]
	var png := _print_report.replace(".print.json", "_print_iso.png")
	_print_report = ""
	_export_check = text
	print("[asset workshop] " + text)
	var img := Image.load_from_file(png) if FileAccess.file_exists(png) else null
	if img != null and not img.is_empty():
		_preview_image.texture = ImageTexture.create_from_image(img)
		_preview_text.text = text
		_preview_panel.visible = true


## The one-piece print's line of the report.
static func _whole_text(w: Dictionary) -> String:
	if w.is_empty():
		return ""
	return "; whole gun in one piece: %s%s" % ["watertight" if bool(w.watertight) and int(w.get("pieces", 0)) == 1
			else "NOT CLEAN", (", %d edge(s) touching only along a line" % int(w.pinched_edges))
			if int(w.get("pinched_edges", 0)) > 0 else ""]


# ---------------------------------------------------------------------------
# Every key in a menu: nothing to remember (2026-10-16)
# ---------------------------------------------------------------------------

## The bar's menus for this scene: every action a key does, with the key beside it. The
## keys still work; a menu item only calls the same thing. What is held or aimed (Tab,
## hold E, the number keys, the wheel, the mouse buttons) stays a key and is listed under
## Help.
var _menu_actions: Array[Callable] = []


func _menu_items(rows: Array) -> Array:
	var out := []
	for r in rows:
		if (r as Array).is_empty():
			out.append([])
			continue
		out.append(["%s      %s" % [r[0], r[1]] if String(r[1]) != "" else String(r[0]), 1000 + _menu_actions.size()])
		_menu_actions.append(r[2])
	return out


func _on_asset_menu(id: int) -> void:
	if id >= 1000 and id - 1000 < _menu_actions.size():
		_menu_actions[id - 1000].call()


func _build_menus() -> void:
	var menus := [
		["Asset", [
			["Make a gun", "", func() -> void: set_asset_kind("gun")],
			["Make a mech", "", func() -> void: set_asset_kind("mech")],
			["Make furniture or an item (rooms: tagged by planet, type, room)", "", func() -> void: set_asset_kind("item")],
		]],
		["Edit", [
			["Redo", "Shift Z", func() -> void: redo()],
		]],
		["View", [
			["3D view", "Alt 0", func() -> void: set_view(0)],
			["Side view", "Alt 1", func() -> void: set_view(1)],
			["Top view", "Alt 2", func() -> void: set_view(2)],
			["Front view", "Alt 3", func() -> void: set_view(3)],
			["The game's view: the gun in the hands (RMB aims)", "Alt C", func() -> void: set_game_view(not game_view_on)],
			["Zoom in", "Home", func() -> void: zoom(0.85)],
			["Zoom out", "End", func() -> void: zoom(1.0 / 0.85)],
			[],
			["Section: hide what is past the plane", "O", func() -> void: set_section(not section_on)],
			["Outlines: none / all parts / this part", "P", func() -> void: set_outlines((outlines + 1) % 3)],
			["Grid", "G", func() -> void:
				_grid_on = not _grid_on
				_grid.visible = _grid_on],
			[],
			["Free placement on the working plane", "Alt F", func() -> void: set_free(not free_place)],
			["Working plane forward", "PgUp", func() -> void: move_work_plane(1)],
			["Working plane back", "PgDn", func() -> void: move_work_plane(-1)],
			[],
			["Mirror", "Alt S", func() -> void: set_mirror(not mirror_on)],
			["Mirror plane where the ghost is", "Alt Shift S", func() -> void: mirror_here()],
		]],
		["Part", [
			["Next part", "Y", func() -> void: select_part(part_sel + 1)],
			["Previous part", "Shift Y", func() -> void: select_part(part_sel - 1)],
			[],
			["This part leaves smooth / as bricks", "N", func() -> void: toggle_smooth()],
			["Connection point where the ghost is", "J", func() -> void: toggle_point_here()],
			[],
		]],
		["Block out", [
			["Sculpt tool (3D, the SDF block-out)", "Alt V", func() -> void: rail_pick("sculpt")],
			["Sketch tool (2D, straight into bricks)", "Alt D", func() -> void: rail_pick("sketch")],
			["Shapes brush (balls, cubes, cylinders)", "K", func() -> void:
				rail_pick("shape")
				shape_mode = "brush"],
			[],
			["Smooth shell on this part / off", "", func() -> void:
				var part := part_names[part_sel]
				set_shell(part, null if shells.has(part) else {"thick": 0.5, "res": 4})
				_sync_shell_ui(true)],
			[],
			["Clear this view's block-out", "", func() -> void: clear_sketch(_sketch_key())],
			["Clear the part's block-out, every view", "", func() -> void: clear_part_sketch(part_names[part_sel])],
		]],
		["Brick", [
			["Turn the brick in hand", "R", func() -> void:
				_yaw = (_yaw + 1) % 4],
			["Flip it (studs down)", "F", func() -> void:
				_flip = not _flip],
			["Turn the last one placed", "T", func() -> void: _rotate_last()],
			[],
			["Next colour", ".", func() -> void: _hotbar.set_colour(_colour + 1)],
			["Previous colour", ",", func() -> void: _hotbar.set_colour(_colour - 1)],
			["Paint", "B", func() -> void: rail_pick("place" if _painting else "paint")],
		]],
		["Gun", [
			["Explode: pull the parts apart", "Alt E", func() -> void: set_exploded(not exploded)],
			["Hands", "Alt H", func() -> void: set_hands(not hands_on)],
			["Play: fire and reload", "Alt P", func() -> void: play_cycle()],
			["Size marks: ruler and grip box", "", func() -> void: set_size_marks(not size_marks_on)],
			["Size: SMG (53 studs)", "", func() -> void: set_gun_class("smg")],
			["Size: rifle (62 studs)", "", func() -> void: set_gun_class("rifle")],
			["Size: pistol (13.5 studs)", "", func() -> void: set_gun_class("pistol")],
			["Turn the ruler (which end is the butt)", "", func() -> void: flip_butt()],
			[],
			["Export to game", "Alt X", func() -> void: export_game()],
			["Export to print (parts and whole)", "Alt B", func() -> void: export_print()],
			["Export and preview in Blender", "F12", func() -> void: export_and_preview()],
		]],
		["Photos", [
			["Photos panel", "F2", func() -> void: _toggle_panel()],
			["Guide models panel", "F3", func() -> void: _toggle_guide_panel()],
			["Parts catalogue", "F7", func() -> void: toggle_catalog()],
			["Take off the tried parts", "", func() -> void: untry_all()],
			["Wand: fill a patch of a photo", "F4", func() -> void: set_tool("" if tool == "wand" else "wand")],
			["Measure", "Alt M", func() -> void: set_measure(not measure_on)],
		]],
		["Help", [
			["How to start, and every key", "F10", func() -> void: show_help(not _help.visible)],
			["The building workshop's key list", "F1", func() -> void:
				_keys_on = not _keys_on
				_keys_panel.visible = _keys_on],
			[],
			["Held or aimed, keys only:", "", func() -> void: pass],
			["  all parts browser", "Tab", func() -> void: pass],
			["  lock the height, slide anywhere", "hold E", func() -> void: pass],
			["  toolbar slot", "1-9, wheel", func() -> void: pass],
			["  pick the brick under the cursor", "MMB", func() -> void: pass],
			["  shape brush from any tool, its size", "Ctrl + LMB / RMB, Ctrl + wheel", func() -> void: pass],
		]],
	]
	for m in menus:
		var mb: MenuButton = _menu.add_menu(String(m[0]), _menu_items(m[1]), _on_asset_menu)
		if m[0] == "Help":
			# The key-only rows are a list, not actions.
			var p := mb.get_popup()
			for i in p.item_count:
				if p.get_item_text(i).begins_with("  ") or p.get_item_text(i).begins_with("Held"):
					p.set_item_disabled(i, true)


# ---------------------------------------------------------------------------
# Round 4: a placed model, the gun's size, the game's view (Docs/AssetWorkshop.md,
# "SDF tools, round 4")
# ---------------------------------------------------------------------------

## The model objects (Docs/AssetWorkshop.md, "Models as objects"): each {id, path, pieces
## ([{name, mesh, soup}], its own frame), box, xf (where it stands, workshop space), op,
## parts (a part index a piece, -1 the model's own), default_part, node (an AssetSculpt: its
## own field, drawn)}. `_placed` is the selected one, {} for none.
var models: Array = []
var _placed := {}
var _model_cache := {}   # id -> {id, path, pieces, box}: undo brings removed ones back
var _model_next := 1
var _gizmo_before := []
var _model_list: OptionButton
var _piece_box: VBoxContainer
var _gizmo: ModelGizmo
var _placed_ghost: MeshInstance3D
var _gizmo_xf0 := Transform3D()

## The gun classes the size marks know (Docs/Parts/joints.md section 7): the real length.
## How long the game shows each in the hands is PlayerView.VIEW_LENGTH's.
const GUN_CLASSES := {
	"smg": {"name": "SMG", "real_mm": 852.0},
	"rifle": {"name": "rifle", "real_mm": 1000.0},
	"pistol": {"name": "pistol", "real_mm": 216.0},
}
## The shared grip leans back like a real pistol grip, and sits this share of the gun's
## length from the butt (an SMG's).
const GRIP_RAKE_DEG := 15.0
const GRIP_AT := 0.25
## The longest a placed model may be, studs (four rifles): past ~1000 the stamp refuses.
const MODEL_MAX_STUDS := 250.0
## The nudge buttons' step: half a stud (up and down: a plate) or a whole one (a brick).
var nudge_whole := false
var gun_class := "smg"
var size_marks_on := true
## The shared grip at print size, mm (standards.json "held_grip"; these until it is read).
var _grip_std := {"length_min": 24.0, "fore_aft": [10.0, 15.5], "thick": [7.0, 9.5]}
var _size_marks: MeshInstance3D
var _size_labels: Node3D
var _size_sig := ""
var _size_at := 0
var _size_pick: OptionButton
## The game's first-person view (Alt C): on, aiming down the sights, the camera as it was.
var game_view_on := false
var game_view_ads := false
var _game_view_was := {}


## Studs long the class's gun is: its real length over 16 mm a nano stud.
func class_studs(c: String = gun_class) -> float:
	return float(GUN_CLASSES[c].real_mm) / (PRINT_MM_PER_STUD * REAL_PER_PRINT)


## A model file added as a model object, its pieces read apart. False if it cannot be read.
func place_model(path: String, op: int = SdfForm.ADD) -> bool:
	var pieces := ModelMesh.read_pieces(path)
	if pieces.is_empty():
		_show_sculpt_note(true, "Could not read %s." % path.get_file())
		return false
	return add_model(pieces, path, op)


## One mesh as a one-piece model (the probes, the picture pass).
func place_mesh(mesh: ArrayMesh, path: String, op: int = SdfForm.ADD) -> bool:
	return add_model([[path.get_file().get_basename(), mesh]], path, op)


## A model object (Docs/AssetWorkshop.md, "Models as objects"): `pieces` ([name, mesh], the
## model's own frame) kept apart, its long side along x and as long as the class's gun,
## centred where the build is (the grid's middle) on the mirror plane, standing no lower
## than the bottom plate. Its own field, drawn as the block-out is; selected, the gizmo on
## it, the view on it. One undo.
func add_model(pieces: Array, path: String, op: int = SdfForm.ADD) -> bool:
	if sculpt_state == "bricks":
		sculpt_to_sdf()
	var entry := _cache_model(pieces, path)
	var box: AABB = entry.box
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest <= 0.0:
		return false
	var turn := Basis(Vector3.UP, PI * 0.5) if box.size.z > box.size.x and box.size.z >= box.size.y else Basis()
	var b := turn * Basis.from_scale(Vector3.ONE * class_studs() * BrickPalette.STUD_M / longest)
	var on := Transform3D(b, Vector3.ZERO) * box
	var c := build_centre()
	var at := Vector3(c.x - on.get_center().x, maxf(c.y - on.size.y * 0.5, BrickPalette.PLATE_M) - on.position.y,
			mirror_z * BrickPalette.STUD_M - on.get_center().z)
	# Not the first: beside the others on the near side, two studs clear, on a stud line, on
	# their bottom (Docs/AssetWorkshop.md, "A second model beside the first").
	if not models.is_empty():
		var others := (models[0].xf as Transform3D) * (models[0].box as AABB)
		for o in models:
			others = others.merge((o.xf as Transform3D) * (o.box as AABB))
		at.y = maxf(others.position.y, BrickPalette.PLATE_M) - on.position.y
		at.z = ceilf(others.end.z / BrickPalette.STUD_M + 2.0) * BrickPalette.STUD_M - on.position.z
	var before := models_state()
	var m := _make_model(entry, Transform3D(b, at), op, [], part_sel)
	models.append(m)
	_model_record(before)
	select_model(m)
	_frame_placed()
	_draw_work_plane()
	return true


## The pieces of a model, kept by id for as long as the workshop is open: undo brings a
## removed model back from here.
func _cache_model(pieces: Array, path: String) -> Dictionary:
	var list := []
	var box := AABB()
	for p in pieces:
		var mesh: ArrayMesh = p[1]
		list.append({"name": String(p[0]), "mesh": mesh, "soup": _mesh_soup(mesh)})
		box = mesh.get_aabb() if list.size() == 1 else box.merge(mesh.get_aabb())
	var entry := {"id": _model_next, "path": path, "pieces": list, "box": box}
	_model_cache[_model_next] = entry
	_model_next += 1
	return entry


func _make_model(entry: Dictionary, xf: Transform3D, op: int, parts: Array, default_part: int) -> Dictionary:
	var node := AssetSculpt.new()
	add_child(node)
	var p := parts.duplicate()
	p.resize((entry.pieces as Array).size())
	for k in p.size():
		if p[k] == null:
			p[k] = -1
	var m := {"id": entry.id, "path": entry.path, "pieces": entry.pieces, "box": entry.box, "xf": xf, "op": op,
			"parts": p, "default_part": default_part, "node": node}
	_colour_model(m)
	_stamp_model(m)
	return m


## A piece's colour: its part's once given one, else a colour of its own (red-tinted when
## the model carves).
func _colour_model(m: Dictionary) -> void:
	var node: AssetSculpt = m.node
	var pal := PackedColorArray([Color(0.8, 0.8, 0.8)])
	for k in (m.pieces as Array).size():
		var part: int = m.parts[k]
		var col := Color.from_hsv(fmod(0.13 + k * 0.37, 1.0), 0.6, 0.95)
		if part >= 0 and part + 1 < sculpt.palette.size():
			col = sculpt.palette[part + 1]
		if int(m.op) == SdfForm.REMOVE:
			col = col.lerp(Color(1.0, 0.25, 0.2), 0.6)
		# The piece picked with the mouse shows lighter.
		if k == int(m.get("piece", -1)):
			col = col.lerp(Color.WHITE, 0.5)
		pal.append(col)
	node.palette = pal
	node.remesh_all()


## A model's own field stamped where it stands: a label a piece (its index + 1).
func _stamp_model(m: Dictionary) -> void:
	var node: AssetSculpt = m.node
	node.transform = sculpt.transform
	node.form.clear()
	var to_s := node.global_transform.affine_inverse() * global_transform * (m.xf as Transform3D)
	var pieces: Array = m.pieces
	for k in pieces.size():
		var soup: Array = pieces[k].soup
		var v: PackedVector3Array = (soup[0] as PackedVector3Array).duplicate()
		for i in v.size():
			v[i] = to_s * v[i]
		node.form.stamp_mesh(SdfForm.ADD, v, soup[1], k + 1)
	node.remesh_all()


## Each piece's label in the block-out: its part's (part + 1), else the model's own part's.
static func _model_labels(m: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array([0])
	for k in (m.pieces as Array).size():
		var part: int = m.parts[k]
		out.append((part if part >= 0 else int(m.default_part)) + 1)
	return out


## Every model joined into the block-out (union, or carved): what Convert and the custom
## pieces read. Returns the record that takes them out again (`_models_out`).
func _models_into_field() -> PackedByteArray:
	if models.is_empty():
		return PackedByteArray()
	sculpt.form.begin_edit()
	for m in models:
		sculpt.form.combine((m.node as AssetSculpt).form, int(m.op), _model_labels(m))
	return sculpt.form.end_edit()


func _models_out(rec: PackedByteArray) -> void:
	if not rec.is_empty():
		sculpt.form.swap_blocks(rec)


## What undo and a save keep of the models: each one's file, place, op and pieces' parts.
func models_state() -> Array:
	var out := []
	for m in models:
		out.append({"id": m.id, "path": m.path, "xf": m.xf, "op": m.op, "parts": (m.parts as Array).duplicate(),
				"default_part": m.default_part})
	return out


func _model_record(before: Array) -> void:
	_edit_groups.append({"end": _edits.size(), "n": 0, "sketch": [{"models_before": before, "models_after": models_state()}]})
	_redo.clear()
	_store_asset_meta()
	_autosave_dirty = true


## The models made as `state` says (an undo, a redo, a load): missing ones from the cache,
## gone ones taken away, the rest moved, recoloured and stamped where they changed.
func _set_models(state: Array) -> void:
	_set_down()
	var want := {}
	for s in state:
		want[int(s.id)] = s
	for m in models.duplicate():
		if not want.has(int(m.id)):
			(m.node as Node).queue_free()
			models.erase(m)
	var order := []
	for s in state:
		var m = null
		for o in models:
			if int(o.id) == int(s.id):
				m = o
		if m == null:
			if not _model_cache.has(int(s.id)):
				continue
			m = _make_model(_model_cache[int(s.id)], s.xf, int(s.op), s.parts, int(s.default_part))
		elif m.xf != s.xf or int(m.op) != int(s.op) or m.parts != s.parts or int(m.default_part) != int(s.default_part):
			m.xf = s.xf
			m.op = int(s.op)
			m.parts = (s.parts as Array).duplicate()
			m.default_part = int(s.default_part)
			_colour_model(m)
			_stamp_model(m)
		order.append(m)
	models = order
	_refresh_model_list()
	_store_asset_meta()


## The models as saved: Transform3D as 12 numbers.
func _models_meta() -> Array:
	var out := []
	for s in models_state():
		var x: Transform3D = s.xf
		s.xf = [x.basis.x.x, x.basis.x.y, x.basis.x.z, x.basis.y.x, x.basis.y.y, x.basis.y.z,
				x.basis.z.x, x.basis.z.y, x.basis.z.z, x.origin.x, x.origin.y, x.origin.z]
		s.erase("id")
		out.append(s)
	return out


## Saved models read in again from their files; one whose file is gone is left out.
func _restore_models(list: Array) -> void:
	for m in models:
		(m.node as Node).queue_free()
	models.clear()
	for s in list:
		var pieces := ModelMesh.read_pieces(String(s.path))
		if pieces.is_empty():
			push_warning("asset workshop: model %s is gone" % s.path)
			continue
		var f: Array = s.xf
		var xf := Transform3D(Basis(Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]), Vector3(f[6], f[7], f[8])),
				Vector3(f[9], f[10], f[11]))
		var parts := []
		for p in s.get("parts", []):
			parts.append(int(p))
		models.append(_make_model(_cache_model(pieces, String(s.path)), xf, int(s.get("op", SdfForm.ADD)), parts,
				int(s.get("default_part", 0))))
	_refresh_model_list()


## Pick `m` (a model, a lifted part or a guide: Docs/AssetWorkshop.md, "Pick and move"), or
## null for nothing. A lifted part picked away from is put down (one undo).
func select_model(m: Variant) -> void:
	var was := _placed
	var now: Dictionary = m if m is Dictionary else {}
	if not was.is_empty() and not is_same(was, now):
		if was.get("kind") == "part":
			_put_part_back(was)
		elif int(was.get("piece", -1)) >= 0:
			was.piece = -1
			_colour_model(was)
	_placed = now
	if _placed.is_empty():
		_hide_gizmo()
		_show_sculpt_note()
	else:
		_show_gizmo()
		_show_placed_note()
	_refresh_model_list()


## The added (ADD) or carving (REMOVE) model; with none selected, the guide picked in the
## guide panel goes in or out of the block-out.
func model_op(op: int) -> void:
	if _held_kind() != "model":
		_set_down()
		sculpt_model_into(_picked_guide(), op)
		return
	var before := models_state()
	_placed.op = op
	_colour_model(_placed)
	_stamp_model(_placed)
	_model_record(before)
	_show_gizmo()


## The selected model's id, -1 for none (or a part or guide picked).
func _pick_id() -> int:
	return int(_placed.id) if _held_kind() == "model" else -1


## What is picked: "model", "part" (lifted out of the block-out), "guide", or "".
func _held_kind() -> String:
	return "" if _placed.is_empty() else String(_placed.get("kind", "model"))


## Before an edit: a model is let go and a lifted part put down (one undo before the
## edit's); a picked guide stays picked (guides are not in the undo).
func _set_down() -> void:
	if _held_kind() in ["model", "part"]:
		lay_model()


## LMB on the block-out in pick and move: part `label` lifted out of it into a field of its
## own, drawn apart, the gizmo on it (Docs/AssetWorkshop.md, "Pick and move"). While it is
## held only its drawing moves; it is resampled and joined back when let go. False if the
## part has nothing there.
func lift_part(label: int) -> bool:
	if label <= 0 or sculpt_state != "sdf":
		return false
	_set_down()
	sculpt.form.begin_edit()
	var taken: SdfForm = sculpt.form.take_part(label)
	var rec := sculpt.form.end_edit()
	var bb := taken.bounds()
	if bb.size == Vector3.ZERO:
		sculpt.form.swap_blocks(rec)
		sculpt.remesh()
		return false
	sculpt.remesh()
	var node := AssetSculpt.new()
	add_child(node)
	node.form = taken
	node.palette = sculpt.palette
	node.transform = sculpt.transform
	node.remesh_all()
	select_model({"kind": "part", "id": -1, "label": label, "node": node, "rec": rec, "xf": Transform3D(),
			"box": sculpt.transform * bb, "pieces": [], "op": SdfForm.ADD,
			"path": part_names[clampi(label - 1, 0, part_names.size() - 1)]})
	return true


## A lifted part put down: where the gizmo left it, resampled and joined back (the lift and
## its moves one undo); not moved (or Escape), the block-out exactly as before the lift.
func _put_part_back(p: Dictionary) -> void:
	var node: AssetSculpt = p.node
	var xf: Transform3D = p.xf
	# Back to before the lift first: the record then starts from the block-out as it was.
	sculpt.form.swap_blocks(p.rec)
	if not xf.is_equal_approx(Transform3D()):
		sculpt.form.begin_edit()
		var taken: SdfForm = sculpt.form.take_part(int(p.label))
		taken.transform(sculpt.transform.affine_inverse() * xf * sculpt.transform)
		sculpt.form.combine(taken, SdfForm.ADD, PackedInt32Array())
		_sculpt_record(sculpt.form.end_edit())
	sculpt.remesh()
	node.queue_free()


## Pick guide `i` (the guide panel's list, or LMB on it in pick and move): the gizmo on it.
func select_guide(i: int) -> void:
	if i < 0 or i >= guides.size():
		return
	var g: Dictionary = guides[i]
	if _guide_list != null and _guide_list.selected != i:
		_guide_list.select(i)
	select_model({"kind": "guide", "id": -1, "guide": g, "node": g.node, "xf": (g.node as Node3D).transform,
			"box": g.box, "pieces": [], "op": SdfForm.ADD, "path": g.path})


## The picked thing where a drag, a nudge or a snap put it: a model stamped again (one
## undo), a lifted part's drawing moved (its undo comes when it is put down), a guide's
## adjust kept.
func _held_moved(before: Array) -> void:
	_held_follow()
	match _held_kind():
		"model":
			_stamp_placed()
			_model_record(before)
		"guide":
			var g: Dictionary = _placed.guide
			g.adjust = (_placed.xf as Transform3D) * _guide_fit_xf(g).affine_inverse()
			_store_asset_meta()
			_show_placed_note()
		_:
			_show_placed_note()
	_gizmo.position = _placed_centre()


## A lifted part's or a guide's drawing where `_placed.xf` says (a model shows its ghost).
func _held_follow() -> void:
	match _held_kind():
		"part":
			(_placed.node as Node3D).transform = (_placed.xf as Transform3D) * sculpt.transform
		"guide":
			((_placed.guide as Dictionary).node as Node3D).transform = _placed.xf


## Pick model `id` again after an undo or redo, if it is still there and the block-out
## showing (Docs/AssetWorkshop.md, "A second model beside the first").
func _repick(id: int) -> void:
	if id < 0 or sculpt_state != "sdf":
		return
	for m in models:
		if int(m.id) == id:
			select_model(m)


## Deselect: the model stays an object, the gizmo goes (pick it again to move it).
func lay_model() -> void:
	if _placed.is_empty():
		return
	select_model(null)


## Take the selected model away. One undo.
func drop_model() -> void:
	if _held_kind() != "model":
		return
	var before := models_state()
	var m := _placed
	select_model(null)
	(m.node as Node).queue_free()
	models.erase(m)
	_model_record(before)


## The selected model joined into the block-out for good (then the brushes carve and smooth
## it); it is no longer an object. One undo.
func bake_model() -> void:
	if _held_kind() != "model":
		_show_sculpt_note(true, "Pick a model first (models: pick and move).")
		return
	var before := models_state()
	var m := _placed
	select_model(null)
	sculpt.form.begin_edit()
	sculpt.form.combine((m.node as AssetSculpt).form, int(m.op), _model_labels(m))
	var rec := sculpt.form.end_edit()
	sculpt.remesh()
	(m.node as Node).queue_free()
	models.erase(m)
	_edit_groups.append({"end": _edits.size(), "n": 0, "sketch": [{"sdf": rec},
			{"models_before": before, "models_after": models_state()}]})
	_redo.clear()
	_sdf_meta = sculpt.save_meta()
	_store_asset_meta()
	_autosave_dirty = true
	_show_sculpt_note(false, "%s baked into the block-out." % String(m.path).get_file())


## Give the selected model's piece `k` a part (-1: the model's own). One undo.
func set_piece_part(k: int, part: int) -> void:
	if _held_kind() != "model" or k < 0 or k >= (_placed.parts as Array).size():
		return
	var before := models_state()
	_placed.parts[k] = part
	_colour_model(_placed)
	_model_record(before)
	_refresh_model_list()


func placed_model() -> Dictionary:
	return _placed


## The selected model's box as it stands, in studs (x along, y up, z across: a stud's length
## each way).
func placed_size() -> Vector3:
	if _placed.is_empty():
		return Vector3.ZERO
	return ((_placed.xf as Transform3D) * (_placed.box as AABB)).size / BrickPalette.STUD_M


func _show_placed_note() -> void:
	if _placed.is_empty():
		return
	var s := placed_size()
	if _held_kind() == "part":
		_show_sculpt_note(false, ("%s lifted: %.1f studs long, %.1f up, %.1f across. Arrows move it, rings turn it, the "
				+ "cube resizes it (Shift: no snap). Enter or LMB on nothing puts it down (one undo); Esc puts it back "
				+ "as it was.") % [String(_placed.path), s.x, s.y, s.z])
		return
	if _held_kind() == "guide":
		_show_sculpt_note(false, ("guide %s: %.1f studs long, %.1f up, %.1f across. Arrows move it, rings turn it, the "
				+ "cube resizes it (Shift: no snap); the guide panel's buttons still fit it. Enter or Esc lets it go.")
				% [String(_placed.path).get_file(), s.x, s.y, s.z])
		return
	_show_sculpt_note(false, ("%s %s: %.1f studs long (%.0f mm real, %.0f mm print), %.1f up, %.1f across. "
			+ "Arrows move it, rings turn it, the cube resizes it (Shift: no snap). Enter or Esc lets it go; "
			+ "pick it again with \"models: pick and move\".") % [String(_placed.path).get_file(),
			"carves" if int(_placed.op) == SdfForm.REMOVE else "selected", s.x,
			s.x * PRINT_MM_PER_STUD * REAL_PER_PRINT, s.x * PRINT_MM_PER_STUD, s.y, s.z])


func _placed_centre() -> Vector3:
	return (_placed.xf as Transform3D) * (_placed.box as AABB).get_center()


func _show_gizmo() -> void:
	if _gizmo == null:
		_gizmo = ModelGizmo.new()
		add_child(_gizmo)
		_placed_ghost = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_placed_ghost.material_override = m
		_placed_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_placed_ghost)
	_gizmo.visible = true
	_gizmo.position = _placed_centre()
	_placed_ghost.visible = false
	var ghost := ArrayMesh.new()
	for p in _placed.pieces:
		var arr := (p.mesh as ArrayMesh).surface_get_arrays(0)
		ghost.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_placed_ghost.mesh = ghost
	var col: Color = Color(1.0, 0.4, 0.35) if int(_placed.op) == SdfForm.REMOVE else Color(0.6, 0.9, 1.0)
	col.a = 0.35
	(_placed_ghost.material_override as StandardMaterial3D).albedo_color = col


func _hide_gizmo() -> void:
	if _gizmo != null:
		_gizmo.visible = false
		_gizmo.end()
		_placed_ghost.visible = false


## The view on a model just added: from the side, above and a little ahead.
func _frame_placed() -> void:
	if view != 0 or game_view_on or _placed.is_empty():
		return
	var bb := (_placed.xf as Transform3D) * (_placed.box as AABB)
	var c := bb.get_center()
	_camera.global_position = c + Vector3(0.3, 0.4, 1.0).normalized() * maxf(bb.size.length(), 2.0) * 1.1
	_camera.look_at(c, Vector3.UP)


## The gizmo: LMB on a handle drags it; the model shows as a ghost while it goes and is
## stamped again where it is let go (one undo). True when the event was the gizmo's.
func _gizmo_input(e: InputEvent) -> bool:
	if _placed.is_empty() or _gizmo == null or not _gizmo.visible:
		return false
	# The ray under the event's own position (a free cursor), else the aimed one.
	var ray := _mouse_ray()
	if e is InputEventMouse and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var at: Vector2 = (e as InputEventMouse).position
		ray = [_camera.project_ray_origin(at), _camera.project_ray_normal(at)]
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			var id := _gizmo.pick(ray[0], ray[1])
			if id == "":
				return false
			_gizmo_xf0 = _placed.xf
			_gizmo_before = models_state()
			_gizmo.begin(id, ray[0], ray[1], e.position, _camera)
			return true
		if _gizmo.dragging() == "":
			return false
		_gizmo.end()
		_placed_ghost.visible = false
		if not (_placed.xf as Transform3D).is_equal_approx(_gizmo_xf0):
			_held_moved(_gizmo_before)
		_gizmo.position = _placed_centre()
		return true
	if e is InputEventMouseMotion:
		if _gizmo.dragging() != "":
			_placed.xf = dragged_xf(_gizmo.drag_delta(ray[0], ray[1], e.position), e.shift_pressed)
			if _held_kind() == "model":
				_placed_ghost.transform = _placed.xf
				_placed_ghost.visible = true
			else:
				_held_follow()
			_show_placed_note()
			return true
		_gizmo.set_hover(_gizmo.pick(ray[0], ray[1]))
	return false


## The selected model stamped again where it stands (callers record the undo).
func _stamp_placed() -> void:
	_stamp_model(_placed)
	_show_placed_note()


## The sculpt mode "pick and move": LMB picks what the mouse is on (a model and its piece,
## a part of the block-out, a guide), on nothing lets go. True when the click was the mode's.
func _model_pick_input(e: InputEvent) -> bool:
	if sculpt_mode != "models":
		return false
	if not (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT):
		return e is InputEventMouseButton
	var at: Vector2 = (e as InputEventMouse).position
	pick_at(_camera.project_ray_origin(at), _camera.project_ray_normal(at))
	return true


## Pick what a ray (workshop space) meets first (Docs/AssetWorkshop.md, "Pick and move"): a
## model, with the piece there; a part of the block-out, lifted; a guide; the lifted part
## itself (kept). Nothing: let go.
func pick_at(from: Vector3, dir: Vector3) -> void:
	var gf := global_transform * from
	var gd := global_transform.basis * dir
	var best := INF
	var what := ""
	var thing = null
	var label := 0
	for m in models:
		var node: AssetSculpt = m.node
		if not node.visible:
			continue
		var h = node.hit(gf, gd)
		if h != null and (node.to_world(h) - gf).length() < best:
			best = (node.to_world(h) - gf).length()
			what = "model"
			thing = m
			# The piece: its label just inside the surface.
			label = node.form.part_near(h + (node.ray_to_samples(gf, gd)[1] as Vector3) * 0.7)
	if _held_kind() == "part":
		var held: AssetSculpt = _placed.node
		var h = held.hit(gf, gd)
		if h != null and (held.to_world(h) - gf).length() < best:
			best = (held.to_world(h) - gf).length()
			what = "held"
	if sculpt.visible and sculpt_state == "sdf" and sculpt.form.block_count() > 0:
		var h = sculpt.hit(gf, gd)
		if h != null and (sculpt.to_world(h) - gf).length() < best:
			best = (sculpt.to_world(h) - gf).length()
			what = "part"
			label = sculpt.form.part_near(h + (sculpt.ray_to_samples(gf, gd)[1] as Vector3) * 0.7)
	for i in guides.size():
		var d := _guide_hit(guides[i], gf, gd)
		if d < best:
			best = d
			what = "guide"
			thing = i
	match what:
		"model":
			select_model(thing)
			pick_piece(label - 1)
		"part":
			if not lift_part(label):
				select_model(null)
		"guide":
			select_guide(thing)
		"held":
			pass
		_:
			select_model(null)


## How far along a ray (global) it meets a shown guide's triangles, INF if it misses.
func _guide_hit(g: Dictionary, from: Vector3, dir: Vector3) -> float:
	var best := INF
	if not (g.node as Node3D).visible:
		return best
	for mi in (g.node as Node).find_children("*", "MeshInstance3D", true, false):
		var xf := (mi as Node3D).global_transform
		var inv := xf.affine_inverse()
		var a := inv * from
		var b := inv * (from + dir)
		var faces := (mi as MeshInstance3D).mesh.get_faces()
		for t in range(0, faces.size() - 2, 3):
			var h = Geometry3D.ray_intersects_triangle(a, b - a, faces[t], faces[t + 1], faces[t + 2])
			if h != null:
				best = minf(best, (xf * (h as Vector3) - from).length())
	return best


## Piece `k` of the picked model picked: shown lighter, marked in the pieces list (-1: none).
func pick_piece(k: int) -> void:
	if _held_kind() != "model":
		return
	_placed.piece = k if k >= 0 and k < (_placed.pieces as Array).size() else -1
	_colour_model(_placed)
	_refresh_model_list()
	_show_placed_note()


## The picked piece given the current part (one undo).
func give_piece_part() -> void:
	var k := int(_placed.get("piece", -1)) if _held_kind() == "model" else -1
	if k < 0:
		_show_sculpt_note(true, "Pick a piece first: LMB on a model in \"pick and move\".")
		return
	set_piece_part(k, part_sel)


## The model a ray (workshop space) meets first, or null.
func pick_model(from: Vector3, dir: Vector3) -> Variant:
	var best = null
	var best_d := INF
	for m in models:
		var node: AssetSculpt = m.node
		var h = node.hit(global_transform * from, global_transform.basis * dir)
		if h == null:
			continue
		var d := (node.to_world(h) - global_transform * from).length()
		if d < best_d:
			best_d = d
			best = m
	return best


## The sculpt panel's models section: the list (pick one), and the selected one's pieces,
## each with a part.
func _build_models_box(box: Container) -> void:
	var title := Label.new()
	title.text = "models"
	box.add_child(title)
	_model_list = OptionButton.new()
	_model_list.focus_mode = Control.FOCUS_NONE
	_model_list.item_selected.connect(func(i: int) -> void:
		select_model(models[i - 1] if i >= 1 and i - 1 < models.size() else null))
	box.add_child(_model_list)
	var row := HFlowContainer.new()
	box.add_child(row)
	for b in [["remove", func() -> void: drop_model()], ["bake into SDF", func() -> void: bake_model()],
			["give the piece this part", func() -> void: give_piece_part()]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(b[1])
		row.add_child(btn)
	_piece_box = VBoxContainer.new()
	box.add_child(_piece_box)
	_refresh_model_list()


func _refresh_model_list() -> void:
	if _model_list == null:
		return
	_model_list.clear()
	_model_list.add_item("(no model picked)" if not models.is_empty() else "(no models yet)")
	var sel := 0
	for i in models.size():
		_model_list.add_item("%d. %s" % [i + 1, String(models[i].path).get_file()])
		if not _placed.is_empty() and models[i] == _placed:
			sel = i + 1
	_model_list.select(sel)
	for c in _piece_box.get_children():
		c.queue_free()
	if _placed.is_empty():
		return
	var pieces: Array = _placed.pieces
	for k in pieces.size():
		var row := HBoxContainer.new()
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.color = (_placed.node as AssetSculpt).palette[k + 1]
		row.add_child(swatch)
		var name := Label.new()
		name.text = ("> " if k == int(_placed.get("piece", -1)) else "") + String(pieces[k].name).left(18)
		name.custom_minimum_size.x = 110
		row.add_child(name)
		var pick := OptionButton.new()
		pick.focus_mode = Control.FOCUS_NONE
		pick.add_item("(%s)" % part_names[clampi(int(_placed.default_part), 0, part_names.size() - 1)])
		for p in part_names:
			pick.add_item(p)
		pick.select(int(_placed.parts[k]) + 1)
		var piece := k
		pick.item_selected.connect(func(i: int) -> void: set_piece_part(piece, i - 1))
		row.add_child(pick)
		_piece_box.add_child(row)


## Where a drag puts the model, from where it stood when the drag began: moved a quarter
## stud at a time, turned 15 degrees, resized 1% (`free`: as dragged).
func dragged_xf(d: Dictionary, free: bool) -> Transform3D:
	var xf := _gizmo_xf0
	var c := _gizmo.position
	if d.has("move"):
		var m: Vector3 = d.move
		if not free:
			var q := BrickPalette.STUD_M * 0.25
			m = (m / q).round() * q
		return Transform3D(xf.basis, xf.origin + m)
	if d.has("turn"):
		var a: float = d.turn[1]
		if not free:
			a = snappedf(a, deg_to_rad(15.0))
		var r := Basis(d.turn[0] as Vector3, a)
		return Transform3D(r, c - r * c) * xf
	if d.has("size"):
		var f: float = d.size
		# Held between a stud and MODEL_MAX_STUDS long: past that the stamp refuses it.
		var now := ((xf * (_placed.box as AABB)).size / BrickPalette.STUD_M)
		var longest := maxf(now.x, maxf(now.y, now.z))
		f = clampf(f, 1.0 / maxf(longest, 0.01), MODEL_MAX_STUDS / maxf(longest, 0.01))
		if not free:
			f = maxf(snappedf(f, 0.01), 0.01)
		return Transform3D(Basis.from_scale(Vector3.ONE * f), c - c * f) * xf
	return xf


## Enter lays a placed model, Escape takes it out. True when the key was the model's.
func _placed_key(e: InputEvent) -> bool:
	if _placed.is_empty() or not (e is InputEventKey and e.pressed and not e.echo):
		return false
	match (e as InputEventKey).keycode:
		KEY_ENTER, KEY_KP_ENTER:
			lay_model()
		KEY_ESCAPE:
			# A lifted part goes back exactly as it was, no undo.
			if _held_kind() == "part":
				_placed.xf = Transform3D()
			lay_model()
		_:
			return false
	return true


## The picture pass's model: an SMG of boxes -- receiver, barrel, stock, grip, magazine --
## touching but not overlapping (the stamp counts crossings), under an armature at 1/100
## and turned to lie along z, as exported characters often are.
static func _test_gun_scene() -> Node3D:
	var root := Node3D.new()
	var arm := Node3D.new()
	arm.scale = Vector3.ONE * 0.01
	arm.rotation.y = PI * 0.5
	root.add_child(arm)
	for b in [[Vector3(-150, 0, -25), Vector3(300, 80, 50)], [Vector3(150, 40, -12), Vector3(260, 24, 24)],
			[Vector3(-400, 5, -20), Vector3(250, 65, 40)], [Vector3(-110, -150, -20), Vector3(55, 150, 40)],
			[Vector3(10, -180, -15), Vector3(45, 180, 30)]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = b[1]
		mi.mesh = bm
		mi.position = (b[0] as Vector3) + (b[1] as Vector3) * 0.5
		arm.add_child(mi)
	return root


# Nudges: off half a stud, a model converts badly -------------------------------------

## Move the placed model, else the whole block-out, one step `dir` (x along: right / left
## as the side view shows it; y up; z front / back): half a stud or a stud along and
## across, a plate or a brick up and down. A laid block-out moved is one undo.
func nudge(dir: Vector3i) -> void:
	var step := 1.0 if nudge_whole else 0.5
	var plates := 3.0 if nudge_whole else 1.0
	var by := Vector3(dir.x * step * BrickPalette.STUD_M, dir.y * plates * BrickPalette.PLATE_M,
			dir.z * step * BrickPalette.STUD_M)
	if not _placed.is_empty():
		var before := models_state()
		var xf: Transform3D = _placed.xf
		_placed.xf = Transform3D(xf.basis, xf.origin + by)
		_held_moved(before)
		return
	move_field(Vector3(dir.x * step * BrickWorld.ticks_per_stud(), dir.y * plates * BrickWorld.ticks_per_plate(), dir.z * step * BrickWorld.ticks_per_stud()))


## The whole block-out moved `by` samples, one undo. Not once converted: bricks move with
## Move part (Alt G).
func move_field(by: Vector3) -> void:
	if sculpt_state == "bricks":
		_show_sculpt_note(true, "Converted: these are bricks. Move part (Alt G) moves them, or Edit as SDF first.")
		return
	if sculpt.form.block_count() == 0 or by == Vector3.ZERO:
		return
	sculpt.form.begin_edit()
	sculpt.form.move(by)
	sculpt.remesh()
	_sculpt_record(sculpt.form.end_edit())


## Line the placed model (else the block-out) up with the bricks: the near corner of its
## box on a whole stud along and across, its bottom on a plate. Then a box-shaped model
## converts to whole bricks instead of half-filled ones.
func snap_to_studs() -> void:
	if not _placed.is_empty():
		var bb := (_placed.xf as Transform3D) * (_placed.box as AABB)
		var s := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
		var by := (bb.position / s).round() * s - bb.position
		var before := models_state()
		var xf: Transform3D = _placed.xf
		_placed.xf = Transform3D(xf.basis, xf.origin + by)
		_held_moved(before)
		return
	if sculpt_state == "bricks" or sculpt.form.block_count() == 0:
		return
	# Samples: a cell starts at a multiple of 5 along and across, of 2 up.
	var lo := Vector3i(sculpt.form.bounds().position)
	var per := Vector3i(BrickWorld.ticks_per_stud(), BrickWorld.ticks_per_plate(), BrickWorld.ticks_per_stud())
	var by := Vector3i.ZERO
	for k in 3:
		var r := posmod(lo[k], per[k])
		by[k] = -r if r * 2 <= per[k] else per[k] - r
	move_field(Vector3(by))


## The sculpt panel's nudge row: the step, and a button each way.
func _build_nudge_row(box: Container) -> void:
	var row := HFlowContainer.new()
	box.add_child(row)
	var step := OptionButton.new()
	step.focus_mode = Control.FOCUS_NONE
	step.add_item("step: half stud (up: a plate)")
	step.add_item("step: 1 stud (up: a brick)")
	step.select(1 if nudge_whole else 0)
	step.item_selected.connect(func(i: int) -> void: nudge_whole = i == 1)
	row.add_child(step)
	for b in [["left", Vector3i(-1, 0, 0)], ["right", Vector3i(1, 0, 0)], ["up", Vector3i(0, 1, 0)],
			["down", Vector3i(0, -1, 0)], ["front", Vector3i(0, 0, 1)], ["back", Vector3i(0, 0, -1)]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.focus_mode = Control.FOCUS_NONE
		var d: Vector3i = b[1]
		btn.pressed.connect(func() -> void: nudge(d))
		row.add_child(btn)


# The gun's size on the grid ----------------------------------------------------------

func set_gun_class(c: String) -> void:
	if not GUN_CLASSES.has(c):
		return
	gun_class = c
	if _size_pick != null:
		_size_pick.select(GUN_CLASSES.keys().find(c))
	_size_sig = ""
	if game_view_on:
		_place_game_camera()


func set_size_marks(on: bool) -> void:
	size_marks_on = on
	_size_sig = ""


## Which end is the butt: the ruler runs from it toward the muzzle (muzzle_end, which
## export also reads off the build).
func flip_butt() -> void:
	muzzle_end = "-x" if muzzle_end == "+x" else "+x"
	_size_sig = ""
	_store_asset_meta()


## The sculpt panel's size row: the gun class, the marks on or off, which end is the butt.
func _build_size_row(box: Container) -> void:
	var row := HFlowContainer.new()
	box.add_child(row)
	_size_pick = OptionButton.new()
	_size_pick.focus_mode = Control.FOCUS_NONE
	for c in GUN_CLASSES:
		_size_pick.add_item("size: %s %s studs" % [GUN_CLASSES[c].name, String.num(class_studs(c), 1).trim_suffix(".0")])
	_size_pick.select(GUN_CLASSES.keys().find(gun_class))
	_size_pick.item_selected.connect(func(i: int) -> void: set_gun_class(GUN_CLASSES.keys()[i]))
	row.add_child(_size_pick)
	var marks := CheckBox.new()
	marks.text = "marks"
	marks.button_pressed = size_marks_on
	marks.focus_mode = Control.FOCUS_NONE
	marks.toggled.connect(func(on: bool) -> void: set_size_marks(on))
	row.add_child(marks)
	var flip := Button.new()
	flip.text = "turn ruler"
	flip.focus_mode = Control.FOCUS_NONE
	flip.pressed.connect(flip_butt)
	row.add_child(flip)


## The box the size marks and the game's view measure, workshop space: the placed model,
## else the field while sculpting, else the bricks. Empty with none of them.
func size_box() -> AABB:
	var boxes := []
	if sculpt != null and sculpt_state == "sdf":
		if sculpt.form.block_count() > 0:
			var bb := sculpt.form.bounds()
			if bb.size != Vector3.ZERO:
				boxes.append(global_transform.affine_inverse() * sculpt.global_transform * bb)
		for m in models:
			boxes.append((m.xf as Transform3D) * (m.box as AABB))
		# A lifted part is out of the field while it is held.
		if _held_kind() == "part":
			boxes.append((_placed.xf as Transform3D) * (_placed.box as AABB))
	if not boxes.is_empty():
		var out: AABB = boxes[0]
		for bx in boxes:
			out = out.merge(bx)
		return out
	if recipe.size() > 0:
		var b := recipe.bounds()
		var lo: Vector3i = b[0]
		var d: Vector3i = b[1]
		var s := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
		return AABB(Vector3(lo) * s, Vector3(d) * s)
	return AABB()


## The ruler's start (x of the butt, workshop space) and which way it runs (+1 / -1).
func size_ruler() -> Vector2:
	var dir := 1.0 if muzzle_end == "+x" else -1.0
	var bb := size_box()
	if bb.size == Vector3.ZERO:
		var mid := plate_studs * BrickPalette.STUD_M * 0.5
		return Vector2(mid - dir * class_studs() * BrickPalette.STUD_M * 0.5, dir)
	return Vector2(bb.position.x if dir > 0.0 else bb.end.x, dir)


## Drawn again when what they measure may have changed (an edit, the placed model, the
## class), looked at twice a second.
func _size_marks_process() -> void:
	# Models are drawn while the block-out is (not once converted).
	for m in models:
		(m.node as Node3D).visible = sculpt.visible and sculpt_state == "sdf"
	if sculpt_state != "sdf" and _held_kind() in ["model", "part"]:
		lay_model()
	if Time.get_ticks_msec() < _size_at:
		return
	_size_at = Time.get_ticks_msec() + 500
	var sig := "%s %s %s %d %d %s %s %s %d" % [size_marks_on, gun_class, muzzle_end, _edits.size(), _edit_groups.size(),
			sculpt_state, str(_placed.get("xf", "")), mirror_z, models.size()]
	if sig != _size_sig:
		_size_sig = sig
		draw_size_marks()


## The ruler along x on the plate from the butt -- a tick a stud, numbers every five, the
## class's length marked tall and banded -- and the shared grip's box.
func draw_size_marks() -> void:
	if _size_marks == null:
		_size_marks = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_size_marks.material_override = m
		_size_marks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_size_marks)
		_size_labels = Node3D.new()
		add_child(_size_labels)
	for c in _size_labels.get_children():
		c.queue_free()
	# Not in the game's view: it is to see the gun as the player will.
	var on := size_marks_on and not game_view_on
	_size_marks.visible = on
	_size_labels.visible = on
	if not on:
		return
	var S := BrickPalette.STUD_M
	var P := BrickPalette.PLATE_M
	var r := size_ruler()
	var dir := r.y
	var under := size_box()
	var y := (under.position.y if under.size != Vector3.ZERO else P) + 0.01
	var z := mirror_z * S
	var n := class_studs()
	var at := func(studs: float) -> float: return r.x + dir * studs * S
	var im := ImmediateMesh.new()
	# The band to the class's length, faint on the plate.
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var band := Color(1.0, 0.85, 0.3, 0.2)
	var x0: float = at.call(0.0)
	var x1: float = at.call(n)
	for q in [Vector3(x0, y, z - S), Vector3(x1, y, z - S), Vector3(x1, y, z + S),
			Vector3(x0, y, z - S), Vector3(x1, y, z + S), Vector3(x0, y, z + S)]:
		im.surface_set_color(band)
		im.surface_add_vertex(q)
	im.surface_end()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var line := func(a: Vector3, b: Vector3, col: Color) -> void:
		im.surface_set_color(col)
		im.surface_add_vertex(a)
		im.surface_set_color(col)
		im.surface_add_vertex(b)
	var past := ceili(n) + 6
	line.call(Vector3(x0, y, z), Vector3(at.call(past), y, z), Color(1.0, 0.92, 0.6, 0.9))
	for i in past + 1:
		var h := P * (4.0 if i % 10 == 0 else (2.5 if i % 5 == 0 else 1.0))
		var col := Color(1.0, 0.92, 0.6, 0.9) if i <= n else Color(0.7, 0.7, 0.7, 0.5)
		var x: float = at.call(float(i))
		line.call(Vector3(x, y, z), Vector3(x, y + h, z), col)
		if i % 5 == 0:
			_size_label(str(i), Vector3(x, y + h + P, z), col)
	var end := Color(1.0, 0.45, 0.25)
	line.call(Vector3(x1, y, z), Vector3(x1, y + P * 10.0, z), end)
	_size_label("%s: %s studs = %.0f mm real, %.0f mm print" % [GUN_CLASSES[gun_class].name,
			String.num(n, 1).trim_suffix(".0"), float(GUN_CLASSES[gun_class].real_mm),
			float(GUN_CLASSES[gun_class].real_mm) / REAL_PER_PRINT], Vector3(x1, y + P * 11.0, z), end)
	_size_label("butt", Vector3(x0, y + P * 6.0, z), Color(1.0, 0.92, 0.6))
	# The grip box: where the hand closes, the one size every gun keeps -- the smallest and
	# the largest it may be across, as tall as the least it must be.
	var g := Color(0.45, 0.95, 1.0)
	var rake := deg_to_rad(GRIP_RAKE_DEG)
	var up := Vector3(dir * sin(rake), cos(rake), 0.0)
	var fwd := Vector3(dir * cos(rake), -sin(rake), 0.0)
	var base := Vector3(at.call(n * GRIP_AT), y, z)
	var mm := PRINT_MM_PER_STUD
	var length := float(_grip_std.length_min) / mm * S
	for k in 2:
		var f := float(_grip_std.fore_aft[k]) / mm * S * 0.5
		var t := float(_grip_std.thick[k]) / mm * S * 0.5
		var col := g if k == 1 else Color(g, 0.5)
		var c := []
		for corner in 8:
			c.append(base + up * (length if corner & 4 else 0.0) + fwd * (f if corner & 1 else -f)
					+ Vector3(0, 0, t if corner & 2 else -t))
		for e in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
			line.call(c[e[0]], c[e[1]], col)
	_size_label("grip: the hand closes here, %s studs (%.0f mm print) or more" % [
			String.num(float(_grip_std.length_min) / mm, 1).trim_suffix(".0"), float(_grip_std.length_min)],
			base + up * (length + P * 2.0), g)
	im.surface_end()
	_size_marks.mesh = im


func _size_label(text: String, at: Vector3, col: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = at
	l.modulate = col
	l.font_size = 32
	l.outline_size = 8
	l.pixel_size = 0.012
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 5
	_size_labels.add_child(l)


# The game's view ----------------------------------------------------------------------

## The workshop's camera as the game's first-person one, framing the gun as PlayerView
## does (`_fit` and the hip pose): off, the camera goes back where it was.
func set_game_view(on: bool) -> void:
	if on == game_view_on:
		return
	if on:
		if size_box().size == Vector3.ZERO:
			_show_sculpt_note(true, "Nothing to hold yet: sculpt, place a model or lay bricks first.")
			return
		if view != 0:
			set_view(0)
		_game_view_was = {"xf": _camera.global_transform, "fov": _camera.fov, "near": _camera.near,
				"process": _camera.is_processing(), "physics": _camera.is_physics_processing(),
				"input": _camera.is_processing_unhandled_input()}
		if _camera.has_method("_set_captured"):
			_camera.call("_set_captured", false)
		_camera.set_process(false)
		_camera.set_physics_process(false)
		_camera.set_process_unhandled_input(false)
		game_view_on = true
		game_view_ads = false
		_place_game_camera()
		draw_size_marks()
	else:
		game_view_on = false
		var w := _game_view_was
		_camera.global_transform = w.xf
		_camera.fov = w.fov
		_camera.near = w.near
		_camera.set_process(w.process)
		_camera.set_physics_process(w.physics)
		_camera.set_process_unhandled_input(w.input)
		draw_size_marks()


## The camera where the game's would be: the gun scaled to its class's view length (the
## game scales every model to it), the top of its back end at the hip pose (or the sights'),
## muzzle ahead; the game's horizontal field of view.
func _place_game_camera() -> void:
	var bb := size_box()
	if bb.size.x <= 0.0:
		return
	var d := 1.0 if muzzle_end == "+x" else -1.0
	var length := float(PlayerView.VIEW_LENGTH.get(StringName(gun_class), PlayerView.VIEW_LENGTH_DEFAULT))
	var k := bb.size.x / length   # workshop metres a metre in the game's view
	var back_top := Vector3(bb.position.x if d > 0.0 else bb.end.x, bb.end.y, bb.get_center().z)
	var basis := Basis(Vector3(0, 0, d), Vector3.UP, Vector3(-d, 0, 0))
	var pose: Vector3 = PlayerView.ADS if game_view_ads else PlayerView.HIP
	_camera.global_transform = global_transform * Transform3D(basis, back_top - basis * (pose * k))
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	_camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(PlayerView.hfov) * 0.5) / aspect))
	_camera.near = 0.02 * k


## In the game's view: RMB aims down the sights and back, Escape leaves; other clicks do
## nothing (the view is to look). True when the event was the view's.
func _game_view_input(e: InputEvent) -> bool:
	if not game_view_on:
		return false
	if e is InputEventKey and e.pressed and not e.echo and (e as InputEventKey).keycode == KEY_ESCAPE:
		set_game_view(false)
		return true
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] and not _over_rail():
		if e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			game_view_ads = not game_view_ads
			_place_game_camera()
		return true
	return false
