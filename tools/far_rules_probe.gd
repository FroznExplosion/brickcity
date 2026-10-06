extends "res://tools/collapse_probe.gd"

## collapse_probe's "farrules" section, in a city of its own
## (Docs/CollapseNext.md 1.8): far from everybody a piece under ten bricks is
## deleted where it breaks off; no room is drawn, faked or opened in a building
## that is coming apart; and a fallen building's rooms are not spilled into
## wreckage still moving.
##
##     godot --headless --path . --script tools/far_rules_probe.gd


func _only(name: String) -> bool:
	return name == "farrules"
