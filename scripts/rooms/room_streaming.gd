class_name RoomStreaming
extends RefCounted

## Which ROOMS have their furniture drawn, and the fade of each room's painted
## window. Docs/HandoffRooms.md 4; Docs/Interiors.md 8.2.
##
## What the user saw (2026-11-13): lag as interiors spawned, whole floors
## popping in at once, and windows flashing as the camera moved. The unit was a
## group of up to four storeys of a whole building, every group within 60 m was
## drawn, nothing looked at the view, and the painted windows dithered out by
## distance -- which moves with the camera.
##
## Now the unit is a room, and only a few are up:
##
##   * NEAR: the room the camera is in and the rooms of its storey, nearest
##     first; out of doors, the nearest rooms within NEAR_RANGE with a window
##     (or a hole) facing the camera. Up to NEAR_PICKS. These get collision.
##   * VIEW: then the best VIEW_PICKS by where the player looks -- the angle
##     from the middle of the screen first, then distance; only rooms with an
##     opening facing the camera, within InteriorGroups.INTERIOR_RANGE.
##   * CAP rooms up at once in all (user, 2026-11-14: 8, 2 of them by view). A
##     room that drops out of the choice stays up LINGER_MS (3 s, user) while
##     the cap allows, so glancing away and back does not respawn it.
##   * A room holds no slot if it would draw nothing (an empty room: its
##     painted window already shows an empty room).
##
## A room's furniture comes up (InteriorGroups draws only the rows of the
## rooms held here: Group.held), and THEN its painted window fades out over
## FADE_S, by time. When it is given back the window fades in first, and only
## then are its rows dropped. The fade is per room: each pane carries its room
## (BuildingShell.window_arrays, CUSTOM0) and the building's pane node carries
## the rooms being faded (shaders/window_interior.gdshader, ROOM_SLOTS).
##
## Everything here is CPU-side and main-thread: the values written to the
## panes are kept (`_written`), never read back from the renderer (CLAUDE.md
## "Where new code runs").

const CAP := 8
const VIEW_PICKS := 2
const NEAR_PICKS := CAP - VIEW_PICKS
## Out of doors, a room is near inside this (to its box).
const NEAR_RANGE := 20.0
const LINGER_MS := 3000
const FADE_S := 0.3
## Rooms a building's panes can fade at once: six vec4s of two
## (shaders/window_interior.gdshader). CAP plus room for the ones fading back in.
const PANE_VECS := 6
const ROOM_SLOTS := PANE_VECS * 2

class Rec:
	extends RefCounted
	var id := 0                 ## building
	var room := 0               ## room index in the building
	var group: InteriorGroups.Group
	var k := 0                  ## room index in the group
	var chosen_ms := 0          ## last pass it was chosen
	var near := false           ## chosen as near (collision) last time
	var pawn := false           ## a pawn stands in it (collision too)
	var want := true            ## held: chosen, or lingering under the cap
	var score := 0.0
	var hide := 0.0             ## its painted window: 0 shown, 1 gone
	var slot := -1              ## its slot on the building's panes


var groups: InteriorGroups
var registry: BuildingRegistry
## Building id -> its pane node (CityDrawing._brick_panes). Read only.
var panes: Dictionary = {}

var _recs := {}                 ## key_of(building, room) -> Rec
var _slots := {}                ## building id -> PackedInt64Array(ROOM_SLOTS): room key or -1
var _written := {}              ## building id -> [pane node instance id, Array of 6 Vector4]
var _boxes := {}                ## building id -> Array of AABB, a room's local box
var _extent := {}               ## building id -> AABB over its rooms (the plan's outer faces)
var _empty := {}                ## room key -> true: its manifest draws nothing

var passes := 0
var _last_pass_ms := 0          ## the `now` of the last pass (Rec.chosen_ms of what it chose)
var choose_ms := 0.0
var worst_choose_ms := 0.0
var picked_near := 0            ## this pass
var picked_view := 0
var waits := 0                  ## new rooms not taken, their building not known to be standing
var evicted := 0                ## all told: rooms given back by the cap
var comes := 0                  ## all told: rooms that came up (window faded out)
var goes := 0                   ## all told: rooms given back after their window came back


static func key_of(building_id: int, room: int) -> int:
	return building_id * 65536 + room


## Choose the rooms for this pass and set every group's masks (Group.held,
## Group.cover_mask). `buildings` are the ones that may have rooms drawn
## (standing, in bricks, meshed: CityScene._stream_groups). `forward` is the
## camera's, `half_fov` half its horizontal field of view in radians.
## `unsure` (building id -> bool) says a building may not get NEW rooms.
## `pawns` are where the pawns are (world): a room up with one in it gets
## collision as a near room does, so a soldier does not walk through a desk
## the player can see.
func choose(here: Vector3, forward: Vector3, half_fov: float, buildings: Array,
		unsure: Callable, pawns: PackedVector3Array = PackedVector3Array()) -> void:
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	passes += 1
	_last_pass_ms = now
	waits = 0
	var near_c: Array = []     # [score, building, group, k]
	var view_c: Array = []
	var live := {}
	for b in buildings:
		var bb: BuildingRegistry.Building = b
		live[bb.id] = true
		_candidates(bb, here, forward, half_fov, near_c, view_c)
	near_c.sort_custom(func(a, c) -> bool: return float(a[0]) < float(c[0]))
	view_c.sort_custom(func(a, c) -> bool: return float(a[0]) < float(c[0]))
	var unsure_of := {}
	var chosen := {}
	picked_near = _pick(near_c, NEAR_PICKS, true, chosen, unsure, unsure_of, now)
	picked_view = _pick(view_c, VIEW_PICKS, false, chosen, unsure, unsure_of, now)
	# Gone with their building, or their group made afresh: forgotten now, no
	# fade (there is nothing on screen of them to fade).
	for key in _recs.keys():
		var r: Rec = _recs[key]
		var layout := groups.known(r.id)
		if not live.has(r.id) or r.group.index >= layout.size() or layout[r.group.index] != r.group:
			_forget(key)
	# Linger, under the cap: chosen ones first (chosen_ms is now), then the
	# most recently chosen.
	var held: Array = []
	for key in _recs:
		var r: Rec = _recs[key]
		if chosen.has(key) or now - r.chosen_ms < LINGER_MS:
			held.append(r)
		elif r.want:
			r.want = false
	held.sort_custom(func(a, c) -> bool:
		return a.chosen_ms > c.chosen_ms or (a.chosen_ms == c.chosen_ms and a.score < c.score))
	for i in held.size():
		var r: Rec = held[i]
		var keep := i < CAP
		if r.want and not keep:
			evicted += 1
		r.want = keep
	# What is given back with its window shown again has nothing left to wait
	# for: forgotten, and its rows dropped below.
	for key in _recs.keys():
		var r: Rec = _recs[key]
		if not r.want and r.hide <= 0.0:
			if r.group.on_screen.size() > r.k and r.group.on_screen[r.k] != 0:
				goes += 1
			_forget(key)
	_mark_pawns(buildings, pawns)
	_set_masks(buildings)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	choose_ms += ms
	worst_choose_ms = maxf(worst_choose_ms, ms)


## Every room of `b` that may be chosen, scored, into `near_c` and `view_c`.
func _candidates(b: BuildingRegistry.Building, here: Vector3, forward: Vector3,
		half_fov: float, near_c: Array, view_c: Array) -> void:
	var inv := b.xform.affine_inverse()
	var local: Vector3 = inv * here
	var fwd: Vector3 = (inv.basis * forward).normalized()
	var rooms := registry.rooms_of(b.id)
	var boxes := _boxes_of(b, rooms)
	var ext: AABB = _extent[b.id]
	var inside := local.x > ext.position.x - 1.0 and local.x < ext.end.x + 1.0 \
			and local.z > ext.position.z - 1.0 and local.z < ext.end.z + 1.0 \
			and local.y > ext.position.y - 1.0 and local.y < ext.end.y
	for g in groups.layout(b):
		var gd := box_distance(g.box, local)
		if gd > InteriorGroups.INTERIOR_RANGE:
			continue
		# A group nowhere near and wholly out of view has nothing to offer.
		if gd > NEAR_RANGE and off_view(g.box, local, fwd) > half_fov:
			continue
		for k in range(g.last_room - g.first_room):
			var index: int = g.first_room + k
			var lb: AABB = boxes[index]
			var room: Room = rooms[index]
			var storey := inside and local.y >= lb.position.y - 0.5 and local.y < lb.end.y
			var facing := faces(room, lb, local, ext)
			if not facing and not storey:
				continue
			var d := box_distance(lb, local)
			if d <= NEAR_RANGE:
				# The camera's own storey first, nearest first (its own room is
				# 0); then rooms seen from outside.
				near_c.append([d + (0.0 if storey else NEAR_RANGE), b, g, k])
				continue
			if not facing:
				continue
			var off := off_view(lb, local, fwd)
			if off > half_fov:
				continue
			view_c.append([off + 0.2 * d / InteriorGroups.INTERIOR_RANGE, b, g, k])


## Take up to `n` rooms off a sorted candidate list into `chosen`.
func _pick(cands: Array, n: int, near: bool, chosen: Dictionary, unsure: Callable,
		unsure_of: Dictionary, now: int) -> int:
	var got := 0
	for c in cands:
		if got >= n:
			break
		var b: BuildingRegistry.Building = c[1]
		var g: InteriorGroups.Group = c[2]
		var k: int = c[3]
		var index: int = g.first_room + k
		var key := key_of(b.id, index)
		if chosen.has(key):
			continue
		var r: Rec = _recs.get(key)
		if r == null or not r.want:
			# New: only in a building known to be standing (CityScene.
			# _interior_unsure), and only if it draws something.
			if not unsure_of.has(b.id):
				unsure_of[b.id] = bool(unsure.call(b.id))
			if unsure_of[b.id]:
				waits += 1
				continue
			if not _draws(key, registry.get_room(b.id, index)):
				continue
		if r == null:
			r = Rec.new()
			r.id = b.id
			r.room = index
			_recs[key] = r
		r.group = g
		r.k = k
		r.chosen_ms = now
		r.near = near
		r.score = float(c[0])
		r.want = true
		chosen[key] = true
		got += 1
	return got


func _mark_pawns(buildings: Array, pawns: PackedVector3Array) -> void:
	var by_id := {}
	for b in buildings:
		by_id[(b as BuildingRegistry.Building).id] = b
	for key in _recs:
		var r: Rec = _recs[key]
		r.pawn = false
		if not r.want or pawns.is_empty() or not by_id.has(r.id):
			continue
		var b: BuildingRegistry.Building = by_id[r.id]
		var lb: AABB = (_boxes_of(b, registry.rooms_of(b.id))[r.room] as AABB).grow(0.3)
		var inv := b.xform.affine_inverse()
		for p in pawns:
			if lb.has_point(inv * p):
				r.pawn = true
				break


## Whether a room's manifest draws anything: an empty room's painted window
## already shows an empty room, and a slot is worth more than that.
func _draws(key: int, room: Room) -> bool:
	if room == null or _empty.has(key):
		return false
	if room.items.is_empty():
		room.items = RoomManifest.items_for(room)
	if room.items.size() - room.gone.size() - room.laid.size() <= 0:
		_empty[key] = true
		return false
	return true


## Each group's masks from the records: held = its rows are drawn (wanted, or
## its window still fading back in); cover = wanted and near.
func _set_masks(buildings: Array) -> void:
	var by_group := {}
	for key in _recs:
		var r: Rec = _recs[key]
		var list: Array = by_group.get(r.group.get_instance_id(), [])
		list.append(r)
		by_group[r.group.get_instance_id()] = list
	for b in buildings:
		for g in groups.layout(b):
			var n: int = g.last_room - g.first_room
			var mine: Array = by_group.get(g.get_instance_id(), [])
			if mine.is_empty() and g.held.size() == n and not g.held.has(1) and not g.cover_mask.has(1):
				continue   # nothing held, and its masks say so already
			var held := PackedByteArray()
			held.resize(n)
			held.fill(0)
			var cover := PackedByteArray()
			cover.resize(n)
			cover.fill(0)
			for r in mine:
				held[r.k] = 1
				if r.want and (r.near or r.pawn):
					cover[r.k] = 1
			if held != g.held:
				g.held = held
				g.dirty = true
			if cover != g.cover_mask:
				g.cover_mask = cover
				g.cover_stale = true


## Every tick: move each room's window fade on by `dt` seconds, and write what
## changed to the panes.
func tend(dt: float) -> void:
	var step := dt / FADE_S
	var touched := {}
	for key in _recs:
		var r: Rec = _recs[key]
		var on: bool = r.group.shown and r.group.on_screen.size() > r.k \
				and r.group.on_screen[r.k] != 0
		var target := 1.0 if r.want and on else 0.0
		var was := r.hide
		if not on:
			r.hide = 0.0   # nothing drawn behind it: the window at once
		elif target > r.hide:
			if r.slot < 0 and not _take_slot(r, key):
				continue   # no slot free: its window stays until one is
			if r.hide <= 0.0:
				comes += 1
			r.hide = minf(r.hide + step, 1.0)
		elif target < r.hide:
			r.hide = maxf(r.hide - step, 0.0)
		if r.hide <= 0.0 and target <= 0.0 and r.slot >= 0:
			_free_slot(r)
			touched[r.id] = true
		elif r.hide != was:
			touched[r.id] = true
	for id in _slots:
		_write(id, touched.has(id))


func _take_slot(r: Rec, key: int) -> bool:
	var s: PackedInt64Array = _slots.get(r.id, PackedInt64Array())
	if s.is_empty():
		s.resize(ROOM_SLOTS)
		s.fill(-1)
	var at := s.find(-1)
	if at < 0:
		return false
	s[at] = key
	_slots[r.id] = s
	r.slot = at
	return true


func _free_slot(r: Rec) -> void:
	var s: PackedInt64Array = _slots.get(r.id, PackedInt64Array())
	if r.slot >= 0 and r.slot < s.size():
		s[r.slot] = -1
		_slots[r.id] = s
	r.slot = -1


## The building's slots onto its pane node: only what changed, unless the node
## is a new one (made again after a hit), which gets all of it.
func _write(id: int, changed: bool) -> void:
	var node = panes.get(id)
	if node == null or not is_instance_valid(node):
		_written.erase(id)
		return
	var had: Array = _written.get(id, [])
	var fresh: bool = had.is_empty() or int(had[0]) != (node as Object).get_instance_id()
	if not changed and not fresh:
		return
	var s: PackedInt64Array = _slots.get(id, PackedInt64Array())
	var values: Array = []
	for i in PANE_VECS:
		var v := Vector4(-1.0, 0.0, -1.0, 0.0)
		for half in 2:
			var at := i * 2 + half
			if at < s.size() and s[at] >= 0:
				var r: Rec = _recs.get(s[at])
				if r != null:
					v[half * 2] = float(r.room)
					v[half * 2 + 1] = r.hide
		values.append(v)
	for i in values.size():
		if fresh or values[i] != (had[1] as Array)[i]:
			InstanceParams.put(node as GeometryInstance3D, StringName("room_fade%d" % i), values[i])
	_written[id] = [(node as Object).get_instance_id(), values]


func _forget(key: int) -> void:
	var r: Rec = _recs.get(key)
	if r == null:
		return
	if r.slot >= 0:
		_free_slot(r)
		_write(r.id, true)
	_recs.erase(key)


## Everything of one building: its groups were dropped (its bricks went, it
## came down, it left the range).
func forget_building(id: int) -> void:
	for key in _recs.keys():
		if (_recs[key] as Rec).id == id:
			_forget(key)
	_slots.erase(id)
	_written.erase(id)
	_boxes.erase(id)
	_extent.erase(id)


## A room changed what it draws (a piece crushed, laid): asked again whether
## it is empty.
func room_changed(building_id: int, room: int) -> void:
	_empty.erase(key_of(building_id, room))


## Every room held was chosen by the last pass (none only lingering), is up
## with its window gone, and none is on its way out. For the gates
## (`--groups`): after the camera moves, the rooms of where it was linger
## LINGER_MS, and the choice from here is not settled until they have gone.
func settled() -> bool:
	for key in _recs:
		var r: Rec = _recs[key]
		if not r.want or r.hide < 1.0 or r.chosen_ms != _last_pass_ms:
			return false
	return true


## The rooms held now, as [building id, room index, near, hide].
func held_rooms() -> Array:
	var out: Array = []
	for key in _recs:
		var r: Rec = _recs[key]
		if r.want:
			out.append([r.id, r.room, r.near, r.hide])
	return out


func is_held(building_id: int, room: int) -> bool:
	var r: Rec = _recs.get(key_of(building_id, room))
	return r != null and r.want


func hide_of(building_id: int, room: int) -> float:
	var r: Rec = _recs.get(key_of(building_id, room))
	return r.hide if r != null else 0.0


func report() -> Dictionary:
	var held := 0
	var fading := 0
	for key in _recs:
		var r: Rec = _recs[key]
		if r.want:
			held += 1
		if r.hide > 0.0 and r.hide < 1.0:
			fading += 1
	return {"held": held, "fading": fading, "near": picked_near, "view": picked_view,
			"evicted": evicted, "comes": comes, "goes": goes, "passes": passes,
			"choose_ms": choose_ms, "worst_choose_ms": worst_choose_ms}


## A room's box in its building's own space, and the box over all its rooms
## (whose faces are the plan's outer walls). For the gates.
func room_box(b: BuildingRegistry.Building, index: int) -> AABB:
	return _boxes_of(b, registry.rooms_of(b.id))[index]


func extent_of(b: BuildingRegistry.Building) -> AABB:
	_boxes_of(b, registry.rooms_of(b.id))
	return _extent[b.id]


## A room would draw something if chosen (not empty). For the gates.
func draws(building_id: int, index: int) -> bool:
	return _draws(key_of(building_id, index), registry.get_room(building_id, index))


func _boxes_of(b: BuildingRegistry.Building, rooms: Array) -> Array:
	var have = _boxes.get(b.id)
	if have != null and (have as Array).size() == rooms.size():
		return have
	var out: Array = []
	var ext := AABB()
	for i in rooms.size():
		var lb: AABB = (rooms[i] as Room).local_box()
		out.append(lb)
		ext = lb if i == 0 else ext.merge(lb)
	_boxes[b.id] = out
	_extent[b.id] = ext
	return out


## Whether a room shows the camera an opening: it is on the outer face of the
## plan the camera is outside of (every outer wall has windows), or it has a
## hole blown in a wall (Room.openings, as last found) on the camera's side.
static func faces(room: Room, lb: AABB, local: Vector3, ext: AABB) -> bool:
	const E := 0.05
	if lb.position.x <= ext.position.x + E and local.x < lb.position.x:
		return true
	if lb.end.x >= ext.end.x - E and local.x > lb.end.x:
		return true
	if lb.position.z <= ext.position.z + E and local.z < lb.position.z:
		return true
	if lb.end.z >= ext.end.z - E and local.z > lb.end.z:
		return true
	if not room.openings.is_empty():
		var c := lb.get_center()
		for o in room.openings:
			var oc: Vector3 = (o as AABB).get_center()
			var out := oc - c
			out.y = 0.0
			if out.dot(local - oc) > 0.0:
				return true
	return false


## How far off the middle of the view a box is, in radians: the angle to its
## centre less the angle its half-size makes from here (0 if the camera looks
## at any of it, or is inside it).
static func off_view(box: AABB, local: Vector3, fwd: Vector3) -> float:
	var to := box.get_center() - local
	var dist := to.length()
	var half := box.size.length() * 0.5
	if dist <= half:
		return 0.0
	var ang := acos(clampf(to.dot(fwd) / dist, -1.0, 1.0))
	return maxf(ang - asin(clampf(half / dist, 0.0, 1.0)), 0.0)


static func box_distance(box: AABB, point: Vector3) -> float:
	var lo: Vector3 = box.position
	var hi: Vector3 = box.end
	return Vector3(maxf(maxf(lo.x - point.x, point.x - hi.x), 0.0),
			maxf(maxf(lo.y - point.y, point.y - hi.y), 0.0),
			maxf(maxf(lo.z - point.z, point.z - hi.z), 0.0)).length()
