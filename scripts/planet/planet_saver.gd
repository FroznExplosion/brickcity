class_name PlanetSaver
extends Node

## The universe being played, kept in its UniverseSave (Docs/Planets.md, "saving").
## Reads each world's file as it comes into the system, puts what happened back
## as what it applies to is made, and writes: every EVERY seconds, on each change
## of frame, and on closing. Coming back in, the scene starts as it always does
## and `resume` then takes the player where they were, behind a dark screen, by the
## ways a player goes: out to open space, the jump, the frames' handoff.

const EVERY := 30.0
## How long the handoffs and the ground may take on the way back, milliseconds.
const WAIT := 20000
## The frame the player is in.
enum { SPACE, BODY, STATION, SHIP }

## The PlanetScene (untyped: it types this class).
var scene
var system: PlanetSystem
var save: UniverseSave
## False until the player is back where they were: nothing is written over the
## last save before that.
var live := false
var writes := 0
var write_us := 0
## What was read, for what has not been made yet.
var state := {}
## Body index -> its file, this system.
var worlds := {}
var _timer := 0.0


## The save's drifting pieces are put back once, in its system (_apply_system).
var _drifts_back := false


func setup(p_scene, p_save: UniverseSave) -> void:
	scene = p_scene
	system = p_scene.system
	save = p_save
	state = save.state()
	system.t = float(state.get("t", system.t))
	(scene.cleared as Dictionary).merge(state.get("cleared", {}), true)
	_read_worlds(int(state.get("system", 0)))
	system.anchor_changed.connect(_on_frame)
	system.populated.connect(apply_sites)
	system.jumped.connect(_on_jumped)
	if int(state.get("system", 0)) == system.system_index:
		_apply_system()
		_ship_back()


func _read_worlds(index: int) -> void:
	worlds.clear()
	for i in Universe.MOST_BODIES:
		var d := save.world(index, i)
		if not d.is_empty():
			worlds[i] = d


## What is made with the system: its stations, and the worlds already built.
func _apply_system() -> void:
	for i in worlds:
		for k in (worlds[i] as Dictionary).get("stations", {}):
			system.stations[k].restore_gone(worlds[i].stations[k])
	for b in system.built:
		apply_sites(b)
	for i in worlds:
		if i < system.bodies.size():
			system.restore_fallen(system.bodies[i], (worlds[i] as Dictionary).get("fallen", []))
	# Adrift where the save was made, once.
	if not _drifts_back and int(state.get("system", -1)) == system.system_index:
		_drifts_back = true
		system.restore_drifts(state.get("drifts", []))


func _on_jumped(_index: int) -> void:
	if live:
		_read_worlds(system.system_index)
		_apply_system()
		save.write_state(_state())


## World `b`'s buildings are made: what happened to them.
func apply_sites(b: PlanetBody) -> void:
	var d: Dictionary = worlds.get(system.index_of(b), {})
	var pb: PlanetBuildings = system.built.get(b)
	if pb == null:
		return
	for k in d.get("sites", {}):
		pb.restore_site(k, d.sites[k], false)
	for k in d.get("toppled", []):
		pb.restore_site(k, PackedInt32Array(), true)
	pb.pieces.restore(d.get("pieces", []))


## World `b`'s trees are made.
func apply_trees(b: PlanetBody, tr: PlanetTrees) -> void:
	var d: Dictionary = worlds.get(system.index_of(b), {})
	tr.restore_knocked(d.get("trees", {}))


func apply_garrison(b: PlanetBody, g: PlanetGarrison) -> void:
	var d: Dictionary = worlds.get(system.index_of(b), {})
	if d.has("garrison"):
		g.restore(d.garrison)


func _on_frame(old: Node3D, _new: Node3D, _kick: Vector3) -> void:
	if not live:
		return
	var i := -1
	if old is PlanetBody:
		i = system.index_of(old)
	elif old is SpaceStation and not old is SpaceShip:
		i = system.sys.orbitals[system.stations.find(old)].parent
	if i >= 0:
		_write_world(i)
	save.write_state(_state())


# Not on leaving the tree: the scene's children have left it by then.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_now()


func _process(delta: float) -> void:
	if not live:
		return
	_timer += delta
	if _timer >= EVERY:
		save_now()


## The universe and the world the player is on, now.
func save_now() -> void:
	if not live:
		return
	_timer = 0.0
	var t0 := Time.get_ticks_usec()
	if system.anchor != null:
		_write_world(system.index_of(system.anchor))
	if system.station != null:
		_write_world(system.sys.orbitals[system.stations.find(system.station)].parent)
	save.write_state(_state())
	write_us = Time.get_ticks_usec() - t0
	writes += 1


func _write_world(i: int) -> void:
	var b: PlanetBody = system.bodies[i]
	var d := {}
	var pb: PlanetBuildings = system.built.get(b)
	if pb != null:
		var sites := {}
		var toppled := []
		for k in pb.sites.size():
			if pb.sites[k].toppled:
				toppled.append(k)
			else:
				var gone := pb.site_gone(k)
				if not gone.is_empty():
					sites[k] = gone
		d["sites"] = sites
		d["toppled"] = toppled
		d["pieces"] = pb.pieces.to_save()
	d["fallen"] = system.fallen_to_save(b)
	var tr: PlanetTrees = scene.trees if b == scene.planet else system.trees_of.get(b)
	if tr != null:
		d["trees"] = tr.knocked()
	var g: PlanetGarrison = scene.garrisons.get(b)
	if g != null:
		d["garrison"] = g.to_save()
	var stations := {}
	for k in system.stations.size():
		if system.sys.orbitals[k].parent == i:
			var gone: PackedInt32Array = system.stations[k].gone()
			if not gone.is_empty():
				stations[k] = gone
	d["stations"] = stations
	worlds[i] = d
	save.write_world(system.system_index, i, d)


func _state() -> Dictionary:
	# On foot, its feet: resume stands the pawn there (_set_on_foot). The anchor
	# is its body's middle, and every load stood it that much higher (0.84 m).
	var at: Vector3 = scene.pawn.feet() if scene.on_foot and not scene.piloting else scene._anchor()
	var look: Vector3 = -(scene.ship.camera if scene.piloting else scene.cam).global_basis.z
	var f := system.frame_node()
	var kind := SPACE
	var index := 0
	var inv: Transform3D = system.space_to_world().affine_inverse()
	if f != null:
		inv = f.global_transform.affine_inverse()
		if f is PlanetBody:
			kind = BODY
			index = system.index_of(f)
		elif f is SpaceShip:
			kind = SHIP
		else:
			kind = STATION
			index = system.stations.find(f)
	var s: SpaceShip = scene.ship
	return {"t": system.t, "system": system.system_index, "cleared": scene.cleared,
			"kind": kind, "index": index, "at": inv * at, "look": inv.basis * look,
			"piloting": scene.piloting, "on_foot": scene.on_foot, "drifts": system.drifts_to_save(),
			"ship": {"ref": system.index_of(s.ref) if s.ref != null else -1, "rel": s.rel, "fine": s.fine,
					"vel": s.vel, "landed": s.landed, "gone": s.gone()}}


func _ship_back() -> void:
	var d: Dictionary = state.get("ship", {})
	if d.is_empty():
		return
	var s: SpaceShip = scene.ship
	s.restore_gone(d.gone)
	var i: int = d.ref
	s.ref = system.bodies[i] if i >= 0 else null
	s.rel = d.rel
	s.fine = d.fine
	s.vel = d.vel
	s.landed = d.landed


## Where the save says the player is, in the world as it stands.
func _world_point() -> Vector3:
	var at: Vector3 = state.at
	match int(state.kind):
		BODY:
			return system.space_to_world() * system.sys.xform(int(state.index), system.t) * at
		STATION:
			return system.space_to_world() * system.sys.orbital_xform(int(state.index), system.t) * at
		SHIP:
			return scene.ship.global_transform * at
	return system.space_to_world() * at


## Whether the system has the frame the save says.
func _in_frame() -> bool:
	var f := system.frame_node()
	match int(state.kind):
		BODY:
			return f == system.bodies[int(state.index)]
		STATION:
			return f == system.stations[int(state.index)]
		SHIP:
			return f == scene.ship
	return f == null


func _frames(cond: Callable) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call() and Time.get_ticks_msec() - t0 < WAIT:
		await get_tree().process_frame


## Back where the player was. The pawn is standing at the spawn.
func resume() -> void:
	if state.get("at") == null:
		live = true
		return
	scene.veil(true)
	var s: SpaceShip = scene.ship
	var there := int(state.system)
	if there != system.system_index:
		# Out to open space and across, as the ship would.
		scene.board()
		var h: int = system.index_of(scene.planet)
		var p := system.sys.pos(h, system.t)
		s.ref = null
		s.rel = Transform3D(s.rel.basis, p + p.normalized() * (scene.data.radius * PlanetSystem.SHELL * 2.0))
		s.vel = system.sys.vel(h, system.t)
		s.landed = false
		await _frames(func() -> bool: return system.frame_node() == s)
		system.jump(there)
		_read_worlds(there)
		_apply_system()
		await get_tree().process_frame
		var d: Dictionary = state.ship
		s.restore_gone(d.gone)
		var i: int = d.ref
		if i >= 0:
			# Into its planet's frame by the ordinary way in, then exactly as it was.
			s.rel = system.sys.xform(i, system.t) * (d.rel as Transform3D)
			s.vel = Vector3.ZERO
			await _frames(func() -> bool: return s.ref == system.bodies[i] and system.anchor == system.bodies[i])
		_ship_back()
	if state.piloting:
		if not scene.piloting:
			scene.board()
		await _frames(_in_frame)
	else:
		scene.step_off()
		await get_tree().process_frame
		var w = scene.walker
		w.frozen = true
		w.global_position = _world_point()
		await _frames(_in_frame)
		w.global_position = _world_point()
		w.inertia = Vector3.ZERO
		w.velocity = Vector3.ZERO
		if int(state.kind) == BODY:
			await _frames(func() -> bool: return scene._ground_hit(_world_point()) != Vector3.INF)
		var at := _world_point()
		if state.on_foot:
			scene._set_on_foot(true, at)
			scene._face(Gravity.flat(state.look, Gravity.up_at(at)).normalized())
		w.frozen = false
	print("[save] back in %s, system %d" % [save.display_name, system.system_index])
	scene.veil(false)
	live = true
