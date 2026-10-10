class_name GunModifiers
extends RefCounted
## A gun's modifiers (Docs/Weapons/COMBAT_DESIGN.md section 6): where its power comes
## from. Rarity sets how many it carries (Rarity.SLOTS) and how high they roll
## (Rarity.QUALITY); each one rolls inside its own band.
##
## A modifier is {"id": StringName, "value": float}. Rolled from the gun's seed on a
## stream of its own, so adding modifiers moved no other roll, and a saved seed or a
## peer rebuilds the same list (GunGenerator.deserialize).
##
## They reach the game as numbers in the gun's stats (apply()): the stat ones change a
## stat; the behaviour ones leave a key the GunController reads when it fires:
##   power_shot_every     every Nth round does POWER_SHOT_MULT
##   double_fire_every    every Nth round fires a free extra round
##   double_fire_chance   any round may fire a free extra round (the rarer roll)
##   shield_buster        +X on damage landing on a shield
##   overkill_ricochet    a killing blow's excess, times X, jumps to the nearest enemy
##   explosive            every round bursts on impact for X of its damage (6.1)

const POWER_SHOT_MULT := 2.0

## id -> its band and rules.
##   lo, hi     the band: `lo` is the worst roll, `hi` the best (for a count, the best
##              is the SMALLER N, so lo > hi there)
##   count      the value is a whole number (a round count)
##   w          pick weight
##   min_rarity the lowest colour that can carry it
##   repeat     may appear more than once on one gun (their values add)
##   group      at most one modifier of a group on a gun
##   guns_only  never on ordnance (it fires once per cooldown: no rounds to count)
const DEFS := {
	&"damage": {"lo": 0.10, "hi": 0.20, "w": 3.0, "repeat": true},
	&"power_shot": {"lo": 6.0, "hi": 4.0, "count": true, "w": 1.5, "guns_only": true},
	&"double_fire": {"lo": 5.0, "hi": 3.0, "count": true, "w": 1.5, "group": &"double",
			"guns_only": true},
	&"double_fire_random": {"lo": 0.15, "hi": 0.25, "w": 0.6, "group": &"double",
			"min_rarity": 4, "guns_only": true},
	&"shield_buster": {"lo": 0.20, "hi": 0.40, "w": 1.5},
	&"overkill_ricochet": {"lo": 1.0, "hi": 1.5, "w": 1.0, "min_rarity": 2},
	&"magazine": {"lo": 0.20, "hi": 0.40, "w": 1.5, "guns_only": true},
	&"reload": {"lo": 0.10, "hi": 0.25, "w": 1.5},
	&"explosive": {"lo": 0.35, "hi": 0.60, "w": 0.8, "min_rarity": 3, "guns_only": true},
}


## The modifiers a gun of this seed, rarity and class carries. Always fills every slot.
static func roll(gun_seed: int, rarity: int, weapon_class: WeaponClass) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([gun_seed, "modifiers"])
	var ordnance := weapon_class != null and weapon_class.is_ordnance
	var out: Array[Dictionary] = []
	for _i in Rarity.modifier_slots(rarity):
		var id := _pick(rng, rarity, ordnance, out)
		if id == &"":
			break
		var d: Dictionary = DEFS[id]
		var q := Rarity.roll_quality(rarity, rng.randf())
		var v := lerpf(float(d.lo), float(d.hi), q)
		if d.get("count", false):
			v = float(roundi(v))
		out.append({"id": id, "value": v})
	return out


static func _pick(rng: RandomNumberGenerator, rarity: int, ordnance: bool,
		taken: Array[Dictionary]) -> StringName:
	var have := {}
	var groups := {}
	for m in taken:
		have[m.id] = true
		var g: StringName = DEFS[m.id].get("group", &"")
		if g != &"":
			groups[g] = true
	var ids: Array[StringName] = []
	var total := 0.0
	for id: StringName in DEFS:
		var d: Dictionary = DEFS[id]
		if rarity < int(d.get("min_rarity", 1)) or (ordnance and d.get("guns_only", false)):
			continue
		if have.has(id) and not d.get("repeat", false):
			continue
		if groups.has(d.get("group", &"")):
			continue
		ids.append(id)
		total += float(d.w)
	if ids.is_empty():
		return &""
	var r := rng.randf() * total
	for id in ids:
		r -= float(DEFS[id].w)
		if r <= 0.0:
			return id
	return ids[ids.size() - 1]


## Fold `mods` into `stats`. Damage modifiers add to each other (two +20% are +40%,
## section 3), then multiply the damage.
static func apply(stats: Dictionary[StringName, float], mods: Array[Dictionary]) -> void:
	var dmg := 0.0
	for m in mods:
		var v := float(m.value)
		match m.id:
			&"damage":
				dmg += v
			&"magazine":
				var mag: float = stats.get(&"mag_size", 1.0)
				stats[&"mag_size"] = maxf(mag + 1.0, floorf(mag * (1.0 + v)))
			&"reload":
				stats[&"reload_time"] = stats.get(&"reload_time", 1.0) * (1.0 - v)
				if stats.has(&"cooldown"):
					stats[&"cooldown"] *= 1.0 - v
			&"power_shot":
				stats[&"power_shot_every"] = v
			&"double_fire":
				stats[&"double_fire_every"] = v
			&"double_fire_random":
				stats[&"double_fire_chance"] = v
			_:
				stats[StringName(m.id)] = v
	stats[&"damage"] = stats.get(&"damage", 0.0) * (1.0 + dmg)


## The ids of modifiers that are also a gun EFFECT the rest of the game reads (the
## explosive attachment wears bricks harder: StructuralDamage.for_shot).
static func effects(mods: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	for m in mods:
		if m.id == &"explosive":
			out.append("explosive")
	return out


## One line for the card.
static func describe(m: Dictionary) -> String:
	var v := float(m.value)
	match m.id:
		&"damage":
			return "+%d%% damage" % roundi(v * 100.0)
		&"power_shot":
			return "Power shot: every %s round hits %d×" % [_nth(roundi(v)), roundi(POWER_SHOT_MULT)]
		&"double_fire":
			return "Double fire: every %s round fires twice" % _nth(roundi(v))
		&"double_fire_random":
			return "Double fire: %d%% of rounds fire twice" % roundi(v * 100.0)
		&"shield_buster":
			return "Shield Buster: +%d%% against shields" % roundi(v * 100.0)
		&"overkill_ricochet":
			return "Overkill Ricochet: a kill's excess ×%.1f jumps on" % v
		&"magazine":
			return "+%d%% magazine" % roundi(v * 100.0)
		&"reload":
			return "−%d%% reload time" % roundi(v * 100.0)
		&"explosive":
			return "Explosive rounds: %d%% splash" % roundi(v * 100.0)
	return String(m.id).capitalize()


static func _nth(n: int) -> String:
	match n:
		2: return "2nd"
		3: return "3rd"
	return "%dth" % n
