extends SceneTree

## Probe for the enemy's book of choices (TacticsBook; Docs/Tactics/).
##
##     godot --headless --path . --script tools/tactics_book_probe.gd
##
## 1. The game gives the page's odds: every golden case written by
##    tools/tactics_export.js (the page's own model code, run on your settings)
##    matches TacticsBook to 1e-9 -- main moves and extras.
## 2. Picks follow the odds: 20 000 picks land within 1.5 points of each chance.
## 3. What was asked for still holds (Docs/Tactics, the casebook chat 2026-09-30..10-01):
##    - within melee reach, melee takes ~95% of the pick
##    - face to face with the player in the open, the soldier opens fire first
##      and often throws a grenade after
##    - with the player behind full cover, the grenade comes first
##    - far from the player, no melee -- unless it is a melee fighter
## If you retune the casebook so one of these no longer holds on purpose, change
## the check here in the same commit.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("tactics book probe")
	var b := TacticsBook.load_book()
	if b == null:
		_ok("the book loads", false)
		quit(1)
		return
	_ok("the book loads", true, "%d moves, %d facts, %d amounts, %d moments, %d golden cases" % [
			b.moves.size(), b.facts.size(), b.amounts.size(), b.moments.size(), b.golden.size()])
	_golden(b)
	_picks(b)
	_intent(b)
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _golden(b: TacticsBook) -> void:
	var worst := 0.0
	var where := ""
	var extras_worst := 0.0
	for g in b.golden:
		var rows := b.odds(g.moment, g.facts, g.amounts, g.mem, g.mates)
		var got := {}
		for r in rows:
			got[r.move] = r.p
		for k in g.expect:
			var d := absf(float(got.get(k, -1.0)) - float(g.expect[k]))
			if d > worst:
				worst = d
				where = "%s / %s" % [g.moment, k]
		if str(g.main) != "":
			var ex := {}
			for x in b.extras_for(g.moment, g.facts, g.amounts, g.main, g.mates):
				ex[str(x.slot) + ":" + str(x.move)] = x.p
			for k in g.extras:
				extras_worst = maxf(extras_worst, absf(float(ex.get(k, -1.0)) - float(g.extras[k])))
	_ok("the game gives the page's odds in every golden case", worst < 1e-9 and b.golden.size() >= 50,
			"worst difference %s%s" % [String.num_scientific(worst), (" at " + where) if worst >= 1e-9 else ""])
	_ok("and the page's chances for extras", extras_worst < 1e-9, "worst difference %s" % String.num_scientific(extras_worst))


func _picks(b: TacticsBook) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var rows := b.odds("first_contact", ["inside"], {"dist": 12, "pcover": 2})
	var counts := {}
	var n := 20000
	for i in n:
		var a := b.pick(rows, rng)
		counts[a] = int(counts.get(a, 0)) + 1
	var worst := 0.0
	for r in rows:
		worst = maxf(worst, absf(float(counts.get(r.move, 0)) / n - r.p))
	_ok("picks follow the odds", worst < 0.015, "worst gap %.1f points over %d picks" % [worst * 100.0, n])
	var squad := b.squad("first_contact", ["inside"], {"dist": 12, "pcover": 2}, 4, rng)
	var texts: Array = squad.map(func(p): return b.plan_text(p))
	_ok("a squad makes plans", squad.size() == 4 and squad.all(func(p): return p.move != ""), " | ".join(texts))


func _p(rows: Array, move: String) -> float:
	for r in rows:
		if r.move == move:
			return r.p
	return 0.0


func _top(rows: Array) -> String:
	var best := ""
	var bp := -1.0
	for r in rows:
		if r.p > bp:
			bp = r.p
			best = r.move
	return best


func _extra(b: TacticsBook, moment: String, f: Array, am: Dictionary, main: String, slot: String, move: String) -> float:
	for x in b.extras_for(moment, f, am, main):
		if x.slot == slot and x.move == move:
			return x.p
	return 0.0


func _intent(b: TacticsBook) -> void:
	var reach := 1.0
	for m in b.moments:
		# A soldier's moments: a mech's (mech_fight) has a punch, not a melee.
		if not (b.moments[m].weights as Dictionary).has("melee"):
			continue
		reach = minf(reach, _p(b.odds(m, ["p_reach"], {"dist": 1.5}), "melee"))
	_ok("within melee reach, melee takes ~95% of the pick in every moment", reach > 0.9,
			"lowest %.0f%%" % (reach * 100.0))
	var face := b.odds("first_contact", [], {"dist": 5, "pcover": 0})
	var then_g := _extra(b, "first_contact", [], {"dist": 5, "pcover": 0}, "trade", "then", "grenade")
	_ok("face to face in the open: open fire first, often a grenade after", _top(face) == "trade" and then_g >= 0.25,
			"open fire %.0f%%, then grenade %.0f%%" % [_p(face, "trade") * 100.0, then_g * 100.0])
	var cov := b.odds("first_contact", [], {"dist": 15, "pcover": 2})
	_ok("player behind full cover: the grenade first", _top(cov) == "grenade" and _p(cov, "grenade") > 2.0 * _p(cov, "trade"),
			"grenade %.0f%%, open fire %.0f%%" % [_p(cov, "grenade") * 100.0, _p(cov, "trade") * 100.0])
	var far := b.odds("first_contact", [], {"dist": 60})
	var brute := b.odds("first_contact", ["we_melee"], {"dist": 60})
	_ok("far from the player no melee, unless a melee fighter", _p(far, "melee") == 0.0 and _top(brute) == "melee",
			"60 m: soldier %.0f%%, melee fighter %.0f%%" % [_p(far, "melee") * 100.0, _p(brute, "melee") * 100.0])
