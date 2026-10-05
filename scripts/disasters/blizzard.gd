class_name Blizzard
extends Snowfall

## A blizzard (Docs/Disasters.md 21): a snowfall with a gale in it. The snow
## comes sideways and thick enough to white the view out, lies twice as fast,
## and the wind leans on whoever is out in it (DebugCamera.wind) and sways the
## trees hard. Soldiers can hardly see (sight to the floor of 60%) and can
## hardly aim. Everything else -- the cover, the caps, the melt -- is the
## snowfall's.

func _init() -> void:
	super()
	title = "Blizzard"
	warning_s = 6.0
	active_s = 70.0
	ending_s = 12.0
	wind_k = 1.1
	drift = 11.0
	push = 2.0
	haze = 0.62
	sight = 0.6
	aim = 2.2
	rate_mul = 1.8
	flake_count = 16000
	flake_size = 0.06
	flake_life = 3.5
