class_name ColourTable
extends RefCounted

## The colour table on import (Docs/BuildTools.md section 21, stages 8c and 8d), shared by the
## building workshop's Generate > Model and the asset workshop's Make bricks: each colour a
## model became (a colour index of `material`) with how many cells have it, and the colour it
## is laid in instead -- picked by hand, or by Fewer colours merging the nearest.

signal edited

var material := 0
## Colour index -> cells.
var counts := {}
## Colour index -> the colour index it is laid in (absent: itself).
var remap := {}


## The colour a cell of colour `c` is laid in.
func map(c: int) -> int:
	return int(remap.get(c, c))


## [the colour the model became, the colour it will be, cells] each, most cells first.
func table() -> Array:
	var out := []
	for c in counts:
		out.append([c, map(c), int(counts[c])])
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[2] > b[2] if a[2] != b[2] else a[0] < b[0])
	return out


## How many colours it will be laid in.
func colour_count() -> int:
	var seen := {}
	for c in counts:
		seen[map(c)] = true
	return seen.size()


func set_colour(from: int, to: int) -> void:
	if to == from:
		remap.erase(from)
	else:
		remap[from] = to
	edited.emit()


## Merge the two nearest colours (Oklab), the one with fewer cells into the other, until `n`
## are left.
func fewer(n: int) -> void:
	n = maxi(1, n)
	while true:
		var count := {}
		for c in counts:
			count[map(c)] = int(count.get(map(c), 0)) + int(counts[c])
		var cols := count.keys()
		if cols.size() <= n:
			break
		var best := INF
		var pair := []
		for i in cols.size():
			var qi := ColourMatch.oklab(BrickWorld.get_material_colour(material, cols[i]))
			for j in range(i + 1, cols.size()):
				var d := qi.distance_squared_to(ColourMatch.oklab(BrickWorld.get_material_colour(material, cols[j])))
				if d < best:
					best = d
					pair = [cols[i], cols[j]]
		var small: int = pair[0] if count[pair[0]] < count[pair[1]] else pair[1]
		var big: int = pair[1] if small == pair[0] else pair[0]
		for c in counts:
			if map(c) == small:
				remap[c] = big
	edited.emit()


func reset() -> void:
	remap = {}
	edited.emit()


# --- On the screen --------------------------------------------------------------------------

const ROWS := 12
var _pick: PopupPanel
var _pick_from := -1


## A flat button in a colour of `material`.
static func swatch(mat: int, colour: int, text := "") -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(22, 18)
	b.text = text
	var c := BrickWorld.get_material_colour(mat, colour)
	for st in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = c.lightened(0.15) if st == "hover" else c
		sb.set_corner_radius_all(3)
		b.add_theme_stylebox_override(st, sb)
	b.add_theme_color_override("font_color", Color.BLACK if c.get_luminance() > 0.5 else Color.WHITE)
	b.tooltip_text = BrickWorld.get_material_colour_name(mat, colour)
	return b


## The rows into `box` (emptied first): a row a colour, most cells first, ROWS at most. A
## changed one shows "*"; its button opens the picker. `none`: the colour shown for -1.
func fill(box: Container, none: int) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	var rows := table()
	for k in mini(rows.size(), ROWS):
		var r: Array = rows[k]
		var row := HBoxContainer.new()
		box.add_child(row)
		var from := swatch(material, r[0] if r[0] >= 0 else none)
		from.disabled = true
		row.add_child(from)
		var l := Label.new()
		l.text = "%d cells ->" % int(r[2])
		l.add_theme_font_size_override("font_size", 12)
		row.add_child(l)
		var to := swatch(material, r[1] if r[1] >= 0 else none, "" if r[0] == r[1] else "*")
		to.tooltip_text = "Lay this colour as another: click to pick it."
		var from_id: int = r[0]
		to.pressed.connect(func() -> void: open_pick(from_id, to))
		row.add_child(to)
	if rows.size() > ROWS:
		var more := Label.new()
		more.text = "and %d more" % (rows.size() - ROWS)
		box.add_child(more)


## Fewer colours (with its count) and Reset colours, into `box`.
static func buttons(box: Container, t: Callable) -> SpinBox:
	var frow := HBoxContainer.new()
	box.add_child(frow)
	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = 64
	spin.value = 4
	var fb := Button.new()
	fb.text = "Fewer colours"
	fb.focus_mode = Control.FOCUS_NONE
	fb.pressed.connect(func() -> void: (t.call() as ColourTable).fewer(int(spin.value)))
	frow.add_child(fb)
	frow.add_child(spin)
	# Its own line: beside the others the pop-out was wider than the rail.
	var rb := Button.new()
	rb.text = "Reset colours"
	rb.focus_mode = Control.FOCUS_NONE
	rb.pressed.connect(func() -> void: (t.call() as ColourTable).reset())
	box.add_child(rb)
	return spin


## The material's colours to pick from for colour `from`, beside `at` (or centred).
func open_pick(from: int, at: Control = null) -> void:
	_pick_from = from
	if _pick == null or not is_instance_valid(_pick):
		_pick = PopupPanel.new()
		(Engine.get_main_loop() as SceneTree).root.add_child(_pick)
	for c in _pick.get_children():
		_pick.remove_child(c)
		c.queue_free()
	var grid := GridContainer.new()
	grid.columns = 8
	_pick.add_child(grid)
	for i in ColourMatch.indices(material):
		var sw := swatch(material, i)
		var pick := i
		sw.pressed.connect(func() -> void:
				_pick.hide()
				set_colour(_pick_from, pick))
		grid.add_child(sw)
	if at != null and at.is_inside_tree():
		_pick.popup(Rect2i(Vector2i(at.get_screen_position() + Vector2(at.size.x + 4, 0)), Vector2i.ZERO))
	else:
		_pick.popup_centered()


func picker() -> PopupPanel:
	return _pick
