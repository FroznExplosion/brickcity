class_name CreatureBook
extends RefCounted
## The animals the mine world knows (Docs/MineCreatures.md 11): every pack's
## data/creatures/*.json "animals" table, merged (a DLC or mod adds animals or
## changes one by naming it). Each entry is completed with defaults so the
## code reads every key without asking.
##
##   body           [width studs, height plates, step up plates, drop plates]
##   temper         "prey" (a herd that notices and runs), "boar" (runs, but
##                  charges when hurt with you near), "predator" (a pack that
##                  stalks, circles and bites)
##   speed          multiples of the walk: graze, alarm, flee (of the run),
##                  stalk, hunt, charge
##   sight, scent   metres
##   wary           how fast notice fills, x
##   jump           climbs `body.z` plates with a jump (a deer: 2 bricks)
##   trample_bricks a fall this high onto a crop tramples it; 0 walking does;
##                  -1 never
##   likes, hunts   crops it eats; animals it hunts
##   drops          {item: count}
##   look           block-out: len (studs), legs (plates), colour, dark, and
##                  snout / antlers / ears / tusks / tail

static var _defs := {}
static var _loaded := false


static func load_all() -> void:
	if _loaded:
		return
	_loaded = true
	for path in ContentPacks.files("data/creatures"):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		if not (parsed is Dictionary) or not (parsed.get("animals") is Dictionary):
			push_warning("[creatures] %s: no \"animals\" table" % path)
			continue
		for k in parsed.animals:
			var raw = parsed.animals[k]
			if raw is Dictionary:
				var base: Dictionary = _defs.get(StringName(k), {})
				var e := base.duplicate(true)
				for key in raw:
					e[key] = raw[key]
				_defs[StringName(k)] = _complete(StringName(k), e)


static func _complete(id: StringName, e: Dictionary) -> Dictionary:
	var b: Array = e.get("body", [2, 6, 3, 9])
	var sp: Dictionary = e.get("speed", {})
	var g: Array = e.get("group", [2, 3])
	return {
		"id": id,
		"name": str(e.get("name", String(id).capitalize())),
		"body": Vector4i(int(b[0]), int(b[1]), int(b[2]), int(b[3])),
		"hp": float(e.get("hp", 30.0)),
		"group": Vector2i(int(g[0]), int(g[1])),
		"temper": str(e.get("temper", "prey")),
		"jump": bool(e.get("jump", false)),
		"zigzag": bool(e.get("zigzag", false)),
		"trample_bricks": float(e.get("trample_bricks", 2.0)),
		"speed": {"graze": float(sp.get("graze", 0.4)), "alarm": float(sp.get("alarm", 0.6)),
				"flee": float(sp.get("flee", 0.9)), "stalk": float(sp.get("stalk", 0.5)),
				"hunt": float(sp.get("hunt", 1.0)), "charge": float(sp.get("charge", 1.0))},
		"sight": float(e.get("sight", 30.0)),
		"scent": float(e.get("scent", 44.0)),
		"wary": float(e.get("wary", 1.0)),
		"likes": (e.get("likes", []) as Array).map(func(c) -> StringName: return StringName(str(c))),
		"hunts": (e.get("hunts", []) as Array).map(func(c) -> StringName: return StringName(str(c))),
		"drops": e.get("drops", {}),
		"charge_damage": float(e.get("charge_damage", 0.0)),
		"bite_damage": float(e.get("bite_damage", 0.0)),
		"look": e.get("look", {}),
	}


static func has(id: StringName) -> bool:
	load_all()
	return _defs.has(id)


static func get_def(id: StringName) -> Dictionary:
	load_all()
	return _defs.get(id, {})


static func ids() -> Array:
	load_all()
	return _defs.keys()
