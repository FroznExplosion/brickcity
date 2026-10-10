class_name SkillScreen
extends CanvasLayer
## The skill tree's screen (SkillTree, COMBAT_DESIGN 1.3): the backpack's second page
## (PlayerArsenal: I opens it, Tab turns to here). The tree grows up the screen, tier 0
## at the bottom; a tier still shut is dim, with the points it waits for at its left.
##
##   arrows / wheel   choose a node
##   Enter or Space   a point into it
##   Backspace twice  every point back (free, for now)
##   + (developer)    a level up, to try the tree
##
## Keys only: the game keeps the mouse captured, and this does not take it.

const BG := Color(0.05, 0.06, 0.08, 0.92)
const DIM := Color(1, 1, 1, 0.45)
const RESET_WINDOW := 2.0

var progress: PlayerLevel
var cursor: StringName = &"vitality"
## A line for the footer ("Opens at 15 points spent"), and how long it stays.
var note := ""
var _note_left := 0.0
var _reset_armed := 0.0
var _draw_node: Control


func _ready() -> void:
	layer = 6
	_draw_node = Control.new()
	_draw_node.set_anchors_preset(Control.PRESET_FULL_RECT)
	_draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_node.draw.connect(_draw_all)
	_draw_node.visible = false
	add_child(_draw_node)


func show_screen(on: bool) -> void:
	if _draw_node != null:
		_draw_node.visible = on
		_draw_node.queue_redraw()


func is_shown() -> bool:
	return _draw_node != null and _draw_node.visible


func _process(delta: float) -> void:
	if _note_left > 0.0:
		_note_left -= delta
		if _note_left <= 0.0:
			note = ""
	_reset_armed = maxf(_reset_armed - delta, 0.0)
	if is_shown():
		_draw_node.queue_redraw()


func _say(s: String) -> void:
	note = s
	_note_left = 2.5


## A key while the screen is up. True if it was this screen's.
func handle(event: InputEvent) -> bool:
	if progress == null:
		return false
	var dir := Vector2i.ZERO
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT:
				dir = Vector2i(-1, 0)
			KEY_RIGHT:
				dir = Vector2i(1, 0)
			KEY_UP:
				dir = Vector2i(0, -1)
			KEY_DOWN:
				dir = Vector2i(0, 1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				spend()
				return true
			KEY_BACKSPACE, KEY_DELETE:
				if _reset_armed > 0.0:
					progress.reset_tree()
					_reset_armed = 0.0
					_say("Every point back")
				elif progress.tree.spent() > 0:
					_reset_armed = RESET_WINDOW
					_say("Backspace again: take every point back")
				return true
			KEY_EQUAL, KEY_KP_ADD:
				if DevMode.on:
					progress.add_xp(PlayerLevel.xp_to_next(progress.level) - progress.xp)
					_say("Level %d (developer)" % progress.level)
					return true
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			dir = Vector2i(0, -1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dir = Vector2i(0, 1)
	if dir != Vector2i.ZERO:
		cursor = SkillTree.neighbour(cursor, dir)
		return true
	return false


## A point into the node under the cursor.
func spend() -> bool:
	var why := progress.tree.why_not(cursor, progress.points_free())
	if why != "":
		_say(why)
		return false
	progress.buy(cursor)
	return true


# --- drawing ------------------------------------------------------------------------

func _draw_all() -> void:
	if progress == null:
		return
	var c := _draw_node
	var font := ThemeDB.fallback_font
	var sz := c.size
	var w := minf(sz.x - 48.0, 1080.0)
	var h := minf(sz.y - 40.0, 680.0)
	var r := Rect2((sz - Vector2(w, h)) * 0.5, Vector2(w, h))
	c.draw_rect(r, BG)
	var tree := progress.tree

	# The header: level, XP, points.
	var x0 := r.position.x + 18.0
	c.draw_string(font, Vector2(x0, r.position.y + 30.0), "SKILLS", HORIZONTAL_ALIGNMENT_LEFT, -1,
			20, Color.WHITE)
	var need := PlayerLevel.xp_to_next(progress.level)
	var lv := "Level %d" % progress.level
	var xp_txt := ("XP %d / %d" % [progress.xp, need]) if need > 0 else "Top level"
	c.draw_string(font, Vector2(x0 + 100.0, r.position.y + 30.0), lv, HORIZONTAL_ALIGNMENT_LEFT, -1,
			18, Color.WHITE)
	var bar := Rect2(x0 + 190.0, r.position.y + 18.0, 200.0, 8.0)
	c.draw_rect(bar, Color(1, 1, 1, 0.15))
	if need > 0:
		c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(progress.xp) / need, bar.size.y)),
				Color(0.4, 0.85, 1.0))
	c.draw_string(font, Vector2(bar.position.x, r.position.y + 44.0), xp_txt, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 12, DIM)
	var free := progress.points_free()
	var pts := "%d point%s to spend   ·   %d spent" % [free, "" if free == 1 else "s", tree.spent()]
	var pw := font.get_string_size(pts, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	c.draw_string(font, Vector2(r.end.x - 18.0 - pw, r.position.y + 30.0), pts, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 16, Color(1.0, 0.85, 0.4) if free > 0 else DIM)

	# The tree's grid: a gutter for the tiers, the limbs' names over their columns.
	var gutter := 86.0
	var area := Rect2(r.position.x + gutter, r.position.y + 78.0, w - gutter - 16.0, h - 78.0 - 84.0)
	var col_w := area.size.x / SkillTree.COLS
	var row_h := area.size.y / SkillTree.TIERS
	var bw := minf(col_w - 10.0, 108.0)
	var bh := minf(row_h - 12.0, 44.0)
	for limb in [[&"gunner", 1], [&"survivor", 4], [&"tactician", 7]]:
		var info: Array = SkillTree.LIMBS[limb[0]]
		var name_s := String(info[0]).to_upper()
		var nw := font.get_string_size(name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		c.draw_string(font, Vector2(area.position.x + (int(limb[1]) + 0.5) * col_w - nw * 0.5,
				area.position.y - 8.0), name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, info[1])
	for t in SkillTree.TIERS:
		var y := area.end.y - (t + 1) * row_h
		var open := tree.tier_open(t)
		if not open:
			c.draw_rect(Rect2(area.position.x, y + 2.0, area.size.x, row_h - 4.0), Color(0, 0, 0, 0.35))
		var lab := "Tier %d" % t
		c.draw_string(font, Vector2(r.position.x + 14.0, y + row_h * 0.5), lab, HORIZONTAL_ALIGNMENT_LEFT,
				-1, 13, Color.WHITE if open else DIM)
		if not open:
			c.draw_string(font, Vector2(r.position.x + 14.0, y + row_h * 0.5 + 15.0),
					"%d pts" % SkillTree.tier_gate(t), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)

	# The limbs: a line from each node to its parents, under the boxes.
	for n in SkillTree.NODES:
		var to := _centre(area, col_w, row_h, n)
		var col: Color = SkillTree.LIMBS[n.limb][1]
		col.a = 0.85 if tree.tier_open(int(n.tier)) else 0.25
		for pid in n.parents:
			var p := SkillTree.node(pid)
			var from := _centre(area, col_w, row_h, p)
			c.draw_line(from + Vector2(0, -bh * 0.5), to + Vector2(0, bh * 0.5), col,
					4.0 if tree.rank(n.id) > 0 else 2.0, true)

	# The nodes.
	for n in SkillTree.NODES:
		var at := _centre(area, col_w, row_h, n)
		var box := Rect2(at - Vector2(bw, bh) * 0.5, Vector2(bw, bh))
		var limb_col: Color = SkillTree.LIMBS[n.limb][1]
		var open := tree.tier_open(int(n.tier))
		var rk := tree.rank(n.id)
		var maxed := rk >= int(n.ranks)
		var fill := Color(0.11, 0.12, 0.15)
		if rk > 0:
			fill = limb_col.darkened(0.55 if not maxed else 0.3)
		c.draw_rect(box, fill)
		var edge := limb_col
		edge.a = 1.0 if open else 0.3
		c.draw_rect(box, edge, false, 2.0)
		if n.id == cursor:
			c.draw_rect(box.grow(4.0), Color.WHITE, false, 3.0)
		var tc := Color.WHITE if open else DIM
		var name_s: String = n.name
		var fs := 12
		var tw := font.get_string_size(name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if tw > bw - 6.0:
			fs = 10
			tw = font.get_string_size(name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		c.draw_string(font, Vector2(at.x - tw * 0.5, box.position.y + 16.0), name_s,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tc)
		var rs := "%d/%d" % [rk, int(n.ranks)]
		var rw := font.get_string_size(rs, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		c.draw_string(font, Vector2(at.x - rw * 0.5, box.end.y - 6.0), rs, HORIZONTAL_ALIGNMENT_LEFT, -1,
				13, Color(1.0, 0.85, 0.4) if maxed else tc)

	# The footer: the node under the cursor, then the keys.
	var sel := SkillTree.node(cursor)
	var fy := r.end.y - 58.0
	if not sel.is_empty():
		var limb_info: Array = SkillTree.LIMBS[sel.limb]
		var head := "%s   %d/%d   ·   %s, tier %d" % [sel.name, tree.rank(cursor), int(sel.ranks),
				limb_info[0], int(sel.tier)]
		c.draw_string(font, Vector2(x0, fy), head, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, limb_info[1])
		c.draw_string(font, Vector2(x0, fy + 20.0), tree.describe(cursor), HORIZONTAL_ALIGNMENT_LEFT, -1,
				14, Color.WHITE)
		var why := note if note != "" else tree.why_not(cursor, free)
		if why == "":
			why = "Enter: a point into it"
		var ww := font.get_string_size(why, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		c.draw_string(font, Vector2(r.end.x - 18.0 - ww, fy + 20.0), why, HORIZONTAL_ALIGNMENT_LEFT, -1,
				14, Color(1.0, 0.85, 0.4))
	var keys := "Arrows choose  ·  Enter spend  ·  Backspace twice: every point back  ·  Tab backpack  ·  I close"
	if DevMode.on:
		keys += "  ·  + level up (dev)"
	c.draw_string(font, Vector2(x0, r.end.y - 12.0), keys, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)


func _centre(area: Rect2, col_w: float, row_h: float, n: Dictionary) -> Vector2:
	return Vector2(area.position.x + (int(n.col) + 0.5) * col_w,
			area.end.y - (int(n.tier) + 0.5) * row_h)
