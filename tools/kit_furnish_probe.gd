extends SceneTree
## Furnishing and dressing a generated station's or ship's rooms
## (Docs/RoomModules.md 7.7, 7.10).
##
##     godot --headless --path . --script res://tools/kit_furnish_probe.gd
##
##   empty     a room with nothing in it is furnished, its bricks plain (drawn)
##   held      a room with furniture of its own (interior bricks) gets none
##             more, and its own is made plain bricks, so a station draws it
##   band      every kit module but the truss has its band course in the mark
##             colour; painting a station by its seed gives it one band colour,
##             the same each time, not every seed the same

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("kit furnish probe")
	_run()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A floor of plates 12 x 12 and one space over it of `kind`.
func _room(kind: String) -> BuildRecipe:
	var r := BuildRecipe.new()
	StationKit._tiles(r, Vector3i.ZERO, Vector2i(12, 12), 0)
	var cols := []
	for z in 12:
		for x in 12:
			cols.append([x, z])
	var rec := StructureSpaces.empty()
	rec.spaces = [{"id": 0, "kind": kind, "frame": 0, "seed": [6, 1, 6], "floor_y": 0, "ceil_y": 17, "columns": cols}]
	r.meta["structure"] = rec
	return r


func _run() -> void:
	var empty := _room("cabin")
	var n0 := empty.size()
	var items := KitFurnish.furnish(empty, 3)
	var plain := true
	for i in empty.size():
		plain = plain and not empty.is_interior(i)
	_ok("empty: a room with nothing in it is furnished, in plain bricks", items > 0 and empty.size() > n0 and plain,
			"%d item(s), %d brick(s)" % [items, empty.size() - n0])

	var held := _room("cabin")
	var own := held.add("brick_2x2", Vector3i(1, 1, 1), 4, 0, BuildRecipe.Role.INTERIOR)
	var n1 := held.size()
	var more := KitFurnish.furnish(held, 3)
	_ok("held: a room with its own furniture gets none more, its own drawn (plain bricks)",
			more == 0 and held.size() == n1 and not held.is_interior(own), "%d item(s)" % more)

	var mark := StationKit._colour(StationKit.BAND_MARK)
	var bad := []
	for m: BuildRecipe in StationKit.modules():
		var banded := 0
		for i in m.size():
			if m.colour_of(i) == mark:
				banded += 1
		var truss := String(m.meta.module.get("role", "")) == "truss"
		if (banded == 0) != truss:
			bad.append("%s %d" % [m.name, banded])
	var made := RoomStation.generate(StationKit.library(), {"seed": 5, "modules": 14, "spine": 3})
	var colours := {}
	var painted := {}
	for sd in [1, 2, 3, 4, 5, 6]:
		var r := BuildRecipe.from_dict(made.recipe.to_dict())
		var n := StationKit.paint_band(r, sd)
		var seen := {}
		for i in r.size():
			if made.recipe.colour_of(i) == mark:
				seen[r.colour_of(i)] = true
		painted[sd] = n
		if seen.size() == 1:
			colours[seen.keys()[0]] = true
		else:
			bad.append("seed %d: %d colour(s)" % [sd, seen.size()])
	_ok("band: every kit module but the truss banded; a station painted one colour by its seed, not all the same",
			bad.is_empty() and colours.size() > 1 and int(painted[1]) > 0 and StationKit.is_kit(StationKit.library()),
			"%d colour(s) over 6 seeds, %d band brick(s) %s" % [colours.size(), int(painted[1]), str(bad)])
