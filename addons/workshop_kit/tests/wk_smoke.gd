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
	_toolbox()
	_sketch_tool()
	_paint_tool()
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


func _click(button: int, pressed: bool, double := false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.double_click = double
	return e


func _toolbox() -> void:
	var box := WkToolbox.new()
	var ctx := _Ctx.new()
	box.ctx = ctx
	var a := WkTool.new()
	a.id = &"a"
	var b := WkTool.new()
	b.id = &"b"
	box.add(a)
	box.add(b)
	_ok("nothing in hand at first", box.active() == null and not box.input(InputEventKey.new()))
	box.use(&"a")
	_ok("use takes a tool up, with the context", box.active_id() == &"a" and a.active and a.ctx == ctx)
	box.use(&"b")
	_ok("and puts the one before down", not a.active and b.active and box.tool(&"a") == a)
	box.use(&"")
	_ok("none", box.active() == null and not b.active)


func _sketch_tool() -> void:
	var ctx := _Ctx.new()
	var box := WkToolbox.new()
	box.ctx = ctx
	var sk: WkSketchTool = box.add(WkSketchTool.new())
	box.use(&"sketch")
	# A click with the freehand pen: one point, handed over on release.
	ctx.at = Vector2(3, 4)
	_ok("a press starts a stroke on the editor's plane", box.input(_click(MOUSE_BUTTON_LEFT, true))
			and sk.drawing() and ctx.begun == 1)
	box.input(_click(MOUSE_BUTTON_LEFT, false))
	_ok("release hands it over and clears the pen", ctx.commits.size() == 1 and ctx.commits[0].plane == "top"
			and (ctx.commits[0].points as Array).size() == 1 and sk.pen.points.is_empty() and not sk.drawing())
	# A polygon, clicked corner by corner; closed on the first corner.
	sk.pen.draw = "polygon"
	for q in [Vector2(0, 0), Vector2(5, 0), Vector2(5, 5), Vector2(0, 5)]:
		ctx.at = q
		box.input(_click(MOUSE_BUTTON_LEFT, true))
		box.input(_click(MOUSE_BUTTON_LEFT, false))
	_ok("a polygon is not handed over corner by corner", ctx.commits.size() == 1 and sk.pen.points.size() == 4)
	ctx.at = Vector2(0.2, 0.1)
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	_ok("a click on its first corner closes it", ctx.commits.size() == 2
			and (ctx.commits[1].points as Array).size() == 4 and not ctx.commits[1].out)
	# RMB takes away, unless it cancels.
	sk.pen.draw = "outline"
	box.input(_click(MOUSE_BUTTON_RIGHT, true))
	box.input(_click(MOUSE_BUTTON_RIGHT, false))
	_ok("RMB draws a stroke that takes away", ctx.commits.size() == 3 and ctx.commits[2].out)
	sk.rmb_cancels = true
	_ok("with rmb_cancels, RMB outside a stroke is not the tool's", not box.input(_click(MOUSE_BUTTON_RIGHT, true)))
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	box.input(_click(MOUSE_BUTTON_RIGHT, true))
	_ok("and in one gives it up", not sk.drawing() and ctx.cancels == 1 and ctx.commits.size() == 3)
	ctx.removes = true
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	box.input(_click(MOUSE_BUTTON_LEFT, false))
	_ok("the editor can say a stroke takes away (a cut)", ctx.commits.size() == 4 and ctx.commits[3].out)
	ctx.removes = false
	# Refused, and off the plane.
	ctx.refuse = true
	_ok("a refused stroke is used up, not started", box.input(_click(MOUSE_BUTTON_LEFT, true)) and not sk.drawing())
	ctx.refuse = false
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	box.use(&"")
	_ok("putting the tool down gives up its stroke", not sk.drawing() and ctx.cancels == 2)


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e


func _paint_tool() -> void:
	var ctx := _Ctx.new()
	var box := WkToolbox.new()
	box.ctx = ctx
	var pt: WkPaintTool = box.add(WkPaintTool.new())
	box.use(&"paint")
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	_ok("a press starts a stroke and paints under the cursor", pt.stroking()
			and ctx.log == ["begin", "at 0"], str(ctx.log))
	box.input(_click(MOUSE_BUTTON_LEFT, false))
	_ok("release ends it: one step for the editor", not pt.stroking() and ctx.log.back() == "end")
	box.input(_key(KEY_EQUAL))
	box.input(_key(KEY_EQUAL))
	box.input(_key(KEY_MINUS))
	_ok("- = the reach, and the editor is told", pt.radius == 1 and ctx.log.back() == "radius 1")
	pt.radius = 99
	_ok("the reach is held to its most", pt.radius == pt.radius_max)
	pt.radius = 0
	box.input(_click(MOUSE_BUTTON_MIDDLE, true))
	_ok("MMB takes a paint", ctx.log.back() == "pick")
	box.input(_key(KEY_PAGEDOWN))
	_ok("Page Down: the paint before", ctx.log.back() == "step -1")
	box.process(0.016)
	_ok("each frame shows the brush; no stroke, no paint", ctx.log.back() == "hover 0")
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	box.process(0.016)
	_ok("a stroke whose button is up (headless) ends on the next frame", not pt.stroking()
			and ctx.log.slice(-2) == ["hover 0", "end"], str(ctx.log.slice(-3)))
	box.input(_click(MOUSE_BUTTON_LEFT, true))
	box.use(&"")
	_ok("putting the brush down ends its stroke", not pt.stroking() and ctx.log.back() == "end")


## A pretend editor for the tools.
class _Ctx:
	extends WkContext
	var at = Vector2.ZERO
	var begun := 0
	var cancels := 0
	var refuse := false
	var removes := false
	var commits := []

	func sketch_begin(_remove: bool) -> Variant:
		if refuse:
			return null
		begun += 1
		return "top"

	func sketch_point(_plane: Variant) -> Variant:
		return at

	func sketch_removes() -> bool:
		return removes

	func sketch_commit(plane: Variant, pen: WkSketchPen) -> void:
		commits.append({"plane": plane, "points": pen.points.duplicate(), "out": pen.out})

	func sketch_cancel() -> void:
		cancels += 1

	var log := []

	func paint_begin() -> void:
		log.append("begin")

	func paint_at(radius: int) -> bool:
		log.append("at %d" % radius)
		return true

	func paint_end() -> void:
		log.append("end")

	func paint_hover(radius: int) -> void:
		log.append("hover %d" % radius)

	func paint_pick() -> void:
		log.append("pick")

	func paint_step(step: int) -> void:
		log.append("step %d" % step)

	func paint_radius_changed(radius: int) -> void:
		log.append("radius %d" % radius)


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
