class_name WiringTraps
extends RefCounted
## The TRAPS KIT of the mine world's wiring (Docs/MineWiring.md 5, 7, 8, 19):
## stages 5 and 6 -- shooter, dropper, release brick, alarm. MineWiring keeps
## them in its DEVICES table and calls these at a few hooks (placing, taking,
## the tick, the look, the readout, saving), so the devices of the earlier
## stages and this kit stay apart. Never names MineWiring (two class_name
## scripts typing each other leak at exit): `w` is the wiring, untyped.
##
##   shooter        (id `dispenser`, kept for saves) faces a way, 9 slots
##                  (RMB opens them, the chest screen). Power turning on at
##                  its back or sides shoots ONE item out of its front, the
##                  first slot that holds something. Weapons do damage:
##                    arrow     flies (WiringArrow): hurts a body, or lies
##                              where it lands, an arrow to pick up again
##                    a gun     one round through the weapon system (its own
##                              GunController aimed out of the front: damage,
##                              crits, bricks broken); the gun stays, its
##                              magazine reloads itself as the guns' do
##                    grenade   thrown up to 6 m out in front (Grenade.throw:
##                              its blast breaks bricks and hurts bodies)
##                    bucket    pours a brick of its water in front (finite:
##                              still water, BrickFluid.STILL)
##                    source bucket  its water or lava, as one brick of still
##                              fluid (never a spring: finite only)
##                    anything else  launched LAUNCH_SPEED out of the front:
##                              still an item (food, blocks), a pickup where
##                              it comes down -- it hurts nobody
##   dropper        the same slots and power; drops one item out of its front
##                  as a pickup (DroppedItems), whatever it is: never fires.
##   release brick  a real brick of the ground (a terrain material, so the
##                  collapse survey counts it as support), 1 stud x 3 plates.
##                  Powered, it lets go: its cells turn to air, and the
##                  survey (terrain_edited) drops whatever it alone held -- a
##                  bridge, a floor, a cave roof. RELEASE_HOLD ticks after the
##                  power goes it grips again (solid), if its cells are still
##                  air and nobody stands in them.
##   motion sensor  faces a way: 15 while a body (the player, a creature) is
##                  in the box in front of it -- MOTION_RANGES studs out (RMB
##                  steps them), 3 wide, its line stopped by the first solid
##                  stud. Out of every side (Docs/MineWiring.md 28).
##   light sensor   a plate: the sky light over it times the daylight, 0-15
##                  (a level: a number display shows it); RMB turns it into a
##                  night sensor (15 minus that).
##   fluid sensor   faces a way: the water or lava in the stud in front, 5 a
##                  tile (0-15); RMB picks any / water / lava.
##   counter        a gate: its back turning on counts; at N (RMB: 2-10) it
##                  gives COUNTER_PULSE ticks of 15 out of its front and starts
##                  again. Its right side turning on sets it back to 0.
##   alarm          powered: a siren, a turning red light, and every hostile
##                  creature within ALARM_REACH is called to it (MineMobs.alarm),
##                  again every ALARM_AGAIN ticks while it stays on.

const SIDES: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const KIND_OF := {&"dispenser": "dispenser", &"dropper": "dropper", &"release_brick": "release", &"alarm": "alarm",
		&"motion_sensor": "motion", &"light_sensor": "light", &"fluid_sensor": "fluidsense"}
## The sensors (section 28).
const SENSORS := ["motion", "light", "fluidsense"]
## A motion sensor's reach, studs, by its setting (RMB steps it).
const MOTION_RANGES := [6, 10, 3]
## Ticks a motion sensor stays on after the last body left its box.
const MOTION_HOLD := 5
## How often a light sensor and a fluid sensor look again (ticks).
const LIGHT_EVERY := 10
const FLUID_EVERY := 5
## A counter's pulse at its count (ticks).
const COUNTER_PULSE := 5
const FLUID_NAMES := ["any", "water", "lava"]
const SLOTS := 9
const LEVEL := 15
## How far a dispenser throws a grenade (studs), at most.
const THROW_STUDS := 17
## Ticks a release brick stays let go after its power drops (2 s): the survey
## must see it gone before it grips again.
const RELEASE_HOLD := 20
## How far an alarm calls (metres), and how often while it stays on (ticks).
const ALARM_REACH := 48.0
const ALARM_AGAIN := 20
## A dropped item's speed out of a dropper's front, and a launched one's out
## of a shooter's (m/s; dropped items slow down as they fly: ~4 m).
const DROP_SPEED := 2.4
const LAUNCH_SPEED := 9.0

## (lo, hi, material) -> void: a probe's ground edit instead of BrickTerrain's.
static var edit_fn := Callable()
## A probe's world for the sensors: (point) -> sky light 0-15; () -> daylight
## 0-1; (cell) -> {"fluid", "amount"} (BrickFluid.cell_info's shape).
static var light_fn := Callable()
static var day_fn := Callable()
static var fluid_fn := Callable()
static var _release_mat := -1
static var _siren: AudioStreamWAV = null


static func kind(item: StringName) -> String:
	return str(KIND_OF.get(item, ""))


## A device that is ground (the release brick): its cells are terrain.
static func is_terrain(item: StringName) -> bool:
	return item == &"release_brick"


static func has_slots(item: StringName) -> bool:
	return item == &"dispenser" or item == &"dropper"


## The release brick's material: the building colour (MAT_FIL_BASE + a
## filament) nearest a warning yellow, so it reads apart from the ground and
## needs no new terrain material.
static func release_material() -> int:
	if _release_mat < 0:
		var want := Color(0.95, 0.75, 0.1)
		var best := 0
		var best_d := INF
		for f in BrickWorld.get_filament_count():
			var col := BrickWorld.get_filament_colour(f)
			var dd := Vector3(col.r - want.r, col.g - want.g, col.b - want.b).length()
			if dd < best_d:
				best_d = dd
				best = f
		_release_mat = ItemCatalog.BUILDING_MATERIAL_BASE + best
	return _release_mat


static func _cells(c: Vector3i) -> Array[Vector3i]:
	return [c, c + Vector3i(0, 1, 0), c + Vector3i(0, 2, 0)]


# ---------------------------------------------------------------------------
# Placing, holding, taking

## A release brick sits on the courses of the ground's bricks (3 plates), as a
## laid block does: the first course at or over `c` that is all air.
static func snap(w, c: Vector3i, item: StringName) -> Vector3i:
	if not is_terrain(item):
		return c
	var y0 := floori(c.y / 3.0) * 3
	var s := Vector3i(c.x, y0, c.z)
	for k in _cells(s):
		if w._solid(k):
			return s + Vector3i(0, 3, 0)
	return s


## Is a release brick held where it would go: ground, or another release
## brick, against any face of it.
static func held(w, c: Vector3i) -> bool:
	if w._solid(c + Vector3i.DOWN) or w._solid(c + Vector3i(0, 3, 0)):
		return true
	for k in _cells(c):
		for s in SIDES:
			if w._solid(k + s):
				return true
			var o = w._device_at(k + s)
			if o != null and w.devices.has(o) and is_terrain(w.devices[o].item):
				return true
	for o in [w._device_at(c + Vector3i.DOWN), w._device_at(c + Vector3i(0, 3, 0))]:
		if o != null and w.devices.has(o) and is_terrain(w.devices[o].item):
			return true
	return false


## Broken (check): a release brick that is not let go whose cells are not all
## solid any more -- shot out, blown, fallen.
static func broken(w, c: Vector3i, d: Dictionary) -> bool:
	if bool(d.on) or bool(d.get("pending", false)):
		return false
	for k in _cells(c):
		if not w._solid(k):
			return true
	return false


## Just placed (`force`: loaded, the ground is as saved): slots, or the brick
## laid into the ground.
static func on_place(w, c: Vector3i, d: Dictionary, force: bool) -> void:
	if has_slots(d.item):
		d["slots"] = Inventory._empty(SLOTS)
	if SENSORS.has(kind(d.item)):
		d.timer = 1      # a sensor is always live: it looks again on its own
	if d.item == &"counter":
		d["count"] = 0
		if int(d.setting) < 2:
			d.setting = 3
	if is_terrain(d.item) and not force:
		d["pending"] = true
		w.trap_edits.append([c, c + Vector3i(0, 2, 0), release_material(), c])


## Taken (LMB, a shot, a blast, its ground gone): what it held falls out; a
## release brick's cells go with it; an open screen on it shuts.
static func on_remove(w, c: Vector3i, d: Dictionary) -> void:
	if has_slots(d.item):
		var at: Vector3 = w.device_box(c).get_center()
		for s in d.get("slots", []):
			if s != null and w.drops != null:
				w.drops.spawn(s, at, Vector3(randf_range(-1.0, 1.0), 2.5, randf_range(-1.0, 1.0)))
		if w.host != null and w.host.has_method("close_wire_slots"):
			w.host.close_wire_slots(slot_key(c))
	if is_terrain(d.item) and not bool(d.on):
		var solid := false
		for k in _cells(c):
			solid = solid or w._solid(k)
		if solid:
			w.trap_edits.append([c, c + Vector3i(0, 2, 0), 0, null])
	if d.has("gun_ctrl") and is_instance_valid(d.gun_ctrl):
		(d.gun_ctrl as Node).queue_free()


## The key a dispenser's slots are open under in the inventory (never a
## chest's key: those have no prefix).
static func slot_key(c: Vector3i) -> String:
	return "wire:%d,%d,%d" % [c.x, c.y, c.z]


## RMB on a dispenser or dropper: its slots in the chest screen.
static func use(w, c: Vector3i, d: Dictionary) -> bool:
	if SENSORS.has(kind(d.item)):
		match kind(d.item):
			"motion":
				d.setting = (int(d.setting) + 1) % MOTION_RANGES.size()
			"light":
				d.setting = 1 - clampi(int(d.setting), 0, 1)
				d.timer = 1      # looks again at once
			"fluidsense":
				d.setting = (int(d.setting) + 1) % FLUID_NAMES.size()
				d.timer = 1
		w._show_device(c)
		w._logic_dirty = true
		w._changed()
		return true
	if not has_slots(d.item):
		return false
	if w.host != null and w.host.has_method("open_wire_slots"):
		w.host.open_wire_slots(c, d.slots, str(ItemCatalog.get_def(d.item).get("name", "Dispenser")))
	d["opened"] = int(d.get("opened", 0)) + 1
	return true


## The ground edits queued this tick, made at its end (never while the tick
## or a check walks the devices: an edit runs `check` at once).
static func flush(w) -> void:
	if w.trap_edits.is_empty():
		return
	var edits: Array = w.trap_edits.duplicate()
	w.trap_edits.clear()
	for e in edits:
		_edit(w, e[0], e[1], int(e[2]))
		if e[3] != null and w.devices.has(e[3]):
			w.devices[e[3]].erase("pending")


static func _edit(w, lo: Vector3i, hi: Vector3i, mat: int) -> void:
	if edit_fn.is_valid():
		edit_fn.call(lo, hi, mat)
		return
	if w.host == null or not w.host.has_method("terrain_edited"):
		return
	var r: Dictionary = BrickTerrain.fill_box(lo, hi, mat, mat != 0)
	if mat != 0 and int(r.get("changed", 0)) > 0:
		# One brick, as a laid block is (Docs/TerrainBond.md 1).
		BrickTerrain.mark_placed(lo, hi, mat)
	w.host.terrain_edited(r)


# ---------------------------------------------------------------------------
# The tick

## After the nets, lamps, doors and gate tiles of MineWiring._evaluate: each
## kit device reacts to the power at it.
static func evaluate(w) -> void:
	var bodies = null    # asked once, the first time a motion sensor wants them
	for c in w.devices.keys():
		if not w.devices.has(c):
			continue
		var d: Dictionary = w.devices[c]
		if SENSORS.has(kind(d.item)):
			var was := int(d.out)
			match kind(d.item):
				"motion":
					if bodies == null:
						bodies = w.bodies_fn.call() if w.bodies_fn.is_valid() else []
					if sees(w, c, d, bodies):
						d["hold"] = MOTION_HOLD
					d.out = LEVEL if int(d.get("hold", 0)) > 0 else 0
					d["hold"] = maxi(int(d.get("hold", 0)) - 1, 0)
					d.timer = 1
				"light":
					d.timer = int(d.timer) - 1
					if int(d.timer) <= 0:
						d.timer = LIGHT_EVERY
						var lvl := light_level(w, c)
						d.out = LEVEL - lvl if int(d.setting) == 1 else lvl
				"fluidsense":
					d.timer = int(d.timer) - 1
					if int(d.timer) <= 0:
						d.timer = FLUID_EVERY
						d.out = fluid_level(w, c, d)
			if int(d.out) != was:
				w._show_device(c)
			continue
		match kind(d.item):
			"dispenser", "dropper":
				var p := _power_not_front(w, c, d) > 0
				if p and int(d.prev) == 0:
					fire(w, c, d)
				if p != (int(d.prev) > 0):
					d.prev = 1 if p else 0
					w._show_device(c)
			"release":
				if w.power_in(c) > 0:
					d.timer = RELEASE_HOLD
					if not bool(d.on):
						d.on = true
						d["released"] = int(d.get("released", 0)) + 1
						w.trap_edits.append([c, c + Vector3i(0, 2, 0), 0, null])
						w._show_device(c)
				elif bool(d.on):
					d.timer = maxi(int(d.timer) - 1, 0)
					if int(d.timer) == 0:
						if _can_grip(w, c):
							d.on = false
							d["pending"] = true
							w.trap_edits.append([c, c + Vector3i(0, 2, 0), release_material(), c])
							w._show_device(c)
						else:
							d.timer = 10     # rubble or a body in it: try again in a second
			"alarm":
				var on: bool = w.power_in(c) > 0
				if on != bool(d.on):
					d.on = on
					d.out = LEVEL if on else 0
					d.timer = 0
					w._show_device(c)
				if on:
					if int(d.timer) <= 0:
						_call(w, c, d)
						d.timer = ALARM_AGAIN
					else:
						d.timer = int(d.timer) - 1


## The highest level at a facing device's back and sides (not its front: what
## it fires into).
static func _power_not_front(w, c: Vector3i, d: Dictionary) -> int:
	var front := SIDES[int(d.facing)]
	var lvl := 0
	for s in SIDES:
		if s != front:
			lvl = maxi(lvl, int(w.side_input(c, s)[0]))
	return lvl


## A release brick grips again only into air with nobody in it.
static func _can_grip(w, c: Vector3i) -> bool:
	for k in _cells(c):
		if w._solid(k):
			return false
	var box: AABB = w.device_box(c)
	var bodies: Array = w.bodies_fn.call() if w.bodies_fn.is_valid() else []
	for p in bodies:
		var q: Vector3 = p
		if AABB(q - Vector3(0.3, 0.0, 0.3), Vector3(0.6, 1.8, 0.6)).intersects(box):
			return false
	return true


static func _call(w, c: Vector3i, d: Dictionary) -> void:
	d["calls"] = int(d.get("calls", 0)) + 1
	var at: Vector3 = w.device_box(c).get_center()
	var n := 0
	if w.host != null and w.host.get("mobs") != null:
		n = int(w.host.mobs.alarm(at, ALARM_REACH))
	d["called"] = n


# ---------------------------------------------------------------------------
# Firing

## The first slot with something in it, or -1.
static func _first(d: Dictionary) -> int:
	var slots: Array = d.get("slots", [])
	for i in slots.size():
		if slots[i] != null and not (slots[i] as ItemStack).is_empty():
			return i
	return -1


## Where a facing device's front is (terrain frame), and which way.
static func front_point(w, c: Vector3i, d: Dictionary) -> Vector3:
	var box: AABB = w.device_box(c)
	return box.get_center() + Vector3(SIDES[int(d.facing)]) * (w._stud * 0.5 + 0.06)


## Power turned on at a dispenser or dropper: one item out of its front.
## `d.fired` counts, `d.last` names what went (probes, the readout).
static func fire(w, c: Vector3i, d: Dictionary) -> bool:
	var i := _first(d)
	if i < 0:
		d["last"] = "empty"
		return false
	var slots: Array = d.slots
	var s: ItemStack = slots[i]
	var how := "drop"
	if d.item == &"dispenser":
		how = "launch"
		match ItemCatalog.kind(s.id):
			"arrow":
				how = "arrow"
			"gun":
				how = "gun"
			"grenade":
				how = "grenade"
			"bucket":
				how = "bucket" if int(s.data.get("tiles", 0)) > 0 else "launch"
			"source_bucket":
				how = "source" if int(s.data.get("fluid", 0)) != 0 else "launch"
	var ok := true
	match how:
		"gun":
			ok = _fire_gun(w, c, d, s)
		"arrow":
			ok = _shoot_arrow(w, c, d)
			if ok:
				_take_one(slots, i)
		"grenade":
			ok = _throw_grenade(w, c, d)
			if ok:
				_take_one(slots, i)
		"bucket":
			var n := mini(3, int(s.data.tiles))
			ok = _pour(w, c, d, 1, n)
			if ok:
				_set_data(s, "tiles", int(s.data.tiles) - n)
		"source":
			ok = _pour(w, c, d, int(s.data.fluid), 3)
			if ok:
				_set_data(s, "fluid", 0)
		_:
			# "drop" (a dropper) or "launch" (a shooter): an item either way.
			var one := s.copy()
			one.count = 1
			if w.drops != null:
				var dir := Vector3(SIDES[int(d.facing)])
				var v := dir * DROP_SPEED + Vector3.UP * 1.2
				if how == "launch":
					v = dir * LAUNCH_SPEED + Vector3.UP * 2.5
				w.drops.spawn(one, front_point(w, c, d), v)
			_take_one(slots, i)
	d["fired"] = int(d.get("fired", 0)) + 1
	d["last"] = "%s %s%s" % [how, String(s.id), "" if ok else " (held)"]
	if w.host != null and w.host.has_method("world_items_changed"):
		w.host.world_items_changed()
	return ok


static func _take_one(slots: Array, i: int) -> void:
	var s: ItemStack = slots[i]
	s.count -= 1
	if s.count <= 0:
		slots[i] = null


static func _set_data(s: ItemStack, key: String, v: int) -> void:
	if v == 0:
		s.data.erase(key)
	else:
		s.data[key] = v


## A gun in a dispenser: one round out of its front, through the weapon system.
## The dispenser keeps a GunController of its own (made the first time, again
## when the gun in it changes), aimed by a muzzle node at its front.
static func _fire_gun(w, c: Vector3i, d: Dictionary, s: ItemStack) -> bool:
	var host = w.host
	if host == null or host.get("kit") == null or host.kit.library == null:
		return true      # a probe: no weapon system here; the slot logic only
	var node: Node3D = d.node
	if not is_instance_valid(node):
		return false
	var ctrl: GunController = d.get("gun_ctrl", null)
	if ctrl == null or not is_instance_valid(ctrl) or d.get("gun_for", null) != s:
		if ctrl != null and is_instance_valid(ctrl):
			ctrl.queue_free()
		var gi := CharacterSave.make_gun(s.data, host.kit.library)
		if gi == null:
			return false
		var muzzle := node.get_node_or_null("Muzzle") as Node3D
		if muzzle == null:
			muzzle = Node3D.new()
			muzzle.name = "Muzzle"
			node.add_child(muzzle)
		var dir := Vector3(SIDES[int(d.facing)])
		muzzle.position = dir * (w._stud * 0.5 + 0.06) + Vector3(0, w._plate * 1.5, 0)
		muzzle.basis = Basis.looking_at(dir, Vector3.UP)
		ctrl = GunController.new()
		ctrl.name = "Gun"
		ctrl.rng = RandomNumberGenerator.new()
		ctrl.rng.seed = hash(slot_key(c))
		ctrl.aim = muzzle
		if host.get("gun") != null:
			ctrl.on_structure_hit = host.gun.on_structure_hit
		var body := node.get_node_or_null("Body") as StaticBody3D
		if body != null:
			ctrl.exclude = [body.get_rid()]
		node.add_child(ctrl)
		# The gun itself rides in the dispenser, its barrel out of the front.
		muzzle.add_child(gi)
		gi.scale = Vector3.ONE * 0.6
		ctrl.equip(gi)
		if s.data.has("ammo"):
			ctrl.ammo = mini(int(s.data.ammo), ctrl.mag_size())
		d["gun_ctrl"] = ctrl
		d["gun_for"] = s
	if ctrl.is_reloading():
		return false
	var ok: bool = ctrl._round_out()
	s.data["ammo"] = ctrl.ammo
	return ok


## An arrow out of the front (WiringArrow), from the muzzle's height.
static func _shoot_arrow(w, c: Vector3i, d: Dictionary) -> bool:
	var host = w.host
	if host == null:
		return true      # a probe: the slot logic only
	var dir := Vector3(SIDES[int(d.facing)])
	var from: Vector3 = w.to_global(front_point(w, c, d) + Vector3(0, w._plate * 0.1, 0))
	var ex: Array[RID] = []
	var body := (d.node as Node3D).get_node_or_null("Body") as StaticBody3D if is_instance_valid(d.node) else null
	if body != null:
		ex.append(body.get_rid())
	var a := WiringArrow.shoot(host, from, w.to_global(front_point(w, c, d) + dir) - w.to_global(front_point(w, c, d)),
			w.drops, w, ex)
	d["arrow"] = a
	return true


## A grenade thrown out of the front: as far as THROW_STUDS or the first
## solid stud, onto the ground there.
static func _throw_grenade(w, c: Vector3i, d: Dictionary) -> bool:
	var f := SIDES[int(d.facing)]
	var mid := c + Vector3i(0, 1, 0)
	var land := mid + f
	for k in range(1, THROW_STUDS + 1):
		var n: Vector3i = mid + f * k
		if w._solid(n):
			break
		land = n
	var down := land
	for k in 60:
		if w._solid(down + Vector3i.DOWN):
			break
		down += Vector3i.DOWN
	var host = w.host
	d["grenade_to"] = down
	if host == null or host.get("kit") == null or host.kit.services == null:
		return true
	var start: Vector3 = w.to_global(front_point(w, c, d))
	var to: Vector3 = w.to_global(Vector3((down.x + 0.5) * w._stud, down.y * w._plate + 0.07, (down.z + 0.5) * w._stud))
	var g := Grenade.throw(host.kit.services, host.get("pawn"), start, to, host)
	g.damage = CombatScale.melee(1) * 2.5
	if "grenades_thrown" in host:
		host.grenades_thrown += 1
	return true


## A brick of fluid (`n` tiles) poured into the stud in front, its course.
static func _pour(w, c: Vector3i, d: Dictionary, fluid: int, n: int) -> bool:
	var fc: Vector3i = c + SIDES[int(d.facing)]
	if w._solid(fc):
		return false
	var cell := Vector3i(fc.x, floori(fc.y / 3.0), fc.z)
	d["poured"] = cell
	if w.host == null:
		return true
	BrickFluid.place(cell, fluid, BrickFluid.STILL, n)
	return true


# ---------------------------------------------------------------------------
# Sensors (section 28)

## The box a motion sensor watches (terrain frame, metres), or an empty AABB
## when the stud in front is solid: 1..reach studs out of its front, a stud to
## each side, from a little under its feet to a body's height over them.
static func motion_box(w, c: Vector3i, d: Dictionary) -> AABB:
	var f := SIDES[clampi(int(d.facing), 0, 3)]
	var reach := 0
	var r := int(MOTION_RANGES[clampi(int(d.setting), 0, MOTION_RANGES.size() - 1)])
	for k in range(1, r + 1):
		var n: Vector3i = c + f * k
		if w._solid(n + Vector3i(0, 1, 0)) or w._solid(n + Vector3i(0, 2, 0)):
			break
		reach = k
	if reach == 0:
		return AABB()
	var side := Vector3i(-f.z, 0, f.x)
	var a: Vector3i = c + f - side
	var b: Vector3i = c + f * reach + side
	var lo := Vector3(mini(a.x, b.x) * w._stud, c.y * w._plate - 0.45, mini(a.z, b.z) * w._stud)
	var hi := Vector3((maxi(a.x, b.x) + 1) * w._stud, c.y * w._plate + 1.2, (maxi(a.z, b.z) + 1) * w._stud)
	return AABB(lo, hi - lo)


## Is a body's feet in the box a motion sensor watches?
static func sees(w, c: Vector3i, d: Dictionary, bodies: Array) -> bool:
	var box := motion_box(w, c, d)
	if box.size == Vector3.ZERO:
		return false
	for p in bodies:
		if box.has_point(p):
			return true
	return false


## A light sensor's level: the sky light over it (0-15, how open it is to the
## sky) times the daylight (0 at night, 1 by day), rounded.
static func light_level(w, c: Vector3i) -> int:
	var box: AABB = w.device_box(c)
	var top := Vector3(box.get_center().x, box.end.y + 0.05, box.get_center().z)
	var sky := 15.0
	if light_fn.is_valid():
		sky = float(light_fn.call(top))
	elif w.host != null:
		sky = BrickTerrain.sky_light_at(top)
	var day := 1.0
	if day_fn.is_valid():
		day = float(day_fn.call())
	elif w.host != null and "_time" in w.host:
		var height := sin((float(w.host._time) - 0.25) * TAU)
		day = clampf(height * 2.5 + 0.4, 0.0, 1.0)
	return clampi(roundi(sky * day), 0, LEVEL)


## A fluid sensor's level: the water or lava in the stud in front, its course,
## 5 a tile; 0 for the other fluid when it watches one.
static func fluid_level(w, c: Vector3i, d: Dictionary) -> int:
	var fc: Vector3i = c + SIDES[clampi(int(d.facing), 0, 3)]
	var cell := Vector3i(fc.x, floori(fc.y / 3.0), fc.z)
	var info: Dictionary = {}
	if fluid_fn.is_valid():
		info = fluid_fn.call(cell)
	elif w.host != null:
		info = BrickFluid.cell_info(cell)
	var fl := int(info.get("fluid", 0))
	var want := clampi(int(d.setting), 0, 2)
	if fl == 0 or (want != 0 and fl != want):
		return 0
	return clampi(int(info.get("amount", 0)) * 5, 5, LEVEL)


## A counter's next output (MineWiring._gate_next): `back` and `right` are
## those sides on now.
static func counter_next(d: Dictionary, back: bool, right: bool) -> int:
	if right and int(d.get("rprev", 0)) == 0:
		d["count"] = 0
	d["rprev"] = 1 if right else 0
	if back and int(d.prev) == 0 and not right:
		d["count"] = int(d.get("count", 0)) + 1
		if int(d.count) >= maxi(int(d.setting), 2):
			d["count"] = 0
			d.timer = COUNTER_PULSE
	d.prev = 1 if back else 0
	var out := 0
	if int(d.timer) > 0:
		out = LEVEL
		d.timer = int(d.timer) - 1
	return out


## The counter's next N on RMB: 2..10, round again.
static func next_count(n: int) -> int:
	return 2 if n >= 10 or n < 2 else n + 1


# ---------------------------------------------------------------------------
# The look

static func build(w, root: Node3D, k: String, box: AABB, facing: int) -> void:
	var stud: float = w._stud
	var plate: float = w._plate
	if k != "release":
		var body := StaticBody3D.new()
		body.name = "Body"
		body.collision_layer = Layers.WORLD
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = box.size
		shape.shape = bs
		shape.position = Vector3(0, box.size.y * 0.5, 0)
		body.add_child(shape)
		root.add_child(body)
	match k:
		"dispenser", "dropper":
			var turn := Node3D.new()
			turn.name = "Turn"
			turn.rotation.y = _yaw(facing)
			root.add_child(turn)
			var stone := _mat(Color(0.42, 0.43, 0.46), 0.65)
			_box(turn, Vector3(stud * 0.97, plate * 2.95, stud * 0.97), Vector3(0, plate * 1.475, 0), stone)
			var dark := _mat(Color(0.06, 0.06, 0.07), 0.8)
			if k == "dispenser":
				# A round mouth with a rim (a barrel's end).
				var rim := MeshInstance3D.new()
				var cyl := CylinderMesh.new()
				cyl.top_radius = stud * 0.3
				cyl.bottom_radius = stud * 0.3
				cyl.height = stud * 0.06
				rim.mesh = cyl
				rim.material_override = _mat(Color(0.25, 0.25, 0.27), 0.4)
				rim.rotation.z = PI * 0.5
				rim.position = Vector3(stud * 0.49, plate * 1.5, 0)
				turn.add_child(rim)
				var mouth := MeshInstance3D.new()
				var cyl2 := CylinderMesh.new()
				cyl2.top_radius = stud * 0.19
				cyl2.bottom_radius = stud * 0.19
				cyl2.height = stud * 0.08
				mouth.mesh = cyl2
				mouth.material_override = dark
				mouth.rotation.z = PI * 0.5
				mouth.position = Vector3(stud * 0.5, plate * 1.5, 0)
				turn.add_child(mouth)
			else:
				# A square funnel mouth.
				_box(turn, Vector3(stud * 0.06, plate * 1.6, stud * 0.6), Vector3(stud * 0.49, plate * 1.5, 0),
						_mat(Color(0.25, 0.25, 0.27), 0.4))
				_box(turn, Vector3(stud * 0.08, plate * 1.0, stud * 0.38), Vector3(stud * 0.5, plate * 1.5, 0), dark)
			# A light on top that blinks when it fires.
			var glow := _mat(Color(0.95, 0.5, 0.15), 0.3)
			glow.emission_enabled = true
			glow.emission = Color(1.0, 0.45, 0.1)
			glow.emission_energy_multiplier = 0.0
			var g := _box(turn, Vector3(stud * 0.24, plate * 0.3, stud * 0.24), Vector3(-stud * 0.2, plate * 3.05, 0), glow)
			g.name = "Glow"
		"release":
			# The brick is the ground's (its yellow cells); the device draws a
			# dark band with a wire stripe round it, and a ghost while let go.
			var band := _mat(Color(0.1, 0.1, 0.11), 0.6)
			_box(root, Vector3(stud * 1.012, plate * 0.7, stud * 1.012), Vector3(0, plate * 1.5, 0), band)
			var stripe := _mat(Color(0.42, 0.24, 0.13), 0.4)
			stripe.emission_enabled = true
			stripe.emission = Color(1.0, 0.32, 0.12)
			stripe.emission_energy_multiplier = 0.0
			var st := _box(root, Vector3(stud * 1.02, plate * 0.18, stud * 1.02), Vector3(0, plate * 1.5, 0), stripe)
			st.name = "Stripe"
			var ghost := _mat(Color(0.95, 0.75, 0.1, 0.18), 0.5)
			ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var gh := _box(root, box.size * 0.98, Vector3(0, box.size.y * 0.5, 0), ghost)
			gh.name = "Ghost"
			gh.visible = false
		"motion", "fluidsense":
			var turn := Node3D.new()
			turn.name = "Turn"
			turn.rotation.y = _yaw(facing)
			root.add_child(turn)
			var shell_col := Color(0.32, 0.34, 0.38) if k == "motion" else Color(0.3, 0.36, 0.42)
			_box(turn, Vector3(stud * 0.96, plate * 2.9, stud * 0.96), Vector3(0, plate * 1.45, 0), _mat(shell_col, 0.6))
			var eye_col := Color(0.9, 0.12, 0.08) if k == "motion" else Color(0.15, 0.45, 1.0)
			var eye := _mat(eye_col.darkened(0.5), 0.2)
			eye.emission_enabled = true
			eye.emission = eye_col
			eye.emission_energy_multiplier = 0.0
			if k == "motion":
				# A round dark lens with a red light in it.
				var lens := MeshInstance3D.new()
				var cyl := CylinderMesh.new()
				cyl.top_radius = stud * 0.26
				cyl.bottom_radius = stud * 0.26
				cyl.height = stud * 0.05
				lens.mesh = cyl
				lens.material_override = _mat(Color(0.05, 0.05, 0.06), 0.15)
				lens.rotation.z = PI * 0.5
				lens.position = Vector3(stud * 0.49, plate * 1.6, 0)
				turn.add_child(lens)
				var dot := _box(turn, Vector3(stud * 0.04, stud * 0.12, stud * 0.12), Vector3(stud * 0.52, plate * 1.6, 0), eye)
				dot.name = "Eye"
			else:
				# A window low on its front, blue while fluid is there.
				var win := _box(turn, Vector3(stud * 0.05, plate * 1.2, stud * 0.6), Vector3(stud * 0.49, plate * 1.0, 0), eye)
				win.name = "Eye"
		"light":
			_box(root, Vector3(stud * 0.96, plate * 0.75, stud * 0.96), Vector3(0, plate * 0.375, 0), _mat(Color(0.22, 0.2, 0.18), 0.6))
			var panel := _mat(Color(0.75, 0.62, 0.25), 0.2)
			panel.emission_enabled = true
			panel.emission = Color(1.0, 0.8, 0.3)
			panel.emission_energy_multiplier = 0.0
			var pn := _box(root, Vector3(stud * 0.8, plate * 0.12, stud * 0.8), Vector3(0, plate * 0.8, 0), panel)
			pn.name = "Panel"
		"alarm":
			var base := _mat(Color(0.2, 0.2, 0.22), 0.6)
			_box(root, Vector3(stud * 0.95, plate * 1.6, stud * 0.95), Vector3(0, plate * 0.8, 0), base)
			var red := _mat(Color(0.75, 0.08, 0.06, 0.85), 0.25)
			red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			red.emission_enabled = true
			red.emission = Color(1.0, 0.1, 0.05)
			red.emission_energy_multiplier = 0.0
			var dome := MeshInstance3D.new()
			dome.name = "Dome"
			var cyl3 := CylinderMesh.new()
			cyl3.top_radius = stud * 0.3
			cyl3.bottom_radius = stud * 0.38
			cyl3.height = plate * 1.3
			dome.mesh = cyl3
			dome.material_override = red
			dome.position = Vector3(0, plate * 2.25, 0)
			root.add_child(dome)
			# The turning light: a bright bar inside the dome, an OmniLight.
			var spin := Node3D.new()
			spin.name = "Spin"
			spin.position = Vector3(0, plate * 2.25, 0)
			root.add_child(spin)
			var bar := _mat(Color(1.0, 0.85, 0.8), 0.2)
			bar.emission_enabled = true
			bar.emission = Color(1.0, 0.3, 0.2)
			bar.emission_energy_multiplier = 0.0
			var b := _box(spin, Vector3(stud * 0.5, plate * 0.4, stud * 0.08), Vector3.ZERO, bar)
			b.name = "Bar"
			var light := OmniLight3D.new()
			light.name = "Light"
			light.light_color = Color(1.0, 0.15, 0.08)
			light.omni_range = 7.0
			light.light_energy = 2.0
			light.shadow_enabled = false
			light.position = Vector3(stud * 0.3, 0, 0)
			light.visible = false
			spin.add_child(light)
			var snd := AudioStreamPlayer3D.new()
			snd.name = "Siren"
			snd.stream = siren()
			snd.unit_size = 10.0
			snd.max_distance = 70.0
			snd.volume_db = -6.0
			root.add_child(snd)


## A kit device's look follows its state.
static func show(w, _c: Vector3i, d: Dictionary, node: Node3D) -> void:
	match kind(d.item):
		"dispenser", "dropper":
			var turn := node.get_node_or_null("Turn") as Node3D
			if turn != null:
				turn.rotation.y = _yaw(int(d.facing))
			var mz := node.get_node_or_null("Muzzle") as Node3D
			if mz != null:
				var dir := Vector3(SIDES[int(d.facing)])
				mz.position = dir * (w._stud * 0.5 + 0.06) + Vector3(0, w._plate * 1.5, 0)
				mz.basis = Basis.looking_at(dir, Vector3.UP)
			var g := node.get_node_or_null("Turn/Glow") as MeshInstance3D
			if g != null:
				w.set_glow(g, 3.0 if int(d.prev) > 0 else 0.0)
		"release":
			var gh := node.get_node_or_null("Ghost") as Node3D
			if gh != null:
				gh.visible = bool(d.on)
			var st := node.get_node_or_null("Stripe") as MeshInstance3D
			if st != null:
				w.set_glow(st, 2.5 if bool(d.on) else 0.0)
		"motion", "fluidsense":
			var turn := node.get_node_or_null("Turn") as Node3D
			if turn != null:
				turn.rotation.y = _yaw(int(d.facing))
			var e := node.get_node_or_null("Turn/Eye") as MeshInstance3D
			if e != null:
				w.set_glow(e, 3.0 * int(d.out) / float(LEVEL))
		"light":
			var pn := node.get_node_or_null("Panel") as MeshInstance3D
			if pn != null:
				w.set_colour(pn, Color(0.75, 0.62, 0.25) if int(d.setting) == 0 else Color(0.25, 0.35, 0.75))
				w.set_glow(pn, 2.5 * int(d.out) / float(LEVEL))
		"alarm":
			var on := bool(d.on)
			var dome := node.get_node_or_null("Dome") as MeshInstance3D
			if dome != null:
				w.set_glow(dome, 2.0 if on else 0.0)
			var bar := node.get_node_or_null("Spin/Bar") as MeshInstance3D
			if bar != null:
				w.set_glow(bar, 4.0 if on else 0.0)
			var light := node.get_node_or_null("Spin/Light") as OmniLight3D
			if light != null:
				light.visible = on
			var spin := node.get_node_or_null("Spin") as Node3D
			var snd := node.get_node_or_null("Siren") as AudioStreamPlayer3D
			if on and not d.has("tween") and spin != null and spin.is_inside_tree():
				var tw := spin.create_tween().set_loops()
				tw.tween_property(spin, "rotation:y", TAU, 0.8).from(0.0)
				d["tween"] = tw
				if snd != null:
					snd.play()
			elif not on and d.has("tween"):
				var tw2: Tween = d.tween
				if tw2 != null and tw2.is_valid():
					tw2.kill()
				d.erase("tween")
				if snd != null:
					snd.stop()


static func readout(w, c: Vector3i, d: Dictionary) -> Array[String]:
	var out: Array[String] = []
	match kind(d.item):
		"dispenser", "dropper":
			var n := 0
			for s in d.get("slots", []):
				if s != null:
					n += (s as ItemStack).count
			out.append("power %d" % _power_not_front(w, c, d))
			out.append("%d items (RMB)" % n)
			if d.has("last"):
				out.append("last: %s" % d.last)
		"release":
			out.append("let go" if bool(d.on) else "holding")
			out.append("power %d" % w.power_in(c))
		"alarm":
			out.append("sounding" if bool(d.on) else "quiet")
			if d.has("called"):
				out.append("called %d" % int(d.called))
		"motion":
			out.append("sees something" if int(d.out) > 0 else "sees nothing")
			out.append("reach %d studs (RMB)" % int(MOTION_RANGES[clampi(int(d.setting), 0, MOTION_RANGES.size() - 1)]))
		"light":
			out.append("night sensor (RMB)" if int(d.setting) == 1 else "day sensor (RMB)")
		"fluidsense":
			out.append("watches %s (RMB)" % FLUID_NAMES[clampi(int(d.setting), 0, 2)])
	if d.item == &"counter":
		out.append("count %d of %d (RMB)" % [int(d.get("count", 0)), int(d.setting)])
	return out


# ---------------------------------------------------------------------------
# Saving

static func save_extra(d: Dictionary, e: Dictionary) -> void:
	if has_slots(d.item):
		e["slots"] = Inventory._save_array(d.get("slots", []))
	if d.item == &"counter":
		e["count"] = int(d.get("count", 0))


static func restore_extra(d: Dictionary, e: Dictionary) -> void:
	if has_slots(d.item) and e.has("slots"):
		var slots := Inventory._empty(SLOTS)
		Inventory._load_array(slots, e.slots)
		d["slots"] = slots
	if is_terrain(d.item) and bool(d.on):
		d.timer = RELEASE_HOLD
	if d.item == &"counter":
		d["count"] = int(e.get("count", 0))


# ---------------------------------------------------------------------------
# Helpers

static func _box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


static func _mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


static func _yaw(f: int) -> float:
	return [0.0, PI, -PI * 0.5, PI * 0.5][clampi(f, 0, 3)]


## The alarm's siren: two tones, 0.45 s each, a soft square wave, looped.
## Synthesised once (the project ships no audio files: DisasterSounds).
static func siren() -> AudioStreamWAV:
	if _siren != null:
		return _siren
	var rate := 22050
	var half := int(rate * 0.45)
	var data := PackedByteArray()
	data.resize(half * 2 * 2)
	var ph := 0.0
	for i in half * 2:
		var hz := 880.0 if i < half else 660.0
		ph += hz / rate
		var v := clampf(sin(TAU * ph) * 3.0, -1.0, 1.0) * 0.35
		# Short fades at each tone's ends, no clicks.
		var k := i % half
		v *= clampf(minf(k, half - k) / 200.0, 0.0, 1.0)
		data.encode_s16(i * 2, int(v * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = rate
	s.stereo = false
	s.data = data
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = half * 2
	_siren = s
	return s
