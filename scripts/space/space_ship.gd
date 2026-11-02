class_name SpaceShip
extends SpaceStation

## A ship to fly (Docs/Planets.md 11.12 step 3; after zylanntest's
## game/ship/scripts/ship_controller.gd: 6DOF, a speed cap that falls near the
## ground, a chase camera). Built as a station's module -- a brick hull, a door,
## a floor -- with engines; a frame of its own the same way.
##
## Where it is, it keeps itself: `rel` in the frame of `ref`, the planet whose
## shell it is in (planet-local, so landed it turns with the ground), or the
## star's in open space (`ref` null); `vel` in that frame. PlanetSystem flies it
## (`fly`) and hands it between frames, place and velocity unchanged in space.
## In open space with the player aboard it is the player's frame: it holds still
## and the universe moves round it, so its deck can be walked while it flies.
## In a planet's shell it moves in the planet's frame (only seated there), keeps
## off the ground by the planet's own height field, levels itself low down and
## sets down.

const FIELD_SHIP := 60.0
## m/s^2 at least; more as the cap grows.
const ACCEL := 40.0
## The cap: by height over the ground, SPEED_LOW at the ground to SPEED_SPACE
## (zylanntest's 300 -> 2000 m/s, lower here at the ground for landing).
const SPEED_LOW := 25.0
const SPEED_SPACE := 2000.0
## Boost: this share of the height over the nearest ground a second, to CRUISE_MAX.
const CRUISE := 0.5
const CRUISE_MAX := 300000.0
## rad/s at full stick.
const TURN := 1.2
## Air under its floor when it sits down; auto-level under LEVEL_BELOW.
const CLEARANCE := 0.3
const LEVEL_BELOW := 120.0
## PlanetSystem.SEE_FAR. The system is never named here by type: PlanetSystem
## names this class, and a class cycle leaks both scripts at exit and crashes
## a headless run as it quits (the system is `ps`, untyped).
const SEE_FAR := 400000.0
## A ram over this (m/s) blasts what it hit.
const RAM_SPEED := 8.0

## It ran into a building or a station, at world `point`, at `speed`.
signal rammed(point: Vector3, speed: float)

var ref: PlanetBody = null
var rel := Transform3D()
## What `rel.origin` could not hold of its place: in open space it is millions of
## metres from the star, where a float32 is good to half a metre and a slow ship
## would not move at all.
var fine := Vector3.ZERO
var vel := Vector3.ZERO
var piloted := false
var landed := false
## The pilot's hands: x strafe right, y up, z forward (-1..1); yaw left, pitch
## up, roll right (-1..1); boost.
var thrust := Vector3.ZERO
var steer := Vector3.ZERO
var boost := false
## Over the ground (m), this frame.
var altitude := 0.0
var camera: Camera3D
var rams := 0
var _hull: BoxShape3D
## A generated ship parked on a planet: a stair of bricks hung from its airlock
## to the ground (its sill can stand metres up), taken up when it is flown.
var gangway: Node3D = null
var gangway_steps := 0
var _gang_body: StaticBody3D = null
## A step: one brick up (what the pawn steps), two studs deep, four across.
const GANG_RISE := 3
const GANG_TREAD := 2
const GANG_STEPS := 24


func setup_ship(d: OrbitalData) -> void:
	setup(d)
	field = FIELD_SHIP
	var stud := BrickWorld.get_stud_metres()
	var w := d.fx * stud
	var dd := d.fz * stud
	if d.layout == "generated":
		# Grown now (ShipBuild, ~0.6 s): its seat and its hull box are wanted at once.
		prepare()
		if recipe != null:
			w = d.fz * stud    # the build's beam is its width, its length its depth
			dd = d.fx * stud
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.36, 0.40)
	mat.metallic = 0.7
	mat.roughness = 0.4
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(0.55, 0.8, 1.0)
	# A generated ship's sized to its hull (a deck is ~2.7 m) and clear of the
	# airlock amidships at its stern.
	var k := 1.0 if recipe == null else clampf(height * 0.3 / 1.8, 0.35, 1.0)
	var ex := w * 0.3 if recipe == null else maxf(w * 0.3, 1.8 * k + 1.2)
	var bricked_engines: Array = recipe.meta.get("engines", []) if recipe != null else []
	# A generated ship's engines are its bricks (ShipBuild): a glow on each one's back.
	for at: Array in bricked_engines:
		var org := recipe.origin()
		var g := MeshInstance3D.new()
		var gm := CylinderMesh.new()
		gm.top_radius = ShipBuild.NACELLE.x * stud * 0.38
		gm.bottom_radius = gm.top_radius
		gm.height = 0.1
		g.mesh = gm
		g.material_override = glow
		g.transform = frame * Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3((float(at[0]) - org.x) * stud - 0.06,
				(float(at[1]) - org.y) * BrickWorld.get_plate_metres(), (float(at[2]) - org.z) * stud))
		look.add_child(g)
	for side in ([] if not bricked_engines.is_empty() else [-1.0, 1.0]):
		var e := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 1.4 * k
		cm.bottom_radius = 1.8 * k
		cm.height = 5.0 * k
		e.mesh = cm
		e.material_override = mat
		e.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		e.position = Vector3(side * ex, height * 0.5, dd * 0.5 + 2.5 * k)
		look.add_child(e)
		var f := MeshInstance3D.new()
		var fm := CylinderMesh.new()
		fm.top_radius = 1.3 * k
		fm.bottom_radius = 1.3 * k
		fm.height = 0.2
		f.mesh = fm
		f.material_override = glow
		f.rotation = Vector3(PI * 0.5, 0.0, 0.0)
		f.position = Vector3(side * ex, height * 0.5, dd * 0.5 + 5.0 * k + 0.05)
		look.add_child(f)
	_hull = BoxShape3D.new()
	_hull.size = Vector3(w, height, dd)
	camera = Camera3D.new()
	camera.name = "ChaseCamera"
	camera.fov = 75.0
	camera.near = 0.1
	camera.far = SEE_FAR
	add_child(camera)
	camera.look_at_from_position(Vector3(0.0, height + 9.0, dd * 0.5 + 30.0), Vector3(0.0, height * 0.6, -dd * 0.5), Vector3.UP)


## Where the pilot sits: on its floor, a third of the way back from the nose.
func seat() -> Vector3:
	var stud := BrickWorld.get_stud_metres()
	if recipe != null and seat_cell.x >= 0:
		# On the bridge's floor (ShipBuild), its middle.
		return frame * Vector3((seat_cell.x + 0.5) * stud, seat_cell.y * BrickWorld.get_plate_metres() + 0.05,
				(seat_cell.z + 0.5) * stud)
	var floor_y := TowerRecipe.SLAB_PLATES * BrickWorld.get_plate_metres()
	return frame * Vector3(data.fx * stud * 0.5, floor_y + 0.05, data.fz * stud * 0.35)


## Its transform in the space frame, now.
func space_xform(ps) -> Transform3D:
	if ref == null:
		return rel
	return ps.sys.xform(ps.index_of(ref), ps.t) * rel


## The space-frame velocity of the point `x` (space frame) held fixed in it.
func frame_velocity(ps, x: Vector3) -> Vector3:
	if ref == null:
		return vel
	var i: int = ps.index_of(ref)
	return ps._frame_velocity(ref, x) + ps.sys.spin(i, ps.t) * vel


## Point its nose (-Z) along `dir` in its reference frame, its up as near `up`
## as that allows (an autopilot's hands, for scripted passes).
func aim(dir: Vector3, up: Vector3) -> void:
	# No way to point is no turn: a zero here would leave no basis at all.
	if dir.length_squared() < 1e-6:
		return
	var z := -dir.normalized()
	var x := up.cross(z)
	if x.length_squared() < 1e-6:
		x = rel.basis.x
	x = x.normalized()
	rel.basis = Basis(x, z.cross(x), z)


func fly(ps, dt: float) -> void:
	# Over the nearest ground: its planet's, else the nearest body's.
	var up := Vector3.UP
	var ground_r := 0.0
	if ref != null:
		up = rel.origin.normalized()
		ground_r = ref.data.radius + ref.data.height(up)
		altitude = rel.origin.length() - ground_r
	else:
		altitude = INF
		for i in ps.bodies.size():
			altitude = minf(altitude, (rel.origin - ps.sys.pos(i, ps.t)).length() - ps.bodies[i].data.radius)
	if landed and not piloted:
		vel = Vector3.ZERO
		return
	if piloted:
		var turn := steer * TURN * dt
		rel.basis = (rel.basis * Basis(Vector3.UP, turn.x) * Basis(Vector3.RIGHT, turn.y)
				* Basis(Vector3.BACK, turn.z)).orthonormalized()
	var cap := clampf(altitude * 0.5, SPEED_LOW, SPEED_SPACE)
	if boost:
		cap = maxf(cap, minf(altitude * CRUISE, CRUISE_MAX))
	# Never a quarter of the way to the ground in one frame, whatever the frame.
	cap = minf(cap, maxf(altitude * 0.25 / maxf(dt, 0.001), SPEED_LOW))
	# By a station: its speed held at neutral, the cap down as it nears (docking).
	var dock: Array = ps.ship_match(self)
	if dock[1] >= 0.0:
		cap = minf(cap, maxf(float(dock[1]) * 0.25, 10.0))
	var hands := thrust if piloted else Vector3.ZERO
	if hands.length_squared() > 1.0:
		hands = hands.normalized()
	var target: Vector3 = rel.basis * Vector3(hands.x, hands.y, -hands.z) * cap + dock[0]
	if ref == null:
		# Stopped is stopped beside the nearest body (a flight computer), or among a
		# belt's rocks.
		if not ps.in_belt(rel.origin):
			var best := 0
			for i in ps.bodies.size():
				if (rel.origin - ps.sys.pos(i, ps.t)).length() < (rel.origin - ps.sys.pos(best, ps.t)).length():
					best = i
			target += ps.sys.vel(best, ps.t)
	# Braking goes by the speed it has, not the cap, which falls as it nears:
	# at a low frame rate it reached a planet at 279 km/s.
	vel = vel.move_toward(target, maxf(ACCEL, maxf(cap, vel.length()) * 0.8) * dt)
	var step := fine + vel * dt
	var next := rel.origin + step
	var free := next
	if ref != null:
		# Kept off the ground (the planet's own heights, as the voxels have them).
		var n_up := next.normalized()
		var g := ref.data.radius + ref.data.height(n_up)
		if next.length() < g + CLEARANCE:
			next = n_up * (g + CLEARANCE)
			var into := vel.dot(n_up)
			if into < 0.0:
				vel -= n_up * into
		# Low down, or with nobody at the controls, it levels itself, its heading kept.
		if altitude < LEVEL_BELOW or not piloted:
			var b := rel.basis.orthonormalized()
			var level := (Basis(Quaternion(b.y.normalized(), n_up)) * b).orthonormalized()
			rel.basis = b.slerp(level, clampf(dt * 1.5, 0.0, 1.0)).orthonormalized()
		landed = next.length() < g + CLEARANCE + 0.05 and vel.length() < 0.5 and hands.y <= 0.0
	if ps.frame_node() != self:
		next = _sweep(ps, next)
	if ps.rock_block(self, next):
		rams += 1
		vel = ps.ship_match(self)[0]
		next = rel.origin
	fine = step - (next - rel.origin) if next == free else Vector3.ZERO
	rel.origin = next


## Lowered while it is parked in its bricks on a planet, nobody at its controls;
## taken up otherwise (PlanetSystem, each frame).
func gangway_step() -> void:
	var want := recipe != null and airlock_cell.x >= 0 and bricked and not riding and landed \
			and not piloted and ref != null
	if want and gangway == null:
		_lower_gangway()
	elif not want and gangway != null:
		gangway.queue_free()
		gangway = null
		_gang_body = null
		gangway_steps = 0


## Its own point `p` over the ground under it (the planet's heights, as it lands by).
func _over_ground(p: Vector3) -> float:
	var at := rel * p
	return at.length() - (ref.data.radius + ref.data.height(at.normalized()))


func _lower_gangway() -> void:
	gangway = Node3D.new()
	gangway.name = "Gangway"
	add_child(gangway)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var lock := airlock_cell
	if _over_ground(cell_point(lock)) < GANG_RISE * plate:
		return
	var r := BuildRecipe.new()
	r.name = "gangway"
	var colour := StationKit._colour(ShipBuild.HULL_COLOUR)
	_gang_body = StaticBody3D.new()
	_gang_body.collision_layer = Layers.STRUCTURE
	_gang_body.collision_mask = 0
	gangway.add_child(_gang_body)
	# The top step level with the deck outside the doorway: the doorway is the
	# pawn's height, no step up under it.
	for k in GANG_STEPS:
		var top := lock.y - GANG_RISE * k
		var x0 := lock.x - GANG_TREAD * (k + 1)
		for x in GANG_TREAD:
			for z in range(lock.z - 1, lock.z + 3):
				r.add("brick_1x1", Vector3i(x0 + x, top - GANG_RISE, z), colour)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(GANG_TREAD * stud, GANG_RISE * plate, 4 * stud)
		cs.shape = box
		cs.transform = frame * Transform3D(Basis(), Vector3((x0 + GANG_TREAD * 0.5) * stud,
				(top - GANG_RISE * 0.5) * plate, (lock.z + 1) * stud))
		_gang_body.add_child(cs)
		gangway_steps = k + 1
		if _over_ground(cell_point(Vector3i(x0, top, lock.z))) < GANG_RISE * plate:
			break
	var c := bricks.create_chunk(Vector3i.ZERO, r.chunk_dims())
	r.build(bricks, c, _palette)
	var merge := MeshMerge.new()
	for band in bricks.get_chunk_sections(c):
		var arrays: Array = bricks.build_chunk_mesh_section(c, band)
		if not arrays.is_empty():
			merge.add_surface(arrays, Transform3D.IDENTITY, Color(-1, 0, 0))
		var got: Array = bricks.get_chunk_studs_and_open(c, band)
		var buf: PackedFloat32Array = got[0]
		var open: PackedByteArray = got[1]
		var keep := PackedFloat32Array()
		for i in open.size():
			if open[i] != 0:
				keep.append_array(buf.slice(i * 16, i * 16 + 16))
		if not keep.is_empty():
			merge.add_instances(_stud_arrays, Transform3D.IDENTITY, keep)
	bricks.release_chunk(c)
	var out := merge.commit()
	if out.is_empty():
		return
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = brick_material
	var org := r.origin()
	mi.transform = frame * Transform3D(Basis(), Vector3(org.x * stud, org.y * plate, org.z * stud))
	gangway.add_child(mi)


## The hull swept from where it is drawn to `next` (in its reference frame):
## buildings and stations stop it. Returns where it may go.
func _sweep(ps, next: Vector3) -> Vector3:
	var to: Transform3D = ps.ship_world(self, next)
	var motion := to.origin - global_position
	if motion.length_squared() < 1e-8:
		return next
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _hull
	q.transform = global_transform * Transform3D(Basis(), Vector3(0.0, height * 0.5, 0.0))
	q.motion = motion
	q.collision_mask = Layers.STRUCTURE
	q.exclude = [shell_body.get_rid()] if _gang_body == null else [shell_body.get_rid(), _gang_body.get_rid()]
	var space := get_world_3d().direct_space_state
	var cast := space.cast_motion(q)
	if cast[0] >= 1.0 or cast[1] <= 0.0:
		# Clear, or starting inside something: not held.
		return next
	var speed := motion.length() / maxf(get_process_delta_time(), 0.001)
	q.transform.origin += motion * cast[1]
	var rest := space.get_rest_info(q)
	var at: Vector3 = rest.get("point", q.transform.origin + motion.normalized() * _hull.size.length() * 0.5)
	rams += 1
	# Stopped against it: moving as it moves, if it is a station.
	vel = ps.ship_match(self)[0]
	if speed > RAM_SPEED:
		rammed.emit(at, speed)
	return rel.origin.lerp(next, cast[0])
