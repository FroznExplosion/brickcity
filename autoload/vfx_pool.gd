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
## Caps: the pool used to grow without end once a key's pre-warmed nodes were
## all out. Past these, acquire_emitter / acquire_arc return null (callers skip
## the effect) and a shatter takes over the oldest one still flying.
@export var max_per_key := 16
@export var max_arcs := 24
@export var max_shatters := 6
@export var max_decals := 16
@export var shard_mesh: Mesh                 # low-poly crystal chunk (_shard_mesh when unset)
@export var arc_ribbon_scene: PackedScene    # QuadMesh strip w/ electric_arc.gdshader
@export var puddle_material: ShaderMaterial  # puddle_decal.gdshader (shared)

var _free: Dictionary = {}      # key -> Array[Node3D]
var _decals: Array[Decal] = []
var _decal_cursor := 0
var _shatters: Array[ShatterBurst] = []
var _free_shatters: Array[ShatterBurst] = []
var _free_arcs: Array[Node3D] = []
var _live := {}         # key -> emitters out of the pool (acquired or bursting)
var _arcs_out := 0
## Requests turned away by the caps, for gates.
var refused := 0

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
## Null when `key` has no scene or max_per_key of it are already out.
func acquire_emitter(key: String, parent: Node, local_pos := Vector3.ZERO) -> Node3D:
	if not emitter_scenes.has(key) or parent == null:
		return null
	var arr: Array = _free.get(key, [])
	_free[key] = arr
	var n: Node3D
	if arr.is_empty():
		if int(_live.get(key, 0)) >= max_per_key:
			refused += 1
			return null
		n = emitter_scenes[key].instantiate()  # pool exhausted — grow, up to the cap
	else:
		n = arr.pop_back()
		n.get_parent().remove_child(n)
	_live[key] = int(_live.get(key, 0)) + 1
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
		_live[key] = maxi(int(_live.get(key, 0)) - 1, 0)
		if not is_instance_valid(n): return
		if n.get_parent(): n.get_parent().remove_child(n)
		add_child(n)
		_sleep(n)
		_free[key].append(n))

## Fire-and-forget one-shot burst at a world position.
func burst(key: String, world_pos: Vector3) -> void:
	var n := acquire_emitter(key, self)
	if n == null:
		return
	n.global_position = world_pos
	for p in _all_particles(n):
		p.one_shot = true
		p.restart()
	get_tree().create_timer(3.0).timeout.connect(func():
		_live[key] = maxi(int(_live.get(key, 0)) - 1, 0)
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
## Null when there is no ribbon scene or max_arcs are already out.
func acquire_arc(parent: Node3D) -> Node3D:
	if arc_ribbon_scene == null or parent == null:
		return null
	if _arcs_out >= max_arcs:
		refused += 1
		return null
	_arcs_out += 1
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
	_arcs_out = maxi(_arcs_out - 1, 0)
	a.visible = false
	if a.get_parent(): a.get_parent().remove_child(a)
	add_child(a)
	_free_arcs.append(a)

# ------------------------------------------------------------- ice shatter
## Shard burst drawn by fx/shaders/ice_shard.gdshader: one MultiMesh, each shard
## written once when the burst starts; the shader flies, bounces and shrinks it
## from its age, the only thing written after (Docs/GpuOffload.md 2.7).
class ShatterBurst:
	var mmi: MultiMeshInstance3D
	var mat: ShaderMaterial
	var life := 0.0
	var max_life := 1.6
	var active := false

## floor_y: pass the enemy's ground height (ElementalTarget sends its
## ground_socket y) so shards bounce on the actual floor, not world y=0.
## On very uneven terrain you can instead raycast down from world_pos here.
func spawn_shatter(world_pos: Vector3, aabb_size: Vector3, count := 40,
		floor_y := 0.0) -> void:
	var b: ShatterBurst
	if _free_shatters.is_empty() and _shatters.size() >= max_shatters:
		# All flying: the one nearest its end starts over here.
		b = _shatters[0]
		for s in _shatters:
			if s.life > b.life:
				b = s
	elif _free_shatters.is_empty():
		b = ShatterBurst.new()
		b.mmi = MultiMeshInstance3D.new()
		# Written once, where the burst starts: never eased from the last one.
		b.mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true            # spin axis, rate
		mm.use_custom_data = true       # velocity
		mm.mesh = shard_mesh if shard_mesh != null else _shard_mesh()
		mm.instance_count = count
		b.mmi.multimesh = mm
		b.mat = ShaderMaterial.new()
		b.mat.shader = load("res://fx/shaders/ice_shard.gdshader")
		b.mat.set_shader_parameter("max_life", b.max_life)
		b.mmi.material_override = b.mat
		b.mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(b.mmi)
		_shatters.append(b)
	else:
		b = _free_shatters.pop_back()
	var mm := b.mmi.multimesh
	if mm.instance_count != count:
		mm.instance_count = count   # shard count scales with enemy size
	# Where a shard is drawn is the shader's: room for the farthest flight.
	mm.custom_aabb = AABB(world_pos - Vector3(10, 10, 10), Vector3(20, 20, 20))
	b.mat.set_shader_parameter("fall", Gravity.down_at(world_pos) * 9.8 * 1.5)
	b.mat.set_shader_parameter("floor_y", floor_y + 0.05)
	b.mat.set_shader_parameter("age", 0.0)
	var rs_mm := mm.get_rid()
	for i in mm.instance_count:
		# Distribute inside the enemy's AABB so the "popsicle" bursts from the body.
		var local := Vector3(randf() - 0.5, randf(), randf() - 0.5) * aabb_size
		var dir := (local + Vector3.UP * 0.3).normalized()
		var vel := dir * randf_range(2.0, 6.0)
		var axis := Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
		RenderingServer.multimesh_instance_set_transform(rs_mm, i, Transform3D(
				Basis().scaled(Vector3.ONE * randf_range(0.4, 1.1)), world_pos + local))
		RenderingServer.multimesh_instance_set_custom_data(rs_mm, i, Color(vel.x, vel.y, vel.z, 0.0))
		RenderingServer.multimesh_instance_set_color(rs_mm, i,
				Color(axis.x, axis.y, axis.z, randf_range(3.0, 12.0)))
	b.life = 0.0
	b.active = true
	b.mmi.visible = true
	burst("shatter_puff", world_pos)     # snow-mist poof (smoke, tinted)


var _shard: Mesh

## A cut-crystal chunk, about 10 cm across, for when no shard_mesh is set.
func _shard_mesh() -> Mesh:
	if _shard == null:
		var m := SphereMesh.new()
		m.radius = 0.05
		m.height = 0.16
		m.radial_segments = 5
		m.rings = 2
		_shard = m
	return _shard


func _process(delta: float) -> void:
	for b in _shatters:
		if not b.active: continue
		b.life += delta
		if b.life >= b.max_life:
			b.active = false
			b.mmi.visible = false
			_free_shatters.append(b)
			continue
		b.mat.set_shader_parameter("age", b.life)
