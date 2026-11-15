# ice_effect.gd — ICE: freeze in place, popsicle look, shatter on kill.
# Static toolbox called by ElementalManager. The shatter itself lives in
# ElementalTarget.on_killed() (kill while frozen) + VfxPool.spawn_shatter().
class_name IceEffect

const FREEZE_RAMP := 0.45   # seconds to fully ice over

static func on_applied(t: ElementalTarget) -> void:
	t.set_overlay(ElementalManager.ELEMENT_COLOR[ElementalManager.Element.ICE],
		0.0, 0.0, 0.0)
	t.set_frozen(true)
	t.fx_handles["ice_mist"] = VfxPool.acquire_emitter(
		"ice_mist", t.chest_socket)

static func on_update(s, _delta: float) -> void:
	# Ramp freeze_amount 0->1 over FREEZE_RAMP so the crust visibly grows,
	# then hold at 1 (the popsicle) until the status expires.
	var params: Dictionary = ElementalManager.ELEMENT_PARAMS[ElementalManager.Element.ICE]
	var elapsed: float = params.duration - s.time_left
	var f: float = clampf(elapsed / FREEZE_RAMP, 0.0, 1.0)
	s.target.set_overlay_param("freeze_amount", f)

static func on_removed(t: ElementalTarget) -> void:
	t.set_frozen(false)
	t.set_overlay_param("freeze_amount", 0.0)
	if t.fx_handles.has("ice_mist"):
		VfxPool.release_emitter("ice_mist", t.fx_handles["ice_mist"])
		t.fx_handles.erase("ice_mist")
	t.clear_overlay_if_unused()
