extends PanelContainer

## THE DEV MENU for the terrain scene. F10 in heightfield_test (and the
## terrain editor, which is the same scene). [Docs/Terrain.md](../Docs/Terrain.md) §20.10.
##
## Opening it frees the mouse; the world keeps running (the waves move, you
## can still fly with the keyboard), it just stops taking the mouse. Every
## control acts at once on the scene it is handed (`host`):
##
##   Freeze LOD      the streamer, the far tier's hiding and the water rings
##                   stop following the camera, so you can fly over to a LOD
##                   border and look at it up close.
##   LOD view        the L tint.
##   Detail radius   how many tiles of full detail round the camera.
##   Smooth far from the coarse sample step past which far ground is smooth
##                   (Terrain.md 19.14); applied with "Rebuild far terrain".
##   Waves           height, strength at the shore, how far out that strength
##                   reaches full, and how far from land the swell stops
##                   rolling toward the shore.
##   Studded water   how far round the camera the brick water reaches.
##   Tile lean, grid lines   the studded tiles' look.
##
## Preloaded by path, not named: see heightfield_scene.gd.

var host = null
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _smooth_step := 8


func setup(p_host) -> void:
	host = p_host
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.92)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	add_theme_stylebox_override("panel", style)
	custom_minimum_size = Vector2(440, 0)
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.custom_minimum_size = Vector2(440, 200)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 6)
	scroll.add_child(_rows)

	_title("DEV MENU  (F10 to close)")
	_section("LOD")
	_check("Freeze LOD streaming", host._lod_frozen, func(on: bool) -> void:
		host.set_lod_frozen(on))
	_check("LOD colour view (L)", host._lod_debug, func(on: bool) -> void:
		host.set_lod_view(on))
	_slider("Detail radius (tiles)", 1, 12, 1, host._streamer.near_radius,
		func(v: float) -> void: host.set_detail_radius(int(v)))
	_smooth_step = BrickTerrain.get_coarse_smooth_step()
	_option("Smooth far terrain from", ["off", "every 8 studs (LOD 2+)", "every 16 studs (LOD 3+)",
			"every 4 studs (LOD 1+)"], [0, 8, 16, 4].find(_smooth_step),
		func(i: int) -> void: _smooth_step = [0, 8, 16, 4][i])
	_button("Rebuild far terrain", func() -> void:
		BrickTerrain.set_coarse_smooth_step(_smooth_step)
		host.rebuild_far())

	_section("WAVES")
	var sea = host._sea
	_slider("Wave height", 0.0, 5.0, 0.1, sea.wave_gain, func(v: float) -> void:
		sea.wave_gain = v
		sea.push_waves())
	var calm: Vector2 = BrickWave.shore_calm_uniform()
	_slider("Strength at the shore", 0.0, 1.0, 0.05, calm.x, func(v: float) -> void:
		var c: Vector2 = BrickWave.shore_calm_uniform()
		BrickWave.set_shore_calm(v, c.y)
		sea.push_waves())
	_slider("Full strength by (m from shore)", 10.0, 500.0, 10.0, calm.y, func(v: float) -> void:
		var c: Vector2 = BrickWave.shore_calm_uniform()
		BrickWave.set_shore_calm(c.x, v)
		sea.push_waves())
	var steer: Vector4 = BrickWave.swell_blend_uniform()
	_slider("Swell rolls to shore within (m)", 0.0, 1000.0, 10.0, steer.x, func(v: float) -> void:
		var b: Vector4 = BrickWave.swell_blend_uniform()
		BrickWave.set_swell_steer(v, v + (b.y - b.x))
		sea.push_waves())

	_section("WATER LOOK")
	_slider("Studded water radius (m)", 10.0, 100.0, 5.0, sea.near_radius, func(v: float) -> void:
		sea.near_radius = v
		sea.rebuild())
	_slider("Tile lean (0 flat)", 0.0, 1.0, 0.05, 0.0, func(v: float) -> void:
		host.set_water_param("tile_tilt", v))
	_check("Grid lines", true, func(on: bool) -> void:
		host.set_water_param("grid_lines", on))


## Fit the window: from where the menu sits down to 14 px off the bottom,
## scrolling for the rest. A fixed height ran off shorter windows.
func fit(top: float) -> void:
	var h: float = get_viewport().get_visible_rect().size.y
	position = Vector2(14, top)
	_scroll.custom_minimum_size = Vector2(440, maxf(h - top - 14.0 - 24.0, 160.0))
	size = Vector2.ZERO


func _title(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	_rows.add_child(l)


func _section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	_rows.add_child(l)


func _check(text: String, value: bool, on_change: Callable) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = value
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(on_change)
	_rows.add_child(c)


func _button(text: String, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	_rows.add_child(b)


func _option(text: String, items: Array, selected: int, on_select: Callable) -> void:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	o.selected = maxi(selected, 0)
	o.focus_mode = Control.FOCUS_NONE
	o.item_selected.connect(on_select)
	h.add_child(o)
	_rows.add_child(h)


## A labelled slider that shows its value, and acts when it is let go rather
## than on every step: some of these rebuild things.
func _slider(text: String, lo: float, hi: float, step: float, value: float,
		on_change: Callable) -> void:
	var l := Label.new()
	_rows.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var show := func(v: float) -> void:
		l.text = "%s   %s" % [text, str(snappedf(v, step))]
	show.call(value)
	s.value_changed.connect(show)
	# On release -- a drag or a click on the track both end in one.
	s.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and not e.pressed \
				and e.button_index == MOUSE_BUTTON_LEFT:
			on_change.call(s.value))
	_rows.add_child(s)
