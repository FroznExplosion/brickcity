## What the workers handed the renderer between two calls into it, by source.
##
## A mesh made on a worker is packed there, but with the renderer on the main
## thread its buffers are made there, at the next call into it (CityScene's
## "render" phase flushes them). That phase spiked to 25-50 ms in the big
## city's collapse with the island uploads under their budget
## (IslandManager.UPLOAD_VERTS_PER_TICK), so something else was landing: each
## worker upload notes itself here, and a slow flush says what it carried.
class_name UploadLedger
extends RefCounted

static var _lock := Mutex.new()
static var _since := {}   # source -> [meshes, vertices] since the last take()


## From the worker, once its mesh is made. `verts` -1 when not known.
static func note(source: String, verts: int) -> void:
	_lock.lock()
	var row: Array = _since.get(source, [0, 0])
	row[0] += 1
	row[1] += maxi(verts, 0)
	_since[source] = row
	_lock.unlock()


static func verts_of(arrays: Array) -> int:
	if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
		return 0
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


## What landed since the last take, and start again.
static func take() -> Dictionary:
	_lock.lock()
	var out := _since
	_since = {}
	_lock.unlock()
	return out


## One line: "island 3 (120k), band 1 (40k)".
static func line(rows: Dictionary) -> String:
	var parts: Array[String] = []
	for k in rows:
		var r: Array = rows[k]
		parts.append("%s %d (%dk)" % [k, r[0], int(r[1]) / 1000])
	return ", ".join(parts) if not parts.is_empty() else "nothing"
