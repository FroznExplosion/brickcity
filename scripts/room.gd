class_name Room
extends RefCounted

## A named volume in a building's own grid, and what is in it.
##
## [Interiors §2](../Docs/Interiors.md). A room is generated from the building's
## recipe rather than authored, so it costs nothing to have: an id, a box in
## cells, a kind and a seed. Its **contents** are generated from
## `(building seed, room id)` on demand, which is the same
## parametric-until-touched trick the buildings themselves use, one level down.
##
##   TRUTH           the room and its seed. Bytes, and generated at that.
##   MATERIALISED    the items, as bricks in the building's own chunk.
##   PRESENTATION    the building's mesh and body, which already draw them.
##
## Items are **bricks in the host's grid**, for the reason a staircase is
## (`Fixture`): a chair standing on a floor that breaks away has to go with it,
## and anything with a body of its own does not. It also answers Interiors §7
## question 3 -- a chair is a small cluster of blocks, so it is destructible,
## printable and spillable by the paths that already exist.

## What the room is for. Drives the manifest, so what you find in a room is
## consistent with what the room is.
const KINDS := ["storeroom", "office", "kitchen", "empty"]

var id := -1
var kind := "storeroom"
## Cells, in the building's own grid: the floor corner and the size.
var lo := Vector3i.ZERO
var size := Vector3i.ONE
## The columns standing IN this room, in plan, in the building's own grid.
##
## A column runs the full height of the storey from this room's own floor, so
## it is not scenery to be drawn round -- it is the room's furniture refusing to
## place. Without this, three items in four landed inside one.
var posts: Array[Rect2i] = []
## Named `room_seed`, not `seed`: the bare name shadows GDScript's own
## `seed()` and the warning is worth heeding — a call to it inside this class
## would silently hit the property instead.
var room_seed := 0

## Materialised state. `items` is the manifest once it has been run; `blocks`
## holds what each item actually laid, so deactivating can take it back out.
var active := false
var items: Array = []
## DRAWN: the manifest on screen and one collision box per item, with not a
## single block laid. [Scale §4.1](../Docs/Scale.md) rung 2 -- furniture nobody
## has touched, which is nearly all of it. Mutually exclusive with `active`: a
## room is shut, drawn or real, and promotion from drawn to real is what
## touching it does.
var drawn := false
## What drawing it takes, worked out once when it is drawn: a MultiMesh buffer
## row per item part (`FurnitureMesh.STRIDE` floats each), and one box per
## item in the chunk's own metres. Both empty while the room is not drawn.
var drawn_buffer := PackedFloat32Array()
var drawn_boxes: Array[AABB] = []
## Real because a blast reached it, not because somebody walked in. Such a room
## holds half-broken furniture, and a drawing can only show an item whole or
## not at all -- so it stays real until the old sleep range rather than
## demoting to drawn the moment the player steps back. Cleared when it closes,
## which is when its diff is written.
var hit := false
## Item index -> true, for the ones that are not coming back: destroyed, taken,
## or never placed because something was in the way. Interiors §2's diff, and
## the only thing about a room that has to be written down.
var gone := {}

## Holes in this room's walls, in the building's local space. Interiors §3: the
## openings ARE the portals, and "importantly -- holes blown in the walls". A
## generated building has no doors and no windows, so every one of these was
## made by somebody shooting at it, which means an undamaged building has none
## and the portal test costs nothing until it does.
var openings: Array[AABB] = []
## The building came down while this room held nothing -- so its contents were
## never built, and what happens to them is Interiors §4.1's question. A
## spilled room resolves into the wreckage when somebody arrives, rather than
## having been simulated while nobody was watching (§5.2).
var spilled := false

## How damaged the building was when the openings were last looked for. Walls
## only change when something hits them.
var openings_at := -1


func has_opening() -> bool:
	return not openings.is_empty()


func item_count() -> int:
	return items.size()


## Stop drawing it. The manifest and the diff stay; only the drawing goes.
func clear_drawing() -> void:
	drawn = false
	drawn_buffer = PackedFloat32Array()
	drawn_boxes = []


## The room's box in the building's local space, in metres.
## How far a point in the BUILDING's own space is from this room, in metres.
##
## The same answer as measuring against `world_box`, and it allocates nothing
## and transforms nothing. That matters because it is the inner loop of room
## streaming: standing inside one of the big shapes, a pass measures a thousand
## rooms, and building a world AABB for each -- eight matrix multiplies and an
## allocation -- was 12 ms of a 15 ms pass.
func local_distance(p: Vector3) -> float:
	var c := BrickWorld.get_cell_size()
	var dx := maxf(maxf(lo.x * c.x - p.x, p.x - (lo.x + size.x) * c.x), 0.0)
	var dy := maxf(maxf(lo.y * c.y - p.y, p.y - (lo.y + size.y) * c.y), 0.0)
	var dz := maxf(maxf(lo.z * c.z - p.z, p.z - (lo.z + size.z) * c.z), 0.0)
	return sqrt(dx * dx + dy * dy + dz * dz)


func local_box() -> AABB:
	var c := BrickWorld.get_cell_size()
	return AABB(Vector3(lo.x * c.x, lo.y * c.y, lo.z * c.z),
			Vector3(size.x * c.x, size.y * c.y, size.z * c.z))


## The same box in the world, under a building's placement.
func world_box(xform: Transform3D) -> AABB:
	var b := local_box()
	var out := AABB(xform * b.position, Vector3.ZERO)
	for i in range(1, 8):
		out = out.expand(xform * (b.position + Vector3(
				b.size.x if (i & 1) else 0.0,
				b.size.y if (i & 2) else 0.0,
				b.size.z if (i & 4) else 0.0)))
	return out


## Has anything in this room been disturbed? An untouched room needs no record
## at all (Interiors §5.4).
func is_changed() -> bool:
	return not gone.is_empty()
