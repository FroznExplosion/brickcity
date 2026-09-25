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

@export var base_damage: float = 100.0            ## worst-common, level-1 per-hit
@export var base_fire_rate: float = 6.0           ## shots/sec at base
@export var mag_min: float = 10.0
@export var mag_max: float = 16.0
@export var crit_mult: float = 1.75
@export var base_reload: float = 1.6
@export var base_accuracy: float = 0.90           ## 0..1

## Shipping presets (WEAPONS §2). Keyed by class id.
const _PRESETS := {
	&"pistol":   {"ammo": &"light",  "dmg": 10.0, "fr": 6.0,  "mmin": 10, "mmax": 16,  "crit": 1.75, "rl": 1.6, "acc": 0.90},
	&"smg":      {"ammo": &"light",  "dmg": 4.5,  "fr": 13.0, "mmin": 25, "mmax": 40,  "crit": 1.40, "rl": 1.8, "acc": 0.75},
	&"rifle":    {"ammo": &"rifle",  "dmg": 8.0,  "fr": 7.5,  "mmin": 24, "mmax": 40,  "crit": 1.75, "rl": 2.4, "acc": 0.85},
	&"lmg":      {"ammo": &"rifle",  "dmg": 6.5,  "fr": 10.0, "mmin": 80, "mmax": 120, "crit": 1.50, "rl": 4.0, "acc": 0.70},
	&"dmr":      {"ammo": &"sniper", "dmg": 15.0, "fr": 3.5,  "mmin": 12, "mmax": 18,  "crit": 2.25, "rl": 2.6, "acc": 0.95},
	# fr 1.35 (not 1.2) so the worst FEEL roll still clears the 1.0 shots/sec floor:
	# 1.35 * 0.80 = 1.08/s (QUALITY_NAMING §4.4). dmg re-solved to hold ~60 base DPS.
	# Do NOT "fix" this by clamping the rolled fire rate — that raises the gun's DPS
	# above its roll and punches a hole in the §4.3 spread budget for this class alone.
	&"sniper":   {"ammo": &"sniper", "dmg": 44.5, "fr": 1.35, "mmin": 4,  "mmax": 6,   "crit": 3.00, "rl": 3.2, "acc": 0.98},
	&"shotgun":  {"ammo": &"shell",  "dmg": 30.0, "fr": 1.6,  "mmin": 5,  "mmax": 8,   "crit": 1.60, "rl": 3.5, "acc": 0.50},
	&"revolver": {"ammo": &"shell",  "dmg": 32.0, "fr": 2.0,  "mmin": 5,  "mmax": 7,   "crit": 2.75, "rl": 2.8, "acc": 0.88},

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
}

## Ordnance ids, for pools that must draw from one category or the other.
const ORDNANCE_IDS: Array[StringName] = [
	&"grenade", &"rocket_launcher", &"grenade_launcher", &"mine_layer", &"drone",
]
## Base damage is a 10× DOWNSCALE of the original table (pistol 100 -> 10), so a level-1
## rifle reads ~9 per shot instead of ~89. Enemy HP was divided by the SAME constant
## (QUALITY_NAMING §7.2), so shots-to-kill is bit-for-bit unchanged, and `score` is a
## RATIO of DPS to class base (§4) so it is unaffected too. Base DPS parity holds at ~60.
## If this is ever rescaled again, the enemy HP table must move by the same factor or
## every shots-to-kill number in the spec silently becomes wrong.


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


static func all_ids() -> Array:
	return _PRESETS.keys()


## Gun classes only — everything that is not ordnance.
static func gun_ids() -> Array:
	var out: Array = []
	for k: StringName in _PRESETS:
		if not bool(_PRESETS[k].get("ord", false)):
			out.append(k)
	return out
