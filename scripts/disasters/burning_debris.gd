class_name BurningDebris
extends Node3D

## Burning debris (Docs/Disasters.md 15). A piece that breaks off a burning
## building takes the fire with it: flames ride the piece as it falls, and
## where it comes to rest it sets alight whatever there is to burn -- a
## neighbour's wall, a floor below. What it leaves in the street burns out.
##
## Checked every CHECK_S: any MOVING piece within CATCH_REACH of a burning
## cell catches, up to MAX_BURNING at once. A piece burns for BURN_S. When it
## settles it lights the cell it lies in (FireSpread.ignite, which does nothing
## where there is nothing to burn), once, and burns anyone standing on it.
##
## The pieces' bricks are already black where the building was: a split
## copies the colour, and fire scorched them before they came loose.

const CHECK_S := 0.5
const CATCH_REACH := 2.5         ## m from a burning cell's centre
const MAX_BURNING := 8
const BURN_S := 12.0
const LAND_HEAT := 0.5
const PAWN_REACH := 1.8
const PAWN_DAMAGE := 3.0         ## per CHECK_S, near a burning piece

var ctx: DisasterContext
var fire: FireSpread

## For the probe and the HUD.
var caught := 0
var landed_lit := 0

## piece -> [seconds left, emitter, lit]. Counted in CHECK_S steps on the
## physics tick, not the clock: where a piece lights a fire is state.
var _burning := {}
var _next := 0.0
var _flame_quad: QuadMesh
var _flame_proc: ParticleProcessMaterial


func setup(context: DisasterContext, fire_service: FireSpread) -> void:
	ctx = context
	fire = fire_service
	_build()


func is_burning(isl: BrickIsland) -> bool:
	return _burning.has(isl)


func count() -> int:
	return _burning.size()


## Put every piece out.
func douse() -> void:
	for isl in _burning.keys():
		_put_out(isl)


## Set a piece burning, from wherever. False at the cap or if it already is.
func catch_piece(isl: BrickIsland) -> bool:
	if _burning.has(isl) or _burning.size() >= MAX_BURNING:
		return false
	if isl == null or not isl.is_valid() or not is_instance_valid(isl.body):
		return false
	var p := GPUParticles3D.new()
	p.amount = 16
	p.lifetime = 0.8
	p.process_material = _flame_proc
	p.draw_pass_1 = _flame_quad
	p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 10, 8))
	isl.body.add_child(p)
	_burning[isl] = [BURN_S, p, false]
	caught += 1
	return true


func _physics_process(delta: float) -> void:
	if ctx == null:
		return
	_next -= delta
	if _next > 0.0:
		return
	_next += CHECK_S
	_catch_near_fire()
	_tend()


func _catch_near_fire() -> void:
	if fire == null or not fire.is_burning() or _burning.size() >= MAX_BURNING:
		return
	for c in fire.cells:
		for isl in ctx.islands_near(FireSpread.centre_of(c.key), CATCH_REACH):
			if not isl.settled:
				catch_piece(isl)
			if _burning.size() >= MAX_BURNING:
				return


func _tend() -> void:
	for isl: BrickIsland in _burning.keys():
		var b: Array = _burning[isl]
		b[0] = float(b[0]) - CHECK_S
		if not isl.is_valid() or not is_instance_valid(isl.body) or float(b[0]) <= 0.0:
			_put_out(isl)
			continue
		var at := isl.body.global_position
		# Where it lands, it lights what it lies against -- a wall, a floor.
		if isl.settled and not bool(b[2]):
			b[2] = true
			if ctx.ignite(at, LAND_HEAT):
				landed_lit += 1
		ctx.damage_pawns(at, PAWN_REACH, PAWN_DAMAGE)


func _put_out(isl: BrickIsland) -> void:
	var b: Array = _burning[isl]
	_burning.erase(isl)
	# Untyped: the emitter goes with the piece's body when that is freed.
	var p: Variant = b[1]
	if is_instance_valid(p):
		(p as Node).queue_free()


func _exit_tree() -> void:
	douse()


func _build() -> void:
	var puff := GradientTexture2D.new()
	puff.width = 64
	puff.height = 64
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	var pg := Gradient.new()
	pg.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	pg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
	puff.gradient = pg
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = puff
	_flame_quad = QuadMesh.new()
	_flame_quad.size = Vector2(0.9, 0.9)
	_flame_quad.material = mat
	_flame_proc = ParticleProcessMaterial.new()
	_flame_proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_flame_proc.emission_sphere_radius = 0.6
	_flame_proc.direction = Vector3.UP
	_flame_proc.spread = 20.0
	_flame_proc.initial_velocity_min = 1.0
	_flame_proc.initial_velocity_max = 2.2
	_flame_proc.gravity = Vector3(0, 1.0, 0)
	_flame_proc.scale_min = 0.5
	_flame_proc.scale_max = 1.1
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.33, 0.66, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.9, 0.5, 1.0), Color(1.0, 0.5, 0.1, 0.9),
			Color(0.8, 0.2, 0.05, 0.5), Color(0.2, 0.05, 0.02, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	_flame_proc.color_ramp = ramp
