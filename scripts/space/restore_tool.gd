class_name RestoreTool
extends RefCounted
## Repair (Docs/Hulls.md 9), both front ends on one button and one core:
##
## * **Brick by brick (front end A):** aimed at a hole in a ship's or station's
##   hull, the one lost brick it would lay shows as a ghost of the original (its
##   own cells, `aimed`) -- the rim brick nearest where it points. A tap lays that
##   brick and no other.
## * **The restore tool (front end B -- Red Faction: Armageddon's Reconstructor):**
##   held past HOLD, the bricks lost within RADIUS of where it points come back, the
##   ones at the hole's edge first (SpaceStation.restorable), RATE a second.
##
## Each is a RESTORE command (SpaceStation.restore), so it records, saves and
## replays as a hit does.
##
## What a brick costs (Docs/Hulls.md 9.3, a guess the user asked for): one brick
## from a pouch of POUCH, `cost` (-1: no limit, the probes' default). Aboard a ship
## or station the pouch fills again from its stores, REFILL a second, once the tool
## has been idle REFILL_AFTER seconds (`refill`) -- so a crew patches from what it
## carries in a fight and tops up between fights.
##
## Each brick laid pops into place with a snap (RepairFx), when `fx_parent` is set.

## How far it reaches, metres along the view.
const RANGE := 6.0
## How far round the aim point it gathers lost bricks, metres.
const RADIUS := 2.5
## Bricks a second.
const RATE := 8.0
## Held longer than this, seconds, it is the restore tool; a shorter press is a tap.
const HOLD := 0.25
## How far off the view's ray a brick may be to be the one a tap lays, metres.
const PICK := 1.0
## The ghost is looked for again this often, seconds.
const AIM_EVERY := 0.1
## Bricks a full pouch holds.
const POUCH := 120
## Bricks a second back into the pouch aboard, after the tool has been idle this long.
const REFILL := 4.0
const REFILL_AFTER := 2.0
## Pops at most for one tick's bricks (the rest are laid quietly).
const FX_PER_TICK := 3

var cost := -1
## While held: the ship or station it is working on, and bricks laid this hold.
var target: SpaceStation = null
var laid := 0
var _owed := 0.0
var _held := 0.0
## The brick a tap would lay: {station, id, xf} (xf: a unit box, centred, onto its
## cells in the world), or empty.
var aimed := {}
var _aim_wait := 0.0
var _ghost: Node3D = null
var _ghost_key := ""
var _ghost_mat: StandardMaterial3D
var _pulse := 0.0
## Effects: where they are drawn (null: none -- the probes), and what draws them.
var fx_parent: Node = null
var fx := RepairFx.new()
var _idle := 0.0
var _refill_owed := 0.0
## Brick shapes made so far: "part|colour|material" -> [ArrayMesh, studs buffer].
static var _shapes := {}
static var _scratch: BrickWorld = null
static var _scratch_pal: Dictionary = {}


## One frame. `from` and `dir` are the view (world); `holding` is the button.
## `structures` are the ships and stations to look in. Returns the bricks laid.
func tick(dt: float, holding: bool, from: Vector3, dir: Vector3, structures: Array,
		space: PhysicsDirectSpaceState3D = null) -> int:
	if holding or _held > 0.0:
		_idle = 0.0
	if not holding:
		var tapped := _held > 0.0 and _held < HOLD
		_held = 0.0
		target = null
		laid = 0
		_owed = 0.0
		if tapped:
			# The tap: the brick its ghost showed, looked for again now (a ghost a
			# tenth of a second old may have been laid by someone else).
			aim(from, dir, structures, space)
			return place_aimed()
		return 0
	_held += dt
	if _held < HOLD:
		return 0
	# Round the first lost brick along the view (a hole's own), else where it meets.
	var at := aim_point(from, dir, space)
	if not aim(from, dir, structures, space).is_empty():
		at = (aimed.xf as Transform3D).origin
	_owed = minf(_owed + RATE * dt, RATE)
	var n := int(_owed)
	if n <= 0:
		return 0
	for s in structures:
		var st := s as SpaceStation
		# Flown, it is worked on through its ghost (Docs/Hulls.md 7b).
		if st == null or not st.bricked or (st.riding and st.ghost == null):
			continue
		var ids := st.restorable(at, RADIUS)
		if ids.is_empty():
			continue
		if cost >= 0:
			n = mini(n, cost)
		if n <= 0:
			return 0
		var back := st.restore(ids.slice(0, n), at, RADIUS)
		_laid_fx(st, back)
		_owed -= float(n)
		target = st
		laid += back.size()
		if cost >= 0:
			cost -= back.size()
		return back.size()
	_owed = 0.0
	target = null
	return 0


## The brick a tap would lay where the view points (`aimed`): of the lost bricks
## within PICK of the view's ray (never past what it meets) and beside a brick
## still there, the nearest along it, then nearest it (the score: along + twice
## off) -- a brick laid against nothing could not be placed
## by hand. Along the ray, not round where it meets: aimed into a hole, the ray
## goes on through it, and the hole's own bricks are the ones wanted. Empty if
## none.
func aim(from: Vector3, dir: Vector3, structures: Array, space: PhysicsDirectSpaceState3D = null) -> Dictionary:
	aimed = {}
	var d := dir.normalized()
	var reach := (aim_point(from, d, space) - from).length() + PICK * 0.5
	var mid := from + d * (reach * 0.5)
	var best := INF
	for s in structures:
		var st := s as SpaceStation
		if st == null or not st.bricked or st.air == null or (st.riding and st.ghost == null):
			continue
		if not st.holds(mid) and (st.global_position - mid).length() > 400.0:
			continue
		for b in st.restorable(mid, reach * 0.5 + PICK, false):
			var xf := box_of(st, b)
			var t := clampf((xf.origin - from).dot(d), 0.0, reach)
			if t >= best:
				continue
			# How far the ray passes from the brick's box.
			var p := from + d * t
			var q := (xf.affine_inverse() * p).clamp(-Vector3.ONE * 0.5, Vector3.ONE * 0.5)
			var off := ((xf * q) - p).length()
			# The nearest along the view, then the nearest the ray: aimed at the
			# middle of a hole, its rim's brick closest to the line.
			var score := t + 2.0 * off
			if off > PICK or score >= best or not rim_of(st, b):
				continue
			best = score
			aimed = {"station": st, "id": b, "xf": xf}
	return aimed


## The button is down (a tap or a hold under way).
func pressed() -> bool:
	return _held > 0.0


## Lay `aimed`'s brick (one; it costs one). Returns the bricks laid: 0 or 1.
func place_aimed() -> int:
	if aimed.is_empty() or cost == 0:
		return 0
	var st := aimed.station as SpaceStation
	if not is_instance_valid(st):
		aimed = {}
		return 0
	var at: Vector3 = (aimed.xf as Transform3D).origin
	var back := st.restore(PackedInt32Array([int(aimed.id)]), at, 0.0)
	_laid_fx(st, back)
	if cost > 0:
		cost -= back.size()
	aimed = {}
	return back.size()


## Brick `b` of `st` is beside one of its bricks that is there.
static func rim_of(st: SpaceStation, b: int) -> bool:
	var own := {}
	var cells := st.air._block_cells(b)
	for i in cells:
		own[i] = true
	for i in cells:
		for j in st.air._neighbours(i):
			if st.air.state[j] == HullAir.SOLID and not own.has(j):
				return true
	return false


## A unit box (centred on the origin) onto brick `b`'s cells, in the world.
static func box_of(st: SpaceStation, b: int) -> Transform3D:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := -lo
	for i in st.air._block_cells(b):
		var c := st.air._cell(i)
		lo = lo.min(c)
		hi = hi.max(c)
	var cell := BrickWorld.get_cell_size()
	var size := Vector3(hi - lo + Vector3i.ONE) * cell
	var mid := Vector3(lo) * cell + size * 0.5
	return st.global_transform * st.frame * Transform3D(Basis.from_scale(size), mid)


## The pouch filling again: `aboard` a ship or station (its stores), once the tool
## has been idle REFILL_AFTER seconds. Returns bricks added.
func refill(dt: float, aboard: bool) -> int:
	_idle += dt
	if cost < 0 or not aboard or _idle < REFILL_AFTER or cost >= POUCH:
		_refill_owed = 0.0
		return 0
	_refill_owed += REFILL * dt
	var n := mini(int(_refill_owed), POUCH - cost)
	_refill_owed -= float(n)
	cost += n
	return n


## Pops and snaps for bricks `back` of `st`, a few a tick.
func _laid_fx(st: SpaceStation, back: PackedInt32Array) -> void:
	if fx_parent == null or back.is_empty():
		return
	for k in mini(back.size(), FX_PER_TICK):
		var b := back[k]
		var shape := shape_of(st, b)
		var box := box_of(st, b)
		if shape.is_empty():
			fx.laid(fx_parent, null, box, box.origin)
		else:
			fx.laid(fx_parent, shape[0], place_of(st, b), box.origin)


## Brick `b` of `st` as it was built: [its mesh (bevelled as the near tier draws
## bricks, its colours in its vertices), its studs (a MultiMesh buffer)], made once
## per part, colour and material in a scratch world of its own. Empty if its
## recipe entry is not known.
static func shape_of(st: SpaceStation, b: int) -> Array:
	var ri := _recipe_id(st, b)
	if ri < 0:
		return []
	var r := st.air._recipe
	var key := "%s|%d|%d" % [r.part_of(ri), r.colour_of(ri), r.material_of(ri)]
	if _shapes.has(key):
		return _shapes[key]
	if _scratch == null:
		_scratch = BrickWorld.new()
		_scratch_pal = TowerRecipe.bake_palette(_scratch)
	var one := BuildRecipe.new()
	one.add(r.part_of(ri), Vector3i.ZERO, r.colour_of(ri), 0, false, r.material_of(ri))
	var asm := Assembly.new(_scratch, _scratch_pal)
	one.build_into(asm, _scratch_pal)
	var out: Array = []
	if not asm.frames.is_empty():
		var f: int = asm.frames[0]
		var arrays := _scratch.build_chunk_chamfer_mesh(f, BrickNear.BEVEL) if BrickNear.enabled \
				else _scratch.build_chunk_mesh(f)
		if arrays.size() > 0 and not (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			out = [m, _scratch.get_chunk_studs(f)]
	_shapes[key] = out
	return out


static func _recipe_id(st: SpaceStation, b: int) -> int:
	if st.air == null or st.air._recipe == null or b < 0 or b >= st.air._block_recipe.size():
		return -1
	return st.air._block_recipe[b]


## Where brick `b`'s shape (shape_of: built at cell 0) goes, in the world.
static func place_of(st: SpaceStation, b: int) -> Transform3D:
	var ri := _recipe_id(st, b)
	var base := st.air._recipe.cell_of(ri) - st.air._origin
	return st.global_transform * st.frame * Transform3D(Basis(), Vector3(base) * BrickWorld.get_cell_size())


## One frame of the ghost: looked for every AIM_EVERY while nothing is held (`show`
## off: hidden), drawn under `parent` -- the brick itself, as built (shape_of), see-
## through and gently pulsing; a box on its cells if its shape is not known.
func show_ghost(dt: float, show: bool, from: Vector3, dir: Vector3, structures: Array,
		space: PhysicsDirectSpaceState3D, parent: Node) -> void:
	fx.tick(dt)
	if not show or _held >= HOLD:
		if _ghost != null:
			_ghost.visible = false
		return
	_aim_wait -= dt
	if _aim_wait <= 0.0:
		_aim_wait = AIM_EVERY
		aim(from, dir, structures, space)
	elif not aimed.is_empty() and is_instance_valid(aimed.station):
		# The hull moves (a ship flies): its box follows every frame.
		aimed.xf = box_of(aimed.station, int(aimed.id))
	if aimed.is_empty():
		if _ghost != null:
			_ghost.visible = false
		return
	var st := aimed.station as SpaceStation
	var b := int(aimed.id)
	var shape := shape_of(st, b)
	var key := "box" if shape.is_empty() else str((shape[0] as Object).get_instance_id())
	if _ghost == null:
		_ghost = Node3D.new()
		_ghost.name = "PatchGhost"
		_ghost.top_level = true
		_ghost_mat = StandardMaterial3D.new()
		_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_mat.vertex_color_use_as_albedo = true
		_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if key != _ghost_key:
		_ghost_key = key
		for c in _ghost.get_children():
			c.queue_free()
		var mi := MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = _ghost_mat
		if shape.is_empty():
			mi.mesh = BoxMesh.new()
		else:
			mi.mesh = shape[0]
			var studs: PackedFloat32Array = shape[1]
			@warning_ignore("integer_division")
			var n := studs.size() / 16
			if n > 0:
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = true
				mm.mesh = PieceMeshes.stud()
				mm.instance_count = n
				mm.set_buffer(studs)
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				mmi.material_override = _ghost_mat
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.add_child(mmi)
		_ghost.add_child(mi)
	if _ghost.get_parent() != parent:
		if _ghost.get_parent() != null:
			_ghost.get_parent().remove_child(_ghost)
		parent.add_child(_ghost)
	# Its own colours, lifted toward a pale blue, see-through and pulsing.
	_pulse += dt
	_ghost_mat.albedo_color = Color(1.15, 1.35, 1.6, 0.42 + 0.14 * sin(_pulse * TAU * 1.2))
	_ghost.global_transform = box_of(st, b) if shape.is_empty() else place_of(st, b)
	_ghost.visible = true


func free_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
		_ghost_key = ""
	fx.clear()


## Where it points: what the view ray meets within RANGE, or RANGE along it (a
## hole has nothing to meet -- the bricks it would hit are the lost ones).
static func aim_point(from: Vector3, dir: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
	var to := from + dir.normalized() * RANGE
	if space != null:
		# Bricks only: never the pawn the view is in. Through a flown ship's ghost,
		# never its shell box (ShipRays).
		var q := PhysicsRayQueryParameters3D.create(from, to, Layers.STRUCTURE)
		var hit := ShipRays.cast(space, q)
		if not hit.is_empty():
			return hit.position
	return to
