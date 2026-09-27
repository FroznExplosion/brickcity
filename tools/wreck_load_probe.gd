extends SceneTree

## Acceptance probe for wreckage weight on buildings (Docs/AI.md 3.10, AIPlan P5).
##
##     godot --headless --path . --script tools/wreck_load_probe.gd
##
## A column carries a 10x10 floor plate; under the plate's edge a single 2x2 brick
## hangs, and from it a 4x4 balcony. Wreckage lying on the balcony pulls on that
## one joint -- tension, which can fail -- and it gives way. Far more wreckage on
## the floor over the column is compression, which cannot, and it holds.
## (Docs/BrickFailure.md: compression never fails; weight hanging from a joint does.)
##
## And the host's loads are commands: a client replaying LOAD, UNLOAD and SOLVE
## ends with the same broken joints and the same loads -- a load one machine has
## and another does not would break the next blast differently (AIPlan R5).

const TENSION := 9.3

var _pass := 0
var _fail := 0


func _init() -> void:
	print("wreck load probe")
	var host := _building()
	var hw: BrickWorld = host.world
	var hc: int = host.chunk
	var auth := WorldAuthority.new()
	var solve := func() -> Dictionary:
		var r: Dictionary = hw.solve_stress(hc)
		if int(r.get("failures", 0)) > 0:
			auth.commit(0, DamageLog.Kind.SOLVE, 0, Vector3.ZERO, 0.0)
		return r

	var r0: Dictionary = solve.call()
	_ok("the structure stands under its own weight", int(r0.failures) == 0,
			"worst ratio %.2f" % float(r0.max_ratio))

	# A piece of wreckage settles on the floor over the column: heavy.
	_load(auth, hw, hc, 8, [host.floor_cell], 500.0)
	var r1: Dictionary = solve.call()
	_ok("a floor over a column holds 500 of wreckage", int(r1.failures) == 0,
			"%d failure(s), load on it %.0f" % [int(r1.failures), hw.get_external_load(hc, host.floor)])

	# Another settles on the balcony: much lighter, but it hangs.
	_load(auth, hw, hc, 7, [host.balcony_cell], 60.0)
	var r2: Dictionary = solve.call()
	_ok("a hanging balcony under 60 of wreckage gives way", int(r2.failures) > 0
			and hw.is_support_broken(hc, host.balcony), "%d failure(s)" % int(r2.failures))
	var groups: Array = hw.find_detached_groups(hc)
	var falls := false
	for g in groups:
		if (g as PackedInt32Array).has(host.balcony):
			falls = true
	_ok("and comes away from the building", falls, "%d detached group(s)" % groups.size())
	_ok("while the floor, still loaded, stands", not hw.is_support_broken(hc, host.floor))

	# The heavy piece moves off: its load goes with it.
	auth.commit_entry(_unload(0, 8))
	hw.clear_load(hc, 8)
	_ok("a piece that moves takes its load with it", hw.get_external_load(hc, host.floor) == 0.0)

	# The client: the same building, fresh, and only the commands.
	var client := _building()
	var cw: BrickWorld = client.world
	var cc: int = client.chunk
	var rep := StructureReplayer.new(cw, func(id: int, frame: int) -> int:
		return cc if id == 0 and frame == 0 else -1)
	rep.apply_all(DamageLog.from_data(bytes_to_var(var_to_bytes(auth.commands.to_data()))).entries)
	var kinds := {}
	for e in auth.commands.entries:
		var k: String = DamageLog.Kind.keys()[e.kind]
		kinds[k] = int(kinds.get(k, 0)) + 1
	_ok("the client applied every command", rep.missed == 0 and rep.applied == auth.commands.size(),
			"%s" % [kinds])
	var same_broken := true
	for i in hw.get_block_count(hc):
		if hw.is_support_broken(hc, i) != cw.is_support_broken(cc, i):
			same_broken = false
	_ok("and has the same joints broken", same_broken)
	_ok("and the same loads", cw.get_external_load(cc, client.balcony) == hw.get_external_load(hc, host.balcony)
			and cw.get_external_load(cc, client.floor) == 0.0
			and cw.get_load_owners(cc) == hw.get_load_owners(hc),
			"%s" % [cw.get_load_owners(cc)])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _building() -> Dictionary:
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(12, 24, 12))
	w.set_tension_per_stud(c, TENSION)
	for k in 6:
		w.place_block(c, Vector3i(4, k * 3, 4), pal["brick_2x2"], 3)
	var floor := w.place_block(c, Vector3i(0, 18, 0), pal["plate_10x10"], 2)
	w.place_block(c, Vector3i(6, 15, 0), pal["brick_2x2"], 5)
	var balcony := w.place_block(c, Vector3i(6, 14, 0), pal["plate_4x4"], 6)
	return {"world": w, "chunk": c, "floor": floor, "balcony": balcony,
			"floor_cell": Vector3i(0, 18, 0), "balcony_cell": Vector3i(8, 14, 2)}


## Rest `mass_each` on the blocks at `cells`, as the host does: commit, apply.
func _load(auth: WorldAuthority, w: BrickWorld, chunk: int, owner: int, cells: Array,
		mass_each: float) -> void:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.LOAD
	e.target = 0
	e.owner = owner
	e.radius = mass_each
	for c in cells:
		e.points.append(Vector3(c))
	DamageLog.apply_entry(w, chunk, e)
	auth.commit_entry(e)


func _unload(target: int, owner: int) -> DamageLog.Entry:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.UNLOAD
	e.target = target
	e.owner = owner
	return e
