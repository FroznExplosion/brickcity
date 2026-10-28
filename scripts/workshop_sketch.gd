class_name SketchPen
extends RefCounted

## The Sketch tool's pen, shared by both workshops (Docs/BuildTools.md, section 0): the
## stroke being drawn on a plane -- freehand outline, brush, rectangle, ellipse or clicked
## polygon -- what it comes to (an outline or a brush stroke), the lines that show it, and
## the cells inside. What a finished stroke BECOMES is each workshop's own: the asset
## workshop draws it into a part's sketch, the building workshop makes a kept shape.
##
## Points are in the plane's own numbers (across it, up it): cells, as floats.

const DRAWS := [["outline", "outline (freehand)"], ["brush", "brush"], ["rect", "rectangle"],
		["ellipse", "ellipse"], ["polygon", "polygon (click corners)"]]

var draw := "outline"
## The stroke so far.
var points: Array[Vector2] = []
## Where a rectangle or an ellipse was started.
var anchor := Vector2.ZERO
## Drawn with RMB: area out, not in.
var out := false


## A button down at `q`: a new stroke (not for a polygon: `polygon_click`).
func press(q: Vector2, remove: bool) -> void:
	points.clear()
	out = remove
	anchor = q
	points.append(q)


## The cursor moved to `q` with the button held. `brush_size`: a brush's reach, so its
## path is kept in steps a quarter of it.
func move(q: Vector2, brush_size: int = 1) -> void:
	match draw:
		"rect", "ellipse":
			points.assign(drag_shape(draw, anchor, q))
		"brush":
			if points.is_empty() or q.distance_to(points.back()) > maxf(0.25, brush_size * 0.25):
				points.append(q)
		_:
			if points.is_empty() or q.distance_to(points.back()) > 0.3:
				points.append(q)


## Polygon: each click a corner (the first click's button says in or out). True when this
## click closes it -- on the first corner, or a double click -- and it is ready to commit.
func polygon_click(q: Vector2, remove: bool, double: bool) -> bool:
	if points.is_empty():
		out = remove
	elif double or (points.size() >= 3 and q.distance_to(points[0]) < 0.7):
		return true
	points.append(q)
	return false


## Enter closes a polygon (true: commit it), Backspace takes its last corner back.
func polygon_key(e: InputEventKey) -> String:
	if points.is_empty() or not e.pressed:
		return ""
	match e.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			return "commit"
		KEY_BACKSPACE:
			points.pop_back()
			return "back"
	return ""


## What the stroke comes to: a brush stroke (`brush_entry`), an outline [[x, y], ...], or
## null when it is too little to be either. `plane`: "top" for a flat plane (a stud each
## way), anything else for a standing one (a stud across is two and a half plates up).
func entry(plane: String, brush_size: int, square: bool) -> Variant:
	if draw == "brush":
		if points.is_empty():
			return null
		return brush_entry(points, brush_size, square, plane)
	if points.size() < 3:
		return null
	var plain := []
	for q in points:
		plain.append([q.x, q.y])
	return plain


## The lines that show the stroke, in plane numbers: [[from, to, colour], ...] -- the
## stroke (closed where it will be), a polygon's edge to the cursor, a brush's reach round
## the cursor. `mouse`: the cursor on the plane, or null.
func preview(mouse: Variant, plane: String, brush_size: int, square: bool) -> Array:
	var segs := []
	var col := Color(1.0, 0.35, 0.3) if out else Color(1, 1, 1)
	var line: Array[Vector2] = points.duplicate()
	var closed := draw in ["outline", "rect", "ellipse"]
	if draw == "polygon" and not line.is_empty() and mouse != null:
		line.append(mouse)
	if draw == "brush" and mouse != null:
		var e := brush_entry([mouse], brush_size, square, plane)
		var ring: Array[Vector2] = drag_shape("rect" if e.square else "ellipse",
				mouse - Vector2(e.rx, e.ry), mouse + Vector2(e.rx, e.ry))
		for i in ring.size():
			segs.append([ring[i], ring[(i + 1) % ring.size()], Color(0.6, 0.9, 1.0)])
	if line.size() >= 2:
		for i in (line.size() if closed else line.size() - 1):
			segs.append([line[i], line[(i + 1) % line.size()], col])
	return segs


## A rectangle or an ellipse dragged from corner `a` to corner `b`, as an outline.
static func drag_shape(kind: String, a: Vector2, b: Vector2) -> Array[Vector2]:
	var res: Array[Vector2] = []
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	if kind == "rect":
		res.assign([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])
		return res
	var c := (lo + hi) * 0.5
	var r := (hi - lo) * 0.5
	for i in 32:
		var t := TAU * i / 32.0
		res.append(c + Vector2(cos(t) * r.x, sin(t) * r.y))
	return res


## A brush stroke as a sketch entry: its path, and its reach across and up the plane (a
## stud across is two and a half plates up on a standing plane, "top" is flat).
static func brush_entry(path: Array, size: int, square: bool, plane: String) -> Dictionary:
	var pts := []
	for q in path:
		pts.append([q.x, q.y])
	var rx := maxf(0.5, float(size))
	return {"brush": pts, "rx": rx, "ry": rx * (1.0 if plane == "top" else 2.5), "square": square}


## The cells an outline ([[x, y] ...]) or a brush stroke (`brush_entry`) covers.
##
## An outline's cells are those whose centres it winds round -- by winding, not even-odd
## (a stretch circled twice is in, not cancelled out) -- and then the outermost: whatever
## the outside cannot reach is in, holes the crossing made included.
static func region_cells(poly: Variant) -> Dictionary:
	if poly is Dictionary:
		return brush_cells(poly)
	var pts := PackedVector2Array()
	for q in poly:
		pts.append(q if q is Vector2 else Vector2(float(q[0]), float(q[1])))
	if pts.size() < 3:
		return {}
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for q in pts:
		lo = Vector2i(mini(lo.x, int(floor(q.x))), mini(lo.y, int(floor(q.y))))
		hi = Vector2i(maxi(hi.x, int(ceil(q.x))), maxi(hi.y, int(ceil(q.y))))
	# A bitmap one cell wider all round, so the outside is connected: 1 inside, 2 outside.
	var w := hi.x - lo.x + 2
	var h := hi.y - lo.y + 2
	var map := PackedByteArray()
	map.resize(w * h)
	# A row at a time: where each edge crosses the row's centre line, and which way.
	var n := pts.size()
	for v in range(lo.y, hi.y):
		var y := v + 0.5
		var xs := []
		for i in n:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if (a.y <= y) == (b.y <= y):
				continue
			xs.append([a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x), 1 if b.y > a.y else -1])
		if xs.is_empty():
			continue
		xs.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
		var wind := 0
		for j in xs.size() - 1:
			wind += int(xs[j][1])
			if wind == 0:
				continue
			# Cells whose centres lie between this crossing and the next.
			var u0 := maxi(lo.x, int(ceil(float(xs[j][0]) - 0.5)))
			var u1 := mini(hi.x - 1, int(ceil(float(xs[j + 1][0]) - 0.5)) - 1)
			for u in range(u0, u1 + 1):
				map[(v - lo.y + 1) * w + (u - lo.x + 1)] = 1
	var todo := PackedInt32Array([0])
	map[0] = 2
	while not todo.is_empty():
		var at := todo[todo.size() - 1]
		todo.resize(todo.size() - 1)
		var ax := at % w
		@warning_ignore("integer_division")
		var ay := at / w
		for nb in [at - 1 if ax > 0 else -1, at + 1 if ax < w - 1 else -1, at - w if ay > 0 else -1,
				at + w if ay < h - 1 else -1]:
			if nb >= 0 and map[nb] == 0:
				map[nb] = 2
				todo.append(nb)
	var res := {}
	for v in range(lo.y, hi.y):
		for u in range(lo.x, hi.x):
			if map[(v - lo.y + 1) * w + (u - lo.x + 1)] != 2:
				res[Vector2i(u, v)] = true
	return res


## The cells a brush stroke covers: every cell whose centre is within its reach of the
## path (an ellipse, or a box when square), the path walked in steps shorter than that.
static func brush_cells(stroke: Dictionary) -> Dictionary:
	var res := {}
	var rx := float(stroke.get("rx", 0.5))
	var ry := float(stroke.get("ry", 0.5))
	var square := bool(stroke.get("square", false))
	var path: Array = stroke.get("brush", [])
	var pts: Array[Vector2] = []
	for i in path.size():
		var b := Vector2(float(path[i][0]), float(path[i][1]))
		if i > 0:
			var a: Vector2 = pts.back()
			var steps := int(ceil(maxf(absf(b.x - a.x) / (rx * 0.5), absf(b.y - a.y) / (ry * 0.5))))
			for k in range(1, steps):
				pts.append(a.lerp(b, float(k) / steps))
		pts.append(b)
	for p in pts:
		for u in range(int(floor(p.x - rx)), int(ceil(p.x + rx)) + 1):
			for v in range(int(floor(p.y - ry)), int(ceil(p.y + ry)) + 1):
				var d := Vector2((u + 0.5 - p.x) / rx, (v + 0.5 - p.y) / ry)
				if (maxf(absf(d.x), absf(d.y)) <= 1.0) if square else (d.length_squared() <= 1.0):
					res[Vector2i(u, v)] = true
	return res
