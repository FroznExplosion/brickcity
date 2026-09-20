extends SceneTree

## Acceptance probe for Stage 2 of build mode: the workshop.
##
##     godot --headless --path . --script tools/build_probe.gd
##
## The gate, from Docs/BuildMode.md section 11:
##
##   Hand-build a house, save it, place it in the city, shoot it, and have it
##   break and topple like a generated one. Round-trip the recipe and get
##   byte-identical blocks.
##
## Everything here is the logic the workshop scene drives; the scene itself is
## input and drawing. No rendering, no physics.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("build probe (Stage 2)")
	_check_recipe_basics()
	_check_order_is_identity()
	_check_round_trip()
	_check_build_is_deterministic()
	_check_placed_in_city()
	_check_welds_in_the_recipe()
	_check_multi_frame_in_city()
	_check_fixtures_in_the_recipe()
	_check_the_cheap_tier()
	_check_damage_record_keys_survive()
	_check_stress_overlay_inputs()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A small house: a 12x10 footprint, four walls four courses high, a plate roof.
## Built the way the workshop builds -- one part at a time, in order.
func _house() -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = "probe house"
	var w := 12
	var d := 10
	for course in 4:
		var y := 1 + course * 3
		var col := 4 + (course % 3)
		# Alternate which pair of walls owns the corners, so the courses
		# interlock instead of four independent walls standing side by side --
		# the same lesson TowerRecipe records.
		var flip := course % 2 == 1
		var x0 := 0 if flip else 2
		var x1 := w if flip else w - 2
		for x in range(x0, x1, 2):
			r.add("brick_2x2", Vector3i(x, y, 0), col)
			r.add("brick_2x2", Vector3i(x, y, d - 2), col)
		var z0 := 2 if flip else 0
		var z1 := d - 2 if flip else d
		for z in range(z0, z1, 2):
			r.add("brick_2x2", Vector3i(0, y, z), col)
			r.add("brick_2x2", Vector3i(w - 2, y, z), col)
	# Roof: two offset plate layers, for the same reason TowerRecipe's floors are
	# two -- stud connectivity is vertical, so one layer of plates side by side
	# is not joined to itself at all.
	for layer in 2:
		var y := 13 + layer
		for x in range(0, w, 4):
			for z in range(0, d, 4):
				r.add("plate_4x4", Vector3i(x, y, z), 2)
	return r


func _world() -> Array:
	var w := BrickWorld.new()
	return [w, BrickPalette.bake(w)]


# ---------------------------------------------------------------------------

func _check_recipe_basics() -> void:
	print("\nrecipe basics")
	var r := BuildRecipe.new()
	_ok("a new recipe is empty", r.is_empty() and r.size() == 0)

	var a := r.add("brick_2x4_x", Vector3i(0, 0, 0), 4)
	var b := r.add("brick_2x4_x", Vector3i(4, 0, 0), 5)
	var c := r.add("plate_2x2", Vector3i(0, 3, 0), 2)
	_ok("ids are 0, 1, 2 in placement order", a == 0 and b == 1 and c == 2)
	_ok("distinct parts are pooled, not repeated", r.parts.size() == 2,
			"%s" % [r.parts])
	_ok("a block remembers its part", r.part_of(1) == "brick_2x4_x")
	_ok("and its cell", r.cell_of(1) == Vector3i(4, 0, 0))
	_ok("and its colour", r.colour_of(1) == 5)

	_ok("pop removes the last one", r.pop() and r.size() == 2)
	_ok("and the survivors are untouched",
			r.part_of(0) == "brick_2x4_x" and r.cell_of(1) == Vector3i(4, 0, 0))
	_ok("popping an empty recipe is refused",
			BuildRecipe.new().pop() == false)

	var bounds := r.bounds()
	_ok("bounds start at the min corner", bounds[0] == Vector3i(0, 0, 0), "%v" % bounds[0])
	_ok("bounds cover the far corner of the far part", bounds[1] == Vector3i(8, 3, 2),
			"%v" % bounds[1])


func _check_order_is_identity() -> void:
	print("\nplacement order IS block id order")
	var r := _house()
	var res := _world()
	var w: BrickWorld = res[0]
	var chunk: int = w.create_chunk(Vector3i.ZERO, r.chunk_dims())
	var placed := r.build(w, chunk, res[1])
	_ok("every brick in the recipe was placed", placed == r.size(),
			"%d of %d" % [placed, r.size()])

	# The contract the damage record rides on: recipe index i is chunk block i.
	var mismatched := 0
	var lo: Vector3i = r.origin()
	for i in r.size():
		if w.get_block_archetype(chunk, i) != res[1][r.part_of(i)]:
			mismatched += 1
		elif w.block_at(chunk, r.cell_of(i) - lo) != i:
			mismatched += 1
	_ok("recipe index i is chunk block i, for every brick", mismatched == 0,
			"%d mismatched" % mismatched)


func _check_round_trip() -> void:
	print("\nsave -> load -> identical")
	var r := _house()
	var path := "user://_probe_house.json"
	_ok("saved", r.save_to(path) == OK)
	var back := BuildRecipe.load_from(path)
	_ok("loaded", not back.is_empty())
	_ok("same name", back.name == r.name)
	_ok("same brick count", back.size() == r.size(), "%d vs %d" % [back.size(), r.size()])

	var diff := 0
	for i in r.size():
		if back.cell_of(i) != r.cell_of(i) or back.part_of(i) != r.part_of(i) \
				or back.colour_of(i) != r.colour_of(i):
			diff += 1
	_ok("every brick survives the round trip unchanged", diff == 0, "%d differ" % diff)

	# And what it builds is byte-identical, which is the claim that matters.
	var r1 := _world()
	var c1: int = r1[0].create_chunk(Vector3i.ZERO, r.chunk_dims())
	r.build(r1[0], c1, r1[1])
	var r2 := _world()
	var c2: int = r2[0].create_chunk(Vector3i.ZERO, back.chunk_dims())
	back.build(r2[0], c2, r2[1])
	var m1: Array = r1[0].build_chunk_mesh(c1)
	var m2: Array = r2[0].build_chunk_mesh(c2)
	_ok("the meshes are byte-identical",
			m1[Mesh.ARRAY_VERTEX] == m2[Mesh.ARRAY_VERTEX])
	_ok("and so are the colours", m1[Mesh.ARRAY_COLOR] == m2[Mesh.ARRAY_COLOR])

	# A version bump must discard rather than misread.
	var d := r.to_dict()
	d["version"] = BuildRecipe.VERSION + 1
	_ok("a recipe from a future version is refused, not misread",
			BuildRecipe.from_dict(d).is_empty())


func _check_build_is_deterministic() -> void:
	print("\nbuilding twice gives the same building")
	var r := _house()
	var a := _world()
	var b := _world()
	var ca: int = a[0].create_chunk(Vector3i.ZERO, r.chunk_dims())
	var cb: int = b[0].create_chunk(Vector3i.ZERO, r.chunk_dims())
	r.build(a[0], ca, a[1])
	r.build(b[0], cb, b[1])
	_ok("same block count", a[0].get_block_count(ca) == b[0].get_block_count(cb))

	a[0].set_foundation_level(ca, 0)
	b[0].set_foundation_level(cb, 0)
	a[0].solve_grounded(ca)
	b[0].solve_grounded(cb)
	var ga: Array = a[0].find_detached_groups(ca)
	var gb: Array = b[0].find_detached_groups(cb)
	_ok("same grounding result", ga.size() == gb.size(), "%d vs %d" % [ga.size(), gb.size()])


func _check_placed_in_city() -> void:
	print("\nplaced in the city, and shot")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var r := _house()

	var id := reg.register_build(r, Transform3D())
	_ok("registered as a building", id >= 0)
	_ok("it knows it is a build", reg.get_building(id).is_build())
	_ok("registering costs no bricks", not reg.get_building(id).is_materialised())

	var chunk := reg.materialise(id)
	_ok("materialised", chunk >= 0)
	var before := w.get_alive_block_count(chunk)
	_ok("the whole house is there", before == r.size(), "%d of %d" % [before, r.size()])

	# Shoot a wall low down.
	var hit := reg.damage(id, BrickWorld.grid_to_world(Vector3i(6, 2, 0)), 1.2)
	_ok("the hit removed bricks", hit.size() > 0, "%d" % hit.size())
	_ok("it is damaged now", reg.get_building(id).is_damaged())

	# It has to break like a generated building, which means the same solve runs
	# on it and reaches a sane answer -- local damage, not a collapsing house.
	w.set_foundation_level(chunk, 0)
	w.solve_grounded(chunk)
	var groups := w.find_detached_groups(chunk)
	var loose := 0
	for g in groups:
		loose += (g as PackedInt32Array).size()
	_ok("the solve runs on a player build", true)
	_ok("local damage stays local", loose < before / 4,
			"%d of %d blocks came loose" % [loose, before])

	var stress: Dictionary = w.solve_stress(chunk)
	_ok("the stress solve runs on it too", stress.has("failures"), "%s" % [stress.keys()])


## Which of the 24 rotations sends a grid own +Y to this world axis. Looked up
## rather than hard-coded: the enumeration order is the extension business.
func _rotation_with_up(w: BrickWorld, up: Vector3) -> int:
	var probe := w.create_chunk(Vector3i.ZERO, Vector3i(1, 1, 1))
	var found := -1
	for r in BrickWorld.rotation_count():
		w.set_chunk_frame(probe, r, Vector3i.ZERO)
		if w.get_chunk_transform(probe).basis.y.is_equal_approx(up):
			found = r
			break
	w.release_chunk(probe)
	return found


## The recipe id of the first block placed at this cell in frame 0.
func _block_at(r: BuildRecipe, cell: Vector3i) -> int:
	for i in r.size():
		if r.frame_of(i) == 0 and r.cell_of(i) == cell:
			return i
	return -1


## The house, plus a sideways panel: a second frame whose own up points along
## world +X, hung off the house by two welds.
##
## The panel is deliberately NOT touching the wall. A weld is declared, not
## inferred from adjacency (Docs/BuildMode.md section 2.4), so a check that says
## "the panel is held on" cannot be passed by accident by something resting on
## something else.
func _panelled_house(w: BrickWorld) -> Array:
	var r := _house()
	r.name = "probe house with panel"
	var rot := _rotation_with_up(w, Vector3(1.0, 0.0, 0.0))
	var t := BrickWorld.ticks_per_stud()
	# Clear of the house, which ends at x = 12 studs.
	var f := r.add_frame(rot, Vector3i(14 * t, 0, 0))
	var panel := PackedInt32Array()
	for i in 3:
		panel.push_back(r.add("brick_2x2", Vector3i(0, i * 3, i * 2), 6, f))
	# Two welds, from two different courses of the +X wall.
	r.add_weld(_block_at(r, Vector3i(10, 1, 4)), panel[0])
	r.add_weld(_block_at(r, Vector3i(10, 7, 4)), panel[1])
	return [r, f, rot, panel]


func _check_welds_in_the_recipe() -> void:
	print("\nwelds are part of the recipe, not of the session that made them")
	var res := _world()
	var w: BrickWorld = res[0]
	var made := _panelled_house(w)
	var r: BuildRecipe = made[0]
	_ok("the recipe has two frames", r.frame_count() == 2, "%d" % r.frame_count())
	_ok("and two welds", r.weld_count() == 2, "%d" % r.weld_count())

	# Round trip. A weld that does not survive the save is a frame that falls
	# off the moment the build is loaded anywhere else.
	var back := BuildRecipe.from_dict(r.to_dict())
	_ok("the welds survive a round trip", back.weld_count() == r.weld_count())
	var same := true
	for i in r.weld_count():
		same = same and back.weld_blocks(i) == r.weld_blocks(i)
	_ok("and they still name the same blocks", same)
	_ok("so do the frames", back.frame_count() == r.frame_count()
			and back.frame_rotation(1) == r.frame_rotation(1)
			and back.frame_ticks(1) == r.frame_ticks(1))

	# A v1 file has no weld column. It has to LOAD -- v2 only adds a column --
	# and it has to load with no welds, because none were ever recorded.
	var old := r.to_dict()
	old["version"] = 1
	old.erase("welds")
	var v1 := BuildRecipe.from_dict(old)
	_ok("a v1 recipe still loads", v1.size() == r.size())
	_ok("with no welds, which is what it was saved with", v1.weld_count() == 0)

	# Undo drops the welds that pointed at what it removed, or the recipe
	# carries a weld to a block that does not exist.
	var n := r.weld_count()
	var last := r.size() - 1
	var touching := 0
	for i in n:
		var ww := r.weld_blocks(i)
		if ww.x == last or ww.y == last:
			touching += 1
	r.pop()
	_ok("undo drops the welds that named the block it removed",
			r.weld_count() == n - touching, "%d -> %d" % [n, r.weld_count()])


func _check_multi_frame_in_city() -> void:
	print("\na multi-frame build placed in the city")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var made := _panelled_house(w)
	var r: BuildRecipe = made[0]

	# Placed somewhere that is neither the origin nor axis-aligned, because a
	# frame offset that only works at the origin is not an offset.
	var place := Transform3D(Basis(Vector3.UP, 0.7), Vector3(31.0, 0.0, -12.0))
	var id := reg.register_build(r, place)
	_ok("a multi-frame build registers", id >= 0)

	var chunk := reg.materialise(id)
	var b := reg.get_building(id)
	_ok("materialised", chunk >= 0)
	_ok("as two chunks, one per frame", b.chunks().size() == 2, "%d" % b.chunks().size())
	_ok("every brick is there", b.blocks == r.size(), "%d of %d" % [b.blocks, r.size()])
	_ok("the assembly holds both welds", b.asm != null and b.asm.live_weld_count() == 2,
			"%d" % (b.asm.live_weld_count() if b.asm != null else -1))

	# The frames have to keep their exact offset wherever the building is put.
	# The offset is stored in ticks, so this is the one thing a float placement
	# could quietly ruin.
	var t := BrickWorld.ticks_per_stud()
	var tick_m: float = BrickWorld.get_cell_size().x / float(t)
	var root_x: Transform3D = w.get_chunk_transform(b.frames[0])
	var panel_x: Transform3D = w.get_chunk_transform(b.frames[1])
	var offset: Vector3 = root_x.affine_inverse() * panel_x.origin
	_ok("the panel sits exactly 14 studs along, wherever the building is placed",
			offset.is_equal_approx(Vector3(14.0 * t * tick_m, 0.0, 0.0)), "%v" % offset)
	_ok("and it is still turned the way it was authored",
			panel_x.basis.y.is_equal_approx(place.basis * Vector3(1.0, 0.0, 0.0)),
			"%v" % panel_x.basis.y)

	# Grounded THROUGH the welds: the panel has no foundation of its own.
	var grounded: Dictionary = b.asm.solve_grounded()
	var panel_up := 0
	for v in (grounded.get(b.frames[1], PackedByteArray()) as PackedByteArray):
		if v != 0:
			panel_up += 1
	_ok("the panel is grounded through its welds", panel_up > 0, "%d blocks" % panel_up)
	_ok("so nothing has come loose", (b.asm.detached_frames().detached as Array).is_empty())

	# Damage lands in the frame it hit, and only in that one.
	var panel_point: Vector3 = panel_x * BrickWorld.grid_to_world(Vector3i(1, 1, 1))
	var before := w.get_alive_block_count(b.frames[1])
	reg.damage(id, panel_point, 1.0)
	var after := w.get_alive_block_count(b.frames[1])
	_ok("a hit on the panel removes panel bricks", after < before,
			"%d -> %d" % [before, after])
	_ok("and the record keeps it under that frame", not b.dead_in(1).is_empty())
	_ok("while the house own record is untouched", b.dead_in(0).is_empty(),
			"%d" % b.dead_in(0).size())

	# And it survives the bricks being handed back, for every frame.
	var house_before := w.get_alive_block_count(b.frames[0])
	reg.damage(id, place * BrickWorld.grid_to_world(Vector3i(6, 2, 0)), 1.2)
	var house_after := w.get_alive_block_count(b.frames[0])
	_ok("the house takes damage too", house_after < house_before)
	reg.dematerialise(id)
	_ok("the bricks went back", not b.is_materialised())
	_ok("both frames kept a record", not b.dead_in(0).is_empty() and not b.dead_in(1).is_empty())
	reg.materialise(id)
	_ok("rebuilt with the same bricks missing in the house",
			w.get_alive_block_count(b.frames[0]) == house_after,
			"%d vs %d" % [w.get_alive_block_count(b.frames[0]), house_after])
	_ok("and the same ones missing in the panel",
			w.get_alive_block_count(b.frames[1]) == after,
			"%d vs %d" % [w.get_alive_block_count(b.frames[1]), after])

	# Kill what holds the panel on, and the panel comes off -- whole, with its
	# own bricks intact. That is the Stage 4 gate, now through a city placement.
	for wid in b.asm.welds:
		var weld: Dictionary = w.get_weld(wid)
		w.kill_blocks(int(weld.chunk_a), PackedInt32Array([int(weld.block_a)]))
	_ok("killing both anchors kills both welds", b.asm.live_weld_count() == 0)
	var loose: Array = b.asm.detached_frames().detached
	_ok("and the panel is the frame that comes off",
			loose.size() == 1 and int(loose[0]) == b.frames[1], "%s" % [loose])
	_ok("with its own bricks still standing",
			w.get_alive_block_count(b.frames[1]) > 0)

func _check_fixtures_in_the_recipe() -> void:
	print("\nwhat was fixed to it in the workshop travels with it")
	var res := _world()
	var w: BrickWorld = res[0]
	var r := _house()
	# Where the workshop would put one: inside the walls, on the floor.
	var at := Vector3i(4, 1, 4)
	var idx := r.add_fixture("staircase", at, {"steps": 12, "colour": 11})
	_ok("a fixture attaches to the recipe", idx == 0 and r.fixture_count() == 1)
	var f := r.fixture_at(0)
	_ok("it remembers what it is and where", f.kind == "staircase" and f.cell == at)
	_ok("and what it was authored with", int((f.params as Dictionary).get("steps", 0)) == 12)

	# Through the FILE, not only through to_dict: JSON has no integer type, and
	# a staircase of 12.0 steps is the kind of thing that loads fine and then
	# builds nothing.
	var path := "user://_probe_fixture.json"
	_ok("saved", r.save_to(path) == OK)
	var back := BuildRecipe.load_from(path)
	_ok("the fixture survives the file", back.fixture_count() == 1)
	var bf := back.fixture_at(0)
	_ok("with its cell intact", bf.cell == at, "%v" % bf.cell)
	_ok("and its parameters still whole numbers",
			typeof((bf.params as Dictionary).get("steps")) == TYPE_INT
			and int((bf.params as Dictionary).get("steps")) == 12,
			"%s" % [(bf.params as Dictionary).get("steps")])
	_ok("and it is decorative, which is what keeps it out of the solve",
			int(bf.role) == Fixture.Role.DECORATIVE)

	# A recipe saved before fixtures existed has no column for them at all.
	var old := r.to_dict()
	old["version"] = 2
	old.erase("fixtures")
	_ok("a v2 recipe still loads", BuildRecipe.from_dict(old).size() == r.size())
	_ok("with no fixtures, which is what it was saved with",
			BuildRecipe.from_dict(old).fixture_count() == 0)

	_ok("undo drops the last fixture", r.pop_fixture() and r.fixture_count() == 0)
	r.add_fixture("staircase", at, {"steps": 12, "colour": 11})

	# Placed in the city, it arrives DORMANT and in the right place. The build is
	# rebased to its own min corner when it is placed, so the fixture has to move
	# with it -- this is the check that says the two rebases agree.
	var reg := BuildingRegistry.new(w, res[1])
	var place := Transform3D(Basis(Vector3.UP, 0.9), Vector3(-14.0, 0.0, 23.0))
	var id := reg.register_build(r, place)
	var b := reg.get_building(id)
	_ok("the building carries the fixture", b.fixtures.size() == 1)
	_ok("and lays no bricks for it until the building is built",
			b.fixtures[0].blocks.is_empty())
	var lo: Vector3i = r.origin()

	# The same recipe with a second frame rebases in the TRANSFORM rather than in
	# the cells. The fixture has to land in the same place either way.
	var made := _panelled_house(w)
	var multi: BuildRecipe = made[0]
	multi.add_fixture("staircase", at, {"steps": 12, "colour": 11})
	var multi_id := reg.register_build(multi, place)
	var mb := reg.get_building(multi_id)
	_ok("a multi-frame build carries it too", mb.fixtures.size() == 1)
	_ok("both hold the cell the author gave it",
			(b.fixtures[0].cell as Vector3i) == at
			and (mb.fixtures[0].cell as Vector3i) == at)

	# Built, it is bricks in the building's own chunk -- and the two rebases
	# have to agree, because a single-frame placement moves the CELLS and a
	# multi-frame one moves the TRANSFORM.
	var chunk: int = reg.materialise(id)
	var built := reg.get_fixture(id, 0)
	_ok("the flight goes in with the house", built.blocks.size() == 12,
			"%d of 12" % built.blocks.size())
	_ok("into the building's own chunk", int(w.get_memory_report().chunks) == 1,
			"%d chunks" % int(w.get_memory_report().chunks))

	var tick_m: float = BrickWorld.get_cell_size().x / float(BrickWorld.ticks_per_stud())
	var box: Array = w.get_block_ticks(chunk, built.blocks[0])
	var world_at: Vector3 = w.get_chunk_transform(chunk) * (Vector3((box[0] as Vector3i)) * tick_m)
	var cell := BrickWorld.get_cell_size()
	var want: Vector3 = place * Vector3((at.x - lo.x) * cell.x, (at.y - lo.y) * cell.y,
			(at.z - lo.z) * cell.z)
	_ok("and it stands where the author put it, rebased with the bricks",
			world_at.distance_to(want) < cell.x, "%v vs %v" % [world_at, want])

	var multi_chunk: int = reg.materialise(multi_id)
	var mf := reg.get_fixture(multi_id, 0)
	var mbox: Array = w.get_block_ticks(multi_chunk, mf.blocks[0])
	var multi_at: Vector3 = w.get_chunk_transform(multi_chunk) 			* (Vector3((mbox[0] as Vector3i)) * tick_m)
	_ok("and lands in the same place under the other rebase",
			multi_at.distance_to(world_at) < cell.x, "%v vs %v" % [multi_at, world_at])


func _check_the_cheap_tier() -> void:
	print("\nwhat a creation looks like when nobody is near it")
	var res := _world()
	var w: BrickWorld = res[0]
	var made := _panelled_house(w)
	var r: BuildRecipe = made[0]

	var intact := BuildShell.build_arrays(w, r)
	var verts: PackedVector3Array = intact[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = intact[Mesh.ARRAY_INDEX]
	_ok("a build gets a shell of its own", not verts.is_empty(), "%d verts" % verts.size())
	_ok("with a whole number of triangles", idx.size() % 3 == 0)
	_ok("and far fewer than its bricks would draw", idx.size() / 3 < r.size() * 12,
			"%d triangles for %d bricks" % [idx.size() / 3, r.size()])
	_ok("it carries the seam shader's units, so it still reads as brick",
			not (intact[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).is_empty())
	_ok("and a colour per vertex",
			(intact[Mesh.ARRAY_COLOR] as PackedColorArray).size() == verts.size())

	# Same recipe, same shell. The cheap tier is derived, so it has to be a pure
	# function of what it is derived from.
	var twice := BuildShell.build_arrays(w, r)
	_ok("built twice, byte-identical", (twice[Mesh.ARRAY_VERTEX] as PackedVector3Array) == verts)

	# The coarse tier is coarser.
	var coarse := BuildShell.build_arrays(w, r, [], BuildShell.COARSE)
	_ok("the far tier draws less",
			(coarse[Mesh.ARRAY_INDEX] as PackedInt32Array).size() < idx.size(),
			"%d vs %d indices" % [(coarse[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), idx.size()])

	# THE claim: the shell shows the damage the truth layer is holding. A tower
	# cannot ask "is block N dead" and takes a band mask instead; a build's
	# shell walks block ids and simply leaves them out.
	var gone := {}
	for i in range(0, mini(60, r.size())):
		gone[i] = true
	var damaged := BuildShell.build_arrays(w, r, [gone, {}])
	_ok("a damaged build draws a damaged shell",
			(damaged[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() != verts.size(),
			"%d verts against %d intact" % [
				(damaged[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), verts.size()])

	# The sideways frame is in the silhouette, not a special case: its cells are
	# mapped into root ticks and dropped into the same voxel grid.
	var frame0 := BuildRecipe.new()
	for i in r.size():
		if r.frame_of(i) == 0:
			frame0.add(r.part_of(i), r.cell_of(i), r.colour_of(i))
	var without := BuildShell.voxels(w, frame0)
	var with_panel := BuildShell.voxels(w, r)
	_ok("a rotated frame is part of the shell", with_panel.size() > without.size(),
			"%d voxels against %d" % [with_panel.size(), without.size()])

	# Nothing left standing is a mesh with no surface, not a crash.
	var all_gone := {}
	for i in r.size():
		all_gone[i] = true
	var empty := BuildShell.build_mesh(w, r, [all_gone, all_gone])
	_ok("a build with nothing left draws nothing", empty.get_surface_count() == 0)

	# Collision: a few boxes, and they have to cover the thing.
	var boxes := BuildShell.collision_boxes(w, r)
	_ok("it is solid, in a handful of boxes", boxes.size() > 0 and boxes.size() < 200,
			"%d boxes" % boxes.size())
	var cover := AABB((boxes[0].pos as Vector3) - (boxes[0].size as Vector3) * 0.5,
			boxes[0].size as Vector3)
	for box in boxes:
		cover = cover.merge(AABB((box.pos as Vector3) - (box.size as Vector3) * 0.5,
				box.size as Vector3))
	var want := r.chunk_dims()
	var cell := BrickWorld.get_cell_size()
	_ok("covering the build it was made from",
			cover.size.x >= want.x * cell.x * 0.5 and cover.size.y >= want.y * cell.y * 0.5,
			"%v against a build of %v" % [cover.size, want])


func _check_damage_record_keys_survive() -> void:
	print("\ndamage survives de-materialisation, as for any recipe")
	var res := _world()
	var w: BrickWorld = res[0]
	var reg := BuildingRegistry.new(w, res[1])
	var r := _house()
	var id := reg.register_build(r, Transform3D())
	var chunk := reg.materialise(id)
	var before := w.get_alive_block_count(chunk)

	reg.damage(id, BrickWorld.grid_to_world(Vector3i(6, 2, 0)), 1.2)
	var standing := w.get_alive_block_count(chunk)
	_ok("bricks are gone", standing < before, "%d -> %d" % [before, standing])

	reg.dematerialise(id)
	_ok("the bricks were handed back", not reg.get_building(id).is_materialised())
	_ok("the damage record kept them", not reg.get_building(id).dead.is_empty())

	var again := reg.materialise(id)
	_ok("rebuilt", again >= 0)
	_ok("the SAME bricks are missing", w.get_alive_block_count(again) == standing,
			"%d vs %d" % [w.get_alive_block_count(again), standing])


func _check_stress_overlay_inputs() -> void:
	print("
the overlay reads the destruction solver, not a new one")
	var res := _world()
	var w: BrickWorld = res[0]

	# A plain stack first. Compression is FREE (BrickFailure 4.1), so a tower
	# standing on its own base must report zero load ratio and no capacity at
	# all -- "a standing tower is stable forever" is the claim, and the overlay
	# showing nothing here is correct rather than broken.
	var stack: int = w.create_chunk(Vector3i.ZERO, Vector3i(8, 32, 8))
	w.place_block(stack, Vector3i(0, 0, 0), res[1]["plate_2x2"], 2)
	for y in 5:
		w.place_block(stack, Vector3i(0, 1 + y * 3, 0), res[1]["brick_2x2"], 4)
	w.set_foundation_level(stack, 0)
	w.solve_grounded(stack)
	var flat: Dictionary = w.solve_stress(stack)
	_ok("a plain stack solves", flat.has("failures"))
	_ok("and carries real weight", float(flat.peak_load) > 0.0, "%.2f" % flat.peak_load)
	_ok("but loads NO joint, because compression is free",
			is_equal_approx(w.get_max_stress_ratio(stack), 0.0),
			"%.4f" % w.get_max_stress_ratio(stack))

	# Now a real tension case: something hanging with no downward path to ground.
	# A column, a long brick overhanging it, and a brick clipped UNDERNEATH the
	# overhanging end -- its only route to the foundation runs upward, which is
	# exactly the joint BrickFailure 4.2 says can fail.
	var c: int = w.create_chunk(Vector3i.ZERO, Vector3i(16, 32, 8))
	w.place_block(c, Vector3i(0, 0, 0), res[1]["plate_2x2"], 2)
	for y in 3:
		w.place_block(c, Vector3i(0, 1 + y * 3, 0), res[1]["brick_2x2"], 4)
	var arm := w.place_block(c, Vector3i(0, 10, 0), res[1]["brick_1x6_x"], 6)
	var hung := w.place_block(c, Vector3i(4, 7, 0), res[1]["brick_2x2"], 5)
	_ok("the overhang and the hanging brick both placed", arm >= 0 and hung >= 0)
	_ok("the hanging brick is joined to the overhang",
			w.get_block_neighbours(c, hung).has(arm))

	w.set_foundation_level(c, 0)
	w.solve_grounded(c)
	var stress: Dictionary = w.solve_stress(c)
	_ok("the solve produced a report", stress.has("failures"))
	_ok("a hanging brick puts its joint in TENSION",
			w.get_max_stress_ratio(c) > 0.0, "%.4f of capacity" % w.get_max_stress_ratio(c))

	# Capacity is contact area, which is what the overlay divides by.
	var caps := 0
	for i in w.get_block_count(c):
		if w.get_block_capacity(c, i) > 0.0:
			caps += 1
	_ok("a tension joint reports a capacity the overlay can divide by", caps > 0, "%d" % caps)
