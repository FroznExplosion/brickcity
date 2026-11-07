extends SceneTree

## The workshop kit on its own, headless, no game classes:
##
##     godot --headless --path . --script res://addons/workshop_kit/tests/wk_smoke.gd
##
## Exit code 0 when every check passes.

var _pass := 0
var _fail := 0

## A pretend document: a list of numbers, appended in order like bricks in a recipe.
var doc: Array = []
var log_: Array = []


func _init() -> void:
	_undo_stack()
	print("wk_smoke: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL  %s  %s" % [what, detail])


# A number appended to the document, as an editor records it: done first, then pushed.
func _add(stack: WkUndoStack, n: int, redo := true) -> void:
	doc.append(n)
	stack.push(WkCommand.make(&"add", n, _unadd, _readd if redo else Callable()))


func _unadd(c: WkCommand) -> bool:
	if doc.is_empty() or doc.back() != c.data:
		return false
	doc.pop_back()
	log_.append("-%d" % c.data)
	return true


func _readd(c: WkCommand) -> bool:
	doc.append(c.data)
	log_.append("+%d" % c.data)
	return true


func _snap(stack: WkUndoStack, name: String) -> WkCommand:
	return WkCommand.make(&"snap", name,
			func(c: WkCommand) -> bool: log_.append("before:" + c.data); return true,
			func(c: WkCommand) -> bool: log_.append("after:" + c.data); return true)


func _undo_stack() -> void:
	var s := WkUndoStack.new()
	_ok("starts empty", not s.can_undo() and not s.can_redo() and s.size() == 0)
	_ok("undo on empty is false", not s.undo() and s.redo() == null)

	_add(s, 1)
	_add(s, 2)
	_add(s, 3)
	_ok("three pushed", s.size() == 3 and s.kinds() == ["add", "add", "add"])
	_ok("undo takes the newest", s.undo() and doc == [1, 2])
	_ok("redo puts it back", s.redo() != null and doc == [1, 2, 3])
	s.undo()
	_add(s, 9)
	_ok("a new edit forgets redo", not s.can_redo() and doc == [1, 2, 9])

	# Pushes while busy are dropped: the command's own work does not record itself.
	var v0 := s.version
	s.push(WkCommand.make(&"inner", null, func(_c: WkCommand) -> bool: return true))
	_ok("version moves on a push", s.version > v0)
	s.undo()   # the "inner"
	var echo := WkCommand.make(&"echo", null,
			func(_c: WkCommand) -> bool:
				s.push(WkCommand.make(&"stray", null, func(_d: WkCommand) -> bool: return true))
				return true,
			func(_c: WkCommand) -> bool: return true)
	s.push(echo)
	s.undo()
	_ok("a push made while undoing is dropped", s.count(&"stray") == 0 and s.top_kind() == &"add")
	_ok("busy is down again", not s.busy)

	# A command that cannot be redone, undone, forgets redo.
	s.clear()
	doc.clear()
	_add(s, 1)
	_add(s, 2, false)
	_add(s, 3)
	s.undo()
	_ok("redo has one", s.redo_size() == 1)
	s.undo()
	_ok("undoing a no-redo edit forgets redo", s.redo_size() == 0 and doc == [1])

	# A failed single command stays the newest.
	doc = [1, 7]
	_ok("a failed undo is false", not s.undo())
	_ok("and keeps its command", s.size() == 1 and doc == [1, 7])
	doc = [1]

	# group_last: a click and its run.
	s.clear()
	doc.clear()
	_add(s, 1)
	_add(s, 2)
	_add(s, 3)
	_add(s, 4)
	s.group_last(3)
	_ok("the last three are one step", s.size() == 2 and s.kinds() == ["add", "group"])
	_ok("counted inside", s.count(&"add") == 4 and s.leaves().size() == 4)
	_ok("last leaf is the newest inside", s.last_leaf().data == 4)
	log_.clear()
	s.undo()
	_ok("the group goes at once, newest first", doc == [1] and log_ == ["-4", "-3", "-2"], str(log_))
	log_.clear()
	s.redo()
	_ok("and comes back oldest first", doc == [1, 2, 3, 4] and log_ == ["+2", "+3", "+4"], str(log_))
	s.group_last(1)
	_ok("a group of one is no group", s.size() == 2)

	# begin/end, nested, flatten, tails.
	s.clear()
	doc.clear()
	log_.clear()
	s.begin_group()
	_add(s, 1)
	s.begin_group()
	_add(s, 2)
	_add(s, 3)
	s.end_group(false, _snap(s, "inner"))
	_ok("an open group counts its steps", s.size() == 2)
	_add(s, 4)
	s.end_group(true, _snap(s, "outer"))
	_ok("a gesture is one step", s.size() == 1 and s.top() is WkGroup)
	_ok("flattened to one level", (s.top() as WkGroup).commands.filter(func(c): return c is WkGroup).is_empty())
	s.undo()
	_ok("edits first, newest first; then tails, newest first", doc.is_empty()
			and log_ == ["-4", "-3", "-2", "-1", "before:outer", "before:inner"], str(log_))
	log_.clear()
	s.redo()
	_ok("redo: edits oldest first, then tails oldest first", doc == [1, 2, 3, 4]
			and log_ == ["+1", "+2", "+3", "+4", "after:inner", "after:outer"], str(log_))
	s.begin_group()
	s.end_group()
	_ok("an empty group is dropped", s.size() == 1)
	s.group_last(0, _snap(s, "alone"))
	_ok("a tail on its own is kept", s.size() == 2)
	s.begin_group()
	_add(s, 5)
	_ok("undo closes an open group first", s.undo() and doc == [1, 2, 3, 4])

	# forget: the thing a command made went some other way.
	s.clear()
	doc.clear()
	for n in 5:
		_add(s, n)
	s.group_last(2)
	_ok("forget_nth", s.forget_nth(&"add", 1) and s.count(&"add") == 4)
	var gone := s.forget_where(func(c: WkCommand) -> bool: return c.data == 3 or c.data == 4)
	_ok("forget_where takes them from inside groups, empty groups go", gone == 2 and s.size() == 2,
			"%d gone, %d steps" % [gone, s.size()])

	# on_empty: a document's own records, taken back one per Z with no command each.
	s.clear()
	doc = [10, 11]
	_add(s, 12)
	s.on_empty = func() -> WkCommand:
		if doc.size() <= 0:
			return null
		var n: int = doc.pop_back()
		return WkCommand.make(&"opened", n, _unadd, _readd)
	s.undo()
	_ok("on_empty waits for the history to run out", doc == [10, 11])
	s.undo()
	s.undo()
	_ok("then takes the document back, one a step", doc.is_empty() and s.redo_size() == 3)
	_ok("and stops when it has none", not s.undo())
	s.redo()
	_ok("what it took comes back with redo", doc == [10])
	s.on_empty = Callable()

	# alive: an edit whose work went some other way is skipped, not a wasted Z.
	s.clear()
	doc.clear()
	_add(s, 1)
	_add(s, 2)
	var vanished := WkCommand.make(&"add", 3, _unadd, Callable(),
			func(c: WkCommand) -> bool: return doc.has(c.data))
	doc.append(3)
	s.push(vanished)
	doc.erase(3)   # taken away by hand
	_ok("a command with nothing left is skipped", s.undo() and doc == [1] and s.size() == 1)

	# merge
	s.clear()
	var a := _Merging.new()
	s.push(a)
	s.push(_Merging.new())
	s.push(_Merging.new())
	_ok("merge folds into the newest", s.size() == 1 and a.n == 3)


## A command that folds the next one of its kind into itself.
class _Merging:
	extends WkCommand
	var n := 1

	func _init() -> void:
		kind = &"merge"

	func undo() -> bool:
		return true

	func merge(next: WkCommand) -> bool:
		if next.kind != kind:
			return false
		n += 1
		return true
