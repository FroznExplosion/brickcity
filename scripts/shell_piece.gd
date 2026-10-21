class_name ShellPiece
extends RigidBody3D

## The intact storeys over one that gave way, leaving the building as ONE rigid
## body: drawn by their shell bands, held by their shell boxes, and no bricks
## (Docs/Space.md 5.2 and 5.3a). A storey of a building laid a storey at a time
## gives way when nothing is left under the storey on it; everything over it
## comes away as this. It becomes bricks -- all of it, ONE piece, every joint as
## it was -- when it lands hard where somebody could see it break, or is shot
## (CityScene._piece_to_bricks); the landing then breaks it where it touched,
## by the same rule as any brick piece (IslandManager.fracture_on_impact). Far
## from everyone it lands whole and stays a shell, as a brick piece would.
## Undamaged storeys are as stiff as LEGO: nothing comes away a floor at a time.
##
## Its frame is the building's -- the body's transform is where the building's
## cell (0, 0, 0) is now -- so a storey laid from the template lands in the
## right place with no offset to carry.

var building := -1
## Storeys [lo, hi) of the building.
var lo := 0
var hi := 0
## Storeys inside [lo, hi) that are not in it: laid as bricks when it broke off,
## they left as brick pieces of their own.
var holes := PackedInt32Array()
## The building's damage record when it broke off, for laying a storey of it
## later: the blocks of its storeys were absent then, and their record was in
## the building's chunk (BrickWorld.create_band_chunk).
var record := {}
## A hard landing seen, waiting for CityScene to act on, and the speed it lost
## -- a brick piece's landing rule (IslandManager: IMPACT_DELTA after a fall of
## IMPACT_FALL_TICKS at IMPACT_MIN_SPEED or more).
var landed_hard := false
var landed_speed := 0.0
var made_at := 0

var _mesh: MeshInstance3D
var _prev_speed := 0.0
var _fall_ticks := 0


## Build the body for storeys [lo, hi): mesh, boxes, mass. Called again when a
## storey of it becomes bricks and it is left with fewer.
func shape(registry: BuildingRegistry, material: Material) -> bool:
	var b := registry.get_building(building)
	if b == null or hi <= lo:
		return false
	var profile := piece_profile(registry)
	for c in get_children():
		if c is CollisionShape3D:
			remove_child(c)
			c.queue_free()
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.material_override = material
		add_child(_mesh)
	var fx: int = b.recipe.footprint_x
	var fz: int = b.recipe.footprint_z
	var courses: int = b.recipe.courses
	_mesh.mesh = BuildingShell.build_mesh(fx, fz, courses, profile)
	var boxes: Array = BuildingShell.collision_boxes(fx, fz, courses, false, profile)
	var lines := registry.storey_lines(b)
	var plate := BrickWorld.get_plate_metres()
	var y_lo: float = lines[lo] * plate
	var any := false
	var bounds := AABB()
	for box in boxes:
		var pos: Vector3 = box.pos
		var size: Vector3 = box.size
		# collision_boxes always lays a ground plate at y = 0: the building's,
		# not this piece's.
		if pos.y + size.y * 0.5 < y_lo + 0.01:
			continue
		var cs := CollisionShape3D.new()
		var shape3 := BoxShape3D.new()
		shape3.size = size
		cs.shape = shape3
		cs.position = pos
		add_child(cs)
		var bb := AABB(pos - size * 0.5, size)
		bounds = bb if not any else bounds.merge(bb)
		any = true
	if not any:
		return false
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = bounds.get_center()
	var kg := registry.world.get_template_mass(b.band_template if b.band_template >= 0
			else -1, lines[lo], lines[hi])
	mass = maxf(kg * IslandManager.MASS_SCALE, 1.0)
	return true


## What its shell draws: its own storeys as the building's profile had them,
## everything else gone.
func piece_profile(registry: BuildingRegistry) -> Dictionary:
	var b := registry.get_building(building)
	var out := {}
	var i := 0
	for band in TowerRecipe.layout(b.recipe.courses):
		@warning_ignore("integer_division")
		var s := int(band.y) / TowerRecipe.STOREY_PLATES
		if s < lo or s >= hi or holes.has(s):
			out[i] = PackedInt32Array([0, 0, 0, 0])
		elif b.damage_profile.has(i):
			out[i] = b.damage_profile[i]
		i += 1
	return out


## The storeys a point (world) at `radius` reaches, inside this piece.
func storeys_at(registry: BuildingRegistry, point: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var b := registry.get_building(building)
	var lines := registry.storey_lines(b)
	var local := global_transform.affine_inverse() * point
	var plate := BrickWorld.get_plate_metres()
	var y0 := floori((local.y - radius) / plate)
	var y1 := floori((local.y + radius) / plate)
	for s in range(lo, hi):
		if holes.has(s):
			continue
		if lines[s + 1] > y0 and lines[s] <= y1:
			out.append(s)
	return out


## Is a world point within `margin` of it?
func reaches(registry: BuildingRegistry, point: Vector3, margin: float) -> bool:
	var b := registry.get_building(building)
	if b == null:
		return false
	var lines := registry.storey_lines(b)
	var plate := BrickWorld.get_plate_metres()
	var box := BuildingRegistry.own_box(b)
	box.position.y = lines[lo] * plate
	box.size.y = (lines[hi] - lines[lo]) * plate
	return box.grow(margin).has_point(global_transform.affine_inverse() * point)


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 4
	gravity_scale = IslandManager.DEBRIS_GRAVITY
	collision_layer = Layers.FALLING
	collision_mask = Layers.FALLING_MASK
	made_at = Time.get_ticks_msec()


func _physics_process(_delta: float) -> void:
	var speed := linear_velocity.length()
	var lost := _prev_speed - speed
	var fell := _fall_ticks
	_fall_ticks = _fall_ticks + 1 if speed > IslandManager.IMPACT_MIN_SPEED else 0
	if lost > IslandManager.IMPACT_DELTA and _prev_speed > IslandManager.IMPACT_MIN_SPEED \
			and fell >= IslandManager.IMPACT_FALL_TICKS:
		landed_hard = true
		landed_speed = maxf(landed_speed, lost)
	_prev_speed = speed
