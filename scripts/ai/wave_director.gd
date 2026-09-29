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
## knows what it sees and hears -- and the player's gun is heard (PLAYER_NOISE).
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
## Wave n (from 1) has BASE + PER_WAVE * (n - 1) soldiers, no more than ALIVE_CAP
## of them up at once (Docs/AI.md A2: about ten smart agents).
const BASE := 4
const PER_WAVE := 2
const ALIVE_CAP := 8
## The share of a wave put inside the focus building, when it has floors.
const INSIDE_SHARE := 0.6
const SPAWN_EVERY := 0.6
const BETWEEN_WAVES := 6.0
const FIRST_WAVE_AFTER := 4.0
const PLAYER_RESPAWN := 3.0
## A rough fix on the player: this far out, and dated so that it is older than
## the fight branch's 2.5 s (SoldierTree) -- a soldier goes to look, rather than
## taking cover from somebody it has never seen.
const TIP_SPREAD := 8.0
const TIP_AGE := 3.0
## Nobody on the side has seen or heard the player for this long: another fix.
const LOST_SECONDS := 15.0
## How far the player's gunfire carries (a soldier's is 40 m).
const PLAYER_NOISE := 40.0
## The arena's soldiers are slower on the trigger and looser than the AI's
## defaults (AimModel): 0.35 s, 7 -> 1.2 degrees over 1.6 s.
const AIM_REACTION := 0.7
const AIM_CONE_START := 10.0
const AIM_CONE_MIN := 2.6
const AIM_SETTLE := 2.6
## Health on the weapon specs' scale (GUN_QUALITY_NAMING_SPEC 7.2: gun damage
## and enemy HP were divided by the same 10): a trash soldier takes about five
## level-1 rifle rounds, a standard one about twelve. Pawn's default 100 is the
## old scale's number, and made every soldier a sponge.
const HP_TRASH := 45.0
const HP_STANDARD := 113.0
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
var _next_wave := 0.0
var _next_survey := 0.0
var _floors: Array[Vector3] = []
var _encounter: Encounter
var _start := Vector3.ZERO
var feedback: CombatFeedback
var voice: ArenaVoice
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
	voice = ArenaVoice.new()
	voice.name = "Voice"
	add_child(voice)
	voice.setup(city)
	city.ai_services.on_say = voice.say
	city._gun.fired.connect(_on_player_fired)


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
	_player().health.died.connect(_on_player_died)
	_resurvey()
	_next_wave = _now() + FIRST_WAVE_AFTER
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
	_settle_check()
	for so in alive:
		var k := so.get_instance_id()
		var at := so.pawn.feet()
		if _last_at.has(k):
			var was: Vector3 = _last_at[k]
			travelled[k] = float(travelled.get(k, 0.0)) + Vector2(at.x - was.x, at.z - was.z).length()
		_last_at[k] = at
	for so in alive:
		if so.pawn.intents.crouch:
			_crouched += 1
	_check_focus()
	_player_tick(now)
	if _left_to_spawn <= 0 and alive.is_empty() and now >= _next_wave:
		_start_wave()
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


func _start_wave() -> void:
	wave += 1
	_left_to_spawn = BASE + PER_WAVE * (wave - 1)
	_wave_size = _left_to_spawn
	_put_inside = 0
	_next_spawn = _now()
	survey.reset_counts()
	_tip()
	_resurvey()
	print("[arena] wave %d: %d soldier(s), %d floor spot(s) in building %d" % [
		wave, _left_to_spawn, _floors.size(), focus])


func _spawn_one() -> void:
	# A quota, not a coin: inside while fewer than the share of those spawned
	# so far (this one included) have been, so a wave mixes from its start.
	var done := _wave_size - _left_to_spawn
	var want_inside := not _floors.is_empty() \
			and float(_put_inside) < INSIDE_SHARE * float(done + 1) - 0.01
	var others: Array = []
	for so in alive:
		others.append(so.pawn)
	# A few tries: a spot that fails the check is dropped and the next tried.
	for attempt in 8:
		var feet: Vector3
		var inside := -1
		if want_inside and not _floors.is_empty():
			var i := _rng.randi() % _floors.size()
			feet = _floors[i]
			inside = focus
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
		_note(feet, true)
		_spawn_at(feet, inside)
		return
	# Nothing inside would do: the rest of this wave comes from outside.
	if want_inside:
		_floors.clear()


func _spawn_at(feet: Vector3, inside: int) -> void:
	var cls: StringName = &"rifle"
	if wave >= 3:
		cls = [&"rifle", &"rifle", &"smg", &"shotgun"][_rng.randi() % 4]
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(city._gun_library,
			city._combat_rng.randi(), WeaponClass.builtin(cls), maxi(1, wave)))
	var so := Soldier.spawn(city.ai_services, city, feet + Vector3.UP * 0.02, ENEMY_TEAM, gun)
	so.aim.reaction = AIM_REACTION
	so.aim.cone_start = AIM_CONE_START
	so.aim.cone_min = AIM_CONE_MIN
	so.aim.settle = AIM_SETTLE
	var hp := HP_STANDARD if wave >= 3 and _rng.randi() % 3 == 0 else HP_TRASH
	so.pawn.health.layer_configs[0].max_value = hp
	so.pawn.health.reset()
	so.max_health = hp
	# In its hands where it can be seen: its muzzle flash and its tracers are
	# how the player tells who is shooting and from where.
	gun.visible = true
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
			"soldier": so, "frame": Engine.get_physics_frames(), "drop": NAN})
	_left_to_spawn -= 1


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
		_next_wave = _now() + BETWEEN_WAVES
		print("[arena] wave %d cleared, %d kill(s)" % [wave, kills])


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
	var p := _player()
	if p != null and city._player.is_possessing():
		city.ai_services.noise(p.eye.global_position, PLAYER_NOISE, p)


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
	# Wave one, all of it.
	_next_wave = 0.0
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
		var d := float(travelled.get(so.get_instance_id(), 0.0))
		# Standing still is fine in cover that happened to be next to where it
		# appeared; standing still anywhere else is what this is here to catch.
		if d > 3.0 or so.state in ["hide", "peek", "reload in cover"]:
			moved.append("%.1f m, %s" % [d, so.state])
		else:
			stayed.append("%.1f m, %s" % [d, so.state])
	ok.call("they move: %d of %d walked more than 3 m or are working a cover spot" % [
			moved.size(), moved.size() + stayed.size()],
			moved.size() * 4 >= (moved.size() + stayed.size()) * 3,
			"moved %s, stayed %s" % [moved, stayed])
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
		while feedback.kills_shown == kills0 and _now() - t_fire < 12.0:
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
		var f: Vector3 = spots[spots.size() / 2]
		for i in spots.size():
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
	_next_wave = 0.0
	await _until(func() -> bool: return wave > w and _left_to_spawn <= 0, 40.0)
	var second := _of_wave(w + 1)
	var in_old := second.filter(func(s): return int(s.inside) == old)
	ok.call("wave %d comes in (%d) and puts nobody in the fallen building" % [w + 1, second.size()],
			second.size() > 0 and in_old.is_empty(),
			"%d in building %d" % [in_old.size(), old])
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
		var said0 := int(voice.said.get("stuck", 0))
		caller.call_for_help()
		ok.call("a stuck soldier shouts for help and a buddy comes",
				int(voice.said.get("stuck", 0)) > said0 and buddy.help_point.distance_to(caller.pawn.feet()) < 0.5,
				"said %s, help at %v" % [voice.said, buddy.help_point])
	ok.call("the player hears what they say", not voice.shown.is_empty(), "said %s" % [voice.said])

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
	_next_wave = 0.0
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
	print("[watch] lines said %s" % [voice.said])
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
				"flags": d.get("flags", []), "outcome": d.get("outcome", {})}))
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
				_left_to_spawn = 0
				_next_wave = 0.0
				if alive.is_empty():
					_start_wave()
				else:
					wave += 1
					_left_to_spawn = BASE + PER_WAVE * (wave - 1)
					_wave_size = _left_to_spawn
					_put_inside = 0
