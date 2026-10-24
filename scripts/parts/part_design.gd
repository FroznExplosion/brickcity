class_name PartDesign
extends RefCounted
## A design: which parts a build of a body plan is made of, slot by slot (Docs/ModularParts.md
## section 7, "Designs: fixed slots and rolled slots"; stage 6).
##
##     {"id": "john", "name": "John", "plan": "figure", "slots": {
##         "root":     {"fixed": "fig_torso_john"},          always this part
##         "neck":     {"fixed": "fig_head_john"},
##         "neck/hat": {"pool": {"tags": ["hat"]}},          any part that fits and passes
##         "arm_L":    {"empty": true}}}                     left empty (optional sockets only)
##
## A slot the design does not name is rolled from every part that fits it. Fixed slots are
## how a joined pair is kept together (a barrel only ever on its receiver) and how a fixed
## character keeps its body while its hat is rolled. Saved as a file of its own: a design
## names parts, it never holds them, so every part is still saved on its own.

## Shipped designs, then the player's. The first of an id wins: a player's file cannot
## take a shipped design's id.
const DIRS := ["res://parts/designs/", "user://parts/designs/"]

var id := ""
var display_name := ""
var plan := "mech"
## path ("root" for the plan's root) -> {fixed: part id} | {pool: catalogue query} | {empty: true}
var slots := {}
## The motion sets it asks for, by action: {"walk": "mech.walk.stomp"} (MotionSets). One the
## build cannot do is passed over for the best it can.
var motion := {}
var source := "official"


static func from_dict(d: Dictionary) -> PartDesign:
	var p := PartDesign.new()
	p.id = String(d.get("id", ""))
	p.display_name = String(d.get("name", p.id))
	p.plan = String(d.get("plan", "mech"))
	p.slots = (d.get("slots", {}) as Dictionary).duplicate(true)
	p.motion = (d.get("motion", {}) as Dictionary).duplicate()
	return p


func to_dict() -> Dictionary:
	var d := {"id": id, "name": display_name, "plan": plan, "slots": slots.duplicate(true)}
	if not motion.is_empty():
		d["motion"] = motion.duplicate()
	return d


func save_file(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	return OK


## Every design file: id -> PartDesign.
static func load_all(dirs: Array = DIRS) -> Dictionary:
	var out := {}
	for base: String in dirs:
		if not DirAccess.dir_exists_absolute(base):
			continue
		var files := Array(DirAccess.get_files_at(base))
		files.sort()
		for f: String in files:
			if f.get_extension() != "json":
				continue
			var d = JSON.parse_string(FileAccess.get_file_as_string(base + f))
			if not d is Dictionary:
				continue
			var p := from_dict(d)
			if p.id == "" or out.has(p.id):
				continue
			p.source = "official" if base.begins_with("res://") else "custom"
			out[p.id] = p
	return out


## A design of `records` as fixed slots: the parts saved from one workshop build, each on
## the path its slot and side make (a mech's left arm on arm_L, its left hand on
## arm_L/hand). Parts with no place on the plan are left out.
static func from_parts(design_id: String, design_name: String, plan_name: String,
		records: Array) -> PartDesign:
	var p := PartDesign.new()
	p.id = design_id
	p.display_name = design_name
	p.plan = plan_name
	var plan_d := PartStandards.plan(plan_name)
	var sockets: Dictionary = plan_d.get("sockets", {})
	var paths := sockets.keys()
	paths.sort()
	for r: PartRecord in records:
		if r.slot == String(plan_d.get("root", "")):
			p.slots["root"] = {"fixed": r.id}
			continue
		for path: String in paths:
			var spot: Dictionary = sockets[path]
			if String(spot.slot) != r.slot or p.slots.has(path):
				continue
			var side := String(spot.get("side", "any"))
			if side == "any" or r.side == "any" or r.side == side or r.mirrorable:
				p.slots[path] = {"fixed": r.id}
				break
	return p
