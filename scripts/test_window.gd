extends Node

## A window nobody is at: a test run, on a machine somebody is using.
##
## A gate or a windowed probe needs a real renderer, so it needs a window --
## and that window used to open in the middle of the screen (MenuSettings
## centres it), take the keyboard, and take the mouse the first time anything
## clicked in it, the pass's own synthetic clicks included. The user's way out
## was Escape, which then paused the pass (user, 2026-10-06).
##
## A test run says it is one with a setting, not an argument: a worktree that
## runs tests has an `override.cfg` beside its project.godot (a copy of
## tools/test_window.cfg; CLAUDE.md, "Testing"; never in the main folder) with
##
##     [display]
##     window/size/no_focus=true
##
## which is the one thing that has to be true BEFORE the window exists -- a
## window made without it has already taken the keyboard by the time any
## script runs.
##
## The same file deals with the three seconds the engine takes to start, in
## which no script runs either: it makes the window as small as a bordered
## window goes (a title bar, 136 x 55) and asks for it far off the screen,
## which the engine answers by putting it in the bottom right corner, a third
## showing. That is as out of the way as a window can be MADE. Measured
## (2026-10-06), the alternatives are worse:
##
##   * made off the screen: not allowed -- the engine pulls it back on;
##   * made minimised: it takes the keyboard;
##   * borderless (which could be 16 x 16): it takes the keyboard, no_focus
##     or not;
##   * started hidden by whoever launches it: it is shown regardless.
##
## Everything else follows from the one setting, here, for every scene:
##
##   * the window is parked off the screen, and put back there whenever
##     something moves it (MenuSettings, a gate changing its size). It is
##     still drawn: a parked window is not a minimised one;
##   * it is never fullscreen, whatever the user's own settings say;
##   * the mouse is never captured (DebugCamera.hands_off).
##
## Without the setting this does nothing at all.

## Where a test window is kept. Past any arrangement of monitors; Windows
## takes window coordinates up to 32767.
const PARK := Vector2i(24000, 24000)
## What a test window draws at: the size every scene pass has been run and
## photographed at (`--resolution 1280x720`, which a test worktree no longer
## passes -- the window has to be MADE a speck).
const SIZE := Vector2i(1280, 720)

var _parked := false
var _sizing := 8


static func is_test_window() -> bool:
	return DisplayServer.get_name() != "headless" \
			and DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not is_test_window():
		set_process(false)
		return
	_parked = true
	DebugCamera.hands_off = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_park()
	# And straight after MenuSettings has had its turn with the window: it puts
	# it on the user's monitor, at the user's resolution, in the middle, from a
	# deferred call queued just before this one (it is the autoload before this).
	# Left to _process, that was the whole first frame with a full-size window
	# on the screen -- a third of a second in the city.
	use_default_settings.call_deferred()
	_park.call_deferred()
	print("[test window] off the screen, no focus, no mouse (override.cfg: display/window/size/no_focus)")


var _defaulted := false


## Run on the menu's DEFAULT settings, not the user's. In memory only: their
## settings.cfg is not written (MenuSettings.set_value(..., false)).
##
## A test loads the same `user://settings.cfg` the game does, so what was set
## in Options was set for every gate as well. `--far`'s crossfade check counts
## pixels far from a reference, and its control -- holes with no box under a
## fading shell -- read 6.1 % one day and 4.7 % the next with nothing in the
## far city changed (2026-10-07), under a floor of 5. It is the anti-aliasing:
## 8.8 % with MSAA and FXAA off, 6.4 % with FXAA alone, 5.1 % with MSAA alone,
## 4.7 % with both, which is the menu's default. Brightness, anti-aliasing,
## shadow quality, render scale, the colour filter, the bindings: a gate's
## answer must not depend on what somebody chose in a menu.
##
## For a test window, and for a scripted pass in any window (CityScene). A
## pass must never SAVE settings itself: after this, what would be written is
## the defaults, over the user's own.
func use_default_settings() -> void:
	if _defaulted:
		return
	_defaulted = true
	var settings := get_node_or_null(^"/root/MenuSettings")
	if settings == null:
		return
	for def in settings.all_defs():
		var id: StringName = (def as Dictionary)["id"]
		settings.set_value(id, settings.default_of(id), false)
	# And the keys the project ships with, once MenuSettings has applied the
	# user's rebinding (a deferred call of its own, queued before this one).
	InputMap.load_from_project_settings.call_deferred()


func _process(_delta: float) -> void:
	_park()


func _park() -> void:
	var win := get_window()
	if win == null:
		return
	if win.mode != Window.MODE_WINDOWED:
		win.mode = Window.MODE_WINDOWED
	if win.position != PARK:
		win.position = PARK
	# The size a pass's pictures are taken at. The window is made a speck (see
	# above) and MenuSettings then gives it the user's own resolution, a frame
	# in: set here, and again for the first few frames after that. Not for
	# ever -- a pass may size its window on purpose.
	if _sizing > 0:
		_sizing -= 1
		if win.size != SIZE:
			win.size = SIZE
