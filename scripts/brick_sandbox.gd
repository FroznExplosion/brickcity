extends Node3D

## Brick sandbox — the scene the milestones are demonstrated in.
##
## M1: shoot a wall, whatever can no longer reach the ground leaves as a rigid
## island and falls.
## M2: weight flows down the structure, overloaded joints crush, the collapse
## cascades over successive ticks, and debris settles.
## M3a: an island IS a chunk — same grid, same connectivity — so it can be shot,
## re-solved and broken apart when it lands hard.
##
## Keys: WASD/QE fly · shift fast · LMB or SPACE fire · X wider blast
##       R rebuild · L seams · G print stress · F1 stats · ESC mouse
## Flags: `-- --shot` scripted capture, `-- --tall` the 150 m gate tower

const BLAST_RADIUS := 1.1      ## metres
const MASS_SCALE := 10.0       ## archetype mass units -> kilograms
const MAX_ISLANDS_PER_TICK := 8
const SETTLE_MIN_MS := 900
const MAX_CASCADE_STEPS := 90
## Above this many blocks it is cheaper to lift the static body out of the
## physics space, change its shapes, and put it back.
const SPACE_DETACH_THRESHOLD := 4
## Tension one stud connection can hold, in the mass units archetypes use.
##
## Physical, not tuned: 4 N to release a connection, 1 mass unit = 1 g, and then
## DIVIDED BY THE SCALE FACTOR. Our studs are 0.35 m against 8 mm in print, and
## clutch force scales with stud area while weight scales with volume -- so a
## game-scale assembly is 43.75x weaker relative to its own weight. A full
## 8-stud connection holds about 29 hanging bricks here, against 1280 on a desk.
##
##     408 / 43.75 ~ 9.3
##
## There is no compression limit at all. Docs/BrickFailure.md section 4.5.
const TENSION_PER_STUD := 9.3

## Impact fracture. A island that loses this much speed in one tick has hit
## something; the harder it hit, the bigger the bite taken out of the contact.
const IMPACT_MIN_SPEED := 4.0     ## m/s before a landing counts as hard
const IMPACT_DELTA := 2.5         ## m/s lost in one tick
const IMPACT_RADIUS := 0.8
const IMPACT_RADIUS_MAX := 2.6
const MAX_FRACTURES := 4          ## per island, so one piece cannot grind forever
## Disturbing one settled piece wakes its neighbours within this, so a pile does
## not hold itself up after the brick underneath it has gone.
const WAKE_RADIUS := 6.0

var world: BrickWorld
var chunk_id := -1
var palette := {}

var mesh_instance: MeshInstance3D
var brick_material: ShaderMaterial
var stats_label: Label
var camera: DebugCamera

var _static_body := RID()
var _static_shapes := {}   ## block id -> PackedInt32Array of shape indices
var _shape_cache := {}
var _islands: Array[BrickIsland] = []
var _settled := 0
var _fracture_count := 0
var _impact_count := 0
var _impact_blocks := 0
var _collapsing := false
var _cascade_steps := 0
var _last_stress := {}
var _last_collapse := {}
var _last_mesh_ms := 0.0
var _shot_mode := false
var _tall := false

var _fps_sampling := false
var _frame_worst := 0.0
var _frame_sum := 0.0
var _frame_samples := 0
var _frames_over_60 := 0
var _frames_over_30 := 0


func _ready() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	_shot_mode = "--shot" in args
	_tall = "--tall" in args

	var footprint_x := 48 if _tall else 24
	var footprint_z := 48 if _tall else 16
	var courses := 357 if _tall else 40

	world = BrickWorld.new()
	world.set_seed(1)

	_build_scenery()
	palette = TowerRecipe.bake_palette(world)
	_report_palette()

	var t0 := Time.get_ticks_usec()
	chunk_id = world.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(footprint_x, footprint_z, courses))
	TowerRecipe.build(world, chunk_id, palette, footprint_x, footprint_z, courses)
	world.set_tension_per_stud(chunk_id, TENSION_PER_STUD)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0

	var height: float = courses * TowerRecipe.PLATES_PER_COURSE * BrickWorld.get_plate_metres()
	print("[sandbox] tower: %d blocks, %d courses, %.1f m tall, built in %.1f ms" % [
		world.get_block_count(chunk_id), courses, height, build_ms])

	_build_static_body()
	_rebuild_mesh()
	_report_stress()

	if _shot_mode:
		_run_shot_pass()


func _exit_tree() -> void:
	if _static_body.is_valid():
		PhysicsServer3D.free_rid(_static_body)
	for rid in _shape_cache.values():
		PhysicsServer3D.free_rid(rid)


func _report_palette() -> void:
	var shaped := 0
	for id in palette.values():
		if not world.is_archetype_full_box(id):
			shaped += 1
	print("[sandbox] palette: %d archetypes, %d of them not box-shaped" % [
		world.get_archetype_count(), shaped])


# ---------------------------------------------------------------------------
# Collision
# ---------------------------------------------------------------------------

## One physics shape per distinct footprint, shared by every block of that size.
func _shape_rid(size: Vector3) -> RID:
	if not _shape_cache.has(size):
		var rid := PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(rid, size * 0.5)  # PhysicsServer wants half-extents
		_shape_cache[size] = rid
	return _shape_cache[size]


## Fill a body from a chunk's boxes and return the block -> shape-indices map.
##
## Shapes go on BEFORE the body joins a space. Adding them afterwards makes the
## physics server re-register the body on every call, which is quadratic: at
## 16.5k blocks that was 18 SECONDS, against 33 ms this way.
func _add_boxes(body_rid: RID, boxes: Array) -> Dictionary:
	var map := {}
	for i in boxes.size():
		var box: Dictionary = boxes[i]
		PhysicsServer3D.body_add_shape(body_rid, _shape_rid(box.size),
				Transform3D(Basis(), box.pos))
		var bid: int = box.block
		if not map.has(bid):
			map[bid] = PackedInt32Array()
		map[bid].append(i)
		if box.has("alive") and not box.alive:
			PhysicsServer3D.body_set_shape_disabled(body_rid, i, true)
	return map


func _build_static_body() -> void:
	var t0 := Time.get_ticks_usec()
	_static_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_static_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_static_body, Layers.STRUCTURE)
	PhysicsServer3D.body_set_collision_mask(_static_body, Layers.STRUCTURE_MASK)

	var boxes: Array = world.get_block_boxes(chunk_id)
	_static_shapes = _add_boxes(_static_body, boxes)

	PhysicsServer3D.body_set_state(_static_body, PhysicsServer3D.BODY_STATE_TRANSFORM,
			world.get_chunk_transform(chunk_id))
	PhysicsServer3D.body_set_space(_static_body, get_world_3d().space)
	print("[sandbox] static body: %d shapes for %d blocks, %d distinct, %.1f ms" % [
		boxes.size(), _static_shapes.size(), _shape_cache.size(),
		(Time.get_ticks_usec() - t0) / 1000.0])


## Turning off a block's collision is one call per shape -- but each of those
## calls costs time proportional to how many shapes the body has, exactly like
## body_add_shape does. Disabling 73 blocks on a 16.7k-shape body measured
## 245 ms; the same work with the body lifted out of the space first is a few
## milliseconds. Nothing steps physics in between, so the body is never
## observed missing.
func _disable_static(ids: PackedInt32Array) -> void:
	if ids.is_empty():
		return
	var detached_space := false
	if ids.size() >= SPACE_DETACH_THRESHOLD:
		PhysicsServer3D.body_set_space(_static_body, RID())
		detached_space = true
	for bid in ids:
		if not _static_shapes.has(bid):
			continue
		for shape_index in _static_shapes[bid]:
			PhysicsServer3D.body_set_shape_disabled(_static_body, shape_index, true)
	if detached_space:
		PhysicsServer3D.body_set_space(_static_body, get_world_3d().space)


# ---------------------------------------------------------------------------
# Damage, stress and cascade
# ---------------------------------------------------------------------------

func _aim_hit() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - camera.global_transform.basis.z * 400.0)
	q.collision_mask = Layers.HITSCAN_MASK
	return space.intersect_ray(q)


func _fire(radius: float = BLAST_RADIUS) -> void:
	var hit := _aim_hit()
	if hit.is_empty():
		return
	# An island is a chunk, so a shot at one is the same call as a shot at the
	# building -- it just goes to a different chunk id.
	for island in _islands:
		if island.is_valid() and island.body == hit.collider:
			_damage_island(island, hit.position, radius)
			return
	_blast_at(hit.position, radius)


func _blast_at(point: Vector3, radius: float) -> void:
	var killed: PackedInt32Array = world.apply_hit(chunk_id, point, radius)
	_disable_static(killed)
	_last_collapse = {"killed": killed.size(), "released": 0, "detached": 0, "islands": 0}
	_collapsing = true
	_cascade_steps = 0
	_rebuild_mesh()


## One cascade round per physics tick, not a whole collapse in one frame.
func _step_collapse() -> void:
	if not _collapsing:
		return
	_cascade_steps += 1
	var t0 := Time.get_ticks_usec()

	var t_stress := Time.get_ticks_usec()
	_last_stress = world.solve_stress(chunk_id)
	# A separated joint destroys nothing; the brick is still there, it is just
	# no longer attached. Connectivity turns it into an island next pass.
	var ms_stress := (Time.get_ticks_usec() - t_stress) / 1000.0

	var t_groups := Time.get_ticks_usec()
	var groups: Array = world.find_detached_groups(chunk_id)
	var ms_groups := (Time.get_ticks_usec() - t_groups) / 1000.0

	# Keep going while the structure is still changing. Crushing alone counts:
	# a failed joint removes material and redistributes load, so the next solve
	# can find more even when nothing came loose this round.
	var released_now := int(_last_stress.get("failures", 0))
	if (released_now == 0 and groups.is_empty()) or _cascade_steps >= MAX_CASCADE_STEPS:
		_collapsing = false
		print("[sandbox] settled after %d cascade step(s), max stress %.2f, %d standing" % [
			_cascade_steps, world.get_max_stress_ratio(chunk_id),
			world.get_alive_block_count(chunk_id)])
		_update_hud()
		return

	var spawned := 0
	var detached := 0
	for g_ids in groups:
		if spawned >= MAX_ISLANDS_PER_TICK:
			break
		var island := _spawn_island(chunk_id, g_ids, Vector3.ZERO, Vector3.ZERO)
		if island == null:
			continue
		detached += world.get_alive_block_count(island.chunk)
		spawned += 1

	_rebuild_mesh()
	_last_collapse.released = int(_last_collapse.get("released", 0)) + released_now
	_last_collapse.detached = int(_last_collapse.get("detached", 0)) + detached
	_last_collapse.islands = int(_last_collapse.get("islands", 0)) + spawned
	_last_collapse.step_ms = (Time.get_ticks_usec() - t0) / 1000.0
	print("[cascade] step %d: %d released, %d island(s), %d standing | step %.1f = stress %.1f + groups %.1f + index %.1f + upload %.1f ms (%d B)" % [
		_cascade_steps, released_now, groups.size(),
		world.get_alive_block_count(chunk_id), _last_collapse.step_ms,
		ms_stress, ms_groups, _last_mesh_ms, _last_upload_ms, _last_changed_bytes])
	_update_hud()


# ---------------------------------------------------------------------------
# Islands
# ---------------------------------------------------------------------------

## Lift a group out of `source` and give it a chunk, a body and a mesh.
func _spawn_island(source: int, block_ids: PackedInt32Array,
		inherit_linear: Vector3, inherit_angular: Vector3) -> BrickIsland:
	var t_split := Time.get_ticks_usec()
	var split: Dictionary = world.split_island(source, block_ids)
	if split.is_empty():
		return null
	var ms_split := (Time.get_ticks_usec() - t_split) / 1000.0

	# The source chunk owns these blocks no longer.
	if source == chunk_id:
		_disable_static(split.source_blocks)
	else:
		for island in _islands:
			if island.chunk == source:
				island.disable_blocks(split.source_blocks)
				break

	var isl := BrickIsland.new()
	isl.chunk = int(split.chunk)
	isl.local_com = split.local_com

	isl.body = RigidBody3D.new()
	isl.body.mass = maxf(float(split.mass) * MASS_SCALE, 0.5)
	isl.body.collision_layer = Layers.DEBRIS
	isl.body.collision_mask = Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS

	var t_boxes := Time.get_ticks_usec()
	var body_data: Dictionary = world.get_body_boxes(isl.chunk)
	var boxes: Array = body_data.boxes
	var ms_boxes := (Time.get_ticks_usec() - t_boxes) / 1000.0

	var t_shapes := Time.get_ticks_usec()
	isl.shape_map = _add_boxes(isl.body.get_rid(), boxes)
	isl.shape_count = boxes.size()
	var ms_shapes := (Time.get_ticks_usec() - t_shapes) / 1000.0

	isl.mesh = MeshInstance3D.new()
	isl.mesh.material_override = brick_material
	isl.mesh.position = -isl.local_com
	isl.body.add_child(isl.mesh)

	# Position so the island's chunk transform lands exactly where the group
	# stood: body origin at the world centre of mass, orientation inherited.
	var island_xform: Transform3D = world.get_chunk_transform(isl.chunk)
	isl.body.transform = island_xform * Transform3D(Basis(), isl.local_com)

	var t_add := Time.get_ticks_usec()
	add_child(isl.body)
	var ms_add := (Time.get_ticks_usec() - t_add) / 1000.0
	isl.body.set_meta("spawn_pos", isl.body.position)
	isl.body.linear_velocity = inherit_linear
	isl.body.angular_velocity = inherit_angular
	isl.born_ms = Time.get_ticks_msec()
	isl.prev_speed = inherit_linear.length()
	_islands.append(isl)
	_wake_neighbours(isl.body.global_position, WAKE_RADIUS)
	var t_mesh := Time.get_ticks_usec()
	_rebuild_island_mesh(isl)
	var ms_mesh := (Time.get_ticks_usec() - t_mesh) / 1000.0
	print("[island] %d blocks, %d shapes | split %.1f + boxes %.1f + shapes %.1f + add_child %.1f + mesh %.1f ms" % [
		int(split.block_count), boxes.size(), ms_split, ms_boxes, ms_shapes, ms_add, ms_mesh])
	return isl


func _rebuild_island_mesh(isl: BrickIsland) -> void:
	var arrays: Array = world.build_chunk_mesh(isl.chunk)
	var mesh := ArrayMesh.new()
	if not arrays.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	isl.mesh.mesh = mesh


## Damage an island in its own frame, then see whether it is still one piece.
func _damage_island(isl: BrickIsland, world_point: Vector3, radius: float) -> void:
	if not isl.is_valid():
		return
	_wake(isl)
	_wake_neighbours(world_point, WAKE_RADIUS)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())
	var killed: PackedInt32Array = world.apply_hit(isl.chunk, world_point, radius)
	if killed.is_empty():
		return
	isl.disable_blocks(killed)
	_split_if_broken(isl)
	_rebuild_island_mesh(isl)


## Wake a settled island. A frozen body never re-evaluates, so one that has been
## shot -- or has just lost the piece it was resting on -- hangs exactly where
## it stopped. That is where floating wreckage comes from.
func _wake(isl: BrickIsland) -> void:
	if not isl.is_valid() or not isl.settled:
		return
	isl.body.freeze = false
	isl.settled = false
	isl.body.sleeping = false
	isl.born_ms = Time.get_ticks_msec()
	isl.prev_speed = 0.0
	_settled = maxi(_settled - 1, 0)


## Wake everything near a disturbance, so a pile settles as a pile rather than
## one brick leaving and the rest staying in the air.
func _wake_neighbours(origin: Vector3, radius: float) -> void:
	for other in _islands:
		if other.is_valid() and other.settled 				and other.body.global_position.distance_to(origin) < radius:
			_wake(other)


## If damage has cut the island in two, the smaller pieces leave as islands of
## their own, inheriting the motion they had.
func _split_if_broken(isl: BrickIsland) -> void:
	var comps: Array = world.get_components(isl.chunk)
	if comps.size() <= 1:
		return
	var linear := isl.body.linear_velocity
	var angular := isl.body.angular_velocity
	# comps[0] is the largest and stays put; everything else breaks away.
	for i in range(1, comps.size()):
		_spawn_island(isl.chunk, comps[i], linear, angular)
	isl.fractures += 1
	_fracture_count += 1
	# What is left is a different shape with a different mass, so it cannot be
	# assumed to still balance where it was.
	_wake(isl)
	_wake_neighbours(isl.body.global_position, WAKE_RADIUS)


func _physics_process(_delta: float) -> void:
	_step_collapse()
	_update_islands()


func _update_islands() -> void:
	var now := Time.get_ticks_msec()
	var i := _islands.size() - 1
	while i >= 0:
		var isl := _islands[i]
		i -= 1
		if not isl.is_valid():
			continue

		# Keep the chunk's idea of where it is in step with the body, so a shot
		# at a tumbling island lands where it looks like it should.
		world.set_chunk_transform(isl.chunk, isl.chunk_transform())

		if isl.settled:
			continue

		var speed := isl.body.linear_velocity.length()
		var lost := isl.prev_speed - speed
		isl.peak_speed = maxf(isl.peak_speed, isl.prev_speed)
		isl.max_speed_lost = maxf(isl.max_speed_lost, lost)
		isl.prev_speed = speed

		# A sudden loss of speed IS the impact. Using that rather than a contact
		# signal keeps the whole thing inside one deterministic tick order.
		if lost > IMPACT_DELTA and isl.prev_speed + lost > IMPACT_MIN_SPEED \
				and isl.impacts < MAX_FRACTURES:
			_fracture_on_impact(isl, lost)
			continue

		if now - isl.born_ms >= SETTLE_MIN_MS and isl.body.sleeping:
			isl.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			isl.body.freeze = true
			isl.settled = true
			_settled += 1
			_update_hud()


## Break the island where it hit: a bite out of its lowest point, scaled by how
## hard the landing was. Spec section 5's "on secondary impact, break down only
## near the contact; distant parts stay clustered".
func _fracture_on_impact(isl: BrickIsland, severity: float) -> void:
	var aabb: AABB = isl.mesh.get_aabb()
	if aabb.size == Vector3.ZERO:
		return
	# A landing shears a thin band along the contact. Radius grows with how hard
	# it hit but stays small -- an earlier version scaled it four times faster
	# AND destroyed what it touched, so a single landing removed dozens of
	# bricks. Nothing is removed now: separate_near marks joints sheared and
	# leaves every brick standing.
	var radius := clampf(IMPACT_RADIUS * severity * 0.08, IMPACT_RADIUS, IMPACT_RADIUS_MAX)
	world.set_chunk_transform(isl.chunk, isl.chunk_transform())

	# Sample across the bottom face: these are hollow wall sections, so a single
	# sample at the bounding-box centre usually finds empty air.
	var loosened := PackedInt32Array()
	var steps := clampi(int(maxf(aabb.size.x, aabb.size.z) / maxf(radius, 0.1)), 1, 5)
	for ix in steps + 1:
		for iz in steps + 1:
			var local := aabb.position + Vector3(
					aabb.size.x * float(ix) / float(steps),
					0.0,
					aabb.size.z * float(iz) / float(steps))
			loosened.append_array(world.separate_near(
					isl.chunk, isl.mesh.global_transform * local, radius))
	if loosened.is_empty():
		return

	isl.impacts += 1
	_impact_count += 1
	_impact_blocks += loosened.size()
	_split_if_broken(isl)
	_rebuild_island_mesh(isl)
	_update_hud()


# ---------------------------------------------------------------------------

var _last_upload_ms := 0.0
var _chunk_mesh: ArrayMesh
var _index_bytes := 0
var _index_width := 4


## Build the surface once; after that only patch the index bytes that changed.
##
## Handing Godot a fresh ArrayMesh re-uploads the ENTIRE vertex buffer, which
## measured 175 ms per cascade step at 16.5k blocks and was the whole reason the
## 150 m gate failed. The vertex buffer never changes under damage — only which
## faces are indexed — so it has no business being re-sent.
func _rebuild_mesh(force_full: bool = false) -> void:
	# `_index_bytes` is 0 whenever the surface is too small to carry 32-bit
	# indices; see IslandManager.index_patch_bytes for why that rules out
	# patching it.
	if _chunk_mesh != null and _index_bytes > 0 and not force_full:
		var t := Time.get_ticks_usec()
		var region: Dictionary = world.update_index_region(chunk_id, _index_width)
		_last_mesh_ms = float(region.get("update_ms", 0.0))
		if int(region.get("changed_bytes", 0)) > 0:
			RenderingServer.mesh_surface_update_index_region(
					_chunk_mesh.get_rid(), 0, int(region.offset), region.data)
		_last_upload_ms = (Time.get_ticks_usec() - t) / 1000.0 - _last_mesh_ms
		_last_changed_bytes = int(region.get("changed_bytes", 0))
		_update_hud()
		return

	var t0 := Time.get_ticks_usec()
	var arrays: Array = world.build_chunk_mesh(chunk_id)
	_last_mesh_ms = (Time.get_ticks_usec() - t0) / 1000.0

	var t1 := Time.get_ticks_usec()
	_chunk_mesh = ArrayMesh.new()
	if not arrays.is_empty():
		_chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_index_bytes = (IslandManager.index_patch_bytes(arrays)
			if _chunk_mesh.get_surface_count() > 0 else 0)
	_index_width = IslandManager.index_width(arrays)
	mesh_instance.mesh = _chunk_mesh
	_last_upload_ms = (Time.get_ticks_usec() - t1) / 1000.0
	_last_changed_bytes = -1
	mesh_instance.transform = world.get_chunk_transform(chunk_id)
	_update_hud()


var _last_changed_bytes := -1


func _report_stress() -> void:
	_last_stress = world.solve_stress(chunk_id)
	print("[sandbox] stress: max tension %.4f of capacity, peak load %.1f, %.0f per stud, %d joint(s) released, %.2f ms" % [
		_last_stress.max_ratio, _last_stress.peak_load,
		world.get_tension_per_stud(chunk_id), _last_stress.failures, _last_stress.solve_ms])
	_update_hud()


func _update_hud() -> void:
	if stats_label == null:
		return
	var s: Dictionary = world.get_mesh_stats(chunk_id)
	var island_blocks := 0
	for isl in _islands:
		if isl.is_valid():
			island_blocks += world.get_alive_block_count(isl.chunk)
	var lines := [
		"standing      %d / %d blocks" % [world.get_alive_block_count(chunk_id), world.get_block_count(chunk_id)],
		"islands       %d  (%d settled, %d blocks)" % [_islands.size(), _settled, island_blocks],
		"impacts       %d landing(s), %d blocks lost, %d split(s)" % [
			_impact_count, _impact_blocks, _fracture_count],
		"triangles     %d   (%.1f%% of faces culled)" % [s.triangles, s.cull_ratio * 100.0],
		"mesh build    %.2f ms" % _last_mesh_ms,
	]
	if not _last_stress.is_empty():
		lines.append("tension       max %.3f of capacity · %d joint(s) released · %.2f ms" % [
			_last_stress.max_ratio, _last_stress.failures, _last_stress.solve_ms])
	if not _last_collapse.is_empty():
		lines.append("last blast    %d destroyed · %d joint(s) released · %d detached · %d island(s)" % [
			_last_collapse.get("killed", 0), _last_collapse.get("released", 0),
			_last_collapse.get("detached", 0), _last_collapse.get("islands", 0)])
	if _collapsing:
		lines.append("COLLAPSING    cascade step %d" % _cascade_steps)
	lines.append("")
	lines.append("LMB/SPACE fire · X wider · WASD/QE fly · shift fast")
	lines.append("R rebuild · L seams · G stress · F1 stats · ESC mouse")
	stats_label.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_fire()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			_fire()
		KEY_X:
			_fire(BLAST_RADIUS * 2.6)
		KEY_R:
			_rebuild_mesh()
		KEY_G:
			_report_stress()
		KEY_F1:
			stats_label.visible = not stats_label.visible
		KEY_L:
			var on: bool = brick_material.get_shader_parameter("seams_enabled")
			brick_material.set_shader_parameter("seams_enabled", not on)


## Per-FRAME time, not Engine.get_frames_per_second(). That reports how many
## frames rendered in the last SECOND, so a single stall drags a whole window
## down and the "minimum" says nothing about any actual frame.
func _process(delta: float) -> void:
	if not _fps_sampling:
		return
	var ms := delta * 1000.0
	_frame_worst = maxf(_frame_worst, ms)
	_frame_sum += ms
	_frame_samples += 1
	if ms > 16.7:
		_frames_over_60 += 1
	if ms > 33.3:
		_frames_over_30 += 1


# ---------------------------------------------------------------------------
# Automated capture
# ---------------------------------------------------------------------------

func _run_shot_pass() -> void:
	var tag := "m3_tall" if _tall else "m3"
	camera.position = Vector3(-6.0, 11.0, -13.0) if not _tall else Vector3(-40.0, 60.0, -150.0)
	camera.rotation = Vector3(-0.16, -2.57, 0.0) if not _tall else Vector3(-0.22, -2.85, 0.0)
	await _settle_frames(4)
	await _save("%s_intact" % tag)

	# Cut a ring right around the building near the top.
	#
	# Slotting ONE wall isolates nothing: courses alternate which pair of walls
	# owns the corners, so every wall is tied into its neighbours all the way up
	# and a section above a single-wall cut still hangs from them at 0.28 of
	# capacity. Correct for a bonded box, and a poor test -- it produced no
	# islands at all. A ring severs every tie at one height.
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	var cut_course := 33 if not _tall else 340
	var slot_y := (1 + cut_course * TowerRecipe.PLATES_PER_COURSE) * plate
	var fx := (48 if _tall else 24) * stud
	var fz := (48 if _tall else 16) * stud
	var points: Array[Vector3] = []
	var px := 0.3
	while px < fx:
		points.append(Vector3(px, slot_y, 0.35))
		points.append(Vector3(px, slot_y, fz - 0.35))
		px += 1.4
	var pz := 0.3
	while pz < fz:
		points.append(Vector3(0.35, slot_y, pz))
		points.append(Vector3(fx - 0.35, slot_y, pz))
		pz += 1.4
	for pt in points:
		_blast_at(pt, 1.1)
	await _settle_frames(2)
	_fps_sampling = true
	await _settle_frames(2)
	await _save("%s_cut" % tag)

	await _settle_frames(40)
	await _save("%s_falling" % tag)

	await _settle_frames(260)
	await _save("%s_fallen" % tag)

	print("[sandbox] final: %d standing, %d islands (%d settled); %d hard landing(s) cost %d blocks and caused %d split(s)" % [
		world.get_alive_block_count(chunk_id), _islands.size(), _settled,
		_impact_count, _impact_blocks, _fracture_count])
	_report_island_motion()
	get_tree().quit()


func _report_island_motion() -> void:
	var moved := 0
	var max_drop := 0.0
	for isl in _islands:
		if not isl.is_valid():
			continue
		var spawn: Vector3 = isl.body.get_meta("spawn_pos", isl.body.position)
		var d := spawn.distance_to(isl.body.position)
		if d > 0.1:
			moved += 1
		max_drop = maxf(max_drop, spawn.y - isl.body.position.y)
		print("[sandbox]   island chunk %d: %d blocks, peak speed %.1f m/s, biggest single-tick loss %.2f m/s, %d fracture(s)" % [
			isl.chunk, world.get_alive_block_count(isl.chunk), isl.peak_speed,
			isl.max_speed_lost, isl.impacts])
	print("[sandbox] island motion: %d of %d moved >10 cm, largest drop %.2f m" % [
		moved, _islands.size(), max_drop])
	if _frame_samples > 0:
		print("[sandbox] frame time through the collapse: mean %.1f ms, worst %.1f ms, %d of %d frames over 16.7 ms (%d over 33.3)" % [
			_frame_sum / _frame_samples, _frame_worst, _frames_over_60, _frame_samples,
			_frames_over_30])


func _settle_frames(frames: int) -> void:
	for i in frames:
		await RenderingServer.frame_post_draw


## Pauses frame-rate sampling: pulling the framebuffer back to the CPU stalls
## the frame hard, and it is the capture harness, not the game.
func _save(shot_name: String) -> void:
	var was_sampling := _fps_sampling
	_fps_sampling = false
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/%s.png" % shot_name)
	print("[sandbox] shot written: %s.png" % shot_name)
	# Skip one more frame so the stall itself is not sampled either.
	await RenderingServer.frame_post_draw
	_fps_sampling = was_sampling


# ---------------------------------------------------------------------------
# Scene furniture
# ---------------------------------------------------------------------------

func _build_scenery() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.55, 0.78)
	sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.83)
	sky_mat.ground_bottom_color = Color(0.30, 0.31, 0.29)
	sky_mat.ground_horizon_color = Color(0.72, 0.78, 0.83)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -40, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	ground.collision_mask = Layers.STRUCTURE_MASK
	var gcs := CollisionShape3D.new()
	gcs.shape = WorldBoundaryShape3D.new()
	ground.add_child(gcs)
	var gmesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	gmesh.mesh = plane
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.34, 0.35, 0.33)
	gmat.roughness = 1.0
	gmesh.material_override = gmat
	ground.add_child(gmesh)
	add_child(ground)

	brick_material = ShaderMaterial.new()
	brick_material.shader = load("res://shaders/brick.gdshader")
	brick_material.set_shader_parameter("seams_enabled", true)

	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "ChunkMesh"
	mesh_instance.material_override = brick_material
	add_child(mesh_instance)

	camera = DebugCamera.new()
	camera.name = "DebugCamera"
	camera.capture_mouse = not _shot_mode
	camera.far = 3000.0
	camera.position = Vector3(-6.0, 11.0, -13.0)
	camera.rotation = Vector3(-0.16, -2.57, 0.0)
	add_child(camera)

	var layer := CanvasLayer.new()
	stats_label = Label.new()
	stats_label.position = Vector2(14, 12)
	stats_label.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	stats_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	stats_label.add_theme_constant_override("outline_size", 4)
	layer.add_child(stats_label)
	add_child(layer)
