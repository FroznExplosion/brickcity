extends SceneTree

## A building laid a storey at a time keeps its staircase (user, 2026-11-15:
## "even when I don't damage a building the staircase and some parts of the
## centre floor of a room is unexplainably damaged and falls when I get close").
##
##     godot --headless --path . --script tools/probes/storey_stair_probe.gd
##
## The staircase is one fixture up the whole stairwell, which has no floor in
## it (CityScene._add_staircase). The camera coming near lays the storeys at its
## height only (CityScene._stream_residency, Docs/Space.md 5.3a). Every storey
## laid on its own, and a few runs of two: nothing of an undamaged building may
## come out detached -- its stair least of all, which fell and broke the floor
## round the shaft.

## `-- --fx=80 --fz=60 --courses=60` for another tower.
var FX := 30
var FZ := 30
var COURSES := 48

var _pass := 0
var _fail := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fx="):
			FX = int(a.trim_prefix("--fx="))
		elif a.begins_with("--fz="):
			FZ = int(a.trim_prefix("--fz="))
		elif a.begins_with("--courses="):
			COURSES = int(a.trim_prefix("--courses="))
	var probe := _make()
	var reg: BuildingRegistry = probe[1]
	var n := reg.storey_count(probe[2])
	print("[storey_stair] %dx%d, %d courses, %d storeys" % [FX, FZ, COURSES, n])
	var worst := 0
	var worst_stair := 0
	var bad := 0
	var runs: Array = []
	for s in range(0, n):
		runs.append(PackedInt32Array([s]))
	if "--quick" in OS.get_cmdline_user_args():
		runs = [PackedInt32Array([1])]
	for s in range(1, n - 1, 3):
		runs.append(PackedInt32Array([s, s + 1]))
	# Laid one after the other, as the city lays them (_lay_more): storey s
	# first, then the one over it.
	var seq: Array = []
	for s in range(1, n - 1, 3):
		seq.append(PackedInt32Array([s, s + 1]))
	for run in seq:
		var m := _make()
		var w: BrickWorld = m[0]
		var r: BuildingRegistry = m[1]
		var id: int = m[2]
		var c := r.materialise(id, PackedInt32Array([run[0]]))
		r.lay_storeys(id, PackedInt32Array([run[1]]))
		var loose := 0
		for g in w.find_detached_groups(c):
			loose += (g as PackedInt32Array).size()
		if loose > 0:
			bad += 1
			print("  --   storey %d, then %d laid over it: %d brick(s) loose" % [run[0], run[1], loose])
		worst = maxi(worst, loose)
	var every := PackedInt32Array()
	for s in n:
		every.append(s)
	runs.append(every)
	for run in runs:
		var m := _make()
		var w: BrickWorld = m[0]
		var r: BuildingRegistry = m[1]
		var id: int = m[2]
		var c := r.materialise(id, run)
		var stair := {}
		for f in r.get_building(id).fixtures:
			for bid in f.blocks:
				stair[bid] = true
		var loose := 0
		var loose_stair := 0
		var where := []
		var boxes := {}
		for bx in w.get_block_boxes(c):
			boxes[int((bx as Dictionary).block)] = (bx as Dictionary).pos
		for g in w.find_detached_groups(c):
			for bid in (g as PackedInt32Array):
				loose += 1
				if stair.has(bid):
					loose_stair += 1
				if where.size() < 8 and boxes.has(bid):
					var tk: Array = w.get_block_ticks(c, bid)
					where.append("%s%s %s y%s h%s" % ["S" if stair.has(bid) else "b",
							(boxes[bid] as Vector3).snapped(Vector3.ONE * 0.1),
							w.get_archetype_name(w.get_block_archetype(c, bid)),
							(tk[0] as Vector3i).y if not tk.is_empty() else -1,
							(tk[1] as Vector3i).y if not tk.is_empty() else -1])
		if loose > 0 and run.size() <= 2 and where.size() > 0:
			print("  --     lines %s; at %s" % [r.storey_lines(r.get_building(id)).slice(run[0], run[run.size() - 1] + 2), where])
		if loose > 0:
			bad += 1
			print("  --   storeys %s: %d brick(s) loose, %d of them stair" % [run, loose, loose_stair])
		worst = maxi(worst, loose)
		worst_stair = maxi(worst_stair, loose_stair)
	_ok(bad == 0, "laid a storey (or two) at a time, nothing of it comes loose (%d of %d runs did; worst %d bricks, %d stair)" % [
			bad, runs.size() + seq.size(), worst, worst_stair])
	print("\n[storey_stair] %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ok    " + what)
	else:
		_fail += 1
		print("  FAIL  " + what)


## A tower with its staircase, as CityScene puts one in (_add_staircase).
func _make() -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	reg.storey_units = true
	var id := reg.register(FX, FZ, COURSES, Transform3D())
	var sx := TowerRecipe.stair_line(FX)
	var sz := TowerRecipe.stair_line(FZ)
	if sx >= 0 and sz >= 0:
		reg.add_fixture(id, "staircase", {
			"steps": StaircaseRecipe.steps_for_courses(COURSES),
			"colour": 11,
		}, Vector3i(sx, TowerRecipe.SLAB_PLATES, sz))
	reg.prepare_templates()
	return [w, reg, id]
