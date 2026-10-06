extends SceneTree

## Fire, brick by brick (Docs/Disasters.md 29), on a bare BrickWorld.
##
##     godot --headless --path . --script res://tools/brick_fire_probe.gd
##
## A tree lit at the foot of its trunk: the fire climbs the trunk, the canopy
## catches and burns out fast while the wooden trunk is still burning, and the
## canopy burns from the outside in -- a leaf brick buried in others catches
## only after one that touches air (nothing in the fire knows what a canopy is;
## it is the touches-air rule). A strip of leaves lit in the middle under a
## wind burns further downwind than up. And by material: leaves and plastic
## burn away, wood burns longest, metal and stone never burn but char.

var _passed := 0
var _failed := 0
var _w: BrickWorld
var _pal: Dictionary
const DT := 0.25
const TICK := 0.07   ## metres a tick (BrickWorld.ticks_per_stud: a 0.35 m stud is 5)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_w = BrickWorld.new()
	_pal = TowerRecipe.bake_palette(_w)
	print("brick fire probe")
	_tree()
	_wind()
	_materials()
	if not "--no-city" in OS.get_cmdline_user_args():
		await _city()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, ("  " + detail) if detail != "" else ""])


func _centre(chunk: int, id: int) -> Vector3:
	var t: Array = _w.get_block_ticks(chunk, id)
	var at: Vector3i = t[0]
	var size: Vector3i = t[1]
	return _w.get_chunk_transform(chunk) * ((Vector3(at) + Vector3(size) * 0.5) * TICK)


## Does the block touch air (no living block in a cell next to one of its own)?
func _exposed(chunk: int, id: int) -> bool:
	var t: Array = _w.get_block_ticks(chunk, id)
	var t_s := BrickWorld.ticks_per_stud()
	var t_p := BrickWorld.ticks_per_plate()
	var at: Vector3i = t[0]
	var size: Vector3i = t[1]
	@warning_ignore("integer_division")
	var lo := Vector3i(at.x / t_s, at.y / t_p, at.z / t_s) + _w.get_chunk_origin(chunk)
	@warning_ignore("integer_division")
	var n := Vector3i(size.x / t_s, size.y / t_p, size.z / t_s)
	for x in n.x:
		for y in n.y:
			for z in n.z:
				var c := lo + Vector3i(x, y, z)
				if _w.block_at(chunk, c) != id:
					continue
				for d in [Vector3i.UP, Vector3i.DOWN, Vector3i.LEFT, Vector3i.RIGHT,
						Vector3i.FORWARD, Vector3i.BACK]:
					var nb := _w.block_at(chunk, c + d)
					if nb != id and (nb < 0 or not _w.is_solid(chunk, c + d)):
						return true
	return false


## Step the chunk until nothing is hot or `limit` seconds, noting when each
## block caught and when it went. Returns {caught: id -> s, gone: id -> s, t}.
func _burn(chunk: int, wind: Vector3, limit: float) -> Dictionary:
	var caught := {}
	var gone := {}
	var t := 0.0
	var n := _w.get_block_count(chunk)
	while t < limit:
		var r: Dictionary = _w.fire_step(chunk, DT, wind, 1.0, 1000)
		t += DT
		for id in (r.killed as PackedInt32Array):
			gone[id] = t
		for id in n:
			if not caught.has(id) and _w.fire_get(chunk, id)[1] > 0.5:
				caught[id] = t
		if not bool(r.active):
			break
	return {"caught": caught, "gone": gone, "t": t}


func _tree() -> void:
	var r := Trees.recipe(0)
	var chunk := _w.create_chunk(Vector3i.ZERO, r.chunk_dims())
	r.build(_w, chunk, _pal)
	var trunk: Array[int] = []
	var leaves: Array[int] = []
	for id in _w.get_block_count(chunk):
		var m := _w.get_block_material(chunk, id)
		if m == Trees.WOOD:
			trunk.append(id)
		elif m == Trees.LEAF:
			leaves.append(id)
	_ok("a tree is a wooden trunk and a canopy of leaves", trunk.size() == Trees.TRUNK_HEIGHTS[0]
			and leaves.size() > 10 and trunk.size() + leaves.size() == _w.get_block_count(chunk),
			"%d trunk, %d leaf" % [trunk.size(), leaves.size()])
	trunk.sort_custom(func(a: int, b: int) -> bool: return _centre(chunk, a).y < _centre(chunk, b).y)
	var buried: Array[int] = []
	var open: Array[int] = []
	for id in leaves:
		(open if _exposed(chunk, id) else buried).append(id)
	# A flame to the foot of the trunk.
	var lit := _w.fire_heat(chunk, _centre(chunk, trunk[0]), 0.3, 1.2)
	var res := _burn(chunk, Vector3.ZERO, 240.0)
	var caught: Dictionary = res.caught
	var gone: Dictionary = res.gone
	var top: int = trunk[trunk.size() - 1]
	var climb := float(caught.get(top, INF)) - float(caught.get(trunk[0], INF))
	var height := _centre(chunk, top).y - _centre(chunk, trunk[0]).y
	_ok("lit at its foot, the fire climbs the trunk -- quickly", lit > 0 and climb < 20.0,
			"%.1f m in %.1f s" % [height, climb])
	var leaf_first := INF
	var leaf_last := 0.0
	var leaf_burn := 0.0
	var nb := 0
	for id in leaves:
		if caught.has(id):
			leaf_first = minf(leaf_first, caught[id])
		if gone.has(id):
			leaf_last = maxf(leaf_last, gone[id])
			if caught.has(id):
				leaf_burn += float(gone[id]) - float(caught[id])
				nb += 1
	var trunk_burn := 0.0
	var nt := 0
	for id in trunk:
		if gone.has(id) and caught.has(id):
			trunk_burn += float(gone[id]) - float(caught[id])
			nt += 1
	leaf_burn /= maxf(1.0, nb)
	trunk_burn /= maxf(1.0, nt)
	_ok("then the canopy catches, from the trunk's top", leaf_first >= float(caught.get(top, 0.0)) - 6.0
			and nb == leaves.size(), "first leaf at %.1f s, %d of %d burnt" % [leaf_first, nb, leaves.size()])
	_ok("leaves flash; the wooden trunk burns many times longer", nt == trunk.size()
			and trunk_burn > leaf_burn * 5.0,
			"a leaf brick %.1f s, a length of trunk %.1f s" % [leaf_burn, trunk_burn])
	_ok("the canopy is gone while the trunk still burns", leaf_last < float(gone.get(trunk[0], 0.0)),
			"last leaf %.1f s, trunk's foot %.1f s" % [leaf_last, float(gone.get(trunk[0], 0.0))])
	var t_open := 0.0
	for id in open:
		t_open += float(caught.get(id, res.t))
	var t_buried := 0.0
	for id in buried:
		t_buried += float(caught.get(id, res.t))
	t_open /= maxf(1.0, open.size())
	t_buried /= maxf(1.0, buried.size())
	_ok("outside in: a leaf brick buried in others catches after the ones touching air",
			buried.size() > 0 and t_buried > t_open,
			"%d touching air caught at %.1f s on average, %d buried at %.1f s" % [
				open.size(), t_open, buried.size(), t_buried])
	var scorched := _w.get_scorched_blocks(chunk).size()
	_ok("and the whole tree burns down", res.t < 240.0 and _w.get_alive_block_count(chunk) == 0,
			"all burnt in %.0f s (%d still standing charred)" % [res.t, scorched])


func _wind() -> void:
	# A strip of leaf plates 40 studs long, lit in the middle, a gale along +x.
	var chunk := _w.create_chunk(Vector3i(0, 0, 40), Vector3i(44, 4, 4))
	var ids := {}
	for i in 21:
		var id := _w.place_block(chunk, Vector3i(i * 2, 0, 40), _pal["plate_2x2"], 7)
		_w.set_block_material(chunk, id, Trees.LEAF)
		ids[id] = i
	var mid := 10
	var mid_id := -1
	for id in ids:
		if ids[id] == mid:
			mid_id = id
	_w.fire_heat(chunk, _centre(chunk, mid_id), 0.2, 1.2)
	var res := _burn(chunk, Vector3(15, 0, 0), 30.0)
	var caught: Dictionary = res.caught
	var down := 0.0
	var up := 0.0
	var t_down := INF
	var t_up := INF
	for id in caught:
		var i: int = ids[id]
		if i == mid + 6:
			t_down = caught[id]
		if i == mid - 6:
			t_up = caught[id]
		down = maxf(down, i - mid)
		up = maxf(up, mid - i)
	_ok("wind: it runs downwind faster than up", t_down < t_up,
			"6 plates downwind caught at %.1f s, upwind at %s" % [t_down,
				"never" if t_up == INF else "%.1f s" % t_up])


func _materials() -> void:
	# A column per material: a burning wooden brick, the brick on top of it.
	var mats := {"PLA": 0, "Wood": 10, "Metal": 11, "Stone": 12, "Leaf": 13}
	var chunk := _w.create_chunk(Vector3i(0, 0, 60), Vector3i(30, 16, 4))
	var top := {}
	var i := 0
	for name in mats:
		var x := i * 6
		var under := _w.place_block(chunk, Vector3i(x, 0, 60), _pal["brick_2x2"], 1)
		_w.set_block_material(chunk, under, Trees.WOOD)
		var id := _w.place_block(chunk, Vector3i(x, 3, 60), _pal["brick_2x2"], 3)
		_w.set_block_material(chunk, id, mats[name])
		top[name] = id
		_w.fire_heat(chunk, _centre(chunk, under), 0.3, 1.2)
		i += 1
	var res := _burn(chunk, Vector3.ZERO, 120.0)
	var gone: Dictionary = res.gone
	var caught: Dictionary = res.caught
	var scorched := _w.get_scorched_blocks(chunk)
	var life := {}
	for name in top:
		var id: int = top[name]
		life[name] = float(gone[id]) - float(caught.get(id, 0.0)) if gone.has(id) else -1.0
	_ok("leaves, plastic and wood burn away", gone.has(top["Leaf"]) and gone.has(top["PLA"])
			and gone.has(top["Wood"]), "%s" % [life])
	_ok("by material: leaves fastest, then plastic, wood longest",
			life["Leaf"] < life["PLA"] and life["PLA"] < life["Wood"])
	_ok("metal and stone never burn, but are charred", not caught.has(top["Metal"])
			and not caught.has(top["Stone"]) and not gone.has(top["Metal"]) and not gone.has(top["Stone"])
			and scorched.has(top["Metal"]) and scorched.has(top["Stone"]))
	print("  --   burn seconds a 2x2 brick: PLA %.1f, Wood %.1f, Leaf %.1f" % [
		BrickWorld.fire_burn_seconds(0, 12), BrickWorld.fire_burn_seconds(10, 12),
		BrickWorld.fire_burn_seconds(13, 12)])


## In the city: two brick trees on open ground, a gale from one to the other.
## The first is lit at its foot: its bricks burn out as committed BURNs and
## char as SCORCHes, which a fresh copy of the tree replays to the same dead
## bricks; it comes down; and embers carry the fire downwind to the second.
func _city() -> void:
	print("in the city")
	var city: Node3D = load("res://scenes/city.tscn").instantiate()
	root.add_child(city)
	for i in 30:
		await physics_frame
	var dir: DisasterDirector = city.disasters
	_ok("the city burns brick by brick", dir.fire is BrickFire, str(dir.fire))
	var fire := dir.fire as BrickFire
	if fire == null:
		return
	var reg: BuildingRegistry = city.registry
	var cs := BrickWorld.get_cell_size()
	var feet: Vector3 = city.ai_nav.snap(Vector3(0.0, 0.0, -40.0))
	var ids: Array[int] = []
	for k in 2:
		var cell := Vector3i(roundi(feet.x / cs.x) + k * 9, roundi(feet.y / cs.y), roundi(feet.z / cs.z))
		var id: int = reg.register_build(Trees.recipe(1), Trees.placement(cell, 1, feet.y))
		city._index_building(id)
		ids.append(id)
	_ok("two trees planted", ids[0] >= 0 and ids[1] >= 0)
	# A gale from the first tree to the second.
	fire.gale = func() -> Vector3: return Vector3(1.0, 0.0, 0.0)
	city.camera.global_position = feet + Vector3(-6.0, 4.0, 8.0)
	var a := reg.get_building(ids[0])
	var foot: Vector3 = a.xform * (Vector3(Trees.trunk_offset(1)) * cs + Vector3(cs.x, cs.y * 1.5, cs.z))
	var n0: int = city.authority.commands.size()
	var lit := dir.ctx.ignite(foot, 1.0)
	_ok("lit at the foot of its trunk", lit and a.chunk >= 0, "at %s" % foot)
	var b := reg.get_building(ids[1])
	var second := false
	var t := 0
	while t < 30 * 90 and (fire.is_burning() or t < 30):
		await physics_frame
		t += 1
		if not second and b.chunk >= 0 and city.world.fire_burning(b.chunk) > 0:
			second = true
	var burns := 0
	var chars := 0
	var dead := {}
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.target != ids[0]:
			continue
		if e.kind == DamageLog.Kind.BURN:
			burns += 1
			for id in e.blocks:
				dead[id] = true
		elif e.kind == DamageLog.Kind.SCORCH and e.flags & DamageLog.FLAG_BLOCKS:
			chars += 1
	_ok("its bricks burnt out as BURN commands, and charred as SCORCHes", burns > 0 and chars > 0,
			"%d BURN (%d bricks), %d SCORCH" % [burns, dead.size(), chars])
	# A client's copy of the tree, built from its recipe, given the same commands.
	var w2 := BrickWorld.new()
	var pal2 := TowerRecipe.bake_palette(w2)
	var r := Trees.recipe(1)
	var c2 := w2.create_chunk(Vector3i.ZERO, r.chunk_dims())
	r.build(w2, c2, pal2)
	var rep := StructureReplayer.new(w2, func(id: int, frame: int) -> int:
		return c2 if id == ids[0] and frame == 0 else -1)
	for i in range(n0, city.authority.commands.size()):
		var e: DamageLog.Entry = city.authority.commands.entries[i]
		if e.target == ids[0] and (e.kind == DamageLog.Kind.BURN or e.kind == DamageLog.Kind.SCORCH):
			rep.apply(e)
	var same := true
	for id in w2.get_block_count(c2):
		if dead.has(id) == w2.is_solid(c2, _first_cell(w2, c2, id)):
			same = false
	_ok("a client replaying them has the same bricks gone", same and rep.missed == 0,
			"%d dead of %d" % [dead.size(), w2.get_block_count(c2)])
	_ok("the tree came down, or burnt to nothing", a.toppled or a.chunk < 0
			or city.world.get_alive_block_count(a.chunk) == 0,
			"toppled %s" % a.toppled)
	_ok("embers carried it downwind to the next tree", second,
			"%d ember(s) landed, %d bricks burnt in all" % [fire.embers_landed, fire.burnt_bricks])
	root.remove_child(city)
	city.free()


func _first_cell(w: BrickWorld, chunk: int, id: int) -> Vector3i:
	return w.get_chunk_origin(chunk) + StructureReplayer.block_cell(w, chunk, id)
