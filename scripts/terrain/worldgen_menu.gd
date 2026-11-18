extends MenuScreen

## THE WORLD GENERATION MENU (M in the mine world, or the pause menu). Docs/MineWorld.md 6.
##
## Edits a COPY of the world's settings; nothing changes in the world until
## "Generate world". Tabs follow the zylanntest world builder: World, Shape,
## Sea & Beach, Caves, Ores, Biomes, Underground, Map. Presets come from
## worldgen_presets.gd (shipped ones and the player's own).
##
## The map is drawn by C++ (BrickTerrain.gen_preview) from these settings
## without touching the live world's, so it can be redrawn while the world
## keeps streaming. Click it to choose where you start.
##
## Sized to the screen the way the Options menu is: a MenuScreen
## (menu/core/MenuScreen.gd). The presets bar is in the header, the status,
## Close and Generate world in the footer -- both outside the scrolling body,
## so they are always on screen; each tab page scrolls on its own, and the
## map shrinks (or goes under the tabs on a narrow window) to fit.
##
## What the host gives it: `settings`, `spawn_xz`, `generate(settings)`,
## `menu_closed()`, `forget_edits()`. Call `setup(host)` BEFORE adding it to
## the tree; the host opens it on a layer of its own (MineWorld.toggle_menu),
## so it alone takes input.

const Presets := preload("res://scripts/terrain/worldgen_presets.gd")

const MAP_SIZE := 256

var host: Node = null
var s: Dictionary = {}

var _tabs: TabContainer
var _status: Label
var _preset_pick: OptionButton
var _presets: Array = []
var _map: TextureRect
var _map_mode := 0
var _map_step := 24
var _map_centre := Vector2i.ZERO
var _spawn_label: Label
var _materials: PackedStringArray
var _name_edit: LineEdit
var _seed_box: SpinBox
var _main: BoxContainer
var _bar: HFlowContainer
var _generate_button: Button


func _init() -> void:
	screen_title = "World generation"
	opaque_backdrop = false
	dim_backdrop = true


func setup(p_host: Node) -> void:
	host = p_host
	s = (host.settings as Dictionary).duplicate(true)
	_materials = BrickTerrain.material_names()
	var stud := BrickWorld.get_stud_metres()
	_map_centre = Vector2i(int(host.spawn_xz.x / stud), int(host.spawn_xz.y / stud))


func _build_content() -> void:
	_build()
	_refresh_map()


## The Generate world button (the menu gate checks it is on screen).
func generate_button() -> Button:
	return _generate_button


func _build() -> void:
	# --- presets bar, in the header beside the title (never scrolls away)
	_bar = HFlowContainer.new()
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar.add_theme_constant_override("separation", 6)
	header.add_child(_bar)
	_bar.add_child(_label("Preset"))
	_preset_pick = OptionButton.new()
	_preset_pick.fit_to_longest_item = false
	_preset_pick.custom_minimum_size = Vector2(160, 0)
	_bar.add_child(_preset_pick)
	_button(_bar, "Load", _on_load)
	_button(_bar, "Save", _on_save)
	_button(_bar, "Duplicate", _on_duplicate)
	_button(_bar, "Delete", _on_delete)
	_button(_bar, "Reset", _on_reset)
	_fill_presets()

	# --- tabs and map, in the scrolling body
	_main = BoxContainer.new()
	_main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main.add_theme_constant_override("separation", 12)
	content.add_child(_main)

	_tabs = TabContainer.new()
	_tabs.clip_tabs = true
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main.add_child(_tabs)
	_build_world_tab()
	_build_shape_tab()
	_build_sea_tab()
	_build_caves_tab()
	_build_ores_tab()
	_build_biomes_tab()
	_build_underground_tab()

	# --- the map, beside the tabs (under them on a narrow window)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	_main.add_child(side)
	side.add_child(_label("Map (click to choose the spawn)"))
	_map = TextureRect.new()
	_map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map.custom_minimum_size = Vector2(MAP_SIZE * 1.5, MAP_SIZE * 1.5)
	_map.stretch_mode = TextureRect.STRETCH_SCALE
	_map.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_map.mouse_filter = Control.MOUSE_FILTER_STOP
	_map.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_map.gui_input.connect(_on_map_input)
	side.add_child(_map)
	var mrow := HFlowContainer.new()
	side.add_child(mrow)
	var mode := OptionButton.new()
	mode.add_item("Ground", 0)
	mode.add_item("Biomes", 1)
	mode.select(_map_mode)
	mode.item_selected.connect(func(i: int) -> void:
		_map_mode = i
		_refresh_map())
	mrow.add_child(mode)
	_button(mrow, "Zoom in", func() -> void:
		_map_step = maxi(4, int(_map_step / 2.0))
		_refresh_map())
	_button(mrow, "Zoom out", func() -> void:
		_map_step = mini(256, _map_step * 2)
		_refresh_map())
	_button(mrow, "Redraw", _refresh_map)
	_spawn_label = MenuFit.fit_label(_label(""), true)
	side.add_child(_spawn_label)
	_button(side, "Random spawn", func() -> void:
		s["spawn"] = null
		_update_spawn_label())
	_update_spawn_label()

	# --- footer: status, Close, Generate world (outside the scroll: always seen)
	_status = MenuFit.fit_label(_label(""), false)
	_status.custom_minimum_size = Vector2(120, 0)
	footer.add_child(_status)
	_button(footer, "Close", _close)
	_generate_button = _button(footer, "Generate world", _on_generate)


## The map and the tab rows follow the window: beside the tabs when there is
## room, under them on a narrow window; never taller than the body can show.
func _on_relayout(vp_size: Vector2) -> void:
	if _main == null:
		return
	var narrow := MenuFit.is_narrow(vp_size)
	_main.vertical = narrow
	var avail_w := available_width(vp_size)
	# Header, separator, footer and padding take about this much of the height.
	var chrome := 190.0 if MenuFit.is_short(vp_size) else 230.0
	var room_h := vp_size.y - float(MenuFit.page_padding(vp_size)) * 2.0 - chrome
	var side_px := minf(MAP_SIZE * 1.5, avail_w * (0.9 if narrow else 0.34))
	if not narrow:
		side_px = minf(side_px, room_h - 110.0)
	side_px = maxf(side_px, 128.0)
	_map.custom_minimum_size = Vector2(side_px, side_px)
	# Under the map the tabs need a height of their own (their pages scroll).
	_tabs.custom_minimum_size = Vector2(0, maxf(room_h, 200.0) if narrow else 0.0)
	var label_w := clampf(avail_w * (0.3 if narrow else 0.18), 110.0, 300.0)
	for l in _tabs.find_children("*", "Label", true, false):
		if (l as Label).has_meta(&"row_label"):
			(l as Label).custom_minimum_size.x = label_w


func _on_back() -> bool:
	_close()
	return true


# ---------------------------------------------------------------------------
# Tabs

func _page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	scroll.add_child(box)
	return box


func _build_world_tab() -> void:
	var p := _page("World")
	var r := _row(p, "Name")
	_name_edit = LineEdit.new()
	_name_edit.text = str(s.name)
	_name_edit.custom_minimum_size = Vector2(120, 0)
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(func(t: String) -> void: s["name"] = t)
	r.add_child(_name_edit)
	r = _row(p, "Seed")
	_seed_box = SpinBox.new()
	_seed_box.min_value = -2147483647
	_seed_box.max_value = 2147483647
	_seed_box.step = 1
	_seed_box.value = int(s.seed)
	_seed_box.custom_minimum_size = Vector2(120, 0)
	_seed_box.value_changed.connect(func(v: float) -> void:
		s["seed"] = int(v)
		_refresh_map())
	r.add_child(_seed_box)
	_button(r, "Random", func() -> void:
		_seed_box.value = randi() % 2000000000)
	_int_slider(p, "Full detail radius (tiles)", s, "detail_tiles", 2, 8)
	_int_slider(p, "View distance (tiles of far rings)", s, "far_tiles", 16, 192)
	_float_slider(p, "World height scale", s.gen, "height_scale", 0.2, 3.0, 0.05)
	_section(p, "Your changes")
	p.add_child(_note("Blocks you break and place are saved for each seed and settings, every 30 s and when you leave or generate. Change a setting and it is a different world with its own changes."))
	_button(p, "Forget changes to this world", func() -> void:
		_close()
		host.forget_edits())
	p.add_child(_note("The world has no edge: the far rings move with you, and the world is moved back under you every 4 km so positions stay precise."))


func _build_shape_tab() -> void:
	var p := _page("Shape")
	var g: Dictionary = s.gen
	_section(p, "Continents")
	_float_slider(p, "Continent size (m)", g, "continent_scale_m", 200, 6000, 50)
	_float_slider(p, "Ocean threshold (more = more basin)", g, "ocean_threshold", -0.9, 0.6, 0.01)
	_float_slider(p, "Land base height (m)", g, "base_height_m", -10, 40, 0.5)
	_float_slider(p, "Continent weight (m)", g, "cont_weight_m", -20, 120, 1)
	_section(p, "Hills and erosion")
	_float_slider(p, "Erosion size (m)", g, "erosion_scale_m", 100, 4000, 50)
	_float_slider(p, "Hill height (m)", g, "hill_height_m", 0, 60, 0.5)
	_float_slider(p, "Hill size (m)", g, "hill_scale_m", 20, 1000, 10)
	_section(p, "Mountains")
	_float_slider(p, "Peak height (m)", g, "peak_height_m", 0, 250, 1)
	_float_slider(p, "Mountain threshold", g, "mountain_threshold", -1, 1, 0.01)
	_float_slider(p, "Mountain gain", g, "mountain_gain", 0, 10, 0.1)
	_float_slider(p, "Ridge size (m)", g, "ridge_scale_m", 50, 3000, 10)
	_section(p, "Dry rivers")
	_float_slider(p, "Valley depth (m)", g, "valley_depth_m", 0, 40, 0.5)
	_float_slider(p, "Valley narrowness", g, "valley_width", 2, 60, 0.5)
	_float_slider(p, "Valley spacing (m)", g, "valley_scale_m", 100, 5000, 50)
	_section(p, "Cliffs and overhangs")
	_float_slider(p, "Cliff amount", g, "cliff_amount", 0, 1, 0.01)
	_float_slider(p, "Cliff step (m)", g, "cliff_step_m", 1, 20, 0.5)
	_float_slider(p, "Overhang amount", g, "overhang_amount", 0, 1, 0.01)
	_float_slider(p, "Overhang size (m)", g, "overhang_size_m", 0, 20, 0.5)
	_section(p, "Far Lands (alien distortion)")
	_check(p, "Far lands", g, "far_lands")
	_float_slider(p, "Far lands intensity", g, "far_lands_intensity", 0, 1, 0.01)


func _build_sea_tab() -> void:
	var p := _page("Sea & Water")
	var g: Dictionary = s.gen
	p.add_child(_note("With water on, the basins and river valleys under the sea line are sea "
			+ "(Docs/MineWater.md); caves under it are sealed. Off: dry, sand-floored basins."))
	_check(p, "Water", g, "water")
	_float_slider(p, "Wave height (x)", g, "wave_scale", 0, 3, 0.05)
	_float_slider(p, "Sea line height (m)", g, "sea_m", -50, 100, 0.5)
	_float_slider(p, "Beach width above the sea line (m)", g, "beach_width_m", 0, 8, 0.1)
	_int_slider(p, "Basin sand depth (bricks)", g, "basin_sand_depth", 1, 16)


func _build_caves_tab() -> void:
	var p := _page("Caves")
	var g: Dictionary = s.gen
	_check(p, "Caves", g, "caves")
	_float_slider(p, "Cave intensity", g, "cave_intensity", 0, 1, 0.01)
	_float_slider(p, "Shallowest cave (m under the surface)", g, "cave_min_depth_m", 0.5, 20, 0.1)
	_float_slider(p, "Deepest cave (m under the surface)", g, "cave_max_depth_m", 2, 60, 0.5)
	_check(p, "Deep caves (on below that, down to the bedrock)", g, "deep_caves")
	_check(p, "Ravines", g, "ravines")
	_float_slider(p, "Ravine width", g, "ravine_width", 0, 1, 0.01)
	_float_slider(p, "Ravine depth (m)", g, "ravine_depth_m", 2, 60, 0.5)


func _build_ores_tab() -> void:
	var p := _page("Ores")
	p.add_child(_note("Heights are metres relative to the sea line. Chance is veins per 8-brick cell."))
	for ore in s.gen.ores:
		_section(p, str(ore.name))
		_float_slider(p, "Chance", ore, "chance", 0, 1, 0.01)
		_float_slider(p, "Vein radius (studs)", ore, "size", 0.5, 3, 0.1)
		_float_slider(p, "From (m)", ore, "min_m", -200, 150, 1)
		_float_slider(p, "To (m)", ore, "max_m", -200, 150, 1)


func _build_biomes_tab() -> void:
	var p := _page("Biomes")
	var g: Dictionary = s.gen
	_section(p, "Climate")
	_float_slider(p, "Biome size (m)", g, "biome_scale_m", 100, 5000, 50)
	_float_slider(p, "Warmer / colder", g, "temp_offset", -1.5, 1.5, 0.05)
	_float_slider(p, "Wetter / drier", g, "humid_offset", -1.5, 1.5, 0.05)
	_float_slider(p, "Snow line (m above the sea line)", g, "snow_line_m", 0, 200, 1)
	p.add_child(_note("Land biomes are picked by the nearest temperature/humidity/weirdness. Basins, beaches, shores, rivers, hills and peaks are picked by the ground."))
	var trees: Dictionary = s.trees
	for b in g.biomes:
		_section(p, str(b.name))
		var r := _row(p, "")
		var on := CheckBox.new()
		on.text = "Enabled"
		on.button_pressed = bool(b.enabled)
		on.toggled.connect(func(v: bool) -> void: b["enabled"] = v)
		r.add_child(on)
		if int(b.kind) == 0:
			_float_slider(p, "Temperature", b, "temp", -1, 1, 0.05)
			_float_slider(p, "Humidity", b, "humid", -1, 1, 0.05)
			_float_slider(p, "Weirdness", b, "weird", -1, 1, 0.05)
		_material_row(p, "Top block", b, "top")
		_material_row(p, "Under block", b, "under")
		_int_slider(p, "Under depth (bricks)", b, "under_depth", 0, 12)
		_material_row(p, "Second under block", b, "under2")
		_int_slider(p, "Second under depth (bricks)", b, "under2_depth", 0, 12)
		_material_row(p, "Stone", b, "stone")
		_float_slider(p, "Hilliness", b, "hilliness", 0, 3, 0.05)
		var name_key := str(b.name)
		if not trees.has(name_key):
			trees[name_key] = 0.0
		_float_slider(p, "Trees", trees, name_key, 0, 1, 0.01)


func _build_underground_tab() -> void:
	var p := _page("Underground")
	var g: Dictionary = s.gen
	_float_slider(p, "Bedrock floor (m relative to the sea line)", g, "bedrock_m", -200, 0, 1)
	_float_slider(p, "Granite, diorite and gravel patches", g, "stone_patches", 0, 1, 0.01)
	_section(p, "Deep layers (replace the stone below their top)")
	var list := VBoxContainer.new()
	p.add_child(list)
	_fill_bands(list)
	_button(p, "+ Add layer", func() -> void:
		(g.bands as Array).append({"top_m": -30.0, "material": _materials.find("dark stone"), "enabled": true})
		_fill_bands(list))


func _fill_bands(list: VBoxContainer) -> void:
	for c in list.get_children():
		c.queue_free()
	var bands: Array = s.gen.bands
	for band in bands:
		var r := HBoxContainer.new()
		list.add_child(r)
		var on := CheckBox.new()
		on.button_pressed = bool(band.get("enabled", true))
		on.toggled.connect(func(v: bool) -> void: band["enabled"] = v)
		r.add_child(on)
		r.add_child(_label("below"))
		var top := SpinBox.new()
		top.min_value = -300
		top.max_value = 200
		top.step = 1
		top.suffix = "m"
		top.value = float(band.top_m)
		top.value_changed.connect(func(v: float) -> void: band["top_m"] = v)
		r.add_child(top)
		r.add_child(_material_pick(band, "material"))
		_button(r, "Remove", func() -> void:
			bands.erase(band)
			_fill_bands(list))


# ---------------------------------------------------------------------------
# Rows

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _note(t: String) -> Label:
	var l := MenuFit.fit_label(_label(t), true)
	l.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	l.add_theme_font_size_override("font_size", 12)
	return l


func _section(p: Control, t: String) -> void:
	var l := _label(t)
	l.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	p.add_child(l)


func _row(p: Control, t: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	p.add_child(r)
	if t != "":
		# Wraps rather than widening the page; _on_relayout sizes it to the window.
		var l := MenuFit.fit_label(_label(t), true)
		l.size_flags_horizontal = Control.SIZE_FILL
		l.custom_minimum_size = Vector2(300, 0)
		l.set_meta(&"row_label", true)
		r.add_child(l)
	return r


func _button(p: Control, t: String, f: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(f)
	p.add_child(b)
	return b


func _float_slider(p: Control, t: String, d: Dictionary, key: String, lo: float, hi: float,
		step: float) -> void:
	var r := _row(p, t)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.custom_minimum_size = Vector2(90, 0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var box := SpinBox.new()
	box.min_value = lo
	box.max_value = hi
	box.step = step
	box.allow_greater = true
	box.allow_lesser = true
	var v := float(d.get(key, lo))
	sl.value = v
	box.value = v
	sl.value_changed.connect(func(x: float) -> void:
		d[key] = x
		box.set_value_no_signal(x))
	box.value_changed.connect(func(x: float) -> void:
		d[key] = x
		sl.set_value_no_signal(x))
	sl.drag_ended.connect(func(_changed: bool) -> void: _refresh_map())
	r.add_child(sl)
	r.add_child(box)


func _int_slider(p: Control, t: String, d: Dictionary, key: String, lo: int, hi: int) -> void:
	var r := _row(p, t)
	var box := SpinBox.new()
	box.min_value = lo
	box.max_value = hi
	box.step = 1
	box.value = int(d.get(key, lo))
	box.value_changed.connect(func(x: float) -> void: d[key] = int(x))
	r.add_child(box)


func _check(p: Control, t: String, d: Dictionary, key: String) -> void:
	var r := _row(p, t)
	var c := CheckBox.new()
	c.button_pressed = bool(d.get(key, false))
	c.toggled.connect(func(v: bool) -> void:
		d[key] = v
		_refresh_map())
	r.add_child(c)


func _material_row(p: Control, t: String, d: Dictionary, key: String) -> void:
	_row(p, t).add_child(_material_pick(d, key))


func _material_pick(d: Dictionary, key: String) -> OptionButton:
	var ob := OptionButton.new()
	for i in range(1, _materials.size()):
		ob.add_item(_materials[i], i)
	ob.select(ob.get_item_index(int(d.get(key, 1))))
	ob.item_selected.connect(func(idx: int) -> void:
		d[key] = ob.get_item_id(idx)
		_refresh_map())
	return ob


# ---------------------------------------------------------------------------
# The map

func _refresh_map() -> void:
	if _map == null:
		return
	var t0 := Time.get_ticks_usec()
	var px: PackedByteArray = BrickTerrain.gen_preview(int(s.seed), s.gen, _map_centre.x,
			_map_centre.y, MAP_SIZE, MAP_SIZE, _map_step, _map_mode)
	var img := Image.create_from_data(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGB8, px)
	_mark_spawn(img)
	_map.texture = ImageTexture.create_from_image(img)
	var km := float(MAP_SIZE * _map_step) * BrickWorld.get_stud_metres() / 1000.0
	_set_status("Map: %.1f km across, drawn in %.0f ms" % [km, float(Time.get_ticks_usec() - t0) / 1000.0])


func _mark_spawn(img: Image) -> void:
	var sp = s.get("spawn", null)
	if not (sp is Array):
		return
	var half := int(MAP_SIZE / 2.0)
	var px := Vector2i(floori(float(int(sp[0]) - _map_centre.x) / _map_step) + half,
			floori(float(int(sp[1]) - _map_centre.y) / _map_step) + half)
	for d in range(-3, 4):
		for p in [px + Vector2i(d, 0), px + Vector2i(0, d)]:
			if p.x >= 0 and p.y >= 0 and p.x < MAP_SIZE and p.y < MAP_SIZE:
				img.set_pixelv(p, Color.RED)


func _on_map_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var uv := mb.position / _map.size
	var px := Vector2i(int(uv.x * MAP_SIZE), int(uv.y * MAP_SIZE))
	var half := int(MAP_SIZE / 2.0)
	s["spawn"] = [_map_centre.x + (px.x - half) * _map_step,
			_map_centre.y + (px.y - half) * _map_step]
	_update_spawn_label()
	_refresh_map()


func _update_spawn_label() -> void:
	var sp = s.get("spawn", null)
	_spawn_label.text = "Spawn: nearest dry land to 0, 0" if not (sp is Array) \
			else "Spawn: nearest dry land to %d, %d studs" % [int(sp[0]), int(sp[1])]


# ---------------------------------------------------------------------------
# Presets and buttons

func _fill_presets() -> void:
	_presets = Presets.list()
	_preset_pick.clear()
	var sel := 0
	for i in _presets.size():
		var p: Dictionary = _presets[i]
		_preset_pick.add_item("%s%s" % [p.name, "" if p.builtin else "  (yours)"], i)
		if str(p.name) == str(s.name):
			sel = i
	if not _presets.is_empty():
		_preset_pick.select(sel)


func _picked() -> Dictionary:
	var i := _preset_pick.selected
	return _presets[i] if i >= 0 and i < _presets.size() else {}


func _on_load() -> void:
	var p := _picked()
	if p.is_empty():
		return
	s = Presets.load_settings(p.path)
	_rebuild_tabs()
	_set_status("Loaded '%s' -- press Generate world to build it" % p.name)


func _on_save() -> void:
	var path := Presets.save(s)
	_fill_presets()
	_set_status("Saved to %s" % path if path != "" else "Could not save")


func _on_duplicate() -> void:
	s["name"] = "%s copy" % str(s.name)
	_name_edit.text = s.name
	_on_save()


func _on_delete() -> void:
	var p := _picked()
	if p.is_empty() or p.builtin:
		_set_status("Shipped presets cannot be deleted")
		return
	Presets.remove(p.path)
	_fill_presets()
	_set_status("Deleted '%s'" % p.name)


func _on_reset() -> void:
	var p := _picked()
	s = Presets.load_settings(p.path) if not p.is_empty() else Presets.complete({})
	_rebuild_tabs()
	_set_status("Reset to '%s'" % s.name)


func _rebuild_tabs() -> void:
	# The scaffold (header, body, footer) stays; what _build put in it goes.
	_bar.free()
	_main.free()
	for c in footer.get_children():
		c.free()
	_map = null
	_build()
	_relayout()
	_refresh_map()


func _on_generate() -> void:
	_set_status("Generating ...")
	var settings := s.duplicate(true)
	_close()
	host.generate(settings)


## M closes it too (Escape is MenuScreen's ui_cancel -> _on_back).
func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and (k.keycode == KEY_M or k.keycode == KEY_ESCAPE):
		get_viewport().set_input_as_handled()
		_close()
		return
	super(event)


var _closed := false


func _close() -> void:
	if _closed:
		return
	_closed = true
	host.menu_closed()
	queue_free()


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t
