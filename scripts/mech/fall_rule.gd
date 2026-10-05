class_name FallRule
extends Node
## Mechs falling through floors (Docs/AI.md 3.11, A12, R9; AIPlan P7).
##
## A landing is energy, not weight, and the rule is stated in BRICKS OF FALL so it
## does not care how heavy a mech turns out to be. A floor breaks if the mech
## arrives with the energy of a fall of at least T bricks; breaking it costs A
## bricks of that energy, and falling the next storey adds the storey back:
##
##   falls from        floors it breaks
##   under 6 bricks    none -- it lands
##   6 (one storey)    1: 6 -> breaks -> 6 - 8.5 + 6 = 3.5, stops on the next floor
##   12 (two storeys)  3: 12 -> 9.5 -> 7 -> 4.5, stops
##
## The energy is height: the fall from the highest point of the jump, or off the
## edge, to the floor -- a dash off a roof counts the same as a drop. After a
## break the energy left is CARRIED (it may be negative) and the next floor is
## judged on it plus the height fallen since, not on the body's speed: the mech
## leaves a broken floor at the speed what is left is worth, or at rest.
##
## The rule decides; physics only carries the pieces (R9). The mech falls through
## the floor it broke -- building collision off until its feet are past it -- and
## ignores falling pieces until it lands, so the plate it broke, which falls with
## it, is never what it lands on; and the pieces' own landing fracture is the
## owner's to suppress. Only where the owner decides (the host) is anything broken.

const T := 6.0
const A := 8.5
## A brick course, metres: the unit of the rule.
const BRICK := 0.42
## What a mech's feet break: the floor under its whole footprint -- a hole it
## does not fit through is a hole it lands on the rim of.
const FOOT_RADIUS := Mech.RADIUS + 0.5
## Building collision stays off at most this long after a break.
const PASS_SECONDS := 2.0
## Pieces the mech ignores while it crashes through.
const PIECE_LAYERS := Layers.DEBRIS | Layers.FALLING | Layers.FIXTURE

## (feet: Vector3) -> Dictionary: what the feet stand on, if it is a floor the
## rule applies to -- {"chunk": int, "t": bricks to break it} -- or {} (the
## ground, a loose piece).
var floor_at := Callable()
## (point: Vector3, radius: float, floor: Dictionary) -> void. Break it (the
## host commits the command).
var on_break := Callable()
## (feet: Vector3) -> float: the top of the next floor under the feet, below
## the one just broken -- or -INF. Everything between the two is fallen past,
## not landed on: the posts and walls under a floor a mech came through are
## where its feet were, and a mech as wide as the plate it broke would otherwise
## come to rest on their tops, between floors.
var next_floor := Callable()
## False on a client: its mech lands, and the host's commands break the floor.
var decides := true
var mech: Mech
## For gates: floors broken, and each landing judged: [feet y, energy, broke].
var breaks := 0
var landings: Array = []
## Pieces it was told to ignore.
var ignored := 0

var _peak_y := 0.0
var _was_on_floor := true
var _carrying := false
var _carry := 0.0
var _carry_y := 0.0
var _through_y := INF
var _through_until := -INF
var _saved_mask := 0


func _ready() -> void:
	# Right after the motor (-10) has moved the body, before anything reads it.
	process_physics_priority = -9
	if mech != null:
		_peak_y = mech.feet().y
		_saved_mask = mech.body.collision_mask


func _physics_process(_delta: float) -> void:
	if mech == null or mech.body == null:
		return
	var body := mech.body
	var y := mech.feet().y
	var now := _now()
	if _through_y != INF and (y < _through_y or now > _through_until):
		# Past the floor it broke: buildings are solid again.
		body.collision_mask |= _saved_mask & Layers.STRUCTURE
		_through_y = INF
	var on_floor := body.is_on_floor()
	if not on_floor:
		_peak_y = maxf(_peak_y, y)
		_was_on_floor = false
		return
	if not _was_on_floor and _land(y):
		return   # broke it: falling on
	_peak_y = y
	_was_on_floor = true


## Simulation time, so the rule is the same however fast the machine runs.
func _now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


## Judge a landing. True if it broke the floor.
func _land(y: float) -> bool:
	var energy := (_carry + (_carry_y - y) / BRICK) if _carrying else (_peak_y - y) / BRICK
	var fl: Dictionary = floor_at.call(mech.feet()) if floor_at.is_valid() else {}
	var t := float(fl.get("t", T))
	var broke := decides and not fl.is_empty() and energy >= t
	landings.append([y, energy, broke])
	if not broke:
		_carrying = false
		mech.body.collision_mask = _saved_mask
		return false
	breaks += 1
	on_break.call(mech.feet() - Vector3.UP * 0.07, FOOT_RADIUS, fl)
	_carry = energy - A
	_carry_y = y
	_carrying = true
	# On through it: the floor it broke is not there for it any more, and
	# neither is anything falling with it.
	_through_y = y - 0.35
	if next_floor.is_valid():
		var below: float = next_floor.call(mech.feet() - Vector3.UP * 0.3)
		if below > -INF:
			_through_y = below + 0.3
	_through_until = _now() + PASS_SECONDS
	mech.body.collision_mask = _saved_mask & ~(Layers.STRUCTURE | PIECE_LAYERS)
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) \
			* mech.motor.gravity_scale
	mech.body.velocity.y = -sqrt(2.0 * g * maxf(_carry, 0.0) * BRICK)
	_peak_y = y
	_was_on_floor = false
	return true


## Never collide with `other` -- a piece of a floor it broke (R9). The owner
## calls this for pieces that come off under it while it is crashing through.
func ignore(other: PhysicsBody3D) -> void:
	if other != null and is_instance_valid(other):
		mech.body.add_collision_exception_with(other)
		ignored += 1


## Is it crashing through floors now?
func is_carrying() -> bool:
	return _carrying
