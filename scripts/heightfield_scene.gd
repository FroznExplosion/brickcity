extends Node3D

## Heightfield terrain test scene.
##
##     godot --path . scenes/heightfield_test.tscn
##     godot --path . scenes/heightfield_test.tscn -- --shot
##
## The simple terrain, deliberately: a plate-quantised heightmap, no voxels,
## no caves, no destruction. [Docs/Terrain.md](../Docs/Terrain.md) §17 chose
## volumetric and this takes that back — see §17.1 for what it gives up
## (overhangs, digging, undercut cliffs that fall) and §17.22 for why.
##
## It shares everything above the field with `terrain_test.tscn`: the same
## packer, the same 2x4-dominant mix, the same stud tiers, the same collision
## merge. `BrickTerrain.set_flat_mode(true)` only changes what `solid_at`
## answers, so nothing downstream knows the difference.
##
## What it is here to show:
##
##   1. brick ground from a heightfield, with terraces and no slopes
##   2. studs on the flat parts and nowhere else
##   3. TILES laid on top of some of those studs — a smooth piece clipped onto
##      a studded surface, which is the thing a brick floor actually looks
##      like and what the studded-everywhere version was missing
##
## Keys: F1 seams · F2 painted studs · F3 contact shadows ·
##       F4 stud geometry + scatter · F5 tiles-on-studs · Space walk/fly ·
##       H disasters (the hurricane; Shift+H ends it)

## 5x5 tiles = 160 studs = 56 m square. `-- --tiles=N` overrides it, which
## is how the view-distance numbers in Terrain.md 19 were measured.
const TILES_DEFAULT := 5
static var TILES := TILES_DEFAULT

## How far the FULL tier reaches, in tiles either side of the camera. Beyond
## it the ground is coarse blocks. `-- --far=N` sets the coarse reach.
## 4 tiles is a 101 m square of FULL detail — packed pieces, studs, scatter,
## collider. Beyond it the coarse tier takes over, and at 56 m (the old
## value) that handover was close enough to read as "the ground went smooth",
## which is exactly how it was reported. `-- --near=N` overrides it.
static var NEAR_TILES := 4
## Coarse reach, in tiles either side. 0 disables the far tier.
##
## 50 tiles is 560 m, ten times the detailed square, and it costs 2.3x the
## frame (§19.4). On by default because the terrain can afford it — the city
## is the half that cannot (§19.5).
static var FAR_TILES := 50
## The FIRST coarse ring: block size in tiles, and studs between samples.
## Both DOUBLE with every ring outward, which is the whole reason distance is
## affordable — see _build_far.
const FAR_SPAN := 4
const FAR_STEP := 4
## Where ring 0 ends, in tiles. Each ring after it reaches twice as far.
const FAR_FIRST := 16
## How many doublings are allowed. Six reaches 5.6 km from a 4-tile block.
const FAR_LEVELS := 6
const WORLD_SEED := 20260921
const DRY_AMBIENT := 0.6
## Preloaded rather than reached for by class name: a brand new `class_name`
## is not in the global class cache until the editor has rescanned, and a
## headless run reads that cache off disk.
const UnderwaterFx := preload("res://scripts/underwater.gd")
## The generator's floor is barely under the default 1.1 m sea, which gives
## puddles rather than a coast. See terrain_scene.gd.
##
## Measured for THIS seed, inland: 1.9 m floods 3% of the field and the
## deepest water is 8 cm. 2.8 m floods ~40% and gets to 1.3 m, which is a
## coast. The number is a property of the seed, not of the water.
## How much of the world is under water. World.sea_level_for.
const DROWNED := World.DEFAULT_DROWNED
## Preloaded, not reached for by class name: a new `class_name` is not in the
## global class cache until the editor rescans, and a headless run reads that
## cache off disk. Same reason as UnderwaterFx.
const World := preload("res://scripts/terrain_world.gd")

var _tiles: Array[TerrainTile] = []
## The sea, as one node (water_sea.gd): the three tiers, the seabed they share,
## and the brick tiers shown only where there is water to draw.
const WaterSeaScript := preload("res://scripts/water_sea.gd")
var _sea = null
## Its tiers, by the names the bench and the toggles have always used.
var _water: WaterSurface = null
var _water_far: WaterSurface = null
var _water_sheet = null
## THE LEVEL EDITOR lives in this scene (Docs/Terrain.md §20.9): the tools are
## a node on top of the same terrain, far tier, water and sites, so what is
## edited is exactly what is looked at. `scenes/terrain_editor.tscn` is this
## scene under its old name.
const EditTools := preload("res://scripts/terrain_editor.gd")
var _editor = null
var _edit_shot := false
## The level: which file, which seed, how much of it is sea.
var _world_path := ""
var _seed := WORLD_SEED
var _drowned := DROWNED
var _load_status := ""
## L: tint the ground and the sea by LOD level.
var _lod_debug := false
## F10: the dev menu (terrain_dev_menu.gd). Freeze LOD lives here so the
## scene can hold its tiers still while the camera flies over to a border.
const DevMenu := preload("res://scripts/terrain_dev_menu.gd")
var _dev_menu = null
var _lod_frozen := false
var _frozen_at := Vector3.ZERO
var _hud_layer: CanvasLayer = null
var _env: Environment = null
var _under := UnderwaterFx.new()
var _camera: DebugCamera = null
## The same camera, under the name the disaster context reads (a city's).
var camera: DebugCamera = null
## Weather for the coast (Docs/Disasters.md 18): the hurricane, and whatever
## else needs no buildings. H opens it, as in the city.
var disasters: DisasterDirector = null
var _sun: DirectionalLight3D = null
var _mat: ShaderMaterial = null
var _label: Label = null

var _shot_mode := false
var _bench_mode := false
var _build_ms := 0.0
var _bake_ms := 0.0
var _streamer: TerrainStreamer = null
var _far_nodes: Array[MeshInstance3D] = []
var _far_rects: Array[Rect2i] = []
var _far_hidden := 0
var _far_tris := 0
var _far_blocks := 0
var _far_rings := 0
var _sites: Array[MeshInstance3D] = []
var _trees: TerrainTrees = null
## Every coarse block's tile rect, and which node draws it (-1 = a merged
## ring, which is always drawn). The coverage check needs both.
var _all_rects: Array[Rect2i] = []
## Each block's sample step, beside its rect: an edit re-bakes a block at the
## step it was built with.
var _all_steps: Array[int] = []
## The camera tile the small far blocks were last re-LODded for.
var _relod_at := Vector2i(1 << 30, 0)
var _all_owner: Array[int] = []
## Block index -> its own node, for blocks that have one.
var _all_node := {}
## span -> the block indices in that ring, and the ring's mesh node.
var _ring_members := {}
var _ring_nodes := {}
var _frame_ms := 0.0
var _show_instances := true

var _toggles := {
	"seams_enabled": true,
	"studs_enabled": true,
	"stud_shadows_enabled": true,
	"chamfer_enabled": true,
	"print_lines_enabled": true,
}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--shot":
			_shot_mode = true
		elif arg.begins_with("--tiles="):
			TILES = maxi(1, int(arg.split("=")[1]))
		elif arg == "--bench":
			_bench_mode = true
		elif arg.begins_with("--far="):
			FAR_TILES = maxi(0, int(arg.split("=")[1]))
		elif arg.begins_with("--near="):
			NEAR_TILES = maxi(1, int(arg.split("=")[1]))
		elif arg == "--editshot":
			_edit_shot = true

	# The whole difference between this scene and the volumetric one.
	BrickTerrain.set_flat_mode(true)
	# Half-brick steps: the relief cut into plates (0.14 m) rather than
	# bricks (0.42 m), so a slope is three shallower stairs instead of one.
	BrickTerrain.set_plate_steps(true)
	# Curved ground is OFF by default, on C.
	#
	# It works — regional, genuinely curved, studs and tiles standing on it
	# (§18.5) — but curved ground has no PIECES in it, so wherever it goes
	# the packed 2x4s and the smooth tiles go with it, and this scene is
	# here to look at laid brick. It is a thing the generator can do, not
	# the ground the game is made of.
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.configure(WORLD_SEED)
	# The world file first — pads, painted material, sculpt and building
	# sites — and the generator's default sites only if this level has never
	# been edited. `-- --world=<name>` picks the level.
	_world_path = World.world_path()
	var loaded := World.load_world(_world_path)
	var file_seed := int(loaded.get("seed", WORLD_SEED))
	if not loaded.is_empty() and file_seed != 0 and file_seed != WORLD_SEED:
		# Loaded against the wrong field: the sea and every pad height were
		# read off ground this world is not. Again, on its own.
		_seed = file_seed
		BrickTerrain.configure(_seed)
		loaded = World.load_world(_world_path)
	if loaded.is_empty():
		World.stamp_sites(DROWNED)
		_load_status = "no world file; seeded from TerrainWorld.SITES"
	else:
		_drowned = float(loaded.get("drowned", DROWNED))
		_load_status = "loaded %s" % _world_path
	# Shaded chamfer only. The geometry tier is what six rounds of artefacts
	# were about (§17.21); the shaded bevel has never produced one and is
	# measured at 7.6% of pixels changed.
	TerrainTile.bevel_enabled = false

	# The sea was chosen from the terrain by loading the world, before its
	# pads were cut — TerrainWorld.sea_level, the one every scene agrees on.
	_build_scenery()
	# The sun, for BAKED shadows, taken FROM THE LIGHT so the two can never
	# disagree: a light rotated after the bake would leave the ground shaded
	# for a sun that is not there. A DirectionalLight3D shines along its own
	# -Z, so +Z points at the sun (§19.7).
	BrickTerrain.set_sun_direction(_sun.global_transform.basis.z)
	_build_terrain()
	_build_water()
	_build_sites()
	# Brick trees (TerrainTrees, Docs/Impostors.md 8). Not in a bench: it
	# measures the terrain, and its numbers are compared across months.
	if not _bench_mode and not "--no-trees" in OS.get_cmdline_user_args():
		_trees = TerrainTrees.new()
		_trees.name = "Trees"
		add_child(_trees)
		_trees.setup(_camera, _brick_material())
		var half := maxi(FAR_TILES, NEAR_TILES) * BrickTerrain.get_tile_studs()
		_trees.build(Rect2i(-half, -half, half * 2, half * 2), _seed)
	# The editing tools, on everything above. Not in a bench or a capture:
	# those measure and photograph the terrain, not an editor's markers.
	if not _bench_mode and not _shot_mode:
		_editor = EditTools.new()
		_editor.name = "Editor"
		add_child(_editor)
		_editor.setup(self)
	if not _bench_mode and not _shot_mode:
		disasters = DisasterDirector.new()
		disasters.name = "Disasters"
		add_child(disasters)
		disasters.setup(self, ["hurricane"])
	_update_hud()
	if _bench_mode:
		_run_bench()
	elif _shot_mode:
		_run_shots()


func _build_scenery() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.54, 0.78)
	sky_mat.sky_horizon_color = Color(0.74, 0.80, 0.84)
	sky_mat.ground_bottom_color = Color(0.28, 0.30, 0.28)
	sky_mat.ground_horizon_color = Color(0.74, 0.80, 0.84)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = DRY_AMBIENT
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	# 30 degrees, not 44.
	#
	# Measured against this terrain: at 44 degrees the sun clears everything
	# and NOTHING is in shadow — the steepest ground is a 42-degree slope —
	# so the baked shadow was a no-op and the hills read as flat lighting.
	# At 30 it is 8% of columns, at 12 it is 26%. A raking sun is also what
	# makes a brick surface read as brick.
	_sun.rotation_degrees = Vector3(-30, -36, 0)
	_sun.light_energy = 1.15
	# The GROUND bakes its own sun shadow, so it never casts — but the light
	# still needs a shadow map for everything that stands ON the ground.
	_sun.shadow_enabled = true
	add_child(_sun)

	_camera = DebugCamera.new()
	_camera.name = "DebugCamera"
	_camera.capture_mouse = not _shot_mode
	_camera.allow_walk = not _shot_mode
	# The clip plane has to clear the far tier or the ground stops in mid-air
	# at 600 m whatever the LOD does.
	_camera.far = maxf(600.0, _far_metres() + 200.0)
	_camera.position = Vector3(-8.0, 7.0, -8.0)
	_camera.rotation = Vector3(-0.38, -2.36, 0.0)
	add_child(_camera)
	camera = _camera

	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.position = Vector2(14, 12)
	_label.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(_label)
	add_child(layer)
	_hud_layer = layer


func _build_terrain() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/terrain.gdshader")
	WeatherFx.register(_mat)
	_mat.set_shader_parameter("stud_pitch", BrickWorld.get_stud_metres())
	_mat.set_shader_parameter("stud_radius", PieceMeshes.STUD_R)
	_mat.set_shader_parameter("stud_height", PieceMeshes.STUD_H)
	for key in _toggles:
		_mat.set_shader_parameter(key, _toggles[key])
	_mat.set_shader_parameter("sun_dir", -_sun.global_transform.basis.z)

	var t0 := Time.get_ticks_usec()

	# The detailed tier STREAMS around the camera (§19.6). The world is a
	# fixed authored size, so `world_half` is a real edge and not a pretence
	# of infinity — nothing is built past it.
	_streamer = TerrainStreamer.new()
	_streamer.name = "Streamer"
	_streamer.near_radius = NEAR_TILES
	_streamer.keep_radius = NEAR_TILES + 2
	_streamer.world_half = maxi(FAR_TILES, NEAR_TILES)
	add_child(_streamer)
	_streamer.setup(_mat)
	# A capture or a bench must not photograph a half-built world.
	_streamer.settle(Vector2(_camera.position.x, _camera.position.z))
	_tiles.assign(_streamer.tiles())
	_bake_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	_build_far()
	_hide_covered_far()
	_build_ms = float(Time.get_ticks_usec() - t0) / 1000.0


## The coarse tier: everything from the full tiles out to FAR_TILES, as
## blocks of FAR_SPAN x FAR_SPAN tiles, one mesh and one draw call each.
##
## Baked in parallel like the near tier, and for the same reason — it is C++
## that only reads the field.
static func _ring_blocks_total(spans: Array[int]) -> int:
	var n := 0
	for v in spans:
		if v > 1:
			n += 1
	return n


## The same surface, moved. A merged ring holds blocks from all over the
## world in one mesh, so their vertices have to carry the offset the node
## transform used to.
static func _offset_surface(arrays: Array, origin: Vector3) -> Array:
	var out := arrays.duplicate(true)
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += origin
	out[Mesh.ARRAY_VERTEX] = verts
	return out


## Build, or rebuild, one ring's mesh from the blocks still belonging to it.
##
## A ring is one mesh holding blocks from all over the world, which is what
## takes the draw calls from 832 to 371 at 4.5 km — and it means a block
## cannot be removed from the world without rebuilding the ring around it.
## That happens when the detail walks into a block and it has to be split.
## Rare, and a ring is ~48 blocks, so it re-bakes in parallel in a few
## milliseconds.
func _rebuild_ring(span: int) -> void:
	var members: Array[int] = _ring_members.get(span, [] as Array[int])
	var live: Array[int] = []
	for i in members:
		if _all_owner[i] != -2:
			live.append(i)
	var baked: Array[Dictionary] = []
	baked.resize(live.size())
	if not live.is_empty():
		var task := WorkerThreadPool.add_group_task(
			func(k: int) -> void:
				baked[k] = BrickTerrain.build_coarse(_all_rects[live[k]].position.x,
					_all_rects[live[k]].position.y, span,
					_all_steps[live[k]]),
			live.size(), -1, true, "coarse ring")
		WorkerThreadPool.wait_for_group_task_completion(task)

	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	var mesh := ArrayMesh.new()
	for k in live.size():
		var arrays: Array = baked[k]["mesh"]
		if arrays.is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			_offset_surface(arrays, Vector3(_all_rects[live[k]].position.x * tile_studs * stud,
				0.0, _all_rects[live[k]].position.y * tile_studs * stud)),
			[], {}, TerrainTile.CUSTOM0_FLAGS)
	if _ring_nodes.has(span):
		(_ring_nodes[span] as MeshInstance3D).queue_free()
	var mi := MeshInstance3D.new()
	mi.name = "CoarseRing_%d" % span
	mi.mesh = mesh
	mi.material_override = _mat
	@warning_ignore("integer_division")
	mi.set_instance_shader_parameter("lod_level", _lod_of_step(FAR_STEP * span / FAR_SPAN))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_ring_nodes[span] = mi


## Split any coarse block the detail has walked into, down to the lattice
## the detail is aligned on.
##
## The rings are laid out from the ORIGIN, so a block far out is 16, 64 or
## 128 tiles across — and the detail square is 12. Wherever the camera walks
## far from the origin it lands INSIDE a block that is too big to hide, and
## the two tiers draw the same ground. The coverage check found 121 tiles
## like that; before the check existed, nobody found them at all.
##
## A quadtree split is the answer and it is cheap because it is local: only
## the children that actually touch the detail recurse, so a 128-tile block
## becomes about fifteen smaller ones rather than a thousand. Refined blocks
## are kept — walking back and forth over the same ground bakes once.
func _refine_for(detail: Rect2i) -> void:
	var todo: Array[int] = []
	for i in _all_rects.size():
		if _all_rects[i].size.x <= _streamer.align:
			continue
		if _all_owner[i] == -2:
			continue                      # already split
		if _all_rects[i].intersects(detail):
			todo.append(i)
	if todo.is_empty():
		return

	var new_rects: Array[Rect2i] = []
	var dirty_rings := {}
	for i in todo:
		_split(_all_rects[i], detail, new_rects)
		# A block that came from an EARLIER split is in `_far_nodes` too, and
		# freeing it without letting go of it there left `_hide_covered_far`
		# setting `visible` on a freed node the next frame -- the crash
		# flying out over the far ground found.
		if _all_owner[i] >= 0:
			_far_nodes[_all_owner[i]] = null
		_all_owner[i] = -2                # retired; its children cover it
		if _all_node.has(i):
			(_all_node[i] as MeshInstance3D).queue_free()
			_all_node.erase(i)
		else:
			dirty_rings[_all_rects[i].size.x] = true
	for span in dirty_rings:
		_rebuild_ring(span)
	if new_rects.is_empty():
		return

	# Bake the children in parallel, like everything else that reads the
	# field and nothing else.
	var baked: Array[Dictionary] = []
	baked.resize(new_rects.size())
	var task := WorkerThreadPool.add_group_task(
		func(k: int) -> void:
			@warning_ignore("integer_division")
			baked[k] = BrickTerrain.build_coarse(new_rects[k].position.x,
				new_rects[k].position.y, new_rects[k].size.x,
				FAR_STEP * (new_rects[k].size.x / FAR_SPAN)),
		new_rects.size(), -1, true, "coarse refine")
	WorkerThreadPool.wait_for_group_task_completion(task)

	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	for k in new_rects.size():
		var arrays: Array = baked[k]["mesh"]
		if arrays.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				TerrainTile.CUSTOM0_FLAGS)
		var mi := MeshInstance3D.new()
		mi.name = "CoarseSplit_%d_%d" % [new_rects[k].position.x, new_rects[k].position.y]
		mi.mesh = mesh
		mi.material_override = _mat
		@warning_ignore("integer_division")
		mi.set_instance_shader_parameter("lod_level",
				_lod_of_step(FAR_STEP * (new_rects[k].size.x / FAR_SPAN)))
		mi.position = Vector3(new_rects[k].position.x * tile_studs * stud, 0.0,
				new_rects[k].position.y * tile_studs * stud)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_all_rects.append(new_rects[k])
		@warning_ignore("integer_division")
		_all_steps.append(FAR_STEP * (new_rects[k].size.x / FAR_SPAN))
		_all_owner.append(_far_nodes.size())
		_all_node[_all_rects.size() - 1] = mi
		_far_nodes.append(mi)
		_far_rects.append(new_rects[k])
		_far_tris += int(baked[k]["triangle_count"])
		_far_blocks += 1


## Four children, and only the ones that touch the detail split again.
func _split(rect: Rect2i, detail: Rect2i, out: Array[Rect2i]) -> void:
	@warning_ignore("integer_division")
	var h := rect.size.x / 2
	for dz in [0, h]:
		for dx in [0, h]:
			var child := Rect2i(rect.position + Vector2i(dx, dz), Vector2i(h, h))
			if h > _streamer.align and child.intersects(detail):
				_split(child, detail, out)
			else:
				out.append(child)


## The field changed over these studs (an edit): make everything that was
## baked from it agree again.
##
## The detailed tier is the editor's to refresh -- it knows which tiles its
## brush is under. This is the rest: the coarse blocks over the rectangle,
## re-baked at the step each was built with (a merged ring as a whole, since
## a ring is one mesh), and the seabed the water reads its shore from.
func terrain_changed(studs: Rect2i) -> void:
	if _trees != null:
		_trees.rebuild_soon(studs)
	var tile := BrickTerrain.get_tile_studs()
	var lo := Vector2i(floori(float(studs.position.x) / tile), floori(float(studs.position.y) / tile))
	var hi := Vector2i(floori(float(studs.end.x) / tile), floori(float(studs.end.y) / tile))
	var tiles := Rect2i(lo, hi - lo + Vector2i.ONE)
	var dirty_rings := {}
	var nodes: Array[int] = []
	for i in _all_rects.size():
		if _all_owner[i] == -2 or not _all_rects[i].intersects(tiles):
			continue
		if _all_node.has(i):
			nodes.append(i)
		else:
			dirty_rings[_all_rects[i].size.x] = true
	var baked: Array[Dictionary] = []
	baked.resize(nodes.size())
	if not nodes.is_empty():
		var task := WorkerThreadPool.add_group_task(
			func(k: int) -> void:
				var r: Rect2i = _all_rects[nodes[k]]
				baked[k] = BrickTerrain.build_coarse(r.position.x, r.position.y,
					r.size.x, _all_steps[nodes[k]]),
			nodes.size(), -1, true, "coarse edit")
		WorkerThreadPool.wait_for_group_task_completion(task)
	for k in nodes.size():
		var arrays: Array = baked[k]["mesh"]
		var mi := _all_node[nodes[k]] as MeshInstance3D
		if arrays.is_empty() or not is_instance_valid(mi):
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				TerrainTile.CUSTOM0_FLAGS)
		mi.mesh = mesh
	for span in dirty_rings:
		_rebuild_ring(span)
	if _sea != null:
		_sea.refresh_seabed(studs)


# ---------------------------------------------------------------------------
# Dev menu hooks (terrain_dev_menu.gd, Terrain.md 20.10)

func _toggle_dev_menu() -> void:
	var opening: bool = _dev_menu == null
	if not opening:
		_dev_menu.queue_free()
		_dev_menu = null
	else:
		# Built fresh each time, so every control shows the state as it is
		# NOW (L pressed, a value changed elsewhere).
		_dev_menu = DevMenu.new()
		_dev_menu.name = "DevMenu"
		_hud_layer.add_child(_dev_menu)
		_dev_menu.setup(self)
		# Under the scene's readout, and never past the window's bottom.
		_dev_menu.fit(300.0)
		if not get_viewport().size_changed.is_connected(_refit_dev_menu):
			get_viewport().size_changed.connect(_refit_dev_menu)
	# The mouse is the menu's while it is open.
	if _camera.has_method("_set_captured"):
		_camera.call("_set_captured", not opening)


func _refit_dev_menu() -> void:
	if _dev_menu != null and is_instance_valid(_dev_menu):
		_dev_menu.fit(300.0)


func set_lod_frozen(on: bool) -> void:
	_lod_frozen = on
	_frozen_at = _camera.global_position


func set_lod_view(on: bool) -> void:
	_lod_debug = on
	_mat.set_shader_parameter("lod_debug", on)
	if _sea != null:
		_sea.set_lod_debug(on)


func set_detail_radius(tiles: int) -> void:
	_streamer.near_radius = tiles
	_streamer.keep_radius = tiles + 2
	if _lod_frozen:
		# One step at the frozen spot, so the change is seen while frozen.
		_streamer.settle(Vector2(_frozen_at.x, _frozen_at.z))
		_hide_covered_far()


## A disaster moves the sea (DisasterContext.set_sea): the sea does it
## (WaterSea.set_surge), as it does in the city.
func disaster_sea(surge: float, wave_mul: float) -> void:
	if _sea != null:
		_sea.set_surge(surge, wave_mul)


func set_water_param(param: String, value: Variant) -> void:
	if _sea == null:
		return
	for tier in [_sea.near, _sea.sheet]:
		if tier != null and tier._mat != null:
			tier._mat.set_shader_parameter(param, value)


## The far tier from scratch: after the smooth step changed, or to see a
## border as the build lays it out.
func rebuild_far() -> void:
	for node in _far_nodes:
		if node != null and is_instance_valid(node):
			node.queue_free()
	for span in _ring_nodes:
		var mi = _ring_nodes[span]
		if is_instance_valid(mi):
			mi.queue_free()
	_far_nodes.clear()
	_far_rects.clear()
	_all_rects.clear()
	_all_steps.clear()
	_all_owner.clear()
	_all_node.clear()
	_ring_members.clear()
	_ring_nodes.clear()
	_far_hidden = 0
	_far_tris = 0
	_far_blocks = 0
	_far_rings = 0
	_build_far()
	var at: Vector3 = _frozen_at if _lod_frozen else _camera.global_position
	_refine_for(_streamer.current_region())
	_hide_covered_far()
	print("[heightfield] far tier rebuilt: %d blocks, %d tris, smooth from step %d (at %s)" % [
		_far_blocks, _far_tris, BrickTerrain.get_coarse_smooth_step(), at])


## THE SMALL FAR BLOCKS FOLLOW THE CAMERA'S LOD (Terrain.md 19.19).
##
## Ring 0 of the far tier is laid out round the world's ORIGIN, and blocks
## split to sit beside the detail are kept once split -- so the ground round
## the origin (where the sites are) and everywhere the camera had passed stayed
## LOD 1, blocky, however far away the camera went. Each such block is re-baked
## at the step its distance from the camera calls for -- the same rings the
## far tier is laid out in, measured from the camera instead of the origin --
## whenever the camera enters a new tile. Smooth past LOD 1, as the rest is.
func _relod_far(at: Vector3) -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var c := Vector2i(floori(at.x / tile_m), floori(at.z / tile_m))
	if c == _relod_at:
		return
	_relod_at = c
	var redo: Array[int] = []
	var want: Array[int] = []
	for i in _all_rects.size():
		if _all_owner[i] < 0 or not _all_node.has(i):
			continue
		var r: Rect2i = _all_rects[i]
		var dx: int = maxi(0, maxi(r.position.x - c.x, c.x - (r.end.x - 1)))
		var dz: int = maxi(0, maxi(r.position.y - c.y, c.y - (r.end.y - 1)))
		var d: int = maxi(dx, dz)
		var level := 0
		while level < FAR_LEVELS - 1 and d >= (FAR_FIRST << level):
			level += 1
		# A block is never sampled coarser than it is wide.
		var step: int = maxi(FAR_STEP << level, 1)
		step = mini(step, r.size.x * BrickTerrain.get_tile_studs())
		if step != _all_steps[i]:
			redo.append(i)
			want.append(step)
	if redo.is_empty():
		return
	var baked: Array[Dictionary] = []
	baked.resize(redo.size())
	var task := WorkerThreadPool.add_group_task(
		func(k: int) -> void:
			var r: Rect2i = _all_rects[redo[k]]
			baked[k] = BrickTerrain.build_coarse(r.position.x, r.position.y, r.size.x, want[k]),
		redo.size(), -1, true, "coarse relod")
	WorkerThreadPool.wait_for_group_task_completion(task)
	for k in redo.size():
		var i: int = redo[k]
		var mi := _all_node[i] as MeshInstance3D
		var arrays: Array = baked[k]["mesh"]
		if not is_instance_valid(mi) or arrays.is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				TerrainTile.CUSTOM0_FLAGS)
		mi.mesh = mesh
		mi.set_instance_shader_parameter("lod_level", _lod_of_step(want[k]))
		_all_steps[i] = want[k]


## A coarse block's LOD level from its sample step: the detailed tiles are 0,
## a block sampled every FAR_STEP studs is 1, and each doubling one more.
## A float, because the shader's `lod_level` is one: an int handed to a float
## instance uniform is dropped without a word, and every block read as 0.
static func _lod_of_step(step: int) -> float:
	return float(1 + maxi(0, roundi(log(float(step) / float(FAR_STEP)) / log(2.0))))


## A coarse block under the detailed tier is hidden.
##
## The coarse tier is built once for the whole world and never rebuilt, so
## without this the detail simply streams in ON TOP of it — two surfaces in
## the same place, the coarse one poking through wherever its max-of-cell
## height beats the real ground. Reported as "the LOD never goes away when
## you walk up to it", which is exactly what it was.
##
## Both tiers are on the same 4-tile lattice, so a block is covered or it is
## not; there is no partial case to get wrong.
func _hide_covered_far() -> void:
	if _far_nodes.is_empty():
		return
	_refine_for(_streamer.current_region())
	_far_hidden = 0
	for i in _far_nodes.size():
		if _far_nodes[i] == null:
			continue                      # retired by a later split
		var rect := _far_rects[i]
		# Only the smallest blocks can ever be covered — anything bigger is
		# further out than the detail reaches — so only they are checked,
		# and a 128-tile block never walks its tiles.
		var covered := rect.size.x <= _streamer.align
		if covered:
			for dz in rect.size.y:
				for dx in rect.size.x:
					var c := rect.position + Vector2i(dx, dz)
					# Outside the authored world counts as covered: there is
					# nothing there for the detail to build, and a block
					# waiting for tiles that will never exist stayed visible
					# under real detail at the world's rim.
					if absi(c.x) > FAR_TILES or absi(c.y) > FAR_TILES:
						continue
					if not _streamer.has_tile(c):
						covered = false
						break
				if not covered:
					break
		_far_nodes[i].visible = not covered
		if covered:
			_far_hidden += 1


## How far the coarse tier reaches, in metres.
static func _far_metres() -> float:
	return float(FAR_TILES * BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()


func _build_far() -> void:
	if FAR_TILES <= 0:
		return
	# NO HOLE. The coarse tier covers the whole world, including under the
	# detail, and blocks are HIDDEN where detail covers them.
	#
	# Leaving a hole where the detail starts is the obvious saving and it is
	# wrong: the detail moves and the hole does not, so walking away from
	# the origin left a black pit behind. Coverage is a property of where
	# the camera IS, so it has to be decided every frame, not at build.
	@warning_ignore("integer_division")

	# CASCADED BLOCKS: the further out, the bigger the block and the coarser
	# the samples inside it.
	#
	# One coarse level at a fixed 1.4 m sample does not scale, and the
	# numbers said so plainly: 560 m held 2.9M triangles, 1.1 km held 10.7M,
	# and 2.2 km held 40.9M and drew at 80 ms. Constant density over a disc
	# is quadratic in the radius, and no amount of culling fixes quadratic.
	#
	# Doubling the sample spacing every time the radius doubles makes each
	# ring cost the SAME as the one inside it — a block always holds the
	# same (span x TILE / step)^2 cells — so the tier is linear in the
	# NUMBER of rings, which is logarithmic in distance.
	#
	# The placement is a greedy fill rather than a lattice sweep: walk every
	# uncovered tile, ask which ring its radius puts it in, and lay the
	# LARGEST aligned block that fits there, halving until one does. Two
	# attempts at "place blocks ring by ring and skip the ones that overlap"
	# both left bands a whole block wide — a tile exactly on a ring boundary
	# belongs to neither sweep — and 2,500 one-tile fills with it. A fill
	# that always terminates at span 1 cannot leave a hole.
	var blocks: Array[Vector2i] = []
	var spans: Array[int] = []
	var steps: Array[int] = []
	var covered := {}

	# The edge of the field, rounded UP to the coarsest lattice.
	#
	# A block has to fit entirely inside the reach or it is refused and the
	# fill falls back a level, so a reach that is not a multiple of the
	# biggest span frays the whole rim down to one-tile blocks: at 9 km that
	# was 3,212 of them. Rounding up draws a little more ground than asked
	# for, which costs one row of blocks and nothing else.
	# Only as many doublings as the reach actually needs: rounding a 560 m
	# field up to the six-level lattice drew 1.4 km of ground nobody asked
	# for.
	var levels := 1
	while (FAR_FIRST << (levels - 1)) < FAR_TILES and levels < FAR_LEVELS:
		levels += 1
	var coarsest: int = FAR_SPAN << (levels - 1)
	var reach: int = int(ceil(float(FAR_TILES) / float(coarsest))) * coarsest

	var free_at := func(bx: int, bz: int, span: int) -> bool:
		if absi(bx) > reach or absi(bz) > reach:
			return false
		if absi(bx + span - 1) > reach or absi(bz + span - 1) > reach:
			return false
		for dz in span:
			for dx in span:
				if covered.has(Vector2i(bx + dx, bz + dz)):
					return false
		return true

	# COARSEST FIRST, then fill in.
	#
	# Placing a block per uncovered tile, at that tile's own level, fragments
	# badly: a big block is refused whenever any of its cells was already
	# taken by a smaller one, so the scan produced 471 blocks where the ring
	# arithmetic says about 140. Laying the big ones first and letting the
	# small ones fill around them is the same greedy idea with the order that
	# actually works.
	#
	# A block may only sit in its own ring or further out, never closer: the
	# radius test is on the block's NEAREST corner, so a coarse block never
	# creeps inside the range where its samples would be visible.
	# Ring 0 starts at the origin, not at the old fixed near square: the
	# detail moves, so the coarse tier has to be able to draw anywhere the
	# detail is not. Excluding the origin square left 21 tiles drawn by
	# nothing the moment the camera walked away from it.
	var ring_inner := func(level: int) -> int:
		return 0 if level == 0 else (FAR_FIRST << (level - 1))

	for level in range(levels - 1, -1, -1):
		var span: int = FAR_SPAN << level
		var step: int = FAR_STEP << level
		var inner: int = ring_inner.call(level)
		for bz in range(-reach, reach, span):
			for bx in range(-reach, reach, span):
				# Nearest corner of the block, in Chebyshev radius.
				var nx: int = 0 if bx <= 0 and bx + span - 1 >= 0 else mini(absi(bx), absi(bx + span - 1))
				var nz: int = 0 if bz <= 0 and bz + span - 1 >= 0 else mini(absi(bz), absi(bz + span - 1))
				if maxi(nx, nz) < inner:
					continue        # too close for this level of detail
				if not free_at.call(bx, bz, span):
					continue
				blocks.append(Vector2i(bx, bz))
				spans.append(span)
				steps.append(step)
				for dz in span:
					for dx in span:
						covered[Vector2i(bx + dx, bz + dz)] = true

	# Whatever is left, one tile at a time. There is always something: the
	# detail square is not on the block lattice, and the world's edge is not
	# either.
	for tz in range(-reach, reach + 1):
		for tx in range(-reach, reach + 1):
			if covered.has(Vector2i(tx, tz)):
				continue
			if absi(tx) > FAR_TILES or absi(tz) > FAR_TILES:
				continue
			blocks.append(Vector2i(tx, tz))
			spans.append(1)
			steps.append(FAR_STEP)
			covered[Vector2i(tx, tz)] = true

	if _bench_mode:
		var by_span := {}
		for v in spans:
			by_span[v] = int(by_span.get(v, 0)) + 1
		var keys := by_span.keys()
		keys.sort()
		for k in keys:
			print("[bench]   span %2d: %d blocks" % [k, by_span[k]])

	var baked: Array[Dictionary] = []
	baked.resize(blocks.size())
	var task := WorkerThreadPool.add_group_task(
		func(i: int) -> void:
			baked[i] = BrickTerrain.build_coarse(
				blocks[i].x, blocks[i].y, spans[i], steps[i]),
		blocks.size(), -1, true, "terrain coarse")
	WorkerThreadPool.wait_for_group_task_completion(task)

	var tile_studs := BrickTerrain.get_tile_studs()
	var stud := BrickWorld.get_stud_metres()
	# The SMALLEST blocks stay separate, because they are the only ones the
	# detail ever covers and hiding is per node. Everything bigger is merged
	# into ONE mesh a ring: those blocks are further out than the detail
	# reaches, so they never need to be hidden individually, and a ring is
	# built once and never changes.
	#
	# Draw calls were growing linearly with view distance — 1,157 at 9 km —
	# and this is where they were going.
	var merged := {}          ## span -> Array of surface arrays
	for i in blocks.size():
		var arrays: Array = baked[i]["mesh"]
		if arrays.is_empty():
			continue
		_far_tris += int(baked[i]["triangle_count"])
		var origin := Vector3(blocks[i].x * tile_studs * stud, 0.0,
				blocks[i].y * tile_studs * stud)
		_all_rects.append(Rect2i(blocks[i], Vector2i(spans[i], spans[i])))
		_all_steps.append(steps[i])
		if spans[i] > _streamer.align:
			# -1: lives in a merged ring and is therefore always drawn. A
			# block like this cannot be hidden on its own — splitting is the
			# only way to get the detail's ground back off it — so the ring
			# it belongs to keeps a HOLE where a split has retired a block.
			_all_owner.append(-1)
			if not merged.has(spans[i]):
				merged[spans[i]] = []
			merged[spans[i]].append(true)
			if not _ring_members.has(spans[i]):
				_ring_members[spans[i]] = [] as Array[int]
			_ring_members[spans[i]].append(_all_rects.size() - 1)
			continue
		_all_owner.append(_far_nodes.size())
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				TerrainTile.CUSTOM0_FLAGS)
		var mi := MeshInstance3D.new()
		_all_node[_all_rects.size() - 1] = mi
		mi.name = "Coarse_%d_%d" % [blocks[i].x, blocks[i].y]
		mi.mesh = mesh
		mi.material_override = _mat
		mi.set_instance_shader_parameter("lod_level", _lod_of_step(steps[i]))
		mi.position = origin
		# Far ground does not cast: the shadow of a hill 300 m away lands on
		# ground the player cannot see, and the shadow pass was 183k
		# triangles before anything was added to it (§19.1).
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_far_nodes.append(mi)
		_far_rects.append(Rect2i(blocks[i], Vector2i(spans[i], spans[i])))
		_far_blocks += 1

	for span in merged:
		_rebuild_ring(span)
		_far_rings += 1
		_far_blocks += merged[span].size()


## One blocky building a site, standing on the pad the field was given.
##
## Not the city's real building system — that is `city_scene.gd`, with its own
## streaming, damage and rooms. This is the TERRAIN half of the contract: a
## pad in the field, a floor at a known height, and something standing on it
## that does not sink, float or clip.
## The shader the city draws its buildings with.
##
## A building standing on terrain should be the same brick as a building in
## the city — same seams, same chamfer, same print pass — and the way to be
## sure of that is to use the same shader rather than a lookalike.
var _brick_mat: ShaderMaterial = null

func _brick_material() -> ShaderMaterial:
	if _brick_mat == null:
		_brick_mat = ShaderMaterial.new()
		_brick_mat.shader = load("res://shaders/brick.gdshader")
		WeatherFx.register(_brick_mat)
	return _brick_mat


## The sites again, after an edit moved, resized or re-floored one.
func rebuild_sites() -> void:
	_build_sites()
	if _trees != null:
		_trees.rebuild_soon()


func _build_sites() -> void:
	for old in _sites:
		if is_instance_valid(old):
			old.queue_free()
	_sites.clear()
	var stud := BrickWorld.get_stud_metres()
	for site in World.sites:
		var c := World.site_centre(site)
		var floor_y: float = World.site_level(site)
		var storeys: int = site["storeys"]
		# The CITY's own shell mesh, not a box.
		#
		# `BuildingShell` is what city_scene draws before a building
		# materialises into real bricks, so a site here shows the same thing
		# the city would put there — banded courses, a slab cap, the right
		# proportions — and the terrain half of the contract is tested
		# against the real article instead of a placeholder.
		# A footprint that FILLS the pad, snapped to the city's panel grid
		# (TerrainWorld.site_footprint).
		var fp := World.site_footprint(site)
		var corner := World.site_corner(site)
		var courses: int = storeys * TowerRecipe.COURSES_PER_FLOOR
		var body := MeshInstance3D.new()
		body.name = "Site_%d_%d" % [c.x, c.y]
		body.mesh = BuildingShell.build_coarse_mesh(fp.x, fp.y, courses)
		# The city's own brick material, for the city's own mesh.
		body.material_override = _brick_material()
		# The shell is built from its own corner, so it stands on the pad by
		# being placed at the corner rather than centred on it.
		body.position = Vector3(corner.x * stud, floor_y, corner.y * stud)
		add_child(body)
		_sites.append(body)


func _build_water() -> void:
	# THE WHOLE WORLD's seabed, one texel every 8 studs: how every tier knows
	# where the shore is (a cull mask and an absorption depth, neither of
	# which needs a stud). water_sea.gd holds the three tiers.
	_sea = WaterSeaScript.new()
	_sea.name = "Sea"
	add_child(_sea)
	_sea.build(FAR_TILES * BrickTerrain.get_tile_studs(), _far_metres() + 200.0)
	_water = _sea.near
	_water_far = _sea.far
	_water_sheet = _sea.sheet
	_camera.water_probe = func(p: Vector3) -> float: return _sea.surface_at(p)
	# ON by default now: the scene is also the level editor, and a level's
	# sea is part of it. The brick tiers only draw where there is water in
	# their reach, so a dry hilltop pays for none of it; F7 still hides it,
	# and the bench measures with and without.


## Water on or off, every tier, and the underwater look with it.
func _set_water(on: bool) -> void:
	if _sea == null:
		return
	_sea.enabled = on
	_sea.follow(_camera.global_position, 0.0)


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	# Frozen, the tiers are laid out for where the camera WAS: the detail
	# square, the far tier's hiding and the water rings all hold still.
	var lod_at: Vector3 = _frozen_at if _lod_frozen else _camera.global_position
	if _streamer != null:
		if not _lod_frozen:
			_streamer.follow(Vector2(lod_at.x, lod_at.z))
			_hide_covered_far()
			_relod_far(lod_at)
		_tiles.assign(_streamer.tiles())
	if _sea != null and _sea.enabled:
		_sea.follow(lod_at, delta)
		_under.set_submerged(_env, _sea.submerged_at(_camera.global_position),
				DRY_AMBIENT)
	elif _sea != null:
		# Hiding the water has to take the underwater look with it. It did
		# not, and every capture taken after a submerged one came out fogged
		# green with the sea switched off.
		_under.set_submerged(_env, false, DRY_AMBIENT)
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_F1:
			_toggle("seams_enabled")
		KEY_F2:
			_toggle("studs_enabled")
		KEY_F3:
			_toggle("stud_shadows_enabled")
		KEY_F4:
			_show_instances = not _show_instances
			for tile in _tiles:
				for child in tile.get_children():
					if child is MultiMeshInstance3D:
						(child as MultiMeshInstance3D).visible = _show_instances
		KEY_F6:
			BrickTerrain.set_plate_steps(not BrickTerrain.get_plate_steps())
			for tile in _tiles:
				tile.rebuild(_mat)
			print("[heightfield] plate steps: %s"
					% ("ON (0.14 m)" if BrickTerrain.get_plate_steps() else "OFF (0.42 m)"))
		KEY_F7:
			_set_water(not _sea.enabled)
		KEY_H:
			if disasters != null:
				disasters.on_key((event as InputEventKey).shift_pressed)
		KEY_L:
			set_lod_view(not _lod_debug)
		KEY_F10:
			_toggle_dev_menu()
		# C, not F8: F8 is Godot's own "stop the running game", and the
		# editor takes it even while the game has focus -- so the curves
		# toggle quit the game instead of toggling anything.
		# P: the print pass on and off, on every material that has one, so
		# "is that the layer lines or the seams" is one keypress.
		KEY_P:
			var on: bool = not bool(_toggles.get("print_lines_enabled", true))
			_toggles["print_lines_enabled"] = on
			_mat.set_shader_parameter("print_lines_enabled", on)
			for mat in [TerrainTile.instance_material(), TerrainTile.stud_material(),
					TerrainTile.tuft_material()]:
				mat.set_shader_parameter("print_lines_enabled", on)
			_water.set_print_lines(on)
			print("[heightfield] print lines: %s" % ("ON" if on else "OFF"))
		KEY_C:
			BrickTerrain.set_smooth_terrain(not BrickTerrain.get_smooth_terrain())
			for tile in _tiles:
				tile.rebuild(_mat)
			print("[heightfield] curved ground: %s"
					% ("ON" if BrickTerrain.get_smooth_terrain() else "OFF"))
		KEY_V:
			_water.set_brick_steps(not _water.brick_steps)
			print("[heightfield] water: %s" % ("brick steps + stop motion"
					if _water.brick_steps else "smooth bob"))
		KEY_F5:
			# Tiles laid on studs are the piece OVERLAY, so this is a rebuild.
			var on := BrickTerrain.get_overlay_chance() <= 0.0
			BrickTerrain.set_overlay_chance(0.26 if on else 0.0)
			for tile in _tiles:
				tile.rebuild(_mat)
			print("[heightfield] tiles on studs: %s" % ("ON" if on else "OFF"))


func _toggle(param: String) -> void:
	var on: bool = not bool(_toggles.get(param, true))
	_toggles[param] = on
	_mat.set_shader_parameter(param, on)


static func _thousands(v: int) -> String:
	var out := ""
	var text := str(v)
	for i in text.length():
		if i > 0 and (text.length() - i) % 3 == 0:
			out += ","
		out += text[i]
	return out


func _update_hud() -> void:
	if _label == null:
		return
	# Refreshed every time, not when the COUNT changes.
	#
	# The streamer drops tiles as well as adding them, so a snapshot can be
	# the same length and still hold freed nodes — one tile in, one tile out
	# is the common case while walking. That read as
	# "Invalid access ... on a base object of type 'previously freed'".
	if _streamer != null:
		_tiles.assign(_streamer.tiles())
	var pieces := 0
	var tris := 0
	var studs := 0
	var scatter := 0
	for tile in _tiles:
		pieces += tile.piece_count
		tris += tile.tri_count
		studs += tile.stud_count
		scatter += tile.scatter_count
	var curved := 0
	for tile in _tiles:
		curved += tile.curve_cells
	var tile_studs := BrickTerrain.get_tile_studs()
	var cells := TILES * TILES * tile_studs * tile_studs
	_label.text = "\n".join([
		"streaming    %s" % _streamer.report(),
		"heightfield  %d tiles  %d cells  %d pieces  %.1f studs/piece" % [
			_tiles.size(), cells, pieces, float(cells) / maxf(float(pieces), 1.0)],
		"             %d tris  %d studs  %d scatter  built %.0f ms (%.0f baked)" % [
			tris, studs, scatter, _build_ms, _bake_ms],
		"             %d%% curved  (C)   far %d blocks  %d tris" % [
			roundi(100.0 * float(curved) / maxf(float(_tiles.size()
				* tile_studs * tile_studs), 1.0)),
			_far_blocks - _far_hidden, _far_tris],
		"water        %s  %d instances  %s  sea %.1f m  %s" % [
			"ON" if _sea.enabled else "OFF (F7)",
			_water.instance_count(),
			"stepped" if _water.brick_steps else "smooth",
			BrickWave.get_sea_level(),
			"SWIMMING" if _camera.is_swimming()
				else ("under" if _under.is_submerged() else "dry")],
		# What the GPU is ACTUALLY asked for this frame, which is the only
		# number that answers "is this too many triangles". The mesh totals
		# above are what is BUILT; visibility ranges and frustum culling
		# decide what is drawn.
		"drawn        %s tris  %d draw calls" % [
			_thousands(RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
			RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)],
		"frame        %.1f ms" % _frame_ms,
		("LOD          0 red  1 orange  2 yellow  3 green  4 cyan  5 blue  6 purple"
			if _lod_debug else ""),
		"F1 seams  F2 studs  F3 shadows  F4 stud geometry",
		"F5 tiles on studs  F6 plate steps  F7 water",
		"C curves  P print  V wave steps  L LOD view  F10 dev menu  H disasters%s" % [
			"   LOD FROZEN" if _lod_frozen else ""],
	])


# ---------------------------------------------------------------------------

func _run_shots() -> void:
	await _frames(4)
	await _shot("hf_wide", Vector3(-34.0, 22.0, -34.0), Vector3(-0.52, -2.36, 0.0))
	await _shot("hf_close", Vector3(2.4, 1.5, 2.4), Vector3(-0.22, -2.30, 0.0))
	await _shot_topdown()
	await _shot_water()
	await _shot_print_detail()
	# Sites are BRICK ground: they belong on the default world, not inside
	# the curves-on block the two curve captures need.
	await _shot_site()
	_set_curves(true)
	await _frames(2)
	await _shot_smooth()
	await _shot_curves()
	_set_curves(false)
	await _frames(2)
	print("[heightfield] shots written")
	get_tree().quit()


## Straight down over flat ground, where the tiles laid on studs read most
## clearly: a smooth patch among studded ones.
func _shot_topdown() -> void:
	var plate := BrickWorld.get_plate_metres()
	var ground := float(BrickTerrain.surface_plate(0, 0)) * plate
	_camera.position = Vector3(0.0, ground + 7.0, 0.0)
	_camera.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_tiles.png")
	print("[heightfield] shot written: hf_tiles.png")


## What each layer costs, measured rather than guessed.
##
##     godot --path . scenes/heightfield_test.tscn -- --bench --tiles=13
##
## Turns one layer off at a time and reports drawn triangles, draw calls and
## the mean frame time over a fixed number of frames. Everything in
## Terrain.md 19 comes from this.
func _run_bench() -> void:
	# Without this every reading is 16.7 ms, because every reading is the
	# vsync interval. The first run of this bench measured the monitor.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_camera.position = Vector3(2.4, float(BrickTerrain.surface_plate(6, 6) + 1)
			* BrickWorld.get_plate_metres() + 1.6, 2.4)
	_camera.rotation = Vector3(-0.18, -2.36, 0.0)
	await _frames(20)

	_report_collision()
	_report_coverage()
	_report_streaming()
	await _report_water_collision()
	if FAR_TILES > 0:
		print("[bench] far tier: %d blocks in %d meshes, %s tris, out to %.0f m" % [
			_far_blocks, _far_nodes.size() + _far_rings, _thousands(_far_tris),
			float(FAR_TILES * BrickTerrain.get_tile_studs())
				* BrickWorld.get_stud_metres()])
	print("[bench] %dx%d tiles, %.0f m square, built %.0f ms (%.0f baked on %d threads)" % [
		TILES, TILES, float(TILES * BrickTerrain.get_tile_studs())
			* BrickWorld.get_stud_metres(), _build_ms, _bake_ms,
		OS.get_processor_count()])
	await _bench_case("everything")

	_set_water(false)
	await _bench_case("water off")

	for tile in _tiles:
		for child in tile.get_children():
			if child is MultiMeshInstance3D:
				(child as MultiMeshInstance3D).visible = false
	await _bench_case("and studs + scatter off")

	_sun.shadow_enabled = false
	await _bench_case("and shadows off")
	# The GROUND bakes its own sun shadow, so it never casts — but the light
	# still needs a shadow map for everything that stands ON the ground.
	_sun.shadow_enabled = true
	_set_water(false)

	await _bench_walk()
	get_tree().quit()


## CAN A BRICK FLOAT?
##
## Water is not a body (§7) and buoyancy is a force, which is right for a
## swimmer and wrong for a barrel: a force pushes, and a barrel wants to sit
## on a crest and stay there. So the surface near the camera also exists as
## collision — and a collider nothing can be dropped onto is indistinguishable
## from no collider at all, which is what this drops something to find out.
func _report_water_collision() -> void:
	var sea: float = BrickWave.get_sea_level()
	var stud := BrickWorld.get_stud_metres()
	# Somewhere with water under it.
	var edge := FAR_TILES * BrickTerrain.get_tile_studs()
	var best := Vector2i(0, 0)
	var deepest := 1 << 30
	for gz in range(-edge, edge, 16):
		for gx in range(-edge, edge, 16):
			var yp := BrickTerrain.surface_plate(gx, gz)
			if yp < deepest:
				deepest = yp
				best = Vector2i(gx, gz)
	var here := Vector3((best.x + 0.5) * stud, 0.0, (best.y + 0.5) * stud)
	_set_water(true)
	_camera.position = Vector3(here.x, sea + 12.0, here.z)
	await _frames(8)

	var want: float = BrickWave.height_at(here.x, here.z, _water.time())
	var from := Vector3(here.x, want + 8.0, here.z)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 16.0)
	q.collision_mask = Layers.WORLD
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var found: bool = not hit.is_empty()
	var off: float = absf(float(hit["position"].y) - want) if found else 99.0
	print("[bench]   %s  water collision: a ray lands on the sea%s" % [
		"ok  " if found and off < 0.6 else "FAIL",
		"  %.2f m from where the wave says" % off if found else "  nothing hit"])
	_set_water(false)


## THE STREAMER ITSELF.
##
## Coverage (below) checks what the two tiers DRAW. This checks the thing
## that decides it: residency, dropping, hysteresis and the world's edge.
## It is the most load-bearing part of the terrain and the easiest to break
## silently — every one of these properties is invisible in a screenshot,
## and all of them change the moment somebody edits a radius.
func _report_streaming() -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	# A one-element array, because a GDScript lambda captures by VALUE: the
	# first version counted into two locals and reported "0 checks, 0
	# failed" under five printed results.
	var tally := [0, 0]

	var gate := func(label: String, ok: bool, detail: String) -> void:
		tally[0] += 1
		if not ok:
			tally[1] += 1
		print("[bench]   %s  streaming: %s%s" % ["ok  " if ok else "FAIL",
			label, ("  " + detail) if detail != "" else ""])

	# 1. SETTLED MEANS SETTLED. Everything the region asks for is built.
	var spot := Vector2(180.0, -140.0)
	_streamer.settle(spot)
	var r := _streamer.current_region()
	var missing := 0
	for dz in r.size.y:
		for dx in r.size.x:
			var c := r.position + Vector2i(dx, dz)
			if absi(c.x) > FAR_TILES or absi(c.y) > FAR_TILES:
				continue
			if not _streamer.has_tile(c):
				missing += 1
	gate.call("settle leaves nothing unbuilt", missing == 0,
		"%d of %d missing" % [missing, r.size.x * r.size.y])

	# 2. AND NOTHING BEYOND THE WORLD. An authored world has edges.
	var outside := 0
	for c in _streamer.tiles_at():
		if absi(c.x) > FAR_TILES or absi(c.y) > FAR_TILES:
			outside += 1
	gate.call("nothing is built outside the world", outside == 0,
		"%d beyond +/-%d tiles" % [outside, FAR_TILES])

	# 3. DROPPING. Walk far away and the old ground must go, or a long
	#    session is a memory leak with a view.
	var resident_before := _streamer.tile_count()
	_streamer.settle(spot + Vector2(tile_m * 40.0, tile_m * 40.0))
	var stale := 0
	for c in _streamer.tiles_at():
		if absi(c.x - int(spot.x / tile_m)) <= 2 and absi(c.y - int(spot.y / tile_m)) <= 2:
			stale += 1
	gate.call("walking away drops what is behind you", stale == 0,
		"%d tiles from the old spot still resident, was %d" % [stale, resident_before])

	# 4. HYSTERESIS. Cross a block boundary back and forth. The FIRST pass
	#    legitimately builds new ground — the region moves a whole block —
	#    so the warm-up is two crossings, and after that the keep margin
	#    should mean nothing is built again. Counting the warm-up as a
	#    failure is what the first version of this check did: 48 tiles, all
	#    of them honest.
	var base := Vector2(tile_m * 4.5, tile_m * 4.5)
	var step := Vector2(tile_m * 0.6, 0.0)
	_streamer.settle(base)
	for i in 2:
		_streamer.settle(base + (step if i % 2 == 0 else -step))
	_streamer.reset_stats()
	for i in 4:
		_streamer.settle(base + (step if i % 2 == 0 else -step))
	gate.call("crossing a boundary does not rebuild the same ground",
		_streamer.built_count() == 0,
		"%d tiles rebuilt over four crossings" % _streamer.built_count())

	# 5. THE BUDGET, in the steady state. `settle` deliberately ignores it —
	#    a capture must not photograph a half-built world — so the reading
	#    has to come from ordinary frames, which is what `follow` is.
	_streamer.reset_stats()
	for i in 40:
		_streamer.follow(base + Vector2(float(i) * 0.4, 0.0))
	gate.call("no phase costs more than a frame", _streamer.worst_phase_ms() < 16.0,
		"worst phase %.1f ms while walking" % _streamer.worst_phase_ms())

	print("[bench] streaming: %d checks, %d failed" % [tally[0], tally[1]])


## ONE SURFACE PER TILE, across the two tiers.
##
## The detail and the coarse tier have now disagreed about who owns a tile
## three separate ways: a build-time hole the detail walked out of, hiding
## against wanted tiles instead of built ones, and blocks that were half
## covered because the two tiers were on different lattices. Every one of
## them was found by looking at a picture.
##
## A tile drawn twice is z-fighting; a tile drawn by neither is a hole. This
## counts them, from several camera positions, and neither shows up in a
## triangle total.
func _report_coverage() -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var worst_double := 0
	var worst_hole := 0
	var checked := 0
	var double_spans: Array[String] = []
	for spot in [Vector2(0, 0), Vector2(120, -80), Vector2(-300, 220), Vector2(500, 500)]:
		if absi(int(spot.x / tile_m)) > FAR_TILES or absi(int(spot.y / tile_m)) > FAR_TILES:
			continue
		_streamer.settle(spot)
		_hide_covered_far()
		var cx := int(floor(spot.x / tile_m))
		var cz := int(floor(spot.y / tile_m))
		for dz in range(-12, 13):
			for dx in range(-12, 13):
				var c := Vector2i(cx + dx, cz + dz)
				if absi(c.x) > FAR_TILES or absi(c.y) > FAR_TILES:
					continue
				checked += 1
				var n := 1 if _streamer.has_tile(c) else 0
				for i in _all_rects.size():
					if not _all_rects[i].has_point(c):
						continue
					var owner_i := _all_owner[i]
					if owner_i == -2:
						continue            # retired by a split
					if owner_i < 0 or _far_nodes[owner_i].visible:
						n += 1
				if n > 1:
					worst_double += 1
					if double_spans.size() < 6:
						for i in _all_rects.size():
							if _all_rects[i].has_point(c) and _all_owner[i] != -2 									and (_all_owner[i] < 0
									or _far_nodes[_all_owner[i]].visible):
								var res := 0
								for qz in _all_rects[i].size.y:
									for qx in _all_rects[i].size.x:
										if _streamer.has_tile(_all_rects[i].position
												+ Vector2i(qx, qz)):
											res += 1
								double_spans.append(
									"%s span %d at %s owner %d resident %d/%d region %s" % [
									c, _all_rects[i].size.x, _all_rects[i].position,
									_all_owner[i], res,
									_all_rects[i].size.x * _all_rects[i].size.y,
									_streamer.current_region()])
				elif n == 0:
					worst_hole += 1
	print("[bench] coverage: %d tiles, %d drawn twice, %d drawn by nothing" % [
		checked, worst_double, worst_hole])
	for d in double_spans:
		print("[bench]   double: %s" % d)


## Does the ground still collide?
##
## The tile collider is a physics-server body with no node behind it, so
## nothing in the scene tree says whether it exists. A ray down onto a few
## columns, compared against the surface the mesher reports, is the check —
## and it is the check that should have existed before the collider was
## moved, not after.
func _report_collision() -> void:
	var space := get_world_3d().direct_space_state
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	var hits := 0
	var tried := 0
	var worst := 0.0
	for i in 40:
		var gx := (i * 37) % 120 - 60
		var gz := (i * 53) % 120 - 60
		var want := float(BrickTerrain.surface_plate(gx, gz) + 1) * plate
		var from := Vector3((gx + 0.5) * stud, want + 4.0, (gz + 0.5) * stud)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 12.0)
		q.collision_mask = Layers.WORLD
		var hit := space.intersect_ray(q)
		tried += 1
		if hit.is_empty():
			continue
		hits += 1
		worst = maxf(worst, absf(float(hit["position"].y) - want))
	print("[bench] collision: %d of %d rays hit, worst %.3f m off the surface" % [
		hits, tried, worst])


## Fly across the world and watch the streamer keep up.
##
## The mean frame time says nothing about streaming — a build that takes 40
## ms once every two seconds averages to nothing and feels like a stutter.
## What matters is the WORST frame while tiles are being built, so that is
## what this reports.
func _bench_walk() -> void:
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var start := _camera.position
	_streamer.reset_stats()
	var worst := 0.0
	var worst_at := 0
	var frames := 300
	var speed := 14.0            # m/s, a fast sprint
	for i in frames:
		await RenderingServer.frame_post_draw
		_camera.position = start + Vector3(float(i) * speed / 60.0, 0.0, 0.0)
		var ms := get_process_delta_time() * 1000.0
		# The first frames after the camera jumps are not streaming cost.
		if i > 10 and ms > worst:
			worst = ms
			worst_at = i
	print("[bench] walk: %.0f m at %.0f m/s, worst frame %.1f ms (frame %d)" % [
		float(frames) * speed / 60.0, speed, worst, worst_at])
	print("[bench]   %s" % _streamer.report())
	print("[bench]   tile is %.1f m, so that crossed %.0f of them" % [
		tile_m, float(frames) * speed / 60.0 / tile_m])


## One reading: N frames, then the mean of the LAST half of them, so the
## first frames after a visibility change do not count.
func _bench_case(label: String) -> void:
	var samples: Array[float] = []
	for i in 90:
		await RenderingServer.frame_post_draw
		samples.append(get_process_delta_time() * 1000.0)
	var sum := 0.0
	@warning_ignore("integer_division")
	var half_n := samples.size() / 2
	for i in range(half_n, samples.size()):
		sum += samples[i]
	var mean: float = sum / float(half_n)
	print("[bench]   %-26s %9s tris  %4d calls  %5.1f ms" % [
		label,
		_thousands(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)),
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		mean])


## Curves on or off, and the tiles rebuilt to match. Curved ground is off by
## default now, so the two captures that exist to show it have to turn it on
## and put it back.
func _set_curves(on: bool) -> void:
	if BrickTerrain.get_smooth_terrain() == on:
		return
	BrickTerrain.set_smooth_terrain(on)
	for tile in _tiles:
		tile.rebuild(_mat)


## An authored site: the pad cut into the field, the building standing on
## it, and the shadow it throws on the ground.
func _shot_site() -> void:
	if _sites.is_empty():
		return
	var stud := BrickWorld.get_stud_metres()
	var site: Dictionary = World.sites[0]
	var c := World.site_centre(site)
	var here := Vector3((c.x + 0.5) * stud, World.site_level(site), (c.y + 0.5) * stud)
	# Standing DOWN-SUN of the building, so its shadow falls toward the
	# camera. The first version stood wherever and reported "no shadows" on
	# a scene whose only shadow was behind the thing casting it.
	var to_sun := _sun.global_transform.basis.z
	var away := Vector3(to_sun.x, 0.0, to_sun.z).normalized()
	_camera.position = here - away * 24.0 + Vector3(0.0, 10.0, 0.0)
	_camera.look_at(here + Vector3(0.0, 4.0, 0.0), Vector3.UP)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_site.png")
	print("[heightfield] shot written: hf_site.png  (%d pads, floor %.2f m)" % [
		BrickTerrain.pad_count(), here.y])


## Standing ON curved ground, away from any brick, looking along the slope.
## This is the capture that answers "can you actually see the curve" — the
## boundary shot cannot, because the brick beside it dominates.
func _shot_smooth() -> void:
	var stud := BrickWorld.get_stud_metres()
	var best := Vector2i(0, 0)
	var found := false
	for r in range(6, 70):
		for a in range(0, 360, 9):
			var gx := int(round(cos(deg_to_rad(a)) * r))
			var gz := int(round(sin(deg_to_rad(a)) * r))
			# Deep inside a curved patch: every neighbour within 3 studs
			# curved too, so nothing bricked is in frame.
			var all_curved := true
			for dz in [-3, 0, 3]:
				for dx in [-3, 0, 3]:
					if not BrickTerrain.smooth_at(gx + dx, gz + dz):
						all_curved = false
			if not all_curved:
				continue
			best = Vector2i(gx, gz)
			found = true
			break
		if found:
			break
	if not found:
		print("[heightfield] no curved patch big enough to photograph")
		return
	var here := Vector3((best.x + 0.5) * stud,
			float(BrickTerrain.surface_raw(best.x, best.y)), (best.y + 0.5) * stud)
	print("[heightfield] curved patch at %s" % best)
	# Looking DOWN at the ground it is standing on. Level with the horizon
	# the frame fills with whatever is beyond the patch, which is usually
	# brick, and the capture proves nothing.
	_camera.position = here + Vector3(0.0, 2.2, 0.0)
	_camera.rotation = Vector3(-0.95, -2.36, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_smooth.png")
	print("[heightfield] shot written: hf_smooth.png")


## Where a curve meets a terrace. That boundary is the whole risk in mixing
## the two surfaces — the curve has to land on the brick top edge exactly or
## the join is a row of pinholes — so it gets a capture of its own.
func _shot_curves() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var best := Vector2i(0, 0)
	var found := false
	for r in range(4, 70):
		for a in range(0, 360, 7):
			var gx := int(round(cos(deg_to_rad(a)) * r))
			var gz := int(round(sin(deg_to_rad(a)) * r))
			if not BrickTerrain.smooth_at(gx, gz):
				continue
			# A curve with bricks on the other side of it.
			if BrickTerrain.smooth_at(gx + 2, gz) and BrickTerrain.smooth_at(gx - 2, gz):
				continue
			best = Vector2i(gx, gz)
			found = true
			break
		if found:
			break
	var ground := float(BrickTerrain.surface_plate(best.x, best.y) + 1) * plate
	var here := Vector3((best.x + 0.5) * stud, ground, (best.y + 0.5) * stud)
	print("[heightfield] curve/brick boundary at %s" % best)
	# Aimed AT the boundary rather than pointed in a fixed direction: the
	# fixed heading kept landing with the join behind the camera.
	_camera.position = here + Vector3(2.4, 1.5, 2.4)
	_camera.look_at(here, Vector3.UP)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_curves.png")
	print("[heightfield] shot written: hf_curves.png")

	# ...and with the print pass off but curves still on, which separates
	# "the geometry is fighting" from "the pattern is aliasing".
	# One at a time, because "the shading is aliasing" is not an answer
	# until it says WHICH shading.
	for pair in [["hf_curves_noprint", false, true],
			["hf_curves_noseam", true, false],
			["hf_curves_bare", false, false]]:
		_mat.set_shader_parameter("print_lines_enabled", pair[1])
		_mat.set_shader_parameter("seams_enabled", pair[2])
		await _frames(6)
		get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % pair[0])
		print("[heightfield] shot written: %s.png" % pair[0])
	_mat.set_shader_parameter("print_lines_enabled", true)
	_mat.set_shader_parameter("seams_enabled", true)

	# The same camera with curves OFF. Any difference that is not the ground
	# changing shape is the curves costing something they should not.
	var tris_on := 0
	for tile in _tiles:
		tris_on += tile.tri_count
	_set_curves(false)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_curves_off.png")
	var tris_off := 0
	for tile in _tiles:
		tris_off += tile.tri_count
	print("[heightfield] shot written: hf_curves_off.png  %d tris curved, %d bricked"
			% [tris_on, tris_off])
	_set_curves(true)
	await _frames(4)


## Nose to the ground: layer lines, bead relief and the nozzle path around a
## piece's perimeter. Everything in the print pass is invisible past about
## twenty metres by design, so it needs a capture of its own.
func _shot_print_detail() -> void:
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	# Over BRICKED ground. It matters when curves are on -- a curve has no
	# perimeter for the nozzle to walk, so a capture that landed on one
	# showed none of what this shot is for -- and costs nothing when they
	# are off, which is the default.
	var spot := Vector2i(0, 0)
	for r in range(2, 60):
		var hit := false
		for a in range(0, 360, 11):
			var gx := int(round(cos(deg_to_rad(a)) * r))
			var gz := int(round(sin(deg_to_rad(a)) * r))
			if BrickTerrain.smooth_at(gx, gz):
				continue
			if BrickTerrain.smooth_at(gx + 1, gz) or BrickTerrain.smooth_at(gx, gz + 1):
				continue
			spot = Vector2i(gx, gz)
			hit = true
			break
		if hit:
			break
	var ground := float(BrickTerrain.surface_plate(spot.x, spot.y) + 1) * plate
	_camera.position = Vector3((spot.x + 0.5) * stud + 0.45, ground + 0.26,
			(spot.y + 0.5) * stud + 0.45)
	_camera.rotation = Vector3(-0.66, -2.36, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_print.png")
	print("[heightfield] shot written: hf_print.png")

	# And the same range over STUDS, where the contact shadow, the stud's own
	# paths and the ground's beads all land in the same pixels.
	var g2 := float(BrickTerrain.surface_plate(0, 0) + 1) * plate
	_camera.position = Vector3(0.45, g2 + 0.30, 0.45)
	_camera.rotation = Vector3(-0.58, -2.36, 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_print_studs.png")
	print("[heightfield] shot written: hf_print_studs.png")


## The coast: stand just above the surface where the water is deepest and
## look back at the land, so the shore taper has something to run into.
func _shot_water() -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var sea: float = BrickWave.get_sea_level()
	# Search the STREAMED area, not a fixed 5x5 field. With 49 m of relief
	# the low ground can be a long way from the origin, and a search that
	# finds only high ground puts the camera inside a hill — which is what
	# the first capture after the relief change actually was.
	# The WHOLE world, coarsely. With 49 m of relief the sea can be hundreds
	# of metres from the origin, and a search that only looked 45 m out kept
	# choosing a hilltop and photographing dry land.
	var edge := FAR_TILES * BrickTerrain.get_tile_studs()
	var best := Vector2i(0, 0)
	var deepest := 1 << 30
	for gz in range(-edge, edge, 8):
		for gx in range(-edge, edge, 8):
			var yp := BrickTerrain.surface_plate(gx, gz)
			if yp < deepest:
				deepest = yp
				best = Vector2i(gx, gz)
	var seabed := float(deepest + 1) * plate
	print("[heightfield] water: cell %s  seabed %.2f m  depth %.2f m"
			% [best, seabed, sea - seabed])
	# The sea is hidden by default in this scene (F7). A capture of the
	# water has to turn it on, which the first version of this did not —
	# and every "no water anywhere" hunt that followed was chasing a
	# switched-off ocean.
	_set_water(true)
	if seabed >= sea:
		print("[heightfield] no water within %d studs; skipping the water shots" % edge)
		return
	var here := Vector3((best.x + 0.5) * stud, 0.0, (best.y + 0.5) * stud)
	# Above the CREST, not above the still level: the pieces bob smoothly now
	# and a crest stands a couple of metres over the sea, so a fixed offset
	# from `sea_level` put the camera under water.
	var crest := _water.surface_at(here) + 0.9
	_camera.position = Vector3(here.x, crest, here.z)
	_camera.rotation = Vector3(-0.12, atan2(here.x, here.z), 0.0)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_water.png")
	print("[heightfield] shot written: hf_water.png")

	# High over the sea: the only view that shows all three water tiers at
	# once, and the one that used to end in mid-air at 80 m.
	_camera.position = Vector3(here.x, sea + 28.0, here.z)
	_camera.rotation = Vector3(-0.22, atan2(here.x, here.z), 0.0)
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_sea.png")
	print("[heightfield] shot written: hf_sea.png  (sheet %d tris)"
			% (_water_sheet.triangle_count() if _water_sheet != null else 0))
	_set_water(false)

	_camera.position = Vector3(here.x,
			maxf(float(deepest + 1) * plate + 0.45, sea - 1.2), here.z)
	_camera.rotation = Vector3(0.14, atan2(here.x, here.z), 0.0)
	await _frames(8)
	get_viewport().get_texture().get_image().save_png("res://shots/hf_under.png")
	print("[heightfield] shot written: hf_under.png")


func _shot(shot_name: String, pos: Vector3, rot: Vector3) -> void:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var gx := int(floor(pos.x / stud))
	var gz := int(floor(pos.z / stud))
	var ground := float(BrickTerrain.surface_plate(gx, gz) + 1) * plate
	pos.y += ground
	_camera.position = pos
	_camera.rotation = rot
	await _frames(6)
	get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % shot_name)
	print("[heightfield] shot written: %s.png" % shot_name)


func _frames(n: int) -> void:
	# Every capture waits here, so this is the one place that has to make
	# sure the world is whole: the streamer fills at a couple of tiles a
	# frame, and six frames after a camera jump is 40 tiles of a 144-tile
	# square.
	if _streamer != null:
		_streamer.settle(Vector2(_camera.position.x, _camera.position.z))
	for i in n:
		await RenderingServer.frame_post_draw
