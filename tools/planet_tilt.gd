extends RefCounted

## Test 3 of the sphere-planet feasibility tests (Docs/Planets.md 10b): a
## building on a pad in a TANGENT frame, under point gravity toward a centre
## 10 km below the pad. Run by tools/planet_passes.gd:
##   res://scenes/city.tscn -- --planet=tilt [--tilt=7]
##
## 7 degrees is a building 1.2 km round a 10 km planet from where the scene's
## axes are square to the ground. With a translation-only origin the axes never
## turn, so most of a planet is further round than that: --tilt=60 is the case
## that shows what still assumes the scene's -Y is down.
##
## The tower is registered as any is, then re-framed onto the pad before its
## shell and index are made: BuildingRegistry.on_grid would snap the tilt away,
## because grid_frame_at is still the world's frame (Planets.md 9.2).

const RADIUS := 10000.0

var p   # the pass (tools/planet_passes.gd)
var city: Node3D
var tilt_deg := 7.0
var frame := Transform3D()   # the pad's top centre, its +Y the local up
var area: Area3D
var pad: StaticBody3D


func _init(pass_node) -> void:
	p = pass_node
	city = pass_node.city
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tilt="):
			tilt_deg = float(a.trim_prefix("--tilt="))


func run() -> void:
	if "--ground=sphere" in OS.get_cmdline_user_args():
		await run_sphere()
		return
	var c = city
	await p._ticks(20)
	# Out past the city's east edge, and high enough at a steep tilt that what
	# falls off the pad never meets the world's own ground first.
	var top := Vector3(170.0, 6.0 if tilt_deg < 20.0 else 60.0, 0.0)
	frame = Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(tilt_deg)), top)
	_make_pad()
	_make_gravity()
	var b = _place_tower(16, 16, 30)
	print("[planet] tilt %.0f deg: pad up %v, gravity toward %v (%.1f km below)" % [
			tilt_deg, frame.basis.y, area.gravity_point_center, RADIUS / 1000.0])
	var cam: Camera3D = c.camera
	var view := func(dist: float, h: float) -> void:
		cam.global_position = frame * Vector3(-dist, h, -dist * 0.7)
		cam.look_at(frame * Vector3(0.0, h * 0.4, 0.0), frame.basis.y)
		cam.reset_physics_interpolation()
	view.call(45.0, 22.0)
	await p._ticks(30)
	var drawn := DisplayServer.get_name() != "headless"
	if drawn:
		await p._frames(10)
		await c._save("planet_tilt_%02d_standing" % int(tilt_deg))

	# Promote: does it stand under its own (tilted) weight?
	var chunk: int = c._promote(b.id)
	await p._ticks(60)
	var blocks0: int = c.world.get_alive_block_count(chunk)
	var pieces0: int = _pieces().size()
	print("[planet] tilt: promoted to chunk %d, %d bricks; chunk gravity %v (grid); %d pieces after 2 s" % [
			chunk, blocks0, c.world.get_chunk_gravity(chunk), pieces0])
	_ai_view(b, "standing")

	# Shoot it: small blasts up one face, as rounds and rockets do.
	var fx: float = b.recipe.footprint_x * c.STUD
	var fz: float = b.recipe.footprint_z * c.STUD
	for k in 6:
		c._blast(b.xform * Vector3(fx * (0.2 + 0.12 * k), 3.0 + 2.6 * k, -0.05), 0.9)
	await p._ticks(120)
	print("[planet] tilt: shot -- %d bricks left, %d pieces, %d crumbs" % [
			c.world.get_alive_block_count(chunk), _pieces().size(), _crumbs().size()])

	# Collapse: the ground storey out.
	var x := 0.0
	var blasts := 0
	while x <= fx + 0.01:
		var z := 0.0
		while z <= fz + 0.01:
			c._blast(b.xform * Vector3(minf(x, fx), 1.2, minf(z, fz)), 2.2)
			blasts += 1
			z += 2.5
		x += 2.5
	print("[planet] tilt: %d blasts on the ground storey" % blasts)
	if drawn:
		await p._ticks(25)
		await c._save("planet_tilt_%02d_falling" % int(tilt_deg))
	var t := 0
	var quiet := 0
	while t < 1800 and quiet < 90:
		await p._ticks(1)
		t += 1
		var moving := 0
		for isl in _pieces():
			if not isl.settled:
				moving += 1
		quiet = quiet + 1 if moving == 0 else 0
	print("[planet] tilt: %s after %d ticks" % ["all settled" if quiet >= 90 else "NOT all settled", t])
	_report_rest()
	_ai_view(b, "fallen")
	if drawn:
		view.call(40.0, 14.0)
		await p._frames(12)
		await c._save("planet_tilt_%02d_settled" % int(tilt_deg))
		cam.global_position = frame * Vector3(-14.0, 3.0, -30.0)
		cam.look_at(frame * Vector3(4.0, 0.5, 0.0), frame.basis.y)
		cam.reset_physics_interpolation()
		await p._frames(12)
		await c._save("planet_tilt_%02d_low" % int(tilt_deg))


func _make_pad() -> void:
	pad = StaticBody3D.new()
	pad.collision_layer = Layers.WORLD
	pad.collision_mask = Layers.STRUCTURE_MASK
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(70.0, 2.0, 70.0)
	cs.shape = box
	cs.position = Vector3(0.0, -1.0, 0.0)
	pad.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	mi.position = cs.position
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.5, 0.42)
	mi.material_override = mat
	pad.add_child(mi)
	city.add_child(pad)
	pad.global_transform = frame


## Point gravity over the pad and everything that can fall off it, replacing
## the project's: what Jolt applies to every loose body in it.
func _make_gravity() -> void:
	area = Area3D.new()
	area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	area.gravity_point = true
	area.gravity_point_unit_distance = 0.0
	area.gravity = Gravity.strength()
	area.gravity_point_center = frame.origin - frame.basis.y * RADIUS
	area.collision_layer = 0
	area.collision_mask = 0xFFFFF
	area.monitorable = false
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 160.0
	cs.shape = sph
	area.add_child(cs)
	city.add_child(area)
	area.global_transform = Transform3D(Basis(), Vector3.ZERO)
	cs.position = frame.origin


func _place_tower(fx: int, fz: int, courses: int):
	var c = city
	var stud: float = c.STUD
	var id: int = c.registry.register(fx, fz, courses, Transform3D(Basis(), frame.origin), {})
	var b = c.registry.get_building(id)
	b.xform = frame * Transform3D(Basis(), Vector3(-fx * stud * 0.5, 0.0, -fz * stud * 0.5))
	c._add_staircase(id, fx, fz, courses)
	c._index_building(id)
	c._make_shell(id)
	return b


func _pieces() -> Array:
	var out := []
	for isl in city.islands.islands:
		if isl.is_valid() and isl.body != null:
			out.append(isl)
	return out


## Every crumb's position (IslandManager's small pieces with no body).
func _crumbs() -> Array:
	var out := []
	var im = city.islands
	if not ("_crumbs" in im):
		return out
	for cr in im._crumbs.values():
		for q in cr.pos:
			out.append(q)
	return out


## Where everything came to rest, measured along the pad's own up: on the pad
## (its lowest point within a few cm of the top), floating, sunk, or gone off.
func _report_rest() -> void:
	var up := frame.basis.y
	var on := 0
	var off := 0
	var asleep := 0
	var frozen := 0
	var unsettled := 0
	var worst_tilt := 0.0
	for isl in _pieces():
		var box: AABB = city.islands.world_aabb(isl)
		var centre := box.get_center()
		var h := (centre - frame.origin).dot(up)
		var lateral := (centre - frame.origin) - up * h
		if absf(lateral.x) < 35.0 and absf(lateral.z) < 35.0 and h > -1.0 and h < 30.0:
			on += 1
		else:
			off += 1
		if isl.body.sleeping:
			asleep += 1
		if isl.body.freeze:
			frozen += 1
		if not isl.settled:
			unsettled += 1
	var crumbs := _crumbs()
	var crumbs_on := 0
	var crumb_h: Array[float] = []
	for q in crumbs:
		var h: float = (q - frame.origin).dot(up)
		crumb_h.append(h)
		if h > -0.3 and h < 2.0:
			crumbs_on += 1
	crumb_h.sort()
	var mid := crumb_h[crumb_h.size() / 2] if not crumb_h.is_empty() else NAN
	print("[planet] tilt: %d pieces -- %d on the pad, %d off it; %d frozen (settled), %d Jolt-asleep, %d not settled" % [
			on + off, on, off, frozen, asleep, unsettled])
	print("[planet] tilt: %d crumbs -- %d lying on the pad (0.3 m under to 2 m over its top along its up); median height over it %.2f m" % [
			crumbs.size(), crumbs_on, mid])
	# The heap: crumbs that came to rest, laid flat "where they stopped". How
	# high over the pad each one's centre is, along the pad's up, and how far
	# its flat face is turned from the pad's.
	var heap = city.islands.heap
	if heap != null:
		var hs: Array[float] = []
		var turns: Array[float] = []
		for h in heap._heaps.values():
			for slot in h.xf.size():
				if slot >= h.used.size() or not h.used[slot]:
					continue
				var at: Transform3D = h.xf[slot]
				hs.append((at.origin - frame.origin).dot(up))
				var best := 0.0
				for k in 3:
					best = maxf(best, absf(at.basis[k].normalized().dot(up)))
				turns.append(rad_to_deg(acos(clampf(best, -1.0, 1.0))))
		hs.sort()
		turns.sort()
		if hs.is_empty():
			print("[planet] tilt: heap holds no bricks")
		else:
			print("[planet] tilt: heap holds %d laid bricks; centre over the pad along its up: min %.2f, median %.2f, max %.2f m; flat face turned from the pad's by median %.1f deg, max %.1f" % [
					hs.size(), hs[0], hs[hs.size() / 2], hs[-1], turns[turns.size() / 2], turns[-1]])


## What the AI makes of the building: lines through it and a floor inside it.
func _ai_view(b, when: String) -> void:
	var c = city
	var stud: float = c.STUD
	var fx: float = b.recipe.footprint_x * stud
	var fz: float = b.recipe.footprint_z * stud
	c.ai_world.sync()
	# Straight through two walls, 4 m up, in the building's own frame.
	var a: Vector3 = b.xform * Vector3(-3.0, 4.0, fz * 0.5)
	var e: Vector3 = b.xform * Vector3(fx + 3.0, 4.0, fz * 0.5)
	var tr: Dictionary = c.ai_world.trace(a, e)
	# The same line in WORLD terms: level in the world, not in the building.
	var e_world := a + Vector3(fx + 6.0, 0.0, 0.0)
	var tr_w: Dictionary = c.ai_world.trace(a, e_world)
	# A point on the first floor inside, and what navigation makes of it.
	var inside: Vector3 = b.xform * Vector3(fx * 0.5, 0.15, fz * 0.5)
	var snapped: Vector3 = c.ai_nav.snap(inside)
	var stand: bool = c.ai_nav.can_stand(inside)
	print("[planet] tilt AI (%s): a line square through it in its frame -- %d bricks, %.1f proxy, hit %s; a world-level line -- %d bricks, %.1f proxy; ground floor inside: can_stand %s, snap moves it %.2f m (%.2f along its up)" % [
			when, int(tr.get("bricks", 0)), float(tr.get("proxy_bricks", 0.0)), tr.get("hit", false),
			int(tr_w.get("bricks", 0)), float(tr_w.get("proxy_bricks", 0.0)), stand,
			snapped.distance_to(inside), (snapped - inside).dot(frame.basis.y)])


# ---------------------------------------------------------------------------
# Test 4's half: pieces coming to rest on CURVED ground. A small sphere (the
# curvature exaggerated 250 times against a 10 km planet) with point gravity
# toward its centre, and a tower in the tangent frame at 0, 45 and 90 degrees
# round it. Each is brought down; where do its pieces, crumbs and laid bricks
# end up, measured along the sphere's own normal there?
#   res://scenes/city.tscn -- --planet=tilt --ground=sphere

const SPHERE_R := 40.0
const SPHERE_AT := Vector3(210.0, 50.0, 0.0)


func run_sphere() -> void:
	var c = city
	await p._ticks(20)
	var ball := StaticBody3D.new()
	ball.collision_layer = Layers.WORLD
	ball.collision_mask = Layers.STRUCTURE_MASK
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = SPHERE_R
	cs.shape = sh
	ball.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = SPHERE_R
	sm.height = SPHERE_R * 2.0
	sm.radial_segments = 128
	sm.rings = 64
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.5, 0.42)
	mi.material_override = mat
	ball.add_child(mi)
	c.add_child(ball)
	ball.global_position = SPHERE_AT
	area = Area3D.new()
	area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	area.gravity_point = true
	area.gravity_point_unit_distance = 0.0
	area.gravity = Gravity.strength()
	area.collision_layer = 0
	area.collision_mask = 0xFFFFF
	area.monitorable = false
	var acs := CollisionShape3D.new()
	var asph := SphereShape3D.new()
	asph.radius = SPHERE_R * 2.2
	acs.shape = asph
	area.add_child(acs)
	c.add_child(area)
	area.global_position = SPHERE_AT
	area.gravity_point_center = Vector3.ZERO   # local: the sphere's centre

	var towers := []
	for deg in [0.0, 45.0, 90.0]:
		var b_ := Basis(Vector3(0, 0, 1), deg_to_rad(deg))
		frame = Transform3D(b_, SPHERE_AT + b_.y * SPHERE_R)
		towers.append([deg, _place_tower(12, 12, 24), frame])
	var cam: Camera3D = c.camera
	cam.global_position = SPHERE_AT + Vector3(0.0, 25.0, -110.0)
	cam.look_at(SPHERE_AT + Vector3(-10.0, 15.0, 0.0), Vector3.UP)
	cam.reset_physics_interpolation()
	var drawn := DisplayServer.get_name() != "headless"
	await p._ticks(30)
	if drawn:
		await p._frames(10)
		await c._save("planet_sphere_standing")
	# One at a time, the camera 25 m off each (what is far from every eye is
	# deleted, not crumbled: IslandManager.far_from_everyone).
	for t in towers:
		var b = t[1]
		var f: Transform3D = t[2]
		cam.global_position = f * Vector3(-14.0, 9.0, -20.0)
		cam.look_at(f * Vector3(2.0, 3.0, 2.0), f.basis.y)
		cam.reset_physics_interpolation()
		await p._ticks(10)
		var chunk: int = c._promote(b.id)
		await p._ticks(30)
		print("[planet] sphere: tower at %.0f deg, chunk %d, %d bricks, standing" % [
				t[0], chunk, c.world.get_alive_block_count(chunk)])
		var fx: float = b.recipe.footprint_x * c.STUD
		var fz: float = b.recipe.footprint_z * c.STUD
		var x := 0.0
		while x <= fx + 0.01:
			var z := 0.0
			while z <= fz + 0.01:
				c._blast(b.xform * Vector3(minf(x, fx), 1.2, minf(z, fz)), 2.2)
				z += 2.5
			x += 2.5
		if drawn:
			await p._ticks(25)
			await c._save("planet_sphere_%02d_falling" % int(t[0]))
		await _settle("tower at %.0f deg down" % t[0])
		# The fallen section broken up where it lies, so pieces scatter over
		# the curve and come to rest on it at their own angles.
		for isl in _pieces():
			if isl.owner != b.id:
				continue
			var box: AABB = c.islands.world_aabb(isl)
			for k in 3:
				c._blast(box.get_center() + (box.size * 0.3) * Vector3(k - 1, 0.3 * (k - 1), 0.2), 1.6)
		await _settle("tower at %.0f deg broken up" % t[0])
		_report_sphere(t[0], t[1], t[2])
		if drawn:
			await p._frames(12)
			await c._save("planet_sphere_%02d_settled" % int(t[0]))
	_report_heap_all()
	if drawn:
		cam.global_position = SPHERE_AT + Vector3(0.0, 25.0, -110.0)
		cam.look_at(SPHERE_AT + Vector3(-10.0, 15.0, 0.0), Vector3.UP)
		cam.reset_physics_interpolation()
		await p._frames(12)
		await c._save("planet_sphere_settled")


func _settle(what: String) -> void:
	var tk := 0
	var quiet := 0
	while tk < 1800 and quiet < 90:
		await p._ticks(1)
		tk += 1
		var moving := 0
		for isl in _pieces():
			if not isl.settled:
				moving += 1
		quiet = quiet + 1 if moving == 0 else 0
	print("[planet] sphere: %s -- %s after %d ticks" % [what, "all settled" if quiet >= 90 else "NOT all settled", tk])


## Height over the sphere is |p - centre| - R; "flat" is a face square to the
## normal there.
func _report_sphere(deg: float, b, f: Transform3D) -> void:
	var up := f.basis.y
	var n := 0
	var settled := 0
	var hs: Array[float] = []
	for isl in _pieces():
		if isl.owner != b.id:
			continue
		n += 1
		if isl.settled:
			settled += 1
		var box: AABB = city.islands.world_aabb(isl)
		hs.append((box.get_center() - SPHERE_AT).length() - SPHERE_R)
	hs.sort()
	var heap_h: Array[float] = []
	var heap_turn: Array[float] = []
	var heap = city.islands.heap
	if heap != null:
		for h in heap._heaps.values():
			for slot in h.xf.size():
				if slot >= h.used.size() or not h.used[slot]:
					continue
				var at: Transform3D = h.xf[slot]
				var rel: Vector3 = at.origin - SPHERE_AT
				# This tower's: nearer its axis than the others' (22.5 deg).
				if rad_to_deg(rel.normalized().angle_to(up)) > 22.5:
					continue
				heap_h.append(rel.length() - SPHERE_R)
				var nrm := rel.normalized()
				var best := 0.0
				for k in 3:
					best = maxf(best, absf(at.basis[k].normalized().dot(nrm)))
				heap_turn.append(rad_to_deg(acos(clampf(best, -1.0, 1.0))))
	heap_h.sort()
	heap_turn.sort()
	var fmt := func(a: Array[float]) -> String:
		if a.is_empty():
			return "none"
		return "min %.2f / median %.2f / max %.2f" % [a[0], a[a.size() / 2], a[-1]]
	print("[planet] sphere %2.0f deg: %d pieces, %d settled; their centres over the ground %s m; %d laid bricks near it over the ground %s m, faces turned from the ground's %s deg" % [
			deg, n, settled, fmt.call(hs), heap_h.size(), fmt.call(heap_h), fmt.call(heap_turn)])


## Every laid brick: how far it is from the sphere's surface, and how many
## lie on the world's own ground instead (y about 0, far below the sphere).
func _report_heap_all() -> void:
	var heap = city.islands.heap
	if heap == null:
		return
	var on_ball := 0
	var on_world := 0
	var elsewhere := 0
	for h in heap._heaps.values():
		for slot in h.xf.size():
			if slot >= h.used.size() or not h.used[slot]:
				continue
			var at: Transform3D = h.xf[slot]
			var hb: float = (at.origin - SPHERE_AT).length() - SPHERE_R
			if hb > -0.3 and hb < 2.5:
				on_ball += 1
			elif at.origin.y < 2.0:
				on_world += 1
			else:
				elsewhere += 1
	print("[planet] sphere: all laid bricks -- %d on the sphere, %d down on the world's flat ground, %d elsewhere (crumbs in the air: %d)" % [
			on_ball, on_world, elsewhere, _crumbs().size()])
