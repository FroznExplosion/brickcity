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
## Who comes, by wave (UnitCatalog's built foot units, as the city's waves field
## them): the first all rifles, each after it a wider mix. A generated town's
## one squad is the second.
## From this wave home's waves bring a tank (UnitCatalog's built heavy armour),
## crewed, beside the squad; a wave is clear when it is wrecked too.
const TANK_FROM := 4
## From this wave a mech comes too (the roster's medium gunner), piloted.
const MECH_FROM := 5
## The tank is sent at the player again once they have moved this far.
const TANK_RESEND := 20.0
const WAVE_KINDS := [
	[&"rifleman"],
	[&"rifleman", &"rifleman", &"assault"],
	[&"rifleman", &"assault", &"breacher", &"veteran"],
	[&"rifleman", &"assault", &"breacher", &"veteran", &"marksman"],
]
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
## This wave's tank, if it brought one, and the pawns it put on the AI (its
## target, its crew), taken off again with the wave.
var tank: Tank
## This wave's mech, if it brought one (its brain).
var mech: MechBrain
var _tank_pawns: Array[Pawn] = []
var _tank_goal := Vector3.INF
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
## Who was left when it was saved: [[planet-local, health]], for when it is raised.
var _left: Array = []
## The wave's tank and mech as a save left them, [planet-local feet, health];
## empty: none (wrecked, or the wave never had one).
var _left_tank: Array = []
var _left_mech: Array = []
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
	if _tank_up() and _tank_goal.distance_to(scene.pawn.feet()) > TANK_RESEND:
		_tank_goal = scene.pawn.feet()
		(tank.get_node(^"TankBrain") as TankBrain).send(_tank_goal)
	if squad != null and squad.alive().is_empty() and not _tank_up() and not _mech_up():
		print("[garrison] %s: town %d clear (wave %d)" % [body.data.planet_name, town, wave])
		squad = null
		if waves:
			next_wave = Time.get_ticks_msec() / 1000.0 + WAVE_BREAK
		else:
			cleared[_key(town)] = true
	if squad != null and not squad.alive().is_empty():
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


## What a save keeps of it.
func to_save() -> Dictionary:
	var left := []
	if squad != null:
		for m in squad.alive():
			left.append([body.to_local(m.pawn.feet()), m.pawn.health.total_current(), str(m.get_meta(&"unit", &"rifleman"))])
	return {"town": town, "wave": wave, "left": left, "ai_town": ai_town,
			"tank": [body.to_local(tank.feet()), tank.health.total_current()] if _tank_up() else [],
			"mech": [body.to_local(mech.mech.feet()), mech.mech.health.total_current()] if _mech_up() else [],
			"next_in": maxf(next_wave - Time.get_ticks_msec() / 1000.0, 0.0)}


## As a save left it: those left come back when it is raised again.
func restore(d: Dictionary) -> void:
	wave = d.wave
	_left = d.left
	_left_tank = d.get("tank", [])
	_left_mech = d.get("mech", [])
	town = -1 if _restoring() else int(d.town)
	next_wave = Time.get_ticks_msec() / 1000.0 + float(d.next_in)


## Is a wave a save left to come back (soldiers, its tank or its mech)?
func _restoring() -> bool:
	return not _left.is_empty() or not _left_tank.is_empty() or not _left_mech.is_empty()


## Is this wave's tank still fighting?
func _tank_up() -> bool:
	return tank != null and is_instance_valid(tank) and not tank.is_wrecked()


## The wave's tank, as the city's (CityScene._spawn_tank, WaveDirector._field_tank):
## a rocket gun and a machine gun, a driver and a gunner, on the vehicle map,
## screening the squad and sent at the player.
func _field_tank(s: AIServices, at: Vector3, side: Vector3, lib: GunPartLibrary, rng: RandomNumberGenerator,
		saved := []) -> void:
	var p: Vector3 = s.vehicle_nav(&"tank").snap(at - side * (SPACING * WAVE_MOST * 0.5 + 8.0)) if saved.is_empty() \
			else body.global_transform * (saved[0] as Vector3)
	var up := Gravity.up_at(p)
	var main := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"lmg"), 1))
	var to := Gravity.flat(scene.pawn.feet() - p, up)
	tank = Tank.make(s, _troops, p + up * 0.3, atan2(-to.x, -to.z), 1, main, mg, s.on_structure_hit, s.rng)
	if not saved.is_empty():
		tank.health.apply_impact(tank.health.total_current() - float(saved[1]), &"")
	PlanetBody.track(tank)
	var target := tank.make_target()
	s.add_pawn(target)
	_tank_pawns = [target]
	var br := TankBrain.attach(s, tank)
	for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
		var so := Soldier.spawn(s, _troops, p + up * 0.3 + side * 5.0, 1,
				GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"rifle"), 1)))
		PlanetBody.track(so.pawn.body)
		tank.board(so.pawn, seat, true)
		_tank_pawns.append(so.pawn)
	br.escort = squad
	_tank_goal = scene.pawn.feet()
	br.send(_tank_goal)
	print("[garrison] %s: a tank with wave %d, %d aboard" % [body.data.planet_name, wave, tank.crew_count()])


## Is this wave's mech still fighting?
func _mech_up() -> bool:
	return mech != null and is_instance_valid(mech) and not mech.is_dead()


## The wave's mech, as the city's (CityScene._spawn_enemy_mech): an LMG in its hand,
## a launcher for walls, the enemy tree, the roster's medium gunner, a pilot inside;
## on the nav net's mech map, on the other side of the squad from the tank. It
## knows where the player is as its side does (the squad's contact, or by ear).
func _field_mech(s: AIServices, at: Vector3, side: Vector3, lib: GunPartLibrary, rng: RandomNumberGenerator,
		saved := []) -> void:
	var nav = s.mech_map()
	var p := _mech_spot(nav, at + side * (SPACING * WAVE_MOST * 0.5 + 10.0) if saved.is_empty()
			else body.global_transform * (saved[0] as Vector3))
	var up := Gravity.up_at(p)
	var to := Gravity.flat(scene.pawn.feet() - p, up)
	var m := Mech.spawn(_troops, p + up * 0.2, atan2(-to.x, -to.z), 1)
	PlanetBody.track(m.body)
	var gi := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"lmg"), 1))
	gi.visible = false
	m.arm.add_child(gi)
	m.gun.equip(gi)
	m.gun.rng = s.rng
	m.gun.on_structure_hit = s.on_structure_hit
	mech = MechBrain.attach(s, m, nav, MechTree.enemy(), 1)
	m.set_type("medium_gunner", Roster.shared())
	if not saved.is_empty():
		m.health.apply_impact(m.health.total_current() - float(saved[1]), &"")
	_tank_pawns.append(m.make_target())
	var pilot := Soldier.spawn(s, _troops, p + up * 0.3, 1,
			GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999), WeaponClass.builtin(&"rifle"), 1)))
	PlanetBody.track(pilot.pawn.body)
	m.mount(pilot.pawn, true)
	_tank_pawns.append(pilot.pawn)
	if not m.no_gun:
		mech.arm_launcher(GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999),
				WeaponClass.builtin(&"rocket_launcher"), 1)), s.rng, s.on_structure_hit)
	print("[garrison] %s: a mech with wave %d, %s" % [body.data.planet_name, wave, "piloted" if m.pilot_pawn != null else "empty"])


## Where a mech can stand near `want`, on its map: out from it in rings. Snap
## alone left one on a spot it could not stand on, and every path from there
## failed: it stood where it was put for the whole wave.
func _mech_spot(nav, want: Vector3) -> Vector3:
	if nav == null:
		return want
	var up := Gravity.up_at(want)
	var ahead := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	for r in [0.0, 6.0, 12.0, 20.0, 30.0]:
		for k in (1 if r == 0.0 else 8):
			var p: Vector3 = nav.snap(want + ahead.rotated(up, TAU * k / 8.0) * r)
			if nav.can_stand(p):
				return p
	return nav.snap(want)


## A line for the HUD, while there is a fight ("": none).
func status() -> String:
	if squad != null:
		return "%s: wave %d, %d left%s" % [body.data.planet_name, wave, squad.alive().size(), (", a tank" if _tank_up() else "") + (", a mech" if _mech_up() else "")] if waves \
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
	for p in _tank_pawns:
		if s != null and is_instance_valid(p):
			s.pawns.erase(p)
	_tank_pawns.clear()
	tank = null
	mech = null
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
	if not _restoring():
		wave = wave + 1 if again else 1
		_dir = _arrival(i)
	else:
		var first: Vector3 = _left[0][0] if not _left.is_empty() else (_left_tank[0] if not _left_tank.is_empty() else _left_mech[0])
		_dir = first.normalized()
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
	# The nav there, on a worker: it is dropped behind the player, and _spawn's
	# snap would make it on its own frame (100+ ms).
	var net := scene.ai_of[body].nav_net as PlanetNavNet
	while not net.region_made(_middle()) and Time.get_ticks_msec() - waited < GROUND_WAIT:
		await get_tree().process_frame
		if not is_inside_tree() or scene.system.anchor != body:
			town = -1
			_raising = false
			return
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
	var lib: GunPartLibrary = scene.kit.arsenal.library
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_key(town))
	var count := mini(SQUAD_SIZE + WAVE_GROWS * (wave - 1), WAVE_MOST)
	var restoring := _restoring()
	if restoring:
		count = _left.size()
	var net := s.nav_net as PlanetNavNet
	var mix: Array = WAVE_KINDS[mini(wave - 1 if waves else 1, WAVE_KINDS.size() - 1)]
	for k in count:
		var p := net.snap(at + side * (k - (count - 1) * 0.5) * SPACING + up * 0.3)
		var kind: StringName = mix[rng.randi() % mix.size()]
		if not _left.is_empty():
			p = body.global_transform * (_left[k][0] as Vector3)
			kind = StringName(_left[k][2]) if (_left[k] as Array).size() > 2 else &"rifleman"
		var unit := UnitCatalog.get_unit(kind)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999),
				WeaponClass.builtin(StringName(unit.weapon)), 1))
		var so := Soldier.spawn(s, _troops, p + Gravity.up_at(p) * 0.1, 1, gun)
		so.set_meta(&"unit", kind)
		so.max_health = UnitCatalog.apply_health(so.pawn.health, kind, 1)
		so.set_type(str(unit.get("recipe", "")), Roster.shared())
		PlanetBody.track(so.pawn.body)
		soldiers.append(so)
		if not _left.is_empty():
			so.pawn.health.apply_impact(so.pawn.health.total_current() - float(_left[k][1]), &"")
	squad = Squad.make(s, _troops, soldiers, 1)
	# A saved wave brings back what it had: its tank, its mech, if they were up.
	if waves and wave >= TANK_FROM and (not restoring or not _left_tank.is_empty()):
		_field_tank(s, at, side, lib, rng, _left_tank)
	if waves and wave >= MECH_FROM and (not restoring or not _left_mech.is_empty()):
		_field_mech(s, at, side, lib, rng, _left_mech)
	_hunting = wave > 1 or restoring
	_left_tank = []
	_left_mech = []
	_left = []
	print("[garrison] %s: %d soldiers at town %d in %.1f ms" % [body.data.planet_name, soldiers.size(), town, (Time.get_ticks_usec() - t0) / 1000.0])
