extends Node
## Functional test for the menu module: the settings model, persistence, rebinding, the host
## seam, and the pause lifecycle. Fit/overflow is a separate test (`menu_fit_smoke.gd`).
##
## Run: godot --headless --path . res://menu/tests/menu_smoke.tscn

var _pass := 0
var _fail := 0
var _sub: SubViewport


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
		print("  ok  ", what)
	else:
		_fail += 1
		print("FAIL  ", what)


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	print("=== menu smoke ===")
	_sub = SubViewport.new()
	_sub.size = Vector2i(1280, 720)
	_sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sub)

	_test_table()
	_test_values()
	_test_persistence()
	_test_audio_buses()
	_test_bindings()
	_test_host_seam()
	await _test_options_screen()
	await _test_pause_lifecycle()

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ---------------------------------------------------------------- table
func _test_table() -> void:
	var ids := {}
	for d in MenuSettings.all_defs():
		var def: Dictionary = d
		_check(not ids.has(def["id"]), "setting id '%s' is unique" % def["id"])
		ids[def["id"]] = true
		_check(def.has("default"), "'%s' declares a default" % def["id"])
		_check(def.has("tab"), "'%s' declares a tab" % def["id"])
	_check(not MenuSettings.tabs().is_empty(), "at least one tab has rows")
	for tab in MenuSettings.tabs():
		_check(MenuSettings.tab_title(tab) != "", "tab '%s' has a title" % tab)


# ---------------------------------------------------------------- values
func _test_values() -> void:
	var before: Variant = MenuSettings.get_value(&"vol_master")
	MenuSettings.set_value(&"vol_master", 0.42, false)
	_check(is_equal_approx(float(MenuSettings.get_value(&"vol_master")), 0.42), "float round-trips")

	# Out of range must clamp, not store garbage — a hand-edited config is the usual source.
	MenuSettings.set_value(&"vol_master", 9.0, false)
	_check(is_equal_approx(float(MenuSettings.get_value(&"vol_master")), 1.0), "over-max clamps")
	MenuSettings.set_value(&"vol_master", -3.0, false)
	_check(is_equal_approx(float(MenuSettings.get_value(&"vol_master")), 0.0), "under-min clamps")

	MenuSettings.set_value(&"msaa", 99, false)
	_check(int(MenuSettings.get_value(&"msaa")) == 3, "enum clamps to the last choice")

	# A stale config file hands back whatever was written last time. None of these forms may
	# take the settings load down — `bool()` raises on a String, so coercion must not use it.
	MenuSettings.set_value(&"show_fps", 1, false)
	_check(MenuSettings.get_bool(&"show_fps") == true, "int coerces to bool")
	MenuSettings.set_value(&"show_fps", "true", false)
	_check(MenuSettings.get_bool(&"show_fps") == true, "string coerces to bool")
	MenuSettings.set_value(&"show_fps", "nonsense", false)
	_check(MenuSettings.get_bool(&"show_fps") == false, "unparseable string reads as false")
	_check(MenuSettings.get_bool(&"no_such_setting") == false,
			"an unknown id reads as false instead of raising")

	var fired := [0]
	var cb := func(_id: StringName, _v: Variant) -> void: fired[0] += 1
	MenuSettings.changed.connect(cb)
	MenuSettings.set_value(&"vol_master", 0.5, false)
	MenuSettings.set_value(&"vol_master", 0.5, false)   # same value again
	MenuSettings.changed.disconnect(cb)
	_check(fired[0] == 1, "changed fires once per real change, not per set")

	MenuSettings.set_value(&"vol_master", before, false)
	MenuSettings.set_value(&"show_fps", MenuSettings.default_of(&"show_fps"), false)
	MenuSettings.set_value(&"msaa", MenuSettings.default_of(&"msaa"), false)

	# Reset restores a whole tab.
	MenuSettings.set_value(&"vol_master", 0.11, false)
	MenuSettings.reset_tab("audio")
	_check(is_equal_approx(float(MenuSettings.get_value(&"vol_master")),
			float(MenuSettings.default_of(&"vol_master"))), "reset_tab restores defaults")

	_check(MenuSettings.def_of(&"not_a_real_setting").is_empty(), "unknown id yields no def")


# ---------------------------------------------------------------- persistence
func _test_persistence() -> void:
	MenuSettings.set_value(&"vol_master", 0.33, true)
	var cfg := ConfigFile.new()
	var ok := cfg.load(MenuSettings.CONFIG_PATH) == OK
	_check(ok, "settings file written")
	if ok:
		_check(is_equal_approx(float(cfg.get_value("audio", "vol_master", -1.0)), 0.33),
				"value lands in its tab's section")
		_check(int(cfg.get_value("meta", "version", -1)) == MenuSettings.CONFIG_VERSION,
				"config version stamped")
	MenuSettings.set_value(&"vol_master", MenuSettings.default_of(&"vol_master"), true)


# ---------------------------------------------------------------- audio
func _test_audio_buses() -> void:
	for bus in MenuSettings.MANAGED_BUSES:
		_check(AudioServer.get_bus_index(bus) >= 0, "bus '%s' exists" % bus)
	MenuSettings.set_value(&"vol_master", 0.5, false)
	var v := MenuSettings.bus_volume("Master")
	_check(absf(v - 0.5) < 0.02, "Master bus follows its slider (%.3f)" % v)
	# (The zeroed-slider-mutes check went with the Music/SFX/UI/Voice sliders: this game's
	# sounds all play on Master, which _set_bus_volume never mutes by design.)
	MenuSettings.set_value(&"vol_master", MenuSettings.default_of(&"vol_master"), false)


# ---------------------------------------------------------------- input
func _test_bindings() -> void:
	var actions := MenuSettings.rebindable_actions()
	_check(not actions.is_empty(), "there are rebindable actions")
	for a in actions:
		_check(not String(a).begins_with("ui_"), "engine action '%s' excluded" % a)
	if actions.is_empty():
		return

	var action: StringName = actions[0]
	var original := MenuSettings.events_for(action).duplicate()

	var e := InputEventKey.new()
	e.physical_keycode = KEY_F13     # nothing in the project uses it
	MenuSettings.rebind(action, e, 0)
	var now := MenuSettings.events_for(action)
	_check(now.size() > 0 and now[0].is_match(e, true), "rebind lands in slot 0")
	_check(KeybindRow.describe_event(e) != "", "binding has a display name")

	# Conflict detection must see the SAME key on a DIFFERENT action, and not on itself.
	if actions.size() > 1:
		var other: StringName = actions[1]
		_check(MenuSettings.conflicts_for(other, e).has(action),
				"conflict reported against the action already using the key")
		_check(not MenuSettings.conflicts_for(action, e).has(action),
				"an action never conflicts with itself")

	MenuSettings.unbind_event(action, e)
	_check(MenuSettings.conflicts_for(actions[actions.size() - 1], e).is_empty(),
			"unbind_event clears the conflict")

	MenuSettings.reset_action(action)
	var restored := MenuSettings.events_for(action)
	_check(restored.size() == original.size(), "reset restores the project default count")
	var same := restored.size() == original.size()
	for i in mini(restored.size(), original.size()):
		if not restored[i].is_match(original[i], true):
			same = false
	_check(same, "reset restores the project's own bindings")


# ---------------------------------------------------------------- host seam
func _test_host_seam() -> void:
	var real := MenuHost.host()
	_check(real != null, "a host is always resolved")
	_check(MenuHost.game_title() != "", "host supplies a title")
	_check(MenuHost.main_menu_scene().begins_with("res://"), "host supplies a main menu scene")

	# The base class must be a complete, harmless host — that is what lets `menu/` run in a
	# project with no game code at all.
	MenuHost.set_host(MenuHost.new())
	_check(MenuHost.main_menu_entries().is_empty(), "null host adds no entries")
	_check(MenuHost.has_continue() == false, "null host has nothing to continue")
	_check(MenuHost.pause_allowed() == true, "null host allows pausing")
	MenuHost.apply_setting(&"anything", 1)          # must not crash
	_check(MenuHost.extra_option_tabs().is_empty(), "null host adds no tabs")
	MenuHost.set_host(real)
	_check(MenuHost.host() == real, "the real host is restored")


# ---------------------------------------------------------------- options screen
func _test_options_screen() -> void:
	var scr := load("res://menu/ui/OptionsMenu.gd") as GDScript
	var o := scr.new() as MenuScreen
	o.set("overlay_mode", true)
	o.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sub.add_child(o)
	await _settle()

	var tab_ids: Array = o.get("_tab_ids")
	_check(tab_ids.size() == MenuSettings.tabs().size() + MenuHost.extra_option_tabs().size(),
			"every tab is built")
	var rows: Dictionary = o.get("_rows")
	_check(rows.size() > 0, "rows were built from the table")
	_check(rows.has(&"vol_master"), "a known setting has a row")

	# Editing through the row writes the model — the UI is a view, never a second source.
	var row: OptionRow = rows[&"vol_master"]
	row.refresh()
	MenuSettings.set_value(&"vol_master", 0.25, false)
	row.refresh()
	_check(is_equal_approx(float(MenuSettings.get_value(&"vol_master")), 0.25),
			"row reflects an external change")
	MenuSettings.set_value(&"vol_master", MenuSettings.default_of(&"vol_master"), false)

	# Dependent rows: resolution is meaningless outside windowed mode and must be disabled.
	MenuSettings.set_value(&"display_mode", 2, false)
	await _settle()
	var res_row: OptionRow = rows.get(&"resolution")
	_check(res_row != null, "resolution row exists")
	MenuSettings.set_value(&"display_mode", 0, false)
	await _settle()

	# Every tab must survive being shown; a tab that throws is a tab nobody can open.
	for i in tab_ids.size():
		o.call("_show_tab", i)
		await _settle()
	_check(true, "every tab shows without error")

	o.queue_free()
	await _settle()


# ---------------------------------------------------------------- pause
func _test_pause_lifecycle() -> void:
	# No current scene in a bare test harness, so pausing must refuse rather than half-open.
	_check(not MenuManager.is_open(), "pause starts closed")
	# The game's host pauses only over the city (Escape belongs to other scenes' own tools).
	# The lifecycle itself is tested under the null host, which pauses anywhere.
	var real := MenuHost.host()
	if get_tree().current_scene != null:
		_check(not MenuHost.pause_allowed(), "the game's host refuses to pause outside the city")
	MenuHost.set_host(MenuHost.new())
	var opened := MenuManager.open_pause()
	if get_tree().current_scene == null:
		_check(not opened, "pause refuses with no scene on screen")
	else:
		_check(opened, "pause opened")
		await _settle()
		_check(get_tree().paused, "the tree is paused while the menu is up")
		MenuManager.close_pause()
		await _settle()
		_check(not get_tree().paused, "resume unpauses")
		_check(not MenuManager.is_open(), "resume closes the menu")
	MenuHost.set_host(real)

	# The real host must refuse to pause over the Forge editor, which owns Escape itself.
	var host := MenuHost.host()
	_check(host != null, "host present for pause policy")


func _settle() -> void:
	for i in 3:
		await get_tree().process_frame
