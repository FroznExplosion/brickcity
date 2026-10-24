class_name FurnishTool
extends Node3D

## Furnishing a build in the workshop: pick a piece of furniture or an item
## from the catalogue and place it the way a brick is placed.
## Docs/AssetWorkshop.md, "Furniture and items".
##
##   F6       open or close the catalogue (AssetCatalogPanel).
##   pick     a piece in the list goes in hand as a ghost on the stud under the
##            cursor: on top of the bricks there, or of furniture already
##            placed (a cup on a table), centred on that stud.
##   R        turn it a quarter.  LMB place it (it stays in hand).
##   RMB      take away the placed piece under the cursor.
##   Esc      put it down; again closes the catalogue.
##
## What is placed is a PLACEMENT in the recipe (`recipe.placements`, asset +
## cell + turn), never its bricks: they are drawn here from the asset's own
## file and laid when the build goes into the city (AssetPlacements.expand).
## Placements are kept out of the workshop's chunk on purpose -- block id there
## is recipe index, and a chair's bricks in it would renumber the build.

var ws    ## the Workshop
var panel: AssetCatalogPanel
var held := ""         ## catalogue id in hand, "" for none
var turn := 0
var at := Vector3i.ZERO   ## where the held piece's min corner would go
var ok := false
var has_target := false

var _layer: CanvasLayer
var _hud: Label
var _ghost: Node3D
var _ghost_material: StandardMaterial3D
var _drawn: Node3D
var _undo := []        ## ["add"] or ["remove", index, record]


func setup(workshop) -> void:
	ws = workshop
	_drawn = Node3D.new()
	_drawn.name = "Placements"
	add_child(_drawn)
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.no_depth_test = false
	_layer = CanvasLayer.new()
	_layer.layer = 5
	_layer.visible = false
	add_child(_layer)
	panel = AssetCatalogPanel.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -400
	panel.offset_right = -12
	panel.offset_top = 44
	panel.picked.connect(hold)
	_layer.add_child(panel)
	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hud.offset_top = -150
	_hud.offset_left = -360
	_hud.offset_right = 360
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	_layer.add_child(_hud)
	redraw()


func is_open() -> bool:
	return _layer.visible


func open(on: bool) -> void:
	_layer.visible = on
	if on:
		panel.reload()
		if ws._camera.has_method("_set_captured"):
			ws._camera.call("_set_captured", false)   # the list needs the cursor
	else:
		put_down()
	print("[furnish] catalogue %s" % ("open" if on else "closed"))


## Take a catalogue piece in hand.
func hold(id: String) -> void:
	if AssetCatalog.entry(id).is_empty():
		return
	held = id
	turn = 0
	_make_ghost()


func put_down() -> void:
	held = ""
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null


func _make_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
	_ghost = AssetPlacements.node_for(held, turn, _ghost_material, _ghost_material, true)
	add_child(_ghost)


func turn_held() -> void:
	if held == "":
		return
	turn = (turn + 1) % 4
	_make_ghost()


## Every frame while a piece is in hand.
func process() -> void:
	if held == "":
		_hud.text = "FURNISH   pick a piece from the list   RMB take one away   F6 close"
		return
	var ray: Array = ws._mouse_ray()
	aim_ray(ray[0], ray[1])
	var e := AssetCatalog.entry(held)
	_hud.text = "PLACING %s   %s\nLMB place   R turn   RMB take one away   Esc put down   F6 close" % [
			e.get("name", held), "fits" if ok else ("BLOCKED" if has_target else "aim at the build")]


# ---------------------------------------------------------------------------
# Aiming
# ---------------------------------------------------------------------------

## Where the held piece would go for one ray: centred on the stud hit, on top
## of the bricks in that column or of the placed piece hit. Public for probes.
func aim_ray(from: Vector3, dir: Vector3) -> void:
	has_target = false
	ok = false
	var size := AssetPlacements.size_of(held, turn)
	var target := Vector3i.ZERO
	var best_t := INF
	var hit: Dictionary = ws._first_hit(from, dir)
	if not hit.is_empty() and int(hit.frame) == ws.chunk:
		var c: Vector3i = ws._cell_in(ws.chunk, hit.point)
		var y := c.y
		while y < c.y + 400 and ws.world.is_solid(ws.chunk, Vector3i(c.x, y, c.z)):
			y += 1
		target = Vector3i(c.x, y, c.z)
		best_t = float(hit.t)
	var p := _placement_ray(from, dir)
	if not p.is_empty() and float(p.t) < best_t:
		target = p.top
		best_t = float(p.t)
	if best_t == INF:
		if _ghost != null:
			_ghost.visible = false
		return
	has_target = true
	@warning_ignore("integer_division")
	at = Vector3i(target.x - (size.x - 1) / 2, target.y, target.z - (size.z - 1) / 2)
	ok = fits(held, turn, at)
	if _ghost != null:
		_ghost.visible = true
		_ghost.transform = _xform(at)
		_ghost_material.albedo_color = Color(0.35, 0.9, 1.0, 0.45) if ok else Color(1.0, 0.25, 0.22, 0.5)


## Does `asset` turned `t` fit with its min corner at `c`: no brick of the
## build and no placed piece in any cell it fills, nothing below the plate.
func fits(asset: String, t: int, c: Vector3i, skip := -1) -> bool:
	if c.y < 0:
		return false
	var mine := AssetPlacements.cells_of(asset, t, c)
	if mine.is_empty():
		return false
	var taken := {}
	for i in ws.recipe.placements.size():
		if i == skip:
			continue
		var q: Dictionary = ws.recipe.placements[i]
		for cell in AssetPlacements.cells_of(str(q.asset), int(q.turn), AssetPlacements.cell_of(q)):
			taken[cell] = true
	for cell: Vector3i in mine:
		if taken.has(cell) or ws.world.is_solid(ws.chunk, cell):
			return false
	return true


## The placed piece nearest along a ray: {index, t, top} -- top is the cell
## over the middle of its top face where the ray met it -- or {}.
func _placement_ray(from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var inv: Transform3D = ws.world.get_chunk_transform(ws.chunk).affine_inverse()
	var lf: Vector3 = inv * from
	var ld: Vector3 = (inv.basis * dir).normalized()
	for i in ws.recipe.placements.size():
		var q: Dictionary = ws.recipe.placements[i]
		var c := AssetPlacements.cell_of(q)
		var s := AssetPlacements.size_of(str(q.asset), int(q.turn))
		var box := AABB(BrickWorld.grid_to_world(c), BrickWorld.grid_to_world(s))
		var hit = box.intersects_ray(lf, ld)
		if hit == null:
			continue
		var t: float = (hit as Vector3).distance_to(lf)
		if best.is_empty() or t < float(best.t):
			var on: Vector3 = hit
			var cs := BrickWorld.get_cell_size()
			var col := Vector3i(clampi(int(floor(on.x / cs.x)), c.x, c.x + s.x - 1), c.y + s.y,
					clampi(int(floor(on.z / cs.z)), c.z, c.z + s.z - 1))
			best = {"index": i, "t": t, "top": col}
	return best


func _xform(c: Vector3i) -> Transform3D:
	return ws.world.get_chunk_transform(ws.chunk) * Transform3D(Basis(), BrickWorld.grid_to_world(c))


# ---------------------------------------------------------------------------
# Edits: each one an undo step in the workshop's list ("furnish")
# ---------------------------------------------------------------------------

## Place the held piece where it is aimed. Returns whether it went in.
func place() -> bool:
	if held == "" or not has_target or not ok:
		return false
	ws.recipe.placements.append(AssetPlacements.make(held, at, turn))
	_undo.append(["add"])
	ws._edits.append("furnish")
	ws._after_edit()
	print("[furnish] placed '%s' at %v, turned %d" % [held, at, turn])
	return true


## Take away the placed piece under a ray. Returns whether one went.
func remove_ray(from: Vector3, dir: Vector3) -> bool:
	var p := _placement_ray(from, dir)
	if p.is_empty():
		return false
	var i := int(p.index)
	var rec: Dictionary = ws.recipe.placements[i]
	ws.recipe.placements.remove_at(i)
	_undo.append(["remove", i, rec])
	ws._edits.append("furnish")
	ws._after_edit()
	print("[furnish] took away '%s'" % rec.asset)
	return true


## The workshop's undo for a "furnish" step (it has popped the step).
func undo() -> void:
	if _undo.is_empty():
		return
	var u: Array = _undo.pop_back()
	if u[0] == "add":
		ws.recipe.placements.pop_back()
	else:
		ws.recipe.placements.insert(int(u[1]), u[2])


## Forget the undo steps (a new or loaded build).
func reset() -> void:
	_undo.clear()


## Draw every placement of the build, in the build's own material.
func redraw() -> void:
	for c in _drawn.get_children():
		c.queue_free()
	if ws == null or ws.recipe == null:
		return
	for q: Dictionary in ws.recipe.placements:
		var n := AssetPlacements.node_for(str(q.asset), int(q.turn), ws._material,
				ws._stud_material())
		n.transform = _xform(AssetPlacements.cell_of(q))
		_drawn.add_child(n)


## Keys and buttons while the catalogue is open. Returns true when used.
func input(e: InputEvent) -> bool:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F6:
		open(not is_open())
		return true
	if not is_open():
		return false
	if e is InputEventMouseButton and e.pressed:
		var ray: Array = ws._mouse_ray()
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				place()
				return true
			MOUSE_BUTTON_RIGHT:
				remove_ray(ray[0], ray[1])
				return true
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_R:
				turn_held()
				return true
			KEY_ESCAPE:
				if held != "":
					put_down()
				else:
					open(false)
				return true
	return false
