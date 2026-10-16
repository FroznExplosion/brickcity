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
const KEYS_TEXT := "F10 instructions   F2 photos   F3 guide models   Alt 0-3 view   Alt M measure   Alt S mirror (shift: plane here)   Alt F free place   Alt D sketch   Alt U studs   Alt G move part   Alt E explode   Alt H hands   Alt P play   PgUp/PgDn working plane\nY part toolbar (shift: back)   hold LMB + move: lay a run   J connection point   K shapes   L select   O section   P outlines\nN part smooth / bricks   F4 wand from a photo   F12 export and preview   Z undo (a fill at once)   shift Z redo"

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

## The plate is bigger than the workshop's: a rifle is 62 studs long here. 80 studs is
## 400 ticks, and so is 200 plates, which keeps the build volume a cube.
const ASSET_PLATE_STUDS := 80
const ASSET_HEIGHT_PLATES := 200


func _init() -> void:
	plate_studs = ASSET_PLATE_STUDS
	height_plates = ASSET_HEIGHT_PLATES
	mirror_z = plate_studs * 0.5 + 0.5
	_ortho_size = plate_studs * BrickPalette.STUD_M * 0.75


func _ready() -> void:
	super()
	# What is made here is a gun (or a mech): File > Save, Save As and Open use their
	# library (user://guns/), not the buildings'. F5 has its own slot, not the workshop's.
	_save_path = ASSET_QUICK_SAVE
	if _menu != null:
		_menu.asset_mode(ASSET_KINDS)
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
		_look_at_build()
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
		set_view(v)
		for _i in 12:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "user://asset_shots/%s.png" % VIEWS[v]
		img.save_png(path)
		print("[asset workshop] wrote %s" % ProjectSettings.globalize_path(path))
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
			"mpp": plate_studs * BrickPalette.STUD_M * 0.9 / maxf(img.get_width(), 1.0),
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
	var mid := plate_studs * BrickPalette.STUD_M * 0.5
	match plane:
		"top":
			return Vector3(mid, BrickPalette.PLATE_M + 0.004, mid)
		"front":
			return Vector3(BrickPalette.STUD_M, mid * 0.5, mid)
	return Vector3(mid, mid * 0.5, BrickPalette.STUD_M)


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
	var w := plate_studs * BrickPalette.STUD_M
	var h := w * 0.4
	var z := mirror_z * BrickPalette.STUD_M
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var corners := [Vector3(0, 0.15, z), Vector3(w, 0.15, z), Vector3(w, h, z), Vector3(0, h, z)]
	for k in 4:
		im.surface_add_vertex(corners[k])
		im.surface_add_vertex(corners[(k + 1) % 4])
	im.surface_end()
	_mirror_sheet.mesh = im


# ---------------------------------------------------------------------------
# Flat views
# ---------------------------------------------------------------------------

func set_view(v: int) -> void:
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
	if _shape_brush_input(e) or _photo_input(e) or _zoom_input(e) or _sketch_input(e) or _stud_input(e) \
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
			KEY_D: set_tool("" if tool == "sketch" else "sketch")
			KEY_U: set_tool("" if tool == "stud" else "stud")
			KEY_G: set_tool("" if tool == "move" else "move")
			KEY_E: set_exploded(not exploded)
			KEY_H: set_hands(not hands_on)
			KEY_P: play_cycle()
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
	if _autosave_dirty and not _no_autosave and Time.get_ticks_msec() > _autosave_at:
		_autosave_dirty = false
		_autosave_at = Time.get_ticks_msec() + 4000
		recipe.save_to(AUTOSAVE)
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
		modes.append("SKETCH %s: draw on the %s plane, %d studs thick" % [part_names[part_sel], work_plane, width_of(part_names[part_sel])])
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
				"turn": g.turn, "opacity": g.opacity})
	recipe.meta["asset"] = {"photos": list, "mirror": {"on": mirror_on, "z": mirror_z},
			"parts": {"names": Array(part_names), "of": Array(part_of)}, "points": pts, "guides": gds,
			"smooth": Array(smooth_parts), "muzzle": muzzle_end, "part_width": part_width.duplicate(),
			"sketches": sketches, "part_bricks": part_bricks, "studs": extra_studs}   # not a copy: this runs on every edit, and a save writes it out as it is


func _restore_asset_meta() -> void:
	var a: Dictionary = recipe.meta.get("asset", {})
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
	muzzle_end = String(a.get("muzzle", "-x"))
	for g in a.get("guides", []):
		var i := load_guide(String(g.path), float(g.real_mm))
		if i >= 0:
			guides[i].offset = Vector3(float(g.offset[0]), float(g.offset[1]), float(g.offset[2]))
			guides[i].turn = int(g.get("turn", 0))
			guides[i].opacity = float(g.get("opacity", 0.35))
			_fit_guide(guides[i])
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
	part_of = PackedInt32Array()
	points = []
	if _points_root != null:
		_draw_points()
	for g in guides:
		(g.node as Node).queue_free()
	guides.clear()
	selection.clear()
	smooth_parts = PackedStringArray()
	_redo.clear()
	_edit_groups.clear()
	_deleted.clear()
	sketches.clear()
	part_bricks.clear()
	extra_studs.clear()
	_draw_studs()
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
const ASSET_KINDS := BuildRecipe.ASSET_KINDS


## A build here is one of the asset kinds; anything else (a build saved before guns had a
## library) becomes a gun.
func _set_asset_kind(k: String) -> void:
	recipe.kind = k if ASSET_KINDS.has(k) else "gun"
	if _menu != null:
		_menu.set_kind(recipe.kind)


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
		if not (name.begins_with("plate_") or name.begins_with("brick_")) or name == "plate_10x10":
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
func pack_cells(cells: Dictionary, random: bool = false, free: Dictionary = {}, course: int = 1 << 30) -> Array:
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
func place_named(arch: String, cell: Vector3i, colour: int = -1, mat: int = -1) -> bool:
	if not palette.has(arch) or _frame != 0:
		return false
	var id: int = palette[arch]
	if world.would_connect(chunk, cell, id) < 0 or not asm.can_place(chunk, cell, id):
		return false
	var c := _colour if colour < 0 else colour
	var m := _mat if mat < 0 else mat
	var placed := asm.place(chunk, cell, id, c)
	if placed < 0:
		return false
	if m != 0:
		world.set_block_material(chunk, placed, m)
	if not _redoing:
		_redo.clear()
	recipe.add(arch, cell, c, _recipe_frame_for(_frame), _role, m)
	_placed_at.append([_frame, placed])
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
	var fbx := path.get_extension().to_lower() == "fbx"
	var doc: GLTFDocument = FBXDocument.new() if fbx else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if fbx else GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("asset workshop: could not read %s" % path)
		return -1
	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		return -1
	var holder := Node3D.new()
	holder.add_child(scene)
	add_child(holder)
	var box := _model_box(scene, Transform3D())
	var g := {"path": path, "real_mm": real_mm, "offset": Vector3.ZERO, "turn": 0, "opacity": 0.35,
			"node": holder, "box": box}
	guides.append(g)
	_fit_guide(g)
	_store_asset_meta()
	_refresh_guide_panel()
	return guides.size() - 1


func _model_box(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var here := xf * (n as Node3D).transform if n is Node3D else xf
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out = here * (n as MeshInstance3D).mesh.get_aabb()
		first = false
	for c in n.get_children():
		var b := _model_box(c, here)
		if b.size == Vector3.ZERO:
			continue
		out = b if first else out.merge(b)
		first = false
	return out


## Size, turn, place and shade a guide: its longest side to `real_mm` at quarter scale,
## standing on the plate, centred on the mirror plane, then `offset` in studs.
func _fit_guide(g: Dictionary) -> void:
	var holder: Node3D = g.node
	var box: AABB = g.box
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if longest <= 0.0:
		return
	var k := float(g.real_mm) / (PRINT_MM_PER_STUD * REAL_PER_PRINT) * BrickPalette.STUD_M / longest
	var turn := Basis(Vector3.UP, int(g.turn) * PI * 0.5)
	var centre := box.get_center() * k
	var bottom := box.position.y * k
	var mid := plate_studs * BrickPalette.STUD_M * 0.5
	var at := Vector3(mid, BrickPalette.PLATE_M - bottom, mirror_z * BrickPalette.STUD_M) - turn * Vector3(centre.x, 0.0, centre.z)
	holder.transform = Transform3D(turn.scaled(Vector3.ONE * k), at + (g.offset as Vector3) * BrickPalette.STUD_M)
	_shade_guide(holder, float(g.opacity))


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
	t1.text = "Shapes (K): drag on the ghost's plane"
	_shape_box.add_child(t1)
	var kinds := OptionButton.new()
	for k in SHAPES:
		kinds.add_item(k)
	kinds.item_selected.connect(func(i: int) -> void: shape_kind = SHAPES[i])
	_shape_box.add_child(kinds)
	var fills := OptionButton.new()
	fills.add_item("clean: fewest bricks")
	fills.add_item("random: mixed sizes")
	fills.item_selected.connect(func(i: int) -> void: shape_fill = "clean" if i == 0 else "random")
	_shape_box.add_child(fills)
	var hrow := HBoxContainer.new()
	_shape_box.add_child(hrow)
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
	t4.text = "Sketch (Alt D) on the working plane"
	_sketch_box.add_child(t4)
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
	var sk_slopes := OptionButton.new()
	sk_slopes.add_item("slopes: own pitch only")
	sk_slopes.add_item("slopes: eager (1-3 plates)")
	sk_slopes.item_selected.connect(func(i: int) -> void:
		slope_eager = i == 1
		resketch(_sketch_key(), {}))
	_sketch_box.add_child(sk_slopes)
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
	_guide_dialog.filters = PackedStringArray(["*.glb, *.gltf, *.fbx ; Models"])
	_guide_dialog.file_selected.connect(func(path: String) -> void:
		load_guide(path, float(_guide_mm.text) if _guide_mm.text.is_valid_float() else 852.0))
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
	return any


## Shift Z: do the last undone group again -- each brick back in its own part, each
## delete taken up again, a sketch back to what it was.
func redo() -> int:
	if _redo.is_empty():
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
	var by_part := {}
	var x_lo := 1 << 30
	var x_hi := -(1 << 30)
	var y_lo := 1 << 30
	var z_lo := 1 << 30
	var z_hi := -(1 << 30)
	for i in recipe.size():
		if recipe.frame_of(i) != 0:
			continue
		var size := BrickPalette.size_of(recipe.part_of(i))
		var c := recipe.cell_of(i)
		x_lo = mini(x_lo, c.x)
		x_hi = maxi(x_hi, c.x + size.x)
		y_lo = mini(y_lo, c.y)
		z_lo = mini(z_lo, c.z)
		z_hi = maxi(z_hi, c.z + size.z)
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
			for i in ids:
				var size := BrickPalette.size_of(recipe.part_of(i))
				var c := recipe.cell_of(i)
				var x0: float = along.call(c.x) if muzzle_end == "-x" else along.call(c.x + size.x)
				bricks.append({"part": recipe.part_of(i), "min_mm": [x0, across.call(c.z), up.call(c.y)],
						"size": [size.x, size.z, size.y]})
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
[b]4. Build.[/b]  Bricks go where the cursor is on the working plane (free placement, Alt F to aim at studs instead); PgUp / PgDn move the plane. The tools are down the left, with the open tool's options under them; every key still works. [b]Saving:[/b] File > Save (Ctrl S), Save As (Ctrl Shift S) and Open (Ctrl O) keep guns in their own library (user://guns/), apart from the buildings; the build is also autosaved every few seconds. [b]Explode[/b] (Alt E) pulls the parts apart -- barrel forward, stock behind, grip and underbarrel under, sight over, a magazine out the way it sits -- and you keep building on them where they are drawn. [b]Move part[/b] (Alt G): drag a part across the view to move it whole, studs, sketch and points with it (one Z). [b]Hands[/b] (Alt H): the game's brick hands at the gun's scale, the right C round the grip, the left round the underbarrel (or the barrel). [b]Play[/b] (Alt P): three shots and a reload, the magazine out and back in -- the parts are baked into pieces of their own first. [b]Shape brush[/b], in any tool: Ctrl + LMB lays a ball, cube, cylinder, or a flat circle or square (on the plane the ghost is on -- hold E to lock its height, as for bricks); Ctrl + RMB carves the shape out of whatever is built, the rest of each brick it touches laid again. Hold and drag to keep going (one Z). Ctrl + wheel sizes it; its shape is on the left. [b]Studs[/b] (Alt U): LMB puts a stud on any face of any brick, a slope's too, on that face's half-stud lattice; RMB takes it off; shift LMB makes a stud a connection point (mount or socket), facing the way the stud does. LMB places one brick; hold it and drag to lay a row. RMB deletes (Z brings it back). R turns, F flips. Alt S mirrors: every brick is placed on the other side too.
[b]   Or sketch it.[/b]  Alt D, set the part's thickness, then draw on the working plane: LMB draws area in, RMB draws it out -- and takes up any brick under the stroke, a hand-laid one or another part's (untick [i]RMB erases any brick[/i] to keep them) -- and the part's bricks are worked out again each time (one Z undoes a change). An outline that crosses itself fills to its outermost line. Edges at a slope's or curve's pitch get slopes and curves, flipped under bottom edges; set slopes to [i]eager[/i] for more of them. Draw a drum magazine as a circle on the front plane (Alt 3). [b]Three views:[/b] the first plane a part is drawn on gives it its thickness; drawn for the same part on another plane (Alt 2 top, Alt 3 front, PgUp/PgDn to move it), area in keeps only what is inside it and area out cuts right through, or set [i]RMB cuts in[/i] to make a pocket so many studs deep. A blue line is the whole part from this plane, grey the other parts. Draw with an outline, a brush (its size and shape on the left), a rectangle, an ellipse, or a polygon of clicked corners (Enter, a double click or the first corner closes it).
[b]5. Smooth parts.[/b]  On a part that should be a smooth custom piece (stock, grip, handguard), press N. Its bricks are only its outline.
[b]6. Joints.[/b]  J where a part attaches: a [i]mount[/i] on the part, a [i]socket[/i] on the part it goes onto, same interface.
[b]7. Export.[/b]  F12 runs the part kit and shows the result and its checks here.

[font_size=18][b]Tools[/b][/font_size]
[b]F2[/b] photos   [b]F3[/b] guide models (an existing model to build inside, never exported)   [b]F4[/b] wand: click a colour patch on a photo to fill it
[b]Alt 0-3[/b] view: 3D, side, top, front   [b]Alt M[/b] measure: two clicks   [b]Alt S[/b] mirror (Alt shift S: plane under the ghost)
[b]Alt F[/b] free placement / aim at studs   [b]PgUp PgDn[/b] move the working plane   [b]Alt D[/b] sketch an outline   [b]Alt + drag[/b] move a photo
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
	var span := plate_studs * s
	var tall := height_plates * p
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
			for i in plate_studs + 1:
				line.call(Vector3(i * s, 0, z), Vector3(i * s, tall, z), i % 4 == 0)
			for j in range(0, height_plates + 1, 3):
				line.call(Vector3(0, j * p, z), Vector3(span, j * p, z), j % 12 == 0)
		"top":
			var y := work_height * p
			for i in plate_studs + 1:
				line.call(Vector3(i * s, y, 0), Vector3(i * s, y, span), i % 4 == 0)
				line.call(Vector3(0, y, i * s), Vector3(span, y, i * s), i % 4 == 0)
		"front":
			var x := work_x * s
			for i in plate_studs + 1:
				line.call(Vector3(x, 0, i * s), Vector3(x, tall, i * s), i % 4 == 0)
			for j in range(0, height_plates + 1, 3):
				line.call(Vector3(x, j * p, 0), Vector3(x, j * p, span), j % 12 == 0)
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
	var empty: bool = (sk.adds as Array).is_empty() and (sk.subs as Array).is_empty()
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
	var plan := _plan_volume(list, vol, free, {} if whole else only, {} if whole else near)
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
	_store_asset_meta()
	_group_with(ops, {"part": part, "before": before, "after": change.duplicate(),
			"bricks_before": bricks_before, "bricks_after": laid})
	return laid.size()


## Put a part's sketches and its brick list back as they were (`which`: "before") or as
## they became ("after"), for undo and redo; the bricks themselves are the edits'.
func _restore_sketch(g: Dictionary, which: String) -> void:
	var states: Dictionary = g.get(which, {})
	for k in states:
		_set_sketch(k, states[k])
	part_bricks[String(g.part)] = g.get("bricks_" + which, [])
	_part_vol.erase(String(g.part))
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
## many studs in from the face toward the camera when it was drawn.
func part_volume(list: Array) -> Dictionary:
	_course = 1 << 30
	_box = [Vector3i(1 << 30, 1 << 30, 1 << 30), -Vector3i(1 << 30, 1 << 30, 1 << 30)]
	var base := ""
	for e in list:
		if not (e[1].adds as Array).is_empty():
			base = e[1].plane
			break
	var vol := {}
	if base == "":
		return vol
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
	_course = (_box[0] as Vector3i).y
	for e in list:
		var sk: Dictionary = e[1]
		if sk.plane == base:
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
	return vol


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
	for e in list:
		var pl: String = e[1].plane
		if pl != "top" and not views.has(pl):
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
			pieces = edge_pieces(slices[k], slope_eager)
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
	var cells := {}
	for poly in sk.get("adds", []):
		for c in region_cells(poly):
			cells[c] = true
	if not cells.is_empty():
		for c in through_cuts(sk):
			cells.erase(c)
	return cells


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
static func edge_pieces(grid: Dictionary, eager: bool = false) -> Array:
	var out := _top_pieces(grid, {}, eager)
	var flipped := {}
	for g in grid:
		flipped[Vector2i(g.x, -g.y - 1)] = true
	var used := {}
	for pc in out:
		used[pc.u] = true
		used[pc.u + 1] = true
	for pc in _top_pieces(flipped, used, eager):
		# Back the right way up: the flipped box held plates base .. base + 2.
		pc.base = -pc.base - 3
		pc.under = true
		out.append(pc)
	return out


static func _top_pieces(grid: Dictionary, used_already: Dictionary = {}, eager: bool = false) -> Array:
	var top := {}
	for g in grid:
		top[g.x] = maxi(int(top.get(g.x, -(1 << 30))), g.y + 1)
	var out := []
	var used := used_already.duplicate()
	var us := top.keys()
	us.sort()
	# Slopes first. A slope's flat back sits over the higher column, its top level with that
	# column's; its low front over the lower column. At its own pitch the edge climbs two
	# plates a stud; eager, one to three, the slope a plate proud of or short of the line.
	var climbs := [1, 2, 3] if eager else [2]
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
	# Then curves: an end that rounds over -- a column two plates up from nothing (or from
	# two plates lower), then one more plate -- is a curve's profile, three plates in two
	# studs from its front edge.
	for u in us:
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
	return out


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
const RAIL_TOOLS := [["place", "Place", "Esc"], ["paint", "Paint", "B"], ["sketch", "Sketch", "Alt D"],
		["shape", "Shapes", "K"], ["select", "Select", "L"], ["stud", "Studs", "Alt U"],
		["move", "Move part", "Alt G"], ["measure", "Measure", "Alt M"]]
const SKETCH_DRAWS := [["outline", "outline (freehand)"], ["brush", "brush"], ["rect", "rectangle"],
		["ellipse", "ellipse"], ["polygon", "polygon (click corners)"]]
const PAINT_WHAT := [["both", "colour and material"], ["colour", "colour only"], ["material", "material only"]]

const RAIL_W := 184.0
const RAIL_FONT := 12
var sketch_draw := "outline"
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
	box.add_child(HSeparator.new())

	# The shape brush: Ctrl + LMB lays a shape, Ctrl + RMB carves it out, in any tool.
	_shape_box2 = VBoxContainer.new()
	box.add_child(_shape_box2)
	var sbt := Label.new()
	sbt.text = "Shape brush: Ctrl + LMB lays, Ctrl + RMB carves"
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
		_sketch.clear())
	_draw_box.add_child(draws)

	# The open tool's own options, which had a panel of their own.
	var inner := _tool_panel.get_child(0)
	_tool_panel.remove_child(inner)
	box.add_child(inner)
	_tool_panel.queue_free()
	_tool_panel = null
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


## Where things to the right of the rail start.
func _rail_right() -> float:
	return 12.0 if _rail == null else _rail.position.x + maxf(RAIL_W, _rail.size.x) + 12.0


## A rail button: the tool it names, everything else put down.
func rail_pick(id: String) -> void:
	match id:
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
	if _rail_buttons.has(tool):
		return tool
	return "place"


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
	_shape_box2.visible = on in ["place", "shape", "select"] or _shape_brush_on()
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
	_draws.select(SKETCH_DRAWS.map(func(d: Array) -> String: return d[0]).find(sketch_draw))


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
	exploded = on
	_display_dirty = true
	if not on:
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
	return _offsets.get(part, Vector3.ZERO) if exploded else Vector3.ZERO


## The offset the last mouse ray was taken in by: the part it met, else the current part.
func _ray_offset() -> Vector3:
	if not exploded:
		return Vector3.ZERO
	return part_offset(_ray_part if _ray_part != "" else part_names[part_sel])


## Each part as its own mesh -- its bricks laid again in a chunk of their own -- so the
## parts can be drawn apart (and, later, moved by the hands). Built again after an edit.
func _rebuild_display() -> void:
	_display_dirty = false
	_clear_display()
	_offsets = explode_offsets() if exploded else {}
	var by_part := {}
	for i in recipe.size():
		if recipe.frame_of(i) == 0:
			(by_part.get_or_add(part_names[part_of[i] if i < part_of.size() else part_sel], []) as Array).append(i)
	var base := world.get_chunk_transform(chunk)
	for name in by_part:
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


func _clear_display() -> void:
	for name in _display:
		(_display[name].mesh as Node).queue_free()
	_display.clear()


## Each frame, exploded: the parts built again if an edit changed them, the build itself
## hidden behind them, and what follows the mouse drawn where its part is.
func _explode_process() -> void:
	var apart := exploded or not _play.is_empty()
	for f in _frame_meshes:
		(_frame_meshes[f] as Node3D).visible = not apart
	if apart and _display_dirty:
		_rebuild_display()
	_play_process()
	_place_hands()
	if not exploded:
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
	if not exploded:
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
		var nk := "%s|%s|%s" % [part, moved.plane, _num(float(moved.at))]
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
	var d := Vector3(by)
	match String(sk.plane):
		"front": d = Vector3(by.z, by.y, by.x)
		"top": d = Vector3(by.x, by.z, by.y)
	var out := sk.duplicate()
	out.at = float(sk.at) + d.z
	out.adds = (sk.adds as Array).map(func(e: Variant) -> Variant: return _shift_entry(e, d.x, d.y))
	out.subs = (sk.subs as Array).map(func(e: Variant) -> Variant: return _shift_entry(e, d.x, d.y))
	return out


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
		if not exploded:
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
var shape_size := 4          # studs across (up: two and a half plates a stud)
var shape_thick := 1         # a flat shape's thickness: cells off its plane
var _sb := {}                # a stroke under way: {erase, start (edits), last (centre)}


func _shape_brush_on() -> bool:
	return Input.is_key_pressed(KEY_CTRL) or not _sb.is_empty()


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


func _stamp_shape(erase: bool) -> void:
	var centre := _shape_centre(erase)
	_sb.last = centre
	var cells := brush_shape_cells(brush3d, centre, shape_size, shape_axis(), shape_thick)
	# Counted, not read off the edit list: a brick taken up swaps its own edit for a delete.
	_sb.ops = int(_sb.get("ops", 0)) + (shape_carve(cells) if erase else shape_place(cells))


## Ctrl + LMB lays the shape, Ctrl + RMB carves it; held and dragged, it goes on doing
## it every half a shape. One stroke is one undo. Ctrl + wheel sizes it.
func _shape_brush_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.pressed and e.ctrl_pressed \
			and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		shape_size = clampi(shape_size + (1 if e.button_index == MOUSE_BUTTON_WHEEL_UP else -1), 1, SHAPE_SIZE_MAX)
		return true
	if e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if e.pressed and e.ctrl_pressed and _sb.is_empty():
			_sb = {"erase": e.button_index == MOUSE_BUTTON_RIGHT, "start": _edits.size(), "last": _cell,
					"button": e.button_index}
			_stamp_shape(bool(_sb.erase))
			return true
		if not e.pressed and not _sb.is_empty() and e.button_index == int(_sb.button):
			_group(int(_sb.get("ops", 0)))
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
