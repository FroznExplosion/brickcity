# corrosive_effect.gd — CORROSIVE: green goo coat + puddle under the enemy.
class_name CorrosiveEffect

static func on_applied(t: ElementalTarget) -> void:
	var col: Color = ElementalManager.ELEMENT_COLOR[ElementalManager.Element.CORROSIVE]
	t.set_overlay(col, 1.0, 0.0, 0.0, 2.0)   # coat + gentle pulse (wet sheen)
	t.fx_handles["corr_drips"] = VfxPool.acquire_emitter("corr_drips", t.chest_socket)
	# Puddle: pooled ground quad/decal at the feet, grows in.
	var d := VfxPool.acquire_puddle(t.ground_socket.global_position, col, 0.9)
	t.fx_handles["corr_puddle"] = d

static func on_removed(t: ElementalTarget) -> void:
	t.set_overlay_param("coat_amount", 0.0)
	if t.fx_handles.has("corr_drips"):
		VfxPool.release_emitter("corr_drips", t.fx_handles["corr_drips"])
		t.fx_handles.erase("corr_drips")
	if t.fx_handles.has("corr_puddle"):
		VfxPool.fade_puddle(t.fx_handles["corr_puddle"], 3.0)
		t.fx_handles.erase("corr_puddle")
	t.clear_overlay_if_unused()
