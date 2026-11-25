extends SceneTree
## MineBuildings without a world (Docs/TerrainBuildings.md): a tower's bricks
## read back with glass and furniture, a workshop build's, the town plan from
## a seed, the registry's save round trip, the plastic-bricks item family.
## Headless: --headless --path . --script res://tools/probes/mine_buildings_probe.gd

var fails := 0


func check(ok: bool, what: String) -> void:
	print("[mine-buildings-probe] %s  %s" % ["ok  " if ok else "FAIL", what])
	fails += 0 if ok else 1


func _init() -> void:
	var glass := MineBuildings.glass_material()
	# terrain.gdshader's TERRAIN_GLASS.
	check(glass == 39, "glass is material %d (the shader's 39)" % glass)
	var p := {"x": 20, "z": 20, "courses": 2 * TowerRecipe.COURSES_PER_FLOOR, "rooms": true,
			"windows": true, "stairs": true}
	var plain := MineBuildings.tower_cells(p.merged({"furnish": false}))
	var full := MineBuildings.tower_cells(p)
	var g := 0
	for c: Array in full:
		if int(c[2]) == glass:
			g += 1
	check(g > 0, "a tower's windows are glass bricks (%d of %d)" % [g, full.size()])
	check(full.size() > plain.size(), "its rooms furnished: %d bricks, %d without" % [full.size(), plain.size()])
	var cot := MineBuildings.recipe_cells(BuildRecipe.load_from(BuildRecipe.shipped("cottage")))
	check(cot.size() > 20, "the cottage build read back (%d bricks)" % cot.size())
	var t1 := JSON.stringify(MineBuildings.town_at(1234, Vector2i(2, 3)))
	var t2 := JSON.stringify(MineBuildings.town_at(1234, Vector2i(2, 3)))
	var towns := 0
	var floors_ok := true
	for z in 10:
		for x in 10:
			var t := MineBuildings.town_at(1234, Vector2i(x, z))
			if t.is_empty():
				continue
			towns += 1
			for pl: Array in t.plots:
				var f: int = int(pl[1].courses) / TowerRecipe.COURSES_PER_FLOOR
				floors_ok = floors_ok and f >= 2 and f <= 10
	check(t1 == t2, "a town is the same from the same seed")
	check(towns > 10 and towns < 80 and floors_ok, "%d towns in 100 regions, 2..10 floors" % towns)
	MineBuildings.registry = [{"lo": Vector3i(1, 2, 3), "hi": Vector3i(4, 5, 6), "base": 2,
			"weight": {Vector2i(1, 3): 7}, "bricks": [[Vector3i(1, 2, 3), Vector3i(2, 4, 3), 70]], "fallen": false}]
	var saved: Variant = JSON.parse_string(JSON.stringify(MineBuildings.to_save()))
	MineBuildings.from_save(saved)
	var b: Dictionary = MineBuildings.registry[0]
	check(b.hi == Vector3i(4, 5, 6) and int(b.weight[Vector2i(1, 3)]) == 7 and int(b.bricks[0][2]) == 70,
			"the registry saves and loads")
	MineBuildings.registry.clear()
	var m := MineBuildings.BUILDING_MATERIAL_BASE + 5
	check(ItemCatalog.block_item(m) == &"plastic_bricks", "a building brick's item: %s" % ItemCatalog.block_item(m))
	check(ItemCatalog.block_item(glass) == &"glass", "glass's item: %s" % ItemCatalog.block_item(glass))
	print("[mine-buildings-probe] %s" % ["PASS" if fails == 0 else "%d FAILED" % fails])
	quit(1 if fails > 0 else 0)
