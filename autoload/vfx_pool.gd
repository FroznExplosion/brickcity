# vfx_pool.gd — AUTOLOAD (name: VfxPool)
# Central pool for every reusable VFX node. Nothing is instantiated mid-combat;
# everything is pre-warmed here and handed out by key.
#
# Emitter scenes are just a GPUParticles3D (or a small tree of them) saved as a
# .tscn using our own flipbook/spark textures (never Synty: brickcity ships none). Register them in `emitter_scenes`.
extends Node

## key -> PackedScene of a GPUParticles3D-rooted effect (one_shot OR looping)
@export var emitter_scenes: Dictionary = {
	# "fire_body":   preload("res://fx/emitters/fire_body.tscn"),
	# "fire_smoke":  preload("res://fx/emitters/fire_smoke.tscn"),
	# "acid_sizzle": preload("res://fx/emitters/acid_sizzle.tscn"),
	# "shock_sparks":preload("res://fx/emitters/shock_sparks.tscn"),
	# "rad_smoke":   preload("res://fx/emitters/rad_smoke.tscn"),
	# "ice_mist":    preload("res://fx/emitters/ice_mist.tscn"),
	# "corr_drips":  preload("res://fx/emitters/corr_drips.tscn"),
	# "shatter_puff":preload("res://fx/emitters/shatter_puff.tscn"),
}
@export var prewarm_per_key := 4
@export var max_decals := 16
@export var shard_mesh: Mesh                 # low-poly crystal chunk
@export var arc_ribbon_scene: PackedScene    # QuadMesh strip w/ electric_arc.gdshader
@export var puddle_material: ShaderMaterial  # puddle_decal.gdshader (shared)

var _free: Dictionary = {}      # key -> Array[Node3D]
var _decals: Array[Decal] = []
var _decal_cursor := 0
var _shatters: Array[ShatterBurst] = []
var _free_shatters: Array[ShatterBurst] = []
var _free_arcs: Array[Node3D] = []

func _ready() -> void:
	for key in emitter_scenes:
		_free[key] = []
		for i in prewarm_per_key:
			var n: Node3D = emitter_scenes[key].instantiate()
			add_child(n)
			_sleep(n)
			_free[key].append(n)
	for i in max_decals:
		var d := Decal.new()
		d.visible = false
		add_child(d)
		_decals.append(d)

# ------------------------------------------------------------- emitters
## Attach a looping emitter (fire, sparks…) to a parent. Returns handle; keep it
## and call release_emitter() when the status ends.
func acquire_emitter(key: String, parent: Node, local_pos := Vector3.ZERO) -> Node3D:
	var arr: Array = _free.get(key, [])
	var n: Node3D
	if arr.is_empty():
		n = emitter_scenes[key].instantiate()  # pool exhausted — grow (rare)
	else:
		n = arr.pop_back()
		n.get_parent().remove_child(n)
	parent.add_child(n)
	n.position = local_pos
	n.visible = true
	_set_emitting(n, true)
	return n

func release_emitter(key: String, n: Node3D) -> void:
	if not is_instance_valid(n):
		return
	_set_emitting(n, false)   # let live particles finish
	# Reparent back after longest lifetime; cheap deferred cleanup.
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func():
		if not is_instance_valid(n): return
		if n.get_parent(): n.get_parent().remove_child(n)
		add_child(n)
		_sleep(n)
		_free[key].append(n))

## Fire-and-forget one-shot burst at a world position.
func burst(key: String, world_pos: Vector3) -> void:
	var n := acquire_emitter(key, self)
	n.global_position = world_pos
	for p in _all_particles(n):
		p.one_shot = true
		p.restart()
	get_tree().create_timer(3.0).timeout.connect(func():
		if is_instance_valid(n):
			_sleep(n)
			_free[key].append(n))

func _set_emitting(n: Node3D, on: bool) -> void:
	for p in _all_particles(n):
		p.emitting = on

func _all_particles(n: Node) -> Array:
	var out := []
	if n is GPUParticles3D: out.append(n)
	for c in n.get_children(): out.append_array(_all_particles(c))
	return out

func _sleep(n: Node3D) -> void:
	n.visible = false
	_set_emitting(n, false)

# ------------------------------------------------------------- decals
## Ring-buffer puddles: oldest is recycled when the cap is hit.
func acquire_puddle(world_pos: Vector3, color: Color, radius: float) -> Decal:
	var d := _decals[_decal_cursor]
	_decal_cursor = (_decal_cursor + 1) % max_decals
	d.visible = true
	d.global_position = world_pos + Vector3.UP * 0.05
	d.size = Vector3(radius * 2.0, 0.5, radius * 2.0)
	d.modulate = color
	d.albedo_mix = 1.0
	# Fade handled by a tween on modulate.a; caller decides lifetime.
	return d

func fade_puddle(d: Decal, duration := 3.0) -> void:
	var tw := create_tween()
	tw.tween_property(d, "modulate:a", 0.0, duration)
	tw.tween_callback(func(): d.visible = false)

# ------------------------------------------------------------- arc ribbons
func acquire_arc(parent: Node3D) -> Node3D:
	var a: Node3D
	if _free_arcs.is_empty():
		a = arc_ribbon_scene.instantiate()
	else:
		a = _free_arcs.pop_back()
		a.get_parent().remove_child(a)
	parent.add_child(a)
	a.visible = true
	return a

func release_arc(a: Node3D) -> void:
	if not is_instance_valid(a): return
	a.visible = false
	if a.get_parent(): a.get_parent().remove_child(a)
	add_child(a)
	_free_arcs.append(a)

# ------------------------------------------------------------- ice shatter
## Scripted-ballistics shard burst. No RigidBodies: one MultiMesh, transforms
## written straight to RenderingServer. ~40 shards costs almost nothing.
class ShatterBurst:
	var mmi: MultiMeshInstance3D
	var vel: PackedVector3Array
	var rot_axis: PackedVector3Array
	var rot_spd: PackedFloat32Array
	var pos: PackedVector3Array
	var basis_arr: Array[Basis]
	var life := 0.0
	var max_life := 1.6
	var floor_y := 0.0
	var active := false

## floor_y: pass the enemy's ground height (ElementalTarget sends its
## ground_socket y) so shards bounce on the actual floor, not world y=0.
## On very uneven terrain you can instead raycast down from world_pos here.
func spawn_shatter(world_pos: Vector3, aabb_size: Vector3, count := 40,
		floor_y := 0.0) -> void:
	var b: ShatterBurst
	if _free_shatters.is_empty():
		b = ShatterBurst.new()
		b.mmi = MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true       # x = fade
		mm.mesh = shard_mesh
		mm.instance_count = count
		b.mmi.multimesh = mm
		b.mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(b.mmi)
		_shatters.append(b)
	else:
		b = _free_shatters.pop_back()
	if b.mmi.multimesh.instance_count != count:
		b.mmi.multimesh.instance_count = count   # shard count scales with enemy size
	b.floor_y = floor_y
	var n := b.mmi.multimesh.instance_count
	b.vel.resize(n); b.pos.resize(n); b.rot_axis.resize(n); b.rot_spd.resize(n)
	b.basis_arr.resize(n)
	var rs_mm := b.mmi.multimesh.get_rid()
	for i in n:
		# Distribute inside the enemy's AABB so the "popsicle" bursts from the body.
		var local := Vector3(randf() - 0.5, randf(), randf() - 0.5) * aabb_size
		b.pos[i] = world_pos + local
		var dir := (local + Vector3.UP * 0.3).normalized()
		b.vel[i] = dir * randf_range(2.0, 6.0)
		b.rot_axis[i] = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
		b.rot_spd[i] = randf_range(3.0, 12.0)
		b.basis_arr[i] = Basis().scaled(Vector3.ONE * randf_range(0.4, 1.1))
		# Write spawn transforms NOW so a reused burst never flashes stale shards.
		RenderingServer.multimesh_instance_set_transform(
			rs_mm, i, Transform3D(b.basis_arr[i], b.pos[i]))
		RenderingServer.multimesh_instance_set_custom_data(
			rs_mm, i, Color(1, 0, 0, 0))
	b.life = 0.0
	b.active = true
	b.mmi.visible = true
	burst("shatter_puff", world_pos)     # snow-mist poof (smoke, tinted)

func _process(delta: float) -> void:
	for b in _shatters:
		if not b.active: continue
		b.life += delta
		var t: float = b.life / b.max_life
		if t >= 1.0:
			b.active = false
			b.mmi.visible = false
			_free_shatters.append(b)
			continue
		var rs_mm := b.mmi.multimesh.get_rid()
		var n := b.mmi.multimesh.instance_count
		var fade := 1.0 - smoothstep(0.6, 1.0, t)
		for i in n:
			b.vel[i].y -= 9.8 * delta * 1.5
			b.pos[i] += b.vel[i] * delta
			if b.pos[i].y < b.floor_y + 0.05:   # bounce on the enemy's floor
				b.pos[i].y = b.floor_y + 0.05
				b.vel[i].y *= -0.35
				b.vel[i] *= 0.7
			b.basis_arr[i] = b.basis_arr[i].rotated(b.rot_axis[i], b.rot_spd[i] * delta)
			RenderingServer.multimesh_instance_set_transform(
				rs_mm, i, Transform3D(b.basis_arr[i], b.pos[i]))
			RenderingServer.multimesh_instance_set_custom_data(
				rs_mm, i, Color(fade, 0, 0, 0))
