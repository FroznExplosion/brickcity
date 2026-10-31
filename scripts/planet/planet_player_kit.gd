class_name PlanetPlayerKit
extends Node3D

## The player's kit on the planet, as the firefight has it (CityScene._enter_pawn,
## _fps_on, _player_hud): the HUD, the arsenal -- four slots and ordnance, gun
## pickups, grenades, skills, the saved kit and level --, aim assist, hit
## feedback, and the callouts and aggro meter of the AI it fights. Not here:
## the brick world's melee context, the mech call, the workbench (the planet
## has no bricks or safehouses yet).
##
## A Node3D of its own, so CombatFeedback, which wants a host with a `camera`,
## has one without the planet scene growing a field for it.

const TestWindowScript := preload("res://scripts/test_window.gd")

var camera: Camera3D
var player: PlayerController
var pawn: Pawn
var gun: GunController
var view: PlayerView
var services: AIServices
var arsenal: PlayerArsenal
var aim_assist: AimAssist
var hud: PlayerHud
var feedback: CombatFeedback
var _callouts: CalloutHud
var _listener: Callouts.Listener
var _meter: AggroMeter
## The pawn is in the fight: on foot, not left behind by the one flying.
var _present := true
## A pass or a test window: nothing is loaded from, or saved to, the player's save.
var scripted := false


## The kit round `p_player`'s pawn, its camera, gun and view, under `parent`;
## `s` is the AI the player fights beside and against.
static func attach(parent: Node3D, p_player: PlayerController, p_cam: Camera3D, p_gun: GunController,
		p_view: PlayerView, s: AIServices, p_scripted: bool) -> PlanetPlayerKit:
	var k := PlanetPlayerKit.new()
	k.name = "PlayerKit"
	k.camera = p_cam
	k.player = p_player
	k.pawn = p_player.pawn
	k.gun = p_gun
	k.view = p_view
	k.services = s
	k.scripted = p_scripted or TestWindowScript.is_test_window()
	parent.add_child(k)
	k._build()
	return k


func _build() -> void:
	pawn.melee_tier = 1
	# After the gun: add_pawn arms it, so its rounds suppress, are heard and earn
	# aggro (AIServices).
	services.add_pawn(pawn)
	gun.team = pawn.team
	hud = PlayerHud.new()
	hud.name = "PlayerHud"
	add_child(hud)
	hud.setup(pawn, gun, view)
	feedback = CombatFeedback.new()
	feedback.name = "Feedback"
	add_child(feedback)
	feedback.setup(self)
	gun.fired.connect(feedback.on_player_shot)
	pawn.meleed.connect(feedback.on_player_shot)
	gun.side_hit.connect(feedback.on_player_shot)
	aim_assist = AimAssist.new()
	aim_assist.setup(camera, gun, player, services)
	add_child(aim_assist)
	if camera is DebugCamera:
		(camera as DebugCamera).assist = aim_assist
	gun.assist = aim_assist
	_listener = services.callouts.listen(camera, 0, pawn)
	_callouts = CalloutHud.new()
	_callouts.name = "Callouts"
	_callouts.setup(services.callouts, _listener)
	add_child(_callouts)
	var aggro_layer := CanvasLayer.new()
	aggro_layer.name = "Aggro"
	aggro_layer.layer = 5
	_meter = AggroMeter.new()
	_meter.table = services.aggro_of(1)
	_meter.position = Vector2(20.0, 180.0)
	aggro_layer.add_child(_meter)
	add_child(aggro_layer)
	arsenal = PlayerArsenal.new()
	arsenal.name = "Arsenal"
	add_child(arsenal)
	if not scripted:
		player.progress.take(CharacterSave.load_from().progress_dict())
		player.progress.changed.connect(_save)
	arsenal.setup(player, gun, view, services, GunPlaceholderParts.build_library(), get_parent() as Node3D, 1)
	if not scripted:
		arsenal.restore(CharacterSave.load_from().loadout)
		arsenal.kit_changed.connect(_save)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x1007
	arsenal.fill_default(rng)


## The player has come to the world `s` is the AI of (Docs/Planets.md 11.12 step 7).
func use_services(s: AIServices) -> void:
	if s == services:
		return
	services.pawns.erase(pawn)
	for c in gun.fired.get_connections():
		if (c.callable as Callable).get_object() == services:
			gun.fired.disconnect(c.callable)
	services.callouts.listeners.erase(_listener)
	services = s
	if _present:
		s.add_pawn(pawn)
	aim_assist.services = s
	arsenal.services = s
	_listener = s.callouts.listen(camera, 0, pawn)
	_callouts.setup(s.callouts, _listener)
	_meter.table = s.aggro_of(1)


## In the fight or out of it: nobody hunts the pawn left behind by one flying.
func present(on: bool) -> void:
	_present = on
	if on:
		services.add_pawn(pawn)
	else:
		services.pawns.erase(pawn)


## The level and the kit into the character save, as the firefight keeps them.
func _save() -> void:
	var s := CharacterSave.load_from()
	s.take_progress(player.progress)
	if not arsenal.loadout.all_guns().is_empty():
		s.loadout = arsenal.kit_dict()
	s.save()
