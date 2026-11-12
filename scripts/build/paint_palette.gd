extends PanelContainer

## The PAINT palette: what a paint brush lays down, picked in one place.
## Docs/Terrain.md §20.7, Docs/BuildMode.md (the workshop's B brush).
##
## A row of materials and, under it, the colours the chosen material offers.
## It knows nothing about bricks or terrain: whoever shows it hands it the
## entries, so the workshop lists brick materials and their kinds, and the
## terrain editor lists ground materials and the filament palette. A value
## can be any int -- the terrain uses -1 for "leave it" and -2 for "put it
## back" -- and the palette only reports which was clicked.
##
## Preloaded, not named: a new `class_name` is not in the global class cache
## until the editor rescans, and a headless run reads that cache off disk.

signal picked(material: int, colour: int)

## [{value, name}] -- the material row.
var materials: Array = []
## func(material_value) -> [{value, name, color}] -- that material's colours.
var colours_for := Callable()
var pick_material := 0
var pick_colour := 0
## A line under the title, for the brush's size and strength.
var info := "":
	set(v):
		info = v
		if _info != null:
			_info.text = v

var _title: Label
var _info: Label
var _row: HFlowContainer
var _swatch_label: Label
var _swatches: GridContainer


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.9)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	add_theme_stylebox_override("panel", style)
	custom_minimum_size = Vector2(430, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 14)
	v.add_child(_title)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 12)
	_info.text = info
	v.add_child(_info)
	_row = HFlowContainer.new()
	_row.add_theme_constant_override("h_separation", 4)
	_row.add_theme_constant_override("v_separation", 4)
	v.add_child(_row)
	_swatch_label = Label.new()
	_swatch_label.add_theme_font_size_override("font_size", 12)
	v.add_child(_swatch_label)
	_swatches = GridContainer.new()
	_swatches.columns = 12
	_swatches.add_theme_constant_override("h_separation", 3)
	_swatches.add_theme_constant_override("v_separation", 3)
	v.add_child(_swatches)
	rebuild()


## Show these entries, with this pair chosen.
func setup(p_materials: Array, p_colours_for: Callable, p_material: int, p_colour: int) -> void:
	materials = p_materials
	colours_for = p_colours_for
	pick_material = p_material
	pick_colour = p_colour
	rebuild()


## Choose, from outside (a key, an eyedropper), without re-announcing it.
func show_pick(p_material: int, p_colour: int) -> void:
	var rebuild_colours := p_material != pick_material
	pick_material = p_material
	pick_colour = p_colour
	if rebuild_colours:
		rebuild()
	else:
		_refresh()


func rebuild() -> void:
	if _row == null:
		return
	for child in _row.get_children():
		child.queue_free()
	for e in materials:
		var b := Button.new()
		b.text = str(e["name"])
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_on_material.bind(int(e["value"])))
		b.set_meta("value", int(e["value"]))
		_row.add_child(b)
	for child in _swatches.get_children():
		child.queue_free()
	var list: Array = colours_for.call(pick_material) if colours_for.is_valid() else []
	for e in list:
		var b := Button.new()
		b.custom_minimum_size = Vector2(30, 24)
		b.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = e["color"]
		sb.set_corner_radius_all(4)
		b.add_theme_stylebox_override("normal", sb)
		var hi := sb.duplicate() as StyleBoxFlat
		hi.set_border_width_all(2)
		hi.border_color = Color(1, 1, 1)
		b.add_theme_stylebox_override("hover", hi)
		b.add_theme_stylebox_override("pressed", hi)
		b.set_meta("hi", hi)
		b.set_meta("lo", sb)
		b.set_meta("value", int(e["value"]))
		if e.has("mark"):
			b.text = str(e["mark"])
			b.add_theme_font_size_override("font_size", 11)
		b.tooltip_text = str(e["name"])
		b.pressed.connect(_on_colour.bind(int(e["value"])))
		_swatches.add_child(b)
	_refresh()


func _refresh() -> void:
	if _title == null:
		return
	var mname := ""
	for e in materials:
		if int(e["value"]) == pick_material:
			mname = str(e["name"])
	var cname := ""
	var list: Array = colours_for.call(pick_material) if colours_for.is_valid() else []
	for e in list:
		if int(e["value"]) == pick_colour:
			cname = str(e["name"])
	_title.text = "PAINT   %s   %s" % [mname, cname]
	_swatch_label.text = "colours (%d)" % list.size()
	for b in _row.get_children():
		(b as Button).button_pressed = int(b.get_meta("value")) == pick_material
	for b in _swatches.get_children():
		var on := int(b.get_meta("value")) == pick_colour
		(b as Button).add_theme_stylebox_override("normal",
				b.get_meta("hi") if on else b.get_meta("lo"))


func _on_material(v: int) -> void:
	pick_material = v
	# The colour is kept where the new material offers it.
	var list: Array = colours_for.call(pick_material) if colours_for.is_valid() else []
	var ok := false
	for e in list:
		if int(e["value"]) == pick_colour:
			ok = true
	if not ok and not list.is_empty():
		pick_colour = int(list[0]["value"])
	rebuild()
	picked.emit(pick_material, pick_colour)


func _on_colour(v: int) -> void:
	pick_colour = v
	_refresh()
	picked.emit(pick_material, pick_colour)


## Step through the materials or the colours, for keys.
func step_material(d: int) -> void:
	var i := 0
	for k in materials.size():
		if int(materials[k]["value"]) == pick_material:
			i = k
	_on_material(int(materials[posmod(i + d, materials.size())]["value"]))


func step_colour(d: int) -> void:
	var list: Array = colours_for.call(pick_material) if colours_for.is_valid() else []
	if list.is_empty():
		return
	var i := 0
	for k in list.size():
		if int(list[k]["value"]) == pick_colour:
			i = k
	_on_colour(int(list[posmod(i + d, list.size())]["value"]))
