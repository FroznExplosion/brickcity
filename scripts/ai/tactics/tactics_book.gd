class_name TacticsBook
extends RefCounted
## The enemy's choices as authored on the Tactics Casebook page
## (Docs/Tactics/tactics_casebook.html), read from data/ai/tactics_book.json
## (made by tools/tactics_export.js). Same odds as the page, to the last digit:
## tools/tactics_book_probe.gd checks the page's own numbers.
##
## A choice is made in a MOMENT (a broad situation: contact, lost the player,
## close quarters...). What is true right now -- FACTS (inside a building, player
## above us, we're a melee fighter) and AMOUNTS (distance, cover, health,
## magazine) -- makes moves likelier or rules them out:
##
##     chance of a move = its weight in the moment x each true fact x each amount
##                        x memory x teamwork, scaled so the moves add to 1
##
## A fact set to ALWAYS ("95%") gives its move ALWAYS_SHARE of the whole pick.
## After the main move, a soldier may add extras -- something first, something
## while, something then (grenade, then rush; open fire while marking).

const PATH := "res://data/ai/tactics_book.json"

var mult: Array = []
var always := 6
var always_share := 0.95
var max_extra := 2
var slots: Array = []
var moves := {}
var facts := {}
var amounts := {}
var moments := {}
var memory := {}
var rules := {}
var golden: Array = []


static func load_book(path := PATH) -> TacticsBook:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("TacticsBook: can't open %s" % path)
		return null
	var d = JSON.parse_string(f.get_as_text())
	if not d is Dictionary:
		push_error("TacticsBook: %s is not a book" % path)
		return null
	var b := TacticsBook.new()
	b.mult = d.mult
	b.always = int(d.always)
	b.always_share = float(d.always_share)
	b.max_extra = int(d.max_extra)
	b.slots = d.slots
	b.moves = d.moves
	b.facts = d.facts
	b.amounts = d.amounts
	b.moments = d.moments
	b.memory = d.memory
	b.rules = d.rules
	b.golden = d.get("golden", [])
	return b


func label(move: String) -> String:
	return str(moves[move].label) if moves.has(move) else move


## What is true in `moment`: the given facts plus the moment's own, in that order
## (a kind's own amount curve is looked up in this order).
func facts_in(moment: String, given: Array) -> Array:
	var out: Array = []
	for f in given + (moments[moment].implied as Array):
		if not out.has(f):
			out.append(f)
	return out


## The moment's starting amounts under the given ones.
func amounts_in(moment: String, given: Dictionary) -> Dictionary:
	var out := {}
	for id in amounts:
		out[id] = float(amounts[id].default)
	for id in moments[moment].amounts:
		out[id] = float(moments[moment].amounts[id])
	for id in given:
		out[id] = float(given[id])
	return out


func _step(fact: String, move: String) -> int:
	return int(facts[fact].mods.get(move, 3)) if facts.has(fact) else 3


func _curve_at(a: Dictionary, row: Array, v: float) -> float:
	if a.discrete:
		return float(mult[int(row[clampi(roundi(v), 0, row.size() - 1)])])
	var xs: Array = []
	for s in a.stops:
		xs.append(log(maxf(float(s), 0.5)) if a.log else float(s))
	var q := log(maxf(v, 0.5)) if a.log else v
	var asc: bool = float(xs[xs.size() - 1]) > float(xs[0])
	for i in xs.size() - 1:
		var lo: float = xs[i]
		var hi: float = xs[i + 1]
		if (q >= lo and q <= hi) if asc else (q <= lo and q >= hi):
			var t := (q - lo) / (hi - lo)
			return float(mult[int(row[i])]) * (1.0 - t) + float(mult[int(row[i + 1])]) * t
	var before: bool = q < xs[0] if asc else q > xs[0]
	return float(mult[int(row[0] if before else row[row.size() - 1])])


## Every amount's effect on `move`: [{t, m}] for those that change it.
func _amount_mults(move: String, true_facts: Array, now: Dictionary) -> Array:
	var out: Array = []
	for id in amounts:
		var a: Dictionary = amounts[id]
		var curves: Dictionary = a.curves
		var row = null
		for f in true_facts:
			if curves.has(move + "@" + f):
				row = curves[move + "@" + f]
				break
		if row == null:
			row = curves.get(move)
		if row == null:
			continue
		var m := _curve_at(a, row, float(now[id]))
		if absf(m - 1.0) > 0.02:
			out.append({"t": "%s %s" % [id, now[id]], "m": m})
	return out


func _mem_mult(key: String) -> float:
	return float(mult[int(memory.get(key, 3))])


## The odds of every move of `moment`. `given_facts`: what is true; `given_amounts`:
## {dist, pcover, cover, hp, mag, squad, php}; `mem`: {last, outcome ("failed",
## "worked")}; `mates`: what squadmates are already doing. Rows:
## {move, w, p, why: [{t, step | m}], blocked, never, force}.
func odds(moment: String, given_facts: Array, given_amounts := {}, mem := {}, mates: Array = []) -> Array:
	var tf := facts_in(moment, given_facts)
	var now := amounts_in(moment, given_amounts)
	var mo: Dictionary = moments[moment]
	var rows: Array = []
	for a in mo.weights:
		var r := {"move": a, "w": 0.0, "p": 0.0, "why": [], "blocked": "", "never": (mo.never as Array).has(a), "force": false}
		rows.append(r)
		if r.never:
			continue
		var nd: Array = moves[a].needs if moves.has(a) else []
		if not nd.is_empty() and not nd.any(func(f): return tf.has(f)):
			r.blocked = "only when: " + " or ".join(nd)
			continue
		var w := float(mo.weights[a])
		for f in tf:
			var st := _step(f, a)
			if st == always:
				r.force = true
			if st != 3:
				w *= float(mult[st])
				r.why.append({"t": f, "step": st})
		for x in _amount_mults(a, tf, now):
			w *= x.m
			r.why.append(x)
		if str(mem.get("last", "")) == a:
			w *= _mem_mult("repeat")
			match str(mem.get("outcome", "")):
				"failed": w *= _mem_mult("failed")
				"worked": w *= _mem_mult("worked")
		var same := mates.count(a)
		var mx := int(moves[a].max) if moves.has(a) else 0
		if mx > 0 and same >= mx:
			r.blocked = "%d squadmate(s) already doing it (at most %d)" % [same, mx]
			continue
		if same > 0:
			w *= _mem_mult("same")
		for m in mates:
			if m != a and (_pairs(a).has(m) or _pairs(m).has(a)):
				w *= _mem_mult("partner")
				r.why.append({"t": "works with a squadmate's " + str(m), "step": int(memory.get("partner", 3))})
				break
		r.w = w
	var ft := 0.0
	var rt := 0.0
	for r in rows:
		if r.force and r.w > 0.0:
			ft += r.w
		else:
			rt += r.w
	for r in rows:
		if ft > 0.0:
			var share := always_share if rt > 0.0 else 1.0
			r.p = share * r.w / ft if (r.force and r.w > 0.0) else ((1.0 - share) * r.w / rt if rt > 0.0 else 0.0)
		else:
			r.p = r.w / rt if rt > 0.0 else 0.0
	return rows


func _pairs(move: String) -> Array:
	return moves[move].pairs if moves.has(move) else []


func pick(rows: Array, rng: RandomNumberGenerator) -> String:
	var x := rng.randf()
	var last := ""
	for r in rows:
		if r.p <= 0.0:
			continue
		last = r.move
		x -= r.p
		if x <= 0.0:
			return r.move
	return last


## The extras `main` could bring here, with their chances: [{slot, move, pct, p}].
func extras_for(moment: String, given_facts: Array, given_amounts: Dictionary, main: String, mates: Array = []) -> Array:
	var tf := facts_in(moment, given_facts)
	var now := amounts_in(moment, given_amounts)
	var mo: Dictionary = moments[moment]
	var out: Array = []
	if not moves.has(main):
		return out
	for slot in slots:
		var c: Dictionary = moves[main].combos[slot]
		for a in c:
			if a == main:
				continue
			out.append({"slot": slot, "move": a, "pct": float(c[a]), "p": _extra_chance(mo, tf, now, a, float(c[a]), mates)})
	return out


func _extra_chance(mo: Dictionary, tf: Array, now: Dictionary, a: String, pct: float, mates: Array) -> float:
	if (mo.never as Array).has(a):
		return 0.0
	var nd: Array = moves[a].needs if moves.has(a) else []
	if not nd.is_empty() and not nd.any(func(f): return tf.has(f)):
		return 0.0
	var mx := int(moves[a].max) if moves.has(a) else 0
	if mx > 0 and mates.count(a) >= mx:
		return 0.0
	var m := 1.0
	var force := false
	for f in tf:
		var st := _step(f, a)
		if st == always:
			force = true
		m *= float(mult[st])
	for x in _amount_mults(a, tf, now):
		m *= x.m
	return always_share if (force and m > 0.0) else minf(0.95, pct / 100.0 * m)


## Up to `max_extra` extras, at most one per slot.
func roll_extras(moment: String, given_facts: Array, given_amounts: Dictionary, main: String, mates: Array, rng: RandomNumberGenerator) -> Array:
	var got: Array = []
	for slot in slots:
		if got.size() >= max_extra:
			break
		var taken: Array = got.map(func(g): return g.move)
		var cands := extras_for(moment, given_facts, given_amounts, main, mates + taken).filter(
				func(x): return x.slot == slot and x.p > 0.0 and not taken.has(x.move))
		cands.sort_custom(func(x, y): return x.p > y.p)
		for x in cands:
			if rng.randf() < x.p:
				got.append(x)
				break
	return got


## One soldier's plan: {move, extras, rows}.
func plan(moment: String, given_facts: Array, given_amounts := {}, mem := {}, mates: Array = [], rng: RandomNumberGenerator = null) -> Dictionary:
	if rng == null:
		rng = RandomNumberGenerator.new()
	var rows := odds(moment, given_facts, given_amounts, mem, mates)
	var a := pick(rows, rng)
	var extras := roll_extras(moment, given_facts, given_amounts, a, mates, rng) if a != "" else []
	return {"move": a, "extras": extras, "rows": rows}


## A squad of `n` choosing in turn, each seeing what the ones before it chose.
func squad(moment: String, given_facts: Array, given_amounts: Dictionary, n: int, rng: RandomNumberGenerator, mem := {}) -> Array:
	var out: Array = []
	var chosen: Array = []
	for i in n:
		var p := plan(moment, given_facts, given_amounts, mem if i == 0 else {}, chosen, rng)
		out.append(p)
		if p.move != "":
			chosen.append(p.move)
			for x in p.extras:
				chosen.append(x.move)
	return out


## "Grenade, then rush them, while ..." for logs and callouts.
func plan_text(p: Dictionary) -> String:
	if p.move == "":
		return "nothing possible"
	var first: Array = []
	var during: Array = []
	var after: Array = []
	for x in p.extras:
		match str(x.slot):
			"first": first.append(label(x.move))
			"with": during.append(label(x.move).to_lower())
			_: after.append(label(x.move).to_lower())
	var s := (", ".join(first) + ", then " + label(p.move).to_lower()) if not first.is_empty() else label(p.move)
	if not during.is_empty():
		s += ", while " + " and ".join(during)
	if not after.is_empty():
		s += ", then " + ", ".join(after)
	return s
