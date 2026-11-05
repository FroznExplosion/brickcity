extends SceneTree

## Lamps on the brick grid (Docs/Lighting.md 6.3).
##
##     godot --headless --path . --script res://tools/lamp_probe.gd
##
## What it is for: a block in the Lamp material is a light in its own colour;
## a Lamp part smooth on ONE side shines that way only -- a tile (a light bar)
## up, an under-tile (studs on top, clipped under a ceiling) down -- and
## anything else all round, as a Glow brick does. Checked where the light is
## worked out (BrickWorld.chunk_lamps, chunk_light_tiles) and where it is hung
## (BrickGridLight: a spot light for a one-way lamp, an omni for the rest).
## The look of it is the light gate's.

var _pass := 0
var _fail := 0

const CELL := BrickGridLight.CELL_PLATES


func _init() -> void:
	print("lamp probe")
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var lamp := _material("Lamp")
	var glow := _material("Glow PLA")
	_ok("the Lamp material is there", lamp >= 0)
	var red := _colour(lamp, "red")
	var blue := _colour(lamp, "blue")

	# A room 10 x 10 studs: a floor (plates 0-2), a ceiling (plates 15-17)
	# on four corner columns, open at the sides; the ceiling has a roof of
	# nothing over it.
	var chunk := w.create_chunk(Vector3i.ZERO, Vector3i(12, 30, 12))
	for y in 3:
		w.place_block(chunk, Vector3i(0, y, 0), pal["plate_10x10"], 0)
	for y in range(3, 15, 3):
		for c in [Vector3i(0, y, 0), Vector3i(8, y, 0), Vector3i(0, y, 8), Vector3i(8, y, 8)]:
			w.place_block(chunk, c, pal["brick_2x2"], 0)
	for y in range(15, 18):
		w.place_block(chunk, Vector3i(0, y, 0), pal["plate_10x10"], 0)

	# An under-tile, red, under the ceiling: it clips on by its studs.
	var under := w.place_block(chunk, Vector3i(4, 14, 4), pal["undertile_1x4_z"], red)
	w.set_block_material(chunk, under, lamp)
	var ceiling: int = w.block_at(chunk, Vector3i(4, 15, 4))
	_ok("an under-tile clips under the ceiling", under >= 0
			and w.get_block_neighbours(chunk, under).has(ceiling))
	# A light bar, blue, on the floor; a Lamp brick and a Glow brick.
	var bar := w.place_block(chunk, Vector3i(2, 3, 6), pal["tile_1x4_x"], blue)
	w.set_block_material(chunk, bar, lamp)
	var lbrick := w.place_block(chunk, Vector3i(7, 3, 2), pal["brick_2x2"], 0)
	w.set_block_material(chunk, lbrick, lamp)
	var gbrick := w.place_block(chunk, Vector3i(7, 3, 6), pal["brick_2x2"], 0)
	w.set_block_material(chunk, gbrick, glow)

	var lamps := w.chunk_lamps(chunk)
	_ok("four lamps", lamps.size() == 32, str(lamps.size() / 8))
	var by_dir := {}
	for k in range(0, lamps.size(), 8):
		by_dir[int(lamps[k + 3]) * 10 + int(lamps[k + 7] * 2)] = Vector3(lamps[k], lamps[k + 1], lamps[k + 2])
	var cs := Vector3(BrickWorld.get_stud_metres(), BrickWorld.get_plate_metres(), BrickWorld.get_stud_metres())
	# dir * 10 + power * 2: Lamp 2.5 -> 5, Glow 1 -> 2.
	_ok("the under-tile shines down, from its underside", by_dir.has(-10 + 5)
			and is_equal_approx((by_dir.get(-5, Vector3.ZERO) as Vector3).y, 14 * cs.y))
	_ok("the light bar shines up, from its top", by_dir.has(10 + 5)
			and is_equal_approx((by_dir.get(15, Vector3.ZERO) as Vector3).y, 4 * cs.y))
	_ok("a Lamp brick shines all round, brighter than a Glow one", by_dir.has(5) and by_dir.has(2))

	# The grid: under the red under-tile its light, red; over the ceiling
	# none of it; over the blue bar, blue.
	var dims := w.chunk_light_dims(chunk, CELL)
	var tiles := w.chunk_light_tiles(chunk, CELL, BrickGridLight.SIZE, BrickGridLight.SIZE,
			BrickGridLight.SKY_STEP, BrickGridLight.LAMP_STEP)
	_ok("the grid is four bytes a cell", tiles.size() == BrickGridLight.SIZE * BrickGridLight.SIZE * 4)
	var below := _cell(tiles, dims, Vector3i(4, 12, 5))
	var above := _cell(tiles, dims, Vector3i(4, 19, 5))
	_ok("under the red under-tile: red light", below.r > 0.8 and below.r > 3.0 * below.g,
			"%.2f %.2f %.2f" % [below.r, below.g, below.b])
	# Only what comes round the room's open sides, a dozen cells about.
	_ok("over the ceiling: hardly any of it", above.r < 0.1,
			"%.2f %.2f %.2f" % [above.r, above.g, above.b])
	var over_bar := _cell(tiles, dims, Vector3i(3, 6, 6))
	_ok("over the blue light bar: blue light", over_bar.b > 0.8 and over_bar.b > 2.0 * over_bar.r,
			"%.2f %.2f %.2f" % [over_bar.r, over_bar.g, over_bar.b])

	# Hung: spot lights the lamp's way, an omni for the rest, in their colours.
	var root := Node3D.new()
	get_root().add_child(root)
	var grid := BrickGridLight.new()
	grid.track("room", w, chunk, root)
	var spots_down := 0
	var spots_up := 0
	var omnis := 0
	var red_down := false
	for kid in root.get_children():
		var s := kid as SpotLight3D
		if s != null:
			# A spot shines down its -Z.
			var fwd := -s.transform.basis.z
			if fwd.y < -0.99:
				spots_down += 1
				red_down = red_down or (s.light_color.r > 0.9 and s.light_color.g < 0.3)
			elif fwd.y > 0.99:
				spots_up += 1
			_ok("a spot leaves the bricks to the grid, unshadowed",
					(s.light_cull_mask & BrickGridLight.RENDER_LAYER) == 0 and not s.shadow_enabled)
		elif kid is OmniLight3D:
			omnis += 1
	_ok("one spot down (red), one up, the bricks' lights omni",
			spots_down == 1 and red_down and spots_up == 1 and omnis >= 1,
			"down %d up %d omni %d" % [spots_down, spots_up, omnis])
	# The bar goes: its spot goes with it.
	w.kill_blocks(chunk, PackedInt32Array([bar]))
	grid.relight("room")
	spots_up = 0
	for kid in root.get_children():
		var s := kid as SpotLight3D
		if s != null and not s.is_queued_for_deletion() and -s.transform.basis.z.y > 0.99:
			spots_up += 1
	_ok("the light bar broken, its light goes", spots_up == 0)
	grid.release("room")
	root.free()

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## The lamps' light (r, g, b, 0..1) in the grid's cell holding chunk cell `c`
## (studs, plates, studs).
func _cell(tiles: PackedByteArray, dims: Vector3i, c: Vector3i) -> Color:
	var g := Vector3i(c.x + 1, c.y / CELL + 1, c.z + 1)
	var per_row := BrickGridLight.SIZE / dims.x
	var px := (g.y % per_row) * dims.x + g.x
	var py := (g.y / per_row) * dims.z + g.z
	var i := (py * BrickGridLight.SIZE + px) * 4
	return Color(tiles[i + 1] / 255.0, tiles[i + 2] / 255.0, tiles[i + 3] / 255.0)


func _material(name: String) -> int:
	for m in BrickWorld.get_material_count():
		if BrickWorld.get_material_name(m) == name:
			return m
	return -1


func _colour(m: int, name: String) -> int:
	for c in BrickWorld.get_material_colour_count(m):
		if BrickWorld.get_material_colour_name(m, c) == name:
			return c
	return 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])
