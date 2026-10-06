extends SceneTree

## Probe for soldiers reading the book's facts and amounts from the world
## (TacticsSense) and the book deciding a fight (BookCombatPolicy, Docs/Tactics).
##
##     godot --headless --path . --script tools/tactics_sense_probe.gd
##
## 1. Readings, one small arena each, a hundred metres apart (no AI running, so
##    nothing moves): face to face in the open; the player behind a brick wall;
##    the player up on a platform; within melee reach; the soldier under a roof;
##    the player looking the other way. Each must read as the casebook means it.
## 2. A squad of three fights a player for 25 s with the book deciding
##    (-- --tactics=book does the same in the game): every decision carries the
##    book's plan, its tactic is the one the plan's move maps to, the soldiers
##    shoot, and what the book asked for that the game cannot do yet is counted.

const Arena := preload("res://tools/ai_arena.gd")
const FIGHT_SECONDS := 25.0
const TALLY := "user://tactics_tally_probe.json"

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _cases := {}
var _squad: Squad
var _player: Pawn
var _policy: BookCombatPolicy
var _t0 := -1.0


func _init() -> void:
	print("tactics sense probe")
	a = Arena.new(self, 11)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x / Arena.STUD), roundi(p.y / Arena.PLATE), roundi(p.z / Arena.STUD))


## A soldier at `bx` and a player `off` from it, looking at each other.
func _pair(name: String, bx: float, off: Vector3) -> void:
	var so := a.soldier(Vector3(bx, 0.0, 0.0), 1, 30 + _cases.size())
	var p := a.player(Vector3(bx, 0.0, 0.0) + off, 1e7, true, _cases.size())
	_cases[name] = {"so": so, "p": p}


## Players face their soldier -- but the unaware one looks away.
func _face() -> void:
	for name in _cases:
		var so: Soldier = _cases[name].so
		var p: Pawn = _cases[name].p
		var at := so.pawn.feet() + Vector3.UP * 1.4
		if name == "unaware":
			at = p.feet() * 2.0 - at + Vector3.UP * 2.8
		Arena.look(p, at)
		Arena.look(so.pawn, p.feet() + Vector3.UP * 1.4)


func _setup() -> void:
	_pair("open", 0.0, Vector3(0.0, 0.0, -5.0))
	# A wall 2.5 m high, a stud thick, just in front of the player.
	a.bricks(_cell(Vector3(97.9, 0.0, -14.0)), Vector3i(12, 6, 1))
	_pair("wall", 100.0, Vector3(0.0, 0.0, -15.0))
	# A platform ten courses high under the player.
	a.bricks(_cell(Vector3(198.95, 0.0, -11.05)), Vector3i(6, 10, 6))
	_pair("high", 200.0, Vector3(0.0, 4.3, -10.0))
	_pair("reach", 300.0, Vector3(0.0, 0.0, -1.5))
	# A slab eight courses over the soldier's head.
	a.bricks(_cell(Vector3(398.6, 3.36, -1.4)), Vector3i(8, 1, 8))
	_pair("roof", 400.0, Vector3(0.0, 0.0, -12.0))
	_pair("unaware", 500.0, Vector3(0.0, 0.0, -12.0))


func _read(name: String) -> Dictionary:
	var so: Soldier = _cases[name].so
	var p: Pawn = _cases[name].p
	var k := so.knowledge()
	k.saw(p, p.feet(), a.s.now(), so)
	return TacticsSense.read(so, k.of(p), {})


func _readings() -> void:
	var r := _read("open")
	_ok("face to face in the open: close quarters, 5 m, nobody in cover, the player aware",
			r.moment == "close_quarters" and absf(float(r.amounts.dist) - 5.0) < 0.6
			and int(r.amounts.pcover) == 0 and int(r.amounts.cover) == 0 and r.facts.has("open")
			and r.facts.has("p_seen") and not r.facts.has("p_reach") and not r.facts.has("p_unaware"), _show(r))
	r = _read("wall")
	_ok("the player behind a brick wall: in full cover, and it can be destroyed",
			int(r.amounts.pcover) == 2 and r.facts.has("destructible") and r.moment == "player_dug_in", _show(r))
	r = _read("high")
	_ok("the player up on a platform: above us", r.facts.has("p_high") and not r.facts.has("p_low"), _show(r))
	r = _read("reach")
	_ok("within melee reach", r.facts.has("p_reach") and r.moment == "close_quarters", _show(r))
	r = _read("roof")
	_ok("under a roof: inside", r.facts.has("inside") and not r.facts.has("open"), _show(r))
	r = _read("unaware")
	_ok("the player looking the other way: unaware, and we have the jump",
			r.facts.has("p_unaware") and r.moment == "have_jump", _show(r))
	var full := _read("open")
	_ok("our health, magazine and squad read in full", absf(float(full.amounts.hp) - 100.0) < 0.01
			and absf(float(full.amounts.mag) - 100.0) < 0.01 and absf(float(full.amounts.squad) - 100.0) < 0.01
			and full.facts.has("we_alone"), _show(full))


func _show(r: Dictionary) -> String:
	var am := []
	for k in r.amounts:
		am.append("%s %s" % [k, snappedf(float(r.amounts[k]), 0.1)])
	return "%s | %s | %s" % [r.moment, ",".join(r.facts), " ".join(am)]


func _fight_setup() -> void:
	_policy = BookCombatPolicy.new()
	a.s.policy = _policy
	# The counts the city keeps (TacticsTally), here in a file of the probe's own.
	if FileAccess.file_exists(TALLY):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TALLY))
	a.s.tally = TacticsTally.open(TALLY)
	_player = a.player(Vector3(700.0, 0.0, -25.0), 1e7, true, 9)
	var members: Array[Soldier] = []
	for i in 3:
		var so := a.soldier(Vector3(698.0 + i * 2.0, 0.0, 0.0), 1, 60 + i)
		Arena.look(so.pawn, _player.eye.global_position)
		members.append(so)
	_squad = Squad.make(a.s, root, members, 1)
	# A low wall to the side, so cover is on offer.
	a.bricks(_cell(Vector3(703.0, 0.0, -6.0)), Vector3i(10, 4, 1))
	# The pairs from the readings stop fighting: they are not this fight.
	for name in _cases:
		_retire(_cases[name].so)


func _retire(so: Soldier) -> void:
	so.pawn.body.process_mode = Node.PROCESS_MODE_DISABLED
	so.process_mode = Node.PROCESS_MODE_DISABLED
	a.s.pawns.erase(so.pawn)


func _verdict() -> void:
	var ids := {}
	var shots := 0
	for m in _squad.members:
		ids[m.get_instance_id()] = true
		shots += m.shots
	var ds := a.s.decisions.filter(func(d): return ids.has(d.who))
	var with_book := ds.filter(func(d): return d.has("book"))
	var agree := true
	var moments := {}
	var moves := {}
	for d in with_book:
		var b: Dictionary = d.book
		moments[b.moment] = int(moments.get(b.moment, 0)) + 1
		moves[b.move] = int(moves.get(b.move, 0)) + 1
		var want := int(BookCombatPolicy.DOABLE.get(b.move, -2))
		var ok: bool = d.tactic == want if want >= 0 else (want == -1 and d.tactic in [CombatPolicy.Tactic.FIGHT_OPEN, CombatPolicy.Tactic.TAKE_COVER])
		if not ok:
			agree = false
	_ok("every decision in the fight carries the book's plan", ds.size() >= 3 and with_book.size() == ds.size(),
			"%d decision(s), moments %s" % [ds.size(), moments])
	_ok("and runs the tactic its move maps to", agree, "moves %s" % [moves])
	_ok("the soldiers fight", shots > 0, "%d shot(s)" % shots)
	# The tally: every book decision counted under its moment, kept on disk.
	var tally := a.s.tally as TacticsTally
	var counted := 0
	var moved := 0.0
	var judged := 0
	for id in tally.data.moments:
		var m: Dictionary = tally.data.moments[id]
		counted += int(m.n)
		for k in m.moves:
			moved += float(m.moves[k])
		for k in m.outcomes:
			judged += int(m.outcomes[k].n)
	var all_book := a.s.decisions.filter(func(d): return d.has("book")).size()
	tally.save()
	var again := TacticsTally.open(TALLY)
	_ok("what happened is counted by moment, with outcomes, and kept on disk",
			counted == all_book and int(moved) == counted and judged >= 1 and judged <= counted
			and int(again.data.decisions) == counted and int(again.data.runs) == 2,
			"%d decision(s) in %d moment(s), %d judged" % [counted, tally.data.moments.size(), judged])
	print("  info the book asked for, not built yet: %s" % (_policy.wanted_text() if not _policy.wanted.is_empty() else "nothing"))


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_setup()
		return
	if _tick < 20:
		_face()
	if _tick == 20:
		_readings()
		_fight_setup()
		return
	if _tick < 20:
		return
	a.tick()
	var now := a.s.now()
	if _t0 < 0.0:
		_t0 = now
	Arena.look(_player, _squad.center() + Vector3.UP)
	if now - _t0 >= FIGHT_SECONDS:
		_verdict()
		print("\n%d passed, %d failed" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
