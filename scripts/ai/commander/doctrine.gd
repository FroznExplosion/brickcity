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
##
## It BUYS RECIPES (Docs/AIRoster.md 8, RO11): the answers above are made along a
## recipe's PARTS -- its attack, role, mods and class (PART_MULS) -- not its
## name, so every fieldable recipe on foot is in the roster, a new one authored
## on the casebook page included (at NEW_RECIPE weight before the answers). A
## recipe's weight is its base times the product of its parts' nudges, clamped.
##
## And SUPPORT (`support`): what it buys besides squads -- AIR (the roster's
## flyers and hover craft) and a TANK -- weighted the same way: against a
## demolisher, what destruction does not stop (flyers); against a player on
## roofs at range, air; against a mech, a tank; against a rusher, armour.

## Base roster weights, before the counters.
const BASE := {&"rifleman": 4.0, &"assault": 2.0, &"breacher": 1.0, &"marksman": 0.6,
		&"veteran": 0.8, &"rocketeer": 0.5,
		# The roster's own types (Docs/AIRoster.md RO3).
		&"brawler": 0.7, &"bomber": 0.7, &"grenadier": 0.6, &"sergeant": 0.4, &"brute": 0.3,
		&"hound": 0.6,
		# Climbs a player's mech and blows its hatch (RO8).
		&"boarder": 0.4}
## Below this many bricks a minute, with enough seen, the player is careful.
const CAREFUL_BRICKS := 10.0
## Base weight of a fieldable recipe BASE does not name.
const NEW_RECIPE := 0.5
## The answers, along the parts: style -> {"part:value": multiplier}. Parts are
## "attack:", "role:", "mod:", "class:". A recipe takes the product of every
## line it matches, clamped to x0.5..x2.
const PART_MULS := {
	# Close the distance: attackers and flankers, not marksmen of its own.
	"sniper": {"role:attacker": 1.8, "role:flanker": 1.4, "mod:armoured": 0.9, "attack:marksman": 0.5},
	# Let them come: armour that takes the hits, grenades, bodies to throw.
	"rusher": {"mod:armoured": 1.75, "role:attacker": 0.7, "attack:grenadier": 1.4, "role:fodder": 1.3},
	# Out of the blast: marksmen from outside it, the bigger classes.
	"demolisher": {"attack:marksman": 1.8, "class:medium": 1.3, "class:heavy": 1.3},
	# Its mech does the killing: anti-armour and rodeo, attackers and marksmen
	# for the pilot; fists are wasted on a hull.
	"mech": {"attack:anti_armour": 2.0, "mod:rodeo": 2.0, "role:attacker": 1.4,
			"attack:marksman": 1.4, "attack:melee": 0.5, "class:heavy": 0.7, "mod:armoured": 0.8},
	"pilot": {"attack:anti_armour": 0.5},
	# A careful pilot on foot: hunters -- flankers and scouts that go and find
	# them. Not marksmen: those are the demolisher's answer, and a careful
	# player meets far fewer of them (threat_style_probe, AIPlan P9).
	"careful": {"role:flanker": 1.5, "role:scout": 1.5},
}
## Support's base weights, before the answers: how readily, given the points,
## it buys air or a tank with a reinforcement.
const SUPPORT_BASE := {&"air": 0.25, &"tank": 0.15}
const SUPPORT_MULS := {
	"sniper": {&"air": 1.6},
	"rusher": {&"tank": 1.5},
	"demolisher": {&"air": 2.0, &"tank": 1.3},
	"mech": {&"tank": 2.0, &"air": 0.7},
	"pilot": {&"air": 1.2},
}

## 0 cautious .. 1 reckless: how readily squads are sent ADVANCE.
var aggression := 0.6
## Share of a reinforcement put inside the focus building.
var inside_share := 0.6
## Metres between members in a file (BTPlayTravel reads its own; for HUDs now).
var spacing := 2.2
var roster := BASE.duplicate()
## How often a reinforcement comes by truck, when the side can pay for one.
var truck_share := 0.4
## Support kind (&"air", &"tank") -> its weight now (SUPPORT_BASE, answered).
var support := SUPPORT_BASE.duplicate()
## What it is answering, for the HUD and the log.
var answering := "unknown"
var answering_armor := "unknown"
## 0..1: how much its fire prefers the player's pilot to the player's mech.
var pilot_focus := 0.0


## Recompute from the profile, the commander's desperation and its difficulty.
func update(profile: ThreatProfile, desperation: float, difficulty: float) -> void:
	var style := profile.style()
	answering = style
	aggression = difficulty
	inside_share = 0.6
	spacing = 2.2
	match style:
		"sniper":
			aggression += 0.2
		"rusher":
			aggression -= 0.2
		"demolisher":
			inside_share = 0.25
			spacing = 3.5
	var armor := profile.armor_style()
	answering_armor = armor
	pilot_focus = 0.7 if armor == "mech" else 0.0
	var careful := style != "demolisher" and profile.evidence >= 2.0 \
			and profile.destructiveness * (1.0 / (ThreatProfile.HALF_LIFE / 60.0 / log(2.0))) < CAREFUL_BRICKS
	if careful:
		inside_share = 0.8
	# Desperation: a little bolder at first, then careful as it bleeds.
	aggression += 0.15 * (1.0 - desperation) - 0.35 * maxf(desperation - 0.5, 0.0)
	aggression = clampf(aggression, 0.1, 0.95)
	# The answers in force, along the parts.
	var answers: Array[String] = [style, armor]
	# Careful and on foot: hunt them -- but not with marksmen against a sniper.
	if careful and armor != "mech" and style != "sniper":
		answers.append("careful")
	roster.clear()
	for id in recipe_ids():
		var k := 1.0
		for a in answers:
			k *= part_mul(id, PART_MULS.get(a, {}))
		roster[id] = base_of(id) * clampf(k, 0.5, 2.0)
	for kind in SUPPORT_BASE:
		var k := 1.0
		for a in answers:
			k *= float((SUPPORT_MULS.get(a, {}) as Dictionary).get(kind, 1.0))
		support[kind] = float(SUPPORT_BASE[kind]) * clampf(k, 0.5, 2.0)
	# A squad by truck: sooner against a sniper (get across the open fast),
	# later against a demolisher (a truck is a target it will not miss).
	truck_share = clampf(0.4 + (0.2 if style == "sniper" else 0.0)
			- (0.25 if style == "demolisher" else 0.0), 0.0, 0.8)


## Every id the roster weighs: BASE's, and every recipe on foot that can be
## fielded (built, no errors, a walker that is not a mech's).
static func recipe_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in BASE:
		out.append(id)
	var r := Roster.shared()
	if r == null:
		return out
	for rid in r.ids():
		var rc := r.recipe(rid)
		if str(rc.get("body", "")) == "walker" and bool(rc.get("built", false)) and r.fit(rid) \
				and not out.has(StringName(rid)):
			out.append(StringName(rid))
	return out


static func base_of(id: StringName) -> float:
	return float(BASE.get(id, NEW_RECIPE))


## The product of `muls`' lines that recipe `id` matches (1 for no recipe).
static func part_mul(id: StringName, muls: Dictionary) -> float:
	var r := Roster.shared()
	var rid := r.for_unit(id) if r != null else ""
	if r != null and rid == "" and r.has(String(id)):
		rid = String(id)
	if rid == "":
		return 1.0
	var rc := r.recipe(rid)
	var keys: Array[String] = ["attack:" + str(rc.get("attack", "")), "role:" + str(rc.get("role", "")),
			"class:" + str(rc.get("class", ""))]
	for m in rc.get("mods", []):
		keys.append("mod:" + str(m))
	var k := 1.0
	for key in keys:
		k *= float(muls.get(key, 1.0))
	return k


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
