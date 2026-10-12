class_name FirefightDirector
extends WaveDirector
## Firefight (scenes/firefight.tscn), after Halo's: the player in a ring of the
## terrain city walled in by an energy barrier, and wave after wave of soldiers
## dropped in at its edge.
##
## The shape of a game: a SET is ROUNDS_PER_SET rounds, a ROUND is
## WAVES_PER_ROUND waves, and the last wave of a round is its heavy one. Each
## round brings tougher kinds (ROUND_KINDS); each set raises the fight's level
## (WaveDirector.level -- what the soldiers' defences and the loot are rolled
## at) and the score multiplier. It does not end: the game is how far you get.
##
## LIVES are a pool: a death costs one and puts the player back in after
## PLAYER_RESPAWN, at the spot in the ring farthest from the soldiers; a round
## cleared gives LIVES_PER_ROUND back. Down with none left is game over, and
## after GAME_OVER_SECONDS it starts again from the first wave.
##
## The soldiers are the arena's (WaveDirector._spawn_at: weapon, health, aim, a
## squad under the commander), but the commander here only gives orders -- it
## buys nothing; what comes is the wave table's. A wave comes in squads of up
## to Commander.SQUAD_SIZE at a drop zone away from the player, as many at once
## as ALIVE_CAP allows, and every squad is told roughly where the player is.
##
## ARMOUR comes with the later waves (_wave_armour): a squad by TRUCK from round
## 2, a TANK with the heavy waves from round 2, and a MECH with round 3's heavy
## wave -- more of all of it from the second set. Trucks and tanks drive in from
## out past the barrier (it stops walkers, not vehicles: their masks leave out
## the fixture layer); a mech, which the barrier would stop, is dropped in at a
## drop zone. A wave is not over while its armour is still up, or a truck still
## has its squad aboard. `-- --ff-armour` puts one of each on every wave.
##
## YOUR MECH is called in, Titanfall's way: the MECH meter fills over time
## (MECH_FILL_SECONDS) and faster with kills (MECH_PER_POINT of a kill's points);
## full, M on foot (where there is no hatch to climb into) calls it down where
## you aim. A beacon stands there MECH_BEACON seconds, then it lands -- crushing
## any soldier under it -- and M at its hatch boards it. One at a time: the meter
## fills again only once it is destroyed.
##
## Keys (developer mode): F8 ends the wave now, F7 the spawn survey overlay.
##
## `-- --gate` is the scripted check (run_firefight_gate).

## The ring: its radius, and the barrier's height over the ground.
const RING_RADIUS := 28.0
const BARRIER_HEIGHT := 14.0
const BARRIER_SEGMENTS := 48
## A player found this far outside the ring (over the barrier off a roof) is
## put back in; a soldier, dropped -- it has left the fight.
const OUTSIDE_GRACE := 3.0
const SOLDIER_OUTSIDE := 8.0
## Drop zones: this share of the radius out, in DROP_TURNS directions.
const DROP_IN := 0.55
const DROP_OUT := 0.85
const DROP_TURNS := 16
## ...and no nearer the player than this, if any is that far.
const DROP_FROM_PLAYER := 14.0
## Seconds before the first wave, between waves, and between rounds.
const INTRO_SECONDS := 6.0
const WAVE_BREAK := 5.0
const ROUND_BREAK := 12.0
const GAME_OVER_SECONDS := 10.0
## A squad lands, then the next may this long after.
const SQUAD_GAP := 2.0
const WAVES_PER_ROUND := 5
const ROUNDS_PER_SET := 3
const LIVES_START := 7
const LIVES_PER_ROUND := 2
## What each round draws from (UnitCatalog kinds), and its heavy last wave.
const ROUND_KINDS := [
	[&"rifleman", &"rifleman", &"assault"],
	[&"rifleman", &"assault", &"breacher", &"veteran"],
	[&"assault", &"breacher", &"veteran", &"marksman"],
]
const HEAVY_KINDS := [&"veteran", &"breacher", &"veteran", &"marksman"]
## Score: a kill is its points times this, times the set's multiplier.
const KILL_SCORE := 100.0
const WAVE_BONUS := 250
const ROUND_BONUS := 1000
const SET_BONUS := 5000
## The mech meter: full in this long on its own; each point of a kill adds this.
const MECH_FILL_SECONDS := 150.0
const MECH_PER_POINT := 0.03
## The meter at the start of a game: full, so the first mech is there from the
## first wave (a restart fills it again).
const MECH_START := 1.0
## Seconds the beacon stands before the mech lands, and how near it crushes.
const MECH_BEACON := 4.0
const MECH_CRUSH := 3.5
## A truck that has not let its squad out by now does so where it is.
const TRUCK_PATIENCE := 60.0

enum Phase { INTRO, WAVE, BREAK, GAME_OVER }

var centre := Vector3.ZERO
var phase := Phase.INTRO
## 0-based: the set, the round in it, and the wave in that round.
var set_index := 0
var round_index := 0
var wave_in_round := 0
var lives := LIVES_START
var score := 0
var deaths := 0
## Soldiers this wave still to come, all told (the squads not yet landed).
var wave_left := 0
var drop_zones: Array[Vector3] = []
## This wave's armour: trucks still carrying their squad, tanks, enemy mechs.
var wave_trucks: Array[TransportTruck] = []
var wave_tanks: Array[Tank] = []
var wave_mechs: Array[MechBrain] = []
## What armour this wave still has to field once its first squad is down.
var _armour_due := {}
var _truck_sent_at := {}
## The player's mech meter, 0..1, and the call on its way down (INF: none).
var mech_meter := MECH_START
var mech_calls := 0
var _beacon_at := Vector3.INF
var _beacon_until := 0.0
var _beacon: MeshInstance3D
var _said_ready := false
## Tanks fielded on a delay, not yet out: the wave waits on them too.
var _tanks_pending := 0
var barrier: Node3D
var _phase_until := 0.0
var _next_squad := 0.0
var _banner: Label
var _banner_left := 0.0
## What wave_in_round / round_index advance to when the break is over.
var _after_break := Callable()


func setup(p_city: Node3D) -> void:
	super(p_city)
	_rng.seed = 0xF1EF1
	# Orders only: what comes is the wave table's, not the commander's budget.
	commander.spawner = Callable()
	commander.support_spawner = Callable()
	commander.can_truck = false
	_banner = Label.new()
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.offset_top = 120.0
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 40)
	_banner.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0))
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 8)
	_label.get_parent().add_child(_banner)
	_label.add_theme_font_size_override("font_size", 20)


## Pick the ring, hold its buildings as bricks, wall it in and put the player
## in the middle.
func begin() -> void:
	if city.ai_services.world3d == null:
		city.ai_services.world3d = city.get_world_3d()
		city.ai_services.on_structure_hit = city._gun.on_structure_hit
	focus = _pick_focus(Vector3.ZERO, -1)
	if focus < 0:
		push_warning("[firefight] no building to fight round")
		return
	centre = _street_of(focus)
	_start = centre
	var reach := RING_RADIUS + ZONE_MARGIN * 0.5
	_encounter = city.start_encounter(AABB(centre - Vector3(reach, 30.0, reach),
			Vector3(reach * 2.0, 120.0, reach * 2.0)))
	city._promote(focus, false)
	_breach(focus)
	city.camera.global_position = centre + Vector3.UP * 3.0
	city.camera.look_at(city._world_box(city.registry.get_building(focus)).get_center(), Vector3.UP)
	var guard := 0
	while guard < 600 and (not _encounter.is_ready() or not _ground_under(centre)):
		await get_tree().physics_frame
		guard += 1
	for i in 10:
		await get_tree().physics_frame
	_build_barrier()
	city._gun_class = city.GUN_CLASSES.find(&"rifle")
	city._equip_gun(&"rifle", city._combat_rng.randi())
	city._enter_pawn(centre + Vector3.UP * 0.3)
	listener = city.ai_services.callouts.listen(city.camera, PLAYER_TEAM, _player())
	callout_hud = CalloutHud.new()
	callout_hud.name = "Callouts"
	callout_hud.setup(city.ai_services.callouts, listener)
	add_child(callout_hud)
	_player().health.died.connect(_on_player_died)
	commander.setup(city.ai_services, ENEMY_TEAM)
	commander.rally = centre
	commander.players_at = func() -> Array:
		var p := _player()
		return [p.feet()] if p != null else []
	_find_drop_zones()
	_ready_to_fight = true
	_enter_intro()
	print("[firefight] ring of %.0f m round %v (building %d), %d drop zone(s)" % [
		RING_RADIUS, centre, focus, drop_zones.size()])


# --- the ring ---------------------------------------------------------------------

## The barrier: a ring of thin walls on the fixture layer -- walkers meet it,
## nothing that falls does -- and a faint glow to see it by.
func _build_barrier() -> void:
	barrier = Node3D.new()
	barrier.name = "FirefightBarrier"
	city.add_child(barrier)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.35, 0.75, 1.0, 0.10)
	var edge := mat.duplicate() as StandardMaterial3D
	edge.albedo_color = Color(0.45, 0.85, 1.0, 0.55)
	var seg_len := TAU * RING_RADIUS / float(BARRIER_SEGMENTS) + 0.3
	for i in BARRIER_SEGMENTS:
		var a := TAU * (float(i) + 0.5) / float(BARRIER_SEGMENTS)
		var at := centre + Vector3(cos(a), 0.0, sin(a)) * RING_RADIUS
		var g: float = city.ai_world.ground_at(at.x, at.z)
		var body := StaticBody3D.new()
		body.collision_layer = Layers.FIXTURE
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(seg_len, BARRIER_HEIGHT + 6.0, 0.4)
		shape.shape = box
		body.add_child(shape)
		var wall := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(seg_len, BARRIER_HEIGHT + 6.0, 0.05)
		wall.mesh = bm
		wall.material_override = mat
		wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(wall)
		var band := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3(seg_len, 0.25, 0.08)
		band.mesh = em
		band.material_override = edge
		band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		band.position.y = 6.0 - (BARRIER_HEIGHT + 6.0) * 0.5 + 0.4
		body.add_child(band)
		barrier.add_child(body)
		# Centred 6 m below ground to BARRIER_HEIGHT above, facing the middle.
		body.global_position = Vector3(at.x, g + (BARRIER_HEIGHT - 6.0) * 0.5, at.z)
		body.rotation.y = -a + PI * 0.5


func in_ring(p: Vector3, grace := 0.0) -> bool:
	return Vector2(p.x - centre.x, p.z - centre.z).length() <= RING_RADIUS + grace


## Spots in the street round the ring a squad can land on: on the ground, out
## of the buildings, near the centre's height.
func _find_drop_zones() -> void:
	drop_zones.clear()
	for k in 2:
		var r: float = RING_RADIUS * (DROP_OUT if k == 0 else DROP_IN)
		for i in DROP_TURNS:
			var a := TAU * (float(i) + 0.5 * k) / float(DROP_TURNS)
			var want := centre + Vector3(cos(a), 0.0, sin(a)) * r
			want.y = city.ai_world.ground_at(want.x, want.z)
			var at: Vector3 = city.ai_nav.snap(want)
			if not city.ai_nav.can_stand(at) or _in_a_building(at) or not in_ring(at, -2.0) \
					or absf(at.y - centre.y) > 6.0:
				continue
			drop_zones.append(at)


## Where the next squad lands: one of the drop zones far from the player, not
## always the farthest. INF if there is none.
func _pick_drop() -> Vector3:
	if drop_zones.is_empty():
		_find_drop_zones()
	if drop_zones.is_empty():
		# The street round the focus, as the arena lands its squads.
		var ring := survey.ring_of(focus, 1, _rng)
		return ring[0] if not ring.is_empty() and in_ring(ring[0], -1.0) else Vector3.INF
	var p := _player()
	var from := p.feet() if p != null else centre
	var far: Array[Vector3] = []
	for z in drop_zones:
		if z.distance_to(from) >= DROP_FROM_PLAYER:
			far.append(z)
	if far.is_empty():
		far = drop_zones.duplicate()
	far.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_to(from) > b.distance_to(from))
	var top := maxi(1, far.size() / 2)
	return far[_rng.randi() % top]


# --- the game ---------------------------------------------------------------------

func _enter_intro() -> void:
	phase = Phase.INTRO
	_phase_until = _now() + INTRO_SECONDS
	_after_break = Callable()
	banner("FIREFIGHT\nSet %d  Round %d" % [set_index + 1, round_index + 1], INTRO_SECONDS)


## The next wave, now: its kinds drawn, its squads to land one by one.
func start_wave() -> void:
	phase = Phase.WAVE
	wave += 1
	var heavy := wave_in_round == WAVES_PER_ROUND - 1
	var size := 4 + wave_in_round + 2 * round_index + 2 * set_index
	if heavy:
		size += 2
	_armour_due = _wave_armour(heavy)
	# A truck's squad is part of the wave's count.
	size += int(_armour_due.trucks) * Commander.SQUAD_SIZE
	wave_left = size
	wave_trucks.clear()
	wave_tanks.clear()
	wave_mechs.clear()
	_queue.clear()
	_left_to_spawn = 0
	_next_squad = _now()
	survey.reset_counts()
	_find_drop_zones()
	if heavy:
		banner("Heavy wave", 2.5)
	else:
		banner("Wave %d" % (wave_in_round + 1), 2.0)
	print("[firefight] set %d round %d wave %d: %d soldier(s)%s, armour %s" % [set_index + 1,
			round_index + 1, wave_in_round + 1, size, " (heavy)" if heavy else "", _armour_due])


## What armour this wave brings: {trucks, tanks, mechs}.
func _wave_armour(heavy: bool) -> Dictionary:
	if "--ff-armour" in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		return {"trucks": 1, "tanks": 1, "mechs": 1}
	var later := round_index >= 1 or set_index > 0
	var trucks := 0
	if not heavy and later and (wave_in_round == 1 or wave_in_round == 3 \
			or (set_index > 0 and wave_in_round >= 1)):
		trucks = 1
	var tanks := 1 if heavy and later else 0
	var mechs := 0
	if heavy and (round_index == 2 or (set_index > 0 and round_index >= 1)):
		mechs = 1 + (1 if set_index >= 2 else 0)
	return {"trucks": trucks, "tanks": tanks, "mechs": mechs}


## The armour due, fielded once the wave's first squad is down (the tank
## escorts it).
func _field_armour() -> void:
	if _armour_due.is_empty():
		return
	var due := _armour_due
	_armour_due = {}
	for i in int(due.trucks):
		var kinds: Array[StringName] = []
		for k in Commander.SQUAD_SIZE:
			kinds.append(_draw_kind())
		var w := wave
		var before := trucks.size()
		if _send_truck(kinds):
			var t: TransportTruck = trucks[trucks.size() - 1]
			wave_trucks.append(t)
			_truck_sent_at[t.get_instance_id()] = _now()
			t.wrecked.connect(func(_t) -> void: _score_kill(&"truck"))
			wave_left -= kinds.size()
			banner("Incoming truck", 2.0)
		elif trucks.size() == before:
			print("[firefight] no road for a truck: its squad lands on foot")
		wave = w
	if int(due.tanks) > 0:
		_tanks_pending += int(due.tanks)
		# After the truck has pulled away: both start from the same open ground.
		_field_tanks(int(due.tanks), 4.0 if int(due.trucks) > 0 else 0.0)
	for i in int(due.mechs):
		var br := _drop_mech()
		if br != null:
			wave_mechs.append(br)
			br.mech.health.died.connect(func() -> void: _score_kill(&"mech"))
			banner("Enemy mech inbound!", 2.5)


func _field_tanks(n: int, after: float) -> void:
	if after > 0.0:
		await get_tree().create_timer(after, false).timeout
	if phase != Phase.WAVE:
		return
	for i in n:
		var was := tank
		_field_tank()
		if tank != null and tank != was and is_instance_valid(tank):
			wave_tanks.append(tank)
			tank.wrecked.connect(func(_t) -> void: _score_kill(&"tank"))
			banner("Enemy tank!", 2.5)
	_tanks_pending = maxi(0, _tanks_pending - n)


## An enemy mech dropped in at the drop zone farthest from the player that has
## room for it, facing the player. Null if none has.
func _drop_mech() -> MechBrain:
	var p := _player()
	var from := p.feet() if p != null else centre
	var zones: Array[Vector3] = drop_zones.duplicate()
	zones.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_to(from) > b.distance_to(from))
	for z in zones:
		var at: Vector3 = z
		if city.mech_nav != null:
			at = city.mech_nav.snap(z)
			if not city.mech_nav.can_stand(at) or not in_ring(at, -3.0):
				continue
		var to := from - at
		var br: MechBrain = city._spawn_enemy_mech(at + Vector3.UP * 0.1, atan2(-to.x, -to.z))
		feedback.burst(at + Vector3.UP * 2.0, Color(1.0, 0.55, 0.2))
		_tip()
		print("[firefight] enemy mech dropped in at %v" % at)
		return br
	print("[firefight] no drop zone with room for a mech")
	return null


func _score_kill(kind: StringName) -> void:
	score += int(UnitCatalog.points(kind) * KILL_SCORE * (1.0 + 0.5 * set_index))
	_fill_mech(UnitCatalog.points(kind) * MECH_PER_POINT)


## Armour of this wave still in the fight, by kind.
func armour_up() -> Dictionary:
	var tr: Array[TransportTruck] = []
	for t in wave_trucks:
		if is_instance_valid(t) and not t.is_wrecked() and not t.cargo.is_empty():
			tr.append(t)
	wave_trucks = tr
	var tk: Array[Tank] = []
	for t in wave_tanks:
		if is_instance_valid(t) and not t.is_wrecked():
			tk.append(t)
	wave_tanks = tk
	var mb: Array[MechBrain] = []
	for br in wave_mechs:
		if is_instance_valid(br) and is_instance_valid(br.mech) and not br.is_dead():
			mb.append(br)
	wave_mechs = mb
	return {"trucks": wave_trucks.size(), "tanks": wave_tanks.size(), "mechs": wave_mechs.size()}


func _armour_count() -> int:
	var a := armour_up()
	return int(a.trucks) + int(a.tanks) + int(a.mechs)


## A truck's squad gets out where it stopped -- unless that is outside the
## barrier, which would leave them walled out: then they land at a drop zone.
func _dismount(t: TransportTruck) -> void:
	if t.cargo.is_empty():
		return
	if in_ring(t.global_position, -2.0):
		var w := wave
		super(t)
		wave = w
		return
	var kinds := t.cargo.duplicate()
	t.cargo.clear()
	print("[firefight] truck stopped outside the ring at %v: its squad lands inside" % t.global_position)
	_land_squad(kinds)


## Trucks that never get there let their squad out anyway.
func _hurry_trucks(now: float) -> void:
	for t in wave_trucks:
		if is_instance_valid(t) and not t.is_wrecked() and not t.cargo.is_empty() \
				and now - float(_truck_sent_at.get(t.get_instance_id(), now)) > TRUCK_PATIENCE:
			print("[firefight] truck out of patience")
			_dismount(t)


func _draw_kind() -> StringName:
	var heavy := wave_in_round == WAVES_PER_ROUND - 1
	var pool: Array = ROUND_KINDS[mini(round_index, ROUND_KINDS.size() - 1)]
	if heavy:
		pool = HEAVY_KINDS
	# From the second set on, any wave may bring the heavy kinds.
	if set_index > 0 and not heavy and _rng.randf() < 0.25:
		pool = HEAVY_KINDS
	return pool[_rng.randi() % pool.size()]


## Land one squad: up to SQUAD_SIZE of what is left, as many as the cap allows
## -- or `given`, a truck's squad, all of it.
func _land_squad(given: Array = []) -> void:
	var n := given.size() if not given.is_empty() \
			else mini(mini(Commander.SQUAD_SIZE, wave_left), ALIVE_CAP - alive.size())
	if n <= 0:
		return
	var drop := _pick_drop()
	if drop == Vector3.INF:
		return
	_wave_squad = null
	var others: Array = []
	for so in alive:
		others.append(so.pawn)
	var landed := 0
	for i in n:
		var feet := Vector3.INF
		for t in 6:
			var a := TAU * float(i + t * n) / float(maxi(n, 1) * 2) + _rng.randf() * 0.3
			var r := 0.0 if i == 0 and t == 0 else 1.6 + 0.4 * t
			var want := drop + Vector3(cos(a), 0.0, sin(a)) * r
			want.y = city.ai_world.ground_at(want.x, want.z)
			var at: Vector3 = city.ai_nav.snap(want)
			if not in_ring(at, -1.0) or _in_a_building(at):
				continue
			if bool(survey.check(at, -1, _player(), others).ok):
				feet = at
				break
		if feet == Vector3.INF:
			continue
		_queue.append(given[i] if not given.is_empty() else _draw_kind())
		_left_to_spawn += 1
		_spawn_at(feet, -1)
		others.append(alive[alive.size() - 1].pawn)
		_note(feet, true)
		landed += 1
	if given.is_empty():
		wave_left -= landed
	if landed > 0:
		feedback.burst(drop + Vector3.UP * 1.0, Color(0.4, 0.8, 1.0))
		_tip()
		_field_armour()


func _wave_over() -> void:
	score += WAVE_BONUS * (wave_in_round + 1)
	wave_in_round += 1
	if wave_in_round < WAVES_PER_ROUND:
		_break(WAVE_BREAK, "Wave complete", Callable())
		return
	# The round is cleared.
	score += ROUND_BONUS * (round_index + 1)
	lives += LIVES_PER_ROUND
	if round_index + 1 < ROUNDS_PER_SET:
		_break(ROUND_BREAK, "Round %d complete\n+%d lives" % [round_index + 1, LIVES_PER_ROUND],
				func() -> void:
					round_index += 1
					wave_in_round = 0)
		return
	score += SET_BONUS
	_break(ROUND_BREAK, "Set %d complete\nThe next set is harder" % (set_index + 1),
			func() -> void:
				set_index += 1
				round_index = 0
				wave_in_round = 0
				level = 1 + set_index)


func _break(seconds: float, what: String, then: Callable) -> void:
	phase = Phase.BREAK
	_phase_until = _now() + seconds
	_after_break = then
	banner(what, minf(seconds, 4.0))
	print("[firefight] %s, score %d, lives %d" % [what.replace("\n", ", "), score, lives])
	if seconds >= ROUND_BREAK:
		# A new round: health and grenades back.
		var p := _player()
		if p != null and _player_dead_at < 0.0:
			p.health.reset()
		if city._arsenal != null:
			city._arsenal.grenades = PlayerArsenal.GRENADES_MAX


func _end_break() -> void:
	if _after_break.is_valid():
		_after_break.call()
		_after_break = Callable()
		banner("Round %d%s" % [round_index + 1, ("  ·  Set %d" % (set_index + 1)) if set_index > 0 else ""], 2.5)
	start_wave()


func _game_over() -> void:
	phase = Phase.GAME_OVER
	_phase_until = _now() + GAME_OVER_SECONDS
	banner("GAME OVER\nScore %d  ·  Set %d Round %d Wave %d" % [score, set_index + 1,
			round_index + 1, wave_in_round + 1], GAME_OVER_SECONDS)
	print("[firefight] game over: score %d, %d kill(s), set %d round %d wave %d" % [score, kills,
			set_index + 1, round_index + 1, wave_in_round + 1])


## From the top: the soldiers gone, the counters back, the player in the middle.
func restart() -> void:
	clear_soldiers()
	set_index = 0
	round_index = 0
	wave_in_round = 0
	level = 1
	lives = LIVES_START
	score = 0
	mech_meter = MECH_START
	_said_ready = false
	_clear_beacon()
	kills = 0
	wave_left = 0
	_player_dead_at = -1.0
	var p := _player()
	if p != null:
		p.health.reset()
		p.place(centre + Vector3.UP * 0.3)
	_enter_intro()


## Every soldier taken off, without a kill or loot (a restart, the gate).
func clear_soldiers() -> void:
	for so in alive.duplicate():
		if not is_instance_valid(so):
			continue
		city.ai_services.pawns.erase(so.pawn)
		city.soldiers.erase(so)
		if so._path_id >= 0:
			city.ai_nav.release(so._path_id)
		so.pawn.body.queue_free()
	alive.clear()
	_queue.clear()
	_left_to_spawn = 0
	# The armour, wrecked where it stands, and anybody who got out of it.
	for t in wave_trucks:
		if is_instance_valid(t):
			t.cargo.clear()
			t.health.apply_impact(1e9, &"")
	for t in wave_tanks:
		if is_instance_valid(t) and not t.is_wrecked():
			t.health.apply_impact(1e9, &"")
	for b in wave_mechs:
		if is_instance_valid(b) and is_instance_valid(b.mech) and not b.is_dead():
			b.mech.health.apply_impact(1e9, &"")
	for so in city.soldiers.duplicate():
		if is_instance_valid(so) and so.team == ENEMY_TEAM and so.pawn != null \
				and is_instance_valid(so.pawn) and not so.pawn.health.is_dead():
			so.pawn.health.apply_impact(1e9, &"")
	wave_trucks.clear()
	wave_tanks.clear()
	wave_mechs.clear()
	_armour_due = {}
	_tanks_pending = 0


# --- the tick ---------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not _ready_to_fight or not enabled:
		return
	var now := _now()
	_reap(now)
	_road_tick(now)
	_keep_in_ring()
	_player_tick(now)
	_mech_tick(_delta, now)
	match phase:
		Phase.INTRO:
			if now >= _phase_until:
				start_wave()
		Phase.BREAK:
			if now >= _phase_until:
				_end_break()
		Phase.WAVE:
			if wave_left > 0 and now >= _next_squad and alive.size() < ALIVE_CAP:
				_land_squad()
				_next_squad = now + SQUAD_GAP
			_hurry_trucks(now)
			if wave_left <= 0 and alive.is_empty() and _armour_count() == 0 and _armour_due.is_empty() \
					and _tanks_pending == 0:
				_wave_over()
		Phase.GAME_OVER:
			if now >= _phase_until:
				restart()
	if not alive.is_empty():
		var c: FactionKnowledge.Contact = city.ai_services.knowledge_of(ENEMY_TEAM).of(_player())
		if c == null or now - maxf(c.seen_at, c.heard_at) > LOST_SECONDS + TIP_AGE:
			_tip()
	if Engine.get_physics_frames() % 10 == 0:
		_update_label()


func _process(delta: float) -> void:
	if _banner == null or _banner_left <= 0.0:
		return
	_banner_left -= delta
	_banner.modulate.a = clampf(_banner_left / 0.6, 0.0, 1.0)
	if _banner_left <= 0.0:
		_banner.visible = false


func banner(text: String, seconds: float) -> void:
	if _banner == null:
		return
	_banner.text = text
	_banner.visible = true
	_banner.modulate.a = 1.0
	_banner_left = seconds


## The player over the barrier (off a roof) is put back in the middle; a soldier
## that got out has left the fight.
func _keep_in_ring() -> void:
	var p := _player()
	if p != null and not in_ring(p.feet(), OUTSIDE_GRACE):
		p.place(centre + Vector3.UP * 0.3)
		banner("Stay inside the barrier", 2.0)
	for so in alive.duplicate():
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn) \
				and not in_ring(so.pawn.feet(), SOLDIER_OUTSIDE):
			so.pawn.health.apply_impact(1e9, &"")


func _player_tick(now: float) -> void:
	var p := _player()
	if p == null:
		return
	if invulnerable and p.health.total_current() < 50.0:
		p.health.reset()
	if _player_dead_at >= 0.0 and phase != Phase.GAME_OVER and now - _player_dead_at >= PLAYER_RESPAWN:
		_player_dead_at = -1.0
		p.health.reset()
		p.place(_respawn_spot() + Vector3.UP * 0.3)
		print("[firefight] player back in at %v, %d li%s left" % [p.feet(), lives,
				"fe" if lives == 1 else "ves"])


## The drop zone (or the centre) farthest from every soldier.
func _respawn_spot() -> Vector3:
	var best := centre
	var best_d := -1.0
	var spots: Array[Vector3] = drop_zones.duplicate()
	spots.append(centre)
	for z in spots:
		var d := INF
		for so in alive:
			if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn):
				d = minf(d, so.pawn.feet().distance_to(z))
		if d > best_d:
			best_d = d
			best = z
	return best


func _on_player_died() -> void:
	if invulnerable:
		var p := _player()
		if p != null:
			p.health.reset()
			return
	if _player_dead_at >= 0.0 or phase == Phase.GAME_OVER:
		return
	_player_dead_at = _now()
	deaths += 1
	if lives <= 0:
		_game_over()
		return
	lives -= 1
	banner("You died\n%d li%s left" % [lives, "fe" if lives == 1 else "ves"], PLAYER_RESPAWN)
	print("[firefight] player down on wave %d, %d li%s left" % [wave, lives, "fe" if lives == 1 else "ves"])


func _on_soldier_died(so: Soldier) -> void:
	var kind := StringName(so.get_meta(&"unit", &"rifleman"))
	score += int(UnitCatalog.points(kind) * KILL_SCORE * (1.0 + 0.5 * set_index))
	_fill_mech(UnitCatalog.points(kind) * MECH_PER_POINT)
	super(so)


# --- your mech ----------------------------------------------------------------------

func player_mech_up() -> bool:
	var m: Mech = city._mech
	return m != null and is_instance_valid(m) and m.health != null and not m.health.is_dead()


func _fill_mech(amount: float) -> void:
	if player_mech_up() or _beacon_at != Vector3.INF:
		return
	mech_meter = minf(1.0, mech_meter + amount)


func _mech_tick(delta: float, now: float) -> void:
	if phase == Phase.WAVE or phase == Phase.BREAK:
		_fill_mech(delta / MECH_FILL_SECONDS)
	if mech_meter >= 1.0 and not _said_ready:
		_said_ready = true
		banner("MECH READY\npress M to call it in", 3.0)
		print("[firefight] mech ready")
	if _beacon_at != Vector3.INF and now >= _beacon_until:
		_land_mech()


## M on foot with no hatch in reach (CityScene._board_mech): call the mech down
## near `aim`. True when this took the key -- it says why when it cannot.
func call_mech(aim: Vector3) -> bool:
	if player_mech_up():
		banner("Your mech is already down\nM at its hatch to board", 2.5)
		return true
	if _beacon_at != Vector3.INF:
		return true
	if mech_meter < 1.0:
		banner("Mech not ready: %d%%" % int(mech_meter * 100.0), 2.0)
		return true
	var spot := _mech_spot(aim)
	if spot == Vector3.INF:
		banner("No room for your mech there", 2.0)
		return true
	mech_meter = 0.0
	_said_ready = false
	mech_calls += 1
	_beacon_at = spot
	_beacon_until = _now() + MECH_BEACON
	_show_beacon(spot)
	banner("Mech inbound", 2.0)
	print("[firefight] mech called in at %v" % spot)
	return true


## Where it lands: the aim point if a mech can stand there (pulled inside the
## ring), else the nearest drop zone to the player that can take it.
func _mech_spot(aim: Vector3) -> Vector3:
	var tries: Array[Vector3] = []
	if aim != Vector3.INF:
		var flat := Vector3(aim.x - centre.x, 0.0, aim.z - centre.z)
		if flat.length() > RING_RADIUS - 4.0:
			flat = flat.normalized() * (RING_RADIUS - 4.0)
		var a := centre + flat
		a.y = city.ai_world.ground_at(a.x, a.z) if absf(aim.y - centre.y) > 6.0 else aim.y
		tries.append(a)
	var p := _player()
	var from := p.feet() if p != null else centre
	var zones: Array[Vector3] = drop_zones.duplicate()
	zones.sort_custom(func(x: Vector3, y: Vector3) -> bool: return x.distance_to(from) < y.distance_to(from))
	tries.append_array(zones)
	for t in tries:
		var at: Vector3 = t
		if city.mech_nav != null:
			at = city.mech_nav.snap(t)
			if not city.mech_nav.can_stand(at):
				continue
		if not in_ring(at, -3.0) or _in_a_building(at) or at.distance_to(from) < 3.0:
			continue
		return at
	return Vector3.INF


func _show_beacon(at: Vector3) -> void:
	if _beacon != null and is_instance_valid(_beacon):
		_beacon.queue_free()
	_beacon = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.3
	cm.bottom_radius = 0.3
	cm.height = 80.0
	_beacon.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 1.0, 0.45, 0.55)
	_beacon.material_override = mat
	_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	city.add_child(_beacon)
	_beacon.global_position = at + Vector3.UP * 40.0


func _clear_beacon() -> void:
	if _beacon != null and is_instance_valid(_beacon):
		_beacon.queue_free()
	_beacon = null
	_beacon_at = Vector3.INF


## Down it comes: anybody under it is crushed, and it stands ready to board.
func _land_mech() -> void:
	var at := _beacon_at
	_clear_beacon()
	for so in alive.duplicate():
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn) \
				and so.pawn.feet().distance_to(at) < MECH_CRUSH:
			so.pawn.health.apply_impact(1e9, &"")
	var p := _player()
	var to := (p.feet() - at) if p != null else Vector3.FORWARD
	city._spawn_mech(at + Vector3.UP * 0.1, atan2(-to.x, -to.z) + PI)
	feedback.burst(at + Vector3.UP * 1.5, Color(0.3, 1.0, 0.45))
	banner("Mech down\nM at its hatch to board", 3.0)
	print("[firefight] mech landed at %v" % at)


# --- showing it ---------------------------------------------------------------------

func _update_label() -> void:
	var p := _player()
	var lines := [
		"SET %d   ROUND %d   WAVE %d/%d" % [set_index + 1, round_index + 1,
				mini(wave_in_round + 1, WAVES_PER_ROUND), WAVES_PER_ROUND],
		"ENEMIES  %d" % (alive.size() + wave_left),
		"LIVES  %d     SCORE  %d" % [lives, score],
	]
	var a := armour_up()
	var armour := []
	for k in [["tanks", "TANK"], ["mechs", "MECH"], ["trucks", "TRUCK"]]:
		if int(a[k[0]]) > 0:
			armour.append("%s%s" % [k[1], (" x%d" % int(a[k[0]])) if int(a[k[0]]) > 1 else ""])
	if not armour.is_empty():
		lines.append("ARMOUR  " + "  ".join(armour))
	if player_mech_up():
		lines.append("MECH  UP")
	elif _beacon_at != Vector3.INF:
		lines.append("MECH  INBOUND %.0f s" % maxf(0.0, _beacon_until - _now()))
	elif mech_meter >= 1.0:
		lines.append("MECH  READY -- press M")
	else:
		lines.append("MECH  %d%%" % int(mech_meter * 100.0))
	if p != null and _player_dead_at >= 0.0 and phase != Phase.GAME_OVER:
		lines.append("back in %.0f s" % maxf(0.0, PLAYER_RESPAWN - (_now() - _player_dead_at)))
	if phase == Phase.BREAK or phase == Phase.INTRO:
		lines.append("next wave in %.0f s" % maxf(0.0, _phase_until - _now()))
	if DevMode.on:
		lines.append("F8 end the wave   F7 spawn overlay%s" % ("   INVINCIBLE" if DevMode.invincible else ""))
	_label.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo) or not DevMode.on:
		return
	match event.keycode:
		KEY_F7:
			_show_overlay = not _show_overlay
			_draw_overlay()
		KEY_F8:
			if phase == Phase.WAVE:
				wave_left = 0
				for so in alive.duplicate():
					if is_instance_valid(so):
						so.pawn.health.apply_impact(1e9, &"")
				_armour_due = {}
				_kill_armour()
				for t in wave_trucks:
					if is_instance_valid(t) and not t.is_wrecked():
						t.cargo.clear()
						t.health.apply_impact(1e9, &"")
			elif phase == Phase.INTRO or phase == Phase.BREAK:
				_phase_until = _now()


# --- the gate -----------------------------------------------------------------------

## `-- --gate` on scenes/firefight.tscn: the ring is walled, a wave lands inside
## it away from the player, a wave killed is a wave over (score, the next one
## after the break), a death costs a life and puts the player back in the
## ring, a player out over the barrier is put back, and down with no lives left
## is game over -- and a restart is the first wave again.
func run_firefight_gate() -> void:
	var ok: Callable = city._gate_ok
	var p := _player()
	ok.call("the fight is set up", _ready_to_fight and p != null)
	if p == null:
		return
	ok.call("the ring has a barrier", barrier != null and barrier.get_child_count() == BARRIER_SEGMENTS)
	ok.call("drop zones to land squads on", drop_zones.size() >= 4, "%d" % drop_zones.size())
	ok.call("the player starts inside the ring", in_ring(p.feet()))
	ok.call("the intro first", phase == Phase.INTRO)
	# The wave now, not after the intro.
	_phase_until = _now()
	await _until(func() -> bool: return phase == Phase.WAVE and not alive.is_empty(), 10.0)
	ok.call("a wave lands", not alive.is_empty(), "wave_left %d" % wave_left)
	await _frames(SETTLE_TICKS + 5)
	var inside := true
	var near_player := 0
	for so in alive:
		if not in_ring(so.pawn.feet()):
			inside = false
		if so.pawn.feet().distance_to(p.feet()) < SpawnSurvey.MIN_FROM_PLAYER:
			near_player += 1
	ok.call("every soldier lands inside the ring", inside)
	ok.call("none on top of the player", near_player == 0, "%d" % near_player)
	# Kill the wave, squad by squad as they land.
	var first_wave := wave_in_round
	var score0 := score
	var t0 := _now()
	while phase == Phase.WAVE and _now() - t0 < 60.0:
		for so in alive.duplicate():
			if is_instance_valid(so):
				so.pawn.health.apply_impact(1e9, &"")
		await _frames(5)
	ok.call("a wave killed is a wave over", phase == Phase.BREAK and wave_in_round == first_wave + 1,
			"phase %s, wave %d" % [Phase.keys()[phase], wave_in_round])
	ok.call("kills and the wave score", score > score0 + WAVE_BONUS, "%d -> %d" % [score0, score])
	_phase_until = _now()
	await _until(func() -> bool: return phase == Phase.WAVE, 3.0)
	ok.call("the next wave after the break", phase == Phase.WAVE)
	# A death costs a life, and the player comes back in the ring.
	invulnerable = false
	var lives0 := lives
	p.health.apply_impact(1e9, &"")
	await _frames(2)
	ok.call("a death costs a life", lives == lives0 - 1, "%d -> %d" % [lives0, lives])
	await _until(func() -> bool: return _player_dead_at < 0.0, PLAYER_RESPAWN + 2.0)
	ok.call("back in after the respawn", not p.health.is_dead() and in_ring(p.feet()))
	# Out over the barrier: put back.
	p.place(centre + Vector3(RING_RADIUS + OUTSIDE_GRACE + 4.0, 2.0, 0.0))
	await _frames(3)
	ok.call("a player outside the ring is put back", in_ring(p.feet()))
	# No lives left: game over, then the first wave again.
	lives = 0
	p.health.apply_impact(1e9, &"")
	await _frames(2)
	ok.call("down with no lives left is game over", phase == Phase.GAME_OVER)
	_phase_until = _now()
	await _frames(3)
	ok.call("a restart is the first wave, lives back", phase == Phase.INTRO and wave_in_round == 0
			and lives == LIVES_START and alive.is_empty() and not p.health.is_dead())
	invulnerable = true
	await _armour_gate(ok)
	await _mech_gate(ok)


## Your mech: refused while the meter is short, called when it is full -- the
## meter spent, a beacon up -- landing inside the ring after MECH_BEACON, and
## refused again while it is up.
func _mech_gate(ok: Callable) -> void:
	var p := _player()
	if city._mech != null and is_instance_valid(city._mech):
		city._mech.health.apply_impact(1e9, &"")
	await _frames(2)
	mech_meter = 0.5
	var calls0 := mech_calls
	call_mech(p.feet() + Vector3(6.0, 0.0, 0.0))
	ok.call("no mech while the meter is short", mech_calls == calls0 and _beacon_at == Vector3.INF)
	mech_meter = 1.0
	call_mech(centre + Vector3(6.0, 0.0, 6.0))
	ok.call("a full meter calls it in", mech_calls == calls0 + 1 and _beacon_at != Vector3.INF
			and mech_meter == 0.0)
	await _until(func() -> bool: return player_mech_up(), MECH_BEACON + 3.0)
	ok.call("it lands, inside the ring", player_mech_up() and in_ring(city._mech.feet()))
	mech_meter = 1.0
	call_mech(centre)
	ok.call("one at a time", mech_calls == calls0 + 1)


## Armour: a wave with a truck, a tank and a mech fields all three -- the mech
## inside the ring -- is not over while they are up, and is once they are
## down and the truck's squad is out and killed.
func _armour_gate(ok: Callable) -> void:
	_phase_until = _now()
	await _until(func() -> bool: return phase == Phase.WAVE, 3.0)
	_armour_due = {"trucks": 1, "tanks": 1, "mechs": 1}
	wave_left += Commander.SQUAD_SIZE
	await _until(func() -> bool: return _armour_due.is_empty() and _tanks_pending == 0, 15.0)
	var a := armour_up()
	ok.call("a truck sets out with a squad", int(a.trucks) == 1, "%s" % a)
	ok.call("a tank sets out", int(a.tanks) == 1, "%s" % a)
	ok.call("a mech drops in", int(a.mechs) == 1, "%s" % a)
	if not wave_mechs.is_empty():
		ok.call("the mech lands inside the ring", in_ring(wave_mechs[0].mech.feet()))
	# The squads killed, the armour still up: not over.
	for i in 20:
		for so in alive.duplicate():
			if is_instance_valid(so):
				so.pawn.health.apply_impact(1e9, &"")
		await _frames(3)
	ok.call("not over while its armour is up", phase == Phase.WAVE)
	# The truck gets its squad out (it is hurried), then everything goes down.
	_truck_sent_at.clear()
	for t in wave_trucks:
		_truck_sent_at[t.get_instance_id()] = _now() - TRUCK_PATIENCE - 1.0
	var score0 := score
	var t0 := _now()
	while phase == Phase.WAVE and _now() - t0 < 30.0:
		for so in alive.duplicate():
			if is_instance_valid(so):
				so.pawn.health.apply_impact(1e9, &"")
		_kill_armour()
		await _frames(5)
	ok.call("over once the armour is down and the truck's squad killed", phase == Phase.BREAK,
			"phase %s, armour %s, alive %d, left %d" % [Phase.keys()[phase], armour_up(), alive.size(), wave_left])
	ok.call("armour kills score", score >= score0 + int(UnitCatalog.points(&"tank") * KILL_SCORE),
			"%d -> %d" % [score0, score])


## Every tank and mech of the wave wrecked (F8, the gate). Trucks with their
## squad aboard are left to let it out.
func _kill_armour() -> void:
	for t in wave_tanks:
		if is_instance_valid(t) and not t.is_wrecked():
			t.health.apply_impact(1e9, &"")
	for b in wave_mechs:
		if is_instance_valid(b) and is_instance_valid(b.mech) and not b.is_dead():
			b.mech.health.apply_impact(1e9, &"")
