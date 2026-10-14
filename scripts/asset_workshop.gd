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
const KEYS_TEXT := "F2 photos   F6 view   F7 measure   F8 mirror (shift: plane under the ghost)   Home / End zoom a flat view\nY part toolbar (shift: back)   hold LMB + move: lay a run   J connection point"

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
	if "--shot" in args:
		call_deferred("_shot")
	elif not ("--gate" in args):
		print("[asset workshop] " + KEYS_TEXT)


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
	set_mirror(true)
	DirAccess.make_dir_recursive_absolute("user://asset_shots")
	for v in [0, 1]:
		set_view(v)
		for _i in 12:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var path := "user://asset_shots/%s.png" % VIEWS[v]
		img.save_png(path)
		print("[asset workshop] wrote %s" % ProjectSettings.globalize_path(path))
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
			"centre": _default_centre(plane), "opacity": 0.6, "shown": true, "node": node}
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
	if mirror_on and recipe.size() > before and _frame == 0:
		_place_mirrored()


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
		return
	# Looking straight at the build. The camera's own click-to-look is off: a flat view
	# is built in with the cursor, and a captured mouse would turn it.
	_camera.set_process_unhandled_input(false)
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", false)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = _ortho_size
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
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
			and (calibrating != null or measure_on):
		if calibrating != null:
			_calibrate_click()
		else:
			_measure_click()
		get_viewport().set_input_as_handled()
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and not _painting and _stamp == null:
			_run_on = true
			_run_last = _cell
		elif not e.pressed:
			_run_on = false
	if e is InputEventKey and e.pressed and not e.echo and not e.ctrl_pressed:
		var mine := true
		match e.keycode:
			KEY_Y: select_part(part_sel + (-1 if e.shift_pressed else 1))
			KEY_J: toggle_point_here()
			KEY_F2: _toggle_panel()
			KEY_F6: set_view((view + 1) % VIEWS.size())
			KEY_F7: set_measure(not measure_on)
			KEY_F8:
				if e.shift_pressed:
					mirror_here()
				else:
					set_mirror(not mirror_on)
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
	_part_label.text = "part %d of %d: %s   (Y next, shift Y back)" % [
			part_sel + 1, part_names.size(), part_names[part_sel].to_upper()]
	_part_label.modulate = PART_COLOURS[part_sel % PART_COLOURS.size()]
	_part_label.position = Vector2((get_viewport().get_visible_rect().size.x - _part_label.size.x) * 0.5,
			get_viewport().get_visible_rect().size.y - 104)
	var vp := get_viewport().get_visible_rect().size
	_ruler.position = Vector2(12, vp.y - 210)
	_ruler.text = ruler_text()
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
	if mirror_on:
		modes.append("mirror at %s studs across" % _num(mirror_z))
	if measure_on:
		modes.append("MEASURE: click two points")
	if calibrating != null:
		modes.append("CALIBRATE: click point %d of 2 on the photo" % ((calibrating as Array).size() + 1))
	lines.append("   ".join(modes))
	if measure_on and measure_points.size() == 2:
		lines.append(measure_text(measure_points[0], measure_points[1]).replace("\n", "   "))
	lines.append(KEYS_TEXT)
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
	_length_edit.placeholder_text = "mm on the real thing, e.g. 852"
	_length_dialog.add_child(_length_edit)
	_length_dialog.confirmed.connect(func() -> void:
		var pts: Array = _length_dialog.get_meta("points", [])
		if pts.size() == 2 and _length_edit.text.is_valid_float():
			calibrate(photo_sel, pts[0], pts[1], float(_length_edit.text)))
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
	recipe.meta["asset"] = {"photos": list, "mirror": {"on": mirror_on, "z": mirror_z},
			"parts": {"names": Array(part_names), "of": Array(part_of)}, "points": pts}


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
	_reconcile_parts()
	_load_toolbar(part_names[part_sel])


## Make part `i` current: its toolbar comes up, and the bricks laid from now are its.
func select_part(i: int) -> void:
	toolbars[part_names[part_sel]] = _hotbar.slots.duplicate(true)
	part_sel = posmod(i, part_names.size())
	_load_toolbar(part_names[part_sel])
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
	super._hold_lock(on or _run_on)


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
