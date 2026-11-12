extends RefCounted
## Test modules for the room-module probes (room_grow_probe, module_marks_probe):
## box rooms of 1x1 plates made as recipes, their rooms found and marked.
## Docs/RoomModules.md.

const H := 12
const DOOR := Vector2i(2, 9)


## A box room W x D inside, H high, walls one stud: floor y 0, ceiling y H + 1.
## doors: [[side, along, link]] (side 0 +X, 1 +Z, 2 -X, 3 -Z; along from 1);
## windows: [[side, along, y0, w, h]]; marks: [[kind, [x, y, z], facing]].
static func box(name: String, w: int, d: int, rules: Dictionary, doors: Array, windows := [],
		marks := []) -> BuildRecipe:
	var r := BuildRecipe.new()
	r.name = name
	var hole := {}
	var link_at := {}
	var wall_cell := func(side: int, along: int, y: int) -> Vector3i:
		match side:
			0: return Vector3i(w + 1, y, along)
			1: return Vector3i(along, y, d + 1)
			2: return Vector3i(0, y, along)
		return Vector3i(along, y, 0)
	for dr in doors:
		for a in DOOR.x:
			for y in range(1, DOOR.y + 1):
				hole[wall_cell.call(dr[0], int(dr[1]) + a, y)] = true
		link_at[wall_cell.call(dr[0], int(dr[1]), 1)] = String(dr[2])
	for wn in windows:
		for a in int(wn[3]):
			for y in range(int(wn[2]), int(wn[2]) + int(wn[4])):
				hole[wall_cell.call(wn[0], int(wn[1]) + a, y)] = true
	for x in w + 2:
		for z in d + 2:
			r.add("plate_1x1", Vector3i(x, 0, z), 2, 0)
			r.add("plate_1x1", Vector3i(x, H + 1, z), 2, 0)
			if x == 0 or z == 0 or x == w + 1 or z == d + 1:
				for y in range(1, H + 1):
					if not hole.has(Vector3i(x, y, z)):
						r.add("plate_1x1", Vector3i(x, y, z), 2, 0)
	var rec := StructureSpaces.empty()
	@warning_ignore("integer_division")
	rec.spaces = [{"id": 0, "kind": "office", "frame": 0, "seed": [w / 2, 1, d / 2]}]
	r.meta["structure"] = rec
	r.meta["module"] = rules.merged({"on": true})
	rec = RoomModules.refresh(r)
	for o in rec.openings:
		for c in o.cells:
			var v := Vector3i(int(c[0]), int(c[1]), int(c[2]))
			if link_at.has(v):
				o.link = link_at[v]
	for mk in marks:
		rec.marks.append({"kind": mk[0], "space": 0, "at": mk[1], "facing": mk[2]})
	r.meta["structure"] = rec
	return r


static func modules() -> Array:
	return [
		box("hall", 10, 10, {"role": "start", "max": 1},
				[[2, 4, "start"], [0, 4, "auto"], [1, 4, "auto"], [3, 4, "auto"]]),
		box("cross", 10, 10, {"role": "room", "weight": 2.0},
				[[0, 4, "auto"], [1, 4, "auto"], [2, 4, "auto"], [3, 4, "auto"]], [[1, 8, 4, 2, 4]]),
		box("corridor", 16, 4, {"role": "corridor"}, [[0, 1, "auto"], [2, 1, "auto"]]),
		box("vault", 8, 8, {"role": "finish"}, [[2, 3, "auto"], [0, 3, "finish"]]),
		box("stairs", 10, 10, {"role": "stair"}, [[2, 4, "auto"], [0, 4, "auto"]], [],
				[["stair_up", [8, H, 5], -1]]),
		box("loft", 10, 10, {"role": "room", "storeys": "upper"}, [], [],
				[["stair_down", [8, 1, 5], -1]]),
		box("tower", 8, 8, {"role": "room"}, [[2, 3, "auto"]], [],
				[["hang", [4, 5, 9], 1], ["balcony", [4, 5, 0], 3]]),
		box("nook", 4, 4, {"role": "hang"}, [[2, 1, "auto"]]),
	]
