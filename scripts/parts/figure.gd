class_name Figure
extends Node3D
## An action figure in the game from its parts (Docs/ModularParts.md section 10, stage 12):
## a torso, head, arms, hands, legs and a hat, each part on its joint as a mech's are
## (MechAssembler.assemble), one size, so any figure's limb goes on any other's. Limbs swap
## while it stands there (`swap`); it walks by the motion sets ("figure.walk.stride").
##
##     var b := PartBuilder.generate("figure", design, seed, catalogue)
##     var f := Figure.make(b)          # null if the build has problems
##     add_child(f)
##
## Animals are not figures: they are the creatures' own (ProcCreature), their own catalogue.

const PLAN := "figure"
## Walking about: how fast, how far from where it was put down.
const WANDER_SPEED := 1.4
const WANDER_RADIUS := 3.0

## The build it is made of: {root, at: {path: PartRecord}}.
var build: Dictionary = {}
var model: Node3D
var walk: MechStride
var walk_id := ""
## Walking speed now, m/s.
var speed := 0.0
## What it does (a character's simple brain; fighting is the AI's): "idle" stands; "wander"
## walks a circle round where it was put; "follow" walks after `target`, stopping FOLLOW_GAP
## short; "patrol" walks `route` round and round.
var mode := "idle"
var target: Node3D
var route: Array[Vector3] = []
var _leg := 0
var _home := Vector3.ZERO
var _angle := 0.0
const WALK := 1.6
const FOLLOW_GAP := 2.0
const ARRIVE := 0.3
const TURN := 6.0

## `wander = true` is the circle walk (kept for its callers).
var wander: bool:
	get:
		return mode == "wander"
	set(v):
		mode = "wander" if v else "idle"


## A figure of `b` (PartBuilder.generate's), or null if it has problems or no torso scene:
## only parts that fit are ever put together.
static func make(b: Dictionary, pick_walk: String = "") -> Figure:
	if not (b.get("problems", []) as Array).is_empty() or b.get("root") == null:
		return null
	var f := Figure.new()
	f.name = "Figure"
	f.build = {"root": b.root, "at": (b.get("at", {}) as Dictionary).duplicate(),
			"motion": (b.get("motion", {}) as Dictionary).duplicate()}
	if not f._rebuild(pick_walk):
		f.free()
		return null
	return f


## Swap the part at `path` ("arm_L", "neck/hat", "root") for `part`. Refused (false, and
## nothing changes) if it does not fit there or the figure would not be whole by the plan;
## what hangs on it stays on, if it fits the new one.
func swap(path: String, part: PartRecord) -> bool:
	return why_not_swap(path, part) == "" and _apply_swap(path, part)


func why_not_swap(path: String, part: PartRecord) -> String:
	var trial := {"root": build.root, "at": (build.at as Dictionary).duplicate()}
	if path == "root":
		trial.root = part
	else:
		var host: PartRecord = trial.root if not path.contains("/") else trial.at.get(path.get_base_dir())
		var why := PartFit.why_not(part, host, path, PLAN)
		if why != "":
			return why
		trial.at[path] = part
	var bad := PartFit.problems(trial, PLAN)
	return "" if bad.is_empty() else "; ".join(bad)


func _apply_swap(path: String, part: PartRecord) -> bool:
	if path == "root":
		build.root = part
	else:
		build.at[path] = part
	return _rebuild(walk_id)


## The joint node of `path` (a part's place on the figure), or null. A hand's is inside its
## arm, under the elbow.
func joint(path: String) -> Node3D:
	return model.find_child("Joint_" + path.replace("/", "_"), true, false) as Node3D if model != null else null


## The hips above the feet: one figure size.
static func hip_height() -> float:
	return FigureReference.hip_height()


func _rebuild(pick_walk: String) -> bool:
	var m := MechAssembler.assemble(build)
	if m == null:
		return false
	if model != null:
		remove_child(model)
		model.queue_free()
	model = m
	model.position = Vector3.UP * hip_height()
	add_child(model)
	if walk != null:
		remove_child(walk)
		walk.queue_free()
		walk = null
	var pick := pick_walk if pick_walk != "" else String((build.get("motion", {}) as Dictionary).get("walk", ""))
	walk_id = MotionSets.best(PLAN, ["walk", "biped"], {"paths": (build.at as Dictionary).keys()}, pick)
	walk = MotionSets.make(walk_id) as MechStride
	if walk != null:
		walk.hip_height = hip_height()
		for path in ["leg_L", "leg_R"]:
			var j := joint(path)
			if j != null:
				walk.hips.append(j)
				walk.knees.append(MotionSets._bend_in(j, "knee"))
		for path in ["arm_L", "arm_R"]:
			var j := joint(path)
			if j != null:
				walk.arms.append(j)
				walk.elbows.append(MotionSets._bend_in(j, "elbow"))
		add_child(walk)
	return true


func _ready() -> void:
	_home = position


func _physics_process(delta: float) -> void:
	think(delta)
	if walk != null:
		walk.step(delta, speed)


## One step of its brain: where it goes this tick.
func think(delta: float) -> void:
	match mode:
		"wander":
			speed = WANDER_SPEED
			_angle = fmod(_angle + delta * speed / WANDER_RADIUS, TAU)
			position = _home + Vector3(cos(_angle), 0.0, sin(_angle)) * WANDER_RADIUS
			rotation.y = -_angle   # facing along the circle (it faces -Z)
		"follow":
			if target == null or not is_instance_valid(target):
				speed = 0.0
				return
			_walk_to(target.global_position if target.is_inside_tree() else target.position, FOLLOW_GAP, delta)
		"patrol":
			if route.is_empty():
				speed = 0.0
				return
			if _walk_to(route[_leg % route.size()], ARRIVE, delta):
				_leg = (_leg + 1) % route.size()
		_:
			speed = 0.0


## Walk toward `to` on the flat, turning to face it, until `gap` from it. True once there.
func _walk_to(to: Vector3, gap: float, delta: float) -> bool:
	var flat := Vector3(to.x - position.x, 0.0, to.z - position.z)
	var d := flat.length()
	if d <= gap:
		speed = 0.0
		return true
	var want := atan2(-flat.x, -flat.z)   # it faces -Z
	rotation.y = lerp_angle(rotation.y, want, clampf(TURN * delta, 0.0, 1.0))
	speed = WALK
	position += flat / d * minf(WALK * delta, d - gap)
	return false


## Where it stands, in words: for gates and the builder.
func doing() -> String:
	return mode if speed == 0.0 else "%s, walking" % mode


## The figures made in the workshop: the parts saved from one build (by its name) fixed on
## their paths, and every figure design file. id -> PartDesign.
static func designs(cat: PartCatalog = null) -> Dictionary:
	if cat == null:
		cat = MechAssembler.catalog()
	var by_from := {}
	for r in cat.filter({"family": ["figure"]}):
		var from := String(r.extra.get("from", ""))
		if from != "" and FileAccess.file_exists(r.dir + MechAssembler.PART_SCENE):
			(by_from.get_or_add(from, []) as Array).append(r)
	var out := {}
	for from: String in by_from:
		var did := AssetGuns.slug(from)
		out[did] = PartDesign.from_parts(did, from, PLAN, by_from[from])
	var files := PartDesign.load_all()
	for did: String in files:
		if (files[did] as PartDesign).plan == PLAN and not out.has(did):
			out[did] = files[did]
	return out
