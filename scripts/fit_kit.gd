class_name FitKit

## The catalogue pieces Convert fits to a sculpted surface (Docs/AssetWorkshop.md,
## "SDF tools, round 3"), as `SdfForm.fit_pieces` takes them: each orientation's shape
## sampled at the field's own samples (5 x 2 x 5 a cell), and the way its open side faces.
##
## The shape is ShapedParts' (the same prisms the game draws and the print kit welds),
## turned as BrickWorld turns a part (Orient in brick_world.cpp: a quarter turn about +Y
## `yaw` times, then a flip of 180 degrees about X), so a fitted piece is the piece laid.

const PER := Vector3i(5, 2, 5)   # field samples a cell: a stud across, a plate up

## Slopes, wedges and cheese at curve level 1; curves too from 2.
const SLOPES := ["slope_1x2", "slope_2x2", "slope_2x4", "slope_1x3", "slope_2x3", "cheese_1x1",
		"cheese_1x2", "cheese_2x2", "wedgeplate_2x2", "wedgeplate_2x4", "wedge_2x2", "wedge_2x4"]
const CURVES := ["curve_1x2", "curve_2x2", "curve_1x3", "curve_1x4", "curve_2x4"]

static var _kits := {}


## {names: [archetype name], pieces: [{grid, size, normal}]}, built once each way.
static func kit(curves: bool) -> Dictionary:
	if _kits.has(curves):
		return _kits[curves]
	var names := []
	var pieces := []
	for part in SLOPES + (CURVES if curves else []):
		var spec: Dictionary = BrickPalette._SHAPED[part]
		var size := BrickPalette.part_size(part)
		var base := canonical(String(spec.kind), size, String(spec.get("axis", "z")))
		for name in BrickPalette.variants_of(part):
			var o := BrickPalette.orientation_of(name)
			var grid := turned(base, size * PER, o.x, o.y != 0)
			var n := open_side(grid, BrickPalette.size_of(name) * PER)
			if n == Vector3.ZERO:
				continue
			names.append(name)
			pieces.append({"grid": grid, "size": BrickPalette.size_of(name), "normal": n})
	_kits[curves] = {"names": names, "pieces": pieces}
	return _kits[curves]


## A part in its canonical orientation, a byte a field sample (1: solid), x fastest.
static func canonical(kind: String, size: Vector3i, axis: String) -> PackedByteArray:
	var prisms: Array = ShapedParts._shape(kind, size, axis).pieces
	var d := size * PER
	var out := PackedByteArray()
	out.resize(d.x * d.y * d.z)
	var step := Vector3(ShapedParts.S / PER.x, ShapedParts.P / PER.y, ShapedParts.S / PER.z)
	var i := 0
	for z in d.z:
		for y in d.y:
			for x in d.x:
				var p := (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) * step
				for pr in prisms:
					if ShapedParts._prism_has(pr, p):
						out[i] = 1
						break
				i += 1
	return out


## The samples of a canonical part (`d` samples each way) turned `yaw` quarters about +Y
## and flipped: Orient::cell, sample by sample.
static func turned(src: PackedByteArray, d: Vector3i, yaw: int, flip: bool) -> PackedByteArray:
	var od := Vector3i(d.z, d.y, d.x) if yaw % 2 == 1 else d
	var out := PackedByteArray()
	out.resize(src.size())
	var i := 0
	for z in d.z:
		for y in d.y:
			for x in d.x:
				var ax := x
				var az := z
				match yaw:
					1:
						ax = d.z - 1 - z
						az = x
					2:
						ax = d.x - 1 - x
						az = d.z - 1 - z
					3:
						ax = z
						az = d.x - 1 - x
				var oy := y
				if flip:
					oy = od.y - 1 - oy
					az = od.z - 1 - az
				out[ax + od.x * (oy + od.y * az)] = src[i]
				i += 1
	return out


## Which way a piece's open side faces: from the middle of its solid samples toward the
## middle of its empty ones (in samples, which are the same size every way). ZERO for a
## piece as empty on every side as on another.
static func open_side(grid: PackedByteArray, d: Vector3i) -> Vector3:
	var solid := Vector3.ZERO
	var empty := Vector3.ZERO
	var ns := 0
	var ne := 0
	var i := 0
	for z in d.z:
		for y in d.y:
			for x in d.x:
				if grid[i] != 0:
					solid += Vector3(x, y, z)
					ns += 1
				else:
					empty += Vector3(x, y, z)
					ne += 1
				i += 1
	if ns == 0 or ne == 0:
		return Vector3.ZERO
	var v := empty / ne - solid / ns
	return v.normalized() if v.length() > 0.05 else Vector3.ZERO
