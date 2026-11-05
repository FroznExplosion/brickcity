class_name GhostHulls
extends RefCounted
## The ghost hulls (Docs/Hulls.md 7b): one physics space of its own, never the
## world's, where each generated ship's brick collision stands still in a slot of
## its own (SLOT metres from the next), built once and edited only by damage and
## repair. Whoever walks a moving ship walks its ghost -- still ground, nothing to
## rebuild when the ship turns, rocks or the origin shifts -- and is drawn on the
## real ship at the same ship-local place: real = ship.ghost_to_real() * ghost.
##
## Owned by the PlanetSystem, which outlives any one planet's sleep.

## Between two ships' slots, metres along X: far past any ship's size, near enough
## to the space's origin that a float keeps millimetres.
const SLOT := 2000.0

var space := RID()
var _slots := {}   ## station -> slot index
var _free: Array[int] = []
var _next := 0


func _init() -> void:
	space = PhysicsServer3D.space_create()
	# Only characters move in it, and they bring their own gravity (their ship's
	# down); the space's own pulls nothing that is there.
	PhysicsServer3D.space_set_active(space, true)


## Ship `st`'s slot: the transform its ghost's frame stands at in the space.
func slot_of(st: Object) -> Transform3D:
	var i: int = _slots.get(st, -1)
	if i < 0:
		i = _free.pop_back() if not _free.is_empty() else _take()
		_slots[st] = i
	return Transform3D(Basis(), Vector3(float(i) * SLOT, 0.0, 0.0))


func _take() -> int:
	_next += 1
	return _next - 1


func release(st: Object) -> void:
	if _slots.has(st):
		_free.append(int(_slots[st]))
		_slots.erase(st)


func slots_used() -> int:
	return _slots.size()


## Onto ship `st`'s ghost: `body` (a character, in the world) taken into the ghost
## space at the same ship-local place, its velocity made the deck's -- what it had
## less what the deck under it has, turned into the ship's frame. Marked "ghosted",
## so an origin shift or a frame's travel leaves it alone (PlanetFrame.recentre,
## PlanetSystem._travel): it is not in the world.
static func board(body: CharacterBody3D, st: SpaceStation) -> void:
	var r2g := st.ghost_to_real().affine_inverse()
	var xf := body.global_transform
	var g := r2g * xf.origin
	var v := body.velocity - st.deck_velocity(g)
	PhysicsServer3D.body_set_space(body.get_rid(), st.ghosts.space)
	body.set_meta(&"ghosted", true)
	body.global_transform = r2g * xf
	body.velocity = r2g.basis * v
	body.reset_physics_interpolation()


## Off the ghost into the world (the one `world_space` is): at the real ship's
## same place, its velocity the deck's plus its own on it, turned into the world.
static func get_off(body: CharacterBody3D, st: SpaceStation, world_space: RID) -> void:
	var g2r := st.ghost_to_real()
	var g := body.global_position
	var v := g2r.basis * body.velocity + st.deck_velocity(g)
	PhysicsServer3D.body_set_space(body.get_rid(), world_space)
	body.remove_meta(&"ghosted")
	body.global_transform = g2r * body.global_transform
	body.velocity = v
	body.reset_physics_interpolation()


static func is_ghosted(n: Node) -> bool:
	return n != null and n.has_meta(&"ghosted")


## The space's query state, for rays and shape tests in it.
func state() -> PhysicsDirectSpaceState3D:
	return PhysicsServer3D.space_get_direct_state(space)


func free_space() -> void:
	if space.is_valid():
		PhysicsServer3D.free_rid(space)
		space = RID()
