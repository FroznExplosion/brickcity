class_name MineCurrents
extends Node3D

## Currents: fast water paths through the deep ocean (Docs/MineOcean.md 2.3).
##
## Worked out from the seed like the sea, stored nowhere. A REGION of
## REGION_M has a chance of one current: it starts where the sea is deep,
## heads a random way and turns slowly, mid-way between the floor and the
## surface, until the sea shoals or it is long enough. Within RADIUS_M of
## its path the water flows along it (push_at, added to the water's flow:
## swimmers are carried). Streaks drift along it near the eye.
##
## Everything here is in the terrain frame (MineWater's host's local).

const REGION_M := 256.0
const CHANCE := 0.55
const STEP_M := 6.0
const MAX_STEPS := 100
const START_DEPTH_M := 30.0     ## sea at least this deep where one starts
const END_DEPTH_M := 20.0       ## ...and it ends where it is shallower
const TOP_GAP_M := 8.0          ## never higher than this under the surface
const RADIUS_M := 4.0
const SPEED := 9.0              ## metres a second at its middle
const NEAR_REGIONS := 2         ## worked out this many regions each way

var host: Node = null
## Vector2i region -> Array of PackedVector3Array (that region's currents).
var _regions := {}
var _at := Vector2i(1 << 30, 0)
## The currents near the player, flattened: [path, aabb] pairs.
var _near: Array = []
var _streaks: GPUParticles3D = null
var _streak_proc: ParticleProcessMaterial = null
var _seed := 0
var _sea_level := 0.0


func setup(p_host: Node) -> void:
	host = p_host
	_build()


func reset_world() -> void:
	_regions.clear()
	_near.clear()
	_at = Vector2i(1 << 30, 0)
	_seed = int(BrickTerrain.get_seed())
	_sea_level = BrickFluid.get_sea_level()


## The current's flow at a point (m/s, terrain frame); zero off every path.
func push_at(p: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var best_k := 0.0
	for e in _near:
		var box: AABB = e[1]
		if not box.grow(RADIUS_M).has_point(p):
			continue
		var path: PackedVector3Array = e[0]
		for i in path.size() - 1:
			var a := path[i]
			var b := path[i + 1]
			var ab := b - a
			var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			if d >= RADIUS_M:
				continue
			var k := 1.0 - d / RADIUS_M
			k = k * k * (3.0 - 2.0 * k)
			# Eases in over its first and last steps: no wall of water.
			var along := (i + t) / float(path.size() - 1)
			k *= smoothstep(0.0, 0.06, along) * smoothstep(1.0, 0.94, along)
			if k > best_k:
				best_k = k
				best = ab.normalized() * SPEED * k
	return best


## The nearest current's nearest point to `p` (or Vector3.INF): for gates.
func nearest_point(p: Vector3) -> Vector3:
	var best := Vector3.INF
	for e in _near:
		var path: PackedVector3Array = e[0]
		for q in path:
			if best == Vector3.INF or q.distance_squared_to(p) < best.distance_squared_to(p):
				best = q
	return best


func count_near() -> int:
	return _near.size()


func frame(eye: Vector3) -> void:
	if not BrickFluid.get_sea_level() == _sea_level or _seed != int(BrickTerrain.get_seed()):
		reset_world()
	var r := Vector2i(floori(eye.x / REGION_M), floori(eye.z / REGION_M))
	if r != _at or _missing > 0:
		_at = r
		_gather(r)
	_place_streaks(eye)


## Regions of the ring still to work out (one a frame: each is a few
## hundred ground queries).
var _missing := 0


## Works out every region of the ring at once (gates; a new world).
func gather_all(eye: Vector3) -> void:
	_at = Vector2i(floori(eye.x / REGION_M), floori(eye.z / REGION_M))
	_gather(_at, 1 << 20)


func _gather(c: Vector2i, budget := 1) -> void:
	_near.clear()
	var keep := {}
	_missing = 0
	for dz in range(-NEAR_REGIONS, NEAR_REGIONS + 1):
		for dx in range(-NEAR_REGIONS, NEAR_REGIONS + 1):
			var k := c + Vector2i(dx, dz)
			if not _regions.has(k):
				if budget <= 0:
					_missing += 1
					continue
				budget -= 1
				_regions[k] = _make(k)
			keep[k] = _regions[k]
			for path in _regions[k]:
				_near.append([path, _box(path)])
	_regions = keep


static func _box(path: PackedVector3Array) -> AABB:
	var b := AABB(path[0], Vector3.ZERO)
	for q in path:
		b = b.expand(q)
	return b


func _hash(k: Vector2i, salt: int) -> float:
	var h := hash([_seed, k.x, k.y, salt])
	return float(h & 0xFFFFFF) / float(0x1000000)


## The ground's top at a point in metres (the generated ground and edits).
func _floor_m(x: float, z: float) -> float:
	var stud := BrickWorld.get_stud_metres()
	return BrickTerrain.surface_plate(floori(x / stud), floori(z / stud)) * BrickWorld.get_plate_metres()


func _make(k: Vector2i) -> Array:
	var out: Array = []
	if _hash(k, 1) > CHANCE:
		return out
	var o := Vector2(k) * REGION_M
	var p := o + Vector2(_hash(k, 2), _hash(k, 3)) * REGION_M
	if _sea_level - _floor_m(p.x, p.y) < START_DEPTH_M:
		# One more try at the region's middle: deep regions are often deep there.
		p = o + Vector2(REGION_M, REGION_M) * 0.5
		if _sea_level - _floor_m(p.x, p.y) < START_DEPTH_M:
			return out
	var heading := _hash(k, 4) * TAU
	var turn := (_hash(k, 5) - 0.5) * 0.12
	var path := PackedVector3Array()
	var y := 0.0
	for i in MAX_STEPS:
		var fl := _floor_m(p.x, p.y)
		var dep := _sea_level - fl
		if dep < END_DEPTH_M:
			break
		var want_y := minf(fl + dep * 0.5, _sea_level - TOP_GAP_M)
		y = want_y if i == 0 else lerpf(y, want_y, 0.35)
		path.append(Vector3(p.x, y, p.y))
		# Turns slowly, and away from shoaling water ahead.
		var ahead := p + Vector2(cos(heading), sin(heading)) * STEP_M * 4.0
		if _sea_level - _floor_m(ahead.x, ahead.y) < START_DEPTH_M:
			turn += 0.08 if turn >= 0.0 else -0.08
		heading += turn + sin(i * 0.37 + _hash(k, 6) * 6.0) * 0.05
		turn *= 0.92
		p += Vector2(cos(heading), sin(heading)) * STEP_M
	if path.size() >= 8:
		out.append(path)
	return out


## Streaks along the currents near the eye: emitted at their points, each
## moving the way its path runs (the emission points' normals).
func _place_streaks(eye: Vector3) -> void:
	if _streaks == null:
		return
	var pts := PackedVector3Array()
	var dirs := PackedVector3Array()
	for e in _near:
		var path: PackedVector3Array = e[0]
		for i in path.size() - 1:
			if path[i].distance_squared_to(eye) < 60.0 * 60.0:
				var d := (path[i + 1] - path[i]).normalized()
				var side := d.cross(Vector3.UP).normalized()
				var up := side.cross(d)
				for s in 6:
					# Spread through the current's tube (the same each time).
					var a := float(i * 6 + s) * 2.39996
					var rr := RADIUS_M * 0.75 * sqrt(fposmod(float(i * 6 + s) * 0.618034, 1.0))
					pts.append(path[i].lerp(path[i + 1], s / 6.0) + (side * cos(a) + up * sin(a)) * rr)
					dirs.append(d)
	var on := not pts.is_empty() and eye.y < _sea_level
	_streaks.emitting = on
	if not on:
		return
	if pts.size() != _streak_proc.emission_point_count or pts[0] != _last_first:
		_last_first = pts[0]
		var img := Image.create(pts.size(), 1, false, Image.FORMAT_RGBF)
		var nimg := Image.create(pts.size(), 1, false, Image.FORMAT_RGBF)
		for i in pts.size():
			img.set_pixel(i, 0, Color(pts[i].x, pts[i].y, pts[i].z))
			nimg.set_pixel(i, 0, Color(dirs[i].x, dirs[i].y, dirs[i].z))
		_streak_proc.emission_point_texture = ImageTexture.create_from_image(img)
		_streak_proc.emission_normal_texture = ImageTexture.create_from_image(nimg)
		_streak_proc.emission_point_count = pts.size()
		_streaks.position = Vector3.ZERO
		_streaks.visibility_aabb = AABB(eye - Vector3(70, 70, 70), Vector3(140, 140, 140))


var _last_first := Vector3.INF


func _build() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.55, 0.85, 1.0, 0.22)
	# Thin streaks, long along their velocity (TRANSFORM_ALIGN below).
	var quad := QuadMesh.new()
	quad.size = Vector2(0.02, 0.45)
	quad.material = mat
	# Each fades in and out over its life: no streak pops.
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.set_color(1, Color(1, 1, 1, 0))
	fade.add_point(0.25, Color(1, 1, 1, 1))
	fade.add_point(0.75, Color(1, 1, 1, 1))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	_streak_proc = ParticleProcessMaterial.new()
	_streak_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_DIRECTED_POINTS
	_streak_proc.emission_point_count = 0
	_streak_proc.direction = Vector3(0, 0, 1)
	_streak_proc.spread = 2.0
	_streak_proc.initial_velocity_min = SPEED * 0.8
	_streak_proc.initial_velocity_max = SPEED * 1.1
	_streak_proc.gravity = Vector3.ZERO
	_streak_proc.color_ramp = ramp
	_streak_proc.scale_min = 0.6
	_streak_proc.scale_max = 1.3
	_streaks = GPUParticles3D.new()
	_streaks.name = "CurrentStreaks"
	_streaks.amount = 1200
	_streaks.lifetime = 1.2
	_streaks.local_coords = false
	_streaks.emitting = false
	_streaks.process_material = _streak_proc
	_streaks.draw_pass_1 = quad
	_streaks.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	add_child(_streaks)
