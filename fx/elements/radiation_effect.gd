# radiation_effect.gd — RADIATION: like shock but slower, smokier, green,
# with a pulsing overlay glow, an irradiation aura, and spread-on-death.
#
# Arc visual: SAME ribbon system as shock, but the pooled "rad" arc scene's
# material sets scroll_speed ~1.5, softness ~0.25, green arc_color — or reuse
# the shock arcs and just drop intensity (done below) + add rad_smoke.
class_name RadiationEffect

const ARC_COUNT := 2

static func on_applied(t: ElementalTarget) -> void:
	var col: Color = ElementalManager.ELEMENT_COLOR[ElementalManager.Element.RADIATION]
	t.set_overlay(col, 0.15, 0.0, 0.0, 3.0)   # faint tint + radioactive throb
	var arcs: Array = []
	for i in ARC_COUNT:
		var a := VfxPool.acquire_arc(t.chest_socket)
		a.rotation.y = TAU * float(i) / ARC_COUNT + 0.7
		for m in a.find_children("*", "MeshInstance3D", true, false):
			m.set_instance_shader_parameter("seed", randf() * 10.0)
			m.set_instance_shader_parameter("intensity", 0.45)  # lazier arcs
		arcs.append(a)
	t.fx_handles["rad_arcs"] = arcs
	t.fx_handles["rad_smoke"] = VfxPool.acquire_emitter("rad_smoke", t.chest_socket)
	if not t.died.is_connected(_on_target_died):
		t.died.connect(_on_target_died.bind(t))

static func on_removed(t: ElementalTarget) -> void:
	for a in t.fx_handles.get("rad_arcs", []):
		VfxPool.release_arc(a)
	t.fx_handles.erase("rad_arcs")
	if t.fx_handles.has("rad_smoke"):
		VfxPool.release_emitter("rad_smoke", t.fx_handles["rad_smoke"])
		t.fx_handles.erase("rad_smoke")
	t.set_overlay_param("pulse_speed", 0.0)
	t.clear_overlay_if_unused()

## Dying while irradiated: the burst. The Borderlands spread -- infecting everyone
## nearby -- is gameplay, so it is not decided here; BoomerBorder's version applied
## it from this visual hook with a hard-coded collision mask. It belongs with the
## radiation StatusEffect, on the host.
static func _on_target_died(t: ElementalTarget) -> void:
	VfxPool.burst("rad_smoke", t.chest_socket.global_position)
