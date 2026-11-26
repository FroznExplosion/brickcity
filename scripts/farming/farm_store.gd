class_name FarmStore
extends RefCounted
## Every tilled plot of a world, kept by 256 x 256-stud region like the
## terrain's edits (Docs/MineFarming.md 11, MineWorld.md 9):
## `<save>.regions/r_<rx>_<rz>.farm`, zstd, header BCMF, format 1, then the
## plots as rows (FarmPlant.to_row) through var_to_bytes. A save writes only
## the regions changed since the last one (`take_dirty`, then `write_regions`
## on a worker). A world with no farm writes no farm file.
##
## All of a world's plots are held in memory (a plot is a small Dictionary).
## A plot out of the player's reach is never touched: it keeps the time it was
## last settled to and catches up when the player comes back (FarmPlant).

const MAGIC := "BCMF"
const FORMAT := 1
## Region size, studs (BrickTerrain's edit regions).
const REGION_STUDS := 256

## block (Vector3i) -> plot (Dictionary).
var plots := {}
## Regions changed since the last save: Vector2i -> true.
var _dirty := {}
## Bumped when a plot comes or goes (FarmFields regroups).
var version := 0


static func region_of(b: Vector3i) -> Vector2i:
	@warning_ignore("integer_division")
	var r := REGION_STUDS / 2
	return Vector2i(floori(float(b.x) / r), floori(float(b.z) / r))


func clear() -> void:
	plots.clear()
	_dirty.clear()
	version += 1


func count() -> int:
	return plots.size()


func get_plot(b: Vector3i) -> Dictionary:
	return plots.get(b, {})


func put(plot: Dictionary) -> void:
	plots[plot.b] = plot
	touch(plot.b)
	version += 1


func remove(b: Vector3i) -> void:
	if plots.erase(b):
		touch(b)
		version += 1


## The plot at `b` changed: its region is saved next time.
func touch(b: Vector3i) -> void:
	_dirty[region_of(b)] = true


func has_dirty() -> bool:
	return not _dirty.is_empty()


## The changed regions as [[rx, rz, bytes], ...], packed here on the main
## thread (a region of plots is small), the dirty set cleared. An empty
## region packs as empty bytes: its file is removed.
func take_dirty() -> Array:
	var rows_by := {}
	for r in _dirty:
		rows_by[r] = []
	for b in plots:
		var r := region_of(b)
		if rows_by.has(r):
			rows_by[r].append(FarmPlant.to_row(plots[b]))
	var out: Array = []
	for r in rows_by:
		var rows: Array = rows_by[r]
		out.append([r.x, r.y, PackedByteArray() if rows.is_empty() else var_to_bytes(rows)])
	_dirty.clear()
	return out


## Write packed regions into `dir` (a worker may run this).
static func write_regions(dir: String, regions: Array) -> void:
	if regions.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for r in regions:
		var path := dir.path_join("r_%d_%d.farm" % [r[0], r[1]])
		var bytes: PackedByteArray = r[2]
		if bytes.is_empty():
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
			continue
		var f := FileAccess.open_compressed(path + ".tmp", FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if f == null:
			continue
		f.store_buffer(MAGIC.to_ascii_buffer())
		f.store_32(FORMAT)
		f.store_32(bytes.size())
		f.store_buffer(bytes)
		f.close()
		DirAccess.rename_absolute(path + ".tmp", path)


## Every region file in `dir`, replacing what is held. The number of plots.
func load_dir(dir: String) -> int:
	clear()
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	for name in d.get_files():
		if not name.ends_with(".farm"):
			continue
		var f := FileAccess.open_compressed(dir.path_join(name), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		if f == null:
			continue
		var magic := f.get_buffer(4).get_string_from_ascii()
		var fmt := f.get_32()
		if magic != MAGIC or fmt != FORMAT:
			push_warning("[farm] %s: not a farm region (format %d)" % [name, fmt])
			continue
		var n := f.get_32()
		var rows = bytes_to_var(f.get_buffer(n))
		if not (rows is Array):
			continue
		for row in rows:
			if row is Array:
				var plot := FarmPlant.from_row(row)
				if not plot.is_empty():
					plots[plot.b] = plot
	version += 1
	return plots.size()


## Remove every farm file in `dir` (a world's changes forgotten).
static func remove_dir_files(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for name in d.get_files():
		if name.ends_with(".farm"):
			DirAccess.remove_absolute(dir.path_join(name))
