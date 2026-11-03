class_name PhysicsView
extends MeshInstance3D

## What the physics sees (Docs/Hulls.md 11, E1; after Brickadia's debug views,
## Docs/Reference/brick-games.md 2.2). Shift+G in the city.
##
##   a standing building's collision, band by band, as wire boxes:
##     cyan     a band as it is
##     orange   stale: lost bricks, merged again at the end of the tick
##     red      parked: out of the space until flush() has budget for it
##   a loose piece's shapes, and a cross at its centre of mass:
##     blue     asleep
##     yellow   awake
##     red      awake for more than NEVER_SLEEPS_MS -- a body that will not settle
##
## Drawing only: nothing here changes a body, a shape or a cap. Redrawn every
## REDRAW_MS while shown; nothing runs while hidden.

const REDRAW_MS := 250
## Awake this long and still not asleep: drawn red, and counted.
const NEVER_SLEEPS_MS := 10000
## More boxes than this are not drawn (the count says how many were left out).
const MAX_BOXES := 30000

const COL_BAND := Color(0.3, 0.85, 0.95)
const COL_STALE := Color(1.0, 0.6, 0.15)
const COL_PARKED := Color(1.0, 0.2, 0.2)
const COL_ASLEEP := Color(0.35, 0.55, 1.0)
const COL_AWAKE := Color(1.0, 0.9, 0.2)
const COL_RESTLESS := Color(1.0, 0.15, 0.15)

## From the last redraw.
var bands := 0
var band_boxes := 0
var stale_bands := 0
var parked_bands := 0
var pieces := 0
var piece_boxes := 0
var awake := 0
var restless := 0
var left_out := 0

## Body instance id -> when it was first seen awake (ms), cleared when it sleeps.
var _awake_since := {}
var _last_ms := -1000000
var _boxes := 0


func _init() -> void:
	mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## Redraw if shown and REDRAW_MS has passed. `cols` is CityScene._brick_cols
## (building id -> BuildingCollision); `islands` the IslandManager.
func tick(cols: Dictionary, islands: IslandManager) -> void:
	if not visible:
		return
	var now := Time.get_ticks_msec()
	if now - _last_ms < REDRAW_MS:
		return
	_last_ms = now
	redraw(cols, islands)


func redraw(cols: Dictionary, islands: IslandManager) -> void:
	bands = 0
	band_boxes = 0
	stale_bands = 0
	parked_bands = 0
	pieces = 0
	piece_boxes = 0
	awake = 0
	restless = 0
	left_out = 0
	_boxes = 0
	var im: ImmediateMesh = mesh
	im.clear_surfaces()
	# ImmediateMesh errors on an empty surface: open it on the first line.
	var open := false
	var now := Time.get_ticks_msec()

	for id in cols:
		var bc: BuildingCollision = cols[id]
		if bc == null:
			continue
		for i in bc.bodies.size():
			var body: RID = bc.bodies[i]
			bands += 1
			var col := COL_BAND
			if i < bc.parked.size() and bc.parked[i]:
				col = COL_PARKED
				parked_bands += 1
			elif i < bc.stale.size() and bc.stale[i]:
				col = COL_STALE
				stale_bands += 1
			if not open:
				im.surface_begin(Mesh.PRIMITIVE_LINES)
				open = true
			band_boxes += _body_boxes(im, body, col)

	var seen := {}
	for isl in islands.islands:
		if not isl.is_valid() or isl.body == null or not is_instance_valid(isl.body):
			continue
		pieces += 1
		var body := isl.body
		var key := body.get_instance_id()
		seen[key] = true
		var col := COL_ASLEEP
		if not body.sleeping and not body.freeze:
			awake += 1
			var since: int = _awake_since.get(key, now)
			_awake_since[key] = since
			if now - since > NEVER_SLEEPS_MS:
				col = COL_RESTLESS
				restless += 1
			else:
				col = COL_AWAKE
		else:
			_awake_since.erase(key)
		if not open:
			im.surface_begin(Mesh.PRIMITIVE_LINES)
			open = true
		piece_boxes += _body_boxes(im, body.get_rid(), col)
		var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
		var com: Vector3 = state.center_of_mass if state != null \
				else body.global_transform * isl.local_com
		_cross(im, com, 0.4, col)
	for key in _awake_since.keys():
		if not seen.has(key):
			_awake_since.erase(key)
	if open:
		im.surface_end()


## One line for the stats (F1).
func hud_line() -> String:
	if not visible:
		return "physics view  off (shift+G)"
	return "physics view  %d bands (%d boxes, %d stale, %d parked) · %d pieces (%d boxes) · %d awake, %d never sleep%s" % [
		bands, band_boxes, stale_bands, parked_bands, pieces, piece_boxes, awake, restless,
		(" · %d boxes not drawn" % left_out) if left_out > 0 else ""]


## Every box shape of `body` as a wire box; the count drawn.
## A switched-off box (an unmerged band's dead brick) is drawn too: the server
## has no way to ask. Merged bands -- every standing building -- have none.
func _body_boxes(im: ImmediateMesh, body: RID, col: Color) -> int:
	var n := PhysicsServer3D.body_get_shape_count(body)
	var xf := PhysicsServer3D.body_get_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM) as Transform3D
	var drawn := 0
	for s in n:
		var shape := PhysicsServer3D.body_get_shape(body, s)
		if PhysicsServer3D.shape_get_type(shape) != PhysicsServer3D.SHAPE_BOX:
			continue
		if _boxes >= MAX_BOXES:
			left_out += 1
			continue
		var half: Vector3 = PhysicsServer3D.shape_get_data(shape)
		var sx := xf * PhysicsServer3D.body_get_shape_transform(body, s)
		_wire_box(im, sx, half, col)
		_boxes += 1
		drawn += 1
	return drawn


func _wire_box(im: ImmediateMesh, xf: Transform3D, h: Vector3, col: Color) -> void:
	var c := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	const EDGES := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	for i in EDGES:
		im.surface_set_color(col)
		im.surface_add_vertex(xf * (c[i] as Vector3))


func _cross(im: ImmediateMesh, p: Vector3, r: float, col: Color) -> void:
	for a in [Vector3(r, 0, 0), Vector3(0, r, 0), Vector3(0, 0, r)]:
		im.surface_set_color(col)
		im.surface_add_vertex(p - a)
		im.surface_set_color(col)
		im.surface_add_vertex(p + a)
