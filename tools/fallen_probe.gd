extends SceneTree

## Breaking a building that has already fallen.
##
## Reported symptoms: the game lags, the section jitters and slides, and the two
## halves never actually separate even though no bricks join them. All three are
## the same bug -- the parent body kept collision shapes for bricks that had
## moved to another island -- so all three are checked here.

const STUD := 0.35
const PLATE := 0.14


func _init() -> void:
	_check_split_takes_its_collision()
	_check_tension_on_a_fallen_piece()
	_check_gravity_axis()
	quit()


func _world() -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(16, 12, 16))
	TowerRecipe.build(w, c, palette, 16, 12, 16)
	w.set_tension_per_stud(c, 9.3)
	return [w, c]


## Cut a chunk in half and check both halves are real, separate chunks with the
## blocks actually moved -- not two halves of one body that only look apart.
func _check_split_takes_its_collision() -> void:
	print("splitting a fallen section")
	var pair := _world()
	var w: BrickWorld = pair[0]
	var c: int = pair[1]
	var total := w.get_alive_block_count(c)

	# Saw straight through the middle, the way shooting along a line does.
	var mid := 8 * TowerRecipe.PLATES_PER_COURSE
	var cut := 0
	for x in range(0, 17, 1):
		cut += w.apply_hit(c, Vector3(x * STUD, mid * PLATE, 2.0), 1.1).size()
	print("  %d blocks, cut %d of them out across the middle" % [total, cut])

	var alive_after := w.get_alive_block_count(c)
	var comps: Array = w.get_components(c)
	print("  connectivity says %d separate piece(s)" % comps.size())
	if comps.size() < 2:
		print("  (the cut did not sever it; nothing to check)")
		return

	# Move the biggest piece that is not the first one out, the way _shed does.
	var moved: PackedInt32Array = comps[1]
	for i in range(1, comps.size()):
		if (comps[i] as PackedInt32Array).size() > moved.size():
			moved = comps[i]
	var split: Dictionary = w.split_island(c, moved)
	if split.is_empty():
		print("  FAIL  split_island refused a real component")
		return
	var island: int = split.chunk
	var left := w.get_alive_block_count(c)
	var gone := w.get_alive_block_count(island)
	print("  parent %d -> %d alive, island holds %d" % [alive_after, left, gone])
	if left + gone == alive_after and gone == moved.size():
		print("  ok    every brick is in exactly one of the two chunks")
	else:
		print("  FAIL  %d + %d does not account for %d" % [left, gone, alive_after])

	# The parent must have no live block left where the island now is: that is
	# the ghost collision the bug left behind.
	var still_alive := {}
	for box in w.get_block_boxes(c):
		if bool(box.alive):
			still_alive[int(box.block)] = true
	var overlap := 0
	for bid in moved:
		if still_alive.has(bid):
			overlap += 1
	if overlap == 0:
		print("  ok    the parent keeps nothing that moved")
	else:
		print("  FAIL  %d moved blocks are still alive in the parent" % overlap)


## A fallen piece must still answer "can what is left hold itself up".
func _check_tension_on_a_fallen_piece() -> void:
	print("tension on a piece that has already fallen")
	var pair := _world()
	var w: BrickWorld = pair[0]
	var c: int = pair[1]

	# On its side: rotate 90 degrees about Z, so world down is grid +X.
	var xform := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(0, 0, 0))
	w.set_chunk_transform(c, xform)
	var down: Vector3 = xform.basis.inverse() * Vector3.DOWN
	w.set_chunk_gravity(c, Vector3i(roundi(down.x * 100.0), roundi(down.y * 100.0),
			roundi(down.z * 100.0)))
	# Rotating +90 degrees about Z sends grid -X to world down, so that is the
	# axis the solver has to anchor to.
	var g: Vector3i = w.get_chunk_gravity(c)
	print("  world down maps to grid %s" % str(g))
	if g == Vector3i(-1, 0, 0):
		print("  ok    the solver knows which way is down for a piece on its side")
	else:
		print("  FAIL  expected (-1, 0, 0)")

	var before := w.get_alive_block_count(c)
	var res: Dictionary = w.solve_stress(c)
	print("  solve: %d joint(s) over capacity, max ratio %.2f, %d blocks loaded" % [
			int(res.failures), float(res.max_ratio), int(res.blocks_loaded)])
	if int(res.blocks_loaded) > 0:
		print("  ok    weight flows along the new down (%d blocks carried load)" % int(res.blocks_loaded))
	else:
		print("  FAIL  nothing carried load -- the solve found no foundation")

	var loose: Array = w.find_detached_groups(c)
	var n := 0
	for grp in loose:
		n += grp.size()
	print("  intact and lying on its face: %d block(s) loose in %d group(s) of %d" % [
			n, loose.size(), before])
	if n == 0:
		print("  ok    a fallen piece nobody has touched stays in one piece")
	else:
		print("  FAIL  it fell apart on its own")

	# Now undercut it. With grid -X down, the foundation is the low-X end; take
	# a bite out of the far end's support and what is beyond it has no path to
	# the ground any more.
	# The WHOLE support face, worked out from the recipe rather than counted off
	# by hand. Leaving any of it standing leaves the section above grounded
	# through it, which is a test of nothing -- and a hard-coded thirteen
	# courses stopped covering this tower the moment a floor went from two
	# plate layers to one and the building got shorter.
	@warning_ignore("integer_division")
	var courses: int = TowerRecipe.total_plates(16) / TowerRecipe.PLATES_PER_COURSE + 1
	var removed := 0
	for y in range(0, courses):
		for z in range(0, 17, 2):
			removed += w.apply_hit(c, xform * Vector3(1.0 * STUD, y * 3 * PLATE, z * STUD),
					1.0).size()
	w.solve_stress(c)
	loose = w.find_detached_groups(c)
	n = 0
	for grp in loose:
		n += grp.size()
	print("  undercut the lowest end (%d bricks): %d block(s) loose in %d group(s)" % [
			removed, n, loose.size()])
	if n > 0:
		print("  ok    removing what a fallen section rests on does something now")
	else:
		print("  FAIL  the fallen section still holds itself up on nothing")


## The snap has to pick the dominant axis, not the first non-zero one.
func _check_gravity_axis() -> void:
	print("gravity snapping")
	var w := BrickWorld.new()
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(4, 4, 4))
	var cases := {
		"upright": [Vector3i(0, -100, 0), Vector3i(0, -1, 0)],
		"on its side (+X down)": [Vector3i(98, -17, 0), Vector3i(1, 0, 0)],
		"on its face (-Z down)": [Vector3i(3, 9, -99), Vector3i(0, 0, -1)],
		"upside down": [Vector3i(0, 100, 0), Vector3i(0, 1, 0)],
	}
	for name in cases:
		var pair: Array = cases[name]
		w.set_chunk_gravity(c, pair[0])
		var got: Vector3i = w.get_chunk_gravity(c)
		if got == pair[1]:
			print("  ok    %s -> %s" % [name, str(got)])
		else:
			print("  FAIL  %s -> %s, expected %s" % [name, str(got), str(pair[1])])
