class_name MeteorStorm
extends MeteorShower

## A heavy meteor shower (Docs/Disasters.md 23): two to three times the rocks,
## bigger, in five or six bursts over 45 s, a quarter of them big.

func _init() -> void:
	super()
	title = "Heavy meteor shower"
	active_s = 45.0


func _roll_schedule() -> void:
	meteors.clear()
	_add_shower(rng.randi_range(70, 100), rng.randi_range(5, 6), 2.0, 3.6, 0.25)
	_sort()
