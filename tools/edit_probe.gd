extends SceneTree

## Acceptance probe for Stage 1 of build mode: an EDITABLE chunk.
##
##     godot --headless --path . --script tools/edit_probe.gd
##
## Docs/BuildMode.md section 11. Three calls, and the whole of build mode sits
## on them:
##
##   remove_block   undo a placement and give the cells back
##   can_place      would this fit here? (the ghost's red state)
##   would_connect  how many stud joints would it make? (cyan vs amber)
##
## The gate: place -> remove -> re-place must leave the chunk indistinguishable
## from never having placed at all. Damage must stay unaffected -- a destroyed
## block still owns its cells, deliberately, and editing must not quietly change
## that.

var _pass := 0
var _fail := 0
var _world: BrickWorld
var _palette: Dictionary


func _init() -> void:
	print("edit probe")
	_world = BrickWorld.new()
	_palette = BrickPalette.bake(_world)

	_check_remove_frees_cells()
	_check_round_trip_is_identical()
	_check_remove_is_not_damage()
	_check_kill_still_holds_its_cells()
	_check_can_place()
	_check_would_connect()
	_check_tint_states()

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _chunk(dims := Vector3i(16, 16, 16)) -> int:
	return _world.create_chunk(Vector3i.ZERO, dims)


func _a(name: String) -> int:
	return _palette[name]


# ---------------------------------------------------------------------------

func _check_remove_frees_cells() -> void:
	print("\nremove frees the cells")
	var c := _chunk()
	var id := _world.place_block(c, Vector3i(0, 0, 0), _a("brick_2x4_x"), 0)
	_ok("placed", id >= 0)
	_ok("its cells are claimed", _world.is_solid(c, Vector3i(3, 2, 1)))
	_ok("and it is where it says", _world.block_at(c, Vector3i(3, 2, 1)) == id)

	_ok("removed", _world.remove_block(c, id))
	_ok("the cells are free again", not _world.is_solid(c, Vector3i(3, 2, 1)))
	_ok("and nothing owns them", _world.block_at(c, Vector3i(3, 2, 1)) == -1)
	_ok("removing twice does nothing", not _world.remove_block(c, id))
	_ok("a bad id is refused", not _world.remove_block(c, 999))

	# The point of the whole call: the space is REUSABLE.
	var again := _world.place_block(c, Vector3i(0, 0, 0), _a("brick_2x4_x"), 0)
	_ok("something else can be built there now", again >= 0)
	_ok("and it is a new block, not the old one", again != id)

	# A masked part gives back only what it owned. The buttress leaves its notch
	# free, so a neighbour sitting in the notch must survive its removal.
	var c2 := _chunk()
	var butt := TowerRecipe.bake_buttress(_world)
	var m := _world.place_block(c2, Vector3i(0, 0, 0), butt, 0)
	var tenant := _world.place_block(c2, Vector3i(0, 1, 1), _a("brick_1x1"), 0)
	_ok("a part sits in the masked part's notch", m >= 0 and tenant >= 0)
	_ok("removing the masked part succeeds", _world.remove_block(c2, m))
	_ok("the tenant is untouched", _world.block_at(c2, Vector3i(0, 1, 1)) == tenant)


func _check_round_trip_is_identical() -> void:
	print("\nplace -> remove -> re-place is a no-op")

	# Build a small wall twice. The second one detours through a removal.
	var clean := _chunk()
	var edited := _chunk()
	for x in 4:
		_world.place_block(clean, Vector3i(x * 2, 0, 0), _a("brick_1x2_z"), 4)
		_world.place_block(edited, Vector3i(x * 2, 0, 0), _a("brick_1x2_z"), 4)

	var doomed := _world.place_block(edited, Vector3i(0, 3, 0), _a("brick_2x4_x"), 7)
	_ok("placed the block that will be undone", doomed >= 0)
	_ok("undone", _world.remove_block(edited, doomed))

	_ok("same alive count",
			_world.get_alive_block_count(clean) == _world.get_alive_block_count(edited),
			"%d vs %d" % [_world.get_alive_block_count(clean),
					_world.get_alive_block_count(edited)])

	var a := _world.build_chunk_mesh(clean)
	var b := _world.build_chunk_mesh(edited)
	var sa: Dictionary = _world.get_mesh_stats(clean)
	var sb: Dictionary = _world.get_mesh_stats(edited)
	_ok("same vertex count", sa.vertices == sb.vertices, "%d vs %d" % [sa.vertices, sb.vertices])
	_ok("same faces emitted", sa.faces_emitted == sb.faces_emitted,
			"%d vs %d" % [sa.faces_emitted, sb.faces_emitted])
	_ok("the meshes are byte-identical",
			a.size() > 0 and b.size() > 0 and a[Mesh.ARRAY_VERTEX] == b[Mesh.ARRAY_VERTEX])
	_ok("and so are the colours", a[Mesh.ARRAY_COLOR] == b[Mesh.ARRAY_COLOR])


func _check_remove_is_not_damage() -> void:
	print("\nan edit is not damage")
	var c := _chunk()
	var keep := _world.place_block(c, Vector3i(0, 0, 0), _a("brick_2x2"), 0)
	var gone := _world.place_block(c, Vector3i(4, 0, 0), _a("brick_2x2"), 0)
	_world.remove_block(c, gone)
	_ok("a removed block is NOT in the damage record",
			not _world.get_dead_blocks(c).has(gone),
			"%s" % [_world.get_dead_blocks(c)])

	_world.kill_block(c, Vector3i(0, 0, 0))
	_ok("a killed one IS", _world.get_dead_blocks(c).has(keep))


func _check_kill_still_holds_its_cells() -> void:
	print("\nkill still claims its cells (limitation 22, deliberate)")
	var c := _chunk()
	var id := _world.place_block(c, Vector3i(0, 0, 0), _a("brick_2x2"), 0)
	_world.kill_block(c, Vector3i(0, 0, 0))
	_ok("the block is dead", _world.get_dead_blocks(c).has(id))
	_ok("but it still owns its cells", _world.block_at(c, Vector3i(0, 0, 0)) == id)
	_ok("so nothing can be rebuilt into the crater",
			_world.place_block(c, Vector3i(0, 0, 0), _a("brick_2x2"), 0) < 0)
	_ok("and can_place agrees", not _world.can_place(c, Vector3i(0, 0, 0), _a("brick_2x2")))


func _check_can_place() -> void:
	print("\ncan_place")
	var c := _chunk(Vector3i(8, 8, 8))
	_ok("empty space is free", _world.can_place(c, Vector3i(0, 0, 0), _a("brick_2x4_x")))
	var id := _world.place_block(c, Vector3i(0, 0, 0), _a("brick_2x4_x"), 0)
	_ok("occupied space is not", not _world.can_place(c, Vector3i(0, 0, 0), _a("brick_2x4_x")))
	_ok("overlapping by one cell is not",
			not _world.can_place(c, Vector3i(3, 0, 0), _a("brick_2x4_x")))
	_ok("clear of it is", _world.can_place(c, Vector3i(4, 0, 0), _a("brick_2x4_x")))
	_ok("out of bounds is not", not _world.can_place(c, Vector3i(7, 0, 0), _a("brick_2x4_x")))
	_ok("below the floor is not", not _world.can_place(c, Vector3i(0, -1, 0), _a("brick_2x4_x")))
	_ok("a bad archetype is not", not _world.can_place(c, Vector3i(4, 4, 4), 9999))

	# It must not have written anything while answering.
	_ok("asking changed nothing", _world.get_block_count(c) == 1 and id == 0)


func _check_would_connect() -> void:
	print("\nwould_connect")
	var c := _chunk(Vector3i(16, 16, 16))
	var floor_id := _world.place_block(c, Vector3i(0, 0, 0), _a("plate_4x4"), 2)
	_ok("floor placed", floor_id >= 0)

	_ok("a brick on the plate connects",
			_world.would_connect(c, Vector3i(0, 1, 0), _a("brick_2x2")) > 0)
	_ok("a brick in mid-air connects to nothing",
			_world.would_connect(c, Vector3i(8, 8, 8), _a("brick_2x2")) == 0)
	_ok("a brick that does not fit is -1",
			_world.would_connect(c, Vector3i(0, 0, 0), _a("brick_2x2")) == -1)

	# Joint count is contact area, which is what the stress solve charges for.
	var one := _world.would_connect(c, Vector3i(0, 1, 0), _a("brick_1x1"))
	var four := _world.would_connect(c, Vector3i(0, 1, 0), _a("brick_2x2"))
	_ok("a 1x1 makes one joint", one == 1, "%d" % one)
	_ok("a 2x2 makes four", four == 4, "%d" % four)
	_ok("and four is four times one", four == one * 4)

	# It counts DOWNWARD and UPWARD joints alike, so slotting a part under
	# something already standing reads as connected.
	var c2 := _chunk(Vector3i(16, 16, 16))
	_world.place_block(c2, Vector3i(0, 1, 0), _a("brick_2x2"), 0)
	_ok("a plate slid in underneath connects upward",
			_world.would_connect(c2, Vector3i(0, 0, 0), _a("plate_2x2")) == 4,
			"%d" % _world.would_connect(c2, Vector3i(0, 0, 0), _a("plate_2x2")))

	# A tile has no studs, so nothing clips on top of one -- would_connect has
	# to see that, or build mode would promise a joint the solver will not make.
	var c3 := _chunk(Vector3i(16, 16, 16))
	_world.place_block(c3, Vector3i(0, 0, 0), _a("tile_2x2"), 0)
	_ok("a brick on a tile reports NO connection",
			_world.would_connect(c3, Vector3i(0, 1, 0), _a("brick_2x2")) == 0,
			"%d" % _world.would_connect(c3, Vector3i(0, 1, 0), _a("brick_2x2")))
	var c4 := _chunk(Vector3i(16, 16, 16))
	_world.place_block(c4, Vector3i(0, 0, 0), _a("brick_2x2"), 0)
	_ok("a tile laid on a brick connects",
			_world.would_connect(c4, Vector3i(0, 3, 0), _a("tile_2x2")) == 4,
			"%d" % _world.would_connect(c4, Vector3i(0, 3, 0), _a("tile_2x2")))


func _check_tint_states() -> void:
	print("\nthe ghost's three states")
	var c := _chunk(Vector3i(16, 16, 16))
	_world.place_block(c, Vector3i(0, 0, 0), _a("plate_4x4"), 2)

	# Exactly one of the three, every time, for every part in the palette.
	var red := 0
	var amber := 0
	var cyan := 0
	for part in BrickPalette.parts():
		var name: String = BrickPalette.variants_of(part)[0]
		var arch: int = _palette[name]
		red += 1 if _world.would_connect(c, Vector3i(0, 0, 0), arch) == -1 else 0
		amber += 1 if _world.would_connect(c, Vector3i(8, 8, 8), arch) == 0 else 0
		var on_top := _world.would_connect(c, Vector3i(0, 1, 0), arch)
		cyan += 1 if on_top > 0 else 0

	var n := BrickPalette.parts().size()
	_ok("every part reads RED inside the plate", red == n, "%d of %d" % [red, n])
	_ok("every part reads AMBER in mid-air", amber == n, "%d of %d" % [amber, n])
	_ok("every part reads CYAN resting on the plate", cyan == n, "%d of %d" % [cyan, n])

	# And the states are exclusive: a fit is never -1, a -1 is never a fit.
	for part in BrickPalette.parts():
		var arch: int = _palette[BrickPalette.variants_of(part)[0]]
		var fits: bool = _world.can_place(c, Vector3i(0, 1, 0), arch)
		var joints: int = _world.would_connect(c, Vector3i(0, 1, 0), arch)
		_ok("%s: can_place and would_connect agree" % part, fits == (joints >= 0))
