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
## Three limbs: the Gunner (reload, magazines, alt-fire), the Survivor (health, the
## shield, grenades, and the Overshield ability), the Brawler (the Vanguard Brawler's
## melee nodes, COMBAT_DESIGN 4.2, mobility, ability cooldowns). A node gives a stat
## (`total`) or, at one rank, a flag (`has`): a melee augment or an ability. What either
## does to the player is PlayerArsenal.apply_skills's. Never a damage number from the
## level (PROGRESSION_SPEC 1) -- Backstab multiplies a blow by where it lands, which is
## the player's doing, not their level's.
##
## An ability node (`ability`) adds an ability the player can put in the ability slot
## (Q; PlayerLevel.tactical). The grapple is there from the start.

const TIER_STEP := 5
const TIERS := 8
## Columns of the tree's grid, left to right: the Gunner limb 0-2, the trunk and the
## Survivor limb 3-5, the Brawler limb 6-8.
const COLS := 9
## Health from the tree, all of it bought: the cap of 1.3 (+30% over base).
const HEALTH_CAP := 0.30
## The shield's, the same way: the tree's Survivor cells, all bought.
const SHIELD_CAP := 0.30

## Limb -> [name, colour].
const LIMBS := {
	&"trunk": ["Core", Color(0.92, 0.85, 0.62)],
	&"gunner": ["Gunner", Color(1.0, 0.5, 0.35)],
	&"survivor": ["Survivor", Color(0.45, 0.95, 0.55)],
	&"brawler": ["Brawler", Color(0.45, 0.72, 1.0)],
}

## Stat -> how one rank reads, with %s for its size (`describe`), and whether it is a
## share (shown as a percent). A flag's text has no size: it is what the node does.
const STATS := {
	&"max_shield": ["+%s max shield", true],
	&"shield_delay": ["-%s wait before the shield recharges", true],
	&"shield_rate": ["+%s shield recharge speed", true],
	&"melee_speed": ["+%s melee speed", true],
	&"ability_cooldown": ["+%s ability and grapple recharge speed", true],
	&"overshield": ["Ability (Q): your shield doubled and filled for 8 s, 30 s recharge", false, true],
	&"lunge": ["+50% melee reach; a blow past the old reach carries you in", false, true],
	&"shockwave": ["A melee that breaks a shield strips 25% off nearby enemies' shields (4 m)", false, true],
	&"backstab": ["A melee from behind does 2.5x", false, true],
	&"vampiric": ["A melee kill: +50% shield back, the gun in hand refilled", false, true],
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

	# Survivor: up the middle from Deep Pockets -- health on the right, the shield on the
	# left, grenades and the Overshield between. Its health nodes and Vitality's are the
	# whole of HEALTH_CAP; its shield cells, SHIELD_CAP.
	{"id": &"thick_skin", "name": "Thick Skin", "limb": &"survivor", "tier": 2, "col": 4, "ranks": 5,
		"stat": &"max_health", "per": 0.02, "parents": [&"deep_pockets"]},
	{"id": &"shield_cells", "name": "Shield Cells", "limb": &"survivor", "tier": 3, "col": 3, "ranks": 5,
		"stat": &"max_shield", "per": 0.03, "parents": [&"thick_skin"]},
	{"id": &"overshield", "name": "Overshield", "limb": &"survivor", "tier": 3, "col": 4, "ranks": 1,
		"stat": &"overshield", "per": 1.0, "ability": &"overshield", "parents": [&"thick_skin"]},
	{"id": &"second_wind", "name": "Second Wind", "limb": &"survivor", "tier": 3, "col": 5, "ranks": 5,
		"stat": &"health_regen", "per": 0.5, "parents": [&"thick_skin"]},
	{"id": &"fast_charge", "name": "Fast Charge", "limb": &"survivor", "tier": 4, "col": 3, "ranks": 5,
		"stat": &"shield_delay", "per": 0.08, "parents": [&"shield_cells"]},
	{"id": &"grenadier", "name": "Grenadier", "limb": &"survivor", "tier": 4, "col": 4, "ranks": 5,
		"stat": &"grenade_recharge", "per": 0.1, "parents": [&"overshield"]},
	{"id": &"hard_to_kill", "name": "Hard to Kill", "limb": &"survivor", "tier": 4, "col": 5, "ranks": 5,
		"stat": &"max_health", "per": 0.02, "parents": [&"second_wind"]},
	{"id": &"layered_cells", "name": "Layered Cells", "limb": &"survivor", "tier": 5, "col": 3, "ranks": 5,
		"stat": &"max_shield", "per": 0.03, "parents": [&"fast_charge"]},
	{"id": &"bandolier", "name": "Bandolier", "limb": &"survivor", "tier": 5, "col": 4, "ranks": 1,
		"stat": &"grenade_max", "per": 1.0, "parents": [&"grenadier"]},
	{"id": &"rally", "name": "Rally", "limb": &"survivor", "tier": 5, "col": 5, "ranks": 5,
		"stat": &"health_regen", "per": 0.5, "parents": [&"hard_to_kill"]},
	{"id": &"flash_charge", "name": "Flash Charge", "limb": &"survivor", "tier": 6, "col": 3, "ranks": 3,
		"stat": &"shield_rate", "per": 0.1, "parents": [&"layered_cells"]},
	{"id": &"demolitions", "name": "Demolitions", "limb": &"survivor", "tier": 6, "col": 4, "ranks": 3,
		"stat": &"grenade_recharge", "per": 0.1, "parents": [&"bandolier"]},
	{"id": &"medic", "name": "Medic", "limb": &"survivor", "tier": 6, "col": 5, "ranks": 3,
		"stat": &"health_regen", "per": 0.5, "parents": [&"rally"]},
	{"id": &"last_stand", "name": "Last Stand", "limb": &"survivor", "tier": 7, "col": 4, "ranks": 1,
		"stat": &"health_regen", "per": 4.0, "parents": [&"flash_charge", &"demolitions", &"medic"]},

	# Brawler (the Vanguard Brawler, COMBAT_DESIGN 4.2): up the right from Fleet Foot. The
	# melee augments down the left of it, mobility and the ability recharge down the right,
	# Vampiric Impact at the top: punch to break a defence, shoot to finish, refill the
	# shield, push the next one.
	{"id": &"heavy_hands", "name": "Heavy Hands", "limb": &"brawler", "tier": 1, "col": 7, "ranks": 5,
		"stat": &"melee_speed", "per": 0.05, "parents": [&"fleet_foot"]},
	{"id": &"light_step", "name": "Light Step", "limb": &"brawler", "tier": 2, "col": 7, "ranks": 5,
		"stat": &"move_speed", "per": 0.01, "parents": [&"heavy_hands"]},
	{"id": &"kinetic_lunge", "name": "Kinetic Lunge", "limb": &"brawler", "tier": 3, "col": 6, "ranks": 1,
		"stat": &"lunge", "per": 1.0, "parents": [&"light_step"]},
	{"id": &"sprinter", "name": "Sprinter", "limb": &"brawler", "tier": 3, "col": 8, "ranks": 5,
		"stat": &"move_speed", "per": 0.01, "parents": [&"light_step"]},
	{"id": &"brutal_rhythm", "name": "Brutal Rhythm", "limb": &"brawler", "tier": 4, "col": 6, "ranks": 5,
		"stat": &"melee_speed", "per": 0.05, "parents": [&"kinetic_lunge"]},
	{"id": &"hook_shot", "name": "Hook Shot", "limb": &"brawler", "tier": 4, "col": 8, "ranks": 5,
		"stat": &"ability_cooldown", "per": 0.06, "parents": [&"sprinter"]},
	{"id": &"shockwave", "name": "Shield-Shatter Shockwave", "limb": &"brawler", "tier": 5, "col": 6,
		"ranks": 1, "stat": &"shockwave", "per": 1.0, "parents": [&"brutal_rhythm"]},
	{"id": &"backstab", "name": "Backstab", "limb": &"brawler", "tier": 5, "col": 8, "ranks": 1,
		"stat": &"backstab", "per": 1.0, "parents": [&"hook_shot"]},
	{"id": &"iron_knuckles", "name": "Iron Knuckles", "limb": &"brawler", "tier": 6, "col": 6, "ranks": 3,
		"stat": &"melee_speed", "per": 0.05, "parents": [&"shockwave"]},
	{"id": &"quick_recovery", "name": "Quick Recovery", "limb": &"brawler", "tier": 6, "col": 8, "ranks": 3,
		"stat": &"ability_cooldown", "per": 0.06, "parents": [&"backstab"]},
	{"id": &"vampiric_impact", "name": "Vampiric Impact", "limb": &"brawler", "tier": 7, "col": 7,
		"ranks": 1, "stat": &"vampiric", "per": 1.0, "parents": [&"iron_knuckles", &"quick_recovery"]},
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
	elif stat == &"max_shield":
		t = minf(t, SHIELD_CAP)
	return t


## A flag node bought: a melee augment, an ability.
func has(stat: StringName) -> bool:
	return total(stat) > 0.0


## The abilities the player can put in the ability slot: the grapple, and every ability
## node bought.
func abilities() -> Array[StringName]:
	var out: Array[StringName] = [&"grapple"]
	for n in NODES:
		if n.has("ability") and rank(n.id) > 0:
			out.append(n.ability)
	return out


## How one rank of `stat` of size `per` reads ("+2% reload speed").
static func describe_stat(stat: StringName, per: float) -> String:
	var s: Array = STATS.get(stat, ["+%s " + String(stat), false])
	if s.size() > 2 and s[2]:
		return String(s[0])
	var size := ("%d%%" % roundi(per * 100.0)) if s[1] else (("%d" % int(per)) if per == floorf(per) else ("%.1f" % per))
	return String(s[0]) % size


## The node bought or not, a rank's worth and what it gives now.
func describe(id: StringName) -> String:
	var n := node(id)
	if n.is_empty():
		return ""
	if int(n.ranks) == 1:
		return describe_stat(n.stat, float(n.per))
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
