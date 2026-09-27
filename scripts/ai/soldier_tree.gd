class_name SoldierTree
extends RefCounted
## The infantry tree (Docs/AI.md 7, AIPlan P4), built in code:
##
##   DynamicSelector                     -- re-checked every tick, top first
##     DynamicSequence  InDanger > Evade       -- a falling piece beats everything
##     DynamicSequence  HasContact(2.5 s) >    -- a live fight
##         Selector
##           Sequence  FindCover > PeekAndFire
##           FireInOpen                        -- no cover anywhere: stand and shoot
##     DynamicSequence  HasContact(25 s, unsearched) > Search  -- lost it: go and look
##     Idle
##
## A higher branch pre-empts a lower one the tick its condition holds: seen again
## while searching, the soldier is fighting again.


static func build() -> BehaviorTree:
	var root := BTDynamicSelector.new()

	var evade := BTDynamicSequence.new()
	evade.add_child(BTInDanger.new())
	evade.add_child(BTEvade.new())
	root.add_child(evade)

	var engage := BTDynamicSequence.new()
	var fresh := BTHasContact.new()
	fresh.max_age = 2.5
	engage.add_child(fresh)
	var how := BTSelector.new()
	var cover := BTSequence.new()
	cover.add_child(BTFindCover.new())
	cover.add_child(BTPeekAndFire.new())
	how.add_child(cover)
	how.add_child(BTFireInOpen.new())
	engage.add_child(how)
	root.add_child(engage)

	var search := BTDynamicSequence.new()
	var stale := BTHasContact.new()
	stale.max_age = 25.0
	stale.unsearched = true
	search.add_child(stale)
	search.add_child(BTSearch.new())
	root.add_child(search)

	root.add_child(BTIdle.new())

	var bt := BehaviorTree.new()
	bt.set_root_task(root)
	return bt


## The Soldier component of a task's agent (the pawn's body).
static func soldier_of(agent: Node) -> Soldier:
	return agent.get_node_or_null(^"Soldier") as Soldier
