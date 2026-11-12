class_name RenderLayers
## Changing what render layers a mesh is on, safely while lights are about.
##
## Godot 4.6 pairs a mesh with each light whose cull mask shares one of its
## layers, and unpairs them by the same test against the mesh's layers AT THE
## TIME. Change a lit mesh's layers to ones the light does not share (0, to
## hide it) and the pair is never undone: freeing the light then logs "BUG,
## indexing did not unpair geometries from light", and quitting crashes
## (signal 11) on the stale pair (Docs/Lighting.md 6.5). Hiding the instance
## first unpairs it under its old layers; shown again, it pairs under the new.


static func set_layers(node: VisualInstance3D, mask: int) -> void:
	if node.layers == mask:
		return
	var shown := node.visible
	if shown and node.is_inside_tree():
		node.visible = false
		node.layers = mask
		node.visible = true
	else:
		node.layers = mask
