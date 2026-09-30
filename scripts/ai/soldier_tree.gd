class_name SoldierTree
extends RefCounted
## The infantry tree (Docs/AI.md 7, AIPlan P4), built in code:
##
##   DynamicSelector                     -- re-checked every tick, top first
##     DynamicSequence  InDanger > Evade       -- a falling piece beats everything
##     DynamicSequence  HasAssignment > DoAssignment  -- the squad's plan (P6)
##     DynamicSequence  HasContact(2.5 s) >    -- a live fight
##         ChooseTactic                        -- the policy's call (CombatPolicy)
##         DynamicSelector
##           Sequence  TacticIs(cover, cover reload, fall back) > FindCover > PeekAndFire
##           Sequence  TacticIs(push, flank) > Manoeuvre
##           FireInOpen                        -- fight open, or a tactic that failed
##     GoHelp                                   -- a buddy is stuck and called
##     DynamicSequence  HasContact(25 s, unsearched) > Search  -- lost it: go and look
##     Idle
##
## A higher branch pre-empts a lower one the tick its condition holds: seen again
## while searching, the soldier is fighting again.
##
## The fight's WHAT is ChooseTactic's, asked of a policy that a model can
## replace; the HOW -- finding cover, paths, peeks, when a line is clear -- stays
## in the tree, where it is clamped (AI.md 11.2).


static func build() -> BehaviorTree:
	var root := BTDynamicSelector.new()

	var evade := BTDynamicSequence.new()
	evade.add_child(BTInDanger.new())
	evade.add_child(BTEvade.new())
	root.add_child(evade)

	var order := BTDynamicSequence.new()
	order.add_child(BTHasAssignment.new())
	order.add_child(BTDoAssignment.new())
	root.add_child(order)

	var engage := BTDynamicSequence.new()
	var fresh := BTHasContact.new()
	fresh.max_age = 2.5
	engage.add_child(fresh)
	engage.add_child(BTChooseTactic.new())
	# Dynamic: re-tried every think, so a tactic chosen again takes over at once,
	# and one that fails falls through to fighting in the open.
	var how := BTDynamicSelector.new()
	var cover := BTSequence.new()
	var wants_cover := BTTacticIs.new()
	wants_cover.tactics = [CombatPolicy.Tactic.TAKE_COVER, CombatPolicy.Tactic.COVER_RELOAD,
			CombatPolicy.Tactic.FALL_BACK]
	cover.add_child(wants_cover)
	cover.add_child(BTFindCover.new())
	cover.add_child(BTPeekAndFire.new())
	how.add_child(cover)
	var move := BTSequence.new()
	var wants_move := BTTacticIs.new()
	wants_move.tactics = [CombatPolicy.Tactic.PUSH, CombatPolicy.Tactic.FLANK]
	move.add_child(wants_move)
	move.add_child(BTManoeuvre.new())
	how.add_child(move)
	how.add_child(BTFireInOpen.new())
	engage.add_child(how)
	root.add_child(engage)

	root.add_child(BTGoHelp.new())

	var search := BTDynamicSequence.new()
	var stale := BTHasContact.new()
	stale.max_age = 25.0
	stale.unsearched = true
	search.add_child(stale)
	search.add_child(BTSearch.new())
	root.add_child(search)

	# Weather: in a storm, with nothing else to do, get under a roof.
	root.add_child(BTShelter.new())

	root.add_child(BTIdle.new())

	var bt := BehaviorTree.new()
	bt.set_root_task(root)
	return bt


## The DIRECTED tree (Docs/AI.md 10.2, AIPlan P8): what a soldier outside the
## ten smart ones runs, at a third of the rate --
##
##   DynamicSelector
##     DynamicSequence  InDanger > Evade          -- never deferred, never dropped
##     DynamicSequence  HasAssignment > DoAssignment  -- follow the squad
##     DynamicSequence  HasContact(8 s) > DirectedEngage  -- shoot what is in
##                                                   front; else close on the
##                                                   shared flow field
##     Idle
##
## No cover search, no tactic, no peeking: slightly stupid, and cheap (A10).
static func build_directed() -> BehaviorTree:
	var root := BTDynamicSelector.new()
	var evade := BTDynamicSequence.new()
	evade.add_child(BTInDanger.new())
	evade.add_child(BTEvade.new())
	root.add_child(evade)
	var order := BTDynamicSequence.new()
	order.add_child(BTHasAssignment.new())
	order.add_child(BTDoAssignment.new())
	root.add_child(order)
	var engage := BTDynamicSequence.new()
	var known := BTHasContact.new()
	known.max_age = 8.0
	engage.add_child(known)
	engage.add_child(BTDirectedEngage.new())
	root.add_child(engage)
	root.add_child(BTIdle.new())
	var bt := BehaviorTree.new()
	bt.set_root_task(root)
	return bt


## The Soldier component of a task's agent (the pawn's body).
static func soldier_of(agent: Node) -> Soldier:
	return agent.get_node_or_null(^"Soldier") as Soldier
