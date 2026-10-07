class_name BookCombatPolicy
extends CombatPolicy
## The engage decision from the Tactics Casebook (TacticsBook, Docs/Tactics):
## behind the switch `-- --tactics=book` (CombatPolicy.from_args).
##
## TacticsSense reads the moment, facts and amounts; the book draws a plan -- a
## main move and extras -- with the squadmates' moves and the soldier's own last
## one counted. The tree can carry out six tactics today, so each book move is
## mapped to one (DOABLE). A move the game cannot do yet (a grenade, smoke,
## bringing a building down...) is counted in `wanted` -- what the book asked
## for most is what to build next -- and the draw is made again among the moves
## it can do, in their book proportions.
##
## The plan rides on the soldier (Soldier.book) into the decision log, so the
## data says what the book chose, not only which of the six tactics ran.

const T := CombatPolicy.Tactic
## Book move -> tactic. -1: fire from cover if there is cover, else in the open.
const DOABLE := {
	"trade": -1, "suppress": -1,
	"hold": T.TAKE_COVER, "relocate": T.TAKE_COVER,
	"reload": T.COVER_RELOAD,
	"rush": T.RUSH, "advance": T.PUSH, "melee": T.MELEE, "detonate": T.DETONATE,
	# Thrown (Soldier.throw_grenade), then fire from cover.
	"grenade": -1,
	"flank": T.FLANK,
	"fall_back": T.FALL_BACK, "flee": T.FALL_BACK, "regroup": T.FALL_BACK, "hide": T.FALL_BACK,
	# Said aloud (SAID), then fire from cover.
	"call_help": -1, "mark": -1,
}
## A "then grenade" goes this long after the decision.
const THEN_GRENADE := 1.8
## Extras the soldier can do now: said aloud (Callouts).
const SAID := {
	"call_help": ["Need help over here!", "Contact, send everyone!", "Get over here!"],
	"mark": ["Marking him!", "He's there, on me!", "Target marked!"],
}

var book: TacticsBook
## Book move -> how often it was drawn and could not be done (main moves and extras).
var wanted := {}
## Book move -> how often it was carried out.
var done := {}
var _fallback := ScriptedCombatPolicy.new()


func _init(b: TacticsBook = null) -> void:
	book = b if b != null else TacticsBook.load_book()


func policy_name() -> String:
	return "book"


## Without the soldier there is nothing to read the world with: the scripted call.
func decide(o: PackedFloat32Array, rng: RandomNumberGenerator) -> int:
	return _fallback.decide(o, rng)


func decide_in(so: Soldier, c: FactionKnowledge.Contact, cover: Dictionary,
		o: PackedFloat32Array, rng: RandomNumberGenerator) -> int:
	if book == null:
		return _fallback.decide(o, rng)
	var sense := TacticsSense.read(so, c, cover)
	var mates: Array = []
	if so.squad != null:
		for m in so.squad.alive():
			if m != so and not m.book.is_empty():
				mates.append(m.book.move)
				for x in m.book.extras:
					mates.append(x)
	var mem := {"last": str(so.book.get("move", ""))}
	var plan := book.plan(sense.moment, sense.facts, sense.amounts, mem, mates, rng)
	var move: String = plan.move
	var asked := move
	if not DOABLE.has(move) or (move == "grenade" and not so.can_throw_at(c.pos)):
		if not DOABLE.has(move):
			_count(wanted, move)
		move = _redraw(plan.rows, rng, so, c)
	if move == "grenade":
		so.throw_grenade(c.pos)
	var tactic := _tactic(move, cover) if move != "" else _fallback.decide(o, rng)
	_count(done, move)
	if SAID.has(move):
		var said: Array = SAID[move]
		so.services.say(so.pawn, "book_" + move, said[rng.randi() % said.size()])
	var extras: Array = []
	var not_yet: Array = []
	for x in plan.extras:
		if x.move == "grenade":
			if x.slot == "then":
				so.grenade_after = so.services.now() + THEN_GRENADE
				extras.append("grenade")
			elif so.throw_grenade(c.pos):
				extras.append("grenade")
		elif SAID.has(x.move):
			var lines: Array = SAID[x.move]
			so.services.say(so.pawn, "book_" + str(x.move), lines[rng.randi() % lines.size()])
			extras.append(x.move)
		elif not DOABLE.has(x.move):
			# A follow-up the tree can do (fire, push...) comes as the next
			# decision; one it cannot is wanted.
			_count(wanted, x.move)
			not_yet.append(x.move)
	so.book = {"moment": sense.moment, "facts": sense.facts, "amounts": sense.amounts,
			"move": move, "asked": asked, "extras": extras, "wanted_extras": not_yet}
	if so.services.tally != null:
		so.services.tally.call(&"note", so.book)
	return tactic


## Again, among the moves the soldier can do now, in their book proportions.
func _redraw(rows: Array, rng: RandomNumberGenerator, so: Soldier, c: FactionKnowledge.Contact) -> String:
	var live: Array = []
	var total := 0.0
	for r in rows:
		if DOABLE.has(r.move) and r.p > 0.0 and (r.move != "grenade" or so.can_throw_at(c.pos)):
			live.append(r)
			total += r.p
	if total <= 0.0:
		return ""
	var x := rng.randf() * total
	for r in live:
		x -= r.p
		if x <= 0.0:
			return r.move
	return live[live.size() - 1].move


static func _tactic(move: String, cover: Dictionary) -> int:
	var t := int(DOABLE.get(move, T.TAKE_COVER))
	if t == -1:
		return T.FIGHT_OPEN if cover.is_empty() else T.TAKE_COVER
	return t


static func _count(d: Dictionary, k: String) -> void:
	if k != "":
		d[k] = int(d.get(k, 0)) + 1


## "grenade 12, smoke 4, ..." -- what to build next, most asked first.
func wanted_text() -> String:
	var ks := wanted.keys()
	ks.sort_custom(func(a, b): return int(wanted[a]) > int(wanted[b]))
	return ", ".join(ks.map(func(k): return "%s %d" % [k, wanted[k]]))
