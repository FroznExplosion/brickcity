class_name TacticsSense
extends RefCounted
## What is true for a soldier right now, in the book's words (TacticsBook,
## Docs/Tactics): the MOMENT it is in, the FACTS that hold, and the AMOUNTS
## (distance, cover, health, magazine...). Read from the world at each engage
## decision -- cover from AIWorld's bricks against the actual threat, a roof by a
## ray, the rest from the soldier, its squad and what its side knows.
##
## Facts the world cannot answer yet are left out (never true): our armour or
## air support near, the place being worth keeping, our troops in a blast zone,
## an evac, the player's other way out. Each is one more line here when the game
## has it.

## Within this, the player can be hit with what a soldier carries.
const REACH := 2.0
## Further above or below than this, the player is "above us" / "below us".
const LEVEL_DIFF := 2.5
## Closer than this is close quarters.
const CLOSE_QUARTERS := 6.0
## Heights above the feet a body is looked for at: its head and its chest.
const HEAD := CoverSearch.STAND_EYE
const CHEST := CoverSearch.STAND_CHEST
## Hurt within this is being caught out, on a first decision.
const CAUGHT_SECONDS := 2.0
## A player out of sight in full cover, heard within this, is dug in, not lost.
const HEARD_DUG_IN := 3.0
## Another player within this of the target is "teammates near".
const TEAM_NEAR := 15.0
## A friendly soldier outside the squad within this is "other squads near".
const FRIENDS_NEAR := 40.0


## {moment, facts: Array[String], amounts: {dist, pcover, cover, hp, mag, squad, php}}.
static func read(so: Soldier, c: FactionKnowledge.Contact, cover: Dictionary) -> Dictionary:
	var s := so.services
	var now := s.now()
	var feet := so.pawn.feet()
	var them := c.pos
	var dist := feet.distance_to(them)
	var facts: Array = []
	var amounts := {}
	var add := func(f: String) -> void:
		if not facts.has(f):
			facts.append(f)

	# The player.
	add.call("p_seen" if c.visible else "p_suspected")
	if them.y - feet.y > LEVEL_DIFF:
		add.call("p_high")
	elif feet.y - them.y > LEVEL_DIFF:
		add.call("p_low")
	if dist <= REACH:
		add.call("p_reach")
	var p := c.pawn
	if p != null and is_instance_valid(p):
		if String(p.get_meta(&"aggro_kind", "pilot")) == "mech":
			add.call("p_mech")
		if p.gun != null and p.gun.is_reloading():
			add.call("p_reloading")
		if c.visible and p.eye != null:
			var look := -p.eye.global_basis.z
			if look.dot((feet - them).normalized()) < 0.0:
				add.call("p_unaware")
		for q in s.hostiles_of(so.team):
			if q != p and q.feet().distance_to(them) < TEAM_NEAR:
				add.call("p_team")
				break
		amounts["php"] = _health_pct(p)

	# Cover, both ways: bricks across the line from the other's eye to the head
	# and to the chest.
	var mine := cover_level(s, them + Vector3.UP * HEAD, feet)
	var theirs := cover_level(s, so.eye_pos(), them)
	amounts["cover"] = mine
	amounts["pcover"] = theirs
	if theirs > 0:
		add.call("destructible")   # every wall here is bricks
	var inside := BTShelter.covered(s, feet)
	if inside:
		add.call("inside")
	elif cover.is_empty() and mine == 0:
		add.call("open")
	if s.sight_mul < 0.8:
		add.call("low_vis")

	# Us.
	amounts["dist"] = dist
	amounts["hp"] = clampf(so.pawn.health.total_current() / maxf(so.max_health, 1.0), 0.0, 1.0) * 100.0
	var g := so.pawn.gun
	amounts["mag"] = 0.0 if g == null or g.is_reloading() \
			else float(g.ammo) / float(maxi(g.mag_size(), 1)) * 100.0
	var near := 0
	var others := 0
	for ally in so.allies():
		var d := ally.pawn.feet().distance_to(feet)
		if d < CombatPolicy.ALONE_METRES:
			near += 1
		if d < FRIENDS_NEAR and (so.squad == null or ally.squad != so.squad):
			others += 1
	if near == 0:
		add.call("we_alone")
	if others > 0:
		add.call("friends_near")
	amounts["squad"] = 100.0
	if so.squad != null and so.squad.members.size() > 0:
		amounts["squad"] = 100.0 * so.squad.alive().size() / so.squad.members.size()
	match StringName(so.get_meta(&"unit", &"")):
		&"marksman": add.call("we_marksman")

	return {"moment": _moment(so, c, facts, amounts, now), "facts": facts, "amounts": amounts}


static func _moment(so: Soldier, c: FactionKnowledge.Contact, facts: Array, amounts: Dictionary, now: float) -> String:
	if float(amounts.dist) < CLOSE_QUARTERS:
		return "close_quarters"
	if float(amounts.squad) <= 50.0 or (facts.has("we_alone") and float(amounts.hp) < 40.0):
		return "losing"
	if facts.has("p_mech"):
		return "outgunned"
	if facts.has("p_unaware"):
		return "have_jump"
	if so.tactic < 0 and now - so.hurt_at < CAUGHT_SECONDS:
		return "caught_out"
	# Hidden behind full cover but just heard (firing from it): dug in, not lost.
	if int(amounts.pcover) == 2 and (c.visible or now - c.heard_at < HEARD_DUG_IN):
		return "player_dug_in"
	if not c.visible:
		return "lost_player"
	return "first_contact"


## How hidden a body standing at `feet` is from an eye at `from`: 0 in the open,
## 1 partly (head or chest), 2 fully (both).
static func cover_level(s: AIServices, from: Vector3, feet: Vector3) -> int:
	var n := 0
	if not s.ai_world.line_clear(from, feet + Vector3.UP * HEAD):
		n += 1
	if not s.ai_world.line_clear(from, feet + Vector3.UP * CHEST):
		n += 1
	return n


static func _health_pct(p: Pawn) -> float:
	var h := p.health
	if h == null:
		return 100.0
	var top := 0.0
	for cfg in h.layer_configs:
		top += float(cfg.max_value)
	return clampf(h.total_current() / maxf(top, 1.0), 0.0, 1.0) * 100.0
