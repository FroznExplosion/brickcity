extends SceneTree

## What actually comes loose when a building is hit?
##
## Reported: "rather than buildings breaking in half they just break a few
## individual bricks off and a lot of the flooring". Flooring is plates -- one
## plate tall against a brick's three -- so this counts what detaches by part
## height and by group size, which is the only way to tell "the floors are weak"
## from "plates are simply smaller so there are more of them".

const STUD := 0.35
const PLATE := 0.14


func _init() -> void:
	_shed_profile()
	quit()


## Height in plates of each block, so a detached set can be split into flooring
## and walling.
func _heights(w: BrickWorld, c: int) -> Dictionary:
	var out := {}
	for box in w.get_block_boxes(c):
		var size: Vector3 = box.size
		out[int(box.block)] = int(round(size.y / PLATE))
	return out


func _describe(label: String, groups: Array, heights: Dictionary) -> void:
	var plates := 0
	var bricks := 0
	var total := 0
	var biggest := 0
	var singles := 0
	for g in groups:
		var ids: PackedInt32Array = g
		total += ids.size()
		biggest = maxi(biggest, ids.size())
		if ids.size() == 1:
			singles += 1
		for bid in ids:
			if int(heights.get(bid, 3)) <= 2:
				plates += 1
			else:
				bricks += 1
	if total == 0:
		print("  %s: nothing came loose" % label)
		return
	print("  %s: %d block(s) in %d group(s) — %d plate (%.0f%%), %d brick; biggest %d, %d lone brick(s)" % [
			label, total, groups.size(), plates,
			float(plates) / total * 100.0, bricks, biggest, singles])


func _shed_profile() -> void:
	print("what comes loose when a wall is blown out")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var fx := 20
	var fz := 16
	var courses := 24
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w, c, palette, fx, fz, courses)
	w.set_tension_per_stud(c, 9.3)

	var heights := _heights(w, c)
	var plates_total := 0
	for h in heights.values():
		if int(h) <= 2:
			plates_total += 1
	print("  built %d blocks, %d of them plates (%.0f%% of the building is flooring)" % [
			heights.size(), plates_total, float(plates_total) / heights.size() * 100.0])

	# Blow a hole through one wall, low down: the shape a rocket makes.
	var killed := 0
	for course in range(1, 4):
		var y := course * TowerRecipe.PLATES_PER_COURSE * PLATE
		killed += w.apply_hit(c, Vector3(fx * 0.5 * STUD, y, 0.2), 1.6).size()
	print("  blew out %d brick(s) of one wall" % killed)

	w.solve_stress(c)
	_describe("detached after the hit", w.find_detached_groups(c), heights)

	# And what a landing-style shear does to the same building.
	var w2 := BrickWorld.new()
	var p2 := TowerRecipe.bake_palette(w2)
	var c2 := w2.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w2, c2, p2, fx, fz, courses)
	w2.set_tension_per_stud(c2, 9.3)
	var h2 := _heights(w2, c2)
	var aim := Vector3(fx * 0.5 * STUD, 8 * 3 * PLATE, fz * 0.5 * STUD)

	# Uncapped first, on a throwaway copy, to show what the sphere selects.
	var w3 := BrickWorld.new()
	var p3 := TowerRecipe.bake_palette(w3)
	var c3 := w3.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w3, c3, p3, fx, fz, courses)
	var raw := w3.separate_near(c3, aim, 2.6)
	var h3 := _heights(w3, c3)
	var rp := 0
	for bid in raw:
		if int(h3.get(bid, 3)) <= 2:
			rp += 1
	print("  uncapped sweep at r=2.6 m: %d block(s), %d plates (%.0f%%)" % [
			raw.size(), rp, float(rp) / maxf(raw.size(), 1) * 100.0])

	var loosened := w2.separate_near(c2, aim, 2.6, IslandManager.SHEAR_MAX_BLOCKS)
	var lp := 0
	for bid in loosened:
		if int(h2.get(bid, 3)) <= 2:
			lp += 1
	print("  capped sweep (SHEAR_MAX_BLOCKS): %d block(s), %d plates (%.0f%%)" % [
			loosened.size(), lp, float(lp) / maxf(loosened.size(), 1) * 100.0])
	w2.solve_stress(c2)
	_describe("detached after the shear", w2.find_detached_groups(c2), h2)

	# The same sweep, peeling instead of shearing. This is the difference
	# between a brick model and concrete: peel severs only the underside of the
	# struck region, so it comes away as one clump held by its running bond
	# rather than as a spray of single bricks.
	var w4 := BrickWorld.new()
	w4.set_seed(4)
	var p4 := TowerRecipe.bake_palette(w4)
	var c4 := w4.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(fx, fz, courses))
	TowerRecipe.build(w4, c4, p4, fx, fz, courses)
	w4.set_tension_per_stud(c4, 9.3)
	var h4 := _heights(w4, c4)
	var peeled := w4.separate_near(c4, aim, 2.6, IslandManager.SHEAR_MAX_BLOCKS, true)
	print("  peeled sweep: %d joint(s) severed (vs %d blocks isolated by shear)" % [
			peeled.size(), loosened.size()])
	w4.solve_stress(c4)
	_describe("detached after the peel", w4.find_detached_groups(c4), h4)
