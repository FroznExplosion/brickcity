class_name PlanetTreeMeshes
extends RefCounted

## The planet's tree kinds (Docs/Planets.md 11.10): low-poly and brick-cut,
## boxes and plates, vertex coloured, built once in code. Each mesh's origin is
## the foot of its trunk, +Y up. `trunk(kind)` is the box a trunk's collider is.

enum Kind { CONIFER, BROADLEAF, ACACIA, PALM, CACTUS, SHRUB }

const BARK := Color(0.36, 0.26, 0.18)
const PALM_BARK := Color(0.52, 0.42, 0.30)

static var _meshes := {}


static func mesh(kind: int) -> ArrayMesh:
	if not _meshes.has(kind):
		_meshes[kind] = _build(kind)
	return _meshes[kind]


## The trunk's box: size, and its centre over the foot.
static func trunk(kind: int) -> Array:
	match kind:
		Kind.CONIFER: return [Vector3(0.5, 2.0, 0.5), Vector3(0, 1.0, 0)]
		Kind.BROADLEAF: return [Vector3(0.6, 3.2, 0.6), Vector3(0, 1.6, 0)]
		Kind.ACACIA: return [Vector3(0.45, 3.0, 0.45), Vector3(0, 1.5, 0)]
		Kind.PALM: return [Vector3(0.45, 7.0, 0.45), Vector3(0, 3.5, 0)]
		Kind.CACTUS: return [Vector3(0.7, 3.0, 0.7), Vector3(0, 1.5, 0)]
	return [Vector3(1.4, 0.9, 1.4), Vector3(0, 0.45, 0)]   # a shrub: walk round it


static func _build(kind: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match kind:
		Kind.CONIFER:
			var dark := Color(0.13, 0.27, 0.17)
			_box(st, Vector3(0, 0.9, 0), Vector3(0.5, 1.8, 0.5), BARK)
			_box(st, Vector3(0, 2.6, 0), Vector3(3.4, 1.6, 3.4), dark)
			_box(st, Vector3(0, 4.0, 0), Vector3(2.6, 1.4, 2.6), dark.lightened(0.05))
			_box(st, Vector3(0, 5.2, 0), Vector3(1.8, 1.2, 1.8), dark.lightened(0.1))
			_box(st, Vector3(0, 6.2, 0), Vector3(0.9, 1.0, 0.9), dark.lightened(0.15))
		Kind.BROADLEAF:
			var leaf := Color(0.22, 0.42, 0.18)
			_box(st, Vector3(0, 1.6, 0), Vector3(0.6, 3.2, 0.6), BARK)
			_box(st, Vector3(0, 4.4, 0), Vector3(4.2, 2.6, 4.2), leaf)
			_box(st, Vector3(0.3, 6.1, -0.2), Vector3(2.8, 1.2, 2.8), leaf.lightened(0.08))
		Kind.ACACIA:
			var leaf := Color(0.38, 0.45, 0.20)
			_box(st, Vector3(0, 1.5, 0), Vector3(0.45, 3.0, 0.45), BARK)
			_box(st, Vector3(0.5, 3.4, 0), Vector3(1.4, 0.3, 0.3), BARK)
			_box(st, Vector3(0, 3.9, 0), Vector3(6.0, 0.7, 5.0), leaf)
		Kind.PALM:
			var frond := Color(0.25, 0.48, 0.17)
			_box(st, Vector3(0, 3.5, 0), Vector3(0.45, 7.0, 0.45), PALM_BARK)
			_box(st, Vector3(0, 7.1, 0), Vector3(5.0, 0.2, 1.0), frond)
			_box(st, Vector3(0, 7.15, 0), Vector3(1.0, 0.2, 5.0), frond.lightened(0.06))
			_box(st, Vector3(0, 7.3, 0), Vector3(0.9, 0.5, 0.9), frond.darkened(0.15))
		Kind.CACTUS:
			var green := Color(0.30, 0.47, 0.25)
			_box(st, Vector3(0, 1.5, 0), Vector3(0.7, 3.0, 0.7), green)
			_box(st, Vector3(0.75, 1.3, 0), Vector3(0.8, 0.45, 0.45), green)
			_box(st, Vector3(1.0, 1.9, 0), Vector3(0.45, 1.2, 0.45), green)
			_box(st, Vector3(-0.7, 1.8, 0), Vector3(0.7, 0.4, 0.4), green)
			_box(st, Vector3(-0.9, 2.2, 0), Vector3(0.4, 0.9, 0.4), green)
		_:
			var leaf := Color(0.30, 0.40, 0.20)
			_box(st, Vector3(0, 0.45, 0), Vector3(1.4, 0.9, 1.4), leaf)
			_box(st, Vector3(0.2, 1.0, 0.1), Vector3(0.8, 0.4, 0.8), leaf.lightened(0.08))
	return st.commit()


## A box at `c`, of `size`, in colour `col`: flat faces, outward normals.
static func _box(st: SurfaceTool, c: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3.RIGHT, Vector3.UP, Vector3.BACK],
		[Vector3.LEFT, Vector3.UP, Vector3.FORWARD],
		[Vector3.UP, Vector3.BACK, Vector3.RIGHT],
		[Vector3.DOWN, Vector3.FORWARD, Vector3.RIGHT],
		[Vector3.BACK, Vector3.UP, Vector3.LEFT],
		[Vector3.FORWARD, Vector3.UP, Vector3.RIGHT],
	]
	for f in faces:
		var n: Vector3 = f[0]
		var a: Vector3 = f[1]
		var b: Vector3 = f[2]
		var o := c + n * h
		var ea := a * h
		var eb := b * h
		var q := [o - ea - eb, o + ea - eb, o + ea + eb, o - ea + eb]
		# Wound so the front faces outward (Godot: clockwise from the front).
		if n.dot(a.cross(b)) > 0.0:
			q.reverse()
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(q[i])
