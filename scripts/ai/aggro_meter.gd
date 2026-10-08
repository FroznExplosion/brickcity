class_name AggroMeter
extends Control
## The aggro meter (Docs/AI.md 8, A8): how much of an enemy side's attention one
## player holds, with their mech's share beside it, and a mark on whichever of
## the two holds the side's focus. Shows AggroTable; decides nothing.

const BAR := Vector2(180.0, 10.0)

var table: AggroTable
## Which player's rows to show.
var player := 0


func _ready() -> void:
	custom_minimum_size = Vector2(BAR.x + 70.0, BAR.y * 2.0 + 30.0)


func _process(_delta: float) -> void:
	queue_redraw()


## The pilot's and the mech's shares, and who holds the focus: what is drawn.
## {"pilot": 0..1, "mech": 0..1, "holder": "pilot"|"mech"|"", "exposed": bool} --
## exposed: the mech's hatch is off, so the pilot in it can be shot (AIRoster.md G9).
func reading() -> Dictionary:
	var out := {"pilot": 0.0, "mech": 0.0, "holder": "", "exposed": false}
	if table == null:
		return out
	var focus := table.focus()
	for id in table.entries:
		var e: AggroTable.Entry = table.entries[id]
		if e.player != player or not is_instance_valid(e.who):
			continue
		out[e.kind] = float(out.get(e.kind, 0.0)) + table.share(e.who)
		if e.who == focus:
			out.holder = e.kind
		if e.kind == "mech" and e.who is Pawn:
			var ml := MechLayers.of((e.who as Pawn).body)
			if ml != null and ml.hatch_off and ml.piloted:
				out.exposed = true
	return out


func _draw() -> void:
	var r := reading()
	var font := get_theme_default_font()
	draw_string(font, Vector2(0, 12), "AGGRO", HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	var y := 18.0
	for kind in ["pilot", "mech"]:
		var v := float(r[kind])
		draw_rect(Rect2(Vector2(46, y), BAR), Color(0, 0, 0, 0.5))
		var col := Color(1.0, 0.35, 0.25) if r.holder == kind else Color(0.9, 0.75, 0.3)
		draw_rect(Rect2(Vector2(46, y), Vector2(BAR.x * v, BAR.y)), col)
		draw_string(font, Vector2(0, y + BAR.y), kind, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		if kind == "mech" and bool(r.exposed):
			draw_string(font, Vector2(46 + BAR.x + 6, y + BAR.y), "hatch off", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
					Color(1.0, 0.35, 0.25))
		y += BAR.y + 6.0
