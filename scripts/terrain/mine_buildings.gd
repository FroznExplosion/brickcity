class_name MineBuildings
extends RefCounted
## BUILDINGS AS GROUND (Docs/TerrainBuildings.md): a city building written
## into the mine world's terrain field, so it IS ground -- dug with the
## pickaxe, shot, collapsing, lit, saved and drawn (the brick overlay's real
## bevels near the eye, the coarse tier far off) by the systems the ground
## already has, with nothing to tell them it is a building.
##
## Two sources, read the same way (built for real into a scratch BrickWorld
## chunk and read back brick by brick, so there is one description of how a
## building is laid):
## - the city's generator (TowerRecipe, as the workshop's TowerBlockout lays
##   it): walls, floors, columns, windows, stairwell, and its rooms furnished
##   the city's way (TowerBlockout._furnish: RoomManifest's furniture, as
##   plain bricks) -- `stamp`;
## - a workshop build (BuildRecipe, its generated towers and catalogue
##   furniture expanded as the city placer does) -- `stamp_build`.
## Each brick becomes the plate cells of its box in the BUILDING material of
## its colour (brick_terrain.h MAT_FIL_BASE + its filament: the city's
## colours, a city brick's strength in the collapse), and is marked one placed
## brick (BrickTerrain.mark_placed) where it fills whole ground courses, so
## it breaks and falls whole. A translucent brick (glass) becomes the GLASS
## material (stage 5): see-through, and light passes it.
##
## The plot is levelled first: the footprint cleared from the building's base
## up past its roof, and stone laid under the base down to the lowest ground
## of the footprint, so the building stands on, and is joined to, the ground.
##
## TOWNS (stage 8): a world with "towns" on gets a few towers in some regions
## (`town_at`), stamped when the player first comes near (`tend_towns`).

## Plates of stone under the base past the footprint's lowest ground.
const FOUNDATION_DEPTH := 3
## brick_terrain.h MAT_FIL_BASE: building material = this + filament index.
const BUILDING_MATERIAL_BASE := 64

static var _mat_ids := {}
static var _glass := -1

## TIPPING (Docs/TerrainBuildings.md 4b): every stamped building, so an edit
## under one can ask whether it still balances. Each {lo, hi, base, weight
## (Vector2i column -> its building cells now), bricks (its stamped bricks,
## [lo, hi, material] in the field), fallen}. Saved with the world
## (to_save / from_save).
static var registry: Array = []
## Balance checks made, buildings let go to tip, columns recounted after
## damage (the weights follow it), for the gates.
static var checks := 0
static var toppled := 0
static var recounted := 0
## Bricks the last toppled building went as (the gate: it breaks landing).
static var last_parts := 0
## Cells of it cleared as no part of a falling course (the last topple).
static var left_over := 0


## The terrain material ids (BrickTerrain's enum, by name: "MAT_STONE").
static func _terrain_ids() -> Dictionary:
	if _mat_ids.is_empty():
		var names := BrickTerrain.material_names()
		for i in names.size():
			_mat_ids["MAT_" + names[i].to_upper().replace(" ", "_")] = i
	return _mat_ids


## The GLASS terrain material (brick_terrain.h MAT_GLASS).
static func glass_material() -> int:
	if _glass < 0:
		_glass = Array(BrickTerrain.material_names()).find("glass")
	return _glass


## A cell of a building: a building material or glass.
static func is_building(m: int) -> bool:
	return m >= BUILDING_MATERIAL_BASE or (m > 0 and m == glass_material())


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
## [lo (stud, plate, stud), hi (inclusive), terrain material, placed].
## `p`: TowerBlockout's parameters ({"x", "z", "courses", "rooms",
## "windows", "stairs", "furnish" (default true), "seed", "program"}).
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
	# INTERIORS (stage 6): its rooms furnished as the city's are -- the
	# manifest's furniture, plain bricks on the floors' studs.
	if bool(p.get("furnish", true)):
		var q := p.duplicate()
		q["seed"] = int(p.get("seed", 1))
		q["program"] = p.get("program", {})
		TowerBlockout._furnish(world, c, palette, q, keep)
	var ymap := course_map(int(p.courses))
	var out := _read_chunk(world, c, ymap)
	if bool(p.get("windows", true)):
		out.append_array(_glaze(world, c, d, ymap))
	world.release_chunk(c)
	if bool(p.get("entrance", true)):
		var e := entrance(p)
		out = _cut(out, e[0], e[1])
	return out


## Plates of an entrance's opening: five bricks, as the city's doorways
## (TowerRecipe: "five bricks clear through a door"), a course of wall over it.
const ENTRANCE_PLATES := 15
## Most steps laid down from an entrance to the ground outside.
const ENTRANCE_STEPS := 4


## The ground storey's way in (the city's towers have none: its people come
## and go by the street's rules, not through a wall): DOOR_WIDE studs in the
## middle of the front (-z) wall, through its thickness, from the ground
## floor up ENTRANCE_PLATES. [lo, hi] in the stamped (ground) plates.
static func entrance(p: Dictionary) -> Array:
	var y := int(course_map(int(p.courses))[TowerRecipe.SLAB_PLATES][0])
	var x0 := (int(p.x) >> 1) - (TowerRecipe.DOOR_WIDE >> 1)
	return [Vector3i(x0, y, 0), Vector3i(x0 + TowerRecipe.DOOR_WIDE - 1, y + ENTRANCE_PLATES - 1,
			TowerRecipe.WALL_THICK - 1)]


## Bricks (tower_cells' form) with box [c0, c1] cut out: a brick across it is
## split into the boxes round it, laid as bond cells (not placed: no longer
## the brick it was).
static func _cut(cells: Array, c0: Vector3i, c1: Vector3i) -> Array:
	var out := []
	for cb: Array in cells:
		var a: Vector3i = cb[0]
		var b: Vector3i = cb[1]
		if b.x < c0.x or a.x > c1.x or b.y < c0.y or a.y > c1.y or b.z < c0.z or a.z > c1.z:
			out.append(cb)
			continue
		var m := int(cb[2])
		# Left and right of it in x, whole; then in front and behind in z,
		# within its x; then under and over in y, within both.
		var ix0 := maxi(a.x, c0.x)
		var ix1 := mini(b.x, c1.x)
		var iz0 := maxi(a.z, c0.z)
		var iz1 := mini(b.z, c1.z)
		if a.x < c0.x:
			out.append([a, Vector3i(c0.x - 1, b.y, b.z), m, false])
		if b.x > c1.x:
			out.append([Vector3i(c1.x + 1, a.y, a.z), b, m, false])
		if a.z < c0.z:
			out.append([Vector3i(ix0, a.y, a.z), Vector3i(ix1, b.y, c0.z - 1), m, false])
		if b.z > c1.z:
			out.append([Vector3i(ix0, a.y, c1.z + 1), Vector3i(ix1, b.y, b.z), m, false])
		if a.y < c0.y:
			out.append([Vector3i(ix0, a.y, iz0), Vector3i(ix1, c0.y - 1, iz1), m, false])
		if b.y > c1.y:
			out.append([Vector3i(ix0, c1.y + 1, iz0), Vector3i(ix1, b.y, iz1), m, false])
	return out


## Most plates a window is tall (a storey's wall band is 18).
const WINDOW_MAX_PLATES := 18


## GLASS in the windows (stage 5): the city draws its panes apart (painted
## windows); here each opening in the outer wall -- a run of air with wall
## above and below it in a perimeter column -- is filled with glass cells,
## above the ground storey (its openings are its doors and shopfronts).
static func _glaze(world: BrickWorld, c: int, d: Vector3i, ymap: Array) -> Array:
	var glass := glass_material()
	if glass <= 0:
		return []
	var out := []
	var y0 := TowerRecipe.STOREY_PLATES + TowerRecipe.SLAB_PLATES
	for z in d.z:
		for x in d.x:
			if x != 0 and z != 0 and x != d.x - 1 and z != d.z - 1:
				continue
			var y := y0
			while y < d.y:
				if world.is_solid(c, Vector3i(x, y, z)):
					y += 1
					continue
				var a := y
				while y < d.y and not world.is_solid(c, Vector3i(x, y, z)):
					y += 1
				if y >= d.y or y - a > WINDOW_MAX_PLATES or not world.is_solid(c, Vector3i(x, a - 1, z)):
					continue
				var ya: Array = ymap[clampi(a, 0, ymap.size() - 1)]
				var yb: Array = ymap[clampi(y - 1, 0, ymap.size() - 1)]
				out.append([Vector3i(x, int(ya[0]), z), Vector3i(x, int(yb[1]), z), glass, false])
	return out


## A workshop build's bricks, as tower_cells gives them. Its towers and its
## catalogue furniture are expanded first (CityPlacer.hold's way). Frame 0
## only (a build of several frames -- moving parts -- is laid as its first).
static func recipe_cells(r: BuildRecipe) -> Array:
	r = TowerBlockout.flatten(AssetPlacements.expand(r))
	var world := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(world)
	var c := world.create_chunk(Vector3i.ZERO, r.chunk_dims() + Vector3i.ONE)
	r.build(world, c, palette)
	var out := _read_chunk(world, c, [])
	world.release_chunk(c)
	return out


## Every brick of chunk `c` as [lo, hi, material, placed]. `ymap`: a tower's
## course_map, or [] (a build's plates as they are: a brick is placed when it
## fills whole ground courses).
static func _read_chunk(world: BrickWorld, c: int, ymap: Array) -> Array:
	var ts := BrickWorld.ticks_per_stud()
	var tp := BrickWorld.ticks_per_plate()
	var glass := glass_material()
	var out := []
	for id in world.get_block_count(c):
		var box: Array = world.get_block_ticks(c, id)
		if box.is_empty():
			continue
		# (min, size) in ticks.
		var lo: Vector3i = box[0]
		var hi: Vector3i = lo + (box[1] as Vector3i)
		@warning_ignore("integer_division")
		var a := Vector3i(lo.x / ts, lo.y / tp, lo.z / ts)
		@warning_ignore("integer_division")
		var b := Vector3i((hi.x + ts - 1) / ts - 1, (hi.y + tp - 1) / tp - 1, (hi.z + ts - 1) / ts - 1)
		var mat := BUILDING_MATERIAL_BASE + world.get_block_colour(c, id)
		if glass > 0 and BrickWorld.is_material_translucent(world.get_block_material(c, id)):
			mat = glass
		if ymap.is_empty():
			out.append([a, b, mat, posmod(a.y, 3) == 0 and posmod(b.y + 1, 3) == 0])
			continue
		# Onto the ground's courses (course_map): a slab's 2 plates are one
		# 3-plate course, so every wall brick sits on the ground's course
		# lines and is kept whole. A slab's lower layer is laid but not
		# placed: its upper layer's bricks are that course's bricks.
		var ya: Array = ymap[clampi(a.y, 0, ymap.size() - 1)]
		var yb: Array = ymap[clampi(b.y, 0, ymap.size() - 1)]
		var place := not (bool(ya[2]) and int(ya[3]) == 0)
		out.append([Vector3i(a.x, int(ya[0]), a.z), Vector3i(b.x, int(yb[1]), b.z), mat, place])
	return out


## Write a tower into the field with its corner at stud `corner` (x, z), on
## the ground there. `host`: the mine world (terrain_edited). Returns
## {base (plate of its ground floor), lo, hi (its plate box), bricks, cells}.
static func stamp(host: Node, corner: Vector2i, p: Dictionary) -> Dictionary:
	var info := stamp_cells(host, corner, tower_cells(p))
	if not info.is_empty():
		info.merge(fit_out(host, corner, int(info.base), p))
	return info


# ---------------------------------------------------------------------------
# Fittings (stage 6): the wiring's devices (Docs/MineWiring.md), not bricks.

## Doors in every interior doorway and a lamp with its lever in every room,
## as the mine world's wiring devices (MineWiring): a door opens with RMB (or
## power), a lever lights its lamp. Lamps start dark: a lit lamp is a light
## of its own (MineWiring: fine for tens, not a town's hundreds). Returns
## {"doors", "lamps"}. Nothing when the world has no wiring.
static func fit_out(host: Node, corner: Vector2i, base: int, p: Dictionary) -> Dictionary:
	var wiring = host.get("wiring")
	if wiring == null:
		return {"doors": 0, "lamps": 0}
	var ymap := course_map(int(p.courses))
	var at := func(x: int, y: int, z: int) -> Vector3i:
		return Vector3i(corner.x + x, base + int(ymap[clampi(y, 0, ymap.size() - 1)][0]), corner.y + z)
	var keep: Array = []
	var stair := TowerBlockout.stair_rect(p)
	if stair.size != Vector2i.ZERO:
		keep.append(stair)
	var doors := 0
	if bool(p.get("rooms", true)):
		for dw: Dictionary in TowerRecipe.doorways(int(p.x), int(p.z), int(p.courses), keep, true):
			doors += _hang_doors(wiring, dw, at)
	# The way in: a double door in the entrance (in the wall's outer layer).
	if bool(p.get("entrance", true)):
		var e := entrance(p)
		var e0: Vector3i = e[0]
		var e1: Vector3i = e[1]
		var to_ground := func(x: int, y: int, z: int) -> Vector3i:
			return Vector3i(corner.x + x, base + y, corner.y + z)
		doors += _hang_doors(wiring, {"span": Vector2i(e0.x, e1.x + 1), "line": e0.z, "floor_y": e0.y,
				"along_z": false}, to_ground)
		# Steps up to it, a brick each, two studs deep, down to the ground
		# outside (stone, filling only air, so ground already high stays).
		var sill := base + e0.y
		var stone := int(_terrain_ids().get("MAT_STONE", 4))
		for k in ENTRANCE_STEPS:
			var top := sill - 1 - 3 * k
			var z1 := corner.y - 1 - 2 * k
			var low := 1 << 30
			for x in range(corner.x + e0.x, corner.x + e1.x + 1):
				low = mini(low, BrickTerrain.surface_plate(x, z1))
			if low >= top:
				break
			host.terrain_edited(BrickTerrain.fill_box(Vector3i(corner.x + e0.x, low, z1 - 1),
					Vector3i(corner.x + e1.x, top, z1), stone, true))
	var lamps := 0
	if bool(p.get("rooms", true)):
		for room: Room in RoomManifest.rooms_for(int(p.x), int(p.z), int(p.courses), int(p.get("seed", 1)),
				p.get("program", {})):
			lamps += _lamp_in(wiring, room, at)
	return {"doors": doors, "lamps": lamps}


## A doorway (TowerRecipe.doorways) is DOOR_WIDE studs: two 2-stud doors,
## hinged at its two ends, meeting in the middle (a double door), in the
## wall's near layer. How many it hung.
static func _hang_doors(wiring, dw: Dictionary, at: Callable) -> int:
	var span: Vector2i = dw.span
	var line := int(dw.line)
	var y := int(dw.floor_y)
	var n := 0
	var hung := []
	if bool(dw.along_z):
		# A wall along z: doors face +x / -x; +x's right is +z.
		hung = [[at.call(line, y, span.x), 0], [at.call(line, y, span.y - 1), 1]]
	else:
		# A wall along x: -z's right is +x, +z's is -x.
		hung = [[at.call(span.x, y, line), 3], [at.call(span.y - 1, y, line), 2]]
	if span.y - span.x < 4:
		hung = [hung[0]]
	for h: Array in hung:
		if wiring.place_device(h[0], &"door", false, false, int(h[1])):
			_stream(wiring, h[0])
			n += 1
	return n


## ROOM STREAMING for a building's fittings (Docs/TerrainBuildings.md 6d):
## their meshes drawn only within FITTINGS_RANGE_M of the eye, a lamp's light
## fading out by LIGHT_FADE_M -- the renderer culls both, so a town's
## hundreds of doors and lamps cost nothing far off. Their colliders stay
## (a door is shut or open wherever it is seen from).
const FITTINGS_RANGE_M := 70.0
const LIGHT_FADE_M := 28.0


static func _stream(wiring, c: Vector3i) -> void:
	var d: Dictionary = wiring.devices.get(c, {})
	var node: Node = d.get("node")
	if node == null:
		return
	for g in node.find_children("*", "GeometryInstance3D", true, false):
		(g as GeometryInstance3D).visibility_range_end = FITTINGS_RANGE_M
		(g as GeometryInstance3D).visibility_range_end_margin = 5.0
	for l in node.find_children("*", "Light3D", true, false):
		(l as Light3D).distance_fade_enabled = true
		(l as Light3D).distance_fade_begin = LIGHT_FADE_M
		(l as Light3D).distance_fade_length = 8.0


## A lamp on the floor of `room`, near its middle, a lever beside it (the
## lever touching it lights it). 1 when laid.
static func _lamp_in(wiring, room: Room, at: Callable) -> int:
	var mid := Vector2(room.lo.x + room.size.x * 0.5, room.lo.z + room.size.z * 0.5)
	var spots := []
	for x in range(room.lo.x, room.lo.x + room.size.x):
		for z in range(room.lo.z, room.lo.z + room.size.z):
			spots.append([Vector2(x + 0.5, z + 0.5).distance_squared_to(mid), x, z])
	spots.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for sp: Array in spots:
		var c: Vector3i = at.call(int(sp[1]), room.lo.y, int(sp[2]))
		if not wiring.can_place_device(c, &"lamp"):
			continue
		for side: Vector3i in MineWiring.SIDES:
			if wiring.can_place_device(c + side, &"lever"):
				wiring.place_device(c, &"lamp")
				wiring.place_device(c + side, &"lever")
				_stream(wiring, c)
				_stream(wiring, c + side)
				return 1
	return 0


## A workshop build (a BuildRecipe file) written into the field, as `stamp`.
## {} when it holds no bricks.
static func stamp_build(host: Node, corner: Vector2i, path: String) -> Dictionary:
	var r := BuildRecipe.load_from(path)
	if r == null or not r.has_content():
		return {}
	return stamp_cells(host, corner, recipe_cells(r))


## Bricks (tower_cells' form) written into the field at `corner`.
static func stamp_cells(host: Node, corner: Vector2i, cells: Array) -> Dictionary:
	if cells.is_empty():
		return {}
	var fx := 1
	var fz := 1
	var top0 := 0
	for cbox: Array in cells:
		fx = maxi(fx, (cbox[1] as Vector3i).x + 1)
		fz = maxi(fz, (cbox[1] as Vector3i).z + 1)
		top0 = maxi(top0, (cbox[1] as Vector3i).y)
	var t_min := 1 << 30
	var t_max := -(1 << 30)
	for z in range(corner.y, corner.y + fz):
		for x in range(corner.x, corner.x + fx):
			var sp := BrickTerrain.surface_plate(x, z)
			t_min = mini(t_min, sp)
			t_max = maxi(t_max, sp)
	# The ground floor on whole courses, a plate over the highest ground.
	var base := (floori(float(t_max + 1) / 3.0) + 1) * 3
	var top := base + top0
	var ids := _terrain_ids()
	var lo := Vector3i(corner.x, base, corner.y)
	var hi := Vector3i(corner.x + fx - 1, top, corner.y + fz - 1)
	# The plot: cleared above the base, stone under it to the ground.
	host.terrain_edited(BrickTerrain.fill_box(Vector3i(lo.x, base, lo.z), Vector3i(hi.x, top + 6, hi.z), 0, false))
	host.terrain_edited(BrickTerrain.fill_box(Vector3i(lo.x, t_min - FOUNDATION_DEPTH, lo.z),
			Vector3i(hi.x, base - 1, hi.z), int(ids.get("MAT_STONE", 4)), false))
	var n := 0
	var placed := 0
	var glass_cells := 0
	var glass := glass_material()
	var laid := []
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
		laid.append([blo, bhi, int(cbox[2])])
		if int(cbox[2]) == glass:
			glass_cells += int(res.get("changed", 0))
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
	registry.append({"lo": lo, "hi": hi, "base": base, "weight": weight, "bricks": laid, "fallen": false})
	return {"base": base, "lo": lo, "hi": hi, "bricks": cells.size(), "cells": n, "ground": t_min,
			"placed": placed, "glass": glass_cells}


# ---------------------------------------------------------------------------
# Tipping.

## The ground changed (`res`, an edit's result). An edit INTO a building
## recounts the columns it reached (its weight follows the damage: a side
## shot away moves its middle). Then, if the edit reached its base or changed
## its weight, it is asked whether it still balances. Its weight's middle
## must lie inside what holds it -- the columns whose bottom brick still
## stands on solid ground. If it does not, the whole building is let go as
## ONE piece of its own bricks (ground_collapse's falling pieces, at a city
## brick's strength so it breaks where it lands): resting on what is left of
## its support, it leans over the edge and falls. Tension alone (the survey)
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
		if ehi.x < lo.x - 2 or elo.x > hi.x + 2 or ehi.z < lo.z - 2 or elo.z > hi.z + 2 or elo.y > hi.y:
			continue
		var changed := false
		var base := int(b.base)
		# Its far facade is made again (MineBuildingsFar).
		if ehi.y >= base:
			b["far_dirty"] = true
		if ehi.y >= base:
			for z in range(maxi(elo.z, lo.z), mini(ehi.z, hi.z) + 1):
				for x in range(maxi(elo.x, lo.x), mini(ehi.x, hi.x) + 1):
					var k := Vector2i(x, z)
					if not b.weight.has(k):
						continue
					var w := _column_weight(x, z, base, hi.y)
					recounted += 1
					if w != int(b.weight[k]):
						b.weight[k] = w
						changed = true
		if not changed and elo.y > base + 3:
			continue
		checks += 1
		if not balances(b):
			_topple(host, b)


## A column's building cells now, from its base to its top.
static func _column_weight(x: int, z: int, y0: int, y1: int) -> int:
	var n := 0
	for y in range(y0, y1 + 1):
		if is_building(BrickTerrain.solid_at(x, y, z)):
			n += 1
	return n


## Does it still stand on its own support?
static func balances(b: Dictionary) -> bool:
	var base := int(b.base)
	var sum := Vector2.ZERO
	var mass := 0.0
	var support := PackedVector2Array()
	for k: Vector2i in b.weight:
		var w := float(b.weight[k])
		if w <= 0.0:
			continue
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
	# Which way it would go: from what holds it toward its middle.
	var held := Vector2.ZERO
	for v in support:
		held += v
	b["lean"] = middle - held / support.size()
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


## Radians a second a toppled building is let go turning at (_topple).
const TIP_SPIN := 0.35


## The parts a falling piece is laid in (ground_collapse._part), largest first.
const _PARTS := [Vector2i(4, 2), Vector2i(2, 4), Vector2i(2, 2), Vector2i(2, 1), Vector2i(1, 2), Vector2i(1, 1)]


## Let the whole building go as one piece, in ITS OWN bricks: each stamped
## brick still whole in the field, a course at a time, in the falling parts'
## sizes (a long wall brick as 2x4s along it); bonded across courses as it
## was laid, so a landing shears it where it hits (PlanetPieces.
## _break_on_landing) rather than it lying whole. Any other whole course
## cell of it left (bricks cut by damage) goes as a 1x1.
static func _topple(host: Node, b: Dictionary) -> void:
	var collapse = host.get("collapse")
	if collapse == null:
		return
	b.fallen = true
	var taken := {}
	var g := PackedInt32Array()
	for br: Array in b.get("bricks", []):
		var blo: Vector3i = br[0]
		var bhi: Vector3i = br[1]
		var m := int(br[2])
		if posmod(blo.y, 3) != 0 or posmod(bhi.y + 1, 3) != 0:
			continue
		for y in range(blo.y, bhi.y + 1, 3):
			_tile_course(blo.x, bhi.x, blo.z, bhi.z, y, m, taken, g)
	var lo: Vector3i = b.lo
	var hi: Vector3i = b.hi
	for c in range(floori(float(lo.y) / 3.0), floori(float(hi.y) / 3.0) + 1):
		var y := c * 3
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				if taken.has(Vector3i(x, y, z)):
					continue
				var m := BrickTerrain.solid_at(x, y, z)
				if is_building(m) and _whole(x, y, z, m):
					g.append_array([x, y, z, 1, 1, m])
					taken[Vector3i(x, y, z)] = true
	if g.is_empty():
		return
	# What is not a whole course of it (a glass run, a furniture plate, a
	# stair's step) goes too, as nothing: left in the ground it held the
	# falling building up from inside, where it had stood.
	var runs := PackedInt32Array()
	for z in range(lo.z, hi.z + 1):
		for x in range(lo.x, hi.x + 1):
			var y := lo.y
			while y <= hi.y:
				if taken.has(Vector3i(x, floori(float(y) / 3.0) * 3, z)) 						or not is_building(BrickTerrain.solid_at(x, y, z)):
					y += 1
					continue
				var y0 := y
				while y <= hi.y and not taken.has(Vector3i(x, floori(float(y) / 3.0) * 3, z)) 						and is_building(BrickTerrain.solid_at(x, y, z)):
					y += 1
				runs.append_array([x, z, y0, y - 1])
	if not runs.is_empty():
		var res: Dictionary = BrickTerrain.clear_runs(runs)
		left_over = int(res.get("removed", 0))
		host.terrain_edited(res)
	toppled += 1
	@warning_ignore("integer_division")
	last_parts = g.size() / 6
	# Started leaning its way: let go from rest, balanced on the edge, it can
	# lie still long enough to count as settled (and be put away) before it
	# tips. A slow turn about the edge, top toward its middle's side.
	var lean: Vector2 = b.get("lean", Vector2.ZERO)
	var spin := Vector3.ZERO
	if lean.length() > 0.01:
		spin = Vector3.UP.cross(Vector3(lean.x, 0.0, lean.y).normalized()) * TIP_SPIN
	collapse.call("_let_group_go", g, 1.0, spin)
	# Rubble lying on it or in it (a shot brick on its roof) is frozen still:
	# immovable, it held the whole building up. Woken, it falls with it.
	var pieces = collapse.get("pieces")
	if pieces != null and host is Node3D:
		var stud := BrickWorld.get_stud_metres()
		var plate := BrickWorld.get_plate_metres()
		var a := Vector3(lo.x * stud, lo.y * plate, lo.z * stud)
		var size := Vector3((hi.x - lo.x + 1) * stud, (hi.y - lo.y + 1) * plate, (hi.z - lo.z + 1) * stud)
		pieces.call("support_gone", AABB((host as Node3D).to_global(a), size).grow(0.5))


## A course cell all of material `m` (its 3 plates).
static func _whole(x: int, y: int, z: int, m: int) -> bool:
	return BrickTerrain.solid_at(x, y, z) == m and BrickTerrain.solid_at(x, y + 1, z) == m \
			and BrickTerrain.solid_at(x, y + 2, z) == m


## One brick's course [x0..x1] x [z0..z1] at plate y, in falling parts: at
## each free whole cell the largest part that fits whole and free.
static func _tile_course(x0: int, x1: int, z0: int, z1: int, y: int, m: int, taken: Dictionary,
		g: PackedInt32Array) -> void:
	var whole := {}
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			if not taken.has(Vector3i(x, y, z)) and _whole(x, y, z, m):
				whole[Vector2i(x, z)] = true
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			if not whole.has(Vector2i(x, z)):
				continue
			for s: Vector2i in _PARTS:
				var fits := true
				for dz in s.y:
					for dx in s.x:
						if not whole.has(Vector2i(x + dx, z + dz)):
							fits = false
				if not fits:
					continue
				for dz in s.y:
					for dx in s.x:
						whole.erase(Vector2i(x + dx, z + dz))
						taken[Vector3i(x + dx, y, z + dz)] = true
				g.append_array([x, y, z, s.x, s.y, m])
				break


# ---------------------------------------------------------------------------
# Saved with the world.

static func to_save() -> Array:
	var out := []
	for b: Dictionary in registry:
		var w := []
		for k: Vector2i in b.weight:
			w.append_array([k.x, k.y, int(b.weight[k])])
		var br := []
		for e: Array in b.get("bricks", []):
			var l: Vector3i = e[0]
			var h: Vector3i = e[1]
			br.append_array([l.x, l.y, l.z, h.x, h.y, h.z, int(e[2])])
		var lo: Vector3i = b.lo
		var hi: Vector3i = b.hi
		out.append({"lo": [lo.x, lo.y, lo.z], "hi": [hi.x, hi.y, hi.z], "base": int(b.base),
				"weight": w, "bricks": br, "fallen": bool(b.fallen)})
	return out


static func from_save(data) -> void:
	registry.clear()
	if not data is Array:
		return
	for d in data:
		if not d is Dictionary:
			continue
		var w := {}
		var wa: Array = d.get("weight", [])
		for i in range(0, wa.size() - 2, 3):
			w[Vector2i(int(wa[i]), int(wa[i + 1]))] = int(wa[i + 2])
		var bricks := []
		var ba: Array = d.get("bricks", [])
		for i in range(0, ba.size() - 6, 7):
			bricks.append([Vector3i(int(ba[i]), int(ba[i + 1]), int(ba[i + 2])),
					Vector3i(int(ba[i + 3]), int(ba[i + 4]), int(ba[i + 5])), int(ba[i + 6])])
		var lo: Array = d.get("lo", [0, 0, 0])
		var hi: Array = d.get("hi", [0, 0, 0])
		registry.append({"lo": Vector3i(int(lo[0]), int(lo[1]), int(lo[2])),
				"hi": Vector3i(int(hi[0]), int(hi[1]), int(hi[2])), "base": int(d.get("base", 0)),
				"weight": w, "bricks": bricks, "fallen": bool(d.get("fallen", false))})


# ---------------------------------------------------------------------------
# Towns (stage 8).

## Studs a side of a town region: at most one town each.
const TOWN_REGION := 768
## Share of regions with a town.
const TOWN_CHANCE := 0.4
## A town's towers: a grid of plots this many studs apart (a street between).
const PLOT := 32
## Most ground a plot may climb (plates) and still be built on.
const PLOT_SLOPE := 18
## How near (studs) the player comes before a town is laid.
const TOWN_NEAR := 260
## Regions whose town is laid (or found to have none), "x,z" -> true.
static var towns_done := {}
## Towers waiting to be stamped, one a tend: [corner, params].
static var _queue: Array = []


## The town of region `r`, or {}: {"plots": [[corner, params], ...], "mid"},
## all from the seed. Up to 3 x 3 plots round a spot near the region's
## middle, each a tower of 2..10 floors (taller nearer the middle),
## footprints 16..24 studs.
static func town_at(seed: int, r: Vector2i) -> Dictionary:
	var s := seed & 0x3FFFFFFF
	if BrickTerrain.hashf(r.x, r.y, s ^ 0x70E1) >= TOWN_CHANCE:
		return {}
	var half := TOWN_REGION >> 1
	var mid := r * TOWN_REGION + Vector2i(half, half) \
			+ Vector2i(int((BrickTerrain.hashf(r.x, r.y, s ^ 0x51) - 0.5) * half),
					int((BrickTerrain.hashf(r.x, r.y, s ^ 0x52) - 0.5) * half))
	var n := 1 + int(BrickTerrain.hashf(r.x, r.y, s ^ 0x53) * 3.0)   # 1..3 a side
	var plots := []
	for j in n:
		for i in n:
			var k := s ^ (i * 7 + j * 131)
			if n > 1 and BrickTerrain.hashf(r.x * 9 + i, r.y * 9 + j, k ^ 0x54) < 0.2:
				continue   # an open lot
			var fx := 16 + 4 * int(BrickTerrain.hashf(r.x + i, r.y + j, k ^ 0x55) * 3.0)
			var fz := 16 + 4 * int(BrickTerrain.hashf(r.x + i, r.y + j, k ^ 0x56) * 3.0)
			var off := Vector2(i - (n - 1) * 0.5, j - (n - 1) * 0.5)
			var centre := 1.0 - (absf(off.x) + absf(off.y)) / float(n)
			var floors := clampi(2 + int(BrickTerrain.hashf(r.x + i, r.y + j, k ^ 0x57) * 5.0 * (0.5 + centre))
					+ int(centre * 3.0), 2, 10)
			var corner := mid + Vector2i(int(off.x * PLOT) - (fx >> 1), int(off.y * PLOT) - (fz >> 1))
			plots.append([corner, {"x": fx, "z": fz, "courses": floors * TowerRecipe.COURSES_PER_FLOOR,
					"rooms": true, "windows": true, "stairs": true, "furnish": true,
					"seed": int(BrickTerrain.hashf(r.x + i, r.y + j, k) * 100000.0)}])
	return {"plots": plots, "mid": mid}


## Lay the towns near stud `at` that are not laid yet: their towers queued,
## one stamped a call (~0.1 s each), on level dry land only (a plot over the
## sea or up a slope is left empty). `sea_plate`: the sea's surface plate.
## Returns how many it stamped.
static func tend_towns(host: Node, seed: int, at: Vector2i, sea_plate: int) -> int:
	if _queue.is_empty():
		var r0 := Vector2i(floori(float(at.x) / TOWN_REGION), floori(float(at.y) / TOWN_REGION))
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var r := r0 + Vector2i(dx, dz)
				var key := "%d,%d" % [r.x, r.y]
				if towns_done.has(key):
					continue
				var t := town_at(seed, r)
				if t.is_empty():
					towns_done[key] = true
					continue
				if Vector2(t.mid).distance_to(Vector2(at)) > TOWN_NEAR:
					continue
				towns_done[key] = true
				for pl: Array in t.plots:
					_queue.append(pl)
	if _queue.is_empty():
		return 0
	var pl: Array = _queue.pop_front()
	var corner: Vector2i = pl[0]
	var p: Dictionary = pl[1]
	var t_min := 1 << 30
	var t_max := -(1 << 30)
	for z in range(corner.y, corner.y + int(p.z), 2):
		for x in range(corner.x, corner.x + int(p.x), 2):
			var sp := BrickTerrain.surface_plate(x, z)
			t_min = mini(t_min, sp)
			t_max = maxi(t_max, sp)
	if t_max - t_min > PLOT_SLOPE or t_min <= sea_plate + 2:
		return 0
	stamp(host, corner, p)
	return 1


## Towers still waiting to be stamped.
static func towns_queued() -> int:
	return _queue.size()


static func towns_to_save() -> Array:
	return towns_done.keys()


static func towns_from_save(data) -> void:
	towns_done.clear()
	_queue.clear()
	if data is Array:
		for k in data:
			towns_done[str(k)] = true
