class_name WkToolbox
extends RefCounted

## An editor's tools and which one is in hand: one place that takes them up and puts them
## down, and hands input and frames to the one in hand.
##
##     toolbox.ctx = my_context
##     toolbox.add(WkSketchTool.new())
##     toolbox.use(&"sketch")          # activate; the one before is deactivated
##     if toolbox.input(event): return # the tool in hand used it

## The tool in hand changed (`id` "" when none).
signal changed(id: StringName)

## Handed to every tool when it is taken up.
var ctx: WkContext = null

var _tools := {}
var _active: WkTool = null


## Add a tool (by its `id`); it gets the context now, so the editor can call it before it is
## first taken up. Returns it.
func add(t: WkTool) -> WkTool:
	_tools[t.id] = t
	if t.ctx == null:
		t.ctx = ctx
	return t


## The tool with this id, or null.
func tool(p_id: StringName) -> WkTool:
	return _tools.get(p_id)


## The tool in hand, or null.
func active() -> WkTool:
	return _active


func active_id() -> StringName:
	return _active.id if _active != null else &""


## Take up the tool with this id (none: "" or an id it does not have). The one in hand before
## is put down first. Taking up the one already in hand does nothing.
func use(p_id: StringName) -> void:
	var next: WkTool = _tools.get(p_id)
	if next == _active:
		return
	if _active != null:
		_active.deactivate()
	_active = next
	if _active != null:
		_active.activate(ctx)
	changed.emit(active_id())


## Hand an event to the tool in hand. True if it used it.
func input(e: InputEvent) -> bool:
	return _active != null and _active.input(e)


func process(delta: float) -> void:
	if _active != null:
		_active.process(delta)
