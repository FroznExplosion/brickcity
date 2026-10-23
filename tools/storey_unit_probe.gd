extends SceneTree

## Storey units (Docs/Space.md 5.3a): a tower laid a storey at a time from its
## template, its block ids the whole building's, its damage record carried by
## the storeys not laid, each run of laid storeys standing on the intact ones
## under it and carrying the ones over it.
##
##     godot --headless --path . --script tools/storey_unit_probe.gd

const FX := 80
const FZ := 60
const COURSES := 204   ## the big city's biggest tower (CityScene.BIG_SHAPES)

var _pass := 0
var _fail := 0


func _init() -> void:
	_check_ids_and_cost()
	_check_record_round_trip()
	_check_record_rides_absent()
	_check_anchors_and_loads()
	_check_give_way()
	_check_piece_runs()
	_check_tip()
	_check_unlay()
	_check_build()
	_check_window()
	print("\n[storey_unit] %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ok    " + what)
	else:
		_fail += 1
		print("  FAIL  " + what)


func _make(units: bool) -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	reg.storey_units = units
	var id := reg.register(FX, FZ, COURSES, Transform3D())
	reg.prepare_templates()
	return [w, reg, id]


## Every cell of storey `s`: which block holds it.
func _cells_of(w: BrickWorld, chunk: int, lo: int, hi: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for y in range(lo, hi):
		for z in FZ:
			for x in FX:
				out.append(w.block_at(chunk, Vector3i(x, y, z)))
	return out


func _check_ids_and_cost() -> void:
	print("\n=== a storey laid from the template keeps the whole building's ids ===")
	var whole := _make(false)
	var ww: BrickWorld = whole[0]
	var wreg: BuildingRegistry = whole[1]
	var t0 := Time.get_ticks_usec()
	var wc := wreg.materialise(whole[2])
	var whole_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var whole_bricks := ww.get_alive_block_count(wc)
	var whole_occ := ww.get_occupancy_bytes(wc)

	var part := _make(true)
	var pw: BrickWorld = part[0]
	var preg: BuildingRegistry = part[1]
	var mid := preg.storey_count(part[2]) / 2
	t0 = Time.get_ticks_usec()
	var pc := preg.materialise(part[2], PackedInt32Array([mid]))
	var part_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var rep := preg.storey_report(part[2])
	print("  whole: %d bricks, %.1f ms, occupancy %.1f MB" % [whole_bricks, whole_ms,
			whole_occ / 1048576.0])
	print("  storey %d of %d: %d bricks, %.1f ms, occupancy %.2f MB" % [mid, int(rep.of),
			int(rep.bricks), part_ms, int(rep.occupancy_bytes) / 1048576.0])
	_ok(pw.get_block_count(pc) == ww.get_block_count(wc),
			"the band chunk holds every id (%d)" % pw.get_block_count(pc))
	_ok(int(rep.bricks) > 300 and int(rep.bricks) < 2000,
			"one storey is a few hundred bricks, not the building (%d)" % int(rep.bricks))
	_ok(int(rep.occupancy_bytes) * 10 < whole_occ, "its grid is a tenth of the whole's or less")
	var lines := preg.storey_lines(preg.get_building(part[2]))
	var a := _cells_of(ww, wc, lines[mid], lines[mid + 1])
	var b := _cells_of(pw, pc, lines[mid], lines[mid + 1])
	_ok(a == b, "every cell of the storey holds the same block id as in the whole building")
	var outside := _cells_of(pw, pc, lines[mid + 1], lines[mid + 1] + 1)
	var empty := true
	for v in outside:
		if v >= 0:
			empty = false
	_ok(empty, "the storey over it reads empty")
	print("  [storey_unit] first lay: whole %.1f ms, one storey %.1f ms" % [whole_ms, part_ms])


func _check_record_round_trip() -> void:
	print("\n=== a hit on a storey, given back, laid again whole: the same hole ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var id: int = part[2]
	var lines := reg.storey_lines(reg.get_building(id))
	var s := 12
	var cell := BrickWorld.get_cell_size()
	var point := Vector3(10.0 * cell.x, (lines[s] + 10) * cell.y, 0.3)
	var killed := reg.damage(id, point, 1.0)
	var b := reg.get_building(id)
	_ok(b.banded and b.storeys_laid == PackedInt32Array([s]),
			"damage() laid the storey it reached and no other (%s)" % str(b.storeys_laid))
	_ok(killed.size() > 0, "and killed %d blocks in it" % killed.size())
	var dead_before := w.get_dead_blocks(b.chunk)
	reg.dematerialise(id)
	reg.storey_units = false
	var c := reg.materialise(id)
	var dead_after := w.get_dead_blocks(c)
	_ok(not reg.get_building(id).banded, "laid whole the second time")
	_ok(dead_after == dead_before, "the record replays into the whole building (%d dead)"
			% dead_after.size())


func _check_record_rides_absent() -> void:
	print("\n=== damage on a storey that is not laid survives a materialisation without it ===")
	var whole := _make(false)
	var w: BrickWorld = whole[0]
	var reg: BuildingRegistry = whole[1]
	var id: int = whole[2]
	var lines := reg.storey_lines(reg.get_building(id))
	var cell := BrickWorld.get_cell_size()
	var c := reg.materialise(id)
	reg.damage(id, Vector3(12.0 * cell.x, (lines[20] + 8) * cell.y, 0.3), 1.6)
	var dead0 := w.get_dead_blocks(c)
	var alive0 := w.get_alive_block_count(c)
	w.set_worn_blocks(c, PackedInt32Array([5, 77]))
	var worn0 := w.get_worn_blocks(c)
	reg.dematerialise(id)
	reg.storey_units = true
	var pc := reg.materialise(id, PackedInt32Array([8]))
	_ok(w.get_dead_blocks(pc) == dead0, "the band chunk reports storey 20's dead though it is absent")
	_ok(w.get_worn_blocks(pc) == worn0, "and the wear on an absent block")
	reg.dematerialise(id)
	reg.storey_units = false
	var c2 := reg.materialise(id)
	_ok(w.get_dead_blocks(c2) == dead0 and w.get_alive_block_count(c2) == alive0,
			"laid whole again: the same %d dead, %d standing" % [dead0.size(), alive0])
	# And a storey laid later comes in with its damage.
	reg.dematerialise(id)
	reg.storey_units = true
	var pc2 := reg.materialise(id, PackedInt32Array([8]))
	var before := w.get_alive_block_count(pc2)
	reg.lay_storeys(id, PackedInt32Array([20]))
	var laid := w.get_block_count(pc2) - w.get_absent_count(pc2)
	var came := w.get_alive_block_count(pc2) - before
	var dead_in := 0
	var dead_set := {}
	for d in dead0:
		dead_set[d] = true
	for d in w.get_dead_blocks(pc2):
		if dead_set.has(d):
			dead_in += 1
	_ok(dead_in == dead0.size(), "storey 20 laid later: its %d dead are dead (%d laid, %d alive came in)"
			% [dead0.size(), laid, came])


func _check_anchors_and_loads() -> void:
	print("\n=== each run stands on the storey under it and carries the ones over it ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var id: int = part[2]
	var c := reg.materialise(id, PackedInt32Array([10, 11]))
	reg.lay_storeys(id, PackedInt32Array([25]))
	var groups := w.find_detached_groups(c)
	_ok(groups.is_empty(), "two runs, nothing detached (%d groups)" % groups.size())
	var lines := reg.storey_lines(reg.get_building(id))
	var top := w.get_blocks_topping(c, lines[12])
	var load := w.get_external_load(c, top[0]) if not top.is_empty() else 0.0
	_ok(top.size() > 10 and load > 0.0, "storey 11's %d top bricks carry %.2f kg each" % [top.size(), load])
	var stress: Dictionary = w.solve_stress(c)
	_ok(int(stress.get("failures", 0)) == 0, "and the stress solve breaks nothing (%d)"
			% int(stress.get("failures", 0)))
	w.set_anchor_levels(c, PackedInt32Array())
	groups = w.find_detached_groups(c)
	_ok(not groups.is_empty(), "without its anchor storey 25 hangs on nothing (%d group(s))" % groups.size())


func _check_give_way() -> void:
	print("\n=== a storey with nothing left under the one over it gives way ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var id: int = part[2]
	var c := reg.materialise(id, PackedInt32Array([14]))
	var lines := reg.storey_lines(reg.get_building(id))
	_ok(reg.storey_gave_way(id) == -1, "standing: nothing gave way")
	w.kill_blocks(c, w.get_blocks_topping(c, lines[15]))
	_ok(reg.storey_gave_way(id) == 15, "its top bricks gone: storey 15 up gave way (%d)"
			% reg.storey_gave_way(id))
	reg.cut_storeys(id, 15)
	reg.dematerialise(id)
	var b := reg.get_building(id)
	var gone := 0
	for i in b.damage_profile:
		var m: PackedInt32Array = b.damage_profile[i]
		if BuildingShell._band_is_gone(m):
			gone += 1
	_ok(gone > 100, "given back: the profile has every band from storey 15 up gone (%d)" % gone)
	reg.storey_units = false
	var c2 := reg.materialise(id)
	var rep := reg.storey_report(id)
	_ok(b.banded and not (rep.laid as PackedInt32Array).has(15),
			"laid again it is still laid a storey at a time, without the storeys that left (%s)"
			% str(rep.laid).left(40))
	_ok(w.get_alive_block_count(c2) < 15000, "and holds only what is left (%d)" % w.get_alive_block_count(c2))


## A shell piece made bricks is laid a run of storeys a lay_band
## (BuildingRegistry._lay_runs), not a storey a call: each call that reached
## past the grid's window built the grid again for every brick laid so far --
## 68.5 ms for a 34-storey piece in a blast's tick. Asked here: the same
## bricks, the same absent ones and the same grid as a storey a call, with a
## hole in the run; the time of each printed.
func _check_piece_runs() -> void:
	print("\n=== a shell piece is laid a run of storeys a call: the same bricks as a storey a call ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var id: int = part[2]
	var b := reg.get_building(id)
	reg.materialise(id, PackedInt32Array([14]))
	var lines := reg.storey_lines(b)
	var n := lines.size() - 1
	var holes := PackedInt32Array([20, 21])
	var t0 := Time.get_ticks_usec()
	var runs := reg.shell_piece_chunk(id, 15, n, holes, Transform3D())
	var t1 := Time.get_ticks_usec()
	var tid := reg._template_of(b)
	var one := w.create_band_chunk(tid)
	for s in range(15, n):
		if not holes.has(s):
			w.lay_band(one, tid, lines[s], lines[s + 1])
	var t2 := Time.get_ticks_usec()
	print("    storeys 15-%d less %s: a run a call %.1f ms, a storey a call %.1f ms" % [
			n - 1, str(holes), (t1 - t0) / 1000.0, (t2 - t1) / 1000.0])
	_ok(runs >= 0 and one >= 0 and w.get_alive_block_count(runs) == w.get_alive_block_count(one)
			and w.get_alive_block_count(runs) > 0,
			"as many bricks alive (%d, %d)" % [w.get_alive_block_count(runs), w.get_alive_block_count(one)])
	var absent_differ := 0
	for i in w.get_block_count(one):
		if w.is_block_absent(runs, i) != w.is_block_absent(one, i):
			absent_differ += 1
	_ok(w.get_block_count(runs) == w.get_block_count(one) and absent_differ == 0,
			"the same blocks absent: the holes and everything under storey 15 (%d differ)" % absent_differ)
	_ok(_cells_of(w, runs, lines[19], lines[23]) == _cells_of(w, one, lines[19], lines[23])
			and _cells_of(w, runs, lines[n - 1], lines[n]) == _cells_of(w, one, lines[n - 1], lines[n]),
			"the same grid round the hole and in the top storey")


func _check_window() -> void:
	print("\n=== nothing can be put where nothing is laid ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var c := reg.materialise(part[2], PackedInt32Array([5]))
	var palette: Dictionary = reg.palette
	var lines := reg.storey_lines(reg.get_building(part[2]))
	var outside := w.place_block(c, Vector3i(35, lines[20] + 5, 35), palette.brick_2x2, 4)
	_ok(outside < 0, "placing in an absent storey fails (%d)" % outside)
	var inside := w.place_block(c, Vector3i(35, lines[5] + 10, 35), palette.brick_2x2, 4)
	_ok(inside >= w.get_block_count(c) - 1 and w.is_block_absent(c, inside) == false,
			"placing inside the laid one goes on the end, present (%d)" % inside)


func _check_tip() -> void:
	print("
=== what is left carries the storey over it off to one side: it tips ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var id: int = part[2]
	var c := reg.materialise(id, PackedInt32Array([14]))
	var lines := reg.storey_lines(reg.get_building(id))
	# One corner gone: the rest still stands round the weight.
	var corner := PackedInt32Array()
	var half := PackedInt32Array()
	for bid in w.get_blocks_topping(c, lines[15]):
		var fp := w.get_blocks_footprint(c, PackedInt32Array([bid]))
		if fp[0].x < FX * 0.25 and fp[0].y < FZ * 0.25:
			corner.append(bid)
		if fp[0].x < FX * 0.6:
			half.append(bid)
	w.kill_blocks(c, corner)
	_ok(reg.storey_gave_way(id) == -1, "a corner gone: it stands (%d)" % reg.storey_gave_way(id))
	w.kill_blocks(c, half)
	var s := reg.storey_gave_way(id)
	_ok(s == 15 and reg.gave_way_tipping, "the west three fifths gone: storey 15 up tips (%d, tipping %s)"
			% [s, reg.gave_way_tipping])


func _check_unlay() -> void:
	print("
=== a storey given back keeps its damage, and comes back with it ===")
	var part := _make(true)
	var w: BrickWorld = part[0]
	var reg: BuildingRegistry = part[1]
	var id: int = part[2]
	var c := reg.materialise(id, PackedInt32Array([10, 11]))
	var lines := reg.storey_lines(reg.get_building(id))
	var cell := BrickWorld.get_cell_size()
	reg.damage(id, Vector3(20.0 * cell.x, (lines[11] + 10) * cell.y, 0.3), 1.0)
	var dead := w.get_dead_blocks(c)
	var alive := w.get_alive_block_count(c)
	var occ := w.get_occupancy_bytes(c)
	var gone := reg.unlay_storeys(id, PackedInt32Array([11]))
	var b := reg.get_building(id)
	_ok(gone > 300 and b.storeys_laid == PackedInt32Array([10]),
			"storey 11 given back: %d blocks, %s laid" % [gone, str(b.storeys_laid)])
	_ok(w.get_dead_blocks(c) == dead, "its dead are still in the record (%d)" % dead.size())
	_ok(w.find_detached_groups(c).is_empty(), "and storey 10 still stands")
	var profile_gone := 0
	for i in b.damage_profile:
		profile_gone += 1
	_ok(profile_gone > 0, "the shell draws its damage (%d band(s) in the profile)" % profile_gone)
	reg.lay_storeys(id, PackedInt32Array([11]))
	_ok(w.get_dead_blocks(c) == dead and w.get_alive_block_count(c) == alive,
			"laid again: the same %d dead, %d standing" % [dead.size(), alive])


func _watchtower(units: bool) -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	reg.storey_units = units
	var r := BuildRecipe.from_dict(JSON.parse_string(
			FileAccess.get_file_as_string("res://builds/watchtower.json")))
	var id := reg.register_build(r, Transform3D())
	return [w, reg, id]


func _check_build() -> void:
	print("
=== a build is laid a storey at a time too, cut at the floors the finder finds ===")
	var whole := _watchtower(false)
	var ww: BrickWorld = whole[0]
	var wreg: BuildingRegistry = whole[1]
	var wc := wreg.materialise(whole[2])
	var part := _watchtower(true)
	var pw: BrickWorld = part[0]
	var preg: BuildingRegistry = part[1]
	var id: int = part[2]
	var b := preg.get_building(id)
	var lines := preg.storey_lines(b)
	_ok(lines.size() >= 4, "the watchtower has %d storeys: %s" % [lines.size() - 1, str(lines)])
	var pc := preg.materialise(id, PackedInt32Array([1]))
	_ok(b.banded and pw.get_block_count(pc) == ww.get_block_count(wc),
			"laid by storeys, every id of the build (%d)" % pw.get_block_count(pc))
	var same := true
	var dims: Vector3i = b.build.chunk_dims()
	for y in range(lines[1], lines[2]):
		for z in dims.z:
			for x in dims.x:
				if pw.block_at(pc, Vector3i(x, y, z)) != ww.block_at(wc, Vector3i(x, y, z)):
					same = false
	_ok(same, "storey 1 holds the same block ids as the build laid whole")
	var laid := pw.get_block_count(pc) - pw.get_absent_count(pc)
	_ok(laid > 0 and laid < ww.get_alive_block_count(wc), "and only it: %d of %d" % [laid,
			ww.get_alive_block_count(wc)])
	_ok(pw.find_detached_groups(pc).is_empty(), "standing on the storey under it")
	var hidden: Array = preg.build_hidden(b, func(s: int) -> bool: return s != 1)
	var hid := 0
	for i in b.build.size():
		if (hidden[0] as Dictionary).has(i):
			hid += 1
	_ok(hid == laid, "its rest shell leaves out exactly the laid storey's blocks (%d)" % hid)
	var cell := BrickWorld.get_cell_size()
	# At a brick of storey 2, found in the grid once it is laid.
	preg.lay_storeys(id, PackedInt32Array([2]))
	var at := Vector3.INF
	for y in range(lines[2] + 3, lines[3]):
		for z in dims.z:
			for x in dims.x:
				if at == Vector3.INF and pw.is_solid(pc, Vector3i(x, y, z)):
					at = Vector3((x + 0.5) * cell.x, (y + 0.5) * cell.y, (z + 0.5) * cell.z)
	# Stone: a blast wears it before it breaks it. Hit until something dies.
	var hit := PackedInt32Array()
	for k in 8:
		hit.append_array(preg.damage(id, at, 0.6))
	_ok(b.storeys_laid.has(2) and hit.size() > 0, "hits on storey 2 kill %d" % hit.size())
	var dead := pw.get_dead_blocks(pc)
	var worn := pw.get_worn_blocks(pc)
	preg.dematerialise(id)
	preg.storey_units = false
	var c2 := preg.materialise(id)
	_ok(pw.get_dead_blocks(c2) == dead and pw.get_worn_blocks(c2) == worn and dead.size() > 0,
			"given back, laid whole: the same %d dead and %d worn" % [dead.size(), worn.size() / 2])
