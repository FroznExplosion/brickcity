class_name PlanetGarrison
extends Node3D

## A settled world's soldiers (Docs/Planets.md 11.12 step 7): a squad at the
## middle of the town the player comes to on foot, on that world's own AI
## (PlanetScene.setup_ai). A Node3D at the top of the scene, holding its soldiers,
## so that all of it sleeps with its world as anything else there does. One town
## at a time: a nav net is good for a town and its country, so going to another
## drops this one's fight. A town wiped out stays clear, but for one with `waves`
## (home's): another, bigger squad comes in after WAVE_BREAK, from the far side of
## the town, for as long as the player stays.
##
## With the player kilometres off the ground under these bodies is coarse where it
## is there at all (it is the player's detail, a far viewer only has it streamed),
## and it is swapped under them as the player comes: they fall through it. So they
## are held, process off, while the player is far (a world wakes with them
## tens of kilometres up) and let go with the player near and ground under each.

## Metres from a town's middle at which it wakes, unless a world says otherwise.
const RAISE_AT := 250.0
const SQUAD_SIZE := 4
## Waves: each this many more than the last, up to the most; seconds between them;
## how far past the town's middle, from the player, they come in.
const WAVE_GROWS := 2
const WAVE_MOST := 8
const WAVE_BREAK := 20.0
const WAVE_FROM := 70.0
## A hunting squad hears the player from however far, and this far past its middle.
const HEARD_PAST := 15.0
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
var raise_at := RAISE_AT
## The town's squad comes back, bigger (home's).
var waves := false
## Which wave (1: the first), and when the next may come, seconds.
var wave := 0
var next_wave := 0.0
## The town the world's AI is on (-1: none yet).
var ai_town := -1
var squad: Squad
var soldiers: Array[Soldier] = []
## Holds the soldiers and the squad; off while they are held.
var _troops: Node3D
## Streams the ground where they are, whoever else is there.
var _ground: Node3D
var _held := false
## They know the player is about and go on looking: from the first contact, a wave
## from the start. Without it a squad that lost them would stand there.
var _hunting := false
## Where they are set down, planet-local.
var _dir := Vector3.UP
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
		print("[garrison] %s: town %d clear (wave %d)" % [body.data.planet_name, town, wave])
		squad = null
		if waves:
			next_wave = Time.get_ticks_msec() / 1000.0 + WAVE_BREAK
		else:
			cleared[_key(town)] = true
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
	elif i >= 0 and waves and squad == null and Time.get_ticks_msec() / 1000.0 >= next_wave:
		_raise(i)


## A line for the HUD, while there is a fight ("": none).
func status() -> String:
	if squad != null:
		return "%s: wave %d, %d left" % [body.data.planet_name, wave, squad.alive().size()] if waves \
				else "%s: %d soldiers left" % [body.data.planet_name, squad.alive().size()]
	if waves and wave > 0:
		return "%s: wave %d clear, wave %d in %.0f s" % [body.data.planet_name, wave, wave + 1,
				maxf(next_wave - Time.get_ticks_msec() / 1000.0, 0.0)]
	return ""


## The town the player stands in, on foot, or -1.
func _town_near() -> int:
	if scene.pawn == null or not scene.on_foot or scene.system.anchor != body:
		return -1
	var at: Vector3 = body.global_transform.affine_inverse() * (scene.pawn.feet() as Vector3)
	var towns := body.data.towns
	for i in towns.size():
		if at.distance_to(body.data.surface_point(towns[i])) < raise_at:
			return i
	return -1


func _key(i: int) -> String:
	return "%d:%d:%d" % [scene.system.system_index, scene.system.index_of(body), i]


## Give the squad the player once it knows of them.
func _command() -> void:
	if squad.order != null or scene.pawn == null:
		return
	if squad.contact() != null:
		_hunting = true
		var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
		o.point = scene.pawn.feet()
		squad.give(o)
	elif _hunting:
		# ADVANCE fails at once with nobody known: they are told by ear, as any
		# soldier comes to know of what it cannot see.
		var at: Vector3 = scene.pawn.feet()
		(scene.ai_of[body] as AIServices).noise(at, at.distance_to(squad.center()) + HEARD_PAST, scene.pawn)


## Drop the fight going on, if any: another town's turn.
func _drop() -> void:
	var s: AIServices = scene.ai_of.get(body)
	for so in soldiers:
		if s != null and is_instance_valid(so):
			s.pawns.erase(so.pawn)
	for c in _troops.get_children():
		c.queue_free()
	soldiers.clear()
	squad = null
	town = -1


func _raise(i: int) -> void:
	_raising = true
	var again := i == town
	_drop()
	town = i
	if ai_town != i:
		var t0 := Time.get_ticks_usec()
		scene.setup_ai(body.data.towns[i], body)
		ai_town = i
		print("[garrison] %s: town %d, its AI in %.1f ms" % [body.data.planet_name, i, (Time.get_ticks_usec() - t0) / 1000.0])
	wave = wave + 1 if again else 1
	_dir = _arrival(i)
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


## Where wave `wave` of town `i` comes in: the first stands in its middle, the rest
## arrive past it, on the far side from the player.
func _arrival(i: int) -> Vector3:
	var dir: Vector3 = body.data.towns[i]
	if wave <= 1:
		return dir
	var at := body.data.surface_point(dir)
	var from: Vector3 = body.global_transform.affine_inverse() * (scene.pawn.feet() as Vector3)
	var away := Gravity.flat(at - from, dir).normalized()
	return (at + away * WAVE_FROM).normalized()


## Where they are set down, where it is now.
func _middle() -> Vector3:
	return body.global_transform * body.data.surface_point(_dir)


func _spawn() -> void:
	var t0 := Time.get_ticks_usec()
	var s: AIServices = scene.ai_of[body]
	var at := _middle()
	var up := Gravity.up_at(at)
	var side := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var lib := GunPlaceholderParts.build_library()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_key(town))
	var count := mini(SQUAD_SIZE + WAVE_GROWS * (wave - 1), WAVE_MOST)
	var net := s.nav_net as PlanetNavNet
	for k in count:
		var p := net.snap(at + side * (k - (count - 1) * 0.5) * SPACING + up * 0.3)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"rifle"), 1))
		var so := Soldier.spawn(s, _troops, p + Gravity.up_at(p) * 0.1, 1, gun)
		PlanetBody.track(so.pawn.body)
		soldiers.append(so)
	squad = Squad.make(s, _troops, soldiers, 1)
	_hunting = wave > 1
	print("[garrison] %s: %d soldiers at town %d in %.1f ms" % [body.data.planet_name, soldiers.size(), town, (Time.get_ticks_usec() - t0) / 1000.0])
