extends MenuScreen

## THE WORLD VIEW MENU (Docs/MineWorld.md 22): how the mine world is DRAWN,
## put in with Apply, in play -- how far detail, caves and the far rings
## reach, the real brick edges, the far ground's detail, cave darkness and
## fade. None of it is a generator setting (those take effect on Generate
## world and key a world's saved changes). Opened from the World generation
## menu's "World view" button; edits a copy of WorldView's values, so Close
## without Apply leaves the world as it was.

var host: Node = null
var _layer: CanvasLayer = null
var v: Dictionary = {}
var _status: Label


func _init() -> void:
	screen_title = "World view"
	opaque_backdrop = true
	dim_backdrop = false


func setup(p_host: Node, layer: CanvasLayer) -> void:
	host = p_host
	_layer = layer
	v = WorldView.values.duplicate()


func _build_content() -> void:
	var p := VBoxContainer.new()
	p.add_theme_constant_override("separation", 8)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(p)

	_section(p, "Distance")
	_int(p, "Full detail radius (tiles)", "detail_tiles",
			"Ground drawn brick by brick round you. Further costs bakes and memory.")
	_int(p, "Cave view distance (tiles)", "cave_tiles",
			"How far caves are drawn underground, past which they fade to black.")
	_int(p, "Far view distance (tiles of far rings)", "far_tiles",
			"How far the distant ground reaches. Laid out again on Apply, in the background.")
	_pick(p, "Distant ground detail", "far_detail", ["High", "Medium", "Low"],
			"How finely the ground past the nearby bricks is shaped. Medium and Low draw a "
			+ "quarter and a sixteenth of its triangles (about 0.7 ms less GPU at Low).")

	_section(p, "Bricks")
	_check(p, "Real brick edges near you", "chamfer",
			"Real bevelled bricks over the ground near you, and a shot brick's hole shows "
			+ "the bricks behind it at once. Off: flat ground with drawn seams.")

	_section(p, "Caves")
	_float(p, "Darkest cave light", "cave_light", 0.0, 0.15, 0.005,
			"The least light a cave with no way to the sky gets. 0 is black.")
	_check(p, "Fade caves to black at the view's end", "cave_fade",
			"Off: caves end where they stop being drawn, with nothing past them.")

	_status = MenuFit.fit_label(_label(""), false)
	_status.custom_minimum_size = Vector2(120, 0)
	footer.add_child(_status)
	_button(footer, "Defaults", func() -> void:
		v = WorldView.DEFAULTS.duplicate()
		_rebuild())
	_button(footer, "Close", _close)
	_button(footer, "Apply", _apply)


func _rebuild() -> void:
	for c in content.get_children():
		c.queue_free()
	for c in footer.get_children():
		c.queue_free()
	_build_content.call_deferred()


func _apply() -> void:
	WorldView.values = v.duplicate()
	WorldView._clamp()
	# A scripted pass never writes the player's file (CLAUDE.md, test windows).
	if not bool(host.get("_gate")):
		WorldView.save()
	host.apply_view()
	_status.text = "Applied."


func _close() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	else:
		queue_free()


func _on_back() -> bool:
	_close()
	return true


# --- rows --------------------------------------------------------------------

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _section(p: Control, t: String) -> void:
	var l := _label(t)
	l.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	p.add_child(l)


func _row(p: Control, t: String, hint: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	p.add_child(r)
	var l := MenuFit.fit_label(_label(t), true)
	l.custom_minimum_size = Vector2(300, 0)
	l.tooltip_text = hint
	r.add_child(l)
	if hint != "":
		var n := MenuFit.fit_label(_label(hint), true)
		n.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
		n.add_theme_font_size_override("font_size", 12)
		p.add_child(n)
	return r


func _button(p: Control, t: String, f: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(f)
	p.add_child(b)
	return b


func _int(p: Control, t: String, key: String, hint: String) -> void:
	var r := _row(p, t, hint)
	var box := SpinBox.new()
	var rg: Array = WorldView.RANGES[key]
	box.min_value = rg[0]
	box.max_value = rg[1]
	box.step = 1
	box.value = int(v[key])
	box.value_changed.connect(func(x: float) -> void: v[key] = int(x))
	r.add_child(box)


func _float(p: Control, t: String, key: String, lo: float, hi: float, step: float, hint: String) -> void:
	var r := _row(p, t, hint)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.custom_minimum_size = Vector2(120, 0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := _label("")
	sl.value = float(v[key])
	val.text = "%.3f" % float(v[key])
	sl.value_changed.connect(func(x: float) -> void:
		v[key] = x
		val.text = "%.3f" % x)
	r.add_child(sl)
	r.add_child(val)


func _check(p: Control, t: String, key: String, hint: String) -> void:
	var r := _row(p, t, hint)
	var c := CheckBox.new()
	c.button_pressed = bool(v[key])
	c.toggled.connect(func(on: bool) -> void: v[key] = on)
	r.add_child(c)


func _pick(p: Control, t: String, key: String, choices: Array, hint: String) -> void:
	var r := _row(p, t, hint)
	var o := OptionButton.new()
	for i in choices.size():
		o.add_item(str(choices[i]), i)
	o.select(int(v[key]))
	o.item_selected.connect(func(i: int) -> void: v[key] = i)
	r.add_child(o)
