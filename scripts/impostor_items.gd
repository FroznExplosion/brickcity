class_name ImpostorItems
extends Node3D

## Small things lying about -- guns, ammo, loot, props -- on the impostor
## ladder (Docs/Impostors.md 8.2): each KIND is one ImpostorLod, so a hundred
## rifles on a battlefield are two draw calls; up close the real mesh, then an
## octahedral card, then nothing.
##
## For the weapons and loot code to call. One node per scene:
##
##     items.kind("rifle", mesh, material)        # once per kind
##     var h := items.add("rifle", xform)         # one on the ground
##     items.move(h, new_xform)                   # it was kicked
##     items.remove(h)                            # picked up
##
## A held item is not in here: it is the player's, drawn by the player. The
## mesh can be anything; for a brick-built item, RecipeMesh.build(recipe).
##
## Small things get small ranges: real mesh inside NEAR, card to CULL, and
## the cards cast no shadow (a shadow a few pixels across is not worth a
## cascade's draw, section 7.2).

const NEAR := 12.0
const CULL := 150.0
## Frames between tier passes.
const UPDATE_EVERY := 6
## Pixels a view in the atlas: small things are small on screen.
const TILE := 64

var _kinds := {}          ## key -> ImpostorLod
var _where := {}          ## handle -> [key, local handle]
var _next := 0
var _frame := 0


func kind(key: String, mesh: Mesh, material: Material, near: float = NEAR,
		cull: float = CULL) -> ImpostorLod:
	if _kinds.has(key):
		return _kinds[key]
	var s := ImpostorLod.new()
	s.name = "Items_%s" % key
	add_child(s)
	s.setup(mesh, material, near, cull, false, TILE)
	_kinds[key] = s
	return s


func add(key: String, xf: Transform3D) -> int:
	var s: ImpostorLod = _kinds.get(key)
	if s == null:
		push_warning("[items] no kind '%s' -- call kind() first" % key)
		return -1
	var h := _next
	_next += 1
	_where[h] = [key, s.add(xf)]
	return h


func move(handle: int, xf: Transform3D) -> void:
	var w: Array = _where.get(handle, [])
	if not w.is_empty():
		(_kinds[w[0]] as ImpostorLod).move(w[1], xf)


func remove(handle: int) -> void:
	var w: Array = _where.get(handle, [])
	if w.is_empty():
		return
	(_kinds[w[0]] as ImpostorLod).remove(w[1])
	_where.erase(handle)


func tier_of(handle: int) -> int:
	var w: Array = _where.get(handle, [])
	return 0 if w.is_empty() else (_kinds[w[0]] as ImpostorLod).tier_of(w[1])


func _process(_delta: float) -> void:
	_frame += 1
	if _frame % UPDATE_EVERY != 0:
		return
	update()


func update() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var here := cam.global_position
	for s in _kinds.values():
		(s as ImpostorLod).update(here)
