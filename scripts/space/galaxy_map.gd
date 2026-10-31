class_name GalaxyMap
extends Control

## The galaxy map (Docs/Planets.md 11.12 step 5; after STA Docs/15 §2): the star
## systems round the ship's, drawn from above, and the nearest ten listed with
## their stars and worlds. Keys, not the mouse -- the mouse flies: PlanetScene
## calls `move` and reads `chosen`.

## One row: [index, name, planets, settled worlds, star colour, light years].
var rows: Array = []
var pick := 0
var uni: Universe
var here := 0


## Open at system `index`; `home_sys` stands for system 0 (home's own).
func open(u: Universe, index: int, home_sys: StarSystem) -> void:
	uni = u
	here = index
	rows.clear()
	pick = 0
	var from := u.system_position(index)
	for k in u.nearest(index, 10):
		var s := home_sys if k == 0 else u.system(k)
		var planets := 0
		var settled := 0
		for d in s.bodies:
			planets += int(d.parent < 0)
			settled += int(not d.towns.is_empty() or k == 0 and d == s.bodies[s.home])
		rows.append([k, s.system_name, planets, settled, s.star_color, from.distance_to(u.system_position(k))])
	visible = true
	queue_redraw()


func move(step: int) -> void:
	pick = posmod(pick + step, rows.size())
	queue_redraw()


## The picked system's index.
func chosen() -> int:
	return int(rows[pick][0])


func _draw() -> void:
	var size_px := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, size_px), Color(0.01, 0.02, 0.05, 0.92))
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(24, 36), "GALAXY  --  Up/Down pick, J jump, M close", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.85, 0.95))
	var c := Vector2(size_px.x * 0.36, size_px.y * 0.54)
	var from := uni.system_position(here)
	var reach := 1.0
	for r in rows:
		reach = maxf(reach, float(r[5]))
	var scale_px := minf(size_px.x * 0.32, size_px.y * 0.42) / reach
	for k in Universe.SYSTEMS:
		var p := uni.system_position(k) - from
		var at := c + Vector2(p.x, p.z) * scale_px
		if at.x > 0.0 and at.x < size_px.x * 0.7 and at.y > 48.0 and at.y < size_px.y:
			draw_circle(at, 1.5, Color(0.5, 0.55, 0.65))
	draw_circle(c, 5.0, Color(0.5, 1.0, 0.6))
	for i in rows.size():
		var r: Array = rows[i]
		var p := uni.system_position(int(r[0])) - from
		var at := c + Vector2(p.x, p.z) * scale_px
		draw_circle(at, 4.0, r[4])
		if i == pick:
			draw_arc(at, 9.0, 0.0, TAU, 24, Color.WHITE, 1.5)
			draw_line(c, at, Color(1, 1, 1, 0.35), 1.0)
		draw_string(font, at + Vector2(8, 4), str(r[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.8, 0.9))
		var line := "%s  %.0f ly  %d planets, %d settled" % [r[1], r[5], r[2], r[3]]
		var y := 72.0 + i * 24.0
		draw_string(font, Vector2(size_px.x * 0.7, y), ("> " if i == pick else "  ") + line, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color.WHITE if i == pick else Color(0.7, 0.75, 0.85))
