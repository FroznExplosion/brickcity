class_name PigHerd
extends RefCounted
## A herd of pigs (Docs/MineCreatures.md 5.1): what makes them a hunt and not
## Minecraft's "nothing happens until you hit one". One ALERT for the herd:
##
##   CALM   grazing round an anchor that wanders, heads down; or going for crops
##   WARY   heads up, they stop and look at you
##   ALARM  they bunch and walk off, away from you
##   FLEE   they bolt together, the same way, and settle far off
##
## What moves it is NOTICE, a score that fills over time (not a yes/no):
## sight (distance, the lookout sees better, heads-down grazers worse; behind
## ground they do not see), how you move (crouched, still, sprinting), light,
## SCENT on the wind (downwind of you they smell you from far off; come at them
## with the wind in your face), and noise (sprinting near; a shot, a hit or a
## death sends them straight to FLEE).
##
## Members are MobPig; they are not typed here (a cycle of class_name types
## leaks at exit).

enum Alert { CALM, WARY, ALARM, FLEE }
const ALERT_NAMES := ["calm", "wary", "alarm", "flee"]

const HZ := 4.0
## A pig's TerrainNav body (MobPig.BODY is this): 2 studs, 6 plates, steps a brick, drops 9 plates.
const PIG_BODY := Vector4i(2, 6, 3, 9)
const SIGHT := 30.0
const SCENT := 44.0
const WARY_AT := 0.25
const ALARM_AT := 0.6
const FLEE_AT := 1.0
const CALM_BELOW := 0.12
const DECAY := 0.05
const FLEE_DIST := 34.0
const FLEE_SECONDS := 14.0
const LOOKOUT_SECONDS := 10.0
const GRAZE_WANDER := 5.0
const GRAZE_EVERY := 7.0
const CROPS_RANGE := 32.0
## What a pig digs up (Docs/MineFarming.md crops).
const LIKES := [&"potato", &"carrot", &"beetroot", &"wheat", &"pumpkin", &"melon", &"corn", &"cabbage", &"beans"]

var mobs
var members: Array = []
var home := Vector3.ZERO
var anchor := Vector3.ZERO
var alert := Alert.CALM
var notice := 0.0
var lookout := 0
var flee_to := Vector3.INF
var flee_from := Vector3.INF
## For gates and the readout.
var flees := 0
var notice_peak := 0.0
var last_rate := 0.0
var last_why := ""
## Senses off (a gate's crop checks): notice stays where it is.
var blind := false

var _flee_until := 0.0
var _lookout_until := 0.0
var _next_graze := 0.0
var _next_crops := 0.0
var _no_way := {}      # plot b -> until when nobody tries it
var _claims := {}      # member index -> plot entry
var _hp := {}          # member index -> health last seen
var _rng := RandomNumberGenerator.new()


func _init(p_mobs, p_home: Vector3, seed := 1) -> void:
	mobs = p_mobs
	home = p_home
	anchor = p_home
	_rng.seed = seed


func alive() -> Array:
	var out := []
	for m in members:
		if is_instance_valid(m) and not m.is_dead():
			out.append(m)
	return out


func centre() -> Vector3:
	var a := alive()
	if a.is_empty():
		return anchor
	var c := Vector3.ZERO
	for m in a:
		c += m.feet()
	return c / a.size()


func alert_name() -> String:
	return ALERT_NAMES[alert]


## A shot, a blast, a death heard at `at`.
func startle(at: Vector3, why: String) -> void:
	notice = maxf(notice, FLEE_AT + 0.3)
	_flee(at, why)


func _flee(from: Vector3, why: String) -> void:
	if alert != Alert.FLEE:
		flees += 1
		mobs.log_line("pigs flee: %s" % why)
	alert = Alert.FLEE
	flee_from = from
	_flee_until = mobs.now() + FLEE_SECONDS
	_claims.clear()
	var c := centre()
	var away := Vector3(c.x - from.x, 0.0, c.z - from.z)
	away = away.normalized() if away.length() > 0.1 else Vector3.BACK
	# The leader's way: away, turned a little at random, onto a floor they fit.
	away = away.rotated(Vector3.UP, _rng.randf_range(-0.4, 0.4))
	var spot: Vector3 = mobs.nav.stand_near(c + away * FLEE_DIST, PIG_BODY, 10)
	flee_to = spot if spot != Vector3.INF else c + away * FLEE_DIST


## Member i's place round `about`: a loose ring, tighter when fleeing.
func slot(i: int, about: Vector3, ring := 2.2) -> Vector3:
	var n := maxi(members.size(), 1)
	var ang := TAU * float(i) / float(n) + float(i) * 0.7
	return about + Vector3(cos(ang), 0.0, sin(ang)) * ring * (0.6 + 0.4 * float(i % 2))


func is_lookout(m) -> bool:
	var a := alive()
	return not a.is_empty() and a[lookout % a.size()] == m


## The crop member `i` is going for ({} for none).
func claim_of(i: int) -> Dictionary:
	return _claims.get(i, {})


func no_way(b: Vector3i) -> void:
	_no_way[b] = mobs.now() + 30.0
	for i in _claims.keys():
		if _claims[i].b == b:
			_claims.erase(i)


func crop_done(i: int) -> void:
	_claims.erase(i)


func think(dt: float) -> void:
	var a := alive()
	if a.is_empty():
		return
	var now: float = mobs.now()
	# Hurt or killed: everyone runs from the player.
	var p: Dictionary = mobs.player_info()
	for i in members.size():
		var m = members[i]
		if not is_instance_valid(m):
			continue
		var hp: float = m.pawn.health.total_current() if (m.pawn != null and is_instance_valid(m.pawn) and m.pawn.health != null) else 0.0
		if _hp.has(i) and hp < float(_hp[i]) - 0.01:
			startle(p.feet if not p.is_empty() else m.feet(), "one was hurt" if hp > 0.0 else "one was killed")
		_hp[i] = hp
	if now > _lookout_until:
		_lookout_until = now + LOOKOUT_SECONDS
		lookout += 1
	if not blind:
		_sense(a, p, dt, now)
	_decide(a, p, now)


func _sense(a: Array, p: Dictionary, dt: float, now: float) -> void:
	if p.is_empty():
		notice = maxf(0.0, notice - DECAY * dt)
		last_rate = 0.0
		return
	var feet: Vector3 = p.feet
	var chest: Vector3 = p.chest
	var c := centre()
	var nearest := INF
	for m in a:
		nearest = minf(nearest, (m.feet() as Vector3).distance_to(feet))
	var rate := 0.0
	var why := PackedStringArray()
	# How the player moves: crouched and still is nearly invisible.
	var stance := 1.0
	if bool(p.crouched):
		stance *= 0.35
	if float(p.speed) < 0.3:
		stance *= 0.4
	elif bool(p.sprinting):
		stance *= 2.0
	var light := clampf(float(p.light), 0.3, 1.0)
	# Sight: the lookout and the nearest one look (two rays a think).
	if nearest < SIGHT:
		var lookers := [a[lookout % a.size()]]
		var near_m = a[0]
		for m in a:
			if (m.feet() as Vector3).distance_to(feet) < (near_m.feet() as Vector3).distance_to(feet):
				near_m = m
		if near_m != lookers[0]:
			lookers.append(near_m)
		var see := 0.0
		for m in lookers:
			var eye: Vector3 = m.feet() + Vector3(0, 0.6, 0)
			var d := eye.distance_to(chest)
			if d > SIGHT:
				continue
			if not mobs.nav.line_clear(eye, chest):
				continue
			var keen := 1.6 if m == lookers[0] else (0.5 if alert == Alert.CALM else 1.0)
			see = maxf(see, keen * (1.0 - d / SIGHT))
		if see > 0.0:
			# Seen walking in the open at 11 m: ~4 s to flee; standing still,
			# a few times that; crouched and still, hardly at all.
			rate += see * stance * light * 0.25
			why.append("sees %.2f" % (see * stance * light))
	# Scent: the wind carries it from the player to them.
	var w: Vector3 = mobs.wind
	var to_herd := Vector3(c.x - feet.x, 0.0, c.z - feet.z)
	var dh := to_herd.length()
	if dh < SCENT and dh > 0.01:
		var down := to_herd.dot(w) / dh
		if down > 0.4:
			var s := (down - 0.4) / 0.6 * (1.0 - dh / SCENT) * 0.5
			rate += s
			why.append("smells %.2f" % s)
	if dh < 3.5:
		rate += 0.4        # right next to them: smelt whatever the wind
	# Noise: running near them.
	if bool(p.sprinting) and nearest < 18.0:
		var n := 0.5 * (1.0 - nearest / 18.0)
		rate += n
		why.append("hears %.2f" % n)
	if nearest < 6.0:
		rate *= 2.0
	last_rate = rate
	last_why = ", ".join(why)
	if rate > 0.001:
		notice += rate * dt
	else:
		notice = maxf(0.0, notice - DECAY * dt)
	notice = minf(notice, 1.6)
	notice_peak = maxf(notice_peak, notice)
	if alert != Alert.FLEE and notice >= FLEE_AT:
		_flee(feet, "noticed (%s)" % last_why)


func _decide(a: Array, p: Dictionary, now: float) -> void:
	var feet: Vector3 = p.feet if not p.is_empty() else Vector3.INF
	match alert:
		Alert.FLEE:
			# Still close behind them: on again, from where the player is now.
			if feet != Vector3.INF and centre().distance_to(feet) < 12.0 and now > _flee_until - FLEE_SECONDS + 3.0:
				_flee(feet, "still followed")
			elif now > _flee_until:
				alert = Alert.ALARM if notice > ALARM_AT else Alert.WARY
				notice = minf(notice, ALARM_AT - 0.05)
				anchor = centre()
				home = anchor
		_:
			var was := alert
			if notice >= ALARM_AT:
				alert = Alert.ALARM
			elif notice >= WARY_AT:
				alert = Alert.WARY
			elif notice < CALM_BELOW:
				alert = Alert.CALM
			if alert == Alert.ALARM and was != Alert.ALARM and feet != Vector3.INF:
				# Walk off a few metres, away.
				var c := centre()
				var away := Vector3(c.x - feet.x, 0.0, c.z - feet.z).normalized()
				anchor = c + away * 8.0
				_claims.clear()
			if alert == Alert.CALM:
				_graze(a, now)


func _graze(a: Array, now: float) -> void:
	var farming = mobs.host.farming
	if farming != null and now >= _next_crops:
		_next_crops = now + 4.0
		for b in _no_way.keys():
			if now > float(_no_way[b]):
				_no_way.erase(b)
		var crops: Array = farming.crops_near(centre(), CROPS_RANGE, LIKES)
		var taken := {}
		for i in _claims:
			taken[_claims[i].b] = true
		for i in members.size():
			if _claims.has(i) or not is_instance_valid(members[i]) or members[i].is_dead():
				continue
			for e in crops:
				if not taken.has(e.b) and not _no_way.has(e.b):
					_claims[i] = e
					taken[e.b] = true
					break
		if not _claims.is_empty():
			anchor = (_claims.values()[0].at as Vector3)
	if _claims.is_empty() and now >= _next_graze:
		_next_graze = now + GRAZE_EVERY
		var ang := _rng.randf() * TAU
		anchor = home + Vector3(cos(ang), 0.0, sin(ang)) * _rng.randf_range(0.0, GRAZE_WANDER)
