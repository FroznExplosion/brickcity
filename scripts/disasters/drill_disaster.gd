class_name DrillDisaster
extends Disaster

## A disaster that changes nothing: it runs every phase, and in ACTIVE gives the
## view a light tremor once a second. What the director and the probe are
## checked with (`--disaster=drill`), and what the roll falls back to while no
## real disaster is built.

var _next_tremor := 0.0


func _init() -> void:
	title = "Drill"
	warning_s = 3.0
	active_s = 5.0
	ending_s = 2.0


func _tick_active(_dt: float) -> void:
	if phase_t >= _next_tremor:
		_next_tremor = phase_t + 1.0
		ctx.shake(ctx.player_pos(), 0.08)


func _on_phase(p: Phase) -> void:
	if p == Phase.ACTIVE:
		_next_tremor = 0.0
