extends RefCounted

## Test 10 of the sphere-planet tests (Docs/Planets.md 10b, "Performance tests
## before the conversion"): what debris costs landing on planet ground.
##   --headless --fixed-fps 30 --path . res://scenes/city.tscn -- --terrain
##       --planet=ground [--collider=boxes|trimesh]
##
## The flat game's ground collides as boxes, one a terrain piece. A tile
## mapped onto a sphere is no longer boxes on one grid: the simple collider for
## it is its own triangles. Swapping each tile's boxes for a trimesh of its
## drawn surface ON THE SAME FLAT GROUND measures that change on its own --
## curving it changes no triangle count, so the sphere's cost is the same.
## Run flat out (--fixed-fps), so a tick's wall time is its work: three towers
## brought down, every tick timed until the pieces settle.

const TOWERS := 3

var p
var city: Node3D


func _init(pass_node) -> void:
	p = pass_node
	city = pass_node.city


func run() -> void:
	var c = city
	var mode := "boxes"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--collider="):
			mode = a.trim_prefix("--collider=")
	await p._ticks(30)
	c._lod_frozen = true
	var st: TerrainStreamer = c._terrain_streamer
	var shapes := 0
	var tris := 0
	var tiles := 0
	for t in st.tiles():
		if not t._body.is_valid():
			continue
		tiles += 1
		if mode == "trimesh":
			var mi: MeshInstance3D = t._near_surface if t._near_surface != null else t._far_surface
			if mi == null or mi.mesh == null:
				continue
			var faces: PackedVector3Array = mi.mesh.get_faces()
			var xf := mi.transform
			for k in faces.size():
				faces[k] = xf * faces[k]
			var tri := ConcavePolygonShape3D.new()
			tri.set_faces(faces)
			PhysicsServer3D.body_clear_shapes(t._body)
			PhysicsServer3D.body_add_shape(t._body, tri.get_rid())
			t.set_meta(&"planet_tri", tri)   # keep the shape alive
			tris += faces.size() / 3
			shapes += 1
		else:
			shapes += PhysicsServer3D.body_get_shape_count(t._body)
	print("[planet] ground %s: %d tiles with colliders, %d shapes%s" % [
			mode, tiles, shapes, (", %d triangles" % tris) if mode == "trimesh" else ""])
	await p._ticks(10)

	# Three towers nearest the middle, their ground storeys shot out together.
	var hit := {}
	for k in TOWERS:
		var target = null
		for b in c.registry.buildings:
			if b.is_build() or hit.has(b.id) or c._is_tree(b.id):
				continue
			if target == null or b.xform.origin.length() < target.xform.origin.length():
				target = b
		if target == null:
			break
		hit[target.id] = true
		c._promote(target.id)
		var fx: float = target.recipe.footprint_x * c.STUD
		var fz: float = target.recipe.footprint_z * c.STUD
		var x := 0.0
		while x <= fx + 0.01:
			var z := 0.0
			while z <= fz + 0.01:
				c._blast(target.xform * Vector3(minf(x, fx), 1.2, minf(z, fz)), 2.2)
				z += 2.5
			x += 2.5
	var r1 := await _watch()
	print("[planet] ground %s: %d towers down -- %s" % [mode, hit.size(), r1])
	# The fallen sections broken up where they lie: the debris that lands.
	for isl in c.islands.islands:
		if not isl.is_valid() or isl.body == null:
			continue
		var box: AABB = c.islands.world_aabb(isl)
		for k in 5:
			var f := (k + 0.5) / 5.0
			c._blast(box.position + box.size * Vector3(f, 0.6, 1.0 - f), 1.8)
	var r2 := await _watch()
	print("[planet] ground %s: broken up -- %s" % [mode, r2])
	# The hard case: 400 loose bricks (plain rigid bodies, what a crumb
	# promoted to a body would be) dropped on the ground in a 20 x 20 m patch.
	var at := Vector3(-60.0, 0.0, -60.0)
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.4, 0.42, 0.7)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var bodies: Array[RigidBody3D] = []
	for i in 400:
		var b := RigidBody3D.new()
		b.collision_layer = Layers.DEBRIS
		b.collision_mask = Layers.FALLING_MASK
		var cs := CollisionShape3D.new()
		cs.shape = shape
		b.add_child(cs)
		c.add_child(b)
		var x := at.x + rng.randf_range(-10.0, 10.0)
		var z := at.z + rng.randf_range(-10.0, 10.0)
		b.global_position = Vector3(x, p._ground_y(Vector3(x, 0.0, z)) + 2.0 + rng.randf_range(0.0, 6.0), z)
		b.rotation = Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)
		bodies.append(b)
	var ms: Array[float] = []
	var last := Time.get_ticks_usec()
	var t := 0
	var asleep := 0
	while t < 1200:
		await c.get_tree().physics_frame
		t += 1
		var now := Time.get_ticks_usec()
		ms.append((now - last) / 1000.0)
		last = now
		asleep = 0
		for b in bodies:
			if b.sleeping:
				asleep += 1
		if asleep == bodies.size():
			break
	var mean := 0.0
	for v in ms:
		mean += v
	mean /= ms.size()
	ms.sort()
	print("[planet] ground %s: 400 loose bricks -- %d asleep after %d ticks; a tick takes mean %.2f ms, 95th %.2f, worst %.2f" % [
			mode, asleep, t, mean, ms[int(ms.size() * 0.95)], ms[-1]])


## Every tick timed until no piece has moved for 3 s: [summary string].
func _watch() -> String:
	var c = city
	var stamps: Array[float] = []
	var last := Time.get_ticks_usec()
	var quiet := 0
	var t := 0
	var most := 0
	while t < 1800 and quiet < 90:
		await c.get_tree().physics_frame
		t += 1
		var now := Time.get_ticks_usec()
		stamps.append((now - last) / 1000.0)
		last = now
		var moving := 0
		var n := 0
		for isl in c.islands.islands:
			if isl.is_valid() and isl.body != null:
				n += 1
				if not isl.settled:
					moving += 1
		most = maxi(most, n)
		quiet = quiet + 1 if moving == 0 and t > 30 else 0
	var busy := stamps.slice(0, maxi(1, t - quiet))
	var mean := 0.0
	for v in busy:
		mean += v
	mean /= maxf(busy.size(), 1)
	busy.sort()
	return "%d pieces at most, settled after %d ticks; while settling a tick takes mean %.2f ms, 95th %.2f, worst %.2f" % [
			most, t - quiet, mean, busy[int(busy.size() * 0.95)], busy[-1]]
