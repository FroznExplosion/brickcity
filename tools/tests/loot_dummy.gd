class_name LootDummy
extends DummyEnemy
## A DummyEnemy that belongs to a loot archetype: trash / standard / heavy / badass /
## boss. On death it emits its drops, hides for RESPAWN_DELAY, then comes back.
##
## Subclasses rather than edits DummyEnemy because test_bed.gd depends on that class's
## 1.5s respawn and no-loot behaviour. Everything here is additive.

const RESPAWN_DELAY := 3.0

signal dropped_loot(archetype: StringName, enemy_tier: int, origin: Vector3)

var archetype: StringName = &"trash"
var enemy_tier: int = 1

var _name_label: Label3D


func setup_loot(p_archetype: StringName, p_tier: int, p_name_label: Label3D) -> void:
	archetype = p_archetype
	enemy_tier = p_tier
	_name_label = p_name_label
	_refresh_name()


## Re-scale to a new tier. Called when the bed changes tier, so the range always
## presents enemies at the tier being tested.
func set_tier(p_tier: int) -> void:
	enemy_tier = p_tier
	if pool != null and pool.layer_count() > 0:
		var hp := LootRoller.enemy_hp(archetype, enemy_tier)
		pool.layer_configs[0].max_value = hp
		pool.reset()
	_refresh_name()


func _refresh_name() -> void:
	if _name_label != null:
		_name_label.text = "%s  T%d" % [String(archetype).to_upper(), enemy_tier]


## DummyEnemy connects pool.died to this in setup(); overriding intercepts the death
## without touching the base class or re-wiring the signal.
func _on_died() -> void:
	dropped_loot.emit(archetype, enemy_tier, global_position)
	if model_root != null:
		model_root.visible = false
	_respawn = RESPAWN_DELAY
