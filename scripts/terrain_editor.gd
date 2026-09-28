extends Node3D

## Terrain LEVEL EDITOR. [Docs/Terrain.md](../Docs/Terrain.md) §20.
##
##     godot --path . scenes/heightfield_test.tscn
##     godot --path . scenes/heightfield_test.tscn -- --editshot
##
## The TOOLS, not a scene. heightfield_scene.gd adds this node on top of its
## own terrain, far tier, water and sites (§20.9), so what is edited is exactly
## what is looked at and there is one terrain scene rather than two that
## drifted apart. `scenes/terrain_editor.tscn` is that same scene.
##
## Editing terrain is an authoring job, not a gameplay one. Nothing here is
## reachable from the game: the game loads a world file and never writes one.
##
## What it edits is the FIELD, through pads (§19.12) — not a mesh, not a
## heightmap. That is the whole reason this is short: a pad goes into the
## generator, and the detailed tier, the coarse tier, the collider, the stud
## test, the seabed texture and the buoyancy solver all agree about it
## without being told. An editor that pushed vertices around would have to
## tell every one of them, forever.
##
## Placed edits, because a level has three kinds of thing placed in it:
##
##   1 PAD     flatten ground to a height — where a building stands
##   2 PAINT   say what the ground is made of, whatever the noise thinks
##   3 SITE    a building: a pad, plus how many storeys stand on it
##
## And BRUSHES, held and dragged across the ground the way a smooth-terrain
## editor sculpts (§20.6). Hold the left button and look across the ground:
##
##   4 RAISE   5 LOWER   6 FLATTEN (to the height where the stroke began)
##   7 SMOOTH
##   8 PAINT BRUSH  what the ground is made of AND its colour, a stud at a
##                  time (§20.7). The palette picks both; I picks them up
##                  from the ground under the cursor.
##
## A brush goes into the field UNDER the pads, so a building's pad stays
## flat whatever is painted round it, and the ground meets its floor.
##
## Keys:
##   0            LOOK: no tool, so a click only takes the mouse
##   1 .. 8       pick the tool
##   LEFT CLICK   place under the cursor, or select what is already there
##                (brushes: hold and drag)
##   CTRL+Z       undo the last brush stroke
##   G            grab the selection; it follows the cursor, click to drop
##   DELETE       remove the selection
##   [ / ]        radius (brushes too)    , / .   skirt
##   - / =        height (pad, site floor), material (paint), strength (brush)
##   PAGE UP/DN   storeys, on a site
##   CTRL+S       save the world       CTRL+O   reload it
##   SPACE SPACE  walk/fly

const World := preload("res://scripts/terrain_world.gd")
## `-- --world=<name>` opens a different level.
var _world_path := "res://worlds/heightfield.json"

enum Tool { LOOK, PAD, PAINT, SITE, RAISE, LOWER, FLATTEN, SMOOTH, PAINT_BRUSH }
const TOOL_NAMES := ["LOOK", "PAD", "PAINT", "SITE", "RAISE", "LOWER", "FLATTEN", "SMOOTH",
		"PAINT BRUSH"]
const PaintPalette := preload("res://scripts/paint_palette.gd")
## What the paint brush lays: a terrain material (or KEEP / NATURAL) and a
## filament colour (or KEEP / the material's OWN). BrickTerrain.paint_surface.
const KEEP := -1
const RESET := -2
## The terrain materials an author can paint with, ASKED FOR rather than
## written out: a hand-copied list is one rename away from painting stone
## and labelling it sand.
static var MATERIALS: PackedStringArray = BrickTerrain.material_names()
const WORLD_SEED := 20260921
## The seed actually in use: the world file's own when it names one, so a
## level cut from a different seed (the city's) is edited on ITS ground.
var _seed := WORLD_SEED
## The scene the tools stand in (heightfield_scene.gd): its camera, its
## streamer, its far tier and water to tell about an edit.
var _host = null
## What the last stroke touched, for the far tier and the seabed at its end.
var _stroke_rect := Rect2i()

var _streamer: TerrainStreamer = null
var _mat: ShaderMaterial = null
var _camera: DebugCamera = null
var _sun: DirectionalLight3D = null
var _label: Label = null
var _markers: Node3D = null

var _tool: Tool = Tool.LOOK
var _selected := -1
var _paint_material := 3        ## sand, a visible default
## Grab mode: the selection follows the cursor until the next click.
##
## A drag, in a scene where the mouse is captured for looking. There is no
## cursor to drag WITH, so "grab, aim, drop" is the shape the camera
## already has — the same gesture a modelling package uses for the same
## reason.
var _grabbing := false
var _drowned := 0.30

## THE BRUSH. Radius in studs; rate in metres a second for raise and lower,
## and the fraction of the way a second for flatten and smooth.
var _brush_radius := 10.0
var _brush_rate := 1.5
var _stroking := false
var _flatten_to := 0.0
## What the stroke has touched since the tiles were last told, in studs.
var _pending := Rect2i()
var _refresh_in := 0.0
## Ten refreshes a second: a dab is microseconds, a tile rebake is not.
const REFRESH_EVERY := 0.1
var _ring: MeshInstance3D = null
var _palette = null
var _brush_material := 3        ## sand
var _brush_colour := RESET      ## the material's own colour
var _dirty := false
var _shot_mode := false
var _status := "loaded"


## Stand the tools in a scene that already has its terrain.
func setup(host) -> void:
	_host = host
	_camera = host._camera
	_streamer = host._streamer
	_sun = host._sun
	_mat = host._mat
	_world_path = host._world_path
	_seed = host._seed
	_drowned = host._drowned
	_status = host._load_status
	_shot_mode = host._edit_shot
	_build_scenery()
	_refresh_markers()
	if _shot_mode:
		_run_shots()


func _build_scenery() -> void:
	_markers = Node3D.new()
	_markers.name = "PadMarkers"
	add_child(_markers)

	# The brush: a flat ring, one metre across, scaled to the radius.
	_ring = MeshInstance3D.new()
	_ring.name = "BrushRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.96
	torus.outer_radius = 1.0
	torus.rings = 48
	_ring.mesh = torus
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(1.0, 0.9, 0.3, 0.8)
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.no_depth_test = true
	_ring.material_override = rm
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)


	var layer := CanvasLayer.new()
	_label = Label.new()
	# Top RIGHT: the scene's own readout has the top left.
	_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.position = Vector2(-14, 12)
	_label.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	add_child(layer)

	# The paint brush's palette (§20.7), shown while that brush is in hand.
	# Click it with the mouse free (ESC); or , . for colour, PAGE UP/DOWN
	# for material.
	_palette = PaintPalette.new()
	_palette.name = "PaintPalette"
	_palette.visible = false
	layer.add_child(_palette)
	_palette.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_palette.position = Vector2(14, 440)
	_palette.setup(_palette_materials(), _palette_colours, _brush_material, _brush_colour)
	_palette.picked.connect(func(m: int, c: int) -> void:
		_brush_material = m
		_brush_colour = c
		_status = "paint: %s" % _paint_name())


func _process(delta: float) -> void:
	if _host == null:
		return
	if _grabbing:
		_drag_marker()
	_brush_tick(delta)
	_update_hud()


## The ground materials an author can paint, plus KEEP (colour only) and
## NATURAL (back to what the noise said). Air is not a material to paint.
func _palette_materials() -> Array:
	var out: Array = [{"value": KEEP, "name": "keep"}]
	for m in range(1, MATERIALS.size()):
		out.append({"value": m, "name": MATERIALS[m]})
	out.append({"value": RESET, "name": "natural"})
	return out


## Any material takes any filament: the ground is printed, and a spool is a
## spool. First its own colour, and KEEP for material-only strokes.
func _palette_colours(m: int) -> Array:
	var own := Color(0.5, 0.5, 0.5)
	if m >= 1:
		own = BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(m))
	var out: Array = [
		{"value": RESET, "name": "the material's own colour", "color": own, "mark": "M"},
		{"value": KEEP, "name": "keep the colour", "color": Color(0.2, 0.2, 0.22), "mark": "-"},
	]
	for i in BrickWorld.get_filament_count():
		var col := BrickWorld.get_filament_colour(i)
		col.a = 1.0
		out.append({"value": i, "name": _filament_name(i), "color": col})
	return out


## A filament's name, as the workshop names it: the colours of any brick
## material that takes every spool.
static func _filament_name(i: int) -> String:
	for m in BrickWorld.get_material_count():
		if BrickWorld.is_filament_material(m) and i < BrickWorld.get_material_colour_count(m):
			return BrickWorld.get_material_colour_name(m, i)
	return "filament %d" % i


func _paint_name() -> String:
	var m := "keep" if _brush_material == KEEP else ("natural" if _brush_material == RESET
			else MATERIALS[_brush_material])
	var c := "own colour" if _brush_colour == RESET else ("keep colour" if _brush_colour == KEEP
			else _filament_name(_brush_colour))
	return "%s, %s" % [m, c]


## P: take the material and colour of the ground under the cursor.
func _pick_paint() -> void:
	var hit := _aim_field()
	if hit.is_empty():
		return
	var stud := BrickWorld.get_stud_metres()
	var p: Vector3 = hit["position"]
	var gx := int(floor(p.x / stud))
	var gz := int(floor(p.z / stud))
	_brush_material = BrickTerrain.material_at(gx, gz)
	_brush_colour = BrickTerrain.colour_at(gx, gz)
	_palette.show_pick(_brush_material, _brush_colour)
	_status = "picked %s" % _paint_name()


func _is_brush() -> bool:
	return int(_tool) >= int(Tool.RAISE)


## The brush, every frame: the ring under the cursor, and a dab while held.
func _brush_tick(delta: float) -> void:
	if _ring == null:
		return
	var hit := _aim_field() if _is_brush() else {}
	_ring.visible = not hit.is_empty()
	if hit.is_empty():
		return
	var p: Vector3 = hit["position"]
	var stud := BrickWorld.get_stud_metres()
	_ring.position = p + Vector3.UP * 0.05
	_ring.scale = Vector3.ONE * (_brush_radius * stud)
	if not _stroking:
		return
	var gx := int(floor(p.x / stud))
	var gz := int(floor(p.z / stud))
	var mode := 0
	var amount := 0.0
	match _tool:
		Tool.RAISE:
			amount = _brush_rate * delta
		Tool.LOWER:
			amount = -_brush_rate * delta
		Tool.FLATTEN:
			mode = 1
			amount = clampf(_brush_rate * 2.0 * delta, 0.0, 1.0)
		Tool.SMOOTH:
			mode = 2
			amount = clampf(_brush_rate * 2.0 * delta, 0.0, 1.0)
	var touched: Rect2i
	if _tool == Tool.PAINT_BRUSH:
		touched = BrickTerrain.paint_surface(gx, gz, _brush_radius,
				_brush_material, _brush_colour)
	else:
		touched = BrickTerrain.sculpt(gx, gz, _brush_radius, mode, amount, _flatten_to)
	_pending = touched if _pending.size.x <= 0 else _pending.merge(touched)
	_stroke_rect = touched if _stroke_rect.size.x <= 0 else _stroke_rect.merge(touched)
	_dirty = true
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_flush_brush()


func _begin_stroke() -> void:
	var hit := _aim_field()
	if hit.is_empty():
		_status = "nothing under the cursor"
		return
	BrickTerrain.sculpt_begin_stroke()
	# Half a plate under the surface that was clicked: the field's height is
	# the TOP solid plate, and the surface is the plate above it.
	_flatten_to = float(hit["position"].y) - BrickWorld.get_plate_metres() * 0.5
	_stroking = true
	_refresh_in = 0.0
	_status = "%s stroke" % TOOL_NAMES[int(_tool)].to_lower()


func _end_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
	_flush_brush()
	# The far tier and the seabed once a stroke, not ten times a second:
	# a merged ring is one mesh, and re-baking it is milliseconds.
	if _stroke_rect.size.x > 0:
		_host.terrain_changed(_stroke_rect)
	_stroke_rect = Rect2i()
	_refresh_markers()
	_status = "stroke done (%d to undo)" % BrickTerrain.sculpt_undo_depth()


## Tell the tiles under what the brush touched. They rebake behind the ones
## on screen (TerrainStreamer.refresh), so the ground never opens up.
func _flush_brush() -> void:
	_refresh_in = REFRESH_EVERY
	if _pending.size.x <= 0:
		return
	_streamer.refresh(_tiles_over(_pending))
	_pending = Rect2i()


func _tiles_over(studs: Rect2i) -> Rect2i:
	var tile := BrickTerrain.get_tile_studs()
	var lo := Vector2i(floori(float(studs.position.x) / float(tile)),
			floori(float(studs.position.y) / float(tile)))
	var hi := Vector2i(floori(float(studs.end.x) / float(tile)),
			floori(float(studs.end.y) / float(tile)))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## While grabbing, the MARKER follows the cursor and the ground does not.
##
## Rebuilding terrain every frame of a drag would be a slideshow — a pad is
## tens of studs and a rebuild is tens of tiles — so the ground catches up
## on the drop. The marker is what the author is aiming with anyway.
func _drag_marker() -> void:
	var hit := _aim()
	if hit.is_empty() or _markers.get_child_count() == 0:
		return
	var idx := _marker_index()
	if idx < 0 or idx >= _markers.get_child_count():
		return
	var p: Vector3 = hit["position"]
	var plate := BrickWorld.get_plate_metres()
	var node := _markers.get_child(idx) as MeshInstance3D
	node.position = Vector3(p.x, p.y + plate * 2.0, p.z)


## Where the selected thing's marker sits in the marker list, which is built
## pads first, then paints, then sites.
func _marker_index() -> int:
	if _selected < 0:
		return -1
	match _tool:
		Tool.PAD:
			return _selected
		Tool.PAINT:
			return BrickTerrain.pad_count() + _selected
		_:
			return BrickTerrain.pad_count() + BrickTerrain.paint_count() + _selected


# ---------------------------------------------------------------------------
# Editing

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if _is_brush() and not _grabbing:
			if event.pressed:
				_begin_stroke()
			else:
				_end_stroke()
			return
		if event.pressed:
			_click()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := (event as InputEventKey).keycode
	if Input.is_key_pressed(KEY_CTRL):
		match key:
			KEY_S:
				var err := World.save_world(_world_path, _seed, _drowned)
				_status = "saved %s" % _world_path if err == OK else "SAVE FAILED"
				_dirty = err != OK
				print("[editor] %s" % _status)
			KEY_O:
				var again := World.load_world(_world_path)
				if not again.is_empty():
					_drowned = float(again.get("drowned", 0.30))
				_selected = -1
				_dirty = false
				_status = "reloaded %s" % _world_path
				_rebuild_all()
			KEY_Z:
				var back: Rect2i = BrickTerrain.sculpt_undo()
				if back.size.x > 0:
					_streamer.refresh(_tiles_over(back))
					_host.terrain_changed(back)
					_dirty = true
					_status = "undone (%d left)" % BrickTerrain.sculpt_undo_depth()
				else:
					_status = "nothing to undo"
		return
	match key:
		KEY_0:
			_set_tool(Tool.LOOK)
		KEY_1:
			_set_tool(Tool.PAD)
		KEY_2:
			_set_tool(Tool.PAINT)
		KEY_3:
			_set_tool(Tool.SITE)
		KEY_4:
			_set_tool(Tool.RAISE)
		KEY_5:
			_set_tool(Tool.LOWER)
		KEY_6:
			_set_tool(Tool.FLATTEN)
		KEY_7:
			_set_tool(Tool.SMOOTH)
		KEY_8:
			_set_tool(Tool.PAINT_BRUSH)
		KEY_I:
			if _tool == Tool.PAINT_BRUSH:
				_pick_paint()
		KEY_G:
			if _selected < 0:
				_status = "nothing selected to grab"
			else:
				_grabbing = not _grabbing
				_status = "grabbed — aim and click to drop" if _grabbing 						else "dropped"
		KEY_ESCAPE:
			if _grabbing:
				_grabbing = false
				_status = "grab cancelled"
		KEY_DELETE:
			_delete_selected()
		KEY_BRACKETLEFT:
			_nudge_selected(-2, 0, 0.0)
		KEY_BRACKETRIGHT:
			_nudge_selected(2, 0, 0.0)
		KEY_COMMA:
			if _tool == Tool.PAINT_BRUSH:
				_palette.step_colour(-1)
			else:
				_nudge_selected(0, -1, 0.0)
		KEY_PERIOD:
			if _tool == Tool.PAINT_BRUSH:
				_palette.step_colour(1)
			else:
				_nudge_selected(0, 1, 0.0)
		KEY_MINUS:
			_step_value(-1)
		KEY_EQUAL:
			_step_value(1)
		KEY_PAGEUP:
			if _tool == Tool.PAINT_BRUSH:
				_palette.step_material(1)
			else:
				_step_storeys(1)
		KEY_PAGEDOWN:
			if _tool == Tool.PAINT_BRUSH:
				_palette.step_material(-1)
			else:
				_step_storeys(-1)


func _set_tool(t: Tool) -> void:
	_end_stroke()
	_tool = t
	if _palette != null:
		_palette.visible = t == Tool.PAINT_BRUSH
	_selected = -1
	_status = "tool: %s" % TOOL_NAMES[int(t)].to_lower()
	_refresh_markers()


## `-` and `=` mean different things per tool, because the thing they change
## is what that tool is FOR: a pad is a height, a paint is a material.
func _step_value(dir: int) -> void:
	if _is_brush():
		_brush_rate = clampf(_brush_rate * (1.25 if dir > 0 else 0.8), 0.1, 20.0)
		_status = "strength %.2f" % _brush_rate
		return
	if _tool == Tool.SITE:
		_step_site_floor(dir)
		return
	if _tool == Tool.PAINT:
		if _selected >= 0:
			var q := BrickTerrain.get_paint(_selected)
			var m: int = wrapi(int(q["material"]) + dir, 1, MATERIALS.size())
			var before: Rect2i = BrickTerrain.paint_bounds(_selected)
			BrickTerrain.set_paint(_selected, int(q["x"]), int(q["z"]),
				int(q["radius"]), int(q["skirt"]), m)
			_dirty = true
			_status = "material: %s" % MATERIALS[m]
			_rebuild_around(before)
		else:
			_paint_material = wrapi(_paint_material + dir, 1, MATERIALS.size())
			_status = "brush: %s" % MATERIALS[_paint_material]
		return
	_nudge_selected(0, 0, float(dir) * BrickTerrain.get_brick_metres())


## A site's FLOOR, a course at a time. The building stays on the brick grid
## and the ground comes to meet it: the pad is cut at the floor, so raising
## it builds a plinth of ground and lowering it digs the building in.
func _step_site_floor(dir: int) -> void:
	if _selected < 0 or _selected >= World.sites.size():
		return
	var site: Dictionary = World.sites[_selected]
	var brick := BrickTerrain.get_brick_metres()
	var now := float(site.get("level", World.site_level(site)))
	site["level"] = roundf(now / brick) * brick + float(dir) * brick
	_dirty = true
	_status = "site floor %.2f m" % float(site["level"])
	_restamp_sites()


func _step_storeys(dir: int) -> void:
	if _tool != Tool.SITE or _selected < 0 or _selected >= World.sites.size():
		return
	var site: Dictionary = World.sites[_selected]
	site["storeys"] = maxi(1, int(site["storeys"]) + dir)
	_dirty = true
	_status = "storeys: %d" % int(site["storeys"])
	_refresh_markers()


## Where the camera is pointing, on the ground. The collider is the terrain's
## own, so what gets hit is exactly what is drawn.
func _aim() -> Dictionary:
	var from := _camera.global_position
	var to := from - _camera.global_transform.basis.z * 400.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Layers.WORLD
	return get_world_3d().direct_space_state.intersect_ray(q)


## Where the camera is pointing, on the FIELD rather than on its collider.
##
## A brush rebuilds the tiles it paints ten times a second, and a ray that
## asks the colliders asks about ground that is mid-swap. The field is the
## truth the tiles are built from, so the brush marches it: half a metre a
## step, then halved down to a couple of centimetres.
func _aim_field() -> Dictionary:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var ground := func(p: Vector3) -> float:
		return float(BrickTerrain.surface_plate(int(floor(p.x / stud)),
				int(floor(p.z / stud))) + 1) * plate
	var step := 0.5
	var t := 0.0
	while t < 400.0:
		var p := from + dir * (t + step)
		if p.y <= ground.call(p):
			var lo := t
			var hi := t + step
			for i in 5:
				var mid := (lo + hi) * 0.5
				var q := from + dir * mid
				if q.y <= ground.call(q):
					hi = mid
				else:
					lo = mid
			var at := from + dir * hi
			return {"position": Vector3(at.x, ground.call(at), at.z)}
		t += step
	return {}


func _click() -> void:
	if _tool == Tool.LOOK and not _grabbing:
		return
	var hit := _aim()
	if hit.is_empty():
		_status = "nothing under the cursor"
		return
	var stud := BrickWorld.get_stud_metres()
	var p: Vector3 = hit["position"]
	var gx := int(floor(p.x / stud))
	var gz := int(floor(p.z / stud))

	# A click while grabbing DROPS, rather than placing another one.
	if _grabbing:
		_grabbing = false
		_move_selected(gx, gz)
		return

	var brick := BrickTerrain.get_brick_metres()
	var level := roundf(p.y / brick) * brick
	var tile := BrickTerrain.get_tile_studs()

	# A click on something this tool owns SELECTS it; a click on open ground
	# makes a new one.
	match _tool:
		Tool.PAD:
			var existing := BrickTerrain.pad_at(gx, gz)
			if existing >= 0:
				_selected = existing
				_status = "selected pad %d" % existing
				_refresh_markers()
				return
			BrickTerrain.add_pad(gx, gz, 10, 5, level)
			_selected = BrickTerrain.pad_count() - 1
			_status = "placed pad %d" % _selected
			_dirty = true
			_rebuild_around(BrickTerrain.pad_bounds(_selected))
		Tool.PAINT:
			var hit_paint := BrickTerrain.paint_at(gx, gz)
			if hit_paint >= 0:
				_selected = hit_paint
				_status = "selected paint %d (%s)" % [hit_paint,
					MATERIALS[int(BrickTerrain.get_paint(hit_paint)["material"])]]
				_refresh_markers()
				return
			BrickTerrain.add_paint(gx, gz, 12, 8, _paint_material)
			_selected = BrickTerrain.paint_count() - 1
			_status = "painted %s" % MATERIALS[_paint_material]
			_dirty = true
			_rebuild_around(BrickTerrain.paint_bounds(_selected))
		Tool.SITE:
			# Clicking a site's pad selects it; clicking open ground places a
			# new one, addressed by TILE, because a building stands on one.
			var t := Vector2i(floori(float(gx) / float(tile)),
					floori(float(gz) / float(tile)))
			for i in World.sites.size():
				var c := World.site_centre(World.sites[i])
				if maxi(absi(gx - c.x), absi(gz - c.y)) <= int(World.sites[i]["radius"]):
					_selected = i
					_status = "selected site %d" % i
					_refresh_markers()
					return
			World.sites.append({"tile": t, "radius": 12, "storeys": 5})
			_selected = World.sites.size() - 1
			_status = "placed site %d" % _selected
			_dirty = true
			_restamp_sites()


## Move the selection to a column, rebuilding what it left as well as what
## it arrived at — the same both-ends rule resizing needs.
func _move_selected(gx: int, gz: int) -> void:
	if _selected < 0:
		return
	var tile := BrickTerrain.get_tile_studs()
	match _tool:
		Tool.PAD:
			if _selected >= BrickTerrain.pad_count():
				return
			var pad := BrickTerrain.get_pad(_selected)
			var was: Rect2i = BrickTerrain.pad_bounds(_selected)
			BrickTerrain.set_pad(_selected, gx, gz, int(pad["radius"]),
				int(pad["skirt"]), float(pad["height"]))
			_status = "moved pad %d" % _selected
			_dirty = true
			_rebuild_around(was.merge(BrickTerrain.pad_bounds(_selected)))
		Tool.PAINT:
			if _selected >= BrickTerrain.paint_count():
				return
			var q := BrickTerrain.get_paint(_selected)
			var wasp: Rect2i = BrickTerrain.paint_bounds(_selected)
			BrickTerrain.set_paint(_selected, gx, gz, int(q["radius"]),
				int(q["skirt"]), int(q["material"]))
			_status = "moved paint %d" % _selected
			_dirty = true
			_rebuild_around(wasp.merge(BrickTerrain.paint_bounds(_selected)))
		Tool.SITE:
			if _selected >= World.sites.size():
				return
			World.sites[_selected]["tile"] = Vector2i(
				floori(float(gx) / float(tile)), floori(float(gz) / float(tile)))
			# A site with its own centre (the city's) moves to the stud; an
			# editor site moves a tile at a time.
			if World.sites[_selected].has("centre"):
				World.sites[_selected]["centre"] = Vector2i(gx, gz)
			_status = "moved site %d" % _selected
			_dirty = true
			_restamp_sites()


func _nudge_selected(d_radius: int, d_skirt: int, d_height: float) -> void:
	if _is_brush():
		_brush_radius = clampf(_brush_radius + float(d_radius), 2.0, 64.0)
		_status = "brush radius %d studs" % int(_brush_radius)
		return
	if _selected < 0:
		return
	if _tool == Tool.PAINT:
		if _selected >= BrickTerrain.paint_count():
			return
		var q := BrickTerrain.get_paint(_selected)
		var was: Rect2i = BrickTerrain.paint_bounds(_selected)
		BrickTerrain.set_paint(_selected, int(q["x"]), int(q["z"]),
			maxi(1, int(q["radius"]) + d_radius), maxi(0, int(q["skirt"]) + d_skirt),
			int(q["material"]))
		_dirty = true
		_rebuild_around(was.merge(BrickTerrain.paint_bounds(_selected)))
		return
	if _tool == Tool.SITE:
		if _selected >= World.sites.size():
			return
		var site: Dictionary = World.sites[_selected]
		site["radius"] = maxi(2, int(site["radius"]) + d_radius)
		_dirty = true
		_restamp_sites()
		return
	if _selected >= BrickTerrain.pad_count():
		return
	var pad := BrickTerrain.get_pad(_selected)
	# The OLD bounds have to be rebuilt too, or shrinking a pad leaves the
	# ground it used to flatten exactly as it was.
	var before: Rect2i = BrickTerrain.pad_bounds(_selected)
	BrickTerrain.set_pad(_selected, int(pad["x"]), int(pad["z"]),
		maxi(1, int(pad["radius"]) + d_radius),
		maxi(0, int(pad["skirt"]) + d_skirt),
		float(pad["height"]) + d_height)
	_dirty = true
	_rebuild_around(before.merge(BrickTerrain.pad_bounds(_selected)))


func _delete_selected() -> void:
	if _selected < 0:
		return
	if _tool == Tool.PAINT:
		if _selected >= BrickTerrain.paint_count():
			return
		var pb: Rect2i = BrickTerrain.paint_bounds(_selected)
		BrickTerrain.remove_paint(_selected)
		_selected = -1
		_dirty = true
		_status = "deleted paint"
		_rebuild_around(pb)
		return
	if _tool == Tool.SITE:
		if _selected >= World.sites.size():
			return
		World.sites.remove_at(_selected)
		_selected = -1
		_dirty = true
		_status = "deleted site"
		_restamp_sites()
		return
	if _selected >= BrickTerrain.pad_count():
		return
	var bounds: Rect2i = BrickTerrain.pad_bounds(_selected)
	BrickTerrain.remove_pad(_selected)
	_selected = -1
	_dirty = true
	_status = "deleted"
	_rebuild_around(bounds)


## Everything the edit touched, rebuilt; everything else left alone.
##
## An edit changes the FIELD, so every tile over the pad is stale — but only
## those. A pad is tens of studs across and the world is thousands, so a
## targeted rebuild is the difference between an editor that responds and one
## that stops for a second every time you press a key.
func _rebuild_around(bounds: Rect2i) -> void:
	var tile := BrickTerrain.get_tile_studs()
	var lo := Vector2i(floori(float(bounds.position.x) / float(tile)),
			floori(float(bounds.position.y) / float(tile)))
	var hi := Vector2i(floori(float(bounds.end.x) / float(tile)),
			floori(float(bounds.end.y) / float(tile)))
	_streamer.invalidate(Rect2i(lo, hi - lo + Vector2i.ONE))
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	_host.terrain_changed(bounds)
	_refresh_markers()


## Sites own pads, so moving or resizing one re-cuts every site pad.
##
## `stamp_sites` clears the pad list, which would throw away hand-placed pads
## too — so they are taken out first and put back. Sites and loose pads live
## in the same list because the FIELD only has one kind of flat spot; the
## editor is what knows the difference.
func _restamp_sites() -> void:
	var loose: Array[Dictionary] = []
	for i in BrickTerrain.pad_count():
		if not _is_site_pad(i):
			loose.append(BrickTerrain.get_pad(i))
	BrickTerrain.clear_pads()
	World.stamp_sites_only(World.sites)
	for pad in loose:
		BrickTerrain.add_pad(int(pad["x"]), int(pad["z"]), int(pad["radius"]),
			int(pad["skirt"]), float(pad["height"]), int(pad.get("radius_z", -1)))
	_rebuild_all()


## Is this pad one a site cut, rather than one an author placed by hand?
func _is_site_pad(index: int) -> bool:
	var pad := BrickTerrain.get_pad(index)
	for site in World.sites:
		var c := World.site_centre(site)
		if int(pad["x"]) == c.x and int(pad["z"]) == c.y:
			return true
	return false


func _rebuild_all() -> void:
	var far: int = _host.get_script().FAR_TILES
	_streamer.invalidate(Rect2i(-far, -far, far * 2 + 1, far * 2 + 1))
	var tile := BrickTerrain.get_tile_studs()
	_host.terrain_changed(Rect2i(-far * tile, -far * tile, (far * 2 + 1) * tile,
		(far * 2 + 1) * tile))
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	_refresh_markers()


## A flat disc over each pad, so an author can see what they are editing —
## the ground itself only shows the RESULT of a pad, which is a flat spot
## that looks like any other flat spot.
func _refresh_markers() -> void:
	for child in _markers.get_children():
		_markers.remove_child(child)
		child.queue_free()
	_refresh_shells()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	for i in BrickTerrain.pad_count():
		var pad := BrickTerrain.get_pad(i)
		_marker(Vector3((int(pad["x"]) + 0.5) * stud, float(pad["height"]) + plate,
				(int(pad["z"]) + 0.5) * stud),
			float(int(pad["radius"]) * 2 + 1) * stud,
			Color(0.25, 0.7, 1.0, 0.18),
			_tool == Tool.PAD and i == _selected)
	for i in BrickTerrain.paint_count():
		var q := BrickTerrain.get_paint(i)
		var gx := int(q["x"])
		var gz := int(q["z"])
		_marker(Vector3((gx + 0.5) * stud,
				float(BrickTerrain.surface_plate(gx, gz) + 1) * plate + plate,
				(gz + 0.5) * stud),
			float(int(q["radius"]) * 2 + 1) * stud,
			Color(0.9, 0.45, 0.15, 0.22),
			_tool == Tool.PAINT and i == _selected)
	for i in World.sites.size():
		var site: Dictionary = World.sites[i]
		var c := World.site_centre(site)
		var gx2: int = c.x
		var gz2: int = c.y
		_marker(Vector3((gx2 + 0.5) * stud,
				float(BrickTerrain.surface_plate(gx2, gz2) + 1) * plate + plate * 2.0,
				(gz2 + 0.5) * stud),
			float(int(site["radius"]) * 2 + 1) * stud,
			Color(0.35, 0.95, 0.45, 0.22),
			_tool == Tool.SITE and i == _selected)


## The building on each site, as the city draws it before it materialises
## (BuildingShell), on its floor and its footprint: so an author sees the
## ground meet the building, not a disc where one will go.
func _refresh_shells() -> void:
	if _host != null:
		_host.rebuild_sites()

## A flat disc over an edit, so an author can see what they are editing —
## the ground only shows the RESULT, which looks like ordinary ground.
func _marker(at: Vector3, width: float, tint: Color, selected: bool) -> void:
	var plate := BrickWorld.get_plate_metres()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, plate * 0.5, width)
	mi.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.2, 0.35) if selected else tint
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = at
	_markers.add_child(mi)


func _update_hud() -> void:
	if _label == null:
		return
	var lines: Array[String] = [
		"TERRAIN EDITOR   %s   seed %d%s" % [
			_world_path.get_file().get_basename(), _seed,
			"  *UNSAVED*" if _dirty else ""],
		"world        %d pads   %d paints   %d sites" % [
			BrickTerrain.pad_count(), BrickTerrain.paint_count(),
			World.sites.size()],
		"tool         %s%s" % [TOOL_NAMES[int(_tool)],
			("   brush: %s" % MATERIALS[_paint_material]) if _tool == Tool.PAINT
			else ("   radius %d%s   %d to undo" % [int(_brush_radius),
				"" if _tool == Tool.PAINT_BRUSH else "   strength %.2f" % _brush_rate,
				BrickTerrain.sculpt_undo_depth()])
			if _is_brush() else ""],
		"status       %s" % _status,
	]
	if _tool == Tool.PAD and _selected >= 0 and _selected < BrickTerrain.pad_count():
		var pad := BrickTerrain.get_pad(_selected)
		lines.append("pad %d        at %d,%d   radius %d   skirt %d   height %.2f m" % [
			_selected, int(pad["x"]), int(pad["z"]), int(pad["radius"]),
			int(pad["skirt"]), float(pad["height"])])
	elif _tool == Tool.PAINT and _selected >= 0 and _selected < BrickTerrain.paint_count():
		var q := BrickTerrain.get_paint(_selected)
		lines.append("paint %d      at %d,%d   radius %d   skirt %d   %s" % [
			_selected, int(q["x"]), int(q["z"]), int(q["radius"]),
			int(q["skirt"]), MATERIALS[int(q["material"])]])
	elif _tool == Tool.SITE and _selected >= 0 and _selected < World.sites.size():
		var site: Dictionary = World.sites[_selected]
		lines.append("site %d       tile %s   radius %d   %d storeys   floor %.2f m" % [
			_selected, site["tile"], int(site["radius"]), int(site["storeys"]),
			World.site_level(site)])
	else:
		lines.append("             nothing selected")
	if _grabbing:
		lines.append(">>> GRABBED — aim and click to drop, ESC to cancel")
	lines.append("0 look  1 pad  2 paint  3 site   CLICK place/select")
	lines.append("G grab  DEL remove")
	lines.append("4 raise  5 lower  6 flatten  7 smooth  8 paint")
	lines.append("brushes: HOLD LEFT and drag   CTRL+Z undo")
	if _tool == Tool.PAINT_BRUSH:
		lines.append("painting %s" % _paint_name())
		lines.append(", . colour   PGUP/PGDN material   I pick from ground")
		lines.append("ESC frees the mouse for the palette")
	lines.append("[ ] radius   , . skirt   - = height, material, strength")
	lines.append("PGUP/PGDN storeys")
	lines.append("CTRL+S save   CTRL+O reload")
	_label.text = "\n".join(lines)


# ---------------------------------------------------------------------------

func _run_shots() -> void:
	await _frames(4)
	_camera.position = Vector3(-14.0, 26.0, -14.0)
	await _frames(4)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_world.png")
	print("[editor] shot written: editor_world.png  (%d pads)" % BrickTerrain.pad_count())

	# Place, resize and delete, the way an author would, and photograph the
	# ground each time: an edit that does not change the ground is the
	# failure this capture exists to catch.
	var stud := BrickWorld.get_stud_metres()
	var gx := 40
	var gz := 40
	var brick := BrickTerrain.get_brick_metres()
	var level := roundf(float(BrickTerrain.surface_plate(gx, gz) + 1)
			* BrickWorld.get_plate_metres() / brick) * brick + brick * 2.0
	BrickTerrain.add_pad(gx, gz, 12, 6, level)
	_selected = BrickTerrain.pad_count() - 1
	_rebuild_around(BrickTerrain.pad_bounds(_selected))
	_camera.position = Vector3((gx + 0.5) * stud + 26.0, level + 18.0,
			(gz + 0.5) * stud + 26.0)
	_camera.look_at(Vector3((gx + 0.5) * stud, level, (gz + 0.5) * stud), Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_placed.png")
	print("[editor] shot written: editor_placed.png")

	_nudge_selected(10, 4, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_resized.png")
	print("[editor] shot written: editor_resized.png")

	_delete_selected()
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_deleted.png")
	print("[editor] shot written: editor_deleted.png  (%d pads)"
			% BrickTerrain.pad_count())

	# PAINT: say the ground is sand and watch it become sand.
	_set_tool(Tool.PAINT)
	BrickTerrain.add_paint(gx, gz, 16, 10, 3)
	_selected = BrickTerrain.paint_count() - 1
	_rebuild_around(BrickTerrain.paint_bounds(_selected))
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_painted.png")
	print("[editor] shot written: editor_painted.png  (%d paints, %s)" % [
		BrickTerrain.paint_count(),
		MATERIALS[int(BrickTerrain.get_paint(_selected)["material"])]])

	# SITE: a building's pad, cut by the site rather than by hand.
	_set_tool(Tool.SITE)
	var tile := BrickTerrain.get_tile_studs()
	World.sites.append({"tile": Vector2i(floori(float(gx) / float(tile)) + 1,
			floori(float(gz) / float(tile))), "radius": 14, "storeys": 6})
	_selected = World.sites.size() - 1
	_restamp_sites()
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_site.png")
	print("[editor] shot written: editor_site.png  (%d sites, %d pads)" % [
		World.sites.size(), BrickTerrain.pad_count()])

	# MOVE: the same call a grab makes when it drops.
	_set_tool(Tool.PAD)
	BrickTerrain.add_pad(gx, gz, 10, 5, level)
	_selected = BrickTerrain.pad_count() - 1
	_rebuild_around(BrickTerrain.pad_bounds(_selected))
	var from_here: Vector2i = Vector2i(int(BrickTerrain.get_pad(_selected)["x"]),
			int(BrickTerrain.get_pad(_selected)["z"]))
	_move_selected(gx + 26, gz + 10)
	var now_here: Vector2i = Vector2i(int(BrickTerrain.get_pad(_selected)["x"]),
			int(BrickTerrain.get_pad(_selected)["z"]))
	var stud2 := BrickWorld.get_stud_metres()
	_camera.position = Vector3((gx + 13) * stud2, level + 22.0, (gz + 5) * stud2 + 24.0)
	_camera.look_at(Vector3((gx + 13) * stud2, level, (gz + 5) * stud2), Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_moved.png")
	print("[editor] shot written: editor_moved.png  (pad %s -> %s, ground rebuilt both ends)"
			% [from_here, now_here])

	# BRUSHES (§20.6): a raise stroke dragged across open ground, then a
	# flatten from where it began, rebuilt behind the tiles on screen. The
	# stroke is driven the way a held button drives it, a frame at a time.
	var bx := gx + 150
	var bz := gz - 120
	var ground_y := float(BrickTerrain.surface_plate(bx, bz) + 1) * BrickWorld.get_plate_metres()
	_camera.position = Vector3(bx * stud2 + 4.0, ground_y + 14.0, bz * stud2 + 22.0)
	_camera.look_at(Vector3(bx * stud2, ground_y, bz * stud2), Vector3.UP)
	await _frames(4)
	_set_tool(Tool.RAISE)
	_brush_radius = 12.0
	_brush_rate = 4.0
	_begin_stroke()
	for i in 40:
		# Drag: sweep the aim a little each frame.
		_camera.look_at(Vector3((bx + i * 0.6) * stud2, ground_y, bz * stud2), Vector3.UP)
		_brush_tick(1.0 / 30.0)
		await get_tree().process_frame
	_end_stroke()
	var raised := BrickTerrain.sculpt_at(bx + 12, bz)
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_raised.png")
	_set_tool(Tool.FLATTEN)
	_camera.look_at(Vector3((bx + 30) * stud2, ground_y, bz * stud2), Vector3.UP)
	_begin_stroke()
	for i in 30:
		_camera.look_at(Vector3((bx + 30 - i) * stud2, ground_y, bz * stud2), Vector3.UP)
		_brush_tick(1.0 / 30.0)
		await get_tree().process_frame
	_end_stroke()
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_flattened.png")
	print("[editor] shot written: editor_raised.png, editor_flattened.png  (raised %.2f m, %d stroke(s) to undo)" % [
		raised, BrickTerrain.sculpt_undo_depth()])
	# THE PAINT BRUSH (§20.7): a stripe of sand in a loud colour across the
	# same ground, with its palette up.
	_set_tool(Tool.PAINT_BRUSH)
	_brush_material = 3
	_brush_colour = 4
	_palette.show_pick(_brush_material, _brush_colour)
	_brush_radius = 5.0
	_begin_stroke()
	for i in 40:
		_camera.look_at(Vector3((bx - 10 + i) * stud2, ground_y, (bz - 6) * stud2), Vector3.UP)
		_brush_tick(1.0 / 30.0)
		await get_tree().process_frame
	_end_stroke()
	_streamer.settle(Vector2(_camera.global_position.x, _camera.global_position.z))
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/editor_paint_brush.png")
	print("[editor] shot written: editor_paint_brush.png  (%s)" % _paint_name())
	BrickTerrain.sculpt_undo()

	var undo_rect: Rect2i = BrickTerrain.sculpt_undo()
	BrickTerrain.sculpt_undo()
	print("[editor] undo: both strokes back, %.2f m left at the middle" % BrickTerrain.sculpt_at(bx + 12, bz))
	_streamer.refresh(_tiles_over(undo_rect))
	_set_tool(Tool.PAD)

	# And the world file, round trip, which is the only thing that outlives
	# the session.
	var path := "user://editor_shot_world.json"
	var err := World.save_world(path, _seed, _drowned)
	var pads_before := BrickTerrain.pad_count()
	var paints_before := BrickTerrain.paint_count()
	var sites_before := World.sites.size()
	World.load_world(path)
	print("[editor] world round trip: %s  %d/%d pads  %d/%d paints  %d/%d sites" % [
		"ok" if err == OK else "FAILED",
		BrickTerrain.pad_count(), pads_before,
		BrickTerrain.paint_count(), paints_before,
		World.sites.size(), sites_before])
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw
