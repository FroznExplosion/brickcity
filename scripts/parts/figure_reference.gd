class_name FigureReference
extends RefCounted
## The reference figure the workshop builds figure parts round (Docs/ModularParts.md section 10,
## stage 12): an action figure, one size -- 8 nano bricks, 1.68 m in the game
## (Docs/Parts/nano.md) -- so every torso takes every head, arm, hand, leg and hat.
## The same calls as MechReference, so the workshop's body mode serves both.
##
## Units: nano studs along and across, nano plates up, from between the feet on the ground.
## It faces -X; its left is +Z (the mirror makes a right part of a left one).

const ROOT := "torso"
const PLAN := "figure"
const PARTS := ["torso", "head", "arm_L", "arm_R", "hand_L", "hand_R", "leg_L", "leg_R", "hat"]
const SPEC := {
	"torso": {"slot": "torso", "side": "any"},
	"head": {"slot": "head", "side": "any", "host": "torso", "socket": "neck", "iface": "fig.neck"},
	"arm_L": {"slot": "arm", "side": "L", "host": "torso", "socket": "arm_L", "iface": "fig.shoulder"},
	"arm_R": {"slot": "arm", "side": "R", "host": "torso", "socket": "arm_R", "iface": "fig.shoulder"},
	"hand_L": {"slot": "hand", "side": "L", "host": "arm_L", "socket": "hand", "iface": "fig.wrist"},
	"hand_R": {"slot": "hand", "side": "R", "host": "arm_R", "socket": "hand", "iface": "fig.wrist"},
	"leg_L": {"slot": "leg", "side": "L", "host": "torso", "socket": "leg_L", "iface": "fig.hip"},
	"leg_R": {"slot": "leg", "side": "R", "host": "torso", "socket": "leg_R", "iface": "fig.hip"},
	"hat": {"slot": "hat", "side": "any", "host": "head", "socket": "hat", "iface": "fig.hat"},
}
## In nano plates up and studs across: hips 4 bricks up, the shoulders 2.5 bricks over them,
## the neck at the shoulders, the hat's studs 2 bricks over the neck.
const HIP_PLATES := 12
const SHOULDER_PLATES := 20
const NECK_PLATES := 21
const HAT_PLATES := 27
const HIP_HALF := 1.0
const SHOULDER_HALF := 2.0
const ARM_PLATES := 8
const WRIST_AHEAD := 1.0


## Every part's joint: {part: Vector3 (studs, plates, studs)}. A figure has no class or leg
## length: the arguments are MechReference's, and ignored.
static func joints(_klass: String = "", _length: int = 0) -> Dictionary:
	return {
		"torso": Vector3(0, HIP_PLATES, 0),
		"head": Vector3(0, NECK_PLATES, 0),
		"arm_L": Vector3(0, SHOULDER_PLATES, SHOULDER_HALF),
		"arm_R": Vector3(0, SHOULDER_PLATES, -SHOULDER_HALF),
		"hand_L": Vector3(-WRIST_AHEAD, SHOULDER_PLATES - ARM_PLATES, SHOULDER_HALF),
		"hand_R": Vector3(-WRIST_AHEAD, SHOULDER_PLATES - ARM_PLATES, -SHOULDER_HALF),
		"leg_L": Vector3(0, HIP_PLATES, HIP_HALF),
		"leg_R": Vector3(0, HIP_PLATES, -HIP_HALF),
		"hat": Vector3(0, HAT_PLATES, 0),
	}


## Half the footprint drawn under it, in studs.
static func footprint(_klass: String = "") -> float:
	return SHOULDER_HALF + 1.0


static func path_of(part: String) -> String:
	var s: Dictionary = SPEC.get(part, {})
	if not s.has("host"):
		return ""
	return s.socket if s.host == ROOT else "%s/%s" % [s.host, s.socket]


static func part_for(slot: String, side: String, prefer: String = "") -> String:
	var p: Dictionary = SPEC.get(prefer, {})
	if not p.is_empty() and p.slot == slot and (side == "any" or p.side == side):
		return prefer
	for k in PARTS:
		var s: Dictionary = SPEC[k]
		if s.slot == slot and (side == "any" or s.side == "any" or s.side == side):
			return k
	return ""


## How high the hips are in the game, metres: one figure size.
static func hip_height() -> float:
	return HIP_PLATES * 0.07
