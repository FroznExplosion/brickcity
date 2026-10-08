class_name MechLayers
extends Node
## How a mech is killed (Docs/AIRoster.md 4.2, 4.6, 4.7): in layers.
##
##     shield -> armour -> health -> doomed     (the mech's HealthPool, top first)
##     + the HATCH's own armour, over the PILOT
##     + the CELL DOOR's own armour, over the POWER CELL
##
##   * The shield is first; it comes back after a pause -- until the mech is doomed.
##   * Armour is one pool, hit anywhere. A hit ON the hatch or the cell door also
##     wears that door, so either can come off before the armour is gone.
##   * Armour gone with a door still on: that door drops to DOOR_LOW.
##   * Hatch off: the pilot can be shot. Killed, the mech goes to AUTO (it fights
##     on, weaker). Cell door off: the power cell can be shot, for CELL_CRIT; gone,
##     the mech blows up, and the pilot with it.
##   * An exposed pilot or cell is not covered by the shield, back or not.
##   * Armour gone and health drained: DOOMED -- the shield dies at once, a few
##     hits finish it, and another mech's melee finishes it outright.
##   * A mech's melee goes through the shield.
##
## WHO is shooting matters (4.6), by the hit's SCALE (DamagePacket.scale):
##   mech, anti_mech   full
##   explosive         half
##   person            nothing -- but a tenth with the element the top layer is
##                     weak to (plasma on a shield, corrosive on bare armour), and
##                     in full on an exposed pilot or power cell
##
## It ends in a blast (4.7): SELF_DESTRUCT when its cell goes or a pilot of
## another side tries to get in; NUKE, for a mech with the Nuker mod, when it is
## doomed -- unless it is finished first, or its cell is destroyed.
##
## The pools are the HealthPool's layers, so bars, regen and everything that
## already hurts a mech keep working; this node is the rules on top. A hit routed
## through DamageSystem comes here (take_packet) because the body carries META.

const META := &"mech_layers"
const SHIELD := &"shield"
const ARMOR := &"armor"
const HEALTH := &"health"
const DOOMED := &"doomed"
## Scale factors on the hull, and for a matched element from a person's gun.
const SCALE := {&"mech": 1.0, &"anti_mech": 1.0, &"explosive": 0.5, &"person": 0.0}
const ELEMENT_MATCH := 0.1
## A door still on when the armour goes is left with this much.
const DOOR_LOW := 40.0
## The shield comes back after this long untouched, over this long.
const SHIELD_DELAY := 5.0
const SHIELD_SECONDS := 6.0
## Hit zones on the torso: within this of the hatch, or of the cell door.
const ZONE_RADIUS := 1.15
const CELL_Y := Mech.COURSE * 7.0
## A pilot nobody put in: an AI's, with this much health.
const PILOT_HP := 100.0
## The blasts: [fuse seconds, reach, damage to a mech]. People in reach die.
const SELF_DESTRUCT := [2.0, 8.0, 1000.0]
const NUKE := [4.0, 30.0, 2500.0]
## Defaults: the medium class (Roster's R_MECH), for a mech nobody gave a recipe.
const MEDIUM := {"shield": 1000.0, "armor": 1500.0, "health": 1250.0, "hatch": 350.0, "cell_door": 250.0,
		"hatch_side": "front", "doomed": 250.0, "power_cell": 300.0, "cell_crit": 3.0}

signal shield_broken
signal armour_broken
signal hatch_blown
signal cell_door_blown
signal pilot_killed
signal doomed_entered
signal fuse_lit(kind: String, seconds: float)
signal exploded(kind: String, at: Vector3)
signal destroyed(cause: String)

var mech: Mech
var pool: HealthPool
var hatch_side := "front"
var hatch := 350.0
var cell_door := 250.0
var power_cell := 300.0
var cell_crit := 3.0
var hatch_off := false
var cell_door_off := false
var doomed := false
var dead := false
## Somebody is in it. Killed (or thrown clear), it runs on AUTO.
var piloted := true
var auto := false
var pilot: Pawn
var pilot_hp := PILOT_HP
## The Nuker mod (Roster).
var nuker := false
## What it blows up as, and when; "" for no fuse lit.
var fuse_kind := ""
var fuse_at := INF
## What killed it: "doomed", "cell", "finisher", "self_destruct", "nuke".
var cause := ""
## What the last blast hurt, for gates: [[target, damage], ...].
var blast_hits: Array = []
## Who is there to be caught in its blast (the owner's AIServices); null in a
## probe with nobody about.
var services: AIServices
var _doom_block := false
var _now := 0.0


## Give `m` its layers: `spec` is a recipe's derived.mech (Roster), or {} for the
## medium class. Replaces the mech's one pool of health with the four.
static func attach(m: Mech, spec: Dictionary = {}) -> MechLayers:
	var s: Dictionary = MEDIUM.duplicate()
	s.merge(spec, true)
	var ml := MechLayers.new()
	ml.name = "MechLayers"
	ml.mech = m
	ml.pool = m.health
	ml.hatch_side = str(s.hatch_side)
	ml.hatch = float(s.hatch)
	ml.cell_door = float(s.cell_door)
	ml.power_cell = float(s.power_cell)
	ml.cell_crit = float(s.cell_crit)
	var rows := [[SHIELD, float(s.shield), EnemyProfiles.COLOURS[EnemyProfiles.SHIELD]],
			[ARMOR, float(s.armor), EnemyProfiles.COLOURS[EnemyProfiles.ARMOR]],
			[HEALTH, float(s.health), EnemyProfiles.COLOURS[EnemyProfiles.FLESH]],
			[DOOMED, float(s.doomed), Color(1.0, 0.2, 0.1)]]
	var layers: Array[DefenseLayer] = []
	for row in rows:
		var l := DefenseLayer.new()
		l.layer_type = row[0]
		l.max_value = row[1]
		l.display_color = row[2]
		if row[0] == SHIELD:
			l.regen_delay = SHIELD_DELAY
			l.regen_rate = l.max_value / SHIELD_SECONDS
		layers.append(l)
	ml.pool.layer_configs = layers
	ml.pool.vital_layer_index = -1
	ml.pool.impact_carries_over = true
	ml.pool.reset()
	ml.pool.damage_filter = ml._filter
	ml.pool.layer_depleted.connect(ml._on_layer_depleted)
	ml.pool.died.connect(ml._on_died)
	m.body.set_meta(META, ml)
	m.body.add_child(ml)
	return ml


## The layers of the mech whose body this is, or null.
static func of(body: Node) -> MechLayers:
	if body == null or not body.has_meta(META):
		return null
	var v: Variant = body.get_meta(META)
	return v as MechLayers if typeof(v) == TYPE_OBJECT and is_instance_valid(v) else null


func value(type: StringName) -> float:
	for i in pool.layer_count():
		if pool.layer_type_at(i) == type:
			return pool.get_layer_value(i)
	return 0.0


func shield_up() -> bool:
	return value(SHIELD) > 0.0


func armour_gone() -> bool:
	return value(ARMOR) <= 0.0


## Where the hatch and the cell door are, in the world: the hatch on its side of
## the torso at the cockpit's height, the cell door on the other side, lower.
func hatch_point() -> Vector3:
	return _torso_point(-1.0 if hatch_side == "front" else 1.0, Mech.COCKPIT_Y)


func cell_point() -> Vector3:
	return _torso_point(1.0 if hatch_side == "front" else -1.0, CELL_Y)


func _torso_point(z_sign: float, up: float) -> Vector3:
	var yaw := mech.motor.torso_yaw if mech.motor != null else 0.0
	var back := Basis(Vector3.UP, yaw).z   # +z is the torso's back
	return mech.feet() + Vector3.UP * up + back * z_sign * Mech.RADIUS * 0.85


## Which part a hit at `point` is on: &"hatch", &"cell", or &"" for the hull.
func zone_at(point: Vector3) -> StringName:
	if point.distance_to(hatch_point()) <= ZONE_RADIUS:
		return &"hatch"
	if point.distance_to(cell_point()) <= ZONE_RADIUS:
		return &"cell"
	return &""


## A hit through DamageSystem.
func take_packet(packet: DamagePacket) -> DamageSystem.DamageResult:
	var res := DamageSystem.DamageResult.new()
	var before := _everything()
	var element := packet.element.id if packet.element != null and packet.element_ratio > 0.0 else &""
	var crit := maxf(1.0, packet.crit_multiplier) if packet.crit else 1.0
	take(packet.amount, scale_of(packet), zone_at(packet.hit_position), element, crit)
	res.dealt = before - _everything()
	res.killed = dead
	if packet.element != null:
		res.element_color = packet.element.color
	return res


## A hit's scale: what the packet says, or -- unsaid -- its gun's (ordnance is
## explosive), or a person's.
static func scale_of(packet: DamagePacket) -> StringName:
	if packet.scale != &"":
		return packet.scale
	var g := packet.source as GunController
	if g != null:
		if g.damage_scale != &"":
			return g.damage_scale
		if g.gun != null and g.gun.weapon_class != null and g.gun.weapon_class.is_ordnance:
			return &"explosive"
	return &"person"


## `amount` of damage of `scale` on `zone`. Returns what it took off the mech.
func take(amount: float, scale: StringName, zone: StringName = &"", element: StringName = &"", crit := 1.0) -> float:
	if dead or amount <= 0.0:
		return 0.0
	var before := _everything()
	# An exposed pilot, an exposed cell: anybody's gun, and no shield over them.
	if zone == &"hatch" and hatch_off and piloted:
		_hurt_pilot(amount * crit)
		return before - _everything()
	if zone == &"cell" and cell_door_off:
		power_cell = maxf(0.0, power_cell - amount * cell_crit)
		if power_cell <= 0.0:
			_cell_gone()
		return before - _everything()
	var hull := amount * _hull_factor(scale, element)
	if hull <= 0.0:
		return 0.0
	var shield_was := value(SHIELD)
	var pool_was := pool.total_current()
	pool.apply_impact(hull, &"")
	_doom_block = false
	if shield_was > 0.0 and value(SHIELD) <= 0.0:
		shield_broken.emit()
	# What got past the shield on a door wore that door too -- into the armour,
	# or, with the armour gone, into what is under it.
	var past_shield := (pool_was - pool.total_current()) - (shield_was - value(SHIELD))
	if past_shield > 0.0:
		_wear_door(zone, past_shield)
	return before - _everything()


## Another mech's fist: through the shield, into armour, health and what is left
## -- and a doomed mech is finished by it. Returns true if this blow killed it.
func melee(amount: float, zone: StringName = &"") -> bool:
	if dead:
		return false
	if doomed:
		_die("finisher")
		return true
	if zone == &"hatch" and hatch_off and piloted:
		_hurt_pilot(amount)
		return false
	var left := amount
	for type in [ARMOR, HEALTH]:
		var have := value(type)
		if have <= 0.0 or left <= 0.0:
			continue
		pool.apply_to_layer_type(minf(left, have), type, &"")
		var took := have - value(type)
		left -= took
		_wear_door(zone, took)
		if doomed:
			break
	_doom_block = false
	return dead


## A pilot of `p_team` tries to get in. Its own side's may; anybody else's sets
## it off (R14). Returns true if they may get in.
func try_enter(p_team: int) -> bool:
	if dead:
		return false
	if p_team == mech.team:
		return true
	light_fuse("self_destruct")
	return false


## Start the blast `kind` ("self_destruct" or "nuke"), if none is running.
func light_fuse(kind: String) -> void:
	if dead or fuse_kind != "":
		return
	fuse_kind = kind
	var spec: Array = NUKE if kind == "nuke" else SELF_DESTRUCT
	fuse_at = _now + float(spec[0])
	fuse_lit.emit(kind, float(spec[0]))


func _physics_process(delta: float) -> void:
	_now += delta
	# The block on the dooming hit's spill lasts that hit, and no longer.
	_doom_block = false
	if not dead and _now >= fuse_at:
		_die(fuse_kind)


func _everything() -> float:
	return pool.total_current() + maxf(hatch, 0.0) + maxf(cell_door, 0.0) + power_cell + (pilot_hp if piloted else 0.0)


func _hull_factor(scale: StringName, element: StringName) -> float:
	var f := float(SCALE.get(scale, 0.0))
	if scale == &"person" and element != &"":
		# The element the top layer is weak to, and only on that layer.
		if (element == Elements.PLASMA and shield_up()) \
				or (element == Elements.CORROSIVE and not shield_up() and not armour_gone()):
			f = ELEMENT_MATCH
	return f


func _wear_door(zone: StringName, amount: float) -> void:
	if zone == &"hatch" and not hatch_off:
		hatch -= amount
		if hatch <= 0.0:
			_hatch_off()
	elif zone == &"cell" and not cell_door_off:
		cell_door -= amount
		if cell_door <= 0.0:
			_cell_door_off()


## Blow the hatch off outright: a rider's charge (rodeo), or enough mech melee.
func blow_hatch() -> void:
	if not hatch_off and not dead:
		_hatch_off()


func _hatch_off() -> void:
	hatch = 0.0
	hatch_off = true
	hatch_blown.emit()


func _cell_door_off() -> void:
	cell_door = 0.0
	cell_door_off = true
	cell_door_blown.emit()


func _hurt_pilot(amount: float) -> void:
	if pilot != null and is_instance_valid(pilot) and pilot.health != null:
		pilot.health.apply_impact(amount, &"")
		if not pilot.health.is_dead():
			return
	else:
		pilot_hp -= amount
		if pilot_hp > 0.0:
			return
	pilot_hp = 0.0
	piloted = false
	auto = true
	pilot_killed.emit()


func _cell_gone() -> void:
	# No nuke from a mech whose cell is gone: it just blows up, now.
	fuse_kind = ""
	fuse_at = INF
	_die("cell")


## The pool tells each layer what it may take: nothing spills from the health
## into the doomed pool on the hit that dooms it -- doomed is a state, not a
## number a big enough hit skips.
func _filter(amount: float, layer_index: int, _element: StringName) -> float:
	if _doom_block and pool.layer_type_at(layer_index) == DOOMED:
		return 0.0
	return amount


func _on_layer_depleted(type: StringName) -> void:
	if type == ARMOR:
		if not hatch_off:
			hatch = minf(hatch, DOOR_LOW)
		if not cell_door_off:
			cell_door = minf(cell_door, DOOR_LOW)
		armour_broken.emit()
	elif type == HEALTH and not doomed:
		doomed = true
		_doom_block = true
		# The shield dies with it, and does not come back.
		for i in pool.layer_count():
			if pool.layer_type_at(i) == SHIELD:
				pool.layer_configs[i].regen_rate = 0.0
		if value(SHIELD) > 0.0:
			pool.apply_to_layer_type(value(SHIELD), SHIELD, &"")
		doomed_entered.emit()
		if nuker:
			# The pilot is thrown clear, and the count starts.
			piloted = false
			light_fuse("nuke")


func _on_died() -> void:
	if not dead:
		_die("doomed")


func _die(why: String) -> void:
	if dead:
		return
	dead = true
	cause = why
	_doom_block = false
	var blast := ""
	match why:
		"nuke": blast = "nuke"
		"self_destruct", "cell": blast = "self_destruct"
	fuse_kind = ""
	fuse_at = INF
	if piloted and why == "cell":
		piloted = false
	if not pool.is_dead():
		for i in pool.layer_count():
			if pool.get_layer_value(i) > 0.0:
				pool.apply_to_layer_type(pool.get_layer_value(i), pool.layer_type_at(i), &"")
	if blast != "":
		_blast(blast)
	destroyed.emit(why)


## The blast: every mech in reach takes it on its hull (less with distance), and
## every body in reach is killed, unless bricks stand between.
func _blast(kind: String) -> void:
	var spec: Array = NUKE if kind == "nuke" else SELF_DESTRUCT
	var reach := float(spec[1])
	var at := mech.feet() + Vector3.UP * Mech.HEIGHT * 0.5
	blast_hits = []
	for n in get_tree().get_nodes_in_group(&"mech_layers"):
		var other := n as MechLayers
		if other == null or other == self or other.dead:
			continue
		var d := (other.mech.feet() + Vector3.UP * Mech.HEIGHT * 0.5).distance_to(at)
		if d < reach:
			var dmg := float(spec[2]) * (1.0 - d / reach)
			blast_hits.append([other, other.take(dmg, &"mech")])
	if services != null:
		for p in services.pawns:
			if not is_instance_valid(p) or p.health == null or p.health.is_dead():
				continue
			if p.chest().distance_to(at) < reach and services.ai_world.line_clear(at, p.chest()):
				p.health.apply_impact(1e9, &"")
				blast_hits.append([p, 1e9])
		services.noise(at, reach * 4.0, null)
	exploded.emit(kind, at)


func _enter_tree() -> void:
	add_to_group(&"mech_layers")
