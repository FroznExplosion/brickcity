class_name UniversePanel
extends Control

## The universes on disk (UniverseSave), from the map: each its own save, as
## zylanntest's universe list. No mouse: the mouse flies.

var rows: Array = []
var here := ""
var pick := 0
var root := UniverseSave.ROOT


func open(p_here: String, p_root: String) -> void:
	here = p_here
	root = p_root
	rows = UniverseSave.list(root)
	pick = 0
	for i in rows.size():
		if rows[i].id == here:
			pick = i
	visible = true
	queue_redraw()


func move(step: int) -> void:
	pick = posmod(pick + step, maxi(rows.size(), 1))
	queue_redraw()


func chosen() -> String:
	return rows[pick].id if not rows.is_empty() else ""


## A new universe, its seed unused so far. Returns its id.
func new_universe() -> String:
	var used := {}
	for r in rows:
		used[int(r.seed)] = true
	var s := 1
	while used.has(s):
		s += 1
	return UniverseSave.make("Universe %d" % s, s, root).universe_id


func _draw() -> void:
	var view := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, view), Color(0.01, 0.02, 0.05, 0.95))
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(24, 36), "UNIVERSES  --  Up/Down pick, Enter play, N new, U close", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.85, 0.95))
	for i in rows.size():
		var r: Dictionary = rows[i]
		var c := Color(1.0, 0.9, 0.5) if i == pick else Color(0.75, 0.8, 0.9)
		var mark := "> " if i == pick else "  "
		var text := "%s%s  seed %d%s" % [mark, r.name, r.seed, "  (here)" if r.id == here else ""]
		draw_string(font, Vector2(24, 72 + i * 22), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, c)
