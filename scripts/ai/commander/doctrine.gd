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
## And whose kills they are (ThreatProfile.armor_style, A8):
##
##   mech        its mech does the killing: go for the PILOT, the one who can be
##               killed -- assault to reach them, marksmen to pick them off, and
##               the side's aggro biased toward pilot rows (pilot_focus); anti-
##               armor (rocketeers) weighted up for when they can be fielded
##   pilot       the pilot does: no rocketeers wasted on a mech that is not the
##               threat
##
## A careful player -- one who hardly breaks a brick -- is the opposite of the
## demolisher: the buildings are safe to put troops in, and it does.
##
## Desperation (losses against what was fielded) pushes both ways, as Red Dawn's
## did: early, more aggressive; late and losing badly, it holds and husbands.

## Base roster weights, before the counters.
const BASE := {&"rifleman": 4.0, &"assault": 2.0, &"breacher": 1.0, &"marksman": 0.6,
		&"veteran": 0.8, &"rocketeer": 0.5,
		# The roster's own types (Docs/AIRoster.md RO3).
		&"brawler": 0.7, &"bomber": 0.7, &"grenadier": 0.6, &"sergeant": 0.4, &"brute": 0.3,
		&"hound": 0.6}
## Below this many bricks a minute, with enough seen, the player is careful.
const CAREFUL_BRICKS := 10.0

## 0 cautious .. 1 reckless: how readily squads are sent ADVANCE.
var aggression := 0.6
## Share of a reinforcement put inside the focus building.
var inside_share := 0.6
## Metres between members in a file (BTPlayTravel reads its own; for HUDs now).
var spacing := 2.2
var roster := BASE.duplicate()
## How often a reinforcement comes by truck, when the side can pay for one.
var truck_share := 0.4
## What it is answering, for the HUD and the log.
var answering := "unknown"
var answering_armor := "unknown"
## 0..1: how much its fire prefers the player's pilot to the player's mech.
var pilot_focus := 0.0


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
	var armor := profile.armor_style()
	answering_armor = armor
	pilot_focus = 0.0
	match armor:
		"mech":
			mul[&"rocketeer"] = 2.0
			mul[&"assault"] = float(mul[&"assault"]) * 1.4
			mul[&"marksman"] = float(mul[&"marksman"]) * 1.4
			pilot_focus = 0.7
		"pilot":
			mul[&"rocketeer"] = 0.5
	if style != "demolisher" and profile.evidence >= 2.0 \
			and profile.destructiveness * (1.0 / (ThreatProfile.HALF_LIFE / 60.0 / log(2.0))) < CAREFUL_BRICKS:
		inside_share = 0.8
	aggression += 0.15 * (1.0 - desperation) - 0.35 * maxf(desperation - 0.5, 0.0)
	aggression = clampf(aggression, 0.1, 0.95)
	for id in BASE:
		roster[id] = float(BASE[id]) * clampf(float(mul[id]), 0.5, 2.0)
	# A squad by truck: sooner against a sniper (get across the open fast),
	# later against a demolisher (a truck is a target it will not miss).
	truck_share = clampf(0.4 + (0.2 if style == "sniper" else 0.0)
			- (0.25 if style == "demolisher" else 0.0), 0.0, 0.8)


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
