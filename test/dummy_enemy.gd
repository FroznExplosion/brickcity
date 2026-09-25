class_name DummyEnemy
extends StaticBody3D
## Test-bed target using the character model. Drives the real elemental overlay shader
## for coat/burn/pulse tints + freeze frost. On freeze it also grows an ICE CRYSTAL at
## each skeleton bone (slightly larger than the limb); on a frozen death the ice flings
## apart and the body breaks into chunks. Auto-respawns so the bed stays usable.


## Only ice these bones (limbs + head + torso). Excludes hands/feet/fingers/etc.
const ICE_BONE_INCLUDE := ["thigh", "shin", "calf", "leg", "upperarm", "lowerarm",
	"forearm", "arm", "head", "spine", "chest", "torso", "hips", "pelvis"]
const ICE_BONE_EXCLUDE := ["hand", "finger", "thumb", "foot", "toe", "eye", "jaw",
	"tongue", "neck", "ear", "clavicle", "shoulder"]

var pool: HealthPool
var label: Label3D
var body_mesh: MeshInstance3D
var model_root: Node3D
var immortal: bool = false

var _skeleton: Skeleton3D
var _ice_parts: Array[Node3D] = []     ## BoneAttachment3D per bone holding an ice crystal
var _elements: Dictionary = {}
var _frozen: bool = false
var _freeze_ramp: float = 0.0
var _flash: float = 0.0
var _flash_color: Color = Color.BLACK
var _overlay_on: bool = false
var _respawn: float = 0.0


func setup(p_pool: HealthPool, p_label: Label3D, p_body_mesh: MeshInstance3D,
		p_model_root: Node3D, p_immortal: bool) -> void:
	pool = p_pool
	label = p_label
	body_mesh = p_body_mesh
	model_root = p_model_root
	immortal = p_immortal
	_skeleton = _find_skeleton(model_root) if model_root != null else null
	pool.died.connect(_on_died)


func _process(delta: float) -> void:
	if _respawn > 0.0:
		_respawn -= delta
		if _respawn <= 0.0:
			_do_respawn()
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 3.0)
	if _frozen:
		_freeze_ramp = minf(1.0, _freeze_ramp + delta * 4.0)
	else:
		_freeze_ramp = maxf(0.0, _freeze_ramp - delta * 4.0)
	_recompute()
	_update_label()


# ---- FX API called by ElementDoT ----

func set_element(id: StringName, color: Color, channel: StringName, active: bool) -> void:
	if active:
		_elements[id] = {"color": color, "channel": channel}
	else:
		_elements.erase(id)


func pulse(color: Color, energy: float) -> void:
	_flash_color = color
	_flash = maxf(_flash, energy)


func set_frozen(active: bool, color: Color) -> void:
	_frozen = active
	if active:
		_flash_color = color
		_flash = maxf(_flash, 0.8)
		_build_ice()
	else:
		_remove_ice()


func shatter(_color: Color) -> void:
	if model_root != null:
		model_root.visible = false
	_clear_overlay()
	_shatter_ice()   # the ice already on the enemy breaks apart; no new shards


# ---- ice shells (per bone) ----

func _build_ice() -> void:
	if _skeleton == null:
		return
	_remove_ice()
	# BoomerBorder used a Synty crystal here; brickcity ships none that is not its own.
	var mesh := PrismMesh.new()
	mesh.size = Vector3(0.18, 0.3, 0.18)
	for b in _skeleton.get_bone_count():
		if not _is_ice_bone(_skeleton.get_bone_name(b).to_lower()):
			continue
		var att := BoneAttachment3D.new()
		att.bone_name = _skeleton.get_bone_name(b)
		_skeleton.add_child(att)
		var cr := MeshInstance3D.new()
		cr.mesh = mesh
		cr.material_override = _ice_mat()
		att.add_child(cr)
		var to_child := _first_child_offset(b)
		cr.position = to_child * 0.5                  # center on the limb
		if to_child.length() > 0.02:
			cr.basis = _basis_y_to(to_child.normalized())   # orient along the limb (any pose)
		var target := Vector3.ONE * (_bone_size(b) * 2.6)
		cr.scale = Vector3.ONE * 0.01
		var gt := cr.create_tween()
		gt.tween_property(cr, "scale", target, 0.4)
		cr.set_meta(&"grow", gt)   # killed on shatter so it can't fight the fly tween
		_ice_parts.append(att)


## Basis with local +Y aligned to `y` (the crystal's long axis follows the limb).
func _basis_y_to(y: Vector3) -> Basis:
	var yy := y.normalized()
	var hint := Vector3.RIGHT if absf(yy.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := hint.cross(yy).normalized()
	var z := x.cross(yy).normalized()
	return Basis(x, yy, z)


func _is_ice_bone(name_lower: String) -> bool:
	for ex in ICE_BONE_EXCLUDE:
		if name_lower.contains(ex):
			return false
	for kw in ICE_BONE_INCLUDE:
		if name_lower.contains(kw):
			return true
	return false


## Offset (bone-local) toward the bone's first child — midpoint of the limb segment.
func _first_child_offset(b: int) -> Vector3:
	var bg := _skeleton.get_bone_global_pose(b)
	for c in _skeleton.get_bone_count():
		if _skeleton.get_bone_parent(c) == b:
			return bg.affine_inverse() * _skeleton.get_bone_global_pose(c).origin
	return Vector3.ZERO


func _remove_ice() -> void:
	for att in _ice_parts:
		if is_instance_valid(att):
			att.queue_free()
	_ice_parts.clear()


func _shatter_ice() -> void:
	var center := global_position + Vector3(0, 0.9, 0)
	for att in _ice_parts:
		if not is_instance_valid(att):
			continue
		for cr in att.get_children():
			var node := cr as Node3D
			if node.has_meta(&"grow"):
				var gt = node.get_meta(&"grow")
				if gt is Tween and (gt as Tween).is_valid():
					(gt as Tween).kill()   # stop the grow tween before flinging
			var gp := node.global_position
			node.reparent(get_tree().current_scene, true)   # keep world transform (real size)
			_fly(node, gp, center)
		att.queue_free()
	_ice_parts.clear()


func _fly(s: Node3D, pos: Vector3, center: Vector3) -> void:
	var out := (pos - center)
	if out.length() < 0.1:
		out = Vector3(randf_range(-1, 1), 1, randf_range(-1, 1))
	var vel := (out.normalized() + Vector3.UP * 0.5) * randf_range(2.5, 5.5)
	var tw := s.create_tween()
	tw.tween_method(_fly_step.bind(s, pos, vel), 0.0, 1.2, 1.2)
	tw.parallel().tween_property(s, "scale", Vector3.ZERO, 1.2)
	tw.chain().tween_callback(s.queue_free)


func _fly_step(t: float, s: Node3D, start: Vector3, vel: Vector3) -> void:
	if is_instance_valid(s):
		s.global_position = start + vel * t + Vector3(0, -4.9 * t * t, 0)
		s.rotate_y(0.35)


func _bone_size(b: int) -> float:
	var gp := _skeleton.get_bone_global_pose(b).origin
	var total := 0.0
	var count := 0
	for c in _skeleton.get_bone_count():
		if _skeleton.get_bone_parent(c) == b:
			total += _skeleton.get_bone_global_pose(c).origin.distance_to(gp)
			count += 1
	if count > 0:
		return clampf(total / float(count), 0.08, 0.5)
	return 0.12


func _ice_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.75, 0.9, 1.0, 0.55)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.1
	m.metallic = 0.1
	m.emission_enabled = true
	m.emission = Color(0.4, 0.7, 1.0)
	m.emission_energy_multiplier = 0.3
	return m


# ---- overlay shader FX ----

func _do_respawn() -> void:
	var sm := get_node_or_null(^"StatusManager")
	if sm != null and sm.has_method(&"clear_all"):
		sm.call(&"clear_all")   # drop lingering statuses so it can be re-frozen etc.
	pool.reset()
	_frozen = false
	_freeze_ramp = 0.0
	_flash = 0.0
	_elements.clear()
	_remove_ice()
	if model_root != null:
		model_root.visible = true
	_clear_overlay()


func _recompute() -> void:
	if body_mesh == null:
		return
	var coat := 0.0
	var burn := 0.0
	var pulse := 0.0
	var col := Color(0, 0, 0)
	var n := 0
	for e: Dictionary in _elements.values():
		n += 1
		col += e["color"]
		match e["channel"]:
			&"coat": coat = maxf(coat, 0.5)
			&"burn": burn = maxf(burn, 0.6)
			&"pulse": pulse = maxf(pulse, 4.0)
	if _freeze_ramp > 0.001:
		col += Color(0.6, 0.85, 1.0)
		n += 1
	if n > 0:
		col /= float(n)
	if _flash > 0.0:
		coat += _flash * 0.6
		burn += _flash * 0.6
		pulse = maxf(pulse, _flash * 6.0)
		col = _flash_color

	if coat <= 0.001 and burn <= 0.001 and pulse <= 0.001 and _freeze_ramp <= 0.001:
		_clear_overlay()
		return
	if not _overlay_on:
		body_mesh.material_overlay = ElementalManager.overlay_material
		_overlay_on = true
	body_mesh.set_instance_shader_parameter(&"element_color", col)
	body_mesh.set_instance_shader_parameter(&"coat_amount", coat)
	body_mesh.set_instance_shader_parameter(&"freeze_amount", _freeze_ramp)
	body_mesh.set_instance_shader_parameter(&"burn_amount", burn)
	body_mesh.set_instance_shader_parameter(&"pulse_speed", pulse)


func _clear_overlay() -> void:
	if _overlay_on and body_mesh != null:
		body_mesh.material_overlay = null
	_overlay_on = false


func _update_label() -> void:
	if pool == null or label == null:
		return
	var parts := PackedStringArray()
	for i in pool.layer_count():
		parts.append("%s:%d" % [pool.layer_type_at(i), roundi(pool.get_layer_value(i))])
	var prefix := ""
	if immortal:
		prefix = "[DUMMY] "
	elif pool.is_dead():
		prefix = "[DEAD] "
	elif _frozen:
		prefix = "[FROZEN] "
	label.text = prefix + "  ".join(parts)


func _on_died() -> void:
	_respawn = 1.5


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var found := _find_skeleton(c)
		if found != null:
			return found
	return null
