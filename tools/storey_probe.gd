extends "res://tools/collapse_probe.gd"

## collapse_probe's "storeys" section, in a city of its own: what is left of a
## storey has to carry what is above it (BrickWorld.gravity_check,
## CityScene._gravity_fail). It needs three untouched towers of four and five
## storeys, and at the end of collapse_probe there were none left.
##
##     godot --headless --path . --script tools/storey_probe.gd


func _only(name: String) -> bool:
	return name == "storeys"
