class_name RoomTactics
extends RefCounted
## The points a squad clears a room by (Docs/AI.md 3.3, 6.2): stack slots either
## side of an opening, the entry point just inside it, the room's corners -- the
## points of domination -- each with the sector it covers, and, when the door is
## the fatal funnel, where to make a door of its own (mouse-holing).
##
## Worked out from the room's box and its opening when a play needs them, not
## baked: an opening a squad blows in a wall is as good as a built one, and a
## wall shot full of holes is not the wall a bake saw.
##
## A room is its INTERIOR box -- inside the walls, floor to ceiling -- under a
## transform (a building's), so rooms in rotated buildings work alike. An opening
## is {"center": world point on the floor in the middle of the wall, "inward":
## horizontal unit vector into the room, "width": m, "thick": wall thickness m}.

## How far outside the wall face a stack stands, and the spacing along it.
const STACK_OUT := 0.55
const STACK_GAP := 0.7
## Corners are taken this far in from the walls.
const CORNER_IN := 0.6
## A breach: the charge's blast, centred this high off the floor.
const BREACH_RADIUS := 1.1
const BREACH_HEIGHT := 0.9
## Candidate breach points along a wall, and how far from a corner or an
## existing opening they must be.
const BREACH_STEP := 0.7
const BREACH_CLEAR := 1.3

var xf := Transform3D()
var box := AABB()
var id := 0


static func make(p_xf: Transform3D, p_box: AABB, p_id := 0) -> RoomTactics:
	var r := RoomTactics.new()
	r.xf = p_xf
	r.box = p_box
	r.id = p_id
	return r


func center() -> Vector3:
	return xf * (box.position + box.size * Vector3(0.5, 0.0, 0.5))


func contains(p: Vector3) -> bool:
	var l := xf.affine_inverse() * p
	return l.x >= box.position.x and l.x <= box.end.x and l.z >= box.position.z \
			and l.z <= box.end.z and l.y >= box.position.y - 0.5 and l.y <= box.end.y


static func right_of(opening: Dictionary) -> Vector3:
	return (opening.inward as Vector3).cross(Vector3.UP).normalized()


## Stack slots for `n` members, outside the opening, alternating left and right
## of it (facing in): [L1, R1, L2, R2, ...]. L1 and R1 are nearest the opening.
static func stack_slots(opening: Dictionary, n: int) -> Array[Vector3]:
	var c: Vector3 = opening.center
	var inn: Vector3 = opening.inward
	var r := right_of(opening)
	var out_face: Vector3 = c - inn * (float(opening.thick) * 0.5 + STACK_OUT)
	var half := float(opening.width) * 0.5
	var slots: Array[Vector3] = []
	for i in n:
		var side := -1.0 if i % 2 == 0 else 1.0
		var rank := i / 2
		slots.append(out_face + r * side * (half + 0.4 + rank * STACK_GAP))
	return slots


## Just inside the opening.
static func entry_point(opening: Dictionary) -> Vector3:
	return (opening.center as Vector3) + (opening.inward as Vector3) * (float(opening.thick) * 0.5 + 0.6)


## The four corners, named from the opening facing in:
## {"near_left", "near_right", "far_left", "far_right"} -> world point.
func corners(opening: Dictionary) -> Dictionary:
	var out := {}
	var c: Vector3 = opening.center
	var inn: Vector3 = opening.inward
	var r := right_of(opening)
	var lo := box.position + Vector3(CORNER_IN, 0.0, CORNER_IN)
	var hi := box.end - Vector3(CORNER_IN, 0.0, CORNER_IN)
	for x in [lo.x, hi.x]:
		for z in [lo.z, hi.z]:
			var p: Vector3 = xf * Vector3(x, box.position.y, z)
			var near := (p - c).dot(inn) < (center() - c).dot(inn)
			var right := (p - c).dot(r) > 0.0
			out[("near_" if near else "far_") + ("right" if right else "left")] = p
	return out


## The yaw a member in `corner` watches from: into the room. Swept +-SWEEP.
func sector_yaw(corner: Vector3) -> float:
	var to := center() - corner
	return atan2(-to.x, -to.z)


## Crisscross (AI.md 6.2): the first through, from the left of the stack, crosses
## to the far right corner; the second, from the right, crosses to the near left;
## the third buttonhooks to the far left; the fourth to the near right. Returns
## the corner for each stack position 0..n-1.
func crisscross(opening: Dictionary, n: int) -> Array[Vector3]:
	var cs := corners(opening)
	var order := ["far_right", "near_left", "far_left", "near_right"]
	var out: Array[Vector3] = []
	for i in n:
		out.append(cs[order[i % 4]])
	return out


## Where to blow a door of its own (mouse-holing): along the walls on the
## squad's side, at least BREACH_CLEAR from a corner and from `avoid` (the
## existing door, which the defender watches), the point scoring best on thin
## bricks and on the defender -- if one is known at `defender_eye` -- NOT seeing
## the inside of it. {} if the room has no wall facing the squad.
func breach(s: AIServices, squad_at: Vector3, avoid: Array, defender_eye: Vector3,
		thick: float) -> Dictionary:
	var best := {}
	var best_score := INF
	# The four walls: in local space, a point on each face and its outward normal.
	var faces := [
		[Vector3(box.position.x, 0, 0), Vector3.LEFT, "z"],
		[Vector3(box.end.x, 0, 0), Vector3.RIGHT, "z"],
		[Vector3(0, 0, box.position.z), Vector3.FORWARD, "x"],
		[Vector3(0, 0, box.end.z), Vector3.BACK, "x"],
	]
	for f in faces:
		var n_w: Vector3 = (xf.basis * (f[1] as Vector3)).normalized()
		var along: String = f[2]
		var from := box.position.z if along == "z" else box.position.x
		var to := box.end.z if along == "z" else box.end.x
		var u := from + BREACH_CLEAR
		while u <= to - BREACH_CLEAR:
			var lp: Vector3 = f[0]
			if along == "z":
				lp.z = u
			else:
				lp.x = u
			lp.y = box.position.y
			var inside: Vector3 = xf * lp
			u += BREACH_STEP
			if (squad_at - inside).dot(n_w) <= 0.0:
				continue   # a wall facing away from the squad
			var mid := inside + n_w * thick * 0.5
			var near_door := false
			for a in avoid:
				if (a as Vector3).distance_to(mid) < BREACH_CLEAR + 0.4:
					near_door = true
			if near_door:
				continue
			var chest := Vector3.UP * 1.1
			var bricks := s.ai_world.bricks_between(inside + n_w * (thick + 0.3) + chest,
					inside - n_w * 0.3 + chest)
			if bricks == 0:
				continue   # already open: that is a door, not a wall
			var score := float(bricks)
			if defender_eye != Vector3.INF:
				var sees := s.ai_world.bricks_between(defender_eye, inside - n_w * 0.4 + chest) == 0
				if sees:
					score += 3.0
				# Head-on to the defender is worse than oblique.
				var to_def := defender_eye - inside
				to_def.y = 0.0
				if to_def.length() > 0.1:
					score += maxf(0.0, (-n_w).dot(to_def.normalized())) * 1.5
			score += squad_at.distance_to(mid) * 0.08
			if score < best_score:
				best_score = score
				best = {"center": mid, "inward": -n_w, "width": 1.2, "thick": thick,
						"bricks": bricks}
	return best
