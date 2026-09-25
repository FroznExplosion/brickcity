class_name GunPartLibrary
extends Resource
## The catalog of all GunPartDefs. Queried by the generator; also resolves
## serialized recipes (part ids) back into defs for saves / multiplayer.

@export var parts: Array[GunPartDef] = []

var _by_id: Dictionary[StringName, GunPartDef] = {}
var _by_slot: Dictionary[GunPartDef.Slot, Array] = {}
var _indexed := false


func _index() -> void:
	if _indexed:
		return
	_by_id.clear()
	_by_slot.clear()
	for def in parts:
		if def == null or def.scene == null:
			push_warning("GunPartLibrary: skipping null/scene-less part def.")
			continue
		if _by_id.has(def.id):
			push_warning("GunPartLibrary: duplicate part id '%s'." % def.id)
		_by_id[def.id] = def
		if not _by_slot.has(def.slot):
			_by_slot[def.slot] = [] as Array[GunPartDef]
		_by_slot[def.slot].append(def)
	_indexed = true


func get_by_id(id: StringName) -> GunPartDef:
	_index()
	return _by_id.get(id)


## All parts for a slot that fit the rarity, optionally biased to a manufacturer.
func candidates(slot: GunPartDef.Slot, rarity: int,
		manufacturer: StringName = &"") -> Array[GunPartDef]:
	_index()
	var out: Array[GunPartDef] = []
	for def: GunPartDef in _by_slot.get(slot, []):
		if not def.fits_rarity(rarity):
			continue
		if manufacturer != &"" and def.manufacturer != manufacturer:
			continue
		out.append(def)
	# If a manufacturer filter emptied the pool, fall back to any manufacturer
	# so mixed-brand guns are always possible (very Borderlands).
	if out.is_empty() and manufacturer != &"":
		return candidates(slot, rarity)
	return out


## Weighted random pick from a candidate list. Returns null if empty.
static func pick_weighted(pool: Array[GunPartDef], rng: RandomNumberGenerator) -> GunPartDef:
	if pool.is_empty():
		return null
	var total := 0.0
	for def in pool:
		total += maxf(def.weight, 0.0)
	if total <= 0.0:
		return pool[rng.randi_range(0, pool.size() - 1)]
	var roll := rng.randf() * total
	for def in pool:
		roll -= maxf(def.weight, 0.0)
		if roll <= 0.0:
			return def
	return pool[pool.size() - 1]
