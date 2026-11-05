## Where a frame's wall time goes, by the clock: the physics ticks' scripts
## (this city's own tick apart), the physics step after them (the solver),
## idle process, and drawing. For the exit report's "[prof] slow frames".
##
## Not Godot's TIME_PHYSICS_PROCESS / TIME_PROCESS monitors: those are the
## WORST frame of the last second, set once a second, so a reading in a frame
## is not that frame's -- a census line's "physics 47 ms this frame" was a
## second's maximum, and subtracting this frame's script from it was not the
## solver.
##
## The marks, in the order a frame runs them: SceneTree.physics_frame (a tick's
## scripts start), this node's _physics_process (they end -- it runs last,
## process_physics_priority), the physics step until the next tick's
## physics_frame or the frame's process_frame, idle process until
## RenderingServer.frame_pre_draw, drawing until frame_post_draw. A frame is
## counted from one process_frame to the next.
##
## The draw mark is the renderer's CPU side and any wait for the swap (vsync,
## a test window's pinned 16.6 ms), so the GPU's own time is read beside it
## (viewport_get_measured_render_time_gpu, a read-back: probe passes only).
class_name FrameClock
extends Node

## A frame over this goes into the slow tally.
const SLOW_MS := 33.3

## This city's own tick, added by the city when it ends (CityScene).
var script_ms := 0.0

var _at := 0          # usec of the last mark
var _in := ""         # what the time since _at is going on
var _frame := {}      # this frame's buckets, ms
var _frame_start := 0
var slow := {"n": 0, "ms": 0.0, "city": 0.0, "scripts": 0.0, "step": 0.0, "process": 0.0,
		"draw": 0.0, "sync": 0.0, "gpu": 0.0, "by": {}, "worst": []}
var frames := 0
var all_ms := 0.0
var all := {}   # every frame's buckets, summed
var _vp := RID()
## Frames the pass itself made slow (a screenshot's read-back, a census) are
## left out: spoil() before the work, and this frame and the next go uncounted.
var _spoiled := 0
var spoiled_frames := 0


func _ready() -> void:
	process_physics_priority = 1 << 30
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	get_tree().physics_frame.connect(_mark.bind("scripts"))
	get_tree().process_frame.connect(_on_process_frame)
	RenderingServer.frame_pre_draw.connect(_mark.bind("draw"))
	RenderingServer.frame_post_draw.connect(_mark.bind("between"))


func _physics_process(_delta: float) -> void:
	_mark("step")


func _mark(next: String) -> void:
	var now := Time.get_ticks_usec()
	if _in != "":
		_frame[_in] = float(_frame.get(_in, 0.0)) + float(now - _at) / 1000.0
	_at = now
	_in = next


func _on_process_frame() -> void:
	_mark("process")
	var now := _at
	if _frame_start > 0:
		_close(float(now - _frame_start) / 1000.0)
	_frame_start = now
	_frame = {}
	script_ms = 0.0


func spoil() -> void:
	_spoiled = 2


func _close(ms: float) -> void:
	if _spoiled > 0:
		_spoiled -= 1
		spoiled_frames += 1
		return
	# The city's tick is inside the scripts' bucket: take it out.
	var parts := {"city": script_ms,
			"scripts": maxf(float(_frame.get("scripts", 0.0)) - script_ms, 0.0),
			"step": float(_frame.get("step", 0.0)),
			"process": float(_frame.get("process", 0.0)),
			"draw": float(_frame.get("draw", 0.0)),
			# After drawing until the first tick's scripts: the physics sync and
			# its callbacks, and the wait for the frame's turn (vsync, the cap).
			"sync": float(_frame.get("between", 0.0)),
			"gpu": RenderingServer.viewport_get_measured_render_time_gpu(_vp)}
	frames += 1
	all_ms += ms
	for k in parts:
		all[k] = float(all.get(k, 0.0)) + float(parts[k])
	if ms <= SLOW_MS:
		return
	slow.n += 1
	slow.ms += ms
	var top := ""
	for k in parts:
		slow[k] += float(parts[k])
		if k == "gpu":
			continue   # beside draw, not a part of the frame's sum
		if top == "" or float(parts[k]) > float(parts[top]):
			top = k
	slow.by[top] = int(slow.by.get(top, 0)) + 1
	var w: Array = slow.worst
	w.append([ms, parts, Engine.get_physics_frames()])
	w.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	if w.size() > 8:
		w.resize(8)


func report_lines() -> Array[String]:
	var out: Array[String] = []
	if frames == 0:
		return out
	var keys := ["city", "scripts", "step", "process", "draw", "sync", "gpu"]
	var line := "frames by the clock: %d (%d left out for the pass's own work), %.1f ms mean =" % [
			frames, spoiled_frames, all_ms / frames]
	for k in keys:
		line += " %s %.1f" % [k, float(all.get(k, 0.0)) / frames]
	out.append(line + "  (city = this script's tick, scripts = the other nodes', step = the physics step, process = idle, draw = the renderer, sync = the physics sync and the wait for the frame; gpu = the GPU's time, beside draw)")
	if int(slow.n) == 0:
		return out
	var n := float(slow.n)
	line = "slow frames: %d over %.1f ms, %.1f ms mean =" % [slow.n, SLOW_MS, slow.ms / n]
	for k in keys:
		line += " %s %.1f" % [k, float(slow[k]) / n]
	out.append(line + "; biggest part %s" % [slow.by])
	for f: Array in slow.worst:
		var parts: Dictionary = f[1]
		line = "  %.1f ms near tick %d:" % [f[0], f[2]]
		for k in keys:
			line += " %s %.1f" % [k, float(parts[k])]
		out.append(line)
	return out
