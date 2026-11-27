class_name MobAnimal
extends Mob
## An animal of the mine world (Docs/MineCreatures.md 5, 11): one of a Herd,
## which decides; the animal does its part (Herd.order). What kind it is --
## body, speeds, temper, what it eats or hunts, what it drops -- is its
## CreatureBook entry, so a pig, a deer, a rabbit, a boar and a wolf are all
## this script.
##
## It eats a crop it can walk to (MineFarming.animal_eat). A path that ends
## short of the crop means "no way" for 30 s (fenced, walled in). It bites
## (a wolf, a charging boar) what it can walk to. A rabbit zigzags when it
## runs; a deer jumps 2 bricks (Mob.jumps).

const BITE_EVERY := 1.2
const BITE_REACH := 1.5
const EAT_EVERY := 4.0
const EAT_REACH := 0.75
const ZIG_EVERY := 0.6

var herd: Herd
var index := 0
var def: Dictionary = {}
var bites := 0
var meals := 0
var _next_bite := 0.0
var _next_meal := 0.0
var _zig := 1.0
var _next_zig := 0.0


func setup_kind(k: StringName) -> void:
	kind = k
	def = CreatureBook.get_def(k)
	body = def.body
	trample_bricks = float(def.trample_bricks)
	jumps = bool(def.jump)


func height_m() -> float:
	return float(body.y) * Pawn.PLATE_M


func eye_height() -> float:
	return height_m() * 0.8


func think(now: float) -> void:
	var o := herd.order(self, index)
	state = str(o.state)
	running = bool(o.run)
	pawn.move_mult = float(o.speed)   # of the run when running, of the walk when not
	face_point = o.get("face", Vector3.INF)
	var to: Vector3 = o.to
	if o.has("crop"):
		_go_eat(o.crop, now)
	elif to == Vector3.INF:
		stop()
	else:
		walk_to(to, now)
	if float(o.get("bite", 0.0)) > 0.0:
		_bite(o, now)


## Mob: where to walk this tick when the order is to run straight at something.
func steer_point() -> Vector3:
	if (state == "attack" or state == "charge") and herd != null:
		var t: Vector3 = herd.target_feet() if state == "attack" else mobs.player_feet()
		if t != Vector3.INF and t.distance_to(last_feet) < 6.0 and mobs.nav.line_clear(last_feet + Vector3(0, 0.3, 0), t + Vector3(0, 0.3, 0)):
			return t
	if state == "flee" and bool(def.zigzag) and not _path.is_empty() and _wp < _path.size():
		var now: float = mobs.now()
		if now > _next_zig:
			_next_zig = now + ZIG_EVERY
			_zig = -_zig
		var ahead: Vector3 = _path[_wp] - last_feet
		ahead.y = 0.0
		if ahead.length() > 0.01:
			var side := Vector3(-ahead.z, 0.0, ahead.x).normalized() * _zig * 0.8
			return _path[_wp] + side
	return Vector3.INF


func _bite(o: Dictionary, now: float) -> void:
	if now < _next_bite:
		return
	var t = o.get("target")
	var tf: Vector3 = mobs.player_feet() if t is StringName else (t.last_feet if t != null and is_instance_valid(t) and not t.dead else Vector3.INF)
	if tf == Vector3.INF:
		return
	var d := Vector2(tf.x - last_feet.x, tf.z - last_feet.z).length()
	if d > BITE_REACH or absf(tf.y - last_feet.y) > 1.0:
		return
	if not mobs.nav.line_clear(last_feet + Vector3(0, 0.3, 0), tf + Vector3(0, 0.3, 0)):
		return    # never through a fence or a wall
	_next_bite = now + BITE_EVERY
	bites += 1
	var dmg := float(o.bite)
	if t is StringName:
		mobs.hurt_player(self, dmg, (tf - last_feet).normalized())
	else:
		t.last_hit_from = last_feet
		t.pawn.health.apply_impact(dmg, &"")
		if t.pawn.health.is_dead():
			herd.kills += 1
			mobs.log_line("a %s killed a %s" % [kind, t.kind])


func _go_eat(claim: Dictionary, now: float) -> void:
	var at: Vector3 = claim.at
	var flat := Vector2(at.x - last_feet.x, at.z - last_feet.z).length()
	if flat <= EAT_REACH and absf(at.y - last_feet.y) < 0.5:
		state = "eating"
		stop()
		face_point = at
		if now >= _next_meal:
			_next_meal = now + EAT_EVERY
			if mobs.host.farming.animal_eat(claim.b):
				meals += 1
				mobs.log_line("a %s ate at %s" % [kind, claim.b])
			var left: Dictionary = mobs.host.farming.store.get_plot(claim.b)
			if left.is_empty() or left.crop == &"":
				herd.crop_done(index)
		return
	state = "to crops"
	walk_to(at, now)
	# The way there ends short of it: fenced or walled in. Try another.
	if answered and not path_reached and arrived():
		herd.no_way(claim.b)
		mobs.log_line("a %s found no way to %s" % [kind, claim.b])


## Head down grazing, up otherwise.
func _animate(delta: float) -> void:
	super._animate(delta)
	if look == null or herd == null:
		return
	var head := look.get_node_or_null(^"head") as Node3D
	if head != null:
		var down := herd.alert == Herd.Alert.CALM and state == "graze"
		head.rotation.x = -0.45 if down else 0.15
