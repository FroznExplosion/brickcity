class_name WorkshopHotbar
extends CanvasLayer

## The workshop's hotbar and parts browser: Minecraft's creative mode, for bricks.
##
## Nine slots along the bottom of the screen. Each holds a PART and a COLOUR --
## a red 2x4 and a white 2x4 are two slots, the way two colours of wool are two
## items -- and the one selected is what the ghost is. 1-9 or the wheel pick a
## slot. TAB opens the browser: every part, grouped by what it does
## (BrickPalette.CATEGORIES), with a search box and the colours; clicking a part
## or a colour puts it in the selected slot. The hotbar is remembered between
## sessions.
##
## Drag and drop, as in the creative inventory: drag a part from the browser
## onto any slot; drag it across a MATERIAL or a colour on the way and it takes
## them; drag a colour or a material onto a slot to repaint it; drag one slot
## onto another to swap them.
##
## A slot is a part, a MATERIAL and a colour. What the colour means depends on
## the material (BrickWorld.get_material_colour): a filament -- PLA, ABS, TPU --
## takes any colour off the filament palette; wood, metal and stone have their
## own lists, oak to ebony, steel to gold. The colour row shows whichever list
## the selected slot's material has.
##
## It owns no placement. It says what is selected (`changed`), and the workshop
## sets its part and colour from that -- so everything that sets them directly
## (the probes, the stair builder) still works exactly as before.

## Emitted whenever the selected slot or what is in it changes.
signal changed(part: String, colour: int, material: int)
## The browser opened or closed: the workshop frees or recaptures the mouse.
signal browsing_changed(on: bool)

const SLOTS := 9
const SAVE := "user://workshop_hotbar.json"
## Where it is remembered. A probe points it elsewhere so a test run cannot
## rearrange somebody's toolbar.
var save_path := SAVE
const SLOT_PX := 64
const ICON_PX := 96
## What a first-time hotbar holds: one of most things, in a few colours.
const DEFAULTS := [
	["brick_2x4", 4], ["brick_2x2", 6], ["brick_1x4", 0], ["plate_2x4", 8],
	["plate_4x4", 2], ["tile_2x2", 11], ["slope_2x2", 4], ["bracket_1x2", 7],
	["arch_1x4", 5],
]

var slots := []          ## [[part, colour, material], ...]; part "" is empty
var selected := 0

## Called with a part name, returns [ArrayMesh, MultiMesh] of it: the workshop's
## own ghost builder, so an icon is exactly the piece that will be placed.
var mesh_for := Callable()

var _bar: HBoxContainer
var _slot_nodes := []    ## [{panel, icon, label, key}]
var _browser: PanelContainer
var _grid: GridContainer
var _search: LineEdit
var _tabs: TabBar
var _title: Label
var _icons := {}         ## part -> Texture2D, filled in as they render
var _icon_queue := []
var _viewport: SubViewport
var _icon_mesh: MeshInstance3D
var _icon_studs: MultiMeshInstance3D
var _icon_cam: Camera3D
var _slot_style: StyleBoxFlat
var _slot_style_on: StyleBoxFlat
## The picture following the cursor during a drag, so a colour it passes over
## can tint it.
var _drag_preview: TextureRect
var _swatches: GridContainer
var _materials: HBoxContainer
var _swatch_label: Label


func _ready() -> void:
	layer = 5
	_load()
	_build_bar()
	_build_browser()
	_build_icon_stage()
	for p in BrickPalette.parts():
		_icon_queue.append(p)
	_refresh()
	changed.emit(part(), colour(), material())


# ---------------------------------------------------------------------------
# What is selected
# ---------------------------------------------------------------------------

func part() -> String:
	return str(slots[selected][0])


func colour() -> int:
	return int(slots[selected][1])


func material() -> int:
	return int(slots[selected][2])


## A slot's colour as it will be drawn, opaque: the material's alpha is for the
## shaders, and a UI tinted with it would come out see-through.
static func rgb(m: int, c: int) -> Color:
	var x := BrickWorld.get_material_colour(m, c)
	x.a = 1.0
	return x


static func _count(m: int) -> int:
	return maxi(BrickWorld.get_material_colour_count(m), 1)


func select(i: int) -> void:
	selected = posmod(i, SLOTS)
	_rebuild_swatches()
	_refresh()
	_save()
	changed.emit(part(), colour(), material())


func step(d: int) -> void:
	select(selected + d)


## Put a part in the selected slot, keeping its colour.
func set_part(p: String) -> void:
	slots[selected][0] = p
	_refresh()
	_save()
	changed.emit(part(), colour(), material())


func set_colour(c: int) -> void:
	slots[selected][1] = posmod(c, _count(material()))
	_refresh()
	_save()
	changed.emit(part(), colour(), material())


## Change what the selected slot is made of. Its colour index is kept where
## the new material's list is long enough, and wrapped into it where not.
func set_material(m: int) -> void:
	slots[selected][2] = clampi(m, 0, BrickWorld.get_material_count() - 1)
	slots[selected][1] = posmod(int(slots[selected][1]), _count(material()))
	_rebuild_swatches()
	_refresh()
	_save()
	changed.emit(part(), colour(), material())


## All three at once: what pick-block does. A material of -1 keeps the slot's.
func set_slot(p: String, c: int, m: int = -1) -> void:
	var mat := material() if m < 0 else m
	slots[selected] = [p, posmod(c, _count(mat)), mat]
	_rebuild_swatches()
	_refresh()
	_save()
	changed.emit(part(), colour(), material())


func is_browsing() -> bool:
	return _browser != null and _browser.visible


func toggle_browser() -> void:
	_browser.visible = not _browser.visible
	if _browser.visible:
		_search.text = ""
		_fill_grid()
		_search.grab_focus()
	else:
		_search.release_focus()
	browsing_changed.emit(_browser.visible)


## TAB here rather than in the workshop: with the search box focused, the GUI
## would take TAB as "next control" and the browser could never be closed.
func _input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_TAB:
		toggle_browser()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# The bar
# ---------------------------------------------------------------------------

func _build_bar() -> void:
	_slot_style = StyleBoxFlat.new()
	_slot_style.bg_color = Color(0.07, 0.08, 0.11, 0.72)
	_slot_style.set_border_width_all(2)
	_slot_style.border_color = Color(0.25, 0.28, 0.35, 0.9)
	_slot_style.set_corner_radius_all(6)
	_slot_style_on = _slot_style.duplicate()
	_slot_style_on.border_color = Color(1.0, 0.86, 0.45)
	_slot_style_on.set_border_width_all(3)

	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 4)
	_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bar.offset_bottom = -10
	add_child(_bar)
	for i in SLOTS:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(SLOT_PX, SLOT_PX)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.gui_input.connect(_on_slot_input.bind(i))
		panel.set_drag_forwarding(_drag_slot.bind(i), _can_drop_on_slot.bind(i),
				_drop_on_slot.bind(i))
		var stack := Control.new()
		# Pass the mouse through to the panel: a plain Control stops it by
		# default, and then neither a click nor a drop ever reaches the slot.
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(stack)
		var icon := TextureRect.new()
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(icon)
		var label := Label.new()
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		label.add_theme_constant_override("outline_size", 4)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(label)
		var key := Label.new()
		key.text = str(i + 1)
		key.position = Vector2(3, 0)
		key.add_theme_font_size_override("font_size", 11)
		key.add_theme_color_override("font_color", Color(1.0, 0.86, 0.45))
		key.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		key.add_theme_constant_override("outline_size", 4)
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(key)
		_bar.add_child(panel)
		_slot_nodes.append({"panel": panel, "icon": icon, "label": label})


# ---------------------------------------------------------------------------
# Drag and drop
# ---------------------------------------------------------------------------

## A drag carries {"kind": "part" | "slot" | "colour" | "material", ...}; a
## part or slot drag also carries the colour and material it will land with,
## which passing over a swatch or a material button changes.
func _preview(p: String, c: int, m: int) -> TextureRect:
	var t := TextureRect.new()
	t.texture = _icons.get(p)
	t.modulate = rgb(m, c)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.size = Vector2(SLOT_PX, SLOT_PX)
	t.position = -t.size * 0.5
	var holder := Control.new()
	holder.add_child(t)
	_drag_preview = t
	return t


func _tint_preview(data: Dictionary) -> void:
	if _drag_preview != null and is_instance_valid(_drag_preview):
		_drag_preview.modulate = rgb(int(data.material), int(data.colour))


func _drag_part(_at: Vector2, p: String, source: Control) -> Variant:
	var data := {"kind": "part", "part": p, "colour": colour(), "material": material()}
	source.set_drag_preview(_preview(p, colour(), material()).get_parent())
	return data


func _drag_slot(_at: Vector2, i: int) -> Variant:
	var p := str(slots[i][0])
	if p == "":
		return null
	var panel: Control = _slot_nodes[i].panel
	panel.set_drag_preview(_preview(p, int(slots[i][1]), int(slots[i][2])).get_parent())
	return {"kind": "slot", "from": i, "part": p, "colour": int(slots[i][1]),
			"material": int(slots[i][2])}


func _drag_chip(source: Control, col: Color) -> void:
	var r := ColorRect.new()
	r.color = col
	r.size = Vector2(28, 28)
	r.position = -r.size * 0.5
	var holder := Control.new()
	holder.add_child(r)
	source.set_drag_preview(holder)


func _drag_colour(_at: Vector2, c: int, m: int, source: Control) -> Variant:
	_drag_chip(source, rgb(m, c))
	return {"kind": "colour", "colour": c, "material": m}


func _drag_material(_at: Vector2, m: int, source: Control) -> Variant:
	_drag_chip(source, rgb(m, 0))
	return {"kind": "material", "material": m}


func _can_drop_on_slot(_at: Vector2, data: Variant, _i: int) -> bool:
	return data is Dictionary and data.get("kind", "") in ["part", "slot", "colour", "material"]


func _drop_on_slot(_at: Vector2, data: Variant, i: int) -> void:
	match str(data.kind):
		"part":
			slots[i] = [str(data.part), int(data.colour), int(data.material)]
		"colour":
			if str(slots[i][0]) != "":
				slots[i][1] = int(data.colour)
				slots[i][2] = int(data.material)
		"material":
			if str(slots[i][0]) != "":
				slots[i][2] = int(data.material)
				slots[i][1] = posmod(int(slots[i][1]), _count(int(data.material)))
		"slot":
			var from: int = data.from
			var held: Array = slots[i]
			slots[i] = slots[from]
			slots[from] = held
	select(i)


## Passing a part over a colour paints it: the picture under the cursor and
## what will land in the slot both take the colour -- and the material that
## colour belongs to. Dropping it ON the colour puts it in the selected slot.
func _can_drop_on_colour(_at: Vector2, data: Variant, c: int, m: int) -> bool:
	if not (data is Dictionary and data.get("kind", "") in ["part", "slot"]):
		return false
	data.colour = c
	data.material = m
	_tint_preview(data)
	return true


func _drop_on_colour(_at: Vector2, data: Variant, c: int, m: int) -> void:
	if str(data.kind) == "slot":
		slots[int(data.from)][1] = c
		slots[int(data.from)][2] = m
		select(int(data.from))
	else:
		set_slot(str(data.part), c, m)


## The same for a material: passing over it makes the dragged part that.
func _can_drop_on_material(_at: Vector2, data: Variant, m: int) -> bool:
	if not (data is Dictionary and data.get("kind", "") in ["part", "slot"]):
		return false
	data.material = m
	data.colour = posmod(int(data.colour), _count(m))
	_tint_preview(data)
	return true


func _drop_on_material(_at: Vector2, data: Variant, m: int) -> void:
	if str(data.kind) == "slot":
		select(int(data.from))
		set_material(m)
	else:
		set_slot(str(data.part), int(data.colour), m)


func _on_slot_input(e: InputEvent, i: int) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		select(i)
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	for i in SLOTS:
		var n: Dictionary = _slot_nodes[i]
		var p := str(slots[i][0])
		(n.panel as PanelContainer).add_theme_stylebox_override("panel",
				_slot_style_on if i == selected else _slot_style)
		(n.icon as TextureRect).texture = _icons.get(p)
		(n.icon as TextureRect).modulate = rgb(int(slots[i][2]), int(slots[i][1]))
		(n.label as Label).text = _short(p) if p != "" else ""
		(n.panel as PanelContainer).tooltip_text = "%s %s %s" % [
				BrickWorld.get_material_colour_name(int(slots[i][2]), int(slots[i][1])),
				BrickWorld.get_material_name(int(slots[i][2])), p] if p != "" else ""
	if _title != null:
		_title.text = "Click a part for slot %d, or drag it to any slot -- across a material or colour to change it. TAB closes." % (selected + 1)


## "2x4 slope" from "slope_2x4": what a slot has room to say.
static func _short(p: String) -> String:
	var size := p.get_slice("_", 1)
	var fam := BrickPalette.family_of(p)
	return "%s %s" % [size, fam.substr(0, 5)]


# ---------------------------------------------------------------------------
# The browser
# ---------------------------------------------------------------------------

func _build_browser() -> void:
	_browser = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.92)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	_browser.add_theme_stylebox_override("panel", style)
	_browser.set_anchors_preset(Control.PRESET_CENTER)
	_browser.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_browser.grow_vertical = Control.GROW_DIRECTION_BOTH
	_browser.visible = false
	add_child(_browser)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_browser.add_child(v)
	_title = Label.new()
	v.add_child(_title)
	_search = LineEdit.new()
	_search.placeholder_text = "search: 2x4, slope, round ..."
	_search.text_changed.connect(func(_t): _fill_grid())
	v.add_child(_search)
	_tabs = TabBar.new()
	_tabs.add_tab("All")
	for c in BrickPalette.categories():
		_tabs.add_tab(c)
	_tabs.tab_changed.connect(func(_i): _fill_grid())
	v.add_child(_tabs)

	var scroll := ScrollContainer.new()
	# Two and a half rows: with 64 colours below it, three pushed the panel
	# down over the toolbar.
	scroll.custom_minimum_size = Vector2(8 * 84, 2.5 * 104)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 8
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(_grid)

	_materials = HBoxContainer.new()
	_materials.add_theme_constant_override("separation", 4)
	v.add_child(_materials)
	for m in BrickWorld.get_material_count():
		var b := Button.new()
		b.text = BrickWorld.get_material_name(m)
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 12)
		b.tooltip_text = "%s -- %s" % [BrickWorld.get_material_name(m),
				"any colour" if BrickWorld.is_filament_material(m)
				else "%d kinds" % BrickWorld.get_material_colour_count(m)]
		b.pressed.connect(set_material.bind(m))
		b.set_drag_forwarding(_drag_material.bind(m, b), _can_drop_on_material.bind(m),
				_drop_on_material.bind(m))
		_materials.add_child(b)
	_swatch_label = Label.new()
	_swatch_label.add_theme_font_size_override("font_size", 12)
	v.add_child(_swatch_label)
	_swatches = GridContainer.new()
	_swatches.columns = 16
	_swatches.add_theme_constant_override("h_separation", 4)
	_swatches.add_theme_constant_override("v_separation", 4)
	v.add_child(_swatches)
	_rebuild_swatches()


## The colours the selected slot's material offers: the whole filament palette,
## or that material's own kinds, each named in its tooltip.
func _rebuild_swatches() -> void:
	if _swatches == null:
		return
	for child in _swatches.get_children():
		child.queue_free()
	var m := material()
	for i in _materials.get_child_count():
		(_materials.get_child(i) as Button).button_pressed = i == m
	_swatch_label.text = "%s colours" % BrickWorld.get_material_name(m) \
			if BrickWorld.is_filament_material(m) else "%s kinds" % BrickWorld.get_material_name(m)
	for c in BrickWorld.get_material_colour_count(m):
		var b := Button.new()
		b.custom_minimum_size = Vector2(36, 26)
		var sb := StyleBoxFlat.new()
		sb.bg_color = rgb(m, c)
		sb.set_corner_radius_all(4)
		b.add_theme_stylebox_override("normal", sb)
		var hover := sb.duplicate()
		hover.set_border_width_all(2)
		hover.border_color = Color(1, 1, 1)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", hover)
		b.tooltip_text = BrickWorld.get_material_colour_name(m, c)
		b.pressed.connect(set_colour.bind(c))
		b.set_drag_forwarding(_drag_colour.bind(c, m, b), _can_drop_on_colour.bind(c, m),
				_drop_on_colour.bind(c, m))
		_swatches.add_child(b)

## The parts the current tab and search allow, in catalogue order.
func shown_parts() -> Array:
	var tab := _tabs.get_tab_title(_tabs.current_tab) if _tabs != null else "All"
	var out := []
	var cats: Array = BrickPalette.categories() if tab == "All" else [tab]
	var q := _search.text.strip_edges().to_lower() if _search != null else ""
	for c in cats:
		for p in BrickPalette.parts_in(c):
			var words := "%s %s %s" % [p, c.to_lower(), p.replace("_", " ")]
			if q == "" or words.contains(q):
				out.append(p)
	return out


func _fill_grid() -> void:
	for child in _grid.get_children():
		child.queue_free()
	for p in shown_parts():
		var b := Button.new()
		b.custom_minimum_size = Vector2(80, 98)
		b.icon = _icons.get(p)
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.text = _short(p)
		b.add_theme_font_size_override("font_size", 11)
		b.tooltip_text = "%s  (%s)" % [p, BrickPalette.category_of(p)]
		b.set_meta("part", p)
		b.pressed.connect(set_part.bind(p))
		b.set_drag_forwarding(_drag_part.bind(p, b), Callable(), Callable())
		_grid.add_child(b)


# ---------------------------------------------------------------------------
# Icons: each part rendered once, off screen, from the workshop's own meshes
# ---------------------------------------------------------------------------

func _build_icon_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(ICON_PX, ICON_PX)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	_viewport.add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.78)
	e.ambient_light_energy = 0.7
	env.environment = e
	_viewport.add_child(env)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	_icon_mesh = MeshInstance3D.new()
	_icon_mesh.material_override = mat
	_viewport.add_child(_icon_mesh)
	_icon_studs = MultiMeshInstance3D.new()
	_icon_studs.material_override = mat
	_icon_mesh.add_child(_icon_studs)
	_icon_cam = Camera3D.new()
	_icon_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_viewport.add_child(_icon_cam)


var _icon_busy := false


func _process(_dt: float) -> void:
	if _icon_busy or _icon_queue.is_empty() or not mesh_for.is_valid():
		return
	if DisplayServer.get_name() == "headless":
		return  # nothing renders, so there is no picture to take
	_render_icon(_icon_queue.pop_front())


## One part, one frame. White bricks, so a slot can tint the icon its colour.
func _render_icon(p: String) -> void:
	_icon_busy = true
	var shape: Array = mesh_for.call(p)
	var mesh: ArrayMesh = shape[0]
	_icon_mesh.mesh = mesh
	_icon_studs.multimesh = shape[1]
	var box := mesh.get_aabb() if mesh.get_surface_count() > 0 else AABB(Vector3.ZERO, Vector3.ONE)
	var centre := box.get_center()
	var reach := box.size.length()
	_icon_cam.size = reach * 1.05
	_icon_cam.position = centre + Vector3(1.0, 0.9, 1.3).normalized() * (reach + 2.0)
	_icon_cam.look_at(centre, Vector3.UP)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	_icons[p] = ImageTexture.create_from_image(_viewport.get_texture().get_image())
	_icon_busy = false
	_refresh()
	if is_browsing():
		for b in _grid.get_children():
			if str(b.get_meta("part", "")) == p:
				(b as Button).icon = _icons[p]


# ---------------------------------------------------------------------------
# Remembered
# ---------------------------------------------------------------------------

func _load() -> void:
	slots = []
	for d in DEFAULTS:
		slots.append([d[0], d[1], 0])
	if not FileAccess.file_exists(save_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if not (data is Dictionary):
		return
	var saved: Array = data.get("slots", [])
	for i in mini(saved.size(), SLOTS):
		var s: Array = saved[i]
		var p := str(s[0])
		if p == "" or BrickPalette.parts().has(p):
			# A toolbar saved before materials is PLA, which it was.
			var m := clampi(int(s[2]) if s.size() > 2 else 0, 0, BrickWorld.get_material_count() - 1)
			slots[i] = [p, posmod(int(s[1]), _count(m)), m]
	selected = clampi(int(data.get("selected", 0)), 0, SLOTS - 1)


func _save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"slots": slots, "selected": selected}))
	f.close()
