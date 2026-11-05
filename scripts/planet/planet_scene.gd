extends Node3D

## A planet to walk on and fly from (Docs/Planets.md 11.5 step 3): one 10 km
## planet of smooth voxel ground (PlanetBody), its sea shell, impostor and
## atmosphere; the radial walker; the floating origin at 4 km; the voxel
## streaming distance from the horizon. scenes/planet.tscn.
##
##   On foot: the game's own pawn, its moves, gun and arms (Planets.md 11.7).
##   F to fly (the walker; wheel for speed, Space up, Ctrl down), F again to
##   land on foot. Left click to look, Esc to let go.
##   -- --gate: the walker -- walk, fly to 30 km and back, land; quit.
##   -- --gate=pawn: the pawn -- walk, strafe, jump, mantle, fire, fly, land.
##   -- --gate=mech, --gate=tank, --gate=soldier: a titan, a tank on the
##   player's controls, a soldier's body moved and aimed as its brain does it.
##   -- --gate=bricks: the town's buildings near the player as real bricks --
##   drawn, solid, a way in, and bricks to the AI (11.11).
##   -- --gate=damage: rounds wear a brick out of a planet building, a blast
##   opens its wall; drawing, collision and the AI's map follow (11.11 D1).
##   -- --gate=storey: a storey cut to one corner tips what is above off it; a
##   tower too weak for its own weight is crushed a storey (11.11 D2 step 6).
##   -- --gate=trees: a tank knocks a tree down; a truck is stopped by one
##   (11.10, trees and vehicles).
##   -- --gate=squad: a squad on the AI's nav region round the town (11.8 N2)
##   walks to the player round the curve, takes cover, fires.
##   -- --gate=garrison: a generated world's own AI and a town's squad (11.12 step 7)
##   -- --gate=save --stage=1|2|3: the universe saved and come back to, run by run
##   -- --gate=home: home's town: quiet at the spawn, a fight walked into, its waves
##   -- --gate=belt: a star's belt from open space, the ship turned, slow among its rocks
##   -- --gate=seat: the ship smooth near a planet, out of its seat, the map, open space
##   -- --gate=hull: the generated ship (Docs/RoomModules.md 7.5): laid in bricks,
##   up its gangway and in by its airlock, flown from the bridge's seat, stood in
##   its bridge, its rooms furnished (KitFurnish).
##   -- --gate=travel: a squad ordered 200 m out of the town on the nav net
##   (11.8 N4), across the regions' borders.
##   -- --gate=far: two squads fight on the far side of the town, in a region
##   the player is not in: each agent asks its own region (AIServices.focus).
##   -- --gate=drive: an AI tank driven 200 m out of the town on the nav net's
##   tank map, across the regions' borders.

var data: PlanetData
var planet: PlanetBody
var buildings: PlanetBuildings
var trees: PlanetTrees
var spawn_dir := Vector3.UP
var town_dirs: Array = []
var landmark_dirs: Array = []
var walker: PlanetWalker
## The player on foot: the city's own kit (scripts/city_scene.gd _enter_pawn).
var cam: DebugCamera
var pawn: Pawn
var player: PlayerController
var gun: GunController
var view: PlayerView
## The firefight's player kit round the pawn: arsenal, HUD, aim assist (PlanetPlayerKit).
var kit: PlanetPlayerKit
var on_foot := false
var _pawn_gate := false
var _mech_gate := false
var _tank_gate := false
var _soldier_gate := false
var _squad_gate := false
var _trees_gate := false
var _bricks_gate := false
var _damage_gate := false
var _fall_gate := false
var _hits_gate := false
var _topple_gate := false
var _pieces_ai_gate := false
var _garrison_gate := false
var _seat_gate := false
var _hull_gate := false
var _belt_gate := false
var _home_gate := false
var _save_gate := false
var _storey_gate := false
## The AI round the fight (Docs/Planets.md 11.8, N2, N4): the nav net round the
## player's town; ai_world / ai_nav the region the player is in. Made by setup_ai.
var ai: AIServices
## Each world's AI (11.12 step 7): PlanetBody -> AIServices. `ai` is the one of the
## world the player is on, or was last on.
var ai_of := {}
## Each settled generated world's PlanetGarrison, made when it is first come to.
var garrisons := {}
## The towns wiped out (PlanetGarrison), across jumps.
var cleared := {}
var nav_region: PlanetNavRegion
var _travel_gate := false
var _far_gate := false
var _drive_gate := false
var _system_gate := false
var _light_gate := false
var _ship_gate := false
var _dock_gate := false
var _worlds_gate := false
var _jump_gate := false
var _debris_gate := false
var _adrift_gate := false
var _falling_gate := false
var _rocks_gate := false
var map: GalaxyMap
var markers: SpaceMarkers
var saver: PlanetSaver
var universes: UniversePanel
var _flash: ColorRect
## The ship parked by the spawn (11.12 step 3), and whether the player flies it.
var ship: SpaceShip
var piloting := false
var _mouse_steer := Vector2.ZERO
## The star system round the planet (Planets.md 11.12); null with --no-system.
var system: PlanetSystem
var sun: DirectionalLight3D
## The light (Docs/Lighting.md): sun, fill, sky, exposure, ambient boxes.
var light: LightRig
## The clouds of the world the camera is on (Docs/Lighting.md 2b).
var clouds: CloudLayer
## Ambient boxes made, by building site or module; when last looked for.
var _box_of := {}
var _boxes_at := 0
## The light on the brick grid in the buildings here (Lighting.md 6.1).
var grid_light := BrickGridLight.new()
var sky_mat: ProceduralSkyMaterial
var env: Environment
var hud: Label
## Low air in a ship or station (Docs/Hulls.md 4): a warning in the middle at the top.
var air_warn: Label
## Repair (Docs/Hulls.md 9): held ("restore", the middle mouse button) on a ship's or
## station's hull, its lost bricks come back.
var restore_tool := RestoreTool.new()

const VIEW_MIN := 1536
const VIEW_MAX := 6144
const VIEW_STEP := 512
const VIEW_MARGIN := 300.0

var _gate := false
var _worst_ms := 0.0
var _hitches: Array = []
## The same, from when the walker is let go: what play sees, not the load.
var _play_hitches: Array = []
var _last_us := 0


func _ready() -> void:
	_gate = "--gate" in OS.get_cmdline_user_args()
	_pawn_gate = "--gate=pawn" in OS.get_cmdline_user_args()
	_mech_gate = "--gate=mech" in OS.get_cmdline_user_args()
	_tank_gate = "--gate=tank" in OS.get_cmdline_user_args()
	_soldier_gate = "--gate=soldier" in OS.get_cmdline_user_args()
	_squad_gate = "--gate=squad" in OS.get_cmdline_user_args()
	_trees_gate = "--gate=trees" in OS.get_cmdline_user_args()
	_bricks_gate = "--gate=bricks" in OS.get_cmdline_user_args()
	_damage_gate = "--gate=damage" in OS.get_cmdline_user_args()
	_fall_gate = "--gate=fall" in OS.get_cmdline_user_args()
	_hits_gate = "--gate=hits" in OS.get_cmdline_user_args()
	_topple_gate = "--gate=topple" in OS.get_cmdline_user_args()
	_pieces_ai_gate = "--gate=pieces_ai" in OS.get_cmdline_user_args()
	_storey_gate = "--gate=storey" in OS.get_cmdline_user_args()
	_travel_gate = "--gate=travel" in OS.get_cmdline_user_args()
	_far_gate = "--gate=far" in OS.get_cmdline_user_args()
	_drive_gate = "--gate=drive" in OS.get_cmdline_user_args()
	_system_gate = "--gate=system" in OS.get_cmdline_user_args()
	_light_gate = "--gate=light" in OS.get_cmdline_user_args()
	_ship_gate = "--gate=ship" in OS.get_cmdline_user_args()
	_dock_gate = "--gate=dock" in OS.get_cmdline_user_args()
	_worlds_gate = "--gate=worlds" in OS.get_cmdline_user_args()
	_jump_gate = "--gate=jump" in OS.get_cmdline_user_args()
	_debris_gate = "--gate=debris" in OS.get_cmdline_user_args()
	_adrift_gate = "--gate=adrift" in OS.get_cmdline_user_args()
	_falling_gate = "--gate=falling" in OS.get_cmdline_user_args()
	_rocks_gate = "--gate=rocks" in OS.get_cmdline_user_args()
	_garrison_gate = "--gate=garrison" in OS.get_cmdline_user_args()
	_seat_gate = "--gate=seat" in OS.get_cmdline_user_args()
	_hull_gate = "--gate=hull" in OS.get_cmdline_user_args()
	_belt_gate = "--gate=belt" in OS.get_cmdline_user_args()
	_home_gate = "--gate=home" in OS.get_cmdline_user_args()
	_save_gate = "--gate=save" in OS.get_cmdline_user_args()
	WorldFrame.origin = Vector3.ZERO
	_gate = _gate or _light_gate or _system_gate or _ship_gate or _dock_gate or _worlds_gate or _jump_gate or _debris_gate or _adrift_gate or _falling_gate or _rocks_gate or _garrison_gate or _seat_gate or _hull_gate or _belt_gate or _home_gate or _save_gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate or _squad_gate or _travel_gate or _far_gate or _drive_gate or _trees_gate or _bricks_gate or _damage_gate or _fall_gate or _hits_gate or _topple_gate or _pieces_ai_gate or _storey_gate
	data = PlanetData.new()
	data.planet_name = "proto"
	# Towns and landmarks: their pads go into the ground before it is built.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x70C1
	spawn_dir = Vector3(0.12, 1.0, -0.08).normalized()
	var east := spawn_dir.cross(Vector3.FORWARD).normalized()
	town_dirs = [_round_dir(spawn_dir, east, 220.0)]
	for k in 6:
		town_dirs.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized())
	landmark_dirs = [_round_dir(spawn_dir, east, 2600.0), _round_dir(spawn_dir, east.rotated(spawn_dir, 2.0), 9000.0),
			Vector3(-0.3, -0.8, 0.5).normalized()]
	for d in town_dirs:
		data.pads.append(PlanetBuildings.town_pad(data, d, 95.0, 70.0))
	for d in landmark_dirs:
		data.pads.append(PlanetBuildings.town_pad(data, d, 30.0, 40.0))
	planet = PlanetBody.new()
	add_child(planet)
	planet.setup(data)
	buildings = PlanetBuildings.new()
	planet.add_child(buildings)
	buildings.setup(planet)
	for d in town_dirs:
		buildings.add_town(d, 6, 30.0, rng)
	buildings.add_landmark(landmark_dirs[0], 80, 80, 900, rng)
	buildings.add_landmark(landmark_dirs[1], 100, 100, 1200, rng)
	buildings.add_landmark(landmark_dirs[2], 80, 80, 700, rng)
	buildings.finish()
	# Trees by biome, streamed round the camera (11.10).
	trees = PlanetTrees.new()
	planet.add_child(trees)
	trees.setup(data)
	trees.prebake()
	# The brick buildings' shapes round the spawn, while it loads (11.11).
	var tpl_ms := buildings.prepare_templates(planet.global_position + data.surface_point(spawn_dir), 400.0)
	Gravity.planet = planet
	Gravity.planet_strength = data.gravity_strength
	Gravity.planet_radius = data.radius
	print("[planet] %s: radius %.0f m, relief %.0f m, sea %.0f m; impostor baked in %d ms; brick shapes %.0f ms" % [
			data.planet_name, data.radius, data.amplitude, data.sea_level, planet.bake_ms, tpl_ms])
	if not "--no-system" in OS.get_cmdline_user_args():
		_build_system()
	_build_light()
	walker = PlanetWalker.new()
	walker.name = "Walker"
	walker.add_to_group(PlanetSystem.RIG)
	walker.camera.far = SEE_FAR
	add_child(walker)
	if system != null:
		system.rig = light
		system.observer = _anchor
		system.eye = _eye
	walker.camera.current = true
	walker.place(planet.global_position + data.surface_point(spawn_dir) + spawn_dir * 1.0,
			east)
	planet.activate()
	# The walker at the origin from the start: the planet's centre is 10 km off.
	PlanetFrame.recentre(self, walker.global_position)
	_build_hud()
	if _gate:
		DebugCamera.hands_off = true
		walker.scripted = true
		var tw := get_node_or_null(^"/root/TestWindow")
		if tw != null:
			tw.use_default_settings()
		if _pawn_gate:
			_run_pawn_gate()
		elif _mech_gate:
			_run_mech_gate()
		elif _tank_gate:
			_run_tank_gate()
		elif _soldier_gate:
			_run_soldier_gate()
		elif _squad_gate:
			_run_squad_gate()
		elif _trees_gate:
			_run_trees_gate()
		elif _bricks_gate:
			_run_bricks_gate()
		elif _damage_gate:
			_run_damage_gate()
		elif _fall_gate:
			_run_fall_gate()
		elif _hits_gate:
			_run_hits_gate()
		elif _topple_gate:
			_run_topple_gate()
		elif _pieces_ai_gate:
			_run_pieces_ai_gate()
		elif _storey_gate:
			_run_storey_gate()
		elif _travel_gate:
			_run_travel_gate()
		elif _far_gate:
			_run_far_gate()
		elif _drive_gate:
			_run_drive_gate()
		elif _light_gate:
			_run_light_gate()
		elif _system_gate:
			_run_system_gate()
		elif _ship_gate:
			_run_ship_gate()
		elif _dock_gate:
			_run_dock_gate()
		elif _worlds_gate:
			_run_worlds_gate()
		elif _jump_gate:
			_run_jump_gate()
		elif _debris_gate:
			_run_debris_gate()
		elif _adrift_gate:
			_run_adrift_gate()
		elif _falling_gate:
			_run_falling_gate()
		elif _rocks_gate:
			_run_rocks_gate()
		elif _garrison_gate:
			_run_garrison_gate()
		elif _seat_gate:
			_run_seat_gate()
		elif _hull_gate:
			_run_hull_gate()
		elif _home_gate:
			_run_home_gate()
		elif _save_gate:
			_run_save_gate()
		elif _belt_gate:
			_run_belt_gate()
		else:
			_run_gate()


## A round or a blast at a building's bricks (GunController.on_structure_hit):
## the planet's buildings take it (11.11 D1).
func _structure_hit(point: Vector3, _dir: Vector3, shot: Dictionary) -> void:
	if system != null:
		# A station's or ship's bricks first: the planet's are asleep under them.
		for s in system.ships:
			if s.damage(point, shot):
				return
		if system.station != null and system.station.damage(point, shot):
			return
	_buildings_here().damage(point, shot)


## The buildings of the world the player is on.
func _buildings_here() -> PlanetBuildings:
	var b := system.buildings_here() if system != null else null
	return b if b != null else buildings


## The ship ran into something at speed: it is blasted there.
func _on_rammed(point: Vector3, speed: float) -> void:
	var shot := {"blast": true, "radius": clampf(speed * 0.15, 1.5, 5.0), "hp": 0}
	if system.station != null and system.station.damage(point, shot):
		return
	_buildings_here().damage(point, shot)


## The pawn, its controller, camera, gun and arms, standing at `feet`, looking
## along `facing` (tangent). Built once; placed again after a flight.
func _spawn_player(feet: Vector3, facing: Vector3) -> void:
	cam = DebugCamera.new()
	cam.name = "Camera"
	cam.capture_mouse = false
	cam.allow_walk = false
	cam.far = SEE_FAR
	cam.add_to_group(PlanetSystem.RIG)
	add_child(cam)
	cam.set_process(false)
	pawn = Pawn.spawn(self, feet, 0)
	pawn.body.add_to_group(PlanetSystem.RIG)
	pawn.moves = PawnMoves.new(pawn)
	player = PlayerController.new()
	player.name = "Player"
	player.drive_uncaptured = _gate
	add_child(player)
	player.possess(pawn, cam)
	gun = GunController.new()
	gun.name = "Gun"
	gun.rng = RandomNumberGenerator.new()
	gun.rng.seed = 0xC0FFEE
	gun.aim = cam
	add_child(gun)
	view = PlayerView.new()
	view.name = "PlayerView"
	add_child(view)
	view.setup(cam, pawn, gun)
	player.view = view
	var gi := GunInstance.from_result(GunGenerator.generate(GunPlaceholderParts.build_library(), 7,
			WeaponClass.builtin(&"rifle"), 1))
	gun.equip(gi)
	view.hold(gi)
	pawn.gun = gun
	gun.exclude = [pawn.body.get_rid()] as Array[RID]
	gun.on_structure_hit = _structure_hit
	gun.add_to_group(PlanetSystem.RIG)
	_face(facing)
	_set_on_foot(true)
	# The AI it fights: the town's region (11.8 N2), unless a gate sets up its own.
	if ai == null and not _gate:
		setup_ai(town_dirs[0])
		_home_garrison()
	var s := ai
	if s == null:
		s = AIServices.new()
		s.world3d = get_world_3d()
	kit = PlanetPlayerKit.attach(self, player, cam, gun, view, s, _gate)
	kit.add_to_group(PlanetSystem.RIG)
	pawn.health.died.connect(_on_player_down)


## The player is down: up again in a moment, beside the ship if it is on the same
## ground, or where they fell.
func _on_player_down() -> void:
	await get_tree().create_timer(DOWN_FOR).timeout
	var at := pawn.feet()
	if ship != null and ship.landed and ship.ref == system.anchor:
		var beside := ship.global_transform * Vector3(BESIDE_SHIP, 2.0, 0.0)
		var ground := _ground_hit(beside)
		if ground != Vector3.INF:
			at = ground
	pawn.health.reset()
	pawn.place(at + Gravity.up_at(at) * 0.05)


## Home's town holds soldiers too, who come back in waves. It wakes nearer than a
## generated world's, so that the spawn stays quiet (the town is 220 m from it).
func _home_garrison() -> void:
	var g := PlanetGarrison.new()
	g.name = "Garrison"
	g.setup(self, planet, cleared)
	g.raise_at = HOME_RAISE_AT
	g.waves = true
	g.ai_town = 0
	add_child(g)
	garrisons[planet] = g
	if saver != null:
		saver.apply_garrison(planet, g)


## Colliders can go from under a body as the ground streams, and a planet has no
## inside to land on: a pawn found under body `b`'s ground is put back on it.
func keep_over_ground(p: Pawn, b: PlanetBody) -> void:
	var f := p.feet()
	var dir := b.dir_of(f)
	if b.altitude_of(f) < b.data.height(dir) - UNDER_GROUND:
		var at := b.global_transform * b.data.surface_point(dir)
		p.place(at + Gravity.up_at(at) * 0.5)
		ground_saves += 1


## Turn the camera, in the pawn's frame, to look along `facing`.
func _face(facing: Vector3) -> void:
	var fr := pawn.body.global_transform.basis.orthonormalized()
	cam.set_frame(fr)
	var local := fr.inverse() * facing
	cam.global_transform.basis = fr * Basis.from_euler(Vector3(0.0, atan2(-local.x, -local.z), 0.0))


## On foot (the pawn and its camera) or flying (the walker). The voxel viewer
## goes with whichever it is, so the ground streams round the player.
func _set_on_foot(on: bool, stand_at := Vector3.INF) -> void:
	if not on and pawn != null and pawn.ghost != null:
		_ghost_off()
	on_foot = on
	# The pawn left behind while flying is not there to be shot.
	if kit != null:
		kit.present(on)
	var viewer := walker.viewer
	if on:
		var feet := stand_at if stand_at != Vector3.INF else _ground_hit(walker.global_position)
		if feet == Vector3.INF:
			feet = walker.global_position
		var fwd := -walker.camera.global_transform.basis.z
		pawn.body.process_mode = Node.PROCESS_MODE_INHERIT
		pawn.place(feet + Gravity.up_at(feet) * 0.05)
		if not player.is_possessing():
			player.possess(pawn, cam)
		cam.current = true
		_face(Gravity.flat(fwd, Gravity.up_at(feet)).normalized())
		walker.process_mode = Node.PROCESS_MODE_DISABLED
		walker.collision_layer = 0
		walker.collision_mask = 0
		viewer.reparent(pawn.body, false)
		view.rig.visible = true
	else:
		var at := pawn.feet() + pawn.up * 0.3
		walker.process_mode = Node.PROCESS_MODE_INHERIT
		walker.collision_layer = 1
		walker.collision_mask = 1 | Layers.STRUCTURE
		walker.place(at, -cam.global_transform.basis.z)
		walker.flying = true
		walker.frozen = false
		walker.camera.current = true
		player.release()
		viewer.reparent(walker, false)
		view.rig.visible = false


## The map, opened (11.12 step 5).
func open_map() -> void:
	map.open(system.universe, system.system_index, system._home_sys, system.jump_block())


## The scene again, in universe `id`, this one saved first.
func _play_universe(id: String) -> void:
	universes.visible = false
	if saver == null or id == saver.save.universe_id or id == "":
		return
	saver.save_now()
	UniverseSave.active_id = id
	get_tree().reload_current_scene()


## Saved before a menu takes the scene away (BrickcityMenuHost).
func before_leaving() -> void:
	if saver != null:
		saver.save_now()


## A dark screen over coming back to where the save was.
func veil(on: bool) -> void:
	_flash.color = Color(0, 0, 0, 1) if on else Color(1, 1, 1, 0)


## Jump to the map's pick, the screen white over the swap.
func map_jump() -> void:
	if not system.can_jump():
		return
	map.visible = false
	_flash.color.a = 1.0
	await _frames(2)
	if system.jump(map.chosen()):
		var tw := create_tween()
		tw.tween_property(_flash, "color:a", 0.0, 0.6)
	else:
		_flash.color.a = 0.0


## The ship's and the map's keys. True if `key` was theirs.
func _ship_key(key: Key) -> bool:
	if universes.visible:
		match key:
			KEY_UP:
				universes.move(-1)
			KEY_DOWN:
				universes.move(1)
			KEY_ENTER:
				_play_universe(universes.chosen())
			KEY_N:
				_play_universe(universes.new_universe())
			KEY_U, KEY_ESCAPE:
				universes.visible = false
		return true
	if map.visible:
		if key == KEY_U and saver != null:
			map.visible = false
			universes.open(saver.save.universe_id, saver.save.root)
			return true
		match key:
			KEY_UP:
				map.move(-1)
			KEY_DOWN:
				map.move(1)
			KEY_J, KEY_ENTER:
				map_jump()
			KEY_M, KEY_ESCAPE:
				map.visible = false
		return true
	if key == KEY_M:
		open_map()
		return true
	if key == KEY_G and system != null:
		# The gravity generator of the ship or station the player is in (7.12).
		var gen := system.generator_at(_anchor())
		if gen != null:
			gen.set_gravity(not gen.data.gravity_on)
			return true
	if key == KEY_E:
		if piloting:
			unboard()
		elif (_anchor() - ship.global_transform * ship.seat()).length() < 8.0:
			board()
		elif on_foot and pawn != null:
			_through_airlock()
		return true
	return false


## On foot at a generated ship's airlock (its sill can stand metres over the
## ground): E steps through it, in onto the deck or out onto the ground.
func _through_airlock() -> void:
	var lock := ship.airlock_cell
	if lock.x < 0 or not ship.bricked:
		return
	var door := ship.global_transform * ((ship.cell_point(lock) + ship.cell_point(lock + Vector3i(0, 0, 1))) * 0.5)
	var inside := ship.global_transform * ((ship.cell_point(lock + Vector3i(3, 0, 0)) + ship.cell_point(lock + Vector3i(3, 0, 1))) * 0.5)
	var outward := (door - inside).normalized()
	var feet := pawn.feet()
	var rel := feet - door
	var up := Gravity.up_at(door)
	var aside := (rel - outward * rel.dot(outward) - up * rel.dot(up)).length()
	if aside > 2.5 or rel.dot(up) > 1.0 or rel.dot(up) < -8.0 or absf(rel.dot(outward)) > 4.0:
		return
	if rel.dot(outward) > 0.0:
		pawn.place(inside + up * 0.05)
		_face(Gravity.flat(-outward, up).normalized())
	else:
		var out := _ground_hit(door + outward * 2.5)
		if out != Vector3.INF:
			pawn.place(out + up * 0.05)
			_face(Gravity.flat(outward, up).normalized())


func _unhandled_input(event: InputEvent) -> void:
	if ship != null and not _gate:
		if event is InputEventKey and event.pressed and not event.echo and _ship_key(event.keycode):
			get_viewport().set_input_as_handled()
			return
		if piloting and event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_mouse_steer += event.relative
			return
	if pawn == null or _gate:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		_set_on_foot(not on_foot)
		get_viewport().set_input_as_handled()


## When the pawn left the seat, waiting for the ship's bricks (-1: not waiting).
var _stepping_out := -1
const STEP_OUT_WAIT := 2000


## Who the origin, the streaming and the sky follow.
func _anchor() -> Vector3:
	# At the controls: the seat, where the ship is this frame (not where the
	# walker was put last frame -- 340 m back at 20 km/s).
	if piloting:
		return ship.global_transform * ship.seat()
	return _pawn_real() if on_foot else walker.global_position


## Where the pawn really is: its body's place, or, aboard a ghost hull, the real
## ship's place for it (Docs/Hulls.md 7b).
func _pawn_real() -> Vector3:
	if pawn.ghost != null and is_instance_valid(pawn.ghost):
		return (pawn.ghost as SpaceStation).ghost_to_real() * pawn.body.global_position
	return pawn.body.global_position


## The ghost hull (Docs/Hulls.md 7b): on foot in a generated ship flown over a
## world (riding: its bricks have no collision of their own), the pawn walks its
## ghost; off it when the ship is at rest again (its bricks solid) or the pawn has
## left it (out through a hole, off the deck).
func _ghost_tick() -> void:
	var st := pawn.ghost as SpaceStation
	if st != null and is_instance_valid(st):
		if st.riding and st.chunk >= 0 and st.ghost != null and st.ghost_holds(pawn.body.global_position):
			return
		_ghost_off()
	# Onto a riding ship's ghost -- from the world, or straight from another's (two
	# docked: ghost to ghost, Docs/Hulls.md 7b).
	var feet := pawn.feet()
	for s in system.ships:
		if s != st and s.riding and s.ghost != null and s.holds(feet):
			_ghost_on(s)
			return


func _ghost_on(s: SpaceStation) -> void:
	GhostHulls.board(pawn.body, s)
	pawn.ghost = s
	# The ground streams round the real ship, not round the ghost's slot.
	walker.viewer.reparent(cam, false)
	walker.viewer.position = Vector3.ZERO
	print("[ghost] aboard %s's ghost" % s.data.orbital_name)


func _ghost_off() -> void:
	var st := pawn.ghost as SpaceStation
	pawn.ghost = null
	if st != null and is_instance_valid(st):
		GhostHulls.get_off(pawn.body, st, get_world_3d().space)
		print("[ghost] off %s's ghost at %.1f m/s" % [st.data.orbital_name, pawn.body.velocity.length()])
	walker.viewer.reparent(pawn.body, false)
	walker.viewer.position = Vector3.ZERO


func _eye() -> Vector3:
	if piloting:
		return ship.camera.global_position
	return cam.global_position if on_foot else walker.camera.global_position


## Into the ship's seat (11.12 step 3): the walker frozen in it, its chase camera.
func board() -> void:
	if pawn != null and pawn.ghost != null:
		_ghost_off()
	if on_foot:
		_set_on_foot(false)
	piloting = true
	walker.frozen = true
	walker.flying = false
	walker.inertia = Vector3.ZERO
	ship.piloted = true
	ship.landed = false
	ship.camera.current = true


func _clear_seat() -> void:
	piloting = false
	ship.piloted = false
	ship.thrust = Vector3.ZERO
	ship.steer = Vector3.ZERO
	ship.boost = false


## Off the pawn and out of the seat, the walker's: a save being gone back to.
func step_off() -> void:
	if piloting:
		_clear_seat()
		walker.camera.current = true
	if on_foot:
		_set_on_foot(false)


## Out of the seat, standing on the ship's floor, wherever it is: on foot, once
## there is a pawn. In a planet's shell the ship stops dead (its deck is not a frame
## there, nothing carries who stands on it), and it is a solid shell until its
## bricks are in, so the pawn waits for them (_process).
func unboard() -> void:
	_clear_seat()
	# Over a world, a ship with no ghost stops dead (nothing would carry who stands
	# on it); one with its ghost glides to rest under them (Docs/Hulls.md 7b).
	if ship.ref != null and (ship.ghost == null or not ship.riding):
		ship.vel = Vector3.ZERO
	var at := ship.global_transform * ship.seat() + ship.global_basis.y * 0.1
	walker.place(at, -ship.global_basis.z)
	walker.frozen = false
	walker.flying = false
	walker.camera.current = true
	if pawn != null:
		_set_on_foot(true, at)
		pawn.body.process_mode = Node.PROCESS_MODE_DISABLED
		_stepping_out = Time.get_ticks_msec()


## The pilot's keys and mouse: W/S ahead and back, A/D aside, Space/Ctrl up and
## down, the mouse to turn, Z/C to roll, Shift to cruise.
func _pilot_input() -> void:
	ship.thrust = Vector3(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
			float(Input.is_key_pressed(KEY_SPACE)) - float(Input.is_key_pressed(KEY_CTRL)),
			float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
	ship.steer = Vector3(clampf(-_mouse_steer.x * 0.05, -1.0, 1.0), clampf(-_mouse_steer.y * 0.05, -1.0, 1.0),
			float(Input.is_key_pressed(KEY_C)) - float(Input.is_key_pressed(KEY_Z)))
	_mouse_steer = Vector2.ZERO
	ship.boost = Input.is_key_pressed(KEY_SHIFT)


## Cameras reach this far; what is further is drawn nearer (PlanetSystem's
## scaled space).
const SEE_FAR := PlanetSystem.SEE_FAR


## The star system round the planet (Planets.md 11.12): system 0 of the
## universe, the planet on its habitable orbit, the spawn at noon in summer. Every gate
## but the system's own runs with the clock stopped.
func _build_system() -> void:
	var save: UniverseSave = null
	if _save_gate and "--stage=1" in OS.get_cmdline_user_args():
		UniverseSave.wipe(UniverseSave.TEST_ROOT)
	if _save_gate or not _gate:
		save = UniverseSave.current(UniverseSave.TEST_ROOT if _save_gate else UniverseSave.ROOT)
	var uni := Universe.new(save.seed_value if save != null else 1)
	var sys := uni.system(0, data)
	sys.best_season(sys.home, spawn_dir)
	data.spin_phase = sys.noon_phase(sys.home, spawn_dir, 0.0)
	system = PlanetSystem.new()
	add_child(system)
	system.setup(sys, planet)
	system.universe = uni
	system.built[planet] = buildings
	system.frozen = _gate and not (_system_gate or _dock_gate or _falling_gate)
	# Set here, not before: home is not one of the generated worlds to settle.
	data.towns.assign(town_dirs)
	system.anchor_changed.connect(_on_anchor_changed)
	system.woke.connect(_on_woke)
	system.jumped.connect(_on_jumped)
	# A ship parked 45 m behind the spawn (not in the other gates' way).
	if not _gate or _ship_gate or _dock_gate or _jump_gate or _rocks_gate or _garrison_gate or _seat_gate or _belt_gate or _hull_gate or _save_gate or _falling_gate:
		var sd := OrbitalData.new()
		sd.kind = "ship"
		sd.orbital_name = "ship"
		sd.fx = 24
		sd.fz = 36
		sd.courses = 6
		# In play a generated ship: a hull with its rooms (Docs/RoomModules.md 7.5);
		# the gates keep the plain one they were written round.
		if not _gate or _hull_gate:
			sd.layout = "generated"
			sd.orbital_seed = 7
		var east := spawn_dir.cross(Vector3.FORWARD).normalized()
		var at := _round_dir(spawn_dir, -east, 45.0)
		var x := (-east - at * (-east).dot(at)).normalized()
		ship = system.add_ship(sd, planet, Transform3D(Basis(at.cross(x), at, x), data.surface_point(at) + at * SpaceShip.CLEARANCE))
		ship.rammed.connect(_on_rammed)
		# Colliders where it sets down, to step out onto.
		PlanetBody.track(ship)
	if save != null:
		saver = PlanetSaver.new()
		saver.name = "Saver"
		add_child(saver)
		saver.setup(self, save)
		saver.apply_trees(planet, trees)
	print("[planet] system %s: %d bodies, the planet at %.0f km, a %.0f min day, a %.0f min year" % [
			sys.system_name, sys.bodies.size(), data.orbit_radius / 1000.0, data.day / 60.0, data.orbit_period / 60.0])


## The planet the player is on or nearest: the streaming, the sky and the HUD follow it.
func _body() -> PlanetBody:
	if system == null:
		return planet
	return system.anchor if system.anchor != null else system.nearest(_anchor())


## The home planet is the anchor: its AI runs, its caches follow the origin.
func _home_awake() -> bool:
	return system == null or system.anchor == planet


## The AI is the world the player is on's: it runs, its nav follows the origin.
func _ai_awake() -> bool:
	return ai != null and (system == null or ai_of.get(system.anchor) == ai)


## The player takes up the AI of world `b`, if it has one.
func _ai_follow(b: Node3D) -> void:
	var s: AIServices = ai_of.get(b)
	if s == null:
		return
	ai = s
	if kit != null:
		kit.use_services(s)


func _on_anchor_changed(_old: Node3D, _new: Node3D, kick: Vector3) -> void:
	if walker.flying:
		walker.inertia += kick
	else:
		walker.velocity += kick
	if pawn != null and not on_foot:
		pawn.body.process_mode = Node.PROCESS_MODE_DISABLED


func _on_woke(body: Node3D, offset: Vector3) -> void:
	if body == planet:
		buildings.on_origin_shift()
	var s: AIServices = ai_of.get(body)
	if s != null:
		(s.nav_net as PlanetNavNet).shift_origin(offset)
	_ai_follow(body)
	if garrisons.has(body):
		(garrisons[body] as PlanetGarrison).hold()
	elif body is PlanetBody and body != planet and not (body as PlanetBody).data.towns.is_empty():
		var g := PlanetGarrison.new()
		g.name = "Garrison"
		g.setup(self, body, cleared)
		add_child(g)
		garrisons[body] = g
		if saver != null:
			saver.apply_garrison(body, g)
	if saver != null and body is PlanetBody and body != planet and system.trees_of.has(body):
		saver.apply_trees(body, system.trees_of[body])


## What was left in the last system went with it.
func _on_jumped(_index: int) -> void:
	for b in ai_of.keys():
		if b != planet:
			ai_of.erase(b)
	for b in garrisons.keys():
		if b != planet:
			garrisons.erase(b)
	ai = ai_of.get(planet)
	_ai_follow(planet)


func _build_light() -> void:
	light = LightRig.new()
	light.build(self, system != null)
	sun = light.sun
	env = light.env
	sky_mat = light.sky_mat
	sun.look_at_from_position(Vector3.ZERO, -planet.sun_dir, Vector3.UP if absf(planet.sun_dir.y) < 0.99 else Vector3.FORWARD)


## A ship or station this near the camera is on the brick grid (its lamps).
const SHIP_GRID_NEAR := 300.0


## The clouds of `body` (Docs/Lighting.md 2b): a world with air has a layer,
## made when the camera comes to it; one without, none. Gates hold them still.
func _clouds_for(body: PlanetBody) -> void:
	CloudLayer.still = _gate
	if clouds != null and is_instance_valid(clouds) and clouds.body == body:
		return
	if clouds != null and is_instance_valid(clouds):
		clouds.queue_free()
	clouds = null
	if body != null and body.data.has_air:
		clouds = CloudLayer.for_planet(light, body, body.data.radius, body.data.peak(),
				body.data.planet_seed)


## Ambient boxes (Docs/Lighting.md 6.2), twice a second: one inside each
## building laid in bricks here, and in each station or ship module laid; a
## toppled building's goes.
func _ambient_boxes() -> void:
	var now := Time.get_ticks_msec()
	if now - _boxes_at < 500:
		return
	_boxes_at = now
	for key in _box_of.keys():
		var p = _box_of[key]
		if not is_instance_valid(p):
			_box_of.erase(key)
	var pb := _buildings_here()
	if pb != null:
		var stud := BrickPalette.STUD_M
		if not pb.brick_material.has_meta(&"grid_light"):
			pb.brick_material.set_meta(&"grid_light", true)
			grid_light.bind(pb.brick_material)
		for i in pb.sites.size():
			var st = pb.sites[i]
			var key := "%d:%d" % [pb.get_instance_id(), i]
			if st.toppled or not st.bricked or st.brick_node == null:
				grid_light.release(key)
			elif not grid_light.tracked(key):
				grid_light.track(key, pb.bricks, st.chunk, st.brick_node)
			if st.toppled:
				if _box_of.has(key):
					(_box_of[key] as Node).queue_free()
					_box_of.erase(key)
				continue
			if st.bricked and st.brick_node != null and not _box_of.has(key):
				_box_of[key] = light.add_box(st.brick_node, Vector3.ZERO,
						Vector3(st.fx * stud, st.height, st.fz * stud), "room")
	if system == null:
		return
	var viewer := get_viewport().get_camera_3d()
	var cam_at := viewer.global_position if viewer != null else Vector3.ZERO
	var mods: Array = []
	mods.append_array(system.stations)
	mods.append_array(system.ships)
	for m in mods:
		var st := m as SpaceStation
		if st == null or not is_instance_valid(st) or st.chunk < 0:
			continue
		var bn := st.get_node_or_null("Bricks") as Node3D
		var key := "m%d" % st.get_instance_id()
		# Its Glow bricks light it (the grid's lamps, BrickGridLight); its
		# sky is left alone: the cabin box stands for its own lights.
		if bn != null and st.brick_material != null and bn.global_position.distance_to(cam_at) < SHIP_GRID_NEAR:
			if not st.brick_material.has_meta(&"grid_light"):
				st.brick_material.set_meta(&"grid_light", true)
				grid_light.bind(st.brick_material, false)
			if not grid_light.tracked(key):
				grid_light.track(key, st.bricks, st.chunk, bn)
		else:
			grid_light.release(key)
		if bn != null and not _box_of.has(key):
			var stud := BrickWorld.get_stud_metres()
			_box_of[key] = light.add_box(bn, Vector3.ZERO,
					Vector3(st.data.fx * stud, st.height, st.data.fz * stud), "cabin")


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	hud = Label.new()
	# Under the kit's line of controls (PlayerHud), over its aggro meter.
	hud.position = Vector2(14, 120)
	hud.add_theme_font_size_override("font_size", 13)
	hud.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(hud)
	air_warn = Label.new()
	air_warn.set_anchors_preset(Control.PRESET_CENTER_TOP)
	air_warn.position = Vector2(-160, 60)
	air_warn.size = Vector2(320, 30)
	air_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	air_warn.add_theme_font_size_override("font_size", 22)
	air_warn.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
	air_warn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	air_warn.add_theme_constant_override("outline_size", 6)
	air_warn.visible = false
	layer.add_child(air_warn)
	add_child(layer)
	if system != null:
		var over := CanvasLayer.new()
		over.layer = 10
		add_child(over)
		markers = SpaceMarkers.new()
		markers.system = system
		markers.mouse_filter = Control.MOUSE_FILTER_IGNORE
		markers.set_anchors_preset(Control.PRESET_FULL_RECT)
		over.add_child(markers)
		universes = UniversePanel.new()
		universes.visible = false
		universes.set_anchors_preset(Control.PRESET_FULL_RECT)
		over.add_child(universes)
		map = GalaxyMap.new()
		map.visible = false
		map.set_anchors_preset(Control.PRESET_FULL_RECT)
		over.add_child(map)
		_flash = ColorRect.new()
		_flash.color = Color(1, 1, 1, 0)
		_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
		over.add_child(_flash)
		# A saved game opens dark until PlanetSaver.resume has the player back:
		# the spawn is only where the scene starts, not where they are.
		if saver != null and saver.state.get("at") != null:
			veil(true)


## The air where the player is (a ship's or station's, Docs/Hulls.md 4): pulled toward a
## hole while it rushes out, warned when it runs low.
func _air_tick() -> void:
	var a := system.air_at(walker.global_position + walker.up * 1.0, true)
	walker.push = a.get("pull", Vector3.ZERO)
	if air_warn == null:
		return
	var p := float(a.get("pressure", 1.0))
	var venting := bool(a.get("venting", false))
	air_warn.visible = not a.is_empty() and (p < HullAir.LOW or venting)
	if air_warn.visible:
		air_warn.text = ("HULL BREACH  air %d%%" if venting else "LOW AIR  %d%%") % roundi(p * 100.0)


## The restore tool, held: what the view points at on a ship or station.
func _restore_tick(dt: float) -> void:
	var holding := InputMap.has_action(&"restore") and Input.is_action_pressed(&"restore") 			and not walker.frozen and cam != null
	if not holding and restore_tool.target == null:
		return
	var sts: Array = system.stations.duplicate()
	for s in system.ships:
		if not sts.has(s):
			sts.append(s)
	restore_tool.tick(dt, holding, cam.global_position, -cam.global_basis.z, sts,
			get_world_3d().direct_space_state)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_us > 0:
		var ms := float(now - _last_us) / 1000.0
		_worst_ms = maxf(_worst_ms, ms)
		if ms > 40.0 and _hitches.size() < 40:
			_hitches.append([snappedf(ms, 0.1), int(planet.altitude_of(_anchor()))])
		if ms > 40.0 and not walker.frozen and _play_hitches.size() < 40:
			_play_hitches.append([snappedf(ms, 0.1), int(planet.altitude_of(_anchor()))])
	_last_us = now
	var cam_pos := _eye()
	var body := _body()
	var alt := body.altitude_of(cam_pos)
	# The origin follows the player, by translation, every SHIFT_AT. A planet
	# asleep (11.12) is moved with its node; its caches wait for it to wake.
	if _anchor().length() > PlanetFrame.SHIFT_AT:
		var offset := PlanetFrame.recentre(self, _anchor())
		if _home_awake():
			buildings.on_origin_shift()
		if _ai_awake():
			(ai.nav_net as PlanetNavNet).shift_origin(offset)
		if system != null:
			system.on_origin_shift()
	if system != null:
		walker.match_velocity = system.match_velocity(walker.global_position)
		_air_tick()
		_restore_tick(_delta)
		walker.reach = body.altitude_of(walker.global_position)
	if _stepping_out >= 0 and (ship.bricked or Time.get_ticks_msec() - _stepping_out > STEP_OUT_WAIT):
		_stepping_out = -1
		pawn.place(ship.global_transform * ship.seat() + ship.global_basis.y * 0.1)
		pawn.body.process_mode = Node.PROCESS_MODE_INHERIT
	if system != null and pawn != null and on_foot:
		_ghost_tick()
	if piloting:
		walker.global_position = ship.global_transform * ship.seat()
		walker.inertia = Vector3.ZERO
		if not _gate:
			_pilot_input()
	# Stream the voxel ground to the horizon and the peaks behind it, no further.
	var want := body.horizon_reach(cam_pos, body.data.peak()) + VIEW_MARGIN
	var q := clampi(int(ceil(want / VIEW_STEP)) * VIEW_STEP, VIEW_MIN, VIEW_MAX)
	if q != walker.viewer.view_distance:
		walker.viewer.view_distance = q
	# The sky goes to black as the air thins (to ~the impostor's band).
	var air := 1.0 - clampf(alt / (body.data.radius * 0.12), 0.0, 1.0) if body.data.has_air else 0.0
	# Day and night (11.12): the sky by the sun's height, with twilight; the
	# ambient down to starlight. Its own air's colour, tamed (Docs/Lighting.md 3).
	var day := 1.0
	var sun_h := 1.0
	if system != null:
		day = smoothstep(-0.18, 0.12, system.sun_height) if air > 0.0 else system.sunlight
		sun_h = system.sun_height
	var viewer := get_viewport().get_camera_3d()
	grid_light.step()
	var open := grid_light.at(viewer.global_position if viewer != null else cam_pos).x
	light.room_open = open if open < 0.0 or light.room_open < 0.0 else lerpf(light.room_open, open,
			clampf(get_process_delta_time() * 4.0, 0.0, 1.0))
	light.set_sky(day, air, body.data.atmosphere_color, sun_h, Gravity.up_at(cam_pos))
	_clouds_for(body)
	_ambient_boxes()
	light.expose(viewer.global_position if viewer != null else cam_pos, get_process_delta_time())
	# Hold the walker until the ground under it has streamed (and has a
	# collider) and the trees' cards are baked; then, unless this is the
	# walker's own gate, the pawn stands on it.
	if walker.frozen and not piloting and pawn == null and trees.prebaked and _ground_hit(walker.global_position) != Vector3.INF:
		walker.frozen = false
		if not _gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate or _squad_gate or _travel_gate or _far_gate or _drive_gate or _trees_gate or _bricks_gate or _damage_gate or _fall_gate or _hits_gate or _topple_gate or _pieces_ai_gate or _storey_gate or _garrison_gate or _seat_gate or _home_gate or _hull_gate or _save_gate or _light_gate:
			_spawn_player(_ground_hit(walker.global_position), -walker.global_transform.basis.z)
			if saver != null:
				saver.resume()
	if not on_foot:
		walker.flying = pawn != null or walker.flying
	elif pawn != null:
		keep_over_ground(pawn, body)
	# Not while standing about on a world, or looking at the map.
	if markers != null:
		markers.visible = (piloting or not on_foot) and not map.visible
	# The gun's HUD is for the one holding it.
	if kit != null:
		kit.hud.visible = not piloting
	if hud != null:
		var mode := "on foot (F flies)" if on_foot else ("FLY %.0f m/s (F lands)" % walker.fly_speed if walker.flying else "walk")
		var here := "" if system != null and system.buildings_here() == null else "  buildings %d near, %d far" % [_buildings_here().near_count, _buildings_here().far_count]
		hud.text = "%s  alt %.0f m  %.0f fps  view %d  shifts %d (last %.1f ms)%s  %s" % [
				"at the controls" if piloting else mode, alt,
				Engine.get_frames_per_second(), walker.viewer.view_distance, PlanetFrame.shifts,
				PlanetFrame.last_us / 1000.0, here,
				"(waiting for ground)" if walker.frozen and not piloting else ""]
		var gen := system.generator_at(_anchor()) if system != null else null
		if gen != null and not piloting:
			hud.text += "
GRAVITY %s  (G turns it %s)" % ["on" if gen.pulls() else "off", "off" if gen.data.gravity_on else "on"]
		elif system != null and not piloting and not Gravity.pulls_at(_anchor()):
			hud.text += "
NOTHING PULLS  (WASD, Space/Ctrl: the suit's thrust)"
		if piloting:
			hud.text += "\nSHIP  %.0f m/s  %.0f m over the ground  (E leaves the seat; WASD, Space/Ctrl, mouse, Z/C roll, Shift cruise; M galaxy map)" % [
					ship.vel.length(), ship.altitude]
			hud.text += "\n" + ("Open space: a jump can be made" if system.can_jump() else system.jump_block())
		elif ship != null and (_anchor() - ship.global_transform * ship.seat()).length() < 8.0:
			hud.text += "\nE: take the ship's controls"
		if system != null:
			var g: PlanetGarrison = garrisons.get(system.anchor)
			if g != null and g.status() != "":
				hud.text += "\n" + g.status()
			var h := system.hour_at(_anchor())
			hud.text += "\n%s  %s  %02d:%02d  sun %.0f%%  t %.0f s%s" % [system.sys.system_name,
					PlanetSystem.name_of(system.frame_node()) if system.frame_node() != null else "space, near " + body.data.planet_name,
					int(h), int(fmod(h, 1.0) * 60.0), system.sunlight * 100.0, system.t, "  (clock stopped)" if system.frozen else ""]


## `dir` carried `metres` along the surface toward `toward` (tangent).
func _round_dir(dir: Vector3, toward: Vector3, metres: float) -> Vector3:
	var axis := dir.cross(toward).normalized()
	return dir.rotated(axis, metres / data.radius).normalized()


## A ray down from 50 m over `world` to the ground's collider: the hit, or INF.
func _ground_hit(world: Vector3) -> Vector3:
	var up := Gravity.up_at(world)
	var q := PhysicsRayQueryParameters3D.create(world + up * 50.0, world - up * 60.0)
	q.exclude = [walker.get_rid()] if pawn == null else [walker.get_rid(), pawn.body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return Vector3.INF if hit.is_empty() else hit.position


# ---------------------------------------------------------------------------
# The gate.

var _ok := 0
var _fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		_ok += 1
	else:
		_fail += 1
	print("  %s %s%s" % ["ok  " if cond else "FAIL", what, (" -- " + detail) if detail else ""])


## The mean luminance of the picture on screen now (windowed only).
func _screen_mean() -> float:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(64, 36, Image.INTERPOLATE_BILINEAR)
	var sum := 0.0
	for y in 36:
		for x in 64:
			sum += img.get_pixel(x, y).get_luminance()
	return sum / (64.0 * 36.0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % name)
	print("[planet] shot written: %s.png" % name)


func _run_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var wait_s := (Time.get_ticks_msec() - t0) / 1000.0
	_check("the ground under the spawn streams in (< 20 s)", not walker.frozen and wait_s < 20.0, "%.1f s" % wait_s)
	await get_tree().create_timer(2.0).timeout
	await _shot("planet_gate_ground")
	# The town, from 90 m up behind the spawn.
	if DisplayServer.get_name() != "headless":
		var town: Vector3 = planet.global_position + data.surface_point(town_dirs[0])
		var up0 := Gravity.up_at(town)
		var over := Camera3D.new()
		over.far = 20000.0
		add_child(over)
		var back := (walker.global_position - town)
		back = (back - up0 * back.dot(up0)).normalized()
		over.look_at_from_position(town + back * 260.0 + up0 * 90.0, town + up0 * 10.0, up0)
		over.current = true
		await _frames(30)
		await _shot("planet_gate_town")
		walker.camera.current = true
		over.queue_free()
	# Walk 30 s forward.
	var start := walker.global_position - planet.global_position
	var air_ticks := 0
	var ticks := 0
	walker.wish = Vector2(0, 1)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 30000:
		await get_tree().physics_frame
		ticks += 1
		if not walker.is_on_floor():
			air_ticks += 1
	walker.wish = Vector2.ZERO
	var walked := (walker.global_position - planet.global_position).normalized().angle_to(start.normalized()) * data.radius
	_check("walks on the voxel ground (feet down > 97% of ticks)", air_ticks < ticks * 0.03, "%d of %d off, %.0f m walked" % [air_ticks, ticks, walked])
	var h := planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))
	_check("stands ON the ground the CPU says is there (within 0.3 m)", absf(h) < 0.3, "%.2f m" % h)
	# A low cruise toward the first landmark, 2.6 km off: it and the town's
	# towers come up over the horizon ahead.
	walker.flying = true
	walker.pitch = 0.0
	var lm: Vector3 = planet.global_position + data.surface_point(landmark_dirs[0])
	var to_lm := lm - walker.global_position
	walker.place(walker.global_position, to_lm)
	var near_seen := 0
	var t_c := Time.get_ticks_msec()
	var shot_mid := false
	while Time.get_ticks_msec() - t_c < 32000:
		var over := planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))
		walker.fly_speed = 70.0
		walker.wish = Vector2(0, 1)
		walker.rise = clampf((25.0 - over) * 0.1, -1.0, 1.0)
		await get_tree().physics_frame
		near_seen = maxi(near_seen, buildings.near_count)
		if not shot_mid and Time.get_ticks_msec() - t_c > 9000:
			shot_mid = true
			await _shot("planet_gate_cruise")
	walker.wish = Vector2.ZERO
	walker.rise = 0.0
	await _shot("planet_gate_landmark")
	_check("the near tier: shells were built near the town", near_seen > 0, "%d at most" % near_seen)
	# Fly up to 30 km, looking down at the ground ahead.
	walker.flying = true
	walker.pitch = -0.9
	var marks := {300.0: "planet_gate_300m", 1200.0: "planet_gate_1200m", 5000.0: "planet_gate_5km", 30000.0: "planet_gate_30km"}
	var reached := 0.0
	var t2 := Time.get_ticks_msec()
	while reached < 30000.0 and Time.get_ticks_msec() - t2 < 120000:
		var alt := planet.altitude_of(walker.global_position)
		walker.fly_speed = clampf(alt * 0.6, 20.0, 3000.0)
		walker.rise = 1.0
		await _frames(1)
		alt = planet.altitude_of(walker.global_position)
		for m in marks.keys():
			if reached < m and alt >= m:
				walker.rise = 0.0
				await _frames(20)
				await _shot(marks[m])
				print("[planet] at %.0f m: impostor %s (fade %.2f), ground %s, view %d; buildings %d far, %d near" % [
						alt, planet.impostor.visible, float(planet._impostor_mat.get_shader_parameter("fade")),
						planet.terrain.visible, walker.viewer.view_distance, buildings.far_count, buildings.near_count])
		reached = alt
	walker.rise = 0.0
	_check("flew to 30 km", reached >= 30000.0, "%.0f m" % reached)
	_check("from orbit the impostor alone draws", planet.impostor.visible and not planet.terrain.visible)
	_check("the origin followed (shifts > 3)", PlanetFrame.shifts > 3, "%d, the last %.1f ms" % [PlanetFrame.shifts, PlanetFrame.last_us / 1000.0])
	# And back down, near where it left.
	walker.pitch = 0.0
	var t3 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t3 < 120000:
		var alt := planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))
		if alt < 3.0:
			break
		walker.fly_speed = clampf(alt * 0.6, 5.0, 3000.0)
		walker.rise = -1.0
		await _frames(1)
	walker.rise = 0.0
	walker.flying = false
	await get_tree().create_timer(4.0).timeout
	_check("lands and stands on the ground again", walker.is_on_floor(), "%.2f m over it" % (
			planet.altitude_of(walker.global_position) - data.height(planet.dir_of(walker.global_position))))
	await _shot("planet_gate_landed")
	_check("no building popped in plain sight (fade jumped > 1/3 over the horizon)", buildings.pops == 0,
			"%d; the biggest one-frame step %.2f" % [buildings.pops, buildings.max_step])
	print("[planet] frames: worst %.1f ms; over 40 ms: %s; of them in play (after the walker is let go): %d %s" % [
			_worst_ms, _hitches, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# The pawn's gate: the game's own player on local down (Planets.md 11.7).

func _hold(action: StringName, seconds: float) -> void:
	Input.action_press(action)
	await get_tree().create_timer(seconds).timeout
	Input.action_release(action)


func _over_ground(p: Vector3) -> float:
	return planet.altitude_of(p) - data.height(planet.dir_of(p))


func _run_pawn_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	_check("the pawn stands on the planet once the ground streams in", pawn != null,
			"%.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if pawn == null:
		get_tree().quit(1)
		return
	await get_tree().create_timer(2.0).timeout
	_check("standing on its feet", pawn.is_on_floor(), "%.2f m over the ground" % _over_ground(pawn.feet()))
	await _shot("planet_pawn_stand")
	# Walk forward 15 s.
	var c := planet.global_position
	var p0 := pawn.feet() - c
	var air := 0
	var ticks := 0
	Input.action_press(&"move_forward")
	var t1 := Time.get_ticks_msec()
	var lift := 0.0
	var runs := 0
	var was_air := false
	var states := {}
	while Time.get_ticks_msec() - t1 < 15000:
		await get_tree().physics_frame
		ticks += 1
		var st: int = pawn.moves.state
		if pawn.is_auto_crouched():
			states["crouched"] = int(states.get("crouched", 0)) + 1
		if pawn.body.get_slide_collision_count() == 0:
			states["no_contact"] = int(states.get("no_contact", 0)) + 1
		states[st] = int(states.get(st, 0)) + 1
		if not pawn.is_on_floor():
			air += 1
			lift = maxf(lift, _over_ground(pawn.feet()))
			if not was_air:
				runs += 1
		was_air = not pawn.is_on_floor()
	Input.action_release(&"move_forward")
	print("[planet] walk: off the floor %d ticks in %d runs, the feet at most %.3f m over the ground; move states %s; on_wall %s" % [
			air, runs, lift, states, pawn.body.is_on_wall()])
	var walked := (pawn.feet() - planet.global_position).normalized().angle_to(p0.normalized()) * data.radius
	_check("walks on the voxel ground (feet down > 95% of ticks)", air < ticks * 0.05, "%d of %d off, %.0f m" % [air, ticks, walked])
	_check("at a walk's speed (15 s, 30-55 m)", walked > 30.0 and walked < 55.0, "%.1f m" % walked)
	_check("stands ON the ground the CPU says is there (within 0.3 m)", absf(_over_ground(pawn.feet())) < 0.3,
			"%.2f m" % _over_ground(pawn.feet()))
	var up := pawn.up
	var roll := rad_to_deg(asin(clampf(absf(cam.global_transform.basis.x.dot(up)), 0.0, 1.0)))
	_check("the camera's horizon is the local one (roll < 0.5 deg)", roll < 0.5, "%.3f deg" % roll)
	_check("the body stands along the local up (< 0.5 deg)", rad_to_deg(pawn.body.global_transform.basis.y.angle_to(up)) < 0.5)
	# Strafe 12 s: no drift off the great circle it set off along.
	var s0 := pawn.feet() - planet.global_position
	var side := cam.global_transform.basis.x
	var n := s0.normalized().cross(Gravity.flat(side, pawn.up).normalized()).normalized()
	var off := 0.0
	Input.action_press(&"move_right")
	var t2 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t2 < 12000:
		await get_tree().physics_frame
		off = maxf(off, absf((pawn.feet() - planet.global_position).dot(n)))
	Input.action_release(&"move_right")
	var strafed := (pawn.feet() - planet.global_position).normalized().angle_to(s0.normalized()) * data.radius
	_check("strafes without drift (< 0.3 m off over the strafe)", off < 0.3 and strafed > 20.0,
			"%.3f m off over %.0f m" % [off, strafed])
	await get_tree().create_timer(0.5).timeout
	# A standing jump: up and back down where it left.
	var j0 := pawn.feet()
	var left := false
	var peak := 0.0
	pawn.intents.jump = true
	var t3 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t3 < 3000:
		await get_tree().physics_frame
		peak = maxf(peak, _over_ground(pawn.feet()))
		if not pawn.is_on_floor():
			left = true
		elif left:
			break
	var drift := Gravity.flat(pawn.feet() - j0, pawn.up).length()
	_check("jumps along the local up and lands where it left (< 0.15 m)", left and drift < 0.15,
			"peak %.2f m, %.3f m off" % [peak, drift])
	# A mantle: a ledge a metre high, 1.6 m ahead, square to the ground.
	await get_tree().create_timer(0.5).timeout
	var f := Gravity.flat(-cam.global_transform.basis.z, pawn.up).normalized()
	var base := pawn.feet()
	var gup := pawn.up
	var ledge := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 1.0, 1.5)
	cs.shape = box
	ledge.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	ledge.add_child(mi)
	add_child(ledge)
	var lb := Basis(f.cross(gup), gup, -f)
	ledge.global_transform = Transform3D(lb, base + f * 2.3 + gup * 0.4)
	await _frames(5)
	Input.action_press(&"move_forward")
	var climbed := 0.0
	var t4 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t4 < 3500:
		await get_tree().physics_frame
		if (Time.get_ticks_msec() - t4) > 300 and (Time.get_ticks_msec() - t4) < 1500:
			pawn.intents.jump = true
			pawn.intents.jump_held = true
		climbed = maxf(climbed, Gravity.vert(pawn.feet() - base, gup))
	Input.action_release(&"move_forward")
	pawn.intents.jump_held = false
	await _shot("planet_pawn_ledge")
	_check("gets up onto a metre-high ledge (feet > 0.8 m up)", climbed > 0.8, "%.2f m" % climbed)
	ledge.queue_free()
	# Fire: rounds go out of the gun.
	var shots := [0]
	gun.fired.connect(func(_i) -> void: shots[0] += 1)
	await _hold(&"fire", 0.8)
	await get_tree().create_timer(0.3).timeout
	_check("the gun fires on the planet", shots[0] > 0, "%d rounds" % shots[0])
	# Fly up 1 km, look round, land on foot again.
	_set_on_foot(false)
	walker.scripted = true
	walker.pitch = -0.4
	var t5 := Time.get_ticks_msec()
	while planet.altitude_of(walker.global_position) < 1000.0 and Time.get_ticks_msec() - t5 < 30000:
		walker.fly_speed = 120.0
		walker.rise = 1.0
		await _frames(1)
	walker.rise = 0.0
	await _shot("planet_pawn_flying")
	var t6 := Time.get_ticks_msec()
	while _over_ground(walker.global_position) > 3.0 and Time.get_ticks_msec() - t6 < 40000:
		walker.fly_speed = clampf(_over_ground(walker.global_position) * 0.8, 5.0, 300.0)
		walker.rise = -1.0
		await _frames(1)
	walker.rise = 0.0
	_set_on_foot(true)
	await get_tree().create_timer(2.0).timeout
	_check("lands on foot again and stands", on_foot and pawn.is_on_floor(), "%.2f m over the ground" % _over_ground(pawn.feet()))
	await _shot("planet_pawn_landed")
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] pawn gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)



# ---------------------------------------------------------------------------
# The mech's gate: a titan on local down (Planets.md 11.7).

func _arc(a: Vector3, b: Vector3) -> float:
	var c := planet.global_position
	return (a - c).normalized().angle_to((b - c).normalized()) * data.radius


func _run_mech_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var fwd := Gravity.flat(-cam.global_transform.basis.z, pawn.up).normalized()
	var spot := pawn.feet() + fwd * 25.0
	var ground := _ground_hit(spot + Gravity.up_at(spot) * 20.0)
	if ground == Vector3.INF:
		ground = spot
	var mech := Mech.spawn(self, ground + Gravity.up_at(ground) * 0.2, 0.0)
	PlanetBody.track(mech.body)
	await get_tree().create_timer(3.0).timeout
	var up := mech.motor.up
	var tilt := rad_to_deg(mech.body.global_transform.basis.y.angle_to(up))
	_check("the mech stands upright on the planet (< 0.5 deg)", tilt < 0.5, "%.3f deg" % tilt)
	_check("on the voxel ground", mech.body.is_on_floor(), "%.2f m over it" % _over_ground(mech.feet()))
	# Look at it from the pawn.
	_face(Gravity.flat(mech.body.global_position - pawn.body.global_position, pawn.up).normalized())
	await _frames(10)
	await _shot("planet_mech_stand")
	# Forward 15 s along the torso.
	var p0 := mech.feet()
	var n := (p0 - planet.global_position).normalized().cross(-mech.motor.torso_basis().z).normalized()
	var air := 0
	var ticks := 0
	var off := 0.0
	mech.intents.move_dir = Vector2(0.0, 1.0)
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 15000:
		await get_tree().physics_frame
		ticks += 1
		if not mech.body.is_on_floor():
			air += 1
		off = maxf(off, absf((mech.feet() - planet.global_position).dot(n)))
	mech.intents.move_dir = Vector2.ZERO
	var walked := _arc(p0, mech.feet())
	_check("walks on the voxel ground (feet down > 95% of ticks)", air < ticks * 0.05, "%d of %d off" % [air, ticks])
	_check("covers ground at a walk (15 s, > 40 m)", walked > 40.0, "%.1f m" % walked)
	_check("straight along its great circle (< 1% off)", off < walked * 0.01, "%.2f m off over %.0f m" % [off, walked])
	_check("still upright after the walk (< 0.5 deg)",
			rad_to_deg(mech.body.global_transform.basis.y.angle_to(mech.motor.up)) < 0.5)
	await _shot("planet_mech_walked")
	# Strafe 8 s.
	await get_tree().create_timer(1.5).timeout
	var s0 := mech.feet()
	var n2 := (s0 - planet.global_position).normalized().cross(mech.motor.torso_basis().x).normalized()
	var off2 := 0.0
	mech.intents.move_dir = Vector2(1.0, 0.0)
	var t2 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t2 < 8000:
		await get_tree().physics_frame
		off2 = maxf(off2, absf((mech.feet() - planet.global_position).dot(n2)))
	mech.intents.move_dir = Vector2.ZERO
	var strafed := _arc(s0, mech.feet())
	_check("strafes along its great circle (< 1% off)", strafed > 10.0 and off2 < strafed * 0.01,
			"%.2f m off over %.0f m" % [off2, strafed])
	# A dash: the speed jumps and comes back.
	await get_tree().create_timer(1.5).timeout
	var peak := 0.0
	mech.intents.move_dir = Vector2(0.0, 1.0)
	await get_tree().physics_frame
	mech.intents.dash = true
	for i in 30:
		await get_tree().physics_frame
		mech.intents.dash = false
		peak = maxf(peak, mech.motor.planar_speed())
	mech.intents.move_dir = Vector2.ZERO
	_check("dashes along the ground", peak > mech.motor.max_speed * 1.5, "peak %.1f m/s (walk %.1f)" % [peak, mech.motor.max_speed])
	# The torso turns about the local up.
	await get_tree().create_timer(2.0).timeout
	var f0 := -mech.motor.torso_basis().z
	mech.intents.aim_yaw = mech.motor.torso_yaw + 1.0
	await get_tree().create_timer(3.0).timeout
	var f1 := -mech.motor.torso_basis().z
	var turned := rad_to_deg(Gravity.flat(f0, mech.motor.up).signed_angle_to(Gravity.flat(f1, mech.motor.up), mech.motor.up))
	_check("the torso turns about the local up (57 deg asked)", absf(turned - 57.3) < 3.0, "%.1f deg" % turned)
	_check("and stays square to the ground (forward level, < 1 deg)",
			absf(90.0 - rad_to_deg(f1.angle_to(mech.motor.up))) < 1.0)
	# Dropped from 15 m: lands standing.
	var drop_at := mech.feet() + mech.motor.up * 15.0
	mech.body.global_position = drop_at + mech.motor.up * Mech.HEIGHT * 0.5
	mech.body.velocity = Vector3.ZERO
	mech.body.reset_physics_interpolation()
	var landed := [false]
	mech.motor.landed.connect(func(_f) -> void: landed[0] = true)
	await get_tree().create_timer(4.0).timeout
	_check("dropped 15 m, it lands and stands", landed[0] and mech.body.is_on_floor(),
			"%.2f m over the ground" % _over_ground(mech.feet()))
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] mech gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------------------
# The tank's gate: the player's tank on local down (Planets.md 11.7). Driven by
# its throttle and steer, as VehiclePilot drives it; no AI services.

## A spot `metres` ahead of the pawn's camera, on the ground.
func _ahead_on_ground(metres: float) -> Vector3:
	var fwd := Gravity.flat(-cam.global_transform.basis.z, pawn.up).normalized()
	var spot := pawn.feet() + fwd * metres
	var ground := _ground_hit(spot + Gravity.up_at(spot) * 20.0)
	return spot if ground == Vector3.INF else ground


func _run_tank_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var at := _ahead_on_ground(20.0)
	var tk := Tank.make(null, self, at + Gravity.up_at(at) * 0.3, 0.0, 0, null, null, Callable(),
			RandomNumberGenerator.new())
	PlanetBody.track(tk)
	await get_tree().create_timer(3.0).timeout
	var tilt := rad_to_deg(tk.global_transform.basis.y.angle_to(tk.up))
	_check("the tank stands square to local up (< 0.5 deg)", tilt < 0.5, "%.3f deg" % tilt)
	_check("on the voxel ground", tk.is_on_floor(), "%.2f m over it" % _over_ground(tk.feet()))
	_face(Gravity.flat(tk.global_position - pawn.body.global_position, pawn.up).normalized())
	await _frames(10)
	await _shot("planet_tank_stand")
	_check("the player takes the wheel", tk.take_player(0, Tank.Seat.DRIVER) and tk.driven())
	# Full ahead 12 s: along the great circle its nose points down.
	var p0 := tk.feet()
	var n := (p0 - planet.global_position).normalized().cross(tk.forward()).normalized()
	var air := 0
	var ticks := 0
	var off := 0.0
	tk.throttle = 1.0
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 12000:
		await get_tree().physics_frame
		ticks += 1
		if not tk.is_on_floor():
			air += 1
		off = maxf(off, absf((tk.feet() - planet.global_position).dot(n)))
	var driven := _arc(p0, tk.feet())
	_check("drives on the voxel ground (on it > 95% of ticks)", air < ticks * 0.05, "%d of %d off" % [air, ticks])
	_check("covers ground at its speed (12 s, > 45 m)", driven > 45.0, "%.1f m" % driven)
	_check("straight along its great circle (< 1% off)", off < driven * 0.01, "%.2f m off over %.0f m" % [off, driven])
	_check("still square to local up (< 0.5 deg)",
			rad_to_deg(tk.global_transform.basis.y.angle_to(tk.up)) < 0.5)
	await _shot("planet_tank_driven")
	# Steer left 2 s at speed: it turns about the local up.
	var f0 := tk.forward()
	tk.steer = 1.0
	await get_tree().create_timer(2.0).timeout
	tk.steer = 0.0
	var f1 := tk.forward()
	var turned := rad_to_deg(Gravity.flat(f0, tk.up).signed_angle_to(Gravity.flat(f1, tk.up), tk.up))
	var asked := rad_to_deg(Tank.TURN * 2.0)
	_check("turns left about the local up (~%.0f deg asked)" % asked,
			turned > asked * 0.7 and turned < asked * 1.1, "%.1f deg" % turned)
	_check("its nose level along the ground (< 1 deg)", absf(90.0 - rad_to_deg(f1.angle_to(tk.up))) < 1.0)
	# Off the throttle: it rolls to a stop.
	tk.throttle = 0.0
	await get_tree().create_timer(3.0).timeout
	var sp := Gravity.flat(tk.velocity, tk.up).length()
	_check("off the throttle it stops (< 0.3 m/s)", sp < 0.3, "%.2f m/s" % sp)
	# Back up 3 s: the other way along its nose.
	var b0 := tk.feet()
	tk.throttle = -1.0
	await get_tree().create_timer(3.0).timeout
	tk.throttle = 0.0
	var back := (tk.feet() - b0).dot(-tk.forward())
	_check("reverses along its nose (> 5 m)", back > 5.0, "%.1f m" % back)
	# Dropped from 6 m: down on its tracks.
	await get_tree().create_timer(2.0).timeout
	tk.global_position = tk.feet() + tk.up * (6.0 + Tank.HEIGHT * 0.5)
	tk.velocity = Vector3.ZERO
	tk.reset_physics_interpolation()
	await get_tree().create_timer(4.0).timeout
	_check("dropped 6 m, it lands on the ground", tk.is_on_floor(), "%.2f m over it" % _over_ground(tk.feet()))
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] tank gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The soldier's gate: an AI body on local down (Planets.md 11.7). Moved the way
# Soldier.walk_toward moves it (a world direction along the ground) and aimed
# the way Soldier aims (AimModel's world angles through Pawn.frame_look). The
# brain's world -- nav, sight, the AI grid -- is still the flat game's.

func _run_soldier_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var at := _ahead_on_ground(10.0)
	var so := Pawn.spawn(self, at + Gravity.up_at(at) * 0.2, 1)
	so.moves = PawnMoves.new(so)
	PlanetBody.track(so.body)
	await get_tree().create_timer(2.5).timeout
	_check("the soldier stands upright (< 0.5 deg)",
			rad_to_deg(so.body.global_transform.basis.y.angle_to(so.up)) < 0.5)
	_check("on the voxel ground", so.body.is_on_floor(), "%.2f m over it" % _over_ground(so.feet()))
	# Walk to a point 40 m round the planet, steering as walk_toward does.
	var c := planet.global_position
	var radial := (so.feet() - c).normalized()
	var side := Gravity.flat(so.feet() - pawn.feet(), so.up).normalized()
	var goal := c + _round_dir(radial, radial + side, 40.0) * (so.feet() - c).length()
	var ticks := 0
	var air := 0
	var left := INF
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 20000:
		await get_tree().physics_frame
		ticks += 1
		if not so.body.is_on_floor():
			air += 1
		var d := Gravity.flat(goal - so.feet(), so.up)
		left = d.length()
		if left <= 0.6:
			break
		so.intents.move = d.normalized()
		so.intents.run = true
	so.intents.move = Vector3.ZERO
	_check("walks 40 m round the curve to its goal (< 0.6 m)", left <= 0.6, "%.2f m short" % left)
	_check("feet on the ground on the way (> 95% of ticks)", air < ticks * 0.05, "%d of %d off" % [air, ticks])
	_face(Gravity.flat(so.body.global_position - pawn.body.global_position, pawn.up).normalized())
	await _frames(10)
	await _shot("planet_soldier_walked")
	await get_tree().create_timer(1.0).timeout
	# Aim at the player: AimModel's world yaw and pitch, through frame_look.
	var eye := so.eye.global_position
	var to := pawn.chest() - eye
	var wyaw := atan2(-to.x, -to.z)
	var wpitch := atan2(to.y, Vector2(to.x, to.z).length())
	var la := so.frame_look(wyaw, wpitch)
	so.intents.look_yaw = la.x
	so.intents.look_pitch = la.y
	var miss := rad_to_deg(so.look_dir().angle_to(Gravity.flat(to, so.up).normalized()))
	_check("its look turns to the player along the ground (< 0.5 deg)", miss < 0.5, "%.2f deg" % miss)
	var tl := so.body.global_transform.basis.orthonormalized().inverse() * to
	var want_pitch := atan2(tl.y, Vector2(tl.x, tl.z).length())
	_check("and its pitch is the pitch in its own frame (< 0.5 deg)", absf(rad_to_deg(la.y - want_pitch)) < 0.5,
			"%.2f vs %.2f deg" % [rad_to_deg(la.y), rad_to_deg(want_pitch)])
	var la2 := so.look_angles_to(to)
	_check("look_angles_to agrees with frame_look",
			absf(wrapf(la2.x - la.x, -PI, PI)) < 0.002 and absf(la2.y - la.y) < 0.002)
	# Its body fits where it stands, upright to local up; sunk half a metre into
	# the ground it does not. (The voxel collider is one-sided: a capsule with
	# its middle under the surface meets only back faces, which Jolt ignores --
	# never a spot body_fits is asked about, as they are snapped to the ground.)
	_check("body_fits: room where it stands", Soldier.body_fits(get_world_3d(), so.feet(), so.body.get_rid()))
	_check("body_fits: no room half a metre into the ground",
			not Soldier.body_fits(get_world_3d(), so.feet() - so.up * 0.5, so.body.get_rid()))
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] soldier gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The AI on the planet (Docs/Planets.md 11.8, N2 and N4): nav regions round the fight.

## Metres from the middle of home's town at which its fight starts.
const HOME_RAISE_AT := 130.0
## Metres under the ground that a pawn is put back from, and how many times.
const UNDER_GROUND := 3.0
var ground_saves := 0
## Seconds a downed player stays down, and metres from the ship's middle they get up.
const DOWN_FOR := 3.0
const BESIDE_SHIP := 10.0
## Regions are kept round everybody fighting within this (PlanetNavNet.keep_around).
const AI_KEEP_M := 60.0
## How often the regions round the fight are looked at again, seconds.
const AI_KEEP_EVERY := 0.5
var _ai_keep_t := 0.0
## The AI's longest physics tick (us) and its parts: keep_around, the net, the rest.
var ai_worst_us := 0
var ai_worst_parts: Array = []


## Set up the AI services on the nav net (PlanetNavNet) anchored over
## planet-local `dir`: regions of 8 x 8 tiles, each its own framed AIWorld and
## AINav on its ground grid (N1, N1b), made round whoever fights and dropped
## behind them. The buildings go into the regions they reach as proxy boxes --
## solid to walk round, bricks to hide behind (their own bricks in the AI's
## world are later work, 11.8 "Not here"). ai_world and ai_nav are the region
## the player is in; a soldier's paths go through the net, across regions. The
## floating origin moves every region's frame with the scene (_process). Of body
## `b`: home by default, or a generated world the player is on, whose first
## region is the only one built in the call (home's load has the time).
func setup_ai(dir: Vector3, b: PlanetBody = planet) -> void:
	var t0 := Time.get_ticks_usec()
	var stud := BrickWorld.get_stud_metres()
	var sites: Array = []
	var pb: PlanetBuildings = buildings if b == planet else system.built[b]
	var tr: PlanetTrees = trees if b == planet else system.trees_of.get(b)
	for s in pb.sites:
		var size := Vector3(s.fx * stud, s.height, s.fz * stud)
		sites.append([s.frame * Transform3D(Basis(), size * 0.5), size])
	var net := PlanetNavNet.make(b.data, dir, b)
	net.set_sites(sites)
	# The buildings' bricks (11.11): the regions read them, a site's box goes
	# while its bricks stand.
	net.bricks = pb.bricks
	pb.site_bricks.connect(func(i: int, on: bool) -> void: net.set_site_bricks(i, on, pb.site_box(i)))
	for i in pb.sites.size():
		if pb.sites[i].bricked:
			net.set_site_bricks(i, true, pb.site_box(i))
	# The trees' trunks too: walked round, and cover; one knocked down goes (11.10).
	if tr != null:
		net.tree_source = tr.trees_near
		tr.tree_knocked.connect(net.remove_tree)
	# What breaks the buildings' bricks (11.11 D1): a soldier's rounds, a squad's
	# breaching charge; the maps forget where bricks went.
	pb.site_damaged.connect(func(_i: int, box: AABB) -> void: net.invalidate_box(box))
	# A piece settled, woke, was hit or went (D2 step 5): the regions' worlds
	# take its chunk where it is now, and the maps forget the box.
	pb.pieces.ground_changed.connect(func(box: AABB) -> void:
		for r in net.regions.values():
			r.world.sync()
		net.invalidate_box(box.grow(1.0)))
	var at := b.global_transform * b.data.surface_point(dir)
	if b == planet:
		net.keep_around([at], AI_KEEP_M, 99)
	else:
		net.ensure(net.key_at(at))
	# From here on regions' grids are built on worker threads, off the frame.
	net.threaded = true
	var r := net.region_at(at)
	nav_region = r.nav_region
	ai = AIServices.new()
	ai.nav_net = net
	ai.ai_world = r.world
	ai.ai_nav = r.nav
	ai.sched = AIScheduler.new()
	ai.sched.set_base_budget_ms(2.5)
	ai.world3d = get_world_3d()
	ai.rng.seed = 0x9A7E7
	ai.on_structure_hit = _structure_hit
	ai.on_breach = func(p: Vector3, r: float) -> void: pb.damage(p, {"blast": true, "radius": r, "hp": 0})
	ai_of[b] = ai
	if b != planet:
		_ai_follow(b)
		# As soldier_probe: the cover mechanics, not the engage decision's dice.
		if _garrison_gate:
			ai.policy = CombatPolicy.new()
	print("[planet] AI nav net over the town: %d region(s) in %.0f ms (%.0f ms the one there), %d building(s)" % [
			net.regions.size(), (Time.get_ticks_usec() - t0) / 1000.0, r.made_ms, sites.size()])


func _physics_process(delta: float) -> void:
	if not _ai_awake():
		return
	var net := ai.nav_net as PlanetNavNet
	var t_ai := Time.get_ticks_usec()
	_ai_keep_t += delta
	if _ai_keep_t >= AI_KEEP_EVERY:
		_ai_keep_t = 0.0
		var points: Array = []
		if pawn != null:
			points.append(pawn.feet())
		for p in ai.pawns:
			if is_instance_valid(p) and p.health != null and not p.health.is_dead():
				points.append(p.feet())
		net.keep_around(points, AI_KEEP_M, 1)
		var here := net.region_at(pawn.feet()) if pawn != null else null
		if here != null:
			nav_region = here.nav_region
	var t_keep := Time.get_ticks_usec()
	# Between thinkers the services are the player's region (AIServices.focus).
	if pawn != null:
		ai.focus(pawn.feet())
	ai.ai_world.sync()
	net.service(800)
	var t_net := Time.get_ticks_usec()
	ai.sched.run()
	# Each thinker focused the services on its own region; the shared tick is the player's.
	if pawn != null:
		ai.focus(pawn.feet())
	ai.tick()
	var t_end := Time.get_ticks_usec()
	if t_end - t_ai > ai_worst_us:
		ai_worst_us = t_end - t_ai
		ai_worst_parts = [t_keep - t_ai, t_net - t_keep, t_end - t_net]


# The squad's gate: four soldiers set down in the town walk to the player round
# the curve, take cover and fire, on the region's nav (11.8 N2).

func _surface(dir: Vector3) -> Vector3:
	return planet.global_transform * data.surface_point(dir)


func _run_squad_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	# The player at the town's edge on the spawn's side, the squad inside it.
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var q_spot := _surface(_round_dir(town, spawn_dir, 28.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	_face(Gravity.flat(q_spot - p_feet, Gravity.up_at(p_feet)).normalized())
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.5).timeout
	setup_ai(town)
	# The cover mechanics, not the engage decision's dice (as soldier_probe).
	ai.policy = CombatPolicy.new()
	var plate := BrickWorld.get_plate_metres()
	_check("the region builds off the fight's path (< 2 s)", nav_region.build_ms < 2000.0,
			"%.0f ms" % nav_region.build_ms)
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	# The nav's own path from the squad to the player first: on the ground.
	var path := (ai.nav_net as PlanetNavNet).find_path(q_spot, pawn.feet(), 200000)
	var worst := 0.0
	for p in path:
		worst = maxf(worst, absf(_over_ground(p)))
	_check("a path from the squad to the player round the curve", path.size() > 2
			and path[path.size() - 1].distance_to(pawn.feet()) < 1.5, "%d points" % path.size())
	_check("the path is on the ground (within a plate, %.3f m)" % plate, path.size() > 2 and worst <= plate,
			"worst %.3f m" % worst)
	# The ground's colliders where the squad is set down, before it is: a body
	# dropped on ground not streamed yet falls into the planet.
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = q_spot
	PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while _ground_hit(q_spot) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(0.5).timeout
	_check("the ground streams in where the squad is set down", _ground_hit(q_spot) != Vector3.INF)
	var lib := GunPlaceholderParts.build_library()
	var up_q := Gravity.up_at(q_spot)
	var side := Gravity.flat(p_feet - q_spot, up_q).normalized().cross(up_q)
	var members: Array[Soldier] = []
	for i in 4:
		var at := ai.ai_nav.snap(q_spot + side * (i - 1.5) * 1.4 + up_q * 0.3)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, 50 + i, WeaponClass.builtin(&"rifle"), 1))
		var so := Soldier.spawn(ai, self, at + Gravity.up_at(at) * 0.1, 1, gun)
		PlanetBody.track(so.pawn.body)
		members.append(so)
	var q := Squad.make(ai, self, members, 1)
	var start := INF
	for m in members:
		start = minf(start, m.pawn.feet().distance_to(pawn.feet()))
	var nearest := start
	var ordered := false
	var ticks := 0
	var floor_ticks := 0
	var body_ticks := 0
	var sunk := 0.0
	var covered := 0
	var fired_at := -1.0
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 60000:
		await get_tree().physics_frame
		ticks += 1
		if not ordered and q.contact() != null:
			var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
			o.point = pawn.feet()
			q.give(o)
			ordered = true
		var shots := 0
		for m in q.alive():
			var f := m.pawn.feet()
			nearest = minf(nearest, f.distance_to(pawn.feet()))
			body_ticks += 1
			if m.pawn.body.is_on_floor():
				floor_ticks += 1
			sunk = minf(sunk, _over_ground(f))
			shots += m.shots
			# In cover: still, with bricks between the player's eye and its chest
			# (a bound ends on a CoverSearch spot; a soldier's own cover tactic too).
			var still := Gravity.flat(m.pawn.body.velocity, m.pawn.up).length() < 0.3
			if still and ai.ai_world.bricks_between(pawn.eye.global_position, f + m.pawn.up * 1.1) > 0:
				covered += 1
		if shots > 0 and fired_at < 0.0:
			fired_at = (Time.get_ticks_msec() - t1) / 1000.0
		if start - nearest >= 15.0 and fired_at >= 0.0 and covered >= 60:
			break
	var states := {}
	for m in members:
		states[m.state] = int(states.get(m.state, 0)) + 1
	print("[planet] squad: %s; play %s; %d of %d alive" % [states, q.play, q.alive().size(), members.size()])
	_check("the squad sees the player and is ordered on", ordered)
	_check("it walks to the player round the curve (closes >= 15 m)", start - nearest >= 15.0,
			"%.1f m -> %.1f m" % [start, nearest])
	_check("its feet on the ground on the way (> 90% of body-ticks)", floor_ticks > body_ticks * 0.9,
			"%d of %d" % [floor_ticks, body_ticks])
	_check("nobody falls through the planet (never > 0.5 m under the ground)", sunk > -0.5, "%.2f m" % sunk)
	_check("it takes cover (still, hidden from the player)", covered >= 60, "%d member-ticks" % covered)
	_check("it fires at the player", fired_at >= 0.0, "first at %.1f s" % fired_at)
	await _shot("planet_squad")
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] squad gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The travel gate (11.8 N4): a squad of four, on the player's side, ordered to a
# point 200 m out of the town, walks it on the nav net -- across the borders of
# regions made round it as it goes.

func _run_travel_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var q_spot := _surface(_round_dir(town, spawn_dir, 80.0))
	var goal := _surface(_round_dir(town, spawn_dir, 280.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = q_spot
	PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while (_ground_hit(p_feet) == Vector3.INF or _ground_hit(q_spot) == Vector3.INF) \
			and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	var plate := BrickWorld.get_plate_metres()
	# The net's own path first.
	var path := net.find_path(q_spot, goal, 200000)
	var worst := 0.0
	var crossed := 0
	var last := net.key_at(q_spot)
	for p in path:
		worst = maxf(worst, absf(_over_ground(p)))
		var k := net.key_at(p)
		if k != last:
			crossed += 1
			last = k
	var worst_join := 0.0
	for j in net.last_joins:
		worst_join = maxf(worst_join, j)
	_check("a path 200 m out of the town on the nav net", path.size() > 2
			and path[path.size() - 1].distance_to(goal) < 1.5, "%d points" % path.size())
	_check("across the regions' borders (>= 2)", crossed >= 2, "%d" % crossed)
	_check("its stretches meet at the borders (<= 0.36 m)", worst_join <= 0.36, "%.3f m" % worst_join)
	_check("on the ground (within 1.5 plates)", path.size() > 2 and worst <= plate * 1.5, "worst %.3f m" % worst)
	var lib := GunPlaceholderParts.build_library()
	var up_q := Gravity.up_at(q_spot)
	var side := Gravity.flat(goal - q_spot, up_q).normalized().cross(up_q)
	var members: Array[Soldier] = []
	for i in 4:
		var at := ai.ai_nav.snap(q_spot + side * (i - 1.5) * 1.4 + up_q * 0.3)
		var gun := GunInstance.from_result(GunGenerator.generate(lib, 70 + i, WeaponClass.builtin(&"rifle"), 1))
		var so := Soldier.spawn(ai, self, at + Gravity.up_at(at) * 0.1, 0, gun)
		PlanetBody.track(so.pawn.body)
		members.append(so)
	var q := Squad.make(ai, self, members, 0)
	await get_tree().create_timer(0.5).timeout
	var o := SquadMsg.Order.make(SquadMsg.OrderKind.MOVE)
	o.point = goal
	var order_id := q.give(o)
	var made0 := net.regions_made
	var ticks := 0
	var floor_ticks := 0
	var body_ticks := 0
	var sunk := 0.0
	var report: Variant = null
	var keys := {}
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 150000:
		await get_tree().physics_frame
		ticks += 1
		for m in q.alive():
			body_ticks += 1
			if m.pawn.body.is_on_floor():
				floor_ticks += 1
			sunk = minf(sunk, _over_ground(m.pawn.feet()))
			keys[net.key_at(m.pawn.feet())] = true
		for r in q.reports:
			if r.order_id == order_id and r.kind != SquadMsg.ReportKind.ACCEPTED:
				report = r
		if report != null:
			break
	var secs := (Time.get_ticks_msec() - t1) / 1000.0
	var near := 0
	var nearest := INF
	for m in q.alive():
		var d := Gravity.flat(m.pawn.feet() - goal, Gravity.up_at(goal)).length()
		nearest = minf(nearest, d)
		if d < 12.0:
			near += 1
	print("[planet] travel: %s after %.0f s; %d of %d within 12 m (nearest %.1f m); %d cell(s) walked, %d region(s) made on the way, %d dropped" % [
			report, secs, near, members.size(), nearest, keys.size(), net.regions_made - made0, net.regions_dropped])
	_check("the squad gets there: MOVE reported DONE", report != null and report.kind == SquadMsg.ReportKind.DONE,
			str(report))
	_check("all of it (>= 3 of 4 within 12 m)", near >= 3, "%d" % near)
	_check("through several regions (>= 3 cells walked)", keys.size() >= 3, "%d" % keys.size())
	_check("regions made round it as it went", net.regions_made > made0, "%d" % (net.regions_made - made0))
	_check("its feet on the ground on the way (> 90% of body-ticks)", floor_ticks > body_ticks * 0.9,
			"%d of %d" % [floor_ticks, body_ticks])
	_check("nobody falls through the planet (never > 0.5 m under the ground)", sunk > -0.5, "%.2f m" % sunk)
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] nav net service: worst %.1f ms %s (builds, region queues, routes, legs; us)" % [
			net.worst_service_us / 1000.0, net.worst_service_parts])
	print("[planet] AI tick: worst %.1f ms (keep_around %.1f, net %.1f, scheduler and services %.1f)" % [
			ai_worst_us / 1000.0, ai_worst_parts[0] / 1000.0, ai_worst_parts[1] / 1000.0, ai_worst_parts[2] / 1000.0])
	print("[planet] travel gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The far gate (11.8): a fight away from the player. Two squads -- one on the
# player's side, one against it -- meet on the town's far side, ~170 m from the
# player and in another region. What they see, hide behind and walk on is their
# own region's (AIServices.focus): the player's region has no ground there.

func _run_far_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	var e := Gravity.flat(spawn_dir - town, town).normalized()
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var a_spot := _surface(_round_dir(town, town - e, 80.0))
	var b_spot := _surface(_round_dir(town, town - e, 112.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	for at in [a_spot, b_spot]:
		var marker := Node3D.new()
		add_child(marker)
		marker.global_position = at
		PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while (_ground_hit(p_feet) == Vector3.INF or _ground_hit(a_spot) == Vector3.INF
			or _ground_hit(b_spot) == Vector3.INF) and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town)
	ai.policy = CombatPolicy.new()
	var net := ai.nav_net as PlanetNavNet
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	net.keep_around([a_spot, b_spot], AI_KEEP_M, 99)
	var kp := net.key_at(p_feet)
	var ka := net.key_at(a_spot)
	var kb := net.key_at(b_spot)
	print("[planet] far: player in %s, the squads in %s and %s, %.0f m off" % [kp, ka, kb, p_feet.distance_to(a_spot)])
	_check("the fight is in another region than the player's", ka != kp and kb != kp)
	var here: AINav = net.regions[kp].nav
	_check("where the player's region has no ground to stand on", not here.can_stand(a_spot)
			and net.nav_at(a_spot).can_stand(net.nav_at(a_spot).snap(a_spot)))
	var lib := GunPlaceholderParts.build_library()
	var sides: Array = []
	for team in [0, 1]:
		var at: Vector3 = a_spot if team == 0 else b_spot
		var other: Vector3 = b_spot if team == 0 else a_spot
		var up := Gravity.up_at(at)
		var side := Gravity.flat(other - at, up).normalized().cross(up)
		var members: Array[Soldier] = []
		for i in 4:
			var feet := net.snap(at + side * (i - 1.5) * 1.4 + up * 0.3)
			var gun := GunInstance.from_result(GunGenerator.generate(lib, 90 + team * 10 + i,
					WeaponClass.builtin(&"rifle"), 1))
			var so := Soldier.spawn(ai, self, feet + Gravity.up_at(feet) * 0.1, team, gun)
			PlanetBody.track(so.pawn.body)
			members.append(so)
		sides.append({"squad": Squad.make(ai, self, members, team), "members": members,
				"ordered": false, "covered": 0, "seen": false})
	var ticks := 0
	var floor_ticks := 0
	var body_ticks := 0
	var sunk := 0.0
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 60000:
		await get_tree().physics_frame
		ticks += 1
		var all_done := true
		for k in 2:
			var sd: Dictionary = sides[k]
			var q: Squad = sd.squad
			var c := q.contact()
			if c != null:
				sd.seen = true
				if not sd.ordered:
					var o := SquadMsg.Order.make(SquadMsg.OrderKind.ADVANCE)
					o.point = c.pos
					q.give(o)
					sd.ordered = true
			var foe: Dictionary = sides[1 - k]
			for m in q.alive():
				var f := m.pawn.feet()
				body_ticks += 1
				if m.pawn.body.is_on_floor():
					floor_ticks += 1
				sunk = minf(sunk, _over_ground(f))
				var still := Gravity.flat(m.pawn.body.velocity, m.pawn.up).length() < 0.3
				var w := net.world_at(f)
				if still and w != null:
					for fm in (foe.squad as Squad).alive():
						if fm.pawn.eye.global_position.distance_to(f) < 60.0 								and w.bricks_between(fm.pawn.eye.global_position, f + m.pawn.up * 1.1) > 0:
							sd.covered += 1
							break
			var shots := 0
			for m in (sd.members as Array):
				if is_instance_valid(m):
					shots += (m as Soldier).shots
			sd["shots"] = shots
			if not (sd.seen and shots > 0 and int(sd.covered) >= 60):
				all_done = false
		if all_done:
			break
	var hurt := 0
	for k in 2:
		for m in (sides[k].members as Array):
			if not is_instance_valid(m) or (m as Soldier).is_dead() 					or (m as Soldier).pawn.health.total_current() < (m as Soldier).max_health:
				hurt += 1
	for k in 2:
		var sd: Dictionary = sides[k]
		var who := "ours" if k == 0 else "theirs"
		print("[planet] far: %s -- seen %s, %d round(s), %d member-ticks in cover, %d of 4 alive" % [
				who, sd.seen, int(sd.get("shots", 0)), int(sd.covered), (sd.squad as Squad).alive().size()])
		_check("%s see the other side" % who, bool(sd.seen))
		_check("%s fire on it" % who, int(sd.get("shots", 0)) > 0, "%d round(s)" % int(sd.get("shots", 0)))
		_check("%s take cover (still, bricks between them and the other side's eyes)" % who,
				int(sd.covered) >= 60, "%d member-ticks" % int(sd.covered))
	_check("rounds land: somebody is hurt", hurt > 0, "%d" % hurt)
	_check("feet on the ground (> 90% of body-ticks)", floor_ticks > body_ticks * 0.9,
			"%d of %d" % [floor_ticks, body_ticks])
	_check("nobody falls through the planet (never > 0.5 m under the ground)", sunk > -0.5, "%.2f m" % sunk)
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] AI tick: worst %.1f ms" % (ai_worst_us / 1000.0))
	print("[planet] far gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The light's gate (Docs/Lighting.md 8): the colour rules on every body of the
# system, the sun's size and brightness by distance, sunset, the fill at night,
# a moon's shadow on its planet, and the ambient boxes in the town's buildings;
# pictures at noon, dawn, night, inside and outside a building.

func _run_light_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while (walker.frozen or pawn == null) and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	# 1. Colour: no world's air paints the ambient; the ground's tint small.
	var worst := 0.0
	var worst_tint := 0.0
	for b in system.bodies:
		var c := LightRig.sky_cast(b.data.atmosphere_color)
		worst = maxf(worst, maxf(absf(c.r - 1.0), maxf(absf(c.g - 1.0), absf(c.b - 1.0))))
		var t := b.data.tint
		worst_tint = maxf(worst_tint, maxf(1.0 - t.r, maxf(1.0 - t.g, 1.0 - t.b)))
	_check("every body's sky cast within %.2f of none" % LightRig.SKY_CAST_DEV, worst <= LightRig.SKY_CAST_DEV + 0.001, "worst %.3f" % worst)
	var red := LightRig.sky_cast(Color(1.0, 0.3, 0.3))
	_check("a red air's cast held (was 2.2, 0.46, 0.3)", red.r <= 1.0 + LightRig.SKY_CAST_DEV + 0.001 and red.b >= 1.0 - LightRig.SKY_CAST_DEV - 0.001,
			"%.2f %.2f %.2f" % [red.r, red.g, red.b])
	_check("every body's ground tint small (under 0.09 a channel)", worst_tint < 0.09, "worst %.3f" % worst_tint)
	_check("the ambient mostly neutral", env.ambient_light_sky_contribution <= LightRig.AMBIENT_SKY + 0.001 and env.ambient_light_color.s < 0.05,
			"sky %.2f, neutral's saturation %.3f" % [env.ambient_light_sky_contribution, env.ambient_light_color.s])
	_check("AgX; daylight's exposure as is", env.tonemap_mode == Environment.TONE_MAPPER_AGX and absf(light.exposure - 1.0) < 0.05,
			"exposure %.2f, light %.2f" % [light.exposure, light.light_here])
	_check("the noon sun near white (saturation < 0.2)", sun.light_color.s < 0.2, "%s" % sun.light_color)
	# 2. Distance: the sun's size and brightness from where the camera is.
	var ds := (system.star.global_position - _eye()).length()
	var want := minf(rad_to_deg(2.0 * asin(system.sys.star_radius / ds)), LightRig.SUN_ANGLE_MAX)
	_check("the sun's size is the star's from here", absf(light.sun_angle - want) < LightRig.ANGLE_STEP + 0.001
			and is_equal_approx(sun.light_angular_distance, light.sun_angle), "%.2f deg against %.2f" % [light.sun_angle, want])
	_check("home's brightness is home's", absf(light.gain - 1.0) < 0.05, "gain %.3f" % light.gain)
	_check("brighter near a star, dimmer far, held", LightRig.sun_gain(4.0) > 1.4 and LightRig.sun_gain(0.25) < 0.7
			and LightRig.sun_gain(100.0) == LightRig.GAIN_MAX and LightRig.sun_gain(0.0001) == LightRig.GAIN_MIN)
	var low := LightRig.sunlight_colour(system.sys.star_color, 0.03, 1.0)
	var high := LightRig.sunlight_colour(system.sys.star_color, 1.0, 1.0)
	_check("a low sun through air is redder", low.b / low.r < 0.6 * high.b / high.r, "b/r %.2f against %.2f" % [low.b / low.r, high.b / high.r])
	_check("no air, no sunset", LightRig.sunlight_colour(system.sys.star_color, 0.03, 0.0) == LightRig.sunlight_colour(system.sys.star_color, 1.0, 0.0))
	# 2a. A ring's shadow (Lighting.md 2a): a point a km sunward-under the
	# ring's thickest band loses most of the sun; one off its plane's shadow
	# none; the far look and the disc are told.
	# A ring of its own here, 20-60 km round a point 100 km off.
	var rg := RockField.new()
	rg.setup(20000.0, 60000.0, 7, Color(0.6, 0.55, 0.5))
	add_child(rg)
	rg.global_position = _eye() + Vector3(100000.0, 0.0, 0.0)
	var disc_parent := Node3D.new()
	add_child(disc_parent)
	rg.build_far(disc_parent)
	var sdw := Vector3(0.3, 0.8, 0.2).normalized()
	var best_r := 0.0
	var best_a := 0.0
	for k in 200:
		var rr := lerpf(rg.inner / rg.outer, 1.0, k / 200.0)
		var a := RockField.alpha_at(rr, rg.inner / rg.outer, rg.far_density, rg.grain())
		if a > best_a:
			best_a = a
			best_r = rr
	var on_ring := rg.global_position + Vector3.RIGHT * best_r * rg.outer
	var l_under := rg.light_at(on_ring - sdw * 1000.0, sdw)
	var l_over := rg.light_at(on_ring + sdw * 1000.0, sdw)
	var l_hole := rg.light_at(rg.global_position - sdw * 1000.0, sdw)
	_check("a ring's shadow: under its thickest band the sun mostly gone; over it, and through its middle, all there",
			l_under < 1.0 - 0.6 * best_a * RockField.SHADE and is_equal_approx(l_over, 1.0) and is_equal_approx(l_hole, 1.0),
			"%.2f under (cover %.2f), %.2f over, %.2f through the middle" % [l_under, best_a, l_over, l_hole])
	rg.queue_free()
	disc_parent.queue_free()
	await _shot("light_gate_noon")
	if DisplayServer.get_name() != "headless" and clouds != null:
		# The clouds (Lighting.md 2b), seen: up at them from the ground, and
		# down from 400 m on the ground their shadows lie on.
		var was_cam := get_viewport().get_camera_3d()
		var up := Gravity.up_at(was_cam.global_position)
		var side := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		var look := Camera3D.new()
		look.far = 40000.0
		add_child(look)
		look.global_position = was_cam.global_position + up * 2.0
		look.look_at(look.global_position + (side + up * 0.6).normalized() * 100.0, up)
		look.make_current()
		await _frames(6)
		await _shot("light_gate_clouds_up")
		look.global_position = was_cam.global_position + up * 400.0
		look.look_at(was_cam.global_position + side * 900.0, up)
		await _frames(6)
		await _shot("light_gate_clouds_down")
		was_cam.make_current()
		look.queue_free()
		await _frames(2)
	# 3. Night: the fill from the brightest body over the horizon.
	var day := data.day
	system.t += day * 0.5
	await get_tree().create_timer(2.5).timeout
	_check("midnight: the sun off", sun.light_energy < 0.01)
	_check("the night opens the eye, but only so far", light.exposure > 1.3 and light.exposure <= LightRig.EXPOSE_MAX,
			"exposure %.2f, light %.3f" % [light.exposure, light.light_here])
	print("[light] night fill: %s, energy %.3f, shadows %s" % [light.fill_from.data.planet_name if light.fill_from != null else "none",
			light.fill_energy, light.fill.shadow_enabled])
	if light.fill.visible:
		_check("a fill this bright with the sun gone casts shadows", light.fill.shadow_enabled == (light.fill_energy > LightRig.FILL_SHADOW_AT))
	await _shot("light_gate_night")
	system.t += day * 0.25
	await get_tree().create_timer(2.5).timeout
	_check("dawn: the sunlight redder than noon's", sun.light_color.b / sun.light_color.r < high.b / high.r * 0.9,
			"b/r %.2f" % (sun.light_color.b / sun.light_color.r))
	await _shot("light_gate_dawn")
	system.t += day * 0.25
	await _frames(4)
	# A body between a planet and the star shadows its far look.
	var moon_i := -1
	for i in system.sys.bodies.size():
		if system.sys.bodies[i].parent >= 0 and moon_i < 0:
			moon_i = i
	if moon_i >= 0:
		var m := system.bodies[moon_i]
		var pl := system.bodies[system.sys.bodies[moon_i].parent]
		var to_s := (system.star.global_position - pl.global_position).normalized()
		m.global_position = pl.global_position + to_s * pl.data.radius * 3.0
		system._shadows_on(pl)
		_check("a moon between its planet and the star shadows the planet's far look", pl.shadows_now > 0, "%d" % pl.shadows_now)
		m.global_position = pl.global_position - to_s * pl.data.radius * 3.0
		system._shadows_on(pl)
		_check("behind it, none", pl.shadows_now == 0, "%d" % pl.shadows_now)
		var found := -1.0
		var tt := system.t
		for k in 800:
			system.t = tt + system.sys.bodies[moon_i].orbit_period * k / 800.0
			system._place()
			if pl.shadows_now > 0:
				found = system.t - tt
				break
		system.t = tt
		system._place()
		print("[light] %s's shadow first on %s %.0f s on (of an orbit of %.0f s)" % [m.data.planet_name, pl.data.planet_name,
				found, system.sys.bodies[moon_i].orbit_period])
	# 4. Ambient boxes in the town's buildings.
	var pb := _buildings_here()
	t0 = Time.get_ticks_msec()
	while pb.bricked_count == 0 and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	_check("a box in every building laid in bricks", light.box_count() >= pb.bricked_count and pb.bricked_count > 0,
			"%d boxes, %d bricked" % [light.box_count(), pb.bricked_count])
	var near := -1
	var best := INF
	for i in pb.sites.size():
		var s = pb.sites[i]
		if s.bricked and s.brick_node != null:
			var d: float = (s.brick_node.global_position - _eye()).length()
			if d < best:
				best = d
				near = i
	if near >= 0:
		var s = pb.sites[near]
		var stud := BrickPalette.STUD_M
		var probe: ReflectionProbe = null
		for c in s.brick_node.get_children():
			if c is ReflectionProbe:
				probe = c
		# Inside: the darkest air at eye height the grid knows (6.1) -- a
		# tower's open windows light the rooms along its walls.
		var inside: Vector3 = s.brick_node.global_transform * Vector3(s.fx * stud * 0.5, 1.6, s.fz * stud * 0.5)
		var darkest := 2.0
		var wt0 := TowerRecipe.WALL_THICK
		var py0 := int(1.0 / BrickWorld.get_plate_metres())
		var py1 := int(2.0 / BrickWorld.get_plate_metres())
		for x in range(wt0 + 1, s.fx - wt0 - 1):
			for z in range(wt0 + 1, s.fz - wt0 - 1):
				var air := true
				for y in range(py0, py1 + 1):
					if pb.bricks.block_at(s.chunk, Vector3i(x, y, z)) >= 0:
						air = false
						break
				if not air:
					continue
				var w: Vector3 = s.brick_node.global_transform * Vector3((x + 0.5) * stud, 1.6, (z + 0.5) * stud)
				var g := grid_light.at(w).x
				if g >= 0.0 and g < darkest:
					darkest = g
					inside = w
		var outside: Vector3 = s.brick_node.global_transform * Vector3(-1.0, 1.6, s.fz * stud * 0.5)
		var wall: Vector3 = s.brick_node.global_transform * Vector3(0.0, 1.6, s.fz * stud * 0.5)
		var holds := func(pt: Vector3) -> bool:
			var l := probe.global_transform.affine_inverse() * pt
			return absf(l.x) <= probe.size.x * 0.5 and absf(l.y) <= probe.size.y * 0.5 and absf(l.z) <= probe.size.z * 0.5
		_check("its box holds the inside, not the outside or the wall's face", probe != null and holds.call(inside)
				and not holds.call(outside) and not holds.call(wall))
		_check("inside darker than outside by day", probe != null and probe.ambient_color_energy * probe.ambient_color.get_luminance()
				< env.ambient_light_energy * env.ambient_light_color.get_luminance() * 0.7, "%.3f against %.3f" % [
				probe.ambient_color_energy * probe.ambient_color.get_luminance(), env.ambient_light_energy * env.ambient_light_color.get_luminance()])
		var c := Camera3D.new()
		c.far = PlanetSystem.SEE_FAR
		c.fov = 70.0
		add_child(c)
		var up := Gravity.up_at(inside)
		c.look_at_from_position(inside, s.brick_node.global_transform * Vector3(s.fx * stud, 1.4, s.fz * stud * 0.5), up)
		c.current = true
		await get_tree().create_timer(2.5).timeout
		_check("inside, the eye opens", light.inside and light.exposure > 1.2, "exposure %.2f, light %.3f" % [light.exposure, light.light_here])
		await _shot("light_gate_inside")
		if DisplayServer.get_name() != "headless":
			# What the picture shows: the box and the eye, each against without.
			light.hold_exposure = true
			var with_all := await _screen_mean()
			pb.brick_material.set_shader_parameter("grid_sky_floor", 1.0)
			await _frames(3)
			var no_box := await _screen_mean()
			pb.brick_material.set_shader_parameter("grid_sky_floor", BrickGridLight.SKY_FLOOR)
			light.attributes.exposure_multiplier = 1.0
			await _frames(3)
			var no_eye := await _screen_mean()
			light.attributes.exposure_multiplier = light.exposure
			light.hold_exposure = false
			print("[light] inside, mean of the picture: %.3f; the grid off %.3f; the eye shut %.3f" % [with_all, no_box, no_eye])
			_check("the grid darkens the inside", with_all < no_box * 0.9, "%.3f against %.3f" % [with_all, no_box])
			_check("the eye brightens it again (AgX squeezes it)", with_all > no_eye * 1.1, "%.3f against %.3f" % [with_all, no_eye])
		var from: Vector3 = outside + (outside - inside).normalized() * 12.0 + up * 4.0
		c.look_at_from_position(from, inside, up)
		await get_tree().create_timer(2.5).timeout
		_check("out again, daylight's", not light.inside and light.exposure < 1.1, "exposure %.2f" % light.exposure)
		await _shot("light_gate_outside")
		# 6.1: the grid. Its bricks are lit by it, not by the box; inside is
		# shut off from the sky, outside is open; a hole in the wall lets the
		# sky in.
		var key := "%d:%d" % [pb.get_instance_id(), near]
		grid_light.step()
		var band: GeometryInstance3D = null
		for ch in s.brick_node.get_children():
			if ch is MeshInstance3D:
				band = ch
		_check("the grid lights its bricks, the box does not", grid_light.tracked(key) and band != null
				and band.layers == BrickGridLight.RENDER_LAYER and (band.get_instance_shader_parameter(&"grid_light") as Vector4).x >= 0.0
				and probe.reflection_mask & BrickGridLight.RENDER_LAYER == 0)
		var in_sky := grid_light.at(inside).x
		_check("inside, the grid's sky is low; outside there is no grid", in_sky >= 0.0 and in_sky < 0.3
				and grid_light.at(outside).x < 0.0, "inside %.2f" % in_sky)
		print("[light] grid: %d update(s), the last %.2f ms" % [grid_light.updates, grid_light.last_ms])
		_check("lighting a building takes under 8 ms", grid_light.last_ms < 8.0, "%.2f ms" % grid_light.last_ms)
		# A hole through the +X wall, three courses tall and four studs wide,
		# at eye height, where a room is right behind it: the air just in from
		# it is three steps from the open (two of wall, one in).
		var wt := TowerRecipe.WALL_THICK
		var y0 := int(1.0 / BrickWorld.get_plate_metres())
		var ids := {}
		var hz := -1
		var eye_plate := int(1.6 / BrickWorld.get_plate_metres())
		# Where the wall is whole and a room is right behind it.
		for z0 in range(wt + 1, s.fz - wt - 5):
			var solid := true
			for z in range(z0, z0 + 4):
				for y in range(y0, y0 + 9):
					if pb.bricks.block_at(s.chunk, Vector3i(s.fx - 1, y, z)) < 0:
						solid = false
				if pb.bricks.block_at(s.chunk, Vector3i(s.fx - wt - 1, eye_plate, z)) >= 0:
					solid = false
			if solid:
				hz = z0
				break
		for x in range(s.fx - wt, s.fx):
			for z in range(hz, hz + 4):
				for y in range(y0, y0 + 9):
					var b := pb.bricks.block_at(s.chunk, Vector3i(x, y, z))
					if b >= 0:
						ids[b] = true
		var hx: int = s.fx - wt - 1
		var by_hole: Vector3 = s.brick_node.global_transform * Vector3((hx + 0.5) * stud, 1.6, (hz + 2.5) * stud)
		var before := grid_light.at(by_hole).x
		pb.bricks.kill_blocks(s.chunk, PackedInt32Array(ids.keys()))
		var n0 := grid_light.updates
		grid_light.relight(key)
		var after := grid_light.at(by_hole).x
		_check("a hole in the wall lets the sky in", hz >= 0 and grid_light.updates > n0 and after > before + 0.05
				and after >= 1.0 - 3.0 * BrickGridLight.SKY_STEP / 255.0 - 0.01,
				"%d bricks out at z %d; %.2f -> %.2f" % [ids.size(), hz, before, after])
		# A lamp: the floor under `inside` made Glow lights the room round it.
		var il: Vector3 = s.brick_node.global_transform.affine_inverse() * inside
		var floor_b := -1
		for y in range(int(il.y / BrickWorld.get_plate_metres()), -1, -1):
			floor_b = pb.bricks.block_at(s.chunk, Vector3i(int(il.x / stud), y, int(il.z / stud)))
			if floor_b >= 0:
				break
		# The real lights hung are the ones nearest the camera
		# (BrickGridLight._place_lamps): the eye in the room for these.
		var was_eye := get_viewport().get_camera_3d()
		var eye := Camera3D.new()
		add_child(eye)
		eye.global_position = inside
		eye.make_current()
		# Its own lights (CeilingLights, under every ceiling over a room).
		var own: int = (grid_light._entries[key] as BrickGridLight.Entry).groups.size()
		_check("the tower has lights under its ceilings", own >= 3, "%d" % own)
		var lamp0 := grid_light.at(inside).y
		var glow := -1
		for m in BrickWorld.get_material_count():
			if BrickWorld.get_material_name(m) == "Glow PLA":
				glow = m
		if floor_b >= 0 and glow >= 0:
			pb.bricks.set_block_material(s.chunk, floor_b, glow)
			grid_light.relight(key)
		var lamp1 := grid_light.at(inside).y
		_check("a Glow brick lights the room round it", floor_b >= 0 and glow >= 0 and lamp0 < 0.05 and lamp1 > 0.4,
				"lamp %.2f -> %.2f" % [lamp0, lamp1])
		# And a real light there (Lighting.md 6.3) for what moves, leaving the
		# bricks to the grid.
		var lamp_near := false
		var lamp_mask_ok := true
		for kid in s.brick_node.get_children():
			var l := kid as OmniLight3D
			if l != null and l.name.begins_with("GlowLamp"):
				lamp_mask_ok = lamp_mask_ok and (l.light_cull_mask & BrickGridLight.RENDER_LAYER) == 0 						and not l.shadow_enabled
				if l.global_position.distance_to(inside) < BrickGridLight.LAMP_RANGE * 0.75:
					lamp_near = true
		_check("the Glow brick hangs an unshadowed light for what moves", lamp_near and lamp_mask_ok,
				"%d lamp(s) in all" % grid_light.lamp_count())
		# A light bar under the ceiling over `inside` (Lighting.md 6.3): a red
		# Lamp under-tile, clipped on by its studs, shining down -- red on the
		# grid under it, and a spot light down for what moves. In the inside
		# picture.
		var under_a: int = pb._palette.get("undertile_1x4_z", -1)
		var lamp_m := -1
		var bar_red := 0
		for m in BrickWorld.get_material_count():
			if BrickWorld.get_material_name(m) == "Lamp":
				lamp_m = m
		for cc in BrickWorld.get_material_colour_count(maxi(lamp_m, 0)):
			if BrickWorld.get_material_colour_name(maxi(lamp_m, 0), cc) == "red":
				bar_red = cc
		var ceil_y := -1
		for y in range(int(il.y / BrickWorld.get_plate_metres()), int(il.y / BrickWorld.get_plate_metres()) + 60):
			if pb.bricks.block_at(s.chunk, Vector3i(int(il.x / stud), y, int(il.z / stud))) >= 0:
				ceil_y = y
				break
		var bar := -1
		var bar_cell := Vector3i.ZERO
		if under_a >= 0 and lamp_m >= 0 and ceil_y > 0:
			# Where it fits, near over `inside` (furniture, a wall may be there).
			for d in [Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, -3), Vector2i(1, -1), Vector2i(-1, -1),
					Vector2i(1, -3), Vector2i(-1, -3), Vector2i(0, -2)]:
				bar_cell = Vector3i(int(il.x / stud) + d.x, ceil_y - 1, int(il.z / stud) + d.y)
				bar = pb.bricks.place_block(s.chunk, bar_cell, under_a, bar_red)
				if bar >= 0:
					break
			if bar >= 0:
				pb.bricks.set_block_material(s.chunk, bar, lamp_m)
				grid_light.relight(key)
				# Drawn: its band made again from the chunk's bake (as a hit's).
				for band_i in s.collision.bands_of(PackedInt32Array([bar])):
					if not s.remesh.has(band_i):
						s.remesh.append(band_i)
				pb.bricks.bake_chunk_async(s.chunk)
		var under_bar: Vector3 = s.brick_node.global_transform * Vector3((bar_cell.x + 0.5) * stud,
				(ceil_y - 4) * BrickWorld.get_plate_metres(), (bar_cell.z + 2.0) * stud)
		var lit := grid_light.at_colour(under_bar)
		var spot_down := false
		for kid in s.brick_node.get_children():
			var sp := kid as SpotLight3D
			if sp != null and (-sp.global_basis.z).dot(s.brick_node.global_basis.y.normalized()) < -0.95 and sp.light_color.r > 0.9 and sp.light_color.g < 0.4:
				spot_down = true
		_check("a red light bar under the ceiling lights red under it, and hangs a spot light down",
				bar >= 0 and lit.g > 0.5 and lit.g > 2.5 * lit.b and spot_down,
				"bar %d (part %d, Lamp %d) at plate %d; under it %.2f %.2f %.2f" % [bar, under_a, lamp_m, ceil_y - 1, lit.g, lit.b, lit.a])
		if DisplayServer.get_name() != "headless" and bar >= 0:
			var bar_at: Vector3 = s.brick_node.global_transform * Vector3((bar_cell.x + 0.5) * stud,
					(ceil_y - 1) * BrickWorld.get_plate_metres(), (bar_cell.z + 2.0) * stud)
			# From under it, a step to one side, looking up at it.
			c.look_at_from_position(bar_at - up * 1.5 + s.brick_node.global_basis.x.normalized() * 0.9
					- s.brick_node.global_basis.z.normalized() * 1.2, bar_at, up)
			await get_tree().create_timer(1.5).timeout
			await _shot("light_gate_lamp")
		if was_eye != null:
			was_eye.make_current()
		eye.queue_free()
		# Clouds (Lighting.md 2b): the world's layer is there, and its shadow
		# takes the sun where it stands -- overcast, a full cloud's share; clear,
		# none. The shader's sum is CloudLayer.shade_at's.
		var had := clouds.cover if clouds != null else 0.0
		var sun_up := 0.0
		var dark := 1.0
		var clear := 0.0
		if clouds != null:
			clouds.cover = 1.0
			clouds._push()
			dark = clouds.shade_at(inside)
			sun_up = clouds._strength()
			clouds.cover = 0.0
			clouds._push()
			clear = clouds.shade_at(inside)
			clouds.cover = had
			clouds._push()
		_check("the world's clouds shade the sun where they stand", clouds != null
				and is_equal_approx(clear, 1.0) and absf(dark - (1.0 - sun_up)) < 0.02
				and (sun_up <= 0.0 or dark < 0.7),
				"cover %.2f; overcast %.2f (a cloud takes %.2f), clear %.2f" % [had, dark, sun_up, clear])
		if DisplayServer.get_name() != "headless":
			# What the soft shadows cost (Lighting.md 2): the GPU's draw time
			# with the sun's size, without, and with again. A report, not a
			# check -- only trustworthy with the editor closed.
			var vp := get_viewport().get_viewport_rid()
			RenderingServer.viewport_set_measure_render_time(vp, true)
			var size := sun.light_angular_distance
			var ms := []
			for a in [size, 0.0, size, 0.0]:
				sun.light_angular_distance = a
				await _frames(20)
				var sum := 0.0
				for k in 120:
					await _frames(1)
					sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
				ms.append(sum / 120.0)
			sun.light_angular_distance = size
			print("[light] GPU draw, sun %.2f deg soft: %.2f / %.2f ms; hard: %.2f / %.2f ms" % [size, ms[0], ms[2], ms[1], ms[3]])
			# And the clouds (Lighting.md 2b): their layer and every surface's
			# shade, on and off. A report, as above.
			if clouds != null:
				var cover := clouds.cover
				var cms := []
				for cv in [cover, 0.0, cover, 0.0]:
					clouds.cover = cv
					await _frames(20)
					var sum := 0.0
					for k in 120:
						await _frames(1)
						sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
					cms.append(sum / 120.0)
				clouds.cover = cover
				print("[light] GPU draw, clouds on: %.2f / %.2f ms; off: %.2f / %.2f ms" % [cms[0], cms[2], cms[1], cms[3]])
			# 7: what each GI level costs and looks like, outside and in
			# (shots light_gate_gi<level>_out / _in; inside, the Glow floor
			# above is lit). Off again at the end.
			var gi_names := ["off", "screen", "sdfgi"]
			var gi_ms := {}
			for lvl in [LightRig.GI_OFF, LightRig.GI_SCREEN, LightRig.GI_SDFGI, LightRig.GI_OFF]:
				LightRig.set_gi(lvl)
				var floor_now: float = pb.brick_material.get_shader_parameter("grid_sky_floor")
				_check("GI %s set on the environment (the grid's sky off under SDFGI)" % gi_names[lvl], env.ssao_enabled == (lvl >= LightRig.GI_SCREEN)
						and env.ssil_enabled == (lvl >= LightRig.GI_SCREEN) and env.sdfgi_enabled == (lvl == LightRig.GI_SDFGI)
						and is_equal_approx(floor_now, 1.0 if lvl == LightRig.GI_SDFGI else BrickGridLight.SKY_FLOOR))
				for where in ["out", "in"]:
					if where == "out":
						c.look_at_from_position(from, inside, up)
					else:
						c.look_at_from_position(inside, s.brick_node.global_transform * Vector3(s.fx * stud, 1.4, s.fz * stud * 0.5), up)
					# SDFGI gathers its cascades over many frames.
					await _frames(90)
					var sum := 0.0
					for k in 120:
						await _frames(1)
						sum += RenderingServer.viewport_get_measured_render_time_gpu(vp)
					var gk := "%s_%s" % [gi_names[lvl], where]
					gi_ms[gk] = ("%.2f" % (sum / 120.0)) if not gi_ms.has(gk) else ("%s / %.2f" % [gi_ms[gk], sum / 120.0])
					await _shot("light_gate_gi%d_%s" % [lvl, where])
			print("[light] GPU draw by GI (ms): %s" % gi_ms)
		c.queue_free()
		cam.current = true
	print("[light] frames: worst %.1f ms" % _worst_ms)
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The system's gate (11.12): day and night at the spawn, off the home planet
# through a handoff, across to the nearest other body, onto its ground, and
# home again to what was left there. The clock runs.

func _run_system_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var home_day := data.day
	var h := system.hour_at(walker.global_position)
	_check("the spawn starts at noon, lit", absf(h - 12.0) < 0.5 and system.sunlight > 0.99, "%.2f h, sun %.2f" % [h, system.sunlight])
	var day_sky := sky_mat.sky_top_color.get_luminance()
	await _shot("system_gate_noon")
	# Half a day on: night. (The clock is analytic: set it.)
	system.t += home_day * 0.5
	await _frames(3)
	h = system.hour_at(walker.global_position)
	_check("half a day later it is midnight, no sun, a dark sky",
			(h < 0.5 or h > 23.5) and system.sunlight < 0.01 and sky_mat.sky_top_color.get_luminance() < day_sky * 0.2,
			"%.2f h, sun %.2f, sky %.3f of %.3f" % [h, system.sunlight, sky_mat.sky_top_color.get_luminance(), day_sky])
	_check("and the light is off", sun.light_energy < 0.01)
	await _shot("system_gate_night")
	system.t += home_day * 0.25
	await _frames(3)
	h = system.hour_at(walker.global_position)
	_check("a quarter on, morning: the sun near the horizon", absf(h - 6.0) < 0.5 and absf(system.sun_height) < 0.35,
			"%.2f h, height %.2f" % [h, system.sun_height])
	await _shot("system_gate_dawn")
	system.t += home_day * 0.25
	await _frames(3)
	# Something left on the home planet's ground.
	var marker := Node3D.new()
	marker.name = "SystemGateMarker"
	add_child(marker)
	marker.global_transform = Transform3D(Basis(Gravity.up_at(walker.global_position), 0.4), walker.global_position)
	var marker_local := planet.global_transform.affine_inverse() * marker.global_transform
	# Straight up and out of the shell, flying: the handoff must not jump.
	walker.flying = true
	walker.pitch = 0.0
	var prev := planet.global_transform.affine_inverse() * walker.global_position
	var step := 0.0
	var t1 := Time.get_ticks_msec()
	while system.anchor == planet and Time.get_ticks_msec() - t1 < 120000:
		var alt := planet.altitude_of(walker.global_position)
		walker.fly_speed = clampf(alt * 0.6, 20.0, 3000.0)
		walker.rise = 1.0
		await get_tree().physics_frame
		var rel := planet.global_transform.affine_inverse() * walker.global_position
		step = (rel - prev).length()
		prev = rel
	var kick := system.last_kick
	# The frame after the handoff: the walker goes on as it was going, seen from the planet.
	await get_tree().physics_frame
	var jump := (planet.global_transform.affine_inverse() * walker.global_position - prev).length()
	walker.rise = 0.0
	_check("off the home planet's shell: in space", system.anchor == null, "%.0f km up, the kick %.0f m/s" % [
			planet.altitude_of(walker.global_position) / 1000.0, kick.length()])
	_check("the handoff did not jump (the step after it as the steps before)", jump < step * 1.5 + 2.0,
			"%.1f m against %.1f m" % [jump, step])
	_check("the home planet sleeps: its ground gone, what was on it under it",
			planet.terrain == null and marker.get_parent() == planet and marker.process_mode == Node.PROCESS_MODE_DISABLED)
	# Across to the nearest other body.
	var target: PlanetBody = null
	for b in system.bodies:
		if b != planet and (target == null or (b.global_position - walker.global_position).length()
				< (target.global_position - walker.global_position).length()):
			target = b
	print("[planet] system gate: across to %s, %.0f km" % [target.data.planet_name,
			(target.global_position - walker.global_position).length() / 1000.0])
	# Onto its day side, mid-morning.
	var noon := target.global_basis.inverse() * (system.star.global_position - target.global_position).normalized()
	var side := noon.cross(Vector3.UP if absf(noon.y) < 0.9 else Vector3.RIGHT).normalized()
	var ok_arrive: bool = await _system_cross(target, noon.rotated(side, 0.5))
	_check("lands in daylight there", system.sunlight > 0.99, "%.2f, %.1f h" % [system.sunlight, system.hour_at(walker.global_position)])
	_check("arrived on %s: its anchor, the identity, its ground streamed" % target.data.planet_name,
			ok_arrive and system.anchor == target and target.global_basis.is_equal_approx(Basis()) and target.terrain != null)
	var over := target.altitude_of(walker.global_position) - target.data.height(target.dir_of(walker.global_position))
	_check("stands on its ground", walker.is_on_floor() and absf(over) < 0.5, "%.2f m over it, g %.1f" % [over, Gravity.strength()])
	await _shot("system_gate_other")
	# Up to the home planet's station: onto its roof, its bricks laid, its gravity.
	var st: SpaceStation = null
	for o in system.stations:
		if o.is_station() and o.data.parent == system.index_of(planet):
			st = o
	_check("the home planet has a station in orbit", st != null)
	if st != null:
		print("[planet] system gate: to %s, %.0f km up, round in %.1f min" % [st.data.orbital_name,
				(st.data.orbit_radius - data.radius) / 1000.0, st.data.orbit_period / 60.0])
		var ok_st: bool = await _station_cross(st)
		_check("on the station: its frame, its bricks laid and solid", ok_st and system.station == st and st.bricked,
				"bricks laid in %.1f ms" % st.lay_ms)
		var up := Gravity.up_at(walker.global_position)
		_check("standing on its roof, down through its deck", walker.is_on_floor() and up.dot(st.global_basis.y) > 0.999,
				"up off the deck's by %.2f deg" % rad_to_deg(acos(clampf(up.dot(st.global_basis.y), -1.0, 1.0))))
		_check("the home planet sleeps under it", planet.terrain == null and marker.get_parent() == planet)
		await _shot("system_gate_station")
	# Home, over the marker.
	var ok_home: bool = await _system_cross(planet, marker_local.origin.normalized())
	_check("home again: its anchor, its ground", ok_home and system.anchor == planet and planet.terrain != null)
	var back := planet.global_transform.affine_inverse() * marker.global_transform
	_check("what was left on it is where it was, on the scene again",
			marker.get_parent() == self and back.is_equal_approx(marker_local) and marker.process_mode == Node.PROCESS_MODE_INHERIT,
			"%.3f m off" % (back.origin - marker_local.origin).length())
	over = _over_ground(walker.global_position)
	_check("and stands on the home ground", walker.is_on_floor() and absf(over) < 0.5, "%.2f m" % over)
	await _shot("system_gate_home")
	print("[planet] system gate: %d handoffs; frames: worst %.1f ms; over 40 ms in play: %d %s" % [
			system.handoffs, _worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Carry the (frozen) walker to station `st`'s roof and stand it there once
## its bricks are solid. True when it got there.
func _station_cross(st: SpaceStation) -> bool:
	walker.frozen = true
	walker.flying = false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		var goal := st.global_transform * Vector3(0.0, st.height + 3.0, 0.0)
		var left := (goal - walker.global_position).length()
		if left < 1.0:
			break
		# Round the planet at height, not through it.
		var b := system.nearest(walker.global_position)
		var here := walker.global_position - b.global_position
		var there := goal - b.global_position
		var ang := here.angle_to(there)
		if ang > 0.4:
			goal = b.global_position + here.normalized().slerp(there.normalized(), 0.4 / ang) * maxf(here.length(), b.data.radius + 3000.0)
		var to := goal - walker.global_position
		var stride := clampf(left * 0.04, 1.0, 100000.0)
		walker.global_position += to.normalized() * minf(stride, to.length())
		await get_tree().physics_frame
	if system.station != st:
		return false
	t0 = Time.get_ticks_msec()
	while not st.bricked and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	var g := _ground_hit(walker.global_position)
	if g == Vector3.INF:
		return false
	walker.place(g + Gravity.up_at(g) * 0.5, st.global_basis.x)
	walker.frozen = false
	await get_tree().create_timer(3.0).timeout
	return true


## Carry the (frozen) walker to body `b` -- toward its centre, or down onto
## planet-local `dir` of it -- slowing as it nears, then onto its ground once
## that has streamed, and let it stand. True when it got there.
func _system_cross(b: PlanetBody, dir: Vector3) -> bool:
	walker.frozen = true
	walker.flying = false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 120000:
		var d := dir if dir != Vector3.ZERO else b.dir_of(walker.global_position)
		var goal := b.global_transform * (d * (b.data.radius + b.data.height(d) + 40.0))
		# Round the planet, not through it.
		var here := b.global_transform.affine_inverse() * walker.global_position
		var ang := here.normalized().angle_to(d)
		if ang > 0.4 and here.length() < b.data.radius * 6.0:
			goal = b.global_transform * (here.normalized().slerp(d, 0.4 / ang) * maxf(here.length(), b.data.radius + 3000.0))
		var to := goal - walker.global_position
		if to.length() < 5.0:
			break
		var stride := clampf(maxf(b.altitude_of(walker.global_position), 50.0) * 0.04, 2.0, 100000.0)
		walker.global_position += to.normalized() * minf(stride, to.length())
		await get_tree().physics_frame
	if system.anchor != b:
		return false
	# Down onto the ground once it is there.
	t0 = Time.get_ticks_msec()
	while _ground_hit(walker.global_position) == Vector3.INF and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var g := _ground_hit(walker.global_position)
	if g == Vector3.INF:
		return false
	walker.place(g + Gravity.up_at(g) * 0.5, -walker.global_transform.basis.z)
	walker.frozen = false
	await get_tree().create_timer(3.0).timeout
	return true


# The rocks gate (11.12 step 6): a jump to the nearest system with a ringed
# planet, the ring seen from afar, into it, its rocks drawn round the ship, and
# flown at one: stopped by it.

func _run_rocks_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	board()
	await _ship_out()
	var to := -1
	for k in system.universe.nearest(0, 40):
		for d in system.universe.system(k).bodies:
			if d.ring_outer > 0.0 and to < 0:
				to = k
	_check("a ringed planet among the 40 nearest systems", to >= 0)
	system.jump(to)
	await _frames(3)
	var world: PlanetBody = null
	for b in system.bodies:
		if b.ring != null and world == null:
			world = b
	print("[planet] rocks gate: %s of %s, ring %.0f-%.0f km; belt %s" % [world.data.planet_name, system.sys.system_name,
			world.data.ring_inner / 1000.0, world.data.ring_outer / 1000.0, str(system.belt != null)])
	var i := system.index_of(world)
	# Cruise to its shell, watching it.
	ship.boost = true
	t0 = Time.get_ticks_msec()
	var seen := false
	while ship.ref != world and Time.get_ticks_msec() - t0 < 60000:
		ship.aim(system.sys.pos(i, system.t) - ship.rel.origin, ship.rel.basis.y)
		ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
		if not seen and (ship.global_position - world.global_position).length() < 300000.0:
			seen = true
			ship.thrust = Vector3.ZERO
			await _look_back(world, "rocks_gate_far")
	ship.boost = false
	_check("in its shell", ship.ref == world and system.anchor == world)
	# Into the ring.
	var f := world.ring
	var mid := (f.inner + f.outer) * 0.5
	# Its nearest point, not one round the far side of the planet.
	var in_plane := f.transform.affine_inverse() * ship.rel.origin
	in_plane.y = 0.0
	var goal := f.transform * (in_plane.normalized() * mid)
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		var to_g := goal - ship.rel.origin
		if to_g.length() < 200.0:
			break
		ship.aim(to_g, ship.rel.basis.y)
		ship.thrust = Vector3(0.0, 0.0, clampf(to_g.length() / 8000.0, 0.03, 1.0))
		await _frames(1)
	ship.thrust = Vector3.ZERO
	await get_tree().create_timer(2.0).timeout
	f.refresh(f.transform.affine_inverse() * ship.rel.origin, 1.0)
	_check("in the ring: its rocks drawn round the ship", f.drawn > 20, "%d rocks" % f.drawn)
	await _shot("rocks_gate_in")
	if f.drawn == 0:
		print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail + 1])
		get_tree().quit(1)
		return
	# At the nearest rock.
	var at := f.transform.affine_inverse() * ship.rel.origin
	var best := Vector3.INF
	var c := RockField.cell_of(at)
	for x in range(c.x - 3, c.x + 4):
		for y in range(c.y - 2, c.y + 3):
			for z in range(c.z - 3, c.z + 4):
				for e in f.rocks_in(Vector3i(x, y, z)):
					if (e[0] as Vector3).distance_to(at) < best.distance_to(at):
						best = e[0]
	var rams0 := ship.rams
	t0 = Time.get_ticks_msec()
	while ship.rams == rams0 and Time.get_ticks_msec() - t0 < 40000:
		ship.aim(f.transform * best - ship.rel.origin, ship.rel.basis.y)
		ship.thrust = Vector3(0.0, 0.0, 0.02)
		await _frames(1)
	ship.thrust = Vector3.ZERO
	var gap := (f.transform.affine_inverse() * ship.rel.origin).distance_to(best)
	_check("a rock stops the ship", ship.rams > rams0 and gap > 5.0, "%.1f m from its centre" % gap)
	await _shot("rocks_gate_rock")
	print("[planet] rocks gate: frames: worst %.1f ms; over 40 ms in play: %d %s" % [_worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The debris gate (11.12 step 6): the top of the station cut off with blasts
# through a whole storey; it leaves in one rigid piece, drifting and turning with
# no body; the clock stopped or not, it goes on; out of reach, it is gone.

## Debris plan step 3: a piece near the ground falls to it; near the player a
## body that lands, far off it goes.
func _run_falling_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var up := Gravity.up_at(walker.global_position)
	var side := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD).normalized()
	var arrays := BoxMesh.new().get_mesh_arrays()
	var at := walker.global_position + side * 12.0 + up * 30.0
	system._on_drifted(arrays, Transform3D(Basis(), at), Vector3.ZERO, 30, buildings.brick_material, ship)
	t0 = Time.get_ticks_msec()
	while system.fallen.is_empty() and Time.get_ticks_msec() - t0 < 5000:
		await _frames(1)
	_check("near the ground and the player, a piece falls: a body under the planet", system.fallen.size() == 1
			and system.drifts.is_empty() and system.fallen[0].get_parent() == planet)
	if system.fallen.is_empty():
		print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
		get_tree().quit(1)
		return
	var body := system.fallen[0]
	t0 = Time.get_ticks_msec()
	while not body.freeze and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	var ground := _ground_hit(body.global_position)
	var above := body.global_position.distance_to(ground) if ground != Vector3.INF else INF
	_check("it lands and lies still on the ground", body.freeze and above < 3.0,
			"%.1f m over it, %.1f s" % [above, (Time.get_ticks_msec() - t0) / 1000.0])
	# Far from the player: it goes, shrinking.
	var far := walker.global_position + side * 3000.0 + up * 30.0
	system._on_drifted(arrays, Transform3D(Basis(), far), Vector3.ZERO, 30, buildings.brick_material, ship)
	t0 = Time.get_ticks_msec()
	while system.drifts.is_empty() and Time.get_ticks_msec() - t0 < 5000:
		await _frames(1)
	var made := not system.drifts.is_empty()
	await get_tree().create_timer(0.5).timeout
	var going := not system.drifts.is_empty() and (system.drifts[0] as Drift).dying >= 0.0
	await get_tree().create_timer(1.5).timeout
	_check("far from the player it shrinks away instead", made and going and system.drifts.is_empty() and system.fallen.size() == 1)
	# A station's piece: it comes in at the station's speed over the ground.
	var st: SpaceStation = null
	for o in system.stations:
		if o.is_station() and o.data.parent == system.index_of(planet):
			st = o
	system._on_drifted(arrays, Transform3D(Basis(), walker.global_position - side * 12.0 + up * 30.0), Vector3.ZERO, 30,
			buildings.brick_material, st)
	t0 = Time.get_ticks_msec()
	while system.fallen.size() < 2 and Time.get_ticks_msec() - t0 < 5000:
		await _frames(1)
	var fast: RigidBody3D = system.fallen[-1] if system.fallen.size() == 2 else null
	var speed := fast.linear_velocity.length() if fast != null else 0.0
	var under := INF
	var went := 0.0
	var start := fast.global_position if fast != null else Vector3.ZERO
	t0 = Time.get_ticks_msec()
	while is_instance_valid(fast) and not fast.freeze and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
		if is_instance_valid(fast):
			var dir := planet.to_local(fast.global_position).normalized()
			under = minf(under, planet.to_local(fast.global_position).length() - data.surface_point(dir).length())
			went = fast.global_position.distance_to(start)
	_check("at a station's speed it lands, not through the ground", is_instance_valid(fast) and fast.freeze and under > -1.0,
			"in at %.0f m/s, %.0f m on, lowest %.1f m over the ground, put back %d time(s)" % [speed, went, under, system.under_ground_saves])
	# Twenty bricks off the parked ship's top, by its own way of sending a piece
	# off: they fall, lie still, and are saved and back where they lie.
	t0 = Time.get_ticks_msec()
	while ship.chunk < 0 and Time.get_ticks_msec() - t0 < 15000:
		await _frames(1)
	var n0 := system.fallen.size()
	if ship.chunk >= 0:
		var tops: Array = ship.bricks.get_block_boxes(ship.chunk)
		tops.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool: return (a.pos as Vector3).y > (b2.pos as Vector3).y)
		var ids := PackedInt32Array()
		for bx: Dictionary in tops:
			if not ids.has(int(bx.block)):
				ids.append(int(bx.block))
			if ids.size() >= 20:
				break
		ship._send_off(ship.bricks.split_island(ship.chunk, ids), ids.size(), [])
	t0 = Time.get_ticks_msec()
	while (system.fallen.size() <= n0 or not system.fallen[-1].freeze) and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	var lying: RigidBody3D = system.fallen[-1] if system.fallen.size() > n0 else null
	var where := planet.to_local(lying.global_position) if lying != null else Vector3.INF
	var saved_fallen: Array = bytes_to_var(var_to_bytes(system.fallen_to_save(planet)))
	for f in system.fallen:
		if is_instance_valid(f):
			f.queue_free()
	system.fallen.clear()
	system.restore_fallen(planet, saved_fallen)
	var near_off := INF
	var drawn := false
	for f in system.fallen:
		near_off = minf(near_off, planet.to_local(f.global_position).distance_to(where))
		drawn = drawn or not f.find_children("*", "MeshInstance3D", false, false).is_empty()
	_check("a ship's piece lies still, and is saved and back where it lies", lying != null and lying.freeze
			and not saved_fallen.is_empty() and system.fallen.size() == saved_fallen.size() and near_off < 0.05 and drawn,
			"%d saved, %d back, %.3f m off" % [saved_fallen.size(), system.fallen.size(), near_off])
	body = system.fallen[0] if not system.fallen.is_empty() else null
	# The first one in the picture, where it lies.
	if is_instance_valid(body):
		var to := body.global_position - walker.camera.global_position
		walker.place(walker.global_position, to)
		walker.pitch = asin(clampf(to.normalized().dot(Gravity.up_at(walker.global_position)), -1.0, 1.0))
		await _frames(4)
	await _shot("falling_gate")
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Someone on a piece that leaves (Docs/RoomModules.md 7.8): the walker on top
## of a generated station's section, its joints shot away; the section leaves
## with the walker on it, a body of its bricks under them. Broken off, it has no
## generator: nothing pulls on it (7.12), and the walker floats, its up its own,
## falling nowhere. Put back in the station's field head over heels, the walker
## comes into its down over a moment (not in a tick) and lands on its feet.
func _run_adrift_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	# A generated station (its sections cut off at their joints, 7.3).
	var st: SpaceStation = null
	for o in system.stations:
		if o.is_station() and o.recipe != null and (st == null or o.global_position.distance_to(walker.global_position)
				< st.global_position.distance_to(walker.global_position)):
			st = o
	if st == null:
		for o in system.stations:
			if o.is_station() and o.data.layout == "generated":
				st = o
	if st == null:
		# Home's system has only its tower: home's station grown as any other is.
		for o in system.stations:
			if o.is_station() and o.data.parent == system.index_of(planet):
				st = o
		if st != null:
			if st.chunk >= 0:
				st.deactivate()
			st._template = -1
			st.data.layout = "generated"
			st.prepare()
	if st == null or st.recipe == null:
		_check("a generated station", false, str(system.stations.map(func(o) -> String: return "%s %s %s" % [o.data.orbital_name, o.data.kind, o.data.layout])))
		print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
		get_tree().quit(1)
		return
	# Its section with the fewest joints (not the keel's), the walker stood on its top.
	var r := st.recipe
	var of := BuildSections.of_build(r)
	var joints := BuildSections._joints(BuildSections._cells(r, of))
	var touch := {}
	for j: Dictionary in joints:
		touch[int(j.a)] = int(touch.get(int(j.a), 0)) + 1
		touch[int(j.b)] = int(touch.get(int(j.b), 0)) + 1
	var size := {}
	for i in of.size():
		size[of[i]] = int(size.get(of[i], 0)) + 1
	var leaf := -1
	for k in touch:
		if int(k) != 0 and (leaf < 0 or int(touch[k]) < int(touch[leaf])
				or int(touch[k]) == int(touch[leaf]) and int(size[k]) > int(size[leaf])):
			leaf = int(k)
	var top := Vector3i(0, -1, 0)
	var n_leaf := 0
	var sum := Vector3.ZERO
	for i in r.size():
		if of[i] == leaf:
			n_leaf += 1
			sum += Vector3(r.cell_of(i))
	var mid := sum / maxf(n_leaf, 1)
	for i in r.size():
		var c := r.cell_of(i)
		if of[i] == leaf and absf(c.x - mid.x) < 2.0 and absf(c.z - mid.z) < 2.0:
			var ty := c.y + BuildRecipe.part_size(r.part_of(i)).y
			if ty > top.y:
				top = Vector3i(c.x, ty, c.z)
	var org := r.origin()
	# Over its top, held there (frozen) until it is the frame and its bricks are in; then down onto it.
	walker.frozen = true
	walker.flying = false
	var over := st.cell_point(top - org) + Vector3(0.0, 3.0, 0.0)
	t0 = Time.get_ticks_msec()
	while not (system.station == st and st.bricked) and Time.get_ticks_msec() - t0 < 60000:
		walker.global_position = st.global_transform * over
		await get_tree().physics_frame
	var g := _ground_hit(st.global_transform * over)
	var ok_st := system.station == st and st.bricked and g != Vector3.INF
	if ok_st:
		walker.place(g + Gravity.up_at(g) * 0.3, st.global_basis.x)
		walker.frozen = false
		await get_tree().create_timer(2.0).timeout
	_check("on a generated station, its bricks solid", ok_st, st.data.orbital_name)
	_check("standing on top of one of its sections", leaf > 0 and top.y >= 0 and walker.is_on_floor(),
			"section %d of %d bricks, %d joint(s), its top %s" % [leaf, n_leaf, int(touch.get(leaf, 0)), str(top)])
	await _shot("adrift_gate_before")
	# Its joints shot away: the section cut off, the walker on it.
	var ids := PackedInt32Array()
	for j: Dictionary in joints:
		if int(j.a) == leaf or int(j.b) == leaf:
			for cell: Vector3i in j.cells:
				var b := st.bricks.block_at(st.chunk, cell - org)
				if b >= 0 and not ids.has(b):
					ids.append(b)
	st.bricks.kill_blocks(st.chunk, ids)
	st._after_kill(ids)
	# Pieces leave over several frames: the one the walker is on.
	var d: Drift = null
	t0 = Time.get_ticks_msec()
	while d == null and Time.get_ticks_msec() - t0 < 15000:
		await _frames(1)
		for e: Drift in system.drifts:
			if e.riders.has(walker):
				d = e
	_check("the section leaves whole with the walker aboard, a body of its bricks under them", d != null and d.body.is_valid(),
			"%d piece(s) of %s bricks" % [system.drifts.size(), str(system.drifts.map(func(e) -> int: return (e as Drift).bricks))])
	if d == null:
		print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
		get_tree().quit(1)
		return
	# Broken off, no generator: nothing pulls on it. The walker floats where it
	# was let go, its up its own -- not pulled down after the station's down.
	await get_tree().create_timer(0.5).timeout
	var up0 := walker.global_transform.basis.y
	var w0 := walker.global_position
	var down0 := Gravity.down_at(st.global_position)
	await get_tree().create_timer(3.0).timeout
	var fell := (walker.global_position - w0).dot(st.global_basis * Vector3.DOWN)
	_check("on it nothing pulls, no generator: the walker floats, its up its own",
			Gravity.pull_at(walker.global_position) == 0.0 and walker.floating and fell < 1.0
			and walker.velocity.length() < 1.5 and walker.global_transform.basis.y.angle_to(up0) < 0.05,
			"pull %.1f, floating %s, fell %.2f m in 3 s, %.2f m/s, up turned %.1f deg (down %s)" % [
				Gravity.pull_at(walker.global_position), walker.floating, fell, walker.velocity.length(),
				rad_to_deg(walker.global_transform.basis.y.angle_to(up0)), str(down0)])
	await _shot("adrift_gate_aboard")
	# Back in the station's field over its deck, head over heels: its down again,
	# the walker righted over a moment (zylanntest's turn, 4 rad/s), on its feet.
	# Over the top of its first section (the core's: it stays), clear of the piece.
	var top0 := Vector3i(0, -1, 0)
	var sum0 := Vector3.ZERO
	var n0 := 0
	for i in r.size():
		if of[i] == 0:
			n0 += 1
			sum0 += Vector3(r.cell_of(i))
	var mid0 := sum0 / maxf(n0, 1)
	for i in r.size():
		var c := r.cell_of(i)
		if of[i] == 0 and absf(c.x - mid0.x) < 2.0 and absf(c.z - mid0.z) < 2.0:
			var ty := c.y + BuildRecipe.part_size(r.part_of(i)).y
			if ty > top0.y:
				top0 = Vector3i(c.x, ty, c.z)
	# In its field (2 m over its bricks), the walker's head a hair over the roof.
	var deck := st.cell_point(top0 - org) + Vector3(0.0, 1.9, 0.0)
	await get_tree().physics_frame
	walker.global_position = st.global_transform * deck
	walker.global_basis = st.global_basis * Basis(Vector3.RIGHT, PI * 0.9)
	walker.velocity = Vector3.ZERO
	walker.reset_physics_interpolation()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var st_up := st.global_basis.y
	var early := rad_to_deg(walker.global_transform.basis.y.angle_to(st_up))
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000 and not (walker.is_on_floor() and walker.global_transform.basis.y.angle_to(st_up) < 0.02):
		await get_tree().physics_frame
	var late := rad_to_deg(walker.global_transform.basis.y.angle_to(st_up))
	_check("back in the station's field head over heels: righted over a moment, not a tick, and on its feet",
			Gravity.pull_at(walker.global_position) > 1.0 and not walker.floating and early > 120.0
			and late < 2.0 and walker.is_on_floor(),
			"%.0f deg off its up two ticks in, %.1f deg at %.1f s, on the floor %s" % [early, late,
				(Time.get_ticks_msec() - t0) / 1000.0, walker.is_on_floor()])
	await _shot("adrift_gate_turned")
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _run_debris_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var st: SpaceStation = null
	for o in system.stations:
		if o.is_station() and o.data.parent == system.index_of(planet):
			st = o
	var ok_st: bool = await _station_cross(st)
	_check("on the station, its bricks solid", ok_st and st.bricked)
	walker.frozen = true
	walker.global_position = st.global_transform * Vector3(0.0, st.height + 60.0, 0.0)
	var stud := BrickWorld.get_stud_metres()
	var n0 := st.bricks.get_alive_block_count(st.chunk)
	await _shot("debris_gate_before")
	# A storey blown out all through, its walls and the stairs up the middle.
	var y := st.height * 0.62
	var x := 0.0
	while x <= st.data.fx * stud:
		var z := 0.0
		while z <= st.data.fz * stud:
			_structure_hit(st.global_transform * (st.frame * Vector3(x, y, z)), Vector3.ZERO, {"blast": true, "radius": 2.5, "hp": 0})
			z += 2.0
		x += 2.0
	t0 = Time.get_ticks_msec()
	while system.drifts.is_empty() and Time.get_ticks_msec() - t0 < 15000:
		await _frames(1)
	_check("what was above leaves whole, a rigid piece with no body", not system.drifts.is_empty(), "%d piece(s), the largest %d bricks" % [
			system.drifts.size(), 0 if system.drifts.is_empty() else (system.drifts[0] as Drift).bricks])
	if system.drifts.is_empty():
		print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
		get_tree().quit(1)
		return
	await get_tree().create_timer(0.5).timeout
	var d: Drift = system.drifts[0]
	_check("it is drawn, as its bricks", d.node.get_child_count() > 0, "%d" % d.node.get_child_count())
	var p0 := d.node.global_position
	var b0 := d.node.global_basis
	await _shot("debris_gate_cut")
	await get_tree().create_timer(3.0).timeout
	var moved := d.node.global_position.distance_to(p0)
	var turned := rad_to_deg(b0.get_rotation_quaternion().angle_to(d.node.global_basis.get_rotation_quaternion()))
	_check("it drifts off and turns", moved > 1.0 and turned > 1.0, "%.1f m, %.1f deg in 3 s" % [moved, turned])
	await _shot("debris_gate_drift")
	var n1 := st.bricks.get_alive_block_count(st.chunk)
	_check("the station keeps the rest", n1 < n0 and n1 > 0, "%d -> %d" % [n0, n1])
	# Away and back: laid as it was left, what went not laid again.
	walker.global_position = st.global_transform * Vector3(0.0, st.height + 400.0, 0.0)
	await _frames(5)
	_check("left: its bricks freed", system.station != st and st.chunk < 0)
	_check("and from afar it looks it: what it last drew, not its whole shell", st.wreck != null and not st.shell.visible)
	walker.global_position = st.global_transform * Vector3(0.0, st.height + 60.0, 0.0)
	t0 = Time.get_ticks_msec()
	while not st.bricked and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	var n2 := st.bricks.get_alive_block_count(st.chunk) if st.chunk >= 0 else -1
	_check("back: laid as it was left, what drifted off still gone", n2 == n1, "%d" % n2)
	_check("its far look gone once its bricks are in", st.wreck == null and not st.shell.visible)
	# Saved and back (PlanetSystem.drifts_to_save, through bytes as a file has it).
	var was_at := d.node.global_position
	var was_n := system.drifts.size()
	var saved_drifts: Array = bytes_to_var(var_to_bytes(system.drifts_to_save()))
	for e: Drift in system.drifts:
		system._drop_body(e)
		e.node.queue_free()
	system.drifts.clear()
	system.restore_drifts(saved_drifts)
	await _frames(4)
	var back_off := INF
	for e: Drift in system.drifts:
		back_off = minf(back_off, e.node.global_position.distance_to(was_at))
	_check("saved and back: each piece adrift, drawn, on its way", system.drifts.size() == was_n and back_off < 1.0
			and (system.drifts[0] as Drift).look != null, "%d of %d, %.2f m off, %d bytes" % [system.drifts.size(), was_n, back_off,
			var_to_bytes(saved_drifts).size()])
	d = system.drifts[0]
	# Far off it shrinks rather than pops, and grows back the same way.
	var off := d.node.global_position.distance_to(_anchor())
	var seen := system.drift_seen
	var hidden := system.drift_hidden
	system.drift_seen = off * 0.5
	system.drift_hidden = off * 2.0
	await _frames(3)
	var small := d.look.scale.x
	system.drift_seen = seen
	system.drift_hidden = hidden
	await _frames(3)
	_check("far off it shrinks, not pops; near again, its own size", small > 0.0 and small < 1.0 and d.look.scale.x == 1.0,
			"%.2f, then %.2f, %.0f m off" % [small, d.look.scale.x, off])
	# A wreck's pieces stay round it while the player is away.
	system.drift_reach = 20.0
	await _frames(5)
	_check("out of reach, but near where it left: it waits", not system.drifts.is_empty())
	# Out of reach, and gone from where it left.
	system.drift_home = 0.0
	await _frames(5)
	_check("out of reach it is gone", system.drifts.is_empty())
	# As a save leaves it: damage known, nothing laid this run.
	walker.global_position = st.global_transform * Vector3(0.0, st.height + 400.0, 0.0)
	await _frames(5)
	st.wreck.free()
	st.wreck = null
	st.shell.visible = true
	st.process_mode = Node.PROCESS_MODE_INHERIT
	t0 = Time.get_ticks_msec()
	while st.wreck == null and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	_check("a save's damage: laid once on the way in, for its far look", st.wreck != null and not st.shell.visible and st.chunk < 0,
			"%.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	print("[planet] debris gate: frames: worst %.1f ms; over 40 ms in play: %d %s" % [_worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The jump gate (11.12 step 5): out of the home planet's shell, the map, a jump
# to the nearest system with a settled world, down on it, off, and home to what
# was left there.

func _run_jump_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var marker := Node3D.new()
	marker.name = "JumpGateMarker"
	add_child(marker)
	marker.global_transform = Transform3D(Basis(), walker.global_position)
	var marker_local := planet.global_transform.affine_inverse() * marker.global_transform
	board()
	_check("no jump from the ground", not system.can_jump() and not system.jump(5))
	await _ship_out()
	_check("in open space the drive works", system.can_jump())
	open_map()
	await _frames(3)
	await _shot("jump_gate_map")
	_check("the map lists the ten nearest, nearest first", map.rows.size() == 10
			and float(map.rows[0][5]) <= float(map.rows[1][5]) and float(map.rows[1][5]) <= float(map.rows[9][5]),
			"%s at %.0f ly" % [map.rows[0][1], map.rows[0][5]])
	# The nearest with a settled world.
	for i in map.rows.size():
		if int(map.rows[i][3]) > 0:
			map.pick = i
			break
	var to := map.chosen()
	var was: StarSystem = system.sys
	map.visible = false
	var ok_jump := system.jump(to)
	_check("the jump: another system, home hidden, the ship in open space", ok_jump and system.sys != was
			and system.system_index == to and not planet.visible and system.frame_node() == ship,
			"%s, %d bodies" % [system.sys.system_name, system.bodies.size()])
	await _frames(3)
	await _shot("jump_gate_arrived")
	var target: PlanetBody = null
	for b in system.bodies:
		if target == null and not b.data.towns.is_empty():
			target = b
	var off := (ship.global_position - target.global_position).length()
	_check("set down short of its first settled world, clear of its shell",
			off > target.data.radius * PlanetSystem.SHELL and off < 400000.0, "%.0f km from %s" % [off / 1000.0, target.data.planet_name])
	var ok_land: bool = await _ship_down_on(target)
	_check("down on it", ok_land and ship.landed and system.anchor == target, "%s, %.1f m" % [target.data.planet_name, ship.altitude])
	await _shot("jump_gate_landed")
	unboard()
	await get_tree().create_timer(3.0).timeout
	_check("out, standing on a world of another system", walker.is_on_floor() and system.anchor == target)
	board()
	await _ship_out()
	var ok_back := system.jump(0)
	_check("back to the home system: home on its own orbit, shown", ok_back and system.sys == was and planet.visible
			and system.bodies.has(planet) and system.sys.home >= 0)
	await _ship_down_on(planet, marker_local.origin.normalized())
	_check("down on home", ship.landed and system.anchor == planet, "%.1f m" % ship.altitude)
	unboard()
	await get_tree().create_timer(3.0).timeout
	var back := planet.global_transform.affine_inverse() * marker.global_transform
	_check("what was left there is where it was, on the scene again", marker.get_parent() == self and back.is_equal_approx(marker_local),
			"%.3f m off" % (back.origin - marker_local.origin).length())
	print("[planet] jump gate: %d handoffs; frames: worst %.1f ms; over 40 ms in play: %d %s" % [
			system.handoffs, _worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Straight up and out of the planet's shell, the ship then the frame.
func _ship_out() -> void:
	ship.thrust = Vector3(0.0, 1.0, 0.0)
	ship.boost = true
	var t0 := Time.get_ticks_msec()
	while system.frame_node() != ship and Time.get_ticks_msec() - t0 < 90000:
		await _frames(1)
	ship.thrust = Vector3.ZERO
	ship.boost = false
	await _frames(2)


## The ship flown to body `b` and set down on it (near planet-local `dir`, if
## given): cruising in, round it at height, down level. True when down.
func _ship_down_on(b: PlanetBody, dir := Vector3.ZERO) -> bool:
	var i := system.index_of(b)
	# Over the point once, it goes down: going round again from low down it climbs
	# back to height.
	var over := dir == Vector3.ZERO
	ship.boost = true
	var t0 := Time.get_ticks_msec()
	while ship.ref != b and Time.get_ticks_msec() - t0 < 120000:
		if ship.ref == null:
			ship.aim(system.sys.pos(i, system.t) - ship.rel.origin, ship.rel.basis.y)
		ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
	t0 = Time.get_ticks_msec()
	while not ship.landed and Time.get_ticks_msec() - t0 < 120000:
		var r := ship.rel.origin
		var down := -r.normalized()
		var ang := 0.0 if over else r.normalized().angle_to(dir)
		over = over or ang <= 0.02
		if not over:
			# Round to over `dir`, at height.
			var goal := r.normalized().slerp(dir, minf(0.2 / ang, 1.0)) * maxf(r.length(), b.data.radius + 4000.0)
			ship.aim(goal - r, -down)
			# Slowing as it nears: at full speed it goes round the point for good.
			ship.thrust = Vector3(0.0, 0.0, clampf(ang * r.length() / 2000.0, 0.05, 1.0))
		elif ship.altitude > 3000.0:
			ship.aim(down, ship.rel.basis.y)
			ship.thrust = Vector3(0.0, 0.0, 1.0)
		else:
			# Along the ground from however it points: its tail, or, nose down, its back.
			var along := ship.rel.basis.z - down * ship.rel.basis.z.dot(down)
			if along.length_squared() < 0.01:
				along = ship.rel.basis.y - down * ship.rel.basis.y.dot(down)
			ship.aim(-along.normalized(), -down)
			ship.thrust = Vector3(0.0, -1.0, 0.0)
		ship.boost = ship.altitude > 20000.0
		await _frames(1)
	ship.thrust = Vector3.ZERO
	ship.boost = false
	await get_tree().create_timer(1.0).timeout
	return ship.landed and ship.ref == b


# The seat's gate: how smooth the ship is near a planet; where space begins; out
# of the seat on foot, wherever it is; the map from anywhere.

## How unevenly the camera moves past the ground: the change in its speed from one
## drawn frame to the next, over its mean, while the ship cruises level.
func _ship_judder(frames: int) -> float:
	var last := ship.camera.get_global_transform_interpolated().origin
	var speeds: Array[float] = []
	var step := get_process_delta_time()
	for k in frames:
		await get_tree().process_frame
		# This signal comes before the frame's _process: what moved it was the last step.
		var at := ship.camera.get_global_transform_interpolated().origin
		speeds.append(at.distance_to(last) / maxf(step, 1e-4))
		last = at
		step = get_process_delta_time()
	var mean := 0.0
	for v in speeds:
		mean += v
	mean /= speeds.size()
	# One frame against the next: the speed the cap gives it wanders, slowly, by height.
	var spread := 0.0
	for k in range(1, speeds.size()):
		spread += (speeds[k] - speeds[k - 1]) * (speeds[k] - speeds[k - 1])
	return sqrt(spread / (speeds.size() - 1)) / maxf(mean, 0.001)


func _run_seat_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var key := func(k: Key) -> void:
		_ship_key(k)
		await _frames(2)
	await key.call(KEY_M)
	_check("the map opens on the ground, saying why no jump", map.visible and map.note.contains("gravity"), map.note)
	await key.call(KEY_J)
	_check("and J does not jump from here", system.system_index == 0 and map.visible)
	await key.call(KEY_M)
	# Out to the ship and into its seat, on foot.
	pawn.place(_ground_hit(ship.global_transform * ship.seat() + ship.global_basis.z * 12.0))
	await get_tree().create_timer(0.5).timeout
	board()
	ship.thrust = Vector3(0.0, 1.0, 0.0)
	await get_tree().create_timer(5.0).timeout
	ship.thrust = Vector3(0.0, 0.0, 0.5)
	await get_tree().create_timer(3.0).timeout
	var judder: float = await _ship_judder(180)
	_check("smooth past the ground (the camera's speed even from frame to frame)", judder < 0.05,
			"%.3f at %.0f m/s, %.0f m up, %.0f fps" % [judder, ship.vel.length(), ship.altitude, Engine.get_frames_per_second()])
	# Out of the seat in the air: on foot on its floor, not flying, not on its roof.
	var stand_on_deck := func() -> bool:
		var since := Time.get_ticks_msec()
		while (_stepping_out >= 0 or not pawn.is_on_floor()) and Time.get_ticks_msec() - since < 6000:
			await _frames(1)
		await get_tree().create_timer(1.0).timeout
		var y: float = ship.to_local(pawn.feet()).y
		print("[planet] seat gate: stood at %.2f m in the ship, on the floor %s, on foot %s" % [y, pawn.is_on_floor(), on_foot])
		return on_foot and pawn.is_on_floor() and y < ship.height * 0.5
	await key.call(KEY_E)
	var ok_air: bool = await stand_on_deck.call()
	_check("out of the seat in the air: on foot, on its floor", ok_air and not walker.flying)
	_check("it holds there, level", ship.vel.length() < 0.1 and ship.global_basis.y.dot(Gravity.up_at(ship.global_position)) > 0.9,
			"%.2f m/s" % ship.vel.length())
	await key.call(KEY_E)
	_check("and back in the seat", piloting)
	await _ship_out()
	_check("open space: the ship is the frame, the jump there to make", system.frame_node() == ship and system.can_jump() and system.jump_block() == "")
	# Every other planet marked; turned to one, it is on the screen, turned away, an arrow.
	await _frames(3)
	var far: Array = []
	for i in system.bodies.size():
		if system.sys.bodies[i].parent < 0 and system.bodies[i] != planet:
			far.append(i)
	var named := func(i: int) -> Array:
		for e in markers.rows:
			if e[0] == system.bodies[i].data.planet_name:
				return e
		return []
	# Windowed only: headless, the viewport has no size to mark.
	if DisplayServer.get_name() != "headless":
		var all_marked := markers.visible
		for i in far:
			all_marked = all_marked and not named.call(i).is_empty()
		_check("the other planets marked, by name and distance", all_marked and not far.is_empty(), "%d marked" % markers.rows.size())
		ship.aim(system.sys.pos(far[0], system.t) - ship.rel.origin, ship.rel.basis.y)
		await _frames(3)
		var ahead: Array = named.call(far[0])
		_check("turned to one, its mark is on the screen", not ahead.is_empty() and ahead[3], str(ahead))
		await _shot("seat_gate_markers")
		ship.aim(ship.rel.origin - system.sys.pos(far[0], system.t), ship.rel.basis.y)
		await _frames(3)
		var behind: Array = named.call(far[0])
		_check("turned away, an arrow at the edge of the screen", not behind.is_empty() and not behind[3], str(behind))
		await _shot("seat_gate_markers_behind")
	await key.call(KEY_E)
	var ok_deck: bool = await stand_on_deck.call()
	_check("out of the seat in open space: on foot on its deck, its own gravity", ok_deck and Gravity.strength() > 1.0, "%.1f m/s2" % Gravity.strength())
	# Its generator off (G): nothing pulls on its deck; on again, its gravity and the deck (7.12).
	await key.call(KEY_G)
	await get_tree().create_timer(0.5).timeout
	var off_ok := not ship.data.gravity_on and Gravity.pull_at(pawn.feet()) == 0.0 and pawn.floating
	await key.call(KEY_G)
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 4000 and not pawn.is_on_floor():
		await get_tree().physics_frame
	_check("its generator off, nothing pulls on its deck; on again, its gravity, on its deck",
			off_ok and ship.data.gravity_on and Gravity.pull_at(pawn.feet()) > 1.0 and pawn.is_on_floor(),
			"off: floating %s; on: %.1f m/s2, on the floor %s" % [off_ok, Gravity.pull_at(pawn.feet()), pawn.is_on_floor()])
	await key.call(KEY_M)
	_check("the map from the deck, nothing against a jump", map.visible and map.note == "")
	var was := system.system_index
	await key.call(KEY_DOWN)
	_ship_key(KEY_J)
	await get_tree().create_timer(1.0).timeout
	_check("the jump from the deck", system.system_index != was and system.frame_node() == ship, system.sys.system_name)
	var ok_after: bool = await stand_on_deck.call()
	_check("still standing on it", ok_after)
	# Off the ship: nothing pulls.
	var away := ship.global_position + ship.global_basis.x * (ship.field * 2.0)
	pawn.place(away)
	await get_tree().create_timer(1.0).timeout
	_check("off the ship in open space, nothing pulls", system.frame_node() == null and Gravity.strength() == 0.0, "%.1f m/s2" % Gravity.strength())
	_check("on foot, no marks", not markers.visible)
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The hull's gate: the parked ship generated (ShipBuild, Docs/RoomModules.md
# 7.5) -- its bricks laid with nothing loose, walked into through its airlock,
# flown from the bridge's seat with nothing shaken loose, stood in on its floor.

func _run_hull_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	_check("the parked ship is a generated one, with an airlock", ship.recipe != null and ship.airlock_cell.x >= 0,
			"%d bricks, grown in %.0f ms" % [ship.recipe.size() if ship.recipe else 0, ship.grow_ms])
	if ship.recipe == null or ship.airlock_cell.x < 0:
		get_tree().quit(1)
		return
	# Its bricks laid with the player by it, its gangway down from the airlock.
	var lock := ship.airlock_cell
	var door := ship.global_transform * ((ship.cell_point(lock) + ship.cell_point(lock + Vector3i(0, 0, 1))) * 0.5)
	var inside := ship.global_transform * ((ship.cell_point(lock + Vector3i(4, 0, 0)) + ship.cell_point(lock + Vector3i(4, 0, 1))) * 0.5)
	var outward := (door - inside).normalized()
	pawn.place(_ground_hit(door + outward * 4.0))
	var t1 := Time.get_ticks_msec()
	while (not ship.bricked or ship.gangway == null) and Time.get_ticks_msec() - t1 < 30000:
		await _frames(1)
	var loose: Array = ship.bricks.find_detached_groups(ship.chunk) if ship.chunk >= 0 else []
	var laid := ship.bricks.get_alive_block_count(ship.chunk) if ship.chunk >= 0 else 0
	_check("laid in bricks with the player by it, every brick, nothing loose", ship.bricked and laid == ship.recipe.size() and loose.is_empty(),
			"%d of %d in %.1f s, %d loose group(s)" % [laid, ship.recipe.size(), (Time.get_ticks_msec() - t1) / 1000.0, loose.size()])
	var reach := ship.gangway_steps * SpaceShip.GANG_TREAD * BrickWorld.get_stud_metres()
	var foot := _ground_hit(door + outward * (reach + 2.5))
	await get_tree().create_timer(BuildDoors.RESYNC + 0.2).timeout
	_check("its doors hung in its doorways (its recipe's)", ship.doors != null and ship.doors.count() > 0
			and ship.doors.count() == BuildDoors.of(ship.recipe).size(),
			"%d of %d" % [ship.doors.count() if ship.doors else 0, BuildDoors.of(ship.recipe).size()])
	_check("a gangway of bricks down from its airlock to the ground", ship.gangway != null and ship.gangway_steps > 0,
			"%d step(s), the sill %.2f m over the ground at its foot" % [ship.gangway_steps, (door - foot).dot(Gravity.up_at(door))])
	# On the brick grid for its Glow bricks' light, its sky left alone: the
	# cabin box stands for its own lights (Docs/Lighting.md 6.1).
	_boxes_at = 0
	_ambient_boxes()
	var floor_v: Variant = ship.brick_material.get_shader_parameter("grid_sky_floor") if ship.brick_material else null
	_check("on the brick grid for its lamps, its sky left alone", grid_light.tracked("m%d" % ship.get_instance_id())
			and floor_v != null and is_equal_approx(float(floor_v), 1.0), "sky floor %s" % str(floor_v))
	# A look at it from off its stern quarter: the housings and the fin on its roof.
	var aside := Gravity.flat(ship.global_basis.x, Gravity.up_at(door)).normalized()
	var off := _ground_hit(door + outward * 28.0 + aside * 18.0)
	if off != Vector3.INF:
		pawn.place(off)
		await get_tree().create_timer(0.5).timeout
		_face(Gravity.flat(ship.global_position - off, Gravity.up_at(off)).normalized())
		await get_tree().create_timer(0.5).timeout
		await _shot("hull_gate_outside")
	# From its foot, up it and in.
	pawn.place(foot)
	await get_tree().create_timer(0.5).timeout
	_face(Gravity.flat(inside - foot, Gravity.up_at(foot)).normalized())
	await get_tree().create_timer(0.5).timeout
	await _shot("hull_gate_stern")
	Input.action_press(&"move_forward")
	var t2 := Time.get_ticks_msec()
	var c := ship.cell_at(pawn.feet())
	while Time.get_ticks_msec() - t2 < 10000 and c.x < lock.x + 3.0:
		await get_tree().physics_frame
		c = ship.cell_at(pawn.feet())
	Input.action_release(&"move_forward")
	await get_tree().create_timer(1.0).timeout
	c = ship.cell_at(pawn.feet())
	_check("walked up the gangway and in through the airlock, standing on its deck", c.x > lock.x + 1.0
			and pawn.is_on_floor() and absf(c.y - lock.y) < 3.0,
			"at cell %s, the airlock %s, %.1f s" % [str(c.snapped(Vector3(0.1, 0.1, 0.1))), str(lock), (Time.get_ticks_msec() - t2) / 1000.0])
	await _hold(&"move_forward", 2.0)
	await get_tree().create_timer(0.5).timeout
	var c2 := ship.cell_at(pawn.feet())
	_check("and on along its spine", c2.x > c.x + 4.0 and pawn.is_on_floor() and absf(c2.y - lock.y) < 3.0,
			"at cell %s" % str(c2.snapped(Vector3(0.1, 0.1, 0.1))))
	# Parked on a world, its generator's gravity inside it over the world's (7.12).
	var gf := ship.gravity_field()
	_check("inside it its own gravity, over the world's", gf != null and Gravity.field_at(pawn.feet()) == gf
			and Gravity.field_at(ship.global_transform * ship.seat() + ship.global_basis.z * 80.0) == null,
			"%s inside, %.1f m/s2" % ["its field" if gf != null and Gravity.field_at(pawn.feet()) == gf else "not its field", Gravity.pull_at(pawn.feet())])
	await _shot("hull_gate_inside")
	# The bridge's seat: up and ahead, its bricks drawn as it flies (riding).
	pawn.place(ship.global_transform * ship.seat() + ship.global_basis.z * 2.0)
	await get_tree().create_timer(0.5).timeout
	_ship_key(KEY_E)
	_check("into the seat from the bridge's floor", piloting)
	await _frames(2)
	_check("its gangway taken up", ship.gangway == null)
	var alt0 := ship.altitude
	ship.thrust = Vector3(0.0, 1.0, 0.0)
	await get_tree().create_timer(5.0).timeout
	ship.thrust = Vector3(0.0, 0.0, 0.5)
	await get_tree().create_timer(3.0).timeout
	ship.thrust = Vector3.ZERO
	_check("flown from the bridge's seat: up and away, its bricks drawn on it", ship.altitude > alt0 + 10.0
			and ship.riding and ship.chunk >= 0 and not ship.shell.visible,
			"%.0f m up from %.0f, %.0f m/s, riding %s" % [ship.altitude, alt0, ship.vel.length(), ship.riding])
	await _shot("hull_gate_flying")
	# Up out of the seat while it still flies (Docs/Hulls.md 7b): onto its ghost, the
	# ship gliding to rest under the pawn, its bricks drawn and riding all the way.
	ship.thrust = Vector3(0.0, 0.0, 0.5)
	await get_tree().create_timer(1.0).timeout
	_ship_key(KEY_E)
	await _frames(3)
	var ghosted: bool = pawn.ghost == ship
	var glide := ship.vel.length()
	var g0 := pawn.body.global_position
	var r0 := ship.global_position
	await get_tree().create_timer(0.4).timeout
	# Along the deck: it was put a little over the floor, and settles onto it.
	var slid := Gravity.flat(pawn.body.global_position - g0, ship.ghost_up()).length()
	_check("up from the seat in flight: on its ghost, standing still on it as it glides", ghosted
			and glide > 1.0 and pawn.ghost == ship and slid < 0.05,
			"%.1f m/s, the ship %.1f m on, the pawn %.3f m along its deck" % [glide,
			(ship.global_position - r0).length(), slid])
	var glided := Time.get_ticks_msec()
	while (ship.riding or pawn.ghost != null) and Time.get_ticks_msec() - glided < 8000:
		await _frames(1)
	_check("at rest: its bricks solid again, the pawn off its ghost onto them", not ship.riding
			and pawn.ghost == null and not GhostHulls.is_ghosted(pawn.body),
			"%.1f s, %d ghost build(s)" % [(Time.get_ticks_msec() - glided) / 1000.0, ship.ghost_builds])
	# Out of the seat: on its bridge's floor.
	var since := Time.get_ticks_msec()
	while (_stepping_out >= 0 or not pawn.is_on_floor()) and Time.get_ticks_msec() - since < 6000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	c = ship.cell_at(pawn.feet())
	var seat := Vector3(ship.seat_cell)
	_check("out of the seat: on foot on the bridge's floor", on_foot and pawn.is_on_floor()
			and Vector2(c.x - seat.x - 0.5, c.z - seat.z - 0.5).length() < 4.0 and absf(c.y - seat.y) < 2.0,
			"at cell %s, the seat %s" % [str(c.snapped(Vector3(0.1, 0.1, 0.1))), str(ship.seat_cell)])
	loose = ship.bricks.find_detached_groups(ship.chunk) if ship.chunk >= 0 else []
	_check("its bricks solid again round its pilot in the air, every brick, nothing loose", ship.chunk >= 0 and not ship.riding
			and ship.bricks.get_alive_block_count(ship.chunk) == laid and loose.is_empty(),
			"%d loose group(s)" % loose.size())
	# The bridge's consoles (ShipBuild._consoles, Docs/RoomModules.md 7.11): looked at
	# from the seat, fore (the recipe's +X).
	var con: Dictionary = ship.recipe.meta.get("consoles", {})
	_check("the bridge's consoles, fore of the seat", int(con.get("bricks", 0)) > 0,
			"%d console brick(s)" % int(con.get("bricks", 0)))
	var s_org := ship.recipe.origin()
	var s_at := ship.global_transform * ship.cell_point(ship.seat_cell - s_org)
	var fore := ship.global_transform * ship.cell_point(ship.seat_cell + Vector3i(6, 0, 0) - s_org) - s_at
	_face(Gravity.flat(fore, Gravity.up_at(s_at)).normalized())
	cam.global_transform.basis = cam.global_transform.basis * Basis(Vector3.RIGHT, -0.3)
	await get_tree().create_timer(0.3).timeout
	await _shot("hull_gate_bridge")
	# Its rooms furnished (KitFurnish): looking aft across the bridge from the seat.
	var from := int((ship.recipe.meta.get("furniture", {}) as Dictionary).get("from", ship.recipe.size()))
	var furnished := ship.recipe.size() - from
	_check("its rooms furnished, in bricks", furnished > 0, "%d furniture brick(s)" % furnished)
	# Stood in the middle of its most furnished room (kept clear), facing its furniture.
	var best := {}
	var best_n := 0
	var toward := Vector3.ZERO
	for sp: Dictionary in ship.recipe.meta.structure.spaces:
		var cols := {}
		for cc in sp.get("columns", []):
			cols[Vector2i(int(cc[0]), int(cc[1]))] = true
		var n := 0
		var sum := Vector3.ZERO
		for i in ship.recipe.size():
			var at := ship.recipe.cell_of(i)
			if i >= from and cols.has(Vector2i(at.x, at.z)) and at.y > int(sp.floor_y) and at.y < int(sp.ceil_y):
				n += 1
				sum += Vector3(at)
		if n > best_n:
			best_n = n
			best = sp
			toward = sum / n
	if best_n > 0:
		var lo := Vector2i(1 << 30, 1 << 30)
		var hi := -lo
		for cc in best.columns:
			lo = Vector2i(mini(lo.x, int(cc[0])), mini(lo.y, int(cc[1])))
			hi = Vector2i(maxi(hi.x, int(cc[0])), maxi(hi.y, int(cc[1])))
		var org := ship.recipe.origin()
		var mid := Vector3i((lo.x + hi.x) / 2, int(best.floor_y) + 1, (lo.y + hi.y) / 2)
		var stand := ship.global_transform * ship.cell_point(mid - org)
		pawn.place(stand)
		await get_tree().create_timer(0.5).timeout
		var look := ship.global_transform * ship.cell_point(Vector3i(toward) - org) - stand
		_face(Gravity.flat(look, Gravity.up_at(stand)).normalized())
		cam.global_transform.basis = cam.global_transform.basis * Basis(Vector3.RIGHT, -0.6)
		await get_tree().create_timer(0.3).timeout
		print("[planet] hull_gate_room: %s, %d furniture brick(s)" % [String(best.kind), best_n])
	await _shot("hull_gate_room")
	# A window in its side (ShipBuild._windows): stood four studs in from a pane, facing it.
	var glass := RoomGrow._glass()
	var panes := 0
	var pane := Vector3i(0, -1, 0)
	# The hull's middle line: the bridge's seat's (the wings widen its bounds).
	var mid_z := float(ship.seat_cell.z + ship.recipe.origin().z)
	for i in ship.recipe.size():
		if ship.recipe.material_of(i) == glass:
			panes += 1
			var pc := ship.recipe.cell_of(i)
			if pane.y < 0 or pc.y < pane.y or pc.y == pane.y and absf(pc.x - ship.seat_cell.x) < absf(pane.x - ship.seat_cell.x):
				pane = pc
	_check("windows in its sides, glazed", panes > 0, "%d glass plate(s)" % panes)
	if pane.y >= 0:
		var org2 := ship.recipe.origin()
		var inward := 1 if pane.z < mid_z else -1
		# Its lowest row is WINDOW_SILL over the room's floor: stood on that floor.
		var g := ship.global_transform * ship.cell_point(pane - org2 + Vector3i(0, -ShipBuild.WINDOW_SILL, 4 * inward))
		pawn.place(g)
		await get_tree().create_timer(0.5).timeout
		var to := ship.global_transform * ship.cell_point(pane - org2) - g
		_face(Gravity.flat(to, Gravity.up_at(g)).normalized())
		await get_tree().create_timer(0.3).timeout
	await _shot("hull_gate_window")
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The belt's gate: a star's belt in open space, the universe turned round a turned
# ship. The rocks drawn where they stop it; stopped among them is stopped; slow
# flight smooth, a planet's orbit out in float32.

func _run_belt_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	board()
	await _ship_out()
	var to := -1
	for i in range(1, Universe.SYSTEMS):
		if to < 0 and system.universe.system(i).belt_outer > 0.0:
			to = i
	system.jump(to)
	await _frames(3)
	var f := system.belt
	_check("a system with a belt", f != null, "%s, %.0f-%.0f km" % [system.sys.system_name, f.inner / 1000.0, f.outer / 1000.0])
	var dir := Vector3(0.6, 0.0, 0.8)
	ship.rel = Transform3D(Basis(Vector3(1.0, 2.0, 0.5).normalized(), 1.1), dir * (f.inner + f.outer) * 0.5)
	ship.vel = Vector3.ZERO
	await _frames(10)
	_check("out of every shell, in it, its rocks drawn", ship.ref == null and system.frame_node() == ship and f.drawn > 20, "%d rocks" % f.drawn)
	await _shot("belt_gate_in")
	var off := 0.0
	var mm := f._mmi.multimesh
	var s2w := system.space_to_world()
	for i in mini(f.drawn, 40):
		var inst := mm.get_instance_transform(i).origin
		off = maxf(off, (f._mmi.global_transform * inst).distance_to(s2w * (inst + f.mid())))
	_check("each rock drawn where it is (the ship turned)", off < 1.0, "%.1f m out" % off)
	var at := ship.rel.origin
	await get_tree().create_timer(3.0).timeout
	_check("stopped among them is stopped", ship.rel.origin.distance_to(at) < 5.0, "%.1f m in 3 s" % ship.rel.origin.distance_to(at))
	# Slow, toward the nearest rock: it comes on evenly, and the ship does move.
	var best := Vector3.ZERO
	var best_d := INF
	var c := RockField.cell_of(ship.rel.origin)
	for x in range(c.x - 2, c.x + 3):
		for y in range(c.y - 1, c.y + 2):
			for z in range(c.z - 2, c.z + 3):
				for e in f.rocks_in(Vector3i(x, y, z)):
					var d := (e[0] as Vector3).distance_to(ship.rel.origin)
					if d < best_d and d > 60.0:
						best_d = d
						best = e[0]
	ship.aim(best - ship.rel.origin, ship.rel.basis.y)
	ship.thrust = Vector3(0.0, 0.0, 0.002)
	await get_tree().create_timer(2.0).timeout
	var last := -1.0
	var step := get_process_delta_time()
	var steps: Array[float] = []
	for k in 120:
		await get_tree().process_frame
		var d := (f._mmi.global_transform * (best - f.mid())).distance_to(ship.camera.global_position)
		if last >= 0.0:
			steps.append(absf(d - last) / maxf(step, 1e-4))
		last = d
		step = get_process_delta_time()
	var mean := 0.0
	for v in steps:
		mean += v
	mean /= steps.size()
	var spread := 0.0
	for k in range(1, steps.size()):
		spread += (steps[k] - steps[k - 1]) * (steps[k] - steps[k - 1])
	spread = sqrt(spread / (steps.size() - 1))
	_check("slow past a rock, even (%.2f m/s, the ship at %.0f km)" % [ship.vel.length(), ship.rel.origin.length() / 1000.0], mean > 2.0 and spread / mean < 0.1,
			"%.2f m/s seen, spread %.2f m/s" % [mean, spread])
	# Fast at it: stopped by it however big the step.
	ship.rel.origin = best - (best - ship.rel.origin).normalized() * 900.0
	ship.aim(best - ship.rel.origin, ship.rel.basis.y)
	ship.vel = (best - ship.rel.origin).normalized() * 1500.0
	ship.thrust = Vector3(0.0, 0.0, 1.0)
	var rams := ship.rams
	t0 = Time.get_ticks_msec()
	while ship.rams == rams and Time.get_ticks_msec() - t0 < 4000:
		await _frames(1)
	ship.thrust = Vector3.ZERO
	var gap := ship.rel.origin.distance_to(best)
	_check("at 1,500 m/s a rock still stops it", ship.rams > rams and gap < 80.0, "%.1f m from its centre" % gap)
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The save's gate, three runs, each finding what the last left: 1 home's town fought
# in, a wall blown, a tree down, a soldier hurt; 2 all of it as it was, then a jump
# to a world, down, a wall blown there; 3 back on that world, then home by the
# ship, home's wall still blown, and a new universe with nothing in it.

const GATE_NOTES := UniverseSave.TEST_ROOT + "gate_notes.dat"
static var _save_stage := 0


func _run_save_gate() -> void:
	if _save_stage == 0:
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--stage="):
				_save_stage = int(a.get_slice("=", 1))
	var saved: bool = saver.state.get("at") != null
	if saved:
		_check("a saved game opens dark, the spawn never on screen", _flash.color == Color(0, 0, 0, 1))
	var t0 := Time.get_ticks_msec()
	while (pawn == null or saver == null or not saver.live) and Time.get_ticks_msec() - t0 < 90000:
		await _frames(1)
	if saved:
		_check("and light once the player is back", saver.live and _flash.color.a == 0.0, "after %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	await get_tree().create_timer(1.0).timeout
	var notes := UniverseSave._read(GATE_NOTES)
	var town: Vector3 = town_dirs[0]
	var near := func() -> int:
		for i in buildings.sites.size():
			if buildings.sites[i].bricked:
				return i
		return -1
	var wall := func(pb: PlanetBuildings, b: PlanetBody, i: int) -> void:
		var site = pb.sites[i]
		_structure_hit(b.global_transform * (site.frame * Vector3(site.fx * 0.175, 3.0, 0.2)), Vector3.ZERO, {"blast": true, "radius": 3.0, "hp": 0})
	var wait_bricked := func(pb: PlanetBuildings) -> void:
		var since := Time.get_ticks_msec()
		while pb.bricked_count == 0 and Time.get_ticks_msec() - since < 30000:
			await _frames(1)
	if _save_stage == 1:
		_check("a first start: nothing to come back to", saver.state.get("at") == null)
		setup_ai(town)
		ai.policy = CombatPolicy.new()
		kit.use_services(ai)
		_home_garrison()
		var g: PlanetGarrison = garrisons[planet]
		pawn.health.layer_configs[0].max_value = 1e7
		pawn.health.reset()
		var feet := _surface(_round_dir(town, spawn_dir, 50.0))
		t0 = Time.get_ticks_msec()
		while _ground_hit(feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
			await _frames(1)
		pawn.place(feet + Gravity.up_at(feet) * 0.3)
		t0 = Time.get_ticks_msec()
		while g.squad == null and Time.get_ticks_msec() - t0 < 40000:
			await _frames(1)
		await wait_bricked.call(buildings)
		var i: int = near.call()
		wall.call(buildings, planet, i)
		await get_tree().create_timer(1.0).timeout
		var gone := buildings.site_gone(i).size()
		var t_near: Array = trees.trees_near(spawn_dir, 400.0)
		var tree_cell: Vector3i = t_near[0].key
		var tree_i: int = t_near[0].index
		_structure_hit(planet.global_transform * (t_near[0].at as Vector3), Vector3.ZERO, {"blast": true, "radius": 1.0, "hp": 0})
		if not trees.knock(tree_cell, tree_i, Vector3.RIGHT) and trees.knocked_count == 0:
			print("[planet] save gate: the tree's cell is not built")
		var q := g.squad
		q.alive()[0].pawn.health.apply_impact(1e6, &"")
		q.alive()[0].pawn.health.apply_impact(60.0, &"")
		# A piece knocked off the top of that building, left where it lands: the
		# rubble a save keeps.
		var s = buildings.sites[i]
		var top := PackedInt32Array()
		var dims: Vector3i = buildings.bricks.get_chunk_dims(s.chunk)
		for yc in range(dims.y - 1, -1, -1):
			for zc in dims.z:
				for xc in dims.x:
					var bid: int = buildings.bricks.block_at(s.chunk, Vector3i(xc, yc, zc))
					if bid >= 0 and not buildings.bricks.is_block_absent(s.chunk, bid) and not top.has(bid):
						top.append(bid)
			if top.size() >= 20:
				break
		top = top.slice(0, 20)
		s.collision.disable(top)
		for b in s.collision.bands_of(top):
			if not s.remesh.has(b):
				s.remesh.append(b)
		var pc := buildings.pieces
		pc.shed(s.chunk, [top])
		buildings.bricks.bake_chunk_async(s.chunk)
		t0 = Time.get_ticks_msec()
		while (pc.pieces.is_empty() or pc.moving() > 0) and Time.get_ticks_msec() - t0 < 20000:
			await _frames(1)
		var kept := 0
		var kept_bricks := 0
		var piece_at := Vector3.INF
		for p in pc.pieces:
			if is_instance_valid(p.body) and p.fading_since == 0:
				kept += 1
				kept_bricks += buildings.bricks.get_alive_block_count(p.chunk)
				piece_at = planet.to_local(p.body.global_position)
		_check("rubble lies about, settled", kept > 0 and pc.moving() == 0, "%d piece(s), %d bricks" % [kept, kept_bricks])
		# Its bricks left the wall too: what is gone from it now.
		gone = buildings.site_gone(i).size()
		await get_tree().create_timer(1.0).timeout
		system.t = 777.0
		var hurt: float = q.alive()[0].pawn.health.total_current()
		saver.save_now()
		var keep := {"site": i, "gone": gone, "trees": trees.knocked_count, "left": q.alive().size(), "hurt": hurt,
				"at": planet.to_local(pawn.feet()), "ship": ship.rel,
				"pieces": kept, "piece_bricks": kept_bricks, "piece_at": piece_at}
		UniverseSave._write(GATE_NOTES, keep)
		_check("the fight written, in place", gone > 0 and FileAccess.file_exists(saver.save.dir() + "s0_b%d.dat" % system.index_of(planet)),
				"%d bricks gone, %d trees, %d soldiers, in %.1f ms" % [gone, trees.knocked_count, q.alive().size(), saver.write_us / 1000.0])
	elif _save_stage == 2:
		_check("the clock as it was", is_equal_approx(system.t, 777.0), "%.0f s" % system.t)
		var off := planet.to_local(pawn.feet()).distance_to(notes.at)
		_check("the player where they were, on foot", on_foot and off < 1.0, "%.2f m off" % off)
		_check("the ship where it was", ship.rel.is_equal_approx(notes.ship) and ship.landed)
		var pc := buildings.pieces
		var back := 0
		var back_bricks := 0
		var off_piece := INF
		for p in pc.pieces:
			if is_instance_valid(p.body) and p.settled:
				back += 1
				back_bricks += buildings.bricks.get_alive_block_count(p.chunk)
				off_piece = minf(off_piece, planet.to_local(p.body.global_position).distance_to(notes.piece_at))
		_check("its rubble back where it lay, settled, brick for brick", back == int(notes.pieces) and back_bricks == int(notes.piece_bricks)
				and off_piece < 0.5, "%d piece(s) of %d, %d bricks of %d, %.2f m off" % [back, int(notes.pieces), back_bricks, int(notes.piece_bricks), off_piece])
		var hit0 := pc.hit_killed
		if not pc.pieces.is_empty():
			# On one of its bricks: its centre of mass may be air.
			var p0 = pc.pieces[0]
			var boxes: Array = buildings.bricks.get_block_boxes(p0.chunk)
			var aim: Vector3 = buildings.bricks.get_chunk_transform(p0.chunk) * (boxes[0].pos as Vector3) if not boxes.is_empty() else p0.body.global_position
			pc.damage(p0, aim, {"blast": true, "radius": 1.5, "hp": 0})
		_check("and it breaks again", pc.hit_killed > hit0, "%d bricks" % (pc.hit_killed - hit0))
		setup_ai(town)
		ai.policy = CombatPolicy.new()
		kit.use_services(ai)
		_home_garrison()
		pawn.health.layer_configs[0].max_value = 1e7
		pawn.health.reset()
		var g: PlanetGarrison = garrisons[planet]
		t0 = Time.get_ticks_msec()
		while g.squad == null and Time.get_ticks_msec() - t0 < 30000:
			await _frames(1)
		_check("those left of the squad, as they were, the same wave", g.squad != null and g.squad.alive().size() == int(notes.left) and g.wave == 1,
				"%d left" % (g.squad.alive().size() if g.squad != null else 0))
		_check("the hurt one still hurt", g.squad != null and absf(g.squad.alive()[0].pawn.health.total_current() - float(notes.hurt)) < 1.0)
		var i: int = notes.site
		_check("its wall's bricks gone again", buildings.site_gone(i).size() == int(notes.gone), "%d" % buildings.site_gone(i).size())
		await wait_bricked.call(buildings)
		_check("in the bricks laid too", buildings.sites[i].chunk >= 0 and bricks_gone(buildings, i) >= int(notes.gone), "%d" % bricks_gone(buildings, i))
		_check("the tree still down", trees.knocked_count == int(notes.trees), "%d" % trees.knocked_count)
		board()
		await _ship_out()
		open_map()
		await _frames(2)
		for k in map.rows.size():
			if int(map.rows[k][3]) > 0:
				map.pick = k
				break
		var to := map.chosen()
		map.visible = false
		system.jump(to)
		await _frames(3)
		var world: PlanetBody = null
		for b in system.bodies:
			if world == null and not b.data.towns.is_empty():
				world = b
		await _ship_down_on(world)
		unboard()
		await get_tree().create_timer(2.0).timeout
		var pb: PlanetBuildings = system.built[world]
		var side: Vector3 = (world.data.towns[0] as Vector3).cross(Vector3.UP).normalized()
		var spot: Vector3 = world.global_transform * world.data.surface_point((world.data.towns[0] as Vector3).rotated(side, 40.0 / world.data.radius))
		pawn.place(spot + Gravity.up_at(spot) * 0.3)
		await wait_bricked.call(pb)
		var w_site := -1
		for k in pb.sites.size():
			if w_site < 0 and pb.sites[k].bricked:
				w_site = k
		wall.call(pb, world, w_site)
		await get_tree().create_timer(1.0).timeout
		saver.save_now()
		notes["world"] = system.index_of(world)
		notes["w_site"] = w_site
		notes["w_gone"] = pb.site_gone(w_site).size()
		notes["system"] = to
		notes["w_at"] = world.to_local(pawn.feet())
		UniverseSave._write(GATE_NOTES, notes)
		_check("on a world of another system, a wall blown, written", int(notes.w_gone) > 0, "%s, %d bricks" % [world.data.planet_name, notes.w_gone])
	elif _save_stage == 3:
		_check("back in that system, on that world", system.system_index == int(notes.system) and system.anchor == system.bodies[int(notes.world)],
				"system %d" % system.system_index)
		var world: PlanetBody = system.anchor
		var off := world.to_local(pawn.feet()).distance_to(notes.w_at)
		_check("the player where they were, on foot, the ship down", on_foot and off < 1.5 and ship.landed and ship.ref == world, "%.2f m off" % off)
		var pb: PlanetBuildings = system.built[world]
		_check("its wall's bricks gone", pb.site_gone(int(notes.w_site)).size() == int(notes.w_gone), "%d" % pb.site_gone(int(notes.w_site)).size())
		board()
		await _ship_out()
		system.jump(0)
		await _frames(3)
		await _ship_down_on(planet, spawn_dir)
		unboard()
		await get_tree().create_timer(1.0).timeout
		_check("home again, its wall's bricks still gone", buildings.site_gone(int(notes.site)).size() == int(notes.gone), "%d" % buildings.site_gone(int(notes.site)).size())
		var n := universes
		n.open(saver.save.universe_id, saver.save.root)
		_save_stage = 4
		_play_universe(n.new_universe())
		return
	elif _save_stage == 4:
		_check("a new universe: its own seed, nothing come back", saver.save.seed_value != 1 and saver.state.get("at") == null and buildings.site_gone(int(notes.site)).is_empty(),
				"%s, seed %d" % [saver.save.display_name, saver.save.seed_value])
		_check("and two universes on disk", UniverseSave.list(UniverseSave.TEST_ROOT).size() == 2)
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func bricks_gone(pb: PlanetBuildings, i: int) -> int:
	return pb.bricks.get_dead_blocks(pb.sites[i].chunk).size() + pb.bricks.get_detached_blocks(pb.sites[i].chunk).size()


# Home's gate: quiet at the spawn; home's town walked into, the fight on home's own
# AI; wave after wave, each bigger, none on the player's head, and it stops at the most.

func _run_home_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town_dirs[0])
	ai.policy = CombatPolicy.new()
	kit.use_services(ai)
	_home_garrison()
	var g: PlanetGarrison = garrisons[planet]
	var home_ai := ai
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	await get_tree().create_timer(2.0).timeout
	_check("quiet at the spawn, 220 m off", g.squad == null and g.wave == 0, "%.0f m" % pawn.feet().distance_to(_surface(town_dirs[0])))
	var town: Vector3 = town_dirs[0]
	var feet := _surface(_round_dir(town, spawn_dir, 50.0))
	t0 = Time.get_ticks_msec()
	while _ground_hit(feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	pawn.place(feet + Gravity.up_at(feet) * 0.3)
	_face(Gravity.flat(_surface(town) - feet, Gravity.up_at(feet)).normalized())
	var raised := func(n: int) -> void:
		var since := Time.get_ticks_msec()
		while (g.squad == null or g.wave != n) and Time.get_ticks_msec() - since < 40000:
			await _frames(1)
	await raised.call(1)
	_check("walked into, its first squad, four strong", g.squad != null and g.squad.alive().size() == 4)
	_check("on home's own AI, no other made", ai == home_ai and ai_of[planet] == home_ai and kit.services == home_ai)
	var q := g.squad
	var fired := false
	t0 = Time.get_ticks_msec()
	while not fired and Time.get_ticks_msec() - t0 < 40000:
		await _frames(2)
		for m in q.alive():
			fired = fired or m.shots > 0
	_check("it fights", fired, g.status())
	await _shot("home_gate_fight")
	var sizes: Array[int] = []
	var nearest := INF
	var kinds := {}
	for n in range(2, 5):
		for m in g.squad.alive():
			m.pawn.health.apply_impact(1e6, &"")
		t0 = Time.get_ticks_msec()
		while g.squad != null and Time.get_ticks_msec() - t0 < 8000:
			await _frames(1)
		if n == 2:
			_check("between waves it says when the next is", g.status().contains("wave 2 in"), g.status())
		g.next_wave = 0.0
		await raised.call(n)
		if g.squad == null:
			break
		sizes.append(g.squad.alive().size())
		for m in g.squad.alive():
			nearest = minf(nearest, m.pawn.feet().distance_to(pawn.feet()))
			kinds[m.get_meta(&"unit", &"")] = true
	_check("each wave bigger, to the most", str(sizes) == "[6, 8, 8]", str(sizes))
	_check("later waves bring more than rifles", kinds.size() >= 3, ", ".join(kinds.keys()))
	_check("none on the player's head", nearest > 40.0, "%.0f m" % nearest)
	var came := nearest
	t0 = Time.get_ticks_msec()
	while came > nearest - 15.0 and Time.get_ticks_msec() - t0 < 40000:
		await _frames(2)
		for m in g.squad.alive():
			came = minf(came, m.pawn.feet().distance_to(pawn.feet()))
	_check("and it comes for them, unseen", came <= nearest - 15.0, "%.0f m -> %.0f m" % [nearest, came])
	await get_tree().create_timer(2.0).timeout
	var low := INF
	for m in g.squad.alive():
		low = minf(low, _over_ground(m.pawn.feet()))
	_check("on the ground where it came in", absf(low) < 1.5, "%.2f m" % low)
	# Wave 4 brought a tank: crewed, and it comes for the player -- at the pace of
	# the squad it screens (TankBrain.escort), as the city's does.
	var tk := g.tank
	var tank_from := tk.feet().distance_to(pawn.feet()) if is_instance_valid(tk) else INF
	var tank_low := INF
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
		if is_instance_valid(tk):
			tank_low = minf(tank_low, _over_ground(tk.feet()))
	var tank_to := tk.feet().distance_to(pawn.feet()) if is_instance_valid(tk) else INF
	_check("wave 4 brings a tank, crewed, and it comes for the player", is_instance_valid(tk) and tk.crew_count() == 2
			and not tk.is_wrecked() and tank_to < tank_from - 3.0 and tank_low > -1.0 and g.status().contains("a tank"),
			"%.0f m -> %.0f m in 20 s, lowest %.2f m over the ground, %s" % [tank_from, tank_to, tank_low, g.status()])
	await _shot("home_gate_tank")
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The garrison's gate (11.12 step 7): a jump to a settled world, down by a town,
# out on foot: the world's own AI, the town's squad closing and firing; left and
# come back to, there and still fighting; wiped out, clear; the player down and
# up again; home's AI back on home.

func _run_garrison_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town_dirs[0])
	kit.use_services(ai)
	var home_ai := ai
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	board()
	await _ship_out()
	open_map()
	await _frames(2)
	for i in map.rows.size():
		if int(map.rows[i][3]) > 0:
			map.pick = i
			break
	var to := map.chosen()
	map.visible = false
	system.jump(to)
	await _frames(3)
	var world: PlanetBody = null
	for b in system.bodies:
		if world == null and not b.data.towns.is_empty():
			world = b
	# Its town nearest the sun.
	var noon := world.global_basis.inverse() * (system.star.global_position - world.global_position).normalized()
	var town: Vector3 = world.data.towns[0]
	for d in world.data.towns:
		if (d as Vector3).dot(noon) > town.dot(noon):
			town = d
	var side := town.cross(Vector3.UP if absf(town.y) < 0.9 else Vector3.RIGHT).normalized()
	var land := town.rotated(side, 150.0 / world.data.radius)
	# Inside a soldier's sight (Soldier.SIGHT_RANGE) of the town's middle.
	var edge := town.rotated(side, 50.0 / world.data.radius)
	var ok_land: bool = await _ship_down_on(world, land)
	_check("down by a town of %s" % world.data.planet_name, ok_land and system.anchor == world, "%.1f m" % ship.altitude)
	_check("no garrison raised from the seat", not garrisons.has(world) or (garrisons[world] as PlanetGarrison).town < 0)
	var stand := func() -> void:
		unboard()
		var feet := world.global_transform * world.data.surface_point(edge)
		var since := Time.get_ticks_msec()
		while _ground_hit(feet) == Vector3.INF and Time.get_ticks_msec() - since < 30000:
			await _frames(1)
			feet = world.global_transform * world.data.surface_point(edge)
		await get_tree().create_timer(1.0).timeout
		feet = world.global_transform * world.data.surface_point(edge)
		pawn.place(feet + Gravity.up_at(feet) * 0.3)
		_face(Gravity.flat(world.global_transform * world.data.surface_point(town) - feet, Gravity.up_at(feet)).normalized())
	await stand.call()
	var g: PlanetGarrison = garrisons.get(world)
	t0 = Time.get_ticks_msec()
	while (g == null or g.squad == null) and Time.get_ticks_msec() - t0 < 40000:
		await _frames(1)
		g = garrisons.get(world)
	_check("the town's squad is raised, four strong", g != null and g.squad != null and g.squad.alive().size() == 4)
	_check("on the world's own AI, the player's kit with it", ai_of.get(world) == ai and ai != home_ai and kit.services == ai
			and ai.pawns.has(pawn) and not home_ai.pawns.has(pawn))
	var q := g.squad
	var start := INF
	for m in q.alive():
		start = minf(start, m.pawn.feet().distance_to(pawn.feet()))
	var nearest := start
	var fired_at := -1.0
	var body_ticks := 0
	var floor_ticks := 0
	var sunk := 0.0
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await get_tree().physics_frame
		var shots := 0
		for m in q.alive():
			var f := m.pawn.feet()
			nearest = minf(nearest, f.distance_to(pawn.feet()))
			body_ticks += 1
			floor_ticks += 1 if m.pawn.body.is_on_floor() else 0
			sunk = minf(sunk, world.altitude_of(f) - world.data.height(world.dir_of(f)))
			shots += m.shots
		if shots > 0 and fired_at < 0.0:
			fired_at = (Time.get_ticks_msec() - t0) / 1000.0
		if start - nearest >= 15.0 and fired_at >= 0.0:
			break
	await _shot("garrison_gate_fight")
	var states := {}
	for m in q.alive():
		states[m.state] = int(states.get(m.state, 0)) + 1
	print("[planet] garrison: %s; play %s; %d alive" % [states, q.play, q.alive().size()])
	_check("it sees the player and closes on them (>= 15 m)", start - nearest >= 15.0, "%.1f m -> %.1f m" % [start, nearest])
	_check("it fires", fired_at >= 0.0, "first at %.1f s" % fired_at)
	_check("on the ground, nobody through it", floor_ticks > body_ticks * 0.9 and sunk > -0.5, "%d of %d on the floor, %.2f m" % [floor_ticks, body_ticks, sunk])
	# Left: it sleeps where it was, and is where it was on waking.
	board()
	_check("in the seat the player is out of the fight", not ai.pawns.has(pawn))
	await _ship_out()
	var keep := {}
	for m in q.alive():
		keep[m] = world.to_local(m.pawn.body.global_position)
	var off := [INF]
	system.woke.connect(func(b: Node3D, _o: Vector3) -> void:
		if b == world and off[0] == INF:
			off[0] = 0.0
			for m in keep:
				off[0] = maxf(off[0], world.to_local(m.pawn.body.global_position).distance_to(keep[m])))
	_check("left, it sleeps with its world", system.anchor != world and g.process_mode == Node.PROCESS_MODE_DISABLED and g.get_parent() == world)
	await _ship_down_on(world, land)
	_check("back, each where it was", off[0] < 0.01 and g.get_parent() == self and kit.services == ai_of[world], "%.4f m off" % off[0])
	await stand.call()
	t0 = Time.get_ticks_msec()
	while g._held and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	var low := INF
	for m in q.alive():
		low = minf(low, world.altitude_of(m.pawn.feet()) - world.data.height(world.dir_of(m.pawn.feet())))
	_check("held till the ground was there: nobody fell", not g._held and absf(low) < 1.5, "lowest %.2f m" % low)
	var shots0 := 0
	for m in q.alive():
		shots0 += m.shots
	var net := ai.nav_net as PlanetNavNet
	var path := PackedVector3Array()
	t0 = Time.get_ticks_msec()
	while path.is_empty() and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().create_timer(0.5).timeout
		path = net.find_path(q.alive()[0].pawn.feet(), pawn.feet(), 200000)
	var worst := 0.0
	for k in path:
		worst = maxf(worst, absf(world.altitude_of(k) - world.data.height(world.dir_of(k))))
	_check("its paths still lie on the ground (the net followed the world)", path.size() > 2 and worst < 2.0, "%d points, %.2f m" % [path.size(), worst])
	t0 = Time.get_ticks_msec()
	var shots1 := shots0
	while shots1 == shots0 and Time.get_ticks_msec() - t0 < 30000:
		await _frames(5)
		shots1 = 0
		for m in q.alive():
			shots1 += m.shots
	_check("and it fights on", shots1 > shots0, "a round in %.1f s; %s" % [(Time.get_ticks_msec() - t0) / 1000.0, g.status()])
	if shots1 == shots0:
		var what := {}
		for m in q.alive():
			what[m.state] = int(what.get(m.state, 0)) + 1
		print("[planet] garrison: %s, play %s, order %s, nearest %.1f m" % [what, q.play, q.order != null, q.alive()[0].pawn.feet().distance_to(pawn.feet())])
	# Wiped out.
	for m in q.alive():
		m.pawn.health.apply_impact(1e6, &"")
	t0 = Time.get_ticks_msec()
	while g.squad != null and Time.get_ticks_msec() - t0 < 8000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	_check("wiped out, the town is clear and stays so", g.squad == null and cleared.size() == 1 and g.soldiers.size() == 4)
	# The player down.
	pawn.health.layer_configs[0].max_value = 100.0
	pawn.health.reset()
	var fell := 0.0
	while not pawn.health.is_dead() and fell < 1e8:
		pawn.health.apply_impact(1e6, &"")
		fell += 1e6
	var was_dead := pawn.health.is_dead()
	await get_tree().create_timer(DOWN_FOR + 0.5).timeout
	var to_ship := pawn.feet().distance_to(ship.global_position)
	_check("down, and up again beside the ship", was_dead and not pawn.health.is_dead() and to_ship < BESIDE_SHIP * 2.0, "%.1f m from it" % to_ship)
	# Home.
	board()
	await _ship_out()
	var ok_back := system.jump(0)
	await _frames(3)
	await _ship_down_on(planet)
	_check("home, on home's AI", ok_back and system.anchor == planet and ai == home_ai and kit.services == home_ai, "ai_of %d" % ai_of.size())
	unboard()
	_check("the player in it", home_ai.pawns.has(pawn) and garrisons.is_empty())
	print("[planet] garrison gate: put back on the ground %d time(s)" % ground_saves)
	print("[planet] garrison gate: frames: worst %.1f ms; over 40 ms in play: %d %s" % [_worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The worlds' gate (11.12 step 4): down onto a generated world with towns, its
# buildings near, in bricks, solid and hit; trees where its biomes have them;
# off again, its towns still on the sphere from space.

func _run_worlds_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var world: PlanetBody = null
	for b in system.bodies:
		if b != planet and not b.data.towns.is_empty() and world == null:
			world = b
	_check("a generated world with towns in the home system", world != null)
	print("[planet] worlds gate: %s, r %.0f m, %+.0f C, %d towns, %d landmarks, %d pads" % [world.data.planet_name,
			world.data.radius, world.data.t_offset, world.data.towns.size(), world.data.landmarks.size(), world.data.pads.size()])
	# Off home, to its town nearest the sun, 90 m from its middle.
	var noon := world.global_basis.inverse() * (system.star.global_position - world.global_position).normalized()
	var town: Vector3 = world.data.towns[0]
	for d in world.data.towns:
		if (d as Vector3).dot(noon) > town.dot(noon):
			town = d
	var side := town.cross(Vector3.UP if absf(town.y) < 0.9 else Vector3.RIGHT).normalized()
	var at := town.rotated(side, 150.0 / world.data.radius)
	walker.flying = true
	walker.pitch = 0.0
	var ok_there: bool = await _system_cross(world, at)
	_check("down on %s: its anchor, its ground" % world.data.planet_name, ok_there and system.anchor == world and world.terrain != null)
	var over := world.altitude_of(walker.global_position) - world.data.height(world.dir_of(walker.global_position))
	_check("standing on it", walker.is_on_floor() and absf(over) < 0.6, "%.2f m, g %.1f" % [over, Gravity.strength()])
	var pb := system.buildings_here()
	_check("its buildings are made, its town's shells near", pb != null and pb.sites.size() > 0 and pb != buildings and pb.near_count > 0,
			"%d sites, %d near" % [pb.sites.size() if pb != null else 0, pb.near_count if pb != null else 0])
	t0 = Time.get_ticks_msec()
	while pb.bricked_count == 0 and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	_check("the nearest in bricks and solid", pb.bricked_count > 0, "%d bricked" % pb.bricked_count)
	await _shot("worlds_gate_town")
	var near := -1
	for i in pb.sites.size():
		if pb.sites[i].bricked:
			near = i
			break
	var s = pb.sites[near]
	var wall: Vector3 = world.global_transform * (s.frame * Vector3(s.fx * 0.175, 3.0, 0.2))
	_structure_hit(wall, Vector3.ZERO, {"blast": true, "radius": 3.0, "hp": 0})
	await get_tree().create_timer(1.0).timeout
	_check("a blast at a wall of it is taken by that world's bricks", pb.bricks_killed > 0, "%d bricks" % pb.bricks_killed)
	await _shot("worlds_gate_hit")
	_check("its trees are set up (none where its biomes have none)", system.trees_of.has(world))
	# Off again: the towns still on the sphere.
	var up := Gravity.up_at(walker.global_position)
	walker.frozen = true
	t0 = Time.get_ticks_msec()
	while world.altitude_of(walker.global_position) < 100000.0 and Time.get_ticks_msec() - t0 < 30000:
		walker.global_position += up * maxf(world.altitude_of(walker.global_position) * 0.05, 5.0)
		await get_tree().physics_frame
	await _look_back(world, "worlds_gate_from_space")
	_check("from 100 km it sleeps", system.anchor != world)
	if DisplayServer.get_name() != "headless":
		_check("and its towns are still on it", pb.far_count > 5, "%d drawn" % pb.far_count)
	print("[planet] worlds gate: %d handoffs; frames: worst %.1f ms; over 40 ms in play: %d %s" % [
			system.handoffs, _worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The docking gate (11.12 step 3b), the clock running: the ship rammed into a
# tower of the town (it stops, the tower is blasted), up to the home planet's
# station, its speed matched, stopped by its hull; the station's bricks shot,
# what came loose gone; left and come back to, as it was left.

func _run_dock_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	board()
	# Up a little, then at the nearest tower of the town.
	ship.thrust = Vector3(0.0, 1.0, 0.0)
	await get_tree().create_timer(1.0).timeout
	var best := -1
	var best_d := INF
	for i in buildings.sites.size():
		var s = buildings.sites[i]
		var d: float = (s.frame.origin + planet.global_position).distance_to(ship.global_position)
		if not s.landmark and s.courses > 30 and d < best_d:
			best_d = d
			best = i
	var site = buildings.sites[best]
	var killed0: int = buildings.bricks_killed
	t0 = Time.get_ticks_msec()
	while ship.rams == 0 and Time.get_ticks_msec() - t0 < 30000:
		var c: Vector3 = site.frame * Vector3(site.fx * 0.175, 6.0, site.fz * 0.175)
		var to := c - ship.rel.origin
		var up := ship.rel.origin.normalized()
		ship.aim(to, up)
		ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
	ship.thrust = Vector3.ZERO
	await get_tree().create_timer(1.0).timeout
	var c2: Vector3 = site.frame * Vector3(site.fx * 0.175, 6.0, site.fz * 0.175)
	_check("the ship rams a tower: stopped by it, not through it", ship.rams > 0
			and (c2 - ship.rel.origin).length() > site.fx * 0.175, "%d rams, %.1f m from its centre" % [ship.rams, (c2 - ship.rel.origin).length()])
	_check("and the tower is blasted where it hit", buildings.bricks_killed > killed0, "%d bricks" % (buildings.bricks_killed - killed0))
	await _shot("dock_gate_ram")
	# Up to the home planet's station.
	var st: SpaceStation = null
	var k_st := -1
	for k in system.stations.size():
		if system.stations[k].is_station() and system.stations[k].data.parent == system.index_of(planet):
			st = system.stations[k]
			k_st = k
	var pi := system.index_of(planet)
	t0 = Time.get_ticks_msec()
	var matched := false
	var worst_rel := 0.0
	while system.station != st and Time.get_ticks_msec() - t0 < 120000:
		var at := system.sys.xform(pi, system.t).affine_inverse() * system.sys.orbital_xform(k_st, system.t).origin
		# Round the planet at the station's height, not through it.
		var a := ship.rel.origin.normalized()
		var b := at.normalized()
		var ang := a.angle_to(b)
		var goal := at if ang < 0.3 else a.slerp(b, 0.3 / ang) * at.length()
		var to := goal - ship.rel.origin
		if ship.altitude < 400.0:
			ship.thrust = Vector3(0.0, 1.0, 0.0)
		else:
			ship.aim(to, a)
			ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
		var dock: Array = system.ship_match(ship)
		if float(dock[1]) >= 0.0:
			matched = true
			worst_rel = maxf(worst_rel, (ship.vel - dock[0]).length())
	ship.boost = false
	_check("up to the station, on its frame, its speed matched by the ship", system.station == st and matched,
			"station at %.0f m/s against the ground frame" % (system.ship_match(ship)[0] as Vector3).length())
	# On the station's frame the ship is still placed off its planet: it must not
	# shake against the station (through the star's frame it did, by 0.125 m steps).
	ship.thrust = Vector3.ZERO
	var near := []
	for n in 90:
		await _frames(1)
		near.append(st.global_transform.affine_inverse() * ship.global_position)
	var shake := 0.0
	for n in range(2, near.size()):
		shake = maxf(shake, ((near[n] as Vector3) - 2.0 * (near[n - 1] as Vector3) + (near[n - 2] as Vector3)).length())
	_check("and steady against it", shake < 0.05, "worst step off by %.3f m" % shake)
	var alive := func() -> int: return st.bricks.get_alive_block_count(st.chunk)
	t0 = Time.get_ticks_msec()
	while not st.bricked and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	# Into its hull: stopped by it.
	var rams0 := ship.rams
	t0 = Time.get_ticks_msec()
	while ship.rams == rams0 and Time.get_ticks_msec() - t0 < 40000:
		var to := st.global_position + st.global_basis.y * st.height * 0.5 - ship.global_position
		ship.aim(system.sys.xform(pi, system.t).basis.inverse() * system.space_to_world().basis.inverse() * to, ship.rel.origin.normalized())
		ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
	ship.thrust = Vector3.ZERO
	await get_tree().create_timer(2.0).timeout
	var gap := st.to_local(ship.global_position).length()
	_check("its hull stops the ship, and it holds there beside it", ship.rams > rams0 and gap > 5.0 and gap < 40.0,
			"%.1f m from its centre" % gap)
	await _shot("dock_gate_docked")
	# Shots at its wall.
	var n0: int = alive.call()
	var wall := st.global_transform * (st.frame * Vector3(st.data.fx * 0.175, st.height * 0.5, 0.2))
	_structure_hit(wall, Vector3.ZERO, {"blast": true, "radius": 3.0, "hp": 0})
	await get_tree().create_timer(1.5).timeout
	var n1: int = alive.call()
	_check("a blast at the station's wall takes bricks out, what it left loose gone too", n1 < n0 and st.bricks_killed > 0,
			"%d -> %d, %d killed" % [n0, n1, st.bricks_killed])
	await _shot("dock_gate_hole")
	# Away and back: as it was left.
	ship.aim(ship.rel.origin.normalized(), ship.rel.basis.z)
	ship.thrust = Vector3(0.0, 0.0, 1.0)
	t0 = Time.get_ticks_msec()
	while system.station == st and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	ship.thrust = Vector3.ZERO
	_check("left: its bricks are freed", system.station == null and st.chunk < 0)
	t0 = Time.get_ticks_msec()
	while system.station != st and Time.get_ticks_msec() - t0 < 30000:
		var at := system.sys.xform(pi, system.t).affine_inverse() * system.sys.orbital_xform(k_st, system.t).origin
		ship.aim(at - ship.rel.origin, ship.rel.origin.normalized())
		ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
	ship.thrust = Vector3.ZERO
	t0 = Time.get_ticks_msec()
	while not st.bricked and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	var n2: int = alive.call() if st.chunk >= 0 else -1
	_check("back: laid again as it was left", n2 == n1, "%d bricks" % n2)
	print("[planet] dock gate: %d handoffs; frames: worst %.1f ms; over 40 ms in play: %d %s" % [
			system.handoffs, _worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# The ship's gate (11.12 step 3): the parked ship in bricks, into its seat, up
# and out of the home planet's shell, a walk on its deck in open space, home
# watched shrinking (its towns on the sphere, then gone), across to the nearest
# other planet, down onto it, out and standing on its ground.

func _run_ship_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while walker.frozen and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	_check("a ship parked by the spawn, on the home planet", ship != null and ship.landed and ship.ref == planet)
	t0 = Time.get_ticks_msec()
	while not ship.bricked and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	_check("parked near the player: its bricks laid and solid", ship.bricked, "template %.1f ms, laid %.1f ms" % [ship.template_ms, ship.lay_ms])
	await _shot("ship_gate_parked")
	board()
	ship.thrust = Vector3(0.0, 1.0, 0.0)
	await get_tree().create_timer(4.0).timeout
	_check("it lifts off", ship.altitude > 20.0 and not ship.landed, "%.0f m up" % ship.altitude)
	await _shot("ship_gate_liftoff")
	# Up and out, cruising, the home planet watched from behind.
	ship.boost = true
	var marks := [2000.0, 20000.0]
	t0 = Time.get_ticks_msec()
	while system.frame_node() != ship and Time.get_ticks_msec() - t0 < 90000:
		await _frames(1)
		if not marks.is_empty() and ship.altitude > marks[0]:
			await _look_back(planet, "ship_gate_back_%dkm" % int(marks[0] / 1000.0))
			marks.pop_front()
	ship.thrust = Vector3.ZERO
	ship.boost = false
	_check("out of the home planet's shell: the ship is the frame", system.frame_node() == ship and ship.ref == null,
			"%.0f km up" % (planet.altitude_of(ship.global_position) / 1000.0))
	await get_tree().create_timer(2.0).timeout
	# A walk on its deck in open space.
	unboard()
	await get_tree().create_timer(3.0).timeout
	var up := Gravity.up_at(walker.global_position)
	_check("out of the seat in open space: standing on its floor, down through its deck",
			walker.is_on_floor() and up.dot(ship.global_basis.y) > 0.999, "%.2f deg" % rad_to_deg(acos(clampf(up.dot(ship.global_basis.y), -1.0, 1.0))))
	await _shot("ship_gate_deck")
	# Across the deck (the seat is by the door, the staircase aft of it).
	walker.wish = Vector2(1, 0)
	await get_tree().create_timer(1.5).timeout
	walker.wish = Vector2.ZERO
	await get_tree().create_timer(1.0).timeout
	var moved := (ship.global_transform.affine_inverse() * walker.global_position - ship.seat()).length()
	_check("and walks about on it", walker.is_on_floor() and moved > 1.5, "%.1f m from the seat" % moved)
	walker.global_position = ship.global_transform * ship.seat()
	board()
	# Across to the nearest other planet, home watched shrinking.
	var target: PlanetBody = null
	for b in system.bodies:
		if b != planet and (target == null or (b.global_position - ship.global_position).length()
				< (target.global_position - ship.global_position).length()):
			target = b
	var ti := system.index_of(target)
	var far_marks := [100000.0, 300000.0]
	var far_seen := []
	ship.boost = true
	t0 = Time.get_ticks_msec()
	while ship.ref != target and Time.get_ticks_msec() - t0 < 120000:
		if ship.ref == null:
			ship.aim(system.sys.pos(ti, system.t) - ship.rel.origin, ship.rel.basis.y)
		ship.thrust = Vector3(0.0, 0.0, 1.0)
		await _frames(1)
		var dh := (ship.global_position - planet.global_position).length()
		if not far_marks.is_empty() and dh > far_marks[0]:
			ship.thrust = Vector3.ZERO
			await _look_back(planet, "ship_gate_home_%dkm" % int(far_marks[0] / 1000.0))
			far_seen.append(buildings.far_count)
			print("[planet] ship gate: home %.0f km off, %d of its buildings drawn" % [dh / 1000.0, buildings.far_count])
			far_marks.pop_front()
	await _frames(2)
	var dh_end := (ship.global_position - planet.global_position).length()
	await _look_back(planet, "ship_gate_home_from_there")
	far_seen.append(buildings.far_count)
	# By size on screen: a headless viewport has none to speak of.
	if DisplayServer.get_name() != "headless":
		_check("from space the towns are on the sphere, then gone when really far",
			far_seen.size() == 3 and far_seen[0] > 10 and far_seen[1] > 10 and far_seen[2] == 0,
			"%s drawn at 100 km, 300 km, %.0f km" % [str(far_seen), dh_end / 1000.0])
	_check("into %s's shell: its frame, the planet the anchor" % target.data.planet_name,
			ship.ref == target and system.anchor == target and target.terrain != null)
	# Down: nose to the centre, then level and settle.
	t0 = Time.get_ticks_msec()
	while not ship.landed and Time.get_ticks_msec() - t0 < 120000:
		var r := ship.rel.origin
		var down := -r.normalized()
		if ship.altitude > 3000.0:
			ship.aim(down, ship.rel.basis.y)
			ship.thrust = Vector3(0.0, 0.0, 1.0)
		else:
			# Along the ground from however it points: its tail, or, nose down, its back.
			var along := ship.rel.basis.z - down * ship.rel.basis.z.dot(down)
			if along.length_squared() < 0.01:
				along = ship.rel.basis.y - down * ship.rel.basis.y.dot(down)
			ship.aim(-along.normalized(), -down)
			ship.thrust = Vector3(0.0, -1.0, 0.0)
		ship.boost = ship.altitude > 20000.0
		await _frames(1)
	ship.thrust = Vector3.ZERO
	ship.boost = false
	_check("it sets down on %s" % target.data.planet_name, ship.landed and ship.ref == target, "%.1f m over its ground" % ship.altitude)
	await get_tree().create_timer(2.0).timeout
	await _shot("ship_gate_landed")
	unboard()
	t0 = Time.get_ticks_msec()
	while not ship.bricked and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	await get_tree().create_timer(2.0).timeout
	_check("out of the seat on the other planet: standing in the landed ship, its bricks solid",
			walker.is_on_floor() and ship.bricked and system.anchor == target)
	await _shot("ship_gate_out")
	print("[planet] ship gate: %d handoffs; frames: worst %.1f ms; over 40 ms in play: %d %s" % [
			system.handoffs, _worst_ms, _play_hitches.size(), _play_hitches])
	print("[planet] gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## A shot from the camera's place looking back at `b`.
func _look_back(b: PlanetBody, name: String) -> void:
	var c := Camera3D.new()
	c.far = PlanetSystem.SEE_FAR
	c.fov = 60.0
	add_child(c)
	var from := _eye()
	c.look_at_from_position(from, b.look.global_position, Gravity.up_at(from) if absf(Gravity.up_at(from).dot((b.look.global_position - from).normalized())) < 0.99 else Vector3.FORWARD)
	c.current = true
	await _frames(4)
	await _shot(name)
	c.queue_free()
	if piloting:
		ship.camera.current = true
	else:
		walker.camera.current = true


# The drive gate (11.8): an AI tank, crewed, on the player's side, sent 200 m out
# of the town. Its road is the nav net's tank map (AIServices.vehicle_nav on a
# planet: a PlanetNavMap, its own AINav in each region), across the borders.

func _run_drive_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	var start := _surface(_round_dir(town, spawn_dir, 100.0))
	var goal := _surface(_round_dir(town, spawn_dir, 300.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	pawn.health.layer_configs[0].max_value = 1e7
	pawn.health.reset()
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = start
	PlanetBody.track(marker)
	t0 = Time.get_ticks_msec()
	while (_ground_hit(p_feet) == Vector3.INF or _ground_hit(start) == Vector3.INF) \
			and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	await get_tree().create_timer(1.0).timeout
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	pawn.set_meta(&"player", 0)
	ai.add_pawn(pawn)
	var vn = ai.vehicle_nav(&"tank")
	_check("on a planet the tank's map is the nav net's", vn is PlanetNavMap)
	var at: Vector3 = vn.snap(start)
	var lib := GunPlaceholderParts.build_library()
	var main := GunInstance.from_result(GunGenerator.generate(lib, 5, WeaponClass.builtin(&"rocket_launcher"), 1))
	var mg := GunInstance.from_result(GunGenerator.generate(lib, 6, WeaponClass.builtin(&"lmg"), 1))
	var face := Gravity.flat(goal - at, Gravity.up_at(at))
	var tk := Tank.make(ai, self, at + Gravity.up_at(at) * 0.3, 0.0, 0, main, mg, Callable(), ai.rng)
	PlanetBody.track(tk)
	ai.add_pawn(tk.make_target())
	var br := TankBrain.attach(ai, tk)
	for seat in [Tank.Seat.DRIVER, Tank.Seat.GUNNER]:
		var so := Soldier.spawn(ai, self, at + Gravity.up_at(at) * 0.3 + face.normalized().cross(Gravity.up_at(at)) * 5.0,
				0, GunInstance.from_result(GunGenerator.generate(lib, 60 + seat, WeaponClass.builtin(&"rifle"), 1)))
		PlanetBody.track(so.pawn.body)
		tk.board(so.pawn, seat, true)
	await get_tree().create_timer(2.0).timeout
	br.send(goal)
	var keys := {}
	var sunk := 0.0
	var roads := {}
	var t1 := Time.get_ticks_msec()
	var left := INF
	while Time.get_ticks_msec() - t1 < 150000:
		await get_tree().physics_frame
		var f := tk.feet()
		keys[net.key_at(f)] = true
		sunk = minf(sunk, _over_ground(f))
		roads[br.road] = true
		left = Gravity.flat(goal - f, Gravity.up_at(goal)).length()
		if left < 8.0 and br.state in ["hold", "idle"]:
			break
	var secs := (Time.get_ticks_msec() - t1) / 1000.0
	print("[planet] drive: %.1f m short after %.0f s, state %s, roads %s, %d cell(s), %d region(s) now" % [
			left, secs, br.state, roads.keys(), keys.size(), net.regions.size()])
	_check("the tank gets there (< 8 m)", left < 8.0, "%.1f m short, %s" % [left, br.state])
	_check("on the tank's own map (its road the vehicle map)", roads.has("vehicle") and not roads.has("foot"),
			str(roads.keys()))
	_check("across the regions (>= 3 cells driven)", keys.size() >= 3, "%d" % keys.size())
	_check("never under the ground (> -1 m)", sunk > -1.0, "%.2f m" % sunk)
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] AI tick: worst %.1f ms" % (ai_worst_us / 1000.0))
	print("[planet] drive gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The trees gate (11.10): a tank, its tracks, knocks a tree down and drives on; a
# truck's body is stopped by a trunk; walkers and rounds still meet trunks.

func _run_trees_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	await get_tree().create_timer(3.0).timeout
	var xf := planet.global_transform
	var near: Array = trees.nearest(xf.affine_inverse() * pawn.feet(), 1)
	_check("trees round the spawn", not near.is_empty())
	if near.is_empty():
		get_tree().quit(1)
		return
	# Stand by the tree, so its cell is solid and its ground streamed.
	var w1: Vector3 = xf * (near[0].at as Vector3)
	var up1 := Gravity.up_at(w1)
	var d := Gravity.flat(w1 - pawn.feet(), up1)
	d = d.normalized() if d.length() > 0.5 else Gravity.tangent_basis(w1).x
	var stand := _ground_hit(w1 - d * 18.0 + Gravity.tangent_basis(w1).z * 6.0 + up1 * 20.0)
	pawn.place((stand if stand != Vector3.INF else w1 - d * 18.0) + up1 * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(w1 - d * 10.0 + up1 * 20.0) == Vector3.INF and Time.get_ticks_msec() - t0 < 20000:
		await _frames(1)
	await get_tree().create_timer(1.5).timeout
	var hit := get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(w1 - d * 3.0 + up1 * 1.0, w1 + d * 3.0 + up1 * 1.0, Layers.HITSCAN_MASK))
	_check("a round meets the trunk (FIXTURE, as before)", not hit.is_empty() and (hit.collider as Object).has_meta(&"on_vehicle"))
	# The tank: 10 m back from the tree, facing it, driven straight at it.
	var at := _ground_hit(w1 - d * 10.0 + up1 * 20.0)
	var tk := Tank.make(null, self, at + up1 * 0.3, 0.0, 0, null, null, Callable(), RandomNumberGenerator.new())
	PlanetBody.track(tk)
	await get_tree().create_timer(1.5).timeout
	var l := tk._local(d)
	tk.yaw = atan2(-l.x, -l.z)
	_check("the player takes the wheel", tk.take_player(0, Tank.Seat.DRIVER) and tk.driven())
	tk.throttle = 1.0
	var key: Vector3i = near[0].key
	var idx: int = near[0].index
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < 8000:
		await get_tree().physics_frame
		if trees.is_knocked(key, idx) and (tk.feet() - w1).dot(d) > 4.0:
			break
	tk.throttle = 0.0
	var past := (tk.feet() - w1).dot(d)
	_check("the tank knocks the tree down", trees.is_knocked(key, idx))
	_check("and drives on past where it stood (> 4 m)", past > 4.0, "%.1f m" % past)
	await get_tree().create_timer(PlanetTrees.FALL_S + 0.5).timeout
	var lying: Variant = trees.fallen_xf(key, idx)
	var lean := 90.0 if lying == null else rad_to_deg((lying as Transform3D).basis.y.normalized().angle_to(
			xf.affine_inverse().basis * up1))
	var toward := -1.0 if lying == null else (xf.basis * (lying as Transform3D).basis.y).normalized().dot(d)
	_check("it lies on the ground, away from the tank (85-95 deg over, top along its way)",
			lying != null and lean > 85.0 and lean < 95.0 and toward > 0.9, "%.1f deg, %.2f along" % [lean, toward])
	await _shot("planet_tree_knocked")
	# A truck's body: a trunk in its way stops it.
	var others: Array = trees.nearest(xf.affine_inverse() * pawn.feet(), 6, [[key, idx]])
	var stopped := false
	var tried := 0
	for o in others:
		var w2: Vector3 = xf * (o.at as Vector3)
		var up2 := Gravity.up_at(w2)
		var d2 := Gravity.flat(w2 - pawn.feet(), up2).normalized()
		var g2 := _ground_hit(w2 - d2 * 6.0 + up2 * 20.0)
		if g2 == Vector3.INF:
			continue
		tried += 1
		var body := CharacterBody3D.new()
		body.collision_layer = 0
		body.collision_mask = TransportTruck.BODY_MASK
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.3, 1.2, 5.0)
		cs.shape = box
		body.add_child(cs)
		add_child(body)
		var basis := Gravity.tangent_basis(w2)
		var start := Transform3D(basis.looking_at(d2, up2), g2 + up2 * 1.4)
		body.global_transform = start
		await get_tree().physics_frame
		var col := KinematicCollision3D.new()
		var met := body.test_move(start, d2 * 12.0, col)
		var by_tree := met and col.get_collider() != null and (col.get_collider() as Object).has_meta(&"on_vehicle")
		body.queue_free()
		if by_tree:
			stopped = true
			break
	_check("a truck's body is stopped by a trunk (Layers.TREE)", stopped, "%d tried" % tried)
	print("[planet] trees: %d knocked; frames worst %.1f ms" % [trees.knocked_count, _worst_ms])
	print("[planet] trees gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The bricks gate (11.11): near the player the town's buildings are bricks --
# drawn by band, solid, the shell gone -- a building has a way in at the ground,
# and the AI's world has the bricks: the nav net's path goes in through it.

func _run_bricks_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	# Which buildings should be bricks: every one but a landmark within BRICK_M.
	var want: Array[int] = []
	for i in buildings.sites.size():
		var st: PlanetBuildings.Site = buildings.sites[i]
		if not st.landmark and cam.global_position.distance_to(planet.global_position + st.frame.origin) < PlanetBuildings.BRICK_M - 10.0:
			want.append(i)
	t0 = Time.get_ticks_msec()
	var all_in := false
	# Frame times over the brick-in, and 3 s after: what walking into town costs.
	# With -- --no-bricks the same 8 s with shells only, for the A/B.
	var frame_ms: Array[float] = []
	var last_us := Time.get_ticks_usec()
	var settle_until := -1
	# The renderer's own clock (a test window's frames are paced): GPU ms a frame,
	# over the settled window (all in, or the shells' last 3 s).
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	var gpu_ms: Array[float] = []
	var cpu_ms: Array[float] = []
	while Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
		var now_us := Time.get_ticks_usec()
		frame_ms.append((now_us - last_us) / 1000.0)
		last_us = now_us
		if settle_until > 0 or (not buildings.bricks_on and Time.get_ticks_msec() - t0 > 5000):
			gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
			cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
		if not buildings.bricks_on:
			if Time.get_ticks_msec() - t0 > 8000:
				break
			continue
		if settle_until > 0:
			if Time.get_ticks_msec() > settle_until:
				break
			continue
		# Held where it stands: a long frame (an unwatched window's stall) can
		# drop a body through the voxel ground, and the bricks follow the camera.
		if _over_ground(pawn.feet()) < -0.5:
			pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
		all_in = true
		for i in want:
			if not buildings.sites[i].bricked:
				all_in = false
				break
		if all_in and settle_until < 0:
			settle_until = Time.get_ticks_msec() + 3000
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var over25 := 0
	var over40 := 0
	var sum := 0.0
	for f in frame_ms:
		sum += f
		if f > 25.0:
			over25 += 1
		if f > 40.0:
			over40 += 1
	print("[planet] frames over the brick-in%s: %d, mean %.1f ms, 95th %.1f, 99th %.1f, worst %.1f; over 25 ms %d, over 40 ms %d" % [
			"" if buildings.bricks_on else " (no bricks)", frame_ms.size(), sum / maxf(frame_ms.size(), 1),
			sorted[int(sorted.size() * 0.95)], sorted[int(sorted.size() * 0.99)], sorted[sorted.size() - 1], over25, over40])
	var g_sum := 0.0
	var c_sum := 0.0
	for g in gpu_ms:
		g_sum += g
	for c in cpu_ms:
		c_sum += c
	print("[planet] settled, the renderer: GPU %.1f ms, render CPU %.1f ms a frame (%d frames)" % [
			g_sum / maxf(gpu_ms.size(), 1), c_sum / maxf(cpu_ms.size(), 1), gpu_ms.size()])
	if not buildings.bricks_on:
		get_tree().quit(0)
		return
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("[planet] bricks: %d of %d buildings near in %.1f s; the worst brick step %.1f ms (%s)" % [
			buildings.bricked_count, want.size(), secs, buildings.brick_worst_us / 1000.0, buildings.brick_worst_what])
	_check("the buildings near the player are bricks", not want.is_empty() and all_in,
			"%d of %d in %.1f s" % [buildings.bricked_count, want.size(), secs])
	_check("brick work stays small a frame (< 12 ms)", buildings.brick_worst_us < 12000,
			"%.1f ms" % (buildings.brick_worst_us / 1000.0))
	if want.is_empty():
		get_tree().quit(1)
		return
	# The nearest of them.
	var bi: int = want[0]
	for i in want:
		if pawn.feet().distance_to(planet.global_position + buildings.sites[i].frame.origin) \
				< pawn.feet().distance_to(planet.global_position + buildings.sites[bi].frame.origin):
			bi = i
	var site: PlanetBuildings.Site = buildings.sites[bi]
	var bxf := planet.global_transform * site.frame
	var stud := BrickWorld.get_stud_metres()
	var w := site.fx * stud
	var dd := site.fz * stud
	_check("its shell is gone (only its shadow drawn, not solid)", site.shell == null
			or (site.shell.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and site.body.collision_layer == 0))
	# A ray at the building: bricks, not the shell. Through the front door, so
	# it meets the staircase in the middle (or the back wall).
	var space := get_world_3d().direct_space_state
	var mid := bxf * Vector3(w * 0.5, 1.2, -3.0)
	var into := bxf * Vector3(w * 0.5, 1.2, dd * 0.9)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(mid, into, Layers.STRUCTURE))
	_check("a ray at a wall meets its bricks", not hit.is_empty() and site.collision != null
			and site.collision.owns(hit.rid), str(hit.get("rid", "nothing")))
	# The AI: its world has the bricks, and the nav net walks in.
	# Just inside the brick the ray met.
	var wall_pt: Vector3 = (hit.position as Vector3) + (into - mid).normalized() * 0.1 if not hit.is_empty() else mid
	var aw := net.world_at(wall_pt)
	_check("the AI's world has its bricks (where the ray met a wall is solid)", aw != null and aw.solid_at(wall_pt))
	# The room the front door opens into.
	var inside_pt := net.snap(bxf * Vector3(w * 0.5, 0.3, 2.5))
	# Its front door (PlanetBuildings._cut_door): a ray through it at a metre
	# meets nothing; the nav net walks in through it to a ground-floor room.
	var door_out := bxf * Vector3(w * 0.5, 1.0, -1.5)
	var door_in := bxf * Vector3(w * 0.5, 1.0, 2.5)
	_check("a front door: a ray goes through it", space.intersect_ray(
			PhysicsRayQueryParameters3D.create(door_out, door_in, Layers.STRUCTURE)).is_empty())
	var path := net.find_path(pawn.feet(), inside_pt, 200000)
	var li := bxf.affine_inverse() * (path[path.size() - 1] if path.size() > 0 else Vector3.INF)
	var by_door := false
	for p in path:
		var lp := bxf.affine_inverse() * p
		if lp.z > -0.5 and lp.z < 1.0 and absf(lp.x - w * 0.5) < 1.5:
			by_door = true
	_check("the nav net walks in, to the room behind the door", path.size() > 2 and li.x > stud and li.x < w - stud
			and li.z > 2.0 * stud and li.z < dd - stud and absf(li.y) < 1.0, "%d points, ends at %s" % [path.size(), li])
	_check("through the door", by_door)
	# Up the stairs: a spot on the first floor beside the stairwell, and the nav
	# net's way to it from outside.
	var plate := BrickWorld.get_plate_metres()
	var floor1 := float(TowerRecipe.SLAB_PLATES + TowerRecipe.STOREY_PLATES) * plate
	var sx := TowerRecipe.stair_line(site.fx)
	var sz := TowerRecipe.stair_line(site.fz)
	var up_pt := Vector3.INF
	var shaft := StaircaseRecipe.DIAMETER
	for off in [Vector2i(-2, shaft / 2), Vector2i(shaft + 1, shaft / 2), Vector2i(shaft / 2, -2), Vector2i(shaft / 2, shaft + 1)]:
		var q := net.snap(bxf * Vector3((sx + off.x + 0.5) * stud, floor1 + 0.3, (sz + off.y + 0.5) * stud))
		var lq := bxf.affine_inverse() * q
		if net.can_stand(q) and absf(lq.y - floor1) < 0.5:
			up_pt = q
			break
	var up_path := net.find_path(pawn.feet(), up_pt, 200000) if up_pt != Vector3.INF else PackedVector3Array()
	var lu := bxf.affine_inverse() * (up_path[up_path.size() - 1] if up_path.size() > 0 else Vector3.INF)
	var climbed := 0.0
	for p in up_path:
		climbed = maxf(climbed, (bxf.affine_inverse() * p).y)
	_check("a staircase: the nav net walks up to the first floor", up_pt != Vector3.INF and up_path.size() > 2
			and absf(lu.y - floor1) < 0.5, "%d points, up to %.2f m (the floor %.2f m)" % [up_path.size(), climbed, floor1])
	await _shot("planet_bricks_town")
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] bricks gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# The damage gate (11.11 D1): the town in bricks, then a rifle's rounds at a wall
# until a brick goes, and a charge at another wall. What the bricks lost is gone
# from the collision, the drawing and the AI's world; the charge's hole is a way in.

func _run_damage_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	# The nearest building, once it is bricks.
	var bi := -1
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
		if _over_ground(pawn.feet()) < -0.5:
			pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
		var best := INF
		bi = -1
		for i in buildings.sites.size():
			var st: PlanetBuildings.Site = buildings.sites[i]
			var d := pawn.feet().distance_to(planet.global_position + st.frame.origin)
			if not st.landmark and d < best:
				best = d
				bi = i
		if bi >= 0 and buildings.sites[bi].bricked and buildings.sites[bi].band_jobs.is_empty():
			break
	var site: PlanetBuildings.Site = buildings.sites[bi]
	_check("the nearest building is bricks", site.bricked)
	_check("the player's gun and the AI's break the planet's bricks", gun.on_structure_hit.is_valid()
			and ai.on_structure_hit.is_valid() and ai.on_breach.is_valid())
	var bxf := planet.global_transform * site.frame
	var stud := BrickWorld.get_stud_metres()
	var w := site.fx * stud
	var dd := site.fz * stud
	var space := get_world_3d().direct_space_state
	# Rounds: a rifle's, at the -Z wall a stud right of the door's edge, 1.2 m up.
	# The first spot along the wall where a ray meets a brick in the wall's own
	# plane (not a window: through one it meets the room's far side).
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var hit := {}
	var tried := []
	for fx in [0.25, 0.2, 0.3, 0.15, 0.35, 0.1]:
		for fy in [0.6, 1.2, 2.0]:
			from = bxf * Vector3(w * fx, fy, -4.0)
			to = bxf * Vector3(w * fx, fy, dd * 0.5)
			hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Layers.STRUCTURE))
			var lz := 99.0 if hit.is_empty() else (bxf.affine_inverse() * (hit.position as Vector3)).z
			tried.append("%.2f/%.1f:%.2f" % [fx, fy, lz])
			if not hit.is_empty() and lz < stud * 1.5:
				break
			hit = {}
		if not hit.is_empty():
			break
	var dir := (to - from).normalized()
	_check("a ray at the wall meets its bricks", not hit.is_empty() and site.collision.owns(hit.rid),
			"" if not hit.is_empty() else " ".join(tried))
	if hit.is_empty():
		get_tree().quit(1)
		return
	var at: Vector3 = hit.position
	var shot := StructuralDamage.for_shot(WeaponClass.builtin(&"rifle"))
	var killed0 := buildings.bricks_killed
	var rounds := 0
	var band0 := 0
	var aw := net.world_at(at)
	var solid0 := aw.solid_at(at + dir * 0.1)
	while rounds < 200 and buildings.bricks_killed == killed0:
		_structure_hit(at + dir * 0.05, dir, shot)
		rounds += 1
	_check("a rifle's rounds wear a brick out", buildings.bricks_killed > killed0,
			"%d brick(s) after %d round(s), %d hp a round" % [buildings.bricks_killed - killed0, rounds, int(shot.hp)])
	var bands: Array = site.remesh.duplicate()
	for b in bands:
		if site.band_nodes.has(b):
			band0 = (site.band_nodes[b] as Node).get_instance_id()
	await _frames(20)
	_check("the AI's world has lost it (no longer solid there)", solid0 and not aw.solid_at(at + dir * 0.1))
	var hit2 := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Layers.STRUCTURE))
	var deeper := hit2.is_empty() or (hit2.position as Vector3).distance_to(from) > at.distance_to(from) + 0.1
	_check("and the collision (a ray goes further in)", deeper,
			"from %.2f m to %s" % [at.distance_to(from), "through" if hit2.is_empty() else "%.2f m" % (hit2.position as Vector3).distance_to(from)])
	var redrawn: bool = site.remesh.is_empty() and site.band_jobs.is_empty() and band0 != 0 \
			and site.band_nodes.has(bands[0]) and (site.band_nodes[bands[0]] as Node).get_instance_id() != band0
	_check("its band is drawn again", redrawn, "bands %s" % [bands])
	# A charge: at the middle of the +X wall, a metre up -- no door there.
	var c_out := bxf * Vector3(w + 3.0, 0.3, dd * 0.5)
	var c_at := bxf * Vector3(w - stud * 0.5, 1.0, dd * 0.5)
	var c_in := net.snap(bxf * Vector3(w - 2.5, 0.3, dd * 0.5))
	var before := net.find_path(net.snap(c_out), c_in, 60000)
	var k1 := buildings.bricks_killed
	buildings.damage(c_at, {"blast": true, "radius": 1.6, "hp": 0})
	await _frames(20)
	_check("a charge blows bricks out of the wall", buildings.bricks_killed - k1 >= 8, "%d" % (buildings.bricks_killed - k1))
	var after := net.find_path(net.snap(c_out), c_in, 200000)
	var through := false
	# A leg of the path that crosses the +X wall's plane by the hole.
	for k in range(1, after.size()):
		var a := bxf.affine_inverse() * after[k - 1]
		var b := bxf.affine_inverse() * after[k]
		if (a.x - w) * (b.x - w) <= 0.0 and absf(a.x - b.x) > 0.001:
			var z := lerpf(a.z, b.z, (w - a.x) / (b.x - a.x))
			if absf(z - dd * 0.5) < 2.0:
				through = true
	_check("and its hole is a way in: the nav net walks through it", after.size() > 2 and through,
			"%d points (before: %d)" % [after.size(), before.size()])
	var hole := space.intersect_ray(PhysicsRayQueryParameters3D.create(c_at + bxf.basis.x.normalized() * 2.0,
			c_at - bxf.basis.x.normalized() * 1.0, Layers.STRUCTURE))
	_check("and the collision has the hole", hole.is_empty())
	# D2: what a hit leaves joined to nothing falls. A ring cut round a panel of
	# the ground storey's -X wall -- two studs each side, the top course under
	# the slab, and the base slab under it -- leaves the panel held by nothing:
	# it must drop, as one piece, to the ground and lie there. Cut by cell, not
	# by blasts: a 2x4 brick is 1.4 m long and a blast's ring left gaps
	# (26 blasts, 30 bricks, the panel still held). Fifteen studs along the
	# wall, off the 30-stud lines where an interior wall would hold it inside.
	var pieces0 := buildings.pieces.pieces.size()
	var zc_c := mini(15, site.fz / 2)
	# Wide enough that whole bricks stand inside the ring: the towers are laid in
	# long, staggered bricks, and twelve studs kept three (a group that small is
	# crumbs, not a piece -- D2 step 2).
	var half := mini(12, site.fz / 2 - 2)
	var z0 := zc_c - half
	var z1 := zc_c + half
	var top := TowerRecipe.SLAB_PLATES + TowerRecipe.COURSES_PER_FLOOR * TowerRecipe.PLATES_PER_COURSE
	var ring_ids := {}
	var inside_cells: Array[Vector3i] = []
	for zc in range(z0, z1):
		for yc in range(0, top):
			for xc in TowerRecipe.WALL_THICK:
				var cell := Vector3i(xc, yc, zc)
				if not buildings.bricks.is_solid(site.chunk, cell):
					continue
				var edge := zc < z0 + 2 or zc >= z1 - 2 or yc < TowerRecipe.SLAB_PLATES \
						or yc >= top - TowerRecipe.PLATES_PER_COURSE
				if edge:
					ring_ids[buildings.bricks.block_at(site.chunk, cell)] = true
				else:
					inside_cells.append(cell)
	var ring := PackedInt32Array(ring_ids.keys())
	var inside := {}
	for cell in inside_cells:
		var bid := buildings.bricks.block_at(site.chunk, cell)
		if not ring_ids.has(bid):
			inside[bid] = true
	buildings.bricks.kill_blocks(site.chunk, ring)
	buildings.after_kill(bi, ring, bxf * AABB(Vector3(-1.0, -0.5, z0 * stud - 1.0),
			Vector3(3.0, top * BrickWorld.get_plate_metres() + 1.0, (z1 - z0) * stud + 2.0)))
	# Everything inside has left the building (its cells no longer the site's)
	# and every piece it went as has come to rest.
	var left := 0
	var fresh: Array = []
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 10000:
		await _frames(1)
		left = 0
		for cell in inside_cells:
			if not buildings.bricks.is_solid(site.chunk, cell):
				left += 1
		fresh = buildings.pieces.pieces.slice(pieces0)
		var all_still := not fresh.is_empty()
		for p in fresh:
			all_still = all_still and (p as PlanetPieces.Piece).settled
		if left == inside_cells.size() and all_still:
			break
	var fell := 0
	for p in fresh:
		fell += (p as PlanetPieces.Piece).bricks
	print("[planet] ring: %d bricks cut round studs %d-%d of the -X wall; %d inside, %d piece(s) of %d" % [
			ring.size(), z0, z1 - 1, inside.size(), fresh.size(), fell])
	_check("all a ring cut round a piece of wall held comes loose and falls", not inside.is_empty()
			and left == inside_cells.size() and not fresh.is_empty(),
			"%d of %d cells left, %d piece(s), %d bricks, %d solve(s), the worst %.1f ms" % [left,
			inside_cells.size(), fresh.size(), fell, buildings.solves, buildings.solve_worst_ms])
	var landed := 0
	var where := []
	for q in fresh:
		var p: PlanetPieces.Piece = q
		var up_here := Gravity.up_at(p.body.global_position)
		var under := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				p.body.global_position, p.body.global_position - up_here * 4.0,
				Layers.WORLD | Layers.STRUCTURE, [p.body.get_rid()]))
		# The terrain is no CollisionObject3D (a VoxelLodTerrain's): ground is
		# whatever the ray met that is not the building's own collision.
		var ground: bool = not under.is_empty() and not site.collision.owns(under.rid)
		if p.settled and ground:
			landed += 1
		else:
			where.append("%d bricks at %s, settled %s, on %s" % [p.bricks,
					str((bxf.affine_inverse() * p.body.global_position).snapped(Vector3.ONE * 0.1)),
					p.settled, "nothing" if under.is_empty() else str(under.collider)])
	_check("and every piece of it comes down to the planet's ground and lies there",
			not fresh.is_empty() and landed == fresh.size(), "%d of %d; %s" % [landed, fresh.size(), "; ".join(where)])
	await _shot("planet_damage")
	print("[planet] damage: %d bricks killed; frames worst %.1f ms" % [buildings.bricks_killed, _worst_ms])
	print("[planet] damage gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The falling gate (Planets.md 11.11, D2 step 2): the damage gate's panel --
# a ring cut by cell round a piece of the ground storey's -X wall, which falls
# as one piece -- lifted 8 m the moment it comes loose and let go, as the mech
# gate drops its titan: it lands hard and comes apart, pieces and crumbs, and
# all of it lies on the ground. (A panel cut free a storey up stays held: its
# wall's bricks reach past the wall onto the floor slab inside.) Then the cap:
# sixty groups shed at once from another building leave at most MAX_MOVING
# moving.

## The nearest building to the pawn but `except` (of `min_courses` or more), once
## it is bricks.
func _bricked_near(except := -1, min_courses := 0) -> int:
	var t0 := Time.get_ticks_msec()
	var bi := -1
	while Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
		var best := INF
		bi = -1
		for i in buildings.sites.size():
			var st: PlanetBuildings.Site = buildings.sites[i]
			var d := pawn.feet().distance_to(planet.global_position + st.frame.origin)
			if i != except and not st.landmark and st.courses >= min_courses and d < best:
				best = d
				bi = i
		if bi >= 0 and buildings.sites[bi].bricked and buildings.sites[bi].band_jobs.is_empty():
			return bi
	return bi


func _run_fall_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var bi: int = await _bricked_near()
	var site: PlanetBuildings.Site = buildings.sites[bi]
	_check("the nearest building is bricks", site.bricked)
	var bxf := planet.global_transform * site.frame
	var stud := BrickWorld.get_stud_metres()
	var space := get_world_3d().direct_space_state
	var pc := buildings.pieces
	var storey := TowerRecipe.SLAB_PLATES + TowerRecipe.COURSES_PER_FLOOR * TowerRecipe.PLATES_PER_COURSE
	var zc_c := mini(15, site.fz / 2)
	# Wide enough that whole bricks stand inside the ring: the towers are laid in
	# long, staggered bricks, and twelve studs kept three (a group that small is
	# crumbs, not a piece -- D2 step 2).
	var half := mini(12, site.fz / 2 - 2)
	var z0 := zc_c - half
	var z1 := zc_c + half
	var ring_ids := {}
	for zc in range(z0, z1):
		for yc in range(0, storey):
			for xc in TowerRecipe.WALL_THICK:
				var cell := Vector3i(xc, yc, zc)
				if not buildings.bricks.is_solid(site.chunk, cell):
					continue
				var edge := zc < z0 + 2 or zc >= z1 - 2 or yc < TowerRecipe.SLAB_PLATES \
						or yc >= storey - TowerRecipe.PLATES_PER_COURSE
				if edge:
					ring_ids[buildings.bricks.block_at(site.chunk, cell)] = true
	var ring := PackedInt32Array(ring_ids.keys())
	var landings0 := pc.landings
	var crumbs0 := pc.crumbs.thrown
	var broke0 := pc.broke_off
	var pieces0 := pc.pieces.size()
	buildings.bricks.kill_blocks(site.chunk, ring)
	buildings.after_kill(bi, ring, bxf * AABB(Vector3(-1.0, -0.5, z0 * stud - 1.0),
			Vector3(3.0, storey * BrickWorld.get_plate_metres() + 1.0, (z1 - z0) * stud + 2.0)))
	# The panel, the moment it is a piece: lifted 8 m and let go.
	t0 = Time.get_ticks_msec()
	while pc.pieces.size() == pieces0 and Time.get_ticks_msec() - t0 < 5000:
		await get_tree().physics_frame
	var panel: PlanetPieces.Piece = null
	for q in pc.pieces.slice(pieces0):
		var pp: PlanetPieces.Piece = q
		if panel == null or pp.bricks > panel.bricks:
			panel = pp
	_check("the ring's panel comes loose as a piece", panel != null and is_instance_valid(panel.body),
			"%d piece(s)" % (pc.pieces.size() - pieces0))
	if panel == null:
		get_tree().quit(1)
		return
	var bricks0 := panel.bricks
	var up0 := Gravity.up_at(panel.body.global_position)
	panel.body.global_position += up0 * 8.0
	panel.body.linear_velocity = Vector3.ZERO
	panel.body.angular_velocity = Vector3.ZERO
	panel.body.reset_physics_interpolation()
	panel.prev_speed = 0.0
	panel.fall_ticks = 0
	var fresh: Array = []
	var peak_speed := 0.0
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 15000:
		await get_tree().physics_frame
		fresh = pc.pieces.slice(pieces0)
		var all_still := not fresh.is_empty()
		for q in fresh:
			var p: PlanetPieces.Piece = q
			all_still = all_still and p.settled
			if is_instance_valid(p.body):
				peak_speed = maxf(peak_speed, p.body.linear_velocity.length())
		if all_still and Time.get_ticks_msec() - t0 > 1500:
			break
	print("[planet] fall: ring %d bricks round studs %d-%d; the panel %d bricks, dropped 8 m; %d piece(s) now, landings %d, broke off %d, crumbs %d (groups: %d small, %d over the cap); fastest %.1f m/s" % [
			ring.size(), z0, z1 - 1, bricks0, fresh.size(), pc.landings - landings0, pc.broke_off - broke0,
			pc.crumbs.thrown - crumbs0, pc.crumbed_small, pc.crumbed_cap, peak_speed])
	_check("dropped 8 m, it lands hard (a landing by the city's rule)", pc.landings > landings0,
			"fastest %.1f m/s" % peak_speed)
	_check("and comes apart: pieces broken off or crumbs thrown",
			pc.broke_off > broke0 or pc.crumbs.thrown > crumbs0,
			"broke off %d, crumbs %d" % [pc.broke_off - broke0, pc.crumbs.thrown - crumbs0])
	var landed := 0
	var where := []
	for q in fresh:
		var p: PlanetPieces.Piece = q
		if not is_instance_valid(p.body):
			continue
		var up_here := Gravity.up_at(p.body.global_position)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				p.body.global_position, p.body.global_position - up_here * 4.0,
				Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS, [p.body.get_rid()]))
		# Ground is what is not the building's own collision (the terrain is no
		# CollisionObject3D); a piece on a piece is down too.
		var down: bool = not hit.is_empty() and not site.collision.owns(hit.rid)
		if p.settled and down:
			landed += 1
		else:
			where.append("%d bricks at %s, settled %s" % [p.bricks,
					str((bxf.affine_inverse() * p.body.global_position).snapped(Vector3.ONE * 0.1)), p.settled])
	_check("every piece of it ends on the ground and lies there", not fresh.is_empty() and landed == fresh.size(),
			"%d of %d; %s" % [landed, fresh.size(), "; ".join(where)])
	await _shot("planet_fall")
	await get_tree().create_timer(2.2).timeout
	_check("its crumbs lie a moment and are gone", pc.crumbs.alive == 0, "%d still" % pc.crumbs.alive)
	# The cap: sixty groups of nine of another building's bricks, shed at once.
	var b2: int = await _bricked_near(bi)
	var s2: PlanetBuildings.Site = buildings.sites[b2]
	var ids := PackedInt32Array()
	# Its bricks, all of it (whole bricks are long: a storey is ~200), from the
	# top down, so the building under them is what is left standing.
	var dims := buildings.bricks.get_chunk_dims(s2.chunk)
	for yc in range(dims.y - 1, -1, -1):
		for zc in dims.z:
			for xc in dims.x:
				var bid := buildings.bricks.block_at(s2.chunk, Vector3i(xc, yc, zc))
				if bid >= 0 and not buildings.bricks.is_block_absent(s2.chunk, bid) and not ids.has(bid):
					ids.append(bid)
	var groups: Array = []
	# Nine bricks a group: one over what is crumbs, so each is a piece unless
	# the cap says not.
	var per := PlanetPieces.DEBRIS_MAX_BLOCKS + 1
	for g in 60:
		if (g + 1) * per > ids.size():
			break
		groups.append(ids.slice(g * per, (g + 1) * per))
	var all := PackedInt32Array()
	for g in groups:
		all.append_array(g as PackedInt32Array)
	s2.collision.disable(all)
	for b in s2.collision.bands_of(all):
		if not s2.remesh.has(b):
			s2.remesh.append(b)
	var cap0 := pc.crumbed_cap
	var made := pc.shed(s2.chunk, groups)
	buildings.bricks.bake_chunk_async(s2.chunk)
	await _frames(2)
	_check("sixty groups at once: at most %d move, the rest are crumbs" % PlanetPieces.MAX_MOVING,
			groups.size() == 60 and pc.moving() <= PlanetPieces.MAX_MOVING and pc.crumbed_cap - cap0 >= 60 - PlanetPieces.MAX_MOVING,
			"%d groups, %d pieces made, %d moving, %d to crumbs over the cap" % [groups.size(), made, pc.moving(), pc.crumbed_cap - cap0])
	print("[planet] frames: worst %.1f ms; over 40 ms: %s" % [_worst_ms, _hitches])
	print("[planet] fall gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The hits gate (Planets.md 11.11, D2 step 3): the damage gate's panel brought
# down and at rest; rifle rounds wear a brick out of it, a charge breaks it
# up, and what is left lies on something.

func _run_hits_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var bi: int = await _bricked_near()
	var site: PlanetBuildings.Site = buildings.sites[bi]
	var bxf := planet.global_transform * site.frame
	var stud := BrickWorld.get_stud_metres()
	var space := get_world_3d().direct_space_state
	var pc := buildings.pieces
	var storey := TowerRecipe.SLAB_PLATES + TowerRecipe.COURSES_PER_FLOOR * TowerRecipe.PLATES_PER_COURSE
	var zc_c := mini(15, site.fz / 2)
	var half := mini(12, site.fz / 2 - 2)
	var z0 := zc_c - half
	var z1 := zc_c + half
	var ring_ids := {}
	for zc in range(z0, z1):
		for yc in range(0, storey):
			for xc in TowerRecipe.WALL_THICK:
				var cell := Vector3i(xc, yc, zc)
				if not buildings.bricks.is_solid(site.chunk, cell):
					continue
				var edge := zc < z0 + 2 or zc >= z1 - 2 or yc < TowerRecipe.SLAB_PLATES \
						or yc >= storey - TowerRecipe.PLATES_PER_COURSE
				if edge:
					ring_ids[buildings.bricks.block_at(site.chunk, cell)] = true
	var ring := PackedInt32Array(ring_ids.keys())
	var pieces0 := pc.pieces.size()
	buildings.bricks.kill_blocks(site.chunk, ring)
	buildings.after_kill(bi, ring, bxf * AABB(Vector3(-1.0, -0.5, z0 * stud - 1.0),
			Vector3(3.0, storey * BrickWorld.get_plate_metres() + 1.0, (z1 - z0) * stud + 2.0)))
	var panel: PlanetPieces.Piece = null
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 10000:
		await get_tree().physics_frame
		for q in pc.pieces.slice(pieces0):
			var pp: PlanetPieces.Piece = q
			if panel == null or pp.bricks > panel.bricks:
				panel = pp
		if panel != null and panel.settled:
			break
	_check("the panel comes down and lies at rest", panel != null and panel.settled,
			"%d piece(s)" % (pc.pieces.size() - pieces0))
	if panel == null or not panel.settled:
		get_tree().quit(1)
		return
	# Rounds: a rifle's, straight down onto it from above its middle.
	var up := Gravity.up_at(panel.body.global_position)
	var from := panel.body.global_position + up * 4.0
	var to := panel.body.global_position - up * 1.0
	var mask := Layers.DEBRIS | Layers.FALLING
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, mask))
	_check("a ray from above meets the panel", not hit.is_empty() and hit.collider == panel.body)
	if hit.is_empty():
		get_tree().quit(1)
		return
	var at: Vector3 = hit.position
	var dir := (to - from).normalized()
	var shot := StructuralDamage.for_shot(WeaponClass.builtin(&"rifle"))
	var bricks0 := panel.bricks
	var killed0 := pc.hit_killed
	var crumbs0 := pc.crumbs.thrown
	var rounds := 0
	while rounds < 200 and pc.hit_killed == killed0:
		_structure_hit(at + dir * 0.05, dir, shot)
		rounds += 1
	_check("a rifle's rounds wear a brick out of it", pc.hit_killed > killed0 and panel.bricks < bricks0,
			"%d brick(s) after %d round(s); %d -> %d bricks" % [pc.hit_killed - killed0, rounds, bricks0, panel.bricks])
	_check("the brick it killed is thrown as crumbs", pc.crumbs.thrown > crumbs0,
			"%d crumb(s)" % (pc.crumbs.thrown - crumbs0))
	await _frames(3)
	var hit2 := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, mask))
	var deeper: bool = hit2.is_empty() or hit2.collider != panel.body \
			or (hit2.position as Vector3).distance_to(from) > at.distance_to(from) + 0.05
	_check("and its shapes have the hole (the ray goes further in)", deeper,
			"from %.2f m to %s" % [at.distance_to(from), "through" if hit2.is_empty() else "%.2f m" % (hit2.position as Vector3).distance_to(from)])
	# A charge on it.
	var k1 := pc.hit_killed
	var made0 := pc.made
	var c0 := pc.crumbs.thrown
	var b1 := panel.bricks
	buildings.damage(panel.body.global_position, {"blast": true, "radius": 1.6, "hp": 0})
	_check("a charge blows bricks out of it", pc.hit_killed - k1 >= 3, "%d" % (pc.hit_killed - k1))
	_check("and breaks it up: pieces off, crumbs, or the panel gone",
			pc.made > made0 or pc.crumbs.thrown > c0 or panel.fading_since != 0,
			"%d -> %d bricks, %d new piece(s), %d crumb(s)" % [b1, panel.bricks, pc.made - made0, pc.crumbs.thrown - c0])
	# What is left lies on something.
	await get_tree().create_timer(4.0).timeout
	var resting := 0
	var left := 0
	var where := []
	for q in pc.pieces.slice(pieces0):
		var p: PlanetPieces.Piece = q
		if not is_instance_valid(p.body) or p.fading_since != 0:
			continue
		left += 1
		var u := Gravity.up_at(p.body.global_position)
		var under := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				p.body.global_position, p.body.global_position - u * 4.0,
				Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS, [p.body.get_rid()]))
		if p.settled and not under.is_empty():
			resting += 1
		else:
			where.append("%d bricks, settled %s" % [p.bricks, p.settled])
	_check("and what is left of it lies on something, at rest", resting == left,
			"%d of %d; %s" % [resting, left, "; ".join(where)])
	await _shot("planet_hits")
	print("[planet] hits: %d hit(s) on pieces, %d bricks; %d woken; crumbs %d; frames worst %.1f ms" % [
			pc.hits, pc.hit_killed, pc.woken, pc.crumbs.thrown, _worst_ms])
	print("[planet] hits gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The topple gate (Planets.md 11.11, D2 step 4): the ground storey under 55% of
# a building's footprint cut away (by cell, as the city's stress pass blasts
# it); off balance, it goes over whole, falls, and lies on the ground; it is no
# building any more.

func _run_topple_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var bi: int = await _bricked_near()
	var site: PlanetBuildings.Site = buildings.sites[bi]
	_check("the nearest building is bricks", site.bricked)
	var bxf := planet.global_transform * site.frame
	var pc := buildings.pieces
	var storey := TowerRecipe.SLAB_PLATES + TowerRecipe.COURSES_PER_FLOOR * TowerRecipe.PLATES_PER_COURSE
	var alive0 := buildings.bricks.get_alive_block_count(site.chunk)
	var cut_ids := {}
	var x_end := int(ceil(site.fx * 0.55))
	for yc in range(0, storey):
		for zc in site.fz:
			for xc in x_end:
				var bid := buildings.bricks.block_at(site.chunk, Vector3i(xc, yc, zc))
				if bid >= 0 and not buildings.bricks.is_block_absent(site.chunk, bid):
					cut_ids[bid] = true
	var cut := PackedInt32Array(cut_ids.keys())
	var toppled0 := buildings.toppled_count
	var pieces0 := pc.pieces.size()
	buildings.bricks.kill_blocks(site.chunk, cut)
	buildings.after_kill(bi, cut, buildings.site_box(bi).grow(1.0))
	t0 = Time.get_ticks_msec()
	while buildings.toppled_count == toppled0 and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().physics_frame
	var tower: PlanetPieces.Piece = null
	for q in pc.pieces.slice(pieces0):
		var pp: PlanetPieces.Piece = q
		if tower == null or pp.bricks > tower.bricks:
			tower = pp
	print("[planet] topple: %d of %d bricks cut from the ground storey under %d of %d studs" % [
			cut.size(), alive0, x_end, site.fx])
	_check("off balance, it topples whole: one piece of every brick it had",
			buildings.toppled_count > toppled0 and tower != null and tower.bricks >= (alive0 - cut.size()) * 0.9,
			"%s" % ("no topple" if tower == null else "%d bricks (%d left standing)" % [tower.bricks, alive0 - cut.size()]))
	_check("and it is no building any more: no collision, no shell, not bricks", site.toppled
			and site.collision == null and site.shell == null and not site.bricked)
	if tower == null:
		get_tree().quit(1)
		return
	# It goes over, and comes to rest.
	var up0 := Gravity.up_at(tower.body.global_position)
	var b0: Basis = tower.body.global_transform.basis
	var tilt := 0.0
	var fresh: Array = []
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 25000:
		await get_tree().physics_frame
		if is_instance_valid(tower.body):
			var b: Basis = tower.body.global_transform.basis
			tilt = maxf(tilt, rad_to_deg((b * (b0.inverse() * up0)).angle_to(Gravity.up_at(tower.body.global_position))))
		fresh = pc.pieces.slice(pieces0)
		var all_still := not fresh.is_empty()
		for q in fresh:
			all_still = all_still and ((q as PlanetPieces.Piece).settled or (q as PlanetPieces.Piece).fading_since != 0)
		if all_still and Time.get_ticks_msec() - t0 > 2000:
			break
	print("[planet] topple: tilted %.0f deg; %d piece(s), landings %d, snaps %d, crumbs %d; frames worst %.1f ms" % [
			tilt, fresh.size(), pc.landings, pc.snaps, pc.crumbs.thrown, _worst_ms])
	_check("it falls over (its up more than 30 deg from the ground's)", tilt > 30.0, "%.0f deg" % tilt)
	var space := get_world_3d().direct_space_state
	var resting := 0
	var left := 0
	var where := []
	for q in fresh:
		var p: PlanetPieces.Piece = q
		if not is_instance_valid(p.body) or p.fading_since != 0:
			continue
		left += 1
		var u := Gravity.up_at(p.body.global_position)
		var under := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				p.body.global_position, p.body.global_position - u * 12.0,
				Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS, [p.body.get_rid()]))
		if p.settled and not under.is_empty():
			resting += 1
		else:
			where.append("%d bricks, settled %s" % [p.bricks, p.settled])
	_check("and it comes to rest, every piece of it on something", left > 0 and resting == left,
			"%d of %d; %s" % [resting, left, "; ".join(where)])
	await _shot("planet_topple")
	await get_tree().create_timer(1.0).timeout
	_check("no shell and no far box come back where it stood", site.shell == null and site.fade == 0.0
			and site.chunk < 0)
	print("[planet] topple gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The pieces' AI gate (Planets.md 11.11, D2 step 5): a building toppled across
# the open ground (as the topple gate); at rest, its biggest piece is bricks to
# the AI -- solid in its world, cover across it -- and a path from one side of
# it to the other goes round it.

func _run_pieces_ai_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var net := ai.nav_net as PlanetNavNet
	var bi: int = await _bricked_near()
	var site: PlanetBuildings.Site = buildings.sites[bi]
	var pc := buildings.pieces
	var storey := TowerRecipe.SLAB_PLATES + TowerRecipe.COURSES_PER_FLOOR * TowerRecipe.PLATES_PER_COURSE
	var cut_ids := {}
	for yc in range(0, storey):
		for zc in site.fz:
			for xc in int(ceil(site.fx * 0.55)):
				var bid := buildings.bricks.block_at(site.chunk, Vector3i(xc, yc, zc))
				if bid >= 0 and not buildings.bricks.is_block_absent(site.chunk, bid):
					cut_ids[bid] = true
	var cut := PackedInt32Array(cut_ids.keys())
	var pieces0 := pc.pieces.size()
	# The AI's regions round the building made BEFORE it falls (paths every way
	# across where it stands), so what they know of it afterwards is what they
	# were told, not what a fresh region read.
	var mid := buildings.site_box(bi).get_center()
	var u0 := Gravity.up_at(mid)
	var ax := Gravity.flat(Vector3.RIGHT, u0).normalized()
	for k in 8:
		var d := ax.rotated(u0, TAU * k / 8.0)
		net.find_path(net.snap(mid + d * 45.0), net.snap(mid - d * 45.0), 60000)
	# And the town done bricking: a building's bricks coming or going re-syncs
	# every region (PlanetNavNet.set_site_bricks), which would tell them of the
	# pieces whatever this step does.
	t0 = Time.get_ticks_msec()
	while (not buildings._brick_queue.is_empty() or buildings._brick_site >= 0) \
			and Time.get_ticks_msec() - t0 < 90000:
		await _frames(1)
	await _frames(5)
	var regions0 := net.regions.size()
	buildings.bricks.kill_blocks(site.chunk, cut)
	buildings.after_kill(bi, cut, buildings.site_box(bi).grow(1.0))
	# At rest: every piece of it settled.
	var fresh: Array = []
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000:
		await get_tree().physics_frame
		fresh = pc.pieces.slice(pieces0)
		var all_still := not fresh.is_empty()
		for q in fresh:
			all_still = all_still and ((q as PlanetPieces.Piece).settled or (q as PlanetPieces.Piece).fading_since != 0)
		if all_still and Time.get_ticks_msec() - t0 > 2000:
			break
	var big: PlanetPieces.Piece = null
	for q in fresh:
		var pp: PlanetPieces.Piece = q
		if pp.settled and pp.fading_since == 0 and (big == null or pp.bricks > big.bricks):
			big = pp
	_check("the building toppled and lies at rest", big != null and buildings.toppled_count > 0,
			"%d piece(s)" % fresh.size())
	if big == null:
		get_tree().quit(1)
		return
	await _frames(3)
	var bw := buildings.bricks
	var xf := bw.get_chunk_transform(big.chunk)
	var dims := bw.get_chunk_dims(big.chunk)
	var cs := BrickWorld.get_cell_size()
	# Its bricks, sampled, and the AI's world at each (the region round it).
	var brick_at := Vector3.INF
	var sampled := 0
	var solid := 0
	for yc in range(0, dims.y, 2):
		for zc in range(0, dims.z, 3):
			for xc in range(0, dims.x, 3):
				var bid := bw.block_at(big.chunk, Vector3i(xc, yc, zc))
				if bid < 0 or bw.is_block_absent(big.chunk, bid) or bw.is_block_decorative(big.chunk, bid):
					continue
				var w := xf * ((Vector3(xc, yc, zc) + Vector3.ONE * 0.5) * cs)
				if brick_at == Vector3.INF:
					brick_at = w
				var r := net.world_at(w)
				sampled += 1
				if r != null and r.solid_at(w):
					solid += 1
	var aw := net.world_at(brick_at)
	_check("its bricks are solid in the AI's world where it lies (most of a sample)",
			aw != null and sampled > 0 and solid > sampled * 0.75, "%d of %d" % [solid, sampled])
	# Across it: its long axis lies along the ground; points either side of it.
	var com := big.body.global_position
	var up := Gravity.up_at(com)
	var size := Vector3(dims) * cs
	var long_axis := xf.basis.y.normalized()
	var long := size.y
	if size.x > long:
		long_axis = xf.basis.x.normalized()
		long = size.x
	if size.z > long:
		long_axis = xf.basis.z.normalized()
		long = size.z
	var side := Gravity.flat(long_axis.cross(up), up).normalized()
	var reach := maxf(maxf(size.x, size.y), size.z)
	var a := _ground_hit(com + side * (reach * 0.5 + 6.0) + up * 20.0)
	var b := _ground_hit(com - side * (reach * 0.5 + 6.0) + up * 20.0)
	var lift := up * 1.0
	var blocks := aw.bricks_between(a + lift, b + lift) if a != Vector3.INF and b != Vector3.INF else 0
	_check("a line across it, a metre up, meets its bricks (cover)", blocks > 0, "%d brick(s)" % blocks)
	var path := net.find_path(net.snap(a), net.snap(b), 200000)
	var inside := 0
	var inv := xf.affine_inverse()
	for pt in path:
		var l := inv * pt
		if l.x > 0.3 and l.y > 0.3 and l.z > 0.3 and l.x < size.x - 0.3 and l.y < size.y - 0.3 and l.z < size.z - 0.3:
			inside += 1
	var length := 0.0
	for k in range(1, path.size()):
		length += path[k].distance_to(path[k - 1])
	print("[planet] pieces_ai: the biggest piece %d bricks, %.1f m long; across it %.1f m straight, the path %.1f m (%d points, %d inside it)" % [
			big.bricks, long, a.distance_to(b), length, path.size(), inside])
	_check("a path from one side to the other goes round it, none of it inside", path.size() > 2 and inside == 0
			and length > a.distance_to(b) * 1.05, "%d points, %d inside, %.1f m vs %.1f m straight" % [
			path.size(), inside, length, a.distance_to(b)])
	print("[planet] pieces_ai: %d region(s) before it fell, %d after" % [regions0, net.regions.size()])
	print("[planet] pieces_ai gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------------------
# The storey gate (Planets.md 11.11, D2 step 6): what is left of a storey has to
# carry what is above it (PlanetBuildings._storey_fail, the city's
# _gravity_fail). A tower's first-floor walls cut away (by cell) but for one
# corner: what is above is off the edge of it -- TIP -- and goes over as one
# piece. Another tower made too weak for its own weight (as the city's collapse
# probe does it): a storey is crushed -- CRUSH -- and what is above comes down.
# Every piece ends at rest. Untouched buildings are nowhere near failing.

## Live bricks of `chunk` whose middle is above `y` (chunk-local metres).
func _bricks_above(chunk: int, y: float) -> int:
	var n := 0
	for bx in buildings.bricks.get_block_boxes(chunk):
		var d: Dictionary = bx
		if bool(d.alive) and (d.pos as Vector3).y > y and not buildings.bricks.is_block_absent(chunk, int(d.block)):
			n += 1
	return n


## Waits for every piece born since `pieces0` to be still (or gone), `ms` at
## most and 2 s at least. Of every piece of BIG_PIECE bricks or more, from when
## it is first seen: the most it tilted from its first up, the most it dropped
## along it, and the most bricks one had.
const BIG_PIECE := 100

func _settle(pieces0: int, ms: int) -> Dictionary:
	var pc := buildings.pieces
	var first := {}   # piece -> [basis, up, position]
	var tilt := 0.0
	var drop := 0.0
	var born := 0
	var fresh: Array = []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().physics_frame
		fresh = pc.pieces.slice(pieces0)
		var all_still := true
		for q in fresh:
			var p: PlanetPieces.Piece = q
			all_still = all_still and (p.settled or p.fading_since != 0)
			if not is_instance_valid(p.body):
				continue
			if not first.has(p):
				if p.bricks < BIG_PIECE:
					continue
				born = maxi(born, p.bricks)
				first[p] = [p.body.global_transform.basis, Gravity.up_at(p.body.global_position),
						p.body.global_position]
			var f: Array = first[p]
			var b: Basis = p.body.global_transform.basis
			tilt = maxf(tilt, rad_to_deg((b * ((f[0] as Basis).inverse() * (f[1] as Vector3))).angle_to(
					Gravity.up_at(p.body.global_position))))
			drop = maxf(drop, ((f[2] as Vector3) - p.body.global_position).dot(f[1] as Vector3))
		if all_still and Time.get_ticks_msec() - t0 > 2000:
			break
	return {"fresh": fresh, "tilt": tilt, "drop": drop, "born": born}


## Of `fresh`, the pieces left that are settled on something (a ray along down).
func _resting(fresh: Array) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var resting := 0
	var left := 0
	var where := []
	for q in fresh:
		var p: PlanetPieces.Piece = q
		if not is_instance_valid(p.body) or p.fading_since != 0:
			continue
		left += 1
		var u := Gravity.up_at(p.body.global_position)
		var under := space.intersect_ray(PhysicsRayQueryParameters3D.create(
				p.body.global_position, p.body.global_position - u * 12.0,
				Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS, [p.body.get_rid()]))
		if p.settled and not under.is_empty():
			resting += 1
		else:
			where.append("%d bricks, settled %s" % [p.bricks, p.settled])
	return {"resting": resting, "left": left, "where": where}


func _run_storey_gate() -> void:
	var t0 := Time.get_ticks_msec()
	while pawn == null and Time.get_ticks_msec() - t0 < 60000:
		await _frames(1)
	var town: Vector3 = town_dirs[0]
	var p_feet := _surface(_round_dir(town, spawn_dir, 88.0))
	pawn.place(p_feet + Gravity.up_at(p_feet) * 0.3)
	t0 = Time.get_ticks_msec()
	while _ground_hit(p_feet) == Vector3.INF and Time.get_ticks_msec() - t0 < 30000:
		await _frames(1)
	setup_ai(town)
	var bw := buildings.bricks
	var pc := buildings.pieces
	var st := TowerRecipe.STOREY_PLATES
	var plate := BrickWorld.get_plate_metres()
	var tall := 3 * TowerRecipe.COURSES_PER_FLOOR
	var bi: int = await _bricked_near(-1, tall)
	var site: PlanetBuildings.Site = buildings.sites[bi]
	_check("a tower of three storeys or more is bricks", site.bricked and site.courses >= tall,
			"%d courses" % site.courses)
	if not site.bricked:
		get_tree().quit(1)
		return
	# Untouched, as the city's probe asks it: the crush load is the same whatever
	# a stud holds in tension (BrickStrength).
	var worst := 0.0
	var worst_region := 0.0
	var asked := 0
	for k in buildings.sites.size():
		var sk: PlanetBuildings.Site = buildings.sites[k]
		if not sk.bricked or sk.chunk < 0 or sk.toppled:
			continue
		var r: Dictionary = bw.gravity_check(sk.chunk,
				buildings.crush_per_stud * BrickStrength.SCALED / bw.get_tension_per_stud(sk.chunk))
		worst = maxf(worst, float(r.get("ratio", 0.0)))
		worst_region = maxf(worst_region, float(r.get("region_ratio", 0.0)))
		asked += 1
	_check("no untouched building is near failing a storey", asked > 0 and worst < 0.8 and worst_region < 0.8,
			"%d asked, worst %.2f of what it can (one region %.2f)" % [asked, worst, worst_region])

	# TIP: the first floor's walls cut but for one corner, CORNER studs square
	# (every brick with a cell in it kept, so the corner is whole).
	const CORNER := 7
	var keep := {}
	for yc in range(st + TowerRecipe.SLAB_PLATES, 2 * st):
		for zc in range(site.fz - CORNER, site.fz):
			for xc in range(site.fx - CORNER, site.fx):
				var bid := bw.block_at(site.chunk, Vector3i(xc, yc, zc))
				if bid >= 0:
					keep[bid] = true
	var cut_ids := {}
	for yc in range(st + TowerRecipe.SLAB_PLATES, 2 * st):
		for zc in site.fz:
			for xc in site.fx:
				var bid := bw.block_at(site.chunk, Vector3i(xc, yc, zc))
				if bid >= 0 and not keep.has(bid) and not bw.is_block_absent(site.chunk, bid):
					cut_ids[bid] = true
	var cut := PackedInt32Array(cut_ids.keys())
	var top_y := 2 * st * plate
	var alive0 := bw.get_alive_block_count(site.chunk)
	var tip0 := int(buildings.storey_fails.tip)
	var pieces0 := pc.pieces.size()
	bw.kill_blocks(site.chunk, cut)
	buildings.after_kill(bi, cut, buildings.site_box(bi).grow(1.0))
	# What the building holds once cut (a piece shed later still counts as
	# alive in it: measured from here, not after).
	var alive1 := bw.get_alive_block_count(site.chunk)
	t0 = Time.get_ticks_msec()
	while int(buildings.storey_fails.tip) == tip0 and not site.toppled and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().physics_frame
	print("[planet] storey: tower %d (%d x %d studs, %d courses), %d of %d bricks cut from its first floor, %d kept in the corner; fails %s" % [
			bi, site.fx, site.fz, site.courses, cut.size(), alive0, keep.size(), str(buildings.storey_fails)])
	_check("one corner left: the storey check says TIP", int(buildings.storey_fails.tip) > tip0 and not site.toppled,
			"tips %d, toppled whole %s" % [int(buildings.storey_fails.tip) - tip0, site.toppled])
	var tipped: Dictionary = await _settle(pieces0, 25000)
	var left_above := _bricks_above(site.chunk, top_y) if site.chunk >= 0 else -1
	var went := alive1 - (bw.get_alive_block_count(site.chunk) if site.chunk >= 0 else 0)
	print("[planet] storey: tip -- the piece above %d bricks (%d left the building), tilted %.0f deg; %d piece(s), landings %d, snaps %d, crumbs %d; storey check worst %.2f ms" % [
			int(tipped.born), went, float(tipped.tilt), (tipped.fresh as Array).size(), pc.landings, pc.snaps,
			pc.crumbs.thrown, buildings.storey_worst_ms])
	_check("what is above leaves as one piece", int(tipped.born) >= went * 0.8 and went > 0,
			"%d of the %d that left" % [int(tipped.born), went])
	_check("nothing of it is left above that storey", left_above == 0, "%d brick(s)" % left_above)
	# Over the edge of the corner, onto the first floor's own slab: a storey
	# post under a top three times its width tips it some 15 degrees.
	_check("it goes over the edge (its up more than 10 deg from the ground's) and comes down",
			float(tipped.tilt) > 10.0 and float(tipped.drop) > 1.0,
			"%.0f deg, %.1f m" % [float(tipped.tilt), float(tipped.drop)])
	var rest: Dictionary = _resting(tipped.fresh)
	_check("and every piece of it comes to rest on something", int(rest.left) > 0 and int(rest.resting) == int(rest.left),
			"%d of %d; %s" % [int(rest.resting), int(rest.left), "; ".join(rest.where)])
	_check("the building still stands below it", site.bricked and not site.toppled and site.chunk >= 0
			and bw.get_alive_block_count(site.chunk) > 0)
	await _shot("planet_storey_tip")

	# CRUSH: an untouched tower too weak for its own weight (crush_per_stud 0.5,
	# as the city's collapse probe weakens one) is asked again.
	var ci: int = await _bricked_near(bi, tall)
	var cs: PlanetBuildings.Site = buildings.sites[ci]
	if not cs.bricked:
		_check("a second tower is bricks", false)
		get_tree().quit(1)
		return
	var c_alive0 := bw.get_alive_block_count(cs.chunk)
	var crush0 := int(buildings.storey_fails.crush) + int(buildings.storey_fails.region)
	pieces0 = pc.pieces.size()
	buildings.crush_per_stud = 0.5
	cs.solve_due = true
	t0 = Time.get_ticks_msec()
	while int(buildings.storey_fails.crush) + int(buildings.storey_fails.region) == crush0 \
			and not cs.toppled and Time.get_ticks_msec() - t0 < 10000:
		await get_tree().physics_frame
	buildings.crush_per_stud = PlanetBuildings.CRUSH_PER_STUD
	print("[planet] storey: tower %d (%d x %d studs, %d courses, %d bricks) made weak; fails %s" % [
			ci, cs.fx, cs.fz, cs.courses, c_alive0, str(buildings.storey_fails)])
	_check("too weak for its weight: the storey check says CRUSH",
			int(buildings.storey_fails.crush) + int(buildings.storey_fails.region) > crush0 and not cs.toppled)
	var crushed: Dictionary = await _settle(pieces0, 25000)
	var drop := float(crushed.drop)
	var c_left := bw.get_alive_block_count(cs.chunk) if cs.chunk >= 0 else 0
	print("[planet] storey: crushed -- the piece above %d bricks, dropped %.1f m; %d of %d bricks left standing; %d piece(s), crumbs %d" % [
			int(crushed.born), drop, c_left, c_alive0, (crushed.fresh as Array).size(), pc.crumbs.thrown])
	_check("what is above comes down: fewer than half its bricks left standing", int(crushed.born) > 0
			and c_left < c_alive0 / 2, "%d of %d" % [c_left, c_alive0])
	_check("it dropped half a storey or more", drop >= st * plate * 0.5, "%.1f m (a storey %.1f m)" % [drop, st * plate])
	rest = _resting(crushed.fresh)
	_check("and every piece of it comes to rest on something", int(rest.left) > 0 and int(rest.resting) == int(rest.left),
			"%d of %d; %s" % [int(rest.resting), int(rest.left), "; ".join(rest.where)])
	await _shot("planet_storey_crush")
	print("[planet] storey gate: %d ok, %d FAIL" % [_ok, _fail])
	get_tree().quit(0 if _fail == 0 else 1)

