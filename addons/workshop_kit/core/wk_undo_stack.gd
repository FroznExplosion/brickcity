class_name WkUndoStack
extends RefCounted

## One undo history for an editor: every edit any tool makes is one WkCommand pushed here,
## and Z / Shift Z take the newest back or do it again. Strictly last in, first out -- an
## editor whose records are appended in order (bricks numbered by when they were laid) can
## rely on undo never reaching past a newer edit.
##
##     stack.push(WkCommand.make(&"paint", stroke, _unpaint, _repaint))
##     stack.begin_group()   ... edits ...   stack.end_group()    # undo as one
##     stack.group_last(2)                                         # the last two, as one
##     stack.undo(); stack.redo()
##
## While a command is being undone or done again `busy` is true and pushes are dropped: the
## edit functions a command calls to put things back do not record themselves a second time.
##
## A command that is no longer `alive` (what it made went some other way) is skipped by undo.
##
## A new edit forgets what redo had (`push`, `forget_redo`). Undoing a command that cannot be
## redone (`WkCommand.can_redo`) forgets it too, so redo never jumps over a gap.

## Something was pushed, undone, done again, grouped, forgotten or cleared.
signal changed

## True while a command is being undone or redone.
var busy := false
## Undo with nothing left calls this, if set: `func() -> WkCommand`, which takes back one more
## thing that has no command of its own -- the records of a document as it was opened, one per
## Z, without a command for each -- and returns a command that does it again (or one that
## cannot be redone), or null when there is nothing more.
var on_empty := Callable()
## Goes up by one with every change: cheap to compare for "has the history moved".
var version := 0

var _done: Array = []
var _undone: Array = []
var _open: Array = []    ## groups begun and not ended, innermost last


## Record an edit that has just been made. Dropped while `busy`.
func push(c: WkCommand) -> void:
	if busy or c == null:
		return
	var into := _container()
	if not into.is_empty() and (into.back() as WkCommand).merge(c):
		pass
	else:
		into.append(c)
	_undone.clear()
	_changed()


## Everything pushed from here to `end_group` undoes as one. Groups nest.
func begin_group(kind: StringName = &"group") -> void:
	_open.append(WkGroup.new(kind))


## Close the group `begin_group` opened. An empty group is dropped; a group of one command is
## that command. `flatten`: groups made inside it are lifted into it (WkGroup.flatten).
## `tail`: a snapshot command added after its edits (WkCommand.tail) -- a group of none but a
## tail is kept.
func end_group(flatten := false, tail: WkCommand = null) -> void:
	if _open.is_empty():
		return
	var g: WkGroup = _open.pop_back()
	if flatten:
		g.flatten()
	_finish(g, tail)


## The last `n` commands pushed, as one group (with `tail` after them, if given): a click and
## the run it began, a brick and its mirror image.
func group_last(n: int, tail: WkCommand = null, kind: StringName = &"group") -> void:
	var into := _container()
	n = clampi(n, 0, into.size())
	if n <= 1 and tail == null:
		return
	var g := WkGroup.new(kind)
	g.commands = into.slice(into.size() - n)
	into.resize(into.size() - n)
	_finish(g, tail)


## Take back the newest edit. False if there was none or it could not be undone.
func undo() -> bool:
	_close_open()
	if busy:
		return false
	while not _done.is_empty() and not (_done.back() as WkCommand).alive():
		_done.pop_back()   # nothing left to take back: not a step of its own
	if _done.is_empty():
		return _undo_beyond()
	# It stays in the history while it runs, so what it calls (renumbering what the history
	# keeps, `leaves`) still reaches the commands inside it not undone yet.
	var c: WkCommand = _done.back()
	busy = true
	var ok := c.undo()
	busy = false
	if not ok and not c is WkGroup:
		return false   # nothing happened: it is still the newest edit
	_done.erase(c)
	if c.can_redo():
		_undone.append(c)
	else:
		_undone.clear()
	_changed()
	return ok


func _undo_beyond() -> bool:
	if not on_empty.is_valid():
		return false
	busy = true
	var c = on_empty.call()
	busy = false
	if c == null:
		return false
	if (c as WkCommand).can_redo():
		_undone.append(c)
	else:
		_undone.clear()
	_changed()
	return true


## Do the newest undone edit again. Returns it, or null if there was none or it failed.
func redo() -> WkCommand:
	_close_open()
	if _undone.is_empty() or busy:
		return null
	var c: WkCommand = _undone.pop_back()
	_done.append(c)   # in the history while it runs, as for undo
	busy = true
	var ok := c.do()
	busy = false
	if not ok and not c is WkGroup:
		_done.erase(c)
	_changed()
	return c if ok else null


## A new edit that records no command of its own still makes redo meaningless. Not while busy.
func forget_redo() -> void:
	if busy or _undone.is_empty():
		return
	_undone.clear()
	_changed()


## Forget everything: a new document.
func clear() -> void:
	_done.clear()
	_undone.clear()
	_open.clear()
	busy = false
	_changed()


func can_undo() -> bool:
	return not _done.is_empty()


func can_redo() -> bool:
	return not _undone.is_empty()


## How many steps undo can take (a group is one; commands in an open group count as theirs).
func size() -> int:
	var n := _done.size()
	for g in _open:
		n += (g as WkGroup).commands.size()
	return n


## How many steps redo can take.
func redo_size() -> int:
	return _undone.size()


## The newest step, or null.
func top() -> WkCommand:
	for i in range(_open.size() - 1, -1, -1):
		var cs: Array = (_open[i] as WkGroup).commands
		if not cs.is_empty():
			return cs.back()
	return null if _done.is_empty() else _done.back()


## The kind of the newest step ("" if none).
func top_kind() -> StringName:
	var t := top()
	return t.kind if t != null else &""


## The newest single command (inside a group, its newest), or null.
func last_leaf() -> WkCommand:
	var t := top()
	while t is WkGroup:
		var g := t as WkGroup
		t = null if g.commands.is_empty() else g.commands.back()
	return t


## Each step's kind, oldest first.
func kinds() -> Array:
	var out := []
	for c in _done:
		out.append(String((c as WkCommand).kind))
	for g in _open:
		for c in (g as WkGroup).commands:
			out.append(String((c as WkCommand).kind))
	return out


## How many single commands of this kind undo can reach, counted inside groups.
func count(kind: StringName) -> int:
	var n := 0
	for c in leaves():
		if (c as WkCommand).kind == kind:
			n += 1
	return n


## Every single command undo can reach, oldest first, groups opened.
func leaves() -> Array:
	var out := []
	for c in _done:
		out.append_array((c as WkCommand).leaves())
	for g in _open:
		out.append_array((g as WkGroup).leaves())
	return out


## Forget single commands without undoing them: the thing they made is gone some other way.
## `pred(c: WkCommand) -> bool`; groups left empty go too. Returns how many went.
func forget_where(pred: Callable) -> int:
	var going := leaves().filter(pred)
	for c in going:
		_forget(c)
	if not going.is_empty():
		_changed()
	return going.size()


## Forget the `n`-th single command of this kind, counted oldest first. True if there was one.
func forget_nth(kind: StringName, n: int) -> bool:
	for c in leaves():
		if (c as WkCommand).kind != kind:
			continue
		if n == 0:
			_forget(c)
			_changed()
			return true
		n -= 1
	return false


# ---------------------------------------------------------------------------

func _container() -> Array:
	return _done if _open.is_empty() else (_open.back() as WkGroup).commands


func _finish(g: WkGroup, tail: WkCommand) -> void:
	if tail != null:
		tail.tail = true
		g.add(tail)
	var into := _container()
	if g.commands.is_empty():
		_changed()
		return
	if g.commands.size() == 1 and not (g.commands[0] as WkCommand).tail:
		into.append(g.commands[0])
	else:
		into.append(g)
	_changed()


func _close_open() -> void:
	while not _open.is_empty():
		end_group()


func _forget(c: WkCommand) -> void:
	for list in [_done] + _open.map(func(g: WkGroup) -> Array: return g.commands):
		var i: int = (list as Array).find(c)
		if i >= 0:
			(list as Array).remove_at(i)
			return
		for g in list:
			if g is WkGroup and (g as WkGroup).remove(c):
				if (g as WkGroup).commands.is_empty():
					(list as Array).erase(g)
				return


func _changed() -> void:
	version += 1
	changed.emit()
