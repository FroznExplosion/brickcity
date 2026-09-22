extends Node3D

## Build mode, Stage 2: the workshop. Docs/BuildMode.md section 11.
##
##     godot --path . --resolution 1280x720 res://scenes/workshop.tscn
##
## What it proves is the loop: a part, a ghost, a grid snap, a placement, an
## undo, and a recipe that can be saved and dropped into the city to be shot at.
## Sideways building is Stage 4's frames; fixtures are Stage 5's, and `K` drops
## one in -- a staircase is authored HERE, in the build's own grid, and travels
## with the recipe like everything else.
##
## Three things are deliberately NOT here:
##
##   Streaming, LOD, promotion.  Section 8.1 -- authoring happens in a workshop
##       on its own baseplate, and the city only ever PLACES a finished recipe.
##       That removes every distance-based system from this file.
##   A placement gate on stability.  Section 5 -- "does it fit" gates, "will it
##       hold" only tints. Players brace impossible things on purpose.
##   Damage.  Nothing here calls kill_block. Editing and damage are separate
##       operations and the extension keeps them separate (remove_block).

## Drawn bottom-left, and printed once on start. F1 hides it.
## Every bound key, once. The on-screen panel and the launch log are both built
## from this, so neither can drift from the other or from `_unhandled_input`.
## Rows are [section, key, action, key, action]; "" leaves a cell empty.
const KEY_ROWS := [
	["CAMERA", "click", "capture mouse to look", "ESC", "release it"],
	["", "WASD", "fly", "SPACE", "up"],
	["", "shift", "fast", "Q / CTRL", "down"],
	["", "alt", "slow", "", ""],
	["BUILD", "LMB", "place on the stud aimed at", "RMB", "delete"],
	["", "hold E", "lock height, slide anywhere", "Z", "undo last"],
	["", "[ ]  wheel", "part", ", .", "colour"],
	["", "R", "rotate X / Z", "F", "flip (studs down)"],
	["", "T", "rotate the brick just placed", "", ""],
	["", "V", "snap to side studs", "", ""],
	["", "I", "layer: structure / interior", "", ""],
	["", "K", "spiral staircase at the ghost", "", ""],
	["VIEW", "G", "grid", "H", "stress overlay"],
	["FILE", "F5 / F9", "save / load", "ENTER", "place in city, shoot it"],
	["", "F1", "hide these", "", ""],
]


static func _keys_text() -> String:
	var out := PackedStringArray()
	for r in KEY_ROWS:
		out.append("%-7s %-11s %-30s %-10s %s" % r)
	return "\n".join(out)



## Baseplate size in studs. Big enough for a house, small enough that the whole
## thing is on screen from the default camera.
const PLATE_STUDS := 48
## Head room above the baseplate, in plates.
##
## 48 studs is 240 ticks and 120 plates is 240 ticks, so the build volume is a
## CUBE in tick space. That is not a coincidence worth losing: it means all six
## build grids cover exactly the same region whichever way they are turned, so
## switching grids never moves you somewhere else.
const HEIGHT_PLATES := 120

## The six build grids, by which world axis the grid's own "up" points along.
## Docs/BuildMode.md section 2 -- a sideways brick is a rotated FRAME, so
## building sideways means building in a different grid, not rotating a block.
const FRAME_UPS := [
	Vector3(0, 1, 0),   # upright
	Vector3(0, 0, 1),   # laid toward +Z
	Vector3(0, 0, -1),  # laid toward -Z
	Vector3(1, 0, 0),   # laid toward +X
	Vector3(-1, 0, 0),  # laid toward -X
	Vector3(0, -1, 0),  # inverted
]
const FRAME_NAMES := ["upright", "+Z", "-Z", "+X", "-X", "inverted"]

var world: BrickWorld
var palette := {}
var recipe := BuildRecipe.new()

## The assembly being built. Frame 0 is the upright one with the baseplate in
## it; a sideways one is made by aiming at a bracket's side stud, and there is
## no other way to get one -- a sideways part needs something with studs on its
## side to be on. Docs/BuildMode.md section 2 -- a sideways brick is a rotated
## FRAME, never a rotated block.
var asm: Assembly
var _frame := 0             ## index into asm.frames
## asm frame index -> recipe frame index, filled in on first use.
var _recipe_frames := {}

## The frame currently being built in. Everything that used to say `chunk` says
## this, so the single-frame case is unchanged.
var chunk: int:
	get:
		return asm.frames[_frame] if asm != null and asm.frames.size() > 0 else -1

var _frame_meshes := {}     ## chunk id -> MeshInstance3D
var _frame_studs := {}      ## chunk id -> MultiMeshInstance3D, child of the mesh
var _stud_count := 0        ## studs drawn, all frames, after the last remesh
var _ghost: MeshInstance3D
var _grid: MeshInstance3D
var _overlay: MeshInstance3D
var _camera: Camera3D
var _hud: Label
var _dot: ColorRect
const DOT_PX := 8.0
var _keys: GridContainer
var _keys_panel: PanelContainer
var _keys_on := true

## Which layer is being built. Docs/Interiors.md: a building's structure and
## the things inside it are the same bricks in the same grid and are NOT the
## same object to the solver -- what is in a room weighs nothing in the stress
## pass and is not part of what the building balances on.
##
## Nothing about a brick's shape or place can say which it is. A player who
## builds a table out of wall bricks has built a table, and only they know it,
## so the layer is a mode they are in rather than anything inferred. Everything
## else about placing a brick is identical in both, deliberately: same parts,
## same grids, same snapping, same undo. The recipe carries one bit per block
## and the city reads it into Block::decorative.
var _interior := false
var _part_index := 0
var _colour := 4
var _axis_z := false        ## which of the two axis variants is selected
var _flip := false          ## inverted: 180 degrees about X, so studs point down
var _cell := Vector3i.ZERO  ## where the ghost currently sits
var _valid := false
var _joints := 0

var _grid_on := true
## Snap the ghost onto a bracket's side stud when the cursor finds one.
var _snap_on := true
## The stud the ghost is currently snapped to, or {} for free placement.
var _snapped := {}

## The stud the cursor is on, as a cell of the grid being built in: the column
## the held part has to cover, at the height it sits at. NO_STUD when the cursor
## is not on one.
const NO_STUD := Vector3i(-1, -1, -1)
var _stud := NO_STUD
## The cells the part may cover to be on that stud; `_fit_over` takes any of them.
var _studs := []
## The LOCK, while E is held: the plane the ghost was on when E went down --
## {frame (asm index), y, snapped, stud} -- and the ghost follows the cursor
## across it. {} when E is up. See `_aim`.
var _lock := {}
## up axis -> rotation index. `_rotation_with_up` makes a probe chunk to find
## out, and aiming asks every frame.
var _rot_for_up := {}
## recipe index -> [asm frame index, chunk block id].
##
## Tracked rather than computed. The first version worked out the chunk block id
## as `baseplate_count + recipe_index`, which is only true while nothing has ever
## been removed: `remove_block` leaves a tombstone and ids keep climbing, so
## after one undo every later mapping is off by one. It presented as undo and
## rotate-in-place silently doing nothing the second time.
var _placed_at := []
## What the last edits were, newest last: "brick" or "fixture". Undo asks this
## rather than assuming, because a fixture is not a block and popping the wrong
## list would take a brick out from under a staircase.
var _edits := []
## The blocks each fixture laid into frame 0, newest last.
##
## A fixture is built into the grid it is authored in -- the same grid the
## bricks are in -- so the preview here is the same thing the city builds, and
## the frame's own mesh draws it. What this list is for is undo: a fixture's
## blocks are not recipe blocks, so they are not in `_placed_at`.
var _fixture_blocks := []
var _fixture_parts := PackedInt32Array()

var _grid_plane := -1       ## which local y the grid is drawn on
var _grid_frame := -1
var _overlay_on := false
var _stress_dirty := true
var _stress := {}           ## block id -> load / capacity, for the overlay

var _material: StandardMaterial3D
var _ghost_material: StandardMaterial3D


func _ready() -> void:
	world = BrickWorld.new()
	world.set_seed(1)
	palette = BrickPalette.bake(world)

	asm = Assembly.new(world, palette)
	_build_frames()
	# The baseplate is a real course of bricks, not scenery: it is what a build
	# is grounded to, so the stress solve has something to call the foundation.
	_lay_baseplate()
	world.set_foundation_level(chunk, 0)

	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.75

	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.albedo_color = Color(0.4, 0.9, 1.0, 0.45)
	_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_ghost = MeshInstance3D.new()
	_ghost.material_override = _ghost_material
	add_child(_ghost)

	_grid = MeshInstance3D.new()
	add_child(_grid)
	_build_grid()

	_overlay = MeshInstance3D.new()
	add_child(_overlay)

	_build_lights()
	_build_camera()
	_build_hud()
	_remesh()
	if "--gate" in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		call_deferred("_run_gate")
		return
	print("[workshop]\n" + _keys_text())


# ---------------------------------------------------------------------------
# The gate: what Stage 5 added to this scene
# ---------------------------------------------------------------------------

var _gate_pass := 0
var _gate_fail := 0


func _gate_ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_gate_pass += 1
		print("  ok   %s" % what)
	else:
		_gate_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## Authoring a fixture, driven through the same calls the keys make.
##
## The recipe half of this is `tools/build_probe.gd`; what needs the scene is
## the preview, the undo stack shared with bricks, and the reload.
func _run_gate() -> void:
	print("[workshop] fixtures, authored here (Stage 5)")
	_save_path = "user://_workshop_gate.json"

	# Two courses of a wall, through the real placement path.
	var placed := 0
	for course in 2:
		for x in range(0, 8, 2):
			_cell = Vector3i(x, 1 + course * 3, 0)
			_valid = true
			_snapped = {}
			_place()
			placed += 1
	_gate_ok("bricks go in", recipe.size() == placed, "%d of %d" % [recipe.size(), placed])

	# A staircase where the ghost is.
	_cell = Vector3i(12, 1, 12)
	_place_staircase()
	_gate_ok("K attaches a fixture to the recipe", recipe.fixture_count() == 1)
	var laid: PackedInt32Array = _fixture_blocks[0]
	_gate_ok("as bricks in the build's own grid", laid.size() > 0, "%d blocks" % laid.size())
	# The newel, not the corner of the bounding box: a wedge does not fill its
	# own box, which is the whole reason it is a masked part.
	@warning_ignore("integer_division")
	var mid := Vector3i(12 + StaircaseRecipe.DIAMETER / 2, 1,
			12 + StaircaseRecipe.DIAMETER / 2)
	_gate_ok("standing where the ghost was",
			world.block_at(chunk, mid) == int(laid[0]),
			"block %d at %v, %d laid first" % [world.block_at(chunk, mid), mid, int(laid[0])])
	var steps: int = int((recipe.fixture_at(0).params as Dictionary).get("steps", 0))
	_gate_ok("with a flight long enough to reach what is built above it",
			steps >= StaircaseRecipe.STEPS_PER_TURN, "%d steps" % steps)
	_gate_ok("and the bricks are untouched by it", recipe.size() == placed)

	# Undo is one stack, bricks and fixtures together.
	_undo()
	_gate_ok("undo takes the fixture back", recipe.fixture_count() == 0)
	_gate_ok("and its bricks with it", _fixture_blocks.is_empty()
			and world.block_at(chunk, mid) < 0)
	_gate_ok("without touching the bricks", recipe.size() == placed)
	_undo()
	_gate_ok("the next undo is a brick again", recipe.size() == placed - 1)

	# Save, then load, which starts over from the file.
	_cell = Vector3i(12, 1, 12)
	_place_staircase()
	_save()
	var bricks := recipe.size()
	var fixtures := recipe.fixture_count()
	_load()
	_gate_ok("a reload brings the bricks back", recipe.size() == bricks,
			"%d of %d" % [recipe.size(), bricks])
	_gate_ok("and the fixtures", recipe.fixture_count() == fixtures)
	_gate_ok("with the bricks laid again for each one",
			_fixture_blocks.size() == fixtures)
	_gate_ok("and the undo stack knows about both",
			_edits.size() == bricks + fixtures, "%d entries" % _edits.size())

	# A picture of it, because "the preview exists" and "the preview is a
	# staircase" are different claims.
	var look := Vector3(12.0 * 0.35, 0.0, 12.0 * 0.35)
	_camera.global_position = look + Vector3(-6.0, 4.5, -6.0)
	_camera.look_at(look + Vector3(0.0, 1.5, 0.0), Vector3.UP)
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://shots/workshop_fixture.png")
	print("[workshop] shot written: workshop_fixture.png")
	await RenderingServer.frame_post_draw

	# And the whole thing still goes into a city.
	_place_in_city()
	_gate_ok("it still places in the city", true)

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Create every build grid up front, all covering the same volume.
##
## The first version created a sideways frame on demand, at an offset derived
## from wherever the cursor happened to be in the PREVIOUS grid -- so the new
## grid landed somewhere unrelated and bricks appeared nowhere near the cursor.
## Six co-located grids removes the whole class of problem: switching grid
## changes the orientation you build in and nothing else.
func _build_frames() -> void:
	var dims := Vector3i(PLATE_STUDS, HEIGHT_PLATES, PLATE_STUDS)
	for up in FRAME_UPS:
		var rot := _rotation_with_up(up)
		if rot < 0:
			push_error("[workshop] no rotation maps up to %v" % up)
			continue
		asm.add_frame(dims, rot, _origin_for(rot, dims))


## Which of the 24 rotations sends the grid's own +Y to this world axis.
##
## Looked up rather than hard-coded: the enumeration order of the 24 is an
## implementation detail of the extension.
func _rotation_with_up(up: Vector3) -> int:
	if _rot_for_up.has(up):
		return _rot_for_up[up]
	var probe := world.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))
	var found := -1
	for r in BrickWorld.rotation_count():
		world.set_chunk_frame(probe, r, Vector3i.ZERO)
		if world.get_chunk_transform(probe).basis.y.is_equal_approx(up):
			found = r
			break
	world.release_chunk(probe)
	_rot_for_up[up] = found
	return found


## Where a rotated grid has to start so its cells land ON the build volume.
##
## A grid's cells run from local (0,0,0) upward, and a rotation can send that
## corner anywhere -- including into negative world space, where the chunk has
## no cells at all. Offsetting by the rotated box's minimum corner puts every
## grid's buildable region over the same tick cube. Exact integers, because the
## whole point of ticks is that cross-grid alignment never rounds.
func _origin_for(rotation: int, dims: Vector3i) -> Vector3i:
	var probe := world.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))
	world.set_chunk_frame(probe, rotation, Vector3i.ZERO)
	var b: Basis = world.get_chunk_transform(probe).basis
	world.release_chunk(probe)

	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var far: Vector3 = b * Vector3(dims.x * t, dims.y * pt, dims.z * t)
	return Vector3i(
		int(round(-minf(0.0, far.x))),
		int(round(-minf(0.0, far.y))),
		int(round(-minf(0.0, far.z))))


## A one-plate floor of 4x4 plates. Every build starts clipped to this, which is
## what makes "is it grounded" a real question in the workshop as well as the city.
func _lay_baseplate() -> void:
	var p: int = palette["plate_4x4"]
	for x in range(0, PLATE_STUDS, 4):
		for z in range(0, PLATE_STUDS, 4):
			world.place_block(chunk, Vector3i(x, 0, z), p, 2)


func _build_lights() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, -0.6, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.15, 0.19)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.55, 0.62)
	e.ambient_light_energy = 0.55
	env.environment = e
	add_child(env)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.set_script(load("res://scripts/debug_camera.gd"))
	_camera.far = 400.0
	_camera.set("e_climbs", false)   # E is the plane lock here; SPACE still climbs
	var mid := PLATE_STUDS * BrickPalette.STUD_M * 0.5
	var centre := Vector3(mid, 0.0, mid)
	_camera.position = centre + Vector3(-mid * 0.9, mid * 0.75, mid * 1.35)
	add_child(_camera)
	# look_at needs the node in the tree, and the debug camera reads its own
	# rotation on the first frame, so set it before anything else runs.
	_camera.look_at(centre + Vector3(0.0, mid * 0.25, 0.0), Vector3.UP)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(12, 10)
	_style(_hud, Color(0.92, 0.94, 1.0))
	layer.add_child(_hud)

	# The aim dot. While the mouse is captured the aim ray goes through the
	# middle of the screen, and this says exactly where that is. Its colour is
	# worked out from what is under it (shaders/crosshair.gdshader), because
	# the bricks behind it are whatever colour the player chose.
	_dot = ColorRect.new()
	var dot_mat := ShaderMaterial.new()
	dot_mat.shader = load("res://shaders/crosshair.gdshader")
	dot_mat.set_shader_parameter("size_px", DOT_PX)
	_dot.material = dot_mat
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dot.set_anchors_preset(Control.PRESET_CENTER)
	_dot.offset_left = -DOT_PX * 0.5
	_dot.offset_top = -DOT_PX * 0.5
	_dot.offset_right = DOT_PX * 0.5
	_dot.offset_bottom = DOT_PX * 0.5
	layer.add_child(_dot)

	# The controls, on screen rather than only in the launch log. A build mode
	# whose keys you have to remember is a build mode nobody uses.
	#
	# On a dark panel rather than outlined text alone: the bricks behind it are
	# whatever colour the player chose, so contrast cannot be assumed.
	_keys_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.11, 0.72)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 12
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_keys_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(_keys_panel)

	# A GRID of labels, not one label of spaced-out text. Aligning columns with
	# spaces needs a monospace font, and the system monospace font's line height
	# came out different from one run to the next -- tight in one capture, twice
	# the height in the next, with the same settings. A grid aligns by cell, in
	# the default font, and has nothing to tune.
	_keys = GridContainer.new()
	_keys.columns = 5
	_keys.add_theme_constant_override("h_separation", 14)
	_keys.add_theme_constant_override("v_separation", 0)
	for r in KEY_ROWS:
		for i in 5:
			var l := Label.new()
			l.text = r[i]
			var col := Color(0.55, 0.62, 0.75)        # section
			if i == 1 or i == 3:
				col = Color(1.0, 0.86, 0.45)          # key
			elif i == 2 or i == 4:
				col = Color(0.84, 0.87, 0.93)         # action
			_style(l, col, 13)
			_keys.add_child(l)
	_keys_panel.add_child(_keys)

	get_viewport().size_changed.connect(_place_keys)
	call_deferred("_place_keys")


func _style(l: Label, col: Color, size: int = 15) -> void:
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_font_size_override("font_size", size)


func _place_keys() -> void:
	if _keys_panel == null:
		return
	var h: float = get_viewport().get_visible_rect().size.y
	_keys_panel.position = Vector2(12, h - _keys_panel.size.y - 12)


# ---------------------------------------------------------------------------
# The part being held
# ---------------------------------------------------------------------------

func _parts() -> Array:
	return BrickPalette.parts()


func _part() -> String:
	return _parts()[_part_index % _parts().size()]


## The archetype name for the held part in its current orientation.
##
## A square part has one axis variant, so R does nothing to it and its name
## carries no axis suffix. F adds `_i`, which is a real different part: its
## studs point down, so it mates with a socket rather than with a stud
## (Docs/BuildMode.md section 3.1). An inverted brick will NOT clip onto a
## normal one, and the ghost goes amber to say so rather than pretending.
func _archetype_name() -> String:
	var square := BrickPalette.is_square(_part())
	var name := _part() if square else (_part() + ("_z" if _axis_z else "_x"))
	return name + "_i" if _flip else name


func _archetype() -> int:
	return palette[_archetype_name()]


# ---------------------------------------------------------------------------
# The placement loop. Docs/BuildMode.md section 4.
# ---------------------------------------------------------------------------

func _process(_dt: float) -> void:
	_dot.visible = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	_aim()
	_update_ghost()
	_update_hud()
	# A PanelContainer does not know its height until it has laid out, so the
	# first placement lands short. Cheap to keep pinned rather than to guess.
	if _keys_panel != null and _keys_panel.visible:
		_place_keys()
	# The grid follows the plane the ghost is on.
	if _grid_on and (_cell.y != _grid_plane or chunk != _grid_frame):
		_grid_plane = _cell.y
		_grid_frame = chunk
		_build_grid()


## Where the ghost goes.
##
## Two modes, and the player always knows which one they are in, because the
## second is only on while they hold a key:
##
##   AIM (default).  Look at a stud and the part goes ON that stud. The face
##       picks the grid -- a brick's top keeps the grid that brick is in, a
##       bracket's side stud derives a sideways one -- so the part turns to
##       match what it is going onto, by itself. It then covers the stud
##       the cursor is on: centred when that fits, shifted along until it does
##       when it does not, so aiming at the end stud of a wall never puts the
##       ghost into the wall beside it.
##   LOCK (hold E).  The plane the ghost is on at that moment -- that grid, that
##       height -- is frozen, and the ghost follows the cursor across it. That
##       is the overhang move (a 1x4 pulled off the end of a 1x6 until one stud
##       overlaps) and the way out into mid-air at a chosen height.
##
## The first version had the lock ALWAYS on: a plane stayed until the cursor
## found something nearer than it. The overhang worked, and a ghost that had
## once been on top of a wall stayed at wall height while the cursor went out
## across the floor, which read as placement being broken.
func _aim() -> void:
	var ray := _mouse_ray()
	_hold_lock(Input.is_key_pressed(KEY_E))
	_aim_ray(ray[0], ray[1])


## [from, dir] for the ray being aimed: through the middle of the screen (the
## dot) while the mouse is captured to look, under the cursor while it is free.
func _mouse_ray() -> Array:
	var vp := get_viewport()
	var from: Vector3 = _camera.global_position
	var dir: Vector3 = -_camera.global_transform.basis.z
	if vp != null:
		var m := vp.get_mouse_position()
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			m = vp.get_visible_rect().size * 0.5
		from = _camera.project_ray_origin(m)
		dir = _camera.project_ray_normal(m)
	return [from, dir]


## E down freezes the plane the ghost is on right now; E up lets it go. Over
## bare floor that is the floor, which is as much a plane as a brick top.
func _hold_lock(on: bool) -> void:
	if not on:
		_lock = {}
	elif _lock.is_empty():
		_lock = {"frame": _frame, "y": _cell.y, "snapped": _snapped, "studs": _studs}


## The placement rule itself, for any ray. Split from `_aim` so a probe can
## drive it with exact rays instead of a mouse (tools/place_probe.gd).
func _aim_ray(from: Vector3, dir: Vector3) -> void:
	if not _lock.is_empty():
		_slide_on_lock(from, dir)
		return
	_snapped = {}
	_stud = NO_STUD
	_studs = []
	var hit := _first_hit(from, dir)
	if hit.is_empty():
		_free_aim(from, dir)
		return
	var face := _face_for(hit, dir)
	if face.is_empty():
		return
	_enter_face(face, hit)


## Distance along the ray to local plane `y` of grid `frame_chunk`, or INF when
## the ray runs parallel to it or it is behind the camera.
func _plane_distance(frame_chunk: int, y: int, from: Vector3, dir: Vector3) -> float:
	var xf: Transform3D = world.get_chunk_transform(frame_chunk)
	var n: Vector3 = xf.basis.y.normalized()
	var p0: Vector3 = xf * Vector3(0.0, y * BrickPalette.PLATE_M, 0.0)
	var denom := n.dot(dir)
	if absf(denom) < 0.0001:
		return INF
	var t := n.dot(p0 - from) / denom
	return t if t > 0.05 else INF


## March for the first solid cell in any grid. Returns {t, frame, block, point}.
func _first_hit(from: Vector3, dir: Vector3) -> Dictionary:
	var step := BrickPalette.PLATE_M * 0.34
	var t := 0.0
	while t < 120.0:
		var p := from + dir * t
		for f in asm.frames:
			var bid := world.block_at(f, _cell_in(f, p))
			if bid >= 0 and world.is_solid(f, _cell_in(f, p)):
				return {"t": t, "frame": f, "block": bid, "point": p}
		t += step
	return {}


## The face of the block that was hit, as something to build on.
##
## Decided by the face the ray went IN through, not by guessing from the view
## direction:
##
##   top      -- the part goes on top, the ordinary case;
##   bottom   -- the part goes UNDER, its top against the block's underside.
##               Whether that clips is `would_connect`'s answer and the ghost's
##               colour says it: a brick's sockets take a brick's studs;
##   a side   -- a bracket's side stud on that face, if it has one there, and
##               the part is built sideways off it. Any other side of anything
##               is treated as its top: a plain brick offers nothing sideways.
##
## The first version picked a side stud whenever one faced the camera by more
## than a threshold, which needed a special case for looking straight down at a
## bracket; the entry face has no such case to get wrong.
func _face_for(hit: Dictionary, dir: Vector3) -> Dictionary:
	var box: Array = world.get_block_ticks(hit.frame, hit.block)
	if box.is_empty():
		return {}
	var lo: Vector3i = box[0]
	var hi: Vector3i = lo + (box[1] as Vector3i)
	var up: Vector3i = _round_axis(world.get_chunk_transform(hit.frame).basis.y)
	var from: Vector3 = hit.point - dir * hit.t
	var entry := _entry_normal(lo, hi, from, dir)

	if entry == -up:
		return {
			"lo": lo, "hi": hi, "dir": -up,
			"frame": hit.frame, "block": hit.block, "bottom": true,
		}
	if entry != up and _snap_on:
		# Of the studs on the face the ray came in through, the one nearest the
		# ray is the one being looked at.
		var best := {}
		var best_miss := INF
		for stud in _real_side_studs(hit.frame, hit.block):
			if stud.dir != entry:
				continue
			var to: Vector3 = stud.centre - from
			var miss := (to - dir * to.dot(dir)).length()
			if miss < best_miss:
				best_miss = miss
				best = stud
		if not best.is_empty():
			return best
	return {
		"lo": lo, "hi": hi, "dir": up,
		"frame": hit.frame, "block": hit.block, "top": true,
	}


## Which face of a box (world ticks) a ray enters through, as an outward world
## axis. The slab test: the entry face is on the axis whose slab the ray enters
## LAST.
func _entry_normal(lo: Vector3i, hi: Vector3i, from: Vector3, dir: Vector3) -> Vector3i:
	var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	var a := Vector3(lo) * tick
	var b := Vector3(hi) * tick
	var best_t := -INF
	var n := Vector3i.ZERO
	for axis in 3:
		if absf(dir[axis]) < 0.000001:
			continue
		var t := minf((a[axis] - from[axis]) / dir[axis], (b[axis] - from[axis]) / dir[axis])
		if t > best_t:
			best_t = t
			n = Vector3i.ZERO
			n[axis] = -1 if dir[axis] > 0.0 else 1
	return n


## A bracket's side studs as they really sit, one per stud of its length.
##
## The extension records each on the bracket's bottom plate row (see
## `BrickPalette._side_studs_for`); a real stud is a stud wide, so its centre is
## half a stud up from the bracket's base, and a part on it stands flush with
## that base. Buried studs are already left out by the extension.
##
## Each is {lo, hi, dir, centre, base, frame, block}: `lo`/`hi` are the raw cell
## (its face is the plane the part goes on), `centre` is the real stud's centre
## on that face in metres, and `base` is the bracket's world-tick box corner the
## sideways grid is lined up with.
func _real_side_studs(frame_chunk: int, block: int) -> Array:
	var out := []
	var raw: Array = world.get_side_studs(frame_chunk, block)
	if raw.is_empty():
		return out
	var box: Array = world.get_block_ticks(frame_chunk, block)
	var blo: Vector3i = box[0]
	var bhi: Vector3i = blo + (box[1] as Vector3i)
	var up: Vector3i = _round_axis(world.get_chunk_transform(frame_chunk).basis.y)
	var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	var half := BrickWorld.ticks_per_stud() * 0.5
	for s in raw:
		var d := {
			"lo": s.lo, "hi": s.hi, "dir": s.dir,
			"frame": frame_chunk, "block": block, "base": blo,
		}
		var c := _stud_world_centre(d) / tick
		for axis in 3:
			if up[axis] > 0:
				c[axis] = blo[axis] + half
			elif up[axis] < 0:
				c[axis] = bhi[axis] - half
		d["centre"] = c * tick
		out.append(d)
	return out


static func _round_axis(v: Vector3) -> Vector3i:
	return Vector3i(int(round(v.x)), int(round(v.y)), int(round(v.z)))


## Put the held part on the stud the cursor is on -- or under the socket.
##
## Switches to the grid that matches the face, finds the stud column in it, and
## fits the part over that column.
func _enter_face(face: Dictionary, hit: Dictionary) -> bool:
	if not _enter_stud_frame(face):
		return false
	var d := Vector3(face.dir as Vector3i)
	if face.has("centre"):
		# A side stud: the sideways grid is lined up with the bracket, so the
		# stud's centre is a cell centre and the part covers exactly it.
		_snapped = face
		_studs = [_cell_in(chunk, face.centre + d * 0.001)]
	else:
		# A top or bottom face has a stud (or socket) in every column, and the
		# one meant is the one under the cursor. The hit point is just inside
		# the block, so its column is one of the block's own. `s` is the cell
		# just outside the face.
		var s := _cell_in(chunk, _stud_world_centre(face) + d * 0.001)
		var c := _cell_in(chunk, hit.point)
		var y := s.y
		if face.get("bottom", false):
			# Under it: the part's TOP row is the one just below the face.
			y = s.y - BrickPalette.size_of(_archetype_name()).y + 1
		_studs = [Vector3i(c.x, y, c.z)]
	_stud = _studs[0]
	_cell = _fit_over(_studs)
	return true


## The cell that puts the held part over one of `studs`: centred on the first
## when that fits, otherwise the nearest shift that still covers one. When
## nothing that covers one fits, centred anyway, and the ghost goes red where
## it was aimed.
func _fit_over(studs: Array) -> Vector3i:
	var size := BrickPalette.size_of(_archetype_name())
	@warning_ignore("integer_division")
	var half := Vector3i((size.x - 1) / 2, 0, (size.z - 1) / 2)
	var first: Vector3i = studs[0]
	var centred := _clamp_cell(Vector3i(first.x - half.x, first.y, first.z - half.z), size)
	var arch := _archetype()
	var best := centred
	var best_d := -1
	for stud: Vector3i in studs:
		for dx in size.x:
			for dz in size.z:
				var c := Vector3i(stud.x - dx, stud.y, stud.z - dz)
				if c != _clamp_cell(c, size):
					continue
				var dist := absi(c.x - centred.x) + absi(c.z - centred.z)
				if best_d >= 0 and dist >= best_d:
					continue
				if asm.can_place(chunk, c, arch):
					best = c
					best_d = dist
	return best


## Keep a part's cell inside the build volume.
func _clamp_cell(c: Vector3i, size: Vector3i) -> Vector3i:
	return Vector3i(
		clampi(c.x, 0, PLATE_STUDS - size.x),
		clampi(c.y, 0, HEIGHT_PLATES - size.y),
		clampi(c.z, 0, PLATE_STUDS - size.z))


## E held: the ghost follows the cursor across the locked plane.
##
## No fitting here. The player is placing by hand, so a cell that does not fit
## goes red rather than the ghost quietly going somewhere else.
func _slide_on_lock(from: Vector3, dir: Vector3) -> void:
	_frame = _lock.frame
	var t := _plane_distance(chunk, _lock.y, from, dir)
	if t == INF:
		return
	var cell := _cell_in(chunk, from + dir * t)
	var size := BrickPalette.size_of(_archetype_name())
	@warning_ignore("integer_division")
	var half := Vector3i((size.x - 1) / 2, 0, (size.z - 1) / 2)
	_cell = _clamp_cell(Vector3i(cell.x - half.x, _lock.y, cell.z - half.z), size)
	# A side stud only holds what is still ON it. Slide the part off the stud
	# and it is a part floating on that plane, not one welded to the bracket.
	_studs = _lock.studs
	_stud = _studs[0] if not _studs.is_empty() else NO_STUD
	var covers := false
	for s: Vector3i in _studs:
		if s.x >= _cell.x and s.x < _cell.x + size.x \
				and s.z >= _cell.z and s.z < _cell.z + size.z:
			covers = true
	_snapped = _lock.snapped if covers else {}


## Nothing under the cursor: the baseplate's top, extended past its edge.
func _free_aim(from: Vector3, dir: Vector3) -> void:
	_frame = 0
	var t := _plane_distance(chunk, 1, from, dir)
	if t == INF:
		return
	var size := BrickPalette.size_of(_archetype_name())
	var cell := _cell_in(chunk, from + dir * t)
	@warning_ignore("integer_division")
	var half := Vector3i((size.x - 1) / 2, 0, (size.z - 1) / 2)
	_cell = _clamp_cell(Vector3i(cell.x - half.x, 1, cell.z - half.z), size)


## Where a face sits in the world, in metres: the centre of the cell face the
## stud is on.
func _stud_world_centre(stud: Dictionary) -> Vector3:
	var lo: Vector3i = stud.lo
	var hi: Vector3i = stud.hi
	var d: Vector3i = stud.dir
	var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	var c := (Vector3(lo) + Vector3(hi)) * 0.5
	c.x = (float(hi.x) if d.x > 0 else float(lo.x)) if d.x != 0 else c.x
	c.y = (float(hi.y) if d.y > 0 else float(lo.y)) if d.y != 0 else c.y
	c.z = (float(hi.z) if d.z > 0 else float(lo.z)) if d.z != 0 else c.z
	return c * tick


## Switch to the grid that matches this face.
##
## A TOP face keeps the grid the block already lives in -- building upward on a
## brick does not change orientation. A SIDE stud derives a grid instead: its
## "up" is the stud's normal and its origin is whatever puts the build plane
## exactly on the stud's face.
##
## Deriving rather than picking one of the six standing grids is what makes
## sideways building reach every plane. A grid at a fixed origin steps by one
## PLATE (2 ticks) while upright brick faces sit at stud boundaries (multiples
## of 5), so it can only ever meet every second stud. An origin taken from the
## stud has no such parity.
func _enter_stud_frame(stud: Dictionary) -> bool:
	var d: Vector3i = stud.dir
	if not stud.has("centre"):
		var idx := asm.frames.find(stud.frame)
		if idx < 0:
			return false
		_frame = idx
		return true
	var rot := _rotation_with_up(Vector3(d))
	if rot < 0:
		return false
	var lo: Vector3i = stud.lo
	var hi: Vector3i = stud.hi
	var plane := Vector3i(
		hi.x if d.x > 0 else lo.x,
		hi.y if d.y > 0 else lo.y,
		hi.z if d.z > 0 else lo.z)
	var dims := Vector3i(PLATE_STUDS, HEIGHT_PLATES, PLATE_STUDS)
	var origin := _origin_on_plane(rot, dims, d, plane, stud.base)
	var f := _asm_frame_for(rot, origin)
	if f < 0:
		f = asm.frames.size()
		if asm.add_frame(dims, rot, origin) < 0:
			return false
		_remesh()
	_frame = f
	return true


## A frame origin that puts the grid's local y = 0 plane exactly on `plane`,
## with its stud lines on `align`'s, and still over the build volume.
##
## Across the face the grid steps in whole studs. Left where `_origin_for` puts
## it, those steps fall at multiples of 5 ticks from the world corner while a
## bracket sits at plate heights (multiples of 2), so a part on its side stud
## hung a tick or three off -- up out of line with the bracket, or down into the
## baseplate. Shifting each in-plane axis by under a stud onto the bracket's own
## corner lines every cell up with it.
func _origin_on_plane(rotation: int, dims: Vector3i, dir: Vector3i,
		plane: Vector3i, align: Vector3i) -> Vector3i:
	var origin := _origin_for(rotation, dims)
	var t := BrickWorld.ticks_per_stud()
	for axis in 3:
		if dir[axis] != 0:
			# Local y maps to `dir`, so this component is the build plane.
			origin[axis] = plane[axis]
		else:
			origin[axis] += posmod(align[axis] - origin[axis], t)
	return origin


## Is this world point inside a live brick in ANY grid?
func _solid_anywhere(p: Vector3) -> bool:
	for f in asm.frames:
		if world.is_solid(f, _cell_in(f, p)):
			return true
	return false


## A world point as a cell of one grid. The grid transform is a rotation plus a
## translation, so its inverse is exact enough to floor.
func _cell_in(frame: int, p: Vector3) -> Vector3i:
	var local: Vector3 = world.get_chunk_transform(frame).affine_inverse() * p
	# Nudge before flooring. A point exactly on a cell boundary comes back as
	# 0.9999997 of a cell often enough to matter -- 0.350 / 0.35 does it -- and
	# flooring that lands the ghost a whole cell short, which looked like the
	# snap aiming at the wrong place entirely.
	const EPS := 0.001
	return Vector3i(
		int(floor(local.x / BrickPalette.STUD_M + EPS)),
		int(floor(local.y / BrickPalette.PLATE_M + EPS)),
		int(floor(local.z / BrickPalette.STUD_M + EPS)))


## Three tint states, straight off would_connect: -1 red, 0 amber, positive cyan.
func _update_ghost() -> void:
	var arch := _archetype()
	_joints = world.would_connect(chunk, _cell, arch)
	# Occupancy is per chunk, so `would_connect` cannot see another frame at all.
	# A sideways brick dropped inside an upright one would place happily without
	# this (Docs/BuildMode.md section 2.3).
	_valid = _joints >= 0 and asm.can_place(chunk, _cell, arch)
	if _joints >= 0 and not _valid:
		_joints = -1

	var size := BrickPalette.size_of(_archetype_name())
	var box := BoxMesh.new()
	box.size = BrickPalette.extents_m(size)
	_ghost.mesh = box
	# The ghost belongs to the frame being built in, so it has to be drawn in
	# that frame's space rather than the world's.
	_ghost.transform = world.get_chunk_transform(chunk) \
			* Transform3D(Basis(), BrickWorld.grid_to_world(_cell) + box.size * 0.5)

	# Red is still "it does not fit" in either layer -- that is a placement
	# answer, and the layer does not change it. The other two say which layer
	# this brick is going in, because the thing most worth seeing before the
	# click is which of the two you are about to add to.
	#
	# A part on a side stud has no joint in its own grid -- the stud holds it
	# through a weld, across grids -- so it counts as attached, not mid-air.
	var held := _joints > 0 or not _snapped.is_empty()
	if not _valid:
		_ghost_material.albedo_color = Color(1.0, 0.25, 0.22, 0.45)
	elif _interior:
		_ghost_material.albedo_color = Color(0.72, 1.0, 0.35, 0.40) if held \
				else Color(0.72, 1.0, 0.35, 0.28)
	elif not held:
		_ghost_material.albedo_color = Color(1.0, 0.72, 0.15, 0.40)
	else:
		_ghost_material.albedo_color = Color(0.35, 0.9, 1.0, 0.40)


func _update_hud() -> void:
	var state := "OCCUPIED"
	if _valid:
		if not _snapped.is_empty():
			state = "on a side stud"
		elif _joints == 0:
			state = "mid-air (allowed)"
		else:
			state = "%d joints" % _joints
	if not _lock.is_empty():
		state += "  [plane locked -- E]"
	var worst := 0.0
	for v in _stress.values():
		worst = maxf(worst, v)
	var interior := recipe.interior_count()
	_hud.text = "%s  [%s%s]  colour %d   grid: %s\nlayer: %s\ncell %v   %s\n%d brick(s): %d structure, %d interior%s%s" % [
		_part(), "Z" if _axis_z else "X", " inverted" if _flip else "",
		_colour, FRAME_NAMES[_frame] if _frame < FRAME_NAMES.size() else str(_frame),
		"INTERIOR (I)  — weighs nothing, holds nothing up" if _interior
				else "STRUCTURE (I)  — what holds the building up",
		_cell, state, recipe.size(), recipe.size() - interior, interior,
		(", %d fixture(s)" % recipe.fixture_count()) if recipe.fixture_count() > 0 else "",
		("\nworst joint %.2f of capacity" % worst) if _overlay_on else ""]


# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		match e.button_index:
			MOUSE_BUTTON_LEFT: _place()
			MOUSE_BUTTON_RIGHT:
				var ray := _mouse_ray()
				_delete_ray(ray[0], ray[1])
			MOUSE_BUTTON_WHEEL_UP: _part_index = (_part_index + 1) % _parts().size()
			MOUSE_BUTTON_WHEEL_DOWN: _part_index = (_part_index - 1 + _parts().size()) % _parts().size()
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.keycode:
		KEY_BRACKETLEFT: _part_index = (_part_index - 1 + _parts().size()) % _parts().size()
		KEY_BRACKETRIGHT: _part_index = (_part_index + 1) % _parts().size()
		KEY_COMMA: _colour = (_colour - 1 + BrickWorld.get_filament_count()) % BrickWorld.get_filament_count()
		KEY_PERIOD: _colour = (_colour + 1) % BrickWorld.get_filament_count()
		KEY_R: _axis_z = not _axis_z
		KEY_F: _flip = not _flip
		KEY_T: _rotate_last()
		KEY_I: _toggle_layer()
		KEY_K: _place_staircase()
		KEY_Z: _undo()
		KEY_V: _snap_on = not _snap_on
		KEY_G: _grid_on = not _grid_on; _grid.visible = _grid_on
		KEY_F1: _keys_on = not _keys_on; _keys_panel.visible = _keys_on
		KEY_H: _overlay_on = not _overlay_on; _stress_dirty = true; _refresh_overlay()
		KEY_F5: _save()
		KEY_F9: _load()
		KEY_ENTER, KEY_KP_ENTER: _place_in_city()


func _place() -> void:
	if not _valid:
		return
	var name := _archetype_name()
	var placed := asm.place(chunk, _cell, palette[name], _colour)
	if placed < 0:
		return
	# A brick put onto a side stud is held by that stud, and a cross-frame join
	# is a weld (Docs/BuildMode.md section 2.4). Made here rather than inferred
	# later, because this is the moment the intent is known.
	var welded_to := -1
	if not _snapped.is_empty():
		asm.weld(_snapped.frame, _snapped.block, chunk, placed)
		welded_to = _recipe_id_at(asm.frames.find(_snapped.frame), _snapped.block)
	# The recipe is the record; the chunk is the preview of it. They are appended
	# in the same order, so recipe index == block id, which is the contract
	# BuildRecipe exists to keep.
	var rid := recipe.size()
	recipe.add(name, _cell, _colour, _recipe_frame_for(_frame), _interior)
	_placed_at.append([_frame, placed])
	# The weld goes in the RECIPE as well, or the build stands here and falls
	# apart everywhere else: a saved file, a city placement and a replay all
	# rebuild from the recipe, and until now the recipe did not know what was
	# holding its sideways frames on. `welded_to` is -1 when the anchor was a
	# baseplate stud, which is not a weld -- the baseplate is not part of what
	# was built.
	if welded_to >= 0:
		recipe.add_weld(welded_to, rid)
	_edits.append("brick")
	_after_edit()


## Which recipe block is this (frame, block) in the world? -1 for anything the
## recipe does not own, which in practice means the baseplate.
func _recipe_id_at(frame_index: int, block: int) -> int:
	if frame_index < 0:
		return -1
	for i in range(_placed_at.size() - 1, -1, -1):
		var at: Array = _placed_at[i]
		if int(at[0]) == frame_index and int(at[1]) == block:
			return i
	return -1


## Drop a spiral staircase where the ghost is.
##
## Docs/BuildMode.md section 9: a fixture is not built out of the parts on the
## palette, it is a sub-assembly with a materialisation state of its own. So
## this does not go through `_place` -- it adds a record to the recipe and a
## preview to the scene, and the CITY is what decides when the bricks exist.
##
## Frame 0 only, and deliberately: a fixture's cell is in the build's own
## upright grid so that it rebases with the build. Authoring one inside a
## sideways frame would need a fixture-per-frame record for a case nothing
## wants yet.
func _place_staircase() -> void:
	if _frame != 0:
		print("[workshop] fixtures are authored in the upright grid (aim at an upright brick)")
		return
	var steps := _steps_above(_cell)
	var at := Vector3i(_cell.x, _cell.y, _cell.z)
	recipe.add_fixture("staircase", at, {"steps": steps, "colour": _colour})
	_spawn_fixture(recipe.fixture_count() - 1)
	_edits.append("fixture")
	print("[workshop] staircase: %d steps at %v" % [steps, at])
	_after_edit()


## How tall a flight has to be to reach the top of what is built above it.
##
## A staircase to nowhere is the usual first draft, so the default is measured
## rather than guessed: from the placement cell to the highest brick in frame 0,
## at two plates a step, and never shorter than one revolution.
func _steps_above(from: Vector3i) -> int:
	var top: int = from.y
	for i in recipe.size():
		if recipe.frame_of(i) != 0:
			continue
		var c := recipe.cell_of(i)
		var size := BrickPalette.size_of(recipe.part_of(i))
		top = maxi(top, c.y + size.y)
	@warning_ignore("integer_division")
	var rise: int = (top - from.y) / StaircaseRecipe.STEP_PLATES
	return maxi(rise, StaircaseRecipe.STEPS_PER_TURN)


## Build the preview for fixture `i`: its own chunk, its own mesh, positioned in
## frame 0's grid.
func _spawn_fixture(i: int) -> void:
	var r := recipe.fixture_at(i)
	if r.is_empty():
		return
	if _fixture_parts.is_empty():
		_fixture_parts = StaircaseRecipe.bake_parts(world)
	# The real thing, through the same class the city builds with: bricks in
	# frame 0, a stairwell carved where they land on what is already there.
	# Nothing is rebased -- the workshop's grid IS the recipe's coordinates.
	var f := Fixture.new()
	f.kind = r.kind
	f.params = r.params
	f.cell = r.cell
	f.role = r.role
	f.build_into(world, asm.frames[0], _fixture_parts)
	_fixture_blocks.append(f.blocks)


## Take fixtures back out of the grid. Used by undo, and by load, which starts
## over from the file.
func _clear_fixtures(keep: int = 0) -> void:
	while _fixture_blocks.size() > keep:
		var ids: PackedInt32Array = _fixture_blocks.pop_back()
		for id in ids:
			world.remove_block(asm.frames[0], id)


## Undo removes the LAST edit, never an arbitrary one -- taking a block out
## of the middle would renumber every block after it and invalidate any damage
## record keyed on those ids.
func _undo() -> bool:
	if not _edits.is_empty() and _edits[_edits.size() - 1] == "fixture":
		if not recipe.pop_fixture():
			return false
		_edits.pop_back()
		_clear_fixtures(recipe.fixture_count())
		_after_edit()
		return true
	if recipe.is_empty() or _placed_at.is_empty():
		return false
	var at: Array = _placed_at[_placed_at.size() - 1]
	# A block that never made it into the world (see _load) has nothing to
	# remove; dropping it from the recipe is the whole of the undo.
	if int(at[0]) >= 0 and not world.remove_block(asm.frames[at[0]], at[1]):
		return false
	_placed_at.remove_at(_placed_at.size() - 1)
	recipe.pop()
	if not _edits.is_empty():
		_edits.pop_back()
	_after_edit()
	return true


## RMB: take out whatever the ray hits first, from anywhere in the build.
##
## Unlike undo this reaches into the middle, which renumbers the recipe blocks
## after it. That is safe HERE and only here: nothing in the workshop is keyed
## on a recipe id except `_placed_at`, which is renumbered in the same step,
## and the world's own block ids are tombstoned rather than reused. A fixture
## goes as a whole -- it is one record, not the bricks it laid. The baseplate
## is not part of the build, so it does not go at all.
func _delete_ray(from: Vector3, dir: Vector3) -> bool:
	var hit := _first_hit(from, dir)
	if hit.is_empty():
		return false
	var rid := _recipe_id_at(asm.frames.find(hit.frame), hit.block)
	if rid >= 0:
		var at: Array = _placed_at[rid]
		if not world.remove_block(asm.frames[at[0]], at[1]):
			return false
		_placed_at.remove_at(rid)
		recipe.remove_at(rid)
		_drop_edit("brick", rid)
		_after_edit()
		return true
	if hit.frame != asm.frames[0]:
		return false
	for k in _fixture_blocks.size():
		var ids: PackedInt32Array = _fixture_blocks[k]
		if not ids.has(hit.block):
			continue
		for id in ids:
			world.remove_block(asm.frames[0], id)
		_fixture_blocks.remove_at(k)
		recipe.remove_fixture(k)
		_drop_edit("fixture", k)
		_after_edit()
		return true
	return false


## Forget the n-th edit of this kind, so undo still takes the others back in
## the order they were made.
func _drop_edit(kind: String, n: int) -> void:
	for i in _edits.size():
		if _edits[i] != kind:
			continue
		if n == 0:
			_edits.remove_at(i)
			return
		n -= 1


func _baseplate_blocks() -> int:
	@warning_ignore("integer_division")
	var n: int = (PLATE_STUDS / 4) * (PLATE_STUDS / 4)
	return n


## Swap which layer the next brick goes in.
##
## The two are not separate scenes, separate grids or separate files. It is one
## build, and the switch is the moment the author stops saying "this is what
## holds it up" and starts saying "this is what is in it" -- which is a fact
## only they have. See `_interior`.
func _toggle_layer() -> void:
	_interior = not _interior
	_update_ghost()
	_update_hud()


## Re-lay the last brick placed, turned 90 degrees.
##
## Undo-and-replace rather than an in-place edit: orientation is baked into the
## archetype (Docs/BuildMode.md section 3), so "the same brick rotated" is a
## different part id and the recipe has to say so. Going through undo keeps
## placement order == block id order, which is the contract everything
## downstream rides on.
func _rotate_last() -> void:
	if recipe.is_empty() or _placed_at.is_empty():
		return
	var id := recipe.size() - 1
	var name := recipe.part_of(id)
	var part := BrickPalette.part_of(name)
	if part == "" or BrickPalette.is_square(part):
		return  # a square part looks the same turned

	var cell := recipe.cell_of(id)
	var colour := recipe.colour_of(id)
	var rf := recipe.frame_of(id)
	var at: Array = _placed_at[_placed_at.size() - 1]
	var af: int = at[0]
	if af < 0:
		return  # it is not in the world to be turned

	var inv := BrickPalette.is_inverted(name)
	var was_x := name.begins_with(part + "_x")
	var turned := part + ("_z" if was_x else "_x") + ("_i" if inv else "")
	if not palette.has(turned):
		return

	if not _edits.is_empty() and _edits[_edits.size() - 1] != "brick":
		return  # the last edit was a fixture; there is no brick to turn
	# The layer travels with the brick, not with the cursor: turning a chair is
	# not a way to make it load-bearing.
	var was_interior := recipe.is_interior(id)
	if not _undo():
		return
	var placed := asm.place(asm.frames[af], cell, palette[turned], colour)
	if placed < 0:
		# It does not fit turned. Put the original back rather than losing it.
		var back := asm.place(asm.frames[af], cell, palette[name], colour)
		if back >= 0:
			recipe.add(name, cell, colour, rf, was_interior)
			_placed_at.append([af, back])
			_edits.append("brick")
		_after_edit()
		return
	recipe.add(turned, cell, colour, rf, was_interior)
	_placed_at.append([af, placed])
	_edits.append("brick")
	_after_edit()


func _asm_frame_index_for_recipe_frame(rf: int) -> int:
	if rf == 0:
		return 0
	for k in _recipe_frames:
		if _recipe_frames[k] == rf:
			return k
	return -1


## The recipe learns about a grid the first time something is built in it.
##
## Lazily, so a build that only ever used the upright grid stays a SINGLE-frame
## recipe and can still be placed in the city -- declaring all six up front
## would make every build multi-frame and none of them placeable.
func _recipe_frame_for(asm_frame: int) -> int:
	if asm_frame == 0:
		return 0
	if _recipe_frames.has(asm_frame):
		return _recipe_frames[asm_frame]
	var f: int = asm.frames[asm_frame]
	var idx := recipe.add_frame(world.get_chunk_rotation(f), world.get_chunk_origin_ticks(f))
	_recipe_frames[asm_frame] = idx
	return idx


func _after_edit() -> void:
	_stress_dirty = true
	_remesh()
	if _overlay_on:
		_refresh_overlay()


## One MeshInstance per frame. A frame has its own grid and its own transform,
## so it cannot share a mesh with another -- that is the whole reason a sideways
## brick is a frame rather than a rotated block.
func _remesh() -> void:
	_stud_count = 0
	for i in asm.frames.size():
		var f: int = asm.frames[i]
		var mi: MeshInstance3D = _frame_meshes.get(f)
		if mi == null:
			mi = MeshInstance3D.new()
			mi.material_override = _material
			add_child(mi)
			_frame_meshes[f] = mi
		mi.transform = world.get_chunk_transform(f)
		var arrays := world.build_chunk_mesh(f)
		var m := ArrayMesh.new()
		if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mi.mesh = m
		_restud(f, mi)


## Studs for one frame: the same instanced stud and the same printed material
## the terrain uses (terrain_tile.gd), so a stud on a brick and a stud on the
## ground are one thing.
##
## The instances come from `BrickWorld.get_chunk_studs`, which already leaves out
## every stud a brick is sitting on -- a covered stud is inside the brick above,
## and drawing it would only z-fight the seam. They are in chunk-local space and
## the MultiMesh is a child of the frame's mesh, so a sideways frame's studs
## point sideways with no extra work.
##
## Rebuilt whole on every edit. The workshop holds hundreds of bricks, the
## buffer is emitted by C++ in the engine's own layout, and one set_buffer is
## cheaper than working out which studs a placement covered.
## Terrain's shared stud material when it exists, so a stud on a brick and a stud
## on the ground are drawn by one thing; a plain vertex-coloured one otherwise.
##
## Looked up by name rather than called directly because the printed-plastic
## stud material and its shader are terrain work that lands on its own schedule.
## A direct call is a PARSE error wherever that work is not present, and a parse
## error takes the whole workshop down with it -- which is what the first commit
## attempt of this found, building from a clean checkout.
static var _studs_fallback: StandardMaterial3D = null

static func _stud_material() -> Material:
	var terrain: Script = load("res://scripts/terrain_tile.gd")
	if terrain != null:
		for m in terrain.get_script_method_list():
			if m.name == "stud_material":
				return terrain.call("stud_material")
	if _studs_fallback == null:
		_studs_fallback = StandardMaterial3D.new()
		_studs_fallback.vertex_color_use_as_albedo = true
		_studs_fallback.roughness = 0.75
	return _studs_fallback


func _restud(frame: int, parent: MeshInstance3D) -> void:
	var mmi: MultiMeshInstance3D = _frame_studs.get(frame)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "Studs"
		mmi.material_override = _stud_material()
		# Studs never cast (Terrain.md 7.4): a 0.07 m shadow for thousands of
		# instances through every cascade, drawn analytically by the shader
		# instead.
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)
		_frame_studs[frame] = mmi
	var buffer: PackedFloat32Array = world.get_chunk_studs(frame)
	buffer.append_array(_side_stud_instances(frame))
	@warning_ignore("integer_division")
	var count := buffer.size() / 16
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.stud()
	mm.instance_count = count
	if count > 0:
		mm.set_buffer(buffer)
	mmi.multimesh = mm
	_stud_count += count


## Brackets' side studs, in the same sixteen-float layout as
## `get_chunk_studs`, in this frame's own space.
##
## The extension draws top and bottom studs only. Without these a bracket looks
## exactly like a plain brick, and a player has no way to see that it is the
## part to build sideways off, or where.
func _side_stud_instances(frame_chunk: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var fi := asm.frames.find(frame_chunk)
	var inv := world.get_chunk_transform(frame_chunk).affine_inverse()
	for at in _placed_at:
		if int(at[0]) != fi or int(at[1]) < 0:
			continue
		var studs := _real_side_studs(frame_chunk, int(at[1]))
		if studs.is_empty():
			continue
		var col := BrickWorld.get_filament_colour(world.get_block_colour(frame_chunk, int(at[1])))
		for st in studs:
			var b := inv.basis * _basis_up(Vector3(st.dir as Vector3i))
			var o: Vector3 = inv * (st.centre as Vector3)
			for v in [b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y,
					b.x.z, b.y.z, b.z.z, o.z, col.r, col.g, col.b, 1.0]:
				out.push_back(v)
	return out


## A rotation taking +Y (the way a stud mesh points) to `n`.
static func _basis_up(n: Vector3) -> Basis:
	if n.is_equal_approx(Vector3.UP):
		return Basis()
	if n.is_equal_approx(Vector3.DOWN):
		return Basis(Vector3.RIGHT, PI)
	return Basis(Quaternion(Vector3.UP, n))


# ---------------------------------------------------------------------------
# "Will it hold" -- an overlay, never a gate. Docs/BuildMode.md section 5.
# ---------------------------------------------------------------------------

## The destruction solver IS the build-mode validator: solve_stress already
## measures tension against the physical constant derived in BrickFailure 4.5,
## and check_stability already asks whether the centre of mass is over the
## footprint. Nothing here computes anything new.
func _refresh_overlay() -> void:
	_overlay.visible = _overlay_on
	if not _overlay_on:
		return
	if _stress_dirty:
		world.solve_grounded(chunk)
		world.solve_stress(chunk)
		_stress.clear()
		for i in range(_baseplate_blocks(), world.get_block_count(chunk)):
			var cap := world.get_block_capacity(chunk, i)
			if cap > 0.0:
				_stress[i] = world.get_block_load(chunk, i) / cap
		_stress_dirty = false

	# Which blocks are worth drawing. Collected first because an ImmediateMesh
	# with no vertices between begin and end is an error, not an empty mesh --
	# and an empty overlay is the NORMAL case: compression is free, so a building
	# that is merely standing loads no joint at all (BrickFailure 4.1). Nothing
	# drawn here means nothing is hanging, not that the overlay is broken.
	var draw := []
	var boxes := world.get_block_boxes(chunk)   # once, not once per block
	for id in _stress:
		var ratio: float = _stress[id]
		if ratio < 0.5:
			continue  # comfortable; drawing it is noise
		if id < boxes.size():
			draw.append([boxes[id], ratio])

	var im := ImmediateMesh.new()
	if draw.is_empty():
		_overlay.mesh = im
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for d in draw:
		var b: Dictionary = d[0]
		var ratio: float = d[1]
		_wire_box(im, b.pos, b.size, Color(1.0, 0.75, 0.2) if ratio < 1.0 else Color(1.0, 0.2, 0.2))
	im.surface_end()
	_overlay.mesh = im


func _wire_box(im: ImmediateMesh, centre: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var c := [
		centre + Vector3(-h.x, -h.y, -h.z), centre + Vector3(h.x, -h.y, -h.z),
		centre + Vector3(h.x, -h.y, h.z), centre + Vector3(-h.x, -h.y, h.z),
		centre + Vector3(-h.x, h.y, -h.z), centre + Vector3(h.x, h.y, -h.z),
		centre + Vector3(h.x, h.y, h.z), centre + Vector3(-h.x, h.y, h.z),
	]
	for pair in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]]:
		im.surface_set_color(col)
		im.surface_add_vertex(c[pair[0]])
		im.surface_set_color(col)
		im.surface_add_vertex(c[pair[1]])


# ---------------------------------------------------------------------------
# The grid overlay
# ---------------------------------------------------------------------------

## The grid is drawn in the ACTIVE grid's space, ON the plane bricks are landing
## on -- not at the grid's origin, which for a sideways grid is the far wall of
## the build volume and tells you nothing.
func _build_grid() -> void:
	if _grid == null:
		return
	var plane_y: float = _cell.y * BrickPalette.PLATE_M
	_grid.transform = world.get_chunk_transform(chunk) \
			* Transform3D(Basis(), Vector3(0.0, plane_y, 0.0))
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var s := BrickPalette.STUD_M
	var span := PLATE_STUDS * s
	# Just above the plane itself, so it does not z-fight with the brick tops.
	var y := 0.002
	for i in PLATE_STUDS + 1:
		# Faint: a rotated grid's plane can sit right across the view, and it is
		# an orientation cue rather than something to read.
		var col := Color(1, 1, 1, 0.13 if i % 4 == 0 else 0.04)
		im.surface_set_color(col); im.surface_add_vertex(Vector3(i * s, y, 0))
		im.surface_set_color(col); im.surface_add_vertex(Vector3(i * s, y, span))
		im.surface_set_color(col); im.surface_add_vertex(Vector3(0, y, i * s))
		im.surface_set_color(col); im.surface_add_vertex(Vector3(span, y, i * s))
	im.surface_end()
	_grid.mesh = im


# ---------------------------------------------------------------------------
# Save, load, and the gate: place it in the city and shoot it
# ---------------------------------------------------------------------------

const SAVE_PATH := "user://workshop_build.json"
## Where F5 and F9 actually go. The gate points it somewhere else so that a
## test run cannot overwrite what somebody built.
var _save_path := SAVE_PATH


func _save() -> void:
	recipe.name = "workshop"
	var err := recipe.save_to(_save_path)
	print("[workshop] saved %d bricks and %d fixture(s) to %s (%s)" % [
			recipe.size(), recipe.fixture_count(), _save_path, error_string(err)])


func _load() -> void:
	var r := BuildRecipe.load_from(_save_path)
	if r.is_empty():
		print("[workshop] nothing to load")
		return
	# Start over: drop every frame, not just the one being built in. A recipe
	# carries no frames yet (Stage 5 work), so a load always lands in one.
	for f in asm.frames:
		world.release_chunk(f)
		var mi: MeshInstance3D = _frame_meshes.get(f)
		if mi != null:
			mi.queue_free()
	_frame_meshes.clear()
	_clear_fixtures()
	_edits.clear()
	asm = Assembly.new(world, palette)
	_build_frames()
	_frame = 0
	_lay_baseplate()
	world.set_foundation_level(chunk, 0)
	recipe = r
	# The six grids already exist, so match the recipe's frames onto them by
	# (rotation, origin) rather than creating more. Cells are absolute in the
	# workshop -- its grids ARE the recipe's coordinate space -- so nothing is
	# rebased either.
	var placed := 0
	for i in recipe.size():
		var rf: int = recipe.frame_of(i)
		var af := _asm_frame_for(recipe.frame_rotation(rf), recipe.frame_ticks(rf))
		if af < 0:
			# A frame this workshop cannot represent -- built somewhere else, or
			# at an offset none of the six standing grids sits at. The BLOCK IS
			# STILL RECORDED, as a hole: _placed_at is indexed by recipe block
			# id, so skipping an entry would shift every id after it and undo
			# would start removing the wrong brick.
			_placed_at.append([-1, -1])
			continue
		var bid := world.place_block(asm.frames[af], recipe.cell_of(i),
				palette[recipe.part_of(i)], recipe.colour_of(i))
		if bid >= 0:
			placed += 1
		_placed_at.append([af, bid])
		_edits.append("brick")
		if rf != 0:
			_recipe_frames[af] = rf
	# Welds last: both ends have to exist before one can hold the other. A weld
	# whose block failed to place is dropped rather than guessed at.
	var welded := 0
	for i in recipe.weld_count():
		var w := recipe.weld_blocks(i)
		if w.x >= _placed_at.size() or w.y >= _placed_at.size():
			continue
		var a: Array = _placed_at[w.x]
		var b: Array = _placed_at[w.y]
		if int(a[1]) < 0 or int(b[1]) < 0:
			continue
		if asm.weld(asm.frames[a[0]], a[1], asm.frames[b[0]], b[1]) >= 0:
			welded += 1
	for i in recipe.fixture_count():
		_spawn_fixture(i)
		_edits.append("fixture")
	print("[workshop] loaded %d of %d bricks across %d frame(s), %d weld(s), %d fixture(s)"
			% [placed, recipe.size(), recipe.frame_count(), welded, recipe.fixture_count()])
	_after_edit()


## Which standing grid matches this (rotation, origin). -1 if none does, which
## means the recipe was built somewhere this workshop cannot represent.
func _asm_frame_for(rotation: int, ticks: Vector3i) -> int:
	for i in asm.frames.size():
		var f: int = asm.frames[i]
		if world.get_chunk_rotation(f) == rotation and world.get_chunk_origin_ticks(f) == ticks:
			return i
	return -1


## The Stage 2 gate, run live: register the build with a BuildingRegistry, blow
## a hole in it, and confirm it breaks like a generated building -- because it
## IS one. Section 8.1: the city places finished recipes, it does not author.
func _place_in_city() -> void:
	if recipe.is_empty():
		print("[workshop] nothing built yet")
		return
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var reg := BuildingRegistry.new(w, pal)
	var id := reg.register_build(recipe, Transform3D())
	if id < 0:
		return
	var c := reg.materialise(id)
	var building := reg.get_building(id)
	var before := 0
	for f in building.chunks():
		before += w.get_alive_block_count(f)
	var b := recipe.bounds()
	var d: Vector3i = b[1]
	@warning_ignore("integer_division")
	var mid := BrickWorld.grid_to_world(Vector3i(d.x / 2, d.y / 2, d.z / 2))
	reg.damage(id, mid, 1.4)
	var after := 0
	for f in building.chunks():
		after += w.get_alive_block_count(f)
	w.solve_grounded(c)
	var groups := w.find_detached_groups(c)
	var loose_frames := 0
	if building.asm != null:
		loose_frames = (building.asm.detached_frames().detached as Array).size()
	var fixtures: int = building.fixtures.size()
	var awake := 0
	for fx in building.fixtures:
		if reg.wake_fixture(id, fx.id) >= 0:
			awake += 1
	print("[workshop] placed in city: %d bricks across %d frame(s), %d weld(s), %d fixture(s) (%d woke); hit removed %d, %d group(s) came loose, %d frame(s) came off"
			% [before, building.chunks().size(),
					building.asm.live_weld_count() if building.asm != null else 0,
					fixtures, awake,
					before - after, groups.size(), loose_frames])
