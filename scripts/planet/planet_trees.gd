class_name PlanetTrees
extends Node3D

## The planet's trees (Docs/Planets.md 11.10). A child of the planet's node, so
## everything here is planet-local and the translation re-centre carries it.
##
## The ground is cut into cells of CELL metres on the cube-sphere (a direction's
## cube face and its gnomonic (u, v)); a cell's trees come from a generator
## seeded by its key, so the same trees stand there every visit and nothing is
## stored. A spot keeps a tree by the biome's density there (PlanetBiomes, the
## climate that colours the ground), never on a town's pad, at the sea or on
## ground steeper than MAX_SLOPE. Cells within KEEP of the camera are built, a
## few a frame nearest first, and freed past DROP; trunks within SOLID of the
## camera are solid.

const CELL := 64.0
const KEEP := 640.0
const DROP := 720.0
const SOLID := 96.0
const MAX_SLOPE := 30.0
## Cells built in one frame at most, and the time they may take.
const BUILD_PER_FRAME := 6
const BUILD_BUDGET_US := 3000
## Re-plan which cells are wanted once the camera has moved this far.
const REPLAN := 48.0

const K := PlanetTreeMeshes.Kind
## Per biome (PlanetBiomes.TABLE's order): [kind, trees a hectare] (11.10).
const TREES := [
	[[K.SHRUB, 15.0]],                                  # tundra
	[[K.CONIFER, 120.0], [K.SHRUB, 20.0]],              # taiga
	[[K.SHRUB, 25.0], [K.BROADLEAF, 3.0]],              # steppe
	[[K.BROADLEAF, 110.0], [K.CONIFER, 30.0]],          # temperate forest
	[[K.BROADLEAF, 12.0], [K.SHRUB, 20.0]],             # temperate grass
	[[K.CACTUS, 6.0], [K.SHRUB, 4.0]],                  # desert
	[[K.ACACIA, 10.0], [K.SHRUB, 15.0]],                # savanna
	[[K.PALM, 60.0], [K.BROADLEAF, 90.0]],              # jungle
]
## The densest biome's trees a hectare: a cell draws this many candidates a
## hectare and each keeps a tree with its own biome's share of it.
const D_MAX := 150.0

var data: PlanetData
var biomes: PlanetBiomes
var faces_n := 0
var _mat: ShaderMaterial
## key (Vector3i face, i, j) -> {node, centre, bodies?}
var _cells := {}
var _queue: Array[Vector3i] = []
var _planned_at := Vector3.INF
var built_cells := 0
var tree_count := 0
var last_build_us := 0


func setup(p_data: PlanetData) -> void:
	name = "Trees"
	data = p_data
	biomes = PlanetBiomes.of(data)
	faces_n = int(ceil(2.0 * data.radius / CELL))
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/planet_tree.gdshader")
	_mat.set_shader_parameter("fade_near", KEEP - 190.0)
	_mat.set_shader_parameter("fade_far", KEEP - 40.0)
	# For an A/B of the trees' cost (-- --no-trees): none are made.
	if "--no-trees" in OS.get_cmdline_user_args():
		set_process(false)


# --- cells ---------------------------------------------------------------------

## A cube face's normal and its two tangent axes.
static func _axes(f: int) -> Array:
	match f:
		0: return [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
		1: return [Vector3.LEFT, Vector3.UP, Vector3.FORWARD]
		2: return [Vector3.UP, Vector3.BACK, Vector3.RIGHT]
		3: return [Vector3.DOWN, Vector3.FORWARD, Vector3.RIGHT]
		4: return [Vector3.BACK, Vector3.UP, Vector3.LEFT]
	return [Vector3.FORWARD, Vector3.UP, Vector3.RIGHT]


static func _face_of(d: Vector3) -> int:
	var a := d.abs()
	if a.x >= a.y and a.x >= a.z:
		return 0 if d.x > 0.0 else 1
	if a.y >= a.z:
		return 2 if d.y > 0.0 else 3
	return 4 if d.z > 0.0 else 5


## The cell a unit direction is in.
func cell_of(d: Vector3) -> Vector3i:
	var f := _face_of(d)
	var ax := _axes(f)
	var m: float = d.dot(ax[0])
	var u: float = d.dot(ax[1]) / m
	var v: float = d.dot(ax[2]) / m
	return Vector3i(f, clampi(int(floor((u + 1.0) * 0.5 * faces_n)), 0, faces_n - 1),
			clampi(int(floor((v + 1.0) * 0.5 * faces_n)), 0, faces_n - 1))


## The direction at (fi, fj) in cell units on face f (fractions inside a cell;
## past the face's edge it carries on, onto the next face's directions).
func dir_at(f: int, fi: float, fj: float) -> Vector3:
	var ax := _axes(f)
	var u := fi / faces_n * 2.0 - 1.0
	var v := fj / faces_n * 2.0 - 1.0
	return ((ax[0] as Vector3) + (ax[1] as Vector3) * u + (ax[2] as Vector3) * v).normalized()


func cell_centre(key: Vector3i) -> Vector3:
	return dir_at(key.x, key.y + 0.5, key.z + 0.5)


## The cell's area on the datum, square metres.
func cell_area(key: Vector3i) -> float:
	var p00 := dir_at(key.x, key.y, key.z) * data.radius
	var p10 := dir_at(key.x, key.y + 1, key.z) * data.radius
	var p01 := dir_at(key.x, key.y, key.z + 1) * data.radius
	var p11 := dir_at(key.x, key.y + 1, key.z + 1) * data.radius
	return 0.5 * ((p10 - p00).cross(p01 - p00).length() + (p10 - p11).cross(p01 - p11).length())


# --- one cell's trees ------------------------------------------------------------

## The trees of a cell: [{kind, at (planet-local foot), basis}], the same every call.
func trees_of(key: Vector3i) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([data.planet_seed, key.x, key.y, key.z])
	var count := int(round(D_MAX * cell_area(key) / 10000.0))
	var side := int(ceil(sqrt(float(count))))
	var out := []
	var sea := data.sea_level if not is_nan(data.sea_level) else -INF
	for s in side * side:
		# Stratified: one candidate in each of side x side sub-cells, jittered.
		var fi := key.y + (float(s % side) + rng.randf()) / side
		var fj := key.z + (floorf(float(s) / side) + rng.randf()) / side
		var pick := rng.randf() * D_MAX
		var yaw := rng.randf() * TAU
		var size := rng.randf_range(0.8, 1.25)
		if s >= count:
			continue
		var d := dir_at(key.x, fi, fj)
		var kinds: Array = TREES[biomes.biome_index(d)]
		var kind := -1
		for e in kinds:
			pick -= float(e[1])
			if pick < 0.0:
				kind = int(e[0])
				break
		if kind < 0:
			continue
		var h := data.height(d)
		if h < sea + 1.0 or _on_pad(d) or _slope(d, h) > MAX_SLOPE:
			continue
		var x := (Vector3.FORWARD if absf(d.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).cross(d).normalized()
		var b := Basis(x, d, x.cross(d)) * Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3.ONE * size)
		out.append({"kind": kind, "at": d * (data.radius + h - 0.05), "basis": b})
	return out


func _on_pad(d: Vector3) -> bool:
	for pad in data.pads:
		if (d * data.radius).distance_to((pad.dir as Vector3) * data.radius) < float(pad.flat) + float(pad.blend):
			return true
	return false


## The ground's slope at `d` (degrees), from its height a metre either way.
func _slope(d: Vector3, h: float) -> float:
	var x := (Vector3.FORWARD if absf(d.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).cross(d).normalized()
	var z := x.cross(d)
	var step := 1.0 / data.radius
	var hx := data.height((d + x * step).normalized()) - h
	var hz := data.height((d + z * step).normalized()) - h
	return rad_to_deg(atan(sqrt(hx * hx + hz * hz)))


func _build_cell(key: Vector3i) -> void:
	var t0 := Time.get_ticks_usec()
	var centre := cell_centre(key) * (data.radius + data.height(cell_centre(key)))
	var node := Node3D.new()
	node.name = "Cell_%d_%d_%d" % [key.x, key.y, key.z]
	node.position = centre
	add_child(node)
	var by_kind := {}
	var trees := trees_of(key)
	for t in trees:
		if not by_kind.has(t.kind):
			by_kind[t.kind] = []
		by_kind[t.kind].append(t)
	for kind in by_kind:
		var list: Array = by_kind[kind]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = PlanetTreeMeshes.mesh(kind)
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, Transform3D(list[i].basis, (list[i].at as Vector3) - centre))
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		node.add_child(mi)
	_cells[key] = {"node": node, "centre": centre, "trees": trees, "body": null}
	built_cells += 1
	tree_count += trees.size()
	last_build_us = Time.get_ticks_usec() - t0


func _free_cell(key: Vector3i) -> void:
	var c: Dictionary = _cells[key]
	tree_count -= (c.trees as Array).size()
	(c.node as Node).queue_free()
	_cells.erase(key)


## Box colliders on a cell's trunks, one StaticBody for the cell. On FIXTURE:
## walkers and bullets meet a trunk, nothing that falls does, and vehicles
## (WORLD | STRUCTURE | DEBRIS) drive through for now. (On WORLD the planet's
## squad gate failed -- the squad never ordered on -- with the nearest trunk 89 m
## from anyone; the cause was not found.)
func _make_solid(key: Vector3i) -> void:
	var c: Dictionary = _cells[key]
	var body := StaticBody3D.new()
	body.collision_layer = Layers.FIXTURE
	body.collision_mask = 0
	(c.node as Node3D).add_child(body)
	for t in c.trees:
		var tb: Array = PlanetTreeMeshes.trunk(t.kind)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = tb[0]
		cs.shape = box
		var b: Basis = t.basis
		cs.transform = Transform3D(b, (t.at as Vector3) - (c.centre as Vector3) + b * (tb[1] as Vector3))
		body.add_child(cs)
	c.body = body


# --- streaming round the camera -----------------------------------------------------

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or data == null:
		return
	var at := to_local(cam.global_position)
	if _planned_at == Vector3.INF or at.distance_to(_planned_at) > REPLAN:
		_plan(at)
	# Build nearest first, a few a frame.
	var t0 := Time.get_ticks_usec()
	var n := 0
	while not _queue.is_empty() and n < BUILD_PER_FRAME and Time.get_ticks_usec() - t0 < BUILD_BUDGET_US:
		var key: Vector3i = _queue.pop_front()
		if not _cells.has(key):
			_build_cell(key)
			n += 1
	# Free the far, make the near solid.
	for key in _cells.keys():
		var c: Dictionary = _cells[key]
		var dist := at.distance_to(c.centre)
		if dist > DROP:
			_free_cell(key)
		elif dist < SOLID and c.body == null:
			_make_solid(key)
		elif dist > SOLID * 1.5 and c.body != null:
			(c.body as Node).queue_free()
			c.body = null


## Which cells the camera wants: a flood from its own cell to every cell whose
## centre is within KEEP, across face edges by direction; nearest first.
func _plan(at: Vector3) -> void:
	_planned_at = at
	_queue.clear()
	if at.length() - data.radius > KEEP:
		return
	var start := cell_of(at.normalized())
	var seen := {start: true}
	var open: Array[Vector3i] = [start]
	var want: Array = []
	while not open.is_empty():
		var key: Vector3i = open.pop_back()
		var c := cell_centre(key) * data.radius
		var dist := c.distance_to(at)
		if dist > KEEP + CELL:
			continue
		if dist <= KEEP:
			want.append([dist, key])
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nk := cell_of(dir_at(key.x, key.y + 0.5 + o.x, key.z + 0.5 + o.y))
			if not seen.has(nk):
				seen[nk] = true
				open.append(nk)
	want.sort_custom(func(a, b) -> bool: return a[0] < b[0])
	for w in want:
		if not _cells.has(w[1]):
			_queue.append(w[1])
