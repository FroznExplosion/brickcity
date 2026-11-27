class_name MineMobs
extends Node3D
## The mine world's creatures (Docs/MineCreatures.md): a zombie and a herd of
## pigs for now, on TerrainNav.
##
##   nav        one TerrainNav for every body (the field read once, kept in
##              sections, forgotten where an edit lands: terrain_edited)
##   the field  ONE flow field out from the player for every zombie, built on
##              a worker when the player has moved or the ground changed, taken
##              when done (never waited for)
##   wind       turns slowly; carries the player's scent to the animals
##              downwind (PigHerd). Shown top right, as an arrow in the view
##   life       one zombie and one herd near the player, made again a while
##              after they die; asleep (no physics) far off, gone farther
##
## A child of the mine world node, so the origin shift moves it and every
## creature with it; positions here are that node's (the terrain frame).
## F7: a zombie. Shift+F7: a herd of pigs.

const ZOMBIE_BODY := MobZombie.BODY
const FIELD_RADIUS := 96          # studs (33.6 m)
const FIELD_NODES := 90000
const FIELD_EVERY := 1.0
const FIELD_MOVE := 1.5           # metres the player moves before a new field
const SLEEP_AT := 80.0
const WAKE_AT := 70.0
const GONE_AT := 150.0
const ZOMBIE_AGAIN := 25.0
const HERD_AGAIN := 60.0
const KNOCK := 5.5
const WIND_TURN := 0.05           # rad/s at most
## Tree cells whose trunks the nav is told about (TerrainTrees' trunks are
## physics boxes, not terrain: without this a zombie walks into them).
const TREES_NEAR := 100.0

var host: Node = null
var nav := TerrainNav.new()
var mobs: Array = []
var herds: Array = []
## Auto spawning (off for a gate, which spawns its own).
var auto := true
var populated := false
## The way the wind blows TO, flat and unit.
var wind := Vector3.RIGHT
var wind_angle := 0.0
var wind_hold := false
## For gates and the readout.
var hits_on_player := 0
var fields_built := 0
var last_field_ms := 0.0
var log_lines: Array[String] = []

var field_id := 0
var _field_goal := Vector3.INF
var _field_job := -1
var _field_out := []
var _field_dirty := false
var _next_field := 0.0
var _field_t0 := 0
var _play_t := 0.0
var _zombie_gone_at := -INF
var _herd_gone_at := -INF
var _herd_alive := false
var _herd_ever := false
var _herd_t := 0.0
var _wind_noise := FastNoiseLite.new()
var _label: Label = null
var _gun_hooked = null
var _rng := RandomNumberGenerator.new()
var _tree_groups := {}   # tree cell -> [obstacle group, trunks]
var _next_group := 1
var _next_trees := 0.0


func setup(p_host: Node) -> void:
	host = p_host
	name = "Mobs"
	_rng.randomize()
	wind_angle = _rng.randf() * TAU
	_wind_noise.seed = _rng.randi()
	_wind_noise.frequency = 0.01
	if host.get("_gate"):
		auto = false
	var layer: CanvasLayer = host.get("_hud_layer")
	if layer != null:
		_label = Label.new()
		_label.name = "WindLabel"
		_label.anchor_left = 1.0
		_label.anchor_right = 1.0
		_label.offset_left = -330.0
		_label.offset_right = -12.0
		_label.offset_top = 8.0
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_label.add_theme_font_size_override(&"font_size", 15)
		_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.8))
		_label.add_theme_constant_override(&"outline_size", 4)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(_label)


## A new world: every creature goes, the nav forgets the old field.
func reset() -> void:
	for m in mobs:
		if is_instance_valid(m) and m.pawn != null and is_instance_valid(m.pawn):
			m.pawn.body.queue_free()
	mobs.clear()
	herds.clear()
	_take_field_job(true)
	if field_id != 0:
		nav.release_field(field_id)
	field_id = 0
	_field_goal = Vector3.INF
	for c in _tree_groups:
		nav.remove_obstacles(int(_tree_groups[c][0]))
	_tree_groups.clear()
	_next_trees = 0.0
	nav.clear()
	populated = false
	_play_t = 0.0
	_herd_alive = false
	_herd_ever = false
	_zombie_gone_at = -INF


func now() -> float:
	return Time.get_ticks_msec() / 1000.0


func to_terrain(global: Vector3) -> Vector3:
	return (host as Node3D).to_local(global)


func to_world(local: Vector3) -> Vector3:
	return (host as Node3D).to_global(local)


func log_line(s: String) -> void:
	log_lines.append(s)
	if log_lines.size() > 200:
		log_lines.remove_at(0)
	print("[mobs] %s" % s)


# ---------------------------------------------------------------------------
# The player as the creatures see them

func player_feet() -> Vector3:
	return host.player_feet_local()


## {} with no player. Else feet, chest (terrain frame), crouched, speed (m/s
## along the ground), sprinting, light (0..1, the sky's and lava's at the chest).
func player_info() -> Dictionary:
	var f: Vector3 = host.player_feet_local()
	if f == Vector3.INF:
		return {}
	var crouched := false
	var speed := 0.0
	var sprinting := false
	var p: Pawn = host.pawn if host.on_foot else null
	if p != null and is_instance_valid(p):
		crouched = p.is_crouched()
		var v := p.body.velocity
		speed = Vector2(v.x, v.z).length()
		sprinting = p.intents.run and speed > Pawn.WALK_SPEED * 1.2
	var chest := f + Vector3(0, 1.05 if not crouched else 0.7, 0)
	var sky := BrickTerrain.sky_light_at(chest) / 15.0
	var sun := FarmPlant.sun_at(float(host.get("_time")))
	var lamp := BrickTerrain.block_light_at(chest) / 15.0
	return {"feet": f, "chest": chest, "crouched": crouched, "speed": speed,
			"sprinting": sprinting, "light": maxf(sky * sun, lamp)}


## A zombie's blow: a shove (the player cannot be hurt yet).
func hit_player(z, dir: Vector3) -> void:
	hits_on_player += 1
	var p: Pawn = host.pawn if host.on_foot else null
	if p != null and is_instance_valid(p):
		p.shove = Vector3(dir.x, 0.0, dir.z) * KNOCK + Vector3.UP * 2.5
	log_line("%s hit the player" % z.kind)


## A loud thing at `at` (terrain frame) heard within `radius` m.
func noise(at: Vector3, radius: float, why: String) -> void:
	for h in herds:
		if (h as PigHerd).centre().distance_to(at) <= radius:
			(h as PigHerd).startle(at, why)


func on_died(m) -> void:
	log_line("%s died" % m.kind)
	if m.kind == &"zombie":
		_zombie_gone_at = now()
	elif m.kind == &"pig":
		if host.get("drops") != null:
			host.drops.spawn(ItemStack.make(&"raw_pork", 2), m.feet() + Vector3(0, 0.4, 0))
		for h in herds:
			if (h as PigHerd).members.has(m):
				(h as PigHerd).startle(m.feet(), "one was killed")


## A push away from creatures closer than a body: flat, up to 1 long.
func separation(m) -> Vector3:
	var f: Vector3 = m.feet()
	var push := Vector3.ZERO
	for o in mobs:
		if o == m or not is_instance_valid(o) or o.dead:
			continue
		var d: Vector3 = f - o.feet()
		d.y = 0.0
		var l := d.length()
		if l < 0.85 and l > 0.001:
			push += d / l * (0.85 - l) / 0.85
	return push.limit_length(1.0)


# ---------------------------------------------------------------------------
# Spawning

func spawn_zombie(at: Vector3) -> MobZombie:
	var p := Pawn.spawn(self, to_world(at), 3, true, MobZombie.HP)
	var z := MobZombie.new()
	z.attach(self, p, MobLooks.zombie())
	mobs.append(z)
	log_line("a zombie at %s" % at)
	return z


func spawn_herd(at: Vector3, n := 3) -> PigHerd:
	var h := PigHerd.new(self, at, _rng.randi())
	for i in n:
		var spot := nav.stand_near(h.slot(i, at), MobPig.BODY, 6)
		if spot == Vector3.INF:
			continue
		var p := Pawn.spawn(self, to_world(spot), 4, true, MobPig.HP)
		p.resize(MobPig.HEIGHT, 0.3)
		var pig := MobPig.new()
		pig.herd = h
		pig.index = h.members.size()
		pig.attach(self, p, MobLooks.pig())
		h.members.append(pig)
		mobs.append(pig)
	herds.append(h)
	log_line("a herd of %d pigs at %s" % [h.members.size(), at])
	return h


## A floor `dist` m from the player in a random way for `body`, or INF.
func spot_from_player(dist: float, body: Vector4i) -> Vector3:
	var f := player_feet()
	if f == Vector3.INF:
		return Vector3.INF
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	for _try in 8:
		var a := _rng.randf() * TAU
		var p := f + Vector3(cos(a), 0.0, sin(a)) * dist
		var top := BrickTerrain.surface_plate(floori(p.x / stud), floori(p.z / stud))
		# Not into a cave far below or a hill far above: near the player's level.
		var y := (top + 1) * plate
		if absf(y - f.y) > 12.0:
			y = f.y
		var s := nav.stand_near(Vector3(p.x, y, p.z), body, 8)
		if s != Vector3.INF:
			return s
	return Vector3.INF


func _populate() -> void:
	var t := now()
	if _count(&"zombie") == 0 and t - _zombie_gone_at > ZOMBIE_AGAIN:
		var s := spot_from_player(28.0, ZOMBIE_BODY)
		if s != Vector3.INF:
			spawn_zombie(s)
	var pigs := 0
	for h in herds:
		pigs += (h as PigHerd).alive().size()
	if pigs == 0:
		if _herd_alive:
			_herd_alive = false
			_herd_gone_at = t
		if not _herd_ever or t - _herd_gone_at > HERD_AGAIN:
			herds.clear()
			var s2 := spot_from_player(24.0, MobPig.BODY)
			if s2 != Vector3.INF and spawn_herd(s2, 3).members.size() > 0:
				_herd_alive = true
				_herd_ever = true
	populated = true


func _count(k: StringName) -> int:
	var n := 0
	for m in mobs:
		if is_instance_valid(m) and not m.dead and m.kind == k:
			n += 1
	return n


func _unhandled_input(event: InputEvent) -> void:
	if host == null or host.get("_gate") or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo or k.keycode != KEY_F7:
		return
	if k.shift_pressed:
		var s := spot_from_player(14.0, MobPig.BODY)
		if s != Vector3.INF:
			spawn_herd(s, 3)
	else:
		var s2 := spot_from_player(14.0, ZOMBIE_BODY)
		if s2 != Vector3.INF:
			spawn_zombie(s2)
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Every frame (MineWorld._process)

func step(delta: float) -> void:
	_hook_gun()
	_wind_step(delta)
	var f := player_feet()
	if f != Vector3.INF and host.on_foot:
		_play_t += delta
	if auto and _play_t > 4.0:
		_populate()
	# Sleep far off, gone farther; the dead are let go.
	for m in mobs.duplicate():
		if not is_instance_valid(m) or m.pawn == null or not is_instance_valid(m.pawn):
			mobs.erase(m)
			continue
		if m.dead or f == Vector3.INF:
			continue
		var d: float = (m.feet() as Vector3).distance_to(f)
		if d > GONE_AT and auto:
			m.pawn.body.queue_free()
			mobs.erase(m)
			if m.kind == &"zombie":
				_zombie_gone_at = now() - ZOMBIE_AGAIN + 5.0
			continue
		var sleep: bool = d > (WAKE_AT if m.asleep else SLEEP_AT)
		if sleep != m.asleep:
			m.asleep = sleep
			m.pawn.body.process_mode = Node.PROCESS_MODE_DISABLED if sleep else Node.PROCESS_MODE_INHERIT
	_trees_step(f)
	_field_step(f)
	_herd_t += delta
	if _herd_t >= 1.0 / PigHerd.HZ:
		for h in herds:
			(h as PigHerd).think(_herd_t)
		_herd_t = 0.0
	_update_label()


func _hook_gun() -> void:
	var g = host.get("gun")
	if g == null or g == _gun_hooked:
		return
	_gun_hooked = g
	(g as GunController).fired.connect(func(_info: Dictionary) -> void:
			var f := player_feet()
			if f != Vector3.INF:
				noise(f, 60.0, "a shot"))


func _wind_step(delta: float) -> void:
	if not wind_hold:
		var turn := _wind_noise.get_noise_1d(now() * 10.0) * WIND_TURN * 2.0
		wind_angle = fposmod(wind_angle + clampf(turn, -WIND_TURN, WIND_TURN) * delta, TAU)
	wind = Vector3(cos(wind_angle), 0.0, sin(wind_angle))


## The wind's way set (a gate): blowing toward `dir`.
func set_wind(dir: Vector3) -> void:
	wind_hold = true
	wind_angle = atan2(dir.z, dir.x)
	wind = Vector3(cos(wind_angle), 0.0, sin(wind_angle))


const ARROWS := ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]


func _update_label() -> void:
	if _label == null:
		return
	var cam = host.get("cam")
	var yaw := 0.0
	if cam != null and is_instance_valid(cam):
		var fwd: Vector3 = -(cam as Node3D).global_transform.basis.z
		yaw = atan2(fwd.x, -fwd.z)
	# The wind's way in the view: up = blowing the way you look.
	var wa := atan2(wind.x, -wind.z) - yaw
	var i := posmod(roundi(wa / (TAU / 8.0)), 8)
	var parts := PackedStringArray(["wind %s" % ARROWS[i]])
	var z := _count(&"zombie")
	if z > 0:
		parts.append("%d zombie%s" % [z, "" if z == 1 else "s"])
	for h in herds:
		var n: int = (h as PigHerd).alive().size()
		if n > 0:
			parts.append("%d pig%s (%s)" % [n, "" if n == 1 else "s", (h as PigHerd).alert_name()])
	_label.text = " · ".join(parts)


# ---------------------------------------------------------------------------
# Tree trunks into the nav

func _trees_step(f: Vector3) -> void:
	var t := now()
	if t < _next_trees or f == Vector3.INF:
		return
	_next_trees = t + 1.0
	var trees = host.get("_trees")
	if trees == null or not is_instance_valid(trees):
		return
	var cells: Dictionary = trees._cells
	var cell_m := float(TerrainTrees.STREAM_CELL) * BrickWorld.get_stud_metres()
	var seen := {}
	for c in cells:
		var mid := (Vector2(c) + Vector2(0.5, 0.5)) * cell_m
		if mid.distance_to(Vector2(f.x, f.z)) > TREES_NEAR:
			continue
		seen[c] = true
		var rows: Array = cells[c]
		var g = _tree_groups.get(c)
		if g != null and int(g[1]) == rows.size():
			continue
		var id: int = int(g[0]) if g != null else _next_group
		if g == null:
			_next_group += 1
		nav.set_obstacles(id, trunk_boxes(rows))
		_tree_groups[c] = [id, rows.size()]
	for c in _tree_groups.keys():
		if not seen.has(c):
			nav.remove_obstacles(int(_tree_groups[c][0]))
			_tree_groups.erase(c)


## Trunk boxes of TerrainTrees rows as nav cells: [lo, hi, lo, hi, ...].
static func trunk_boxes(rows: Array) -> PackedVector3Array:
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	var out := PackedVector3Array()
	for row in rows:
		var v: int = row.variant
		var size := Trees.trunk_size(v)
		var foot: Vector3 = (row.xf as Transform3D) * Trees.trunk_foot(v)
		var lo := Vector3(floorf((foot.x - size.x * 0.5) / stud + 0.01), floorf(foot.y / plate + 0.01),
				floorf((foot.z - size.z * 0.5) / stud + 0.01))
		var hi := lo + Vector3(roundf(size.x / stud) - 1.0, roundf(size.y / plate) - 1.0, roundf(size.z / stud) - 1.0)
		out.append(lo)
		out.append(hi)
	return out


# ---------------------------------------------------------------------------
# The zombies' shared field

func field_next(from: Vector3) -> Vector3:
	if field_id == 0:
		return Vector3.INF
	return nav.field_next(field_id, from)


## Metres of walking from `from` to the player on the field (INF: not in it).
func field_cost(from: Vector3) -> float:
	if field_id == 0:
		return INF
	return nav.field_cost(field_id, from)


func _field_step(f: Vector3) -> void:
	_take_field_job(false)
	if _field_job >= 0 or f == Vector3.INF or _count(&"zombie") == 0:
		return
	var t := now()
	if t < _next_field:
		return
	var moved := _field_goal == Vector3.INF or f.distance_to(_field_goal) > FIELD_MOVE
	if not moved and not _field_dirty:
		return
	_next_field = t + FIELD_EVERY
	_field_dirty = false
	_field_goal = f
	var out := []
	_field_out = out
	var n := nav
	var goal := f
	_field_t0 = Time.get_ticks_usec()
	_field_job = WorkerThreadPool.add_task(func() -> void:
			out.append(n.build_field(goal, FIELD_RADIUS, ZOMBIE_BODY, FIELD_NODES)), true, "zombie field")


func _take_field_job(wait: bool) -> void:
	if _field_job < 0:
		return
	if not wait and not WorkerThreadPool.is_task_completed(_field_job):
		return
	WorkerThreadPool.wait_for_task_completion(_field_job)   # done (or leaving)
	_field_job = -1
	if wait or _field_out.is_empty():
		return
	var id := int(_field_out[0])
	last_field_ms = (Time.get_ticks_usec() - _field_t0) / 1000.0
	fields_built += 1
	if id == 0:
		_field_dirty = true   # the player on no floor a zombie fits (flying, a ledge): again later
		return
	if field_id != 0:
		nav.release_field(field_id)
	field_id = id


## MineWorld.terrain_edited: the sections the edit touched go, the field is made again.
func terrain_edited(res: Dictionary) -> void:
	if res.has("box_lo") and res.has("box_hi"):
		nav.invalidate_box(res.box_lo, res.box_hi)
	else:
		nav.clear()
	_field_dirty = true


func _exit_tree() -> void:
	_take_field_job(true)
