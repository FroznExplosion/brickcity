class_name AggroTable
extends RefCounted
## One enemy side's attention (Docs/AI.md 8, A8): a number per player-side entity
## -- each pilot and each mech -- that grows with the damage it does to the side,
## the noise it makes, being seen and being close, and fades on its own. Whoever
## holds it draws the fire (attack tokens go to it, FactionKnowledge.best picks
## it); whoever does not is free to go round. Pilot and mech are separate rows,
## so the mech sent in loud takes the attention off its pilot.
##
## HYSTERESIS: the focus moves only when another row leads it by a margin, so the
## enemy does not swap targets every time two players trade a few points.

## Gains: per hit point dealt, per round fired within earshot, per second seen by
## the side, per second within NEAR_RANGE of one of its agents.
const DAMAGE := 1.0
const FIRE := 0.5
const SEEN := 3.0
const NEAR := 4.0
const NEAR_RANGE := 10.0
## Aggro halves every HALF_LIFE seconds of doing nothing.
const HALF_LIFE := 8.0
## To take the focus, a row has to beat the holder by this ratio AND this much.
const LEAD_RATIO := 1.25
const LEAD_ABS := 15.0

class Entry:
	var who: Object
	var value := 0.0
	## For the meter: which player it belongs to, and whether it is the pilot or
	## the mech.
	var player := 0
	var kind := "pilot"


var entries := {}   # instance id -> Entry
## What each kind of row's gains count for: the commander's doctrine sets the
## pilot's higher against a player whose mech does the killing (pilot_focus).
var bias := {"pilot": 1.0, "mech": 1.0}
## Times the focus has moved, for gates.
var switches := 0
var _focus_id := 0


func track(who: Object, player := 0, kind := "pilot") -> Entry:
	var id := who.get_instance_id()
	if not entries.has(id):
		var e := Entry.new()
		e.who = who
		e.player = player
		e.kind = kind
		entries[id] = e
	return entries[id]


func add(who: Object, amount: float) -> void:
	if who == null or amount <= 0.0:
		return
	var e := track(who)
	e.value += amount * float(bias.get(e.kind, 1.0))
	_refresh()


func value(who: Object) -> float:
	var e: Entry = entries.get(who.get_instance_id() if who != null else 0)
	return e.value if e != null else 0.0


## Its part of the side's whole attention, 0..1: what the meter shows.
func share(who: Object) -> float:
	var total := 0.0
	for k in entries:
		total += (entries[k] as Entry).value
	return value(who) / total if total > 0.0 else 0.0


## Who holds the attention, or null.
func focus() -> Object:
	var e: Entry = entries.get(_focus_id)
	if e == null or not is_instance_valid(e.who):
		return null
	return e.who


## Fade by `dt` seconds.
func decay(dt: float) -> void:
	var k := pow(0.5, dt / HALF_LIFE)
	var dead := []
	for id in entries:
		var e: Entry = entries[id]
		if not is_instance_valid(e.who):
			dead.append(id)
			continue
		e.value *= k
	for id in dead:
		entries.erase(id)
	_refresh()


func _refresh() -> void:
	var holder: Entry = entries.get(_focus_id)
	var best: Entry = null
	for id in entries:
		var e: Entry = entries[id]
		if e != holder and (best == null or e.value > best.value):
			best = e
	if best == null:
		return
	if holder == null or not is_instance_valid(holder.who):
		if best.value > 0.0:
			_focus_id = best.who.get_instance_id()
			switches += 1
		return
	if best.value > holder.value * LEAD_RATIO and best.value > holder.value + LEAD_ABS:
		_focus_id = best.who.get_instance_id()
		switches += 1
