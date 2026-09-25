class_name GunEffects
extends RefCounted
## Aggregates the mechanical effects a gun carries from all its parts (slot-agnostic),
## and answers the generator's compatibility question (MANUFACTURER_SPEC §3–§4).
## Effects come from real parts here; gun mods (§3b) and manufacturer badges (§3c)
## append to the same list at equip/generation time in later steps.

## Effect ids carried by a recipe's parts, respecting each effect's own rarity gate.
## DUPLICATES ARE PRESERVED on purpose — two parts carrying the same effect is one of
## the two ways an effect gets upgraded (see stack()).
static func collect(recipe: Dictionary, rarity: int) -> PackedStringArray:
	var out := PackedStringArray()
	for def: Variant in recipe.values():
		if def is GunPartDef:
			var p := def as GunPartDef
			if p.has_effect() and rarity >= p.effect_min_rarity:
				out.append(p.effect_id)
	return out


## Collapse duplicate effects into upgrades. THE unified stacking rule
## (QUALITY_NAMING §11): **two sources of the same effect upgrade it**, and the sources
## are interchangeable —
##
##   part + part      (a gun rolling the same effect twice; legendary+ / always mythic)
##   part + ability    (the player's equipped ability matching the gun)
##   ability + ability (two abilities granting the same effect)
##
## Counting sources rather than special-casing each pairing is what lets a WeaponAbility
## and a gun part be the same currency. A third source adds nothing yet; the cap is
## deliberate so stacking cannot spiral.
static func stack(effects: PackedStringArray) -> PackedStringArray:
	var counts: Dictionary[StringName, int] = {}
	var order: Array[StringName] = []
	for e in effects:
		var base := WeaponAbility.base_id(StringName(e))
		# An already-upgraded id counts as two sources, so stack() is idempotent.
		var weight := 2 if WeaponAbility.is_upgraded(StringName(e)) else 1
		if not counts.has(base):
			counts[base] = 0
			order.append(base)
		counts[base] += weight

	var out := PackedStringArray()
	for base in order:
		out.append(String(WeaponAbility.upgraded_id(base) if counts[base] >= 2 else base))
	return out


## Would `candidate`'s effect conflict with any already-placed part's effect?
## Symmetric tag check: neither side may declare a tag the other carries as
## incompatible. Parts with no effect are always compatible.
static func compatible(candidate: GunPartDef, placed: Array) -> bool:
	if candidate == null or not candidate.has_effect():
		return true

	var placed_tags: Dictionary = {}
	var placed_incompat: Dictionary = {}
	for def: Variant in placed:
		if def is GunPartDef and (def as GunPartDef).has_effect():
			var p := def as GunPartDef
			for t in p.effect_tags:
				placed_tags[t] = true
			for t in p.effect_incompatible_tags:
				placed_incompat[t] = true

	for t in candidate.effect_incompatible_tags:
		if placed_tags.has(t):
			return false
	for t in candidate.effect_tags:
		if placed_incompat.has(t):
			return false
	return true
