class_name TacticsTally
extends RefCounted
## How often things happen while the casebook decides (Docs/Tactics): for each
## MOMENT, how many decisions, which moves were taken, which were asked for and
## could not be done, the extras, which facts held, how far and how covered the
## player was, and what came of each move (DecisionJudge). The graph on the
## Tactics Casebook page ("In the game") is drawn from this.
##
## Kept across runs in PATH (user://, so outside the repo): the game adds to it
## and saves every SAVE_EVERY decisions and when the city closes. Delete the file
## to start counting again.

const PATH := "user://tactics_tally.json"
const VERSION := 1
const SAVE_EVERY := 25
## Distance bands, by their upper edge in metres.
const BANDS := [[2.0, "reach"], [6.0, "close"], [15.0, "near"], [30.0, "mid"], [60.0, "far"]]
const BEYOND := "very far"

var path := PATH
var data := {}
var _unsaved := 0


static func open(p := PATH) -> TacticsTally:
	var t := TacticsTally.new()
	t.path = p
	t.data = {"version": VERSION, "decisions": 0, "runs": 0, "since": Time.get_datetime_string_from_system(),
			"updated": "", "moments": {}}
	if FileAccess.file_exists(p):
		var f := FileAccess.open(p, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f != null else null
		if d is Dictionary and int(d.get("version", 0)) == VERSION:
			t.data = d
	t.data.runs = int(t.data.get("runs", 0)) + 1
	return t


static func band(metres: float) -> String:
	for b in BANDS:
		if metres < float(b[0]):
			return b[1]
	return BEYOND


func _moment(id: String) -> Dictionary:
	var ms: Dictionary = data.moments
	if not ms.has(id):
		ms[id] = {"n": 0, "moves": {}, "asked": {}, "extras": {}, "wanted_extras": {}, "facts": {},
				"dist": {}, "pcover": {}, "by_pcover": {}, "by_dist": {}, "outcomes": {}}
	return ms[id]


static func _inc(d: Dictionary, k: String, by := 1.0) -> void:
	d[k] = float(d.get(k, 0.0)) + by


static func _inc2(d: Dictionary, k: String, k2: String) -> void:
	if not d.has(k):
		d[k] = {}
	_inc(d[k], k2)


## One decision the book took: the soldier's plan (Soldier.book).
func note(book: Dictionary) -> void:
	if book.is_empty():
		return
	var m := _moment(str(book.moment))
	var move := str(book.move)
	m.n = int(m.n) + 1
	data.decisions = int(data.decisions) + 1
	_inc(m.moves, move)
	if str(book.asked) != move:
		_inc(m.asked, str(book.asked))
	for e in book.extras:
		_inc(m.extras, str(e))
	for e in book.wanted_extras:
		_inc(m.wanted_extras, str(e))
	for f in book.facts:
		_inc(m.facts, str(f))
	var am: Dictionary = book.amounts
	var b := band(float(am.get("dist", 0.0)))
	var pc := str(int(am.get("pcover", 0)))
	_inc(m.dist, b)
	_inc(m.pcover, pc)
	_inc2(m.by_dist, b, move)
	_inc2(m.by_pcover, pc, move)
	_unsaved += 1
	if _unsaved >= SAVE_EVERY:
		save()


## What came of a decision, once it is judged (DecisionJudge.close): `d` is the
## logged decision, with book, reward, flags and outcome.
func close(d: Dictionary, verdict: String) -> void:
	var book: Dictionary = d.get("book", {})
	if book.is_empty():
		return
	var outs: Dictionary = _moment(str(book.moment)).outcomes
	var move := str(book.move)
	if not outs.has(move):
		outs[move] = {"n": 0, "reward": 0.0, "good": 0, "stupid": 0, "dealt": 0.0, "taken": 0.0, "died": 0}
	var o: Dictionary = outs[move]
	var out: Dictionary = d.get("outcome", {})
	o.n = int(o.n) + 1
	o.reward = float(o.reward) + float(d.get("reward", 0.0))
	o.dealt = float(o.dealt) + float(out.get("dealt", 0.0))
	o.taken = float(o.taken) + float(out.get("taken", 0.0))
	if bool(out.get("died", false)):
		o.died = int(o.died) + 1
	if verdict == "good":
		o.good = int(o.good) + 1
	elif verdict == "stupid":
		o.stupid = int(o.stupid) + 1


func save() -> bool:
	_unsaved = 0
	data.updated = Time.get_datetime_string_from_system()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[ai] cannot write the tactics tally to %s" % path)
		return false
	f.store_string(JSON.stringify(data, " "))
	return true
