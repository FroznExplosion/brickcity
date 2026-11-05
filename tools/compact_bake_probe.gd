extends SceneTree
## A settled loose piece baked again without its dead bricks (Docs/Hulls.md 11, E2:
## BrickWorld.set_chunk_bake_skips_dead, IslandManager._compact_due).
##
##     godot --headless --path . --script res://tools/compact_bake_probe.gd
##
##   carried   a ship's chunk with most of its bricks killed keeps every face slot
##   compact   baked again skipping the dead: far fewer slots, the same faces drawn
##   patched   a live brick killed after: the patch fits and draws what a full fill
##             would (the index check finds no mismatch)
##   flag off  a chunk without the flag still keeps its dead bricks' slots

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("compact bake probe")
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


func _bake(w: BrickWorld, ch: int) -> void:
	w.drop_chunk_bake(ch)
	w.bake_chunk_async(ch)
	var t0 := Time.get_ticks_msec()
	while not w.bake_ready(ch) and Time.get_ticks_msec() - t0 < 20000:
		OS.delay_msec(5)
	w.build_chunk_mesh(ch)


func _slots(w: BrickWorld, ch: int) -> Array:
	var st := w.get_mesh_stats(ch)
	@warning_ignore("integer_division")
	return [int(st.index_slots) / 3, int(st.triangles)]


func _run() -> void:
	var w := BrickWorld.new()
	w.set_index_check(true)
	var pal := TowerRecipe.bake_palette(w)
	var m := ShipBuild.make(1)
	if not m.ok:
		_ok("a ship to break", false, str(m.why))
		return
	var r: BuildRecipe = m.recipe
	var made := []
	for flag in [true, false]:
		var ch := w.create_chunk(Vector3i.ZERO, r.chunk_dims())
		r.build(w, ch, pal)
		_bake(w, ch)
		var whole: Array = _slots(w, ch)
		# Most of it gone, as a piece that came loose from it is.
		var n := w.get_block_count(ch)
		var dead := PackedInt32Array()
		for b in n:
			if b % 5 != 0:
				dead.append(b)
		w.kill_blocks(ch, dead)
		w.update_index_region(ch, 4)
		var carried: Array = _slots(w, ch)
		if flag:
			# Drawn need not drop: killing bricks shows their neighbours' inner
			# faces. What matters is that the slots stay, mostly as nothing.
			_ok("carried: every face slot kept, most of them drawn as nothing",
					carried[0] == whole[0] and carried[1] * 4 < carried[0],
					"%d blocks, %d slots, %d drawn (whole %d)" % [n, carried[0], carried[1], whole[1]])
		w.set_chunk_bake_skips_dead(ch, flag)
		_bake(w, ch)
		var after: Array = _slots(w, ch)
		made.append(after)
		if flag:
			_ok("compact: far fewer slots, the same faces drawn",
					after[0] * 2 < carried[0] and after[1] == carried[1],
					"%d -> %d slots, %d -> %d drawn" % [carried[0], after[0], carried[1], after[1]])
			# A live one killed after: a patch, checked against a full fill
			# (get_index_patch_stats [3]: the index check's mismatches).
			var before_patch := w.get_index_patch_stats()
			var live := -1
			for b in range(0, n, 5):
				if w.get_block_hp(ch, b) > 0:
					live = b
					break
			w.kill_blocks(ch, PackedInt32Array([live]))
			var reg := w.update_index_region(ch, 4)
			var after_patch := w.get_index_patch_stats()
			var p: Array = _slots(w, ch)
			_ok("patched: a live brick killed after, the patch fits and matches a full fill",
					not reg.is_empty() and int(reg.get("offset", 0)) + (reg.get("data", PackedByteArray()) as PackedByteArray).size() <= after[0] * 3 * 4
					and p[1] < after[1] and after_patch[3] == before_patch[3],
					"%d drawn, stats %s" % [p[1], str(after_patch)])
		else:
			_ok("flag off: the dead keep their slots", after[0] == carried[0],
					"%d slots" % after[0])
		w.release_chunk(ch)

