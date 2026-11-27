class_name MineMobs
extends Node3D
## The mine world's creatures (Docs/MineCreatures.md): zombies and herds of
## animals (CreatureBook: pig, deer, rabbit, boar, wolf), on TerrainNav.
##
##   nav        one TerrainNav for every body: the field read once, kept in
##              sections, forgotten where an edit lands (terrain_edited);
##              water and lava read again when the fluid changes; tree trunks
##              and shut doors as obstacles
##   the field  ONE flow field out from the player for every zombie, built on
##              a worker when the player has moved or the ground changed, taken
##              when done (never waited for)
##   wind       turns slowly; carries the player's scent to the animals
##              downwind (Herd). Shown top right, as an arrow in the view
##   tiers      near: a Pawn walking; FAR (past the terrain's colliders): the
##              creature rides the nav; asleep past SLEEP_AT; wild ones gone
##              past GONE_AT, penned ones PARKED (a record) and back when near
##   life       a zombie and two wild groups near the player, made again a
##              while after they go
##   saving     (section 11) animals PENNED in -- a fence, a building, a pit,
##              anything they cannot walk 32 studs out of (TerrainNav.free_reach)
##              -- are saved with the world, parked ones too; zombies within
##              ZOMBIE_SAVE_M of the player are saved, but only by the host
##              (a client leaving a game saves no enemies)
##   gates      fence gates (MineFences): which panels open, saved here
##
## A child of the mine world node, so the origin shift moves it and every
## creature with it; positions here are that node's (the terrain frame).
## F7: a zombie. Shift+F7: a group of the next kind of animal.

const ZOMBIE_BODY := MobZombie.BODY
const FIELD_RADIUS := 96          # studs (33.6 m)
const FIELD_NODES := 90000
const FIELD_EVERY := 1.0
const FIELD_MOVE := 1.5           # metres the player moves before a new field
const SLEEP_AT := 128.0
const WAKE_AT := 118.0
const GONE_AT := 170.0
const UNPARK_AT := 140.0
const ZOMBIE_AGAIN := 25.0
const WILD_GROUPS := 2
## A spawned animal joins a herd of its kind this near.
const JOIN_HERD := 16.0
const WILD_EVERY := 45.0
const ZOMBIE_SAVE_M := 48.0
const PEN_REACH := 32             # studs out of which it cannot walk: penned
const PEN_NODES := 9000
const PEN_EVERY := 8.0
const KNOCK := 5.5
const WIND_TURN := 0.05           # rad/s at most
## Tree cells whose trunks the nav is told about (TerrainTrees' trunks are
## physics boxes, not terrain: without this a zombie walks into them).
const TREES_NEAR := 100.0
## Which wild group comes next, by weight.
const WILD_KINDS := {&"pig": 3, &"deer": 3, &"rabbit": 2, &"boar": 1, &"wolf": 1}

var host: Node = null
var nav := TerrainNav.new()
var mobs: Array = []
var herds: Array = []
## Auto spawning (off for a gate, which spawns its own).
var auto := true
var populated := false
## Past this a creature rides the nav (the terrain's colliders end about here).
var far_at := 56.0
## The way the wind blows TO, flat and unit.
var wind := Vector3.RIGHT
var wind_angle := 0.0
var wind_hold := false
## Fence gates: key -> {at: Vector3i (lattice anchor), x: bool, plates, open, mat}.
var gates := {}
## Penned animals far away, as records: {kind, p: Vector3, hp, herd}.
var parked: Array = []
## -1: ask the multiplayer API; 0 / 1: a gate's answer.
var host_override := -1
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
var _next_wild := 0.0
var _herd_t := 0.0
var _wind_noise := FastNoiseLite.new()
var _label: Label = null
var _gun_hooked = null
var _rng := RandomNumberGenerator.new()
var _tree_groups := {}   # tree cell -> [obstacle group, trunks]
var _door_groups := {}   # device cell -> obstacle group
var _next_group := 1
var _next_trees := 0.0
var _next_doors := 0.0
var _next_fluid := 0.0
var _pending := {}
var _pen_job := -1
var _pen_out := []
var _pen_mob = null
var _pen_i := 0
var _next_pen := 0.0
var _next_herd_uid := 1
var _key_kind := 0
## The player's feet and whether this is the host, as of the last step: the
## save at the world's close runs with the bodies already out of the tree.
var _last_player := Vector3.INF
var _host_seen := true


func setup(p_host: Node) -> void:
	host = p_host
	name = "Mobs"
	_rng.randomize()
	wind_angle = _rng.randf() * TAU
	_wind_noise.seed = _rng.randi()
	_wind_noise.frequency = 0.01
	nav.set_fluid(true)
	BrickFluid.set_change_log(true)
	if host.get("_gate"):
		auto = false
	var layer: CanvasLayer = host.get("_hud_layer")
	if layer != null:
		_label = Label.new()
		_label.name = "WindLabel"
		_label.anchor_left = 1.0
		_label.anchor_right = 1.0
		_label.offset_left = -420.0
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
	parked.clear()
	gates.clear()
	_pending = {}
	_take_field_job(true)
	_take_pen_job(true)
	if field_id != 0:
		nav.release_field(field_id)
	field_id = 0
	_field_goal = Vector3.INF
	for c in _tree_groups:
		nav.remove_obstacles(int(_tree_groups[c][0]))
	_tree_groups.clear()
	for c in _door_groups:
		nav.remove_obstacles(int(_door_groups[c]))
	_door_groups.clear()
	_next_trees = 0.0
	nav.clear()
	populated = false
	_play_t = 0.0
	_zombie_gone_at = -INF
	_next_wild = 0.0


func now() -> float:
	return Time.get_ticks_msec() / 1000.0


func to_terrain(global: Vector3) -> Vector3:
	return (host as Node3D).to_local(global)


func to_world(local: Vector3) -> Vector3:
	return (host as Node3D).to_global(local)


func log_line(s: String) -> void:
	log_lines.append(s)
	if log_lines.size() > 300:
		log_lines.remove_at(0)
	print("[mobs] %s" % s)


## The one who saves the world: no network peer, or the server.
func is_host() -> bool:
	if host_override >= 0:
		return host_override == 1
	if not is_inside_tree():
		return _host_seen
	var mp := multiplayer
	return mp == null or not mp.has_multiplayer_peer() or mp.is_server()


# ---------------------------------------------------------------------------
# The player as the creatures see them

func player_feet() -> Vector3:
	return host.player_feet_local()


func player_health_frac() -> float:
	var p: Pawn = host.pawn
	if p == null or not is_instance_valid(p) or p.health == null:
		return 1.0
	return clampf(p.health.get_layer_fraction(0), 0.0, 1.0)


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


## A blow on the player: a shove always; health too in survival (MineSurvival
## takes it from there).
func hurt_player(m, dmg: float, dir: Vector3) -> void:
	hits_on_player += 1
	var p: Pawn = host.pawn if host.on_foot else null
	if p != null and is_instance_valid(p):
		p.shove = Vector3(dir.x, 0.0, dir.z) * KNOCK + Vector3.UP * 2.5
		if bool(host.get("survival")) and p.health != null and not p.health.is_dead():
			p.health.apply_impact(dmg, &"")
	log_line("a %s hit the player (%.0f)" % [m.kind, dmg])


## A loud thing at `at` (terrain frame) heard within `radius` m.
func noise(at: Vector3, radius: float, why: String) -> void:
	for h in herds:
		if (h as Herd).centre().distance_to(at) <= radius:
			(h as Herd).startle(at, why)


func on_died(m) -> void:
	log_line("a %s died" % m.kind)
	if m.kind == &"zombie":
		_zombie_gone_at = now()
		return
	var drops: Dictionary = m.def.get("drops", {}) if m.get("def") != null else {}
	if host.get("drops") != null:
		for id in drops:
			if ItemCatalog.has(StringName(id)):
				host.drops.spawn(ItemStack.make(StringName(id), int(drops[id])), m.last_feet + Vector3(0, 0.4, 0))


## A push away from creatures closer than a body: flat, up to 1 long.
func separation(m) -> Vector3:
	var f: Vector3 = m.last_feet
	var push := Vector3.ZERO
	var r: float = maxf(0.85, m.body.x * 0.35)
	for o in mobs:
		if o == m or not is_instance_valid(o) or o.dead:
			continue
		var d: Vector3 = f - o.last_feet
		d.y = 0.0
		var l := d.length()
		if l < r and l > 0.001:
			push += d / l * (r - l) / r
	return push.limit_length(1.0)


# ---------------------------------------------------------------------------
# Spawning

func spawn_zombie(at: Vector3, hp := -1.0) -> MobZombie:
	var p := Pawn.spawn(self, to_world(at), 3, true, MobZombie.HP)
	var z := MobZombie.new()
	z.attach(self, p, MobLooks.make(&"zombie", {}))
	if hp > 0.0 and hp < MobZombie.HP:
		p.health.apply_impact(MobZombie.HP - hp, &"")
	mobs.append(z)
	log_line("a zombie at %s" % at)
	return z


## A group of `kind` round `at` (n of them), or at `points` (a saved herd).
func spawn_herd(kind: StringName, at: Vector3, n := 3, points: Array = [], hps: Array = [], uid := 0) -> Herd:
	var def := CreatureBook.get_def(kind)
	if def.is_empty():
		push_warning("[mobs] no creature %s" % kind)
		return null
	var h := Herd.new(self, kind, at, _rng.randi())
	h.set_meta(&"uid", uid if uid > 0 else _next_herd_uid)
	_next_herd_uid = maxi(_next_herd_uid, int(h.get_meta(&"uid"))) + 1
	var count := points.size() if not points.is_empty() else n
	for i in count:
		var spot: Vector3 = points[i] if not points.is_empty() else nav.stand_near(h.slot(i, at), def.body, 6)
		if spot == Vector3.INF:
			continue
		_add_member(h, spot, float(hps[i]) if i < hps.size() else -1.0)
	h.started = h.members.size()
	herds.append(h)
	log_line("a group of %d %s at %s" % [h.members.size(), kind, at])
	return h


## One creature of `kind` at `at` (a spawn item's RMB, Docs/MineCreatures.md
## 12): on the nearest floor it fits. An animal joins a herd of its kind
## within JOIN_HERD m, or starts one. True if one was made.
func spawn_one(kind: StringName, at: Vector3) -> bool:
	if kind == &"zombie":
		var s := nav.stand_near(at, ZOMBIE_BODY, 4)
		if s == Vector3.INF:
			return false
		spawn_zombie(s)
		return true
	var def := CreatureBook.get_def(kind)
	if def.is_empty():
		return false
	var spot := nav.stand_near(at, def.body, 4)
	if spot == Vector3.INF:
		return false
	for h in herds:
		var o := h as Herd
		if o.kind == kind and not o.alive().is_empty() and o.centre().distance_to(spot) < JOIN_HERD:
			_add_member(o, spot, -1.0)
			o.started = maxi(o.started, o.alive().size())
			log_line("a %s joined its herd at %s" % [kind, spot])
			return true
	spawn_herd(kind, spot, 0, [spot])
	return true


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


## One more animal of herd `h` at `spot`, with `hp` (< 0: whole).
func _add_member(h: Herd, spot: Vector3, hp: float) -> MobAnimal:
	var def := h.def
	var b: Vector4i = def.body
	var p := Pawn.spawn(self, to_world(spot), 4, true, float(def.hp))
	var height := float(b.y) * Pawn.PLATE_M
	p.resize(height, minf(b.x * 0.35 * 0.45, height * 0.5))
	var a := MobAnimal.new()
	a.setup_kind(h.kind)
	a.herd = h
	a.index = h.members.size()
	a.attach(self, p, MobLooks.make(h.kind, def))
	if hp > 0.0 and hp < float(def.hp):
		p.health.apply_impact(float(def.hp) - hp, &"")
	h.members.append(a)
	mobs.append(a)
	return a


func _wild_kind() -> StringName:
	var total := 0
	for k in WILD_KINDS:
		if CreatureBook.has(k):
			total += int(WILD_KINDS[k])
	var r := _rng.randi_range(0, maxi(total - 1, 0))
	for k in WILD_KINDS:
		if not CreatureBook.has(k):
			continue
		r -= int(WILD_KINDS[k])
		if r < 0:
			return k
	return &"pig"


func _populate() -> void:
	var t := now()
	if _count(&"zombie") == 0 and t - _zombie_gone_at > ZOMBIE_AGAIN:
		var s := spot_from_player(28.0, ZOMBIE_BODY)
		if s != Vector3.INF:
			spawn_zombie(s)
	if t < _next_wild:
		return
	var wild := 0
	for h in herds:
		if not (h as Herd).penned and not (h as Herd).alive().is_empty():
			wild += 1
	if wild < WILD_GROUPS:
		# The first group is pigs (the farm's trouble); then any kind.
		var kind: StringName = &"pig" if not populated else _wild_kind()
		var def := CreatureBook.get_def(kind)
		var g: Vector2i = def.group
		var s2 := spot_from_player(_rng.randf_range(24.0, 40.0), def.body)
		if s2 != Vector3.INF:
			spawn_herd(kind, s2, _rng.randi_range(g.x, g.y))
		_next_wild = t + (4.0 if not populated else WILD_EVERY)
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
		var kinds := CreatureBook.ids()
		if kinds.is_empty():
			return
		var kind: StringName = kinds[_key_kind % kinds.size()]
		_key_kind += 1
		var def := CreatureBook.get_def(kind)
		var s := spot_from_player(14.0, def.body)
		if s != Vector3.INF:
			spawn_herd(kind, s, Vector2i(def.group).y)
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
	_last_player = f
	_host_seen = is_host()
	if f != Vector3.INF and host.on_foot:
		_play_t += delta
	if not _pending.is_empty() and _play_t > 1.0:
		_spawn_saved(_pending)
		_pending = {}
	if auto and _play_t > 4.0:
		_populate()
	_tiers(f)
	_unpark(f)
	_trees_step(f)
	_doors_step()
	_fluid_step()
	_field_step(f)
	_pen_step()
	_herd_t += delta
	if _herd_t >= 1.0 / Herd.HZ:
		for h in herds:
			(h as Herd).think(_herd_t)
		_herd_t = 0.0
	_update_label()


## Near, far, asleep, gone or parked, by distance to the player.
func _tiers(f: Vector3) -> void:
	for m in mobs.duplicate():
		if not is_instance_valid(m) or m.pawn == null or not is_instance_valid(m.pawn):
			mobs.erase(m)
			continue
		if m.dead or f == Vector3.INF:
			continue
		var d: float = (m.last_feet as Vector3).distance_to(f)
		if d > GONE_AT and (auto or m.penned):
			if m.kind != &"zombie" and m.penned:
				parked.append({"kind": m.kind, "p": m.last_feet, "hp": m.hp(), "herd": int(m.herd.get_meta(&"uid"))})
				log_line("a penned %s parked" % m.kind)
			elif m.kind == &"zombie":
				_zombie_gone_at = now() - ZOMBIE_AGAIN + 5.0
			m.pawn.body.queue_free()
			mobs.erase(m)
			if m.get("herd") != null:
				m.herd.members.erase(m)
			continue
		var sleep: bool = d > (WAKE_AT if m.asleep else SLEEP_AT)
		if sleep != m.asleep:
			m.asleep = sleep
			m.pawn.body.process_mode = Node.PROCESS_MODE_DISABLED if sleep else Node.PROCESS_MODE_INHERIT
		m.set_far(d > far_at)
	for h in herds.duplicate():
		if (h as Herd).members.is_empty():
			herds.erase(h)


## Parked animals come back when the player is near their place again.
func _unpark(f: Vector3) -> void:
	if parked.is_empty() or f == Vector3.INF:
		return
	var groups := {}
	for r in parked.duplicate():
		if (r.p as Vector3).distance_to(f) < UNPARK_AT:
			parked.erase(r)
			var key := "%s/%d" % [r.kind, int(r.herd)]
			if not groups.has(key):
				groups[key] = {"kind": r.kind, "herd": int(r.herd), "points": [], "hps": []}
			groups[key].points.append(r.p)
			groups[key].hps.append(r.hp)
	for key in groups:
		var g: Dictionary = groups[key]
		var h := spawn_herd(StringName(g.kind), g.points[0], 0, g.points, g.hps, int(g.herd))
		if h != null:
			h.penned = true
			for m in h.members:
				m.penned = true


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
		var n: int = (h as Herd).alive().size()
		if n > 0:
			parts.append("%d %s%s (%s%s)" % [n, (h as Herd).kind, "" if n == 1 else "s", (h as Herd).alert_name(),
					", penned" if (h as Herd).penned else ""])
	_label.text = " · ".join(parts)


# ---------------------------------------------------------------------------
# Saving (section 11)

## What goes into the world file under "mobs".
func to_save() -> Dictionary:
	var animals := []
	for h in herds:
		var uid := int((h as Herd).get_meta(&"uid", 0))
		for m in (h as Herd).alive():
			if m.penned and m.last_feet != Vector3.INF:
				animals.append({"kind": String(m.kind), "p": _v(m.last_feet), "hp": m.hp(), "herd": uid})
	for r in parked:
		animals.append({"kind": String(r.kind), "p": _v(r.p), "hp": r.hp, "herd": int(r.herd)})
	var zombies := []
	if is_host():
		var f := _last_player
		for m in mobs:
			if is_instance_valid(m) and not m.dead and m.kind == &"zombie" and f != Vector3.INF \
					and (m.last_feet as Vector3).distance_to(f) <= ZOMBIE_SAVE_M:
				zombies.append({"p": _v(m.last_feet), "hp": m.hp()})
	var g := []
	for k in gates:
		var e: Dictionary = gates[k]
		g.append([e.at.x, e.at.y, e.at.z, e.x, e.plates, e.open, e.mat])
	return {"v": 1, "animals": animals, "zombies": zombies, "gates": g}


static func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]


static func _p(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2])) if a is Array and (a as Array).size() == 3 else Vector3.INF


## Anything to save (the world file is written when there is).
func wants_save() -> bool:
	var d := to_save()
	return not (d.animals as Array).is_empty() or not (d.zombies as Array).is_empty() or not (d.gates as Array).is_empty()


## The world file's "mobs": the gates at once; the creatures once the player
## stands in the world (their floors need the ground loaded).
func restore(d) -> void:
	if not (d is Dictionary):
		return
	for g in d.get("gates", []):
		if g is Array and (g as Array).size() >= 7:
			var at := Vector3i(int(g[0]), int(g[1]), int(g[2]))
			gates[MineFences.gate_key(at, bool(g[3]))] = {"at": at, "x": bool(g[3]), "plates": int(g[4]),
					"open": bool(g[5]), "mat": int(g[6])}
	_pending = d


func _spawn_saved(d: Dictionary) -> void:
	var groups := {}
	for a in d.get("animals", []):
		if not (a is Dictionary) or not CreatureBook.has(StringName(str(a.get("kind", "")))):
			continue
		var p := _p(a.get("p"))
		if p == Vector3.INF:
			continue
		var key := "%s/%d" % [a.kind, int(a.get("herd", 0))]
		if not groups.has(key):
			groups[key] = {"kind": a.kind, "herd": int(a.get("herd", 0)), "points": [], "hps": []}
		groups[key].points.append(p)
		groups[key].hps.append(float(a.get("hp", 0.0)))
	var f := player_feet()
	for key in groups:
		var g: Dictionary = groups[key]
		if f != Vector3.INF and (g.points[0] as Vector3).distance_to(f) > UNPARK_AT:
			for i in g.points.size():
				parked.append({"kind": StringName(g.kind), "p": g.points[i], "hp": g.hps[i], "herd": g.herd})
			continue
		var h := spawn_herd(StringName(g.kind), g.points[0], 0, g.points, g.hps, int(g.herd))
		if h != null:
			h.penned = true
			for m in h.members:
				m.penned = true
	for z in d.get("zombies", []):
		var p2 := _p(z.get("p") if z is Dictionary else null)
		if p2 != Vector3.INF:
			spawn_zombie(p2, float(z.get("hp", 0.0)))
	log_line("restored %d animals, %d zombies, %d gates" % [(d.get("animals", []) as Array).size(),
			(d.get("zombies", []) as Array).size(), gates.size()])


## One animal at a time, on a worker: can it walk out (32 studs)? If not it
## is penned (fence, building, pit) and the world keeps it.
func _pen_step() -> void:
	_take_pen_job(false)
	if _pen_job >= 0 or now() < _next_pen:
		return
	var animals := []
	for m in mobs:
		if is_instance_valid(m) and not m.dead and m.kind != &"zombie" and not m.asleep:
			animals.append(m)
	if animals.is_empty():
		return
	_pen_i = (_pen_i + 1) % animals.size()
	if _pen_i == 0:
		_next_pen = now() + PEN_EVERY
	var m = animals[_pen_i]
	_pen_mob = m
	var out := []
	_pen_out = out
	var n := nav
	var from: Vector3 = m.last_feet
	var b: Vector4i = m.body
	_pen_job = WorkerThreadPool.add_task(func() -> void:
			out.append(n.free_reach(from, b, PEN_REACH, PEN_NODES)), true, "animal pen")


func _take_pen_job(wait: bool) -> void:
	if _pen_job < 0:
		return
	if not wait and not WorkerThreadPool.is_task_completed(_pen_job):
		return
	WorkerThreadPool.wait_for_task_completion(_pen_job)   # done (or leaving)
	_pen_job = -1
	if wait or _pen_out.is_empty() or _pen_mob == null or not is_instance_valid(_pen_mob):
		return
	var was: bool = _pen_mob.penned
	_pen_mob.penned = not bool(_pen_out[0])
	if _pen_mob.penned != was:
		log_line("a %s is %s" % [_pen_mob.kind, "penned in" if _pen_mob.penned else "free"])
	var h = _pen_mob.get("herd")
	if h != null:
		var any := false
		for o in (h as Herd).alive():
			any = any or o.penned
		(h as Herd).penned = any


## Every pen judged now (a gate; a final save is fine with the last answers).
func judge_pens_now() -> void:
	_take_pen_job(true)
	for h in herds:
		var any := false
		for m in (h as Herd).alive():
			m.penned = not nav.free_reach(m.last_feet, m.body, PEN_REACH, PEN_NODES)
			any = any or m.penned
		(h as Herd).penned = any


# ---------------------------------------------------------------------------
# Fence gates (MineFences)

## Lay a fence gate (closed) through `at`; true if laid.
func place_gate(at: Vector3i, along_x: bool, plates: int, mat: int) -> bool:
	var res := MineFences.place(at, along_x, plates, mat)
	if res.is_empty():
		return false
	for r in res:
		host.terrain_edited(r)
	var a0 := MineFences.anchor(at, along_x)
	gates[MineFences.gate_key(a0, along_x)] = {"at": a0, "x": along_x, "plates": plates, "open": false, "mat": mat}
	log_line("a fence gate at %s" % a0)
	return true


## RMB on plate cell `cell`: a gate holding it opens or shuts. True if one did.
func use_gate(cell: Vector3i) -> bool:
	for k in gates.keys():
		var g: Dictionary = gates[k]
		if not MineFences.gate_has(g.at, g.x, g.plates, cell):
			continue
		if not MineFences.posts_stand(g.at, g.x, g.plates):
			gates.erase(k)      # broken up: no gate any more
			return false
		g.open = not g.open
		for r in MineFences.set_gate(g.at, g.x, g.plates, g.mat, g.open):
			host.terrain_edited(r)
		log_line("a fence gate %s" % ("opened" if g.open else "shut"))
		return true
	return false


# ---------------------------------------------------------------------------
# Tree trunks and shut doors into the nav

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


## Wiring doors and trapdoors are colliders, not cells: a shut one is an
## obstacle to the nav, an open one is not.
func _doors_step() -> void:
	var t := now()
	if t < _next_doors:
		return
	_next_doors = t + 0.5
	var w = host.get("wiring")
	if w == null:
		return
	var seen := {}
	for c in w.devices:
		var d: Dictionary = w.devices[c]
		var kind := str(MineWiring.DEVICES.get(d.item, {}).get("kind", ""))
		if kind != "door" and kind != "trapdoor":
			continue
		var shut := not bool(d.on)
		if not shut:
			continue
		seen[c] = true
		if _door_groups.has(c):
			continue
		var boxes := PackedVector3Array()
		var plates := MineWiring.plates_of(d.item)
		for b in MineWiring.footprint(c, d.item, int(d.facing)):
			boxes.append(Vector3(b))
			boxes.append(Vector3(b + Vector3i(0, plates - 1, 0)))
		_door_groups[c] = _next_group
		nav.set_obstacles(_next_group, boxes)
		_next_group += 1
		_field_dirty = true
	for c in _door_groups.keys():
		if not seen.has(c):
			nav.remove_obstacles(int(_door_groups[c]))
			_door_groups.erase(c)
			_field_dirty = true


## Water and lava move: the nav reads them again where it looks next.
func _fluid_step() -> void:
	var t := now()
	if t < _next_fluid:
		return
	_next_fluid = t + 1.0
	# The water's change log (on for this): only the sections a changed cell
	# is in read their fluid again -- the sea and rain change cells all the
	# time, and reading every section's water again cost a field 2 s.
	nav.update_fluid()


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
	_take_pen_job(true)
