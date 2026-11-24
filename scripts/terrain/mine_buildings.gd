class_name MineBuildings
extends RefCounted
## BUILDINGS AS GROUND (Docs/TerrainBuildings.md, stage 1): a city building
## written into the mine world's terrain field, so it IS ground -- dug with
## the pickaxe, shot, collapsing, lit, saved and drawn (the brick overlay's
## real bevels near the eye, the coarse tier far off) by the systems the
## ground already has, with nothing to tell them it is a building.
##
## The building is the city's own generator's (TowerRecipe, as the workshop's
## TowerBlockout lays it): built for real into a scratch BrickWorld chunk and
## read back brick by brick, so its walls, floors, columns, windows and
## stairwell are the ones measured to stand. Each brick becomes the plate cells
## of its box in the BUILDING material of its colour (brick_terrain.h
## MAT_FIL_BASE + its filament: the city's colours, a city brick's strength in
## the collapse), and is marked one placed brick (BrickTerrain.mark_placed), so
## it breaks and falls whole. Glass (PETG, translucent) is left out: its
## windows are open.
##
## The plot is levelled first: the footprint cleared from the building's base
## up past its roof, and stone laid under the base down to the lowest ground
## of the footprint, so the building stands on, and is joined to, the ground.

## Brick material index of PETG, the translucent one (brick_grid.h): glass.
const GLASS_MATERIAL := 4
## Plates of stone under the base past the footprint's lowest ground.
const FOUNDATION_DEPTH := 3
## brick_terrain.h MAT_FIL_BASE: building material = this + filament index.
const BUILDING_MATERIAL_BASE := 64

static var _mat_ids := {}


## The terrain material ids (BrickTerrain's enum, by name).
static func _terrain_ids() -> Dictionary:
	if _mat_ids.is_empty():
		# BrickTerrain's Material enum, in order (brick_terrain.h): appended,
		# never inserted, so the numbers hold.
		var order := ["MAT_AIR", "MAT_GRASS", "MAT_DIRT", "MAT_SAND", "MAT_STONE", "MAT_DARK_STONE",
				"MAT_ROAD", "MAT_SNOW", "MAT_GRAVEL", "MAT_SANDSTONE", "MAT_RED_SAND", "MAT_TERRA_ORANGE",
				"MAT_TERRA_CREAM", "MAT_TERRA_RED", "MAT_CLAY", "MAT_BEDROCK", "MAT_COAL", "MAT_IRON",
				"MAT_COPPER", "MAT_GOLD", "MAT_REDSTONE", "MAT_LAPIS", "MAT_DIAMOND", "MAT_PODZOL",
				"MAT_DRY_GRASS", "MAT_LUSH_GRASS", "MAT_COLD_GRASS", "MAT_DARK_GRASS", "MAT_GRANITE",
				"MAT_DIORITE", "MAT_ICE", "MAT_OBSIDIAN", "MAT_WOOD", "MAT_LEAVES"]
		for i in order.size():
			_mat_ids[order[i]] = i
	return _mat_ids


## The tower's bricks as boxes of plate cells relative to its corner:
## [lo (stud, plate, stud), hi (inclusive), terrain material]. Glass is left
## out. `p`: TowerBlockout's parameters ({"x", "z", "courses", "rooms",
## "windows", "stairs"}).
static func tower_cells(p: Dictionary) -> Array:
	var world := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(world)
	var d := TowerRecipe.chunk_dims(int(p.x), int(p.z), int(p.courses))
	var c := world.create_chunk(Vector3i.ZERO, d)
	var keep: Array = []
	var stair := TowerBlockout.stair_rect(p)
	if stair.size != Vector2i.ZERO:
		keep.append(stair)
	TowerRecipe.build(world, c, palette, int(p.x), int(p.z), int(p.courses), keep,
			{"rooms": bool(p.get("rooms", true)), "windows": bool(p.get("windows", true))})
	if stair.size != Vector2i.ZERO:
		var f := Fixture.new()
		f.kind = "staircase"
		f.cell = Vector3i(stair.position.x, TowerRecipe.SLAB_PLATES, stair.position.y)
		f.params = {"steps": StaircaseRecipe.steps_for_courses(int(p.courses)), "colour": 11}
		f.build_into(world, c, StaircaseRecipe.flight_parts(palette))
	var ts := BrickWorld.ticks_per_stud()
	var tp := BrickWorld.ticks_per_plate()
	var out := []
	for id in world.get_block_count(c):
		var box: Array = world.get_block_ticks(c, id)
		if box.is_empty():
			continue
		if world.get_block_material(c, id) == GLASS_MATERIAL:
			continue
		# (min, size) in ticks.
		var lo: Vector3i = box[0]
		var hi: Vector3i = lo + (box[1] as Vector3i)
		@warning_ignore("integer_division")
		var a := Vector3i(lo.x / ts, lo.y / tp, lo.z / ts)
		@warning_ignore("integer_division")
		var b := Vector3i((hi.x + ts - 1) / ts - 1, (hi.y + tp - 1) / tp - 1, (hi.z + ts - 1) / ts - 1)
		out.append([a, b, BUILDING_MATERIAL_BASE + world.get_block_colour(c, id)])
	world.release_chunk(c)
	return out


## Write a tower into the field with its corner at stud `corner` (x, z), on
## the ground there. `host`: the mine world (terrain_edited). Returns
## {base (plate of its ground floor), lo, hi (its plate box), bricks, cells}.
static func stamp(host: Node, corner: Vector2i, p: Dictionary) -> Dictionary:
	var fx := int(p.x)
	var fz := int(p.z)
	var t_min := 1 << 30
	var t_max := -(1 << 30)
	for z in range(corner.y, corner.y + fz):
		for x in range(corner.x, corner.x + fx):
			var sp := BrickTerrain.surface_plate(x, z)
			t_min = mini(t_min, sp)
			t_max = maxi(t_max, sp)
	# The ground floor on whole courses, a plate over the highest ground.
	var base := (floori(float(t_max + 1) / 3.0) + 1) * 3
	var cells := tower_cells(p)
	var top := base
	for cbox: Array in cells:
		top = maxi(top, base + (cbox[1] as Vector3i).y)
	var ids := _terrain_ids()
	var lo := Vector3i(corner.x, base, corner.y)
	var hi := Vector3i(corner.x + fx - 1, top, corner.y + fz - 1)
	# The plot: cleared above the base, stone under it to the ground.
	host.terrain_edited(BrickTerrain.fill_box(Vector3i(lo.x, base, lo.z), Vector3i(hi.x, top + 6, hi.z), 0, false))
	host.terrain_edited(BrickTerrain.fill_box(Vector3i(lo.x, t_min - FOUNDATION_DEPTH, lo.z),
			Vector3i(hi.x, base - 1, hi.z), int(ids.MAT_STONE), false))
	var n := 0
	var placed := 0
	for cbox: Array in cells:
		var a: Vector3i = cbox[0]
		var b: Vector3i = cbox[1]
		var blo := Vector3i(corner.x + a.x, base + a.y, corner.y + a.z)
		var bhi := Vector3i(corner.x + b.x, base + b.y, corner.y + b.z)
		var res: Dictionary = BrickTerrain.fill_box(blo, bhi, int(cbox[2]), false)
		n += int(res.get("changed", 0))
		# One brick, kept whole (only whole courses of it: a brick off the
		# ground's course lines stays bond cells).
		placed += BrickTerrain.mark_placed(blo, bhi, int(cbox[2]))
		host.terrain_edited(res)
	return {"base": base, "lo": lo, "hi": hi, "bricks": cells.size(), "cells": n, "ground": t_min,
			"placed": placed}
