extends RefCounted
## The arena the squad probes fight in (AIPlan P6): a BrickWorld on open ground,
## the AI services over it, brick walls and rooms built to order, and what a
## round or a charge does to the bricks -- dead bricks stop stopping bullets and
## pawns, as the city's _disable does. Preloaded by the probes, not a class.
##
##     const Arena := preload("res://tools/ai_arena.gd")
##     var a := Arena.new(self, 42)
##     ... a.tick() once a physics tick ...

const STUD := 0.35
const PLATE := 0.14
const COURSE := 0.42

var root: Node
var s: AIServices
var w: BrickWorld
var palette: Dictionary
var lib: GunPartLibrary
var chunks: Array[int] = []
## Blocks killed by charges, for gates.
var breached_blocks := 0
## Every change the arena's bricks took, as the host's commands (target = the
## chunk), so a gate can replay them into a client's copy: twin().
var log := DamageLog.new()
## What bricks() built, in order, to build the client's copy from.
var _specs: Array = []
## chunk -> [body RID, block -> shape indices]
var _shapes := {}
var _ai_us_sum := 0
var _ai_ticks := 0
var worst_ai_us := 0


func _init(tree: SceneTree, seed := 1) -> void:
	root = tree.root
	w = BrickWorld.new()
	palette = TowerRecipe.bake_palette(w)
	s = AIServices.new()
	s.rng.seed = seed
	s.ai_world = AIWorld.new()
	s.ai_world.set_world(w)
	s.ai_nav = AINav.new()
	s.ai_nav.set_ai_world(s.ai_world)
	s.sched = AIScheduler.new()
	s.world3d = root.get_world_3d()
	s.on_structure_hit = structure_hit
	s.on_breach = breach
	lib = GunPlaceholderParts.build_library()
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600.0, 1.0, 600.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)


## A box of 1x1 bricks from cell `lo`, `size` in studs, COURSES and studs.
func bricks(lo: Vector3i, size: Vector3i) -> int:
	var c := w.create_chunk(lo, Vector3i(size.x, size.y * 3, size.z))
	for x in size.x:
		for y in size.y:
			for z in size.z:
				w.place_block(c, lo + Vector3i(x, y * 3, z), palette["brick_1x1"], 4)
	w.set_chunk_anchored(c, true)
	_specs.append([lo, size])
	var body := StaticBody3D.new()
	body.collision_layer = Layers.STRUCTURE
	var built: Dictionary = w.add_chunk_shapes(body.get_rid(), c, Vector3.ZERO, false)
	body.transform = w.get_chunk_transform(c)
	root.add_child(body)
	chunks.append(c)
	_shapes[c] = [body.get_rid(), built.map]
	s.ai_world.sync()
	s.ai_nav.clear_cache()
	return c


## A walled room, open to the sky: walls one stud thick, `courses` high, round a
## box of cells from (x0, z0) of `wx` by `wz` studs (walls included). A door
## `door_w` studs wide in the south (-Z) wall from x = `door_x`; `door_w` 0 for
## none. Returns {"room": RoomTactics, "opening": {} or the door}.
func room(x0: int, z0: int, wx: int, wz: int, courses: int, door_x: int, door_w: int,
		id := 1) -> Dictionary:
	if door_w > 0:
		if door_x > x0:
			bricks(Vector3i(x0, 0, z0), Vector3i(door_x - x0, courses, 1))
		if door_x + door_w < x0 + wx:
			bricks(Vector3i(door_x + door_w, 0, z0), Vector3i(x0 + wx - door_x - door_w, courses, 1))
	else:
		bricks(Vector3i(x0, 0, z0), Vector3i(wx, courses, 1))
	bricks(Vector3i(x0, 0, z0 + wz - 1), Vector3i(wx, courses, 1))
	bricks(Vector3i(x0, 0, z0 + 1), Vector3i(1, courses, wz - 2))
	bricks(Vector3i(x0 + wx - 1, 0, z0 + 1), Vector3i(1, courses, wz - 2))
	var inner := AABB(Vector3((x0 + 1) * STUD, 0.0, (z0 + 1) * STUD),
			Vector3((wx - 2) * STUD, courses * COURSE, (wz - 2) * STUD))
	var opening := {}
	if door_w > 0:
		opening = {"center": Vector3((door_x + door_w * 0.5) * STUD, 0.0, (z0 + 0.5) * STUD),
				"inward": Vector3.BACK, "width": door_w * STUD, "thick": STUD}
	return {"room": RoomTactics.make(Transform3D(), inner, id), "opening": opening}


## What a round does to the arena's bricks, as the city's StructuralDamage says:
## a gun wears them, ordnance blasts them.
func structure_hit(point: Vector3, _dir: Vector3, shot: Dictionary) -> void:
	if bool(shot.get("blast", false)):
		breach(point, float(shot.radius))
		return
	for c in chunks:
		if w.is_chunk_alive(c):
			var e := log.record(0, DamageLog.Kind.CHIP, c, point, float(shot.radius), Vector3.ZERO,
					int(shot.hp))
			_disable(c, DamageLog.apply_entry(w, c, e))
	var r := Vector3.ONE
	s.ai_nav.invalidate_box(AABB(point - r, r * 2.0))


## A breaching charge: every brick within `radius` goes.
func breach(point: Vector3, radius: float) -> void:
	for c in chunks:
		if w.is_chunk_alive(c):
			var e := log.record(0, DamageLog.Kind.BLAST, c, point, radius)
			var killed := DamageLog.apply_entry(w, c, e)
			breached_blocks += killed.size()
			_disable(c, killed)
	s.ai_world.sync()
	var r := Vector3.ONE * (radius + 1.0)
	s.ai_nav.invalidate_box(AABB(point - r, r * 2.0))


## The client: the same bricks built in a fresh world, the log applied. Returns
## how many blocks agree with this world on alive and let-go, and of how many.
func twin_agrees() -> Vector2i:
	var w2 := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w2)
	var twins: Array[int] = []
	for spec in _specs:
		var lo: Vector3i = spec[0]
		var size: Vector3i = spec[1]
		var c := w2.create_chunk(lo, Vector3i(size.x, size.y * 3, size.z))
		for x in size.x:
			for y in size.y:
				for z in size.z:
					w2.place_block(c, lo + Vector3i(x, y * 3, z), pal["brick_1x1"], 4)
		w2.set_chunk_anchored(c, true)
		twins.append(c)
	for e in log.entries:
		DamageLog.apply_entry(w2, twins[chunks.find(e.target)], e)
	var same := 0
	var n := 0
	for i in chunks.size():
		var a_boxes: Array = w.get_block_boxes(chunks[i])
		var b_boxes: Array = w2.get_block_boxes(twins[i])
		for k in a_boxes.size():
			n += 1
			if k < b_boxes.size() and bool(a_boxes[k].alive) == bool(b_boxes[k].alive) \
					and w.is_support_broken(chunks[i], k) == w2.is_support_broken(twins[i], k):
				same += 1
	return Vector2i(same, n)


func _disable(c: int, killed: PackedInt32Array) -> void:
	var sh: Array = _shapes.get(c, [])
	for id in killed:
		if not sh.is_empty() and (sh[1] as Dictionary).has(id):
			var idx = sh[1][id]
			for si in (idx if idx is Array or idx is PackedInt32Array else [idx]):
				PhysicsServer3D.body_set_shape_disabled(sh[0], int(si), true)


func rifle(seed: int) -> GunInstance:
	return GunInstance.from_result(GunGenerator.generate(lib, seed, WeaponClass.builtin(&"rifle"), 1))


func soldier(feet: Vector3, team := 1, seed := 1, hp := 100.0) -> Soldier:
	var so := Soldier.spawn(s, root, feet, team, rifle(seed))
	if hp != 100.0:
		so.pawn.health.layer_configs[0].max_value = hp
		so.pawn.health.reset()
	return so


## A player-side pawn, with a rifle if `armed`.
func player(feet: Vector3, hp := 1e7, armed := true, player_index := 0) -> Pawn:
	var p := Pawn.spawn(root, feet, 0, true, hp)
	p.set_meta(&"player", player_index)
	Soldier._greybox(p, 0)
	if armed:
		var g := GunController.new()
		g.name = "Gun"
		g.aim = p.eye
		g.rng = s.rng
		g.exclude = [p.body.get_rid()] as Array[RID]
		g.on_structure_hit = structure_hit
		p.body.add_child(g)
		# The same rifle for every player: a gate compares what they do with it.
		var gun := rifle(99)
		gun.visible = false
		p.eye.add_child(gun)
		g.equip(gun)
		p.gun = g
	s.add_pawn(p)
	return p


## Point `p` at `at` (its intents; the pawn turns its eye to them).
static func look(p: Pawn, at: Vector3) -> void:
	var to := at - p.eye.global_position
	p.intents.look_yaw = atan2(-to.x, -to.z)
	p.intents.look_pitch = atan2(to.y, Vector2(to.x, to.z).length())


## One physics tick of AI: sync, nav, the scheduler, the shared services.
func tick() -> int:
	var t0 := Time.get_ticks_usec()
	s.ai_world.sync()
	s.ai_nav.service(500)
	s.sched.run()
	s.tick()
	var us := Time.get_ticks_usec() - t0
	_ai_us_sum += us
	_ai_ticks += 1
	if _ai_ticks > 3:
		worst_ai_us = maxi(worst_ai_us, us)
	return us


func mean_ai_ms() -> float:
	return float(_ai_us_sum) / maxf(_ai_ticks, 1) / 1000.0
