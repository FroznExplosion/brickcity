class_name MergeRule
extends Resource
## A synergy merge (MANUFACTURER_SPEC §6): when a gun's aggregate effect list holds
## BOTH effect_a and effect_b, it gains `bonus_effect` — an EXTRA on top; the base
## effects keep working. Slot-agnostic (any part can contribute either effect).
## Authorable as .tres later; the static table is the shipping source of truth.

@export var id: StringName
@export var effect_a: StringName
@export var effect_b: StringName
@export var bonus_effect: StringName
## always | conditional | chance — how the bonus fires (dispatch handler reads this).
@export var trigger: StringName = &"always"
@export var params: Dictionary = {}

## Shipping 2-part merges (MANUFACTURER §6). Legendary-only + 3-part merges are
## authored per-legendary, not here.
const _TABLE := [
	{"id": &"ricochet_double_blast",  "a": &"ricochet",       "b": &"explosive",      "bonus": &"ricochet_double_blast",  "trig": &"always"},
	{"id": &"ricochet_dot_up",        "a": &"ricochet",       "b": &"element",        "bonus": &"ricochet_dot_up",        "trig": &"always"},
	{"id": &"power_ricochet",         "a": &"ricochet",       "b": &"power_shot",     "bonus": &"power_ricochet",         "trig": &"always"},
	{"id": &"burst_power_finisher",   "a": &"burst",          "b": &"power_shot",     "bonus": &"burst_power_finisher",   "trig": &"conditional"},
	{"id": &"power_splash",           "a": &"power_shot",     "b": &"explosive",      "bonus": &"power_splash",           "trig": &"conditional"},
	{"id": &"extra_other_element",    "a": &"extra_round",    "b": &"double_element", "bonus": &"extra_other_element",    "trig": &"always"},
	{"id": &"hyperburst_cycle",       "a": &"hyper_burst",    "b": &"double_element", "bonus": &"hyperburst_cycle",       "trig": &"conditional"},
	{"id": &"dual_element_blast",     "a": &"double_element", "b": &"explosive",      "bonus": &"dual_element_blast",     "trig": &"always"},
	{"id": &"charged_lunge",          "a": &"bayonet",        "b": &"power_shot",     "bonus": &"charged_lunge",          "trig": &"conditional"},
	{"id": &"explosive_melee",        "a": &"bayonet",        "b": &"explosive",      "bonus": &"explosive_melee",        "trig": &"always"},
	{"id": &"blood_blade",            "a": &"bayonet",        "b": &"lifesteal",      "bonus": &"blood_blade",            "trig": &"always"},
	{"id": &"desperation_power",      "a": &"overdraw",       "b": &"power_shot",     "bonus": &"desperation_power",      "trig": &"conditional"},
	{"id": &"sustain_overdraw",       "a": &"overdraw",       "b": &"lifesteal",      "bonus": &"sustain_overdraw",       "trig": &"always"},
	{"id": &"shielded_overdraw",      "a": &"shield_module",  "b": &"overdraw",       "bonus": &"shielded_overdraw",      "trig": &"always"},
	{"id": &"ramp_extra",             "a": &"fire_ramp",      "b": &"extra_round",    "bonus": &"ramp_extra",             "trig": &"conditional"},
	{"id": &"elemental_bomblets",     "a": &"cluster",        "b": &"element",        "bonus": &"elemental_bomblets",     "trig": &"always"},
	{"id": &"homing_split",           "a": &"homing",         "b": &"extra_round",    "bonus": &"homing_split",           "trig": &"always"},
	{"id": &"power_offhand_element",  "a": &"power_shot",     "b": &"double_element", "bonus": &"power_offhand_element",   "trig": &"conditional"},
	{"id": &"power_element_chance",   "a": &"power_shot",     "b": &"element",        "bonus": &"power_element_chance",    "trig": &"chance"},
	{"id": &"overkill_ricochet",      "a": &"overkill",       "b": &"ricochet",       "bonus": &"overkill_ricochet",       "trig": &"conditional"},
	{"id": &"overkill_element",       "a": &"overkill",       "b": &"element",        "bonus": &"overkill_element",        "trig": &"conditional"},
	{"id": &"overkill_power",         "a": &"overkill",       "b": &"power_shot",     "bonus": &"overkill_power",          "trig": &"conditional"},
	{"id": &"overkill_leech",         "a": &"overkill",       "b": &"lifesteal",      "bonus": &"overkill_leech",          "trig": &"conditional"},
]


static func shipping_rules() -> Array[MergeRule]:
	var out: Array[MergeRule] = []
	for e: Dictionary in _TABLE:
		var r := MergeRule.new()
		r.id = e.id
		r.effect_a = e.a
		r.effect_b = e.b
		r.bonus_effect = e.bonus
		r.trigger = e.trig
		out.append(r)
	return out


## Merges active for a gun's aggregate effect ids (both halves present, order-free).
##
## Ids are normalised to their BASE form first: an upgraded effect (`ricochet_up`, from
## two stacked sources — MANUFACTURER §8) must still satisfy a rule that asks for
## `ricochet`. Without this, upgrading an effect silently breaks every merge it takes
## part in, which is the exact opposite of what stacking is supposed to be worth.
static func detect(effect_ids: PackedStringArray) -> Array[MergeRule]:
	var have: Dictionary = {}
	for e in effect_ids:
		have[WeaponAbility.base_id(StringName(e))] = true
	var out: Array[MergeRule] = []
	for r in shipping_rules():
		if have.has(r.effect_a) and have.has(r.effect_b):
			out.append(r)
	return out
