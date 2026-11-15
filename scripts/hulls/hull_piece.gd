class_name HullPiece
extends Node3D
## A part broken off a boat (Docs/Hulls.md 7.4): its bricks drawn as one mesh, and
## floated by what it is itself (HullFloat) -- its bricks' plastic, and any air it
## still shuts in. A part with a whole stretch of hold in it floats; an open one,
## little lighter than the water, settles and goes down.
##
## It has no collision and takes no hits: nobody stands on it, and a shot goes
## through it. Gone once it is SUNK under the sea, or LIFE seconds old.

## This far under the calm sea: gone.
const SUNK := 8.0
## Seconds it is kept at most, afloat or not.
const LIFE := 240.0
## Seconds it shrinks away in, at the end.
const FADE := 1.5

var floats: HullFloat
var vel := Vector3.ZERO
var ang := Vector3.ZERO
var bricks := 0
var sea := 0.0
## The sea's clock (its boat's, while that lasts).
var wave_t := 0.0
var age := 0.0
var last_submerged := 0.0
## Its boat, untyped: Boat names this class, and two scripts typing each other
## leak at exit.
var _boat
var _look: MeshInstance3D
var _task := -1
var _holder: Array = [null]
var _dying := -1.0


## The piece that is chunk `c` of `boat`'s bricks (the split's, alive while
## `drifted` is emitted), drawn from `arrays` with its centre of mass at its
## node. Its transform is the caller's to set: `at`.
static func make(boat, c: int, arrays: Array, at: Transform3D, local_com: Vector3, count: int,
		material: Material) -> HullPiece:
	var p := HullPiece.new()
	p.name = "HullPiece"
	p.bricks = count
	p._boat = boat
	p.sea = boat.sea
	p.wave_t = boat.wave_t
	# Its cells: bricks, and the air they still shut in (HullAir's fills, on its
	# own grid, no doors).
	var a := HullAir.new()
	a.dims = boat.bricks.get_chunk_dims(c)
	var solid: PackedByteArray = boat.bricks.get_solid_cells(c)
	var n := a.dims.x * a.dims.y * a.dims.z
	a.state.resize(n)
	a.comp.resize(n)
	a.comp.fill(-1)
	for i in n:
		a.state[i] = HullAir.SOLID if solid[i] != 0 else HullAir.EMPTY
	a._fill_outside()
	a._label_inside()
	p.floats = HullFloat.measure(a.dims, a.state, Transform3D(Basis(), -local_com))
	# It leaves moving as that part of the boat moved.
	var b_vel: Vector3 = boat.vel
	var b_ang: Vector3 = boat.ang
	var b_com: Vector3 = boat.global_transform * boat.com
	p.vel = b_vel + b_ang.cross(at.origin - b_com)
	p.ang = b_ang
	p.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	p._look = MeshInstance3D.new()
	p._look.position = -local_com
	p._look.material_override = material
	p.add_child(p._look)
	# Its mesh on a worker, as a drifting piece's (10-25 ms on the main thread).
	var holder := p._holder
	p._task = WorkerThreadPool.add_task(func() -> void:
			if arrays.is_empty():
				return
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, IslandManager.UPLOAD_COMPRESS)
			holder[0] = m, false, "hull piece")
	return p


## Whether it floats when at rest: it keeps more water out than it weighs.
func buoyant() -> bool:
	return floats.displaces() * HullFloat.WATER > floats.mass


func _physics_process(dt: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_look.mesh = _holder[0]
	age += dt
	wave_t = float(_boat.wave_t) if _boat != null and is_instance_valid(_boat) else wave_t + dt
	var sn := {"xf": global_transform, "vel": vel, "ang": ang, "t": wave_t, "sea": sea,
			"water": PackedFloat32Array()}
	floats.forces(sn)
	last_submerged = float(sn.sub)
	var next := floats.integrate(dt, sn, global_transform, vel, ang)
	global_transform = next[0]
	vel = next[1]
	ang = next[2]
	if _dying < 0.0 and (age > LIFE or sea - global_position.y > SUNK):
		_dying = 0.0
	if _dying >= 0.0:
		_dying += dt
		_look.scale = Vector3.ONE * maxf(0.01, 1.0 - _dying / FADE)
		if _dying >= FADE:
			queue_free()


func _exit_tree() -> void:
	# Its mesh job writes into its holder: let it finish (teardown, not play).
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
