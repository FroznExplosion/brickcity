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
	var g := Gravity.strength() \
			* isl.body.gravity_scale
	var ahead := box
	ahead.position += v * HORIZON + Gravity.down_at(box.get_center()) * 0.5 * g * HORIZON * HORIZON
	# It stops at the ground; what matters is the column it comes down through.
	# (The flat game's ground plane; on a planet the box runs on through it.)
	if Gravity.planet == null:
		ahead.position.y = maxf(ahead.position.y, minf(box.position.y, 0.0))
	return box.merge(ahead).grow(MARGIN)


## The pieces' danger ids set last time: only those are taken down again, so
## the danger others keep there (Airspace's landing pads) stays.
static var _ids: Array[int] = []


## Every big piece still moving, as danger boxes in `ai_world`.
static func update(ai_world: AIWorld, islands: IslandManager) -> void:
	for id in _ids:
		ai_world.remove_danger(id)
	_ids.clear()
	for isl in islands.islands:
		if isl.is_valid() and not isl.settled and not isl.disposable:
			ai_world.set_danger(isl.chunk, of_piece(islands, isl))
			_ids.append(isl.chunk)
