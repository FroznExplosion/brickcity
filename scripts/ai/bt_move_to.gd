@tool
class_name BTMoveTo
extends BTAction
## Walk the agent's Pawn to a point on the blackboard.
##
## The first LimboAI task, and the pattern for all of them (Docs/AI.md): a task
## never moves a body. It writes the pawn's PawnIntents -- the same struct
## PlayerController writes -- and the Pawn's motor does the moving on the physics
## tick. A behaviour tree is therefore just another brain, and a soldier moves by
## exactly the rules the player moves by.
##
## Straight-line for now: navigation is P3. The agent is the pawn's body, with
## the Pawn as its child named "Pawn" (Pawn.spawn).

@export var target_var: StringName = &"target"
## Close enough, in metres, measured on the ground plane.
@export var tolerance := 0.5
@export var run := false


func _generate_name() -> String:
	return "MoveTo %s" % LimboUtility.decorate_var(target_var)


func _tick(_delta: float) -> Status:
	var pawn := agent.get_node_or_null(^"Pawn") as Pawn
	if pawn == null or not blackboard.has_var(target_var):
		return FAILURE
	var target: Vector3 = blackboard.get_var(target_var)
	var to := target - pawn.feet()
	to.y = 0.0
	if to.length() <= tolerance:
		pawn.intents.move = Vector3.ZERO
		pawn.intents.run = false
		return SUCCESS
	pawn.intents.move = to.normalized()
	pawn.intents.run = run
	pawn.intents.look_yaw = atan2(-to.x, -to.z)
	return RUNNING
