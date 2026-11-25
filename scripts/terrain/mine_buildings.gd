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

## TIPPING (Docs/TerrainBuildings.md 4b): every stamped building, so an edit
## under one can ask whether it still balances. Each {lo, hi, base, weight
## (Vector2i column -> cells stamped there), fallen}.
static var registry: Array = []
## Balance checks made and buildings let go to tip, for the gate.
static var checks := 0
static var toppled := 0


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


## The building's plates onto the ground's: building plate -> [first ground
## plate, last ground plate, in a slab, layer in its band]. The ground's
## course is 3 plates; a storey is 6 courses and a 2-plate slab (20 plates),
## so storeys drift off the ground's course lines. Here each slab (and the
## base) is one whole 3-plate course: a storey is 21 plates, 7 courses, and
## every course of bricks lines up with the ground's (Docs/TerrainBuildings.md
## 4). The floors are a plate thicker for it.
static func course_map(courses: int) -> Array:
	var out := []
	var t := 0
	for band: Dictionary in TowerRecipe.layout(courses):
		var n := int(band.plates)
		var slab: bool = band.kind == "base" or band.kind == "slab"
		for o in n:
			if slab:
				out.append([t, t + 2, true, o])
			else:
				out.append([t + o, t + o, false, o])
		t += 3 if slab else n
	return out


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
	var ymap := course_map(int(p.courses))
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
		# Onto the ground's courses (course_map): a slab's 2 plates are one
		# 3-plate course, so every wall brick sits on the ground's course
		# lines and is kept whole. A slab's lower layer is laid but not
		# placed: its upper layer's bricks are that course's bricks.
		var ya: Array = ymap[clampi(a.y, 0, ymap.size() - 1)]
		var yb: Array = ymap[clampi(b.y, 0, ymap.size() - 1)]
		var place := not (bool(ya[2]) and int(ya[3]) == 0)
		out.append([Vector3i(a.x, int(ya[0]), a.z), Vector3i(b.x, int(yb[1]), b.z),
				BUILDING_MATERIAL_BASE + world.get_block_colour(c, id), place])
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
		if bool(cbox[3]):
			placed += BrickTerrain.mark_placed(blo, bhi, int(cbox[2]))
		host.terrain_edited(res)
	# Its weight by column, for the balance (after_edit).
	var weight := {}
	for cbox: Array in cells:
		var a: Vector3i = cbox[0]
		var b: Vector3i = cbox[1]
		var h := b.y - a.y + 1
		for z in range(a.z, b.z + 1):
			for x in range(a.x, b.x + 1):
				var k := Vector2i(corner.x + x, corner.y + z)
				weight[k] = int(weight.get(k, 0)) + h
	registry.append({"lo": lo, "hi": hi, "base": base, "weight": weight, "fallen": false})
	return {"base": base, "lo": lo, "hi": hi, "bricks": cells.size(), "cells": n, "ground": t_min,
			"placed": placed}


# ---------------------------------------------------------------------------
# Tipping.

## The ground changed (`res`, an edit's result): any building whose base the
## edit reached is asked whether it still balances. Its weight's middle (the
## columns' stamped cells) must lie inside what holds it -- the columns whose
## bottom brick still stands on solid ground. If it does not, the whole
## building is let go as ONE piece (ground_collapse's falling pieces): resting
## on what is left of its support, it leans over the edge and falls, as a
## building does that is undermined on one side. Tension alone (the survey)
## never tips anything: whole bricks bridge the gap and it hangs.
static func after_edit(host: Node, res: Dictionary) -> void:
	if registry.is_empty() or not res.has("box_lo"):
		return
	var elo: Vector3i = res.box_lo
	var ehi: Vector3i = res.box_hi
	for b: Dictionary in registry:
		if bool(b.fallen):
			continue
		var lo: Vector3i = b.lo
		var hi: Vector3i = b.hi
		# Under or round its base: two studs out, below its ground floor.
		if ehi.x < lo.x - 2 or elo.x > hi.x + 2 or ehi.z < lo.z - 2 or elo.z > hi.z + 2 \
				or elo.y > int(b.base) + 3:
			continue
		checks += 1
		if not balances(b):
			_topple(host, b)


## Does it still stand on its own support?
static func balances(b: Dictionary) -> bool:
	var base := int(b.base)
	var sum := Vector2.ZERO
	var mass := 0.0
	var support := PackedVector2Array()
	for k: Vector2i in b.weight:
		var w := float(b.weight[k])
		sum += (Vector2(k) + Vector2(0.5, 0.5)) * w
		mass += w
		# Its bottom brick there, on solid ground.
		if BrickTerrain.solid_at(k.x, base, k.y) != 0 and BrickTerrain.solid_at(k.x, base - 1, k.y) != 0:
			for c in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
				support.append(Vector2(k) + c)
	if mass <= 0.0 or support.is_empty():
		return true   # nothing under it: the survey drops it whole
	var middle := sum / mass
	var hull := Geometry2D.convex_hull(support)
	if hull.size() < 3:
		return false
	# Inside, and not on the edge (a weight over the edge falls).
	return Geometry2D.is_point_in_polygon(middle, hull) and _inside_by(middle, hull, 0.25)


## At least `margin` studs inside every edge of the (closed) hull.
static func _inside_by(p: Vector2, hull: PackedVector2Array, margin: float) -> bool:
	for i in hull.size() - 1:
		var a := hull[i]
		var c := hull[i + 1]
		if Geometry2D.get_closest_point_to_segment(p, a, c).distance_to(p) < margin:
			return false
	return true


## Let the whole building go as one piece: every whole course cell of its
## materials in its box (ground_collapse lets a group go a course tall).
static func _topple(host: Node, b: Dictionary) -> void:
	var collapse = host.get("collapse")
	if collapse == null:
		return
	b.fallen = true
	var lo: Vector3i = b.lo
	var hi: Vector3i = b.hi
	var g := PackedInt32Array()
	var c0 := floori(float(lo.y) / 3.0)
	var c1 := floori(float(hi.y) / 3.0)
	for c in range(c0, c1 + 1):
		var y := c * 3
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				var m := BrickTerrain.solid_at(x, y, z)
				if m < BUILDING_MATERIAL_BASE:
					continue
				if BrickTerrain.solid_at(x, y + 1, z) != m or BrickTerrain.solid_at(x, y + 2, z) != m:
					continue
				g.append_array([x, y, z, 1, 1, m])
	if g.is_empty():
		return
	toppled += 1
	collapse.call("_let_group_go", g)
