extends Node3D

## BUILD MODE in the mine world (Docs/MineWorld.md 8): break and place blocks
## from a hotbar, Minecraft's way, in brick.
##
##   B        build mode on/off (on foot or flying)
##   LMB      break the block looked at (held: keeps breaking)
##   RMB      place the selected block against the face looked at (held: repeats)
##   MMB      pick the block looked at into the selected slot
##   1-9, wheel   choose a slot
##   X        block size: 1x1, 2x2 or 4x4 studs, one brick tall
##
## A block is BrickTerrain's own edit: `fill_box` writes plate cells, the
## streamer rebakes the tiles behind the old ones (`host.terrain_edited`), so
## a placed block is ground like any other -- packed into pieces, studded,
## collided with, broken again by a shot. Blocks sit on a lattice of their
## size, so placed ones line up.
##
## While building, the mouse is the builder's: the gun neither fires nor aims
## (PlayerController.hold_fire), and slot keys and the wheel do not reach the
## arsenal or the fly speed.
##
## Preloaded by path, not named (see terrain_scene.gd).

const REACH := 6.0
const REPEAT := 0.22
const SIZES := [2, 1, 4]
const DEFAULT_HOTBAR := ["grass", "dirt", "stone", "dark stone", "sand", "sandstone",
		"gravel", "snow", "terracotta"]

var host: Node = null
var active := false
var slot := 0
var size_i := 0
var hotbar: Array[int] = []
## The ray's answer this frame (BrickTerrain.ray_cell), or empty.
var target := {}
var placed := 0
var broken := 0
## The last blocks placed and broken (block coordinates), for the gate.
var log_blocks: Array[String] = []

var _names: PackedStringArray
var _outline: MeshInstance3D
var _bar: HBoxContainer
var _bar_label: Label
var _slots: Array[Panel] = []
var _hold_break := 0.0
var _hold_place := 0.0


func setup(p_host: Node, hud_layer: CanvasLayer) -> void:
	host = p_host
	_names = BrickTerrain.material_names()
	for n in DEFAULT_HOTBAR:
		hotbar.append(maxi(_names.find(n), 1))
	_outline = MeshInstance3D.new()
	_outline.name = "Target"
	_outline.mesh = _box_lines()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.05, 0.05, 0.05)
	m.no_depth_test = false
	_outline.material_override = m
	_outline.visible = false
	_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_outline)
	_build_bar(hud_layer)


func block_studs() -> int:
	return SIZES[size_i]


func set_active(on: bool) -> void:
	active = on
	_bar.visible = on
	_bar_label.visible = on
	if not on:
		_outline.visible = false
		target = {}
	var player: PlayerController = host.player
	if player != null:
		player.hold_fire = on
	var view: PlayerView = host.view
	if view != null and host.on_foot:
		view.rig.visible = not on
	_refresh_bar()


## The view changed hands (walk/fly): the gun shows again only on foot and
## only out of build mode.
func on_mode_changed() -> void:
	var view: PlayerView = host.view
	if view != null and host.on_foot:
		view.rig.visible = not active


# ---------------------------------------------------------------------------
# Input: first, before the arsenal, the camera and the walker see it.

func _input(event: InputEvent) -> void:
	if host == null or host.get("_gate") or host.get("_menu") != null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_B:
			set_active(not active)
			get_viewport().set_input_as_handled()
			return
		if not active:
			return
		if k == KEY_X:
			size_i = (size_i + 1) % SIZES.size()
			_refresh_bar()
			get_viewport().set_input_as_handled()
		elif k >= KEY_1 and k <= KEY_9:
			slot = k - KEY_1
			_refresh_bar()
			get_viewport().set_input_as_handled()
		return
	if not active or not (event is InputEventMouseButton):
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not PlayerCamera.hands_off:
		return            # a click that captures the mouse is the camera's
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			break_target()
			_hold_break = REPEAT * 1.5
		MOUSE_BUTTON_RIGHT:
			place_target()
			_hold_place = REPEAT * 1.5
		MOUSE_BUTTON_MIDDLE:
			pick_target()
		MOUSE_BUTTON_WHEEL_UP:
			slot = (slot + hotbar.size() - 1) % hotbar.size()
			_refresh_bar()
		MOUSE_BUTTON_WHEEL_DOWN:
			slot = (slot + 1) % hotbar.size()
			_refresh_bar()
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not active or host == null:
		return
	update_target()
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_hold_break -= delta
		if _hold_break <= 0.0:
			break_target()
			_hold_break = REPEAT
	if captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_hold_place -= delta
		if _hold_place <= 0.0:
			place_target()
			_hold_place = REPEAT


# ---------------------------------------------------------------------------
# The block looked at

func update_target() -> void:
	var c: Camera3D = host._eye_camera()
	var from := c.global_position
	var dir := -c.global_transform.basis.z
	target = BrickTerrain.ray_cell(from, dir, REACH)
	if target.is_empty():
		_outline.visible = false
		return
	var b := _block_of(target.cell)
	var lo := _cell_lo(b)
	var size := _block_size_m()
	_outline.visible = true
	_outline.global_transform = Transform3D(Basis.from_scale(size * 1.004), lo - size * 0.002)


## The block (on this size's lattice) holding plate cell `cell`.
func _block_of(cell: Vector3i) -> Vector3i:
	var s := block_studs()
	return Vector3i(floori(float(cell.x) / s), floori(float(cell.y) / 3.0), floori(float(cell.z) / s))


func _cell_lo(block: Vector3i) -> Vector3:
	var s := block_studs()
	var stud := BrickWorld.get_stud_metres()
	return Vector3(block.x * s * stud, block.y * 3 * BrickWorld.get_plate_metres(), block.z * s * stud)


func _block_size_m() -> Vector3:
	var s := block_studs()
	var stud := BrickWorld.get_stud_metres()
	return Vector3(s * stud, 3.0 * BrickWorld.get_plate_metres(), s * stud)


## Plate-cell bounds (inclusive) of a block.
func _cells(block: Vector3i) -> Array[Vector3i]:
	var s := block_studs()
	var lo := Vector3i(block.x * s, block.y * 3, block.z * s)
	return [lo, lo + Vector3i(s - 1, 2, s - 1)]


func break_target() -> bool:
	if target.is_empty():
		update_target()
		if target.is_empty():
			return false
	var c := _cells(_block_of(target.cell))
	var res: Dictionary = BrickTerrain.fill_box(c[0], c[1], 0, false)
	if int(res.changed) == 0:
		return false
	broken += 1
	log_blocks.append("break %s" % _block_of(target.cell))
	host.terrain_edited(res)
	target = {}
	return true


func place_target() -> bool:
	if target.is_empty():
		update_target()
		if target.is_empty():
			return false
	var b := _block_of(target.cell)
	var n: Vector3i = target.normal
	var to := b + n
	var c := _cells(to)
	if _blocks_player(to):
		return false
	var res: Dictionary = BrickTerrain.fill_box(c[0], c[1], hotbar[slot], true)
	if int(res.changed) == 0:
		return false
	placed += 1
	log_blocks.append("place %s" % to)
	host.terrain_edited(res)
	target = {}
	return true


func pick_target() -> void:
	if target.is_empty():
		return
	var m := int(target.material)
	var i := hotbar.find(m)
	if i >= 0:
		slot = i
	else:
		hotbar[slot] = m
	_refresh_bar()


## Would a block there stand inside the player?
func _blocks_player(block: Vector3i) -> bool:
	var box := AABB(_cell_lo(block), _block_size_m())
	var feet: Vector3
	if host.on_foot:
		feet = (host.pawn as Pawn).feet()
	else:
		feet = (host.walker as Node3D).global_position
	var me := AABB(feet - Vector3(0.3, 0.0, 0.3), Vector3(0.6, 1.75, 0.6))
	return box.intersects(me)


# ---------------------------------------------------------------------------
# The hotbar

func _build_bar(layer: CanvasLayer) -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 4)
	_bar.anchor_left = 0.5
	_bar.anchor_right = 0.5
	_bar.anchor_top = 1.0
	_bar.anchor_bottom = 1.0
	_bar.offset_left = -9 * 26
	_bar.offset_right = 9 * 26
	_bar.offset_top = -120
	_bar.offset_bottom = -72
	_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_bar)
	for i in hotbar.size():
		var p := Panel.new()
		p.custom_minimum_size = Vector2(48, 48)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var swatch := ColorRect.new()
		swatch.name = "Swatch"
		swatch.position = Vector2(8, 8)
		swatch.size = Vector2(32, 32)
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(swatch)
		var num := Label.new()
		num.text = str(i + 1)
		num.position = Vector2(3, 0)
		num.add_theme_font_size_override("font_size", 11)
		num.add_theme_color_override("font_outline_color", Color.BLACK)
		num.add_theme_constant_override("outline_size", 3)
		p.add_child(num)
		_bar.add_child(p)
		_slots.append(p)
	_bar_label = Label.new()
	_bar_label.anchor_left = 0.5
	_bar_label.anchor_right = 0.5
	_bar_label.anchor_top = 1.0
	_bar_label.anchor_bottom = 1.0
	_bar_label.offset_left = -300
	_bar_label.offset_right = 300
	_bar_label.offset_top = -146
	_bar_label.offset_bottom = -122
	_bar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bar_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_bar_label.add_theme_constant_override("outline_size", 4)
	root.add_child(_bar_label)
	_bar.visible = false
	_bar_label.visible = false
	_refresh_bar()


func _refresh_bar() -> void:
	if _bar == null:
		return
	for i in _slots.size():
		var p := _slots[i]
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.08, 0.08, 0.1, 0.75)
		sb.set_border_width_all(3 if i == slot else 1)
		sb.border_color = Color(1, 1, 1) if i == slot else Color(0.35, 0.35, 0.4)
		p.add_theme_stylebox_override("panel", sb)
		var col := BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(hotbar[i]))
		(p.get_node("Swatch") as ColorRect).color = col
	var s := block_studs()
	_bar_label.text = "BUILD  %s  -  block %dx%d studs, 1 brick  (B exit  X size  MMB pick)" % [
			_names[hotbar[slot]], s, s]


static func _box_lines() -> ArrayMesh:
	var v := PackedVector3Array()
	var c := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
			Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]
	for e in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]]:
		v.append(c[e[0]])
		v.append(c[e[1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return m
