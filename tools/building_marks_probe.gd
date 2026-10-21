extends SceneTree

## Probe for the points authors mark in builds (BuildingMarks; Docs/AI.md 3.3.1).
##
##     godot --headless --path . --script res://tools/building_marks_probe.gd
##
## A. Where a mark is: a build placed turned and off the origin puts each mark
##    at the middle of its cell, feet on the floor, rebased with the bricks; the
##    city's lookup finds it near and not far, and a toppled build has none.
## B. Cover from a mark: a soldier with an enemy across a wall takes the
##    marked spot behind it -- without the ring search. A mark in the open, on
##    another floor, or behind a wall that has been blown away is no cover, and
##    the ring search answers as it always did.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("building marks probe")
	_check_where()
	_check_cover()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _check_where() -> void:
	print("\nA. where a mark is")
	var w := BrickWorld.new()
	var reg := BuildingRegistry.new(w, BrickPalette.bake(w))
	# A floor of plates from cell (4, 0, 6): not at the origin, so the rebase shows.
	var r := BuildRecipe.new()
	r.name = "marked floor"
	for x in range(4, 16, 2):
		for z in range(6, 16, 2):
			r.add("brick_2x2", Vector3i(x, 0, z), 4)
	var cover_cell := Vector3i(6, 3, 9)
	var spawn_cell := Vector3i(12, 3, 12)
	r.meta["structure"] = {"spaces": [], "openings": [], "points": [
			{"kind": "cover", "at": [cover_cell.x, cover_cell.y, cover_cell.z]},
			{"kind": "spawn", "at": [spawn_cell.x, spawn_cell.y, spawn_cell.z]},
			{"kind": "loot", "at": [8, 3, 8]}]}
	var place := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(30.0, 2.0, -12.0))
	var id := reg.register_build(r, place)
	var b := reg.get_building(id)
	var cs := BrickWorld.get_cell_size()
	var lo := Vector3(r.origin())
	var want := b.xform * ((Vector3(cover_cell.x + 0.5, cover_cell.y, cover_cell.z + 0.5) - lo) * cs)
	var got := BuildingMarks.spots(b, "cover")
	_ok("one cover mark, one spawn mark", got.size() == 1
			and BuildingMarks.spots(b, "spawn").size() == 1, "%d cover" % got.size())
	_ok("the cover mark is at its cell's middle, rebased and turned with the build",
			not got.is_empty() and got[0].distance_to(want) < 0.001,
			"%v vs %v" % [got[0] if not got.is_empty() else Vector3.INF, want])
	# The bricks agree: the floor's top is under the mark's feet.
	var chunk := reg.materialise(id)
	var under := got[0] - Vector3.UP * cs.y * 0.5 if not got.is_empty() else Vector3.INF
	var local: Vector3 = w.get_chunk_transform(chunk).affine_inverse() * under
	var cell := w.get_chunk_origin(chunk) + Vector3i(floori(local.x / cs.x), floori(local.y / cs.y),
			floori(local.z / cs.z))
	_ok("and the plate under its feet is a brick of the floor", w.is_solid(chunk, cell),
			"cell %v" % cell)
	# What the city asks.
	var near := BuildingMarks.near(got[0] + Vector3(3.0, 0.0, 0.0), 6.0, "cover", reg)
	var far := BuildingMarks.near(got[0] + Vector3(40.0, 0.0, 0.0), 6.0, "cover", reg)
	_ok("found from 3 m, not from 40 m", near.size() == 1 and far.is_empty(),
			"%d near, %d far" % [near.size(), far.size()])
	var tower := reg.register(20, 20, 6, Transform3D(Basis(), Vector3(-40.0, 0.0, 0.0)))
	_ok("a generated tower has no marks", BuildingMarks.of_building(reg.get_building(tower)).is_empty())
	b.toppled = true
	_ok("a build that came down has none to give",
			BuildingMarks.near(got[0], 6.0, "cover", reg).is_empty())


func _check_cover() -> void:
	print("\nB. cover from a mark")
	var a := Arena.new(self, 7)
	# A wall of five courses (2.1 m), two studs thick, 10.5 m long: it hides a
	# standing body (nobody crouches, AI.md A21) for over a second, and a step
	# past its end sees round it. The mark is behind it near that end, where a
	# body can peek.
	var wall := a.bricks(Vector3i(0, 0, 0), Vector3i(30, 5, 2))
	var threat_eye := Vector3(5.25, 1.6, -18.0)
	var behind := Vector3(9.8, 0.0, 1.05)
	var from := Vector3(9.0, 0.0, 2.5)
	var marks: Array[Vector3] = [behind]
	a.s.marks = func(p: Vector3, radius: float, kind: String) -> Array[Vector3]:
		var out: Array[Vector3] = []
		if kind == "cover":
			for m in marks:
				if m.distance_to(p) <= radius:
					out.append(m)
		return out
	var rated := CoverSearch.rate(a.s, behind, threat_eye)
	print("    the marked spot rates: %s" % rated)
	var t := Time.get_ticks_usec()
	var found := CoverSearch.find(a.s, from, threat_eye)
	var marked_us := Time.get_ticks_usec() - t
	_ok("a soldier near a wall takes the marked spot behind it",
			found.get("cover", Vector3.INF) == behind, "%s" % found)
	t = Time.get_ticks_usec()
	var ring := a.s.ai_nav.find_cover(from, threat_eye, CoverSearch.THREAT_HP, CoverSearch.THREAT_RATE,
			CoverSearch.IDEAL_RANGE)
	var ring_us := Time.get_ticks_usec() - t
	print("    marked: %d us; the ring search: %d us (to %v)" % [marked_us, ring_us,
			ring.get("cover", Vector3.INF)])

	# Changed in place: the lambda holds this array, not the variable.
	marks.clear()
	marks.append(Vector3(20.0, 0.0, 6.0))
	found = CoverSearch.find(a.s, Vector3(18.0, 0.0, 5.0), threat_eye)
	_ok("a mark in the open is no cover", found.get("cover", Vector3.INF) != marks[0], "%s" % found)

	marks.clear()
	marks.append(behind + Vector3.UP * 3.0)
	found = CoverSearch.find(a.s, from, threat_eye)
	_ok("a mark on another floor is not this soldier's", found.get("cover", Vector3.INF) != marks[0],
			"%s" % found)

	marks.clear()
	marks.append(behind)
	_ok("the same mark is taken again",
			CoverSearch.find(a.s, from, threat_eye).get("cover", Vector3.INF) == behind)
	a.breach(Vector3(9.6, 1.0, 0.35), 1.8)
	_ok("the wall in front of it blown away", a.w.is_chunk_alive(wall) and a.breached_blocks > 0,
			"%d blocks" % a.breached_blocks)
	found = CoverSearch.find(a.s, from, threat_eye)
	_ok("and the mark is no cover any more", found.get("cover", Vector3.INF) != behind, "%s" % found)
