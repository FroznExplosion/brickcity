class_name FactionKnowledge
extends RefCounted
## What one side knows about the enemy (Docs/AI.md 4.2): where each contact is,
## when it was last seen, when last heard. Shared inside a side -- one soldier
## sees, the others know -- and never across: the enemy does not know where your
## mech saw you.

class Contact:
	var pawn: Pawn
	## Where it was when last seen, or where the noise came from.
	var pos := Vector3.ZERO
	var seen_at := -INF
	var heard_at := -INF
	## Seen by somebody on the side this sensing pass.
	var visible := false
	## A search of its last known position has been made and found nothing.
	var searched := false
	## Who on the side has it in sight: seer instance id -> true. One soldier
	## losing sight of it does not blind the soldier beside him who still has it.
	var seen_by := {}

	func age(now: float) -> float:
		return now - maxf(seen_at, heard_at)


var contacts := {}   # pawn instance id (or -1 for an unknown noise) -> Contact
## The side's aggro table (AI.md 8), when it has one: the contact to fight is the
## one holding the side's attention, not merely the freshest.
var aggro: AggroTable


func saw(pawn: Pawn, pos: Vector3, now: float, seer: Object = null) -> void:
	var c := _contact(pawn)
	c.pos = pos
	c.seen_at = now
	c.visible = true
	c.searched = false
	c.seen_by[seer.get_instance_id() if seer != null else 0] = true


func lost_sight(pawn: Pawn, seer: Object = null) -> void:
	var key := pawn.get_instance_id()
	if contacts.has(key):
		var c: Contact = contacts[key]
		c.seen_by.erase(seer.get_instance_id() if seer != null else 0)
		c.visible = not c.seen_by.is_empty()


## A seer is gone (dead, removed): whatever it alone had in sight is out of sight.
func forget_seer(seer: Object) -> void:
	var id := seer.get_instance_id()
	for k in contacts:
		var c: Contact = contacts[k]
		if c.seen_by.erase(id):
			c.visible = not c.seen_by.is_empty()


func heard(pawn: Pawn, pos: Vector3, now: float) -> void:
	var c := _contact(pawn)
	# A noise moves what is known only if nothing better is: a contact in sight
	# is where it is seen, not where its gun was heard.
	if not c.visible:
		c.pos = pos
		c.searched = false
	c.heard_at = now


## The contact to fight. The one the side's aggro is on, if it is fresh (known
## within FRESH seconds); otherwise the freshest.
const FRESH := 2.5


func best(now: float) -> Contact:
	var out: Contact = null
	var focus: Object = aggro.focus() if aggro != null else null
	for k in contacts:
		var c: Contact = contacts[k]
		if c.pawn != null and (not is_instance_valid(c.pawn) or c.pawn.health == null
				or c.pawn.health.is_dead()):
			continue
		if focus != null and c.pawn == focus and c.age(now) <= FRESH:
			return c
		if out == null or c.age(now) < out.age(now):
			out = c
	return out


func of(pawn: Pawn) -> Contact:
	return contacts.get(pawn.get_instance_id() if pawn != null else -1)


func _contact(pawn: Pawn) -> Contact:
	var key := pawn.get_instance_id() if pawn != null else -1
	if not contacts.has(key):
		var c := Contact.new()
		c.pawn = pawn
		contacts[key] = c
	return contacts[key]
