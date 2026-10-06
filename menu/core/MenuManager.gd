extends Node
## Autoload `MenuManager` — owns pausing. The pause menu is a panel; this is the thing that
## decides it may open, freezes the tree, remembers the mouse mode, and puts it all back.
##
## Separating them is what makes the module portable in practice: a game with a different pause
## trigger (a cutscene system, a networked session that must not stop the world) replaces or
## subclasses this file and keeps the entire UI.
##
## Pause is deliberately NOT bound to `ui_cancel` alone. `ui_cancel` is also Back inside every
## menu, so a project where they are the same action gets an Escape that closes a submenu *and*
## pauses. The manager therefore prefers a dedicated `pause` action and only falls back to
## `ui_cancel` when the project has none.

const PAUSE_SCENE := "res://menu/ui/PauseMenu.tscn"
const PAUSE_ACTION := &"pause"

signal pause_opened
signal pause_closed

var _layer: CanvasLayer = null
var _menu: Node = null
var _prev_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
var _was_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return is_instance_valid(_menu)


func _unhandled_input(event: InputEvent) -> void:
	if _pause_pressed(event):
		toggle_pause()
		get_viewport().set_input_as_handled()


func _pause_pressed(event: InputEvent) -> bool:
	if InputMap.has_action(PAUSE_ACTION):
		return event.is_action_pressed(PAUSE_ACTION)
	return event.is_action_pressed("ui_cancel")


func toggle_pause() -> void:
	if is_open():
		close_pause()
	else:
		open_pause()


## Open unless something says otherwise. Returns true if the menu is now up.
func open_pause() -> bool:
	if is_open() or not can_pause():
		return false
	_prev_mouse_mode = Input.mouse_mode
	_was_paused = get_tree().paused

	_layer = CanvasLayer.new()
	_layer.name = "PauseMenuLayer"
	_layer.layer = 90
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child(_layer)

	_menu = _instantiate_pause_menu()
	_layer.add_child(_menu)

	get_tree().paused = true
	MenuHost.pause_opened()
	pause_opened.emit()
	return true


func close_pause() -> void:
	if not is_open():
		return
	dismiss()
	var tree := get_tree()
	if tree != null:
		tree.paused = _was_paused
	Input.mouse_mode = _prev_mouse_mode
	MenuHost.pause_closed()
	pause_closed.emit()


## Tear the menu down WITHOUT restoring the previous mouse mode or pause state — used when the
## thing behind it is going away anyway (quit to menu, level reload).
func dismiss() -> void:
	if is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_menu = null


func quit_to_main_menu() -> void:
	dismiss()
	var tree := get_tree()
	if tree != null:
		tree.paused = false
	MenuHost.quit_to_main_menu()
	pause_closed.emit()


## False when pausing would be wrong: already inside a menu scene, no scene yet, or the game
## says so (level editor with its own Escape panel, cutscene, results screen).
func can_pause() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	var scene := tree.current_scene
	if scene == null:
		return false
	if scene is MenuScreen:
		return false
	return MenuHost.pause_allowed()


func _instantiate_pause_menu() -> Node:
	if ResourceLoader.exists(PAUSE_SCENE):
		var ps := load(PAUSE_SCENE) as PackedScene
		if ps != null:
			return ps.instantiate()
	# Scene missing (a port that copied only the scripts) — the script alone is enough.
	var scr := load("res://menu/ui/PauseMenu.gd") as GDScript
	return scr.new()


## Open the full options screen over whatever is on screen, without pausing. For a settings
## button on a results screen or a lobby.
func open_options_overlay(parent: Node = null) -> Node:
	var host: Node = parent
	if host == null:
		var tree := get_tree()
		host = tree.current_scene if tree != null else null
	if host == null:
		return null
	var scr := load("res://menu/ui/OptionsMenu.gd")
	var o := scr.new() as Control
	o.set("overlay_mode", true)
	o.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(o)
	return o


# =====================================================================
# Auto-pause on focus loss
# =====================================================================
func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_OUT:
		return
	var s := get_node_or_null("/root/MenuSettings")
	if s == null or not s.get_bool(&"pause_on_focus_loss"):
		return
	open_pause()
