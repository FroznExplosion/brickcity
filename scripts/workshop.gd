extends Node3D

## The building workshop (Docs/BuildMode.md section 11, Docs/BuildTools.md):
##
##     godot --path . res://scenes/workshop.tscn
##
## Its bricks, frames, recipe, aiming, undo, HUD and menus are a BrickBench
## (scripts/workshop/brick_bench.gd), the component the asset workshop owns too; its tools
## (Draw, Roof, Stairs, Cut, Repeat, Select, Rooms) are WorkshopTools, which the bench makes
## when `wants_tools` is on, and the shared ones are the editor kit's (addons/workshop_kit).
## This scene owns the bench and hands it Godot's calls. `-- --gate` is the bench's gate.

var bench := BrickBench.new()


func _ready() -> void:
	bench.name = "Bench"
	add_child(bench)
	bench.bind_host(self)
	bench.bench_ready()


func _process(dt: float) -> void:
	bench.bench_process(dt)


func _input(e: InputEvent) -> void:
	bench.bench_input(e)


func _unhandled_input(e: InputEvent) -> void:
	bench.bench_unhandled_input(e)


## The pause menu asks the scene (brickcity_menu_host.gd).
func pause_allowed() -> bool:
	return bench.pause_allowed()
