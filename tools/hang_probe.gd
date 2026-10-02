extends SceneTree

## Does a brick that is still clicked onto the building fall off it?
##
##     godot --headless --path . --script tools/hang_probe.gd
##
## A storey blown out of a tower, the way --jam and --breaklag do it, and the
## building solved until it stops coming apart -- every group that comes loose
## cut out as the city would. Each small group (DEBRIS_MAX_BLOCKS or fewer) is
## asked one question: when it came loose, was any of its bricks still joined
## -- a live stud joint, not cut by a seam -- to a brick that stayed? Such a
## brick is not falling because nothing holds it. It fell because a stress
## solve failed it while load from elsewhere was routed through it, and a
## failed brick is "joined to nothing" (Block::support_broken): the grounding
## walk never enters it again, whatever it is still clicked onto. Reported by
## the user, 2026-10-02: "single bricks just falling off when they should stay
## attached because their top studs are connected to the bricks above them".

const TENSION := 9.3
const FOOT_X := 20
const FOOT_Z := 16
const COURSES := 60
const STUD := 0.35

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	print("hang probe: a brick still clicked on stays on")
	for kind in ["storey", "stubs", "hole", "slot", "shots"]:
		_case(kind, 1)
		_case(kind, 48)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _case(kind: String, rounds: int) -> void:
	var storey := 2
	var w := BrickWorld.new()
	w.set_seed(7)
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(FOOT_X, FOOT_Z, COURSES))
	TowerRecipe.build(w, c, palette, FOOT_X, FOOT_Z, COURSES)
	w.set_tension_per_stud(c, TENSION)
	var plate: float = BrickWorld.get_cell_size().y
	var y: float = (1 + storey * TowerRecipe.STOREY_PLATES + 6) * plate
	var fx := FOOT_X * STUD
	var fz := FOOT_Z * STUD
	match kind:
		"storey":
			var x := 0.0
			while x <= fx + 0.01:
				var z := 0.0
				while z <= fz + 0.01:
					w.apply_hit(c, Vector3(x, y, z), 2.0)
					z += 2.5
				x += 2.5
		"stubs":
			# The storey shot through but not cleared: stubs left holding up
			# everything above, as --breaklag --big leaves them.
			var x := 0.0
			while x <= fx + 0.01:
				var z := 0.0
				while z <= fz + 0.01:
					w.apply_hit(c, Vector3(x, y, z), 1.3)
					z += 2.6
				x += 2.6
		"hole":
			# One rocket in the middle of a wall.
			w.apply_hit(c, Vector3(fx * 0.5, y, 0.2), 1.6)
		"slot":
			# A slot along one wall, a storey up: everything over it hangs.
			var x := 0.6
			while x <= fx - 0.6:
				w.apply_hit(c, Vector3(x, y, 0.2), 1.0)
				x += 0.8
		"shots":
			# A burst of small hits up and down a wall.
			for i in 40:
				w.apply_hit(c, Vector3(0.8 + float(i % 10) * 0.6, y - 0.6 + float(i / 10) * 0.42, 0.2), 0.35)
	var small := 0
	var singles := 0
	var still_joined := 0
	var joined_singles := 0
	var big := 0
	var solves := 0
	var failures := 0
	while solves < 400:
		solves += 1
		var res: Dictionary = w.solve_structure(c, rounds, 0.0)
		failures += int(res.stress.failures)
		var groups: Array = res.groups
		if groups.is_empty() and int(res.stress.failures) == 0:
			break
		if groups.is_empty():
			continue
		var grounded := w.solve_grounded(c)
		for g in groups:
			var ids: PackedInt32Array = g
			if ids.size() > IslandManager.DEBRIS_MAX_BLOCKS:
				big += 1
			else:
				small += 1
				if ids.size() == 1:
					singles += 1
				var inside := {}
				for id in ids:
					inside[id] = true
				var joined := false
				for id in ids:
					for nb in w.get_block_neighbours(c, id):
						if not inside.has(nb) and nb < grounded.size() and grounded[nb] != 0 \
								and not w.is_block_decorative(c, nb) and not w.is_block_decorative(c, id):
							joined = true
							break
					if joined:
						break
				if joined:
					var flags := []
					for id in ids:
						flags.append(w.get_block_joints(c, id))
					print("    still joined: %d brick(s), joint bits %s (1 broken, 2 bottom cut, 4 strained, 8 held)" % [ids.size(), flags])
					still_joined += 1
					if ids.size() == 1:
						joined_singles += 1
		for g in groups:
			var cut: Dictionary = w.split_island(c, g)
			if not cut.is_empty():
				w.release_chunk(int(cut.chunk))
	print("\n%s, %d round(s) a solve: %d solve(s), %d joint failure(s); %d big group(s); %d small, %d of them single bricks" % [
			kind, rounds, solves, failures, big, small, singles])
	_ok("%s, %d round(s): no small group falls while still clicked onto a brick that stays" % [kind, rounds],
			still_joined == 0, "%d of %d small group(s) still joined, %d of them single bricks" % [
				still_joined, small, joined_singles])
