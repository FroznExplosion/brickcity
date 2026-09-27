extends SceneTree

## Acceptance probe for one soldier (Docs/AIPlan.md P4), in an arena.
##
##     godot --headless --path . --script tools/soldier_probe.gd
##     godot --path . --script tools/soldier_probe.gd -- --shot      (windowed, screenshot)
##
## A soldier and a player on open ground, a low wall between them, a block to
## hide behind. The soldier has to: see the player and engage; take cover on the
## side of the wall away from the player; hide and peek, firing only when it
## peeks; lose the player when the player goes behind the block, and search where
## it was; see it again and fight again; be blinded by smoke; and never fire a
## round with bricks between its eye and what it is aiming at -- all inside the
## AI budget. Everything runs on the physics tick; the clock is simulation time.

const STUD := 0.35
const PLATE := 0.14
const TICKS := 30 * 44

var _pass := 0
var _fail := 0
var s: AIServices
var w: BrickWorld
var palette: Dictionary
var soldier: Soldier
var player: Pawn
var chunks: Array[int] = []
var _tick := 0
var _shot := false
var _log := {}
var _worst_ai_us := 0
var _ai_us_sum := 0
var _hidden_seen := 0
var _hide_ticks := 0
var _peek_shots := 0
var _states := {}
var _worst_sub := {}
var _worst_at := 0
var _worst_state := ""
var _worst_after_spawn := 0
var _search_from := 0.0
var _p0 := Vector3(0.0, 0.0, -24.0)


func _init() -> void:
	print("soldier probe")
	_shot = "--shot" in OS.get_cmdline_user_args()
	w = BrickWorld.new()
	palette = TowerRecipe.bake_palette(w)
	s = AIServices.new()
	s.rng.seed = 42
	s.ai_world = AIWorld.new()
	s.ai_world.set_world(w)
	s.ai_nav = AINav.new()
	s.ai_nav.set_ai_world(s.ai_world)
	s.sched = AIScheduler.new()
	s.world3d = root.get_world_3d()
	s.on_structure_hit = _structure_hit
	_build_arena()
	s.ai_world.sync()
	var lib := GunPlaceholderParts.build_library()
	var gun := GunInstance.from_result(GunGenerator.generate(lib, 7, WeaponClass.builtin(&"rifle"), 1))
	soldier = Soldier.spawn(s, root, Vector3(0.0, 0.0, 2.0), 1, gun)
	soldier.pawn.intents.look_yaw = 0.0   # facing -Z, toward the player
	player = Pawn.spawn(root, _p0, 0, true, 100000.0)
	s.pawns.append(player)
	Soldier._greybox(player, 0)
	player.intents.look_yaw = PI
	if _shot:
		_build_view()
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# --- the arena ------------------------------------------------------------------

func _fill(chunk: int, at: Vector3i, size: Vector3i) -> void:
	for x in size.x:
		for y in size.y:
			for z in size.z:
				w.place_block(chunk, at + Vector3i(x, y, z), palette["tile_1x1"], 3)


func _build_arena() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = Layers.WORLD
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position = Vector3(0.0, -0.5, 0.0)
	ground.add_child(shape)
	root.add_child(ground)
	# The low wall: 20 studs wide (7 m), one stud thick, 9 plates (1.26 m) tall --
	# over a crouching figure's eye (1.0 m), under a standing one's (1.42).
	var wall_lo := Vector3i(-10, 0, -12)
	var wall := w.create_chunk(wall_lo, Vector3i(20, 9, 1))
	_fill(wall, wall_lo, Vector3i(20, 9, 1))
	chunks.append(wall)
	# The block the player hides behind: 12 x 10 studs, three storeys high.
	var blk_lo := Vector3i(14, 0, -100)
	var blk := w.create_chunk(blk_lo, Vector3i(12, 30, 12))
	_fill(blk, blk_lo, Vector3i(12, 30, 12))
	chunks.append(blk)
	for c in chunks:
		var body := StaticBody3D.new()
		body.collision_layer = Layers.STRUCTURE
		w.add_chunk_shapes(body.get_rid(), c, Vector3.ZERO, false)
		# The node's transform, not the server's: a node entering the tree pushes
		# its own transform to its body and would put the wall back at the origin.
		body.transform = w.get_chunk_transform(c)
		root.add_child(body)


## What a round that missed does to the arena's bricks: wear them.
func _structure_hit(point: Vector3, _dir: Vector3, shot: Dictionary) -> void:
	for c in chunks:
		w.chip_hit(c, point, float(shot.radius), int(shot.hp))
	var r := Vector3.ONE * 1.0
	s.ai_nav.invalidate_box(AABB(point - r, r * 2.0))


# --- the fight ----------------------------------------------------------------

func _on_tick() -> void:
	_tick += 1
	var t0 := Time.get_ticks_usec()
	s.ai_world.sync()
	var t_nav := Time.get_ticks_usec()
	s.ai_nav.service(500)
	_worst_sub["nav"] = maxi(int(_worst_sub.get("nav", 0)), Time.get_ticks_usec() - t_nav)
	s.sched.run()
	var st: Dictionary = s.sched.get_stats()
	for sub in ["perception", "trees", "tactical"]:
		_worst_sub[sub] = maxf(float(_worst_sub.get(sub, 0.0)), float((st[sub] as Dictionary).ms))
	var us := Time.get_ticks_usec() - t0
	if us > _worst_ai_us:
		_worst_at = _tick
		_worst_state = soldier.state
	_worst_ai_us = maxi(_worst_ai_us, us)
	if _tick > 3:
		_worst_after_spawn = maxi(_worst_after_spawn, us)
	_ai_us_sum += us
	var now := s.now()
	_states[soldier.state] = int(_states.get(soldier.state, 0)) + 1
	_watch(now)
	_script(now)
	if _tick >= TICKS:
		_finish()


var _t_start := -1.0
var _first_shot := -1.0


func _watch(now: float) -> void:
	if _t_start < 0.0:
		_t_start = now
	var t := now - _t_start
	if _first_shot < 0.0 and soldier.shots > 0:
		_first_shot = t
	if soldier.state == "hide" and soldier.pawn.is_crouched():
		_hide_ticks += 1
		if s.ai_world.bricks_between(player.eye.global_position, soldier.pawn.chest()) > 0:
			_hidden_seen += 1


var _phase := ""
var _shots_at := {}
var _searched_toward := INF


func _script(now: float) -> void:
	var t := now - _t_start
	if _shot and t >= 9.0 and not _log.has("cover_shot"):
		_log["cover_shot"] = true
		var img := root.get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("res://shots")
		img.save_png("res://shots/soldier_cover.png")
		print("  shot written: soldier_cover.png (%s at %v, crouched %s)" % [soldier.state, soldier.pawn.feet(), soldier.pawn.is_crouched()])
	if t < 14.0:
		_phase = "open"
		return
	if _phase == "open":
		# Phase A done.
		_log["shots_a"] = soldier.shots
		_log["peeks_a"] = soldier.peeks
		_log["hp_a"] = player.health.total_current()
		_log["cover_dist"] = soldier.pawn.feet().distance_to(_p0)
		# Behind the block, out of sight.
		player.place(Vector3(7.0, 0.0, -40.0))
		_phase = "hidden"
		_search_from = soldier.pawn.feet().distance_to(_p0)
	if _phase == "hidden":
		if soldier.state == "search":
			_log["searched"] = true
			_searched_toward = minf(_searched_toward, soldier.pawn.feet().distance_to(_p0))
		if t >= 26.0:
			# Out again, in the open, and firing (below): heard, then seen.
			player.place(Vector3(-2.0, 0.0, -20.0))
			_log["shots_b"] = soldier.shots
			_phase = "back"
			_log["back_at"] = t
	if _phase == "back":
		# Back, and shooting: the soldier hears where it comes from.
		if _tick % 15 == 0 and not _log.has("smoke_on"):
			s.noise(player.eye.global_position, 40.0, player)
		if not _log.has("reacquired") and soldier.shots > int(_log.shots_b):
			_log["reacquired"] = t - float(_log.back_at)
		if t >= 34.0 and not _log.has("smoke_on"):
			var mid := (soldier.eye_pos() + player.chest()) * 0.5
			s.ai_world.set_smoke(1, mid, 2.5)
			_log["smoke_on"] = t
			_log["shots_smoke0"] = soldier.shots
		if _log.has("smoke_on") and t >= float(_log.smoke_on) + 1.0 and not _log.has("blind"):
			_log["blind"] = not soldier.can_see(player)
			_log["shots_smoke1"] = soldier.shots
		if _log.has("blind") and t >= float(_log.smoke_on) + 3.0 and not _log.has("smoke_shots"):
			_log["smoke_shots"] = soldier.shots - int(_log.shots_smoke1)


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	print("  states (ticks): %s" % [_states])
	print("  worst per subsystem: %s (nav in us, the rest ms); worst tick %d (%s); after the first three ticks %.2f ms" % [
			_worst_sub, _worst_at, _worst_state, _worst_after_spawn / 1000.0])
	_ok("it sees the player and fires", _first_shot >= 0.0 and _first_shot < 3.0
			and float(_log.get("hp_a", 1e9)) < 100000.0,
			"first round at %.2f s; player %.0f hp" % [_first_shot, float(_log.get("hp_a", 0.0))])
	_ok("it takes cover and hides behind the wall, on the side away from the player",
			_hide_ticks > 30 and _hidden_seen >= _hide_ticks * 0.9,
			"%d tick(s) hiding, %d of them with bricks in the player's line" % [_hide_ticks, _hidden_seen])
	_ok("it peeks and fires, in turn", int(_log.get("peeks_a", 0)) >= 3 and int(_log.get("shots_a", 0)) > 10,
			"%d peek(s), %d round(s)" % [int(_log.get("peeks_a", 0)), int(_log.get("shots_a", 0))])
	_ok("it loses the player and searches where it was",
			_log.get("searched", false) and _searched_toward < _search_from - 3.0,
			"%.1f m from the last sighting, from %.1f" % [_searched_toward, _search_from])
	_ok("it sees the player again and fights again", _log.has("reacquired")
			and float(_log.reacquired) < 3.0, "%.2f s" % float(_log.get("reacquired", -1.0)))
	_ok("smoke blinds it", _log.get("blind", false) and int(_log.get("smoke_shots", 1)) == 0,
			"%d round(s) into the smoke" % int(_log.get("smoke_shots", -1)))
	_ok("it never fired with bricks between it and its target", soldier.blocked_shots == 0,
			"%d of %d" % [soldier.blocked_shots, soldier.shots])
	var mean := float(_ai_us_sum) / maxf(_tick, 1) / 1000.0
	# The budget is judged headless (AIPlan P4's gate): a windowed run shares the
	# machine with the renderer, and its timings say more about that.
	if _shot:
		print("  (windowed: AI mean %.3f ms a tick, worst %.2f ms -- not judged)" % [
				mean, _worst_ai_us / 1000.0])
	else:
		_ok("inside the AI budget", _worst_ai_us < 2500 and mean < 0.5,
				"mean %.3f ms a tick, worst %.2f ms" % [mean, _worst_ai_us / 1000.0])
	if _shot:
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("res://shots")
		img.save_png("res://shots/soldier.png")
		print("  shot written: soldier.png")
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _build_view() -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(9.0, 7.0, 9.0)
	cam.look_at(Vector3(0.0, 0.5, -8.0), Vector3.UP)
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	root.add_child(env)
	_view_box(Vector3(0, -0.05, -10), Vector3(60, 0.1, 60), Color(0.35, 0.38, 0.35))
	_view_box(Vector3(0.0, 0.63, -12 * STUD + STUD * 0.5), Vector3(20 * STUD, 1.26, STUD), Color(0.7, 0.35, 0.25))
	_view_box(Vector3(20 * STUD, 30 * PLATE * 0.5, -94 * STUD), Vector3(12 * STUD, 30 * PLATE, 12 * STUD), Color(0.6, 0.6, 0.62))


func _view_box(at: Vector3, size: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	mi.material_override = m
	mi.position = at
	root.add_child(mi)
