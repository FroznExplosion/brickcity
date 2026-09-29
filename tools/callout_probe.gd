extends SceneTree

## Acceptance probe for callouts (Docs/AIPlan.md P6, AI.md 6.5, A18), in an arena.
##
##     godot --headless --path . --script tools/callout_probe.gd
##
## A player's camera at the origin looking down -Z, and speakers round it, each
## saying one line. What the player is shown, per speaker:
##
##   enemy in view, nothing between      subtitle, attributed, marker (depth-tested)
##   enemy in view, behind a wall        subtitle, unattributed, NO marker
##   enemy in view, behind smoke         subtitle, unattributed, NO marker
##   enemy behind the camera             subtitle, unattributed, NO marker
##   enemy out of earshot                nothing
##   friendly behind a wall              subtitle, attributed, marker through walls
##
## Then the rate limits: one line per squad every SQUAD_GAP, a repeat of the same
## line dropped, an urgent line to the front.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var cam: Camera3D
var hud: CalloutHud
var me: Pawn
var sp := {}
var _tick := 0
var _t0 := 0.0


func _init() -> void:
	print("callout probe")
	a = Arena.new(self, 5)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _build() -> void:
	me = a.player(Vector3.ZERO, 1e7, false)
	cam = Camera3D.new()
	root.add_child(cam)
	cam.global_position = me.eye.global_position
	cam.rotation = Vector3.ZERO   # down -Z
	cam.current = true
	var l := a.s.callouts.listen(cam, 0, me)
	hud = CalloutHud.new()
	hud.setup(a.s.callouts, l)
	root.add_child(hud)
	# A wall 10 m out, left of centre, three metres high: speakers behind it at
	# x -4..0 are hidden.
	a.bricks(Vector3i(-14, 0, int(-10.0 / Arena.STUD)), Vector3i(14, 8, 1))
	sp["seen"] = _speaker(Vector3(3.0, 0.0, -12.0), 1)
	sp["walled"] = _speaker(Vector3(-2.5, 0.0, -13.0), 1)
	sp["smoked"] = _speaker(Vector3(14.0, 0.0, -14.0), 1)
	sp["behind"] = _speaker(Vector3(1.0, 0.0, 10.0), 1)
	sp["far"] = _speaker(Vector3(2.0, 0.0, -60.0), 1)
	sp["friend"] = _speaker(Vector3(-1.5, 0.0, -13.0), 0)
	var mid := (cam.global_position + (sp.smoked as Pawn).chest()) * 0.5
	a.s.ai_world.set_smoke(1, mid, 2.0)


func _speaker(at: Vector3, team: int) -> Pawn:
	var p := Pawn.spawn(root, at, team, true, 100.0)
	Soldier._greybox(p, team)
	a.s.add_pawn(p)
	return p


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
		return
	a.tick()
	hud.refresh()
	var now := a.s.now()
	if _tick == 3:
		_t0 = now
		# Each in a squad of its own, so none waits on another.
		var k := 10
		for key in sp:
			a.s.callouts.say(k, sp[key], key, "line from %s" % key, now)
			k += 1
	if _tick == 6:
		_judge_views()
		# The rate limits, on one squad: three lines at once, a repeat, and an
		# urgent one queued last.
		var p: Pawn = sp.seen
		a.s.callouts.say(1, p, "moving", "Moving!", now)
		a.s.callouts.say(1, p, "covering", "Covering!", now)
		a.s.callouts.say(1, p, "moving", "Moving!", now)
		a.s.callouts.say(1, p, "grenade", "Grenade!", now, true)
	if now - _t0 > 6.0:
		_judge_limits()
		print("\n%d passed, %d failed" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)


func _view_of(p: Pawn) -> Callouts.View:
	for v in hud.listener.views:
		if v.line.speaker == p:
			return v
	return null


func _judge_views() -> void:
	var subs := hud.subtitles()
	print("  subtitles: %s" % [subs])
	var v: Callouts.View
	v = _view_of(sp.seen)
	_ok("an enemy the player can see: subtitle, named, and a talking marker over it",
			v != null and v.attributed and hud.marker_state(sp.seen) == {"through_walls": false},
			"marker %s" % [hud.marker_state(sp.seen)])
	for key in ["walled", "smoked", "behind"]:
		v = _view_of(sp[key])
		_ok("an enemy %s: the subtitle only, unattributed, no marker" % {"walled": "behind a wall",
				"smoked": "behind smoke", "behind": "behind the player"}[key],
				v != null and not v.attributed and hud.marker_state(sp[key]).is_empty(),
				"view %s, marker %s" % ["shown" if v != null else "none", hud.marker_state(sp[key])])
	v = _view_of(sp.far)
	_ok("an enemy out of earshot: nothing", v == null and hud.marker_state(sp.far).is_empty())
	v = _view_of(sp.friend)
	_ok("a friendly behind a wall: named, and its marker drawn through the wall",
			v != null and v.attributed and hud.marker_state(sp.friend) == {"through_walls": true},
			"marker %s" % [hud.marker_state(sp.friend)])
	var unnamed := 0
	for s in subs:
		if s.begins_with("?:"):
			unnamed += 1
	_ok("the subtitles on screen match: five lines, three of them unattributed",
			subs.size() == 5 and unnamed == 3, "%d lines, %d unattributed" % [subs.size(), unnamed])


func _judge_limits() -> void:
	var mine := []
	for l in a.s.callouts.said:
		if int(l[1]) == 1:
			mine.append(l)
	var keys := mine.map(func(l): return l[2])
	var gaps := []
	for i in range(1, mine.size()):
		gaps.append(snappedf(float(mine[i][0]) - float(mine[i - 1][0]), 0.01))
	# Four asked at once: the urgent one first, then one more a SQUAD_GAP later;
	# the repeat never queued, and the last waited past QUEUE_LIFE and was dropped
	# -- a stale "covering!" is worse than none.
	_ok("urgent first, then one at a time; the repeat and the stale line dropped",
			keys == ["grenade", "moving"], "said %s, %s s apart" % [keys, gaps])
	_ok("a squad speaks no more than one line every %.1f s" % Callouts.SQUAD_GAP,
			gaps.size() == 1 and float(gaps[0]) >= Callouts.SQUAD_GAP - 0.01, "%s" % [gaps])
