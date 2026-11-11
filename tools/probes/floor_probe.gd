extends SceneTree

## Does a floor slab hold? Two questions only:
##   1. with nothing damaged, is anything already detached?
##   2. after a hole is punched in ONE wall, do the OTHER floors survive?
## Both were "no" before the slab became two interlocking layers.

func _init() -> void:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var courses := 24
	var fx := 20
	var fz := 16
	var c := w.create_chunk(Vector3i(0, 0, 0), TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, palette, fx, fz, courses)
	var total := w.get_block_count(c)
	print("built %d blocks, %d courses, %d floors" % [
			total, courses, courses / TowerRecipe.COURSES_PER_FLOOR])

	w.solve_grounded(c)
	var loose := w.find_detached_groups(c)
	var loose_blocks := 0
	for g in loose:
		loose_blocks += g.size()
	print("undamaged: %d detached groups, %d blocks" % [loose.size(), loose_blocks])
	if loose_blocks == 0:
		print("ok    an intact building is intact")
	else:
		print("FAIL  %d blocks fall off a building nobody touched" % loose_blocks)

	# Punch a hole low in one wall, the way a rocket would.
	var hit := Vector3(fx * 0.5 * 0.35, 6 * 0.14, 0.0)
	var killed := w.apply_hit(c, hit, 1.2)
	w.solve_grounded(c)
	var after := w.find_detached_groups(c)
	var after_blocks := 0
	var biggest := 0
	for g in after:
		after_blocks += g.size()
		biggest = maxi(biggest, g.size())
	print("one hit: removed %d, then %d groups / %d blocks came loose (biggest %d)" % [
			killed.size(), after.size(), after_blocks, biggest])
	var share := float(after_blocks) / float(total) * 100.0
	print("that is %.1f%% of the building" % share)
	if share < 25.0:
		print("ok    local damage stays local")
	else:
		print("FAIL  one hit detaches %.1f%% of the building" % share)

	_moved_wreckage()
	quit()


## A toppled building is a chunk lying on its side a long way from where it was
## built. Shooting it has to work in WORLD space -- this is the mechanism behind
## "settled wreckage is not always damageable".
func _moved_wreckage() -> void:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(12, 12, 8))
	TowerRecipe.build(w, c, palette, 12, 12, 8)
	var before := w.get_block_count(c)

	# On its side, 40 m away -- the shape a fallen tower actually ends up in.
	var xform := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3(40.0, 0.0, -25.0))
	w.set_chunk_transform(c, xform)

	# Aim at a point ON the wreckage, not at its origin.
	var boxes: Array = w.get_block_boxes(c)
	if boxes.is_empty():
		print("FAIL  no boxes to aim at")
		return
	var far_end: Dictionary = boxes[boxes.size() - 1]
	var aim: Vector3 = xform * (far_end.pos as Vector3)
	var killed := w.apply_hit(c, aim, 1.4)
	print("moved wreckage: %d bricks, hit at %.1f,%.1f,%.1f removed %d" % [
			before, aim.x, aim.y, aim.z, killed.size()])
	if killed.size() > 0:
		print("ok    a chunk that has moved can still be shot where it lies")
	else:
		print("FAIL  the hit missed a chunk that had moved")
