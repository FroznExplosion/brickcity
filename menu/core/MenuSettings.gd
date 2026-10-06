extends Node
## Autoload `MenuSettings` — the settings MODEL. One table, one file, one signal.
##
## Everything the options screen shows is a row in `DEFS`. The screen is a renderer for this
## table, not a hand-built form, which is why adding a setting is one entry here and zero UI
## edits, and why porting the module to another game means deleting rows rather than untangling
## a scene. Game-specific rows arrive the same way through `MenuHost.setting_defs()`.
##
## Split of responsibility:
##   * this file APPLIES anything the engine owns — window mode, vsync, buses, viewport AA,
##     UI scale, the accessibility filter. Those work in a project with no game code at all.
##   * `MenuHost.apply_setting()` gets everything else — FOV, difficulty, the player's look
##     sensitivity. The module stores and persists the value; the game decides what it means.
##
## Persistence is `user://settings.cfg` (`ConfigFile`), section = tab id. Input rebindings live
## in the `input` section as arrays of `InputEvent`, which `ConfigFile` serialises natively.
##
## Nothing here reads a game class, so the file parses and runs standalone.

const CONFIG_PATH := "user://settings.cfg"
const CONFIG_VERSION := 1

## Buses the module guarantees exist, in creation order, all sending to Master. A game that ships
## its own bus layout keeps it — anything already present is left alone.
const MANAGED_BUSES := ["Music", "SFX", "UI", "Voice"]

## Windowed resolutions offered, filtered at runtime to those that fit the current screen.
const RESOLUTION_CHOICES: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(2560, 1080), Vector2i(3440, 1440), Vector2i(3840, 2160),
]

## Emitted after a value changes AND has been applied. `id` is the setting id.
signal changed(id: StringName, value: Variant)
## Emitted after any input rebinding changes, including reset-to-defaults.
signal bindings_changed()

# Row types. Strings, not the engine's TYPE_* ints, so a def is readable in a diff.
const T_BOOL := "bool"
const T_SLIDER := "slider"      ## float, uses min/max/step, shown as a percentage or unit
const T_INT := "int"            ## integer slider
const T_ENUM := "enum"          ## fixed `choices` (Array[String]), value = index
const T_RESOLUTION := "res"     ## dynamic choices from the display server
const T_MONITOR := "monitor"    ## dynamic choices, one per screen
const T_AUDIO_DEVICE := "adev"  ## dynamic choices from AudioServer
const T_LOCALE := "locale"      ## dynamic choices from the loaded translations

# Tab ids. The options screen orders its tabs by this list; extra host tabs append after.
const TABS := ["video", "audio", "controls", "gameplay", "accessibility", "interface"]
const TAB_TITLES := {
	"video": "Video", "audio": "Audio", "controls": "Controls",
	"gameplay": "Gameplay", "accessibility": "Accessibility", "interface": "Interface",
}

## The table. Keys per row:
##   id       StringName, unique, also the config key
##   tab      which options tab it lands on
##   type     one of the T_* constants
##   label    what the player reads
##   default  value used until the player changes it
##   min/max/step   sliders only
##   choices  T_ENUM only (Array[String]); dynamic types build their own
##   suffix   slider unit shown after the number ("%", "°", " FPS", "x")
##   min_nonzero  T_INT only; 0 stays 0 ("off"), anything between 1 and this snaps up to it
##   hint     one-line explanation under the row; "" for none
##   needs_rd true = requires a RenderingDevice (Forward+/Mobile). Hidden and skipped on
##            the Compatibility renderer instead of silently doing nothing.
const DEFS := [
	# ---------------- Video ----------------
	{"id": &"display_mode", "tab": "video", "type": T_ENUM, "label": "Display Mode", "default": 0,
		"choices": ["Windowed", "Borderless Window", "Fullscreen"],
		"hint": "Borderless matches your desktop resolution."},
	{"id": &"resolution", "tab": "video", "type": T_RESOLUTION, "label": "Resolution",
		"default": Vector2i(1280, 720), "hint": "Windowed only — the other modes follow the display."},
	{"id": &"monitor", "tab": "video", "type": T_MONITOR, "label": "Monitor", "default": 0, "hint": ""},
	{"id": &"vsync", "tab": "video", "type": T_ENUM, "label": "V-Sync", "default": 1,
		"choices": ["Off", "On", "Adaptive", "Mailbox"],
		"hint": "Off can tear. Adaptive drops V-Sync only when the frame is late."},
	{"id": &"max_fps", "tab": "video", "type": T_INT, "label": "Frame Rate Limit", "default": 0,
		"min": 0.0, "max": 360.0, "step": 5.0, "suffix": " FPS", "min_nonzero": 30,
		"hint": "0 is unlimited. The lowest cap offered is 30 — below that the game reads as broken."},
	{"id": &"fov", "tab": "video", "type": T_INT, "label": "Field of View", "default": 90,
		"min": 70.0, "max": 120.0, "step": 1.0, "suffix": "°",
		"hint": "Horizontal. Wider screens see further to the sides, never less vertically."},
	{"id": &"render_scale", "tab": "video", "type": T_SLIDER, "label": "Render Scale", "default": 1.0,
		"min": 0.5, "max": 2.0, "step": 0.05, "suffix": "x", "needs_rd": true,
		"hint": "Renders the 3D world above or below screen resolution. The UI stays sharp."},
	{"id": &"scaling_mode", "tab": "video", "type": T_ENUM, "label": "Upscaler", "default": 0,
		"choices": ["Bilinear", "FSR 1.0", "FSR 2.2"], "needs_rd": true,
		"hint": "Only does anything below 1.0x render scale."},
	{"id": &"msaa", "tab": "video", "type": T_ENUM, "label": "Anti-Aliasing (MSAA)", "default": 1,
		"choices": ["Off", "2x", "4x", "8x"], "hint": ""},
	{"id": &"fxaa", "tab": "video", "type": T_BOOL, "label": "FXAA", "default": true,
		"hint": "Cheap edge smoothing. Slightly softens the image."},
	{"id": &"taa", "tab": "video", "type": T_BOOL, "label": "Temporal AA", "default": false,
		"needs_rd": true, "hint": "Cleanest edges in motion; can ghost."},
	{"id": &"shadow_quality", "tab": "video", "type": T_ENUM, "label": "Shadow Quality", "default": 2,
		"choices": ["Off", "Low", "Medium", "High", "Ultra"], "hint": ""},
	{"id": &"brightness", "tab": "video", "type": T_SLIDER, "label": "Brightness", "default": 1.0,
		"min": 0.5, "max": 1.8, "step": 0.05, "suffix": "x",
		"hint": "Raise until the darkest shape is just visible."},

	# ---------------- Audio ----------------
	{"id": &"vol_master", "tab": "audio", "type": T_SLIDER, "label": "Master", "default": 0.8,
		"min": 0.0, "max": 1.0, "step": 0.01, "suffix": "%", "hint": ""},
	{"id": &"mute", "tab": "audio", "type": T_BOOL, "label": "Mute All", "default": false, "hint": ""},
	{"id": &"mute_unfocused", "tab": "audio", "type": T_BOOL, "label": "Mute When Unfocused",
		"default": true, "hint": "Silences the game when you alt-tab away."},
	{"id": &"audio_device", "tab": "audio", "type": T_AUDIO_DEVICE, "label": "Output Device",
		"default": "Default", "hint": ""},

	# ---------------- Controls ----------------
	{"id": &"mouse_sensitivity", "tab": "controls", "type": T_SLIDER, "label": "Mouse Sensitivity",
		"default": 1.0, "min": 0.05, "max": 3.0, "step": 0.05, "suffix": "x", "hint": ""},
	{"id": &"ads_sensitivity", "tab": "controls", "type": T_SLIDER, "label": "Aim Sensitivity",
		"default": 0.75, "min": 0.1, "max": 2.0, "step": 0.05, "suffix": "x",
		"hint": "Multiplies mouse sensitivity while aiming down sights."},
	{"id": &"invert_y", "tab": "controls", "type": T_BOOL, "label": "Invert Look (Y)",
		"default": false, "hint": ""},
	{"id": &"pad_deadzone", "tab": "controls", "type": T_SLIDER, "label": "Stick Deadzone",
		"default": 0.2, "min": 0.0, "max": 0.6, "step": 0.01, "suffix": "%",
		"hint": "Raise if your view drifts with the sticks centred."},
	{"id": &"toggle_sprint", "tab": "controls", "type": T_BOOL, "label": "Toggle Sprint",
		"default": false, "hint": "Off = hold the key to sprint."},
	{"id": &"toggle_aim", "tab": "controls", "type": T_BOOL, "label": "Toggle Aim",
		"default": false, "hint": "Off = hold the button to aim."},
	{"id": &"toggle_crouch", "tab": "controls", "type": T_BOOL, "label": "Toggle Crouch / Slide",
		"default": false, "hint": ""},

	# ---------------- Gameplay ----------------
	{"id": &"subtitles", "tab": "gameplay", "type": T_BOOL, "label": "Callout Subtitles",
		"default": true, "hint": "What soldiers shout, as text over the speaker."},
	{"id": &"pause_on_focus_loss", "tab": "gameplay", "type": T_BOOL, "label": "Pause When Unfocused",
		"default": true, "hint": "Opens the pause menu when you alt-tab out of the game."},

	# ---------------- Accessibility ----------------
	{"id": &"ui_scale", "tab": "accessibility", "type": T_SLIDER, "label": "Interface Scale",
		"default": 1.0, "min": 0.75, "max": 1.75, "step": 0.05, "suffix": "x",
		"hint": "Scales every menu and HUD element together."},
	{"id": &"text_scale", "tab": "accessibility", "type": T_SLIDER, "label": "Text Size",
		"default": 1.0, "min": 0.85, "max": 1.6, "step": 0.05, "suffix": "x",
		"hint": "Menu text only — layouts reflow to keep everything on screen."},
	{"id": &"colorblind_mode", "tab": "accessibility", "type": T_ENUM, "label": "Colour Filter",
		"default": 0, "choices": ["Off", "Protanopia", "Deuteranopia", "Tritanopia", "Monochrome"],
		"hint": "Shifts confusable hues apart across the whole screen."},
	{"id": &"filter_strength", "tab": "accessibility", "type": T_SLIDER, "label": "Filter Strength",
		"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05, "suffix": "%", "hint": ""},
	{"id": &"screen_shake", "tab": "accessibility", "type": T_SLIDER, "label": "Screen Shake",
		"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05, "suffix": "%", "hint": ""},
	{"id": &"reduce_motion", "tab": "accessibility", "type": T_BOOL, "label": "Reduce Motion",
		"default": false, "hint": "Removes menu transitions, camera sway and head bob."},
	{"id": &"high_contrast", "tab": "accessibility", "type": T_BOOL, "label": "High Contrast UI",
		"default": false, "hint": "Solid panels and brighter outlines behind menu text."},

	# ---------------- Interface ----------------
	{"id": &"safe_left", "tab": "interface", "type": T_SLIDER, "label": "Safe Area — Left",
		"default": 0.0, "min": 0.0, "max": 0.15, "step": 0.005, "suffix": "%",
		"hint": "Pulls all UI in from that screen edge. For overscan, notches, rounded corners."},
	{"id": &"safe_right", "tab": "interface", "type": T_SLIDER, "label": "Safe Area — Right",
		"default": 0.0, "min": 0.0, "max": 0.15, "step": 0.005, "suffix": "%", "hint": ""},
	{"id": &"safe_top", "tab": "interface", "type": T_SLIDER, "label": "Safe Area — Top",
		"default": 0.0, "min": 0.0, "max": 0.15, "step": 0.005, "suffix": "%", "hint": ""},
	{"id": &"safe_bottom", "tab": "interface", "type": T_SLIDER, "label": "Safe Area — Bottom",
		"default": 0.0, "min": 0.0, "max": 0.15, "step": 0.005, "suffix": "%", "hint": ""},
	{"id": &"hud_opacity", "tab": "interface", "type": T_SLIDER, "label": "HUD Opacity",
		"default": 1.0, "min": 0.2, "max": 1.0, "step": 0.05, "suffix": "%", "hint": ""},
	{"id": &"show_fps", "tab": "interface", "type": T_BOOL, "label": "Show FPS Counter",
		"default": false, "hint": ""},
	{"id": &"show_ping", "tab": "interface", "type": T_BOOL, "label": "Show Frame Time",
		"default": false, "hint": "Milliseconds per frame next to the FPS counter."},
	{"id": &"menu_animations", "tab": "interface", "type": T_BOOL, "label": "Menu Animations",
		"default": true, "hint": ""},
]

var _values: Dictionary = {}          ## id:StringName -> Variant
var _defs_by_id: Dictionary = {}      ## id:StringName -> def Dictionary
var _all_defs: Array = []             ## DEFS + host defs, in display order
var _default_events: Dictionary = {}  ## action:StringName -> Array[InputEvent] (project defaults)
var _loading := false                 ## suppresses saving while the config file is being read

var _filter_layer: CanvasLayer = null
var _filter_rect: ColorRect = null
var _fps_layer: CanvasLayer = null
var _fps_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	_capture_default_events()
	_build_def_index()
	_load()
	# The window and root viewport are not addressable during autoload _ready in every
	# configuration; one frame in, they always are.
	apply_all.call_deferred()
	_watch_window.call_deferred()


## The interface-scale floor depends on the window size, so it has to be recomputed whenever
## that changes — a resize, a monitor change, entering or leaving fullscreen.
func _watch_window() -> void:
	var win := get_window()
	if win != null and not win.size_changed.is_connected(_apply_ui_scale):
		win.size_changed.connect(_apply_ui_scale)


# =====================================================================
# Table access
# =====================================================================
func all_defs() -> Array:
	return _all_defs


func def_of(id: StringName) -> Dictionary:
	return _defs_by_id.get(id, {})


## Rows for one tab, in table order, minus anything this renderer cannot support.
func defs_for(tab: String) -> Array:
	var out: Array = []
	for d in _all_defs:
		var def: Dictionary = d
		if String(def.get("tab", "")) != tab:
			continue
		if bool(def.get("needs_rd", false)) and not _has_rendering_device():
			continue
		out.append(def)
	return out


## Tab ids that actually have rows, in display order. Host tabs are appended by the UI.
func tabs() -> Array:
	var out: Array = []
	for t in TABS:
		if not defs_for(t).is_empty():
			out.append(t)
	return out


func tab_title(tab: String) -> String:
	return String(TAB_TITLES.get(tab, tab.capitalize()))


func _build_def_index() -> void:
	_all_defs = []
	_defs_by_id = {}
	var rows: Array = DEFS.duplicate()
	for extra in MenuHost.setting_defs():
		rows.append(extra)
	for d in rows:
		var def: Dictionary = d
		var id: StringName = def["id"]
		if _defs_by_id.has(id):
			push_warning("MenuSettings: duplicate setting id '%s' — the later one wins." % id)
		_defs_by_id[id] = def
		_all_defs.append(def)
		if not _values.has(id):
			_values[id] = def["default"]


# =====================================================================
# Values
# =====================================================================
func get_value(id: StringName) -> Variant:
	if _values.has(id):
		return _values[id]
	var def := def_of(id)
	return def.get("default", null)


## Read a boolean setting. Use this rather than `bool(get_value(id))`: GDScript's `bool()` has
## constructors for bool/int/float ONLY, and calling it on a String, a null (an unknown id) or
## anything else does not return false — it raises and aborts the calling function. A
## hand-edited `settings.cfg` with `show_fps="true"` would take the whole settings load down.
func get_bool(id: StringName) -> bool:
	return truthy(get_value(id))


## Safe truthiness for any Variant, including the types `bool()` refuses.
static func truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT:
			return int(v) != 0
		TYPE_FLOAT:
			return float(v) != 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v).strip_edges().to_lower() in ["1", "true", "yes", "on"]
	return v != null


func default_of(id: StringName) -> Variant:
	return def_of(id).get("default", null)


## Set, apply, notify, persist. `save` is false while dragging a slider — the caller saves once
## on release rather than rewriting the file every pixel.
func set_value(id: StringName, value: Variant, save: bool = true) -> void:
	if not _defs_by_id.has(id):
		push_warning("MenuSettings: unknown setting '%s'" % id)
		return
	value = _coerce(id, value)
	if _values.has(id) and _same(_values[id], value):
		# Still apply on the initial load pass, where nothing has been applied yet.
		if not _loading:
			return
	_values[id] = value
	_apply_one(id, value)
	changed.emit(id, value)
	if save and not _loading:
		_save()


## Restore one tab's rows to their defaults.
func reset_tab(tab: String) -> void:
	for d in defs_for(tab):
		var def: Dictionary = d
		set_value(def["id"], def["default"], false)
	_save()


func reset_all() -> void:
	for d in _all_defs:
		var def: Dictionary = d
		set_value(def["id"], def["default"], false)
	_save()


## Clamp / re-type an incoming value so a stale config file or a bad caller cannot poison state.
func _coerce(id: StringName, value: Variant) -> Variant:
	var def := def_of(id)
	match String(def.get("type", "")):
		T_BOOL:
			return truthy(value)
		T_SLIDER:
			return clampf(float(value), float(def.get("min", 0.0)), float(def.get("max", 1.0)))
		T_INT:
			var i := int(clampf(float(value), float(def.get("min", 0.0)),
					float(def.get("max", 1.0))))
			# `min_nonzero` is for rows where 0 means "off" and the numbers just above it are
			# all worse than off. A frame limit of 5 is not a preference, it is a player who
			# dragged an unlabelled slider — and the result looks exactly like a broken build.
			var floor_at := int(def.get("min_nonzero", 0))
			if floor_at > 0 and i > 0 and i < floor_at:
				i = floor_at
			return i
		T_ENUM:
			var n: int = (def.get("choices", []) as Array).size()
			return clampi(int(value), 0, maxi(n - 1, 0))
		T_MONITOR:
			return clampi(int(value), 0, maxi(DisplayServer.get_screen_count() - 1, 0))
		T_RESOLUTION:
			if value is Vector2i:
				return value
			if value is Vector2:
				return Vector2i(value)
			if value is String:
				var parts := String(value).split("x")
				if parts.size() == 2:
					return Vector2i(int(parts[0]), int(parts[1]))
			return def.get("default", Vector2i(1280, 720))
		T_AUDIO_DEVICE, T_LOCALE:
			return String(value)
	return value


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return is_equal_approx(a, b)
	return a == b


# =====================================================================
# Apply
# =====================================================================
func apply_all() -> void:
	for d in _all_defs:
		var def: Dictionary = d
		var id: StringName = def["id"]
		_apply_one(id, get_value(id))
	_apply_input_config()


## Engine-owned settings act here; everything else is handed to the game. Both happen — a game
## that wants to mirror an engine setting (say, a FOV readout) still hears about it.
func _apply_one(id: StringName, value: Variant) -> void:
	var def := def_of(id)
	if bool(def.get("needs_rd", false)) and not _has_rendering_device():
		return
	match id:
		&"display_mode", &"resolution", &"monitor":
			_apply_window()
		&"vsync":
			var modes := [DisplayServer.VSYNC_DISABLED, DisplayServer.VSYNC_ENABLED,
					DisplayServer.VSYNC_ADAPTIVE, DisplayServer.VSYNC_MAILBOX]
			DisplayServer.window_set_vsync_mode(modes[clampi(int(value), 0, 3)])
		&"max_fps":
			Engine.max_fps = maxi(int(value), 0)
		&"render_scale":
			var root := _root()
			if root != null:
				root.scaling_3d_scale = float(value)
		&"scaling_mode":
			var root2 := _root()
			if root2 != null:
				var m := [Viewport.SCALING_3D_MODE_BILINEAR, Viewport.SCALING_3D_MODE_FSR,
						Viewport.SCALING_3D_MODE_FSR2]
				root2.scaling_3d_mode = m[clampi(int(value), 0, 2)]
		&"msaa":
			var root3 := _root()
			if root3 != null:
				root3.msaa_3d = clampi(int(value), 0, 3) as Viewport.MSAA
		&"fxaa":
			var root4 := _root()
			if root4 != null:
				root4.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if truthy(value) \
						else Viewport.SCREEN_SPACE_AA_DISABLED
		&"taa":
			var root5 := _root()
			if root5 != null:
				root5.use_taa = truthy(value)
		&"shadow_quality":
			_apply_shadows(int(value))
		&"brightness", &"colorblind_mode", &"filter_strength":
			_apply_screen_filter()
		&"vol_master":
			_set_bus_volume("Master", float(value))
		&"vol_music":
			_set_bus_volume("Music", float(value))
		&"vol_sfx":
			_set_bus_volume("SFX", float(value))
		&"vol_ui":
			_set_bus_volume("UI", float(value))
		&"vol_voice":
			_set_bus_volume("Voice", float(value))
		&"mute":
			AudioServer.set_bus_mute(0, truthy(value))
		&"audio_device":
			var dev := String(value)
			if dev != "" and dev in AudioServer.get_output_device_list():
				AudioServer.output_device = dev
		&"pad_deadzone":
			# Player actions only — the engine's own `ui_*` set keeps its tuned deadzones so
			# raising this cannot make menu navigation stop responding.
			for action in rebindable_actions():
				InputMap.action_set_deadzone(action, float(value))
		&"language":
			var loc := String(value)
			if loc != "":
				TranslationServer.set_locale(loc)
		&"ui_scale":
			_apply_ui_scale()
		&"text_scale", &"high_contrast":
			MenuTheme.invalidate()
		&"safe_left", &"safe_right", &"safe_top", &"safe_bottom":
			_apply_safe_area()
		&"show_fps", &"show_ping":
			_apply_fps_counter()
	# The game always hears about it, engine-owned or not.
	MenuHost.apply_setting(id, value)


func _root() -> Viewport:
	var tree := get_tree()
	return tree.root if tree != null else null


## True on Forward+/Mobile. The Compatibility renderer has no RenderingDevice, and TAA / FSR /
## render scaling silently do nothing there — those rows are hidden rather than lying.
func _has_rendering_device() -> bool:
	return RenderingServer.get_rendering_device() != null


func _apply_window() -> void:
	var win := get_window()
	if win == null or DisplayServer.get_name() == "headless":
		return
	var mode := int(get_value(&"display_mode"))
	var screen := clampi(int(get_value(&"monitor")), 0, maxi(DisplayServer.get_screen_count() - 1, 0))
	if win.current_screen != screen:
		win.current_screen = screen
	match mode:
		1:
			win.mode = Window.MODE_FULLSCREEN          # borderless, desktop resolution
		2:
			win.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
		_:
			win.mode = Window.MODE_WINDOWED
			var res: Vector2i = get_value(&"resolution")
			var usable := DisplayServer.screen_get_usable_rect(screen)
			# Never open a window bigger than the screen it opens on — that is exactly the
			# "cut off by the screen" failure this module exists to prevent.
			res.x = clampi(res.x, 640, maxi(usable.size.x, 640))
			res.y = clampi(res.y, 400, maxi(usable.size.y, 400))
			win.size = res
			win.move_to_center()


## Interface scale, with a floor that stops the UI being drawn smaller than native pixels.
##
## `canvas_items` stretch divides the window size by the base resolution, so on a screen
## SMALLER than the base every menu is drawn shrunk: at 1280x720 against a 1920x1080 base the
## factor is 0.667, which puts a 17px font on 11 device pixels, a 12px Forge label on 8, and a
## 1px border on two thirds of one. That is the "tiny and blurry" failure, and no slider in the
## options screen was defending against it — `ui_scale` only multiplied the shrink further.
##
## `content_scale_factor` multiplies the stretch, so raising it by exactly the shortfall puts
## the net scale back at 1.0 and the UI lays out in the window's real pixels. Above the base
## resolution the floor is inert: scaling UP is what the base resolution is for.
##
## The write is guarded because setting the factor re-emits `size_changed`, which is what calls
## this — without the compare it is an infinite loop.
func _apply_ui_scale() -> void:
	var win := get_window()
	if win == null:
		return
	var want := float(get_value(&"ui_scale")) * _ui_scale_floor(win)
	if not is_equal_approx(win.content_scale_factor, want):
		win.content_scale_factor = want


## The multiplier that cancels a sub-1.0 stretch. 1.0 whenever the window is at least as big as
## the base resolution, or when stretch is off entirely.
func _ui_scale_floor(win: Window) -> float:
	if win.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED:
		return 1.0
	var base := win.content_scale_size
	var win_size := win.size
	if base.x <= 0 or base.y <= 0 or win_size.x <= 0 or win_size.y <= 0:
		return 1.0
	# Every aspect policy settles on the smaller of the two axis ratios — `keep*` letterboxes to
	# it and `expand` grows the viewport past it — so that ratio is the scale actually in force.
	var stretch := minf(float(win_size.x) / float(base.x), float(win_size.y) / float(base.y))
	return 1.0 / stretch if stretch > 0.0 and stretch < 1.0 else 1.0


func _apply_shadows(level: int) -> void:
	# 0 Off .. 4 Ultra. Directional and positional atlases move together; "Off" keeps a tiny
	# atlas rather than disabling lights, so nothing renders black.
	var dir_sizes := [512, 2048, 4096, 8192, 16384]
	var pos_sizes := [512, 2048, 4096, 8192, 8192]
	var l := clampi(level, 0, 4)
	RenderingServer.directional_shadow_atlas_set_size(dir_sizes[l], l >= 2)
	var root := _root()
	if root != null:
		root.positional_shadow_atlas_size = pos_sizes[l]
	var quality := [
		RenderingServer.SHADOW_QUALITY_HARD,
		RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
	]
	RenderingServer.directional_soft_shadow_filter_set_quality(quality[l])
	RenderingServer.positional_soft_shadow_filter_set_quality(quality[l])


# =====================================================================
# Audio buses
# =====================================================================
## Create the buses the sliders drive if the project ships no layout. A game that already has
## them (or ships a `default_bus_layout.tres`) keeps its own — this only fills gaps.
func _ensure_buses() -> void:
	for bus_name in MANAGED_BUSES:
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		var i := AudioServer.bus_count
		AudioServer.add_bus(i)
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, "Master")


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	# A 0 slider is silence, not -inf dB arithmetic: mute the bus outright so nothing leaks.
	AudioServer.set_bus_mute(idx, linear <= 0.0001 and idx != 0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))


func bus_volume(bus_name: String) -> float:
	var idx := AudioServer.get_bus_index(bus_name)
	return 0.0 if idx < 0 else db_to_linear(AudioServer.get_bus_volume_db(idx))


# =====================================================================
# Safe area — driven through the UISafeArea autoload IF the game has one
# =====================================================================
## Looked up by node path, never by class name: the module must parse in a project that has no
## such autoload, and `get_node_or_null` is the only form that degrades to "not there".
func safe_area_node() -> Node:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("UISafeArea")


func _apply_safe_area() -> void:
	var sa := safe_area_node()
	if sa == null or not sa.has_method("set_insets"):
		return
	sa.call("set_insets", float(get_value(&"safe_left")), float(get_value(&"safe_right")),
			float(get_value(&"safe_top")), float(get_value(&"safe_bottom")), true)


## The rectangle every menu must stay inside, in viewport pixels. Falls back to the whole
## viewport when the game has no safe-area system.
func safe_rect() -> Rect2:
	var sa := safe_area_node()
	if sa != null and sa.has_method("safe_rect"):
		return sa.call("safe_rect")
	var root := _root()
	var size := root.get_visible_rect().size if root != null else Vector2(1920, 1080)
	return Rect2(Vector2.ZERO, size)


## Safe-area insets as a fraction per edge, whether or not a UISafeArea autoload exists. The
## menus apply these as margins themselves, because a `Control` main scene is NOT under a
## CanvasLayer and so is never reached by UISafeArea's layer transform.
func safe_insets() -> Vector4:
	return Vector4(float(get_value(&"safe_left")), float(get_value(&"safe_right")),
			float(get_value(&"safe_top")), float(get_value(&"safe_bottom")))


# =====================================================================
# Screen filter (brightness + colour-blind correction) and the FPS counter
# =====================================================================
const FILTER_SHADER := """
shader_type canvas_item;
render_mode blend_disabled, unshaded;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float brightness = 1.0;
uniform float strength = 1.0;
uniform int mode = 0;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	vec3 s = c;
	if (mode == 1) {        // protanopia — red-blind: fold red into green
		s = vec3(0.567 * c.r + 0.433 * c.g, 0.558 * c.r + 0.442 * c.g, 0.242 * c.g + 0.758 * c.b);
	} else if (mode == 2) { // deuteranopia — green-blind
		s = vec3(0.625 * c.r + 0.375 * c.g, 0.700 * c.r + 0.300 * c.g, 0.300 * c.g + 0.700 * c.b);
	} else if (mode == 3) { // tritanopia — blue-blind
		s = vec3(0.950 * c.r + 0.050 * c.g, 0.433 * c.g + 0.567 * c.b, 0.475 * c.g + 0.525 * c.b);
	} else if (mode == 4) { // monochrome
		s = vec3(dot(c, vec3(0.299, 0.587, 0.114)));
	}
	c = mix(c, s, clamp(strength, 0.0, 1.0));
	COLOR = vec4(clamp(c * brightness, vec3(0.0), vec3(1.0)), 1.0);
}
"""


## The filter and the FPS readout are the module's own screen furniture. Both are created on
## demand — a player who never turns them on pays nothing — and both are torn down when they
## go back to neutral rather than left as invisible full-screen draws.
func _apply_screen_filter() -> void:
	var mode := int(get_value(&"colorblind_mode"))
	var bright := float(get_value(&"brightness"))
	var strength := float(get_value(&"filter_strength"))
	var neutral := (mode == 0 or strength <= 0.001) and is_equal_approx(bright, 1.0)
	if neutral:
		if is_instance_valid(_filter_layer):
			_filter_layer.queue_free()
		_filter_layer = null
		_filter_rect = null
		return
	if not is_instance_valid(_filter_layer):
		var tree := get_tree()
		if tree == null or tree.root == null:
			return
		_filter_layer = CanvasLayer.new()
		_filter_layer.name = "MenuScreenFilter"
		_filter_layer.layer = 120
		# Full-screen FX must cover the WHOLE screen, so it opts out of the safe-area inset the
		# same way the game's own overlays do.
		_filter_layer.add_to_group("ui_no_safe_area")
		var sh := Shader.new()
		sh.code = FILTER_SHADER
		var mat := ShaderMaterial.new()
		mat.shader = sh
		_filter_rect = ColorRect.new()
		_filter_rect.material = mat
		_filter_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_filter_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_filter_layer.add_child(_filter_rect)
		tree.root.add_child(_filter_layer)
	var m := _filter_rect.material as ShaderMaterial
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("brightness", bright)
	m.set_shader_parameter("strength", strength)


func _apply_fps_counter() -> void:
	var want := get_bool(&"show_fps") or get_bool(&"show_ping")
	if not want:
		if is_instance_valid(_fps_layer):
			_fps_layer.queue_free()
		_fps_layer = null
		_fps_label = null
		return
	if not is_instance_valid(_fps_layer):
		var tree := get_tree()
		if tree == null or tree.root == null:
			return
		_fps_layer = CanvasLayer.new()
		_fps_layer.name = "MenuFPSCounter"
		_fps_layer.layer = 110
		var pad := MarginContainer.new()
		pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for side in ["left", "top", "right", "bottom"]:
			pad.add_theme_constant_override("margin_" + side, 12)
		_fps_label = Label.new()
		_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_fps_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_fps_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		_fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_fps_label.add_theme_constant_override("outline_size", 4)
		_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad.add_child(_fps_label)
		_fps_layer.add_child(pad)
		tree.root.add_child(_fps_layer)


func _process(_delta: float) -> void:
	if not is_instance_valid(_fps_label):
		return
	var parts: Array[String] = []
	if get_bool(&"show_fps"):
		parts.append("%d FPS" % Engine.get_frames_per_second())
	if get_bool(&"show_ping"):
		var fps := maxf(float(Engine.get_frames_per_second()), 1.0)
		parts.append("%.1f ms" % (1000.0 / fps))
	_fps_label.text = "   ".join(parts)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and get_bool(&"mute_unfocused"):
		AudioServer.set_bus_mute(0, true)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN and get_bool(&"mute_unfocused"):
		AudioServer.set_bus_mute(0, get_bool(&"mute"))


# =====================================================================
# Input rebinding
# =====================================================================
## Snapshot of the project's InputMap before any config is applied — what "Reset to Defaults"
## restores. Taken in _ready, before _load().
func _capture_default_events() -> void:
	for action in InputMap.get_actions():
		_default_events[action] = InputMap.action_get_events(action)


## Actions a player may rebind: everything except the engine's `ui_*` set and whatever the game
## asks to hide.
func rebindable_actions() -> Array[StringName]:
	var hidden := MenuHost.hidden_actions()
	var out: Array[StringName] = []
	for action in InputMap.get_actions():
		var s := String(action)
		if s.begins_with("ui_") or s.begins_with("spatial_editor"):
			continue
		if hidden.has(s):
			continue
		out.append(action)
	return out


func action_label(action: StringName) -> String:
	var custom := MenuHost.action_label(action)
	return custom if custom != "" else String(action).replace("_", " ").capitalize()


func events_for(action: StringName) -> Array[InputEvent]:
	return InputMap.action_get_events(action)


## The project's own bindings for this action, before any player change — what Reset restores
## and what the UI compares against to decide whether to offer Reset at all.
func default_events_for(action: StringName) -> Array:
	return _default_events.get(action, [])


## Actions other than `action` already using an equivalent event.
func conflicts_for(action: StringName, event: InputEvent) -> Array[StringName]:
	var out: Array[StringName] = []
	for other in rebindable_actions():
		if other == action:
			continue
		for e in InputMap.action_get_events(other):
			if _events_match(e, event):
				out.append(other)
				break
	return out


## Compare by what the player pressed, not by object identity — `InputEvent.is_match` ignores
## the pressed state, which is what makes a captured press comparable to a stored binding.
func _events_match(a: InputEvent, b: InputEvent) -> bool:
	if a == null or b == null:
		return false
	return a.is_match(b, true)


## Replace slot `index` of `action` with `event` (append when index is out of range).
func rebind(action: StringName, event: InputEvent, index: int = 0) -> void:
	var events := InputMap.action_get_events(action)
	if index >= 0 and index < events.size():
		events[index] = event
	else:
		events.append(event)
	_write_action(action, events)


func unbind(action: StringName, index: int) -> void:
	var events := InputMap.action_get_events(action)
	if index < 0 or index >= events.size():
		return
	events.remove_at(index)
	_write_action(action, events)


func unbind_event(action: StringName, event: InputEvent) -> void:
	var events := InputMap.action_get_events(action)
	var keep: Array[InputEvent] = []
	for e in events:
		if not _events_match(e, event):
			keep.append(e)
	_write_action(action, keep)


func reset_action(action: StringName) -> void:
	var defaults: Array = _default_events.get(action, [])
	var events: Array[InputEvent] = []
	for e in defaults:
		events.append(e)
	_write_action(action, events)


func reset_all_bindings() -> void:
	for action in _default_events:
		reset_action(action)


func _write_action(action: StringName, events: Array[InputEvent]) -> void:
	InputMap.action_erase_events(action)
	for e in events:
		if e != null:
			InputMap.action_add_event(action, e)
	InputMap.action_set_deadzone(action, float(get_value(&"pad_deadzone")))
	_save()
	bindings_changed.emit()


func _apply_input_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	if not cfg.has_section("input"):
		return
	for key in cfg.get_section_keys("input"):
		var action := StringName(key)
		if not InputMap.has_action(action):
			continue
		var stored: Array = cfg.get_value("input", key, [])
		var events: Array[InputEvent] = []
		for e in stored:
			if e is InputEvent:
				events.append(e)
		if events.is_empty():
			continue
		InputMap.action_erase_events(action)
		for e in events:
			InputMap.action_add_event(action, e)


# =====================================================================
# Persistence
# =====================================================================
## Force a write. Slider drags set values with `save = false` and call this once on release, so a
## drag is one file write rather than one per pixel.
func save_now() -> void:
	_save()


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", CONFIG_VERSION)
	for d in _all_defs:
		var def: Dictionary = d
		var id: StringName = def["id"]
		cfg.set_value(String(def.get("tab", "misc")), String(id), _values.get(id, def["default"]))
	# Only actions that differ from the project defaults are written, so a later change to the
	# project's own bindings reaches players who never rebound that key.
	for action in rebindable_actions():
		var current := InputMap.action_get_events(action)
		var defaults: Array = _default_events.get(action, [])
		if not _event_lists_match(current, defaults):
			cfg.set_value("input", String(action), current)
	var err := cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("MenuSettings: could not save settings (%d)" % err)


func _load() -> void:
	_loading = true
	var cfg := ConfigFile.new()
	var ok := cfg.load(CONFIG_PATH) == OK
	for d in _all_defs:
		var def: Dictionary = d
		var id: StringName = def["id"]
		var tab := String(def.get("tab", "misc"))
		var v: Variant = cfg.get_value(tab, String(id), def["default"]) if ok else def["default"]
		_values[id] = _coerce(id, v)
	_loading = false


func _event_lists_match(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not _events_match(a[i], b[i]):
			return false
	return true


# =====================================================================
# Convenience readers — so game code does not repeat the id strings
# =====================================================================
func look_sensitivity() -> float: return float(get_value(&"mouse_sensitivity"))
func look_inverted() -> bool: return get_bool(&"invert_y")
func shake_scale() -> float: return float(get_value(&"screen_shake"))
func hud_opacity() -> float: return float(get_value(&"hud_opacity"))
func animations_on() -> bool:
	return get_bool(&"menu_animations") and not get_bool(&"reduce_motion")
