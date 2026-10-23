extends SceneTree

## The planet's voxel generator (scripts/planet/planet_graph.gd) against the
## CPU's height (PlanetData.height): where the generated SDF crosses zero along
## a radial line must be where the CPU says the ground is -- on the relief, on
## a pad and on a pad's slope. The impostor, building placement and spawn all
## ask the CPU, so a disagreement is a building floating or sunk.
##   --headless --path . --script res://tools/planet_graph_probe.gd

var ok := 0
var fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		ok += 1
	else:
		fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


func _initialize() -> void:
	var data := PlanetData.new()
	var pad_dir := Vector3(0.3, 1.0, 0.2).normalized()
	data.pads = [{"dir": pad_dir, "height": 12.0, "flat": 30.0, "blend": 25.0}]
	var t0 := Time.get_ticks_usec()
	var g := PlanetGraph.build(data)
	print("[graph] compiled in %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var worst := 0.0
	var dirs: Array = [Vector3.UP, Vector3(1, 0.2, 0).normalized(), Vector3(-0.4, -0.7, 0.5).normalized(),
			pad_dir, (pad_dir + Vector3(0.0016, 0, 0)).normalized(), (pad_dir + Vector3(0.004, 0, 0)).normalized()]
	for d in dirs:
		var want := data.height(d)
		var got := _crossing(g, data, d)
		var e := absf(got - want)
		worst = maxf(worst, e)
		print("[graph] dir %v: CPU %.3f m, voxels %.3f m, off %.3f" % [d, want, got, e])
	_check("the generator's ground is the CPU's (< 0.05 m)", worst < 0.05, "%.3f m" % worst)
	var on_pad := data.height(pad_dir)
	_check("a pad is level at its height", absf(on_pad - 12.0) < 0.01, "%.3f" % on_pad)
	print("[graph] %d ok, %d FAIL" % [ok, fail])
	quit(1 if fail > 0 else 0)


## Where the SDF changes sign along `dir`, from a 1-voxel block column round
## the CPU's guess, by linear interpolation between samples 0.25 m apart.
func _crossing(g: VoxelGeneratorGraph, data: PlanetData, dir: Vector3) -> float:
	var guess := data.height(dir)
	var prev_s := NAN
	var prev_t := 0.0
	var t := guess - 8.0
	while t <= guess + 8.0:
		var p := dir * (data.radius + t)
		var s := _sdf(g, p)
		if not is_nan(prev_s) and prev_s <= 0.0 and s > 0.0:
			return prev_t + (t - prev_t) * (-prev_s) / (s - prev_s)
		prev_s = s
		prev_t = t
		t += 0.25
	return NAN


func _sdf(g: VoxelGeneratorGraph, p: Vector3) -> float:
	# The eight voxel corners round p, trilinearly: what the mesher does too.
	var buf := VoxelBuffer.new()
	buf.create(2, 2, 2)
	var o := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
	g.generate_block(buf, o, 0)
	var fr := p - Vector3(o)
	var s := 0.0
	for k in 8:
		var cx := k & 1
		var cy := (k >> 1) & 1
		var cz := (k >> 2) & 1
		var w := (fr.x if cx else 1.0 - fr.x) * (fr.y if cy else 1.0 - fr.y) * (fr.z if cz else 1.0 - fr.z)
		s += w * buf.get_voxel_f(cx, cy, cz, VoxelBuffer.CHANNEL_SDF)
	return s
