class_name WkGroup
extends WkCommand

## Commands that undo as one: a run of bricks, a fill, a mirrored pair, a gesture.
##
## Undo takes its commands back newest first, then its `tail` commands newest first; redo
## does them again oldest first, then the tail oldest first. A tail command is a snapshot
## (a sketch, a model's state) that must land after the edits it goes with, either way.

var commands: Array = []


func _init(p_kind: StringName = &"group") -> void:
	kind = p_kind


## Add a command: a tail one (`c.tail`) goes with the tail.
func add(c: WkCommand) -> void:
	commands.append(c)


func body() -> Array:
	return commands.filter(func(c: WkCommand) -> bool: return not c.tail)


func tails() -> Array:
	return commands.filter(func(c: WkCommand) -> bool: return c.tail)


## True if any command in it was undone.
func undo() -> bool:
	var any := false
	var b := body()
	for i in range(b.size() - 1, -1, -1):
		if (b[i] as WkCommand).undo():
			any = true
	var t := tails()
	for i in range(t.size() - 1, -1, -1):
		if (t[i] as WkCommand).undo():
			any = true
	return any


func do() -> bool:
	var any := false
	for c in body():
		if (c as WkCommand).do():
			any = true
	for c in tails():
		if (c as WkCommand).do():
			any = true
	return any


func can_redo() -> bool:
	for c in commands:
		if not (c as WkCommand).can_redo():
			return false
	return true


func leaf_count(kinds: Array = []) -> int:
	var n := 0
	for c in commands:
		n += (c as WkCommand).leaf_count(kinds)
	return n


func leaves() -> Array:
	var out := []
	for c in commands:
		out.append_array((c as WkCommand).leaves())
	return out


## Lift the commands of groups inside it into it (their tails into its tail), so it is one
## level deep: a gesture that made groups of its own still undoes as one, in the order the
## edits were made.
func flatten() -> void:
	var flat := []
	for c in commands:
		if c is WkGroup:
			(c as WkGroup).flatten()
			flat.append_array((c as WkGroup).commands)
		else:
			flat.append(c)
	commands = flat


## Take out one command anywhere inside it. True if it was there.
func remove(c: WkCommand) -> bool:
	var i := commands.find(c)
	if i >= 0:
		commands.remove_at(i)
		return true
	for g in commands:
		if g is WkGroup and (g as WkGroup).remove(c):
			if (g as WkGroup).commands.is_empty():
				commands.erase(g)
			return true
	return false
