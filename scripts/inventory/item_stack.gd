class_name ItemStack
extends RefCounted
## A stack of one item in one slot (Docs/Inventory.md 3.2): its id, how many,
## and `data` -- what this one stack holds that others of its id may not (a
## bucket's tiles, a source bucket's fluid). Stacks with different `data`
## never merge.
##
## A reference, not a value: the cursor, a slot and a drag all point at the
## same stack, so a count changed through one is seen by all.

var id: StringName = &""
var count := 0
var data := {}


static func make(p_id: StringName, p_count := 1, p_data := {}) -> ItemStack:
	var s := ItemStack.new()
	s.id = p_id
	s.count = p_count
	s.data = p_data.duplicate(true)
	return s


func copy() -> ItemStack:
	return ItemStack.make(id, count, data)


func is_empty() -> bool:
	return count <= 0 or id == &""


## Would `other` merge into this one (same item, same per-stack state)?
func same_kind(other: ItemStack) -> bool:
	return other != null and other.id == id and other.data == data


func to_dict() -> Dictionary:
	var d := {"id": String(id), "count": count}
	if not data.is_empty():
		d["data"] = data
	return d


static func from_dict(d) -> ItemStack:
	if not (d is Dictionary) or not d.has("id"):
		return null
	var s := ItemStack.make(StringName(str(d.id)), int(d.get("count", 1)), d.get("data", {}))
	return null if s.is_empty() else s
