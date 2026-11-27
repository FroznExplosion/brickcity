class_name MineSurvival
extends Node
## Health, death and coming back in the mine world (Docs/MineCreatures.md 11).
##
##   health    the player's pawn's HealthPool (100). In SURVIVAL zombies,
##             wolves and boars take from it (MineMobs.hurt_player), as do
##             falls and lava (Pawn, as before). It comes back by itself,
##             REGEN a second once REGEN_DELAY has passed with no harm.
##   death     "You died" for RESPAWN_AFTER seconds, the body held; then back
##             at the world's spawn with full health. The inventory is KEPT
##             (nothing is dropped): what dying costs is the walk back.
##   creative  monsters only shove; dying (lava, a fall) still brings you back.

const REGEN := 0.5
const REGEN_DELAY := 6.0
const RESPAWN_AFTER := 3.0

var host: Node = null
var deaths := 0
var dead := false
## Where the last death was (terrain frame), for the readout and gates.
var died_at := Vector3.INF
var _hooked = null
var _dead_t := 0.0
var _label: Label = null


func setup(p_host: Node) -> void:
	host = p_host
	name = "Survival"
	var layer: CanvasLayer = host.get("_hud_layer")
	if layer != null:
		_label = Label.new()
		_label.name = "DeathLabel"
		_label.set_anchors_preset(Control.PRESET_CENTER)
		_label.offset_left = -300.0
		_label.offset_right = 300.0
		_label.offset_top = -60.0
		_label.offset_bottom = 0.0
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.add_theme_font_size_override(&"font_size", 44)
		_label.add_theme_color_override(&"font_color", Color(0.9, 0.15, 0.1))
		_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
		_label.add_theme_constant_override(&"outline_size", 8)
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.visible = false
		layer.add_child(_label)


func step(delta: float) -> void:
	var p: Pawn = host.get("pawn")
	if p == null or not is_instance_valid(p) or p.health == null:
		return
	if p != _hooked:
		_hooked = p
		for cfg in p.health.layer_configs:
			if (cfg as DefenseLayer).layer_type == &"health":
				cfg.regen_rate = REGEN
				cfg.regen_delay = REGEN_DELAY
		p.health.died.connect(_on_died)
	if dead:
		_dead_t += delta
		if _label != null:
			_label.text = "You died\nback in %d" % ceili(RESPAWN_AFTER - _dead_t)
		if _dead_t >= RESPAWN_AFTER:
			respawn()


func _on_died() -> void:
	if dead:
		return
	dead = true
	deaths += 1
	_dead_t = 0.0
	died_at = host.player_feet_local()
	var p: Pawn = host.pawn
	p.frozen = true
	if _label != null:
		_label.visible = true
	print("[survival] the player died at %s (%d deaths)" % [died_at, deaths])


## Back at the world's spawn, whole.
func respawn() -> void:
	var p: Pawn = host.pawn
	var stud := BrickWorld.get_stud_metres()
	var sp: Vector2 = host.get("spawn_xz")
	var c := Vector2i(floori(sp.x / stud), floori(sp.y / stud))
	var feet := Vector3(sp.x, float(host._ground_m(c.x, c.y)) + 0.05, sp.y)
	host.set_on_foot(true, feet)
	p.health.reset()
	p.frozen = false
	p.shove = Vector3.ZERO
	dead = false
	if _label != null:
		_label.visible = false
	print("[survival] back at the spawn %s" % feet)
