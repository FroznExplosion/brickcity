class_name CityPlacer
extends Node3D

## Placing a finished build in the city, the way the workshop places a brick.
##
## A build is one more building, so what it snaps to is the city's grid -- the
## same stud (0.35 m) and plate (0.14 m) from the world origin that the terrain,
## the workshop and every other building stand on (BuildingRegistry.on_grid).
## The rules are the workshop's (workshop.gd `_aim`), one level up:
##
##   AIM (default).  The stud under the dot is the target: on the ground, or on
##       top of whatever building the ray hits first (its side counts as its
##       top, as a plain brick's does). The ghost is centred on that stud, and
##       when that spot is blocked by another building it is shifted along,
##       still covering the stud, until it fits -- red only when nothing does.
##   LOCK (hold E).  The height the ghost is at is frozen and the ghost follows
##       the dot across that plane, red wherever it does not fit.
##   R turns it a quarter. LMB places it, and it stays in hand for another.
##   The wheel steps through the library -- every saved build (`library`).
##   P or RMB puts it down without placing.
##
## The ghost is the build itself -- every frame's real mesh and studs, drawn
## through one translucent material -- so what is seen is what lands.
##
## Knows nothing of the city scene: it is handed the registry, the camera and a
## callback, and `aim_ray` is public so a probe can drive it with exact rays.

## Called with the new building's id once it is registered, so the scene can
## index and shell it like any other building.
var on_placed := Callable()

## Where prebuilt structures live. `res://builds/` ships with the game
## (tools/make_prebuilts.gd writes it); `user://builds/` is the player's.
const LIBRARY_DIRS := ["res://builds/", "user://builds/"]

var _registry: BuildingRegistry
var _camera: Camera3D
var _recipe: BuildRecipe
var _name := ""

var _ghost: Node3D
var _material: StandardMaterial3D
var _hud: Label

var _dims := Vector3i.ZERO   ## the build's box in cells, min corner at its origin
var _turn := 0               ## quarter turns about +Y
var _cell := Vector3i.ZERO   ## where the turned box's min corner goes
var _valid := false
var _lock := {}              ## {"y": plates} while E is held
var _target := Vector3i.ZERO ## the stud aimed at
var _paths := PackedStringArray()   ## the library, as the wheel steps through it
var _index := 0

## Pre-turn box sizes, so a quarter turn swaps x and z.
func _turned_dims() -> Vector3i:
	return Vector3i(_dims.z, _dims.y, _dims.x) if _turn % 2 == 1 else _dims


func is_active() -> bool:
	return _recipe != null


func setup(registry: BuildingRegistry, camera: Camera3D) -> void:
	_registry = registry
	_camera = camera
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hud.position = Vector2(-260, -70)
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_hud.add_theme_constant_override("outline_size", 4)
	_hud.visible = false
	layer.add_child(_hud)


## Every build that can be placed: `first` (the workshop's last save) if it
## exists, then each library folder's .json files in name order.
static func library(first: String = "") -> PackedStringArray:
	var out := PackedStringArray()
	if first != "" and FileAccess.file_exists(first):
		out.append(first)
	for dir in LIBRARY_DIRS:
		if not DirAccess.dir_exists_absolute(dir):
			continue   # a player who has saved nothing has no folder yet
		var files := DirAccess.get_files_at(dir)
		files.sort()
		for f in files:
			var path: String = dir + f
			if f.ends_with(".json") and not out.has(path):
				out.append(path)
	return out


## Pick up a build, or put the one in hand down. The wheel then steps through
## the rest of the library from wherever `path` is in it.
func toggle(path: String) -> bool:
	if is_active():
		stop()
		return false
	_paths = library(path)
	if _paths.is_empty():
		push_warning("[place] nothing to place: save a build in the workshop with F5")
		return false
	_index = maxi(_paths.find(path), 0)
	return start(_paths[_index])


## Next (or previous) build in the library, keeping the turn.
func cycle(step: int) -> void:
	if _paths.size() < 2:
		return
	var keep := _turn
	_index = posmod(_index + step, _paths.size())
	if start(_paths[_index]):
		_turn = keep


func start(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("[place] no build at %s -- save one in the workshop with F5" % path)
		return false
	var r := BuildRecipe.load_from(path)
	if r.is_empty():
		push_warning("[place] %s holds no bricks" % path)
		return false
	var label := r.name if r.name != "" and r.name != "untitled" else path.get_file().get_basename()
	return hold(r, label)


## Take a recipe in hand. Split from `start` so a probe can hand one over.
func hold(r: BuildRecipe, label: String = "build") -> bool:
	_recipe = r
	_name = label
	_dims = r.chunk_dims()
	_turn = 0
	_lock = {}
	_make_ghost()
	_hud.visible = true
	if _camera != null and "e_climbs" in _camera:
		_camera.set("e_climbs", false)   # E is the height lock while placing
	return true


func stop() -> void:
	_recipe = null
	_lock = {}
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	_hud.visible = false
	if _camera != null and "e_climbs" in _camera:
		_camera.set("e_climbs", true)


# ---------------------------------------------------------------------------
# The ghost
# ---------------------------------------------------------------------------

## Every frame of the build, meshed in a scratch world of its own, laid out the
## way the registry will lay the real one out: its min corner at the origin.
func _make_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
	_ghost = Node3D.new()
	add_child(_ghost)
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var asm := Assembly.new(w, pal)
	_recipe.build_into(asm, pal)
	var cell := BrickWorld.get_cell_size()
	var lo: Vector3i = _recipe.origin()
	var shift := Transform3D(Basis(), -Vector3(lo.x * cell.x, lo.y * cell.y, lo.z * cell.z))
	for f in asm.frames:
		var arrays := w.build_chunk_mesh(f)
		if arrays.size() == 0 or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.material_override = _material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.transform = shift * w.get_chunk_transform(f)
		_ghost.add_child(mi)
		var studs: PackedFloat32Array = w.get_chunk_studs(f)
		@warning_ignore("integer_division")
		var n := studs.size() / 16
		if n > 0:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = PieceMeshes.stud()
			mm.instance_count = n
			mm.set_buffer(studs)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = _material
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.add_child(mmi)


## Where the build goes: a quarter-turned basis and an origin that puts the
## TURNED box's min corner on `_cell`. Both on the grid by construction.
func placement() -> Transform3D:
	var turned := Basis(Vector3.UP, _turn * PI * 0.5)
	var cell := BrickWorld.get_cell_size()
	var size := Vector3(_dims.x * cell.x, 0.0, _dims.z * cell.z)
	var lo := Vector3(INF, 0.0, INF)
	for c in [Vector3.ZERO, Vector3(size.x, 0, 0), Vector3(0, 0, size.z), size]:
		var p: Vector3 = turned * c
		lo = Vector3(minf(lo.x, p.x), 0.0, minf(lo.z, p.z))
	var at := BrickWorld.grid_to_world(_cell)
	return BuildingRegistry.on_grid(Transform3D(turned, at - lo))


# ---------------------------------------------------------------------------
# Aiming: workshop.gd `_aim`, one level up
# ---------------------------------------------------------------------------

func _process(_dt: float) -> void:
	if not is_active() or _camera == null:
		return
	_hold_lock(Input.is_key_pressed(KEY_E))
	var vp := get_viewport()
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	if vp != null and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var m := vp.get_mouse_position()
		from = _camera.project_ray_origin(m)
		dir = _camera.project_ray_normal(m)
	aim_ray(from, dir)


func _hold_lock(on: bool) -> void:
	if not on:
		_lock = {}
	elif _lock.is_empty():
		_lock = {"y": _cell.y}


## The placement rule for one ray. Public for the probe.
func aim_ray(from: Vector3, dir: Vector3) -> void:
	var cell := BrickWorld.get_cell_size()
	var d := _turned_dims()
	@warning_ignore("integer_division")
	var half := Vector3i((d.x - 1) / 2, 0, (d.z - 1) / 2)
	if not _lock.is_empty():
		# Slide on the locked plane; no fitting, red where it does not fit.
		var y: float = int(_lock.y) * cell.y
		if absf(dir.y) < 1e-4:
			return
		var t := (y - from.y) / dir.y
		if t <= 0.0:
			return
		var p := from + dir * t
		_target = Vector3i(int(floor(p.x / cell.x)), int(_lock.y), int(floor(p.z / cell.z)))
		_cell = Vector3i(_target.x - half.x, _target.y, _target.z - half.z)
		_update()
		return
	var hit := _first_surface(from, dir)
	if hit.is_empty():
		return
	_target = hit.cell
	_cell = _fit_over(_target, d, half)
	_update()


## The first surface along the ray: the top of a building (a side counts as the
## top, as a plain brick's does in the workshop) or the ground. Returns the stud
## cell on it, {} when the ray finds neither.
func _first_surface(from: Vector3, dir: Vector3) -> Dictionary:
	var cell := BrickWorld.get_cell_size()
	var best_t := INF
	var best := {}
	for b in _registry.buildings:
		var box := box_of(b)
		var t := _ray_box(from, dir, box)
		if t < best_t:
			var p := from + dir * t
			# Nudge into the box so the column is one of the building's own.
			var q := p + dir * 0.01
			q.x = clampf(q.x, box.position.x + 0.001, box.end.x - 0.001)
			q.z = clampf(q.z, box.position.z + 0.001, box.end.z - 0.001)
			best_t = t
			best = {"cell": Vector3i(int(floor(q.x / cell.x)),
					int(round(box.end.y / cell.y)), int(floor(q.z / cell.z)))}
	if absf(dir.y) > 1e-4:
		var tg := -from.y / dir.y
		if tg > 0.0 and tg < best_t:
			var g := from + dir * tg
			best = {"cell": Vector3i(int(floor(g.x / cell.x)), 0, int(floor(g.z / cell.z)))}
	return best


## Slab test, world AABB. INF when the ray misses or the box is behind it.
static func _ray_box(from: Vector3, dir: Vector3, box: AABB) -> float:
	var t0 := -INF
	var t1 := INF
	for a in 3:
		if absf(dir[a]) < 1e-9:
			if from[a] < box.position[a] or from[a] > box.end[a]:
				return INF
			continue
		var ta := (box.position[a] - from[a]) / dir[a]
		var tb := (box.end[a] - from[a]) / dir[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t1 < maxf(t0, 0.0):
		return INF
	return t0 if t0 > 0.0 else INF


## Centred on the stud when that fits; otherwise the nearest shift that still
## covers it. Centred and red when nothing does -- the workshop's `_fit_over`.
func _fit_over(stud: Vector3i, d: Vector3i, half: Vector3i) -> Vector3i:
	var centred := Vector3i(stud.x - half.x, stud.y, stud.z - half.z)
	var best := centred
	var best_d := -1
	for dx in d.x:
		for dz in d.z:
			var c := Vector3i(stud.x - dx, stud.y, stud.z - dz)
			var dist := absi(c.x - centred.x) + absi(c.z - centred.z)
			if best_d >= 0 and dist >= best_d:
				continue
			if fits(c):
				best = c
				best_d = dist
	return best


## A building's box in the world. Every building stands on the grid at a
## quarter turn (BuildingRegistry.on_grid), so its turned box is exactly an AABB.
static func box_of(b) -> AABB:
	var cell := BrickWorld.get_cell_size()
	var size: Vector3
	if b.is_build():
		var d: Vector3i = b.build.chunk_dims()
		size = Vector3(d.x * cell.x, d.y * cell.y, d.z * cell.z)
	else:
		size = Vector3(int(b.recipe.footprint_x) * cell.x,
				TowerRecipe.total_plates(int(b.recipe.courses)) * cell.y,
				int(b.recipe.footprint_z) * cell.z)
	return b.xform * AABB(Vector3.ZERO, size)


## Does the build, turned as it is, fit with its min corner at `c`? It must not
## go below the ground or into any building; touching is fine.
func fits(c: Vector3i) -> bool:
	if c.y < 0:
		return false
	var cell := BrickWorld.get_cell_size()
	var d := _turned_dims()
	var mine := AABB(BrickWorld.grid_to_world(c),
			Vector3(d.x * cell.x, d.y * cell.y, d.z * cell.z)).grow(-0.01)
	for b in _registry.buildings:
		if mine.intersects(box_of(b)):
			return false
	return true


func _update() -> void:
	_valid = fits(_cell)
	if _ghost != null:
		_ghost.transform = placement()
	_material.albedo_color = Color(0.35, 0.9, 1.0, 0.4) if _valid else Color(1.0, 0.25, 0.22, 0.45)
	var which := (" (%d of %d)" % [_index + 1, _paths.size()]) if _paths.size() > 1 else ""
	_hud.text = "PLACING %s%s   %s%s\nLMB place   wheel next build   R turn   hold E lock height   P / RMB put down" % [
			_name, which, "fits" if _valid else "BLOCKED", "   [height locked]" if not _lock.is_empty() else ""]


## Register it where the ghost is. Returns the new building id, or -1.
func place() -> int:
	if not is_active() or not _valid:
		return -1
	var id := _registry.register_build(_recipe, placement())
	if id >= 0 and on_placed.is_valid():
		on_placed.call(id)
	return id


func turn() -> void:
	_turn = (_turn + 1) % 4


func _unhandled_input(e: InputEvent) -> void:
	if not is_active():
		return
	if e is InputEventMouseButton and e.pressed:
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				place()
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_RIGHT:
				stop()
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_UP:
				cycle(1)
				get_viewport().set_input_as_handled()
			MOUSE_BUTTON_WHEEL_DOWN:
				cycle(-1)
				get_viewport().set_input_as_handled()
	elif e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_R:
		turn()
		get_viewport().set_input_as_handled()
