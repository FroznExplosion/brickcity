class_name Ladder
extends Node3D

## A ladder to climb (Docs/RoomModules.md 7.13): a node at the foot of its face,
## its Y up the ladder, its +Z out of the face toward whoever climbs it, `width`
## across and `height` up, m. PawnMoves climbs one it is pushed into; at its top
## the climber goes over it, on to what it leads to.
##
## A build's ladders are `meta.ladders` ([{at, facing, w, h}]: the low corner
## cell of its face's first column, the facing out of it, studs across, plates
## up); `place` puts a node for each under the node the build is laid in.

const GROUP := &"ladder"
## How far out of its face a body may stand and take it, m.
const REACH := 0.8

var width := 1.0
var height := 2.0


func _init() -> void:
	add_to_group(GROUP)


## The ladder whose face `feet` stands at -- across it, up to REACH out, from
## just under its foot to its top -- null for none.
static func at(tree: SceneTree, feet: Vector3) -> Ladder:
	for n in tree.get_nodes_in_group(GROUP):
		var l := n as Ladder
		if l == null or not l.is_inside_tree():
			continue
		var p := l.global_transform.affine_inverse() * feet
		if absf(p.x) < l.width * 0.5 + 0.1 and p.z > -0.1 and p.z < REACH \
				and p.y > -0.6 and p.y < l.height + 0.1:
			return l
	return null


## Feet `feet` in this ladder's frame.
func local(feet: Vector3) -> Vector3:
	return global_transform.affine_inverse() * feet


## A node for each of `recipe`'s ladders under `parent`, whose frame is the
## build's (cell c at (c - origin) * cell size). Returns how many.
static func place(parent: Node3D, recipe: BuildRecipe) -> int:
	var list: Array = recipe.meta.get("ladders", [])
	var org := recipe.origin()
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	for d: Dictionary in list:
		var fd: Vector2i = StructureSpaces.FACINGS[int(d.facing)]
		var out := Vector3(fd.x, 0.0, fd.y)
		var across := Vector3(absi(fd.y), 0.0, absi(fd.x))
		var c := BuildRecipe.cell_from(d.at) - org
		var w := int(d.w)
		# The face's middle, on its out side, at its foot.
		var foot := (Vector3(c) + Vector3(0.5, 0.0, 0.5) + across * (w - 1) * 0.5 + out * 0.5) \
				* Vector3(stud, plate, stud)
		var l := Ladder.new()
		l.name = "Ladder"
		l.width = w * stud
		l.height = int(d.h) * plate
		l.transform = Transform3D(Basis(out.cross(Vector3.UP).normalized() * -1.0, Vector3.UP, out), foot)
		parent.add_child(l)
	return list.size()
