class_name Loadout
extends RefCounted
## What the player carries (Docs/Weapons/COMBAT_DESIGN.md 7.1-7.6), as plain state:
## two groups of two gun slots, an ordnance slot, the third hand (a floor gun being
## tried), and the backpack. No nodes, no input -- PlayerArsenal drives it and shows
## it -- so every rule here is testable without a window.
##
## Slots are numbered 0..3: group 0 is slots 0 and 1, group 1 is slots 2 and 3. A
## "gun" is any Object (a GunInstance in the game, anything in a probe).
##
## Every operation that lets go of a gun returns it in an Array: the caller drops
## those on the floor. Nothing is ever silently lost.

const SLOTS := 4
const BACKPACK_START := 10

var slots: Array = [null, null, null, null]
## The active group (0 or 1) and, per group, which of its two slots is in hand.
var group := 0
var hand := [0, 0]
var ordnance: Object = null
## The ordnance is up instead of the group's gun.
var ordnance_up := false
## A floor gun being tried: in hand over everything else, owned by nobody yet.
var third_hand: Object = null
var backpack: Array = []
var backpack_size := BACKPACK_START


func active_slot() -> int:
	return group * 2 + int(hand[group])


## What is in the player's hands now (null: nothing).
func in_hand() -> Object:
	if third_hand != null:
		return third_hand
	if ordnance_up and ordnance != null:
		return ordnance
	return slots[active_slot()]


func group_has_gun(g: int) -> bool:
	return slots[g * 2] != null or slots[g * 2 + 1] != null


## Put `gun` in `slot` (filling the loadout at the start). Returns what was there.
func set_slot(slot: int, gun: Object) -> Array:
	var out: Array = []
	if slots[slot] != null:
		out.append(slots[slot])
	slots[slot] = gun
	_settle()
	return out


## Tap swap: drop a tried floor gun; else put the ordnance away; else the other gun of
## the group, if there is one.
func tap_swap() -> Array:
	if third_hand != null:
		return [_take_third()]
	if ordnance_up:
		ordnance_up = false
		return []
	var other := 1 - int(hand[group])
	if slots[group * 2 + other] != null:
		hand[group] = other
	return []


## Hold swap: the other group, at the gun last held there. Drops a tried floor gun.
func switch_group() -> Array:
	var out: Array = []
	if third_hand != null:
		out.append(_take_third())
	ordnance_up = false
	if group_has_gun(1 - group):
		group = 1 - group
		_settle()
	return out


## A slot key: with a floor gun in the third hand, keep it there (keep()); else draw
## that slot's gun, if it has one.
func select(slot: int) -> Array:
	if third_hand != null:
		return keep(slot)
	if slots[slot] == null:
		return []
	ordnance_up = false
	group = slot / 2
	hand[group] = slot % 2
	return []


## The ordnance up, or away again. Drops a tried floor gun.
func toggle_ordnance() -> Array:
	if ordnance == null:
		return []
	var out: Array = []
	if third_hand != null:
		out.append(_take_third())
	ordnance_up = not ordnance_up
	return out


## A floor gun into the third hand. Returns the one it replaces there, if any.
func pick_up(gun: Object) -> Array:
	var out: Array = []
	if third_hand != null:
		out.append(_take_third())
	third_hand = gun
	ordnance_up = false
	return out


## The third hand's gun into `slot`, which becomes the gun in hand. The gun it
## replaces goes to the backpack -- or, the backpack full, back to the floor.
func keep(slot: int) -> Array:
	if third_hand == null:
		return []
	var displaced: Object = slots[slot]
	slots[slot] = _take_third()
	group = slot / 2
	hand[group] = slot % 2
	if displaced == null:
		return []
	if backpack.size() < backpack_size:
		backpack.append(displaced)
		return []
	return [displaced]


## The third hand's gun straight into the backpack. False (and nothing moves) when it
## is full.
func stow() -> bool:
	if third_hand == null or backpack.size() >= backpack_size:
		return false
	backpack.append(_take_third())
	return true


## Backpack gun `i` into `slot`; the slot's gun takes its place in the backpack.
func equip_from_backpack(i: int, slot: int) -> void:
	if i < 0 or i >= backpack.size():
		return
	var g: Object = backpack[i]
	if slots[slot] != null:
		backpack[i] = slots[slot]
	else:
		backpack.remove_at(i)
	slots[slot] = g
	_settle()


## Backpack gun `i` out, to the floor.
func drop_from_backpack(i: int) -> Array:
	if i < 0 or i >= backpack.size():
		return []
	var g: Object = backpack[i]
	backpack.remove_at(i)
	return [g]


## Every gun it holds, wherever.
func all_guns() -> Array:
	var out: Array = []
	for g in slots + [ordnance, third_hand] + backpack:
		if g != null and not out.has(g):
			out.append(g)
	return out


func _take_third() -> Object:
	var g := third_hand
	third_hand = null
	return g


## Keep the hand on a slot that holds a gun, and the group on one that has any.
func _settle() -> void:
	if not group_has_gun(group) and group_has_gun(1 - group):
		group = 1 - group
	for g in 2:
		if slots[g * 2 + int(hand[g])] == null and slots[g * 2 + 1 - int(hand[g])] != null:
			hand[g] = 1 - int(hand[g])
