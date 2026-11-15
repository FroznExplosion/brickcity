extends RefCounted
## Test modules for a station (room_station_probe; Docs/RoomModules.md 7.2): the
## game's own station kit (scripts/rooms/station_kit.gd), built to hold in space.


static func modules() -> Array:
	return StationKit.modules()
