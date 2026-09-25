class_name MaterialFx
extends Node3D

## What materials DO in the world: the mark a hit leaves, what flies off, what
## it sounds like, and footsteps. The data is BrickMaterials; this plays it.
##
## One call for anything that hits a brick -- the city's blast today, a gun when
## the weapons land (Docs/Reference/boomer-border.md, "guns must also hurt
## bricks"):
##
##     fx.impact(point, normal, material, brick_colour)
##
## and `material_at(point)` to find out what is there. Footsteps run by
## themselves once `walker` is set to something with a `body()`: every stride
## on the floor plays the step of whatever is under it.

## Marks are recycled oldest first past this many.
const MAX_MARKS := 96
## How big a hit's mark is, in metres: a stud's width -- a 9 mm round at the
## game's scale would be forty centimetres across, which reads as a crater.
const MARK_SIZE := 0.24
## A stride, in metres of the walker's horizontal travel.
const STRIDE := 0.62

var world: BrickWorld
var registry: BuildingRegistry
## Anything with body() -> CharacterBody3D and is_walking() -> bool, i.e.
## DebugCamera. Null: no footsteps.
var walker: Node = null

var _marks: Array[Decal] = []
var _players: Array[AudioStreamPlayer3D] = []
var _next_player := 0
var _stride_left := STRIDE
var _last_foot := Vector3.INF
var _step_variant := 0


func setup(brick_world: BrickWorld, building_registry: BuildingRegistry, who_walks: Node = null) -> void:
	world = brick_world
	registry = building_registry
	walker = who_walks
	for i in 8:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 6.0
		p.max_distance = 60.0
		add_child(p)
		_players.append(p)


# ---------------------------------------------------------------------------
# Hits
# ---------------------------------------------------------------------------

## Something struck a brick of `material` at `point`, on a face whose outward
## normal is `normal`. Leaves the mark, throws the debris, plays the sound.
func impact(point: Vector3, normal: Vector3, material: int, brick_colour: Color = Color.WHITE) -> void:
	var fam := BrickMaterials.family(material)
	_mark(point, normal, fam)
	_debris(point, normal, fam, brick_colour)
	_play(BrickMaterials.hit_sound(fam, randi() % 3), point, randf_range(0.9, 1.1))


func _mark(point: Vector3, normal: Vector3, fam: String) -> void:
	var d: Decal
	if _marks.size() >= MAX_MARKS:
		d = _marks.pop_front()
	else:
		d = Decal.new()
		d.cull_mask = 1
		add_child(d)
	d.texture_albedo = BrickMaterials.hole_texture(fam)
	d.size = Vector3(MARK_SIZE, 0.2, MARK_SIZE)
	d.upper_fade = 0.2
	d.lower_fade = 0.2
	# A decal projects down its own -Y, so its Y is the face's outward normal,
	# and it is spun about that by chance so no two marks line up.
	var n := normal.normalized() if normal.length() > 0.1 else Vector3.UP
	var side := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var fwd := side.cross(n).normalized()
	var frame := Basis(side, n, fwd).rotated(n, randf() * TAU)
	if d.is_inside_tree():
		d.global_transform = Transform3D(frame, point)
	else:
		d.transform = Transform3D(frame, point)
	_marks.append(d)


func _debris(point: Vector3, normal: Vector3, fam: String, brick_colour: Color) -> void:
	if not is_inside_tree():
		return
	var spec := BrickMaterials.debris(fam, brick_colour)
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = int(spec.count)
	p.lifetime = float(spec.life)
	p.explosiveness = 1.0
	p.direction = normal
	p.spread = 45.0
	p.initial_velocity_min = float(spec.speed) * 0.5
	p.initial_velocity_max = float(spec.speed)
	p.gravity = Vector3(0, -float(spec.gravity), 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var mesh := BoxMesh.new()
	var s := float(spec.size)
	mesh.size = Vector3(s, s, s)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = spec.colour
	if spec.glow:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission = spec.colour
		mat.emission_energy_multiplier = 3.0
	mesh.material = mat
	p.mesh = mesh
	add_child(p)
	p.global_position = point + normal * 0.02
	p.emitting = true
	# One shot, then gone: finished is emitted when the last particle dies.
	p.finished.connect(p.queue_free)


func _play(stream: AudioStream, at: Vector3, pitch: float, volume_db: float = 0.0) -> void:
	if _players.is_empty() or not is_inside_tree():
		return
	var p := _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	p.stream = stream
	p.global_position = at
	p.pitch_scale = pitch
	p.volume_db = volume_db
	p.play()


# ---------------------------------------------------------------------------
# What is where
# ---------------------------------------------------------------------------

## The brick at a world point, as {material, colour} (colour as drawn), or {}
## where there is none this can see: a building with real bricks is asked cell
## by cell; a player build still on its cheap tier is asked through its
## recipe; a generated tower is PLA all through.
func brick_at(point: Vector3) -> Dictionary:
	if registry == null:
		return {}
	var cell := BrickWorld.get_cell_size()
	for b in registry.buildings:
		var box := CityPlacer.box_of(b)
		if not box.grow(0.05).has_point(point):
			continue
		if b.is_materialised():
			for f in b.chunks():
				var local: Vector3 = world.get_chunk_transform(f).affine_inverse() * point
				var c := Vector3i(floori(local.x / cell.x), floori(local.y / cell.y), floori(local.z / cell.z))
				var bid := world.block_at(f, c)
				if bid >= 0:
					var m := world.get_block_material(f, bid)
					return {"material": m,
							"colour": BrickWorld.get_material_colour(m, world.get_block_colour(f, bid))}
		elif b.is_build():
			var r: BuildRecipe = b.build
			var local: Vector3 = b.xform.affine_inverse() * point
			var c := Vector3i(floori(local.x / cell.x), floori(local.y / cell.y), floori(local.z / cell.z)) + r.origin()
			for i in r.size():
				if r.frame_of(i) != 0:
					continue
				var at := r.cell_of(i)
				var sz := BrickPalette.size_of(r.part_of(i))
				if c.x >= at.x and c.y >= at.y and c.z >= at.z 						and c.x < at.x + sz.x and c.y < at.y + sz.y and c.z < at.z + sz.z:
					var m := r.material_of(i)
					return {"material": m, "colour": BrickWorld.get_material_colour(m, r.colour_of(i))}
		return {"material": 0, "colour": BrickWorld.get_material_colour(0, 2)}
	return {}


## Just the material, -1 where there is no brick.
func material_at(point: Vector3) -> int:
	var b := brick_at(point)
	return int(b.material) if not b.is_empty() else -1


## A hit at `point` on a face with outward `normal`: finds what is there (just
## inside the face) and plays its impact. What a gun calls. False if there is
## no brick to hit.
func impact_at(point: Vector3, normal: Vector3) -> bool:
	var b := brick_at(point - normal.normalized() * 0.03)
	if b.is_empty():
		return false
	var col: Color = b.colour
	col.a = 1.0
	impact(point, normal, int(b.material), col)
	return true


# ---------------------------------------------------------------------------
# Footsteps
# ---------------------------------------------------------------------------

func _physics_process(_dt: float) -> void:
	if walker == null or not walker.has_method("body") or not walker.call("is_walking"):
		_last_foot = Vector3.INF
		return
	var body: CharacterBody3D = walker.call("body")
	if body == null or not body.is_on_floor():
		return
	var foot := body.global_position
	if _last_foot != Vector3.INF:
		_stride_left -= Vector2(foot.x - _last_foot.x, foot.z - _last_foot.z).length()
	_last_foot = foot
	if _stride_left > 0.0:
		return
	_stride_left = STRIDE
	step_at(foot)


## One footstep at the feet `foot`: what is just under them decides the sound.
## Public for the probe.
func step_at(foot: Vector3) -> String:
	var under := material_at(foot - Vector3(0, 0.07, 0))
	var fam := BrickMaterials.family(maxi(under, 0))
	_step_variant += 1
	_play(BrickMaterials.step_sound(fam, _step_variant), foot, randf_range(0.92, 1.08), -6.0)
	return fam
