class_name GaitController
extends Node
## Physics-based procedural locomotion (LOD0/LOD1).
## Per-leg steppers keep feet planted in WORLD space while the body moves;
## a step triggers when a foot is overstretched and its phase group is free.
## Raycasts place feet on real geometry; body height/pitch/roll are derived
## from the planted feet. Writing the body bone pose every physics tick also
## dirties the skeleton, which is what makes the 4.6 modifier stack run.

var creature: Node3D
var rig: Dictionary
var dna: CreatureDNA

var tick_divisor: int = 1         # LOD1 runs the stepper at a reduced rate
var wander: bool = true
var move_dir := Vector3(0, 0, -1) # creature-local forward is -Z

var _steppers: Array[Dictionary] = []
var _tick := 0
var _time := 0.0
var _heading := 0.0
var _body_y_off := 0.0
var _pitch := 0.0
var _roll := 0.0
var _stepping_in_group := [0, 0]
var _needs_replant := false
var _rng := RandomNumberGenerator.new()

var steps_taken := 0              # telemetry for tests
var path_len := 0.0

func setup(p_creature: Node3D, p_rig: Dictionary, p_dna: CreatureDNA) -> void:
	creature = p_creature
	rig = p_rig
	dna = p_dna
	_rng.seed = dna.seed_value ^ 0xBEEF
	_heading = creature.rotation.y
	# Write targets/poses BEFORE the skeleton's modifier pass runs this frame.
	process_physics_priority = -10
	for leg in rig.legs:
		_steppers.append({
			"leg": leg,
			"planted": Vector3.ZERO,
			"swing_t": -1.0,   # <0 means planted
			"from": Vector3.ZERO, "to": Vector3.ZERO,
		})
	_needs_replant = true  # snap feet on first tick — robust to positioning after add_child
	set_physics_process(true)

## Call after teleporting the creature to snap feet under it instantly.
func teleport_reset() -> void:
	_needs_replant = true

func _physics_process(delta: float) -> void:
	if rig.is_empty():
		return
	_tick += 1
	if _tick % tick_divisor != 0:
		return
	var dt := delta * float(tick_divisor)
	_time += dt

	if _needs_replant:
		_needs_replant = false
		_heading = creature.rotation.y
		for s in _steppers:
			s.planted = creature.global_transform * (s.leg as Dictionary).foot_local
			s.swing_t = -1.0
		_stepping_in_group = [0, 0]

	# ---- locomotion / wander --------------------------------------------
	if wander:
		_heading += (sin(_time * 0.37 + float(dna.seed_value % 7)) * 0.8 + _rng.randf_range(-0.2, 0.2)) * dt
		creature.rotation.y = _heading
	var fwd := -creature.global_transform.basis.z
	var vel := fwd * dna.move_speed
	creature.global_position += vel * dt
	path_len += vel.length() * dt

	# root follows terrain under the body center
	var space := creature.get_world_3d().direct_space_state
	var hit := _ray(space, creature.global_position + Vector3.UP * (rig.stand_h * 2.0 + 1.0), rig.stand_h * 4.0 + 2.0)
	if hit:
		creature.global_position.y = lerpf(creature.global_position.y, hit.position.y, 1.0 - pow(0.001, dt))

	# ---- steppers --------------------------------------------------------
	var step_trig: float = rig.stand_h * dna.step_trigger_f
	var step_h: float = rig.stand_h * dna.step_height_f
	var xf := creature.global_transform
	for s in _steppers:
		var leg: Dictionary = s.leg
		var home: Vector3 = xf * leg.home_local
		var ghit := _ray(space, home + Vector3.UP * rig.stand_h, rig.stand_h * 3.0)
		var ground: Vector3 = ghit.position if ghit else Vector3(home.x, creature.global_position.y, home.z)

		if s.swing_t >= 0.0:  # mid-swing
			s.swing_t = minf(s.swing_t + dt / dna.step_time, 1.0)
			var t: float = s.swing_t
			var p: Vector3 = s.from.lerp(s.to, smoothstep(0.0, 1.0, t))
			p.y += sin(PI * t) * step_h
			leg.target.global_position = p
			if s.swing_t >= 1.0:
				s.planted = s.to
				s.swing_t = -1.0
				_stepping_in_group[leg.group] -= 1
				steps_taken += 1
		else:
			var overstretch: float = (s.planted as Vector3).distance_to(ground)
			var other: int = 1 - int(leg.group)
			var may: bool = _stepping_in_group[other] == 0 or overstretch > step_trig * 1.9
			if overstretch > step_trig and may:
				s.swing_t = 0.0
				s.from = s.planted
				s.to = ground + vel * dna.step_time * 0.7
				_stepping_in_group[leg.group] += 1
			leg.target.global_position = s.planted

		# knee pole rides with the body
		leg.pole.global_position = xf * leg.pole_local

	# ---- body dynamics from feet ----------------------------------------
	var front := 0.0; var back := 0.0; var left := 0.0; var right := 0.0
	var nf := 0; var nb := 0; var nl := 0; var nr := 0
	var avg_y := 0.0
	for s in _steppers:
		var lp: Vector3 = xf.affine_inverse() * (s.planted as Vector3)
		avg_y += lp.y
		if lp.z < 0.0: front += lp.y; nf += 1
		else: back += lp.y; nb += 1
		if lp.x < 0.0: left += lp.y; nl += 1
		else: right += lp.y; nr += 1
	avg_y /= maxf(1.0, _steppers.size())
	var tgt_pitch := 0.0
	if nf > 0 and nb > 0:
		tgt_pitch = atan2((front / nf) - (back / nb), maxf(dna.body_len, 0.3))
	var tgt_roll := 0.0
	if nl > 0 and nr > 0:
		tgt_roll = atan2((right / nr) - (left / nl), maxf(dna.body_r * 4.0, 0.3))
	var k := 1.0 - pow(0.002, dt)
	_pitch = lerpf(_pitch, tgt_pitch * 0.6, k)
	_roll = lerpf(_roll, tgt_roll * 0.5, k)
	_body_y_off = lerpf(_body_y_off, avg_y * 0.7, k)

	var bob := sin(_time * TAU * (dna.move_speed / maxf(rig.stand_h, 0.2)) * 0.7) * dna.bob_amp
	var skel: Skeleton3D = rig.skeleton
	skel.set_bone_pose_position(rig.body, rig.body_rest_pos + Vector3(0, _body_y_off + bob, 0))
	skel.set_bone_pose_rotation(rig.body, Quaternion(Vector3.RIGHT, _pitch) * Quaternion(Vector3.BACK, _roll))

	# look target drifts ahead with a little curiosity
	rig.look_target.global_position = xf * (rig.head_local + Vector3(sin(_time * 0.8) * 1.2, sin(_time * 0.53) * 0.5, -3.0))

func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, dist: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * dist)
	return space.intersect_ray(q)
