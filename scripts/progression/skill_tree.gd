class_name SkillTree
extends RefCounted
## The player's skill tree (Docs/Weapons/COMBAT_DESIGN.md 1.3, PROGRESSION_SPEC 2): one
## tree, Borderlands-style, a trunk that forks into limbs and the limbs into twigs.
##
##   * A skill point a level (PlayerLevel). A node takes points up to its `ranks`.
##   * The tree opens by TIERS, from the bottom: tier t opens once TIER_STEP * t points
##     are spent ANYWHERE in the tree. Every point counts toward every limb: a player who
##     spent all of theirs on the left limb can still buy a top-tier node on the right.
##     No node needs its parent bought -- the limbs are how the tree reads, not locks.
##   * The top tier opens at TIER_STEP * (TIERS - 1) = 35 points spent: level 36, so by
##     level 40 the whole tree is open. The tree holds far more ranks than a player ever
##     has points (CAPACITY > PlayerLevel.LEVEL_MAX - 1), so no one fills it: a build is
##     what the player chose to leave out.
##   * Points come back only all at once (`reset`), so the tiers a node was bought under
##     never close behind it.
##
## The skills are placeholders -- plain stats (more health, faster reload, ...) to be
## replaced by the real kit (abilities, the Vanguard Brawler's melee nodes, 4.2). What a
## stat does to the player is PlayerArsenal.apply_skills's. Never a damage number: the
## player level is never part of one (PROGRESSION_SPEC 1).

const TIER_STEP := 5
const TIERS := 8
## Columns of the tree's grid, left to right: the Gunner limb 0-2, the trunk and the
## Survivor limb 3-5, the Tactician limb 6-8.
const COLS := 9
## Health from the tree, all of it bought: the cap of 1.3 (+30% over base).
const HEALTH_CAP := 0.30

## Limb -> [name, colour].
const LIMBS := {
	&"trunk": ["Core", Color(0.92, 0.85, 0.62)],
	&"gunner": ["Gunner", Color(1.0, 0.5, 0.35)],
	&"survivor": ["Survivor", Color(0.45, 0.95, 0.55)],
	&"tactician": ["Tactician", Color(0.45, 0.72, 1.0)],
}

## Stat -> how one rank reads, with %s for its size (`describe`), and whether it is a
## share (shown as a percent).
const STATS := {
	&"max_health": ["+%s max health", true],
	&"health_regen": ["+%s health a second, after 5 s unhurt", false],
	&"reload_speed": ["+%s reload speed", true],
	&"mag_size": ["+%s magazine size", true],
	&"move_speed": ["+%s move speed", true],
	&"grenade_max": ["+%s grenade carried", false],
	&"grenade_recharge": ["+%s grenade recharge speed", true],
	&"alt_speed": ["+%s alt-fire charge and recharge speed", true],
}

## The nodes: id, name, limb, tier, col, ranks, stat, per rank, parents (for the
## limbs' lines only).
const NODES: Array[Dictionary] = [
	# The trunk: the first tier, and the fork.
	{"id": &"vitality", "name": "Vitality", "limb": &"trunk", "tier": 0, "col": 4, "ranks": 5,
		"stat": &"max_health", "per": 0.02, "parents": []},
	{"id": &"quick_hands", "name": "Quick Hands", "limb": &"trunk", "tier": 0, "col": 3, "ranks": 5,
		"stat": &"reload_speed", "per": 0.02, "parents": [&"vitality"]},
	{"id": &"fleet_foot", "name": "Fleet Foot", "limb": &"trunk", "tier": 0, "col": 5, "ranks": 5,
		"stat": &"move_speed", "per": 0.02, "parents": [&"vitality"]},
	{"id": &"deep_pockets", "name": "Deep Pockets", "limb": &"trunk", "tier": 1, "col": 4, "ranks": 2,
		"stat": &"grenade_max", "per": 1.0, "parents": [&"vitality"]},

	# Gunner: up the left from Quick Hands, forking at tier 3.
	{"id": &"steady_hands", "name": "Steady Hands", "limb": &"gunner", "tier": 1, "col": 1, "ranks": 5,
		"stat": &"reload_speed", "per": 0.02, "parents": [&"quick_hands"]},
	{"id": &"big_mags", "name": "Big Mags", "limb": &"gunner", "tier": 2, "col": 1, "ranks": 5,
		"stat": &"mag_size", "per": 0.03, "parents": [&"steady_hands"]},
	{"id": &"fast_hands", "name": "Fast Hands", "limb": &"gunner", "tier": 3, "col": 0, "ranks": 5,
		"stat": &"reload_speed", "per": 0.02, "parents": [&"big_mags"]},
	{"id": &"drum_feed", "name": "Drum Feed", "limb": &"gunner", "tier": 3, "col": 2, "ranks": 5,
		"stat": &"mag_size", "per": 0.03, "parents": [&"big_mags"]},
	{"id": &"speed_loader", "name": "Speed Loader", "limb": &"gunner", "tier": 4, "col": 0, "ranks": 5,
		"stat": &"reload_speed", "per": 0.02, "parents": [&"fast_hands"]},
	{"id": &"quick_charge", "name": "Quick Charge", "limb": &"gunner", "tier": 4, "col": 2, "ranks": 5,
		"stat": &"alt_speed", "per": 0.05, "parents": [&"drum_feed"]},
	{"id": &"slick_hands", "name": "Slick Hands", "limb": &"gunner", "tier": 5, "col": 0, "ranks": 5,
		"stat": &"reload_speed", "per": 0.02, "parents": [&"speed_loader"]},
	{"id": &"capacitor", "name": "Capacitor", "limb": &"gunner", "tier": 5, "col": 2, "ranks": 5,
		"stat": &"alt_speed", "per": 0.05, "parents": [&"quick_charge"]},
	{"id": &"ammo_belt", "name": "Ammo Belt", "limb": &"gunner", "tier": 6, "col": 0, "ranks": 5,
		"stat": &"mag_size", "per": 0.03, "parents": [&"slick_hands"]},
	{"id": &"overclock", "name": "Overclock", "limb": &"gunner", "tier": 6, "col": 2, "ranks": 3,
		"stat": &"alt_speed", "per": 0.05, "parents": [&"capacitor"]},
	{"id": &"lock_and_load", "name": "Lock and Load", "limb": &"gunner", "tier": 7, "col": 1, "ranks": 1,
		"stat": &"reload_speed", "per": 0.15, "parents": [&"ammo_belt", &"overclock"]},

	# Survivor: up the middle from Deep Pockets, forking at tier 4. Its health nodes and
	# Vitality's are the whole of HEALTH_CAP.
	{"id": &"thick_skin", "name": "Thick Skin", "limb": &"survivor", "tier": 2, "col": 4, "ranks": 5,
		"stat": &"max_health", "per": 0.02, "parents": [&"deep_pockets"]},
	{"id": &"second_wind", "name": "Second Wind", "limb": &"survivor", "tier": 3, "col": 4, "ranks": 5,
		"stat": &"health_regen", "per": 0.5, "parents": [&"thick_skin"]},
	{"id": &"grenadier", "name": "Grenadier", "limb": &"survivor", "tier": 4, "col": 3, "ranks": 5,
		"stat": &"grenade_recharge", "per": 0.1, "parents": [&"second_wind"]},
	{"id": &"hard_to_kill", "name": "Hard to Kill", "limb": &"survivor", "tier": 4, "col": 5, "ranks": 5,
		"stat": &"max_health", "per": 0.02, "parents": [&"second_wind"]},
	{"id": &"bandolier", "name": "Bandolier", "limb": &"survivor", "tier": 5, "col": 3, "ranks": 1,
		"stat": &"grenade_max", "per": 1.0, "parents": [&"grenadier"]},
	{"id": &"rally", "name": "Rally", "limb": &"survivor", "tier": 5, "col": 5, "ranks": 5,
		"stat": &"health_regen", "per": 0.5, "parents": [&"hard_to_kill"]},
	{"id": &"demolitions", "name": "Demolitions", "limb": &"survivor", "tier": 6, "col": 3, "ranks": 3,
		"stat": &"grenade_recharge", "per": 0.1, "parents": [&"bandolier"]},
	{"id": &"medic", "name": "Medic", "limb": &"survivor", "tier": 6, "col": 5, "ranks": 3,
		"stat": &"health_regen", "per": 0.5, "parents": [&"rally"]},
	{"id": &"last_stand", "name": "Last Stand", "limb": &"survivor", "tier": 7, "col": 4, "ranks": 1,
		"stat": &"health_regen", "per": 4.0, "parents": [&"demolitions", &"medic"]},

	# Tactician: up the right from Fleet Foot, forking at tier 3.
	{"id": &"light_step", "name": "Light Step", "limb": &"tactician", "tier": 1, "col": 7, "ranks": 5,
		"stat": &"move_speed", "per": 0.01, "parents": [&"fleet_foot"]},
	{"id": &"sprinter", "name": "Sprinter", "limb": &"tactician", "tier": 2, "col": 7, "ranks": 5,
		"stat": &"move_speed", "per": 0.01, "parents": [&"light_step"]},
	{"id": &"sharp_mind", "name": "Sharp Mind", "limb": &"tactician", "tier": 3, "col": 6, "ranks": 5,
		"stat": &"alt_speed", "per": 0.05, "parents": [&"sprinter"]},
	{"id": &"runner", "name": "Runner", "limb": &"tactician", "tier": 3, "col": 8, "ranks": 5,
		"stat": &"move_speed", "per": 0.01, "parents": [&"sprinter"]},
	{"id": &"focus", "name": "Focus", "limb": &"tactician", "tier": 4, "col": 6, "ranks": 5,
		"stat": &"alt_speed", "per": 0.05, "parents": [&"sharp_mind"]},
	{"id": &"pack_mule", "name": "Pack Mule", "limb": &"tactician", "tier": 4, "col": 8, "ranks": 5,
		"stat": &"mag_size", "per": 0.03, "parents": [&"runner"]},
	{"id": &"refit", "name": "Refit", "limb": &"tactician", "tier": 5, "col": 6, "ranks": 3,
		"stat": &"grenade_recharge", "per": 0.1, "parents": [&"focus"]},
	{"id": &"stride", "name": "Stride", "limb": &"tactician", "tier": 5, "col": 8, "ranks": 3,
		"stat": &"move_speed", "per": 0.01, "parents": [&"pack_mule"]},
	{"id": &"tinker", "name": "Tinker", "limb": &"tactician", "tier": 6, "col": 6, "ranks": 3,
		"stat": &"alt_speed", "per": 0.05, "parents": [&"refit"]},
	{"id": &"spare_grenade", "name": "Spare Grenade", "limb": &"tactician", "tier": 6, "col": 8, "ranks": 1,
		"stat": &"grenade_max", "per": 1.0, "parents": [&"stride"]},
	{"id": &"afterburner", "name": "Afterburner", "limb": &"tactician", "tier": 7, "col": 7, "ranks": 1,
		"stat": &"move_speed", "per": 0.05, "parents": [&"tinker", &"spare_grenade"]},
]

## Node id -> ranks bought.
var ranks := {}

static var _by_id := {}


## The node `id`'s definition, or {}.
static func node(id: StringName) -> Dictionary:
	if _by_id.is_empty():
		for n in NODES:
			_by_id[n.id] = n
	return _by_id.get(id, {})


## Every rank in the tree.
static func capacity() -> int:
	var t := 0
	for n in NODES:
		t += int(n.ranks)
	return t


## Points that must be spent before tier `t` opens.
static func tier_gate(t: int) -> int:
	return TIER_STEP * t


func rank(id: StringName) -> int:
	return int(ranks.get(id, 0))


func spent() -> int:
	var t := 0
	for id in ranks:
		t += int(ranks[id])
	return t


func tier_open(t: int) -> bool:
	return spent() >= tier_gate(t)


## The highest tier open now.
func open_tier() -> int:
	return clampi(spent() / TIER_STEP, 0, TIERS - 1)


## Why `id` cannot take a point now ("" if it can), with `free` points to spend.
func why_not(id: StringName, free: int) -> String:
	var n := node(id)
	if n.is_empty():
		return "No such skill"
	if rank(id) >= int(n.ranks):
		return "Maxed"
	if not tier_open(int(n.tier)):
		return "Opens at %d points spent" % tier_gate(int(n.tier))
	if free <= 0:
		return "No skill points"
	return ""


## One point into `id`, if it can take one with `free` to spend.
func buy(id: StringName, free: int) -> bool:
	if why_not(id, free) != "":
		return false
	ranks[id] = rank(id) + 1
	return true


## Every point back.
func reset() -> void:
	ranks.clear()


## The sum of `stat` over every rank bought.
func total(stat: StringName) -> float:
	var t := 0.0
	for id in ranks:
		var n := node(id)
		if not n.is_empty() and n.stat == stat:
			t += float(n.per) * int(ranks[id])
	if stat == &"max_health":
		t = minf(t, HEALTH_CAP)
	return t


## How one rank of `stat` of size `per` reads ("+2% reload speed").
static func describe_stat(stat: StringName, per: float) -> String:
	var s: Array = STATS.get(stat, ["+%s " + String(stat), false])
	var size := ("%d%%" % roundi(per * 100.0)) if s[1] else (("%d" % int(per)) if per == floorf(per) else ("%.1f" % per))
	return String(s[0]) % size


## The node bought or not, a rank's worth and what it gives now.
func describe(id: StringName) -> String:
	var n := node(id)
	if n.is_empty():
		return ""
	var line := "%s each rank" % describe_stat(n.stat, float(n.per))
	if rank(id) > 0:
		line += "  (now %s)" % describe_stat(n.stat, float(n.per) * rank(id))
	return line


## The node nearest `id` in direction `dir` (screen: +y down, the tree grows up), or
## `id` if there is none that way.
static func neighbour(id: StringName, dir: Vector2i) -> StringName:
	var from := node(id)
	if from.is_empty():
		return NODES[0].id
	var at := Vector2(int(from.col), -int(from.tier))
	var best: StringName = id
	var best_d := INF
	for n in NODES:
		if n.id == id:
			continue
		var d := Vector2(int(n.col), -int(n.tier)) - at
		var along := d.x * dir.x + d.y * dir.y
		if along <= 0.0:
			continue
		var across := absf(d.x * dir.y - d.y * dir.x)
		var score := along + across * 2.5
		if score < best_d:
			best_d = score
			best = n.id
	return best


func to_dict() -> Dictionary:
	var d := {}
	for id in ranks:
		if int(ranks[id]) > 0:
			d[String(id)] = int(ranks[id])
	return d


## A saved tree, re-bought tier by tier with at most `points`: what an older or edited
## save holds that the tree no longer allows (a node gone, too many ranks, a tier not
## open) is left out, and those points are free again.
static func from_dict(d: Dictionary, points: int) -> SkillTree:
	var t := SkillTree.new()
	var want := []
	for k in d:
		var n := node(StringName(k))
		if not n.is_empty():
			want.append([int(n.tier), n.id, mini(int(d[k]), int(n.ranks))])
	want.sort()
	var progress := true
	# A node can only be re-bought once the tiers below it have their points again:
	# go round until nothing more goes in.
	while progress:
		progress = false
		for w in want:
			while t.rank(w[1]) < int(w[2]) and t.buy(w[1], points - t.spent()):
				progress = true
	return t
