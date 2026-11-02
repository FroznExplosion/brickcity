extends SceneTree
## The air inside a hull (HullAir, Docs/Hulls.md 2-3).
##
##     godot --headless --path . --script res://tools/hull_air_probe.gd
##
##   baked     8 generated ships: inside air, rooms as compartments, no breach,
##             one door to the outside (the airlock), every block followed
##   shot      a hull brick beside a room knocked out: exactly that room breached,
##             the breach where the brick was, no other room touched
##   wall      a brick between two rooms knocked out: they merge, still sealed
##   patched   the hull brick laid back: the room sealed again
##   airlock   opened: what it opens onto breached; shut: sealed

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("hull air probe")
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


func _run() -> void:
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var bad := []
	var worst_ms := 0.0
	var seeds := 0
	for sd in range(1, 9):
		var m := ShipBuild.make(sd)
		if not m.ok:
			bad.append("seed %d: %s" % [sd, m.why])
			continue
		var r: BuildRecipe = m.recipe
		var ch := w.create_chunk(Vector3i.ZERO, r.chunk_dims())
		r.build(w, ch, pal)
		var air := HullAir.bake(w, ch, r)
		worst_ms = maxf(worst_ms, air.bake_ms)
		var comps := air.compartments()
		var rooms := (m.plan.placed as Array).size()
		var outside_doors := 0
		for d in air.doors:
			if bool(d.outside):
				outside_doors += 1
		var breached := 0
		for c in comps:
			if int(c.breaches) > 0:
				breached += 1
		print("  seed %d: %s cells, %d inside in %d compartment(s), %d rooms, %d doors (%d outside), %.0f ms" % [
				sd, str(air.dims), air.inside_cells(), comps.size(), rooms, air.doors.size(),
				outside_doors, air.bake_ms])
		if air.inside_cells() == 0:
			bad.append("seed %d: no inside air" % sd)
		if comps.size() < rooms:
			bad.append("seed %d: %d compartments for %d rooms" % [sd, comps.size(), rooms])
		if breached > 0:
			bad.append("seed %d: %d compartment(s) breached as built" % [sd, breached])
		if outside_doors != 1:
			bad.append("seed %d: %d outside doors" % [sd, outside_doors])
		if not air.follows_hits():
			bad.append("seed %d: blocks not followed" % sd)
		if sd == 1:
			_hits(w, ch, r, air, pal)
		w.release_chunk(ch)
		seeds += 1
	_ok("8 ships baked", seeds == 8 and bad.is_empty(), "; ".join(bad))
	print("  worst bake %.0f ms" % worst_ms)


## Shoot, merge, patch and the airlock, on one ship.
func _hits(w: BrickWorld, ch: int, r: BuildRecipe, air: HullAir, pal: Dictionary) -> void:
	# A hull brick: one with a cell beside inside air AND one beside outside air.
	var hull_b := -1
	var room_ci := -1
	var wall_b := -1
	var wall_pair := []
	for b in w.get_block_count(ch):
		var ins := {}
		var out := false
		for i in air._block_cells(b):
			for j in air._neighbours(i):
				if air.state[j] == HullAir.INSIDE:
					ins[air._root(air.comp[j])] = true
				elif air.state[j] == HullAir.OUTSIDE:
					out = true
		if hull_b < 0 and out and ins.size() == 1:
			hull_b = b
			room_ci = ins.keys()[0]
		if wall_b < 0 and not out and ins.size() == 2:
			wall_b = b
			wall_pair = ins.keys()
		if hull_b >= 0 and wall_b >= 0:
			break
	_ok("a hull brick beside a room, and a wall between two", hull_b >= 0 and wall_b >= 0,
			"hull %d wall %d" % [hull_b, wall_b])
	if hull_b < 0 or wall_b < 0:
		return
	var n0 := air.compartments().size()

	# Shot through the hull.
	var cells_of := air._block_cells(hull_b)
	var hb_cell := air._cell(cells_of[0])
	var part := r.part_of(air._block_recipe[hull_b])
	var colour := r.colour_of(air._block_recipe[hull_b])
	var base := r.cell_of(air._block_recipe[hull_b]) - r.origin()
	w.kill_blocks(ch, PackedInt32Array([hull_b]))
	var t0 := Time.get_ticks_usec()
	var hit := air.blocks_removed(w, ch, PackedInt32Array([hull_b]))
	var hit_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var others := 0
	for c in air.compartments():
		if int(c.breaches) > 0 and c.id != air._root(room_ci):
			others += 1
	_ok("shot: that room breached, no other", hit == [air._root(room_ci)] and others == 0,
			"breached %s, room %d, others %d, %.2f ms" % [str(hit), room_ci, others, hit_ms])
	var near := false
	for c in air.breach_cells(room_ci):
		near = near or (c - hb_cell).abs() <= Vector3i(4, 4, 4)
	_ok("the breach is where the brick was", near)

	# A wall between two rooms.
	w.kill_blocks(ch, PackedInt32Array([wall_b]))
	air.blocks_removed(w, ch, PackedInt32Array([wall_b]))
	var a: int = air._root(wall_pair[0])
	var b2: int = air._root(wall_pair[1])
	_ok("wall: the two rooms are one", a == b2 and air.compartments().size() == n0 - 1,
			"%d / %d, %d -> %d compartments" % [a, b2, n0, air.compartments().size()])

	# Patched: the hull brick laid again -- the dead one taken out and a new one
	# laid (no revive yet: the repair step, Hulls.md 9, brings one).
	w.remove_block(ch, hull_b)
	var nb := w.place_block(ch, base, pal[part], colour)
	var cells: Array[Vector3i] = []
	for i in cells_of:
		cells.append(air._cell(i))
	var sealed := air.cells_added(w, ch, cells)
	_ok("patched: the room sealed again", nb >= 0 and not air.is_breached(room_ci),
			"new block %d, sealed %s, breach cells left %d" % [nb, str(sealed), air.breach_cells(room_ci).size()])

	# The airlock.
	var di := -1
	for i in air.doors.size():
		if bool(air.doors[i].outside):
			di = i
	var opened := air.set_door(di, true)
	var onto := -1
	for s in air.door_sides(di):
		if s >= 0:
			onto = s
	_ok("airlock open: what it opens onto is breached", onto >= 0 and air.is_breached(onto),
			"opened %s" % str(opened))
	air.set_door(di, false)
	_ok("airlock shut: sealed", onto >= 0 and not air.is_breached(onto))
