extends SceneTree

## The hard cap on moving pieces (IslandManager.MAX_MOVING).
##
##     godot --headless --path . --script tools/cap_probe.gd
##
## With the scene already full of moving pieces, a LANDMARK that comes loose far
## from every player is cut out and dropped instead of becoming a body -- and the
## DETACH says so (DamageLog.FLAG_GONE), so a client that applies it drops the
## same bricks and makes no piece either. Anything near a player still falls,
## and below the cap everything does.

const BUILDING := 7

var _pass := 0
var _fail := 0
var _started := false


func _init() -> void:
	print("the moving cap drops far landmarks, the same on every machine")
	physics_frame.connect(_run)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A tower with a storey taken out from under its top, so what is above is held
## by nothing: one big group, a landmark by any measure.
func _tower(w: BrickWorld, palette: Dictionary) -> int:
	var chunk := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(20, 20, 24))
	TowerRecipe.build(w, chunk, palette, 20, 20, 24)
	var pt := BrickWorld.ticks_per_plate()
	var gone := PackedInt32Array()
	for id in w.get_block_count(chunk):
		var ticks: Array = w.get_block_ticks(chunk, id)
		if ticks.is_empty():
			continue
		@warning_ignore("integer_division")
		var plate: int = (ticks[0] as Vector3i).y / pt
		if plate >= 30 and plate < 33:
			gone.push_back(id)
	w.kill_blocks(chunk, gone)
	return chunk


func _manager(w: BrickWorld, entries: Array, near: bool) -> IslandManager:
	var islands := IslandManager.new()
	root.add_child(islands)
	islands.setup(w, null, null)
	var seq := [0]
	islands.on_command = func(e: DamageLog.Entry) -> int:
		seq[0] += 1
		e.seq = seq[0]
		entries.append(e)
		return seq[0]
	var at := Vector3(4.0, 4.0, 4.0) if near else Vector3(1000.0, 0.0, 1000.0)
	islands.interest = func() -> PackedVector3Array: return PackedVector3Array([at])
	return islands


func _run() -> void:
	if _started:
		return
	_started = true

	# --- over the cap, far from everybody: dropped, and the client agrees ---
	var hw := BrickWorld.new()
	var hp := TowerRecipe.bake_palette(hw)
	var hc := _tower(hw, hp)
	var entries: Array = []
	var islands := _manager(hw, entries, false)
	islands._moving_now = IslandManager.MAX_MOVING
	var groups: Array = hw.find_detached_groups(hc)
	_ok("the tower has something to shed", not groups.is_empty())
	var group: PackedInt32Array = groups[0]
	_ok("and it is a landmark", islands.group_is_landmark(hc, group), "%d blocks" % group.size())
	var before := hw.get_alive_block_count(hc)
	var pid := islands.record_detach(BUILDING, null, hc, group)
	var piece := islands.spawn(hc, group, Vector3.ZERO, Vector3.ZERO, pid, BUILDING)
	_ok("over the cap and far from everybody, it never becomes a body", piece == null)
	_ok("the bricks have left the building all the same",
			hw.get_alive_block_count(hc) == before - group.size(),
			"%d -> %d" % [before, hw.get_alive_block_count(hc)])
	var e: DamageLog.Entry = entries.back() if not entries.is_empty() else null
	_ok("and the DETACH says it is gone", e != null and e.kind == DamageLog.Kind.DETACH
			and bool(e.flags & DamageLog.FLAG_GONE))
	_ok("counted as dropped over the cap", int(islands.spawn_census.capped[0]) == 1)

	# The client: the same tower, the same damage, then the host's DETACH.
	var cw := BrickWorld.new()
	var cp := TowerRecipe.bake_palette(cw)
	var cc := _tower(cw, cp)
	var rep := StructureReplayer.new(cw, func(id: int, frame: int) -> int:
		return cc if id == BUILDING and frame == 0 else -1)
	_ok("the client applies it", e != null and rep.apply(e))
	_ok("and has no piece from it either", rep.pieces.is_empty())
	_ok("and the same bricks standing as the host",
			cw.get_alive_block_count(cc) == hw.get_alive_block_count(hc),
			"%d vs %d" % [cw.get_alive_block_count(cc), hw.get_alive_block_count(hc)])

	# --- the same, with somebody near: it falls ---
	var nw := BrickWorld.new()
	var nc := _tower(nw, TowerRecipe.bake_palette(nw))
	var near_entries: Array = []
	var near := _manager(nw, near_entries, true)
	near._moving_now = IslandManager.MAX_MOVING
	var ng: PackedInt32Array = nw.find_detached_groups(nc)[0]
	var npid := near.record_detach(BUILDING, null, nc, ng)
	_ok("with somebody near, it falls however many are moving",
			near.spawn(nc, ng, Vector3.ZERO, Vector3.ZERO, npid, BUILDING) != null)
	_ok("and the DETACH does not say gone", not near_entries.is_empty()
			and not bool((near_entries.back() as DamageLog.Entry).flags & DamageLog.FLAG_GONE))

	# --- under the cap, far away: it falls ---
	var uw := BrickWorld.new()
	var uc := _tower(uw, TowerRecipe.bake_palette(uw))
	var under := _manager(uw, [], false)
	under._moving_now = IslandManager.MAX_MOVING - 1
	var ug: PackedInt32Array = uw.find_detached_groups(uc)[0]
	var upid := under.record_detach(BUILDING, null, uc, ug)
	var body := under.spawn(uc, ug, Vector3.ZERO, Vector3.ZERO, upid, BUILDING)
	_ok("under the cap it falls, far or not", body != null)
	_ok("and, being far, it falls merged", body != null and body.merged,
			"%d blocks" % ug.size())

	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
