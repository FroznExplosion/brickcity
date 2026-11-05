extends SceneTree
## A generated ship (Docs/RoomModules.md 7.5, stage 12): ShipBuild's hull and
## rooms, flown as a SpaceShip -- its seat the bridge's, its nose -Z, its decks
## its anchors, a bulkhead shot through letting what is aft of it go whole.
##
##     godot --headless --path . --script res://tools/ship_build_probe.gd
##
##   ships     8 seeds: a hull 1-3 decks, a bridge (its seat on its floor) in
##             the fore third, an engine room in the aft third, an airlock through
##             the stern onto the spine, most of the inside rooms, sections at the
##             bulkheads, two engine housings of bricks on the roof aft, wings;
##             each laid with nothing loose, every door under its lintel;
##             furnished (KitFurnish): items in its rooms, none in a doorway or
##             beside one, every brick still in a section; windows in its sides;
##             the bridge's consoles (7.11): eight columns or more, all fore of the
##             seat, the seat's own column clear, none by a doorway
##   flown     a SpaceShip of layout "generated": grown at setup, its seat the
##             bridge's -- forward of its middle (-Z), on a floor, under a roof --
##             its hull box long along Z
##   laid      laid frame by frame, every brick, nothing loose (decks anchored)
##   bulkhead  the bulkhead behind the bridge's section shot to under a third:
##             everything aft of it drifts off as one piece, the bridge's stays

var _pass := 0
var _fail := 0
var _drifts := []
var _done := false
var _ship: SpaceShip
var _frames := 0


func _process(_d: float) -> bool:
	if not _done:
		_done = true
		print("ship build probe")
		_run()
		if _ship == null:
			_finish()
		return false
	if _ship == null:
		return true
	_frames += 1
	if not _ship.bricked and _frames < 900:
		return false
	_after_laid()
	_ship = null
	_finish()
	return true


func _finish() -> void:
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
	var bad := []
	var fills := []
	var items := []
	var wins := []
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	for sd in range(1, 9):
		var m := ShipBuild.make(sd)
		if not m.ok:
			bad.append("seed %d: %s" % [sd, m.why])
			continue
		var r: BuildRecipe = m.recipe
		var size: Vector3i = r.bounds()[1]
		fills.append(snappedf(float(m.stats.fill), 0.01))
		var cells := {}
		var inner := {}
		var from := int((r.meta.get("furniture", {}) as Dictionary).get("from", r.size()))
		var con: Dictionary = r.meta.get("consoles", {})
		var con_from := int(con.get("from", r.size()))
		from = mini(from, con_from)
		var aft := 0
		for i in range(con_from, con_from + int(con.get("bricks", 0))):
			if r.cell_of(i).x <= m.seat.x:
				aft += 1
		if int(m.stats.get("consoles", 0)) < 8 or aft > 0:
			bad.append("seed %d: %d console column(s), %d brick(s) not fore of the seat" % [sd,
					int(m.stats.get("consoles", 0)), aft])
		for i in r.size():
			var c := r.cell_of(i)
			var s := BuildRecipe.part_size(r.part_of(i))
			for y in s.y:
				for z in s.z:
					for x in s.x:
						cells[c + Vector3i(x, y, z)] = true
						if i >= from:
							inner[c + Vector3i(x, y, z)] = true
		# Furnished, its doorways and the cells beside them clear.
		var blocked := 0
		for dr: Dictionary in BuildDoors.of(r):
			var lo: Vector3i = dr.lo
			var ds: Vector3i = dr.size
			for z in range(lo.z - 1, lo.z + ds.z + 1):
				for x in range(lo.x - 1, lo.x + ds.x + 1):
					if inner.has(Vector3i(x, lo.y, z)):
						blocked += 1
		if int(m.stats.get("furniture", 0)) < 10 or blocked > 0 or BuildSections.of_build(r).size() != r.size():
			bad.append("seed %d: %d item(s), %d cell(s) by a door taken, sections of %d of %d bricks" % [sd,
					int(m.stats.get("furniture", 0)), blocked, BuildSections.of_build(r).size(), r.size()])
		items.append("%d+%d" % [int(m.stats.get("furniture", 0)), int(m.stats.get("consoles", 0))])
		wins.append(int(m.stats.get("windows", 0)))
		if int(m.stats.get("windows", 0)) < 4:
			bad.append("seed %d: %d window(s)" % [sd, int(m.stats.get("windows", 0))])
		var seat: Vector3i = m.seat
		if seat.x < 0 or cells.has(seat) or cells.has(seat + Vector3i(0, 3, 0)) or not cells.has(seat - Vector3i(0, 1, 0)):
			bad.append("seed %d: seat %s not on a floor" % [sd, str(seat)])
		elif float(seat.x) < size.x * 0.6:
			bad.append("seed %d: bridge at %d of %d, not fore" % [sd, seat.x, size.x])
		var engine_x := -1.0
		for pl: Dictionary in m.plan.placed:
			if String(m.lib[pl.m].name) == "engine room":
				engine_x = float((pl.off as Vector3i).x)
		if engine_x < 0 or engine_x > size.x / 3.0:
			bad.append("seed %d: engine room at %.0f of %d" % [sd, engine_x, size.x])
		# Two engine housings on the roof aft, their backs out past the stern.
		var eng: Array = r.meta.get("engines", [])
		var housed := eng.size() == 2
		for e: Array in eng:
			var back := Vector3i(int(e[0]), int(e[1]), int(e[2]))
			housed = housed and back.x < 0 and cells.has(back) and cells.has(back + Vector3i(4, 0, 0))
		if not housed:
			bad.append("seed %d: engines %s" % [sd, str(eng)])
		# Laid with its floor the foundation and its decks anchors: nothing loose
		# (the housings, the fin and the wings hold by their studs).
		var ch := w.create_chunk(Vector3i.ZERO, r.chunk_dims())
		r.build(w, ch, pal)
		w.set_foundation_level(ch, 0)
		var rows := PackedInt32Array()
		for s in range(1, int(m.decks)):
			rows.append(s * ShipBuild.PITCH)
		if not rows.is_empty():
			w.set_anchor_levels(ch, rows)
		var loose: Array = w.find_detached_groups(ch)
		# Every door under a lintel (BuildDoors hangs none without one).
		var bare := 0
		for dr: Dictionary in BuildDoors.of(r):
			if not w.is_solid(ch, (dr.lo as Vector3i) + Vector3i(0, (dr.size as Vector3i).y, 0) - r.origin()):
				bare += 1
		if bare > 0 or BuildDoors.of(r).is_empty():
			bad.append("seed %d: %d of %d door(s) without a lintel" % [sd, bare, BuildDoors.of(r).size()])
		w.release_chunk(ch)
		if not loose.is_empty():
			bad.append("seed %d: %d loose group(s)" % [sd, loose.size()])
		var lock: Vector3i = m.stats.airlock
		if lock.x < 0 or cells.has(lock) or cells.has(lock + Vector3i(0, 0, 1)) or cells.has(lock + Vector3i(1, 0, 0)):
			bad.append("seed %d: no airlock open at %s" % [sd, str(lock)])
		if int(m.decks) < 1 or int(m.decks) > 3 or float(m.stats.fill) < 0.7 \
				or (r.meta.sections.sections as Array).size() < 2:
			bad.append("seed %d: %d deck(s), fill %.2f, %d section(s)" % [sd, m.decks, m.stats.fill,
					(r.meta.sections.sections as Array).size()])
	_ok("8 seeds: hulls of 1-3 decks, the bridge's seat on its floor fore, the engine room aft, an airlock aft onto the spine, mostly rooms, sections, engine housings, furnished with its doorways clear, windows, nothing loose, every door under a lintel",
			bad.is_empty(), "fill %s, items %s, windows %s %s" % [str(fills), str(items), str(wins), str(bad.slice(0, 4))])

	var d := OrbitalData.new()
	d.kind = "ship"
	d.layout = "generated"
	d.orbital_name = "probe ship"
	d.orbital_seed = 7
	var ship := SpaceShip.new()
	root.add_child(ship)
	ship.setup_ship(d)
	ship.drifted.connect(func(_a, _c, _l, count: int, _m) -> void: _drifts.append(count))
	var seat := ship.seat()
	var hull: BoxShape3D = ship._hull
	_ok("a generated SpaceShip: grown at setup, its seat the bridge's forward of the middle, its hull long along Z",
			ship.recipe != null and seat.z < 0.0 and absf(seat.x) < hull.size.x * 0.5 and seat.y > 0.0
			and seat.y < ship.height and hull.size.z > hull.size.x,
			"seat %s, hull %s, %d bricks, grown in %.0f ms" % [str(seat), str(hull.size),
				ship.recipe.size() if ship.recipe else 0, ship.grow_ms])
	if ship.recipe == null:
		return
	ship.activate()
	_ship = ship


func _after_laid() -> void:
	var ship := _ship
	var r := ship.recipe
	var alive := ship.bricks.get_alive_block_count(ship.chunk)
	var loose: Array = ship.bricks.find_detached_groups(ship.chunk)
	_ok("laid frame by frame: every brick, nothing loose (its floor and decks its anchors)",
			ship.bricked and alive == r.size() and loose.is_empty(),
			"%d frame(s), %d of %d alive, %d loose group(s), %d joint(s)" % [_frames, alive, r.size(), loose.size(),
				ship.joints.size()])
	# The bulkhead behind the bridge's section (0) shot to under a third.
	var joint: Dictionary = {}
	for j: Dictionary in ship.joints:
		if int(j.a) == 0 or int(j.b) == 0:
			joint = j
	var of := BuildSections.of_build(r)
	var root_n := 0
	for s in of:
		if s == 0:
			root_n += 1
	var killed := PackedInt32Array()
	if not joint.is_empty():
		var ids: PackedInt32Array = joint.ids
		for k in int(ids.size() * 0.75):
			killed.append(ids[k])
		ship.bricks.kill_blocks(ship.chunk, killed)
		ship._after_kill(killed)
		ship._solve()
	var biggest := 0
	for n: int in _drifts:
		biggest = maxi(biggest, n)
	# What lies beyond that joint: the sections the bridge's no longer reaches.
	var adj := {}
	for j: Dictionary in ship.joints:
		if j == joint:
			continue
		for pr in [[int(j.a), int(j.b)], [int(j.b), int(j.a)]]:
			if not adj.has(pr[0]):
				adj[pr[0]] = []
			adj[pr[0]].append(pr[1])
	var reach := {0: true}
	var todo := [0]
	while not todo.is_empty():
		var a: int = todo.pop_back()
		for b in adj.get(a, []):
			if not reach.has(b):
				reach[b] = true
				todo.append(b)
	var rest := 0
	for s in of:
		if not reach.has(s):
			rest += 1
	var bridge_floor := ship.bricks.block_at(ship.chunk, ship.seat_cell - Vector3i(0, 1, 0))
	_ok("a bulkhead of the bridge's section shot through: the part beyond drifts off whole, the bridge stays",
			not joint.is_empty() and rest > 0 and biggest >= (rest - killed.size()) * 0.9 and bridge_floor >= 0
			and ship.bricks.get_alive_block_count(ship.chunk) >= root_n * 0.6,
			"%d of %d joint bricks killed, drifted %s of %d beyond it, %d left (bridge's section %d)" % [killed.size(),
				int(joint.get("n", 0)), str(_drifts), rest, ship.bricks.get_alive_block_count(ship.chunk), root_n])
	ship.deactivate()
	ship.queue_free()
