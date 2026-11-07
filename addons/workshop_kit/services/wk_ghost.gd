class_name WkGhost
extends RefCounted

## The preview of what a click would make (workshop_kit): a see-through node the editor gives a
## mesh and a place, tinted for "fits" and "does not fit". The mesh is always the editor's.
##
##     var ghost := WkGhost.new()
##     add_child(ghost.node)
##     ghost.place(my_mesh, xf)
##     ghost.fits(ok)

const FITS := Color(0.4, 0.9, 1.0, 0.45)
const DOES_NOT_FIT := Color(1.0, 0.25, 0.22, 0.45)

var node: MeshInstance3D
var material: StandardMaterial3D


func _init() -> void:
	material = StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = FITS
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	node = MeshInstance3D.new()
	node.name = "Ghost"
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func tint(c: Color) -> void:
	material.albedo_color = c


## The fits / does-not-fit colours.
func fits(ok: bool) -> void:
	tint(FITS if ok else DOES_NOT_FIT)


func place(mesh: Mesh, xf: Transform3D) -> void:
	node.mesh = mesh
	node.transform = xf


func show(on: bool) -> void:
	node.visible = on
