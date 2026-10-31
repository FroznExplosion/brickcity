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
##
## The trees are bricks (11.10 revised): Trees' four variants, the heightfield
## scene's and the city's, drawn as the heightfield draws them -- ImpostorLod,
## real bricks within NEAR, baked cards past it. One set per variant per cube
## face, its node turned so the face's normal is its +Y: its chunks, keyed on
## its own XZ, are squares on the ground there.

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
## Frames between re-sorts of the sets whose trees changed: cells come and go
## at the far edge, where a few frames late is never seen.
const DIRTY_EVERY := 4

## Real bricks within this; cards past it (ImpostorLod's tiers).
const NEAR := 45.0
## Per biome (PlanetBiomes.TABLE's order): [trees a hectare, the Trees variants
## it grows] -- 0 green/dark wide, 1 dark/olive narrow, 2 bright wide, 3 olive wide.
const TREES := [
	[0.0, []],              # tundra
	[140.0, [1, 3]],        # taiga: the dark ones
	[3.0, [3]],             # steppe
	[150.0, [0, 1, 2, 3]],  # temperate forest
	[15.0, [0, 2]],         # temperate grass
	[0.0, []],              # desert
	[8.0, [3]],             # savanna
	[170.0, [2, 0]],        # jungle: the bright ones
	[0.0, []],              # scorched
	[0.0, []],              # ice
	[0.0, []],              # barren
]
## The densest biome's trees a hectare: a cell draws this many candidates a
## hectare and each keeps a tree with its own biome's share of it.
const D_MAX := 170.0

var data: PlanetData
var biomes: PlanetBiomes
var faces_n := 0
var _mat: ShaderMaterial
## "face_variant" -> ImpostorLod, and the ones changed since their last update.
var _sets := {}
var _dirty := {}
var _sorted_at := {}
var _turn := 0
var _frame := 0
## key (Vector3i face, i, j) -> {node, centre, trees, handles: [[set, handle]], body}
var _cells := {}
## Trees knocked down this session: cell key -> {index: fallen planet-local
## transform}, so a cell built again has them lying where they fell.
var _knocked := {}
## Falling now: [{lod, handle, from: Transform3D, axis, foot, t}].
var _falls: Array = []
## How long a knocked tree takes to come down, seconds.
const FALL_S := 1.2
var knocked_count := 0
## A tree came down (knock): the AI's world takes its trunk away (PlanetNavNet).
signal tree_knocked(key: Vector3i, index: int)
var _queue: Array[Vector3i] = []
var _planned_at := Vector3.INF
var built_cells := 0
var tree_count := 0
var last_build_us := 0
## Every variant's cards baked (prebake): the scene holds the walker until then.
var prebaked := false


func setup(p_data: PlanetData) -> void:
	name = "Trees"
	data = p_data
	biomes = PlanetBiomes.of(data)
	faces_n = int(ceil(2.0 * data.radius / CELL))
	# The bricks' own material, as the heightfield scene's trees have it.
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/brick.gdshader")
	# Not WeatherFx's: the planet has no weather system, so its trees carry their
	# own -- a breeze along each cube face, snow on the crowns where it is cold
	# (_set_for) -- and nothing else writes over it.
	# For an A/B of the trees' cost (-- --no-trees): none are made.
	if "--no-trees" in OS.get_cmdline_user_args():
		set_process(false)
		prebaked = true


## Bake every variant's cards while the spawn loads (ImpostorLod.prebake), so
## the first sets find them baked instead of baking in play: four bakes were
## six frames of 43-247 ms at the spawn (11.10). Headless there is no bake.
func prebake() -> void:
	if prebaked:
		return
	for v in Trees.VARIANTS:
		await ImpostorLod.prebake(self, _mesh_of(v))
	prebaked = true


func _mesh_of(variant: int) -> Mesh:
	return RecipeMesh.build(Trees.recipe(variant), "tree_%d" % variant)


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

## The trees of a cell: [{variant, at (planet-local foot), basis}], the same every call.
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
		var which := rng.randf()
		if s >= count:
			continue
		var d := dir_at(key.x, fi, fj)
		var e: Array = TREES[biomes.biome_index(d)]
		if pick >= float(e[0]):
			continue
		var kinds: Array = e[1]
		var variant: int = kinds[mini(int(which * kinds.size()), kinds.size() - 1)]
		var h := data.height(d)
		if h < sea + 1.0 or _on_pad(d) or _slope(d, h) > MAX_SLOPE:
			continue
		var x := (Vector3.FORWARD if absf(d.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).cross(d).normalized()
		# Bricks keep their size: turned, never scaled.
		var b := Basis(x, d, x.cross(d)) * Basis(Vector3.UP, yaw)
		out.append({"variant": variant, "at": d * (data.radius + h - 0.05), "basis": b,
				"snow": snow_bucket(d, h)})
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


## A variant's foot -- the middle of its 2 x 2 trunk's base -- in its mesh's
## own metres (the recipe rebased to its min corner, as RecipeMesh builds it).
static func foot_of(variant: int) -> Vector3:
	var off := Trees.trunk_offset(variant)
	var size := BrickWorld.get_cell_size()
	return Vector3((off.x + 1) * size.x, off.y * size.y, (off.z + 1) * size.z)


## Snow on a tree's crown, by the ground shader's own rule (snow where the
## temperature at the height is under freezing, planet_ground.gdshader):
## 0 none, 1 a little, 2 a full cap. Trees are set by it (_set_for).
const SNOW_CAPS := [0.0, 0.5, 1.0]
## The breeze the crowns sway in, along each cube face (weather.gdshaderinc's
## wind, 0..~1.5): a light one.
const BREEZE := 0.35


func snow_bucket(d: Vector3, h: float) -> int:
	var t := PlanetBiomes.temperature_at(biomes.temperature_sea(d), h)
	var cap := smoothstep(1.5, -1.5, t)
	return 0 if cap < 0.25 else (1 if cap < 0.75 else 2)


## The set for `variant` on cube face `f` with snow cap `snow`, made the first
## time it is asked for.
func _set_for(f: int, variant: int, snow := 0) -> ImpostorLod:
	var k := "%d_%d_%d" % [f, variant, snow]
	if _sets.has(k):
		return _sets[k]
	var ax := _axes(f)
	var a: Vector3 = ax[1]
	var m: Vector3 = ax[0]
	var s := ImpostorLod.new()
	s.name = "Trees_%s" % k
	# The face's normal is the set's +Y: its chunks are squares on the ground.
	s.transform = Transform3D(Basis(a, m, a.cross(m)), Vector3.ZERO)
	add_child(s)
	s.set_chunk(128.0)
	var mesh := _mesh_of(variant)
	# Crowns sway about their own base, in their own frame (weather_sway_vertex),
	# in a breeze along the face; snow whitens what faces the tree's own up.
	s.sway = WeatherFx.sway_tree(mesh.get_aabb().end.y)
	s.snowcap = SNOW_CAPS[snow]
	var wind := a * BREEZE
	s.near_params = {"weather_wind": wind, "weather_snow": 1.0, "weather_snow_model_up": true}
	s.card_params = {"weather_snow": SNOW_CAPS[snow], "weather_snow_model_up": true}
	s.setup(_mesh_of(variant), _mat, NEAR, KEEP)
	s.set_cull_fade(150.0)
	_sets[k] = s
	return s


func _build_cell(key: Vector3i) -> void:
	var t0 := Time.get_ticks_usec()
	var centre := cell_centre(key) * (data.radius + data.height(cell_centre(key)))
	var node := Node3D.new()
	node.name = "Cell_%d_%d_%d" % [key.x, key.y, key.z]
	node.position = centre
	add_child(node)
	var trees := trees_of(key)
	var handles := []
	for t in trees:
		var lod := _set_for(key.x, t.variant, int(t.get("snow", 0)))
		var b: Basis = t.basis
		var xf := Transform3D(b, (t.at as Vector3) - b * foot_of(t.variant))
		var down: Dictionary = _knocked.get(key, {})
		if down.has(handles.size()):
			xf = down[handles.size()]
		handles.append([lod, lod.add(lod.transform.affine_inverse() * xf)])
		_dirty[lod] = true
	_cells[key] = {"node": node, "centre": centre, "trees": trees, "handles": handles, "body": null}
	built_cells += 1
	tree_count += trees.size()
	last_build_us = Time.get_ticks_usec() - t0


func _free_cell(key: Vector3i) -> void:
	var c: Dictionary = _cells[key]
	tree_count -= (c.trees as Array).size()
	for h in c.handles:
		(h[0] as ImpostorLod).remove(int(h[1]))
		_dirty[h[0]] = true
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
	# FIXTURE for walkers and rounds, TREE for vehicles (Layers.TREE).
	body.collision_layer = Layers.FIXTURE | Layers.TREE
	body.collision_mask = 0
	body.set_meta(&"on_vehicle", _hit_by_vehicle.bind(key, body))
	(c.node as Node3D).add_child(body)
	var stud := BrickWorld.get_stud_metres()
	var down: Dictionary = _knocked.get(key, {})
	for ti in (c.trees as Array).size():
		var t: Dictionary = c.trees[ti]
		if down.has(ti):
			continue
		# The trunk: 2 x 2 studs of round bricks, three plates each.
		var tall: float = Trees.TRUNK_HEIGHTS[t.variant] * 3 * BrickWorld.get_plate_metres()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.0 * stud, tall, 2.0 * stud)
		cs.shape = box
		var b: Basis = t.basis
		cs.transform = Transform3D(b, (t.at as Vector3) - (c.centre as Vector3) + b.y * tall * 0.5)
		cs.set_meta(&"tree", ti)
		body.add_child(cs)
	c.body = body


# --- knocked down ------------------------------------------------------------

## A vehicle ran into one of a cell's trunks (Tank._knock): a tracked one knocks
## the tree down, away from it; a wheeled one is just stopped by it.
func _hit_by_vehicle(shape_index: int, vehicle: Node3D, key: Vector3i, body: StaticBody3D) -> void:
	if not (vehicle is Tank) or not is_instance_valid(body):
		return
	var owner_id := body.shape_find_owner(shape_index)
	var cs := body.shape_owner_get_owner(owner_id) as CollisionShape3D
	if cs == null or not cs.has_meta(&"tree"):
		return
	var push := (vehicle as CharacterBody3D).velocity
	if push.length() < 0.1:
		push = -vehicle.global_transform.basis.z
	knock(key, int(cs.get_meta(&"tree")), to_local(global_position + push) - to_local(global_position))
	cs.queue_free()


## Knock tree `index` of cell `key` down toward `push` (planet-local): it
## falls about its foot over FALL_S and lies there for the rest of the session.
func knock(key: Vector3i, index: int, push: Vector3) -> bool:
	var c: Dictionary = _cells.get(key, {})
	if c.is_empty() or index < 0 or index >= (c.trees as Array).size():
		return false
	var down: Dictionary = _knocked.get(key, {})
	if down.has(index):
		return false
	var t: Dictionary = c.trees[index]
	var b: Basis = t.basis
	var foot: Vector3 = t.at
	var p := (push - b.y * push.dot(b.y))
	if p.length() < 1e-3:
		p = b.x
	# About the horizontal axis that tips the tree's up toward the push.
	var axis := b.y.cross(p.normalized()).normalized()
	var from := Transform3D(b, foot - b * foot_of(t.variant))
	var h: Array = c.handles[index]
	down[index] = _rotated(from, axis, foot, PI * 0.5)
	_knocked[key] = down
	_falls.append({"lod": h[0], "handle": h[1], "from": from, "axis": axis, "foot": foot, "t": 0.0})
	knocked_count += 1
	tree_knocked.emit(key, index)
	return true


## Every tree within `radius` metres (on the datum) of planet-local unit `dir`,
## whether its cell is built or not: [{key, index, at, basis, variant}]. The
## same every call (trees_of is seeded by the cell); for the AI's world
## (PlanetNavNet.tree_source). Knocked ones are left out.
func trees_near(dir: Vector3, radius: float) -> Array:
	var at := dir.normalized() * data.radius
	var start := cell_of(dir.normalized())
	var seen := {start: true}
	var open: Array[Vector3i] = [start]
	var out: Array = []
	while not open.is_empty():
		var key: Vector3i = open.pop_back()
		if (cell_centre(key) * data.radius).distance_to(at) > radius + CELL:
			continue
		var trees := trees_of(key)
		for i in trees.size():
			var t: Dictionary = trees[i]
			if is_knocked(key, i) or (t.at as Vector3).normalized().distance_to(dir.normalized()) * data.radius > radius:
				continue
			out.append({"key": key, "index": i, "at": t.at, "basis": t.basis, "variant": t.variant})
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nk := cell_of(dir_at(key.x, key.y + 0.5 + o.x, key.z + 0.5 + o.y))
			if not seen.has(nk):
				seen[nk] = true
				open.append(nk)
	return out


## A trunk's box (the collider's): 2 x 2 studs, its height in bricks.
static func trunk_size(variant: int) -> Vector3:
	var stud := BrickWorld.get_stud_metres()
	return Vector3(2.0 * stud, Trees.TRUNK_HEIGHTS[variant] * 3 * BrickWorld.get_plate_metres(), 2.0 * stud)


## The standing trees of the built cells nearest planet-local `p`, nearest
## first: [{key, index, at, variant}], at most `n`.
func nearest(p: Vector3, n := 1, skip: Array = []) -> Array:
	var all: Array = []
	for key in _cells:
		var trees: Array = _cells[key].trees
		for i in trees.size():
			if is_knocked(key, i) or skip.has([key, i]):
				continue
			all.append([(trees[i].at as Vector3).distance_to(p), key, i])
	all.sort_custom(func(a, b) -> bool: return a[0] < b[0])
	var out: Array = []
	for e in all.slice(0, n):
		var t: Dictionary = _cells[e[1]].trees[e[2]]
		out.append({"key": e[1], "index": e[2], "at": t.at, "variant": t.variant})
	return out


## Where a knocked tree lies (planet-local transform of its copy), or none.
func fallen_xf(key: Vector3i, index: int) -> Variant:
	return (_knocked.get(key, {}) as Dictionary).get(index)


func is_knocked(key: Vector3i, index: int) -> bool:
	return (_knocked.get(key, {}) as Dictionary).has(index)


static func _rotated(xf: Transform3D, axis: Vector3, foot: Vector3, a: float) -> Transform3D:
	var r := Basis(axis, a)
	return Transform3D(r * xf.basis, foot + r * (xf.origin - foot))


func _fall_step(delta: float) -> void:
	var i := 0
	while i < _falls.size():
		var f: Dictionary = _falls[i]
		f.t = float(f.t) + delta
		# As a falling body goes: slowly from upright, fast at the end.
		var k := clampf(float(f.t) / FALL_S, 0.0, 1.0)
		var xf := _rotated(f.from, f.axis, f.foot, PI * 0.5 * k * k)
		var lod: ImpostorLod = f.lod
		if is_instance_valid(lod):
			lod.move(int(f.handle), lod.transform.affine_inverse() * xf)
			_dirty[lod] = true
		if k >= 1.0:
			_falls.remove_at(i)
		else:
			i += 1


# --- streaming round the camera -----------------------------------------------------

func _process(_delta: float) -> void:
	if not _falls.is_empty():
		_fall_step(_delta)
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
	# The sets: those whose trees changed now, and one more a frame in turn once
	# the camera has moved a metre since it was last sorted (TerrainTrees' way).
	var here := cam.global_position
	_frame += 1
	if _frame % DIRTY_EVERY == 0:
		for lod in _dirty:
			(lod as ImpostorLod).update((lod as ImpostorLod).to_local(here))
			_sorted_at[lod] = here
		_dirty.clear()
	if not _sets.is_empty():
		var keys := _sets.keys()
		var s: ImpostorLod = _sets[keys[_turn % keys.size()]]
		_turn += 1
		if (_sorted_at.get(s, Vector3.INF) as Vector3).distance_to(here) > 1.0:
			s.update(s.to_local(here))
			_sorted_at[s] = here


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
