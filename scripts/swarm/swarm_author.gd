class_name SwarmAuthor
extends Node3D
## In-game placement of the two things a level hand-authors for the horde: climb approaches and
## no-climb regions. Aim, click, saved to disk, reloaded next run.
##
## This is deliberately small and deliberately data-first. ceramicedge's Forge is already a
## portable addon (`forge/`, its own plugin.cfg, host-project catalogs merged from JSON) and is
## the eventual home for this — a climb point is an object-palette entry and a no-climb box is a
## brush. So the *tool* here is throwaway, but the FILE is not: it is a plain JSON array of
## `{type, ...}` dicts in the same shape Forge's level.json uses, so porting means teaching Forge
## to write this file, not redoing the data.
##
##   [K]      toggle authoring mode (mouse look and firing are suspended; the overlay then
##            lists every control and which half of a two-click placement you are on)
##   [1]/[2]  climb point / no-climb box
##   [LMB]    place — climb point takes two clicks (foot, then landing), box takes two corners
##   [Z]      undo the last placement
##   [X]      clear everything authored
##   [ENTER]  save     [L] reload from disk

const SAVE_PATH := "user://swarm_authoring.json"
const NL := "
"

enum { MODE_CLIMB, MODE_NOCLIMB }

var swarm: SwarmCore
var camera: Camera3D
var active := false
var mode := MODE_CLIMB

var _entries: Array = []          ## the authored data, exactly as saved
var _pending := Vector3.ZERO      ## first click of a two-click placement
var _has_pending := false
var _markers: Node3D


func setup(core: SwarmCore, cam: Camera3D) -> void:
	swarm = core
	camera = cam
	_markers = Node3D.new()
	_markers.name = "AuthorMarkers"
	add_child(_markers)
	load_from_disk()


## Where the player is aiming, against the level's collision. Returns false if the ray hits
## nothing, which is what you get pointing at the sky.
func _aim(out: Array) -> bool:
	if camera == null:
		return false
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	out.append(hit["position"])
	return true


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_K:
				active = not active
				_has_pending = false
				get_viewport().set_input_as_handled()
			KEY_1:
				if active: mode = MODE_CLIMB
			KEY_2:
				if active: mode = MODE_NOCLIMB
			KEY_Z:
				if active and not _entries.is_empty():
					_entries.pop_back()
					_apply()
			KEY_X:
				if active:
					_entries.clear()
					_apply()
			KEY_ENTER, KEY_KP_ENTER:
				if active: save_to_disk()
			KEY_L:
				if active: load_from_disk()
		return

	if not active:
		return
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		# Swallow the click so it never reaches the gun while authoring.
		get_viewport().set_input_as_handled()
		var res: Array = []
		if not _aim(res):
			return
		var p: Vector3 = res[0]
		if not _has_pending:
			_pending = p
			_has_pending = true
			return
		_has_pending = false
		if mode == MODE_CLIMB:
			# First click is the foot the pile forms at, second is where they land.
			_entries.append({"type": "climb", "base": _v(_pending), "top": _v(p)})
		else:
			var lo := Vector3(minf(_pending.x, p.x), minf(_pending.y, p.y), minf(_pending.z, p.z))
			var hi := Vector3(maxf(_pending.x, p.x), maxf(_pending.y, p.y), maxf(_pending.z, p.z))
			hi.y = maxf(hi.y, lo.y + 3.0)   # a flat drag still has to box something
			_entries.append({"type": "no_climb", "center": _v((lo + hi) * 0.5), "size": _v(hi - lo)})
		_apply()


## Push the whole authored set into the core. Rebuilt wholesale rather than incrementally: the
## core rebuilds its spot list from scratch anyway, and "replay the file" is the only version of
## this that cannot drift from what is on disk.
func _apply() -> void:
	if swarm == null:
		return
	swarm.clear_climb_points()
	swarm.clear_no_climb()
	for e in _entries:
		if e["type"] == "climb":
			swarm.add_climb_point(_a(e["base"]), _a(e["top"]))
		else:
			swarm.add_no_climb(_a(e["center"]), _a(e["size"]))
	_redraw()


func _redraw() -> void:
	for c in _markers.get_children():
		c.queue_free()
	for e in _entries:
		if e["type"] == "climb":
			_ball(_a(e["base"]), Color(1.0, 0.55, 0.1), 0.3)
			_ball(_a(e["top"]), Color(0.2, 1.0, 0.5), 0.3)
		else:
			_box(_a(e["center"]), _a(e["size"]), Color(1.0, 0.2, 0.2, 0.18))


func _ball(pos: Vector3, col: Color, r: float) -> void:
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	m.mesh = s
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	m.material_override = mat
	m.position = pos
	_markers.add_child(m)


func _box(center: Vector3, size: Vector3, col: Color) -> void:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.material_override = mat
	m.position = center
	_markers.add_child(m)


# Vector3 <-> plain arrays, so the file stays engine-portable the way Forge's level.json is.
func _v(p: Vector3) -> Array: return [p.x, p.y, p.z]
func _a(a) -> Vector3: return Vector3(float(a[0]), float(a[1]), float(a[2]))


func save_to_disk() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("SwarmAuthor: cannot write %s" % SAVE_PATH)
		return
	f.store_string(JSON.stringify({"version": 1, "entries": _entries}, "\t"))
	f.close()
	print("SwarmAuthor: saved %d entries to %s" % [_entries.size(), SAVE_PATH])


func load_from_disk() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("entries"):
		push_warning("SwarmAuthor: %s is not authoring data" % SAVE_PATH)
		return
	_entries = parsed["entries"]
	_apply()
	print("SwarmAuthor: loaded %d entries" % _entries.size())


func status() -> String:
	if not active:
		return ""
	var m := "CLIMB POINT" if mode == MODE_CLIMB else "NO-CLIMB BOX"
	# Say what the NEXT click does, not just which mode is on — a two-click placement is the one
	# thing about this tool you cannot work out by looking at the screen.
	var step: String
	if mode == MODE_CLIMB:
		step = "click 2 of 2: where they LAND" if _has_pending else "click 1 of 2: the pile FOOT"
	else:
		step = "click 2 of 2: opposite corner" if _has_pending else "click 1 of 2: first corner"
	return NL.join([
		"---- AUTHORING -------------------------------",
		"  mode: %s   (%s)" % [m, step],
		"  placed: %d      file: %s" % [_entries.size(), SAVE_PATH],
		"  [1] climb point   [2] no-climb box",
		"  [LMB] place   [Z] undo   [X] clear all",
		"  [ENTER] save   [L] reload   [K] exit authoring",
		"----------------------------------------------",
	])
