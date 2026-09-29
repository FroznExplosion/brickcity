class_name Doctrine
extends RefCounted
## How a commander's force fights, and what it fields (Docs/AI.md 9), from the
## player's ThreatProfile, its own desperation and the difficulty.
##
## Every answer is a NUDGE, clamped: no counter is a hard counter (a roster
## weight moves at most between x0.5 and x2 of its base), so a player is met,
## not hard-countered, and one who changes style is followed as the profile
## decays.
##
##   sniper      close the distance: more assault and breachers, advance more,
##               fewer marksmen of its own
##   rusher      hold and let them come: fewer advances, more breachers (close
##               in, shotguns win), veterans who take the hits
##   demolisher  do not stand in what it is shooting: fewer spawns inside
##               buildings, spread out, more marksmen (from outside the blast)
##
## Desperation (losses against what was fielded) pushes both ways, as Red Dawn's
## did: early, more aggressive; late and losing badly, it holds and husbands.

## Base roster weights, before the counters.
const BASE := {&"rifleman": 4.0, &"assault": 2.0, &"breacher": 1.0, &"marksman": 0.6,
		&"veteran": 0.8}

## 0 cautious .. 1 reckless: how readily squads are sent ADVANCE.
var aggression := 0.6
## Share of a reinforcement put inside the focus building.
var inside_share := 0.6
## Metres between members in a file (BTPlayTravel reads its own; for HUDs now).
var spacing := 2.2
var roster := BASE.duplicate()
## What it is answering, for the HUD and the log.
var answering := "unknown"


## Recompute from the profile, the commander's desperation and its difficulty.
func update(profile: ThreatProfile, desperation: float, difficulty: float) -> void:
	var style := profile.style()
	answering = style
	var mul := {}
	for id in BASE:
		mul[id] = 1.0
	aggression = difficulty
	inside_share = 0.6
	spacing = 2.2
	match style:
		"sniper":
			mul[&"assault"] = 1.8
			mul[&"breacher"] = 1.6
			mul[&"marksman"] = 0.5
			aggression += 0.2
		"rusher":
			mul[&"breacher"] = 1.8
			mul[&"veteran"] = 1.7
			mul[&"assault"] = 0.7
			aggression -= 0.2
		"demolisher":
			mul[&"marksman"] = 1.8
			mul[&"veteran"] = 1.3
			inside_share = 0.25
			spacing = 3.5
	# Desperation: a little bolder at first, then careful as it bleeds.
	aggression += 0.15 * (1.0 - desperation) - 0.35 * maxf(desperation - 0.5, 0.0)
	aggression = clampf(aggression, 0.1, 0.95)
	for id in BASE:
		roster[id] = float(BASE[id]) * clampf(float(mul[id]), 0.5, 2.0)


## Draw `n` units the budget can pay for, weighted by the roster. Only built
## units; the cheapest is always affordable last.
func draw(n: int, budget: float, rng: RandomNumberGenerator) -> Array[StringName]:
	var out: Array[StringName] = []
	var left := budget
	var built := UnitCatalog.built()
	for i in n:
		var total := 0.0
		for id in roster:
			if id in built and UnitCatalog.points(id) <= left:
				total += float(roster[id])
		if total <= 0.0:
			break
		var pick := rng.randf() * total
		for id in roster:
			if not (id in built) or UnitCatalog.points(id) > left:
				continue
			pick -= float(roster[id])
			if pick <= 0.0:
				out.append(id)
				left -= UnitCatalog.points(id)
				break
	return out
