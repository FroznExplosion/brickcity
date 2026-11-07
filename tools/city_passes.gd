extends Node

## The city scene's test passes: `res://scenes/city.tscn -- --<pass>` (the
## flags are read in city_scene.gd, which calls in here from its _ready).
##
## Moved out of city_scene.gd so the game's own code is the game: nothing in
## this file runs in a plain game, and a pass's helpers sit beside the pass.
## Each pass drives the city through `city` -- its members, its camera, its
## gun -- exactly as it did from inside it, and quits when it is done.
##
## Typed against the city's script, so a name the city no longer has is a
## parse error here, not a silent null at run time.

const City := preload("res://scripts/city_scene.gd")

var city: City

# --- what only the passes keep -------------------------------------------

const RENDER_SAMPLE_EVERY := 15
var _many_target: Pawn
var _many := {"soldiers": 0, "flyers": 0, "animals": 0, "hunters": 0}
var _glass_here_worst_usec := 0
var _glass_here := 0
var _last_wait := 0

## The storey-units gate (Docs/Space.md 5.3a): the biggest tower shot once at
## mid-height -- what the first hit costs and what it holds afterwards; then
## (storey units on) that storey blown out until it gives way, the part above
## falling as one shell piece and landing; then the building given back and
## laid again, its record replayed. `-- --storeys --big`, and with `--whole`
## for today's numbers. Timing only means anything with the editor closed.
## The --storeys gate's line between a top that came to rest on its stump and
## one that fell: three storeys of drop.
const STOREY_FALL := 3.0 * TowerRecipe.STOREY_PLATES * 0.14

## How wide a bay `_bay_check` shoots out: twice Floor Reach at its default, so
## the middle of the floor over it is a reach from either side.
const BAY_STUDS := 40
const _RUBBLE_WINDOW := 240

## Does a building draw what it has, and nothing it has lost?
##
## A building's bands are index-patched when it is hit (_remesh), against a
## baseline of what they draw (BrickWorld.update_index_regions). The baseline
## was set by the first patch asked for -- after the hit it was for -- so that
## hit was never drawn: three big blasts into a wall left 3,467 of 9,516
## triangles drawn with no brick behind them, a staircase and walls floating in
## the hole, real to nobody's grid (user report, 2026-10-02). Each triangle is
## asked: a step inside it, along its normal, is a live brick? A shaped part
## (a spiral tread, a slope) answers no for a few of its own -- 246 of 15,106
## on this building whole -- so the measure has slack for that.
const DRAWN_SLACK := 0.02

## Walls drawn where no brick is (CollapseNext 29(a): "from mid range, parts
## of the wall drawn that should be gone, there until the player comes close").
## GHOST_RAYS rays from the camera across building `id`'s box, against the
## triangles of what draws it from its bricks -- its brick mesh, its bands
## (_brick_bands), its shell -- and at the nearest hit, half a cell into the
## face: no solid cell of its chunk within a cell of there is a ghost. The rest
## shell (storeys not laid), the far box and the instanced set are whole by
## design and not asked. [rays that hit, ghosts, {source: ghosts}, five ghosts,
## hits on storeys not laid]. `solid_out`, if given, gets the solid cells hit
## (up to 40): _ghost_control kills them to see the check see them.
const GHOST_RAYS := Vector2i(24, 48)
var _lodbreak_blind := 0   ## stops where a building with bricks alive drew no walls

## From 8 s after the shot on (the building quiet, flown up to through the mid
## ring), a stop may show GHOST_ALLOWED ghost hits or GHOST_SHARE of its hits,
## whichever is more: 1-2 are seen while pieces are still moving off it.
const GHOST_ALLOWED := 2
const GHOST_SHARE := 0.03
var _ghost_asked := false
var _ghost_stops: Array = []

## Each frozen piece of the building with more than HUNG_GAP of air under its
## middle (the first three): a picture from 15 m off, level with it, then woken
## with the camera there -- the near settle window, 1.5 s to begin tipping by
## itself -- and asked again 3 s on. Frozen where it would fall, it drops; held
## (wedged, or levered under what still stands), it stays. CollapseNext 29: from
## 320 m a piece frozen 21 m over what is under its middle. 2026-10-22 it was a
## 54-brick corner of a storey levered under the standing top: tipped three
## times on the far window, and woken close up it moved 0.0 m. Returns
## [asked, moved more than HUNG_DROP]. The camera is put back after.
const HUNG_GAP := 3.0
const HUNG_DROP := 0.5

## Every part of an interior drawing within its range of the camera, and every
## brick lying in the heap within its own, with nothing drawn under its foot for
## FLOAT_REACH (_float_held). [kind, foot in world space].
const FLOAT_REACH := 1.5
var _float_seen := 0   ## parts asked, the last time

## What loose pieces cost to draw (Docs/Hulls.md 11, E2: measure before batching).
## A timing pass: editor closed, no other runs (CLAUDE.md).
##
##     godot --path . scenes/city.tscn -- --piececost
##
## Towers blasted until the debris caps are full (or the towers run out), left to
## settle, then the frame measured three ways, PIECE_FRAMES frames each: pieces
## drawn, their meshes hidden, drawn again. Prints CPU and GPU render time, draw
## calls and the frame's process time; the difference is what the pieces cost.
## Also how many pieces share a mesh -- a MultiMesh only batches shared ones.
const PIECE_FRAMES := 180

## Does a collapse come down, or hang?
##
## A storey blown out under three towers with stairs, watched for ten seconds
## from inside FRACTURE_RANGE, so landings break things. A piece is STUCK when it
## has stayed slower than JAM_SLOW for a second, a second and a half after it
## came loose, and still not settled: held up and jittering, the thing a
## collapse was seen doing in mid-air. What it is touching says why. Measured
## first (--diag stairs, 2026-09-30): 22 stuck, 17 of them on pieces that were
## themselves still falling. And a piece THROWN -- going up faster than
## JAM_THROWN with nothing having blown it -- is what pushing two overlapping
## bodies apart looks like, which is the price of letting falling pieces pass
## through each other if it is done wrong (IslandManager.MAX_RISE_SPEED). It
## was counted as a jump in one tick; the push builds over three or four, and
## 1 -> 6 -> 10 -> 11 m/s was never one jump.
const JAM_SLOW := 0.8
const JAM_THROWN := 6.0

## The --checkpoint gate's expectations, carried across the reload the same way.
const CHECKPOINT_GATE_META := &"city_checkpoint_gate"


func _init(c: Node3D) -> void:
	city = c
	name = "CityPasses"

## The city's shore (§21.6): standing on dry ground a little inland of the
## nearest water, looking out over it, so the brick tiers, the sheet and the
## seabed's shallows are all in one picture.
func _shot_shore() -> void:
	var sea: float = City.TerrainWorldScript.sea_level
	var wet := Vector3.INF
	for r in range(20, 400, 8):
		for k in 48:
			var a := TAU * float(k) / 48.0
			var p := city._on_ground(Vector3(cos(a) * r, 0.0, sin(a) * r))
			if p.y < sea - 0.5:
				wet = p
				break
		if wet != Vector3.INF:
			break
	if wet == Vector3.INF:
		return
	var inland := Vector3(wet.x, 0.0, wet.z).normalized() * -18.0
	var stand := city._on_ground(wet + inland)
	city.camera.position = Vector3(stand.x, maxf(stand.y, sea) + 6.0, stand.z)
	city.camera.look_at(Vector3(wet.x, sea, wet.z) - inland, Vector3.UP)
	await _frames(8)
	await _save("city_shore")

## What is straight under a figure, for a gate's failure message: which body,
## and how far down.
func _what_is_under(body: CharacterBody3D) -> String:
	if body == null:
		return "nothing (no figure)"
	var q := PhysicsRayQueryParameters3D.create(body.global_position,
			body.global_position - Vector3(0.0, 6.0, 0.0))
	q.collision_mask = Layers.HITSCAN_MASK
	q.exclude = [body.get_rid()]
	var hit := city.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return "nothing within 6 m"
	var rid: RID = hit.rid
	var what := "something else"
	for bid in city._brick_cols:
		var bc: BuildingCollision = city._brick_cols[bid]
		if bc.owns(rid):
			what = "band %d of building %d's bricks" % [bc.bodies.find(rid), bid]
	for bid in city._shell_bodies:
		if city._shell_bodies[bid] == rid:
			what = "building %d's shell" % bid
	for bid in city._room_bodies:
		if city._room_bodies[bid] == rid:
			what = "building %d's furniture" % bid
	if city.islands.find_by_body(hit.collider) != null:
		what = "a piece"
	return "%s, shape %d, %.2f m down" % [what, int(hit.shape),
			body.global_position.y - (hit.position as Vector3).y]

## The gate for the player's gun (Docs/AIPlan.md P1): a generated gun, fired at a
## wall, wears bricks through the WorldAuthority and breaks one on the hit
## StructuralDamage says; a living target takes the damage instead of the wall;
## ordnance blasts; and the log -- CHIPs and all -- replays into the same city.
func _run_gun_pass() -> void:
	var b := city.registry.get_building(0)
	city._promote(0)
	await _frames(20)
	var chunk := b.chunk
	# A structural brick in the outer wall at chest height -- not a window, which
	# a round would go straight through into the room behind.
	var xf := city.world.get_chunk_transform(chunk)
	var face := Vector3.ZERO
	var best := INF
	var mid: float = b.recipe.footprint_x * 0.5 * City.STUD
	for bx in city.world.get_block_boxes(chunk):
		var d: Dictionary = bx
		var pos: Vector3 = d.pos
		if not bool(d.alive) or city.world.is_block_decorative(chunk, int(d.block)) 				or pos.y < 1.2 or pos.y > 2.2:
			continue
		var score := pos.z * 10.0 + absf(pos.x - mid)
		if score < best:
			best = score
			face = xf * pos
	var out := xf.basis * Vector3(0.0, 0.0, -1.0)
	city.camera.look_at_from_position(face + out * 6.0, face)
	await _frames(2)
	# Dead, not alive: a shot near a window opens the room behind it, and the
	# furniture that puts in the chunk counts as alive.
	var dead0 := city.world.get_dead_blocks(chunk).size()
	var n0 := city.authority.commands.size()

	city._equip_gun(&"pistol", 7)
	# Dead straight, so every round lands in the same brick.
	city._gun.gun.stats[&"accuracy"] = 1.0
	var shots := [0]
	var structural := [0]
	var log_hits: Array = []
	city._gun.fired.connect(func(info: Dictionary) -> void:
		shots[0] += 1
		log_hits.append(info)
		if bool(info.get("structure", false)):
			structural[0] += 1)
	await _shoot(1)
	var chips := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	print("[city] gun gate")
	_gate_ok("one round is one CHIP, on the building it hit",
			chips == 1 and city.authority.commands.entries[-1].target == 0,
			"%d command(s)" % (city.authority.commands.size() - n0))
	_gate_ok("and it breaks nothing", city.world.get_dead_blocks(chunk).size() == dead0)
	await _shoot(StructuralDamage.hits_per_brick(WeaponClass.builtin(&"pistol")) - 1)
	_gate_ok("the round StructuralDamage names breaks the brick",
			city.world.get_dead_blocks(chunk).size() == dead0 + 1,
			"%d dead -> %d" % [dead0, city.world.get_dead_blocks(chunk).size()])

	# Something alive in the line of fire takes the bullet instead.
	var target := StaticBody3D.new()
	target.collision_layer = Layers.PAWN
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	col.shape = capsule
	target.add_child(col)
	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = 1000.0
	pool.layer_configs = [layer]
	target.add_child(pool)
	city.add_child(target)
	target.global_position = face + out * 3.0 - Vector3(0.0, 0.2, 0.0)
	await _frames(2)
	var n1 := city.authority.commands.size()
	var before := pool.total_current()
	await _shoot(2)
	_gate_ok("a living target takes the damage, and the wall none",
			pool.total_current() < before and city.authority.commands.size() == n1,
			"%.0f -> %.0f hp, %d command(s)" % [before, pool.total_current(),
			city.authority.commands.size() - n1])
	target.queue_free()
	await _frames(2)

	# An SMG held down: every round a command, none of them a whole brick.
	city._equip_gun(&"smg", 11)
	var n2 := city.authority.commands.size()
	var s0: int = shots[0]
	log_hits.clear()
	city._gun.set_trigger(true)
	await _frames(60)
	city._gun.set_trigger(false)
	await _shoot(0)
	var fired: int = shots[0] - s0
	for info in log_hits:
		if info.is_empty() or not bool(info.structure):
			print("[city]   round: %s" % ("missed" if info.is_empty() else "hit %s at %v" % [info.collider, info.point]))
	_gate_ok("a held trigger fires at the gun's rate, one command a round",
			fired >= 5 and city.authority.commands.size() - n2 == fired,
			"%d rounds, %d command(s), %.1f/s rated" % [fired, city.authority.commands.size() - n2,
			city._gun.gun.stats.get(&"fire_rate", 0.0)])

	city._equip_gun(&"rocket_launcher", 3)
	city._gun.gun.stats[&"accuracy"] = 1.0
	var n3 := city.authority.commands.size()
	log_hits.clear()
	await _shoot(1)
	var blasts := 0
	for i in range(n3, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	_gate_ok("ordnance blasts", blasts >= 1, "%d BLAST(s); rounds %s" % [blasts, log_hits])
	await _frames(30)
	# The AI overlay (F4) draws, and says something.
	city._ai_label.visible = true
	city.dev_hud.update_ai_label()
	_gate_ok("the AI overlay reports the AI's world and budget",
			city._ai_label.text.begins_with("AI (F4)") and city._ai_label.text.contains("chunks"),
			city._ai_label.text.get_slice("\n", 0))
	await _frames(12)
	await _save("city_gun")
	_check_log_replays()
	print("[city] gun gate: %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The gate for the mech (Docs/AIPlan.md P1): BoomerBorder's motor under a body
## sized in bricks, piloted by the keys -- walks at its speed, sprints faster,
## dashes on a charge, its torso follows the look at its own pace, it steps over a
## figure's cover and not a storey -- and its arm aims UP as far as the player can
## (A15) and puts rounds into a wall high above through the authority.
func _run_mech_pass() -> void:
	print("[mech] a greybox mech, piloted")
	city._pilot.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	city.camera.global_position = open + Vector3(0.0, 6.0, 12.0)
	city.camera.rotation = Vector3.ZERO
	city.vehicles.spawn_mech(open, 0.0)
	city.vehicles.board_mech()
	await _frames(60)
	var m := city._mech
	_gate_ok("it stands on the ground", m.body.is_on_floor() and absf(m.feet().y) < 0.1,
			"feet %.2f" % m.feet().y)
	_gate_ok("the camera is in the cockpit, ten courses up",
			absf(city.camera.global_position.y - Mech.COCKPIT_Y) < 0.15,
			"%.2f m" % city.camera.global_position.y)
	# The seat (CockpitView): no canopy slab across the view, the pilot's hands on
	# the two sticks.
	var cv := city._pilot.cockpit
	_gate_ok("from the seat the canopy is not drawn across the view", not m.canopy.visible)
	_gate_ok("the pilot's hands are on the sticks", cv != null and cv.arms != null
			and cv.arms.reach_gap[0] < 0.02 and cv.arms.reach_gap[1] < 0.02,
			"%.3f, %.3f m short" % [cv.arms.reach_gap[0], cv.arms.reach_gap[1]] if cv != null else "none")
	city.camera.rotation = Vector3(-0.3, 0.0, 0.0)
	await _frames(3)
	await _save("mech_cockpit")
	city.camera.rotation = Vector3.ZERO
	await _frames(2)

	_key(KEY_W, true)
	await _frames(90)
	var walk := m.motor.planar_speed()
	_gate_ok("W leans the left stick ahead", cv != null and (cv.lean[ViewArms.LEFT] as Vector2).x > 0.7,
			"%.2f" % (cv.lean[ViewArms.LEFT] as Vector2).x if cv != null else "")
	_key(KEY_SHIFT, true)
	await _frames(90)
	var sprint := m.motor.planar_speed()
	_key(KEY_SHIFT, false)
	_key(KEY_W, false)
	await _frames(60)
	_gate_ok("it walks at the motor's speed", absf(walk - m.motor.max_speed) < 0.6,
			"%.1f m/s" % walk)
	_gate_ok("and sprints faster", sprint > walk * 1.3, "%.1f m/s" % sprint)
	_gate_ok("and stops when let go", m.motor.planar_speed() < 0.5)

	var charges := m.motor.charges()
	_key(KEY_W, true)
	_key(KEY_Q, true)
	await _frames(4)
	var dashing := m.motor.is_dashing()
	_key(KEY_Q, false)
	_key(KEY_W, false)
	await _frames(60)
	_gate_ok("Q dashes on a charge", dashing and m.motor.charges() == charges - 1,
			"%d -> %d charges" % [charges, m.motor.charges()])

	# The look turns at once; the torso follows at its own pace, the legs after.
	city.camera.rotation = Vector3(0.0, PI * 0.5, 0.0)
	await _frames(2)
	var lag := absf(wrapf(m.motor.torso_yaw - PI * 0.5, -PI, PI))
	await _frames(60)
	var settled := absf(wrapf(m.motor.torso_yaw - PI * 0.5, -PI, PI))
	_gate_ok("the torso chases the look, heavy but arriving",
			lag > 0.2 and settled < deg_to_rad(3.0),
			"%.0f deg behind, then %.1f" % [rad_to_deg(lag), rad_to_deg(settled)])
	_gate_ok("and the legs follow it round",
			absf(wrapf(m.motor.legs_yaw - m.motor.torso_yaw, -PI, PI)) < deg_to_rad(40.0))

	# Cover a figure hides behind is a step; a storey is a wall. Facing -Z again.
	city.camera.rotation = Vector3.ZERO
	await _frames(60)
	var here := m.feet()
	var cover := _test_block(here + Vector3(0.0, 0.5, -6.0), Vector3(8.0, 1.0, 2.0))
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(30)
	_gate_ok("it walks over a metre of cover", m.feet().z < here.z - 8.0,
			"z %.2f, cover at %.2f" % [m.feet().z, here.z - 6.0])
	cover.queue_free()
	here = m.feet()
	var storey := _test_block(here + Vector3(0.0, 1.5, -6.0), Vector3(10.0, 3.0, 2.0))
	await _frames(4)
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(30)
	_gate_ok("and not over a storey", m.feet().z > here.z - 5.0 - Mech.RADIUS + 0.5
			and m.feet().z < here.z - 1.0, "z %.2f, face at %.2f" % [m.feet().z, here.z - 5.0])
	storey.queue_free()

	# Aim UP (A15): stand back from the tallest building and fire at its wall well
	# above the cockpit.
	var tall := city.registry.get_building(0)
	for b in city.registry.buildings:
		if b.recipe.courses > tall.recipe.courses:
			tall = b
	var face := tall.xform * Vector3(tall.recipe.footprint_x * 0.5 * City.STUD, 0.0, 0.0)
	var out := tall.xform.basis * Vector3(0.0, 0.0, -1.0)
	city.vehicles.leave_mech()
	m.body.global_position = face + out * 6.0 + Vector3.UP * Mech.HEIGHT * 0.5
	m.body.reset_physics_interpolation()
	city.vehicles.board_mech()
	await _frames(60)
	var high := face + Vector3.UP * minf(tall.recipe.courses * Mech.COURSE * 0.9, 30.0)
	print("[mech]   tallest: %d courses; aiming at %.1f m from 6 m out" % [tall.recipe.courses, high.y])
	city.camera.look_at(high, Vector3.UP)
	await _frames(30)
	var n0 := city.authority.commands.size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(40)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await _shoot(0)
	var top := 0.0
	var chips := 0
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.kind == DamageLog.Kind.CHIP:
			chips += 1
			top = maxf(top, e.point.y)
	_gate_ok("the arm aims up as far as the player can (A15)",
			m.arm_pitch > deg_to_rad(40.0), "%.0f deg" % rad_to_deg(m.arm_pitch))
	_gate_ok("and its rounds wear the wall high above the cockpit",
			chips > 0 and top > Mech.COCKPIT_Y + 4.0, "%d CHIP(s), highest %.1f m" % [chips, top])

	city.vehicles.leave_mech()
	await _frames(30)
	_gate_ok("M leaves: the camera flies and the mech stays parked",
			city.camera.is_processing() and is_instance_valid(m) and m.motor.planar_speed() < 0.5)
	# From above the street: the blocks are 13 m apart, so anywhere level with the
	# mech and a few metres off is inside a building.
	city.camera.global_position = m.feet() + out * 3.0 + out.cross(Vector3.UP) * 3.0 + Vector3.UP * 13.0
	city.camera.look_at(m.feet() + Vector3.UP * 3.5, Vector3.UP)
	await _frames(3)
	await _save("city_mech")

	# On foot to the hatch and in: the player's own gun is put away, and the left
	# button is the mech's arm's alone.
	city._enter_pawn(m.mount_point())
	await _frames(30)
	var own := [0]
	var arm_shots := [0]
	city._gun.fired.connect(func(_i: Dictionary) -> void: own[0] += 1)
	m.gun.fired.connect(func(_i: Dictionary) -> void: arm_shots[0] += 1)
	city.vehicles.board_mech()
	await _frames(10)
	_gate_ok("in from the hatch, on foot", city._pilot.is_piloting() and city.vehicles._boarded_on_foot)
	_gate_ok("the player's own gun is put away", city._gun.gun == null or not city._gun.gun.visible)
	city.camera.rotation = Vector3.ZERO
	click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(30)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await _frames(5)
	_gate_ok("the left button fires the mech's arm, not the player's gun",
			own[0] == 0 and arm_shots[0] > 0, "player's %d, arm's %d" % [own[0], arm_shots[0]])
	city.vehicles.leave_mech()
	await _frames(20)
	_gate_ok("out again on foot, the gun back in hand and the canopy back on",
			city._player.is_possessing() and city._gun.gun != null and city._gun.gun.visible and m.canopy.visible
			and city._pilot.cockpit == null)
	_check_log_replays()
	print("[mech] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The player's vehicles, by their keys (Docs/AIVehicles.md 4; Halo's driving,
## riding and boarding): a truck of ours got into with M and driven, the view
## behind and inside; friends near hop in its bed; out with M, they get down.
## An enemy's crewed tank: E beside it climbs on, E held pries the hatch, its
## crew is dragged out and the player has it; its cannon fires.
func _run_vehicles_pass() -> void:
	print("[vehicles] driving, riding and boarding")
	city._vehicle_pilot.drive_uncaptured = true
	city._player.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	city.camera.global_position = open + Vector3(0.0, 6.0, 12.0)
	city.camera.rotation = Vector3.ZERO
	var truck_at: Vector3 = city.ai_services.vehicle_nav(&"truck").snap(city._on_ground(open))
	var truck: TransportTruck = city.vehicles.spawn_truck(truck_at, 0.0, 0, [] as Array[StringName])
	await _frames(20)
	city._enter_pawn(truck.mount_point())
	await _frames(10)
	_key(KEY_M, true)
	await _frames(2)
	_key(KEY_M, false)
	await _frames(20)
	_gate_ok("M beside a truck of ours: at the wheel", city._vehicle_pilot.vehicle == truck and truck.player_in)
	var cam_back := (city.camera.global_position - truck.global_position)
	_gate_ok("the camera follows behind it (Halo)", cam_back.length() > 4.0 and cam_back.dot(city.camera.global_transform.basis.z) > 3.0,
			"%.1f m from it" % cam_back.length())
	_key(KEY_C, true)
	await _frames(2)
	_key(KEY_C, false)
	await _frames(5)
	_gate_ok("C puts the view inside the cab", city.camera.global_position.distance_to(truck.eye_interpolated()) < 0.3)
	_key(KEY_C, true)
	await _frames(2)
	_key(KEY_C, false)
	var from := truck.feet()
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(60)
	_gate_ok("W drives it", truck.feet().distance_to(from) > 8.0, "%.1f m" % truck.feet().distance_to(from))
	# Friends near hop in its bed while it stands.
	var friends: Array[Soldier] = []
	for i in 2:
		var so := city._spawn_soldier(city.ai_nav.snap(truck.feet() + truck.global_transform.basis.x * (5.0 + i)))
		so.team = 0
		so.pawn.team = 0
		friends.append(so)
	await _frames(400)
	_gate_ok("friends near hop in its bed", truck.rodeo.rider_count() == 2,
			"%d on (%s)" % [truck.rodeo.rider_count(), ", ".join(friends.map(func(x: Soldier) -> String: return x.state))])
	_key(KEY_M, true)
	await _frames(2)
	_key(KEY_M, false)
	await _frames(20)
	_gate_ok("M gets out, on foot beside it, and its riders get down", not city._vehicle_pilot.is_driving()
			and city._player.is_possessing() and city._player_pawn.feet().distance_to(truck.feet()) < 4.0
			and truck.rodeo.rider_count() == 0, "%d still on" % truck.rodeo.rider_count())
	for so in friends:
		so.pawn.health.apply_impact(1e9, &"")

	# An enemy's crewed tank: E beside it climbs on, E held pries the hatch.
	var tank_at: Vector3 = city.ai_services.vehicle_nav(&"tank").snap(city._on_ground(open + Vector3(25.0, 0.0, 0.0)))
	var t: Tank = city.vehicles.spawn_tank(tank_at, PI * 0.5, 1, true)
	(t.get_node(^"TankBrain") as TankBrain).enabled = false
	await _frames(20)
	var crew: Array = t.crew.values()
	city._player_pawn.place(t.rodeo._down_point(true))
	await _frames(10)
	_key(KEY_E, true)
	await _frames(10)
	_gate_ok("E beside an enemy's crewed tank: onto its deck", city._riding() == t)
	await _frames(int((VehicleDeck.PRY_SECONDS + 0.5) * 60.0))
	_key(KEY_E, false)
	await _frames(20)
	var out := 0
	for c in crew:
		if c != null and is_instance_valid(c) and not (c as Pawn).has_meta(&"in_vehicle"):
			out += 1
	_gate_ok("held, it pries the hatch: the crew is dragged out and the tank is the player's",
			city._vehicle_pilot.vehicle == t and t.team == 0 and t.crew_count() == 0 and out == 2,
			"driving %s, side %d, %d of 2 out" % [city._vehicle_pilot.vehicle, t.team, out])
	var shells := t.shells
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(10)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await _frames(20)
	_gate_ok("LMB fires its cannon", t.shells > shells)
	# Its seats: Q to the gunner's -- nobody drives now -- and back.
	_key(KEY_Q, true)
	await _frames(2)
	_key(KEY_Q, false)
	await _frames(5)
	var at_gun := t.feet()
	_key(KEY_W, true)
	await _frames(60)
	_key(KEY_W, false)
	_gate_ok("Q: the gunner's seat -- W drives nothing", t.player_seat == Tank.Seat.GUNNER
			and t.feet().distance_to(at_gun) < 0.5, "seat %d, moved %.1f m" % [t.player_seat, t.feet().distance_to(at_gun)])
	_key(KEY_Q, true)
	await _frames(2)
	_key(KEY_Q, false)
	await _frames(5)
	# Back at the wheel, standing: a friend near takes the gunner's seat.
	var gunner := city._spawn_soldier(city.ai_nav.snap(t.feet() + t.global_transform.basis.z * 7.0))
	gunner.team = 0
	gunner.pawn.team = 0
	await _frames(600)
	_gate_ok("Q back at the wheel; a friend near takes the gunner's seat", t.player_drives()
			and t.crew[Tank.Seat.GUNNER] == gunner.pawn and not t.player_guns(),
			"seat %d, gunner %s (%s)" % [t.player_seat, t.crew[Tank.Seat.GUNNER], gunner.state])
	await _save("city_vehicles")
	_key(KEY_M, true)
	await _frames(2)
	_key(KEY_M, false)
	await _frames(10)
	print("[vehicles] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The gate for navigation (Docs/AIPlan.md P3): an encounter brings a tower and
## its neighbours in; a path from the street into a room two storeys up, found
## through the queue; a wall blown out on the far side makes a new way out that
## is taken within a few ticks of the blast; paths round pristine buildings
## materialise nothing; fifty requesters are served inside the budget.
## A point on dry ground within `half` metres of the origin: on terrain the
## sea is not somewhere a path can start or end, and a random point can land
## in it.
func _dry_point(rng: RandomNumberGenerator, half: float) -> Vector3:
	var p := Vector3.ZERO
	for attempt in 64:
		p = city._on_ground(Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half)))
		if not city._terrain_mode or p.y >= city.ai_nav.get_water_level() + city.ai_nav.get_wade():
			return p
	return p

## A point on dry ground in the 80 x 40 m in front of `street`. On the plane
## that is the first draw, every time, so the flat pass asks exactly what it
## always asked.
func _dry_near(rng: RandomNumberGenerator, street: Vector3) -> Vector3:
	var p := street
	for attempt in 64:
		p = city._on_ground(street + Vector3(rng.randf_range(-40.0, 40.0), 0.0,
				rng.randf_range(-40.0, 0.0)))
		if not city._terrain_mode or p.y >= city.ai_nav.get_water_level() + city.ai_nav.get_wade():
			return p
	return p

## Buildings on the terrain (Docs/Terrain.md §21.8): on the world's stud and
## plate grid, and the ground flush with the floor under every column of the
## footprint -- and a build placed on a hillside gets the same.
func _ground_gates() -> void:
	var off_grid := 0
	var off_ground := 0
	var cols := 0
	for id in city._site_ids:
		var b := city.registry.get_building(id)
		var o: Vector3 = b.xform.origin
		if absf(o.x / City.STUD - roundf(o.x / City.STUD)) > 1e-3 				or absf(o.z / City.STUD - roundf(o.z / City.STUD)) > 1e-3 				or absf(o.y / City.PLATE - roundf(o.y / City.PLATE)) > 1e-3:
			off_grid += 1
		off_ground += _unflush(b)
		cols += int(b.recipe.footprint_x) * int(b.recipe.footprint_z)
	print("[nav]   grid: %d building(s), %d off the stud grid, %d of %d footprint columns not flush" % [
		city._site_ids.size(), off_grid, off_ground, cols])
	_gate_ok("every site building is on the stud grid and flush with the ground",
			off_grid == 0 and off_ground == 0)

	# A saved build, aimed at open hillside, placed like the player does.
	var path := BuildRecipe.shipped("cottage")
	# Open, dry hillside: clear of every registry entry -- trees and small
	# items too, since the placer would land a build ON one -- searched on a
	# widening spiral, which a city full of trees needs more tries for.
	var spot := _dry_point(RandomNumberGenerator.new(), 30.0)
	var found_clear := false
	for attempt in 400:
		var ang := float(attempt) * 2.39996
		var cand := city._on_ground(Vector3(cos(ang), 0.0, sin(ang)) * (10.0 + float(attempt) * 0.6))
		if cand.y < city.ai_nav.get_water_level() + 0.5:
			continue
		var clear := true
		for b in city.registry.buildings:
			if city._world_box(b).grow(8.0).has_point(Vector3(cand.x, b.xform.origin.y + 1.0, cand.z)):
				clear = false
				break
		if clear:
			spot = cand
			found_clear = true
			break
	if not found_clear:
		print("[nav]   placed: no clear hillside found; trying anyway at %s" % spot)
	if not city._placer.start(path):
		_gate_ok("a build placed on the hillside gets ground at its floor", false, "no " + path)
		return
	var eye := spot + Vector3(0.0, 30.0, 12.0)
	city._placer.aim_ray(eye, (spot - eye).normalized())
	var before_y := city._ground_y(spot.x, spot.z)
	var id := city._placer.place()
	city._placer.stop()
	await _frames(20)
	var ok := id >= 0 and city._placer.on_ground
	var unflush := -1
	var pb = null
	if id >= 0:
		pb = city.registry.get_building(id)
		unflush = _unflush(pb)
	print("[nav]   placed: %s at %s, ground was %.2f m, floor %.2f m, %d column(s) not flush" % [
		path.get_file(), spot, before_y, pb.xform.origin.y if pb != null else 0.0, unflush])
	_gate_ok("a build placed on the hillside gets ground at its floor",
			ok and unflush == 0)

## Footprint columns of a building whose ground is not at its floor.
func _unflush(b) -> int:
	var box: AABB = CityPlacer.box_of(b)
	var n := 0
	var x0 := int(roundf(box.position.x / City.STUD))
	var z0 := int(roundf(box.position.z / City.STUD))
	for dz in int(roundf(box.size.z / City.STUD)):
		for dx in int(roundf(box.size.x / City.STUD)):
			var gy := float(BrickTerrain.surface_plate(x0 + dx, z0 + dz) + 1) * City.PLATE
			if absf(gy - box.position.y) > 1e-3:
				n += 1
	return n

## What navigation has to get right on a hillside (Docs/Terrain.md §21.7).
func _nav_terrain_gates(rng: RandomNumberGenerator) -> void:
	await _ground_gates()
	# Up the hill: from in front of the lowest building to in front of the
	# highest, which on this seed is metres of climb across the city.
	# The SITE buildings: the registry also holds trees and small items now,
	# and a tree on a hilltop is not a building a path climbs to.
	var lo_b := city.registry.get_building(city._site_ids[0])
	var hi_b := lo_b
	for id in city._site_ids:
		var c := city.registry.get_building(id)
		if c.xform.origin.y < lo_b.xform.origin.y:
			lo_b = c
		if c.xform.origin.y > hi_b.xform.origin.y:
			hi_b = c
	var a := city._on_ground(lo_b.xform * Vector3(lo_b.recipe.footprint_x * City.STUD * 0.5, 0.0, -3.0))
	var z := city._on_ground(hi_b.xform * Vector3(hi_b.recipe.footprint_x * City.STUD * 0.5, 0.0, -3.0))
	var climb := city.ai_nav.find_path(a, z, 120000)
	# Every corner of it is ON the ground (or on bricks above it), never
	# under it: a path that tunnels through a hill is a y=0 path in disguise.
	var worst_under := 0.0
	var top := -INF
	var bottom := INF
	for q in climb:
		worst_under = maxf(worst_under, city._ground_y(q.x, q.z) - q.y)
		top = maxf(top, q.y)
		bottom = minf(bottom, q.y)
	# A corner is where four columns meet and stands on ONE of them, so the
	# ground next to it can be a step higher: a step is the tolerance.
	var step_m := float(AINav.STEP_UP) * City.PLATE + 0.05
	var climb_detail := ("%.1f m to %.1f m: %.0f m long, spans %.1f m, never more than %.2f m under the ground" % [
			a.y, z.y, _path_len(climb), top - bottom, worst_under]) if not climb.is_empty() 			else "none, %.1f m to %.1f m" % [a.y, z.y]
	print("[nav]   climb: %s" % climb_detail)
	_gate_ok("a path climbs the hillside from the lowest building to the highest",
			not climb.is_empty() and worst_under <= step_m
			and absf(climb[0].y - a.y) <= step_m and absf(climb[-1].y - z.y) <= step_m,
			climb_detail)
	_draw_path(climb, Color(0.3, 0.7, 1.0))

	# A hill hides a body. Two points either side of a crest, eye height, and
	# the AI's own line of sight says so -- as physics does, which is what
	# the soldiers' eyes use.
	var hidden := 0
	var tried := 0
	var physics_agrees := 0
	var space := city.get_world_3d().direct_space_state
	for i in 4000:
		if tried >= 12:
			break
		var p := _dry_point(rng, 110.0)
		var dir := Vector3.FORWARD.rotated(Vector3.UP, rng.randf() * TAU)
		var q := city._on_ground(p + dir * rng.randf_range(20.0, 60.0))
		var mid := city._on_ground((p + q) * 0.5)
		var eye_p := p + Vector3.UP * 1.6
		var eye_q := q + Vector3.UP * 1.6
		# A metre of ground over the sight line between two eyes: a crest,
		# not a bump the line grazes.
		if mid.y < (eye_p.y + eye_q.y) * 0.5 + 1.0:
			continue
		tried += 1
		if not city.ai_world.line_clear(eye_p, eye_q) \
				and is_inf(city.ai_world.cover_seconds(eye_p, eye_q, 30, 10.0)):
			hidden += 1
		# What a soldier's own eyes do (Soldier.can_see): a physics ray, and
		# the field where there are no colliders.
		var ray := PhysicsRayQueryParameters3D.create(eye_p, eye_q, Layers.HITSCAN_MASK)
		if not space.intersect_ray(ray).is_empty() or city.ai_world.ground_blocks(eye_p, eye_q):
			physics_agrees += 1
	print("[nav]   crest: %d of %d lines over a crest blocked (a soldier's eyes: %d)" % [
			hidden, tried, physics_agrees])
	_gate_ok("a crest blocks the AI's sight and is cover no gun wears away",
			tried > 0 and hidden == tried and physics_agrees == tried,
			"%d of %d lines over a crest blocked (physics: %d)" % [hidden, tried, physics_agrees])

	# And nobody walks into the sea.
	var sea := city.ai_nav.get_water_level()
	var wet := Vector3.INF
	for i in 400:
		var w := city._on_ground(Vector3(rng.randf_range(-200.0, 200.0), 0.0,
				rng.randf_range(-200.0, 200.0)))
		if w.y < sea - 1.0:
			wet = w
			break
	if wet == Vector3.INF:
		print("[nav]   (no ground under the sea within 200 m; the sea gate is skipped)")
	else:
		var swim := city.ai_nav.find_path(a, wet, 40000)
		print("[nav]   sea: seabed %.1f m under a %.1f m sea; can stand %s, path %s" % [
				wet.y, sea, city.ai_nav.can_stand(wet),
				"none" if swim.is_empty() else "ends at %.2f m" % swim[-1].y])
		_gate_ok("the sea is not somewhere a path goes",
				not city.ai_nav.can_stand(wet) and (swim.is_empty()
				or swim[-1].y >= sea - city.ai_nav.get_wade() - 0.05),
				"seabed %.1f m under a %.1f m sea" % [wet.y, sea])

func _run_nav_pass() -> void:
	print("[nav] paths through a city that falls down")
	var b := city.registry.get_building(0)
	for c in city.registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5, 30.0, -25.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 4.0, fz * 0.5), Vector3.UP)
	await _frames(4)

	# The encounter: the tower and whatever else its zone touches.
	var zone := city._world_box(b).grow(6.0)
	var enc := city.start_encounter(zone)
	var guard := 0
	while not enc.is_ready() and guard < 300:
		await _frames(1)
		guard += 1
	await _frames(30)
	var all_in := true
	for id in enc.buildings:
		if not city.registry.get_building(id).is_materialised():
			all_in = false
	_gate_ok("an encounter brings its buildings in", all_in and enc.buildings.size() >= 1,
			"%d building(s) in %d tick(s)" % [enc.buildings.size(), guard])

	# From the street in front of the tower to a room two storeys up. On
	# terrain the tower stands on its pad and the street is wherever the
	# hillside is, so both are measured from the ground rather than from 0.
	var floor0 := b.xform.origin.y
	var street := city._on_ground(b.xform * Vector3(fx * 0.5, 0.0, -4.0))
	var storey_y := (TowerRecipe.SLAB_PLATES + 2 * TowerRecipe.STOREY_PLATES) * City.PLATE
	var room := city.ai_nav.snap(b.xform * Vector3(fx * 0.3, storey_y + 0.05, fz * 0.3))
	_gate_ok("there is floor to stand on two storeys up",
			absf(room.y - floor0 - storey_y) < 0.3,
			"snapped to %.2f m, the floor is at %.2f" % [room.y, floor0 + storey_y])
	# A tower is sealed at street level: no door, and its sills are four plates
	# up -- over a course, which nobody steps and nobody jumps. The way in is
	# made, not found (AI.md 3.8, "make a door").
	var sealed := city.ai_nav.find_path(street, room, 20000)
	_gate_ok("a sealed tower has no way in from the street", sealed.is_empty())
	var breach := b.xform * Vector3(fx * 0.5, 1.0, 0.2)
	var id_in := await _path_after_blast(breach, street, room)
	var path_in := city.ai_nav.get_path(id_in)
	var inside := false
	var top := 0.0
	var box := city._world_box(b)
	for p in path_in:
		if box.grow(-0.4).has_point(p + Vector3.UP * 0.5) and p.y < floor0 + 1.0:
			inside = true
		top = maxf(top, p.y)
	_gate_ok("breached, a path from the street through the hole and up to the room",
			city.ai_nav.get_status(id_in) == AINav.DONE and path_in[-1].distance_to(room) < 0.8
			and inside and top >= room.y - 0.2 and _passes(path_in, breach),
			"%d corners, %.0f m, %d tick(s) from the blast" % [path_in.size(),
			_path_len(path_in), _last_wait])
	_draw_path(path_in, Color(1.0, 0.9, 0.2))

	# Out the far side: back down and out through the breach, the long way...
	var far := city._on_ground(b.xform * Vector3(fx * 0.5, 0.0, fz + 4.0))
	var before := city.ai_nav.find_path(room, far)
	# ...until the far wall is blown open too.
	var hole := b.xform * Vector3(fx * 0.5, 1.0, fz - 0.2)
	var id_out := await _path_after_blast(hole, room, far)
	var after := city.ai_nav.get_path(id_out)
	_gate_ok("a wall shot out on the far side is the new way out",
			not after.is_empty() and _passes(after, hole)
			and (before.is_empty() or _path_len(after) < _path_len(before) - 2.0),
			"%.0f m, was %s; %d tick(s) from the blast to the new path" % [
			_path_len(after), ("%.0f m" % _path_len(before)) if not before.is_empty() else "none",
			_last_wait])
	_draw_path(after, Color(0.3, 1.0, 0.4))

	# Paths round pristine buildings, far from the encounter: they ask the
	# shells, and nothing is materialised to answer them.
	var mat0: int = city.registry.report().materialised
	var promos := city._promotions
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var found := 0
	for i in 20:
		var a := _dry_point(rng, 120.0)
		var z := _dry_point(rng, 120.0)
		if not city.ai_nav.find_path(a, z, 30000).is_empty():
			found += 1
	_gate_ok("paths across the city materialise nothing",
			city.registry.report().materialised == mat0 and city._promotions == promos and found >= 15,
			"%d of 20 found, %d materialised before and after" % [found, mat0])
	if city._terrain_mode:
		await _nav_terrain_gates(rng)

	# Fifty requesters at once, served from the scheduler's share.
	city._nav_worst_us = 0
	city.ai_nav.reset_stats()
	var ids := []
	for i in 50:
		var a := _dry_near(rng, street)
		var z := _dry_near(rng, street)
		ids.append(city.ai_nav.request_path(a, z, rng.randf() * 10.0))
	var frames := 0
	while city.ai_nav.pending() > 0 and frames < 600:
		await city.get_tree().physics_frame
		frames += 1
	var answered := 0
	for id in ids:
		if city.ai_nav.get_status(id) != AINav.PENDING:
			answered += 1
	print("[nav]   %s" % city.ai_nav.get_stats())
	var found_paths := 0
	for id in ids:
		if city.ai_nav.get_status(id) == AINav.DONE:
			found_paths += 1
	_gate_ok("fifty requesters answered inside the nav budget",
			answered == 50 and city._nav_worst_us < City.NAV_BUDGET_US + 400,
			"%d answered (%d found) in %d tick(s); worst tick %d us against %d" % [
			answered, found_paths, frames, city._nav_worst_us, City.NAV_BUDGET_US])
	city._ai_label.visible = true
	city.dev_hud.update_ai_label()
	city.camera.position = b.xform * Vector3(fx * 0.5 + 18.0, 20.0, fz + 14.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 3.0, fz * 0.5), Vector3.UP)
	await _frames(20)
	await _save("city_nav")
	print("[nav] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Blow a hole at `at`, and once the blast has been committed (and the columns
## it touched forgotten), queue a path. Returns the request once it is answered.
func _path_after_blast(at: Vector3, from: Vector3, to: Vector3) -> int:
	var n0 := city.authority.commands.size()
	city._blast(at, 1.3)
	var id := -1
	_last_wait = 0
	while _last_wait < 600:
		await city.get_tree().physics_frame
		_last_wait += 1
		if id < 0 and city._damage_queue.is_empty() and city.authority.commands.size() > n0:
			id = city.ai_nav.request_path(from, to, 5.0)
		if id >= 0 and city.ai_nav.get_status(id) != AINav.PENDING:
			break
	return id

func _passes(p: PackedVector3Array, point: Vector3) -> bool:
	for i in range(1, p.size()):
		var a: Vector3 = p[i - 1]
		var b: Vector3 = p[i]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var t := 0.0
		if ab.length_squared() > 0.0:
			t = clampf(Vector2(point.x - a.x, point.z - a.z).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var q := a.lerp(b, t)
		# Through the hole, not over it: within half a metre of its height,
		# which on terrain is wherever the building's floor is.
		if Vector2(q.x - point.x, q.z - point.z).length() < 1.6 and q.y < point.y + 0.5:
			return true
	return false

func _path_len(p: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, p.size()):
		total += p[i - 1].distance_to(p[i])
	return total

func _draw_path(p: PackedVector3Array, col: Color) -> void:
	if p.size() < 2:
		return
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.no_depth_test = true
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for q in p:
		im.surface_add_vertex(q + Vector3.UP * 0.3)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	city.add_child(mi)

## The P8 population round `center` (the --stress --agents pass): six squads of
## six in a ring 30-60 m out, three flyers, a herd, and 300 swarm rows 50-80 m
## out -- all after one player-side body at `center` (the player's pawn if it
## is out, a stand-in otherwise). The ImportanceBudget keeps ten smart.
func _spawn_many(center: Vector3) -> void:
	if city.ai_services.world3d == null:
		city.ai_services.world3d = city.get_world_3d()
		city.ai_services.on_structure_hit = city._gun.on_structure_hit
	city.budget = ImportanceBudget.new()
	var target := city._player_pawn
	if target == null or not is_instance_valid(target):
		target = Pawn.spawn(city, city.ai_nav.snap(city._on_ground(center)), 0, true, 1e7)
		Soldier._greybox(target, 0)
		city.ai_services.add_pawn(target)
	_many_target = target
	city.budget.players = [target]
	var rng := RandomNumberGenerator.new()
	rng.seed = 88
	for q in 6:
		var ang := TAU * q / 6.0
		var at := center + Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(30.0, 60.0)
		var members: Array[Soldier] = []
		for i in 6:
			var so := city._spawn_soldier(city.ai_nav.snap(city._on_ground(at + Vector3((i % 3) * 1.5, 0.0, floori(i / 3.0) * 1.5))))
			members.append(so)
			city.budget.add(so)
		city.squads.append(Squad.make(city.ai_services, city, members, 1))
		_many.soldiers += 6
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	for i in 3:
		var ang := TAU * i / 3.0
		var g := GunInstance.from_result(GunGenerator.generate(city._gun_library, city._combat_rng.randi(),
				WeaponClass.builtin(&"rifle"), 1))
		var f := Flyer.spawn(city.ai_services, city, city._on_ground(center + Vector3(cos(ang), 0.0, sin(ang)) * 40.0)
				+ Vector3.UP * 30.0, 1, g)
		city.budget.add(f)
		_many.flyers += 1
	var home := center + Vector3(-25.0, 0.0, -20.0)
	var herd := AnimalPack.new(city.ai_services, -1, city._on_ground(home), 5)
	for i in 5:
		city.budget.add(Animal.spawn(city.ai_services, city, city.ai_nav.snap(city._on_ground(home + Vector3(i * 1.5, 0.0, 0.0))),
				herd, 60.0, 400 + i if i < 2 else -1))
		_many.animals += 1
	var pts := PackedVector3Array()
	for i in 300:
		var ang := rng.randf() * TAU
		pts.append(city._on_ground(center + Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(50.0, 80.0)))
	city.swarm = SwarmSide.new()
	city.swarm.boxes = func() -> Array:
		var out := []
		for id in city._near_buildings(center, 150.0):
			var b := city.registry.get_building(id)
			if b != null and not b.toppled:
				out.append(city._world_box(b))
		return out
	city.swarm.spawn_promoted = func(pos: Vector3, hp: float) -> Object:
		var pack := AnimalPack.new(city.ai_services, 1, pos, _many.hunters)
		var an := Animal.spawn(city.ai_services, city, city.ai_nav.snap(pos), pack, maxf(hp, 1.0), -1,
				AgentTier.DIRECTED)
		an.swarm_born = true
		pack.hunt(_many_target)
		city.budget.add(an)
		_many.hunters += 1
		return an
	city.swarm.node_room = func() -> int:
		return ImportanceBudget.SMART_CAP + ImportanceBudget.DIRECTED_CAP - city.budget.agents.size()
	city.swarm.setup(city.ai_services, city, 1, pts, 40.0, 17)
	city.swarm.refresh()
	city.budget.demote_to_swarm = city.swarm.demote
	print("[city] %d soldiers, %d flyers, %d animals, %d swarm rows round %v" % [_many.soldiers,
			_many.flyers, _many.animals, city.swarm.alive(), center])

## The squad gate (AIPlan P6): a tower is sealed at street level, so a squad told
## to clear a ground-floor room blows its own door (mouse-holing, AI.md 6.2)
## through the authority, stacks either side of it, flashes the room, goes in
## crisscross, drops whoever is in there, and reports the room clear. The blast
## is in the log, so the twins replay the hole.
func _run_squad_pass() -> void:
	print("[squad] a squad clears a room in a sealed tower")
	var b := city.registry.get_building(0)
	for c in city.registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var fx: float = b.recipe.footprint_x * City.STUD
	var _fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5, 14.0, -16.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 1.0, 2.0), Vector3.UP)
	var enc := city.start_encounter(city._world_box(b).grow(6.0))
	var guard := 0
	while not enc.is_ready() and guard < 300:
		await _frames(1)
		guard += 1
	await _frames(20)
	# A ground-storey room against the street wall (-Z).
	var cell := BrickWorld.get_cell_size()
	var pick: Room = null
	for r in city.registry.rooms_of(b.id):
		if r.lo.z > TowerRecipe.WALL_THICK + RoomManifest.WALL_MARGIN:
			continue
		if pick == null or r.lo.y < pick.lo.y or (r.lo.y == pick.lo.y and r.size.x > pick.size.x):
			pick = r
	_gate_ok("the tower has a ground-storey room on the street", pick != null)
	if pick == null:
		city.get_tree().quit(1)
		return
	var box := AABB(Vector3(pick.lo) * cell, Vector3(pick.size) * cell)
	var room := RoomTactics.make(b.xform, box, pick.id)
	# Somebody in there, whom nobody has seen.
	var inside := city.ai_nav.snap(b.xform * (box.position + box.size * Vector3(0.5, 0.0, 0.7)))
	var defender := Pawn.spawn(city, inside, 0, true, 100.0)
	Soldier._greybox(defender, 0)
	city.ai_services.add_pawn(defender)
	var street := city._on_ground(b.xform * Vector3(box.get_center().x, 0.0, -9.0))
	var q := city._spawn_squad(street)
	await _frames(10)
	var n0 := city.authority.commands.size()
	var o := SquadMsg.Order.make(SquadMsg.OrderKind.CLEAR_ROOM)
	o.room = room
	o.wall_thick = TowerRecipe.WALL_THICK * City.STUD
	var oid := q.give(o)
	var t0 := Engine.get_physics_frames()
	var inside_n := {}
	var done: SquadMsg.Report = null
	while done == null and Engine.get_physics_frames() - t0 < 30 * 90:
		await city.get_tree().physics_frame
		for m in q.members:
			if room.contains(m.pawn.feet()):
				inside_n[m.get_instance_id()] = true
		for r in q.reports:
			if r.order_id == oid and r.kind != SquadMsg.ReportKind.ACCEPTED:
				done = r
	var secs := float(Engine.get_physics_frames() - t0) / 30.0
	var blasts := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.BLAST:
			blasts += 1
	print("[squad] events %s" % [q.events.keys()])
	_gate_ok("no door, so it makes one: a BLAST through the authority",
			bool(q.events.get("breach", false)) and q.events.has("breached") and blasts >= 1,
			"%d BLAST(s)" % blasts)
	_gate_ok("it stacks, flashes the room and goes in", q.events.has("stacked")
			and q.events.has("flashed") and inside_n.size() >= 3,
			"%d of 4 went in" % inside_n.size())
	_gate_ok("the room is cleared and the order reported DONE",
			done != null and done.kind == SquadMsg.ReportKind.DONE and defender.health.is_dead(),
			"%s in %.1f s; defender %s" % [done, secs, "down" if defender.health.is_dead() else "UP"])
	var said := {}
	for l in city.ai_services.callouts.said:
		said[l[2]] = true
	print("[squad] said %s" % [said.keys()])
	# The picture: the hole it made, from the street.
	var hole: Vector3 = q.events.get("opening", street)
	var back := street - hole
	back.y = 0.0
	city.camera.position = hole + back.normalized() * 7.0 + Vector3.UP * 2.5
	city.camera.look_at(hole + Vector3.UP * 0.9, Vector3.UP)
	await _frames(30)
	await _save("city_squad")
	_check_log_replays()
	print("[squad] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The fall rule in the city (Docs/AI.md 3.11, AIPlan P7): a mech dropped twelve
## bricks onto a tower's roof goes through three floors -- each a SHEAR the host
## commits -- and stops on the fourth down; the pieces it broke land without
## breaking anything more; and the log's twin buildings replay every break.
func _run_mechfall_pass() -> void:
	print("[mechfall] a mech dropped onto a tower")
	var b := city.registry.get_building(0)
	for c in city.registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var enc := city.start_encounter(city._world_box(b).grow(4.0))
	var guard := 0
	while not enc.is_ready() and guard < 300:
		await _frames(1)
		guard += 1
	await _frames(20)
	# Over the middle of the biggest room of the top storey: over floor, not a
	# column or a wall.
	var cell := BrickWorld.get_cell_size()
	var pick: Room = null
	for r in city.registry.rooms_of(b.id):
		if pick == null or r.lo.y > pick.lo.y or (r.lo.y == pick.lo.y
				and r.size.x * r.size.z > pick.size.x * pick.size.z):
			pick = r
	var mid := b.xform * ((Vector3(pick.lo) + Vector3(pick.size) * Vector3(0.5, 0.0, 0.5)) * cell)
	# The roof's surface there -- the highest under the mech's footprint, which is
	# what it lands on. top_at is only a bound (the parapet is above it), and a
	# roof has openings.
	var roof := -INF
	var high := city.ai_world.top_at(mid.x, mid.z) + 1.0
	for r in [0.0, Mech.RADIUS * 0.5, Mech.RADIUS * 0.9]:
		for k in (1 if r == 0.0 else 8):
			var a := k * TAU / 8.0
			roof = maxf(roof, city._next_floor_below(Vector3(mid.x + cos(a) * r, high, mid.z + sin(a) * r)))
	city.camera.position = Vector3(mid.x + 18.0, roof + 4.0, mid.z - 18.0)
	city.camera.look_at(Vector3(mid.x, roof - 6.0, mid.z), Vector3.UP)
	var n0 := city.authority.commands.size()
	var feet := Vector3(mid.x, roof + 12.0 * FallRule.BRICK + 0.02, mid.z)
	var m := Mech.spawn(city, feet, 0.0, 1)
	city.vehicles.wire_mech(m)
	city.vehicles._loose_mechs.append(m)
	var t0 := Engine.get_physics_frames()
	var still := 0
	while still < 30 and Engine.get_physics_frames() - t0 < 30 * 12:
		await city.get_tree().physics_frame
		still = still + 1 if m.body.is_on_floor() and not m.fall.is_carrying() else 0
	var shears := 0
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.kind == DamageLog.Kind.SHEAR and e.flags & DamageLog.FLAG_WHOLE:
			shears += 1
	var judged := m.fall.landings.map(func(l): return "%.1f%s" % [float(l[1]), "!" if l[2] else ""])
	var storeys := (roof - m.feet().y) / (TowerRecipe.STOREY_PLATES * City.PLATE)
	_gate_ok("dropped twelve bricks onto the roof, it goes through three floors",
			m.fall.breaks == 3 and shears == 3,
			"%d broken, %d SHEAR(s); landings (bricks of energy) %s" % [m.fall.breaks, shears, judged])
	_gate_ok("and stands on the floor three storeys down", absf(storeys - 3.0) < 0.35
			and m.body.is_on_floor(), "%.2f storeys under the roof" % storeys)
	# The picture: down through the holes it made.
	city.camera.position = Vector3(mid.x + 4.0, roof + 12.0, mid.z + 4.0)
	city.camera.look_at(m.feet() + Vector3.UP * 3.0, Vector3.UP)
	await _frames(60)
	await _save("city_mechfall")
	_check_log_replays()
	print("[mechfall] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The vertical slice (AIPlan P4): a soldier in the city, against the player's
## pawn in a street. It sees and fires; its misses wear the buildings through the
## WorldAuthority like anybody's; it never fires through a wall; and the log --
## its rounds in it -- still replays into the same city.
func _run_soldier_pass() -> void:
	print("[soldier] one soldier in the city")
	var b := city.registry.get_building(0)
	var fx: float = b.recipe.footprint_x * City.STUD
	var street := city.ai_nav.snap(b.xform * Vector3(fx * 0.5, 0.0, -3.0))
	city.camera.global_position = street + Vector3(0.0, 6.0, 0.0)
	city._enter_pawn(street)
	city._player.drive_uncaptured = true
	city._player_pawn.health.layer_configs[-1].max_value = 100000.0
	city._player_pawn.health.reset()
	city.camera.rotation = Vector3(0.0, 0.0, 0.0)   # the player looks down -Z, out of the street
	await _frames(20)
	var spot := city.ai_nav.snap(street + Vector3(0.0, 0.0, -18.0))
	var so := city._spawn_soldier(spot)
	so.pawn.intents.look_yaw = PI   # toward the player
	var n0 := city.authority.commands.size()
	var hp0 := city._player_pawn.health.total_current()
	var t0 := Engine.get_physics_frames()
	while Engine.get_physics_frames() - t0 < 30 * 16:
		await city.get_tree().physics_frame
	var chips := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	_gate_ok("the soldier sees the player's pawn and fires", so.shots > 5
			and city._player_pawn.health.total_current() < hp0,
			"%d round(s); %.0f hp taken; now %s" % [so.shots, hp0 - city._player_pawn.health.total_current(), so.state])
	_gate_ok("its misses wear the city through the authority", chips > 0, "%d CHIP(s)" % chips)
	_gate_ok("it never fired through a wall", so.blocked_shots == 0,
			"%d of %d" % [so.blocked_shots, so.shots])
	city._leave_pawn()
	city.camera.global_position = spot + Vector3(-4.0, 3.0, -6.0)
	city.camera.look_at(street + Vector3.UP, Vector3.UP)
	await _frames(10)
	await _save("city_soldier")
	_check_log_replays()
	print("[soldier] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _run_storeys_pass() -> void:
	var units := city.registry.storey_units
	print("[storeys] storey units %s" % ("on" if units else "OFF (--whole)"))
	var b: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build() or c.is_materialised() or city._wide_ids.has(c.id) or city._is_tree(c.id):
			continue
		if b == null or c.recipe.courses * c.recipe.footprint_x * c.recipe.footprint_z \
				> b.recipe.courses * b.recipe.footprint_x * b.recipe.footprint_z:
			b = c
	if b == null:
		print("[storeys] no tower")
		city.get_tree().quit(1)
		return
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	var lines := city.registry.storey_lines(b)
	var n := lines.size() - 1
	@warning_ignore("integer_division")
	var mid := n / 2
	var mid_y: float = (lines[mid] + 10) * City.PLATE
	# Bricks drawn once first, on another building: the first brick drawn
	# compiles the pipeline (most of a second), which is not this tower's cost.
	for c in city.registry.buildings:
		if c != b and not c.is_build() and not c.is_materialised() and not city._is_tree(c.id) 				and c.recipe.courses <= 30:
			var cfx: float = c.recipe.footprint_x * City.STUD
			city.camera.position = c.xform * Vector3(cfx * 0.5, 4.0, -20.0)
			city.camera.look_at(c.xform * Vector3(cfx * 0.5, 4.0, 0.0), Vector3.UP)
			city._blast(c.xform * Vector3(cfx * 0.5, 2.0, 0.0), City.BLAST_RADIUS)
			await _frames(60)
			break
	# Facing away while the city streams in: a look at it for six ticks would
	# make it bricks before the shot (_aim_promote).
	city.camera.position = b.xform * Vector3(fx * 0.5, mid_y, -45.0)
	city.camera.look_at(city.camera.position + (b.xform.basis * Vector3(0, 0, -1)), Vector3.UP)
	await _frames(120)
	var mem0: int = int(city.world.get_memory_report().total_bytes)
	var static0 := OS.get_static_memory_usage()
	var vid0 := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	var p0 := city._promote_ms
	var whole_bricks := 0   ## the template's, once there is a chunk to ask
	city.camera.look_at(b.xform * Vector3(fx * 0.5, mid_y, fz * 0.5), Vector3.UP)
	city._blast(b.xform * Vector3(fx * 0.5, mid_y, 0.0), City.BLAST_RADIUS)
	var worst := 0.0
	var worst_at := -1
	var worst_parts := {}
	var prev := Time.get_ticks_usec()
	var shown := -1
	for t in 90:
		await city.get_tree().physics_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - prev) / 1000.0
		prev = now
		if dt > worst:
			# What the tick before this await spent, part by part (_part, _mark).
			worst = dt
			worst_at = t + 1
			worst_parts = city._prof.duplicate()
		if shown < 0 and b.is_materialised() and not city._shells.has(b.id) and not city._bands_building(b.id):
			shown = t + 1
	var rep := city.registry.storey_report(b.id)
	var bricks: int = int(rep.get("bricks", 0)) if bool(rep.get("banded", false)) \
			else city.world.get_block_count(b.chunk)
	var occ: int = city.world.get_occupancy_bytes(b.chunk) if b.is_materialised() else 0
	whole_bricks = city.world.get_block_count(b.chunk) if b.is_materialised() else 0
	print("[storeys] first hit on building %d (%d bricks whole, %d storeys):" % [b.id,
			whole_bricks, n])
	print("[storeys]   promote %.1f ms, worst frame %.1f ms in 90 ticks, shot shown at tick %d" % [
			city._promote_ms - p0, worst, shown])
	print("[storeys]   %d bricks laid (storeys %s), its grid %.2f MB; BrickWorld %+.1f MB, static %+.1f MB, video %+.1f MB" % [
			bricks, str(rep.get("laid", "all")), occ / 1048576.0,
			(int(city.world.get_memory_report().total_bytes) - mem0) / 1048576.0,
			(OS.get_static_memory_usage() - static0) / 1048576.0,
			(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) - vid0) / 1048576.0])
	var parts := []
	for k in worst_parts:
		if float(worst_parts[k]) >= 1.0:
			parts.append("%s %.1f" % [k, float(worst_parts[k])])
	print("[storeys]   the worst frame was tick %d; its physics tick: %s; process %.1f ms" % [
			worst_at, ", ".join(parts), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	_gate_ok("the shot shows within 15 ticks", shown > 0 and shown <= 15, "tick %d" % shown)
	if not units:
		print("[storeys] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1 if city._gate_fail > 0 else 0)
		return
	_gate_ok("only the storeys the shot reached are bricks", bricks > 0 and bricks <= 2000,
			"%d bricks, storeys %s" % [bricks, str(rep.get("laid", []))])
	_gate_ok("a rest shell draws the storeys still whole", city._rest_shells.has(b.id))

	# The storey blown out, everything in it, until nothing holds what is over it.
	var made0 := city.shell_pieces_made
	var bricked0 := city.shell_pieces_bricked
	var dy: float = lines[mid] * City.PLATE
	for h in [1.0, 1.8]:
		var x := 0.5
		while x < fx:
			var z := 0.5
			while z < fz:
				city._blast(b.xform * Vector3(x, dy + h, z), 1.0)
				z += 1.0
			x += 1.0
	var piece: ShellPiece = null
	var t2 := 0
	while t2 < 600 and piece == null:
		await city.get_tree().physics_frame
		t2 += 1
		for p in city._shell_pieces:
			if is_instance_valid(p) and p.building == b.id:
				piece = p
	var rep2 := city.registry.storey_report(b.id)
	print("[storeys] storey %d blown out: %s at tick %d; building laid %s, cut at %d, %d bricks" % [
			mid, "a shell piece" if piece != null else "no shell piece", t2,
			str(rep2.get("laid", [])), int(rep2.get("cut", -1)), int(rep2.get("bricks", 0))])
	_gate_ok("the part above leaves as one shell piece", piece != null and city.shell_pieces_made == made0 + 1,
			"%d made" % (city.shell_pieces_made - made0))
	if piece != null:
		_gate_ok("it is every storey over the one that went", piece.hi == n and piece.lo <= mid + 3,
				"storeys %d-%d" % [piece.lo, piece.hi - 1])
	# The storey blown out, the ones its blasts reached and the ones its wreckage
	# landed on (_shear_building) -- a few storeys, not the tower.
	@warning_ignore("integer_division")
	_gate_ok("and the building stays a few storeys of bricks, not the tower",
			int(rep2.get("bricks", 0)) <= whole_bricks / 4,
			"%d of %d bricks" % [int(rep2.get("bricks", 0)), whole_bricks])
	var t3 := 0
	var bottom0 := piece.world_box(city.registry).position.y if piece != null else 0.0
	var fell := 0.0
	while t3 < 600 and city.shell_pieces_bricked == bricked0:
		await city.get_tree().physics_frame
		t3 += 1
		# Somebody watching it fall, wherever it goes: a landing nobody is
		# near lands whole and stays a shell, as a brick piece's does.
		if piece != null and is_instance_valid(piece):
			var pbox := piece.world_box(city.registry)
			fell = maxf(fell, bottom0 - pbox.position.y)
			city.camera.position = Vector3(pbox.get_center().x, pbox.position.y + 2.0,
					pbox.get_center().z) - city.camera.global_transform.basis.z * 25.0
	# A top that tipped onto what is left of its storey and came to rest leaning
	# there, a few metres down, never landed hard: it stays a shell, as a brick
	# piece that settles does. One that fell must land hard and become bricks.
	print("[storeys] its bottom fell %.1f m; %d piece(s) made bricks after %d ticks" % [fell,
			city.shell_pieces_bricked - bricked0, t3])
	_gate_ok("a top that falls lands hard, close by, and becomes ONE brick piece",
			city.shell_pieces_bricked == bricked0 + 1 or fell < STOREY_FALL,
			"fell %.1f m, %d piece(s) made bricks" % [fell, city.shell_pieces_bricked - bricked0])
	await _frames(120)

	# Given back and laid again: the same record. Of the template's blocks: a
	# room's piece laid as bricks went on the end and is not laid again.
	var tpl: int = city.registry.get_building(b.id).blocks
	var dead := {}
	for d in city.world.get_dead_blocks(b.chunk):
		if d < tpl:
			dead[d] = true
	for d in city.world.get_detached_blocks(b.chunk):
		if d < tpl:
			dead[d] = true
	var laid: PackedInt32Array = (city.registry.storey_report(b.id).laid as PackedInt32Array).duplicate()
	city._demote(b.id, 0.0)
	city._materialised.erase(b.id)
	await _frames(5)
	city._promote(b.id, true, laid)
	await _frames(5)
	var again := {}
	for d in city.world.get_dead_blocks(b.chunk):
		if d < tpl:
			again[d] = true
	var same := again.size() == dead.size()
	for d in dead:
		if not again.has(d):
			same = false
	_gate_ok("given back and laid again, its record replays", same,
			"%d dead before, %d after" % [dead.size(), again.size()])
	# Off balance: another tower's ground storey blown out under the west three
	# fifths of it. What is left still carries it -- in compression, which the
	# stress solve never fails -- but off to one side: it tips (storey_gave_way),
	# leaving as one shell piece over the stump's edge.
	var tb: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c == b or c.is_build() or c.is_materialised() or city._wide_ids.has(c.id) or city._is_tree(c.id) \
				or c.recipe.courses < 60:
			continue
		tb = c
		break
	if tb != null:
		var tfx: float = tb.recipe.footprint_x * City.STUD
		var tfz: float = tb.recipe.footprint_z * City.STUD
		city.camera.position = tb.xform * Vector3(tfx * 0.5, 20.0, -50.0)
		city.camera.look_at(tb.xform * Vector3(tfx * 0.5, 10.0, tfz * 0.5), Vector3.UP)
		# Low enough that no blast reaches the storey over it (2.8 m): the piece
		# it leaves as would be made bricks by the next blast in the queue.
		for h in [0.9, 1.6]:
			var x := 0.5
			while x < tfx * 0.6:
				var z := 0.5
				while z < tfz:
					city._blast(tb.xform * Vector3(x, h, z), 1.0)
					z += 1.0
				x += 1.0
		var tp: ShellPiece = null
		var found := false   ## a freed piece compares equal to null: kept apart
		var tilt := 0.0
		var t4 := 0
		while t4 < 900 and (not found or t4 < 600):
			await city.get_tree().physics_frame
			t4 += 1
			if not found:
				for p in city._shell_pieces:
					if is_instance_valid(p) and p.building == tb.id:
						tp = p
						found = true
			elif is_instance_valid(tp):
				tilt = maxf(tilt, rad_to_deg(tp.global_transform.basis.y.angle_to(Vector3.UP)))
		print("[storeys] building %d's ground storey blown out under its west side: %s, tilted %.0f degrees" % [
				tb.id, "a shell piece" if found else "no shell piece", tilt])
		_gate_ok("off balance, the rest tips over as one shell piece", found and tilt > 20.0,
				"tilt %.0f degrees before it landed" % tilt)

	# A build is laid a storey at a time too, cut at the floors the floor finder
	# finds (Structures 2.4): a watchtower set down in the street by the big
	# tower, one storey hit, then its first floor's storey blown out.
	var wt := BuildRecipe.from_dict(JSON.parse_string(
			FileAccess.get_file_as_string("res://builds/watchtower.json")))
	var wid := city.registry.register_build(wt, Transform3D(Basis(), b.xform * Vector3(fx * 0.5, 0.0, -8.0)))
	city._index_building(wid)
	city._make_shell(wid)
	var wb := city.registry.get_building(wid)
	var wlines := city.registry.storey_lines(wb)
	var wbox := city.registry.local_box(wid)
	city.camera.position = wb.xform * Vector3(wbox.get_center().x, 6.0, -10.0)
	city.camera.look_at(wb.xform * wbox.get_center(), Vector3.UP)
	await _frames(20)
	var wmid := (wlines[1] + wlines[2]) * 0.5 * City.PLATE
	city._blast(wb.xform * Vector3(wbox.get_center().x, wmid, wbox.position.z), 0.6)
	await _frames(30)
	var wrep := city.registry.storey_report(wid)
	print("[storeys] the watchtower (%d storeys: %s), hit: laid %s, rest shell %s" % [
			wlines.size() - 1, str(wlines), str(wrep.get("laid", [])), city._rest_shells.has(wid)])
	_gate_ok("a build hit lays the storey hit, and its rest shell draws the others",
			bool(wrep.get("banded", false)) and city._rest_shells.has(wid)
			and (wrep.laid as PackedInt32Array).size() < wlines.size() - 1,
			"laid %s of %d" % [str(wrep.get("laid", [])), wlines.size() - 1])
	var wmade := city.shell_pieces_made
	for pass_n in 10:
		for h in [wlines[1] * City.PLATE + 0.5, wlines[1] * City.PLATE + 1.3, wlines[1] * City.PLATE + 2.1]:
			for gx in 3:
				for gz in 3:
					city._blast(wb.xform * Vector3(wbox.position.x + (gx + 0.5) * wbox.size.x / 3.0, h,
							wbox.position.z + (gz + 0.5) * wbox.size.z / 3.0), 0.6)
		await _frames(8)
	var wpiece := false
	for t6 in 300:
		await city.get_tree().physics_frame
		if city.shell_pieces_made > wmade or wb.cut_storey >= 0:
			wpiece = true
			break
	print("[storeys] the watchtower's first floor blown out: cut at %d, %d shell piece(s) made" % [
			wb.cut_storey, city.shell_pieces_made - wmade])
	_gate_ok("and what is over a storey of it that gives way leaves as one shell piece",
			wpiece and wb.cut_storey >= 0, "cut at %d" % wb.cut_storey)

	# The brick budget (Docs/Space.md 5.3): just over what is in play now, and
	# four more towers shot. The quietest storeys furthest from the camera go
	# back to their rest shells until it is met again -- never the one stood by.
	var budget0 := city.brick_budget
	city.brick_budget = city.bricks_in_play() + 3000
	var given0 := city.storeys_given_back
	var shot: Array = []
	for c in city.registry.buildings:
		if shot.size() >= 4:
			break
		if c == b or c == tb or c.is_build() or c.is_materialised() or city._wide_ids.has(c.id) \
				or city._is_tree(c.id) or c.recipe.courses < 36:
			continue
		shot.append(c)
	for c in shot:
		var cfx: float = c.recipe.footprint_x * City.STUD
		city._blast(c.xform * Vector3(cfx * 0.5, 9.0, 0.0), City.BLAST_RADIUS)
	var near: BuildingRegistry.Building = shot[shot.size() - 1] if not shot.is_empty() else null
	if near != null:
		var nfx: float = near.recipe.footprint_x * City.STUD
		city.camera.position = near.xform * Vector3(nfx * 0.5, 9.0, -6.0)
		city.camera.look_at(near.xform * Vector3(nfx * 0.5, 9.0, 0.0), Vector3.UP)
	var peak := 0
	for t5 in 30 * 10:
		await city.get_tree().physics_frame
		peak = maxi(peak, city.bricks_in_play())
	var after := city.bricks_in_play()
	print("[storeys] brick budget %d: peak %d, %d after ten seconds; %d storey(s) given back to their shells" % [
			city.brick_budget, peak, after, city.storeys_given_back - given0])
	_gate_ok("over the brick budget, the far storeys go back to their shells until it is met",
			city.storeys_given_back > given0 and after <= city.brick_budget + 2500,
			"%d in play of %d" % [after, city.brick_budget])
	_gate_ok("and not the storey stood by", near == null or (near.is_materialised()
			and not near.storeys_laid.is_empty()),
			"building %d laid %s" % [near.id if near != null else -1,
			str(near.storeys_laid) if near != null else "-"])
	city.brick_budget = budget0

	# Co-op and saves: the host's log, replayed into fresh twins, has to lay the
	# same storeys, cut the same top off and make the same brick piece of it
	# (DamageLog LAY, UNLAY, GIVE_WAY, SHELL_BRICKS).
	_check_log_replays()
	print("[storeys] laid later %d times, %.1f ms all told, worst %.1f; rest shells made %d; shell pieces made bricks %d" % [
			city.storeys_laid_later, city._lay_more_ms, city._lay_more_worst, city.rest_shells_made, city.shell_pieces_bricked])
	print("[storeys] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## How long a break takes to show. Reported: a break, then pieces that do
## nothing for a few frames or vanish, and nothing falling for about a second.
## A building is shot through as a player would -- its ground storey's walls
## all round, or the whole storey -- and every physics tick after the first blast
## is watched: the damage still queued, the buildings waiting for a solve, rounds
## the collapse director held, and the pieces: when the first is cut out, when
## the BIGGEST is (the building's body, which is what is seen hanging), when
## they are drawn and when they move. Two ordinary buildings and the biggest
## there is (a mega one in the big city: -- --breaklag --big).
func _run_breaklag_pass() -> void:
	print("[breaklag] a break, and how long before anything moves")
	var biggest: BuildingRegistry.Building = null
	var ordinary: Array = []
	for c in city.registry.buildings:
		# Towers, as this was written for. The big city's wide buildings are
		# 12-24 courses, which made them its "ordinary" ones -- where it had
		# none -- and they fail what a tower is asked (CollapseNext item 25).
		if c.is_build() or city._wide_ids.has(c.id):
			continue
		var size: int = c.recipe.courses * c.recipe.footprint_x * c.recipe.footprint_z
		if biggest == null or size > biggest.recipe.courses * biggest.recipe.footprint_x \
				* biggest.recipe.footprint_z:
			biggest = c
		if c.recipe.courses >= 12 and c.recipe.courses <= 30 and ordinary.size() < 3:
			ordinary.append(c)
	# The first shot at a building that is still a shell: it is made bricks by
	# the shot, and drawn by its shell until its bands are up.
	var shell: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build() or c.is_materialised() or ordinary.has(c) or c == biggest \
				or city._wide_ids.has(c.id):
			continue
		if shell == null or absi(c.recipe.courses - 24) < absi(shell.recipe.courses - 24):
			shell = c
	if shell != null:
		await _shell_lag(shell)
	# Another shell, aimed at before it is shot (_aim_promote).
	var aimed: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build() or c.is_materialised() or ordinary.has(c) or c == biggest or c == shell \
				or city._wide_ids.has(c.id):
			continue
		aimed = c
		break
	if aimed != null:
		await _aim_check(aimed)
	# And one a falling piece is about to land on (_path_promote).
	var under: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build() or c.is_materialised() or ordinary.has(c) or c == biggest \
				or c == shell or c == aimed or city._wide_ids.has(c.id):
			continue
		under = c
		break
	if under != null:
		await _path_check(under)
	# On a building of its own: the walls case below wants one nothing has hit.
	if ordinary.size() > 2:
		await _proxy_check(ordinary[2])
		await _far_shell_check(ordinary[2], true)
	if ordinary.size() > 0:
		await _break_lag(ordinary[0], false)
	if ordinary.size() > 1:
		await _break_lag(ordinary[1], true)
		await _far_shell_check(ordinary[1], false)
	if biggest != null and not ordinary.has(biggest):
		# A third of the way up: what is above falls on what is below, rather
		# than the whole tower toppling off its stump.
		await _break_lag(biggest, true,
				TowerRecipe.total_plates(biggest.recipe.courses) * City.PLATE / 3.0)
	print("[breaklag] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## A player's widest shots at the biggest building, from close up. Reported
## (2026-10-24): the left click at a big radius into a large building, 20-30
## rooms at once, froze and then crashed the game close up and was smooth from
## far away. The crash was a bake worker's (BrickWorld::join_chunk_readers);
## this measures what is left: every FRAME after each shot -- what the player
## sees as a freeze -- its worst, how many went over 33 and 100 ms, and what the
## physics tick of the worst one spent, part by part (_part, _mark). `--far`
## takes the same shots from 150 m, the case that was fine.
func _run_bigbreak_pass() -> void:
	var far := "--far" in OS.get_cmdline_user_args()
	var b: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build() or city._wide_ids.has(c.id):
			continue
		if b == null or c.recipe.courses * c.recipe.footprint_x * c.recipe.footprint_z \
				> b.recipe.courses * b.recipe.footprint_x * b.recipe.footprint_z:
			b = c
	if b == null:
		print("[bigbreak] no building")
		city.get_tree().quit(1)
		return
	var fx: float = b.recipe.footprint_x * City.STUD
	var back := 150.0 if far else 14.0
	print("[bigbreak] building %d (%dx%d, %d courses), shots from %.0f m" % [b.id,
			b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses, back])
	# Where a player stands: in front of the face, a few storeys up.
	city.camera.position = b.xform * Vector3(fx * 0.5, 9.0, -back)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 9.0, 0.0), Vector3.UP)
	await _frames(120)
	var shots := [[0.3, 8.0, 8.0], [0.7, 10.0, 12.0], [0.5, 22.0, 12.0]]
	var worst_all := 0.0
	for shot in shots:
		var at: Vector3 = b.xform * Vector3(fx * float(shot[0]), float(shot[1]), 0.0)
		city.camera.look_at(at, Vector3.UP)
		await _frames(30)
		var bricks0 := city.world.get_alive_block_count(b.chunk) if b.is_materialised() else 0
		var rep0 := city.registry.storey_report(b.id)
		var held0 := city.director.held_rounds
		var lay0 := city.registry.lay_usec
		var laid0 := city.registry.items_laid
		var join0 := city.world.get_join_wait_usec()
		city._blast(at, float(shot[2]))
		var worst := 0.0
		var worst_at := -1
		var worst_parts := {}
		var worst_process := 0.0
		var over33 := 0
		var over100 := 0
		var total := 0.0
		var frames := 0
		var prev := Time.get_ticks_usec()
		var quiet := 0
		var last_alive := -1
		# Until the break is over: the damage applied and a second of nothing.
		while frames < 900 and (quiet < 60 or not city._damage_queue.is_empty()):
			await city.get_tree().process_frame
			var now := Time.get_ticks_usec()
			var dt := float(now - prev) / 1000.0
			prev = now
			frames += 1
			total += dt
			if dt > 33.3:
				over33 += 1
			if dt > 100.0:
				over100 += 1
			if dt > worst:
				worst = dt
				worst_at = frames
				worst_parts = city._prof.duplicate()
				worst_process = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			var alive := city.world.get_alive_block_count(b.chunk) if b.is_materialised() else 0
			quiet = quiet + 1 if alive == last_alive else 0
			last_alive = alive
		var rep := city.registry.storey_report(b.id)
		var parts := []
		for k in worst_parts:
			if float(worst_parts[k]) >= 1.0:
				parts.append("%s %.1f" % [k, float(worst_parts[k])])
		print("[bigbreak] radius %.0f m at %.0f m up: %d bricks gone of %d; storeys laid %s -> %s; director held %d" % [
				float(shot[2]), float(shot[1]), bricks0 - last_alive, bricks0,
				str(rep0.get("laid", "all")), str(rep.get("laid", "all")),
				city.director.held_rounds - held0])
		print("[bigbreak]   %d frames, mean %.1f ms, worst %.1f ms at frame %d, %d over 33 ms, %d over 100 ms" % [
				frames, total / maxf(frames, 1), worst, worst_at, over33, over100])
		print("[bigbreak]   worst frame's physics tick: %s; process %.1f ms" % [
				", ".join(parts), worst_process])
		print("[bigbreak]   %d interior pieces laid as bricks, %.1f ms laying them; %.1f ms waiting on bake workers" % [
				city.registry.items_laid - laid0, (city.registry.lay_usec - lay0) / 1000.0,
				(city.world.get_join_wait_usec() - join0) / 1000.0])
		worst_all = maxf(worst_all, worst)
	print("[bigbreak] worst frame of all %.1f ms" % worst_all)
	city.get_tree().quit(0)

## The wide buildings' own checks (CollapseNext 25; WIDE_SHAPES). `--breaklag`
## and `--far` keep to towers (`_wide_ids`) because the wide ones failed
## what a tower is asked there; these ask them the same things on their own,
## one building each so no shot lands on another's wreckage:
##   the first (240 x 50): a shell shot through its ground storey shows it
##     within 15 ticks (_shell_lag);
##   the second (160 x 60): made bricks, its ground storey blown out -- pieces
##     move within 10 ticks of its bricks going and its body comes off within
##     3 of the first piece (_break_lag);
##   the third (200 x 80): far off, a shell stands in drawn with the damage
##     it has, and a hit taken there shows on it (_far_shell_check);
##   the fourth (120 x 40): a bay of its ground storey shot out across its
##     whole depth, BAY_STUDS wide -- the floor over it comes down by the span
##     rule (Structures 2.3: nothing within Floor Reach holds it) and the rest
##     of the building stands (_bay_check).
##     godot --path . scenes/big_city.tscn -- --widecheck --big
func _run_wide_pass() -> void:
	print("[widecheck] the wide buildings, asked a tower's questions")
	city.respawn_buildings = false
	var wides: Array = []
	for c in city.registry.buildings:
		if city._wide_ids.has(c.id):
			wides.append(c)
	wides.sort_custom(func(a, c) -> bool: return a.id < c.id)
	if wides.size() < 4:
		print("[widecheck] %d wide building(s); run it in big_city.tscn with --big" % wides.size())
		city.get_tree().quit(1)
		return
	for b: BuildingRegistry.Building in wides:
		print("[widecheck] building %d: %d x %d studs, %d courses" % [b.id,
				b.recipe.footprint_x, b.recipe.footprint_z, b.recipe.courses])
	await _shell_lag(wides[0])
	city._promote(wides[1].id)
	await _break_lag(wides[1], true)
	city._promote(wides[2].id)
	await _frames(30)
	await _far_shell_check(wides[2], true)
	await _bay_check(wides[3])
	print("[widecheck] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## A bay of a wide building's ground storey shot out across its whole depth,
## BAY_STUDS wide, a third of the way along: walls, columns and room walls all
## gone under it. The floor over it has nothing within reach to hold it (the
## span rule) and must come down; past the bay, at the building's ends, it
## stands. Read from the bricks: the first floor's slab over the middle of the
## bay, and over each end.
func _bay_check(b: BuildingRegistry.Building) -> void:
	var fz: float = b.recipe.footprint_z * City.STUD
	@warning_ignore("integer_division")
	var bay0: int = b.recipe.footprint_x / 3
	var bay1: int = bay0 + BAY_STUDS
	@warning_ignore("integer_division")
	var over := bay0 + BAY_STUDS / 2
	city.camera.position = b.xform * Vector3(float(over) * City.STUD, 15.0, -25.0)
	city.camera.look_at(b.xform * Vector3(float(over) * City.STUD, 4.0, fz * 0.5), Vector3.UP)
	city._promote(b.id, true, PackedInt32Array([0, 1]))
	await _frames(60)
	var slab_y := TowerRecipe.STOREY_PLATES
	@warning_ignore("integer_division")
	var mid_z: int = b.recipe.footprint_z / 2
	var probe := func(at: int) -> bool:
		if not b.is_materialised():
			return false
		var origin := city.world.get_chunk_origin(b.chunk)
		return city.world.is_solid(b.chunk, origin + Vector3i(at, slab_y, mid_z)) \
				and city.world.is_solid(b.chunk, origin + Vector3i(at, slab_y + 1, mid_z))
	var ends := [5, b.recipe.footprint_x - 6]
	var before: bool = probe.call(over) and probe.call(ends[0]) and probe.call(ends[1])
	_gate_ok("building %d: its first floor laid over the bay and both ends before the shot" % b.id,
			before, "over the bay %s, ends %s %s" % [probe.call(over), probe.call(ends[0]),
				probe.call(ends[1])])
	var blasts := 0
	var x := float(bay0) * City.STUD
	while x <= float(bay1) * City.STUD + 0.01:
		var z := 0.0
		while z <= fz + 0.01:
			city._blast(b.xform * Vector3(x, 1.2, z), 2.2)
			blasts += 1
			z += 2.5
		x += 2.5
	var t := 0
	while t < 600 and probe.call(over):
		await city.get_tree().physics_frame
		t += 1
	await _frames(120)
	print("[widecheck] building %d: a %d-stud bay shot out at studs %d..%d (%d blasts); the floor over it %s at tick %d" % [
			b.id, BAY_STUDS, bay0, bay1, blasts, "still there" if probe.call(over) else "gone", t])
	_gate_ok("building %d: the floor over the bay comes down (span rule)" % b.id,
			not probe.call(over), "still standing after %d ticks" % t)
	_gate_ok("building %d: and the building either side of it stands" % b.id,
			probe.call(ends[0]) and probe.call(ends[1]),
			"ends %s, %s" % [probe.call(ends[0]), probe.call(ends[1])])

## What wreckage at rest costs -- the measurement DestructionLod 3.5 waits for
## ("rubble at rest merged into one static body per tile ... worth doing when a
## measurement says it costs something"). The --shot pass's cut (one side of
## every tall tower, eight courses up), then until every piece has settled,
## then three windows of WINDOW frames: as it is; with the settled pieces out of
## the physics space (what merging them could save the physics step at most);
## with them hidden (what it could save drawing at most). Each window: the
## frame, the physics frame and the renderer's own CPU and GPU time, means.
##     godot --path . scenes/big_city.tscn -- --rubble --big
func _run_rubble_pass() -> void:
	city.islands.field_enabled = not ("--no-field" in OS.get_cmdline_user_args())
	print("[rubble] wreckage at rest: what it costs (rubble field %s)" % (
			"on" if city.islands.field_enabled else "off"))
	city.respawn_buildings = false
	city.camera.position = Vector3(-52.0, 34.0, -52.0)
	city.camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(30)
	for b in city.registry.buildings:
		if b.is_build() or b.recipe.courses < 44:
			continue
		var bw: float = b.recipe.footprint_x * City.STUD
		var d: float = b.recipe.footprint_z * City.STUD
		for course in range(0, 8):
			var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * City.PLATE
			var px := 0.3
			while px < bw * 0.55:
				var pz := 0.3
				while pz < d:
					city._blast(b.xform.origin + Vector3(px, y, pz), 1.5)
					pz += 2.0
				px += 2.0
	var t := 0
	var moving := 1
	while t < 60 * 60 and (moving > 0 or not city._damage_queue.is_empty()):
		await _frames(30)
		t += 30
		moving = 0
		for isl in city.islands.islands:
			if isl.is_valid() and not isl.settled:
				moving += 1
	var settled: Array = []
	var boxes := 0
	var bricks := 0
	for isl in city.islands.islands:
		if isl.is_valid() and isl.settled:
			settled.append(isl)
			boxes += isl.shape_count
			bricks += city.world.get_alive_block_count(isl.chunk)
	print("[rubble] after %.0f s: %d piece(s) at rest (%d boxes, %d bricks), %d still moving, %d asleep" % [
			t / 60.0, settled.size(), boxes, bricks, moving, city.islands.dormant.size()])
	# And the rubble field's work done: far stand-ins of bricks made coarse and
	# every tile merged (IslandManager._tend_field), up to 20 s.
	var w := 0
	var last_coarse := -1
	while w < 1200:
		await _frames(60)
		w += 60
		var busy := not city.islands._coarsening.is_empty()
		for key in city.islands._field:
			busy = busy or city.islands._field[key].dirty or city.islands._field[key].job >= 0
		if not busy and city.islands.field_coarsened == last_coarse:
			break
		last_coarse = city.islands.field_coarsened
	var vp := city.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var as_is: Array = await _rubble_window(vp)
	var space := city.get_world_3d().space
	for isl in settled:
		if _rubble_live(isl):
			PhysicsServer3D.body_set_space((isl as BrickIsland).body.get_rid(), RID())
	var no_physics: Array = await _rubble_window(vp)
	for isl in settled:
		if _rubble_live(isl):
			PhysicsServer3D.body_set_space((isl as BrickIsland).body.get_rid(), space)
			_rubble_show(isl, false)
	var no_draw: Array = await _rubble_window(vp)
	for isl in settled:
		if _rubble_live(isl):
			_rubble_show(isl, true)
	# The asleep: their stand-ins drawn a tile at a time (IslandManager's rubble
	# field), the biggest-looking FIELD_MAX_DRAWN tiles only.
	var field := city.islands.get_node_or_null("RubbleField") as Node3D
	print("[rubble] field: %d tile(s), %d drawn, %d left undrawn by the cap; %d merge(s), the slowest %.2f ms on a worker, %.2f ms on the main thread" % [
			city.islands._field.size(), city.islands.field_drawn, city.islands.field_culled, city.islands.field_merges,
			city.islands.field_worst_ms, city.islands.field_main_worst_ms])
	var with_arrays := 0
	var stand_ins := 0
	for dm in city.islands.dormant:
		if dm.stand_in != null and is_instance_valid(dm.stand_in):
			stand_ins += 1
			if not dm.stand_in_arrays.is_empty():
				with_arrays += 1
	print("[rubble] %d stand-in(s), %d with the arrays to merge from; %d made coarse from their record" % [
			stand_ins, with_arrays, city.islands.field_coarsened])
	var no_field: Array = as_is
	if field != null:
		field.visible = false
		no_field = await _rubble_window(vp)
		field.visible = true
	for row in [["as it is", as_is], ["settled out of physics", no_physics],
			["settled not drawn", no_draw], ["the asleep not drawn", no_field]]:
		var m: Array = row[1]
		print("[rubble]   %-24s frame %.2f ms, physics %.2f ms, render cpu %.2f ms gpu %.2f ms, %d draw calls" % [
				row[0], m[0], m[1], m[2], m[3], int(m[4])])
	print("[rubble] the most merging could save: physics %.2f ms a frame, drawing %.2f ms cpu %.2f ms gpu, %d draw calls" % [
			float(as_is[1]) - float(no_physics[1]), float(as_is[2]) - float(no_draw[2]),
			float(as_is[3]) - float(no_draw[3]), int(as_is[4]) - int(no_draw[4])])
	city.get_tree().quit(0)

## A piece can be freed between the windows (a stand-in's turn, a trim).
func _rubble_live(isl: BrickIsland) -> bool:
	return isl.is_valid() and is_instance_valid(isl.body)

func _rubble_show(isl: BrickIsland, on: bool) -> void:
	isl.body.visible = on
	if is_instance_valid(isl.mesh):
		isl.mesh.visible = on

## Means over _RUBBLE_WINDOW frames: [frame, physics, render cpu, render gpu,
## draw calls], ms but the last.
func _rubble_window(vp: RID) -> Array:
	await _frames(30)
	var sum := [0.0, 0.0, 0.0, 0.0, 0.0]
	var prev := Time.get_ticks_usec()
	for k in _RUBBLE_WINDOW:
		await city.get_tree().process_frame
		var now := Time.get_ticks_usec()
		sum[0] += (now - prev) / 1000.0
		prev = now
		sum[1] += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		sum[2] += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		sum[3] += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		sum[4] += RenderingServer.get_rendering_info(
				RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	for i in sum.size():
		sum[i] /= float(_RUBBLE_WINDOW)
	return sum

## Reported (user, 2026-10-26): a building comes down fine, but as it hits the
## ground "all the other rooms and floors become active" and "the entire
## building glassed and disappears for a second". A tower's ground storey shot
## out on one side, from 45 m, so it tips and lands; then 600 ticks watched, every
## tick: is its shell drawn (the far drawing, with painted windows), is its brick
## node drawn, how many of the bricks of its pieces are drawn (not blind), how
## many are drawn by a stand-in or the rubble field, and what material the
## biggest piece is drawn with. A tick where most of its bricks go undrawn, or
## the shell comes back while it has pieces down, is printed and pictured.
func _run_landing_pass() -> void:
	print("[landing] a tower comes down: is it drawn all the way to the ground?")
	city.respawn_buildings = false
	var b: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build() or city._wide_ids.has(c.id):
			continue
		if c.recipe.courses >= 36 and c.recipe.courses <= 90:
			b = c
			break
	if b == null:
		print("[landing] no tower")
		city.get_tree().quit(1)
		return
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5 + 35.0, 25.0, -30.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 10.0, fz * 0.5), Vector3.UP)
	city._promote(b.id)
	await _frames(60)
	var known := {}
	for isl in city.islands.islands:
		known[isl] = true
	# The -x half of the ground storey: it tips that way.
	var px := 0.3
	while px < fx * 0.55:
		var pz := 0.3
		while pz < fz:
			for y in [1.0, 2.4]:
				city._blast(b.xform * Vector3(px, y, pz), 1.6)
			pz += 2.0
		px += 2.0
	var bricks0 := city.world.get_alive_block_count(b.chunk) if b.is_materialised() else 0
	var worst_blind := 0.0
	var worst_at := -1
	var shell_back := 0
	var shots := 0
	var lines: Array[String] = []
	for t in range(1, 601):
		await city.get_tree().physics_frame
		var total := 0
		var blind := 0
		var stood := 0
		var biggest: BrickIsland = null
		var most := 0
		# A child shed undrawn is drawn by its parent's held mesh meanwhile
		# (IslandManager.HOLD_MAX_FRAMES): not blind to the eye.
		var covered := {}
		var frame := Engine.get_process_frames()
		for isl in city.islands.islands:
			if isl.is_valid() and isl.hold_until > frame:
				for c in isl.waiting_children:
					covered[c] = true
		for isl in city.islands.islands:
			if known.has(isl) or not isl.is_valid() or isl.owner != b.id:
				continue
			var n := city.world.get_alive_block_count(isl.chunk)
			total += n
			if city.islands.is_blind(isl) and not covered.has(isl):
				blind += n
			if n > most:
				most = n
				biggest = isl
		for dm in city.islands.dormant:
			if dm.owner == b.id:
				stood += dm.record.block_count()
		var shell = city._shells.get(b.id)
		var shell_shown: bool = shell != null and is_instance_valid(shell) and (shell as Node3D).is_visible_in_tree()
		var bn = city._brick_nodes.get(b.id)
		var bricks_shown: bool = bn != null and is_instance_valid(bn) and (bn as Node3D).is_visible_in_tree()
		var share := float(blind) / maxf(total, 1.0)
		if total > 200 and share > worst_blind:
			worst_blind = share
			worst_at = t
		if total > 200 and shell_shown:
			shell_back += 1
		var mat := ""
		if biggest != null and biggest.mesh != null:
			var m: Material = biggest.mesh.material_override
			mat = m.resource_name if m != null and m.resource_name != "" else str(m)
		var odd := total > 200 and (share > 0.3 or shell_shown)
		if t <= 10 or t % 30 == 0 or odd:
			lines.append("%d: pieces %d bricks (%d blind), asleep %d; standing %d; shell %s, brick node %s; biggest %d drawn with %s%s" % [
					t, total, blind, stood,
					city.world.get_alive_block_count(b.chunk) if b.is_materialised() else 0,
					shell_shown, bricks_shown, most, mat, "  <--" if odd else ""])
		if odd and shots < 4 and t % 5 == 0:
			shots += 1
			await _save("landing_%03d" % t)
	print("[landing] building %d, %d bricks, shot from %.0f m:" % [b.id, bricks0,
			city.camera.global_position.distance_to(b.xform.origin)])
	for line in lines:
		print("[landing]   " + line)
	_gate_ok("building %d: its pieces drawn as they come down and land (at most 30%% undrawn)" % b.id,
			worst_blind <= 0.3, "%.0f%% of its pieces' bricks undrawn at tick %d" % [
				worst_blind * 100.0, worst_at])
	_gate_ok("building %d: and its shell does not come back while it lies there" % b.id,
			shell_back == 0, "%d tick(s) shell drawn" % shell_back)
	print("[landing] holds extended for children still undrawn: %d frame(s)" % city.islands.holds_extended)
	print("[landing] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## A building's shadow proxy (_stream_shadows) is built on a worker now: it has
## to turn up, and to catch up with a hit once the building has stopped losing
## bricks.
func _proxy_check(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5 + 30.0, 20.0, -30.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 6.0, fz * 0.5), Vector3.UP)
	city._promote(b.id)
	var t := 0
	while t < 90 and not _proxy_drawn(b.id):
		await city.get_tree().physics_frame
		t += 1
	_gate_ok("building %d: its shadow proxy is up" % b.id, _proxy_drawn(b.id),
			"after %d tick(s)" % t)
	city._blast(b.xform * Vector3(fx * 0.5, 4.0, 0.0), 1.5)
	await _frames(10)
	t = 0
	while t < 150 and not (_proxy_drawn(b.id) and not city._shadow_jobs.has(b.id)
			and int(city._shadow_proxy_alive.get(b.id, -1)) == city.world.get_alive_block_count(b.chunk)):
		await city.get_tree().physics_frame
		t += 1
	# And a hit that leaves its floors standing leaves its stairs (_sweep_stairs
	# cuts out only flights whose storey has gone). Past a sweep or two first.
	await _frames(City.STAIR_SWEEP_TICKS * 3)
	var stairs_all := 0
	var stairs_live := 0
	var gone := {}
	for d in city.world.get_dead_blocks(b.chunk):
		gone[d] = true
	for d in city.world.get_detached_blocks(b.chunk):
		gone[d] = true
	for f in b.fixtures:
		if f.kind == "staircase":
			for bid in f.blocks:
				stairs_all += 1
				if not gone.has(bid):
					stairs_live += 1
	_gate_ok("building %d: its stairs stand while its floors do" % b.id,
			stairs_all > 0 and stairs_live == stairs_all, "%d of %d" % [stairs_live, stairs_all])
	_gate_ok("building %d: and it catches up with a hit" % b.id,
			_proxy_drawn(b.id) and int(city._shadow_proxy_alive.get(b.id, -1))
					== city.world.get_alive_block_count(b.chunk),
			"built from %d bricks, %d alive, after %d tick(s)" % [
				int(city._shadow_proxy_alive.get(b.id, -1)), city.world.get_alive_block_count(b.chunk), t])

## A building still in bricks gives its mesh up past DEMESH_RANGE and stands in
## as a shell (_demesh). That shell has to be drawn from the damage its bricks
## have now -- nothing, if none are left -- and take a hit while it is far. It
## used to be drawn from the profile of the last time the building was given
## back: a building damaged since came back whole at range, and went again up
## close, which is what "buildings respawning" was.
func _far_shell_check(b: BuildingRegistry.Building, hit_it: bool) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	city.camera.global_position = b.xform.origin + Vector3(0.0, 40.0,
			-(City.DEMESH_RANGE + City.DEMESH_HYSTERESIS + 30.0))
	city.camera.look_at(b.xform.origin + Vector3(0.0, 10.0, 0.0), Vector3.UP)
	var t := 0
	while t < 300 and not (city._shells.has(b.id) and not city._brick_nodes.has(b.id)):
		await city.get_tree().physics_frame
		t += 1
	_gate_ok("building %d: far off, a shell stands in for it" % b.id,
			city._shells.has(b.id) and not city._brick_nodes.has(b.id), "after %d tick(s)" % t)
	_gate_ok("building %d: drawn with the damage it has, not what it had" % b.id,
			_far_shell_true(b), _far_shell_note(b))
	if not hit_it or not b.is_materialised() or city.world.get_alive_block_count(b.chunk) == 0:
		return
	var before := city.world.get_alive_block_count(b.chunk)
	city._blast(b.xform * Vector3(fx * 0.5, 6.0, 0.0), 2.0)
	t = 0
	while t < 150 and (city.world.get_alive_block_count(b.chunk) == before or not _far_shell_true(b)):
		await city.get_tree().physics_frame
		t += 1
	_gate_ok("building %d: and a hit taken while far shows on it" % b.id,
			city.world.get_alive_block_count(b.chunk) < before and _far_shell_true(b),
			"%d -> %d bricks; %s" % [before, city.world.get_alive_block_count(b.chunk), _far_shell_note(b)])

## Vertices the shell draws, and what it should: from the bricks while it has
## them, from the profile once it has given them back.
func _far_shell_counts(b: BuildingRegistry.Building) -> Array:
	var got := 0
	var mi = city._shells.get(b.id)
	if is_instance_valid(mi) and (mi as MeshInstance3D).mesh != null \
			and (mi as MeshInstance3D).mesh.get_surface_count() > 0:
		got = ((mi as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				as PackedVector3Array).size()
	var r: Dictionary = b.recipe
	# Drawn from its bricks (_far_real): what it should draw is their coarse
	# mesh as they are now, not a recipe shell with holes -- a wide one far off
	# is drawn so (it was 21,824 vertices against the profile's 2,692, and right).
	if is_instance_valid(mi) and city._far_real_done.get(b.id) == mi and b.is_materialised():
		var coarse: Array = city.world.build_chunk_coarse_mesh(b.chunk)
		var cw := 0 if coarse.is_empty() \
				else (coarse[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		return [got, cw, -1]
	var profile: Dictionary = b.damage_profile
	var want := 0
	if b.is_materialised():
		profile = city.registry.live_damage_profile(b.id)
		if city.world.get_alive_block_count(b.chunk) == 0:
			return [got, 0, -1]
	want = (BuildingShell.build_arrays(int(r.footprint_x), int(r.footprint_z), int(r.courses),
			profile)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var whole := (BuildingShell.build_arrays(int(r.footprint_x), int(r.footprint_z),
			int(r.courses), {})[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return [got, want, whole]

func _far_shell_true(b: BuildingRegistry.Building) -> bool:
	var n := _far_shell_counts(b)
	return int(n[0]) == int(n[1])

func _far_shell_note(b: BuildingRegistry.Building) -> String:
	var n := _far_shell_counts(b)
	return "%d vertices drawn, %d from its damage, %s whole" % [n[0], n[1],
			"n/a" if int(n[2]) < 0 else str(n[2])]

func _proxy_drawn(id: int) -> bool:
	var mi = city._shadow_proxy.get(id)
	return is_instance_valid(mi) and (mi as MeshInstance3D).mesh != null \
			and (mi as MeshInstance3D).mesh.get_surface_count() > 0

## A slab dropped from twenty-five metres onto a shell: by the time it lands
## the building is bricks with its bands drawn, so the landing shows on it.
func _path_check(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	var top: float = TowerRecipe.total_plates(b.recipe.courses) * City.PLATE
	var centre: Vector3 = b.xform * Vector3(fx * 0.5, top, fz * 0.5)
	city.camera.global_position = centre + Vector3(0.0, 10.0, 0.0) \
			+ (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized() * (fz * 0.5 + 35.0)
	# Looking AWAY: aimed at, it would be made bricks for that (_aim_promote),
	# and this is about the piece.
	city.camera.look_at(city.camera.global_position * 2.0 - centre, Vector3.UP)
	await _frames(4)
	var c := city.world.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(6, 6, 3))
	TowerRecipe.build(city.world, c, city.palette, 6, 6, 3)
	city.world.set_chunk_transform(c, Transform3D(Basis(), centre + Vector3(-1.0, 25.0, -1.0)))
	var ids := PackedInt32Array()
	for id in city.world.get_block_count(c):
		ids.append(id)
	var p0 := city.path_promotions
	var piece := city.islands.spawn(c, ids, Vector3.ZERO, Vector3.ZERO, -1, -1)
	city.world.release_chunk(c)
	if piece == null:
		_gate_ok("a slab to drop on building %d" % b.id, false)
		return
	var start := piece.body.global_position
	var promoted_at := -1
	var t := 0
	while t < 240 and piece.is_valid() and not piece.landed:
		await city.get_tree().physics_frame
		t += 1
		if promoted_at < 0 and b.is_materialised():
			promoted_at = t
	print("[breaklag]   slab: %d bricks, %s, from %s to %s; building box %s; made bricks at tick %d, landed %d" % [
			city.world.get_alive_block_count(piece.chunk) if piece.is_valid() else -1,
			"landmark" if piece.landmark else ("rubble" if piece.disposable else "piece"),
			start, piece.body.global_position if piece.is_valid() else Vector3.ZERO,
			city._world_box(b), promoted_at, t])
	_gate_ok("building %d: a slab falling on it made it bricks, drawn, before it landed" % b.id,
			b.is_materialised() and not city._shells.has(b.id) and city.path_promotions > p0,
			"landed after %d tick(s); materialised %s, shell %s, %d promoted from a path" % [
				t, b.is_materialised(), city._shells.has(b.id), city.path_promotions - p0])

## Aimed at from past PROMOTE_RANGE, a shell is bricks with its bands drawn
## before the shot: the first hit shows the tick it lands.
func _aim_check(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	# A side and a distance, past PROMOTE_RANGE, with nothing between the
	# camera and the wall: a city block is dense, and the ray takes the first
	# building it meets (the one really aimed at).
	var face := Vector3.ZERO
	var found := false
	for side in [[Vector3(fx * 0.5, 3.0, 0.0), Vector3(0, 0, -1)], [Vector3(fx * 0.5, 3.0, fz), Vector3(0, 0, 1)],
			[Vector3(0.0, 3.0, fz * 0.5), Vector3(-1, 0, 0)], [Vector3(fx, 3.0, fz * 0.5), Vector3(1, 0, 0)]]:
		for dist in [35.0, 45.0, 60.0, 80.0]:
			var f: Vector3 = b.xform * (side[0] as Vector3)
			var out: Vector3 = b.xform.basis * (side[1] as Vector3)
			var at: Vector3 = Vector3(f.x, 3.0, f.z) + out * dist
			var hit := city.get_world_3d().direct_space_state.intersect_ray(
					PhysicsRayQueryParameters3D.create(at, f + (f - at).normalized() * 2.0,
					Layers.WORLD | Layers.STRUCTURE))
			if not hit.is_empty() and city._building_for_body(hit.rid) == b.id:
				city.camera.global_position = at
				city.camera.look_at(f, Vector3.UP)
				face = f
				found = true
				break
		if found:
			break
	if not found:
		print("[breaklag] no clear view of building %d; aim check skipped" % b.id)
		return
	var t := 0
	while t < 120 and not (b.is_materialised() and not city._shells.has(b.id)):
		await city.get_tree().physics_frame
		t += 1
	_gate_ok("building %d: aimed at from 60 m, it is bricks, drawn, before the shot" % b.id,
			b.is_materialised() and not city._shells.has(b.id), "after %d tick(s)" % t)
	# The shot, then: on bricks already drawn.
	var n0 := city.authority.commands.size()
	city.chip(face, 0.3, 60)
	await _frames(4)
	_gate_ok("building %d: and the shot lands on bricks already drawn" % b.id,
			b.is_materialised() and not city._shells.has(b.id) and city.authority.commands.size() > n0)

## A building still drawn as its shell, its ground storey blown out: how long
## until the shot is SEEN on it -- the shell gone, its bands up -- and that no
## piece comes out of it before then. The shell draws the building whole, so a
## piece cut out earlier fell out of a wall that went on showing it.
func _shell_lag(b: BuildingRegistry.Building) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5 + 30.0, 20.0, -30.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 6.0, fz * 0.5), Vector3.UP)
	await _frames(2)
	var was_shell := city._shells.has(b.id) and not b.is_materialised()
	var known := {}
	for isl in city.islands.islands:
		known[isl] = true
	var x := 0.0
	while x <= fx + 0.01:
		var z := 0.0
		while z <= fz + 0.01:
			city._blast(b.xform * Vector3(x, 1.2, z), 2.2)
			z += 2.5
		x += 2.5
	var materialised_at := -1
	var cut_at := -1
	var shell_gone_at := -1
	var t := 0
	var timeline: Array[String] = []
	while t < 240 and (shell_gone_at < 0 or cut_at < 0 or t < shell_gone_at + 10):
		await city.get_tree().physics_frame
		t += 1
		var fresh := 0
		for isl in city.islands.islands:
			if not known.has(isl) and isl.is_valid():
				fresh += 1
		if b.is_materialised() and materialised_at < 0:
			materialised_at = t
		var shelled := city._shells.has(b.id)
		if materialised_at > 0 and not shelled and shell_gone_at < 0:
			shell_gone_at = t
		if fresh > 0 and cut_at < 0:
			cut_at = t
		if t <= 30 or t % 10 == 0:
			timeline.append("%d: materialised %s, shell %s, bands building %s, redo %s, pieces %d" % [
					t, b.is_materialised(), shelled, b.is_materialised() and city._bands_building(b.id),
					city._band_redo.has(b.id), fresh])
	print("[breaklag] building %d, a shell when shot (%s), %d bricks:" % [b.id, was_shell,
			city.world.get_block_count(b.chunk) if b.is_materialised() else 0])
	for line in timeline:
		print("[breaklag]   " + line)
	print("[breaklag]   made bricks at tick %d, the shell gone at %d, first piece cut out %d" % [
			materialised_at, shell_gone_at, cut_at])
	_gate_ok("building %d: a shot shell shows the shot within 15 ticks" % b.id,
			shell_gone_at > 0 and shell_gone_at <= 15, "shell gone at %d" % shell_gone_at)
	_gate_ok("building %d: and nothing comes out of it while the shell still shows it whole" % b.id,
			cut_at < 0 or shell_gone_at < 0 or cut_at >= shell_gone_at,
			"first piece %d, shell gone %d" % [cut_at, shell_gone_at])
	await _frames(60)

## `storey`: the whole storey blown out; otherwise its walls all round. At
## height `y` -- the ground storey unless told.
func _break_lag(b: BuildingRegistry.Building, storey: bool, y := 1.2) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5 + 30.0, 20.0, -30.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, y + 5.0, fz * 0.5), Vector3.UP)
	city._promote(b.id)
	await _frames(40)
	var bricks := city.world.get_block_count(b.chunk)
	var known := {}
	for isl in city.islands.islands:
		known[isl] = true
	var held0 := city.director.held_rounds
	var blasts := 0
	var step := 2.5
	var x := 0.0
	while x <= fx + 0.01:
		var z := 0.0
		while z <= fz + 0.01:
			var wall := x < 0.01 or z < 0.01 or x > fx - step or z > fz - step
			if storey or wall:
				city._blast(b.xform * Vector3(minf(x, fx), y, minf(z, fz)), 2.2 if storey else 2.0)
				blasts += 1
			z += step
		x += step
	var cut_at := -1
	var drawn_at := -1
	var moving_at := -1
	var gone_at := -1
	var biggest_at := -1
	var biggest := 0
	# Every piece as it is first seen: when, and how many bricks. Counted in
	# bricks, not boxes -- a piece that lands is split back into a box a brick,
	# and a child of it could "outgrow" the building's body. And only pieces
	# cut out while the building was still losing bricks: what comes off a
	# piece once it lands is not the break.
	var first_seen := {}   # island -> [tick, bricks]
	var last_loss := 0
	var alive_was := bricks
	# Small pieces are crumbs now (IslandManager._crumble): no body, and falling
	# from the tick they appear. They are what showed the break at once before,
	# as bodies, and still are.
	var crumbs0 := city.islands.crumbled
	var crumbs_at := -1
	var landed_at := -1   # the tick the damage queue emptied: the whole shot applied
	var t := 0
	var timeline: Array[String] = []
	# Until nothing has changed for a second: the damage applied, what was
	# going to come away gone.
	var last_change := 0
	var last_state := ""
	while t < 240 and (t - last_change < 30 or not city._damage_queue.is_empty()):
		await city.get_tree().physics_frame
		t += 1
		var fresh := 0
		var drawn := 0
		var fastest := 0.0
		for isl in city.islands.islands:
			if known.has(isl) or not isl.is_valid():
				continue
			fresh += 1
			if not city.islands.is_blind(isl):
				drawn += 1
			fastest = maxf(fastest, isl.body.linear_velocity.length())
			if not first_seen.has(isl):
				first_seen[isl] = [t, city.world.get_alive_block_count(isl.chunk)]
		if fresh > 0 and cut_at < 0:
			cut_at = t
		if drawn > 0 and drawn_at < 0:
			drawn_at = t
		if city.islands.crumbled > crumbs0 and crumbs_at < 0:
			crumbs_at = t
		if city._damage_queue.is_empty() and landed_at < 0:
			landed_at = t
		if (fastest > 1.0 or crumbs_at >= 0) and moving_at < 0:
			moving_at = t
		var alive := city.world.get_alive_block_count(b.chunk) if b.is_materialised() else 0
		if gone_at < 0 and alive < int(bricks * 0.98):
			gone_at = t
		if alive != alive_was:
			alive_was = alive
			last_loss = t
		var state := "%d/%d" % [alive, fresh]
		if state != last_state:
			last_state = state
			last_change = t
		if t <= 30 or t % 10 == 0:
			timeline.append("%d: queue %d, dirty %d, held %d, alive %d, pieces %d (%d drawn), fastest %.1f m/s" % [
					t, city._damage_queue.size(), city._dirty.size(), city.director.held_rounds - held0,
					alive, fresh, drawn, fastest])
	for isl in first_seen:
		var seen: Array = first_seen[isl]
		if int(seen[0]) <= last_loss + 1 and int(seen[1]) > biggest:
			biggest = int(seen[1])
			biggest_at = int(seen[0])
	print("[breaklag] building %d, %d bricks (mega %s), %s at %.1f m, %d blasts:" % [b.id, bricks,
			CollapseDirector.is_mega(bricks), "the storey" if storey else "its walls", y, blasts])
	for line in timeline:
		print("[breaklag]   " + line)
	print("[breaklag]   bricks gone at tick %d; first piece cut out %d, the biggest (%d bricks) %d, drawn %d, moving %d (crumbs from %d, %d piece(s)); the director held %d round(s)" % [
			gone_at, cut_at, biggest, biggest_at, drawn_at, moving_at, crumbs_at,
			city.islands.crumbled - crumbs0, city.director.held_rounds - held0])
	_gate_ok("building %d: pieces move within 10 ticks of its bricks going" % b.id,
			moving_at > 0 and gone_at > 0 and moving_at - gone_at <= 10,
			"gone %d, moving %d" % [gone_at, moving_at])
	# Stairs go with their floors (_sweep_stairs): none left standing on its own
	# once the break is over. Given the sweep's time to come round.
	if b.is_materialised() and not b.fixtures.is_empty():
		var w := 0
		while w < City.STAIR_SWEEP_TICKS * 6 and not city._orphan_stairs(b).is_empty():
			await city.get_tree().physics_frame
			w += 1
		var left := 0
		for r in city._orphan_stairs(b):
			left += (r as PackedInt32Array).size()
		_gate_ok("building %d: no flight of stairs stands without its storey" % b.id,
				left == 0, "%d left standing alone" % left)
	# The body is let go with the first of them, not after the debris: it was
	# 13 ticks behind when two pieces went a tick, smallest first. Or while the
	# shot is still landing: a wide building's storey is 207 blasts, the queue
	# takes 27 ticks over them, and the body goes when the last of what held it
	# does -- 9 ticks after the first piece and 4 before the last blast landed
	# (160 x 60, --widecheck). A tower's shot has landed before anything is cut.
	if not CollapseDirector.is_mega(bricks):
		_gate_ok("building %d: and the biggest piece within 3 ticks of the first, or of the shot landing" % b.id,
				biggest_at > 0 and cut_at > 0
						and (biggest_at - cut_at <= 3 or biggest_at <= landed_at + 3),
				"first %d, biggest %d, the shot landed %d" % [cut_at, biggest_at, landed_at])
	else:
		# A mega tower: when it comes down is the structure's -- what still
		# holds it, and when it tips -- as much as anything held back, so it
		# is reported, not judged. (The director's hold is HOLD_NEAR_MS where
		# somebody is watching.)
		print("[breaklag]   mega: the director held %d round(s); the biggest piece at tick %d" % [
				city.director.held_rounds - held0, biggest_at])
	await _frames(60)

func _run_wreck_pass() -> void:
	print("[wreck] a piece resting on a building loads it")
	var b := city.registry.get_building(0)
	for c in city.registry.buildings:
		if c.recipe.courses >= 24 and not c.is_build():
			b = c
			break
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	city.camera.position = b.xform * Vector3(fx * 0.5 + 20.0, 25.0, -20.0)
	city.camera.look_at(b.xform * Vector3(fx * 0.5, 8.0, fz * 0.5), Vector3.UP)
	city._promote(b.id)
	await _frames(20)
	# Cut the tower through at a storey's slab, as a collision would.
	# On the joint plane between the second storey's slab and the course above.
	var cut := b.xform * Vector3(fx * 0.5, (TowerRecipe.SLAB_PLATES + 2 * TowerRecipe.STOREY_PLATES) * City.PLATE, fz * 0.5)
	if city.authority.request(DamageLog.Kind.SEVER, b.id, cut, 0.14, Vector3.UP):
		city.world.separate_plane(b.chunk, cut, Vector3.UP, 0.14)
		city.authority.commit(Engine.get_physics_frames(), DamageLog.Kind.SEVER, b.id, cut, 0.14,
				Vector3.UP)
		city._mark_dirty(b.id)
	var n0 := city.authority.commands.size()
	var landed: DamageLog.Entry = null
	var waited := 0
	while landed == null and waited < 30 * 20:
		await city.get_tree().physics_frame
		waited += 1
		for i in range(n0, city.authority.commands.size()):
			var e: DamageLog.Entry = city.authority.commands.entries[i]
			if e.kind == DamageLog.Kind.LOAD and e.target == b.id:
				landed = e
				break
	_gate_ok("the cut-free top comes to rest on the tower and loads it", landed != null,
			"%s" % ("%d brick(s) under %.1f each, after %d tick(s)" % [landed.points.size(),
			landed.radius, waited] if landed != null else "no LOAD in %d tick(s)" % waited))
	if landed != null:
		_gate_ok("the landed is on the building's solve",
				city.world.get_load_owners(b.chunk).has(landed.owner) and b.is_materialised(),
				"owners %s" % [city.world.get_load_owners(b.chunk)])
	await _frames(30)
	await _save("city_wreck")
	_check_log_replays()
	print("[wreck] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## A blast's ring, to look at (Docs/CollapseNext.md 1.10 (3)): one rocket into
## a wall, a picture a tenth of a second on -- the bricks round the hole in the
## air -- and one half a second on, as they fall. The counts are
## tools/blast_ring_probe.gd's; this is what it looks like, and that a city's
## blast goes that way.
func _run_ring_pass() -> void:
	print("[ring] a blast throws out the ring round its middle")
	var b: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build():
			continue
		if b == null or absi(c.recipe.courses - 30) < absi(b.recipe.courses - 30):
			b = c
	var fx: float = b.recipe.footprint_x * City.STUD
	var face: Vector3 = b.xform * Vector3(fx * 0.5, 5.0, 0.0)
	var out: Vector3 = (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized()
	var side: Vector3 = (b.xform.basis * Vector3(1.0, 0.0, 0.0)).normalized()
	city.camera.global_position = face + out * 9.0 + side * 5.0 + Vector3(0.0, 1.0, 0.0)
	city.camera.look_at(face + Vector3(0.0, -1.0, 0.0), Vector3.UP)
	# The pictures are of the wall: the readout would be across the hole.
	city.stats_label.visible = false
	await _frames(90)
	_gate_ok("building %d is bricks" % b.id, b.is_materialised())
	var alive0 := city.world.get_alive_block_count(b.chunk)
	var census0: Array = city.islands.blast_census.duplicate()
	city._blast(face - out * 0.3, 2.0)
	var waited := 0
	while city.islands.blast_census[0] == census0[0] and waited < 120:
		await city.get_tree().physics_frame
		waited += 1
	var killed: int = city.islands.blast_census[0] - int(census0[0])
	var thrown: int = city.islands.blast_census[2] - int(census0[2])
	var core: int = city.islands.blast_census[1] - int(census0[1])
	_gate_ok("the blast killed bricks, and the ones round its middle are in the air",
			killed > 0 and thrown > 0 and thrown + core == killed and city.islands.crumb_count >= thrown,
			"%d killed: %d in the core, %d thrown; %d crumb(s) drawn" % [
				killed, core, thrown, city.islands.crumb_count])
	_gate_ok("and the building has lost every one of them, thrown or not",
			alive0 - city.world.get_alive_block_count(b.chunk) >= killed,
			"%d fewer alive" % (alive0 - city.world.get_alive_block_count(b.chunk)))
	print("[ring]   %d killed: %d in the core, %d thrown; %d crumb(s) drawn" % [
			killed, core, thrown, city.islands.crumb_count])
	await _frames(6)
	await _save("city_ring_0")
	await _frames(24)
	await _save("city_ring_1")
	for t in 150:
		await city.get_tree().physics_frame
	_gate_ok("five seconds on none is falling: what came down lies there",
			city.islands.crumb_count == 0 and (not BrickHeap.enabled()
			or city.islands.heap.count >= thrown - IslandManager.HEAP_FALL_MAX),
			"%d falling, %d lying (%d thrown)" % [city.islands.crumb_count, city.islands.heap.count, thrown])
	await _frames(2)
	await _save("city_ring_2")
	_check_log_replays()
	print("[ring] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _run_drawn_pass() -> void:
	print("[drawn] a building draws the bricks it has, and none it has lost")
	# The recipe tower nearest thirty courses: the big city has none in the
	# twenties or thirties.
	var b: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if c.is_build():
			continue
		if b == null or absi(c.recipe.courses - 30) < absi(b.recipe.courses - 30):
			b = c
	var fx: float = b.recipe.footprint_x * City.STUD
	var face: Vector3 = b.xform * Vector3(fx * 0.5, 7.0, 0.0)
	var out: Vector3 = (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized()
	city.camera.global_position = face + out * 16.0 + Vector3(0.0, 2.0, 0.0)
	city.camera.look_at(face, Vector3.UP)
	await _frames(90)
	_gate_ok("building %d is bricks, its bands drawn" % b.id,
			b.is_materialised() and city._brick_nodes.has(b.id) and not city._bands_building(b.id))
	var before := _drawn_stale(b)
	_gate_ok("whole, it draws nothing but bricks", float(before[1]) <= float(before[0]) * DRAWN_SLACK,
			"%d of %d triangles with no brick behind them: %s" % [before[1], before[0], before[2]])
	for shot in 3:
		city._blast(face + Vector3(0.0, float(shot) * 2.5 - 2.0, 0.0) + out * 0.5, 5.8)
		await _frames(20)
	for t in 240:
		await city.get_tree().physics_frame
	await _frames(4)
	var after := _drawn_stale(b)
	_gate_ok("three big blasts into a wall later, it draws only what it has left",
			float(after[1]) <= float(after[0]) * DRAWN_SLACK,
			"%d of %d triangles with no brick behind them: %s" % [after[1], after[0], after[2]])
	# Furniture holds nothing up: its body is no layer a piece collides with.
	var furniture_ok := true
	for id in city._room_bodies:
		if PhysicsServer3D.body_get_collision_layer(city._room_bodies[id]) \
				& (Layers.FALLING_MASK | Layers.SETTLED_MASK | Layers.AIRBORNE_MASK):
			furniture_ok = false
	_gate_ok("and no piece can come to rest on furniture", furniture_ok,
			"%d furniture bodies" % city._room_bodies.size())
	print("[drawn] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Furniture floating where a building came down (user, 2026-10-16: "furniture
## appears floating where a collapsing building used to be" in the small city,
## walking up to it).
##
##     godot --path . scenes/city.tscn -- --floating
##
## A building is brought down -- its ground storey shot through -- once with
## the camera beside it and once from far off, and left to settle; then the
## camera walks in from 160 m. Every few frames each interior drawing within
## its range (storey groups, a piece's own drawing, riders, laid furniture) is
## asked, part by part, whether anything is under it: a brick of a building or
## a piece in the grid, or the ground. Writes shots/floating_*.png.
func _run_floating_pass() -> void:
	print("[floating] no furniture is drawn with nothing under it")
	# As the game plays: a damaged building out of range is given back to its
	# shell (_trim_quiet) and made bricks again as it is walked up to.
	city.respawn_buildings = "--no-respawn" not in OS.get_cmdline_user_args()
	var picks: Array = []
	for c in city.registry.buildings:
		if c.is_build() or city._wide_ids.has(c.id):
			continue
		if c.recipe.courses >= 18 and c.recipe.courses <= 60:
			picks.append(c)
	picks.sort_custom(func(a, c) -> bool: return a.xform.origin.length() < c.xform.origin.length())
	_gate_ok("three towers to bring down", picks.size() >= 3, "%d found" % picks.size())
	if picks.size() < 3:
		print("[floating] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1)
		return
	# Shot through all round: at its ground storey, watched from beside it; a
	# third of the way up, from well out of range; and one corner of its
	# ground storey, from beside it.
	for k in 3:
		var b: BuildingRegistry.Building = picks[k]
		var fx: float = b.recipe.footprint_x * City.STUD
		var fz: float = b.recipe.footprint_z * City.STUD
		var mid: Vector3 = b.xform * Vector3(fx * 0.5, 0.0, fz * 0.5)
		var away := Vector3(mid.x, 0.0, mid.z).normalized()
		if away.length() < 0.5:
			away = Vector3(1.0, 0.0, 0.0)
		var off := 170.0 if k == 1 else 35.0
		var cut_y := TowerRecipe.total_plates(b.recipe.courses) * City.PLATE / 3.0 if k == 1 else 1.2
		city.camera.global_position = mid + away * off + Vector3(0.0, 14.0, 0.0)
		city.camera.look_at(mid + Vector3(0.0, 8.0, 0.0), Vector3.UP)
		city._promote(b.id)
		await _frames(40)
		# Its groups come up while it stands, if it is in range.
		for t in 60:
			await city.get_tree().physics_frame
		var step := 2.5
		var x := 0.0
		while x <= fx + 0.01:
			var z := 0.0
			while z <= fz + 0.01:
				if k != 2 or (x < fx * 0.5 and z < fz * 0.5):
					city._blast(b.xform * Vector3(minf(x, fx), cut_y, minf(z, fz)), 2.2)
				z += step
			x += step
		# Until it has settled: nothing of it moving for two seconds.
		var still := 0
		var t := 0
		while t < 1200 and still < 120:
			await city.get_tree().physics_frame
			t += 1
			still = still + 1 if city.islands.moving_of(b.id) == 0 and city._damage_queue.is_empty() else 0
		var left := city.world.get_alive_block_count(b.chunk) if b.is_materialised() else 0
		print("  building %d (%d courses): settled after %d ticks, %d bricks standing, %d pieces of it, %d bricks lying"
				% [b.id, b.recipe.courses, t, left, _pieces_of(b.id),
				city.islands.heap.count if city.islands.heap != null else -1])
		if k != 1:
			_floating_report("watched it come down, from %d m" % int(off), _floating_furniture())
		# Away for long enough to be given back (TRIM_RADIUS, TRIM_AFTER_MS),
		# then walk in from 160 m to 8 m, 6 m a second, looking at it.
		city.camera.global_position = mid + away * 260.0 + Vector3(0.0, 30.0, 0.0)
		for w in 15 * 60:
			await city.get_tree().physics_frame
		print("  given back while away: %s, %d pieces of it" % [not b.is_materialised(), _pieces_of(b.id)])
		var d := 160.0
		var seen_worst := 0
		var worst_parts := ""
		var worst_at := -1.0
		var shot := false
		var n := 0
		while d > 8.0:
			d -= 0.1
			city.camera.global_position = mid + away * d + Vector3(0.0, 1.7, 0.0)
			city.camera.look_at(mid + Vector3(0.0, 3.0, 0.0), Vector3.UP)
			await city.get_tree().physics_frame
			n += 1
			if n % 50 != 0:
				continue
			var f: Array = _floating_furniture()
			if f.size() > seen_worst:
				seen_worst = f.size()
				worst_at = d
				worst_parts = ""
				for e in f.slice(0, 4):
					worst_parts += " [%s at %s]" % [e[0], str((e[1] as Vector3).snapped(Vector3.ONE * 0.1))]
				if not shot and f.size() >= 3:
					await _frames(3)
					_save("floating_%d" % k)
					shot = true
					_floating_report("first seen at %d m" % int(d), f)
		await _frames(30)
		if seen_worst > 0:
			print("  --   the worst, at %d m:%s" % [int(worst_at), worst_parts])
		_floating_report("walked in to 8 m (worst %d parts at %d m)" % [seen_worst, int(worst_at)],
				_floating_furniture())
		if not shot:
			_save("floating_%d" % k)
	print("[floating] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The user's way of breaking a building (2026-10-17 pictures): a 12 m blast
## fired at a tower's foot from each of the building's distance tiers -- 25 m
## (bricks), 60 m (bricks, mesh), 160 m (past DEMESH_RANGE: its far drawing)
## and 320 m (past SHELL_RANGE: a recipe) -- then watched from there and flown
## up to at 20 m/s. Pictures at every stop (shots/lodbreak_*); what each says
## of the building, its studs and the furniture and bricks lying near it.
##
##     godot --path . scenes/big_city.tscn -- --lodbreak [--at=<m>] [--pick=<n>] [--foot]
##
## Gates, at each tower's end: no brick of the heap lying in mid-air (a crumb's
## floor gone before it got there: IslandManager._crumb_floor_gone), no stud
## drawn on a brick that has gone (BrickNear.stale_studs), and at every stop
## inside SHELL_RANGE something drawing its walls (_walls_drawn_by), and no piece
## frozen over air that drops when woken close up (_wake_hung_pieces). Furniture riding a
## piece lying on its side reads as floating to _floating_furniture: printed,
## not gated.
func _run_lodbreak_pass() -> void:
	print("[lodbreak] a tower shot down from each tier, then flown up to")
	city.respawn_buildings = false
	BrickHeap.track = true
	city.islands.perch_say = true
	var picks: Array = []
	for c in city.registry.buildings:
		if c.is_build() or city._wide_ids.has(c.id):
			continue
		if c.recipe.courses >= 40:
			picks.append(c)
	picks.sort_custom(func(a, c) -> bool: return a.recipe.courses > c.recipe.courses)
	var dists := [60.0, 90.0, 160.0, 320.0]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--at="):
			dists = [float(a.substr(5))]
		if a.begins_with("--pick="):
			picks = picks.slice(int(a.substr(7)))
	for k in mini(dists.size(), picks.size()):
		var b: BuildingRegistry.Building = picks[k]
		var d: float = dists[k]
		var fx: float = b.recipe.footprint_x * City.STUD
		var fz: float = b.recipe.footprint_z * City.STUD
		var mid: Vector3 = b.xform * Vector3(fx * 0.5, 0.0, fz * 0.5)
		var away := Vector3(mid.x, 0.0, mid.z).normalized()
		if away.length() < 0.5:
			away = Vector3(1.0, 0.0, 0.0)
		var aim_y := TowerRecipe.total_plates(b.recipe.courses) * City.PLATE * 0.5
		if "--foot" in OS.get_cmdline_user_args():
			aim_y = 3.0
		# From the city's middle outward was not always clear: at 160 m the shot
		# landed on the tower in front (2026-10-21, building 10 for 11), and the
		# one asked about was never hit.
		away = _clear_way(b, mid + Vector3(0.0, aim_y, 0.0), away, d)
		city.camera.global_position = mid + away * d + Vector3(0.0, aim_y, 0.0)
		city.camera.look_at(mid + Vector3(0.0, aim_y, 0.0), Vector3.UP)
		await _frames(90)
		_lodbreak_say(b, "%d m, before" % int(d))
		city._fire(12.0)
		_ghost_asked = false
		_ghost_stops.clear()
		for sec in [1, 3, 8]:
			await _frames(60 if sec == 1 else 120 if sec == 3 else 300)
			_ghost_asked = sec == 8
			_lodbreak_say(b, "%d m, after" % int(d))
			_save("lodbreak_%d_%dm_wait%d" % [k, int(d), sec])
		var at := d
		var marks := [110.0, 60.0, 30.0, 12.0]
		var mi := 0
		while at > 12.0:
			at -= 20.0 / 60.0
			city.camera.global_position = mid + away * at + Vector3(0.0, aim_y, 0.0)
			city.camera.look_at(mid + Vector3(0.0, aim_y * 0.7, 0.0), Vector3.UP)
			await city.get_tree().physics_frame
			if mi < marks.size() and at <= marks[mi]:
				if marks[mi] < d:
					await _frames(30)
					_lodbreak_say(b, "flown in to %d m" % int(marks[mi]))
					_save("lodbreak_%d_%dm_at%d" % [k, int(d), int(marks[mi])])
				mi += 1
		await _frames(120)
		_lodbreak_say(b, "2 s at 12 m")
		var lying := 0
		for f in _floating_furniture():
			if f[0] == "heap":
				lying += 1
		_gate_ok("%d m: no brick lying in mid-air" % int(d), lying == 0, "%d" % lying)
		var ss: Array = city.brick_near.stale_studs()
		_gate_ok("%d m: no stud drawn on a brick that has gone" % int(d), int(ss[1]) == 0,
				"%d of %d" % [ss[1], ss[0]])
		_gate_ok("%d m: its walls drawn at every stop (CollapseNext 29(b))" % int(d),
				_lodbreak_blind == 0, "%d stop(s) with nothing drawing them" % _lodbreak_blind)
		_lodbreak_blind = 0
		_gate_ok("%d m: no wall drawn where its bricks are gone, from 8 s on (CollapseNext 29(a))" % int(d),
				_ghost_stops.is_empty(), "; ".join(_ghost_stops))
		_ghost_asked = false
		_save("lodbreak_%d_%dm_settled" % [k, int(d)])
		var ff: Array = _floating_furniture()
		if not ff.is_empty():
			@warning_ignore("integer_division")
			var foot: Vector3 = ff[ff.size() / 2][1]
			for f in ff:
				if f[0] == "heap":
					foot = f[1]
					print("    a heap brick at %s, laid %s" % [str(foot.snapped(Vector3.ONE * 0.1)), f[2]])
					break
			for side in 2:
				city.camera.global_position = foot + (Vector3(7.0, 3.0, 5.0) if side == 0 else Vector3(-6.0, 2.0, -7.0))
				city.camera.look_at(foot, Vector3.UP)
				await _frames(60)
				_lodbreak_say(b, "looking at a floating part at %s" % str(foot.snapped(Vector3.ONE * 0.1)))
				if side == 0:
					var q := PhysicsRayQueryParameters3D.create(foot + Vector3.UP * 0.02, foot + Vector3.DOWN * 60.0)
					q.collision_mask = 0xFFFF
					var hit := city.get_world_3d().direct_space_state.intersect_ray(q)
					var under := "nothing"
					if not hit.is_empty():
						var isl := city.islands.find_by_body(hit.collider)
						under = "%s at %.2f m below (layer %d%s)" % [str(hit.collider), foot.y - (hit.position as Vector3).y,
								(hit.collider as CollisionObject3D).collision_layer if hit.collider is CollisionObject3D else -1,
								", a piece settled %s" % isl.settled if isl != null else ""]
					print("    under it: %s" % under)
				_save("lodbreak_%d_%dm_float%d" % [k, int(d), side])
		var hung: Array = await _wake_hung_pieces(b.id, "lodbreak_%d_%dm" % [k, int(d)])
		_gate_ok("%d m: no piece frozen over air drops when woken close up (CollapseNext 29)" % int(d),
				int(hung[1]) == 0, "%d of %d dropped" % [hung[1], hung[0]])
		if k == mini(dists.size(), picks.size()) - 1:
			var gc: Array = _ghost_control(b.id)
			_gate_ok("the ghost-wall check sees bricks killed and not yet redrawn",
					int(gc[1]) > int(gc[0]), "%d ghost hit(s) before, %d after %d brick(s) killed" % gc)
	print("[lodbreak] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## What draws a building's walls right now: its shell, shown with a mesh; its
## brick node's mesh; or its bands. "" when nothing does (CollapseNext 29(b):
## "close up its interiors are drawn whole and its walls invisible").
func _walls_drawn_by(id: int) -> String:
	var by := PackedStringArray()
	var shell: MeshInstance3D = city._shells.get(id)
	if shell != null and shell.is_visible_in_tree() and shell.mesh != null \
			and shell.mesh.get_surface_count() > 0:
		by.append("shell")
	# A shell with no mesh of its own, drawn by its far box or its instanced set.
	if city._far_on.has(id):
		by.append("far box")
	if shell != null and city._shell_inst.has(id):
		by.append("instanced set")
	var bricks = city._brick_nodes.get(id)
	if bricks is MeshInstance3D and (bricks as MeshInstance3D).is_visible_in_tree():
		var m: Mesh = (bricks as MeshInstance3D).mesh
		if m != null and m.get_surface_count() > 0:
			by.append("bricks")
		var bands := 0
		for c in (bricks as Node).get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null \
					and (c as MeshInstance3D).mesh.get_surface_count() > 0 \
					and (c as MeshInstance3D).material_override != BuildingShell.window_material():
				bands += 1
		if bands > 0:
			by.append("%d band(s)" % bands)
	return " + ".join(by)

func _ghost_walls(id: int, solid_out: Array = []) -> Array:
	var b := city.registry.get_building(id)
	if b == null or not b.is_materialised():
		return [0, 0, {}, [], 0]
	var sources: Array = []   # [MeshInstance3D, its TriangleMesh, what it is]
	var bricks = city._brick_nodes.get(id)
	if bricks is MeshInstance3D and (bricks as MeshInstance3D).is_visible_in_tree() \
			and (bricks as MeshInstance3D).mesh != null \
			and (bricks as MeshInstance3D).mesh.get_surface_count() > 0:
		sources.append([bricks, (bricks as MeshInstance3D).mesh.generate_triangle_mesh(), "bricks"])
	for n in city._brick_bands.get(id, []):
		var band := n as MeshInstance3D
		if band != null and is_instance_valid(band) and band.is_visible_in_tree() \
				and band.mesh != null and band.mesh.get_surface_count() > 0:
			sources.append([band, band.mesh.generate_triangle_mesh(), "band"])
	var shell: MeshInstance3D = city._shells.get(id)
	if shell != null and shell.is_visible_in_tree() and shell.mesh != null \
			and shell.mesh.get_surface_count() > 0:
		sources.append([shell, shell.mesh.generate_triangle_mesh(), "shell"])
	var rest = city._rest_shells.get(id, [null])[0]
	if rest is MeshInstance3D and is_instance_valid(rest) and (rest as MeshInstance3D).is_visible_in_tree() \
			and (rest as MeshInstance3D).mesh != null and (rest as MeshInstance3D).mesh.get_surface_count() > 0:
		sources.append([rest, (rest as MeshInstance3D).mesh.generate_triangle_mesh(), "rest shell"])
	if sources.is_empty():
		return [0, 0, {}, [], 0]
	var box := CityPlacer.box_of(b)
	var c := box.get_center()
	var eye := city.camera.global_position
	var right := Vector3(-(c - eye).z, 0.0, (c - eye).x).normalized()
	var wide := absf(box.size.x * right.x) + absf(box.size.z * right.z)
	var reach := eye.distance_to(c) + box.size.length()
	var into := city.world.get_chunk_transform(b.chunk).affine_inverse()
	var origin := city.world.get_chunk_origin(b.chunk)
	var cs := BrickWorld.get_cell_size()
	var hits := 0
	var whole := 0
	var ghosts := 0
	var by := {}
	var some: Array = []   # up to five ghosts: where, and its face's normal
	for i in GHOST_RAYS.x:
		for j in GHOST_RAYS.y:
			var at := c + right * wide * ((i + 0.5) / GHOST_RAYS.x - 0.5) \
					+ Vector3.UP * box.size.y * ((j + 0.5) / GHOST_RAYS.y - 0.5)
			var to := eye + (at - eye).normalized() * reach
			var best := INF
			var p := Vector3.ZERO
			var nrm := Vector3.ZERO
			var what := ""
			for s in sources:
				var xf: Transform3D = (s[0] as Node3D).global_transform
				var inv := xf.affine_inverse()
				var hit: Dictionary = (s[1] as TriangleMesh).intersect_segment(inv * eye, inv * to)
				if hit.is_empty():
					continue
				var w: Vector3 = xf * (hit.position as Vector3)
				var dd := eye.distance_to(w)
				if dd < best:
					best = dd
					p = w
					nrm = (xf.basis * (hit.normal as Vector3)).normalized()
					what = s[2]
			if what == "":
				continue
			# Half a cell into the face: what was drawn there. On a storey line
			# the face itself belongs to neither (the underside of a storey not
			# laid, seen from a crater, read as the laid one under it).
			var inner := p - nrm * cs.y * 0.5
			# Laid a storey at a time: a storey not laid, and still the
			# building's, is drawn whole by design -- not asked. One laid, or
			# one that left over the cut, is judged by its bricks.
			if b.banded:
				var at_s := city.registry.storeys_in(id, inner, 0.0)
				var s := at_s[0] if not at_s.is_empty() else -1
				if not b.storeys_laid.has(s) and (b.cut_storey < 0 or s < b.cut_storey):
					whole += 1
					continue
			hits += 1
			var cell := Vector3i(((into * inner) / cs).floor()) + origin
			var solid := false
			for dx in [0, -1, 1]:
				for dy in [0, -1, 1]:
					for dz in [0, -1, 1]:
						if not solid and city.world.is_solid(b.chunk, cell + Vector3i(dx, dy, dz)):
							solid = true
							if solid_out.size() < 40:
								solid_out.append(cell + Vector3i(dx, dy, dz))
			if not solid:
				ghosts += 1
				by[what] = int(by.get(what, 0)) + 1
				if some.size() < 5:
					some.append("%s n%s" % [str(p.snapped(Vector3.ONE * 0.1)), str(nrm.snapped(Vector3.ONE * 0.1))])
	return [hits, ghosts, by, some, whole]

## Does _ghost_walls see a wall drawn where its bricks have gone? The bricks
## its rays hit, and every one within two cells, are killed -- with no word to
## anything that redraws -- and it is asked again in the same frame: those
## hits must now be ghosts. Leaves the building drawn wrong, so only once, at
## the pass's end. [ghosts before, ghosts after, bricks killed].
func _ghost_control(id: int) -> Array:
	var b := city.registry.get_building(id)
	var cells: Array = []
	var before: Array = _ghost_walls(id, cells)
	if b == null or not b.is_materialised() or cells.is_empty():
		return [before[1], before[1], 0]
	var killed := 0
	for e in cells:
		var cell: Vector3i = e
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				for dz in range(-2, 3):
					if city.world.kill_block(b.chunk, cell + Vector3i(dx, dy, dz)) >= 0:
						killed += 1
	var after: Array = _ghost_walls(id)
	return [before[1], after[1], killed]

## Of eight ways round building `b`, starting at `away`, the first with no other
## building's box between a camera `d` out and `at`.
func _clear_way(b: BuildingRegistry.Building, at: Vector3, away: Vector3, d: float) -> Vector3:
	for k in 8:
		var dir := away.rotated(Vector3.UP, k * PI / 4.0)
		var blocked := false
		for o in city.registry.buildings:
			if o.id != b.id and CityPlacer.box_of(o).intersects_segment(at + dir * d, at):
				blocked = true
				break
		if not blocked:
			return dir
	return away

func _lodbreak_say(b: BuildingRegistry.Building, what: String) -> void:
	var alive := city.world.get_alive_block_count(b.chunk) if b.is_materialised() else -1
	var shell: MeshInstance3D = city._shells.get(b.id)
	var bricks: Node3D = city._brick_nodes.get(b.id)
	var drawn := _walls_drawn_by(b.id)
	print("    its walls drawn by: %s" % (drawn if drawn != "" else "NOTHING"))
	var t_ghost := Time.get_ticks_msec()
	var gw: Array = _ghost_walls(b.id)
	print("    ghost walls: %d of %d hits drawn where no brick is %s, %d on storeys not laid%s (%d ms)" % [
			gw[1], gw[0], str(gw[2]), gw[4],
			" at " + ", ".join(gw[3]) if int(gw[1]) > 0 else "",
			Time.get_ticks_msec() - t_ghost])
	if b.banded:
		print("      storeys laid %s of %d, cut at %d" % [str(b.storeys_laid), city.registry.storey_count(b.id), b.cut_storey])
	if _ghost_asked and int(gw[1]) > maxi(GHOST_ALLOWED, int(float(gw[0]) * GHOST_SHARE)):
		_ghost_stops.append("%s: %d of %d" % [what, gw[1], gw[0]])
	# Past SHELL_RANGE a building has no node at all: the far city draws it.
	if drawn == "" and alive != 0 and b.xform.origin.distance_to(city.camera.global_position) < City.SHELL_RANGE:
		_lodbreak_blind += 1
	var ss: Array = city.brick_near.stale_studs()
	var ff: Array = _floating_furniture()
	var fk := {}
	for f in ff:
		fk[f[0]] = int(fk.get(f[0], 0)) + 1
	print("    studs held %d, %d with no brick under them %s; furniture parts %d, %d floating %s"
			% [ss[0], ss[1], str(ss[2]), _float_seen, ff.size(), str(fk)])
	var gboxes := 0
	var gl: Array = city.interior_groups.known(b.id)
	for gi in gl.size():
		var pn := city.interior_groups.piece_node(b.id, gi)
		if pn != null and pn.is_visible_in_tree() and pn.multimesh != null:
			gboxes += pn.multimesh.visible_instance_count if pn.multimesh.visible_instance_count >= 0 else pn.multimesh.instance_count
	print("    its storey groups draw %d piece box(es)" % gboxes)
	if shell != null:
		var panes := 0
		for c in shell.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				@warning_ignore("integer_division")
				panes += (c as MeshInstance3D).mesh.surface_get_array_len(0) / 4
		print("    its shell: %s mesh, %d painted window(s)%s" % [
				"a" if shell.mesh != null else "no", panes,
				", from its bricks" if city._far_real_owed.has(b.id) or city.far_real_built > 0 else ""])
	_pieces_say(b.id)
	print("  [%d] %s: dist %.0f, materialised %s, %d bricks alive, shell %s, brick node %s, bands building %s, pieces %d (%d moving), damage %d"
			% [b.id, what, city.camera.global_position.distance_to(b.xform.origin), b.is_materialised(), alive,
			"none" if shell == null else ("shown" if shell.visible else "hidden"),
			"none" if bricks == null else ("shown" if bricks.visible else "hidden"),
			city._bands_building(b.id),
			_pieces_of(b.id), city.islands.moving_of(b.id), b.damage_profile.size()])

## Which way buildings break (user, 2026-10-18: "they break in half
## vertically, when lego breaks along the layers"). Towers shot close up (the
## hot tier), and every piece of 50 bricks or more that leaves one measured in
## the building's own studs and plates the tick it is first seen, before it has
## moved: a LAYER spans the building's plan (80% of it both ways); a SLICE is
## two storeys tall or more and does not. For each cut face of a slice -- a
## side of its box that is not the building's own face -- where it lies: on a
## floor panel line (TowerRecipe.PANEL), a 32-stud region line, the edge of a
## window column, or elsewhere.
##
##     godot --path . scenes/big_city.tscn -- --breakshape [--picks=N] [--no-stagger]
##
## Four towers unless `--picks` asks for more: four make three pieces of 50+,
## too few to tell one floor layout from another (TowerRecipe.STAGGER).
func _run_breakshape_pass() -> void:
	print("[breakshape] towers shot close up, every piece measured as it leaves (stagger %s)"
			% ("on" if TowerRecipe.stagger else "off"))
	city.respawn_buildings = false
	var picks: Array = []
	for c in city.registry.buildings:
		if not c.is_build() and not city._wide_ids.has(c.id) and c.recipe.courses >= 30:
			picks.append(c)
	picks.sort_custom(func(a, c) -> bool: return a.id < c.id)
	var count := 4
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--picks="):
			count = int(a.substr(8))
	print("[breakshape] %d of %d tower(s)" % [mini(count, picks.size()), picks.size()])
	picks = picks.slice(0, count)
	var storey_m := TowerRecipe.STOREY_PLATES * City.PLATE
	var tally := {"layer": 0, "slice": 0, "other": 0}
	var faces := {"panel": 0, "region": 0, "window": 0, "elsewhere": 0}
	var shots := [[0.5, 0.5, 6.0], [0.05, 0.5, 8.0], [0.5, 0.15, 7.0]]
	for b: BuildingRegistry.Building in picks:
		for shot in shots:
			if b.toppled:
				break
			var fx: float = b.recipe.footprint_x * City.STUD
			var tall := TowerRecipe.total_plates(b.recipe.courses) * City.PLATE
			var aim: Vector3 = b.xform * Vector3(fx * float(shot[0]), tall * float(shot[1]), 0.0)
			city.camera.global_position = b.xform * Vector3(fx * float(shot[0]), tall * float(shot[1]), -30.0)
			city.camera.look_at(aim, Vector3.UP)
			await _frames(20)
			var known := {}
			for isl in city.islands.islands:
				if isl.is_valid():
					known[isl] = true
			city._blast(aim, float(shot[2]))
			var inv := b.xform.affine_inverse()
			for t in 360:
				await city.get_tree().physics_frame
				for isl in city.islands.islands:
					if not isl.is_valid() or known.has(isl) or isl.owner != b.id:
						continue
					known[isl] = true
					var n := city.world.get_alive_block_count(isl.chunk)
					if n < 50:
						continue
					var wb := city.islands.world_aabb(isl)
					var lb := inv * wb
					var lo := Vector2(lb.position.x / City.STUD, lb.position.z / City.STUD)
					var hi := Vector2(lb.end.x / City.STUD, lb.end.z / City.STUD)
					var share := Vector2((hi.x - lo.x) / b.recipe.footprint_x,
							(hi.y - lo.y) / b.recipe.footprint_z)
					var storeys := lb.size.y / storey_m
					var what := "other"
					if share.x >= 0.8 and share.y >= 0.8:
						what = "layer"
					elif storeys >= 2.0:
						what = "slice"
					tally[what] += 1
					var cuts := []
					if what == "slice":
						for pair in [[lo.x, b.recipe.footprint_x], [hi.x, b.recipe.footprint_x],
								[lo.y, b.recipe.footprint_z], [hi.y, b.recipe.footprint_z]]:
							var v := roundi(float(pair[0]))
							if v <= 1 or v >= int(pair[1]) - 1:
								continue   # the building's own face
							var on := "elsewhere"
							if v % TowerRecipe.PANEL <= 1 or v % TowerRecipe.PANEL >= TowerRecipe.PANEL - 1:
								on = "panel"
							elif v % 32 <= 1 or v % 32 >= 31:
								on = "region"
							else:
								for g in TowerRecipe.window_gaps(int(pair[1])):
									if absi(v - (g as Vector2i).x) <= 1 or absi(v - (g as Vector2i).y) <= 1:
										on = "window"
							faces[on] += 1
							cuts.append("%d:%s" % [v, on])
					print("[breakshape]   building %d shot %s: %s, %d bricks, plan %.0f%% x %.0f%%, %.1f storeys, y %.1f..%.1f m %s" % [
							b.id, str(shot), what, n, share.x * 100.0, share.y * 100.0, storeys,
							lb.position.y, lb.end.y, str(cuts) if not cuts.is_empty() else ""])
			_save("breakshape_%d_%d" % [b.id, shots.find(shot)])
	print("[breakshape] pieces of 50+: %s; a slice's cut faces lie on %s" % [str(tally), str(faces)])
	city.get_tree().quit(0)

## The rooms view (Shift+O, SpacesView) on a tower, for pictures: one of
## eight storeys or more, in bricks, its structure see-through, from a corner
## outside and from above. Prints what the finder made of it.
##
##     godot --path . scenes/big_city.tscn -- --roomsview [--pick=N]
func _run_roomsview_pass() -> void:
	print("[roomsview] the rooms of a tower, as the finder makes them")
	city.respawn_buildings = false
	var picks: Array = []
	for c in city.registry.buildings:
		if not c.is_build() and not city._wide_ids.has(c.id) and c.recipe.courses >= 48:
			picks.append(c)
	picks.sort_custom(func(a, c) -> bool: return a.recipe.courses < c.recipe.courses)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pick="):
			picks = picks.slice(int(a.substr(7)))
	if picks.is_empty():
		print("[roomsview] no tower of eight storeys")
		city.get_tree().quit(1)
		return
	var b: BuildingRegistry.Building = picks[0]
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	var tall := TowerRecipe.total_plates(b.recipe.courses) * City.PLATE
	var corner: Vector3 = b.xform * Vector3(-0.6 * fx, 0.0, -0.6 * fz)
	var mid: Vector3 = b.xform * Vector3(fx * 0.5, 0.0, fz * 0.5)
	city.camera.global_position = corner + Vector3(0, tall * 0.35, 0)
	city.camera.look_at(mid + Vector3(0, tall * 0.25, 0), Vector3.UP)
	await _frames(30)
	city._promote(b.id)
	await _frames(60)
	_view_set(DebugView.Mode.CLEAR, DebugView.Mode.HIDDEN, DebugView.Mode.HIDDEN)
	city._toggle_spaces_view()
	city._spaces_ms = 0
	await _frames(90)
	print("[roomsview] building %d, %d x %d studs, %d courses: %s" % [b.id, b.recipe.footprint_x,
			b.recipe.footprint_z, b.recipe.courses, city._spaces_view.report()])
	_save("roomsview_corner")
	city.camera.global_position = mid + Vector3(0.01, tall + 25.0, 0)
	city.camera.look_at(mid + Vector3(0, tall * 0.5, 0), Vector3.FORWARD)
	await _frames(30)
	_save("roomsview_above")
	city.camera.global_position = b.xform * Vector3(fx * 0.5, TowerRecipe.STOREY_PLATES * City.PLATE * 1.5, -6.0)
	city.camera.look_at(mid + Vector3(0, TowerRecipe.STOREY_PLATES * City.PLATE * 1.2, 0), Vector3.UP)
	await _frames(30)
	_save("roomsview_storey")
	city.get_tree().quit(0)

## What the drawn rooms cost to draw (Docs/Structures.md 4.2, the drawn
## state): the renderer's own clock with the interior pieces and items shown,
## then hidden, from the foot of the tallest tower and from above the city.
##
##     godot --path . scenes/big_city.tscn -- --roomcost
##
## Timing: the editor closed and no other run going (CLAUDE.md).
func _run_roomcost_pass() -> void:
	print("[roomcost] drawn rooms, shown and hidden")
	city.respawn_buildings = false
	var best: BuildingRegistry.Building = null
	for c in city.registry.buildings:
		if not c.is_build() and (best == null or c.recipe.courses > best.recipe.courses):
			best = c
	var fx: float = best.recipe.footprint_x * City.STUD
	var fz: float = best.recipe.footprint_z * City.STUD
	var mid: Vector3 = best.xform * Vector3(fx * 0.5, 0.0, fz * 0.5)
	var away := Vector3(mid.x, 0.0, mid.z).normalized()
	if away.length() < 0.5:
		away = Vector3(1.0, 0.0, 0.0)
	var views := [["street", mid + away * (maxf(fx, fz) * 0.5 + 8.0) + Vector3(0, 1.7, 0),
			mid + Vector3(0, 12.0, 0)],
			["above", mid + away * 70.0 + Vector3(0, 40.0, 0), mid + Vector3(0, 10.0, 0)]]
	for v in views:
		city.camera.global_position = v[1]
		city.camera.look_at(v[2], Vector3.UP)
		await _frames(480)
		var groups := 0
		var boxes := 0
		for id in city.interior_groups.known_ids():
			var gl: Array = city.interior_groups.known(id)
			for gi in gl.size():
				for mm in [city.interior_groups.piece_node(id, gi), city.interior_groups.item_node(id, gi)]:
					if mm != null and mm.is_visible_in_tree() and mm.multimesh != null:
						groups += 1
						boxes += mm.multimesh.visible_instance_count 								if mm.multimesh.visible_instance_count >= 0 else mm.multimesh.instance_count
		var shown: Array = await _frame_times(240)
		_view_set(DebugView.Mode.SHOWN, DebugView.Mode.HIDDEN, DebugView.Mode.HIDDEN)
		await _frames(30)
		var hidden: Array = await _frame_times(240)
		_view_set(DebugView.Mode.SHOWN, DebugView.Mode.SHOWN, DebugView.Mode.SHOWN)
		await _frames(30)
		print("[roomcost] %s: %d drawing(s), %d box(es) of rooms" % [v[0], groups, boxes])
		print("[roomcost]   shown:  %s" % _frame_line(shown))
		print("[roomcost]   hidden: %s" % _frame_line(hidden))
		_save("roomcost_%s" % v[0])
	city.get_tree().quit(0)

## Each piece of a building: how big, where, at rest or not, and what is
## under it -- what the lodbreak pass says of a collapse that stops in the air.
func _pieces_say(id: int) -> void:
	var b := city.registry.get_building(id)
	if b != null and b.is_materialised():
		var sb := city.world.get_blocks_box(b.chunk, PackedInt32Array())
		print("    standing part: %d bricks, box y %.1f..%.1f (chunk space)" % [
				city.world.get_alive_block_count(b.chunk), sb.position.y, sb.end.y])
	for isl in city.islands.islands:
		if not isl.is_valid() or isl.owner != id:
			continue
		var box := city.islands.world_aabb(isl)
		var space := isl.body.get_world_3d().direct_space_state
		var c := box.get_center()
		var q := PhysicsRayQueryParameters3D.create(Vector3(c.x, box.position.y + 0.1, c.z),
				Vector3(c.x, box.position.y - 60.0, c.z), isl.body.collision_mask, [isl.body.get_rid()])
		q.hit_from_inside = true
		var hit := space.intersect_ray(q)
		print("    (perched tips so far %d) piece %d: %d bricks, y %.1f..%.1f, %s%s, speed %.2f, %s under its middle%s" % [city.islands.perched_tipped,
				isl.piece_id, city.world.get_alive_block_count(isl.chunk), box.position.y, box.end.y,
				"settled" if isl.settled else "loose", " frozen" if isl.body.freeze else "",
				isl.body.linear_velocity.length(),
				("%s %.1f m down" % [str(hit.collider.name) if hit.collider != null else "?",
				box.position.y + 0.1 - hit.position.y]) if not hit.is_empty() else "nothing",
				", supported" if city.islands._supported_below(isl) else ", NOT supported"])
		var drawn := "no mesh node"
		if isl.mesh != null and is_instance_valid(isl.mesh):
			drawn = "mesh %s at y %.1f (body y %.1f), %s" % [
					"shown" if isl.mesh.is_visible_in_tree() else "hidden",
					isl.mesh.global_position.y, isl.body.global_position.y,
					"has a mesh" if isl.mesh.mesh != null else "no mesh"]
		print("      drawn: %s; coarse %s, coarse drawn %s, fly merged %s, mm key %s" % [
				drawn, isl.coarse, isl.coarse_drawn, isl.fly_merged, str(isl.mm_key)])
		# What holds it, from the same nine rays IslandManager._under asks (but
		# 30 m long): the gap under each, rows of x by z, and where its weight is.
		var gaps := PackedStringArray()
		for fx in [0.02, 0.5, 0.98]:
			for fz in [0.02, 0.5, 0.98]:
				var at := Vector3(box.position.x + box.size.x * fx, box.position.y + 0.1,
						box.position.z + box.size.z * fz)
				var rq := PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 30.0,
						isl.body.collision_mask, [isl.body.get_rid()])
				rq.hit_from_inside = true
				var rh := space.intersect_ray(rq)
				var on := ""
				if not rh.is_empty():
					var hp := city.islands.find_by_body(rh.collider) if rh.collider is Node else null
					on = ("p%d" % hp.piece_id) if hp != null else "b" if rh.collider == null else "g"
				gaps.append("%.1f%s" % [at.y - 0.1 - (rh.position as Vector3).y, on] if not rh.is_empty() else "-")
		var com := isl.body.global_position - box.position
		print("      plan %.1f x %.1f m (perch foot %.1f), weight at %.1f, %.1f of it; gaps under: %s / %s / %s" % [
				box.size.x, box.size.z, IslandManager.PERCH_FOOT, com.x, com.z,
				" ".join(gaps.slice(0, 3)), " ".join(gaps.slice(3, 6)), " ".join(gaps.slice(6, 9))])
		print("      perch: %s" % city.islands.perch_said.get(isl.piece_id, "never asked"))

func _wake_hung_pieces(id: int, prefix: String) -> Array:
	var was := city.camera.global_transform
	var shot := 0
	var moved := 0
	for e in city.islands.islands.duplicate():
		var isl: BrickIsland = e
		if shot >= 3:
			break
		if not isl.is_valid() or isl.owner != id or not isl.body.freeze:
			continue
		var box := city.islands.world_aabb(isl)
		var c := box.get_center()
		var q := PhysicsRayQueryParameters3D.create(Vector3(c.x, box.position.y + 0.1, c.z),
				Vector3(c.x, box.position.y - 60.0, c.z), isl.body.collision_mask, [isl.body.get_rid()])
		q.hit_from_inside = true
		var hit := isl.body.get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty() and box.position.y + 0.1 - (hit.position as Vector3).y <= HUNG_GAP:
			continue
		var from := was.origin - c
		from.y = 0.0
		from = from.normalized() if from.length() > 0.1 else Vector3(1.0, 0.0, 0.0)
		city.camera.global_position = c + from * maxf(15.0, box.size.length() * 1.2)
		city.camera.look_at(c, Vector3.UP)
		await _frames(30)
		_save("%s_hung%d" % [prefix, shot])
		var y0 := box.position.y
		city.islands.wake(isl)
		await _frames(180)
		var now_y := city.islands.world_aabb(isl).position.y if isl.is_valid() else NAN
		if is_nan(now_y) or y0 - now_y > HUNG_DROP:
			moved += 1
		print("    piece %d woken close up: %s" % [isl.piece_id,
				"gone" if is_nan(now_y) else "down %.1f m, %s" % [y0 - now_y,
				"settled" if isl.settled else "moving"]])
		_save("%s_hung%d_woken" % [prefix, shot])
		shot += 1
	city.camera.global_transform = was
	return [shot, moved]

func _pieces_of(id: int) -> int:
	var n := 0
	for isl in city.islands.islands:
		if isl.is_valid() and isl.owner == id:
			n += 1
	return n

func _floating_report(what: String, found: Array) -> void:
	var kinds := {}
	for f in found:
		kinds[f[0]] = int(kinds.get(f[0], 0)) + 1
	var some := ""
	for f in found.slice(0, 4):
		some += " [%s at %s]" % [f[0], str((f[1] as Vector3).snapped(Vector3.ONE * 0.1))]
	_gate_ok("%s: no furniture with nothing under it (%d parts drawn)" % [what, _float_seen],
			found.is_empty(), "%d parts: %s;%s" % [found.size(), str(kinds), some])
	# What each of the first few stands over: which building, in what state.
	for f in found.slice(0, 2):
		var at: Vector3 = f[1]
		for id in city._near_buildings(at, 2.0):
			var b := city.registry.get_building(id)
			if b == null or b.is_build() or not city._world_box(b).grow(0.5).has_point(at):
				continue
			var local := b.xform.affine_inverse() * at
			var band := -1
			var bi := 0
			for l in TowerRecipe.layout(b.recipe.courses):
				if local.y >= int(l.y) * City.PLATE - 0.3 and local.y < (int(l.y) + int(l.plates)) * City.PLATE + 0.3:
					band = bi
				bi += 1
			print("  --   over building %d at local y %.2f: bricks %s, banded %s, laid %s, cut %d, shell %s (coarse %s), rest shell %s, toppled %s, profile around band %d: %s" % [
					id, local.y, b.is_materialised(), b.banded, str(b.storeys_laid), b.cut_storey,
					city._shells.has(id), city._shell_coarse.get(id, false), city._rest_shells.has(id), b.toppled, band,
					str([b.damage_profile.get(band - 1), b.damage_profile.get(band), b.damage_profile.get(band + 1)])])

func _floating_furniture() -> Array:
	var out: Array = []
	_float_seen = 0
	var here := city.camera.global_position
	var under := _float_supports(here)
	var riders := {}
	for r in city._group_riders:
		riders[r[1]] = true
	var brick_parents := {}
	for id in city._brick_nodes:
		brick_parents[city._brick_nodes[id]] = true
	var space := city.get_world_3d().direct_space_state
	for node in city.get_tree().get_nodes_in_group(DebugView.GROUP_INTERIOR):
		if not (node is MultiMeshInstance3D) or not (node as Node3D).is_visible_in_tree():
			continue
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm == null:
			continue
		var kind := "laid"
		if riders.has(node):
			kind = "rider"
		elif brick_parents.has((node as Node).get_parent()):
			kind = "group"
		elif (node as MultiMeshInstance3D).material_override == InteriorGroups.piece_material():
			kind = "piece"
		var xf0: Transform3D = (node as Node3D).global_transform
		for i in mm.instance_count:
			var xf: Transform3D = xf0 * mm.get_instance_transform(i)
			if xf.basis.get_scale().length() < 0.001:
				continue   # taken out
			if xf.origin.distance_to(here) > InteriorGroups.INTERIOR_RANGE:
				continue   # faded out
			_float_seen += 1
			var hy := 0.5 * (absf(xf.basis.x.y) + absf(xf.basis.y.y) + absf(xf.basis.z.y))
			var foot := xf.origin - Vector3(0.0, hy, 0.0)
			if not _float_held(foot, space, under):
				out.append([kind, foot])
	# And bricks lying in the heap (BrickHeap): a broken piece of furniture's
	# parts are its bricks, in its colours.
	var heap: BrickHeap = city.islands.heap
	if heap != null:
		for h in heap._heaps.values():
			for i in (h.used as PackedByteArray).size():
				if h.used[i] == 0 or h.fixed[i] != 0:
					continue
				var xf: Transform3D = h.xf[i]
				if xf.origin.distance_to(here) > BrickHeap.DRAW_RANGE:
					continue
				_float_seen += 1
				var size: Vector3 = h.size
				var hy := 0.5 * (absf(xf.basis.x.y) * size.x + absf(xf.basis.y.y) * size.y
						+ absf(xf.basis.z.y) * size.z)
				if not _float_held(xf.origin - Vector3(0.0, hy, 0.0), space, under):
					out.append(["heap", xf.origin - Vector3(0.0, hy, 0.0),
							h.why[i] if not h.why.is_empty() else ""])
	return out

## What can hold something up near `here`, as it is drawn there: buildings in
## bricks and pieces by their grids; a building drawn by its shell by the floors
## the shell draws (BuildingShell caps every slab band left standing across the
## whole footprint, where its collision has only walls, the ground plate and a
## roof); an asleep piece by its box, while its stand-in is drawn. Heap bricks
## are drawn out to BrickHeap.DRAW_RANGE, past the interiors' range: a building
## given back or a piece put to sleep out there is not in the grid, and a brick
## lying on one read as floating (--floating, 2026-10-20: three on a shell's
## first floor at 135 m; the odd heap brick of --lodbreak, CollapseNext 28).
func _float_supports(here: Vector3) -> Dictionary:
	# [chunk, world -> chunk space, origin]
	var chunks: Array = []
	# [world -> building space, width, depth, the tops of its floors drawn]
	var shells: Array = []
	for id in city._near_buildings(here, maxf(InteriorGroups.INTERIOR_RANGE, BrickHeap.DRAW_RANGE) + 60.0):
		var b := city.registry.get_building(id)
		if b == null:
			continue
		if b.is_materialised() and b.chunk >= 0:
			chunks.append([b.chunk, city.world.get_chunk_transform(b.chunk).affine_inverse(),
					city.world.get_chunk_origin(b.chunk)])
			# Laid a storey at a time: the storeys still whole are its rest
			# shell, and what lies on them is held (Docs/Space.md 5.3a).
			if city._rest_shells.has(id) and not b.is_build():
				shells.append([b.xform.affine_inverse(), b.recipe.footprint_x * City.STUD,
						b.recipe.footprint_z * City.STUD,
						_shell_tops(b.recipe.courses, city.registry.rest_profile(id))])
		elif not b.is_build() and city._shells.has(id):
			var tops := _shell_tops(b.recipe.courses, b.damage_profile)
			if bool(city._shell_coarse.get(id, false)):
				# The far-far tier: one solid band and a cap at the cornice's top.
				tops.append(TowerRecipe.total_plates(b.recipe.courses) * City.PLATE)
			shells.append([b.xform.affine_inverse(), b.recipe.footprint_x * City.STUD,
					b.recipe.footprint_z * City.STUD, tops])
	for isl in city.islands.islands:
		if isl.is_valid() and isl.chunk >= 0:
			chunks.append([isl.chunk, city.world.get_chunk_transform(isl.chunk).affine_inverse(),
					city.world.get_chunk_origin(isl.chunk)])
	# A shell piece (Docs/Space.md 5.3a) is a body like any piece: what lies on
	# its floors, or on its top, lies on something. In its own frame it is the
	# building's storeys [lo, hi), so its tops are theirs.
	for p in city._shell_pieces:
		if not is_instance_valid(p):
			continue
		var pb := city.registry.get_building(p.building)
		if pb == null:
			continue
		var plines := city.registry.storey_lines(pb)
		var ptops := PackedFloat32Array()
		for st in range(p.lo, p.hi):
			if not p.holes.has(st):
				ptops.append((plines[st] + TowerRecipe.SLAB_PLATES) * City.PLATE)
		ptops.append(plines[p.hi] * City.PLATE)
		shells.append([p.global_transform.affine_inverse(), pb.recipe.footprint_x * City.STUD,
				pb.recipe.footprint_z * City.STUD, ptops])
	var sleepers: Array = []
	for dm in city.islands.dormant:
		if dm.stand_in != null and is_instance_valid(dm.stand_in):
			sleepers.append(dm.record.box)
	return {"chunks": chunks, "shells": shells, "sleepers": sleepers}

## What lies on a shell's top surfaces lies on something: its floors, the top
## of a band of wall where the band over it is shot away or holed (the shell's
## boxes stand to there: BuildingShell._damaged_boxes), and its top. Heights in
## the building's own metres, from a damage profile.
func _shell_tops(courses: int, profile: Dictionary) -> PackedFloat32Array:
	var tops := PackedFloat32Array()
	var lay := TowerRecipe.layout(courses)
	for i in lay.size():
		var band: Dictionary = lay[i]
		if BuildingShell._band_is_gone(profile.get(i, PackedInt32Array())):
			continue
		var top := float(int(band.y) + int(band.plates)) * City.PLATE
		var is_floor: bool = band.kind == "base" or band.kind == "slab"
		if is_floor or i + 1 >= lay.size() or profile.has(i + 1):
			tops.append(top)
	return tops

## Something under `foot` within FLOAT_REACH: the ground, or one of `under`
## (_float_supports).
func _float_held(foot: Vector3, space: PhysicsDirectSpaceState3D, under: Dictionary) -> bool:
	var q := PhysicsRayQueryParameters3D.create(foot + Vector3(0.0, 0.05, 0.0),
			foot - Vector3(0.0, FLOAT_REACH, 0.0))
	q.collision_mask = Layers.WORLD
	if not space.intersect_ray(q).is_empty():
		return true
	for s in under.shells:
		var local: Vector3 = (s[0] as Transform3D) * foot
		if local.x < 0.0 or local.z < 0.0 or local.x > float(s[1]) or local.z > float(s[2]):
			continue
		for top in (s[3] as PackedFloat32Array):
			if top <= local.y + 0.05 and top >= local.y - FLOAT_REACH:
				return true
	for box in under.sleepers:
		var bx: AABB = box
		if foot.x >= bx.position.x and foot.x <= bx.end.x and foot.z >= bx.position.z \
				and foot.z <= bx.end.z and bx.position.y <= foot.y + 0.05 \
				and bx.end.y >= foot.y - FLOAT_REACH:
			return true
	var cs := BrickWorld.get_cell_size()
	var s := 0.02
	while s < FLOAT_REACH:
		var p := foot - Vector3(0.0, s, 0.0)
		for c in under.chunks:
			var local: Vector3 = (c[1] as Transform3D) * p
			if city.world.is_solid(int(c[0]), Vector3i((local / cs).floor()) + (c[2] as Vector3i)):
				return true
		s += cs.y * 0.5
	return false

## The storey groups' gate (Docs/Interiors.md 8.2 and 8.7, stage 1).
##
##     godot --path . --resolution 1280x720 scenes/city.tscn -- --groups --big
##
## One tower seen through its windows from three ranges, drawn by the rungs and
## then by the storey groups: shots/interior_rungs_*.png beside
## shots/interior_groups_*.png. And what a screenshot does not show:
##
##   * a group is drawn by its own distance and by nothing else -- the rungs
##     draw nothing while the groups do, and a group past its range is not kept;
##   * collision is for the group the player is at, not for what is far off;
##   * a shot works out the groups at its height and leaves the rest alone;
##   * nothing of a group is left drawn in a section that has fallen;
##   * no group is made in a building that is coming apart, and the storeys
##     left standing get theirs once it is still (Docs/CollapseNext.md 1.8).
func _run_groups_pass() -> void:
	print("[groups] interiors by storey group")
	# The towers looked at keep their bricks at every range they are looked from.
	city.respawn_buildings = false
	var picks := _groups_pick(2)
	_gate_ok("two towers of eight storeys or more with a face nothing stands in front of",
			picks.size() == 2, "%d found" % picks.size())
	if picks.size() < 2:
		print("[groups] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1)
		return
	var b: BuildingRegistry.Building = picks[0][0]
	var face: Vector3 = picks[0][1]
	var out: Vector3 = picks[0][2]
	var eye := 8.0
	# Inside InteriorGroups.INTERIOR_RANGE, the near ring (60 m since
	# 2026-10-19, Docs/DestructionLod.md; 14, 50 and 92 m before).
	var ranges := [14.0, 40.0, 55.0]
	# Nothing over the picture, and the same 22 m of wall filling it from each
	# range (the lens narrowed, not the picture cropped): what changes between
	# the shots is how the interior is drawn, not how big it is.
	city.stats_label.visible = false
	if city._reticle != null:
		city._reticle.visible = false
	var fov_was := city.camera.fov
	city._promote(b.id)
	for t in 600:
		await city.get_tree().physics_frame
		if city._brick_nodes.has(b.id) and not city._bands_building(b.id):
			break
	@warning_ignore("integer_division")
	_gate_ok("building %d (%d storeys) is bricks, its bands drawn" % [b.id,
			int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR],
			b.is_materialised() and city._brick_nodes.has(b.id) and not city._bands_building(b.id))

	var layout: Array = city.interior_groups.layout(b)
	for k in ranges.size():
		if k == ranges.size() - 1:
			# Come in from outside the range: collision and shadows are kept a
			# way past where they come on (ROOM_SLEEP_RANGE, SHADOW_RELEASE),
			# and with the range at 60 m every stop is inside those from the
			# one before.
			_groups_look(face, out, InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE + 6.0, eye)
			for t in 40:
				await city.get_tree().physics_frame
		_groups_look(face, out, ranges[k], eye)
		city.camera.fov = rad_to_deg(2.0 * atan(11.0 / float(ranges[k])))
		var took: int = await _groups_settle(b)
		# Made afresh if they were let go (the last stop comes in from outside).
		layout = city.interior_groups.layout(b)
		var local: Vector3 = b.xform.affine_inverse() * city.camera.global_position
		var in_range := 0
		var shown := 0
		var kept_past := 0
		var boxes := 0
		var covered := 0
		var cover_boxes := 0
		var cover_shapes := 0
		var shadowed := 0
		for g in layout:
			var d := City._box_distance(g.box, local)
			if d <= InteriorGroups.INTERIOR_RANGE:
				in_range += 1
				if g.shown and not g.dirty and not g.changed:
					shown += 1
			elif d > InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE and g.shown:
				kept_past += 1
			if g.shown:
				boxes += g.piece_count
				if g.shadows:
					shadowed += 1
			if g.cover:
				covered += 1
				for room_boxes in g.boxes:
					for box in (room_boxes as Array):
						if (box as AABB).size != Vector3.ZERO:
							cover_boxes += 1
				cover_shapes += (city._group_shapes.get(InteriorGroups.key_of(b.id, g.index),
						PackedInt32Array()) as PackedInt32Array).size()
		print("[groups] from %.0f m: %d of %d group(s) in range and drawn after %d tick(s), %d box(es); %d with collision, %d casting shadows" % [
				ranges[k], shown, layout.size(), took, boxes, covered, shadowed])
		_gate_ok("from %.0f m: every storey group within %.0f m is drawn and up to date, none kept past it" % [
				ranges[k], InteriorGroups.INTERIOR_RANGE],
				in_range > 0 and shown == in_range and kept_past == 0,
				"%d in range, %d drawn, %d kept past" % [in_range, shown, kept_past])
		if k == 0:
			print("[groups]   %d of its %d group(s) are past the range from its foot, and not drawn" % [
					layout.size() - in_range, layout.size()])
			_gate_ok("  every interior piece of those storeys is in it once",
					boxes > 0 and boxes == _groups_expected_boxes(b, layout),
					"%d box(es), %d part(s) in the rooms' manifests" % [boxes, _groups_expected_boxes(b, layout)])
			_gate_ok("  the group at the player's height has a collision box a piece",
					covered >= 1 and cover_boxes > 0 and cover_shapes == cover_boxes,
					"%d group(s), %d piece(s), %d shape(s)" % [covered, cover_boxes, cover_shapes])
			var met := false
			var chunk_xf := city.world.get_chunk_transform(b.chunk)
			for g in layout:
				if not g.cover or met:
					continue
				for room_boxes in g.boxes:
					if (room_boxes as Array).is_empty():
						continue
					var q := PhysicsRayQueryParameters3D.create(city.camera.global_position,
							chunk_xf * (room_boxes[0] as AABB).get_center())
					q.collision_mask = Layers.FIXTURE
					var hit := city.get_world_3d().direct_space_state.intersect_ray(q)
					met = not hit.is_empty() and hit.rid == city._room_bodies.get(b.id, RID())
					break
			_gate_ok("  and something aimed at a piece meets it", met)
			_gate_ok("  near, the pieces cast shadows", shadowed >= 1)
		if k == ranges.size() - 1:
			_gate_ok("  from here it is drawn with no collision and no shadows",
					shown > 0 and covered == 0 and shadowed == 0,
					"%d drawn, %d with collision, %d casting" % [shown, covered, shadowed])
		await _frames(2)
		await _save("interior_groups_%d" % int(ranges[k]))
	city.camera.fov = fov_was

	# Out of range altogether: nothing of it is kept.
	_groups_look(face, out, InteriorGroups.INTERIOR_RANGE + InteriorGroups.RELEASE + 6.0, eye)
	for t in 40:
		await city.get_tree().physics_frame
	var left := 0
	for g in city.interior_groups.known(b.id):
		if g.shown or city.interior_groups.piece_node(b.id, g.index) != null:
			left += 1
	_gate_ok("past the range and its margin no group of it is kept", left == 0, "%d kept" % left)
	# And its windows are painted on its bricks there, as a shell's are
	# (Docs/DestructionLod.md 3.2), hidden inside the range the rooms are in.
	for t in 200:
		if city._brick_panes.has(b.id):
			break
		await city.get_tree().physics_frame
	var panes = city._brick_panes.get(b.id)
	_gate_ok("  its windows are painted on its bricks, hidden where its rooms are drawn",
			panes != null and is_instance_valid(panes) and (panes as MeshInstance3D).mesh != null
			and is_equal_approx(float((panes as GeometryInstance3D).get_instance_shader_parameter(
				"near_hide")), InteriorGroups.INTERIOR_RANGE),
			"panes %s; %d made, %.1f ms all told" % [panes != null, city.brick_panes_built, city.brick_panes_ms])
	await _save("interior_groups_panes")

	# One shot. The groups at its height are asked again; the top ones are not.
	_groups_look(face, out, ranges[0], eye)
	await _groups_settle(b)
	layout = city.interior_groups.layout(b)
	var stamps := []
	var buffers := []
	for g in layout:
		stamps.append(g.struct_stamp)
		var node := city.interior_groups.piece_node(b.id, g.index)
		buffers.append(node.get_meta(&"buffer", PackedFloat32Array()) if node != null
				else PackedFloat32Array())
	var worked0 := city.interior_groups.rooms_worked
	city._blast(face + Vector3(0.0, eye, 0.0) - out * 0.5, 2.0)
	for t in 40:
		await city.get_tree().physics_frame
	await _groups_settle(b)
	var asked := 0
	var far_same := true
	var hit_group := -1
	var hit_off := INF
	var why := ""
	var local_hit: Vector3 = b.xform.affine_inverse() * (face + Vector3(0.0, eye, 0.0))
	for g in layout:
		if g.struct_stamp != stamps[g.index]:
			asked += 1
		# The nearest by height: a shot at a slab is between two groups' storeys.
		var off := maxf(maxf(g.box.position.y - local_hit.y, local_hit.y - g.box.end.y), 0.0)
		if off < hit_off:
			hit_off = off
			hit_group = g.index
	for g in layout:
		if hit_group < 0 or g.index < hit_group + 2 or not g.shown:
			continue
		var node := city.interior_groups.piece_node(b.id, g.index)
		var now: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array()) if node != null \
				else PackedFloat32Array()
		if g.struct_stamp != stamps[g.index] or now != buffers[g.index]:
			far_same = false
			why += " group %d: stamp %d->%d, %d->%d floats;" % [g.index, stamps[g.index],
					g.struct_stamp, (buffers[g.index] as PackedFloat32Array).size(), now.size()]
	# Nothing is walked for a shot: the rooms it reached are laid as bricks and
	# drop out of their group, and what lost its floor is found the tick it
	# does (InteriorGroups.check_floors). The groups above do not change.
	_gate_ok("a shot has no storey group walk its rooms again, and leaves the ones above as they were",
			hit_group >= 0 and asked == 0 and far_same,
			"%d of %d group(s) asked again (the shot in group %d), %d room(s) worked out;%s" % [
				asked, layout.size(), hit_group, city.interior_groups.rooms_worked - worked0, why])

	# A blast at a PIECE: that piece becomes bricks and is broken as bricks
	# are. Its room is not laid, and the rest of the storey goes on being a
	# drawing (Interiors.md 8.4). A room of two pieces or more that nothing
	# has touched, in a group near enough to have its collision.
	var shot_room: Room = null
	var shot_item := -1
	var shot_group: InteriorGroups.Group = null
	var shot_offset: Vector3i = city.registry._rebase_of(b)
	for g in layout:
		if not g.cover or shot_room != null:
			continue
		for index in range(g.first_room, g.last_room):
			var r := city.registry.get_room(b.id, index)
			if r == null or r.items.size() < 2 or not r.gone.is_empty() or not r.laid.is_empty():
				continue
			if RoomManifest.item_floor_share(city.world, b.chunk, str(r.items[0].type),
					(r.items[0].cell as Vector3i) - shot_offset) > 0.5:
				shot_room = r
				shot_item = 0
				shot_group = g
				break
	if shot_room != null:
		var laid0: int = city.registry.items_laid
		var boxes0: int = shot_group.piece_count
		city._blast(b.xform * RoomManifest.item_box(shot_room.items[shot_item]).get_center(), 0.5)
		for t in 30:
			await city.get_tree().physics_frame
		await _groups_settle(b)
		_gate_ok("a blast at a piece makes that piece bricks, and no other in its room",
				city.registry.items_laid > laid0 and shot_room.laid.has(shot_item)
				and shot_room.laid.size() + shot_room.gone.size() < shot_room.items.size(),
				"%d piece(s) laid, room %d of %d piece(s): laid %s, gone %s" % [
					city.registry.items_laid - laid0, shot_room.id, shot_room.items.size(),
					shot_room.laid.keys(), shot_room.gone.keys()])
		_gate_ok("  and the rest of its storeys are still a drawing, less what the blast reached",
				shot_group.shown and not shot_group.dirty and shot_group.piece_count > 0
				and shot_group.piece_count < boxes0,
				"%d box(es) before, %d after" % [boxes0, shot_group.piece_count])
	else:
		_gate_ok("a blast at a piece makes that piece bricks, and lays no room", false,
				"no untouched room of two pieces in a group with collision")

	# A section comes off: nothing of a group stays drawn where its floor has left.
	var wb := city._world_box(b)
	@warning_ignore("integer_division")
	var cut_storey := mini(9, int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR - 3)
	# A metre up its storey: the blasts (1.3 m) stop short of the slab above.
	var cut_world := wb.position.y + float(TowerRecipe.SLAB_PLATES + cut_storey * TowerRecipe.STOREY_PLATES) * City.PLATE + 1.0
	var cut_local: float = (b.xform.affine_inverse() * Vector3(face.x, cut_world, face.z)).y
	_groups_look(face, out, 30.0, eye + 10.0)
	await _groups_settle(b)
	var above := _groups_shown_above(b, cut_local + 2.8)
	var rides0 := city._group_rides
	var orphans0 := city._group_orphans
	_groups_cut(wb, cut_world)
	var hung_ticks := 0
	var hung_worst := 0
	var riding_most := 0
	var rider_off := 0   # riders on a section that has landed, or on nothing
	for t in 240:
		await city.get_tree().physics_frame
		riding_most = maxi(riding_most, city._group_riders.size())
		if t == 50:
			await _save("interior_groups_fall")   # the sections on their way down, furniture aboard
		if t % 4 == 0:
			for rider in city._group_riders:
				var on: BrickIsland = rider[0]
				if rider[1] == null or not is_instance_valid(rider[1]) or not on.is_valid():
					continue
				# Drawn under the section's own node, and that node is where the
				# section's bricks are (a tick of travel allowed): the rows were
				# carried into the section's space on that understanding.
				if (rider[1] as Node).get_parent() != on.mesh \
						or on.mesh.global_transform.origin.distance_to(
							city.world.get_chunk_transform(on.chunk).origin) > 0.6:
					rider_off += 1
		if b.toppled or not b.is_materialised():
			break
		var hung := _groups_hanging(b, cut_local + 2.8)
		if hung > 0:
			hung_ticks += 1
			hung_worst = maxi(hung_worst, hung)
	_gate_ok("a section falls: of %d box(es) above the cut, none is left drawn over a floor that has gone" % above,
			above > 0 and hung_ticks == 0,
			"%d tick(s), up to %d box(es)" % [hung_ticks, hung_worst])
	_gate_ok("  what stood in it rides the section down, drawn on the section",
			city._group_rides > rides0 and riding_most > 0 and rider_off == 0,
			"%d piece(s) lost their floor, %d rode; up to %d section(s) carrying some; %d found off its section" % [
				city._group_orphans - orphans0, city._group_rides - rides0, riding_most, rider_off])
	# The wreckage is not empty (user, 2026-10-07: "the building just stays
	# empty"). Once its pieces are still, what stood on a floor is laid as
	# bricks on the piece that has that floor (Interiors 8.14: solid, shot as
	# bricks, there at every distance) -- and nothing is laid on one still
	# moving.
	var wreck: Dictionary = await _groups_wreck_settle(b)
	_gate_ok("the wreckage has its interior: still pieces carry what stood on their floors, as bricks",
			int(wreck.pieces) > 0 and int(wreck.boxes) > 0 and int(wreck.made_moving) == 0,
			"%d piece(s) with furniture, %d brick(s) of it; %d laid on a piece still moving; still after %d tick(s)" % [
				wreck.pieces, wreck.boxes, wreck.made_moving, wreck.ticks])
	_gate_ok("  none of it is left only drawn, and no rider is left on a piece that has its own",
			int(wreck.wrong) == 0 and int(wreck.riders) == 0,
			"%d piece(s) with furniture still to lay, %d rider(s) on a piece that has it;%s" % [
				wreck.wrong, wreck.riders, wreck.get("why", "")])
	await _save("interior_groups_wreck")

	# A blast at furniture on wreckage breaks its bricks, as any blast does.
	var target: BrickIsland = null
	var target_at := Vector3.ZERO
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	for isl in city.islands.islands:
		if not isl.is_valid() or not isl.settled or isl.owner != b.id:
			continue
		var deco: PackedInt32Array = city.world.get_decorative_blocks(isl.chunk)
		if deco.is_empty():
			continue
		@warning_ignore("integer_division")
		var ticks: Array = city.world.get_block_ticks(isl.chunk, deco[deco.size() / 2])
		if ticks.is_empty():
			continue
		var lo: Vector3 = Vector3(ticks[0] as Vector3i) * tick_m
		var size: Vector3 = Vector3(ticks[1] as Vector3i) * tick_m
		target = isl
		target_at = isl.chunk_transform() * (lo + size * 0.5)
		break
	if target != null:
		var deco0 := _wreck_furniture(b.id)
		city._blast(target_at, 0.6)
		for t in 24:
			await city.get_tree().physics_frame
		var deco1 := _wreck_furniture(b.id)
		_gate_ok("a blast at furniture on wreckage breaks its bricks",
				deco1 < deco0, "%d furniture brick(s) on the wreckage before, %d after" % [deco0, deco1])
	else:
		_gate_ok("a blast at furniture on wreckage breaks its bricks", false,
				"no furniture on a still piece to shoot")

	# A building that is coming apart when somebody arrives gets no groups
	# until it is still; then the storeys left standing get theirs.
	var b2: BuildingRegistry.Building = picks[1][0]
	var face2: Vector3 = picks[1][1]
	var out2: Vector3 = picks[1][2]
	_groups_look(face2, out2, InteriorGroups.INTERIOR_RANGE + 5.0, eye)
	city._promote(b2.id)
	for t in 600:
		await city.get_tree().physics_frame
		if city._brick_nodes.has(b2.id) and not city._bands_building(b2.id):
			break
	for t in 30:
		await city.get_tree().physics_frame
	var before_any := 0
	for g in city.interior_groups.known(b2.id):
		if g.shown:
			before_any += 1
	var wb2 := city._world_box(b2)
	@warning_ignore("integer_division")
	var storeys2: int = int(b2.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR
	@warning_ignore("integer_division")
	var cut2 := wb2.position.y + float(TowerRecipe.SLAB_PLATES + (storeys2 * 2 / 3) * TowerRecipe.STOREY_PLATES) * City.PLATE + 1.0
	_groups_cut(wb2, cut2)
	_groups_look(face2, out2, 30.0, eye)
	var mid_ticks := 0
	var made_mid := 0
	var still_at := -1
	for t in 1800:
		await city.get_tree().physics_frame
		var any := 0
		for g in city.interior_groups.known(b2.id):
			if g.shown:
				any += 1
		if city._mid_collapse(b2.id):
			mid_ticks += 1
			made_mid = maxi(made_mid, any)
		elif mid_ticks > 0:
			still_at = t
			break
	_gate_ok("building %d cut at two thirds of its height with nobody in range: no group before, none while it comes apart" % b2.id,
			before_any == 0 and mid_ticks > 0 and made_mid == 0,
			"%d before; coming apart for %d tick(s), up to %d group(s) made in them" % [
				before_any, mid_ticks, made_mid])
	var after := 0
	if still_at >= 0 and not b2.toppled and b2.is_materialised():
		await _groups_settle(b2)
		for g in city.interior_groups.known(b2.id):
			if g.shown and g.piece_count > 0:
				after += 1
	_gate_ok("  once it is still, the storeys left standing get theirs", after > 0,
			"%d group(s); still at tick %d, toppled %s" % [after, still_at, b2.toppled])

	# What is left of it goes over whole. Its furniture goes with it: the piece
	# it becomes is the same chunk, so every box it was drawing rides. (Dropped
	# with the groups, a toppling tower's rooms emptied the tick it leaned.)
	if not b2.toppled and b2.is_materialised():
		@warning_ignore("integer_division")
		var drawing: int = city.interior_groups.rows_of(b2.id).size() / FurnitureMesh.STRIDE
		var went := b2.chunk
		city._topple(b2.id)
		await city.get_tree().physics_frame
		var carried := 0
		for rider in city._group_riders:
			if (rider[0] as BrickIsland).is_valid() and (rider[0] as BrickIsland).chunk == went \
					and rider[1] != null and is_instance_valid(rider[1]):
				carried += (rider[1] as MultiMeshInstance3D).multimesh.instance_count
		_gate_ok("a tower that goes over whole takes its furniture with it",
				b2.toppled and drawing > 0 and carried == drawing
				and city.interior_groups.known(b2.id).is_empty(),
				"%d box(es) drawn before, %d riding the piece it became" % [drawing, carried])
		var wreck2: Dictionary = await _groups_wreck_settle(b2)
		_gate_ok("  and what is left of it on the ground has its interior",
				int(wreck2.pieces) > 0 and int(wreck2.boxes) > 0 and int(wreck2.wrong) == 0,
				"%d piece(s) with furniture, %d brick(s), %d with some still to lay; still after %d tick(s);%s" % [
					wreck2.pieces, wreck2.boxes, wreck2.wrong, wreck2.ticks, wreck2.get("why", "")])
	else:
		_gate_ok("a tower that goes over whole takes its furniture with it", false,
				"nothing left standing to topple")

	# Its bricks given back, a building keeps no group and none of its collision.
	city._demote(b2.id, 0.0)
	_gate_ok("a building that gives its bricks back keeps no group and none of their collision",
			city.interior_groups.known(b2.id).is_empty() and not city._room_bodies.has(b2.id),
			"%d group(s) known, furniture body %s" % [city.interior_groups.known(b2.id).size(),
				city._room_bodies.has(b2.id)])
	var gr: Dictionary = city.interior_groups.report()
	print("[groups] all told: %d room(s) worked out, %d drawing(s) put up or refreshed, %d let go, %.1f ms (the slowest drawing %.2f ms); %d time(s) collision put on or taken off" % [
			gr.rooms_worked, gr.attaches, gr.releases, gr.work_ms, gr.worst_attach_ms, city._group_covers])
	print("[groups]   floors asked %d time(s), %.2f ms all told (%.3f ms each); %d piece(s) lost theirs, %d rode a section" % [
			gr.checks, gr.check_ms, float(gr.check_ms) / maxf(float(gr.checks), 1.0),
			city._group_orphans, city._group_rides])
	print("[groups] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The physics view's check (PhysicsView, Docs/Hulls.md 11 E1).
##
##     godot --headless --path . scenes/city.tscn -- --physview
##
## A tower in bricks, blasted: the view draws its bands' boxes and the pieces
## that come off, each piece's centre of mass, and counts what is awake; off
## again, it draws nothing and the boxes are all still there.
func _run_physview_pass() -> void:
	print("[physview] what the physics sees")
	city.respawn_buildings = false
	var picks := _groups_pick(1)
	_gate_ok("a tower to blast", picks.size() == 1)
	if picks.is_empty():
		print("[physview] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1)
		return
	var b: BuildingRegistry.Building = picks[0][0]
	var face: Vector3 = picks[0][1]
	city._promote(b.id)
	for t in 600:
		await city.get_tree().physics_frame
		if city._brick_nodes.has(b.id) and not city._bands_building(b.id):
			break
	_gate_ok("its collision is built", city._brick_cols.has(b.id))
	# Wide shots, as a player's widest (_run_bigbreak_pass): enough to cut
	# pieces loose, not only a hole.
	for shot in [[0.0, 8.0], [-4.0, 10.0], [4.0, 10.0]]:
		city._blast(face + Vector3(0.0, float(shot[0]), 0.0), float(shot[1]))
		for t in 20:
			await city.get_tree().physics_frame
	for t in 30:
		await city.get_tree().physics_frame
	city._toggle_physics_view()
	var v := city._physics_view
	print("  %s" % v.hud_line())
	_gate_ok("bands drawn", v.bands > 0 and v.band_boxes > 0, "%d bands %d boxes" % [v.bands, v.band_boxes])
	_gate_ok("pieces drawn with their shapes", v.pieces > 0 and v.piece_boxes > 0,
			"%d pieces %d boxes" % [v.pieces, v.piece_boxes])
	var lines := (v.mesh as ImmediateMesh).get_surface_count()
	_gate_ok("something to see", lines == 1)
	# Long enough for a piece that will not settle to show red.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < PhysicsView.NEVER_SLEEPS_MS + 1500:
		await city.get_tree().physics_frame
	v.redraw(city._brick_cols, city.islands)
	print("  after %.1f s: %s" % [(Time.get_ticks_msec() - t0) / 1000.0, v.hud_line()])
	print("  %s" % city.dev_hud.caps_hud_line())
	var shapes0 := _physview_shapes()
	v.redraw(city._brick_cols, city.islands)
	city._toggle_physics_view()
	_gate_ok("off: nothing drawn", not v.visible)
	var shapes1 := _physview_shapes()
	_gate_ok("drawing changed no shape", shapes0 == shapes1, "%d then %d" % [shapes0, shapes1])
	print("[physview] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _run_piececost_pass() -> void:
	print("[piececost] what loose pieces cost to draw")
	city.respawn_buildings = false
	var picks := _groups_pick(6)
	if picks.is_empty():
		print("[piececost] no tower to blast")
		city.get_tree().quit(1)
		return
	var first: Vector3 = picks[0][1]
	var dir0: Vector3 = picks[0][2]
	city.camera.position = first + dir0 * 45.0 + Vector3(0, 18, 0)
	city.camera.look_at(first + Vector3(0, 10, 0))
	for pk in picks:
		var b: BuildingRegistry.Building = pk[0]
		var face: Vector3 = pk[1]
		city._promote(b.id)
		for t in 600:
			await city.get_tree().physics_frame
			if city._brick_nodes.has(b.id) and not city._bands_building(b.id):
				break
		for shot in [[0.0, 8.0], [-4.0, 10.0], [4.0, 10.0], [8.0, 9.0], [12.0, 9.0]]:
			city._blast(face + Vector3(0.0, float(shot[0]), 0.0), float(shot[1]))
			for t in 15:
				await city.get_tree().physics_frame
		var caps := city.islands.cap_counts()
		print("[piececost] after %s: %s" % [b.id, str(caps)])
		if int(caps.small) + int(caps.large) >= 90:
			break
	# Settled: the caps' work done, what lies about is what is drawn.
	for t in 240:
		await city.get_tree().physics_frame
	var vp := city.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var meshes := {}
	var shown := 0
	var tris := 0
	var bricks := 0
	var coarse_tris := 0
	var live_tris := 0
	# Each piece's coarse stand-in (what it is drawn as past ISLAND_MESH_RANGE),
	# hung beside it hidden: what the same pieces would cost as stand-ins. Test
	# only -- the read-backs and main-thread builds here are not for play.
	var stand := []
	var compact := []   ## [piece node, its mesh, the same with dead faces left out]
	for isl in city.islands.islands:
		if isl.is_valid() and isl.mesh != null and is_instance_valid(isl.mesh) and isl.mesh.mesh != null:
			shown += 1
			meshes[isl.mesh.mesh.get_rid()] = true
			var tl := _mesh_tris(isl.mesh.mesh)
			var t: int = tl[0]
			live_tris += tl[1]
			var nb := city.islands.world.get_alive_block_count(isl.chunk)
			tris += t
			bricks += nb
			var ca: Array = city.islands.world.build_chunk_coarse_mesh(isl.chunk)
			var ct := 0
			if not ca.is_empty():
				var cm := ArrayMesh.new()
				cm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ca)
				ct = _mesh_tris(cm)[0]
				# Beside the piece's node, not under it: hiding the piece hides it.
				var mi := MeshInstance3D.new()
				mi.mesh = cm
				mi.material_override = isl.mesh.material_override
				mi.visible = false
				isl.mesh.get_parent().add_child(mi)
				mi.transform = isl.mesh.transform
				stand.append(mi)
			coarse_tris += ct
			compact.append([isl.mesh, isl.mesh.mesh, _live_only(isl.mesh.mesh)])
			if tl[1] * 2 < t:
				# Mostly dead: what the bake says, and what a rebuild from it would hold.
				var ms := city.islands.world.get_mesh_stats(isl.chunk)
				var ra: Array = city.islands.world.build_chunk_mesh(isl.chunk)
				@warning_ignore("integer_division")
				var rt: int = (ra[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if not ra.is_empty() else 0
				print("[piececost]     mostly dead: stats %d drawn / %d slots, bake valid %s; a rebuild holds %d triangles" % [
						int(ms.triangles), int(ms.index_slots) / 3, str(city.islands.world.bake_ready(isl.chunk)), rt])
			if tl[1] > 50 * maxi(1, nb):
				var w := city.islands.world
				for bi in w.get_block_count(isl.chunk):
					if w.get_block_hp(isl.chunk, bi) > 0:
						var r := w.get_block_index_range(isl.chunk, bi)
						@warning_ignore("integer_division")
						print("[piececost]     block %d: archetype %d, material %d, %d triangles" % [
								bi, w.get_block_archetype(isl.chunk, bi), w.get_block_material(isl.chunk, bi), r.y / 3])
			print("[piececost]   piece %d: %d bricks, %d triangles (%d live, %.1f a brick), %d band(s), %s, %.0f m off; stand-in %d triangles" % [
					isl.chunk, nb, t, tl[1], float(tl[1]) / maxf(1.0, nb), isl.bands.size(),
					"coarse" if isl.coarse_drawn else "bricks",
					isl.mesh.global_position.distance_to(city.camera.global_position), ct])
	print("[piececost] %d settled piece(s) baked again to drop dead faces" % city.islands.compacted)
	print("[piececost] %d pieces drawn, %d distinct mesh(es), %d bricks, %d triangles (%d live, %.1f a brick); as stand-ins %d; caps %s" % [
			shown, meshes.size(), bricks, tris, live_tris, float(live_tris) / maxf(1.0, bricks), coarse_tris,
			str(city.islands.cap_counts())])
	var a := await _piececost_measure(vp, "drawn")
	_piece_meshes_visible(false)
	var h := await _piececost_measure(vp, "hidden")
	for mi in stand:
		mi.visible = true
	var s := await _piececost_measure(vp, "stand-ins")
	for mi in stand:
		mi.visible = false
	_piece_meshes_visible(true)
	for c in compact:
		(c[0] as MeshInstance3D).mesh = c[2]
	var k := await _piececost_measure(vp, "compacted")
	for c in compact:
		(c[0] as MeshInstance3D).mesh = c[1]
	var a2 := await _piececost_measure(vp, "drawn again")
	var cpu: float = (a.cpu + a2.cpu) * 0.5 - h.cpu
	var gpu: float = (a.gpu + a2.gpu) * 0.5 - h.gpu
	var calls: float = (a.calls + a2.calls) * 0.5 - h.calls
	print("[piececost] the pieces cost: render CPU %.3f ms, GPU %.3f ms, %.0f draw calls a frame (%d pieces)" % [
			cpu, gpu, calls, shown])
	print("[piececost] as stand-ins: render CPU %.3f ms, GPU %.3f ms, %.0f draw calls a frame" % [
			s.cpu - h.cpu, s.gpu - h.gpu, s.calls - h.calls])
	print("[piececost] compacted (dead faces out): render CPU %.3f ms, GPU %.3f ms, %.0f draw calls a frame" % [
			k.cpu - h.cpu, k.gpu - h.gpu, k.calls - h.calls])
	city.get_tree().quit(0)

## `m` with its patched-out faces left out of the index buffer (test only).
func _live_only(m: Mesh) -> Mesh:
	var out := ArrayMesh.new()
	for si in m.get_surface_count():
		var arr := m.surface_get_arrays(si)
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx != null:
			var ix := idx as PackedInt32Array
			var live := PackedInt32Array()
			for i in range(0, ix.size() - 2, 3):
				if ix[i] != ix[i + 1] or ix[i] != ix[i + 2]:
					live.append(ix[i])
					live.append(ix[i + 1])
					live.append(ix[i + 2])
			if live.is_empty():
				continue
			arr[Mesh.ARRAY_INDEX] = live
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return out

## A mesh's triangles, from its arrays (a read-back: test passes only): [all, live]
## -- live leaves out the ones patched out of the index buffer (all three corners
## the same vertex: a dead brick's faces, BrickWorld.update_index_region).
func _mesh_tris(m: Mesh) -> Array:
	var n := 0
	var live := 0
	for si in m.get_surface_count():
		var arr := m.surface_get_arrays(si)
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx == null:
			@warning_ignore("integer_division")
			var k := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			n += k
			live += k
			continue
		var ix := idx as PackedInt32Array
		@warning_ignore("integer_division")
		n += ix.size() / 3
		for i in range(0, ix.size() - 2, 3):
			if ix[i] != ix[i + 1] or ix[i] != ix[i + 2]:
				live += 1
	return [n, live]

func _piece_meshes_visible(on: bool) -> void:
	for isl in city.islands.islands:
		if isl.is_valid() and isl.mesh != null and is_instance_valid(isl.mesh):
			isl.mesh.visible = on

func _piececost_measure(vp: RID, what: String) -> Dictionary:
	for t in 20:
		await city.get_tree().process_frame
	var cpu := 0.0
	var gpu := 0.0
	var calls := 0.0
	var proc := 0.0
	var worst := 0.0
	for t in PIECE_FRAMES:
		await city.get_tree().process_frame
		var g := RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		gpu += g
		worst = maxf(worst, g)
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var n := float(PIECE_FRAMES)
	var out := {"cpu": cpu / n, "gpu": gpu / n, "calls": calls / n, "proc": proc / n}
	print("[piececost] %-12s render CPU %.3f ms  GPU %.3f ms (worst %.3f)  %.0f draw calls  process %.2f ms" % [
			what, out.cpu, out.gpu, worst, out.calls, out.proc])
	return out

## Every band's and every piece's shape count, summed (_run_physview_pass).
func _physview_shapes() -> int:
	var n := 0
	for id in city._brick_cols:
		n += (city._brick_cols[id] as BuildingCollision).shape_count()
	for isl in city.islands.islands:
		if isl.is_valid() and isl.body != null:
			n += PhysicsServer3D.body_get_shape_count(isl.body.get_rid())
	return n

## The view switches' gate (DebugView).
##
##     godot --path . --resolution 1280x720 scenes/city.tscn -- --view --big
##
## A tower in bricks, looked at in each view (shots/view_*.png), and the two
## halves of what the switches promise:
##
##   * a switch changes what is DRAWN -- the picture really is different, for
##     bricks cut loose after the switch as much as for those there before it;
##   * and nothing else -- the wall that is not drawn still stops a ray, the
##     desk that is not drawn still has its box, and with every switch back
##     each node is drawn exactly as it was.
func _run_view_pass() -> void:
	print("[view] what is drawn can be switched off; what is there cannot")
	city.respawn_buildings = false
	var picks := _groups_pick(1)
	_gate_ok("a tower with a face nothing stands in front of", picks.size() == 1)
	if picks.is_empty():
		print("[view] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1)
		return
	var b: BuildingRegistry.Building = picks[0][0]
	var face: Vector3 = picks[0][1]
	var out: Vector3 = picks[0][2]
	var eye := 8.0
	city._promote(b.id)
	for t in 600:
		await city.get_tree().physics_frame
		if city._brick_nodes.has(b.id) and not city._bands_building(b.id):
			break
	city.stats_label.visible = false
	if city._reticle != null:
		city._reticle.visible = false
	_groups_look(face, out, 16.0, eye)
	await _groups_settle(b)
	await _frames(4)
	var S := DebugView.Mode.SHOWN
	var C := DebugView.Mode.CLEAR
	var H := DebugView.Mode.HIDDEN

	# What every drawing in the scene is drawn with, before anything is switched.
	var before := {}
	for node in city.find_children("*", "GeometryInstance3D", true, false):
		before[node] = [(node as GeometryInstance3D).layers, (node as GeometryInstance3D).transparency]
	var shown := _view_grab()
	await _save("view_shown")

	# See-through: the bricks, not what stands in them.
	_view_set(C, S, S)
	await _frames(6)
	var tally := _view_tally(b)
	_gate_ok("structure see-through: every brick mesh of the tower is, and no interior piece",
			tally.structure > 0 and tally.structure_clear == tally.structure
			and tally.interior > 0 and tally.interior_clear == 0 and tally.structure_hidden == 0,
			str(tally))
	var clear := _view_grab()
	await _save("view_structure_clear")

	# Hidden: not drawn, and still there.
	_view_set(H, S, S)
	await _frames(6)
	tally = _view_tally(b)
	var cam := city.get_viewport().get_camera_3d()
	_gate_ok("structure hidden: every brick mesh of the tower is on the layer the camera does not draw",
			tally.structure > 0 and tally.structure_hidden == tally.structure
			and tally.interior_hidden == 0 and (cam.cull_mask & DebugView.HIDDEN_LAYER) == 0,
			str(tally))
	var hidden := _view_grab()
	await _save("view_structure_hidden")
	var d_clear := _view_differ(shown, clear)
	var d_hidden := _view_differ(shown, hidden)
	_gate_ok("  and the picture shows it: see-through and hidden are each a different picture from shown, and from each other",
			d_clear > 0.05 and d_hidden > 0.05 and _view_differ(clear, hidden) > 0.02,
			"%.0f%% of the picture changed see-through, %.0f%% hidden" % [d_clear * 100.0, d_hidden * 100.0])
	await city.get_tree().physics_frame
	var centre := city._world_box(b).get_center()
	var q := PhysicsRayQueryParameters3D.create(city.camera.global_position,
			Vector3(centre.x, city.camera.global_position.y, centre.z))
	q.collision_mask = Layers.STRUCTURE
	var wall := city.get_world_3d().direct_space_state.intersect_ray(q)
	_gate_ok("  the wall that is not drawn still stops a ray",
			not wall.is_empty() and city._brick_cols.has(b.id)
			and (city._brick_cols[b.id] as BuildingCollision).owns(wall.rid)
			and city.camera.global_position.distance_to(wall.position) < 17.0,
			"%s" % ("nothing hit" if wall.is_empty() else "%.1f m off" % city.camera.global_position.distance_to(wall.position)))

	# Bricks cut loose AFTER the switch are in the same view.
	var pieces0 := city.islands.islands.size()
	city._blast(face + Vector3(0.0, eye, 0.0) - out * 0.5, 2.6)
	for t in 45:
		await city.get_tree().physics_frame
	await _frames(4)
	var loose := 0
	var loose_drawn := 0
	for node in city.islands.find_children("*", "GeometryInstance3D", true, false):
		if DebugView.kind_of(node) != DebugView.Kind.STRUCTURE:
			continue
		loose += 1
		if (node as GeometryInstance3D).layers != DebugView.HIDDEN_LAYER:
			loose_drawn += 1
	_gate_ok("  what a blast cuts loose after the switch is hidden with the rest",
			loose > 0 and loose_drawn == 0,
			"%d drawing(s) of pieces and crumbs (%d piece(s) made), %d still drawn" % [
				loose, city.islands.islands.size() - pieces0, loose_drawn])

	# Interior pieces off, walls see-through: the rooms are empty to look at.
	_view_set(H, S, S)
	await _frames(4)
	var with_pieces := _view_grab()
	_view_set(H, H, S)
	await _frames(6)
	tally = _view_tally(b)
	var without := _view_grab()
	await _save("view_structure_and_interior_hidden")
	_gate_ok("interior pieces hidden: every drawing of them is, and the picture loses them",
			tally.interior > 0 and tally.interior_hidden == tally.interior
			and _view_differ(with_pieces, without) > 0.0005,
			"%s; %.2f%% of the picture" % [str(tally), _view_differ(with_pieces, without) * 100.0])
	await city.get_tree().physics_frame
	var met := false
	var chunk_xf := city.world.get_chunk_transform(b.chunk)
	for g in city.interior_groups.known(b.id):
		if not g.cover or met:
			continue
		for room_boxes in g.boxes:
			for box in (room_boxes as Array):
				if (box as AABB).size == Vector3.ZERO or met:
					continue
				var fq := PhysicsRayQueryParameters3D.create(city.camera.global_position,
						chunk_xf * (box as AABB).get_center())
				fq.collision_mask = Layers.FIXTURE
				var fhit := city.get_world_3d().direct_space_state.intersect_ray(fq)
				met = not fhit.is_empty() and fhit.rid == city._room_bodies.get(b.id, RID())
	_gate_ok("  the desk that is not drawn still has its box", met)
	_view_set(C, H, S)
	await _frames(6)
	await _save("view_clear_no_interior")

	# Items: the storey groups' item drawings and loot. A generated city has
	# no authored item with a DETAIL part, so there may be none to hide.
	_view_set(S, S, H)
	await _frames(6)
	var items := 0
	var items_drawn := 0
	for node in city.get_tree().get_nodes_in_group(DebugView.GROUP_ITEMS):
		items += 1
		if (node as GeometryInstance3D).layers != DebugView.HIDDEN_LAYER:
			items_drawn += 1
	_gate_ok("items hidden: every item drawing is (%d here)" % items, items_drawn == 0,
			"%d still drawn" % items_drawn)

	# Everything back: each node drawn exactly as it was.
	_view_set(S, S, S)
	await _frames(6)
	var changed := 0
	var checked := 0
	var metas := 0
	for node in before:
		if not is_instance_valid(node):
			continue
		checked += 1
		var g := node as GeometryInstance3D
		if g.layers != int(before[node][0]) or not is_equal_approx(g.transparency, float(before[node][1])):
			changed += 1
		if g.has_meta(&"view_layers") or g.has_meta(&"view_alpha"):
			metas += 1
	_gate_ok("everything shown again: each drawing is on the layer and at the transparency it had",
			checked > 0 and changed == 0 and metas == 0
			and city.get_tree().get_nodes_in_group(DebugView.GROUP_TOUCHED).is_empty()
			and (cam.cull_mask & DebugView.HIDDEN_LAYER) != 0,
			"%d checked, %d changed, %d still marked, %d still listed" % [checked, changed, metas,
				city.get_tree().get_nodes_in_group(DebugView.GROUP_TOUCHED).size()])
	print("[view] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## How the tower's drawings stand under the view switches: of its structure
## and of its interior pieces, how many, how many see-through, how many hidden.
func _view_tally(b: BuildingRegistry.Building) -> Dictionary:
	var t := {"structure": 0, "structure_clear": 0, "structure_hidden": 0,
			"interior": 0, "interior_clear": 0, "interior_hidden": 0}
	var root: Node = city._brick_nodes.get(b.id)
	if root == null:
		return t
	var nodes: Array = [root]
	nodes.append_array(root.find_children("*", "GeometryInstance3D", true, false))
	for node in nodes:
		var g := node as GeometryInstance3D
		var kind := DebugView.kind_of(g)
		if kind == DebugView.Kind.ITEMS:
			continue
		var key := "structure" if kind == DebugView.Kind.STRUCTURE else "interior"
		t[key] += 1
		if g.layers == DebugView.HIDDEN_LAYER:
			t[key + "_hidden"] += 1
		if is_equal_approx(g.transparency, DebugView.CLEAR):
			t[key + "_clear"] += 1
	return t

func _view_grab() -> Image:
	return city.get_viewport().get_texture().get_image()

## The share of two pictures' pixels (every fourth, each way) that differ.
func _view_differ(a: Image, b: Image) -> float:
	var size := a.get_size()
	var n := 0
	var differ := 0
	for y in range(0, size.y, 4):
		for x in range(0, size.x, 4):
			n += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.06:
				differ += 1
	return float(differ) / maxf(float(n), 1.0)

## Up to `n` recipe towers of eight storeys or more, tallest first, each with a
## face no other building stands within 100 m in front of:
## [building, the foot of that face, which way it looks].
func _groups_pick(n: int) -> Array:
	var cands: Array = []
	for c in city.registry.buildings:
		if c.is_build() or int(c.recipe.courses) < 8 * TowerRecipe.COURSES_PER_FLOOR:
			continue
		cands.append(c)
	cands.sort_custom(func(a, c) -> bool: return int(a.recipe.courses) > int(c.recipe.courses))
	var found: Array = []
	for c in cands:
		var box := city._world_box(c)
		for dir: Vector3 in [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0)]:
			var along_z: bool = dir.z != 0.0
			var foot: Vector3 = box.get_center() + dir * (box.size.z if along_z else box.size.x) * 0.5
			foot.y = box.position.y
			# As wide as the face and a little over, from just clear of it.
			var across := Vector3(box.size.x * 0.5 + 0.5, 0.0, 0.0) if along_z \
					else Vector3(0.0, 0.0, box.size.z * 0.5 + 0.5)
			var a: Vector3 = foot + dir * 1.0 - across
			var e: Vector3 = foot + dir * 100.0 + across
			var corridor := AABB(Vector3(minf(a.x, e.x), foot.y, minf(a.z, e.z)),
					Vector3(absf(e.x - a.x), 40.0, absf(e.z - a.z)))
			var clear := true
			for o in city.registry.buildings:
				if o.id != c.id and city._world_box(o).intersects(corridor):
					clear = false
					break
			if clear:
				found.append([c, foot, dir])
				break
		if found.size() >= n:
			break
	return found

## Wait for a building's pieces to come to rest and their furniture to be
## laid, then say what the wreckage carries: {pieces with furniture bricks,
## those bricks, pieces where an item still stands on its floor unlaid (asked
## of the piece's own chunk afresh), riders left on a piece whose furniture is
## laid, records first made on a piece that was not still, ticks waited}.
func _groups_wreck_settle(b: BuildingRegistry.Building) -> Dictionary:
	var out := {"pieces": 0, "boxes": 0, "wrong": 0, "riders": 0, "made_moving": 0, "ticks": 0}
	var seen := {}
	var quiet := 0
	for t in 2400:
		await city.get_tree().physics_frame
		out.ticks = t
		for chunk in city.interior_groups.piece_chunks():
			if seen.has(chunk):
				continue
			seen[chunk] = true
			var at := city.islands.find_by_chunk(int(chunk))
			if at != null and not at.settled:
				out.made_moving += 1
		quiet = quiet + 1 if (t > 90 and city.islands.moving_of(b.id) == 0 and city._pieces_owed == 0) else 0
		# Long enough for every piece's bricks to have been counted again
		# (_stream_pieces: every eighth pass, a pass every fourth tick).
		if quiet >= 48:
			break
	var rooms := city.registry.rooms_of(b.id)
	var offset: Vector3i = city.registry._rebase_of(b)
	for chunk in city.interior_groups.piece_chunks():
		var p: InteriorGroups.PieceDraw = city.interior_groups.piece(int(chunk))
		if p == null or p.owner != b.id or not p.shown:
			continue
		for rider in city._group_riders:
			if (rider[0] as BrickIsland).is_valid() and (rider[0] as BrickIsland).chunk == int(chunk):
				out.riders += 1
		var deco := city.world.get_decorative_blocks(int(chunk)).size()
		if deco > 0:
			out.pieces += 1
			out.boxes += deco
		# Asked afresh, of every room of the building and not only the ones
		# its box was thought to reach: nothing standing here is left unlaid.
		var left := 0
		for room in rooms:
			if room.items.is_empty():
				continue
			@warning_ignore("integer_division")
			left += (RoomManifest.draw_items(city.world, int(chunk), city.registry.palette, room,
					offset).buffer as PackedFloat32Array).size() / FurnitureMesh.STRIDE
		if left > 0:
			out.wrong += 1
			var isl := city.islands.find_by_chunk(int(chunk))
			out["why"] = "%s piece %d: %d box(es) still to lay; %d room(s) tried; settled %s, %d brick(s)" % [
					out.get("why", ""), int(chunk), left, p.rooms.size(),
					isl.settled if isl != null else false, city.world.get_alive_block_count(int(chunk))]
	return out

## Furniture bricks on a building's wreckage, all its pieces together.
func _wreck_furniture(id: int) -> int:
	var n := 0
	for isl in city.islands.islands:
		if isl.is_valid() and isl.owner == id:
			n += city.world.get_decorative_blocks(isl.chunk).size()
	return n

## Stand `dist` out from the foot of a face, `eye` up it, looking at it.
func _groups_look(foot: Vector3, dir: Vector3, dist: float, eye: float) -> void:
	city.camera.global_position = foot + dir * dist + Vector3(0.0, eye, 0.0)
	city.camera.look_at(foot + Vector3(0.0, eye, 0.0), Vector3.UP)

## Wait until every group of `b` in range is drawn and up to date, and the
## passes have had time to hand out collision. Returns the ticks it took.
func _groups_settle(b: BuildingRegistry.Building) -> int:
	var quiet := 0
	for t in 600:
		await city.get_tree().physics_frame
		var local: Vector3 = b.xform.affine_inverse() * city.camera.global_position
		var owed := 0
		for g in city.interior_groups.layout(b):
			if City._box_distance(g.box, local) <= InteriorGroups.INTERIOR_RANGE \
					and (not g.shown or g.dirty or g.changed):
				owed += 1
		quiet = quiet + 1 if owed == 0 else 0
		if quiet >= 12:
			return t - 11
	return 600

## The interior parts the manifests of `b`'s shown groups hold: what their
## drawings should add up to.
func _groups_expected_boxes(b: BuildingRegistry.Building, layout: Array) -> int:
	var rooms := city.registry.rooms_of(b.id)
	var n := 0
	for g in layout:
		if not g.shown:
			continue
		for index in range(g.first_room, g.last_room):
			var room: Room = rooms[index]
			for i in room.items.size():
				if room.gone.has(i):
					continue
				for part in RoomManifest.parts_of(str((room.items[i] as Dictionary).type)):
					if city.registry.palette.has(part[0]) and not RoomManifest.is_detail(part):
						n += 1
	return n

## Blast a building through, wall to wall, at one height: what is above comes off.
func _groups_cut(wb: AABB, cut_world: float) -> void:
	var x := wb.position.x + 0.6
	while x < wb.end.x:
		var z := wb.position.z + 0.6
		while z < wb.end.z:
			city._blast(Vector3(x, cut_world, z), 1.3)
			z += 2.0
		x += 2.0

## Boxes of `b`'s group drawings still shown above a height (its own space).
func _groups_shown_above(b: BuildingRegistry.Building, y: float) -> int:
	var n := 0
	for g in city.interior_groups.known(b.id):
		var node := city.interior_groups.piece_node(b.id, g.index)
		if node == null:
			continue
		var buffer: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array())
		@warning_ignore("integer_division")
		for i in buffer.size() / FurnitureMesh.STRIDE:
			var at := i * FurnitureMesh.STRIDE
			if buffer[at + 7] > y and absf(buffer[at]) + absf(buffer[at + 5]) + absf(buffer[at + 10]) > 0.0001:
				n += 1
	return n

## What a group draws above `y` that its rooms, asked now, would not draw:
## furniture left on screen over a floor that has gone. Asked of the rule
## itself (RoomManifest.draw_items: an item stands while most of its floor is
## there, Interiors.md 8.10), not of each part's own footing -- a bed with nine
## tenths of its floor under it stands, the part of it over the hole with it,
## and counting that part was what failed this check every run with
## --programs, whose beds are wide (2026-10-14: 1-2 parts of 7 over a hole,
## floor share 0.88-0.97, from the tick of the cut).
func _groups_hanging(b: BuildingRegistry.Building, y: float) -> int:
	var offset: Vector3i = city.registry._rebase_of(b)
	var n := 0
	for g in city.interior_groups.known(b.id):
		var node := city.interior_groups.piece_node(b.id, g.index)
		if node == null:
			continue
		var buffer: PackedFloat32Array = node.get_meta(&"buffer", PackedFloat32Array())
		var fresh := {}
		for index in range(g.first_room, g.last_room):
			var room := city.registry.get_room(b.id, index)
			if room == null or room.items.is_empty():
				continue
			var rows: PackedFloat32Array = RoomManifest.draw_items(city.world, b.chunk,
					city.registry.palette, room, offset).buffer
			for r in range(0, rows.size(), 16):
				fresh[Vector3(rows[r + 3], rows[r + 7], rows[r + 11]).snapped(Vector3.ONE * 0.01)] = true
		@warning_ignore("integer_division")
		for i in buffer.size() / FurnitureMesh.STRIDE:
			var at := i * FurnitureMesh.STRIDE
			if buffer[at + 7] <= y or absf(buffer[at]) + absf(buffer[at + 5]) + absf(buffer[at + 10]) <= 0.0001:
				continue
			if not fresh.has(Vector3(buffer[at + 3], buffer[at + 7], buffer[at + 11]).snapped(Vector3.ONE * 0.01)):
				n += 1
	return n

## [triangles drawn, of them with no live brick behind, what was there].
func _drawn_stale(b: BuildingRegistry.Building) -> Array:
	var node: MeshInstance3D = city._brick_nodes.get(b.id)
	if node == null:
		return [0, 0, {}]
	var inv := city.world.get_chunk_transform(b.chunk).affine_inverse()
	var cs := BrickWorld.get_cell_size()
	var origin: Vector3i = city.world.get_chunk_origin(b.chunk)
	var meshes: Array = [node]
	for k in node.get_children():
		if k is MeshInstance3D:
			meshes.append(k)
	var tris := 0
	var stale := 0
	var kinds := {}
	for m in meshes:
		var mesh: Mesh = (m as MeshInstance3D).mesh
		if mesh == null:
			continue
		var xf: Transform3D = inv * (m as MeshInstance3D).global_transform
		for si in mesh.get_surface_count():
			var arr: Array = mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				var a := idx[t]
				var bb := idx[t + 1]
				var c := idx[t + 2]
				if a == bb or bb == c or a == c:
					continue
				tris += 1
				var centre: Vector3 = xf * ((v[a] + v[bb] + v[c]) / 3.0)
				var inside: Vector3 = centre - (xf.basis * nrm[a]).normalized() * 0.02
				var cell := origin + Vector3i(floori(inside.x / cs.x), floori(inside.y / cs.y),
						floori(inside.z / cs.z))
				if city.world.is_solid(b.chunk, cell):
					continue
				stale += 1
				var bid := city.world.block_at(b.chunk, cell)
				var what := "no block" if bid < 0 else \
						city.world.get_archetype_name(city.world.get_block_archetype(b.chunk, bid)).get_slice("#", 0)
				kinds[what] = int(kinds.get(what, 0)) + 1
	return [tris, stale, kinds]

func _run_jam_pass() -> void:
	print("[jam] a collapse comes down, and nothing hangs in mid-air")
	var picks: Array = []
	for b in city.registry.buildings:
		if b.is_build() or b.toppled or b.recipe.courses < 12:
			continue
		for f in b.fixtures:
			if f.kind == "staircase":
				picks.append(b)
				break
		if picks.size() >= 3:
			break
	_gate_ok("three towers with stairs to bring down", picks.size() == 3, "%d" % picks.size())
	for b in picks:
		city._promote(b.id)
		_jam_look(b, 30.0, 15.0)
		await _frames(40)
	var stuck := {}
	var reported := {}
	var on := {}
	var thrown := 0
	var worst_up := 0.0
	var spawned0: int = city.islands.islands.size()
	var t_quiet := -1
	var blasts := 0
	for b in picks:
		var fx: float = b.recipe.footprint_x * City.STUD
		var fz: float = b.recipe.footprint_z * City.STUD
		var y: float = 1.2 + TowerRecipe.STOREY_PLATES * City.PLATE
		var x := 0.0
		while x <= fx + 0.01:
			var z := 0.0
			while z <= fz + 0.01:
				city._blast(b.xform * Vector3(x, y, z), 2.0)
				blasts += 1
				z += 2.5
			x += 2.5
	var blasted_at := Engine.get_physics_frames()
	var b0: BuildingRegistry.Building = picks[0]
	_jam_look(b0, 35.0, 20.0)
	var prev_vy := {}
	for t in 600:
		await city.get_tree().physics_frame
		var by_body := {}
		var moving := 0
		for isl in city.islands.islands:
			if isl.is_valid():
				by_body[isl.body.get_rid()] = isl
		for isl in city.islands.islands:
			if not isl.is_valid() or isl.settled:
				continue
			moving += 1
			var v: Vector3 = isl.body.linear_velocity
			if v.y > JAM_THROWN and float(prev_vy.get(isl, 0.0)) <= JAM_THROWN:
				thrown += 1
			if v.y > 5.0 and v.y > worst_up:
				print("[jam]   up %.1f m/s (%.1f a tick ago): %d bricks, %s, age %d ms, at y %.1f, %d contact(s)%s" % [
						v.y, float(prev_vy.get(isl, 0.0)), city.world.get_alive_block_count(isl.chunk),
						"landed" if isl.landed else "in the air", Time.get_ticks_msec() - isl.born_ms,
						isl.body.global_position.y, isl.body.get_contact_count(), _jam_others(isl, by_body)])
			worst_up = maxf(worst_up, v.y)
			prev_vy[isl] = v.y
			if t % 10 != 0:
				continue
			if v.length() < JAM_SLOW and Time.get_ticks_msec() - isl.born_ms > 1500:
				stuck[isl] = int(stuck.get(isl, 0)) + 10
			else:
				stuck[isl] = 0
			if int(stuck.get(isl, 0)) >= 60 and not reported.has(isl):
				reported[isl] = true
				var kinds := _jam_touching(isl, by_body)
				for k in kinds:
					on[k] = int(on.get(k, 0)) + 1
				print("[jam]   stuck: %d bricks, %s, %s, on %s; %s, %.2f m/s, spin %.2f, tries %d, at y %.1f%s" % [
						city.world.get_alive_block_count(isl.chunk),
						"landmark" if isl.landmark else "debris",
						"rubble" if isl.disposable else "falling", kinds,
						"landed" if isl.landed else "in the air", v.length(),
						isl.body.angular_velocity.length(), isl.unsupported_tries,
						isl.body.global_position.y, _jam_others(isl, by_body)])
		if moving == 0 and t_quiet < 0 and t > 60:
			t_quiet = Engine.get_physics_frames() - blasted_at
	var r := city.islands.report()
	print("[jam]   %d blasts; %d pieces came loose; stuck %d, by what they touch %s; thrown %d (fastest up %.1f m/s); all still after %s tick(s); settled by rule %d (jittering %d), by age %d; landed %d; perched and tipped %d" % [
			blasts, city.islands.islands.size() - spawned0, reported.size(), on, thrown, worst_up,
			str(t_quiet) if t_quiet >= 0 else "never", int(r.settled_by_rule),
			int(r.get("settled_jittering", 0)), int(r.settled_by_age), int(r.get("landings_noted", 0)), city.islands.perched_tipped])
	print("[jam]   crumbs: %d piece(s), %d brick(s) drawn, %d not (CRUMBS_MAX); worst crumb tick %.2f ms, worst crumble %.2f ms; small bodies %d; rises capped %d" % [
			int(r.crumbled), int(r.crumb_bricks), int(r.crumbs_over), float(r.crumb_worst_ms),
			float(r.crumble_worst_ms), int(city.islands.spawn_census.small[0]), int(r.rises_capped)])
	for line in city.islands.body_census_lines():
		print("[jam]   bodies " + line)
	_gate_ok("no piece hangs on another that is still falling",
			int(on.get("falling piece", 0)) == 0, "%d" % int(on.get("falling piece", 0)))
	_gate_ok("and hardly any hang at all", reported.size() <= 3, "%d stuck" % reported.size())
	_gate_ok("and none is thrown out of another", thrown == 0,
			"%d thrown, fastest up %.1f m/s" % [thrown, worst_up])
	print("[jam] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _jam_look(b: BuildingRegistry.Building, dist: float, height: float) -> void:
	var fx: float = b.recipe.footprint_x * City.STUD
	var fz: float = b.recipe.footprint_z * City.STUD
	var centre: Vector3 = b.xform * Vector3(fx * 0.5, 0.0, fz * 0.5)
	city.camera.global_position = centre + (b.xform.basis * Vector3(0.0, 0.0, -1.0)).normalized() \
			* (fz * 0.5 + dist) + Vector3(0.0, height, 0.0)
	city.camera.look_at(centre + Vector3(0.0, 8.0, 0.0), Vector3.UP)

func _jam_others(isl: BrickIsland, by_body: Dictionary) -> String:
	var out := ""
	var st := PhysicsServer3D.body_get_direct_state(isl.body.get_rid())
	for i in (st.get_contact_count() if st != null else 0):
		var rid: RID = st.get_contact_collider(i)
		var n := st.get_contact_local_normal(i)
		var what := "?"
		if by_body.has(rid):
			var o: BrickIsland = by_body[rid]
			what = "piece %d br %s %.2f m/s" % [city.world.get_alive_block_count(o.chunk),
					"settled" if o.settled else ("landed" if o.landed else "air"),
					o.body.linear_velocity.length()]
		elif city._building_for_body(rid) >= 0:
			what = "building"
		else:
			what = "ground"
		out += "\n[jam]       n (%.2f %.2f %.2f) %s" % [n.x, n.y, n.z, what]
	return out

## What a stuck piece's contacts are: standing structure, the ground, settled
## wreckage, or pieces still falling.
func _jam_touching(isl: BrickIsland, by_body: Dictionary) -> Array:
	var kinds := {}
	for ct in city.islands._contact_points(isl):
		var rid: RID = (ct as Dictionary).collider
		var kind := "ground/other"
		if city._building_for_body(rid) >= 0:
			kind = "structure"
		elif by_body.has(rid):
			var o: BrickIsland = by_body[rid]
			# Not asleep yet is not falling. A piece that is down and slower than
			# "stuck" itself (JAM_SLOW) is settling, and resting on it is not
			# hanging on anything: the two runs in about six that failed "no
			# piece hangs on another that is still falling" were a 268-brick
			# piece on a 547-brick one at 0.00 m/s, and a 12-brick one wedged
			# against a 121-brick one sliding at 0.52 (2026-10-08, -14).
			if o.settled:
				kind = "settled piece"
			elif not o.landed or o.body.linear_velocity.length() >= JAM_SLOW:
				kind = "falling piece"
			else:
				kind = "piece settling"
		kinds[kind] = true
	return kinds.keys()

## The gate for the player (Docs/AIPlan.md P1): a Pawn driven by PlayerController
## lands, walks, steps a kerb and not a wall, ducks a beam from a brick floor --
## the debug walker's rules, now on the physics tick -- and shoots a wall from its
## own eye, through the authority, without shooting itself.
## The first-person arms (ViewArms, PlayerView): the hands on the gun, a swap that
## takes the gun out of view and changes it there, the walk and the run, a reload's
## pinch hand, and a hard landing that slams the muzzle down. Pictures in
## shots/arms_*.png.
## `-- --asset-gun=<id>`: a gun made in the asset workshop, in the player's hands. It is
## held (both hands on it), fired, and reloaded with its magazine coming off in the left
## hand and going back; pictures asset_gun_*.png. Docs/AssetWorkshop.md, "Into the game".
func _run_asset_gun_pass() -> void:
	print("[asset gun] %s in the hands" % city._asset_gun)
	city._player.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	city.camera.global_position = open + Vector3(0.0, 6.0, 0.0)
	city.camera.rotation = Vector3.ZERO
	city._enter_pawn(open + Vector3(0.0, 4.0, 0.0))
	await _frames(90)
	city.camera.rotation = Vector3(-0.08, PI * 0.75, 0.0)
	var gi := city._equip_asset_gun(city._asset_gun, 7)
	_gate_ok("the asset gun is made", gi != null)
	if gi == null:
		_finish_asset_gun_pass()
		return
	await _frames(60)
	var arms := city._view.arms
	print("[asset gun] holding %s (%s): %s" % [gi.gun_name, gi.weapon_class.id, gi.describe().replace("\n", " | ")])
	_gate_ok("it is the one in hand, its own parts", city._gun.gun == gi
			and String((gi.recipe[GunPartDef.Slot.BODY] as GunPartDef).id).begins_with("asset_"))
	_gate_ok("both hands reach it", arms.reach_gap[0] < 0.005 and arms.reach_gap[1] < 0.005,
			"short by %.3f / %.3f m" % [arms.reach_gap[0], arms.reach_gap[1]])
	await _save("asset_gun_idle")
	# Fire a burst.
	city._gun.set_trigger(true)
	await _frames(8)
	await _save("asset_gun_fire")
	await _frames(20)
	city._gun.set_trigger(false)
	await _frames(20)
	# Reload: the magazine comes off in the left hand and goes back.
	var mag: Node3D = null
	for n in gi.find_children("*", "Node3D", true, false):
		if n.is_in_group(GunAssembler.PART_GROUP) and n.get_meta(&"part_slot", -1) == GunPartDef.Slot.MAGAZINE:
			mag = n
	var home := gi.to_local(mag.global_position) if mag != null else Vector3.ZERO
	var furthest := 0.0
	var shot := false
	city._gun.ammo = 0
	city._gun.reload()
	for i in 400:
		await _frames(1)
		if not city._gun.is_reloading():
			break
		if mag != null:
			furthest = maxf(furthest, gi.to_local(mag.global_position).distance_to(home) * gi.scale.x)
		if not shot and city._gun.reload_progress() > 0.5:
			shot = true
			await _save("asset_gun_mag_out")
	await _frames(20)
	_gate_ok("reloading, its magazine comes off with the hand", mag != null and furthest > 0.05,
			"%.3f m at most" % furthest)
	_gate_ok("and is back home after", mag != null
			and gi.to_local(mag.global_position).distance_to(home) < 0.001)
	await _save("asset_gun_reloaded")
	_finish_asset_gun_pass()

func _finish_asset_gun_pass() -> void:
	print("[asset gun] gate: %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _run_arms_pass() -> void:
	print("[arms] the arms and hands in first person")
	city._player.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	city.camera.global_position = open + Vector3(0.0, 6.0, 0.0)
	city.camera.rotation = Vector3.ZERO
	city._enter_pawn(open + Vector3(0.0, 4.0, 0.0))
	await _frames(90)
	var pawn := city._player_pawn
	var arms := city._view.arms
	city.camera.rotation = Vector3(-0.08, PI * 0.75, 0.0)
	await _frames(40)
	_gate_ok("the arms hang on the camera, on Mixamo's bones", arms != null
			and arms.skeleton.find_bone("mixamorig_RightForeArm") >= 0
			and arms.skeleton.find_bone("mixamorig_LeftHand") >= 0)
	_gate_ok("both hands reach the gun", arms.reach_gap[0] < 0.005 and arms.reach_gap[1] < 0.005,
			"short by %.3f / %.3f m" % [arms.reach_gap[0], arms.reach_gap[1]])
	_gate_ok("in C hands", arms.shown_hand(ViewArms.RIGHT) == ViewArms.Hand.C
			and arms.shown_hand(ViewArms.LEFT) == ViewArms.Hand.C)
	print("[arms] holding %s (%s)" % [city._gun.gun.gun_name, city._gun.gun.weapon_class.id])
	await _save("arms_idle")

	# A swap: the gun goes down out of view, the new one comes up.
	var first := city._gun.gun
	var bottoms := city._view.swaps_done
	var deepest := 0.0
	var hidden_at_bottom := true
	var early := false
	var fired_down := false
	var shot := false
	_key(KEY_TAB, true)
	await _frames(2)
	_key(KEY_TAB, false)
	var t := 0
	while t < 90:
		await _frames(1)
		t += 1
		var sw := city._view.swap_amount()
		deepest = maxf(deepest, sw)
		if sw > 0.3 and city._view.can_fire():
			fired_down = true
		var shown := city._gun.gun != first and city._gun.gun.visible
		if shown and sw < 0.95 and deepest < 0.95:
			early = true
		if sw >= 0.95 and _arms_gun_in_view(first) or sw >= 0.95 and _arms_gun_in_view(city._gun.gun):
			hidden_at_bottom = false
		if not shot and sw > 0.5 and deepest < 1.0:
			shot = true
			await _save("arms_swap_down")
		if city._view.swaps_done > bottoms and sw <= 0.0:
			break
	_gate_ok("Tab swaps the gun", city._gun.gun != first and city._gun.gun.get_parent() == city._view.rig)
	_gate_ok("the old one went all the way down, out of view",
			city._view.swaps_done == bottoms + 1 and hidden_at_bottom, "deepest %.2f" % deepest)
	_gate_ok("the new one shows only at the bottom", not early)
	_gate_ok("no firing while it is down", not fired_down)
	_gate_ok("and it is back up inside half a second", city._view.swap_amount() <= 0.0 and t < 40,
			"%d frames" % t)
	_gate_ok("the old one went to the holster", first.get_parent() != city._view.rig)
	print("[arms] now holding %s (%s)" % [city._gun.gun.gun_name, city._gun.gun.weapon_class.id])
	await _frames(10)
	await _save("arms_swapped")

	# Walk, then run: at a run the left hand comes off, open.
	_key(KEY_W, true)
	await _frames(50)
	await _save("arms_walk")
	_key(KEY_SHIFT, true)
	var left_open := false
	for i in 120:
		await _frames(1)
		left_open = left_open or arms.shown_hand(ViewArms.LEFT) == ViewArms.Hand.OPEN
	await _save("arms_sprint")
	_key(KEY_SHIFT, false)
	_key(KEY_W, false)
	_gate_ok("at a run the left hand comes off the gun, open", left_open)
	await _frames(60)
	_gate_ok("and goes back on it as a C", arms.shown_hand(ViewArms.LEFT) == ViewArms.Hand.C
			and arms.reach_gap[1] < 0.005)

	# A reload: the left hand fetches the magazine in a pinch.
	city._gun.ammo = 0
	city._gun.reload()
	var pinched := false
	shot = false
	for i in 300:
		await _frames(1)
		if not city._gun.is_reloading():
			break
		pinched = pinched or arms.shown_hand(ViewArms.LEFT) == ViewArms.Hand.PINCH
		if not shot and city._gun.reload_progress() > 0.36:
			shot = true
			await _save("arms_reload")
	await _frames(30)
	_gate_ok("a reload takes the magazine in a pinch hand", pinched)
	_gate_ok("and the C goes back on the gun", arms.shown_hand(ViewArms.LEFT) == ViewArms.Hand.C)

	# A grenade: the left hand goes out of view, comes back with it, cocks and throws.
	var g0 := city._arsenal.grenades
	var count := func() -> int:
		var n := 0
		for c in city.get_children():
			if c is Grenade:
				n += 1
		return n
	var in_world: int = count.call()
	var fetched_unseen := true
	var was_shown := false
	var let_go_at := -1.0
	var from_hand := INF
	var shots_taken := {}
	_key(KEY_G, true)
	await _frames(2)
	_key(KEY_G, false)
	for i in 90:
		await _frames(1)
		var shown := city._view._grenade_in_hand.visible
		if shown and not was_shown and arms._in_view(ViewArms.LEFT):
			fetched_unseen = false
		was_shown = shown
		var p := city._view._throw
		if let_go_at < 0.0 and count.call() > in_world:
			let_go_at = p
			for c in city.get_children():
				if c is Grenade:
					from_hand = minf(from_hand, (c as Grenade).from.distance_to(
							arms.global_transform * arms.hole(ViewArms.LEFT)))
		if p > 0.42 and not shots_taken.has("cock"):
			shots_taken["cock"] = true
			await _save("arms_grenade_cock")
		if p > 0.6 and not shots_taken.has("throw"):
			shots_taken["throw"] = true
			await _save("arms_grenade_throw")
		if not city._view.is_throwing():
			break
	_gate_ok("G throws a grenade from the left hand", city._arsenal.grenades == g0 - 1
			and let_go_at > 0.45 and from_hand < 0.25,
			"%d -> %d grenades, let go at %.2f, %.2f m from the hand" % [g0, city._arsenal.grenades,
			let_go_at, from_hand])
	_gate_ok("the hand fetched it out of view", fetched_unseen)
	await _frames(20)
	_gate_ok("and goes back on the gun as a C", arms.shown_hand(ViewArms.LEFT) == ViewArms.Hand.C
			and arms.reach_gap[1] < 0.005 and not city._view._grenade_in_hand.visible)

	# A grapple: the left hand out toward a wall ahead, the line from its C.
	var ahead := -city.camera.global_transform.basis.z
	ahead = Vector3(ahead.x, 0.0, ahead.z).normalized()
	var wall := _test_block(pawn.feet() + ahead * 14.0 + Vector3.UP * 4.0, Vector3(8.0, 8.0, 1.0))
	wall.look_at(wall.global_position + ahead, Vector3.UP)
	await _frames(4)
	city.camera.rotation.x = 0.12
	await _frames(2)
	_key(KEY_Q, true)
	var hooked := false
	var rope_full := false
	for i in 14:
		await _frames(1)
		hooked = hooked or pawn.moves.is_grappling()
		rope_full = rope_full or city._view.rope_amount() >= 1.0
	await _save("arms_grapple")
	var hand_out := arms.hole(ViewArms.LEFT).z < -0.4
	_gate_ok("Q grapples, the left hand held out", hooked and hand_out,
			"hooked %s, hand at %v" % [hooked, arms.hole(ViewArms.LEFT)])
	_gate_ok("and the line runs from the hand to the hook", rope_full and arms._rope.visible)
	_key(KEY_Q, false)
	for i in 30:
		await _frames(1)
	_gate_ok("let go, the line comes back in", not arms._rope.visible)
	wall.queue_free()
	await _frames(60)
	city.camera.rotation.x = -0.08

	# A long fall: the muzzle slams down on landing.
	pawn.place(pawn.feet() + Vector3(0.0, 9.0, 0.0))
	await _frames(4)
	var lowest := 0.0
	var landed_at := -1
	shot = false
	for i in 240:
		await _frames(1)
		lowest = minf(lowest, city._view.landing_pitch())
		if landed_at < 0 and pawn.is_on_floor():
			landed_at = i
		if landed_at < 0 and i == 30:
			await _save("arms_fall")
		if landed_at >= 0 and not shot and i >= landed_at + 5:
			shot = true
			await _save("arms_land")
		if landed_at >= 0 and i > landed_at + 40:
			break
	_gate_ok("a 9 m fall lands", landed_at >= 0, "fell %.1f m" % pawn.last_fall)
	_gate_ok("and slams the muzzle down", lowest < -0.15, "%.2f rad" % lowest)
	_gate_ok("and it settles", absf(city._view.landing_pitch()) < 0.03,
			"%.3f rad" % city._view.landing_pitch())
	# A long gun: slot 3.
	_key(KEY_3, true)
	await _frames(2)
	_key(KEY_3, false)
	await _frames(50)
	print("[arms] slot 3: %s (%s)" % [city._gun.gun.gun_name, city._gun.gun.weapon_class.id])
	_gate_ok("a long gun is held in both hands", arms.reach_gap[0] < 0.005
			and arms.reach_gap[1] < 0.005, "short by %.3f / %.3f m" % [arms.reach_gap[0],
			arms.reach_gap[1]])
	await _save("arms_long")

	# The kinds (COMBAT_DESIGN 7.8): a magnum in the hands.
	var magnum := GunInstance.from_result(GunGenerator.generate(city._gun_library, 41,
			WeaponClass.builtin(&"pistol").with_kind(&"heavy"), 1))
	city._arsenal.replace_in_hand(magnum)
	await _frames(40)
	@warning_ignore("integer_division")
	_gate_ok("a magnum is held", city._gun.gun == magnum and arms.reach_gap[0] < 0.005
			and city._gun.mag_size() == int(magnum.stats[&"mag_size"]) / 2,
			"%d shots of %d rounds" % [city._gun.mag_size(), int(magnum.stats[&"mag_size"])])
	await _save("arms_magnum")

	# Hit reactions (HitReaction): the light (auto) shotgun's wide pellets stumble a
	# soldier only at arm's length, and from a few steps he only flinches; the heavy
	# one's tight pattern throws him from 8 m.
	var fwd := -city.camera.global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	var yaw := city.camera.rotation.y
	for leg in [[&"light", 1.5, true], [&"light", 6.0, false], [&"heavy", 8.0, true]]:
		var sg := GunInstance.from_result(GunGenerator.generate(city._gun_library, 77,
				WeaponClass.builtin(&"shotgun").with_kind(leg[0]), 1))
		city._arsenal.replace_in_hand(sg)
		sg.stats[&"accuracy"] = 1.0
		await _frames(30)
		var dist: float = leg[1]
		var target := Pawn.spawn(city, pawn.feet() + fwd * dist, 1, true, 100000.0)
		Soldier._greybox(target, 1)
		await _frames(20)
		city.camera.look_at(target.chest(), Vector3.UP)
		await _frames(2)
		var at := target.feet()
		city._gun.call(&"_fire_one")
		var held := target.stagger_left
		var r := target.body.get_node_or_null(^"HitReaction") as HitReaction
		var tipped := 0.0
		for i in 12:
			await _frames(1)
			if r != null:
				tipped = maxf(tipped, r.lean_angle())
			if bool(leg[2]) and i == 5:
				await _save("arms_hit_%s" % leg[0])
		await _frames(30)
		var back := (target.feet() - at).dot(fwd)
		var what := "a %s shotgun at %.0f m" % [leg[0], dist]
		if bool(leg[2]):
			# A light gun's stumble is a lighter one (HitReaction.ARCHETYPE).
			_gate_ok("%s stumbles a soldier" % what, held > 0.2 and tipped > 0.1,
					"held %.2f s, leaned %.2f rad" % [held, tipped])
			_gate_ok("and knocks him back", back > 0.2, "%.2f m" % back)
			_gate_ok("and he stands up straight again", r != null and absf(r.lean_angle()) < 0.01)
		else:
			_gate_ok("%s only makes him flinch" % what, held == 0.0 and tipped > 0.02
					and tipped < 0.2, "held %.2f s, leaned %.2f rad" % [held, tipped])
		target.body.queue_free()
		await _frames(4)
	city.camera.rotation = Vector3(-0.08, yaw, 0.0)
	# A gun dropped on the floor: it falls, lies and sleeps; looked at, its card is up.
	var ahead2 := -city.camera.global_transform.basis.z
	ahead2 = Vector3(ahead2.x, 0.0, ahead2.z).normalized()
	var dropped := city.drop_loot(pawn.feet() + ahead2 * 1.6, &"heavy")
	var lying := false
	for i in 300:
		await _frames(1)
		if not dropped.is_empty() and dropped[0].resting():
			lying = true
			break
	if not dropped.is_empty():
		var lying_gun: WorldGunPickup = dropped[0]
		_gate_ok("a dropped gun falls and sleeps on the ground", lying
				and absf(lying_gun.global_position.y - pawn.feet().y) < 0.25,
				"%.2f m over the feet, asleep %s" % [lying_gun.global_position.y - pawn.feet().y, lying])
		city.camera.look_at(lying_gun.centre(), Vector3.UP)
		await _frames(10)
		var hud_card: GunCard = city._arsenal._hud.card
		_gate_ok("looked at, its card is up", city._arsenal.target_pickup == lying_gun and hud_card != null
				and hud_card.visible)
		# The card's plain stats, then its special effects under them (Borderlands 4's).
		var txt := hud_card.text() if hud_card != null else ""
		var rows_ok := true
		for k in ["Fire rate", "Fire mode", "Accuracy", "Reload", "Magazine", "Swap speed",
				"Element", "Crit"]:
			rows_ok = rows_ok and txt.contains(k)
		_gate_ok("the card has its stats: fire rate, fire mode, accuracy, swap speed, element",
				rows_ok and txt.contains("SPECIAL"), txt.replace("\n", " | ").left(200))
		await _save("arms_card")
		city.camera.rotation = Vector3(-0.08, city.camera.rotation.y, 0.0)
		# Walked over, it does not move.
		var lay := lying_gun.global_position
		var lay_basis := lying_gun.global_basis
		city.camera.look_at(Vector3(lay.x, city.camera.global_position.y, lay.z), Vector3.UP)
		city.camera.rotation = Vector3(0.0, city.camera.rotation.y, 0.0)
		_key(KEY_W, true)
		await _frames(70)
		_key(KEY_W, false)
		await _frames(20)
		var past := (pawn.feet() - lay).dot(-city.camera.global_transform.basis.z)
		_gate_ok("walked over, the gun on the floor stays where it lies", is_instance_valid(lying_gun)
				and lying_gun.global_position.distance_to(lay) < 0.01
				and lying_gun.global_basis.z.dot(lay_basis.z) > 0.999 and past > 0.5,
				"moved %.3f m; walked %.1f m past it" % [lying_gun.global_position.distance_to(lay)
				if is_instance_valid(lying_gun) else -1.0, past])
		# Standing over it, looking ahead: hold R takes it for keeps (Halo's).
		pawn.place(Vector3(lay.x, pawn.feet().y, lay.z) + city.camera.global_transform.basis.z * 0.5)
		city.camera.rotation = Vector3(-0.05, city.camera.rotation.y, 0.0)
		await _frames(6)
		var at_feet := city._arsenal.target_pickup == lying_gun and not city._arsenal.target_looked
		var had := city._arsenal.loadout.in_hand()
		var lying_res := lying_gun.result
		_key(KEY_R, true)
		await _frames(40)
		_key(KEY_R, false)
		await _frames(30)
		var now := city._arsenal.loadout.in_hand() as GunInstance
		_gate_ok("standing over it, not looking: hold R takes it for keeps, the old gun dropped",
				at_feet and now != null and now != had and now.result == lying_res
				and city._arsenal.loadout.slots.has(now) and city._arsenal.loadout.third_hand == null
				and city._view.swaps_done > 0,
				"at the feet %s, in a slot %s" % [at_feet, city._arsenal.loadout.slots.has(now)])
	_gate_ok("no hand was changed in plain view", arms.swaps_in_view == 0,
			"%d" % arms.swaps_in_view)

	city._leave_pawn()
	await _frames(4)
	print("[arms] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Is any corner of this gun's model inside the view?
func _arms_gun_in_view(gi: GunInstance) -> bool:
	if gi == null or not is_instance_valid(gi) or not gi.is_inside_tree() or not gi.is_visible_in_tree():
		return false
	for n in gi.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var bb := vi.get_aabb()
		for k in 8:
			if city.camera.is_position_in_frustum(vi.global_transform * bb.get_endpoint(k)):
				return true
	return false

func _run_play_pass() -> void:
	print("[play] a player pawn, driven by the keys")
	city._player.drive_uncaptured = true
	var open := Vector3(-70.0, 0.0, -70.0)
	city.camera.global_position = open + Vector3(0.0, 6.0, 0.0)
	city.camera.rotation = Vector3.ZERO
	city._enter_pawn(open + Vector3(0.0, 4.0, 0.0))
	await _frames(90)
	var pawn := city._player_pawn
	_gate_ok("it falls to the ground and stands on it", pawn.is_on_floor(),
			"feet at %.2f" % pawn.feet().y)
	_gate_ok("and the camera is at its eye (%.2f m)" % city.camera.global_position.y,
			absf(city.camera.global_position.y - Pawn.EYE_HEIGHT) < 0.12)

	# A kerb is stepped over, a wall is not. Facing +Z: the camera looks down -Z.
	city.camera.rotation = Vector3(0.0, PI, 0.0)
	var here := pawn.feet()
	var kerb := _test_block(Vector3(here.x, 0.15, here.z + 3.0), Vector3(6.0, 0.3, 1.0))
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	_gate_ok("a kerb is walked over", pawn.feet().z > here.z + 3.5 and pawn.feet().y < 0.2,
			"z %.2f, feet %.2f" % [pawn.feet().z, pawn.feet().y])
	kerb.queue_free()
	here = pawn.feet()
	var wall := _test_block(Vector3(here.x, 0.75, here.z + 2.5), Vector3(8.0, 1.5, 1.0))
	await _frames(4)
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	_gate_ok("a wall is not", pawn.feet().z < here.z + 2.0 and pawn.feet().z > here.z + 0.5,
			"z %.2f, face at %.2f" % [pawn.feet().z, here.z + 2.0])
	wall.queue_free()

	# The debug walker's headroom bug, on the pawn: a beam that clears a figure
	# on the ground stops one standing on a brick, and ducking gets past it. Its
	# underside at 1.75 m: over a standing figure's 1.68, under the 2.10 of one
	# standing on a brick, over the 1.68 of one crouched on it. (The --walk gate's
	# beam sits at 1.40, from before the figure was resized, and fails.)
	var room := Vector3(open.x + 30.0, 0.0, open.z)
	var beam := _test_block(room + Vector3(0.0, 1.85, 0.0), Vector3(6.0, 0.2, 1.2))
	var ledge := _test_block(room + Vector3(0.0, City.PLATE * 1.5, 0.0), Vector3(6.0, City.PLATE * 3.0, 6.0))
	pawn.place(room + Vector3(0.0, 0.0, -5.0))
	await _frames(20)
	var ducked := false
	_key(KEY_W, true)
	for i in 180:
		await _frames(1)
		ducked = ducked or pawn.is_auto_crouched()
	_key(KEY_W, false)
	await _frames(6)
	_gate_ok("standing on a brick it ducks under the beam and gets past",
			ducked and pawn.feet().z > room.z + 1.0 and pawn.feet().y > 0.3,
			"ducked %s, z %.2f, feet %.2f" % [ducked, pawn.feet().z, pawn.feet().y])
	beam.queue_free()
	ledge.queue_free()
	await _frames(20)
	_gate_ok("and stands up again", not pawn.is_crouched())

	# Shooting from the pawn: face a building's wall from close and hold LMB.
	var b := city.registry.get_building(0)
	var face := b.xform * Vector3(b.recipe.footprint_x * 0.5 * City.STUD, 0.0, 0.0)
	var out := b.xform.basis * Vector3(0.0, 0.0, -1.0)
	pawn.place(face + out * 5.0)
	await _frames(30)
	city.camera.look_at(face + Vector3.UP * 1.2, Vector3.UP)
	await _frames(2)
	var n0 := city.authority.commands.size()
	var hp := pawn.health.total_current()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.parse_input_event(click)
	await _frames(30)
	click = click.duplicate()
	click.pressed = false
	Input.parse_input_event(click)
	await _shoot(0)
	var chips := 0
	for i in range(n0, city.authority.commands.size()):
		if city.authority.commands.entries[i].kind == DamageLog.Kind.CHIP:
			chips += 1
	_gate_ok("holding the button fires the pawn's gun into the wall",
			chips > 0, "%d CHIP(s) from %s" % [chips, city._gun.gun.gun_name])
	# That was a click, and a click is what takes the mouse. A pass must not:
	# it runs on a machine somebody is using (PlayerCamera.hands_off).
	_gate_ok("and the pass's own click did not take the real mouse",
			Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	_gate_ok("and it never shoots its own body", pawn.health.total_current() == hp)

	# The settings menu (Ceramic Edge's menu/, Docs/Reference/ceramicedge.md section 8):
	# Escape pauses the city under it and resuming gives it back; what is set in Options
	# reaches the game (BrickcityMenuHost).
	var mm := city.get_node_or_null(^"/root/MenuManager")
	var ms := city.get_node_or_null(^"/root/MenuSettings")
	_gate_ok("the menu autoloads are there", mm != null and ms != null)
	if mm != null and ms != null:
		_key(KEY_ESCAPE, true)
		await _frames(2)
		_key(KEY_ESCAPE, false)
		await _frames(2)
		_gate_ok("Escape opens the pause menu over the city, and the city stops",
				mm.is_open() and city.get_tree().paused)
		mm.close_pause()
		await _frames(2)
		_gate_ok("and resuming starts it again", not mm.is_open() and not city.get_tree().paused)
		var fov_was: Variant = ms.get_value(&"fov")
		ms.set_value(&"fov", 110, false)
		await _frames(30)
		var vp := city.get_viewport().get_visible_rect().size
		var want := rad_to_deg(2.0 * atan(tan(deg_to_rad(110.0) * 0.5) / (vp.x / vp.y)))
		_gate_ok("a field of view set in Options is the view's",
				is_equal_approx(PlayerView.hfov, 110.0) and absf(city.camera.fov - want) < 1.0,
				"camera %.1f, want %.1f" % [city.camera.fov, want])
		ms.set_value(&"fov", fov_was, false)
		var sens_was: Variant = ms.get_value(&"mouse_sensitivity")
		var crouch_was: Variant = ms.get_value(&"toggle_crouch")
		ms.set_value(&"mouse_sensitivity", 2.0, false)
		ms.set_value(&"toggle_crouch", true, false)
		_gate_ok("and so are the mouse and hold-or-toggle",
				is_equal_approx(PlayerCamera.look_mult, 2.0) and PlayerController.toggle_crouch)
		ms.set_value(&"mouse_sensitivity", sens_was, false)
		ms.set_value(&"toggle_crouch", crouch_was, false)
	city._leave_pawn()
	await _frames(4)
	_gate_ok("V leaves: the camera flies again", city.camera.is_processing() and city._player_pawn == null)
	_check_log_replays()
	print("[play] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Fire `n` single rounds, waiting out the gun's rate between them and the
## damage queue after.
func _shoot(n: int) -> void:
	for i in n:
		while city._gun._cooldown > 0.0 or city._gun.is_reloading():
			await _frames(1)
		# Held across two ticks: physics_frame is emitted BEFORE the nodes'
		# _physics_process, so a trigger held for one resumption never fires.
		city._gun.set_trigger(true)
		await city.get_tree().physics_frame
		await city.get_tree().physics_frame
		city._gun.set_trigger(false)
	var guard := 0
	while not city._damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(2)

func _view_set(structure: int, interior: int, items: int) -> void:
	DebugView.modes = [structure, interior, items] as Array[int]
	city._view_owed = true

## What the city costs a frame, from three viewpoints.
##
##     godot --path . scenes/city.tscn -- --bench
##
## Vsync off, or every reading is the monitor. See Docs/Terrain.md 19.5 for
## the comparison against terrain.
func _run_bench() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	await _frames(30)
	var rep: Dictionary = city.registry.report()
	print("[bench] city: %d buildings, %d live bricks" % [
		rep.buildings, rep.live_blocks])

	await _bench_at("over the city", Vector3(-52.0, 34.0, -52.0),
			Vector3(-0.42, -2.36, 0.0))
	await _bench_at("street level", Vector3(-8.0, 1.7, -8.0),
			Vector3(-0.05, -2.36, 0.0))
	await _bench_at("high and far", Vector3(-140.0, 90.0, -140.0),
			Vector3(-0.42, -2.36, 0.0))
	city.get_tree().quit()

func _bench_at(label: String, pos: Vector3, rot: Vector3) -> void:
	city.camera.position = pos
	city.camera.rotation = rot
	# The shell tier streams a few buildings a tick; sampling before it has
	# caught up with the jump measured a different city on every run.
	await _far_settle()
	var samples: Array[float] = []
	for i in 90:
		await RenderingServer.frame_post_draw
		samples.append(city.get_process_delta_time() * 1000.0)
	var sum := 0.0
	for i in range(floori(samples.size() / 2.0), samples.size()):
		sum += samples[i]
	var detailed := 0
	var meshed_coarse := 0
	for id in city._shells:
		if city._shell_box.has(id):
			continue
		if city._shell_coarse.get(id, false):
			meshed_coarse += 1
		else:
			detailed += 1
	@warning_ignore("integer_division")
	print("[bench]   %-16s %10d tris  %5d calls  %5.1f ms  (%d banded shells, %d coarse meshes, %d far boxes; %d brick buildings, %d brick nodes casting, %d shadow shells)" % [
		label,
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		sum / float(samples.size() / 2), detailed, meshed_coarse, city._far_on.size(),
		city._brick_nodes.size(), int(city._shadow_stats.bricks_casting), int(city._shadow_stats.proxies)])

func _run_shot_pass() -> void:
	city.camera.position = Vector3(-52.0, 34.0, -52.0)
	city.camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(4)
	await _save("city_intact")
	if city._sea != null:
		await _shot_shore()

	# Inside an undamaged building: floors have to be visible from above AND
	# below, and the walls have to read as brick before anything materialises.
	# From a corner room at eye height, looking across the storey: the middle of
	# the building is the stairwell, and a camera there saw only the flight.
	var inside = city.registry.buildings[0]
	# Mid-panel: columns stand on the lattice lines either side of it.
	var corner := (float(TowerRecipe.WALL_THICK) + TowerRecipe.PANEL * 0.5) * City.STUD
	city.camera.position = inside.xform.origin + Vector3(corner,
			City.PLATE * TowerRecipe.SLAB_PLATES + DebugCamera.EYE_HEIGHT, corner)
	city.camera.rotation = Vector3(0.15, -2.356, 0.0)
	await _frames(2)
	await _save("city_interior")
	# And looking down at the floor you are standing on, which is the half that
	# was missing.
	city.camera.position.y = inside.xform.origin.y + 2.4
	city.camera.rotation = Vector3(-0.6, 0.6, 0.0)
	await _frames(2)
	await _save("city_interior_down")
	city.camera.position = Vector3(-52.0, 34.0, -52.0)
	city.camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(2)

	# --- measurement 1: does one hit take the floors out? --------------------
	# The bug was that any damage at all detached every slab in the building,
	# because a slab was a single layer of plates and our connectivity is
	# vertical only, so no plate in it touched any other.
	var probe = city.registry.buildings[0]
	city._blast(probe.xform.origin + Vector3(probe.recipe.footprint_x * 0.5 * City.STUD, 0.8, 0.3), 1.4)
	await _frames(2)
	var standing := city.world.get_block_count(probe.chunk)
	var loose := 0
	for isl in city.islands.islands:
		if isl.is_valid():
			loose += city.world.get_block_count(isl.chunk)
	var built := standing + loose
	print("[city] one hit on building %d: %d bricks, %d came loose (%.1f%%)" % [
		probe.id, built, loose, float(loose) / maxf(built, 1) * 100.0])

	# Take out ONE SIDE of the tall ones, all the way up several courses.
	#
	# A horizontal ring does not topple anything -- it just lowers the building
	# onto whatever is left, which is exactly right and looks like nothing. A
	# brick tower falls the way the research says it does: when its centre of
	# mass leaves what is still holding it up. So the cut has to be asymmetric.
	city._sampling = true
	for b in city.registry.buildings:
		if b.recipe.courses < 44:
			continue
		var w: float = b.recipe.footprint_x * City.STUD
		var d: float = b.recipe.footprint_z * City.STUD
		# Eat the -X half of the footprint over the bottom eight courses.
		for course in range(0, 8):
			var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * City.PLATE
			var px := 0.3
			while px < w * 0.55:
				var pz := 0.3
				while pz < d:
					city._blast(b.xform.origin + Vector3(px, y, pz), 1.5)
					pz += 2.0
				px += 2.0
	# Damage is budgeted now, so a thousand queued blasts take a few dozen ticks
	# to land. Wait for them rather than photographing a half-cut city.
	var guard := 0
	while not city._damage_queue.is_empty() and guard < 600:
		await _frames(1)
		guard += 1
	await _frames(3)
	await _save("city_cut")
	_physics_census("cut")

	await _frames(60)
	await _save("city_falling")
	_physics_census("1 s")

	for k in 4:
		await _frames(60)
		_physics_census("%d s" % (k + 2))
	await _save("city_fallen")

	# The grid overlay, so it is covered by the same pass that covers everything
	# else. Green standing, orange falling, blue settled, grey emptied.
	city._show_grids = true
	city._draw_grids()
	await _frames(2)
	await _save("city_grids")
	print("[city] grid overlay: %d live chunk(s) drawn" % city._grid_count)
	city._show_grids = false
	if city._grid_view != null:
		city._grid_view.visible = false
	await _frames(1)

	var mem: Dictionary = city.world.get_memory_report()
	var rep: Dictionary = city.registry.report()
	var isl: Dictionary = city.islands.report()
	print("[city] final: %d buildings, %d materialised, %d damaged, %.1f MB" % [
		rep.buildings, rep.materialised, rep.damaged, float(mem.total_bytes) / 1048576.0])
	# What a grid actually costs, which is the question "how many grids is too
	# many" really asks. Occupancy is 4 bytes per cell of the chunk's bounding
	# box whether or not a brick is in it.
	print("[city] %d chunks: occupancy %.1f MB, blocks %.1f MB, bake %.1f MB" % [
		mem.chunks, float(mem.occupancy_bytes) / 1048576.0,
		float(mem.block_bytes) / 1048576.0,
		float(int(mem.total_bytes) - int(mem.occupancy_bytes) - int(mem.block_bytes)) / 1048576.0])
	print("[city] islands: %d live (%d settled, %d loose), %d bricks discarded unseen" % [
		isl.islands, isl.settled, isl.disposable, isl.discarded])
	print("[city]   debris: %d brick(s) deleted where they came loose (beyond %.0f m or out of view); %d piece(s) gone once out of view, %d shrunk away in view; %d of furniture; %.0f ms deciding"
			% [isl.tiny_deleted, IslandManager.SMALL_KEEP_RANGE, int(isl.get("debris_unseen", 0)),
			int(isl.get("debris_faded", 0)), isl.furniture_deleted, float(city.islands.spawn_prof.deleted)])
	var cen: Dictionary = city.islands.census
	var sc: Dictionary = city.islands.spawn_census
	var nt := maxi(int(cen.ticks), 1)
	print("[city]   in motion: mean %.1f piece(s) (%.1f landmarks, %.0f boxes), peak %d (%d landmarks, %d boxes)" % [
			float(cen.moving) / nt, float(cen.landmarks) / nt, float(cen.blocks) / nt,
			int(cen.moving_peak), int(cen.landmarks_peak), int(cen.blocks_peak)])
	print("[city]   came loose: %d landmark bodies (%d bricks), %d small bodies (%d), %d deleted where they were (%d), %d dropped over the moving cap (%d)" % [
			sc.landmark[0], sc.landmark[1], sc.small[0], sc.small[1], sc.deleted[0], sc.deleted[1],
			sc.capped[0], sc.capped[1]])
	print("[city]   of which pieces coming off pieces: %d (%d bricks)" % [sc.shed[0], sc.shed[1]])
	for line in city.islands.body_census_lines():
		print("[city]   bodies " + line)
	print("[city]   " + city.islands.hit_census_line())
	print("[city]   pieces' heavy work left for a later tick: %d merged rebuild(s), %d finished mesh(es)" % [
			city.islands.reshapes_spread, city.islands.harvests_spread])
	print("[city]   " + city.islands.blast_census_line())
	print("[city]   " + city.islands.crumb_cost_line())
	print("[city]   " + city.islands.push_census_line())
	print("[city]   " + city.islands.shed_census_line())
	print("[city]   " + city.span_line())
	print("[city]   " + city.islands.heap.census_line())
	print("[city]   furniture broken: %d item(s), %d part(s) thrown; %d crushed under wreckage" % [
			city.islands.furniture_broken[0], city.islands.furniture_broken[1], city.crushed_by_wreckage])
	print("[city]   crumbs: %d piece(s), %d brick(s), %d not drawn (CRUMBS_MAX), worst tick %.2f ms, worst crumble %.2f ms, all told drawing %.1f + cutting out %.1f + deciding %.1f ms" % [
			city.islands.crumbled, city.islands.crumb_bricks, city.islands.crumbs_over, city.islands.crumb_worst_ms,
			city.islands.crumble_worst_ms, city.islands.crumble_parts[0], city.islands.crumble_parts[1],
			city.islands.crumble_parts[2]])
	print("[city]   " + city.islands.snap_census_line())
	# Started can pass built: a start is dropped when its chunk changes under
	# the worker, and asked for again.
	print("[city]   stand-ins: %d built; %d started on a worker; the slowest on the main thread %.1f ms (of any, %.1f)" % [
			city.islands.coarse_built, city.islands.coarse_async, city.islands.coarse_main_worst_ms, city.islands.coarse_worst_ms])
	print("[city]   big pieces in bands: %d band(s) built, %d piece(s) swapped over, %d begun again, %d at two index widths; the slowest band %.1f ms" % [
			city.islands.slices_built, city.islands.slice_swaps, city.islands.slice_restarts,
			city.islands.slice_mixed_width, city.islands.slice_worst_ms])
	print("[city]   piece shadows from stand-ins: %d asked for, %d hung; %d piece(s) casting one now" % [
			city.islands.shadow_proxies_asked, city.islands.shadow_proxies_built,
			int(city._shadow_stats.get("pieces_proxied", 0))])
	print("[city]   collapse director: %d mega round(s) turned %d group(s) into %d chunk(s) (%d round(s) held); %d breakage group(s); %d furniture brick(s) written off; %d building(s) came down big" % [
			city.director.rounds, city.director.groups_in, city.director.chunks_out, city.director.held_rounds,
			city.director.breakage_out, city.director.furniture_out, city.director.collapsing.size()])
	print("[city]   sleep: %d piece(s) put to sleep (%d by the cap), %d woken (%d of the cap's), %d asleep now" % [
			city.islands.slept, city.islands.cap_slept, city.islands.woken, city.islands.cap_woken, city.islands.dormant.size()])
	print("[city]   support: %d settled piece(s) woken because what held them went, %d because something landed on them; %d nudged down instead of settling with nothing under them; %d jolt(s) not taken for landings; %d woken as the piece under them moved off, %d settle(s) put off for a piece under still moving" % [
			city.islands.ripple_woken, city.islands.touch_woken, city.islands.unsupported_nudges, city.islands.jolts_ignored,
			city.islands.holder_woken, city.islands.settle_waits])
	# The patches CollapseNext's cleanup would retire once they stay at 0.
	print("[city]   patches: %d nudged (nothing under), %d settle(s) refused floating, %d perched piece(s) tipped, %d floating piece(s) the watchdog woke" % [
			city.islands.unsupported_nudges, city.islands.floating_refused, city.islands.perched_tipped,
			city.islands.audit_woken])
	print("[city]   %d merge(s) down to %d box(es); %d box(es) rebuilt per block when hit" % [
		isl.merged_shapes, isl.merged_boxes, isl.unmerged_boxes])
	print("[city] impacts: %d landing(s) sheared %d joint(s), %d split(s), %d snapped across" % [
		isl.impacts, isl.impact_blocks, isl.splits, isl.breaks])
	print("[city]   biggest single-tick speed loss %.1f m/s, %d landing(s) on a piece long enough to snap" % [
		isl.peak_drop, isl.long_landings])
	print("[city]   landings rejected: %d too gentle, %d too short; longest piece landed %.1f m" % [
		isl.soft_landings, isl.short_landings, isl.longest_landed])
	print("[city] promotions: %d in %.0f ms (%.1f ms each), %d of them for somebody walking up" % [
		city._promotions, city._promote_ms, city._promote_ms / maxf(city._promotions, 1), city._near_promotions])
	print("[city] falling debris sheared %d brick(s) off what it landed on" % city._impact_damage)
	var kinds := {}
	for e in city.authority.commands.entries:
		var k: String = DamageLog.Kind.keys()[e.kind]
		kinds[k] = int(kinds.get(k, 0)) + 1
	print("[city] authority: %d command(s) committed -- %s" % [
		city.authority.commands.size(), kinds])
	_check_log_replays()

	# --- measurement 2: is settled wreckage still breakable? -----------------
	# A collapsed section is a frozen body whose origin is its centre of mass,
	# so anything that located it by origin distance missed it entirely.
	# get_block_count includes blocks that are already dead -- a hit marks them,
	# it does not remove them from the chunk -- so the only count that answers
	# "did the blast do anything" is the alive one.
	var biggest: BrickIsland = null
	var biggest_n := 0
	for piece in city.islands.islands:
		if piece.is_valid() and city.world.get_alive_block_count(piece.chunk) > biggest_n:
			biggest_n = city.world.get_alive_block_count(piece.chunk)
			biggest = piece
	if biggest != null:
		# Aim at an actual brick. A toppled building is hollow, so the centre
		# of its bounding box is thin air and a blast there removes nothing --
		# which is a bad measurement, not a bug.
		# A LIVE one: the list has the dead too, and the middle of it was as
		# often as not a brick the pass's own blasts had taken -- a hole, where
		# a blast reached nothing (this printed FAIL in about half the runs
		# since September; 2026-10-15).
		var boxes: Array = city.world.get_block_boxes(biggest.chunk)
		var live: Array = boxes.filter(func(b: Dictionary) -> bool: return bool(b.alive))
		var aim := city.islands.world_aabb(biggest).get_center()
		if not live.is_empty():
			@warning_ignore("integer_division")
			var pick: Dictionary = live[live.size() / 2]
			aim = biggest.chunk_transform() * (pick.pos as Vector3)
		var hits := city.islands.damage_near(aim, 1.4)
		var after := city.world.get_alive_block_count(biggest.chunk)
		print("[city] settled wreckage: biggest piece %d bricks, blast hit %d piece(s), %d bricks left" % [
			biggest_n, hits, after])
		print("[city] %s" % ("ok    settled wreckage is still breakable" if after < biggest_n
				else "FAIL  settled wreckage shrugged the blast off"))
	if city._frame_samples > 0:
		print("[city] frame time: mean %.1f ms, worst %.1f ms, %d of %d over 33.3 ms" % [
			city._frame_sum / city._frame_samples, city._frame_worst, city._frames_over_30, city._frame_samples])
	_report_profile()
	city.get_tree().quit()

## The gate for F5/F9. Knock the city about, save partway through the collapse
## -- pieces still falling, some at rest -- reload the scene from the save, and
## check it is the same area: every damaged building brick for brick, every
## piece brick for brick, where it was, moving or not as it was. Then let the
## loaded city carry on and check the log still replays into it.
func _run_checkpoint_pass() -> void:
	var root := city.get_tree().root
	if root.has_meta(CHECKPOINT_GATE_META):
		var saved_want: Dictionary = root.get_meta(CHECKPOINT_GATE_META)
		root.remove_meta(CHECKPOINT_GATE_META)
		await _check_checkpoint(saved_want)
		return
	city.camera.position = Vector3(-52.0, 34.0, -52.0)
	city.camera.rotation = Vector3(-0.42, -2.36, 0.0)
	await _frames(4)
	var probe = city.registry.buildings[0]
	city._blast(probe.xform.origin + Vector3(probe.recipe.footprint_x * 0.5 * City.STUD, 0.8, 0.3), 1.4)
	# A build placed after the city was built, and hit: the save has to carry
	# it, or the load has no building for those commands to land on.
	var placed_id := -1
	if city._placed.is_empty():
		city._place_build(BuildRecipe.shipped("cottage"))
	if not city._placed.is_empty():
		placed_id = int(city._placed[0]["id"])
		var pbox: AABB = CityPlacer.box_of(city.registry.get_building(placed_id))
		# Twice, a few ticks apart: the hit that turns a placed build into
		# bricks destroys none of them (measured 2026-10-08: 76 of 76 alive
		# after the first, 3 after the second -- not this gate's to fix).
		for shot in 2:
			city._blast(pbox.position + Vector3(0.2, 1.0, pbox.size.z * 0.5), 1.0)
			await _frames(8)
	for b in city.registry.buildings:
		if b.recipe.courses < 44:
			continue
		var w: float = b.recipe.footprint_x * City.STUD
		var d: float = b.recipe.footprint_z * City.STUD
		for course in range(0, 8):
			var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * City.PLATE
			var px := 0.3
			while px < w * 0.55:
				var pz := 0.3
				while pz < d:
					city._blast(b.xform.origin + Vector3(px, y, pz), 1.5)
					pz += 2.0
				px += 2.0
	var guard := 0
	while not city._damage_queue.is_empty() and guard < 600:
		await _frames(1)
		guard += 1
	# Saved while pieces are still coming down: three quarters of a second of
	# physics, counted in ticks. It was 45 drawn frames -- the same at 60 a
	# second, and four seconds with the display asleep and drawing at 11, by
	# which time everything was at rest and "a moving piece still moving" had
	# nothing to ask about (2026-10-14).
	for t in roundi(0.75 * Engine.physics_ticks_per_second):
		await city.get_tree().physics_frame

	var want := {"buildings": {}, "pieces": {}, "dormant": 0, "moving": 0, "settled": 0}
	var touched := {}
	for e in city.authority.commands.entries:
		if not e.is_piece():
			touched[e.target] = true
	for id in touched:
		var b := city.registry.get_building(int(id))
		if b != null and not b.toppled and b.is_materialised():
			want.buildings[int(id)] = _structure_of(b.chunk)
	for isl in city.islands.islands:
		if not isl.is_valid() or isl.piece_id < 0:
			continue
		want.pieces[isl.piece_id] = {"structure": _structure_of(isl.chunk),
				"xform": isl.chunk_transform(), "at_rest": isl.settled,
				"linear": isl.body.linear_velocity}
		if isl.settled:
			want.settled += 1
		else:
			want.moving += 1
	for dm in city.islands.dormant:
		if dm.piece_id >= 0:
			want.dormant += 1
	want["commands"] = city.authority.commands.size()
	want["placed"] = placed_id
	want["placed_hit"] = want.buildings.has(placed_id)
	print("[city] checkpoint: saving %d command(s), %d damaged building(s), %d piece(s) (%d moving, %d at rest), %d asleep" % [
		want.commands, want.buildings.size(), want.pieces.size(), want.moving, want.settled, want.dormant])
	if not city.save_checkpoint():
		city.get_tree().quit(1)
		return
	root.set_meta(CHECKPOINT_GATE_META, want)
	city.load_checkpoint()

func _check_checkpoint(want: Dictionary) -> void:
	print("[city] checkpoint gate: the loaded area against the saved one")
	_gate_ok("every command came back", city.authority.commands.size() == int(want.commands),
			"%d of %d" % [city.authority.commands.size(), int(want.commands)])
	var same_b := 0
	for id in want.buildings:
		var b := city.registry.get_building(int(id))
		if b != null and not b.toppled and b.is_materialised() \
				and _structure_of(b.chunk) == want.buildings[id]:
			same_b += 1
	_gate_ok("every damaged building, brick for brick",
			same_b == want.buildings.size() and same_b > 0,
			"%d of %d" % [same_b, want.buildings.size()])
	var pb := city.registry.get_building(int(want.get("placed", -1)))
	_gate_ok("a build placed before the save is there after the load, hit as it was",
			bool(want.get("placed_hit", false)) and pb != null and pb.is_build()
			and pb.is_materialised() and city._placed.size() == 1,
			"building %d, hit before the save: %s, %d placed now" % [
			int(want.get("placed", -1)), want.get("placed_hit", false), city._placed.size()])
	var got := {}
	for isl in city.islands.islands:
		if isl.is_valid() and isl.piece_id >= 0:
			got[isl.piece_id] = isl
	var same := 0
	var placed := 0
	var moving := 0
	var drawn := 0
	for id in want.pieces:
		var p: Dictionary = want.pieces[id]
		var isl: BrickIsland = got.get(id)
		if isl == null:
			continue
		if _structure_of(isl.chunk) == p.structure:
			same += 1
		if isl.chunk_transform().is_equal_approx(p.xform) and isl.settled == bool(p.at_rest):
			placed += 1
		else:
			print("  piece %d: at rest %s -> %s, %.3f m out" % [int(id), p.at_rest,
					isl.settled, isl.chunk_transform().origin.distance_to(p.xform.origin)])
		if not isl.settled and not bool(p.at_rest) \
				and isl.body.linear_velocity.is_equal_approx(p.linear):
			moving += 1
		# Something to draw into, or an array of bricks nobody can see.
		if isl.mesh != null or isl.mm_key != Vector3.ZERO:
			drawn += 1
	var n: int = want.pieces.size()
	_gate_ok("every piece, brick for brick", same == n and n > 0, "%d of %d" % [same, n])
	_gate_ok("where it was, at rest or not as it was", placed == n, "%d of %d" % [placed, n])
	_gate_ok("a moving piece still moving", moving == int(want.moving) and moving > 0,
			"%d of %d" % [moving, int(want.moving)])
	_gate_ok("every piece has a node to draw into", drawn == n, "%d of %d" % [drawn, n])
	_gate_ok("everything asleep is still asleep",
			city.islands.dormant.size() == int(want.dormant),
			"%d of %d" % [city.islands.dormant.size(), int(want.dormant)])
	await _frames(20)
	await _save("city_checkpoint_loaded")
	# And it carries on: the collapse finishes, and the log -- the loaded part
	# and what was added after -- still replays into what is standing.
	await _frames(240)
	_gate_ok("the loaded city carries on", city.authority.commands.size() >= int(want.commands),
			"%d command(s) now" % city.authority.commands.size())
	_check_log_replays()
	print("[city] checkpoint gate: %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _check_log_replays() -> void:
	var t0 := Time.get_ticks_msec()
	var entries := city.authority.commands.entries
	var touched := {}
	for e in entries:
		if not e.is_piece():
			touched[e.target] = true

	# The twins: same recipes, same places, same staircases, fresh bricks.
	var twin := BuildingRegistry.new(city.world, city.palette)
	var twin_of := {}
	var skipped := 0
	for id in touched:
		var b := city.registry.get_building(int(id))
		# A placed build of one frame has a twin too (its fixtures come with
		# its recipe); one of several frames is skipped, as every build was:
		# the replay below resolves frame 0 only.
		if b == null or (b.is_build() and not b.build.is_single_frame()):
			skipped += 1
			continue
		if b.is_build():
			twin_of[int(id)] = twin.register_build(b.build, b.xform)
			continue
		var tid := twin.register(b.recipe.footprint_x, b.recipe.footprint_z,
				b.recipe.courses, b.xform)
		for f in b.fixtures:
			twin.add_fixture(tid, f.kind, f.params, f.cell, f.role)
		twin_of[int(id)] = tid
	var toppled := {}
	var rep := StructureReplayer.new(city.world, func(id: int, frame: int) -> int:
		if frame != 0 or not twin_of.has(id) or toppled.has(id):
			return -1
		return twin.materialise(int(twin_of[id])))
	rep.on_toppled = func(id: int) -> void:
		toppled[id] = true
		twin.hand_over(int(twin_of[id]))
	city._storey_hooks(rep, twin, func(id: int) -> int: return int(twin_of.get(id, -1)))
	rep.apply_all(entries)

	var b_ok := 0
	var b_n := 0
	for id in twin_of:
		var b := city.registry.get_building(int(id))
		if b.toppled or not b.is_materialised():
			continue
		b_n += 1
		var tb := twin.get_building(int(twin_of[id]))
		var hs := _structure_of(b.chunk)
		var ts := _structure_of(tb.chunk)
		if hs == ts:
			b_ok += 1
		elif b_n - b_ok == 1:
			_explain_difference("building %d" % int(id), hs, ts)
	var p_ok := 0
	var p_n := 0
	var p_missing := 0
	var rest_ok := 0
	var rest_n := 0
	for isl in city.islands.islands:
		if not isl.is_valid() or isl.piece_id < 0 or not twin_of.has(isl.owner):
			continue
		p_n += 1
		var rc := rep.piece_chunk(isl.piece_id)
		if rc < 0:
			p_missing += 1
			continue
		# A landmark at rest has to lie where the host's lies (PIECE_REST).
		if isl.settled and isl.landmark:
			rest_n += 1
			if city.world.get_chunk_transform(rc).is_equal_approx(isl.chunk_transform()):
				rest_ok += 1
		var hp := _structure_of(isl.chunk)
		var rp := _structure_of(rc)
		if hp == rp:
			p_ok += 1
		elif p_n - p_ok - p_missing <= 2:
			_explain_difference("piece %d (owner %d, woke %d time(s))" % [isl.piece_id, isl.owner, isl.wakes], hp, rp)
			_trace_piece(rep, entries, isl, hp, rp)

	var loads := 0
	var unloads := 0
	for e in entries:
		if e.kind == DamageLog.Kind.LOAD:
			loads += 1
		elif e.kind == DamageLog.Kind.UNLOAD:
			unloads += 1
	print("[city] log replay: %d command(s) into %d twin building(s) (%d skipped), %d missed, %.0f ms; wreckage %d LOAD, %d UNLOAD" % [
		entries.size(), twin_of.size(), skipped, rep.missed, Time.get_ticks_msec() - t0, loads, unloads])
	print("[city]   buildings: %d of %d identical; pieces: %d of %d identical, %d missing; %d of %d at rest where the host's are" % [
		b_ok, b_n, p_ok, p_n, p_missing, rest_ok, rest_n])
	for m in rep.miss_log:
		print("[city]   missed: %s target %d seq %d -- %s" % m)
	print("[city] %s" % ("ok    the log replays into the same structure"
			if b_ok == b_n and p_ok == p_n and rep.missed == 0 and rest_ok == rest_n
			else "FAIL  the log does not replay into the same structure"))

	# Give the twins' bricks back: nothing after this should find them.
	for id in rep.pieces:
		var c := rep.piece_chunk(int(id))
		if c >= 0:
			city.world.release_chunk(c)
	for id in twin_of:
		twin.dematerialise(int(twin_of[id]))

## Where did a piece's missing bricks go in the replay, and what does the log say
## about the piece? Only run when a piece disagrees.
func _trace_piece(rep: StructureReplayer, entries: Array, isl: BrickIsland,
		host: PackedStringArray, replay: PackedStringArray) -> void:
	var in_replay := {}
	for s in replay:
		in_replay[s] = true
	var lost := {}
	for s in host:
		if not in_replay.has(s):
			lost[s] = true
	# Which replay piece holds them now? Cells are absolute -- the building's grid,
	# which every piece cut from it keeps -- so this is where they went.
	var holders := {}
	for id in rep.pieces:
		var c := rep.piece_chunk(int(id))
		if c < 0 or int(id) == isl.piece_id:
			continue
		for s in _structure_of(c):
			if lost.has(s):
				holders[int(id)] = int(holders.get(int(id), 0)) + 1
	print("[city]     lost bricks are now in replay piece(s) %s" % holders)
	# The piece's own history in the log, and its parent's.
	var parent := -1
	var mine: Array = []
	for e in entries:
		var ee: DamageLog.Entry = e
		if DamageLog.piece_id(ee.seq) == isl.piece_id and ee.kind == DamageLog.Kind.DETACH:
			parent = ee.target if ee.flags & DamageLog.FLAG_FROM_PIECE else -1
			mine.append("born seq %d from %s %d, %d cells %d ids" % [ee.seq,
					"piece" if parent >= 0 else "building", ee.target, ee.points.size(), ee.blocks.size()])
		elif ee.target == isl.piece_id and ee.is_piece():
			mine.append("%s seq %d" % [DamageLog.Kind.keys()[ee.kind], ee.seq])
	print("[city]     its log: %s" % [mine.slice(0, 12)])
	if parent >= 0:
		var hist: Array = []
		for e in entries:
			var ee: DamageLog.Entry = e
			if ee.is_piece() and ee.target == parent:
				hist.append("%s seq %d%s" % [DamageLog.Kind.keys()[ee.kind], ee.seq,
						" -> piece %d" % DamageLog.piece_id(ee.seq) if ee.kind == DamageLog.Kind.DETACH else ""])
		print("[city]     parent %d's log: %s" % [parent, hist.slice(0, 20)])

func _explain_difference(what: String, host: PackedStringArray, replay: PackedStringArray) -> void:
	var in_replay := {}
	for s in replay:
		in_replay[s] = true
	var in_host := {}
	for s in host:
		in_host[s] = true
	var only_host := PackedStringArray()
	var only_replay := PackedStringArray()
	for s in host:
		if not in_replay.has(s):
			only_host.append(s)
	for s in replay:
		if not in_host.has(s):
			only_replay.append(s)
	print("[city]   %s differs: host %d, replay %d; %d only on the host %s, %d only in the replay %s" % [
		what, host.size(), replay.size(), only_host.size(), only_host.slice(0, 3),
		only_replay.size(), only_replay.slice(0, 3)])

## A chunk's structure as something comparable: every living, structural block
## as its ABSOLUTE cell (the building's grid, kept by every piece cut from it and
## now through sleep) and its archetype by name, sorted.
func _structure_of(chunk: int) -> PackedStringArray:
	var out := PackedStringArray()
	if chunk < 0 or not city.world.is_chunk_alive(chunk):
		return out
	var origin := city.world.get_chunk_origin(chunk)
	for id in city.world.get_block_count(chunk):
		if city.world.is_block_decorative(chunk, id):
			continue
		var cell := StructureReplayer.block_cell(city.world, chunk, id)
		# Dead and detached blocks are not solid: they were destroyed, or they left
		# with a piece. Only what is standing here counts.
		if cell == StructureReplayer.NO_CELL or not city.world.is_solid(chunk, origin + cell):
			continue
		# By NAME: fixture parts are baked on first demand, so the same stair step
		# can hold a different archetype number in another registry -- or on
		# another machine -- and still be the same brick.
		out.append("%s:%s" % [origin + cell, city.world.get_archetype_name(city.world.get_block_archetype(chunk, id))])
	out.sort()
	return out

## Where the time actually went. `script_total` is everything this script did in
## a physics tick; whatever the frame cost beyond that is the engine -- physics
## solve, rendering, and the buffer uploads the script asked for.
func _report_profile() -> void:
	if city._prof_worst.is_empty():
		return
	var keys := ["render", "solve", "disable", "spawn", "remesh",
			"bands", "retire", "damage", "promote", "promote_finish", "stream", "collision",
			"islands", "hud"]
	if city._frame_samples > 0:
		print("[prof] mean frame: %.1f ms physics (solver + this script), %.1f ms idle process" % [
				city._phys_sum / city._frame_samples, city._proc_sum / city._frame_samples])
	if city._clock != null:
		for line in city._clock.report_lines():
			print("[prof] " + line)
	print("[prof] uploads from workers over the pass: " + UploadLedger.line(city._render_landed))
	for r: Array in city._render_spikes:
		print("[prof]   render flush %.1f ms at tick %d: %s" % [r[0], r[1], r[2]])
	print("[prof] worst script tick %.1f ms  (%d islands)" % [
			city._prof_worst_ms, int(city._prof_worst.get("island_count", 0))])
	if city._glass_ticks > 0:
		print("[prof] glass: %.2f ms a tick on the main thread over %d ticks, worst %.1f ms (one hung %.1f, one built here from bricks %.1f, %d built here); %d built in all" % [
				city._glass_usec / 1000.0 / city._glass_ticks, city._glass_ticks, city._glass_worst_usec / 1000.0,
				city._glass_hang_worst_usec / 1000.0, _glass_here_worst_usec / 1000.0, _glass_here,
				city.glass_built])
	if not city._prof_spikes.is_empty():
		var spikes := city._prof_spikes.duplicate()
		spikes.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
		print("[prof] %d tick(s) over %.0f ms; the worst:" % [spikes.size(), City.SPIKE_MS])
		for k in mini(12, spikes.size()):
			print("[prof]   %.1f ms at tick %d: %s" % [spikes[k][0], spikes[k][1], spikes[k][2]])
	var line := ""
	for k in keys:
		line += "%s %.1f  " % [k, float(city._prof_worst.get(k, 0.0))]
	print("[prof]   " + line)
	print("[prof]   of which damage: promote %.1f  rooms %.1f  hit %.1f  loose pieces %.1f  collision update %.1f"
			% [float(city._prof_worst.get("dmg_promote", 0.0)), float(city._prof_worst.get("dmg_rooms", 0.0)),
			float(city._prof_worst.get("dmg_hit", 0.0)), float(city._prof_worst.get("dmg_pieces", 0.0)),
			float(city._prof_worst.get("dmg_disable", 0.0))])
	print("[prof]   of which collision: %d band(s) merged again, the worst building's %d in %.1f ms" % [
			int(city._prof_worst.get("col_bands", 0.0)), int(city._prof_worst.get("col_worst_bands", 0.0)),
			float(city._prof_worst.get("col_worst", 0.0))])
	print("[prof]   of which rooms: scan %.1f  draw %.1f  open %.1f  body back %.1f  redraw %.1f  wrecks %.1f  shut %.1f  sync drawn %.1f  fake %.1f" % [
			float(city._prof_worst.get("rm_scan", 0.0)), float(city._prof_worst.get("rm_draw", 0.0)),
			float(city._prof_worst.get("rm_open", 0.0)), float(city._prof_worst.get("rm_swap", 0.0)),
			float(city._prof_worst.get("rm_redraw", 0.0)), float(city._prof_worst.get("rm_wreck", 0.0)),
			float(city._prof_worst.get("rm_ladder", 0.0)), float(city._prof_worst.get("rm_sync", 0.0)),
			float(city._prof_worst.get("rm_fake", 0.0))])
	print("[prof]   of which fake: rooms worked out %.1f, drawing rebuilt %.1f (%d rooms in it)" % [
			float(city._prof_worst.get("fk_rooms", 0.0)), float(city._prof_worst.get("fk_attach", 0.0)),
			int(city._prof_worst.get("fk_count", 0.0))])
	print("[prof] solves: worst single %.1f ms (%d bricks, %d groups, collapsing %s); mega buildings solved alone %d time(s), %.0f ms; %d batch(es) solved at once, worst %.1f ms" % [
			float(city._solve_worst[0]), int(city._solve_worst[1]), int(city._solve_worst[2]), city._solve_worst[3],
			int(city._solve_mega[0]), float(city._solve_mega[1]), city._solve_batches, city._solve_batch_worst])
	var sa: Dictionary = city.world.get_solve_async_stats()
	print("[prof] solves on workers: %d taken, %d stale (solved again), %d dropped; %d busy (no slot); the main thread waited for %d, %.1f ms in all" % [
			int(city._solve_async[0]), int(city._solve_async[1]), int(city._solve_async[2]), int(sa.busy),
			int(sa.waited), float(sa.wait_ms)])
	print("[prof] cascades: %d round(s) that failed something, at most %d in one solve; %d small group(s) held on by their own studs; %d second solve(s) in a tick put off" % [
			city._cascade_rounds, city._cascade_worst, city._held_groups, city._resolves_put_off])
	var sw: Array = city.islands.spawn_worst
	print("[prof] worst single spawn %.1f ms (%d bricks): split %.1f  shapes %.1f  node %.1f (furniture %.1f, into the scene %.1f, %d boxes)  mesh %.1f" % [
			float(sw[0]), int(sw[5]), float(sw[1]), float(sw[2]), float(sw[3]), float(sw[6]),
			float(sw[7]), int(sw[8]), float(sw[4])])
	print("[prof] worst single piece landing / re-solve: %s" % [city.islands.unit_worst])
	print("[prof] worst single building given back %.1f ms (%d bricks): dematerialise %.1f  free %.1f  shell %.1f; %d piece upload(s) waited a tick" % [
			float(city._demote_worst[0]), int(city._demote_worst[4]), float(city._demote_worst[1]),
			float(city._demote_worst[2]), float(city._demote_worst[3]), city.islands.uploads_waited])
	var bw: Dictionary = city.islands.blind_worst_stages
	print("[prof] the longest invisible stretch, tick by tick: %s" % [bw])
	print("[prof]   of which disable: collision %.1f  furniture bodies %.1f; furniture redraw %.1f (in retire)" % [
			float(city._prof_worst.get("dis_collision", 0.0)), float(city._prof_worst.get("dis_rooms", 0.0)),
			float(city._prof_worst.get("furniture", 0.0))])
	print("[prof]   of which bands: harvest %.1f (attach %.1f, finished %.1f)  bake slices %.1f  upload %.1f" % [
			float(city._prof_worst.get("bd_harvest", 0.0)), float(city._prof_worst.get("bd_apply", 0.0)),
			float(city._prof_worst.get("bd_done", 0.0)), float(city._prof_worst.get("bd_cpp", 0.0)),
			float(city._prof_worst.get("bd_upload", 0.0))])
	print("[prof]   of which stream: trim %.1f  merge %.1f  rooms %.1f  detail %.1f  residency %.1f  shells %.1f"
			% [float(city._prof_worst.get("st_trim", 0.0)), float(city._prof_worst.get("st_merge", 0.0)),
			float(city._prof_worst.get("st_rooms", 0.0)), float(city._prof_worst.get("st_detail", 0.0)),
			float(city._prof_worst.get("st_residency", 0.0)), float(city._prof_worst.get("st_shells", 0.0))])
	print("[prof] %d building meshes rebuilt from scratch (the rest were index patches)"
			% city._full_rebuilds)
	var tw: Dictionary = city.islands.tick_worst
	if not tw.is_empty():
		print("[prof] worst islands.tick %.1f ms = loop %.1f + resolve %.1f + fracture %.1f + mesh %.1f  (%d islands)" % [
				float(tw.total), float(tw.loop), float(tw.resolve), float(tw.fracture),
				float(tw.mesh), int(tw.islands)])
		print("[prof]   of which fracture: landings %.1f + merged rebuilds %.1f" % [
			float(tw.get("landings", 0.0)), float(tw.get("reshapes", 0.0))])
		print("[prof]   of which resolve (harvest, upload, mesh queue, band holes, resolve queue): %s; the slowest mesh the queue made %s" % [
			tw.get("resolve parts: harvest, upload, mesh queue, band holes, resolve queue", []),
			city.islands.mesh_drain_worst])
		print("[prof]   worst single piece reshape %.1f ms (%d bricks, %d boxes): shapes %.1f + space %.1f" % [
			float(city.islands.reshape_worst[0]), int(city.islands.reshape_worst[1]), int(city.islands.reshape_worst[2]),
			float(city.islands.reshape_worst[3]), float(city.islands.reshape_worst[4])])
	print("[prof]   of which the loop: pieces %.1f + dormancy %.1f (wake %.1f, sleep %.1f) + debris cap %.1f" % [
				float(tw.get("pieces", 0.0)), float(tw.get("dormancy", 0.0)),
				float(tw.get("wake", 0.0)), float(tw.get("sleep", 0.0)), float(tw.get("cap", 0.0))])
	print("[prof]   worst single wake %.1f ms (%d bricks), worst single sleep %.1f ms (%d bricks)" % [
				float(city.islands.wake_worst[0]), int(city.islands.wake_worst[1]),
				float(city.islands.sleep_worst[0]), int(city.islands.sleep_worst[1])])
	var sp: Dictionary = city.islands.spawn_prof
	var _bi: Dictionary = city.islands.report()
	print("[prof] overlaps alive at once, worst: %d" % _bi.overlap_peak)
	print("[prof] invisible pieces: %d went blind, worst %d tick(s), mean %.2f, biggest %d bricks" % [
			_bi.blind_count, _bi.blind_worst, _bi.blind_mean, _bi.meshless_worst_blocks])
	print("[prof] spawn total %.0f ms = split %.0f (C++ chunk+blocks) + shapes %.0f + node %.0f + mesh %.0f" % [
			sp.total, sp.split, sp.shapes, sp.node, sp.mesh])
	if city._frame_samples > 0:
		line = ""
		for k in keys:
			line += "%s %.2f  " % [k, float(city._prof_sum.get(k, 0.0)) / maxi(city._tick_samples, 1)]
		print("[prof] mean per tick: " + line)
		line = ""
		for k in ["after_spawn", "stairs", "dmg_promote", "dmg_rooms", "dmg_hit", "dmg_pieces", "dmg_disable"]:
			line += "%s %.2f  " % [k, float(city._prof_sum.get(k, 0.0)) / maxi(city._tick_samples, 1)]
		print("[prof]   of which damage, mean per tick: " + line)
		var dn: Array = city.islands.damage_near_ms
		print("[prof]   loose pieces (damage_near), all told: %d call(s); waking sleepers %.1f ms, finding pieces %.1f, damaging them %.1f, pushing %.1f" % [
				int(dn[4]), dn[0], dn[1], dn[2], dn[3]])
		var dm: Array = city.islands.damage_ms
		print("[prof]     of which a hit on a piece: the hit %.1f ms, throwing what it killed %.1f, cutting shapes %.1f, solve %.1f, mesh %.1f" % [
				dm[0], dm[1], dm[2], dm[3], dm[4]])
		var tp: Dictionary = city.islands.tick_prof
		var n := maxi(int(city.islands.census.ticks), 1)
		print("[prof] islands per tick, whole run: loop %.2f (pieces %.2f, dormancy %.2f, cap %.2f)  resolve %.2f  fracture %.2f  mesh %.2f  multimesh %.2f" % [
				float(tp.loop) / n, float(tp.pieces) / n, float(tp.dormancy) / n, float(tp.cap) / n,
				float(tp.resolve) / n, float(tp.fracture) / n, float(tp.mesh) / n, float(tp.mm) / n])

## Sustained destruction across a whole city, with rendering on.
##
## The shot pass cuts twelve buildings open in one burst and then watches them
## fall; this keeps firing for the whole run, so promotion, island spawning,
## island LOD and the damage queue are all under load at the same time rather
## than one after another. Run it with:
##
##     godot --path . -- --stress --buildings=200
func _run_stress_pass() -> void:
	print("[stress] %d buildings, %.1f m spacing" % [city._city_size, 13.0])
	city.camera.position = Vector3(0.0, 46.0, 96.0)
	city.camera.rotation = Vector3(-0.42, 0.0, 0.0)
	await _frames(10)

	var mem: Dictionary = city.world.get_memory_report()
	print("[stress] standing: %.1f MB, %d chunks, %d islands" % [
			float(mem.total_bytes) / 1048576.0, int(mem.chunks), city.islands.islands.size()])

	if city._agents_mode:
		_spawn_many(Vector3(0.0, 0.0, 30.0))
		await _frames(30)
	city._sampling = true
	city._phase = "under fire"
	var target := 0
	var shots := 0
	var toppled_on_purpose := 0
	# One building per frame, working along the city. Unlike the old version
	# this fires a SMALL pattern, because the damage queue drains at
	# DAMAGE_PER_TICK (8) a tick: a pattern that queues more than eight hits per
	# frame builds a backlog that never clears, and the pass then measures a
	# permanent queue rather than a city. See "What the stress pass could not
	# say" in Docs/Status.md.
	while target < city.registry.buildings.size():
		var b = city.registry.buildings[target]
		var collapse: bool = city._stress_collapse < 0 or target < city._stress_collapse
		if collapse:
			shots += _stress_topple(b)
			toppled_on_purpose += 1
		else:
			shots += _stress_wound(b)
		target += 1
		await _frames(1)

	# Let the queue actually empty. If it does not, the run is not measuring
	# what it says it is, and the report below says so rather than quietly
	# reporting a number taken under a backlog.
	city._phase = "damage queue draining"
	var wait := 0
	while not city._damage_queue.is_empty() and wait < 1800:
		await _frames(1)
		wait += 1
	var queue_left := city._damage_queue.size()

	# Everything is falling, nothing new is arriving.
	city._phase = "collapsing"
	await _frames(180)

	# And then: does it come back?
	city._phase = "settled"
	await _frames(240)
	var peak_mb := float(city.world.get_memory_report().total_bytes) / 1048576.0
	var peak_res: int = city.registry.report().materialised
	# How much of the peak belongs to buildings nobody can see the bricks of?
	# A materialised building is skipped by _stream_shells, so it is drawn as
	# full brick geometry however far away it is -- and the bake is most of what
	# a resident building costs.
	var near_res := 0
	var far_res := 0
	var far_blocks := 0
	var near_blocks := 0
	for b in city.registry.buildings:
		if not b.is_materialised():
			continue
		if b.xform.origin.distance_to(city.camera.global_position) > City.SHELL_DETAIL_RANGE:
			far_res += 1
			far_blocks += city.world.get_block_count(b.chunk)
		else:
			near_res += 1
			near_blocks += city.world.get_block_count(b.chunk)
	print("[stress] at peak: %d resident within %.0f m (%d blocks), %d beyond it (%d blocks, %.0f%%)" % [
			near_res, City.SHELL_DETAIL_RANGE, near_blocks, far_res, far_blocks,
			float(far_blocks) / maxf(near_blocks + far_blocks, 1) * 100.0])

	# Well past TRIM_AFTER_MS (12 s) AND past several runs of _trim_quiet, which
	# only fires every 120 physics frames. A tail shorter than both answers
	# "does a damaged city hand its bricks back?" with the trim barely started.
	city._phase = "trimmed"
	await _frames(1800)
	city._sampling = false
	city._phase = ""

	mem = city.world.get_memory_report()
	var rep: Dictionary = city.registry.report()
	var isl: Dictionary = city.islands.report()
	var toppled := 0
	for b in city.registry.buildings:
		if b.toppled:
			toppled += 1
	# The arbiter (AIPlan R14): the AI stepped down while the city came apart,
	# and back up once it was quiet again.
	var ladder := ""
	for ph in ["under fire", "damage queue draining", "collapsing", "settled", "trimmed"]:
		ladder += "%s %d (tick %.1f ms)  " % [ph, int(city._ai_phase_level.get(ph, 0)),
				float(city._ai_phase_level.get("tick:" + ph, 0.0)) / maxi(int(city._ai_phase_level.get("n:" + ph, 0)), 1)]
	print("[stress] AI ladder, deepest level per phase: %s-> now %d (deepest %d); AI sync+run %.2f ms a tick" % [
			ladder, city.ai_sched.get_level(), city.ai_sched.get_max_level_seen(),
			float(city._prof_sum.get("ai", 0.0)) / maxi(city._tick_samples, 1)])
	if city.budget != null:
		print("[stress] agents: %d smart, %d directed, %d swarm row(s); %d soldier(s), %d flyer(s), %d animal(s), %d promoted, %d demoted; budget %.2f ms a tick, swarm %.2f ms" % [
					int(city.budget.counts.smart), int(city.budget.counts.directed), city.swarm.alive(),
					_many.soldiers, _many.flyers, _many.animals, city.swarm.promoted, city.swarm.demoted,
					city.budget.last_ms, city.swarm.tick_ms()])
	# Stepped down when the collapse was heavy enough to call for it -- a run of
	# AI_HEAVY_TICKS ticks over AI_HEAVY_MS -- and back up after, either way.
	# The check used to require a step down, full stop, and failed once the
	# collapse itself got cheap enough never to need one (its worst ticks well
	# under 8 ms, one at a time): the arbiter doing nothing was the right answer.
	# The ladder itself, driven by a load that does call for it, is
	# tools/ai_world_probe.gd's.
	var called_for := city._ai_heavy_run_max >= City.AI_HEAVY_TICKS
	print("[stress] destruction for the arbiter: worst tick %.1f ms, longest run over %.0f ms %d tick(s) -- a step down %s" % [
			city._ai_destruction_peak, City.AI_HEAVY_MS, city._ai_heavy_run_max,
			"was called for" if called_for else "was not called for"])
	print("[stress] %s  the AI stepped down under the collapse if it was heavy, and back up after" % (
			"ok   " if (city.ai_sched.get_max_level_seen() >= 1 or not called_for)
					and city.ai_sched.get_level() == 0
			else "FAIL "))
	print("[stress] %d shot(s) at %d building(s); %d meant to come down" % [
			shots, target, toppled_on_purpose])
	print("[stress] %d of %d buildings took a hit, %d actually toppled" % [
			rep.damaged, city.registry.buildings.size(), toppled])
	if queue_left > 0:
		print("[stress] WARNING: %d hit(s) never left the queue -- the numbers below were taken"
				% queue_left)
		print("[stress]          under a permanent backlog and understate how many buildings")
		print("[stress]          were involved. Fire a smaller pattern or raise DAMAGE_PER_TICK.")
	elif rep.damaged < city.registry.buildings.size():
		print("[stress] note: %d building(s) took no damage -- the queue drained, so the hits"
				% (city.registry.buildings.size() - rep.damaged))
		print("[stress]       missed rather than being dropped.")
	print("[stress] %d materialised, %.1f MB across %d chunks" % [
			rep.materialised, float(mem.total_bytes) / 1048576.0, int(mem.chunks)])
	print("[stress]   occupancy %.1f MB, blocks %.1f MB, bake %.1f MB" % [
			float(mem.occupancy_bytes) / 1048576.0, float(mem.block_bytes) / 1048576.0,
			float(int(mem.total_bytes) - int(mem.occupancy_bytes) - int(mem.block_bytes)) / 1048576.0])
	print("[stress] collision: %s" % _collision_report())
	print("[stress] islands %d (%d settled, %d small), %d gone coarse for distance, %d split(s)" % [
			isl.islands, isl.settled, isl.disposable, isl.dropped, isl.splits])
	print("[stress] coarse stand-ins: %d built (worst %.2f ms, %d vertices in all), %d left by pieces put to sleep" % [
			int(isl.coarse_built), float(isl.coarse_worst_ms), int(isl.coarse_verts), int(isl.stand_ins)])
	print("[stress] small pieces deleted where they came loose: %d brick(s) beyond %.0f m, %d unseen, %d of furniture"
			% [int(city.islands.report().tiny_deleted), IslandManager.SMALL_KEEP_RANGE,
			int(city.islands.report().discarded), int(city.islands.report().furniture_deleted)])
	print("[stress] bands built %d: C++ %.0f ms, upload %.0f ms, worst one %.1f ms" % [
			city._band_builds, city._band_cpp_ms, city._band_upload_ms, city._band_worst])
	print("[stress] near tier: %s" % city.brick_near.report())
	print("[stress] debris cap: small <=%d, large <=%d, total <=%d -- deleted %d, slept %d, peak %d over" % [
			city.islands.small_live_max, city.islands.large_live_max, city.islands.total_live_max,
			city.islands.cap_deleted, city.islands.cap_slept, maxi(city.islands.cap_worst_over, 0)])
	print("[stress] asleep %d piece(s) holding %d block(s) in %.1f KB (%d slept, %d woken)" % [
			isl.dormant, isl.dormant_blocks, float(isl.dormant_bytes) / 1024.0,
			isl.slept, isl.woken])
	print("[stress] invisible pieces: %d went blind, worst %d tick(s), mean %.1f, biggest %d bricks" % [
			isl.blind_count, isl.blind_worst, isl.blind_mean, isl.meshless_worst_blocks])
	print("[stress] breaks %d (%d had to tear a band), %d impact(s) loosening %d block(s)" % [
			isl.breaks, isl.band_breaks, isl.impacts, isl.impact_blocks])
	print("[stress] de-meshed %d, re-meshed %d, in %.0f ms" % [
			city._demeshed, city._remeshed_back, city._demesh_ms])
	print("[stress] trimmed %d building(s) in %.0f ms (%.1f ms each) = demat %.0f + free %.0f + shell %.0f" % [
			city._trims, city._trim_ms, city._trim_ms / maxf(city._trims, 1),
			city._trim_split.demat, city._trim_split.free, city._trim_split.shell])
	print("[stress] peak %.1f MB with %d resident; after trimming %.1f MB with %d" % [
			peak_mb, peak_res, float(mem.total_bytes) / 1048576.0, rep.materialised])
	print("[stress] interior pieces a blast reached %d (%d laid as bricks) in %.0f ms" % [
			city._pieces_hit, city._pieces_laid, city._pieces_hit_ms])
	print("[stress] promotions: %d in %.0f ms (%.1f ms each), %d of them for somebody walking up" % [
			city._promotions, city._promote_ms, city._promote_ms / maxf(city._promotions, 1), city._near_promotions])
	if city._frame_samples > 0:
		print("[stress] whole run: mean %.1f ms, worst %.1f ms, %d of %d over 33.3 ms (%.1f%%)" % [
			city._frame_sum / city._frame_samples, city._frame_worst, city._frames_over_30, city._frame_samples,
			float(city._frames_over_30) / city._frame_samples * 100.0])
	_report_phases()
	_report_profile()
	city.get_tree().quit()

## A bite out of the bottom of one side. The centre of mass leaves its support
## and the building comes down. A symmetric ring just lowers it onto what is
## left and nothing falls.
func _stress_topple(b) -> int:
	var w: float = b.recipe.footprint_x * City.STUD
	var d: float = b.recipe.footprint_z * City.STUD
	var fired := 0
	for course in range(0, 8):
		var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * City.PLATE
		var px := 0.3
		while px < w * 0.55:
			var pz := 0.3
			while pz < d:
				city._blast(b.xform.origin + Vector3(px, y, pz), 1.5)
				fired += 1
				pz += 2.0
			px += 2.0
	return fired

## Damage without demolition: a shallow bite out of one wall, high enough up
## that removing the mass makes the building MORE stable rather than less.
##
## Eight hits, because the damage queue drains eight a tick and this pass fires
## at one building a frame -- so the queue stays level instead of growing. That
## is the whole difference between measuring a city and measuring a backlog.
func _stress_wound(b) -> int:
	var w: float = b.recipe.footprint_x * City.STUD
	var d: float = b.recipe.footprint_z * City.STUD
	var courses: int = b.recipe.courses
	var fired := 0
	# Two courses, two thirds of the way up.
	for i in 2:
		var course: int = maxi(1, int(courses * 0.66) + i)
		var y := (1 + course * TowerRecipe.PLATES_PER_COURSE) * City.PLATE
		# Four points across one face, and only a quarter of the way in, so the
		# opposite wall and the core are untouched.
		for j in 4:
			var pz: float = d * (0.15 + 0.7 * float(j) / 3.0)
			city._blast(b.xform.origin + Vector3(w * 0.12, y, pz), 1.3)
			fired += 1
	return fired

## The de-mesh tier, there and back.
##
## Dropping a building's mesh is only half a feature. The half that breaks
## silently is the return: walk away, walk back, and the building has to be
## bricks again -- with its damage still in them. A building stuck as a shell
## forever looks exactly like a building that was never damaged.
func _run_lod_pass() -> void:
	print("[lod] de-mesh and back")
	var target := city.registry.get_building(0)
	var aim: Vector3 = target.xform.origin + Vector3(
			target.recipe.footprint_x * City.STUD * 0.5,
			target.recipe.courses * TowerRecipe.PLATES_PER_COURSE * City.PLATE * 0.5,
			target.recipe.footprint_z * City.STUD * 0.5)

	# An Array, not an int: a GDScript lambda captures locals BY VALUE, so
	# `failures += 1` inside one updates a copy and the probe reports PASS over
	# its own FAIL lines. The array is captured by reference.
	var failures := [0]
	var check := func(label: String, cond: bool, detail: String) -> void:
		if cond:
			print("  ok    %s  %s" % [label, detail])
		else:
			failures[0] += 1
			print("  FAIL  %s  %s" % [label, detail])

	# Stand close and shoot it.
	city.camera.global_position = aim + Vector3(0.0, 0.0, -40.0)
	city.camera.look_at(aim, Vector3.UP)
	await _frames(20)
	city._fire(1.6)
	var guard := 0
	while not city._damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)

	var b := city.registry.get_building(0)
	check.call("it took damage", b.is_damaged(), "")
	check.call("and is drawn as bricks", city._brick_nodes.has(0), "")
	var dead_near: int = city.world.get_dead_blocks(b.chunk).size()
	check.call("bricks are missing", dead_near > 0, "%d dead" % dead_near)

	# Walk away, past DEMESH_RANGE + hysteresis, and POLL for the de-mesh rather
	# than sleeping a fixed time. _trim_quiet is a deeper tier on the same
	# buildings -- TRIM_RADIUS (90 m) is inside DEMESH_RANGE (110 m) -- so a
	# fixed wait long enough to be safe is also long enough for the trim to fire
	# and take the chunk away, which reads as the de-mesh tier failing when it
	# is the trim working.
	city.camera.global_position = aim + Vector3(0.0, 0.0, -200.0)
	city.camera.look_at(aim, Vector3.UP)
	var waited := 0
	while city._brick_nodes.has(0) and waited < 600:
		await _frames(1)
		waited += 1

	b = city.registry.get_building(0)
	check.call("mesh dropped", not city._brick_nodes.has(0), "after %d frame(s)" % waited)
	check.call("still resident", b.is_materialised(), "")
	check.call("drawn as a shell instead", city._shells.has(0), "")
	check.call("damage still recorded", _dead_count(0) == dead_near,
			"%d dead" % _dead_count(0))

	# A shot from out here still has to land, on real bricks. Aimed WELL AWAY
	# from the first hole: firing at the same point again destroys nothing
	# because everything in range of it is already destroyed, which is the game
	# being right and the test being wrong.
	#
	# And aimed at a FLOOR SLAB rather than at a fraction of the height. The
	# walls have windows in them now, and a ray through a window is a ray out
	# of the far side of the building: the shot landed on nothing and the check
	# read it as damage not carrying to 200 m. A slab spans the whole footprint
	# and is the one band of a tower that is solid all the way across.
	var aim_high: Vector3 = _intact_aim(0)
	var before: int = _dead_count(0)
	city.camera.look_at(aim_high, Vector3.UP)
	# From whichever bearing has a clear line. The first shot knocked a piece
	# off the near wall, and a piece knocked off a building 200 m away is a
	# rigid body standing between the camera and the target: the shot lands on
	# the DEBRIS and the building takes nothing, which is the game being right
	# and the test aiming badly. Walk round until the ray reaches the building
	# itself.
	var bearings := [Vector3(0.0, 0.0, -1.0), Vector3(-1.0, 0.0, 0.0),
			Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0)]
	var clear_line := false
	for bearing in bearings:
		city.camera.global_position = aim_high + (bearing as Vector3) * 200.0
		city.camera.look_at(aim_high, Vector3.UP)
		await _frames(10)
		var look := PhysicsRayQueryParameters3D.create(city.camera.global_position,
				city.camera.global_position - city.camera.global_transform.basis.z * City.FIRE_RANGE)
		look.collision_mask = Layers.HITSCAN_MASK
		var seen := city.get_world_3d().direct_space_state.intersect_ray(look)
		# BUILDING 0, not merely something solid. "Not an island" was too weak:
		# another building's shell in front of this one is not an island
		# either, and the shot landed on that and destroyed nothing here.
		# Either of building 0's own bodies counts -- de-meshed, it is drawn
		# by a shell and collided by its bricks, and both are in the space.
		var struck_rid: RID = seen.get("rid", RID())
		if not seen.is_empty() and city._building_for_body(struck_rid) == 0:
			clear_line = true
			break
	check.call("there is a clear line to it from 200 m", clear_line, "")
	city._fire(1.6)
	guard = 0
	while not city._damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)
	var after: int = _dead_count(0)
	check.call("a shot from 200 m still destroys brick", after > before,
			"%d -> %d dead" % [before, after])

	# Walk back, and poll for the bricks to return.
	city.camera.global_position = aim + Vector3(0.0, 0.0, -40.0)
	city.camera.look_at(aim, Vector3.UP)
	waited = 0
	while not city._brick_nodes.has(0) and waited < 600:
		await _frames(1)
		waited += 1
	await _frames(20)

	b = city.registry.get_building(0)
	check.call("bricks came back", city._brick_nodes.has(0), "after %d frame(s)" % waited)
	check.call("and the shell went away", not city._shells.has(0), "")
	# The node itself holds no mesh: a building draws through its BANDS, and
	# the node is the transform they hang off. See _rebuild_bands.
	check.call("with geometry in it", _drawn_surfaces(0) > 0,
			"%d band(s) with a surface" % _drawn_surfaces(0))
	check.call("damage survived the round trip", _dead_count(0) >= after,
			"%d dead" % _dead_count(0))

	print("")
	print("[probe] PASS" if failures[0] == 0 else "[probe] FAIL — %d check(s)" % failures[0])
	city.get_tree().quit()

## How many bricks this building has lost, whether or not it is materialised.
## The registry record survives de-materialisation; the chunk does not.
func _dead_count(id: int) -> int:
	var b := city.registry.get_building(id)
	if b == null:
		return -1
	if b.is_materialised() and city.world.is_chunk_alive(b.chunk):
		return city.world.get_dead_blocks(b.chunk).size()
	return b.dead.size()

## Trees in the city (Docs/Impostors.md 8).
##
##     godot --path . scenes/city.tscn -- --terrain --trees
##
## They are there, drawn by their sets and nothing else; one materialised
## whole stands up on its own; one shot through the trunk comes down.
func _run_tree_pass() -> void:
	print("[trees] brick trees on the ground")
	await _frames(30)
	_gate_ok("trees were placed", city._trees_placed > 0, "%d" % city._trees_placed)
	if city._trees_placed == 0:
		print("[trees] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1)
		return
	# The nearest tree to the middle of the city, and the camera by it.
	var trees: Array = city._inst_handle.keys()
	var pick: int = trees[0]
	var best := INF
	for id in trees:
		var d := city.registry.get_building(id).xform.origin.length()
		if d < best:
			best = d
			pick = id
	var tb := city.registry.get_building(pick)
	var base := tb.xform * (city.registry.local_box(pick).get_center() * Vector3(1, 0, 1))
	city.camera.global_position = base + Vector3(10.0, 5.0, 14.0)
	city.camera.look_at(base + Vector3(0.0, 3.0, 0.0), Vector3.UP)
	await _far_settle()
	for i in 20:
		await RenderingServer.frame_post_draw
	var near := 0
	var far := 0
	for s in city._inst_sets.values():
		near += (s as ImpostorLod).near_count
		far += (s as ImpostorLod).far_count
	var meshed := 0
	for id in trees:
		if city._shells.has(id) and (city._shells[id] as MeshInstance3D).mesh != null:
			meshed += 1
	print("[trees] %d trees in %d kinds: %d drawn as bricks, %d as cards; %d with a shell mesh" % [
		city._trees_placed, city._inst_sets.size(), near, far, meshed])
	# Counted by copy, not by buffer: a tree crossing the mesh-to-card band is
	# in both buffers, dithered into itself.
	var drawn := 0
	for id in trees:
		var tset: ImpostorLod = city._inst_sets[city._inst_key(city.registry.get_building(id))]
		if tset.is_drawn(int(city._inst_handle[id])):
			drawn += 1
	_gate_ok("every tree is drawn by its set", drawn == city._trees_placed,
			"%d of %d" % [drawn, city._trees_placed])
	_gate_ok("  and none by a shell mesh of its own", meshed == 0)
	var baked := 0
	for s in city._inst_sets.values():
		if not (s as ImpostorLod).bake.is_empty():
			baked += 1
	_gate_ok("every kind has its impostor baked", baked == city._inst_sets.size(),
			"%d of %d" % [baked, city._inst_sets.size()])
	_gate_ok("a tree in reach has collision", city._shell_bodies.has(pick))
	await _save("trees_near")

	# Materialised whole, it has to stand: the canopy rests on the trunk.
	var chunk := city._promote(pick)
	await _frames(90)
	var alive := city.world.get_alive_block_count(chunk) if chunk >= 0 else -1
	_gate_ok("a tree materialised whole stands", chunk >= 0 and not tb.toppled
			and alive == tb.build.size(), "%d of %d bricks, toppled %s" % [
				alive, tb.build.size(), tb.toppled])
	_gate_ok("  and its copy is not drawn over its bricks",
			not (city._inst_sets[city._inst_key(tb)] as ImpostorLod).is_drawn(int(city._inst_handle[pick])))

	# Shot through the trunk, low: it comes down.
	var islands_before := city.islands.islands.size()
	city._blast(base + Vector3(0.35, 0.6, 0.35), 0.9)
	var fell := false
	for i in 240:
		await RenderingServer.frame_post_draw
		if tb.toppled or city.islands.islands.size() > islands_before:
			fell = true
			break
	await _save("trees_shot")
	_gate_ok("a tree shot through the trunk comes down", fell,
			"toppled %s, islands %d -> %d" % [tb.toppled, islands_before, city.islands.islands.size()])

	# From the edge of the city: the cards.
	city.camera.global_position = base + Vector3(0.0, 40.0, 160.0)
	city.camera.look_at(base, Vector3.UP)
	await _far_settle()
	for i in 20:
		await RenderingServer.frame_post_draw
	await _save("trees_far")
	print("[trees] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## The far city's gate (Docs/Impostors.md, Stage 1).
##
##     godot --path . scenes/big_city.tscn -- --far --buildings=150
##
## Every building is drawn by exactly one thing at every distance; a damaged
## building out past SHELL_RANGE keeps a shell that shows the damage, with no
## body, and a shot still lands on it; walking back in gives the body back.
func _run_far_pass() -> void:
	print("[far] the city past SHELL_RANGE")
	# Outside the corner, low enough to see a skyline rather than a map. The
	# grid's last tower: the big city's wide buildings are rows past it.
	var last := city.registry.buildings.size() - 1
	while last > 0 and city._wide_ids.has(last):
		last -= 1
	var span := city._world_box(city.registry.buildings[last]).end
	var corner := Vector3(-120.0, 40.0, -120.0)
	city.camera.global_position = corner
	city.camera.look_at(Vector3(span.x, 0.0, span.z) * 0.5, Vector3.UP)
	await _far_settle()

	var here := city.camera.global_position
	var undrawn := 0
	var twice := 0
	var past := 0
	for b in city.registry.buildings:
		if b.toppled or b.is_materialised():
			continue
		if b.xform.origin.distance_to(here) > City.SHELL_RANGE + City.SHELL_HYSTERESIS:
			past += 1
		# A coarse shell the far box draws has no mesh: that is one drawer.
		var shell: bool = city._shells.has(b.id) and not city._shell_box.has(b.id)
		var on_far: bool = city._far_on.has(b.id)
		if city._shell_box.has(b.id) and (city._shells[b.id] as MeshInstance3D).mesh != null:
			twice += 1
		# A box under a banded shell that is fading (Stage 5) is what the
		# shell blends over: one building drawn, not two.
		if shell and on_far and float(city._far_fade.get(b.id, 0.0)) == 0.0:
			twice += 1
		elif not shell and not on_far:
			undrawn += 1
	print("[far] %d buildings, %d past the shell range, %d shells, %d far boxes" % [
		city.registry.buildings.size(), past, city._shells.size(), city._far_on.size()])
	_gate_ok("there is a far city to draw", past > 0)
	_gate_ok("every building past the shell range is a far box", city._far_on.size() >= past,
			"%d boxes for %d" % [city._far_on.size(), past])
	var boxed := 0
	var coarse_bodies := 0
	for id in city._shell_box:
		boxed += 1
		if city._shell_bodies.has(id):
			coarse_bodies += 1
	print("[far] %d coarse shells drawn by the far box" % boxed)
	_gate_ok("the coarse tier is drawn by the far box", boxed > 0)
	_gate_ok("  and keeps its collision", coarse_bodies == boxed,
			"%d of %d" % [coarse_bodies, boxed])
	_gate_ok("no building is left undrawn", undrawn == 0, "%d undrawn" % undrawn)
	_gate_ok("no building is drawn twice", twice == 0, "%d twice" % twice)
	await _save("far_skyline")
	if city._far_on.is_empty():
		# Nothing out there to shoot: a city too small for this pass.
		print("[far] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
		city.get_tree().quit(1)
		return

	# The farthest far box, its top blown off and left to settle the way the
	# trim leaves one.
	var far_id := -1
	var far_d := 0.0
	for id in city._far_on:
		# Towers, as this was written for (CollapseNext item 25).
		if city._wide_ids.has(id):
			continue
		var d := city.registry.get_building(id).xform.origin.distance_to(here)
		if d > far_d:
			far_d = d
			far_id = id
	var fb := city.registry.get_building(far_id)
	var box := city.registry.local_box(far_id)
	city._promote(far_id)
	await _frames(20)
	# A hole in the front wall low down, and the crown taken off.
	city.registry.damage(far_id, fb.xform * (box.position + box.size * Vector3(0.5, 0.3, 0.0)), 2.0)
	for f in [0.1, 0.3, 0.5, 0.7, 0.9]:
		for g in [0.1, 0.3, 0.5, 0.7, 0.9]:
			for h in [0.86, 0.93, 1.0]:
				city.registry.damage(far_id, fb.xform * (box.position + box.size * Vector3(f, h, g)), 6.0)
	await _frames(2)
	city._demote(far_id, far_d)
	await _far_settle()
	print("[far] shot building %d at %.0f m: %d band(s) damaged" % [
		far_id, far_d, fb.damage_profile.size()])
	_gate_ok("a damaged far building is a far box", city._far_on.has(far_id)
			and not city._shells.has(far_id))
	_gate_ok("  with its damage in a row of the texture", city._far_dmg_row.has(far_id)
			and city._far_dmg_tex != null)
	var centre := fb.xform * (box.position + box.size * Vector3(0.5, 0.5, 0.5))
	# From straight above it, so no nearer building stands in the way.
	var hit := city._ray_recipes(centre + Vector3(0.0, box.size.y + 30.0, 0.0), centre)
	_gate_ok("  a shot at it still lands", int(hit.get("building", -1)) == far_id,
			str(hit))

	# Docs/Impostors.md Stage 3: the blown-off top reads from every range.
	# From outside the city, on the line from its middle through this building,
	# so nothing nearer stands in the way.
	var middle := Vector3.ZERO
	for ob in city.registry.buildings:
		middle += ob.xform.origin
	middle /= float(city.registry.buildings.size())
	var front := fb.xform * (box.position + box.size * Vector3(0.5, 0.6, 0.5))
	var out := Vector3(front.x - middle.x, 0.0, front.z - middle.z).normalized()
	for dist in [130.0, 300.0, 1000.0]:
		city.camera.global_position = front + out * dist + Vector3(0.0, dist * 0.08, 0.0)
		city.camera.look_at(front, Vector3.UP)
		await _far_settle()
		var drawn := ("far box" + (" for its coarse shell" if city._shell_box.has(far_id) else "") if city._far_on.has(far_id)
				else "shell" if city._shells.has(far_id) else "nothing")
		print("[far]   at %4.0f m: %s" % [dist, drawn])
		await _save_crop("far_top_%d" % int(dist), 60.0 / dist)

	# Walk up to it: inside the shell range it is a solid shell again.
	var aim := fb.xform * (box.position + box.size * 0.5)
	city.camera.global_position = aim + Vector3(0.0, 20.0, -(City.SHELL_RANGE - 80.0))
	city.camera.look_at(aim, Vector3.UP)
	await _far_settle()
	_gate_ok("closer in, it is a coarse shell with a body, drawn by the far box",
			city._shell_bodies.has(far_id) and city._shell_box.has(far_id) and city._far_on.has(far_id))
	# And inside SHELL_DETAIL_RANGE, the banded shell with its holes.
	city.camera.global_position = aim + Vector3(0.0, 0.0, -(City.SHELL_DETAIL_RANGE - 70.0))
	city.camera.look_at(aim, Vector3.UP)
	await _far_settle()
	# Its far box is still there, flagged, just inside the banded shell for
	# the shell's fade to blend over (Stage 5); inside FADE_NEAR the shell is
	# opaque and hides it.
	_gate_ok("closer still, a banded shell, its box only its crossfade", city._shells.has(far_id)
			and not city._shell_box.has(far_id) and city._shell_bodies.has(far_id)
			and (not city._far_on.has(far_id) or float(city._far_fade.get(far_id, 0.0)) > 0.0),
			"shell %s, box tier %s, body %s, far box %s, bricks %s, aim-promoted %d" % [
			city._shells.has(far_id), city._shell_box.has(far_id), city._shell_bodies.has(far_id),
			city._far_on.has(far_id), fb.is_materialised(), city.aim_promotions])

	# Stage 4: player builds out there are cards, one bake for identical ones.
	var tower := BuildRecipe.load_from(BuildRecipe.shipped("watchtower"))
	var far_at := here + Vector3(-600.0, 0.0, -600.0)
	var b1 := city.registry.register_build(tower, Transform3D(Basis(), BrickWorld.grid_to_world(
			Vector3i(int(far_at.x / City.STUD), 0, int(far_at.z / City.STUD)))))
	var b2 := city.registry.register_build(tower, Transform3D(Basis(), BrickWorld.grid_to_world(
			Vector3i(int(far_at.x / City.STUD) + 60, 0, int(far_at.z / City.STUD)))))
	city._index_building(b1)
	city._index_building(b2)
	city.camera.global_position = here
	city.camera.look_at(far_at, Vector3.UP)
	await _far_settle()
	var bb1 := city.registry.get_building(b1)
	var key := city._inst_key(bb1)
	var set_: ImpostorLod = city._inst_sets.get(key)
	_gate_ok("Stage 4: a far player build has no shell", not city._shells.has(b1) and not city._shells.has(b2))
	_gate_ok("  both are drawn by one set", set_ != null and city._inst_key(city.registry.get_building(b2)) == key
			and set_.is_drawn(int(city._inst_handle.get(b1, -1)))
			and set_.is_drawn(int(city._inst_handle.get(b2, -1))))
	var baked_guard := 0
	while set_ != null and set_.bake.is_empty() and baked_guard < 300:
		await RenderingServer.frame_post_draw
		baked_guard += 1
	_gate_ok("  as a card, baked once for both", set_ != null and not set_.bake.is_empty()
			and set_.tier_of(int(city._inst_handle[b1])) == 2)
	await _save_crop("far_builds", 0.25)
	city.camera.global_position = bb1.xform.origin + Vector3(40.0, 30.0, 150.0)
	city.camera.look_at(bb1.xform.origin, Vector3.UP)
	await _far_settle()
	_gate_ok("  closer in, its own shell and no card", city._shells.has(b1)
			and (city._shells[b1] as MeshInstance3D).mesh != null
			and not set_.is_drawn(int(city._inst_handle[b1])),
			"shell %s, mesh %s, card tier %d, %.0f m" % [city._shells.has(b1),
			city._shells.has(b1) and (city._shells[b1] as MeshInstance3D).mesh != null,
			set_.tier_of(int(city._inst_handle[b1])), bb1.xform.origin.distance_to(city.camera.global_position)])
	# Damaged, it keeps its exact shell even out there.
	var bb2 := city.registry.get_building(b2)
	city._promote(b2)
	await _frames(20)
	var lb := city.registry.local_box(b2)
	for f in [Vector3(0.5, 0.1, 0.0), Vector3(0.0, 0.1, 0.5), Vector3(0.5, 0.5, 0.5)]:
		city.registry.damage(b2, bb2.xform * (lb.position + lb.size * f), 1.5)
	await _frames(2)
	city._demote(b2, 400.0)
	city.camera.global_position = here
	city.camera.look_at(far_at, Vector3.UP)
	await _far_settle()
	print("[far]   damaged build: damaged %s, shell %s, far shell %s, card %s, bricks %s" % [
		bb2.is_damaged(), city._shells.has(b2), city._shell_far.has(b2),
		set_.is_drawn(int(city._inst_handle[b2])), bb2.is_materialised()])
	_gate_ok("  a damaged one keeps its shell out there, without the card",
			city._shells.has(b2) and city._shell_far.has(b2) and not set_.is_drawn(int(city._inst_handle[b2])))

	# Stage 5: across the fade band a banded shell and its box are both drawn,
	# the shell fading out and the box flagged to fade in.
	var mid_id := -1
	for ob in city.registry.buildings:
		if not ob.is_build() and not ob.toppled and not ob.is_materialised():
			mid_id = ob.id
			break
	var mb := city.registry.get_building(mid_id)
	var mc := city._world_box(mb).get_center()
	city.camera.global_position = mc + Vector3(0.0, 10.0, -(City.FADE_NEAR + City.FADE_FAR) * 0.5)
	city.camera.look_at(mc, Vector3.UP)
	await _far_settle()
	var banded: bool = city._shells.has(mid_id) and not city._shell_coarse.get(mid_id, true)
	var faded: bool = banded and (city._shells[mid_id] as GeometryInstance3D).visibility_range_fade_mode \
			== GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_gate_ok("Stage 5: in the fade band, a banded shell that fades out", faded,
			"banded %s" % banded)
	_gate_ok("  and its far box, flagged to fade in", city._far_on.has(mid_id)
			and float(city._far_fade.get(mid_id, 0.0)) > 0.0)
	for d in [70.0, 100.0, 125.0, 150.0]:
		city.camera.global_position = mc + Vector3(0.0, 10.0, -d)
		city.camera.look_at(mc, Vector3.UP)
		await _far_settle()
		await _save_crop("fade_%d" % int(d), 0.5)

	# The crossfade leaves no holes. It rests on how Godot fades an instance
	# (blended, over [end - margin, end + margin] from its bounds' centre);
	# if an engine update changes that, this is what fails.
	# In the middle of the band, from low down so the building stands on sky:
	#   A  the crossfade as it runs;
	#   B  the shell alone, not fading -- the reference;
	#   C  the shell fading with no box under it -- holes at the fade's rate.
	# Holes are pixels of the building far from B: the box under the blend
	# makes A nearly B, where C shows the sky through the fading shell.
	city.camera.global_position = mc + Vector3(0.0, -mc.y + 1.5, -(City.FADE_NEAR + City.FADE_FAR) * 0.5)
	city.camera.look_at(mc + Vector3(0.0, mb.recipe.courses * 0.1, 0.0), Vector3.UP)
	await _far_settle()
	var shell_mi: MeshInstance3D = city._shells.get(mid_id)
	if shell_mi != null and city._far_on.has(mid_id):
		var rect := _screen_rect(city._world_box(mb))
		var img_a := await _grab()
		var ranged: Array[GeometryInstance3D] = [shell_mi]
		for ch in shell_mi.get_children():
			if ch is GeometryInstance3D:
				ranged.append(ch)
		for g in ranged:
			g.visibility_range_end = 0.0
		var img_b := await _grab()
		for g in ranged:
			city._fade_out(g)
		city._far.visible = false
		var img_c := await _grab()
		city._far.visible = true
		var holes_a := _holes(img_a, img_b, rect)
		var holes_c := _holes(img_c, img_b, rect)
		print("[far]   crossfade: %.1f%% of the building off its reference, against %.1f%% with no box" % [
			holes_a * 100.0, holes_c * 100.0])
		# The control's floor is for the settings a pass runs on -- the menu's
		# defaults (TestWindow.use_default_settings): MSAA 2x and FXAA, under
		# which a fading shell with no box shows 4.7 % holes. It was 0.05, set
		# when passes ran on whatever was saved in Options: 8.8 % with both
		# off, 6.4 and 5.1 with one. What the check is for is the second half:
		# the crossfade is a small fraction of that, whatever it is.
		_gate_ok("Stage 5: the crossfade leaves no holes", holes_c > 0.03 and holes_a < holes_c * 0.25,
				"%.3f vs %.3f" % [holes_a, holes_c])
	else:
		_gate_ok("Stage 5: the crossfade leaves no holes", false,
				"no fading shell to look at: shell %s, far box %s, bricks %s, aim-promoted %d" % [
				shell_mi != null, city._far_on.has(mid_id), mb.is_materialised(), city.aim_promotions])

	print("[far] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## A screenshot of the middle of the view, blown up: `frac` of the screen's
## size, scaled back to full height, so a building a kilometre off is big
## enough to judge.
func _save_crop(shot_name: String, frac: float) -> void:
	await RenderingServer.frame_post_draw
	var img := city.get_viewport().get_texture().get_image()
	var full := img.get_size()
	var size := Vector2i(int(full.x * frac), int(full.y * frac))
	img = img.get_region(Rect2i(Vector2i(Vector2(full - size) / 2.0), size))
	img.resize(full.x, full.y, Image.INTERPOLATE_NEAREST)
	img.save_png("res://shots/%s.png" % shot_name)
	print("[city] shot written: %s.png" % shot_name)

## The screen rectangle a world box covers, clamped to the view.
func _screen_rect(box: AABB) -> Rect2i:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var p := box.position + box.size * Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1)
		if city.camera.is_position_behind(p):
			continue
		var s := city.camera.unproject_position(p)
		lo = lo.min(s)
		hi = hi.max(s)
	var view := Vector2(city.get_viewport().get_visible_rect().size)
	lo = lo.clamp(Vector2.ZERO, view)
	hi = hi.clamp(Vector2.ZERO, view)
	return Rect2i(Vector2i(lo), Vector2i(hi - lo))

func _grab() -> Image:
	for i in 3:
		await RenderingServer.frame_post_draw
	return city.get_viewport().get_texture().get_image()

## Share of `rect`, shrunk a little off its edges, where `img` is far from
## `ref`: a hole shows what is behind, and here that is sky.
static func _holes(img: Image, ref: Image, rect: Rect2i) -> float:
	var r := rect.grow(-floori(maxi(rect.size.x, rect.size.y) / 12.0))
	if r.size.x <= 0 or r.size.y <= 0:
		return 0.0
	var off := 0
	var n := 0
	for y in range(r.position.y, r.end.y, 2):
		for x in range(r.position.x, r.end.x, 2):
			n += 1
			var a := img.get_pixel(x, y)
			var b := ref.get_pixel(x, y)
			if absf(a.get_luminance() - b.get_luminance()) > 0.2:
				off += 1
	return float(off) / maxf(n, 1)

## Frames until the shell streamer has had a full quiet pass over the register.
func _far_settle() -> void:
	var last := -1
	var quiet := 0
	# And two whole passes of the streamer over the register: ninety quiet
	# FRAMES is a third of a second at a high frame rate, less than one pass
	# with the trees in it, and a building it had not reached yet was read as
	# having no shell.
	var from := city._stream_cursor
	for i in 1200:
		await RenderingServer.frame_post_draw
		var n := city._shells_made + city._shells_freed + city._shells_swapped + city._far_on.size() \
				+ city._shell_far.size() + city._shell_bodies.size()
		quiet = quiet + 1 if n == last else 0
		last = n
		if quiet >= 90 and city._stream_cursor - from >= city.registry.buildings.size() * 2:
			return

## How far away can a building be shot?
##
## The answer has to be "as far as you can see it", because a player who lines
## up a distant tower and fires expects a hole. The chain is: the ray needs
## something to hit, so the building needs a shell body; the hit point then goes
## through _apply_blast, which materialises whatever it lands on regardless of
## distance. So the reach is exactly the shell tier's reach, and this measures
## it rather than assuming it.
func _run_reach_pass() -> void:
	print("[reach] how far can a building be shot?")
	var target := city.registry.get_building(0)
	var aim: Vector3 = target.xform.origin + Vector3(
			target.recipe.footprint_x * City.STUD * 0.5,
			target.recipe.courses * TowerRecipe.PLATES_PER_COURSE * City.PLATE * 0.5,
			target.recipe.footprint_z * City.STUD * 0.5)

	var furthest := 0.0
	var first_miss := 0.0
	var d := 40.0
	while d <= 480.0:
		# Rebuild the target so each distance is asked the same question.
		# Order matters: dematerialise() refreshes `dead` FROM the chunk, so
		# clearing the record first and de-materialising second puts the damage
		# straight back and every distance reports a hit.
		var b := city.registry.get_building(0)
		if b.is_materialised():
			city.registry.dematerialise(0)
			if city._brick_cols.has(0):
				(city._brick_cols[0] as BuildingCollision).free_bodies()
				city._brick_cols.erase(0)
			if city._brick_nodes.has(0):
				(city._brick_nodes[0] as MeshInstance3D).queue_free()
				city._brick_nodes.erase(0)
			city._brick_meshes.erase(0)
			city._brick_index_bytes.erase(0)
			city._brick_index_width.erase(0)
			city._materialised.erase(0)
			city._dirty.erase(0)
		b.hit = false
		b.dead = PackedInt32Array()
		b.damage_profile = {}
		city._free_shell(0)

		# Stand off along -Z and look at it. The shell streamer needs a few
		# ticks to notice where the camera is before the ray has anything to
		# hit, which is itself part of the answer.
		city.camera.global_position = aim + Vector3(0.0, 0.0, -d)
		city.camera.look_at(aim, Vector3.UP)
		# _stream_shells runs every fourth tick at SHELLS_PER_TICK, so a camera
		# that has just jumped 40 m needs time for the shell tier to catch up.
		# Thirty frames was sometimes enough and sometimes not, which made this
		# probe report misses that were the test's fault rather than the game's.
		await _frames(120)

		var _sp := city.get_world_3d().direct_space_state
		var _f := city.camera.global_position
		var _t2 := _f - city.camera.global_transform.basis.z * City.FIRE_RANGE
		var _q := PhysicsRayQueryParameters3D.create(_f, _t2)
		_q.collision_mask = Layers.HITSCAN_MASK
		var _ph := _sp.intersect_ray(_q)
		var _rr := city._ray_recipes(_f, _t2)
		print("[reach]        physics %s, recipe %s" % [
				("%.0f m" % _f.distance_to(_ph.position)) if not _ph.is_empty() else "none",
				("b%d @ %.0f m" % [int(_rr.building), _f.distance_to(_rr.position)]) if not _rr.is_empty() else "none"])
		city._fire(1.6)
		var guard := 0
		while not city._damage_queue.is_empty() and guard < 120:
			await _frames(1)
			guard += 1
		await _frames(2)

		var landed: bool = city.registry.get_building(0).is_damaged()
		var shelled: bool = city._shells.has(0)
		print("[reach] %4.0f m: shell %s, damage %s" % [
				d, "yes" if shelled else "NO ", "LANDED" if landed else "missed"])
		if landed:
			furthest = d
		elif first_miss == 0.0:
			first_miss = d
		d += 40.0

	print("[reach] damage lands out to %.0f m; first miss at %.0f m (SHELL_RANGE is %.0f)" % [
			furthest, first_miss, City.SHELL_RANGE])
	city.get_tree().quit()

## Does the shaded chamfer do anything, and does it stop doing it at range?
##
## A bevel on every edge of every block would be four quads a face -- five times
## the triangles for something 13 mm wide. It is shaded instead, so the only
## test that means anything is the rendered picture: one frame with it and one
## without, differenced. The second half matters as much as the first: a
## sub-pixel highlight that does not fade out shimmers, which is the same reason
## the seam fades (spec section 2, layer lines).
func _run_chamfer_pass() -> void:
	# `-- --chamfer --cost`: what the near tier costs where it is paid --
	# shooting at, and then bringing down, a building the camera stands beside.
	# A timing run (CLAUDE.md: the editor closed), and with `--no-near` the
	# same run without the tier, to set beside it.
	if "--cost" in OS.get_cmdline_user_args():
		if "--street" in OS.get_cmdline_user_args():
			await _run_chamfer_street()
		elif "--overview" in OS.get_cmdline_user_args():
			await _run_overview()
		else:
			await _run_chamfer_cost()
		city.get_tree().quit(0)
		return
	print("[chamfer] real bevels where the camera is, none where it is not")
	var b := city.registry.get_building(0)
	var chunk := city._promote(0)
	await _frames(40)
	_gate_ok("there are real bricks to look at", chunk >= 0
			and city.world.get_alive_block_count(chunk) > 0)

	# Close enough to read a single brick: about a metre and a half off a wall,
	# square on.
	var wall: Vector3 = b.xform * Vector3(b.recipe.footprint_x * City.STUD * 0.5, 2.2, 0.0)
	city.camera.global_position = wall - Vector3(0.0, 0.0, 1.6)
	city.camera.look_at(wall, Vector3.UP)
	await _frames(10)

	# The wall in front of the camera is drawn with its chamfered mesh
	# (BrickNear), and the studs within reach as studs.
	var near_off := await _capture_chamfer(false, "chamfer_off")
	_gate_ok("with the near tier off, nothing is chamfered", city.brick_near.chamfered_bands == 0)
	var near_on := await _capture_chamfer(true, "chamfer_on")
	_gate_ok("a wall a metre and a half off is drawn chamfered", city.brick_near.chamfered_bands > 0,
			"%d bands, %d triangles, %d studs; worst step %.2f ms" % [city.brick_near.chamfered_bands,
				city.brick_near.chamfered_tris, city.brick_near.stud_instances, city.brick_near.worst_step_ms])
	_gate_ok("and its exposed studs are geometry", city.brick_near.stud_instances > 0,
			"%d" % city.brick_near.stud_instances)
	# Their shadows are the flat meshes' (PerfCaps.md 2.2): the bevel is not
	# there at shadow resolution, its triangles would be drawn in every cascade.
	var shadow_faults: Vector2i = city.brick_near.shadow_faults()
	_gate_ok("the chamfered bands cast their flat mesh's shadow, not their own",
			shadow_faults == Vector2i.ZERO,
			"%d chamfered meshes casting, %d bands without a flat shadow" % [shadow_faults.x,
				shadow_faults.y])
	var near_diff := _image_difference(near_off, near_on)
	_gate_ok("up close, the bevel changes the picture", near_diff > 0.01,
			"%.1f%% of sampled pixels" % (near_diff * 100.0))
	_gate_ok("but does not repaint the whole wall -- it is edges, not a tint",
			near_diff < 0.75, "%.1f%%" % (near_diff * 100.0))

	# Pictures, not checks: a roof's edge from a stride back on it, as a
	# player stands there, and a storey's ceiling from the room under it.
	var space := city.get_world_3d().direct_space_state
	var inward: Vector3 = b.xform.basis * Vector3(0.0, 0.0, 1.0)
	var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			wall + inward * 1.2 + Vector3.UP * 200.0, wall + inward * 1.2 + Vector3.DOWN * 50.0))
	if not down.is_empty():
		var roof: Vector3 = down.position
		city.camera.global_position = roof + Vector3.UP * 0.55
		city.camera.look_at(roof - inward * 1.25 + Vector3.DOWN * 0.1, Vector3.UP)
		await _frames(30)
		city.brick_near.settle(city.camera.global_position)
		await _frames(6)
		await _save("chamfer_roof")
	var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			wall + inward * 2.0 + Vector3.DOWN * 0.8, wall + inward * 2.0 + Vector3.UP * 20.0))
	if not up.is_empty():
		var ceil_at: Vector3 = up.position
		city.camera.global_position = ceil_at + Vector3.DOWN * 0.7 + inward * 0.6
		city.camera.look_at(ceil_at + inward * -0.4, Vector3.UP)
		await _frames(30)
		city.brick_near.settle(city.camera.global_position)
		await _frames(6)
		await _save("chamfer_ceiling")
	city.camera.global_position = wall - Vector3(0.0, 0.0, 1.6)
	city.camera.look_at(wall, Vector3.UP)
	await _frames(10)

	# Shot at: the chamfered bands are patched as the flat ones are. What their
	# index buffers draw is read back and set against the bricks left alive.
	var before: Dictionary = city.brick_near.audit()
	city._blast(wall + Vector3(0.6, 0.3, 0.2), 1.1)
	await _frames(20)
	city.brick_near.settle(city.camera.global_position)
	await _frames(4)
	var after: Dictionary = city.brick_near.audit()
	_gate_ok("a hit takes triangles out of the chamfered bands", int(after.bands) > 0
			and int(after.drawn) != int(before.drawn),
			"%d drawn before, %d after" % [before.drawn, after.drawn])
	_gate_ok("and they draw exactly the bricks left", int(after.drawn) == int(after.wanted),
			"%d drawn, %d wanted, over %d bands" % [after.drawn, after.wanted, after.bands])
	await _save("chamfer_hit")

	# The cap (Options > Video): its budgets squeezed to nothing, it still lets
	# one band of each in -- and that one is the wall in front of the camera.
	var cap_was := [BrickNear.cap_enabled, BrickNear.max_tris, BrickNear.max_studs]
	BrickNear.cap_enabled = true
	BrickNear.max_tris = 1
	BrickNear.max_studs = 1
	await _frames(4)
	city.brick_near.settle(city.camera.global_position)
	await _frames(4)
	var held: Vector2i = city.brick_near.held()
	_gate_ok("with the cap's budgets at nothing, one band is chamfered and one has stud geometry",
			held.x == 1 and held.y <= 1 and city.brick_near.chamfered_bands == 1,
			"%d chamfered (%d held), %d with stud geometry" % [city.brick_near.chamfered_bands,
				held.x, held.y])
	var ahead := city.camera.global_position + (-city.camera.global_basis.z) * 1.6
	var ahead_near := _near_band_at(ahead)
	_gate_ok("and it is the wall in front", ahead_near)
	# Studs of any kind by count (max_card_bands): squeezed to two, two bands
	# hold studs, and studs are still drawn -- the best placed keep theirs.
	var cards_was := BrickNear.max_card_bands
	BrickNear.max_card_bands = 2
	await _frames(4)
	city.brick_near.settle(city.camera.global_position)
	await _frames(4)
	_gate_ok("with studded bands capped at two, two bands hold studs, and studs are drawn",
			city.brick_near.held_cards() <= 2 and city.brick_near.stud_instances > 0,
			"%d bands with studs, %d studs" % [city.brick_near.held_cards(), city.brick_near.stud_instances])
	BrickNear.max_card_bands = cards_was
	BrickNear.cap_enabled = cap_was[0]
	BrickNear.max_tris = cap_was[1]
	BrickNear.max_studs = cap_was[2]

	# And from across the street there is none: at that size it is noise, and
	# it is not paid for.
	city.camera.global_position = wall - Vector3(0.0, -6.0, 110.0)
	city.camera.look_at(wall, Vector3.UP)
	await _frames(10)
	var far_off := await _capture_chamfer(false, "")
	var far_on := await _capture_chamfer(true, "")
	_gate_ok("at a hundred metres no band is chamfered", city.brick_near.chamfered_bands == 0
			and city.brick_near.stud_instances == 0,
			"%d bands, %d studs" % [city.brick_near.chamfered_bands, city.brick_near.stud_instances])
	var far_diff := _image_difference(far_off, far_on)
	_gate_ok("and the picture is the same either way", far_diff < 0.01,
			"%.2f%% of sampled pixels" % (far_diff * 100.0))

	print("\n%d passed, %d failed" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Whether a chamfered band of a building is drawn round `at` (a point on its
## wall): any band whose box holds it, a few centimetres either way.
func _near_band_at(at: Vector3) -> bool:
	for node in _bands_round(at):
		if city.brick_near.is_near(node):
			return true
	return false

func _bands_round(at: Vector3) -> Array:
	var out := []
	for n in city.get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = n
		if mi.mesh == null or not mi.is_inside_tree():
			continue
		var local := mi.global_transform.affine_inverse() * at
		if mi.mesh.get_aabb().grow(0.1).has_point(local):
			out.append(mi)
	return out

## What a look out over the city costs the GPU, and what of it is what
## (PerfCaps.md 5). From the street walk's start, at eye height: eight
## directions, then the dearest one with each kind of thing hidden in turn.
func _run_overview() -> void:
	var view := city.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(view, true)
	var b := city.registry.get_building(0)
	for i in mini(city.registry.buildings.size(), 12):
		city._promote(i)
	await _frames(120)
	var start: Vector3 = b.xform * Vector3(-4.0, 0.0, -3.0)
	start.y = DebugCamera.EYE_HEIGHT
	var along: Vector3 = (b.xform.basis * Vector3.RIGHT).normalized()
	city.camera.global_position = start
	print("[overview] %d buildings, from %s" % [city.registry.buildings.size(), str(start)])
	var worst_dir := Vector3.ZERO
	var worst_gpu := 0.0
	for k in 8:
		var dir := along.rotated(Vector3.UP, TAU * float(k) / 8.0)
		city.camera.look_at(start + dir, Vector3.UP)
		var m := await _overview_measure()
		print("[overview]   yaw %3d: %s" % [k * 45, _overview_line(m)])
		if float(m.gpu) > worst_gpu:
			worst_gpu = float(m.gpu)
			worst_dir = dir
	city.camera.look_at(start + worst_dir, Vector3.UP)
	var base := await _overview_measure()
	print("[overview] dearest view: %s" % _overview_line(base))
	# The sun's shadow, off.
	if city._sun != null:
		city._sun.shadow_enabled = false
		print("[overview]   no sun shadow: %s" % _overview_line(await _overview_measure()))
		city._sun.shadow_enabled = true
	# Each kind of thing among the city's children, hidden in turn. A kind is
	# a child's class and its name without digits.
	var kinds := {}
	for c in city.get_children():
		if not (c is Node3D) or not (c as Node3D).visible or c == city.camera:
			continue
		var key := "%s %s" % [c.get_class(), _overview_kind(c.name)]
		if not kinds.has(key):
			kinds[key] = []
		(kinds[key] as Array).append(c)
	var rows := []
	for key in kinds:
		var nodes: Array = kinds[key]
		for n in nodes:
			(n as Node3D).visible = false
		var m := await _overview_measure()
		for n in nodes:
			(n as Node3D).visible = true
		rows.append([float(base.gpu) - float(m.gpu), key, nodes.size(), m])
	rows.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
	for r in rows:
		print("[overview]   without %-44s (x%3d): GPU %5.2f ms less; %s" % [r[1], r[2], r[0],
				_overview_line(r[3])])
	# The far tier for buildings in bricks (_tend_far_coarse): off, then on.
	City.far_coarse_enabled = false
	await _frames(30)
	var off := await _overview_measure()
	var img_off := city.get_viewport().get_texture().get_image()
	await _save("overview_bands")
	City.far_coarse_enabled = true
	for i in 600:
		await city.get_tree().physics_frame
		if city._far_coarse_jobs.is_empty() and i > 60:
			break
	var on := await _overview_measure()
	var img_on := city.get_viewport().get_texture().get_image()
	await _save("overview_coarse")
	print("[overview] far tier off: %s" % _overview_line(off))
	print("[overview] far tier on (%d buildings coarse): %s" % [city._far_coarse.size(),
			_overview_line(on)])
	print("[overview]   picture differs at %.2f%% of sampled pixels" % [
			_image_difference(img_off, img_on) * 100.0])
	_gate_ok("far buildings in bricks are drawn coarse, and the picture is the same",
			not city._far_coarse.is_empty() and _image_difference(img_off, img_on) < 0.01,
			"%d coarse" % city._far_coarse.size())
	# A hit on one: its bands at once, coarse again once quiet.
	if not city._far_coarse.is_empty():
		var hit_id: int = city._far_coarse.keys()[0]
		var hb := city.registry.get_building(hit_id)
		var box := CityPlacer.box_of(hb)
		city._blast(Vector3(box.position.x, box.position.y + 3.0, box.get_center().z), 1.5)
		var back := false
		for i in 60:
			await city.get_tree().physics_frame
			if not city._far_coarse.has(hit_id):
				back = true
				break
		var bands_shown := true
		for band in city._brick_bands.get(hit_id, []):
			if is_instance_valid(band) and not (band as Node3D).visible:
				bands_shown = false
		_gate_ok("a hit on a far building draws its bricks again at once", back and bands_shown)
		var again := false
		for i in 300:
			await city.get_tree().physics_frame
			if city._far_coarse.has(hit_id):
				again = true
				break
		_gate_ok("and it goes coarse again once it is quiet", again)
	print("[overview] %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])

func _overview_kind(n: String) -> String:
	var out := ""
	for ch in n:
		if not ch.is_valid_int():
			out += ch
	return out

func _overview_measure() -> Dictionary:
	var view := city.get_viewport().get_viewport_rid()
	await _frames(20)
	var gpu := 0.0
	var n := 40
	for i in n:
		await city.get_tree().process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(view)
	return {"gpu": gpu / n,
		"draws": RenderingServer.viewport_get_render_info(view, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.viewport_get_render_info(view, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
				RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
		"tris": RenderingServer.viewport_get_render_info(view, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
		"sh_draws": RenderingServer.viewport_get_render_info(view, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"sh_tris": RenderingServer.viewport_get_render_info(view, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)}

func _overview_line(m: Dictionary) -> String:
	return "GPU %5.2f ms, %4d draws, %4d objects, %5.0fk tris; shadows %4d draws, %5.0fk tris" % [
			float(m.gpu), int(m.draws), int(m.objects), float(m.tris) / 1000.0,
			int(m.sh_draws), float(m.sh_tris) / 1000.0]

## Frame times while a building six metres from the camera is shot at and then
## cut down, with whatever near tier the run has (`--no-cap`: the cap off).
func _run_chamfer_cost() -> void:
	# A test window takes the menu's defaults once it is up, after this starts:
	# the flag is set again once the city has settled (_cap_arg).
	_cap_arg()
	@warning_ignore("integer_division")
	print("[chamfer] cost, near tier %s, cap %s" % ["ON" if BrickNear.enabled else "OFF (--no-near)",
			"on (%dk triangles, %d studs)" % [BrickNear.max_tris / 1000, BrickNear.max_studs]
			if BrickNear.cap_enabled else "OFF (--no-cap)"])
	# The renderer's own clock as well as the frame's: a frame is held to the
	# display's 16.6 ms whatever it cost to draw.
	RenderingServer.viewport_set_measure_render_time(city.get_viewport().get_viewport_rid(), true)
	var b := city.registry.get_building(0)
	var chunk := city._promote(0)
	await _frames(60)
	_cap_arg()
	var fx: float = b.recipe.footprint_x * City.STUD
	var wall: Vector3 = b.xform * Vector3(fx * 0.5, 2.6, 0.0)
	city.camera.global_position = wall - Vector3(1.5, -0.4, 6.0)
	city.camera.look_at(wall, Vector3.UP)
	await _frames(10)
	city.brick_near.settle(city.camera.global_position)
	await _frames(30)
	print("[chamfer]   standing: %d bricks, %d bands; %s" % [city.world.get_alive_block_count(chunk),
			city.world.get_chunk_sections(chunk), city.brick_near.report()])
	var idle: Array = await _frame_times(120)
	print("[chamfer]   looking at it: %s" % _frame_line(idle))

	# Twelve shots into the wall, one every five frames.
	var hits := []
	for i in 12:
		city._blast(wall + Vector3(-1.5 + 0.5 * float(i % 6), -0.8 + 0.9 * floorf(float(i) / 6.0), 0.3), 0.9)
		hits.append_array(await _frame_times(5))
	hits.append_array(await _frame_times(30))
	print("[chamfer]   twelve shots: %s" % _frame_line(hits))
	print("[chamfer]   %s" % city.brick_near.report())

	# And down: its bottom courses cut through from the camera's side.
	for i in 10:
		city._blast(b.xform * Vector3(fx * (0.05 + 0.1 * float(i)), 0.9, 0.3), 2.2)
	var fall: Array = await _frame_times(360)
	print("[chamfer]   brought down: %s" % _frame_line(fall))
	print("[chamfer]   %s" % city.brick_near.report())
	await _save("chamfer_cost_%s" % ("near" if BrickNear.enabled else "flat"))

## `--no-cap`: the near tier's cap off for this run.
func _cap_arg() -> void:
	if "--no-cap" in OS.get_cmdline_user_args():
		BrickNear.cap_enabled = false

## A walk down a street at eye height past every building near the first one,
## the view swinging from side to side and once right round, as a player looks
## about: frame times, and what the near tier held and cost on the way. A timing
## run (the editor closed); `--no-cap` for the same walk without the cap.
func _run_chamfer_street() -> void:
	RenderingServer.viewport_set_measure_render_time(city.get_viewport().get_viewport_rid(), true)
	var b := city.registry.get_building(0)
	for i in mini(city.registry.buildings.size(), 12):
		city._promote(i)
	await _frames(90)
	_cap_arg()
	@warning_ignore("integer_division")
	print("[street] near tier %s, cap %s" % ["ON" if BrickNear.enabled else "OFF",
			"on (%dk triangles, %d studs)" % [BrickNear.max_tris / 1000, BrickNear.max_studs]
			if BrickNear.cap_enabled else "OFF"])
	var fx: float = b.recipe.footprint_x * City.STUD
	var start: Vector3 = b.xform * Vector3(-4.0, 0.0, -3.0)
	var along: Vector3 = (b.xform.basis * Vector3.RIGHT).normalized()
	var side: Vector3 = (b.xform.basis * Vector3.BACK).normalized()
	start.y = DebugCamera.EYE_HEIGHT
	city.camera.global_position = start
	city.camera.look_at(start + along, Vector3.UP)
	await _frames(30)
	var view := city.get_viewport().get_viewport_rid()
	var frames := 480
	var times := []
	var near_worst := 0.0
	var held_max := Vector2i.ZERO
	var tris_max := 0
	var studs_max := 0
	var last := Time.get_ticks_usec()
	var rows := []   # per frame: what was in it (the long frames, below)
	var render_at := [0.0, 0.0]   # the last render times read (_one_thread)
	var pf_last := Engine.get_physics_frames()
	for i in frames:
		var t := float(i) / float(frames)
		var at: Vector3 = start + along * ((fx + 30.0) * t)
		# Side to side three times, and once right round in the middle.
		var yaw := sin(t * TAU * 3.0) * 1.2 + (TAU * clampf((t - 0.45) * 10.0, 0.0, 1.0))
		var dir: Vector3 = along.rotated(Vector3.UP, yaw)
		city.camera.global_position = at
		city.camera.look_at(at + dir + side * 0.0, Vector3.UP)
		var w0 := city.brick_near.worst_step_ms
		city.brick_near.worst_step_ms = 0.0
		await city.get_tree().process_frame
		near_worst = maxf(near_worst, city.brick_near.worst_step_ms)
		city.brick_near.worst_step_ms = maxf(w0, city.brick_near.worst_step_ms)
		var now := Time.get_ticks_usec()
		if city._one_thread or i % RENDER_SAMPLE_EVERY == 0:
			render_at = [RenderingServer.viewport_get_measured_render_time_cpu(view)
					+ RenderingServer.get_frame_setup_time_cpu(),
					RenderingServer.viewport_get_measured_render_time_gpu(view)]
		times.append([float(now - last) / 1000.0, render_at[0], render_at[1]])
		last = now
		var pf := Engine.get_physics_frames()
		var top := ""
		if pf != pf_last:
			var ph: Array = []
			for k in city._prof:
				if not (k as String).contains("_"):
					ph.append([float(city._prof[k]), k])
			ph.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
			for k in mini(3, ph.size()):
				top += "%s %.1f " % [ph[k][1], ph[k][0]]
			if not ph.is_empty():
				top += "| " + city.dev_hud.spike_parts(ph[0][1])
		rows.append([float(times[-1][0]), pf - pf_last,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				float(times[-1][1]), float(times[-1][2]), city.brick_near.worst_step_ms,
				float(city._prof.get("script_total", 0.0)) if pf != pf_last else 0.0, top])
		pf_last = pf
		var h: Vector2i = city.brick_near.held()
		held_max = Vector2i(maxi(held_max.x, h.x), maxi(held_max.y, h.y))
		tris_max = maxi(tris_max, city.brick_near.chamfered_tris)
		studs_max = maxi(studs_max, city.brick_near.stud_instances)
	var over := 0
	for tt in times:
		if float(tt[0]) > 25.0:
			over += 1
	print("[street]   walk: %s; %d frames over 25 ms" % [_frame_line(times), over])
	if "--long" in OS.get_cmdline_user_args():
		print("[street]   long frames, with the one before and after (ms: frame, ticks, process, physics, render cpu, gpu, near step, tick script; the tick's top phases):")
		for i in rows.size():
			if float(rows[i][0]) <= 25.0:
				continue
			for j in range(maxi(i - 1, 0), mini(i + 2, rows.size())):
				var r: Array = rows[j]
				print("[street]     %s%3d  %5.1f  %d  %5.1f  %5.1f  %5.2f  %5.1f  %5.2f  %5.1f  %s" % [
						"*" if j == i else " ", j, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]])
	@warning_ignore("integer_division")
	print("[street]   held at most %d chamfered, %d with stud geometry (budgets %dk triangles, %d studs); %d triangles, %d studs at most; worst step %.2f ms"
			% [held_max.x, held_max.y, BrickNear.max_tris / 1000, BrickNear.max_studs,
				tris_max, studs_max, near_worst])
	print("[street]   %s" % city.brick_near.report())
	print("[street]   studs, worst: fetch %.2f ms, split %.2f, set %.2f; %d in one band at most"
			% [city.brick_near.worst_fetch_ms, city.brick_near.worst_split_ms, city.brick_near.worst_set_ms,
				city.brick_near.most_band_studs])
	print("[street]   showing a band, worst %.2f ms; %d steps a band waited for an upload to finish first"
			% [city.brick_near.worst_show_ms, city.brick_near.show_waited])

## The next `n` frames: each one's length, and what the renderer says the
## frame before it took to draw on the CPU and on the GPU, in ms.
func _frame_times(n: int) -> Array:
	var out := []
	var view := city.get_viewport().get_viewport_rid()
	var last := Time.get_ticks_usec()
	for i in n:
		await city.get_tree().process_frame
		var now := Time.get_ticks_usec()
		out.append([float(now - last) / 1000.0,
				RenderingServer.viewport_get_measured_render_time_cpu(view)
				+ RenderingServer.get_frame_setup_time_cpu(),
				RenderingServer.viewport_get_measured_render_time_gpu(view)])
		last = now
	return out

func _frame_line(times: Array) -> String:
	var sum := 0.0
	var worst := 0.0
	var cpu := 0.0
	var gpu := 0.0
	var gpu_worst := 0.0
	for t in times:
		sum += float(t[0])
		worst = maxf(worst, float(t[0]))
		cpu += float(t[1])
		gpu += float(t[2])
		gpu_worst = maxf(gpu_worst, float(t[2]))
	var n := maxf(times.size(), 1.0)
	return "%d frames, mean %.1f ms, worst %.1f; drawing them: CPU %.2f ms, GPU %.2f (worst %.2f)" % [
			times.size(), sum / n, worst, cpu / n, gpu / n, gpu_worst]

## Render one frame with the near tier -- chamfered bands, bevelled studs -- on
## or off and hand back the image. A name also writes it to shots/, for the eye
## to judge what a number cannot.
func _capture_chamfer(on: bool, shot_name: String) -> Image:
	BrickNear.enabled = on
	city.brick_near.settle(city.camera.global_position)
	await _frames(3)
	var img := city.get_viewport().get_texture().get_image()
	if shot_name != "":
		img.save_png("res://shots/%s.png" % shot_name)
		print("[chamfer] shot written: %s.png" % shot_name)
	await RenderingServer.frame_post_draw
	return img

## What fraction of sampled pixels changed. Every fourth pixel each way, which
## is 57,600 samples out of 921,600 -- enough to measure an effect that is drawn
## along every brick edge in the frame.
func _image_difference(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 0.0
	var changed := 0
	var total := 0
	var w := a.get_width()
	var h := a.get_height()
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			total += 1
			var pa := a.get_pixel(x, y)
			var pb := b.get_pixel(x, y)
			if absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b) > 0.02:
				changed += 1
	return float(changed) / float(maxi(total, 1))

## Where the physics is going, by piece size: how many pieces are moving and
## how many have settled, and how many collision boxes each class is carrying.
## The solver's cost is bodies, boxes and the contacts between them, so this is
## what says whether a collapse is expensive because of a few enormous pieces
## or a great many small ones -- which are different fixes.
func _physics_census(label: String) -> void:
	var edges := [1, 10, 100, 1000, 1 << 30]
	var names := ["1-9", "10-99", "100-999", "1000+"]
	var rows := []
	for i in names.size():
		rows.append({"moving": 0, "settled": 0, "mbox": 0, "sbox": 0, "bricks": 0})
	if city._clock != null:
		city._clock.spoil()
	for isl in city.islands.islands:
		if not isl.is_valid():
			continue
		var n := city.world.get_alive_block_count(isl.chunk)
		var i := 0
		while i < names.size() - 1 and n >= int(edges[i + 1]):
			i += 1
		var r: Dictionary = rows[i]
		if isl.settled:
			r.settled += 1
			r.sbox += isl.shape_count
		else:
			r.moving += 1
			r.mbox += isl.shape_count
		r.bricks += n
	# Jolt answers the server's active-object and pair counts with zero, so the
	# census counts for itself; the physics time is the engine's own monitor.
	var rep: Dictionary = city.islands.report()
	print("[census] %s: physics %.1f ms this frame; settled so far %d (%d by staying slow, %d by age)"
			% [label, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			int(rep.settled), int(rep.settled_by_rule), int(rep.settled_by_age)])
	for i in names.size():
		var r: Dictionary = rows[i]
		if int(r.moving) + int(r.settled) == 0:
			continue
		print("[census]   %-8s bricks: %4d moving (%6d boxes), %4d settled (%6d boxes), %6d bricks"
				% [names[i], r.moving, r.mbox, r.settled, r.sbox, r.bricks])

## The grid's light in a city building (Docs/Lighting.md 6.1):
##
##     godot --path . res://scenes/city.tscn -- --light
##
## Building 0 in bricks; the camera at the darkest air at eye height in it.
## The grid lights its bands and the near tier's chamfered meshes; the
## picture is darker with it than without; a hole lets the sky in.
## Pictures city_light_on / city_light_off.
func _run_light_pass() -> void:
	print("[light] the grid in a city building")
	var b := city.registry.get_building(0)
	var chunk := city._promote(0)
	var t0 := Time.get_ticks_msec()
	while not city.grid_light.tracked(0) and Time.get_ticks_msec() - t0 < 20000:
		await _ticks(1)
	_gate_ok("building 0 is in bricks and lit by the grid", chunk >= 0 and city.grid_light.tracked(0))
	# Its ceiling lights (CeilingLights; Docs/Lighting.md 6.3).
	var lamps := 0
	if chunk >= 0:
		for k in city.world.get_block_count(chunk):
			if BrickWorld.get_material_name(city.world.get_block_material(chunk, k)) == "Lamp":
				lamps += 1
	_gate_ok("the tower has lights under its ceilings", lamps >= 3, "%d" % lamps)
	var node := city._brick_nodes.get(0) as Node3D
	var dims := city.world.get_chunk_dims(chunk)
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var p0 := int(1.0 / plate)
	var p1 := int(2.0 / plate)
	var best := 2.0
	var at := Vector3.ZERO
	var cell := Vector3i(-1, -1, -1)
	for x in range(2, dims.x - 2):
		for z in range(2, dims.z - 2):
			var air := true
			for y in range(p0, p1 + 1):
				if city.world.block_at(chunk, city.world.get_chunk_origin(chunk) + Vector3i(x, y, z)) >= 0:
					air = false
					break
			if not air:
				continue
			var w := node.global_transform * Vector3((x + 0.5) * stud, 1.6, (z + 0.5) * stud)
			var g := city.grid_light.at(w).x
			if g >= 0.0 and g < best:
				best = g
				at = w
				cell = Vector3i(x, 0, z)
	# A city tower has wide openings: half the sky is already a room in shade.
	_gate_ok("somewhere inside is shaded from the sky", best < 0.5, "darkest %.2f" % best)
	# Looking along the longer way across it.
	var across := node.global_transform.basis * (Vector3(1, 0, 0) if cell.x < dims.x / 2 else Vector3(-1, 0, 0))
	city.camera.global_position = at
	city.camera.look_at(at + across * 5.0 - Vector3.UP * 0.4, Vector3.UP)
	await _ticks(60)
	var near_ok := 0
	var near_all := 0
	var studs_ok := 0
	var studs_all := 0
	for band in node.get_children():
		for k in band.get_children():
			var lit := false
			if k is MeshInstance3D and k.name.begins_with("Chamfered"):
				near_all += 1
				lit = true
			# Its studs as geometry (BrickNear.grid_stud_material), not the cards.
			elif k is MultiMeshInstance3D and k.material_override == BrickNear.grid_stud_material():
				studs_all += 1
				lit = true
			if not lit:
				continue
			var v: Variant = (k as GeometryInstance3D).get_instance_shader_parameter(&"grid_light")
			if v is Vector4 and (v as Vector4).x >= 0.0:
				if k is MultiMeshInstance3D:
					studs_ok += 1
				else:
					near_ok += 1
	# Headless, the near tier makes nothing.
	if DisplayServer.get_name() != "headless":
		_gate_ok("the near tier's bricks carry the grid", near_all > 0 and near_ok == near_all,
				"%d of %d" % [near_ok, near_all])
		_gate_ok("the near tier's studs carry the grid", studs_all > 0 and studs_ok == studs_all,
				"%d of %d" % [studs_ok, studs_all])
	if DisplayServer.get_name() != "headless":
		await _ticks(10)
		var on := _mean_of(city.get_viewport().get_texture().get_image())
		await _save("city_light_on")
		# The studs alone without it: the floor's studs bright on a dark floor.
		BrickNear.grid_stud_material().set_shader_parameter("grid_sky_floor", 1.0)
		await _ticks(4)
		var no_studs := _mean_of(city.get_viewport().get_texture().get_image())
		await _save("city_light_studs_off")
		print("[light] mean of the picture: grid %.3f, studs not on it %.3f" % [on, no_studs])
		_gate_ok("the grid darkens the studs", on < no_studs * 0.98, "%.3f against %.3f" % [on, no_studs])
		city.brick_material.set_shader_parameter("grid_sky_floor", 1.0)
		await _ticks(4)
		var off := _mean_of(city.get_viewport().get_texture().get_image())
		await _save("city_light_off")
		city.brick_material.set_shader_parameter("grid_sky_floor", BrickGridLight.SKY_FLOOR)
		BrickNear.grid_stud_material().set_shader_parameter("grid_sky_floor", BrickGridLight.SKY_FLOOR)
		print("[light] mean of the picture: grid %.3f, none %.3f" % [on, off])
		_gate_ok("the grid darkens the inside", on < off * 0.9, "%.3f against %.3f" % [on, off])
		# The player's flashlight (Docs/Lighting.md 6.4): L lights the room ahead.
		var vp_rid := city.get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp_rid, true)
		await _ticks(10)
		var gpu_off := RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		var torch := Flashlight.mount(city.camera)
		torch.set_on(true)
		await _ticks(10)
		var lit := _mean_of(city.get_viewport().get_texture().get_image())
		var gpu_on := RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
		await _save("city_flashlight")
		torch.set_on(false)
		print("[light] flashlight: picture %.3f against %.3f; GPU %.2f ms against %.2f off"
				% [lit, on, gpu_on, gpu_off])
		_gate_ok("the flashlight lights the room", lit > on * 1.1, "%.3f against %.3f" % [lit, on])
	# A hole through an outer wall (x = 0 side or the far one), where it is
	# whole for 4 studs across and 1-2 m up and a room is right behind it; the
	# air just in reads at least three steps from the open.
	var hole := {}
	var by := Vector3i(-1, -1, -1)
	var org := city.world.get_chunk_origin(chunk)
	var eye_p := int(1.6 / plate)
	for side in [0, dims.x - 1]:
		var inward: int = 1 if side == 0 else -1
		for z0 in range(2, dims.z - 6):
			var ok := true
			for z in range(z0, z0 + 4):
				for y in range(p0, p1 + 1):
					if city.world.block_at(chunk, org + Vector3i(side, y, z)) < 0:
						ok = false
			if not ok:
				continue
			# Through the wall: the first air in, at eye height, in the middle.
			var x: int = side
			while x != side + inward * 6 and city.world.block_at(chunk, org + Vector3i(x, eye_p, z0 + 2)) >= 0:
				x += inward
			if city.world.block_at(chunk, org + Vector3i(x, eye_p, z0 + 2)) >= 0:
				continue
			for xx in range(side, x, inward):
				for z in range(z0, z0 + 4):
					for y in range(p0, p1 + 1):
						var bk := city.world.block_at(chunk, org + Vector3i(xx, y, z))
						if bk >= 0:
							hole[bk] = true
			by = Vector3i(x, eye_p, z0 + 2)
			break
		if by.x >= 0:
			break
	var by_w := node.global_transform * Vector3((by.x + 0.5) * stud, 1.6, (by.z + 0.5) * stud)
	var before := city.grid_light.at(by_w).x
	city.world.kill_blocks(chunk, PackedInt32Array(hole.keys()))
	city.grid_light.relight(0)
	var after := city.grid_light.at(by_w).x
	var steps := absi(by.x - (0 if by.x < dims.x / 2 else dims.x - 1)) + 2
	_gate_ok("a hole in the wall lets the sky in", by.x >= 0 and after > before + 0.05
			and after >= 1.0 - steps * BrickGridLight.SKY_STEP / 255.0 - 0.01,
			"%d bricks out at %s; %.2f -> %.2f" % [hole.size(), by, before, after])
	print("[light] grid: %d update(s), the last %.2f ms" % [city.grid_light.updates, city.grid_light.last_ms])
	print("[light] city light pass: %d ok, %d FAIL" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Frames by the main loop's tick: a headless city draws none, so
## frame_post_draw never comes (_frames waits for ever there).
func _ticks(n: int) -> void:
	for i in n:
		await city.get_tree().process_frame

static func _mean_of(img: Image) -> float:
	var small := img.duplicate() as Image
	small.resize(64, 36)
	var sum := 0.0
	for y in 36:
		for x in 64:
			sum += small.get_pixel(x, y).get_luminance()
	return sum / (64.0 * 36.0)

## What a far building's windows look like: a shell, close up.
##
##     godot --path . --resolution 1280x720 res://scenes/city.tscn -- --windows
##
## Promotion is held off (`_measuring`), so the camera can walk right up to a
## building that is still a shell -- which in play it never does, because a
## building becomes bricks at PROMOTE_RANGE. That is the point of looking: the
## panes have to hold up at the closest a player ever sees them, and further.
func _run_windows_pass() -> void:
	city._measuring = true
	print("[windows] a shell's windows, close up")
	var panes := 0
	var tris := 0
	for id in city._shells:
		var shell: MeshInstance3D = city._shells[id]
		for child in shell.get_children():
			if child is MeshInstance3D:
				@warning_ignore("integer_division")
				var n: int = (child as MeshInstance3D).mesh.get_faces().size() / 6
				panes += n
				tris += n * 2
	print("[windows] %d pane(s) across %d shell(s), %d triangle(s)" % [panes, city._shells.size(), tris])
	var tallest := 0
	var target := -1
	for b in city.registry.buildings:
		if b.recipe != null and not b.is_build() and b.recipe.courses > tallest:
			tallest = b.recipe.courses
			target = b.id
	var b := city.registry.get_building(target)
	var box := city.registry.local_box(target)
	var face: Vector3 = b.xform * (box.position + Vector3(box.size.x * 0.5, 7.5, 0.0))
	# In the street: the city's buildings are only a street apart, so anything
	# much further out than this is inside the one across the road.
	for view in [["windows_near", Vector3(0.0, 0.0, -5.0)],
			["windows_angle", Vector3(-4.0, -1.5, -4.0)],
			["windows_far", Vector3(0.0, 25.0, -40.0)]]:
		city.camera.global_position = face + (view[1] as Vector3)
		city.camera.look_at(face, Vector3.UP)
		await _frames(8)
		await _save(str(view[0]))
	city.get_tree().quit(0)

## Does wreckage stop costing anything once nobody is near it?
##
## Docs/Status.md, "give islands back to the world". A settled island used to
## keep a chunk, an occupancy grid, a bake, a mesh and a body for the rest of
## the scene, and the 1.2 GB worst case is mostly that. The truth layer's half
## of this gate is `tools/dormant_probe.gd`; here are the distances, the
## budgets and the memory.
func _run_dormant_pass() -> void:
	print("[dormant] wreckage, given back")

	# Make some. Three buildings promoted and toppled is a field of settled
	# pieces within a few seconds.
	var mid := Vector3.ZERO
	for id in [0, 1, 2]:
		var b := city.registry.get_building(id)
		mid += b.xform.origin / 3.0
		city._promote(id)
	await _frames(20)
	for id in [0, 1, 2]:
		city._topple(id)
	city.camera.global_position = mid + Vector3(0.0, 30.0, -60.0)
	city.camera.look_at(mid, Vector3.UP)

	# Let them fall and settle. SETTLE_MIN_MS is 900 and a body has to be
	# asleep, so this is seconds of scene time however it is written.
	var guard := 0
	while guard < 600 and int(city.islands.report().settled) < 1:
		await _frames(1)
		guard += 1
	var rep: Dictionary = city.islands.report()
	_gate_ok("there is wreckage", int(rep.islands) > 0, "%d islands" % int(rep.islands))
	_gate_ok("and it has settled", int(rep.settled) > 0, "%d settled" % int(rep.settled))
	_gate_ok("none of it is asleep yet", int(rep.dormant) == 0)
	var resident: Dictionary = city.world.get_memory_report()
	var blocks_before := int(rep.blocks)

	# Walk away. SLEEP_AFTER_MS is six seconds, and the streamer puts one piece
	# away per tick, so this is deliberately not instant.
	city.camera.global_position = mid + Vector3(0.0, 40.0, -320.0)
	city.camera.look_at(mid, Vector3.UP)
	guard = 0
	while guard < 1200 and int(city.islands.report().islands) > 0:
		await _frames(1)
		guard += 1
	rep = city.islands.report()
	var asleep: Dictionary = city.world.get_memory_report()
	_gate_ok("walking away puts the wreckage to sleep", int(rep.dormant) > 0,
			"%d asleep, %d still resident" % [int(rep.dormant), int(rep.islands)])
	_gate_ok("the chunks went with it", int(asleep.chunks) < int(resident.chunks),
			"%d chunks, was %d" % [int(asleep.chunks), int(resident.chunks)])
	_gate_ok("and so did the memory",
			int(asleep.total_bytes) < int(resident.total_bytes),
			"%.1f MB, was %.1f MB" % [float(asleep.total_bytes) / 1048576.0,
					float(resident.total_bytes) / 1048576.0])
	var freed := int(resident.total_bytes) - int(asleep.total_bytes)
	_gate_ok("what it kept is a fraction of what it gave back",
			int(rep.dormant_bytes) * 8 < freed,
			"%.1f KB kept against %.1f MB freed" % [
				float(int(rep.dormant_bytes)) / 1024.0, float(freed) / 1048576.0])
	_gate_ok("and every brick is still accounted for",
			int(rep.dormant_blocks) + int(rep.blocks) == blocks_before,
			"%d asleep + %d awake against %d" % [
				int(rep.dormant_blocks), int(rep.blocks), blocks_before])
	# Asleep is not gone from view: each piece left its coarse stand-in drawn
	# where it lay (IslandManager._leave_stand_in). A single brick is drawn by
	# the shared MultiMesh and leaves none.
	var drawn := 0
	var singles := 0
	for d in city.islands.dormant:
		if d.record.block_count() == 1:
			singles += 1
		elif d.stand_in != null and is_instance_valid(d.stand_in) \
				and d.stand_in.is_inside_tree() and d.stand_in.mesh != null:
			drawn += 1
	_gate_ok("and it is still drawn where it lay", drawn > 0 and drawn + singles == int(rep.dormant),
			"%d stand-in(s) for %d asleep, %d single brick(s)" % [drawn, int(rep.dormant), singles])
	print("[dormant] %d piece(s), %d block(s): %.1f MB resident -> %.1f MB + %.1f KB of record" % [
			int(rep.dormant), int(rep.dormant_blocks),
			float(resident.total_bytes) / 1048576.0,
			float(asleep.total_bytes) / 1048576.0,
			float(int(rep.dormant_bytes)) / 1024.0])
	await _save("dormant_asleep")

	# Walk back. It has to be the same wreckage, not a fresh pile.
	var was_dormant := int(rep.dormant)
	var was_blocks := int(rep.dormant_blocks)
	city.camera.global_position = mid + Vector3(0.0, 30.0, -60.0)
	city.camera.look_at(mid, Vector3.UP)
	guard = 0
	# Each piece as it wakes draws its stand-in until its bricks are baked: a
	# woken piece used to be invisible for the tick or two that took.
	var blind_on_waking := 0
	var woken_before := int(city.islands.report().woken)
	while guard < 1200 and int(city.islands.report().dormant) > 0:
		await _frames(1)
		guard += 1
		if int(city.islands.report().woken) > woken_before:
			woken_before = int(city.islands.report().woken)
			for isl in city.islands.islands:
				if city.islands.is_blind(isl):
					blind_on_waking += 1
	var stand_ins_left := 0
	for child in city.islands.get_children():
		if child is MeshInstance3D and not child.is_queued_for_deletion():
			stand_ins_left += 1
	rep = city.islands.report()
	_gate_ok("a piece waking draws from its first tick", blind_on_waking == 0,
			"%d blind piece-tick(s) as they woke" % blind_on_waking)
	_gate_ok("and the stand-ins it left are gone", stand_ins_left == 0,
			"%d left" % stand_ins_left)
	_gate_ok("walking back wakes it", int(rep.dormant) == 0,
			"%d still asleep" % int(rep.dormant))
	_gate_ok("as the same pieces", int(rep.islands) >= was_dormant,
			"%d islands for %d that slept" % [int(rep.islands), was_dormant])
	_gate_ok("with the same bricks", int(rep.blocks) == blocks_before,
			"%d against %d" % [int(rep.blocks), blocks_before])
	_gate_ok("settled, not falling over again", int(rep.settled) >= was_dormant,
			"%d settled" % int(rep.settled))
	_gate_ok("and it was woken rather than rebuilt from nothing",
			int(rep.woken) >= was_dormant and was_blocks > 0)
	await _save("dormant_awake")

	# And a piece that is asleep is still there to be shot. Plan section 4.4:
	# damage does not wait for somebody to be near.
	city.camera.global_position = mid + Vector3(0.0, 40.0, -320.0)
	city.camera.look_at(mid, Vector3.UP)
	guard = 0
	while guard < 1200 and int(city.islands.report().dormant) == 0:
		await _frames(1)
		guard += 1
	_gate_ok("something is asleep again", int(city.islands.report().dormant) > 0)
	var target: IslandManager.Dormant = city.islands.dormant[0]
	var at: Vector3 = target.record.box.get_center()
	var held := target.record.block_count()
	var slept_id := target.piece_id
	var before_blast := {}
	for isl in city.islands.islands:
		before_blast[isl] = true
	city._blast(at, 3.0)
	guard = 0
	while not city._damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(10)
	# THAT piece, by its id -- not every piece within 20 m of the blast, which
	# counted its neighbours' bricks too (2,814 "left" of a 1,421-brick piece).
	var woke := false
	var left := 0
	for isl in city.islands.islands:
		if isl.is_valid() and isl.piece_id == slept_id:
			woke = true
			left = city.world.get_alive_block_count(isl.chunk)
	_gate_ok("a blast wakes what it reaches", woke, "piece %d" % slept_id)
	_gate_ok("and takes bricks out of it", left > 0 and left < held,
			"%d of %d left" % [left, held])
	# Out here -- 300 m off -- the piece it woke goes on drawing the stand-in it
	# left, rebuilt for what the blast took, and anything the blast broke off
	# comes up as a stand-in too: nothing out here is baked or uploaded as
	# bricks (IslandManager.ISLAND_MESH_RANGE).
	var woken_coarse := false
	var new_coarse := 0
	var new_bricks := 0
	for isl in city.islands.islands:
		if not isl.is_valid() or isl.mesh == null:
			continue
		if isl.piece_id == slept_id:
			woken_coarse = isl.coarse and isl.coarse_drawn
		elif not before_blast.has(isl):
			if isl.coarse:
				new_coarse += 1
			else:
				new_bricks += 1
	_gate_ok("far off, the piece it woke draws its stand-in", woken_coarse)
	_gate_ok("and what it broke off comes up as stand-ins, never as bricks", new_bricks == 0,
			"%d stand-in(s), %d as bricks" % [new_coarse, new_bricks])

	print("\n%d passed, %d failed" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Is a staircase part of the building it is in?
##
## Docs/BuildMode.md section 11, Stage 5. The truth layer's half is
## `tools/fixture_probe.gd`; this is the half that needs a scene -- bricks in
## the building's own body, a figure standing on a tread, and what happens to
## the flight when the building comes down.
##
## The first version of this gate asked the opposite questions: whether the
## staircase had a body of its own, whether it woke up when you walked near it,
## whether a falling section passed through it. It did all of those and the
## result was a staircase left standing in the rubble of the building it was
## fixed to. A staircase is bricks in the same grid as the building. These are
## the questions that follow from that.
func _run_fixture_pass() -> void:
	print("[fixture] a staircase made of the building it is in")
	var b := city.registry.get_building(0)
	var rep: Dictionary = city.registry.report()

	_gate_ok("every building registered a staircase",
			int(rep.fixtures) == city.registry.buildings.size(),
			"%d for %d buildings" % [int(rep.fixtures), city.registry.buildings.size()])
	_gate_ok("and the city is still recipes and shells, staircases included",
			int(city.world.get_memory_report().chunks) == 0)
	_gate_ok("no fixture holds a chunk of its own", b.fixtures[0].blocks.is_empty())

	# Materialise it the way a shot does.
	var chunk := city._promote(0)
	await _frames(20)
	var f := b.fixtures[0]
	var steps: int = int(f.params.get("steps", 0))
	_gate_ok("the building builds its staircase with itself", not f.blocks.is_empty(),
			"%d blocks" % f.blocks.size())
	# One spiral piece per two steps (StaircaseRecipe.build_flight): the count
	# is pieces. It was steps, from before the flight was built from spiral
	# pieces, and 27 steps are 14 pieces.
	var pieces := StaircaseRecipe.flight_pieces(steps)
	_gate_ok("every step is there", f.blocks.size() == pieces,
			"%d pieces of %d for %d steps" % [f.blocks.size(), pieces, steps])
	_gate_ok("in the SAME chunk as the building", chunk == b.chunk)
	# A chunk per building in bricks and none more: the staircase is not one.
	# It was "one chunk", which counted on nothing else being bricks -- and the
	# camera at rest here may be aiming at another building (_aim_promote).
	var in_bricks := 0
	for o in city.registry.buildings:
		if o.is_materialised():
			in_bricks += 1
	_gate_ok("so the city holds a chunk for each building in bricks, none for its stairs",
			int(city.world.get_memory_report().chunks) == in_bricks,
			"%d chunk(s), %d building(s) in bricks" % [
				int(city.world.get_memory_report().chunks), in_bricks])

	# Clipped to the building, which is what makes it come apart with it.
	var joined := 0
	for id in f.blocks:
		for n in city.world.get_block_neighbours(chunk, id):
			if not f.blocks.has(n):
				joined += 1
	_gate_ok("and it is clipped to the building's own bricks", joined > 0,
			"%d joints out of the flight" % joined)

	# Solid, and solid as part of the BUILDING's body rather than a body of its
	# own -- the ray has to come back with the building's brick body.
	var vol := f.volume()
	var mid: Vector3 = b.xform * (vol.position + vol.size * 0.5)
	var eye := mid + Vector3(9.0, 1.0, 9.0)
	city.camera.global_position = eye
	city.camera.look_at(mid, Vector3.UP)
	await _frames(6)
	var shell: MeshInstance3D = city._shells.get(0)
	if shell != null:
		shell.visible = false
	await _save("fixture_awake")

	# Stand on it. The treads are three studs wide and the figure is a little
	# under three bricks tall, so this is also the check that those agree.
	# Onto a tread, found rather than computed: only an eighth of the ring is
	# solid at any one height, so a point picked off the volume alone is as
	# likely to be the gap the next step leaves.
	var over: Vector3 = b.xform * (vol.position + Vector3(
			vol.size.x * 0.75, vol.size.y * 0.6, vol.size.z * 0.5))
	var down := PhysicsRayQueryParameters3D.create(over, over - Vector3(0.0, 6.0, 0.0))
	down.collision_mask = Layers.HITSCAN_MASK
	var found := city.get_world_3d().direct_space_state.intersect_ray(down)
	_gate_ok("a ray down the stairwell lands on a tread", not found.is_empty(),
			"from %v" % over)
	var tread: Vector3 = (found.position as Vector3) if not found.is_empty() else over
	city.camera.allow_walk = true
	city.camera.drive_uncaptured = true
	# DROPPED: feet a little above the tread, the eye EYE_HEIGHT above them. It
	# was put a metre above the tread, which is the figure half a metre INTO it,
	# and whether the solver pushed it out upwards or let it sink through was
	# down to the shape of the box it was stuck in.
	city.camera.global_position = tread + Vector3(0.0, DebugCamera.EYE_HEIGHT + 0.3, 0.0)
	city.camera.set_walking(true)
	var body := city.camera.body()
	var landed := 0
	# Until it is on the floor. A figure just put down has no speed yet, so
	# "slow enough" is true before it has fallen at all.
	while landed < 150 and (body == null or not body.is_on_floor()):
		await _frames(1)
		landed += 1
		body = city.camera.body()
	var stood_on := _what_is_under(body)
	await _frames(10)
	_gate_ok("a figure dropped onto the flight comes to rest on it",
			body != null and (body.is_on_floor() or absf(body.velocity.y) < 0.15),
			"on floor %s, vy %.2f; landed on %s, now over %s" % [
					body.is_on_floor() if body != null else false,
					body.velocity.y if body != null else 0.0, stood_on, _what_is_under(body)])
	_gate_ok("well above the building's floor, which means it landed on a TREAD",
			city.camera.global_position.y > b.xform.origin.y + 1.0,
			"%.2f m" % city.camera.global_position.y)
	city.camera.look_at(Vector3(mid.x, city.camera.global_position.y - 1.2, mid.z), Vector3.UP)
	await _frames(4)
	await _save("fixture_standing")
	city.camera.set_walking(false)
	if shell != null:
		shell.visible = true

	# Shoot it. Its bricks are the building's bricks, so they go into the
	# building's own damage record and nowhere else.
	city.camera.global_position = mid + Vector3(0.0, 1.0, -9.0)
	city.camera.look_at(mid, Vector3.UP)
	await _frames(6)
	var stairs_before := _alive_of(chunk, f.blocks)
	city._blast(mid, 2.0)
	var guard := 0
	while not city._damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(20)
	_gate_ok("shooting the flight takes steps out of it",
			_alive_of(chunk, f.blocks) < stairs_before,
			"%d of %d left" % [_alive_of(chunk, f.blocks), stairs_before])
	# In the BUILDING's own dead list -- the steps it lost are its bricks. Not
	# "fewer bricks than before": the rooms around the camera open while this
	# waits and lay their furniture, and the count went up (638 -> 647).
	var dead_steps := 0
	for id in city.world.get_dead_blocks(chunk):
		if f.blocks.has(id):
			dead_steps += 1
	_gate_ok("and the building is the thing that is damaged",
			city.registry.get_building(0).is_damaged() and dead_steps > 0,
			"%d dead steps in the building's record" % dead_steps)

	# The whole point: when the building comes down, the staircase goes with it.
	var stairs_standing := _alive_of(chunk, f.blocks)
	var before_islands: int = int(city.islands.report().islands)
	city._topple(0)
	await _frames(30)
	_gate_ok("toppling the building makes one piece of wreckage",
			int(city.islands.report().islands) > before_islands)
	_gate_ok("the staircase went with it -- same chunk, now an island",
			city.world.is_chunk_alive(chunk) and _alive_of(chunk, f.blocks) == stairs_standing,
			"%d of %d steps" % [_alive_of(chunk, f.blocks), stairs_standing])
	_gate_ok("nothing was left standing where the building was",
			not city.registry.get_building(0).is_materialised())
	_gate_ok("and the city never made a body for the staircase itself",
			int(city.world.get_memory_report().chunks) >= 1)
	await _frames(60)
	await _save("fixture_collapse")

	print("\n%d passed, %d failed" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

## Somewhere on this building that still HAS brick in it, high up.
##
## Aiming at a fixed fraction of the height was wrong twice over. The walls have
## windows in them, so a ray at an arbitrary height goes through one and out of
## the far side; and the shot that damaged this building in the first place can
## have detached everything above it, so the brick that was at 80% of the height
## is an island lying on the ground by the time the second shot is fired. Both
## read as "damage does not carry to 200 m", which is not what either of them is.
##
## So: the floor slabs, from the top down, because a slab spans the whole
## footprint and is the one band of a tower that is solid all the way across --
## and the first one whose wall cell is still solid.
func _intact_aim(id: int) -> Vector3:
	var b := city.registry.get_building(id)
	var cell := BrickWorld.get_cell_size()
	var stud: int = int(b.recipe.footprint_x * 0.5)
	var bands := TowerRecipe.layout(b.recipe.courses)
	for i in range(bands.size() - 1, -1, -1):
		var band: Dictionary = bands[i]
		if str(band.kind) != "slab":
			continue
		var plate: int = int(band.y)
		if b.is_materialised() and not city.world.is_solid(b.chunk, Vector3i(stud, plate, 0)):
			continue
		return b.xform * Vector3(stud * cell.x, plate * cell.y, 0.0)
	# Nothing left standing at any slab: aim at the middle and let the check say
	# so rather than inventing a point.
	return b.xform * (city.registry.local_box(id).position
			+ city.registry.local_box(id).size * 0.5)

## How many of a building's bands actually hold a surface.
func _drawn_surfaces(id: int) -> int:
	var n := 0
	for mesh in (city._brick_band_meshes.get(id, []) as Array):
		if mesh != null and (mesh as ArrayMesh).get_surface_count() > 0:
			n += 1
	return n

## How many of these blocks are still alive in this chunk.
func _alive_of(chunk: int, ids: PackedInt32Array) -> int:
	var dead := {}
	for id in city.world.get_dead_blocks(chunk):
		dead[id] = true
	var n := 0
	for id in ids:
		if not dead.has(id):
			n += 1
	return n

## Is a multi-frame player build a building like any other once it is in the
## city -- cheap when nobody is near it, bricks when somebody shoots it, and
## damaged in both?
##
## Docs/BuildMode.md section 11 (the seam Stage 4 left open) and section 12
## question 3 (the cheap tier). A build used to arrive materialised and stay
## that way forever, because there was nothing cheap to draw it with.
func _run_build_pass() -> void:
	print("[build] a creation placed in the city, and what it costs when nobody is near it")
	var id := city.registry.buildings.size() - 1
	var b := city.registry.get_building(id)
	if b == null or not b.is_build():
		print("  FAIL nothing was placed -- run tools/demo_build.gd first")
		city.get_tree().quit(1)
		return

	_gate_ok("it is in the registry as a build", b.is_build())
	_gate_ok("with more than one frame in its recipe", b.build.frame_count() > 1,
			"%d" % b.build.frame_count())
	_gate_ok("and welds in it", b.build.weld_count() > 0)
	_gate_ok("and a staircase authored in the workshop", b.build.fixture_count() == 1)

	# The cheap tier: a shell, and no bricks anywhere in the world.
	_gate_ok("it arrives as a shell rather than as bricks", city._shells.has(id))
	_gate_ok("holding no bricks at all", not b.is_materialised()
			and int(city.world.get_memory_report().chunks) == 0,
			"%d chunks" % int(city.world.get_memory_report().chunks))
	var shell_mesh: Mesh = (city._shells[id] as MeshInstance3D).mesh
	var shell_tris := 0
	if shell_mesh != null and shell_mesh.get_surface_count() > 0:
		@warning_ignore("integer_division")
		shell_tris = shell_mesh.get_faces().size() / 3
	_gate_ok("with something to draw", shell_tris > 0, "%d triangles" % shell_tris)
	_gate_ok("and far fewer triangles than its bricks would be",
			shell_tris < b.build.size() * 12, "%d for %d bricks" % [shell_tris, b.build.size()])
	_gate_ok("it is solid to a shot", city._shell_bodies.has(id))
	await _frames(20)

	# Look at it.
	var box := city.registry.local_box(id)
	var mid: Vector3 = b.xform * (box.position + box.size * 0.5)
	city.camera.global_position = mid + Vector3(9.0, 3.0, -9.0)
	city.camera.look_at(mid, Vector3.UP)
	await _frames(6)
	await _save("build_shell")

	# Shoot it: the shell gives way to bricks, frames and all.
	city._fire(1.4)
	var guard := 0
	while not city._damage_queue.is_empty() and guard < 120:
		await _frames(1)
		guard += 1
	await _frames(40)
	_gate_ok("shooting it turns the shell into bricks", b.is_materialised())
	_gate_ok("as one chunk per frame", b.chunks().size() == b.build.frame_count(),
			"%d chunks for %d frames" % [b.chunks().size(), b.build.frame_count()])
	# The weld TABLE, not how many survived: what is alive depends on which
	# bricks the shot took, and the shot is aimed at whatever the shell put in
	# front of the camera.
	_gate_ok("the welds were rebuilt with them",
			b.asm != null and b.asm.welds.size() == b.build.weld_count(),
			"%d of %d" % [b.asm.welds.size() if b.asm != null else -1, b.build.weld_count()])
	_gate_ok("the staircase went in with the bricks",
			b.fixtures.size() == 1 and not b.fixtures[0].blocks.is_empty())
	_gate_ok("every frame past the root has a node",
			(city._frame_nodes.get(id, []) as Array).size() == b.frames.size() - 1)
	_gate_ok("and the shell is gone, because the bricks are there",
			not city._shells.has(id))
	_gate_ok("it is damaged", b.is_damaged())
	await _save("build_bricks")

	# Walk away: the bricks go back and the shell returns -- WITH the hole in
	# it. That is the whole point of generating it from the recipe.
	var intact_tris := shell_tris
	var chunks_with_bricks := int(city.world.get_memory_report().chunks)
	city._demote(id, 200.0)
	city._materialised.erase(id)
	await _frames(10)
	# Its own chunks, not the world's: the shot left debris, and a piece of
	# wreckage is not the build's to give back.
	_gate_ok("walking away gives the bricks back",
			not b.is_materialised() and b.chunks().is_empty())
	_gate_ok("and the world is holding fewer chunks for it",
			int(city.world.get_memory_report().chunks) < chunks_with_bricks,
			"%d, was %d" % [int(city.world.get_memory_report().chunks), chunks_with_bricks])
	_gate_ok("and puts a shell back", city._shells.has(id))
	var damaged_mesh: Mesh = (city._shells[id] as MeshInstance3D).mesh
	var damaged_tris := 0
	if damaged_mesh != null and damaged_mesh.get_surface_count() > 0:
		@warning_ignore("integer_division")
		damaged_tris = damaged_mesh.get_faces().size() / 3
	_gate_ok("the shell shows the hole rather than an intact silhouette",
			damaged_tris != intact_tris,
			"%d triangles against %d intact" % [damaged_tris, intact_tris])
	_gate_ok("the damage record is what it was drawn from",
			not b.dead.is_empty() or not b.dead_in(1).is_empty())
	city.camera.global_position = mid + Vector3(9.0, 3.0, -9.0)
	city.camera.look_at(mid, Vector3.UP)
	await _frames(6)
	await _save("build_shell_damaged")

	print("\n%d passed, %d failed" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit(1 if city._gate_fail > 0 else 0)

func _gate_ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		city._gate_pass += 1
		print("  ok   %s" % what)
	else:
		city._gate_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])

## Synthesise a key the way the OS would. `Input.is_key_pressed` is what the
## camera reads, so the event has to go through the input singleton rather than
## straight to `_unhandled_input`.
func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)

## A box on the WORLD layer, for the two things the city has no natural example
## of: a kerb low enough to step over and a wall too high to.
func _test_block(centre: Vector3, size: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.collision_layer = Layers.WORLD
	sb.collision_mask = Layers.STRUCTURE_MASK
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	sb.add_child(cs)
	city.add_child(sb)
	sb.global_position = centre
	return sb

## Does the camera collide with the world when it is walking, and stop
## colliding when it is not?
##
## Everything here is a question the free-fly camera could not be asked at all:
## it had no body, so there was nothing for the ground, a building or a kerb to
## push against.
func _run_walk_pass() -> void:
	print("[walk] walking, flying, and what stops each of them")
	city.camera.allow_walk = true
	city.camera.drive_uncaptured = true

	# Open ground, well clear of a 22-building block 13 m apart.
	var open := Vector3(-70.0, 12.0, -70.0)
	city.camera.global_position = open
	city.camera.rotation = Vector3.ZERO
	city.camera.set_walking(true)
	await _frames(120)
	var body := city.camera.body()
	print("\nit falls to the ground and stands on it")
	_gate_ok("a body exists once walking", body != null)
	_gate_ok("it is on the floor", body != null and body.is_on_floor())
	_gate_ok("the eye is at standing height (%.2f m)" % city.camera.global_position.y,
			absf(city.camera.global_position.y - DebugCamera.EYE_HEIGHT) < 0.12)

	# A kerb, 0.3 m: lower than STEP_HEIGHT, so it is walked over.
	print("\na kerb is stepped over, a wall is not")
	var here := city.camera.global_position
	var kerb := _test_block(Vector3(here.x, 0.15, here.z + 3.0), Vector3(6.0, 0.3, 1.0))
	city.camera.look_at(Vector3(here.x, here.y, here.z + 10.0), Vector3.UP)
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	var after_kerb := city.camera.global_position
	_gate_ok("the kerb was crossed (z %.2f, kerb at %.2f)" % [after_kerb.z, here.z + 3.0],
			after_kerb.z > here.z + 3.5)
	_gate_ok("and it is standing on the ground beyond it",
			absf(after_kerb.y - DebugCamera.EYE_HEIGHT) < 0.2)
	kerb.queue_free()

	# A wall, 1.5 m: higher than STEP_HEIGHT, so it stops the body.
	here = city.camera.global_position
	var wall := _test_block(Vector3(here.x, 0.75, here.z + 2.5), Vector3(8.0, 1.5, 1.0))
	await _frames(4)
	_key(KEY_W, true)
	await _frames(90)
	_key(KEY_W, false)
	await _frames(10)
	var at_wall := city.camera.global_position
	_gate_ok("the wall stopped it (z %.2f, wall face at %.2f)" % [at_wall.z, here.z + 2.0],
			at_wall.z < here.z + 2.0)
	_gate_ok("it did walk up to the wall rather than not moving at all",
			at_wall.z > here.z + 0.5)
	wall.queue_free()
	await _frames(4)

	# A real building: the shell tier's own collision, which is what a player
	# meets long before anything is made of bricks.
	print("\na building's shell is solid to a walker and not to a flier")
	var b := city.registry.get_building(0)
	var w: float = b.recipe.footprint_x * City.STUD
	var d: float = b.recipe.footprint_z * City.STUD
	var centre: Vector3 = b.xform.origin + Vector3(w * 0.5, 0.0, d * 0.5)
	var start := centre - Vector3(0.0, 0.0, d * 0.5 + 4.0)

	# The shell's own collision, tested from outside AIM_PROMOTE_RANGE -- which
	# is now the only place a shell survives being looked at: walking up to a
	# building makes it bricks (PROMOTE_RANGE), and so does aiming at it from
	# nearer than that (_aim_promote). It was seventy metres, which aiming now
	# reaches. A ray is how a shell gets hit in practice anyway: FIRE_RANGE is
	# 2 km against SHELL_RANGE's 260 m, so most shots that land on a building
	# land on one of these.
	city.camera.set_walking(false)
	city.camera.global_position = centre - Vector3(0.0, -3.0, d * 0.5 + City.AIM_PROMOTE_RANGE + 20.0)
	city.camera.look_at(Vector3(centre.x, 3.0, centre.z), Vector3.UP)
	await _frames(20)
	_gate_ok("from past aiming range it is a shell and nothing else",
			city._shells.has(0) and not b.is_materialised())
	var shell_q := PhysicsRayQueryParameters3D.create(
			city.camera.global_position, Vector3(centre.x, 3.0, centre.z))
	shell_q.collision_mask = Layers.PAWN_MASK
	_gate_ok("and it is solid to the thing a walker collides with",
			not city.get_world_3d().direct_space_state.intersect_ray(shell_q).is_empty())

	city.camera.set_walking(false)
	city.camera.global_position = start + Vector3(0.0, DebugCamera.EYE_HEIGHT, 0.0)
	city.camera.look_at(Vector3(centre.x, city.camera.global_position.y, centre.z), Vector3.UP)
	city.camera.set_walking(true)
	await _frames(60)
	_key(KEY_W, true)
	await _frames(120)
	_key(KEY_W, false)
	await _frames(10)
	var walked := city.camera.global_position
	_gate_ok("walking stops outside the wall (z %.2f, wall at %.2f)" % [
			walked.z, centre.z - d * 0.5],
			walked.z < centre.z - d * 0.5)
	# And what stopped it is the brick tier, not the shell: standing four metres
	# from a wall is inside PROMOTE_RANGE, so by the time the walker arrives the
	# building it walked up to is made of bricks. That is the whole point of the
	# range -- the interior has to exist before anybody shoots a hole in it.
	_gate_ok("and walking up to it made it bricks, with nobody firing",
			b.is_materialised() and not b.is_damaged())
	_gate_ok("so the shell that used to stop the walker is gone", not city._shells.has(0))

	city.camera.set_walking(false)
	city.camera.global_position = start + Vector3(0.0, DebugCamera.EYE_HEIGHT, 0.0)
	city.camera.look_at(Vector3(centre.x, city.camera.global_position.y, centre.z), Vector3.UP)
	_key(KEY_W, true)
	await _frames(60)
	_key(KEY_W, false)
	await _frames(4)
	var flown := city.camera.global_position
	_gate_ok("flying goes straight through it (z %.2f)" % flown.z, flown.z > centre.z - d * 0.5)

	# The toggle itself. Two taps inside DOUBLE_TAP_MS swap modes; two taps
	# further apart than that are two jumps.
	# The reported bug: a figure that walks under a beam from a tile floor is
	# stopped dead by the same beam when it is standing on a brick. Two plates of
	# floor is the whole difference, and there was no way to duck.
	print("\na brick floor costs headroom, and ducking gets it back")
	city.camera.set_walking(false)
	var room := Vector3(open.x + 30.0, 0.0, open.z)
	# A beam with 1.90 m under it: clear standing from the ground (the figure is
	# four bricks, 1.68 m), not clear standing on one brick course (2.10 m), and
	# clear again crouched on it (a brick shorter, 1.68 m). It was 1.40 m, sized
	# for the old three-brick figure, which a four-brick one could not get under
	# on the ground or crouched on the brick.
	var beam := _test_block(room + Vector3(0.0, 2.0, 0.0), Vector3(6.0, 0.2, 1.2))
	city.camera.global_position = room + Vector3(0.0, DebugCamera.EYE_HEIGHT, -4.0)
	city.camera.look_at(Vector3(room.x, DebugCamera.EYE_HEIGHT, room.z + 6.0), Vector3.UP)
	city.camera.set_walking(true)
	await _frames(40)
	# Until it is past the beam, in physics ticks, ten seconds at most. It was
	# 150 drawn frames, which at a few hundred frames a second is half a second
	# of walking -- a metre and a half of the five it had to cover.
	_key(KEY_W, true)
	var walk_ticks := 0
	while walk_ticks < 300 and city.camera.global_position.z <= room.z + 1.0:
		await city.get_tree().physics_frame
		walk_ticks += 1
	_key(KEY_W, false)
	await _frames(6)
	_gate_ok("from the ground it walks under the beam standing",
			city.camera.global_position.z > room.z + 1.0 and not city.camera.is_crouched(),
			"z %.2f of %.2f, crouched %s" % [
				city.camera.global_position.z, room.z + 1.0, city.camera.is_crouched()])

	# The same beam, with one brick course of floor under it.
	var ledge := _test_block(room + Vector3(0.0, City.PLATE * 1.5, 0.0), Vector3(6.0, City.PLATE * 3.0, 6.0))
	city.camera.set_walking(false)
	city.camera.global_position = room + Vector3(0.0, DebugCamera.EYE_HEIGHT, -5.0)
	city.camera.look_at(Vector3(room.x, DebugCamera.EYE_HEIGHT, room.z + 6.0), Vector3.UP)
	city.camera.set_walking(true)
	await _frames(40)
	var ducked := false
	_key(KEY_W, true)
	# Physics ticks, as above: until past the beam, ten seconds at most.
	var ticks := 0
	while ticks < 300 and city.camera.global_position.z <= room.z + 1.0:
		await city.get_tree().physics_frame
		ticks += 1
		ducked = ducked or city.camera.is_auto_crouched()
	_key(KEY_W, false)
	await _frames(6)
	_gate_ok("standing on a brick it ducks under the same beam", ducked)
	_gate_ok("and gets past it rather than stopping dead",
			city.camera.global_position.z > room.z + 1.0,
			"z %.2f of %.2f" % [city.camera.global_position.z, room.z + 1.0])
	_gate_ok("on top of the brick course, not in front of it",
			city.camera.global_position.y > room.y + 0.8, "%.2f m" % city.camera.global_position.y)
	beam.queue_free()
	await _frames(20)
	_key(KEY_W, true)
	await _frames(30)
	_key(KEY_W, false)
	await _frames(10)
	_gate_ok("and stands up again once the beam is behind it", not city.camera.is_crouched())
	ledge.queue_free()
	await _frames(4)

	print("\nSPACE twice swaps the mode, SPACE once does not")
	city.camera.global_position = open
	city.camera.set_walking(false)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(2)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(4)
	_gate_ok("a double tap started walking", city.camera.is_walking())
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(2)
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(4)
	_gate_ok("a second double tap went back to flying", not city.camera.is_walking())
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(40)   # 40 frames at 60 fps is well past DOUBLE_TAP_MS
	_gate_ok("a single tap left it flying", not city.camera.is_walking())

	# And the tool that used to be on SPACE is not on it any more.
	print("\nSPACE no longer fires")
	city.camera.global_position = start + Vector3(0.0, DebugCamera.EYE_HEIGHT, 0.0)
	city.camera.look_at(Vector3(centre.x, city.camera.global_position.y, centre.z), Vector3.UP)
	await _frames(4)
	var damaged_before: bool = city.registry.get_building(0).is_damaged()
	_key(KEY_SPACE, true)
	_key(KEY_SPACE, false)
	await _frames(20)
	_gate_ok("nothing was destroyed by it",
			city.registry.get_building(0).is_damaged() == damaged_before)

	print("\nthe wheel sets how big the next hole is")
	var was := city._blast_radius
	city._set_blast_radius(city._blast_radius * City.BLAST_STEP)
	_gate_ok("a notch up is bigger", city._blast_radius > was)
	city._set_blast_radius(1000.0)
	_gate_ok("and it is clamped at %.1f m" % City.BLAST_MAX, is_equal_approx(city._blast_radius, City.BLAST_MAX))
	city._set_blast_radius(0.0)
	_gate_ok("and at %.1f m" % City.BLAST_MIN, is_equal_approx(city._blast_radius, City.BLAST_MIN))

	print("\n%d passed, %d failed" % [city._gate_pass, city._gate_fail])
	city.get_tree().quit()

## How many collision shapes the scene is actually holding, and where.
##
## One box per brick is what a large body costs the solver, and the only honest
## way to decide whether to merge anything is to know who is carrying the boxes
## -- the standing buildings, the pieces still falling, or the settled wreckage
## that already merges.
func _collision_report() -> String:
	var building_shapes := 0
	var building_blocks := 0
	for id in city._materialised:
		if city._brick_cols.has(id):
			building_shapes += (city._brick_cols[id] as BuildingCollision).shape_count()
		var b := city.registry.get_building(id)
		if b != null and b.is_materialised():
			building_blocks += city.world.get_alive_block_count(b.chunk)
	var falling := 0
	var settled_boxes := 0
	for isl in city.islands.islands:
		if not isl.is_valid():
			continue
		if isl.settled:
			settled_boxes += isl.shape_count
		else:
			falling += isl.shape_count
	# The furniture bodies are separate from the buildings' own (see _room_body),
	# so they are counted separately or the census quietly stops adding up.
	var furniture := 0
	for fid in city._room_bodies:
		furniture += PhysicsServer3D.body_get_shape_count(city._room_bodies[fid])
	return ("%d box(es) in %d standing building(s) (%d bricks), %d on open room contents, "
			+ "%d in pieces still falling, "
			+ "%d in settled wreckage; building bands merged %d time(s) (%.1f ms total, worst %.1f) "
			+ "and un-merged %d (%.1f ms, worst %.1f); "
			+ "islands merged %d time(s), %d boxes against %d unmerged") % [
			building_shapes, city._materialised.size(), building_blocks, furniture,
			falling, settled_boxes,
			BuildingCollision.merges, BuildingCollision.merge_ms, BuildingCollision.merge_worst,
			BuildingCollision.unmerges, BuildingCollision.unmerge_ms, BuildingCollision.unmerge_worst,
			city.islands.merged_shapes, city.islands.merged_boxes, city.islands.unmerged_boxes]

func _report_phases() -> void:
	# `name` is a Node property, so it cannot be a loop variable here.
	for phase_name in city._phases:
		var ph: Dictionary = city._phases[phase_name]
		if int(ph.n) == 0:
			continue
		print("[stress] %-22s mean %6.1f ms (%5.1f physics) worst %6.1f  %5.1f fps  %d of %d over 33.3" % [
				phase_name, float(ph.sum) / int(ph.n),
				float(ph.get("phys", 0.0)) / int(ph.n), float(ph.worst),
				1000.0 / maxf(float(ph.sum) / int(ph.n), 0.001),
				int(ph.over), int(ph.n)])

func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw

func _save(shot_name: String) -> void:
	var was := city._sampling
	city._sampling = false
	if city._clock != null:
		city._clock.spoil()
	var img := city.get_viewport().get_texture().get_image()
	img.save_png("res://shots/%s.png" % shot_name)
	print("[city] shot written: %s.png" % shot_name)
	await RenderingServer.frame_post_draw
	city._sampling = was


## A boat on the city's sea (Docs/Hulls.md 6-8): the sea cut out of its hull cell by
## cell, its hold dry under the sea line; then holed, its hold flooding, the water
## drawn inside it. Shots: hull_boat_side, hull_boat_deck, hull_boat_hold,
## hull_boat_flooded. Windowed, one run (heat check after).
func _run_boat_pass() -> void:
	city.respawn_buildings = false
	var sea: float = City.TerrainWorldScript.sea_level
	# The ground in first: the sea is where it is under the sea level.
	for i in 120:
		await city.get_tree().process_frame
	var at := Vector3.INF
	for r in range(60, 2400, 20):
		for k in 64:
			var a := TAU * float(k) / 64.0
			var p := city._on_ground(Vector3(cos(a) * r, 0.0, sin(a) * r))
			if p.y < sea - 4.0:
				at = Vector3(p.x, sea + 0.6, p.z)
				break
		if at != Vector3.INF:
			break
	if at == Vector3.INF:
		print("[boat] no open water within 2.4 km (the sea at %.1f m; the ground at the middle %.1f)" % [
				sea, city._on_ground(Vector3.ZERO).y])
		city.get_tree().quit(1)
		return
	var ghosts := GhostHulls.new()
	var boat := Boat.launch(city, 1, Transform3D(Basis(Vector3.UP, 0.6), at), ghosts)
	if city._sea != null and city._sea.near != null:
		boat.wave_clock = func() -> float: return float(city._sea.near._time)
	var hulls: Array = [boat]
	var tick := func() -> void:
		HullMasks.update(hulls, city.camera.global_position)
	var t0 := Time.get_ticks_msec()
	while (not boat.bricked or boat.columns.is_empty()) and Time.get_ticks_msec() - t0 < 30000:
		await city.get_tree().process_frame
	for i in 240:
		tick.call()
		await city.get_tree().process_frame
	var tally := [0, 0]
	var check := func(what: String, c: bool, detail: String) -> void:
		print("[boat] %s %s  %s" % ["ok  " if c else "FAIL", what, detail])
		tally[0 if c else 1] += 1
	var hold_c := Vector3i(boat.seat_cell.x, int(boat.recipe.meta.boat.hold_y) + 2, boat.seat_cell.z)
	var hold := boat.global_transform * boat.cell_point(hold_c)
	check.call("its hold dry under the sea line, and not under water", hold.y < sea and HullMasks.dry_at(hold)
			and not city._sea.submerged_at(hold), "the hold at %.2f m, the sea at %.2f" % [hold.y, sea])
	# Beside it, low over the water, looking at its side.
	var side := boat.global_basis.z.normalized()
	city.camera.global_position = boat.global_position + side * 9.0 + Vector3(0, 1.2, 0)
	city.camera.look_at(boat.global_position + Vector3(0, 0.3, 0), Vector3.UP)
	for i in 10:
		tick.call()
		await city.get_tree().process_frame
	await _save("hull_boat_side")
	# On its deck, looking down into the sea over its side.
	city.camera.global_position = boat.global_transform * boat.cell_point(boat.seat_cell) + Vector3(0, 1.7, 0)
	city.camera.look_at(city.camera.global_position + side * 4.0 - Vector3(0, 2.0, 0), Vector3.UP)
	for i in 10:
		tick.call()
		await city.get_tree().process_frame
	await _save("hull_boat_deck")
	# In its hold, under the sea line: no sea inside.
	city.camera.global_position = hold + Vector3(0, 0.1, 0)
	city.camera.look_at(hold + boat.global_basis.x * 3.0, Vector3.UP)
	for i in 10:
		tick.call()
		await city.get_tree().process_frame
	await _save("hull_boat_hold")
	# Holed low on one side: its hold floods, the water drawn in it.
	var hole := boat.global_transform * boat.cell_point(Vector3i(boat.seat_cell.x, int(boat.recipe.meta.boat.hold_y), 0))
	boat.damage(hole, {"blast": true, "radius": 0.9, "hp": 0})
	for i in 300:
		tick.call()
		await city.get_tree().process_frame
	var flooded := boat.hull_water != null and boat.hull_water.total() > 50.0
	check.call("holed: its hold floods, the flooded cells no longer dry", flooded and boat.water_mesh != null
			and boat.water_mesh.mesh != null and not HullMasks.dry_at(boat.global_transform * boat.cell_point(
			Vector3i(boat.seat_cell.x, int(boat.recipe.meta.boat.hold_y), boat.seat_cell.z))),
			"%.0f cells of water, %.0f kg" % [boat.hull_water.total() if boat.hull_water != null else 0.0, boat.water_mass])
	city.camera.global_position = boat.global_transform * boat.cell_point(boat.seat_cell) + Vector3(0, 1.7, 0) 			- boat.global_basis.x * 3.0
	city.camera.look_at(boat.global_transform * boat.cell_point(Vector3i(boat.seat_cell.x, int(boat.recipe.meta.boat.hold_y), 2)), Vector3.UP)
	# The deck taken off over the hold, to see in.
	var lid := PackedInt32Array()
	var deck_y: int = int(boat.recipe.meta.boat.deck_y)
	for b in boat.bricks.get_block_count(boat.chunk):
		var c: Vector3i = boat.recipe.cell_of(boat.air._block_recipe[b]) - boat.recipe.origin()
		if c.y >= deck_y - 2 and c.y < deck_y and absi(c.x - boat.seat_cell.x) < 6 and c.z > 1 and c.z < 12:
			lid.append(b)
	boat.bricks.kill_blocks(boat.chunk, lid)
	boat._after_kill(lid)
	for i in 30:
		tick.call()
		await city.get_tree().process_frame
	await _save("hull_boat_flooded")
	print("[boat] %d ok, %d FAIL" % [tally[0], tally[1]])
	city.get_tree().quit(1 if int(tally[1]) > 0 else 0)

