class_name PointsBattle
extends RefCounted
## A fight nobody is watching, resolved in points (Docs/AI.md 9: "resolves
## fights no player is near by Red Dawn's points formula"; Red Dawn's
## docs/commander_and_points_system.md).
##
## The ratio of the attacker's points to the defender's -- the defender's
## counting x FORTIFIED when it holds a building -- picks one of five outcomes,
## each with the share of each side it costs; how long it takes is longer the
## more even the fight. A player who comes within REAL_TIME metres turns it into
## a real fight: the host spawns what is left, and the points stop.
##
##   ratio >= 2.0   decisive attacker win   attacker loses 10 %, defender 80 %
##   ratio >= 1.3   attacker win            25 %, 60 %
##   ratio >= 0.8   stalemate               35 %, 35 %
##   ratio >= 0.5   defender win            60 %, 25 %
##   ratio <  0.5   decisive defender win   80 %, 10 %

enum Outcome { DECISIVE_ATTACKER, ATTACKER, STALEMATE, DEFENDER, DECISIVE_DEFENDER }
const OUTCOME_NAMES := ["decisive attacker win", "attacker win", "stalemate", "defender win",
		"decisive defender win"]
const FORTIFIED := 1.3
const REAL_TIME := 100.0
## Seconds to resolve: an even fight takes the longest.
const QUICK := 30.0
const SLOW := 120.0
## The losses of each outcome: [attacker share, defender share].
const LOSSES := [[0.10, 0.80], [0.25, 0.60], [0.35, 0.35], [0.60, 0.25], [0.80, 0.10]]


## {outcome, name, ratio, attacker_left, defender_left, seconds}.
static func resolve(attacker: float, defender: float, fortified := false) -> Dictionary:
	var d := defender * (FORTIFIED if fortified else 1.0)
	var ratio := attacker / maxf(d, 0.1)
	var o := Outcome.DECISIVE_DEFENDER
	if ratio >= 2.0:
		o = Outcome.DECISIVE_ATTACKER
	elif ratio >= 1.3:
		o = Outcome.ATTACKER
	elif ratio >= 0.8:
		o = Outcome.STALEMATE
	elif ratio >= 0.5:
		o = Outcome.DEFENDER
	# 1 when even (ratio 1), 0 when one side is twice the other or more.
	var balance := clampf(1.0 - absf(log(maxf(ratio, 0.01)) / log(2.0)), 0.0, 1.0)
	return {"outcome": o, "name": OUTCOME_NAMES[o], "ratio": ratio,
			"attacker_left": attacker * (1.0 - float(LOSSES[o][0])),
			"defender_left": defender * (1.0 - float(LOSSES[o][1])),
			"seconds": lerpf(QUICK, SLOW, balance)}


## A front: two forces at a place, fighting on while nobody watches.
class Front:
	var where := Vector3.ZERO
	var attacker := 0.0
	var defender := 0.0
	var fortified := false
	## Which side is the commander's own that opened it.
	var ours_attacker := false
	var started := 0.0
	## Set when it is resolved.
	var result := {}

	## Resolve it if its time has come and no player is near (`players`: their
	## positions). True when it resolved this call.
	func step(now: float, players: Array) -> bool:
		if not result.is_empty():
			return false
		for p in players:
			if (p as Vector3).distance_to(where) < PointsBattle.REAL_TIME:
				return false   # real time: the host fights it
		var r := PointsBattle.resolve(attacker, defender, fortified)
		if now - started < float(r.seconds):
			return false
		result = r
		attacker = r.attacker_left
		defender = r.defender_left
		return true
