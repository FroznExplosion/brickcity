class_name HullAir
extends RefCounted

## The air inside a hull (Docs/Hulls.md 2-3): which empty cells of a ship are
## enclosed -- its "air bricks" -- split into compartments by its walls and
## closed doors, and where a hit has opened a compartment to the outside.
##
## One cell is one BrickWorld cell (a stud by a plate), in the chunk's own
## cells, so it moves and tilts with the ship and a one-plate ceiling seals.
##
##   var air := HullAir.bake(world, chunk, recipe)
##   air.compartments()          # [{id, cells, breaches, doors}]
##   air.blocks_removed(world, chunk, ids)   # after a hit; returns what it breached
##   air.blocks_added(world, chunk, ids)     # after a repair; returns what it sealed
##   air.set_door(i, open)
##
## Built once from the laid recipe (get_solid_cells: one C++ call), then kept up
## to date from the hits' own cells -- never a scan of the whole ship.
##
## A compartment is a room: doors are walls to the fill, so each room is its own
## compartment and an OPEN door links two (`links`). A door to the outside (the
## airlock) left open is a breach like any hole.

enum { EMPTY, SOLID, OUTSIDE, INSIDE, DOOR }

## How far a repaired hole's leftover outside cells are followed to see if they
## still reach the outside (blocks_added): past this many cells they are taken
## to (it is a big hole, not a pocket in a wall).
const POCKET_MAX := 4096

var dims := Vector3i.ZERO
var state := PackedByteArray()
## Per cell: the compartment it was labelled with (follow `_root`), or -1.
var comp := PackedInt32Array()
## Per compartment: [parent (union-find), cells, breaches {cell index: true}].
var _parent := PackedInt32Array()
var _cells := PackedInt32Array()
var _breach: Array[Dictionary] = []
## Doors: [{lo, size, cells: PackedInt32Array, open, outside: bool}]
var doors: Array[Dictionary] = []
## Per cell that is a door: its door index, else -1 (only for DOOR cells).
var door_of := {}
## Block id -> recipe index (for the block's cells: its part's box).
var _recipe: BuildRecipe
var _origin := Vector3i.ZERO
var _block_recipe := PackedInt32Array()
## How long the bake took, ms.
var bake_ms := 0.0


## The hull of `recipe`, laid in `chunk` of `world` with the recipe rebased
## (BuildRecipe.build's default): solid where it has bricks, the rest filled
## from outside, what the fill never reaches is inside air.
static func bake(world: BrickWorld, chunk: int, recipe: BuildRecipe) -> HullAir:
	var t0 := Time.get_ticks_usec()
	var a := HullAir.new()
	a._recipe = recipe
	a._origin = recipe.origin()
	a.dims = world.get_chunk_dims(chunk)
	var n := a.dims.x * a.dims.y * a.dims.z
	var solid := world.get_solid_cells(chunk)
	a.state.resize(n)
	a.comp.resize(n)
	a.comp.fill(-1)
	for i in n:
		a.state[i] = SOLID if solid[i] != 0 else EMPTY
	# Doors are walls to the fill.
	for d: Dictionary in BuildDoors.of(recipe):
		var lo: Vector3i = d.lo - a._origin
		var size: Vector3i = d.size
		var cells := PackedInt32Array()
		for z in size.z:
			for y in size.y:
				for x in size.x:
					var c := lo + Vector3i(x, y, z)
					if not a._in(c):
						continue
					var i := a._idx(c)
					if a.state[i] == EMPTY:
						a.state[i] = DOOR
						a.door_of[i] = a.doors.size()
						cells.append(i)
		a.doors.append({"lo": lo, "size": size, "cells": cells, "open": false, "outside": false})
	a._fill_outside()
	a._label_inside()
	for di in a.doors.size():
		a.doors[di].outside = a._door_touches_outside(di)
	# Block ids are the recipe's frame-0 entries in order (BuildRecipe.build
	# places them so); a block that did not fit would shift the rest, so the map
	# is only kept when the counts agree.
	var ids := PackedInt32Array()
	for i in recipe.size():
		if recipe.frame_of(i) == 0:
			ids.append(i)
	if ids.size() == world.get_block_count(chunk):
		a._block_recipe = ids
	else:
		push_warning("HullAir: %d blocks for %d recipe entries; hits will not be followed"
				% [world.get_block_count(chunk), ids.size()])
	a.bake_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return a


## True when hits can be followed (the block map was kept).
func follows_hits() -> bool:
	return not _block_recipe.is_empty()


## Every compartment that is its own root: {id, cells, breaches, doors}.
func compartments() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ci in _parent.size():
		if _parent[ci] != ci:
			continue
		var ds := []
		for di in doors.size():
			if ci in door_sides(di):
				ds.append(di)
		out.append({"id": ci, "cells": _cells[ci], "breaches": _breach[ci].size(), "doors": ds})
	return out


func inside_cells() -> int:
	var n := 0
	for ci in _parent.size():
		if _parent[ci] == ci:
			n += _cells[ci]
	return n


## The compartment at `cell` (chunk cells), or -1 (solid, outside, a door).
func compartment_at(cell: Vector3i) -> int:
	if not _in(cell):
		return -1
	var c := comp[_idx(cell)]
	return _root(c) if c >= 0 else -1


func is_breached(ci: int) -> bool:
	return not _breach[_root(ci)].is_empty()


## The breach cells of compartment `ci`, as chunk cells.
func breach_cells(ci: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for i: int in _breach[_root(ci)]:
		out.append(_cell(i))
	return out


## The compartments a door joins (roots); -2 stands for the outside.
func door_sides(di: int) -> Array:
	var sides := []
	for i: int in doors[di].cells:
		for j in _neighbours(i):
			var s := state[j]
			var v := -3
			if s == INSIDE:
				v = _root(comp[j])
			elif s == OUTSIDE:
				v = -2
			if v != -3 and not sides.has(v):
				sides.append(v)
	return sides


## Open or shut door `di`. An outside door (the airlock) left open breaches what
## it opens onto; shut, that breach goes. Returns the compartments it changed.
func set_door(di: int, open: bool) -> Array:
	var d := doors[di]
	if bool(d.open) == open:
		return []
	d.open = open
	var changed := []
	if not bool(d.outside):
		return changed
	for ci in door_sides(di):
		if ci < 0:
			continue
		for i: int in d.cells:
			if open:
				_breach[ci][i] = true
			else:
				_breach[ci].erase(i)
		changed.append(ci)
	return changed


## Open doors' links between compartments: [[a, b], ...] (roots, -2 outside).
func links() -> Array:
	var out := []
	for di in doors.size():
		if bool(doors[di].open):
			var s := door_sides(di)
			if s.size() >= 2:
				out.append(s)
	return out


## Blocks `ids` are gone (a hit). Their cells empty; a group of them that
## reaches the outside breaches every compartment it touches, one that does
## not joins the compartments it touches (merging them) or is a new sealed
## pocket. Returns the compartments newly breached (roots).
func blocks_removed(world: BrickWorld, chunk: int, ids: PackedInt32Array) -> Array:
	var freed := {}
	for b in ids:
		for i in _block_cells(b):
			if state[i] == SOLID and not world.is_solid(chunk, _cell(i)):
				freed[i] = true
	if freed.is_empty():
		return []
	var breached := []
	var seen := {}
	for start: int in freed:
		if seen.has(start):
			continue
		# One connected group of freed cells, and what it touches.
		var group := PackedInt32Array([start])
		seen[start] = true
		var k := 0
		var touches_out := false
		var touches := {}
		while k < group.size():
			var i := group[k]
			k += 1
			if _on_edge(i):
				touches_out = true
			for j in _neighbours(i):
				if freed.has(j):
					if not seen.has(j):
						seen[j] = true
						group.append(j)
					continue
				var s := state[j]
				if s == OUTSIDE:
					touches_out = true
				elif s == INSIDE:
					touches[_root(comp[j])] = true
				elif s == DOOR and bool(doors[door_of[j]].open) and bool(doors[door_of[j]].outside):
					touches_out = true
		if touches_out:
			for i in group:
				state[i] = OUTSIDE
			for ci: int in touches:
				var was := _breach[ci].is_empty()
				for i in group:
					for j in _neighbours(i):
						if state[j] == INSIDE and _root(comp[j]) == ci:
							_breach[ci][i] = true
							break
				if was and not _breach[ci].is_empty():
					breached.append(ci)
		else:
			var into := -1
			for ci: int in touches:
				into = ci if into < 0 else _union(into, ci)
			if into < 0:
				into = _new_comp()
			for i in group:
				state[i] = INSIDE
				comp[i] = into
			_cells[into] += group.size()
	return breached


## Blocks `ids` are back (a repair). Their cells are solid again and leave
## every breach list; outside cells next to them that no longer reach the
## outside (the inner part of a patched hole) are inside air again. Returns the
## compartments that are sealed now (roots).
func blocks_added(world: BrickWorld, chunk: int, ids: PackedInt32Array) -> Array:
	var cand := PackedInt32Array()
	for b in ids:
		cand.append_array(_block_cells(b))
	return _added(world, chunk, cand)


## The same for cells (chunk cells) that may have bricks again -- a brick laid
## anew, whose block id the bake never saw.
func cells_added(world: BrickWorld, chunk: int, cells: Array[Vector3i]) -> Array:
	var cand := PackedInt32Array()
	for c in cells:
		if _in(c):
			cand.append(_idx(c))
	return _added(world, chunk, cand)


func _added(world: BrickWorld, chunk: int, cand: PackedInt32Array) -> Array:
	var filled := []
	for i in cand:
		if state[i] != SOLID and world.is_solid(chunk, _cell(i)):
			filled.append(i)
	if filled.is_empty():
		return []
	var was_breached := {}
	for ci in _parent.size():
		if _parent[ci] == ci and not _breach[ci].is_empty():
			was_breached[ci] = true
	for i: int in filled:
		if state[i] == INSIDE:
			_cells[_root(comp[i])] -= 1
		state[i] = SOLID
		comp[i] = -1
		for ci: int in was_breached:
			_breach[ci].erase(i)
	# Leftover outside cells beside the patch: still open to the outside?
	var checked := {}
	for i: int in filled:
		for j in _neighbours(i):
			if state[j] != OUTSIDE or checked.has(j):
				continue
			var pocket := _pocket_from(j)
			for p in pocket:
				checked[p] = true
			if pocket.is_empty():
				continue
			# Enclosed: inside air of whatever it touches.
			var into := -1
			for p in pocket:
				for q in _neighbours(p):
					if state[q] == INSIDE:
						var r := _root(comp[q])
						into = r if into < 0 else _union(into, r)
			if into < 0:
				into = _new_comp()
			for p in pocket:
				state[p] = INSIDE
				comp[p] = into
				for ci: int in was_breached:
					_breach[ci].erase(p)
			_cells[into] += pocket.size()
	var sealed := []
	for ci: int in was_breached:
		var r := _root(ci)
		if _breach[r].is_empty() and not sealed.has(r):
			sealed.append(r)
	return sealed


# --- the fills ---------------------------------------------------------------

func _fill_outside() -> void:
	var q := PackedInt32Array()
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				if x == 0 or y == 0 or z == 0 or x == dims.x - 1 or y == dims.y - 1 or z == dims.z - 1:
					var i := x + dims.x * (y + dims.y * z)
					if state[i] == EMPTY:
						state[i] = OUTSIDE
						q.append(i)
	var k := 0
	while k < q.size():
		var i := q[k]
		k += 1
		for j in _neighbours(i):
			if state[j] == EMPTY:
				state[j] = OUTSIDE
				q.append(j)


func _label_inside() -> void:
	for start in state.size():
		if state[start] != EMPTY:
			continue
		var ci := _new_comp()
		var q := PackedInt32Array([start])
		state[start] = INSIDE
		comp[start] = ci
		var k := 0
		while k < q.size():
			var i := q[k]
			k += 1
			for j in _neighbours(i):
				if state[j] == EMPTY:
					state[j] = INSIDE
					comp[j] = ci
					q.append(j)
		_cells[ci] = q.size()


func _door_touches_outside(di: int) -> bool:
	for i: int in doors[di].cells:
		if _on_edge(i):
			return true
		for j in _neighbours(i):
			if state[j] == OUTSIDE:
				return true
	return false


## The outside cells joined to `start` if they do NOT reach the true outside
## (the chunk's edge) within POCKET_MAX cells; empty if they do.
func _pocket_from(start: int) -> PackedInt32Array:
	var q := PackedInt32Array([start])
	var seen := {start: true}
	var k := 0
	while k < q.size():
		var i := q[k]
		k += 1
		if _on_edge(i) or q.size() > POCKET_MAX:
			return PackedInt32Array()
		for j in _neighbours(i):
			if state[j] == OUTSIDE and not seen.has(j):
				seen[j] = true
				q.append(j)
			elif state[j] == DOOR and bool(doors[door_of[j]].open) and bool(doors[door_of[j]].outside):
				return PackedInt32Array()
	return q


# --- compartments: union-find -----------------------------------------------

func _new_comp() -> int:
	var ci := _parent.size()
	_parent.append(ci)
	_cells.append(0)
	_breach.append({})
	return ci


func _root(ci: int) -> int:
	while _parent[ci] != ci:
		_parent[ci] = _parent[_parent[ci]]
		ci = _parent[ci]
	return ci


func _union(a: int, b: int) -> int:
	a = _root(a)
	b = _root(b)
	if a == b:
		return a
	if _cells[a] < _cells[b]:
		var t := a
		a = b
		b = t
	_parent[b] = a
	_cells[a] += _cells[b]
	for i: int in _breach[b]:
		_breach[a][i] = true
	_breach[b].clear()
	return a


# --- cells -------------------------------------------------------------------

func _block_cells(b: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if b < 0 or b >= _block_recipe.size():
		return out
	var ri := _block_recipe[b]
	var base := _recipe.cell_of(ri) - _origin
	var size := BuildRecipe.part_size(_recipe.part_of(ri))
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var c := base + Vector3i(x, y, z)
				if _in(c):
					out.append(_idx(c))
	return out


func _in(c: Vector3i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < dims.x and c.y < dims.y and c.z < dims.z


func _idx(c: Vector3i) -> int:
	return c.x + dims.x * (c.y + dims.y * c.z)


func _cell(i: int) -> Vector3i:
	var x := i % dims.x
	@warning_ignore("integer_division")
	var r := i / dims.x
	@warning_ignore("integer_division")
	var z := r / dims.y
	return Vector3i(x, r % dims.y, z)


func _on_edge(i: int) -> bool:
	var c := _cell(i)
	return c.x == 0 or c.y == 0 or c.z == 0 or c.x == dims.x - 1 or c.y == dims.y - 1 or c.z == dims.z - 1


func _neighbours(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var sx := 1
	var sy := dims.x
	var sz := dims.x * dims.y
	var c := _cell(i)
	if c.x > 0:
		out.append(i - sx)
	if c.x < dims.x - 1:
		out.append(i + sx)
	if c.y > 0:
		out.append(i - sy)
	if c.y < dims.y - 1:
		out.append(i + sy)
	if c.z > 0:
		out.append(i - sz)
	if c.z < dims.z - 1:
		out.append(i + sz)
	return out
