class_name MechPods
extends Node
## A mech's two pods (Docs/ModularParts.md section 4, "Pods"; stage 7): pod_L and pod_R, on top
## of the chassis, apart from the arms. Passives change the layers while fitted; actives are
## used, then cool down. Two of one kind stack by adding.
##
##   missiles, laser, grenade arm   a gun of the pod's weapon class of its own, fired along
##                                   where the mech aims, `shots` rounds
##   strike arm                      the nearest enemy mech in reach takes `damage`
##   shield booster                  the shield layer's size, up by `shield`
##   brace plate                   the armour layer's, up by `armor` (a shield over one side
##                                   wants hits to say where they came from; they do not yet)
##
##     var pods := MechPods.attach(mech, library, rng)
##     pods.fit(0, PodGenerator.generate(seed))
##     pods.use(0)

signal changed
signal used(slot: int, kind: StringName)

const SLOTS := 2
## The layers a passive adds to (MechLayers' order: shield, armour, health, doomed).
const LAYER_OF := {"shield": 0, "armor": 1}

var mech: Mech
var library: GunPartLibrary
var rng: RandomNumberGenerator
var on_structure_hit: Callable
var slots: Array = [null, null]
## Seconds until each slot can be used again.
var cool: Array[float] = [0.0, 0.0]
var _guns: Array = [null, null]       # GunController per active weapon pod
var _bursts: Array[int] = [0, 0]      # rounds left to fire
var _base := {}                       # layer index -> its size before passives


static func attach(m: Mech, lib: GunPartLibrary = null, p_rng: RandomNumberGenerator = null) -> MechPods:
	var p := MechPods.new()
	p.name = "MechPods"
	p.mech = m
	p.library = lib
	p.rng = p_rng if p_rng != null else RandomNumberGenerator.new()
	m.body.add_child(p)
	return p


static func of(m: Mech) -> MechPods:
	return m.body.get_node_or_null(^"MechPods") as MechPods if m != null and m.body != null else null


## Fit `pod` in `slot` (0 left, 1 right); what was there comes back (or null).
func fit(slot: int, pod: PodGenerator.Result) -> PodGenerator.Result:
	if slot < 0 or slot >= SLOTS:
		return pod
	var was: PodGenerator.Result = slots[slot]
	slots[slot] = pod
	cool[slot] = 0.0
	_bursts[slot] = 0
	_make_gun(slot)
	_apply_passives()
	changed.emit()
	return was


func take_off(slot: int) -> PodGenerator.Result:
	return fit(slot, null)


## Use the pod in `slot`: true if it went off (an active one, cooled down).
func use(slot: int) -> bool:
	var pod: PodGenerator.Result = slots[slot] if slot >= 0 and slot < SLOTS else null
	if pod == null or not pod.is_active() or cool[slot] > 0.0 or mech.layers == null or mech.layers.dead:
		return false
	if pod.kind == &"melee_arm":
		var target := _nearest_enemy(float(pod.stats.get("reach", 7.0)))
		if target == null:
			return false
		target.layers.melee(float(pod.stats.damage), target.layers.zone_at(target.feet()
				+ target.motor.up * target.cockpit_y))
	elif _guns[slot] != null:
		_bursts[slot] = int(pod.stats.get("shots", 1))
	else:
		return false
	cool[slot] = float(pod.stats.get("cooldown", 5.0))
	used.emit(slot, pod.kind)
	return true


func _physics_process(delta: float) -> void:
	for i in SLOTS:
		if cool[i] > 0.0:
			cool[i] = maxf(cool[i] - delta, 0.0)
		var g: GunController = _guns[i]
		if g == null:
			continue
		g.set_trigger(_bursts[i] > 0)


## A weapon pod's gun: its own controller, aimed where the mech's arm aims.
func _make_gun(slot: int) -> void:
	if _guns[slot] != null:
		(_guns[slot] as Node).queue_free()
		_guns[slot] = null
	var pod: PodGenerator.Result = slots[slot]
	if pod == null or not PodGenerator.KINDS[pod.kind].has("weapon") or library == null:
		return
	var res := GunGenerator.generate(library, pod.seed, WeaponClass.builtin(PodGenerator.KINDS[pod.kind].weapon),
			pod.tier)
	if res == null:
		return
	var gi := GunInstance.from_result(res)
	gi.visible = false   # the pod body is what is seen
	var g := GunController.new()
	g.name = "Pod%d" % slot
	g.aim = mech.muzzle
	g.rng = rng
	g.exclude = [mech.body.get_rid()] as Array[RID]
	g.damage_scale = &"mech"
	g.damage_mult = Mech.GUN_MULT * float(pod.stats.get("power", 1.0))
	if on_structure_hit.is_valid():
		g.on_structure_hit = on_structure_hit
	mech.body.add_child(g)
	mech.arm.add_child(gi)
	g.equip(gi)
	g.fired.connect(func(_i: Dictionary) -> void:
		_bursts[slot] = maxi(_bursts[slot] - 1, 0))
	_guns[slot] = g


## The layers' sizes: their own, plus what the fitted passives add.
func _apply_passives() -> void:
	var pool := mech.health
	if pool == null:
		return
	var add := {}
	for pod: PodGenerator.Result in slots:
		if pod == null or pod.is_active():
			continue
		for stat in LAYER_OF:
			if pod.stats.has(stat):
				add[LAYER_OF[stat]] = float(add.get(LAYER_OF[stat], 0.0)) + float(pod.stats[stat])
	for i in pool.layer_configs.size():
		var l: DefenseLayer = pool.layer_configs[i]
		if not _base.has(i):
			_base[i] = l.max_value
		var size: float = _base[i] * (1.0 + float(add.get(i, 0.0)))
		var frac := pool.get_layer_fraction(i) if i < pool.layer_count() else 1.0
		l.max_value = size
		if l.layer_type == MechLayers.SHIELD:
			l.regen_rate = size / MechLayers.SHIELD_SECONDS
		if i < pool._current.size():
			pool._current[i] = size * frac   # as full as it was


## The layers were made again (a class from a chassis): what the pods add starts over.
func layers_changed() -> void:
	_base.clear()
	_apply_passives()


func _nearest_enemy(reach: float) -> Mech:
	var best: Mech = null
	var best_d := reach
	for n in mech.get_tree().get_nodes_in_group(&"mechs"):
		var o := n as Mech
		if o == null or o == mech or o.team == mech.team or o.layers == null or o.layers.dead:
			continue
		var d := (o.feet() - mech.feet()).length()
		if d <= best_d:
			best_d = d
			best = o
	return best
