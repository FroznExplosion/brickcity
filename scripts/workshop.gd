extends Node3D

## Build mode, Stage 2: the workshop. Docs/BuildMode.md section 11.
##
##     godot --path . --resolution 1280x720 res://scenes/workshop.tscn
##
## What it proves is the loop: a part, a ghost, a grid snap, a placement, an
## undo, and a recipe that can be saved and dropped into the city to be shot at.
## Sideways building is Stage 4's frames. A staircase is BUILT here, from the
## palette's spiral stair pieces, like anything else; the prefab staircase `K`
## used to drop in is gone from the keys, and a fixture only arrives in a saved
## recipe that already has one (`_add_fixture`).
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
	["CAMERA", "Y", "swap FPS and orbit camera", "ESC", "pause (cancels a drawing)"],
	["", "orbit", "MMB orbit, shift pan, wheel zoom", "hold RMB", "look round"],
	["", "fps", "hold ALT for the cursor", "", ""],
	["", "WASD", "fly", "SPACE", "up"],
	["", "shift", "fast", "Q / CTRL", "down"],
	["", "alt", "slow", "", ""],
	["BUILD", "LMB", "place on the stud aimed at", "RMB", "delete"],
	["", "hold E", "lock height, slide anywhere", "Z", "undo last"],
	["", "1-9  wheel", "toolbar slot", "TAB", "all parts (creative)"],
	["", "MMB", "pick a placed brick", ", .", "colour of the slot"],
	["", "R", "rotate a quarter turn", "F", "flip (studs down)"],
	["", "T", "rotate the brick just placed", "hold LMB", "move: lay a run"],
	["", "V", "snap to side studs", "B", "paint brush (LMB paints, drag)"],
	["TOOLS", "rail", "on the left (Docs/BuildTools.md)", "K", "shapes of the held brick"],
	["", "N", "cut a door / window / shape", "L", "select a kept shape"],
	["", "J", "repeat: storeys, rows", "alt D", "sketch an outline"],
	["PAINT", "palette", "material + colour (ESC, click)", "- =", "brush size"],
	["", "MMB", "take a brick's material + colour", "PGUP/DN", "material"],
	["GROUP", "X", "select the inserted build aimed at", "M", "move it"],
	["", "C", "copy it", "DEL", "delete it"],
	["ROOM", "U", "room template: guide size", "", ""],
	["", "I", "layer: structure / interior / detail", "", ""],
	["SPACES", "O", "rooms + openings (LMB room/opening)", "K", "room kind (shift: back)"],
	["", "RMB", "forget a room (in O)", "P", "point (shift P: kind)"],
	["VIEW", "G", "grid", "H", "stress overlay"],
	["FILE", "ESC", "free the mouse for the menus", "ctrl N / O", "new / open"],
	["", "ctrl S", "save", "ctrl shift S", "save as"],
	["INSERT", "ctrl I", "a build from the library", "ctrl G", "a generated building"],
	["", "drag handles", "size a generated building", "", ""],
	["", "F5 / F9", "quick save / load", "ENTER", "place in city, shoot it"],
	["", "shift F5", "save as a new build (city: P, wheel)", "", ""],
	["", "F1", "hide these", "", ""],
]


static func _keys_text() -> String:
	var out := PackedStringArray()
	for r in KEY_ROWS:
		out.append("%-7s %-11s %-30s %-10s %s" % r)
	return "\n".join(out)



## The build area: 1000 bricks tall, and as wide as that is in ticks (Docs/BuildTools.md
## section 15).
const BUILD_STUDS := 1200
const BUILD_PLATES := 3000
## What a brick library that cannot page a chunk gets: the big area would be allocated whole.
const SMALL_BUILD_STUDS := 96
const SMALL_BUILD_PLATES := 240
## How wide the view of a new build is: the plate it used to start on.
const START_VIEW_M := 8.4
## How much of the area the grid is drawn over, round the ghost.
const GRID_STUDS := 120
## A grid drawn a section at a time (Docs/BuildTools.md section 16): how big a section is,
## and how far from a changed brick the bricks round it change too (a brick's faces and
## bevels look a couple of cells out).
const SECTION_STUDS := 48
const SECTION_PLATES := 60
const SECTION_MARGIN := 3
## A frame's worth of sections to mesh: one a thread (BrickWorld.build_sections_chamfer_mesh).
## A change that reaches no more is drawn at once.
const SECTIONS_AT_ONCE := 8
## How far studs are drawn. Past it a section's tops are flat; the printed seam stays.
const STUD_RANGE := 40.0

## Build area size in studs, along and across.
## A variable rather than a constant so a scene built on this one can have its own
## before `_ready` (the asset workshop).
var plate_studs := BUILD_STUDS
## Head room over the floor, in plates.
##
## 1200 studs is 6000 ticks and 3000 plates is 6000 ticks, so the build volume is a
## CUBE in tick space. That is not a coincidence worth losing: it means all six
## build grids cover exactly the same region whichever way they are turned, so
## switching grids never moves you somewhere else.
## Kept with `plate_studs` so the build volume stays a cube in tick space.
var height_plates := BUILD_PLATES

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
## chunk id, or Vector2i(chunk id, section) on a grid in sections -> MultiMeshInstance3D,
## child of the mesh
var _frame_studs := {}
var _sections := {}         ## chunk id -> {section -> MeshInstance3D}, children of its mesh
var _frame_boxes := {}      ## chunk id -> AABB of those, in the grid's own space
var _queued := {}           ## Vector2i(chunk, section) -> true: to mesh, nearest first
var _bevelled := {}         ## Vector2i(chunk, section) -> true while it is drawn chamfered
var _tiered_from := Vector3(INF, INF, INF)   ## where the camera was when the tiers were last looked at
var _studs_from := Vector3(INF, INF, INF)    ## and the studs'
var _studs_changed := false
## Draw a big change over frames, and far sections flat (Docs/BuildTools.md section 19). Off
## headless, where a probe asks about the meshes straight after an edit.
var mesh_over_frames := DisplayServer.get_name() != "headless"
var draw_far_flat := DisplayServer.get_name() != "headless"
var _stud_count := 0        ## studs drawn, all frames, after the last remesh
var _ghost: MeshInstance3D
var _ghost_studs: MultiMeshInstance3D   ## child of _ghost
## archetype id -> [ArrayMesh, MultiMesh]: the held part's real shape and studs.
var _ghost_shapes := {}
var _grid: MeshInstance3D
var _grid_drawn := Rect2i()   ## the studs it was last drawn over: grid_window()
var _floor: MeshInstance3D
var _overlay: MeshInstance3D
var _camera: Camera3D
var _hud: Label
## The spaces tool (O): rooms, openings and points (WorkshopSpaces;
## Docs/Structures.md 3.2).
var _spaces: WorkshopSpaces
## Furniture and items placed from the catalogue (F6; Docs/AssetWorkshop.md).
var _furnish: FurnishTool
## The rail and the building tools (Docs/BuildTools.md); null where a workshop has its own.
var _tools: WorkshopTools
var _hud_layer: CanvasLayer
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
##
## Three layers now (Docs/Workshop.md, Stage D): STRUCTURE, INTERIOR, and
## DETAIL -- interior the city only lays with somebody in the room.
var _role: int = BuildRecipe.Role.STRUCTURE
var _interior: bool:
	get:
		return _role != BuildRecipe.Role.STRUCTURE
var _part_index := 0
var _colour := 4
## What the next brick is made of: an index into BrickWorld's materials. The
## colour is read through it (a filament palette entry, or a wood or metal).
var _mat := 0
## The toolbar and parts browser (scripts/workshop_hotbar.gd). It sets
## `_part_index` and `_colour` when its selection changes; nothing reads it back,
## so a probe or the stair builder setting them directly is unaffected.
var _hotbar: WorkshopHotbar
## archetype id -> an archetype name for it, for pick-block. Filled on first use.
var _arch_names := {}

## The paint brush (B). While it is on, LMB repaints placed bricks in the
## selected slot's colour instead of placing one -- held and dragged, every
## brick the dot passes over -- and the ghost becomes a box over the brick
## that would be painted. A colour is only a vertex attribute and not part of a
## brick's identity, so nothing is removed or renumbered.
var _painting := false
## The brush is the kit's Paint tool (WkPaintTool, addons/workshop_kit): it takes the strokes,
## the eyedropper, - = and Page Up/Down, and asks the workshop through its context
## (`wk_paint_begin` ... below). Docs/BuildTools.md section 20.
var _paint_tool := WkPaintTool.new()
## Studs round the dot the brush reaches: 0 is the one brick under it, more
## is every brick of the build within that distance -- a wall in one pass. The tool's.
var _paint_radius: int:
	get: return _paint_tool.radius
	set(v): _paint_tool.radius = v
const PAINT_RADIUS_MAX := 12
## What the brush lays, picked in one place (scripts/paint_palette.gd): the
## selected slot's material and colour, which is what the brush has always
## painted with -- the palette is a nearer way to change them.
const PaintPalette := preload("res://scripts/paint_palette.gd")
var _paint_palette = null
## The stroke under way, as [recipe id, colour it had] per brick, or null.
var _stroke = null
## Quarter turns about +Y, 0..3. A brick only has two distinct orientations and
## reads this mod 2; a slope has a front, and all four are different parts.
var _yaw := 1
## The old two-way switch, kept as a view of `_yaw`: true is the long side on Z.
var _axis_z: bool:
	get:
		return _yaw % 2 == 0
	set(v):
		_yaw = 0 if v else 1
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
## Where a newel-bearing part must go to stand on the newel aimed at (x and z
## only), or NO_STUD. See `_newel_target`.
var _newel_at := NO_STUD
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
## What `_placed_at` says the other way: (grid << 32 | block) -> recipe id. Good for the first
## `_rid_synced` of it: an append needs nothing, a removal lowers the mark, a look-up catches up.
var _rid_map := {}
var _rid_synced := 0
## Every edit, newest last: one history for the workshop, its tools and the asset workshop
## (WkUndoStack, addons/workshop_kit; Docs/BuildTools.md section 20). A hand-laid brick is a
## "brick" command holding its recipe id; a fixture, a paint stroke, an inserted build, a
## generated building's change, a lifted group, a shape edit and a furniture edit are one
## command each. Recipe ids it holds are moved down whenever bricks leave from the middle
## (`_forget_rids`).
var undo_stack := WkUndoStack.new()
## The kit's tools taken up and put down here (WkToolbox), and the seam they ask through
## (BrickWorkshopContext). Docs/BuildTools.md section 20.
var toolbox := WkToolbox.new()
var wk_ctx: BrickWorkshopContext
## The bricks and fixtures the build was opened with that undo has not taken back yet: they
## have no command each (on a big build that is seconds and megabytes), `_undo_opened` takes
## them back once the history runs out, newest first, as Z always could.
var _opened_bricks := 0
var _opened_fixtures := 0
## The mirror (Docs/BuildTools.md section 7; moved down from the asset workshop): while on,
## a brick placed is placed again across the plane -- across Z at `mirror_z` studs, or with
## `mirror_axis` 0 across X at `mirror_x`.
var mirror_on := false
var mirror_z := 0.0
var mirror_x := 0.0
var mirror_axis := 2
## Lock height as a button: the plane stays as with E held, until it is pressed again.
var plane_locked := false
var _run_from := 0
## Holding LMB lays a run (Docs/BuildTools.md): the cell last laid, or NO_STUD between runs.
var _run_last := NO_STUD
var _run_on := false
## A held click lays a run only after the mouse has moved this far, this long after.
const RUN_START_PX := 14.0
const RUN_START_MS := 150
var _run_moved := 0.0
var _run_press_ms := 0
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

var _material: Material
var _ghost_material: StandardMaterial3D


func _init() -> void:
	if not ClassDB.class_has_method("BrickWorld", "paged_chunk_cells"):
		push_warning("[workshop] this brick library cannot page a chunk: build area %d studs, not %d (rebuild the extension)"
				% [SMALL_BUILD_STUDS, BUILD_STUDS])
		plate_studs = SMALL_BUILD_STUDS
		height_plates = SMALL_BUILD_PLATES


func _ready() -> void:
	wk_ctx = BrickWorkshopContext.new(self)
	toolbox.ctx = wk_ctx
	_paint_tool.radius_max = PAINT_RADIUS_MAX
	toolbox.add(_paint_tool)
	world = BrickWorld.new()
	world.set_seed(1)
	# The generator's palette: the player's parts plus the cornice a generated
	# building is finished with (Docs/Workshop.md, Stage C). Same ids for every
	# part the player has, because the extra one is baked last.
	palette = TowerRecipe.bake_palette(world)

	asm = Assembly.new(world, palette)
	_build_frames()
	_lay_baseplate()
	@warning_ignore("integer_division")
	_cell = Vector3i(plate_studs / 2, 1, plate_studs / 2)

	# The city's brick shader, not a plain material: seams, printed layers and
	# the MATERIALS (wood, metal, TPU ...) all live there, and a workshop that
	# drew bricks some other way would show a build the city never does.
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/brick.gdshader")
	_material = BrickMaterials.add_glass(sm)

	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.albedo_color = Color(0.4, 0.9, 1.0, 0.45)
	_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_ghost = MeshInstance3D.new()
	_ghost.material_override = _ghost_material
	add_child(_ghost)
	_ghost_studs = MultiMeshInstance3D.new()
	_ghost_studs.material_override = _ghost_material
	_ghost_studs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.add_child(_ghost_studs)

	_grid = MeshInstance3D.new()
	add_child(_grid)
	_build_grid()

	_overlay = MeshInstance3D.new()
	add_child(_overlay)

	_build_lights()
	_build_camera()
	_build_hud()
	if _wants_tools():
		_tools = WorkshopTools.new()
		_tools.name = "Tools"
		add_child(_tools)
		_tools.setup(self, _hud_layer)
	_spaces = WorkshopSpaces.new()
	add_child(_spaces)
	# The build's doors, lifts and ladders, as the city has them (BuildDoors,
	# BuildLifts, BuildLadders).
	var this_build := func() -> Array:
		if asm == null or asm.frames.is_empty():
			return []
		return [[0, asm.frames[0], recipe, Vector3i.ZERO]]
	add_child(BuildDoors.new(world, this_build))
	add_child(BuildLifts.new(world, this_build))
	add_child(BuildLadders.new(world, this_build))
	_spaces.setup(self)
	_furnish = FurnishTool.new()
	_furnish.name = "Furnish"
	add_child(_furnish)
	_furnish.setup(self)
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


## A staircase built from spiral pieces, driven through the same calls the
## mouse makes; then a fixture as an older saved recipe carries one.
##
## The recipe half of this is `tools/build_probe.gd`; what needs the scene is
## the aiming, the preview, the undo stack shared with bricks, and the reload.
func _run_gate() -> void:
	print("[workshop] a staircase, built here; fixtures, as saves carry them")
	_save_path = "user://_workshop_gate.json"

	# Two courses of a wall, through the real placement path. The part is named
	# rather than whatever happens to be in hand: the toolbar remembers what the
	# player last held, and a 2x4 laid every two studs overlaps half of itself.
	_part_index = BrickPalette.parts().find("brick_2x2")
	_yaw = 0
	_flip = false
	var placed := 0
	for course in 2:
		for x in range(0, 8, 2):
			_cell = Vector3i(x, 1 + course * 3, 0)
			_valid = true
			_snapped = {}
			_place()
			placed += 1
	_gate_ok("bricks go in", recipe.size() == placed, "%d of %d" % [recipe.size(), placed])

	# A staircase, built: one spiral piece on the floor, then seven more, each
	# placed by aiming straight down at a stud of the newel below -- a
	# different one of its four each time. Every piece should land with its
	# newel on that newel, turned to carry the flight on.
	var part := "spiralcw_10x10"
	var base := Vector3i(12, 1, 12)
	_part_index = BrickPalette.parts().find(part)
	_yaw = 0
	_flip = false
	_frame = 0
	chunk = asm.frames[0]
	_cell = base
	_valid = true
	_snapped = {}
	_place()
	var newel := BrickPalette.newel_of(BrickPalette.variant_name(part, 0, false))
	var lined_up := true
	var turned := true
	var h := BrickPalette.part_size(part).y
	for k in range(1, 8):
		@warning_ignore("integer_division")
		var col := Vector2i(newel.position.x + k % 2, newel.position.y + (k / 2) % 2)
		var above := Vector3((base.x + col.x + 0.5) * 0.35, 20.0, (base.z + col.y + 0.5) * 0.35)
		_aim_ray(above, Vector3(0, -1, 0))
		_update_ghost()
		lined_up = lined_up and _cell == base + Vector3i(0, k * h, 0)
		turned = turned and _archetype_name() == BrickPalette.variant_name(part, k, false)
		_place()
	var pieces := recipe.size() - placed
	_gate_ok("eight spiral pieces go in", pieces == 8, "%d" % pieces)
	_gate_ok("each one's newel on the newel below, whichever stud was aimed at", lined_up)
	_gate_ok("each one turned to carry the flight on", turned)
	var stair_top := recipe.size()

	# A fixture, as an older save carries one.
	_cell = Vector3i(30, 1, 30)
	_add_fixture("staircase", _cell, {"steps": StaircaseRecipe.STEPS_PER_TURN, "colour": _colour})
	_gate_ok("a fixture in a recipe still builds", recipe.fixture_count() == 1)
	var laid: PackedInt32Array = _fixture_blocks[0]
	_gate_ok("as bricks in the build's own grid", laid.size() > 0, "%d blocks" % laid.size())
	# The newel, not the corner of the bounding box: a wedge does not fill its
	# own box, which is the whole reason it is a masked part.
	@warning_ignore("integer_division")
	var mid := Vector3i(30 + StaircaseRecipe.DIAMETER / 2, 1,
			30 + StaircaseRecipe.DIAMETER / 2)
	_gate_ok("standing where it says",
			world.block_at(chunk, mid) == int(laid[0]),
			"block %d at %v, %d laid first" % [world.block_at(chunk, mid), mid, int(laid[0])])
	_gate_ok("and the bricks are untouched by it", recipe.size() == stair_top)

	# Undo is one stack, bricks and fixtures together.
	_undo()
	_gate_ok("undo takes the fixture back", recipe.fixture_count() == 0)
	_gate_ok("and its bricks with it", _fixture_blocks.is_empty()
			and world.block_at(chunk, mid) < 0)
	_gate_ok("without touching the bricks", recipe.size() == stair_top)
	_undo()
	_gate_ok("the next undo is a brick again", recipe.size() == stair_top - 1)

	# Save, then load, which starts over from the file.
	_add_fixture("staircase", Vector3i(30, 1, 30),
			{"steps": StaircaseRecipe.STEPS_PER_TURN, "colour": _colour})
	_save()
	var bricks := recipe.size()
	var fixtures := recipe.fixture_count()
	_load()
	_gate_ok("a reload brings the bricks back", recipe.size() == bricks,
			"%d of %d" % [recipe.size(), bricks])
	_gate_ok("and the fixtures", recipe.fixture_count() == fixtures)
	_gate_ok("with the bricks laid again for each one",
			_fixture_blocks.size() == fixtures)
	_gate_ok("and undo can take both back",
			_opened_bricks + _opened_fixtures == bricks + fixtures and undo_stack.size() == 0,
			"%d + %d, %d steps" % [_opened_bricks, _opened_fixtures, undo_stack.size()])

	# A picture of it, because "the pieces went in" and "it is a staircase"
	# are different claims.
	var look := Vector3(17.0 * 0.35, 0.0, 17.0 * 0.35)
	_camera.global_position = look + Vector3(-6.0, 4.5, -6.0)
	_camera.look_at(look + Vector3(0.0, 1.5, 0.0), Vector3.UP)
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://shots/workshop_stair.png")
	print("[workshop] shot written: workshop_stair.png")
	await RenderingServer.frame_post_draw
	await _gate_wood()

	# And the whole thing still goes into a city.
	_place_in_city()
	_gate_ok("it still places in the city", true)

	print("\n%d passed, %d failed" % [_gate_pass, _gate_fail])
	get_tree().quit(1 if _gate_fail > 0 else 0)


## Wood, placed as the player places it: two boards stacked and one turned,
## drawn with their grain axis in the mesh (Docs/PbrWood.md), and a close
## picture of the grain running round their edges and from board to board.
func _gate_wood() -> void:
	var wood := -1
	for m in BrickWorld.get_material_count():
		if BrickWorld.get_material_name(m) == "Wood":
			wood = m
	var was := _mat
	_mat = wood
	_part_index = BrickPalette.parts().find("brick_2x4")
	_flip = false
	_frame = 0
	chunk = asm.frames[0]
	for at in [[Vector3i(20, 1, 4), 0], [Vector3i(20, 4, 4), 0], [Vector3i(26, 1, 2), 1]]:
		_cell = at[0]
		_yaw = at[1]
		_valid = true
		_snapped = {}
		_place()
	_mat = was
	_remesh()
	var nodes: Array = _sections.get(asm.frames[0], {}).values()
	if nodes.is_empty():
		nodes = [_frame_meshes.get(asm.frames[0])]
	var axes := {}
	for mi: MeshInstance3D in nodes:
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		for c in mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]:
			var code := roundi((1.0 - (c as Color).a) * 255.0)
			if code & 31 == wood:
				axes[(code >> 5) & 3] = true
	_gate_ok("wood bricks carry their grain: along X and, turned, along Z",
			wood >= 0 and axes.has(0) and axes.has(1), "material %d, axes %s" % [wood, axes.keys()])
	_gate_ok("and the frame knows where it lies on the grid",
			nodes[0] != null and nodes[0].get_instance_shader_parameter("grain_origin") != null)
	var look := Vector3(22.0 * 0.35, 0.6, 5.0 * 0.35)
	_camera.global_position = look + Vector3(-1.6, 1.3, -2.0)
	_camera.look_at(look, Vector3.UP)
	for i in 4:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://shots/workshop_wood.png")
	print("[workshop] shot written: workshop_wood.png")


## Create every build grid up front, all covering the same volume.
##
## The first version created a sideways frame on demand, at an offset derived
## from wherever the cursor happened to be in the PREVIOUS grid -- so the new
## grid landed somewhere unrelated and bricks appeared nowhere near the cursor.
## Six co-located grids removes the whole class of problem: switching grid
## changes the orientation you build in and nothing else.
func _build_frames() -> void:
	var dims := Vector3i(plate_studs, height_plates, plate_studs)
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
func _origin_for(rot: int, dims: Vector3i) -> Vector3i:
	var probe := world.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))
	world.set_chunk_frame(probe, rot, Vector3i.ZERO)
	var b: Basis = world.get_chunk_transform(probe).basis
	world.release_chunk(probe)

	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var far: Vector3 = b * Vector3(dims.x * t, dims.y * pt, dims.z * t)
	return Vector3i(
		int(round(-minf(0.0, far.x))),
		int(round(-minf(0.0, far.y))),
		int(round(-minf(0.0, far.z))))


## The floor: one plate thick, the whole area, and not bricks (Docs/BuildTools.md section
## 15). The bottom course is the foundation, which keeps "is it grounded" a real question.
func _lay_baseplate() -> void:
	world.set_foundation_level(chunk, 1)
	if _floor != null:
		return
	_floor = MeshInstance3D.new()
	_floor.name = "Floor"
	var area := plate_studs * BrickPalette.STUD_M
	var quad := PlaneMesh.new()
	quad.size = Vector2(area, area)
	_floor.mesh = quad
	_floor.position = Vector3(area * 0.5, BrickPalette.PLATE_M, area * 0.5)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/workshop_floor.gdshader")
	_floor.material_override = mat
	_floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_floor)


## Whether a brick here would sit on the floor. It clips to that as to a plate.
func _on_floor(cell: Vector3i) -> bool:
	return chunk == asm.frames[0] and cell.y == 1


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
	# Something to REFLECT, behind the plain background. A metal brick is lit
	# almost entirely by what it mirrors, and with nothing but a flat colour
	# around it every steel and brass brick came out black. The city has a
	# procedural sky for the same job.
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.48, 0.62)
	sky_mat.sky_horizon_color = Color(0.72, 0.76, 0.80)
	sky_mat.ground_horizon_color = Color(0.55, 0.55, 0.56)
	sky_mat.ground_bottom_color = Color(0.25, 0.25, 0.27)
	sky.sky_material = sky_mat
	e.sky = sky
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.environment = e
	add_child(env)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.set_script(load("res://scripts/debug_camera.gd"))
	_camera.far = 2500.0
	_camera.set("e_climbs", false)   # E is the plane lock here; SPACE still climbs
	add_child(_camera)
	_look_at(area_middle(), START_VIEW_M)


## The floor at the middle of the area, in metres.
func area_middle() -> Vector3:
	var mid := plate_studs * BrickPalette.STUD_M * 0.5
	return Vector3(mid, 0.0, mid)


## Stand back from this point, from the same side whatever the size.
func _look_at(centre: Vector3, radius: float) -> void:
	_camera.position = centre + Vector3(-radius * 0.9, radius * 0.75, radius * 1.35)
	# look_at needs the node in the tree, and the debug camera reads its own
	# rotation on the first frame, so set it before anything else runs.
	_camera.look_at(centre + Vector3(0.0, radius * 0.25, 0.0), Vector3.UP)


## The view of what is built, wherever in the area it is; of the middle when nothing is.
func frame_build() -> void:
	if _camera == null:
		return
	if not recipe.has_content():
		_look_at(area_middle(), START_VIEW_M)
		return
	var b := recipe.bounds()
	var lo: Vector3 = BrickWorld.grid_to_world(b[0])
	var size: Vector3 = BrickWorld.grid_to_world(b[1])
	var mid := lo + size * 0.5
	_look_at(Vector3(mid.x, lo.y, mid.z), maxf(size.length() * 0.6, START_VIEW_M))


## The building tools' rail: the building workshop's. A workshop built on this one with a
## rail of its own (the asset workshop) says no.
func _wants_tools() -> bool:
	return true


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud_layer = layer

	_hotbar = WorkshopHotbar.new()
	_hotbar.name = "Hotbar"
	# The icons are the ghost's own meshes, so an icon is the piece that lands.
	_hotbar.mesh_for = func(p: String) -> Array:
		return _ghost_shape(palette[BrickPalette.variant_name(p, 1, false)])
	_hotbar.changed.connect(_on_hotbar)
	_hotbar.browsing_changed.connect(func(on: bool) -> void:
		if _tools == null and _camera.has_method("_set_captured"):
			_camera.call("_set_captured", not on))
	add_child(_hotbar)

	_paint_palette = PaintPalette.new()
	_paint_palette.name = "PaintPalette"
	_paint_palette.visible = false
	layer.add_child(_paint_palette)
	_paint_palette.position = Vector2(12, 150)
	_paint_palette.setup(_paint_materials(), _paint_colours, _mat, _colour)
	_paint_palette.picked.connect(func(m: int, c: int) -> void:
		if m != _mat:
			_hotbar.set_material(m)
		_hotbar.set_colour(c))
	_paint_palette.info = _paint_info()

	_menu = WorkshopMenu.new()
	_menu.name = "Menu"
	_menu.action.connect(_on_menu)
	layer.add_child(_menu)

	_hud = Label.new()
	_hud.position = Vector2(12, 40)
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
	# A label, not a control: let the mouse through. A panel stops it by
	# default, and one over the middle of the window ate mouse-look.
	_keys_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
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


## The toolbar's selection became the part and colour in hand.
func _on_hotbar(part: String, colour: int, material: int) -> void:
	if part == "":
		return
	var i := _parts().find(part)
	if i >= 0:
		_part_index = i
	_colour = colour
	_mat = material
	if _paint_palette != null:
		_paint_palette.show_pick(_mat, _colour)


## Every brick material, for the paint palette.
func _paint_materials() -> Array:
	var out: Array = []
	for m in BrickWorld.get_material_count():
		out.append({"value": m, "name": BrickWorld.get_material_name(m)})
	return out


## A material's colours -- every filament, or its own kinds -- named as the
## toolbar names them.
func _paint_colours(m: int) -> Array:
	var out: Array = []
	for c in BrickWorld.get_material_colour_count(m):
		out.append({"value": c, "name": BrickWorld.get_material_colour_name(m, c),
				"color": WorkshopHotbar.rgb(m, c)})
	return out


func _paint_info() -> String:
	return "brush: %s   (- = size)   MMB takes a brick's paint" % (
			"one brick" if _paint_radius == 0 else "%d studs round the dot" % _paint_radius)


## Middle click: the brick under the cursor, its part, turn and colour, into
## the selected slot -- Minecraft's pick-block.
func _pick_block() -> void:
	var ray := _mouse_ray()
	if _painting:
		_pick_paint_ray(ray[0], ray[1])
		return
	_pick_ray(ray[0], ray[1])


## The eyedropper: a brick's material and colour into the brush, and nothing
## else -- the part in hand stays the part in hand.
func _pick_paint_ray(from: Vector3, dir: Vector3) -> void:
	var hit := _first_hit(from, dir)
	if hit.is_empty() or hit.block < 0:
		return
	_hotbar.set_material(world.get_block_material(hit.frame, hit.block))
	_hotbar.set_colour(world.get_block_colour(hit.frame, hit.block))


## The same for any ray, so a probe can aim it exactly.
func _pick_ray(from: Vector3, dir: Vector3) -> void:
	var hit := _first_hit(from, dir)
	if hit.is_empty() or hit.block < 0:
		return
	var arch: int = world.get_block_archetype(hit.frame, hit.block)
	if _arch_names.is_empty():
		for n in palette:
			if BrickPalette.part_of(n) != "" and not _arch_names.has(palette[n]):
				_arch_names[palette[n]] = n
	var arch_name: String = _arch_names.get(arch, "")
	var part := BrickPalette.part_of(arch_name)
	if part == "":
		return
	var o := BrickPalette.orientation_of(arch_name)
	_yaw = o.x
	_flip = o.y != 0
	_hotbar.set_slot(part, world.get_block_colour(hit.frame, hit.block),
			world.get_block_material(hit.frame, hit.block))


func _set_painting(on: bool) -> void:
	_painting = on
	if _paint_palette != null:
		_paint_palette.visible = on
		_paint_palette.show_pick(_mat, _colour)
	if on:
		toolbox.use(&"paint")
	elif toolbox.active_id() == &"paint":
		toolbox.use(&"")
	_end_stroke()
	_ghost_studs.visible = not on
	_ghost.visible = true


## Paint mode, each frame: the ghost boxes the brick under the dot (or, with a reach, a
## ball round it). A held LMB painting on is the tool's (WkPaintTool.process).
func _paint_hover() -> void:
	var ray := _mouse_ray()
	var hit := _first_hit(ray[0], ray[1])
	_ghost.visible = not hit.is_empty()
	if hit.is_empty():
		return
	var box: Array = world.get_block_ticks(hit.frame, hit.block)
	if box.is_empty():
		return
	var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	var size := Vector3(box[1] as Vector3i) * tick
	if _paint_radius > 0:
		# The brush's reach, as a ball round the dot.
		var ball := SphereMesh.new()
		var r := float(_paint_radius) * BrickPalette.STUD_M
		ball.radius = r
		ball.height = r * 2.0
		_ghost.mesh = ball
		_ghost.transform = Transform3D(Basis(), hit.point)
	else:
		var mesh := BoxMesh.new()
		mesh.size = size + Vector3.ONE * 0.02
		_ghost.mesh = mesh
		_ghost.transform = Transform3D(Basis(), Vector3(box[0] as Vector3i) * tick + size * 0.5)
	var c := BrickWorld.get_filament_colour(_colour)
	_ghost_material.albedo_color = Color(c.r, c.g, c.b, 0.55)


# The kit's Paint tool asks these, through the workshop's context (BrickWorkshopContext).

func wk_paint_begin() -> void:
	_stroke = []


func wk_paint_at(_radius: int) -> bool:
	var ray := _mouse_ray()
	return _paint_ray(ray[0], ray[1])


func wk_paint_end() -> void:
	_end_stroke()


func wk_paint_hover(_radius: int) -> void:
	_paint_hover()


func wk_paint_pick() -> void:
	var ray := _mouse_ray()
	_pick_paint_ray(ray[0], ray[1])


func wk_paint_step(step: int) -> void:
	if _paint_palette != null:
		_paint_palette.step_material(step)


func wk_paint_radius_changed(_radius: int) -> void:
	if _paint_palette != null:
		_paint_palette.info = _paint_info()


func _begin_stroke() -> void:
	_stroke = []
	var ray := _mouse_ray()
	_paint_ray(ray[0], ray[1])


## Paint the brick this ray hits first, into the stroke under way. Only bricks
## the recipe owns: the baseplate is scenery and a fixture is one record, not
## its bricks. Public-ish for the probe. Returns whether a brick changed.
func _paint_ray(from: Vector3, dir: Vector3) -> bool:
	if _stroke == null:
		return false
	var hit := _first_hit(from, dir)
	if hit.is_empty():
		return false
	var rid := _recipe_id_at(asm.frames.find(hit.frame), hit.block)
	var targets: Array[int] = []
	if _paint_radius <= 0:
		targets.append(rid)
	else:
		targets = _bricks_near(hit.point, float(_paint_radius) * BrickPalette.STUD_M)
	var changed := false
	for r in targets:
		changed = _paint_one(r) or changed
	if changed:
		_remesh()
	return changed


## One brick into the stroke, if it is the build's and not this paint already.
func _paint_one(rid: int) -> bool:
	if rid < 0 or (recipe.colour_of(rid) == _colour and recipe.material_of(rid) == _mat):
		return false
	for e in _stroke:
		if int(e[0]) == rid:
			return false
	_stroke.append([rid, recipe.colour_of(rid), recipe.material_of(rid)])
	_repaint(rid, _colour, _mat)
	return true


## The build's bricks within `reach` metres of a point, measured to each
## brick's box -- so a wide brick is painted when any part of it is in reach.
func _bricks_near(point: Vector3, reach: float) -> Array[int]:
	var out: Array[int] = []
	var tick := BrickPalette.STUD_M / BrickWorld.ticks_per_stud()
	for rid in _placed_at.size():
		var at: Array = _placed_at[rid]
		if int(at[0]) < 0:
			continue
		var box: Array = world.get_block_ticks(asm.frames[at[0]], at[1])
		if box.is_empty():
			continue
		var lo := Vector3(box[0] as Vector3i) * tick
		var hi := lo + Vector3(box[1] as Vector3i) * tick
		var q := Vector3(clampf(point.x, lo.x, hi.x), clampf(point.y, lo.y, hi.y),
				clampf(point.z, lo.z, hi.z))
		if q.distance_to(point) <= reach:
			out.append(rid)
	return out


func _end_stroke() -> void:
	if _stroke != null and not _stroke.is_empty():
		undo_stack.push(WkCommand.make(&"paint", _stroke, _unpaint))
	_stroke = null


## Undo of a paint stroke: each brick back to the colour it had, newest first. A brick
## deleted since is -1 and is skipped.
func _unpaint(c: WkCommand) -> bool:
	var stroke: Array = c.data
	for i in range(stroke.size() - 1, -1, -1):
		_repaint(int(stroke[i][0]), int(stroke[i][1]), int(stroke[i][2]))
	_after_edit()
	return true


## One brick, in the world and in the recipe together.
func _repaint(rid: int, colour: int, material: int) -> void:
	if rid < 0 or rid >= _placed_at.size():
		return
	var at: Array = _placed_at[rid]
	if int(at[0]) >= 0:
		world.set_block_material(asm.frames[at[0]], at[1], material)
		world.set_block_colour(asm.frames[at[0]], at[1], colour)
	recipe.set_material(rid, material)
	recipe.set_colour(rid, colour)


## Esc opens the pause menu here, as in the city (MenuHost asks) -- never over a scripted
## pass or a test window.
func pause_allowed() -> bool:
	return _tools != null and not PlayerCamera.hands_off and not ("--gate" in OS.get_cmdline_user_args())


func _place_keys() -> void:
	if _keys_panel == null:
		return
	var h: float = get_viewport().get_visible_rect().size.y
	# Top right: the toolbar owns the bottom of the screen now.
	var w: float = get_viewport().get_visible_rect().size.x
	var top := 12.0 + (_menu.bar_height() if _menu != null else 0.0)
	if _tools != null:
		top += _tools.bar_height()
	_keys_panel.position = Vector2(w - _keys_panel.size.x - 12, top)


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
## What the HUD says the ghost is facing: the axis its long side runs along, or
## for a part with a front, the way that front looks.
func _facing() -> String:
	var front := BrickPalette.front_of(_archetype_name())
	if front != Vector3i.ZERO:
		return "front %s%s" % ["+" if front.x + front.z > 0 else "-", "X" if front.x != 0 else "Z"]
	if BrickPalette.is_square(_part()):
		return "-"
	return "Z" if _axis_z else "X"


func _archetype_name() -> String:
	return BrickPalette.variant_name(_part(), _yaw, _flip)


func _archetype() -> int:
	return palette[_archetype_name()]


# ---------------------------------------------------------------------------
# The placement loop. Docs/BuildMode.md section 4.
# ---------------------------------------------------------------------------

func _process(_dt: float) -> void:
	_dot.visible = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	_stud_lod()
	_section_process()
	if not _drag.is_empty():
		_drag_process()
	_place_handles()
	if _spaces != null:
		_spaces.process()
	if _furnish != null and _furnish.is_open():
		_ghost.visible = false
		_furnish.process()
	elif _stamp != null:
		_ghost.visible = false
		_stamp_process()
	elif _spaces != null and _spaces.active:
		_ghost.visible = false
	elif _painting:
		toolbox.process(_dt)
	else:
		_ghost.visible = true
		_aim()
		_update_ghost()
		if _run_on and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_end_run()
		run_step()
	_update_hud()
	if _tools != null:
		_tools.process()
	# A PanelContainer does not know its height until it has laid out, so the
	# first placement lands short. Cheap to keep pinned rather than to guess.
	if _keys_panel != null and _keys_panel.visible:
		_place_keys()
	# The grid follows the plane the ghost is on.
	if _grid_on and (_cell.y != _grid_plane or chunk != _grid_frame or grid_window() != _grid_drawn):
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
	_hold_lock(Input.is_key_pressed(KEY_E) or plane_locked)
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
	# While a run is held, the ghost stays on the plane it started on, as with E.
	on = on or _run_on or (_tools != null and _tools.dragging())
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
##
## Only where a grid holds bricks: the whole area at this step would be a hundred thousand
## cells for every ray.
func _first_hit(from: Vector3, dir: Vector3) -> Dictionary:
	var step := BrickPalette.PLATE_M * 0.34
	var spans := []
	var t := INF
	var end := 0.0
	for f in asm.frames:
		var box := _frame_box(f)
		if not box.has_volume():
			continue
		var s := _ray_through(from, dir, (world.get_chunk_transform(f) * box).grow(0.2))
		if s.x <= s.y:
			spans.append([f, s.x, s.y])
			t = minf(t, s.x)
			end = maxf(end, s.y)
	var to_floor := _floor_t(from, dir)
	while t <= end and t < to_floor:
		var p := from + dir * t
		for s in spans:
			if t < s[1] or t > s[2]:
				continue
			var f: int = s[0]
			var bid := world.block_at(f, _cell_in(f, p))
			if bid >= 0 and world.is_solid(f, _cell_in(f, p)):
				return {"t": t, "frame": f, "block": bid, "point": p}
		t += step
	if to_floor < INF:
		return {"t": to_floor, "frame": asm.frames[0], "block": -1, "floor": true,
				"point": from + dir * to_floor}
	return {}


## What a grid's bricks fill, in its own space.
func _frame_box(f: int) -> AABB:
	if _frame_boxes.has(f):
		return _frame_boxes[f]
	var mi: MeshInstance3D = _frame_meshes.get(f)
	return mi.mesh.get_aabb() if mi != null and mi.mesh != null else AABB()


## How far along a ray the floor is, INF if it misses. Just inside it: a hit's point is in
## the course under the bricks, as it was in a plate.
func _floor_t(from: Vector3, dir: Vector3) -> float:
	if _floor == null or dir.y >= 0.0 or from.y <= BrickPalette.PLATE_M:
		return INF
	var t := (BrickPalette.PLATE_M - 0.001 - from.y) / dir.y
	var p := from + dir * t
	var area := plate_studs * BrickPalette.STUD_M
	return t if p.x >= 0.0 and p.z >= 0.0 and p.x < area and p.z < area else INF


## Where a ray is inside a box: (in, out), in past out when it misses.
static func _ray_through(from: Vector3, dir: Vector3, box: AABB) -> Vector2:
	var near := 0.0
	var far := INF
	for a in 3:
		if absf(dir[a]) < 0.000001:
			if from[a] < box.position[a] or from[a] > box.end[a]:
				return Vector2(1.0, 0.0)
			continue
		var t0: float = (box.position[a] - from[a]) / dir[a]
		var t1: float = (box.end[a] - from[a]) / dir[a]
		near = maxf(near, minf(t0, t1))
		far = minf(far, maxf(t0, t1))
	return Vector2(near, far)


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
	var up: Vector3i = _round_axis(world.get_chunk_transform(hit.frame).basis.y)
	if hit.block < 0:
		# The floor: the stud aimed at.
		var c := _cell_in(hit.frame, hit.point)
		var ts := BrickWorld.ticks_per_stud()
		var floor_lo := Vector3i(c.x * ts, 0, c.z * ts)
		return {"lo": floor_lo, "hi": floor_lo + Vector3i(ts, BrickWorld.ticks_per_plate(), ts),
				"dir": up, "frame": hit.frame, "block": -1, "top": true}
	var box: Array = world.get_block_ticks(hit.frame, hit.block)
	if box.is_empty():
		return {}
	var lo: Vector3i = box[0]
	var hi: Vector3i = lo + (box[1] as Vector3i)
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
## The extension records each on the bracket's top plate row (see
## `BrickPalette._side_studs_for`); a real stud is a stud wide, so its centre is
## half a stud in from the end of the bracket that row is at, and a part on it
## stands flush with that end -- the top, unless the bracket is inverted.
## Buried studs are already left out by the extension.
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
			if up[axis] == 0:
				continue
			# Whichever end of the bracket the stud's row is nearer. The grid
			# built off it lines up with that end: `base` is what
			# `_origin_on_plane` aligns to, and a stud is a whole number of
			# ticks, so the far end lines up exactly as well as the near one.
			var row: float = ((s.lo as Vector3i)[axis] + (s.hi as Vector3i)[axis]) * 0.5
			if row > (blo[axis] + bhi[axis]) * 0.5:
				c[axis] = bhi[axis] - half
				var b: Vector3i = d.base
				b[axis] = bhi[axis]
				d["base"] = b
			else:
				c[axis] = blo[axis] + half
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
	_newel_at = NO_STUD
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
		else:
			_continue_flight(face, c)
			_newel_at = _newel_target(face, c)
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
	# Newel on newel: aimed at a newel with a newel-bearing part held, the part
	# goes squarely on it, whichever of its four studs was aimed at. Centring a
	# ten-stud part would put it a stud out on three of the four, and the most
	# joints is no guide either -- a stud out, the new tread clips onto the old
	# one too and out-scores the newel.
	if _newel_at != NO_STUD:
		var c := Vector3i(_newel_at.x, first.y, _newel_at.z)
		if c == _clamp_cell(c, size) and asm.can_place(chunk, c, arch):
			return c
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


## Where the held part goes to stand its newel squarely on the newel the
## cursor is on -- a spiral stair piece's, or a round 2x2, which is one -- as
## the x and z of its cell. NO_STUD when the held part has no newel, or the
## cursor is not on the top of one.
func _newel_target(face: Dictionary, column: Vector3i) -> Vector3i:
	var held := BrickPalette.newel_of(_archetype_name())
	if not held.has_area() or not face.get("top", false):
		return NO_STUD
	var rid := _recipe_id_at(asm.frames.find(face.frame), int(face.block))
	if rid < 0 or rid >= recipe.size():
		return NO_STUD
	var below := BrickPalette.newel_of(recipe.part_of(rid))
	var at := recipe.cell_of(rid)
	if not below.has_point(Vector2i(column.x - at.x, column.z - at.z)):
		return NO_STUD
	return Vector3i(at.x + below.position.x - held.position.x, 0,
			at.z + below.position.y - held.position.y)


## Aiming at the top of a spiral stair piece's NEWEL while holding the same
## part turns the held piece to be the next in the flight: a quarter the way
## the part winds. Anywhere else, the turn is left as the player set it.
func _continue_flight(face: Dictionary, column: Vector3i) -> void:
	if not face.get("top", false):
		return
	var rid := _recipe_id_at(asm.frames.find(face.frame), int(face.block))
	if rid < 0 or rid >= recipe.size():
		return
	var below := recipe.part_of(rid)
	if BrickPalette.part_of(below) != _part():
		return
	var at := recipe.cell_of(rid)
	if not BrickPalette.newel_of(below).has_point(Vector2i(column.x - at.x, column.z - at.z)):
		return
	_yaw = BrickPalette.orientation_of(BrickPalette.next_in_flight(below)).x


## Keep a part's cell inside the build volume.
func _clamp_cell(c: Vector3i, size: Vector3i) -> Vector3i:
	return Vector3i(
		clampi(c.x, 0, plate_studs - size.x),
		clampi(c.y, 0, height_plates - size.y),
		clampi(c.z, 0, plate_studs - size.z))


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
	var dims := Vector3i(plate_studs, height_plates, plate_studs)
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
func _origin_on_plane(rot: int, dims: Vector3i, dir: Vector3i,
		plane: Vector3i, align: Vector3i) -> Vector3i:
	var origin := _origin_for(rot, dims)
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


## The held part as it will look placed: its real shape, its studs, and a
## bracket's side studs, so the ghost says which way those face before the
## click. It used to be a bare box, which showed none of that.
##
## Built by placing the part alone in a scratch chunk and asking the same
## calls the frames are drawn with, so it cannot disagree with them. Once per
## archetype; the ghost only changes shape when the part or its turn does.
func _ghost_shape(arch: int) -> Array:
	if _ghost_shapes.has(arch):
		return _ghost_shapes[arch]
	var c := world.create_chunk(Vector3i.ZERO, world.get_archetype_size(arch))
	var bid := world.place_block(c, Vector3i.ZERO, arch, 0)
	# Bevelled as the part will be once it is down (_remesh).
	var arrays := world.build_chunk_chamfer_mesh(c, BrickNear.BEVEL) if BrickNear.enabled \
			else world.build_chunk_mesh(c)
	var m := ArrayMesh.new()
	if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var buffer: PackedFloat32Array = world.get_chunk_studs(c)
	if bid >= 0:
		buffer.append_array(_side_stud_floats(c, bid, Transform3D(), Color.WHITE))
	world.release_chunk(c)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = PieceMeshes.stud()
	@warning_ignore("integer_division")
	mm.instance_count = buffer.size() / 16
	if mm.instance_count > 0:
		mm.set_buffer(buffer)
	_ghost_shapes[arch] = [m, mm]
	return _ghost_shapes[arch]


## Three tint states, straight off would_connect: -1 red, 0 amber, positive cyan.
func _update_ghost() -> void:
	var arch := _archetype()
	_joints = world.would_connect(chunk, _cell, arch)
	if _joints == 0 and _on_floor(_cell):
		_joints = 1
	# Occupancy is per chunk, so `would_connect` cannot see another frame at all.
	# A sideways brick dropped inside an upright one would place happily without
	# this (Docs/BuildMode.md section 2.3).
	_valid = _joints >= 0 and asm.can_place(chunk, _cell, arch)
	if _joints >= 0 and not _valid:
		_joints = -1

	var shape := _ghost_shape(arch)
	_ghost.mesh = shape[0]
	_ghost_studs.multimesh = shape[1]
	# The ghost belongs to the frame being built in, so it has to be drawn in
	# that frame's space rather than the world's.
	_ghost.transform = world.get_chunk_transform(chunk) \
			* Transform3D(Basis(), BrickWorld.grid_to_world(_cell))

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
	elif _role == BuildRecipe.Role.DETAIL:
		_ghost_material.albedo_color = Color(0.9, 0.5, 1.0, 0.42) if held \
				else Color(0.9, 0.5, 1.0, 0.28)
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
	if _painting:
		state = "PAINT BRUSH (B) -- LMB paints %s %s" % [
				BrickWorld.get_material_colour_name(_mat, _colour), BrickWorld.get_material_name(_mat)]
	var worst := 0.0
	for v in _stress.values():
		worst = maxf(worst, v)
	var interior := recipe.interior_count()
	if _stamp != null:
		state = "PLACING '%s' (%d bricks) -- LMB place, R turn, RMB cancel%s" % [
				_stamp_label, _stamp.size(), "" if _stamp_ok else "  [does not fit]"]
	elif _drag.size() > 0:
		state = "sizing the generated building"
	elif _spaces != null and _spaces.active:
		state = _spaces.status()
	var gen := ""
	if recipe.kind == "room":
		gen += "
" + _guide_text()
	for t in recipe.towers:
		var tp := TowerBlockout.normalised(t.params)
		@warning_ignore("integer_division")
		var storeys: int = int(tp.courses) / TowerBlockout.STOREY
		var mix := ""
		for k in (tp.program as Dictionary):
			mix += "%s%s %d" % [", " if mix != "" else "", k, tp.program[k]]
		gen += "\ngenerated building %dx%d studs, %d storeys%s%s%s%s -- drag its handles" % [
				tp.x, tp.z, storeys,
				", rooms" if tp.rooms else "", ", stairs" if tp.stairs else "",
				", windows" if tp.windows else "",
				(", furnished (%s)" % (mix if mix != "" else "any rooms")) if tp.furnish else ""]
	_hud.text = "%s  [%s%s]  %s   grid: %s\nlayer: %s\ncell %v   %s\n%d brick(s): %d structure, %d interior%s%s%s" % [
		_part(), _facing(), " inverted" if _flip else "",
		"%s %s" % [BrickWorld.get_material_colour_name(_mat, _colour), BrickWorld.get_material_name(_mat)],
		FRAME_NAMES[_frame] if _frame < FRAME_NAMES.size() else str(_frame),
		ROLE_TEXT[_role],
		_cell, state, recipe.size(), recipe.size() - interior, interior,
		(", %d fixture(s)" % recipe.fixture_count()) if recipe.fixture_count() > 0 else "",
		gen,
		("\nworst joint %.2f of capacity" % worst) if _overlay_on else ""]
	if _menu != null:
		_menu.set_title("%s%s  —  %s" % [recipe.name, " *" if _dirty else "",
				WorkshopMenu.KIND_LABELS.get(recipe.kind, recipe.kind)])


# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

func _unhandled_input(e: InputEvent) -> void:
	# The browser is a menu: nothing is built through it.
	if _hotbar != null and _hotbar.is_browsing():
		return
	# Nor through a dialog or an open menu.
	if _menu != null and _menu.is_modal():
		return
	# CTRL chords are the menus' (WorkshopMenu shortcuts); CTRL alone is the
	# camera's "down". Neither is a build key.
	if e is InputEventKey and e.ctrl_pressed:
		return
	if _tools != null and _tools.view.input(e):
		get_viewport().set_input_as_handled()
		return
	if _furnish != null and _furnish.input(e):
		return
	if _stamp != null and _stamp_input(e):
		return
	if _spaces != null and _spaces_input(e):
		return
	if _tools != null and _tools.input(e):
		return
	if _painting and toolbox.active_id() == &"paint" and toolbox.input(e):
		return
	if e is InputEventMouseButton and not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		_end_run()
	if e is InputEventMouseButton and e.pressed:
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				var before := recipe.size()
				_place()
				_begin_run(before)
			MOUSE_BUTTON_RIGHT:
				var ray := _mouse_ray()
				_delete_ray(ray[0], ray[1])
			MOUSE_BUTTON_MIDDLE: _pick_block()
			# Down is next, as in Minecraft.
			MOUSE_BUTTON_WHEEL_DOWN: _hotbar.step(1)
			MOUSE_BUTTON_WHEEL_UP: _hotbar.step(-1)
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.keycode >= KEY_1 and e.keycode <= KEY_9:
		_hotbar.select(e.keycode - KEY_1)
		return
	match e.keycode:
		KEY_BRACKETLEFT: _hotbar.step(-1)
		KEY_BRACKETRIGHT: _hotbar.step(1)
		KEY_COMMA: _hotbar.set_colour(_colour - 1)
		KEY_PERIOD: _hotbar.set_colour(_colour + 1)
		KEY_R: _yaw = (_yaw + 1) % 4
		KEY_F: _flip = not _flip
		KEY_T: _rotate_last()
		KEY_I: _toggle_layer()
		KEY_X:
			var ray := _mouse_ray()
			select_group_ray(ray[0], ray[1])
		KEY_M: move_group()
		KEY_U: _cycle_guide()
		KEY_C: copy_group()
		KEY_DELETE, KEY_BACKSPACE: delete_group()
		KEY_Z:
			if e.shift_pressed:
				redo_last()
			else:
				_undo()
		KEY_V: _snap_on = not _snap_on
		KEY_B: _set_painting(not _painting)
		KEY_O:
			if _spaces != null:
				if _painting:
					_set_painting(false)
				_spaces.toggle()
		KEY_G: _grid_on = not _grid_on; _grid.visible = _grid_on
		KEY_F1: _keys_on = not _keys_on; _keys_panel.visible = _keys_on
		KEY_H: _overlay_on = not _overlay_on; _stress_dirty = true; _refresh_overlay()
		KEY_F5:
			if e.shift_pressed:
				_save_new()
			else:
				_save()
		KEY_F9: _load()
		KEY_ENTER, KEY_KP_ENTER: _place_in_city()


## The spaces tool's share of the input, while it is out (O).
func _spaces_input(e: InputEvent) -> bool:
	if not _spaces.active:
		return false
	if e is InputEventMouseButton and e.pressed:
		var ray := _mouse_ray()
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				_spaces.click(ray[0], ray[1])   # what it marks: _spaces.mark
				return true
			MOUSE_BUTTON_RIGHT:
				_spaces.right_click(ray[0], ray[1])
				return true
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				_spaces.cycle_kind(-1 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
				return true
		return false
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_K:
				_spaces.cycle_kind(-1 if e.shift_pressed else 1)
				return true
			KEY_P:
				if e.shift_pressed:
					_spaces.cycle_point_kind()
				else:
					var ray := _mouse_ray()
					_spaces.toggle_point(ray[0], ray[1])
				return true
	return false


func _place() -> void:
	var before := recipe.size()
	_place_one()
	if mirror_on and recipe.size() > before and _frame == 0:
		_place_mirrored()


## The first stud across of a part `width` studs wide at `z`, mirrored across the plane.
func mirrored_z(z: int, width: int) -> int:
	return int(round(2.0 * mirror_z - float(z + width)))


## The same across X.
func mirrored_x(x: int, width: int) -> int:
	return int(round(2.0 * mirror_x - float(x + width)))


func set_mirror(on: bool) -> void:
	mirror_on = on
	if on and mirror_z == 0.0:
		mirror_z = float(_cell.z)
	if on and mirror_x == 0.0:
		mirror_x = float(_cell.x)


## Put the plane down the middle of the ghost.
func mirror_here() -> void:
	var size := BrickPalette.size_of(_archetype_name())
	if mirror_axis == 0:
		mirror_x = _cell.x + size.x * 0.5
	else:
		mirror_z = _cell.z + size.z * 0.5


## The brick just placed, again, on the other side of the plane. A part with a front
## that looks across the plane is turned to look the other way; one straddling the plane
## exactly is its own mirror and is not placed twice. Upright grid only, for now.
func _place_mirrored() -> void:
	var arch := _archetype_name()
	var size := BrickPalette.size_of(arch)
	var to := _cell
	if mirror_axis == 0:
		to.x = mirrored_x(_cell.x, size.x)
	else:
		to.z = mirrored_z(_cell.z, size.z)
	if to == _cell:
		return
	var keep := [_cell, _yaw, _snapped]
	var front := BrickPalette.front_of(arch)
	if front[mirror_axis] != 0:
		var want := front
		want[mirror_axis] = -front[mirror_axis]
		for y in 4:
			if BrickPalette.front_of(BrickPalette.variant_name(_part(), y, _flip)) == want:
				_yaw = y
				break
	_snapped = {}
	_cell = to
	_update_ghost()
	_place_one()
	_cell = keep[0]
	_yaw = keep[1]
	_snapped = keep[2]
	_update_ghost()


## One brick where the ghost is (`_place` is this and its mirror image).
func _place_one() -> void:
	if not _valid:
		return
	var arch_name := _archetype_name()
	var placed := asm.place(chunk, _cell, palette[arch_name], _colour)
	if placed >= 0 and _mat != 0:
		world.set_block_material(chunk, placed, _mat)
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
	recipe.add(arch_name, _cell, _colour, _recipe_frame_for(_frame), _role, _mat)
	_placed_at.append([_frame, placed])
	# The weld goes in the RECIPE as well, or the build stands here and falls
	# apart everywhere else: a saved file, a city placement and a replay all
	# rebuild from the recipe, and until now the recipe did not know what was
	# holding its sideways frames on. `welded_to` is -1 when the anchor was a
	# baseplate stud, which is not a weld -- the baseplate is not part of what
	# was built.
	if welded_to >= 0:
		recipe.add_weld(welded_to, rid)
	_push_brick(rid)
	_after_edit()


## Lay a part (a palette variant name) at a cell of the upright grid, in a colour and a
## material, as a click would but with no edit of its own: a kept shape's bricks undo with
## the shape (Docs/BuildTools.md). False if it does not fit there.
func lay_part(arch: String, cell: Vector3i, colour: int, mat: int, role: int = -1, af: int = 0) -> bool:
	if not palette.has(arch) or af < 0 or af >= asm.frames.size():
		return false
	var f: int = asm.frames[af]
	var id: int = palette[arch]
	if world.would_connect(f, cell, id) < 0 or not asm.can_place(f, cell, id):
		return false
	var placed := asm.place(f, cell, id, colour)
	if placed < 0:
		return false
	if mat != 0:
		world.set_block_material(f, placed, mat)
	recipe.add(arch, cell, colour, _recipe_frame_for(af), _role if role < 0 else role, mat)
	_placed_at.append([af, placed])
	_after_edit()
	return true


## Weld two recipe blocks, in the recipe and the world.
func weld_rids(a: int, b: int) -> void:
	var pa: Array = _placed_at[a]
	var pb: Array = _placed_at[b]
	asm.weld(asm.frames[pa[0]], pa[1], asm.frames[pb[0]], pb[1])
	recipe.add_weld(a, b)


## The brick of this part at this cell of grid `af` (0 upright), by recipe index, or -1.
## Found through the world's own cell lookup, not by walking the recipe.
func find_brick(arch: String, cell: Vector3i, af: int = 0) -> int:
	var size := BrickPalette.size_of(arch)
	for dx in size.x:
		for dy in size.y:
			for dz in size.z:
				var block := world.block_at(asm.frames[af], cell + Vector3i(dx, dy, dz))
				if block < 0:
					continue
				var i := _recipe_id_at(af, block)
				if i >= 0 and recipe.cell_of(i) == cell and recipe.part_of(i) == arch:
					return i
	return -1


## A held click: from here, moving the cursor lays a run (`run_step`). `from`: the recipe's
## size before the click laid its brick, so the run (and a mirror image) undo as one.
func _begin_run(from: int = -1) -> void:
	if _stamp != null:
		return
	_run_from = recipe.size() if from < 0 else from
	_run_on = true
	_run_last = _cell
	_run_moved = 0.0
	_run_press_ms = Time.get_ticks_msec()


## The button is up: what the click and its run laid is one undo (the building workshop's;
## the asset workshop groups its own).
func _end_run() -> void:
	if _run_on and _tools != null:
		var n := recipe.size() - _run_from
		if n > 1:
			undo_stack.group_last(n)
	_run_on = false


## Lay the held brick where the ghost has moved to, if it fits there -- once the click
## has become a drag: a hand that shook a little while clicking laid two bricks.
func run_step() -> void:
	if not _run_on or _cell == _run_last:
		return
	if _run_moved < RUN_START_PX or Time.get_ticks_msec() - _run_press_ms < RUN_START_MS:
		return
	_run_last = _cell
	if _valid:
		_place()


## Which recipe block is this (frame, block) in the world? -1 for anything the
## recipe does not own, which in practice means the baseplate.
func _recipe_id_at(frame_index: int, block: int) -> int:
	if frame_index < 0 or block < 0:
		return -1
	for rid in range(_rid_synced, _placed_at.size()):
		var at: Array = _placed_at[rid]
		_rid_map[int(at[0]) << 32 | int(at[1])] = rid
	_rid_synced = _placed_at.size()
	var rid: int = _rid_map.get(frame_index << 32 | block, -1)
	if rid < 0 or rid >= _placed_at.size():
		return -1
	# A brick gone since leaves its entry: the block id is never used again, but its old
	# recipe id is.
	var at: Array = _placed_at[rid]
	return rid if int(at[0]) == frame_index and int(at[1]) == block else -1


## Add a fixture to the recipe and build its preview, as one undoable edit.
##
## Nothing in the workshop authors fixtures any more: a staircase is built from
## the palette's spiral stair pieces (`K` used to drop a prefab one in). What is
## left is what a recipe that already HAS a fixture needs -- an older save, or
## a probe standing in for one -- so fixtures still load, draw, undo and delete.
## Frame 0 only: a fixture's cell is in the build's own upright grid.
func _add_fixture(kind: String, at: Vector3i, params: Dictionary) -> void:
	recipe.add_fixture(kind, at, params)
	_spawn_fixture(recipe.fixture_count() - 1)
	undo_stack.push(WkCommand.make(&"fixture", null, _undo_fixture))
	_after_edit()


## Undo of a fixture: the newest one, its record and the bricks it laid.
func _undo_fixture(_c: WkCommand) -> bool:
	if not recipe.pop_fixture():
		return false
	_clear_fixtures(recipe.fixture_count())
	_after_edit()
	return true


## Build the preview for fixture `i`: its own chunk, its own mesh, positioned in
## frame 0's grid.
func _spawn_fixture(i: int) -> void:
	var r := recipe.fixture_at(i)
	if r.is_empty():
		return
	if _fixture_parts.is_empty():
		_fixture_parts = StaircaseRecipe.flight_parts(palette)
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


## Z: the newest edit back, whatever it was (`undo_stack`). Bricks come off the end of the
## build; the one time a brick comes out of the middle is when an undo laid bricks back after
## it (a delete undone), and then as RMB takes one (`_remove_rid`), every id renumbered.
func _undo() -> bool:
	return undo_stack.undo()


## Shift Z (and the rail's Redo): do the last undone edit again.
func redo_last() -> bool:
	return undo_stack.redo() != null


## Record the brick just laid at recipe id `rid` as an edit of its own.
func _push_brick(rid: int) -> void:
	undo_stack.push(WkCommand.make(&"brick", rid, _undo_brick, _redo_brick, _brick_alive))


## The recipe id of a "brick" edit's brick, or -1. Its data is the recipe id while the brick
## stands; {gone, arch, cell, af} once it left some other way (RMB, a cut), when it is found
## again by part and cell -- an undo that lays it back (a delete undone) brings its edit back
## with it; and that brick's item (`_brick_item`) while the edit is undone.
func _brick_rid(c: WkCommand) -> int:
	if typeof(c.data) == TYPE_INT:
		return int(c.data) if int(c.data) < recipe.size() else -1
	if typeof(c.data) == TYPE_DICTIONARY and c.data.get("gone", false):
		var af := int(c.data.af)
		return find_brick(String(c.data.arch), c.data.cell, af) if af >= 0 and af < asm.frames.size() else -1
	return -1


func _brick_alive(c: WkCommand) -> bool:
	return _brick_rid(c) >= 0


## Undo of a "brick": take it up and keep what laying it again needs.
func _undo_brick(c: WkCommand) -> bool:
	var rid := _brick_rid(c)
	if rid < 0:
		return true   # its brick is not there: nothing to take back
	var item := _brick_item(rid)
	if not _take_rid(rid):
		return false
	c.data = item
	return true


## Redo of a "brick": lay it again as it was. A redone brick is laid as it was; a weld it had
## is not made again.
func _redo_brick(c: WkCommand) -> bool:
	if typeof(c.data) != TYPE_DICTIONARY or not _relay(c.data):
		c.data = -1
		return false
	c.data = recipe.size() - 1
	return true


## Undo past the first edit: the opened build's own fixtures, then its bricks, newest first,
## one a Z (`undo_stack.on_empty`). A brick taken back this way can be redone.
func _undo_opened() -> WkCommand:
	if _opened_fixtures > 0 and recipe.fixture_count() > 0:
		if not _undo_fixture(null):
			return null
		_opened_fixtures -= 1
		return WkCommand.make(&"fixture", null, _undo_fixture)
	if _opened_bricks > 0 and _opened_bricks <= recipe.size():
		var rid := _opened_bricks - 1
		var item := _brick_item(rid)
		if not _take_rid(rid):
			return null
		_opened_bricks -= 1
		return WkCommand.make(&"brick", item, _undo_brick, _redo_brick, _brick_alive)
	return null


## A brick as redo would lay it again.
func _brick_item(rid: int) -> Dictionary:
	return {"arch": recipe.part_of(rid), "cell": recipe.cell_of(rid), "colour": recipe.colour_of(rid),
			"mat": recipe.material_of(rid), "role": recipe.role_of(rid), "af": int(_placed_at[rid][0])}


## Take up recipe brick `rid` for an undo: off the end, or out of the middle as RMB does.
func _take_rid(rid: int) -> bool:
	if rid < recipe.size() - 1:
		_remove_rid(rid)
		_after_edit()
		return true
	var at: Array = _placed_at[rid]
	# A block that never made it into the world (see _load) has nothing to
	# remove; dropping it from the recipe is the whole of the undo.
	if int(at[0]) >= 0 and not world.remove_block(asm.frames[at[0]], at[1]):
		return false
	_placed_at.remove_at(rid)
	_rid_synced = mini(_rid_synced, _placed_at.size())
	recipe.pop()
	_after_edit()
	return true


## Bricks `gone` (recipe ids, sorted, no repeats) are about to leave the build some other way
## than undo -- RMB, a cut, a lifted group, an undone insert. Called BEFORE they go: their own
## edits remember them by part and cell (`_brick_rid`), and every recipe id the history keeps
## moves down past them.
func _forget_rids(gone: PackedInt32Array) -> void:
	if gone.is_empty():
		return
	_opened_bricks -= gone.bsearch(_opened_bricks)
	for c in undo_stack.leaves():
		var w := c as WkCommand
		match w.kind:
			&"brick":
				if typeof(w.data) != TYPE_INT:
					continue
				var rid := int(w.data)
				var below := gone.bsearch(rid)
				if below < gone.size() and gone[below] == rid:
					w.data = {"gone": true, "arch": recipe.part_of(rid), "cell": recipe.cell_of(rid),
							"af": int(_placed_at[rid][0])}
				else:
					w.data = rid - below
			&"paint":
				for e in w.data:
					var rid := int(e[0])
					if rid < 0:
						continue
					var below := gone.bsearch(rid)
					e[0] = -1 if below < gone.size() and gone[below] == rid else rid - below
			&"stamp":
				w.data.first = int(w.data.first) - gone.bsearch(int(w.data.first))


func _relay(item: Dictionary) -> bool:
	if item.is_empty() or not palette.has(String(item.arch)):
		return false
	var af := int(item.af)
	if af < 0 or af >= asm.frames.size():
		return false
	var f: int = asm.frames[af]
	var id: int = palette[String(item.arch)]
	var cell: Vector3i = item.cell
	if world.would_connect(f, cell, id) < 0 or not asm.can_place(f, cell, id):
		return false
	var placed := asm.place(f, cell, id, int(item.colour))
	if placed < 0:
		return false
	if int(item.mat) != 0:
		world.set_block_material(f, placed, int(item.mat))
	recipe.add(String(item.arch), cell, int(item.colour), _recipe_frame_for(af), int(item.role), int(item.mat))
	_placed_at.append([af, placed])
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
		# A kept shape's brick has no edit of its own (the shape's undo has it).
		if _tools != null and _tools.owner_of(recipe.part_of(rid), recipe.cell_of(rid)) >= 0:
			_tools.forget_brick(recipe.part_of(rid), recipe.cell_of(rid))
		_before_remove(rid)
		_forget_rids(PackedInt32Array([rid]))
		_placed_at.remove_at(rid)
		_rid_synced = mini(_rid_synced, rid)
		recipe.remove_at(rid)
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
		# Forget its edit, so undo still takes the others back in the order they were made.
		if k < _opened_fixtures:
			_opened_fixtures -= 1
		else:
			undo_stack.forget_nth(&"fixture", k - _opened_fixtures)
		_after_edit()
		return true
	return false


## Who answers the kit's Sketch tool (BrickWorkshopContext): the building workshop's tools,
## which make kept shapes of a stroke. The asset workshop answers itself.
func _sketch_host() -> Object:
	return _tools


## A brick at recipe id `rid` is about to leave from the middle (RMB, a cut, an undo): for a
## workshop that keeps something per brick (the asset workshop's part tags).
func _before_remove(_rid: int) -> void:
	pass


## Swap which layer the next brick goes in.
##
## The two are not separate scenes, separate grids or separate files. It is one
## build, and the switch is the moment the author stops saying "this is what
## holds it up" and starts saying "this is what is in it" -- which is a fact
## only they have. See `_interior`.
func _toggle_layer() -> void:
	_set_role((_role + 1) % 3)


func _set_role(r: int) -> void:
	_role = clampi(r, 0, BuildRecipe.Role.DETAIL)
	if _menu != null:
		_menu.set_role(_role)
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
	var arch_name := recipe.part_of(id)
	var turned := BrickPalette.turn(arch_name)
	if turned == "" or turned == arch_name:
		return  # a square part looks the same turned

	var cell := recipe.cell_of(id)
	var colour := recipe.colour_of(id)
	var mat := recipe.material_of(id)
	var rf := recipe.frame_of(id)
	var at: Array = _placed_at[_placed_at.size() - 1]
	var af: int = at[0]
	if af < 0:
		return  # it is not in the world to be turned

	if not palette.has(turned):
		return

	var last := undo_stack.last_leaf()
	if last == null or last.kind != &"brick" or typeof(last.data) != TYPE_INT or int(last.data) != id:
		return  # the last edit was not this brick (a fixture, a shape...): nothing to turn
	# The layer travels with the brick, not with the cursor: turning a chair is
	# not a way to make it load-bearing.
	var was_interior := recipe.role_of(id)
	# Taken up and laid again at the same recipe id: its edit stays, and undoes the turned one.
	if not _take_rid(id):
		return
	var placed := asm.place(asm.frames[af], cell, palette[turned], colour)
	if placed < 0:
		# It does not fit turned. Put the original back rather than losing it.
		var back := asm.place(asm.frames[af], cell, palette[arch_name], colour)
		if back >= 0:
			world.set_block_material(asm.frames[af], back, mat)
			recipe.add(arch_name, cell, colour, rf, was_interior, mat)
			_placed_at.append([af, back])
		else:
			undo_stack.forget_where(func(w: WkCommand) -> bool: return w == last)
		_after_edit()
		return
	world.set_block_material(asm.frames[af], placed, mat)
	recipe.add(turned, cell, colour, rf, was_interior, mat)
	_placed_at.append([af, placed])
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
	_dirty = true
	undo_stack.forget_redo()   # an edit makes redo meaningless (not while undoing or redoing)
	if _spaces != null:
		_spaces.edited()
	if _batch:
		return
	_select_group(_selected)   # ids move under it; redraw or drop the box
	_update_guide()
	_stress_dirty = true
	if _menu != null:
		var i := _tower_sel()
		if i >= 0:
			var tp := TowerBlockout.normalised(recipe.towers[i].params)
			_menu.set_tower_options(true, tp.rooms, tp.stairs, tp.windows, tp.furnish)
		else:
			_menu.set_tower_options(false, false, false, false, false)
	_remesh()
	if _furnish != null:
		_furnish.redraw()
	if _overlay_on:
		_refresh_overlay()


## One MeshInstance per frame. A frame has its own grid and its own transform,
## so it cannot share a mesh with another -- that is the whole reason a sideways
## brick is a frame rather than a rotated block.
func _remesh() -> void:
	_stud_count = 0
	var sectioned := _draws_sections()
	for i in asm.frames.size():
		var f: int = asm.frames[i]
		var mi: MeshInstance3D = _frame_meshes.get(f)
		if mi == null:
			mi = MeshInstance3D.new()
			mi.material_override = _material
			add_child(mi)
			_frame_meshes[f] = mi
		mi.transform = world.get_chunk_transform(f)
		if sectioned:
			_remesh_sections(f, mi)
			continue
		# Chamfered, all of it: a workshop is a few hundred bricks an arm's
		# length away, so there is no far tier to keep and nothing to patch
		# (Docs/BrickBevel.md). The shader is told, so its drawn seam and shaded
		# bevel stand down up close (geo_bevel).
		var chamfered := BrickNear.enabled
		_show_bricks(mi, f, world.build_chunk_chamfer_mesh(f, BrickNear.BEVEL) if chamfered \
				else world.build_chunk_mesh(f))
		_restud(f, mi)
	if sectioned:
		var n := _queued.size()
		_mesh_queued(n if not mesh_over_frames or n <= SECTIONS_AT_ONCE else SECTIONS_AT_ONCE)
		_count_studs()


## Builds can be far too big to rebuild whole for each brick. An old brick library has no way
## to do less.
func _draws_sections() -> bool:
	return ClassDB.class_has_method("BrickWorld", "build_sections_chamfer_mesh")


func _show_bricks(mi: MeshInstance3D, f: int, arrays: Array, bevelled: bool = BrickNear.enabled) -> void:
	var m := ArrayMesh.new()
	if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = m
	mi.set_instance_shader_parameter("geo_bevel", 1.0 if bevelled else 0.0)
	# Frames are chunks of their own: wood's grain is the grid's across them.
	BrickMaterials.set_grain_origin(mi, world, f)


## The sections of a grid the engine says have changed, into the queue to be meshed.
func _remesh_sections(f: int, _frame_node: MeshInstance3D) -> void:
	world.set_chunk_section_studs(f, SECTION_STUDS)
	world.set_chunk_section_plates(f, SECTION_PLATES)
	# Untyped: these calls are newer than some libraries, and a typed call to a method the
	# library lacks does not compile. `_draws_sections` has said they are there.
	var engine: Variant = world
	var changed: PackedInt32Array = engine.take_changed_sections(f, SECTION_MARGIN)
	for s in changed:
		_queued[Vector2i(f, s)] = true
	if not changed.is_empty():
		_box_frame(f)


## Mesh up to `n` queued sections, nearest the camera first, each as near or far as it is.
func _mesh_queued(n: int) -> void:
	if _queued.is_empty() or n <= 0:
		return
	var eye := _camera.global_position if _camera != null else Vector3.ZERO
	var keys := _queued.keys()
	if keys.size() > n:
		var dist := {}
		for k in keys:
			dist[k] = _section_distance(k, eye)
		keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return float(dist[a]) < float(dist[b]))
		keys.resize(n)
	var groups := {}
	for k: Vector2i in keys:
		_queued.erase(k)
		if not _frame_meshes.has(k.x):
			continue
		var g := Vector2i(k.x, 1 if _wants_bevel(k, eye) else 0)
		(groups.get_or_add(g, []) as Array).append(k.y)
	for g: Vector2i in groups:
		_mesh_sections(g.x, PackedInt32Array(groups[g]), g.y == 1)
	_count_studs()


func _count_studs() -> void:
	_stud_count = 0
	for key in _frame_studs:
		var held: Variant = _frame_studs[key]
		if is_instance_valid(held):
			_stud_count += (held as MultiMeshInstance3D).multimesh.instance_count


func _mesh_sections(f: int, list: PackedInt32Array, bevelled: bool) -> void:
	var engine: Variant = world
	var frame_node: MeshInstance3D = _frame_meshes[f]
	var held: Dictionary = _sections.get_or_add(f, {})
	var meshes: Array = engine.build_sections_chamfer_mesh(f, list, BrickNear.BEVEL if bevelled else 0.0)
	var inv := world.get_chunk_transform(f).affine_inverse()
	for i in list.size():
		var s := list[i]
		var arrays: Array = meshes[i]
		var studs: PackedFloat32Array = engine.get_section_studs(f, s)
		var key := Vector2i(f, s)
		var mi: MeshInstance3D = held.get(s)
		if arrays.is_empty() and studs.is_empty():
			if mi != null:
				mi.queue_free()
				held.erase(s)
				_frame_studs.erase(key)
			_bevelled.erase(key)
			continue
		if mi == null:
			mi = MeshInstance3D.new()
			mi.material_override = _material
			frame_node.add_child(mi)
			held[s] = mi
		_show_bricks(mi, f, arrays, bevelled)
		if bevelled:
			_bevelled[key] = true
		else:
			_bevelled.erase(key)
		for id in engine.get_section_side_stud_blocks(f, s):
			var col := BrickWorld.get_material_colour(world.get_block_material(f, id), world.get_block_colour(f, id))
			studs.append_array(_side_stud_floats(f, id, inv, col))
		_fill_studs(key, mi, studs)
	_box_frame(f)


## What a grid's bricks fill, drawn or queued to be: a ray has to find a brick not drawn yet.
func _box_frame(f: int) -> void:
	var box := AABB()
	for s in _sections.get(f, {}):
		var part: AABB = (_sections[f][s] as MeshInstance3D).get_aabb()
		if part.has_volume():
			box = part if not box.has_volume() else box.merge(part)
	for k: Vector2i in _queued:
		if k.x == f:
			var part := _section_box(k.y)
			box = part if not box.has_volume() else box.merge(part)
	_frame_boxes[f] = box


## A section's box in its grid's own space, in metres: the cells it draws, and a brick's
## reach past them (a brick belongs to the section its lowest cell is in).
func _section_box(s: int) -> AABB:
	var nx := ceili(float(plate_studs) / SECTION_STUDS)
	var nz := ceili(float(plate_studs) / SECTION_STUDS)
	@warning_ignore("integer_division")
	var layer := s / (nx * nz)
	var size := Vector3(SECTION_STUDS * BrickPalette.STUD_M, SECTION_PLATES * BrickPalette.PLATE_M,
			SECTION_STUDS * BrickPalette.STUD_M)
	@warning_ignore("integer_division")
	var at := Vector3(s % nx, layer, (s / nx) % nz) * size
	return AABB(at, size).grow(1.0)


## How far the camera is from a section, in metres.
func _section_distance(k: Vector2i, eye: Vector3) -> float:
	var mi: MeshInstance3D = _sections.get(k.x, {}).get(k.y)
	var local := _section_box(k.y)
	if mi != null and mi.get_aabb().has_volume():
		local = mi.get_aabb()
	var box := world.get_chunk_transform(k.x) * local
	return eye.distance_to(eye.clamp(box.position, box.end))


## Chamfered near the camera, flat past it (as the city's BrickNear), with its margin so a
## section on the line does not flicker between them.
func _wants_bevel(k: Vector2i, eye: Vector3) -> bool:
	if not BrickNear.enabled:
		return false
	if not draw_far_flat or _camera == null:
		return true
	var reach := BrickNear.radius + (BrickNear.MARGIN if _bevelled.has(k) else 0.0)
	return _section_distance(k, eye) < reach


## As the camera moves, the sections that crossed the line go back in the queue, and each
## frame meshes a frame's worth of the queue.
func _section_process() -> void:
	if not _draws_sections():
		return
	if draw_far_flat and BrickNear.enabled and _camera != null:
		var eye := _camera.global_position
		if eye.distance_to(_tiered_from) > 1.0:
			_tiered_from = eye
			for f in _sections:
				for s in _sections[f]:
					var k := Vector2i(f, s)
					if _wants_bevel(k, eye) != _bevelled.has(k):
						_queued[k] = true
	if not _queued.is_empty():
		_mesh_queued(SECTIONS_AT_ONCE)


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
static var _studs_fallback: Material = null

static func _stud_material() -> Material:
	var terrain: Script = load("res://scripts/terrain_tile.gd")
	if terrain != null:
		for m in terrain.get_script_method_list():
			if m.name == "stud_material":
				return terrain.call("stud_material")
	if _studs_fallback == null:
		# The printed stud shader, not a plain material: it reads the material
		# a stud's brick is made of (brick_materials.gdshaderinc), so a metal
		# brick has metal studs even where the terrain does not supply one.
		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/printed.gdshader")
		_studs_fallback = BrickMaterials.add_glass(sm)
	return _studs_fallback


## Bevelled studs on a frame the camera is near, plain ones on a frame it is
## not (BrickNear.stud_bevel_radius, as the city does it): which mesh the
## frame's stud MultiMesh draws, a whole frame at a time.
func _stud_lod() -> void:
	if _camera == null:
		return
	var eye := _camera.global_position
	# Only when the camera has moved or studs were made again: a big build has hundreds of them.
	if eye.distance_to(_studs_from) < 0.25 and not _studs_changed:
		return
	_studs_from = eye
	_studs_changed = false
	for frame in _frame_studs:
		# A frame that emptied was freed with its mesh; its entry stays.
		var held: Variant = _frame_studs[frame]
		if not is_instance_valid(held):
			continue
		var mmi: MultiMeshInstance3D = held
		if mmi.multimesh == null or mmi.multimesh.instance_count == 0:
			continue
		# From the boxes kept here, not the MultiMesh's: that is asked of the renderer
		# (Docs/WhereWorkRuns.md), and is empty headless.
		var dist: float
		if frame is Vector2i:
			dist = _section_distance(frame, eye)
		else:
			var box := world.get_chunk_transform(int(frame)) * _frame_box(int(frame))
			dist = eye.distance_to(eye.clamp(box.position, box.end))
		# Past this a stud is a pixel or two, and a big build has hundreds of thousands.
		mmi.visible = not draw_far_flat or dist < STUD_RANGE
		var plain := mmi.multimesh.mesh == PieceMeshes.stud_plain()
		var want_plain := dist > BrickNear.stud_bevel_radius + (0.0 if plain else BrickNear.MARGIN)
		if want_plain != plain:
			mmi.multimesh.mesh = PieceMeshes.stud_plain() if want_plain else PieceMeshes.stud()


func _restud(frame: int, parent: MeshInstance3D) -> void:
	var buffer: PackedFloat32Array = world.get_chunk_studs(frame)
	buffer.append_array(_side_stud_instances(frame))
	_fill_studs(frame, parent, buffer)


func _fill_studs(key: Variant, parent: MeshInstance3D, buffer: PackedFloat32Array) -> void:
	var mmi: MultiMeshInstance3D = _frame_studs.get(key)
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "Studs"
		mmi.material_override = _stud_material()
		# Studs never cast (Terrain.md 7.4): a 0.07 m shadow for thousands of
		# instances through every cascade, drawn analytically by the shader
		# instead.
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)
		_frame_studs[key] = mmi
	_studs_changed = true
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
##
## Run on every edit over every brick, so a brick whose part has no side studs
## (nearly all of them) is passed over on its archetype alone.
func _side_stud_instances(frame_chunk: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var fi := asm.frames.find(frame_chunk)
	var inv := world.get_chunk_transform(frame_chunk).affine_inverse()
	for at in _placed_at:
		if int(at[0]) != fi or int(at[1]) < 0:
			continue
		var arch := world.get_block_archetype(frame_chunk, int(at[1]))
		if not _arch_side_studs.has(arch):
			_arch_side_studs[arch] = not world.get_archetype_side_studs(arch).is_empty()
		if not _arch_side_studs[arch]:
			continue
		var col := BrickWorld.get_material_colour(world.get_block_material(frame_chunk, int(at[1])),
				world.get_block_colour(frame_chunk, int(at[1])))
		out.append_array(_side_stud_floats(frame_chunk, int(at[1]), inv, col))
	return out


## One block's side studs as stud instances, taken from world space by `inv`.
func _side_stud_floats(frame_chunk: int, block: int, inv: Transform3D,
		col: Color) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for st in _real_side_studs(frame_chunk, block):
		var b := inv.basis * _basis_up(Vector3(st.dir as Vector3i))
		var o: Vector3 = inv * (st.centre as Vector3)
		for v in [b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y,
				b.x.z, b.y.z, b.z.z, o.z, col.r, col.g, col.b, col.a]:
			out.push_back(v)
	return out


## Archetype id -> whether its part has side studs at all.
var _arch_side_studs := {}


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
		for i in world.get_block_count(chunk):
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
	_grid_drawn = grid_window()
	var lo := _grid_drawn.position
	var hi := _grid_drawn.end
	# Just above the plane itself, so it does not z-fight with the brick tops.
	var y := 0.002
	for i in _grid_drawn.size.x + 1:
		# Faint: a rotated grid's plane can sit right across the view, and it is
		# an orientation cue rather than something to read.
		var u := (lo.x + i) * s
		var v := (lo.y + i) * s
		var col := Color(1, 1, 1, 0.13 if (lo.x + i) % 4 == 0 else 0.04)
		im.surface_set_color(col); im.surface_add_vertex(Vector3(u, y, lo.y * s))
		im.surface_set_color(col); im.surface_add_vertex(Vector3(u, y, hi.y * s))
		im.surface_set_color(col); im.surface_add_vertex(Vector3(lo.x * s, y, v))
		im.surface_set_color(col); im.surface_add_vertex(Vector3(hi.x * s, y, v))
	im.surface_end()
	_grid.mesh = im


## The studs the grid is drawn over: round the ghost, moving a quarter of itself at a time
## so it is not redrawn for every stud walked, and a square in the area.
func grid_window() -> Rect2i:
	var side := mini(GRID_STUDS, plate_studs)
	@warning_ignore("integer_division")
	var q := side / 4
	@warning_ignore("integer_division")
	var x := clampi(snappedi(_cell.x, q) - side / 2, 0, plate_studs - side)
	@warning_ignore("integer_division")
	var z := clampi(snappedi(_cell.z, q) - side / 2, 0, plate_studs - side)
	return Rect2i(x, z, side, side)


## The upright grid's bricks seen from above, a stud round them, in studs. Past this there
## is nothing to walk into.
func built_area() -> Rect2i:
	var box := _frame_box(asm.frames[0])
	if not box.has_volume():
		return Rect2i()
	var lo := Vector2i(floori(box.position.x / BrickPalette.STUD_M), floori(box.position.z / BrickPalette.STUD_M))
	var hi := Vector2i(ceili(box.end.x / BrickPalette.STUD_M), ceili(box.end.z / BrickPalette.STUD_M))
	return Rect2i(lo, hi - lo).grow(1)


# ---------------------------------------------------------------------------
# Save, load, and the gate: place it in the city and shoot it
# ---------------------------------------------------------------------------

## Where F5 and F9 actually go: the quick-save slot (BuildRecipe.QUICK_SAVE).
## The gate points it somewhere else so that a test run cannot overwrite what
## somebody built.
var _save_path := BuildRecipe.QUICK_SAVE


func _save() -> void:
	if recipe.name == "untitled":
		recipe.name = "workshop"
	var err := recipe.save_to(_save_path)
	print("[workshop] saved %d bricks and %d fixture(s) to %s (%s)" % [
			recipe.size(), recipe.fixture_count(), _save_path, error_string(err)])


## Where Shift+F5 keeps builds: the player's half of the building library
## (BuildRecipe.player_dir), so every one saved here can be picked up with P in
## the city and chosen with the wheel. F5 still overwrites the one quick-save
## slot. A gate points this somewhere a test cannot hurt.
var _builds_dir := BuildRecipe.player_dir()


## Save the build as a NEW entry in the library, never over an old one: the
## next free build_NNN.json, named "Build NNN" so the placer can say which.
## Returns the path written, or "" if it failed.
func _save_new() -> String:
	if not recipe.has_content():
		print("[workshop] nothing built yet")
		return ""
	DirAccess.make_dir_recursive_absolute(_builds_dir)
	var n := 1
	while FileAccess.file_exists(_builds_dir + "build_%03d.json" % n):
		n += 1
	var path := _builds_dir + "build_%03d.json" % n
	recipe.name = "Build %03d" % n
	var err := recipe.save_to(path)
	print("[workshop] saved '%s': %d bricks and %d fixture(s) to %s (%s)" % [
			recipe.name, recipe.size(), recipe.fixture_count(), path, error_string(err)])
	return path if err == OK else ""


func _load() -> void:
	var r := BuildRecipe.load_from(_save_path)
	if not r.has_content():
		print("[workshop] nothing to load")
		return
	_load_recipe(r)


## Start over with nothing on the baseplate: every frame dropped and rebuilt
## empty, every stack emptied. New, and the first half of every load.
func _reset_space() -> void:
	_cancel_stamp()
	_stamp_moving = false
	_select_group(-1)
	_drag = {}
	_clear_towers()
	undo_stack.clear()
	undo_stack.on_empty = _undo_opened
	_opened_bricks = 0
	_opened_fixtures = 0
	if _spaces != null:
		_spaces.edited()
	# Drop every frame, not just the one being built in.
	for f in asm.frames:
		world.release_chunk(f)
		var mi: MeshInstance3D = _frame_meshes.get(f)
		if mi != null:
			mi.queue_free()
	_frame_meshes.clear()
	_frame_studs.clear()
	_sections.clear()
	_frame_boxes.clear()
	_queued.clear()
	_bevelled.clear()
	_clear_fixtures()
	_stroke = null
	# And the placement list, which is indexed by recipe id: left standing, the
	# new recipe's entries went on after the old ones, and every id read back
	# from it -- undo, delete, turn, the newel aim -- was off by the old count.
	_placed_at.clear()
	_rid_map.clear()
	_rid_synced = 0
	asm = Assembly.new(world, palette)
	_build_frames()
	_frame = 0
	_recipe_frames.clear()
	_lay_baseplate()
	recipe = BuildRecipe.new()
	if _tools != null:
		_tools.recipe_changed()


## Load a recipe into a cleared space. The generated buildings go first, as the
## city lays them first (TowerBlockout.flatten).
func _load_recipe(r: BuildRecipe) -> void:
	_reset_space()
	recipe = r
	if _tools != null:
		_tools.recipe_changed()
	for i in recipe.towers.size():
		_spawn_tower(i)
	# The six grids already exist, so match the recipe's frames onto them by
	# (rotation, origin) rather than creating more. Cells are absolute in the
	# workshop -- its grids ARE the recipe's coordinate space -- so nothing is
	# rebased either.
	var placed := 0
	for i in recipe.size():
		var rf: int = recipe.frame_of(i)
		var af := _asm_frame_for(recipe.frame_rotation(rf), recipe.frame_ticks(rf))
		if af < 0 and rf != 0:
			# A sideways grid from when the volume was smaller, which put them elsewhere:
			# any grid holds bricks, so stand one where it was.
			if asm.add_frame(Vector3i(plate_studs, height_plates, plate_studs),
					recipe.frame_rotation(rf), recipe.frame_ticks(rf)) >= 0:
				af = asm.frames.size() - 1
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
			if recipe.material_of(i) != 0:
				world.set_block_material(asm.frames[af], bid, recipe.material_of(i))
		_placed_at.append([af, bid])
		if rf != 0:
			_recipe_frames[af] = rf
	_opened_bricks = recipe.size()
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
	_opened_fixtures = recipe.fixture_count()
	print("[workshop] loaded %d of %d bricks across %d frame(s), %d weld(s), %d fixture(s)"
			% [placed, recipe.size(), recipe.frame_count(), welded, recipe.fixture_count()])
	if _menu != null:
		_menu.set_kind(recipe.kind)
	_after_edit()
	_dirty = false
	if _tools != null:
		frame_build()


## Which standing grid matches this (rotation, origin). -1 if none does, which
## means the recipe was built somewhere this workshop cannot represent.
func _asm_frame_for(rot: int, ticks: Vector3i) -> int:
	for i in asm.frames.size():
		var f: int = asm.frames[i]
		if world.get_chunk_rotation(f) == rot and world.get_chunk_origin_ticks(f) == ticks:
			return i
	return -1


## The Stage 2 gate, run live: register the build with a BuildingRegistry, blow
## a hole in it, and confirm it breaks like a generated building -- because it
## IS one. Section 8.1: the city places finished recipes, it does not author.
func _place_in_city() -> void:
	if not recipe.has_content():
		print("[workshop] nothing built yet")
		return
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, pal)
	# What the city places: a generated building as bricks (TowerBlockout).
	var flat := TowerBlockout.flatten(recipe)
	var id := reg.register_build(flat, Transform3D())
	if id < 0:
		return
	var c := reg.materialise(id)
	var building := reg.get_building(id)
	var before := 0
	for f in building.chunks():
		before += w.get_alive_block_count(f)
	var b := flat.bounds()
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
	# Fixtures are built with the building now (BuildingRegistry._build_fixtures),
	# not woken afterwards, so what is worth reporting is that each laid bricks.
	var fixtures: int = building.fixtures.size()
	var awake := 0
	for fx in building.fixtures:
		if not fx.blocks.is_empty():
			awake += 1
	print("[workshop] placed in city: %d bricks across %d frame(s), %d weld(s), %d fixture(s) (%d built); hit removed %d, %d group(s) came loose, %d frame(s) came off"
			% [before, building.chunks().size(),
					building.asm.live_weld_count() if building.asm != null else 0,
					fixtures, awake,
					before - after, groups.size(), loose_frames])


# ---------------------------------------------------------------------------
# Menus (Docs/Workshop.md, Stage A)
# ---------------------------------------------------------------------------

const ROLE_TEXT := [
	"STRUCTURE (I)  — what holds the building up",
	"INTERIOR (I)  — weighs nothing, holds nothing up",
	"DETAIL (I)  — interior, only laid with somebody in the room",
]

var _menu: WorkshopMenu
## Where Save writes without asking. "" until the build has been opened from or
## saved to a file; the quick-save slot (F5) is not it.
var _current_path := ""
## Edited since it was last saved or loaded.
var _dirty := false
## While true, `_after_edit` does nothing: a stamp or its undo is hundreds of
## edits and must remesh once, not once per brick.
var _batch := false


func _on_menu(what: String, arg: Variant) -> void:
	match what:
		"new": _new_build()
		"open": _open_path(str(arg))
		"save": _save_current()
		"save_as_ask": _menu.show_save_as(recipe.name if recipe.name != "untitled" else "",
				str(recipe.meta.get("room_kind", "")),
				AssetTags.tags_of(recipe) if recipe.kind == "item" else {})
		"save_as": _save_as(str(arg.name), str(arg.get("room_kind", "")), arg.get("tags", {}))
		"quick_save": _save()
		"quick_load": _load()
		"city": _place_in_city()
		"insert": _begin_stamp(str(arg))
		"tower": _add_tower()
		"bake_tower": _bake_tower()
		"remove_tower": _remove_tower()
		"tower_option": _set_tower_option(str(arg[0]), bool(arg[1]))
		"tower_program": _set_tower_param("program", arg)
		"reroll": _reroll_tower()
		"program_dialog":
			var i := _tower_sel()
			if i >= 0:
				_menu.show_program(TowerBlockout.normalised(recipe.towers[i].params).program)
		"kind":
			recipe.kind = str(arg)
			_menu.set_kind(recipe.kind)
			_dirty = true
			_update_guide()
		"role": _set_role(int(arg))
		"select_group":
			var ray := _mouse_ray()
			select_group_ray(ray[0], ray[1])
		"move_group": move_group()
		"undo": _undo()
		"copy_group": copy_group()
		"delete_group": delete_group()


## File > New: an empty baseplate, the same kind of build as before.
func _new_build() -> void:
	var kind := recipe.kind
	_reset_space()
	recipe.kind = kind
	_current_path = ""
	_after_edit()
	_dirty = false
	frame_build()
	print("[workshop] new %s" % kind)


func _open_path(path: String) -> bool:
	var r := BuildRecipe.load_from(path)
	if not r.has_content():
		print("[workshop] %s holds nothing to load" % path)
		return false
	_load_recipe(r)
	_current_path = path
	_dirty = false
	return true


## Can this file be written? A shipped build (res://) can be while running
## from the editor, which is how the shipped library gets made.
static func _writable(path: String) -> bool:
	return not path.begins_with("res://") or OS.has_feature("editor")


## File > Save: over the file it came from, or ask for a name.
func _save_current() -> void:
	if _current_path == "" or not _writable(_current_path):
		_menu.show_save_as(recipe.name if recipe.name != "untitled" else "",
				str(recipe.meta.get("room_kind", "")),
				AssetTags.tags_of(recipe) if recipe.kind == "item" else {})
		return
	_write(_current_path)


## File > Save As: a named file in the library for this kind of build --
## buildings where the city placer finds them, rooms filed by room kind.
func _save_as(build_name: String, room_kind: String = "", tags: Dictionary = {}) -> String:
	recipe.name = build_name
	var dir := BuildRecipe.player_dir(recipe.kind)   # the player's, not the shipped one
	if recipe.kind == "room":
		if room_kind == "":
			room_kind = str(recipe.meta.get("room_kind", Room.KINDS[0]))
		recipe.meta["room_kind"] = room_kind
		dir += room_kind + "/"
	elif recipe.kind == "item":
		# Planet, type and rooms (AssetTags): what the catalogue filters by and
		# where the generator may put it (RoomTemplates.add_item). A room kind
		# alone is the older form of the room tag.
		if tags.is_empty():
			tags = AssetTags.tags_of(recipe)
			if room_kind != "":
				tags["room"] = [] if room_kind == "any" else [room_kind]
		recipe.meta["tags"] = AssetTags.clean(tags)
		recipe.meta.erase("room_kind")
		recipe.meta.erase("room_kinds")
	if _builds_dir != BuildRecipe.player_dir():
		dir = _builds_dir   # the gate writes somewhere a test cannot hurt
	var path := dir + slug(build_name) + ".json"
	return path if _write(path) else ""


## A file name from a build name.
static func slug(n: String) -> String:
	var s := n.strip_edges().to_lower().replace(" ", "_").validate_filename()
	return s if s != "" else "build"


func _write(path: String) -> bool:
	if recipe.kind == "room" or recipe.kind == "item":
		# What the generator needs to choose a template without building it.
		var b := recipe.bounds()
		var d: Vector3i = b[1]
		recipe.meta["size"] = [d.x, d.y, d.z]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := recipe.save_to(path)
	if recipe.kind == "room" or recipe.kind == "item":
		# The generator reads templates once; this one is new. So do the
		# catalogue and the furniture meshes.
		RoomTemplates.reload()
		AssetCatalog.reload()
		AssetPlacements.forget_meshes()
	print("[workshop] saved '%s' (%s): %d bricks, %d fixture(s), %d generated building(s) to %s (%s)"
			% [recipe.name, recipe.kind, recipe.size(), recipe.fixture_count(),
			recipe.towers.size(), path, error_string(err)])
	if err != OK:
		return false
	_current_path = path
	_dirty = false
	return true


# ---------------------------------------------------------------------------
# A build inside a build (Docs/Workshop.md, Stage B)
# ---------------------------------------------------------------------------
#
# A COPY, with a group record saying where it came from -- never a reference.
# Docs/Workshop.md section 0 has the reasons; the short one is that block id is
# the damage contract and a reference renumbers every block after it whenever
# its source is edited.

var _stamp: BuildRecipe = null    ## what is in hand, already turned
var _stamp_base: BuildRecipe = null   ## the same, unturned
var _stamp_src := ""
var _stamp_label := ""
var _stamp_turn := 0
var _stamp_at := Vector3i(-1, -1, -1)  ## where its box's min corner goes
var _stamp_ok := false
const STAMP_BEVELS_TO := 5000
var _stamp_ghost: MeshInstance3D
var _stamp_material: StandardMaterial3D


## Insert > Build from library: pick it up.
func _begin_stamp(path: String) -> bool:
	var r := BuildRecipe.load_from(path)
	if not r.has_content():
		print("[workshop] %s holds nothing to insert" % path)
		return false
	return hold_stamp(r, path)


## Take a recipe in hand to stamp. Split from `_begin_stamp` for the probe.
func hold_stamp(r: BuildRecipe, source: String = "") -> bool:
	_cancel_stamp()
	_stamp_base = r
	_stamp_src = source
	_stamp_label = r.name if r.name != "untitled" else source.get_file().get_basename()
	_stamp_turn = 0
	_stamp = r
	_stamp_at = Vector3i(-1, -1, -1)
	_stamp_ok = false
	_make_stamp_ghost()
	return true


func _cancel_stamp() -> void:
	_stamp = null
	_stamp_base = null
	if _stamp_ghost != null:
		_stamp_ghost.queue_free()
		_stamp_ghost = null


## A quarter turn of what is in hand. A multi-frame build cannot turn (its
## sideways grids would each need a turn composed onto them), so it does not.
func _turn_stamp() -> void:
	var t := _stamp_base.turned(_stamp_turn + 1)
	if t == null:
		print("[workshop] a build with sideways parts only goes in facing the way it was built")
		return
	_stamp_turn = (_stamp_turn + 1) % 4
	_stamp = t
	_stamp_at = Vector3i(-1, -1, -1)
	_make_stamp_ghost()


## Keys and clicks while a build is in hand. True when used.
func _stamp_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.pressed:
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				if _stamp_ok:
					_commit_stamp()
				return true
			MOUSE_BUTTON_RIGHT:
				_abort_stamp()
				return true
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_R:
				_turn_stamp()
				return true
			KEY_BACKSPACE, KEY_DELETE:
				_abort_stamp()
				return true
	return false


## The box a stamp takes up in frame 0's cells: its bricks, fixtures and
## generated buildings. [min corner, size].
static func stamp_box(r: BuildRecipe) -> Array:
	var b := r.bounds()
	var lo: Vector3i = b[0]
	var hi: Vector3i = lo + (b[1] as Vector3i)
	var any := not r.is_empty()
	for t in r.towers:
		var c := BuildRecipe.cell_from(t.cell)
		var d := TowerBlockout.dims(TowerBlockout.normalised(t.params))
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z)) if any else c
		hi = Vector3i(maxi(hi.x, c.x + d.x), maxi(hi.y, c.y + d.y), maxi(hi.z, c.z + d.z)) \
				if any else c + d
		any = true
	return [lo, hi - lo]


## The held build's bricks, drawn as a ghost: built for real in a scratch
## chunk and meshed, the way the ghost of one part is.
func _make_stamp_ghost() -> void:
	if _stamp_ghost != null:
		_stamp_ghost.queue_free()
	if _stamp_material == null:
		_stamp_material = _ghost_material.duplicate() as StandardMaterial3D
	_stamp_ghost = MeshInstance3D.new()
	_stamp_ghost.material_override = _stamp_material
	add_child(_stamp_ghost)
	if _stamp.is_empty():
		var bm := BoxMesh.new()   # only a generated building: its box
		var box := stamp_box(_stamp)
		bm.size = BrickWorld.grid_to_world(box[1])
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bm.get_mesh_arrays())
		_stamp_ghost.mesh = m
		_stamp_ghost.set_meta("centre", true)
		return
	var c := world.create_chunk(Vector3i.ZERO, _stamp.chunk_dims())
	_stamp.build(world, c, palette, true)
	# Plain for a whole building: a see-through ghost has no use for bevels, and picking it up
	# should not take seconds.
	var arrays := world.build_chunk_chamfer_mesh(c, BrickNear.BEVEL) if BrickNear.enabled and _stamp.size() < STAMP_BEVELS_TO \
			else world.build_chunk_mesh(c)
	world.release_chunk(c)
	var m := ArrayMesh.new()
	if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_stamp_ghost.mesh = m


## Each frame while a build is in hand: aim, fit, tint.
func _stamp_process() -> void:
	var ray := _mouse_ray()
	var at := stamp_target(ray[0], ray[1])
	if at.x < 0:
		_stamp_ghost.visible = false
		return
	_stamp_ghost.visible = true
	if at != _stamp_at:
		_stamp_at = at
		_stamp_ok = _stamp_fits(at)
	var box := stamp_box(_stamp)
	var lo: Vector3i = box[0]
	var ghost_at := at
	if not _stamp.is_empty():
		# The ghost was rebased to its BRICKS' min corner, which may be inside
		# the box when a generated building sticks out further.
		ghost_at = at + ((_stamp.bounds()[0] as Vector3i) - lo)
	var p := BrickWorld.grid_to_world(ghost_at)
	if _stamp_ghost.has_meta("centre"):
		p += BrickWorld.grid_to_world(box[1]) * 0.5
	_stamp_ghost.transform = world.get_chunk_transform(asm.frames[0]) * Transform3D(Basis(), p)
	_stamp_material.albedo_color = Color(0.35, 0.9, 1.0, 0.40) if _stamp_ok \
			else Color(1.0, 0.25, 0.22, 0.45)


## Where the held build's box goes for this ray: its middle under the cursor,
## its underside on whatever the cursor is on (the baseplate, or the top of the
## brick aimed at), kept on the baseplate. x < 0 when the ray finds nothing.
func stamp_target(from: Vector3, dir: Vector3) -> Vector3i:
	var box := stamp_box(_stamp)
	var d: Vector3i = box[1]
	var hit := _first_hit(from, dir)
	var p: Vector3
	var y := 1
	if not hit.is_empty():
		if hit.block >= 0:
			var b: Array = world.get_block_ticks(hit.frame, hit.block)
			@warning_ignore("integer_division")
			y = ((b[0] as Vector3i).y + (b[1] as Vector3i).y) / BrickWorld.ticks_per_plate()
		p = hit.point
	else:
		var t := _plane_distance(asm.frames[0], 1, from, dir)
		if t == INF:
			return Vector3i(-1, -1, -1)
		p = from + dir * t
	@warning_ignore("integer_division")
	var x := int(floor(p.x / BrickPalette.STUD_M)) - d.x / 2
	@warning_ignore("integer_division")
	var z := int(floor(p.z / BrickPalette.STUD_M)) - d.z / 2
	return Vector3i(clampi(x, 0, maxi(plate_studs - d.x, 0)),
			clampi(y, 1, maxi(height_plates - d.y, 1)),
			clampi(z, 0, maxi(plate_studs - d.z, 0)))


## Cell offset for each of the stamp's frames beyond 0, in that frame's own
## grid, for a frame-0 move of `off`. {} if a frame has no standing grid here
## or the move is not a whole number of its cells.
func _frame_offsets(r: BuildRecipe, off: Vector3i) -> Dictionary:
	var out := {}
	var world_ticks := Vector3(off.x * BrickWorld.ticks_per_stud(),
			off.y * BrickWorld.ticks_per_plate(), off.z * BrickWorld.ticks_per_stud())
	for f in range(1, r.frame_count()):
		var af := _asm_frame_for(r.frame_rotation(f), r.frame_ticks(f))
		if af < 0:
			return {}
		var basis: Basis = world.get_chunk_transform(asm.frames[af]).basis
		var lt: Vector3 = basis.inverse() * world_ticks
		var cell := Vector3(lt.x / BrickWorld.ticks_per_stud(),
				lt.y / BrickWorld.ticks_per_plate(), lt.z / BrickWorld.ticks_per_stud())
		var ci := Vector3i(int(round(cell.x)), int(round(cell.y)), int(round(cell.z)))
		if (cell - Vector3(ci)).length() > 0.001:
			return {}
		out[f] = ci
	return out


## Does every brick of the held build go in at `at`?
func _stamp_fits(at: Vector3i) -> bool:
	var off: Vector3i = at - (stamp_box(_stamp)[0] as Vector3i)
	var fo := _frame_offsets(_stamp, off)
	if _stamp.frame_count() > 1 and fo.is_empty():
		return false
	if _stamp.frame_count() > 1 or not _stamp_clear(at):
		if not _stamp_bricks_fit(off, fo):
			return false
	for t in _stamp.towers:
		var c := BuildRecipe.cell_from(t.cell) + off
		var d := TowerBlockout.dims(TowerBlockout.normalised(t.params))
		if c.x < 0 or c.z < 0 or c.x + d.x > plate_studs or c.z + d.z > plate_studs \
				or c.y + d.y > height_plates:
			return false
	return true


## Whether the stamp's box at `at` is inside the area and clear of every grid's bricks. The
## usual case for a whole building in hand, and it saves asking about each of its bricks
## each time the cursor crosses a stud.
func _stamp_clear(at: Vector3i) -> bool:
	var box := stamp_box(_stamp)
	var d: Vector3i = box[1]
	if at.x < 0 or at.y < 0 or at.z < 0 or at.x + d.x > plate_studs or at.z + d.z > plate_studs \
			or at.y + d.y > height_plates:
		return false
	var size := Vector3(BrickPalette.STUD_M, BrickPalette.PLATE_M, BrickPalette.STUD_M)
	var mine := AABB(Vector3(at) * size, Vector3(d) * size)
	for f in asm.frames:
		var held := _frame_box(f)
		if held.has_volume() and mine.intersects((world.get_chunk_transform(f) * held).grow(0.05)):
			return false
	return true


func _stamp_bricks_fit(off: Vector3i, fo: Dictionary) -> bool:
	for i in _stamp.size():
		var rf := _stamp.frame_of(i)
		var af := 0 if rf == 0 else _asm_frame_for(_stamp.frame_rotation(rf), _stamp.frame_ticks(rf))
		var pname := _stamp.part_of(i)
		if af < 0 or not palette.has(pname):
			return false
		var move: Vector3i = off if rf == 0 else fo[rf]
		if not asm.can_place(asm.frames[af], _stamp.cell_of(i) + move, palette[pname]):
			return false
	return true


## Put the held build down: its bricks appended to this recipe in its own
## order, into the world, and one group saying where they came from.
func _commit_stamp() -> bool:
	if _stamp == null or _stamp_at.x < 0:
		return false
	var off: Vector3i = _stamp_at - (stamp_box(_stamp)[0] as Vector3i)
	var fo := _frame_offsets(_stamp, off)
	var first := recipe.size()
	var fix0 := recipe.fixture_count()
	var pl0 := recipe.placements.size()
	var tow0 := recipe.towers.size()
	var weld0 := recipe.weld_count()
	recipe.append(_stamp, off, fo)
	_batch = true
	_realise_appended(first, fix0, tow0, weld0)
	recipe.groups.append({
		"source": _stamp_src, "name": _stamp_label,
		"first": first, "count": recipe.size() - first,
		"turn": _stamp_turn, "offset": [off.x, off.y, off.z],
	})
	undo_stack.push(WkCommand.make(&"stamp",
			{"first": first, "fixtures": fix0, "towers": tow0, "placements": pl0}, _undo_stamp))
	_batch = false
	_stamp_moving = false
	_after_edit()
	# The cells it just filled are not free for the next one.
	_stamp_at = Vector3i(-1, -1, -1)
	print("[workshop] inserted '%s': %d bricks at %v, turned %d" % [
			_stamp_label, recipe.size() - first, off, _stamp_turn])
	return true


## Put into the world whatever was just appended to the recipe: blocks from
## `first`, welds from `weld0`, fixtures from `fix0`, generated buildings from
## `tow0`. The recipe is the record and the world its preview, in one order.
func _realise_appended(first: int, fix0: int, tow0: int, weld0: int) -> void:
	for i in range(first, recipe.size()):
		var rf := recipe.frame_of(i)
		var af := 0 if rf == 0 else _asm_frame_for(recipe.frame_rotation(rf), recipe.frame_ticks(rf))
		var bid := -1
		if af >= 0 and palette.has(recipe.part_of(i)):
			bid = asm.place(asm.frames[af], recipe.cell_of(i), palette[recipe.part_of(i)],
					recipe.colour_of(i))
		if bid >= 0:
			if recipe.material_of(i) != 0:
				world.set_block_material(asm.frames[af], bid, recipe.material_of(i))
			if rf != 0:
				_recipe_frames[af] = rf
		_placed_at.append([af if bid >= 0 else -1, bid])
	for i in range(weld0, recipe.weld_count()):
		var w := recipe.weld_blocks(i)
		var a: Array = _placed_at[w.x]
		var b: Array = _placed_at[w.y]
		if int(a[1]) >= 0 and int(b[1]) >= 0:
			asm.weld(asm.frames[a[0]], a[1], asm.frames[b[0]], b[1])
	for i in range(fix0, recipe.fixture_count()):
		_spawn_fixture(i)
	for i in range(tow0, recipe.towers.size()):
		_spawn_tower(i)


## Undo of a stamp or a bake: everything it added, as one step. Its data: where the recipe's
## lists stood before it -- {first, fixtures, towers, placements, and for a bake the
## generated building it was: tower, tower_index}.
func _undo_stamp(c: WkCommand) -> bool:
	var m: Dictionary = c.data
	_batch = true
	while recipe.fixture_count() > int(m.fixtures):
		if not _undo_fixture(null):
			break
	# Its bricks all at once. One at a time, each is an edit: a remesh of what it touched.
	remove_rids(PackedInt32Array(range(mini(int(m.first), recipe.size()), recipe.size())))
	if m.has("placements"):
		recipe.placements.resize(mini(recipe.placements.size(), int(m.placements)))
	var respawn := false
	while recipe.towers.size() > int(m.towers):
		recipe.towers.pop_back()
		respawn = true
	if m.has("tower"):
		recipe.towers.insert(int(m.tower_index), m.tower)
		respawn = true
	if respawn:
		_respawn_towers()
	_batch = false
	_after_edit()
	return true


# ---------------------------------------------------------------------------
# A generated building (Docs/Workshop.md, Stage C)
# ---------------------------------------------------------------------------
#
# TowerRecipe's parameters held as parameters, previewed as bricks in frame 0 so
# anything can be built onto it, and sized by dragging three handles. The
# bricks are the preview's, not the recipe's: the recipe holds one record and
# the city builds it (TowerBlockout.flatten). Bake makes them the recipe's.

## Frame-0 block ids each generated building laid, one entry per
## recipe.towers entry.
var _tower_blocks := []
## The role each of those was laid with: furniture comes out INTERIOR or DETAIL.
var _tower_roles := []
## The handle being dragged: {"handle", "index", "before", "grab"}.
var _drag := {}
var _handles := {}      ## name -> MeshInstance3D
var _handle_material: StandardMaterial3D
const HANDLE_M := 0.7
const HANDLE_PICK_PX := 22.0


func _tower_limit(cell: Vector3i) -> Vector3i:
	return Vector3i(plate_studs - cell.x, height_plates - cell.y, plate_studs - cell.z)


## Insert > Generated building: three panels by three, two storeys, near the
## baseplate's corner so it has room to be dragged bigger. Three panels is the
## smallest with a stairwell (TowerRecipe.stair_line).
const TOWER_AT := Vector3i(4, 1, 4)
func _add_tower() -> int:
	var p := TowerBlockout.normalised(TowerBlockout.defaults(), _tower_limit(TOWER_AT))
	var at := TOWER_AT
	var i := recipe.add_tower(at, p)
	_spawn_tower(i)
	_record_tower(i, null)
	_after_edit()
	return i


## The generated building the handles and the menu act on: the newest.
func _tower_sel() -> int:
	return recipe.towers.size() - 1


## Lay generated building `i`'s preview bricks into frame 0.
func _spawn_tower(i: int) -> void:
	while _tower_blocks.size() <= i:
		_tower_blocks.append(PackedInt32Array())
	var t: Dictionary = recipe.towers[i]
	var at := BuildRecipe.cell_from(t.cell)
	var p := TowerBlockout.normalised(t.params)
	while _tower_roles.size() <= i:
		_tower_roles.append(PackedByteArray())
	var ids := PackedInt32Array()
	var roles := PackedByteArray()
	var f0: int = asm.frames[0]
	for b in TowerBlockout.bricks(world, palette, p):
		var arch: int = palette.get(b[0], -1)
		if arch < 0:
			continue
		var bid := world.place_block(f0, (b[1] as Vector3i) + at, arch, int(b[2]))
		if bid >= 0:
			if int(b[4]) != 0:
				world.set_block_material(f0, bid, int(b[4]))
			ids.push_back(bid)
			roles.push_back(int(b[3]))
	_tower_blocks[i] = ids
	_tower_roles[i] = roles


func _clear_tower_blocks(i: int) -> void:
	if i < 0 or i >= _tower_blocks.size():
		return
	for id in (_tower_blocks[i] as PackedInt32Array):
		world.remove_block(asm.frames[0], id)
	_tower_blocks[i] = PackedInt32Array()


func _clear_towers() -> void:
	for i in _tower_blocks.size():
		_clear_tower_blocks(i)
	_tower_blocks.clear()
	_tower_roles.clear()


func _respawn_towers() -> void:
	_clear_towers()
	for i in recipe.towers.size():
		_spawn_tower(i)


## Change generated building `i` and rebuild its preview. Does not record undo.
func _set_tower(i: int, cell: Vector3i, params: Dictionary) -> void:
	var p := TowerBlockout.normalised(params, _tower_limit(cell))
	recipe.towers[i] = {"cell": [cell.x, cell.y, cell.z], "params": p}
	_clear_tower_blocks(i)
	_spawn_tower(i)
	_after_edit()


## A change to generated building `i`, as one undo: `before` is the record as it was, or null
## when the edit created it.
func _record_tower(i: int, before, removed := false) -> void:
	var u := {"index": i, "before": before}
	if removed:
		u["removed"] = true
	undo_stack.push(WkCommand.make(&"tower", u, _undo_tower))


func _undo_tower(c: WkCommand) -> bool:
	var u: Dictionary = c.data
	var i := int(u.index)
	if typeof(u.before) == TYPE_NIL:
		if i < recipe.towers.size():
			recipe.towers.remove_at(i)
	elif u.get("removed", false):
		recipe.towers.insert(i, u.before)
	elif i < recipe.towers.size():
		recipe.towers[i] = u.before
	_respawn_towers()
	_after_edit()
	return true


func _set_tower_option(key: String, on: bool) -> void:
	_set_tower_param(key, on)


## Change one parameter of the newest generated building, as one undoable edit.
func _set_tower_param(key: String, value: Variant) -> void:
	var i := _tower_sel()
	if i < 0:
		return
	var before: Dictionary = (recipe.towers[i] as Dictionary).duplicate(true)
	var p: Dictionary = (before.params as Dictionary).duplicate(true)
	p[key] = value
	_set_tower(i, BuildRecipe.cell_from(before.cell), p)
	_record_tower(i, before)


## Generated > Reroll furniture: the same rooms, furnished from another seed.
func _reroll_tower() -> void:
	var i := _tower_sel()
	if i >= 0:
		_set_tower_param("seed", int(TowerBlockout.normalised(recipe.towers[i].params).seed) + 1)


## Insert > Remove generated building.
func _remove_tower() -> void:
	var i := _tower_sel()
	if i < 0:
		return
	var before: Dictionary = (recipe.towers[i] as Dictionary).duplicate(true)
	recipe.towers.remove_at(i)
	_respawn_towers()
	_record_tower(i, before, true)
	_after_edit()


## Insert > Bake: the generated building's preview bricks become the recipe's
## own, to be edited brick by brick. Undo puts the generated building back.
func _bake_tower() -> int:
	var i := _tower_sel()
	if i < 0:
		return 0
	var ids: PackedInt32Array = _tower_blocks[i]
	var roles: PackedByteArray = _tower_roles[i] if i < _tower_roles.size() else PackedByteArray()
	var first := recipe.size()
	var f0: int = asm.frames[0]
	var ts := BrickWorld.ticks_per_stud()
	var tp := BrickWorld.ticks_per_plate()
	var names := TowerBlockout.names_of(palette)
	for k in ids.size():
		var bid := ids[k]
		var box: Array = world.get_block_ticks(f0, bid)
		if box.is_empty():
			continue
		var lo: Vector3i = box[0]
		@warning_ignore("integer_division")
		var cell := Vector3i(lo.x / ts, lo.y / tp, lo.z / ts)
		recipe.add(names.get(world.get_block_archetype(f0, bid), ""), cell,
				world.get_block_colour(f0, bid), 0, roles[k] if k < roles.size() else 0,
				world.get_block_material(f0, bid))
		_placed_at.append([0, bid])
	var rec: Dictionary = recipe.towers[i]
	recipe.towers.remove_at(i)
	_tower_blocks.remove_at(i)   # the bricks stay: they are the recipe's now
	if i < _tower_roles.size():
		_tower_roles.remove_at(i)
	recipe.groups.append({"source": "generated", "name": "generated building",
			"first": first, "count": recipe.size() - first, "turn": 0,
			"offset": rec.cell})
	undo_stack.push(WkCommand.make(&"stamp", {"first": first, "fixtures": recipe.fixture_count(),
			"towers": recipe.towers.size(), "tower": rec, "tower_index": i}, _undo_stamp))
	_after_edit()
	print("[workshop] baked a generated building into %d bricks" % (recipe.size() - first))
	return recipe.size() - first


# --- the handles -------------------------------------------------------------

## Where each handle of generated building `i` is, and which way it pulls.
## {name: [world position, axis]}; "move" slides on the ground, axis ZERO.
func _handle_spots(i: int) -> Dictionary:
	var t: Dictionary = recipe.towers[i]
	var at := BuildRecipe.cell_from(t.cell)
	var d := TowerBlockout.dims(TowerBlockout.normalised(t.params))
	var xf: Transform3D = world.get_chunk_transform(asm.frames[0])
	var o := BrickWorld.grid_to_world(at)
	var s := BrickWorld.grid_to_world(d)
	var gap := HANDLE_M
	return {
		"x": [xf * (o + Vector3(s.x + gap, s.y * 0.5, s.z * 0.5)), Vector3.RIGHT],
		"z": [xf * (o + Vector3(s.x * 0.5, s.y * 0.5, s.z + gap)), Vector3.BACK],
		"y": [xf * (o + Vector3(s.x * 0.5, s.y + gap, s.z * 0.5)), Vector3.UP],
		"move": [xf * (o + Vector3(-gap, HANDLE_M * 0.5, -gap)), Vector3.ZERO],
	}


func _place_handles() -> void:
	var i := _tower_sel()
	if _handle_material == null:
		_handle_material = StandardMaterial3D.new()
		_handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_handle_material.no_depth_test = true
		_handle_material.albedo_color = Color(1.0, 0.62, 0.1)
		_handle_material.render_priority = 10
	if i < 0 or _stamp != null:
		for h in _handles.values():
			(h as Node3D).visible = false
		return
	var spots := _handle_spots(i)
	for hname in spots:
		var h: MeshInstance3D = _handles.get(hname)
		if h == null:
			h = MeshInstance3D.new()
			var bm: Mesh
			if hname == "move":
				bm = SphereMesh.new()
				(bm as SphereMesh).radius = HANDLE_M * 0.5
				(bm as SphereMesh).height = HANDLE_M
			else:
				bm = BoxMesh.new()
				(bm as BoxMesh).size = Vector3.ONE * HANDLE_M
			h.mesh = bm
			h.material_override = _handle_material
			h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(h)
			_handles[hname] = h
		h.visible = true
		h.global_position = spots[hname][0]
		var hot: bool = not _drag.is_empty() and _drag.handle == hname
		h.scale = Vector3.ONE * (1.35 if hot else 1.0)


## The screen point the aim ray goes through: the cursor, or the middle while
## the mouse is captured to look.
func _aim_point() -> Vector2:
	var vp := get_viewport()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return vp.get_visible_rect().size * 0.5
	return vp.get_mouse_position()


## The handle under the aim point, or "".
func _handle_under() -> String:
	var i := _tower_sel()
	if i < 0 or _camera == null:
		return ""
	var m := _aim_point()
	var best := ""
	var best_d := HANDLE_PICK_PX
	var spots := _handle_spots(i)
	for hname in spots:
		var p: Vector3 = spots[hname][0]
		if _camera.is_position_behind(p):
			continue
		var d := _camera.unproject_position(p).distance_to(m)
		if d < best_d:
			best_d = d
			best = hname
	return best


## Handles take the click before anything else does -- ahead of the camera,
## which would otherwise capture the mouse, and of placement.
func _input(e: InputEvent) -> void:
	if _run_on and e is InputEventMouseMotion:
		_run_moved += (e as InputEventMouseMotion).relative.length()
	if _tools != null and _tools.view.input_motion(e):
		get_viewport().set_input_as_handled()
		return
	if not (e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT):
		return
	if _menu != null and _menu.is_modal():
		return
	if _hotbar != null and _hotbar.is_browsing():
		return
	if e.pressed:
		if _stamp != null or _painting or recipe.towers.is_empty():
			return
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
				and _aim_point().y < _menu.bar_height():
			return
		var h := _handle_under()
		if h == "":
			return
		begin_drag(h)
		get_viewport().set_input_as_handled()
	elif not _drag.is_empty():
		end_drag()
		get_viewport().set_input_as_handled()


func begin_drag(handle: String) -> void:
	var i := _tower_sel()
	var t: Dictionary = recipe.towers[i]
	_drag = {"handle": handle, "index": i, "before": t.duplicate(true), "grab": Vector3.ZERO}
	if handle == "move":
		var ray := _mouse_ray()
		var p := _ray_on_ground(ray[0], ray[1], BuildRecipe.cell_from(t.cell).y)
		if p != Vector3.INF:
			_drag.grab = p - BrickWorld.grid_to_world(BuildRecipe.cell_from(t.cell))


func end_drag() -> void:
	if _drag.is_empty():
		return
	var i := int(_drag.index)
	if i < recipe.towers.size() and recipe.towers[i] != _drag.before:
		_record_tower(i, _drag.before)
	_drag = {}


func _drag_process() -> void:
	var ray := _mouse_ray()
	drag_ray(ray[0], ray[1])


## Resize or move the dragged generated building for this aim ray. Split out so
## a probe can drive it with exact rays.
func drag_ray(from: Vector3, dir: Vector3) -> void:
	var i := int(_drag.index)
	if i >= recipe.towers.size():
		_drag = {}
		return
	var t: Dictionary = recipe.towers[i]
	var at := BuildRecipe.cell_from(t.cell)
	var p: Dictionary = (t.params as Dictionary).duplicate()
	var o := BrickWorld.grid_to_world(at)
	var new_at := at
	match str(_drag.handle):
		"x", "z", "y":
			var axis: Vector3 = _handle_spots(i)[_drag.handle][1]
			var along := _closest_on_axis(o, axis, from, dir) - HANDLE_M
			match str(_drag.handle):
				"x": p.x = int(round(along / BrickPalette.STUD_M))
				"z": p.z = int(round(along / BrickPalette.STUD_M))
				"y": p.courses = _courses_for_plates(along / BrickPalette.PLATE_M, p)
		"move":
			var g := _ray_on_ground(from, dir, at.y)
			if g == Vector3.INF:
				return
			var c := g - (_drag.grab as Vector3)
			var d := TowerBlockout.dims(TowerBlockout.normalised(p))
			new_at = Vector3i(
					clampi(int(round(c.x / BrickPalette.STUD_M)), 0, plate_studs - d.x),
					at.y,
					clampi(int(round(c.z / BrickPalette.STUD_M)), 0, plate_studs - d.z))
	var np := TowerBlockout.normalised(p, _tower_limit(new_at))
	if np != TowerBlockout.normalised(t.params) or new_at != at:
		_set_tower(i, new_at, np)


## Distance from `o` along `axis` to the point on that line nearest the ray.
static func _closest_on_axis(o: Vector3, axis: Vector3, from: Vector3, dir: Vector3) -> float:
	var w0 := o - from
	var b := axis.dot(dir)
	var den := 1.0 - b * b
	if absf(den) < 0.0001:
		return 0.0
	return (b * dir.dot(w0) - axis.dot(w0)) / den


## The storey count whose height is nearest `plates`.
static func _courses_for_plates(plates: float, p: Dictionary) -> int:
	var best := TowerBlockout.STOREY
	var best_d := INF
	for st in range(1, 40):
		var q := p.duplicate()
		q.courses = st * TowerBlockout.STOREY
		var h := TowerBlockout.dims(TowerBlockout.normalised(q)).y
		if absf(h - plates) < best_d:
			best_d = absf(h - plates)
			best = st * TowerBlockout.STOREY
	return best


## Where a ray meets the horizontal plane at plate `y`, or INF.
func _ray_on_ground(from: Vector3, dir: Vector3, y: int) -> Vector3:
	var t := _plane_distance(asm.frames[0], y, from, dir)
	return from + dir * t if t != INF else Vector3.INF


# ---------------------------------------------------------------------------
# Groups: an inserted build, as one thing (Docs/Workshop.md, Stage G)
# ---------------------------------------------------------------------------

var _selected := -1          ## index into recipe.groups, or -1
var _sel_box: MeshInstance3D
var _stamp_moving := false   ## the build in hand was lifted out of this one


## X: the group of the brick aimed at, or nothing. Again on the same group lets
## it go.
func select_group_ray(from: Vector3, dir: Vector3) -> int:
	var hit := _first_hit(from, dir)
	var g := -1
	if not hit.is_empty():
		var rid := _recipe_id_at(asm.frames.find(hit.frame), hit.block)
		if rid >= 0:
			g = recipe.group_of(rid)
	_select_group(-1 if g == _selected else g)
	if _selected >= 0:
		var gr: Dictionary = recipe.groups[_selected]
		print("[workshop] selected '%s' (%d bricks): M move, C copy, DEL delete"
				% [gr.get("name", "group"), int(gr.count)])
	return _selected


func _select_group(g: int) -> void:
	_selected = g if g >= 0 and g < recipe.groups.size() else -1
	if _sel_box == null:
		_sel_box = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.no_depth_test = true
		m.vertex_color_use_as_albedo = true
		_sel_box.material_override = m
		add_child(_sel_box)
	_sel_box.visible = _selected >= 0
	if _selected < 0:
		return
	var gr: Dictionary = recipe.groups[_selected]
	var sub := recipe.extract(int(gr.first), int(gr.count))
	var b := sub.bounds()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var lo := BrickWorld.grid_to_world(b[0])
	var size := BrickWorld.grid_to_world(b[1])
	_wire_box(im, lo + size * 0.5, size + Vector3.ONE * 0.04, Color(1.0, 0.85, 0.2))
	im.surface_end()
	_sel_box.mesh = im
	_sel_box.transform = world.get_chunk_transform(asm.frames[0])


## Take group `g`'s bricks out of the build and the world, as one undoable
## edit. Returns them as a recipe in their own cells.
func _lift_group(g: int) -> BuildRecipe:
	var gr: Dictionary = (recipe.groups[g] as Dictionary).duplicate(true)
	var first := int(gr.first)
	var count := int(gr.count)
	var sub := recipe.extract(first, count)
	sub.name = str(gr.get("name", "group"))
	_batch = true
	remove_rids(PackedInt32Array(range(first, first + count)))
	# remove_many dropped the group with its last brick; make sure.
	for k in range(recipe.groups.size() - 1, -1, -1):
		if int(recipe.groups[k].count) <= 0:
			recipe.groups.remove_at(k)
	_batch = false
	undo_stack.push(WkCommand.make(&"ungroup", {"recipe": sub, "group": gr}, _undo_ungroup))
	_select_group(-1)
	_after_edit()
	return sub


## One recipe block out of the middle: world, recipe, placement list and the undo history
## (its edit forgotten, every id after it moved down), all renumbered together (as RMB does).
func _remove_rid(rid: int) -> void:
	_before_remove(rid)
	_forget_rids(PackedInt32Array([rid]))
	var at: Array = _placed_at[rid]
	if int(at[0]) >= 0:
		world.remove_block(asm.frames[at[0]], at[1])
	_placed_at.remove_at(rid)
	_rid_synced = mini(_rid_synced, rid)
	recipe.remove_at(rid)


## `_remove_rid` for many at once, any order. One pass, not one for each: a building is
## tens of thousands.
func remove_rids(rids: PackedInt32Array) -> void:
	if rids.is_empty():
		return
	var ids := rids.duplicate()
	ids.sort()
	var unique := PackedInt32Array()
	for id in ids:
		if id >= 0 and id < _placed_at.size() and (unique.is_empty() or unique[unique.size() - 1] != id):
			unique.push_back(id)
	if unique.is_empty():
		return
	_forget_rids(unique)
	var kept := []
	var g := 0
	for i in _placed_at.size():
		if g >= unique.size() or unique[g] != i:
			kept.append(_placed_at[i])
			continue
		var at: Array = _placed_at[i]
		if int(at[0]) >= 0:
			world.remove_block(asm.frames[at[0]], at[1])
		g += 1
	_placed_at = kept
	_rid_synced = mini(_rid_synced, ids[0])
	recipe.remove_many(unique)


## Undo of a delete (or of the lifting half of a move): the bricks go back
## where they were, on the END of the build -- the middle is append-only -- and
## the group comes back with them.
func _undo_ungroup(c: WkCommand) -> bool:
	var u: Dictionary = c.data
	var sub: BuildRecipe = u.recipe
	var first := recipe.size()
	var weld0 := recipe.weld_count()
	recipe.append(sub, Vector3i.ZERO, _identity_frames(sub))
	_batch = true
	_realise_appended(first, recipe.fixture_count(), recipe.towers.size(), weld0)
	var gr: Dictionary = u.group
	gr.first = first
	gr.count = recipe.size() - first
	recipe.groups.append(gr)
	_batch = false
	_after_edit()
	return true


## Zero offset for every frame beyond 0: a lifted group goes back where it was.
static func _identity_frames(r: BuildRecipe) -> Dictionary:
	var out := {}
	for f in range(1, r.frame_count()):
		out[f] = Vector3i.ZERO
	return out


## DEL: the selected group, gone. Undo brings it back.
func delete_group() -> bool:
	if _selected < 0:
		return false
	var sub := _lift_group(_selected)
	print("[workshop] deleted '%s' (%d bricks)" % [sub.name, sub.size()])
	return true


## M: pick the selected group up to put somewhere else. Cancelling (RMB) puts
## it back where it was.
func move_group() -> bool:
	if _selected < 0:
		return false
	var gr: Dictionary = recipe.groups[_selected]
	var src := str(gr.get("source", ""))
	var sub := _lift_group(_selected)
	hold_stamp(sub, src)
	_stamp_moving = true
	return true


## C: a copy of the selected group in hand; the original stays.
func copy_group() -> bool:
	if _selected < 0:
		return false
	var gr: Dictionary = recipe.groups[_selected]
	var sub := recipe.extract(int(gr.first), int(gr.count))
	sub.name = str(gr.get("name", "group"))
	hold_stamp(sub, str(gr.get("source", "")))
	return true


## RMB with a build in hand: drop it, and if it was being MOVED, put it back.
func _abort_stamp() -> void:
	var moving := _stamp_moving
	_cancel_stamp()
	_stamp_moving = false
	if moving and undo_stack.top_kind() == &"ungroup":
		undo_stack.undo()


# ---------------------------------------------------------------------------
# Room template guide (Docs/Workshop.md, Stage E)
# ---------------------------------------------------------------------------
#
# A template furnishes every generated room its furniture FITS (studs across,
# studs deep, plates high, either way round). The guide is a real city room's
# floor, drawn on the baseplate, so the author can see what they are filling.

## The room sizes the city's shapes actually cut, commonest first
## (RoomManifest.rooms_for over city_scene's SHAPES and BIG_SHAPES).
const ROOM_GUIDES := [Vector3i(25, 18, 25), Vector3i(15, 18, 25),
		Vector3i(15, 18, 15), Vector3i(25, 18, 5), Vector3i(5, 18, 5)]
const GUIDE_AT := Vector3i(4, 1, 4)
var _guide_i := 0
var _guide: MeshInstance3D


func _cycle_guide() -> void:
	if recipe.kind != "room":
		return
	_guide_i = (_guide_i + 1) % ROOM_GUIDES.size()
	_update_guide()


func _update_guide() -> void:
	if _guide == null:
		_guide = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		_guide.material_override = m
		add_child(_guide)
	_guide.visible = recipe.kind == "room"
	if not _guide.visible:
		return
	var d: Vector3i = ROOM_GUIDES[_guide_i]
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var lo := BrickWorld.grid_to_world(GUIDE_AT)
	var size := BrickWorld.grid_to_world(d)
	_wire_box(im, lo + size * 0.5, size, Color(0.45, 1.0, 0.6))
	im.surface_end()
	_guide.mesh = im
	_guide.transform = world.get_chunk_transform(asm.frames[0])


## The furniture's size, and which of the city's room sizes it fits.
func _guide_text() -> String:
	var g: Vector3i = ROOM_GUIDES[_guide_i]
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	var any := false
	for i in recipe.size():
		if recipe.frame_of(i) != 0 or recipe.role_of(i) == BuildRecipe.Role.STRUCTURE:
			continue
		var c := recipe.cell_of(i)
		var sz := BuildRecipe.part_size(recipe.part_of(i))
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x + sz.x), maxi(hi.y, c.y + sz.y), maxi(hi.z, c.z + sz.z))
		any = true
	var head := "room guide %dx%d studs, %d plates high (U)" % [g.x, g.z, g.y]
	if not any:
		return head + " -- build the furniture on the Interior / Detail layers"
	var f := hi - lo
	var fits := PackedStringArray()
	for r in ROOM_GUIDES:
		if f.y <= r.y and ((f.x <= r.x and f.z <= r.z) or (f.z <= r.x and f.x <= r.z)):
			fits.append("%dx%d" % [r.x, r.z])
	return "%s -- furniture %dx%dx%d fits: %s" % [head, f.x, f.z, f.y,
			", ".join(fits) if not fits.is_empty() else "NO city room"]
