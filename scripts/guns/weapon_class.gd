class_name WeaponClass
extends Resource
## Per-class base stats (GUN_SCALING_SPEC §1.5, WEAPONS_SPEC §2). The level curve and
## rarity multipliers are SHARED across classes — only these bases differ. Pistol
## (base_damage 100) is the reference class. Numbers are starting points tuned toward
## the 3s standard-enemy TTK; confirm in playtest.

@export var id: StringName
@export var display_name: String
@export var ammo: StringName                      ## light / rifle / sniper / shell
## ORDNANCE (BL4-style equip slot): thrown/launched, cooldown-gated instead of
## magazine-gated. Everything else about it is a normal weapon class, so it flows
## through GunGenerator / GunStats / score / grade words with no special case.
@export var is_ordnance: bool = false
## Seconds between uses. base_fire_rate is kept as 1.0/cooldown so DPS parity and the
## score formula work unchanged.
@export var cooldown: float = 0.0
@export var blast_radius: float = 0.0
## The kind of gun in this class (COMBAT_DESIGN 7.8): &"light" or &"heavy", a different
## gun to hold. Empty is a gun no one chose a kind for -- an enemy's, a vehicle's -- and
## it is the class as its preset stands, which is also what a light gun is (but for the
## light shotgun, which fires faster and lighter: KINDS). `with_kind` makes one.
@export var archetype: StringName = &""
## Rounds a shot spends: 2 on a heavy. The magazine stat is counted in ROUNDS; what the
## trigger and the HUD count is shots (GunController.mag_size).
@export var rounds_per_shot: int = 1
## A legendary that breaks its kind's trade (7.8): a heavy with a light's fire rate, or a
## light with a heavy's damage, without the other kind's penalty.
@export var crossed := false

@export var base_damage: float = 100.0            ## worst-common, level-1 per-hit
@export var base_fire_rate: float = 6.0           ## shots/sec at base
@export var mag_min: float = 10.0
@export var mag_max: float = 16.0
@export var crit_mult: float = 1.75
@export var base_reload: float = 1.6
@export var base_accuracy: float = 0.90           ## 0..1

## Shipping presets (WEAPONS §2). Keyed by class id. "crit" is the HEADSHOT multiplier
## (Docs/Weapons/COMBAT_DESIGN.md 4.3): 2x across the board, more on the precision guns.
## A gun's damage a round is stated in UNITS of a medium enemy's health at Unique, on
## level (the Armory Ledger's Time to kill tab, COMBAT_DESIGN 3). DMG_UNIT turns a unit
## into this table's base damage: a medium enemy's health at tier 1 (CombatScale.MELEE_BASE,
## 60) over what the rolls and a Unique's rarity make of a base on the median
## (GunStats; calibrated by tools/combat_numbers_probe.gd).
const MEDIAN_UNIQUE := 1.123
const DMG_UNIT := 60.0 / MEDIAN_UNIQUE
const _PRESETS := {
	&"pistol":   {"ammo": &"light",  "dmg": DMG_UNIT * 0.2, "fr": 8.0,  "mmin": 10, "mmax": 16,  "crit": 2.0, "rl": 1.6, "acc": 0.90},
	&"smg":      {"ammo": &"light",  "dmg": DMG_UNIT * 0.09, "fr": 14.0, "mmin": 25, "mmax": 40,  "crit": 2.0, "rl": 1.8, "acc": 0.75},
	&"rifle":    {"ammo": &"rifle",  "dmg": DMG_UNIT * 0.12, "fr": 12.0,  "mmin": 24, "mmax": 40,  "crit": 2.0, "rl": 2.4, "acc": 0.85},
	&"lmg":      {"ammo": &"rifle",  "dmg": DMG_UNIT * 0.126, "fr": 13.0, "mmin": 80, "mmax": 120, "crit": 2.0, "rl": 4.0, "acc": 0.70},
	&"dmr":      {"ammo": &"sniper", "dmg": DMG_UNIT * 0.4, "fr": 3.5,  "mmin": 12, "mmax": 18,  "crit": 2.0, "rl": 2.6, "acc": 0.95},
	&"sniper":   {"ammo": &"sniper", "dmg": DMG_UNIT * 1.0, "fr": 1.4, "mmin": 4,  "mmax": 6,   "crit": 3.0, "rl": 3.2, "acc": 0.98},
	&"shotgun":  {"ammo": &"shell",  "dmg": DMG_UNIT * 1.0, "fr": 1.4,  "mmin": 5,  "mmax": 8,   "crit": 2.0, "rl": 3.5, "acc": 0.50},
	&"revolver": {"ammo": &"shell",  "dmg": DMG_UNIT * 0.2, "fr": 8.0,  "mmin": 5,  "mmax": 7,   "crit": 2.5, "rl": 2.8, "acc": 0.88},

	# --- ORDNANCE (the BL4-style second equip slot) ---
	# Cooldown-gated, not magazine-gated: `fr` is exactly 1.0/cooldown, so base DPS lands
	# on the same ~60 parity every gun class holds and the score formula needs no special
	# case. `mmin`/`mmax` are CHARGES held, not magazine size.
	#
	# NOTE these deliberately break the >= 1.25 base_fire_rate floor. That floor exists so
	# no GUN feels sluggish; ordnance is supposed to be slow, and its cadence is a
	# cooldown the player watches rather than a trigger they hold. GunStats exempts
	# is_ordnance from the 1.0/s clamp for exactly this reason.
	&"grenade": {"ammo": &"ordnance", "dmg": 150.0, "fr": 0.40, "mmin": 2, "mmax": 4,
		"crit": 1.0, "rl": 0.0, "acc": 1.0, "ord": true, "cd": 2.50, "blast": 4.0},
	&"rocket_launcher": {"ammo": &"ordnance", "dmg": 240.0, "fr": 0.25, "mmin": 1, "mmax": 2,
		"crit": 1.25, "rl": 0.0, "acc": 0.9, "ord": true, "cd": 4.00, "blast": 5.0},
	&"grenade_launcher": {"ammo": &"ordnance", "dmg": 100.0, "fr": 0.60, "mmin": 3, "mmax": 6,
		"crit": 1.0, "rl": 0.0, "acc": 0.8, "ord": true, "cd": 1.67, "blast": 3.0},
	&"mine_layer": {"ammo": &"ordnance", "dmg": 120.0, "fr": 0.50, "mmin": 3, "mmax": 5,
		"crit": 1.0, "rl": 0.0, "acc": 1.0, "ord": true, "cd": 2.00, "blast": 3.5},
	&"drone": {"ammo": &"ordnance", "dmg": 40.0, "fr": 1.50, "mmin": 1, "mmax": 1,
		"crit": 1.0, "rl": 0.0, "acc": 1.0, "ord": true, "cd": 0.67, "blast": 1.5},
	# The shock special weapon (COMBAT_DESIGN 7.3): each charge is a shock arc through up
	# to six enemies, each slowed (GunController.ARC_CASTER). No blast.
	&"arc_caster": {"ammo": &"ordnance", "dmg": 120.0, "fr": 0.50, "mmin": 2, "mmax": 3,
		"crit": 1.0, "rl": 0.0, "acc": 1.0, "ord": true, "cd": 2.00, "blast": 0.0},
}

## The kinds, per gun class: what each multiplies of the class's preset --
## [damage, fire rate, reload time, accuracy, magazine rounds] -- and its name.
## A heavy spends two rounds a shot. Its damage and fire rate come from its own shots to
## kill (the Armory Ledger's Time to kill tab): e.g. the Magnum kills a medium enemy's
## health in one crit, firing 3 a second against the pistol's 8.
## Not listed: the class as it is (light) -- and ordnance has no kinds. The shotgun's
## light kind is the pump; its auto kind (AUTO_CHANCE of light shotguns) is weaker.
const KINDS := {
	&"pistol": {&"heavy": [2.750, 0.375, 1.15, 1.05, 1.0], &"heavy_name": "Magnum"},
	&"revolver": {&"heavy": [2.750, 0.375, 1.15, 1.03, 1.0], &"heavy_name": "Hand Cannon"},
	&"smg": {&"heavy": [1.667, 0.679, 1.15, 1.05, 1.0], &"heavy_name": "Heavy SMG"},
	&"rifle": {&"heavy": [1.417, 0.650, 1.15, 1.05, 1.0], &"heavy_name": "Battle Rifle"},
	&"lmg": {&"heavy": [1.270, 0.692, 1.15, 1.05, 1.0], &"heavy_name": "Heavy Machine Gun"},
	&"dmr": {&"heavy": [2.100, 0.514, 1.15, 1.02, 1.0], &"heavy_name": "Heavy DMR"},
	&"sniper": {&"heavy": [1.450, 0.500, 1.2, 1.0, 1.0], &"heavy_name": "Anti-Materiel Rifle"},
	&"shotgun": {&"heavy": [1.450, 0.500, 1.2, 1.1, 1.0], &"heavy_name": "Heavy Shotgun",
		&"light_name": "Pump Shotgun",
		&"auto": [0.45, 2.0, 1.0, 1.0, 1.4], &"auto_name": "Auto Shotgun"},
}
## How likely a dropped gun is heavy, by rarity (common..mythic): heavies are rarer.
const HEAVY_CHANCE: Array[float] = [0.15, 0.2, 0.25, 0.3, 0.35, 0.4]
## Of light shotguns, how many are the auto kind (the rest pumps).
const AUTO_CHANCE := 0.5
## Of legendaries and mythics, how many break their kind's trade.
const CROSSED_CHANCE := 0.35

## Seconds to put the last gun away and bring this one up (PlayerView's swap), per
## class: a pistol is quick, a long gun slow; a heavy takes SWAP_HEAVY as long.
const SWAP_TIMES := {
	&"pistol": 0.36, &"revolver": 0.4, &"smg": 0.42, &"rifle": 0.48, &"shotgun": 0.55,
	&"dmr": 0.55, &"sniper": 0.7, &"lmg": 0.8,
}
const SWAP_TIME_BASE := 0.48
const SWAP_HEAVY := 1.25

## Ordnance ids, for pools that must draw from one category or the other.
const ORDNANCE_IDS: Array[StringName] = [
	&"grenade", &"rocket_launcher", &"grenade_launcher", &"mine_layer", &"drone", &"arc_caster",
]
## Base damage is a 10× DOWNSCALE of the original table (pistol 100 -> 10), so a level-1
## rifle reads ~9 per shot instead of ~89. Enemy HP was divided by the SAME constant
## (QUALITY_NAMING §7.2), so shots-to-kill is bit-for-bit unchanged, and `score` is a
## RATIO of DPS to class base (§4) so it is unaffected too. Base DPS parity holds at ~60.
## If this is ever rescaled again, the enemy HP table must move by the same factor or
## every shots-to-kill number in the spec silently becomes wrong.


## How long a swap to a gun of this class takes, down and up (the card's swap speed).
func swap_time() -> float:
	var t := float(SWAP_TIMES.get(id, SWAP_TIME_BASE))
	return t * (SWAP_HEAVY if archetype == &"heavy" and not crossed else 1.0)


## Build a class from a shipping preset (falls back to pistol).
static func builtin(class_id: StringName) -> WeaponClass:
	var p: Dictionary = _PRESETS.get(class_id, _PRESETS[&"pistol"])
	var wc := WeaponClass.new()
	wc.id = class_id if _PRESETS.has(class_id) else &"pistol"
	wc.display_name = String(wc.id).capitalize()
	wc.ammo = p.ammo
	wc.base_damage = p.dmg
	wc.base_fire_rate = p.fr
	wc.mag_min = float(p.mmin)
	wc.mag_max = float(p.mmax)
	wc.crit_mult = p.crit
	wc.base_reload = p.rl
	wc.base_accuracy = p.acc
	wc.is_ordnance = bool(p.get("ord", false))
	wc.cooldown = float(p.get("cd", 0.0))
	wc.blast_radius = float(p.get("blast", 0.0))
	return wc


## This class as the given kind (&"light" / &"heavy"), crossed or not. Ordnance, and a
## class with no kinds, come back as they are.
func with_kind(kind: StringName, p_crossed := false) -> WeaponClass:
	if is_ordnance or kind == &"" or not KINDS.has(id):
		return self
	var row: Dictionary = KINDS[id]
	var wc := duplicate() as WeaponClass
	wc.archetype = kind
	wc.crossed = p_crossed
	wc.rounds_per_shot = 2 if kind == &"heavy" else 1
	var m: Array = row.get(kind, [1.0, 1.0, 1.0, 1.0, 1.0])
	var dmg := float(m[0])
	var fr := float(m[1])
	if p_crossed:
		# Without the other kind's penalty: a heavy fires at the light's rate, a light
		# hits with the heavy's damage (and still spends one round).
		var other: Array = row.get(&"light" if kind == &"heavy" else &"heavy", [1.0, 1.0, 1.0, 1.0, 1.0])
		if kind == &"heavy":
			fr = float(other[1])
		else:
			dmg = float(other[0])
	wc.base_damage = base_damage * dmg
	wc.base_fire_rate = base_fire_rate * fr
	wc.base_reload = base_reload * float(m[2])
	wc.base_accuracy = minf(base_accuracy * float(m[3]), 1.0)
	wc.mag_min = roundf(mag_min * float(m[4]))
	wc.mag_max = roundf(mag_max * float(m[4]))
	wc.display_name = kind_name()
	return wc


## What the player calls it: "Magnum", "Auto Shotgun", "Rifle".
func kind_name() -> String:
	var plain := String(id).capitalize().replace("_", " ")
	if archetype == &"" or not KINDS.has(id):
		return plain
	return String((KINDS[id] as Dictionary).get(StringName(String(archetype) + "_name"), plain))


## A dropped gun's class: its kind rolled off its seed and rarity (rarity < 1: unknown
## yet, the common chance). The roll is its own stream, so the parts and stats the seed
## rolls are the ones it always rolled.
static func rolled(class_id: StringName, gen_seed: int, rarity := -1) -> WeaponClass:
	var wc := builtin(class_id)
	if wc.is_ordnance or not KINDS.has(wc.id):
		return wc
	var r := RandomNumberGenerator.new()
	r.seed = hash([gen_seed, 0x4EA7])
	var i := clampi(rarity - 1, 0, HEAVY_CHANCE.size() - 1)
	var kind := &"heavy" if r.randf() < HEAVY_CHANCE[i] else &"light"
	var cross := rarity >= 5 and r.randf() < CROSSED_CHANCE
	# A light shotgun is a pump or an auto, even odds (its own draw, after the others).
	if kind == &"light" and (KINDS[wc.id] as Dictionary).has(&"auto") and r.randf() < AUTO_CHANCE:
		kind = &"auto"
	return wc.with_kind(kind, cross)


static func all_ids() -> Array:
	return _PRESETS.keys()


## Gun classes only — everything that is not ordnance.
static func gun_ids() -> Array:
	var out: Array = []
	for k: StringName in _PRESETS:
		if not bool(_PRESETS[k].get("ord", false)):
			out.append(k)
	return out
