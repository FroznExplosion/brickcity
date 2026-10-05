class_name AgentTier
extends LimboHSM
## An agent's tier as a state machine (Docs/AI.md 7, 10.2; AIPlan P8): the HSM is
## the LIFECYCLE and nothing else -- behaviour lives in the trees.
##
##   SMART      the full tree at full rate, full perception
##   DIRECTED   a reduced tree at 2-5 Hz: follow the squad, shoot what is in front
##
## A SWARM ROW is not a state here: an agent demoted that far stops being a node
## at all and becomes a row of SwarmCore (SwarmSide), and one promoted from a row
## is born DIRECTED. The ImportanceBudget dispatches `promote` and `demote`; each
## state's enter hook tells the agent (`set_tier`), which swaps its tree and its
## rates. A demoted agent keeps its health and what its side knows.

enum { SMART, DIRECTED }

var smart_state: TierState
var directed_state: TierState


## The HSM for `agent` (a node with `set_tier(int)`), starting in `start`.
static func attach(p_agent: Node, start: int) -> AgentTier:
	var h := AgentTier.new()
	h.name = "Tier"
	h.update_mode = LimboHSM.MANUAL
	var smart := TierState.new()
	smart.name = "Smart"
	smart.tier = SMART
	var directed := TierState.new()
	directed.name = "Directed"
	directed.tier = DIRECTED
	h.add_child(smart)
	h.add_child(directed)
	h.add_transition(smart, directed, &"demote")
	h.add_transition(directed, smart, &"promote")
	h.smart_state = smart
	h.directed_state = directed
	h.initial_state = smart if start == SMART else directed
	p_agent.add_child(h)
	h.initialize(p_agent)
	h.set_active(true)
	return h


func tier() -> int:
	var st := get_active_state() as TierState
	return st.tier if st != null else SMART


## An event, as the transitions say -- and if the HSM did not take it (an agent
## spawned this very tick has not been through an update yet), the state itself.
func promote() -> void:
	if tier() != SMART:
		dispatch(&"promote")
		if tier() != SMART:
			change_active_state(smart_state)


func demote() -> void:
	if tier() != DIRECTED:
		dispatch(&"demote")
		if tier() != DIRECTED:
			change_active_state(directed_state)
