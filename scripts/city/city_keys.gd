extends Node

## The city's keys: what each key and click does in the city -- the player's
## (V on foot, M the mech, E use, F orders) and the developer's (spawning,
## the debug views, blasts, the profiler, the terrain and disaster tools).
## The city's _unhandled_input hands every event here.
##
## A part of the city scene, made by it (CityScene.keys), and moved out of
## city_scene.gd so the key map is in one place. It drives the city through
## `host` -- typed against the city's script, so a name the city no longer has
## is a parse error here.

const Host := preload("res://scripts/city_scene.gd")

var host: Host

## The enemy's mech (Y), ahead of the camera: an LMG, a launcher for walls, and
## the enemy tree -- it breaches to get at infantry (AI.md 6.4).
## `recipe`: which of the roster's mechs it is (AIRoster.md RO11: a commander
## buys one by its recipe).
## Which workshop mech Ctrl Y spawned last.
var _mech_design := -1

## The figures Ctrl T put down, and which design was last.
var _figures: Array[Figure] = []

var _figure_design := -1

var _builder: CharacterBuilder

var _dress_colour := 1

## The player's actions the city handles itself, and the key each stands for in
## _unhandled_input's match (its arms keep the default keys' names).
const PLAYER_KEYS := {&"use_vehicle": KEY_M}


func _init(h: Node3D) -> void:
	host = h
	name = "Keys"


func _spawn_figure() -> String:
	var cat := MechAssembler.catalog(true)
	var made := Figure.designs(cat)
	if made.is_empty():
		return "no figure saved in the asset workshop yet"
	var ids := made.keys()
	ids.sort()
	_figure_design = (_figure_design + 1) % ids.size()
	var b := PartBuilder.generate("figure", made[ids[_figure_design]], hash(ids[_figure_design]), cat)
	var f := Figure.make(b)
	if f == null:
		return "figure %s does not go together: %s" % [ids[_figure_design], "; ".join(b.problems)]
	f.position = host._on_ground(host.camera.global_position - host.camera.global_transform.basis.z * 6.0)
	f.wander = true
	host.add_child(f)
	_figures.append(f)
	return "figure %s" % ids[_figure_design]


## Ctrl Alt T: the character builder. What it puts in the world stands ahead of the camera
## and follows the player on foot (else walks a circle).
func _open_character_builder() -> void:
	if _builder == null:
		_builder = CharacterBuilder.new()
		_builder.name = "CharacterBuilder"
		host.add_child(_builder)
		_builder.spawned.connect(func(f: Figure) -> void:
			f.position = host._on_ground(host.camera.global_position - host.camera.global_transform.basis.z * 4.0)
			host.add_child(f)
			if host._player.is_possessing() and host._player_pawn != null and is_instance_valid(host._player_pawn):
				f.mode = "follow"
				f.target = host._player_pawn.body
			else:
				f.mode = "wander"
			_figures.append(f)
			print("[city] character put down, %s" % f.mode))
	_builder.open(MechAssembler.catalog(true))


func _swap_figure_limb() -> String:
	while not _figures.is_empty() and not is_instance_valid(_figures[-1]):
		_figures.pop_back()
	if _figures.is_empty():
		return "no figure to swap a limb of (Ctrl T puts one down)"
	var f := _figures[-1]
	var cat := MechAssembler.catalog()
	var paths: Array = (f.build.at as Dictionary).keys()
	paths.shuffle()
	for path: String in paths:
		var now: PartRecord = f.build.at[path]
		var options := cat.filter({"family": ["figure"], "slot": [now.slot]}).filter(
				func(r: PartRecord) -> bool: return r.id != now.id and f.why_not_swap(path, r) == "")
		if not options.is_empty():
			var pick: PartRecord = options[randi() % options.size()]
			f.swap(path, pick)
			return "figure's %s is now %s" % [path, pick.display_name]
	return "no other part fits any of its slots"


## Put a dressing brick on (or take one off) the player's mech's stud nearest the crosshair
## line, within half a metre of it and 30 m off. What happened, in words.
func _dress_at_crosshair(take_off: bool) -> String:
	var from := host.camera.global_position
	var dir := -host.camera.global_transform.basis.z
	var best_d := 0.5
	var best := {}
	var parts := PartDressing.parts_of(host._mech)
	for id: String in parts:
		var part: Node3D = parts[id]
		for st in PartDressing.studs(part).studs:
			var at: Vector3 = part.global_transform * (st.at as Vector3)
			var along := (at - from).dot(dir)
			if along < 0.0 or along > 30.0:
				continue
			var d := (from + dir * along).distance_to(at)
			if d < best_d:
				best_d = d
				best = {"id": id, "key": st.key}
	if best.is_empty():
		return "no stud of your mech under the crosshair"
	var store := PartDressing.load_store()
	var list := PartDressing.of(store, "player", best.id)
	if take_off:
		list = PartDressing.remove(list, best.key)
	else:
		var r := PartDressing.add(parts[best.id], list, best.key, "brick", _dress_colour)
		if not r.ok:
			return "not there: " + String(r.why)
		list = r.list
	PartDressing.put(store, "player", best.id, list)
	PartDressing.save_store(store)
	PartDressing.apply(parts[best.id], list)
	return "%d bricks on %s, %.1f kg" % [list.size(), best.id, PartDressing.mass(list)]


## One of the view switches (DebugView): 7, 8 and 9 in play.
func _view_cycle(kind: int) -> void:
	DebugView.cycle(kind)
	host._view_owed = true
	print("[city] view: %s" % DebugView.line())
	host.dev_hud.update_hud()


## Flip a shader bool and return its new value. Never reads the material.
func _toggle_shader(param: String) -> bool:
	var on: bool = not bool(host._shader_toggles.get(param, true))
	host._shader_toggles[param] = on
	host.brick_material.set_shader_parameter(param, on)
	return on


## The key `event` stands for, by the action it is bound to (so a rebinding
## counts), or KEY_NONE. Modifiers are ignored: Shift+Z is still the tank key,
## and its arm reads the Shift.
static func _key_of(event: InputEvent) -> Key:
	for a in PLAYER_KEYS:
		if event.is_action_pressed(a):
			return PLAYER_KEYS[a]
	# The developer keys only in developer mode (DevMode, Options > Gameplay).
	if not DevMode.on:
		return KEY_NONE
	for a in Host.DEV_KEYS:
		if event.is_action_pressed(a):
			return Host.DEV_KEYS[a]
	return KEY_NONE


func handle_input(event: InputEvent) -> void:
	# Terrain edit mode: everything but these is the editor's.
	if host._edit_mode:
		if event is InputEventKey and event.pressed and not event.echo:
			match _key_of(event):
				KEY_F11:
					host._toggle_terrain_edit()
				KEY_F10:
					host._toggle_terrain_dev_menu()
				KEY_F1:
					host.stats_label.visible = not host.stats_label.visible
		return
	# Rodeo (Docs/AIRoster.md 4.5): on foot, melee (E) climbs an enemy mech in reach
	# instead of striking (_melee_context); on its back, E held plants the charge and
	# jump gets off.
	if host._player.is_possessing() and host._player_pawn != null and is_instance_valid(host._player_pawn):
		if host._riding() != null and event.is_action_pressed(&"jump"):
			host._riding().rodeo.drop("jumped")
			return
		if host.vehicles.aboard() != null and event.is_action_pressed(&"jump"):
			host.vehicles.aboard().rodeo.get_off(host._player_pawn, "jumped")
			return
	# On foot the buttons are the player's own (rebindable input actions,
	# PlayerController): firing, aiming and reloading go through the pawn.
	if event is InputEventMouseButton and (host._player.is_possessing() or host._pilot.is_piloting()):
		return
	if event is InputEventMouseButton and not event.pressed 			and event.button_index == MOUSE_BUTTON_LEFT:
		host._gun.set_trigger(false)
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if host._gun_armed:
					host._gun.set_trigger(true)
				else:
					host._fire(host._blast_radius)
				return
			MOUSE_BUTTON_WHEEL_UP:
				if not host._player.is_possessing():
					host._set_blast_radius(host._blast_radius * Host.BLAST_STEP)
				return
			MOUSE_BUTTON_WHEEL_DOWN:
				if not host._player.is_possessing():
					host._set_blast_radius(host._blast_radius / Host.BLAST_STEP)
				return
	# The mech's one button (AI.md 2.1): on foot, F -- a tap toggles FOLLOW and
	# HOLD, held while aiming sends it to attack where the crosshair is.
	if event is InputEventKey and not event.echo and event.is_action(&"mech_order") \
			and host._mech_cmd != null and host._player.is_possessing():
		if event.pressed:
			host._mech_cmd.press(host.ai_services.now())
		else:
			var o := host._mech_cmd.release(host.ai_services.now(), host._aim_point())
			print("[city] mech order: %s" % MechBrain.Order.keys()[o])
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# On foot by the player's own mech of parts: Ctrl B puts a brick on the stud under the
	# crosshair, Ctrl Shift B takes it off, Ctrl Alt B the next colour (stage 11: dressing).
	if event.ctrl_pressed and event.keycode == KEY_B and host._player.is_possessing() and host._mech != null \
			and is_instance_valid(host._mech) and not PartDressing.parts_of(host._mech).is_empty():
		if event.alt_pressed:
			_dress_colour = (_dress_colour + 1) % PartDressing.COLOURS
			print("[city] dressing colour %d" % _dress_colour)
		else:
			print("[city] dressing: %s" % _dress_at_crosshair(event.shift_pressed))
		return
	# Ctrl T: the figures made in the asset workshop, in turn, walking a circle ahead of the
	# camera; Ctrl Shift T swaps a limb of the last one for another that fits (stage 12).
	if event.ctrl_pressed and event.keycode == KEY_T:
		if event.alt_pressed:
			_open_character_builder()
		else:
			print("[city] %s" % (_swap_figure_limb() if event.shift_pressed else _spawn_figure()))
		return
	# In the mech, 1 and 2 are its pods (MechPods).
	if host._pilot.is_piloting() and host._mech_pods != null and host._pilot.mech == host._mech_pods.mech:
		for slot in MechPods.SLOTS:
			if event.is_action_pressed(StringName("slot_%d" % (slot + 1))):
				if not host._mech_pods.use(slot):
					var pod: PodGenerator.Result = host._mech_pods.slots[slot]
					print("[city] pod %d: %s" % [slot + 1, "empty" if pod == null else
							("passive" if not pod.is_active() else "cooling, %.1f s" % host._mech_pods.cool[slot])])
				return
	match _key_of(event):
		KEY_X:
			host._fire(Host.BIG_BLAST)
		KEY_H:
			if host.disasters != null:
				host.disasters.on_key(event.shift_pressed)
		KEY_F1:
			host.stats_label.visible = not host.stats_label.visible
		KEY_1:
			# On foot 1 is the first gun slot (slot_1): the free camera's gun only.
			if host._player.is_possessing():
				return
			host._arm_gun()
		KEY_2:
			if host._player.is_possessing():
				return
			host._gun_armed = false
			host._gun.set_trigger(false)
			if host._gun.gun != null:
				host._gun.gun.visible = false
		KEY_K:
			var ahead := host.camera.global_position - host.camera.global_transform.basis.z * 20.0
			host._spawn_soldier(host.ai_nav.snap(host._on_ground(ahead)))
		KEY_U:
			var ahead := host.camera.global_position - host.camera.global_transform.basis.z * 30.0
			host._spawn_squad(host._on_ground(ahead))
		KEY_Y:
			var ahead := host.camera.global_position - host.camera.global_transform.basis.z * 40.0
			var design: PartDesign = null
			if event.ctrl_pressed:
				# Ctrl Y: the mechs made in the asset workshop, in turn.
				var made := MechAssembler.designs(MechAssembler.catalog(true))
				if made.is_empty():
					print("[city] no mech saved in the asset workshop yet")
					return
				var ids := made.keys()
				ids.sort()
				_mech_design = (_mech_design + 1) % ids.size()
				design = made[ids[_mech_design]]
			host.vehicles.spawn_enemy_mech(host.mech_nav.snap(host._on_ground(ahead)), host.camera.global_rotation.y + PI,
					"medium_gunner", design)
		KEY_M:
			if host._vehicle_pilot.is_driving():
				host.vehicles.leave_vehicle()
			elif host._pilot.is_piloting():
				host.vehicles.leave_mech()
			elif host.vehicles.aboard() != null:
				host.vehicles.aboard().rodeo.get_off(host._player_pawn, "jumped")
			elif host.vehicles.vehicle_at_side() != null:
				host.vehicles.use_vehicle(host.vehicles.vehicle_at_side())
			else:
				host.vehicles.board_mech()
		KEY_Z:
			var ahead := host.camera.global_position - host.camera.global_transform.basis.z * 30.0
			var truck_nav = host.ai_services.vehicle_nav(&"truck")
			if event.alt_pressed and event.shift_pressed:
				host.vehicles.spawn_truck(host.ai_services.vehicle_nav(&"apc").snap(host._on_ground(ahead)), host.camera.global_rotation.y, 0,
						[] as Array[StringName], &"apc")
			elif event.alt_pressed:
				# An enemy APC from further off with a squad inside: it stops at
				# contact, lets them out in its lee and covers them.
				var far := host.camera.global_position - host.camera.global_transform.basis.z * 80.0
				var apc: TransportTruck = host.vehicles.spawn_truck(host.ai_services.vehicle_nav(&"apc").snap(host._on_ground(far)),
						host.camera.global_rotation.y + PI, 1,
						[&"rifleman", &"rifleman", &"rifleman", &"rifleman"] as Array[StringName], &"apc")
				apc.send(host._player_pawn.feet() if host._player_pawn != null and is_instance_valid(host._player_pawn)
						else host._on_ground(host.camera.global_position))
			elif event.ctrl_pressed and event.shift_pressed:
				# From further off, coming for the player with a squad in the back.
				var far := host.camera.global_position - host.camera.global_transform.basis.z * 60.0
				var truck: TransportTruck = host.vehicles.spawn_truck(truck_nav.snap(host._on_ground(far)), host.camera.global_rotation.y + PI, 1,
						[&"rifleman", &"rifleman", &"rifleman", &"rifleman"] as Array[StringName])
				truck.send(host._player_pawn.feet() if host._player_pawn != null and is_instance_valid(host._player_pawn)
						else host._on_ground(host.camera.global_position))
			elif event.ctrl_pressed:
				host.vehicles.spawn_truck(truck_nav.snap(host._on_ground(ahead)), host.camera.global_rotation.y, 0, [] as Array[StringName])
			elif event.shift_pressed:
				host.vehicles.spawn_tank(host.ai_nav.snap(host._on_ground(ahead)), host.camera.global_rotation.y, 0, false)
			else:
				host.vehicles.spawn_enemy_tank(host.ai_nav.snap(host._on_ground(ahead)), host.camera.global_rotation.y + PI)
		KEY_V:
			if host._pilot.is_piloting() or host._vehicle_pilot.is_driving():
				return
			if host._player.is_possessing():
				host._leave_pawn()
			else:
				host._enter_pawn(host.camera.global_position - Vector3.UP * Pawn.EYE_HEIGHT)
		KEY_T:
			# The classes, then each gun made in the asset workshop.
			var made := AssetGuns.ids()
			host._gun_class = (host._gun_class + 1) % (Host.GUN_CLASSES.size() + made.size())
			if host._gun_class < Host.GUN_CLASSES.size():
				host._equip_gun(Host.GUN_CLASSES[host._gun_class], host._combat_rng.randi())
			else:
				host._equip_asset_gun(made[host._gun_class - Host.GUN_CLASSES.size()], host._combat_rng.randi())
			host._gun_armed = true
		KEY_R:
			if host._gun_armed and not host._player.is_possessing():
				host._gun.reload()
		KEY_F4:
			host._ai_label.visible = not host._ai_label.visible
			host.dev_hud.update_ai_label()
		KEY_F5:
			host.save_checkpoint()
		KEY_7:
			_view_cycle(DebugView.Kind.STRUCTURE)
		KEY_8:
			_view_cycle(DebugView.Kind.INTERIOR)
		KEY_9:
			_view_cycle(DebugView.Kind.ITEMS)
		KEY_F9:
			host.load_checkpoint()
		KEY_F10:
			host._toggle_terrain_dev_menu()
		KEY_F11:
			host._toggle_terrain_edit()
		KEY_L:
			if event.shift_pressed:
				# What drew each brick pixel (brick.gdshader tier_debug).
				var on := not bool(host._shader_toggles.get("tier_debug", false))
				host._shader_toggles["tier_debug"] = on
				host.brick_material.set_shader_parameter("tier_debug", on)
				print("[city] tier debug: %s" % ("ON" if on else "OFF"))
			else:
				print("[city] seams: %s" % ("ON" if _toggle_shader("seams_enabled") else "OFF"))
		KEY_B:
			# Both halves of the bevel: the shaded one, and the real one near
			# the camera (BrickNear), so the key shows the wall with and
			# without. Shift+B is the near tier alone.
			if not event.shift_pressed:
				_toggle_shader("chamfer_enabled")
			BrickNear.enabled = not BrickNear.enabled if event.shift_pressed \
					else bool(host._shader_toggles["chamfer_enabled"])
			print("[city] chamfered edges: shaded %s, built near the camera %s (%.0f m)" % [
					"ON" if host._shader_toggles["chamfer_enabled"] else "OFF",
					"ON" if BrickNear.enabled else "OFF", BrickNear.radius])
		KEY_I:
			# Printed on glass / smooth PEI / textured PEI, or injection
			# moulded (BrickMaterials.set_look).
			print("[city] finish: %s" % BrickMaterials.cycle_look())
		KEY_J:
			# The overlap. A piece that has just come off a building is drawn by
			# BOTH for two frames, because on the frame it is born there is
			# otherwise an instant where neither draws those bricks and the
			# building flashes. No readback can see it -- the sync hides it --
			# so the evidence is this toggle: turn it off and the flash returns.
			IslandManager.OVERLAP_FRAMES = 0 if IslandManager.OVERLAP_FRAMES > 0 else 2
			print("[city] overlap frames: %d %s" % [
					IslandManager.OVERLAP_FRAMES,
					"(a new piece and its parent both draw, briefly)"
					if IslandManager.OVERLAP_FRAMES > 0
					else "OFF -- watch for the one-frame flash"])
		KEY_O when event.shift_pressed:
			host._toggle_spaces_view()
		KEY_O:
			# Slow motion, so a one-tick artefact lasts long enough to attribute
			# to something. Cycles rather than toggles: 0.05 makes a single
			# physics tick last two thirds of a second.
			var steps := [1.0, 0.25, 0.05]
			var at := steps.find(snappedf(Engine.time_scale, 0.01))
			Engine.time_scale = steps[(at + 1) % steps.size()] if at >= 0 else 1.0
			print("[city] time scale: %.2f" % Engine.time_scale)
		KEY_F2:
			host._live_prof = not host._live_prof
			host._live_ring.clear()
			host._live_frame_ms.clear()
			host._live_worst = {}
			host._live_worst_ms = 0.0
			if host._live_label != null:
				host._live_label.visible = host._live_prof
			print("[city] live profiler: %s" % ("ON" if host._live_prof else "OFF"))
		KEY_F3:
			host._live_worst = {}
			host._live_worst_ms = 0.0
			print("[city] worst frame reset")
		KEY_N:
			host.respawn_buildings = not host.respawn_buildings
			print("[city] buildings give their bricks back and take them again: %s"
					% ("ON" if host.respawn_buildings else "OFF -- promoted once, resident for good"))
			host.dev_hud.update_hud()
		KEY_P:
			host._placer.toggle(host._build_path if host._build_path != "" else BuildRecipe.QUICK_SAVE)
		KEY_G:
			if event.shift_pressed:
				host._toggle_physics_view()
				return
			host._show_grids = not host._show_grids
			if host._grid_view != null:
				host._grid_view.visible = host._show_grids
			if host._show_grids:
				host._draw_grids()
