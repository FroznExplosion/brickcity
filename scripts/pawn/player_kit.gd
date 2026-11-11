class_name PlayerKit
extends Node3D

## The player's kit round their pawn, the same in every scene that has one (the
## city, the planet): the HUD, the arsenal -- four slots and ordnance, gun
## pickups, grenades, skills, the saved kit and level --, aim assist, hit
## feedback, and the callouts and aggro meter of the AI it fights.
##
## The scene keeps what is its own: the camera, the pawn, the controller, the
## gun and the view it builds (and the city's free camera, workbench, mech call
## and melee context). It attaches a kit once, then tells it when the player
## takes a pawn (`enter`) and leaves it (`leave`) -- the city's V, or the planet
## once at the start.
##
## A Node3D of its own, so CombatFeedback, which wants a host with a `camera`,
## has one without the scene growing a field for it.

const TestWindowScript := preload("res://scripts/core/test_window.gd")

var camera: Camera3D
var player: PlayerController
var pawn: Pawn
var gun: GunController
var view: PlayerView
var services: AIServices
var arsenal: PlayerArsenal
var aim_assist: AimAssist
var hud: PlayerHud
## Our own hit feedback; null while the scene gives one of its own (`enter`).
var feedback: CombatFeedback
var _callouts: CalloutHud
var _listener: Callouts.Listener
var _meter: AggroMeter
var _aggro_layer: CanvasLayer
## The pawn is in the fight: on foot, not left behind by the one flying.
var _present := true
## A pass or a test window: nothing is loaded from, or saved to, the player's save.
var scripted := false

## Set before the first `enter` (attach's `opts` does it).
## The guns the arsenal rolls and builds from.
var library: GunPartLibrary
## Where the arsenal drops and finds guns in the world.
var world: Node3D
## The aggro meter's place on screen, under the scene's own status lines.
var meter_at := Vector2(20.0, 214.0)
## The arsenal's default fill is drawn from this (seeded 0x1007 when the arsenal
## is made); a scene that rolls its loot from the same stream passes its own.
var rng: RandomNumberGenerator
## Handed to the arsenal: boarding a vehicle on Use, the backpack's mech page.
var board: Callable
var mech_screen: Node


## A kit for `p_player` -- its camera, gun -- under `parent`; `s` is the AI the
## player fights beside and against. `opts`: scripted, library, world, meter_at,
## rng, board, mech_screen (each as the field of that name).
static func attach(parent: Node3D, p_player: PlayerController, p_cam: Camera3D, p_gun: GunController,
		s: AIServices, opts := {}) -> PlayerKit:
	var k := PlayerKit.new()
	k.name = "PlayerKit"
	k.camera = p_cam
	k.player = p_player
	k.gun = p_gun
	k.services = s
	k.scripted = bool(opts.get("scripted", false)) or TestWindowScript.is_test_window()
	k.library = opts.get("library", null)
	if k.library == null:
		k.library = GunPlaceholderParts.build_library()
	k.world = opts.get("world", parent)
	k.meter_at = opts.get("meter_at", k.meter_at)
	k.rng = opts.get("rng", null)
	if k.rng == null:
		k.rng = RandomNumberGenerator.new()
	k.board = opts.get("board", Callable())
	k.mech_screen = opts.get("mech_screen", null)
	parent.add_child(k)
	return k


## The player has taken `p_pawn`, seen through `p_view`: everything round it up.
## `tier` is the fight's (melee, the arsenal's rolls). `shared_feedback`, if
## given, is the scene's own hit feedback (the city's arena has one): ours is
## not made and the pawn's hits mark there.
func enter(p_pawn: Pawn, p_view: PlayerView, tier := 1, shared_feedback: CombatFeedback = null) -> void:
	pawn = p_pawn
	view = p_view
	pawn.melee_tier = tier
	# After the gun: add_pawn arms it, so its rounds suppress, are heard and earn
	# aggro (AIServices).
	if _present:
		services.add_pawn(pawn)
	gun.team = pawn.team
	if aim_assist == null:
		aim_assist = AimAssist.new()
		aim_assist.setup(camera, gun, player, services)
		add_child(aim_assist)
	if camera is PlayerCamera:
		(camera as PlayerCamera).assist = aim_assist
	gun.assist = aim_assist
	_fight_hud()
	if hud == null:
		hud = PlayerHud.new()
		hud.name = "PlayerHud"
		add_child(hud)
		hud.setup(pawn, gun, view)
	if feedback == null and shared_feedback == null:
		feedback = CombatFeedback.new()
		feedback.name = "Feedback"
		add_child(feedback)
		feedback.setup(self)
		gun.fired.connect(feedback.on_player_shot)
	# A melee that lands marks like a round (its info is the same shape), and so
	# does a splash or a ricochet of a modifier (GunController.side_hit).
	var fb: CombatFeedback = shared_feedback if shared_feedback != null else feedback
	if fb != null and not pawn.meleed.is_connected(fb.on_player_shot):
		pawn.meleed.connect(fb.on_player_shot)
	if fb != null and not gun.side_hit.is_connected(fb.on_player_shot):
		gun.side_hit.connect(fb.on_player_shot)
	var first := arsenal == null
	if first:
		arsenal = PlayerArsenal.new()
		arsenal.name = "Arsenal"
		arsenal.board = board
		arsenal.mech_screen = mech_screen
		add_child(arsenal)
		rng.seed = 0x1007
		if not scripted:
			player.progress.take(CharacterSave.load_from().progress_dict())
			player.progress.changed.connect(_save)
	arsenal.setup(player, gun, view, services, library, world, tier)
	if first and not scripted:
		arsenal.restore(CharacterSave.load_from().loadout)
		arsenal.kit_changed.connect(_save)
	arsenal.fill_default(rng)


## The player has let go of the pawn (the city's V back to the free camera): its
## HUD down, the meter hidden. The arsenal, aim assist and callouts stay for the
## next pawn.
func leave() -> void:
	if hud != null:
		hud.queue_free()
		hud = null
	if _aggro_layer != null:
		_aggro_layer.visible = false


## What the player is shown of the fight (AI.md 6.5, 8): the callouts it can hear
## -- markers over the speakers it can see, over friendlies always -- and the
## enemy's aggro meter. Heard from the camera, which is the player's eye.
func _fight_hud() -> void:
	if _callouts == null:
		_listener = services.callouts.listen(camera, 0, pawn)
		_callouts = CalloutHud.new()
		_callouts.name = "Callouts"
		_callouts.setup(services.callouts, _listener)
		add_child(_callouts)
		_aggro_layer = CanvasLayer.new()
		_aggro_layer.name = "Aggro"
		_aggro_layer.layer = 5
		_meter = AggroMeter.new()
		_meter.table = services.aggro_of(1)
		_meter.position = meter_at
		_aggro_layer.add_child(_meter)
		add_child(_aggro_layer)
	_listener.pawn = pawn
	_aggro_layer.visible = true


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


## The level and the kit into the character save.
func _save() -> void:
	var s := CharacterSave.load_from()
	s.take_progress(player.progress)
	if arsenal != null and not arsenal.loadout.all_guns().is_empty():
		s.loadout = arsenal.kit_dict()
	s.save()
