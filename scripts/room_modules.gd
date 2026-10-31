class_name RoomModules
extends RefCounted

## The module library (Docs/RoomModules.md section 3.1, stage 2): every build
## with its module on, read from its bricks and its record, turned four ways,
## as the grow generator (RoomGrow) asks for it.
##
## A module's record is found again from its bricks here, not trusted from the
## save: an old save, or one made before a connector rule changed, still gives
## the connectors its bricks have. The links, kinds and marks set by hand are
## the record's.
##
## One module, as the library has it:
##   {name, rules, turns: [one per quarter turn, see _turn]}

## Where a module's rules start (Docs/RoomModules.md 1).
const RULES := {"on": false, "role": "room", "min": 0, "max": -1, "weight": 1.0, "storeys": "any"}
## Probes put their own modules here (Engine meta: a scene load resets class
## statics) instead of the library folders.
const META_RECIPES := "room_modules_recipes"


## Every module in the build libraries (buildings and rooms, shipped and the
## player's), or the probe's own when it set some (use_recipes).
static func library() -> Array:
	var recipes := []
	if Engine.has_meta(META_RECIPES):
		recipes = Engine.get_meta(META_RECIPES)
	else:
		for kind in ["building", "room"]:
			for path in BuildRecipe.library(kind):
				var r := BuildRecipe.load_from(path)
				if r != null and bool((r.meta.get("module", {}) as Dictionary).get("on", false)):
					recipes.append(r)
	return from_recipes(recipes)


## A probe's modules in place of the library folders; [] puts the folders back.
static func use_recipes(recipes: Array) -> void:
	if recipes.is_empty():
		Engine.remove_meta(META_RECIPES)
	else:
		Engine.set_meta(META_RECIPES, recipes)


static func from_recipes(recipes: Array) -> Array:
	var out := []
	for r: BuildRecipe in recipes:
		var m := make(r)
		if not m.is_empty():
			out.append(m)
	return out


## One build as a module, or {} when it cannot be one: its module is off, it
## has no rooms found, or it is built in more than one grid (a turn of a
## sideways grid is not done yet, BuildRecipe.turned).
static func make(r: BuildRecipe) -> Dictionary:
	var rules := RULES.duplicate()
	rules.merge(r.meta.get("module", {}), true)
	if not bool(rules.on) or not r.is_single_frame() or r.is_empty():
		return {}
	r = with_floor(r)
	var rec := refresh(r)
	if (rec.spaces as Array).is_empty():
		return {}
	var frame := _turn_frame(r)
	var turns := []
	for k in 4:
		turns.append(_turn(r, r.turned(k), rec, k, frame[0], frame[1]))
	return {"name": r.name, "rules": rules, "turns": turns}


# ---------------------------------------------------------------------------
# A build's rooms from its recipe alone.

## A module built on the workshop's baseplate stands on it: its lowest bricks
## are on row 1 and its rooms' floor is the baseplate, which is not in the
## recipe. Such a build gets a floor of its own on row 0 -- under every column
## it has bricks in and every column they close round -- so it is a whole room
## wherever the generator puts it, on the ground or up a stair. Any other build
## comes back as it is.
static func with_floor(r: BuildRecipe) -> BuildRecipe:
	var b := r.bounds()
	var lo: Vector3i = b[0]
	var size: Vector3i = b[1]
	if lo.y != 1:
		return r
	var under := footprint(r)
	var out := r.turned(0)
	var colour := 0
	for i in r.size():
		if r.role_of(i) == BuildRecipe.Role.STRUCTURE:
			colour = r.colour_of(i)
			break
	# Laid in the biggest square plates that fit.
	for n in [4, 2, 1]:
		for z in range(lo.z, lo.z + size.z):
			for x in range(lo.x, lo.x + size.x):
				var all := true
				for dz in n:
					for dx in n:
						if not under.has(Vector2i(x + dx, z + dz)):
							all = false
				if not all:
					continue
				for dz in n:
					for dx in n:
						under.erase(Vector2i(x + dx, z + dz))
				out.add("plate_%dx%d" % [n, n], Vector3i(x, 0, z), colour)
	return out


## The columns a build stands on: every column its structure bricks are in and
## every column they close round (what a flood from outside its box does not
## reach without crossing a brick). Vector2i -> true. An outline drawn with
## Sketch or Walls gives the floor plan inside it.
static func footprint(r: BuildRecipe) -> Dictionary:
	var b := r.bounds()
	var lo: Vector3i = b[0]
	var size: Vector3i = b[1]
	var foot := {}
	for i in r.size():
		if r.role_of(i) != BuildRecipe.Role.STRUCTURE:
			continue
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for z in s.z:
			for x in s.x:
				foot[Vector2i(c.x + x, c.z + z)] = true
	var x0 := lo.x - 1
	var z0 := lo.z - 1
	var x1 := lo.x + size.x
	var z1 := lo.z + size.z
	var outside := {}
	var todo: Array[Vector2i] = [Vector2i(x0, z0)]
	outside[todo[0]] = true
	while not todo.is_empty():
		var c: Vector2i = todo.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < x0 or n.y < z0 or n.x > x1 or n.y > z1 or outside.has(n) or foot.has(n):
				continue
			outside[n] = true
			todo.append(n)
	var under := {}
	for z in range(lo.z, lo.z + size.z):
		for x in range(lo.x, lo.x + size.x):
			if not outside.has(Vector2i(x, z)):
				under[Vector2i(x, z)] = true
	return under


## The build's structure as the space finder sees it: Vector3i -> Cell (SOLID,
## GLASS, DOOR) for every cell a structure brick of the upright grid fills.
## Furniture and detail are air, as they are to the finder in the workshop.
static func cells_of(r: BuildRecipe) -> Dictionary:
	var out := {}
	for i in r.size():
		if r.frame_of(i) != 0 or r.role_of(i) != BuildRecipe.Role.STRUCTURE:
			continue
		var k := StructureSpaces.Cell.SOLID
		if BrickWorld.is_material_translucent(r.material_of(i)):
			k = StructureSpaces.Cell.GLASS
		elif r.part_of(i).contains("door"):
			k = StructureSpaces.Cell.DOOR
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					out[c + Vector3i(x, y, z)] = k
	return out


## The build's record found again from its bricks: every space from its seed,
## the kinds and links set by hand kept, the connectors worked out again, the
## marks as they were. The recipe is not changed.
static func refresh(r: BuildRecipe) -> Dictionary:
	var rec: Dictionary = StructureSpaces.empty()
	rec.merge((r.meta.get("structure", {}) as Dictionary).duplicate(true), true)
	var cells := cells_of(r)
	var b := r.bounds()
	var lo: Vector3i = (b[0] as Vector3i) - Vector3i.ONE
	var hi: Vector3i = (b[0] as Vector3i) + (b[1] as Vector3i) + Vector3i.ONE
	var kind := func(c: Vector3i) -> int: return int(cells.get(c, StructureSpaces.Cell.AIR))
	var openings := []
	var spaces := []
	for s: Dictionary in rec.spaces:
		var start := Vector3i(int(s.seed[0]), int(s.seed[1]), int(s.seed[2]))
		var mine := (rec.openings as Array).filter(func(o) -> bool: return int(o.space) == int(s.id))
		var found := StructureSpaces.find_space(start, kind, lo, hi)
		if not found.ok:
			continue
		var made := StructureSpaces.record_space(int(s.id), String(s.kind), 0, start, found, mine)
		spaces.append(made[0])
		openings.append_array(made[1])
	rec.spaces = spaces
	rec.openings = openings
	rec.connectors = StructureSpaces.connectors(rec, kind, lo, hi)
	return rec


# ---------------------------------------------------------------------------
# Turned.

## The box BuildRecipe.turned turns everything inside: [lo, size]. The same
## sum it makes, so a cell turned here lands where its brick does.
static func _turn_frame(r: BuildRecipe) -> Array:
	var b := r.bounds()
	var lo: Vector3i = b[0]
	var hi: Vector3i = lo + (b[1] as Vector3i)
	var any := not r.is_empty()
	var boxes := []
	for i in r.fixture_count():
		boxes.append(r._fixture_bounds(r.fixture_at(i)))
	for t in r.towers:
		boxes.append([BuildRecipe.cell_from(t.cell), TowerBlockout.dims(TowerBlockout.normalised(t.params))])
	for bx in boxes:
		var c: Vector3i = bx[0]
		var hc: Vector3i = c + (bx[1] as Vector3i)
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z)) if any else c
		hi = Vector3i(maxi(hi.x, hc.x), maxi(hi.y, hc.y), maxi(hi.z, hc.z)) if any else hc
		any = true
	return [lo, hi - lo]


static func turn_cell(c: Vector3i, k: int, lo: Vector3i, d: Vector3i) -> Vector3i:
	return BuildRecipe._turn_box(c - lo, Vector3i.ONE, d, k) + lo


## One quarter turn of a module:
##   recipe     the build turned (BuildRecipe.turned)
##   solid      Vector3i -> Cell, its structure (cells_of)
##   cols       Vector2i -> Vector2i(y0, y1): what it fills, column by column,
##              lowest brick to highest and the air of its rooms, y1 exclusive
##   min_y      its lowest cell
##   conns      its connectors: {kind, at: Vector3i, facing, size: Vector2i,
##              link, depth (the wall's thickness; 0 an open side), space,
##              base, top (a stair link's column's y0 and y1), wall: [colour,
##              material] of the brick beside a doorway (what its cap is laid in)}
##   marks      its facade spots: {kind, at: Vector3i (the wall's inside cell),
##              facing, depth, floor_y, ceil_y, space}
##   windows    its window and glass openings: [{kind, cells: [Vector3i]}]
##   spaces     {id: {floor_y, ceil_y, cols: {Vector2i: true}, kind, seed: Vector3i}}
##   colour     its first structure brick's colour (what a cap is laid in)
static func _turn(r: BuildRecipe, tr: BuildRecipe, rec: Dictionary, k: int,
		lo: Vector3i, d: Vector3i) -> Dictionary:
	var solid := cells_of(tr)
	var cols := {}
	var brick_of := {}
	var add_span := func(c: Vector2i, y0: int, y1: int) -> void:
		var s: Vector2i = cols.get(c, Vector2i(y0, y1))
		cols[c] = Vector2i(mini(s.x, y0), maxi(s.y, y1))
	for i in tr.size():
		var c := tr.cell_of(i)
		var s := BuildRecipe.part_size(tr.part_of(i))
		for z in s.z:
			for x in s.x:
				add_span.call(Vector2i(c.x + x, c.z + z), c.y, c.y + s.y)
				if tr.role_of(i) == BuildRecipe.Role.STRUCTURE:
					for y in s.y:
						brick_of[c + Vector3i(x, y, z)] = i
	var spaces := {}
	for sp: Dictionary in rec.spaces:
		var sc := {}
		for c in sp.columns:
			var t := turn_cell(Vector3i(int(c[0]), 0, int(c[1])), k, lo, d)
			sc[Vector2i(t.x, t.z)] = true
			add_span.call(Vector2i(t.x, t.z), int(sp.floor_y) + 1, int(sp.ceil_y))
		var seed := turn_cell(Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2])), k, lo, d)
		spaces[int(sp.id)] = {"floor_y": int(sp.floor_y), "ceil_y": int(sp.ceil_y), "cols": sc,
				"kind": String(sp.kind), "seed": seed}
	var min_y := 1 << 30
	for c: Vector2i in cols:
		min_y = mini(min_y, (cols[c] as Vector2i).x)

	var conns := []
	for c: Dictionary in rec.connectors:
		var at := turn_cell(Vector3i(int(c.at[0]), int(c.at[1]), int(c.at[2])), k, lo, d)
		if StructureSpaces.STAIR_MARKS.has(String(c.kind)):
			var span: Vector2i = cols.get(Vector2i(at.x, at.z), Vector2i(at.y, at.y + 1))
			conns.append({"kind": String(c.kind), "at": at, "facing": -1, "size": Vector2i.ONE,
					"link": "auto", "depth": 0, "space": int(c.space), "base": span.x, "top": span.y})
			continue
		var f := int(c.facing)
		var w := int(c.size[0])
		var fd: Vector2i = StructureSpaces.FACINGS[f]
		var across := Vector3i(absi(fd.y), 0, absi(fd.x))
		var far := turn_cell(Vector3i(int(c.at[0]), int(c.at[1]), int(c.at[2])) + across * (w - 1), k, lo, d)
		var low := Vector3i(mini(at.x, far.x), at.y, mini(at.z, far.z))
		conns.append({"kind": "door", "at": low, "facing": (f + k) % 4, "size": Vector2i(w, int(c.size[1])),
				"link": String(c.link), "space": int(c.space), "depth": int(c.get("depth", 1)),
				"wall": _jamb(tr, brick_of, low, (f + k) % 4, w)})
	var marks := []
	for m: Dictionary in rec.get("marks", []):
		if StructureSpaces.STAIR_MARKS.has(String(m.kind)) or not spaces.has(int(m.space)):
			continue
		var at := turn_cell(Vector3i(int(m.at[0]), int(m.at[1]), int(m.at[2])), k, lo, d)
		var tf := (int(m.facing) + k) % 4
		var fd: Vector2i = StructureSpaces.FACINGS[tf]
		var depth := 0
		while depth <= StructureSpaces.MAX_WALL and solid.has(at + Vector3i(fd.x, 0, fd.y) * depth):
			depth += 1
		var sp: Dictionary = spaces[int(m.space)]
		marks.append({"kind": String(m.kind), "at": at, "facing": tf, "depth": maxi(depth, 1),
				"floor_y": int(sp.floor_y), "ceil_y": int(sp.ceil_y), "space": int(m.space)})
	var windows := []
	for o: Dictionary in rec.openings:
		if String(o.kind) != "window" and String(o.kind) != "glass":
			continue
		var cells := []
		for c in o.cells:
			cells.append(turn_cell(Vector3i(int(c[0]), int(c[1]), int(c[2])), k, lo, d))
		windows.append({"kind": String(o.kind), "cells": cells})
	var colour := 0
	for i in tr.size():
		if tr.role_of(i) == BuildRecipe.Role.STRUCTURE:
			colour = tr.colour_of(i)
			break
	for c: Dictionary in conns:
		if c.has("wall") and (c.wall as Array).is_empty():
			c.wall = [colour, 0]
	return {"recipe": tr, "solid": solid, "cols": cols, "min_y": min_y, "conns": conns,
			"marks": marks, "windows": windows, "spaces": spaces, "colour": colour}


## The colour and material of the wall a doorway goes through: the brick beside
## it (a jamb, either side, a course up), or [] when none is found.
static func _jamb(tr: BuildRecipe, brick_of: Dictionary, at: Vector3i, facing: int, w: int) -> Array:
	var fd: Vector2i = StructureSpaces.FACINGS[facing]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	for y in [1, 0, 2]:
		for side in [-1, w]:
			var c: Vector3i = at - d + across * side + Vector3i(0, y, 0)
			if brick_of.has(c):
				var i: int = brick_of[c]
				return [tr.colour_of(i), tr.material_of(i)]
	return []
