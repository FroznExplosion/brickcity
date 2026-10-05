class_name MeteorMixed
extends MeteorShower

## A meteor shower with giants in it (Docs/Disasters.md 23): a shower of small
## rocks, and one or two giants among them -- the second, if there is one,
## late, when the streets are already broken.

func _init() -> void:
	super()
	title = "Meteor shower with giants"
	active_s = 40.0


func _roll_schedule() -> void:
	meteors.clear()
	_add_shower(rng.randi_range(25, 40), rng.randi_range(3, 4), 1.2, 2.2, 0.0)
	var giants := 1 if rng.randf() < 0.5 else 2
	_add_giant(active_s * rng.randf_range(0.35, 0.5), 7.0)
	if giants == 2:
		_add_giant(active_s * rng.randf_range(0.75, 0.9), 7.0)
	_sort()
