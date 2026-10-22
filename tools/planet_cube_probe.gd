extends SceneTree

## Test 6 of the sphere-planet feasibility tests (Docs/Planets.md 10b): our
## terrain tiles on a cubed sphere, at a face edge and at a corner.
##
##   --fixed-fps 30 --path . --script res://tools/planet_cube_probe.gd [--headless]
##   (windowed, it also writes res://shots/planet_cube_*.png)
##
## R = 10 km, STA doc 23's warp (blend 0.48), tiles from BrickTerrain.build_tile
## exactly as the flat game builds them, every vertex mapped onto the sphere and
## the mapped triangles used as the collider. The faces are an UNFOLDED NET of
## the flat field: +Y is field tiles [0, N)^2, +X is attached along +Y's x = L
## edge and -Z along its z = L edge, so the field runs on unbroken across those
## two edges -- as it can across 5 of a cube's 12. The corner's third edge
## (+X against -Z) is a CUT: the two sides come from different parts of the
## flat field, as 7 edges and all 8 corners must with a 2D field.
##
## Measured: rays toward the centre on a 5 cm grid across each seam (a miss is
## a hole; a jump between neighbours is a step), the shape of the tiles at the
## corner, and the radial walker (tools/planet_radial_body.gd) walking across.

const Radial := preload("res://tools/planet_radial_body.gd")
const R := 10000.0
const BLEND := 0.48
const N := 1402                  # tiles per face edge; even, so an edge is a tile edge
const TILE := 11.2

var L := N * TILE                # a face's width in the flat field
var p0 := Vector3.ZERO           # the scene origin, on the sphere
var root3d: Node3D
var ok := 0
var fail := 0
var started := false


func _initialize() -> void:
	pass


func _process(_delta: float) -> bool:
	if not started:
		started = true
		_run()
	return false


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


static func warp(t: float) -> float:
	return lerpf(t, tan(t * PI / 4.0), BLEND)


## A point of the flat field (metres, the net's coordinates) as a direction:
## +Y for x, z in [0, L]; +X past x = L; -Z past z = L (see the header).
func dir_of(x: float, z: float) -> Vector3:
	var d: Vector3
	if x > L and z <= L:
		d = Vector3(1.0, warp(1.0 - 2.0 * (x - L) / L), -warp(2.0 * z / L - 1.0))
	elif z > L and x <= L:
		d = Vector3(warp(2.0 * x / L - 1.0), warp(1.0 - 2.0 * (z - L) / L), -1.0)
	else:
		d = Vector3(warp(2.0 * x / L - 1.0), 1.0, -warp(2.0 * z / L - 1.0))
	return d.normalized()


## A field point at height h (metres) on the planet, relative to the origin.
## Done in double: GDScript floats are 64-bit, Vector3 only stores the result.
func place(x: float, h: float, z: float) -> Vector3:
	var d := dir_of(x, z)
	var r := R + h
	return Vector3(d.x * r - p0.x, d.y * r - p0.y, d.z * r - p0.z)


## Field tile (i, j), every vertex mapped; a MeshInstance and a trimesh body.
func tile(i: int, j: int, colour: Color) -> Dictionary:
	var d: Dictionary = BrickTerrain.build_tile(i, j)
	var arr: Array = d.mesh
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var out := PackedVector3Array()
	out.resize(v.size())
	for k in v.size():
		out[k] = place(i * TILE + v[k].x, v[k].y, j * TILE + v[k].z)
	arr = arr.duplicate()
	arr[Mesh.ARRAY_VERTEX] = out
	arr[Mesh.ARRAY_NORMAL] = null
	arr[Mesh.ARRAY_TANGENT] = null
	var st := SurfaceTool.new()
	var am := ArrayMesh.new()
	var clean := []
	clean.resize(Mesh.ARRAY_MAX)
	clean[Mesh.ARRAY_VERTEX] = out
	if not idx.is_empty():
		clean[Mesh.ARRAY_INDEX] = idx
	if arr[Mesh.ARRAY_COLOR] != null:
		clean[Mesh.ARRAY_COLOR] = arr[Mesh.ARRAY_COLOR]
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, clean)
	st.create_from(am, 0)
	st.generate_normals()
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = colour
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	root3d.add_child(mi)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	# The net's map mirrors a tile (field z runs to the sphere's -Z), so its
	# triangles wind the other way: both sides collide, both sides draw.
	var tri: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	tri.backface_collision = true
	cs.shape = tri
	body.add_child(cs)
	root3d.add_child(body)
	# The same tile unmapped, as the flat game has it, in a space of its own:
	# what a ray at this field point should find.
	var fam := ArrayMesh.new()
	var fl := []
	fl.resize(Mesh.ARRAY_MAX)
	var fv := PackedVector3Array()
	fv.resize(v.size())
	for k in v.size():
		fv[k] = v[k] + Vector3(i * TILE, 0.0, j * TILE)
	fl[Mesh.ARRAY_VERTEX] = fv
	if not idx.is_empty():
		fl[Mesh.ARRAY_INDEX] = idx
	fam.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fl)
	var fbody := StaticBody3D.new()
	var fcs := CollisionShape3D.new()
	var ftri: ConcavePolygonShape3D = fam.create_trimesh_shape()
	ftri.backface_collision = true
	fcs.shape = ftri
	fbody.add_child(fcs)
	flat_root.add_child(fbody)
	return {"mi": mi, "body": body, "flat": fbody}


## The flat twins' space (a SubViewport's World3D that never draws).
var flat_root: Node3D


## The flat field's height under field (x, z): a ray down through the twins.
func flat_h(x: float, z: float) -> float:
	var hit := flat_root.get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(Vector3(x, 200.0, z), Vector3(x, -200.0, z)))
	return NAN if hit.is_empty() else float(hit.position.y)


func _run() -> void:
	BrickTerrain.configure(7)
	root3d = Node3D.new()
	root.add_child(root3d)
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.size = Vector2i(2, 2)
	root.add_child(vp)
	flat_root = Node3D.new()
	vp.add_child(flat_root)
	var drawn := DisplayServer.get_name() != "headless"

	# The mapping itself, before any tile: the two faces of an edge agree on
	# it, and what a 32-stud tile becomes near the edge and at a corner.
	var worst_edge := 0.0
	for k in 21:
		var z := L * k / 20.0
		var a := dir_of(L, z) * R
		var b := dir_of(L + 1e-7, z) * R
		worst_edge = maxf(worst_edge, a.distance_to(b))
	var cell := func(x: float, z: float) -> Vector2:
		var c := dir_of(x, z) * R
		return Vector2((dir_of(x + TILE, z) * R).distance_to(c), (dir_of(x, z + TILE) * R).distance_to(c))
	var mid: Vector2 = cell.call(L * 0.5, L * 0.5)
	var at_edge: Vector2 = cell.call(L - TILE, L * 0.5)
	var at_corner: Vector2 = cell.call(L - TILE, L - TILE)
	var cc := dir_of(L, L) * R
	# The corner's three edges: +Y|+X, +Y|-Z and the cut +X|-Z.
	var e1 := (dir_of(L, L - TILE) * R - cc).normalized()
	var e2 := (dir_of(L - TILE, L) * R - cc).normalized()
	var e3 := (dir_of(L + TILE, L - 0.0001) * R - cc).normalized()
	print("[cube] the map: the faces of an edge meet to %.6f mm; a tile is %.2f x %.2f m mid-face, %.2f x %.2f m at an edge, %.2f x %.2f m at a corner; at the corner its edges meet at %.1f, %.1f and %.1f deg" % [
			worst_edge * 1000.0, mid.x, mid.y, at_edge.x, at_edge.y, at_corner.x, at_corner.y,
			rad_to_deg(e1.angle_to(e2)), rad_to_deg(e2.angle_to(e3)), rad_to_deg(e3.angle_to(e1))])
	_check("the two faces of an edge meet (< 0.01 mm)", worst_edge < 1e-5)

	# --- The edge: +Y | +X, halfway along it. Two tiles each side, two along.
	var jm := N / 2
	p0 = dir_of(L, jm * TILE) * (R + 8.0)
	for i in [N - 2, N - 1]:
		for j in [jm - 1, jm]:
			tile(i, j, Color(0.75, 0.85, 0.75))
	for i in [N, N + 1]:
		for j in [jm - 1, jm]:
			tile(i, j, Color(0.85, 0.78, 0.7))
	await physics_frame
	await physics_frame
	var face_edge := _rays(L, jm * TILE, true, "the face edge +Y | +X (net-adjacent, the field unbroken)")
	var tile_edge := _rays(L - TILE, jm * TILE, true, "a tile edge inside +Y (the flat game's own seam)")
	_check("no hole across the face edge the flat game has not", face_edge.holes == 0, "%d" % face_edge.holes)
	_check("the ground across the face edge is the flat game's (none off by 5 cm)", face_edge.differ == 0,
			"%d of %d" % [face_edge.differ, face_edge.n])
	await _walk(L - 6.0, jm * TILE + 2.0, L + 6.0, jm * TILE + 2.0, "across the face edge")
	await _walk(L - TILE - 6.0, jm * TILE + 2.0, L - TILE + 6.0, jm * TILE + 2.0, "across a tile edge")
	if drawn:
		await _shot(L, jm * TILE, "planet_cube_edge")
	for c in root3d.get_children() + flat_root.get_children():
		c.queue_free()
	await physics_frame

	# --- The corner: +Y, +X and -Z meet; +X | -Z is a cut edge.
	p0 = dir_of(L, L) * (R + 8.0)
	tile(N - 1, N - 1, Color(0.75, 0.85, 0.75))
	tile(N, N - 1, Color(0.85, 0.78, 0.7))
	tile(N - 1, N, Color(0.7, 0.75, 0.9))
	await physics_frame
	await physics_frame
	var cut := _rays_cut()
	_check("the cut edge +X | -Z: no hole the flat game has not", cut.holes == 0, "%d of %d" % [cut.holes, cut.n])
	_check("the cut edge +X | -Z: no step of its own (worst < 0.2 m)", cut.step_max < 0.2, "%.2f m" % cut.step_max)
	if drawn:
		await _shot(L, L, "planet_cube_corner")
	print("[cube] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)


## Rays toward the centre on a 5 cm grid across the seam at field x = sx (or
## z, `across_x` false), 1.6 m each side, 4 m along it from field (sx, sz),
## each against a ray down through the flat twins at the same field point.
## A hole is a ray that finds nothing where the flat game has ground; a
## difference is a hit more than 5 cm off the flat game's height.
func _rays(sx: float, sz: float, across_x: bool, what: String) -> Dictionary:
	var pts: Array = []
	for a in 80:
		# 13 mm off the stud lattice: a ray exactly on an edge between two
		# triangles is a coin toss in any mesh, flat or not.
		var along := sz + a * 0.05 + 0.013
		for k in 64:
			var off := -1.6 + k * 0.05 + 0.013
			pts.append(Vector2(sx + off, along) if across_x else Vector2(along, sx + off))
	return _compare(pts, what)


func _compare(pts: Array, what: String) -> Dictionary:
	var space := (root3d.get_world_3d()).direct_space_state
	var holes := 0
	var flat_cracks := 0
	var differ := 0
	var worst := 0.0
	var diffs: Array[float] = []
	for q in pts:
		var x: float = q.x
		var z: float = q.y
		var want := flat_h(x, z)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(place(x, 60.0, z), place(x, -40.0, z)))
		if is_nan(want):
			flat_cracks += 1
			continue
		if hit.is_empty():
			holes += 1
			continue
		var h: float = (hit.position + p0).length() - R
		var d := absf(h - want)
		diffs.append(d)
		worst = maxf(worst, d)
		if d > 0.05:
			differ += 1
	diffs.sort()
	var med := diffs[diffs.size() / 2] if not diffs.is_empty() else NAN
	print("[cube] %s: %d rays; %d holes the flat game has no hole at (%d cracks it has itself); height against the flat game's: median %.4f m, %d off by more than 5 cm, worst %.3f m" % [
			what, pts.size(), holes, flat_cracks, med, differ, worst])
	return {"holes": holes, "differ": differ, "n": pts.size(), "median": med}


## The cut edge at the corner: rays from 1 m inside +X, across the sphere's own
## +X | -Z edge, to 1 m inside -Z, at 0.5 .. 9.4 m from the corner. The +X side
## is field (L + d, L + e) for e < 0; the -Z side (L - e, L + d). Each against
## the flat field at its own point -- and the step the cut makes: the flat
## field at (L + d, L) against (L, L + d), the same point of the sphere.
func _rays_cut() -> Dictionary:
	var pts: Array = []
	var steps: Array[float] = []
	for a in 60:
		var d := 0.5 + a * 0.15 + 0.013
		for k in 41:
			var e := -1.0 + k * 0.05 + 0.013
			if e < 0.0:
				pts.append(Vector2(L + d, L + e))
			else:
				pts.append(Vector2(L - e - 0.0001, L + d))
		var ha := flat_h(L + d, L - 0.01)
		var hb := flat_h(L - 0.01, L + d)
		if not is_nan(ha) and not is_nan(hb):
			steps.append(absf(ha - hb))
	var r := _compare(pts, "the cut edge +X | -Z at the corner")
	steps.sort()
	r.step_median = steps[steps.size() / 2] if not steps.is_empty() else NAN
	r.step_max = steps[-1] if not steps.is_empty() else NAN
	var zero := 0
	for s in steps:
		if s < 0.01:
			zero += 1
	print("[cube] the cut edge's own step (the two sides' field heights at one point of the sphere): median %.2f m, worst %.2f m; %d of %d points with none" % [
			r.step_median, r.step_max, zero, steps.size()])
	return r


## The radial walker from field (x0, z0) to (x1, z1) in a straight line on
## the flat field: does it stay on its feet, and how hard is it jolted?
func _walk(x0: float, z0: float, x1: float, z1: float, what: String) -> void:
	var w = Radial.new()
	w.centre = -p0
	root3d.add_child(w)
	var start := place(x0, 40.0, z0)
	w.place(start, place(x1, 40.0, z1) - start)
	# Drop it onto the ground first.
	for i in 60:
		await physics_frame
		if w.is_on_floor():
			break
	w.wish = Vector2(0.0, 1.0)
	var off_floor := 0
	var jolt := 0.0
	var prev_v := NAN
	var ticks := int(12.0 / w.speed * 30.0)
	for i in ticks:
		await physics_frame
		if not w.is_on_floor():
			off_floor += 1
		var vu: float = w.get_real_velocity().dot(w.up)
		if not is_nan(prev_v):
			jolt = maxf(jolt, absf(vu - prev_v))
		prev_v = vu
	w.wish = Vector2.ZERO
	print("[cube] walking %s: %d of %d ticks off the floor, the biggest change in speed along up in a tick %.2f m/s" % [
			what, off_floor, ticks, jolt])
	_check("walking %s: on its feet throughout" % what, off_floor <= 2, "%d off" % off_floor)
	w.queue_free()
	await physics_frame


func _shot(x: float, z: float, name: String) -> void:
	var sun := DirectionalLight3D.new()
	root3d.add_child(sun)
	var up := dir_of(x, z)
	sun.look_at_from_position(Vector3.ZERO, -up + Vector3(0.3, 0.0, 0.2), Vector3.FORWARD if absf(up.y) > 0.9 else Vector3.UP)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	var target := place(x, 8.0, z)
	var eye := place(x - 9.0, 20.0, z - 9.0)
	cam.look_at_from_position(eye, target, up)
	cam.current = true
	for i in 10:
		await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % name)
	print("[cube] shot written: %s.png" % name)
	cam.queue_free()
	sun.queue_free()
