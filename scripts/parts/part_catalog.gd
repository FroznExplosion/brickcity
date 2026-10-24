class_name PartCatalog
extends RefCounted
## Every part the game knows, official and custom, in one list that filters and sorts the
## same way for every family (Docs/ModularParts.md section 6).
##
##     var cat := PartCatalog.load_all()
##     cat.filter({"class": ["light"]})                       light parts of any brand
##     cat.filter({"family": ["mech"], "slot": ["leg"]})      every mech leg
##     cat.filter({"manufacturer": ["korr", "vex"], "slot": ["arm"], "class": ["heavy"]})
##     cat.sorted(list, "rarity", true)
##
## OR inside a facet, AND across facets. Manufacturer then part is only how a list is
## grouped by default, never an order the filters must be used in.

## Shipped parts, and the player's own and downloaded ones (section 7).
const OFFICIAL_DIR := "res://parts/"
const CUSTOM_DIR := "user://parts/custom/"
const FILE := "part.json"
## Every facet a part is filed under. `weapon_class` is worked out for gun parts that are
## not receivers: every class whose receivers take them (section 5).
const FACETS := ["family", "source", "manufacturer", "slot", "side", "class", "scale",
		"weapon_class", "pod_kind", "rarity", "creator", "length", "tags"]
const SORTS := ["name", "manufacturer", "class", "rarity", "mass", "newest", "creator"]

var _parts: Array[PartRecord] = []
var _by_id: Dictionary = {}
## id -> {facet: [values]}, rebuilt when the parts change.
var _facets: Dictionary = {}
var _indexed := false


## The catalogue of every part in the shipped and the custom folders.
static func load_all() -> PartCatalog:
	var cat := PartCatalog.new()
	cat.load_dir(OFFICIAL_DIR, "official")
	cat.load_dir(CUSTOM_DIR, "custom")
	return cat


## Read every part.json under `base`, at any depth. `source` is the folder's, whatever the
## file says: a downloaded part cannot make itself official. A part whose id is already in
## the catalogue is left out (the first folder read wins), with a warning.
func load_dir(base: String, source: String) -> int:
	var n := 0
	for path in _files_under(base):
		var r := PartRecord.load_file(path)
		if r == null:
			push_warning("PartCatalog: %s is not a part" % path)
			continue
		r.source = source
		if add(r):
			n += 1
	return n


## Add one part; false (and a warning) if it has problems of its own or its id is taken.
func add(r: PartRecord) -> bool:
	var bad := r.problems()
	if not bad.is_empty():
		push_warning("PartCatalog: %s left out: %s" % [r.id, "; ".join(bad)])
		return false
	if _by_id.has(r.id):
		push_warning("PartCatalog: duplicate part id '%s'" % r.id)
		return false
	_parts.append(r)
	_by_id[r.id] = r
	_indexed = false
	return true


func get_part(part_id: String) -> PartRecord:
	return _by_id.get(part_id)


func size() -> int:
	return _parts.size()


## Every part, in id order.
func all() -> Array[PartRecord]:
	return sorted(_parts, "id")


## The facets one part is filed under: {facet: [values]}.
func facets_of(r: PartRecord) -> Dictionary:
	_index()
	return _facets.get(r.id, {})


## The parts of `from` (default: every part) that pass `query` ({facet: [values]}), in
## id order. A facet missing or empty in the query does not filter.
func filter(query: Dictionary, from: Variant = null) -> Array[PartRecord]:
	_index()
	var out: Array[PartRecord] = []
	for r: PartRecord in (all() if from == null else from):
		if _passes(r, query):
			out.append(r)
	return out


## Each value a facet has among `from` (default: everything) and how many parts have it,
## for the filter panel's ticks: {value: count}, values in order.
func values(facet: String, from: Variant = null) -> Dictionary:
	_index()
	var counts := {}
	for r: PartRecord in (_parts if from == null else from):
		for v in (_facets[r.id] as Dictionary).get(facet, []):
			counts[v] = counts.get(v, 0) + 1
	var keys := counts.keys()
	keys.sort()
	var out := {}
	for k in keys:
		out[k] = counts[k]
	return out


## The parts of `from` that fit the socket at `path` on `host` in a `plan_name` build: the
## filter panel's Fits toggle.
func fitting(from: Array[PartRecord], host: PartRecord, path: String, plan_name: String) -> Array[PartRecord]:
	var out: Array[PartRecord] = []
	for r in from:
		if PartFit.fits(r, host, path, plan_name):
			out.append(r)
	return out


## `list` sorted by `key` (SORTS, or "id"); ties always break on id, so an order is the
## same every time.
static func sorted(list: Array[PartRecord], key: String, descending: bool = false) -> Array[PartRecord]:
	var out := list.duplicate()
	out.sort_custom(func(a: PartRecord, b: PartRecord) -> bool:
		var ka: Variant = _sort_key(a, key)
		var kb: Variant = _sort_key(b, key)
		if ka != kb:
			return (ka > kb) if descending else (ka < kb)
		return a.id < b.id)
	return out


static func _sort_key(r: PartRecord, key: String) -> Variant:
	match key:
		"name":
			return (r.display_name if r.display_name != "" else r.id).to_lower()
		"manufacturer":
			return r.manufacturer.to_lower()
		"class":
			return PartRecord.WEIGHT_CLASSES.find(r.weight_class)
		"rarity":
			return r.rarity
		"mass":
			return r.mass
		"newest":
			return r.saved
		"creator":
			return String(r.creator.get("name", "")).to_lower()
	return r.id


func _passes(r: PartRecord, query: Dictionary) -> bool:
	var have: Dictionary = _facets[r.id]
	for facet in query:
		var want: Array = query[facet]
		if want.is_empty():
			continue
		var any := false
		for v in have.get(facet, []):
			if v in want:
				any = true
				break
		if not any:
			return false
	return true


func _index() -> void:
	if _indexed:
		return
	_indexed = true
	_facets.clear()
	# Which classes take each gun interface: a receiver's sockets say what it accepts.
	var classes_of := {}
	for r in _parts:
		if r.family == "gun" and r.weapon_class != "":
			for s in r.sockets:
				for a in (s as Dictionary).get("accepts", []):
					if not classes_of.has(a):
						classes_of[a] = {}
					classes_of[a][r.weapon_class] = true
	for r in _parts:
		var f := {
			"family": [r.family], "source": [r.source], "manufacturer": [r.manufacturer],
			"slot": [r.slot], "side": [r.side],
		}
		for pair in [["class", r.weight_class], ["scale", r.scale], ["pod_kind", r.pod_kind],
				["creator", String(r.creator.get("name", ""))]]:
			if pair[1] != "":
				f[pair[0]] = [pair[1]]
		if r.rarity > 0:
			f["rarity"] = [r.rarity]
		if r.param("length") != null:
			f["length"] = [int(r.param("length"))]
		if not r.tags.is_empty():
			f["tags"] = Array(r.tags)
		if r.family == "gun":
			var wc: Array = [r.weapon_class] if r.weapon_class != "" \
					else (classes_of.get(r.interface(), {}) as Dictionary).keys()
			wc.sort()
			if not wc.is_empty():
				f["weapon_class"] = wc
		_facets[r.id] = f


static func _files_under(base: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(base):
		return out
	if FileAccess.file_exists(base.path_join(FILE)):
		out.append(base.path_join(FILE))
	var dirs := Array(DirAccess.get_directories_at(base))
	dirs.sort()
	for d in dirs:
		out.append_array(_files_under(base.path_join(d)))
	return out
