extends SceneTree

## Test 7 of the sphere-planet feasibility tests (Docs/Planets.md 10b): two
## physics spaces in one process -- the co-op answer for players far apart, a
## second World3D (and so a second Jolt PhysicsSystem) in a viewport that draws
## nothing.
##
##   --headless --fixed-fps 30 --path . --script res://tools/planet_spaces_probe.gd
##       -- --mode=check     the two do not touch (same coordinates, both full)
##       -- --mode=a|ab|a2|a0  the cost: N bodies in one space; N in each of
##                           two; 2N in one (two piles side by side); N and an
##                           empty second space -- frames run flat out, timed
##
## A pile of boxes is dropped onto a floor in each space AT THE SAME PLACE. If
## the spaces shared anything the two piles would land on each other; each
## must instead come to rest exactly as the other does.

const N := 400

var mode := "check"
var spaces: Array = []    # [world node, bodies]
var frame := 0
var t0 := 0
var marks := {}


func _initialize() -> void:
	pass


## On the first tick, once the root is in its world.
func _setup() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.trim_prefix("--mode=")
	var main := Node3D.new()
	root.add_child(main)
	var counts: Array = []
	match mode:
		"a":
			counts = [N]
		"a2":
			counts = [N * 2]
		"a0":
			counts = [N, 0]
		_:
			counts = [N, N]
	for i in counts.size():
		var parent: Node = main
		if i > 0:
			# The second space: a World3D of its own, in a viewport that never
			# draws (UPDATE_DISABLED) -- physics only.
			var vp := SubViewport.new()
			vp.own_world_3d = true
			vp.world_3d = World3D.new()
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			vp.size = Vector2i(2, 2)
			root.add_child(vp)
			parent = vp
		spaces.append([parent, _pile(parent, counts[i])])
	print("[spaces] mode %s: %d space(s), %s bodies; space RIDs %s" % [
			mode, spaces.size(), counts, _space_rids()])
	t0 = Time.get_ticks_usec()


func _space_rids() -> Array:
	var out := []
	for sp in spaces:
		var n: Node = sp[0]
		var w: World3D = (n as Node3D).get_world_3d() if n is Node3D else (n as Viewport).world_3d
		out.append(w.space.get_id())
	return out


## A floor and `count` boxes over it in a 10 x 10 grid of columns.
func _pile(parent: Node, count: int) -> Array[RigidBody3D]:
	var floor_body := StaticBody3D.new()
	var fcs := CollisionShape3D.new()
	fcs.shape = WorldBoundaryShape3D.new()
	floor_body.add_child(fcs)
	parent.add_child(floor_body)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.7, 0.42, 0.7)
	var out: Array[RigidBody3D] = []
	for i in count:
		var b := RigidBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = shape
		b.add_child(cs)
		parent.add_child(b)
		var col := i % 100
		# Past the first N, a second pile beside the first: a2 holds the bodies
		# two spaces would, in one, without stacking them on each other.
		var side := 20.0 * (i / N)
		var layer := (i % N) / 100
		b.position = Vector3(side + (col % 10) * 0.9, 0.5 + 0.6 * layer, (col / 10) * 0.9) \
				+ Vector3(0.05 * sin(i * 1.7), 0.0, 0.05 * cos(i * 2.3))
		out.append(b)
	return out


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		_setup()
		return false
	if frame == 150:
		marks.active = Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
	if frame == 450:
		marks.quiet = Time.get_ticks_usec() - t0
		_finish()
		return true
	return false


func _finish() -> void:
	var asleep := []
	for s in spaces:
		var n := 0
		for b in s[1]:
			if b.sleeping:
				n += 1
		asleep.append(n)
	print("[spaces] mode %s: ticks 1-150 (falling) %.2f ms a tick, 151-450 (piled) %.2f ms a tick; asleep %s" % [
			mode, marks.active / 150000.0, marks.quiet / 300000.0, asleep])
	if mode == "check" and spaces.size() == 2:
		# The same pile in each, at the same coordinates: identical if they never
		# met, which a shared space could not give.
		var worst := 0.0
		var a: Array = spaces[0][1]
		var b: Array = spaces[1][1]
		for i in a.size():
			worst = maxf(worst, (a[i] as Node3D).global_position.distance_to((b[i] as Node3D).global_position))
		var top := -INF
		for x in a:
			top = maxf(top, (x as Node3D).global_position.y)
		# A ray in the first space through where the second's boxes are: it
		# meets only the first's.
		var hit := (spaces[0][0] as Node3D).get_world_3d().direct_space_state.intersect_ray(
				PhysicsRayQueryParameters3D.create(Vector3(4.0, 20.0, 4.0), Vector3(4.0, -1.0, 4.0)))
		# Its own box or its own floor: anything whose parent is space 1's.
		var mine: bool = not hit.is_empty() and (hit.collider as Node).get_parent() == spaces[0][0]
		print("[spaces] two spaces, same coordinates: worst difference between the piles %.6f m; highest box %.2f m (a pile %d high would be %.2f); a ray in space 1 hits %s" % [
				worst, top, (N + 99) / 100, 0.42 * ((N + 99) / 100) - 0.21,
				("space 1's own %s" % hit.collider.get_class()) if mine else ("nothing" if hit.is_empty() else "space 2's body")])
		print("  %s the spaces do not touch" % ("ok  " if worst < 1e-4 and top < 0.42 * ((N + 99) / 100) + 0.5 and mine else "FAIL"))
