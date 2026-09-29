class_name CityRooms
extends RefCounted
## A city building's room, made into what a squad clears it by (RoomTactics,
## BTPlayClearRoom): the room's box in the building's placement, and a way in.
##
## The city's rooms are boxes in each building's own grid (Room.local_box); its
## openings are the holes in the room's walls, found from the bricks
## (BuildingRegistry.openings_of) -- windows cut high in every storey, and
## whatever somebody blew. Only a WALKABLE one is a way in: from the floor up, a
## body high. With none, the opening is {} and the play makes a door of its own
## (mouse-holing), which is what a squad does to a sealed tower anyway.

## A way in starts this close to the floor and is at least this tall.
const SILL := 0.35
const HEADROOM := 1.5


## The room at `point` and a way into it: {"room": RoomTactics, "opening": {} or
## {center, inward, width, thick}, "building": id, "index": room index}, or {}
## when `point` is in no materialised building's room. `city` is the city scene.
static func at(city: Node, point: Vector3) -> Dictionary:
	var reg: BuildingRegistry = city.registry
	for id in city._near_buildings(point, 1.0):
		var b: BuildingRegistry.Building = reg.get_building(id)
		if b == null or b.toppled or b.is_build() or not b.is_materialised():
			continue
		var local: Vector3 = b.xform.affine_inverse() * point
		for i in reg.rooms_in_range(id, point, 0.5):
			var room: Room = reg.get_room(id, i)
			if room == null:
				continue
			var lb := room.local_box()
			if local.x < lb.position.x or local.x > lb.end.x or local.z < lb.position.z \
					or local.z > lb.end.z or local.y < lb.position.y - 0.3 or local.y > lb.end.y:
				continue
			return {"room": RoomTactics.make(b.xform, lb, id * 10000 + i),
					"opening": _way_in(reg, id, i, lb, b.xform), "building": id, "index": i}
	return {}


## The widest walkable hole in the room's walls, as RoomTactics wants it.
static func _way_in(reg: BuildingRegistry, id: int, index: int, lb: AABB, xf: Transform3D) -> Dictionary:
	var best := {}
	var best_w := 0.0
	var mid := lb.get_center()
	for hole in reg.openings_of(id, index):
		var h: AABB = hole
		if h.position.y > lb.position.y + SILL or h.size.y < HEADROOM:
			continue
		# The thin axis of the hole is the wall's thickness; the long one runs
		# along the wall. Inward is from the hole towards the room's middle.
		var across_x := h.size.x < h.size.z
		var width := h.size.z if across_x else h.size.x
		var thick := h.size.x if across_x else h.size.z
		if width < 0.9 or width <= best_w:
			continue
		var c := h.get_center()
		var inward := Vector3(signf(mid.x - c.x), 0.0, 0.0) if across_x \
				else Vector3(0.0, 0.0, signf(mid.z - c.z))
		best_w = width
		best = {"center": xf * Vector3(c.x, lb.position.y, c.z),
				"inward": (xf.basis * inward).normalized(), "width": width, "thick": thick}
	return best
