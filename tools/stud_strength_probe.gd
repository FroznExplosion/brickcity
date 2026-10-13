extends "res://tools/collapse_probe.gd"

## How hard a stud holds (BrickStrength; Docs/CollapseNext.md 1.10, item 6):
## one number, in one place, that the buildings have and that can be moved in
## play.
##
##     godot --headless --path . --script tools/stud_strength_probe.gd
##
## What it is FOR is how much comes off a damaged building by itself, so that
## is what is counted: the same wall left hanging over the same slot, solved
## until it is quiet, at the strength of a building the game's size, at the
## game's setting, and at the toy's.

const FOOT_X := 20
const FOOT_Z := 16
const COURSES := 60


func _only(_name: String) -> bool:
	return false


## A tower with its ground storey shot out under two thirds of its width: what
## is above that side hangs off the third still standing. Solved until it is
## quiet with a stud holding `tension`: [bricks that came loose, joints that
## failed in tension].
func _overhang(tension: float) -> Array:
	var w := BrickWorld.new()
	w.set_seed(7)
	var palette := TowerRecipe.bake_palette(w)
	var c := w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(FOOT_X, FOOT_Z, COURSES))
	TowerRecipe.build(w, c, palette, FOOT_X, FOOT_Z, COURSES)
	w.set_tension_per_stud(c, tension)
	var top: float = float(1 + TowerRecipe.STOREY_PLATES) * BrickWorld.get_cell_size().y
	var y := 0.5
	while y < top:
		var x := 0.0
		while x <= FOOT_X * 0.35 * 0.65:
			var z := 0.0
			while z <= FOOT_Z * 0.35 + 0.01:
				w.apply_hit(c, Vector3(x, y, z), 1.2)
				z += 1.2
			x += 1.2
		y += 1.2
	var loose := 0
	var fails := 0
	for round_i in 400:
		var res: Dictionary = w.solve_structure(c, 8, 0.0)
		fails += int(res.stress.failures)
		var groups: Array = res.groups
		if groups.is_empty() and int(res.stress.failures) == 0:
			break
		for g in groups:
			loose += (g as PackedInt32Array).size()
			var cut: Dictionary = w.split_island(c, g)
			if not cut.is_empty():
				w.release_chunk(int(cut.chunk))
	return [loose, fails]


func _run() -> void:
	print("stud strength probe: how hard a stud holds")
	_ok("the game's stud is the scaled one, times the setting",
			is_equal_approx(BrickStrength.tension(), BrickStrength.SCALED * BrickStrength.times)
			and is_equal_approx(BrickStrength.times, BrickStrength.DEFAULT_TIMES),
			"%.1f = %.1f x %.1f" % [BrickStrength.tension(), BrickStrength.SCALED, BrickStrength.times])
	_ok("and the toy's is forty-four of the scaled",
			absf(BrickStrength.TOY / BrickStrength.SCALED - 43.75) < 0.2,
			"%.1f" % (BrickStrength.TOY / BrickStrength.SCALED))

	# What the number is for: joints asked to hold something up.
	var scaled := _overhang(BrickStrength.SCALED)
	var game := _overhang(BrickStrength.tension())
	var toy := _overhang(BrickStrength.TOY)
	print("  --   a tower hanging over two thirds of its ground storey: %d joint(s) fail and %d brick(s) come loose at 1x; %d and %d at %.0fx; %d and %d at the toy's" % [
			scaled[1], scaled[0], game[1], game[0], BrickStrength.times, toy[1], toy[0]])
	_ok("at the strength of a building the game's size, joints holding the overhang up give way",
			int(scaled[1]) > 0, "%d joint(s), %d brick(s) loose" % [scaled[1], scaled[0]])
	_ok("at the game's setting they hold, and less comes loose",
			int(game[1]) == 0 and int(game[0]) < int(scaled[0]),
			"%d joint(s); %d loose against %d" % [game[1], game[0], scaled[0]])
	_ok("and at the toy's", int(toy[1]) == 0 and int(toy[0]) <= int(game[0]),
			"%d joint(s), %d loose" % [toy[1], toy[0]])

	# The city's buildings have it, and take a new one while they stand.
	city = load("res://scenes/city.tscn").instantiate()
	root.add_child(city)
	await _ticks(30)
	var id := _tower(4)
	var chunk: int = city._promote(id)
	await _ticks(10)
	_ok("a building made bricks has the game's stud",
			is_equal_approx(city.world.get_tension_per_stud(chunk), BrickStrength.tension()),
			"%.1f" % city.world.get_tension_per_stud(chunk))
	var was := BrickStrength.times
	BrickStrength.times = 1.0
	await _ticks(3)
	_ok("moved in play, a building that is bricks takes the new strength",
			is_equal_approx(city.world.get_tension_per_stud(chunk), BrickStrength.SCALED),
			"%.1f" % city.world.get_tension_per_stud(chunk))
	# Whatever a stud holds, a storey is crushed at the same load: the check
	# is handed the crush limit over how many times stronger the studs are.
	var b = city.registry.get_building(id)
	var weak: Dictionary = city.world.gravity_check(chunk,
			city.CRUSH_PER_STUD * BrickStrength.SCALED / city.world.get_tension_per_stud(chunk))
	BrickStrength.times = 8.0
	await _ticks(3)
	var strong: Dictionary = city.world.gravity_check(chunk,
			city.CRUSH_PER_STUD * BrickStrength.SCALED / city.world.get_tension_per_stud(chunk))
	_ok("an undamaged tower is as far from crushing a storey at 1x as at 8x",
			b != null and str(weak.kind) == "crush" and str(strong.kind) == "crush"
			and absf(float(weak.ratio) - float(strong.ratio)) < 0.001,
			"%s %.3f at 1x, %s %.3f at 8x" % [weak.kind, float(weak.ratio), strong.kind, float(strong.ratio)])
	BrickStrength.times = was
	await _ticks(3)
	_ok("and put back, it is the game's again",
			is_equal_approx(city.world.get_tension_per_stud(chunk), BrickStrength.tension()))
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
