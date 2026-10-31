class_name SpaceMarkers
extends Control

## Where everything too small to see is (Docs/Planets.md 11.12 step 5): a mark on
## each body the player is not on, with its name and how far off; off the screen,
## an arrow at the edge the way to turn. A moon or a station only when it is near,
## or a system's planets would be lost among them. A body big enough on screen to
## see needs none.

## A body this wide on screen, pixels, has no mark.
const SEEN_PX := 48.0
## Moons and stations are marked inside this, metres.
const NEAR_ONLY := 300000.0
## How far in from the edges an arrow sits, pixels.
const EDGE := 36.0
const PLANET := Color(0.85, 0.9, 1.0)
const SETTLED := Color(0.55, 1.0, 0.65)
const SMALL := Color(0.6, 0.85, 0.95)

var system: PlanetSystem
## What is marked this frame: [name, metres, screen point, on the screen].
var rows: Array = []
var _colours: Array[Color] = []


func _process(_delta: float) -> void:
	rows.clear()
	_colours.clear()
	var cam := get_viewport().get_camera_3d()
	if not visible or cam == null or system == null:
		return
	for i in system.bodies.size():
		var b: PlanetBody = system.bodies[i]
		if b == system.anchor:
			continue
		var moon: bool = system.sys.bodies[i].parent >= 0
		var colour := SMALL if moon else (SETTLED if not b.data.towns.is_empty() else PLANET)
		_mark(cam, b.data.planet_name, b.global_position, b.data.radius, moon, colour)
	for st in system.stations:
		if st.is_station() and st != system.station:
			_mark(cam, st.data.orbital_name, st.global_position, 0.0, true, SMALL)
	queue_redraw()


func _mark(cam: Camera3D, label: String, at: Vector3, radius: float, near_only: bool, colour: Color) -> void:
	var view := get_viewport_rect().size
	var to := at - cam.global_position
	var d := to.length()
	if near_only and d > NEAR_ONLY:
		return
	if 2.0 * radius / d * view.y / (2.0 * tan(deg_to_rad(cam.fov) * 0.5)) > SEEN_PX:
		return
	var dir := to / d
	var local := cam.global_basis.inverse() * dir
	var p := Vector2.ZERO
	var on := local.z < 0.0
	if on:
		# A point on the same line: the far plane is much nearer than most of these.
		p = cam.unproject_position(cam.global_position + dir * 100.0)
		on = Rect2(Vector2.ONE * EDGE, view - Vector2.ONE * EDGE * 2.0).has_point(p)
	if not on:
		var way := Vector2(local.x, -local.y).normalized()
		if way == Vector2.ZERO:
			way = Vector2.UP
		var half := view * 0.5 - Vector2.ONE * EDGE
		p = view * 0.5 + way * minf(half.x / maxf(absf(way.x), 0.001), half.y / maxf(absf(way.y), 0.001))
	rows.append([label, d, p, on])
	_colours.append(colour)


static func distance_text(d: float) -> String:
	if d < 10000.0:
		return "%.0f m" % d
	if d < 1e7:
		return "%.0f km" % (d / 1000.0)
	return "%.1f thousand km" % (d / 1e6)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var view := get_viewport_rect().size
	for i in rows.size():
		var e: Array = rows[i]
		var p: Vector2 = e[2]
		var c := _colours[i]
		if e[3]:
			draw_polyline(PackedVector2Array([p + Vector2(0, -7), p + Vector2(7, 0), p + Vector2(0, 7), p + Vector2(-7, 0), p + Vector2(0, -7)]), c, 1.5)
		else:
			var way := (p - view * 0.5).normalized()
			var side := way.orthogonal()
			draw_colored_polygon(PackedVector2Array([p + way * 10.0, p + side * 7.0, p - side * 7.0]), c)
		var text := "%s  %s" % [e[0], distance_text(e[1])]
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		# To the left of a mark too near the right edge for it.
		var x := p.x + 12.0 if p.x + 12.0 + w < view.x - 4.0 else p.x - w - 12.0
		var at := Vector2(x, clampf(p.y + 4.0, 16.0, view.y - 6.0))
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color(0, 0, 0, 0.8))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, c)
