class_name BuildDoors
extends Node3D

## Doors in a build's doorways (Docs/RoomModules.md 3.2): a leaf hung in each
## door hole of every build that is bricks, swung open when a figure comes near
## and shut again when it has gone, dropped when the wall over it is shot away.
##
## A door is the one thing in a building that moves, so it is not a brick in the
## grid (a fixture is, Fixture's own notes): it is a node that follows its
## building's chunk. Where the doors are is the recipe's:
##
##   meta["doors"]   [{"lo": [x, y, z], "size": [sx, sy, sz], "colour", "material"}]
##                   the hole's box in the build's cells -- what the generators
##                   (RoomGrow, RoomShell) put in joined doorways
##   an opening of kind "door" in meta["structure"] (set by hand in the spaces
##   tool): its cells' box
##
## The leaf runs along the longer of the box's two flat sides, hinged at its low
## end, as high as the hole less a plate, and stands in the middle of the
## wall's depth.
##
## `sources` says which builds have bricks: a Callable returning
## [[key, chunk, recipe, rebase]] -- the city's registry (from_registry), the
## workshop's one build.

## How near a figure comes before a door opens, metres from its middle.
const REACH := 1.6
## How far it swings, and how fast (radians a second).
const SWING := PI * 0.5
const SPEED := 4.0
## A leaf's thickness, in studs.
const THICK := 0.3
## How often the builds and the walls over the doors are looked at again, seconds.
const RESYNC := 0.5

var world: BrickWorld
var sources: Callable
## On a vehicle (a ship, SpaceStation): its doors are its children, not the world's.
## Set, each leaf hangs at `local_frame` * its place, under this node -- which is
## the vehicle's child -- so it turns and flies with it, drawn with it every frame,
## and is never placed from the chunk's transform (which a parked or flown ship
## does not keep up to date). Unset (the city, the workshop): from the chunk.
var follow_parent := false
var local_frame := Transform3D()
## Its ghost hull (Docs/Hulls.md 7b): each leaf has a twin box in `ghost_space` at
## `ghost_frame` * its place, swung with it, so whoever walks the ghost meets a shut
## door as a wall. RID() for none.
var ghost_space := RID()
var ghost_frame := Transform3D()
## World points of figures the areas cannot see (crew on the ghost, whose bodies
## are not in the world): a door opens for them too. Optional.
var figures := Callable()
## key -> {chunk, sig, leaves: [{frame: Node3D, hinge, area, at, angle, open, lintel: Vector3i}]}
var _builds := {}
var _since := 0.0


## The doors of a recipe as boxes: [{lo: Vector3i, size: Vector3i, colour, material}].
static func of(r: BuildRecipe) -> Array:
	var out := []
	for d: Dictionary in r.meta.get("doors", []):
		out.append({"lo": BuildRecipe.cell_from(d.lo), "size": BuildRecipe.cell_from(d.size),
				"colour": int(d.get("colour", default_colour())), "material": int(d.get("material", 0))})
	var rec: Dictionary = r.meta.get("structure", {})
	for o: Dictionary in rec.get("openings", []):
		if String(o.kind) != "door" or (o.cells as Array).is_empty():
			continue
		var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
		var hi := -lo
		for c in o.cells:
			var v := Vector3i(int(c[0]), int(c[1]), int(c[2]))
			lo = Vector3i(mini(lo.x, v.x), mini(lo.y, v.y), mini(lo.z, v.z))
			hi = Vector3i(maxi(hi.x, v.x), maxi(hi.y, v.y), maxi(hi.z, v.z))
		out.append({"lo": lo, "size": hi - lo + Vector3i.ONE, "colour": default_colour(), "material": 0})
	return out


## A door record for meta["doors"]: the hole's box.
static func record(lo: Vector3i, size: Vector3i, colour := -1, material := 0) -> Dictionary:
	return {"lo": [lo.x, lo.y, lo.z], "size": [size.x, size.y, size.z],
			"colour": default_colour() if colour < 0 else colour, "material": material}


## The hole a doorway `w` x `h` makes through a wall `depth` thick, whose outer
## face is `at` (a connector's: the low corner of its bottom row, one past the
## wall) facing `facing`: its box [lo, size].
static func hole(at: Vector3i, facing: int, w: int, h: int, depth: int) -> Array:
	var fd: Vector2i = StructureSpaces.FACINGS[facing]
	var d := Vector3i(fd.x, 0, fd.y)
	var across := Vector3i(absi(fd.y), 0, absi(fd.x))
	var k := maxi(depth, 1)
	var a := at - d
	var b := at - d * k + across * (w - 1) + Vector3i(0, h - 1, 0)
	var lo := Vector3i(mini(a.x, b.x), mini(a.y, b.y), mini(a.z, b.z))
	var hi := Vector3i(maxi(a.x, b.x), maxi(a.y, b.y), maxi(a.z, b.z))
	return [lo, hi - lo + Vector3i.ONE]


## A door's colour when nobody said: the palette's first brown, a door's wood.
static var _brown := -2


static func default_colour() -> int:
	if _brown == -2:
		_brown = 0
		for i in BrickWorld.get_material_colour_count(0):
			if BrickWorld.get_material_colour_name(0, i).to_lower().contains("brown"):
				_brown = i
				break
	return _brown


## The city's builds that are bricks now, from its registry (BuildLifts asks
## the same).
static func from_registry(registry: BuildingRegistry) -> Callable:
	return func() -> Array:
		var out := []
		for b in registry.buildings:
			if b.build == null or b.chunk < 0 or b.toppled or not b.frames.is_empty():
				continue
			if not b.build.meta.has("doors") and not b.build.meta.has("structure") 					and not b.build.meta.has("lifts"):
				continue
			out.append([b.id, b.chunk, b.build, b.build.origin()])
		return out


func _init(w: BrickWorld = null, src := Callable()) -> void:
	world = w
	sources = src
	name = "BuildDoors"


func _physics_process(delta: float) -> void:
	if world == null or not sources.is_valid():
		return
	_since += delta
	if _since >= RESYNC:
		_since = 0.0
		resync()
	for key in _builds:
		var e: Dictionary = _builds[key]
		var xf := world.get_chunk_transform(int(e.chunk))
		for lf: Dictionary in e.leaves:
			var want := SWING if bool(lf.open) else 0.0
			lf.angle = move_toward(float(lf.angle), want, SPEED * delta)
			if follow_parent:
				(lf.frame as Node3D).transform = local_frame * (lf.at as Transform3D)
			else:
				(lf.frame as Node3D).global_transform = xf * (lf.at as Transform3D)
			(lf.hinge as Node3D).transform = Transform3D(Basis(Vector3.UP, float(lf.angle)))
			_ghost_place(lf)


## The builds looked at again: doors hung in builds that came, taken out of
## those that went, each door opened or shut by who is near, hidden while the
## brick over it is gone.
func resync() -> void:
	var seen := {}
	for s: Array in sources.call():
		var key = s[0]
		var chunk: int = s[1]
		var r: BuildRecipe = s[2]
		var rebase: Vector3i = s[3]
		seen[key] = true
		var doors := of(r)
		var sig := "%d %d %s" % [chunk, r.size(), str(doors)]
		var e: Dictionary = _builds.get(key, {})
		if e.is_empty() or String(e.sig) != sig:
			_drop(key)
			e = {"chunk": chunk, "sig": sig, "leaves": []}
			var xf := world.get_chunk_transform(chunk)
			for d: Dictionary in doors:
				e.leaves.append(_hang(d, rebase, xf))
			_builds[key] = e
	for key in _builds.keys():
		if not seen.has(key):
			_drop(key)
	for key in _builds:
		var e: Dictionary = _builds[key]
		var chunk := int(e.chunk)
		for lf: Dictionary in e.leaves:
			# No brick over it -- shot away, or a storey not laid yet: no door.
			var up := world.is_solid(chunk, lf.lintel)
			var frame: Node3D = lf.frame
			if frame.visible != up:
				frame.visible = up
				frame.process_mode = Node.PROCESS_MODE_INHERIT if up else Node.PROCESS_MODE_DISABLED
				var gb: RID = lf.get("ghost", RID())
				if gb.is_valid():
					PhysicsServer3D.body_set_shape_disabled(gb, 0, not up)
			lf.open = up and _near(lf)


## Build `key`'s doors, in `of`'s order: open (swung, or its leaf gone with the wall
## over it -- a doorway with no door), for the air (HullAir.set_door). Empty when
## it has none hung.
func open_states(key) -> Array:
	var out := []
	for lf: Dictionary in _builds.get(key, {}).get("leaves", []):
		out.append(bool(lf.open) or not (lf.frame as Node3D).visible)
	return out


## Doors hung and standing (not hidden under a missing lintel).
func count() -> int:
	var n := 0
	for key in _builds:
		for lf: Dictionary in _builds[key].leaves:
			if (lf.frame as Node3D).visible:
				n += 1
	return n


func _drop(key) -> void:
	if not _builds.has(key):
		return
	for lf: Dictionary in _builds[key].leaves:
		(lf.frame as Node).queue_free()
		_ghost_free(lf)
	_builds.erase(key)


func _exit_tree() -> void:
	for key in _builds:
		for lf: Dictionary in _builds[key].leaves:
			_ghost_free(lf)


## A leaf's twin in the ghost, where it stands and how far it is swung.
func _ghost_place(lf: Dictionary) -> void:
	var gb: RID = lf.get("ghost", RID())
	if not gb.is_valid():
		return
	PhysicsServer3D.body_set_state(gb, PhysicsServer3D.BODY_STATE_TRANSFORM,
			ghost_frame * (lf.at as Transform3D) * Transform3D(Basis(Vector3.UP, float(lf.angle))))


func _ghost_free(lf: Dictionary) -> void:
	var gb: RID = lf.get("ghost", RID())
	if gb.is_valid():
		PhysicsServer3D.free_rid(gb)
		PhysicsServer3D.free_rid(lf.ghost_shape)
		lf.ghost = RID()


## A figure (any CharacterBody3D) near the door's middle.
func _near(lf: Dictionary) -> bool:
	var area: Area3D = lf.area
	for b in area.get_overlapping_bodies():
		if b is CharacterBody3D:
			return true
	if figures.is_valid():
		var inv := (lf.frame as Node3D).global_transform.affine_inverse()
		var box: AABB = lf.reach
		for p: Vector3 in figures.call():
			if box.has_point(inv * p):
				return true
	return false


## One leaf: a frame at the hole's low end in the chunk's cells (following the
## chunk), a hinge on it, the leaf a box off the hinge along the wall with a
## body that stops what a shut door stops, and an area round the doorway that
## opens it.
func _hang(d: Dictionary, rebase: Vector3i, xf: Transform3D) -> Dictionary:
	var cell := BrickWorld.get_cell_size()
	var lo: Vector3i = (d.lo as Vector3i) - rebase
	var size: Vector3i = d.size
	var along_x := size.x >= size.z
	var w := (size.x if along_x else size.z) * (cell.x if along_x else cell.z)
	var depth := (size.z if along_x else size.x) * (cell.z if along_x else cell.x)
	var h := maxf(size.y - 1, 1) * cell.y
	var t := THICK * cell.x
	# The hinge: the hole's low corner, the middle of the wall's depth.
	var base := Vector3(lo.x * cell.x, lo.y * cell.y, lo.z * cell.z)
	base += Vector3(0, 0, depth * 0.5) if along_x else Vector3(depth * 0.5, 0, 0)
	var at := Transform3D(Basis() if along_x else Basis(Vector3.UP, -PI * 0.5), base)
	var frame := Node3D.new()
	add_child(frame)
	if follow_parent:
		frame.transform = local_frame * at
	else:
		frame.global_transform = xf * at
	var hinge := Node3D.new()
	frame.add_child(hinge)
	var body := AnimatableBody3D.new()
	body.sync_to_physics = false
	hinge.add_child(body)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w - 0.02, h, t)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BrickWorld.get_material_colour(int(d.material), int(d.colour))
	bm.material = mat
	mi.mesh = bm
	mi.position = Vector3(w * 0.5, h * 0.5, 0)
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = bm.size
	cs.shape = shape
	cs.position = mi.position
	body.add_child(cs)
	# Who opens it: a box round the doorway, out to REACH either side.
	var area := Area3D.new()
	area.monitorable = false
	area.collision_mask = 0xFFFFFFFF
	var acs := CollisionShape3D.new()
	var ab := BoxShape3D.new()
	ab.size = Vector3(w + REACH, h, REACH * 2.0)
	acs.shape = ab
	acs.position = Vector3(w * 0.5, h * 0.5, 0)
	area.add_child(acs)
	frame.add_child(area)
	# The brick over the middle of the doorway: gone, and the door goes with it.
	@warning_ignore("integer_division")
	var mid := (size.x if along_x else size.z) / 2
	var lintel := lo + Vector3i(mid if along_x else 0, size.y, 0 if along_x else mid)
	var out := {"frame": frame, "hinge": hinge, "area": area, "at": at, "angle": 0.0, "open": false,
			"lintel": lintel, "reach": AABB(acs.position - ab.size * 0.5, ab.size)}
	if ghost_space.is_valid():
		var gb := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(gb, PhysicsServer3D.BODY_MODE_KINEMATIC)
		PhysicsServer3D.body_set_collision_layer(gb, body.collision_layer)
		PhysicsServer3D.body_set_collision_mask(gb, 0)
		var gs := PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(gs, shape.size * 0.5)
		PhysicsServer3D.body_add_shape(gb, gs, Transform3D(Basis(), cs.position))
		PhysicsServer3D.body_set_space(gb, ghost_space)
		out.ghost = gb
		out.ghost_shape = gs
		_ghost_place(out)
	return out
