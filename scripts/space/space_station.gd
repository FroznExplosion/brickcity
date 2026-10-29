class_name SpaceStation
extends Node3D

## A station or a satellite in orbit (Docs/Planets.md 11.12 step 2; after STA's
## OrbitalUnit). Its node is where the clock has it (PlanetSystem places it),
## +Y away from its planet.
##
## A STATION is a frame of its own, as a planet is: inside FIELD of it the
## player is on it, it is the anchor and holds still, and its module is laid in
## bricks (a tower's recipe: storeys, a staircase, a door) with their
## collision; down is its -Y, toward a centre DEPTH under its floor so the deck
## is flat (STA's virtual gravity centre). Elsewhere it is its shell and two
## panels, moving. A SATELLITE is only seen.
##
## Its far look is under `look`, for PlanetSystem's scaled space.

## Inside this of its node the player is on it.
const FIELD := 250.0
## Its gravity's centre this far under its floor: the deck all but flat.
const DEPTH := 3000.0
const SECTION_PLATES := 24
const SECTION_STUDS := 32

var data: OrbitalData
## Inside this of its node the player is on it (a ship's is smaller).
var field := FIELD
var look: Node3D
var gravity_centre: Node3D
var brick_material: ShaderMaterial
## The module's corner, in the station's frame: its floor at y 0, centred.
var frame := Transform3D()
var height := 0.0
var shell: MeshInstance3D
var shell_body: StaticBody3D
var bricks: BrickWorld
var chunk := -1
## Its bricks drawn and solid: the shell is gone.
var bricked := false
var _palette: Dictionary
var _brick_node: Node3D
var _band_next := 0
var _band_jobs: Array = []
var _collision: BuildingCollision
var _stud_arrays: Array = []
var _template := -1
var lay_ms := 0.0
var template_ms := 0.0


func setup(d: OrbitalData) -> void:
	data = d
	name = d.orbital_name.replace(" ", "_")
	look = Node3D.new()
	look.name = "Look"
	add_child(look)
	if d.kind == "satellite":
		_build_satellite()
		return
	brick_material = ShaderMaterial.new()
	brick_material.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(brick_material)
	var stud := BrickWorld.get_stud_metres()
	var w := d.fx * stud
	var dd := d.fz * stud
	height = TowerRecipe.total_plates(d.courses) * BrickWorld.get_plate_metres()
	frame = Transform3D(Basis(), Vector3(-w * 0.5, 0.0, -dd * 0.5))
	shell = MeshInstance3D.new()
	shell.name = "Shell"
	shell.mesh = BuildingShell.build_mesh(d.fx, d.fz, d.courses)
	shell.material_override = brick_material
	shell.transform = frame
	look.add_child(shell)
	if d.kind == "station":
		_panels(w * 0.5, height * 0.5, maxf(w, dd) * 1.1, height * 0.7)
	shell_body = StaticBody3D.new()
	shell_body.name = "ShellBody"
	shell_body.collision_layer = Layers.STRUCTURE
	shell_body.collision_mask = 0
	for bx in BuildingShell.collision_boxes(d.fx, d.fz, d.courses, true):
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = bx.size
		cs.shape = shape
		cs.position = bx.pos
		shell_body.add_child(cs)
	shell_body.transform = frame
	add_child(shell_body)
	gravity_centre = Node3D.new()
	gravity_centre.name = "GravityCentre"
	gravity_centre.position = Vector3(0.0, -DEPTH, 0.0)
	add_child(gravity_centre)


## A frame of its own (a station or a ship), not only seen (a satellite).
func is_station() -> bool:
	return data.kind != "satellite"


## Two solar wings, either side along X, `span` long, from `x0` out.
func _panels(x0: float, y: float, span: float, wide: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.16, 0.34)
	mat.metallic = 0.6
	mat.roughness = 0.3
	var strut := StandardMaterial3D.new()
	strut.albedo_color = Color(0.6, 0.6, 0.62)
	for side in [-1.0, 1.0]:
		var p := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(span, 0.12, wide)
		p.mesh = bm
		p.material_override = mat
		p.position = Vector3(side * (x0 + span * 0.5 + 1.5), y, 0.0)
		look.add_child(p)
		var s := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(span + 1.5, 0.3, 0.3)
		s.mesh = sm
		s.material_override = strut
		s.position = Vector3(side * (x0 + span * 0.5 + 0.75), y, 0.0)
		look.add_child(s)


func _build_satellite() -> void:
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 2.5, 2.0)
	body.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.72, 0.30)
	mat.metallic = 0.8
	mat.roughness = 0.35
	body.material_override = mat
	look.add_child(body)
	var dish := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.2
	cm.bottom_radius = 0.2
	cm.height = 0.6
	dish.mesh = cm
	dish.position = Vector3(0.0, -1.6, 0.0)
	look.add_child(dish)
	_panels(1.0, 0.0, 6.0, 1.8)


# --- on it: the module in bricks ---------------------------------------------------

## Its module's bricks built and kept as a template (~60 ms): ahead of the
## player's arrival (at load, or on the way in), so arriving only copies it.
func prepare() -> void:
	if not is_station() or _template >= 0:
		return
	var t0 := Time.get_ticks_usec()
	if bricks == null:
		bricks = BrickWorld.new()
		_palette = TowerRecipe.bake_palette(bricks)
		_stud_arrays = PieceMeshes.stud().surface_get_arrays(0)
	var c := bricks.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(data.fx, data.fz, data.courses))
	var stair := _staircase()
	TowerRecipe.build(bricks, c, _palette, data.fx, data.fz, data.courses, [stair.footprint()] if stair != null else [])
	if stair != null:
		stair.build_into(bricks, c, StaircaseRecipe.flight_parts(_palette))
	_cut_door(c)
	_template = bricks.save_template(c)
	bricks.release_chunk(c)
	template_ms = (Time.get_ticks_usec() - t0) / 1000.0


## The player is on it: its module laid in bricks (drawn a band a frame, then
## solid), the shell's boxes standing in until then.
func activate() -> void:
	if not is_station() or chunk >= 0:
		return
	prepare()
	var t0 := Time.get_ticks_usec()
	chunk = bricks.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(data.fx, data.fz, data.courses))
	bricks.load_template(_template, chunk)
	bricks.set_chunk_anchored(chunk, true)
	bricks.set_tension_per_stud(chunk, BrickStrength.tension())
	bricks.set_chunk_section_plates(chunk, SECTION_PLATES)
	bricks.set_chunk_section_studs(chunk, SECTION_STUDS)
	bricks.set_chunk_transform(chunk, global_transform * frame)
	_brick_node = Node3D.new()
	_brick_node.name = "Bricks"
	_brick_node.transform = frame
	add_child(_brick_node)
	_band_next = 0
	bricks.bake_chunk_async(chunk)
	lay_ms = (Time.get_ticks_usec() - t0) / 1000.0
	print("[station] %s: %d bricks laid in %.1f ms (its template built in %.1f ms, before)" % [
			data.orbital_name, bricks.get_alive_block_count(chunk), lay_ms, template_ms])


func deactivate() -> void:
	if chunk < 0:
		return
	for job in _band_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_band_jobs.clear()
	if _collision != null:
		_collision.free_bodies()
		_collision = null
	if _brick_node != null:
		_brick_node.queue_free()
		_brick_node = null
	bricks.release_chunk(chunk)
	chunk = -1
	bricked = false
	shell.visible = true
	shell_body.collision_layer = Layers.STRUCTURE


## The floating origin moved it: its bricks' transform and collision follow.
func on_origin_shift() -> void:
	if chunk < 0:
		return
	bricks.set_chunk_transform(chunk, global_transform * frame)
	if _collision != null:
		_collision.free_bodies()
		_collision = BuildingCollision.new(bricks, chunk, get_world_3d().space, global_transform * frame, true)


func _process(_delta: float) -> void:
	if chunk < 0 or bricked:
		return
	if not bricks.bake_ready(chunk):
		if not bricks.bake_pending(chunk):
			bricks.bake_chunk_async(chunk)
		return
	_harvest()
	if _band_next < bricks.get_chunk_sections(chunk):
		_draw_band(_band_next)
		_band_next += 1
	elif _band_jobs.is_empty():
		_collision = BuildingCollision.new(bricks, chunk, get_world_3d().space, global_transform * frame, true)
		bricked = true
		shell.visible = false
		shell_body.collision_layer = 0


## As PlanetBuildings._draw_band: a band's bricks and open studs merged into one
## mesh on a worker.
func _draw_band(band: int) -> void:
	var arrays: Array = bricks.build_chunk_mesh_section(chunk, band)
	var got: Array = bricks.get_chunk_studs_and_open(chunk, band)
	var buf: PackedFloat32Array = got[0]
	var open: PackedByteArray = got[1]
	var keep := PackedFloat32Array()
	for k in open.size():
		if open[k] != 0:
			keep.append_array(buf.slice(k * 16, k * 16 + 16))
	if arrays.is_empty() and keep.is_empty():
		return
	var stud: Array = _stud_arrays
	var holder := [null]
	var task := WorkerThreadPool.add_task(func() -> void:
			var merge := MeshMerge.new()
			if not arrays.is_empty():
				merge.add_surface(arrays, Transform3D.IDENTITY, Color(-1, 0, 0))
			if not keep.is_empty():
				merge.add_instances(stud, Transform3D.IDENTITY, keep)
			var out := merge.commit()
			if out.is_empty():
				return
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, IslandManager.UPLOAD_COMPRESS)
			holder[0] = m, false, "station band")
	_band_jobs.append([task, holder])


func _harvest() -> void:
	var k := 0
	while k < _band_jobs.size():
		var job: Array = _band_jobs[k]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			k += 1
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		_band_jobs.remove_at(k)
		var mesh: ArrayMesh = (job[1] as Array)[0]
		if mesh == null or _brick_node == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = brick_material
		_brick_node.add_child(mi)


## As PlanetBuildings._staircase: the city's staircase on the lattice inside.
func _staircase() -> Fixture:
	var sx := TowerRecipe.stair_line(data.fx)
	var sz := TowerRecipe.stair_line(data.fz)
	if sx < 0 or sz < 0:
		return null
	var f := Fixture.new()
	f.kind = "staircase"
	f.params = {"steps": StaircaseRecipe.steps_for_courses(data.courses), "colour": 11}
	f.cell = Vector3i(sx, TowerRecipe.SLAB_PLATES, sz)
	return f


## As PlanetBuildings._cut_door: a door in the ground storey's -Z wall, the
## airlock you fly in by.
func _cut_door(c: int) -> void:
	var x0 := data.fx / 2 - TowerRecipe.DOOR_WIDE / 2
	var y0 := TowerRecipe.SLAB_PLATES
	var y1 := y0 + 5 * TowerRecipe.PLATES_PER_COURSE
	var gone := {}
	for x in range(x0, x0 + TowerRecipe.DOOR_WIDE):
		for z in TowerRecipe.WALL_THICK:
			for y in range(y0, y1):
				var b := bricks.block_at(c, Vector3i(x, y, z))
				if b >= 0 and not gone.has(b):
					gone[b] = true
					bricks.remove_block(c, b)


func _exit_tree() -> void:
	for job in _band_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_band_jobs.clear()
	if _collision != null:
		_collision.free_bodies()
		_collision = null
