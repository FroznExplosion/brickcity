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
	## Seen this sensing pass.
	var visible := false
	## A search of its last known position has been made and found nothing.
	var searched := false

	func age(now: float) -> float:
		return now - maxf(seen_at, heard_at)


var contacts := {}   # pawn instance id (or -1 for an unknown noise) -> Contact


func saw(pawn: Pawn, pos: Vector3, now: float) -> void:
	var c := _contact(pawn)
	c.pos = pos
	c.seen_at = now
	c.visible = true
	c.searched = false


func lost_sight(pawn: Pawn) -> void:
	var key := pawn.get_instance_id()
	if contacts.has(key):
		(contacts[key] as Contact).visible = false


func heard(pawn: Pawn, pos: Vector3, now: float) -> void:
	var c := _contact(pawn)
	# A noise moves what is known only if nothing better is: a contact in sight
	# is where it is seen, not where its gun was heard.
	if not c.visible:
		c.pos = pos
		c.searched = false
	c.heard_at = now


## The contact to fight: the freshest.
func best(now: float) -> Contact:
	var out: Contact = null
	for k in contacts:
		var c: Contact = contacts[k]
		if c.pawn != null and (not is_instance_valid(c.pawn) or c.pawn.health == null
				or c.pawn.health.is_dead()):
			continue
		if out == null or c.age(now) < out.age(now):
			out = c
	return out


func _contact(pawn: Pawn) -> Contact:
	var key := pawn.get_instance_id() if pawn != null else -1
	if not contacts.has(key):
		var c := Contact.new()
		c.pawn = pawn
		contacts[key] = c
	return contacts[key]
