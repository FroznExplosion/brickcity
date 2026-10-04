class_name DisasterDirector
extends Node3D

## Starts natural disasters in the small city and runs one at a time
## (Docs/Disasters.md section 1.1).
##
##   H         open / close the disaster menu: which disaster (or Random), how
##             hard, and the earthquake's collapse caps; Start (or Enter) runs it
##   Shift+H   end the running one; its ENDING phase still plays
##   --disaster=<kind>       what Random rolls, forced
##   --disaster-seed=<n>     base seed for the roll and each disaster
##
## Every city has one, the big city included.
##
## Co-op (Docs/Disasters.md 16): the host decides, clients watch. The host
## sends each client a small event -- ["start", kind, seed, start tick,
## intensity, options], ["stop", tick] -- and a client runs the same disaster
## from the same seed, caught up to the host's tick, for the sky, the rain,
## the meteors in the air and the funnel. It changes nothing: its context does
## not decide (DisasterContext.decides), and what the disaster does to bricks
## and people arrives as the host's commands like any other. A client that
## asks for a disaster (the menu, H) sends ["request", ...] to the host.
## Transport-free, like WorldAuthority: the owner fills in the Callables.

signal started(kind: String)
signal ended(kind: String)

## Kind name -> script. Every kind here can be forced with --disaster=.
const KINDS := {
	"drill": preload("res://scripts/disasters/drill_disaster.gd"),
	"meteor": preload("res://scripts/disasters/meteor_shower.gd"),
	"lightning": preload("res://scripts/disasters/lightning_storm.gd"),
	"fire": preload("res://scripts/disasters/building_fire.gd"),
	"tornado": preload("res://scripts/disasters/tornado.gd"),
	"earthquake": preload("res://scripts/disasters/earthquake.gd"),
	"acid": preload("res://scripts/disasters/acid_rain.gd"),
	"hurricane": preload("res://scripts/disasters/hurricane.gd"),
	"snow": preload("res://scripts/disasters/snowfall.gd"),
}
## What Random rolls from. The drill is not in it; --disaster=drill still runs one.
const ROLL := ["meteor", "lightning", "fire", "tornado", "earthquake", "acid", "hurricane", "snow"]
## The menu's names, in the menu's order.
const TITLES := {
	"meteor": "Meteor shower",
	"lightning": "Lightning storm",
	"fire": "Building fire",
	"tornado": "Tornado",
	"earthquake": "Earthquake",
	"acid": "Acid rain",
	"hurricane": "Hurricane",
	"snow": "Snowfall",
}
## Intensity steps the slider snaps to, with their names.
const INTENSITY_NAMES := [[0.5, "Low"], [1.0, "Medium"], [1.6, "High"], [2.5, "Extreme"]]

const BASE_SEED := 0xD15A5

var ctx: DisasterContext
## What this scene offers and Random rolls from: ROLL in a city, the kinds its
## host asked for elsewhere (setup). A scene without buildings has no use for a
## meteor shower.
var roll: Array = ROLL.duplicate()
## Fire outlives what lit it, so it is the director's, not a disaster's.
var fire: FireSpread
var current: Disaster
## Pieces carrying fire off a burning building (BurningDebris).
var debris: BurningDebris
var current_kind := ""
## How many disasters this run has started. The N-th one's seed is the same
## every run, so a disaster seen once can be seen again.
var count := 0

## What the menu will start: "" for Random. Kept between openings.
var menu_kind := ""
var menu_intensity := 1.0
var menu_options := {"max_collapse_at_once": 2, "max_collapse_total": 6}

## Co-op. The host publishes to every add_client(); a client (set_client)
## sends its requests through send_to_host.
var is_host := true
var send_to_host := Callable()
var events_sent := 0
var events_received := 0
var _clients: Array[Callable] = []
## The running disaster's start event, for a client that joins mid-way.
var _start_event: Array = []
## Most ticks a joining client runs to catch up (a whole disaster's worth).
const MAX_CATCHUP := 30 * 120

var _forced := ""
var _base_seed := BASE_SEED
var _roll_rng := RandomNumberGenerator.new()
var _banner: Label
var _layer: CanvasLayer
var _menu: PanelContainer
var _kind_pick: OptionButton
var _intensity: HSlider
var _intensity_label: Label
var _at_once: SpinBox
var _total: SpinBox
var _quake_box: VBoxContainer
var _status: Label
var _recapture := false
var _screen: ShaderMaterial


func setup(city: Node3D, kinds: Array = []) -> void:
	if not kinds.is_empty():
		roll = kinds.duplicate()
	ctx = DisasterContext.new(city)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--disaster="):
			_forced = a.split("=", true, 1)[1]
			if not KINDS.has(_forced):
				push_warning("[disaster] unknown kind '%s'; knows %s" % [_forced, KINDS.keys()])
				_forced = ""
		elif a.begins_with("--disaster-seed="):
			_base_seed = int(a.split("=", true, 1)[1])
	_roll_rng.seed = _base_seed
	fire = FireSpread.new()
	fire.name = "Fire"
	add_child(fire)
	fire.material_at = ctx.material_at
	fire.chip = ctx.chip
	fire.scorch = ctx.scorch
	fire.damage = ctx.damage_pawns
	fire.raining = func() -> bool: return ctx.raining
	fire.setup(hash([_base_seed, "fire"]))
	ctx.fire = fire
	debris = BurningDebris.new()
	debris.name = "BurningDebris"
	add_child(debris)
	debris.setup(ctx, fire)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	_build_banner()
	_build_menu()
	_build_screen()
	ctx.screen = _screen


## True when a disaster is running (any phase before DONE).
func is_running() -> bool:
	return current != null


## Start `kind` -- or a rolled one when empty -- at `intensity`, with `options`
## for the kinds that take them. False if one is already running.
##
## On a client this asks the host instead, and returns whether it could ask.
func start(kind: String = "", intensity := 1.0, options := {}) -> bool:
	if not is_host:
		if not send_to_host.is_valid():
			return false
		send_to_host.call(["request", kind, intensity, options.duplicate(true)])
		events_sent += 1
		return true
	if current != null:
		return false
	if kind == "":
		kind = _forced if _forced != "" else String(roll[_roll_rng.randi_range(0, roll.size() - 1)])
	if not KINDS.has(kind):
		push_warning("[disaster] unknown kind '%s'" % kind)
		return false
	var seed_value := hash([_base_seed, count])
	var at := Engine.get_physics_frames()
	_begin(kind, seed_value, intensity, options)
	_start_event = ["start", kind, seed_value, at, intensity, options.duplicate(true)]
	_publish(_start_event)
	return true


## Make the disaster and set it going. Both sides come through here.
func _begin(kind: String, seed_value: int, intensity: float, options: Dictionary) -> void:
	var d: Disaster = KINDS[kind].new()
	d.name = "Disaster_%s" % kind
	d.intensity = intensity
	d.options = options.duplicate()
	add_child(d)
	current = d
	current_kind = kind
	d.finished.connect(_on_finished)
	d.begin(ctx, seed_value)
	count += 1
	print("[disaster] %s begins (#%d, intensity %.2f)%s" % [d.title, count, intensity,
			"" if is_host else " -- the host's"])
	started.emit(kind)
	_update_banner()


# --- Co-op ------------------------------------------------------------------------

## Host: send every event to this client from now on -- and the running
## disaster's start at once, so a client joining mid-storm sees the storm.
## Called with the event's wire form (plain arrays: they have to serialise).
func add_client(deliver: Callable) -> void:
	_clients.append(deliver)
	if not _start_event.is_empty():
		deliver.call(_start_event.duplicate(true))
		events_sent += 1


## Make this director a client: it plays the host's disasters and decides
## nothing. `send` carries its requests to the host.
func set_client(send: Callable) -> void:
	is_host = false
	send_to_host = send
	ctx.decides = false
	fire.douse()


## An event from the other side.
func receive(msg: Array) -> void:
	events_received += 1
	match String(msg[0]):
		"start":
			if is_host:
				return
			if current != null:
				current.queue_free()   # the host's word is final
				current = null
			var kind := String(msg[1])
			if not KINDS.has(kind):
				push_warning("[disaster] the host started '%s', which this build does not know" % kind)
				return
			_begin(kind, int(msg[2]), float(msg[4]), msg[5])
			# Catch up to the host: the disaster's clock runs on physics ticks.
			var behind := mini(Engine.get_physics_frames() - int(msg[3]), MAX_CATCHUP)
			var dt := 1.0 / Engine.physics_ticks_per_second
			for i in maxi(behind, 0):
				if current == null or current.phase == Disaster.Phase.DONE:
					break
				current.tick(dt)
		"stop":
			if not is_host and current != null:
				current.end_now()
				_update_banner()
		"request":
			if is_host:
				start(String(msg[1]), float(msg[2]), msg[3])
		"request_stop":
			if is_host:
				stop()


func _publish(msg: Array) -> void:
	for c in _clients:
		c.call(msg.duplicate(true))
		events_sent += 1


## Start what the menu has chosen.
func start_from_menu() -> bool:
	var ok := start(menu_kind, menu_intensity, menu_options)
	close_menu()
	return ok


## End the running disaster: straight to its ENDING phase.
func stop() -> void:
	if not is_host:
		if send_to_host.is_valid():
			send_to_host.call(["request_stop"])
			events_sent += 1
		return
	if current != null:
		current.end_now()
		_update_banner()
		_publish(["stop", Engine.get_physics_frames()])


## The city's key handler hands H here.
func on_key(shift: bool) -> void:
	if shift:
		stop()
	elif is_menu_open():
		close_menu()
	else:
		open_menu()


func is_menu_open() -> bool:
	return _menu != null and _menu.visible


func open_menu() -> void:
	_sync_menu()
	_menu.visible = true
	# The mouse is the camera's while captured; give it to the menu, and give
	# it back on close only if it was the camera's before.
	var cam = ctx.city.camera
	_recapture = cam._captured
	if _recapture:
		cam._set_captured(false)
	_kind_pick.grab_focus()


func close_menu() -> void:
	if _menu == null or not _menu.visible:
		return
	_menu.visible = false
	if _recapture:
		ctx.city.camera._set_captured(true)
	_recapture = false


func _unhandled_input(event: InputEvent) -> void:
	if not is_menu_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			start_from_menu()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE:
			close_menu()
			get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if current != null:
		current.tick(delta)


func _process(delta: float) -> void:
	ctx.step(delta)
	_update_banner()
	if is_menu_open():
		_status.text = ("Running: %s — Shift+H or Stop to end it" % current.title) \
				if current != null else "Nothing running."


func _on_finished() -> void:
	var kind := current_kind
	print("[disaster] %s over" % current.title)
	current.queue_free()
	current = null
	current_kind = ""
	_start_event = []
	ended.emit(kind)
	_update_banner()


# --- The weather on the lens -------------------------------------------------------

## A full-screen overlay, under the HUD and over the 3D (layer -1): rain and dust,
## both 0 until a disaster sets them (DisasterContext.set_screen).
func _build_screen() -> void:
	var layer := CanvasLayer.new()
	layer.layer = -1
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen = ShaderMaterial.new()
	_screen.shader = load("res://shaders/disaster_screen.gdshader")
	rect.material = _screen
	layer.add_child(rect)
	add_child(layer)


# --- The banner ---------------------------------------------------------------------

func _build_banner() -> void:
	_banner = Label.new()
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.position.y = 16
	_banner.add_theme_font_size_override("font_size", 22)
	_banner.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35))
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_banner.add_theme_constant_override("outline_size", 6)
	_banner.visible = false
	_layer.add_child(_banner)


func _update_banner() -> void:
	if _banner == null:
		return
	var burning := ""
	if fire != null and fire.is_burning():
		burning = "FIRE — %d burning" % fire.count()
	if current == null:
		_banner.visible = burning != ""
		_banner.text = burning
		return
	_banner.visible = true
	_banner.text = "%s (%s) — %s  %ds   (Shift+H to end)" % [current.title.to_upper(),
			intensity_name(current.intensity), Disaster.phase_name(current.phase),
			ceili(current.seconds_left())]
	if current is Earthquake:
		var q: Earthquake = current
		_banner.text += "\ncollapsing %d/%d · %d of %d so far" % [q.active_collapses(),
				q.max_collapse_at_once, q.collapses.size(), q.max_collapse_total]
	if burning != "" and current_kind != "fire":
		_banner.text += "\n" + burning


static func intensity_name(v: float) -> String:
	var best := ""
	var gap := INF
	for pair in INTENSITY_NAMES:
		if absf(float(pair[0]) - v) < gap:
			gap = absf(float(pair[0]) - v)
			best = pair[1]
	return best if gap < 0.01 else "%s-ish, %.2f" % [best, v]


# --- The menu ---------------------------------------------------------------------------

func _build_menu() -> void:
	_menu = PanelContainer.new()
	_menu.set_anchors_preset(Control.PRESET_CENTER)
	_menu.position = Vector2(-190, -150)
	_menu.custom_minimum_size = Vector2(380, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.1, 0.9)
	style.border_color = Color(1.0, 0.78, 0.35, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	_menu.add_theme_stylebox_override("panel", style)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_menu.add_child(v)

	var head := Label.new()
	head.text = "DISASTERS"
	head.add_theme_font_size_override("font_size", 20)
	head.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35))
	v.add_child(head)

	_kind_pick = OptionButton.new()
	_kind_pick.add_item("Random", 0)
	var i := 1
	for kind in roll:
		_kind_pick.add_item(TITLES[kind], i)
		i += 1
	_kind_pick.item_selected.connect(func(idx: int) -> void:
		menu_kind = "" if idx == 0 else String(roll[idx - 1])
		_quake_box.modulate.a = 1.0 if menu_kind in ["", "earthquake"] else 0.45)
	v.add_child(_row("Disaster", _kind_pick))

	var ih := HBoxContainer.new()
	_intensity = HSlider.new()
	_intensity.min_value = 0.25
	_intensity.max_value = 3.0
	_intensity.step = 0.05
	_intensity.value = menu_intensity
	_intensity.custom_minimum_size = Vector2(170, 0)
	_intensity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_intensity_label = Label.new()
	_intensity_label.custom_minimum_size = Vector2(80, 0)
	_intensity.value_changed.connect(func(value: float) -> void:
		# Snap to the named steps when close to one.
		for pair in INTENSITY_NAMES:
			if absf(value - float(pair[0])) < 0.06 and value != float(pair[0]):
				_intensity.set_value_no_signal(float(pair[0]))
				value = float(pair[0])
		menu_intensity = value
		_intensity_label.text = intensity_name(value))
	ih.add_child(_intensity)
	ih.add_child(_intensity_label)
	v.add_child(_row("Intensity", ih))

	_quake_box = VBoxContainer.new()
	var qh := Label.new()
	qh.text = "Earthquake — keep the collapses in hand"
	qh.add_theme_color_override("font_color", Color(0.8, 0.82, 0.86))
	_quake_box.add_child(qh)
	_at_once = SpinBox.new()
	_at_once.min_value = 0
	_at_once.max_value = 8
	_at_once.value = menu_options.max_collapse_at_once
	_at_once.tooltip_text = "Buildings falling at the same moment. Each is a big physics event: " \
			+ "more at once is more spectacle and a longer worst frame. 0: none collapse."
	_at_once.value_changed.connect(func(value: float) -> void:
		menu_options.max_collapse_at_once = int(value))
	_quake_box.add_child(_row("Max collapsing at once", _at_once))
	_total = SpinBox.new()
	_total.min_value = 0
	_total.max_value = 30
	_total.value = menu_options.max_collapse_total
	_total.tooltip_text = "Buildings the whole quake may bring down."
	_total.value_changed.connect(func(value: float) -> void:
		menu_options.max_collapse_total = int(value))
	_quake_box.add_child(_row("Max collapses in total", _total))
	v.add_child(_quake_box)
	_quake_box.visible = roll.has("earthquake")

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	var go := Button.new()
	go.text = "Start  (Enter)"
	go.pressed.connect(start_from_menu)
	var halt := Button.new()
	halt.text = "Stop"
	halt.pressed.connect(stop)
	var shut := Button.new()
	shut.text = "Close  (H)"
	shut.pressed.connect(close_menu)
	buttons.add_child(go)
	buttons.add_child(halt)
	buttons.add_child(shut)
	v.add_child(buttons)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.7, 0.72, 0.75))
	v.add_child(_status)
	_menu.visible = false
	_layer.add_child(_menu)
	_sync_menu()


func _row(label: String, control: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(150, 0)
	h.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	return h


## Put the controls where the remembered choice is.
func _sync_menu() -> void:
	_kind_pick.select(0 if menu_kind == "" else roll.find(menu_kind) + 1)
	_intensity.set_value_no_signal(menu_intensity)
	_intensity_label.text = intensity_name(menu_intensity)
	_at_once.set_value_no_signal(menu_options.max_collapse_at_once)
	_total.set_value_no_signal(menu_options.max_collapse_total)
	_quake_box.modulate.a = 1.0 if menu_kind in ["", "earthquake"] else 0.45
