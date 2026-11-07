extends SceneTree

## The in-game UI kit (ui/core/GameUI.gd, ui/docs/README.md) and the one rarity
## palette (Rarity.colour).
##
##     godot --headless --path . --script res://tools/game_ui_probe.gd
##
## Text scale is changed IN MEMORY only (MenuSettings.set_value(id, v, false)) and
## put back: a probe must never write the player's settings.cfg (CLAUDE.md).

var _ok := 0
var _fail := 0


func _check(what: String, cond: bool, detail := "") -> void:
	if cond:
		_ok += 1
		print("  ok   ", what)
	else:
		_fail += 1
		print("  FAIL ", what, (" -- " + detail) if detail != "" else "")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var settings := root.get_node_or_null("MenuSettings")
	_check("the settings module is there", settings != null)
	var was: Variant = settings.get_value(&"text_scale")
	settings.set_value(&"text_scale", 1.0, false)
	print("[game_ui] at text scale 1")
	_check("a designed size is itself at scale 1 (%d)" % GameUI.px(16), GameUI.px(16) == 16)
	var w1 := GameUI.text_width("R  RELOAD", 16)
	var host := Control.new()
	root.add_child(host)
	GameUI.style(host)
	var theme1 := host.theme
	_check("a styled screen wears the menus' theme", theme1 != null and theme1 == MenuTheme.theme())
	var sb := GameUI.panel_box()
	_check("a panel is the menus' surface", sb.bg_color.r == MenuTheme.surface.r and sb.bg_color.a < 1.0)

	settings.set_value(&"text_scale", 1.5, false)
	print("[game_ui] at text scale 1.5")
	_check("text scale turns a designed size up (%d)" % GameUI.px(16), GameUI.px(16) == 24)
	var w2 := GameUI.text_width("R  RELOAD", 16)
	_check("and what is measured with it (%.0f -> %.0f px)" % [w1, w2], w2 > w1 * 1.3)
	_check("a styled screen gets the rebuilt theme", host.theme != null and host.theme != theme1
			and host.theme == MenuTheme.theme())
	settings.set_value(&"text_scale", was, false)
	host.queue_free()

	print("[game_ui] rarity")
	_check("one colour per rarity, 1..6", Rarity.COLOURS.size() == 6)
	_check("legendary is orange", Rarity.colour(5).is_equal_approx(Color(1.0, 0.6, 0.1)))
	_check("out of range clamps", Rarity.colour(0) == Rarity.colour(1) and Rarity.colour(9) == Rarity.colour(6))

	print("[game_ui] %d ok, %d FAIL" % [_ok, _fail])
	quit(1 if _fail > 0 else 0)
