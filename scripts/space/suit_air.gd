class_name SuitAir
extends RefCounted
## What low air does to a player (Docs/Hulls.md 4.3, the user's call 2026-11-09): a
## suit timer, then damage. Where the air you breathe is under HullAir.LOW (a
## breached room, space, a world's thin upper air, a head under water:
## PlanetSystem.under_water_at) the suit's own air runs down, a
## second a second; back in good air it fills again. Run out, and the lack of air
## hurts you -- straight to health (shields and armour keep nothing out of your
## lungs) -- until you are back in air or dead.

## Seconds of air in a full suit.
const SUIT_S := 60.0
## Seconds an empty suit takes to fill in good air.
const REFILL_S := 8.0
## Out of suit air: this share of a pool's health a second (10 s to dead).
const HURT_SHARE := 0.1
## What the damage is (HealthPool element; nothing resists it).
const ELEMENT := &"suffocation"

## Suit air left, seconds.
var left := SUIT_S
## The air breathed last tick (0..1).
var pressure := 1.0


## One tick in air of `p` (0..1). Returns the damage it does this tick, as a share of
## the pool's health: 0 while the suit has air.
func tick(dt: float, p: float) -> float:
	pressure = p
	if p >= HullAir.LOW:
		left = minf(SUIT_S, left + dt * SUIT_S / REFILL_S)
		return 0.0
	if left > 0.0:
		left -= dt
		if left >= 0.0:
			return 0.0
		# The part of this tick past empty hurts.
		var over := -left
		left = 0.0
		return over * HURT_SHARE
	return dt * HURT_SHARE


## `tick`, the damage put on `pool`'s health layer.
func breathe(dt: float, p: float, pool: HealthPool) -> void:
	var share := tick(dt, p)
	if share <= 0.0 or pool == null or pool.is_dead():
		return
	var idx := -1
	for i in pool.layer_count():
		if pool.layer_type_at(i) == &"health":
			idx = i
	var full := pool.layer_configs[idx].max_value if idx >= 0 else 100.0
	pool.apply_to_layer_type(share * full, &"health", ELEMENT)


## In good air, the suit not full or not needed: nothing to show.
func draining() -> bool:
	return pressure < HullAir.LOW


func empty() -> bool:
	return left <= 0.0 and draining()


func reset() -> void:
	left = SUIT_S
	pressure = 1.0
