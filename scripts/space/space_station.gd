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
## A generated station's sections (BuildSections): its far shell a box round each.
const SECTION_BRICKS := 2000
## A loose group over this many bricks leaves whole, as a drifting piece
## (Planets.md 11.12 step 6); smaller, crumbs.
const DRIFT_MIN := 20
## Its gravity's boxes grown this much past its bricks, m: a jump off its roof
## (the pawn's held jump clears four bricks, 1.7 m) still comes back down on it.
const FIELD_GROW := 2.0

## A loose group left: its mesh `arrays`, drawn from `local_com` back; the world
## transform of its centre of mass; how many bricks.
signal drifted(arrays: Array, com: Transform3D, local_com: Vector3, count: int, material: Material)

var data: OrbitalData
## Inside this of its node the player is on it (a ship's is smaller).
var field := FIELD
var look: Node3D
## Damaged, its far look: the bands it last drew, in place of its whole shell.
var wreck: Node3D
## Laying its bricks only to leave `wreck` (lay_wreck).
var _wreck_only := false
var gravity_centre: Node3D
## Its generator's field (Gravity.Field; Docs/RoomModules.md 7.12), made once.
var _field: Gravity.Field
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
## Flown with its bricks drawn (a generated ship piloted over a planet, where it
## moves in the planet's frame): its meshes ride along as its children, its brick
## collision (world-placed) is put away and its shell box stands in, nothing
## damaged. `ride` / `unride`.
var riding := false
## Who stood on the piece being sent off (`drifted`), and a body of its bricks
## for them to stand on: the drift handler takes both (PlanetSystem), else the
## body is freed once the signal is out.
var drift_riders: Array = []
## The piece being sent off, as its bricks (ChunkRecord.to_data), for a save:
## PlanetSystem takes it with the riders.
var drift_record := {}
var drift_body := RID()
## How far under a figure's origin its floor is looked for, plates.
const RIDE_DROP := 16
## A generated one's doors and lifts (its recipe's meta), hung once its bricks
## are solid, following its chunk (Docs/RoomModules.md 7.3).
var doors: BuildDoors = null
var lifts: BuildLifts = null
## Hits (step 3b): the host's commands, the bands to draw again, the structure
## to ask, and the dead ids kept while its bricks are freed.
var damage_log := DamageLog.new()
var crumbs: PlanetCrumbs
var bricks_killed := 0
## Bricks brought back by repair (Docs/Hulls.md 9).
var bricks_restored := 0
## Water inside it (Docs/Hulls.md 5, HullWater): every ship's, a spaceship's too --
## parked in a planet's sea, a hole under the surface floods it.
var hull_water: HullWater
## Where the water outside stands: world point -> metres under its surface
## (below 0: over it; NAN: none -- space, dry land). Set by whoever knows the
## water: a Boat its sea, PlanetSystem a planet's for a ship on it. Unset: none.
var water_depth := Callable()
var water_mesh: MeshInstance3D
var _water_clock := 0.0
## The water's ticks a second, and its drawing's.
const WATER_HZ := 20.0
## Its ghost hull (Docs/Hulls.md 7b): its brick collision standing still in
## `ghosts`' space, at `ghost_slot`, for whoever walks it while it moves. Built
## once, when its bricks are first in; edited by damage and repair; never by a
## turn, a ride or an origin shift. `ghosts` is set by whoever owns the space.
## A GhostHulls -- untyped: it names SpaceStation, and two class_name scripts
## typing each other leak and crash the quit.
var ghosts = null
var ghost: BuildingCollision = null
var ghost_slot := Transform3D()
var ghost_builds := 0
## Last frame's ghost_to_real and how long ago, for the deck's velocity.
var _g2r_prev := Transform3D()
var _g2r_last := Transform3D()
var _g2r_dt := 0.0
var _band_nodes := {}
var _remesh := PackedInt32Array()
var _solve_due := false
var _dead := PackedInt32Array()
var _stud_arrays: Array = []
var _template := -1
var lay_ms := 0.0
var template_ms := 0.0
## A generated station's module (data.layout "generated"): the grown build, and
## how long growing it took.
var recipe: BuildRecipe
var grow_ms := 0.0
## A generated ship's (ShipBuild): the pilot's cell, the decks' floor rows (its
## anchors, chunk rows), and its bulkheads as joints: [{a, b, ids, n}] -- the
## bricks of sections a and b that meet there, how many when whole.
var seat_cell := Vector3i(-1, -1, -1)
## A generated ship's airlock doorway, its low cell (RoomPack), if it has one.
var airlock_cell := Vector3i(-1, -1, -1)
var deck_rows := PackedInt32Array()
var joints := []
var _cut := {}
## The air inside a generated one (Docs/Hulls.md 2-4): baked once from its recipe,
## followed through every hit, let out through the holes.
var air: HullAir
## The pressure outside, atmospheres: 0 in space (1 parked on a world with air).
var outside_pressure := 0.0
## A joint holds while this share of its bricks is left (Docs/Space.md 3.2).
const JOINT_HOLD := 0.35


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
	if d.kind == "station" and d.layout != "generated":
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


## Its own gravity pulls (Docs/RoomModules.md 7.12): a working station or ship --
## not a satellite, not a wreck -- with its generator on.
func pulls() -> bool:
	return is_station() and data.gravity_on and data.gravity > 0.0 and wreck == null


## Its generator on or off.
func set_gravity(on: bool) -> void:
	data.gravity_on = on
	print("[station] %s: gravity generator %s" % [data.orbital_name, "on" if on else "off"])


## Its field: its gravity inside its boxes -- a box round each section of a
## generated one (BuildSections), its module's box for a tower's -- grown by
## FIELD_GROW, so standing on its floor, its roof or in a doorway, or jumping
## off its roof, is in it.
## Null while it does not pull.
func gravity_field() -> Gravity.Field:
	if not pulls() or gravity_centre == null:
		return null
	if _field == null:
		_field = Gravity.Field.new()
		_field.space = self
		_field.centre = gravity_centre
		_field.radius = DEPTH
	if _field.boxes.is_empty() or _field.local != frame:
		_field.local = frame
		_field.boxes.clear()
		var cell := Vector3(BrickWorld.get_stud_metres(), BrickWorld.get_plate_metres(), BrickWorld.get_stud_metres())
		if recipe != null and recipe.meta.has("sections"):
			var org := recipe.origin()
			for s: Dictionary in recipe.meta.sections.sections:
				var lo := Vector3(BuildRecipe.cell_from(s.lo) - org) * cell
				var hi := Vector3(BuildRecipe.cell_from(s.hi) - org + Vector3i.ONE) * cell
				_field.boxes.append(AABB(lo, hi - lo).grow(FIELD_GROW))
		else:
			_field.boxes.append(AABB(Vector3.ZERO, Vector3(data.fx * cell.x, height, data.fz * cell.z)).grow(FIELD_GROW))
	_field.pull = data.gravity
	return _field


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
	if data.layout == "generated":
		_prepare_generated()
		template_ms = (Time.get_ticks_usec() - t0) / 1000.0
		return
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
	_wreck_only = false
	if not is_station() or chunk >= 0:
		return
	prepare()
	var t0 := Time.get_ticks_usec()
	chunk = bricks.create_chunk(Vector3i.ZERO, recipe.chunk_dims() if recipe != null
			else TowerRecipe.chunk_dims(data.fx, data.fz, data.courses))
	bricks.load_template(_template, chunk)
	if recipe != null:
		# Its keel (a ship's floor) is its foundation; a ship's decks hold too.
		bricks.set_foundation_level(chunk, 0)
		if not deck_rows.is_empty():
			bricks.set_anchor_levels(chunk, deck_rows)
	# As it was left.
	if not _dead.is_empty():
		bricks.kill_blocks(chunk, _dead)
		if air != null:
			air.blocks_removed(bricks, chunk, _dead)
	if ghost != null:
		# Laid again: its ghost, kept, follows the new chunk (the same block ids,
		# from the same template, so what it has switched off still holds).
		ghost.chunk = chunk
		ghost.world = bricks
	bricks.set_chunk_anchored(chunk, true)
	bricks.set_tension_per_stud(chunk, BrickStrength.tension())
	bricks.set_chunk_section_plates(chunk, SECTION_PLATES)
	bricks.set_chunk_section_studs(chunk, SECTION_STUDS)
	bricks.set_chunk_transform(chunk, global_transform * frame)
	_brick_node = Node3D.new()
	_brick_node.name = "Bricks"
	_brick_node.transform = frame
	add_child(_brick_node)
	if recipe != null:
		var src := func() -> Array:
			return [[0, chunk, recipe, recipe.origin()]] if bricked and chunk >= 0 else []
		doors = BuildDoors.new(bricks, src)
		# Its doors are its own (its children, in its frame): they turn and fly with
		# it, and have twins in its ghost for the crew walking that.
		doors.follow_parent = true
		doors.local_frame = frame
		if ghost != null or (ghosts != null and recipe != null):
			doors.ghost_space = ghosts.space
			doors.ghost_frame = ghosts.slot_of(self) * frame
		doors.figures = _crew_points
		add_child(doors)
		lifts = BuildLifts.new(bricks, src)
		add_child(lifts)
		# Its ladders to climb (Ladder), in its bricks' frame.
		Ladder.place(_brick_node, recipe)
	crumbs = PlanetCrumbs.new()
	add_child(crumbs)
	crumbs.setup(gravity_centre)
	if air != null:
		# Crumbs inside drawn out of a hole with the air (Docs/Hulls.md 4).
		crumbs.wind = func(p: Vector3) -> Vector3:
			return air_at(p, true).get("pull", Vector3.ZERO)
	_band_next = 0
	bricks.bake_chunk_async(chunk)
	lay_ms = (Time.get_ticks_usec() - t0) / 1000.0
	print("[station] %s: %d bricks laid in %.1f ms (its template built in %.1f ms, before)" % [
			data.orbital_name, bricks.get_alive_block_count(chunk), lay_ms, template_ms])


func deactivate() -> void:
	if chunk < 0:
		return
	riding = false
	for job in _band_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_band_jobs.clear()
	if _collision != null:
		_collision.free_bodies()
		_collision = null
	# Its ghost stays (Docs/Hulls.md 7b: built once, for the ship's life): a crew on
	# it goes on standing on it while its bricks are put away; laid again, it
	# follows the new chunk (activate).
	# Thrown as crumbs or gone as pieces, all gone from what is laid next.
	_dead = bricks.get_dead_blocks(chunk)
	_dead.append_array(bricks.get_detached_blocks(chunk))
	if _brick_node != null:
		if bricked and not _dead.is_empty():
			_drop_wreck()
			wreck = _brick_node
			wreck.reparent(look, false)
		else:
			_brick_node.queue_free()
		_brick_node = null
	if crumbs != null:
		crumbs.queue_free()
		crumbs = null
	for n in [doors, lifts]:
		if n != null:
			n.queue_free()
	doors = null
	lifts = null
	_band_nodes.clear()
	_remesh = PackedInt32Array()
	_solve_due = false
	bricks.release_chunk(chunk)
	chunk = -1
	bricked = false
	shell.visible = wreck == null
	shell_body.collision_layer = Layers.STRUCTURE


## The bricks it has lost.
func gone() -> PackedInt32Array:
	if chunk < 0:
		return _dead
	var out := bricks.get_dead_blocks(chunk)
	out.append_array(bricks.get_detached_blocks(chunk))
	return out


func _drop_wreck() -> void:
	if wreck != null:
		wreck.queue_free()
		wreck = null


## A save's damage, never laid this run: its bricks laid once, for `wreck`.
func lay_wreck() -> void:
	if _dead.is_empty() or wreck != null or chunk >= 0 or not can_process():
		return
	activate()
	_wreck_only = true


## As a save left it, before its bricks are laid.
func restore_gone(ids: PackedInt32Array) -> void:
	_dead = ids


## Flown over a planet: its bricks stay drawn, moving with it; their collision
## (world-placed, it would stay behind) put away, its shell box's back.
func ride() -> void:
	if riding or not bricked:
		return
	riding = true
	if _collision != null:
		_collision.free_bodies()
		_collision = null
	shell_body.collision_layer = Layers.STRUCTURE


## Stopped riding: its bricks' transform where it now is, their collision back.
func unride() -> void:
	if not riding:
		return
	riding = false
	bricks.set_chunk_transform(chunk, global_transform * frame)
	_collision = BuildingCollision.new(bricks, chunk, get_world_3d().space, global_transform * frame, true)
	shell_body.collision_layer = 0


## The floating origin moved it: its bricks' transform and collision follow.
func on_origin_shift() -> void:
	if chunk < 0:
		return
	bricks.set_chunk_transform(chunk, global_transform * frame)
	if _collision != null:
		_collision.free_bodies()
		_collision = BuildingCollision.new(bricks, chunk, get_world_3d().space, global_transform * frame, true)


## A round or a blast at world `point` (StructuralDamage.for_shot's record), as
## a planet building's bricks take one. False if its bricks are not there.
func damage(point: Vector3, shot: Dictionary) -> bool:
	# Riding too: its ghost is its bricks' collision then (Docs/Hulls.md 7b), and a
	# ray reaches its bricks through it (ShipRays).
	if not bricked or not holds(point) or (riding and ghost == null):
		return false
	if riding:
		bricks.set_chunk_transform(chunk, global_transform * frame)
	var blast := bool(shot.get("blast", false))
	var radius := float(shot.get("radius", 0.0))
	var e := damage_log.record(0, DamageLog.Kind.BLAST if blast else DamageLog.Kind.CHIP, chunk,
			point, radius, Vector3.ZERO, int(shot.get("hp", 0)))
	var killed := DamageLog.apply_entry(bricks, chunk, e)
	if killed.is_empty():
		return true
	crumbs.throw(bricks, chunk, killed, Vector3.ZERO, point, radius * IslandManager.BLAST_CORE if blast else 0.0)
	_after_kill(killed)
	return true


## Repair (Docs/Hulls.md 9, the core): the bricks it has lost -- destroyed, or gone
## on a piece -- within `radius` metres of world `point`. With `edge_first`, the
## ones beside a brick that is there come first (a hole closes from its rim
## inward, so a breach seals soonest), nearest `point` first within each. Only a
## generated one (its recipe and air know every brick); empty while its bricks
## are not laid.
func restorable(point: Vector3, radius: float, edge_first := true) -> PackedInt32Array:
	if not bricked or (riding and ghost == null) or chunk < 0 or recipe == null or air == null:
		return PackedInt32Array()
	var here := cell_at(point)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var rim: Array = []
	var inner: Array = []
	for b in gone():
		var cells := air._block_cells(b)
		if cells.is_empty():
			continue
		var mid := Vector3.ZERO
		for i in cells:
			mid += Vector3(air._cell(i))
		mid = mid / float(cells.size()) + Vector3(0.5, 0.5, 0.5)
		var d := Vector3((mid.x - here.x) * stud, (mid.y - here.y) * plate, (mid.z - here.z) * stud).length()
		if d > radius:
			continue
		var edge := false
		if edge_first:
			var own := {}
			for i in cells:
				own[i] = true
			for i in cells:
				for j in air._neighbours(i):
					if air.state[j] == HullAir.SOLID and not own.has(j):
						edge = true
						break
				if edge:
					break
		(rim if edge or not edge_first else inner).append([d, b])
	rim.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	inner.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	var out := PackedInt32Array()
	for e in rim + inner:
		out.append(int(e[1]))
	return out


## Lay `ids` back as built (Docs/Hulls.md 9): a RESTORE command, recorded and applied
## as a hit is, then what follows a brick's return -- its air sealed, its shapes
## and bands back. `point` and `radius` are where, for the record. Refused while
## its bricks are not laid, and while it flies over a world (`riding`: a hit is
## refused then too -- its bricks' collision is put away; the ghost hull, step 6,
## is what lets a crew work on it in flight). Returns the bricks brought back.
func restore(ids: PackedInt32Array, point := Vector3.ZERO, radius := 0.0) -> PackedInt32Array:
	if not bricked or (riding and ghost == null) or chunk < 0 or ids.is_empty():
		return PackedInt32Array()
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.RESTORE
	e.target = 0
	e.point = point
	e.radius = radius
	e.blocks = ids
	damage_log.add(e)
	var back := DamageLog.apply_entry(bricks, chunk, e)
	if not back.is_empty():
		_after_restore(back)
	return back


func _after_restore(back: PackedInt32Array) -> void:
	bricks_restored += back.size()
	if air != null:
		air.blocks_added(bricks, chunk, back)
	if hull_water != null:
		hull_water.grid_changed = true
	if ghost != null:
		ghost.enable(back)
	if _collision != null:
		_collision.enable(back)
	for b in _bands_of(back):
		if not _remesh.has(b):
			_remesh.append(b)
	bricks.bake_chunk_async(chunk)


## World `p` is inside its module's box.
func holds(p: Vector3) -> bool:
	var stud := BrickWorld.get_stud_metres()
	var l := (global_transform * frame).affine_inverse() * p
	return l.x > -0.5 and l.z > -0.5 and l.y > -0.5 and l.x < data.fx * stud + 0.5 \
			and l.z < data.fz * stud + 0.5 and l.y < height + 0.5


## A ram's blow on its own hull at `point` (world; PlanetScene._on_rammed): as
## `damage`, but taken whatever its bricks are doing. Riding with no ghost (no
## round can reach them then, but what it flew into still hits), on the chunk as
## it is; not laid at all, on the bricks it would lay, briefly, so that what dies
## is in what it keeps (`_dead`). Returns the bricks killed.
func take_ram(point: Vector3, shot: Dictionary) -> int:
	if chunk >= 0:
		if not bricked:
			return 0
		if riding:
			bricks.set_chunk_transform(chunk, global_transform * frame)
		var radius := float(shot.get("radius", 0.0))
		var e := damage_log.record(0, DamageLog.Kind.BLAST, chunk, point, radius, Vector3.ZERO, 0)
		var killed := DamageLog.apply_entry(bricks, chunk, e)
		if not killed.is_empty():
			crumbs.throw(bricks, chunk, killed, Vector3.ZERO, point, radius * IslandManager.BLAST_CORE)
			_after_kill(killed)
		return killed.size()
	prepare()
	if _template < 0:
		return 0
	var c := bricks.create_chunk(Vector3i.ZERO, recipe.chunk_dims() if recipe != null
			else TowerRecipe.chunk_dims(data.fx, data.fz, data.courses))
	bricks.load_template(_template, c)
	if not _dead.is_empty():
		bricks.kill_blocks(c, _dead)
	bricks.set_chunk_transform(c, global_transform * frame)
	var hit := bricks.apply_hit(c, point, float(shot.get("radius", 0.0)))
	if not hit.is_empty():
		_dead = bricks.get_dead_blocks(c)
		_dead.append_array(bricks.get_detached_blocks(c))
		bricks_killed += hit.size()
		if ghost != null:
			ghost.disable(hit)
	bricks.release_chunk(c)
	return hit.size()


func _after_kill(killed: PackedInt32Array) -> void:
	bricks_killed += killed.size()
	if air != null:
		air.blocks_removed(bricks, chunk, killed)
	if hull_water != null:
		hull_water.grid_changed = true
	if _collision != null:
		_collision.disable(killed)
	if ghost != null:
		ghost.disable(killed)
	for b in _bands_of(killed):
		if not _remesh.has(b):
			_remesh.append(b)
	bricks.bake_chunk_async(chunk)
	_solve_due = true


## What the hit left joined to nothing goes: a small group as crumbs, a large
## one as a rigid piece, drifting (step 6).
func _solve() -> void:
	_solve_due = false
	# A generated station: by its studs alone (in orbit nothing weighs on it --
	# Docs/Space.md 3.2), so a part cut off from the keel's comes away whole.
	var groups: Array = bricks.find_detached_groups(chunk) if recipe != null \
			else (bricks.solve_structure(chunk, 48, 3.0).groups as Array)
	if groups.is_empty():
		if not joints.is_empty():
			_joints_step()
		return
	var all := PackedInt32Array()
	for g in groups:
		var ids: PackedInt32Array = g
		all.append_array(ids)
		# Flown with crew on its ghost (Docs/Hulls.md 7b), a group come loose INSIDE
		# its hull stays in it: as crumbs, which ride with the ship (its frame),
		# never as a piece drifting off through the wall.
		if ids.size() <= DRIFT_MIN or (riding and _inside_hull(ids)):
			crumbs.throw(bricks, chunk, ids)
			bricks.kill_blocks(chunk, ids)
			continue
		var riders := _riders(ids)
		var split: Dictionary = bricks.split_island(chunk, ids)
		if split.is_empty():
			continue
		_send_off(split, ids.size(), riders)
	_after_kill(all)
	if not joints.is_empty():
		_joints_step()


func _damage_step() -> void:
	if _solve_due:
		_solve()
	if _collision != null and _collision.any_stale():
		_collision.flush(2)
	if ghost != null and ghost.any_stale():
		ghost.flush(2)
	if not _remesh.is_empty():
		if not bricks.bake_ready(chunk):
			if not bricks.bake_pending(chunk):
				bricks.bake_chunk_async(chunk)
			return
		_harvest()
		for b in _remesh:
			_draw_band(b)
		_remesh = PackedInt32Array()
	elif not _band_jobs.is_empty():
		_harvest()


func _process(_delta: float) -> void:
	if chunk < 0:
		return
	if bricked:
		# The ship has moved for this frame already (PlanetSystem flies it first).
		_g2r_prev = _g2r_last
		_g2r_last = ghost_to_real()
		_g2r_dt = _delta
		_air_step(_delta)
		_water_step(_delta)
		if riding:
			# Its doors and lifts follow its chunk; flown, the chunk follows it.
			bricks.set_chunk_transform(chunk, global_transform * frame)
		_damage_step()
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
		bricked = true
		if _wreck_only:
			_wreck_only = false
			deactivate()
			return
		_collision = BuildingCollision.new(bricks, chunk, get_world_3d().space, global_transform * frame, true)
		_build_ghost()
		_drop_wreck()
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
			# Every brick of the band gone: its vertices are still baked, no triangle is.
			if out.is_empty() or (out[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
				return
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, IslandManager.UPLOAD_COMPRESS)
			holder[0] = m, false, "station band")
	_band_jobs.append([task, holder, band])


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
		var band: int = job[2]
		if _brick_node == null:
			continue
		# A band drawn again (a hit) replaces the one it was.
		var old: Node = _band_nodes.get(band)
		if old != null:
			old.queue_free()
			_band_nodes.erase(band)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = brick_material
		_brick_node.add_child(mi)
		_band_nodes[band] = mi


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


# --- a generated station (Docs/RoomModules.md 7.3) ------------------------------

## Grown from the station kit by its seed (~0.2 s, so here, ahead of arrival, not
## at load), its template built; its box, its shell and its frame made to fit.
func _prepare_generated() -> void:
	var t0 := Time.get_ticks_usec()
	# A boat (Docs/Hulls.md 7) is laid as a ship is: a build, its bow its nose.
	var ship := data.kind == "ship" or data.kind == "boat"
	var made := BoatBuild.make(data.orbital_seed) if data.kind == "boat" \
			else ShipBuild.make(data.orbital_seed) if ship else RoomStation.generate(StationKit.library(),
			{"seed": data.orbital_seed, "modules": 12 + data.orbital_seed % 12, "spine": 3 + data.orbital_seed % 3,
			"section_bricks": SECTION_BRICKS})
	grow_ms = (Time.get_ticks_usec() - t0) / 1000.0
	if not bool(made.ok):
		push_warning("[station] %s: %s -- a tower instead" % [data.orbital_name, made.why])
		data.layout = "tower"
		prepare()
		return
	recipe = made.recipe
	if not ship:
		var lib := StationKit.library()
		if StationKit.is_kit(lib):
			made.stats["band"] = StationKit.paint_band(recipe, data.orbital_seed)
		made.stats["furniture"] = KitFurnish.furnish(recipe, data.orbital_seed)
	var size: Vector3i = recipe.bounds()[1]
	data.fx = size.x
	data.fz = size.z
	var stud := BrickWorld.get_stud_metres()
	height = size.y * BrickWorld.get_plate_metres()
	frame = Transform3D(Basis(), Vector3(-size.x * stud * 0.5, 0.0, -size.z * stud * 0.5))
	if ship:
		# Its bow (+X in the build) is the ship's nose (-Z).
		var turn := Basis(Vector3.UP, PI * 0.5)
		frame = Transform3D(turn, turn * Vector3(-size.x * stud * 0.5, 0.0, -size.z * stud * 0.5))
		var org := recipe.origin()
		seat_cell = (made.seat as Vector3i) - org if (made.seat as Vector3i).x >= 0 else Vector3i(size.x / 2, 1, size.z / 2)
		var lock: Vector3i = made.stats.get("airlock", Vector3i(-1, -1, -1))
		airlock_cell = lock - org if lock.x >= 0 else lock
		deck_rows = PackedInt32Array()
		for s in range(1, int(made.decks)):
			deck_rows.append(s * ShipBuild.PITCH)
		_joints_of()
	var c := bricks.create_chunk(Vector3i.ZERO, recipe.chunk_dims())
	recipe.build(bricks, c, _palette)
	air = HullAir.bake(bricks, c, recipe)
	print("[station] %s: %d cells of air in %d room(s), baked in %.0f ms" % [data.orbital_name,
			air.inside_cells(), air.compartments().size(), air.bake_ms])
	_template = bricks.save_template(c)
	bricks.release_chunk(c)
	_generated_shell()
	print("[station] %s grown: %d modules, %d bricks, %d section(s) in %.0f ms" % [data.orbital_name,
			int(made.stats.modules), recipe.size(), (recipe.meta.sections.sections as Array).size(), grow_ms])


## Its shell from afar and its boxes until its bricks are solid: a box round each
## section (BuildSections), in place of the tower's.
func _generated_shell() -> void:
	var cell := Vector3(BrickWorld.get_stud_metres(), BrickWorld.get_plate_metres(), BrickWorld.get_stud_metres())
	var org := recipe.origin()
	var boxes := []
	for s: Dictionary in recipe.meta.sections.sections:
		var lo := Vector3(BuildRecipe.cell_from(s.lo) - org) * cell
		var hi := Vector3(BuildRecipe.cell_from(s.hi) - org + Vector3i.ONE) * cell
		boxes.append(AABB(lo, hi - lo))
	var im := ArrayMesh.new()
	for b: AABB in boxes:
		var bm := BoxMesh.new()
		bm.size = b.size
		var arrays := bm.get_mesh_arrays()
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in v.size():
			v[i] += b.get_center()
		arrays[Mesh.ARRAY_VERTEX] = v
		im.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = data.colour
	shell.mesh = im
	shell.material_override = mat
	shell.transform = frame
	for n in shell_body.get_children():
		n.queue_free()
	for b: AABB in boxes:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = b.size
		cs.shape = shape
		cs.position = b.get_center()
		shell_body.add_child(cs)
	shell_body.transform = frame


## The air's tick: its doors as they stand (an open one links two rooms, the airlock
## open is a hole), then out through the holes.
func _air_step(dt: float) -> void:
	if air == null:
		return
	if doors != null:
		var st := doors.open_states(0)
		for i in mini(st.size(), air.doors.size()):
			air.set_door(i, bool(st[i]))
	air.step(dt, outside_pressure)


## Cells next to one, nearest first, then up (what lies on a floor is under its air).
const _NEAR := [Vector3i(0, 1, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
		Vector3i(1, 1, 0), Vector3i(-1, 1, 0), Vector3i(0, 1, 1), Vector3i(0, 1, -1), Vector3i(0, 2, 0),
		Vector3i(1, 0, 1), Vector3i(-1, 0, 1), Vector3i(1, 0, -1), Vector3i(-1, 0, -1), Vector3i(0, -1, 0)]


## The air at world point `p` (Docs/Hulls.md 4): {pressure (atmospheres), pull (the
## rush toward a hole, world m/s^2), breached, venting (air going out now)}; empty
## where `p` is not in its air.
## `near`: a point in a brick or on its face (a crumb lying by a wall, feet on a floor)
## takes the air of a cell next to it.
func air_at(p: Vector3, near := false) -> Dictionary:
	if air == null or chunk < 0 or not bricked or not holds(p):
		return {}
	var c := cell_at(p)
	var at := Vector3i(c.floor())
	var ci := air.compartment_at(at)
	if ci < 0 and near:
		for o in _NEAR:
			ci = air.compartment_at(at + o)
			if ci >= 0:
				c = Vector3(at + o) + Vector3(0.5, 0.5, 0.5)
				break
	if ci < 0:
		return {}
	var pull := air.pull_at(c, BrickWorld.get_cell_size())
	return {"pressure": air.pressure(ci), "pull": (global_transform * frame).basis * pull,
			"breached": air.is_breached(ci), "venting": air.vent_rate(ci) > 0.001}


## Build cell `c`'s bottom middle, in its own space (a generated one's).
func cell_point(c: Vector3i) -> Vector3:
	var stud := BrickWorld.get_stud_metres()
	return frame * Vector3((c.x + 0.5) * stud, c.y * BrickWorld.get_plate_metres(), (c.z + 0.5) * stud)


## World point `p` in build cells (fractional): the inverse of cell_point's frame.
func cell_at(p: Vector3) -> Vector3:
	var l := (global_transform * frame).affine_inverse() * p
	var stud := BrickWorld.get_stud_metres()
	return Vector3(l.x / stud, l.y / BrickWorld.get_plate_metres(), l.z / stud)


## A ship's bulkheads as joints: where the bricks of two sections touch.
func _joints_of() -> void:
	joints = []
	var of := BuildSections.of_build(recipe)
	if of.is_empty():
		return
	var at := {}
	for i in recipe.size():
		var c := recipe.cell_of(i)
		var sz := BuildRecipe.part_size(recipe.part_of(i))
		for y in sz.y:
			for z in sz.z:
				for x in sz.x:
					at[c + Vector3i(x, y, z)] = i
	var by := {}
	for c: Vector3i in at:
		var i: int = at[c]
		for d in [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]:
			var n: int = at.get(c + d, -1)
			if n < 0 or of[n] == of[i]:
				continue
			var key := Vector2i(mini(of[i], of[n]), maxi(of[i], of[n]))
			if not by.has(key):
				by[key] = {}
			by[key][i] = true
			by[key][n] = true
	for k: Vector2i in by:
		var ids := PackedInt32Array((by[k] as Dictionary).keys())
		joints.append({"a": k.x, "b": k.y, "ids": ids, "n": ids.size()})


## After a hit's solve, a ship's joints: one with under JOINT_HOLD of its bricks
## left is broken, and what no unbroken joint joins to the root section (the
## bridge's) leaves whole, drifting, as a loose group does.
func _joints_step() -> void:
	if joints.is_empty():
		return
	var gone := {}
	for b in bricks.get_dead_blocks(chunk):
		gone[b] = true
	for b in bricks.get_detached_blocks(chunk):
		gone[b] = true
	var adj := {}
	for j: Dictionary in joints:
		var left := 0
		for b in j.ids:
			if not gone.has(b):
				left += 1
		if float(left) < float(j.n) * JOINT_HOLD:
			continue
		for pair in [[j.a, j.b], [j.b, j.a]]:
			if not adj.has(pair[0]):
				adj[pair[0]] = []
			adj[pair[0]].append(pair[1])
	var held := {0: true}
	var todo := [0]
	while not todo.is_empty():
		var s: int = todo.pop_back()
		for t in adj.get(s, []):
			if not held.has(t):
				held[t] = true
				todo.append(t)
	var of := BuildSections.of_build(recipe)
	var off := PackedInt32Array()
	var sections := {}
	for i in of.size():
		if not held.has(of[i]) and not _cut.has(of[i]) and not gone.has(i):
			off.append(i)
			sections[of[i]] = true
	if off.is_empty():
		return
	for s in sections:
		_cut[s] = true
	var riders := _riders(off)
	var split: Dictionary = bricks.split_island(chunk, off)
	if split.is_empty():
		return
	_send_off(split, off.size(), riders)
	_after_kill(off)


## A piece split off (`split_island`'s) sent drifting: its mesh, and when
## anyone stood on it, a body of its bricks round its centre of mass that they
## ride on (PlanetSystem moves it with the piece).
func _send_off(split: Dictionary, count: int, riders: Array) -> void:
	var c := int(split.chunk)
	var arrays: Array = bricks.build_chunk_mesh(c)
	var com: Vector3 = split.local_com
	drift_riders = riders
	if not riders.is_empty():
		drift_body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(drift_body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(drift_body, Layers.STRUCTURE)
		PhysicsServer3D.body_set_collision_mask(drift_body, Layers.STRUCTURE_MASK)
		bricks.add_chunk_shapes(drift_body, c, com, true, true)
	drift_record = ChunkRecord.capture(bricks, c).to_data(bricks)
	drifted.emit(arrays, bricks.get_chunk_transform(c) * Transform3D(Basis(), com), com, count, brick_material)
	drift_record = {}
	if drift_body.is_valid():
		PhysicsServer3D.free_rid(drift_body)
	drift_body = RID()
	drift_riders = []
	bricks.release_chunk(c)


## The figures (any CharacterBody3D near it) whose floor is a brick among `ids`:
## the first brick under each, within RIDE_DROP plates.
func _riders(ids: PackedInt32Array) -> Array:
	var on := {}
	for i in ids:
		on[i] = true
	var out := []
	var inv := bricks.get_chunk_transform(chunk).affine_inverse()
	var cs := BrickWorld.get_cell_size()
	for n in get_tree().root.find_children("*", "CharacterBody3D", true, false):
		var b := n as CharacterBody3D
		if (b.global_position - global_position).length() > field:
			continue
		var l := inv * b.global_position
		var c := Vector3i(floori(l.x / cs.x), floori(l.y / cs.y), floori(l.z / cs.z))
		for k in RIDE_DROP:
			var id := bricks.block_at(chunk, c - Vector3i(0, k, 0))
			if id >= 0:
				if on.has(id):
					out.append(b)
				break
	return out


func _exit_tree() -> void:
	for job in _band_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_band_jobs.clear()
	if _collision != null:
		_collision.free_bodies()
		_collision = null


## Its ghost goes with it, and only then: a reparent (a planet asleep, a jump)
## leaves and enters the tree, and the ghost is what must not notice.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_free_ghost()


# --- the ghost hull (Docs/Hulls.md 7b) ----------------------------------------

func _build_ghost() -> void:
	if ghosts == null or recipe == null or ghost != null or chunk < 0:
		return
	ghost_slot = ghosts.slot_of(self)
	ghost = BuildingCollision.new(bricks, chunk, ghosts.space, ghost_slot * frame, true)
	ghost_builds += 1
	_g2r_prev = ghost_to_real()
	_g2r_last = _g2r_prev
	_g2r_dt = 0.0


func _free_ghost() -> void:
	if ghost != null:
		ghost.free_bodies()
		ghost = null
	if ghosts != null:
		ghosts.release(self)


## Its ghost switched off (a planet it is parked on gone to sleep, Docs/Hulls.md 7b)
## or back on: its bodies out of the ghost space and back, nothing rebuilt.
var ghost_on := true


func ghost_switch(on: bool) -> void:
	if ghost == null or on == ghost_on:
		return
	ghost_on = on
	for b in ghost.bodies:
		PhysicsServer3D.body_set_space(b, ghosts.space if on else RID())


## Where whoever walks its ghost really is (world points): a door opens for them.
func _crew_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	if ghost == null or not is_inside_tree():
		return out
	var g2r := ghost_to_real()
	for n in get_tree().get_nodes_in_group(GhostHulls.CREW):
		if n is Node3D and n.get_meta(&"ghosted", null) == self:
			out.append(g2r * (n as Node3D).global_position)
	return out


## Ghost-space points to the world, now: the real ship's transform over its slot.
func ghost_to_real() -> Transform3D:
	return global_transform * ghost_slot.affine_inverse()


## Its gravity pulls aboard (generator on): who walks its ghost falls toward its
## decks; off, they float.
func ghost_pulls() -> bool:
	return gravity_field() != null


## Up on its ghost's decks (its bricks' frame in the slot).
func ghost_up() -> Vector3:
	return (ghost_slot * frame).basis.y.normalized()


## Ghost point `g` held fixed on the real ship: its velocity in the world, m/s,
## over the last frame (its flight and its turn both).
func deck_velocity(g: Vector3) -> Vector3:
	if _g2r_dt <= 0.0:
		return Vector3.ZERO
	return (_g2r_last * g - _g2r_prev * g) / _g2r_dt


## No cell of these blocks borders the outside: they are inside its hull.
func _inside_hull(ids: PackedInt32Array) -> bool:
	if air == null:
		return false
	for b in ids:
		for i in air._block_cells(b):
			for j in air._neighbours(i):
				if air.state[j] == HullAir.OUTSIDE:
					return false
	return true


## Its bricks' bands these blocks are in (BuildingCollision.bands_of, without one).
func _bands_of(ids: PackedInt32Array) -> PackedInt32Array:
	if _collision != null:
		return _collision.bands_of(ids)
	var out := PackedInt32Array()
	for si in bricks.get_block_sections(chunk, ids, true):
		if si >= 0 and not out.has(si):
			out.append(si)
	return out


# --- water inside (Docs/Hulls.md 5, 8) -----------------------------------------

func _water_step(dt: float) -> void:
	if air == null:
		return
	_water_clock += dt
	if _water_clock < 1.0 / WATER_HZ:
		return
	var t := _water_clock
	_water_clock = 0.0
	if hull_water == null:
		if not water_depth.is_valid():
			return
		hull_water = HullWater.on(air)
	if not water_depth.is_valid() and not hull_water.any():
		return
	hull_water.step(t, water_down(), _hole_depth)
	if hull_water.changed:
		_draw_water()


## Its down in its grid's axes: its own gravity's (its frame's -Y) while it pulls,
## else the world's where it is, turned into its frame.
func water_down() -> Vector3:
	if pulls():
		return Vector3.DOWN
	var b := (global_transform * frame).basis.orthonormalized()
	return (b.inverse() * Gravity.down_at(global_position)).normalized()


## A hole cell's depth under the outside water (HullWater's depth_at).
func _hole_depth(i: int) -> float:
	if not water_depth.is_valid():
		return NAN
	var c := air._cell(i)
	var p := global_transform * (cell_point(c) + frame.basis * Vector3(0.0, BrickWorld.get_plate_metres() * 0.5, 0.0))
	return float(water_depth.call(p))


## The water in it drawn (Docs/Hulls.md 8): a top on each column of wet cells at its
## level, stepped by plate, and sides toward dry inside cells -- in its bricks'
## frame, so it rides with it.
func _draw_water() -> void:
	if _brick_node == null:
		return
	if water_mesh == null:
		water_mesh = MeshInstance3D.new()
		water_mesh.name = "Water"
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.16, 0.42, 0.62, 0.72)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		water_mesh.material_override = m
		water_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_brick_node.add_child(water_mesh)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var v := PackedVector3Array()
	var dims := air.dims
	var sy := dims.x
	for i: int in hull_water.wet:
		var w := hull_water.level(i)
		if w < 0.02:
			continue
		var c := air._cell(i)
		var x0 := c.x * stud
		var z0 := c.z * stud
		var y0 := c.y * plate
		var y1 := y0 + w * plate
		var above := i + sy
		if c.y + 1 >= dims.y or hull_water.level(above) < 0.02:
			v.append_array([Vector3(x0, y1, z0), Vector3(x0 + stud, y1, z0), Vector3(x0 + stud, y1, z0 + stud),
					Vector3(x0, y1, z0), Vector3(x0 + stud, y1, z0 + stud), Vector3(x0, y1, z0 + stud)])
		for e: Array in [[Vector3i(1, 0, 0), x0 + stud, true], [Vector3i(-1, 0, 0), x0, true],
				[Vector3i(0, 0, 1), z0 + stud, false], [Vector3i(0, 0, -1), z0, false]]:
			var nc: Vector3i = c + (e[0] as Vector3i)
			if not air._in(nc):
				continue
			var ni := air._idx(nc)
			if not hull_water.passable(ni) or hull_water.level(ni) >= w - 0.02:
				continue
			var at: float = e[1]
			if bool(e[2]):
				v.append_array([Vector3(at, y0, z0), Vector3(at, y1, z0), Vector3(at, y1, z0 + stud),
						Vector3(at, y0, z0), Vector3(at, y1, z0 + stud), Vector3(at, y0, z0 + stud)])
			else:
				v.append_array([Vector3(x0, y0, at), Vector3(x0, y1, at), Vector3(x0 + stud, y1, at),
						Vector3(x0, y0, at), Vector3(x0 + stud, y1, at), Vector3(x0 + stud, y0, at)])
	if v.is_empty():
		water_mesh.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	water_mesh.mesh = mesh


## Water pumped out of it, `cells` a second (HullWater.pump): its crew's pumps.
func pump(dt: float, cells: float) -> float:
	return hull_water.pump(dt, cells) if hull_water != null else 0.0


## Where the segment `from` -> `to` (world) is inside its module's box (holds'):
## (t in, t out) as shares of the segment, in > out when it misses.
func box_span(from: Vector3, to: Vector3) -> Vector2:
	var stud := BrickWorld.get_stud_metres()
	var inv := (global_transform * frame).affine_inverse()
	var a := inv * from
	var d := inv * to - a
	var lo := Vector3(-0.5, -0.5, -0.5)
	var hi := Vector3(data.fx * stud + 0.5, height + 0.5, data.fz * stud + 0.5)
	var t0 := 0.0
	var t1 := 1.0
	for k in 3:
		if absf(d[k]) < 1e-9:
			if a[k] < lo[k] or a[k] > hi[k]:
				return Vector2(1.0, 0.0)
			continue
		var u := (lo[k] - a[k]) / d[k]
		var v := (hi[k] - a[k]) / d[k]
		t0 = maxf(t0, minf(u, v))
		t1 = minf(t1, maxf(u, v))
	return Vector2(t0, t1)


## Ghost point `g` is inside its module's box (holds, in the ghost).
func ghost_holds(g: Vector3) -> bool:
	return holds(ghost_to_real() * g)
