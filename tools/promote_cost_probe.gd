extends SceneTree

## What a tower's promotion costs the main thread, part by part, outside the
## city (Docs/Handoff-terrain-ai.md: the fight's opening ticks).
##
##     godot --headless --path . --script res://tools/promote_cost_probe.gd
##
## A registry over the city's palette, towers of the firefight's sizes
## materialised one after another, and the C++ calls CityScene._dress makes
## timed one by one: the bricks laid, the section setters, the bake started,
## the collision built. Prints; checks nothing.

const SIZES := [[30, 30, 42], [30, 40, 60], [40, 30, 24], [20, 20, 12]]
const REPEAT := 4


func _init() -> void:
	var w := BrickWorld.new()
	w.set_seed(4)
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	print("palette: %d archetypes" % w.get_archetype_count())
	var space := PhysicsServer3D.space_create()
	# As the city does at load: a template per tower shape, laid by copying.
	var ids := []
	for size in SIZES:
		ids.append(reg.register(int(size[0]), int(size[1]), int(size[2]),
				Transform3D(Basis(), Vector3(0.0, 0.0, -200.0))))
	print("templates: %.1f ms" % reg.prepare_templates())
	for size in SIZES:
		var sums := {}
		var bricks := 0
		for r in REPEAT:
			var id := reg.register(int(size[0]), int(size[1]), int(size[2]),
					Transform3D(Basis(), Vector3(r * 40.0, 0.0, 0.0)))
			var t := Time.get_ticks_usec()
			var chunk := reg.materialise(id)
			t = _note(sums, "bricks", t)
			w.set_chunk_section_plates(chunk, 20)
			w.set_chunk_section_studs(chunk, 32)
			t = _note(sums, "sections", t)
			w.bake_chunk_async(chunk)
			t = _note(sums, "bake start", t)
			var col := BuildingCollision.new(w, chunk, space, w.get_chunk_transform(chunk), true)
			t = _note(sums, "collision", t)
			bricks = w.get_alive_block_count(chunk)
			while not w.bake_ready(chunk):
				OS.delay_usec(200)
			col.free_bodies()
		var line := ""
		for k in sums:
			line += "%s %.2f  " % [k, float(sums[k]) / REPEAT / 1000.0]
		print("%dx%d, %d courses (%d bricks): %s" % [size[0], size[1], size[2], bricks, line])
	PhysicsServer3D.free_rid(space)
	quit(0)


func _note(sums: Dictionary, part: String, t: int) -> int:
	var now := Time.get_ticks_usec()
	sums[part] = int(sums.get(part, 0)) + (now - t)
	return now
