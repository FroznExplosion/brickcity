extends SceneTree

## Acceptance probe for weight on bricks (Docs/AI.md 3.10, A16; AIPlan P7).
##
##     godot --headless --path . --script tools/pawn_weight_probe.gd
##
## A floor plate on a column, and a balcony hanging under its edge from one 2x2
## brick, with wreckage already resting on it -- hanging by a thread. Two people:
##
##   on the floor over the column   its way down is all compression: headroom
##                                  INF, no command, nothing breaks
##   on the balcony                 finite headroom, less than a person: a LOAD,
##                                  a solve, the balcony lets go and the person
##                                  falls with it; on the ground, an UNLOAD
##
## Every command goes in a log; a client building the same structure and applying
## the log has the same joints broken. Headroom itself is checked against the
## solve: a load one unit under it holds, one unit over it breaks.

const Arena := preload("res://tools/ai_arena.gd")
const TENSION := 9.3
## How much room the balcony is left with by the wreckage on it.
const THREAD := 0.5
const LIMIT := 30 * 6

var _pass := 0
var _fail := 0
var a: Arena
var log := DamageLog.new()
var tracker: WeightTracker
var chunk := -1
var parts := {}
var on_floor: Pawn
var on_balcony: Pawn
var _tick := 0
var _log := {}


func _init() -> void:
	print("pawn weight probe")
	_headroom_is_the_solve()
	a = Arena.new(self, 4)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## The structure, in `w`: {chunk, floor, hanger, balcony}.
static func build(w: BrickWorld, pal: Dictionary) -> Dictionary:
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(14, 24, 12))
	w.set_tension_per_stud(c, TENSION)
	for k in 6:
		w.place_block(c, Vector3i(4, k * 3, 4), pal["brick_2x2"], 3)
	var floor := w.place_block(c, Vector3i(0, 18, 0), pal["plate_10x10"], 2)
	# Under the floor's edge, and out past it: a person stands on the part in
	# the open.
	var hanger := w.place_block(c, Vector3i(8, 15, 4), pal["brick_2x2"], 5)
	var balcony := w.place_block(c, Vector3i(8, 14, 3), pal["plate_4x4"], 6)
	w.set_chunk_anchored(c, true)
	return {"chunk": c, "floor": floor, "hanger": hanger, "balcony": balcony}


## Headroom is what the solve says, not a guess: in a fresh copy, a load one unit
## under the balcony's headroom breaks nothing, and one unit over it does.
func _headroom_is_the_solve() -> void:
	var results := []
	for extra in [-1.0, 1.0]:
		var w := BrickWorld.new()
		var pal := TowerRecipe.bake_palette(w)
		var p := build(w, pal)
		w.solve_stress(p.chunk)
		var h := w.get_headroom(p.chunk, p.balcony)
		w.set_load(p.chunk, 7, PackedInt32Array([p.balcony]), h + extra)
		var r: Dictionary = w.solve_stress(p.chunk)
		results.append([h, int(r.failures)])
	var fw := BrickWorld.new()
	var fp := build(fw, TowerRecipe.bake_palette(fw))
	fw.solve_stress(fp.chunk)
	var floor_h := fw.get_headroom(fp.chunk, fp.floor)
	_ok("headroom is the solve's: one unit under it holds, one over it breaks; a floor on a column has no limit",
			results[0][1] == 0 and results[1][1] > 0 and is_inf(floor_h) and float(results[0][0]) > 0.0,
			"balcony headroom %.2f; failures %d / %d; floor %s" % [float(results[0][0]),
			results[0][1], results[1][1], floor_h])


func _build() -> void:
	parts = build(a.w, a.palette)
	chunk = parts.chunk
	var body := StaticBody3D.new()
	body.collision_layer = Layers.STRUCTURE
	var built: Dictionary = a.w.add_chunk_shapes(body.get_rid(), chunk, Vector3.ZERO, false)
	body.transform = a.w.get_chunk_transform(chunk)
	root.add_child(body)
	a.chunks.append(chunk)
	a._shapes[chunk] = [body.get_rid(), built.map]
	a.w.solve_stress(chunk)
	a.s.ai_world.sync()
	# Wreckage on the balcony, leaving it THREAD of room: a LOAD, as the host
	# commits one when a piece settles there.
	var h := a.w.get_headroom(chunk, parts.balcony)
	_load(chunk, 900, Vector3i(10, 14, 5), h - THREAD)
	_solve(chunk)
	_log["room"] = a.w.get_headroom(chunk, parts.balcony)
	tracker = WeightTracker.new(a.s.ai_world, a.w)
	tracker.on_load = func(c: int, owner: int, cell: Vector3i, mass: float) -> void:
		_load(c, owner, cell, mass)
	tracker.on_unload = func(c: int, owner: int) -> void:
		var e := DamageLog.Entry.new()
		e.kind = DamageLog.Kind.UNLOAD
		e.target = c
		e.owner = owner
		DamageLog.apply_entry(a.w, c, e)
		log.add(e)
	tracker.on_solve = _solve
	var S := Arena.STUD
	var P := Arena.PLATE
	on_floor = Pawn.spawn(root, Vector3(2.5 * S, 19 * P + 0.02, 2.5 * S), 0, true, 100.0)
	on_balcony = Pawn.spawn(root, Vector3(11.0 * S, 15 * P + 0.02, 5.0 * S), 0, true, 100.0)
	for p in [on_floor, on_balcony]:
		Soldier._greybox(p, 0)
		p.set_meta(&"owner", tracker.add(p.body, p.feet, WeightTracker.PERSON))


func _load(c: int, owner: int, cell: Vector3i, mass: float) -> void:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.LOAD
	e.target = c
	e.owner = owner
	e.radius = mass
	e.points.append(Vector3(cell))
	DamageLog.apply_entry(a.w, c, e)
	log.add(e)


## The host's solve: a SOLVE command, and whatever it cut loose leaves (here it
## simply stops colliding; in the city it becomes a piece).
func _solve(c: int) -> void:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.SOLVE
	e.target = c
	DamageLog.apply_entry(a.w, c, e)
	log.add(e)
	for g in a.w.find_detached_groups(c):
		a._disable(c, g)
		_log["detached"] = int(_log.get("detached", 0)) + (g as PackedInt32Array).size()
	a.s.ai_world.sync()


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
		return
	a.s.ai_world.sync()
	tracker.tick(a.s.now())
	if _tick >= LIMIT:
		_finish()


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var fo := tracker.bearer(int(on_floor.get_meta(&"owner")))
	var ba_broken := a.w.is_support_broken(chunk, parts.balcony) or a.w.is_support_broken(chunk, parts.hanger)
	_ok("wreckage leaves the balcony hanging by a thread", float(_log.get("room", -1.0)) > 0.0
			and float(_log.room) < WeightTracker.PERSON, "%.2f of room" % float(_log.get("room", -1.0)))
	_ok("a person on the floor over the column: no command, nothing breaks",
			not fo.logged and not a.w.is_support_broken(chunk, parts.floor)
			and on_floor.feet().y > 2.5, "feet at %.2f m" % on_floor.feet().y)
	_ok("a person on the hanging balcony drops it, and falls with it",
			ba_broken and int(_log.get("detached", 0)) >= 2 and on_balcony.feet().y < 0.3,
			"%d block(s) came away; feet at %.2f m" % [int(_log.get("detached", 0)), on_balcony.feet().y])
	_ok("on the ground again, the load comes off", tracker.unloads >= 1,
			"%d load(s), %d unload(s), %d solve(s), %d lookup(s)" % [tracker.loads, tracker.unloads,
			tracker.solves, tracker.lookups])
	# The client.
	var w2 := BrickWorld.new()
	var p2 := build(w2, TowerRecipe.bake_palette(w2))
	w2.solve_stress(p2.chunk)
	for e in log.entries:
		DamageLog.apply_entry(w2, p2.chunk, e)
	var same := 0
	var n := a.w.get_block_count(chunk)
	for b in n:
		if a.w.is_support_broken(chunk, b) == w2.is_support_broken(p2.chunk, b):
			same += 1
	var kinds := {}
	for e in log.entries:
		kinds[DamageLog.Kind.keys()[e.kind]] = int(kinds.get(DamageLog.Kind.keys()[e.kind], 0)) + 1
	_ok("a client applying the log has the same joints broken", same == n,
			"%d of %d blocks agree; log %s" % [same, n, kinds])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
