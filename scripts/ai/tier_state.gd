class_name TierState
extends LimboState
## One tier of AgentTier: entering it tells the agent.

var tier := 0


func _enter() -> void:
	if agent != null and agent.has_method(&"set_tier"):
		agent.call(&"set_tier", tier)
