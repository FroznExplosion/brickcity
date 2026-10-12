class_name AimAssist
extends Node
## Aim assist for the player's own gun (Docs/Weapons/AIM_ASSIST.md). Four helpers, each
## its own strength, for the mouse and for a controller apart, all in Options > Aim Assist:
##
##   friction    the look turns slower over and near a target -- never moves the view
##   tracking    the view follows a target's MOTION across the screen (its strafe, or the
##               player's own): a target standing still is not pulled toward at all
##   centering   a gentle pull to the target's aim line -- only while the player is turning
##               or firing, never against the way the player turns
##   snap        starting to aim down the sights near a target closes part of the gap,
##               once, over the sights' rise
##   bullet      a round that would just miss is bent onto the aim line (GunController.bend)
##
## The AIM LINE: every target is a vertical segment, feet to top, and the assists aim for
## the nearest point on it to the crosshair. Anywhere between the feet and the head the
## vertical error is zero, so the assist only ever helps sideways -- a player going for
## the head keeps the head. The segment stands on the target's weak point nearest the
## crosshair among those FACING the player (CritSpots; a mech's hatch and power cell), or
## its middle when none faces. A weak point on the far side is never aimed for.
##
## Limited by the gun: past its class's assist range (WEAPONS) nothing helps -- a shotgun
## does not pull toward a man it cannot reach. Slow projectiles (the grenade tube) get more
## tracking and aim where the target will be (lead).
##
## Hip and sights blend by the sights' rise (PlayerView.ads_amount). Engagement: keeping a
## target in the cone while firing builds strength over ENGAGE_RISE seconds, lost fast.

enum Device { MOUSE, PAD }

# --- settings (Options > Aim Assist, BrickcityMenuHost). Static: one player. ---
## 0 off, 1 low, 2 medium, 3 high.
static var mouse_level := 2
static var pad_level := 2
static var snap_on_aim := true
static var friction_scale := 1.0
static var tracking_scale := 1.0
static var centering_scale := 1.0
static var bullet_scale := 1.0
static var snap_strength := 0.6
static var engage_on := true
static var range_limit := true
static var vertical_pull := false
static var weak_points := true
## Which hands are on the controls: the last look input decides.
static var device := Device.MOUSE

const LEVEL_MULT := [0.0, 0.6, 1.0, 1.5]
## [hip, sights] per device.
const FRICTION := [[0.15, 0.3], [0.35, 0.5]]
const TRACKING := [[0.25, 0.45], [0.45, 0.7]]
## Of the sideways error, closed per second while turning or firing.
const CENTERING := [[1.2, 2.5], [2.0, 4.0]]
## Degrees past a target's edge a round may still be bent onto it.
const BULLET_DEG := [[0.5, 0.8], [0.9, 1.3]]
## The cone round a target that the assists work in: its half-width times this, plus
## this many degrees. Wider from the hip, narrower down the sights.
const CONE_WIDTH := [2.5, 1.6]
const CONE_DEG := [2.5, 1.2]
## The snap: within this many half-widths of the line when the sights start up.
const SNAP_CONE := 2.5
const SNAP_TIME := 0.16
const ENGAGE_RISE := 0.5
const ENGAGE_FALL := 0.3
## Engaged, the tracking and centering are this much stronger.
const ENGAGE_BOOST := 0.5
const FRICTION_CAP := 0.8
## Assist range (m), tracking multiplier, projectile speed (m/s, 0 = hitscan) per class.
const WEAPONS := {
	&"pistol": [35.0, 1.0, 0.0], &"revolver": [40.0, 1.0, 0.0], &"smg": [28.0, 1.0, 0.0],
	&"rifle": [60.0, 1.0, 0.0], &"lmg": [55.0, 1.0, 0.0], &"dmr": [90.0, 1.0, 0.0],
	&"sniper": [150.0, 0.8, 0.0], &"shotgun": [14.0, 1.1, 0.0],
	&"rocket_launcher": [60.0, 1.3, 0.0], &"grenade_launcher": [40.0, 1.3, 0.0],
	&"arc_caster": [20.0, 1.0, 0.0],
}
const DEFAULT_WEAPON := [40.0, 1.0, 0.0]
## The grenade tube's lob (TubeGrenade): slow, so more tracking, and led.
const TUBE_WEAPON := [40.0, 1.5, 32.0]
## The range fades out over its last fifth.
const RANGE_FADE := 0.8

var camera: Camera3D
var gun: GunController
var player: PlayerController
var services: AIServices
## The pick this frame, {} for none: owner, point (aim-line point), err (yaw, pitch
## radians to it, + right, + up), half (half-width, radians), k (0..1 weight), dist.
var target: Dictionary = {}
var engagement := 0.0
## For a probe with no PlayerView: the sights' rise to use, or -1 for the view's.
var ads_override := -1.0

var _look_in := Vector2.ZERO
var _last_dir := Vector3.ZERO
var _last_owner: Object = null
var _ads_was := 0.0
var _snap_left := Vector2.ZERO
var _snap_time := 0.0


func setup(cam: Camera3D, g: GunController, p: PlayerController, s: AIServices) -> void:
	camera = cam
	gun = g
	player = p
	services = s
	name = "AimAssist"
	# After the camera has been put at the eye (PlayerController) this frame.
	process_priority = 100


func level() -> float:
	return LEVEL_MULT[clampi(pad_level if device == Device.PAD else mouse_level, 0, 3)]


func active() -> bool:
	return camera != null and gun != null and gun.gun != null and player != null \
			and player.is_possessing() and level() > 0.0


## The sights' rise, 0..1.
func ads() -> float:
	if ads_override >= 0.0:
		return ads_override
	return player.view.ads_amount() if player != null and player.view != null else 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).relative.length() > 0.5:
		device = Device.MOUSE
	elif event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.4:
		device = Device.PAD


## The look's turn this input, (yaw, pitch) radians, slowed over a target. The camera
## calls it with every mouse move (DebugCamera.assist).
func filter_look(d: Vector2) -> Vector2:
	_look_in += d
	if not active() or target.is_empty():
		return d
	var f := minf(_blend(FRICTION) * level() * friction_scale * float(target.k), FRICTION_CAP)
	return d * (1.0 - f)


func _blend(table: Array) -> float:
	var row: Array = table[device]
	return lerpf(float(row[0]), float(row[1]), ads())


## [range, tracking mult, projectile speed] for the gun in hand now.
func weapon() -> Array:
	if gun == null or gun.gun == null:
		return DEFAULT_WEAPON
	if gun.gun.alt_fire == GunAltFire.TUBE and gun.alt_on():
		return TUBE_WEAPON
	var id := gun.gun.weapon_class.id if gun.gun.weapon_class != null else &""
	return WEAPONS.get(id, DEFAULT_WEAPON)


func _process(delta: float) -> void:
	if not active():
		target = {}
		_last_owner = null
		_look_in = Vector2.ZERO
		_ads_was = ads()
		return
	var w := weapon()
	target = pick(w)
	var firing := gun.trigger_held()
	if engage_on and firing and not target.is_empty():
		engagement = minf(engagement + delta / ENGAGE_RISE, 1.0)
	else:
		engagement = maxf(engagement - delta / ENGAGE_FALL, 0.0)
	var turn := Vector2.ZERO
	var a := ads()
	if not target.is_empty():
		var lv := level()
		var boost := 1.0 + ENGAGE_BOOST * engagement
		var k := float(target.k)
		var err: Vector2 = target.err
		# Tracking: follow the line's motion across the view since last frame.
		var dir: Vector3 = (target.point as Vector3) - camera.global_position
		dir = dir.normalized()
		if target.owner == _last_owner and _last_dir != Vector3.ZERO:
			var moved := _angles(dir) - _angles(_last_dir)
			moved.x = wrapf(moved.x, -PI, PI)
			var tr := _blend(TRACKING) * lv * tracking_scale * float(w[1]) * boost * k
			turn += moved * minf(tr, 1.0)
		_last_dir = dir
		_last_owner = target.owner
		# Centering: only while the player turns or fires, and never against them.
		if _look_in.length() > 0.0001 or firing:
			var c := clampf(_blend(CENTERING) * lv * centering_scale * boost * k * delta, 0.0, 0.5)
			var cx := -err.x * c
			if _look_in.x * cx >= 0.0:
				turn.x += cx
			if vertical_pull:
				var cy := err.y * c
				if _look_in.y * cy >= 0.0:
					turn.y += cy
		# The snap: the sights starting up near the line close part of the gap.
		if snap_on_aim and _ads_was < 0.05 and a > 0.0 and player.pawn.intents.aim \
				and err.length() < float(target.half) * SNAP_CONE:
			_snap_left = Vector2(-err.x, err.y if vertical_pull else 0.0) * snap_strength * minf(lv, 1.0)
			_snap_time = SNAP_TIME
	else:
		_last_owner = null
		_last_dir = Vector3.ZERO
	if _snap_time > 0.0:
		var step := minf(delta / _snap_time, 1.0)
		turn += _snap_left * step
		_snap_left *= 1.0 - step
		_snap_time -= delta
	if not player.pawn.intents.aim:
		_snap_time = 0.0
	_ads_was = a
	_look_in = Vector2.ZERO
	if turn != Vector2.ZERO and camera.has_method(&"add_look"):
		camera.add_look(turn.x, turn.y)


## (yaw, pitch) of a world direction.
static func _angles(d: Vector3) -> Vector2:
	return Vector2(atan2(-d.x, -d.z), asin(clampf(d.y, -1.0, 1.0)))


# ------------------------------------------------------------------- targets

## The target the assists work on now: the one nearest the crosshair for its size,
## in range for the gun `w`, in sight. The last pick is kept unless another is clearly
## nearer (hysteresis).
func pick(w: Array = DEFAULT_WEAPON) -> Dictionary:
	var from := camera.global_position
	var team := player.pawn.team if player != null and player.pawn != null else 0
	var best := {}
	var best_score := INF
	var found: Array = []
	for o in candidates(team):
		var d := describe(o, from, w)
		if d.is_empty():
			continue
		var score := float(d.score) * (0.75 if o == _last_owner else 1.0)
		found.append([score, d])
	found.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	for i in mini(found.size(), 3):
		var d: Dictionary = found[i][1]
		if _in_sight(from, d):
			best = d
			best_score = float(found[i][0])
			break
	return best if best_score < 1.0 else {}


## Everything of another side that can be aimed at: pawns, mechs, tanks, trucks.
func candidates(team: int) -> Array:
	var out: Array = []
	if services != null:
		for p in services.pawns:
			if is_instance_valid(p) and p.team != team and not p.is_player \
					and p.health != null and not p.health.is_dead() and p.body != null \
					and p.body.is_inside_tree() and p.body.visible:
				out.append(p)
	var tree := get_tree() if is_inside_tree() else null
	if tree != null:
		for g in [&"mechs", &"tanks", &"trucks"]:
			for n in tree.get_nodes_in_group(g):
				var t = n.get("team")
				var h = n.get("health")
				if t != null and int(t) != team and h is HealthPool and not (h as HealthPool).is_dead():
					out.append(n)
	return out


## What the assists need of `o` seen from `from` with the gun `w`, or {} when it is out
## of range or outside the cone.
func describe(o: Object, from: Vector3, w: Array = DEFAULT_WEAPON) -> Dictionary:
	var shape := body_of(o)
	if shape.is_empty():
		return {}
	var feet: Vector3 = shape.feet
	var dist := Vector2(feet.x - from.x, feet.z - from.z).length()
	var reach := float(w[0])
	var fade := 1.0
	if range_limit:
		if dist > reach:
			return {}
		fade = 1.0 - smoothstep(reach * RANGE_FADE, reach, dist)
	# The aim line: on the weak point nearest the crosshair among those facing us.
	var column := feet
	var fwd := -camera.global_transform.basis.z
	if weak_points:
		var best := INF
		for p in shape.points:
			var a := fwd.angle_to((p as Vector3) - from)
			if a < best:
				best = a
				column = p
	# Lead a slow projectile: where the line will be when the round gets there.
	var speed := float(w[2])
	if speed > 0.0:
		var v: Vector3 = shape.velocity
		column += Vector3(v.x, 0.0, v.z) * (from.distance_to(feet) / speed)
	var lo: float = feet.y + 0.1
	var hi: float = float(shape.top)
	var point := line_point(from, fwd, Vector3(column.x, lo, column.z), hi)
	var err := error_to(point)
	var half := atan2(float(shape.radius), maxf(from.distance_to(point), 0.5))
	var a := ads()
	var cone := half * lerpf(CONE_WIDTH[0], CONE_WIDTH[1], a) + deg_to_rad(lerpf(CONE_DEG[0], CONE_DEG[1], a))
	var off := err.length()
	if off > cone:
		return {}
	# Full inside the target's own width, nothing at the cone's edge.
	var k := 1.0 if off <= half else 1.0 - (off - half) / maxf(cone - half, 0.0001)
	return {"owner": o, "point": point, "err": err, "half": half, "k": k * fade,
			"dist": dist, "score": off / cone, "body": shape.body}


## The nearest point to the ray `from` + t `fwd` on the vertical segment from `bottom` up
## to height `top`.
static func line_point(from: Vector3, fwd: Vector3, bottom: Vector3, top: float) -> Vector3:
	var fh := Vector2(fwd.x, fwd.z)
	var t := 0.0
	if fh.length_squared() > 1e-6:
		t = maxf(Vector2(bottom.x - from.x, bottom.z - from.z).dot(fh) / fh.length_squared(), 0.0)
	var y := clampf(from.y + fwd.y * t, bottom.y, maxf(top, bottom.y))
	return Vector3(bottom.x, y, bottom.z)


## (yaw, pitch) radians from the crosshair to `p`: + right, + up.
func error_to(p: Vector3) -> Vector2:
	var v := camera.global_transform.basis.inverse() * (p - camera.global_position)
	return Vector2(atan2(v.x, -v.z), atan2(v.y, Vector2(v.x, v.z).length()))


func _in_sight(from: Vector3, d: Dictionary) -> bool:
	var ex: Array[RID] = []
	if player != null and player.pawn != null:
		ex.append(player.pawn.body.get_rid())
	var b := d.body as CollisionObject3D
	if b != null:
		ex.append(b.get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, d.point, Layers.HITSCAN_MASK, ex)
	return camera.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## The target's shape for the assists: feet, top (height), radius, velocity, the body, and
## its weak points that face the camera. {} for nothing that can be read.
func body_of(o: Object) -> Dictionary:
	var from := camera.global_position
	if o is Pawn:
		var p := o as Pawn
		var feet := p.feet()
		var pts: Array = []
		var spots := p.body.get_node_or_null(^"CritSpots") as CritSpots
		if spots != null:
			for s in spots.spots:
				var n := s.node as Node3D
				if n == null or not is_instance_valid(n) or not n.is_inside_tree():
					continue
				var c: Vector3 = n.global_transform * (s.offset as Vector3)
				if facing(c, feet, from, 0.15):
					pts.append(c)
		return {"feet": feet, "top": feet.y + p.eye_height() + 0.2, "radius": 0.4,
				"velocity": p.body.velocity, "body": p.body, "points": pts}
	if o is Mech:
		var m := o as Mech
		if m.body == null:
			return {}
		var pts: Array = []
		if m.layers != null:
			for c in [m.layers.hatch_point(), m.layers.cell_point()]:
				if m.layers.side_faces(c, from):
					pts.append(c)
		return {"feet": m.feet(), "top": m.feet().y + Mech.HEIGHT, "radius": Mech.RADIUS,
				"velocity": m.body.velocity, "body": m.body, "points": pts}
	if o is CharacterBody3D:
		var b := o as CharacterBody3D
		var box := AABB()
		var first := true
		for c in b.get_children():
			var cs := c as CollisionShape3D
			if cs == null or cs.shape == null:
				continue
			var bb := cs.global_transform * cs.shape.get_debug_mesh().get_aabb()
			box = bb if first else box.merge(bb)
			first = false
		if first:
			return {}
		var centre := box.get_center()
		return {"feet": Vector3(centre.x, box.position.y, centre.z), "top": box.end.y,
				"radius": maxf(box.size.x, box.size.z) * 0.5, "velocity": b.velocity, "body": b,
				"points": []}
	return {}


## A weak point at `c` on a body standing at `feet` faces `from` unless it is out to the
## far side: near the body's axis (within `axis` m) it faces every way.
static func facing(c: Vector3, feet: Vector3, from: Vector3, axis: float) -> bool:
	var out := Vector2(c.x - feet.x, c.z - feet.z)
	if out.length() <= axis:
		return true
	var to := Vector2(from.x - feet.x, from.z - feet.z)
	return out.normalized().dot(to.normalized()) > -0.1


# ------------------------------------------------------------------- bullets

## A round leaving `from` along `dir`: bent onto the target's aim line when it would just
## miss -- within the target's half-width plus the bullet assist's degrees. The point it
## is bent to is on the line at the crosshair's height, so a head stays a head.
func bend(from: Vector3, dir: Vector3) -> Vector3:
	if not active() or target.is_empty() or bullet_scale <= 0.0:
		return dir
	var feet: Vector3 = target.point
	var shape := body_of(target.owner)
	if shape.is_empty():
		return dir
	var p := line_point(from, dir, Vector3(feet.x, (shape.feet as Vector3).y + 0.1, feet.z), float(shape.top))
	var to := p - from
	if to.length() < 0.5:
		return dir
	var allow := float(target.half) + deg_to_rad(_blend(BULLET_DEG) * level() * bullet_scale) \
			* clampf(float(target.k) * 2.0, 0.0, 1.0)
	if dir.angle_to(to) > allow:
		return dir
	return to.normalized()
