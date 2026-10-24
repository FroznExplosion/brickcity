extends SceneTree
## BuildingShell.standing_copy -- the rows and outer-wall columns a window pane
## asks, copied for a worker -- against a copy of the whole chunk
## (BrickWorld.get_solid_cells), over a big tower shot at random: every cell
## window_arrays asks is in the copy, and the panes it draws are the same. And
## how long each copy takes.
##   --headless --path . --script res://tools/pane_copy_probe.gd

const FX := 40
const FZ := 30
const COURSES := 34

var _fails := 0


func _init() -> void:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(FX, FZ, COURSES, Transform3D())
	var chunk := reg.materialise(id)
	var layout := TowerRecipe.layout(COURSES)
	var lattice := RoomManifest.lattice_for(FX, FZ, COURSES)
	var rows := BuildingShell.window_rows(COURSES, layout, lattice)
	var dims: Vector3i = w.get_chunk_dims(chunk)
	_ok("the chunk is the footprint", dims.x == FX and dims.z == FZ, "%s" % dims)
	_ok("there are window rows", rows.size() > 0, "%d of %d" % [rows.size(), dims.y])
	var row_set := {}
	for y in rows:
		row_set[y] = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var top := COURSES * 0.4
	var full_us := 0
	var part_us := 0
	var rounds := 0
	var outside := 0
	var differ := 0
	var panes_seen := 0
	for r in 30:
		for k in 2 + r / 3:
			var p := Vector3(rng.randf_range(-0.5, FX * 0.4 + 0.5), rng.randf_range(0.0, top),
					rng.randf_range(-0.5, FZ * 0.4 + 0.5))
			reg.damage(id, p, rng.randf_range(0.6, 2.0))
		var t0 := Time.get_ticks_usec()
		var solid := w.get_solid_cells(chunk)
		var t1 := Time.get_ticks_usec()
		var part := BuildingShell.standing_copy(w, chunk, rows)
		var t2 := Time.get_ticks_usec()
		full_us += t1 - t0
		part_us += t2 - t1
		rounds += 1
		var asked: Array[Vector3i] = []
		var full := func(cell: Vector3i) -> bool:
			asked.append(cell)
			if cell.x < 0 or cell.y < 0 or cell.z < 0 \
					or cell.x >= dims.x or cell.y >= dims.y or cell.z >= dims.z:
				return false
			return solid[cell.x + dims.x * (cell.y + dims.y * cell.z)] != 0
		var a := BuildingShell.window_arrays(FX, FZ, COURSES, 1, layout, lattice, {}, {}, full)
		var b := BuildingShell.window_arrays(FX, FZ, COURSES, 1, layout, lattice, {}, {}, part)
		for c in asked:
			var ring := c.x < BuildingShell.PANE_REACH or c.x >= dims.x - BuildingShell.PANE_REACH \
					or c.z < BuildingShell.PANE_REACH or c.z >= dims.z - BuildingShell.PANE_REACH
			if not row_set.has(c.y) or not ring:
				outside += 1
				if outside <= 3:
					print("  asked outside the copy: %s" % c)
		var va: PackedVector3Array = PackedVector3Array() if a.is_empty() else a[Mesh.ARRAY_VERTEX]
		var vb: PackedVector3Array = PackedVector3Array() if b.is_empty() else b[Mesh.ARRAY_VERTEX]
		if va != vb:
			differ += 1
			print("  round %d: %d vs %d pane vertices" % [r, va.size(), vb.size()])
		panes_seen = maxi(panes_seen, va.size())
	print("  %d rounds, alive at the end %d of %d" % [rounds, w.get_alive_block_count(chunk),
			w.get_block_count(chunk)])
	print("  whole chunk copy: mean %.3f ms; rows and walls: mean %.3f ms" % [
			float(full_us) / rounds / 1000.0, float(part_us) / rounds / 1000.0])
	_ok("every cell a pane asks is in the copy", outside == 0, "%d outside" % outside)
	_ok("the panes are the same as from the whole chunk", differ == 0, "%d round(s) differ" % differ)
	_ok("and there were panes to draw", panes_seen > 0)
	print("[pane_copy] %s" % ("ok" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


func _ok(what: String, cond: bool, detail := "") -> void:
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])
	if not cond:
		_fails += 1
