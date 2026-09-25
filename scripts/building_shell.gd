class_name BuildingShell

## The far LOD tier: what an undamaged building looks like when it holds no
## bricks at all. Plan.md §4.1.
##
## Measured reason this exists: a 150 m tower is 220 MB and 685k triangles once
## its bricks are meshed, so twenty of them is not a rendering budget, it is a
## crash. A shell is built straight from the recipe parameters — the same
## dimensions, the same course colours, none of the bricks — and comes out
## around 30x cheaper.
##
## It is deliberately NOT a box. Course banding is what makes a brick building
## read as a brick building at distance, and the seam shader needs UV/UV2, so
## the shell is built a course at a time and carries both.

const STUD := 0.35
const PLATE := 0.14

## The seam shader tiles UV by UV2, so a shell face carrying a BRICK-sized UV2
## gets a grid of brick outlines instead of one outline around the whole wall.
## That is what makes an undamaged building read as brick at any distance,
## without a single extra triangle. A standard brick face is two studs wide and
## one course tall.
const SEAM_UNIT := Vector2(2.0 * STUD, 3.0 * PLATE)
const SEAM_UNIT_FLAT := Vector2(2.0 * STUD, 2.0 * STUD)

## How finely a damaged band is cut up along each wall run. Gate G1b.
##
## A shell is generated from the recipe and has no way to ask "is block N
## dead", so damage reaches it as a coarse SEGMENT MASK: one bit per segment
## per side, set where that stretch of wall is still standing. 32 bits is one
## int, which is why it is 32 -- on a 48-stud wall that is 1.5 studs per
## segment, finer than a brick, and at shell range (110 m+) a hole is a few
## pixels wide anyway. What has to read right is that there IS one.
##
## An undamaged band carries no mask and emits exactly the quads it always did,
## so the intact case costs nothing.
const SEGMENTS := 32

## Side order used by the segment masks, matching the order _band emits.
const SIDE_FRONT := 0   ## -Z, runs along X
const SIDE_BACK := 1    ## +Z, runs along X
const SIDE_LEFT := 2    ## -X, runs along Z
const SIDE_RIGHT := 3   ## +X, runs along Z

const ALL_STANDING := -1  ## every bit set, as a 32-bit int


## Surface arrays for a hollow shell: outer faces, inner faces, wall tops.
## `courses`, `footprint_*` and the colour table all come from TowerRecipe, so
## the shell and the bricks agree about what the building is.
## `damage` is band index -> PackedInt32Array of four segment masks, in
## SIDE_* order. An absent band is intact. Empty means an undamaged building,
## which is the overwhelmingly common case and takes the original path.
static func build_arrays(footprint_x: int, footprint_z: int, courses: int,
		damage: Dictionary = {}) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()

	var t := TowerRecipe.WALL_THICK
	var w := footprint_x * STUD
	var d := footprint_z * STUD
	var tw := t * STUD

	# Walk the SAME layout the brick recipe walks, so the shell and the bricks
	# are the same building -- including the floor slabs, which are part of the
	# exterior and read as bands from outside.
	var top := 0.0
	# Grey, not filament 1 -- filament 1 is BLACK, and this is what a wall-top
	# cap falls back to if no band ever sets it.
	var top_colour := BrickWorld.get_filament_colour(TowerRecipe.SLAB_COLOUR)
	var top_hollow := false
	var band_index := 0
	for band in TowerRecipe.layout(courses):
		var masks: PackedInt32Array = damage.get(band_index, PackedInt32Array())
		band_index += 1

		# Nothing of this band's perimeter is standing, so it contributes no
		# walls AND no floor. Without this a flattened building still drew a
		# stack of floating slabs.
		if _band_is_gone(masks):
			top_hollow = false
			continue
		var y0: float = int(band.y) * PLATE
		var h: float = int(band.plates) * PLATE
		var y1 := y0 + h

		if band.kind == "base" or band.kind == "slab":
			# A slab spans the whole footprint, so its band is solid all round
			# and it caps with a visible top face.
			var sc: Color = BrickWorld.get_filament_colour(
					TowerRecipe.BASE_COLOUR if band.kind == "base" else TowerRecipe.SLAB_COLOUR)
			_band(verts, normals, colours, uvs, uv2s, indices, sc, y0, y1, w, d, 0.0, false, masks)
			# Top, then underside. A floor is seen from both sides once you are
			# inside the building: standing on one and looking up at the next.
			# The shell only ever had one of the two, and it was wound the wrong
			# way round, so a room showed the bottoms of floors and never a top.
			_cap(verts, normals, colours, uvs, uv2s, indices, sc, y1, w, d, true)
			if band.kind != "base":
				_cap(verts, normals, colours, uvs, uv2s, indices, sc, y0, w, d, false)
			top = y1
			top_colour = sc
			top_hollow = false
			continue

		# The cornice is NOT a ring. TowerRecipe places it as a run of buttresses
		# along the z=0 edge ONLY, in filament 1 -- which is black:
		#
		#     for x in range(0, footprint_x - 1, 2):
		#         world.place_block(chunk_id, Vector3i(x, band.y, 0), ..., 1)
		#
		# Drawing it as a full hollow band painted every roof with a black
		# border the bricks never had, which vanished the moment the building
		# materialised. Skipping it altogether was the opposite mistake: then the
		# shell had no black at all and the bricks had a row of it.
		#
		# One run along the front, reusing the damage-mask machinery: front
		# standing, the other three sides empty. `top` and `top_colour` are left
		# alone deliberately, so the wall-top cap below still lands on the last
		# COURSE, in that course's colour, which is what holds up the roof.
		if band.kind == "cornice":
			var front: int = _mask_for(masks, SIDE_FRONT)
			if front != 0:
				_band(verts, normals, colours, uvs, uv2s, indices,
						BrickWorld.get_filament_colour(1), y0, y1, w, d, 0.0, false,
						PackedInt32Array([front, 0, 0, 0]))
			continue

		var col := BrickWorld.get_filament_colour(1)
		if band.kind == "course":
			col = BrickWorld.get_filament_colour(
					TowerRecipe.COURSE_COLOURS[int(band.index) % TowerRecipe.COURSE_COLOURS.size()])
		_band(verts, normals, colours, uvs, uv2s, indices, col, y0, y1, w, d, tw, true, masks)
		top = y1
		top_colour = col
		top_hollow = true

	# Cap the wall tops. The real building's topmost course is a ring of bricks
	# and every one of them draws a top face; the shell's top band just stopped,
	# so looking down at a roof showed a paper-thin rim and straight through into
	# the building. Four quads fix it, and only the topmost band needs them --
	# every band below is capped by the one above.
	if top_hollow:
		_ring_cap(verts, normals, colours, uvs, uv2s, indices, top_colour, top, w, d, tw)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## The top of a hollow wall: a rectangular frame of four quads, `tw` thick.
static func _ring_cap(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		indices: PackedInt32Array, col: Color,
		y: float, w: float, d: float, tw: float) -> void:
	var n := Vector3(0, 1, 0)
	# Same winding rule as _cap's upward face: a, b across X, c, d across Z.
	_quad(verts, normals, colours, uvs, uv2s, indices, col,
			Vector3(0, y, 0), Vector3(w, y, 0), Vector3(0, y, tw), Vector3(w, y, tw),
			n, Vector2(w, tw), SEAM_UNIT_FLAT)
	_quad(verts, normals, colours, uvs, uv2s, indices, col,
			Vector3(0, y, d - tw), Vector3(w, y, d - tw), Vector3(0, y, d), Vector3(w, y, d),
			n, Vector2(w, tw), SEAM_UNIT_FLAT)
	_quad(verts, normals, colours, uvs, uv2s, indices, col,
			Vector3(0, y, tw), Vector3(tw, y, tw), Vector3(0, y, d - tw), Vector3(tw, y, d - tw),
			n, Vector2(tw, d - tw * 2.0), SEAM_UNIT_FLAT)
	_quad(verts, normals, colours, uvs, uv2s, indices, col,
			Vector3(w - tw, y, tw), Vector3(w, y, tw), Vector3(w - tw, y, d - tw), Vector3(w, y, d - tw),
			n, Vector2(tw, d - tw * 2.0), SEAM_UNIT_FLAT)


## A horizontal slab face at height `y`. `upward` picks which way it is seen
## from.
##
## Winding matters and is easy to get backwards: Godot treats CLOCKWISE as
## front-facing, so the corner order has to make (b-a) x (c-a) point AWAY from
## the side the face is meant to be seen from. Every wall quad in this file
## already obeys that; the old top cap did not, which is why floors were only
## visible from underneath.
static func _cap(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		indices: PackedInt32Array, col: Color,
		y: float, w: float, d: float, upward: bool) -> void:
	if upward:
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(0, y, 0), Vector3(w, y, 0), Vector3(0, y, d), Vector3(w, y, d),
				Vector3(0, 1, 0), Vector2(w, d), SEAM_UNIT_FLAT)
	else:
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(0, y, 0), Vector3(0, y, d), Vector3(w, y, 0), Vector3(w, y, d),
				Vector3(0, -1, 0), Vector2(w, d), SEAM_UNIT_FLAT)


## One horizontal band of the building: four outer faces, and four inner ones
## when the band is hollow.
static func _band(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		indices: PackedInt32Array, col: Color,
		y0: float, y1: float, w: float, d: float, tw: float, hollow: bool,
		masks: PackedInt32Array = PackedInt32Array()) -> void:
	var h := y1 - y0
	var m_front := _mask_for(masks, SIDE_FRONT)
	var m_back := _mask_for(masks, SIDE_BACK)
	var m_left := _mask_for(masks, SIDE_LEFT)
	var m_right := _mask_for(masks, SIDE_RIGHT)

	# Outer faces. A run is a stretch of standing segments, merged, so an intact
	# side is one quad exactly as before and a damaged one is a handful.
	for r in _runs(m_front, w):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(r.x, y0, 0), Vector3(r.y, y0, 0), Vector3(r.x, y1, 0), Vector3(r.y, y1, 0),
				Vector3(0, 0, -1), Vector2(r.y - r.x, h), SEAM_UNIT)
	for r in _runs(m_back, w):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(r.y, y0, d), Vector3(r.x, y0, d), Vector3(r.y, y1, d), Vector3(r.x, y1, d),
				Vector3(0, 0, 1), Vector2(r.y - r.x, h), SEAM_UNIT)
	for r in _runs(m_left, d):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(0, y0, r.y), Vector3(0, y0, r.x), Vector3(0, y1, r.y), Vector3(0, y1, r.x),
				Vector3(-1, 0, 0), Vector2(r.y - r.x, h), SEAM_UNIT)
	for r in _runs(m_right, d):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(w, y0, r.x), Vector3(w, y0, r.y), Vector3(w, y1, r.x), Vector3(w, y1, r.y),
				Vector3(1, 0, 0), Vector2(r.y - r.x, h), SEAM_UNIT)
	if not hollow:
		return

	# Inner faces take the SAME mask as the outer face they back onto: a hole
	# blown in a wall goes through it, so the inside of that stretch is gone too.
	# Without this you could see an intact inner skin through the hole.
	for r in _runs(m_front, w):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(_hi(r.y, w, tw), y0, tw), Vector3(_lo(r.x, tw), y0, tw),
				Vector3(_hi(r.y, w, tw), y1, tw), Vector3(_lo(r.x, tw), y1, tw),
				Vector3(0, 0, 1), Vector2(r.y - r.x, h), SEAM_UNIT)
	for r in _runs(m_back, w):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(_lo(r.x, tw), y0, d - tw), Vector3(_hi(r.y, w, tw), y0, d - tw),
				Vector3(_lo(r.x, tw), y1, d - tw), Vector3(_hi(r.y, w, tw), y1, d - tw),
				Vector3(0, 0, -1), Vector2(r.y - r.x, h), SEAM_UNIT)
	for r in _runs(m_left, d):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(tw, y0, _lo(r.x, tw)), Vector3(tw, y0, _hi(r.y, d, tw)),
				Vector3(tw, y1, _lo(r.x, tw)), Vector3(tw, y1, _hi(r.y, d, tw)),
				Vector3(1, 0, 0), Vector2(r.y - r.x, h), SEAM_UNIT)
	for r in _runs(m_right, d):
		_quad(verts, normals, colours, uvs, uv2s, indices, col,
				Vector3(w - tw, y0, _hi(r.y, d, tw)), Vector3(w - tw, y0, _lo(r.x, tw)),
				Vector3(w - tw, y1, _hi(r.y, d, tw)), Vector3(w - tw, y1, _lo(r.x, tw)),
				Vector3(-1, 0, 0), Vector2(r.y - r.x, h), SEAM_UNIT)


## Every side of this band shot away. Distinct from "no mask", which is intact.
static func _band_is_gone(masks: PackedInt32Array) -> bool:
	return masks.size() == 4 and masks[0] == 0 and masks[1] == 0 			and masks[2] == 0 and masks[3] == 0


## Inner faces are inset by the wall thickness, but only where they meet a
## corner -- a run that starts mid-wall starts exactly where the outer one does.
static func _lo(v: float, tw: float) -> float:
	return maxf(v, tw)


static func _hi(v: float, span: float, tw: float) -> float:
	return minf(v, span - tw)


static func _mask_for(masks: PackedInt32Array, side: int) -> int:
	return masks[side] if masks.size() == 4 else ALL_STANDING


## Merge set bits into runs, in metres along a wall of length `span`.
##
## The whole-mask case short-circuits to one run, so an undamaged building never
## touches the bit loop and emits byte-identical geometry to before G1b.
static func _runs(mask: int, span: float) -> Array:
	if mask == ALL_STANDING:
		return [Vector2(0.0, span)]
	if mask == 0:
		return []
	var out := []
	var step := span / float(SEGMENTS)
	var i := 0
	while i < SEGMENTS:
		if (mask >> i) & 1 == 0:
			i += 1
			continue
		var j := i
		while j + 1 < SEGMENTS and ((mask >> (j + 1)) & 1) == 1:
			j += 1
		out.append(Vector2(i * step, (j + 1) * step))
		i = j + 1
	return out


## The far-far tier: one solid band and a cap. No course banding, no interior,
## no floor slabs.
##
## Measured reason: 1256 detailed shells inside 260 m came to 1.0 M triangles
## and ~179 MB. Past about a hundred metres a course is thinner than a pixel,
## so all that geometry buys nothing. This is 10 triangles instead of ~830.
static func build_coarse_arrays(footprint_x: int, footprint_z: int, courses: int) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()

	var w := footprint_x * STUD
	var d := footprint_z * STUD
	var h := TowerRecipe.total_plates(courses) * PLATE
	# The colour a viewer actually reads at this distance is the average of the
	# course banding, so take the middle of the rotation rather than the first.
	@warning_ignore("integer_division")
	var mid := TowerRecipe.COURSE_COLOURS.size() / 2
	var col := BrickWorld.get_filament_colour(TowerRecipe.COURSE_COLOURS[mid])
	_band(verts, normals, colours, uvs, uv2s, indices, col, 0.0, h, w, d, 0.0, false)
	_cap(verts, normals, colours, uvs, uv2s, indices,
			BrickWorld.get_filament_colour(TowerRecipe.SLAB_COLOUR), h, w, d, true)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


static func build_coarse_mesh(footprint_x: int, footprint_z: int, courses: int) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			build_coarse_arrays(footprint_x, footprint_z, courses))
	return mesh


static func build_mesh(footprint_x: int, footprint_z: int, courses: int,
		damage: Dictionary = {}) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := build_arrays(footprint_x, footprint_z, courses, damage)
	if (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return mesh  # every band shot away: a mesh with no surface, not a crash
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The windows of a shell, as panes of glass with a room painted behind them.
##
## A shell is solid bands -- it has no openings, so a fake room could only ever
## sit behind a wall. These are quads over the wall face exactly where the brick
## recipe cuts its windows (`TowerRecipe.window_gaps`, `is_window_course`), a
## few millimetres proud of it, drawn by shaders/window_interior.gdshader: the
## view ray is followed into a box of a room behind the glass, floor, ceiling,
## walls and a few pieces of furniture, all in the fragment shader. No geometry
## behind them and no rooms generated.
##
## Each pane carries, in its vertex colour, the KIND of the room really behind
## it (`RoomManifest.kind_at`) and a seed for how it is laid out and lit, so a
## storeroom's window shows crates and walking up to it finds crates.
##
## A band that has been damaged gets no panes: its wall has holes the shell
## draws as missing, and glass over a hole is glass in mid-air. Null if the
## building has no windows at all.
static func build_window_mesh(footprint_x: int, footprint_z: int, courses: int,
		building_seed: int, damage: Dictionary = {}) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()

	var w := footprint_x * STUD
	var d := footprint_z * STUD
	var gx: Array = TowerRecipe.window_gaps(footprint_x)
	var gz: Array = TowerRecipe.window_gaps(footprint_z)
	var storeys := RoomManifest.storeys_of(courses)
	var first := TowerRecipe.COURSES_PER_FLOOR - 1 - TowerRecipe.WINDOW_COURSES
	var tall := TowerRecipe.WINDOW_COURSES * TowerRecipe.PLATES_PER_COURSE * PLATE
	var reach := float(TowerRecipe.WALL_THICK) + 2.0  # studs in from the face
	var band_index := -1
	for band in TowerRecipe.layout(courses):
		band_index += 1
		if band.kind != "course":
			continue
		var index: int = band.index
		if index % TowerRecipe.COURSES_PER_FLOOR != first \
				or not TowerRecipe.is_window_course(index, courses):
			continue
		var damaged := false
		for k in TowerRecipe.WINDOW_COURSES:
			if damage.has(band_index + k):
				damaged = true
		if damaged:
			continue
		var storey := -1
		for si in storeys.size():
			var st: Dictionary = storeys[si]
			if int(band.y) >= int(st.floor_y) and int(band.y) < int(st.floor_y) + int(st.height):
				storey = si
				break
		var y0: float = int(band.y) * PLATE
		var y1 := y0 + tall
		# Front (-Z) and back (+Z) along X; left (-X) and right (+X) along Z.
		for g in gx:
			var a: float = (g as Vector2i).x * STUD
			var b: float = (g as Vector2i).y * STUD
			var mid := float((g as Vector2i).x + (g as Vector2i).y) * 0.5
			_pane(verts, normals, tangents, colours, uvs, uv2s, indices,
					Vector3(a, y0, -GLASS_PROUD), Vector3(b, y0, -GLASS_PROUD),
					Vector3(a, y1, -GLASS_PROUD), Vector3(b, y1, -GLASS_PROUD),
					Vector3(0, 0, -1), _pane_colour(footprint_x, footprint_z, courses,
					building_seed, storey, Vector2(mid, reach), 0, g))
			_pane(verts, normals, tangents, colours, uvs, uv2s, indices,
					Vector3(b, y0, d + GLASS_PROUD), Vector3(a, y0, d + GLASS_PROUD),
					Vector3(b, y1, d + GLASS_PROUD), Vector3(a, y1, d + GLASS_PROUD),
					Vector3(0, 0, 1), _pane_colour(footprint_x, footprint_z, courses,
					building_seed, storey, Vector2(mid, footprint_z - reach), 1, g))
		for g in gz:
			var a: float = (g as Vector2i).x * STUD
			var b: float = (g as Vector2i).y * STUD
			var mid := float((g as Vector2i).x + (g as Vector2i).y) * 0.5
			_pane(verts, normals, tangents, colours, uvs, uv2s, indices,
					Vector3(-GLASS_PROUD, y0, b), Vector3(-GLASS_PROUD, y0, a),
					Vector3(-GLASS_PROUD, y1, b), Vector3(-GLASS_PROUD, y1, a),
					Vector3(-1, 0, 0), _pane_colour(footprint_x, footprint_z, courses,
					building_seed, storey, Vector2(reach, mid), 2, g))
			_pane(verts, normals, tangents, colours, uvs, uv2s, indices,
					Vector3(w + GLASS_PROUD, y0, a), Vector3(w + GLASS_PROUD, y0, b),
					Vector3(w + GLASS_PROUD, y1, a), Vector3(w + GLASS_PROUD, y1, b),
					Vector3(1, 0, 0), _pane_colour(footprint_x, footprint_z, courses,
					building_seed, storey, Vector2(footprint_x - reach, mid), 3, g))
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The material the panes are drawn with, its room sized from the recipe: the
## glass sits WINDOW_COURSES tall with the storey's lower courses under it and
## the lintel course over it, and a pane's room is one window pitch wide.
static var _window_material: ShaderMaterial


static func window_material() -> ShaderMaterial:
	if _window_material != null:
		return _window_material
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/window_interior.gdshader")
	var course := TowerRecipe.PLATES_PER_COURSE * PLATE
	var below := TowerRecipe.COURSES_PER_FLOOR - 1 - TowerRecipe.WINDOW_COURSES
	m.set_shader_parameter("sill", below * course)
	m.set_shader_parameter("head", (TowerRecipe.COURSES_PER_FLOOR - below
			- TowerRecipe.WINDOW_COURSES) * course)
	m.set_shader_parameter("side",
			(TowerRecipe.WINDOW_PITCH - TowerRecipe.WINDOW_WIDE) * 0.5 * STUD)
	_window_material = m
	return m


## How far in front of the wall face a pane sits. Enough that it never fights
## the wall for depth at shell range, not enough to see a gap.
const GLASS_PROUD := 0.004


## What a pane knows about its room, packed in a vertex colour: r and b are
## seeds for layout, g is how brightly the room is lit, a is the room's kind as
## the room's window style (Room.WINDOW_STYLE), divided by four.
static func _pane_colour(footprint_x: int, footprint_z: int, courses: int,
		building_seed: int, storey: int, plan: Vector2, side: int, gap: Vector2i) -> Color:
	var kind := RoomManifest.kind_at(footprint_x, footprint_z, courses, building_seed,
			storey, plan)
	if kind < 0:
		kind = Room.KINDS.find("empty")
	kind = int(Room.WINDOW_STYLE.get(Room.KINDS[kind], 3))
	var h := RoomManifest.hash3(building_seed, storey * 4 + side, gap.x)
	var h2 := RoomManifest.hash3(h, 17, 31)
	# One room in five has its lights off.
	var lit := 0.3 if h2 % 5 == 0 else 0.8 + float((h2 >> 8) % 100) / 400.0
	return Color(float(h % 1000) / 1000.0, lit, float(h2 % 1000) / 1000.0,
			float(kind) / 4.0)


## One pane: corners a, b, c, d as `_quad` takes them, UV in metres across the
## glass, UV2 its size, and a tangent along U so the shader knows which way the
## glass runs.
static func _pane(verts: PackedVector3Array, normals: PackedVector3Array,
		tangents: PackedFloat32Array, colours: PackedColorArray,
		uvs: PackedVector2Array, uv2s: PackedVector2Array, indices: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, dd: Vector3, n: Vector3, col: Color) -> void:
	var size := Vector2(a.distance_to(b), a.distance_to(c))
	var t := (b - a).normalized()
	var v0 := verts.size()
	for p in [a, b, c, dd]:
		verts.push_back(p)
		normals.push_back(n)
		tangents.append_array([t.x, t.y, t.z, 1.0])
		colours.push_back(col)
		uv2s.push_back(size)
	uvs.push_back(Vector2(0, 0))
	uvs.push_back(Vector2(size.x, 0))
	uvs.push_back(Vector2(0, size.y))
	uvs.push_back(Vector2(size.x, size.y))
	for i in [0, 1, 2, 1, 3, 2]:
		indices.push_back(v0 + i)


## Four wall slabs and a floor. Enough for a projectile to hit the building and
## for debris to land on it; the real per-block collision arrives with the
## bricks, on damage.
static func collision_boxes(footprint_x: int, footprint_z: int, courses: int) -> Array:
	var t := TowerRecipe.WALL_THICK
	var w := footprint_x * STUD
	var d := footprint_z * STUD
	var tw := t * STUD
	var h := TowerRecipe.total_plates(courses) * PLATE
	var y := h * 0.5
	return [
		{"pos": Vector3(w * 0.5, y, tw * 0.5), "size": Vector3(w, h, tw)},
		{"pos": Vector3(w * 0.5, y, d - tw * 0.5), "size": Vector3(w, h, tw)},
		{"pos": Vector3(tw * 0.5, y, d * 0.5), "size": Vector3(tw, h, d - tw * 2.0)},
		{"pos": Vector3(w - tw * 0.5, y, d * 0.5), "size": Vector3(tw, h, d - tw * 2.0)},
		{"pos": Vector3(w * 0.5, PLATE * 0.5, d * 0.5), "size": Vector3(w, PLATE, d)},
	]


## `unit` is the rectangle the seam shader tiles: pass a brick-sized one and the
## face gets a grid of brick outlines rather than a single outline around the
## whole thing. Zero means "the face is one brick", which is what the real brick
## mesher writes.
static func _quad(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		indices: PackedInt32Array, col: Color,
		a: Vector3, b: Vector3, c: Vector3, dd: Vector3, n: Vector3, size: Vector2,
		unit: Vector2 = Vector2.ZERO) -> void:
	var seam := size if unit == Vector2.ZERO else Vector2(
			minf(unit.x, size.x), minf(unit.y, size.y))
	var v0 := verts.size()
	for p in [a, b, c, dd]:
		verts.push_back(p)
		normals.push_back(n)
		colours.push_back(col)
		uv2s.push_back(seam)
	# Corners run a, b, c, d with triangles (a,b,c) and (b,d,c), matching the
	# brick mesher, so the seam shader reads a course as one band.
	uvs.push_back(Vector2(0, 0))
	uvs.push_back(Vector2(size.x, 0))
	uvs.push_back(Vector2(0, size.y))
	uvs.push_back(Vector2(size.x, size.y))
	for i in [0, 1, 2, 1, 3, 2]:
		indices.push_back(v0 + i)
