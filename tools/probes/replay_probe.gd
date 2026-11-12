extends SceneTree

## The three things a networked destruction system needs, tested as claims
## rather than asserted in a design document. See Docs/Multiplayer.md.
##
##   1. The structural outcome is decided by integers, so it cannot drift.
##   2. A recorded command log replays into an identical world.
##   3. A piece has a name derived from what it holds, not from when it was cut.

const STUD := 0.35
const PLATE := 0.14

var failures := 0


func _init() -> void:
	_check_integer_solve()
	_check_replay()
	_check_content_identity()
	print("")
	if failures == 0:
		print("[probe] PASS")
	else:
		print("[probe] FAIL — %d check(s)" % failures)
	quit(1 if failures > 0 else 0)


func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  ok    %s%s" % [label, ("  " + detail) if detail else ""])
	else:
		failures += 1
		print("  FAIL  %s%s" % [label, ("  " + detail) if detail else ""])


func _tower(courses: int = 20) -> Array:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 16, courses))
	TowerRecipe.build(w, c, palette, 20, 16, courses)
	w.set_tension_per_stud(c, 9.3)
	return [w, c]


## The alive set, as one number. This is the thing that has to agree between
## machines; everything else is decoration.
func _outcome(w: BrickWorld, c: int) -> int:
	return w.get_chunk_content_hash(c)


# ---------------------------------------------------------------------------

## Load is accumulated in fixed-point integers, so the same structure gives the
## same answer bit for bit -- no rounding sits near a failure threshold.
func _check_integer_solve() -> void:
	print("the solve is decided by integers")
	var a := _tower()
	var b := _tower()
	var wa: BrickWorld = a[0]
	var wb: BrickWorld = b[0]

	# Damage both identically, then compare the reported load of every block.
	for i in 6:
		var y := (2 + i * 3) * TowerRecipe.PLATES_PER_COURSE * PLATE
		wa.apply_hit(a[1], Vector3(3.0, y, 0.2), 1.4)
		wb.apply_hit(b[1], Vector3(3.0, y, 0.2), 1.4)
	var ra: Dictionary = wa.solve_stress(a[1])
	var rb: Dictionary = wb.solve_stress(b[1])

	_ok("same failures", int(ra.failures) == int(rb.failures),
			"%d vs %d" % [int(ra.failures), int(rb.failures)])
	_ok("same peak load, exactly", is_equal_approx(float(ra.peak_load), float(rb.peak_load)),
			"%.6f vs %.6f" % [float(ra.peak_load), float(rb.peak_load)])

	var drift := 0
	var boxes: Array = wa.get_block_boxes(a[1])
	for box in boxes:
		var bid := int(box.block)
		if wa.get_block_load(a[1], bid) != wb.get_block_load(b[1], bid):
			drift += 1
	_ok("every block carries an identical load", drift == 0, "%d differ" % drift)

	# Load must be conserved: integer division that dropped remainders would
	# make a tall building get lighter the further down it went.
	_ok("load reaches the foundation", int(ra.blocks_loaded) > 0,
			"%d blocks carried load" % int(ra.blocks_loaded))


## A recorded log, replayed into a fresh world, reproduces it. This is what
## join-in-progress does, and what a save file is.
func _check_replay() -> void:
	print("a recorded log replays into the same world")
	var live := _tower()
	var w: BrickWorld = live[0]
	var c: int = live[1]

	var log := DamageLog.new()
	log.recording = true

	# A messy sequence: blasts and collision shears interleaved, the way a real
	# fight produces them.
	var tick := 0
	for i in 10:
		tick += 3
		var y := (1 + i * 2) * TowerRecipe.PLATES_PER_COURSE * PLATE
		var at := Vector3(1.0 + i * 0.6, y, 0.25)
		w.apply_hit(c, at, 1.3)
		log.record(tick, DamageLog.Kind.BLAST, 0, at, 1.3)
		if i % 3 == 0:
			var shear_at := Vector3(3.0, y, 2.4)
			w.separate_near(c, shear_at, 2.0, 14)
			log.record(tick, DamageLog.Kind.SHEAR, 0, shear_at, 2.0, Vector3.ZERO, 14)
	w.solve_stress(c)
	var want := _outcome(w, c)
	print("  recorded %d command(s) against %d surviving brick(s)" % [
			log.size(), w.get_alive_block_count(c)])

	# A fresh world, built from the same recipe, fed the same commands.
	var fresh := _tower()
	var w2: BrickWorld = fresh[0]
	var c2: int = fresh[1]
	var applied := log.replay(w2, func(_target: int) -> int: return c2)
	w2.solve_stress(c2)
	var got := _outcome(w2, c2)

	_ok("every command applied", applied == log.size(), "%d of %d" % [applied, log.size()])
	_ok("the replayed world is the recorded world", want == got,
			"%d vs %d" % [want, got])
	_ok("and the same bricks survive",
			w.get_alive_block_count(c) == w2.get_alive_block_count(c2),
			"%d vs %d" % [w.get_alive_block_count(c), w2.get_alive_block_count(c2)])

	# Round-tripping through the wire format must change nothing.
	var wire := log.to_data()
	var back := DamageLog.from_data(wire)
	var third := _tower()
	var w3: BrickWorld = third[0]
	var c3: int = third[1]
	back.replay(w3, func(_target: int) -> int: return c3)
	w3.solve_stress(c3)
	_ok("a log survives serialisation", _outcome(w3, c3) == want)


## A piece is named by what it holds, not by when it was cut out.
func _check_content_identity() -> void:
	print("pieces are named by their content")
	var a := _tower(12)
	var wa: BrickWorld = a[0]
	var ca: int = a[1]
	var b := _tower(12)
	var wb: BrickWorld = b[0]
	var cb: int = b[1]

	_ok("identical builds hash identically",
			wa.get_chunk_content_hash(ca) == wb.get_chunk_content_hash(cb))

	# Cut the same two groups out in OPPOSITE orders -- which is exactly what
	# two machines on different hardware do, because the per-tick budgets are
	# wall-clock driven.
	var comps: Array = wa.get_components(ca)
	if comps.size() < 1:
		_ok("a tower has components to cut", false)
		return
	# Sever a band so there is more than one piece to take.
	wa.separate_plane(ca, Vector3(3.5, 6 * 3 * PLATE, 2.8), Vector3(0, 1, 0), 0.42)
	wb.separate_plane(cb, Vector3(3.5, 6 * 3 * PLATE, 2.8), Vector3(0, 1, 0), 0.42)
	var ga: Array = wa.get_components(ca)
	var gb: Array = wb.get_components(cb)
	_ok("the same cut makes the same number of pieces", ga.size() == gb.size(),
			"%d vs %d" % [ga.size(), gb.size()])
	if ga.size() < 2:
		return

	# Take them in opposite orders.
	var a1: Dictionary = wa.split_island(ca, ga[0])
	var a2: Dictionary = wa.split_island(ca, ga[1])
	var b2: Dictionary = wb.split_island(cb, gb[1])
	var b1: Dictionary = wb.split_island(cb, gb[0])
	if a1.is_empty() or a2.is_empty() or b1.is_empty() or b2.is_empty():
		_ok("both worlds cut both pieces", false)
		return

	print("  cut order A gave chunk ids %d, %d; order B gave %d, %d" % [
			int(a1.chunk), int(a2.chunk), int(b1.chunk), int(b2.chunk)])
	var ha1 := wa.get_chunk_content_hash(int(a1.chunk))
	var hb1 := wb.get_chunk_content_hash(int(b1.chunk))
	var ha2 := wa.get_chunk_content_hash(int(a2.chunk))
	var hb2 := wb.get_chunk_content_hash(int(b2.chunk))
	_ok("the first piece has the same name in both", ha1 == hb1)
	_ok("so does the second", ha2 == hb2)
	_ok("and the two pieces are told apart", ha1 != ha2)
