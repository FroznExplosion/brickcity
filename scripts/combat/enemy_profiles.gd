class_name EnemyProfiles
extends RefCounted
## What an enemy wears over its flesh, in MELEES to break each layer
## (Docs/Weapons/COMBAT_DESIGN.md 4.1-4.2; CombatScale for the unit).
##
## The point is that a player who looks at an enemy knows the count: every enemy up to
## medium has one melee of flesh, and its shield or armor says how many more. A very
## light enemy's flesh is HALF a melee -- still one melee, but fewer rounds.
##
## Layers are listed top first: shield over armor over flesh. Shields regenerate after a
## pause (CombatScale); armor and flesh do not.

const SHIELD := &"shield"
const ARMOR := &"armor"
const FLESH := &"health"
const VEGETATION := &"vegetation"

## id -> [[layer type, melees], ...], top first. The last layer is the vital one.
const PROFILES := {
	&"very_light": [[FLESH, 0.5]],
	&"very_light_shielded": [[SHIELD, 1.0], [FLESH, 0.5]],
	&"light": [[FLESH, 1.0]],
	&"light_shielded": [[SHIELD, 1.0], [FLESH, 1.0]],
	&"light_armored": [[ARMOR, 1.0], [FLESH, 1.0]],
	&"medium": [[ARMOR, 3.0], [FLESH, 1.0]],
	&"medium_shielded": [[SHIELD, 3.0], [FLESH, 1.0]],
	&"heavy": [[SHIELD, 2.0], [ARMOR, 3.0], [FLESH, 2.0]],
	&"plant": [[VEGETATION, 1.0]],
}

const COLOURS := {
	SHIELD: Color(0.35, 0.75, 1.0),
	ARMOR: Color(0.95, 0.75, 0.3),
	FLESH: Color(0.9, 0.3, 0.25),
	VEGETATION: Color(0.4, 0.85, 0.3),
}


static func has(id: StringName) -> bool:
	return PROFILES.has(id)


## The layers of `id` at `level`, top first, ready for a HealthPool.
static func layers(id: StringName, level: int) -> Array[DefenseLayer]:
	var out: Array[DefenseLayer] = []
	for row in PROFILES.get(id, PROFILES[&"light"]):
		var l := DefenseLayer.new()
		l.layer_type = row[0]
		l.max_value = CombatScale.layer_hp(row[0], float(row[1]), level)
		l.display_color = COLOURS.get(row[0], Color.WHITE)
		if row[0] == SHIELD:
			l.regen_delay = CombatScale.SHIELD_REGEN_DELAY
			l.regen_rate = l.max_value / CombatScale.SHIELD_REGEN_SECONDS
		out.append(l)
	return out


## Dress `pool` as `id` at `level`, full. Returns its total health.
static func apply(pool: HealthPool, id: StringName, level: int) -> float:
	pool.layer_configs = layers(id, level)
	pool.vital_layer_index = -1
	# What breaks a layer goes on into the next (shield gating halves a body shot's).
	pool.impact_carries_over = true
	pool.reset()
	return pool.total_current()


## Melees to break each layer of `id`, top first -- what the player is meant to read.
static func melee_counts(id: StringName) -> Array[float]:
	var out: Array[float] = []
	for row in PROFILES.get(id, PROFILES[&"light"]):
		out.append(float(row[1]))
	return out
