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
		var t1 := Time.get_ticks_usec()
		_ws._stamp_model(m)
		var t2 := Time.get_ticks_usec()
		var blocks: int = (m.node as AssetSculpt).form.block_count()
		_ws.sculpt_convert()
		var t3 := Time.get_ticks_usec()
		var rss1 := _rss_mb()
		print("  %5d   %8.0f   %6d   %10.0f   %6d   %.0f -> %.0f" % [int(s), (t2 - t1) / 1000.0, blocks,
				(t3 - t2) / 1000.0, _ws.bench.recipe.size(), rss0, rss1])
		print("         (placing it at a gun's size first: %.0f ms)" % ((t1 - t0) / 1000.0))
	print("model scale probe: done")
	quit(0)
