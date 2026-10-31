extends RefCounted
## Test modules for a station (room_station_probe; Docs/RoomModules.md 7.2):
## box rooms made as recipes by room_module_kit.gd, with a station's roles.

const Kit := preload("res://tools/room_module_kit.gd")


static func modules() -> Array:
	var all4 := func(along: int) -> Array:
		return [[0, along, "auto"], [1, along, "auto"], [2, along, "auto"], [3, along, "auto"]]
	return [
		Kit.box("core", 10, 10, {"role": "core", "min": 1, "max": 1}, all4.call(4)),
		Kit.box("node", 6, 6, {"role": "node", "weight": 2.0}, all4.call(2)),
		Kit.box("tube", 12, 4, {"role": "tube", "weight": 2.0}, [[0, 1, "auto"], [2, 1, "auto"]]),
		Kit.box("short tube", 4, 4, {"role": "tube"}, [[0, 1, "auto"], [2, 1, "auto"]]),
		Kit.box("pod", 14, 6, {"role": "pod", "weight": 2.0}, [[2, 2, "auto"]], [],
				[["window", [7, 4, 0], 3], ["radiator", [7, 5, 7], 1]]),
		Kit.box("truss", 10, 2, {"role": "truss"}, [[2, 1, "auto"]], [], [["panel", [11, 5, 1], 0]]),
		Kit.box("dock", 6, 6, {"role": "dock"}, [[2, 2, "auto"], [0, 2, "finish"]]),
	]
