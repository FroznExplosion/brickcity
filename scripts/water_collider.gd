class_name WaterCollider
extends Node3D

## Something for a floating object to REST ON.
## [Docs/Water.md](../Docs/Water.md) §7.1, option B.
##
## Buoyancy as a force (option A) is right for the player and costs nothing:
## `BrickWave.sample_heights` answers where the surface is and the swimmer
## follows it. It is wrong for a barrel, because a force pushes and a barrel
## wants to SIT — on a crest, tilted, staying there.
##
## So the surface near the player also exists as collision: a patch of boxes
## whose tops are moved to the wave every physics-ish tick. Nothing is
## created or destroyed after setup, the shapes are shared, and the patch
## follows whoever it was given.
##
## It is deliberately SMALL. Water is not a body (§7) and this does not make
## it one; it is a few square metres of standable sea around the thing that
## needs it, which is all that a barrel, a boat or a dropped brick can touch.

## Cells a side. 9 is 12.6 m at four studs a cell.
@export var cells := 9
## Studs a cell. Four is 1.4 m — a barrel is smaller than that, so it never
## straddles more than two.
@export var cell_studs := 4
## How deep each box goes. Only the top matters; the depth is there so a
## fast body cannot tunnel through in one step.
@export var thickness := 2.0
## How often the patch is re-fitted, in seconds. The surface moves slowly
## and a resting body does not need the truth at 60 Hz.
@export var refit_hz := 20.0

var _body := RID()
var _shape := RID()
var _next_refit := 0.0
var _centre := Vector2.ZERO


func setup(space: RID) -> void:
	var stud := BrickWorld.get_stud_metres()
	var w := float(cell_studs) * stud
	# ONE shape, shared by every cell: they are all the same box, and only
	# their transforms differ.
	_shape = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(_shape, Vector3(w, thickness, w) * 0.5)

	_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(_body, space)
	PhysicsServer3D.body_set_collision_layer(_body, Layers.WORLD)
	PhysicsServer3D.body_set_collision_mask(_body, Layers.STRUCTURE_MASK)
	for i in cells * cells:
		PhysicsServer3D.body_add_shape(_body, _shape, Transform3D())


## Put the patch under `centre_xz` and fit it to the wave at `time`.
func follow(centre_xz: Vector2, time: float, delta: float) -> void:
	if not _body.is_valid():
		return
	_next_refit -= delta
	var stud := BrickWorld.get_stud_metres()
	var w := float(cell_studs) * stud
	# Snapped to the cell lattice, so the boxes do not crawl with the
	# camera — the same reason the water grid snaps (§3.4).
	var at := Vector2(round(centre_xz.x / w) * w, round(centre_xz.y / w) * w)
	if _next_refit > 0.0 and at == _centre:
		return
	_next_refit = 1.0 / maxf(refit_hz, 1.0)
	_centre = at

	var half := float(cells) * 0.5 - 0.5
	for i in cells * cells:
		@warning_ignore("integer_division")
		var cz := i / cells
		var cx := i % cells
		var x := at.x + (float(cx) - half) * w
		var z := at.y + (float(cz) - half) * w
		# The CONTINUOUS surface, because that is what the shader draws
		# (Water §2.2). If the water is switched back to brick steps, this
		# follows, because both read the one wave function.
		var y: float = BrickWave.height_at(x, z, time)
		PhysicsServer3D.body_set_shape_transform(_body, i,
			Transform3D(Basis(), Vector3(x, y - thickness * 0.5, z)))


func _exit_tree() -> void:
	if _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		_body = RID()
	if _shape.is_valid():
		PhysicsServer3D.free_rid(_shape)
		_shape = RID()
