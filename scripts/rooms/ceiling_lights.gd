class_name CeilingLights
extends RefCounted

## Ceiling lights for a building laid straight into a chunk (Docs/Lighting.md
## 6.3): Lamp under-tiles clipped under every ceiling over a room-high space,
## a bar every EVERY studs each way, shining down. For buildings that have no
## spaces to read (a planet town's towers, TowerRecipe); a generated ship or
## station is lit by its spaces (KitFurnish.light).
##
## A ceiling is a cell with a brick over it, at least ROOM plates of air under
## it, and brick over the bar's whole length and a stud either side of it --
## a slab, not a stair's flight or a lintel.
##
##   var n := CeilingLights.hang(bricks, chunk, palette)

const EVERY := 7
const ROOM := 8
const COLOUR := "cream"
const PART := "undertile_1x4_z"


## Hangs them; how many.
static func hang(bricks: BrickWorld, chunk: int, palette: Dictionary, colour_name := COLOUR) -> int:
	var part: int = palette.get(PART, -1)
	var lamp := -1
	for m in BrickWorld.get_material_count():
		if BrickWorld.get_material_name(m) == "Lamp":
			lamp = m
	if part < 0 or lamp < 0:
		return 0
	var colour := 0
	for c in BrickWorld.get_material_colour_count(lamp):
		if BrickWorld.get_material_colour_name(lamp, c) == colour_name:
			colour = c
	var o := bricks.get_chunk_origin(chunk)
	var d := bricks.get_chunk_dims(chunk)
	var laid := 0
	for x in range(2, d.x - 2, EVERY):
		for z in range(2, d.z - 5, EVERY):
			var air := 0
			for y in d.y - 1:
				var here := o + Vector3i(x, y, z)
				if bricks.block_at(chunk, here) >= 0:
					air = 0
					continue
				air += 1
				if air < ROOM or not _slab_over(bricks, chunk, here + Vector3i(0, 1, 0)):
					continue
				var id := bricks.place_block(chunk, here, part, colour)
				if id >= 0:
					bricks.set_block_material(chunk, id, lamp)
					laid += 1
				air = 0
	return laid


## Brick over the bar's four cells and a stud either side of each.
static func _slab_over(bricks: BrickWorld, chunk: int, at: Vector3i) -> bool:
	for z in 4:
		for x in [-1, 0, 1]:
			if bricks.block_at(chunk, at + Vector3i(x, 0, z)) < 0:
				return false
	return true
