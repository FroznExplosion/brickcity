class_name PartStandards
extends RefCounted
## The interfaces and body plans of Docs/Parts/standards.json, read once
## (Docs/ModularParts.md sections 3 and 10). An interface is a named physical fit; a part
## joins a socket only on one listed here, so a typo is caught, never fits by accident.

const PATH := "res://Docs/Parts/standards.json"
## The tables that hold interfaces, one per family of fit.
const TABLES := ["gun_interfaces", "mgun_interfaces", "mech_interfaces", "figure_interfaces"]

static var _interfaces: Dictionary = {}
static var _plans: Dictionary = {}
static var _version := 0
static var _loaded := false


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var d = JSON.parse_string(FileAccess.get_file_as_string(PATH)) if FileAccess.file_exists(PATH) else null
	if not d is Dictionary:
		push_error("PartStandards: cannot read %s" % PATH)
		return
	_version = int(d.get("version", 0))
	for t in TABLES:
		for k in (d.get(t, {}) as Dictionary):
			if k != "note":
				_interfaces[k] = d[t][k]
	for k in (d.get("body_plans", {}) as Dictionary):
		if k != "note":
			_plans[k] = d.body_plans[k]


## standards.json's version: a part package says which it was made against.
static func version() -> int:
	_load()
	return _version


## The interface's entry ({slot, connector ...}), or {} if there is no such interface.
static func interface(iface: String) -> Dictionary:
	_load()
	return _interfaces.get(iface, {})


static func interfaces() -> Array:
	_load()
	var out := _interfaces.keys()
	out.sort()
	return out


## A body plan: {root, sockets: {path: {slot, side?, required}}, same: [{paths, param}]}.
static func plan(plan_name: String) -> Dictionary:
	_load()
	return _plans.get(plan_name, {})


static func plans() -> Array:
	_load()
	return _plans.keys()
