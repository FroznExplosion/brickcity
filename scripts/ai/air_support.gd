class_name AirSupport
extends RefCounted
## A side's fast planes (Docs/AIRoster.md 7, R10): what a soldier's "call in air"
## (the casebook's call_air) asks for, and what its commander pays for (RO11):
## RUN_POINTS from the `payer`'s budget a run -- with too little there, there is
## no air to call (and a soldier does not know it as available). No payer: free.
## One run at a time, then COOLDOWN before the next. A side with nowhere to put a
## plane (no `parent`) has none -- and its soldiers do not know air as available.
##
## Which run: bombs on a target with bricks over or round it (they come down on
## it), a strafing run on one in the open. Along which line: across the caller's
## view of it, so the run does not come in over the caller's own head.

const COOLDOWN := 45.0
const RUN_POINTS := 6.0

var services: AIServices
var team := 1
## Where the planes are put; null for a side with no air.
var parent: Node
var ready_at := 0.0
## The side's commander, who pays for each run; null for free runs.
var payer: Commander
var current: AirStrike
var runs := 0
## Every run launched, for logs and gates: [kind, at, called by].
var log: Array = []


func _init(s: AIServices, p_team: int) -> void:
	services = s
	team = p_team


func available() -> bool:
	return parent != null and is_instance_valid(parent) and services.now() >= ready_at \
			and (current == null or not is_instance_valid(current)) \
			and (payer == null or not is_instance_valid(payer) or payer.budget >= RUN_POINTS)


## A run on `at`, called by `caller` (or nobody). Returns it, or null.
func request(at: Vector3, caller: Pawn = null, kind := "") -> AirStrike:
	if not available():
		return null
	if kind == "":
		kind = "bombs" if _covered(at) else "strafe"
	var dir := Vector3.FORWARD
	if caller != null and is_instance_valid(caller):
		var to := at - caller.feet()
		to.y = 0.0
		if to.length() > 1.0:
			dir = to.normalized().cross(Vector3.UP)
	else:
		var a := services.rng.randf() * TAU
		dir = Vector3(cos(a), 0.0, sin(a))
	current = AirStrike.launch(services, parent, at, dir, kind, team, caller)
	ready_at = services.now() + COOLDOWN
	runs += 1
	log.append([kind, at, caller])
	if payer != null and is_instance_valid(payer):
		payer.pay(RUN_POINTS, "air: a %s run" % kind)
	print("[air] %s run on %v (side %d)%s" % [kind, at, team, " called by a soldier" if caller != null else ""])
	return current


func _covered(at: Vector3) -> bool:
	var w := services.ai_world
	return not w.line_clear(at + Vector3.UP * 1.0, at + Vector3.UP * 30.0)
