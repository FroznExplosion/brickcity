class_name WaveDirector
extends Node
## The combat arena (scenes/combat_arena.tscn): the player's pawn in a street of
## the terrain city, and waves of soldiers that come out of a building and the
## ground round it.
##
## One building is the FOCUS. An encounter is started over it and its
## neighbours, so they are bricks with floors in them (Encounter, AIPlan R3),
## and each wave puts some soldiers on its floors and the rest round its walls.
## Every spot goes through SpawnSurvey twice -- when the wave is planned, from
## the bricks, and again the tick the soldier appears, from the physics -- so a
## soldier is never put on a floor that has fallen out, in a building that has
## come down, or on a section that is still falling. When the focus is no
## longer fit to stand in, the fight moves to the nearest building that is.
##
## The soldiers are not told where the player is. A wave is SENT: when it starts
## the side is given a rough fix (TIP_SPREAD metres out), and after that it
## knows what it sees and hears -- and the player's gun is heard (AIServices).
##
## WHAT comes, and when, and what the squads are told to do, is the COMMANDER's
## (Commander): it buys squads with points and asks for them here
## (request_squad); this puts them on the floors and round the walls, as the
## survey allows, and hands each squad back to it.
## Only if nobody on the side has had any contact for LOST_SECONDS is another
## rough fix given, so a player who hides and stays quiet is looked for rather
## than waited for.
##
## What a hit looks like is CombatFeedback's: hitmarkers, numbers, the flash,
## the hurt edge, and the burst a body goes out in -- it does not stay.
##
## Keys: F7 the spawn survey overlay (green a spot taken, red one refused)
##       F8 the next wave now
##
## `-- --gate` is the scripted check; `-- --watch` prints what each soldier of a
## wave is doing, second by second for 30 s, against a player standing still.

const PLAYER_TEAM := 0
const ENEMY_TEAM := 1
## A reinforcement (a "wave") is one squad, Commander.SQUAD_SIZE strong; no more
## than ALIVE_CAP up at once (Docs/AI.md A2: about ten smart agents).
const BASE := Commander.SQUAD_SIZE
const ALIVE_CAP := 8
## Spots that pass the survey the commander chooses between, per soldier.
const SPOT_CHOICES := 3
## The HQ goes in a standing building at most this far from the focus.
const HQ_WITHIN := 70.0
const RADIO_HP := 120.0
## The fight's level (Tier, 1..10): what its soldiers' defences are sized at
## (EnemyProfiles). The player's guns are rolled at the same level.
var level := 1
## The HQ is at least this far from the focus: out of its collapse.
const HQ_CLEAR := 25.0
## A truck sets out this far from the focus.
const TRUCK_OUT := 70.0
## ...and starts within this height of the fight.
const TRUCK_LEVEL := 1.5
## ...looked for in this many directions round the focus, at five distances.
const TRUCK_TURNS := 32
## The gate's room spot is this far inside its room on every side.
const ROOM_MARGIN := 0.8
## The share of a wave put inside the focus building, when it has floors.
const SPAWN_EVERY := 0.6
const FIRST_WAVE_AFTER := 4.0
const PLAYER_RESPAWN := 3.0
## A rough fix on the player: this far out, and dated so that it is older than
## the fight branch's 2.5 s (SoldierTree) -- a soldier goes to look, rather than
## taking cover from somebody it has never seen.
const TIP_SPREAD := 8.0
const TIP_AGE := 3.0
## Nobody on the side has seen or heard the player for this long: another fix.
const LOST_SECONDS := 15.0
## The arena's soldiers are slower on the trigger and looser than the AI's
## defaults (AimModel): 0.35 s, 7 -> 1.2 degrees over 1.6 s.
const AIM_REACTION := 0.7
const AIM_CONE_START := 10.0
const AIM_CONE_MIN := 2.6
const AIM_SETTLE := 2.6
## Ticks after a spawn its drop is measured at.
const SETTLE_TICKS := 15
## Half a street out from a face.
const STREET_OUT := 1.6
## A doorway: the nav gate's breach (city_scene._run_nav_pass).
const DOOR_RADIUS := 1.3
## How far round the focus the encounter holds buildings as bricks.
const ZONE_MARGIN := 24.0
## Survey again this often while a wave is spawning: the building may have
## changed since it was planned.
const RESURVEY_EVERY := 3.0

var city: Node3D
var survey: SpawnSurvey
var enabled := true
## Gate: the player cannot die.
var invulnerable := false

var wave := 0
var kills := 0
var focus := -1
var focus_changes := 0
## Every spawn made: {feet, inside (building id or -1), on, wave, soldier}.
var spawned: Array[Dictionary] = []
var alive: Array[Soldier] = []

var _left_to_spawn := 0
## This wave's size, and how many of it have been put inside so far.
var _wave_size := 0
var _put_inside := 0
var _next_spawn := 0.0
## The commander, and the squad now being put down with the kinds it asked for.
var commander: Commander
var _queue: Array[StringName] = []
var _wave_squad: Squad
var _next_profile := 0.0
## The commander's HQ: its officer, its radio, and the building they are in.
var hq_officer: Soldier
var hq_radio: StaticBody3D
var hq_building := -1
## Trucks bringing squads (TransportTruck).
var trucks: Array[TransportTruck] = []
## The share of the last truck's road that was a truck wide (_truck_start).
var _truck_road := 0.0
var _next_survey := 0.0
var _floors: Array[Vector3] = []
var _encounter: Encounter
var _start := Vector3.ZERO
var feedback: CombatFeedback
## The player's view of what the soldiers say (Callouts, AI.md 6.5).
var listener: Callouts.Listener
var callout_hud: CalloutHud
## Physics ticks on which the player had at least one line in front of them.
var heard_ticks := 0
## The body of the last soldier to die (instance id), for the gate.
var last_dead_id := 0
## Metres each soldier has walked since it appeared (instance id -> metres).
var travelled := {}
var _last_at := {}
## Ticks any soldier spent crouched, for the gate (nobody crouches, A21).
var _crouched := 0
var _player_dead_at := -1.0
var _rng := RandomNumberGenerator.new()
var _label: Label
var _overlay: MeshInstance3D
var _show_overlay := false
var _last_move := ""
var _ready_to_fight := false
var _breached := {}


func setup(p_city: Node3D) -> void:
	city = p_city
	survey = SpawnSurvey.new(city)
	_rng.seed = 0xA7E4A
	_label = Label.new()
	# Top right, clear of the city's own stats (top left, F1).
	_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.offset_right = -14.0
	_label.offset_top = 12.0
	if city.stats_label != null:
		city.stats_label.visible = false
	_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.7))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	var layer := CanvasLayer.new()
	layer.add_child(_label)
	add_child(layer)
	feedback = CombatFeedback.new()
	feedback.name = "Feedback"
	add_child(feedback)
	feedback.setup(city)
	city._gun.fired.connect(_on_player_fired)
	commander = Commander.new()
	commander.name = "Commander"
	add_child(commander)
	commander.alive_cap = ALIVE_CAP
	commander.spawner = request_squad
	commander.can_truck = true
	commander.room_at = func(p: Vector3) -> Dictionary: return CityRooms.at(city, p)
	_wire_support()


## Pick the focus, hold it as bricks, and put the player in the street.
func begin() -> void:
	if city.ai_services.world3d == null:
		city.ai_services.world3d = city.get_world_3d()
		city.ai_services.on_structure_hit = city._gun.on_structure_hit
	var centre := Vector3.ZERO
	focus = _pick_focus(centre, -1)
	if focus < 0:
		push_warning("[arena] no building to fight in")
		return
	_hold(focus)
	_start = _street_of(focus)
	# The terrain's colliders are where the camera is: put it there first.
	city.camera.global_position = _start + Vector3.UP * 3.0
	var b: BuildingRegistry.Building = city.registry.get_building(focus)
	city.camera.look_at(city._world_box(b).get_center(), Vector3.UP)
	# Wait for the encounter's buildings and for ground under the start.
	var guard := 0
	while guard < 600 and (not _encounter.is_ready() or not _ground_under(_start)):
		await get_tree().physics_frame
		guard += 1
	for i in 10:
		await get_tree().physics_frame
	# A rifle to start with (T still cycles): the pistol is the weakest thing
	# in the game, and the first thing a player should hold is a fair fight.
	city._gun_class = city.GUN_CLASSES.find(&"rifle")
	city._equip_gun(&"rifle", city._combat_rng.randi())
	city._enter_pawn(_start + Vector3.UP * 0.3)
	listener = city.ai_services.callouts.listen(city.camera, PLAYER_TEAM, _player())
	callout_hud = CalloutHud.new()
	callout_hud.name = "Callouts"
	callout_hud.setup(city.ai_services.callouts, listener)
	add_child(callout_hud)
	_player().health.died.connect(_on_player_died)
	_resurvey()
	commander.setup(city.ai_services, ENEMY_TEAM)
	# Fast planes for its soldiers to call in (AIRoster.md R10) -- not in the
	# gate, whose fights are compared run to run.
	if not "--gate" in (OS.get_cmdline_args() + OS.get_cmdline_user_args()):
		city.ai_services.air_of(ENEMY_TEAM).parent = city
	commander.rally = city._world_box(city.registry.get_building(focus)).get_center()
	# The first squad a few seconds in: the commander's clock, set back.
	commander.hold_until(_now() + FIRST_WAVE_AFTER)
	commander.players_at = func() -> Array:
		var p := _player()
		return [p.feet()] if p != null else []
	_set_up_hq()
	_ready_to_fight = true
	print("[arena] focus building %d, player at %v, %d floor spot(s) in it" % [
		focus, _start, _floors.size()])


func _now() -> float:
	return city.ai_services.now()


func _player() -> Pawn:
	var p: Pawn = city._player_pawn
	return p if p != null and is_instance_valid(p) else null


# --- the tick ---------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not _ready_to_fight or not enabled:
		return
	var now := _now()
	_reap(now)
	if listener != null and not listener.views.is_empty():
		heard_ticks += 1
	_settle_check()
	for so in alive:
		var k := so.get_instance_id()
		var at := so.pawn.feet()
		if _last_at.has(k):
			var was: Vector3 = _last_at[k]
			travelled[k] = float(travelled.get(k, 0.0)) + Vector2(at.x - was.x, at.z - was.z).length()
		_last_at[k] = at
	for so in alive:
		# The body, not the ask: plays still ask for it (P6's assignments), and
		# Pawn.no_crouch refuses. Ducking under a beam is the body, not a choice.
		# The rule, not the body: crouching is never allowed a soldier (Pawn.
		# no_crouch), outside a disaster's duck, let through for now (AI.md A21).
		# A body squeezed where it can neither stand nor fit crouched stays low,
		# and that is the body, not a crouch.
		if not so.pawn.no_crouch and not so._ducking and _now() - so._duck_until > 0.5:
			_crouched += 1
	_check_focus()
	_tank_report(now)
	if Engine.get_physics_frames() % 15 == 7:
		_check_hq()
	_player_tick(now)
	if now >= _next_profile:
		# What the commander learns of the player: how close it fights.
		_next_profile = now + 1.0
		var p := _player()
		if p != null and not alive.is_empty():
			var near := INF
			for so in alive:
				near = minf(near, so.pawn.feet().distance_to(p.feet()))
			commander.profile.sample(near, 1.0)
	if _left_to_spawn > 0 and now >= _next_spawn and alive.size() < ALIVE_CAP:
		if now >= _next_survey:
			_resurvey()
		_spawn_one()
		_next_spawn = now + SPAWN_EVERY
	if not alive.is_empty():
		var c: FactionKnowledge.Contact = city.ai_services.knowledge_of(ENEMY_TEAM).of(_player())
		if c == null or now - maxf(c.seen_at, c.heard_at) > LOST_SECONDS + TIP_AGE:
			_tip()
	if Engine.get_physics_frames() % 10 == 0:
		_update_label()


## The commander's spawner: put down a squad of these kinds. False while one is
## still going down, or before the fight is set up.
func request_squad(kinds: Array[StringName], arrival: StringName = &"foot") -> bool:
	if not _ready_to_fight or kinds.is_empty():
		return false
	if arrival == &"truck":
		return _send_truck(kinds)
	# A batch still going down when the next is asked for -- its spots kept
	# failing (a building came down under them) -- is given up: the commander's
	# new call is the one that counts, and waiting on the old one refused every
	# call after it.
	if _left_to_spawn > 0:
		print("[arena] reinforcement %d abandoned with %d still to come" % [wave, _left_to_spawn])
		_left_to_spawn = 0
		_queue.clear()
	wave += 1
	_queue = kinds.duplicate()
	_left_to_spawn = kinds.size()
	_wave_size = _left_to_spawn
	_put_inside = 0
	_wave_squad = null
	_next_spawn = _now()
	survey.reset_counts()
	_tip()
	_resurvey()
	print("[arena] reinforcement %d: %s, %d floor spot(s) in building %d" % [
		wave, ", ".join(kinds), _floors.size(), focus])
	_air_wing()
	_tank_wing()
	return true


## Air and armour (AIRoster.md RO10, RO11): the COMMANDER buys them with its
## points as support (Commander.buy_support, Doctrine.support) -- a flyer or
## hover craft of the roster, or a tank -- and this host fields them
## (_field_support). Not in a gate: its checks count a wave's soldiers.
##
## Two switches field them free, for trying them out: `-- --air`, AIR_PER_WAVE
## flyers and the Skimmer with every reinforcement; `-- --tank`, a tank.
const AIR_PER_WAVE := 2
const AIR_KINDS: Array[StringName] = [&"gnat", &"gnat", &"drone"]
## A hover craft keeps to the area over the focus building (AIRoster.md R10).
const HOVER_KIND := &"skimmer"
var hover: Flyer
var air: Array[Flyer] = []
## The enemy's tank, and the squad screening it.
var tank: Tank


## The commander's support, wired when this is not a gate.
func _wire_support() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if "--gate" in args:
		return
	commander.support_spawner = _field_support
	commander.support_up = func() -> Dictionary:
		air = air.filter(func(f): return is_instance_valid(f) and not f.is_dead())
		return {&"air": air.size(),
				&"tank": 1 if tank != null and is_instance_valid(tank) and not tank.is_wrecked() else 0}


## What the commander bought: `unit` of `kind` (&"air" or &"tank").
func _field_support(kind: StringName, unit: StringName) -> bool:
	if _player() == null:
		return false
	print("[arena] the commander buys %s (%.1f pts of %.1f), answering %s / %s" % [unit,
			UnitCatalog.points(unit), commander.budget, commander.doctrine.answering,
			commander.doctrine.answering_armor])
	if kind == &"tank":
		return _field_tank()
	return _field_flyer(unit) != null


func _air_wing() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if not "--air" in args or "--gate" in args or _player() == null or Roster.shared() == null:
		return
	air = air.filter(func(f): return is_instance_valid(f) and not f.is_dead())
	for i in AIR_PER_WAVE:
		_field_flyer(AIR_KINDS[city._combat_rng.randi() % AIR_KINDS.size()])
	if hover == null or not is_instance_valid(hover) or hover.is_dead():
		_field_flyer(HOVER_KIND)
	print("[arena] air wing: %s" % [air.map(func(f): return f.name_tag.text if f.name_tag != null else "flyer")])


## One flyer of recipe `kind` over the fight: a hover craft over the focus
## building, held to its area; any other from over the rooftops round the
## player. Null if the roster cannot field it.
func _field_flyer(kind: StringName) -> Flyer:
	var p := _player()
	var unit := UnitCatalog.get_unit(kind)
	if p == null or not bool(unit.get("built", false)) or Roster.shared() == null:
		return null
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(city._gun_library,
			city._combat_rng.randi(), WeaponClass.builtin(StringName(unit.weapon)), 1))
	var hovers := str(Roster.shared().recipe(str(unit.get("recipe", ""))).get("body", "")) == "hover"
	var at: Vector3
	var over := Vector3.ZERO
	if hovers:
		var c: Vector3 = city._world_box(city.registry.get_building(focus)).get_center()
		over = Vector3(c.x, 0.0, c.z)
		at = over + Vector3.UP * 40.0
	else:
		var ang: float = city._combat_rng.randf() * TAU
		at = p.feet() + Vector3(cos(ang), 0.0, sin(ang)) * 45.0 + Vector3.UP * 25.0
	var f := Flyer.spawn(city.ai_services, city, at, ENEMY_TEAM, gun)
	UnitCatalog.apply_health(f.health, kind, level)
	f.set_type(str(unit.get("recipe", "")), Roster.shared())
	if hovers:
		f.set_loiter(over)
		hover = f
	air.append(f)
	print("[arena] in the air: %s" % (f.name_tag.text if f.name_tag != null else String(kind)))
	return f


## A tank with the reinforcements (`-- --tank`): see _field_tank.
func _tank_wing() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	if not "--tank" in args or "--gate" in args or _player() == null:
		return
	_field_tank()


## A crewed tank (one at a time): it drives in from out past the fight -- where
## a truck would start -- to the focus building's street, at the pace of the
## wave's squad, who screen it. A live one is sent on to the new focus instead.
func _field_tank() -> bool:
	var goal: Vector3 = _street_of(focus)
	if tank != null and is_instance_valid(tank) and not tank.is_wrecked():
		(tank.get_node(^"TankBrain") as TankBrain).send(goal)
		return false
	var start := _truck_start()
	if start == Vector3.INF:
		print("[arena] no open ground for a tank to start from")
		return false
	var to := goal - start
	tank = city._spawn_tank(start, atan2(-to.x, -to.z), ENEMY_TEAM, true)
	var br := tank.get_node(^"TankBrain") as TankBrain
	br.send(goal)
	if _wave_squad != null and is_instance_valid(_wave_squad):
		br.escort = _wave_squad
	print("[arena] tank from %v to the street of building %d" % [start, focus])
	return true


## Every TANK_REPORT seconds while a tank is out: what it and its escort are
## doing, for the log (`--tank`).
const TANK_REPORT := 10.0
var _tank_report_at := 0.0
func _tank_report(now: float) -> void:
	if tank == null or not is_instance_valid(tank) or now < _tank_report_at:
		return
	_tank_report_at = now + TANK_REPORT
	if tank.is_wrecked():
		print("[arena] tank: wrecked")
		tank = null
		return
	var br := tank.get_node(^"TankBrain") as TankBrain
	var near := 0
	var screening := 0
	for so in alive:
		if is_instance_valid(so) and so.pawn.feet().distance_to(tank.feet()) < TacticsSense.HEAVY_NEAR:
			near += 1
			if so.state in ["screen", "lee"]:
				screening += 1
	var holds := br.take_hold_counts()
	var ks := holds.keys()
	ks.sort_custom(func(x, y): return int(holds[x]) > int(holds[y]))
	print("[arena] tank: %s, %.0f hp, %d shell(s), %d crew, %.0f m from the player; %d soldier(s) within %.0f m, %d screening or in its lee; gunner %s" % [
			br.state, tank.health.total_current(), tank.shells, tank.crew_count(),
			tank.feet().distance_to(_player().feet()) if _player() != null else -1.0,
			near, TacticsSense.HEAVY_NEAR, screening,
			", ".join(ks.map(func(k): return "%s %d%%" % [k, roundi(100.0 * int(holds[k]) / maxf(1.0, float(holds.values().reduce(func(x, y): return x + y, 0))))]))])


func _spawn_one() -> void:
	# A quota, not a coin: inside while fewer than the share of those spawned
	# so far (this one included) have been, so a wave mixes from its start.
	var done := _wave_size - _left_to_spawn
	var want_inside := not _floors.is_empty() \
			and float(_put_inside) < commander.doctrine.inside_share * float(done + 1) - 0.01
	# A body bigger than a person does not start on a floor it could not leave.
	if want_inside and not _queue.is_empty() and Roster.shared() != null:
		var next := UnitCatalog.get_unit(_queue[0])
		if str(Roster.shared().recipe(str(next.get("recipe", ""))).get("size", "person")) != "person":
			want_inside = false
	var others: Array = []
	for so in alive:
		others.append(so.pawn)
	# A few tries: a spot that fails the check is dropped and the next tried.
	# Of the spots that pass, the commander's map picks the one where its men
	# have not been dying and the enemy has not been seen (SectorGrid).
	var good: Array = []
	var inside := focus if want_inside else -1
	for attempt in 12:
		if good.size() >= SPOT_CHOICES:
			break
		var feet: Vector3
		if want_inside:
			if _floors.is_empty():
				break
			var i := _rng.randi() % _floors.size()
			feet = _floors[i]
			var r := survey.check(feet, inside, _player(), others)
			if not bool(r.ok):
				_floors.remove_at(i)
				_note(feet, false)
				continue
		else:
			var ring := survey.ring_of(focus, 1, _rng)
			if ring.is_empty():
				return
			feet = ring[0]
			var r := survey.check(feet, -1, _player(), others)
			if not bool(r.ok):
				_note(feet, false)
				continue
		good.append(feet)
	if good.is_empty():
		# Nothing inside would do: the rest of this wave comes from outside.
		if want_inside:
			_floors.clear()
		return
	var pick: Vector3 = commander.sectors.safest(good)
	_note(pick, true)
	_spawn_at(pick, inside)


func _spawn_at(feet: Vector3, inside: int) -> void:
	# What the commander asked for: its weapon and its health (UnitCatalog).
	var kind: StringName = _queue.pop_front() if not _queue.is_empty() else &"rifleman"
	var unit := UnitCatalog.get_unit(kind)
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(city._gun_library,
			city._combat_rng.randi(), WeaponClass.builtin(StringName(unit.weapon)), 1))
	var so := Soldier.spawn(city.ai_services, city, feet + Vector3.UP * 0.02, ENEMY_TEAM, gun)
	so.aim.reaction = AIM_REACTION
	so.aim.cone_start = AIM_CONE_START
	so.aim.cone_min = AIM_CONE_MIN
	so.aim.settle = AIM_SETTLE
	so.set_meta(&"unit", kind)
	so.max_health = UnitCatalog.apply_health(so.pawn.health, kind, level)
	so.set_type(str(unit.get("recipe", "")), Roster.shared())
	# In its hands where it can be seen: its muzzle flash and its tracers are
	# how the player tells who is shooting and from where.
	gun.visible = not so.no_gun
	gun.position = Vector3(0.2, -0.28, -0.3)
	so.pawn.gun.fired.connect(_on_soldier_fired.bind(so))
	var p := _player()
	if p != null:
		var to := p.feet() - feet
		so.pawn.intents.look_yaw = atan2(-to.x, -to.z)
	city.soldiers.append(so)
	alive.append(so)
	so.pawn.health.died.connect(_on_soldier_died.bind(so))
	var under := survey.what_is_under(feet)
	if inside >= 0:
		_put_inside += 1
	spawned.append({"feet": feet, "inside": inside, "on": int(under.on), "wave": wave,
			"soldier": so, "frame": Engine.get_physics_frames(), "drop": NAN, "unit": kind})
	_left_to_spawn -= 1
	# Into this reinforcement's squad, and under the commander.
	if _wave_squad == null or not is_instance_valid(_wave_squad):
		_wave_squad = Squad.make(city.ai_services, city, [so] as Array[Soldier], ENEMY_TEAM)
		commander.adopt(_wave_squad)
		# The tank goes at this squad's pace, and they screen it (AIVehicles.md 4).
		if tank != null and is_instance_valid(tank) and not tank.is_wrecked():
			(tank.get_node(^"TankBrain") as TankBrain).escort = _wave_squad
	else:
		_wave_squad.add(so)
		commander.joined(_wave_squad, so)


## How far each new soldier dropped in its first ticks -- before it has walked
## anywhere, so a drop is what it was put on giving way under it.
func _settle_check() -> void:
	var f := Engine.get_physics_frames()
	for i in range(spawned.size() - 1, -1, -1):
		var s: Dictionary = spawned[i]
		if f - int(s.frame) > SETTLE_TICKS + 30:
			break
		if not is_nan(float(s.drop)) or f - int(s.frame) < SETTLE_TICKS:
			continue
		if not is_instance_valid(s.soldier):
			continue
		var so: Soldier = s.soldier
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn):
			var now_at := so.pawn.feet()
			var at: Vector3 = s.feet
			# One that has walked off is not one that sank: its brain starts on
			# its first tick, and a step down a kerb in half a second is a walk.
			s.drop = 0.0 if Vector2(now_at.x - at.x, now_at.z - at.z).length() > 0.4 else at.y - now_at.y


func _on_soldier_died(so: Soldier) -> void:
	kills += 1
	alive.erase(so)
	# Gone at once, in a burst of its own colour: a body that stood where it
	# died read as a soldier still standing there.
	feedback.burst(so.pawn.feet(), Color(0.75, 0.25, 0.2))
	last_dead_id = so.pawn.body.get_instance_id()
	city.ai_services.pawns.erase(so.pawn)
	city.soldiers.erase(so)
	if so._path_id >= 0:
		city.ai_nav.release(so._path_id)
	so.pawn.body.call_deferred("queue_free")
	if _left_to_spawn <= 0 and alive.is_empty():
		print("[arena] all down after reinforcement %d, %d kill(s)" % [wave, kills])


## A soldier's round: what struck the player is shown, and from where.
func _on_soldier_fired(info: Dictionary, so: Soldier) -> void:
	var p := _player()
	if info.is_empty() or info.get("result") == null or p == null:
		return
	if info.get("collider") == p.body and is_instance_valid(so):
		var r: DamageSystem.DamageResult = info.result
		feedback.player_hurt(r.dealt, so.eye_pos())


## The player's round: the marks, and the noise -- it is heard where it is fired.
func _on_player_fired(info: Dictionary) -> void:
	feedback.on_player_shot(info)
	# And the commander's read on the player: range, hits, kills, what it breaks.
	var p := _player()
	if p == null or info.is_empty():
		return
	var r = info.get("result")
	commander.profile.note_shot(r != null, p.eye.global_position.distance_to(info.point),
			r != null and r.killed, 1 if bool(info.get("structure", false)) else 0)


## A rough fix on the player for the side: TIP_SPREAD out, and TIP_AGE old.
func _tip() -> void:
	var p := _player()
	if p == null or p.health.is_dead():
		return
	var a := _rng.randf() * TAU
	var off := Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(0.0, TIP_SPREAD)
	var at: Vector3 = city.ai_nav.snap(p.feet() + off)
	city.ai_services.knowledge_of(ENEMY_TEAM).heard(p, at, _now() - TIP_AGE)


func _reap(_now_s: float) -> void:
	# Anyone who fell out of the world is dead too.
	for so in alive.duplicate():
		if not is_instance_valid(so) or so.pawn == null or not is_instance_valid(so.pawn):
			alive.erase(so)
		elif so.pawn.feet().y < -60.0:
			so.pawn.health.apply_impact(1e9, &"")


func _player_tick(now: float) -> void:
	var p := _player()
	if p == null:
		return
	if invulnerable and p.health.total_current() < 50.0:
		p.health.reset()
	if _player_dead_at >= 0.0 and now - _player_dead_at >= PLAYER_RESPAWN:
		_player_dead_at = -1.0
		p.health.reset()
		p.place(_street_of(focus) + Vector3.UP * 0.3)
		print("[arena] player back in at %v" % p.feet())


func _on_player_died() -> void:
	# A gate's player does not go down: one grenade takes more than the top-up
	# in _player_tick catches.
	if invulnerable:
		var p := _player()
		if p != null:
			p.health.reset()
			return
	# Down already: more hits on the body do not put the respawn off.
	if _player_dead_at >= 0.0:
		return
	_player_dead_at = _now()
	print("[arena] player down on wave %d" % wave)


# --- the focus --------------------------------------------------------------------

## The focus is no longer somewhere to stand: move the fight to the nearest
## building that is.
func _check_focus() -> void:
	if focus < 0 or Engine.get_physics_frames() % 15 != 0:
		return
	var fit := survey.building_fit(focus)
	if bool(fit.ok) or fit.why == "not bricks yet":
		return
	var b: BuildingRegistry.Building = city.registry.get_building(focus)
	var here: Vector3 = city._world_box(b).get_center()
	var was := focus
	var next := _pick_focus(here, was)
	if next < 0:
		return
	focus = next
	focus_changes += 1
	_hold(focus)
	_floors.clear()
	_next_survey = 0.0
	_last_move = "building %d: %s -- the fight moves to building %d" % [was, fit.why, focus]
	print("[arena] " + _last_move)


## The standing tower nearest `near` that survey calls fit or that is not bricks
## yet (the encounter will make it so), skipping `not_id`.
func _pick_focus(near: Vector3, not_id: int) -> int:
	var best := -1
	var best_d := INF
	for b in city.registry.buildings:
		if b.id == not_id or b.toppled or b.is_build():
			continue
		var fit := survey.building_fit(b.id)
		if not bool(fit.ok) and fit.why != "not bricks yet":
			continue
		var c: Vector3 = city._world_box(b).get_center()
		var d := Vector2(c.x - near.x, c.z - near.z).length()
		if d < best_d:
			best_d = d
			best = b.id
	return best


func _hold(id: int) -> void:
	var b: BuildingRegistry.Building = city.registry.get_building(id)
	var zone: AABB = city._world_box(b).grow(ZONE_MARGIN)
	# The old encounter lets go of its buildings; this one takes the new zone.
	if _encounter != null:
		city._encounters.erase(_encounter)
	_encounter = city.start_encounter(zone)
	# The focus itself first, now: its floors are what the next wave needs.
	city._promote(id, false)
	_breach(id)


func _resurvey() -> void:
	_next_survey = _now() + RESURVEY_EVERY
	_floors = survey.floors_of(focus)
	for f in _floors:
		_note(f, true)


## A point in the street in front of building `id`, on the ground.
func _street_of(id: int) -> Vector3:
	var b: BuildingRegistry.Building = city.registry.get_building(id)
	var fx: float = b.recipe.footprint_x * BrickWorld.get_stud_metres()
	var fz: float = b.recipe.footprint_z * BrickWorld.get_stud_metres()
	# The middle of the street off each face in turn, -Z first: a street is
	# nine studs (3.2 m), so any further out is the next building's footprint.
	var faces := [Vector3(fx * 0.5, 0.0, -STREET_OUT), Vector3(fx * 0.5, 0.0, fz + STREET_OUT),
			Vector3(-STREET_OUT, 0.0, fz * 0.5), Vector3(fx + STREET_OUT, 0.0, fz * 0.5)]
	for f in faces:
		var p: Vector3 = b.xform * f
		p.y = city.ai_world.ground_at(p.x, p.z)
		var q: Vector3 = city.ai_nav.snap(p)
		if city.ai_nav.can_stand(q) and not _in_a_building(q):
			return q
	var p0: Vector3 = b.xform * faces[0]
	p0.y = city.ai_world.ground_at(p0.x, p0.z)
	return p0


## Inside some building's footprint -- its shell or its bricks.
func _in_a_building(p: Vector3) -> bool:
	for id in city._near_buildings(p, 0.5):
		var b: BuildingRegistry.Building = city.registry.get_building(id)
		if b == null or b.toppled:
			continue
		var box: AABB = city._world_box(b)
		if p.x > box.position.x and p.x < box.end.x and p.z > box.position.z and p.z < box.end.z:
			return true
	return false


## A doorway blown in the middle of each face at street level. A tower is sealed
## (Docs/AI.md 3.8: the way in is made, not found), and soldiers put on its
## floors have to be able to come out -- and the player to go in after them.
func _breach(id: int) -> void:
	var b: BuildingRegistry.Building = city.registry.get_building(id)
	if b == null or _breached.has(id):
		return
	_breached[id] = true
	var fx: float = b.recipe.footprint_x * BrickWorld.get_stud_metres()
	var fz: float = b.recipe.footprint_z * BrickWorld.get_stud_metres()
	for f in [Vector3(fx * 0.5, 1.0, 0.2), Vector3(fx * 0.5, 1.0, fz - 0.2),
			Vector3(0.2, 1.0, fz * 0.5), Vector3(fx - 0.2, 1.0, fz * 0.5)]:
		city._blast(b.xform * f, DOOR_RADIUS)


func _ground_under(p: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.0, p - Vector3.UP * 3.0,
			Layers.PAWN_MASK)
	return not city.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# --- the gate -----------------------------------------------------------------------

## `-- --arena --gate`: a wave comes in and every soldier is where the survey
## said, standing on what it said; a floor shot out from under a spot refuses
## it; the focus brought down is left, and the next wave puts nobody in it.
func run_gate() -> void:
	var ok: Callable = city._gate_ok
	print("[arena] gate: waves in and round building %d" % focus)
	ok.call("a focus building was found and the player stands in its street",
			focus >= 0 and _player() != null, "focus %d" % focus)
	ok.call("the focus has floors to stand on", not _floors.is_empty(),
			"refused %s" % [survey.refused])
	if focus < 0:
		return
	# The first reinforcement, all of it: the commander's to send.
	commander.force_reinforce()
	await _until(func() -> bool: return wave >= 1 and _left_to_spawn <= 0, 30.0)
	var first := _of_wave(1)
	var n_in := 0
	var n_out := 0
	var wrong := []
	for s in first:
		if int(s.inside) >= 0:
			n_in += 1
			if int(s.on) != SpawnSurvey.On.BUILDING or int(s.inside) != focus:
				wrong.append(s)
		else:
			n_out += 1
			if int(s.on) != SpawnSurvey.On.GROUND and int(s.on) != SpawnSurvey.On.WRECK:
				wrong.append(s)
	ok.call("wave 1 comes in: %d on the building's floors, %d round it" % [n_in, n_out],
			first.size() == BASE and n_in > 0 and n_out > 0, "%d spawned" % first.size())
	# The commander's: one squad, under it, of units the game has.
	var sq: Squad = null
	var one_squad := true
	var built_only := true
	for sp in first:
		if not is_instance_valid(sp.soldier):
			continue
		var so: Soldier = sp.soldier
		if sq == null:
			sq = so.squad
		if so.squad == null or so.squad != sq:
			one_squad = false
		if not bool(UnitCatalog.get_unit(StringName(sp.get("unit", &"rifleman"))).built):
			built_only = false
	ok.call("the reinforcement is one squad, under the commander, of units the game has",
			one_squad and sq != null and commander.squads.has(sq) and built_only,
			"%s" % [first.map(func(sp): return sp.get("unit", "?"))])
	ok.call("each one on what the survey said it would be", wrong.is_empty(),
			"%s" % [wrong.map(func(s): return "%v on %s" % [s.feet, SpawnSurvey.ON_NAMES[s.on]])])
	await _frames(SETTLE_TICKS + 2)
	var fell := []
	for s in first:
		if is_nan(float(s.drop)) or float(s.drop) > 0.3:
			fell.append("%v dropped %.2f" % [s.feet, float(s.drop)])
	ok.call("nobody sinks into or falls through what they were put on",
			fell.is_empty(), ", ".join(fell))
	# They were sent at the player: somebody finds them and fires.
	await _until(func() -> bool:
		return first.any(func(s): return is_instance_valid(s.soldier) and (s.soldier as Soldier).shots > 0),
		40.0)
	var shots := 0
	for s in first:
		if is_instance_valid(s.soldier):
			shots += (s.soldier as Soldier).shots
	ok.call("the wave hunts the player and fires at it", shots > 0, "%d round(s)" % shots)
	# They move: off their spawn point, to cover, across the line in the open.
	await _frames(300)
	var moved := []
	var stayed := []
	for sp in first:
		if not is_instance_valid(sp.soldier):
			continue
		var so: Soldier = sp.soldier
		if so.is_dead():
			continue
		# Metres walked since it appeared, not how far it is from there now: a
		# soldier that ran to cover and back out to fight can be standing a
		# metre from its spawn point having gone thirty.
		var walked := float(travelled.get(so.get_instance_id(), 0.0))
		# Standing still is fine in cover that happened to be next to where it
		# appeared; standing still anywhere else is what this is here to catch.
		if walked > 3.0 or so.state in ["hide", "peek", "reload in cover"]:
			moved.append("%.1f m, %s" % [walked, so.state])
		else:
			stayed.append("%.1f m, %s" % [walked, so.state])
	ok.call("they move: %d of %d walked more than 3 m or are working a cover spot" % [
			moved.size(), moved.size() + stayed.size()],
			moved.size() * 4 >= (moved.size() + stayed.size()) * 3,
			"moved %s, stayed %s" % [moved, stayed])
	# Each squad has an order -- or is already on the enemy, where an advance
	# has nothing to add and the commander leaves it to fight.
	var unled := []
	var ck: FactionKnowledge.Contact = city.ai_services.knowledge_of(ENEMY_TEAM).best(_now())
	for q in commander.squads:
		if not is_instance_valid(q) or q.alive().is_empty() or q.order != null or q.broken:
			continue
		if ck == null or q.center().distance_to(ck.pos) >= Commander.ADVANCE_FROM:
			unled.append(q.id)
	ok.call("the commander leaves no squad without a purpose", unled.is_empty(),
			"squads %s with no order and away from the fight; orders %s; %s" % [unled,
			commander.orders_given, commander.log.slice(maxi(commander.log.size() - 4, 0))])
	# And the player's gun works on them, and says so: fire at whoever is in
	# sight until one drops.
	await _until(func() -> bool: return _soldier_in_sight() != null, 20.0)
	var marks := feedback.hits
	var numbers := feedback.numbers_shown
	var sounds0 := feedback.sounds_played
	var kills0 := feedback.kills_shown
	var t_fire := _now()
	var target := _soldier_in_sight()
	if target != null:
		var shot_hit := false
		_mouse(true)
		# A veteran (3 melees of armor over 1 of flesh) takes ~29 rifle rounds: time for them.
		while feedback.kills_shown == kills0 and _now() - t_fire < 20.0:
			var t := _soldier_in_sight()
			if t != null:
				city.camera.look_at(t.pawn.chest(), Vector3.UP)
			await get_tree().physics_frame
			if feedback.hits - marks == 2 and not shot_hit and DirAccess.dir_exists_absolute("res://shots"):
				shot_hit = true
				await city._save("arena_hit")
		_mouse(false)
		ok.call("the player's gun kills a soldier", feedback.kills_shown > kills0,
				"%d hit(s) in %.1f s" % [feedback.hits - marks, _now() - t_fire])
		ok.call("and makes a sound", feedback.sounds_played > sounds0,
				"%d sound(s)" % (feedback.sounds_played - sounds0))
		ok.call("each hit shows a hitmarker and a number",
				feedback.hits > marks and feedback.numbers_shown - numbers == feedback.hits - marks,
				"%d marker(s), %d number(s)" % [feedback.hits - marks, feedback.numbers_shown - numbers])
		await _frames(3)
		ok.call("the dead soldier is gone, not standing where it died",
				last_dead_id != 0 and instance_from_id(last_dead_id) == null)
		await _frames(10)
		if DirAccess.dir_exists_absolute("res://shots"):
			await city._save("arena_fight")
	else:
		ok.call("a soldier comes into the player's sight", false)

	# From here the gate blows floors out and a building down and kills the
	# wave by hand: not the soldiers' decisions, so not judged.
	(city.ai_services.judge as DecisionJudge).pause()
	# A floor shot out from under a spot: the spot is refused.
	var spots := survey.floors_of(focus)
	if not spots.is_empty():
		# A spot the survey takes now (bricks and physics both), from the middle
		# of the list out.
		@warning_ignore("integer_division")
		var f: Vector3 = spots[spots.size() / 2]
		for i in spots.size():
			@warning_ignore("integer_division")
			var g: Vector3 = spots[(spots.size() / 2 + i) % spots.size()]
			if bool(survey.check(g, focus, null, []).ok):
				f = g
				break
		var before := survey.check(f, focus, null, [])
		city._blast(f - Vector3.UP * 0.1, 1.2)
		await _frames(45)
		var after := survey.check(f, focus, null, [])
		ok.call("a spot on the floor is good, then refused once the floor is blown out",
				bool(before.ok) and not bool(after.ok),
				"before %s, after %s" % [before, after])
		var again := survey.floors_of(focus)
		var near := 0
		for g in again:
			if Vector2(g.x - f.x, g.z - f.z).length() < 0.6 and absf(g.y - f.y) < 0.3:
				near += 1
		ok.call("and the survey no longer finds a floor there", near == 0,
				"%d spot(s) still at %v" % [near, f])

	# Bring the focus down: its ground storey blown out, a ring of big blasts.
	var old := focus
	var b: BuildingRegistry.Building = city.registry.get_building(old)
	var box: AABB = city._world_box(b)
	print("[arena] gate: bringing building %d down" % old)
	var tries := 0
	while bool(survey.building_fit(old).ok) and tries < 16:
		for k in 8:
			var t := float(k) / 8.0
			var edge := box.position + Vector3(box.size.x * t, 0.0, 0.0) if tries % 2 == 0 \
					else box.position + Vector3(0.0, 0.0, box.size.z * t)
			var other := edge + (Vector3(0.0, 0.0, box.size.z) if tries % 2 == 0
					else Vector3(box.size.x, 0.0, 0.0))
			for p in [edge, other]:
				city._blast(Vector3(p.x, box.position.y + 1.0 + (tries % 3) * 1.2, p.z),
						city.BIG_BLAST)
		tries += 1
		await _frames(30)
	var gone := survey.building_fit(old)
	ok.call("building %d is no longer fit to spawn in" % old, not bool(gone.ok),
			"%s after %d round(s) of blasts, %.0f%% standing" % [gone.why, tries,
			survey.integrity(old) * 100.0])
	await _until(func() -> bool: return focus != old, 5.0)
	ok.call("the fight moves to another building", focus != old and focus >= 0,
			"focus %d" % focus)
	# Clear the wave and take the next one.
	for so in alive.duplicate():
		so.pawn.health.apply_impact(1e9, &"")
	var w := wave
	await _frames(2)
	(city.ai_services.judge as DecisionJudge).resume()
	await _frames(2)
	commander.force_reinforce()
	await _until(func() -> bool: return wave > w and _left_to_spawn <= 0, 40.0)
	var second := _of_wave(w + 1)
	var in_old := second.filter(func(s): return int(s.inside) == old)
	ok.call("wave %d comes in (%d) and puts nobody in the fallen building" % [w + 1, second.size()],
			second.size() > 0 and in_old.is_empty(),
			"%d in building %d; commander: radio %s, officer %s, budget %.1f, %d up of %d, log %s" % [
			in_old.size(), old, commander.radio_up, commander.commander_up, commander.budget,
			alive.size(), ALIVE_CAP, commander.log.slice(maxi(commander.log.size() - 4, 0))])
	var in_new := second.filter(func(s): return int(s.inside) >= 0)
	ok.call("its inside spawns are on the new focus's floors",
			in_new.all(func(s): return int(s.inside) == focus and int(s.on) == SpawnSurvey.On.BUILDING),
			"%s" % [in_new.map(func(s): return [s.inside, SpawnSurvey.ON_NAMES[s.on]])])
	await _frames(SETTLE_TICKS + 2)
	var sank := second.filter(func(s): return is_nan(float(s.drop)) or float(s.drop) > 0.3)
	ok.call("and none of them sinks into what it was put on", sank.is_empty(),
			"%s" % [sank.map(func(s): return [s.feet, s.drop])])
	# The engage decision: logged, varied, never crouching, and a stuck soldier
	# calls for help.
	var d: Array[Dictionary] = city.ai_services.decisions
	var kinds := {}
	for e in d:
		kinds[int(e.tactic)] = true
	ok.call("soldiers face to face with the player decide what to do: %d decision(s), %d kind(s)"
			% [d.size(), kinds.size()],
			d.size() > 0 and kinds.size() >= 2 and (d[0].obs as PackedFloat32Array).size() == CombatPolicy.Obs.COUNT)
	ok.call("nobody crouches", _crouched == 0, "%d tick(s) crouched" % _crouched)
	var judged := (city.ai_services.judge as DecisionJudge).episodes
	var all_scored := judged.size() > 0
	for e in judged:
		if not is_finite(float(e.reward)) or not (e.verdict in ["stupid", "good", "neutral"]):
			all_scored = false
	var logged_reward := d.any(func(e): return e.has("reward"))
	ok.call("every call is judged: %d with a reward and a verdict" % judged.size(),
			all_scored and logged_reward)
	print_judgement()
	var pair := alive.slice(0, 2)
	if pair.size() == 2:
		var caller: Soldier = pair[0]
		var buddy: Soldier = pair[1]
		# A buddy free to come: searching, not stuck or cut off itself.
		buddy.state = "search"
		buddy._called_help_at = -INF
		buddy.trapped = false
		buddy.help_point = Vector3.INF
		# And a caller that is not itself off helping someone (it would give
		# that up rather than call).
		caller.help_point = Vector3.INF
		caller._called_help_at = -INF
		# Near enough to hear it, and the call judged by what it did -- the
		# display rate-limits repeated lines, so a count of shown lines is not.
		# Beside it, on its floor -- a snap can land on the ground floor of the
		# building, thirty metres down and out of earshot.
		buddy.pawn.place(caller.pawn.feet() + Vector3(0.8, 0.0, 0.0))
		var at := caller.pawn.feet()
		var t_call := _now()
		caller.call_for_help()
		ok.call("a stuck soldier shouts for help and a buddy comes",
				is_equal_approx(caller._called_help_at, t_call) and buddy.help_point.distance_to(at) < 0.5,
				"called at %.2f (now %.2f), help at %v, caller at %v" % [caller._called_help_at, t_call,
				buddy.help_point, at])
	ok.call("the player hears what they say", heard_ticks > 0,
			"%d tick(s) with a line up; said %s" % [heard_ticks, _said_keys()])

	# The player takes to a room of the focus: the commander sends a squad in.
	# A squad strong enough to clear one first (Commander.CLEAR_WITH): what is
	# left of the fight so far may be twos, and twos are not sent into rooms.
	(city.ai_services.judge as DecisionJudge).pause()
	for so in alive.duplicate():
		so.pawn.health.apply_impact(1e9, &"")
	await _frames(3)
	(city.ai_services.judge as DecisionJudge).resume()
	commander.budget = Commander.BUDGET_CAP
	commander.force_reinforce(&"foot")
	# And nothing more to spend until the truck below is asked for: with the
	# rest of a full budget the commander sent a truck of its own during the
	# clear, and the truck this pass sends drove into it six metres from the
	# same start.
	commander.budget = 0.0
	await _until(func() -> bool: return _left_to_spawn <= 0 and alive.size() >= Commander.CLEAR_WITH, 30.0)
	var spot := _room_spot()
	var cleared0 := int(commander.orders_given.get("CLEAR_ROOM", 0))
	var stacked := false
	if spot != Vector3.INF:
		_player().place(spot)
		# It fires from in there, and is heard: the side knows the room, not a
		# rough fix eight metres off.
		await _frames(2)
		var me := _player()
		# And keeps firing, as a player holed up does: heard every couple of
		# seconds, the contact stays fresh while the commander decides.
		for k in 15:
			city.ai_services.noise(me.eye.global_position, 40.0, me)
			if int(commander.orders_given.get("CLEAR_ROOM", 0)) > cleared0:
				break
			await _frames(60)
		# A minute and a half: the room is one well inside the building now, and
		# a squad on its way to the door at sixty seconds was counted as one
		# that never got there.
		await _until(func() -> bool:
			return commander.squads.any(func(q): return is_instance_valid(q) and q.events.has("stacked")),
			90.0)
		stacked = commander.squads.any(func(q): return is_instance_valid(q) and q.events.has("stacked"))
	var known: FactionKnowledge.Contact = city.ai_services.knowledge_of(commander.team).best(_now())
	ok.call("the player in a room: the commander sends a squad in to clear it",
			int(commander.orders_given.get("CLEAR_ROOM", 0)) > cleared0,
			"room spot %v; player at %v; contact %s; squads of %s; %s" % [spot,
			_player().feet() if _player() != null else Vector3.INF,
			("at %v, %.1f s old, in a room: %s" % [known.pos, known.age(_now()),
			not CityRooms.at(city, known.pos).is_empty()]) if known != null else "none",
			commander.squads.map(func(q): return q.alive().size() if is_instance_valid(q) else -1),
			commander.log.slice(maxi(commander.log.size() - 5, 0))])
	# Either it gets to the door, or it says it cannot (a city tower's slots
	# can all be walled off) and the commander hears so -- never silence.
	# Or the clear came to an end and said why (Commander._clearing emptied by
	# the squad's report): never a squad stood at a door for good.
	var concluded := commander._clearing.is_empty() \
			and int(commander.orders_given.get("CLEAR_ROOM", 0)) > cleared0
	ok.call("and the squad stacks on the way in -- or reports why it cannot",
			stacked or concluded, _clear_detail())
	print("[arena] room clear: %s" % ("stacked" if stacked else "could not stack, reported"))

	# A squad by truck: it drives in from out past the fight and lets them out
	# on the side away from the player.
	(city.ai_services.judge as DecisionJudge).pause()
	for so in alive.duplicate():
		so.pawn.health.apply_impact(1e9, &"")
	await _frames(3)
	(city.ai_services.judge as DecisionJudge).resume()
	commander.budget = Commander.BUDGET_CAP
	var sent := commander.force_reinforce(&"truck")
	# Nothing left over: a second squad sent on the change, by truck from the
	# same start or on foot, is in this one's way and in its count.
	commander.budget = 0.0
	var truck: TransportTruck = trucks.back() if not trucks.is_empty() else null
	ok.call("the commander sends a squad by truck", sent and truck != null,
			"%s" % [commander.log.slice(maxi(commander.log.size() - 2, 0))])
	if truck != null:
		var t0 := truck.global_position
		var up0 := alive.size()
		await _until(func() -> bool: return truck.state != "driving", 60.0)
		await _frames(10)
		var drove := truck.global_position.distance_to(t0)
		ok.call("it drives in and lets them out", truck.state == "arrived" and truck.cargo.is_empty()
				and alive.size() - up0 >= 2 and drove > 10.0,
				"%s (%s), drove %.0f m, %d out; against %s; path %d pts" % [truck.state,
				truck.stopped_because, drove, alive.size() - up0, truck.stuck_on, truck._path.size()])
		var me := _player()
		var lee := 0
		var got_out := alive.slice(up0)
		for so in got_out:
			# The far side of the truck from the player.
			if (so.pawn.feet() - truck.global_position).dot(me.feet() - truck.global_position) < 0.0:
				lee += 1
		ok.call("on the side away from the player", got_out.size() > 0 and lee * 2 >= got_out.size(),
				"%d of %d in its lee" % [lee, got_out.size()])
		# A second truck, shot to pieces on the way: its squad dies with it.
		# Nothing to spend while the field is cleared: with a full budget the
		# commander could send a squad on foot in the frames before the truck is
		# asked for, and those soldiers were then counted against the truck's.
		commander.budget = 0.0
		var lost0 := commander.lost_points
		var up1 := alive.size()
		for so in alive.duplicate():
			so.pawn.health.apply_impact(1e9, &"")
		await _frames(3)
		lost0 = commander.lost_points
		up1 = alive.size()
		commander.budget = Commander.BUDGET_CAP
		var second_sent := commander.force_reinforce(&"truck")
		commander.budget = 0.0
		if second_sent:
			var second_truck: TransportTruck = trucks.back()
			await _frames(30)
			second_truck.health.apply_impact(1e9, &"")
			await _frames(5)
			ok.call("a truck shot to pieces takes its squad with it",
					alive.size() == up1 and commander.lost_points >= lost0 + UnitCatalog.points(&"truck") + 2.0,
					"%d up (was %d); lost %.1f -> %.1f pts" % [alive.size(), up1, lost0, commander.lost_points])

	# The HQ: shoot the radio and nobody can be called; kill the officer and
	# nothing more is decided.
	ok.call("the commander has an HQ: an officer and a radio in building %d" % hq_building,
			hq_officer != null and is_instance_valid(hq_officer) and hq_radio != null)
	if hq_radio != null and is_instance_valid(hq_radio):
		(hq_radio.get_node("HealthPool") as HealthPool).apply_impact(1e9, &"")
		await _frames(3)
		ok.call("the radio shot out: no more reinforcements can be called",
				not commander.radio_up and not commander.force_reinforce(),
				"radio %s" % commander.radio_up)
	if hq_officer != null and is_instance_valid(hq_officer):
		hq_officer.pawn.health.apply_impact(1e9, &"")
		await _frames(3)
		var given := commander.log.size()
		await _frames(120)
		# Decisions, not the squads' reports still coming in to a dead man.
		var after := commander.log.slice(given).filter(func(l: String) -> bool:
			return not (": order " in l))
		ok.call("the officer killed: the commander decides nothing more",
				not commander.commander_up and after.is_empty(), "%s" % [after])

	# The player goes down and comes back in the street.
	invulnerable = false
	var p := _player()
	p.health.apply_impact(1e9, &"")
	var down := p.health.is_dead()
	await _until(func() -> bool: return not p.health.is_dead(), PLAYER_RESPAWN + 2.0)
	ok.call("the player goes down and is put back in the street",
			down and not p.health.is_dead() and not _in_a_building(p.feet()),
			"dead %s, now %s at %v" % [down, p.health.is_dead(), p.feet()])
	invulnerable = true
	print("[arena] refused on the way: %s" % [survey.refused])


## The left button, as the OS would press it: PlayerController reads the
## button every frame, so a trigger set any other way is let go at once.
func _mouse(down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	Input.parse_input_event(e)


## A living soldier the player's eye has a clear line to, or null.
func _soldier_in_sight() -> Soldier:
	var p := _player()
	if p == null:
		return null
	var eye: Vector3 = city.camera.global_position
	for so in alive:
		if so.is_dead():
			continue
		var q := PhysicsRayQueryParameters3D.create(eye, so.pawn.chest(), Layers.HITSCAN_MASK,
				[p.body.get_rid(), so.pawn.body.get_rid()] as Array[RID])
		if city.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
			return so
	return null


## `-- --arena --watch`: what the soldiers do, second by second, for a
## wave against a player who stands still.
func run_watch() -> void:
	commander.force_reinforce()
	var last := {}
	var moved := {}
	var states := {}
	for sec in 30:
		await _frames(30)
		var line := "t%02d" % sec
		for so in alive:
			var k := so.get_instance_id()
			var f := so.pawn.feet()
			if last.has(k):
				moved[k] = float(moved.get(k, 0.0)) + Vector2(f.x - last[k].x, f.z - last[k].z).length()
			last[k] = f
			states[so.state] = int(states.get(so.state, 0)) + 1
			var c := so.contact()
			line += " | %s/%s %.1fm vis %s path %d/%d st %d" % [
					CombatPolicy.TACTIC_NAMES[so.tactic] if so.tactic >= 0 else "-", so.state,
					float(moved.get(k, 0.0)),
					c.visible if c != null else false, so._wp, so._path.size(),
					city.ai_nav.get_status(so._path_id) if so._path_id >= 0 else -9]
		print(line)
	var chosen := {}
	for d in city.ai_services.decisions:
		var n: String = CombatPolicy.TACTIC_NAMES[int(d.tactic)]
		chosen[n] = int(chosen.get(n, 0)) + 1
	print("[watch] tactics chosen %s" % [chosen])
	print("[watch] lines said %s" % [_said_keys()])
	print("[watch] commander: %s" % [commander.orders_given])
	for l in commander.log:
		print("[watch]   " + l)
	print_judgement()
	print("[watch] states %s" % [states])
	print("[watch] metres moved %s" % [moved.values()])


## The engage decisions taken, as JSON lines (`-- --log-decisions=PATH`): the
## imitation data a model is first trained on (CombatPolicy, AI.md 11.3). One
## header line with the contract, then {t, who, obs, tactic, policy} each.
func write_decisions(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[arena] cannot write %s" % path)
		return 0
	f.store_line(JSON.stringify({"contract": CombatPolicy.CONTRACT}))
	for d in city.ai_services.decisions:
		f.store_line(JSON.stringify({"t": d.t, "who": d.who, "obs": Array(d.obs),
				"tactic": d.tactic, "policy": d.policy, "reward": d.get("reward"),
				"flags": d.get("flags", []), "outcome": d.get("outcome", {}), "book": d.get("book")}))
	f.close()
	print("[arena] %d decision(s) written to %s" % [city.ai_services.decisions.size(), path])
	return city.ai_services.decisions.size()


func _exit_tree() -> void:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--log-decisions="):
			write_decisions(a.split("=", true, 1)[1])


## The judge's table: per tactic, how many, mean reward, how many stupid.
func print_judgement() -> void:
	var sm := (city.ai_services.judge as DecisionJudge).summary()
	print("[judge] %d decision(s) judged" % sm.episodes)
	for n in sm.tactics:
		var b: Dictionary = sm.tactics[n]
		print("[judge]   %-13s %3d  mean %+6.1f  stupid %2d  good %2d" % [n, b.n, b.mean,
				b.stupid, b.good])
	print("[judge]   flags %s" % [sm.flags])


## What each squad clearing a room is doing, member by member, for a failed check.
func _clear_detail() -> String:
	var out := []
	for q in commander.squads:
		if not is_instance_valid(q):
			continue
		var parts := []
		for m in q.alive():
			var asg := m.assignment
			parts.append("%s/%s R%s B%s d%.1f stuck%d path%d/%d nav%d" % [m.state,
					(SquadMsg.Task.keys()[asg.task] + ":" + asg.role) if asg else "-",
					q.replied(m, SquadMsg.StatusKind.REACHED), q.replied(m, SquadMsg.StatusKind.BLOCKED),
					m.pawn.feet().distance_to(asg.point) if asg else -1.0, m.stuck, m._wp, m._path.size(),
					city.ai_nav.get_status(m._path_id)])
		out.append("squad %d %s %s [%s]" % [q.id, q.play, q.events.keys(), "; ".join(parts)])
	return " || ".join(out)


# --- the HQ -------------------------------------------------------------------------

## The commander's HQ (Commander, Docs/AI.md 9): its officer on the top floor of
## the nearest other standing building, holding there, and its radio beside him.
## Shoot the radio and nobody can be called in; kill the officer and nothing more
## is decided. A building that comes down with the HQ in it takes the radio.
func _set_up_hq() -> void:
	var here: Vector3 = city._world_box(city.registry.get_building(focus)).get_center()
	var best := -1
	var best_d := HQ_WITHIN
	for b in city.registry.buildings:
		if b.id == focus or b.toppled or b.is_build():
			continue
		if not bool(survey.building_fit(b.id).ok):
			continue
		var d: float = city._world_box(b).get_center().distance_to(here)
		# Not next door: what brings the focus down would bring the HQ with it.
		if d < HQ_CLEAR:
			continue
		if d < best_d:
			best_d = d
			best = b.id
	if best < 0:
		print("[arena] no building for an HQ within %.0f m" % HQ_WITHIN)
		return
	var spots := survey.floors_of(best)
	if spots.size() < 2:
		return
	# Top floor first; the radio a stride from him on the same floor.
	spots.sort_custom(func(x: Vector3, y: Vector3) -> bool: return x.y > y.y)
	var at: Vector3 = spots[0]
	var beside: Vector3 = spots[1]
	for s in spots:
		if absf(s.y - at.y) < 0.2 and s.distance_to(at) > 1.0 and s.distance_to(at) < 3.0:
			beside = s
			break
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(city._gun_library,
			city._combat_rng.randi(), WeaponClass.builtin(&"pistol"), 1))
	hq_officer = Soldier.spawn(city.ai_services, city, at + Vector3.UP * 0.02, ENEMY_TEAM, gun)
	hq_officer.set_meta(&"unit", &"officer")
	hq_officer.max_health = UnitCatalog.apply_health(hq_officer.pawn.health, &"officer", level)
	hq_officer.set_type(str(UnitCatalog.get_unit(&"officer").get("recipe", "")), Roster.shared())
	gun.visible = true
	gun.position = Vector3(0.2, -0.28, -0.3)
	# Gold, so he can be picked out from his men.
	for c in hq_officer.pawn.body.get_children():
		if c is MeshInstance3D:
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.95, 0.75, 0.2)
			(c as MeshInstance3D).material_override = m
	var hold := SquadMsg.Assignment.make(SquadMsg.Task.HOLD, at)
	hold.role = "HQ"
	hq_officer.set_assignment(hold)
	hq_officer.pawn.health.died.connect(_on_officer_died)
	hq_radio = _make_radio(beside)
	hq_building = best
	commander.hq = at
	print("[arena] HQ in building %d: officer at %v, radio at %v" % [best, at, beside])


## A radio set you can shoot: a box on the floor with an aerial, and health.
func _make_radio(at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Radio"
	# On the pawn layer: guns hit it (Layers.GUN_MASK), sight lines do not stop.
	body.collision_layer = Layers.PAWN
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.55, 0.8, 0.4)
	shape.shape = box
	shape.position = Vector3.UP * 0.4
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.36, 0.22)
	bm.material = mat
	mesh.mesh = bm
	mesh.position = Vector3.UP * 0.4
	body.add_child(mesh)
	var aerial := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.015
	cm.bottom_radius = 0.02
	cm.height = 1.3
	aerial.mesh = cm
	aerial.position = Vector3(0.18, 1.45, 0.0)
	body.add_child(aerial)
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = RADIO_HP
	pool.layer_configs = [layer]
	body.add_child(pool)
	city.add_child(body)
	body.global_position = at
	pool.died.connect(_on_radio_destroyed)
	return body


func _on_radio_destroyed() -> void:
	if hq_radio != null and is_instance_valid(hq_radio):
		feedback.burst(hq_radio.global_position, Color(0.3, 0.36, 0.22))
		hq_radio.call_deferred("queue_free")
	hq_radio = null
	commander.radio_destroyed()
	city.ai_services.say(hq_officer.pawn if hq_officer != null and is_instance_valid(hq_officer)
			and not hq_officer.is_dead() else null, "radio", "The radio's gone!", AIServices.SHOUT)


func _on_officer_died() -> void:
	if hq_officer == null or not is_instance_valid(hq_officer):
		return
	feedback.burst(hq_officer.pawn.feet(), Color(0.95, 0.75, 0.2))
	city.ai_services.pawns.erase(hq_officer.pawn)
	hq_officer.pawn.body.call_deferred("queue_free")
	commander.commander_killed()


## The HQ's building no longer stands: the radio goes with it.
func _check_hq() -> void:
	if hq_building < 0 or hq_radio == null or not is_instance_valid(hq_radio):
		return
	var fit := survey.building_fit(hq_building)
	if not bool(fit.ok) and fit.why != "not bricks yet":
		(hq_radio.get_node("HealthPool") as HealthPool).apply_impact(1e9, &"")


# --- trucks -------------------------------------------------------------------------

## A squad by truck (TransportTruck): from a start on open ground out past the
## fight, on the far side of it from the player, to the fight; its cargo is put
## down at the tailgate when it stops.
func _send_truck(kinds: Array[StringName]) -> bool:
	var t0 := Time.get_ticks_usec()
	var start := _truck_start()
	var took := float(Time.get_ticks_usec() - t0) / 1000.0
	if start == Vector3.INF:
		return false
	var goal: Vector3 = _street_of(focus)
	var to := goal - start
	var t := TransportTruck.make(city.ai_services, city, start, atan2(-to.x, -to.z))
	t.cargo = kinds.duplicate()
	t.arrived.connect(_dismount)
	t.wrecked.connect(_truck_wrecked)
	# Its rounds hit the truck like a body (it has a HealthPool): it shows.
	trucks.append(t)
	wave += 1
	commander.note_fielded(UnitCatalog.points(&"truck"))
	t.send(goal)
	print("[arena] reinforcement %d by truck: %s, from %v (road wide enough for %d%% of the way; found in %.0f ms)" % [wave,
			", ".join(kinds), start, roundi(_truck_road * 100.0), took])
	return true


## Open ground TRUCK_OUT metres out from the focus, away from the player, where
## a body stands and nothing is overhead.
func _truck_start() -> Vector3:
	var c: Vector3 = city._world_box(city.registry.get_building(focus)).get_center()
	var p := _player()
	var away := (c - p.feet()) if p != null else Vector3.FORWARD
	away.y = 0.0
	away = away.normalized() if away.length() > 0.1 else Vector3.FORWARD
	var goal: Vector3 = _street_of(focus)
	# The widest route found, if none is wide the whole way: the city's streets
	# are three metres, and a soldier's path hugs the walls of them.
	# ...and of those, the one a truck gets furthest along before it sticks: by
	# share alone it took a road wide for four fifths of its length and narrow
	# ten metres from the start, and let its squad out there.
	var best := Vector3.INF
	var best_share := -1.0
	var best_run := -1.0
	# Near the fight's own height: the foot map it drives climbs terraces a
	# course at a time, and wheels do not (a vehicle map is AIVehicles.md 3).
	# All the way round, closely, and at five distances: with the player inside the
	# focus "away" is any direction at all, and three rings of eight found no
	# start as often as not -- or only one whose road was too narrow, and the
	# truck stuck eight metres in.
	for out in [TRUCK_OUT, TRUCK_OUT * 0.85, TRUCK_OUT * 0.7, TRUCK_OUT * 0.55, TRUCK_OUT * 0.4]:
		for step in TRUCK_TURNS:
			# 0, +1, -1, +2, -2 ... steps round: away from the player first.
			var turn := float(ceili(step / 2.0)) * (TAU / float(TRUCK_TURNS)) * (1.0 if step % 2 == 1 else -1.0)
			var dir: Vector3 = away.rotated(Vector3.UP, turn)
			var q := c + dir * float(out)
			q.y = city.ai_world.ground_at(q.x, q.z)
			q = city.ai_nav.snap(q)
			if not city.ai_nav.can_stand(q) or _in_a_building(q) or absf(q.y - goal.y) > TRUCK_LEVEL:
				continue
			if survey.what_is_under(q).on != SpawnSurvey.On.GROUND:
				continue
			# Room to turn a truck round in.
			if not TransportTruck.room_at(city.get_world_3d(), q):
				continue
			# And a way from there to the fight -- not a beach below the tide line
			# -- wide enough for a truck all the way in.
			var route: PackedVector3Array = city.ai_nav.find_path(q, goal, 20000)
			if route.is_empty():
				continue
			var share := TransportTruck.route_width_share(city.get_world_3d(), route)
			if share >= 1.0:
				_truck_road = 1.0
				return q + Vector3.UP * 0.3
			var run := TransportTruck.route_clear_run(city.get_world_3d(), route)
			if run > best_run:
				best_run = run
				best_share = share
				best = q + Vector3.UP * 0.3
	_truck_road = maxf(best_share, 0.0)
	return best


func _dismount(t: TransportTruck) -> void:
	if t.cargo.is_empty():
		return
	var p := _player()
	var threat: Vector3 = p.feet() if p != null else t.global_position + Vector3.FORWARD
	var spots := t.tailgate_points(threat, t.cargo.size())
	_queue = t.cargo.duplicate()
	_left_to_spawn = _queue.size()
	_wave_size = _left_to_spawn
	_put_inside = 0
	_wave_squad = null
	var n := _queue.size()
	for i in n:
		var at: Vector3 = spots[i] if i < spots.size() else city.ai_nav.snap(t.global_position
				+ t.global_transform.basis.z * (TransportTruck.SIZE.z * 0.5 + 1.2 + i))
		_spawn_at(at, -1)
	t.cargo.clear()
	_tip()
	print("[arena] truck unloaded %d at %v" % [n, t.global_position])


func _truck_wrecked(t: TransportTruck) -> void:
	var lost := UnitCatalog.points(&"truck")
	for k in t.cargo:
		lost += UnitCatalog.points(k)
	if not t.cargo.is_empty():
		print("[arena] truck wrecked with %d aboard" % t.cargo.size())
	t.cargo.clear()
	commander.note_loss(lost, t.global_position)
	feedback.burst(t.global_position, Color(0.33, 0.38, 0.24))
	t.call_deferred("queue_free")
	trucks.erase(t)


## A floor spot in a room of the focus, lowest storey first, or INF.
func _room_spot() -> Vector3:
	var spots := survey.floors_of(focus)
	spots.sort_custom(func(x: Vector3, y: Vector3) -> bool: return x.y < y.y)
	# Well inside the room, not on its edge: a body put down beside a wall
	# settles a hand's width from where it was put, and from an edge spot that
	# is outside the room -- the commander then sees a contact in no room at
	# all and never orders the clear.
	var edge := Vector3.INF
	for f in spots:
		var r := CityRooms.at(city, f)
		if r.is_empty():
			continue
		var inside := true
		for d in [Vector3(ROOM_MARGIN, 0.0, 0.0), Vector3(-ROOM_MARGIN, 0.0, 0.0),
				Vector3(0.0, 0.0, ROOM_MARGIN), Vector3(0.0, 0.0, -ROOM_MARGIN)]:
			var n := CityRooms.at(city, f + d)
			if n.is_empty() or int(n.index) != int(r.index) or int(n.building) != int(r.building):
				inside = false
				break
		if inside:
			return f
		if edge == Vector3.INF:
			edge = f
	return edge


## Every line said so far, by key and count.
func _said_keys() -> Dictionary:
	var out := {}
	for l in city.ai_services.callouts.said:
		out[l[2]] = int(out.get(l[2], 0)) + 1
	return out


func _of_wave(n: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in spawned:
		if int(s.wave) == n:
			out.append(s)
	return out


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _until(cond: Callable, seconds: float) -> void:
	var t0 := _now()
	while not cond.call() and _now() - t0 < seconds:
		await get_tree().physics_frame


# --- showing it ---------------------------------------------------------------------

func _update_label() -> void:
	var p := _player()
	var hp := p.health.total_current() if p != null else 0.0
	var fit := survey.building_fit(focus) if focus >= 0 else {"ok": false, "why": "none"}
	var lines := [
		"ARENA   wave %d   alive %d   to come %d   kills %d   hp %.0f%s" % [
			wave, alive.size(), _left_to_spawn, kills, hp,
			"   DOWN" if _player_dead_at >= 0.0 else ""],
		"focus   building %d   %.0f%% standing   %s   %d floor spot(s)" % [
			focus, survey.integrity(focus) * 100.0 if focus >= 0 else 0.0,
			"fit" if bool(fit.ok) else fit.why, _floors.size()],
	]
	var inside := 0
	var outside := 0
	for s in spawned:
		if int(s.wave) == wave:
			if int(s.inside) >= 0:
				inside += 1
			else:
				outside += 1
	lines.append("spawned this wave: %d on its floors, %d outside" % [inside, outside])
	var cm := commander
	lines.append("commander   %.0f pts banked, wants %.1f up   desperation %.0f%%   answering %s   aggression %.2f" % [
			cm.budget, cm.want_strength(), cm.desperation * 100.0, cm.doctrine.answering,
			cm.doctrine.aggression])
	if hq_building >= 0:
		var me := _player()
		lines.append("HQ   building %d   officer %s   radio %s%s" % [hq_building,
				"up" if cm.commander_up else "DEAD", "up" if cm.radio_up else "DOWN",
				("   %.0f m" % me.feet().distance_to(cm.hq)) if me != null else ""])
	for q in cm.squads:
		if is_instance_valid(q):
			lines.append("  squad %d  %d up  %s%s%s" % [q.id, q.alive().size(), q.play,
					("  order " + SquadMsg.OrderKind.keys()[q.order.kind]) if q.order != null else "",
					"  BROKEN" if q.broken else ""])
	if not cm.log.is_empty():
		lines.append("  " + cm.log[cm.log.size() - 1])
	var tactics := {}
	for so in alive:
		var t: String = CombatPolicy.TACTIC_NAMES[so.tactic] if so.tactic >= 0 else so.state
		tactics[t] = int(tactics.get(t, 0)) + 1
	if not tactics.is_empty():
		var parts := []
		for k in tactics:
			parts.append("%s %d" % [k.replace("_", " "), tactics[k]])
		lines.append("doing: " + ", ".join(parts))
	var j := city.ai_services.judge as DecisionJudge
	if j != null and not j.episodes.is_empty():
		var sm := j.summary()
		var stupid := 0
		var good := 0
		var total := 0.0
		for n in sm.tactics:
			stupid += int(sm.tactics[n].stupid)
			good += int(sm.tactics[n].good)
			total += float(sm.tactics[n].reward)
		lines.append("judge: %d call(s), mean %+.1f, %d stupid, %d good" % [sm.episodes,
				total / float(sm.episodes), stupid, good])
		var bl := []
		for f in sm.flags:
			if f in DecisionJudge.BLUNDERS:
				bl.append("%s %d" % [f.replace("_", " "), sm.flags[f]])
		if not bl.is_empty():
			lines.append("stupid: " + ", ".join(bl))
	if not survey.refused.is_empty():
		var parts := []
		for k in survey.refused:
			parts.append("%s %d" % [k, survey.refused[k]])
		lines.append("refused: " + ", ".join(parts))
	if _last_move != "":
		lines.append(_last_move)
	lines.append("F7 spawn overlay   F8 next wave   X big blast")
	_label.text = "\n".join(lines)


func _note(p: Vector3, ok: bool) -> void:
	survey.looked.append([p, ok])
	if survey.looked.size() > 600:
		survey.looked = survey.looked.slice(survey.looked.size() - 600)
	if _show_overlay:
		_draw_overlay()


func _draw_overlay() -> void:
	if _overlay == null:
		_overlay = MeshInstance3D.new()
		_overlay.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = true
		_overlay.material_override = mat
		_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		city.add_child(_overlay)
	_overlay.visible = _show_overlay
	var im: ImmediateMesh = _overlay.mesh
	im.clear_surfaces()
	if survey.looked.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in survey.looked:
		var p: Vector3 = e[0]
		var col := Color(0.2, 1.0, 0.3) if bool(e[1]) else Color(1.0, 0.2, 0.2)
		im.surface_set_color(col)
		im.surface_add_vertex(p)
		im.surface_set_color(col)
		im.surface_add_vertex(p + Vector3.UP * 1.2)
		im.surface_set_color(col)
		im.surface_add_vertex(p + Vector3(-0.25, 0.05, 0.0))
		im.surface_set_color(col)
		im.surface_add_vertex(p + Vector3(0.25, 0.05, 0.0))
	im.surface_end()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F7:
			_show_overlay = not _show_overlay
			_draw_overlay()
		KEY_F8:
			if _ready_to_fight:
				commander.force_reinforce()
