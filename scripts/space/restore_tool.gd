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
## What a brick costs is a design value nobody has picked yet (Docs/Hulls.md 13);
## `cost` is how many it may still lay (-1: no limit), for when it is.

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
var _ghost: MeshInstance3D = null


## One frame. `from` and `dir` are the view (world); `holding` is the button.
## `structures` are the ships and stations to look in. Returns the bricks laid.
func tick(dt: float, holding: bool, from: Vector3, dir: Vector3, structures: Array,
		space: PhysicsDirectSpaceState3D = null) -> int:
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


## One frame of the ghost: looked for every AIM_EVERY while nothing is held (`show`
## off: hidden), drawn under `parent`.
func show_ghost(dt: float, show: bool, from: Vector3, dir: Vector3, structures: Array,
		space: PhysicsDirectSpaceState3D, parent: Node) -> void:
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
	if _ghost == null:
		_ghost = MeshInstance3D.new()
		_ghost.name = "PatchGhost"
		var box := BoxMesh.new()
		box.size = Vector3.ONE * 1.04
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.45, 0.85, 1.0, 0.35)
		m.no_depth_test = false
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		box.material = m
		_ghost.mesh = box
		_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghost.top_level = true
	if _ghost.get_parent() != parent:
		if _ghost.get_parent() != null:
			_ghost.get_parent().remove_child(_ghost)
		parent.add_child(_ghost)
	_ghost.global_transform = aimed.xf
	_ghost.visible = true


func free_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null


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
