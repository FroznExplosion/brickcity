extends Node

## The city's machines: the player's mech (calling it down, boarding it from
## its hatch, leaving it), the enemy's mechs, tanks and trucks, drop pods and
## the backpack's mech page, and getting in and out of a vehicle on foot.
##
## A part of the city scene, made by it (CityScene.vehicles), and moved out of
## city_scene.gd so this feature's code is in one place. It drives the city
## through `city` -- its player, camera, guns, AI and world -- exactly as it
## did from inside it. Typed against the city's script, so a name the city
## no longer has is a parse error here.

const City := preload("res://scripts/city_scene.gd")

var city: City

## The trucks spawned here; the arena's are its own. All of them are in the
## "trucks" group, which is what M and E look through.
var trucks: Array[TransportTruck] = []

## Every mech with a brain: the player's (its brain off while piloted) and the
## enemy's (Y).
var mech_brains: Array[MechBrain] = []

## The player got into the mech on foot, and gets out on foot (_leave_mech).
var _boarded_on_foot := false

## Mechs with no brain and no pilot (the --mechfall gate's).
var _loose_mechs: Array[Mech] = []

## The pods' own dice: a pod drop never moves what the guns' loot stream draws.
var _pod_rng := RandomNumberGenerator.new()

## The pods the player starts with: one of each kind, rolled from fixed seeds.
const START_POD_SEED := 0x90D5


func _init(c: Node3D) -> void:
	city = c
	name = "Vehicles"


## A pod on the ground at `at`, of the fight's tier and a rolled rarity (as loot is): the
## player walking onto it takes it into the backpack's mech page.
func drop_pod(at: Vector3) -> WorldPodPickup:
	if _pod_rng.seed == 0:
		_pod_rng.seed = 0x90D0
	var t := city.arena.level if city.arena != null else 1
	var pod := PodGenerator.generate(_pod_rng.randi(), LootRoller.roll_rarity(_pod_rng,
			LootRoller.total_luck(t, t, &"heavy")), t)
	var w := WorldPodPickup.create(pod)
	city.add_child(w)
	w.global_position = city._on_ground(at)
	w.taker_of = func() -> Node3D:
		return city._player_pawn.body if city._player.is_possessing() and city._player_pawn != null 				and is_instance_valid(city._player_pawn) else null
	w.picked.connect(func(p: PodGenerator.Result) -> void:
		_pod_stash().stash.append(p)
		if city._arsenal != null:
			city._arsenal._say("Pod: %s (backpack, mech page)" % p.pod_name)
		print("[city] picked up pod %s" % p.pod_name))
	print("[city] pod dropped: %s" % pod.pod_name)
	return w


## The backpack's mech page, made if the player has had no mech yet: where pods go.
func _pod_stash() -> MechLoadoutScreen:
	if city._mech_screen == null:
		city._mech_screen = MechLoadoutScreen.new()
		city._mech_screen.name = "MechLoadout"
		city.add_child(city._mech_screen)
		if city._arsenal != null:
			city._arsenal.mech_screen = city._mech_screen
	return city._mech_screen


## Climb into the mech -- spawning one on the ground ahead of the camera if there
## is none -- and take its controls. Its arm gets a gun of its own. On foot it is
## got into from its hatch's side, and only our own: trying another side's sets
## it off (Docs/AIRoster.md 4.4, R14). From the free camera it is a debug key
## and boards from anywhere.
func board_mech() -> void:
	_boarded_on_foot = false
	if city._player.is_possessing() and city._player_pawn != null and is_instance_valid(city._player_pawn):
		var near := _mech_at_hatch(city._player_pawn)
		if near == null:
			# Firefight: no hatch in reach is a call for the mech (Titanfall's).
			if city.arena is FirefightDirector and (city.arena as FirefightDirector).call_mech(city._aim_point()):
				return
			print("[city] no mech's hatch within reach: walk to its hatch side")
			return
		if not near.layers.try_enter(city._player_pawn.team):
			print("[city] not our mech: its self-destruct is lit -- get clear")
			return
		if near != city._mech:
			print("[city] a mech of ours, but not yours to drive")
			return
		_boarded_on_foot = true
		city._leave_pawn()
	if city.camera.is_walking():
		city.camera.set_walking(false)
	if city._mech == null or not is_instance_valid(city._mech):
		var ahead := city.camera.global_position - city.camera.global_transform.basis.z * 12.0
		var q := PhysicsRayQueryParameters3D.create(ahead + Vector3.UP * 50.0,
				ahead - Vector3.UP * 200.0, Layers.PAWN_MASK)
		var hit := city.get_world_3d().direct_space_state.intersect_ray(q)
		var feet: Vector3 = hit.position if not hit.is_empty() else Vector3(ahead.x, 0.0, ahead.z)
		spawn_mech(feet, city.camera.global_rotation.y)
	if city._pilot.get_parent() == null:
		city._pilot.name = "Pilot"
		city.add_child(city._pilot)
	city.camera.set_process(false)
	city.camera.allow_walk = false
	# The pilot's keys drive it now, not its brain.
	var br := city._mech.body.get_node_or_null(^"MechBrain") as MechBrain
	if br != null:
		br.enabled = false
	# The player's own gun is put down: the mech's arm is the only gun now.
	city._gun_armed = false
	city._gun.set_trigger(false)
	if city._gun.gun != null:
		city._gun.gun.visible = false
	city._pilot.board(city._mech, city.camera)
	city._mech.occupy()
	print("[city] piloting: mech at %v, %s" % [city._mech.feet(), city._mech.gun.gun.gun_name])


## The vehicle of ours the player's pawn rides on (VehicleDeck), or null.
func aboard() -> Node3D:
	if city._player_pawn == null or not is_instance_valid(city._player_pawn) or not city._player_pawn.has_meta(&"aboard"):
		return null
	var v: Node3D = city._player_pawn.get_meta(&"aboard")
	return v if v != null and is_instance_valid(v) else null


## The mech whose hatch `p` stands at, any side's; null for none.
## Hold reload on foot (PlayerArsenal.interact): into our mech at its hatch, or the
## vehicle beside -- what M does, but only when there is one to get in. True if it did.
func hold_board() -> bool:
	if not city._player.is_possessing() or city._player_pawn == null or not is_instance_valid(city._player_pawn):
		return false
	var m := _mech_at_hatch(city._player_pawn)
	if m != null and m == city._mech:
		board_mech()
		return true
	var v := vehicle_at_side()
	if v != null:
		use_vehicle(v)
		return true
	return false


func _mech_at_hatch(p: Pawn) -> Mech:
	for n in city.get_tree().get_nodes_in_group(&"mech_layers"):
		var ml := n as MechLayers
		if ml != null and not ml.dead and ml.mech.can_reach(p):
			return ml.mech
	return null


func spawn_mech(feet: Vector3, yaw: float) -> Mech:
	city._mech = Mech.spawn(city, feet, yaw, 0)
	# The player's dressing on it -- not in a scripted pass, which must not change with what
	# this machine's player has put on.
	if not city._scripted:   # a scripted pass's mech stays the boxes its numbers were taken with
		MechAssembler.dress_rolled(city._mech, hash(feet), "normal", null, false, "player")
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	_give_pods(city._mech)
	MachineLoadout.arm_mech(city._mech, city._gun_library, city._combat_rng.randi())
	# A mech gun made in the workshop, if there is one, in its hand instead (stage 7) --
	# not in a scripted pass, which must not change with what this machine has saved.
	if not city._scripted:
		MechAssembler.arm_gun(city._mech, MechAssembler.roll_gun(city._gun_library, hash(feet)))
	city._mech.gun.rng = city._combat_rng
	city._mech.gun.on_structure_hit = city._gun.on_structure_hit
	# The player's mech's kills are the player's XP (PlayerLevel).
	city._mech.gun.set_meta(PlayerLevel.SOURCE_META, city._player.progress)
	wire_mech(city._mech)
	# Out of the cockpit it fights on its own, on the one button (AI.md 2.1).
	var br := MechBrain.attach(city.ai_services, city._mech, city.mech_nav, MechTree.companion(), 0)
	br.enabled = false
	mech_brains.append(br)
	city._mech_cmd = MechCommand.new(br, city._player_pawn)
	return city._mech


func leave_mech() -> void:
	city._pilot.leave()
	city.camera.set_process(true)
	city.camera.allow_walk = city.camera.capture_mouse
	if city._mech_cmd != null and is_instance_valid(city._mech):
		# Out: it holds where it stands until told otherwise.
		var br := city._mech_cmd.brain
		br.enabled = true
		br.order = MechBrain.Order.HOLD
		br.order_point = city._mech.feet()
	if is_instance_valid(city._mech):
		city._mech.dismount()
		# Out of the hatch, on foot, if that is how the player got in.
		if _boarded_on_foot:
			_boarded_on_foot = false
			city._enter_pawn(city._mech.mount_point())


## A tank of side `team` on the ground at `feet`: a cannon that opens walls, a
## machine gun, a brain for its crew -- and a crew of soldiers of its side in
## both seats if `crewed`.
func spawn_tank(feet: Vector3, yaw: float, team: int, crewed: bool) -> Tank:
	if city.ai_services.world3d == null:
		city.ai_services.world3d = city.get_world_3d()
		city.ai_services.on_structure_hit = city._gun.on_structure_hit
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	var guns := MachineLoadout.tank_guns(city._gun_library, city._combat_rng.randi(), city._combat_rng.randi())
	var t := Tank.make(city.ai_services, city, feet, yaw, team, guns[0], guns[1], city._gun.on_structure_hit,
			city._combat_rng)
	city.ai_services.add_pawn(t.make_target())
	TankBrain.attach(city.ai_services, t)
	city.weight.add(t, t.feet, WeightTracker.MECH)
	if crewed:
		MachineLoadout.crew_tank(t, func(_seat: int) -> Pawn:
			var so := city._spawn_soldier(feet)
			so.team = team
			so.pawn.team = team
			return so.pawn)
	t.wrecked.connect(func(w: Tank) -> void:
		print("[city] tank wrecked at %v%s" % [w.feet(), " -- its ammo cooked off" if w.cooked_off else ""]))
	t.damaged.connect(func(zone: StringName) -> void:
		var whose := "your tank" if city._vehicle_pilot.vehicle == t else "a tank of side %d" % t.team
		print("[city] %s: %s" % [whose, City.ZONE_LOST_LINES.get(zone, String(zone) + " gone")]))
	city._wire_deck(t)
	t.player_thrown.connect(func() -> void:
		if city._vehicle_pilot.vehicle == t:
			print("[city] a boarder pried the hatch open: you are dragged out")
			leave_vehicle(Tank.DRAGGED_HURT))
	city.tanks.append(t)
	print("[city] tank of side %d at %v, %s" % [team, feet, "crewed" if crewed else "empty"])
	return t


## The enemy's tank (Z), with a squad that screens it (AIVehicles.md 4): it goes
## for the player at the squad's pace.
func spawn_enemy_tank(feet: Vector3, yaw: float) -> Tank:
	var t := spawn_tank(feet, yaw, 1, true)
	var back := Basis(Vector3.UP, yaw).z
	var q := city._spawn_squad(city.ai_nav.snap(feet + back * 9.0))
	var br := t.get_node(^"TankBrain") as TankBrain
	br.escort = q
	if city._player_pawn != null and is_instance_valid(city._player_pawn):
		br.send(city._player_pawn.feet())
	return t


## The vehicle -- a tank or a truck, any side's -- the player's pawn stands
## beside; null for none.
func vehicle_at_side() -> CharacterBody3D:
	if not city._player.is_possessing() or city._player_pawn == null or not is_instance_valid(city._player_pawn):
		return null
	for t in city.tanks:
		if is_instance_valid(t) and not t.is_wrecked() and t.can_reach(city._player_pawn):
			return t
	for n in city.get_tree().get_nodes_in_group(&"trucks"):
		var truck := n as TransportTruck
		if truck != null and not truck.is_wrecked() and (truck.can_reach(city._player_pawn)
				or truck.rodeo.beside(city._player_pawn, VehicleDeck.RIDE_REACH)):
			return truck
	return null


## M beside a vehicle (Halo): the wheel if nobody has it -- an empty one of any
## side, a tank of ours with no driver, a truck from beside its cab -- and
## otherwise a place on its deck, if it is ours.
func use_vehicle(v: CharacterBody3D) -> void:
	var drive := false
	if v is Tank:
		# A seat: the driver's if it is free, the gunner's with one of ours driving.
		var t := v as Tank
		drive = not t.player_in and (t.is_empty() or (t.team == city._player_pawn.team
				and (t.seat_free(Tank.Seat.DRIVER) or t.seat_free(Tank.Seat.GUNNER))))
	else:
		var truck := v as TransportTruck
		drive = truck.is_empty() and truck.can_reach(city._player_pawn)
	if drive:
		drive_vehicle(v)
	elif v.rodeo.ride(city._player_pawn):
		print("[city] riding on it: shoot from there; jump or M to get off")
	elif v.team == city._player_pawn.team:
		print("[city] no room on it")
	else:
		print("[city] not yours: E beside it to %s" % ("climb on and pry its hatch" if v is Tank else "take its cab"))


## In at the wheel (a tank: both seats). An empty vehicle of any side, or one of ours.
func drive_vehicle(v: CharacterBody3D) -> void:
	if not v.take_player(city._player_pawn.team):
		print("[city] its crew is in it: not yours to take")
		return
	city._leave_pawn()
	# The free camera's gun stays down: the buttons are the vehicle's (its view
	# drew over the tank, and its left button fired beside the cannon).
	city._gun_armed = false
	city._gun.set_trigger(false)
	if city._gun.gun != null:
		city._gun.gun.visible = false
	if city.camera.is_walking():
		city.camera.set_walking(false)
	if city._vehicle_pilot.get_parent() == null:
		city._vehicle_pilot.name = "VehiclePilot"
		city.add_child(city._vehicle_pilot)
	city.camera.set_process(false)
	city.camera.allow_walk = false
	city._vehicle_pilot.board(v, city.camera)
	if not v.wrecked.is_connected(_on_driven_wrecked):
		v.wrecked.connect(_on_driven_wrecked)
	city._hop_in_at = 0.0
	if v is Tank:
		print("[city] in a tank, %s; C inside/behind, M to get out" % VehiclePilot.seat_line(v as Tank))
	else:
		if (v as TransportTruck).is_apc():
			print("[city] driving an APC: W/S throttle, A/D steer, LMB its gun, C inside/behind, M to get out")
		else:
			print("[city] driving a truck: W/S throttle, A/D steer, C inside/behind, M to get out -- friends near hop in the back")


## Out on foot beside it, `hurt` for a wreck or a boarder; its riders get down
## with the driver -- they have a fight to get back to.
func leave_vehicle(hurt := 0.0) -> void:
	var v := city._vehicle_pilot.vehicle
	city._vehicle_pilot.leave()
	city.camera.set_process(true)
	city.camera.allow_walk = city.camera.capture_mouse
	if v != null and is_instance_valid(v):
		v.rodeo.all_off("driver out")
		city._enter_pawn(v.mount_point())
		if hurt > 0.0 and city._player_pawn != null and city._player_pawn.health != null:
			city._player_pawn.health.apply_impact(hurt, &"")


func _on_driven_wrecked(v: Node) -> void:
	if city._vehicle_pilot.vehicle == v:
		print("[city] wrecked: you climb out")
		leave_vehicle(float(v.get(&"bail_hurt")) if v is Tank else Tank.BAIL_HURT)


## A truck of side `team` at `feet`, facing `yaw`, with `cargo` in the back
## (put down at its tailgate when it stops: _truck_unload).
func spawn_truck(feet: Vector3, yaw: float, team: int, cargo: Array[StringName],
		kind := &"truck") -> TransportTruck:
	var gi: GunInstance = null
	if kind == &"apc":
		if city.ai_services.world3d == null:
			city.ai_services.world3d = city.get_world_3d()
			city.ai_services.on_structure_hit = city._gun.on_structure_hit
		if city._gun_library == null:
			city._gun_library = GunPlaceholderParts.build_library()
		gi = MachineLoadout.roll(city._gun_library, city._combat_rng.randi(), MachineLoadout.APC_GUN)
	var truck := TransportTruck.make(city.ai_services, city, feet, yaw, kind, gi, city._gun.on_structure_hit, city._combat_rng)
	truck.team = team
	truck.cargo = cargo
	truck.arrived.connect(_truck_unload)
	city._wire_deck(truck)
	truck.damaged.connect(func(zone: StringName) -> void:
		var whose := "your truck" if city._vehicle_pilot.vehicle == truck else "a truck of side %d" % truck.team
		print("[city] %s: %s" % [whose, City.TRUCK_ZONE_LOST_LINES.get(zone, String(zone) + " gone")]))
	truck.wrecked.connect(func(w: TransportTruck) -> void:
		print("[city] truck wrecked at %v%s" % [w.feet(), (" with %d aboard" % w.cargo.size()) if not w.cargo.is_empty() else ""])
		w.cargo.clear()
		trucks.erase(w)
		city.get_tree().create_timer(10.0).timeout.connect(func() -> void:
			if is_instance_valid(w):
				w.queue_free()))
	trucks.append(truck)
	print("[city] %s of side %d at %v%s" % [truck.name.to_lower(), team, feet,
			(", %d in the back" % cargo.size()) if not cargo.is_empty() else ", empty"])
	return truck


## A truck spawned here has stopped (or was hijacked): its squad is put down at
## the tailgate, on the side away from the player.
func _truck_unload(truck: TransportTruck) -> void:
	if truck.cargo.is_empty():
		return
	var threat := city._player_pawn.feet() if city._player_pawn != null and is_instance_valid(city._player_pawn) \
			else truck.global_position + Vector3.FORWARD
	var spots := truck.tailgate_points(threat, truck.cargo.size())
	var members: Array[Soldier] = []
	for i in truck.cargo.size():
		var at: Vector3 = spots[i] if i < spots.size() else city.ai_nav.snap(truck.global_position
				+ truck.global_transform.basis.z * (truck.size.z * 0.5 + 1.2 + i))
		members.append(city._spawn_soldier(at))
	print("[city] %s unloaded %d at %v (%s)" % [truck.name.to_lower(), truck.cargo.size(), truck.global_position,
			truck.stopped_because])
	truck.cargo.clear()
	# An APC's squad is one, and it covers them (moving cover).
	if truck.is_apc() and not members.is_empty():
		var q := Squad.make(city.ai_services, city, members, 1)
		city.squads.append(q)
		if city._player_pawn != null and is_instance_valid(city._player_pawn):
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = city._player_pawn.feet()
			for m in members:
				m.knowledge().heard(city._player_pawn, city._player_pawn.feet(), city.ai_services.now())
			q.give(o)
		truck.escort = q


## A mech's weight and its fall rule, on this city (Docs/AI.md 3.10, 3.11).
func wire_mech(m: Mech) -> void:
	m.fall.decides = city.authority.may_decide()
	m.fall.floor_at = _mech_floor_at
	m.fall.on_break = _mech_break
	m.fall.next_floor = city._next_floor_below
	city.weight.add(m.body, m.feet, Mech.MASS)
	city._wire_rodeo(m)


## The player's mech gets its two pod slots, and the backpack its mech page with the
## pods the player has; a missile pod and a shield booster fitted to start (not in a
## scripted pass, whose mech must fight as it always has).
func _give_pods(m: Mech) -> void:
	city._mech_pods = MechPods.attach(m, city._gun_library, city._combat_rng)
	city._mech_pods.on_structure_hit = city._gun.on_structure_hit
	if city._mech_screen == null:
		city._mech_screen = MechLoadoutScreen.new()
		city._mech_screen.name = "MechLoadout"
		city.add_child(city._mech_screen)
		var kinds := PodGenerator.kinds()
		for i in kinds.size():
			city._mech_screen.stash.append(PodGenerator.generate(START_POD_SEED + i, 2, 1, kinds[i]))
		city._mech_screen.index = 0
		# Not in a scripted pass: a pass's mech fights as it always has.
		for want in ([] if city._scripted else [&"missiles", &"shield_boost"]):
			for i in city._mech_screen.stash.size():
				if (city._mech_screen.stash[i] as PodGenerator.Result).kind == want:
					city._mech_screen.index = i
					city._mech_screen.fit_selected(0 if want == &"missiles" else 1)
					break
	else:
		# A new mech of the player's: the pods it had go on it again.
		var old: Array = city._mech_screen.pods.slots.duplicate() if city._mech_screen.pods != null else []
		for i in old.size():
			if old[i] != null:
				city._mech_pods.fit(i, old[i])
	city._mech_screen.pods = city._mech_pods
	if city._arsenal != null:
		city._arsenal.mech_screen = city._mech_screen


func spawn_enemy_mech(feet: Vector3, yaw: float, recipe := "medium_gunner", design: PartDesign = null) -> MechBrain:
	if city._gun_library == null:
		city._gun_library = GunPlaceholderParts.build_library()
	var m := Mech.spawn(city, feet, yaw, 1)
	MachineLoadout.arm_mech(m, city._gun_library, city._combat_rng.randi())
	if not city._scripted:
		# A mech gun in its hand, seen: the shipped one, or one made in the workshop.
		MechAssembler.arm_gun(m, MechAssembler.roll_gun(city._gun_library, hash(feet)))
	m.gun.rng = city._combat_rng
	m.gun.on_structure_hit = city._gun.on_structure_hit
	wire_mech(m)
	var br := MechBrain.attach(city.ai_services, m, city.mech_nav, MechTree.enemy(), 1)
	# A mech by the roster: its layers and the name over it (AIRoster.md RO6).
	m.set_type(recipe, Roster.shared())
	# Made of parts when there are parts to make it of (Docs/ModularParts.md stage 6): a
	# chassis of its class, every part fitting -- or a design's, of the design's class.
	# Else the boxes. Seeded from where it stands: no roll of the combat dice moves.
	if not city._scripted or design != null:   # a scripted pass's mechs stay the boxes it measured
		MechAssembler.dress_rolled(m, hash(feet), MechAssembler.class_of(
				str(Roster.shared().recipe(recipe).get("class", ""))) if design == null else "",
				design, design != null)
	# Its pilot, a soldier of its side, inside: one who can bail out (RO8).
	var pilot := city._spawn_soldier(feet)
	m.mount(pilot.pawn, true)
	MachineLoadout.arm_launcher(br, m, city._gun_library, city._combat_rng.randi, city._combat_rng,
			city._gun.on_structure_hit)
	mech_brains.append(br)
	# Destroyed, it leaves a pod (stage 7's pods as loot) -- not in a scripted pass.
	if not city._scripted and m.layers != null:
		m.layers.destroyed.connect(func(_why: String) -> void: drop_pod(m.feet()))
	print("[city] enemy mech (%s) at %v" % [m.name_tag.text if m.name_tag != null else recipe, feet])
	return br


## What a mech's feet land on, for the fall rule: a building's brick is a floor
## (T = 6 bricks; a floor already hanging, T = 3); a loose piece or the ground is
## not. A building still in its shell is made bricks first -- a landing is damage
## (A20).
func _mech_floor_at(feet: Vector3) -> Dictionary:
	var under := feet - Vector3.UP * 0.07
	var v := city._block_under_footprint(under)
	if v.x < 0:
		for id in city._near_buildings(feet, 1.0):
			var b := city.registry.get_building(id)
			if b != null and city._world_box(b).grow(0.3).has_point(under) 					and city._wants_bricks(b, city._storeys_for(id, under, 1.0)):
				city._promote(id, true, city._storeys_for(id, under, 1.0))
				city.ai_world.sync()
				v = city._block_under_footprint(under)
				break
	if v.x < 0:
		return {}
	var id := city._building_of_chunk(v.x)
	if id < 0:
		return {}
	var t := FallRule.T
	var h := city.world.get_headroom(v.x, v.y)
	if h >= 0.0 and not is_inf(h):
		t *= 0.5
	return {"chunk": v.x, "building": id, "t": t}


## The host breaks the floor under a mech: a SHEAR that lets every block in the
## ball go on its own. The pieces land quietly -- the rule, not their landing,
## decides the next floor (R9).
func _mech_break(point: Vector3, radius: float, fl: Dictionary) -> void:
	var id := int(fl.building)
	var e := DamageLog.Entry.new()
	e.tick = Engine.get_physics_frames()
	e.kind = DamageLog.Kind.SHEAR
	e.target = id
	e.point = point
	e.radius = radius
	e.limit = 48
	e.flags = DamageLog.FLAG_WHOLE
	DamageLog.apply_entry(city.world, int(fl.chunk), e)
	city.authority.commit_entry(e)
	city.islands.quiet_landings(point, radius + 2.5, 3.0)
	city._mark_dirty(id)
	city._queue_remesh(id)
	var r := Vector3.ONE * (radius + 1.0)
	city.ai_nav.invalidate_box(AABB(point - r, r * 2.0))


func mech_ignore_piece(isl: BrickIsland) -> void:
	if not isl.is_valid():
		return
	var box := city.islands.world_aabb(isl)
	for m in _crashing_mechs():
		var f := m.feet()
		if box.grow(Mech.RADIUS + 1.0).has_point(Vector3(f.x, clampf(f.y, box.position.y, box.end.y), f.z)):
			m.fall.ignore(isl.body)


func _crashing_mechs() -> Array[Mech]:
	var out: Array[Mech] = []
	if city._mech != null and is_instance_valid(city._mech) and city._mech.fall.is_carrying():
		out.append(city._mech)
	for br in mech_brains:
		if is_instance_valid(br) and br.mech.fall.is_carrying() and not out.has(br.mech):
			out.append(br.mech)
	for m in _loose_mechs:
		if is_instance_valid(m) and m.fall.is_carrying() and not out.has(m):
			out.append(m)
	return out


func mech_nav_service() -> void:
	city.mech_nav.service(int(City.NAV_BUDGET_US * city.ai_sched.rate_scale(AIScheduler.NAV)))
