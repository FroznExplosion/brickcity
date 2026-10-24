class_name PartLobby
extends RefCounted
## What a match needs of the parts, and getting what a player is missing (Docs/ModularParts.md
## section 7, "In a match"; stage 10). The network half -- the lobby's messages, the host's
## connection -- waits on the game's netcode; this is everything around it, so the netcode
## only has to carry these dictionaries and byte chunks.
##
##   host     list(ids) -> the match's parts: id, rev, hash, a Steam Workshop item if it has
##            one, and the record (no bricks) so a missing part can stand in by its shape
##   client   missing(list) -> what it lacks (or has another version of); each comes from
##            Steam if it has an item, else from the host: PartTransfer
##   either   placeholder(entry) -> a part of the missing one's slot and fit, shown as a plain
##            block, so its mech still plays; swapped for the real one once it is in

## A part's Steam Workshop item, kept beside it once it has one (stage 10's Steam half).
const STEAM_FILE := "steam.json"
const PLACEHOLDER_DIR := "user://parts/placeholder/"


## The match's parts, for the lobby: each id in `ids` that the catalogue has.
static func list(ids: Array, cat: PartCatalog) -> Array:
	var out := []
	var seen := {}
	for id in ids:
		var r := cat.get_part(String(id))
		if r == null or seen.has(r.id):
			continue
		seen[r.id] = true
		var shape := r.to_dict()
		shape.erase("bricks")   # the shape, not the part: small enough for the lobby
		var e := {"id": r.id, "rev": r.rev, "hash": PartPackage.hash_for(r.dir), "record": shape,
				"source": r.source}
		var item := steam_item(r.dir)
		if item != 0:
			e["steam_item"] = item
		out.append(e)
	return out


## The entries of a lobby `list` this player does not have as the host has them: not here,
## or here as another hash. Official parts are shipped: the same game has them.
static func missing(entries: Array, cat: PartCatalog) -> Array:
	var out := []
	for e: Dictionary in entries:
		if String(e.get("source", "")) == "official" and cat.get_part(String(e.id)) != null:
			continue
		var r := cat.get_part(String(e.id))
		if r != null and PartPackage.hash_for(r.dir) == String(e.hash):
			continue
		out.append(e)
	return out


## Where a missing part comes from: "steam" (its Workshop item, kept) or "host" (in chunks,
## over the match's connection).
static func source_for(entry: Dictionary) -> String:
	return "steam" if int(entry.get("steam_item", 0)) != 0 and SteamParts.available() else "host"


static func steam_item(dir: String) -> int:
	var t := FileAccess.get_file_as_string(dir + STEAM_FILE) if dir != "" else ""
	var d = JSON.parse_string(t) if t != "" else null
	return int(d.get("item", 0)) if d is Dictionary else 0


## A stand-in for a missing part: its record as the lobby gave it (so it fits where the
## real one does), tagged "placeholder", drawn as a plain block. Null if the entry's record
## is not one.
static func placeholder(entry: Dictionary) -> PartRecord:
	var d = entry.get("record")
	if not d is Dictionary:
		return null
	var r := PartRecord.from_dict(d)
	if not r.problems().is_empty():
		return null
	r.source = "custom"
	if r.creator.is_empty():
		r.creator = {"name": "?"}
	r.tags = PackedStringArray(Array(r.tags) + ["placeholder"])
	r.dir = _placeholder_scene(r)
	return r


## A block with the part's mount and sockets where the record cannot say: at its origin.
static func _placeholder_scene(r: PartRecord) -> String:
	var dir := PLACEHOLDER_DIR + r.slot + "/"
	if FileAccess.file_exists(dir + "part.scn"):
		return dir
	DirAccess.make_dir_recursive_absolute(dir)
	var root := Node3D.new()
	root.name = r.slot
	var box := MeshInstance3D.new()
	box.name = "Model"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.6, 0.6, 0.6) if r.scale != "held" else Vector3(0.05, 0.05, 0.12)
	box.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.55, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material_override = mat
	root.add_child(box)
	box.owner = root
	var mount := Node3D.new()
	mount.name = "mount"
	root.add_child(mount)
	mount.owner = root
	var ps := PackedScene.new()
	ps.pack(root)
	root.free()
	ResourceSaver.save(ps, dir + "part.scn")
	return dir
