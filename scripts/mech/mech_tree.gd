class_name MechTree
extends RefCounted
## The mechs' trees (Docs/AI.md 6.4, 2.1; AIPlan P7), built in code. Their agent
## is the mech's body; MechBrain fires at whatever it sees on its own, so a tree
## decides only where to go -- and whether to take a wall away.
##
## The enemy's mech:
##   DynamicSelector
##     DynamicSequence  Knows(in sight) > HoldRange   -- keep its range, shoot
##     DynamicSequence  Knows(20 s) > Breach          -- behind bricks: the wall goes
##     Idle
##
## The player's mech, on the one-button order (AI.md 2.1, A4):
##   DynamicSelector
##     DynamicSequence  Order(FOLLOW) > Follow         -- the pilot's 5-8 m band
##     DynamicSequence  Order(HOLD) > Hold             -- where it was told
##     DynamicSequence  Order(ATTACK_AREA) > GoTo      -- there, and fight
##     Idle


static func enemy() -> BehaviorTree:
	var root := BTDynamicSelector.new()
	var fight := BTDynamicSequence.new()
	var sees := BTMechKnows.new()
	sees.max_age = 0.6
	sees.in_sight = true
	fight.add_child(sees)
	fight.add_child(BTMechHoldRange.new())
	root.add_child(fight)
	var breach := BTDynamicSequence.new()
	var knows := BTMechKnows.new()
	knows.max_age = 20.0
	breach.add_child(knows)
	breach.add_child(BTMechBreach.new())
	root.add_child(breach)
	root.add_child(BTMechIdle.new())
	return _tree(root)


static func companion() -> BehaviorTree:
	var root := BTDynamicSelector.new()
	var orders := [[MechBrain.Order.FOLLOW, BTMechFollow.new()],
			[MechBrain.Order.HOLD, BTMechHold.new()],
			[MechBrain.Order.ATTACK_AREA, BTMechGoTo.new()]]
	for pair in orders:
		var seq := BTDynamicSequence.new()
		var cond := BTMechOrderIs.new()
		cond.order = pair[0]
		seq.add_child(cond)
		seq.add_child(pair[1])
		root.add_child(seq)
	root.add_child(BTMechIdle.new())
	return _tree(root)


static func _tree(root: BTTask) -> BehaviorTree:
	var bt := BehaviorTree.new()
	bt.set_root_task(root)
	return bt


static func brain_of(agent: Node) -> MechBrain:
	return agent.get_node_or_null(^"MechBrain") as MechBrain
