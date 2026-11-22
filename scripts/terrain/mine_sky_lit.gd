class_name MineSkyLit
extends Node
## Sky light on things in the mine world (Docs/MineWorld.md 19): collapse
## pieces, dropped items and chests take the sky light of the cell they are
## in, so in a dark cave they are as dark as the walls round them, not lit by
## the open-air environment.
##
## Each is drawn with a mine-world copy of its material that reads an
## `instance uniform float sky_level` (sky_lit.gdshaderinc): brick.gdshader
## with `#define SKY_LIT` for the pieces, sky_lit_item.gdshader for ItemIcons'
## StandardMaterial3Ds. The shared materials are not touched: other scenes,
## and the mine world's near trees, draw as before.
##
## The level is BrickTerrain.sky_light_at (~0.15 ms in a dark cave), asked
## only when a thing is tracked, moves a light cell, or the ground within
## light's reach of it is edited (`dirty_box`, from terrain_edited); at most
## ASK_BUDGET_US of asking a frame. Painted with set_instance_shader_parameter
## on its meshes: nothing read back from the renderer.
##
## Made by the mine world only when sky light is on (no `--no-sky-light`).

## Things scanned for a new cell each frame (round robin).
const SCAN_PER_FRAME := 24
## Asking stops for the frame past this (one is always asked).
const ASK_BUDGET_US := 250
## Light reaches 15 cells: an edit can change the level this far off (studs
## across, courses up and down).
const REACH := 16

## The mine world (untyped: it holds this).
var world: Node3D = null
## Root's instance id -> entry {root, id, cell, level, queued}.
var _entries := {}
var _order: Array = []
var _scan := 0
## Entries to ask again, oldest first; `queued` marks them.
var _queue: Array = []
## The gate's A/B: a level >= 0 painted on everything instead of its own.
var force_level := -1.0
## Counters, for the readout and the gate.
var asked := 0
var painted := 0
var worst_ask_us := 0

static var _brick_shader: Shader = null
static var _item_shaders := [null, null]
var _item_mats := {}
var _brick_mats := {}


func setup(w: Node3D) -> void:
	world = w


## `brick.gdshader` with `#define SKY_LIT` in front, made once.
static func brick_shader() -> Shader:
	if _brick_shader == null:
		_brick_shader = _with_define(load("res://shaders/brick.gdshader") as Shader, "SKY_LIT")
	return _brick_shader


static func item_shader(alpha: bool) -> Shader:
	var i := 1 if alpha else 0
	if _item_shaders[i] == null:
		var s: Shader = load("res://shaders/sky_lit_item.gdshader")
		_item_shaders[i] = _with_define(s, "ITEM_ALPHA") if alpha else s
	return _item_shaders[i]


static func _with_define(src: Shader, name: String) -> Shader:
	var code := src.code
	var at := code.find("\n") + 1
	var s := Shader.new()
	s.code = code.insert(at, "#define %s\n" % name)
	return s


## A copy of `src` (a brick.gdshader material) drawn with sky light: the same
## parameters, the SKY_LIT shader, registered for the weather as the
## original is. One copy per original.
func brick_material(src: ShaderMaterial) -> ShaderMaterial:
	var id := src.get_instance_id()
	if not _brick_mats.has(id):
		var m := src.duplicate() as ShaderMaterial
		m.shader = brick_shader()
		WeatherFx.register(m)
		_brick_mats[id] = m
	return _brick_mats[id]


## A StandardMaterial3D's look (colour, roughness, alpha, glow) drawn with
## sky light, shared by every model with the same look.
func item_material(std: StandardMaterial3D) -> ShaderMaterial:
	var alpha := std.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
	var glow := std.emission_enabled
	var key := "%s|%.3f|%s|%s|%.3f" % [std.albedo_color.to_html(), std.roughness, alpha,
			std.emission.to_html() if glow else "", std.emission_energy_multiplier if glow else 0.0]
	if not _item_mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = item_shader(alpha)
		m.set_shader_parameter("albedo", std.albedo_color)
		m.set_shader_parameter("roughness", std.roughness)
		if glow:
			m.set_shader_parameter("emission", std.emission)
			m.set_shader_parameter("emission_energy", std.emission_energy_multiplier)
		_item_mats[key] = m
	return _item_mats[key]


## Every StandardMaterial3D override under `root` swapped for its sky-lit
## copy (ItemIcons' models).
func sky_lit_model(root: Node) -> void:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.material_override is StandardMaterial3D:
			mi.material_override = item_material(mi.material_override as StandardMaterial3D)


## `root` (a Node3D whose meshes are drawn with sky-lit copies) takes the
## light where it is. Again for a root already tracked: its meshes are
## painted with the level it has (a piece's mesh made again), and it is asked
## again.
func track(root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		return
	var e: Dictionary = _entries.get(root.get_instance_id(), {})
	if e.is_empty():
		e = {"root": root, "id": root.get_instance_id(), "cell": _cell_of(root), "level": -1.0,
				"queued": false}
		_entries[e.id] = e
		_order.append(e)
		# New: asked now if the frame has room, else drawn at the eye's level
		# till it is (things appear near the player).
		if not _ask(e, true):
			_paint(e, float(world.get("_eye_sky")) if world != null else 15.0)
	else:
		_paint(e, e.level, true)
	_enqueue(e)


func untrack(root: Node3D) -> void:
	var e: Dictionary = _entries.get(root.get_instance_id(), {})
	if not e.is_empty():
		_entries.erase(e.id)
		_order.erase(e)


## The ground changed between plate cells `lo` and `hi` (terrain_edited's
## box_lo / box_hi): what is within light's reach is asked again.
func dirty_box(lo: Vector3i, hi: Vector3i) -> void:
	if _order.is_empty():
		return
	var course := 3
	var clo := Vector3i(lo.x - REACH, floori(float(lo.y) / course) - REACH, lo.z - REACH)
	var chi := Vector3i(hi.x + REACH, floori(float(hi.y) / course) + REACH, hi.z + REACH)
	for e: Dictionary in _order:
		var c: Vector3i = e.cell
		if c.x >= clo.x and c.x <= chi.x and c.y >= clo.y and c.y <= chi.y \
				and c.z >= clo.z and c.z <= chi.z:
			_enqueue(e)


## Its level as last painted (-1 untracked): for the gate and the probe.
func level_of(root: Node3D) -> float:
	var e: Dictionary = _entries.get(root.get_instance_id(), {})
	return -1.0 if e.is_empty() else float(e.level)


func count() -> int:
	return _order.size()


## The gate's A/B: everything painted `level` (>= 0), or its own again (-1).
func set_force(level: float) -> void:
	force_level = level
	for e: Dictionary in _order:
		if is_instance_valid(e.root):
			_paint(e, e.level, true)


## Everything asked again now (the gate, after building round them).
func ask_all() -> void:
	for e: Dictionary in _order:
		if is_instance_valid(e.root):
			e.cell = _cell_of(e.root)
			_ask(e, false)


func _process(_delta: float) -> void:
	if _order.is_empty():
		return
	# Scan a few for a new cell (a falling piece or item); the gone dropped.
	var n := mini(SCAN_PER_FRAME, _order.size())
	var k := 0
	while k < n and not _order.is_empty():
		_scan = _scan % _order.size()
		var e: Dictionary = _order[_scan]
		if not is_instance_valid(e.root):
			_entries.erase(e.id)
			_order.remove_at(_scan)
		else:
			var c := _cell_of(e.root)
			if c != e.cell:
				e.cell = c
				_enqueue(e)
			_scan += 1
		k += 1
	var t0 := Time.get_ticks_usec()
	while not _queue.is_empty():
		var e: Dictionary = _queue.pop_front()
		e.queued = false
		if not is_instance_valid(e.root):
			continue
		_ask(e, false)
		if Time.get_ticks_usec() - t0 > ASK_BUDGET_US:
			break


func _enqueue(e: Dictionary) -> void:
	if not e.queued:
		e.queued = true
		_queue.append(e)


## Asks its level and paints it if it changed. With `only_if_room`, not past
## the frame's budget: false then, nothing asked.
var _frame := -1
var _frame_us := 0


func _ask(e: Dictionary, only_if_room: bool) -> bool:
	var f := Engine.get_process_frames()
	if f != _frame:
		_frame = f
		_frame_us = 0
	if only_if_room and _frame_us > ASK_BUDGET_US:
		return false
	var t0 := Time.get_ticks_usec()
	var level := BrickTerrain.sky_light_at(_point_of(e.root))
	var us := Time.get_ticks_usec() - t0
	_frame_us += us
	worst_ask_us = maxi(worst_ask_us, us)
	asked += 1
	if level != float(e.level):
		_paint(e, level)
	return true


func _paint(e: Dictionary, level: float, always := false) -> void:
	if level < 0.0:
		level = 15.0
	if not always and level == float(e.level):
		return
	e.level = level
	var shown := force_level if force_level >= 0.0 else level
	var root: Node3D = e.root
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).set_instance_shader_parameter(&"sky_level", shown)
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		(n as GeometryInstance3D).set_instance_shader_parameter(&"sky_level", shown)
	painted += 1


## Terrain-local: the mine world's frame (its origin shift moves it).
func _point_of(root: Node3D) -> Vector3:
	return world.to_local(root.global_position) if world != null else root.global_position


func _cell_of(root: Node3D) -> Vector3i:
	var p := _point_of(root)
	return Vector3i(floori(p.x / BrickWorld.get_stud_metres()),
			floori(p.y / BrickTerrain.get_brick_metres()), floori(p.z / BrickWorld.get_stud_metres()))


func readout() -> String:
	return "sky-lit things %d, asked %d (worst %.2f ms), painted %d" % [_order.size(), asked,
			worst_ask_us / 1000.0, painted]
