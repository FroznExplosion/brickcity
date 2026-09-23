class_name Fixture
extends RefCounted

## Something fixed to a building: a staircase, a railing, pipework.
##
## Docs/BuildMode.md section 9. A fixture is **authored** separately -- it is a
## kind, a cell and a handful of parameters rather than a pile of bricks in a
## recipe -- and it is **built into its host's own grid**, as ordinary blocks in
## the host's own chunk.
##
## That second half was learned the hard way. The first implementation gave a
## fixture a chunk, a body and a materialisation state of its own, which is what
## section 9.4 describes, and it behaved exactly like what it was: a separate
## object standing inside a building.
##
##   * A collapsing building landed on its own staircase and stopped there,
##     until the fixture was moved onto a collision layer nothing structural
##     could touch.
##   * And then a building could come down around a staircase that stayed
##     standing in the rubble, because nothing in the world connected the two.
##
## Both are the same mistake. **A staircase in a brick building is made of
## bricks, in the same grid, clipped to the floors it lands on.** Put the blocks
## in the host's chunk and the rest follows for nothing: the stress solve
## carries them, a section that breaks off takes the steps inside it, the island
## it becomes has them, the damage record already keys on block id, and a piece
## landing on the flight breaks it the way it breaks anything else.
##
## What is left here is the authoring record and the generator. Dormancy is
## **inherited rather than implemented**: a building that is still a recipe has
## no bricks at all, its staircase included.

enum Role {
	## Carries load, contributes capacity, is grounded through its host.
	STRUCTURAL,
	## Fixed to structure rather than being it. Kept because the recipe format
	## carries it and section 9.2 turns on it; nothing reads it while a
	## fixture's blocks live in the host's own grid, where they are structure by
	## construction.
	DECORATIVE,
}

var id := -1
var kind := "staircase"
var params := {}
## Where it starts, in the HOST's cells -- the same coordinates the host's own
## blocks are in, so a fixture rebases with the building and needs no transform
## of its own.
var cell := Vector3i.ZERO
var role: Role = Role.DECORATIVE
## Block ids this fixture produced the last time its host was built. For
## reporting and for the gates only: the damage record keys on block id and does
## not care which blocks came from where.
var blocks := PackedInt32Array()


func is_decorative() -> bool:
	return role == Role.DECORATIVE


## Cells this fixture occupies in its host's grid, as (min corner, size).
func bounds() -> Array:
	match kind:
		"staircase":
			return [cell, StaircaseRecipe.chunk_dims(int(params.get("steps", 8)))]
		_:
			return [cell, Vector3i.ONE]


## The volume it occupies in its host's LOCAL space, in metres.
func volume() -> AABB:
	var b := bounds()
	var lo: Vector3i = b[0]
	var size: Vector3i = b[1]
	var c := BrickWorld.get_cell_size()
	return AABB(Vector3(lo.x * c.x, lo.y * c.y, lo.z * c.z),
			Vector3(size.x * c.x, size.y * c.y, size.z * c.z))


## Lay the bricks into the host's chunk. `offset` is the host's own rebase, so
## that a fixture moves with the bricks it was authored against.
##
## Called at a FIXED point in the host's build order -- after its own blocks --
## because block ids are the contract the damage record rides on, and an id has
## to mean the same brick every time the building is rebuilt.
func build_into(world: BrickWorld, chunk: int, parts: PackedInt32Array,
		offset: Vector3i = Vector3i.ZERO) -> int:
	blocks = PackedInt32Array()
	match kind:
		"staircase":
			var steps := int(params.get("steps", 8))
			var at := cell - offset
			_carve(world, chunk, at, StaircaseRecipe.chunk_dims(steps))
			var first := world.get_block_count(chunk)
			var placed := StaircaseRecipe.build(world, chunk, parts,
					steps, int(params.get("colour", 11)), at)
			for i in range(first, world.get_block_count(chunk)):
				blocks.push_back(i)
			return placed
		_:
			push_error("Fixture: no generator for kind '%s'" % kind)
			return 0


## Free the cells the fixture is about to fill.
##
## A staircase needs a STAIRWELL: the floors it passes through are the
## building's own blocks, and without this three steps of a twenty-seven step
## flight were simply refused -- a staircase with a landing missing wherever a
## floor crossed it.
##
## `remove_block` and not `kill_block`: this is an EDIT, not damage. The cells
## come back, the ids stay (a tombstone keeps its id, so the damage record is
## untouched), and `get_dead_blocks` leaves a removed block out -- which is what
## stops a stairwell from reading as a hole somebody shot.
##
## A floor plate is 4x4 and the shaft is 8x8, so a plate that only clips the
## shaft is removed whole. The hole is therefore a little wider than the flight,
## which is what a stairwell looks like anyway.
static func _carve(world: BrickWorld, chunk: int, at: Vector3i, dims: Vector3i) -> int:
	var seen := {}
	var removed := 0
	for y in range(at.y, at.y + dims.y):
		for z in range(at.z, at.z + dims.z):
			for x in range(at.x, at.x + dims.x):
				var found := world.block_at(chunk, Vector3i(x, y, z))
				if found < 0 or seen.has(found):
					continue
				seen[found] = true
				if world.remove_block(chunk, found):
					removed += 1
	return removed


## Where this fixture needs the building to leave room, in studs.
##
## Asked by TowerRecipe BEFORE it lays its columns. A staircase is a shaft the
## full height of the building, and a shaft up the middle is exactly where the
## columns carrying the floor want to stand -- removing them afterwards left the
## panel above holding on to nothing.
func footprint() -> Rect2i:
	match kind:
		"staircase":
			return Rect2i(cell.x, cell.z,
					StaircaseRecipe.DIAMETER, StaircaseRecipe.DIAMETER)
	return Rect2i()
