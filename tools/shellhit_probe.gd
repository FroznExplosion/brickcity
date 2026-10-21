extends "res://tools/collapse_probe.gd"

## collapse_probe's "shellhit" section, in a city of its own
## (Docs/CollapseNext.md 1.1): a damaged shell is solid where it is drawn and
## nowhere else. It needs an untouched tower of six storeys, and at the end of
## collapse_probe, about one run in two, there was none left: the "inside"
## section's toppling tower hits its neighbour, every later section then took
## the next tower along, and the last six-storey one went to a section that
## asked for four.
##
##     godot --headless --path . --script tools/shellhit_probe.gd


func _only(name: String) -> bool:
	return name == "shellhit"
