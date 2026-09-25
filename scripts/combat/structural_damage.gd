class_name StructuralDamage
extends RefCounted
## What a gun does to bricks. The one place that decides it (Docs/AIPlan.md R16).
##
## Enemies and bricks are hit by the same bullet but judged by different rules:
##
##   * **Tier, rarity and crits do not reach the wall.** A tier-10 gun is ten tiers of
##     stronger ENEMY, and the city is the same city at every tier. So a brick is worn
##     by the gun's CLASS -- its per-hit base damage, before any roll -- and a
##     legendary pistol chips the way a common one does. Crits are weak spots, and a
##     wall has none.
##   * **A bullet wears, it does not delete.** Every brick has 255 hp
##     (BrickWorld.chip_hit); a pistol takes three hits to break one, an SMG seven.
##     Deleting a brick per bullet let an SMG erase a wall at thirteen bricks a
##     second, and ten AI agents suppressing would have levelled the block they were
##     fighting over (R16).
##   * **Ordnance is a blast** (BrickWorld.apply_hit): it destroys outright, over a
##     radius far smaller than the one it hurts enemies in -- a grenade's four metres
##     of splash would take a storey out of a tower.
##
## Tune here and nowhere else. Every gun, the player's, the mech's and the AI's,
## goes through `for_shot`.

## The pistol -- the reference class, base damage 10 -- breaks a brick in three.
const HP_PER_BASE_DAMAGE := 8.5
const BRICK_HP := 255

## Radius of a gun's wear, by ammo. Zero is the one brick the bullet struck
## (chip_hit always takes that one). A sniper round punches through into the brick
## behind; a shell is a fistful of pellets.
const CHIP_RADIUS := {
	&"light": 0.0,
	&"rifle": 0.0,
	&"sniper": 0.2,
	&"shell": 0.35,
}

## An explosive-effect gun (EffectDispatch) wears a small ball as well as the brick
## it struck. Its splash on enemies is metres; on bricks, this.
const SPLASH_CHIP_RADIUS := 0.5

## Ordnance: brick blast radius as a fraction of the enemy blast radius, and a cap.
const ORDNANCE_BLAST_SCALE := 0.35
const ORDNANCE_BLAST_MAX := 2.0


## What one shot of this class does to structure:
##   {"blast": bool, "radius": metres, "hp": wear per brick (0 for a blast)}
## `effects` are the gun's active effect ids (GunInstance.active_effects).
static func for_shot(weapon_class: WeaponClass,
		effects := PackedStringArray()) -> Dictionary:
	var wc := weapon_class if weapon_class != null else WeaponClass.builtin(&"pistol")
	if wc.is_ordnance:
		return {"blast": true, "hp": 0,
				"radius": minf(wc.blast_radius * ORDNANCE_BLAST_SCALE, ORDNANCE_BLAST_MAX)}
	var radius: float = float(CHIP_RADIUS.get(wc.ammo, 0.0))
	if effects.has("explosive"):
		radius = maxf(radius, SPLASH_CHIP_RADIUS)
	return {"blast": false, "radius": radius, "hp": chip_hp(wc)}


## Wear per hit for a class: tier-free, rarity-free, crit-free. At least 1, at
## most a whole brick.
static func chip_hp(weapon_class: WeaponClass) -> int:
	return clampi(roundi(weapon_class.base_damage * HP_PER_BASE_DAMAGE), 1, BRICK_HP)


## Hits of this class it takes to break one brick. For probes and tuning.
static func hits_per_brick(weapon_class: WeaponClass) -> int:
	return ceili(float(BRICK_HP) / float(chip_hp(weapon_class)))
