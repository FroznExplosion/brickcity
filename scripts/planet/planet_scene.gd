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
##   -- --gate=snap: a landing snaps a piece where the city's would -- a weak
##   seam or a storey line up its Y, a crack along the bond across (D2 step 7).
##   -- --gate=farfight: bricks where the AI fights, away from the camera; a hit
##   on a building not yet bricks lands once it is (11.11).
##   -- --gate=trees: a tank knocks a tree down; a truck is stopped by one
##   (11.10, trees and vehicles).
##   -- --gate=squad: a squad on the AI's nav region round the town (11.8 N2)
##   walks to the player round the curve, takes cover, fires.
##   -- --gate=garrison: a generated world's own AI and a town's squad (11.12 step 7);
##      with --size=N its town counts as N buildings (PlanetGarrison.plan_for)
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
var cam: PlayerCamera
var pawn: Pawn
var player: PlayerController
var gun: GunController
var view: PlayerView
## The player's kit round the pawn: arsenal, HUD, aim assist -- the city's own (PlayerKit).
var kit: PlayerKit
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
## The hull gate, then the autopilot's flight to another planet (Docs/Hulls.md 7b).
var _auto_gate := false
var _belt_gate := false
var _home_gate := false
var _save_gate := false
var _storey_gate := false
var _snap_gate := false
var _farfight_gate := false
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
var _mechwave_gate := false
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
## Repair (Docs/Hulls.md 9), "restore" (the middle mouse button) on a ship's or
## station's hull: a tap lays the ghosted brick, held its lost bricks come back.
var restore_tool := RestoreTool.new()
## Bricks left in the repair pouch (RestoreTool.cost), bottom middle.
var brick_count: Label

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


## The planet's gravity is this scene's: off with it, so the next scene (the
## city, the menu) is not pulled toward a freed planet (Gravity.reset).
func _exit_tree() -> void:
	Gravity.reset()

## The gates (`-- --gate=<name>`) live in tools/planet_gates.gd, out of the
## game's own code: made the first time a gate is asked for, never in a plain run.
var _gate_runner_node: Node = null


func _gate_runner() -> Node:
	if _gate_runner_node == null:
		_gate_runner_node = (load("res://tools/planet_gates.gd") as GDScript).new(self)
		add_child(_gate_runner_node)
	return _gate_runner_node



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
	_snap_gate = "--gate=snap" in OS.get_cmdline_user_args()
	_farfight_gate = "--gate=farfight" in OS.get_cmdline_user_args()
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
	_mechwave_gate = "--gate=mechwave" in OS.get_cmdline_user_args()
	_rocks_gate = "--gate=rocks" in OS.get_cmdline_user_args()
	_garrison_gate = "--gate=garrison" in OS.get_cmdline_user_args()
	_seat_gate = "--gate=seat" in OS.get_cmdline_user_args()
	_auto_gate = "--gate=autopilot" in OS.get_cmdline_user_args()
	_hull_gate = "--gate=hull" in OS.get_cmdline_user_args() or _auto_gate
	_belt_gate = "--gate=belt" in OS.get_cmdline_user_args()
	_home_gate = "--gate=home" in OS.get_cmdline_user_args()
	_save_gate = "--gate=save" in OS.get_cmdline_user_args()
	WorldFrame.origin = Vector3.ZERO
	_gate = _gate or _light_gate or _system_gate or _ship_gate or _dock_gate or _worlds_gate or _jump_gate or _debris_gate or _adrift_gate or _falling_gate or _mechwave_gate or _rocks_gate or _garrison_gate or _seat_gate or _hull_gate or _belt_gate or _home_gate or _save_gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate or _squad_gate or _travel_gate or _far_gate or _drive_gate or _trees_gate or _bricks_gate or _damage_gate or _fall_gate or _hits_gate or _topple_gate or _pieces_ai_gate or _storey_gate or _snap_gate or _farfight_gate
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
		PlayerCamera.hands_off = true
		walker.scripted = true
		var tw := get_node_or_null(^"/root/TestWindow")
		if tw != null:
			tw.use_default_settings()
		if _pawn_gate:
			_gate_runner()._run_pawn_gate()
		elif _mech_gate:
			_gate_runner()._run_mech_gate()
		elif _tank_gate:
			_gate_runner()._run_tank_gate()
		elif _soldier_gate:
			_gate_runner()._run_soldier_gate()
		elif _squad_gate:
			_gate_runner()._run_squad_gate()
		elif _trees_gate:
			_gate_runner()._run_trees_gate()
		elif _bricks_gate:
			_gate_runner()._run_bricks_gate()
		elif _damage_gate:
			_gate_runner()._run_damage_gate()
		elif _fall_gate:
			_gate_runner()._run_fall_gate()
		elif _hits_gate:
			_gate_runner()._run_hits_gate()
		elif _topple_gate:
			_gate_runner()._run_topple_gate()
		elif _pieces_ai_gate:
			_gate_runner()._run_pieces_ai_gate()
		elif _storey_gate:
			_gate_runner()._run_storey_gate()
		elif _snap_gate:
			_gate_runner()._run_snap_gate()
		elif _farfight_gate:
			_gate_runner()._run_farfight_gate()
		elif _travel_gate:
			_gate_runner()._run_travel_gate()
		elif _far_gate:
			_gate_runner()._run_far_gate()
		elif _drive_gate:
			_gate_runner()._run_drive_gate()
		elif _light_gate:
			_gate_runner()._run_light_gate()
		elif _system_gate:
			_gate_runner()._run_system_gate()
		elif _ship_gate:
			_gate_runner()._run_ship_gate()
		elif _dock_gate:
			_gate_runner()._run_dock_gate()
		elif _worlds_gate:
			_gate_runner()._run_worlds_gate()
		elif _jump_gate:
			_gate_runner()._run_jump_gate()
		elif _debris_gate:
			_gate_runner()._run_debris_gate()
		elif _adrift_gate:
			_gate_runner()._run_adrift_gate()
		elif _falling_gate:
			_gate_runner()._run_falling_gate()
		elif _mechwave_gate:
			_gate_runner()._run_mechwave_gate()
		elif _rocks_gate:
			_gate_runner()._run_rocks_gate()
		elif _garrison_gate:
			_gate_runner()._run_garrison_gate()
		elif _seat_gate:
			_gate_runner()._run_seat_gate()
		elif _hull_gate:
			_gate_runner()._run_hull_gate()
		elif _home_gate:
			_gate_runner()._run_home_gate()
		elif _save_gate:
			_gate_runner()._run_save_gate()
		elif _belt_gate:
			_gate_runner()._run_belt_gate()
		else:
			_gate_runner()._run_gate()


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


## Each world's buildings told where its AI's fighters are (PlanetBuildings.
## set_fights): bricks where the fight is, not only where the camera is.
const FIGHTS_EVERY := 0.5
var _fights_in := 0.0

func _tell_fights() -> void:
	for b in ai_of:
		var pb: PlanetBuildings = buildings if b == planet else (system.built.get(b) if system != null else null)
		var s: AIServices = ai_of[b]
		if pb == null or s == null:
			continue
		var pts := PackedVector3Array()
		for p in s.pawns:
			if is_instance_valid(p) and p != pawn and p.is_inside_tree() and not p.health.is_dead():
				pts.append(p.feet())
		pb.set_fights(pts)


## The buildings of the world the player is on.
func _buildings_here() -> PlanetBuildings:
	var b := system.buildings_here() if system != null else null
	return b if b != null else buildings


## The ship ran into something at speed: it is blasted there.
func _on_rammed(point: Vector3, speed: float) -> void:
	var shot := {"blast": true, "radius": clampf(speed * 0.15, 1.5, 5.0), "hp": 0}
	# The ship takes it too, nearer the point: its hull is the smaller thing.
	ship.take_ram(point, {"blast": true, "radius": float(shot.radius) * RAM_SHIP_SHARE, "hp": 0})
	if system.station != null and system.station.damage(point, shot):
		return
	_buildings_here().damage(point, shot)


## How much of a ram's blast radius the ship's own hull takes (_on_rammed).
const RAM_SHIP_SHARE := 0.6


## The pawn, its controller, camera, gun and arms, standing at `feet`, looking
## along `facing` (tangent). Built once; placed again after a flight.
func _spawn_player(feet: Vector3, facing: Vector3) -> void:
	cam = PlayerCamera.new()
	cam.name = "Camera"
	cam.capture_mouse = false
	cam.far = SEE_FAR
	cam.add_to_group(PlanetSystem.RIG)
	add_child(cam)
	Flashlight.mount(cam)
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
	kit = PlayerKit.attach(self, player, cam, gun, s, {"scripted": _gate})
	kit.enter(pawn, view)
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
	if key == KEY_H and piloting and system != null:
		# The autopilot (Docs/Hulls.md 7b): on for the planet ahead, or off.
		if ship.autopilot:
			ship.autopilot = false
		else:
			ship.autopilot_on(system)
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
	system.player_pawn = pawn
	var was = pawn.ghost
	var r := GhostHulls.tick(pawn, system.ships, get_world_3d().space)
	if r != 0 or pawn.ghost != was:
		# The ground streams round the real ship, not round the ghost's slot.
		walker.viewer.reparent(cam if pawn.ghost != null else pawn.body, false)
		walker.viewer.position = Vector3.ZERO
		print("[ghost] %s" % ("aboard %s's ghost" % pawn.ghost.data.orbital_name if pawn.ghost != null
				else "off its ghost at %.1f m/s" % pawn.body.velocity.length()))


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
	# A pilot in the seat takes it over from the autopilot.
	ship.autopilot = false
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
	if ship.ref != null and (ship.ghost == null or not ship.riding) and not ship.autopilot:
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
	system.frozen = _gate and not (_system_gate or _dock_gate or _falling_gate or _mechwave_gate)
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
	brick_count = Label.new()
	brick_count.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	brick_count.position = Vector2(-120, -96)
	brick_count.size = Vector2(240, 24)
	brick_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	brick_count.add_theme_font_size_override("font_size", 18)
	brick_count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	brick_count.add_theme_constant_override("outline_size", 5)
	brick_count.visible = false
	layer.add_child(brick_count)
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


## The player stands in one of `sts` (a ship's or station's box): its stores fill
## the repair pouch.
func _aboard_any(sts: Array) -> bool:
	var at := _pawn_real() if pawn != null and on_foot else _anchor()
	for s in sts:
		var st := s as SpaceStation
		if st != null and is_instance_valid(st) and st.bricked and st.holds(at):
			return true
	return false


## Repair, both front ends (RestoreTool): the ghost of the brick a tap would lay
## where the view points on a ship or station, a tap lays it, held it restores.
func _restore_tick(dt: float) -> void:
	var can := InputMap.has_action(&"restore") and not walker.frozen and cam != null
	var holding := can and Input.is_action_pressed(&"restore")
	var sts: Array = system.stations.duplicate()
	for s in system.ships:
		if not sts.has(s):
			sts.append(s)
	var space := get_world_3d().direct_space_state
	var from := cam.global_position if cam != null else Vector3.ZERO
	var dir := -cam.global_basis.z if cam != null else Vector3.FORWARD
	if restore_tool.fx_parent == null:
		restore_tool.fx_parent = self
		restore_tool.cost = RestoreTool.POUCH
	restore_tool.show_ghost(dt, can, from, dir, sts, space, self)
	restore_tool.refill(dt, _aboard_any(sts))
	if brick_count != null:
		# Shown while there is something to mend in view, or the pouch is not full.
		brick_count.visible = can and (not restore_tool.aimed.is_empty() or restore_tool.pressed()
				or restore_tool.cost < RestoreTool.POUCH)
		brick_count.text = "BRICKS  %d / %d" % [restore_tool.cost, RestoreTool.POUCH]
		brick_count.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3) if restore_tool.cost == 0
				else Color(0.75, 0.92, 1.0))
	if not holding and restore_tool.target == null and not restore_tool.pressed():
		return
	restore_tool.tick(dt, holding, from, dir, sts, space)


func _process(delta: float) -> void:
	_fights_in -= delta
	if _fights_in <= 0.0:
		_fights_in = FIGHTS_EVERY
		_tell_fights()
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
		_restore_tick(delta)
		# A ship sitting in its planet's sea: the ocean cut out of its dry cells
		# (Docs/Hulls.md 6).
		HullMasks.update(system.ships, cam_pos)
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
		if not _gate or _pawn_gate or _mech_gate or _tank_gate or _soldier_gate or _squad_gate or _travel_gate or _far_gate or _drive_gate or _trees_gate or _bricks_gate or _damage_gate or _fall_gate or _hits_gate or _topple_gate or _pieces_ai_gate or _storey_gate or _snap_gate or _farfight_gate or _garrison_gate or _seat_gate or _home_gate or _mechwave_gate or _hull_gate or _save_gate or _light_gate:
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
		if gen != null and not piloting and gen.generator_out():
			hud.text += "\nGRAVITY GENERATOR SHOT OUT" + ("" if Gravity.pulls_at(_anchor())
					else "  (nothing pulls; WASD, Space/Ctrl: the suit's thrust)")
		elif gen != null and not piloting:
			hud.text += "\nGRAVITY %s  (G turns it %s)" % ["on" if gen.pulls() else "off", "off" if gen.data.gravity_on else "on"]
		elif system != null and not piloting and not Gravity.pulls_at(_anchor()):
			hud.text += "\nNOTHING PULLS  (WASD, Space/Ctrl: the suit's thrust)"
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


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# ---------------------------------------------------------------------------
# The pawn's gate: the game's own player on local down (Planets.md 11.7).


# ---------------------------------------------------------------------------
# The mech's gate: a titan on local down (Planets.md 11.7).


# ---------------------------------------------------------------------------
# The tank's gate: the player's tank on local down (Planets.md 11.7). Driven by
# its throttle and steer, as VehiclePilot drives it; no AI services.


# ---------------------------------------------------------------------------
# The soldier's gate: an AI body on local down (Planets.md 11.7). Moved the way
# Soldier.walk_toward moves it (a world direction along the ground) and aimed
# the way Soldier aims (AimModel's world angles through Pawn.frame_look). The
# brain's world -- nav, sight, the AI grid -- is still the flat game's.


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


# The travel gate (11.8 N4): a squad of four, on the player's side, ordered to a
# point 200 m out of the town, walks it on the nav net -- across the borders of
# regions made round it as it goes.


# The far gate (11.8): a fight away from the player. Two squads -- one on the
# player's side, one against it -- meet on the town's far side, ~170 m from the
# player and in another region. What they see, hide behind and walk on is their
# own region's (AIServices.focus): the player's region has no ground there.


# The light's gate (Docs/Lighting.md 8): the colour rules on every body of the
# system, the sun's size and brightness by distance, sunset, the fill at night,
# a moon's shadow on its planet, and the ambient boxes in the town's buildings;
# pictures at noon, dawn, night, inside and outside a building.


# The system's gate (11.12): day and night at the spawn, off the home planet
# through a handoff, across to the nearest other body, onto its ground, and
# home again to what was left there. The clock runs.


# The rocks gate (11.12 step 6): a jump to the nearest system with a ringed
# planet, the ring seen from afar, into it, its rocks drawn round the ship, and
# flown at one: stopped by it.


# The debris gate (11.12 step 6): the top of the station cut off with blasts
# through a whole storey; it leaves in one rigid piece, drifting and turning with
# no body; the clock stopped or not, it goes on; out of reach, it is gone.


# The jump gate (11.12 step 5): out of the home planet's shell, the map, a jump
# to the nearest system with a settled world, down on it, off, and home to what
# was left there.


# The seat's gate: how smooth the ship is near a planet; where space begins; out
# of the seat on foot, wherever it is; the map from anywhere.


# The hull's gate: the parked ship generated (ShipBuild, Docs/RoomModules.md
# 7.5) -- its bricks laid with nothing loose, walked into through its airlock,
# flown from the bridge's seat with nothing shaken loose, stood in on its floor.


# The belt's gate: a star's belt in open space, the universe turned round a turned
# ship. The rocks drawn where they stop it; stopped among them is stopped; slow
# flight smooth, a planet's orbit out in float32.


# The save's gate, three runs, each finding what the last left: 1 home's town fought
# in, a wall blown, a tree down, a soldier hurt; 2 all of it as it was, then a jump
# to a world, down, a wall blown there; 3 back on that world, then home by the
# ship, home's wall still blown, and a new universe with nothing in it.


# Home's gate: quiet at the spawn; home's town walked into, the fight on home's own
# AI; wave after wave, each bigger, none on the player's head, and it stops at the most.


# The garrison's gate (11.12 step 7): a jump to a settled world, down by a town,
# out on foot: the world's own AI, the town's squad closing and firing; left and
# come back to, there and still fighting; wiped out, clear; the player down and
# up again; home's AI back on home.


# The worlds' gate (11.12 step 4): down onto a generated world with towns, its
# buildings near, in bricks, solid and hit; trees where its biomes have them;
# off again, its towns still on the sphere from space.


# The docking gate (11.12 step 3b), the clock running: the ship rammed into a
# tower of the town (it stops, the tower is blasted), up to the home planet's
# station, its speed matched, stopped by its hull; the station's bricks shot,
# what came loose gone; left and come back to, as it was left.


# The ship's gate (11.12 step 3): the parked ship in bricks, into its seat, up
# and out of the home planet's shell, a walk on its deck in open space, home
# watched shrinking (its towns on the sphere, then gone), across to the nearest
# other planet, down onto it, out and standing on its ground.


# The drive gate (11.8): an AI tank, crewed, on the player's side, sent 200 m out
# of the town. Its road is the nav net's tank map (AIServices.vehicle_nav on a
# planet: a PlanetNavMap, its own AINav in each region), across the borders.


# The trees gate (11.10): a tank, its tracks, knocks a tree down and drives on; a
# truck's body is stopped by a trunk; walkers and rounds still meet trunks.


# The bricks gate (11.11): near the player the town's buildings are bricks --
# drawn by band, solid, the shell gone -- a building has a way in at the ground,
# and the AI's world has the bricks: the nav net's path goes in through it.


# The damage gate (11.11 D1): the town in bricks, then a rifle's rounds at a wall
# until a brick goes, and a charge at another wall. What the bricks lost is gone
# from the collision, the drawing and the AI's world; the charge's hole is a way in.


# ---------------------------------------------------------------------------
# The falling gate (Planets.md 11.11, D2 step 2): the damage gate's panel --
# a ring cut by cell round a piece of the ground storey's -X wall, which falls
# as one piece -- lifted 8 m the moment it comes loose and let go, as the mech
# gate drops its titan: it lands hard and the landing breaks it -- sheared,
# snapped or cracked across (D2 step 7) -- and all of it lies on the ground.
# (A panel cut free a storey up stays held: its
# wall's bricks reach past the wall onto the floor slab inside.) Then the cap:
# sixty groups shed at once from another building leave at most MAX_MOVING
# moving.


# ---------------------------------------------------------------------------
# The hits gate (Planets.md 11.11, D2 step 3): the damage gate's panel brought
# down and at rest; rifle rounds wear a brick out of it, a charge breaks it
# up, and what is left lies on something.


# ---------------------------------------------------------------------------
# The topple gate (Planets.md 11.11, D2 step 4): the ground storey under 55% of
# a building's footprint cut away (by cell, as the city's stress pass blasts
# it); off balance, it goes over whole, falls, and lies on the ground; it is no
# building any more.


# ---------------------------------------------------------------------------
# The pieces' AI gate (Planets.md 11.11, D2 step 5): a building toppled across
# the open ground (as the topple gate); at rest, its biggest piece is bricks to
# the AI -- solid in its world, cover across it -- and a path from one side of
# it to the other goes round it.


# ---------------------------------------------------------------------------
# The storey gate (Planets.md 11.11, D2 step 6): what is left of a storey has to
# carry what is above it (PlanetBuildings._storey_fail, the city's
# _gravity_fail). A tower's first-floor walls cut away (by cell) but for one
# corner: what is above is off the edge of it -- TIP -- and goes over as one
# piece. Another tower made too weak for its own weight (as the city's collapse
# probe does it): a storey is crushed -- CRUSH -- and what is above comes down.
# Every piece ends at rest. Untouched buildings are nowhere near failing.


# ---------------------------------------------------------------------------
# The snap gate (Planets.md 11.11, D2 step 7): where a landing snaps a piece,
# as the city's (IslandManager._snap_across): along its grid's Y at the weakest
# seam in reach or a storey line; across X or Z, a crack along the bond -- never
# a band torn into gravel. A wall panel dropped 8 m (as the fall gate) is long
# across; a toppled building (as the topple gate) is long up its own Y.


# ---------------------------------------------------------------------------
# The far-fight gate (Planets.md 11.11, bricks where the fight is): a soldier by
# a building out of the camera's reach makes it bricks -- solid, the AI's -- and
# a charge at another far building, a shell then, waits and lands once it is
# bricks. The soldier gone, both are freed; the hit one keeps its damage.

