class_name BrickIsland
extends RefCounted

## A detached piece of structure, carried by a rigid body.
##
## The island IS a chunk in BrickWorld -- same grid, same archetypes, same
## connectivity -- so everything that works on a building works on a piece of
## one. That is what lets it be shot at, re-solved and broken apart again when
## it lands. A bag of boxes could do none of those.
##
## Collision goes on the body's RID rather than as CollisionShape3D children.
## 633 shapes as nodes measured 1.8 SECONDS to spawn; the same shapes on the RID
## are milliseconds, and it is the same lesson as the static body: shapes go on
## before the body joins a space.

var chunk := -1
## Which piece this is, the same number on every machine: the seq of the command
## that created it (DamageLog.piece_id). -1 for a piece nothing recorded.
var piece_id := -1
## The building it came from.
var owner := -1
var body: RigidBody3D
var mesh: MeshInstance3D
## The surface whose index bytes get patched in place. Held separately because
## MeshInstance3D.mesh is typed Mesh, and losing this reference is what forces a
## full vertex re-upload.
var array_mesh: ArrayMesh
## Band meshes inherited from a building that toppled whole (city_scene
## SECTION_PLATES). They already hold the right geometry, so a piece that has
## just come down draws for nothing; damage PATCHES them, band by band, as it
## does a standing building's (IslandManager._patch_bands). Only a change a
## patch cannot carry frees them and makes it an ordinary one-mesh island.
var bands: Array = []
## Each band's index buffer size in bytes, as the building had it: a band can
## be patched only while its buffer is the length it was built at.
var band_bytes: Array = []
## Size of that surface's index buffer, in bytes. A patch is only valid
## while the buffer is the length it was built at.
var index_bytes := 0
## 2 or 4: the width that surface stores indices at.
var index_width := 4
var local_com := Vector3.ZERO
## Half the diagonal of this piece's bounding box. A cheap sphere test with it
## rejects most islands before anything has to build a world-space AABB, which
## matters because every hit used to ask every island whether it was in range.
var radius := 0.0
## block id -> the shape indices it owns on the body. A shaped part contributes
## more than one, so this cannot be an identity map the way the static chunk's is.
var shape_map := {}
var shape_count := 0
## Its collision is merged boxes that ignore block identity, so no block can
## be disabled on its own. Anything that damages this piece has to rebuild
## the shapes per block first.
var merged := false
## It FALLS with merged collision: a big piece carries as few boxes as its shape
## allows from the moment it breaks off, not one per brick (IslandManager.
## MERGE_FALLING_BLOCKS). Whatever changes its blocks while it is moving marks
## it `reshape_due`, and it is rebuilt merged once, at the end of the tick.
var fly_merged := false
var reshape_due := false
## Bumped by every change to its blocks (IslandManager._touched). A capture
## spread over several ticks is only good if nothing changed while it ran.
var edits := 0
## Being captured to go to sleep, a slice a tick. See IslandManager._sleep_or_begin.
var capturing := false
var prev_speed := 0.0
var peak_speed := 0.0
var max_speed_lost := 0.0
var born_ms := 0
var settled := false
## When it came to rest, for the debris cap's eviction order. `born_ms` is when
## it was CUT, which for a piece that tumbled for ten seconds is a different
## thing -- and what "oldest debris" means is oldest at rest, not first cut.
var settled_ms := 0
## Blocks it held when it settled. Cached because the cap sorts on it every
## time it runs and asking the world costs a call per island.
var settled_blocks := 0
## Small enough to be swept up after a few seconds. Big sections never are --
## a piece that stays intact is what the whole model exists to produce.
var disposable := false
## Big enough to hide behind or stand on (IslandManager.is_landmark_size). The
## opposite of disposable except for a fixture made rubble on purpose.
var landmark := false
## When a small piece came to rest, for sweeping it up moments later; 0 while
## it is moving.
var rest_since := 0
## When this piece last dropped under IslandManager.SETTLE_SPEED and stayed
## there; 0 while it is moving faster. What settles it by rule rather than by
## waiting for the physics to call it asleep.
var slow_since := 0
## Non-zero when this island is a single brick drawn from a shared MultiMesh
## rather than its own MeshInstance3D. The key is the brick's box size.
var mm_key := Vector3.ZERO
var mm_colour := Color.WHITE

## Set whenever this island loses blocks. Only then is it worth asking the
## extension how many it has left -- that question walks every block in the
## chunk, and asking it for every island every tick was most of a frame at 373
## islands.
var changed := true
## Already waiting in the landing queue; do not queue it twice.
var fracture_queued := false
## Physics ticks this piece has existed with a MeshInstance3D and nothing in it
## -- i.e. ticks spent invisible. Reset when it finally gets geometry.
var blind_ticks := 0
## Do not rebuild this piece's mesh before this process frame: a child it shed
## is still coming up, and until it has, these bricks are drawn by nobody else.
var hold_until := -1
var fractures := 0   ## times damage split this island
var impacts := 0     ## times it landed hard enough to lose blocks
## Times it has come back from sleep. Diagnostic: a piece that has been through a
## ChunkRecord round trip is the first suspect when it disagrees with a replay.
var wakes := 0


func is_valid() -> bool:
	return chunk >= 0 and is_instance_valid(body)


## Body space and chunk space differ by the centre-of-mass offset, because the
## body is positioned AT the centre of mass and its shapes are laid out around
## the origin. Everything that converts between them goes through here.
func chunk_transform() -> Transform3D:
	return body.global_transform * Transform3D(Basis(), -local_com)


func chunk_to_world(local: Vector3) -> Vector3:
	return chunk_transform() * local


func world_to_chunk(world_point: Vector3) -> Vector3:
	return chunk_transform().affine_inverse() * world_point


## Take these blocks' collision out of the body.
##
## The body is lifted out of its space first. `body_set_shape_disabled` costs
## time proportional to the body's shape count while the body is IN a space, so
## disabling a thousand shapes in a loop is quadratic -- the same trap the
## static chunk bodies hit, and the reason breaking a large fallen section
## stalled the game.
func disable_blocks(ids: PackedInt32Array, space: RID = RID()) -> void:
	if ids.is_empty():
		return
	# Merged boxes span blocks, so there is no one block's shape to switch
	# off. A piece that is merged at this point is falling merged, and is
	# rebuilt whole at the end of the tick (IslandManager._flush_reshapes).
	if merged:
		return
	var rid := body.get_rid()
	var was_space := PhysicsServer3D.body_get_space(rid) if space == RID() else space
	if was_space.is_valid():
		PhysicsServer3D.body_set_space(rid, RID())
	for bid in ids:
		if not shape_map.has(bid):
			continue
		for shape_index in shape_map[bid]:
			PhysicsServer3D.body_set_shape_disabled(rid, shape_index, true)
	if was_space.is_valid():
		PhysicsServer3D.body_set_space(rid, was_space)
		# Rejoining a space is a teleport as far as interpolation is concerned,
		# even though the body has not moved a millimetre. Without this the
		# interpolator blends it in from whatever transform it held before the
		# lift -- for one frame the piece is drawn somewhere else entirely,
		# which reads as it vanishing at the exact moment it is shot.
		#
		# Same reasoning as the spawn path in IslandManager, which already does
		# this; damage is just a second door into the same problem.
		body.reset_physics_interpolation()
		if mesh != null:
			mesh.reset_physics_interpolation()
