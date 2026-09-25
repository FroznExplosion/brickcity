extends SceneTree

## Acceptance probe for Stage 5 of build mode: fixtures.
##
##     godot --headless --path . --script tools/fixture_probe.gd
##
## The gate, from Docs/BuildMode.md section 11:
##
##   A dormant staircase costs zero chunks and zero bodies; materialises with
##   the building; comes apart with the building; and is ordinary brick while
##   it stands.
##
## The original wording said "materialises on room activation" and "never
## appears in `solve_stress`", and that is what the first implementation did: a
## fixture with a chunk, a body and a materialisation state of its own. It
## produced a building that came down around a staircase left standing in the
## rubble. A staircase in a brick building is **bricks in the same grid**, so
## the gate asks that instead -- built with its host, clipped to its host, and
## going wherever its host's blocks go.
##
## No rendering and no physics. The scene's half is `godot --path . -- --fixture`.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("fixture probe (Stage 5)")
	_check_the_staircase()
	_check_it_rests_on_the_newel()
	_check_dormant_costs_nothing()
	_check_built_with_its_host()
	_check_the_stairwell()
	_check_damage_record()
	_check_it_comes_apart_with_the_building()
	_check_decorative_frames()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _world() -> Array:
	var w := BrickWorld.new()
	# The tower recipe's palette: the host of a fixture here is a generated
	# building and it wants its own cornice in the table.
	return [w, TowerRecipe.bake_palette(w)]


## A tower with a staircase up the middle of it.
func _tower_with_stairs(reg: BuildingRegistry, courses: int = 12) -> Array:
	var id := reg.register(16, 16, courses, Transform3D(Basis(), Vector3(20.0, 0.0, -8.0)))
	var steps := StaircaseRecipe.steps_for_courses(courses)
	@warning_ignore("integer_division")
	var at := Vector3i((16 - StaircaseRecipe.DIAMETER) / 2, TowerRecipe.SLAB_PLATES,
			(16 - StaircaseRecipe.DIAMETER) / 2)
	var fx := reg.add_fixture(id, "staircase", {"steps": steps, "colour": 11}, at)
	return [id, fx, steps]


func _alive_of(w: BrickWorld, chunk: int, ids: PackedInt32Array) -> int:
	var dead := {}
	for id in w.get_dead_blocks(chunk):
		dead[id] = true
	var n := 0
	for id in ids:
		if not dead.has(id):
			n += 1
	return n


# ---------------------------------------------------------------------------

func _check_the_staircase() -> void:
	print("\neight steps a revolution, as masked archetypes and no frames")
	var res := _world()
	var w: BrickWorld = res[0]
	var parts := StaircaseRecipe.bake_parts(w)
	_ok("eight sector archetypes bake", parts.size() == 8, "%d" % parts.size())
	var baked := true
	for id in parts:
		baked = baked and id >= 0
	_ok("all eight are real", baked)

	# The eight masks have to tile one revolution exactly: every cell of the
	# tread annulus in exactly one sector, and the newel in all eight, because
	# every step carries its own slice of the column it rests on.
	var counts := {}
	for s in 8:
		var m: PackedByteArray = StaircaseRecipe._mask(s)
		for i in m.size():
			if m[i] != 0:
				counts[i] = int(counts.get(i, 0)) + 1
	var newel := 0
	var tread := 0
	var shared := 0
	for i in counts:
		var n: int = counts[i]
		if n == 8:
			newel += 1
		elif n == 1:
			tread += 1
		else:
			shared += 1
	_ok("the newel is carried by every step",
			newel == StaircaseRecipe.NEWEL * StaircaseRecipe.NEWEL, "%d cells" % newel)
	_ok("every tread cell belongs to exactly one sector", shared == 0, "%d shared" % shared)
	_ok("and there are treads to stand on", tread > 0, "%d cells" % tread)

	var chunk := w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(16))
	var placed := StaircaseRecipe.build(w, chunk, parts, 16)
	_ok("a flight of sixteen places without a single refusal", placed == 16, "%d" % placed)
	_ok("which is two revolutions", w.get_alive_block_count(chunk) == 16)


func _check_it_rests_on_the_newel() -> void:
	print("\nthe steps rest on the newel rather than hanging off it")
	var res := _world()
	var w: BrickWorld = res[0]
	var parts := StaircaseRecipe.bake_parts(w)
	var chunk := w.create_chunk(Vector3i.ZERO, StaircaseRecipe.chunk_dims(12))
	StaircaseRecipe.build(w, chunk, parts, 12)
	w.set_foundation_level(chunk, 0)

	# Section 9.3: a step CANTILEVERED off a column is right at the failure
	# threshold, so the part is authored to rest on it -- compression, which is
	# free. Grounding is the check that says so.
	var grounded: PackedByteArray = w.solve_grounded(chunk)
	var up := 0
	for v in grounded:
		if v != 0:
			up += 1
	_ok("every step is grounded, through the one below it", up == 12, "%d of 12" % up)
	_ok("so nothing is hanging in the air",
			(w.find_detached_groups(chunk) as Array).is_empty())

	var low: Array = w.get_block_ticks(chunk, 0)
	var high: Array = w.get_block_ticks(chunk, 11)
	var rise: int = (high[0] as Vector3i).y - (low[0] as Vector3i).y
	var want: int = 11 * StaircaseRecipe.STEP_PLATES * BrickWorld.ticks_per_plate()
	_ok("it rises two plates a step", rise == want,
			"%d ticks over eleven steps, wanted %d" % [rise, want])


func _check_dormant_costs_nothing() -> void:
	print("\na building that is still a recipe has no staircase either")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var before: Dictionary = w.get_memory_report()
	var made := _tower_with_stairs(reg)
	var after: Dictionary = w.get_memory_report()
	_ok("attaching a fixture creates no chunk", after.chunks == before.chunks,
			"%d -> %d" % [before.chunks, after.chunks])
	_ok("and no bricks", int(after.total_bytes) == int(before.total_bytes))
	_ok("it has laid nothing yet", reg.get_fixture(made[0], made[1]).blocks.is_empty())
	_ok("the registry counts it without holding it", int(reg.report().fixtures) == 1)
	_ok("dormancy is inherited, not implemented",
			not reg.get_building(made[0]).is_materialised())


func _check_built_with_its_host() -> void:
	print("\nand builds with it, into the same grid")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var made := _tower_with_stairs(reg)
	var id: int = made[0]
	var steps: int = made[2]
	var chunk := reg.materialise(id)
	var f := reg.get_fixture(id, 0)

	_ok("the building materialised", chunk >= 0)
	var pieces := StaircaseRecipe.flight_pieces(steps)
	_ok("its staircase went in with it", f.blocks.size() == pieces,
			"%d of %d" % [f.blocks.size(), pieces])
	_ok("in the building's own chunk, not one of its own",
			int(w.get_memory_report().chunks) == 1,
			"%d chunks" % int(w.get_memory_report().chunks))
	_ok("the steps are the last blocks placed, so the ids are stable",
			f.blocks.size() > 0
			and int(f.blocks[f.blocks.size() - 1]) == w.get_block_count(chunk) - 1)

	# Clipped to the building: this is what makes the flight come apart with a
	# section instead of standing there while one falls off around it.
	var mine := {}
	for step in f.blocks:
		mine[step] = true
	var joined := 0
	for step in f.blocks:
		for n in w.get_block_neighbours(chunk, step):
			if not mine.has(n):
				joined += 1
	_ok("and clipped to the building's own bricks", joined > 0, "%d joints" % joined)

	# It is structure now, and the solve carries it. That is the trade: a
	# staircase that comes apart with the building is one the building can lean
	# on.
	w.solve_grounded(chunk)
	var stress: Dictionary = w.solve_stress(chunk)
	_ok("the stress solve runs over it like anything else", stress.has("failures"))
	_ok("and nothing about it reads as detached",
			(w.find_detached_groups(chunk) as Array).is_empty())

	# Built twice, the same building.
	var again := _world()
	var reg2 := BuildingRegistry.new(again[0], again[1])
	var made2 := _tower_with_stairs(reg2)
	var chunk2 := reg2.materialise(made2[0])
	_ok("building it twice gives the same block count",
			again[0].get_block_count(chunk2) == w.get_block_count(chunk),
			"%d vs %d" % [again[0].get_block_count(chunk2), w.get_block_count(chunk)])
	_ok("and the same ids for the flight",
			reg2.get_fixture(made2[0], 0).blocks == f.blocks)


func _check_the_stairwell() -> void:
	print("\nit carves a stairwell, and that is an edit rather than damage")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])

	# The same tower without a staircase, to compare against.
	var plain := reg.register(16, 16, 12, Transform3D())
	var plain_chunk := reg.materialise(plain)
	var plain_alive := w.get_alive_block_count(plain_chunk)

	var made := _tower_with_stairs(reg)
	var chunk := reg.materialise(made[0])
	var f := reg.get_fixture(made[0], 0)
	var pieces := StaircaseRecipe.flight_pieces(int(made[2]))
	_ok("the flight went in whole, floors and all", f.blocks.size() == pieces,
			"%d of %d" % [f.blocks.size(), pieces])
	_ok("and the shaft cost the building some floor",
			w.get_alive_block_count(chunk) != plain_alive + f.blocks.size(),
			"%d vs %d" % [w.get_alive_block_count(chunk), plain_alive + f.blocks.size()])

	# THE distinction: a carved cell is REMOVED, not killed. A stairwell is not
	# a hole somebody shot, and the damage record must not think it is.
	_ok("nothing in the damage record", w.get_dead_blocks(chunk).is_empty(),
			"%d dead" % w.get_dead_blocks(chunk).size())
	_ok("so the building is undamaged", not reg.get_building(made[0]).is_damaged())


func _check_damage_record() -> void:
	print("\nits steps are the building's bricks, record and all")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var made := _tower_with_stairs(reg)
	var id: int = made[0]
	var chunk := reg.materialise(id)
	var f := reg.get_fixture(id, 0)
	var b := reg.get_building(id)

	var box: Array = w.get_block_ticks(chunk, f.blocks[4])
	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var at: Vector3 = b.xform * (Vector3((box[0] as Vector3i)) * tick_m)
	var before := _alive_of(w, chunk, f.blocks)
	reg.damage(id, at, 1.2)
	var after := _alive_of(w, chunk, f.blocks)
	_ok("a hit on the flight takes steps out", after < before, "%d -> %d" % [before, after])
	_ok("the BUILDING is what is damaged", reg.get_building(id).is_damaged())
	_ok("and the record holds the steps", not reg.get_building(id).dead.is_empty())

	reg.dematerialise(id)
	_ok("the bricks went back", not reg.get_building(id).is_materialised())
	var rebuilt := reg.materialise(id)
	_ok("rebuilt with the same steps missing",
			_alive_of(w, rebuilt, reg.get_fixture(id, 0).blocks) == after,
			"%d vs %d" % [_alive_of(w, rebuilt, reg.get_fixture(id, 0).blocks), after])


func _check_it_comes_apart_with_the_building() -> void:
	print("\nand it comes apart with the building")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var made := _tower_with_stairs(reg)
	var id: int = made[0]
	var chunk := reg.materialise(id)
	var f := reg.get_fixture(id, 0)
	w.solve_grounded(chunk)

	# Cut the building through, low down, and ask what came loose. The flight is
	# clipped to the floors, so a detached section has to bring its steps with
	# it -- which is the whole point of building it into this grid.
	var cut_y := TowerRecipe.SLAB_PLATES + 6
	for x in range(0, 16):
		for z in range(0, 16):
			w.kill_block(chunk, Vector3i(x, cut_y, z))
	w.solve_grounded(chunk)
	var groups: Array = w.find_detached_groups(chunk)
	var loose := 0
	var loose_steps := 0
	for g in groups:
		var ids: PackedInt32Array = g
		loose += ids.size()
		for step in f.blocks:
			if ids.has(step):
				loose_steps += 1
	_ok("cutting the building through detaches a section", loose > 0, "%d blocks" % loose)
	_ok("and the steps above the cut came with it", loose_steps > 0,
			"%d of %d steps" % [loose_steps, f.blocks.size()])
	_ok("most of the flight, not a step or two of it",
			loose_steps >= int(f.blocks.size() * 0.4),
			"%d of %d" % [loose_steps, f.blocks.size()])

	# Handing the building over hands the staircase over with it: one chunk.
	reg.hand_over(id)
	_ok("toppling gives the whole chunk away", not reg.get_building(id).is_materialised())
	_ok("with the flight still in it",
			w.is_chunk_alive(chunk) and _alive_of(w, chunk, f.blocks) > 0)


func _check_decorative_frames() -> void:
	print("\na decorative FRAME, for the things that are welded on")
	var res := _world()
	var w: BrickWorld = res[0]
	var asm := Assembly.new(w, res[1])
	var brick: int = res[1]["brick_2x2"]
	var root := asm.add_frame(Vector3i(8, 16, 8))
	var rail := asm.add_frame(Vector3i(8, 16, 8), 0, Vector3i(40, 0, 0))
	var a := asm.place(root, Vector3i(0, 0, 0), brick, 4)
	var b := asm.place(rail, Vector3i(0, 6, 0), brick, 7)
	var wid := asm.weld(root, a, rail, b)
	_ok("welded on", wid >= 0)

	asm.set_decorative(rail)
	_ok("the frame says it is decorative", asm.is_decorative(rail))
	_ok("and it is not in the structural set",
			not asm.structural_frames().has(rail) and asm.structural_frames().has(root))

	var grounded := asm.solve_grounded()
	_ok("the solve skips it entirely", not grounded.has(rail), "%s" % [grounded.keys()])
	var state := asm.detached_frames()
	_ok("while a weld holds it, it is attached", (state.attached as Array).has(rail))
	_ok("and it is never called detached, because it was never grounded",
			not (state.detached as Array).has(rail))

	w.kill_block(root, Vector3i(0, 0, 0))
	var after := asm.detached_frames()
	_ok("killing the weld releases it", (after.released as Array).has(rail))
	_ok("its own bricks are untouched", w.get_alive_block_count(rail) == 1)

	var post := asm.add_frame(Vector3i(8, 16, 8), 0, Vector3i(80, 0, 0))
	var c := asm.place(post, Vector3i(0, 0, 0), brick, 5)
	asm.weld(rail, b, post, c)
	var third := asm.solve_grounded()
	var post_up := 0
	for v in (third.get(post, PackedByteArray()) as PackedByteArray):
		if v != 0:
			post_up += 1
	_ok("a structural frame is not held up by a decorative one", post_up == 0,
			"%d block(s) grounded through the rail" % post_up)
