class_name BuildSections
extends RefCounted

## A generated build cut into sections (Docs/RoomModules.md 7.1): the parts a
## station or a ship is made of (Docs/Space.md 3.2), each about a city
## building's bricks, joined to the others at joints; the one with the start
## (or the ground storey) is the root.
##
## The cut follows the plan's units -- a grown building's placements (a module
## is never split), a tower's storeys -- each brick going with the unit its
## cell is in (or the nearest one: a cap, a balcony, a step). Units are put
## together from the root outward along the plan's joins, each section filled
## to an even share of the bricks (as few as `budget` allows), then the small
## ones joined to a neighbour while both stay under it; a unit over it alone is
## a section of its own.
##
##   meta["sections"]  {"budget", "kind" ("join" | "storey"), "size" (bricks
##                     when cut: a build edited since has other bricks),
##                     "sections": [{"id", "root", "bricks", "lo", "hi"}],
##                     "joints": [{"a", "b", "cells"}] (how many cells meet),
##                     "of": [[section, run], ...] each brick's section in order}
##
## `split` lays each section as a build of its own (its rooms, doors, lifts and
## furniture with it), moved to start at 0, and says where it goes back.

const BUDGET := 8000
## How far (cells) a brick outside every unit looks for the nearest one.
const REACH := 6
const DIRS := [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]


## The sections of `r`, laid from `plan` with `shift` (RoomGrow.lay):
## {sections, joints: [{a, b, cells: [Vector3i]}], of: PackedInt32Array, kind, budget}.
static func of_plan(lib: Array, plan: Dictionary, r: BuildRecipe, shift: Vector3i, budget := BUDGET) -> Dictionary:
	var u := _units(lib, plan, shift)
	var n: int = u.n
	var unit := PackedInt32Array()
	unit.resize(r.size())
	var count := []
	count.resize(n)
	count.fill(0)
	for i in r.size():
		var k := _unit_of(u, r.cell_of(i))
		unit[i] = k
		count[k] = int(count[k]) + 1
	# Units together from the root outward, each section filled to an even share
	# of the bricks (as few sections as the budget allows) ...
	var total := 0
	for k in count:
		total += int(k)
	var target := ceili(float(total) / maxi(ceili(float(total) / budget), 1))
	var order := _bfs(u.adj, int(u.root), n)
	var sec := []
	sec.resize(n)
	sec.fill(-1)
	var sizes := []
	for seed: int in order:
		if int(sec[seed]) >= 0:
			continue
		var id := sizes.size()
		var sum := int(count[seed])
		sec[seed] = id
		var q := [seed]
		while not q.is_empty():
			var a: int = q.pop_front()
			for b: int in u.adj[a]:
				if int(sec[b]) < 0 and sum + int(count[b]) <= target:
					sec[b] = id
					sum += int(count[b])
					q.append(b)
		sizes.append(sum)
	# ... then the smallest joined to the smallest section it touches while the
	# two stay under budget (the root keeps its number).
	var merged := true
	while merged:
		merged = false
		var by_size := range(sizes.size()).filter(func(k) -> bool: return int(sizes[k]) > 0)
		by_size.sort_custom(func(x, y) -> bool: return int(sizes[x]) < int(sizes[y]))
		for k: int in by_size:
			var best := -1
			for a in n:
				if int(sec[a]) != k:
					continue
				for b: int in u.adj[a]:
					var o := int(sec[b])
					if o != k and int(sizes[k]) + int(sizes[o]) <= budget 							and (best < 0 or int(sizes[o]) < int(sizes[best])):
						best = o
			if best < 0:
				continue
			var keep := mini(k, best)
			var gone := maxi(k, best)
			for a in n:
				if int(sec[a]) == gone:
					sec[a] = keep
			sizes[keep] = int(sizes[keep]) + int(sizes[gone])
			sizes[gone] = 0
			merged = true
			break
	# Numbered again in order, the root's 0.
	var renum := {}
	var sections := []
	for k in sizes.size():
		if int(sizes[k]) > 0 or k == 0:
			renum[k] = sections.size()
			sections.append({"id": sections.size(), "root": sections.is_empty(), "bricks": int(sizes[k]),
					"units": [], "lo": Vector3i(1 << 30, 1 << 30, 1 << 30), "hi": -Vector3i(1 << 30, 1 << 30, 1 << 30)})
	for a in n:
		sec[a] = int(renum.get(int(sec[a]), 0))
		(sections[int(sec[a])].units as Array).append(a)
	var of := PackedInt32Array()
	of.resize(r.size())
	for i in r.size():
		of[i] = int(sec[unit[i]])
	var cells := _cells(r, of)
	for c: Vector3i in cells:
		var s: Dictionary = sections[int(cells[c])]
		s.lo = (s.lo as Vector3i).min(c)
		s.hi = (s.hi as Vector3i).max(c)
	return {"sections": sections, "joints": _joints(cells), "of": of, "kind": u.kind, "budget": budget}


## What goes in the build's meta: the sections, the joints' sizes, each brick's
## section run-length coded.
static func record(cut: Dictionary, size: int) -> Dictionary:
	var runs := []
	var of: PackedInt32Array = cut.of
	for i in of.size():
		if not runs.is_empty() and int(runs[-1][0]) == of[i]:
			runs[-1][1] = int(runs[-1][1]) + 1
		else:
			runs.append([of[i], 1])
	return {"budget": int(cut.budget), "kind": String(cut.kind), "size": size,
			"sections": (cut.sections as Array).map(func(s) -> Dictionary: return {"id": int(s.id),
				"root": bool(s.root), "bricks": int(s.bricks), "lo": _arr(s.lo),
				"hi": _arr(s.hi)}),
			"joints": (cut.joints as Array).map(func(j) -> Dictionary: return {"a": int(j.a), "b": int(j.b),
				"cells": (j.cells as Array).size()}),
			"of": runs}


## The build's sections' record again after its bricks changed: `of` each
## brick's section now (as `of_build` gave it, kept in step with the change).
static func rerecord(r: BuildRecipe, of: PackedInt32Array) -> void:
	var m: Dictionary = r.meta.sections
	var runs := []
	var count := {}
	for i in of.size():
		count[of[i]] = int(count.get(of[i], 0)) + 1
		if not runs.is_empty() and int(runs[-1][0]) == of[i]:
			runs[-1][1] = int(runs[-1][1]) + 1
		else:
			runs.append([of[i], 1])
	m.of = runs
	m.size = r.size()
	for s: Dictionary in m.sections:
		s.bricks = int(count.get(int(s.id), 0))


## Each brick's section from a build's meta (empty when it has none, or its
## bricks changed since it was cut).
static func of_build(r: BuildRecipe) -> PackedInt32Array:
	var out := PackedInt32Array()
	var m: Dictionary = r.meta.get("sections", {})
	if m.is_empty() or int(m.size) != r.size():
		return out
	for run in m.of:
		for k in int(run[1]):
			out.append(int(run[0]))
	return out


## The sections as builds of their own: [{"id", "root", "recipe", "offset"}],
## each recipe's cells moved to start at 0 -- `offset` puts them back. Rooms,
## doors, lifts (a stop each storey it has), fixtures and furniture go with the
## section their cell is in or nearest.
static func split(r: BuildRecipe) -> Array:
	var of := of_build(r)
	var m: Dictionary = r.meta.get("sections", {})
	if of.is_empty():
		return [{"id": 0, "root": true, "recipe": r, "offset": Vector3i.ZERO}]
	var cells := _cells(r, of)
	var out := []
	for s: Dictionary in m.sections:
		var rec := BuildRecipe.new()
		rec.kind = r.kind
		rec.name = "%s section %d" % [r.name, int(s.id)]
		var st := StructureSpaces.empty()
		rec.meta["structure"] = st
		out.append({"id": int(s.id), "root": bool(s.root), "recipe": rec, "offset": BuildRecipe.cell_from(s.lo)})
	for i in r.size():
		var o: Dictionary = out[of[i]]
		(o.recipe as BuildRecipe).add(r.part_of(i), r.cell_of(i) - (o.offset as Vector3i), r.colour_of(i),
				0, r.role_of(i), r.material_of(i))
	for i in r.fixture_count():
		var f := r.fixture_at(i)
		var o: Dictionary = out[_nearest(cells, f.cell)]
		(o.recipe as BuildRecipe).add_fixture(f.kind, (f.cell as Vector3i) - (o.offset as Vector3i), f.params, f.role)
	for a in r.placements:
		var c := BuildRecipe.cell_from(a.cell)
		var o: Dictionary = out[_nearest(cells, c)]
		(o.recipe as BuildRecipe).placements.append(AssetPlacements.make(str(a.asset), c - (o.offset as Vector3i),
				int(a.get("turn", 0))))
	for sp: Dictionary in r.meta.get("structure", {}).get("spaces", []):
		var sd := Vector3i(int(sp.seed[0]), int(sp.seed[1]), int(sp.seed[2]))
		var o: Dictionary = out[_nearest(cells, sd)]
		var off: Vector3i = o.offset
		var spaces: Array = o.recipe.meta.structure.spaces
		var d := sd - off
		spaces.append({"id": spaces.size(), "kind": String(sp.kind), "frame": 0, "seed": [d.x, d.y, d.z],
				"floor_y": int(sp.floor_y) - off.y, "ceil_y": int(sp.ceil_y) - off.y,
				"columns": (sp.columns as Array).map(func(c) -> Array: return [int(c[0]) - off.x, int(c[1]) - off.z])})
	for dr: Dictionary in r.meta.get("doors", []):
		var lo := BuildRecipe.cell_from(dr.lo)
		var o: Dictionary = out[_nearest(cells, lo)]
		var d: Dictionary = dr.duplicate(true)
		d.lo = _arr(lo - (o.offset as Vector3i))
		var rm: Dictionary = o.recipe.meta
		if not rm.has("doors"):
			rm["doors"] = []
		(rm.doors as Array).append(d)
	for lf: Dictionary in r.meta.get("lifts", []):
		var lo := BuildRecipe.cell_from(lf.lo)
		var by := {}
		for y in lf.stops:
			var k := _nearest(cells, Vector3i(lo.x, int(y), lo.z))
			if not by.has(k):
				by[k] = []
			(by[k] as Array).append(int(y))
		for k in by:
			if (by[k] as Array).size() < 2:
				continue
			var off: Vector3i = out[k].offset
			var rm: Dictionary = out[k].recipe.meta
			if not rm.has("lifts"):
				rm["lifts"] = []
			(rm.lifts as Array).append(BuildLifts.record(lo - off, Vector2i(int(lf.size[0]), int(lf.size[1])),
					(by[k] as Array).map(func(y) -> int: return y - off.y)))
	for o: Dictionary in out:
		o.recipe.meta["section"] = {"id": int(o.id), "root": bool(o.root), "offset": _arr(o.offset),
				"of": r.name}
		if r.meta.has("generated"):
			o.recipe.meta["generated"] = r.meta.generated
	return out


# ---------------------------------------------------------------------------

## The plan's units: a ship's stretches between bulkheads (the bulkhead with
## the stretch aft of it; fore the root), a tower's storeys (one over another),
## else its placements (joined where the plan joined them); the root the ground
## storey or the start.
static func _units(lib: Array, plan: Dictionary, shift: Vector3i) -> Dictionary:
	var placed: Array = plan.get("placed", [])
	if String(plan.get("generator", "grow")) == "pack":
		# A ship: the stretches between its bulkheads, the bridge's (plan.root_x) the root.
		var segs: Array = plan.segments
		var n := segs.size() + 1
		var adj := []
		for k in n:
			adj.append(([k - 1] if k > 0 else []) + ([k + 1] if k < n - 1 else []))
		var root := n - 1 if int(plan.get("fore", 1)) > 0 else 0
		if plan.has("root_x"):
			root = 0
			for b in segs:
				if int(b) < int(plan.root_x):
					root += 1
		return {"kind": "bulkhead", "n": n, "segments": segs, "x0": shift.x, "adj": adj, "root": root}
	if String(plan.get("generator", "grow")) == "shell":
		var n := maxi(int(plan.stats.storeys), 1)
		var adj := []
		for s in n:
			adj.append(([s - 1] if s > 0 else []) + ([s + 1] if s < n - 1 else []))
		return {"kind": "storey", "n": n, "pitch": int(plan.stats.pitch), "y0": shift.y, "root": 0, "adj": adj}
	var cols := {}
	for i in placed.size():
		var pl: Dictionary = placed[i]
		var td: Dictionary = lib[pl.m].turns[pl.t]
		var off: Vector3i = (pl.off as Vector3i) + shift
		for c: Vector2i in td.cols:
			var w := Vector2i(c.x + off.x, c.y + off.z)
			var s: Vector2i = td.cols[c]
			if not cols.has(w):
				cols[w] = []
			(cols[w] as Array).append([s.x + off.y, s.y + off.y, i])
	var adj := []
	for i in maxi(placed.size(), 1):
		adj.append([])
	for j: Dictionary in plan.get("joins", []):
		var a := int(j.a.p)
		var b := int(j.b.p)
		if a != b and not (adj[a] as Array).has(b):
			(adj[a] as Array).append(b)
			(adj[b] as Array).append(a)
	var path: Array = plan.get("path", [])
	return {"kind": "join", "n": maxi(placed.size(), 1), "cols": cols, "root": int(path[0]) if not path.is_empty() else 0,
			"adj": adj}


static func _unit_of(u: Dictionary, c: Vector3i) -> int:
	if String(u.kind) == "bulkhead":
		var k := 0
		for b in u.segments:
			if int(b) + int(u.x0) < c.x:
				k += 1
		return k
	if String(u.kind) == "storey":
		@warning_ignore("integer_division")
		return clampi((c.y - int(u.y0)) / maxi(int(u.pitch), 1), 0, int(u.n) - 1)
	var k := _in_cols(u.cols, c)
	if k >= 0:
		return k
	for r in range(1, REACH + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), maxi(absi(dy), absi(dz))) != r:
						continue
					k = _in_cols(u.cols, c + Vector3i(dx, dy, dz))
					if k >= 0:
						return k
	return int(u.root)


static func _in_cols(cols: Dictionary, c: Vector3i) -> int:
	for s in cols.get(Vector2i(c.x, c.z), []):
		if c.y >= int(s[0]) and c.y < int(s[1]):
			return int(s[2])
	return -1


## Every unit once, the root's first and then outward; those it does not reach after.
static func _bfs(adj: Array, root: int, n: int) -> Array:
	var seen := {root: true}
	var out := [root]
	var i := 0
	while out.size() < n:
		if i >= out.size():
			for k in n:
				if not seen.has(k):
					seen[k] = true
					out.append(k)
					break
			continue
		for b: int in adj[out[i]]:
			if not seen.has(b):
				seen[b] = true
				out.append(b)
		i += 1
	return out


## Every cell of every brick -> its section.
static func _cells(r: BuildRecipe, of: PackedInt32Array) -> Dictionary:
	var out := {}
	for i in r.size():
		var c := r.cell_of(i)
		var s := BuildRecipe.part_size(r.part_of(i))
		for y in s.y:
			for z in s.z:
				for x in s.x:
					out[c + Vector3i(x, y, z)] = of[i]
	return out


## Where two sections' bricks touch: [{a, b, cells}], a < b, each cell of a
## touching b and of b touching a.
static func _joints(cells: Dictionary) -> Array:
	var by := {}
	for c: Vector3i in cells:
		var s := int(cells[c])
		for d: Vector3i in DIRS:
			var n: Vector3i = c + d
			if not cells.has(n) or int(cells[n]) == s:
				continue
			var t := int(cells[n])
			var key := Vector2i(mini(s, t), maxi(s, t))
			if not by.has(key):
				by[key] = {}
			by[key][c] = true
			by[key][n] = true
	var out := []
	var keys := by.keys()
	keys.sort()
	for k: Vector2i in keys:
		out.append({"a": k.x, "b": k.y, "cells": (by[k] as Dictionary).keys()})
	return out


## The section of the brick cell at `c` or nearest it (under first: a room's
## seed is over its floor).
static func _nearest(cells: Dictionary, c: Vector3i) -> int:
	for d in [Vector3i.ZERO, Vector3i(0, -1, 0)]:
		if cells.has(c + d):
			return int(cells[c + d])
	for r in range(1, REACH * 2 + 1):
		# Its own row first, then under before over.
		var ys := range(-r, r + 1)
		ys.sort_custom(func(x, y) -> bool: return absi(x) < absi(y) or (absi(x) == absi(y) and x < y))
		for dy: int in ys:
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), maxi(absi(dy), absi(dz))) != r:
						continue
					var n := c + Vector3i(dx, dy, dz)
					if cells.has(n):
						return int(cells[n])
	return 0


static func _arr(c: Vector3i) -> Array:
	return [c.x, c.y, c.z]
