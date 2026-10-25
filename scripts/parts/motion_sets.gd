class_name MotionSets
extends RefCounted
## One animation library for everything (Docs/ModularParts.md section 8, stage 8): guns, mechs,
## figures, creatures and pods pick their motion by what the build is -- its body plan, the
## parts it has, how many legs -- never by hand per model.
##
## A set is `procedural` (a mover node that reads lengths from the assembly, so one mech walk
## serves every leg length) or `clips` (named bones' animations). Some are run by the system
## that already owns them (`by`): the gun reload in PlayerView, the creatures' gaits; the
## library says which one a build gets, that system plays it.
##
##     var id := MotionSets.best("mech", ["walk", "heavy"], {"paths": build.at.keys()})
##     var mover := MotionSets.make(id)

const SETS := {
	# Mechs: the legs swing at the hips, the stride from the leg's length (MechStride).
	"mech.walk.stride": {"kind": "procedural", "plans": ["mech"], "tags": ["walk", "light", "normal"],
			"needs": ["leg_L", "leg_R"], "mover": "stride", "swing": 0.45},
	"mech.walk.stomp": {"kind": "procedural", "plans": ["mech"], "tags": ["walk", "heavy"],
			"needs": ["leg_L", "leg_R"], "mover": "stride", "swing": 0.3},
	# Pods with an arm of their own (PodArmMotion): a hammer blow, a lob.
	"pod.arm.strike": {"kind": "procedural", "plans": ["pod"], "tags": ["pod.arm", "melee_arm"],
			"mover": "pod_arm", "style": "strike"},
	"pod.arm.throw": {"kind": "procedural", "plans": ["pod"], "tags": ["pod.arm", "grenade_arm"],
			"mover": "pod_arm", "style": "throw"},
	# Guns: PlayerView's reload, the magazine out with the hand when it detaches.
	"gun.reload.mag": {"kind": "procedural", "plans": ["gun"], "tags": ["reload", "reload.mag"],
			"needs": ["magazine"], "by": "PlayerView"},
	"gun.reload.fixed": {"kind": "procedural", "plans": ["gun"], "tags": ["reload"], "by": "PlayerView"},
	# Creatures (animals): the stepping gait from their morphology near, the sine swing far.
	"creature.gait": {"kind": "procedural", "plans": ["creature"], "tags": ["walk", "near"],
			"legs": [1, 10], "by": "GaitController"},
	"creature.gait.far": {"kind": "procedural", "plans": ["creature"], "tags": ["walk", "far"],
			"legs": [1, 10], "by": "CannedGait"},
	# Figures: the legs swing at the hips, as a mech's (Figure); Mixamo-named clips are there to
	# be picked when a figure has the bones for them.
	"figure.walk.stride": {"kind": "procedural", "plans": ["figure"], "tags": ["walk", "biped"],
			"needs": ["leg_L", "leg_R"], "mover": "stride", "swing": 0.5},
	"figure.walk.clips": {"kind": "clips", "plans": ["figure"], "tags": ["walk", "clips"],
			"needs": ["leg_L", "leg_R"], "by": "clips"},
}


## Every set a build satisfies: its plan, every path it needs, its leg count in range.
## `have`: {paths: [...], legs: int}.
static func satisfying(plan: String, have: Dictionary) -> Array:
	var out := []
	var paths: Array = have.get("paths", [])
	for id: String in SETS:
		var s: Dictionary = SETS[id]
		if not plan in s.plans:
			continue
		if not (s.get("needs", []) as Array).all(func(p: String) -> bool: return p in paths):
			continue
		if s.has("legs"):
			var n := int(have.get("legs", -1))
			if n < int(s.legs[0]) or n > int(s.legs[1]):
				continue
		out.append(id)
	out.sort()
	return out


## The set a build gets for `want` (the first tag is the action -- "walk", "pod.arm",
## "reload" -- the rest what it would like: its class, its pod's kind): among those it
## satisfies that do the action, the one with the most wanted tags; ties on id. `pick`, if
## the build satisfies it, wins (a player's choice, a design's `motion`). "" for none.
static func best(plan: String, want: Array, have: Dictionary, pick: String = "") -> String:
	var ok := satisfying(plan, have)
	if pick != "" and pick in ok and (want.is_empty() or String(want[0]) in SETS[pick].tags):
		return pick
	var best_id := ""
	var best_n := -1
	for id: String in ok:
		var tags: Array = SETS[id].tags
		if not want.is_empty() and not String(want[0]) in tags:
			continue
		var n := 0
		for t in want:
			if t in tags:
				n += 1
		if n > best_n:
			best_n = n
			best_id = id
	return best_id


## The mover a procedural set runs, or null for one another system runs (`by`).
static func make(id: String) -> Node:
	var s: Dictionary = SETS.get(id, {})
	match String(s.get("mover", "")):
		"stride":
			var m := MechStride.new()
			m.name = "MotionWalk"
			m.set_id = id
			m.swing_max = float(s.swing)
			return m
		"pod_arm":
			var p := PodArmMotion.new()
			p.name = "MotionPodArm"
			p.set_id = id
			p.style = String(s.style)
			return p
	return null


## The bend `name` of the part on joint `j`, or null.
static func _bend_in(j: Node3D, name: String) -> Node3D:
	for c in j.get_children():
		if c.has_meta(&"part_id"):
			return MechAssembler.bends_of(c).get(name)
	return null


## Give dressed mech `m` its walk: the set its build gets (or `pick`), its legs as long as
## the build's. Any walk it had goes. The set's id, or "" (no legs: nothing walks).
static func walk_mech(m: Mech, build: Dictionary, pick: String = "") -> String:
	var old := m.body.get_node_or_null(^"MotionWalk")
	if old != null:
		old.queue_free()
		m.body.remove_child(old)
	var root: PartRecord = build.get("root")
	var id := best("mech", ["walk", root.weight_class if root != null else ""],
			{"paths": (build.get("at", {}) as Dictionary).keys()}, pick)
	var mover := make(id) as MechStride
	if mover == null:
		return ""
	mover.mech = m
	mover.hip_height = MechAssembler.hip_height(build)
	for c in m.legs.get_children():
		if String(c.name).begins_with("Joint_leg_"):
			mover.hips.append(c)
			mover.knees.append(_bend_in(c, "knee"))
			mover.ankles.append(_bend_in(c, "ankle"))
	m.body.add_child(mover)
	return id
