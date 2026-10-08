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
##   PRESENTATION    a drawing, a few storeys of rooms at a time, of whatever
##                   still has a floor under it (`InteriorGroups`).
##   MATERIALISED    an item something has hit, as bricks in the building's
##                   own chunk (`laid`) -- that item and no other.
##
## Items are measured in **the host's grid**, for the reason a staircase is
## (`Fixture`): a chair standing on a floor that breaks away has to go with it,
## and anything with a body of its own does not. It also answers Interiors §7
## question 3 -- a chair is a small cluster of blocks, so once it is hit it is
## destructible and printable by the paths that already exist.

## What the room is for. Drives the manifest, so what you find in a room is
## consistent with what the room is.
##
## APPEND ONLY. A room's kind is an index drawn from its seed, and the first
## four are what every generated building has had since rooms existed: a
## building with no program still draws from those four alone
## (`LEGACY_KINDS`), so adding a kind here changes no room anybody has seen.
## The rest are reached through a program (Docs/Workshop.md, Stage F).
const KINDS := ["storeroom", "office", "kitchen", "empty",
		"bedroom", "living", "bathroom", "lab", "shop"]
const LEGACY_KINDS := 4
## How a far window draws a room of each kind: which of the drawings in
## shaders/window_interior.gdshader it gets. One each today; a kind added later
## can borrow another's until it has its own. At most 16 (the pane packs it in
## a vertex colour channel as style / 16).
const WINDOW_STYLE := {
	"storeroom": 0, "office": 1, "kitchen": 2, "empty": 3,
	"bedroom": 4, "living": 5, "bathroom": 6, "lab": 7, "shop": 8,
}

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

## The manifest once it has been run (`RoomManifest.items_for`): a dictionary
## an item -- type, cell, yaw, and `blocks` for one laid as bricks (`laid`).
var items: Array = []
## Item index -> true, for the ones that are not coming back: destroyed, taken,
## or never placed because something was in the way. Interiors §2's diff, and
## the only thing about a room that has to be written down.
var gone := {}

## Item index -> true, for the ones that are BRICKS: laid into the building's
## chunk because a blast or a bullet reached them ([Interiors §8.4]
## (../Docs/Interiors.md); BuildingRegistry.lay_item). From then on such an
## item is ordinary brick destruction, drawn from its blocks, and no drawing
## of the room shows it. Its blocks are in `items[i].blocks`. The rest of the
## room stays a drawing: no room is ever laid whole.
var laid := {}

## Holes in this room's walls, in the building's local space. Interiors §3: the
## openings ARE the portals, and "importantly -- holes blown in the walls". A
## generated building has no doors and no windows, so every one of these was
## made by somebody shooting at it, which means an undamaged building has none
## and the portal test costs nothing until it does.
var openings: Array[AABB] = []

## How damaged the building was when the openings were last looked for. Walls
## only change when something hits them.
var openings_at := -1


## Changes whenever what a drawing of this room should show changes: an item
## written off, or one laid as bricks.
func diff_stamp() -> int:
	return gone.size() + laid.size() * 65536


func has_opening() -> bool:
	return not openings.is_empty()


func item_count() -> int:
	return items.size()


## The room's box in the building's local space, in metres.
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
