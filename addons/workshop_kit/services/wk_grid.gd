class_name WkGrid
extends RefCounted

## The grid overlay (workshop_kit): faint lines over a window of cells on a plane, a stronger
## one every `major` cells -- an orientation cue, not something to read. Lines in the node's
## own XZ plane at height `y` (just above the plane, so it does not z-fight with what is on it);
## the editor places the node.

## The lines of the cells in `window` (x across, y along -- the plane's z), each `cell` metres.
static func lines(window: Rect2i, cell: float, major := 4, major_alpha := 0.13, minor_alpha := 0.04,
		y := 0.002) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var lo := window.position
	var hi := window.end
	for i in window.size.x + 1:
		var u := (lo.x + i) * cell
		var col := Color(1, 1, 1, major_alpha if posmod(lo.x + i, major) == 0 else minor_alpha)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(u, y, lo.y * cell))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(u, y, hi.y * cell))
	for i in window.size.y + 1:
		var v := (lo.y + i) * cell
		var col := Color(1, 1, 1, major_alpha if posmod(lo.y + i, major) == 0 else minor_alpha)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(lo.x * cell, y, v))
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(hi.x * cell, y, v))
	im.surface_end()
	return im
