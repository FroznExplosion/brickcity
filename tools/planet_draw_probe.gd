extends SceneTree

## Test 11 of the sphere-planet tests (Docs/Planets.md 10b, "Performance tests
## before the conversion"): what curved ground costs to DRAW against the flat.
##
##   --path . --script res://tools/planet_draw_probe.gd      (windowed, editor closed)
##
## 33 x 33 detail tiles (370 m square, BrickTerrain.build_tile, the ground
## material) drawn twice: flat, as the game has them, and mapped onto a 10 km
## sphere mid-face (tools/planet_cube_probe.gd's map). Each from street level
## (1.7 m over the ground) and from 100 m up, looking along the ground; the
## renderer's CPU and GPU time over 240 frames. Then, on the sphere, a horizon
## cull: a tile whose highest point is under the camera's horizon is hidden --
## how many go, and what that saves.

const R := 10000.0
const BLEND := 0.48
const N := 1402
const TILE := 11.2
const HALF := 16        # tiles each way: 33 x 33, past the street-level horizon
const FRAMES := 240

var L := N * TILE
var p0 := Vector3.ZERO
var c0 := Vector2.ZERO   # the field point under the origin
var started := false
var flat_root: Node3D
var ball_root: Node3D
var tops := {}           # tile -> [centre dir, highest radius]


func _initialize() -> void:
	pass


func _process(_d: float) -> bool:
	if not started:
		started = true
		_run()
	return false


static func warp(t: float) -> float:
	return lerpf(t, tan(t * PI / 4.0), BLEND)


func dir_of(x: float, z: float) -> Vector3:
	return Vector3(warp(2.0 * x / L - 1.0), 1.0, -warp(2.0 * z / L - 1.0)).normalized()


func place(x: float, h: float, z: float) -> Vector3:
	var d := dir_of(x, z)
	var r := R + h
	return Vector3(d.x * r - p0.x, d.y * r - p0.y, d.z * r - p0.z)


func _run() -> void:
	BrickTerrain.configure(7)
	var i0 := N / 2
	c0 = Vector2((i0 + 0.5) * TILE, (i0 + 0.5) * TILE)
	var h0 := float(BrickTerrain.surface_plate(int(c0.x / BrickWorld.get_stud_metres()),
			int(c0.y / BrickWorld.get_stud_metres())) + 1) * BrickWorld.get_plate_metres()
	p0 = dir_of(c0.x, c0.y) * (R + h0)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, -35, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.5, 0.65, 0.85)
	root.add_child(env)
	var mat := TerrainTile.ground_material(-sun.global_transform.basis.z)
	flat_root = Node3D.new()
	ball_root = Node3D.new()
	root.add_child(flat_root)
	root.add_child(ball_root)
	var t0 := Time.get_ticks_msec()
	var tris := 0
	for j in range(i0 - HALF, i0 + HALF + 1):
		for i in range(i0 - HALF, i0 + HALF + 1):
			tris += _tile(i, j, mat)
	print("[draw] %d tiles, %d triangles each way, built in %d ms" % [
			(HALF * 2 + 1) * (HALF * 2 + 1), tris, Time.get_ticks_msec() - t0])
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.far = 4000.0
	root.add_child(cam)
	cam.current = true
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var rows: Array = []
	for height in [1.7, 100.0]:
		for curved in [false, true]:
			flat_root.visible = not curved
			ball_root.visible = curved
			_show_all()
			_aim(cam, curved, height)
			rows.append(await _measure("%s, %.0f m up" % ["curved" if curved else "flat", height]))
		# The horizon cull, curved.
		flat_root.visible = false
		ball_root.visible = true
		_aim(cam, true, height)
		var hidden := _cull(cam.global_position + p0)
		rows.append(await _measure("curved, %.0f m up, horizon cull (%d tiles hidden)" % [height, hidden]))
		await _shot("planet_draw_%03dm" % int(height))
	# Test 12: the atmosphere pass over the flat ground from 100 m, on and off.
	flat_root.visible = true
	ball_root.visible = false
	_aim(cam, false, 100.0)
	rows.append(await _measure("flat, 100 m up, no atmosphere"))
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	quad.mesh = qm
	var am := ShaderMaterial.new()
	am.shader = load("res://tools/planet_atmosphere.gdshader")
	am.set_shader_parameter("planet_centre", Vector3(0.0, -R, 0.0))
	am.set_shader_parameter("sun_dir", sun.global_transform.basis.z)
	quad.material_override = am
	quad.extra_cull_margin = 16384.0
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cam.add_child(quad)
	quad.position = Vector3(0, 0, -1)
	rows.append(await _measure("flat, 100 m up, atmosphere pass"))
	await _shot("planet_draw_atmosphere")
	print("[draw] summary (ms: render CPU mean / worst, render GPU mean / worst)")
	for r in rows:
		print("  %-52s cpu %.2f / %.2f   gpu %.2f / %.2f" % r)
	quit()


## Street level or up high, at the patch's edge, looking across it.
func _aim(cam: Camera3D, curved: bool, height: float) -> void:
	var from := c0 + Vector2(-HALF * TILE * 0.9, -HALF * TILE * 0.9)
	var to := c0 + Vector2(HALF * TILE * 0.5, HALF * TILE * 0.5)
	var sp := BrickWorld.get_stud_metres()
	var hf := float(BrickTerrain.surface_plate(int(from.x / sp), int(from.y / sp)) + 1) * BrickWorld.get_plate_metres()
	var ht := float(BrickTerrain.surface_plate(int(to.x / sp), int(to.y / sp)) + 1) * BrickWorld.get_plate_metres()
	if curved:
		var eye := place(from.x, hf + height, from.y)
		var at := place(to.x, ht, to.y)
		cam.look_at_from_position(eye, at, (eye + p0).normalized())
	else:
		cam.look_at_from_position(Vector3(from.x, hf + height, from.y) - Vector3(c0.x, 0, c0.y),
				Vector3(to.x, ht, to.y) - Vector3(c0.x, 0, c0.y), Vector3.UP)


func _tile(i: int, j: int, mat: Material) -> int:
	var d: Dictionary = BrickTerrain.build_tile(i, j)
	var arr: Array = d.mesh
	if arr.is_empty():
		return 0
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	# Flat: as the game draws it.
	var fm := ArrayMesh.new()
	fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var fmi := MeshInstance3D.new()
	fmi.mesh = fm
	fmi.material_override = mat
	fmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flat_root.add_child(fmi)
	fmi.position = Vector3(i * TILE - c0.x, 0.0, j * TILE - c0.y)
	# Curved: every vertex through the map, normals turned by the tile's
	# tangent frame at its centre. Positions relative to the tile's own corner,
	# so the node carries the large part.
	var corner := place(i * TILE, 0.0, j * TILE)
	var cx := (i + 0.5) * TILE
	var cz := (j + 0.5) * TILE
	var up := dir_of(cx, cz)
	var ex := (place(cx + 1.0, 0.0, cz) - place(cx - 1.0, 0.0, cz)).normalized()
	var ez := (place(cx, 0.0, cz + 1.0) - place(cx, 0.0, cz - 1.0)).normalized()
	var frame := Basis(ex, up, ez)
	var mv := PackedVector3Array()
	mv.resize(v.size())
	var hi := -INF
	for k in v.size():
		mv[k] = place(i * TILE + v[k].x, v[k].y, j * TILE + v[k].z) - corner
		hi = maxf(hi, v[k].y)
	var ca := arr.duplicate()
	ca[Mesh.ARRAY_VERTEX] = mv
	if not nrm.is_empty():
		var mn := PackedVector3Array()
		mn.resize(nrm.size())
		for k in nrm.size():
			mn[k] = (frame * nrm[k]).normalized()
		ca[Mesh.ARRAY_NORMAL] = mn
	ca[Mesh.ARRAY_TANGENT] = null
	# The map mirrors a tile (field z runs to the sphere's -Z): turn every
	# triangle round, or its top faces away and is culled.
	if arr[Mesh.ARRAY_INDEX] != null:
		var idx: PackedInt32Array = (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
		for k in range(0, idx.size() - 2, 3):
			var t := idx[k + 1]
			idx[k + 1] = idx[k + 2]
			idx[k + 2] = t
		ca[Mesh.ARRAY_INDEX] = idx
	else:
		for k in range(0, mv.size() - 2, 3):
			var t := mv[k + 1]
			mv[k + 1] = mv[k + 2]
			mv[k + 2] = t
		ca[Mesh.ARRAY_VERTEX] = mv
		for key in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
			if ca[key] != null:
				var a2 = ca[key].duplicate()
				for k in range(0, a2.size() - 2, 3):
					var t2 = a2[k + 1]
					a2[k + 1] = a2[k + 2]
					a2[k + 2] = t2
				ca[key] = a2
	var cm := ArrayMesh.new()
	cm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ca)
	var cmi := MeshInstance3D.new()
	cmi.mesh = cm
	cmi.material_override = mat
	cmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ball_root.add_child(cmi)
	cmi.position = corner
	tops[cmi] = [up, R + hi]
	return int(d.get("triangle_count", v.size() / 3))


func _show_all() -> void:
	for mi in tops:
		(mi as Node3D).visible = true


## Hide every curved tile whose top is under the horizon from `eye` (planet
## coordinates, the centre at 0): the angle from the eye's straight-down to the
## tile is past the horizon's angle plus what the tile's own height lets it
## stick up over the curve. Returns how many were hidden.
func _cull(eye: Vector3) -> int:
	var re := eye.length()
	var h_eye := acos(clampf(R / re, -1.0, 1.0))
	var n := 0
	for mi in tops:
		var t: Array = tops[mi]
		var up: Vector3 = t[0]
		var rt: float = t[1]
		var over := acos(clampf(R / rt, -1.0, 1.0))
		# Its half diagonal, as an angle, so a tile partly over is kept.
		var slack := (TILE * 0.71) / R
		var ang := up.angle_to(eye / re)
		var hide := ang - slack > h_eye + over
		(mi as Node3D).visible = not hide
		if hide:
			n += 1
	return n


func _measure(what: String) -> Array:
	for i in 30:
		await RenderingServer.frame_post_draw
	var vp := root.get_viewport().get_viewport_rid()
	var cpu: Array[float] = []
	var gpu: Array[float] = []
	for f in FRAMES:
		await RenderingServer.frame_post_draw
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
	return [what] + _mw(cpu) + _mw(gpu)


func _mw(a: Array[float]) -> Array:
	var m := 0.0
	var w := 0.0
	for x in a:
		m += x
		w = maxf(w, x)
	return [m / a.size(), w]


func _shot(name: String) -> void:
	for i in 5:
		await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % name)
	print("[draw] shot written: %s.png" % name)
