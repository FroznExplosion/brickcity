class_name BuildLifts
extends Node3D

## Lifts in a build's shafts (Docs/RoomModules.md 4): a platform in each shaft
## of every build that is bricks. Stood on, it carries whoever is on it a
## storey up (down from the top storey); stood by on another storey, it comes
## there. A moving thing, so a node following its building's chunk, as a door
## is (BuildDoors).
##
##   meta["lifts"]   [{"lo": [x, y, z], "size": [sx, sz], "stops": [y, ...]}]
##                   the shaft's low corner and inside in the build's cells;
##                   each stop a floor row the platform lies in, its top level
##                   with that storey's floor -- what RoomShell puts in a tower

## How fast it rides, metres a second; how long someone stands on it before it goes.
const SPEED := 2.0
const DWELL := 0.8
## How far round the shaft a figure stands to call it, studs.
const CALL := 3
const RESYNC := 0.5

var world: BrickWorld
var sources: Callable
## key -> {chunk, sig, lifts: [{body, ride: Area3D, calls: [Area3D], stops, at: float (cell row),
##          target: int (stop index), stop: int, wait: float, base: Vector3}]}
var _builds := {}
var _since := 0.0


static func of(r: BuildRecipe) -> Array:
	var out := []
	for l: Dictionary in r.meta.get("lifts", []):
		out.append({"lo": BuildRecipe.cell_from(l.lo), "size": Vector2i(int(l.size[0]), int(l.size[1])),
				"stops": (l.stops as Array).map(func(y) -> int: return int(y))})
	return out


static func record(lo: Vector3i, size: Vector2i, stops: Array) -> Dictionary:
	return {"lo": [lo.x, lo.y, lo.z], "size": [size.x, size.y], "stops": stops}


func _init(w: BrickWorld = null, src := Callable()) -> void:
	world = w
	sources = src
	name = "BuildLifts"


func _physics_process(delta: float) -> void:
	if world == null or not sources.is_valid():
		return
	_since += delta
	if _since >= RESYNC:
		_since = 0.0
		resync()
	var cell := BrickWorld.get_cell_size()
	for key in _builds:
		var e: Dictionary = _builds[key]
		var xf := world.get_chunk_transform(int(e.chunk))
		for lf: Dictionary in e.lifts:
			_drive(lf, delta)
			var at := Transform3D(Basis(), (lf.base as Vector3) + Vector3(0, float(lf.at) * cell.y, 0))
			(lf.body as Node3D).global_transform = xf * at
			for i in (lf.calls as Array).size():
				(lf.calls[i] as Node3D).global_transform = xf * Transform3D(Basis(),
						(lf.base as Vector3) + Vector3(0, int(lf.stops[i]) * cell.y, 0))


## One lift a tick: riding to its target; at a stop, off on a ride when someone
## has stood on it DWELL, or to a stop someone waits at when nobody is on it.
func _drive(lf: Dictionary, delta: float) -> void:
	var stops: Array = lf.stops
	var cell := BrickWorld.get_cell_size()
	var goal := float(stops[int(lf.target)])
	if not is_equal_approx(float(lf.at), goal):
		lf.at = move_toward(float(lf.at), goal, SPEED / cell.y * delta)
		return
	lf.stop = int(lf.target)
	if _riders(lf.ride):
		lf.wait = float(lf.wait) + delta
		if float(lf.wait) >= DWELL and stops.size() > 1:
			lf.wait = 0.0
			var i := int(lf.stop)
			lf.target = i + 1 if i + 1 < stops.size() else i - 1
		return
	lf.wait = 0.0
	for i in (lf.calls as Array).size():
		if i != int(lf.stop) and _riders(lf.calls[i]):
			lf.target = i
			return


func _riders(area: Area3D) -> bool:
	for b in area.get_overlapping_bodies():
		if b is CharacterBody3D:
			return true
	return false


func resync() -> void:
	var seen := {}
	for s: Array in sources.call():
		var key = s[0]
		var chunk: int = s[1]
		var r: BuildRecipe = s[2]
		var rebase: Vector3i = s[3]
		var lifts := of(r)
		if lifts.is_empty():
			continue
		seen[key] = true
		var sig := "%d %d %s" % [chunk, r.size(), str(lifts)]
		var e: Dictionary = _builds.get(key, {})
		if e.is_empty() or String(e.sig) != sig:
			_drop(key)
			e = {"chunk": chunk, "sig": sig, "lifts": []}
			var xf := world.get_chunk_transform(chunk)
			for l: Dictionary in lifts:
				e.lifts.append(_make(l, rebase, xf))
			_builds[key] = e
	for key in _builds.keys():
		if not seen.has(key):
			_drop(key)


func count() -> int:
	var n := 0
	for key in _builds:
		n += (_builds[key].lifts as Array).size()
	return n


func lifts() -> Array:
	var out := []
	for key in _builds:
		out.append_array(_builds[key].lifts)
	return out


func _drop(key) -> void:
	if not _builds.has(key):
		return
	for lf: Dictionary in _builds[key].lifts:
		(lf.body as Node).queue_free()
		for a in lf.calls:
			(a as Node).queue_free()
	_builds.erase(key)


## A platform the shaft's inside a plate thick, lying in its lowest stop's row;
## over it a box that sees who is on it; at every stop a box round the shaft
## that sees who waits there.
func _make(l: Dictionary, rebase: Vector3i, xf: Transform3D) -> Dictionary:
	var cell := BrickWorld.get_cell_size()
	var lo: Vector3i = (l.lo as Vector3i) - rebase
	var size: Vector2i = l.size
	var stops: Array = (l.stops as Array).map(func(y) -> int: return int(y) - rebase.y)
	var w := size.x * cell.x
	var d := size.y * cell.z
	var base := Vector3(lo.x * cell.x, 0, lo.z * cell.z)
	var body := AnimatableBody3D.new()
	body.sync_to_physics = true
	add_child(body)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w - 0.04, cell.y, d - 0.04)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BrickWorld.get_material_colour(0, BuildDoors.default_colour())
	bm.material = mat
	mi.mesh = bm
	mi.position = Vector3(w * 0.5, cell.y * 0.5, d * 0.5)
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = bm.size
	cs.shape = shape
	cs.position = mi.position
	body.add_child(cs)
	var ride := _area(Vector3(w - 0.1, 1.2, d - 0.1), Vector3(w * 0.5, cell.y + 0.6, d * 0.5))
	body.add_child(ride)
	var calls := []
	for y in stops:
		var c := CALL * cell.x
		var a := _area(Vector3(w + c * 2.0, 1.2, d + c * 2.0), Vector3(w * 0.5, cell.y + 0.6, d * 0.5))
		add_child(a)
		calls.append(a)
	body.global_transform = xf * Transform3D(Basis(), base + Vector3(0, int(stops[0]) * cell.y, 0))
	return {"body": body, "ride": ride, "calls": calls, "stops": stops, "at": float(stops[0]),
			"target": 0, "stop": 0, "wait": 0.0, "base": base}


func _area(size: Vector3, at: Vector3) -> Area3D:
	var a := Area3D.new()
	a.monitorable = false
	a.collision_mask = 0xFFFFFFFF
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	cs.position = at
	a.add_child(cs)
	return a
