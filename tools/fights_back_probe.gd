extends SceneTree

## Acceptance probe for "the city fights back" (Docs/AIPlan.md P5), in an arena.
##
##     godot --headless --path . --script tools/fights_back_probe.gd
##
## Three fights, one after another, on the physics tick:
##   1. The player shoots a soldier's cover away. The soldier leaves while the
##      cover still has seconds in it, and nothing reaches it while it hides.
##   2. After a collapse: a fallen wall section lying at an angle is the soldier's
##      cover, and a flat piece of wreck across its way is walked over, not round.
##   3. A piece falls from ten metres above a soldier. It is out from under it
##      before it lands.
## The weight of wreckage on buildings is tools/wreck_load_probe.gd and the city's
## -- --wreck gate.

const STUD := 0.35
const PLATE := 0.14

var _pass := 0
var _fail := 0
var s: AIServices
var w: BrickWorld
var palette: Dictionary
var islands: IslandManager
var player: Pawn
var player_gun: GunController
var lib: GunPartLibrary
var chunks: Array[int] = []
var _tick := 0
var _stage := 0
var _t0 := 0.0
var so: Soldier
var _log := {}
## chunk -> [body RID, block -> shape indices], so a brick that dies stops
## stopping bullets -- what the city's _disable does.
var _shapes := {}


func _init() -> void:
	print("fights back probe")
	w = BrickWorld.new()
	palette = TowerRecipe.bake_palette(w)
	s = AIServices.new()
	s.rng.seed = 9
	s.ai_world = AIWorld.new()
	s.ai_world.set_world(w)
	s.ai_nav = AINav.new()
	s.ai_nav.set_ai_world(s.ai_world)
	s.sched = AIScheduler.new()
	# The cover mechanics, not the engage decision's dice: the base policy
	# always takes cover (CombatPolicy; the choice has its own probe).
	s.policy = CombatPolicy.new()
	s.world3d = root.get_world_3d()
	s.on_structure_hit = _structure_hit
	lib = GunPlaceholderParts.build_library()
	_ground()
	islands = IslandManager.new()
	root.add_child(islands)
	islands.setup(w, ShaderMaterial.new(), null)
	player = Pawn.spawn(root, Vector3(0, 0, -20), 0, true, 1e7)
	s.pawns.append(player)
	player_gun = GunController.new()
	player_gun.aim = player.eye
	player_gun.rng = s.rng
	player_gun.exclude = [player.body.get_rid()] as Array[RID]
	player_gun.on_structure_hit = _structure_hit
	player.body.add_child(player_gun)
	var g := GunInstance.from_result(GunGenerator.generate(lib, 3, WeaponClass.builtin(&"rifle"), 1))
	g.visible = false
	player.eye.add_child(g)
	player_gun.equip(g)
	player.gun = player_gun
	# Rounds the player fires while the soldier hides, and how many reach it.
	player_gun.fired.connect(func(info: Dictionary) -> void:
		# In its first cover, while the wall is still a wall; once it has been
		# shot full of holes, rounds through them are fair.
		if so != null and is_instance_valid(so) and _stage == 0 and so.relocations == 0 				and so.state == "hide":
			_log["hide_rounds"] = int(_log.get("hide_rounds", 0)) + 1
			if not info.is_empty() and info.result != null:
				_log["hide_hits"] = int(_log.get("hide_hits", 0)) + 1)
	_stage_cover()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ground() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600.0, 1.0, 600.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)


## A box of 1x1 bricks at `lo` (cells), `size` in studs and COURSES, placed at
## `xf` (identity for a building; anything for a piece of wreck).
func _bricks(lo: Vector3i, size: Vector3i, xf := Transform3D(), anchored := true) -> int:
	var c := w.create_chunk(lo, Vector3i(size.x, size.y * 3, size.z))
	for x in size.x:
		for y in size.y:
			for z in size.z:
				w.place_block(c, lo + Vector3i(x, y * 3, z), palette["brick_1x1"], 4)
	if xf != Transform3D():
		w.set_chunk_transform(c, xf)
	w.set_chunk_anchored(c, anchored)
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


func _structure_hit(point: Vector3, _dir: Vector3, shot: Dictionary) -> void:
	for c in chunks:
		if w.is_chunk_alive(c):
			var killed := w.chip_hit(c, point, float(shot.radius), int(shot.hp))
			var sh: Array = _shapes.get(c, [])
			for id in killed:
				if not sh.is_empty() and (sh[1] as Dictionary).has(id):
					var idx = sh[1][id]
					for si in (idx if idx is Array or idx is PackedInt32Array else [idx]):
						PhysicsServer3D.body_set_shape_disabled(sh[0], int(si), true)
	var r := Vector3.ONE
	s.ai_nav.invalidate_box(AABB(point - r, r * 2.0))


func _soldier(at: Vector3, face: float) -> Soldier:
	var gun := GunInstance.from_result(GunGenerator.generate(lib, 7, WeaponClass.builtin(&"rifle"), 1))
	var o := Soldier.spawn(s, root, at, 1, gun)
	o.pawn.health.layer_configs[0].max_value = 1e6
	o.pawn.health.reset()
	o.pawn.intents.look_yaw = face
	return o


func _retire(o: Soldier) -> void:
	s.pawns.erase(o.pawn)
	o.pawn.body.queue_free()


# --- 1: cover shot away ----------------------------------------------------------

func _stage_cover() -> void:
	# A wall three studs thick, five courses (2.1 m) high: cover for somebody
	# standing (nobody crouches, Docs/AI.md A21).
	_bricks(Vector3i(-10, 0, -14), Vector3i(20, 5, 3))
	# Off the wall's end, the player in sight past it.
	so = _soldier(Vector3(11, 0, 1), 0.0)
	_log["hide_hp_lost"] = 0.0
	_log["hide_ticks"] = 0


func _tick_cover(t: float) -> void:
	# The player fires at the soldier's chest, all the time: at it when it shows,
	# into the wall in front of it when it hides -- taking the cover away.
	var to := so.pawn.chest() - player.eye.global_position
	player.intents.look_yaw = atan2(-to.x, -to.z)
	player.intents.look_pitch = atan2(to.y, Vector2(to.x, to.z).length())
	player.intents.fire = t > 3.0
	if so.state == "hide":
		_log.hide_ticks = int(_log.hide_ticks) + 1
		var hp := so.pawn.health.total_current()
		if _log.has("hp_prev"):
			_log.hide_hp_lost = float(_log.hide_hp_lost) + maxf(float(_log.hp_prev) - hp, 0.0)
	_log["hp_prev"] = so.pawn.health.total_current()
	if t > 22.0:
		player.intents.fire = false
		_ok("shot at, its cover worn away, it leaves while the cover still has time in it",
				so.relocations >= 1 and so.cover_left_with > 0.0,
				"%d relocation(s), the first with %.2f s of cover left" % [so.relocations,
				so.cover_left_with])
		# A three-course wall is exactly as tall as a crouched figure (1.26 m), so
		# a round skimming its top can clip a head. Nearly all go into the wall.
		var rounds := int(_log.get("hide_rounds", 0))
		var hits := int(_log.get("hide_hits", 0))
		_ok("and while it hid, the rounds went into the wall, not into it",
				int(_log.hide_ticks) > 20 and rounds > 10 and hits * 100 <= rounds * 15,
				"%d tick(s) hiding; %d of %d round(s) reached it" % [int(_log.hide_ticks), hits, rounds])
		_retire(so)
		_stage_wreck()
		_next()


# --- 2: wreckage as cover and as ground ------------------------------------------

var _wreck := -1
var _flat := -1


func _stage_wreck() -> void:
	# Far from the first fight: a wall section fallen and lying at 35 degrees,
	# not anchored -- a piece, not a building -- and nothing else to hide behind.
	var at := Vector3(100, 0, 0)
	var lean := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-35.0)), at + Vector3(-2.0, 0.0, -6.0))
	# Two studs thick, as a tower's wall is (TowerRecipe.WALL_THICK).
	_wreck = _bricks(Vector3i(0, 0, 0), Vector3i(12, 5, 2), lean, false)
	# And a flat slab of wreck, one course thick, across a lane between two walls.
	_bricks(Vector3i(300, 0, 60), Vector3i(1, 6, 24))
	_bricks(Vector3i(316, 0, 60), Vector3i(1, 6, 24))
	_flat = _bricks(Vector3i(0, 0, 0), Vector3i(15, 1, 8),
			Transform3D(Basis(), Vector3(301 * STUD, 0.0, 68 * STUD)), false)
	player.place(at + Vector3(0, 0, -24))
	so = _soldier(at + Vector3(0, 0, 0), 0.0)
	_log["wreck_hide"] = 0


func _tick_wreck(t: float) -> void:
	player.intents.fire = false
	var to := so.pawn.chest() - player.eye.global_position
	player.intents.look_yaw = atan2(-to.x, -to.z)
	_log["states2"] = _log.get("states2", {})
	_log.states2[so.state] = int(_log.states2.get(so.state, 0)) + 1
	# Behind high cover a soldier hides standing; behind low, crouched. Either way
	# the player's line to it has to run into the wreck.
	if so.state == "hide":
		var tr: Dictionary = s.ai_world.trace(player.eye.global_position, so.pawn.chest())
		if bool(tr.hit) and int(tr.chunk) == _wreck:
			_log.wreck_hide = int(_log.wreck_hide) + 1
	if t > 12.0 and not _log.has("walk_from"):
		_ok("after a collapse it hides behind the wreck", int(_log.wreck_hide) > 10,
				"%d tick(s) hiding with the fallen section in the player's line; states %s" % [
				int(_log.wreck_hide), _log.get("states2", {})])
		# Now walk it through the lane with the wreck lying across it.
		so.brain.active = false
		so.fire_ok = false
		player.place(Vector3(-100, 0, -100))
		var start := s.ai_nav.snap(Vector3(308 * STUD, 0.0, 62 * STUD))
		so.pawn.place(start)
		_log["walk_from"] = start
		_log["walk_top"] = 0.0
	if _log.has("walk_from"):
		var goal := Vector3(308 * STUD, 0.0, 82 * STUD)
		var r := so.move_to(goal)
		_log.walk_top = maxf(float(_log.walk_top), so.pawn.feet().y)
		if r == 1 or t > 30.0:
			_ok("and walks over a piece of wreck lying across its way",
					r == 1 and float(_log.walk_top) > 0.35,
					"arrived %s, highest step %.2f m (the slab is 0.42)" % [r == 1, float(_log.walk_top)])
			_retire(so)
			_stage_falling()
			_next()


# --- 3: not under a falling piece --------------------------------------------------

var _piece: BrickIsland


func _stage_falling() -> void:
	var at := Vector3(-100, 0, 100)
	player.place(Vector3(-100, 0, -100))
	so = _soldier(at, 0.0)
	# A slab of wreck, ten metres up, over its head, and let go.
	var c := w.create_chunk(Vector3i.ZERO, Vector3i(10, 3, 10))
	for x in 10:
		for z in 10:
			w.place_block(c, Vector3i(x, 0, z), palette["brick_1x1"], 6)
	w.set_chunk_transform(c, Transform3D(Basis(), at + Vector3(-1.75, 10.0, -1.75)))
	_piece = islands.adopt(c, null, null, 0, 4, [], -1, -1, true, true)
	_log["evaded"] = false
	_log["falling_hp"] = so.pawn.health.total_current()


func _tick_falling(t: float) -> void:
	player.intents.fire = false
	Danger.update(s.ai_world, islands)
	if so.state == "evade":
		_log.evaded = true
	var landed := _piece == null or not _piece.is_valid() or _piece.settled \
			or islands.world_aabb(_piece).position.y < 0.6
	if landed or t > 8.0:
		var box := islands.world_aabb(_piece) if _piece != null and _piece.is_valid() else AABB()
		var f := so.pawn.feet()
		var under := f.x > box.position.x - 0.2 and f.x < box.end.x + 0.2 \
				and f.z > box.position.z - 0.2 and f.z < box.end.z + 0.2
		_ok("nobody stands under a falling piece", landed and bool(_log.evaded) and not under,
				"evaded %s; at landing %.1f m from under its middle" % [_log.evaded,
				Vector2(f.x - box.get_center().x, f.z - box.get_center().z).length()])
		_next()


# --- the loop ----------------------------------------------------------------------

func _next() -> void:
	_stage += 1
	_t0 = s.now()


func _on_tick() -> void:
	_tick += 1
	s.ai_world.sync()
	s.ai_nav.service(500)
	s.sched.run()
	islands.tick()
	var t := s.now() - _t0
	match _stage:
		0: _tick_cover(t)
		1: _tick_wreck(t)
		2: _tick_falling(t)
		_:
			physics_frame.disconnect(_on_tick)
			print("\n%d passed, %d failed" % [_pass, _fail])
			quit(1 if _fail > 0 else 0)
