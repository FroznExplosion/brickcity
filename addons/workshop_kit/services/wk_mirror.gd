class_name WkMirror
extends RefCounted

## The mirror plane of an editor (workshop_kit): while it is on, what is made is made again
## on the other side. One plane at a time, upright: across X (`axis` 0, at `x`) or across Z
## (`axis` 2, at `z`), in cells -- a plane at 10.0 runs along the line between cells 9 and 10,
## at 10.5 through the middle of cell 10.
##
## The editor decides what "made again" means (a piece turned to face the other way, a shape
## reflected); this keeps the plane and does the cell arithmetic.

## On, off, moved or turned.
signal changed

var on := false:
	set(v):
		on = v
		changed.emit()
## 0: across X (the plane is x = `x`); 2: across Z (z = `z`).
var axis := 2:
	set(v):
		axis = 0 if v == 0 else 2
		changed.emit()
var x := 0.0:
	set(v):
		x = v
		changed.emit()
var z := 0.0:
	set(v):
		z = v
		changed.emit()


## Where the plane is on its own axis.
func plane() -> float:
	return x if axis == 0 else z


func set_plane(v: float) -> void:
	if axis == 0:
		x = v
	else:
		z = v


## Turn it on; a plane never set yet starts at `cell` (both axes).
func turn_on(cell: Vector3i) -> void:
	if z == 0.0:
		z = float(cell.z)
	if x == 0.0:
		x = float(cell.x)
	on = true


## The far side of a thing `width` cells wide whose first cell is `c`, across a plane at `at`:
## the first cell of its mirror image.
static func across(c: int, width: int, at: float) -> int:
	return int(round(2.0 * at - float(c + width)))


func mirrored_x(c: int, width: int) -> int:
	return across(c, width, x)


func mirrored_z(c: int, width: int) -> int:
	return across(c, width, z)


## The first cell of the mirror image of a thing of `size` cells at `cell`, across the plane
## in use. The same cell when it straddles the plane exactly (it is its own mirror image).
func mirror_cell(cell: Vector3i, size: Vector3i) -> Vector3i:
	var to := cell
	if axis == 0:
		to.x = mirrored_x(cell.x, size.x)
	else:
		to.z = mirrored_z(cell.z, size.z)
	return to


## A direction (a piece's front) as it looks across the plane: its part along the axis turned.
func mirror_dir(d: Vector3i) -> Vector3i:
	var out := d
	out[axis] = -d[axis]
	return out


## Put the plane through the middle of a thing of `size` cells at `cell`.
func through(cell: Vector3i, size: Vector3i) -> void:
	if axis == 0:
		x = cell.x + size.x * 0.5
	else:
		z = cell.z + size.z * 0.5
