class_name DisasterDirector
extends Node3D

## Starts natural disasters in the small city and runs one at a time
## (Docs/Disasters.md section 1.1).
##
##   H         start a random disaster (ignored while one runs)
##   Shift+H   end the running one; its ENDING phase still plays
##   --disaster=<kind>       roll this kind instead of a random one
##   --disaster-seed=<n>     base seed for the roll and each disaster
##
## The city creates this only when it is not --big.

signal started(kind: String)
signal ended(kind: String)

## Kind name -> script. Every kind here can be forced with --disaster=.
const KINDS := {
	"drill": preload("res://scripts/disasters/drill_disaster.gd"),
}
## What H rolls from. The drill is only here until a real disaster is built:
## a key that does nothing is worse than one that runs a drill.
const ROLL := ["drill"]

const BASE_SEED := 0xD15A5

var ctx: DisasterContext
var current: Disaster
var current_kind := ""
## How many disasters this run has started. The N-th one's seed is the same
## every run, so a disaster seen once can be seen again.
var count := 0

var _forced := ""
var _base_seed := BASE_SEED
var _roll_rng := RandomNumberGenerator.new()
var _banner: Label


func setup(city: Node3D) -> void:
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
	_build_banner()


## True when a disaster is running (any phase before DONE).
func is_running() -> bool:
	return current != null


## Start `kind`, or a rolled one when empty. False if one is already running.
func start(kind: String = "") -> bool:
	if current != null:
		return false
	if kind == "":
		kind = _forced if _forced != "" else String(ROLL[_roll_rng.randi_range(0, ROLL.size() - 1)])
	if not KINDS.has(kind):
		push_warning("[disaster] unknown kind '%s'" % kind)
		return false
	var d: Disaster = KINDS[kind].new()
	d.name = "Disaster_%s" % kind
	add_child(d)
	current = d
	current_kind = kind
	d.finished.connect(_on_finished)
	d.begin(ctx, hash([_base_seed, count]))
	count += 1
	print("[disaster] %s begins (#%d)" % [d.title, count])
	started.emit(kind)
	_update_banner()
	return true


## End the running disaster: straight to its ENDING phase.
func stop() -> void:
	if current != null:
		current.end_now()
		_update_banner()


## The city's key handler hands H here.
func on_key(shift: bool) -> void:
	if shift:
		stop()
	else:
		start()


func _physics_process(delta: float) -> void:
	if current != null:
		current.tick(delta)


func _process(delta: float) -> void:
	ctx.step(delta)
	_update_banner()


func _on_finished() -> void:
	var kind := current_kind
	print("[disaster] %s over" % current.title)
	current.queue_free()
	current = null
	current_kind = ""
	ended.emit(kind)
	_update_banner()


func _build_banner() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
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
	layer.add_child(_banner)
	add_child(layer)


func _update_banner() -> void:
	if _banner == null:
		return
	if current == null:
		_banner.visible = false
		return
	_banner.visible = true
	_banner.text = "%s — %s  %ds   (Shift+H to end)" % [current.title.to_upper(),
			Disaster.phase_name(current.phase), ceili(current.seconds_left())]
