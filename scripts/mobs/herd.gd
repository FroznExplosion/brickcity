class_name Herd
extends RefCounted
## A group of one kind of animal (Docs/MineCreatures.md 5, 11): what makes
## them a hunt and not Minecraft's "nothing happens until you hit one". The
## herd decides; each MobAnimal takes its place (order()).
##
## PREY (pig, deer, rabbit) and BOAR: one ALERT for the herd --
##   CALM   grazing round an anchor that wanders, heads down; or going for crops
##   WARY   heads up, they stop and look at you
##   ALARM  they bunch and walk off, away from you
##   FLEE   they bolt together, the same way, and settle far off
##   CHARGE a boar hurt with you near turns on you, then runs
## moved by NOTICE, a score that fills over time: sight (distance, the lookout
## sees better, heads-down grazers worse; not through ground), how you move
## (crouched, still, sprinting), light, SCENT on the wind (downwind of you they
## smell you from far off), noise (sprinting near). A shot, a hit, a death, or
## wolves closing in send them straight to FLEE.
##
## PREDATOR (wolf): a pack --
##   CALM   roaming round its anchor
##   STALK  walking in on a target (prey it hunts; the player at night, when
##          hurt, or when the pack was hurt by them) to 12 m
##   CIRCLE spread round it, running, until the ring is closed or 5 s pass
##   ATTACK in, biting
##   FLEE   half the pack lost: it breaks and runs
##
## Members are MobAnimal; they are not typed here (a cycle of class_name types
## leaks at exit).

enum Alert { CALM, WARY, ALARM, FLEE, CHARGE, STALK, CIRCLE, ATTACK }
const ALERT_NAMES := ["calm", "wary", "alarm", "flee", "charge", "stalk", "circle", "attack"]

const HZ := 4.0
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
const CHARGE_SECONDS := 6.0
const STALK_TO := 12.0
const RING := 6.0
const CIRCLE_SECONDS := 5.0

var mobs
var kind := &""
var def: Dictionary = {}
var members: Array = []
var home := Vector3.ZERO
var anchor := Vector3.ZERO
var alert := Alert.CALM
var notice := 0.0
var lookout := 0
var flee_to := Vector3.INF
var flee_from := Vector3.INF
## A predator's target: a MobAnimal, the player (&"player"), or null.
var target = null
## Some member is penned in (a fence, a room, a pit): the herd is saved.
var penned := false
## Senses off (a gate's crop checks): notice stays where it is.
var blind := false
## For gates and the readout.
var flees := 0
var notice_peak := 0.0
var last_rate := 0.0
var last_why := ""
var kills := 0
var started := 0

var _flee_until := 0.0
var _charge_until := 0.0
var _circle_since := 0.0
var _hurt_by_player := -INF
var _lookout_until := 0.0
var _next_graze := 0.0
var _next_crops := 0.0
var _next_target := 0.0
var _no_way := {}      # plot b -> until when nobody tries it
var _claims := {}      # member index -> plot entry
var _hp := {}          # member index -> health last seen
var _rng := RandomNumberGenerator.new()


func _init(p_mobs, p_kind: StringName, p_home: Vector3, seed := 1) -> void:
	mobs = p_mobs
	kind = p_kind
	def = CreatureBook.get_def(p_kind)
	home = p_home
	anchor = p_home
	_rng.seed = seed


func temper() -> String:
	return str(def.get("temper", "prey"))


func alive() -> Array:
	var out := []
	for m in members:
		if is_instance_valid(m) and not m.dead:
			out.append(m)
	return out


func centre() -> Vector3:
	var a := alive()
	if a.is_empty():
		return anchor
	var c := Vector3.ZERO
	for m in a:
		c += m.last_feet
	return c / a.size()


func alert_name() -> String:
	return ALERT_NAMES[alert]


## A shot, a blast, a death heard at `at`.
func startle(at: Vector3, why: String) -> void:
	if temper() == "predator":
		return            # a pack is not put off by a bang
	notice = maxf(notice, FLEE_AT + 0.3)
	_flee(at, why)


func _flee(from: Vector3, why: String) -> void:
	if alert != Alert.FLEE:
		flees += 1
		mobs.log_line("%ss flee: %s" % [kind, why])
	alert = Alert.FLEE
	flee_from = from
	_flee_until = mobs.now() + FLEE_SECONDS
	_claims.clear()
	target = null
	var c := centre()
	var away := Vector3(c.x - from.x, 0.0, c.z - from.z)
	away = away.normalized() if away.length() > 0.1 else Vector3.BACK
	# The leader's way: away, turned a little at random, onto a floor they fit.
	away = away.rotated(Vector3.UP, _rng.randf_range(-0.4, 0.4))
	var spot: Vector3 = mobs.nav.stand_near(c + away * FLEE_DIST, def.body, 10)
	flee_to = spot if spot != Vector3.INF else c + away * FLEE_DIST


## Member i's place round `about`: a loose ring.
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


## Where the target is (INF: none, or gone).
func target_feet() -> Vector3:
	if target is StringName:
		return mobs.player_feet()
	if target != null and is_instance_valid(target) and not target.dead:
		return target.last_feet
	return Vector3.INF


## A member was hit by the player: a pack remembers.
func hurt_by_player() -> void:
	_hurt_by_player = mobs.now()


func think(dt: float) -> void:
	var a := alive()
	if a.is_empty():
		return
	var now: float = mobs.now()
	var p: Dictionary = mobs.player_info()
	for i in members.size():
		var m = members[i]
		if not is_instance_valid(m):
			continue
		var hp: float = m.hp()
		if _hp.has(i) and hp < float(_hp[i]) - 0.01:
			var from: Vector3 = m.last_hit_from if m.last_hit_from != Vector3.INF else (p.feet if not p.is_empty() else m.last_feet)
			_on_hurt(m, from, hp <= 0.0, p, now)
		_hp[i] = hp
	if now > _lookout_until:
		_lookout_until = now + LOOKOUT_SECONDS
		lookout += 1
	if temper() == "predator":
		_pack(a, p, now)
		return
	if not blind:
		_sense(a, p, dt)
		_predators_near(now)
	_decide(a, p, now)


func _on_hurt(m, from: Vector3, killed: bool, p: Dictionary, now: float) -> void:
	var by_player: bool = m.last_hit_from == Vector3.INF or (not p.is_empty() and (p.feet as Vector3).distance_to(from) < 2.0)
	if by_player:
		_hurt_by_player = now
	match temper():
		"predator":
			if by_player and not (target is StringName):
				target = &"player"
				alert = Alert.ATTACK
		"boar":
			if not killed and by_player and not p.is_empty() and centre().distance_to(p.feet) < 14.0:
				if alert != Alert.CHARGE:
					mobs.log_line("boars charge")
				alert = Alert.CHARGE
				_charge_until = now + CHARGE_SECONDS
				_claims.clear()
			else:
				startle(from, "one was killed" if killed else "one was hurt")
		_:
			startle(from, "one was killed" if killed else "one was hurt")


func _sense(a: Array, p: Dictionary, dt: float) -> void:
	if p.is_empty():
		notice = maxf(0.0, notice - DECAY * dt)
		last_rate = 0.0
		return
	var feet: Vector3 = p.feet
	var chest: Vector3 = p.chest
	var c := centre()
	var sight: float = def.sight
	var scent_r: float = def.scent
	var nearest := INF
	for m in a:
		nearest = minf(nearest, (m.last_feet as Vector3).distance_to(feet))
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
	if nearest < sight:
		var lookers := [a[lookout % a.size()]]
		var near_m = a[0]
		for m in a:
			if (m.last_feet as Vector3).distance_to(feet) < (near_m.last_feet as Vector3).distance_to(feet):
				near_m = m
		if near_m != lookers[0]:
			lookers.append(near_m)
		var see := 0.0
		for m in lookers:
			var eye: Vector3 = m.last_feet + Vector3(0, m.eye_height(), 0)
			var d := eye.distance_to(chest)
			if d > sight:
				continue
			if not mobs.nav.line_clear(eye, chest):
				continue
			var keen := 1.6 if m == lookers[0] else (0.5 if alert == Alert.CALM else 1.0)
			see = maxf(see, keen * (1.0 - d / sight))
		if see > 0.0:
			# Seen walking in the open at 11 m: ~4 s to flee; standing still,
			# a few times that; crouched and still, hardly at all.
			rate += see * stance * light * 0.25
			why.append("sees %.2f" % (see * stance * light))
	# Scent: the wind carries it from the player to them.
	var w: Vector3 = mobs.wind
	var to_herd := Vector3(c.x - feet.x, 0.0, c.z - feet.z)
	var dh := to_herd.length()
	if dh < scent_r and dh > 0.01:
		var down := to_herd.dot(w) / dh
		if down > 0.4:
			var s := (down - 0.4) / 0.6 * (1.0 - dh / scent_r) * 0.5
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
	rate *= float(def.wary)
	last_rate = rate
	last_why = ", ".join(why)
	if rate > 0.001:
		notice += rate * dt
	else:
		notice = maxf(0.0, notice - DECAY * dt)
	notice = minf(notice, 1.6)
	notice_peak = maxf(notice_peak, notice)
	if alert != Alert.FLEE and alert != Alert.CHARGE and notice >= FLEE_AT:
		_flee(feet, "noticed (%s)" % last_why)


## A wolf pack closing on them: off, away from it.
func _predators_near(_now: float) -> void:
	if alert == Alert.FLEE or alert == Alert.CHARGE:
		return
	var c := centre()
	for h in mobs.herds:
		var o := h as Herd
		if o == self or o.temper() != "predator" or not (o.def.hunts as Array).has(kind):
			continue
		if not (o.alert in [Alert.STALK, Alert.CIRCLE, Alert.ATTACK]):
			continue
		var oc := o.centre()
		if oc.distance_to(c) < float(def.sight) * 0.6:
			_flee(oc, "wolves")
			return


func _decide(a: Array, p: Dictionary, now: float) -> void:
	var feet: Vector3 = p.feet if not p.is_empty() else Vector3.INF
	match alert:
		Alert.CHARGE:
			if now > _charge_until or feet == Vector3.INF:
				_flee(feet if feet != Vector3.INF else centre(), "done charging")
		Alert.FLEE:
			# Still close behind them: on again, from where the player is now.
			if feet != Vector3.INF and centre().distance_to(feet) < 12.0 and now > _flee_until - FLEE_SECONDS + 3.0 \
					and flee_from.distance_to(feet) < 30.0:
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
				var c := centre()
				var away := Vector3(c.x - feet.x, 0.0, c.z - feet.z).normalized()
				anchor = c + away * 8.0
				_claims.clear()
			if alert == Alert.CALM:
				_graze(now)


func _graze(now: float) -> void:
	var farming = mobs.host.farming
	var likes: Array = def.likes
	if farming != null and not likes.is_empty() and now >= _next_crops:
		_next_crops = now + 4.0
		for b in _no_way.keys():
			if now > float(_no_way[b]):
				_no_way.erase(b)
		var crops: Array = farming.crops_near(centre(), CROPS_RANGE, likes)
		var taken := {}
		for i in _claims:
			taken[_claims[i].b] = true
		for i in members.size():
			if _claims.has(i) or not is_instance_valid(members[i]) or members[i].dead:
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


# ---------------------------------------------------------------------------
# A pack

func _pack(a: Array, p: Dictionary, now: float) -> void:
	# Half lost: the pack breaks and runs.
	if a.size() * 2 < maxi(started, 1) and alert != Alert.FLEE:
		_flee(p.feet if not p.is_empty() else centre(), "the pack broke")
		alert = Alert.FLEE
	if alert == Alert.FLEE:
		if now > _flee_until:
			alert = Alert.CALM
			anchor = centre()
			home = anchor
			started = a.size()
		return
	var tf := target_feet()
	if tf == Vector3.INF or (tf.distance_to(centre()) > float(def.sight) * 1.6):
		if target != null:
			mobs.log_line("wolves lost their target")
		target = null
		if alert != Alert.CALM:
			alert = Alert.CALM
			anchor = centre()
	if target == null and now >= _next_target:
		_next_target = now + 2.0
		_pick_target(p, now)
		tf = target_feet()
	match alert:
		Alert.CALM:
			if target != null:
				alert = Alert.STALK
			elif now >= _next_graze:
				_next_graze = now + GRAZE_EVERY
				var ang := _rng.randf() * TAU
				anchor = home + Vector3(cos(ang), 0.0, sin(ang)) * _rng.randf_range(0.0, GRAZE_WANDER * 2.0)
		Alert.STALK:
			if centre().distance_to(tf) < STALK_TO:
				alert = Alert.CIRCLE
				_circle_since = now
		Alert.CIRCLE:
			var ringed := 0
			for i in a.size():
				if (a[i].last_feet as Vector3).distance_to(slot(i, tf, RING)) < 2.5:
					ringed += 1
			if ringed >= a.size() or now - _circle_since > CIRCLE_SECONDS:
				alert = Alert.ATTACK
				mobs.log_line("wolves close in on %s" % ("the player" if target is StringName else target.kind))
		Alert.ATTACK:
			pass


func _pick_target(p: Dictionary, now: float) -> void:
	var c := centre()
	var sight: float = def.sight
	if not p.is_empty():
		var night: bool = FarmPlant.sun_at(float(mobs.host.get("_time"))) < 0.35
		var weak: bool = mobs.player_health_frac() < 0.5
		var angry := now - _hurt_by_player < 60.0
		if (night or weak or angry) and (p.feet as Vector3).distance_to(c) < sight:
			target = &"player"
			mobs.log_line("wolves hunt the player (%s)" % ("night" if night else ("hurt" if weak else "angry")))
			return
	var best = null
	var best_d := sight
	var hunts: Array = def.hunts
	for h in mobs.herds:
		var o := h as Herd
		if o == self or not hunts.has(o.kind):
			continue
		for m in o.alive():
			var d := (m.last_feet as Vector3).distance_to(c)
			if d < best_d:
				best_d = d
				best = m
	if best != null:
		target = best
		mobs.log_line("wolves hunt a %s %.0f m off" % [best.kind, best_d])


## What member `m` (index i) is to do: {to, speed, run, face, bite}.
func order(m, i: int) -> Dictionary:
	var a := alive()
	var sp: Dictionary = def.speed
	var p: Dictionary = mobs.player_info()
	var pf: Vector3 = p.feet if not p.is_empty() else Vector3.INF
	match alert:
		Alert.FLEE:
			var to := slot(i, flee_to, 1.8)
			return {"to": to, "speed": sp.flee, "run": true, "state": "flee"}
		Alert.CHARGE:
			return {"to": pf, "speed": sp.charge, "run": true, "state": "charge", "bite": def.charge_damage, "target": &"player"}
		Alert.ALARM:
			return {"to": slot(i, anchor, 1.6), "speed": sp.alarm, "run": false, "state": "alarm", "face": pf}
		Alert.WARY:
			return {"to": Vector3.INF, "speed": sp.graze, "run": false, "state": "wary", "face": pf}
		Alert.STALK:
			var tf := target_feet()
			var back := (centre() - tf)
			back.y = 0.0
			back = back.normalized() * (STALK_TO - 2.0) if back.length() > 0.1 else Vector3.ZERO
			return {"to": slot(i, tf + back, 2.0), "speed": sp.stalk, "run": false, "state": "stalk", "face": tf}
		Alert.CIRCLE:
			var tf2 := target_feet()
			return {"to": slot(i, tf2, RING), "speed": sp.hunt, "run": true, "state": "circle", "face": tf2}
		Alert.ATTACK:
			return {"to": target_feet(), "speed": sp.hunt, "run": true, "state": "attack", "bite": def.bite_damage, "target": target}
	var claim := claim_of(i)
	if not claim.is_empty():
		return {"to": claim.at, "speed": sp.graze, "run": false, "state": "to crops", "crop": claim}
	return {"to": slot(i, anchor, 2.2 if temper() != "predator" else 3.0), "speed": sp.graze, "run": false,
			"state": "lookout" if is_lookout(m) else ("roam" if temper() == "predator" else "graze")}
