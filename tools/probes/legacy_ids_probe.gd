extends SceneTree

## A save from before 2026-11-16 still names the right blocks (AreaSnapshot 3,
## BuildingRegistry.legacy_ids). The cornice -- a row of buttresses laid last
## of a tower's own blocks, before its fixtures -- is not laid any more, so a
## fixture's id is less by the cornice's count than an old save says.
##
##     godot --headless --path . --script tools/probes/legacy_ids_probe.gd

const FX := 30
const FZ := 30
const COURSES := 48

var _pass := 0
var _fail := 0


func _init() -> void:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(FX, FZ, COURSES, Transform3D())
	reg.add_fixture(id, "staircase", {
		"steps": StaircaseRecipe.steps_for_courses(COURSES), "colour": 11,
	}, Vector3i(TowerRecipe.stair_line(FX), TowerRecipe.SLAB_PLATES, TowerRecipe.stair_line(FZ)))
	var c := reg.materialise(id)
	var b := reg.get_building(id)
	var first := w.get_block_count(c)
	var last := -1
	for f in b.fixtures:
		for bid in f.blocks:
			first = mini(first, int(bid))
			last = maxi(last, int(bid))
	var cornice := 0
	for x in range(0, FX - 1, 2):
		cornice += 1
	print("[legacy_ids] tower blocks 0..%d, fixtures %d..%d, the cornice was %d" % [first - 1, first, last, cornice])
	_ok(first > 0 and last >= first, "the tower has fixtures after its own blocks")
	# As an old save named them: a wall brick, a cornice buttress, the first
	# and the last stair piece.
	var old := PackedInt32Array([first - 1, first, first + cornice - 1, first + cornice, last + cornice])
	var now := reg.legacy_ids(id, c, old)
	_ok(now == PackedInt32Array([first - 1, first, last]),
			"a wall brick keeps its id, the cornice's are dropped, a stair piece's is less by %d (%s -> %s)" % [
				cornice, old, now])
	_ok(AreaSnapshot.VERSION >= 3, "saves are written at version %d" % AreaSnapshot.VERSION)
	var v2 := var_to_bytes({"version": 2, "commands": [], "pieces": [], "dormant": []})
	var snap := AreaSnapshot.from_bytes(v2)
	_ok(snap != null and snap.version == 2, "a version 2 save still loads, and says it is one")
	print("\n[legacy_ids] %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  ok    " + what)
	else:
		_fail += 1
		print("  FAIL  " + what)
