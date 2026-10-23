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


func setup(p: PlanetBody) -> void:
	planet = p
	name = "Buildings"
	brick_material = ShaderMaterial.new()
	brick_material.shader = load("res://shaders/brick.gdshader")
	BrickMaterials.add_glass(brick_material)


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


func _free_near(s: Site) -> void:
	s.shell.queue_free()
	s.shell = null
	if s.body != null:
		s.body.queue_free()
		s.body = null
