class_name MenuHost
extends RefCounted
## THE SEAM. Every point where the menu module needs something only the surrounding game can
## provide goes through here — what "Continue" resumes, whether the pause key is allowed right
## now, which extra tabs Options grows, what a game-specific setting does when it changes.
##
## Why it exists: GDScript resolves `class_name` at PARSE time. A direct reference to a missing
## game class doesn't degrade gracefully, it fails to compile — so one absent script takes the
## whole menu down. Routing those references through one overridable object means `menu/` parses
## and runs in a project that has none of them; the main menu just shows fewer buttons.
##
## To wire the menus into a game, subclass this, override the `_`-prefixed methods you care
## about, and point the project setting `menu/host_script` at your script:
##
##     # res://game/MyMenuHost.gd
##     extends MenuHost
##     func _game_title() -> String: return "My Game"
##     func _play_pressed() -> void: get_tree().change_scene_to_file("res://game/Level1.tscn")
##
## Or assign it in code before the menus load: `MenuHost.set_host(MyMenuHost.new())`.
##
## Every method below is a no-op / neutral default, so an unimplemented hook is silence, never a
## crash. The base class IS the null host — a project that sets nothing gets a working main menu
## with Options and Quit, a working pause menu, and the full engine-level settings set.

## Project setting naming the host script. Absent or unset = the no-op default.
const HOST_SETTING := "menu/host_script"

static var _host: MenuHost = null


## The active host, discovered on first use. Never null.
static func host() -> MenuHost:
	if _host == null:
		_host = _discover()
	return _host


## Install a host explicitly (tests, or a game that would rather not use a project setting).
##
## Passing null RE-DISCOVERS on the next call — it does not install the no-op host. To get the
## null host, install one: `MenuHost.set_host(MenuHost.new())` — the base class IS the null host.
static func set_host(h: MenuHost) -> void:
	_host = h


static func _discover() -> MenuHost:
	var path := String(ProjectSettings.get_setting(HOST_SETTING, ""))
	if path != "" and ResourceLoader.exists(path):
		var scr := load(path)
		if scr is GDScript:
			var inst = (scr as GDScript).new()
			if inst is MenuHost:
				return inst
			push_warning("MenuHost: '%s' does not extend MenuHost — using the no-op host." % path)
	return MenuHost.new()


# =====================================================================
# Static forwarders — what the rest of the module calls. Overriding happens on the `_` methods.
# =====================================================================

static func game_title() -> String: return host()._game_title()
static func game_subtitle() -> String: return host()._game_subtitle()
static func game_version() -> String: return host()._game_version()

static func main_menu_scene() -> String: return host()._main_menu_scene()
static func main_menu_entries() -> Array: return host()._main_menu_entries()
static func pause_menu_entries() -> Array: return host()._pause_menu_entries()

static func has_continue() -> bool: return host()._has_continue()
static func continue_game() -> void: host()._continue_game()
static func play_pressed() -> void: host()._play_pressed()

static func pause_allowed() -> bool: return host()._pause_allowed()
static func pause_opened() -> void: host()._pause_opened()
static func pause_closed() -> void: host()._pause_closed()
static func quit_to_main_menu() -> void: host()._quit_to_main_menu()

static func apply_setting(id: StringName, value: Variant) -> void: host()._apply_setting(id, value)
static func setting_defs() -> Array: return host()._setting_defs()
static func extra_option_tabs() -> Array: return host()._extra_option_tabs()
static func action_label(action: StringName) -> String: return host()._action_label(action)
static func hidden_actions() -> PackedStringArray: return host()._hidden_actions()


# =====================================================================
# Overridable hooks — the null host's answers
# =====================================================================

## Big title on the main menu. Defaults to the project name.
func _game_title() -> String:
	return String(ProjectSettings.get_setting("application/config/name", "Game"))

## Small line under the title. Empty hides it.
func _game_subtitle() -> String:
	return ""

## Shown bottom-right on the main menu.
func _game_version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", ""))

## Where "Quit to Main Menu" and the module's own back-to-menu route go.
func _main_menu_scene() -> String:
	return "res://menu/ui/MainMenu.tscn"

## Extra buttons for the main menu, ABOVE Options/Quit. Each entry is a Dictionary:
##   { "id": StringName, "label": String, "tooltip": String, "disabled": bool,
##     "action": Callable, "primary": bool }
## `action` takes no arguments. `primary` styles it as the highlighted call-to-action.
func _main_menu_entries() -> Array:
	return []

## Extra buttons for the pause menu, between Resume and Options. Same Dictionary shape.
func _pause_menu_entries() -> Array:
	return []

## True when there is a run to resume — drives the main menu's Continue button.
func _has_continue() -> bool:
	return false

func _continue_game() -> void:
	pass

## What the main "Play" button does. The null host does nothing, so the module hides the button
## unless the host also supplies entries.
func _play_pressed() -> void:
	pass

## False while the pause key must be ignored — a level editor with its own Esc panel, a cutscene,
## an already-open modal. The module never pauses over the main menu regardless.
func _pause_allowed() -> bool:
	return true

## The pause menu just opened / closed. Games use these to free and re-capture the mouse and to
## suspend their own input handling.
func _pause_opened() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _pause_closed() -> void:
	pass

func _quit_to_main_menu() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.paused = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		tree.change_scene_to_file(_main_menu_scene())

## A setting the module does not own changed. Called on load and on every subsequent change, so
## a host can treat it as "make the world match this value" without tracking deltas.
func _apply_setting(_id: StringName, _value: Variant) -> void:
	pass

## Game-specific settings to append to the built-in table. Same Dictionary shape as
## `MenuSettings.DEFS` — see that file's header. They persist and appear in Options like any
## other; `_apply_setting` is what makes them do something.
func _setting_defs() -> Array:
	return []

## Extra Options tabs. Each entry: { "title": String, "build": Callable(parent: VBoxContainer) }.
## The builder is handed a container already inside the fit-safe scroll body.
func _extra_option_tabs() -> Array:
	return []

## Human-readable name for an input action in the rebinding list. Empty = auto-prettify the
## action name ("move_forward" -> "Move Forward").
func _action_label(_action: StringName) -> String:
	return ""

## Actions to keep OUT of the rebinding list even though they are not `ui_*` — debug toggles,
## internal aliases.
func _hidden_actions() -> PackedStringArray:
	return PackedStringArray()
