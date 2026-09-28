class_name Disaster
extends Node3D

## One natural disaster, from its warning to the last of its effects
## (Docs/Disasters.md section 1.2).
##
## The director owns it and calls tick() on the PHYSICS tick, never _process, so
## what it decides -- where a meteor lands, which cell catches -- comes from its
## seeded rng at the same ticks on every machine and every frame rate. Nothing
## here changes a brick directly: it asks the context, which goes through the
## world authority like a gun does.
##
## A subclass sets the three durations in _init and overrides the _on_* hooks.

enum Phase { WARNING, ACTIVE, ENDING, DONE }

signal finished

## What the banner calls it.
var title := "Disaster"
## Seconds in each phase. ACTIVE may be ended early (end_now); the others run out.
var warning_s := 5.0
var active_s := 30.0
var ending_s := 5.0

## How hard, 1 the default (Low 0.5 ... Extreme 2.5). Set by the director
## before begin(); each disaster reads it there. At 1 every disaster is exactly
## what it was before intensity existed; a seed at another intensity is its own
## (still deterministic) disaster -- more meteors draw more numbers.
var intensity := 1.0
## Per-kind settings from the menu (the earthquake's collapse caps).
var options := {}

var ctx: DisasterContext
var rng := RandomNumberGenerator.new()
var phase := Phase.WARNING
## Seconds spent in the current phase.
var phase_t := 0.0


## Set up and enter WARNING. Called once, after the node is in the tree.
func begin(context: DisasterContext, seed_value: int) -> void:
	ctx = context
	rng.seed = seed_value
	phase = Phase.WARNING
	phase_t = 0.0
	_on_begin()
	_on_phase(Phase.WARNING)


func tick(dt: float) -> void:
	if phase == Phase.DONE:
		return
	phase_t += dt
	match phase:
		Phase.WARNING:
			_tick_warning(dt)
		Phase.ACTIVE:
			_tick_active(dt)
		Phase.ENDING:
			_tick_ending(dt)
	if phase_t >= phase_length():
		_advance()


## Skip what is left of WARNING or ACTIVE and wind down. ENDING still plays --
## fires go out rather than vanish.
func end_now() -> void:
	if phase == Phase.WARNING or phase == Phase.ACTIVE:
		_enter(Phase.ENDING)


func phase_length() -> float:
	match phase:
		Phase.WARNING:
			return warning_s
		Phase.ACTIVE:
			return active_s
		Phase.ENDING:
			return ending_s
	return 0.0


func seconds_left() -> float:
	return maxf(0.0, phase_length() - phase_t)


static func phase_name(p: Phase) -> String:
	return ["warning", "active", "ending", "done"][p]


func _advance() -> void:
	match phase:
		Phase.WARNING:
			_enter(Phase.ACTIVE)
		Phase.ACTIVE:
			_enter(Phase.ENDING)
		Phase.ENDING:
			_enter(Phase.DONE)


func _enter(p: Phase) -> void:
	phase = p
	phase_t = 0.0
	_on_phase(p)
	if p == Phase.DONE:
		finished.emit()


# --- For subclasses ---------------------------------------------------------

func _on_begin() -> void:
	pass


## Entering phase `p`, DONE included: the place to free what the disaster made.
func _on_phase(_p: Phase) -> void:
	pass


func _tick_warning(_dt: float) -> void:
	pass


func _tick_active(_dt: float) -> void:
	pass


func _tick_ending(_dt: float) -> void:
	pass
