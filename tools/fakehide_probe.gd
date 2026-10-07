extends SceneTree

## The furniture drawn behind a building's windows (the fake rung) and in its
## drawn rooms goes with a section that falls off, the tick it falls -- not
## once every room of the building has been worked out again, which on the big
## city's towers was up to 18 ticks of furniture hanging in the air where the
## section had been.
##
## Not headless: the fake is not drawn without a renderer.
##
##     godot --path . --resolution 960x540 --script res://tools/fakehide_probe.gd

var city: Node3D
var _pass := 0
var _fail := 0


func _initialize() -> void:
	_run.call_deferred()


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	print("fakehide probe")
	city = load("res://scenes/big_city.tscn").instantiate()
	# The fake and drawn rungs are what this probe is about; storey groups are
	# the default now, and what they do when a section leaves is `-- --groups`
	# ("none is left drawn over a floor that has gone"). Goes with the rungs.
	city.group_interiors = false
	root.add_child(city)
	await _ticks(30)
	var used := []
	for round_i in 3:
		var id := -1
		for b in city.registry.buildings:
			if b.is_build() or b.toppled or b.is_damaged() or used.has(b.id):
				continue
			if int(b.recipe.courses) / TowerRecipe.COURSES_PER_FLOOR >= 6:
				id = b.id
				break
		used.append(id)
		var b = city.registry.get_building(id)
		var box: AABB = CityPlacer.box_of(b)
		var c := box.get_center()
		# Near enough for drawn rooms, then for the fake only.
		var dist: float = [30.0, 45.0, 60.0][round_i]
		city.camera.global_position = Vector3(c.x - dist, box.position.y + 6.0, c.z - dist * 0.3)
		city.camera.look_at(c)
		await _ticks(30 * 8)
		var cut_world := box.position.y + (1 + 1 * (TowerRecipe.COURSES_PER_FLOOR * 3 + 1)) * BrickPalette.PLATE_M + 1.2
		var cut_local: float = cut_world - b.xform.origin.y
		var before := _shown(city._fake_furniture.get(id), cut_local)
		var alive0: int = city.world.get_alive_block_count(b.chunk)
		var x := box.position.x + 0.6
		while x < box.end.x:
			var z := box.position.z + 0.6
			while z < box.end.z:
				city._blast(Vector3(x, cut_world, z), 1.3)
				z += 2.0
			x += 2.0
		var late := 0
		var worst := 0
		for t in 30 * 4:
			await physics_frame
			if b.toppled or not b.is_materialised():
				break
			# Most of it gone: what is above the cut is in the air.
			if city.world.get_alive_block_count(b.chunk) * 3 < alive0:
				var shown := _shown(city._fake_furniture.get(id), cut_local) \
						+ _shown(city._drawn_furniture.get(id), cut_local)
				if shown > 0:
					late += 1
					worst = maxi(worst, shown)
		_ok("building %d at %.0f m: of %d item(s) through its windows, none left in the air" % [
				id, dist, before], before > 0 and late == 0,
				"%d tick(s), up to %d item(s)" % [late, worst])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Items of a furniture MultiMesh shown above `cut_local`.
func _shown(node, cut_local: float) -> int:
	if node == null or not is_instance_valid(node) or not node.is_visible_in_tree():
		return 0
	var mm: MultiMesh = node.multimesh
	if mm == null:
		return 0
	var n := 0
	for i in mm.instance_count:
		var t := mm.get_instance_transform(i)
		if t.basis.get_scale().length() > 0.001 and t.origin.y > cut_local + 0.3:
			n += 1
	return n
