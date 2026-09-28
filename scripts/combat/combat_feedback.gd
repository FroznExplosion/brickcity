class_name CombatFeedback
extends Node
## What a fight tells the player it is doing (the combat arena, WaveDirector).
##
## A round that struck somebody was indistinguishable from one that missed: no
## mark, no number, no flinch, and a dead soldier stood where it died. So:
##
##   * a HITMARKER on the crosshair for every round that lands on a body --
##     white, yellow for a crit, a bigger red one for the kill;
##   * the DAMAGE, as a number rising from where it landed;
##   * the body FLASHES white for a moment where it was struck;
##   * a KILL bursts the body into bricks and the body is gone;
##   * the player's own hurt as a red edge on the screen, heavier the harder
##     the hit, and a mark on the side it came from.
##
## Cosmetic and local: nothing here is in the damage log.

const MARK_SECONDS := 0.16
const KILL_MARK_SECONDS := 0.35
const NUMBER_SECONDS := 0.8
const FLASH_SECONDS := 0.09
const HURT_FADE := 1.6

var city: Node3D
## Counts, for gates: hitmarkers, numbers and kill markers shown.
var hits := 0
var numbers_shown := 0
var kills_shown := 0
var _hud: Control
var _mark := 0.0
var _mark_len := MARK_SECONDS
var _mark_colour := Color.WHITE
var _mark_size := 9.0
var _hurt := 0.0
var _hurt_dir := 0.0   # radians, screen space: 0 up, + clockwise
var _hurt_dir_left := 0.0
var _numbers: Array = []   # [Label3D, born, velocity]
var _flashes := {}         # MeshInstance3D -> [material it had, until]
var _flash_mat: StandardMaterial3D
var _hit_snd: AudioStreamPlayer
var _crit_snd: AudioStreamPlayer
var _kill_snd: AudioStreamPlayer
var _hurt_snd: AudioStreamPlayer
## Sounds played, for gates.
var sounds_played := 0


func setup(p_city: Node3D) -> void:
	city = p_city
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_hud = Overlay.new()
	_hud.fb = self
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)
	# Sounds, made here: there are no audio assets yet, and a hit you cannot
	# hear is half a hit. A short high tick for a hit, a two-note chime for the
	# kill, a low thump for being hurt -- replace with real ones when there are.
	_hit_snd = _player_for(_tone([2400.0], 0.035, 90.0, 0.35))
	_crit_snd = _player_for(_tone([3100.0, 1550.0], 0.05, 70.0, 0.4))
	_kill_snd = _player_for(_tone([880.0, 1320.0], 0.16, 18.0, 0.45))
	_hurt_snd = _player_for(_tone([110.0, 165.0], 0.12, 25.0, 0.6))
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.albedo_color = Color(1.0, 1.0, 1.0)
	_flash_mat.emission_enabled = true
	_flash_mat.emission = Color(1.0, 0.95, 0.85)
	_flash_mat.emission_energy_multiplier = 2.0


## A round of the player's gun: `info` is GunController.fired's.
func on_player_shot(info: Dictionary) -> void:
	if info.is_empty() or info.get("result") == null:
		return
	var r: DamageSystem.DamageResult = info.result
	hits += 1
	if r.killed:
		kills_shown += 1
		_mark = KILL_MARK_SECONDS
		_mark_len = KILL_MARK_SECONDS
		_mark_colour = Color(1.0, 0.25, 0.2)
		_mark_size = 14.0
	else:
		_mark = MARK_SECONDS
		_mark_len = MARK_SECONDS
		_mark_colour = Color(1.0, 0.85, 0.2) if r.was_crit else Color.WHITE
		_mark_size = 9.0
	_play(_kill_snd if r.killed else (_crit_snd if r.was_crit else _hit_snd))
	if r.dealt > 0.0:
		_number(info.point, r.dealt, r.was_crit, r.killed)
	var body := info.get("collider") as Node
	if body != null and not r.killed:
		_flash(body)


## The player was hurt by `amount`, from `from` (world, or INF).
func player_hurt(amount: float, from: Vector3) -> void:
	_hurt = clampf(_hurt + amount / 40.0, 0.0, 1.0)
	_play(_hurt_snd)
	var cam: Camera3D = city.camera
	if from != Vector3.INF and cam != null:
		var to := cam.global_transform.affine_inverse() * from
		_hurt_dir = atan2(to.x, -to.z)
		_hurt_dir_left = 1.0


## A body died at `where`: burst it into bricks.
func burst(where: Vector3, colour: Color) -> void:
	var p := CPUParticles3D.new()
	var cube := BoxMesh.new()
	cube.size = Vector3(0.14, 0.12, 0.14)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	cube.material = mat
	p.mesh = cube
	p.amount = 28
	p.one_shot = true
	p.explosiveness = 0.95
	p.lifetime = 1.1
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.25, 0.8, 0.25)
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 5.0
	p.gravity = Vector3(0.0, -14.0, 0.0)
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.3
	city.add_child(p)
	p.global_position = where + Vector3.UP * 0.8
	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.3).timeout.connect(p.queue_free)


func _play(p: AudioStreamPlayer) -> void:
	if p == null:
		return
	sounds_played += 1
	p.play()


func _player_for(stream: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.max_polyphony = 4
	add_child(p)
	return p


## A short tone: `freqs` played one after another (evenly split over
## `seconds`), each decaying at `decay` per second, at `gain`. 16-bit mono.
static func _tone(freqs: Array, seconds: float, decay: float, gain: float) -> AudioStreamWAV:
	const RATE := 22050
	var n := int(seconds * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	@warning_ignore("integer_division")
	var per := maxi(n / freqs.size(), 1)
	for i in n:
		@warning_ignore("integer_division")
		var k := mini(i / per, freqs.size() - 1)
		var t := float(i - k * per) / RATE
		# A few samples of fade-in: no click at the start of each note.
		var attack := minf(float(i - k * per) / 40.0, 1.0)
		var v := sin(TAU * float(freqs[k]) * t) * exp(-decay * t) * gain * attack
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


func _number(at: Vector3, dealt: float, crit: bool, killed: bool) -> void:
	numbers_shown += 1
	var l := Label3D.new()
	l.text = ("%d!" if crit else "%d") % roundi(dealt)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0014
	l.font_size = 44 if not (crit or killed) else 60
	l.outline_size = 12
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	# The text over its own outline: with no depth test the two are sorted by
	# priority alone, and at the defaults the outline could land on top.
	l.render_priority = 2
	l.outline_render_priority = 1
	l.modulate = Color(1.0, 0.3, 0.25) if killed else (Color(1.0, 0.85, 0.2) if crit else Color.WHITE)
	city.add_child(l)
	# Up and to the right of where it landed, in screen pixels (the label is
	# fixed-size): clear of the crosshair at any range.
	l.offset = Vector2(110.0, 80.0)
	l.global_position = at
	var drift := Vector3(randf_range(-0.4, 0.4), 1.2, randf_range(-0.4, 0.4))
	_numbers.append([l, Time.get_ticks_msec(), drift])


func _flash(body: Node) -> void:
	for c in body.get_children():
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		if not _flashes.has(mi):
			_flashes[mi] = [mi.material_override, 0]
		mi.material_override = _flash_mat
		_flashes[mi][1] = Time.get_ticks_msec() + int(FLASH_SECONDS * 1000.0)


func _process(delta: float) -> void:
	_mark = maxf(_mark - delta, 0.0)
	_hurt = maxf(_hurt - delta / HURT_FADE, 0.0)
	_hurt_dir_left = maxf(_hurt_dir_left - delta / HURT_FADE, 0.0)
	var now := Time.get_ticks_msec()
	for i in range(_numbers.size() - 1, -1, -1):
		var e: Array = _numbers[i]
		var l: Label3D = e[0]
		var age := float(now - int(e[1])) / 1000.0
		if age > NUMBER_SECONDS or not is_instance_valid(l):
			if is_instance_valid(l):
				l.queue_free()
			_numbers.remove_at(i)
			continue
		l.global_position += (e[2] as Vector3) * delta
		l.modulate.a = 1.0 - age / NUMBER_SECONDS
		l.outline_modulate.a = 0.85 * (1.0 - age / NUMBER_SECONDS)
	for mi in _flashes.keys():
		if not is_instance_valid(mi):
			_flashes.erase(mi)
		elif now >= int(_flashes[mi][1]):
			(mi as MeshInstance3D).material_override = _flashes[mi][0]
			_flashes.erase(mi)
	_hud.queue_redraw()


class Overlay extends Control:
	var fb: CombatFeedback

	func _draw() -> void:
		var c := size * 0.5
		if fb._mark > 0.0:
			var a := fb._mark / fb._mark_len
			var col := fb._mark_colour
			col.a = a
			var r0 := 7.0
			var r1 := r0 + fb._mark_size
			var back := Color(0.0, 0.0, 0.0, 0.7 * a)
			# Dark under light, so it reads against a white flash or the sky.
			for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
				var n: Vector2 = d.normalized()
				draw_line(c + n * (r0 - 1.0), c + n * (r1 + 1.0), back, 5.5, true)
			for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
				var n: Vector2 = d.normalized()
				draw_line(c + n * r0, c + n * r1, col, 3.0, true)
		if fb._hurt > 0.0:
			# A red edge: four bands fading inwards.
			var w := size.x
			var h := size.y
			var edge := minf(w, h) * 0.16
			var col := Color(0.85, 0.0, 0.0, 0.55 * fb._hurt)
			var clear := Color(0.85, 0.0, 0.0, 0.0)
			_band(Rect2(0, 0, w, edge), col, clear, true)
			_band(Rect2(0, h - edge, w, edge), clear, col, true)
			_band(Rect2(0, 0, edge, h), col, clear, false)
			_band(Rect2(w - edge, 0, edge, h), clear, col, false)
		if fb._hurt_dir_left > 0.0:
			# Which way it came from: a wedge on a ring round the crosshair.
			var col := Color(1.0, 0.15, 0.1, 0.9 * fb._hurt_dir_left)
			var r := minf(size.x, size.y) * 0.18
			var a0: float = fb._hurt_dir - PI * 0.5
			draw_arc(c, r, a0 - 0.35, a0 + 0.35, 16, col, 6.0, true)

	func _band(r: Rect2, from: Color, to: Color, vertical: bool) -> void:
		var pts := PackedVector2Array([r.position, r.position + Vector2(r.size.x, 0),
				r.position + r.size, r.position + Vector2(0, r.size.y)])
		var cols := PackedColorArray([from, from, to, to]) if vertical \
				else PackedColorArray([from, to, to, from])
		draw_polygon(pts, cols)
