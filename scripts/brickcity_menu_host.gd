class_name BrickcityMenuHost
extends MenuHost
## Printed Brick City's side of the menu seam (`menu/core/MenuHost.gd`). The `menu/` folder is
## Ceramic Edge's front end copied whole (Docs/Reference/ceramicedge.md section 8); everything
## game-shaped it needs lives here, so that folder stays a straight copy.
##
## Wired by the project setting `menu/host_script`.
##
## Settings reach the game as STATIC fields on the classes that use them (PlayerView.hfov,
## DebugCamera.look_mult, PlayerController.toggle_sprint...), not by finding nodes: a setting
## changed while nobody is on foot still holds when somebody is, and a probe that never loads
## the menu runs on the defaults.

## The settings SCRIPT, not the autoload of the same name: `truthy` is static.
const MENU_SETTINGS := preload("res://menu/core/MenuSettings.gd")
const CITY := "res://scenes/city.tscn"
const BIG_CITY := "res://scenes/big_city.tscn"
const ARENA := "res://scenes/combat_arena.tscn"
const WORKSHOP := "res://scenes/workshop.tscn"
## The scenes the pause menu opens over: the city's, which owns Escape for nothing else. The
## workshop and the terrain tools have their own Escape (menus, cancelling a grab).
const CITY_SCRIPT := "res://scripts/city_scene.gd"


func _game_title() -> String:
	return "PRINTED BRICK CITY"


func _game_subtitle() -> String:
	return "Everything is bricks. Everything breaks."


func _game_version() -> String:
	var v := String(ProjectSettings.get_setting("application/config/version", ""))
	return v if v != "" else "dev build"


# =====================================================================
# Main menu
# =====================================================================
func _main_menu_entries() -> Array:
	return [
		{"label": "Combat Arena", "primary": true,
			"tooltip": "Waves of soldiers in and around a building.",
			"action": func() -> void: _goto(ARENA)},
		{"label": "City", "tooltip": "A block of city to walk, fight and knock down.",
			"action": func() -> void: _goto(CITY)},
		{"label": "Big City", "action": func() -> void: _goto(BIG_CITY)},
		{"label": "Workshop", "tooltip": "Build with bricks.",
			"action": func() -> void: _goto(WORKSHOP)},
	]


func _goto(path: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.paused = false
		tree.change_scene_to_file(path)


# =====================================================================
# Pause menu
# =====================================================================
func _pause_allowed() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return false
	var scr := tree.current_scene.get_script() as Script
	if scr == null or scr.resource_path != CITY_SCRIPT:
		return false
	# Not over a scripted pass: CityScene.pause_allowed says why.
	return tree.current_scene.pause_allowed()


func _pause_opened() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Back to the game: the city's camera takes the mouse again, the way a click would.
func _pause_closed() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	var cam := tree.current_scene.get("camera") as DebugCamera
	if cam != null and cam.capture_mouse:
		cam._set_captured(true)


## Leaving for the main menu. The city's slow motion (its O key) is the engine's
## own time scale, which outlives the scene: the menu and whatever was started
## from it next ran slow.
func _quit_to_main_menu() -> void:
	Engine.time_scale = 1.0
	super()


# =====================================================================
# Settings the game owns
# =====================================================================
func _apply_setting(id: StringName, value: Variant) -> void:
	match id:
		&"fov":
			PlayerView.hfov = float(value)
		&"mouse_sensitivity":
			DebugCamera.look_mult = float(value)
		&"ads_sensitivity":
			PlayerView.ads_sensitivity = float(value)
		&"invert_y":
			DebugCamera.invert_y = MENU_SETTINGS.truthy(value)
		&"toggle_sprint":
			PlayerController.toggle_sprint = MENU_SETTINGS.truthy(value)
		&"toggle_aim":
			PlayerController.toggle_aim = MENU_SETTINGS.truthy(value)
		&"toggle_crouch":
			PlayerController.toggle_crouch = MENU_SETTINGS.truthy(value)
		&"screen_shake":
			PlayerView.shake_scale = float(value)
		&"reduce_motion":
			PlayerView.reduce_motion = MENU_SETTINGS.truthy(value)
		&"hud_opacity":
			PlayerHud.opacity = float(value)
		&"subtitles":
			CalloutHud.shown = MENU_SETTINGS.truthy(value)


## Names for the rebinding list.
func _action_label(action: StringName) -> String:
	const NAMES := {
		"move_forward": "Move Forward", "move_back": "Move Back",
		"move_left": "Strafe Left", "move_right": "Strafe Right",
		"sprint": "Sprint", "jump": "Jump (hold: higher) / Climb",
		"crouch": "Crouch / Slide / Let Go", "grapple": "Grapple (hold)",
		"fire": "Fire", "aim": "Aim Down Sights", "reload": "Reload", "pause": "Pause",
	}
	return String(NAMES.get(String(action), ""))
