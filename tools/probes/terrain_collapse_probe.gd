extends SceneTree

## TerrainCollapse.survey, headless (Docs/TerrainCollapse.md).
##
##     godot --headless --path . --script res://tools/probes/terrain_collapse_probe.gd
##
## What each check is for:
##
##   * flat shot: a brick shot out of level ground leaves nothing hanging, so
##     the survey must not solve (the cheap path almost every shot takes) and
##     nothing falls.
##   * floating block: a block with nothing under or round it is joined to
##     nothing -- one loose group, exactly its cells.
##   * pillar and arm: a stone arm on a pillar is held (tension at the game's
##     stud strength); the pillar's foot shot out lets pillar and arm go as
##     one group, and nothing of the ground with them.
##   * tension: the same arm with studs nearly without strength breaks off
##     where it hangs -- the stress solve runs, not only the grounding.
##   * bond by material: at one strength a dirt arm (2x2 bond, single-stud
##     laps) lets go where a stone arm (2x4 bond) of the same shape holds.
##   * sand: a sand block in the air falls as columns, never as a piece;
##     sand standing on the ground stays; a stack of sand falls together.
##   * cost: the flat shot's and the arm's survey times, the worker's budget.

const MASS := 0.1   # BrickPalette.MASS_PER_CELL

var failures := 0
var tension := 37.2
var base := Vector3i.ZERO   # a flat spot: its x, ground top plate, z


func _initialize() -> void:
	BrickTerrain.configure(424242)
	BrickTerrain.set_generator(1)
	BrickTerrain.reset_gen_params()
	BrickTerrain.set_smooth_terrain(false)
	BrickTerrain.set_plate_steps(false)
	# The mine world's top course: laid on the ground's bond (Docs/TerrainBond.md).
	BrickTerrain.set_bond_top(true)
	# The ground's strength, as the mine world asks (ground_collapse.gd).
	tension = BrickStrength.tension() * float(load("res://scripts/terrain/ground_collapse.gd").TERRAIN_TIMES)
	if not _find_flat():
		_expect(false, "found a flat spot to build on")
	else:
		_check_flat_shot()
		_check_floating_block()
		_check_pillar_arm()
		_check_tension()
		_check_bond()
		_check_big_island()
		_check_cache()
		_check_roof()
		_check_real_caves()
		_check_sand()
	BrickTerrain.clear_terrain_edits()
	BrickTerrain.set_generator(0)
	BrickTerrain.set_bond_top(false)
	print("[collapse] %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		failures += 1


## Top solid plate of a column, scanning down from high up.
func _top(x: int, z: int) -> int:
	var yp := BrickTerrain.surface_plate(x, z) + 12
	while yp > -400 and BrickTerrain.solid_at(x, yp, z) == 0:
		yp -= 1
	return yp


## 28 x 28 studs whose tops are all one plate, nothing over them.
func _find_flat() -> bool:
	for i in 400:
		var x := (i % 20) * 97 - 900
		var z := int(i / 20.0) * 89 - 900
		var t := _top(x, z)
		var flat := true
		for dz in range(-14, 14, 3):
			for dx in range(-14, 14, 3):
				if _top(x + dx, z + dz) != t:
					flat = false
					break
			if not flat:
				break
		# Whole bricks: the top is a brick's last plate.
		if flat and (t + 1) % 3 == 0:
			base = Vector3i(x, t, z)
			print("  flat spot at %s" % base)
			return true
	return false


func _fill(lo: Vector3i, hi: Vector3i, mat: int) -> void:
	BrickTerrain.fill_box(base + lo, base + hi, mat, false)


func _survey(lo: Vector3i, hi: Vector3i, t := -1.0) -> Dictionary:
	return TerrainCollapse.survey(base + lo, base + hi, tension if t < 0.0 else t, MASS)


## Cells a group's bricks cover.
func _cells(g: PackedInt32Array) -> int:
	var n := 0
	for i in range(0, g.size(), 6):
		n += g[i + 3] * g[i + 4]
	return n


func _all_cells(r: Dictionary) -> int:
	var n := 0
	for g in r.groups:
		n += _cells(g)
	return n


## Any brick of the groups at or under the ground's top plate.
func _ground_in(r: Dictionary) -> bool:
	for g in r.groups:
		var p: PackedInt32Array = g
		for i in range(0, p.size(), 6):
			if p[i + 1] <= base.y:
				return true
	return false


func _check_flat_shot() -> void:
	BrickTerrain.clear_terrain_edits()
	# The top brick of one column, as a wall hit takes it.
	var lo := Vector3i(0, -2, 0)
	_fill(lo, Vector3i(0, 0, 0), 0)
	var t0 := Time.get_ticks_usec()
	var r := _survey(lo, Vector3i(0, 0, 0))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_expect(not bool(r.solved), "flat shot: nothing hangs, no solve")
	_expect((r.groups as Array).is_empty() and (r.sand as PackedInt32Array).is_empty(),
			"flat shot: nothing falls")
	print("    flat shot survey %.2f ms (sample %.2f)" % [ms, float(r.sample_ms)])


func _check_floating_block() -> void:
	BrickTerrain.clear_terrain_edits()
	var lo := Vector3i(2, 10, 2)
	var hi := Vector3i(3, 12, 3)
	_fill(lo, hi, 4)  # stone, a 2x2 block four bricks over the ground
	# Laid as the builder lays one: ONE brick (Docs/TerrainBond.md 1).
	BrickTerrain.mark_placed(base + lo, base + hi, 4)
	var r := _survey(lo, hi)
	_expect(bool(r.solved), "floating block: solved")
	_expect((r.groups as Array).size() == 1 and _all_cells(r) == 4,
			"floating block: one group of its 4 cells (%d groups, %d cells)" % [(r.groups as Array).size(), _all_cells(r)])
	_expect(not _ground_in(r), "floating block: no ground with it")


## A 2x2 stone pillar 6 bricks tall, an arm 2 bricks thick (one course
## alone is bricks side by side, joined to nothing: the LEGO rule), 2 wide, `reach`
## studs out along +X from its top.
func _build_arm(reach: int, mat: int) -> Array:
	BrickTerrain.clear_terrain_edits()
	_fill(Vector3i(0, 1, 0), Vector3i(1, 18, 1), 4)
	_fill(Vector3i(2, 13, 0), Vector3i(1 + reach, 18, 1), mat)
	return [Vector3i(0, 1, 0), Vector3i(1 + reach, 18, 1)]


func _check_pillar_arm() -> void:
	var box := _build_arm(8, 4)
	var t0 := Time.get_ticks_usec()
	var r := _survey(box[0], box[1])
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_expect(bool(r.solved), "arm: solved (it hangs)")
	_expect((r.groups as Array).is_empty(), "arm: held at stud strength %.1f (%d groups)" % [tension, (r.groups as Array).size()])
	print("    arm survey %.2f ms (sample %.2f, solve %.2f = tops %.2f + bond %.2f + world %.2f, %d bricks)" % [
			ms, float(r.sample_ms), float(r.solve_ms), float(r.get("tops_ms", 0.0)), float(r.get("bond_ms", 0.0)),
			float(r.get("world_ms", 0.0)), int(r.bricks)])
	# The pillar's foot shot out.
	_fill(Vector3i(0, 1, 0), Vector3i(1, 3, 1), 0)
	r = _survey(Vector3i(0, 1, 0), Vector3i(1, 3, 1))
	var want := 2 * 2 * 5 + 2 * 8 * 2
	_expect((r.groups as Array).size() == 1 and _all_cells(r) == want,
			"foot shot out: pillar and arm one group (%d groups, %d cells, want %d)" % [(r.groups as Array).size(), _all_cells(r), want])
	_expect(not _ground_in(r), "foot shot out: no ground with it")


func _check_tension() -> void:
	var box := _build_arm(8, 4)
	var r := _survey(box[0], box[1], 0.001)
	_expect(not (r.groups as Array).is_empty(), "weak studs: the arm breaks off (%d groups, %d cells)" % [(r.groups as Array).size(), _all_cells(r)])
	_expect(not _ground_in(r), "weak studs: no ground with it")


## The lowest strength that holds an arm of `mat`, by halving.
func _holds_at(reach: int, mat: int) -> float:
	var box := _build_arm(reach, mat)
	var lo := 0.0001
	var hi := 400.0
	for i in 22:
		var mid := sqrt(lo * hi)
		var r := _survey(box[0], box[1], mid)
		if (r.groups as Array).is_empty():
			hi = mid
		else:
			lo = mid
	return hi


func _check_bond() -> void:
	var stone := _holds_at(10, 4)   # MAT_STONE
	var dirt := _holds_at(10, 2)    # MAT_DIRT
	print("    a 10-stud arm holds from: stone %.3f, dirt %.3f a stud" % [stone, dirt])
	_expect(dirt > stone, "bond: a dirt arm needs stronger studs than a stone one")


## An arm 40 studs long -- past the region a survey starts with -- on its
## pillar: the foot shot out, all of it comes loose as ONE group (the region
## grows to it; it used to read as held at the region's edge).
func _check_big_island() -> void:
	var box := _build_arm(40, 4)
	var r := _survey(box[0], box[1])
	_expect((r.groups as Array).is_empty(), "long arm: held while its pillar stands")
	_fill(Vector3i(0, 1, 0), Vector3i(1, 3, 1), 0)
	var t0 := Time.get_ticks_usec()
	r = _survey(Vector3i(0, 1, 0), Vector3i(1, 3, 1))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var want := 2 * 2 * 5 + 2 * 40 * 2
	_expect((r.groups as Array).size() == 1 and _all_cells(r) == want,
			"long arm: foot shot out, one group of all of it (%d groups, %d cells, want %d, region grown %d times)" % [
			(r.groups as Array).size(), _all_cells(r), want, int(r.grown)])
	print("    long arm survey %.1f ms (%d bricks; tops %.1f, bond %.1f, world %.1f)" % [ms, int(r.bricks),
			float(r.get("tops_ms", 0.0)), float(r.get("bond_ms", 0.0)), float(r.get("world_ms", 0.0))])


## The same survey again, nothing edited: the tiles' top course comes from
## the cache (TerrainCollapse's tile versions), not packed again -- packing it
## was 97% of a survey.
func _check_cache() -> void:
	var box := _build_arm(8, 4)
	var r1 := _survey(box[0], box[1])
	var t0 := Time.get_ticks_usec()
	var r2 := _survey(box[0], box[1])
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_expect(int(r2.get("tiles_packed", -1)) == 0 and (r2.groups as Array).size() == (r1.groups as Array).size(),
			"survey again, nothing changed: no tile packed (%d), same answer; %.1f ms against %.1f" % [
			int(r2.get("tiles_packed", -1)), ms, float(r1.get("tops_ms", 0.0)) + float(r1.get("bond_ms", 0.0))])


## A stone cave roof (Docs/TerrainCollapse.md 8.2): a tunnel `span` studs wide
## and 3 bricks tall dug under 4 bricks of stone, one brick shot out of its
## middle. The lowest stud strength at which the roof stands.
func _roof_holds_at(span: int) -> float:
	BrickTerrain.clear_terrain_edits()
	# Solid stone over the flat spot, 7 bricks tall, then the tunnel dug.
	var w := span + 16
	_fill(Vector3i(-w / 2, 1, -10), Vector3i(w / 2, 21, 10), 4)
	_fill(Vector3i(-span / 2, 1, -6), Vector3i(span / 2 - 1, 9, 6), 0)
	# The shot: one brick of the roof's underside, mid-span.
	_fill(Vector3i(0, 10, 0), Vector3i(0, 12, 0), 0)
	var lo := 0.01
	var hi := 2000.0
	for i in 18:
		var mid := sqrt(lo * hi)
		var r := _survey(Vector3i(0, 10, 0), Vector3i(0, 12, 0), mid)
		if (r.groups as Array).is_empty():
			hi = mid
		else:
			lo = mid
	return hi


func _check_roof() -> void:
	var line := ""
	for span in [6, 12, 20]:
		line += "%d studs: %.1f  " % [span, _roof_holds_at(span)]
	print("    a stone cave roof with one brick shot out stands from (stud strength): %s(the ground's: %.1f)" % [line, tension])
	var at12 := _roof_holds_at(12)
	_expect(at12 <= tension, "a 12-stud stone cave roof stands after one brick is shot (needs %.1f, has %.1f)" % [at12, tension])


## Generated cave ceilings (the default world), one brick shot out of each:
## what comes down, at the game's stud strength and at a strength nothing
## fails at -- a group at both is joined to nothing (grounding), one at the
## game's only is the stress solve. The user saw whole ceilings fall from one
## brick (2026-11-20).
func _check_real_caves() -> void:
	for t in [tension]:
		_real_caves_at(t)


func _real_caves_at(tension_now: float) -> void:
	BrickTerrain.clear_terrain_edits()
	var sites := 0
	var fell := 0
	var fell_strong := 0
	var cells_fell := 0
	var worst := 0
	var ms_all := 0.0
	var ms_worst := 0.0
	var notes := []
	for i in 600:
		if sites >= 40:
			break
		var x := (i % 30) * 53 - 800
		var z := int(i / 30.0) * 47 - 700
		var top := BrickTerrain.surface_plate(x, z)
		# Down the column: the first air under solid ground, under the top.
		var yp := top - 6
		var lo := top - 240
		while yp > lo and BrickTerrain.solid_at(x, yp, z) != 0:
			yp -= 1
		if yp <= lo:
			continue
		# A ceiling: solid right over this air, the cell a brick.
		var ceil := yp + 1
		var b := int(floor(ceil / 3.0))
		var m := BrickTerrain.solid_at(x, b * 3, z)
		if m == 0 or TerrainCollapse.material_class(m) == 1:
			continue
		sites += 1
		BrickTerrain.clear_terrain_edits()
		var c_lo := Vector3i(x, b * 3, z)
		var c_hi := Vector3i(x, b * 3 + 2, z)
		BrickTerrain.fill_box(c_lo, c_hi, 0, false)
		var t0 := Time.get_ticks_usec()
		var r := TerrainCollapse.survey(c_lo, c_hi, tension_now, MASS)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		ms_all += ms
		ms_worst = maxf(ms_worst, ms)
		var strong := TerrainCollapse.survey(c_lo, c_hi, 1.0e6, MASS)
		var n := _all_cells(r)
		if n > 0:
			fell += 1
			cells_fell += n
			worst = maxi(worst, n)
			if notes.size() < 6:
				notes.append("(%d,%d,%d) %s: %d cells in %d groups, strong %d cells, grown %d, %.0f ms" % [
						x, b * 3, z, BrickTerrain.material_names()[m], n, (r.groups as Array).size(),
						_all_cells(strong), int(r.grown), ms])
		if _all_cells(strong) > 0:
			fell_strong += 1
	BrickTerrain.clear_terrain_edits()
	print("    real cave ceilings at stud strength %.0f: %d sites, %d let something go (%d even at unbreakable studs: joined to nothing), %d cells in all, the most %d; survey %.0f ms mean, %.0f worst" % [
			tension_now, sites, fell, fell_strong, cells_fell, worst, ms_all / maxf(sites, 1), ms_worst])
	for n in notes:
		print("      " + n)
	if tension_now == tension:
		_expect(worst < 100, "real cave ceilings: one brick shot out never brings down more than a few bricks (the most %d cells)" % worst)


func _check_sand() -> void:
	BrickTerrain.clear_terrain_edits()
	# Sand on the ground: stays.
	_fill(Vector3i(0, 1, 0), Vector3i(1, 6, 1), 3)   # MAT_SAND, 2 bricks
	var r := _survey(Vector3i(0, 1, 0), Vector3i(1, 6, 1))
	_expect((r.sand as PackedInt32Array).is_empty() and (r.groups as Array).is_empty(),
			"sand on the ground stays")
	# Its bottom brick taken: the brick over it falls, as columns.
	_fill(Vector3i(0, 1, 0), Vector3i(1, 3, 1), 0)
	r = _survey(Vector3i(0, 1, 0), Vector3i(1, 3, 1))
	var cols: PackedInt32Array = r.sand
	@warning_ignore("integer_division")
	_expect(cols.size() / 4 == 4, "undercut sand: 4 columns fall (%d)" % (cols.size() / 4))
	_expect((r.groups as Array).is_empty(), "undercut sand: no piece")
	# A floating sand block, 3 bricks: each column falls whole.
	BrickTerrain.clear_terrain_edits()
	_fill(Vector3i(4, 13, 4), Vector3i(5, 21, 5), 3)
	r = _survey(Vector3i(4, 13, 4), Vector3i(5, 21, 5))
	cols = r.sand
	var whole := cols.size() == 16
	for i in range(0, cols.size(), 4):
		whole = whole and cols[i + 3] == 3
	_expect(whole, "floating sand: 4 columns of 3 cells (%s)" % [cols])
	_expect((r.groups as Array).is_empty(), "floating sand: no piece")
	# Sand under a stone block, both floating: sand falls, the stone is a piece.
	BrickTerrain.clear_terrain_edits()
	_fill(Vector3i(4, 13, 4), Vector3i(5, 15, 5), 3)
	_fill(Vector3i(4, 16, 4), Vector3i(5, 18, 5), 4)
	r = _survey(Vector3i(4, 13, 4), Vector3i(5, 18, 5))
	_expect((r.sand as PackedInt32Array).size() == 16 and _all_cells(r) == 4,
			"sand under stone: sand falls as columns, the stone as a piece")
