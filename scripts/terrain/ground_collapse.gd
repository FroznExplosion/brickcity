extends Node3D

## The mine world's ground coming down (Docs/TerrainCollapse.md): what an edit
## lets go, asked of TerrainCollapse.survey on a worker, and what that answers
## made to happen -- sand and gravel falling straight down and landing as
## ground again, loose ground falling as pieces (PlanetPieces) that stay.
##
## Owned by the mine world (mine_world.gd): it hands every edit to `queue`,
## a shot that meets a piece to `shoot`, and saves and loads `to_save` /
## `restore` with its edits. Preloaded by path, not named, as the scene's
## other parts are (terrain_scene.gd).

## Edits gathered for this long before a survey, as the tiles' refresh is.
const SURVEY_EVERY := 0.1
## What a stud of ground holds: the buildings' (BrickStrength.tension(),
## the Options menu's Stud Strength) times this.
const TERRAIN_TIMES := 1.0
## Falling sand: as a falling piece falls (PlanetPieces.GRAVITY_SCALE).
const SAND_GRAVITY_SCALE := 1.6
const SAND_MAX_SPEED := 40.0
## A column falls at most this far (m) before it is dropped, not landed: out
## of the world.
const SAND_MAX_DROP := 400.0
## Settled pieces are unloaded / laid again this often (s).
const TEND_EVERY := 0.5
## Waiting for a tile to be rebuilt at most this long (ms) before letting go
## anyway.
const WAIT_MAX_MS := 2000
## Pieces laid at once at most, the nearest the player (Docs/TerrainCollapse.md
## 5): past it the farthest settled ones are put away.
const MAX_LOADED := 100
## A piece of this many bricks or fewer is DELETED when put away (out of the
## detail tiles, or over the cap); a bigger one is unloaded to a record and
## laid again when near.
const SMALL_MAX := 3
## A put-away piece is laid again in place of a laid one only when it is this
## much nearer (m): no swapping back and forth at the edge of the cap.
const SWAP_MARGIN := 8.0
## Laid again at most this many a tend: a walk into a field of them is spread.
const RELOAD_PER_TEND := 12

## The mine world (untyped: the two scripts would type each other).
var world: Node3D = null
var bricks: BrickWorld = null
var pieces: PlanetPieces = null
var palette := {}

## Edit boxes waiting for a survey: [lo, hi] (plates), each at most MAX_BOX.
## Boxes near each other are one; far apart, or a shaft dug a long way down,
## are several surveys -- one box round all of them was a region hundreds of
## bricks tall (and the scene crashed under a 120 m shaft, Docs/MineWater.md 14).
var _boxes: Array = []
## Studs (x, z) and plates (y) a queued box may grow to by merging.
const MAX_BOX := Vector3i(32, 96, 32)
## Boxes this close (studs / plates) merge.
const MERGE_GAP := 6
var _survey_in := 0.0
var _job := -1
var _holder := [null]
## What a survey let go, held until the tiles over it are rebuilt without it
## (the old tile draws it till then): {rect, born, kind, ...}.
var _waiting: Array = []
## Falling columns: {x, z, y (metres, bottom), v, mats, drop}.
var _sand: Array = []
var _sand_mm: MultiMeshInstance3D = null
## Settled pieces whose tile is not near-detail: tile -> [records].
var _dormant := {}
var _tend_in := TEND_EVERY

## Counters, for the readout and the gate.
var surveys := 0
var solves := 0
var groups_let_go := 0
var bricks_let_go := 0
var columns_fell := 0
var columns_landed := 0
var unloaded := 0
var reloaded := 0
var deleted := 0
var columns_on_pieces := 0
## MAX_LOADED, settable (the gate shrinks it).
var max_loaded := MAX_LOADED
var worst_survey_ms := 0.0
var last_survey_ms := 0.0
var worst_apply_ms := 0.0


func setup(w: Node3D, brick_material: Material) -> void:
	world = w
	bricks = BrickWorld.new()
	palette = BrickPalette.bake(bricks)
	pieces = PlanetPieces.new()
	pieces.name = "Pieces"
	# Every piece stays (the user, 2026-11-17: to change later): no cap, no
	# group too small to be a piece.
	pieces.max_pieces = 1 << 30
	# What a landing knocks off a piece: SMALL_MAX bricks or fewer are crumbs
	# that fly and shrink away (the city's rule), not pieces that lie forever.
	pieces.debris_max = SMALL_MAX
	pieces.studs = true
	add_child(pieces)
	pieces.setup(bricks, w, brick_material)
	_sand_mm = MultiMeshInstance3D.new()
	_sand_mm.name = "FallingSand"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3(BrickWorld.get_stud_metres(), BrickTerrain.get_brick_metres(), BrickWorld.get_stud_metres())
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	box.material = mat
	mm.mesh = box
	mm.instance_count = 64
	mm.visible_instance_count = 0
	_sand_mm.multimesh = mm
	# Moved in _process each frame: no physics interpolation on it.
	_sand_mm.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_sand_mm)


## The world is being made again (generate): everything of the old one goes.
func reset() -> void:
	if _job >= 0:
		WorkerThreadPool.wait_for_task_completion(_job)
		_job = -1
	_boxes.clear()
	for w in _waiting:
		if w.kind == "piece" and int(w.chunk) >= 0:
			bricks.release_chunk(int(w.chunk))
	_waiting.clear()
	_sand.clear()
	_sand_mm.multimesh.visible_instance_count = 0
	_dormant.clear()
	for p in pieces.pieces:
		if is_instance_valid(p.body):
			p.body.queue_free()
		if p.chunk >= 0:
			bricks.release_chunk(p.chunk)
	pieces.pieces.clear()
	pieces.settled_count = 0


## A plate box of the field changed (BrickTerrain.fill_box / clear_runs'
## box_lo, box_hi): surveyed with the others gathered.
func queue(res: Dictionary) -> void:
	if not res.has("box_lo"):
		return
	var lo: Vector3i = res.box_lo
	var hi: Vector3i = res.box_hi
	if _boxes.is_empty():
		_survey_in = SURVEY_EVERY
	# Too big for one survey (a big piece's cells cleared): in parts.
	for z in range(lo.z, hi.z + 1, MAX_BOX.z):
		for y in range(lo.y, hi.y + 1, MAX_BOX.y):
			for x in range(lo.x, hi.x + 1, MAX_BOX.x):
				var a := Vector3i(x, y, z)
				_add_box(a, Vector3i(mini(hi.x, x + MAX_BOX.x - 1), mini(hi.y, y + MAX_BOX.y - 1),
						mini(hi.z, z + MAX_BOX.z - 1)))


func _add_box(lo: Vector3i, hi: Vector3i) -> void:
	var g := Vector3i(MERGE_GAP, MERGE_GAP, MERGE_GAP)
	for b in _boxes:
		var blo: Vector3i = b[0]
		var bhi: Vector3i = b[1]
		var near := lo.x <= bhi.x + g.x and hi.x >= blo.x - g.x and lo.y <= bhi.y + g.y \
				and hi.y >= blo.y - g.y and lo.z <= bhi.z + g.z and hi.z >= blo.z - g.z
		if not near:
			continue
		var mlo := Vector3i(mini(lo.x, blo.x), mini(lo.y, blo.y), mini(lo.z, blo.z))
		var mhi := Vector3i(maxi(hi.x, bhi.x), maxi(hi.y, bhi.y), maxi(hi.z, bhi.z))
		var size := mhi - mlo + Vector3i.ONE
		if size.x <= MAX_BOX.x and size.y <= MAX_BOX.y and size.z <= MAX_BOX.z:
			b[0] = mlo
			b[1] = mhi
			return
	_boxes.append([lo, hi])


func busy() -> bool:
	return _job >= 0 or not _boxes.is_empty() or not _waiting.is_empty() or not _sand.is_empty() \
			or pieces.moving() > 0


## The last frame's _process, microseconds (the mine world's --gate=stop).
var last_us := 0


func _process(delta: float) -> void:
	var t_in := Time.get_ticks_usec()
	_process_body(delta)
	last_us = Time.get_ticks_usec() - t_in


func _process_body(delta: float) -> void:
	if world == null:
		return
	_warm_up()
	_land_survey()
	if not _boxes.is_empty() and _job < 0:
		_survey_in -= delta
		if _survey_in <= 0.0:
			_start_survey()
	_release()
	_fall_sand(delta)
	_tend_in -= delta
	if _tend_in <= 0.0:
		_tend_in = TEND_EVERY
		_tend()


## One stud drawn for a few frames, tiny, in front of the camera, when the
## world starts: the first piece's studs cost a ~260 ms frame (the brick
## shader's pipeline for an instanced, coloured mesh, made on first draw).
var _warm: MultiMeshInstance3D = null
var _warm_frames := -1


func _warm_up() -> void:
	if _warm_frames == 0:
		return
	if _warm == null:
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam == null:
			return
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = PieceMeshes.stud()
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis.from_scale(Vector3.ONE * 0.001), Vector3.ZERO))
		mm.set_instance_color(0, Color.WHITE)
		_warm = MultiMeshInstance3D.new()
		_warm.multimesh = mm
		_warm.material_override = pieces.brick_material
		_warm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		cam.add_child(_warm)
		_warm.position = Vector3(0, 0, -0.5)
		_warm_frames = 4
		return
	_warm_frames -= 1
	if _warm_frames == 0:
		_warm.queue_free()
		_warm = null


func _start_survey() -> void:
	var box: Array = _boxes.pop_front()
	var lo: Vector3i = box[0]
	var hi: Vector3i = box[1]
	var t := BrickStrength.tension() * TERRAIN_TIMES
	var m := BrickPalette.MASS_PER_CELL
	var holder := [null]
	_holder = holder
	_job = WorkerThreadPool.add_task(func() -> void:
			var t0 := Time.get_ticks_usec()
			var r: Dictionary = TerrainCollapse.survey(lo, hi, t, m)
			r["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
			holder[0] = r, false, "ground survey")


## A finished survey: never waits for one.
func _land_survey() -> void:
	if _job < 0 or not WorkerThreadPool.is_task_completed(_job):
		return
	WorkerThreadPool.wait_for_task_completion(_job)
	_job = -1
	var r: Dictionary = _holder[0]
	if r == null:
		return
	surveys += 1
	last_survey_ms = float(r.get("ms", 0.0))
	worst_survey_ms = maxf(worst_survey_ms, last_survey_ms)
	if bool(r.get("solved", false)):
		solves += 1
	var t0 := Time.get_ticks_usec()
	_let_sand_go(r.sand, r.sand_mats)
	for g in r.groups:
		_let_group_go(g)
	worst_apply_ms = maxf(worst_apply_ms, (Time.get_ticks_usec() - t0) / 1000.0)


func _tiles_rect(res: Dictionary) -> Rect2i:
	var tiles: PackedInt32Array = res.get("tiles", PackedInt32Array())
	if tiles.is_empty():
		return Rect2i()
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for i in range(0, tiles.size(), 2):
		lo = Vector2i(mini(lo.x, tiles[i]), mini(lo.y, tiles[i + 1]))
		hi = Vector2i(maxi(hi.x, tiles[i]), maxi(hi.y, tiles[i + 1]))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


# --- sand ----------------------------------------------------------------------

func _let_sand_go(cols: PackedInt32Array, mats: PackedByteArray) -> void:
	if cols.is_empty():
		return
	var runs := PackedInt32Array()
	var out: Array = []
	var k := 0
	var plate := BrickWorld.get_plate_metres()
	var stud := BrickWorld.get_stud_metres()
	for i in range(0, cols.size(), 4):
		var n := cols[i + 3]
		runs.append_array([cols[i], cols[i + 1], cols[i + 2], cols[i + 2] + n * 3 - 1])
		out.append({"x": cols[i], "z": cols[i + 1], "y": cols[i + 2] * plate, "v": 0.0,
				"mats": mats.slice(k, k + n), "drop": 0.0,
				"at": Vector2((cols[i] + 0.5) * stud, (cols[i + 1] + 0.5) * stud)})
		k += n
	var res: Dictionary = BrickTerrain.clear_runs(runs)
	if int(res.get("removed", 0)) == 0:
		return
	columns_fell += out.size()
	world.terrain_edited(res)
	_waiting.append({"kind": "sand", "rect": _tiles_rect(res), "born": Time.get_ticks_msec(),
			"cols": out})


func _fall_sand(delta: float) -> void:
	if _sand.is_empty():
		if _sand_mm.multimesh.visible_instance_count != 0:
			_sand_mm.multimesh.visible_instance_count = 0
		return
	var g := Gravity.strength() * SAND_GRAVITY_SCALE
	var plate := BrickWorld.get_plate_metres()
	var brick := BrickTerrain.get_brick_metres()
	var space := get_world_3d().direct_space_state
	var i := _sand.size() - 1
	while i >= 0:
		var c: Dictionary = _sand[i]
		c.v = minf(float(c.v) + g * delta, SAND_MAX_SPEED)
		var step := float(c.v) * delta
		# A piece under it this frame: it lands on the piece, as a piece.
		var at2: Vector2 = c.at
		var from := Vector3(at2.x, float(c.y) + 0.02, at2.y)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (step + 0.04),
				Layers.DEBRIS | Layers.FALLING)
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and _is_piece_body(hit.collider):
			_land_on_piece(c, float(hit.position.y))
			_sand.remove_at(i)
			i -= 1
			continue
		# Down a plate at a time: never through a floor in one frame.
		var y := float(c.y)
		var done := false
		while step > 0.0:
			var d := minf(step, plate)
			var below := floori((y - d) / plate)
			if BrickTerrain.solid_at(int(c.x), below, int(c.z)) != 0:
				# Rests on that plate's top.
				y = (below + 1) * plate
				done = true
				break
			y -= d
			step -= d
		c.drop = float(c.drop) + (float(c.y) - y)
		c.y = y
		if done:
			_land_column(c)
			_sand.remove_at(i)
		elif float(c.drop) > SAND_MAX_DROP:
			_sand.remove_at(i)
		i -= 1
	var n := 0
	for c in _sand:
		n += (c.mats as PackedByteArray).size()
	var mm := _sand_mm.multimesh
	if mm.instance_count < n:
		# Grown, never shrunk every frame: a buffer swapped while drawn.
		mm.instance_count = maxi(n, maxi(mm.instance_count * 2, 64))
	mm.visible_instance_count = n
	var k := 0
	for c in _sand:
		var at: Vector2 = c.at
		var mats: PackedByteArray = c.mats
		for j in mats.size():
			var p := Vector3(at.x, float(c.y) + (j + 0.5) * brick, at.y)
			mm.set_instance_transform(k, Transform3D(Basis(), p))
			mm.set_instance_color(k, _colour(mats[j]))
			k += 1


func _is_piece_body(o: Object) -> bool:
	for p in pieces.pieces:
		if p.body == o:
			return true
	return false


## A column that met a piece: a piece of its own (1x1 bricks, as it fell),
## dropped onto the piece it met. Drawn by the boxes it fell as.
func _land_on_piece(c: Dictionary, top_y: float) -> void:
	var mats: PackedByteArray = c.mats
	var n := mats.size()
	if n == 0:
		return
	var stud := BrickWorld.get_stud_metres()
	var brick := BrickTerrain.get_brick_metres()
	var chunk := bricks.create_chunk(Vector3i.ZERO, Vector3i(1, n * 3, 1))
	var cells := PackedInt32Array()
	var archs := PackedInt32Array()
	var cols := PackedByteArray()
	var one := int(palette.get("brick_1x1", 0))
	var holder := Node3D.new()
	add_child(holder)
	for j in n:
		cells.append_array([0, j * 3, 0])
		archs.append(one)
		cols.append(BrickTerrain.material_filament_index(mats[j]))
		var mi := MeshInstance3D.new()
		mi.mesh = _sand_mm.multimesh.mesh
		mi.material_override = _box_material(mats[j])
		mi.position = Vector3(stud * 0.5, (j + 0.5) * brick, stud * 0.5)
		holder.add_child(mi)
	bricks.place_blocks(chunk, Vector3i.ZERO, cells, archs, cols)
	bricks.set_tension_per_stud(chunk, BrickStrength.tension() * TERRAIN_TIMES)
	# Chunk transforms are global; the column is in the terrain frame (the
	# mine world's origin shift, Docs/MineWorld.md 15).
	bricks.set_chunk_transform(chunk, world.global_transform * Transform3D(Basis(),
			Vector3(int(c.x) * stud, top_y + 0.02, int(c.z) * stud)))
	var p := pieces.adopt(chunk, holder)
	pieces.toppled -= 1
	p.body.linear_velocity = Vector3.DOWN * minf(float(c.v), 6.0)
	columns_on_pieces += 1


static var _box_mats := {}

static func _box_material(m: int) -> StandardMaterial3D:
	if not _box_mats.has(m):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _colour(m)
		mat.roughness = 0.9
		_box_mats[m] = mat
	return _box_mats[m]


## Its cells written back where it came to rest: plate `bottom` up, a brick a
## cell, only into air (a landing on what came since stacks on it).
func _land_column(c: Dictionary) -> void:
	var plate := BrickWorld.get_plate_metres()
	var bottom := roundi(float(c.y) / plate)
	var mats: PackedByteArray = c.mats
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	var tiles := {}
	for j in mats.size():
		var y0 := bottom + j * 3
		var r: Dictionary = BrickTerrain.fill_box(Vector3i(int(c.x), y0, int(c.z)),
				Vector3i(int(c.x), y0 + 2, int(c.z)), mats[j], true)
		if int(r.get("changed", 0)) == 0:
			continue
		lo = Vector3i(mini(lo.x, r.box_lo.x), mini(lo.y, r.box_lo.y), mini(lo.z, r.box_lo.z))
		hi = Vector3i(maxi(hi.x, r.box_hi.x), maxi(hi.y, r.box_hi.y), maxi(hi.z, r.box_hi.z))
		var t: PackedInt32Array = r.tiles
		for q in range(0, t.size(), 2):
			tiles[Vector2i(t[q], t[q + 1])] = true
	if tiles.is_empty():
		return
	columns_landed += 1
	var flat := PackedInt32Array()
	for t in tiles:
		flat.append_array([t.x, t.y])
	world.terrain_edited({"tiles": flat, "box_lo": lo, "box_hi": hi, "changed": 1})


static var _colours := {}

static func _colour(m: int) -> Color:
	if not _colours.has(m):
		_colours[m] = BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(m))
	return _colours[m]


# --- pieces --------------------------------------------------------------------

## One loose group: its cells cleared, its bricks laid in a chunk of ours,
## its mesh begun; it falls once the tiles over it are rebuilt without it.
func _let_group_go(g: PackedInt32Array) -> void:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	var runs := PackedInt32Array()
	for i in range(0, g.size(), 6):
		var x := g[i]
		var y := g[i + 1]
		var z := g[i + 2]
		lo = Vector3i(mini(lo.x, x), mini(lo.y, y), mini(lo.z, z))
		hi = Vector3i(maxi(hi.x, x + g[i + 3] - 1), maxi(hi.y, y + 2), maxi(hi.z, z + g[i + 4] - 1))
		for dz in g[i + 4]:
			for dx in g[i + 3]:
				runs.append_array([x + dx, z + dz, y, y + 2])
	var res: Dictionary = BrickTerrain.clear_runs(runs)
	if int(res.get("removed", 0)) == 0:
		return
	world.terrain_edited(res)
	# Grid from zero, placed by its transform, as every piece's is (split_island):
	# piece_at and the landing rule read the grid in the chunk's own frame.
	var chunk := bricks.create_chunk(Vector3i.ZERO, hi - lo + Vector3i.ONE)
	bricks.set_chunk_transform(chunk, world.global_transform * Transform3D(Basis(), BrickWorld.grid_to_world(lo)))
	var cells := PackedInt32Array()
	var archs := PackedInt32Array()
	var cols := PackedByteArray()
	@warning_ignore("integer_division")
	var n := g.size() / 6
	cells.resize(n * 3)
	archs.resize(n)
	cols.resize(n)
	for b in n:
		var i := b * 6
		cells[b * 3] = g[i] - lo.x
		cells[b * 3 + 1] = g[i + 1] - lo.y
		cells[b * 3 + 2] = g[i + 2] - lo.z
		archs[b] = int(palette.get(_part(g[i + 3], g[i + 4]), palette.get("brick_1x1", 0)))
		cols[b] = BrickTerrain.material_filament_index(g[i + 5])
	bricks.place_blocks(chunk, Vector3i.ZERO, cells, archs, cols)
	bricks.set_tension_per_stud(chunk, BrickStrength.tension() * TERRAIN_TIMES)
	bricks.bake_chunk_async(chunk)
	groups_let_go += 1
	bricks_let_go += n
	_waiting.append({"kind": "piece", "rect": _tiles_rect(res), "born": Time.get_ticks_msec(),
			"chunk": chunk, "job": []})


static func _part(sx: int, sz: int) -> String:
	match Vector2i(sx, sz):
		Vector2i(4, 2): return "brick_2x4_x"
		Vector2i(2, 4): return "brick_2x4_z"
		Vector2i(2, 2): return "brick_2x2"
		Vector2i(2, 1): return "brick_1x2_x"
		Vector2i(1, 2): return "brick_1x2_z"
	return "brick_1x1"


## What waits for its tiles: let go once they are rebuilt (and a piece's mesh
## made), so the old tile and the falling thing never draw together.
func _release() -> void:
	var now := Time.get_ticks_msec()
	var i := 0
	while i < _waiting.size():
		var w: Dictionary = _waiting[i]
		if w.kind == "piece" and not _mesh_ready(w):
			i += 1
			continue
		var fresh: bool = world.tiles_fresh(w.rect)
		if not fresh and now - int(w.born) < WAIT_MAX_MS:
			i += 1
			continue
		_waiting.remove_at(i)
		if w.kind == "sand":
			_sand.append_array(w.cols)
		else:
			var p := pieces.adopt(int(w.chunk), null)
			pieces.toppled -= 1
			var mi: MeshInstance3D = w.get("mesh")
			if mi == null:
				pieces._start_mesh(p)
			else:
				# The mesh made while it waited, on the body as _hang_mesh puts one.
				mi.position = -p.local_com
				p.mesh_node = mi
				p.body.add_child(mi)


## A waiting piece's mesh: its bake on a worker, then the ArrayMesh on one.
func _mesh_ready(w: Dictionary) -> bool:
	if w.has("mesh"):
		return true
	var chunk := int(w.chunk)
	var job: Array = w.job
	if job.is_empty():
		if not bricks.bake_ready(chunk):
			return false
		var arrays: Array = bricks.build_chunk_mesh(chunk)
		if arrays.is_empty():
			w["mesh"] = null
			return true
		var holder := [null]
		var task := WorkerThreadPool.add_task(func() -> void:
				var m := ArrayMesh.new()
				m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, IslandManager.UPLOAD_COMPRESS)
				holder[0] = m, false, "ground piece")
		w["job"] = [task, holder]
		return false
	if not WorkerThreadPool.is_task_completed(int(job[0])):
		return false
	WorkerThreadPool.wait_for_task_completion(int(job[0]))
	# Waited: forget it, or _exit_tree waits on it again ("Invalid Task ID").
	w["job"] = []
	var mesh: ArrayMesh = (job[1] as Array)[0]
	if mesh == null:
		w["mesh"] = null
		return true
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = pieces.brick_material
	mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	pieces.add_studs(mi, int(w.chunk))
	w["mesh"] = mi
	return true


## The piece whose body is `o`, or null.
func piece_of_body(o: Object) -> PlanetPieces.Piece:
	for p in pieces.pieces:
		if p.body == o and p.fading_since == 0:
			return p
	return null


## The brick of piece `p` at world `point`, as an outline's transform (a unit
## box scaled to it, a hair larger), or null when no live brick is there.
func piece_brick_xform(p: PlanetPieces.Piece, point: Vector3) -> Variant:
	var xf := bricks.get_chunk_transform(p.chunk)
	var l := xf.affine_inverse() * point
	var cs := BrickWorld.get_cell_size()
	var dims := bricks.get_chunk_dims(p.chunk)
	var c := Vector3i(floori(l.x / cs.x), floori(l.y / cs.y), floori(l.z / cs.z))
	if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= dims.x or c.y >= dims.y or c.z >= dims.z:
		return null
	var bid := bricks.block_at(p.chunk, c + bricks.get_chunk_origin(p.chunk))
	if bid < 0 or not bricks.is_block_alive(p.chunk, bid) or bricks.is_block_absent(p.chunk, bid):
		return null
	var box := bricks.get_blocks_box(p.chunk, PackedInt32Array([bid]))
	return xf * Transform3D(Basis.from_scale(box.size * 1.004), box.position - box.size * 0.002)


## Mined (build mode): the brick of `p` at world `point` goes, whole. True if
## one did.
func mine_piece(p: PlanetPieces.Piece, point: Vector3) -> bool:
	return pieces.damage(p, point, {"blast": false, "radius": 0.0, "hp": 1 << 20}) > 0


## A shot at world `point` meeting a piece: it is that piece's. False when
## there is no piece there.
func shoot(point: Vector3, dir: Vector3, shot) -> bool:
	# Past the studs' shapes into the brick, and THERE for the damage too: a
	# round that met a top face 5 cm in wore the empty stud layer, forever.
	var inside := point + dir.normalized() * 0.1
	var p := pieces.piece_at(inside)
	if p == null:
		return false
	pieces.damage(p, inside, shot if shot is Dictionary else {})
	return true


# --- kept, unloaded, saved -----------------------------------------------------

func _tile_of(p: PlanetPieces.Piece) -> Vector2i:
	# Piece boxes are global; tiles are in the mine world's terrain frame
	# (its origin shift, Docs/MineWorld.md 15).
	var c: Vector3 = world.to_local(pieces.world_box(p).get_center())
	var tm := BrickTerrain.get_tile_studs() * BrickWorld.get_stud_metres()
	return Vector2i(floori(c.x / tm), floori(c.z / tm))


func _record(p: PlanetPieces.Piece) -> Dictionary:
	var r := ChunkRecord.capture(bricks, p.chunk)
	if r.block_count() == 0:
		return {}
	return {"record": r.to_data(bricks),
			"at": world.global_transform.affine_inverse() * bricks.get_chunk_transform(p.chunk),
			"mid": world.global_transform.affine_inverse() * pieces.world_box(p).get_center()}


## Settled pieces out of the near-detail tier are put away; past max_loaded
## the farthest from the player are too. Put away: a piece of more than
## SMALL_MAX bricks to a record where it lies (laid again when its tile is
## near-detail and there is room, nearest first), a smaller one deleted.
func _tend() -> void:
	# Global, as the pieces' boxes are (world._eye() is the terrain frame).
	var eye: Vector3 = world._eye_render()
	var i := pieces.pieces.size() - 1
	while i >= 0:
		var p: PlanetPieces.Piece = pieces.pieces[i]
		i -= 1
		if not p.settled or p.fading_since != 0 or not is_instance_valid(p.body):
			continue
		if not world.near_tile(_tile_of(p)):
			_put_away(p, false)
	# Over the cap: the farthest settled ones go.
	var laid := _laid()
	if laid.size() > max_loaded:
		var far := _settled_by_distance(eye)
		var k := far.size() - 1
		while laid.size() > max_loaded and k >= 0:
			_put_away(far[k][1], true)
			laid.erase(far[k][1])
			k -= 1
	# Laid again: the nearest put-away pieces whose tile is near-detail, while
	# there is room -- or in place of a laid one well farther off.
	var want: Array = []
	var xf := world.global_transform
	for t in _dormant:
		if not world.near_tile(t):
			continue
		for d in _dormant[t]:
			var local: Vector3 = d.get("mid", (d.at as Transform3D).origin)
			want.append([eye.distance_to(xf * local), t, d])
	if want.is_empty():
		return
	want.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var far2 := _settled_by_distance(eye)
	var n := 0
	for w in want:
		if n >= RELOAD_PER_TEND:
			break
		if laid.size() >= max_loaded:
			if far2.is_empty() or float(far2[-1][0]) < float(w[0]) + SWAP_MARGIN:
				break
			var gone: PlanetPieces.Piece = far2.pop_back()[1]
			_put_away(gone, true)
			laid.erase(gone)
		var recs: Array = _dormant[w[1]]
		recs.erase(w[2])
		if recs.is_empty():
			_dormant.erase(w[1])
		var before := pieces.pieces.size()
		pieces.restore([w[2]])
		if pieces.pieces.size() > before:
			laid.append(pieces.pieces[-1])
			reloaded += 1
		n += 1


## The pieces laid now, not on their way out.
func _laid() -> Array:
	var out := []
	for p in pieces.pieces:
		if p.fading_since == 0 and is_instance_valid(p.body):
			out.append(p)
	return out


## [distance, piece] of the settled pieces laid, nearest first.
func _settled_by_distance(eye: Vector3) -> Array:
	var out: Array = []
	for p in pieces.pieces:
		if p.settled and p.fading_since == 0 and is_instance_valid(p.body):
			out.append([eye.distance_to(pieces.world_box(p).get_center()), p])
	out.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	return out


## Out of the world: a record if it is big enough to keep, else deleted --
## shrunk away (PlanetPieces' fade) when it may be in view (`seen`), at once
## when its tile is not even drawn.
func _put_away(p: PlanetPieces.Piece, seen: bool) -> void:
	# Its mesh still being made on a worker: next tend (freeing the chunk under
	# a bake is a crash).
	if not p.job.is_empty():
		return
	if bricks.get_alive_block_count(p.chunk) <= SMALL_MAX:
		deleted += 1
		if seen:
			p.fading_since = Time.get_ticks_msec()
		else:
			_drop_piece(p)
		return
	var d := _record(p)
	if not d.is_empty():
		var t := _tile_of(p)
		if not _dormant.has(t):
			_dormant[t] = []
		(_dormant[t] as Array).append(d)
	_drop_piece(p)
	unloaded += 1


func _drop_piece(p: PlanetPieces.Piece) -> void:
	if is_instance_valid(p.body):
		p.body.queue_free()
	bricks.release_chunk(p.chunk)
	pieces.pieces.erase(p)
	if p.settled:
		pieces.settled_count -= 1


func dormant_count() -> int:
	var n := 0
	for t in _dormant:
		n += (_dormant[t] as Array).size()
	return n


## Every piece, laid or not: records where each lies. One still falling is
## kept as it is now, and comes back settled there.
func to_save() -> Array:
	var out := []
	for p in pieces.pieces:
		if p.chunk < 0 or not is_instance_valid(p.body) or p.fading_since != 0:
			continue
		var d := _record(p)
		if not d.is_empty():
			out.append(d)
	for t in _dormant:
		out.append_array(_dormant[t])
	return out


## Back from to_save: each kept as a record under its tile, laid when its
## tile is near-detail (the next tend).
func restore(saved: Array) -> void:
	var tm := BrickTerrain.get_tile_studs() * BrickWorld.get_stud_metres()
	var cs := BrickWorld.get_cell_size()
	for d in saved:
		if not (d is Dictionary) or not d.has("record") or not d.has("at"):
			continue
		var at: Transform3D = d.at
		var dims = (d.record as Dictionary).get("dims", Vector3i.ONE)
		var mid := at * (Vector3(dims) * cs * 0.5) if dims is Vector3i else at.origin
		var t := Vector2i(floori(mid.x / tm), floori(mid.z / tm))
		if not d.has("mid"):
			d["mid"] = mid
		if not _dormant.has(t):
			_dormant[t] = []
		(_dormant[t] as Array).append(d)
	_tend_in = 0.0


func readout() -> String:
	return "ground: %d surveys (%d solved, last %.1f ms, worst %.1f), %d pieces (%d bricks) let go, %d laid (cap %d), %d put away, %d deleted; sand %d fell, %d landed, %d on pieces, %d falling" % [
			surveys, solves, last_survey_ms, worst_survey_ms, groups_let_go, bricks_let_go,
			pieces.pieces.size(), max_loaded, dormant_count(), deleted, columns_fell, columns_landed,
			columns_on_pieces, _sand.size()]


func _exit_tree() -> void:
	if _job >= 0:
		WorkerThreadPool.wait_for_task_completion(_job)
		_job = -1
	for w in _waiting:
		var job: Array = w.get("job", [])
		if not job.is_empty():
			WorkerThreadPool.wait_for_task_completion(int(job[0]))
		if w.has("mesh") and w.mesh != null and is_instance_valid(w.mesh):
			(w.mesh as Node).free()
