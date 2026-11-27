class_name MobPig
extends Mob
## A pig (Docs/MineCreatures.md 5): one of a PigHerd, which decides; the pig
## does its part. 2 studs across, 2 bricks (6 plates) high, steps up a brick:
## a fence two bricks high keeps it out. It digs up crops it can walk to
## (MineFarming.animal_eat); a fall of 2 bricks onto a plot tramples it.

const BODY := PigHerd.PIG_BODY
const HP := 30.0
const HEIGHT := Pawn.PLATE_M * 6.0
const BITE_EVERY := 4.0
const EAT_REACH := 0.75

var herd: PigHerd
var index := 0
var bites := 0
var _next_bite := 0.0


func _init() -> void:
	kind = &"pig"
	body = BODY
	trample_bricks = 2.0


func think(now: float) -> void:
	var p: Dictionary = mobs.player_info()
	running = false
	face_point = Vector3.INF
	match herd.alert:
		PigHerd.Alert.FLEE:
			state = "flee"
			running = true
			pawn.move_mult = 0.85
			walk_to(herd.slot(index, herd.flee_to, 1.8), now)
		PigHerd.Alert.ALARM:
			state = "alarm"
			pawn.move_mult = 0.55
			walk_to(herd.slot(index, herd.anchor, 1.6), now)
			if not p.is_empty():
				face_point = p.feet if arrived() else Vector3.INF
		PigHerd.Alert.WARY:
			state = "wary"
			stop()
			if not p.is_empty():
				face_point = p.feet
		_:
			pawn.move_mult = 0.4
			var claim := herd.claim_of(index)
			if not claim.is_empty():
				_go_eat(claim, now)
			else:
				state = "lookout" if herd.is_lookout(self) else "graze"
				walk_to(herd.slot(index, herd.anchor), now)
	_head()


func _go_eat(claim: Dictionary, now: float) -> void:
	var at: Vector3 = claim.at
	var f := feet()
	var flat := Vector2(at.x - f.x, at.z - f.z).length()
	if flat <= EAT_REACH and absf(at.y - f.y) < 0.5:
		state = "eating"
		stop()
		face_point = at
		if now >= _next_bite:
			_next_bite = now + BITE_EVERY
			if mobs.host.farming.animal_eat(claim.b):
				bites += 1
				mobs.log_line("a pig ate at %s" % claim.b)
			var left: Dictionary = mobs.host.farming.store.get_plot(claim.b)
			if left.is_empty() or left.crop == &"":
				herd.crop_done(index)
		return
	state = "to crops"
	walk_to(at, now)
	# The way there ends short of it: fenced or walled in. Try another.
	if answered and not path_reached and arrived():
		herd.no_way(claim.b)
		mobs.log_line("a pig found no way to %s" % claim.b)


## Head down grazing, up when wary or on lookout.
func _head() -> void:
	if look == null:
		return
	var head := look.get_node_or_null(^"head") as Node3D
	if head == null:
		return
	var down := herd.alert == PigHerd.Alert.CALM and not herd.is_lookout(self)
	head.rotation.x = -0.45 if down else 0.15
