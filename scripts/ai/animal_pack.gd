class_name AnimalPack
extends RefCounted
## A pack, a herd (Docs/AI.md 5.2; AIPlan P8): what its animals do together.
##
##   GRAZE   round an anchor that wanders a few metres every so often; each animal
##           keeps its own place in a loose ring round it
##   FLEE    a gunshot, a blast, a collapse heard within FLEE_RANGE: all run away
##           from it, together, for FLEE_SECONDS
##   HUNT    a prey: they spread round it at ENCIRCLE radius, each to its own
##           angle, and when the ring is closed -- or has had ENCIRCLE_SECONDS --
##           they go in and bite
##
## Decided once, at the pack's own rate, for all of them: the pack is the
## behaviour, as the swarm is (AI.md 5.2).

enum Mode { GRAZE, FLEE, HUNT }

const HZ := 2.0
## A noise heard at all (AIServices.noise carries 40 m) and this near: run.
const FLEE_RANGE := 60.0
const FLEE_SECONDS := 6.0
const GRAZE_WANDER := 6.0
const GRAZE_EVERY := 8.0
const RING := 3.5
const ENCIRCLE := 7.0
const ENCIRCLE_SECONDS := 5.0

var services: AIServices
var team := 2
var members: Array = []   # Animal
var mode := Mode.GRAZE
var home := Vector3.ZERO
var anchor := Vector3.ZERO
var prey: Pawn
var threat := Vector3.ZERO
var flee_until := -INF
var hunt_since := -INF
var closing := false
## For gates.
var fled := 0
var _next := -INF
var _next_graze := -INF
var _rng := RandomNumberGenerator.new()


func _init(s: AIServices, p_team: int, p_home: Vector3, seed := 1) -> void:
	services = s
	team = p_team
	home = p_home
	anchor = p_home
	_rng.seed = seed


func hunt(p: Pawn) -> void:
	prey = p
	mode = Mode.HUNT
	hunt_since = services.now()
	closing = false


func alive() -> Array:
	var out := []
	for m in members:
		if is_instance_valid(m) and not m.is_dead():
			out.append(m)
	return out


func think() -> void:
	var now := services.now()
	if now < _next:
		return
	_next = now + 1.0 / HZ
	# A noise near the pack: a shot, a blast, a collapse.
	if mode != Mode.HUNT:
		var k := services.knowledge_of(team)
		for key in k.contacts:
			var c: FactionKnowledge.Contact = k.contacts[key]
			if now - c.heard_at < 1.0 and c.pos.distance_to(anchor) < FLEE_RANGE:
				if mode != Mode.FLEE:
					fled += 1
				mode = Mode.FLEE
				threat = c.pos
				flee_until = now + FLEE_SECONDS
	match mode:
		Mode.FLEE:
			if now > flee_until:
				mode = Mode.GRAZE
				anchor = centre()
		Mode.GRAZE:
			if now >= _next_graze:
				_next_graze = now + GRAZE_EVERY
				var a := _rng.randf() * TAU
				anchor = home + Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(0.0, GRAZE_WANDER)
		Mode.HUNT:
			if prey == null or not is_instance_valid(prey) or prey.health.is_dead():
				mode = Mode.GRAZE
				prey = null
			elif not closing:
				var ringed := 0
				var a := alive()
				for i in a.size():
					if (a[i].budget_pos() as Vector3).distance_to(slot(i, a.size())) < 2.5:
						ringed += 1
				if ringed >= a.size() or now - hunt_since > ENCIRCLE_SECONDS:
					closing = true


## Where the pack is.
func centre() -> Vector3:
	var a := alive()
	var c := Vector3.ZERO
	for m in a:
		c += m.budget_pos()
	return c / maxf(a.size(), 1)


## Member i's place: round the anchor grazing, round the prey hunting.
func slot(i: int, n: int) -> Vector3:
	var ang := TAU * float(i) / float(maxi(n, 1))
	if mode == Mode.HUNT and prey != null and is_instance_valid(prey):
		return prey.feet() + Vector3(cos(ang), 0.0, sin(ang)) * ENCIRCLE
	return anchor + Vector3(cos(ang), 0.0, sin(ang)) * RING * (0.5 + 0.5 * float(i % 2))
