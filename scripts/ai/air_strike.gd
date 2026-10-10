class_name AirStrike
extends Node
## A fast plane's run (Docs/AIRoster.md 7, R10): not an agent -- no navigation,
## no brain. A side buys one (AirSupport); it is a LINE across the map through a
## target point, flown once:
##
##   WARN     WARN_SECONDS of warning first: the caller's shout, the engine heard
##   PASS     in from LEAD metres out along the line, at ALTITUDE over the tallest
##            thing under the line, at SPEED, and away the other side
##   STRAFE   over the WINDOW round the point, rounds walk along the ground ahead
##            of it: ROUND_DAMAGE to anyone within ROUND_REACH of each, with a
##            clear line from the plane
##   BOMBS    over the WINDOW, BOMBS of them, evenly spaced: a blast each, in the
##            bricks too
##
## It can be shot at on the pass: its body has a HealthPool like any flyer's, and
## shot down it falls along its line and crashes (a blast), the run over.
## Whose weapon: a vehicle's, on the mech's scale -- a mech takes it on its hull.

const WARN_SECONDS := 3.0
const LEAD := 260.0
const SPEED := 70.0
const ALTITUDE := 30.0
const WINDOW := 40.0
const HEALTH := 400.0
## Rounds land every ROUND_SPACING metres along the window, this far ahead of
## the plane, a little either side of the line.
const ROUND_SPACING := 1.2
const ROUND_REACH := 2.0
const ROUND_DAMAGE := 30.0
const ROUND_AHEAD := 25.0
const ROUND_SPREAD := 1.2
const BOMBS := 6
const BOMB_DAMAGE := 160.0
const BOMB_RADIUS := 6.0
const CRASH := [120.0, 7.0]
const FALL_G := 15.0

signal warned(kind: String, at: Vector3)
signal passed
signal shot_down(at: Vector3)

var services: AIServices
var team := 1
var kind := "strafe"
var target := Vector3.ZERO
var dir := Vector3.FORWARD
var caller: Pawn
var body: CharacterBody3D
var health: HealthPool
var state := "warn"
## For gates: every pawn it hurt, [pawn, damage]; rounds and bombs let go.
var hits: Array = []
var rounds := 0
var bombs := 0
var _t := 0.0
var _start := Vector3.ZERO
var _alt := 0.0
var _next_round := -WINDOW
var _bombs_at: Array[float] = []
var _falling := false


## A run of `kind` ("strafe" or "bombs") along `p_dir` through `at`.
static func launch(s: AIServices, parent: Node, at: Vector3, p_dir: Vector3, p_kind: String,
		p_team: int, p_caller: Pawn = null) -> AirStrike:
	var a := AirStrike.new()
	a.name = "AirStrike"
	a.services = s
	a.team = p_team
	a.kind = p_kind
	a.target = at
	var d := Vector3(p_dir.x, 0.0, p_dir.z)
	a.dir = d.normalized() if d.length() > 0.01 else Vector3.FORWARD
	a.caller = p_caller
	parent.add_child(a)
	a._begin()
	return a


func _begin() -> void:
	_start = target - dir * LEAD
	# Over the tallest thing under its line.
	var top := 0.0
	var k := -LEAD
	while k <= LEAD:
		var p := target + dir * k
		var h := services.ai_world.top_at(p.x, p.z)
		if is_finite(h):
			top = maxf(top, h)
		k += 5.0
	_alt = maxf(top, target.y) + ALTITUDE
	for i in BOMBS:
		_bombs_at.append(-WINDOW + (2.0 * WINDOW) * (float(i) + 0.5) / float(BOMBS))
	body = CharacterBody3D.new()
	body.name = "PlaneBody"
	body.collision_layer = Layers.PAWN
	body.collision_mask = 0
	body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var sh := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(9.0, 1.6, 7.0)
	sh.shape = box
	body.add_child(sh)
	health = HealthPool.new()
	health.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.max_value = HEALTH
	health.layer_configs = [layer]
	body.add_child(health)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(9.0, 0.5, 2.0)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.37, 0.4)
	mi.material_override = mat
	body.add_child(mi)
	var hull := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(1.4, 1.2, 7.0)
	hull.mesh = hm
	hull.material_override = mat
	body.add_child(hull)
	body.visible = false
	add_child(body)
	body.global_position = _start + Vector3.UP * _alt
	body.look_at(body.global_position + dir, Vector3.UP)
	if caller != null and is_instance_valid(caller):
		services.say(caller, "air_inbound", ["Air strike inbound!", "Strafing run, get down!",
				"Bombs on the way!"][services.rng.randi() % 3], AIServices.SHOUT)
	warned.emit(kind, target)


## How far along its line it is, metres from the target point (negative: before).
func along() -> float:
	return (body.global_position - target).dot(dir)


func is_down() -> bool:
	return health.is_dead()


func _physics_process(delta: float) -> void:
	_t += delta
	if _t < WARN_SECONDS:
		return
	if state == "warn":
		state = "pass"
		body.visible = true
		# The engine: heard all round as it comes in.
		services.noise(body.global_position, LEAD, null)
	if is_down():
		_fall(delta)
		return
	var flown := (_t - WARN_SECONDS) * SPEED
	body.global_position = _start + dir * flown + Vector3.UP * _alt
	var x := along()
	if x > LEAD:
		state = "gone"
		passed.emit()
		queue_free()
		return
	if kind == "strafe":
		_strafe(x + ROUND_AHEAD)
	elif absf(x) <= WINDOW:
		_bomb(x)


## The burst: rounds walk along the ground ahead of it, up to `upto` along the
## line, every ROUND_SPACING metres of the window.
func _strafe(upto: float) -> void:
	while _next_round <= minf(upto, WINDOW):
		_round(target + dir * _next_round)
		_next_round += ROUND_SPACING


func _round(on_line: Vector3) -> void:
	var side := dir.cross(Vector3.UP)
	var at := on_line + side * services.rng.randf_range(-ROUND_SPREAD, ROUND_SPREAD)
	at.y = _ground(at)
	rounds += 1
	var from := body.global_position
	for p in services.pawns:
		if not is_instance_valid(p) or p.team == team or p.health == null or p.health.is_dead():
			continue
		var f := p.feet()
		if Vector2(f.x - at.x, f.z - at.z).length() > ROUND_REACH or absf(f.y - at.y) > 3.0:
			continue
		if not services.ai_world.line_clear(from, p.chest()):
			continue
		var ml := MechLayers.of(p.body)
		if ml != null:
			ml.take(ROUND_DAMAGE, &"mech")
		else:
			p.health.apply_impact(ROUND_DAMAGE, &"")
		hits.append([p, ROUND_DAMAGE])


func _bomb(x: float) -> void:
	while not _bombs_at.is_empty() and x >= _bombs_at[0]:
		var k: float = _bombs_at.pop_front()
		var at := target + dir * k
		at.y = _ground(at)
		bombs += 1
		var b := Grenade.blast(services, at, null, BOMB_DAMAGE, BOMB_RADIUS)
		hits.append_array(b)
		if services.on_breach.is_valid():
			services.on_breach.call(at, 2.0)


## The top of what is under `p`: a roof, or the ground.
func _ground(p: Vector3) -> float:
	var h := services.ai_world.top_at(p.x, p.z)
	return h if is_finite(h) else target.y


func _fall(delta: float) -> void:
	if state == "crashed":
		return
	if not _falling:
		_falling = true
		state = "falling"
		shot_down.emit(body.global_position)
	var v := dir * SPEED * 0.8 + Vector3.DOWN * FALL_G * (_t - WARN_SECONDS) * 0.5
	body.global_position += v * delta
	var p := body.global_position
	if p.y <= _ground(p) + 0.8:
		state = "crashed"
		hits.append_array(Grenade.blast(services, p, null, CRASH[0], CRASH[1]))
		if services.on_breach.is_valid():
			services.on_breach.call(p, 2.5)
		body.visible = false
		queue_free()
