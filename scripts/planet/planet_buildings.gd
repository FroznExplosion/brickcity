class_name PlanetBuildings
extends Node3D

## The planet's buildings (Docs/Planets.md 11.2-11.4). A child of PlanetBody,
## so planet-local: a floating-origin shift moves them with the planet.
##
## Each building stands in the TANGENT frame at its site, on a pad the ground is
## levelled to (PlanetData.pads, one a town). Two tiers:
##   near: the city's own shell (BuildingShell.build_mesh, the brick material)
##         and its collision boxes, inside NEAR_M; dither-faded out at the edge
##         (Godot's visibility range);
##   far:  one instance of a box in a MultiMesh (planet_far_building.gdshader),
##         faded in where the near one fades out, and drawn only
##           * on or near the ground, inside the distance its own top can
##             crest the horizon from: sqrt(h(2R+h)) + sqrt(H(2R+H)) + margin --
##             it appears below the horizon and rises into view (11.3);
##           * from the air, by its size on screen: from 1.5 px tall to 4 px (11.4).
## Landmarks (the tallest) never fade below their full alpha from space, and
## carry a beacon that stays a few pixels across at any distance.

const NEAR_M := 450.0
const NEAR_FADE := 40.0
const CREST_MARGIN := 60.0
const PX_FROM := 1.5
const PX_FULL := 4.0
const BEACON_PX := 2.5

class Site:
	var dir: Vector3            # planet-local unit direction of its centre
	var frame: Transform3D      # planet-local: its corner on the ground, Y = local up
	var fx := 0
	var fz := 0
	var courses := 0
	var height := 0.0           # metres
	var top_alt := 0.0          # its top over the datum: ground + height
	var landmark := false
	var colour := Color.WHITE
	var shell: MeshInstance3D = null
	var body: StaticBody3D = null
	var fade := 0.0             # the far tier's, this frame
	var shown_at := -1.0        # first time the far tier showed it (s), for the gate
	# Its bricks (11.11): the chunk in `bricks`, -1 with none; the node its bands
	# and collision hang from; the next band to draw; all of them in.
	var chunk := -1
	var brick_node: Node3D = null
	var band_next := 0
	var bricked := false
	# Bands uploading on workers: [task id, [mesh]] (the city's way: making the
	# GPU mesh is ~9 ms on the main thread whatever its size).
	var band_jobs: Array = []
	# Past BRICK_DRAW_M a materialised building looks like its shell (this, the
	# shell's mesh dithered in), its bricks still solid and the AI's.
	var shell_look: MeshInstance3D = null

var planet: PlanetBody
var sites: Array[Site] = []
var far: MultiMeshInstance3D
var beacons: MultiMeshInstance3D
var brick_material: ShaderMaterial
var _far_mat: ShaderMaterial
var _mesh_cache := {}
var _landmarks: Array[int] = []
var near_count := 0
var far_count := 0
## For the gate: fades that jumped in plain sight, and the biggest one-frame step.
var pops := 0
var max_step := 0.0
var _time := 0.0

# --- real bricks near (Docs/Planets.md 11.11) -------------------------------------

## A building this near the camera is its bricks; past BRICK_DROP the shell again.
const BRICK_M := 160.0
const BRICK_DROP := 220.0
## Drawn as bricks only this near (dithered over BRICK_DRAW_FADE): further, the
## shell's look -- a tower's every floor and wall at 150 m is GPU for nothing.
const BRICK_DRAW_M := 80.0
const BRICK_DRAW_FADE := 10.0
## Drawing bands, as the city cuts its buildings (CityScene.SECTION_PLATES / _STUDS).
const SECTION_PLATES := 24
const SECTION_STUDS := 32
## The planet's bricks: every materialised building is a chunk here, its
## transform its site's frame in the world. The AI's nav regions read it too.
var bricks: BrickWorld
var _palette: Dictionary
## Vector3i(fx, fz, courses) -> template id: a shape is built once.
var _templates := {}
var _brick_queue: Array[int] = []
var _brick_site := -1
var bricked_count := 0
## Off (-- --no-bricks): shells only, as before 11.11 -- for an A/B of the cost.
var bricks_on := not ("--no-bricks" in OS.get_cmdline_user_args())
var brick_worst_us := 0
## What that worst step was doing: "start", "band", "finish" or "template".
var brick_worst_what := ""
var _stud_arrays: Array = []
var _stair_parts := PackedInt32Array()
## A site's bricks came in (true) or went (false): the AI's world follows.
signal site_bricks(index: int, on: bool)


func setup(p: PlanetBody) -> void:
	planet = p
	name = "Buildings"
	brick_material = ShaderMaterial.new()
	brick_material.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(brick_material)
	bricks = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(bricks)
	# The studs' mesh and material are made on first use: ~15 ms, in the load
	# rather than in the first band that has open studs.
	_stud_arrays = PieceMeshes.stud().surface_get_arrays(0)
	_stair_parts = StaircaseRecipe.flight_parts(_palette)


## A town of towers on a grid round `dir`, in the tangent frame there, on the
## pad already in PlanetData.pads for it. `rng` picks heights and colours.
func add_town(dir: Vector3, rows: int, spacing: float, rng: RandomNumberGenerator,
		tall := 1.0) -> void:
	var up := dir.normalized()
	var e1 := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var e2 := up.cross(e1)
	var stud := BrickWorld.get_stud_metres()
	for i in rows:
		for j in rows:
			if rng.randf() < 0.15:
				continue   # a square
			var off := (Vector2(i, j) - Vector2(rows - 1, rows - 1) * 0.5) * spacing
			var d := (up * planet.data.radius + e1 * off.x + e2 * off.y).normalized()
			var fx := 24 + 2 * rng.randi_range(0, 6)
			var fz := 24 + 2 * rng.randi_range(0, 6)
			var courses := int(rng.randi_range(12, 60) * tall)
			_add(d, e1, fx, fz, courses, false, rng)


## One very tall building: visible from space.
func add_landmark(dir: Vector3, fx: int, fz: int, courses: int, rng: RandomNumberGenerator) -> void:
	var up := dir.normalized()
	var e1 := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	_add(up, e1, fx, fz, courses, true, rng)


func _add(d: Vector3, e1: Vector3, fx: int, fz: int, courses: int, landmark: bool,
		rng: RandomNumberGenerator) -> void:
	var s := Site.new()
	s.dir = d
	var up := d
	var ex := (e1 - up * e1.dot(up)).normalized()
	var ez := ex.cross(up)
	var stud := BrickWorld.get_stud_metres()
	var w := fx * stud
	var dd := fz * stud
	var base := planet.data.surface_point(d)
	# The building's own origin is its corner (BuildingShell's meshes and boxes
	# are laid from there), its centre on the site.
	s.frame = Transform3D(Basis(ex, up, ez), base) * Transform3D(Basis(), Vector3(-w * 0.5, 0.0, -dd * 0.5))
	s.fx = fx
	s.fz = fz
	s.courses = courses
	s.height = TowerRecipe.total_plates(courses) * BrickWorld.get_plate_metres()
	s.top_alt = planet.data.height(d) + s.height
	s.landmark = landmark
	var c: Color = TowerRecipe.COURSE_COLOURS[rng.randi() % TowerRecipe.COURSE_COLOURS.size()]
	s.colour = c.lerp(Color(0.7, 0.7, 0.72), 0.45)
	if landmark:
		_landmarks.append(sites.size())
	sites.append(s)


## Build the far tier once every site is in.
func finish() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	# Base at the origin: BoxMesh is centred, so lift it by half in the mesh.
	var arr := box.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for k in v.size():
		v[k] += Vector3(0.5, 0.5, 0.5)
	arr[Mesh.ARRAY_VERTEX] = v
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = sites.size()
	_far_mat = ShaderMaterial.new()
	_far_mat.shader = load("res://shaders/planet_far_building.gdshader")
	for i in sites.size():
		var s := sites[i]
		var w := s.fx * BrickWorld.get_stud_metres()
		var dd := s.fz * BrickWorld.get_stud_metres()
		mm.set_instance_transform(i, s.frame * Transform3D(Basis.from_scale(Vector3(w, s.height, dd)), Vector3.ZERO))
		mm.set_instance_color(i, Color(s.colour, 1.0 if s.landmark else 0.0))
		mm.set_instance_custom_data(i, Color(0.0, w, s.height, dd))
	far = MultiMeshInstance3D.new()
	far.name = "Far"
	far.multimesh = mm
	far.material_override = _far_mat
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	far.extra_cull_margin = planet.data.radius
	add_child(far)
	# Beacons: a small lit quad over each landmark, sized every frame.
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var bm := MultiMesh.new()
	bm.transform_format = MultiMesh.TRANSFORM_3D
	bm.mesh = q
	bm.instance_count = _landmarks.size()
	beacons = MultiMeshInstance3D.new()
	beacons.name = "Beacons"
	beacons.multimesh = bm
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bmat.albedo_color = Color(1.0, 0.85, 0.55)
	bmat.billboard_keep_scale = true
	beacons.material_override = bmat
	beacons.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beacons.extra_cull_margin = planet.data.radius
	add_child(beacons)


## The pads the ground needs for these sites: one a town, from its sites'
## spread. Call before PlanetBody.setup builds the generator.
static func town_pad(data: PlanetData, dir: Vector3, flat: float, blend: float) -> Dictionary:
	var h := maxf(data.relief(dir.normalized()), data.sea_level + 3.0 if not is_nan(data.sea_level) else -1e9)
	return {"dir": dir.normalized(), "height": h, "flat": flat, "blend": blend}


func _process(delta: float) -> void:
	_time += delta
	var cam := get_viewport().get_camera_3d()
	if cam == null or far == null:
		return
	var eye := cam.global_position
	var centre := planet.global_position
	var r := planet.data.radius
	var h_eye := maxf(planet.altitude_of(eye), 1.0)
	var horizon := sqrt(h_eye * (2.0 * r + h_eye))
	var vp := cam.get_viewport().get_visible_rect().size
	var px_per_rad: float = (vp.y * 0.5) / tan(deg_to_rad(cam.fov) * 0.5)
	var mm := far.multimesh
	near_count = 0
	far_count = 0
	for i in sites.size():
		var s := sites[i]
		var base := centre + s.frame * Vector3(s.fx * 0.175, 0.0, s.fz * 0.175)
		var dist := eye.distance_to(base + (centre - base).normalized() * -s.height * 0.5)
		# Near: the shell, built on the way in, freed well past the edge.
		if dist < NEAR_M + NEAR_FADE:
			if s.shell == null:
				_make_near(s)
			near_count += 1
		elif s.shell != null and dist > NEAR_M + NEAR_FADE * 3.0:
			_free_near(s)
		# Nearer still, its bricks (not a landmark: a thousand courses).
		if not s.landmark and bricks_on:
			if dist < BRICK_M and s.chunk < 0 and i != _brick_site and not _brick_queue.has(i):
				_brick_queue.append(i)
			elif dist > BRICK_DROP and (s.chunk >= 0 or _brick_queue.has(i)):
				_brick_queue.erase(i)
				_free_bricks(i)
		# Far: only where its top can crest the horizon, by its size on screen,
		# and fading in where the shell fades out.
		# From its TOP's altitude over the datum (ground + height): a tower on a
		# hill crests sooner than its height alone says.
		var crest := horizon + sqrt(s.top_alt * (2.0 * r + s.top_alt)) + CREST_MARGIN
		var a := 0.0
		if dist < crest:
			var px := s.height * px_per_rad / maxf(dist, 1.0)
			a = smoothstep(PX_FROM, PX_FULL, px)
			if s.landmark:
				a = 1.0
			a *= smoothstep(NEAR_M - NEAR_FADE, NEAR_M + NEAR_FADE, dist)
		if a > 0.0 and s.shown_at < 0.0:
			s.shown_at = _time
		# A pop: a jump in the far tier's fade while the top is in plain sight
		# over the horizon. Coming up from behind the curve is not one.
		if absf(a - s.fade) > 0.34 and _time > 2.0:
			var see := horizon + sqrt(maxf(s.top_alt, 0.0) * (2.0 * r + maxf(s.top_alt, 0.0)))
			if dist < see and dist > NEAR_M + NEAR_FADE:
				pops += 1
		max_step = maxf(max_step, absf(a - s.fade) if _time > 2.0 else 0.0)
		if a != s.fade:
			s.fade = a
			var w := s.fx * BrickWorld.get_stud_metres()
			var dd := s.fz * BrickWorld.get_stud_metres()
			mm.set_instance_custom_data(i, Color(a, w, s.height, dd))
		if a > 0.0:
			far_count += 1
	_brick_step(eye)
	# Beacons a few pixels across, on each landmark's top.
	var bmm := beacons.multimesh
	for k in _landmarks.size():
		var s := sites[_landmarks[k]]
		var top := s.frame * Vector3(s.fx * 0.175, s.height + 2.0, s.fz * 0.175)
		var dist := eye.distance_to(centre + top)
		var size := maxf(BEACON_PX * dist / px_per_rad, 1.5)
		# Only past the near tier, and only from the air or over the horizon line.
		var show := dist > NEAR_M and dist < horizon + sqrt(s.top_alt * (2.0 * r + s.top_alt)) + CREST_MARGIN
		bmm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ONE * (size if show else 0.0)), top))


func _make_near(s: Site) -> void:
	var key := Vector3i(s.fx, s.fz, s.courses)
	if not _mesh_cache.has(key):
		_mesh_cache[key] = BuildingShell.build_mesh(s.fx, s.fz, s.courses)
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh_cache[key]
	mi.material_override = brick_material
	mi.transform = s.frame
	# Dithered out at the edge of the near tier, where the far box fades in.
	mi.visibility_range_end = NEAR_M
	mi.visibility_range_end_margin = NEAR_FADE
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)
	s.shell = mi
	var body := StaticBody3D.new()
	body.collision_layer = Layers.STRUCTURE
	body.collision_mask = 0
	for bx in BuildingShell.collision_boxes(s.fx, s.fz, s.courses, true):
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = bx.size
		cs.shape = shape
		cs.position = bx.pos
		body.add_child(cs)
	add_child(body)
	body.transform = s.frame
	s.body = body


## One piece of brick work a frame: start the nearest building waiting (its
## chunk from its shape's template, baked on a worker), or draw the next band
## of the one in hand; with its last band, its collision, and the shell goes.
func _brick_step(eye: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	var what := ""
	if _brick_site < 0:
		if _brick_queue.is_empty():
			_idle_template(eye)
			_note_step(t0, "template")
			return
		var best := 0
		var best_d := INF
		for qi in _brick_queue.size():
			var d := eye.distance_to(planet.global_position + sites[_brick_queue[qi]].frame.origin)
			if d < best_d:
				best_d = d
				best = qi
		_brick_site = _brick_queue[best]
		_brick_queue.remove_at(best)
		_start_bricks(sites[_brick_site])
		what = "start"
	else:
		var s := sites[_brick_site]
		if not bricks.bake_ready(s.chunk):
			if not bricks.bake_pending(s.chunk):
				bricks.bake_chunk_async(s.chunk)
			return
		_harvest_bands(s)
		if s.band_next < bricks.get_chunk_sections(s.chunk):
			_draw_band(s, s.band_next)
			s.band_next += 1
			what = "band"
		elif not s.band_jobs.is_empty():
			what = "upload"
		else:
			_finish_bricks(_brick_site)
			_brick_site = -1
			what = "finish"
	_note_step(t0, what)


func _note_step(t0: int, what: String) -> void:
	var us := Time.get_ticks_usec() - t0
	if us > brick_worst_us:
		brick_worst_us = us
		brick_worst_what = what


## A shape's template, built if there is none: the tower, its front door,
## saved. 5-20 ms; done ahead (prepare_templates, idle frames), not when a
## building is wanted.
func _template(fx: int, fz: int, courses: int) -> int:
	var key := Vector3i(fx, fz, courses)
	if _templates.has(key):
		return _templates[key]
	var c := bricks.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	# The city's staircase up the middle (CityScene._add_staircase): its shaft
	# kept clear while the tower is laid, its flight laid after, in the same chunk.
	var stair := _staircase(fx, fz, courses)
	TowerRecipe.build(bricks, c, _palette, fx, fz, courses, [stair.footprint()] if stair != null else [])
	if stair != null:
		stair.build_into(bricks, c, _stair_parts)
	_cut_door(c, fx)
	_templates[key] = bricks.save_template(c)
	bricks.release_chunk(c)
	return _templates[key]


## Every shape within `radius` of world `p` built now (a scene loading).
## Returns milliseconds.
func prepare_templates(p: Vector3, radius: float) -> float:
	var t0 := Time.get_ticks_usec()
	for s in sites:
		if not s.landmark and p.distance_to(planet.global_position + s.frame.origin) < radius:
			_template(s.fx, s.fz, s.courses)
	return (Time.get_ticks_usec() - t0) / 1000.0


## In a frame with no brick work: the nearest shape within this of the camera
## that has no template yet.
const TEMPLATE_AHEAD := 600.0


func _idle_template(eye: Vector3) -> void:
	var best: Site = null
	var best_d := TEMPLATE_AHEAD
	for s in sites:
		if s.landmark or _templates.has(Vector3i(s.fx, s.fz, s.courses)):
			continue
		var d := eye.distance_to(planet.global_position + s.frame.origin)
		if d < best_d:
			best_d = d
			best = s
	if best != null:
		_template(best.fx, best.fz, best.courses)


func _start_bricks(s: Site) -> void:
	s.chunk = bricks.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(s.fx, s.fz, s.courses))
	bricks.load_template(_template(s.fx, s.fz, s.courses), s.chunk)
	bricks.set_chunk_anchored(s.chunk, true)
	bricks.set_chunk_section_plates(s.chunk, SECTION_PLATES)
	bricks.set_chunk_section_studs(s.chunk, SECTION_STUDS)
	bricks.set_chunk_transform(s.chunk, planet.global_transform * s.frame)
	s.brick_node = Node3D.new()
	s.brick_node.name = "Bricks"
	s.brick_node.transform = s.frame
	add_child(s.brick_node)
	s.band_next = 0
	bricks.bake_chunk_async(s.chunk)


## The staircase a shape gets, as the city's buildings get theirs: on the
## lattice point inside the walls, every storey's steps; null with no room.
func _staircase(fx: int, fz: int, courses: int) -> Fixture:
	var sx := TowerRecipe.stair_line(fx)
	var sz := TowerRecipe.stair_line(fz)
	if sx < 0 or sz < 0:
		return null
	var f := Fixture.new()
	f.kind = "staircase"
	f.params = {"steps": StaircaseRecipe.steps_for_courses(courses), "colour": 11}
	f.cell = Vector3i(sx, TowerRecipe.SLAB_PLATES, sz)
	return f


## A front door in the middle of the ground storey's -Z wall: the bricks in a
## DOOR_WIDE x five-course box taken out (remove_block: as never placed), the
## lintel course over it left. A city tower has none -- its squads breach --
## but a town on a planet is walked into.
func _cut_door(chunk: int, fx: int) -> void:
	var x0 := fx / 2 - TowerRecipe.DOOR_WIDE / 2
	var y0 := TowerRecipe.SLAB_PLATES
	var y1 := y0 + 5 * TowerRecipe.PLATES_PER_COURSE
	var gone := {}
	for x in range(x0, x0 + TowerRecipe.DOOR_WIDE):
		for z in TowerRecipe.WALL_THICK:
			for y in range(y0, y1):
				var b := bricks.block_at(chunk, Vector3i(x, y, z))
				if b >= 0 and not gone.has(b):
					gone[b] = true
					bricks.remove_block(chunk, b)


func _draw_band(s: Site, band: int) -> void:
	var arrays: Array = bricks.build_chunk_mesh_section(s.chunk, band)
	# Its studs: only the OPEN ones (a roof, a ledge); a floor's under a ceiling
	# show only through a window, and a tower has tens of thousands.
	var got: Array = bricks.get_chunk_studs_and_open(s.chunk, band)
	var buf: PackedFloat32Array = got[0]
	var open: PackedByteArray = got[1]
	var keep := PackedFloat32Array()
	for k in open.size():
		if open[k] != 0:
			keep.append_array(buf.slice(k * 16, k * 16 + 16))
	if arrays.is_empty() and keep.is_empty():
		return
	# Merged and made into a GPU mesh on a worker (the city's way, CityScene.
	# _submit_band_job): on the main thread a mesh -- or a MultiMesh of studs --
	# going to the renderer is 10-25 ms windowed, whatever its size.
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
			holder[0] = m, false, "planet band")
	s.band_jobs.append([task, holder])


## The bands whose meshes are made: drawn now.
func _harvest_bands(s: Site) -> void:
	var k := 0
	while k < s.band_jobs.size():
		var job: Array = s.band_jobs[k]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			k += 1
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		s.band_jobs.remove_at(k)
		var mesh: ArrayMesh = (job[1] as Array)[0]
		if mesh == null or s.brick_node == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = brick_material
		# The shell casts the building's shadow (_finish_bricks): every floor and
		# wall of a tower in the sun's cascades tripled the GPU's frame.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = BRICK_DRAW_M
		mi.visibility_range_end_margin = BRICK_DRAW_FADE
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		s.brick_node.add_child(mi)


func _finish_bricks(i: int) -> void:
	var s := sites[i]
	var body := StaticBody3D.new()
	body.name = "BrickBody"
	body.collision_layer = Layers.STRUCTURE
	body.collision_mask = 0
	# The shapes before the body is in the physics space: added to a body in
	# it, each shape updates the broadphase -- 300-1000 ms for a tower, against
	# 1.5 ms outside it.
	bricks.add_chunk_shapes(body.get_rid(), s.chunk, Vector3.ZERO, true)
	s.brick_node.add_child(body)
	s.bricked = true
	bricked_count += 1
	# The shell and its walls go: the bricks are the building now.
	if s.shell != null:
		# Not drawn, but its outline still casts the building's shadow.
		s.shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		var look := MeshInstance3D.new()
		look.mesh = s.shell.mesh
		look.material_override = brick_material
		look.transform = s.frame
		look.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		look.visibility_range_begin = BRICK_DRAW_M
		look.visibility_range_begin_margin = BRICK_DRAW_FADE
		look.visibility_range_end = NEAR_M
		look.visibility_range_end_margin = NEAR_FADE
		look.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(look)
		s.shell_look = look
	if s.body != null:
		s.body.collision_layer = 0
	site_bricks.emit(i, true)


func _free_bricks(i: int) -> void:
	var s := sites[i]
	if i == _brick_site:
		_brick_site = -1
	if s.chunk < 0:
		return
	if s.bricked:
		bricked_count -= 1
	s.bricked = false
	for job in s.band_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	s.band_jobs.clear()
	if s.brick_node != null:
		s.brick_node.queue_free()
		s.brick_node = null
	bricks.release_chunk(s.chunk)
	s.chunk = -1
	if s.shell != null:
		s.shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if s.shell_look != null:
		s.shell_look.queue_free()
		s.shell_look = null
	if s.body != null:
		s.body.collision_layer = Layers.STRUCTURE
	site_bricks.emit(i, false)


func _exit_tree() -> void:
	# Bands still uploading: waited for, or the pool tears down under them.
	for s in sites:
		for job in s.band_jobs:
			WorkerThreadPool.wait_for_task_completion(int(job[0]))
		s.band_jobs.clear()


## The floating origin moved the scene: every chunk's transform is the world's.
func on_origin_shift() -> void:
	for s in sites:
		if s.chunk >= 0:
			bricks.set_chunk_transform(s.chunk, planet.global_transform * s.frame)


## The world box a site stands in (for the AI: what to forget when its bricks change).
func site_box(i: int) -> AABB:
	var s := sites[i]
	var stud := BrickWorld.get_stud_metres()
	return (planet.global_transform * s.frame) * AABB(Vector3.ZERO, Vector3(s.fx * stud, s.height, s.fz * stud))


func _free_near(s: Site) -> void:
	s.shell.queue_free()
	s.shell = null
	if s.body != null:
		s.body.queue_free()
		s.body = null
