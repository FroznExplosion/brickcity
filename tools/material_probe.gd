extends SceneTree

## What materials do beyond their look: how hard they are to break, what they
## sound like and what a hit leaves.
##
##     godot --headless --path . --script tools/material_probe.gd

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _mat(name: String) -> int:
	for m in BrickWorld.get_material_count():
		if BrickWorld.get_material_name(m) == name:
			return m
	return -1


func _init() -> void:
	print("material probe")
	_toughness()
	_damage()
	_sounds_and_marks()
	_where()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _toughness() -> void:
	print("\ntoughness")
	var pla := BrickWorld.get_material_toughness(0)
	var metal := BrickWorld.get_material_toughness(_mat("Metal"))
	_ok("PLA is the unit", is_equal_approx(pla, 1.0))
	var strongest := true
	for m in BrickWorld.get_material_count():
		if m != _mat("Metal") and BrickWorld.get_material_toughness(m) >= metal:
			strongest = false
	_ok("metal is the toughest there is", strongest, "metal %.2f" % metal)
	_ok("stone and wood are tougher than PLA", BrickWorld.get_material_toughness(_mat("Stone")) > 1.0
			and BrickWorld.get_material_toughness(_mat("Wood")) > 1.0)


## A 1x1 brick of `material` alone in a chunk, and a blast at its centre or
## at the rim of the blast's reach.
func _hits_to_kill(material: int, at_rim: bool) -> int:
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	var bid := w.place_block(c, Vector3i(3, 3, 3), pal["brick_1x1"], 0)
	w.set_block_material(c, bid, material)
	var centre := Vector3(3.5 * 0.35, 4.5 * 0.14, 3.5 * 0.35)
	var radius := 0.3
	# At the rim: the blast centred off to the side, the nearest cell just inside.
	var at := centre + Vector3(radius * 0.97, 0, 0) if at_rim else centre
	for n in range(1, 20):
		var killed: PackedInt32Array = w.apply_hit(c, at, radius)
		if killed.has(bid):
			return n
	return -1


func _damage() -> void:
	print("\na blast's damage, by material")
	var pla := _hits_to_kill(0, false)
	var pla_rim := _hits_to_kill(0, true)
	_ok("PLA dies to one hit, centre or rim -- as every block always did",
			pla == 1 and pla_rim == 1, "%d, %d" % [pla, pla_rim])
	var metal := _hits_to_kill(_mat("Metal"), false)
	var metal_rim := _hits_to_kill(_mat("Metal"), true)
	_ok("metal takes two at the centre", metal == 2, "%d" % metal)
	_ok("and four at the rim", metal_rim == 4, "%d" % metal_rim)
	var stone := _hits_to_kill(_mat("Stone"), false)
	_ok("stone is between: two at the centre", stone == 2, "%d" % stone)
	# A surviving block is hurt, not reset.
	var w := BrickWorld.new()
	var pal := BrickPalette.bake(w)
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(8, 8, 8))
	var bid := w.place_block(c, Vector3i(3, 3, 3), pal["brick_1x1"], 0)
	w.set_block_material(c, bid, _mat("Metal"))
	w.apply_hit(c, Vector3(3.5 * 0.35, 4.5 * 0.14, 3.5 * 0.35), 0.3)
	var hp := w.get_block_hp(c, bid)
	_ok("a metal brick that survives is left with less", hp > 0 and hp < 255, "hp %d" % hp)
	# The same hits, replayed, land the same.
	_ok("and the same hits decide the same thing again",
			_hits_to_kill(_mat("Metal"), true) == metal_rim)


func _sounds_and_marks() -> void:
	print("\nsounds and marks, by family")
	var lengths := {}
	for fam in ["plastic", "soft", "wood", "metal", "stone"]:
		var step := BrickMaterials.step_sound(fam)
		var hit := BrickMaterials.hit_sound(fam)
		lengths[fam] = hit.data.size()
		_ok("%s: a step and a hit" % fam, step.data.size() > 0 and hit.data.size() > step.data.size())
		var tex := BrickMaterials.hole_texture(fam)
		_ok("%s: a mark" % fam, tex != null and tex.get_width() == 64)
	_ok("metal rings longest", lengths.metal > lengths.plastic and lengths.metal > lengths.stone)
	_ok("the families are filed: metal, wood, stone, TPU soft, PLA plastic",
			BrickMaterials.family(_mat("Metal")) == "metal" and BrickMaterials.family(_mat("Wood")) == "wood"
			and BrickMaterials.family(_mat("Stone")) == "stone" and BrickMaterials.family(_mat("TPU")) == "soft"
			and BrickMaterials.family(0) == "plastic")
	var plastic := BrickMaterials.hole_texture("plastic").get_image()
	var metal := BrickMaterials.hole_texture("metal").get_image()
	_ok("a plastic hole and a metal dent are different marks",
			plastic.get_pixel(32, 20) != metal.get_pixel(32, 20))


func _where() -> void:
	print("\nwhat is under a point, in a city")
	var w := BrickWorld.new()
	var reg := BuildingRegistry.new(w, TowerRecipe.bake_palette(w))
	var r := BuildRecipe.load_from("res://builds/kiosk.json")   # cedar walls, steel roof
	var id := reg.register_build(r, Transform3D())
	var fx := MaterialFx.new()
	root.add_child(fx)
	fx.setup(w, reg)
	var box := CityPlacer.box_of(reg.get_building(id))
	var roof := Vector3(box.get_center().x, box.end.y - 0.07, box.get_center().z)
	_ok("on its cheap tier, the roof is metal (read from the recipe)",
			fx.material_at(roof) == _mat("Metal"), "%d" % fx.material_at(roof))
	_ok("and a step on it sounds like metal", fx.step_at(roof + Vector3(0, 0.07, 0)) == "metal")
	reg.materialise(id)
	var wall := Vector3(box.position.x + 0.1, 0.8, box.get_center().z)
	_ok("with real bricks, the wall is wood", fx.material_at(wall) == _mat("Wood"),
			"%d" % fx.material_at(wall))
	_ok("nowhere near a building is nothing", fx.material_at(Vector3(500, 1, 500)) == -1)
	_ok("a hit on the wall leaves a mark", fx.impact_at(wall + Vector3(-0.1, 0, 0), Vector3.LEFT)
			and fx._marks.size() == 1)
