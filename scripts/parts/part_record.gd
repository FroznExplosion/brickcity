class_name PartRecord
extends RefCounted
## One part, of any family -- a gun's barrel, a mech's left leg, a figure's hat, a pod
## (Docs/ModularParts.md section 2). Saved on its own as part.json; the catalogue
## (PartCatalog) finds it, PartFit says what it goes on.
##
## Only data: nothing here is a scene or a script, so a part from another player is safe to
## read (section 7). Keys this script does not know are kept in `extra` and written back, so
## a newer game's part survives a round trip through an older one.

const FAMILIES := ["gun", "mech", "figure", "creature", "pod"]
const SIDES := ["any", "L", "R"]
const WEIGHT_CLASSES := ["", "light", "normal", "heavy"]
const SCALES := ["", "held", "mech"]
const SOURCES := ["official", "custom"]

var id: String = ""
## Bumped on every save that changes the part; saves name a part by id and rev.
var rev: int = 1
var family: String = ""
## Guns only: a player's gun (held) or a mech's (mech). The two never join (section 5).
var scale: String = ""
var slot: String = ""
var side: String = "any"
## A part for one side that may be mirrored onto the other.
var mirrorable: bool = false
var display_name: String = ""
var manufacturer: String = "generic"
## light, normal or heavy: a mech's comes from its chassis alone (section 4).
var weight_class: String = ""
## A receiver's class (smg, rifle ...); other gun parts' is worked out by the catalogue.
var weapon_class: String = ""
## A pod's kind: active_animated, active_fixed, passive.
var pod_kind: String = ""
var rarity: int = 0
var source: String = "official"
## {name, steam_id} of whoever made a custom part.
var creator: Dictionary = {}
## Flavour and filtering only: never what fits (section 3).
var tags: PackedStringArray = []
## {interface, params: {length ...}}; empty for a root part (a chassis, a body, a torso).
var mount: Dictionary = {}
## [{name, accepts: [interface ...], frame?, envelope?}]
var sockets: Array = []
## Keeps it out of every pool but its design's (a joined pair, a fixed character).
var exclusive_to: String = ""
var name_fragment: String = ""
var effect_id: String = ""
var effect_params: Dictionary = {}
var stats: Dictionary = {}
var mass: float = 0.0
## Unix time of the save that made this rev: the catalogue's "newest".
var saved: int = 0
var extra: Dictionary = {}
## The folder it was read from (PartCatalog), never saved: where its part.scn is.
var dir: String = ""

const _KNOWN := ["id", "rev", "family", "scale", "slot", "side", "mirrorable", "name",
		"manufacturer", "class", "weapon_class", "pod_kind", "rarity", "source", "creator",
		"tags", "mount", "sockets", "exclusive_to", "name_fragment", "effect_id",
		"effect_params", "stats", "mass", "saved"]


static func from_dict(d: Dictionary) -> PartRecord:
	var r := PartRecord.new()
	r.id = String(d.get("id", ""))
	r.rev = int(d.get("rev", 1))
	r.family = String(d.get("family", ""))
	r.scale = String(d.get("scale", ""))
	r.slot = String(d.get("slot", ""))
	r.side = String(d.get("side", "any"))
	r.mirrorable = bool(d.get("mirrorable", false))
	r.display_name = String(d.get("name", ""))
	r.manufacturer = String(d.get("manufacturer", "generic"))
	r.weight_class = String(d.get("class", ""))
	r.weapon_class = String(d.get("weapon_class", ""))
	r.pod_kind = String(d.get("pod_kind", ""))
	r.rarity = int(d.get("rarity", 0))
	r.source = String(d.get("source", "official"))
	if d.get("creator") is Dictionary:
		r.creator = d.creator
	if d.get("tags") is Array:
		r.tags = PackedStringArray(d.tags)
	if d.get("mount") is Dictionary:
		r.mount = (d.mount as Dictionary).duplicate(true)
		# JSON has no ints: a length of 3 reads back as 3.0. Params are counts.
		var params: Dictionary = r.mount.get("params", {})
		for k in params:
			if params[k] is float and params[k] == floorf(params[k]):
				params[k] = int(params[k])
	if d.get("sockets") is Array:
		r.sockets = d.sockets
	r.exclusive_to = String(d.get("exclusive_to", ""))
	r.name_fragment = String(d.get("name_fragment", ""))
	r.effect_id = String(d.get("effect_id", ""))
	if d.get("effect_params") is Dictionary:
		r.effect_params = d.effect_params
	if d.get("stats") is Dictionary:
		r.stats = d.stats
	r.mass = float(d.get("mass", 0.0))
	r.saved = int(d.get("saved", 0))
	for k in d:
		if not String(k) in _KNOWN:
			r.extra[k] = d[k]
	return r


func to_dict() -> Dictionary:
	var d := extra.duplicate(true)
	d.merge({"id": id, "rev": rev, "family": family, "slot": slot, "side": side,
			"name": display_name, "manufacturer": manufacturer, "source": source,
			"tags": Array(tags), "mount": mount, "sockets": sockets}, true)
	for pair in [["scale", scale], ["class", weight_class], ["weapon_class", weapon_class],
			["pod_kind", pod_kind], ["exclusive_to", exclusive_to],
			["name_fragment", name_fragment], ["effect_id", effect_id]]:
		if pair[1] != "":
			d[pair[0]] = pair[1]
	if mirrorable:
		d["mirrorable"] = true
	if rarity > 0:
		d["rarity"] = rarity
	if not creator.is_empty():
		d["creator"] = creator
	if not effect_params.is_empty():
		d["effect_params"] = effect_params
	if not stats.is_empty():
		d["stats"] = stats
	if mass > 0.0:
		d["mass"] = mass
	if saved > 0:
		d["saved"] = saved
	return d


static func load_file(path: String) -> PartRecord:
	if not FileAccess.file_exists(path):
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return from_dict(d) if d is Dictionary else null


func save_file(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t") + "\n")
	return OK


func interface() -> String:
	return String(mount.get("interface", ""))


func param(key: String, default: Variant = null) -> Variant:
	return (mount.get("params", {}) as Dictionary).get(key, default)


func socket(socket_name: String) -> Dictionary:
	for s in sockets:
		if s is Dictionary and String(s.get("name", "")) == socket_name:
			return s
	return {}


func is_custom() -> bool:
	return source == "custom"


## What is wrong with this record on its own, before it meets anything (empty: nothing).
## Fitting other parts is PartFit's.
func problems() -> PackedStringArray:
	var out := PackedStringArray()
	if id == "":
		out.append("no id")
	if not family in FAMILIES:
		out.append("family '%s' is not one of %s" % [family, FAMILIES])
	if slot == "":
		out.append("no slot")
	if not side in SIDES:
		out.append("side '%s' is not one of %s" % [side, SIDES])
	if not weight_class in WEIGHT_CLASSES:
		out.append("class '%s' is not light, normal or heavy" % weight_class)
	if not scale in SCALES:
		out.append("scale '%s' is not held or mech" % scale)
	if family == "gun" and scale == "":
		out.append("a gun part says no scale (held or mech)")
	if not source in SOURCES:
		out.append("source '%s' is not official or custom" % source)
	if source == "custom" and String(creator.get("name", "")) == "":
		out.append("a custom part with no creator")
	var iface := interface()
	if iface != "":
		var known := PartStandards.interface(iface)
		if known.is_empty():
			out.append("mounts on '%s', which is no interface" % iface)
		elif String(known.get("slot", slot)) != slot:
			out.append("mounts on '%s', a %s's interface, but is a %s" % [iface, known.slot, slot])
		for p in known.get("params", []):
			if param(p) == null:
				out.append("'%s' needs its %s" % [iface, p])
	if param("length") != null and int(param("length")) <= 0:
		out.append("length %s is not a positive whole number" % str(param("length")))
	var names := {}
	for s in sockets:
		if not s is Dictionary:
			out.append("a socket that is not a record")
			continue
		var n := String(s.get("name", ""))
		if n == "" or names.has(n):
			out.append("socket name '%s' empty or used twice" % n)
		names[n] = true
		for a in s.get("accepts", []):
			if PartStandards.interface(String(a)).is_empty():
				out.append("socket '%s' accepts '%s', which is no interface" % [n, a])
	return out
