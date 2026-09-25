class_name GunSkinLibrary
extends Resource
## Catalog of skins + the manufacturer tint pass: default skins keyed by
## manufacturer, applied automatically when a gun is created with this library.

@export var skins: Array[GunSkinDef] = []
## Manufacturer -> default tint skin (usually pattern-less palette skins).
@export var manufacturer_defaults: Dictionary[StringName, GunSkinDef] = {}
## Fallback when a manufacturer has no entry.
@export var fallback_default: GunSkinDef

var _by_id: Dictionary[StringName, GunSkinDef] = {}
var _indexed := false


func get_by_id(id: StringName) -> GunSkinDef:
	if not _indexed:
		for s in skins:
			if s != null:
				_by_id[s.id] = s
		_indexed = true
	return _by_id.get(id)


func default_for(manufacturer: StringName) -> GunSkinDef:
	return manufacturer_defaults.get(manufacturer, fallback_default)
