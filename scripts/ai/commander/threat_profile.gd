class_name ThreatProfile
extends RefCounted
## How the player fights, measured (Docs/AI.md 9): the commander's read on its
## enemy, and what its doctrine and roster answer. Saved with the character
## (A14) so the next encounter's commander starts from it; every number decays
## (HALF_LIFE) so a player who changes style is followed, not punished.
##
##   destructiveness  bricks the player's fire breaks, per minute
##   range            how far off the player's damaging hits land, metres
##   closeness        share of the time the player is within CLOSE of an enemy
##   lethality        kills per minute
##   accuracy         share of rounds that hit a body
##
## style() names the strongest habit, as Red Dawn's classifier did: "sniper",
## "rusher", "demolisher", or "balanced".

const HALF_LIFE := 90.0
const CLOSE := 12.0

var destructiveness := 0.0
var range_m := 20.0
var closeness := 0.0
var lethality := 0.0
var accuracy := 0.3
## Weight of what has been seen: a profile of one shot says little.
var evidence := 0.0

var _shots := 0.0
var _hits := 0.0


## Called once a second (or so) with how long it has been.
func decay(dt: float) -> void:
	var k := pow(0.5, dt / HALF_LIFE)
	destructiveness *= k
	lethality *= k
	_shots *= k
	_hits *= k
	evidence *= k


## A round the player fired: `hit` a body at `dist` metres; `bricks` it broke.
func note_shot(hit: bool, dist: float, killed: bool, bricks: int) -> void:
	_shots += 1.0
	evidence += 0.2
	if hit:
		_hits += 1.0
		range_m = lerpf(range_m, dist, 0.15)
	if killed:
		lethality += 1.0
	if bricks > 0:
		destructiveness += float(bricks)
	accuracy = _hits / maxf(_shots, 1.0)


## Something the player blew up: `bricks` of it.
func note_bricks(bricks: int) -> void:
	destructiveness += float(bricks)
	evidence += 0.5


## A sample of where the player is: `nearest` enemy distance, over `dt` seconds.
func sample(nearest: float, dt: float) -> void:
	var near := 1.0 if nearest < CLOSE else 0.0
	var k := clampf(dt / 20.0, 0.0, 1.0)
	closeness = lerpf(closeness, near, k)


func style() -> String:
	if evidence < 2.0:
		return "unknown"
	# Per-minute numbers: the sums above decay with a 90 s half-life, so the
	# sum is about 2.2 minutes' worth.
	var per_min := 1.0 / (HALF_LIFE / 60.0 / log(2.0))
	if destructiveness * per_min > 120.0:
		return "demolisher"
	if range_m > 30.0 and closeness < 0.2:
		return "sniper"
	if closeness > 0.5 or range_m < 9.0:
		return "rusher"
	return "balanced"


func to_dict() -> Dictionary:
	return {"destructiveness": destructiveness, "range": range_m, "closeness": closeness,
			"lethality": lethality, "accuracy": accuracy, "evidence": evidence}


static func from_dict(d: Dictionary) -> ThreatProfile:
	var p := ThreatProfile.new()
	p.destructiveness = float(d.get("destructiveness", 0.0))
	p.range_m = float(d.get("range", 20.0))
	p.closeness = float(d.get("closeness", 0.0))
	p.lethality = float(d.get("lethality", 0.0))
	p.accuracy = float(d.get("accuracy", 0.3))
	p.evidence = float(d.get("evidence", 0.0))
	return p
