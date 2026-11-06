class_name BuildLadders
extends Node3D

## Ladders in a build that is bricks (Docs/RoomModules.md 7.13): a Ladder node
## for each of `meta.ladders`, following its building's chunk, as a lift does
## (BuildLifts) -- so a player's generated tower in the city or the workshop is
## climbed where its ladder's bricks stand. A station or ship lays its own
## (Ladder.place, under its bricks' node).

const RESYNC := 0.5

var world: BrickWorld
var sources: Callable
## key -> {chunk, sig, ladders: [Ladder], local: [Transform3D]}
var _builds := {}
var _since := 0.0


func _init(w: BrickWorld = null, src := Callable()) -> void:
	world = w
	sources = src
	name = "BuildLadders"


func _physics_process(delta: float) -> void:
	if world == null or not sources.is_valid():
		return
	_since += delta
	if _since >= RESYNC:
		_since = 0.0
		resync()
	for key in _builds:
		var e: Dictionary = _builds[key]
		var xf := world.get_chunk_transform(int(e.chunk))
		for i in (e.ladders as Array).size():
			(e.ladders[i] as Node3D).global_transform = xf * (e.local[i] as Transform3D)


func resync() -> void:
	var seen := {}
	for s: Array in sources.call():
		var key = s[0]
		var chunk: int = s[1]
		var r: BuildRecipe = s[2]
		var rebase: Vector3i = s[3]
		var list: Array = r.meta.get("ladders", [])
		if list.is_empty():
			continue
		seen[key] = true
		var sig := "%d %d %s" % [chunk, r.size(), str(list)]
		var e: Dictionary = _builds.get(key, {})
		if e.is_empty() or String(e.sig) != sig:
			_drop(key)
			e = {"chunk": chunk, "sig": sig, "ladders": [], "local": []}
			var xf := world.get_chunk_transform(chunk)
			for d: Dictionary in list:
				var l := Ladder.make(d, rebase)
				e.local.append(l.transform)
				add_child(l)
				l.global_transform = xf * l.transform
				e.ladders.append(l)
			_builds[key] = e
	for key in _builds.keys():
		if not seen.has(key):
			_drop(key)


func count() -> int:
	var n := 0
	for key in _builds:
		n += (_builds[key].ladders as Array).size()
	return n


func _drop(key) -> void:
	if not _builds.has(key):
		return
	for l: Node in _builds[key].ladders:
		l.queue_free()
	_builds.erase(key)
