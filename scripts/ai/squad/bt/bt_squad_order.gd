@tool
class_name BTSquadOrder
extends BTCondition
## The squad holds an order of `kind`.

@export var kind := 0


func _generate_name() -> String:
	return "Order %s" % SquadMsg.OrderKind.keys()[kind]


func _tick(_delta: float) -> Status:
	var q := agent as Squad
	return SUCCESS if q != null and q.order != null and q.order.kind == kind else FAILURE
