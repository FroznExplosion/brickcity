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
const FIREFIGHT := "res://scenes/firefight.tscn"
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
		{"label": "Firefight", "tooltip": "Hold out against waves of soldiers in a walled-in ring.",
			"action": func() -> void: _goto(FIREFIGHT)},
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
		&"dev_mode":
			DevMode.on = MENU_SETTINGS.truthy(value)
		&"invincible":
			DevMode.invincible = MENU_SETTINGS.truthy(value)
		&"stud_strength":
			# A headless run is a test, and keeps the default as a test window
			# does (TestWindow.use_default_settings): a probe's answer must not
			# be what somebody set here.
			if DisplayServer.get_name() != "headless":
				BrickStrength.times = float(value)
		&"blast_push":
			if DisplayServer.get_name() != "headless":
				IslandManager.push_times = float(value)
		&"brick_bounce":
			if DisplayServer.get_name() != "headless":
				IslandManager.crumb_bounce = float(value)
		&"brick_heap":
			if DisplayServer.get_name() != "headless":
				BrickHeap.max_bricks = int(value)
		&"floor_reach":
			if DisplayServer.get_name() != "headless":
				BrickStrength.span_reach = float(value)
		&"aa_mouse":
			AimAssist.mouse_level = int(value)
		&"aa_pad":
			AimAssist.pad_level = int(value)
		&"aa_snap":
			AimAssist.snap_on_aim = MENU_SETTINGS.truthy(value)
		&"aa_friction":
			AimAssist.friction_scale = float(value)
		&"aa_tracking":
			AimAssist.tracking_scale = float(value)
		&"aa_centering":
			AimAssist.centering_scale = float(value)
		&"aa_bullet":
			AimAssist.bullet_scale = float(value)
		&"aa_snap_strength":
			AimAssist.snap_strength = float(value)
		&"aa_engage":
			AimAssist.engage_on = MENU_SETTINGS.truthy(value)
		&"aa_range":
			AimAssist.range_limit = MENU_SETTINGS.truthy(value)
		&"aa_vertical":
			AimAssist.vertical_pull = MENU_SETTINGS.truthy(value)
		&"aa_weak_points":
			AimAssist.weak_points = MENU_SETTINGS.truthy(value)


## The game's own rows: developer mode and the invincible player, in Gameplay.
func _setting_defs() -> Array:
	return [
		{"id": &"dev_mode", "tab": "gameplay", "type": MENU_SETTINGS.T_BOOL, "label": "Developer Mode",
			"default": true, "hint": "The developer keys and tools (spawning, debug views, the terrain "
			+ "and disaster tools), and a Developer tab here with buttons and their key bindings."},
		{"id": &"invincible", "tab": "gameplay", "type": MENU_SETTINGS.T_BOOL, "label": "Invincible (Developer)",
			"default": true, "hint": "While Developer Mode is on, you take no damage -- on foot, and in "
			+ "the mech or vehicle you drive."},
		{"id": &"stud_strength", "tab": "gameplay", "type": MENU_SETTINGS.T_SLIDER,
			"label": "Stud Strength (Developer)", "default": BrickStrength.DEFAULT_TIMES,
			"min": BrickStrength.MIN_TIMES, "max": BrickStrength.MAX_TIMES, "step": 0.5, "suffix": "x",
			"hint": "How hard a stud holds: how much comes off a damaged building by itself. "
			+ "1x is a building the game's size, 44x a toy on a table. Buildings take it at once; "
			+ "what has already fallen is not put back."},
		{"id": &"blast_push", "tab": "gameplay", "type": MENU_SETTINGS.T_SLIDER,
			"label": "Blast Push (Developer)", "default": IslandManager.PUSH_DEFAULT_TIMES,
			"min": 0.0, "max": IslandManager.PUSH_MAX_TIMES, "step": 0.25, "suffix": "x",
			"hint": "How hard a blast shoves the loose pieces near it. Light ones are thrown, "
			+ "big wreckage hardly moves; 0 pushes nothing."},
		{"id": &"brick_bounce", "tab": "gameplay", "type": MENU_SETTINGS.T_SLIDER,
			"label": "Brick Bounce (Developer)", "default": IslandManager.CRUMB_BOUNCE,
			"min": 0.0, "max": IslandManager.CRUMB_BOUNCE_MAX, "step": 0.05,
			"hint": "How far a loose brick bounces when it lands, as a share of how fast it came "
			+ "down. 0: it stops where it lands."},
		{"id": &"brick_heap", "tab": "gameplay", "type": MENU_SETTINGS.T_SLIDER,
			"label": "Bricks Left Lying (Developer)", "default": BrickHeap.DEFAULT_MAX,
			"min": 0, "max": BrickHeap.MAX_MAX, "step": 500,
			"hint": "How many loose bricks stay where they fell, all told; past it the oldest heaps "
			+ "are swept up first. 0: they shrink away a second and a half after they come loose."},
		{"id": &"floor_reach", "tab": "gameplay", "type": MENU_SETTINGS.T_SLIDER,
			"label": "Floor Reach (Developer)", "default": BrickStrength.SPAN_DEFAULT,
			"min": 6.0, "max": 80.0, "step": 2.0, "suffix": " studs",
			"hint": "How far a floor reaches past what holds it up before it gives way: a floor "
			+ "over a gap, an overhang, wreckage lying across two stubs. Stone reaches 2.5 times "
			+ "as far, metal 4. Asked once a building has stopped coming apart."},
	] + AIM_ASSIST_DEFS + AIM_ASSIST_ADVANCED


## Options > Aim Assist (AimAssist). Off the built-in tabs: the tab is the host's own
## (_build_aim_tab), so the simple rows can sit over an Advanced section.
const AIM_LEVELS := ["Off", "Low", "Medium", "High"]
const AIM_ASSIST_DEFS := [
	{"id": &"aa_mouse", "tab": "aim_assist", "type": MENU_SETTINGS.T_ENUM, "label": "Mouse Aim Assist",
		"default": 2, "choices": AIM_LEVELS,
		"hint": "With a mouse: slows your aim over an enemy and helps it follow them. On for testing."},
	{"id": &"aa_pad", "tab": "aim_assist", "type": MENU_SETTINGS.T_ENUM, "label": "Controller Aim Assist",
		"default": 2, "choices": AIM_LEVELS,
		"hint": "With a controller: stronger than the mouse's. Used once controller look is in."},
	{"id": &"aa_snap", "tab": "aim_assist", "type": MENU_SETTINGS.T_BOOL, "label": "Snap When Aiming",
		"default": true, "hint": "Raising the sights near an enemy eases your aim part of the way onto them."},
]
const AIM_ASSIST_ADVANCED := [
	{"id": &"aa_friction", "tab": "aim_assist", "type": MENU_SETTINGS.T_SLIDER, "label": "Slowdown",
		"default": 1.0, "min": 0.0, "max": 2.0, "step": 0.05, "suffix": "x",
		"hint": "How much your aim slows over an enemy. Never moves your view."},
	{"id": &"aa_tracking", "tab": "aim_assist", "type": MENU_SETTINGS.T_SLIDER, "label": "Tracking",
		"default": 1.0, "min": 0.0, "max": 2.0, "step": 0.05, "suffix": "x",
		"hint": "How much your view follows an enemy who moves. A still enemy is never pulled toward."},
	{"id": &"aa_centering", "tab": "aim_assist", "type": MENU_SETTINGS.T_SLIDER, "label": "Centering",
		"default": 1.0, "min": 0.0, "max": 2.0, "step": 0.05, "suffix": "x",
		"hint": "A gentle pull to the enemy's middle while you turn or fire -- never against your turn."},
	{"id": &"aa_bullet", "tab": "aim_assist", "type": MENU_SETTINGS.T_SLIDER, "label": "Bullet Magnetism",
		"default": 1.0, "min": 0.0, "max": 2.0, "step": 0.05, "suffix": "x",
		"hint": "Rounds that would just miss are bent onto the enemy. Your view does not move."},
	{"id": &"aa_snap_strength", "tab": "aim_assist", "type": MENU_SETTINGS.T_SLIDER, "label": "Snap Strength",
		"default": 0.6, "min": 0.0, "max": 1.0, "step": 0.05, "suffix": "%",
		"hint": "How much of the gap the snap closes when you raise the sights."},
	{"id": &"aa_engage", "tab": "aim_assist", "type": MENU_SETTINGS.T_BOOL, "label": "Stronger While Firing",
		"default": true, "hint": "Staying on an enemy while firing builds the assist up over half a second."},
	{"id": &"aa_range", "tab": "aim_assist", "type": MENU_SETTINGS.T_BOOL, "label": "Limit to Weapon Range",
		"default": true, "hint": "No assist toward an enemy your gun cannot reach (a shotgun at 30 m)."},
	{"id": &"aa_weak_points", "tab": "aim_assist", "type": MENU_SETTINGS.T_BOOL, "label": "Aim for Weak Points",
		"default": true, "hint": "Help toward the weak point facing you (a head, a mech's hatch), never one round the back."},
	{"id": &"aa_vertical", "tab": "aim_assist", "type": MENU_SETTINGS.T_BOOL, "label": "Vertical Help",
		"default": false, "hint": "Off: the assist helps only side to side, so aiming at a head stays on the head."},
]


## Names for the rebinding lists: Options > Controls (the player's) and Options >
## Developer (DEV_ACTIONS).
const ACTION_NAMES := {
	"move_forward": "Move Forward / Drive Forward", "move_back": "Move Back / Reverse",
	"move_left": "Strafe Left / Turn or Steer Left", "move_right": "Strafe Right / Turn or Steer Right",
	"sprint": "Sprint (on foot and in a mech)", "jump": "Jump (hold: higher) / Climb",
	"crouch": "Crouch / Slide / Let Go", "grapple": "Grapple (hold)",
	"fire": "Fire / Mech Gun / Tank Cannon", "aim": "Aim Down Sights / Tank Machine Gun",
	"reload": "Reload (hold: take a floor gun / get in a mech or vehicle / alt-fire)", "melee": "Melee / Climb on or Hijack (hold: pry the hatch)", "pause": "Pause",
	"swap_weapon": "Swap Gun (hold: other group / try a floor gun)", "slot_1": "Gun 1", "slot_2": "Gun 2",
	"slot_3": "Gun 3", "slot_4": "Gun 4", "ordnance": "Ordnance", "grenade": "Grenade",
	"inventory": "Backpack",
	"use_vehicle": "Get In / Out, Ride on (Mech, Tank, Truck)",
	"vehicle_view": "Vehicle: Behind / Inside View",
	"vehicle_seat": "Tank: Driver's / Gunner's Seat",
	"mech_order": "Order Your Mech (tap: follow / hold; hold + aim: attack there)",
	"mech_dash": "Mech: Dash", "mech_smoke": "Mech: Electric Smoke (throws off a rider)",
	"dev_big_blast": "Big Blast", "dev_disasters": "Disaster Menu (Shift: stop all)",
	"dev_stats": "Stats Overlay", "dev_gun_out": "Free Camera: Take the Gun Out",
	"dev_gun_away": "Free Camera: Put the Gun Away", "dev_spawn_soldier": "Spawn a Soldier",
	"dev_spawn_squad": "Spawn a Squad", "dev_spawn_enemy_mech": "Spawn an Enemy Mech",
	"dev_spawn_tank": "Spawn an Enemy Tank (Shift: an empty one of ours; Ctrl: an empty truck; Ctrl+Shift: an enemy truck; Alt: an enemy APC; Alt+Shift: an empty APC of ours)",
	"dev_play_on_foot": "Play on Foot / Free Camera", "dev_gun_class": "Free Camera: Next Gun Class",
	"dev_gun_reload": "Free Camera: Reload", "dev_ai_overlay": "AI Overlay",
	"dev_save": "Save Checkpoint", "dev_load": "Load Checkpoint",
	"dev_view_structure": "Debug View: Structure", "dev_view_interior": "Debug View: Interior",
	"dev_view_items": "Debug View: Items", "dev_terrain_menu": "Terrain Settings",
	"dev_terrain_edit": "Terrain Editor", "dev_seams": "Brick Seams",
	"dev_bevel": "Chamfered Edges (Shift: near tier only)", "dev_finish": "Brick Finish",
	"dev_overlap": "Piece Overlap Frames", "dev_slow_motion": "Slow Motion",
	"dev_profiler": "Live Profiler", "dev_worst_frame": "Reset Worst Frame",
	"dev_brick_shells": "Buildings: Bricks Back and Forth", "dev_placer": "Place a Build",
	"dev_grids": "Brick Grids",
}


func _action_label(action: StringName) -> String:
	return String(ACTION_NAMES.get(String(action), ""))


## The developer keys: out of Options > Controls, on Options > Developer.
func _hidden_actions() -> PackedStringArray:
	return PackedStringArray(_dev_actions().map(func(a): return String(a)))


static func _dev_actions() -> Array[StringName]:
	var out: Array[StringName] = []
	for a in InputMap.get_actions():
		if String(a).begins_with("dev_"):
			out.append(a)
	return out


# =====================================================================
# Developer mode (DevMode): a tab of its own, and shortcuts in the pause menu
# =====================================================================

## Options > Developer, while developer mode is on (turn it on in Gameplay and
## open Options again to see it).
func _extra_option_tabs() -> Array:
	var tabs: Array = [{"title": "Aim Assist", "build": _build_aim_tab}]
	if DevMode.on:
		tabs.append({"title": "Developer", "build": _build_dev_tab})
	return tabs


## Options > Aim Assist: the three simple rows, then the Advanced ones under a heading.
func _build_aim_tab(page: VBoxContainer) -> void:
	for d in AIM_ASSIST_DEFS:
		page.add_child(OptionRow.create(d))
	page.add_child(HSeparator.new())
	var head := Label.new()
	head.text = "Advanced"
	page.add_child(head)
	for d in AIM_ASSIST_ADVANCED:
		page.add_child(OptionRow.create(d))


## The tools that open from a button, in the city: [label, what it does].
func _dev_tools() -> Array:
	return [
		["Disaster Menu", func(c: Node) -> void:
			if c.disasters != null: c.disasters.open_menu()],
		["Terrain Editor", func(c: Node) -> void: c._toggle_terrain_edit()],
		["Terrain Settings", func(c: Node) -> void: c._toggle_terrain_dev_menu()],
		["AI Overlay", func(c: Node) -> void:
			c._ai_label.visible = not c._ai_label.visible
			c._update_ai_label()],
		["Stats Overlay", func(c: Node) -> void: c.stats_label.visible = not c.stats_label.visible],
		["Save Checkpoint", func(c: Node) -> void: c.save_checkpoint()],
		["Load Checkpoint", func(c: Node) -> void: c.load_checkpoint()],
	]


## The city under the menu, or null.
static func _city() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var scr := tree.current_scene.get_script() as Script
	return tree.current_scene if scr != null and scr.resource_path == CITY_SCRIPT else null


## Close the menus, back to the game, then open the tool on the city.
func _open_tool(what: Callable) -> void:
	var c := _city()
	if c == null:
		return
	var mm := (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"MenuManager")
	if mm != null:
		mm.close_pause()
	what.call(c)


func _build_dev_tab(page: VBoxContainer) -> void:
	var head := Label.new()
	head.text = "Tools"
	head.add_theme_font_size_override("font_size", MenuTheme.font_size(1.2))
	MenuFit.fit_label(head, false)
	page.add_child(head)
	var where := Label.new()
	where.text = "They open over the city (the City, Big City, Combat Arena and Firefight), and close the menu." \
			if _city() != null else "Open in the City, Big City, the Combat Arena or Firefight to use these."
	MenuFit.fit_label(where)
	where.add_theme_color_override("font_color", MenuTheme.text_dim)
	where.add_theme_font_size_override("font_size", MenuTheme.font_size(0.82))
	page.add_child(where)
	# The same setting as Gameplay's row, here where it is looked for.
	var inv := CheckButton.new()
	inv.text = "Invincible"
	inv.button_pressed = DevMode.invincible
	MenuFit.fit_button(inv)
	inv.toggled.connect(func(v: bool) -> void:
		var ms := (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"MenuSettings")
		if ms != null:
			ms.set_value(&"invincible", v)
		else:
			DevMode.invincible = v)
	page.add_child(inv)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(grid)
	for t in _dev_tools():
		var b := MenuFit.fit_button(Button.new())
		b.text = str(t[0])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = _city() == null
		var what: Callable = t[1]
		b.pressed.connect(func() -> void: _open_tool(what))
		grid.add_child(b)

	page.add_child(HSeparator.new())
	var keys := Label.new()
	keys.text = "Developer Keys"
	keys.add_theme_font_size_override("font_size", MenuTheme.font_size(1.2))
	MenuFit.fit_label(keys, false)
	page.add_child(keys)
	var note := Label.new()
	note.text = "They work only while Developer Mode is on (Gameplay). Click a binding, then press " \
			+ "the key; right-click to clear it. The free camera's own keys -- WASD fly, Space / Q up " \
			+ "and down, Shift fast, Space twice to walk -- are fixed."
	MenuFit.fit_label(note)
	note.add_theme_color_override("font_color", MenuTheme.text_dim)
	note.add_theme_font_size_override("font_size", MenuTheme.font_size(0.82))
	page.add_child(note)
	for a in _dev_actions():
		page.add_child(KeybindRow.create(a))


## In the pause menu, while developer mode is on and over the city: the two
## tools most often wanted, one click away.
func _pause_menu_entries() -> Array:
	if not DevMode.on or _city() == null:
		return []
	var out: Array = []
	for t in _dev_tools().slice(0, 2):
		var what: Callable = t[1]
		out.append({"label": "Dev: " + str(t[0]), "action": func() -> void: _open_tool(what)})
	return out
