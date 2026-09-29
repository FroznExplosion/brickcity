class_name SquadTree
extends RefCounted
## The squad's tree (Docs/AI.md 7, AIPlan P6), built in code. Its agent is the
## Squad node; its tasks choose a PLAY and hand out assignments.
##
##   DynamicSelector
##     DynamicSequence  Broken > FallBack           -- morale gone: back to rally cover
##     DynamicSequence  Order(CLEAR_ROOM) > ClearRoom
##     DynamicSequence  Order(ADVANCE) > Advance   -- bounding overwatch, masked moves
##     DynamicSequence  LostContact > SearchPairs
##     Idle                                         -- members fight on their own trees


static func build() -> BehaviorTree:
	var root := BTDynamicSelector.new()
	var fall := BTDynamicSequence.new()
	fall.add_child(BTSquadBroken.new())
	fall.add_child(BTPlayFallBack.new())
	root.add_child(fall)
	var clear := BTDynamicSequence.new()
	var oc := BTSquadOrder.new()
	oc.kind = SquadMsg.OrderKind.CLEAR_ROOM
	clear.add_child(oc)
	clear.add_child(BTPlayClearRoom.new())
	root.add_child(clear)
	var adv := BTDynamicSequence.new()
	var oa := BTSquadOrder.new()
	oa.kind = SquadMsg.OrderKind.ADVANCE
	adv.add_child(oa)
	adv.add_child(BTPlayAdvance.new())
	root.add_child(adv)
	var search := BTDynamicSequence.new()
	search.add_child(BTSquadLostContact.new())
	search.add_child(BTPlaySearchPairs.new())
	root.add_child(search)
	root.add_child(BTSquadIdle.new())
	var bt := BehaviorTree.new()
	bt.set_root_task(root)
	return bt
