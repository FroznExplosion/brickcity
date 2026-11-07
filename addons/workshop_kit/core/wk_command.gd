class_name WkCommand
extends RefCounted

## One edit, as the undo stack keeps it (WkUndoStack). Pushed AFTER the edit is made: the
## editor does the work, then records how to take it back and how to do it again.
##
## Two ways to make one:
##
##   * `WkCommand.make(kind, data, undo_fn, do_fn)` -- the editor keeps the logic, the command
##     keeps the data. `undo_fn` and `do_fn` take the command (`func(c: WkCommand) -> bool`) and
##     may change `c.data` (a redo that lays a brick again records where it went).
##     No `do_fn`: the edit can be undone but not redone.
##   * Extend this class and override `undo`, `do`, `can_redo`, `merge`.
##
## `kind` is free text the editor picks ("brick", "paint", ...); the stack only uses it to
## count, find and forget commands (`WkUndoStack.count`, `forget_where`).

## What sort of edit this is.
var kind: StringName = &""
## What the edit needs to be undone or done again. Anything.
var data: Variant = null
## Run after the other commands of a group, both ways (WkGroup): a snapshot of state that the
## group's own edits must not overwrite.
var tail := false

var _undo_fn := Callable()
var _do_fn := Callable()
var _alive_fn := Callable()


## `alive_fn` (`func(c: WkCommand) -> bool`), if given: whether the edit still has anything to
## take back (`alive`).
static func make(p_kind: StringName, p_data: Variant, undo_fn: Callable, do_fn := Callable(),
		alive_fn := Callable()) -> WkCommand:
	var c := WkCommand.new()
	c.kind = p_kind
	c.data = p_data
	c._undo_fn = undo_fn
	c._do_fn = do_fn
	c._alive_fn = alive_fn
	return c


## Take the edit back. False if it could not be (the stack keeps it, for a single command).
func undo() -> bool:
	return bool(_undo_fn.call(self)) if _undo_fn.is_valid() else false


## Do the edit again, after an undo. False if it could not be.
func do() -> bool:
	return bool(_do_fn.call(self)) if _do_fn.is_valid() else false


## Whether there is still anything to take back: what the edit made may have gone some other
## way since (deleted by hand). Undo drops a command that is not alive and goes on to the next,
## so Z never does nothing. Default: alive.
func alive() -> bool:
	return bool(_alive_fn.call(self)) if _alive_fn.is_valid() else true


## Whether `do` can follow `undo`. Undoing one that cannot forgets everything redo had.
func can_redo() -> bool:
	return _do_fn.is_valid()


## Fold `next`, the edit made just after this one, into this one, so they undo as one.
## True if it was folded (the stack then keeps only this one). Default: never.
func merge(_next: WkCommand) -> bool:
	return false


## How many single edits this is (1; a group: its commands, counted down).
## `kinds`: only those kinds (empty: all).
func leaf_count(kinds: Array = []) -> int:
	return 1 if kinds.is_empty() or kinds.has(kind) else 0


## This and every command inside it, oldest first.
func leaves() -> Array:
	return [self]
