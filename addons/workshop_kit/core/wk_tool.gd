class_name WkTool
extends RefCounted

## One tool of an editor: what it does with input while it is in hand. Each shared tool is one
## file under `addons/workshop_kit/tools/`; an editor's own tools extend this too, in the
## editor's folders. A tool talks to the editor only through its WkContext (`ctx`).
##
## The editor (or a WkToolbox) calls `activate` when the tool is taken in hand, `deactivate`
## when it is put down, `input` with each event (true: used, stop there) and `process` each
## frame.

## What the editor calls it: "sketch", "paint" ...
var id: StringName = &""
## Its name on a button.
var label := ""
## Its key, as written on the button ("K", "Alt D"); the editor binds it.
var key := ""
## The seam to the editor.
var ctx: WkContext = null
## In hand now.
var active := false


func activate(p_ctx: WkContext) -> void:
	ctx = p_ctx
	active = true


func deactivate() -> void:
	active = false


## An input event while in hand. True if the tool used it.
func input(_e: InputEvent) -> bool:
	return false


func process(_delta: float) -> void:
	pass


## The tool's options, for the editor's option panel; null if it has none.
func options_ui() -> Control:
	return null


## One line on what to do next, for the editor's hint line.
func hint() -> String:
	return ""
