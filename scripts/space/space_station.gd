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
## Hits (step 3b): the host's commands, the bands to draw again, the structure
## to ask, and the dead ids kept while its bricks are freed.
var damage_log := DamageLog.new()
var crumbs: PlanetCrumbs
var bricks_killed := 0
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
	bricks.set_chunk_anchored(chunk, true)
	bricks.set_tension_per_stud(chunk, BrickStrength.tension())
	bricks.set_chunk_section_plates(chunk, SECTION_PLATES)
	bricks.set_chunk_section_studs(chunk, SECTION_STUDS)
	bricks.set_chunk_transform(chunk, global_transform * frame)
	_brick_node = Node3D.new()
	_brick_node.name = "Bricks"
	_brick_node.transform = frame
	add_child(_brick_node)
	crumbs = PlanetCrumbs.new()
	add_child(crumbs)
	crumbs.setup(gravity_centre)
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
	if not bricked or riding or not holds(point):
		return false
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


## World `p` is inside its module's box.
func holds(p: Vector3) -> bool:
	var stud := BrickWorld.get_stud_metres()
	var l := (global_transform * frame).affine_inverse() * p
	return l.x > -0.5 and l.z > -0.5 and l.y > -0.5 and l.x < data.fx * stud + 0.5 \
			and l.z < data.fz * stud + 0.5 and l.y < height + 0.5


func _after_kill(killed: PackedInt32Array) -> void:
	bricks_killed += killed.size()
	_collision.disable(killed)
	for b in _collision.bands_of(killed):
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
		if ids.size() <= DRIFT_MIN:
			crumbs.throw(bricks, chunk, ids)
			bricks.kill_blocks(chunk, ids)
			continue
		var split: Dictionary = bricks.split_island(chunk, ids)
		if split.is_empty():
			continue
		var c := int(split.chunk)
		var arrays: Array = bricks.build_chunk_mesh(c)
		var com: Vector3 = split.local_com
		drifted.emit(arrays, bricks.get_chunk_transform(c) * Transform3D(Basis(), com), com, ids.size(), brick_material)
		bricks.release_chunk(c)
	_after_kill(all)
	if not joints.is_empty():
		_joints_step()


func _damage_step() -> void:
	if _solve_due:
		_solve()
	if _collision.any_stale():
		_collision.flush(2)
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
		if not riding:
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
	var ship := data.kind == "ship"
	var made := ShipBuild.make(data.orbital_seed) if ship else RoomStation.generate(StationKit.library(),
			{"seed": data.orbital_seed, "modules": 12 + data.orbital_seed % 12, "spine": 3 + data.orbital_seed % 3,
			"section_bricks": SECTION_BRICKS})
	grow_ms = (Time.get_ticks_usec() - t0) / 1000.0
	if not bool(made.ok):
		push_warning("[station] %s: %s -- a tower instead" % [data.orbital_name, made.why])
		data.layout = "tower"
		prepare()
		return
	recipe = made.recipe
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
	var split: Dictionary = bricks.split_island(chunk, off)
	if split.is_empty():
		return
	var c := int(split.chunk)
	var arrays: Array = bricks.build_chunk_mesh(c)
	var com: Vector3 = split.local_com
	drifted.emit(arrays, bricks.get_chunk_transform(c) * Transform3D(Basis(), com), com, off.size(), brick_material)
	bricks.release_chunk(c)
	_after_kill(off)


func _exit_tree() -> void:
	for job in _band_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_band_jobs.clear()
	if _collision != null:
		_collision.free_bodies()
		_collision = null
