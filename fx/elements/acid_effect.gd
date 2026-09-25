# acid_effect.gd — ACID: chemical burn, flesh dissolves to reveal skeleton.
# Requires the shared dissolve material (base-material swap) because an
# overlay can't discard the base mesh's pixels.
class_name AcidEffect

const MAX_LIVING_DISSOLVE := 0.55   # while alive only partially eaten
const DEATH_DISSOLVE_TIME := 1.4    # on kill, melt the rest away

static func on_applied(t: ElementalTarget) -> void:
	t.begin_dissolve()
	t.fx_handles["acid_sizzle"] = VfxPool.acquire_emitter("acid_sizzle", t.chest_socket)
	# Melt fully on death (corpse dissolves down to the skeleton, then fades).
	if not t.died.is_connected(_on_target_died):
		t.died.connect(_on_target_died.bind(t))

static func on_update(s, _delta: float) -> void:
	var params: Dictionary = ElementalManager.ELEMENT_PARAMS[ElementalManager.Element.ACID]
	var progress: float = 1.0 - (s.time_left / params.duration)
	s.target.set_dissolve(progress * MAX_LIVING_DISSOLVE)

static func on_removed(t: ElementalTarget) -> void:
	if not t.is_dead:
		t.end_dissolve()   # flesh "heals" visually; keep it if you prefer scars
	if t.fx_handles.has("acid_sizzle"):
		VfxPool.release_emitter("acid_sizzle", t.fx_handles["acid_sizzle"])
		t.fx_handles.erase("acid_sizzle")

static func _on_target_died(t: ElementalTarget) -> void:
	if t.is_frozen:
		return   # ice shatter already handled the corpse
	# Tween the shared instance uniform to 1: flesh fully gone -> skeleton pose.
	var tw := t.create_tween()
	tw.tween_method(t.set_dissolve,
		t.body_mesh.get_instance_shader_parameter("dissolve_amount"),
		1.0, DEATH_DISSOLVE_TIME)
	# Then sink/fade the skeleton however your corpse cleanup works.
