extends Node
## Headless proof that no menu is ever cut off by the screen.
##
## Every screen is built inside a SubViewport of each test size and then audited twice:
##
##   1. `MenuFit.audit()` — nothing sits outside its clipping ancestor unless that ancestor can
##      scroll in the direction it overflows. A violation means content the player cannot reach.
##   2. `needs_horizontal_scroll()` — the layout fit the WIDTH without falling back to the
##      horizontal escape valve. Sideways-scrolling menus are not "fine", they are a failure to
##      shrink, so this is asserted separately rather than being forgiven by rule 1.
##   3. `MenuFit.audit_collapsed()` — every control that has text is big enough to draw it. Rules
##      1 and 2 are both satisfied by a label squashed to one pixel, so on their own they would
##      score a completely blank menu as a pass. This is the assertion that says otherwise.
##
## A SubViewport rather than resizing the real window because headless has no window to resize,
## and because it makes each size an isolated, deterministic build.
##
## Run: godot --headless --path . res://menu/tests/menu_fit_smoke.tscn

## Deliberately brutal: a small netbook window, 4:3, ultrawide, portrait, and 4K.
const SIZES: Array[Vector2i] = [
	Vector2i(640, 480),    # smallest window Godot will reasonably open
	Vector2i(800, 600),
	Vector2i(1024, 768),
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1920, 1080),
	Vector2i(2560, 1080),  # 21:9 ultrawide
	Vector2i(3840, 2160),  # 4K
	Vector2i(1080, 1920),  # portrait / rotated display
]

## Each screen is also built at the most punishing accessibility combination, because the
## largest text at the smallest window is where layouts actually break.
const STRESS := {"text_scale": 1.6, "safe": 0.15}

const SCREENS := {
	"MainMenu": "res://menu/ui/MainMenu.gd",
	"OptionsMenu": "res://menu/ui/OptionsMenu.gd",
	"PauseMenu": "res://menu/ui/PauseMenu.gd",
}

var _pass := 0
var _fail := 0
var _sub: SubViewport


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL  ", what)
		if detail != "":
			print(detail)


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	print("=== menu fit smoke ===")
	_sub = SubViewport.new()
	_sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sub)

	await _sweep("default", 1.0, 0.0)
	await _sweep("stress", STRESS["text_scale"], STRESS["safe"])

	# Modals are screens too — a confirmation that opens half off a 640x480 window is the same
	# bug as a menu that does.
	await _check_modal()

	# Leave the settings as we found them so a test run does not rewrite the player's config.
	MenuSettings.set_value(&"text_scale", MenuSettings.default_of(&"text_scale"), false)
	for edge in [&"safe_left", &"safe_right", &"safe_top", &"safe_bottom"]:
		MenuSettings.set_value(edge, MenuSettings.default_of(edge), false)

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _sweep(label: String, text_scale: float, safe: float) -> void:
	MenuSettings.set_value(&"text_scale", text_scale, false)
	for edge in [&"safe_left", &"safe_right", &"safe_top", &"safe_bottom"]:
		MenuSettings.set_value(edge, safe, false)
	MenuTheme.invalidate()

	for size in SIZES:
		for screen_name in SCREENS:
			await _check_screen(label, String(screen_name), String(SCREENS[screen_name]), size)


func _check_screen(label: String, screen_name: String, script_path: String,
		size: Vector2i) -> void:
	_sub.size = size
	var scr := load(script_path) as GDScript
	var screen := scr.new() as MenuScreen
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sub.add_child(screen)
	await _settle()

	var tag := "%s %s @ %dx%d" % [label, screen_name, size.x, size.y]
	# OptionsMenu holds every tab; each one has to fit on its own, so walk them all.
	var tab_count: int = 1
	if screen.has_method("_show_tab"):
		tab_count = maxi((screen.get("_tab_ids") as Array).size(), 1)
	for tab in tab_count:
		if screen.has_method("_show_tab") and tab_count > 1:
			screen.call("_show_tab", tab)
			await _settle()
		var suffix := "" if tab_count == 1 else " [tab %d]" % tab
		var violations := screen.audit_fit()
		_check(violations.is_empty(), tag + suffix + " — all content reachable",
				MenuFit.describe(violations))
		_check(not screen.needs_horizontal_scroll(), tag + suffix + " — fits the width")
		# Fitting is not the same as being visible: a label collapsed to one pixel of height
		# passes every overflow check there is. Both halves or neither.
		var collapsed := MenuFit.audit_collapsed(screen)
		_check(collapsed.is_empty(), tag + suffix + " — nothing collapsed out of sight",
				MenuFit.describe_collapsed(collapsed))

	screen.queue_free()
	await _settle()


func _check_modal() -> void:
	_sub.size = Vector2i(640, 480)
	var host := MenuScreen.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sub.add_child(host)
	await _settle()
	var m := MenuModal.ask(host, "A fairly long confirmation heading",
			"A message long enough to need wrapping on a small window, which is exactly the "
			+ "case where a fixed-width dialog would run off the edge.", "Confirm", "Cancel")
	await _settle()
	var violations := m.audit_fit()
	_check(violations.is_empty(), "modal @ 640x480 — all content reachable",
			MenuFit.describe(violations))
	_check(not m.needs_horizontal_scroll(), "modal @ 640x480 — fits the width")
	var collapsed := MenuFit.audit_collapsed(m)
	_check(collapsed.is_empty(), "modal @ 640x480 — nothing collapsed out of sight",
			MenuFit.describe_collapsed(collapsed))
	host.queue_free()
	await _settle()


## Containers lay out over several frames — sizes read too early are the previous frame's.
func _settle() -> void:
	for i in 4:
		await get_tree().process_frame
