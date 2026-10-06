class_name DebugView

## Seeing exactly what is spawned (user, 2026-10-06): three switches over what
## the city draws, none of which changes what is THERE.
##
##   STRUCTURE   bricks -- buildings, their shells and far boxes, falling and
##               settled pieces, crumbs: shown, see-through, or hidden
##   INTERIOR    interior pieces -- whatever rung or storey group draws them,
##               the furniture of a room laid as bricks, what rides a falling
##               section: shown or hidden
##   ITEMS       the small things -- a storey group's item drawing, loot:
##               shown or hidden
##
## Only the drawing is touched. A hidden thing keeps its node, its blocks and
## its collision, still casts its shadow, and is still worked out and streamed
## exactly as it was; a bullet stops on a wall nobody can see. That is the
## point: hide the walls and what stands in the rooms is what is spawned there,
## hide that and what is left is the items.
##
## HOW. Hidden is a render layer the game's camera is told not to draw
## (HIDDEN_LAYER), not `visible = false`: the game switches `visible` itself
## for reasons of its own (stand-ins, holds, fades) and the two would fight.
## See-through is the instance's own `transparency`, which every brick shader
## takes because none of them writes ALPHA. A far box and an impostor card cut
## their own alpha, so they stay solid when the structure is see-through, and
## go when it is hidden.
##
## Nothing here runs while all three are shown: what a thing was drawn with is
## kept on it (metas) only while this has changed it, and put back.
##
## WHAT IS WHAT. Interior pieces and items say so when they are made
## (`tag`, from FurnitureMesh and InteriorGroups). Structure is whatever else
## draws under the nodes the scene names as its bricks (CityScene._view_sweep).

enum Kind { STRUCTURE, INTERIOR, ITEMS }
enum Mode { SHOWN, CLEAR, HIDDEN }

const GROUP_INTERIOR := &"view_interior"
const GROUP_ITEMS := &"view_items"
## Every node this has changed, so all of them can be put back even if the
## scene no longer names them.
const GROUP_TOUCHED := &"view_touched"
## Render layer 20. Nothing else in the project uses render layers past 1.
const HIDDEN_LAYER := 1 << 19
## How much of a see-through brick is not there.
const CLEAR := 0.75

const KIND_NAMES := ["structure", "interior pieces", "items"]
const MODE_NAMES := ["shown", "see-through", "hidden"]

static var modes: Array[int] = [Mode.SHOWN, Mode.SHOWN, Mode.SHOWN]
## Per kind, from the last sweep: [nodes drawing something, boxes or meshes].
static var seen := [[0, 0], [0, 0], [0, 0]]


static func reset() -> void:
	modes = [Mode.SHOWN, Mode.SHOWN, Mode.SHOWN]


static func active() -> bool:
	return modes[0] != Mode.SHOWN or modes[1] != Mode.SHOWN or modes[2] != Mode.SHOWN


static func any_hidden() -> bool:
	return modes[0] == Mode.HIDDEN or modes[1] == Mode.HIDDEN or modes[2] == Mode.HIDDEN


## The next state of one switch: structure goes round all three, the others
## are on or off.
static func cycle(kind: int) -> int:
	if kind == Kind.STRUCTURE:
		modes[kind] = (modes[kind] + 1) % 3
	else:
		modes[kind] = Mode.HIDDEN if modes[kind] == Mode.SHOWN else Mode.SHOWN
	return modes[kind]


## Say what a node draws, as it is made. It takes the current view at once, so
## a room drawn while interiors are hidden never shows for a frame.
static func tag(node: GeometryInstance3D, kind: int) -> void:
	if node == null:
		return
	if node.is_in_group(GROUP_INTERIOR):
		node.remove_from_group(GROUP_INTERIOR)
	if node.is_in_group(GROUP_ITEMS):
		node.remove_from_group(GROUP_ITEMS)
	if kind == Kind.INTERIOR:
		node.add_to_group(GROUP_INTERIOR)
	elif kind == Kind.ITEMS:
		node.add_to_group(GROUP_ITEMS)
	if active():
		apply(node, kind)


static func kind_of(node: Node, otherwise: int = Kind.STRUCTURE) -> int:
	if node.is_in_group(GROUP_INTERIOR):
		return Kind.INTERIOR
	if node.is_in_group(GROUP_ITEMS):
		return Kind.ITEMS
	return otherwise


## Make one node's drawing match the view for its kind.
static func apply(node: GeometryInstance3D, kind: int) -> void:
	var mode: int = modes[kind]
	if mode == Mode.HIDDEN:
		if node.layers != HIDDEN_LAYER:
			node.set_meta(&"view_layers", node.layers)
			node.layers = HIDDEN_LAYER
			node.add_to_group(GROUP_TOUCHED)
	elif node.layers == HIDDEN_LAYER:
		node.layers = int(node.get_meta(&"view_layers", 1))
		node.remove_meta(&"view_layers")
	if mode == Mode.CLEAR:
		if not node.has_meta(&"view_alpha"):
			node.set_meta(&"view_alpha", node.transparency)
			node.add_to_group(GROUP_TOUCHED)
		node.transparency = CLEAR
	elif node.has_meta(&"view_alpha"):
		node.transparency = float(node.get_meta(&"view_alpha"))
		node.remove_meta(&"view_alpha")
	if mode == Mode.SHOWN and node.is_in_group(GROUP_TOUCHED):
		node.remove_from_group(GROUP_TOUCHED)


## Every drawing under `root`, each by its own kind (`otherwise` for what is
## not tagged, and for what hangs under something of a kind: a glass pane
## under a shell is structure, a detail under an item is an item).
static func apply_tree(root: Node, otherwise: int = Kind.STRUCTURE) -> void:
	if root == null or not is_instance_valid(root):
		return
	var stack: Array = [root, otherwise]
	while not stack.is_empty():
		var under: int = stack.pop_back()
		var node: Node = stack.pop_back()
		var kind := kind_of(node, under)
		if node is GeometryInstance3D:
			apply(node as GeometryInstance3D, kind)
			_count(node as GeometryInstance3D, kind)
		for child in node.get_children():
			stack.push_back(child)
			stack.push_back(kind)


static func _count(node: GeometryInstance3D, kind: int) -> void:
	var n := 0
	if node is MultiMeshInstance3D:
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm != null:
			n = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
	elif node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		n = 1
	if n > 0 and node.is_visible_in_tree():
		seen[kind][0] += 1
		seen[kind][1] += n


## Put back everything this has changed, wherever it is now. For when all
## three are shown again -- and nothing is left to do after it.
static func restore(tree: SceneTree) -> void:
	for node in tree.get_nodes_in_group(GROUP_TOUCHED):
		if node is GeometryInstance3D:
			apply(node as GeometryInstance3D, kind_of(node))
		node.remove_from_group(GROUP_TOUCHED)


## Tell a camera whether to draw the hidden layer: not while anything is
## hidden, and as it was otherwise.
static func aim(camera: Camera3D) -> void:
	if camera == null:
		return
	if any_hidden():
		camera.cull_mask &= ~HIDDEN_LAYER
	else:
		camera.cull_mask |= HIDDEN_LAYER


static func line() -> String:
	var parts := []
	for k in 3:
		parts.append("%s %s" % [KIND_NAMES[k], MODE_NAMES[modes[k]].to_upper()
				if modes[k] != Mode.SHOWN else MODE_NAMES[modes[k]]])
	return " · ".join(parts)
