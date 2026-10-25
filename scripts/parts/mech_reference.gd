class_name MechReference
extends RefCounted
## The reference mech the workshop builds parts round (Docs/ModularParts.md section 9, stage
## 5): where each joint of a mech is, for a chassis class and a leg length. Every part of a
## slot mounts on the same joint whatever its class (section 4: the chassis says where, the
## interface says what), so a part built round these fits any mech of its class.
##
## Units are the workshop's: nano studs along and across, nano plates up, from the point
## between the feet on the ground. The mech faces -X; its left is +Z (the workshop's mirror
## is across Z, so a left part mirrors into a right one). Heights follow Docs/Parts/joints.md
## section 5's greybox (hip 16 nano bricks up at the middle leg length, shoulder 2 above).

const ROOT := "chassis"
const PLAN := "mech"
## The parts a mech build is made of, in the order the workshop lists them.
const PARTS := ["chassis", "head", "arm_L", "arm_R", "hand_L", "hand_R", "leg_L", "leg_R",
		"pod_L", "pod_R"]
## Each part's slot and side in the catalogue, and where it hangs: {host part, socket name,
## interface}. The socket names are the body plan's (standards.json body_plans.mech).
const SPEC := {
	"chassis": {"slot": "chassis", "side": "any"},
	"head": {"slot": "head", "side": "any", "host": "chassis", "socket": "neck", "iface": "mech.neck"},
	"arm_L": {"slot": "arm", "side": "L", "host": "chassis", "socket": "arm_L", "iface": "mech.shoulder"},
	"arm_R": {"slot": "arm", "side": "R", "host": "chassis", "socket": "arm_R", "iface": "mech.shoulder"},
	"hand_L": {"slot": "hand", "side": "L", "host": "arm_L", "socket": "hand", "iface": "mech.wrist"},
	"hand_R": {"slot": "hand", "side": "R", "host": "arm_R", "socket": "hand", "iface": "mech.wrist"},
	"leg_L": {"slot": "leg", "side": "L", "host": "chassis", "socket": "leg_L", "iface": "mech.hip"},
	"leg_R": {"slot": "leg", "side": "R", "host": "chassis", "socket": "leg_R", "iface": "mech.hip"},
	"pod_L": {"slot": "pod", "side": "L", "host": "chassis", "socket": "pod_L", "iface": "mech.pod"},
	"pod_R": {"slot": "pod", "side": "R", "host": "chassis", "socket": "pod_R", "iface": "mech.pod"},
}
## The joints inside a part, top to bottom: a leg bends at its knee (half way down) and its
## ankle (an eighth of the way up from the ground), an arm at its elbow (half way down). The
## bricks below a bend swing about it, and each bend below hangs on the one above.
## Which way each folds, for a part hanging down and facing -Z: a knee back, an elbow forward;
## an ankle keeps the foot level.
const BENDS := {"leg_L": ["knee", "ankle"], "leg_R": ["knee", "ankle"], "arm_L": ["elbow"], "arm_R": ["elbow"]}
const FOLD := {"knee": -1.0, "elbow": 1.0, "ankle": 1.0}
## How far down each bend is, from the part's joint (0) to its end (1).
const BEND_DOWN := {"knee": 0.5, "elbow": 0.5, "ankle": 0.85}
const CLASSES := ["light", "normal", "heavy"]
## Hip height, nano bricks, by leg length (body_plans.mech.leg_lengths). A boss's legs may
## be any length; these are the players' three.
const HIP_BRICKS := {1: 12, 2: 16, 3: 20}
## By class: half the hips' span and the shoulders' (nano studs), and the chassis's height
## from the hips to the neck (nano bricks). A heavy is wider and taller in the body.
const HIP_HALF := {"light": 4, "normal": 5, "heavy": 6}
const SHOULDER_HALF := {"light": 9, "normal": 11, "heavy": 13}
const CHASSIS_BRICKS := {"light": 5, "normal": 6, "heavy": 7}
## The shoulder above the hips, the arm's length to the wrist (plates), the wrist ahead
## of the shoulder (studs), the pods behind the neck and in from the shoulders (studs).
const SHOULDER_UP := 6
const ARM_PLATES := 24
const WRIST_AHEAD := 2
const POD_BEHIND := 3
const POD_IN := 4
const PLATES_PER_BRICK := 3


## Every part's joint for `klass` and `length`: {part: Vector3 (studs, plates, studs)}, the
## chassis's at the point between the hips.
static func joints(klass: String, length: int) -> Dictionary:
	klass = klass if CLASSES.has(klass) else "normal"
	var hip_y := float(HIP_BRICKS.get(length, HIP_BRICKS[2]) * PLATES_PER_BRICK)
	var neck_y := hip_y + float(CHASSIS_BRICKS[klass] * PLATES_PER_BRICK)
	var shoulder_y := hip_y + SHOULDER_UP
	var sh := float(SHOULDER_HALF[klass])
	var hh := float(HIP_HALF[klass])
	return {
		"chassis": Vector3(0, hip_y, 0),
		"head": Vector3(0, neck_y, 0),
		"arm_L": Vector3(0, shoulder_y, sh),
		"arm_R": Vector3(0, shoulder_y, -sh),
		"hand_L": Vector3(-WRIST_AHEAD, shoulder_y - ARM_PLATES, sh),
		"hand_R": Vector3(-WRIST_AHEAD, shoulder_y - ARM_PLATES, -sh),
		"leg_L": Vector3(0, hip_y, hh),
		"leg_R": Vector3(0, hip_y, -hh),
		"pod_L": Vector3(POD_BEHIND, neck_y, sh - POD_IN),
		"pod_R": Vector3(POD_BEHIND, neck_y, -(sh - POD_IN)),
	}


## Where part `part` bends at `bend` (BENDS; "" its first), in the joints' units: that far
## from its joint to its end (a leg's foot on the ground, an arm's wrist). Vector3.INF for none.
static func bend_at(part: String, bend: String = "", klass: String = "normal", length: int = 2) -> Vector3:
	var names: Array = BENDS.get(part, [])
	if names.is_empty():
		return Vector3.INF
	if bend == "":
		bend = names[0]
	if not bend in names:
		return Vector3.INF
	var j := joints(klass, length)
	var top: Vector3 = j[part]
	var end: Vector3 = Vector3(top.x, 0.0, top.z) if part.begins_with("leg") else j["hand" + part.substr(3)]
	return top.lerp(end, float(BEND_DOWN[bend]))


## Half the footprint drawn under it, in studs: the shoulders' span.
static func footprint(klass: String = "normal") -> float:
	return float(SHOULDER_HALF.get(klass, SHOULDER_HALF.normal))


## The body plan path of a part's socket: "arm_L", "arm_L/hand".
static func path_of(part: String) -> String:
	var s: Dictionary = SPEC.get(part, {})
	if not s.has("host"):
		return ""
	# Paths run by socket names from the root: the hat on the head is "neck/hat".
	return s.socket if s.host == "chassis" else "%s/%s" % [path_of(s.host), s.socket]


## The build part a catalogue part goes on: its slot and side; a part for either side goes
## on `prefer` if that is of its slot, else the left one.
static func part_for(slot: String, side: String, prefer: String = "") -> String:
	var p: Dictionary = SPEC.get(prefer, {})
	if not p.is_empty() and p.slot == slot and (side == "any" or p.side == side):
		return prefer
	for k in PARTS:
		var s: Dictionary = SPEC[k]
		if s.slot == slot and (side == "any" or s.side == "any" or s.side == side):
			return k
	return ""
