class_name HitReaction
extends Node3D
## What a round does to the body it hits, past its damage: a FLINCH -- the body
## jerks back and comes upright -- and, hit hard enough, a STUMBLE -- it reels,
## held where it stands for a moment (Pawn.stagger), knocked back along the shot,
## and leans away from it as it goes.
##
## How hard a round hits is its class's IMPACT and how near it was fired from. A
## shotgun at a few metres stumbles a soldier and throws him back; the same shot
## at ten metres only makes him flinch. A rifle round only ever flinches.
##
## The light and heavy kinds of each class (COMBAT_DESIGN 7.8) scale this when
## they exist: a gun's `archetype` (&"light" or &"heavy"), if it has one, is read
## through ARCHETYPE -- a light shotgun stumbles only when nearly touching, a
## heavy one from further off and harder. Without one, the class's numbers stand.
##
## One of these hangs on each body that has been hit (the first hit makes it). It
## leans the body's LOOK -- its meshes, never its collision or its eye -- about the
## feet, and puts it back exactly when the lean is spent.

## Per class: [stumble seconds at full impact, knock-back m/s at full impact,
## range of full impact m, range past which nothing m]. A stumble needs at least
## STUMBLE_MIN seconds' worth; less is a flinch.
const IMPACT := {
	&"shotgun": [0.7, 7.0, 4.0, 12.0],
	&"revolver": [0.45, 3.0, 8.0, 30.0],
	&"sniper": [0.55, 3.5, 30.0, 120.0],
	&"dmr": [0.3, 1.5, 15.0, 60.0],
	&"pistol": [0.12, 0.6, 6.0, 25.0],
	&"smg": [0.08, 0.4, 5.0, 20.0],
	&"rifle": [0.1, 0.5, 10.0, 40.0],
	&"lmg": [0.12, 0.6, 10.0, 40.0],
}
## The light and heavy kinds: [impact x, ranges x]. A light gun's impact falls off
## twice as soon, so it only stumbles at the muzzle; a heavy's reaches further.
const ARCHETYPE := {
	&"light": [0.6, 0.5],
	&"heavy": [1.6, 1.6],
}
const STUMBLE_MIN := 0.2
## The lean: how far a full stumble tips the body, and a flinch, radians.
const LEAN_STUMBLE := 0.45
const LEAN_FLINCH := 0.12
const LEAN_STIFF := 70.0
const LEAN_DAMP := 9.0

var _pawn: Pawn
var _parts: Array[Node3D] = []
var _rest: Array[Transform3D] = []
## The lean: an angle about an axis lying on the ground, on a spring.
var _axis := Vector3.RIGHT
var _angle := 0.0
var _speed := 0.0
## For the --arms pass: stumbles this body has taken.
var stumbles := 0


## A round from `from` struck `info` (GunController.fired's shape) out of `gun`.
## Returns the stumble it caused, seconds (0 a flinch, or nothing).
static func hit(gun: GunInstance, from: Vector3, info: Dictionary) -> float:
	if info.is_empty() or gun == null or gun.weapon_class == null:
		return 0.0
	var collider := info.get("collider") as Node
	if collider == null or not is_instance_valid(collider):
		return 0.0
	var pawn := _pawn_of(collider)
	if pawn == null or pawn.is_player or pawn.body == null:
		return 0.0
	var row: Array = IMPACT.get(gun.weapon_class.id, [])
	if row.is_empty():
		return 0.0
	var arch: Array = ARCHETYPE.get(gun.get(&"archetype") if &"archetype" in gun else &"", [1.0, 1.0])
	var point: Vector3 = info.get("point", pawn.chest())
	# Past its range a round still makes him flinch: every hit that lands reads. A
	# shotgun blast pushes by the share of its pellets that struck; a charged shot's
	# knockback, KNOCK_MULT as hard (GunFireMode).
	var k := impact(row, arch, from.distance_to(point))
	if info.has("pellets"):
		k *= float(info.pellets_hit) / maxf(float(info.pellets), 1.0)
	k *= float(info.get("impact_mult", 1.0))
	var dir := point - from
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.ZERO
	var seconds := float(row[0]) * k
	var stumble := seconds >= STUMBLE_MIN
	if stumble:
		pawn.stagger(seconds, dir * float(row[1]) * k)
	# Any hit that lands reads: a flinch is at least half one, however far.
	var lean := LEAN_STUMBLE * minf(k, 1.5) if stumble else LEAN_FLINCH * clampf(k * 2.0, 0.5, 1.0)
	# Straight back reads poorly from the gun that did it: the body also twists off
	# toward the side the round struck (or, dead centre, one side then the other).
	var r := _on(pawn)
	var side_v := Vector3(-dir.z, 0.0, dir.x)
	var off := (point - pawn.chest()).dot(side_v)
	var side := clampf(off * 4.0, -0.7, 0.7)
	if absf(side) < 0.2:
		side = 0.45 if r.stumbles % 2 == 0 else -0.45
	r.lean((dir + side_v * side).normalized(), lean, stumble)
	return seconds if stumble else 0.0


## 0..: how hard a round of this class (and kind) lands at `dist` metres. Full out
## to the class's near range, nothing past its far one, a straight fall between.
static func impact(row: Array, arch: Array, dist: float) -> float:
	var near := float(row[2]) * float(arch[1])
	var far := float(row[3]) * float(arch[1])
	var fall := 1.0 - clampf((dist - near) / maxf(far - near, 0.01), 0.0, 1.0)
	return fall * float(arch[0])


static func _pawn_of(n: Node) -> Pawn:
	var body := n if n is CharacterBody3D else n.get_parent()
	for i in 2:
		if body == null:
			return null
		for c in body.get_children():
			if c is Pawn:
				return c
		body = body.get_parent()
	return null


static func _on(pawn: Pawn) -> HitReaction:
	var had := pawn.body.get_node_or_null(^"HitReaction") as HitReaction
	if had != null:
		return had
	var r := HitReaction.new()
	r.name = "HitReaction"
	r._pawn = pawn
	pawn.body.add_child(r)
	return r


## Tip away along `dir` (flat), by `amount` radians' worth of shove.
func lean(dir: Vector3, amount: float, stumble: bool) -> void:
	if dir == Vector3.ZERO:
		return
	if stumble:
		stumbles += 1
	if _parts.is_empty():
		_take_parts()
	# The top goes along the shot: about the axis square to it on the ground.
	_axis = Vector3.UP.cross(dir).normalized()
	_speed += amount * sqrt(LEAN_STIFF) * 1.4
	set_process(true)


func lean_angle() -> float:
	return _angle


## The body's look: what it shows, not what it collides with or aims from.
func _take_parts() -> void:
	for c in _pawn.body.get_children():
		if c == self or c is CollisionShape3D or c is Pawn or c == _pawn.eye:
			continue
		if c is VisualInstance3D or c is DefenceLook:
			_parts.append(c)
			_rest.append((c as Node3D).transform)


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if _pawn == null or not is_instance_valid(_pawn) or _pawn.body == null:
		return
	_speed += (-LEAN_STIFF * _angle - LEAN_DAMP * _speed) * delta
	_angle = clampf(_angle + _speed * delta, -0.2, 0.8)
	var spent := absf(_angle) < 0.002 and absf(_speed) < 0.01
	if spent:
		_angle = 0.0
		_speed = 0.0
	# About the feet, in the body's frame.
	var bxf := _pawn.body.global_transform
	var feet := bxf.affine_inverse() * _pawn.feet()
	var axis := (bxf.basis.inverse() * _axis).normalized()
	var tip := Transform3D(Basis(axis, _angle), Vector3.ZERO)
	var about := Transform3D(Basis.IDENTITY, feet) * tip * Transform3D(Basis.IDENTITY, -feet)
	for i in _parts.size():
		if is_instance_valid(_parts[i]):
			_parts[i].transform = about * _rest[i]
	if spent:
		set_process(false)
