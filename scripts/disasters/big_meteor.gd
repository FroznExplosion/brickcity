class_name BigMeteor
extends MeteorShower

## A single giant meteor (Docs/Disasters.md 23). A long warning: a light in the
## sky that grows, the sky going a dusty orange, the rumble deepening, then a
## ring wide enough to read from a street away. One impact -- a crater
## GIANT_RADIUS across times intensity's root -- a shockwave that throws what
## is loose and knocks people down, ejecta blasting the ground round it, fires
## in a ring, and the dust of all of it.

var _star: MeshInstance3D


func _init() -> void:
	super()
	title = "Giant meteor"
	warning_s = 12.0
	active_s = 14.0
	ending_s = 8.0


func _roll_schedule() -> void:
	meteors.clear()
	bursts = 1
	_add_giant(active_s * 0.5, GIANT_RADIUS)
	_sort()


func _on_begin() -> void:
	super()
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.8, 0.55)
	m.material = mat
	_star = MeshInstance3D.new()
	_star.mesh = m
	_star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_star)
	_star.visible = false


## The light in the sky, growing as it comes, where it will come from.
func _process(delta: float) -> void:
	super(delta)
	if _star == null:
		return
	var coming: bool = phase == Phase.WARNING or (phase == Phase.ACTIVE and int(meteors[0].stage) < Stage.FLYING)
	_star.visible = coming
	if coming:
		var k := phase_t / warning_s if phase == Phase.WARNING else 1.0 + phase_t / 4.0
		_star.global_position = ctx.player_pos() - entry_dir * 900.0
		_star.scale = Vector3.ONE * lerpf(2.0, 18.0, clampf(k * 0.6, 0.0, 1.0))
