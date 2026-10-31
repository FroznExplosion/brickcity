class_name PlanetGarrison
extends Node3D

## A settled world's soldiers (Docs/Planets.md 11.12 step 7): a squad at the
## middle of the town the player comes to on foot, on that world's own AI
## (PlanetScene.setup_ai). A Node3D at the top of the scene, holding its soldiers,
## so that all of it sleeps with its world as anything else there does. One town
## at a time: a nav net is good for a town and its country, so going to another
## drops this one's fight. A town wiped out stays clear.
##
## With the player kilometres off the ground under these bodies is coarse where it
## is there at all (it is the player's detail, a far viewer only has it streamed),
## and it is swapped under them as the player comes: they fall through it. So they
## are held, process off, while the player is far (a world wakes with them
## tens of kilometres up) and let go with the player near and ground under each.

## Metres from a town's middle at which it wakes.
const RAISE_AT := 250.0
const SQUAD_SIZE := 4
## Metres between soldiers as they are set down.
const SPACING := 1.4
## How long to wait for the ground under them, milliseconds.
const GROUND_WAIT := 30000
const LOOK_EVERY := 0.5
## Metres of ground kept round them.
const GROUND_RADIUS := 128
## The player nearer than this lets them go; further than HOLD_AT holds them.
const RELEASE_AT := 200.0
const HOLD_AT := 400.0

## The PlanetScene (untyped: a class cycle crashes the quit).
var scene
var body: PlanetBody
## "system:body:town" of each town cleared (the scene's, kept across jumps).
var cleared: Dictionary
## The town being fought over, an index in the world's towns (-1: none).
var town := -1
var squad: Squad
var soldiers: Array[Soldier] = []
## Holds the soldiers and the squad; off while they are held.
var _troops: Node3D
## Streams the ground where they are, whoever else is there.
var _ground: Node3D
var _held := false
var _look := 0.0
var _raising := false


func setup(p_scene, p_body: PlanetBody, p_cleared: Dictionary) -> void:
	scene = p_scene
	body = p_body
	cleared = p_cleared
	_troops = Node3D.new()
	_troops.name = "Troops"
	add_child(_troops)
	_ground = Node3D.new()
	_ground.name = "Ground"
	add_child(_ground)
	PlanetBody.track(_ground, GROUND_RADIUS)


## Nobody moves.
func hold() -> void:
	_held = true
	_troops.process_mode = Node.PROCESS_MODE_DISABLED


func _let_go() -> void:
	_held = false
	_troops.process_mode = Node.PROCESS_MODE_INHERIT


func _ground_under_all() -> bool:
	for m in squad.alive():
		if scene._ground_hit(m.pawn.feet()) == Vector3.INF:
			return false
	return true


func _physics_process(delta: float) -> void:
	_look -= delta
	if _look > 0.0 or _raising:
		return
	_look = LOOK_EVERY
	if squad != null and squad.alive().is_empty():
		cleared[_key(town)] = true
		print("[garrison] %s: town %d clear" % [body.data.planet_name, town])
		squad = null
	if squad != null:
		var at := squad.center()
		_ground.global_position = at
		var off: float = (scene._anchor() as Vector3).distance_to(at)
		if _held and off < RELEASE_AT and _ground_under_all():
			_let_go()
		elif not _held and off > HOLD_AT:
			hold()
		if not _held:
			for m in squad.alive():
				scene.keep_over_ground(m.pawn, body)
			_command()
	var i := _town_near()
	if i >= 0 and i != town and not cleared.has(_key(i)):
		_raise(i)


## The town the player stands in, on foot, or -1.
func _town_near() -> int:
	if not scene.on_foot or scene.system.anchor != body:
		return -1
	var at: Vector3 = body.global_transform.affine_inverse() * (scene.pawn.feet() as Vector3)
	var towns := body.data.towns
	for i in towns.size():
		if at.distance_to(body.data.surface_point(towns[i])) < RAISE_AT:
			return i
	return -1


func _key(i: int) -> String:
	return "%d:%d:%d" % [scene.system.system_index, scene.system.index_of(body), i]


## Give the squad the player once it knows of them.
func _command() -> void:
	if squad.order == null and squad.contact() != null and scene.pawn != null:
		var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
		o.point = scene.pawn.feet()
		squad.give(o)


## Drop the fight going on, if any: another town's turn.
func _drop() -> void:
	for c in _troops.get_children():
		c.queue_free()
	soldiers.clear()
	squad = null
	town = -1


func _raise(i: int) -> void:
	_raising = true
	_drop()
	town = i
	var t0 := Time.get_ticks_usec()
	scene.setup_ai(body.data.towns[i], body)
	print("[garrison] %s: town %d, its AI in %.1f ms" % [body.data.planet_name, i, (Time.get_ticks_usec() - t0) / 1000.0])
	# The ground's colliders where they are set down, first.
	_ground.global_position = _middle()
	var waited := Time.get_ticks_msec()
	while scene._ground_hit(_middle()) == Vector3.INF and Time.get_ticks_msec() - waited < GROUND_WAIT:
		await get_tree().create_timer(0.2).timeout
		if not is_inside_tree() or scene.system.anchor != body:
			# Left before it was ready: it starts over on the way back.
			town = -1
			_raising = false
			return
		_ground.global_position = _middle()
	_spawn()
	_raising = false


## The town's middle, where it stands now.
func _middle() -> Vector3:
	return body.global_transform * body.data.surface_point(body.data.towns[town])


func _spawn() -> void:
	var t0 := Time.get_ticks_usec()
	var s: AIServices = scene.ai
	var at := _middle()
	var up := Gravity.up_at(at)
	var side := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var lib := GunPlaceholderParts.build_library()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_key(town))
	for k in SQUAD_SIZE:
		var p := s.ai_nav.snap(at + side * (k - 1.5) * SPACING + up * 0.3)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"rifle"), 1))
		var so := Soldier.spawn(s, _troops, p + Gravity.up_at(p) * 0.1, 1, gun)
		PlanetBody.track(so.pawn.body)
		soldiers.append(so)
	squad = Squad.make(s, _troops, soldiers, 1)
	print("[garrison] %s: %d soldiers at town %d in %.1f ms" % [body.data.planet_name, soldiers.size(), town, (Time.get_ticks_usec() - t0) / 1000.0])
