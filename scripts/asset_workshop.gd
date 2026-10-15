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
##               cursor in a flat view (Alt or Ctrl + wheel), Alt + drag moves a photo, and
##               buttons that put it behind the build or through its middle
##   sketch      Alt D: draw an outline on the side plane; it is filled with bricks for
##               the current part, as thick as that part is set to be
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
const KEYS_TEXT := "F10 instructions   F2 photos   F3 guide models   Alt 0-3 view   Alt M measure   Alt S mirror (shift: plane here)   Alt F free place   Alt D sketch   PgUp/PgDn working plane\nY part toolbar (shift: back)   hold LMB + move: lay a run   J connection point   K shapes   L select   O section   P outlines\nN part smooth / bricks   F4 wand from a photo   F12 export and preview   Z undo (a fill at once)   shift Z redo"

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
	if "--ramp" in OS.get_cmdline_user_args():
		# A sketched ramp climbing a slope's pitch, to look at the slopes it lays.
		for _i in 3:
			await get_tree().process_frame
		sketch_fill([Vector2(30, 24), Vector2(46, 24), Vector2(46, 48), Vector2(42, 48)])
		_look_at_build()
	DirAccess.make_dir_recursive_absolute("user://asset_shots")
	for v in [0, 1]:
		set_view(v)
		for _i in 12:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "user://asset_shots/%s.png" % VIEWS[v]
		img.save_png(path)
		print("[asset workshop] wrote %s" % ProjectSettings.globalize_path(path))
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
	if _photo_input(e) or _zoom_input(e) or _sketch_input(e):
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
	_ruler.position = Vector2(12, vp.y - 136 - _ruler.size.y)
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
		modes.append("SKETCH %s: draw on the side plane, %d studs thick" % [part_names[part_sel], width_of(part_names[part_sel])])
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
	hint.text = "Alt + drag moves the photo.  Alt / Ctrl + wheel zooms a flat view."
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
			"smooth": Array(smooth_parts), "muzzle": muzzle_end, "part_width": part_width.duplicate()}


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
	for p in photos:
		(p.node as Node).queue_free()
	photos.clear()
	photo_sel = -1
	measure_points.clear()
	if _measure_line != null:
		_draw_measure()


func _load_recipe(r: BuildRecipe) -> void:
	# The workshop's load ends in an edit, and an edit saves this scene's state into the
	# recipe: while loading, that state is still the last build's, so it waits.
	_loading = true
	super._load_recipe(r)
	_loading = false
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
	_store_asset_meta()
	_outlines_dirty = true
	_autosave_dirty = true
	if recipe.size() == 0:
		_ensure_start_brick.call_deferred()


func _delete_ray(from: Vector3, dir: Vector3) -> bool:
	var hit := _first_hit(from, dir)
	if not hit.is_empty():
		_removing = _recipe_id_at(asm.frames.find(hit.frame), hit.block)
	var done := super._delete_ray(from, dir)
	if not done:
		_removing = -1
	return done


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


## Lay the held brick where the ghost has moved to, if it fits there.
func run_step() -> void:
	if not _run_on or _cell == _run_last:
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
func toggle_point(at: Array, kind: String, slot: String, iface: String) -> bool:
	for i in points.size():
		if points[i].at == at:
			points.remove_at(i)
			_draw_points()
			_store_asset_meta()
			return false
	points.append({"part": part_names[part_sel], "kind": kind, "slot": slot, "interface": iface, "at": at})
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
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	_fill_point_ifaces()


func _build_point_panel(layer: CanvasLayer) -> void:
	_point_panel = PanelContainer.new()
	_point_panel.visible = false
	_point_panel.position = Vector2(12, 300)
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
					_point_iface.get_item_text(_point_iface.selected))
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
				float(at[2]) * BrickPalette.STUD_M)
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
func pack_cells(cells: Dictionary, random: bool = false) -> Array:
	var left := cells.duplicate()
	var parts := fill_parts()
	var out := []
	if left.is_empty():
		return out
	var ys := {}
	for c in left:
		ys[c.y] = true
	var layers := ys.keys()
	layers.sort()
	var base: int = layers[0]
	for y in layers:
		var flip: bool = (y - base) % 2 == 1
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
				if size.y > 1 and (y - base) % 3 != 0:
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
func fill_cells(cells: Dictionary, random: bool = false) -> int:
	var laid := 0
	_batch = true
	for pc in pack_cells(cells, random):
		if place_named(pc[0], pc[1]):
			laid += 1
	_batch = false
	_after_edit()
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
	_tool_panel.visible = t != ""
	_shape_box.visible = t == "shape"
	_select_box.visible = t == "select"
	if t == "" :
		selection.clear()
	_sketch.clear()
	_shape_box.get_parent().get_parent().visible = t in ["shape", "select", "sketch"]
	_sketch_box.visible = t == "sketch"
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
	if tool == "sketch" and _sketch.size() >= 2:
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		var z := work_depth * BrickPalette.STUD_M
		for q in _sketch + [_sketch[0]]:
			im.surface_set_color(Color(1.0, 0.9, 0.2))
			im.surface_add_vertex(Vector3(q.x * BrickPalette.STUD_M, q.y * BrickPalette.PLATE_M, z))
		im.surface_end()
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
	t4.text = "Sketch (Alt D): draw an outline on the side plane"
	_sketch_box.add_child(t4)
	var wrow := HBoxContainer.new()
	_sketch_box.add_child(wrow)
	var wl := Label.new()
	wl.text = "this part's thickness, studs"
	wrow.add_child(wl)
	_width_spin = SpinBox.new()
	_width_spin.min_value = 1
	_width_spin.max_value = 20
	_width_spin.value = 3
	_width_spin.value_changed.connect(func(v: float) -> void:
		part_width[part_names[part_sel]] = int(v)
		_store_asset_meta())
	wrow.add_child(_width_spin)
	var sk_fill := OptionButton.new()
	sk_fill.add_item("clean: fewest bricks")
	sk_fill.add_item("random: mixed sizes")
	sk_fill.item_selected.connect(func(i: int) -> void: shape_fill = "clean" if i == 0 else "random")
	_sketch_box.add_child(sk_fill)

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


## Z: a fill, a copy or a mirrored pair goes at once; anything else one edit at a time.
func _undo() -> bool:
	var n := 1
	if not _edit_groups.is_empty() and int(_edit_groups.back().end) == _edits.size():
		n = int(_edit_groups.pop_back().n)
	var group := []
	var any := false
	for _k in n:
		var b = _last_brick()
		if not super._undo():
			break
		any = true
		if b != null:
			group.append(b)
	if not group.is_empty():
		_redo.append(group)
	return any


## Shift Z: lay the last undone group again, each brick back in its own part.
func redo() -> int:
	if _redo.is_empty():
		return 0
	var group: Array = _redo.pop_back()
	group.reverse()
	_redoing = true
	var keep := part_sel
	var laid := 0
	_batch = true
	for b in group:
		part_sel = int(b.tag)
		if place_named(b.arch, b.cell, b.colour, b.mat):
			laid += 1
	_batch = false
	part_sel = keep
	_after_edit()
	_group(laid)
	_redoing = false
	return laid


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
	for q in points:
		var at: Array = q.at
		var joint := {"at": [snappedf(along.call(float(at[0])), 0.001), snappedf(up.call(float(at[1])), 0.001)],
				"interface": q.interface}
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
[b]2. Look at it flat.[/b]  Alt 1 for the side view (Alt 2 top, Alt 3 front, Alt 0 back to 3D). Alt or Ctrl + wheel zooms where the cursor is, WASD moves. ESC frees the mouse for the panels. Tick [i]stud grid on the photo[/i] in F2 to check its size.
[b]3. Pick the part.[/b]  Y (shift Y back) to body, barrel, stock, grip ... Every brick you lay belongs to the part you are on, and each part keeps its own 9 toolbar slots.
[b]4. Build.[/b]  Bricks go where the cursor is on the working plane (free placement, Alt F to aim at studs instead); PgUp / PgDn move the plane. LMB places, hold LMB and move to lay a row, RMB deletes, R turns, F flips. Alt S mirrors: every brick is placed on the other side too.
[b]   Or sketch it.[/b]  Alt D, set the part's thickness, then draw its outline on the side plane: it fills with bricks.
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


## Alt or Ctrl + wheel in a flat view: zoom about the point under the cursor.
func _zoom_input(e: InputEvent) -> bool:
	if view == 0 or not (e is InputEventMouseButton) or not e.pressed:
		return false
	if not (e.alt_pressed or e.ctrl_pressed):
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


func _sketch_input(e: InputEvent) -> bool:
	if tool != "sketch":
		return false
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_sketch.clear()
			_sketch_add()
		else:
			if _sketch.size() >= 3:
				sketch_fill(_sketch)
			_sketch.clear()
		return true
	if e is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _sketch.is_empty():
		_sketch_add()
		return true
	return false


func _sketch_add() -> void:
	var keep := work_plane
	work_plane = "side"
	var ray := _mouse_ray()
	var hit = work_plane_hit(ray[0], ray[1])
	work_plane = keep
	if hit == null:
		return
	var q := Vector2((hit as Vector3).x / BrickPalette.STUD_M, (hit as Vector3).y / BrickPalette.PLATE_M)
	if _sketch.is_empty() or q.distance_to(_sketch.back()) > 0.3:
		_sketch.append(q)


## Fill an outline drawn on the side plane -- points in (studs along, plates up) -- with
## bricks for the current part, as thick as the part is set to be, centred on the
## working depth. Every cell whose middle is inside the outline is filled, and where the
## top edge climbs in steps of two plates a stud -- a slope's own pitch -- the step is a
## slope instead of a staircase. One undo.
func sketch_fill(outline: Array) -> int:
	if outline.size() < 3:
		return 0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in outline:
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var w := width_of(part_names[part_sel])
	var z0 := int(round(work_depth - w * 0.5))
	var columns := {}
	for x in range(int(floor(lo.x)), int(ceil(hi.x))):
		for y in range(maxi(int(floor(lo.y)), 0), int(ceil(hi.y))):
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), PackedVector2Array(outline)):
				columns[Vector2i(x, y)] = true
	var slopes := top_slopes(columns)
	var cells := {}
	for c in columns:
		for k in w:
			cells[Vector3i(c.x, c.y, z0 + k)] = true
	var placements := []
	for sl in slopes:
		var x: int = sl.x
		var b: int = sl.base
		for dx in 2:
			for dy in 3:
				for k in w:
					cells.erase(Vector3i(x + dx, b + dy, z0 + k))
		# Two wide where the part allows, one wide for what is left.
		var k := 0
		while k < w:
			var wide := 2 if w - k >= 2 else 1
			placements.append([slope_variant(wide, sl.rises), Vector3i(x, b, z0 + k)])
			k += wide
	var laid := 0
	_batch = true
	for pc in pack_cells(cells, shape_fill == "random"):
		if place_named(pc[0], pc[1]):
			laid += 1
	for pl in placements:
		if place_named(pl[0], pl[1]):
			laid += 1
	_batch = false
	_after_edit()
	_group(laid)
	return laid


## Where a slope goes on the top edge of a side-view fill (Vector2i(stud along, plate
## up) -> true): wherever one column's top is exactly two plates above its neighbour's.
## The slope sits over the lower column and the higher one -- its low front over the
## lower, its flat back over the higher -- with its base a plate below the lower top.
## [{x: its first column, base: its bottom plate, rises: +1 if it climbs along +x}]
static func top_slopes(columns: Dictionary) -> Array:
	var top := {}
	for c in columns:
		top[c.x] = maxi(int(top.get(c.x, -1)), c.y + 1)
	var out := []
	var used := {}
	var xs := top.keys()
	xs.sort()
	for x in xs:
		if not top.has(x + 1) or used.has(x) or used.has(x + 1):
			continue
		var d: int = top[x + 1] - top[x]
		if absi(d) != 2:
			continue
		var low: int = x if d > 0 else x + 1
		var base: int = top[low] - 1
		# The whole box under the slope has to be the part's: no slope over a gap.
		var solid := true
		for dx in 2:
			if not columns.has(Vector2i(x + dx, base)):
				solid = false
		if not solid:
			continue
		out.append({"x": x, "base": base, "rises": 1 if d > 0 else -1})
		used[x] = true
		used[x + 1] = true
	return out


## The slope that is `wide` studs across, 2 long along the gun, with its low front
## toward -x if it `rises` along +x, else toward +x.
func slope_variant(wide: int, rises: int) -> String:
	var part := "slope_1x2" if wide == 1 else "slope_2x2"
	var want := Vector3i(-1, 0, 0) if rises > 0 else Vector3i(1, 0, 0)
	for yaw in 4:
		var name := BrickPalette.variant_name(part, yaw, false)
		if BrickPalette.front_of(name) == want and BrickPalette.size_of(name).x == 2:
			return name
	return BrickPalette.variant_name(part, 0, false)
