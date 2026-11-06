class_name RepairFx
extends RefCounted
## What a repair looks and sounds like (Docs/Hulls.md 9.3): each brick laid back
## pops into place -- a copy of its ghost, a little large and bright, shrinking
## onto it and fading in a fifth of a second -- with a plastic snap made on the
## spot (a click of noise and two short high tones, pitched a little differently
## each time so a stream of them is not a buzz). Nothing loaded from disk.

## How long a pop lasts, seconds.
const POP := 0.2
## Pops at once at most (the held tool lays 8 a second).
const MAX_POPS := 12
## Snap players at once.
const VOICES := 4

static var _snaps: Array[AudioStreamWAV] = []

var _pops: Array = []        ## [MeshInstance3D, age]
var _players: Array[AudioStreamPlayer3D] = []
var _next := 0
var _mat: StandardMaterial3D
## Snaps played (for the gates: headless has no audio to listen to).
var played := 0


## A brick laid at `xf` (its mesh's transform, world) with `mesh` (its shape; a
## box if null), under `parent`.
func laid(parent: Node, mesh: Mesh, xf: Transform3D, centre: Vector3) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	_pop(parent, mesh, xf, centre)
	_snap(parent, centre)


func _pop(parent: Node, mesh: Mesh, xf: Transform3D, centre: Vector3) -> void:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.vertex_color_use_as_albedo = true
		_mat.albedo_color = Color(1.4, 1.6, 1.8, 0.8)
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _pops.size() >= MAX_POPS:
		var old: Array = _pops.pop_front()
		if is_instance_valid(old[0]):
			old[0].queue_free()
	var mi := MeshInstance3D.new()
	if mesh == null:
		var box := BoxMesh.new()
		mesh = box
	mi.mesh = mesh
	mi.material_override = _mat.duplicate()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	parent.add_child(mi)
	_pops.append([mi, 0.0, xf, centre])
	_place(_pops.back())


## One frame of the pops.
func tick(dt: float) -> void:
	var k := 0
	while k < _pops.size():
		var p: Array = _pops[k]
		p[1] = float(p[1]) + dt
		if float(p[1]) >= POP or not is_instance_valid(p[0]):
			if is_instance_valid(p[0]):
				p[0].queue_free()
			_pops.remove_at(k)
			continue
		_place(p)
		k += 1


## A pop at its age: 1.25 times its size shrinking to 1, about its centre, fading.
func _place(p: Array) -> void:
	var mi: MeshInstance3D = p[0]
	var f := clampf(float(p[1]) / POP, 0.0, 1.0)
	var s := lerpf(1.25, 1.0, 1.0 - (1.0 - f) * (1.0 - f))
	var xf: Transform3D = p[2]
	var c: Vector3 = p[3]
	mi.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * s), c - c * s) * xf
	(mi.material_override as StandardMaterial3D).albedo_color.a = 0.8 * (1.0 - f)


func _snap(parent: Node, at: Vector3) -> void:
	if _snaps.is_empty():
		for k in 3:
			_snaps.append(snap_sound(k))
	if _players.size() < VOICES:
		var pl := AudioStreamPlayer3D.new()
		pl.unit_size = 6.0
		pl.max_distance = 40.0
		_players.append(pl)
	var p := _players[_next % _players.size()]
	_next += 1
	if p.get_parent() != parent:
		if p.get_parent() != null:
			p.get_parent().remove_child(p)
		parent.add_child(p)
	p.stream = _snaps[randi() % _snaps.size()]
	p.pitch_scale = randf_range(0.92, 1.1)
	p.global_position = at
	p.play()
	played += 1


## A plastic snap, made: a 4 ms click of noise, then two short high tones (the
## brick's two walls ringing) dying in 60 ms. `k` varies the tones.
static func snap_sound(k: int) -> AudioStreamWAV:
	const RATE := 22050
	var seconds := 0.08
	var n := int(seconds * RATE)
	var f1 := 2300.0 + 260.0 * k
	var f2 := 3900.0 - 180.0 * k
	var rng := RandomNumberGenerator.new()
	rng.seed = 7 + k
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / RATE
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 900.0) * 0.8
		var ring := (sin(TAU * f1 * t) * 0.5 + sin(TAU * f2 * t) * 0.3) * exp(-t * 70.0)
		var attack := minf(float(i) / 12.0, 1.0)
		var v := (click + ring * 0.6) * attack * 0.7
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


func clear() -> void:
	for p in _pops:
		if is_instance_valid(p[0]):
			p[0].queue_free()
	_pops.clear()
