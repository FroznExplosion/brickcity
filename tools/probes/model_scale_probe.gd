extends SceneTree

## A model as big as a building, through the asset workshop's clay as it is now: the time and
## the memory of stamping it and of Make bricks, at 100, 200 and 400 studs (Docs/BuildTools.md
## section 21, "A model into a building": measure before building stage 7). A model a fifth
## the size has the samples across that the planned stud-sized clay would give the full one,
## so its row estimates that clay too. Not a pass/fail probe: it prints a table.
##
##     godot --headless --path . --script res://tools/probes/model_scale_probe.gd [-- --sizes=100,200,400]
##
## Timing: run with the editor closed and nothing else heavy going (CLAUDE.md).

var _ws
var _frames := 0


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	root.add_child(_ws)
	process_frame.connect(_tick)


## The process's working set, MB (Windows: tasklist), or -1.
func _rss_mb() -> float:
	var out := []
	OS.execute("tasklist", ["/FI", "PID eq %d" % OS.get_process_id(), "/FO", "CSV", "/NH"], out)
	if out.is_empty():
		return -1.0
	var cols := String(out[0]).split("\",\"")
	if cols.size() < 5:
		return -1.0
	return float(cols[4].replace("\"", "").replace(",", "").replace(" K", "").strip_edges()) / 1024.0


## A building-like model: a hollow box (walls a stud thick) `s` studs long, half as tall, 0.4
## as deep -- a skin, as a building is -- as one mesh in metres of the model's own.
func _building_mesh(s: float) -> ArrayMesh:
	var outer := BoxMesh.new()
	outer.size = Vector3(s, s * 0.5, s * 0.4)
	var inner := BoxMesh.new()
	inner.size = Vector3(s - 2.0, s * 0.5 - 2.0, s * 0.4 - 2.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(outer, 0, Transform3D())
	# The inner box turned inside out: its faces point in, so the walls are a shell.
	var arr := inner.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	for i in range(0, idx.size(), 3):
		for k in [0, 2, 1]:
			st.add_vertex(v[idx[i + k]])
	var m := st.commit()
	return m


func _tick() -> void:
	_frames += 1
	if _frames != 3:
		return
	_ws.set_process(false)
	_ws._no_autosave = true
	_ws.bench._hotbar.save_path = "user://dev/_probe_asset_hotbar.json"
	_ws.toolbars_save = "user://dev/_probe_asset_toolbars.json"
	_ws.convert_mirror = false
	var sizes := [80.0, 100.0, 200.0, 400.0]
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--sizes="):
			sizes = Array(String(a).substr(8).split(",")).map(func(x: String) -> float: return float(x))
	print("model scale probe: a hollow building model through the clay (tick clay, as built)")
	print("  build area: %d x %d studs, %d plates up" % [_ws.bench.plate_studs, _ws.bench.plate_studs, _ws.bench.height_plates])
	print("  studs   stamp ms   blocks   convert ms   bricks   RSS MB (before -> after)")
	for s in sizes:
		_ws.sculpt_clear()
		_ws.bench._new_build()
		var rss0 := _rss_mb()
		var mesh := _building_mesh(s)
		var t0 := Time.get_ticks_usec()
		var placed: bool = _ws.place_mesh(mesh, "res://scale_%d.glb" % int(s))
		var m: Dictionary = _ws.models[_ws.models.size() - 1] if placed and not _ws.models.is_empty() else {}
		if m.is_empty():
			print("  %5d   could not place" % int(s))
			continue
		# As long as asked (place_mesh made it a gun's length): scale it about where it stands.
		var box: AABB = (m.xf as Transform3D) * (m.box as AABB)
		var k: float = s * BrickPalette.STUD_M / maxf(box.size.x, 0.001)
		var xf: Transform3D = m.xf
		m.xf = Transform3D(xf.basis.scaled(Vector3.ONE * k), xf.origin)
		# Standing on the area's floor (a plate up), inside it.
		var nb: AABB = (m.xf as Transform3D) * (m.box as AABB)
		m.xf = Transform3D((m.xf as Transform3D).basis, (m.xf as Transform3D).origin
				+ Vector3(0.0, BrickPalette.PLATE_M - nb.position.y, 0.0))
		var t1 := Time.get_ticks_usec()
		_ws._stamp_model(m)
		var t2 := Time.get_ticks_usec()
		var blocks: int = (m.node as AssetSculpt).form.block_count()
		var cb: AABB = (m.xf as Transform3D) * (m.box as AABB)
		print("         model box, studs: %s at %s" % [str(cb.size / BrickPalette.STUD_M), str(cb.position / BrickPalette.STUD_M)])
		_ws.sculpt_convert()
		var t3 := Time.get_ticks_usec()
		var rss1 := _rss_mb()
		print("  %5d   %8.0f   %6d   %10.0f   %6d   %.0f -> %.0f" % [int(s), (t2 - t1) / 1000.0, blocks,
				(t3 - t2) / 1000.0, _ws.bench.recipe.size(), rss0, rss1])
		print("         (placing it at a gun's size first: %.0f ms)" % ((t1 - t0) / 1000.0))
		# Make bricks emptied the clay in one (every cell became bricks): one Z brings it back.
		var clay_after: int = _ws.sculpt.form.block_count()
		_ws._undo()
		print("         clay blocks after Make bricks %d; after Z %d, bricks %d (undo %s)" % [clay_after,
				_ws.sculpt.form.block_count() + _ws.models.size(), _ws.bench.recipe.size(),
				"ok" if clay_after == 0 and (_ws.sculpt.form.block_count() > 0 or not _ws.models.is_empty()) and _ws.bench.recipe.size() <= 1 else "WRONG"])
		# Where Make bricks' time went, the biggest first.
		var steps: Array = _ws.convert_ms.keys()
		steps.sort_custom(func(x, y) -> bool: return float(_ws.convert_ms[x]) > float(_ws.convert_ms[y]))
		for st in steps:
			if float(_ws.convert_ms[st]) >= 1.0:
				print("           %-30s %8.0f ms" % [st, float(_ws.convert_ms[st])])
	print("model scale probe: done")
	quit(0)
