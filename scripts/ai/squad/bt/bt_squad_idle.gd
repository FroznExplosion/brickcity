@tool
class_name BTSquadIdle
extends BTAction
## No play: the members run their own trees -- fight, take cover, search -- as a
## lone soldier would.


func _enter() -> void:
	var q := agent as Squad
	q.clear_assignments()


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	q.play = "idle"
	blackboard.set_var(&"play", "idle")
	return RUNNING
