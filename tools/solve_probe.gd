extends SceneTree

## The structural solve a damaged building is put through every time it is
## dirty: solve_stress, check_stability, find_detached_groups -- and
## BrickWorld.solve_structure, which is those three in one call sharing one
## grounding walk. It has to give exactly their answers, including when the
## stress solve breaks joints and the grounding has to be walked again.
##
## `-- --digest` prints one line per case instead: every block's load, the
## failures, the stability and the groups, hashed -- to compare two builds of
## the extension bit for bit. `-- --time` adds what each call costs on the big
## city's towers.

var passed := 0
var failed := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--digest"):
		for c in _cases():
			print("%-34s %s" % [c.name, _digest(c)])
		quit(0)
		return
	print("solve_structure is the three calls it replaces")
	for c in _cases():
		_check_same(c)
	_check_template()
	if args.has("--time"):
		_time()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  ok   %s" % what)
	else:
		failed += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## Each case is a way of damaging a tower, applied to a fresh world, so the same
## case can be built twice and asked two ways.
func _cases() -> Array:
	return [
		{"name": "intact", "x": 20, "z": 20, "courses": 36, "tension": 0.0, "hits": []},
		{"name": "base blown out", "x": 20, "z": 20, "courses": 36, "tension": 0.0,
				"hits": [[Vector3(0.4, 0.5, 0.4), 2.5], [Vector3(2.0, 0.5, 0.4), 2.5]]},
		{"name": "weak joints, undercut", "x": 20, "z": 20, "courses": 36, "tension": 20.0,
				"hits": [[Vector3(4.0, 3.0, 0.3), 2.0]]},
		{"name": "very weak joints", "x": 30, "z": 20, "courses": 60, "tension": 3.0,
				"hits": [[Vector3(6.0, 6.0, 0.3), 3.0]]},
		{"name": "a corner gone", "x": 40, "z": 30, "courses": 60, "tension": 0.0,
				"hits": [[Vector3(0.5, 1.0, 0.5), 3.2], [Vector3(0.5, 4.0, 0.5), 3.2]]},
		{"name": "joints barely hold", "x": 20, "z": 20, "courses": 36, "tension": 0.6,
				"hits": [[Vector3(4.0, 3.0, 0.3), 2.0]]},
		{"name": "a storey cut through", "x": 20, "z": 20, "courses": 36, "tension": 0.0,
				"hits": [], "cut": [30, 33]},
		{"name": "cut, and weak above it", "x": 30, "z": 20, "courses": 48, "tension": 2.0,
				"hits": [[Vector3(6.0, 9.0, 0.3), 2.5]], "cut": [45, 48]},
	]


func _build(c: Dictionary) -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var chunk := w.create_chunk(Vector3i.ZERO,
			TowerRecipe.chunk_dims(int(c.x), int(c.z), int(c.courses)))
	TowerRecipe.build(w, chunk, palette, int(c.x), int(c.z), int(c.courses))
	w.set_chunk_transform(chunk, Transform3D.IDENTITY)
	if float(c.tension) > 0.0:
		w.set_tension_per_stud(chunk, float(c.tension))
	for h in c.hits:
		w.apply_hit(chunk, h[0], h[1])
	# Every brick whose bottom is in these plates, gone: what is above is held
	# by nothing and comes away as groups.
	if c.has("cut"):
		var pt := BrickWorld.ticks_per_plate()
		var gone := PackedInt32Array()
		for id in w.get_block_count(chunk):
			var ticks: Array = w.get_block_ticks(chunk, id)
			if ticks.is_empty():
				continue
			@warning_ignore("integer_division")
			var plate: int = (ticks[0] as Vector3i).y / pt
			if plate >= int(c.cut[0]) and plate < int(c.cut[1]):
				gone.push_back(id)
		w.kill_blocks(chunk, gone)
	return [w, chunk]


func _separately(w: BrickWorld, chunk: int) -> Dictionary:
	var stress: Dictionary = w.solve_stress(chunk)
	var stability: Dictionary = w.check_stability(chunk)
	var groups: Array = w.find_detached_groups(chunk)
	return {"stress": stress, "stability": stability, "groups": groups}


func _check_same(c: Dictionary) -> void:
	var a := _build(c)
	var b := _build(c)
	var wa: BrickWorld = a[0]
	var wb: BrickWorld = b[0]
	var ca: int = a[1]
	var cb: int = b[1]
	# Twice: the second solve starts from what the first one broke.
	for round in 2:
		var three := _separately(wa, ca)
		var one: Dictionary = wb.solve_structure(cb)
		var s3: Dictionary = three.stress
		var s1: Dictionary = one.stress
		var label := "%s, solve %d (%d failures)" % [c.name, round + 1, int(s3.failures)]
		_ok(label + ": the same stress answer",
				s3.failures == s1.failures and s3.separated == s1.separated
				and s3.max_ratio == s1.max_ratio and s3.peak_load == s1.peak_load
				and s3.blocks_loaded == s1.blocks_loaded)
		_ok(label + ": the same loads, block by block", _loads(wa, ca) == _loads(wb, cb))
		var t3: Dictionary = three.stability
		var t1: Dictionary = one.stability
		_ok(label + ": the same stability",
				t3.get("stable") == t1.get("stable") and t3.get("blocks") == t1.get("blocks")
				and t3.get("overhang") == t1.get("overhang") and t3.get("com") == t1.get("com"))
		_ok(label + ": the same detached groups", three.groups == one.groups,
				"%d against %d" % [three.groups.size(), one.groups.size()])
		# What a building does with detached groups: they leave it.
		for g in three.groups:
			wa.kill_blocks(ca, g)
		for g in one.groups:
			wb.kill_blocks(cb, g)


## BuildingRegistry builds a recipe once and copies it after that
## (BrickWorld.save_template / load_template). The copy has to be the building:
## the same ids with the same bricks in the same cells, or every damage record
## replays into the wrong bricks.
func _check_template() -> void:
	print("
a template is the building it was saved from")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var dims := TowerRecipe.chunk_dims(30, 20, 48)
	var built := w.create_chunk(Vector3i.ZERO, dims)
	TowerRecipe.build(w, built, palette, 30, 20, 48, [Rect2i(10, 10, 10, 10)])
	var t := w.save_template(built)
	var copy := w.create_chunk(Vector3i.ZERO, dims)
	_ok("it loads into an empty chunk of the same shape", w.load_template(t, copy))
	var other := w.create_chunk(Vector3i.ZERO, dims + Vector3i(1, 0, 0))
	_ok("and not into one of another shape", not w.load_template(t, other))
	_ok("and not twice into the same one", not w.load_template(t, copy))
	var same := w.get_block_count(built) == w.get_block_count(copy)
	var first_diff := -1
	for id in w.get_block_count(built):
		if w.get_block_ticks(built, id) != w.get_block_ticks(copy, id) 				or w.get_block_archetype(built, id) != w.get_block_archetype(copy, id) 				or w.get_block_colour(built, id) != w.get_block_colour(copy, id) 				or w.get_block_material(built, id) != w.get_block_material(copy, id) 				or w.is_block_decorative(built, id) != w.is_block_decorative(copy, id):
			same = false
			first_diff = id
			break
	_ok("every block the same, id for id", same, "first difference at %d" % first_diff)
	# The grid too: a copy whose blocks match but whose cells were not claimed
	# would take a second brick in the same place.
	var cells_same := true
	for x in dims.x:
		for z in dims.z:
			for y in range(0, dims.y, 3):
				if w.block_at(built, Vector3i(x, y, z)) != w.block_at(copy, Vector3i(x, y, z)):
					cells_same = false
	_ok("and the same cells claimed", cells_same)
	w.apply_hit(built, Vector3(4.0, 1.0, 0.3), 2.5)
	w.apply_hit(copy, Vector3(4.0, 1.0, 0.3), 2.5)
	var a: Dictionary = w.solve_structure(built)
	var b: Dictionary = w.solve_structure(copy)
	# Everything but the clock.
	(a.stress as Dictionary).erase("solve_ms")
	(b.stress as Dictionary).erase("solve_ms")
	_ok("and it solves the same after the same hit", str(a) == str(b)
			and _loads(w, built) == _loads(w, copy))


func _loads(w: BrickWorld, chunk: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for id in w.get_block_count(chunk):
		out.push_back(w.get_block_load(chunk, id))
	return out


func _digest(c: Dictionary) -> String:
	var r := _build(c)
	var w: BrickWorld = r[0]
	var chunk: int = r[1]
	var parts := []
	var groups_seen := [0, 0]
	for round in 2:
		var s := _separately(w, chunk)
		groups_seen[round] = s.groups.size()
		var st: Dictionary = s.stress
		var stab: Dictionary = s.stability
		parts.append([st.failures, Array(st.separated).hash(), st.max_ratio, st.peak_load,
				Array(_loads(w, chunk)).hash(), stab.get("stable"), stab.get("overhang"),
				Array(stab.get("blocks", [])).hash(), str(s.groups).hash(),
				str(w.get_components(chunk)).hash()])
		for g in s.groups:
			w.kill_blocks(chunk, g)
	# The hash, then failures and groups in each round, to see what was exercised.
	return "%x  (failures %d/%d, groups %d/%d)" % [str(parts).hash(), parts[0][0], parts[1][0],
			groups_seen[0], groups_seen[1]]


func _time() -> void:
	print("\nwhat one solve costs, separately and in one call")
	for s in [[40, 30, 60], [60, 40, 162], [80, 60, 204]]:
		var c := {"name": "", "x": s[0], "z": s[1], "courses": s[2], "tension": 0.0,
				"hits": [[Vector3(1.0, 1.0, 0.3), 3.2]]}
		var r := _build(c)
		var w: BrickWorld = r[0]
		var chunk: int = r[1]
		var best3 := INF
		var best1 := INF
		for i in 3:
			var t := Time.get_ticks_usec()
			_separately(w, chunk)
			best3 = minf(best3, float(Time.get_ticks_usec() - t) / 1000.0)
			t = Time.get_ticks_usec()
			w.solve_structure(chunk)
			best1 = minf(best1, float(Time.get_ticks_usec() - t) / 1000.0)
		print("  %dx%dx%d, %5d blocks: three calls %5.1f ms, solve_structure %5.1f ms" % [
				s[0], s[1], s[2], w.get_block_count(chunk), best3, best1])
