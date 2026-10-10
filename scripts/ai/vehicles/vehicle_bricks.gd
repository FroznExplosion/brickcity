class_name VehicleBricks
extends Node
## A vehicle's body built of bricks, in ZONES (Docs/AIVehicles.md 1, 4.2).
##
## Red Dawn coloured its vehicles' damage zones -- engine, tracks, ammo -- and
## lost a function with each; here a zone is a GROUP OF BRICKS, and losing the
## group loses the function. Every brick is a real brick's size (a stud square
## across, a course or a plate tall), laid in running bond, a chamfered box with
## studs on whatever top is open, and every brick has hit points of its own.
##
## A hit lands on the brick nearest where it struck, and what is left of it goes
## on to the next nearest, within the hit's reach -- in the same part first (a
## rocket on the turret goes into the turret, not the deck under it): a rifle
## round chips a brick, a rocket knocks two or three off, and they fly. Once fewer than a zone's KEEP
## share of its bricks are left, the zone is LOST (`zone_lost`): what that means
## is the vehicle's to say (Tank: an engine that stops, a track thrown, a gun
## gone, an ammo rack that cooks off).
##
## Not yet: the bricks are the vehicle's own, drawn and hit here, not bricks in
## the world's grid -- so they are not cover AIWorld knows of, and they do not
## carry weight (AIPlan P7).
##
## Drawn cheaply: one MultiMesh per part and brick size, and one of studs per
## part. A brick knocked off is a zero-scale instance and its part's studs laid
## again -- nothing is rebuilt.

signal zone_lost(zone: StringName)
## A brick came off (`at`, world space).
signal brick_off(zone: StringName, at: Vector3)

const STUD := 0.35
const PLATE := 0.14
## Plates in a brick's course.
const COURSE := 3
## A brick's length along a fill's long axis, and its width across, in studs.
const BRICK_LONG := 4.0
const BRICK_WIDE := 2.0
## What is left of a hit goes into another part only past this much more
## distance than its own.
const OTHER_PART := 0.45
## Bricks in the air at once, over every vehicle: past this one comes off unseen.
const FLYING_MAX := 40
const FLY_LIFE := 4.0

class Brick:
	var part := 0
	var zone: StringName
	## Part-local box, metres.
	var center := Vector3.ZERO
	var size := Vector3.ZERO
	## In studs (x, z) and plates (y), part-local: for the studs on its top.
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	var hp := 0.0
	var color := Color.WHITE
	var alive := true
	## On the outside of what it was laid in: what a hit with no point lands on.
	var outer := false
	var mm: MultiMesh
	var mm_index := 0

var vehicle: Node3D
var bricks: Array[Brick] = []
var parts: Array[Node3D] = []
## zone -> {"total": int, "alive": int, "keep": float, "lost": bool}
var zones := {}
## Bricks knocked off, for logs and probes.
var knocked := 0
var rng := RandomNumberGenerator.new()

var _material: StandardMaterial3D
var _burnt: StandardMaterial3D
## part -> size key -> MultiMesh (while laying: arrays of bricks)
var _laying := {}
var _mmis: Array[MultiMeshInstance3D] = []
var _studs: Array[MultiMeshInstance3D] = []
## part -> Vector3i(stud x * 2, bottom plate, stud z * 2) -> brick, for "is this
## stud covered".
var _cells: Array[Dictionary] = []

static var _flying := 0


static func attach(v: Node3D) -> VehicleBricks:
	var vb := VehicleBricks.new()
	vb.name = "Bricks"
	vb.vehicle = v
	vb.rng.seed = 0xB41C
	vb._material = StandardMaterial3D.new()
	vb._material.vertex_color_use_as_albedo = true
	vb._material.roughness = 0.55
	vb._burnt = StandardMaterial3D.new()
	vb._burnt.albedo_color = Color(0.1, 0.09, 0.08)
	vb._burnt.roughness = 0.9
	v.add_child(vb)
	return vb


## A part that moves on its own (the hull, a turret, a gun): bricks are laid in
## its space. Returns its index.
func add_part(node: Node3D) -> int:
	parts.append(node)
	_cells.append({})
	_laying[parts.size() - 1] = {}
	return parts.size() - 1


## Fill a box of `part` with bricks of `zone`, in running bond: `lo` .. `hi` in
## studs across (x), plates up (y) and studs along (z), part-local, laid in
## courses of COURSE plates (the last one thinner if the box is). Long bricks
## run along z, or along x with `along_x`. `hp` each.
func fill(part: int, zone: StringName, lo: Vector3, hi: Vector3, color: Color, hp: float,
		along_x := false) -> void:
	if not zones.has(zone):
		zones[zone] = {"total": 0, "alive": 0, "keep": 0.0, "lost": false}
	var y := lo.y
	var c := 0
	while y < hi.y - 0.01:
		var y2 := minf(y + COURSE, hi.y)
		var odd := c % 2 == 1
		var xs := _cuts(lo.x, hi.x, BRICK_LONG if along_x else BRICK_WIDE,
				(2.0 if along_x else 1.0) if odd else 0.0)
		var zs := _cuts(lo.z, hi.z, BRICK_WIDE if along_x else BRICK_LONG,
				(1.0 if along_x else 2.0) if odd else 0.0)
		for xr in xs:
			for zr in zs:
				var b := Brick.new()
				b.part = part
				b.zone = zone
				b.lo = Vector3(xr[0], y, zr[0])
				b.hi = Vector3(xr[1], y2, zr[1])
				b.size = Vector3((b.hi.x - b.lo.x) * STUD, (b.hi.y - b.lo.y) * PLATE, (b.hi.z - b.lo.z) * STUD)
				b.center = Vector3((b.lo.x + b.hi.x) * 0.5 * STUD, (b.lo.y + b.hi.y) * 0.5 * PLATE,
						(b.lo.z + b.hi.z) * 0.5 * STUD)
				b.hp = hp
				b.color = color
				b.outer = is_equal_approx(b.lo.x, lo.x) or is_equal_approx(b.hi.x, hi.x) \
						or is_equal_approx(b.lo.z, lo.z) or is_equal_approx(b.hi.z, hi.z) \
						or is_equal_approx(b.hi.y, hi.y)
				bricks.append(b)
				zones[zone].total += 1
				zones[zone].alive += 1
				var key := "%.3f,%.3f,%.3f" % [b.size.x, b.size.y, b.size.z]
				var by_size: Dictionary = _laying[part]
				if not by_size.has(key):
					by_size[key] = []
				(by_size[key] as Array).append(b)
				for sx in _stud_cells(b):
					_cells[part][Vector3i(roundi(sx.x * 2.0), roundi(b.lo.y), roundi(sx.y * 2.0))] = b
		y = y2
		c += 1


## A zone is lost when fewer than `share` of its bricks are left.
func keep(zone: StringName, share: float) -> void:
	zones[zone].keep = share


## Done laying: the meshes.
func finish() -> void:
	for part in _laying:
		var by_size: Dictionary = _laying[part]
		for key in by_size:
			var list: Array = by_size[key]
			var first: Brick = list[0]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = PieceMeshes.chamfered_box(first.size)
			mm.instance_count = list.size()
			for i in list.size():
				var b: Brick = list[i]
				b.mm = mm
				b.mm_index = i
				mm.set_instance_transform(i, Transform3D(Basis(), b.center))
				mm.set_instance_color(i, b.color)
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Bricks%d" % _mmis.size()
			mmi.multimesh = mm
			mmi.material_override = _material
			parts[part].add_child(mmi)
			_mmis.append(mmi)
		var studs := MultiMeshInstance3D.new()
		studs.name = "Studs%d" % part
		var smm := MultiMesh.new()
		smm.transform_format = MultiMesh.TRANSFORM_3D
		smm.use_colors = true
		smm.mesh = PieceMeshes.stud()
		studs.multimesh = smm
		studs.material_override = _material
		parts[part].add_child(studs)
		_studs.append(studs)
		_lay_studs(part)
	_laying.clear()


func zone_alive(zone: StringName) -> int:
	return int(zones[zone].alive) if zones.has(zone) else 0


func zone_share(zone: StringName) -> float:
	if not zones.has(zone) or int(zones[zone].total) == 0:
		return 0.0
	return float(zones[zone].alive) / float(zones[zone].total)


## Does it still have `zone` (a zone it never had, it has not lost)?
func has(zone: StringName) -> bool:
	return not zones.has(zone) or not bool(zones[zone].lost)


func alive_count() -> int:
	var n := 0
	for b in bricks:
		if b.alive:
			n += 1
	return n


# --- hits ---------------------------------------------------------------------------

## `amount` landing at `at` (world): on the nearest brick within `reach`, and
## what it does not need on to the next nearest, and so on. Returns the bricks
## knocked off.
func hit(at: Vector3, amount: float, reach: float) -> int:
	var off := 0
	var left := amount
	var guard := 0
	var part := -1
	while left > 0.001 and guard < 16:
		guard += 1
		var b := nearest(at, reach, part)
		if b == null:
			break
		part = b.part
		var take := minf(left, b.hp)
		b.hp -= take
		left -= take
		if b.hp > 0.001:
			break
		knock(b, at)
		off += 1
	return off


## `amount` with nowhere it struck (a splash round the middle): on a brick of
## the outside, picked at random, from just off its face.
func hit_anywhere(amount: float, reach: float) -> int:
	var out: Array[Brick] = []
	for b in bricks:
		if b.alive and b.outer:
			out.append(b)
	if out.is_empty():
		return 0
	var b: Brick = out[rng.randi() % out.size()]
	var p := parts[b.part].global_transform * b.center
	return hit(p, amount, reach)


## The living brick nearest `at` (world), within `reach` of its box; null for
## none. With `part`, another part's bricks count OTHER_PART further off.
func nearest(at: Vector3, reach: float, part := -1) -> Brick:
	var local: Array[Vector3] = []
	for p in parts:
		local.append(p.global_transform.affine_inverse() * at)
	var best: Brick = null
	var best_d := reach
	for b in bricks:
		if not b.alive:
			continue
		var q := local[b.part] - b.center
		var d := Vector3(maxf(absf(q.x) - b.size.x * 0.5, 0.0), maxf(absf(q.y) - b.size.y * 0.5, 0.0),
				maxf(absf(q.z) - b.size.z * 0.5, 0.0)).length()
		if part >= 0 and b.part != part:
			d += OTHER_PART
		if d <= best_d:
			best_d = d
			best = b
	return best


## `b` comes off, flung away from `from`.
func knock(b: Brick, from: Vector3) -> void:
	if not b.alive:
		return
	b.alive = false
	b.hp = 0.0
	knocked += 1
	b.mm.set_instance_transform(b.mm_index, Transform3D(Basis().scaled(Vector3.ZERO), b.center))
	_lay_studs(b.part)
	var world := parts[b.part].global_transform * b.center
	_fly(b, world, from)
	brick_off.emit(b.zone, world)
	var z: Dictionary = zones[b.zone]
	z.alive -= 1
	if not z.lost and float(z.alive) < float(z.total) * float(z.keep):
		z.lost = true
		zone_lost.emit(b.zone)


## Every brick of `zone` off at once (an ammo rack cooking off takes itself).
func knock_zone(zone: StringName, from: Vector3) -> void:
	for b in bricks:
		if b.alive and b.zone == zone:
			knock(b, from)


## Wrecked: what is left of it, burnt.
func burn() -> void:
	for mmi in _mmis:
		mmi.material_override = _burnt
	for s in _studs:
		s.material_override = _burnt


# --- laying -------------------------------------------------------------------------

## `a` .. `b` cut into lengths of `len`, the first `first` long (0: a whole one).
static func _cuts(a: float, b: float, len: float, first: float) -> Array:
	var out := []
	var s := a
	var e := a + (first if first > 0.0 else len)
	while s < b - 0.01:
		e = minf(e, b)
		out.append([s, e])
		s = e
		e = s + len
	return out


## The studs on `b`'s top: the middle of each stud square it covers (x, z).
static func _stud_cells(b: Brick) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var x := b.lo.x
	while x < b.hi.x - 0.01:
		var z := b.lo.z
		while z < b.hi.z - 0.01:
			out.append(Vector2(minf(x + 0.5, (x + b.hi.x) * 0.5), minf(z + 0.5, (z + b.hi.z) * 0.5)))
			z += 1.0
		x += 1.0
	return out


## The studs of `part`: on every living brick's top, where no living brick sits.
func _lay_studs(part: int) -> void:
	var xs: Array[Transform3D] = []
	var cs: Array[Color] = []
	for b in bricks:
		if not b.alive or b.part != part:
			continue
		for c in _stud_cells(b):
			var above: Brick = _cells[part].get(Vector3i(roundi(c.x * 2.0), roundi(b.hi.y), roundi(c.y * 2.0)))
			if above != null and above.alive:
				continue
			xs.append(Transform3D(Basis(), Vector3(c.x * STUD, b.hi.y * PLATE, c.y * STUD)))
			cs.append(b.color)
	var mm := _studs[part].multimesh
	mm.instance_count = xs.size()
	for i in xs.size():
		mm.set_instance_transform(i, xs[i])
		mm.set_instance_color(i, cs[i])


## A brick in the air: off the vehicle, tumbling, gone in FLY_LIFE.
func _fly(b: Brick, world: Vector3, from: Vector3) -> void:
	if _flying >= FLYING_MAX or not vehicle.is_inside_tree():
		return
	var parent := vehicle.get_parent()
	if parent == null:
		return
	var body := RigidBody3D.new()
	body.name = "LooseBrick"
	body.collision_layer = 0
	body.collision_mask = Layers.WORLD | Layers.STRUCTURE | Layers.DEBRIS
	body.mass = 2.0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = b.size
	shape.shape = box
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	mi.mesh = PieceMeshes.chamfered_box(b.size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = b.color
	mi.material_override = mat
	body.add_child(mi)
	parent.add_child(body)
	body.global_transform = Transform3D(parts[b.part].global_basis, world)
	var away := world - from
	away.y = maxf(away.y, 0.0)
	away = away.normalized() if away.length() > 0.01 else Vector3.UP
	var cv := vehicle as CharacterBody3D
	body.linear_velocity = away * rng.randf_range(2.5, 5.0) + Vector3.UP * rng.randf_range(2.0, 4.0) \
			+ (cv.velocity if cv != null else Vector3.ZERO)
	body.angular_velocity = Vector3(rng.randf_range(-6, 6), rng.randf_range(-6, 6), rng.randf_range(-6, 6))
	_flying += 1
	body.tree_exiting.connect(func() -> void: _flying -= 1)
	body.get_tree().create_timer(FLY_LIFE).timeout.connect(func() -> void:
		if is_instance_valid(body):
			body.queue_free())
