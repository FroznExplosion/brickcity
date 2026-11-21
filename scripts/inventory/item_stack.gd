class_name ItemStack
extends RefCounted
## A stack of one item in one slot (Docs/Inventory.md 3.2): its id, how many,
## and `data` -- what this one stack holds that others of its id may not (a
## bucket's tiles, a source bucket's fluid). Stacks with different `data`
## never merge.
##
## A reference, not a value: the cursor, a slot and a drag all point at the
## same stack, so a count changed through one is seen by all.
##
## A backpack's stack also holds what is in it (`contents`, Docs/Inventory.md
## 8): its slots, each a stack or null. Wherever the stack goes -- a chest,
## the ground, the cursor -- its contents go too (zylanntest's rule).

var id: StringName = &""
var count := 0
var data := {}
## A backpack's slots (ItemStack or null); empty for anything else.
var contents: Array = []


static func make(p_id: StringName, p_count := 1, p_data := {}) -> ItemStack:
	var s := ItemStack.new()
	s.id = p_id
	s.count = p_count
	s.data = p_data.duplicate(true)
	return s


## A new stack of the same; a backpack's copy shares its contents (the same
## things, moved, not doubled).
func copy() -> ItemStack:
	var s := ItemStack.make(id, count, data)
	s.contents = contents
	return s


func is_empty() -> bool:
	return count <= 0 or id == &""


## Would `other` merge into this one (same item, same per-stack state)?
func same_kind(other: ItemStack) -> bool:
	return (other != null and other.id == id and other.data == data
			and contents.is_empty() and other.contents.is_empty())


func to_dict() -> Dictionary:
	var d := {"id": String(id), "count": count}
	if not data.is_empty():
		d["data"] = data
	if not contents.is_empty():
		var c := []
		for s in contents:
			if s == null:
				c.append(null)
			else:
				c.append((s as ItemStack).to_dict())
		d["contents"] = c
	return d


static func from_dict(d) -> ItemStack:
	if not (d is Dictionary) or not d.has("id"):
		return null
	var s := ItemStack.make(StringName(str(d.id)), int(d.get("count", 1)), d.get("data", {}))
	var c = d.get("contents", [])
	if c is Array:
		for e in c:
			s.contents.append(ItemStack.from_dict(e))
	return null if s.is_empty() else s
