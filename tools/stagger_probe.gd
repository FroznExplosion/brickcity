extends SceneTree
## Staggered floor seams (TowerRecipe.STAGGER): every other floor's two layers
## laid 2 and 6 studs in instead of 0 and 5. Towers built both ways, and:
##   * every floor covers exactly the cells it did -- no hole, no overlap
##     with a column or a wall (the same solid cells, layer by layer);
##   * on a staggered floor no seam of either layer is on a line of the floor
##     below's (what the stagger is for);
##   * the upper layer still crosses every seam of the lower;
##   * how many parts it costs, building by building.
##   --headless --path . --script res://tools/stagger_probe.gd

const SHAPES := [Vector3i(40, 34, 30), Vector3i(80, 60, 60), Vector3i(50, 48, 50),
		Vector3i(30, 24, 30)]

var _fails := 0


func _init() -> void:
	for s: Vector3i in SHAPES:
		var off := _build(s, false)
		var on := _build(s, true)
		var w_off: BrickWorld = off[0]
		var w_on: BrickWorld = on[0]
		var c_off: int = off[1]
		var c_on: int = on[1]
		var dims := w_on.get_chunk_dims(c_on)
		var origin := w_on.get_chunk_origin(c_on)
		var n_off := w_off.get_block_count(c_off)
		var n_on := w_on.get_block_count(c_on)
		print("  %d x %d, %d courses: %d parts as before, %d staggered (%+d, %+.1f%%)" % [
				s.x, s.z, s.y, n_off, n_on, n_on - n_off, 100.0 * (n_on - n_off) / n_off])
		# The same cells solid, everywhere.
		var differ := 0
		for y in dims.y:
			for x in dims.x:
				for z in dims.z:
					var p := origin + Vector3i(x, y, z)
					if w_on.is_solid(c_on, p) != w_off.is_solid(c_off, p):
						differ += 1
		_ok("%d x %d: the same cells solid both ways" % [s.x, s.z], differ == 0,
				"%d differ" % differ)
		# Seams, floor by floor: which x lines each layer is cut on, read from the
		# bricks along a row near each face. Not one past the stairwell: the
		# hole's edge is a cut in every floor whatever the layout, the hole
		# being there -- and the layers lay round it on its own lines.
		var floors := 0
		var clash := 0
		var unbridged := 0
		for row in [origin.z + 3, origin.z + s.z - 4]:
			var prev_lines := {}
			for band in TowerRecipe.layout(s.y):
				if band.kind != "slab" and band.kind != "base":
					continue
				var lower := _seams(w_on, c_on, origin, int(band.y), row, s.x)
				var upper := _seams(w_on, c_on, origin, int(band.y) + 1, row, s.x)
				var here := {}
				for v in lower:
					here[v] = true
				for v in upper:
					here[v] = true
				if band.kind == "slab":
					floors += 1
					for v in here:
						if prev_lines.has(v):
							clash += 1
				for v in lower:
					if upper.has(v):
						unbridged += 1
				prev_lines = here
		_ok("%d x %d: no seam over a seam of the floor below (%d floor rows)" % [s.x, s.z, floors],
				clash == 0, "%d line(s) shared" % clash)
		_ok("%d x %d: the upper layer crosses every lower seam" % [s.x, s.z], unbridged == 0,
				"%d seam(s) in both layers" % unbridged)
	print("[stagger] %s" % ("ok" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)


func _build(s: Vector3i, staggered: bool) -> Array:
	TowerRecipe.stagger = staggered
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	reg.storey_units = false
	var id := reg.register(s.x, s.z, s.y, Transform3D())
	# With its stairwell: a hole through every floor but the ground, which a
	# staggered layer has to lay round (TowerRecipe._lay_layer).
	var sx := TowerRecipe.stair_line(s.x)
	var sz := TowerRecipe.stair_line(s.z)
	if sx >= 0 and sz >= 0:
		reg.add_fixture(id, "staircase", {"steps": StaircaseRecipe.steps_for_courses(s.y),
				"colour": 11}, Vector3i(sx, TowerRecipe.SLAB_PLATES, sz))
	var chunk := reg.materialise(id)
	var detached := 0
	for g in w.find_detached_groups(chunk):
		detached += (g as PackedInt32Array).size()
	_ok("%d x %d %s: nothing detached" % [s.x, s.z, "staggered" if staggered else "as before"],
			detached == 0, "%d detached" % detached)
	return [w, chunk]


## The x lines inside the footprint where one plate ends and the next begins,
## along row `z` of plate layer `y`. Walls and columns cut through a slab
## nowhere, so every block in it is a plate.
func _seams(w: BrickWorld, chunk: int, origin: Vector3i, y: int, z: int, fx: int) -> Array:
	var out := []
	var was := w.block_at(chunk, origin + Vector3i(0, y, z))
	for x in range(1, fx):
		var b := w.block_at(chunk, origin + Vector3i(x, y, z))
		if b != was and b >= 0 and was >= 0:
			out.append(x)
		was = b
	return out


func _ok(what: String, cond: bool, note := "") -> void:
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + note) if note != "" else ""])
	if not cond:
		_fails += 1
