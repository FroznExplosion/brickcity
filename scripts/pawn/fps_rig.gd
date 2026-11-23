class_name FpsRig
extends RefCounted

## The player's first-person rig, on foot or flying: the planet's own
## (scripts/planet/planet_scene.gd), shared so the mine world (Docs/MineWorld.md
## 7) is the same controller rather than a copy of it.
##
##   on foot   the game's Pawn, its PawnMoves, PlayerController, PlayerCamera,
##             a GunController and PlayerView (gun and arms);
##   flying    PlanetWalker with its fly mode (wheel for speed, Space up, Ctrl
##             down, Shift fast). F toggles in both scenes.
##
## Up comes from Gravity.up_at, so on a planet it is radial and on flat ground
## (Gravity.planet null) it is +Y; nothing here knows which.

## The pawn, controller, camera, gun and arms, standing at `feet`. Returns
## {"cam", "pawn", "player", "gun", "view"}; the caller adds the kit (it needs
## the scene's AI services) and turns the camera (`face`).
## The player's first gun, made ahead (`prewarm`, while a scene loads): its parts'
## library alone is 45-110 ms, and it was made in the frame the player appeared
## (Docs/PlanetCost.md 10). `make_player` takes it, or makes it then.
static var _gun_ahead: GunGenerator.Result = null


static func prewarm() -> void:
	if _gun_ahead == null:
		_gun_ahead = _first_gun()


static func _first_gun() -> GunGenerator.Result:
	return GunGenerator.generate(GunPlaceholderParts.build_library(), 7, WeaponClass.builtin(&"rifle"), 1)


static func make_player(parent: Node3D, feet: Vector3, far: float, scripted: bool) -> Dictionary:
	var cam := PlayerCamera.new()
	cam.name = "Camera"
	cam.capture_mouse = false
	cam.far = far
	parent.add_child(cam)
	Flashlight.mount(cam)
	var pawn := Pawn.spawn(parent, feet, 0)
	pawn.moves = PawnMoves.new(pawn)
	var player := PlayerController.new()
	player.name = "Player"
	player.drive_uncaptured = scripted
	parent.add_child(player)
	player.possess(pawn, cam)
	var gun := GunController.new()
	gun.name = "Gun"
	gun.rng = RandomNumberGenerator.new()
	gun.rng.seed = 0xC0FFEE
	gun.aim = cam
	parent.add_child(gun)
	var view := PlayerView.new()
	view.name = "PlayerView"
	parent.add_child(view)
	view.setup(cam, pawn, gun)
	player.view = view
	var made: GunGenerator.Result = _gun_ahead if _gun_ahead != null else _first_gun()
	_gun_ahead = null
	var gi := GunInstance.from_result(made)
	gun.equip(gi)
	view.hold(gi)
	pawn.gun = gun
	gun.exclude = [pawn.body.get_rid()] as Array[RID]
	return {"cam": cam, "pawn": pawn, "player": player, "gun": gun, "view": view}


## Turn the camera, in the pawn's frame, to look along `facing`.
static func face(cam: PlayerCamera, pawn: Pawn, facing: Vector3) -> void:
	var fr := pawn.body.global_transform.basis.orthonormalized()
	cam.set_frame(fr)
	var local := fr.inverse() * facing
	cam.global_transform.basis = fr * Basis.from_euler(Vector3(0.0, atan2(-local.x, -local.z), 0.0))


## On foot at `feet` (on true) or flying from where the pawn stands (false).
## `kit` may be null.
##
## `keep_view` (the mine world): flying keeps the pawn's camera as the one
## drawn, with the arms and gun on it, and the scene moves it with the walker
## every frame (`follow_flight`). Without it the walker's own camera takes
## over and the arms stay where the pawn was left (the planet, as it was).
static func switch_mode(on: bool, feet: Vector3, walker: PlanetWalker, pawn: Pawn,
		player: PlayerController, cam: PlayerCamera, view: PlayerView, kit: PlayerKit,
		keep_view := false) -> void:
	# The pawn left behind while flying is not there to be shot.
	if kit != null:
		kit.present(on)
	if on:
		var fwd := -walker.camera.global_transform.basis.z
		pawn.body.process_mode = Node.PROCESS_MODE_INHERIT
		pawn.place(feet + Gravity.up_at(feet) * 0.05)
		if not player.is_possessing():
			player.possess(pawn, cam)
		cam.current = true
		face(cam, pawn, Gravity.flat(fwd, Gravity.up_at(feet)).normalized())
		walker.process_mode = Node.PROCESS_MODE_DISABLED
		walker.collision_layer = 0
		walker.collision_mask = 0
		view.rig.visible = true
	else:
		var at := pawn.feet() + pawn.up * 0.3
		walker.process_mode = Node.PROCESS_MODE_INHERIT
		walker.collision_layer = 1
		walker.collision_mask = 1 | Layers.STRUCTURE
		walker.place(at, -cam.global_transform.basis.z)
		walker.flying = true
		walker.frozen = false
		player.release()
		if keep_view:
			follow_flight(cam, walker)
			cam.current = true
		else:
			walker.camera.current = true
			view.rig.visible = false


## Flying with `keep_view`: the pawn's camera where the walker's is.
static func follow_flight(cam: PlayerCamera, walker: PlanetWalker) -> void:
	cam.global_transform = walker.camera.get_global_transform_interpolated()
