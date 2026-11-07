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
##
## A generated town's garrison is sized by its buildings (Planets.md, "a generated
## town's garrison by its size"): one to three squads (`plan_for`), the first in the
## middle and the others in the streets round it, a tank and a mech in the biggest,
## and an officer holding the middle. While the officer lives a squad that has seen
## nobody is told where the player is once any squad has; the town is clear when he
## is down too. Home's waves are one squad each and have no officer.

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
## one squad is one of the mixes after the first, its own (mix_index).
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
## A generated town: a squad for each this many buildings, one to the most; a tank
## from this many buildings, a mech from this many (a 3x3 town is ~8, 6x6 ~31).
const TOWN_PER_SQUAD := 9.0
const TOWN_SQUADS_MOST := 3
const TOWN_TANK_FROM := 18
const TOWN_MECH_FROM := 26
## The other squads stand about this far from the middle, in the streets.
const STREET_RINGS := [22.0, 30.0, 38.0]
## The officer stands this far from the first squad.
const OFFICER_OFF := 3.0
## The officer's colour (as the arena's HQ officer): he can be picked out.
const OFFICER_COLOUR := Color(0.95, 0.75, 0.2)

## Gates: every town counts as this many buildings (-1: as built).
static var test_buildings := -1

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
## The first squad (null: no fight), and every squad of the fight, the first too.
var squad: Squad
var squads: Array[Squad] = []
## A generated town's officer (null: none, or a wave).
var officer: Soldier
## Every soldier raised for the fight, the officer too, dead or alive.
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
## The squads that know the player is about and go on looking (Squad -> true): from
## their first contact (or the officer's word), a wave from the start. Without it a
## squad that lost them would stand there.
var _hunts := {}
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


## Everyone of the fight still up, on foot: every squad's and the officer.
func alive() -> Array[Soldier]:
	var out: Array[Soldier] = []
	for q in squads:
		out.append_array(q.alive())
	if _officer_up():
		out.append(officer)
	return out


func _officer_up() -> bool:
	return officer != null and is_instance_valid(officer) and not officer.is_dead()


## Where they are, on the whole (their feet's mean).
func _center(who: Array[Soldier]) -> Vector3:
	var at := Vector3.ZERO
	for m in who:
		at += m.pawn.feet()
	return at / maxf(who.size(), 1)


## What a generated town of `n` buildings raises: {squads, tank, mech}.
static func plan_for(n: int) -> Dictionary:
	return {"squads": clampi(roundi(n / TOWN_PER_SQUAD), 1, TOWN_SQUADS_MOST),
			"tank": n >= TOWN_TANK_FROM, "mech": n >= TOWN_MECH_FROM}


## The world's buildings (null: not built).
func _buildings():
	return scene.buildings if body == scene.planet else scene.system.built.get(body)


## How many buildings town `i` has (8, a small town's, if its buildings are not known).
func town_buildings(i: int) -> int:
	if test_buildings >= 0:
		return test_buildings
	var pb = _buildings()
	if pb != null and i < (pb.town_sites as Array).size():
		return pb.town_sites[i]
	return 8


func _ground_under_all() -> bool:
	for m in alive():
		if scene._ground_hit(m.pawn.feet()) == Vector3.INF:
			return false
	return true


func _physics_process(delta: float) -> void:
	_look -= delta
	if _look > 0.0 or _raising:
		return
	_look = LOOK_EVERY
	# Not at a player in the seat: it drove to the ship and the ship came down on it.
	if _tank_up() and scene.on_foot and _tank_goal.distance_to(scene.pawn.feet()) > TANK_RESEND:
		_tank_goal = scene.pawn.feet()
		(tank.get_node(^"TankBrain") as TankBrain).send(_tank_goal)
	var up := alive()
	if squad != null and up.is_empty() and not _tank_up() and not _mech_up():
		print("[garrison] %s: town %d clear (wave %d)" % [body.data.planet_name, town, wave])
		squad = null
		squads.clear()
		officer = null
		if waves:
			next_wave = Time.get_ticks_msec() / 1000.0 + WAVE_BREAK
		else:
			cleared[_key(town)] = true
	if squad != null and not up.is_empty():
		var at := _center(up)
		_ground.global_position = at
		var off: float = (scene._anchor() as Vector3).distance_to(at)
		if _held and off < RELEASE_AT and _ground_under_all():
			_let_go()
		elif not _held and off > HOLD_AT:
			hold()
		if not _held:
			for m in up:
				scene.keep_over_ground(m.pawn, body)
			_command()
	var i := _town_near()
	if i >= 0 and i != town and not cleared.has(_key(i)):
		_raise(i)
	elif i >= 0 and waves and squad == null and Time.get_ticks_msec() / 1000.0 >= next_wave:
		_raise(i)


## What a save keeps of it.
func to_save() -> Dictionary:
	# Each: [planet-local feet, health, kind, its squad (-1: the officer)].
	var left := []
	if squad != null:
		for qi in squads.size():
			for m in squads[qi].alive():
				left.append([body.to_local(m.pawn.feet()), m.pawn.health.total_current(), str(m.get_meta(&"unit", &"rifleman")), qi])
		if _officer_up():
			left.append([body.to_local(officer.pawn.feet()), officer.pawn.health.total_current(), "officer", -1])
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


## The wave's tank, as the city's (MachineLoadout; CityVehicles.spawn_tank, WaveDirector._field_tank):
## a rocket gun and a machine gun, a driver and a gunner, on the vehicle map,
## screening the squad and sent at the player.
func _field_tank(s: AIServices, at: Vector3, side: Vector3, lib: GunPartLibrary, rng: RandomNumberGenerator,
		saved := []) -> void:
	var p: Vector3 = s.vehicle_nav(&"tank").snap(at - side * (SPACING * WAVE_MOST * 0.5 + 8.0)) if saved.is_empty() \
			else body.global_transform * (saved[0] as Vector3)
	var up := Gravity.up_at(p)
	var guns := MachineLoadout.tank_guns(lib, rng.randi_range(1, 9999), rng.randi_range(1, 9999))
	var to := Gravity.flat(scene.pawn.feet() - p, up)
	tank = Tank.make(s, _troops, p + up * 0.3, atan2(-to.x, -to.z), 1, guns[0], guns[1], s.on_structure_hit, s.rng)
	if not saved.is_empty():
		tank.health.apply_impact(tank.health.total_current() - float(saved[1]), &"")
	PlanetBody.track(tank)
	var target := tank.make_target()
	s.add_pawn(target)
	_tank_pawns = [target]
	var br := TankBrain.attach(s, tank)
	_tank_pawns.append_array(MachineLoadout.crew_tank(tank, func(_seat: int) -> Pawn:
		var so := Soldier.spawn(s, _troops, p + up * 0.3 + side * 5.0, 1,
				MachineLoadout.roll(lib, rng.randi_range(1, 9999), &"rifle"))
		PlanetBody.track(so.pawn.body)
		return so.pawn))
	br.escort = squad
	_tank_goal = scene.pawn.feet()
	br.send(_tank_goal)
	print("[garrison] %s: a tank with %s, %d aboard" % [body.data.planet_name, _what(), tank.crew_count()])


## Is this wave's mech still fighting?
func _mech_up() -> bool:
	return mech != null and is_instance_valid(mech) and not mech.is_dead()


## The wave's mech, as the city's (MachineLoadout; CityVehicles.spawn_enemy_mech): an LMG in its hand,
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
	MachineLoadout.arm_mech(m, lib, rng.randi_range(1, 9999))
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
	MachineLoadout.arm_launcher(mech, m, lib, func() -> int: return rng.randi_range(1, 9999), s.rng,
			s.on_structure_hit)
	print("[garrison] %s: a mech with %s, %s" % [body.data.planet_name, _what(), "piloted" if m.pilot_pawn != null else "empty"])


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
	var gear := (", a tank" if _tank_up() else "") + (", a mech" if _mech_up() else "")
	if squad != null and waves:
		return "%s: wave %d, %d left%s" % [body.data.planet_name, wave, squad.alive().size(), gear]
	if squad != null:
		return "%s: %d soldiers left%s%s" % [body.data.planet_name, alive().size(),
				", the officer" if _officer_up() else ", the officer down", gear]
	if waves and wave > 0:
		return "%s: wave %d clear, wave %d in %.0f s" % [body.data.planet_name, wave, wave + 1,
				maxf(next_wave - Time.get_ticks_msec() / 1000.0, 0.0)]
	return ""


## What this fight is, for the log.
func _what() -> String:
	return "wave %d" % wave if waves else "town %d" % town


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


## Which of WAVE_KINDS a squad is drawn from: home's by its wave; a generated
## town's by the town itself, any mix but the first -- towns differ, and each is
## the same every time it is raised.
func mix_index(i := town) -> int:
	if waves:
		return mini(wave - 1, WAVE_KINDS.size() - 1)
	return 1 + absi(hash(_key(i))) % (WAVE_KINDS.size() - 1)


func _key(i: int) -> String:
	return "%d:%d:%d" % [scene.system.system_index, scene.system.index_of(body), i]


## Give each squad the player once it knows of them: by its own contact, or, while
## the officer lives, by any squad's.
func _command() -> void:
	if scene.pawn == null:
		return
	var word := false
	if _officer_up():
		for q in squads:
			if not q.alive().is_empty() and q.contact() != null:
				word = true
	var at: Vector3 = scene.pawn.feet()
	for q in squads:
		if q.order != null or q.alive().is_empty():
			continue
		if q.contact() != null:
			_hunts[q] = true
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = at
			q.give(o)
		elif _hunts.has(q) or word:
			# ADVANCE fails at once with nobody known: they are told by ear, as any
			# soldier comes to know of what it cannot see.
			_hunts[q] = true
			(scene.ai_of[body] as AIServices).noise(at, at.distance_to(q.center()) + HEARD_PAST, scene.pawn)


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
	squads.clear()
	officer = null
	_hunts.clear()
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
	var restoring := _restoring()
	var plan := {"squads": 1, "tank": wave >= TANK_FROM, "mech": wave >= MECH_FROM} if waves \
			else plan_for(town_buildings(town))
	var net := s.nav_net as PlanetNavNet
	# Each squad: [[spot, kind, saved entry or []]]; the officer: [spot, saved entry or []].
	var groups := []
	var lead := []
	if restoring:
		for e in _left:
			var qi := int(e[3]) if (e as Array).size() > 3 else 0
			var kind := StringName(e[2]) if (e as Array).size() > 2 else &"rifleman"
			var p := body.global_transform * (e[0] as Vector3)
			if qi < 0:
				lead = [p, e]
				continue
			while groups.size() <= qi:
				groups.append([])
			groups[qi].append([p, kind, e])
	else:
		var count := mini(SQUAD_SIZE + WAVE_GROWS * (wave - 1), WAVE_MOST) if waves else SQUAD_SIZE
		var spots: Array[Vector3] = [at]
		spots.append_array(_street_spots(int(plan.squads) - 1))
		for qi in spots.size():
			# Home's by its wave; a generated town's first squad by the town itself, the
			# others the mixes after it in turn.
			var mix: Array = WAVE_KINDS[mix_index() if waves
					else 1 + (mix_index() - 1 + qi) % (WAVE_KINDS.size() - 1)]
			var c := spots[qi]
			var cup := Gravity.up_at(c)
			var cside := cup.cross(Vector3.RIGHT if absf(cup.x) < 0.9 else Vector3.FORWARD).normalized()
			var g := []
			for k in count:
				g.append([net.snap(c + cside * (k - (count - 1) * 0.5) * SPACING + cup * 0.3),
						mix[rng.randi() % mix.size()], []])
			groups.append(g)
		if not waves:
			lead = [net.snap(at + up.cross(side) * OFFICER_OFF + up * 0.3), []]
	if groups.is_empty():
		# Only the tank or the mech was left: the squad is there, and empty.
		groups.append([])
	for g in groups:
		var members: Array[Soldier] = []
		for e in g:
			members.append(_make_soldier(s, lib, rng, e[0], e[1], e[2]))
		squads.append(Squad.make(s, _troops, members, 1))
	squad = squads[0]
	if not lead.is_empty():
		_make_officer(s, lib, rng, lead[0], lead[1])
	# A saved fight brings back what it had: its tank, its mech, if they were up.
	if plan.tank and (not restoring or not _left_tank.is_empty()):
		_field_tank(s, at, side, lib, rng, _left_tank)
	if plan.mech and (not restoring or not _left_mech.is_empty()):
		_field_mech(s, at, side, lib, rng, _left_mech)
	_hunts.clear()
	if wave > 1 or restoring:
		for q in squads:
			_hunts[q] = true
	_left_tank = []
	_left_mech = []
	_left = []
	print("[garrison] %s: %d soldiers in %d squad(s)%s at %s (%d buildings) in %.1f ms" % [body.data.planet_name,
			soldiers.size() - (1 if _officer_up() else 0), squads.size(), ", an officer" if _officer_up() else "",
			_what(), town_buildings(town) if not waves else 0, (Time.get_ticks_usec() - t0) / 1000.0])


## One soldier of kind `kind` (UnitCatalog's) at `p`, as hurt as `saved` says.
func _make_soldier(s: AIServices, lib: GunPartLibrary, rng: RandomNumberGenerator, p: Vector3,
		kind: StringName, saved: Array) -> Soldier:
	var unit := UnitCatalog.get_unit(kind)
	var gun := GunInstance.from_result(GunGenerator.generate(lib, rng.randi_range(1, 9999),
			WeaponClass.builtin(StringName(unit.weapon)), 1))
	var so := Soldier.spawn(s, _troops, p + Gravity.up_at(p) * 0.1, 1, gun)
	so.set_meta(&"unit", kind)
	so.max_health = UnitCatalog.apply_health(so.pawn.health, kind, 1)
	so.set_type(str(unit.get("recipe", "")), Roster.shared())
	PlanetBody.track(so.pawn.body)
	soldiers.append(so)
	if not saved.is_empty():
		so.pawn.health.apply_impact(so.pawn.health.total_current() - float(saved[1]), &"")
	return so


## The town's officer, as the arena's HQ has one (WaveDirector._set_up_hq): a pistol,
## gold, holding where he stands -- here, by the first squad in the town's middle.
func _make_officer(s: AIServices, lib: GunPartLibrary, rng: RandomNumberGenerator, p: Vector3,
		saved: Array) -> void:
	officer = _make_soldier(s, lib, rng, p, &"officer", saved)
	var m := StandardMaterial3D.new()
	m.albedo_color = OFFICER_COLOUR
	for c in officer.pawn.body.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).material_override = m
	var hold := SquadMsg.Assignment.make(SquadMsg.Task.HOLD, officer.pawn.feet())
	hold.role = "HQ"
	officer.set_assignment(hold)


## Where a generated town's other `n` squads stand: round the middle, each in its own
## part of the ring, at the spot farthest from any of the town's buildings (a street).
func _street_spots(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if n <= 0:
		return out
	var r: float = body.data.radius
	var up := _dir.normalized()
	var e1 := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var near: Array[Vector3] = []
	var pb = _buildings()
	if pb != null:
		for st in pb.sites:
			if (st.dir as Vector3).angle_to(up) * r < 150.0:
				near.append(st.dir)
	for k in n:
		var best := up
		var best_clear := -1.0
		for ring in STREET_RINGS:
			for a in 5:
				var d: Vector3 = (up * r + e1.rotated(up, TAU * (k + 0.5) / n + (a - 2) * 0.25) * ring).normalized()
				var clear := INF
				for sd in near:
					clear = minf(clear, d.angle_to(sd) * r)
				if clear > best_clear:
					best_clear = clear
					best = d
		out.append(body.global_transform * body.data.surface_point(best))
	return out
