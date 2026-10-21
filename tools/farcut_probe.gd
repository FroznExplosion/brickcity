extends "res://tools/collapse_probe.gd"

## collapse_probe's "farcut" section, in a city of its own: a building cut from
## past the shell range is drawn once, and one given back mid-bands is drawn
## from its bricks as they are. It takes two untouched towers, the second
## late, and at the end of collapse_probe about one run in three there was
## none left (wreckage of earlier sections, a top leaving as a shell piece).
##
##     godot --headless --path . --script tools/farcut_probe.gd


func _only(name: String) -> bool:
	return name == "farcut"
