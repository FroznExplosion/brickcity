class_name Danger
extends RefCounted
## Where not to stand (Docs/AI.md 3.5): a falling piece is a danger volume, its
## box swept along where it is GOING -- velocity and gravity over the next second
## and a half, stopped at the ground -- so a soldier under a piece ten metres up
## moves before it has picked up any speed, not once it is about to land.

const HORIZON := 1.5
const MARGIN := 0.75


static func of_piece(islands: IslandManager, isl: BrickIsland) -> AABB:
	var box := islands.world_aabb(isl)
	var v := isl.body.linear_velocity
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) \
			* isl.body.gravity_scale
	var ahead := box
	ahead.position += v * HORIZON + Vector3.DOWN * 0.5 * g * HORIZON * HORIZON
	# It stops at the ground; what matters is the column it comes down through.
	ahead.position.y = maxf(ahead.position.y, minf(box.position.y, 0.0))
	return box.merge(ahead).grow(MARGIN)


## Every big piece still moving, as danger boxes in `ai_world`.
static func update(ai_world: AIWorld, islands: IslandManager) -> void:
	ai_world.clear_danger()
	for isl in islands.islands:
		if isl.is_valid() and not isl.settled and not isl.disposable:
			ai_world.set_danger(isl.chunk, of_piece(islands, isl))
